<*
 B2: the whole rigging math path, offline and with no GPU.

     `c3c test --trust=full --test-filter crig_tests::rig_export`

 Loads a mesh, rigs it, exports a rigged .glb, then re-opens that file and checks
 it is a rig rather than a plausible pile of bytes. Everything the interactive
 app will do on export runs here — `tails`, the binder, `sparsify_weights`, the
 glTF writer — so a failure in the math is a test failure and not a mystery in
 a viewport.

 Four rigs, in order of how much they ask of the weighting:

     spine        4 joints down the long axis. Proves the machinery runs.
     quadruped    16 dots — 5 spine, head, 2 tail, 2 per leg. PLAN §8's
                  interactive target, and the first rig with a fork in it.
     geodesic     the same 16 dots, weighted through the body instead of
                  across it. Same skeleton, same file, one thing different —
                  which is what makes the two tables a measurement of the
                  binder and of nothing else.
     crowned      the same 16 plus a dot in every part of the mesh that turned
                  out to have none. This is the editor's loop — look at what
                  holds no skin, put a dot there — run without the editor.

 Every skeleton is placed from measured landmarks rather than hard-coded
 coordinates, so nothing here depends on a particular model: the spine rig runs
 over `SPINE_MESH` and the limb rigs over `LIMB_MESH`, both from the repo, and
 either could be swapped for another model of the same broad shape.

 The .glb files it writes go under `build/`, which is not tracked.
*>
module crig_tests::rig_export;

import rig;
import gltf;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;


import std::io::file;

<*
 The two models the rigs are placed on, both tracked in the repo.

 Relative, so the run has to start from the crig directory. The limb rigs need a
 mesh standing on four separate columns; `find_landmarks` says so, and a mesh
 that does not is a broken fixture rather than a skipped check.
*>
const String SPINE_MESH = "assets/animations/humanoid.glb";
const String LIMB_MESH = "assets/animations/quadruped.glb";

// Where the exported files go. Gitignored, and `c3c test` runs from the project
// root, so this is beside the build output rather than in with the assets.
const String OUT_DIR = "build";

// How close a weight sum has to be to 1. sparsify_weights renormalises in
// float32 and the writer round-trips through the file, so this is float noise
// over four influences, not a tolerance for being slightly wrong.
const float WEIGHT_SUM_EPSILON = 1.0e-3f;

<*
 A chain of `count` joints down the mesh's longest axis, parents before
 children — the ordering the glTF writer assumes.

 This stands in for what the user will place by hand in B4. A straight spine is
 the crudest possible rig and that is the point: if the weights come out sane
 for this, the machinery is right and only the dot placement is left.
*>
fn rig::Skeleton spine_skeleton(Allocator allocator, rig::TriMesh geometry, usz count)
{
    rig::Bounds box = geometry.bounds();
    Vec3 extent = box.extent();

    usz axis = 0;
    for (usz i = 1; i < 3; i++) if (extent[i] > extent[axis]) axis = i;

    Vec3[] joints = alloc::new_array(allocator, Vec3, (sz)count);
    int[] parents = alloc::new_array(allocator, int, (sz)count);

    for (usz i = 0; i < count; i++)
    {
        // Along the long axis, centred on the other two — inside the body for
        // anything roughly convex, which is all this needs to be.
        float t = count > 1 ? (float)i / (float)(count - 1) : 0.5f;
        Vec3 joint = box.center();
        joint[axis] = box.min[axis] + extent[axis] * t;

        joints[i] = joint;
        parents[i] = i == 0 ? -1 : (int)(i - 1);
    }

    return { .joints = joints, .parents = parents };
}

// glTF is Y-up, so the vertical axis is never in question. The other two are.
const usz UP = 1;
const String[3] AXIS_NAME = { "x", "y", "z" };

<*
 Anatomical landmarks measured off the mesh.

 A straight spine proves the math runs; it does not show what the weighting does
 at a fork, which is the only place a geometric binder can be wrong in an
 interesting way. For that the rig has to have limbs, and the limbs have to be
 where the animal's are.

 The interactive app gets these from the user clicking. The test has to find
 them, and finding them by measurement rather than hard-coding goat coordinates
 is what lets `LIMB_MESH` be pointed at some other quadruped and still mean
 something.
*>
struct Landmarks
{
    rig::Bounds box;
    usz along;          // long horizontal axis — the spine runs down it
    usz side;           // the other horizontal axis — left/right
    float height;
    float head_sign;    // +1 when the head is at the high end of `along`
    Vec3[4] feet;       // hindL, hindR, foreL, foreR
    Vec3[4] knees;
    Vec3 head;
    Vec3 tail_tip;
    float hip_along;
    float shoulder_along;
    float spine_up;
    float leg_radius;   // how far from a foot still counts as that leg
    bool four_legs;     // false when the limb rig below would be meaningless
}

fn Landmarks find_landmarks(rig::TriMesh geometry)
{
    Vec3[] positions = geometry.positions;
    rig::Bounds box = geometry.bounds();
    Vec3 extent = box.extent();
    Vec3 center = box.center();

    Landmarks marks;
    marks.box = box;
    marks.height = extent[UP];
    marks.along = extent[0] > extent[2] ? 0 : 2;
    marks.side = marks.along == 0 ? 2 : 0;

    usz along = marks.along;
    usz side = marks.side;

    // Which end is the head? A head carries far more geometry than a tail, so
    // the denser of the two outer fifths wins. On the goat that is 455 verts
    // against 110 — not a close call, and it stays uncloseable on anything with
    // a face.
    float lo_cut = box.min[along] + extent[along] * 0.20f;
    float hi_cut = box.max[along] - extent[along] * 0.20f;
    usz lo = 0;
    usz hi = 0;
    foreach (p : positions)
    {
        if (p[along] < lo_cut) lo++;
        if (p[along] > hi_cut) hi++;
    }
    marks.head_sign = hi >= lo ? 1.0f : -1.0f;

    // Feet: the bottom sixth, split into quadrants. Anything standing on four
    // legs puts one cluster in each.
    float foot_cut = box.min[UP] + marks.height * 0.15f;
    Vec3[4] foot_sum;
    usz[4] foot_count;
    foreach (p : positions)
    {
        if (p[UP] >= foot_cut) continue;
        bool fore = (p[along] - center[along]) * marks.head_sign > 0.0f;
        bool right = p[side] > center[side];
        usz q = (usz)((fore ? 2 : 0) + (right ? 1 : 0));
        foot_sum[q] = foot_sum[q] + p;
        foot_count[q]++;
    }
    for (usz q = 0; q < 4; q++)
    {
        Vec3 foot = foot_count[q] > 0 ? foot_sum[q] * (1.0f / (float)foot_count[q]) : center;
        foot[UP] = box.min[UP] + marks.height * 0.04f;   // the ankle, just off the ground
        marks.feet[q] = foot;
    }

    // A leg is its own column out to a third of the way to the nearest other
    // leg. Derived from the animal rather than fixed, so it means the same
    // thing on a dachshund and on a giraffe.
    float closest = extent[along] + extent[side];
    for (usz a = 0; a < 4; a++)
    {
        for (usz b = a + 1; b < 4; b++)
        {
            float ds = marks.feet[a][side] - marks.feet[b][side];
            float da = marks.feet[a][along] - marks.feet[b][along];
            float d = math::sqrt(ds * ds + da * da);
            if (d < closest) closest = d;
        }
    }
    marks.leg_radius = closest * 0.35f;

    // A quadruped stands on four separate columns with a gap up the middle. A
    // pot, a trunk or a plinth fills that gap and puts its "feet" wherever the
    // quadrant lines happen to fall, and every number downstream of here is
    // then meaningless rather than merely approximate. Two tests: every
    // quadrant has to hold a foot at all, and the middle has to be empty.
    usz slab = foot_count[0] + foot_count[1] + foot_count[2] + foot_count[3];
    usz central = 0;
    foreach (p : positions)
    {
        if (p[UP] >= foot_cut) continue;
        float ds = p[side] - center[side];
        float da = p[along] - center[along];
        if (ds * ds + da * da < marks.leg_radius * marks.leg_radius) central++;
    }
    marks.four_legs = foot_count[0] > 0 && foot_count[1] > 0
        && foot_count[2] > 0 && foot_count[3] > 0
        && slab > 0 && (float)central / (float)slab < 0.05f;

    marks.hip_along = 0.5f * (marks.feet[0][along] + marks.feet[1][along]);
    marks.shoulder_along = 0.5f * (marks.feet[2][along] + marks.feet[3][along]);

    // The backbone runs just under the line of the back. Measured, because a
    // fraction of overall height would land in the belly on something
    // deep-chested and above the withers on something shallow.
    float torso_lo = math::min(marks.hip_along, marks.shoulder_along);
    float torso_hi = math::max(marks.hip_along, marks.shoulder_along);
    const usz TORSO_SLICES = 12;
    float top_sum = 0;
    usz slices = 0;
    for (usz s = 0; s < TORSO_SLICES; s++)
    {
        float a0 = torso_lo + (torso_hi - torso_lo) * (float)s / (float)TORSO_SLICES;
        float a1 = torso_lo + (torso_hi - torso_lo) * (float)(s + 1) / (float)TORSO_SLICES;
        float top = 0;
        bool found = false;
        foreach (p : positions)
        {
            if (p[along] < a0 || p[along] >= a1) continue;
            if (!found || p[UP] > top) { top = p[UP]; found = true; }
        }
        if (found) { top_sum += top; slices++; }
    }
    marks.spine_up = slices > 0
        ? top_sum / (float)slices - marks.height * 0.10f
        : box.min[UP] + marks.height * 0.60f;

    // Knees: the leg column, taken between a fifth and two fifths of the way up.
    float knee_lo = box.min[UP] + marks.height * 0.22f;
    float knee_hi = box.min[UP] + marks.height * 0.42f;
    Vec3[4] knee_sum;
    usz[4] knee_count;
    foreach (p : positions)
    {
        if (p[UP] < knee_lo || p[UP] > knee_hi) continue;
        for (usz q = 0; q < 4; q++)
        {
            float ds = p[side] - marks.feet[q][side];
            float da = p[along] - marks.feet[q][along];
            if (ds * ds + da * da > marks.leg_radius * marks.leg_radius) continue;
            knee_sum[q] = knee_sum[q] + p;
            knee_count[q]++;
            break;
        }
    }
    for (usz q = 0; q < 4; q++)
    {
        if (knee_count[q] > 0)
        {
            marks.knees[q] = knee_sum[q] * (1.0f / (float)knee_count[q]);
            continue;
        }
        // Nothing found in the band — split the difference between the hip
        // attachment and the foot rather than dropping the joint.
        Vec3 hip = marks.feet[q];
        hip[UP] = marks.spine_up;
        hip[along] = q < 2 ? marks.hip_along : marks.shoulder_along;
        marks.knees[q] = (hip + marks.feet[q]) * 0.5f;
    }

    marks.head = end_centroid(positions, along, marks.head_sign, box, extent, 0.18f, center);
    marks.tail_tip = end_centroid(positions, along, -marks.head_sign, box, extent, 0.12f, center);

    return marks;
}

// Centroid of the outer `fraction` of the mesh at one end of `along`.
fn Vec3 end_centroid(Vec3[] positions, usz along, float sign, rig::Bounds box,
                     Vec3 extent, float fraction, Vec3 fallback)
{
    float cut = sign > 0
        ? box.max[along] - extent[along] * fraction
        : box.min[along] + extent[along] * fraction;

    Vec3 sum;
    usz count = 0;
    foreach (p : positions)
    {
        bool beyond = sign > 0 ? p[along] > cut : p[along] < cut;
        if (!beyond) continue;
        sum = sum + p;
        count++;
    }
    return count > 0 ? sum * (1.0f / (float)count) : fallback;
}

<*
 PLAN §8's interactive target, placed without a viewport: 5 spine, head, 2 tail,
 and 2 dots per leg — 16 dots, the rig a user puts on a goat in a minute.

 Parents are always a lower index than their children, which is what
 the glTF writer requires.
*>
const String[] QUADRUPED_NAMES = {
    "pelvis", "spine_01", "spine_02", "chest", "neck", "head",
    "tail_01", "tail_02",
    "hindL_knee", "hindL_foot", "hindR_knee", "hindR_foot",
    "foreL_knee", "foreL_foot", "foreR_knee", "foreR_foot",
};
const String[4] LEG_NAME = { "hindL", "hindR", "foreL", "foreR" };

fn rig::Skeleton quadruped_skeleton(Allocator allocator, Landmarks marks)
{
    usz count = QUADRUPED_NAMES.len;
    Vec3[] joints = alloc::new_array(allocator, Vec3, (sz)count);
    int[] parents = alloc::new_array(allocator, int, (sz)count);

    Vec3 pelvis = marks.box.center();
    pelvis[UP] = marks.spine_up;
    pelvis[marks.along] = marks.hip_along;

    Vec3 chest = pelvis;
    chest[marks.along] = marks.shoulder_along;

    joints[0] = pelvis;                                        parents[0] = -1;
    joints[1] = pelvis + (chest - pelvis) * (1.0f / 3.0f);     parents[1] = 0;
    joints[2] = pelvis + (chest - pelvis) * (2.0f / 3.0f);     parents[2] = 1;
    joints[3] = chest;                                         parents[3] = 2;
    joints[4] = chest + (marks.head - chest) * 0.45f;          parents[4] = 3;
    joints[5] = marks.head;                                    parents[5] = 4;
    joints[6] = pelvis + (marks.tail_tip - pelvis) * 0.5f;     parents[6] = 0;
    joints[7] = marks.tail_tip;                                parents[7] = 6;

    // Hind legs hang off the pelvis, fore legs off the chest — the fork the
    // straight spine never exercised.
    for (usz q = 0; q < 4; q++)
    {
        usz knee = 8 + q * 2;
        joints[knee] = marks.knees[q];
        parents[knee] = q < 2 ? 0 : 3;
        joints[knee + 1] = marks.feet[q];
        parents[knee + 1] = (int)knee;
    }

    return { .joints = joints, .parents = parents };
}

// Leg joints occupy a contiguous block; everything before them is torso, and
// anything after is a dot added later.
const usz FIRST_LEG = 8;
const usz LEG_JOINT_COUNT = 8;

fn float segment_distance(Vec3 point, Vec3 head, Vec3 tail)
{
    Vec3 axis = tail - head;
    float length_sq = axis.dot(axis);
    if (length_sq <= 1.0e-12f) return (point - head).length();
    float t = math::clamp((point - head).dot(axis) / length_sq, 0.0f, 1.0f);
    return (point - (head + axis * t)).length();
}

fn float nearest_bone(rig::Skeleton* skeleton, Vec3 point)
{
    float best = -1.0f;
    foreach (b, joint : skeleton.joints)
    {
        int parent = skeleton.parents[b];
        Vec3 head = parent >= 0 ? skeleton.joints[(usz)parent] : joint;
        float d = segment_distance(point, head, joint);
        if (best < 0.0f || d < best) best = d;
    }
    return best;
}

<*
 The parts of the mesh no dot is anywhere near.

 This is the diagnostic the editor should eventually put on screen, and it is
 here because it is what explains a lopsided rig. `bind_geometric` gives every
 bone a pull on every vertex, so mesh with no dot near it is never left
 unweighted — it is handed to whatever happens to be least far away, and when
 several bones are equally far it is handed to the lowest-numbered one. Children
 of the same joint are *exactly* equally far from anything behind that joint,
 because they all clamp to it, so an unclaimed region does not merely get poor
 weights: it gets weights decided by bone index.

 On the goat that region is the horns, which the 16-dot rig has no dot for, and
 the tie between `chest -> foreL_knee` and `chest -> foreR_knee` handed 521
 vertices to the left leg and 13 to the right.

 A fraction of the worst distance rather than an absolute one, so it means the
 same thing on a goat and on a whale. The caller owns the result.
*>
fn Vec3[] unclaimed_regions(Allocator allocator, rig::TriMesh geometry,
                            rig::Skeleton* skeleton, Landmarks marks, float* worst)
{
    Vec3 center = marks.box.center();
    usz count = geometry.positions.len;

    float far = 0;
    float[] distance = alloc::new_array(mem, float, (sz)count);
    defer alloc::free(mem, distance);
    foreach (v, point : geometry.positions)
    {
        distance[v] = nearest_bone(skeleton, point);
        if (distance[v] > far) far = distance[v];
    }
    *worst = far;

    float cut = far * 0.70f;
    Vec3 left_sum;
    Vec3 right_sum;
    usz left_count = 0;
    usz right_count = 0;
    foreach (v, point : geometry.positions)
    {
        if (distance[v] < cut) continue;
        if (point[marks.side] < center[marks.side]) { left_sum = left_sum + point; left_count++; }
        else { right_sum = right_sum + point; right_count++; }
    }

    Vec3[2] found;
    usz regions = 0;
    if (left_count > 0) { found[regions] = left_sum * (1.0f / (float)left_count); regions++; }
    if (right_count > 0) { found[regions] = right_sum * (1.0f / (float)right_count); regions++; }

    // A feature on the midline — a snout, a dorsal fin — splits into two halves
    // that are really one dot. Merge them back rather than placing a mirrored
    // pair where the user would place one.
    if (regions == 2 && (found[0] - found[1]).length() < marks.leg_radius)
    {
        found[0] = (found[0] + found[1]) * 0.5f;
        regions = 1;
    }

    Vec3[] result = alloc::new_array(allocator, Vec3, (sz)regions);
    for (usz r = 0; r < regions; r++) result[r] = found[r];
    return result;
}

<*
 The 16-dot rig plus a dot in each unclaimed region — what the user does after
 reading the report and noticing the horns hold nothing.

 Each added dot hangs off whichever existing joint is nearest, which is always a
 lower index, so parents still precede children.
*>
fn rig::Skeleton crowned_skeleton(Allocator allocator, Landmarks marks, Vec3[] extra)
{
    rig::Skeleton base = quadruped_skeleton(allocator, marks);
    defer base.free(allocator);

    usz n = base.joints.len;
    usz total = n + extra.len;
    Vec3[] joints = alloc::new_array(allocator, Vec3, (sz)total);
    int[] parents = alloc::new_array(allocator, int, (sz)total);

    for (usz i = 0; i < n; i++)
    {
        joints[i] = base.joints[i];
        parents[i] = base.parents[i];
    }

    foreach (e, point : extra)
    {
        usz i = n + (usz)e;
        joints[i] = point;

        usz best = 0;
        float best_distance = -1.0f;
        for (usz b = 0; b < n; b++)
        {
            float d = (point - base.joints[b]).length();
            if (best_distance < 0.0f || d < best_distance) { best_distance = d; best = b; }
        }
        parents[i] = (int)best;
    }

    return { .joints = joints, .parents = parents };
}

// Which leg column a point sits in, or -1 for the body.
fn int leg_of(Landmarks marks, Vec3 point)
{
    if (point[UP] > marks.box.min[UP] + marks.height * 0.45f) return -1;
    for (usz q = 0; q < 4; q++)
    {
        float ds = point[marks.side] - marks.feet[q][marks.side];
        float da = point[marks.along] - marks.feet[q][marks.along];
        if (ds * ds + da * da <= marks.leg_radius * marks.leg_radius) return (int)q;
    }
    return -1;
}

<*
 What the binder actually produced, read back out of the file Blender opens.

 Read back rather than measured from the dense matrix on purpose: the dense
 matrix gives every bone a non-zero pull on every vertex, and what ships is the
 top four renormalised. Those are different rigs, and only the second one is the
 one anybody sees.

 Two things are worth looking at. Per-joint share says whether the dots the user
 placed are all doing work — a dot holding nothing is a dot in the wrong place,
 and the old export prune would have dropped it. The leg table says where a leg's own
 skin sends its weight, which is where `bind_geometric` is expected to be wrong:
 it measures straight-line distance, so the near side of one thigh is close to
 the other thigh's bone through the gap between them.
*>
struct SkinReport
{
    float weakest_share;
    float worst_bleed;        // a leg's weight landing on another leg
    float worst_asymmetry;    // how far apart a left/right leg pair holds skin
}

fn SkinReport report_skinning(String path, rig::TriMesh source, rig::Skeleton* skeleton,
                              String[] names, Landmarks marks, String measured = "straight-line distance")
{
    usz count = source.positions.len;
    usz bones = skeleton.joints.len;

    ushort[<4>][] vertex_joints = alloc::new_array(mem, ushort[<4>], (sz)count);
    Vec4[] vertex_weights = alloc::new_array(mem, Vec4, (sz)count);
    defer
    {
        alloc::free(mem, vertex_joints);
        alloc::free(mem, vertex_weights);
    }

    gltf::GltfStream stream = gltf::open(path, mem)!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    foreach (mesh : stream.gltf.meshes)
    {
        foreach (primitive : mesh.primitives)
        {
            stream.@each_joint(primitive, 0; ushort[<4>] joints, sz index)
            {
                if ((usz)index < count) vertex_joints[index] = joints;
            };
            stream.@each_weight(primitive, 0; Vec4 weights, sz index)
            {
                if ((usz)index < count) vertex_weights[index] = weights;
            };
        }
    }

    float[] share = alloc::new_array(mem, float, (sz)bones);
    usz[] owned = alloc::new_array(mem, usz, (sz)bones);
    defer
    {
        alloc::free(mem, share);
        alloc::free(mem, owned);
    }

    for (usz v = 0; v < count; v++)
    {
        usz best = 0;
        float best_weight = -1.0f;
        for (usz i = 0; i < 4; i++)
        {
            usz b = (usz)vertex_joints[v][i];
            if (b >= bones) continue;
            share[b] += vertex_weights[v][i];
            if (vertex_weights[v][i] > best_weight)
            {
                best_weight = vertex_weights[v][i];
                best = b;
            }
        }
        owned[best]++;
    }

    io::printn("\nskin held per joint — share of all weight, and where it wins outright:");
    float weakest = 1.0f;
    String weakest_name = "";
    foreach (b, name : names)
    {
        float fraction = share[b] / (float)count;
        if (fraction < weakest) { weakest = fraction; weakest_name = name; }
        io::printf("  %-11s %5.1f%%  wins %4d  ", name, fraction * 100.0f, owned[b]);
        usz filled = (usz)(fraction * 100.0f * 1.5f);
        for (usz i = 0; i < filled && i < 40; i++) io::printf("#");
        io::printn("");
    }

    io::printn("\nleg columns — where each leg's own skin sends its weight:");
    io::printfn("  %-6s %6s %9s %12s %8s", "leg", "verts", "own leg", "other legs", "torso");

    float worst_bleed = 0;
    bool legs_hold_themselves = true;
    for (usz q = 0; q < 4; q++)
    {
        usz own_knee = FIRST_LEG + q * 2;
        float own = 0;
        float other = 0;
        float torso = 0;
        usz verts = 0;

        for (usz v = 0; v < count; v++)
        {
            if (leg_of(marks, source.positions[v]) != (int)q) continue;
            verts++;
            for (usz i = 0; i < 4; i++)
            {
                usz b = (usz)vertex_joints[v][i];
                if (b >= bones) continue;
                float w = vertex_weights[v][i];
                if (b == own_knee || b == own_knee + 1) { own += w; }
                else if (b >= FIRST_LEG && b < FIRST_LEG + LEG_JOINT_COUNT) { other += w; }
                else { torso += w; }
            }
        }

        float total = own + other + torso;
        if (total <= 0.0f) continue;
        float bleed = other / total;
        if (bleed > worst_bleed) worst_bleed = bleed;
        if (own / total <= 0.5f) legs_hold_themselves = false;

        io::printfn("  %-6s %6d %8.1f%% %11.1f%% %7.1f%%",
            LEG_NAME[q], verts, own / total * 100.0f, bleed * 100.0f, torso / total * 100.0f);
    }

    // Left and right are the same animal; if the binder disagrees about them,
    // something is wrong with the binder rather than with the goat.
    float worst_asymmetry = 0;
    for (usz pair = 0; pair < 2; pair++)
    {
        usz left = FIRST_LEG + pair * 4;
        usz right = left + 2;
        float ls = share[left] + share[left + 1];
        float rs = share[right] + share[right + 1];
        float d = math::abs(ls - rs) / math::max(ls + rs, 1.0e-6f);
        if (d > worst_asymmetry) worst_asymmetry = d;
    }

    io::printn("");
    test::@check(weakest >= rig::DEFAULT_PRUNE_SHARE,
        "%s holds %.2f%% of the skin, under the %.2f%% prune cuts at",
        weakest_name, weakest * 100.0f, rig::DEFAULT_PRUNE_SHARE * 100.0f);
    test::@check(legs_hold_themselves, "each leg's skin is held mostly by its own bones");

    // Reported, not asserted: PLAN §8 lists leg-to-leg bleed as a known M1
    // artifact and M3 (geodesic weights through the interior) is what fixes it.
    // Asserting a number here would only pin the artifact in place.
    io::printfn("  NOTE leg-to-leg bleed %.1f%% under %s", worst_bleed * 100.0f, measured);
    io::printfn("  NOTE left/right leg pairs %.1f%% apart", worst_asymmetry * 100.0f);

    return { .weakest_share = weakest, .worst_bleed = worst_bleed, .worst_asymmetry = worst_asymmetry };
}

// ---------------------------------------------------------------------------
// Loading, and where the written files go
// ---------------------------------------------------------------------------

<*
 Load one of the fixture meshes, or fail the calling test saying which.

 The path is relative, so a run started outside the crig directory finds
 nothing — which is a different problem from a broken exporter and is reported
 as itself.
*>
fn rig::TriMesh? fixture_mesh(String path)
{
    rig::TriMesh? loaded = rig::load_gltf(mem, path);
    if (catch fault error = loaded)
    {
        test::@check(false, "could not load %s (%s) — run from the crig directory", path, error);
    }
    return loaded;
}

// `assets/…/foo.glb` -> `build/foo<suffix>.glb`, so nothing is written beside
// the tracked assets.
fn String out_path(Allocator allocator, String source, String suffix)
{
    String stem = source.ends_with(".glb") || source.ends_with(".gltf")
        ? source[..source.rindex_of_char('.')!! - 1]
        : source;
    usz slash = 0;
    foreach (usz i, c : stem) if (c == '/') slash = i + 1;
    return string::format(allocator, "%s/%s%s.glb", OUT_DIR, stem[slash..], suffix);
}

// ---------------------------------------------------------------------------
// The spine rig: four joints down the long axis, which proves the machinery runs
// ---------------------------------------------------------------------------

// Every bone has a non-zero direction. A bone with none imports into Blender as
// an armature fanning out from the origin.
fn void every_bone_has_a_direction() @test
{
    rig::TriMesh? loaded = fixture_mesh(SPINE_MESH);
    if (catch loaded) return;
    rig::TriMesh geometry = loaded;
    defer geometry.free(mem);

    rig::Skeleton skeleton = spine_skeleton(mem, geometry, 4);
    defer skeleton.free(mem);

    Vec3[] tails = skeleton.tails(mem);
    defer alloc::free(mem, tails);

    foreach (i, tail : tails)
    {
        test::@check((tail - skeleton.joints[i]).length() > 0.0f, "bone %d has no direction", i);
    }
}

// Dense weights are finite and positive — before any of the export machinery
// gets a chance to launder a NaN into a plausible-looking file.
fn void dense_weights_are_finite_and_positive() @test
{
    rig::TriMesh? loaded = fixture_mesh(SPINE_MESH);
    if (catch loaded) return;
    rig::TriMesh geometry = loaded;
    defer geometry.free(mem);

    rig::Skeleton skeleton = spine_skeleton(mem, geometry, 4);
    defer skeleton.free(mem);

    float[] dense = rig::bind_geometric(mem, geometry.positions, skeleton.joints, skeleton.parents);
    defer alloc::free(mem, dense);

    foreach (i, weight : dense)
    {
        test::@check(math::is_finite(weight) && weight > 0.0f, "dense weight %d is %.6f", i, weight);
    }
}

// An exported rig reads back as a rig. Reading the file rather than trusting
// the writer is the point: a self-consistent file no consumer can use fails
// only in Blender.
fn void an_exported_rig_reads_back_as_a_rig() @test
{
    rig::TriMesh? loaded = fixture_mesh(SPINE_MESH);
    if (catch loaded) return;
    rig::TriMesh geometry = loaded;
    defer geometry.free(mem);

    rig::Skeleton skeleton = spine_skeleton(mem, geometry, 4);
    defer skeleton.free(mem);

    float[] dense = rig::bind_geometric(mem, geometry.positions, skeleton.joints, skeleton.parents);
    defer alloc::free(mem, dense);

    String path = out_path(mem, SPINE_MESH, "_rigged");
    defer alloc::free(mem, path);

    rig::export_rigged_glb(mem, path, geometry, &skeleton, skin: dense)!!;
    validate_glb(path, geometry, 4);
    (void)file::delete(path);
}

<*
 An export with no skin supplied produces the same rig, not an empty one.

 The interactive app takes this path whenever the preview has not run, so the
 internal fallback has to reach the same file the explicit weights do.
*>
fn void an_export_with_no_skin_supplied_still_carries_one() @test
{
    rig::TriMesh? loaded = fixture_mesh(SPINE_MESH);
    if (catch loaded) return;
    rig::TriMesh geometry = loaded;
    defer geometry.free(mem);

    rig::Skeleton skeleton = spine_skeleton(mem, geometry, 4);
    defer skeleton.free(mem);

    String path = out_path(mem, SPINE_MESH, "_fallback");
    defer alloc::free(mem, path);

    rig::export_rigged_glb(mem, path, geometry, &skeleton)!!;
    validate_glb(path, geometry, 4);
    (void)file::delete(path);
}

// ---------------------------------------------------------------------------
// The limb rig: 16 dots, the first rig with a fork in it
// ---------------------------------------------------------------------------

<*
 The four-legged fixture, its landmarks and the 16-dot rig placed from them.

 Fails the calling test if the mesh is not standing on four separate columns —
 with a fixed fixture that means the model changed, not that the check does not
 apply. The caller frees the mesh and the skeleton.
*>
fn bool limb_rig(rig::TriMesh* geometry, rig::Skeleton* skeleton, Landmarks* marks)
{
    rig::TriMesh? loaded = fixture_mesh(LIMB_MESH);
    if (catch loaded) return false;
    *geometry = loaded;

    *marks = find_landmarks(*geometry);
    if (!marks.four_legs)
    {
        test::@check(false, "%s is not standing on four separate columns any more", LIMB_MESH);
        geometry.free(mem);
        return false;
    }

    *skeleton = quadruped_skeleton(mem, *marks);
    return true;
}

// The limb rig exports and reads back, which every claim below depends on.
fn void a_limb_rig_reads_back_as_a_rig() @test
{
    rig::TriMesh geometry;
    rig::Skeleton skeleton;
    Landmarks marks;
    if (!limb_rig(&geometry, &skeleton, &marks)) return;
    defer { skeleton.free(mem); geometry.free(mem); }

    String path = out_path(mem, LIMB_MESH, "_quadruped");
    defer alloc::free(mem, path);

    rig::export_rigged_glb(mem, path, geometry, &skeleton, names: QUADRUPED_NAMES)!!;
    validate_glb(path, geometry, skeleton.joints.len);
    (void)file::delete(path);
}

<*
 Every placed dot holds real skin, and each leg is held mostly by its own bones.

 Both come out of `report_skinning`, which reads the weights back off the file
 rather than off the array that was written — so a writer that dropped a column
 fails here and not merely in a viewer.
*>
fn void every_placed_dot_holds_real_skin() @test
{
    rig::TriMesh geometry;
    rig::Skeleton skeleton;
    Landmarks marks;
    if (!limb_rig(&geometry, &skeleton, &marks)) return;
    defer { skeleton.free(mem); geometry.free(mem); }

    String path = out_path(mem, LIMB_MESH, "_quadruped");
    defer alloc::free(mem, path);

    rig::export_rigged_glb(mem, path, geometry, &skeleton, names: QUADRUPED_NAMES)!!;
    report_skinning(path, geometry, &skeleton, QUADRUPED_NAMES, marks);
    (void)file::delete(path);
}

<*
 Measuring through the body cuts leg-to-leg bleed.

 Same dots, same skeleton, same file format, one thing different: how far apart
 two points are. That is what makes this a measurement of the binder and of
 nothing else. PLAN §8 lists the bleed as a known M1 artifact and M3 is what
 fixes it, so what is asserted is the improvement rather than a figure.
*>
fn void measuring_through_the_body_cuts_leg_bleed() @test
{
    rig::TriMesh geometry;
    rig::Skeleton skeleton;
    Landmarks marks;
    if (!limb_rig(&geometry, &skeleton, &marks)) return;
    defer { skeleton.free(mem); geometry.free(mem); }

    rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
    defer voxels.free(mem);
    test::@check(voxels.usable(), "%s has no inside, so there is nothing to measure through", LIMB_MESH);

    String plain_path = out_path(mem, LIMB_MESH, "_quadruped");
    defer alloc::free(mem, plain_path);
    rig::export_rigged_glb(mem, plain_path, geometry, &skeleton, names: QUADRUPED_NAMES)!!;
    SkinReport plain = report_skinning(plain_path, geometry, &skeleton, QUADRUPED_NAMES, marks);
    (void)file::delete(plain_path);

    float[] through = rig::bind_geodesic(mem, &voxels, geometry.positions, skeleton.joints, skeleton.parents);
    defer alloc::free(mem, through);

    String through_path = out_path(mem, LIMB_MESH, "_quadruped_geodesic");
    defer alloc::free(mem, through_path);
    rig::export_rigged_glb(mem, through_path, geometry, &skeleton, skin: through, names: QUADRUPED_NAMES)!!;
    SkinReport measured = report_skinning(
        through_path, geometry, &skeleton, QUADRUPED_NAMES, marks, "distance through the body");
    (void)file::delete(through_path);

    test::@check(measured.worst_bleed < plain.worst_bleed,
        "leg-to-leg bleed is %.1f%% straight-line and %.1f%% through the body",
        plain.worst_bleed * 100.0f, measured.worst_bleed * 100.0f);
}

<*
 A symmetric animal binds symmetrically, and covering the unclaimed mass keeps
 it that way.

 The 16 dots are the obvious ones and they do not cover everything: whatever
 they miss still has to be weighted to something. This is the editor's actual
 loop, run without the editor — look at what holds no skin, put a dot there —
 and the thing being protected is that the loop cannot cost symmetry.

 It used to be that the 16 dots alone came out lopsided, because a vertex
 equidistant from two bones radiating out of one parent had its tie settled by
 bone index. A joint holding its own outgoing bone rather than the one arriving
 from its parent removes the tie, so both halves of this check now read zero;
 the second assertion is the one with teeth.
*>
fn void a_symmetric_animal_stays_symmetric_when_the_gaps_are_covered() @test
{
    rig::TriMesh geometry;
    rig::Skeleton skeleton;
    Landmarks marks;
    if (!limb_rig(&geometry, &skeleton, &marks)) return;
    defer { skeleton.free(mem); geometry.free(mem); }

    String plain_path = out_path(mem, LIMB_MESH, "_quadruped");
    defer alloc::free(mem, plain_path);
    rig::export_rigged_glb(mem, plain_path, geometry, &skeleton, names: QUADRUPED_NAMES)!!;
    SkinReport plain = report_skinning(plain_path, geometry, &skeleton, QUADRUPED_NAMES, marks);
    (void)file::delete(plain_path);

    float worst_distance;
    Vec3[] unclaimed = unclaimed_regions(mem, geometry, &skeleton, marks, &worst_distance);
    defer alloc::free(mem, unclaimed);

    test::@check(unclaimed.len > 0,
        "no part of %s is left unclaimed by the 16 dots, so there is nothing to correct", LIMB_MESH);
    if (unclaimed.len == 0) return;

    rig::Skeleton crowned = crowned_skeleton(mem, marks, unclaimed);
    defer crowned.free(mem);

    String[] names = alloc::new_array(mem, String, (sz)crowned.joints.len);
    defer alloc::free(mem, names);
    foreach (i, name : QUADRUPED_NAMES) names[i] = name;
    foreach (r, point : unclaimed) names[QUADRUPED_NAMES.len + r] = r == 0 ? "crown_01" : "crown_02";

    String crowned_path = out_path(mem, LIMB_MESH, "_quadruped_crowned");
    defer alloc::free(mem, crowned_path);
    rig::export_rigged_glb(mem, crowned_path, geometry, &crowned, names: names)!!;
    validate_glb(crowned_path, geometry, crowned.joints.len);
    SkinReport fixed = report_skinning(crowned_path, geometry, &crowned, names, marks);
    (void)file::delete(crowned_path);

    test::@check(fixed.worst_asymmetry <= plain.worst_asymmetry,
        "left and right are %.1f%% apart with 16 dots and %.1f%% with the unclaimed mass covered",
        plain.worst_asymmetry * 100.0f, fixed.worst_asymmetry * 100.0f);
    test::@check(fixed.worst_asymmetry < 0.10f,
        "the corrected rig's left and right legs are still %.1f%% apart", fixed.worst_asymmetry * 100.0f);
}

// ---------------------------------------------------------------------------
// Pruning
// ---------------------------------------------------------------------------

<*
 Re-read the exported file and check it against what went in.

 Reading it back rather than trusting the writer is the whole point: the writer
 could produce a self-consistent file that no consumer can use, and the failure
 would only show up in Blender.
*>
fn void validate_glb(String path, rig::TriMesh source, usz joint_count)
{
    gltf::GltfStream stream = gltf::open(path, mem)!!;
    defer stream.close();
    stream.load_all_buffers()!!;

    test::@check((usz)stream.gltf.skins.len() == 1, "file has exactly one skin");
    if (stream.gltf.skins.len() == 0) return;

    gltf::Skin skin = stream.gltf.skins[0];
    test::@check((usz)skin.joints.len() == joint_count, "skin joint count matches the skeleton");

    // The inverse bind matrices are what pose the mesh; one per joint or the
    // rig silently deforms wrong in every viewer.
    gltf::Accessor ibm = stream.gltf.accessors[skin.inverseBindAccessor];
    test::@check((usz)ibm.count == joint_count, "inverse-bind matrix count matches joint count");

    usz vertices = 0;
    bool indices_in_range = true;
    bool sums_to_one = true;
    bool weights_finite = true;
    float worst = 0;

    foreach (mesh : stream.gltf.meshes)
    {
        foreach (primitive : mesh.primitives)
        {
            stream.@each_position(primitive; Vec3 position, sz index) { vertices++; };

            stream.@each_joint(primitive, 0; ushort[<4>] joints, sz index)
            {
                for (usz i = 0; i < 4; i++)
                {
                    if ((usz)joints[i] >= joint_count) indices_in_range = false;
                }
            };

            stream.@each_weight(primitive, 0; Vec4 weights, sz index)
            {
                float sum = 0;
                for (usz i = 0; i < 4; i++)
                {
                    if (!math::is_finite(weights[i]) || weights[i] < 0.0f) weights_finite = false;
                    sum += weights[i];
                }
                float error = math::abs(sum - 1.0f);
                if (error > worst) worst = error;
                if (error > WEIGHT_SUM_EPSILON) sums_to_one = false;
            };
        }
    }

    test::@check(vertices == source.positions.len, "vertex count survives the round trip");
    test::@check(indices_in_range, "every joint index is inside the skeleton");
    test::@check(weights_finite, "every weight is finite and non-negative");
    test::@check(sums_to_one, "a weight row sums to %.2e off 1", worst);
}

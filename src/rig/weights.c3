<*
 Binding a mesh to a skeleton, and writing the pair out as a rigged .glb.

 `bind_geometric` is SkinTokens' rig_export.c3 verbatim (module rename only). `export_rigged_glb` is that file's
 `export_rig_glb` with the AI-side plumbing removed: no `RigResult`, and no
 `Normalization`, because crig's joints are already in model space.

     `Skeleton skeleton = { .joints = ..., .parents = ... };`
     `rig::export_rigged_glb(mem, "goat_rigged.glb", geometry, &skeleton)!;`

 The dense `float[]` skin matrix is the contract the binders share:
 `bind_geometric` measures straight lines and needs nothing but the dots,
 `bind_geodesic` measures through the body and needs a `VoxelGrid`. Both return
 the same [vertices, bones] shape, so the live preview, the skinning pass and the
 export all read whichever one they were handed.

 The whole file keeps upstream's four-space indents against crig's tabs. Not an
 oversight: two of the functions here are byte-for-byte SkinTokens', and
 reformatting crig's half while leaving theirs would be worse than either — the
 shared style is what keeps the vendored code diffable.
*>
module rig;

import gltf;
import collision;


import std::math;
import std::math::vector;

<*
 Squared distance from a point to a bone, taken as the segment it runs along
 rather than as the joint at its end.

 Segments rather than joints because a limb's vertices sit alongside the bone,
 not around its ends: measured to the nearest joint, a vertex halfway down a
 thigh is equidistant from hip and knee and ends up blended between them, which
 makes the whole limb bend from the middle.
*>
fn float segment_distance_sq(Vec3 point, Vec3 head, Vec3 tail) @private
{
    Vec3 axis = tail - head;
    float length_sq = axis.dot(axis);
    if (length_sq <= 1.0e-12f)
    {
        Vec3 d = point - head;
        return d.dot(d);
    }
    float t = (point - head).dot(axis) / length_sq;
    t = math::clamp(t, 0.0f, 1.0f);
    Vec3 d = point - (head + axis * t);
    return d.dot(d);
}

<*
 Where each joint's own bone ends, which is the segment its skin is measured
 against.

 **A joint deforms the bone below it, not the bone above it.** `joint_palette`
 turns a joint about its own position, so the skin that has to answer to a joint
 is the skin that swings when it turns: the thigh belongs to the hip, the shin
 to the knee, the foot to the ankle. Measuring against the segment that
 *arrives* at a joint puts every limb one link too far down the chain — an error
 nothing sees until a mid-chain joint turns, whereupon the bone above the one
 being bent swings with it.

 `Skeleton.tails` is the same answer the exporters write and the viewport draws,
 so a joint's skin cannot disagree with its drawn bone. It also gives a leaf
 somewhere to reach: the segment runs half a bone past the last joint, which is
 what lets a hand, a foot or a head hold the mesh beyond its own dot instead of
 leaving it to the joint above.

 The caller owns the returned array.
*>
fn Vec3[] bone_tails(alloc::Allocator allocator, Vec3[] joints, int[] parents) @private
{
    Skeleton bones = { .joints = joints, .parents = parents };
    return bones.tails(allocator);
}

// Seed for a running minimum over squared distances. A model whose bones are
// this far from a vertex is not one anybody rigged; the value only has to lose
// to the first real comparison.
const float FURTHER_THAN_ANY_MESH @private = 1.0e30f;

<*
 How much of a bone's weight survives at squared distance `d2`, given the reach
 it was given.

 `1 / (d^2 + eps)` has no end: it is small far from a bone and never zero, so
 every dot influences every vertex and only the four-influence cut decides
 otherwise. A reach ranks that influence down:

     s = (r^2 / (r^2 + d^2))^2

 is 1 at the bone, a quarter at the reach, and a hundredth at three times it, so
 a bone asked to keep to itself is ranked far below one that was not. Dropping
 that ranking is what lets a shoulder with a 6 cm ring take a share of the back
 of a hood 20 cm away, because `1 / d^2` alone puts it in the same range as the
 neck that properly owns it.

 **A reach sizes a dot; it does not fence one.** Until M3.7 this was a window
 that cut to zero at `r`. That read well as a ring and behaved badly, because
 zero is not a weight — a vertex outside *every* reach came out holding nothing,
 which `sparsify_weights` cannot normalise, so it fell through to a repair that
 by construction could not honour cutoffs and had only this ranking left to
 choose with. An unlimited dot scores 1 there and beats every bounded one at any
 distance, so a rig with reaches on most of its dots and none on the rest handed
 all of its stranded mass to whichever dots had been left alone — a squirrel's
 two hind feet held a third of its body, head included, and the body skewed
 whenever a hind leg bent.

 Falling off smoothly instead means the main pass always has an answer, so no
 reach can strand a vertex and that second ranking never decides anything the
 user did not ask it to. The cost is that a reach no longer *guarantees* silence
 past `r`; what it buys is that being wrong about one degrades instead of
 detonating. `sparsify_weights` keeping only the four strongest influences is
 what turns a rank far down into no influence at all.

 A reach of zero is the unlimited one, which is what every dot has until a user
 says otherwise — so a rig that never sets one binds exactly as it did before
 reaches existed.
*>
fn float reach_bias(float d2, float reach) @private
{
    if (reach <= 0.0f) return 1.0f;

    float span = reach * reach;
    float fade = span / (span + d2);
    return fade * fade;
}

<*
 How far the repair looks for a cell the flood reached, in voxels.

 The distance across whatever separates a too-thin feature's islands from the
 body, which is a property of the voxelizer rather than of the model: a cell or
 two of gap where the parity test found no interior, not the length of the
 antenna. Six is generous for that and still short enough that the answer is the
 body the feature grows from rather than some other limb standing near it — the
 warning `nearest_cell` carries about widening a shell search applies here word
 for word.

 A feature further out than this keeps the straight-line last resort, which is
 the honest answer for a piece with no body near it at all.
*>
const int ISLAND_REACH @private = 6;

<*
 How many bones a cell of the grid keeps a distance for.

 `bind_geodesic` used to flood the whole interior once per bone. Almost all of
 that was thrown away — a hand's bone is nowhere near a foot, and the answer for
 every cell in the leg was a large number nobody read — and the price was that
 the grid could not be made fine enough to see a finger. On the shipped robot a
 rebind at the resolution that resolves fingers cost three and a half seconds
 against a rebind budget of a seventh of one.

 So every bone floods at once and each cell keeps only its nearest few: one pass
 over the interior instead of sixty-five, and the per-vertex read drops from a
 sample per bone to a sample per vertex.

 What that gives up is the distance from a vertex to a bone that is not among its
 nearest. Nothing reads those. `sparsify_weights` keeps four influences and the
 exporter writes four, so the fifth-nearest bone's weight has never reached a
 file; eight is double that, and the two views that read the raw matrix —
 territory and falloff — are asking which bone wins and by how much, which the
 nearest eight settle.

 It is a *ceiling*, not a promise: a cell in open ground away from the rig may
 hold fewer, and one wedged between limbs holds eight of them.
*>
const usz GEODESIC_SLOTS = 8;

// The reach of bone `b`, or unlimited when the caller supplied none. Short
// arrays are read as "no limit from here on", the same bargain `bind_geodesic`
// strikes with a short `attachments`.
fn float reach_of(float[] reaches, usz b) @private => b < reaches.len ? reaches[b] : 0.0f;

// The straight-line matrix, written into an array the caller has already sized.
// Split out so `bind_geodesic` can start from it without paying for a second
// allocation and a second `bone_tails`.
fn void fill_geometric(
    float[] dense,
    Vec3[] positions,
    Vec3[] joints,
    Vec3[] tails,
    float[] reaches,
    float[] nearest,
    float eps) @private
{
    usz bones = joints.len;
    bool wants_nearest = nearest.len == positions.len;

    foreach (usz v, position : positions)
    {
        usz base = v * bones;
        float closest = FURTHER_THAN_ANY_MESH;

        foreach (usz b, joint : joints)
        {
            float d2 = segment_distance_sq(position, joint, tails[b]);
            dense[base + b] = reach_bias(d2, reach_of(reaches, b)) / (d2 + eps);
            if (d2 < closest) closest = d2;
        }

        if (wants_nearest) nearest[v] = closest;
    }
}

<*
 A dense vertex-by-bone weight matrix from geometry alone.

 Each vertex is weighted towards each bone by `1 / (d^2 + eps)`, so influence
 falls off with the square of the distance to the bone's segment and no vertex
 is ever left with nothing. `sparsify_weights` reduces this to the four
 strongest influences and renormalises, so only the relative magnitudes matter
 and the absolute scale is free.

 The segment is the joint's own bone — see `bone_tails` for why it is that one
 and not the bone arriving from the parent.

 Straight-line distance is what makes adjacent limbs bleed into each other: a
 point on one thigh is close to the other thigh's segment through the gap
 between them. `bind_geodesic` is the answer to that; this stays as the binder
 for meshes with no inside to travel through, and as the fallback everywhere
 the grid has nothing to say.

 The caller owns the returned array. `eps` sets how soft the falloff is,
 relative to the model's own units.

 @param reaches : `One per joint, in model units, 0 for no limit — see reach_bias. Shorter than the joint count is allowed; the rest are unlimited.`
*>
fn float[] bind_geometric(
    alloc::Allocator allocator,
    Vec3[] positions,
    Vec3[] joints,
    int[] parents,
    float[] reaches = {},
    float eps = 1.0e-4f)
{
    usz bones = joints.len;
    float[] dense = alloc::new_array(allocator, float, (sz)(positions.len * bones));
    if (bones == 0) return dense;

    Vec3[] tails = bone_tails(allocator, joints, parents);
    defer { if (tails.len > 0) alloc::free(allocator, tails); }

    fill_geometric(dense, positions, joints, tails, reaches, {}, eps);
    return dense;
}

<*
 The same matrix, with the distance measured through the body instead of across
 it (M3).

 Every number here is `bind_geometric`'s, and every rule around them is the
 same — `1 / (d^2 + eps)`, unnormalised, read through `sparsify_weights`. The
 only thing that changes is `d`: a path that has to stay inside the mesh. On a
 quadruped that is the difference between the near side of one thigh sitting a
 few centimetres from the other thigh's bone and sitting a whole leg, a pelvis
 and another leg away from it.

 It starts from the straight-line matrix and overwrites what the grid can
 answer for, which makes every gap fall back rather than fail:

 - No grid, or a mesh with no inside, and the whole matrix is the geometric one.
 - A bone whose segment touches no interior voxel — a dot dropped outside the
   mesh — keeps its geometric column. The dot is misplaced, but silently giving
   it no skin would hide that from the user rather than show it.
 - A vertex the grid could not anchor keeps its geometric row.
 - A vertex inside a pocket no bone reaches ends the pass with nothing at all,
   which `sparsify_weights` cannot normalise, so its row is recomputed straight.

 **Every bone floods at once**, and each cell of the grid keeps its nearest
 `GEODESIC_SLOTS` of them rather than a distance for all — see there for what
 that gives up and why nothing reads it. The pass this replaced ran the whole
 interior once per bone, which put the resolution a hand needs an order of
 magnitude out of reach.

 Distance is read between voxel centres and interpolated back to the vertex, so
 the falloff is smooth rather than stepped at the grid's resolution — but a
 feature thinner than a cell may not voxelize, and a limb that does not fill is
 one no path travels down. That is the failure mode to look for if a rig comes
 out worse than the straight-line one: raise the resolution or check the mesh is
 closed.

 **A shell nothing reaches is a prop, not skin**, and **a shell wholly one
 bone's is that bone's** — see `rigid_shells`, which runs over the result and is
 where a sword strapped to a back stops bending and a machine's finger stops
 being smeared across its neighbours.

 The caller owns the returned array.

 @param voxels : `Built from this same mesh; null falls back to straight lines.`
 @param shells : `Built from this same mesh; null leaves every vertex to the rules above.`
 @param attachments : `One joint index per shell, -1 to decide automatically. Shorter than the shell count is allowed; the rest decide automatically.`
 @param riders : `Filled with the joint each shell was bound rigidly to, or -1. Caller-sized to the shell count; empty to not ask.`
 @param reaches : `One per joint, in model units, 0 for no limit — see reach_bias. Shorter than the joint count is allowed; the rest are unlimited.`
 @param nearest : `Filled with the squared distance to the closest bone, the same distance the weights were made from — geodesic where the flood arrived, straight-line elsewhere. Caller-sized to the vertex count; empty to not ask. This is the honest way to ask how well served a vertex is, because a weight scaled by a reach can no longer be inverted back into a distance.`
 @param eps : `Softness of the falloff, in the model's own units.`
*>
fn float[] bind_geodesic(
    alloc::Allocator allocator,
    MeshVoxels* voxels,
    Vec3[] positions,
    Vec3[] joints,
    int[] parents,
    MeshShells* shells = null,
    int[] attachments = {},
    int[] riders = {},
    float[] reaches = {},
    float[] nearest = {},
    float eps = 1.0e-4f)
{
    usz bones = joints.len;
    float[] dense = alloc::new_array(allocator, float, (sz)(positions.len * bones));
    if (bones == 0) return dense;

    // One `bone_tails` for the whole pass: the straight-line fill, the grid's
    // segments, the repair below and the carrier rule all have to agree about
    // where a bone runs, and deriving it four times is four chances not to.
    Vec3[] tails = bone_tails(allocator, joints, parents);
    defer { if (tails.len > 0) alloc::free(allocator, tails); }

    fill_geometric(dense, positions, joints, tails, reaches, nearest, eps);

    bool wants_nearest = nearest.len == positions.len;
    bool measured = voxels != null && voxels.usable() && voxels.anchors.len == positions.len;

    // Which vertices the flood arrived at. Not the same question as "does this
    // row hold anything": a vertex the grid could not anchor is never written by
    // the pass below and keeps its straight-line row, so a shell can end up with
    // weights everywhere and still never have been reached.
    bool[] reached = alloc::new_array(allocator, bool, (sz)positions.len);
    defer alloc::free(allocator, reached);
    reached[:positions.len] = false;

    // Which bones the grid actually answered for. A bone whose segment touches no
    // interior — a dot dropped outside the mesh — keeps its whole straight-line
    // column, because silently giving it no skin would hide the misplacement from
    // the user rather than show it.
    bool[] flooded = alloc::new_array(allocator, bool, (sz)bones);
    defer alloc::free(allocator, flooded);
    flooded[:bones] = false;

    collision::VoxelSource[] field = {};
    defer if (field.len > 0) alloc::free(allocator, field);

    if (measured)
    {
        collision::VoxelGrid grid = voxels.grid;

        field = alloc::new_array(allocator, collision::VoxelSource, (sz)(grid.cells.len * GEODESIC_SLOTS));
        grid.clear_sources(field, GEODESIC_SLOTS);

        foreach (usz b, joint : joints)
        {
            flooded[b] = grid.seed_source(field, GEODESIC_SLOTS, (int)b, joint, tails[b]) > 0;
        }
        grid.solve_sources(field, GEODESIC_SLOTS);

        collision::VoxelSource[GEODESIC_SLOTS] near;
        float near_field = grid.cell * 2.0f;

        foreach (usz v, position : positions)
        {
            int anchor = voxels.anchors[v];
            if (anchor < 0) continue;

            // Every bone the grid could speak for is spoken for here, whether or
            // not it arrived — a bone that did not reach this vertex holds none of
            // it, and leaving the straight line standing would be the bleed this
            // binder exists to remove.
            usz base = v * bones;
            for (usz b = 0; b < bones; b++)
            {
                if (flooded[b]) dense[base + b] = 0.0f;
            }

            usz found = grid.sample_sources(field, GEODESIC_SLOTS, position, anchor, near[..]);
            for (usz i = 0; i < found; i++)
            {
                if (near[i].distance >= collision::VOXEL_UNREACHED) continue;

                usz b = (usz)near[i].source;
                float d2 = near[i].distance * near[i].distance;
                // Nor shorter than the line. And within a couple of cells the
                // flood is no measure at all: it counts in whole voxels, so on a
                // small hand the finger joints sharing a cell come out the same
                // distance from everything round them — none, or a cell or two —
                // and one joint takes the whole finger. Up close a path through
                // the body is the line, so the line is what is used there.
                float line = segment_distance_sq(position, joints[b], tails[b]);
                d2 = near[i].distance <= near_field ? line : math::max(d2, line);

                // The first bone to arrive *replaces* the straight-line figure
                // rather than being taken as a minimum against it: a path through
                // the body is never shorter than the line across it, so a minimum
                // would keep the straight one and report a route the flood just
                // proved does not exist.
                if (wants_nearest) nearest[v] = reached[v] ? math::min(nearest[v], d2) : d2;
                reached[v] = true;

                dense[base + b] = reach_bias(d2, reach_of(reaches, b)) / (d2 + eps);
            }
        }
    }

    rigid_shells(dense, shells, attachments, riders, reached, measured, positions, joints, parents, tails, eps);

    // Both repairs below run for a vertex no bone holds at all, and their job is
    // that `sparsify_weights` always has something to normalise.
    //
    // Since M3.7 that means one thing only: a vertex the flood never arrived at.
    // A reach can no longer put a vertex here, because `reach_bias` never
    // answers zero — which is the point of it being a bias rather than a window.
    // The distinction matters to anyone reading these loops for the reach rules:
    // they have none left to apply beyond the ranking every other path applies
    // too, and a rig whose mesh the grid can travel never reaches this line at
    // all. What is left is geometry the flood cannot explain — a pocket, an
    // unanchored vertex, a mesh with no inside.
    //
    // What it must not drop is the *geodesy*. A straight line from the inner face
    // of one thigh finds the other thigh's bone across the gap before it finds
    // its own through the meat of its own leg, which is the whole failure this
    // binder exists to remove — so a repair measured straight lets it back in on
    // exactly the vertices least able to argue. The field solved above is still
    // in hand and every bone is in it, so the repair reads that rather than
    // measuring anything again.
    //
    // Which rows are stranded is settled *before* a single weight is written.
    // Deciding it as the pass goes would let the first bone to arrive fill a row
    // and so hide that row from every bone after it, leaving the vertex rigid to
    // whichever bone the loop happened to reach first.
    bool[] stranded = alloc::new_array(allocator, bool, (sz)positions.len);
    defer alloc::free(allocator, stranded);

    bool needed = false;
    for (usz v = 0; v < positions.len; v++)
    {
        usz base = v * bones;
        bool empty = true;
        for (usz b = 0; b < bones; b++)
        {
            if (dense[base + b] > 0.0f) { empty = false; break; }
        }
        stranded[v] = empty;
        needed = needed || empty;
    }

    if (measured && needed)
    {
        collision::VoxelGrid grid = voxels.grid;

        foreach (usz v, position : positions)
        {
            if (!stranded[v]) continue;

            // Cut off rather than merely far: a spine thinner than a cell — an
            // antenna, a whisker, an ear — voxelizes as islands sharing no face
            // with the body, so no flood seeded on the body ever enters one and
            // every bone reads UNREACHED however near it stands. Left there the
            // vertex falls to straight lines below, where a wrist held out beside
            // a head is nearer to that head's antenna through the air than the
            // neck is through the neck. Borrowing the nearest cell the flood *did*
            // reach binds the antenna like the skin it grows out of, which is what
            // it is.
            int borrowed = grid.nearest_sourced(field, GEODESIC_SLOTS, position, ISLAND_REACH);
            if (borrowed < 0) continue;

            collision::VoxelSource[] cell = field[(usz)borrowed * GEODESIC_SLOTS : GEODESIC_SLOTS];
            for (usz s = 0; s < GEODESIC_SLOTS; s++)
            {
                if (cell[s].source == collision::NO_VOXEL_SOURCE) break;

                usz b = (usz)cell[s].source;
                float d2 = cell[s].distance * cell[s].distance;
                dense[v * bones + b] = reach_bias(d2, reach_of(reaches, b)) / (d2 + eps);
            }
        }
    }

    // The last resort, and the only one available with no grid, no anchor, or a
    // pocket too far from the body for even the borrow above: straight lines to
    // every bone. Nothing is left holding nothing.
    for (usz v = 0; v < positions.len; v++)
    {
        usz base = v * bones;
        float total = 0.0f;
        for (usz b = 0; b < bones; b++) total += dense[base + b];
        if (total > 0.0f) continue;

        foreach (usz b, joint : joints)
        {
            float d2 = segment_distance_sq(positions[v], joint, tails[b]);
            dense[base + b] = reach_bias(d2, reach_of(reaches, b)) / (d2 + eps);
        }
    }

    return dense;
}

<*
 The share of a mesh a shell may hold and still be treated as something worn
 rather than as part of the body.

 A sword, a pauldron, a buckle, an eyeball: all small next to the figure. What
 the bar is really protecting is the other kind of split mesh — a character
 delivered as separate limb pieces, where every piece is unreachable from every
 other and binding them rigidly would freeze the knees. Those pieces are large,
 and they keep the straight-line weights that at least bend.

 A tenth is deliberately generous. Getting it wrong in the cautious direction
 leaves a prop bending, which the user can correct by attaching it by hand;
 getting it wrong the other way freezes a limb, and nothing in the interface
 says why.
*>
const float SHELL_PROP_SHARE = 0.1f;

<*
 How much of a shell's straight-line influence a bone's subtree must hold to be
 called the bone that carries it.
*>
const float SHELL_CARRIER_SHARE = 0.7f;

<*
 How much of a piece has to be nearest one bone before the piece is taken to
 *be* that bone's, and bound to it rigidly.

 This is what a hard-surface model is: not a skin stretched over a skeleton but
 one solid per bone, hinged at the joints. A Mixamo character shipped as a robot
 is ninety-five separate pieces and ninety-four of them are one joint outright in
 the weights it came with — which is why its hand reads cleanly and a
 falloff-bound one does not, and it is a fact about how the model was built
 rather than about anybody's weight painting.

 What the bar has to refuse is the piece that spans a joint — one box covering
 both sides of a knuckle, which is how a generator usually emits a finger —
 because binding *that* rigidly does not sharpen the hand, it welds the knuckle.

 The value comes from measuring rather than from taste, and the two kinds of
 piece turn out to be far apart. Counted over the two split models in the repo,
 pieces pile up at both ends and thin out in between: the robot has 21 of its 70
 sitting at 0.5-0.6 and 18 above 0.9, with five in the 0.8-0.9 band between them;
 the Mixamo character has 28 at 0.5-0.6 and 41 above 0.9, with seven between. A
 piece that straddles a knuckle splits near half-and-half by construction — the
 bone ends in the middle of it — so the low mode is the joint-spanning pieces and
 the high mode is the one-bone ones, and the bar belongs in the trough.

 Nearest bone rather than the bound weights, so what the test measures and what
 the rule then does are the same statement about the geometry, and neither can
 drift from the other as the binder changes.
*>
const float SHELL_RIGID_SHARE = 0.85f;

<*
 Give every vertex of a shell the same weights, so the shell moves as one rigid
 piece.

 Three things ask for this. An **attachment** is the user naming the bone a piece
 rides, and it is obeyed whatever the geometry says.

 A shell the flood reached **none** of is worn rather than grown: no path runs
 from any bone to any part of it, so there is no distance through the body to
 weight it by, and the gap has no other honest reading. Left alone it would fall
 to the straight-line repair below, which is the one rule guaranteed to smear it
 — a sword slung across a back comes out held at the tip by the head, at the
 middle by a shoulder and at the hilt by the spine, and bends in the middle of
 the blade when the figure walks.

 And a shell that is **wholly one bone's** is that bone's, which is what a
 hard-surface model is made of: see `SHELL_RIGID_SHARE`. This is the only one of
 the three that fires on a piece the flood reached perfectly well. It fires
 because a falloff is the wrong answer there and not a slightly soft one — a
 solid hinged at its ends does not stretch, and every gram of the neighbouring
 bone's influence that a distance function puts on it is a gram of wrong.

 Rigid means one identical row per vertex, so the whole shell resolves to a
 single transform however the skinning weights it.

 **Only on a mesh that came apart, and only with a grid.** A mesh in one piece
 is a skin and none of this applies to it, so a single shell is left entirely
 alone — which is also what keeps every organic model binding exactly as it did.
 And with no distances measured, no shell has been reached and every one of them
 would look worn, which would bind a whole mesh rigidly on the strength of a
 measurement never taken. Attachments are still honoured in both cases, because
 they are a statement about the model and not about the grid.

 @param dense : `[vertices, bones], rewritten in place for the shells that qualify.`
 @param riders : `Receives the joint each shell was bound to, or -1; empty to not report.`
 @param reached : `Per vertex, whether any bone's flood arrived at it.`
 @param measured : `Whether the flood ran at all; false disables the automatic rule.`
*>
fn void rigid_shells(
    float[] dense,
    MeshShells* shells,
    int[] attachments,
    int[] riders,
    bool[] reached,
    bool measured,
    Vec3[] positions,
    Vec3[] joints,
    int[] parents,
    Vec3[] tails,
    float eps) @private
{
    riders[..] = -1;
    if (shells == null || shells.of.len != positions.len || shells.count == 0) return;

    usz bones = joints.len;

    for (int shell = 0; shell < (int)shells.count; shell++)
    {
        int rider = (usz)shell < attachments.len ? attachments[shell] : -1;

        if (rider < 0)
        {
            if (!measured || !shells.split()) continue;

            usz members = 0;
            bool touched = false;
            foreach (usz v, id : shells.of)
            {
                if (id != shell) continue;
                members++;
                if (reached[v]) touched = true;
            }
            if (members == 0) continue;

            if (touched)
            {
                // Reached, so there is a real distance to weight it by — and the
                // only reason to throw that away is that the piece turns out to
                // be one bone's outright. No size bar on this one: what would
                // freeze a knee is a piece *spanning* the knee, and the share
                // below is already the test for that. A piece is not dangerous
                // for being large, only for being two bones' worth.
                rider = solid_bone(shells, shell, members, positions, joints, tails);
            }
            else
            {
                if ((float)members > SHELL_PROP_SHARE * (float)positions.len) continue;
                rider = shell_carrier(shells, shell, positions, joints, parents, tails, eps);
            }
        }

        if (rider < 0 || (usz)rider >= bones) continue;
        if ((usz)shell < riders.len) riders[shell] = rider;

        foreach (usz v, id : shells.of)
        {
            if (id != shell) continue;
            usz base = v * bones;
            for (usz b = 0; b < bones; b++) dense[base + b] = 0.0f;
            dense[base + (usz)rider] = 1.0f;
        }
    }
}

<*
 The one bone a piece belongs to outright, or -1 when it belongs to more than
 one.

 A vote of nearest bones, and the winner has to take `SHELL_RIGID_SHARE` of the
 piece. Nearest rather than most-weighted because a weight is a falloff over
 every bone and this question is not about falloffs at all: it is whether the
 piece sits in one bone's territory, which is a fact about where it is.

 A tie cannot be nearer than the bar, so there is no tie-break to get wrong: two
 bones splitting a piece both come in under the share and the piece keeps its
 falloff, which is the right answer for a box that spans a knuckle.

 @param members : `How many vertices the piece has, already counted by the caller.`
*>
fn int solid_bone(
    MeshShells* shells,
    int shell,
    usz members,
    Vec3[] positions,
    Vec3[] joints,
    Vec3[] tails) @private
{
    usz bones = joints.len;

    // Allocation-free, and the same ceiling `shell_carrier` works under: a rig
    // with more bones than this is not one a person placed by hand.
    const usz LIMIT = 256;
    if (bones == 0 || bones > LIMIT || members == 0) return -1;

    usz[LIMIT] votes;
    votes[:bones] = 0;

    foreach (usz v, id : shells.of)
    {
        if (id != shell) continue;

        usz best = 0;
        float nearest = FURTHER_THAN_ANY_MESH;
        foreach (usz b, joint : joints)
        {
            float d2 = segment_distance_sq(positions[v], joint, tails[b]);
            if (d2 >= nearest) continue;
            nearest = d2;
            best = b;
        }
        votes[best]++;
    }

    usz top = 0;
    for (usz b = 1; b < bones; b++)
    {
        if (votes[b] > votes[top]) top = b;
    }
    return (float)votes[top] >= SHELL_RIGID_SHARE * (float)members ? (int)top : -1;
}

<*
 The bone a loose piece hangs off: the deepest one whose subtree still holds
 most of the piece's straight-line influence.

 Proximity alone answers this badly, and the failure is not subtle. A sword
 lying diagonally across a back is nearest to a shoulder, so proximity straps it
 to an arm and it swings when the arm does; measured to the skin it rests
 against it comes out on the neck, and it swings when the head turns. What is
 actually true of it is that it spans the shoulders, the chest and the spine —
 and the bone all of those descend from is the spine, which is where a scabbard
 is strapped.

 So influence is summed per bone and then accumulated up the tree, and the
 answer is the deepest bone whose subtree still carries `SHELL_CARRIER_SHARE` of
 the piece. Deepest, because the root's subtree always holds everything and
 saying so is useless: a hat wants the head, not the hips. A piece that leans on
 one limb alone lands on that limb by the same rule, since its subtree is the
 only one that qualifies below the trunk.

 @return `A joint index, or -1 when the piece leans on nothing.`
*>
fn int shell_carrier(
    MeshShells* shells,
    int shell,
    Vec3[] positions,
    Vec3[] joints,
    int[] parents,
    Vec3[] tails,
    float eps) @private
{
    usz bones = joints.len;

    // Stack-free and allocation-free: the two accumulators are the only state,
    // and a rig with more bones than this is not one a person placed by hand.
    const usz LIMIT = 256;
    if (bones == 0 || bones > LIMIT) return -1;

    float[LIMIT] subtree;
    subtree[:bones] = 0;

    float members = 0;
    foreach (usz v, id : shells.of)
    {
        if (id != shell) continue;

        float total = 0;
        float[LIMIT] row;
        foreach (usz b, joint : joints)
        {
            row[b] = 1.0f / (segment_distance_sq(positions[v], joint, tails[b]) + eps);
            total += row[b];
        }
        if (total <= 0.0f) continue;

        // Normalised per vertex, so every vertex of the piece counts once however
        // near the bones it happens to sit.
        for (usz b = 0; b < bones; b++) subtree[b] += row[b] / total;
        members += 1.0f;
    }
    if (members <= 0.0f) return -1;

    // Joints are ordered parents-before-children, so one backward pass folds
    // every child into its parent before the parent is read.
    for (usz b = bones; b > 0; b--)
    {
        int parent = parents[b - 1];
        if (parent >= 0) subtree[(usz)parent] += subtree[b - 1];
    }

    float bar = members * SHELL_CARRIER_SHARE;
    int carrier = -1;
    usz deepest = 0;
    for (usz b = 0; b < bones; b++)
    {
        if (subtree[b] < bar) continue;

        usz depth = 0;
        for (int walk = (int)b; walk >= 0; walk = parents[(usz)walk]) depth++;
        if (carrier < 0 || depth > deepest)
        {
            carrier = (int)b;
            deepest = depth;
        }
    }
    return carrier;
}

<*
 The share of a mesh's skin a joint has to hold to be worth keeping.

 A count would not travel: two vertices out of a 1300-vertex cow is noise, and
 two out of a 200000-vertex scan is nothing at all. A share means the same thing
 on both.
*>
const float DEFAULT_PRUNE_SHARE = 0.005f;

<*
 Write the mesh and its skeleton out as a rigged .glb.

 SkinTokens' `export_rig_glb` minus the AI plumbing: crig's joints are already
 in model space, so there is no `Normalization` to map back through, and there
 is no `RigResult` — the skeleton is passed directly.

 Bone directions come from `Skeleton.tails`, and they are not optional: a glb
 whose bones have no direction imports into Blender as an armature fanning out
 from the origin, whatever the joint positions say.

 Joints are named positionally unless the caller supplies names. Deriving them —
 `.L`/`.R` for mirror pairs, limb names from the dot's position — is M5; this is
 just the hook, and it exists because an armature of `joint_11`s is unreadable in
 Blender, which is where a rig gets checked.

 @param geometry : `The mesh in its own coordinates.`
 @param skeleton : `Joints in model space, ordered parents-before-children.`
 @param skin : `[vertices, bones] weights, or empty for the distance fallback.`
 @param names : `One name per joint, or empty for positional joint_N names.`
 @param influences : `How many bones a vertex may ride in the file; 1 writes a rigid bind with no blending.`
 @return? gltf::WEIGHT_SIZE_MISMATCH : `The skeleton and the weight matrix disagree.`
 @return? gltf::WRITE_FAILED : `The file could not be opened, written or flushed.`
*>
fn void? export_rigged_glb(
    alloc::Allocator allocator,
    String path,
    TriMesh geometry,
    Skeleton* skeleton,
    String name = "Mesh",
    float[] skin = {},
    String[] names = {},
    uint influences = 4)
{
    Vec3[] joints = skeleton.joints;

    Vec3[] tails = skeleton.tails(allocator);
    defer alloc::free(allocator, tails);

    gltf::Bone[] bones = alloc::new_array(allocator, gltf::Bone, (sz)joints.len);
    defer alloc::free(allocator, bones);

    bool named = names.len == joints.len;

    foreach (i, joint : joints)
    {
        bones[i] = {
            // Copied either way, so the free below stays uniform and the
            // caller's names are not aliased into the file writer.
            .name = named
                ? string::format(allocator, "%s", names[i])
                : string::format(allocator, "joint_%d", i),
            .parent = skeleton.parents[i],
            .position = joint,
            .direction = tails[i] - joint,
        };
    }
    defer foreach (bone : bones) alloc::free(allocator, bone.name);

    bool predicted = skin.len == geometry.positions.len * joints.len && joints.len > 0;
    float[] fallback = predicted
        ? (float[]){}
        : bind_geometric(allocator, geometry.positions, joints, skeleton.parents);
    defer if (!predicted) alloc::free(allocator, fallback);

    gltf::SkinnedMesh skinned = {
        .name = name,
        .positions = geometry.positions,
        .normals = geometry.normals,
        .indices = geometry.indices,
        .bones = bones,
        .weights = predicted ? skin : fallback,
        .max_influences = influences,
    };

    return gltf::write_skinned_glb(path, skinned, allocator);
}

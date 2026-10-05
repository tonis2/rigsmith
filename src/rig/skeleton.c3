<*
 The skeleton a rig is built from: a joint per bone, and the index of the bone
 it hangs from.

 Extracted from SkinTokens' rig_tokens.c3, which is mostly transformer token
 machinery M1 has no use for. What is kept is the part a rig actually needs —
 the struct, and `tails()` — plus the faultdef that lives in a file crig does
 not vendor and would otherwise be stranded.

 In crig, unlike SkinTokens, joints are in model space — there is no encoder and
 no normalised frame, so nothing has to be mapped back before export.

 The indentation is upstream's — four spaces, against crig's tabs everywhere
 else. Left alone on purpose, so that what is vendored is visible from the
 formatting and a re-sync stays a small diff.
*>
module rig;



import std::math;
import std::math::vector;

<*
 Raised when a dense skin matrix is not exactly `vertices * bones` long.

 Re-homed from skin_vae.c3, which crig does not vendor.
*>
faultdef SKIN_SHAPE_MISMATCH;

<*
 A skeleton: a joint per bone, and the index of the bone it hangs from.

 `parents[i]` is -1 for a root. Joints must be ordered parents-before-children:
 the glTF writer and every ancestor walk assume a parent index is lower than the
 child's.
*>
struct Skeleton {
    Vec3[] joints;
    int[] parents;
}

fn usz Skeleton.len(self) => self.joints.len;

<*
 How tall the rig stands, the unit a template's offsets are measured in.

 The joints' vertical extent rather than the mesh's, because it is the rig a
 template is written against: a figure wearing a tall hat is not a figure that
 should bob further. Zero for a rig with no height — one joint, or a flat one —
 which leaves every scaled offset at zero, and a rig with nothing to fall
 through is a rig that should not be dropped.

 Both ends of the animation path read this: the importer divides by the source
 rig's height to store an offset, the player multiplies by the target's to use
 it, so the two have to agree on what "height" counts.
*>
fn float Skeleton.height(&self) {
    if (self.joints.len == 0) return 0.0f;

    float lowest = self.joints[0].y;
    float highest = lowest;
    foreach (joint : self.joints) {
        if (joint.y < lowest) lowest = joint.y;
        if (joint.y > highest) highest = joint.y;
    }
    return highest - lowest;
}

// How far past a joint a leaf bone is extruded, as a fraction of the bone that
// led into it. `extrude_scale` in the reference.
const float TAIL_EXTRUDE = 0.5f;

<*
 Where each bone ends — its tail, in the same frame as the joints.

 A skeleton names joints, not bones: a position and where it hangs from, and
 nothing about which way the bone between them faces onward. That is fine for a
 graph and useless for a rig, because every consumer of a skeleton draws and
 rotates bones along their own length — import a glb without tails into Blender
 and the bones fan out from the origin. So the direction is reconstructed, and
 there are two cases:

     has children   the tail is the child that continues straightest — the one
                    whose direction best matches the bone that arrived here
     a leaf         nothing to reach, so extrude the direction that arrived
                    here by half its length

 Straightest, rather than first in joint order, because of what a fork costs
 downstream.
 First-in-joint-order let BFS decide instead, and BFS reaches a quadruped's
 front legs before its neck — so a cow exported with a shoulder bone plunging
 down a foreleg and the neck left hanging, which is the one arrangement nobody
 would draw by hand. Ties still fall to the earliest child, so a straight chain
 is unaffected.

 The reference instead aims at a child only where there is exactly one and
 extrudes a fork the way it extrudes a leaf, which leaves a fork pointing at
 nothing — on the cow that put the second shoulder's bone out through the ribs
 and left 8 of 33 bones ending in mid-air.

 A tail decides which axes a joint turns about *and* what its skin is: the
 binder measures every vertex against the segment from a joint to its tail, so
 changing an answer here moves weights. See `bone_tails` in rig/weights.c3.

 The caller owns the returned array.
*>
fn Vec3[] Skeleton.tails(&self, Allocator allocator) {
    usz count = self.joints.len;
    Vec3[] tails = alloc::new_array(allocator, Vec3, (sz)count);
    if (count == 0) return tails;

    usz[] heir = alloc::new_array(allocator, usz, (sz)count);
    bool[] has_child = alloc::new_array(allocator, bool, (sz)count);
    float[] straightest = alloc::new_array(allocator, float, (sz)count);
    defer {
        alloc::free(allocator, heir);
        alloc::free(allocator, has_child);
        alloc::free(allocator, straightest);
    }
    for (usz i = 0; i < count; i++) { heir[i] = 0; has_child[i] = false; straightest[i] = 0; }

    // Ascending and a strict improvement to win, so a tie keeps the earliest
    // child in joint order. A root's children are scored against world up
    // rather than tying — see bone_continuation for why joint order must not
    // decide a root's facing.
    foreach (usz i, parent : self.parents) {
        if (parent < 0 || (usz)parent >= count) continue;
        usz p = (usz)parent;
        float score = bone_continuation(self, p, i);
        if (has_child[p] && score <= straightest[p]) continue;
        heir[p] = i;
        straightest[p] = score;
        has_child[p] = true;
    }

    for (usz i = 0; i < count; i++) {
        if (has_child[i]) {
            tails[i] = self.joints[heir[i]];
            continue;
        }

        int parent = self.parents[i];
        if (parent >= 0 && (usz)parent < count) {
            Vec3 arriving = self.joints[i] - self.joints[(usz)parent];
            // Coincident joints happen — a shoulder and an upper arm often sit
            // on the same point — and leave nothing to extrude along.
            if (arriving.length_sq() > 1.0e-18f) {
                tails[i] = self.joints[i] + arriving * TAIL_EXTRUDE;
                continue;
            }
        }

        // A lone joint, with nothing above it and nothing below. Up is +Y:
        // these are glTF coordinates, where the reference's are Blender's.
        tails[i] = self.joints[i] + (Vec3){ 0, TAIL_EXTRUDE, 0 };
    }

    return tails;
}

<*
 How straight the bone from `parent` down to `child` continues the bone that
 arrived at `parent`: the cosine between the two, 1 for dead straight and -1 for
 a fold back along it.

 A root has no arriving bone, so its children are scored against world up
 instead. Not a stylistic choice: retargeting compares this direction across
 two rigs, and "the earliest child" is an accident of joint order — one file
 lists the hips' thigh first and another its spine, and the carry between the
 two turns of a root becomes a half-turn that folds every clip in half. Up is
 the one direction two standing rigs share without consulting each other.

 Two answers are not cosines and both are deliberate:

     0    the bone above `parent` has no length, so there is nothing to
          continue. Every child then scores the same and the caller's tie rule
          picks the earliest.
     -2   `child` sits on top of `parent`, so the bone between them has no
          direction to judge. Below every real cosine, so a zero-length bone is
          taken as an heir only when there is nothing else on offer.

 Coincident joints are not hypothetical here — a shoulder and an upper arm often
 land on the same point — and scoring one 0 would let it beat a limb that folds
 back, handing the tail to the one child that cannot say where it points.
*>
fn float bone_continuation(Skeleton* skeleton, usz parent, usz child) @private {
    Vec3 onward = skeleton.joints[child] - skeleton.joints[parent];
    float onward_sq = onward.length_sq();
    if (onward_sq < 1.0e-18f) return -2.0f;

    int above = skeleton.parents[parent];
    if (above < 0 || (usz)above >= skeleton.joints.len) {
        return onward.y / math::sqrt(onward_sq);
    }

    Vec3 arriving = skeleton.joints[parent] - skeleton.joints[(usz)above];
    float arriving_sq = arriving.length_sq();
    if (arriving_sq < 1.0e-18f) return 0;

    return onward.dot(arriving) / math::sqrt(onward_sq * arriving_sq);
}

<*
 Which way each bone points, as a unit vector, or zero where it has no
 direction to speak of.

 The direction from a joint to its tail, so this is `tails()` expressed as a
 heading rather than a point, and it inherits every decision made there —
 including which child a fork continues into.

 Retargeting is what wants it. A pose rotation is about a world axis, which
 makes the same angle mean different things on two rigs whose limbs rest in
 different directions: swing a hanging arm about X and it walks, swing a
 T-posed arm about X and it merely spins in place. Knowing where the bone
 pointed when a template was authored, and where it points now, is enough to
 carry the axis across — and when the two rigs agree the correction is the
 identity, so a template authored against the target costs nothing.

 The caller owns the returned array.
*>
fn Vec3[] Skeleton.bone_directions(&self, Allocator allocator) {
    usz count = self.joints.len;
    Vec3[] directions = alloc::new_array(allocator, Vec3, (sz)count);
    if (count == 0) return directions;

    Vec3[] tails = self.tails(allocator);
    defer alloc::free(allocator, tails);

    for (usz i = 0; i < count; i++) {
        Vec3 bone = tails[i] - self.joints[i];
        // Zero rather than an arbitrary direction: a bone with no length cannot
        // say which way it points, and a caller reading zero knows to leave the
        // axis alone instead of turning it somewhere invented.
        directions[i] = bone.length_sq() > 1.0e-18f ? bone.normalize() : (Vec3){ 0, 0, 0 };
    }

    return directions;
}

<*
 The unbranched run of ancestors above `joint` — the joints that may turn to
 carry it somewhere.

 Up through every parent that has exactly one child, stopping at the first that
 has more, and at a root. On a figure, asking this of an ankle gives back the
 knee and the thigh and stops at the hips; asking it of a wrist gives the elbow
 and the shoulder and stops at the chest. That is the limb, and the rig's own
 shape said so — there is no chain length to choose and nothing to configure per
 model.

 **A fork is where it stops because a fork is shared.** The hips carry both legs
 and the spine, so turning them to place one foot swings the other leg and the
 head, which is not what moving a foot asks for. The joints that can move it
 without disturbing anything else are exactly the ones with nothing else hanging
 off them.

 `joint` itself is never included. Turning a joint about its own position leaves
 it exactly where it was — see `joint_palette` in pose.c3, where a joint's own
 rotation is applied after the translation that places it — so it can bend
 everything below without helping itself anywhere.

 Child counts are recounted per step rather than tabulated up front. A run is a
 handful of joints and a rig is a few dozen, so this is a few hundred integer
 comparisons; a cached table would have to be invalidated whenever the skeleton
 is rebuilt, which is every dot edit, to save less than the invalidation costs.

 @param out : `Receives the run, nearest first, so out[0] is the joint's own parent. A run longer than this is cut short — no rig placed by hand has one.`
 @return `How many were written. Zero for a root, and zero for a joint whose parent branches, which the caller has to answer for: there is nothing here that can move such a joint without moving its siblings.`
*>
fn usz Skeleton.ancestor_run(&self, usz joint, usz[] out) {
    usz count = self.joints.len;
    if (joint >= count || out.len == 0) return 0;

    usz written = 0;
    usz walk = joint;

    while (written < out.len) {
        int parent = self.parents[walk];
        if (parent < 0 || (usz)parent >= count) break;

        usz children = 0;
        foreach (usz i, int of : self.parents) {
            if (of == parent) children++;
        }
        if (children != 1) break;

        out[written++] = (usz)parent;
        walk = (usz)parent;
    }

    return written;
}

fn void Skeleton.free(&self, Allocator allocator) {
    if (self.joints.len > 0) alloc::free(allocator, self.joints);
    if (self.parents.len > 0) alloc::free(allocator, self.parents);
    *self = {};
}

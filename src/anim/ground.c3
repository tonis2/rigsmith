<*
 Putting a clip's feet on the floor, against whatever rig it is playing on.

 A cycle's root height is the one thing that cannot be authored portably. Where
 the hips have to sit for the stance foot to reach the ground is a fact about the
 *rig* — thigh length, shin length, how far the knee folds — and a keyframe that
 states it has stated it for one skeleton. Play the same clip on a figure with
 shorter legs and the feet sink; on longer legs they float. Measured on the pack
 authored in this repo: a run cycle solved on one mesh and replayed on another
 sank its feet by 3.3% of rig height, against 0.5% for the same cycle re-solved
 against the target.

 So the clip states *when* each foot is down and lets the rig answer *where*.
 The solve runs at pose time, inside `AnimTemplate.pose`, which means it runs
 against the skeleton actually in front of it — the player's, the exporter's, a
 test's — rather than the one the keyframes were written on.

 **The author writes no root Y.** The solve supplies stance height. It is added
 as a correction, but measured from the pose with the root slide already in it,
 so while any contact is planted it cancels an authored root Y outright — keyed
 or from a layer — and the pelvis height comes from how the legs bend. An
 authored root slide survives only while every foot is off the floor (and away
 from its edges), which is where a flight arc goes.
*>
module crig;

import rig;
import std::math;



<*
 One contact joint and the part of the cycle it spends on the floor.

 `down` and `up` are cycle phase — `AnimTemplate.phase_at`, 0 to 1 — rather than
 seconds, so retiming a clip moves its footfalls with it. A window wraps when
 `up` is at or below `down`, which is the ordinary case for whichever foot
 carries the loop point.

 A foot named here that the rig has no joint for is skipped rather than refused:
 a ground spec describes a body plan, and a rig missing a toe still walks on the
 ankles it has.
*>
struct AnimFoot
{
	String joint;
	float down;
	float up;
	// A contact that is not on the floor, such as a hand on a wall: planted and
	// measured, but the height solve leaves it alone.
	bool off_floor;
}

<*
 Which joints touch the ground, when, and what "the ground" means.

 An empty `feet` is the whole of "this clip has no ground solve", which is every
 clip written before this existed and every clip that has no business having one
 — a wave, a turret, anything that never touches a floor.

 `floor` is a height in the rig's own model space, not a fraction of anything: it
 is compared against joint positions, which arrive at whatever scale the mesh was
 exported at. Left unset it is the lowest contact joint's own rest height, which
 is where the modeller put the sole.
*>
struct AnimGround
{
	AnimFoot[] feet;
	float floor;
	bool floor_set;
}

<*
 Whether this spec asks for anything.
*>
fn bool AnimGround.solves(self) => self.feet.len > 0;

<*
 Release a ground spec an importer or a parser allocated.

 Mirrors `AnimTemplate.free`, and is called from it — a template owns its ground
 spec the same way it owns its keyframes.
*>
fn void AnimGround.free(&self, Allocator allocator)
{
	foreach (foot : self.feet)
	{
		if (foot.joint.len > 0) alloc::free(allocator, foot.joint.ptr);
	}
	if (self.feet.len > 0) alloc::free(allocator, self.feet);
	*self = {};
}

<*
 Whether the cycle is on this foot at `phase`.

 A window whose end is at or before its start wraps through the loop point, so
 `{ .down = 0.75, .up = 0.05 }` is the last eighth of the cycle and the first
 twentieth. That is not an edge case — one foot of a symmetric gait always
 straddles the seam.
*>
fn bool AnimFoot.planted(self, float phase)
{
	// A window that runs to the end of the cycle holds its end too: a clip that
	// does not loop reads its last frame as phase 1 (`phase_at`), and a landing
	// held to the end must still be down there.
	return self.up > self.down
		? phase >= self.down && (phase < self.up || self.up >= 1.0f)
		: phase >= self.down || phase < self.up;
}

<*
 How much of the cycle the window covers, 0 to 1; a wrapping window counts
 through the loop point.
*>
fn float AnimFoot.span(self) => self.up > self.down ? self.up - self.down : self.up + 1.0f - self.down;

<*
 What `ground_contacts` found: how many contact joints, how many are planted, and
 the floor height.
*>
struct GroundContacts
{
	usz count;
	usz planted;
	float floor;
}

<*
 The joints a ground spec puts on the floor for this rig, and where the floor is.

 What `ground_pose` solves against, pulled out so whatever edits a pose while it
 is shown grounded reads the same contacts the display is about to: a gesture
 that ignored them would finish by handing the body to the ground solve, which
 raises or drops the *whole* figure — pins and all — to put its feet back.

 @param contact : `Filled with the joint of each contact, in spec order; room for one per spec foot.`
 @param down : `Filled, per contact, with whether the clip has it on the floor at the phase.`
 @return `The count (0 when the rig has none of the spec's joints), how many are planted, and the floor height.`
*>
fn GroundContacts ground_contacts(
	rig::Skeleton* skeleton,
	String[] names,
	AnimGround ground,
	float phase,
	usz[] contact,
	bool[] down)
{
	GroundContacts found;
	usz count = skeleton.len();
	foreach (foot : ground.feet)
	{
		if (foot.joint.len == 0 || foot.off_floor || found.count >= contact.len || found.count >= down.len) continue;
		foreach (usz j, name : names)
		{
			if (name != foot.joint || j >= count) continue;
			contact[found.count] = j;
			down[found.count] = foot.planted(phase);
			if (down[found.count]) found.planted++;
			found.count++;
			break;
		}
	}
	if (found.count == 0) return found;

	// Where the ground is. The lowest sole at rest is where the modeller put the
	// figure's contact with it, and asking the rig beats asking the clip: a clip
	// carrying a number would be carrying the authoring mesh's scale.
	found.floor = ground.floor;
	if (!ground.floor_set)
	{
		found.floor = skeleton.joints[contact[0]].y;
		for (usz i = 1; i < found.count; i++)
		{
			found.floor = math::min(found.floor, skeleton.joints[contact[i]].y);
		}
	}
	return found;
}

<*
 Slide the root until the clip's feet are where the ground spec says they are.

 Two passes, and they do different jobs:

 1. **Plant.** Of the feet down at this phase, the lowest is put on the floor —
    signed, so a bent stance knee pulls the root *down*, which is what a stance
    is. The lowest rather than the highest, so a walk's double-support phase
    leaves the trailing foot above the floor instead of through it.
 2. **Keep out.** Then every contact joint, planted or not, is checked again and
    the root raised by whatever is still below the floor. Raise-only, so the
    price is a planted foot floating by a hair rather than a swinging one
    scything through the ground — and it holds on limb proportions nobody
    measured, which is the point of solving instead of authoring.

 Both move the offset of the root the feet actually hang from, found by walking
 up from the first contact joint. A root has no parent, so its offset is in world
 axes (see `rig::Pose.move`) and moving it is the whole figure rising or
 dropping, whichever joint the rig happens to be rooted at.

 Does nothing when the spec names no feet, when none of them is a joint of this
 rig, or when the pose and the skeleton disagree on joint count.

 @param names : `One name per joint, in joint order — the same array pose was built against.`
 @param pose : `Adjusted in place; nothing else about it is read back out.`
 @param phase : `Where in the cycle this pose is, 0 to 1.`
*>
fn void ground_pose(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimGround ground,
	rig::Pose* pose,
	float phase)
{
	if (!ground.solves()) return;

	usz count = skeleton.len();
	if (count == 0 || pose.offsets.len != count) return;

	usz[] contact = alloc::new_array(allocator, usz, (sz)ground.feet.len);
	bool[] down = alloc::new_array(allocator, bool, (sz)ground.feet.len);
	defer
	{
		alloc::free(allocator, contact);
		alloc::free(allocator, down);
	}

	GroundContacts found = ground_contacts(skeleton, names, ground, phase, contact, down);
	usz feet = found.count;
	usz planted = found.planted;
	if (feet == 0) return;
	float floor = found.floor;

	usz root = contact[0];
	while (skeleton.parents[root] >= 0) root = (usz)skeleton.parents[root];

	if (planted > 0)
	{
		float lowest;
		if (lowest_contact(allocator, skeleton, *pose, contact[:feet], down[:feet], true, &lowest))
		{
			pose.offsets[root].y += floor - lowest;
		}
	}
	else
	{
		pose.offsets[root].y += flight_correction(allocator, skeleton, names, ground, *pose, phase, contact[:feet], floor);
	}

	float sunk;
	if (lowest_contact(allocator, skeleton, *pose, contact[:feet], down[:feet], false, &sunk)
		&& sunk < floor)
	{
		pose.offsets[root].y += floor - sunk;
	}
}

// How much of the cycle, either side of a flight, a foot that has just left the
// floor or is about to land keeps a share of its plant: under a tenth of a run's
// cycle, a few frames.
const float GROUND_FLIGHT_BLEND = 0.08f;

<*
 The root's height correction while no foot is down.

 With a foot planted, the solve pulls the root down by however far that foot is
 off the floor — a bent stance knee lowers the body. With none planted there is
 nothing to plant, and a correction that simply stopped would drop the body back
 up by the whole stance pull at the instant of take-off, and down again at
 landing: a run with a flight phase, or a jump, popping twice a stride. So a foot
 that has just lifted keeps a share of its own plant, fading over
 GROUND_FLIGHT_BLEND of the cycle, and a foot about to land takes one on as it
 comes down — weighted by how near each is to its edge, and to nothing in the
 middle of a long flight, where the clip's own root keys carry the body.
*>
fn float flight_correction(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimGround ground,
	rig::Pose pose,
	float phase,
	usz[] contact,
	float floor) @local
{
	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, pose);
	if (catch built) return 0.0f;
	Matrix4f[] palette = built;
	defer alloc::free(allocator, palette);

	// The same feet, in the same order, `ground_contacts` found.
	float share = 0.0f;
	float sum = 0.0f;
	usz at = 0;
	foreach (foot : ground.feet)
	{
		if (at >= contact.len) break;
		if (foot.joint.len == 0 || foot.off_floor) continue;
		usz joint = contact[at];
		if (joint >= names.len || names[joint] != foot.joint) continue;
		at++;
		float weight = foot.flight_weight(phase);
		if (weight <= 0.0f) continue;
		float height = skeleton.joints[joint].transform(palette[joint]).y;
		sum += weight * (floor - height);
		share += weight;
	}
	return share > 1.0f ? sum / share : sum;
}

// How much of its plant a lifted foot keeps at `phase`: all of it at its window's
// edges, none from GROUND_FLIGHT_BLEND of the cycle away, eased between.
fn float AnimFoot.flight_weight(self, float phase)
{
	float after = phase - self.up;
	after -= math::floor(after);
	float before = self.down - phase;
	before -= math::floor(before);
	float near = math::min(after, before);
	if (near >= GROUND_FLIGHT_BLEND) return 0.0f;
	float s = near / GROUND_FLIGHT_BLEND;
	return 1.0f - s * s * (3.0f - 2.0f * s);
}

<*
 The lowest world height any of these joints reaches in this pose.

 A palette entry applied to its joint's rest position is where the pose put that
 joint — the same arithmetic the posed overlay reads — so this is one
 `joint_palette` and a walk, not a second kinematic chain that could disagree
 with the first.

 @param planted_only : `Restrict to the joints marked down; false measures all of them.`
 @return `False when the palette could not be built, or nothing was measured.`
*>
fn bool lowest_contact(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose pose,
	usz[] contact,
	bool[] down,
	bool planted_only,
	float* lowest) @local
{
	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, pose);
	if (catch built) return false;
	Matrix4f[] palette = built;
	defer alloc::free(allocator, palette);

	bool found = false;
	foreach (usz i, joint : contact)
	{
		if (planted_only && !down[i]) continue;

		Vec3 moved = skeleton.joints[joint].transform(palette[joint]);
		if (!found || moved.y < *lowest) *lowest = moved.y;
		found = true;
	}
	return found;
}

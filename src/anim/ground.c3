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
import std::math::quaternion;



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

 A contact is measured by its own joint (`joint_clearance`), a foot's against
 where it stood at rest. The toes under an ankle are not what holds the body up:
 a clip that points them into the floor — mid-swing, or landing toes first — has
 them turned up at the ankle (`lift_toes`), so they skim the floor and the body
 does not hop for them.

 Two passes, and they do different jobs:

 1. **Plant.** Of the feet down at this phase, the lowest is put on the floor —
    signed, so a bent stance knee pulls the root *down*, which is what a stance
    is. The lowest rather than the highest, so a walk's double-support phase
    leaves the trailing foot above the floor instead of through it.
 2. **Keep out.** Then every contact, planted or not, and every other foot of the
    rig is checked again and the root raised by whatever is still below the
    floor. Raise-only, so the price is a planted foot floating by a hair rather
    than a swinging one scything through the ground — and it holds on limb
    proportions nobody measured, which is the point of solving instead of
    authoring. A foot the spec leaves out is kept out too: a spec naming one foot
    must not drive the other through the floor.

 Both move the offset of the root the feet actually hang from, found by walking
 up from the first contact joint. A root has no parent, so its offset is in world
 axes (see `rig::Pose.move`) and moving it is the whole figure rising or
 dropping, whichever joint the rig happens to be rooted at — every height below
 moves by the same amount, so one palette measures both passes.

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
	if (feet == 0) return;

	usz root = contact[0];
	while (skeleton.parents[root] >= 0) root = (usz)skeleton.parents[root];

	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(allocator, palette);
	GroundFloor level = floor_of_solve(skeleton, contact[:feet], found.floor, ground.floor_set);

	float lift = 0.0f;
	if (found.planted > 0)
	{
		float lowest = GROUND_FAR;
		for (usz i = 0; i < feet; i++)
		{
			if (down[i]) lowest = math::min(lowest, joint_clearance(skeleton, palette, contact[i], level));
		}
		lift = -lowest;
	}
	else
	{
		lift = flight_correction(skeleton, names, ground, palette, phase, contact[:feet], level);
	}

	float sunk = GROUND_FAR;
	for (usz i = 0; i < feet; i++) sunk = math::min(sunk, joint_clearance(skeleton, palette, contact[i], level));
	for (usz j = 0; j < count; j++)
	{
		if (!level.foot_top(skeleton, j) || tree_root(skeleton, j) != root) continue;
		if (foot_in_spec(skeleton, names, ground, j)) continue;
		sunk = math::min(sunk, skeleton.joints[j].transform(palette[j]).y - (skeleton.joints[j].y + level.shift));
	}
	if (sunk + lift < 0.0f) lift = -sunk;
	pose.offsets[root].y += lift;

	// A foot whose toes the clip points through the floor — swinging, or landing
	// toes first — is turned up at its ankle rather than the body raised for it:
	// raising the body for every swing is a hop a step.
	for (usz j = 0; j < count; j++)
	{
		if (!level.foot_top(skeleton, j) || tree_root(skeleton, j) != root) continue;
		FootInSpec held = foot_in_spec_of(skeleton, names, ground, contact[:feet], j);
		if (held.off_floor) continue;
		float shift = held.named && level.floor_set ? level.floor - skeleton.joints[held.joint].y : level.shift;
		lift_toes(allocator, skeleton, pose, j, shift);
	}
}

<*
 How far a contact joint is above the floor in this pose; negative is through it.
 A joint of a foot is measured against where it stood at rest, or the spec's
 floor when one is set; any other joint, a knee put down in a kneel, against the
 floor. The joint alone: the toes under an ankle are turned clear instead
 (`lift_toes`), so a clip that points them into the floor does not lift the body.

 @param palette : `rig::joint_palette of the pose.`
*>
fn float joint_clearance(rig::Skeleton* skeleton, Matrix4f[] palette, usz joint, GroundFloor level)
{
	float at = skeleton.joints[joint].transform(palette[joint]).y;
	if (!level.rests_low(skeleton, joint) || level.floor_set) return at - level.floor;
	return at - skeleton.joints[joint].y;
}

// What a ground spec says about the foot topped by one joint.
struct FootInSpec @local
{
	bool named;
	bool off_floor;
	// The first joint of the foot the spec names, when `named`.
	usz joint;
}

fn FootInSpec foot_in_spec_of(rig::Skeleton* skeleton, String[] names, AnimGround ground, usz[] contact, usz top) @local
{
	FootInSpec held;
	foreach (foot : ground.feet)
	{
		if (!foot.off_floor) continue;
		foreach (usz j, name : names)
		{
			if (j < skeleton.len() && name == foot.joint && joint_under(skeleton, top, j)) held.off_floor = true;
		}
	}
	foreach (j : contact)
	{
		if (!joint_under(skeleton, top, j)) continue;
		if (!held.named) held.joint = j;
		held.named = true;
	}
	return held;
}

<*
 Turn the foot topped by `top` up about it, the way it faces, until no joint under
 it is below where it stood at rest (raised by `shift`). The joint that would be
 lowest is lifted onto that height; a few rounds catch a toe that becomes the
 lowest once the tip is lifted.
*>
fn void lift_toes(Allocator allocator, rig::Skeleton* skeleton, rig::Pose* pose, usz top, float shift) @local
{
	const Vec3 UP = { 0, 1, 0 };
	for (usz round = 0; round < 3; round++)
	{
		Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
		if (catch built) return;
		Matrix4f[] palette = built;
		defer alloc::free(allocator, palette);
		Vec3 pivot = skeleton.joints[top].transform(palette[top]);
		float least = -1.0e-6f;
		sz lowest = -1;
		for (usz j = 0; j < skeleton.len(); j++)
		{
			if (j == top || !joint_under(skeleton, top, j)) continue;
			float above = skeleton.joints[j].transform(palette[j]).y - (skeleton.joints[j].y + shift);
			if (above < least) { least = above; lowest = (sz)j; }
		}
		if (lowest < 0) return;
		Vec3 reach = skeleton.joints[(usz)lowest].transform(palette[(usz)lowest]) - pivot;
		float length = reach.length();
		Vec3 axis = reach.cross(UP);
		if (length < 1.0e-6f || axis.length() < 1.0e-6f) return;
		float now = math::asin(math::clamp(reach.y / length, -1.0f, 1.0f));
		float wanted = math::asin(math::clamp((reach.y - least) / length, -1.0f, 1.0f));
		if (wanted <= now) return;
		Quaternionf[]? read = pose.world_rotations(allocator, skeleton);
		if (catch read) return;
		Quaternionf[] world = read;
		defer alloc::free(allocator, world);
		int parent = skeleton.parents[top];
		Quaternionf above = parent >= 0 ? world[(usz)parent] : quaternion::IDENTITY;
		Quaternionf turn = quaternion::from_axis_angle{float}(axis.normalize(), wanted - now);
		pose.rotations[top] = above.invert().mul(turn).mul(above).mul(pose.rotations[top]).normalize();
	}
}

<*
 What the floor is for one solve: the height a contact that is no foot is put at,
 whether the spec set it, and how far a set floor sits from the lowest contact's
 rest height, which a foot the spec leaves out is carried by.
*>
struct GroundFloor
{
	float floor;
	bool floor_set;
	float shift;
	// The rig's lowest joint at rest, and the band over it a foot rests within.
	float low;
	float band;
}

// A joint resting within this fraction of the rig's height over its lowest joint
// is part of a foot: an ankle, its toes. A hand is not.
const float GROUND_FOOT_BAND = 0.12f;
// Further than any foot is from the floor: where a search for the lowest starts.
const float GROUND_FAR = 1.0e30f;

fn GroundFloor floor_of_solve(rig::Skeleton* skeleton, usz[] contact, float floor, bool floor_set)
{
	GroundFloor level = { .floor = floor, .floor_set = floor_set };
	if (skeleton.len() == 0) return level;
	level.low = skeleton.joints[0].y;
	foreach (at : skeleton.joints) level.low = math::min(level.low, at.y);
	level.band = GROUND_FOOT_BAND * skeleton.height();
	if (!floor_set || contact.len == 0) return level;
	float rest = skeleton.joints[contact[0]].y;
	foreach (j : contact) rest = math::min(rest, skeleton.joints[j].y);
	level.shift = floor - rest;
	return level;
}

// Whether `joint` rests near the floor, as a foot's joints do.
fn bool GroundFloor.rests_low(self, rig::Skeleton* skeleton, usz joint)
	=> skeleton.joints[joint].y <= self.low + self.band;

// Whether `joint` is the top of a foot: resting low under a parent that does not.
fn bool GroundFloor.foot_top(self, rig::Skeleton* skeleton, usz joint)
{
	if (!self.rests_low(skeleton, joint)) return false;
	int parent = skeleton.parents[joint];
	return parent < 0 || !self.rests_low(skeleton, (usz)parent);
}

<*
 The top of the foot `joint` is part of: up from it while the parent rests low
 too, so the ankle over a toe. A joint that does not rest low is its own.
*>
fn usz GroundFloor.foot_of(self, rig::Skeleton* skeleton, usz joint)
{
	if (!self.rests_low(skeleton, joint)) return joint;
	usz top = joint;
	while (skeleton.parents[top] >= 0 && self.rests_low(skeleton, (usz)skeleton.parents[top]))
	{
		top = (usz)skeleton.parents[top];
	}
	return top;
}

// Whether `joint` is `top` or hangs under it.
fn bool joint_under(rig::Skeleton* skeleton, usz top, usz joint)
{
	for (sz at = (sz)joint; at >= 0; at = skeleton.parents[(usz)at])
	{
		if ((usz)at == top) return true;
	}
	return false;
}

fn usz tree_root(rig::Skeleton* skeleton, usz joint) @local
{
	while (skeleton.parents[joint] >= 0) joint = (usz)skeleton.parents[joint];
	return joint;
}

// Whether the spec names a joint of the foot topped by `top`: that foot is
// measured by what the spec says, not kept out whole.
fn bool foot_in_spec(rig::Skeleton* skeleton, String[] names, AnimGround ground, usz top) @local
{
	foreach (foot : ground.feet)
	{
		foreach (usz j, name : names)
		{
			if (j < skeleton.len() && name == foot.joint && joint_under(skeleton, top, j)) return true;
		}
	}
	return false;
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
	rig::Skeleton* skeleton,
	String[] names,
	AnimGround ground,
	Matrix4f[] palette,
	float phase,
	usz[] contact,
	GroundFloor level) @local
{
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
		sum -= weight * joint_clearance(skeleton, palette, joint, level);
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

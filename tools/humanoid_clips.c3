<*
 Clips for the humanoid plan, written in world angles.

 	`crig::AnimTemplate[] clips = make_anims::humanoid_clips(mem);`

 The other clip tables here state each joint's turn **relative to its parent**,
 which is what a keyframe stores and what makes them short. That works while the
 joint's parent is at rest, and stops working the moment it is not: a keyframe
 entry's axis is read in the parent's *posed* frame, so once the shoulder has
 swung the upper arm down through seventy-odd degrees, the axis that bends the
 elbow forward is no longer world x — it is world x turned by however far the
 shoulder went. On a rig that rests in a T-pose and animates with its arms down,
 which is this one, every single arm entry has that problem.

 So the poses below say where a bone *points*, in the world, and the conversion
 to parent-relative happens in `humanoid_keys`. Three angles per joint, applied
 in a fixed order — roll, then pitch, then yaw — and a fourth before them:

 	`twist`  about the bone's own rest axis, before anything else, so it turns
 	         the limb without moving it. What a wave needs: the upper arm rolled
 	         so the elbow's hinge lies flat, and the forearm rising *up* is then
 	         an elbow bending the one way an elbow bends. Positive is the
 	         right-hand rule about the bone pointing away from the body, which
 	         on either arm turns the palm forward.
 	`pitch`  about world x. Swings a limb fore and aft: **negative is forward**,
 	         for a leg hanging down and for an arm already brought down by roll.
 	         On the spine it is the lean, and negative is again forward.
 	`yaw`    about world y. Turns the figure or twists the spine; positive turns
 	         the chest and face towards the figure's left.
 	`roll`   about world z. What brings a T-posed arm down: the left arm needs
 	         `-down`, the right arm `+down`, where `down` is degrees below
 	         horizontal. So -90 raises the right arm straight up and +90 the left.

 The poses respect the rotation limits `core/limit_defaults.c3` gives these
 joints, and a check in test/limit_defaults_test.c3 says so: a clip that bends
 an elbow sideways plays clamped on the shipped rig, and this is where it is
 caught rather than on screen.

 **Naming a joint states its orientation absolutely**, not as a correction to its
 parent. A joint no pose names inherits its parent's orientation exactly, which
 is rest — so the fingers below stay straight without a word being written about
 any of the forty of them, and the legs stay standing through the whole idle.
 The flip side is that writing `head` with all three angles zero holds the head
 level in the world while the chest turns underneath it, which is a real thing to
 want and not a way of saying "leave it alone".

 **Except a hinge.** An entry marked `relative` reads its angles about the rest
 axes *carried by its parent's turn*, which is the one case the absolute form
 is bad at: an elbow bends about an axis fixed in the upper arm, wherever the
 upper arm has gone, and the world angle that bends it changes with every pose
 of the shoulder. So the wave's elbow says `.relative = true, .yaw = 46°` —
 forty-six degrees about the arm's own hinge — and is the same elbow at every
 twist of the shoulder above it.

 Degrees, because nobody authors a walk in radians.
*>
module make_anims;

import crig;
import rig;
import std::io;
import std::math;
import std::math::vector;
import std::math::quaternion;



const float DEG = 0.017453293f;

<*
 One joint's orientation in a pose being authored, in world axes.

 See the module comment for the three angles and the order they compose in. All
 zero is a joint held at its rest orientation in the world — not a joint left
 alone, which is what omitting it does.
*>
struct HumanTurn
{
	String joint;   // a name from `humanoid_dots`
	float pitch;    // about world x, radians
	float yaw;      // about world y, radians
	float roll;     // about world z, radians
	float twist;    // about the bone's rest axis, radians, applied first
	bool relative;  // the angles are about the rest axes as the parent carries them
	Vec3 move;      // fraction of rig height; the root's, and nothing else's
}

<*
 A pose as the keyframe entries it turns into.

 	`crig::AnimKeyDot[] dots = humanoid_keys(mem, HUMAN_WALK_CONTACT_L[..]);`

 Walks `humanoid_dots` once, root first, composing each joint's world turn and
 dividing out its parent's — the same `Rw_i = Rw_parent · R_i` relation
 `AnimTemplate.pose` reads the entries back through, run backwards. A joint no
 pose names takes its parent's world turn unchanged, which divides out to
 identity, which is rest.

 One pass suffices because the table is written parents-before-children, the
 invariant `PresetDot.parent` states and `joint_palette` also relies on.

 A pose naming a joint the table does not carry is a typo that would otherwise
 animate nothing and say nothing, so it is reported here rather than at the
 moment somebody notices an arm is not moving.

 The caller owns the returned array.
*>
fn crig::AnimKeyDot[] humanoid_keys(Allocator allocator, HumanTurn[] pose, bool[] keyed = {})
{
	usz count = humanoid_dots.len;

	Quaternionf[] world = alloc::new_array(allocator, Quaternionf, (sz)count);
	int[] source = alloc::new_array(allocator, int, (sz)count);
	defer
	{
		alloc::free(allocator, world);
		alloc::free(allocator, source);
	}

	usz driven = 0;
	foreach (usz i, dot : humanoid_dots)
	{
		int parent = dot.parent;
		Quaternionf from_parent = parent >= 0 ? world[(usz)parent] : quaternion::IDENTITY;

		source[i] = named_by(pose, dot.name);
		if (source[i] < 0)
		{
			world[i] = from_parent;
			continue;
		}
		HumanTurn turn = pose[(usz)source[i]];
		Quaternionf own = world_turn(turn, rest_bone(i));
		world[i] = turn.relative ? from_parent.mul(own).normalize() : own;
		if (keyed.len == 0) driven++;
	}
	if (keyed.len > 0) foreach (held : keyed) if (held) driven++;

	foreach (turn : pose)
	{
		if (row_of(turn.joint) < 0) io::printfn("  ! no joint named \"%s\" in the humanoid plan", turn.joint);
	}

	crig::AnimKeyDot[] out = alloc::new_array(allocator, crig::AnimKeyDot, (sz)driven);
	usz next = 0;
	foreach (usz i, dot : humanoid_dots)
	{
		if (keyed.len > 0 ? !keyed[i] : source[i] < 0) continue;

		int parent = dot.parent;
		Quaternionf from_parent = parent >= 0 ? world[(usz)parent] : quaternion::IDENTITY;
		Quaternionf local = from_parent.invert().mul(world[i]).normalize();

		Vec3 move = source[i] >= 0 ? pose[(usz)source[i]].move : (Vec3){};
		crig::AnimKeyDot key = { .joint_name = dot.name, .move = move };
		crig::axis_angle_of(local, &key.axis, &key.angle);
		out[next++] = key;
	}
	return out;
}

// Twist first, then roll, then pitch, then yaw — see the module comment.
// Composed as world turns, so `yaw.mul(pitch)` is yaw applied *after* pitch,
// matching the order `AnimTemplate.pose` composes a chain in.
fn Quaternionf world_turn(HumanTurn turn, Vec3 bone) @local
{
	Quaternionf twist = quaternion::from_axis_angle{float}(bone, turn.twist);
	Quaternionf roll = quaternion::from_axis_angle{float}((Vec3){ 0, 0, 1 }, turn.roll);
	Quaternionf pitch = quaternion::from_axis_angle{float}((Vec3){ 1, 0, 0 }, turn.pitch);
	Quaternionf yaw = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, turn.yaw);
	return yaw.mul(pitch).mul(roll).mul(twist).normalize();
}

// Which way the bone below row `i` of the plan points at rest: to its first
// child in the table, or on from its parent for a tip. What `twist` turns
// about — a unit vector, so a joint with nothing below it and nothing above it
// (there is none) would get one along x.
fn Vec3 rest_bone(usz i) @local
{
	foreach (dot : humanoid_dots)
	{
		if (dot.parent != (int)i) continue;
		Vec3 along = dot.at - humanoid_dots[i].at;
		if (along.length_sq() > 1.0e-12f) return along.normalize();
	}
	int parent = humanoid_dots[i].parent;
	if (parent < 0) return { 1, 0, 0 };
	Vec3 along = humanoid_dots[i].at - humanoid_dots[(usz)parent].at;
	return along.length_sq() > 1.0e-12f ? along.normalize() : (Vec3){ 1, 0, 0 };
}

// Which entry of `pose` drives the joint `name` names, or -1. Linear, over at
// most a few dozen entries, a few hundred times in the life of the tool.
fn int named_by(HumanTurn[] pose, String name) @local
{
	foreach (usz i, turn : pose)
	{
		if (turn.joint == name) return (int)i;
	}
	return -1;
}

// Which row of the plan a pose entry names, or -1 — the same question the other
// way round, and the one that catches a misspelling.
fn int row_of(String joint) @local
{
	foreach (usz i, dot : humanoid_dots)
	{
		if (dot.name == joint) return (int)i;
	}
	return -1;
}

// ---------------------------------------------------------------------------
// Idle.
//
// A figure standing still is never actually still: it breathes, and the breath
// travels up the spine and dies out at the head. Two poses, three and a bit
// seconds apart, and the pelvis carrying a few millimetres of rise and fall so
// the whole figure participates rather than only its ribs.
//
// The arms are named in both poses and the legs in neither. That is the point of
// authoring absolutely: the legs are standing at rest already, and the arms are
// not, because the rig rests in a T-pose.

const float HUMAN_IDLE_ARM_DOWN = 76.0f;

const HumanTurn[] HUMAN_IDLE_SETTLED = {
	{ .joint = "hips",        .move = { 0, -0.004, 0 } },
	{ .joint = "spine",       .pitch =  2.0f * DEG },
	{ .joint = "upper_spine", .pitch =  3.0f * DEG },
	{ .joint = "chest",       .pitch =  2.0f * DEG },
	{ .joint = "neck",        .pitch = -3.0f * DEG },
	{ .joint = "head",        .pitch =  0.0f * DEG },

	{ .joint = "shoulder_L",  .roll = -HUMAN_IDLE_ARM_DOWN * DEG, .pitch =  -5.0f * DEG },
	{ .joint = "elbow_L",     .roll = -HUMAN_IDLE_ARM_DOWN * DEG, .pitch = -18.0f * DEG },
	{ .joint = "shoulder_R",  .roll =  HUMAN_IDLE_ARM_DOWN * DEG, .pitch =  -5.0f * DEG },
	{ .joint = "elbow_R",     .roll =  HUMAN_IDLE_ARM_DOWN * DEG, .pitch = -18.0f * DEG },
};

const HumanTurn[] HUMAN_IDLE_BREATH = {
	{ .joint = "hips",        .move = { 0, 0.004, 0 } },
	{ .joint = "spine",       .pitch =  0.0f * DEG },
	{ .joint = "upper_spine", .pitch =  0.0f * DEG },
	{ .joint = "chest",       .pitch = -1.0f * DEG },
	{ .joint = "neck",        .pitch =  0.0f * DEG },
	{ .joint = "head",        .pitch = -1.0f * DEG },

	{ .joint = "shoulder_L",  .roll = -74.0f * DEG, .pitch =  -3.0f * DEG },
	{ .joint = "elbow_L",     .roll = -74.0f * DEG, .pitch = -15.0f * DEG },
	{ .joint = "shoulder_R",  .roll =  74.0f * DEG, .pitch =  -3.0f * DEG },
	{ .joint = "elbow_R",     .roll =  74.0f * DEG, .pitch = -15.0f * DEG },
};

// ---------------------------------------------------------------------------
// Walk.
//
// Four poses a quarter-second apart — contact, passing, contact mirrored,
// passing mirrored — and a fifth repeating the first so the loop closes on the
// pose it opened with.
//
// Contact is the pose a walk is recognisable from: one leg reaching forward with
// the heel about to land, the other trailing with the heel lifted. Passing is
// what makes it a walk rather than a scissor — the swinging leg folds under the
// body and clears the ground while the standing leg carries the weight straight.
//
// The pelvis carries the bob, which is the one thing only a translation can do.
// Legs are a fixed length, so a figure standing with its feet apart is shorter
// than one standing with them together: hold the pelvis level through a stride
// and the leading foot has to hang in the air to reach it. It drops at both
// contacts and rises at both passings — twice a cycle, which is the rhythm a
// walk actually has.
//
// The hips are never turned, only slid. They are the root, so turning them turns
// the whole figure, and a walk that rocks the entire body reads as a stumble.
// The counter-rotation lives on `Spine1` and `Spine2`, which is where a person's
// is: shoulders one way, pelvis the other.
//
// Arms oppose legs — the leg reaching forward is the arm swinging back — and
// both elbows stay bent through the whole cycle, more on the arm that is behind.
// A walking human does not straighten an arm.

const float HUMAN_WALK_BOB = 0.022f;      // fraction of rig height
const float HUMAN_ARM_DOWN = 74.0f;

const HumanTurn[] HUMAN_WALK_CONTACT_L = {
	{ .joint = "hips",        .move = { 0, -HUMAN_WALK_BOB, 0 } },
	{ .joint = "spine",       .pitch =  2.0f * DEG },
	{ .joint = "upper_spine", .pitch =  2.0f * DEG, .yaw =  4.0f * DEG },
	{ .joint = "chest",       .pitch =  2.0f * DEG, .yaw =  4.0f * DEG },
	{ .joint = "neck",        .pitch = -2.0f * DEG },
	{ .joint = "head",        .pitch =  0.0f * DEG },

	{ .joint = "thigh_L",     .pitch = -22.0f * DEG },
	{ .joint = "knee_L",      .pitch = -19.0f * DEG },
	{ .joint = "ankle_L",     .pitch = -26.0f * DEG },
	{ .joint = "thigh_R",     .pitch =  18.0f * DEG },
	{ .joint = "knee_R",      .pitch =  33.0f * DEG },
	{ .joint = "ankle_R",     .pitch =  50.0f * DEG },

	{ .joint = "shoulder_L",  .roll = -HUMAN_ARM_DOWN * DEG, .pitch =  18.0f * DEG },
	{ .joint = "elbow_L",     .roll = -HUMAN_ARM_DOWN * DEG, .pitch = -12.0f * DEG },
	{ .joint = "shoulder_R",  .roll =  HUMAN_ARM_DOWN * DEG, .pitch = -18.0f * DEG },
	{ .joint = "elbow_R",     .roll =  HUMAN_ARM_DOWN * DEG, .pitch = -40.0f * DEG },
};

const HumanTurn[] HUMAN_WALK_PASS_L = {
	{ .joint = "hips",        .move = { 0, 0, 0 } },
	{ .joint = "spine",       .pitch =  2.0f * DEG },
	{ .joint = "upper_spine", .pitch =  2.0f * DEG, .yaw = 0.0f * DEG },
	{ .joint = "chest",       .pitch =  2.0f * DEG, .yaw = 0.0f * DEG },
	{ .joint = "neck",        .pitch = -2.0f * DEG },
	{ .joint = "head",        .pitch =  0.0f * DEG },

	{ .joint = "thigh_L",     .pitch =  1.0f * DEG },
	{ .joint = "knee_L",      .pitch =  3.0f * DEG },
	{ .joint = "ankle_L",     .pitch =  4.0f * DEG },
	{ .joint = "thigh_R",     .pitch = -7.0f * DEG },
	{ .joint = "knee_R",      .pitch = 34.0f * DEG }, // folds the foot clear of the floor
	{ .joint = "ankle_R",     .pitch = 25.0f * DEG },

	{ .joint = "shoulder_L",  .roll = -HUMAN_ARM_DOWN * DEG, .pitch =   3.0f * DEG },
	{ .joint = "elbow_L",     .roll = -HUMAN_ARM_DOWN * DEG, .pitch = -22.0f * DEG },
	{ .joint = "shoulder_R",  .roll =  HUMAN_ARM_DOWN * DEG, .pitch =  -3.0f * DEG },
	{ .joint = "elbow_R",     .roll =  HUMAN_ARM_DOWN * DEG, .pitch = -28.0f * DEG },
};

// The two above with the sides exchanged. Written out rather than reflected in
// code: a mirror has to negate the yaw and swap the legs but *not* swap the
// arms' roll, since each arm keeps its own side's sign, and a routine with that
// many exceptions is harder to check than two tables read against each other.
const HumanTurn[] HUMAN_WALK_CONTACT_R = {
	{ .joint = "hips",        .move = { 0, -HUMAN_WALK_BOB, 0 } },
	{ .joint = "spine",       .pitch =  2.0f * DEG },
	{ .joint = "upper_spine", .pitch =  2.0f * DEG, .yaw = -4.0f * DEG },
	{ .joint = "chest",       .pitch =  2.0f * DEG, .yaw = -4.0f * DEG },
	{ .joint = "neck",        .pitch = -2.0f * DEG },
	{ .joint = "head",        .pitch =  0.0f * DEG },

	{ .joint = "thigh_R",     .pitch = -22.0f * DEG },
	{ .joint = "knee_R",      .pitch = -19.0f * DEG },
	{ .joint = "ankle_R",     .pitch = -26.0f * DEG },
	{ .joint = "thigh_L",     .pitch =  18.0f * DEG },
	{ .joint = "knee_L",      .pitch =  33.0f * DEG },
	{ .joint = "ankle_L",     .pitch =  50.0f * DEG },

	{ .joint = "shoulder_R",  .roll =  HUMAN_ARM_DOWN * DEG, .pitch =  18.0f * DEG },
	{ .joint = "elbow_R",     .roll =  HUMAN_ARM_DOWN * DEG, .pitch = -12.0f * DEG },
	{ .joint = "shoulder_L",  .roll = -HUMAN_ARM_DOWN * DEG, .pitch = -18.0f * DEG },
	{ .joint = "elbow_L",     .roll = -HUMAN_ARM_DOWN * DEG, .pitch = -40.0f * DEG },
};

const HumanTurn[] HUMAN_WALK_PASS_R = {
	{ .joint = "hips",        .move = { 0, 0, 0 } },
	{ .joint = "spine",       .pitch =  2.0f * DEG },
	{ .joint = "upper_spine", .pitch =  2.0f * DEG, .yaw = 0.0f * DEG },
	{ .joint = "chest",       .pitch =  2.0f * DEG, .yaw = 0.0f * DEG },
	{ .joint = "neck",        .pitch = -2.0f * DEG },
	{ .joint = "head",        .pitch =  0.0f * DEG },

	{ .joint = "thigh_R",     .pitch =  1.0f * DEG },
	{ .joint = "knee_R",      .pitch =  3.0f * DEG },
	{ .joint = "ankle_R",     .pitch =  4.0f * DEG },
	{ .joint = "thigh_L",     .pitch = -7.0f * DEG },
	{ .joint = "knee_L",      .pitch = 34.0f * DEG },
	{ .joint = "ankle_L",     .pitch = 25.0f * DEG },

	{ .joint = "shoulder_R",  .roll =  HUMAN_ARM_DOWN * DEG, .pitch =   3.0f * DEG },
	{ .joint = "elbow_R",     .roll =  HUMAN_ARM_DOWN * DEG, .pitch = -22.0f * DEG },
	{ .joint = "shoulder_L",  .roll = -HUMAN_ARM_DOWN * DEG, .pitch =  -3.0f * DEG },
	{ .joint = "elbow_L",     .roll = -HUMAN_ARM_DOWN * DEG, .pitch = -28.0f * DEG },
};

// ---------------------------------------------------------------------------
// Wave.
//
// The right arm up and the forearm rocking about vertical; everything else held
// where the idle holds it. Two poses alternating, which is all a wave is.
//
// It earns its place in the pack by being the one clip that drives a chain the
// walk barely touches — a shoulder past horizontal, an elbow near its limit —
// which is exactly where a bad weight on the deltoid shows up.
//
// The upper arm is twisted outward, palm forward, which is how a person holds
// it: an elbow is a hinge, and with the upper arm as it rests the hinge would
// fold the forearm *forward*, not up. The elbow is then written as the hinge it
// is — relative, about the axis the arm carries — and the forearm rises where
// the twist points it. Sixty degrees rather than the full quarter turn: at
// ninety the three-angle reading of the shoulder is at its singularity, and a
// limit table cannot clamp what it cannot read.

const float HUMAN_WAVE_TWIST = 60.0f;

const HumanTurn[] HUMAN_WAVE_OUT = {
	{ .joint = "upper_spine", .yaw = -6.0f * DEG },
	{ .joint = "chest",       .yaw = -6.0f * DEG },
	{ .joint = "neck",        .pitch = -2.0f * DEG, .yaw = -4.0f * DEG },
	{ .joint = "head",        .pitch = -4.0f * DEG, .yaw = -6.0f * DEG },

	{ .joint = "shoulder_R",  .roll = -58.0f * DEG, .pitch = -12.0f * DEG, .twist = HUMAN_WAVE_TWIST * DEG },
	{ .joint = "elbow_R",     .relative = true, .yaw = 14.0f * DEG },

	{ .joint = "shoulder_L",  .roll = -76.0f * DEG, .pitch =  -6.0f * DEG },
	{ .joint = "elbow_L",     .roll = -76.0f * DEG, .pitch = -20.0f * DEG },
};

const HumanTurn[] HUMAN_WAVE_IN = {
	{ .joint = "upper_spine", .yaw = -6.0f * DEG },
	{ .joint = "chest",       .yaw = -6.0f * DEG },
	{ .joint = "neck",        .pitch = -2.0f * DEG, .yaw = -4.0f * DEG },
	{ .joint = "head",        .pitch = -4.0f * DEG, .yaw = -6.0f * DEG },

	{ .joint = "shoulder_R",  .roll = -58.0f * DEG, .pitch = -12.0f * DEG, .twist = HUMAN_WAVE_TWIST * DEG },
	{ .joint = "elbow_R",     .relative = true, .yaw = 46.0f * DEG },

	{ .joint = "shoulder_L",  .roll = -76.0f * DEG, .pitch =  -6.0f * DEG },
	{ .joint = "elbow_L",     .roll = -76.0f * DEG, .pitch = -20.0f * DEG },
};

<*
 The three clips the humanoid pack ships with, in the order the library shows
 them.

 Built here rather than declared as constants because every entry is computed:
 the tables above are world orientations and a keyframe holds parent-relative
 ones, and the conversion needs the plan's hierarchy to walk.

 The caller owns the templates, their keyframes and the entries inside them.
*>
fn crig::AnimTemplate[] humanoid_clips(Allocator allocator)
{
	crig::AnimTemplate[] clips = alloc::new_array(allocator, crig::AnimTemplate, 3);

	clips[0] = humanoid_clip(allocator, "Walk", 1.0f,
		{ 0.00f, 0.25f, 0.50f, 0.75f, 1.00f },
		{ HUMAN_WALK_CONTACT_L[..], HUMAN_WALK_PASS_L[..], HUMAN_WALK_CONTACT_R[..], HUMAN_WALK_PASS_R[..], HUMAN_WALK_CONTACT_L[..] });

	clips[1] = humanoid_clip(allocator, "Stand", 3.2f,
		{ 0.0f, 1.6f, 3.2f },
		{ HUMAN_IDLE_SETTLED[..], HUMAN_IDLE_BREATH[..], HUMAN_IDLE_SETTLED[..] });

	clips[2] = humanoid_clip(allocator, "Wave", 1.6f,
		{ 0.0f, 0.4f, 0.8f, 1.2f, 1.6f },
		{ HUMAN_WAVE_OUT[..], HUMAN_WAVE_IN[..], HUMAN_WAVE_OUT[..], HUMAN_WAVE_IN[..], HUMAN_WAVE_OUT[..] });

	return clips;
}

// One clip from a list of times and the pose at each. Every clip here loops, so
// there is no flag to pass.
fn crig::AnimTemplate humanoid_clip(
	Allocator allocator,
	String name,
	float duration,
	float[] times,
	HumanTurn[][] poses) @local
{
	// Before sparse tracks, an omitted entry at a global key meant an explicit
	// rest pose. Preserve that authored motion by densely keying the union of
	// joints mentioned anywhere in this clip, including identity entries.
	bool[] keyed = alloc::new_array(allocator, bool, (sz)humanoid_dots.len);
	defer alloc::free(allocator, keyed);
	foreach (pose : poses)
	{
		foreach (turn : pose)
		{
			sz row = row_of(turn.joint);
			if (row >= 0) keyed[(usz)row] = true;
		}
	}
	crig::AnimKeyframe[] frames = alloc::new_array(allocator, crig::AnimKeyframe, (sz)times.len);
	foreach (usz i, time : times)
	{
		frames[i] = { .time = time, .dots = humanoid_keys(allocator, poses[i], keyed) };
	}
	return { .name = name, .duration = duration, .keyframes = frames, .loop = true };
}

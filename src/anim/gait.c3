<*
 Gaits: a walking, trotting or galloping cycle written from a rig's own legs.

 Posing a leg by angle means guessing a hip, a knee and a hock until a paw lands
 where it was wanted, then doing it again for every instant of a cycle. A gait is
 easier to state as *where each foot is when*: the stance slides it backward at a
 constant speed along the floor, the swing carries it forward through a lifted
 arc, and each foot keeps its own place in the cycle. This file does that
 statement and turns it into keys — the leg angles that put every foot on its
 path — for any rig that has legs, rather than for one skeleton.

 ## What a leg is

 A leg is the run of joints from the first one below a fork (hip, shoulder,
 thigh) down to the foot — the lowest joint whose child is a toe. Two to four
 bones: a human leg is thigh, shin and foot; a dog's hind leg adds the metatarsal.
 The foot joint is the one the floor meets, so it is what the ground spec names
 and what the path is drawn for.

 ## The solve

 In the plane the rest leg bends in — the one holding the root, the rest knee and
 the rest foot, whichever way the leg is splayed — the two proximal bones are
 solved analytically. Which way the knee points is the side it already bends
 toward at rest: the bend is carried along with the root-to-foot line, so a leg
 never flips. A longer leg keeps its distal segment, the metatarsal or the foot
 itself, at a preferred tilt and tilts it only as far as the reach needs, the way
 a real hock does; a two-bone leg is plain analytic two-bone IK. `solve_leg` is
 that solve and is pure: it takes where the joints are and answers with the turns,
 which is what lets `solve_targets` use the same rule on a posed rig.

 ## What it does not do

 It keys no root turn. The floor solve (`anim/ground.c3`) still owns the root's
 height, so the clip names which feet are down and when. One thing is keyed for
 it: a straight-legged figure cannot walk at its standing height, so the paths are
 solved for a hip a constant `drop` lower, the smallest that keeps every stance
 leg short of straight, and that drop is keyed as the root's move. Left to the
 solve, a gait with a flight phase would pop up by it whenever no foot is down.
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;

faultdef GAIT_NO_LEGS, GAIT_BAD_LEG, GAIT_NO_OFFSET;

// Bones between the leg root and the foot. More and the root is the fourth joint
// above the foot, which leaves the higher ones where they are.
const usz GAIT_BONES_MAX = 4;
// The most feet one gait drives; past a centipede.
const usz GAIT_FEET_MAX = 8;
// How much of its length a leg may stretch to before its distal segment starts
// tilting to make up the reach.
const float GAIT_REACH = 0.985f;
// How much of its length a stance leg is allowed to need: short of straight, so
// a straight-legged figure crouches a little instead of walking on locked knees.
const float GAIT_COMFORT = 0.95f;
// A bend smaller than this fraction of the leg's length is noise in the rest
// pose, not a side the leg prefers — a straight leg bends forward.
const float GAIT_BEND_MIN = 0.05f;
// Foot roll, radians: the distal segment's tilt through a stance, the extra flex
// a swing adds, and how far the toes lift in a swing. Toes are never pitched down:
// they rest on the floor with the foot, and a toe turned under it is a sunk one.
const float GAIT_STANCE_TILT = 0.25f;
const float GAIT_SWING_FLEX = 0.6f;
const float GAIT_TOE_LIFT = 0.3f;

enum GaitKind
{
	WALK,
	TROT,
	PACE,
	GALLOP,
	CUSTOM,
}

fn bool parse_gait_kind(String text, GaitKind* into)
{
	switch (text)
	{
		case "walk": *into = WALK;
		case "trot": *into = TROT;
		case "pace": *into = PACE;
		case "gallop": *into = GALLOP;
		case "custom": *into = CUSTOM;
		default: return false;
	}
	return true;
}

fn String GaitKind.label(self)
{
	switch (self)
	{
		case WALK: return "walk";
		case TROT: return "trot";
		case PACE: return "pace";
		case GALLOP: return "gallop";
		case CUSTOM: return "custom";
	}
}

<*
 A joint chain that can be solved as a leg: where its joints are, and what they
 already hold.

 `at` and `turn` are the *starting* pose — the rest pose for a cycle, whatever a
 clip holds for a solve on a posed rig — so the solve keeps the roll a bone
 already has about its own length and turns it only as far as the reach needs.
*>
struct LegChain
{
	usz bones;                                  // 2 to GAIT_BONES_MAX
	Vec3[GAIT_BONES_MAX + 1] at;                // root first, the foot last
	Quaternionf[GAIT_BONES_MAX + 1] turn;       // each joint's world rotation
	Quaternionf parent;                         // the root's parent's world rotation
}

<*
 What a leg solve answers: the turns, and where they leave the joints.
*>
struct LegSolve
{
	Quaternionf[GAIT_BONES_MAX] local;          // parent-relative, joints 0 to bones - 1
	Quaternionf[GAIT_BONES_MAX] world;
	Vec3[GAIT_BONES_MAX + 1] at;                // where the joints land, foot last
	Vec3 lateral;                               // the axis the leg's plane is turned about
	float tilt;                                 // the distal tilt the reach settled on
	float gap;                                  // how far short of the target the foot landed
}

// The plane a rest leg bends in: its root-to-joint-2 axis, the way the knee
// stands off it, and the normal of the plane that makes.
struct LegPlane @local
{
	Vec3 axis;
	Vec3 bend;
	bool bent;
	Vec3 normal;
}

fn Vec3 unit_or(Vec3 v, Vec3 fallback) @local
{
	float length = v.length();
	return length > 1.0e-9f ? v / length : fallback;
}

fn LegPlane leg_plane(LegChain* chain) @local
{
	LegPlane plane;
	Vec3 axis = chain.at[2] - chain.at[0];
	plane.axis = unit_or(axis, { 0, -1, 0 });
	Vec3 knee = chain.at[1] - chain.at[0];
	Vec3 off = knee - plane.axis * knee.dot(plane.axis);
	float span = (chain.at[1] - chain.at[0]).length() + (chain.at[2] - chain.at[1]).length();
	plane.bent = off.length() > GAIT_BEND_MIN * span;
	plane.bend = plane.bent ? off.normalize() : (Vec3){ 0, 0, 1 };
	plane.normal = plane.bent ? unit_or(plane.axis.cross(plane.bend), { 1, 0, 0 }) : (Vec3){ 1, 0, 0 };
	// Positive turns about it are the world X sense the conventions in
	// animation.c3 describe, so a leg in the sagittal plane pitches about +X.
	if (plane.normal.x < 0.0f) plane.normal = -plane.normal;
	return plane;
}

fn float distal_distance(Vec3 root, Vec3 target, Vec3 distal, Vec3 lateral, float tilt) @local
{
	Quaternionf pitch = quaternion::from_axis_angle{float}(lateral, tilt);
	return (target - pitch.rotate_vec3(distal) - root).length();
}

<*
 Bend a leg so its foot lands on `target`.

 	`LegSolve s = solve_leg(&chain, target, 0.25f);`

 Two bones is analytic two-bone IK. With three or four, the first two are solved
 and the rest — the metatarsal, or the foot — are carried as one rigid segment
 held at `tilt` radians about the leg's lateral axis from the tilt it started at,
 and tilted further (toward whichever side shortens the reach, the smallest turn
 that does) only when the proximal pair would otherwise have to stretch past
 `GAIT_REACH`. A target beyond reach comes back short, with `gap` saying by how
 much.

 The knee bends to the side it stood on at the start: the bend is carried along
 with the root-to-joint line by the shortest turn, so a limb does not flip as the
 target crosses it. A leg with no bend to read (a straight rest pose) bends
 toward +Z, the way a knee does.

 @param chain : `Two to GAIT_BONES_MAX bones, the starting pose.`
 @param tilt : `Radians about the lateral axis, added to the distal segment's starting orientation. Ignored by a two-bone leg.`
*>
fn LegSolve solve_leg(LegChain* chain, Vec3 target, float tilt = 0.0f)
{
	LegSolve out;
	usz bones = chain.bones;
	Vec3 root = chain.at[0];
	float l0 = (chain.at[1] - chain.at[0]).length();
	float l1 = (chain.at[2] - chain.at[1]).length();
	LegPlane plane = leg_plane(chain);
	out.lateral = plane.normal;

	// Where joint 2 has to land. A two-bone leg's joint 2 is its foot; a longer
	// one holds the rest of the leg rigid beyond it, turned by the tilt.
	Vec3 distal = bones > 2 ? chain.at[bones] - chain.at[2] : (Vec3){};
	float used = tilt;
	if (bones > 2)
	{
		float limit = GAIT_REACH * (l0 + l1);
		if (distal_distance(root, target, distal, plane.normal, used) > limit)
		{
			// The smallest extra turn, from either side, that brings the reach in.
			for (uint step = 1; step <= 250; step++)
			{
				float more = tilt + (float)step * 0.01f;
				float less = tilt - (float)step * 0.01f;
				float near_more = distal_distance(root, target, distal, plane.normal, more);
				float near_less = distal_distance(root, target, distal, plane.normal, less);
				if (math::min(near_more, near_less) > limit) continue;
				used = near_more <= near_less ? more : less;
				break;
			}
		}
	}
	out.tilt = used;
	Quaternionf group = quaternion::from_axis_angle{float}(plane.normal, used);
	Vec3 joint2 = bones > 2 ? target - group.rotate_vec3(distal) : target;

	// The two proximal bones.
	Vec3 to = joint2 - root;
	float reach = to.length();
	float low = math::abs(l0 - l1) + 1.0e-4f * (l0 + l1);
	float high = (l0 + l1) * 0.9999f;
	float d = math::clamp(reach, low, high);
	Vec3 u = unit_or(to, plane.axis);

	Vec3 bend;
	if (plane.bent)
	{
		bend = bone_carry(plane.axis, u).rotate_vec3(plane.bend);
		bend = unit_or(bend - u * bend.dot(u), plane.bend);
	}
	else
	{
		Vec3 forward = (Vec3){ 0, 0, 1 };
		bend = forward - u * forward.dot(u);
		if (bend.length() < 1.0e-4f) bend = (Vec3){ 1, 0, 0 } - u * u.x;
		bend = bend.normalize();
	}

	float along = (l0 * l0 + d * d - l1 * l1) / (2.0f * d);
	float lift = math::sqrt(math::max(l0 * l0 - along * along, 0.0f));
	Vec3 knee = root + u * along + bend * lift;
	Vec3 wrist = root + u * d;

	Quaternionf w0 = bone_carry(chain.at[1] - chain.at[0], knee - root).mul(chain.turn[0]).normalize();
	Quaternionf w1 = bone_carry(chain.at[2] - chain.at[1], wrist - knee).mul(chain.turn[1]).normalize();
	out.world[0] = w0;
	out.world[1] = w1;
	out.local[0] = chain.parent.invert().mul(w0).normalize();
	out.local[1] = w0.invert().mul(w1).normalize();

	out.at[0] = root;
	out.at[1] = knee;
	out.at[2] = wrist;
	for (usz j = 2; j < bones; j++)
	{
		out.world[j] = group.mul(chain.turn[j]).normalize();
		out.local[j] = out.world[j - 1].invert().mul(out.world[j]).normalize();
		out.at[j + 1] = out.at[j] + group.rotate_vec3(chain.at[j + 1] - chain.at[j]);
	}
	out.gap = (target - out.at[bones]).length();
	return out;
}

<*
 The foot's own turn, once the leg above it is solved: its orientation held
 `pitch` radians off where it started, about the leg's lateral axis — positive
 points the toes down — whatever the leg above is doing. A foot left at its
 starting orientation stays flat on the floor while the shin swings over it.

 @return `Parent-relative, to key on the foot joint.`
*>
fn Quaternionf leg_foot_turn(LegChain* chain, LegSolve* solved, float pitch)
{
	Quaternionf held = quaternion::from_axis_angle{float}(solved.lateral, pitch).mul(chain.turn[chain.bones]);
	return solved.world[chain.bones - 1].invert().mul(held).normalize();
}

<*
 How a joint's parent count reads: children of each joint of the skeleton.
*>
fn usz skeleton_children(rig::Skeleton* skeleton, usz joint) @local
{
	usz count;
	foreach (int parent : skeleton.parents)
	{
		if (parent >= 0 && (usz)parent == joint) count++;
	}
	return count;
}

<*
 A leg named by its joints: root first, foot last.
*>
struct GaitLeg
{
	usz bones;
	usz[GAIT_BONES_MAX + 1] joints;
}

<*
 The leg that ends in `foot`: up from it until the parent forks (the hip's parent
 is the pelvis, which also carries the spine) or GAIT_BONES_MAX bones are walked.

 @return `False when that is fewer than two bones, which is not a leg this can bend.`
*>
fn bool gait_leg_of(rig::Skeleton* skeleton, usz foot, GaitLeg* leg)
{
	*leg = {};
	usz[GAIT_BONES_MAX + 1] up;
	usz count = 1;
	up[0] = foot;
	usz at = foot;
	while (count <= GAIT_BONES_MAX)
	{
		int parent = skeleton.parents[at];
		if (parent < 0) break;
		if (skeleton_children(skeleton, (usz)parent) > 1) break;
		up[count++] = (usz)parent;
		at = (usz)parent;
	}
	if (count < 3) return false;
	leg.bones = count - 1;
	for (usz i = 0; i < count; i++) leg.joints[i] = up[count - 1 - i];
	return true;
}

// Whether every joint of the leg has a name a clip can address.
fn bool gait_leg_named(GaitLeg* leg, String[] names) @local
{
	for (usz i = 0; i <= leg.bones; i++)
	{
		if (leg.joints[i] >= names.len || names[leg.joints[i]].len == 0) return false;
	}
	return true;
}

// The pairs of suffixes a rig names its sides with, left first.
const String[2][*] GAIT_SIDES = {
	{ "_L", "_R" }, { "_l", "_r" }, { ".L", ".R" }, { ".l", ".r" }, { "Left", "Right" },
};

// The other side's name, or "" for a name that states no side. Caller frees.
fn String gait_twin_name(Allocator allocator, String name)
{
	foreach (pair : GAIT_SIDES)
	{
		if (name.len > pair[0].len && name.ends_with(pair[0]))
		{
			return string::format(allocator, "%s%s", name[:name.len - pair[0].len], pair[1]);
		}
		if (name.len > pair[1].len && name.ends_with(pair[1]))
		{
			return string::format(allocator, "%s%s", name[:name.len - pair[1].len], pair[0]);
		}
	}
	return "";
}

fn sz gait_joint_named(String[] names, String name) @local
{
	foreach (usz i, candidate : names)
	{
		if (candidate.len > 0 && candidate == name) return (sz)i;
	}
	return -1;
}

// The foot a leaf limb ends in: the toe's parent when that still leaves a leg, the
// leaf itself when it is the ankle of a rig with no toes.
fn bool gait_foot_of_leaf(rig::Skeleton* skeleton, String[] names, usz leaf, usz* foot) @local
{
	GaitLeg leg;
	int parent = skeleton.parents[leaf];
	*foot = leaf;
	if (parent >= 0 && gait_leg_of(skeleton, (usz)parent, &leg)) *foot = (usz)parent;
	return gait_leg_of(skeleton, *foot, &leg) && gait_leg_named(&leg, names);
}

<*
 Find a rig's feet: for each left/right pair of limbs that end in a leaf, the
 lowest joint whose child is a toe — the joint the floor meets.

 A limb counts only when both sides are legs — two bones or more below a fork —
 and it is near the floor, within a fifth of the rig's height of the lowest foot,
 which is what separates legs from arms, ears and fingers.

 @param out : `Receives foot joint indices, in joint order.`
 @return `How many were found, at most out.len.`
*>
fn usz gait_find_feet(rig::Skeleton* skeleton, String[] names, usz[] out)
{
	usz joints = skeleton.len();
	usz[64] found;
	usz total = 0;
	for (usz j = 0; j < joints && total < found.len; j++)
	{
		if (j >= names.len || names[j].len == 0 || skeleton_children(skeleton, j) > 0) continue;
		String twin = gait_twin_name(mem, names[j]);
		defer if (twin.len > 0) twin.free(mem);
		if (twin.len == 0) continue;
		sz other = gait_joint_named(names, twin);
		if (other < 0 || skeleton_children(skeleton, (usz)other) > 0) continue;

		usz foot;
		usz other_foot;
		if (!gait_foot_of_leaf(skeleton, names, j, &foot) || !gait_foot_of_leaf(skeleton, names, (usz)other, &other_foot)) continue;
		bool known;
		for (usz i = 0; i < total; i++) if (found[i] == foot) known = true;
		if (!known) found[total++] = foot;
	}

	float lowest = (float)math::FLOAT_MAX;
	for (usz i = 0; i < total; i++) lowest = math::min(lowest, skeleton.joints[found[i]].y);
	float near = 0.2f * skeleton.height();

	usz written;
	for (usz i = 0; i < total && written < out.len; i++)
	{
		if (skeleton.joints[found[i]].y <= lowest + near) out[written++] = found[i];
	}
	for (usz i = 1; i < written; i++)
	{
		usz key = out[i];
		usz k = i;
		while (k > 0 && out[k - 1] > key) { out[k] = out[k - 1]; k--; }
		out[k] = key;
	}
	return written;
}

// Footfall offsets by [row][side], row 0 hind and 1 fore, side 0 left and 1 right.
const float[2][2] GAIT_TABLE_WALK @local = { { 0.0f, 0.5f }, { 0.25f, 0.75f } };
const float[2][2] GAIT_TABLE_TROT @local = { { 0.0f, 0.5f }, { 0.5f, 0.0f } };
const float[2][2] GAIT_TABLE_PACE @local = { { 0.0f, 0.5f }, { 0.0f, 0.5f } };
const float[2][2] GAIT_TABLE_GALLOP @local = { { 0.0f, 0.1f }, { 0.6f, 0.5f } };

<*
 How long each foot is down, as a fraction of the cycle, when a gait is not told.
 Fewer feet down at once is faster: a walk keeps four-fifths of a dog on the
 floor at any instant, a gallop hardly one.
*>
fn float gait_default_duty(GaitKind kind, usz feet)
{
	switch (kind)
	{
		case WALK: return feet == 2 ? 0.6f : 0.62f;
		case TROT: return 0.45f;
		case PACE: return 0.45f;
		case GALLOP: return 0.35f;
		case CUSTOM: return 0.5f;
	}
}

// How far the stride reaches, as a fraction of leg height, by gait.
fn float gait_default_stride(GaitKind kind)
{
	switch (kind)
	{
		case WALK: return 0.6f;
		case TROT: return 0.75f;
		case PACE: return 0.7f;
		case GALLOP: return 0.95f;
		case CUSTOM: return 0.6f;
	}
}

// How high a swinging foot clears the floor, as a fraction of leg height.
fn float gait_default_lift(GaitKind kind)
{
	switch (kind)
	{
		case WALK: return 0.12f;
		case TROT: return 0.16f;
		case PACE: return 0.14f;
		case GALLOP: return 0.2f;
		case CUSTOM: return 0.12f;
	}
}

<*
 Where in the cycle each foot lands, for a named gait.

 Two feet alternate. Four are read as a pair of rows — hind behind, fore ahead
 of the feet's own centre — and a pair of sides, left at +X, and looked up in the
 gait's table: a walk is the lateral sequence (left hind, left fore, right hind,
 right fore), a trot has the diagonals land together, a pace the lateral pairs, a
 gallop the rotary order. Any other count is spread evenly, in order.

 @param offsets : `One phase per foot, in the order of feet.`
*>
fn void gait_offsets(rig::Skeleton* skeleton, GaitKind kind, usz[] feet, float[] offsets)
{
	usz count = feet.len;
	if (count == 2)
	{
		offsets[0] = 0.0f;
		offsets[1] = 0.5f;
		return;
	}
	if (count == 4)
	{
		Vec3 centre = {};
		foreach (foot : feet) centre += skeleton.joints[foot];
		centre /= 4.0f;
		bool[2][2] taken;
		float[4] read;
		bool clean = true;
		for (usz i = 0; i < 4; i++)
		{
			Vec3 at = skeleton.joints[feet[i]];
			usz row = at.z > centre.z ? 1 : 0;
			usz side = at.x > centre.x ? 0 : 1;
			if (taken[row][side]) clean = false;
			taken[row][side] = true;
			switch (kind)
			{
				case WALK: read[i] = GAIT_TABLE_WALK[row][side];
				case TROT: read[i] = GAIT_TABLE_TROT[row][side];
				case PACE: read[i] = GAIT_TABLE_PACE[row][side];
				case GALLOP: read[i] = GAIT_TABLE_GALLOP[row][side];
				case CUSTOM: read[i] = 0.0f;
			}
		}
		if (clean)
		{
			for (usz i = 0; i < 4; i++) offsets[i] = read[i];
			return;
		}
	}
	for (usz i = 0; i < count; i++) offsets[i] = (float)i / (float)count;
}

<*
 A gait asked for.

 `stride` is how far, in model units, the stance foot slides back — and so, over
 the `duty` share of the cycle it is down, how fast the treadmill the figure walks
 on has to run. `lift` is how high the swinging foot clears the floor in model
 units. Zero takes the gait's default, scaled to the leg.
*>
struct GaitSpec
{
	GaitKind kind;
	float duty;
	float stride;
	float lift;
	float duration;
	bool loop;
	usz samples;
}

// One foot of a gait: a joint of the skeleton, and where in the cycle it lands.
struct GaitFoot
{
	usz joint;
	float offset;
}

<*
 What a gait turned out to be, for the caller to report.
*>
struct GaitReport
{
	usz legs;
	usz keys;
	float duty;
	float stride;
	float lift;
	float leg_height;
	float drop;
	float floor;
	float speed;   // model units per second the treadmill runs
}

// One foot's path and leg, ready to be solved per instant.
struct LegPlan @local
{
	GaitLeg leg;
	LegChain chain;
	Vec3 rest;
	float offset;
}

fn float smooth_step(float s) @local
{
	s = math::clamp(s, 0.0f, 1.0f);
	return s * s * (3.0f - 2.0f * s);
}

<*
 How far forward a swinging foot is, from -0.5 (lift-off) to 0.5 (touchdown) of
 the stride, `s` of the way through the swing.

 A Hermite whose ends move at the stance's own speed: the foot leaves the ground
 still travelling back with it and meets it again already travelling back, so
 neither edge of the stance is a jolt the leg has to take up in one frame. A
 smoothstep stops the foot dead at each end instead, and every footfall then
 jerks the knee from rest to full ground speed.
*>
fn float swing_travel(float s, float duty) @local
{
	// Stance speed in stride per unit of swing, backward.
	float k = -(1.0f - duty) / math::max(duty, 0.05f);
	float s2 = s * s;
	float s3 = s2 * s;
	float h00 = 2.0f * s3 - 3.0f * s2 + 1.0f;
	float h10 = s3 - 2.0f * s2 + s;
	float h01 = -2.0f * s3 + 3.0f * s2;
	float h11 = s3 - s2;
	return -0.5f * h00 + k * h10 + 0.5f * h01 + k * h11;
}

<*
 Where a foot is at `phase`, and how its leg should hold itself there.

 The stance slides the foot back at a constant speed along the floor; the swing
 carries it forward on a curve that leaves and meets the ground at the stance's
 speed (`swing_travel`) and lifts it on a sine. The distal segment
 tilts through the stance (heel down at touchdown, off at the end) and flexes in
 the swing, and the toes stay flat through the stance and lift in the swing.

 @param tilt : `Radians the distal segment is held at.`
 @param toes : `Radians the toes point down, in the world; negative lifts them.`
*>
fn Vec3 gait_foot_at(LegPlan* plan, GaitSpec* spec, float floor, float drop, float phase, float* tilt, float* toes) @local
{
	float p = phase - plan.offset;
	p -= math::floor(p);
	float z;
	float y = floor + drop;
	if (p < spec.duty)
	{
		float s = p / spec.duty;
		z = plan.rest.z + spec.stride * (0.5f - s);
		*tilt = GAIT_STANCE_TILT * (2.0f * s - 1.0f);
		*toes = 0.0f;
	}
	else
	{
		float s = (p - spec.duty) / (1.0f - spec.duty);
		z = plan.rest.z + spec.stride * swing_travel(s, spec.duty);
		y += spec.lift * (float)math::pow(math::sin((float)math::PI * s), 1.2f);
		*tilt = GAIT_STANCE_TILT * (1.0f - 2.0f * smooth_step(s)) + GAIT_SWING_FLEX * math::sin((float)math::PI * s);
		*toes = -GAIT_TOE_LIFT * math::sin((float)math::PI * s);
	}
	return { plan.rest.x, y, z };
}

// Whether every leg can hold its gait comfortably with the hips `drop` lower.
fn bool gait_holds(LegPlan[] plans, GaitSpec* spec, float floor, float drop) @local
{
	foreach (&plan : plans)
	{
		LegChain* chain = &plan.chain;
		float l0 = (chain.at[1] - chain.at[0]).length();
		float l1 = (chain.at[2] - chain.at[1]).length();
		LegPlane shape = leg_plane(chain);
		Vec3 distal = chain.bones > 2 ? chain.at[chain.bones] - chain.at[2] : (Vec3){};
		for (uint i = 0; i < 48; i++)
		{
			float tilt;
			float toes;
			Vec3 target = gait_foot_at(plan, spec, floor, drop, (float)i / 48.0f, &tilt, &toes);
			if (distal_distance(chain.at[0], target, distal, shape.normal, tilt) > GAIT_COMFORT * (l0 + l1)) return false;
		}
	}
	return true;
}

<*
 Write a gait as a looping (or not) clip.

 	`AnimTemplate clip = gait_clip(mem, &view.skeleton, view.names, "Trot", spec, feet, &report)!;`

 Every foot is given a leg, a path and a place in the cycle; at each of
 `spec.samples` instants the legs are solved and their joints keyed as rotations,
 linear between — dense enough that the curve between two keys is the path. The
 ground spec names each foot's window (down at its offset, up a duty later) and
 the floor it stands on, so the floor solve finds the root height the clip leaves
 out. Nothing above the legs is keyed.

 @param feet : `The feet and where each lands. Their legs must have two to four bones below a fork.`
 @param spec : `Zero duty, stride and lift take the gait's defaults, scaled to the leg.`
 @param report : `Filled with what the gait turned out to be.`
 @return? GAIT_NO_LEGS : `No feet.`
 @return? GAIT_BAD_LEG : `A foot has no two-bone leg below a fork, or a joint of it is unnamed.`
*>
fn AnimTemplate? gait_clip(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	String name,
	GaitSpec spec,
	GaitFoot[] feet,
	GaitReport* report)
{
	*report = {};
	if (feet.len == 0 || feet.len > GAIT_FEET_MAX) return GAIT_NO_LEGS~;

	LegPlan[GAIT_FEET_MAX] held;
	LegPlan[] plans = held[:feet.len];
	float floor = (float)math::FLOAT_MAX;
	float leg_height;
	foreach (usz i, foot : feet)
	{
		LegPlan* plan = &plans[i];
		*plan = { .offset = foot.offset };
		if (foot.joint >= skeleton.len() || !gait_leg_of(skeleton, foot.joint, &plan.leg) || !gait_leg_named(&plan.leg, names)) return GAIT_BAD_LEG~;
		plan.chain.bones = plan.leg.bones;
		plan.chain.parent = quaternion::IDENTITY;
		for (usz j = 0; j <= plan.leg.bones; j++)
		{
			plan.chain.at[j] = skeleton.joints[plan.leg.joints[j]];
			plan.chain.turn[j] = quaternion::IDENTITY;
		}
		plan.rest = plan.chain.at[plan.leg.bones];
		floor = math::min(floor, plan.rest.y);
		leg_height += plan.chain.at[0].y - plan.rest.y;
	}
	leg_height /= (float)feet.len;
	if (!(leg_height > 0.0f)) return GAIT_BAD_LEG~;

	if (!(spec.duty > 0.0f)) spec.duty = gait_default_duty(spec.kind, feet.len);
	spec.duty = math::clamp(spec.duty, 0.1f, 0.9f);
	if (!(spec.stride > 0.0f)) spec.stride = gait_default_stride(spec.kind) * leg_height;
	if (!(spec.lift > 0.0f)) spec.lift = gait_default_lift(spec.kind) * leg_height;
	if (spec.samples < 8) spec.samples = 8;
	if (!(spec.duration > 0.0f)) spec.duration = 1.0f;

	// The smallest constant hip drop that keeps every leg short of straight across
	// the whole cycle: none when the legs already bend enough, else a search.
	float drop;
	if (!gait_holds(plans, &spec, floor, 0.0f))
	{
		float high = 0.6f * leg_height;
		if (!gait_holds(plans, &spec, floor, high))
		{
			drop = high;
		}
		else
		{
			float low;
			for (uint i = 0; i < 16; i++)
			{
				float mid = (low + high) * 0.5f;
				if (gait_holds(plans, &spec, floor, mid)) { high = mid; } else { low = mid; }
			}
			drop = high;
		}
	}

	usz root = 0;
	while (skeleton.parents[root] >= 0) root = (usz)skeleton.parents[root];
	float height = skeleton.height();
	bool keys_root = drop > 0.0f && height > 0.0f && root < names.len && names[root].len > 0;

	usz count = spec.loop ? spec.samples : spec.samples + 1;
	AnimKeyframe[] keyframes = alloc::new_array(allocator, AnimKeyframe, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		float phase = (float)i / (float)spec.samples;
		usz dots_made;
		usz total = keys_root ? 1 : 0;
		foreach (&plan : plans) total += plan.leg.bones + 1;
		AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, (sz)total);
		// The hips' drop, keyed on the root rather than left to the floor solve: a
		// gait with a flight phase (a trot, a gallop) has instants with no foot
		// down, and there the solve has nothing to plant, so the figure would pop
		// up by the whole drop. Keyed, the stance legs already reach the floor and
		// the solve's correction is nothing.
		if (keys_root)
		{
			dots[dots_made++] = {
				.joint_name = names[root].copy(allocator),
				.channels = AnimChannels.TRANSLATION,
				.move = { 0, -drop / height, 0 },
			};
		}
		foreach (&plan : plans)
		{
			float tilt;
			float toes;
			Vec3 target = gait_foot_at(plan, &spec, floor, drop, phase, &tilt, &toes);
			LegSolve solved = solve_leg(&plan.chain, target, tilt);
			Quaternionf[GAIT_BONES_MAX + 1] turns;
			for (usz j = 0; j < plan.leg.bones; j++) turns[j] = solved.local[j];
			turns[plan.leg.bones] = leg_foot_turn(&plan.chain, &solved, toes);
			for (usz j = 0; j <= plan.leg.bones; j++)
			{
				AnimKeyDot dot = { .joint_name = names[plan.leg.joints[j]].copy(allocator), .channels = AnimChannels.ROTATION };
				axis_angle_of(turns[j], &dot.axis, &dot.angle);
				dots[dots_made++] = dot;
			}
		}
		keyframes[i] = { .time = spec.duration * phase, .dots = dots };
	}

	AnimFoot[] windows = alloc::new_array(allocator, AnimFoot, (sz)feet.len);
	foreach (usz i, &plan : plans)
	{
		float down = plan.offset - math::floor(plan.offset);
		float up = down + spec.duty;
		up -= math::floor(up);
		windows[i] = { .joint = names[plan.leg.joints[plan.leg.bones]].copy(allocator), .down = down, .up = up };
	}

	*report = {
		.legs = feet.len,
		.keys = count,
		.duty = spec.duty,
		.stride = spec.stride,
		.lift = spec.lift,
		.leg_height = leg_height,
		.drop = drop,
		.floor = floor,
		.speed = spec.stride / (spec.duty * spec.duration),
	};
	return {
		.name = name.copy(allocator),
		.duration = spec.duration,
		.keyframes = keyframes,
		.loop = spec.loop,
		.blend = LINEAR,
		.ground = { .feet = windows, .floor = floor, .floor_set = true },
		.owned = true,
	};
}

<*
 What the body solve is handed and what it hands back, and the numbers that read
 the body without solving it.

 The method is in `body_solve.c3`; this file is its vocabulary.

 **In.** `PointJoint` is one joint in play, with its inverse mass, its limit
 frame and limits, and whether it is frozen (aimed), floored (kept above the
 floor) or part of the trunk. `PointGoal` is one thing the body is asked to do:
 hold a joint at a point (hard, a pin; or soft, the grab) and/or hold its world
 rotation (hard, or soft by `turn_weight`). `PointPoseSettings` is the height,
 the floor, the balance and the pose the stiffness draws back toward.

 **Out.** Each goal's `residual` (how far its joint ended from the point),
 `turn_residual` (radians from the held rotation) and `stood_down`, the
 settings' `balance_miss`, and the largest position miss that
 `point_pose_measure` returns. Measuring is separate from solving: it reads a
 pose through `joint_palette`, the forward kinematics the viewport draws by.

 **Masses.** `point_pose_masses` reads how heavy each joint is off the rig's
 shape, and off the mesh's part masses where there are any
 (`AppState.body_part_masses`): limbs light, the trunk heavier, the root
 heaviest. The solve's stiffness is built on them.

 **The balance's weights and outline.** `point_balance_weights` weighs the body
 and `point_support_miss` says how far its centre stands outside the outline of
 what it stands on; `body_solve` calls both.
*>
module crig;

import rig;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// Rounds of the closing polish: each pin's limb by CCD, then the root slid toward
// the pins they could not reach (`BodySolve.polish`).
const int POINT_POSE_POLISH_ROUNDS = 6;

// A grab's say in where its joint goes, against a pin's `POINT_POSE_PIN`.
const float POINT_POSE_GRAB = 1.0;

// The most planted feet the balance reads the outline of.
const usz POINT_POSE_SUPPORTS = 8;

// How bent a one-sided hinge has to stand, the way its range opens, in radians
// (about three degrees), for the solve not to start it bent (`BodySolve.seed_bends`);
// a range narrower than four times this is not a hinge worth bending
// (`BodySolve.one_sided_hinge`).
const float POINT_POSE_BEND = 0.05;

// The legs' share of the body's mass for the balance; the rest is the trunk, the
// head and the arms. Fixed rather than counted, so a hand's many finger bones do
// not outweigh the chest.
const float POINT_POSE_LEG_MASS = 0.32;

// How much heavier the trunk is than a limb, and the root than the trunk — the
// masses `point_pose_masses` hands out.
const float POINT_POSE_TRUNK_MASS = 4.0;
const float POINT_POSE_ROOT_MASS = 16.0;

// A branch shorter than this share of the height, counted from the joint it hangs
// from, is a hand or a foot and its digits — a head on its neck is longer — and
// does not make that joint part of the trunk.
const float POINT_POSE_LIMB_SHARE = 0.2;

// ---------------------------------------------------------------------------
// What the solve is handed, and what it gives back

<*
 One joint the solve may move.

 Joints the caller does not list are not in play: they keep their rotation and
 ride whatever they hang from, like a frozen joint.
*>
struct PointJoint
{
	usz joint;
	float inv_mass;              // 1 for a limb; less is heavier
	bool frozen;                 // keeps its local rotation: what hangs below it rides
	bool floored;                // kept at or above `PointPoseSettings.floor`
	bool trunk;                  // stiff against leaning and twisting, and leans for the balance
	JointLimitFrame frame;
	JointRotationLimits limits;
}

<*
 One thing the body is asked to do.

 A hard goal is held whatever it costs the others; a soft one — the grab — is
 reached for as far as the hard goals let it.
*>
struct PointGoal
{
	usz joint;
	bool position;           // hold the joint at `target`
	Vec3 target;             // model space
	bool soft;               // the grab: gives way to the hard goals
	bool rotation;           // hold the joint's world rotation at `orient`
	Quaternionf orient;
	float turn_weight;       // with `rotation`: 0 holds `orient` hard; more is a soft hold of that weight
	float residual;          // out: how far the joint ended from `target`
	float turn_residual;     // out: radians the joint ended from `orient`
	bool stood_down;         // out: a hard position out of its limb's reach, left unsolved
}

struct PointPoseSettings
{
	float height;
	Vec3 up;                 // unit; zero means +Y
	bool has_floor;
	float floor;             // along `up`: floored joints stay at or above it
	int iterations;          // trial steps per sub-step; zero for `BODY_SOLVE_ITERATIONS`
	int ramp;                // sub-steps the grab is carried in; zero for as many as its distance asks (`BodySolve.ramp_steps`)
	bool balance;            // keep the centre of mass over the hard goals planted below the root
	Quaternionf[] posture;   // per skeleton joint, the local rotation the stiffness draws toward; empty for the pose handed in
	float balance_miss;      // out: how far the centre of mass ended from over what the body stands on
}

fn bool PointJoint.limited(&self) => self.limits.constrained && self.frame.usable();

// ---------------------------------------------------------------------------
// Masses

<*
 How heavy each joint is to the solve, as an inverse mass per skeleton joint.

 Read off the rig's shape, not its names. A joint is *trunk* when two or more
 limbs hang below it — a chest carrying both arms and the head, a spine carrying
 the chest — where a limb is any branch longer than `POINT_POSE_LIMB_SHARE` of
 the height, so a hand's five fingers do not make the wrist trunk; so is the
 root's main branch, the one that does not hang from it and carries the most. A
 root is the heaviest of all. With `fork_carry`, a trunk joint's mass is shared by the
 joints it carries rigidly (the children of a fork), so a hip socket weighs what
 the pelvis weighs and a thigh pulled sideways tilts the pelvis only a little —
 what a solver of points would need, which knows nothing of a socket being fixed to
 its pelvis. `body_solve` turns real joints with the sockets carried by forward
 kinematics, so it asks without (the app and the tests do): a thigh is a limb,
 light next to the pelvis it hangs from, and a pull on the waist is answered by
 the legs.

 @param inv_mass : `One per skeleton joint; filled.`
 @param trunk_out : `One per skeleton joint, or empty: filled with whether it is the trunk or the root.`
 @param part_mass : `One per skeleton joint, or empty: each body part's mass off the mesh (AppState.body_part_masses), used for the limbs in place of the shape's 1.`
 @param fork_carry : `Whether the children of a trunk fork weigh as much as the fork.`
*>
fn void point_pose_masses(rig::Skeleton* skeleton, float height, float[] inv_mass, bool[] trunk_out = {}, float[] part_mass = {},
	bool fork_carry = true)
{
	usz n = skeleton.len();
	if (inv_mass.len < n) return;
	float h = height > 0.0f ? height : 1.0f;
	float[] reach = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, reach);
	usz[] limbs = alloc::new_array(mem, usz, (sz)n);
	defer alloc::free(mem, limbs);
	bool[] trunk = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, trunk);

	// Children come after their parents, so walking back sees every child first.
	for (usz i = n; i > 0; i--)
	{
		usz j = i - 1;
		int parent = skeleton.parents[j];
		if (limbs[j] >= 2) trunk[j] = true;
		if (parent < 0) continue;
		float branch = (skeleton.joints[j] - skeleton.joints[(usz)parent]).length() + reach[j];
		reach[(usz)parent] = math::max(reach[(usz)parent], branch);
		if (branch >= h * POINT_POSE_LIMB_SHARE) limbs[(usz)parent]++;
		if (trunk[j]) trunk[(usz)parent] = true;
	}
	// And the root's main branch: of the children that do not hang below it, the
	// one carrying the most joints — a spine, whatever it carries — down through
	// every joint with one child. A torso with nothing on it yet is still the torso.
	usz[] carried = alloc::new_array(mem, usz, (sz)n);
	defer alloc::free(mem, carried);
	for (usz i = n; i > 0; i--)
	{
		usz j = i - 1;
		carried[j]++;
		int parent = skeleton.parents[j];
		if (parent >= 0) carried[(usz)parent] += carried[j];
	}
	for (usz r = 0; r < n; r++)
	{
		if (skeleton.parents[r] >= 0) continue;
		usz best = n;
		for (usz c = 0; c < n; c++)
		{
			if (skeleton.parents[c] != (int)r) continue;
			Vec3 away = skeleton.joints[c] - skeleton.joints[r];
			if (away.y < -0.5f * away.length()) continue;
			// Without the fork's carry a torso is the branch that goes up: a T-pose's legs
			// leave the hips sideways and, carrying more joints than a bare spine,
			// would be taken for it.
			bool up = away.y > 0.5f * away.length();
			if (!fork_carry && best != n)
			{
				Vec3 held = skeleton.joints[best] - skeleton.joints[r];
				bool held_up = held.y > 0.5f * held.length();
				if (up != held_up)
				{
					if (up) best = c;
					continue;
				}
			}
			if (best == n || carried[c] > carried[best]) best = c;
		}
		for (usz walk = best; walk < n;)
		{
			trunk[walk] = true;
			usz next = n;
			usz children = 0;
			for (usz c = walk + 1; c < n; c++)
			{
				if (skeleton.parents[c] != (int)walk) continue;
				children++;
				next = c;
			}
			if (children != 1) break;
			walk = next;
		}
	}
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		float mass = 1.0f;
		// A limb off the trunk weighs what its body part does, up to the trunk's
		// own weight: a fingertip next to nothing, a forearm more, a thigh as much as
		// the trunk. The trunk and the root keep the shape's weights, which is what
		// lets a pull on the waist sit the body down on its legs.
		bool on_fork = fork_carry && parent >= 0 && (trunk[(usz)parent] || skeleton.parents[(usz)parent] < 0);
		if (part_mass.len >= n && parent >= 0 && !trunk[j] && !on_fork)
		{
			mass = math::clamp(part_mass[j], 1.0f, (float)POINT_POSE_TRUNK_MASS);
		}
		else if (parent < 0)
		{
			mass = POINT_POSE_ROOT_MASS;
		}
		else if (trunk[j])
		{
			mass = POINT_POSE_TRUNK_MASS;
		}
		// Carried rigidly by a trunk fork: as heavy as the fork.
		if (fork_carry && parent >= 0 && (trunk[(usz)parent] || skeleton.parents[(usz)parent] < 0))
		{
			mass = math::max(mass, skeleton.parents[(usz)parent] < 0 ? POINT_POSE_ROOT_MASS : POINT_POSE_TRUNK_MASS);
		}
		inv_mass[j] = 1.0f / mass;
		if (j < trunk_out.len) trunk_out[j] = trunk[j] || parent < 0;
	}
}

// ---------------------------------------------------------------------------
// The measure

<*
 Fill every goal's `residual` (position) and `turn_residual` (world rotation)
 against `pose` as `joint_palette` builds it.

 @return `The largest position miss of any goal that has not stood down.`
*>
fn float point_pose_measure(rig::Skeleton* skeleton, rig::Pose* pose, PointGoal[] goals)
{
	Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
	if (catch built) return 0.0f;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? spun = pose.world_rotations(mem, skeleton);
	if (catch spun) return 0.0f;
	Quaternionf[] world = spun;
	defer alloc::free(mem, world);
	float worst = 0.0f;
	foreach (&goal : goals)
	{
		if (goal.joint >= skeleton.len()) continue;
		Vec3 at = skeleton.joints[goal.joint].transform(palette[goal.joint]);
		if (goal.position)
		{
			goal.residual = (at - goal.target).length();
			if (!goal.stood_down) worst = math::max(worst, goal.residual);
		}
		if (goal.rotation)
		{
			float cosine = math::min(math::abs(world[goal.joint].v.dot(goal.orient.v)), 1.0f);
			goal.turn_residual = 2.0f * (float)math::acos(cosine);
		}
	}
	return worst;
}

// ---------------------------------------------------------------------------
// The balance

<*
 The masses the balance weighs: each joint in play carries the bone above it, by
 rest length, and the joints flagged `leg` are scaled to `POINT_POSE_LEG_MASS` of
 the whole, the rest sharing the remainder.

 @param in_play : `Per skeleton joint: whether it is in the solve.`
 @param leg : `Per skeleton joint: whether it lies between the root and something stood on.`
 @param mass : `Per skeleton joint; filled.`
 @return `The masses' total, or zero when there are no legs or no body to weigh against them.`
*>
fn float point_balance_weights(rig::Skeleton* skeleton, bool[] in_play, bool[] leg, float[] mass)
{
	usz n = skeleton.len();
	float legs = 0.0f;
	float rest = 0.0f;
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		if (!in_play[j] || parent < 0) continue;
		float weight = (skeleton.joints[j] - skeleton.joints[(usz)parent]).length();
		mass[j] = weight;
		if (leg[j]) { legs += weight; } else { rest += weight; }
	}
	if (legs <= 0.0f || rest <= 0.0f) return 0.0f;
	float total = 0.0f;
	for (usz j = 0; j < n; j++)
	{
		mass[j] *= leg[j] ? POINT_POSE_LEG_MASS / legs : (1.0f - POINT_POSE_LEG_MASS) / rest;
		total += mass[j];
	}
	return total;
}

<*
 How far, across `up`, a centre of mass stands outside the outline of its
 supports: zero inside the convex hull, else the way to the nearest point of it.

 @param stands : `Where the body stands, already flattened across up.`
 @param centre : `The centre of mass, flattened the same way.`
*>
fn Vec3 point_support_miss(Vec3[] stands, Vec3 centre, Vec3 up)
{
	usz count = stands.len;
	if (count == 0) return {};
	if (count == 1) return stands[0] - centre;
	// The outline is the convex hull of the stands, by gift wrapping: a handful of
	// feet at most. In it, nothing to correct; out of it, the nearest point of any
	// edge.
	Vec3 a = stands[0];
	Vec3 b = stands[0];
	// Two axes across `up` to measure the turn of an edge by.
	Vec3 side = math::abs(up.x) < 0.9f ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
	side = point_flat(up, side).normalize();
	Vec3 ahead = up.cross(side);
	usz[POINT_POSE_SUPPORTS] hull;
	usz hull_count = 0;
	usz start = 0;
	for (usz i = 1; i < count; i++)
	{
		if (stands[i].dot(side) < stands[start].dot(side)) start = i;
	}
	usz at = start;
	while (hull_count < count)
	{
		hull[hull_count++] = at;
		usz next = (at + 1) % count;
		for (usz i = 0; i < count; i++)
		{
			Vec3 e = stands[next] - stands[at];
			Vec3 f = stands[i] - stands[at];
			float turn = e.dot(side) * f.dot(ahead) - e.dot(ahead) * f.dot(side);
			// Of points in a line the farthest, so the wrap never doubles back along it.
			if (turn < 0.0f || (turn == 0.0f && f.length_sq() > e.length_sq())) next = i;
		}
		at = next;
		if (at == start) break;
	}
	bool inside = hull_count >= 3;
	Vec3 nearest = stands[hull[0]];
	float closest = float::max;
	for (usz k = 0; k < hull_count; k++)
	{
		a = stands[hull[k]];
		b = stands[hull[(k + 1) % hull_count]];
		Vec3 e = b - a;
		Vec3 f = centre - a;
		float turn = e.dot(side) * f.dot(ahead) - e.dot(ahead) * f.dot(side);
		if (turn < 0.0f) inside = false;
		float t = e.length_sq() > 1.0e-12f ? math::clamp(f.dot(e) / e.length_sq(), 0.0f, 1.0f) : 0.0f;
		Vec3 point = a + e * t;
		float distance = (point - centre).length();
		if (distance < closest)
		{
			closest = distance;
			nearest = point;
		}
	}
	return inside ? (Vec3){} : nearest - centre;
}

// Only the part across `up`: standing over the feet says nothing about height.
fn Vec3 point_flat(Vec3 up, Vec3 v) => v - up * v.dot(up);

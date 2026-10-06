<*
 The point solver: one position-based solve that poses the whole body.

 	`float miss = point_pose(&skeleton, &pose, joints, goals, &settings);`

 **Why points.** Posing used to be a pipeline: a least-squares solve over joint
 angles, then passes that held the pins, the planted feet and the toes, each
 undoing a little of the last, with a joint on its limit clamped back after every
 step — so a drag that leaned on a limit stalled there, and a pin could slip when
 the passes disagreed. Here every joint is a point and every bone a fixed length,
 every demand on the body — the grab, the pins, the floor, the balance — says
 where its joint should be, and the body is relaxed toward all of them at once.
 Cascadeur poses this way.

 **What moves.** A joint with a goal anywhere below it is *framed*: its children
 are points, and its turn is whatever carries them where they are wanted. Every
 other joint keeps its own rotation and rides its parent — a free arm on a chest
 that leans, a hand that is grabbed by its position. The root is framed whenever
 anything below it is held, so every drag lets the spine and the hips join in,
 each by its mass: limbs are light, the trunk heavier, the root heaviest
 (`point_pose_masses`).

 **One iteration, two passes.** Warm-started from the pose handed in, which is
 the last mouse move's answer, each iteration

   wants    leaves first: every joint says where it should be — a pin's target
            outright; a grab's, heard over what the joint's bones say; any other
            joint where its bones put it given where its children want to be (the
            backward pass of FABRIK, the bone aimed as the joint's limits allow
            it; a fork slides its cluster to sit on its children's wants). Each
            is weighed against the joint's own inertia, so a heavy pelvis moves
            only when the limbs cannot answer alone, and then kept within reach
            of every pin below it — which is all a pin asks of the joints above.
   places   root first: each framed joint is turned to point its children at
            where they want to be, the turn read in the joint's own limit frame
            and clamped there, and its children are put where that turn and their
            bones say. So every iteration ends on a real pose — bones their own
            length, every joint inside its limits — and nothing the passes ask for
            can tear it.

 The iteration that came nearest is kept, then a closing polish puts each pin on
 its point exactly by its own limb, sliding the root after the pins where their
 limbs fall short.

 **The grab gives way.** Within the pins' reach the grab moves the body freely;
 where it still asks for more than every pin can follow, the solve is run again
 with the grab carried a shorter way, halving toward the furthest every pin holds
 at. The pins hold; the grab reports its miss. A pin's angle is the exception:
 where it and its joint's limits cannot both hold — a foot kept flat under a shin
 tilted past what the ankle bends to — the limit holds, and the angle reports its
 miss.

 **Limits slide, they do not stop.** A joint clamped at its limit places its
 children short of where they want to be; the next iteration's wants carry that
 miss to the joints above, which turn instead. A drag against an elbow's limit
 keeps tracking through the shoulder and the chest.

 **Twist.** A chain of points has no roll. A joint aims its one bone keeping the
 twist it had — so a swing of the shoulder leaves the forearm's roll as it was —
 except where the joint below is a hinge, whose bend the bone above has to roll to
 face; a fork's roll is its cluster's.

 Pure: it reads the skeleton and writes only the pose handed to it.
*>
module crig;

import rig;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// Iterations per solve. A solve stops early once an iteration moves no joint by
// more than `POINT_POSE_STILL`, which a mouse move's small step usually reaches
// well before.
const int POINT_POSE_ITERATIONS = 96;

// The largest step an iteration may take and still count as still, as a share of
// the height.
const float POINT_POSE_STILL = 1.0e-5;

// How much of a joint's inertia is left after each iteration of a solve. The
// first iterations share a pull out by mass — the arm takes what it can before
// the chest is asked — and once that is decided the rest are free to finish it:
// a chest that has to lean for a reach leans all the way, not a quarter of the
// rest of the way each time.
const float POINT_POSE_SETTLING = 0.8;

// How near every goal a pose handed in has to be already, as a share of the
// height, for the solve to leave it as it is.
const float POINT_POSE_MET = 5.0e-4;

// How far a hard position may end from its target and still count as held, as a
// share of the height — the line a solve that followed the grab too far is
// retried against (`point_pose`).
const float POINT_POSE_HOLD = 2.0e-3;

// Rounds of the closing polish: each pin's limb by CCD, then the root slid toward
// the pins they could not reach.
const int POINT_POSE_POLISH_ROUNDS = 6;

// How many halvings a grab that asked too much is cut back by.
const int POINT_POSE_GIVE_STEPS = 6;

// A grab's say in where its own joint goes, against what the joint's bones say.
const float POINT_POSE_GRAB = 1.0;

// A hard goal's say in where a joint goes, against a grab's 1.
const float POINT_POSE_HARD = 1.0e4;

// The say of a cluster member nothing pulls on: where it already is, as strongly
// as a grab. A fork is a rigid piece of the body — a chest with a neck and two
// collarbones — and one pulled child should turn it only as far as the others
// agree, not spin it to aim one short bone at a far-off want.
const float POINT_POSE_IDLE = 1.0;

// The most planted feet the balance reads the outline of.
const usz POINT_POSE_SUPPORTS = 8;

// The balance's say on each trunk joint, against a grab's 1.
const float POINT_POSE_BALANCE = 0.5;

// The share of the lean the balance asks of the root that it takes each
// iteration, and the most it takes at once, in radians.
const float POINT_POSE_BALANCE_TILT = 0.3;
const float POINT_POSE_MAX_LEAN = 0.1;

// How near the limit frame's Z axis a bone may point, as the sine of its tilt off
// the frame's XY plane, before the joint is aimed by the shortest turn instead of
// by its X and Z angles (about 72 degrees) — see `aim_local`.
const float POINT_POSE_POLE = 0.95;

// How bent a limb has to be before the bone above its hinge is rolled to face the
// bend, as the sine of the angle its lower bone stands off the upper (about 17
// degrees), and the most that roll takes in one iteration, in radians.
const float POINT_POSE_ROLL_BENT = 0.3;
const float POINT_POSE_MAX_ROLL = 0.3;

// How far inside full reach a joint above a pin is kept, as a share of the height.
const float POINT_POSE_SPARE = 1.0e-3;

// How far a one-sided hinge is turned past straight when its limb is squeezed,
// in radians (about three degrees) — see `PointSolve.unfold_want`.
const float POINT_POSE_BEND = 0.05;

// How much shorter than straight a hinge's two bones have to be asked to reach
// before it counts as squeezed, as a share of their length: well under the three
// degrees of `POINT_POSE_BEND`, which shortens them by about 0.03%.
const float POINT_POSE_SQUEEZED = 1.0e-3;

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
	bool trunk;                  // drawn back toward its posture, and leans for the balance
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
	int iterations;          // zero for `POINT_POSE_ITERATIONS`
	bool balance;            // keep the centre of mass over the hard goals planted below the root
	Quaternionf[] posture;   // per skeleton joint, the local rotation a trunk joint is drawn toward; empty for none
	float posture_pull;      // share of a trunk joint's drift from `posture` undone per iteration, 0 to 1
	float balance_miss;      // out: how far the centre of mass ended from over what the body stands on
}

fn bool PointJoint.limited(&self) => self.limits.constrained && self.frame.usable();

<*
 How heavy each joint is to the solve, as an inverse mass per skeleton joint.

 Read off the rig's shape, not its names. A joint is *trunk* when two or more
 limbs hang below it — a chest carrying both arms and the head, a spine carrying
 the chest — where a limb is any branch longer than `POINT_POSE_LIMB_SHARE` of
 the height, so a hand's five fingers do not make the wrist trunk; so is the
 root's main branch, the one that does not hang from it and carries the most. A
 root is the heaviest of all. A trunk joint's mass is shared by the joints it carries rigidly
 (the children of a fork), so a hip socket weighs what the pelvis weighs and a
 thigh pulled sideways tilts the pelvis only a little.

 @param inv_mass : `One per skeleton joint; filled.`
 @param trunk_out : `One per skeleton joint, or empty: filled with whether it is the trunk or the root.`
*>
fn void point_pose_masses(rig::Skeleton* skeleton, float height, float[] inv_mass, bool[] trunk_out = {})
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
		if (parent < 0)
		{
			mass = POINT_POSE_ROOT_MASS;
		}
		else if (trunk[j])
		{
			mass = POINT_POSE_TRUNK_MASS;
		}
		// Carried rigidly by a trunk fork: as heavy as the fork.
		if (parent >= 0 && (trunk[(usz)parent] || skeleton.parents[(usz)parent] < 0))
		{
			mass = math::max(mass, skeleton.parents[(usz)parent] < 0 ? POINT_POSE_ROOT_MASS : POINT_POSE_TRUNK_MASS);
		}
		inv_mass[j] = 1.0f / mass;
		if (j < trunk_out.len) trunk_out[j] = trunk[j] || parent < 0;
	}
}

<*
 Solve `pose` in place so the joints in play meet `goals`.

 @return `The largest miss of any position goal still standing, in model units; each goal's own is in its residual.`
*>
fn float point_pose(rig::Skeleton* skeleton, rig::Pose* pose, PointJoint[] joints, PointGoal[] goals,
	PointPoseSettings* settings)
{
	usz n = skeleton.len();
	if (n == 0 || pose.rotations.len != n || pose.offsets.len != n) return 0.0f;
	float h = settings.height > 0.0f ? settings.height : 1.0f;

	// What the hard goals missed by before anything moved, and where the soft
	// goals' joints stood: the pose to fall back to, and the floor a retry is
	// judged against.
	rig::Pose start = pose.copy(mem);
	defer start.free(mem);
	Vec3[] targets = alloc::new_array(mem, Vec3, (sz)goals.len);
	defer alloc::free(mem, targets);
	Vec3[] from = alloc::new_array(mem, Vec3, (sz)goals.len);
	defer alloc::free(mem, from);
	float[] held = alloc::new_array(mem, float, (sz)goals.len);
	defer alloc::free(mem, held);
	bool soft = false;
	Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
	if (try palette = built)
	{
		defer alloc::free(mem, palette);
		foreach (usz g, goal : goals)
		{
			targets[g] = goal.target;
			if (goal.joint >= n) continue;
			from[g] = skeleton.joints[goal.joint].transform(palette[goal.joint]);
			held[g] = (from[g] - goal.target).length();
			if (goal.soft && goal.position) soft = true;
		}
	}

	float worst = point_pose_once(skeleton, pose, joints, goals, settings);
	if (!soft || point_pose_holds(goals, held, h)) return worst;

	// The grab asked for more than the pins allow, and the relaxation followed it
	// past where they hold. Bisect how far the soft goals are carried toward their
	// targets for the furthest every hard goal still holds at — the grab gives
	// way, the pins do not.
	rig::Pose best = start.copy(mem);
	defer best.free(mem);
	float low = 0.0f;
	float high = 1.0f;
	for (int step = 0; step < POINT_POSE_GIVE_STEPS; step++)
	{
		float middle = (low + high) * 0.5f;
		foreach (usz g, &goal : goals)
		{
			if (goal.soft && goal.position) goal.target = from[g] + (targets[g] - from[g]) * middle;
		}
		pose.rotations[..] = start.rotations[..];
		pose.offsets[..] = start.offsets[..];
		worst = point_pose_once(skeleton, pose, joints, goals, settings);
		if (point_pose_holds(goals, held, h))
		{
			low = middle;
			best.rotations[..] = pose.rotations[..];
			best.offsets[..] = pose.offsets[..];
		}
		else
		{
			high = middle;
		}
	}
	// The answer, measured against the targets that were asked for.
	foreach (usz g, &goal : goals) goal.target = targets[g];
	// Not even the smallest step holds: the body stays where the pins had it.
	pose.rotations[..] = best.rotations[..];
	pose.offsets[..] = best.offsets[..];
	return point_pose_measure(skeleton, pose, goals);
}

<*
 Whether every hard position holds: no further from its target than it began,
 or than the tolerance, whichever is more — a pin that began out of reach is not
 asked to come in.

 Positions only. A pin's angle is held as far as its joint's limits let it — a
 foot kept flat while the shin tilts past what the ankle bends to has to give,
 and the limit is the one thing nothing gives on — and reports what it missed by;
 a squat deep enough to tip the feet is still a squat.
*>
fn bool point_pose_holds(PointGoal[] goals, float[] held, float h) @local
{
	foreach (usz g, goal : goals)
	{
		if (goal.soft || goal.stood_down) continue;
		if (goal.position && goal.residual > math::max(held[g], h * POINT_POSE_HOLD)) return false;
	}
	return true;
}

<*
 Every goal's residual against `pose` as `joint_palette` builds it, and the
 largest position miss.
*>
fn float point_pose_measure(rig::Skeleton* skeleton, rig::Pose* pose, PointGoal[] goals) @local
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

// One relaxation of `pose` toward `goals`, warm-started from it.
fn float point_pose_once(rig::Skeleton* skeleton, rig::Pose* pose, PointJoint[] joints, PointGoal[] goals,
	PointPoseSettings* settings) @local
{
	PointSolve s;
	s.open(skeleton, pose, joints, goals, settings);
	defer s.free();
	if (s.active)
	{
		int iterations = settings.iterations > 0 ? settings.iterations : POINT_POSE_ITERATIONS;
		float still = s.h * POINT_POSE_STILL;
		// The best iteration is kept, not the last: pressed against its limits a
		// nearly straight limb can fall into a cycle the passes do not leave, and
		// what is shown is then the nearest the cycle came.
		Quaternionf[] best_local = alloc::new_array(mem, Quaternionf, (sz)s.n);
		defer alloc::free(mem, best_local);
		Vec3[] best_x = alloc::new_array(mem, Vec3, (sz)s.n);
		defer alloc::free(mem, best_x);
		// A pose that already meets every goal is the answer: a pointer that has
		// stopped asks for nothing new, and the passes could only wander from it.
		float best = s.error() <= s.h * POINT_POSE_MET ? -1.0f : float::max;
		best_local[..] = s.local[..];
		best_x[..] = s.x[..];
		for (int iteration = 0; iteration < iterations && best >= 0.0f; iteration++)
		{
			foreach (usz j, at : s.x) s.was[j] = at;
			s.want(iteration);
			s.place(iteration);
			float error = s.error();
			if (error < best)
			{
				best = error;
				best_local[..] = s.local[..];
				best_x[..] = s.x[..];
			}
			float moved = 0.0f;
			foreach (usz j, at : s.x) if (s.particle[j]) moved = math::max(moved, (at - s.was[j]).length());
			if (moved < still) break;
		}
		s.local[..] = best_local[..];
		s.x[..] = best_x[..];
		s.walk();
	}
	settings.balance_miss = s.balance_on ? s.balance_miss().length() : 0.0f;
	return s.finish(pose);
}

// ---------------------------------------------------------------------------
// The solve's working state

struct PointSolve @local
{
	rig::Skeleton* skeleton;
	PointJoint[] joints;
	PointGoal[] goals;
	PointPoseSettings* settings;
	usz n;
	float h;
	Vec3 up;
	bool active;             // anything to solve at all
	bool balance_on;
	sz[] slot;               // per joint: its PointJoint, or -1 when not in play
	sz[] goal;               // per joint: its PointGoal, or -1
	bool[] framed;           // its turn is solved: a goal, the floor or the balance below it
	bool[] particle;         // a point the passes read: framed, a framed joint's child, or a goal
	Vec3[] x;                // where each joint is, as the last pass placed it
	Vec3[] was;
	Vec3[] y;                // where each joint wants to be
	float[] say;             // how strongly: 0 for nothing, 1 for a grab, `POINT_POSE_HARD` for a pin
	Vec3[] rest;             // offset from the parent in the parent's frame; a root's is its position
	Quaternionf[] local;
	Quaternionf[] world;
	Quaternionf[] start;     // the local rotations handed in, for frozen joints
	usz[] child_from;        // children of joint j are child_list[child_from[j] .. child_from[j + 1]]
	usz[] child_list;
	int[] hinge;             // per joint: the one-sided hinge axis, or -1
	float[] opens;           // +1 or -1: the side that hinge's range opens to
	int[] plane;             // per joint: the one axis it bends about, the other swing locked, or -1
	float[] deficit;         // per one-sided hinge: how much shorter than its two bones laid straight it can reach
	float[] balance_mass;
	float balance_total;
	Vec3[POINT_POSE_SUPPORTS] stands;   // where the body stands: hard goals below the root, flattened
	usz stand_count;
	float[] reach;           // per hard goal g and joint j, at [g * n + j]: 1 when g hangs below j, else -1
}

fn void PointSolve.open(&self, rig::Skeleton* skeleton, rig::Pose* pose, PointJoint[] joints, PointGoal[] goals,
	PointPoseSettings* settings)
{
	usz n = skeleton.len();
	self.skeleton = skeleton;
	self.joints = joints;
	self.goals = goals;
	self.settings = settings;
	self.n = n;
	self.h = settings.height > 0.0f ? settings.height : 1.0f;
	self.up = settings.up.length_sq() > 1.0e-12f ? settings.up.normalize() : (Vec3){ 0, 1, 0 };
	self.slot = alloc::new_array(mem, sz, (sz)n);
	self.goal = alloc::new_array(mem, sz, (sz)n);
	self.framed = alloc::new_array(mem, bool, (sz)n);
	self.particle = alloc::new_array(mem, bool, (sz)n);
	self.x = alloc::new_array(mem, Vec3, (sz)n);
	self.was = alloc::new_array(mem, Vec3, (sz)n);
	self.y = alloc::new_array(mem, Vec3, (sz)n);
	self.say = alloc::new_array(mem, float, (sz)n);
	self.rest = alloc::new_array(mem, Vec3, (sz)n);
	self.local = alloc::new_array(mem, Quaternionf, (sz)n);
	self.world = alloc::new_array(mem, Quaternionf, (sz)n);
	self.start = alloc::new_array(mem, Quaternionf, (sz)n);
	self.child_from = alloc::new_array(mem, usz, (sz)n + 1);
	self.child_list = alloc::new_array(mem, usz, (sz)n);
	self.hinge = alloc::new_array(mem, int, (sz)n);
	self.opens = alloc::new_array(mem, float, (sz)n);
	self.plane = alloc::new_array(mem, int, (sz)n);
	self.deficit = alloc::new_array(mem, float, (sz)n);
	self.balance_mass = alloc::new_array(mem, float, (sz)n);
	self.reach = alloc::new_array(mem, float, (sz)(n * goals.len + 1));

	for (usz j = 0; j < n; j++)
	{
		self.slot[j] = -1;
		self.goal[j] = -1;
		self.hinge[j] = -1;
		self.plane[j] = -1;
	}
	foreach (usz i, pj : joints) if (pj.joint < n) self.slot[pj.joint] = (sz)i;

	// Where everything stands: the same walk `joint_palette` does, kept as points
	// and world rotations.
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		self.local[j] = pose.rotations[j];
		self.start[j] = pose.rotations[j];
		if (parent < 0)
		{
			self.rest[j] = skeleton.joints[j] + pose.offsets[j];
			self.x[j] = self.rest[j];
			self.world[j] = pose.rotations[j];
			continue;
		}
		self.rest[j] = skeleton.joints[j] - skeleton.joints[(usz)parent] + pose.offsets[j];
		self.x[j] = self.x[(usz)parent] + self.world[(usz)parent].rotate_vec3(self.rest[j]);
		self.world[j] = self.world[(usz)parent].mul(pose.rotations[j]).normalize();
	}

	// Children, parents first.
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		if (parent >= 0) self.child_from[(usz)parent + 1]++;
	}
	for (usz j = 0; j < n; j++) self.child_from[j + 1] += self.child_from[j];
	usz[] filled = alloc::new_array(mem, usz, (sz)n);
	defer alloc::free(mem, filled);
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		if (parent < 0) continue;
		self.child_list[self.child_from[(usz)parent] + filled[(usz)parent]++] = j;
	}

	// The goals, each on a joint in play. A hard position out of its limb's reach
	// when the solve begins cannot be held by anything the limb does: it stands
	// down and reports its miss rather than dragging the body after it.
	foreach (usz g, &goal : goals)
	{
		goal.residual = 0.0f;
		goal.turn_residual = 0.0f;
		goal.stood_down = false;
		if (goal.joint >= n || self.slot[goal.joint] < 0) continue;
		if (goal.position && !goal.soft && !self.in_reach(goal.joint, goal.target))
		{
			goal.stood_down = true;
			if (!goal.rotation) continue;
		}
		self.goal[goal.joint] = (sz)g;
	}

	// Which joints each hard goal hangs below: the ones whose wants it bounds.
	foreach (usz g, goal : goals)
	{
		for (usz j = 0; j < n; j++) self.reach[g * n + j] = -1.0f;
		if (goal.joint >= n || self.goal[goal.joint] != (sz)g || !goal.position || goal.soft || goal.stood_down) continue;
		for (int walk = skeleton.parents[goal.joint]; walk >= 0 && self.slot[(usz)walk] >= 0; walk = skeleton.parents[(usz)walk])
		{
			self.reach[g * n + (usz)walk] = 1.0f;
		}
	}

	// Framed: every joint in play above a goal or a floored joint — and, for the
	// balance, every trunk joint, which leans for it whatever else is held.
	for (usz j = 0; j < n; j++)
	{
		if (self.slot[j] < 0) continue;
		bool floored = settings.has_floor && joints[(usz)self.slot[j]].floored;
		if (self.goal[j] < 0 && !floored) continue;
		self.particle[j] = true;
		for (int walk = skeleton.parents[j]; walk >= 0 && self.slot[(usz)walk] >= 0; walk = skeleton.parents[(usz)walk])
		{
			self.framed[(usz)walk] = true;
		}
	}
	if (settings.balance && self.stands_on_something())
	{
		for (usz j = 0; j < n; j++)
		{
			if (self.slot[j] < 0 || !joints[(usz)self.slot[j]].trunk || !self.any_framed_in_tree(j)) continue;
			if (self.child_from[j + 1] > self.child_from[j]) self.framed[j] = true;
		}
	}
	for (usz j = 0; j < n; j++)
	{
		if (!self.framed[j]) continue;
		self.particle[j] = true;
		for (usz k = self.child_from[j]; k < self.child_from[j + 1]; k++)
		{
			usz child = self.child_list[k];
			if (self.slot[child] >= 0) self.particle[child] = true;
		}
	}
	for (usz j = 0; j < n; j++)
	{
		self.y[j] = self.x[j];
		if (!self.particle[j]) continue;
		self.active = true;
		self.find_hinge(j);
	}
	self.open_balance();
}

fn void PointSolve.free(&self)
{
	alloc::free(mem, self.slot);
	alloc::free(mem, self.goal);
	alloc::free(mem, self.framed);
	alloc::free(mem, self.particle);
	alloc::free(mem, self.x);
	alloc::free(mem, self.was);
	alloc::free(mem, self.y);
	alloc::free(mem, self.say);
	alloc::free(mem, self.rest);
	alloc::free(mem, self.local);
	alloc::free(mem, self.world);
	alloc::free(mem, self.start);
	alloc::free(mem, self.child_from);
	alloc::free(mem, self.child_list);
	alloc::free(mem, self.hinge);
	alloc::free(mem, self.opens);
	alloc::free(mem, self.plane);
	alloc::free(mem, self.deficit);
	alloc::free(mem, self.balance_mass);
	alloc::free(mem, self.reach);
}

fn PointJoint* PointSolve.joint_of(&self, usz j) => &self.joints[(usz)self.slot[j]];

fn bool PointSolve.frozen(&self, usz j) => self.slot[j] >= 0 && self.joint_of(j).frozen;

fn bool PointSolve.trunk(&self, usz j) => self.slot[j] >= 0 && self.joint_of(j).trunk;

// The goal on `j` that holds its world rotation, or null.
fn PointGoal* PointSolve.turn_goal(&self, usz j)
{
	if (self.goal[j] < 0) return null;
	PointGoal* goal = &self.goals[(usz)self.goal[j]];
	return goal.rotation ? goal : null;
}

// The goal on `j` that holds its position, or null.
fn PointGoal* PointSolve.place_goal(&self, usz j)
{
	if (self.goal[j] < 0) return null;
	PointGoal* goal = &self.goals[(usz)self.goal[j]];
	return goal.position && !goal.stood_down ? goal : null;
}

fn Quaternionf PointSolve.above(&self, usz j)
{
	int parent = self.skeleton.parents[j];
	return parent >= 0 ? self.world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
}

// Whether anything in the tree `j` belongs to is framed — a balance has nothing to
// lean in a tree no goal is in.
fn bool PointSolve.any_framed_in_tree(&self, usz j)
{
	usz root = j;
	while (self.skeleton.parents[root] >= 0) root = (usz)self.skeleton.parents[root];
	return self.framed[root];
}

<*
 Whether any hard position is planted below the root of its tree — the only
 thing a balance can stand on.
*>
fn bool PointSolve.stands_on_something(&self)
{
	foreach (goal : self.goals)
	{
		if (goal.joint >= self.n || self.goal[goal.joint] < 0 || !goal.position || goal.soft || goal.stood_down) continue;
		usz root = goal.joint;
		while (self.skeleton.parents[root] >= 0) root = (usz)self.skeleton.parents[root];
		if (goal.target.dot(self.up) < self.x[root].dot(self.up)) return true;
	}
	return false;
}

<*
 Whether `target` is within reach of the limb `joint` ends: no further from the
 nearest fork or root above it than the bones between them are long.
*>
fn bool PointSolve.in_reach(&self, usz joint, Vec3 target)
{
	float reach = 0.0f;
	usz walk = joint;
	while (true)
	{
		int parent = self.skeleton.parents[walk];
		if (parent < 0 || self.slot[(usz)parent] < 0) break;
		reach += self.rest[walk].length();
		walk = (usz)parent;
		if (self.child_from[walk + 1] - self.child_from[walk] != 1) break;
	}
	if (walk == joint) return true;
	return (target - self.x[walk]).length() <= reach + self.h * 1.0e-3f;
}

<*
 The joint's hinge, if it is one. `plane` is the one axis square to the bone it
 bends about when the other is locked — a knee, an elbow — whatever its twist
 does; `hinge` is that axis again when its range opens one way only from rest,
 which a squeezed limb has to be folded along (`unfold_want`).
*>
fn void PointSolve.find_hinge(&self, usz j)
{
	if (!self.framed[j] || self.child_from[j + 1] - self.child_from[j] != 1) return;
	PointJoint* pj = self.joint_of(j);
	if (!pj.limited()) return;
	// Of the two axes square to the bone (Y is the bone), one bends and the other
	// is locked: the joint bends in one plane.
	JointAxisLimit across = pj.limits.axes[0];
	JointAxisLimit along = pj.limits.axes[2];
	if (across.allowed != along.allowed) self.plane[j] = across.allowed ? 0 : 2;
	int parent = self.skeleton.parents[j];
	if (parent < 0 || !self.particle[(usz)parent]) return;
	foreach (usz k, axis : pj.limits.axes)
	{
		if (!axis.allowed || axis.maximum - axis.minimum < POINT_POSE_BEND * 4.0f) continue;
		if (math::abs(axis.minimum) < 1.0e-3f) { self.opens[j] = 1.0f; }
		else if (math::abs(axis.maximum) < 1.0e-3f) { self.opens[j] = -1.0f; }
		else { continue; }
		self.hinge[j] = (int)k;
		// Modelled bent the way it opens, the hinge cannot straighten past its rest:
		// the limb reaches no further than its rest chord.
		usz child = self.child_list[self.child_from[j]];
		Vec3 axis_rest = pj.frame.rotation.normalize().rotate_vec3(AXIS_DIRECTION[k]);
		Vec3 upper = self.rest[j] - axis_rest * self.rest[j].dot(axis_rest);
		Vec3 lower = self.rest[child] - axis_rest * self.rest[child].dot(axis_rest);
		float bend = math::atan2(axis_rest.dot(upper.cross(lower)), upper.dot(lower));
		if (bend * self.opens[j] > 0.0f)
		{
			self.deficit[j] = self.rest[j].length() + self.rest[child].length() - (self.rest[j] + self.rest[child]).length();
		}
		return;
	}
}

// Where a child is to be aimed at, and how strongly it asks: its want, or — when
// nothing pulls on it — where it is, barely.
fn Vec3 PointSolve.aim_of(&self, usz c, float* weight)
{
	if (self.say[c] > 0.0f)
	{
		*weight = self.say[c];
		return self.y[c];
	}
	*weight = POINT_POSE_IDLE;
	return self.x[c];
}

// ---------------------------------------------------------------------------
// Wants: leaves first

<*
 Every point's want, leaves first.

 A joint with a goal of its own wants the goal's target: a pin outright, a grab
 as far as the pins allow. Any other weighs what its bones say given what its
 children want (`propose`) and, on a trunk joint, the balance, against where it
 is, by its mass. Then every want is kept where the hard goals below the joint
 can still be reached from it — within its bones' length of each one — and above
 the floor. That is all a pin asks of the joints above it: a leg whose foot is
 pinned does not hold the hips where they are, only within its reach.
*>
fn void PointSolve.want(&self, int iteration)
{
	float settling = math::pow(POINT_POSE_SETTLING, (float)iteration);
	Vec3 lean = {};
	if (self.balance_on) lean = self.balance_miss();
	for (usz step = self.n; step > 0; step--)
	{
		usz j = step - 1;
		self.say[j] = 0.0f;
		self.y[j] = self.x[j];
		if (!self.particle[j]) continue;
		PointGoal* goal = self.place_goal(j);
		if (goal && !goal.soft)
		{
			self.y[j] = goal.target;
			self.say[j] = POINT_POSE_HARD;
			continue;
		}
		if (goal)
		{
			// The grab, heard over what its bones say: where the body can follow,
			// they come to agree with it; where it cannot, they draw it the way the
			// pinned limbs below need — a pelvis pulled lower than flat feet allow
			// goes back, not through.
			Vec3 sum = goal.target * POINT_POSE_GRAB;
			float weight = POINT_POSE_GRAB;
			Vec3 at;
			float said;
			if (self.framed[j] && self.propose(j, &at, &said))
			{
				sum = sum + at;
				weight += 1.0f;
			}
			self.y[j] = sum / weight;
			self.say[j] = 1.0f;
		}
		else
		{
			Vec3 sum = {};
			float weight = 0.0f;
			if (self.framed[j])
			{
				Vec3 at;
				float said;
				if (self.propose(j, &at, &said))
				{
					sum = at;
					weight = 1.0f;
					self.say[j] = said;
				}
				if (self.balance_on && self.trunk(j))
				{
					sum = sum + (self.x[j] + lean) * POINT_POSE_BALANCE;
					weight += POINT_POSE_BALANCE;
					self.say[j] = math::max(self.say[j], POINT_POSE_BALANCE);
				}
			}
			if (weight > 0.0f)
			{
				float inertia = self.inertia(j) * settling;
				self.y[j] = (sum + self.x[j] * inertia) / (weight + inertia);
			}
		}
		self.keep_reach(j);
		if (self.settings.has_floor && self.joint_of(j).floored)
		{
			float under = self.settings.floor - self.y[j].dot(self.up);
			if (under > 0.0f)
			{
				self.y[j] = self.y[j] + self.up * under;
				self.say[j] = math::max(self.say[j], 1.0f);
			}
		}
	}
}

<*
 Bring joint `j`'s want back within reach of every hard goal below it, a few
 rounds since bringing it within one may take it out of another's.

 The reach is read along the path from `j` down to the goal. A bone below a joint
 with one child may point anywhere, so its length is slack; a bone below a fork
 is held by the fork's turn with its siblings, so it is an offset, taken as it
 stands now. The goal holds when `j`, carried by those offsets, is within the
 slack of the goal's target: a pelvis cannot rise past where the legs hanging off
 its sides reach, whatever the bones from it to the feet add up to.
*>
fn void PointSolve.keep_reach(&self, usz j)
{
	for (int round = 0; round < 4; round++)
	{
		bool moved = false;
		foreach (usz g, goal : self.goals)
		{
			if (self.reach[g * self.n + j] < 0.0f) continue;
			float slack = 0.0f;
			Vec3 offset = {};
			Vec3 target = goal.target;
			usz from = goal.joint;
			// A pin that holds its angle too lets the bone above it tilt only as far
			// as its own limits allow, and the parent's want was already kept inside
			// that (`propose`): the reach is read from there.
			int over = self.skeleton.parents[goal.joint];
			if (goal.rotation && over >= 0 && (usz)over != j && self.joint_of(goal.joint).limited())
			{
				target = self.y[(usz)over];
				from = (usz)over;
			}
			for (usz walk = from; walk != j;)
			{
				usz parent = (usz)self.skeleton.parents[walk];
				if (self.child_from[parent + 1] - self.child_from[parent] == 1)
				{
					slack += self.rest[walk].length();
					// A hinge with both its bones on the path, short of straight.
					if (parent != j && self.skeleton.parents[parent] >= 0
						&& self.child_from[(usz)self.skeleton.parents[parent] + 1] - self.child_from[(usz)self.skeleton.parents[parent]] == 1)
					{
						slack -= self.deficit[parent];
					}
				}
				else
				{
					offset = offset + (self.x[walk] - self.x[parent]);
				}
				walk = parent;
			}
			// A hair inside full reach, so a limb holding a pin is never asked to be
			// straighter than its joints can make it.
			slack = math::max(slack - self.h * POINT_POSE_SPARE, 0.0f);
			Vec3 away = self.y[j] + offset - target;
			float length = away.length();
			if (length <= slack) continue;
			self.y[j] = target - offset + away * (slack / length);
			moved = true;
		}
		if (!moved) return;
	}
}

<*
 How much a joint holds to where it is against what asks it to move: none for a
 limb, which goes where it is asked, and more the heavier — the trunk, the root —
 so the body is moved by a pull only as far as its limbs cannot answer it.
*>
fn float PointSolve.inertia(&self, usz j)
{
	float inv = self.joint_of(j).inv_mass;
	if (inv <= 0.0f) return POINT_POSE_HARD;
	return math::max(1.0f / inv - 1.0f, 0.0f);
}

<*
 Where framed joint `j`'s bones put it, given what its children want: with one
 child, its bone's length back from the child's want along the line to where `j`
 is now (FABRIK's step); with several, where the cluster — `j` and its children,
 as it is turned now — sits best on their wants. A joint holding a world
 rotation, or frozen, keeps the turn it must have.

 @return `False when no child wants anything, so the bones say nothing.`
*>
fn bool PointSolve.propose(&self, usz j, Vec3* at, float* said)
{
	usz first = self.child_from[j];
	usz count = self.child_from[j + 1] - first;
	float strongest = 0.0f;
	for (usz k = first; k < first + count; k++) strongest = math::max(strongest, self.say[self.child_list[k]]);
	if (strongest <= 0.0f) return false;
	*said = strongest;

	PointGoal* turned = self.turn_goal(j);
	bool fixed = turned != null || self.frozen(j);
	if (fixed)
	{
		Quaternionf r = turned ? turned.orient : self.above(j).mul(self.start[j]).normalize();
		Vec3 sum = {};
		float weight = 0.0f;
		for (usz k = first; k < first + count; k++)
		{
			usz c = self.child_list[k];
			float w;
			Vec3 aim = self.aim_of(c, &w);
			sum = sum + (aim - r.rotate_vec3(self.rest[c])) * w;
			weight += w;
		}
		*at = sum / weight;
		return true;
	}
	if (count == 1)
	{
		usz c = self.child_list[first];
		PointGoal* held = self.turn_goal(c);
		Vec3 up_bone = self.x[j] - self.y[c];
		if (held && self.joint_of(c).limited() && up_bone.length_sq() > 1.0e-18f)
		{
			// The child holds its world rotation, and its limits allow that only from
			// a bone above it within their range: the bone turned the usual way, then
			// the nearest one in range if that is not.
			Quaternionf shin = self.above(j).mul(self.local[j]).normalize();
			shin = bone_carry(shin.rotate_vec3(self.rest[c]), -up_bone).mul(shin).normalize();
			Quaternionf local = shin.invert().mul(held.orient).normalize();
			Quaternionf allowed = self.limited(c, local);
			if (math::abs(allowed.v.dot(local.v)) < 1.0f - 1.0e-7f) shin = held.orient.mul(allowed.invert()).normalize();
			*at = self.y[c] - shin.rotate_vec3(self.rest[c]);
			return true;
		}
		Vec3 back = self.x[j] - self.y[c];
		float length = back.length();
		if (length <= 1.0e-9f)
		{
			*at = self.x[j];
			return true;
		}
		if (self.unfold_want(j, c, at)) return true;
		// Back along the bone as the joint's limits let it point at the child's want,
		// so a joint pressed against its limit asks the joints above it to make up
		// the difference — the way a pull slides along a limit rather than stopping.
		// Not on a pinned chain: what holds a pin is its reach, kept by `keep_reach`,
		// and reading its bones through the frames above as they last stood would
		// feed every turn of the pelvis back into where the legs ask it to be.
		Quaternionf above = self.above(j);
		Quaternionf aimed;
		if (self.say[c] < POINT_POSE_HARD && self.aim_local(j, self.rest[c], above.invert().rotate_vec3(-back), &aimed))
		{
			*at = self.y[c] - above.mul(aimed).rotate_vec3(self.rest[c]);
			return true;
		}
		*at = self.y[c] + back * (self.rest[c].length() / length);
		return true;
	}

	// The cluster slid, not turned, to sit best on its children's wants: where the
	// fork goes is the wants' to say, which way it faces the turn's (`turn`), with
	// the children nothing pulls on holding it as it is. Turned here too, one far
	// pull on a short bone would spin the whole cluster and drag the fork round
	// with it. The children nothing pulls on have no say in the slide: they go
	// wherever the cluster does. Those that are pulled say alike, a pinned leg as
	// much as a grabbed spine: what a pin asks of the joints above it is only to
	// stay within its reach, and `keep_reach` holds them to that.
	Quaternionf r = self.world[j];
	Vec3 sum = {};
	float total = 0.0f;
	for (usz k = first; k < first + count; k++)
	{
		usz c = self.child_list[k];
		if (self.say[c] <= 0.0f) continue;
		sum = sum + (self.y[c] - r.rotate_vec3(self.rest[c]));
		total += 1.0f;
	}
	*at = sum / total;
	return true;
}

// ---------------------------------------------------------------------------
// Placing: root first

<*
 Every joint placed, root first: the root where it wants to be, every other
 joint where its parent's turn and its bone put it, and each framed joint turned
 to aim its children at their wants (`turn`). A joint nothing asks of keeps its
 rotation and rides.
*>
fn void PointSolve.place(&self, int iteration)
{
	float settling = math::pow(POINT_POSE_SETTLING, (float)iteration);
	for (usz j = 0; j < self.n; j++)
	{
		if (self.slot[j] < 0) continue;
		int parent = self.skeleton.parents[j];
		if (parent < 0)
		{
			if (self.particle[j] && self.say[j] > 0.0f) self.x[j] = self.y[j];
		}
		else
		{
			self.x[j] = self.x[(usz)parent] + self.world[(usz)parent].rotate_vec3(self.rest[j]);
		}
		Quaternionf above = self.above(j);
		if (self.framed[j])
		{
			self.turn(j, above, settling);
		}
		else if (self.particle[j] && self.turn_goal(j))
		{
			self.local[j] = self.limited(j, above.invert().mul(self.turn_goal(j).orient).normalize());
		}
		self.world[j] = above.mul(self.local[j]).normalize();
	}
}

<*
 Turn framed joint `j`, already placed, to aim its children at their wants.

 One child: the bone is aimed keeping the joint's twist (`aim_in_frame`, or the
 shortest turn for a joint with no limits), and rolled to face the hinge below
 if there is one (`roll_to_plane`). Several: the cluster's best turn about the
 joint. Then a trunk joint is drawn toward its posture, and the result clamped to
 the joint's limits. A frozen joint keeps its
 turn; a joint holding a world rotation takes it.
*>
fn void PointSolve.turn(&self, usz j, Quaternionf above, float settling)
{
	if (self.frozen(j))
	{
		self.local[j] = self.start[j];
		return;
	}
	PointGoal* turned = self.turn_goal(j);
	if (turned)
	{
		self.local[j] = self.limited(j, above.invert().mul(turned.orient).normalize());
		return;
	}
	usz first = self.child_from[j];
	usz count = self.child_from[j + 1] - first;
	if (count == 1)
	{
		usz c = self.child_list[first];
		float w;
		Vec3 aim = self.aim_of(c, &w);
		Vec3 d = aim - self.x[j];
		Vec3 bone = self.rest[c];
		if (bone.length_sq() > 1.0e-14f && d.length_sq() > 1.0e-14f)
		{
			Vec3 want = above.invert().rotate_vec3(d);
			if (!self.aim_in_frame(j, bone, want))
			{
				Vec3 have = self.local[j].rotate_vec3(bone);
				self.local[j] = bone_carry(have, want).mul(self.local[j]).normalize();
			}
			self.roll_to_plane(j, c, above);
		}
	}
	else if (count > 1)
	{
		Quaternionf r = above.mul(self.local[j]).normalize();
		for (int iteration = 0; iteration < 24; iteration++)
		{
			Vec3 torque = {};
			float along = 0.0f;
			for (usz k = first; k < first + count; k++)
			{
				usz c = self.child_list[k];
				float w;
				Vec3 aim = self.aim_of(c, &w);
				Vec3 turned_rest = r.rotate_vec3(self.rest[c]);
				Vec3 p = aim - self.x[j];
				torque = torque + turned_rest.cross(p) * w;
				along += turned_rest.dot(p) * w;
			}
			if (!point_turn_by(&r, torque, along)) break;
		}
		self.local[j] = above.invert().mul(r).normalize();
	}
	// Along the trunk the posture fades as the solve goes on, as the inertia does:
	// it chooses which way the trunk takes up a pull while there is a choice, and
	// leaves the pull its due once there is not. The root's stays: a body carried
	// whole by a pull with nothing pinned slides, it does not tip.
	PointPoseSettings* settings = self.settings;
	if (self.trunk(j) && settings.posture.len == self.n && settings.posture_pull > 0.0f)
	{
		Quaternionf toward = settings.posture[j];
		if (toward.v.dot(self.local[j].v) < 0.0f) toward.v = -toward.v;
		float pull = self.skeleton.parents[j] < 0 ? settings.posture_pull : settings.posture_pull * settling;
		self.local[j] = self.local[j].slerp(toward, pull).normalize();
	}
	if (self.skeleton.parents[j] < 0 && self.balance_on) self.local[j] = self.tilt_for_balance(j).mul(self.local[j]).normalize();
	self.local[j] = self.limited(j, self.local[j]);
}

// `local` clamped to joint `j`'s limits, when it has any.
fn Quaternionf PointSolve.limited(&self, usz j, Quaternionf local)
{
	PointJoint* pj = self.joint_of(j);
	return pj.limited() ? constrain_joint_rotation(pj.frame, pj.limits, local) : local;
}

<*
 Turn limited joint `j` so its bone points along `want` (in the parent's frame),
 keeping the twist it had.

 The limits are an X, Y, Z table in the joint's frame, Y along the bone, applied
 Z after Y after X. The shortest turn onto a new direction is not a pure swing in
 those terms — it carries some Y — so a joint whose twist is locked, a clavicle,
 would be clamped off its own direction every iteration and fight its way back.
 Here the twist is kept where it was, inside its range, and the other two angles
 are solved for the direction exactly: with the twist y, the bone points along
 Rz(z) · (sin x sin y, cos x, sin x cos y), so sin x is the direction's Z over
 cos y and z what turns the rest into its X and Y.

 @return `False when this joint is not one the table can aim — no limits, a frame not along this bone, a twist near a quarter turn, or a bone near the frame's Z — and the caller carries it instead.`
*>
fn bool PointSolve.aim_in_frame(&self, usz j, Vec3 bone, Vec3 want)
{
	Quaternionf aimed;
	if (!self.aim_local(j, bone, want, &aimed)) return false;
	self.local[j] = aimed;
	return true;
}

<*
 The local rotation `aim_in_frame` would give joint `j`, without giving it.
*>
fn bool PointSolve.aim_local(&self, usz j, Vec3 bone, Vec3 want, Quaternionf* aimed)
{
	PointJoint* pj = self.joint_of(j);
	if (!pj.limited()) return false;
	Quaternionf frame = pj.frame.rotation.normalize();
	Vec3 rest = frame.invert().rotate_vec3(bone.normalize());
	if (rest.y < 0.9999f) return false;
	Vec3 d = frame.invert().rotate_vec3(want.normalize());
	Vec3 was = joint_angles_from_rotation(pj.frame, self.local[j]);
	JointAxisLimit twist = pj.limits.axes[1];
	float y = twist.allowed ? math::clamp(was.y, twist.minimum, twist.maximum) : twist.locked;
	float cy = math::cos(y);
	if (math::abs(cy) < 0.05f) return false;
	// Near the frame's own Z the bone's turn about Z barely moves it, and Z swings
	// through half a turn for the slightest change of direction — an arm hanging
	// straight down from a shoulder whose X tilts it there. The shortest turn is
	// continuous through it: the caller carries the bone that way instead.
	if (math::abs(d.z) > math::abs(cy) * POINT_POSE_POLE) return false;
	float sx = math::clamp(d.z / cy, -1.0f, 1.0f);
	float x = math::asin(sx);
	float other = (x >= 0.0f ? (float)math::PI : -(float)math::PI) - x;
	if (math::abs(other - was.x) < math::abs(x - was.x)) x = other;
	float z = point_turn_onto(d, x, y);
	while (z - was.z > (float)math::PI) z -= 2.0f * (float)math::PI;
	while (z - was.z < -(float)math::PI) z += 2.0f * (float)math::PI;
	// Out of range, the nearest direction the table allows: each angle clamped and
	// the other turned as near as it then can, a few times over.
	JointAxisLimit tilt = pj.limits.axes[0];
	JointAxisLimit swing = pj.limits.axes[2];
	for (int round = 0; round < 3; round++)
	{
		bool tilt_out = tilt.allowed ? (x < tilt.minimum || x > tilt.maximum) : x != tilt.locked;
		bool swing_out = swing.allowed ? (z < swing.minimum || z > swing.maximum) : z != swing.locked;
		if (!tilt_out && !swing_out) break;
		x = tilt.allowed ? math::clamp(x, tilt.minimum, tilt.maximum) : tilt.locked;
		z = point_turn_onto(d, x, y);
		while (z - was.z > (float)math::PI) z -= 2.0f * (float)math::PI;
		while (z - was.z < -(float)math::PI) z += 2.0f * (float)math::PI;
		z = swing.allowed ? math::clamp(z, swing.minimum, swing.maximum) : swing.locked;
		x = point_tilt_onto(d, y, z);
		x = tilt.allowed ? math::clamp(x, tilt.minimum, tilt.maximum) : tilt.locked;
	}
	*aimed = rotation_from_joint_angles(pj.frame, { x, y, z });
	return true;
}

<*
 The Z angle that turns a bone tilted by `x` and twisted by `y` — in the frame
 its limits are read in — as near as it goes to direction `d`.
*>
fn float point_turn_onto(Vec3 d, float x, float y)
{
	float vx = math::sin(x) * math::sin(y);
	float vy = math::cos(x);
	return math::atan2(d.y, d.x) - math::atan2(vy, vx);
}

<*
 The X angle that, with twist `y` and turn `z`, brings the bone nearest to
 direction `d`: the bone is Rz(z) · (sin x sin y, cos x, sin x cos y), so against
 `d` turned back by z it reads cos x · e.y + sin x · (e.x sin y + e.z cos y).
*>
fn float point_tilt_onto(Vec3 d, float y, float z)
{
	float c = math::cos(z);
	float s = math::sin(z);
	Vec3 e = { d.x * c + d.y * s, -d.x * s + d.y * c, d.z };
	return math::atan2(e.x * math::sin(y) + e.z * math::cos(y), e.y);
}

<*
 Roll joint `j` about its own bone so the hinge below it, `child`, can bend to
 where its own child wants to be.

 A hinge — a knee, an elbow — turns about one axis, so the bone below it can only
 point somewhere on the sweep that axis carries its rest direction through. Which
 way that sweep faces is decided by the bone above: the thigh's roll is where the
 knee points. A chain of points has no roll, so the bone above is rolled by the
 least turn that puts the lower bone back on its hinge's sweep, and the hinge then
 has only its angle to answer for. Of the two rolls that do, the one that bends
 the hinge inside its range wins, then the smaller, and it is taken a step at a
 time. A limb too nearly straight to say keeps the roll it had.
*>
fn void PointSolve.roll_to_plane(&self, usz j, usz child, Quaternionf above)
{
	if (self.plane[child] < 0 || self.child_from[child + 1] - self.child_from[child] != 1) return;
	usz below = self.child_list[self.child_from[child]];
	if (!self.particle[below] || self.rest[below].length_sq() < 1.0e-12f) return;
	Quaternionf world = above.mul(self.local[j]).normalize();
	Vec3 knee = self.x[j] + world.rotate_vec3(self.rest[child]);
	float w;
	Vec3 aim = self.aim_of(below, &w);
	Vec3 upper = knee - self.x[j];
	Vec3 lower = aim - knee;
	if (upper.length_sq() < 1.0e-12f || lower.length_sq() < 1.0e-12f) return;
	Vec3 bone = upper.normalize();
	Vec3 down = lower.normalize();
	PointJoint* hinge = self.joint_of(child);
	usz k = (usz)self.plane[child];
	// The hinge axis and the lower bone's rest direction, both carried by `j` — the
	// frame below a joint is carried by its parent.
	Vec3 axis_rest = hinge.frame.rotation.rotate_vec3(AXIS_DIRECTION[k]);
	Vec3 aim_rest = self.rest[below].normalize();
	float cone = axis_rest.dot(aim_rest);
	Vec3 axis = world.rotate_vec3(axis_rest);
	Vec3 rest_down = world.rotate_vec3(aim_rest);

	// Rolled by r about the bone, the axis is a(r) = a∥ + a⊥ cos r + (b × a⊥) sin r,
	// and the lower bone lies on its sweep when a(r)·down equals `cone`.
	Vec3 along = bone * axis.dot(bone);
	Vec3 square = axis - along;
	float a = square.dot(down);
	float b = bone.cross(square).dot(down);
	float rhs = cone - along.dot(down);
	float reach = math::sqrt(a * a + b * b);
	// Nearly straight, any roll puts the bone near enough on the sweep, and which
	// one swings wildly with the smallest change in where it points.
	if (reach < POINT_POSE_ROLL_BENT || math::abs(rhs) > reach) return;
	float centre = math::atan2(b, a);
	float spread = (float)math::acos((double)(rhs / reach));
	JointAxisLimit range = hinge.limits.axes[k];
	float best = 0.0f;
	float best_score = float::max;
	foreach (float roll : (float[2]){ centre + spread, centre - spread })
	{
		while (roll > (float)math::PI) roll -= 2.0f * (float)math::PI;
		while (roll < -(float)math::PI) roll += 2.0f * (float)math::PI;
		Quaternionf turn = quaternion::from_axis_angle{float}(bone, roll);
		Vec3 rolled_axis = turn.rotate_vec3(axis);
		Vec3 rolled_down = turn.rotate_vec3(rest_down);
		float bend = math::atan2(rolled_axis.dot(rolled_down.cross(down)), rolled_down.dot(down));
		float outside = math::max(range.minimum - bend, 0.0f) + math::max(bend - range.maximum, 0.0f);
		float score = outside * 10.0f + math::abs(roll);
		if (score < best_score) { best_score = score; best = roll; }
	}
	best = math::clamp(best, -POINT_POSE_MAX_ROLL, POINT_POSE_MAX_ROLL);
	world = quaternion::from_axis_angle{float}(bone, best).mul(world).normalize();
	self.local[j] = above.invert().mul(world).normalize();
}

<*
 A one-sided hinge asked to squeeze its limb while it sits at the closed end of
 its range — straight, or bent the wrong way, as a knee modelled hyper-extended is
 at rest — wants to be off the line between its neighbours, by `POINT_POSE_BEND`
 on the side its range opens.

 A straight limb asked to shorten has nowhere to fold: each joint's want is read
 back along the line to where it is, and the line is straight. A hyper-extended
 one folds the wrong way, into its limit. So the hinge's want is pushed square off
 the line from its parent to its child's want — the knee forward — and the bone
 above is aimed there; from a little bend the right way, the next iterations fold
 it further. Squeezed means the parent is nearer the child's want than the two
 bones reach laid straight.

 @return `True when it set the want, so FABRIK's own step is not taken.`
*>
fn bool PointSolve.unfold_want(&self, usz j, usz child, Vec3* at)
{
	if (self.hinge[j] < 0) return false;
	PointJoint* pj = self.joint_of(j);
	usz k = (usz)self.hinge[j];
	if (joint_angles_from_rotation(pj.frame, self.local[j])[k] * self.opens[j] >= POINT_POSE_BEND) return false;
	usz parent = (usz)self.skeleton.parents[j];
	Vec3 line = self.y[child] - self.x[parent];
	float upper = self.rest[j].length();
	float lower = self.rest[child].length();
	float span = line.length();
	if (span <= 1.0e-9f || span >= (upper + lower) * (1.0f - POINT_POSE_SQUEEZED)) return false;
	Vec3 axis = self.above(j).mul(pj.frame.rotation).normalize().rotate_vec3(AXIS_DIRECTION[k]);
	Vec3 along = line / span;
	// Bent by +t about the hinge, the joint stands off the line on the side
	// -(axis × line); see the bend's sign in `roll_to_plane`.
	Vec3 side = axis.cross(along);
	if (side.length_sq() < 1.0e-12f) return false;
	side = side.normalize() * -self.opens[j];
	// Already standing off the line that way by the bend's worth: nothing to seed.
	Vec3 off = self.x[j] - self.x[parent];
	if (off.dot(side) >= upper * POINT_POSE_BEND) return false;
	// Where the two bones meet with the parent and the child's want `span` apart,
	// on the open side.
	float reach = (upper * upper - lower * lower + span * span) / (2.0f * span);
	float rise = math::sqrt(math::max(upper * upper - reach * reach, 0.0f));
	rise = math::max(rise, upper * POINT_POSE_BEND);
	*at = self.x[parent] + along * reach + side * rise;
	return true;
}

// ---------------------------------------------------------------------------
// The balance

<*
 The masses the balance weighs, and whether it is on. Each joint carries the bone
 above it, by rest length. The legs — every joint between the root and a hard
 goal planted below it — are then scaled to `POINT_POSE_LEG_MASS` of the whole.
 Off without such a goal: a body standing on nothing has nothing to balance over.
*>
fn void PointSolve.open_balance(&self)
{
	PointPoseSettings* settings = self.settings;
	if (!settings.balance || !self.active) return;
	bool[] leg = alloc::new_array(mem, bool, (sz)self.n);
	defer alloc::free(mem, leg);
	foreach (goal : self.goals)
	{
		if (goal.joint >= self.n || self.goal[goal.joint] < 0 || !goal.position || goal.soft || goal.stood_down) continue;
		usz root = goal.joint;
		while (self.skeleton.parents[root] >= 0) root = (usz)self.skeleton.parents[root];
		if (goal.target.dot(self.up) >= self.x[root].dot(self.up)) continue;
		for (usz walk = goal.joint; walk != root; walk = (usz)self.skeleton.parents[walk]) leg[walk] = true;
		if (self.stand_count < POINT_POSE_SUPPORTS) self.stands[self.stand_count++] = self.flat(goal.target);
	}
	float legs = 0.0f;
	float rest = 0.0f;
	for (usz j = 0; j < self.n; j++)
	{
		int parent = self.skeleton.parents[j];
		if (self.slot[j] < 0 || parent < 0) continue;
		float mass = (self.skeleton.joints[j] - self.skeleton.joints[(usz)parent]).length();
		self.balance_mass[j] = mass;
		if (leg[j]) { legs += mass; } else { rest += mass; }
	}
	if (legs <= 0.0f || rest <= 0.0f) return;
	for (usz j = 0; j < self.n; j++)
	{
		self.balance_mass[j] *= leg[j] ? POINT_POSE_LEG_MASS / legs : (1.0f - POINT_POSE_LEG_MASS) / rest;
		self.balance_total += self.balance_mass[j];
	}
	self.balance_on = self.balance_total > 0.0f;
}

<*
 The turn that leans root `j` toward keeping the centre of mass over the
 support: about the level axis square to the miss, by the angle the miss stands
 off over the height of the body above the root, a share of it each iteration.
 The root carries the whole upper body, so a pelvis pulled back over planted feet
 tips the chest forward over them, the way a person sitting back does; the legs
 below it fold to keep their feet.
*>
fn Quaternionf PointSolve.tilt_for_balance(&self, usz j)
{
	Vec3 miss = self.balance_miss();
	float length = miss.length();
	if (length < self.h * 1.0e-4f) return quaternion::IDENTITY;
	Vec3 axis = self.up.cross(miss / length);
	float lean = math::atan2(length, self.h * 0.5f) * POINT_POSE_BALANCE_TILT;
	return quaternion::from_axis_angle{float}(axis, math::min(lean, POINT_POSE_MAX_LEAN));
}

<*
 How far, across `up`, the centre of mass stands outside what the body stands on:
 zero inside the outline of its planted feet, else the way to the nearest point
 of it. A body is in no danger of falling while its weight is over its feet, so
 the balance only leans it when its weight leaves them — a dog on four pinned
 paws, standing unevenly, is not tipped sideways to put its weight over their
 middle, and a body sitting back past the line between its two feet leans
 forward until its weight is over that line again.
*>
fn Vec3 PointSolve.balance_miss(&self)
{
	Vec3 centre = self.flat(self.centre());
	usz count = self.stand_count;
	if (count == 1) return self.stands[0] - centre;
	// The outline is the convex hull of the stands, by gift wrapping: a handful of
	// feet at most. In it, nothing to correct; out of it, the nearest point of any
	// edge.
	Vec3 a = self.stands[0];
	Vec3 b = self.stands[0];
	// Two axes across `up` to measure the turn of an edge by.
	Vec3 side = math::abs(self.up.x) < 0.9f ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
	side = self.flat(side).normalize();
	Vec3 ahead = self.up.cross(side);
	usz[POINT_POSE_SUPPORTS] hull;
	usz hull_count = 0;
	usz start = 0;
	for (usz i = 1; i < count; i++)
	{
		if (self.stands[i].dot(side) < self.stands[start].dot(side)) start = i;
	}
	usz at = start;
	while (hull_count < count)
	{
		hull[hull_count++] = at;
		usz next = (at + 1) % count;
		for (usz i = 0; i < count; i++)
		{
			Vec3 e = self.stands[next] - self.stands[at];
			Vec3 f = self.stands[i] - self.stands[at];
			float turn = e.dot(side) * f.dot(ahead) - e.dot(ahead) * f.dot(side);
			if (turn < 0.0f) next = i;
		}
		at = next;
		if (at == start) break;
	}
	bool inside = hull_count >= 3;
	Vec3 nearest = self.stands[hull[0]];
	float closest = float::max;
	for (usz k = 0; k < hull_count; k++)
	{
		a = self.stands[hull[k]];
		b = self.stands[hull[(k + 1) % hull_count]];
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

fn Vec3 PointSolve.centre(&self)
{
	Vec3 sum = {};
	for (usz j = 0; j < self.n; j++) sum = sum + self.x[j] * self.balance_mass[j];
	return self.balance_total > 0.0f ? sum / self.balance_total : (Vec3){};
}

// Only the part across `up`: standing over the feet says nothing about height.
fn Vec3 PointSolve.flat(&self, Vec3 v) => v - self.up * v.dot(self.up);

// ---------------------------------------------------------------------------
// Back to a pose

<*
 Write the rotations of every joint the solve turned, and the root's slide, into
 `pose`, then measure every goal against the pose as `joint_palette` builds it. A
 frozen joint keeps the very rotation it came in with, bit for bit.
*>
fn float PointSolve.finish(&self, rig::Pose* pose)
{
	if (self.active) self.polish();
	for (usz j = 0; j < self.n; j++)
	{
		if (self.slot[j] < 0) continue;
		if (self.frozen(j)) continue;
		if (self.framed[j] || (self.particle[j] && self.turn_goal(j))) pose.rotations[j] = self.local[j];
		if (self.skeleton.parents[j] < 0 && self.particle[j]) pose.offsets[j] = self.x[j] - self.skeleton.joints[j];
	}

	return point_pose_measure(self.skeleton, pose, self.goals);
}

<*
 How far the placed pose is from what was asked: every grab's miss, and every
 pin's past what the closing polish takes up, counting as `POINT_POSE_HARD`
 grabs'.
*>
fn float PointSolve.error(&self)
{
	float sum = 0.0f;
	foreach (goal : self.goals)
	{
		if (!goal.position || goal.stood_down || goal.joint >= self.n || self.goal[goal.joint] < 0) continue;
		float miss = (self.x[goal.joint] - goal.target).length();
		// A pin's last hair is the polish's to close; past that it outweighs any grab.
		sum += goal.soft ? miss : math::max(miss - self.h * POINT_POSE_HOLD * 0.5f, 0.0f) * POINT_POSE_HARD;
	}
	return sum;
}

<*
 Every joint in play placed again from the rotations and the root alone.
*>
fn void PointSolve.walk(&self)
{
	for (usz j = 0; j < self.n; j++)
	{
		if (self.slot[j] < 0) continue;
		int parent = self.skeleton.parents[j];
		if (parent >= 0) self.x[j] = self.x[(usz)parent] + self.world[(usz)parent].rotate_vec3(self.rest[j]);
		self.world[j] = self.above(j).mul(self.local[j]).normalize();
	}
}

<*
 Each pin brought the last of the way onto its point by its own limb: a few
 passes of limited CCD over the joints between the pin and the fork its limb
 hangs from, nearest first. The relaxation leaves a pin a hair short where its
 limb is nearly straight — a knee whose hinge does not quite face the pin has no
 sideways bend to close it, and no roll worth asking for — and a pin is held
 exactly or not at all. A joint holding a world rotation is turned back to it
 after.
*>
fn void PointSolve.polish(&self)
{
	float close = self.h * 1.0e-5f;
	for (int round = 0; round < POINT_POSE_POLISH_ROUNDS; round++)
	{
		self.polish_limbs(close);
		if (!self.shift_root_to_pins(close)) break;
	}
	// A joint holding a world rotation turned back to it under the limb the polish
	// moved.
	for (usz j = 0; j < self.n; j++)
	{
		PointGoal* turned = self.particle[j] ? self.turn_goal(j) : null;
		if (!turned) continue;
		self.walk();
		self.local[j] = self.limited(j, self.above(j).invert().mul(turned.orient).normalize());
	}
	self.walk();
}

<*
 Each pin's own limb turned, by limited CCD, to put the pin on its point: the
 joints between it and the fork its limb hangs from, nearest first. Parents first,
 so a knee is placed before the ankle below it, and an ankle's limb stops at the
 knee rather than swinging it off its own pin.
*>
fn void PointSolve.polish_limbs(&self, float close)
{
	for (usz g = 0; g < self.n; g++)
	{
		PointGoal* goal = self.place_goal(g);
		if (!goal || goal.soft) continue;
		for (int pass = 0; pass < 8; pass++)
		{
			self.walk();
			if ((self.x[g] - goal.target).length() <= close) break;
			for (usz pivot = g;;)
			{
				int parent = self.skeleton.parents[pivot];
				if (parent < 0 || !self.framed[(usz)parent]) break;
				PointGoal* held = self.place_goal((usz)parent);
				if (held && !held.soft) break;
				pivot = (usz)parent;
				if (!self.frozen(pivot) && !self.turn_goal(pivot))
				{
					Quaternionf turn = bone_carry(self.x[g] - self.x[pivot], goal.target - self.x[pivot]);
					Quaternionf above = self.above(pivot);
					self.local[pivot] = self.limited(pivot, above.invert().mul(turn).mul(self.world[pivot]).normalize());
					self.walk();
				}
				// Up to and including the joint the fork carries: the fork itself
				// turns the other limbs too.
				int grand = self.skeleton.parents[pivot];
				if (grand < 0 || self.child_from[(usz)grand + 1] - self.child_from[(usz)grand] != 1) break;
			}
		}
	}
	self.walk();
}

<*
 Pins their limbs could not reach: the root slid by their average miss, so the
 next polish starts from a body they can reach. This is where a grab that asked
 too much finally gives way — in whichever direction the pins need, a pelvis
 pulled down past what flat feet allow going back as well as stopping.

 @return `True when the root moved.`
*>
fn bool PointSolve.shift_root_to_pins(&self, float close)
{
	Vec3 sum = {};
	usz missing = 0;
	usz root = self.n;
	for (usz g = 0; g < self.n; g++)
	{
		PointGoal* goal = self.place_goal(g);
		if (!goal || goal.soft) continue;
		Vec3 miss = goal.target - self.x[g];
		if (miss.length() <= close * 10.0f) continue;
		sum = sum + miss;
		missing++;
		root = g;
		while (self.skeleton.parents[root] >= 0) root = (usz)self.skeleton.parents[root];
	}
	if (missing == 0 || root >= self.n || !self.particle[root]) return false;
	PointGoal* held = self.place_goal(root);
	if (held && !held.soft) return false;
	self.x[root] = self.x[root] + sum / (float)missing;
	self.walk();
	return true;
}

<*
 One step of Müller's iteration for the rotation of a shape match: `r` turned by
 the torque the points exert on its rest shape, over how well they already line
 up with it.

 @return `False once the step is too small to matter.`
*>
fn bool point_turn_by(Quaternionf* r, Vec3 torque, float along)
{
	Vec3 omega = torque / (math::abs(along) + 1.0e-12f);
	float angle = omega.length();
	if (angle < 1.0e-7f) return false;
	*r = quaternion::from_axis_angle{float}(omega / angle, angle).mul(*r).normalize();
	return true;
}

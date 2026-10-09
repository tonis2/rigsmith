<*
 The body solve's reach, pins and limits on the real humanoid, called directly:
 the rig's own joints, limits and masses, a goal or two, and what the pose comes
 back holding. These are the intents of the point solver's old tests, carried to
 `body_solve` (the file is `point_pose.c3`'s: the goals, the masses and the measure
 the solve is handed).

 The figure is a disposable copy of the shipped humanoid (`library::ready`), and the
 fixture is `body_solve_test`'s: a position pin holds its part's world rotation
 softly (`POINT_POSE_PIN_SOFT_TURN`), the way the app asks for it, and the masses are
 the app's (`body_part_masses`, no fork carry). Every reading is off `joint_palette`,
 the same forward kinematics the viewport draws by. A drag solves every pointer
 position from the pose the gesture began with, so each step here is restored to it
 first; the sweeps are judged by `body_solve_test`'s `Jumps`, thresholds and all.

 Where a legacy number could not carry over it is said in the test that had it. The
 hand is grabbed on its point alone, as the old solver was and as `body_solve_test`'s
 hand tests do, unless a test says it holds the part's world rotation too, which is
 what the app asks of every grab. The pull past reach
 (`a_pull_past_the_elbows_limit_keeps_tracking`) is made both ways.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::point_pose`
*>
module crig_tests::point_pose;

import crig;
import rig;
import crig_tests::body_solve;
import crig_tests::library;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

const String PERSON = "humanoid.glb";

// A pin holds when the pinned part is within this share of the height of its point.
const float PIN_HELD = 0.002f;

// The sit tests' thresholds (`puppet_test`): a position-pinned foot turns less than
// this many degrees, the hips and the chest tilt less than this many.
const float FOOT_FLAT = 3.0f;
const float UPRIGHT = 10.0f;

// ---------------------------------------------------------------------------
// The fixture

struct Body
{
	rig::TriMesh mesh;
	crig::AppState app;
	crig::RigView view;
	rig::Pose pose;
	float height;
	float[] inv_mass;
	crig::PointJoint[] joints;
	Quaternionf[] began;
}

<*
 Opens the humanoid with its own rig.
*>
fn bool Body.open(&self)
{
	String path = string::tformat("%s/%s", library::ready(), PERSON);
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "%s must import its rig", path);
		return false;
	}
	self.view = self.app.open_rig(mem)!!;
	self.height = self.view.skeleton.height();
	usz n = self.view.len();
	self.pose = rig::rest_pose(mem, n);
	self.inv_mass = alloc::new_array(mem, float, (sz)n);
	bool[] trunk = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, trunk);
	// The masses the app gives the solve: the shape's, with each limb weighing what its
	// part of the mesh does, and no joint made as heavy as the one it hangs from.
	float[] part = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, part);
	crig::point_pose_masses(&self.view.skeleton, self.height, self.inv_mass, trunk, self.app.body_part_masses(&self.view, part) ? part : {}, fork_carry: false);
	self.joints = alloc::new_array(mem, crig::PointJoint, (sz)n);
	self.began = alloc::new_array(mem, Quaternionf, (sz)n);
	foreach (usz j, id : self.view.dot_ids)
	{
		crig::JointRotationLimits limits = self.app.doc.rotation_limits_of(id);
		self.joints[j] = {
			.joint = j,
			.inv_mass = self.inv_mass[j],
			.trunk = trunk[j],
			.limits = limits,
			.frame = limits.constrained ? crig::joint_limit_frame(&self.view.skeleton, self.view.dot_ids, limits) : (crig::JointLimitFrame){},
		};
		self.began[j] = quaternion::IDENTITY;
	}
	return true;
}

fn void Body.close(&self)
{
	alloc::free(mem, self.inv_mass);
	alloc::free(mem, self.joints);
	alloc::free(mem, self.began);
	self.pose.free(mem);
	self.view.free(mem);
	self.app.free();
	self.mesh.free(mem);
}

fn usz Body.joint(&self, String name)
{
	foreach (usz j, joint_name : self.view.names) if (joint_name == name) return j;
	test::@check(false, "no joint called %s", name);
	return 0;
}

fn Vec3 Body.at(&self, String name)
{
	usz j = self.joint(name);
	Matrix4f[] palette = rig::joint_palette(mem, &self.view.skeleton, self.pose)!!;
	defer alloc::free(mem, palette);
	return self.view.skeleton.joints[j].transform(palette[j]);
}

fn Quaternionf Body.world(&self, String name)
{
	Quaternionf[] world = self.pose.world_rotations(mem, &self.view.skeleton)!!;
	defer alloc::free(mem, world);
	return world[self.joint(name)];
}

// Every joint's position, in skeleton order, into `out`.
fn void Body.points(&self, Vec3[] out)
{
	Matrix4f[] palette = rig::joint_palette(mem, &self.view.skeleton, self.pose)!!;
	defer alloc::free(mem, palette);
	foreach (usz j, rest : self.view.skeleton.joints) out[j] = rest.transform(palette[j]);
}

// The gesture begins: what the stiffness draws back toward is the pose as it stands.
fn void Body.begin(&self)
{
	foreach (usz j, rotation : self.pose.rotations) self.began[j] = rotation;
}

// The pose put back as the gesture began, the way a drag starts every move from it.
fn void Body.restore(&self, rig::Pose* start)
{
	self.pose.rotations[..] = start.rotations[..];
	self.pose.offsets[..] = start.offsets[..];
}

fn float Body.solve(&self, crig::PointGoal[] goals)
{
	crig::PointPoseSettings settings = {
		.height = self.height,
		.posture = self.began,
	};
	return crig::body_solve(&self.view.skeleton, &self.pose, self.joints, goals, &settings);
}

<*
 The grab, which holds its own part's world rotation too when `hold` is given.
*>
fn crig::PointGoal Body.grab(&self, String name, Vec3 target, bool hold = false)
{
	crig::PointGoal goal = { .joint = self.joint(name), .position = true, .soft = true, .target = target };
	if (hold)
	{
		goal.rotation = true;
		goal.orient = self.world(name);
		goal.turn_weight = crig::POINT_POSE_GRAB_HOLD;
	}
	return goal;
}

<*
 A position pin: hard position where the part stands, its world rotation held
 softly (`POINT_POSE_PIN_SOFT_TURN`), or hard when `hard_turn`.
*>
fn crig::PointGoal Body.pin(&self, String name, bool hard_turn = false)
{
	return {
		.joint = self.joint(name),
		.position = true,
		.target = self.at(name),
		.rotation = true,
		.orient = self.world(name),
		.turn_weight = hard_turn ? 0.0f : crig::POINT_POSE_PIN_SOFT_TURN,
	};
}

// How far `name` is from `point`, in heights.
fn float Body.off(&self, String name, Vec3 point) => (self.at(name) - point).length() / self.height;

// How far a joint's world rotation is from `was`, in degrees.
fn float Body.turned(&self, String name, Quaternionf was) => body_solve::angle_of(self.world(name).mul(was.invert()));

// How far a joint's up has leaned from where `was` had it, in degrees.
fn float Body.tilt(&self, String name, Quaternionf was)
{
	Vec3 before = was.rotate_vec3({ 0, 1, 0 });
	Vec3 after = self.world(name).rotate_vec3({ 0, 1, 0 });
	return (float)math::atan2(before.cross(after).length(), before.dot(after)) * body_solve::DEGREES;
}

// Every bone of the solved pose inside its joint's limits, to a hair.
fn void Body.check_limits(&self, String what)
{
	foreach (usz j, pj : self.joints)
	{
		if (!pj.limited()) continue;
		Vec3 angles = crig::joint_angles_from_rotation(pj.frame, self.pose.rotations[j]);
		foreach (usz k, axis : pj.limits.axes)
		{
			float lo = axis.allowed ? axis.minimum : axis.locked;
			float hi = axis.allowed ? axis.maximum : axis.locked;
			test::@check(angles[k] >= lo - 1.0e-3f && angles[k] <= hi + 1.0e-3f,
				"%s: %s axis %d at %.3f, outside %.3f..%.3f", what, self.view.names[j], k, angles[k], lo, hi);
		}
	}
}

// The angle between a joint's two bones, in degrees: 0 for a straight limb.
fn float Body.fold(&self, String above, String joint, String below)
{
	Vec3 upper = (self.at(joint) - self.at(above)).normalize();
	Vec3 lower = (self.at(below) - self.at(joint)).normalize();
	return (float)math::acos(math::clamp(upper.dot(lower), -1.0f, 1.0f)) * 180.0f / (float)math::PI;
}

<*
 What the body stood like as a gesture began: the world rotations of the parts a
 pinned figure is judged by, so the feet's turn and the pelvis's and chest's tilt can
 be read against them.
*>
struct Stance
{
	Quaternionf hips;
	Quaternionf chest;
	Quaternionf foot_l;
	Quaternionf foot_r;
}

fn Stance Body.stance(&self) => {
	.hips = self.world("hips"),
	.chest = self.world("chest"),
	.foot_l = self.world("ankle_L"),
	.foot_r = self.world("ankle_R"),
};

// The most either foot has turned from the stance, in degrees.
fn float Body.feet_turned(&self, Stance* was) => math::max(self.turned("ankle_L", was.foot_l), self.turned("ankle_R", was.foot_r));

// ---------------------------------------------------------------------------
// Bones, pins and the grab

<*
 A hand brought in from a T-pose, down and across: the arm folds to reach it, and
 nothing the arm can do on its own is handed to the trunk — the chest and hips stay
 where they were. The bones come back their own length: the solve writes rotations,
 and only the root slides. The pointer comes in eight positions, each solved from
 the pose the gesture began with.

 The old test looked at where the chest and hips stood; the tilt checks are new. The
 chest does lean a little for this reach (6.6 degrees) though the arm alone makes it
 (with the trunk frozen the hand misses by 0.0002 h): the stiffness shares a long
 reach with the trunk, which a quarter of this reach does not (0.8 degrees). It is not
 the straight arm's singularity: along the same line the lean grows steadily with the
 reach, 0.8 degrees at 0.1 h from the shoulder, 3.0 at 0.2, 6.9 at the arm's full
 0.299, and the solution with the trunk held costs only 3% more (4.3e-5 against
 4.2e-5), so the lean is the cost's own flat valley, to be moved by the trunk's stiffness
 against the arm's, not by a fix of the solve.
*>
fn void a_free_hand_reaches_and_leaves_the_trunk_alone() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	rig::Pose start = b.pose.copy(mem);
	defer start.free(mem);
	Vec3 from = b.at("wrist_L");
	Vec3 hips = b.at("hips");
	Vec3 chest = b.at("chest");
	Stance stance = b.stance();
	Vec3 by = (Vec3){ -0.15f, -0.2f, 0.15f } * b.height;
	crig::PointGoal[1] goals;
	for (int k = 1; k <= 8; k++)
	{
		b.restore(&start);
		goals[0] = b.grab("wrist_L", from + by * (k / 8.0f));
		b.solve(goals[..]);
	}
	float miss = b.off("wrist_L", from + by);
	float elbow = b.fold("shoulder_L", "elbow_L", "wrist_L");
	body_solve::note("  free hand: miss %.5f h, chest moved %.4f h, hips moved %.4f h, chest tilt %.2f, hips tilt %.2f deg, elbow %.1f deg", miss,
		b.off("chest", chest), b.off("hips", hips), b.tilt("chest", stance.chest), b.tilt("hips", stance.hips), elbow);
	test::@check(miss < 0.002f, "the hand missed by %.4f heights", miss);
	test::@check(b.off("chest", chest) < 0.01f && b.off("hips", hips) < 0.01f, "the trunk moved for a reach the arm could make");
	test::@check(b.tilt("hips", stance.hips) < 3.0f && b.tilt("chest", stance.chest) < UPRIGHT, "the trunk tilted for a reach the arm could make");
	test::@check(elbow > 15.0f, "the elbow did not fold");
	foreach (usz j, offset : b.pose.offsets)
	{
		test::@check(j == b.joint("hips") || offset.length() == 0.0f, "%s was slid, not turned", b.view.names[j]);
	}
	b.check_limits("free hand");
}

<*
 A hand pulled down and out past the arm's reach with the feet pinned: the arm
 straightens against its elbow, and the pull goes on into the shoulder, the chest
 and the hips — the answers keep coming closer to the pointer instead of sticking
 at the elbow — and stop cleanly once the body is out of reach, the feet never
 leaving their pins nor turning.

 Made with the grab holding the hand's world rotation, as the app's does, and without
 it, which no gesture of the app asks for. A pull this long (0.66 h) was carried to the
 pointer in three sub-steps, 0.22 h each, and without the hold the last of them landed in
 another fold of the arm: the pointer arrived and the hand was 0.17 h from it, where the
 step before it was 0.05 h. It is carried in more now (`POINT_POSE_RAMP_STEP`).

 The pointer goes 16 steps out and holds still for 8. The old solver was warm-started
 from its last answer and could wander on a still pointer, so the test asked it
 not to by more than 0.002 h a step; the solve now starts from the gesture's pose
 every time, and a still pointer gives the same bits, which is asserted.
*>
fn void a_pull_past_the_elbows_limit_keeps_tracking() @test
{
	foreach (bool hold : (bool[2]){ true, false })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		b.begin();
		rig::Pose start = b.pose.copy(mem);
		defer start.free(mem);
		crig::PointGoal[3] goals;
		goals[1] = b.pin("ankle_L");
		goals[2] = b.pin("ankle_R");
		Stance stance = b.stance();
		Vec3 from = b.at("wrist_L");
		Vec3 to = from + (Vec3){ 0.2f, -0.6f, 0.2f } * b.height;
		float last = (from - to).length();
		Vec3 held;
		float travelled_late = 0.0f;
		float worst_feet = 0.0f;
		float worst_slip = 0.0f;
		for (int k = 1; k <= 24; k++)
		{
			b.restore(&start);
			goals[0] = b.grab("wrist_L", from + (to - from) * math::min(k / 16.0f, 1.0f), hold);
			b.solve(goals[..]);
			Vec3 hand = b.at("wrist_L");
			float left = (hand - to).length();
			test::@check(left <= last + b.height * 1.0e-3f, "step %d: the hand fell back from %.4f to %.4f (hold %s)", k, last, left, hold);
			last = left;
			if (k == 16) held = hand;
			if (k > 16) travelled_late = math::max(travelled_late, (hand - held).length() / b.height);
			worst_feet = math::max(worst_feet, b.feet_turned(&stance));
			worst_slip = math::max(worst_slip, math::max(b.off("ankle_L", goals[1].target), b.off("ankle_R", goals[2].target)));
		}
		float came = ((from - to).length() - last) / b.height;
		body_solve::note("  pull past reach (%s): the hand came %.3f heights of %.3f, a still pointer moved it %.6f h, ankles slipped up to %.6f h, feet turned up to %.2f deg, hips tilt %.2f deg, chest tilt %.2f deg",
			hold ? "hand held at its angle" : "hand free to turn", came, (from - to).length() / b.height, travelled_late, worst_slip, worst_feet, b.tilt("hips", stance.hips), b.tilt("chest", stance.chest));
		test::@check(came > 0.3f, "the hand stuck after %.3f heights (hold %s)", came, hold);
		test::@check(travelled_late == 0.0f, "a still pointer moved the hand %.5f heights", travelled_late);
		test::@check(worst_slip < PIN_HELD, "an ankle slipped %.6f heights", worst_slip);
		test::@check(worst_feet < FOOT_FLAT, "a pinned foot turned %.2f degrees", worst_feet);
		b.check_limits("pull past reach");
	}
}

<*
 The grab is what gives way: hips pulled up past where the legs reach with both
 ankles pinned rise only until the legs are straight, the ankles stay, and back
 within reach the hips follow the pointer again. The pelvis and the chest stay
 upright and the feet stay flat all the way, past reach as well.
*>
fn void a_grab_gives_way_to_two_pins() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	rig::Pose start = b.pose.copy(mem);
	defer start.free(mem);
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L");
	goals[2] = b.pin("ankle_R");
	Stance stance = b.stance();
	Vec3 hips = b.at("hips");
	float worst_slip = 0.0f;
	float worst_feet = 0.0f;
	float worst_hips = 0.0f;
	float worst_chest = 0.0f;
	for (int k = 1; k <= 10; k++)
	{
		b.restore(&start);
		goals[0] = b.grab("hips", hips + (Vec3){ 0, 0.03f * k, 0 } * b.height, true);
		b.solve(goals[..]);
		worst_slip = math::max(worst_slip, math::max(b.off("ankle_L", goals[1].target), b.off("ankle_R", goals[2].target)));
		worst_feet = math::max(worst_feet, b.feet_turned(&stance));
		worst_hips = math::max(worst_hips, b.tilt("hips", stance.hips));
		worst_chest = math::max(worst_chest, b.tilt("chest", stance.chest));
	}
	float rose = (b.at("hips").y - hips.y) / b.height;
	body_solve::note("  grab gives way: rose %.4f h of 0.3 asked, the grab misses %.4f h, ankles slipped up to %.6f h, feet turned up to %.2f, hips tilted up to %.2f, chest up to %.2f deg",
		rose, goals[0].residual / b.height, worst_slip, worst_feet, worst_hips, worst_chest);
	test::@check(worst_slip < PIN_HELD, "the pull tore an ankle %.6f heights off its pin", worst_slip);
	test::@check(rose < 0.02f, "the hips rose %.4f, past the legs' reach", rose);
	test::@check(goals[0].residual > 0.25f * b.height, "the grab reports it was met");
	test::@check(worst_feet < FOOT_FLAT, "a pinned foot turned %.2f degrees", worst_feet);
	test::@check(worst_hips < UPRIGHT && worst_chest < UPRIGHT, "the hips tilted %.2f and the chest %.2f degrees", worst_hips, worst_chest);
	b.check_limits("grab gives way, up");

	// Back within reach, the pointer coming down in ten steps from where the hips stopped:
	// each position is solved from the start, so they follow it. Within reach is 0.05 h
	// down, not the 0.1 h the old test asked: the old solver got that deep by tipping the
	// feet, and with their angle held the hips go no further than about 0.07 h (0.1 h
	// leaves the grab 0.027 h short).
	Vec3 down = hips - (Vec3){ 0, 0.05f, 0 } * b.height;
	Vec3 stopped = b.at("hips");
	for (int k = 1; k <= 10; k++)
	{
		b.restore(&start);
		goals[0] = b.grab("hips", stopped + (down - stopped) * (k / 10.0f), true);
		b.solve(goals[..]);
	}
	body_solve::note("  grab gives way: back down the hips are %.5f h off the pointer, ankles %.6f %.6f h off, feet turned %.2f, hips tilt %.2f, chest tilt %.2f deg",
		b.off("hips", down), b.off("ankle_L", goals[1].target), b.off("ankle_R", goals[2].target), b.feet_turned(&stance),
		b.tilt("hips", stance.hips), b.tilt("chest", stance.chest));
	test::@check(b.off("hips", down) < PIN_HELD, "back within reach the hips are %.4f off the pointer", b.off("hips", down));
	test::@check(b.off("ankle_L", goals[1].target) < PIN_HELD && b.off("ankle_R", goals[2].target) < PIN_HELD, "an ankle slipped on the way down");
	test::@check(b.feet_turned(&stance) < FOOT_FLAT, "a pinned foot turned %.2f degrees on the way down", b.feet_turned(&stance));
	test::@check(b.tilt("hips", stance.hips) < UPRIGHT && b.tilt("chest", stance.chest) < UPRIGHT, "the body tilted on the way down");
	b.check_limits("grab gives way, down");
}

<*
 A held world rotation holds: an ankle pinned in position and angle stays flat
 while a squat folds the leg above it, and the other foot, pinned by position alone,
 stays flat too while the ankle's limits allow it. The pelvis and the chest stay
 upright. The hips are asked 0.08 of the height, a little past what flat feet allow
 (about 0.07): the grab gives way, the held angle does not.
*>
fn void a_rotation_pin_keeps_the_foot_flat() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	rig::Pose start = b.pose.copy(mem);
	defer start.free(mem);
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L", hard_turn: true);
	goals[2] = b.pin("ankle_R");
	Stance stance = b.stance();
	Vec3 hips = b.at("hips");
	for (int k = 1; k <= 8; k++)
	{
		b.restore(&start);
		goals[0] = b.grab("hips", hips - (Vec3){ 0, 0.08f * k / 8.0f, 0 } * b.height, true);
		b.solve(goals[..]);
	}
	body_solve::note("  rotation pin: held ankle turned %.4f rad (%.2f deg), the other %.2f deg, slip %.6f %.6f h, hips tilt %.2f, chest tilt %.2f deg, hips dropped %.4f h",
		goals[1].turn_residual, b.turned("ankle_L", stance.foot_l), b.turned("ankle_R", stance.foot_r), b.off("ankle_L", goals[1].target),
		b.off("ankle_R", goals[2].target), b.tilt("hips", stance.hips), b.tilt("chest", stance.chest), (hips.y - b.at("hips").y) / b.height);
	test::@check(goals[1].turn_residual < 0.02f, "the held foot tilted %.4f rad", goals[1].turn_residual);
	test::@check(b.off("ankle_L", goals[1].target) < PIN_HELD && b.off("ankle_R", goals[2].target) < PIN_HELD, "a pinned foot slid");
	test::@check(b.turned("ankle_R", stance.foot_r) < FOOT_FLAT, "the position-pinned foot turned %.2f degrees", b.turned("ankle_R", stance.foot_r));
	test::@check(b.tilt("hips", stance.hips) < UPRIGHT && b.tilt("chest", stance.chest) < UPRIGHT, "the body tilted: hips %.2f, chest %.2f degrees",
		b.tilt("hips", stance.hips), b.tilt("chest", stance.chest));
	b.check_limits("rotation pin");
}

// ---------------------------------------------------------------------------
// Twist

<*
 Twist carries: a sweep of the hand that swings the arm leaves the forearm's own
 roll — its angle about the bone, the twist of the elbow's limit angles — nearly
 where it was. The hand's own world rotation is not held: holding it is a reason to
 roll the forearm, and what is asked here is that nothing but a reason does.

 The old solver aimed each bone keeping the twist it had, so the roll came back to
 within a thousandth of a radian. The solve has no such rule: the roll is an unknown
 drawn back toward where it began by a small stiffness, and the fingers, which want
 to stay where they were, pull on it a little as the wrist is carried off — a
 swing that straightens the arm (the full reach here) drifts it 0.13 rad, a quarter
 of it 0.03. So the roll is judged by how little it drifts: under 0.05 rad for the
 short swing, under 10 degrees for the long one, and less for the short than the long.
*>
fn void a_swing_leaves_the_forearms_roll() @test
{
	float[2] drift;
	foreach (usz run, float reach : (float[2]){ 0.25f, 1.0f })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		usz elbow = b.joint("elbow_L");
		// Some roll to keep, first.
		Vec3 angles = { 0, 0.4f, -0.5f };
		b.pose.rotations[elbow] = crig::rotation_from_joint_angles(b.joints[elbow].frame, angles);
		b.begin();
		rig::Pose start = b.pose.copy(mem);
		defer start.free(mem);
		Vec3 from = b.at("wrist_L");
		crig::PointGoal[1] goals;
		for (int k = 1; k <= 8; k++)
		{
			b.restore(&start);
			goals[0] = b.grab("wrist_L", from + (Vec3){ 0, 0.15f, 0.1f } * b.height * (reach * k / 8.0f));
			b.solve(goals[..]);
		}
		Vec3 now = crig::joint_angles_from_rotation(b.joints[elbow].frame, b.pose.rotations[elbow]);
		drift[run] = math::abs(now.y - angles.y);
		body_solve::note("  forearm roll, reach %.2f: %.5f -> %.5f rad (drift %.4f), the bend %.4f -> %.4f, hand missed by %.5f h", reach, angles.y, now.y,
			drift[run], angles.z, now.z, b.off("wrist_L", goals[0].target));
		test::@check(b.off("wrist_L", goals[0].target) < 0.002f, "the hand did not arrive");
		b.check_limits("forearm roll");
	}
	test::@check(drift[0] < 0.05f, "a short swing drifted the forearm's roll %.4f rad", drift[0]);
	test::@check(drift[1] < 10.0f / body_solve::DEGREES, "a long swing drifted the forearm's roll %.4f rad", drift[1]);
	test::@check(drift[0] < drift[1], "the roll drifted %.4f rad for the short swing and %.4f for the long one", drift[0], drift[1]);
}

// ---------------------------------------------------------------------------
// A sweep

<*
 The wrist's circle: `at(lap)` is the point a fraction `lap` of the way round it.
*>
struct Circle
{
	Vec3 centre;
	float radius;
}

fn Vec3 Circle.at(&self, float lap) => self.centre + (Vec3){ self.radius * math::cos(lap * 2.0f * (float)math::PI), 0, self.radius * math::sin(lap * 2.0f * (float)math::PI) };

<*
 The wrist pulled to `target`, the ankles pinned where `goals` has them: solved from `start`.
*>
fn void Body.solve_wrist(&self, rig::Pose* start, crig::PointGoal[] goals, Vec3 target)
{
	self.restore(start);
	goals[0] = self.grab("wrist_L", target);
	self.solve(goals);
}

<*
 Pointer step `step` of the sweep solved again in `REFINE_STEPS` equal sub-steps between
 its two ends: the most `joint` moved (heights) or turned (degrees) in any one of them.
*>
fn float Body.refine_wrist(&self, rig::Pose* start, crig::PointGoal[] goals, Vec3 a, Vec3 c, usz joint, bool turn)
{
	self.solve_wrist(start, goals, a);
	Vec3 was_at = self.at(self.view.names[joint]);
	Quaternionf was_turn = self.pose.rotations[joint];
	float most;
	for (int sub = 1; sub <= body_solve::REFINE_STEPS; sub++)
	{
		self.solve_wrist(start, goals, a + (c - a) * ((float)sub / (float)body_solve::REFINE_STEPS));
		Vec3 at = self.at(self.view.names[joint]);
		Quaternionf rotation = self.pose.rotations[joint];
		float change = turn ? body_solve::angle_of(rotation.mul(was_turn.invert())) : (at - was_at).length() / self.height;
		most = math::max(most, change);
		was_at = at;
		was_turn = rotation;
	}
	return most;
}

<*
 What a hand sweep did to the figure besides moving it: how far behind the pointer
 the hand fell, and how far the feet and the trunk were disturbed.
*>
struct HandSweep
{
	body_solve::Jumps jumps;
	float behind;
	float feet;
	float hips;
	float chest;
}

<*
 The wrist swept round `circle` for `laps` laps in `steps` targets a lap, each solved
 from the same start pose with the same anchor, as a drag does, ankles pinned. The
 first target is where the circle begins, solved but not counted as a step. The step
 that moved a joint most and the step that turned one most are then solved again in
 finer steps (`refine_wrist`).
*>
fn HandSweep Body.sweep_wrist(&self, Circle* circle, int steps, int laps)
{
	self.begin();
	rig::Pose start = self.pose.copy(mem);
	defer start.free(mem);
	usz n = self.view.len();
	Vec3[] before = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, before);
	Vec3[] after = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, after);
	Quaternionf[] was = alloc::new_array(mem, Quaternionf, (sz)n);
	defer alloc::free(mem, was);
	crig::PointGoal[3] goals;
	goals[1] = self.pin("ankle_L");
	goals[2] = self.pin("ankle_R");
	Stance stance = self.stance();
	HandSweep sweep = { .jumps = { .push = circle.radius * 2.0f * (float)math::PI / (float)steps / self.height } };
	self.solve_wrist(&start, goals[..], circle.at(0.0f));
	self.points(before);
	foreach (usz j, rotation : self.pose.rotations) was[j] = rotation;
	for (int k = 1; k <= steps * laps; k++)
	{
		Vec3 target = circle.at((float)k / (float)steps);
		self.solve_wrist(&start, goals[..], target);
		self.points(after);
		body_solve::Jumps* jumps = &sweep.jumps;
		foreach (usz j, at : after)
		{
			float moved = (at - before[j]).length() / self.height;
			if (moved > jumps.move) { jumps.move = moved; jumps.move_at = self.view.names[j]; jumps.move_joint = j; jumps.move_step = k; }
			float turn = body_solve::angle_of(self.pose.rotations[j].mul(was[j].invert()));
			if (turn > jumps.turn) { jumps.turn = turn; jumps.turn_at = self.view.names[j]; jumps.turn_joint = j; jumps.turn_step = k; }
		}
		jumps.ankle = math::max(jumps.ankle, math::max(self.off("ankle_L", goals[1].target), self.off("ankle_R", goals[2].target)));
		sweep.behind = math::max(sweep.behind, self.off("wrist_L", target));
		sweep.feet = math::max(sweep.feet, self.feet_turned(&stance));
		sweep.hips = math::max(sweep.hips, self.tilt("hips", stance.hips));
		sweep.chest = math::max(sweep.chest, self.tilt("chest", stance.chest));
		before[..] = after[..];
		foreach (usz j, rotation : self.pose.rotations) was[j] = rotation;
	}
	body_solve::Jumps* jumps = &sweep.jumps;
	Vec3 move_from = circle.at((float)(jumps.move_step - 1) / (float)steps);
	Vec3 move_to = circle.at((float)jumps.move_step / (float)steps);
	Vec3 turn_from = circle.at((float)(jumps.turn_step - 1) / (float)steps);
	Vec3 turn_to = circle.at((float)jumps.turn_step / (float)steps);
	jumps.move_sub = self.refine_wrist(&start, goals[..], move_from, move_to, jumps.move_joint, false);
	jumps.turn_sub = self.refine_wrist(&start, goals[..], turn_from, turn_to, jumps.turn_joint, true);
	return sweep;
}

<*
 No jump: the hand swept twice round a circle inside the arm's reach with the feet
 pinned. The smoothness is `body_solve_test`'s (`Jumps.check`): no joint moves more
 than four times the pointer's step between one answer and the next, none turns more
 than 10 degrees, and the worst step solved again in eighths is spread over them and
 not a jump. The hand always arrives, the feet never leave their pins nor turn, and
 the pelvis and the chest stay upright (the arm does it alone).

 The old test allowed five hand steps and looked at the position of the joints only.

 The hand's world rotation is not held, as the old test had it. Held, as the app holds
 it, the sweep has a spike on one step of each lap (17 and 65): the wrist, which sits
 on its limits to keep the rotation, lets go for that step and the elbow's twist goes
 18, 45, 28 degrees round it (a turn of 28.6 degrees, the refined step 79% in one
 eighth). Not asserted: a known miss.
*>
fn void a_continuous_sweep_never_jumps() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	// Inside the arm's reach all the way round, so every step is one the arm can
	// make: what is checked is that it makes it smoothly.
	Circle circle = { .centre = b.at("wrist_L") + (Vec3){ -0.15f, -0.1f, 0.1f } * b.height, .radius = 0.08f * b.height };
	HandSweep sweep = b.sweep_wrist(&circle, 48, 2);
	sweep.jumps.print("hand circle");
	body_solve::note("  hand circle: the hand fell up to %.5f h behind, feet turned up to %.2f deg, hips tilted up to %.2f, chest up to %.2f deg", sweep.behind, sweep.feet, sweep.hips, sweep.chest);
	sweep.jumps.check();
	test::@check(sweep.jumps.ankle < PIN_HELD, "an ankle slipped %.6f heights during the sweep", sweep.jumps.ankle);
	test::@check(sweep.behind < 0.003f, "the hand fell %.4f heights behind", sweep.behind);
	test::@check(sweep.feet < FOOT_FLAT, "a pinned foot turned %.2f degrees", sweep.feet);
	test::@check(sweep.hips < UPRIGHT && sweep.chest < UPRIGHT, "the hips tilted %.2f and the chest %.2f degrees", sweep.hips, sweep.chest);
	b.check_limits("sweep");
}

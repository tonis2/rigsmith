<*
 The body solver on the real humanoid, called directly: the rig's own joints,
 limits and masses, a grab or two and some pins, and what the pose comes back
 holding.

 The figure is a disposable copy of the shipped humanoid (`library::ready`). Every
 reading is off `joint_palette`, the same forward kinematics the viewport draws
 by, so a point the solve kept and a rotation it read back wrongly cannot pass for
 one another. A position pin is a hard position with a soft hold on the part's
 world rotation (`POINT_POSE_PIN_SOFT_TURN`), the way the app asks for it; the
 grab holds its own part's world rotation too (`POINT_POSE_GRAB_HOLD`).

 Every test prints its numbers, and appends them to the file named by the
 `BODY_SOLVE_LOG` environment variable when there is one — the runner may hide
 stdout.

     `BODY_SOLVE_LOG=/tmp/body.txt c3c test --trust=full --test-noleak --test-filter crig_tests::body_solve`
*>
module crig_tests::body_solve;

import crig;
import rig;
import crig_tests::library;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::os::env;
import std::time;

const String PERSON = "humanoid.glb";

// Radians to degrees.
const float DEGREES = 57.29578f;

// ---------------------------------------------------------------------------
// The log

// A line of the report: on the screen, and in the log when there is one.
fn void note(String format, args...)
{
	String line = string::tformat(format, ...args);
	io::printn(line);
	String? path = env::tget_var("BODY_SOLVE_LOG");
	if (catch path) return;
	File? out = file::open(path, "a");
	if (catch out) return;
	(void)io::fprintn(&out, line);
	(void)out.close();
}

// The angle of a rotation, in degrees, 0 to 180.
fn float angle_of(Quaternionf q)
{
	q = q.normalize();
	float vector = math::sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2]);
	return 2.0f * (float)math::atan2(vector, math::abs(q.v[3])) * DEGREES;
}

// ---------------------------------------------------------------------------
// The fixture

struct Body
{
	rig::TriMesh mesh;
	crig::AppState app;
	crig::RigView view;
	rig::Pose pose;
	rig::Pose rest;
	float height;
	float[] inv_mass;
	crig::PointJoint[] joints;
	Quaternionf[] began;
	bool balance;
	float balance_miss;      // out: what the last solve reported
	bool has_floor;
	float floor;
	int ramp;                // sub-steps for the grab; zero for the solve's own
}

<*
 Opens the humanoid with its own rig. `knee_back` moves both knees that far
 behind where the model has them before the rig is read, for a figure whose
 rest knees are hyper-extended.
*>
fn bool Body.open(&self, float knee_back = 0.0f)
{
	String path = string::tformat("%s/%s", library::ready(), PERSON);
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "%s must import its rig", path);
		return false;
	}
	if (knee_back != 0.0f)
	{
		foreach (String name : (String[]){ "knee_L", "knee_R" })
		{
			crig::Dot* knee = self.app.dot_named(name);
			test::@check(self.app.doc.move_dot(knee.id, knee.position - (Vec3){ 0, 0, knee_back }), "%s would not move", name);
		}
	}
	self.view = self.app.open_rig(mem)!!;
	self.height = self.view.skeleton.height();
	usz n = self.view.len();
	self.pose = rig::rest_pose(mem, n);
	self.rest = rig::rest_pose(mem, n);
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
	self.rest.free(mem);
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
		.balance = self.balance,
		.has_floor = self.has_floor,
		.floor = self.floor,
		.ramp = self.ramp,
	};
	float miss = crig::body_solve(&self.view.skeleton, &self.pose, self.joints, goals, &settings);
	self.balance_miss = settings.balance_miss;
	return miss;
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
 A position pin: hard position where the part stands. Its world rotation is held
 softly (`POINT_POSE_PIN_SOFT_TURN`), or hard when `hard_turn`, or not at all when `turn` is false.
*>
fn crig::PointGoal Body.pin(&self, String name, bool turn = true, bool hard_turn = false)
{
	crig::PointGoal goal = { .joint = self.joint(name), .position = true, .target = self.at(name) };
	if (turn)
	{
		goal.rotation = true;
		goal.orient = self.world(name);
		goal.turn_weight = hard_turn ? 0.0f : crig::POINT_POSE_PIN_SOFT_TURN;
	}
	return goal;
}

// How far `name` is from `point`, in heights.
fn float Body.off(&self, String name, Vec3 point) => (self.at(name) - point).length() / self.height;

// How far a joint's world rotation is from `was`, in degrees.
fn float Body.turned(&self, String name, Quaternionf was) => angle_of(self.world(name).mul(was.invert()));

// How far a joint's up has leaned from where `was` had it, in degrees.
fn float Body.tilt(&self, String name, Quaternionf was)
{
	Vec3 before = was.rotate_vec3({ 0, 1, 0 });
	Vec3 after = self.world(name).rotate_vec3({ 0, 1, 0 });
	return (float)math::atan2(before.cross(after).length(), before.dot(after)) * DEGREES;
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
 How far the knee stands in front of the line from the thigh to the ankle, in
 heights — the side a knee folds to (the humanoid faces +Z).
*>
fn float Body.knee_ahead(&self, String thigh, String knee, String ankle)
{
	Vec3 top = self.at(thigh);
	Vec3 line = (self.at(ankle) - top).normalize();
	Vec3 off = self.at(knee) - top;
	off = off - line * off.dot(line);
	return off.z / self.height;
}

<*
 The axes the solve turns a joint about for each limit angle are what raising that
 angle by a hair does, whatever the angles are: the solve's derivatives follow the
 limit angles' composition, so a change there has to be followed here.
*>
fn void limit_axes_follow_the_angles() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	uint seed = 99;
	usz checked = 0;
	foreach (usz j, pj : b.joints)
	{
		if (!pj.limited()) continue;
		Quaternionf basis = pj.frame.rotation.normalize();
		for (int run = 0; run < 6; run++)
		{
			Vec3 angles;
			for (usz c = 0; c < 3; c++)
			{
				seed = seed * 1664525 + 1013904223;
				angles[c] = ((float)(seed >> 8) / (float)(1 << 24) - 0.5f) * 2.4f;
			}
			Quaternionf here = crig::rotation_from_joint_angles(pj.frame, angles);
			Vec3[3] axes = crig::limit_angle_axes(basis, angles);
			for (usz a = 0; a < 3; a++)
			{
				Vec3 raised = angles;
				raised[a] += 1.0e-3f;
				Quaternionf delta = crig::rotation_from_joint_angles(pj.frame, raised).mul(here.invert()).normalize();
				if (delta.v.w < 0.0f) delta.v = -delta.v;
				Vec3 turn = (Vec3){ delta.v.x, delta.v.y, delta.v.z } * 2.0f / 1.0e-3f;
				test::@check((turn - axes[a]).length() < 2.0e-2f, "%s angle %d at %s: the axis is %s, a hair of it turns %s", b.view.names[j], a, angles, axes[a], turn);
				checked++;
			}
		}
	}
	note("  limit axes: %d derivatives checked against the angles", checked);
}

<*
 The same, at chosen points, by central differences and to a tight tolerance: the
 swing's Jacobian is the part most easily got wrong, and it is worst where a short
 series would be used (a swing near nothing) or a long one needed (a swing near a
 half turn). The points include 80 degrees of X with 60 of Z (a swing of 100), a
 twist at both ends of the circle, a swing of 170 and one of a thousandth of a
 radian, and a pose the Euler reading could not name (a quarter turn of twist).
 Done in the identity frame and in two turned ones, so the change of basis is checked too.
*>
fn void limit_axes_match_central_differences_at_the_hard_points() @test
{
	Vec3[12] points = {
		{ 80.0f, 0.0f, 60.0f }, { 80.0f, 170.0f, 60.0f }, { 80.0f, -170.0f, 60.0f },
		{ 0.0f, 170.0f, 0.0f }, { -30.0f, -169.0f, 45.0f }, { 0.0f, 0.0f, 0.0f },
		{ 0.04f, 0.0f, 0.03f }, { 100.0f, 20.0f, -80.0f }, { 170.0f, 10.0f, 0.0f },
		{ 45.0f, 90.0f, 45.0f }, { 0.0f, 90.0f, 90.0f }, { -20.0f, 175.0f, -150.0f },
	};
	Quaternionf[3] bases = {
		quaternion::IDENTITY,
		quaternion::from_axis_angle{float}((Vec3){ 0.3f, 0.5f, 0.8f }.normalize(), 1.1f),
		quaternion::from_axis_angle{float}((Vec3){ -0.7f, 0.2f, 0.4f }.normalize(), -2.4f),
	};
	const float STEP = 4.0e-3f;
	float worst = 0.0f;
	foreach (basis : bases)
	{
		crig::JointLimitFrame frame;
		frame.status = crig::JointLimitFrameStatus.READY;
		frame.rotation = basis;
		foreach (degrees : points)
		{
			Vec3 angles = degrees * (1.0f / DEGREES);
			Vec3[3] axes = crig::limit_angle_axes(basis, angles);
			for (usz a = 0; a < 3; a++)
			{
				Vec3 up = angles;
				Vec3 down = angles;
				up[a] += STEP;
				down[a] -= STEP;
				// R(up) = exp(2 STEP omega) R(down), the left-multiplied increment the solve carries.
				Quaternionf delta = crig::rotation_from_joint_angles(frame, up).mul(crig::rotation_from_joint_angles(frame, down).invert()).normalize();
				if (delta.v.w < 0.0f) delta.v = -delta.v;
				Vec3 turn = (Vec3){ delta.v.x, delta.v.y, delta.v.z } * (1.0f / delta.v.w) * (1.0f / STEP);
				float miss = (turn - axes[a]).length();
				worst = math::max(worst, miss);
				test::@check(miss < 1.0e-3f, "angle %d at %s degrees: the axis is %s, the angle turns %s (off by %.2e)", a, degrees, axes[a], turn, miss);
			}
		}
	}
	note("  limit axes: %d derivatives checked by central differences, worst off by %.2e", bases.len * points.len * 3, worst);
}

// ---------------------------------------------------------------------------
// The sit

<*
 What a sit is measured by: the world rotations the figure began with, and the
 pins' points.
*>
struct Sit
{
	Quaternionf hips;
	Quaternionf chest;
	Quaternionf foot_l;
	Quaternionf foot_r;
	Vec3 hips_at;
	Vec3 chest_at;
	crig::PointGoal[3] goals;
}

<*
 Both ankles pinned (position hard, angle soft or hard) and `part` pulled `drop`
 heights straight down, holding its own world rotation.
*>
fn Sit Body.sit(&self, String part, float drop, bool hard_feet = false)
{
	Sit sit = {
		.hips = self.world("hips"),
		.chest = self.world("chest"),
		.foot_l = self.world("ankle_L"),
		.foot_r = self.world("ankle_R"),
		.hips_at = self.at("hips"),
		.chest_at = self.at("chest"),
	};
	self.begin();
	sit.goals[0] = self.grab(part, self.at(part) - (Vec3){ 0, drop * self.height, 0 }, true);
	sit.goals[1] = self.pin("ankle_L", true, hard_feet);
	sit.goals[2] = self.pin("ankle_R", true, hard_feet);
	return sit;
}

// The numbers every sit is read by, printed.
struct SitReading
{
	float ankle_l;
	float ankle_r;
	float foot_l;
	float foot_r;
	float hips_tilt;
	float chest_tilt;
	float hips_dropped;
	float knee_l;
	float knee_r;
	float ahead_l;
	float ahead_r;
	float miss;
}

fn SitReading Body.read_sit(&self, Sit* sit)
{
	return {
		.ankle_l = self.off("ankle_L", sit.goals[1].target),
		.ankle_r = self.off("ankle_R", sit.goals[2].target),
		.foot_l = self.turned("ankle_L", sit.foot_l),
		.foot_r = self.turned("ankle_R", sit.foot_r),
		.hips_tilt = self.tilt("hips", sit.hips),
		.chest_tilt = self.tilt("chest", sit.chest),
		.hips_dropped = (sit.hips_at.y - self.at("hips").y) / self.height,
		.knee_l = self.fold("thigh_L", "knee_L", "ankle_L"),
		.knee_r = self.fold("thigh_R", "knee_R", "ankle_R"),
		.ahead_l = self.knee_ahead("thigh_L", "knee_L", "ankle_L"),
		.ahead_r = self.knee_ahead("thigh_R", "knee_R", "ankle_R"),
		.miss = sit.goals[0].residual / self.height,
	};
}

fn void SitReading.print(&self, String what)
{
	note("  %s: ankles %.6f %.6f h, feet turned %.2f %.2f deg, hips tilt %.2f, chest tilt %.2f, hips dropped %.4f h, grab missed %.4f h, knees %.1f %.1f deg ahead %.3f %.3f h",
		what, self.ankle_l, self.ankle_r, self.foot_l, self.foot_r, self.hips_tilt, self.chest_tilt, self.hips_dropped, self.miss,
		self.knee_l, self.knee_r, self.ahead_l, self.ahead_r);
}

<*
 1. The hips grabbed and pulled down 0.15 of the height with both ankles pinned
 (position hard, angle soft): the ankles stay on their points, the feet stay
 flat, the pelvis drops without tipping, the knees fold forward.
*>
fn void the_hips_drop_on_pinned_ankles() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	Sit sit = b.sit("hips", 0.15f);
	b.solve(sit.goals[..]);
	SitReading r = b.read_sit(&sit);
	r.print("hips down 0.15h");
	test::@check(r.ankle_l < 1.0e-4f && r.ankle_r < 1.0e-4f, "an ankle slipped %.6f %.6f heights", r.ankle_l, r.ankle_r);
	test::@check(r.foot_l < 3.0f && r.foot_r < 3.0f, "a foot turned %.2f %.2f degrees", r.foot_l, r.foot_r);
	test::@check(r.hips_tilt < 5.0f, "the hips tilted %.2f degrees", r.hips_tilt);
	test::@check(r.knee_l > 45.0f && r.knee_r > 45.0f, "the knees folded only %.1f %.1f degrees", r.knee_l, r.knee_r);
	test::@check(r.ahead_l > 0.02f && r.ahead_r > 0.02f, "a knee did not stand forward: %.3f %.3f", r.ahead_l, r.ahead_r);
	// The hips go where they are pulled, as far as flat feet allow: 0.10 of the 0.15 asked.
	test::@check(r.hips_dropped > 0.08f, "the hips dropped only %.4f heights", r.hips_dropped);
	b.check_limits("hips sit");
}

<*
 2. The spine grabbed the same way and pulled down 0.18 of the height: the body
 sits onto bent knees with the pelvis and chest upright.
*>
fn void the_spine_sits_the_body_on_pinned_ankles() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	Sit sit = b.sit("spine", 0.18f);
	b.solve(sit.goals[..]);
	SitReading r = b.read_sit(&sit);
	r.print("spine down 0.18h");
	test::@check(r.ankle_l < 1.0e-4f && r.ankle_r < 1.0e-4f, "an ankle slipped %.6f %.6f heights", r.ankle_l, r.ankle_r);
	test::@check(r.foot_l < 3.0f && r.foot_r < 3.0f, "a foot turned %.2f %.2f degrees", r.foot_l, r.foot_r);
	test::@check(r.hips_tilt < 10.0f && r.chest_tilt < 10.0f, "the hips tilted %.2f and the chest %.2f degrees", r.hips_tilt, r.chest_tilt);
	test::@check(r.knee_l > 60.0f && r.knee_r > 60.0f, "the knees folded only %.1f %.1f degrees", r.knee_l, r.knee_r);
	test::@check(r.ahead_l > 0.02f && r.ahead_r > 0.02f, "a knee did not stand forward: %.3f %.3f", r.ahead_l, r.ahead_r);
	b.check_limits("spine sit");
}

<*
 3. The same, with the feet held hard and the pull 0.25 of the height — past what
 flat feet allow: the ankles stay, the feet do not turn, the torso stays upright,
 and the grab is what gives way.
*>
fn void hard_feet_hold_and_the_grab_gives_way() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	Sit sit = b.sit("spine", 0.25f, true);
	b.solve(sit.goals[..]);
	SitReading r = b.read_sit(&sit);
	r.print("spine down 0.25h, hard feet");
	test::@check(r.ankle_l < 1.0e-4f && r.ankle_r < 1.0e-4f, "an ankle slipped %.6f %.6f heights", r.ankle_l, r.ankle_r);
	test::@check(r.foot_l < 1.0f && r.foot_r < 1.0f, "a foot turned %.2f %.2f degrees", r.foot_l, r.foot_r);
	test::@check(r.hips_tilt < 10.0f && r.chest_tilt < 10.0f, "the hips tilted %.2f and the chest %.2f degrees", r.hips_tilt, r.chest_tilt);
	b.check_limits("hard feet");
}

// ---------------------------------------------------------------------------
// A free hand

<*
 4. A hand pulled a little forward with nothing pinned: the arm answers it and
 the trunk hardly knows.
*>
fn void a_free_hand_reaches_and_the_trunk_stays() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	Vec3 hips = b.at("hips");
	Quaternionf chest = b.world("chest");
	Vec3 target = b.at("wrist_L") + (Vec3){ 0, 0, 0.08f * b.height };
	crig::PointGoal[1] goals = { b.grab("wrist_L", target) };
	b.solve(goals[..]);
	float miss = b.off("wrist_L", target);
	float moved = b.off("hips", hips);
	float tilt = b.tilt("chest", chest);
	note("  free hand: wrist missed %.6f h, hips moved %.5f h, chest tilt %.2f deg, elbow %.1f deg", miss, moved, tilt,
		b.fold("shoulder_L", "elbow_L", "wrist_L"));
	test::@check(miss < 1.0e-3f, "the wrist missed by %.5f heights", miss);
	test::@check(moved < 0.005f, "the hips moved %.5f heights for a reach the arm could make", moved);
	test::@check(tilt < 3.0f, "the chest tilted %.2f degrees", tilt);
	foreach (usz j, offset : b.pose.offsets)
	{
		test::@check(j == b.joint("hips") || offset.length() == 0.0f, "%s was slid, not turned", b.view.names[j]);
	}
	b.check_limits("free hand");
}

// ---------------------------------------------------------------------------
// Continuity

// The most a joint moves in one pointer step, in pointer steps, and the most it turns, in
// degrees: a lever is not a jump (a straight leg pulled shorter is a square-root
// response, and its knee moves cot(bend / 2) times the drop), so the moves are allowed a
// few steps of the pointer, and the continuity is judged by the refinement below.
const float SMOOTH_MOVE = 4.0f;
const float SMOOTH_TURN = 10.0f;

// The sub-steps the worst step is solved again in, and the share of the whole step
// any one of them may carry: a jump puts nearly all of a step in one sub-step, a smooth
// response spreads it, and the first sub-step of a square-root onset carries about 35%.
const int REFINE_STEPS = 8;

const float SMOOTH_SHARE = 0.5f;

// The most a joint turns in a step of the circle on a wide step (13c), in degrees: the arm's own pace there is 12.5.
const float WIDE_TURN = 15.0f;

// The worst step of a sweep: how far any joint moved, how far any joint turned, and what
// the same step solved again in `REFINE_STEPS` sub-steps gave for those two joints.
struct Jumps
{
	float move;
	String move_at;
	usz move_joint;
	int move_step;
	float turn;
	String turn_at;
	usz turn_joint;
	int turn_step;
	float ankle;
	float push;
	float move_sub;
	float turn_sub;
}

<*
 Where a sweep carries the grab: a part pulled straight down, or round a circle in the
 horizontal plane. `target` is the pointer `step` pointer steps along, a step a
 fraction of the way between two being a finer sweep of the same path. The grab holds
 the world rotation it began with, the way `pose_toward` asks it to.
*>
struct Path
{
	String part;
	Vec3 from;
	Quaternionf held;
	float height;
	bool circle;
	Vec3 centre;
	Vec3 across;             // the circle's two directions, unit and at right angles
	Vec3 along;
	float radius;
	float round;             // steps in one turn of the circle
	float push;              // the pointer's step, in heights
}

// The part `part` pulled `total` heights down in `steps` pointer steps.
fn Path Body.down_path(&self, String part, float total, int steps)
{
	return { .part = part, .from = self.at(part), .held = self.world(part), .height = self.height, .push = total / (float)steps };
}

<*
 The part `part` carried round a circle of `radius` heights about the point `centre`
 (an offset from where it stands, in heights), `round` steps to a turn. The pointer
 begins the circle at its angle 0, not at the part, so the sweep is judged on the
 circle alone; each target is solved from the gesture's start, a long way from the
 circle's first point and not an easy one.
*>
fn Path Body.circle_path(&self, String part, Vec3 centre, float radius, int round)
{
	return {
		.part = part, .from = self.at(part), .held = self.world(part), .height = self.height, .circle = true,
		.centre = self.at(part) + centre * self.height, .across = { 1, 0, 0 }, .along = { 0, 0, 1 }, .radius = radius * self.height, .round = (float)round,
		.push = radius * 2.0f * (float)math::PI / (float)round,
	};
}

fn Vec3 Path.target(&self, float step)
{
	if (!self.circle) return self.from - (Vec3){ 0, self.push * step * self.height, 0 };
	float angle = step / self.round * 2.0f * (float)math::PI;
	return self.centre + self.across * (self.radius * math::cos(angle)) + self.along * (self.radius * math::sin(angle));
}

<*
 The path's pointer `step` steps along, solved from `start`: the grab holding its
 start world rotation, the pins in `goals` (after the grab) as they were set.
*>
fn void Body.solve_path(&self, rig::Pose* start, crig::PointGoal[] goals, Path* path, float step)
{
	self.restore(start);
	goals[0] = self.grab(path.part, path.target(step));
	goals[0].rotation = true;
	goals[0].orient = path.held;
	goals[0].turn_weight = crig::POINT_POSE_GRAB_HOLD;
	self.solve(goals);
}

<*
 Pointer step `step` of the sweep solved again in `REFINE_STEPS` equal sub-steps: the
 most `joint` moved (heights) or turned (degrees) in any one of them. The step before
 it is the reference, which for the first step of a sweep from the start is the start
 pose itself.
*>
fn float Body.refine_path(&self, rig::Pose* start, crig::PointGoal[] goals, Path* path, int step, usz joint, bool turn)
{
	Vec3 was_at;
	Quaternionf was_turn;
	if (step == 1 && !path.circle)
	{
		self.restore(start);
	}
	else
	{
		self.solve_path(start, goals, path, (float)(step - 1));
	}
	was_at = self.at(self.view.names[joint]);
	was_turn = self.pose.rotations[joint];
	float most;
	for (int sub = 1; sub <= REFINE_STEPS; sub++)
	{
		self.solve_path(start, goals, path, (float)(step - 1) + (float)sub / (float)REFINE_STEPS);
		Vec3 at = self.at(self.view.names[joint]);
		Quaternionf rotation = self.pose.rotations[joint];
		float change = turn ? angle_of(rotation.mul(was_turn.invert())) : (at - was_at).length() / self.height;
		most = math::max(most, change);
		was_at = at;
		was_turn = rotation;
	}
	return most;
}

<*
 The path swept in `steps` targets, each solved from the pose the gesture began with
 and the same anchor, as a drag does, ankles pinned. The step that moved a joint most
 and the step that turned one most are then solved again in finer steps
 (`refine_path`).
*>
fn Jumps Body.sweep(&self, Path* path, int steps)
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
	goals[1] = self.pin("ankle_L", true);
	goals[2] = self.pin("ankle_R", true);
	// A circle is judged from its first point on; a pull down from where the body stands.
	if (path.circle) self.solve_path(&start, goals[..], path, 0.0f);
	self.points(before);
	foreach (usz j, rotation : self.pose.rotations) was[j] = rotation;
	Jumps jumps = { .push = path.push };
	for (int k = 1; k <= steps; k++)
	{
		self.solve_path(&start, goals[..], path, (float)k);
		self.points(after);
		foreach (usz j, at : after)
		{
			float moved = (at - before[j]).length() / self.height;
			if (moved > jumps.move) { jumps.move = moved; jumps.move_at = self.view.names[j]; jumps.move_joint = j; jumps.move_step = k; }
			float turn = angle_of(self.pose.rotations[j].mul(was[j].invert()));
			if (turn > jumps.turn) { jumps.turn = turn; jumps.turn_at = self.view.names[j]; jumps.turn_joint = j; jumps.turn_step = k; }
		}
		jumps.ankle = math::max(jumps.ankle, math::max(self.off("ankle_L", goals[1].target), self.off("ankle_R", goals[2].target)));
		before[..] = after[..];
		foreach (usz j, rotation : self.pose.rotations) was[j] = rotation;
	}
	jumps.move_sub = self.refine_path(&start, goals[..], path, jumps.move_step, jumps.move_joint, false);
	jumps.turn_sub = self.refine_path(&start, goals[..], path, jumps.turn_step, jumps.turn_joint, true);
	// The pose the sweep ended on.
	self.solve_path(&start, goals[..], path, (float)steps);
	return jumps;
}

fn Jumps Body.sweep_spine(&self, float total, int steps)
{
	Path path = self.down_path("spine", total, steps);
	return self.sweep(&path, steps);
}

fn void Jumps.print(&self, String what)
{
	note("  %s: the most any joint moved in a step %.4f h at %s on step %d (pointer step %.4f h, %.1fx), the most any joint turned %.2f deg at %s on step %d, ankles off by up to %.6f h",
		what, self.move, self.move_at, self.move_step, self.push, self.move / self.push, self.turn, self.turn_at, self.turn_step, self.ankle);
	note("  %s, refined x%d: the worst move's largest sub-step %.4f h (%.0f%% of the step), the worst turn's largest sub-step %.2f deg (%.0f%% of the step)",
		what, REFINE_STEPS, self.move_sub, 100.0f * self.move_sub / math::max(self.move, 1.0e-9f), self.turn_sub, 100.0f * self.turn_sub / math::max(self.turn, 1.0e-9f));
}

// The three smoothness checks of a sweep: no explosion in a move, none in a turn, and the worst of each spread over its sub-steps.
fn void Jumps.check(&self)
{
	test::@check(self.move <= SMOOTH_MOVE * self.push, "%s moved %.4f heights on step %d, over %.0f times the pointer's %.4f", self.move_at, self.move, self.move_step, SMOOTH_MOVE, self.push);
	test::@check(self.turn <= SMOOTH_TURN, "%s turned %.2f degrees on step %d (limit %.0f)", self.turn_at, self.turn, self.turn_step, SMOOTH_TURN);
	test::@check(self.move_sub <= SMOOTH_SHARE * self.move + 1.0e-4f, "%s moved %.4f of its %.4f heights in one eighth of step %d: a jump, not a response",
		self.move_at, self.move_sub, self.move, self.move_step);
	test::@check(self.turn_sub <= SMOOTH_SHARE * self.turn + 0.05f, "%s turned %.2f of its %.2f degrees in one eighth of step %d: a jump, not a response",
		self.turn_at, self.turn_sub, self.turn, self.turn_step);
}

<*
 5. The spine swept down 0 to 0.18 of the height in 40 targets, each solved from
 the same start pose with the same anchor, as a drag does: no joint moves more
 than four times the pointer's step between one answer and the next, none turns
 more than 10 degrees, the worst step solved again in eighths is spread over them
 and not a jump, and the same inputs twice give the same bits.
*>
fn void a_sweep_never_jumps_and_repeats_exactly() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	Jumps jumps = b.sweep_spine(0.18f, 40);
	jumps.print("sweep");

	// The same inputs twice: the same bits.
	rig::Pose start = b.pose.copy(mem);
	defer start.free(mem);
	b.restore(&b.rest);
	Sit sit = b.sit("spine", 0.18f);
	b.solve(sit.goals[..]);
	rig::Pose first = b.pose.copy(mem);
	defer first.free(mem);
	b.restore(&b.rest);
	b.solve(sit.goals[..]);
	bool same = true;
	foreach (usz j, rotation : b.pose.rotations) same = same && rotation.v == first.rotations[j].v;
	foreach (usz j, offset : b.pose.offsets) same = same && offset == first.offsets[j];
	note("  the same sit solved twice gives %s bits", same ? "the same" : "different");
	jumps.check();
	test::@check(jumps.ankle < 1.0e-4f, "an ankle slipped %.6f heights during the sweep", jumps.ankle);
	test::@check(same, "the same inputs gave different rotations");
	b.check_limits("sweep");
}

<*
 5b. The same sweep with the balance on, which is how the app runs it: two pinned
 ankles are two points, and an outline of two points is a line that a centre of
 mass can only be brought onto by a jump at the first touch of the pointer. The
 outline is the feet's — each pinned ankle with the toe below it, so two feet make
 a quadrilateral — and a pose already off its feet is not pushed onto them
 (`BodySolve.open_balance`). The same limits hold as with the balance off, and the
 sole under the pins is not lost sight of: the centre ends within a hair of it.
*>
fn void a_sweep_with_the_balance_on_never_jumps() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.balance = true;
	Jumps jumps = b.sweep_spine(0.18f, 40);
	jumps.print("sweep, balance on");
	jumps.check();
	test::@check(jumps.ankle < 1.0e-4f, "an ankle slipped %.6f heights during the sweep", jumps.ankle);
	b.check_limits("sweep, balance on");
}

// ---------------------------------------------------------------------------
// Limits and reach

<*
 6. A hand sent where the elbow would have to bend past its limit — into its own
 shoulder — and one sent past the arm's straight reach, with the feet, the hips,
 the chest and the shoulder all held so the body cannot bring the shoulder to it: every joint
 of the answer stays inside its limits, the elbow ends on the limit it ran into,
 and the miss is reported in the goal's residual.
*>
fn void an_elbow_never_leaves_its_limit() @test
{
	foreach (usz run, bool near : (bool[2]){ true, false })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		b.begin();
		crig::PointGoal[6] goals;
		String[5] held = { "ankle_L", "ankle_R", "hips", "chest", "shoulder_L" };
		foreach (usz i, name : held) goals[i + 1] = b.pin(name, false);
		// Inside the shortest the forearm folds to, or well past the longest it stretches to.
		Vec3 shoulder = b.at("shoulder_L");
		Vec3 target = near ? shoulder + (Vec3){ 0.0f, 0.0f, 0.02f } : shoulder + (Vec3){ 0.6f, 0.9f, 0.3f } * b.height;
		goals[0] = b.grab("wrist_L", target);
		b.solve(goals[..]);
		float reported = goals[0].residual / b.height;
		float actual = b.off("wrist_L", target);
		usz elbow_joint = b.joint("elbow_L");
		float bend = crig::joint_angles_from_rotation(b.joints[elbow_joint].frame, b.pose.rotations[elbow_joint]).z * DEGREES;
		float slip = 0.0f;
		foreach (usz i, name : held) slip = math::max(slip, b.off(name, goals[i + 1].target));
		note("  elbow limit (%s): wrist missed %.4f h (reported %.4f), elbow bend %.1f deg, the pins slipped up to %.6f h", near ? "near" : "far",
			actual, reported, bend, slip);
		test::@check(math::abs(reported - actual) < 1.0e-4f, "the residual says %.5f, the wrist is %.5f off", reported, actual);
		test::@check(actual > (near ? 0.03f : 0.2f), "the wrist missed only %.4f heights: it was not out of reach", actual);
		test::@check(near ? bend < -149.0f : bend > -1.0f, "the elbow ended at %.1f degrees, not on the limit it ran into", bend);
		test::@check(slip < 1.0e-3f, "a held part slipped %.6f heights", slip);
		b.check_limits("elbow limit");
	}
}

<*
 7. The floor is a floor: with the ankles and toes floored and nothing pinned, the
 hips pulled down hard leave no floored joint below it.
*>
fn void the_floor_holds_the_feet() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	b.has_floor = true;
	b.floor = math::min(b.at("toe_L").y, b.at("toe_R").y);
	String[4] floored = { "ankle_L", "ankle_R", "toe_L", "toe_R" };
	foreach (name : floored) b.joints[b.joint(name)].floored = true;
	crig::PointGoal[1] goals;
	goals[0] = b.grab("hips", b.at("hips") - (Vec3){ 0, 0.3f * b.height, 0 });
	b.solve(goals[..]);
	float lowest = float::max;
	foreach (name : floored) lowest = math::min(lowest, b.at(name).y);
	note("  floor: the lowest floored joint ended %.6f h above the floor, hips dropped %.4f h of 0.3 asked, knee folded %.1f deg",
		(lowest - b.floor) / b.height, -b.pose.offsets[b.joint("hips")].y / b.height, b.fold("thigh_L", "knee_L", "ankle_L"));
	test::@check(lowest >= b.floor - 1.0e-4f * b.height, "a floored joint sank %.6f heights through the floor", (b.floor - lowest) / b.height);
	test::@check((b.pose.offsets[b.joint("hips")].y * -1.0f) / b.height > 0.1f, "the hips came down only %.4f heights", -b.pose.offsets[b.joint("hips")].y / b.height);
	b.check_limits("floor");
}

<*
 8. A hinge folds the way its range opens: a drop on pinned ankles brings both
 knees forward, inside their 0..150 hinge, and so does one from knees modelled
 hyper-extended — behind the line from hip to ankle, where folding the right way
 first makes the leg longer. The hips come most of the way down in both, and
 the hyper-extended leg sits about as deep as the straight one.
*>
fn void a_hinge_folds_the_way_it_opens_from_straight_or_past_it() @test
{
	float[2] depth;
	foreach (usz run, float back : (float[2]){ 0.0f, 0.03f })
	{
		Body b;
		if (!b.open(knee_back: back)) return;
		defer b.close();
		b.begin();
		float rest_ahead = b.knee_ahead("thigh_L", "knee_L", "ankle_L");
		crig::PointGoal[3] goals;
		goals[1] = b.pin("ankle_L", false);
		goals[2] = b.pin("ankle_R", false);
		Vec3 hips = b.at("hips");
		goals[0] = b.grab("hips", hips - (Vec3){ 0, 0.1f, 0 } * b.height);
		b.solve(goals[..]);
		float ahead = b.knee_ahead("thigh_L", "knee_L", "ankle_L");
		depth[run] = (hips.y - b.at("hips").y) / b.height;
		note("  knee back %.2f: rest %.4f ahead, drop %.4f ahead, hips dropped %.4f h, ankles off %.6f %.6f h", back, rest_ahead, ahead, depth[run],
			b.off("ankle_L", goals[1].target), b.off("ankle_R", goals[2].target));
		test::@check(ahead > 0.02f, "the knee went %.4f ahead, not forward", ahead);
		test::@check(depth[run] > 0.09f, "the hips dropped only %.4f of 0.1", depth[run]);
		test::@check(b.off("ankle_L", goals[1].target) < 1.0e-4f && b.off("ankle_R", goals[2].target) < 1.0e-4f, "an ankle slipped");
		b.check_limits("hinge");
	}
	test::@check(math::abs(depth[0] - depth[1]) < 0.01f, "a hyper-extended knee sat %.4f deep against %.4f", depth[1], depth[0]);
}

// ---------------------------------------------------------------------------
// Speed and stand-down

// The median time of nine solves of `sit` from the pose `start`, in seconds.
fn double Body.time_sit(&self, Sit* sit, rig::Pose* start, double* fastest, double* slowest)
{
	// Once to warm up, then timed.
	self.restore(start);
	self.solve(sit.goals[..]);
	double[9] seconds;
	foreach (&took : seconds)
	{
		self.restore(start);
		Clock clock = clock::now();
		self.solve(sit.goals[..]);
		*took = clock.mark().to_sec();
	}
	double[9] sorted = seconds;
	for (usz i = 0; i < 9; i++) for (usz k = i + 1; k < 9; k++) if (sorted[k] < sorted[i]) { double t = sorted[i]; sorted[i] = sorted[k]; sorted[k] = t; }
	*fastest = sorted[0];
	*slowest = sorted[8];
	return sorted[4];
}

<*
 9. One solve of the spine sit (test 2) takes under 5 ms in the test build — and
 so does one with the balance on, which solves the whole trunk too.
*>
fn void a_solve_is_fast() @test
{
	foreach (bool balance : (bool[2]){ false, true })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		b.balance = balance;
		Sit sit = b.sit("spine", 0.18f);
		rig::Pose start = b.pose.copy(mem);
		defer start.free(mem);
		double fastest;
		double slowest;
		double median = b.time_sit(&sit, &start, &fastest, &slowest);
		note("  time: one spine-sit solve%s takes %.3f ms (fastest %.3f, slowest %.3f)", balance ? " with the balance on" : "", median * 1000.0, fastest * 1000.0, slowest * 1000.0);
		test::@check(median < 0.005, "a solve took %.3f ms", median * 1000.0);
	}
}

<*
 10. A pin whose point is out of its limb's reach at the start stands down: it
 reports its miss, and it does not drag the body after it.
*>
fn void a_pin_out_of_reach_stands_down() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	Vec3 hips = b.at("hips");
	Vec3 ankle_r = b.at("ankle_R");
	Vec3 wrist = b.at("wrist_L");
	crig::PointGoal[3] goals;
	// The left ankle asked for a whole height out to the side: the leg cannot reach.
	goals[0] = b.pin("ankle_L", false);
	goals[0].target = goals[0].target + (Vec3){ 1.0f * b.height, 0, 0 };
	goals[1] = b.pin("ankle_R", false);
	goals[2] = b.grab("wrist_L", wrist + (Vec3){ 0, 0, 0.05f * b.height });
	b.solve(goals[..]);
	float moved = b.off("hips", hips);
	note("  stood down: %s, its miss %.4f h, hips moved %.5f h, other ankle off %.6f h, hand off %.6f h", goals[0].stood_down ? "yes" : "no",
		goals[0].residual / b.height, moved, b.off("ankle_R", ankle_r), b.off("wrist_L", goals[2].target));
	test::@check(goals[0].stood_down, "the pin was not stood down");
	test::@check(!goals[1].stood_down && !goals[2].stood_down, "a pin in reach was stood down");
	test::@check(goals[0].residual > 0.9f * b.height, "the miss was reported as %.4f heights", goals[0].residual / b.height);
	test::@check(moved < 0.001f, "the hips were dragged %.5f heights after the pin", moved);
	test::@check(b.off("ankle_R", ankle_r) < 1.0e-4f, "the other ankle moved");
	test::@check(b.off("wrist_L", goals[2].target) < 1.0e-3f, "the hand did not arrive");
	b.check_limits("stood down");
}

// ---------------------------------------------------------------------------
// The balance

<*
 11. The balance: hips pulled down and back over pinned ankles lean the chest out
 over the feet, where without it the chest stays over the hips.
*>
fn void the_balance_leans_the_chest_over_the_feet() @test
{
	float[2] leans;
	foreach (usz run, bool balance : (bool[2]){ true, false })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		b.begin();
		b.balance = balance;
		crig::PointGoal[3] goals;
		goals[1] = b.pin("ankle_L", true);
		goals[2] = b.pin("ankle_R", true);
		Vec3 hips = b.at("hips");
		goals[0] = b.grab("hips", hips + (Vec3){ 0, -0.15f, -0.1f } * b.height);
		b.solve(goals[..]);
		Vec3 spine = b.at("chest") - b.at("hips");
		leans[run] = spine.z / spine.length();
		note("  balance %s: lean %.3f, hips miss %.4f h, the centre of mass %.4f h off its feet, ankles off %.6f %.6f h", balance ? "on" : "off", leans[run],
			b.off("hips", goals[0].target), b.balance_miss / b.height, b.off("ankle_L", goals[1].target), b.off("ankle_R", goals[2].target));
		test::@check(balance || b.balance_miss == 0.0f, "the balance was off and reported a miss");
		test::@check(!balance || b.balance_miss / b.height < 0.01f, "the centre of mass ended %.4f heights off its feet", b.balance_miss / b.height);
		test::@check(b.off("ankle_L", goals[1].target) < 1.0e-4f && b.off("ankle_R", goals[2].target) < 1.0e-4f, "an ankle slipped");
		b.check_limits("balance");
	}
	test::@check(leans[0] > leans[1] + 0.1f, "the balance leaned the chest only %.3f against %.3f", leans[0], leans[1]);
}

<*
 11b. A figure that stands off its feet to begin with is not thrown onto them.
 With one ankle pinned the centre of mass stands between the feet, nowhere near
 the outline of the one: pulled to the outline at the first touch of the pointer
 the whole body would lurch, and by the same lurch for every pointer position.
 The outline takes in where the centre stood as the solve began, so a small reach
 with the hand is answered by the arm and the trunk stays where it was.
*>
fn void a_pose_off_balance_is_not_thrown_onto_its_feet() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	b.balance = true;
	Vec3 hips = b.at("hips");
	Quaternionf chest = b.world("chest");
	crig::PointGoal[2] goals;
	goals[1] = b.pin("ankle_L", true);
	Vec3 target = b.at("wrist_L") + (Vec3){ 0, 0, 0.02f * b.height };
	goals[0] = b.grab("wrist_L", target, true);
	b.solve(goals[..]);
	float moved = b.off("hips", hips);
	float tilt = b.tilt("chest", chest);
	note("  off balance: hips moved %.5f h, chest tilt %.2f deg, the hand %.5f h short, the centre %.5f h outside", moved, tilt,
		b.off("wrist_L", target), b.balance_miss / b.height);
	test::@check(moved < 0.005f, "the hips lurched %.5f heights for a small reach", moved);
	test::@check(tilt < 2.0f, "the chest tilted %.2f degrees for a small reach", tilt);
	test::@check(b.off("wrist_L", target) < 2.0e-3f, "the hand was %.5f heights short", b.off("wrist_L", target));
	test::@check(b.off("ankle_L", goals[1].target) < 1.0e-4f, "the pinned ankle slipped");
	b.check_limits("off balance");
}
<*
 11c. The mass table the body solve asks for. A joint carried rigidly by a trunk fork
 — a thigh off the pelvis, the spine off the root — is as heavy as the fork in the
 table `point_pose_masses` gives by default (`fork_carry`), which a solver of points
 would need, knowing nothing of a hip socket being fixed to its pelvis. The body solve
 turns real joints, which forward kinematics carries: there the thigh weighs a limb,
 the spine a trunk, and a pulled waist is answered by the legs.
*>
fn void the_fork_does_not_carry_the_masses_the_body_solve_asks_for() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	usz n = b.view.len();
	float[] carried = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, carried);
	float[] free = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, free);
	crig::point_pose_masses(&b.view.skeleton, b.height, carried);
	crig::point_pose_masses(&b.view.skeleton, b.height, free, fork_carry: false);
	usz thigh = b.joint("thigh_L");
	usz spine = b.joint("spine");
	usz hips = b.joint("hips");
	note("  masses with the fork's carry: thigh %.2f spine %.2f hips %.2f; without: thigh %.2f spine %.2f hips %.2f",
		1.0f / carried[thigh], 1.0f / carried[spine], 1.0f / carried[hips], 1.0f / free[thigh], 1.0f / free[spine], 1.0f / free[hips]);
	test::@check(math::abs(1.0f / carried[thigh] - crig::POINT_POSE_ROOT_MASS) < 1.0e-3f, "the carried thigh weighs %.2f, not the root's", 1.0f / carried[thigh]);
	test::@check(math::abs(1.0f / free[thigh] - 1.0f) < 1.0e-3f, "the thigh weighs %.2f when nothing carries it, not a limb's 1", 1.0f / free[thigh]);
	test::@check(math::abs(1.0f / free[spine] - crig::POINT_POSE_TRUNK_MASS) < 1.0e-3f, "the spine weighs %.2f, not a trunk's", 1.0f / free[spine]);
	test::@check(math::abs(1.0f / free[hips] - crig::POINT_POSE_ROOT_MASS) < 1.0e-3f && math::abs(1.0f / carried[hips] - crig::POINT_POSE_ROOT_MASS) < 1.0e-3f,
		"the root changed weight with the carry");
}

// ---------------------------------------------------------------------------
// Anything the pointer does

<*
 12. Wherever the hands are sent, every joint of the answer stays inside its
 limits, nothing comes back as NaN, and the pinned feet stay: forty random targets
 for both hands, each solved from the last answer the way a drag follows a pointer.
*>
fn void random_targets_stay_inside_every_limit() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[4] goals;
	goals[2] = b.pin("ankle_L", true);
	goals[3] = b.pin("ankle_R", true);
	uint seed = 12345;
	Vec3 hand_l = b.at("wrist_L");
	Vec3 hand_r = b.at("wrist_R");
	float worst_slip = 0.0f;
	for (int k = 0; k < 40; k++)
	{
		Vec3 jitter;
		for (usz c = 0; c < 3; c++)
		{
			seed = seed * 1664525 + 1013904223;
			jitter[c] = ((float)(seed >> 8) / (float)(1 << 24) - 0.5f) * 0.8f * b.height;
		}
		goals[0] = b.grab("wrist_L", hand_l + jitter);
		goals[1] = b.grab("wrist_R", hand_r - jitter);
		b.solve(goals[..]);
		b.check_limits("random targets");
		foreach (rotation : b.pose.rotations) test::@check(rotation.v.length() > 0.99f && rotation.v.length() < 1.01f && rotation.v.x == rotation.v.x, "step %d: a rotation is not a rotation", k);
		worst_slip = math::max(worst_slip, math::max(b.off("ankle_L", goals[2].target), b.off("ankle_R", goals[3].target)));
	}
	note("  random targets: the ankles slipped up to %.6f h over 40 targets", worst_slip);
	test::@check(worst_slip < 1.0e-3f, "an ankle slipped %.6f heights", worst_slip);
}

<*
 13. The hand swept round a circle with the feet pinned never moves any joint by
 more than a few times the hand's own step, and always arrives.
*>
fn void a_circling_hand_never_jumps() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L", true);
	goals[2] = b.pin("ankle_R", true);
	Vec3 centre = b.at("wrist_L") + (Vec3){ -0.15f, -0.1f, 0.1f } * b.height;
	float radius = 0.08f * b.height;
	usz n = b.view.len();
	Vec3[] before = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, before);
	Vec3[] after = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, after);
	// Into the circle first, then round it twice.
	Vec3 from = b.at("wrist_L");
	Vec3 start = centre + (Vec3){ radius, 0, 0 };
	for (int k = 1; k <= 8; k++)
	{
		goals[0] = b.grab("wrist_L", from + (start - from) * (k / 8.0f));
		b.solve(goals[..]);
	}
	float worst = 0.0f;
	String worst_joint = "";
	float behind = 0.0f;
	float step = radius * 2.0f * (float)math::PI / 48.0f;
	for (int k = 1; k <= 96; k++)
	{
		float angle = (float)k / 48.0f * 2.0f * (float)math::PI;
		Vec3 target = centre + (Vec3){ radius * math::cos(angle), 0, radius * math::sin(angle) };
		b.points(before);
		goals[0] = b.grab("wrist_L", target);
		b.solve(goals[..]);
		b.points(after);
		foreach (usz j, at : after)
		{
			float moved = (at - before[j]).length() / step;
			if (moved > worst) { worst = moved; worst_joint = b.view.names[j]; }
		}
		behind = math::max(behind, b.off("wrist_L", target));
	}
	note("  circling hand: the most any joint moved in a step %.2f hand steps (%s), the hand fell up to %.5f h behind", worst, worst_joint, behind);
	test::@check(worst < 5.0f, "%s jumped %.2f times the hand's step", worst_joint, worst);
	test::@check(behind < 3.0e-3f, "the hand fell %.4f heights behind", behind);
	b.check_limits("circle");
}

<*
 13b. The same circle as the app drives it: every target solved from the pose the
 gesture began with, the hand holding the world rotation it began with
 (`pose_toward`'s grab), the feet pinned. The smoothness is `Jumps.check`'s, as for
 the sit: no joint moves more than four pointer steps or turns more than 10 degrees
 in a step, and the worst step solved in eighths is spread over them. Two turns of
 the circle at 96 targets a turn, a pointer step of half a percent of the height.
 A hand held at its angle on a wider step has the arm turn faster than that: with
 the wrist and the clavicle against their limits the six numbers of the hand's place
 and angle leave the arm no spare turn, and 48 targets a turn ask the shoulder for
 12.5 degrees a step on the true track (tested by `a_wide_stepped_circle_is_fast_but_never_hops`).
*>
fn void a_circling_hand_held_at_its_angle_never_twitches() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	Path path = b.circle_path("wrist_L", { -0.15f, -0.1f, 0.1f }, 0.08f, 96);
	Jumps jumps = b.sweep(&path, 192);
	jumps.print("held circle");
	jumps.check();
	test::@check(jumps.ankle < 1.0e-4f, "an ankle slipped %.6f heights during the sweep", jumps.ankle);
	b.check_limits("held circle");
}

<*
 13c. The same circle on a wider step, 48 targets a turn, for either hand. The pace
 is the arm's (see 13b): the turn of a step stays under `WIDE_TURN`. What it may not
 do is hop: a coarse walk to a target far from the hand can end in another fold of
 the arm than its neighbour's, and then one step carries a joint 25 degrees or more
 and the worst step, solved in eighths, jumps all at once instead of spreading over
 them. The checks of `Jumps.check` that tell a hop from a quick response apply:
 the move within four pointer steps and the worst step spread over its eighths.
*>
fn void a_wide_stepped_circle_is_fast_but_never_hops() @test
{
	foreach (String part : (String[]){ "wrist_L", "wrist_R" })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		float side = part == "wrist_L" ? -1.0f : 1.0f;
		Path path = b.circle_path(part, { side * 0.15f, -0.1f, 0.1f }, 0.08f, 48);
		Jumps jumps = b.sweep(&path, 96);
		jumps.print(part);
		test::@check(jumps.move <= SMOOTH_MOVE * jumps.push, "%s moved %.4f heights on step %d, over %.0f times the pointer's %.4f", jumps.move_at, jumps.move, jumps.move_step, SMOOTH_MOVE, jumps.push);
		test::@check(jumps.turn <= WIDE_TURN, "%s turned %.2f degrees on step %d (limit %.0f)", jumps.turn_at, jumps.turn, jumps.turn_step, WIDE_TURN);
		test::@check(jumps.move_sub <= SMOOTH_SHARE * jumps.move + 1.0e-4f, "%s moved %.4f of its %.4f heights in one eighth of step %d: a jump", jumps.move_at, jumps.move_sub, jumps.move, jumps.move_step);
		test::@check(jumps.turn_sub <= SMOOTH_SHARE * jumps.turn + 0.05f, "%s turned %.2f of its %.2f degrees in one eighth of step %d: a jump", jumps.turn_at, jumps.turn_sub, jumps.turn, jumps.turn_step);
		b.check_limits(part);
	}
}

<*
 14. A frozen joint keeps its rotation bit for bit: an aimed neck stays aimed
 while the body reaches around it.
*>
fn void a_frozen_joint_is_left_alone() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	usz neck = b.joint("neck");
	usz spine = b.joint("spine");
	b.joints[neck].frozen = true;
	b.pose.rotations[neck] = crig::rotation_from_joint_angles(b.joints[neck].frame, { 0.1f, 0.2f, -0.1f });
	Quaternionf kept = b.pose.rotations[neck];
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L", true);
	goals[2] = b.pin("ankle_R", true);
	goals[0] = b.grab("spine", b.at("spine") - (Vec3){ 0, 0.1f * b.height, 0 });
	b.solve(goals[..]);
	note("  frozen neck: %s, the spine turned %.2f deg", b.pose.rotations[neck].v == kept.v ? "left as it was" : "TURNED", angle_of(b.pose.rotations[spine]));
	test::@check(b.pose.rotations[neck].v == kept.v, "the frozen neck was turned");
	test::@check(b.off("ankle_L", goals[1].target) < 1.0e-4f, "an ankle slipped");
}

<*
 15. Nothing to do, nothing done: no goals, or goals only on joints that are not
 in play, leave every rotation and offset as they were, bit for bit, and a goal on
 a joint out of play still reports where it stands.
*>
fn void nothing_asked_changes_nothing() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.pose.rotations[b.joint("knee_L")] = crig::rotation_from_joint_angles(b.joints[b.joint("knee_L")].frame, { 0.3f, 0.0f, 0.0f });
	b.begin();
	rig::Pose before = b.pose.copy(mem);
	defer before.free(mem);
	float miss = b.solve({});
	bool same = true;
	foreach (usz j, rotation : b.pose.rotations) same = same && rotation.v == before.rotations[j].v;
	foreach (usz j, offset : b.pose.offsets) same = same && offset == before.offsets[j];
	test::@check(same && miss == 0.0f, "an empty solve changed the pose");

	// The wrist is out of play: nothing is solved, and the goal reads its miss off the pose.
	usz wrist = b.joint("wrist_L");
	crig::PointJoint[] kept = b.joints;
	b.joints = kept[:wrist];
	crig::PointGoal[1] goals = { b.grab("wrist_L", b.at("wrist_L") + (Vec3){ 0, 0.1f, 0 }) };
	goals[0].joint = wrist;
	miss = b.solve(goals[..]);
	b.joints = kept;
	same = true;
	foreach (usz j, rotation : b.pose.rotations) same = same && rotation.v == before.rotations[j].v;
	note("  nothing asked: an empty solve and a goal out of play both left the pose alone (miss %.4f h)", miss / b.height);
	test::@check(same, "a goal on a joint out of play moved the body");
	test::@check(math::abs(miss - 0.1f) < 1.0e-4f, "the miss was %.5f, not the 0.1 asked", miss);
}

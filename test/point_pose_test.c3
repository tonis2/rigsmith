<*
 The point solver on the real humanoid, called directly: the rig's own joints,
 limits and masses, a goal or two, and what the pose comes back holding.

 Every reading is off `joint_palette`, the same forward kinematics the viewport
 draws by, so a point the solve kept and a rotation it read back wrongly cannot
 pass for one another.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::point_pose`
*>
module crig_tests::point_pose;

import crig;
import rig;
import std::io;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::core::test;

const String PERSON = "assets/animations/humanoid.glb";

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
	bool balance;
	bool has_floor;
	float floor;
}

<*
 Opens the humanoid with its own rig. `knee_back` moves both knees that far
 behind where the model has them before the rig is read, for a figure whose
 rest knees are hyper-extended.
*>
fn bool Body.open(&self, float knee_back = 0.0f)
{
	self.mesh = rig::load_gltf(mem, PERSON)!!;
	self.app = crig::new_app(self.mesh, PERSON);
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "%s must import its rig", PERSON);
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
	self.inv_mass = alloc::new_array(mem, float, (sz)n);
	bool[] trunk = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, trunk);
	crig::point_pose_masses(&self.view.skeleton, self.height, self.inv_mass, trunk);
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

// The gesture begins: what the posture draws back toward is the pose as it stands.
fn void Body.begin(&self)
{
	foreach (usz j, rotation : self.pose.rotations) self.began[j] = rotation;
}

fn float Body.solve(&self, crig::PointGoal[] goals)
{
	crig::PointPoseSettings settings = {
		.height = self.height,
		.posture = self.began,
		.posture_pull = 0.05f,
		.balance = self.balance,
		.has_floor = self.has_floor,
		.floor = self.floor,
	};
	return crig::point_pose(&self.view.skeleton, &self.pose, self.joints, goals, &settings);
}

fn crig::PointGoal Body.grab(&self, String name, Vec3 target) => { .joint = self.joint(name), .position = true, .soft = true, .target = target };
fn crig::PointGoal Body.pin(&self, String name) => { .joint = self.joint(name), .position = true, .target = self.at(name) };

// How far `name` is from `point`, in heights.
fn float Body.off(&self, String name, Vec3 point) => (self.at(name) - point).length() / self.height;

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

// ---------------------------------------------------------------------------
// Bones, pins and the grab

<*
 A hand brought in from a T-pose: the arm folds to reach it, and nothing the arm
 can do on its own is handed to the trunk — the chest and hips stay where they
 were. The bones come back their own length: the solve writes rotations, and
 only the root slides.
*>
fn void a_free_hand_reaches_and_leaves_the_trunk_alone() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	Vec3 from = b.at("wrist_L");
	Vec3 hips = b.at("hips");
	Vec3 chest = b.at("chest");
	Vec3 by = (Vec3){ -0.15f, -0.2f, 0.15f } * b.height;
	crig::PointGoal[1] goals;
	for (int k = 1; k <= 8; k++)
	{
		goals[0] = b.grab("wrist_L", from + by * (k / 8.0f));
		b.solve(goals[..]);
	}
	float miss = b.off("wrist_L", from + by);
	io::printfn("  hand miss %.5f, chest moved %.4f, hips moved %.4f, elbow %.1f", miss,
		b.off("chest", chest), b.off("hips", hips), b.fold("shoulder_L", "elbow_L", "wrist_L"));
	test::@check(miss < 0.002f, "the hand missed by %.4f heights", miss);
	test::@check(b.off("chest", chest) < 0.01f && b.off("hips", hips) < 0.01f, "the trunk moved for a reach the arm could make");
	test::@check(b.fold("shoulder_L", "elbow_L", "wrist_L") > 15.0f, "the elbow did not fold");
	foreach (usz j, offset : b.pose.offsets)
	{
		test::@check(j == b.joint("hips") || offset.length() == 0.0f, "%s was slid, not turned", b.view.names[j]);
	}
	b.check_limits("free hand");
}

<*
 A hand pulled down and out past the arm's reach with the feet pinned: the arm
 straightens against its elbow, and the pull goes on into the shoulder, the
 chest and the hips — the hand keeps coming closer to the pointer every step
 instead of sticking at the elbow, and stops cleanly once the body is out of
 reach, the feet never leaving their pins.
*>
fn void a_pull_past_the_elbows_limit_keeps_tracking() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L");
	goals[2] = b.pin("ankle_R");
	Vec3 from = b.at("wrist_L");
	Vec3 to = from + (Vec3){ 0.2f, -0.6f, 0.2f } * b.height;
	float last = (from - to).length();
	Vec3 was = from;
	float travelled_late = 0.0f;
	for (int k = 1; k <= 24; k++)
	{
		goals[0] = b.grab("wrist_L", from + (to - from) * math::min(k / 16.0f, 1.0f));
		b.solve(goals[..]);
		Vec3 hand = b.at("wrist_L");
		float left = (hand - to).length();
		test::@check(left <= last + b.height * 1.0e-3f, "step %d: the hand fell back from %.4f to %.4f", k, last, left);
		last = left;
		if (k > 20) travelled_late = math::max(travelled_late, (hand - was).length() / b.height);
		was = hand;
		test::@check(b.off("ankle_L", goals[1].target) < 0.002f && b.off("ankle_R", goals[2].target) < 0.002f,
			"step %d: a foot left its pin", k);
	}
	float came = ((from - to).length() - last) / b.height;
	io::printfn("  the hand came %.3f heights of %.3f, still moving %.5f at the end", came, (from - to).length() / b.height, travelled_late);
	test::@check(came > 0.3f, "the hand stuck after %.3f heights", came);
	test::@check(travelled_late < 0.002f, "the hand still wanders %.4f heights a step past reach", travelled_late);
	b.check_limits("pull past reach");
}

<*
 Both ankles pinned and the hips pulled down: the knees fold, the hips go where
 they are pulled, and the ankles do not leave their pins.
*>
fn void pinned_ankles_hold_while_the_hips_drop() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L");
	goals[2] = b.pin("ankle_R");
	Vec3 hips = b.at("hips");
	float drop = 0.15f * b.height;
	for (int k = 1; k <= 8; k++)
	{
		goals[0] = b.grab("hips", hips - (Vec3){ 0, drop * k / 8.0f, 0 });
		b.solve(goals[..]);
	}
	float dropped = (hips.y - b.at("hips").y) / b.height;
	io::printfn("  dropped %.4f of 0.15, slip %.5f %.5f, knees %.1f %.1f", dropped, b.off("ankle_L", goals[1].target),
		b.off("ankle_R", goals[2].target), b.fold("thigh_L", "knee_L", "ankle_L"), b.fold("thigh_R", "knee_R", "ankle_R"));
	test::@check(b.off("ankle_L", goals[1].target) < 0.002f && b.off("ankle_R", goals[2].target) < 0.002f, "an ankle slipped");
	test::@check(dropped > 0.14f, "the hips dropped only %.4f", dropped);
	test::@check(b.knee_ahead("thigh_L", "knee_L", "ankle_L") > 0.02f && b.knee_ahead("thigh_R", "knee_R", "ankle_R") > 0.02f,
		"a knee did not fold forward");
	b.check_limits("squat");
}

<*
 The grab is what gives way: hips pulled up past where the legs reach with both
 ankles pinned rise only until the legs are straight, the ankles stay, and back
 within reach the hips follow the pointer again.
*>
fn void a_grab_gives_way_to_two_pins() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L");
	goals[2] = b.pin("ankle_R");
	Vec3 hips = b.at("hips");
	for (int k = 1; k <= 10; k++)
	{
		goals[0] = b.grab("hips", hips + (Vec3){ 0, 0.03f * k, 0 } * b.height);
		b.solve(goals[..]);
		test::@check(b.off("ankle_L", goals[1].target) < 0.002f && b.off("ankle_R", goals[2].target) < 0.002f,
			"step %d: the pull tore an ankle off its pin", k);
	}
	float rose = (b.at("hips").y - hips.y) / b.height;
	io::printfn("  rose %.4f of 0.3 asked, grab misses %.4f", rose, goals[0].residual / b.height);
	test::@check(rose < 0.02f, "the hips rose %.4f, past the legs' reach", rose);
	test::@check(goals[0].residual > 0.25f * b.height, "the grab reports it was met");

	Vec3 stopped = b.at("hips");
	Vec3 down = hips - (Vec3){ 0, 0.1f, 0 } * b.height;
	for (int k = 1; k <= 10; k++)
	{
		goals[0] = b.grab("hips", stopped + (down - stopped) * (k / 10.0f));
		b.solve(goals[..]);
	}
	test::@check(b.off("hips", down) < 0.002f, "back within reach the hips are %.4f off the pointer", b.off("hips", down));
	test::@check(b.off("ankle_L", goals[1].target) < 0.002f, "the ankle slipped on the way down");
	b.check_limits("grab gives way");
}

<*
 No jump: the hand swept round a circle with the feet pinned never moves any
 joint by more than a few times the hand's own step, and never the feet.
*>
fn void a_continuous_sweep_never_jumps() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L");
	goals[2] = b.pin("ankle_R");
	// Inside the arm's reach all the way round, so every step is one the arm can
	// make: what is checked is that it makes it smoothly.
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
	for (int k = 1; k <= 96; k++)
	{
		float angle = (float)k / 48.0f * 2.0f * (float)math::PI;
		Vec3 target = centre + (Vec3){ radius * math::cos(angle), 0, radius * math::sin(angle) };
		b.points(before);
		goals[0] = b.grab("wrist_L", target);
		b.solve(goals[..]);
		b.points(after);
		float step = radius * 2.0f * (float)math::PI / 48.0f;
		foreach (usz j, at : after)
		{
			float moved = (at - before[j]).length() / step;
			if (moved > worst) { worst = moved; worst_joint = b.view.names[j]; }
		}
		test::@check(b.off("wrist_L", target) < 0.003f, "step %d: the hand fell %.4f behind", k, b.off("wrist_L", target));
	}
	io::printfn("  the most any joint moved in a step: %.2f hand steps (%s)", worst, worst_joint);
	test::@check(worst < 5.0f, "%s jumped %.2f times the hand's step", worst_joint, worst);
	b.check_limits("sweep");
}

<*
 A hinge folds the way its range opens: a squat on pinned ankles brings both
 knees forward, inside their 0..150 hinge, and so does one from knees modelled
 hyper-extended — behind the line from hip to ankle, where folding the right
 way first makes the leg longer.
*>
fn void a_hinge_folds_the_way_it_opens_from_straight_or_past_it() @test
{
	foreach (float back : (float[2]){ 0.0f, 0.03f })
	{
		Body b;
		if (!b.open(knee_back: back)) return;
		defer b.close();
		b.begin();
		float rest_ahead = b.knee_ahead("thigh_L", "knee_L", "ankle_L");
		crig::PointGoal[3] goals;
		goals[1] = b.pin("ankle_L");
		goals[2] = b.pin("ankle_R");
		Vec3 hips = b.at("hips");
		for (int k = 1; k <= 8; k++)
		{
			goals[0] = b.grab("hips", hips - (Vec3){ 0, 0.1f * k / 8.0f, 0 } * b.height);
			b.solve(goals[..]);
		}
		float ahead = b.knee_ahead("thigh_L", "knee_L", "ankle_L");
		io::printfn("  knee back %.2f: rest %.4f ahead, squat %.4f ahead, hips dropped %.4f", back, rest_ahead, ahead,
			(hips.y - b.at("hips").y) / b.height);
		test::@check(ahead > 0.02f, "the knee went %.4f ahead, not forward", ahead);
		test::@check((hips.y - b.at("hips").y) / b.height > 0.09f, "the hips did not come down");
		b.check_limits("hinge");
	}
}

<*
 The floor is a floor: with nothing pinned, the hips pulled down below where the
 legs reach the ground leave the feet on it — the knees fold instead of the body
 sinking through.
*>
fn void the_floor_holds_the_feet() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	b.has_floor = true;
	b.floor = math::min(b.at("toe_L").y, b.at("toe_R").y);
	foreach (String name : (String[]){ "ankle_L", "ankle_R", "toe_L", "toe_R" }) b.joints[b.joint(name)].floored = true;
	crig::PointGoal[1] goals;
	Vec3 hips = b.at("hips");
	for (int k = 1; k <= 8; k++)
	{
		goals[0] = b.grab("hips", hips - (Vec3){ 0, 0.1f * k / 8.0f, 0 } * b.height);
		b.solve(goals[..]);
	}
	float lowest = math::min(b.at("toe_L").y, b.at("toe_R").y);
	io::printfn("  the toes ended %.4f heights above the floor, the knee folded %.1f", (lowest - b.floor) / b.height,
		b.fold("thigh_L", "knee_L", "ankle_L"));
	test::@check(lowest > b.floor - 0.002f * b.height, "a toe sank %.4f heights through the floor", (b.floor - lowest) / b.height);
	test::@check(b.off("hips", goals[0].target) < 0.002f, "the hips did not come down");
	b.check_limits("floor");
}

<*
 Twist carries: a sweep of the hand that swings the arm leaves the forearm's own
 roll — its angle about the bone — where it was.
*>
fn void a_swing_leaves_the_forearms_roll() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	usz elbow = b.joint("elbow_L");
	// Some roll to keep, first.
	Vec3 angles = { 0, 0.4f, -0.5f };
	b.pose.rotations[elbow] = crig::rotation_from_joint_angles(b.joints[elbow].frame, angles);
	b.begin();
	Vec3 from = b.at("wrist_L");
	crig::PointGoal[1] goals;
	for (int k = 1; k <= 8; k++)
	{
		goals[0] = b.grab("wrist_L", from + (Vec3){ 0, 0.15f * k / 8.0f, 0.1f * k / 8.0f } * b.height);
		b.solve(goals[..]);
	}
	Vec3 now = crig::joint_angles_from_rotation(b.joints[elbow].frame, b.pose.rotations[elbow]);
	io::printfn("  the forearm's roll went %.4f -> %.4f, the shoulder turned %.3f", angles.y, now.y,
		2.0f * math::acos(math::min(math::abs(b.pose.rotations[b.joint("shoulder_L")].v.w), 1.0f)));
	test::@check(b.off("wrist_L", goals[0].target) < 0.002f, "the hand did not arrive");
	test::@check(math::abs(now.y - angles.y) < 1.0e-3f, "the forearm's roll went %.4f -> %.4f", angles.y, now.y);
}

<*
 A held world rotation holds: an ankle pinned in position and angle stays flat
 while a squat folds the leg above it.
*>
fn void a_rotation_pin_keeps_the_foot_flat() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[3] goals;
	goals[1] = b.pin("ankle_L");
	goals[1].rotation = true;
	goals[1].orient = b.world("ankle_L");
	goals[2] = b.pin("ankle_R");
	Vec3 hips = b.at("hips");
	for (int k = 1; k <= 8; k++)
	{
		goals[0] = b.grab("hips", hips - (Vec3){ 0, 0.08f * k / 8.0f, 0 } * b.height);
		b.solve(goals[..]);
	}
	io::printfn("  held ankle turned %.4f rad, free ankle %.4f rad", goals[1].turn_residual,
		2.0f * math::acos(math::min(math::abs(b.world("ankle_R").v.w), 1.0f)));
	test::@check(goals[1].turn_residual < 0.02f, "the held foot tilted %.4f rad", goals[1].turn_residual);
	test::@check(b.off("ankle_L", goals[1].target) < 0.002f, "the held foot slid");
	b.check_limits("rotation pin");
}

<*
 The balance: hips pulled down and back over pinned ankles lean the chest out
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
		crig::PointGoal[3] goals;
		goals[1] = b.pin("ankle_L");
		goals[2] = b.pin("ankle_R");
		b.balance = balance;
		Vec3 hips = b.at("hips");
		for (int k = 1; k <= 10; k++)
		{
			goals[0] = b.grab("hips", hips + (Vec3){ 0, -0.15f, -0.1f } * b.height * (k / 10.0f));
			b.solve(goals[..]);
		}
		Vec3 spine = b.at("chest") - b.at("hips");
		leans[run] = spine.z / spine.length();
		io::printfn("  balance %s: lean %.3f, hips miss %.4f", balance, leans[run], b.off("hips", goals[0].target));
		test::@check(b.off("hips", goals[0].target) < 0.003f, "the hips missed the pull");
		test::@check(b.off("ankle_L", goals[1].target) < 0.002f, "an ankle slipped");
		b.check_limits("balance");
	}
	test::@check(leans[0] > leans[1] + 0.1f, "the balance leaned the chest only %.3f against %.3f", leans[0], leans[1]);
}

// ---------------------------------------------------------------------------
// Limits under any target

<*
 Wherever the hands are sent, every joint of the answer stays inside its limits
 — the rotations are read off the points and limited once more on the way out,
 so no target finds a way past them — and the pinned feet stay.
*>
fn void random_targets_stay_inside_every_limit() @test
{
	Body b;
	if (!b.open()) return;
	defer b.close();
	b.begin();
	crig::PointGoal[4] goals;
	goals[2] = b.pin("ankle_L");
	goals[3] = b.pin("ankle_R");
	uint seed = 12345;
	Vec3 hand_l = b.at("wrist_L");
	Vec3 hand_r = b.at("wrist_R");
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
		test::@check(b.off("ankle_L", goals[2].target) < 0.002f, "step %d: an ankle slipped", k);
	}
}

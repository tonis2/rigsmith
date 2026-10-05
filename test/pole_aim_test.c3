<*
 Milestone 5, K1 — stable pole targets.

 The pole solver `aim_chain_pole` already turns a two-bone limb's bend onto the
 side a pole names. These are the guarantees that make it stable enough to build
 on: it says honestly what it did (aimed, clamped by a limit, or ignored because
 the limb named no bend), it gives the same bend for the same request, and every
 "no bend to aim" reading is measured relative to the limb it turns on, so it
 holds at any scale of rig. The MCP surface (`solve_targets`) is covered in
 mcp_test; this drives the solver directly.
*>
module crig_tests::pole_aim;

import crig;
import rig;
import collision;
import std::core::test;
import std::math;
import std::math::matrix;

// A clean two-pivot leg hanging off a fork: the chest keeps the hips branched, so
// the ankle's run of ancestors is exactly [knee, thigh] — a bend to aim, with the
// thigh the root pivot the pole turns. `scale` multiplies the whole figure so the
// same rig can be measured large and small.
struct Leg
{
	crig::AppState app;
	uint hips, thigh, knee, ankle;
}

fn void Leg.open(&self, float scale = 1.0f)
{
	self.app = crig::new_app({});
	self.hips = self.app.doc.add_dot({ 0, 1.0f * scale, 0 }, "hips");
	uint chest = self.app.doc.add_dot({ 0, 1.4f * scale, 0 }, "chest");
	self.thigh = self.app.doc.add_dot({ 0, 0.7f * scale, 0 }, "thigh");
	self.knee = self.app.doc.add_dot({ 0, 0.35f * scale, 0 }, "knee");
	self.ankle = self.app.doc.add_dot({ 0, 0, 0 }, "ankle");
	self.app.doc.connect(self.hips, chest);
	self.app.doc.connect(self.hips, self.thigh);
	self.app.doc.connect(self.thigh, self.knee);
	self.app.doc.connect(self.knee, self.ankle);
	self.app.doc.root_id = self.hips;
}

fn void Leg.close(&self) { self.app.free(); }

// Solve the ankle onto `target` (unless `bend` is false, which leaves the leg
// straight), aim `pole`, and report both what the pole did and where the knee
// ended up in world space — its Z is which way the bend bowed.
fn crig::PoleAim Leg.aim(&self, bool bend, Vec3 target, Vec3 pole, Vec3* knee_at)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);

	rig::Pose pose = rig::rest_pose(mem, view.skeleton.len());
	defer pose.free(mem);

	crig::PoseChain chain = self.app.pose_chain(&view, self.ankle);
	Vec3[crig::IK_MAX_CHAIN + 1] points;
	self.app.chain_points(&view, chain, pose, {}, points[:chain.count + 1]);
	if (bend)
	{
		// tolerance 0 runs every pass, so the bend is the same shape at any scale.
		(void)self.app.solve_limited_pose_chain(&view, chain, &pose,
			points[:chain.count + 1], target, 0.0f, {}, false);
	}
	crig::PoleAim result = self.app.aim_chain_pole(&view, &pose, chain, pole);

	Matrix4f[] pal = rig::joint_palette(mem, &view.skeleton, pose)!!;
	defer alloc::free(mem, pal);
	usz kj = (usz)view.joint_of(self.knee);
	Vec3 rest = view.skeleton.joints[kj];
	float[<4>] moved = pal[kj].apply({ rest.x, rest.y, rest.z, 1.0f });
	*knee_at = { moved.x, moved.y, moved.z };
	return result;
}

<*
 A pole aims the bend to the side it names, and reports that it did.
*>
fn void pole_bows_the_bend_toward_the_side_it_names() @test
{
	Leg leg;
	leg.open();
	defer leg.close();

	Vec3 target = { 0.15f, 0.55f, 0 };
	Vec3 front_at, back_at;
	crig::PoleAim front = leg.aim(true, target, { 0, 0.5f, 5 }, &front_at);
	crig::PoleAim back = leg.aim(true, target, { 0, 0.5f, -5 }, &back_at);

	test::@check(front == crig::PoleAim.AIMED, "a real pole reports it aimed, got %s", front);
	test::@check(back == crig::PoleAim.AIMED, "the opposite pole aims too, got %s", back);
	test::@check(front_at.z > 0.02f, "a +Z pole bows the knee toward +Z (z=%.4f)", front_at.z);
	test::@check(back_at.z < -0.02f, "a -Z pole bows the knee toward -Z (z=%.4f)", back_at.z);
	test::@check(front_at.z > back_at.z + 0.1f, "the pole flips the bend from one side to the other");
}

<*
 The same request gives the same bend — the pole is a single turn, not a search.
*>
fn void the_same_pole_gives_the_same_bend() @test
{
	Leg leg;
	leg.open();
	defer leg.close();

	Vec3 target = { 0.15f, 0.55f, 0 };
	Vec3 first, second;
	leg.aim(true, target, { 0.3f, 0.5f, 2 }, &first);
	leg.aim(true, target, { 0.3f, 0.5f, 2 }, &second);

	test::@check((first - second).length_sq() == 0.0f,
		"the same pole put the knee at %s then %s", first, second);
}

<*
 A straight limb has no bend off the line to swing, so the pole is ignored and
 the leg is left exactly as it was.
*>
fn void a_straight_limb_names_no_bend() @test
{
	Leg leg;
	leg.open();
	defer leg.close();

	Vec3 knee_at;
	crig::PoleAim result = leg.aim(false, {}, { 0, 0.5f, 5 }, &knee_at);
	test::@check(result == crig::PoleAim.STRAIGHT, "a straight leg names no bend, got %s", result);
	test::@check(math::abs(knee_at.z) < 1.0e-6f, "and the pole left it straight (z=%.6g)", knee_at.z);
}

<*
 A pole on the line from the chain root to the effector names no side, so it is
 ignored rather than swinging the bend to a noisy answer.
*>
fn void a_pole_on_the_line_names_no_side() @test
{
	Leg leg;
	leg.open();
	defer leg.close();

	// The thigh is the root pivot and never translates, so a pole at its rest
	// place sits exactly on the root — the far end of the root-effector line.
	Vec3 knee_at;
	crig::PoleAim result = leg.aim(true, { 0.15f, 0.55f, 0 }, { 0, 0.7f, 0 }, &knee_at);
	test::@check(result == crig::PoleAim.POLE_ON_LINE, "a pole on the line names no side, got %s", result);
}

<*
 A pole is read against the arm it turns, not an absolute distance, so a rig
 scaled up by a hundred reaches the same reading and the same shape of bend.
*>
fn void the_pole_reads_the_same_at_any_scale() @test
{
	Leg small, big;
	small.open(1.0f);
	defer small.close();
	big.open(100.0f);
	defer big.close();

	Vec3 small_at, big_at;
	crig::PoleAim rs = small.aim(true, { 0.15f, 0.55f, 0 }, { 0, 0.5f, 5 }, &small_at);
	crig::PoleAim rb = big.aim(true, { 15.0f, 55.0f, 0 }, { 0, 50.0f, 500 }, &big_at);

	test::@check(rs == crig::PoleAim.AIMED && rb == crig::PoleAim.AIMED,
		"a real pole aims at any scale (%s at 1x, %s at 100x)", rs, rb);
	test::@check(small_at.z > 0.0f && big_at.z > 0.0f, "and bows the same way at either size");
	// The hundred-times figure bends a hundred times as far, and no further: the
	// reading did not drift with the scale.
	test::@check(math::abs(big_at.z - small_at.z * 100.0f) <= math::abs(big_at.z) * 1.0e-3f,
		"the bend scaled with the rig (1x z=%.5f, 100x z=%.5f)", small_at.z, big_at.z);
}

<*
 When a rotation limit on the root pivot cuts the twist short, the pole says so
 rather than reporting a clean aim it did not achieve.
*>
fn void a_limit_clamped_pole_reports_it_fell_short() @test
{
	Leg leg;
	leg.open();
	defer leg.close();

	// Lock the thigh — the root pivot the pole turns — so it cannot swing at all.
	crig::JointRotationLimits limits = crig::unconstrained_rotation(leg.thigh);
	limits.constrained = true;
	foreach (&axis : limits.axes)
	{
		axis.allowed = false;
		axis.locked = 0.0f;
	}
	test::@check(leg.app.doc.set_rotation_limits(leg.thigh, limits), "the thigh lock was refused");

	Vec3 knee_at;
	crig::PoleAim result = leg.aim(true, { 0.15f, 0.55f, 0 }, { 0, 0.5f, 5 }, &knee_at);
	test::@check(result == crig::PoleAim.AIMED_TO_LIMIT,
		"a fully locked root pivot cannot aim the pole freely, got %s", result);
}

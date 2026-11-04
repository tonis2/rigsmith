module crig_tests::body_goals;

import crig;
import rig;
import std::collections::list;
import std::core::test;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::math::vector;

// hips, knee, ankle, a toe a short bone from the ankle, and an arm to grab that
// isn't above the foot.
Vec3[5] leg_joints = { { 0, 1, 0 }, { 0, 0.5f, 0 }, { 0, 0.05f, 0 }, { 0, 0, 0.05f }, { 0.3f, 1, 0 } };
int[5] leg_parents = { -1, 0, 1, 2, 0 };
uint[5] leg_dots = { 11, 12, 13, 14, 15 };
String[5] leg_names = { "hips", "knee", "ankle", "toe", "arm" };

fn crig::RigView leg_view() @local
{
	return { .skeleton = { .joints = leg_joints[..], .parents = leg_parents[..] }, .dot_ids = leg_dots[..], .names = leg_names[..] };
}

struct LegPose @local
{
	rig::Pose pose;
	Matrix4f[] palette;
	Quaternionf[] world;
}

fn LegPose rest_leg(crig::RigView* view) @local
{
	rig::Pose pose = rig::rest_pose(mem, 5);
	return {
		.pose = pose,
		.palette = rig::joint_palette(mem, &view.skeleton, pose)!!,
		.world = pose.world_rotations(mem, &view.skeleton)!!,
	};
}

fn void LegPose.free(&self) @local
{
	self.pose.free(mem);
	alloc::free(mem, self.palette);
	alloc::free(mem, self.world);
}

fn void the_gesture_comes_first_then_the_pins() @test
{
	crig::RigView view = leg_view();
	LegPose leg = rest_leg(&view);
	defer leg.free();
	crig::PointGoal[1] gesture = { { .joint = 1, .position = true, .soft = true } };
	crig::PositionLock[1] locks = { { .dot_id = 13, .target = { 0, 0.2f, 0 }, .position = true } };

	List{crig::PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	crig::body_goals(&goals, &view, 0, gesture[..], locks[..], 0, { 0, 0.1f, 0 }, leg.palette, leg.world, {}, {});

	test::@check(goals.len() == 2, "%d goals", goals.len());
	test::@check(goals[0].joint == 1 && goals[0].soft, "the grab is not first");
	test::@check(goals[1].joint == 2 && goals[1].position, "the pin is not second");
	test::@check(math::abs(goals[1].target.y - 0.1f) < 1.0e-6f, "the pin was not shifted: %f", goals[1].target.y);
	// A pin on the position alone keeps the angle softly, as the gesture found it.
	test::@check(goals[1].rotation && goals[1].turn_weight == crig::POINT_POSE_PIN_SOFT_TURN, "no soft angle");
}

fn void a_pin_on_the_angle_holds_it_hard() @test
{
	crig::RigView view = leg_view();
	LegPose leg = rest_leg(&view);
	defer leg.free();
	crig::PointGoal[1] gesture = { { .joint = 1, .position = true } };
	crig::PositionLock[1] locks = { { .dot_id = 13, .rotation = true } };

	List{crig::PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	crig::body_goals(&goals, &view, 0, gesture[..], locks[..], 0, {}, leg.palette, leg.world, {}, {});
	test::@check(goals[1].rotation && goals[1].turn_weight == 0.0f, "the angle is not held hard");
}

fn void the_dragged_joints_pin_does_not_hold_it() @test
{
	crig::RigView view = leg_view();
	LegPose leg = rest_leg(&view);
	defer leg.free();
	crig::PointGoal[1] gesture = { { .joint = 1, .position = true } };
	crig::PositionLock[1] locks = { { .dot_id = 13, .position = true } };

	List{crig::PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	crig::body_goals(&goals, &view, 0, gesture[..], locks[..], 13, {}, leg.palette, leg.world, {}, {});
	test::@check(goals.len() == 1, "a pin held the joint in the user's hand");
}

fn void a_planted_toe_holds_its_heel_too() @test
{
	crig::RigView view = leg_view();
	LegPose leg = rest_leg(&view);
	defer leg.free();
	crig::PointGoal[1] gesture = { { .joint = 4, .position = true } };
	usz[1] standing = { 3 };
	bool[1] planted = { true };

	List{crig::PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	crig::body_goals(&goals, &view, 0, gesture[..], {}, 0, {}, leg.palette, leg.world, standing[..], planted[..]);
	test::@check(goals.len() == 3, "%d goals", goals.len());
	test::@check(goals[1].joint == 3 && goals[1].position, "the toe is not held");
	test::@check(goals[2].joint == 2 && goals[2].turn_weight == crig::POINT_POSE_PIN_SOFT_TURN, "the heel is not held");
}

fn void a_foot_off_the_ground_is_not_held() @test
{
	crig::RigView view = leg_view();
	LegPose leg = rest_leg(&view);
	defer leg.free();
	crig::PointGoal[1] gesture = { { .joint = 4, .position = true } };
	usz[1] standing = { 3 };
	bool[1] planted = { false };

	List{crig::PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	crig::body_goals(&goals, &view, 0, gesture[..], {}, 0, {}, leg.palette, leg.world, standing[..], planted[..]);
	test::@check(goals.len() == 1, "a lifted foot was held");
}

fn void a_foot_under_the_grab_is_lifted_not_stood_on() @test
{
	crig::RigView view = leg_view();
	LegPose leg = rest_leg(&view);
	defer leg.free();
	crig::PointGoal[1] gesture = { { .joint = 1, .position = true } };
	usz[1] standing = { 3 };
	bool[1] planted = { true };

	List{crig::PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	crig::body_goals(&goals, &view, 0, gesture[..], {}, 0, {}, leg.palette, leg.world, standing[..], planted[..]);
	test::@check(goals.len() == 1, "a foot in the user's hand was held down");
}

fn void standing_joints_are_marked_floored() @test
{
	crig::RigView view = leg_view();
	crig::RigDocument doc;
	float[5] inv = { 1, 1, 1, 1, 1 };
	bool[5] trunk = { true, false, false, false, false };
	usz[1] standing = { 3 };
	crig::AimAppliedSet none;

	List{crig::PointJoint} joints;
	joints.init(mem);
	defer joints.free();
	crig::body_joints(&joints, &doc, &view, 0, inv[..], trunk[..], &none, standing[..]);
	test::@check(joints.len() == 5, "%d joints", joints.len());
	test::@check(joints[0].trunk && !joints[1].trunk, "the trunk was lost");
	test::@check(joints[3].floored && !joints[2].floored, "the floored joint was not marked");
}

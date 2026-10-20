<*
 A clip carried onto a rig built differently plays the same whichever way the
 figure faces.

 A clip made on another rig is carried onto this one relative to each rig's
 rest (`AnimTemplate.pose`). That carry has to ride the figure's heading: a clip
 captured from a side camera faces a quarter turn round, and carried about the
 world's axes instead its arms swung forward where they should hang.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::retarget_facing`
*>
module crig_tests::retarget_facing;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::quaternion;

// Hips, chest, and an arm this rig built reaching forward at rest; the clip's
// rig had it hanging, so the arm is carried (not an arm held at another
// height, which the A-pose rule takes instead).
fn rig::Pose posed(float heading)
{
	Vec3[4] at = { { 0, 1, 0 }, { 0, 1.5f, 0 }, { 0.2f, 1.4f, 0 }, { 0.2f, 1.4f, 0.4f } };
	int[4] parents = { -1, 0, 1, 2 };
	rig::Skeleton skeleton = { .joints = at[..], .parents = parents[..] };
	String[4] names = { "hips", "chest", "arm_L", "hand_L" };

	crig::AnimKeyDot[2] dots = {
		{ .joint_name = "hips", .axis = { 0, 1, 0 }, .angle = heading, .bone = { 0, 1, 0 }, .channels = ROTATION },
		{ .joint_name = "arm_L", .axis = { 1, 0, 0 }, .angle = 0.5f, .bone = { 0, -1, 0 }, .channels = ROTATION },
	};
	crig::AnimKeyframe[2] keys = { { .time = 0.0f, .dots = dots[..] }, { .time = 1.0f, .dots = dots[..] } };
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..] };
	return clip.pose(mem, &skeleton, names[..], 0.5f, false);
}

fn void a_carried_arm_moves_the_same_whichever_way_the_figure_faces() @test
{
	rig::Pose ahead = posed(0.0f);
	defer ahead.free(mem);
	float quarter = (float)math::PI / 2.0f;
	rig::Pose turned = posed(quarter);
	defer turned.free(mem);

	float same = math::abs(ahead.rotations[2].v.dot(turned.rotations[2].v));
	test::@check(same > 0.9999f, "the arm's turn against its parent changes with the facing (|dot| %f)", same);
	Quaternionf want = quaternion::from_axis_angle{float}({ 0, 1, 0 }, quarter).mul(ahead.rotations[0]);
	float hips = math::abs(want.v.dot(turned.rotations[0].v));
	test::@check(hips > 0.9999f, "the hips are the facing turned (|dot| %f)", hips);
}

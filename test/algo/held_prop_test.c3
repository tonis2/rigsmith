<*
 Held props and the pins held relative to another joint (algo/pose/held_prop.c3,
 algo/layers/pin.c3). Pure data: no app, no files.
*>
module crig_tests::held_prop;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::io::file;
import std::collections::object;
import std::encoding::json;
import gltf_edit;

// Hips under a chest with two straight arms out to the sides.
Vec3[8] arm_joints @local = {
	{ 0, 1.0f, 0 }, { 0, 1.4f, 0 },
	{ 0.2f, 1.4f, 0 }, { 0.45f, 1.4f, 0 }, { 0.7f, 1.4f, 0 },
	{ -0.2f, 1.4f, 0 }, { -0.45f, 1.4f, 0 }, { -0.7f, 1.4f, 0 },
};
int[8] arm_parents @local = { -1, 0, 1, 2, 3, 1, 5, 6 };
String[8] arm_names @local = { "hips", "chest", "shoulder_L", "elbow_L", "wrist_L", "shoulder_R", "elbow_R", "wrist_R" };
const usz WRIST_L @local = 4;
const usz WRIST_R @local = 7;

fn rig::Skeleton arm_rig() @local => { .joints = arm_joints[..], .parents = arm_parents[..] };

// Where the support hand should be: the pin's point in the prop hand's posed frame.
fn Vec3 held_point(rig::Skeleton* skeleton, rig::Pose pose, Vec3 at) @local
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);
	Quaternionf[] world = pose.world_rotations(mem, skeleton)!!;
	defer alloc::free(mem, world);
	return skeleton.joints[WRIST_R].transform(palette[WRIST_R]) + world[WRIST_R].rotate_vec3(at);
}

fn Vec3 joint_at(rig::Skeleton* skeleton, rig::Pose pose, usz joint) @local
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);
	return skeleton.joints[joint].transform(palette[joint]);
}

<*
 The left hand held on a point in the right hand's frame lands on it wherever
 the right arm swings: the grip follows the prop hand.
*>
fn void a_relative_pin_follows_the_prop_hand() @test
{
	rig::Skeleton skeleton = arm_rig();
	crig::AnimPin[1] pins;
	pins[0] = crig::pin_defaults(mem, "wrist_L", {}, 0.0f, 1.0f);
	pins[0].relative_to = "wrist_R".copy(mem);
	defer pins[0].free(mem);

	float[3] swings = { 1.5f, 1.7f, 1.9f };
	foreach (usz i, swing : swings)
	{
		rig::Pose pose = rig::rest_pose(mem, skeleton.len());
		defer pose.free(mem);
		pose.rotations[5] = quaternion::from_axis_angle{float}({ 0, 1, 0 }, swing);
		pose.rotations[6] = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.2f);
		// The grip is set in front of the chest on the first swing, then rides the hand.
		if (i == 0)
		{
			Quaternionf[] world = pose.world_rotations(mem, &skeleton)!!;
			defer alloc::free(mem, world);
			pins[0].at = world[WRIST_R].invert().rotate_vec3((Vec3){ 0.05f, 1.3f, 0.35f } - joint_at(&skeleton, pose, WRIST_R));
		}
		Vec3 want = held_point(&skeleton, pose, pins[0].at);
		test::@check((want - arm_joints[2]).length() < 0.48f, "swing %.2f: the grip is out of the left arm's reach", swing);
		crig::pin_pose(mem, &skeleton, arm_names[..], pins[..], 0.5f, 1.0f, false, &pose, 1.0f);

		Vec3 got = joint_at(&skeleton, pose, WRIST_L);
		test::@check((got - want).length() < 0.005f, "swing %.2f: the left hand is %.3f off the grip", swing, (got - want).length());
		test::@check((want - held_point(&skeleton, pose, pins[0].at)).length() < 1.0e-5f,
			"swing %.2f: the pin moved the prop hand", swing);
	}
}

<*
 A pin held relative to a joint its own limb carries is refused: it would chase
 itself.
*>
fn void a_pin_relative_to_its_own_limb_holds_nothing() @test
{
	rig::Skeleton skeleton = arm_rig();
	crig::AnimPin[1] pins;
	pins[0] = crig::pin_defaults(mem, "wrist_L", { 0.0f, -0.2f, 0.0f }, 0.0f, 1.0f);
	pins[0].relative_to = "elbow_L".copy(mem);
	defer pins[0].free(mem);
	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	crig::pin_pose(mem, &skeleton, arm_names[..], pins[..], 0.5f, 1.0f, false, &pose, 1.0f);
	foreach (q : pose.rotations) test::@check(math::abs(q.l) > 0.9999f, "a joint turned");
	test::@check(!crig::pin_reference_allowed(&skeleton, WRIST_L, WRIST_L), "a pin may ride its own joint");
	test::@check(crig::pin_reference_allowed(&skeleton, WRIST_L, WRIST_R), "the other hand was refused");
}

<*
 A prop rides its hand: at rest it sits at the grip offset, and posed it turns
 with the hand.
*>
fn void a_prop_follows_its_hand() @test
{
	rig::Skeleton skeleton = arm_rig();
	crig::HeldProp prop = crig::default_prop(&skeleton, arm_names[..], WRIST_R, 1, crig::PropKind.SWORD);
	test::@check(prop.held(), "the default sword has no length");
	Vec3 blade = prop.turn.rotate_vec3({ 0, 1, 0 });
	Vec3 hand = (arm_joints[WRIST_R] - arm_joints[6]).normalize();
	test::@check(math::abs(blade.dot(hand)) < 1.0e-3f, "the blade is not square to the hand (%.3f)", blade.dot(hand));

	crig::PropFrame rest = crig::prop_frame(&skeleton, {}, WRIST_R, prop);
	test::@check((rest.at - arm_joints[WRIST_R] - prop.offset * skeleton.height()).length() < 1.0e-5f, "the grip left the hand at rest");

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	Quaternionf swing = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 1.0f);
	pose.rotations[5] = swing;
	Matrix4f[] palette = rig::joint_palette(mem, &skeleton, pose)!!;
	defer alloc::free(mem, palette);
	crig::PropFrame posed = crig::prop_frame(&skeleton, palette, WRIST_R, prop);
	Vec3 want = joint_at(&skeleton, pose, WRIST_R) + swing.rotate_vec3(prop.offset * skeleton.height());
	test::@check((posed.at - want).length() < 1.0e-4f, "the grip is %.4f off the posed hand", (posed.at - want).length());
	Vec3 tip = posed.turn.rotate_vec3({ 0, 1, 0 });
	test::@check((tip - swing.rotate_vec3(blade)).length() < 1.0e-4f, "the blade did not turn with the hand");
}

<*
 Both named wrists are hands; nothing else on the arm is.
*>
fn void the_named_wrists_are_hands() @test
{
	rig::Skeleton skeleton = arm_rig();
	bool[] hands = crig::rig_arm_wrists(mem, &skeleton, arm_names[..]);
	defer alloc::free(mem, hands);
	foreach (usz j, hand : hands)
	{
		test::@check(hand == (j == WRIST_L || j == WRIST_R), "%s is%s a hand", arm_names[j], hand ? "" : " not");
	}
}

// A node's own translation and rotation, out of its glTF object.
fn void node_local(Object* node, Vec3* at, Quaternionf* turn) @local
{
	*at = {};
	*turn = quaternion::IDENTITY;
	if (try Object* t = node.get("translation"))
	{
		*at = { (float)t.get_float_at(0)!!, (float)t.get_float_at(1)!!, (float)t.get_float_at(2)!! };
	}
	if (try Object* r = node.get("rotation"))
	{
		*turn = { .v = { (float)r.get_float_at(0)!!, (float)r.get_float_at(1)!!, (float)r.get_float_at(2)!!, (float)r.get_float_at(3)!! } };
	}
}

<*
 The export that writes a fresh file hangs the socket under the hand's
 bone-aligned node, so in the world it sits at the grip and turns as the prop.
*>
fn void an_export_writes_the_socket_under_the_hand() @test
{
	rig::Skeleton skeleton = arm_rig();
	float[1] radii = { 0.03f };
	rig::TriMesh body = crig::dummy_body(mem, &skeleton, radii[..]);
	defer body.free(mem);
	crig::HeldProp prop = crig::default_prop(&skeleton, arm_names[..], WRIST_R, 1, crig::PropKind.SWORD);
	float height = skeleton.height();
	crig::PropSocket[1] sockets = { { .joint = WRIST_R, .offset = prop.offset * height, .turn = prop.turn } };
	String path = "build/held-prop-export.glb";
	defer (void)file::delete(path);
	crig::export_rigged_animated_glb(mem, path, body, &skeleton, arm_names[..], {}, {}, sockets: sockets[..])!!;

	gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, path)!!;
	defer parts.free(mem);
	Object* parsed = json::parse(mem, (String)parts.json)!!;
	defer parsed.free();
	Object* nodes = parsed.get("nodes")!!;
	sz socket = -1;
	for (sz i = 0; i < nodes.get_len(); i++) if ((nodes.get_at(i).get_string("name") ?? "") == "wrist_R.socket") socket = i;
	test::@check(socket >= 0, "no wrist_R.socket node was written");
	if (socket < 0) return;

	// Up the parents to the scene, composing each node's transform.
	Vec3 at;
	Quaternionf turn;
	node_local(nodes.get_at(socket), &at, &turn);
	sz walk = socket;
	sz first_parent = -1;
	for (usz guard = 0; guard < 64; guard++)
	{
		sz parent = -1;
		for (sz i = 0; i < nodes.get_len() && parent < 0; i++)
		{
			Object*? children = nodes.get_at(i).get("children");
			if (catch children) continue;
			for (sz k = 0; k < children.get_len(); k++) if (children.get_int_at(k)!! == walk) parent = i;
		}
		if (parent < 0) break;
		if (first_parent < 0) first_parent = parent;
		Vec3 up_at;
		Quaternionf up_turn;
		node_local(nodes.get_at(parent), &up_at, &up_turn);
		at = up_at + up_turn.rotate_vec3(at);
		turn = up_turn.mul(turn);
		walk = parent;
	}
	test::@check(first_parent >= 0 && (nodes.get_at(first_parent).get_string("name") ?? "") == "wrist_R", "the socket is not under wrist_R");
	Vec3 grip = arm_joints[WRIST_R] + prop.offset * height;
	test::@check((at - grip).length() < 1.0e-4f, "the socket is %.5f from the grip", (at - grip).length());
	Vec3 blade = turn.rotate_vec3({ 0, 1, 0 });
	test::@check((blade - prop.turn.rotate_vec3({ 0, 1, 0 })).length() < 1.0e-4f, "the socket's +Y is not along the blade");
}

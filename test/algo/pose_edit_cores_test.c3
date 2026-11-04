<* The pure steps of keying and pinning, on a small rig built here. *>
module crig_tests::pose_edit_cores;

import crig;
import rig;
import std::collections::list;
import std::core::test;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::math::vector;

const float NEAR = 1.0e-4f;

// hips, spine, head upright, and a foot hanging from the hips.
Vec3[4] rig_joints = { { 0, 1, 0 }, { 0, 1.5f, 0 }, { 0, 2, 0 }, { 0, 0, 0 } };
int[4] rig_parents = { -1, 0, 1, 0 };
uint[4] rig_dots = { 21, 22, 23, 24 };
String[4] rig_names = { "hips", "spine", "head", "foot" };

fn crig::RigView small_view() @local
{
	return { .skeleton = { .joints = rig_joints[..], .parents = rig_parents[..] }, .dot_ids = rig_dots[..], .names = rig_names[..] };
}

// ---- key_offsets_of

fn void only_what_changed_becomes_an_offset() @test
{
	rig::Pose before = rig::rest_pose(mem, 4);
	defer before.free(mem);
	rig::Pose after = rig::rest_pose(mem, 4);
	defer after.free(mem);
	after.turn(1, { 0, 1, 0 }, 0.5f);
	after.move(2, { 0, 1, 0 });
	bool[4] all = { true, true, true, true };

	List{crig::KeyOffset} offsets;
	offsets.init(mem);
	defer offsets.free();
	bool turns, moves;
	crig::key_offsets_of(&offsets, rig_names[..], before, after, 2.0f, all[..], all[..], &turns, &moves);
	test::@check(offsets.len() == 2, "%d offsets", offsets.len());
	test::@check(offsets[0].joint == "spine" && offsets[0].rotates && !offsets[0].moves, "the turn");
	test::@check(offsets[1].joint == "head" && offsets[1].moves && !offsets[1].rotates, "the move");
	test::@check(math::abs(offsets[1].move.y - 0.5f) < NEAR, "a move is a fraction of the height");
	test::@check(turns && moves, "the summary");
}

fn void a_joint_left_out_gives_no_offset() @test
{
	rig::Pose before = rig::rest_pose(mem, 4);
	defer before.free(mem);
	rig::Pose after = rig::rest_pose(mem, 4);
	defer after.free(mem);
	after.turn(1, { 0, 1, 0 }, 0.5f);
	after.move(1, { 0, 1, 0 });
	bool[4] none;
	bool[4] moves_only = { false, true, false, false };

	List{crig::KeyOffset} offsets;
	offsets.init(mem);
	defer offsets.free();
	bool turns, moves;
	crig::key_offsets_of(&offsets, rig_names[..], before, after, 1.0f, none[..], moves_only[..], &turns, &moves);
	test::@check(offsets.len() == 1 && !offsets[0].rotates && offsets[0].moves, "the channel filter failed");
	test::@check(!turns && moves, "the summary");
}

// ---- aims

fn void a_new_target_goes_in_front_of_the_root_with_nothing_picked() @test
{
	crig::RigView view = small_view();
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	Vec3 at;
	test::@check(crig::aim_spot_for(&view, pose, {}, {}, {}, &at), "no spot");
	float height = view.skeleton.height();
	test::@check(math::abs(at.z - crig::AIM_FRONT_REACH) < NEAR, "not in front: %f", at.z);
	test::@check(math::abs(at.y - (1.0f + 0.2f * height) / height) < NEAR, "not at chest height: %f", at.y);
}

fn void an_upright_joint_looks_out_its_front() @test
{
	crig::RigView view = small_view();
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	uint[1] dots = { 23 };
	Vec3[1] positions = { { 0, 2, 0 } };
	Quaternionf[1] worlds = { quaternion::IDENTITY };
	Vec3 at;
	test::@check(crig::aim_spot_for(&view, pose, dots[..], positions[..], worlds[..], &at), "no spot");
	test::@check(math::abs(at.z - crig::AIM_FRONT_REACH) < NEAR && math::abs(at.x) < NEAR, "not in front: %s", at);
}

fn void an_existing_lock_keeps_its_settings_on_a_new_target() @test
{
	crig::RigView view = small_view();
	crig::AnimAim[1] held = { crig::aim_defaults(mem, "head", "Old", { 0, 0, 1 }) };
	defer held[0].free(mem);
	held[0].influence = 0.25f;
	String[2] names = { "head", "spine" };
	Vec3[2] positions = { { 0, 2, 0 }, { 0, 1.5f, 0 } };
	Quaternionf[2] worlds = { quaternion::IDENTITY, quaternion::IDENTITY };
	uint[2] dots = { 23, 22 };

	crig::AnimAim[] locks = crig::aim_locks_for(mem, &view, held[..], names[..], positions[..], worlds[..], dots[..], "New", { 0, 1, 1 });
	defer crig::free_aims(mem, locks);
	test::@check(locks.len == 2, "%d locks", locks.len);
	test::@check(locks[0].target == "New" && locks[0].influence == 0.25f, "the kept lock");
	test::@check(locks[1].joint == "spine" && locks[1].target == "New", "the fresh lock");
}

// ---- foot pins

fn void a_set_floor_moves_the_pins_with_it() @test
{
	crig::RigView view = small_view();
	crig::AnimFoot[1] feet = { { .joint = "foot", .down = 0, .up = 1 } };
	crig::AnimGround ground = { .feet = feet[..], .floor = 0.25f, .floor_set = true };
	test::@check(math::abs(crig::pin_floor_shift(&view.skeleton, rig_names[..], ground) - 0.25f) < NEAR, "the shift");
	ground.floor_set = false;
	test::@check(crig::pin_floor_shift(&view.skeleton, rig_names[..], ground) == 0.0f, "no spec, no shift");
}

fn void a_foot_pin_stands_on_the_floor_and_runs_back_by_the_travel() @test
{
	crig::RigView view = small_view();
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	pose.move(3, { 0.5f, 0.3f, 0 });

	crig::AnimPin pin = crig::foot_pin_at(mem, &view.skeleton, pose, 3, "foot", 0.1f, 0.5f, 0.2f, 1.0f, { 1, 0, 0 }, false)!!;
	defer pin.free(mem);
	float height = view.skeleton.height();
	test::@check(math::abs(pin.at.x - 0.5f / height) < NEAR, "the foot's place was lost: %f", pin.at.x);
	test::@check(math::abs(pin.at.y - 0.2f / height) < NEAR, "not on the floor: %f", pin.at.y);
	test::@check(math::abs(pin.blend - 0.2f) < NEAR, "the blend is capped at half the window: %f", pin.blend);
	test::@check(math::abs(pin.travel.x + 1.0f / height) < NEAR, "the travel: %f", pin.travel.x);
	test::@check(!pin.rotation, "a pin not asked to be flat held the angle");
}

fn void a_flat_pin_keeps_only_the_yaw() @test
{
	crig::RigView view = small_view();
	rig::Pose pose = rig::rest_pose(mem, 4);
	defer pose.free(mem);
	pose.turn(3, { 1, 0, 0 }, 0.4f);
	crig::AnimPin pin = crig::foot_pin_at(mem, &view.skeleton, pose, 3, "foot", 0, 1, 0, 0, {}, true)!!;
	defer pin.free(mem);
	test::@check(pin.rotation, "the angle isn't held");
	test::@check(math::abs(pin.orient.v.x) < NEAR, "the tilt was kept");
}

fn void a_window_past_the_end_of_a_loop_wraps_as_a_contact() @test
{
	crig::AnimPin[1] pins = { { .joint = "foot", .from = 1.5f, .to = 2.5f } };
	crig::AnimTemplate clip = { .duration = 2.0f, .loop = true };
	crig::AnimFoot[] feet = crig::pins_as_feet(mem, pins[..], clip);
	defer
	{
		foreach (&foot : feet) alloc::free(mem, foot.joint.ptr);
		alloc::free(mem, feet);
	}
	test::@check(feet.len == 1 && feet[0].joint == "foot", "the foot");
	test::@check(math::abs(feet[0].down - 0.75f) < NEAR, "down %f", feet[0].down);
	test::@check(math::abs(feet[0].up - 0.25f) < NEAR, "up %f", feet[0].up);
}

fn void the_ground_spec_names_the_windows_and_skips_a_hand_on_a_wall() @test
{
	crig::RigView view = small_view();
	crig::AnimFoot[2] feet = { { .joint = "foot", .down = 0.25f, .up = 0.5f }, { .joint = "foot", .down = 0.6f, .up = 0.7f, .off_floor = true } };
	crig::AnimTemplate clip = { .duration = 2.0f, .ground = { .feet = feet[..] } };
	String[1] joints = { "foot" };

	crig::FootWindowList windows;
	windows.init(mem);
	defer windows.free();
	crig::foot_windows_of(&windows, &view.skeleton, rig_names[..], clip, joints[..]);
	test::@check(windows.len() == 1, "%d windows", windows.len());
	test::@check(math::abs(windows[0].from - 0.5f) < NEAR && math::abs(windows[0].to - 1.0f) < NEAR, "the seconds");
}

// ---- layers

fn void the_layers_above_are_taken_back_out() @test
{
	rig::Pose drafted = rig::rest_pose(mem, 2);
	defer drafted.free(mem);
	rig::Pose full = rig::rest_pose(mem, 2);
	defer full.free(mem);
	rig::Pose incl = rig::rest_pose(mem, 2);
	defer incl.free(mem);
	rig::Pose wanted = rig::rest_pose(mem, 2);
	defer wanted.free(mem);

	// Joint 0 untouched by the person; joint 1 moved 0.5 past what the stack showed.
	full.move(0, { 1, 0, 0 });
	drafted.move(0, { 1, 0, 0 });
	incl.move(0, { 0.25f, 0, 0 });
	full.move(1, { 1, 0, 0 });
	drafted.move(1, { 1.5f, 0, 0 });
	incl.move(1, { 0.25f, 0, 0 });

	crig::take_out_layers_above(&wanted, drafted, full, incl);
	test::@check(math::abs(wanted.offsets[0].x - 0.25f) < NEAR, "an untouched joint left the stack: %f", wanted.offsets[0].x);
	test::@check(math::abs(wanted.offsets[1].x - 0.75f) < NEAR, "the person's move was lost: %f", wanted.offsets[1].x);
}

fn crig::LayerKeyAsk layer_ask(crig::RigView* view, crig::AnimTemplate* clip, crig::AnimLayer* layer, rig::Pose below, rig::Pose wanted, bool[] selected) @local
{
	return {
		.skeleton = &view.skeleton,
		.names = rig_names[..],
		.clip = clip,
		.below_clip = clip,
		.layer = layer,
		.time = 0.0f,
		.gain = 1.0f,
		.below = below,
		.incl = below,
		.wanted = wanted,
		.scope = ALL,
		.selected = selected,
	};
}

fn void a_sparse_layer_keys_only_the_joint_that_differs() @test
{
	crig::RigView view = small_view();
	crig::AnimTemplate clip = { .duration = 1.0f };
	crig::AnimLayer layer = { .weight = 1.0f, .mode = ADDITIVE, .kind = KEYED };
	rig::Pose below = rig::rest_pose(mem, 4);
	defer below.free(mem);
	rig::Pose wanted = rig::rest_pose(mem, 4);
	defer wanted.free(mem);
	wanted.turn(2, { 0, 1, 0 }, 0.5f);
	bool[4] selected;

	crig::LayerKeyAsk ask = layer_ask(&view, &clip, &layer, below, wanted, selected[..]);
	crig::AnimKeyframe key = crig::layer_key_for(&ask);
	defer key.free(mem);
	test::@check(key.dots.len == 1 && key.dots[0].joint_name == "head", "%d dots", key.dots.len);
	test::@check(math::abs(key.dots[0].angle - 0.5f) < 1.0e-3f, "the turn was %f", key.dots[0].angle);
}

fn void a_selected_scope_keys_the_selection_whatever_moved() @test
{
	crig::RigView view = small_view();
	crig::AnimTemplate clip = { .duration = 1.0f };
	crig::AnimLayer layer = { .weight = 1.0f, .mode = ADDITIVE, .kind = KEYED };
	rig::Pose below = rig::rest_pose(mem, 4);
	defer below.free(mem);
	rig::Pose wanted = rig::rest_pose(mem, 4);
	defer wanted.free(mem);
	wanted.turn(2, { 0, 1, 0 }, 0.5f);
	bool[4] selected = { false, true, false, false };

	crig::LayerKeyAsk ask = layer_ask(&view, &clip, &layer, below, wanted, selected[..]);
	ask.scope = SELECTED;
	crig::AnimKeyframe key = crig::layer_key_for(&ask);
	defer key.free(mem);
	test::@check(key.dots.len == 1 && key.dots[0].joint_name == "spine", "%d dots", key.dots.len);
}

fn void a_half_weight_layer_holds_twice_the_gap() @test
{
	crig::RigView view = small_view();
	crig::AnimTemplate clip = { .duration = 1.0f };
	crig::AnimLayer layer = { .weight = 0.5f, .mode = ADDITIVE, .kind = KEYED };
	rig::Pose below = rig::rest_pose(mem, 4);
	defer below.free(mem);
	rig::Pose wanted = rig::rest_pose(mem, 4);
	defer wanted.free(mem);
	wanted.turn(2, { 0, 1, 0 }, 0.25f);
	bool[4] selected;

	crig::LayerKeyAsk ask = layer_ask(&view, &clip, &layer, below, wanted, selected[..]);
	ask.gain = 0.5f;
	crig::AnimKeyframe key = crig::layer_key_for(&ask);
	defer key.free(mem);
	test::@check(key.dots.len == 1 && math::abs(key.dots[0].angle - 0.5f) < 1.0e-3f, "held %f", key.dots.len > 0 ? key.dots[0].angle : 0.0f);
}

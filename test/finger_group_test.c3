<*
 A hand's fingertips selected together: one look-at target bends every finger,
 and G carries every tip, not only the one under the pointer.

     `c3c test --trust=full --test-filter crig_tests::finger_group`
*>
module crig_tests::finger_group;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;

const String HUMANOID = "assets/animations/humanoid.glb";

struct Hand
{
	crig::AppState app;
	rig::TriMesh mesh;
	uint[4] tips;
	uint[4] knuckles; // the _2 joint of each finger
}

fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

fn bool Hand.open(&self)
{
	rig::TriMesh? loaded = rig::load_gltf(mem, HUMANOID);
	if (catch loaded) return false;
	self.mesh = loaded;
	self.app = crig::new_app(self.mesh, HUMANOID);
	self.app.adopt_source_rig();
	String[4] fingers = { "index", "middle", "ring", "pinky" };
	foreach (usz i, finger : fingers)
	{
		self.tips[i] = dot_named(&self.app, string::tformat("%s_4_L", finger));
		self.knuckles[i] = dot_named(&self.app, string::tformat("%s_2_L", finger));
		if (self.tips[i] == 0 || self.knuckles[i] == 0) return false;
	}
	crig::AnimRef clip = self.app.new_clip("hand", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.5f;
	self.app.stage = POSE_STAGE;
	self.app.auto_key = false;
	self.app.select(self.tips[0]);
	for (usz i = 1; i < 4; i++) self.app.extend_selection(self.tips[i]);
	return true;
}

fn void Hand.close(&self)
{
	self.app.free();
	self.mesh.free(mem);
}

// Where `id` stands on screen, look-at targets included.
fn Vec3 Hand.at(&self, uint id)
{
	crig::AppState* app = &self.app;
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.draft_pose(mem, &view);
	defer pose.free(mem);
	app.apply_clip_aims(&view, *app.clip(app.editing), app.editing, app.edit_time, &pose);
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	usz joint = (usz)view.joint_of(id);
	return view.skeleton.joints[joint].transform(palette[joint]);
}

fn void four_fingertips_on_one_target_bend_four_fingers() @test
{
	Hand hand;
	test::@check(hand.open(), "the humanoid did not open");
	defer hand.close();
	crig::AppState* app = &hand.app;
	Vec3[4] tips_before;
	foreach (usz i, tip : hand.tips) tips_before[i] = hand.at(tip);

	test::@check(app.add_aim_target(), "the target was not added");
	crig::AnimTemplate* clip = app.clip(app.editing);
	test::@check(clip.aims.len == 4, "%d locks, not four", clip.aims.len);
	foreach (aim : clip.aims)
	{
		test::@check(aim.spread == 4 && aim.weights[0] == 0.0f && aim.weights[1] > 0.0f,
			"%s spreads over %d with the tip weighted %f", aim.joint, aim.spread, aim.weights[0]);
	}
	foreach (usz i, tip : hand.tips)
	{
		test::@check((hand.at(tip) - tips_before[i]).length() < 1.0e-4f, "locking moved tip %d", i);
	}

	// The target dragged well below the hand: every finger curls toward it.
	Vec3 start = app.posed_aims[0].at;
	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	app.aim_target_toward(start + (Vec3){ 0.0f, -0.5f, 0.0f });
	app.end_drag();
	foreach (usz i, tip : hand.tips)
	{
		float dropped = tips_before[i].y - hand.at(tip).y;
		test::@check(dropped > 0.01f, "fingertip %d dropped only %f", i, dropped);
	}
}

fn void g_carries_every_selected_fingertip() @test
{
	Hand hand;
	test::@check(hand.open(), "the humanoid did not open");
	defer hand.close();
	crig::AppState* app = &hand.app;
	Vec3[4] before;
	foreach (usz i, tip : hand.tips) before[i] = hand.at(tip);

	test::@check(app.begin_pose(), "the grab did not begin");
	Vec3 down = { 0.0f, -0.02f, 0.0f };
	for (int k = 1; k <= 4; k++) (void)app.pose_toward(app.drag.from + down * (float)k * 0.25f);
	foreach (usz i, tip : hand.tips)
	{
		float dropped = before[i].y - hand.at(tip).y;
		test::@check(dropped > 0.01f, "fingertip %d dropped only %f during the grab", i, dropped);
	}

	// Escape puts every finger back.
	test::@check(app.cancel_drag(), "the grab did not cancel");
	foreach (usz i, tip : hand.tips)
	{
		test::@check((hand.at(tip) - before[i]).length() < 1.0e-4f, "escape left fingertip %d moved", i);
	}

	// A release banks every finger as one edit.
	test::@check(app.begin_pose(), "the second grab did not begin");
	for (int k = 1; k <= 4; k++) (void)app.pose_toward(app.drag.from + down * (float)k * 0.25f);
	app.end_drag();
	test::@check(app.pose_edit_pending, "the release left nothing pending");
	foreach (usz i, tip : hand.tips)
	{
		test::@check(before[i].y - hand.at(tip).y > 0.01f, "the release dropped fingertip %d", i);
	}
}

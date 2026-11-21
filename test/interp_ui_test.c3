<*
 The interpolation popover, the gait dialog's foot offset fields and the I key,
 through the real tree.

 `c3c test --trust=full --test-filter crig_tests::ui`
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;

fn void interp_open(Fixture* f)
{
	f.click(f.center_of(crig::ANIM_INTERP_ID)!!);
	f.ui.flush();
}

fn void interp_thumb(Fixture* f, usz preset)
{
	f.click(f.center_of(crig::ANIM_INTERP_THUMB_IDS[preset])!!);
	f.ui.flush();
	f.feed({ 0, 0 });
}

fn String interp_label(Fixture* f) => crig::anim_interp_label(crig::anim_interp_state(&f.app));

fn void the_ease_in_thumbnail_sets_the_ease() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(multi_pose_point(&f, 1));
	f.ui.flush();
	interp_open(&f);
	sz history = f.app.undo_stack.cursor;
	interp_thumb(&f, 3);
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.keyframes[1].dots[0].rotation_ease.same({ 1, 0 }), "Ease in did not set { 1, 0 }");
	test::@check(clip.keyframes[0].dots[0].rotation_ease.none(), "an unselected key was eased");
	test::eq(interp_label(&f), "Ease in");
	test::eq(crig::anim_interp_preset(crig::anim_interp_state(&f.app)), (sz)3);

	interp_thumb(&f, 5);
	test::eq(interp_label(&f), "Ease in-out");
	interp_thumb(&f, 0);
	test::eq(interp_label(&f), "Smooth");
	test::@check(f.app.clip(f.app.editing).keyframes[1].dots[0].rotation_ease.none(), "Smooth left an ease behind");
}

fn void the_sliders_set_a_custom_ease() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(multi_pose_point(&f, 1));
	f.ui.flush();
	interp_open(&f);
	crig::anim_interp_ease_in_committed(f.ui, 0.5f);
	f.ui.flush();
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.keyframes[1].dots[0].rotation_ease.same({ 0.5f, 0 }), "the Ease in slider did not set the start");
	test::eq(interp_label(&f), "Custom");
	crig::anim_interp_ease_out_committed(f.ui, 0.25f);
	f.ui.flush();
	clip = f.app.clip(f.app.editing);
	test::@check(clip.keyframes[1].dots[0].rotation_ease.same({ 0.5f, 0.25f }), "the Ease out slider lost the start");
	test::eq(interp_label(&f), "Custom");
	Slider* slider = f.ui.find_id(crig::ANIM_INTERP_EASE_OUT_ID)!!.widget_as(Slider);
	test::@check(math::abs(slider.value - 0.25f) < 1e-4f, "the slider does not show the ease");
}

fn void the_i_key_opens_the_popover_only_with_a_clip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.feed_key(Key.I);
	test::@check(!f.in_tree(crig::ANIM_INTERP_THUMB_IDS[0]), "I opened a popover with no clip");

	multi_pose_workspace(&f);
	f.feed_key(Key.I);
	f.ui.flush();
	test::@check(f.ui.find_id(crig::ANIM_INTERP_POPOVER_ID)!!.widget_as(Dialog).open, "I did not open the popover");
}

fn void the_k_key_keys_the_pose_and_shift_k_flips_auto_key() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.edit_time = 3.0f;
	usz keys = f.app.clip(f.app.editing).keyframes.len;
	f.app.stage = crig::EditStage.JOINTS_STAGE;
	f.feed_key(Key.K);
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys, "K keyed a pose in the Joints stage");
	f.app.stage = crig::EditStage.POSE_STAGE;
	f.feed_key(Key.K);
	test::@check(!f.app.sketching, "K opened the Sketch tool; it has no key now");
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys + 1, "K did not key the pose at the playhead");

	bool auto_key = f.app.auto_key;
	f.feed(f.ui.input.mouse, keys: { Key.LEFT_SHIFT, Key.K });
	f.feed(f.ui.input.mouse);
	test::@check(f.app.auto_key != auto_key, "Shift+K did not flip Auto-key");
}

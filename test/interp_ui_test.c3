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

fn void the_popover_sets_linear_on_the_selected_keys() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(multi_pose_point(&f, 1));
	f.shift_click(multi_pose_point(&f, 2));
	f.ui.flush();
	interp_open(&f);
	test::@check(f.ui.find_id(crig::ANIM_INTERP_POPOVER_ID)!!.widget_as(Dialog).open, "the button did not open the popover");
	foreach (id : crig::ANIM_INTERP_THUMB_IDS) test::@check(f.in_tree(id), "the popover has no %s", id);
	test::@check(f.in_tree(crig::ANIM_INTERP_EASE_IN_ID) && f.in_tree(crig::ANIM_INTERP_EASE_OUT_ID), "the ease sliders are missing");
	test::@check(f.in_tree(crig::ANIM_KEY_TIME_ID) && f.in_tree(crig::ANIM_KEY_SPAN_ID), "Time and Span are missing");

	// Step first, so Linear is a change from something.
	interp_thumb(&f, 2);
	test::eq(interp_label(&f), "Step");
	sz history = f.app.undo_stack.cursor;
	interp_thumb(&f, 1);
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	foreach (frame : clip.keyframes[1:2])
	{
		foreach (dot : frame.dots) test::@check(dot.interpolation(true, clip.blend) == LINEAR, "key 1 is not Linear");
	}
	test::@check(clip.keyframes[2].dots[0].interpolation(true, clip.blend) == LINEAR, "key 2 is not Linear");
	test::eq(interp_label(&f), "Linear");
	test::@check(clip.keyframes[0].dots[0].rotation_interpolation == INHERIT, "an unselected key changed");
	test::@check(f.app.undo(), "Linear did not undo");
}

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

fn void a_mixed_selection_reads_mixed() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(multi_pose_point(&f, 1));
	f.ui.flush();
	crig::anim_interp_apply_preset(f.ui, 2);
	f.click(multi_pose_point(&f, 2));
	f.ui.flush();
	crig::anim_interp_apply_preset(f.ui, 1);
	f.click(multi_pose_point(&f, 1));
	f.shift_click(multi_pose_point(&f, 2));
	f.ui.flush();
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)2);
	test::eq(interp_label(&f), "Mixed");
	test::eq(crig::anim_interp_preset(crig::anim_interp_state(&f.app)), (sz)-1);
	interp_open(&f);
	foreach (id : crig::ANIM_INTERP_THUMB_IDS)
	{
		test::@check(!f.ui.find_id(id)!!.widget_as(InterpThumb).lit, "a preset is lit for a mixed selection");
	}
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
	f.app.stage = crig::EditStage.POSE_STAGE;
	f.app.edit_time = 3.0f;
	usz keys = f.app.clip(f.app.editing).keyframes.len;
	f.feed_key(Key.K);
	test::@check(!f.app.sketching, "K opened the Sketch tool; it has no key now");
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys + 1, "K did not key the pose at the playhead");

	bool auto_key = f.app.auto_key;
	f.feed(f.ui.input.mouse, keys: { Key.LEFT_SHIFT, Key.K });
	f.feed(f.ui.input.mouse);
	test::@check(f.app.auto_key != auto_key, "Shift+K did not flip Auto-key");
}

fn void the_k_key_does_nothing_in_the_joints_stage() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.stage = crig::EditStage.JOINTS_STAGE;
	f.app.edit_time = 3.0f;
	usz keys = f.app.clip(f.app.editing).keyframes.len;
	f.feed_key(Key.K);
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys, "K keyed a pose in the Joints stage");
}

fn void the_key_menu_has_one_interpolation_item() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.select_animation_key(f.app.editing, 2.0f);
	crig::anim_key_context(f.ui, { .at = 2.0f }, { 200, 200 });
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_CONTEXT_INTERP_ID), "the key menu has no Interpolation item");
	foreach (id : (String[]) { "anim-context-auto", "anim-context-linear", "anim-context-hold",
		"anim-context-ease-in", "anim-context-ease-out", "anim-context-no-ease" })
	{
		test::@check(!f.in_tree(id), "the key menu still has the flat %s", id);
	}
	f.click(f.center_of(crig::ANIM_CONTEXT_INTERP_ID)!!);
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_INTERP_THUMB_IDS[0]), "the item did not open the popover");
}

// ---- the gait dialog's foot offsets ----------------------------------------

fn void the_gait_offsets_default_to_the_gait_and_reach_the_clip() @test
{
	rig::TriMesh mesh = rig::load_gltf(mem, GAIT_DOG)!!;
	defer mesh.free(mem);
	Fixture f;
	gait_dog(&f, mesh);
	defer f.close();

	gait_open(&f);
	for (usz i = 0; i < 4; i++)
	{
		test::@check(f.in_tree(crig::gait_offset_ids[i]), "no offset field for foot %d", i);
		String shown = f.ui.find_id(crig::gait_offset_ids[i])!!.widget_as(TextField).value();
		test::eq(shown, crig::gait_offset_text(crig::gait_draft.rows[i].offset));
	}
	test::@check(!f.in_tree(crig::gait_offset_ids[4]), "a fifth field for a four-foot rig");

	// Untouched fields leave the named gait alone.
	gait_create(&f);
	test::@check(f.app.clip(f.app.editing) != null, "the untouched gait was not authored");

	gait_open(&f);
	foreach (i, id : crig::gait_offset_ids[:4])
	{
		Element* field = f.ui.find_id(id)!!;
		field.widget_as(TextField).set_text(field, i == 1 ? "0.9" : "0.25");
	}
	gait_create(&f);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip != null && clip.ground.feet.len == 4, "the typed gait was not authored");
	foreach (i, foot : clip.ground.feet)
	{
		float want = i == 1 ? 0.9f : 0.25f;
		test::@check(math::abs(foot.down - want) < 0.001f, "foot %d lands at %f, not the typed %f", i, foot.down, want);
	}

	// A typed phase outside the cycle is refused and authors nothing more.
	gait_open(&f);
	Element* field = f.ui.find_id(crig::gait_offset_ids[0])!!;
	field.widget_as(TextField).set_text(field, "1.5");
	sz clips = f.app.doc.animations.len();
	gait_create(&f);
	test::@check(f.ui.get_widget_id(crig::GAIT_DIALOG_ID, Dialog)!!.open, "a bad offset closed the dialog");
	test::eq(f.app.doc.animations.len(), clips);
}

<*
 The layer strip in the Animations pane (ui/layer_strip.c3) and the app-level
 edits under it (app/layer_edit.c3): adding, muting and choosing layers, the
 generator form, keying a delta into a keyed layer, merge down, and undo.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::layer_ui`
*>
module crig_tests::ui;

import crig;
import rig;
import cui;
import cui::widgets;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

// A biped with a four-second clip keyed at 0, 1 and 2 (all rest), open on the
// Animations pane.
fn AnimRef lyr_workspace(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Layered", 4);
	clip = f.app.key_here(clip, 1);
	f.app.editing = f.app.key_here(clip, 2);
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	return f.app.editing;
}

fn AnimLayer* lyr_layer(Fixture* f, usz at) => &f.app.clip(f.app.editing).layers[at];

fn void lyr_add(Fixture* f, String menu_id)
{
	f.click(f.center_of(crig::ANIM_LAYER_ADD_ID)!!);
	f.ui.flush();
	f.click(f.center_of(menu_id)!!);
	f.ui.flush();
}

// The rotation the clip plays for the root at `time`, stack included.
fn Quaternionf lyr_root_turn(Fixture* f, float time)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = f.app.evaluated_clip_pose(mem, &view, *f.app.clip(f.app.editing), f.app.editing, time, false);
	defer pose.free(mem);
	foreach (usz j, id : view.dot_ids) if (id == f.app.doc.root_id) return pose.rotations[j];
	return quaternion::IDENTITY;
}

fn float lyr_angle_between(Quaternionf a, Quaternionf b)
{
	float d = math::min(1.0f, math::abs(a.v.dot(b.v)));
	return 2.0f * math::acos(d);
}

fn void layer_ui_adds_a_layer_through_the_strip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = lyr_workspace(&f);
	test::@check(f.ui.find_id(crig::ANIM_LAYER_TREE_ID)!! != null, "the pane has no layer list");
	test::eq(f.app.clip(clip).layers.len, (sz)0);
	sz history = f.app.undo_stack.cursor;

	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	AnimTemplate* now = f.app.clip(f.app.editing);
	test::eq(now.layers.len, (sz)1);
	test::@check(now.layers[0].kind == WAVE && now.layers[0].mode == ADDITIVE, "the menu did not add a wave");
	test::@check(now.layers[0].joint.len > 0, "a new wave has no joint to drive");
	test::@check(math::abs(now.layers[0].amplitude - 15.0f * (float)math::PI / 180.0f) < 1.0e-4f
		&& now.layers[0].cycles == 2.0f && now.layers[0].axis.y == 1.0f, "a new wave lacks its defaults");
	test::eq(f.app.active_layer_of(f.app.editing), (sz)0);
	test::eq(f.app.undo_stack.cursor, history + 1);

	lyr_add(&f, crig::ANIM_LAYER_KEYED_ID);
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)2);
	test::@check(lyr_layer(&f, 1).kind == KEYED && lyr_layer(&f, 1).keyframes.len == 1, "a keyed layer starts empty");
	test::eq(f.app.active_layer_of(f.app.editing), (sz)1);

	test::@check(f.app.undo(), "undo failed");
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)1);
	test::@check(f.app.undo(), "second undo failed");
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)0);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
}

fn void layer_ui_mute_and_solo_toggle_from_the_row() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	lyr_add(&f, crig::ANIM_LAYER_NOISE_ID);
	sz history = f.app.undo_stack.cursor;

	// Row 0 is the top of the stack: the noise layer, index 1.
	crig::anim_layer_row_toggled(f.ui, 0, 0);
	test::@check(lyr_layer(&f, 1).mute && !lyr_layer(&f, 0).mute, "the eye did not mute the top layer");
	test::eq(f.app.undo_stack.cursor, history + 1);
	crig::anim_layer_row_toggled(f.ui, 1, 1);
	test::@check(lyr_layer(&f, 0).solo, "the solo switch did not solo the lower layer");
	test::@check(!lyr_layer(&f, 1).plays(f.app.clip(f.app.editing).layers, true), "a solo left the other layer playing");
	crig::anim_layer_row_toggled(f.ui, 0, 0);
	test::@check(!lyr_layer(&f, 1).mute, "the eye did not unmute");
	test::@check(f.app.undo() && lyr_layer(&f, 1).mute && lyr_layer(&f, 0).solo, "undo did not step back one toggle");
}

fn void layer_ui_choosing_a_row_changes_the_active_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	lyr_add(&f, crig::ANIM_LAYER_PULSE_ID);
	test::eq(f.app.active_layer_of(clip), (sz)1);
	sz history = f.app.undo_stack.cursor;

	crig::anim_layer_row_chosen(f.ui, 1);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)0);
	crig::anim_layer_row_chosen(f.ui, 2);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
	crig::anim_layer_row_chosen(f.ui, 0);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)1);
	test::eq(f.app.undo_stack.cursor, history);

	// A stack that shrinks under the active layer falls back to the base.
	test::@check(f.app.undo(), "undo failed");
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)1);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);

	// Another clip starts on its base, and coming back does not resurrect the choice.
	f.app.set_active_layer(f.app.editing, 0);
	AnimRef first = f.app.editing;
	f.app.editing = f.app.new_clip("Other", 2);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
	f.app.editing = first;
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
}

fn void layer_ui_the_generator_form_edits_the_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	test::@check(f.ui.find_id(crig::ANIM_LAYER_AMPLITUDE_ID)!! != null, "no amplitude slider for a wave");
	test::@check(f.ui.find_id(crig::ANIM_LAYER_JOINT_ID)!! != null, "no joint chooser for a wave");
	sz history = f.app.undo_stack.cursor;

	crig::anim_layer_amplitude_committed(f.ui, 30.0f);
	test::@check(math::abs(lyr_layer(&f, 0).amplitude - 30.0f * (float)math::PI / 180.0f) < 1.0e-5f, "amplitude is stored in radians");
	crig::anim_layer_cycles_committed(f.ui, 3.0f);
	test::eq(lyr_layer(&f, 0).cycles, 3.0f);
	crig::anim_layer_axis_chosen(f.ui, 2);
	test::@check(lyr_layer(&f, 0).axis.z == 1.0f && lyr_layer(&f, 0).axis.y == 0.0f, "the axis did not move to Z");
	crig::anim_layer_weight_committed(f.ui, 0.5f);
	test::eq(lyr_layer(&f, 0).weight, 0.5f);
	crig::anim_layer_mode_chosen(f.ui, 1);
	test::@check(lyr_layer(&f, 0).mode == OVERRIDE, "the mode did not change");
	crig::anim_layer_named(f.ui, "Tail swish");
	test::@check(lyr_layer(&f, 0).name == "Tail swish", "the layer was not renamed");
	crig::anim_layer_joint_chosen(f.ui, 1);
	test::@check(lyr_layer(&f, 0).joint.len > 0, "the joint chooser lost the joint");
	test::eq(f.app.undo_stack.cursor, history + 7);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).layers[0].name == "Tail swish", "undo took back more than the last edit");
}

fn void layer_ui_mask_from_the_selection() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	f.app.select(0);
	crig::anim_layer_mask_clicked(f.ui);
	test::eq(lyr_layer(&f, 0).mask.len, (sz)0);
	f.app.select(f.app.doc.root_id);
	crig::anim_layer_mask_clicked(f.ui);
	test::eq(lyr_layer(&f, 0).mask.len, (sz)1);
	crig::anim_layer_mask_clear_clicked(f.ui);
	test::eq(lyr_layer(&f, 0).mask.len, (sz)0);
}

fn void layer_ui_reordering_and_deleting_keep_the_active_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	lyr_add(&f, crig::ANIM_LAYER_NOISE_ID);
	lyr_add(&f, crig::ANIM_LAYER_PULSE_ID);
	f.app.set_active_layer(f.app.editing, 0);
	crig::anim_layer_up_clicked(f.ui);
	test::@check(lyr_layer(&f, 1).kind == WAVE && lyr_layer(&f, 0).kind == NOISE, "Move up did not raise the wave");
	test::eq(f.app.active_layer_of(f.app.editing), (sz)1);
	crig::anim_layer_down_clicked(f.ui);
	test::@check(lyr_layer(&f, 0).kind == WAVE, "Move down did not lower it again");
	test::eq(f.app.active_layer_of(f.app.editing), (sz)0);
	crig::anim_layer_delete_clicked(f.ui);
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)2);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).layers.len == 3, "undo did not bring the layer back");
}

// The pose the root is given in a keyed layer comes back out of the stack, the
// base keys untouched.
fn void layer_ui_keying_into_an_additive_layer_stores_a_delta() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = lyr_workspace(&f);
	sz base_keys = f.app.clip(clip).keyframes.len;
	lyr_add(&f, crig::ANIM_LAYER_KEYED_ID);
	crig::anim_layer_weight_committed(f.ui, 0.5f);

	Quaternionf turn = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, 0.45f);
	f.app.edit_time = 1.0f;
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not open a pose draft");
	test::@check(f.app.set_working_pose(f.app.doc.root_id, turn, {}), "could not pose the root");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying into the layer failed");

	AnimTemplate* keyed = f.app.clip(f.app.editing);
	test::eq(keyed.keyframes.len, base_keys);
	foreach (frame : keyed.keyframes) foreach (dot : frame.dots)
	{
		test::@check(dot.angle < 1.0e-6f, "a base key changed while keying into a layer");
	}
	AnimLayer* layer = &keyed.layers[0];
	test::@check(layer.keyframes.len == 2, "the layer did not gain a key at 1s (%d keys)", (int)layer.keyframes.len);
	// At weight 0.5 the stored turn is twice the wanted one.
	float stored = 0.0f;
	foreach (frame : layer.keyframes) foreach (dot : frame.dots)
	{
		if (math::abs(frame.time - 1.0f) < 1.0e-4f && dot.angle > stored) stored = dot.angle;
	}
	test::@check(math::abs(stored - 0.9f) < 1.0e-3f, "the delta is %f, not twice 0.45", stored);
	test::@check(lyr_angle_between(lyr_root_turn(&f, 1.0f), turn) < 1.0e-3f,
		"the stack does not reproduce the keyed pose");

	test::@check(f.app.undo(), "undo failed");
	test::eq(f.app.clip(f.app.editing).layers[0].keyframes.len, (sz)1);
}

fn void layer_ui_keying_ignores_layers_above_the_active_one() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_KEYED_ID);
	lyr_add(&f, crig::ANIM_LAYER_PULSE_ID);
	// The pulse (above) sits on the root at t = 1 s and leans it; keying into
	// the keyed layer must not bake that lean in.
	crig::anim_layer_at_committed(f.ui, 1.0f);
	crig::anim_layer_joint_chosen(f.ui, 0);
	f.app.set_active_layer(f.app.editing, 0);

	Quaternionf turn = quaternion::from_axis_angle{float}((Vec3){ 0, 0, 1 }, 0.3f);
	f.app.edit_time = 1.0f;
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not open a pose draft");
	Quaternionf seen = f.app.working_pose(f.app.doc.root_id).rotation;
	test::@check(f.app.set_working_pose(f.app.doc.root_id, seen.mul(turn), {}), "could not pose the root");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying into the layer failed");

	float stored = 0.0f;
	foreach (frame : f.app.clip(f.app.editing).layers[0].keyframes) foreach (dot : frame.dots)
	{
		if (math::abs(frame.time - 1.0f) < 1.0e-4f && dot.angle > stored) stored = dot.angle;
	}
	test::@check(math::abs(stored - 0.3f) < 2.0e-3f, "the layer kept the pulse's lean: %f, not 0.3", stored);
}

fn void layer_ui_a_generator_layer_cannot_be_keyed_into() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = lyr_workspace(&f);
	sz keys = f.app.clip(clip).keyframes.len;
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	f.app.edit_time = 1.0f;
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not open a pose draft");
	test::@check(!f.app.key_here(f.app.editing, 1.0f).valid(), "keying with a wave active did something");
	test::eq(f.app.clip(f.app.editing).keyframes.len, keys);
}

fn void layer_ui_timeline_keys_follow_the_active_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_KEYED_ID);
	f.app.edit_time = 1.0f;
	test::@check(f.app.pose_from_clip(f.app.editing, 1.0f), "could not open a pose draft");
	Quaternionf turn = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, 0.4f);
	test::@check(f.app.set_working_pose(f.app.doc.root_id, turn, {}), "could not pose the root");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying failed");
	f.app.discard_pose_edit();
	f.app.show_edited();
	f.feed(f.center_of(crig::ANIM_KEY_ID)!!);
	f.ui.flush();

	// The sheet draws the layer's two keys, not the base's three.
	test::eq(f.app.key_clip(f.app.editing).keyframes.len, (sz)2);
	Timeline* sheet = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(sheet.marks.len == 2, "the sheet draws %d marks, not the layer's two", (int)sheet.marks.len);
	// Selecting and deleting the key at 1 s removes it from the layer only.
	test::@check(f.app.select_animation_key(f.app.editing, 1.0f), "could not select the layer's key");
	test::@check(f.app.delete_selected_animation_keys(f.app.editing), "could not delete the layer's key");
	test::eq(f.app.clip(f.app.editing).layers[0].keyframes.len, (sz)1);
	test::eq(f.app.clip(f.app.editing).keyframes.len, f.app.clip(clip).keyframes.len);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)3);

	// Back on the base, the sheet is the base's.
	f.app.set_active_layer(f.app.editing, -1);
	test::eq(f.app.key_clip(f.app.editing).keyframes.len, (sz)3);
}

fn void layer_ui_merge_down_bakes_the_stack_and_undo_restores_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	crig::anim_layer_cycles_committed(f.ui, 1.0f);
	crig::anim_layer_axis_chosen(f.ui, 1);
	Quaternionf layered = lyr_root_turn(&f, 1.0f);
	test::@check(lyr_angle_between(layered, quaternion::IDENTITY) > 0.05f, "the wave does nothing at 1s");

	sz history = f.app.undo_stack.cursor;
	crig::anim_layer_merge_clicked(f.ui);
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)0);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(lyr_angle_between(lyr_root_turn(&f, 1.0f), layered) < 1.0e-2f, "merging changed the pose");

	test::@check(f.app.undo(), "undo failed");
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)1);
}

fn void layer_ui_keying_into_an_override_layer_stores_the_wanted_pose() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_OVERRIDE_ID);
	test::@check(lyr_layer(&f, 0).mode == OVERRIDE, "the menu did not add an override layer");

	Quaternionf turn = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, 0.6f);
	f.app.edit_time = 2.0f;
	test::@check(f.app.pose_from_clip(f.app.editing, 2.0f), "could not open a pose draft");
	test::@check(f.app.set_working_pose(f.app.doc.root_id, turn, {}), "could not pose the root");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(ALL), "keying into the layer failed");
	test::@check(lyr_angle_between(lyr_root_turn(&f, 2.0f), turn) < 1.0e-3f, "the override does not reproduce the pose");
}

fn void layer_ui_mute_reaches_the_clip_that_is_playing() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	AnimRef clip = lyr_workspace(&f);
	lyr_add(&f, crig::ANIM_LAYER_WAVE_ID);
	test::@check(f.app.park_clip(clip, 1.0f), "could not put the clip up");
	test::@check(f.app.current_anim.layers.len == 1 && !f.app.current_anim.layers[0].mute, "the player lacks the layer");
	crig::anim_layer_row_toggled(f.ui, 0, 0);
	test::@check(f.app.current_anim.layers.len == 1 && f.app.current_anim.layers[0].mute,
		"muting did not reach the playing clip");
}

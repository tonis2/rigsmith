module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

fn float repair_key_time(Fixture* f, usz i) => f.app.clip(f.app.editing).keyframes[i].time;

fn void repair_submit(Fixture* f, String id, String typed, OnSubmit submit)
{
	Element* field = f.ui.find_id(id)!!;
	field.widget_as(TextField).set_text(field, typed);
	submit(f.ui, typed);
	f.ui.flush();
	f.feed({ 0, 0 });
}

// Typing into Key moves the selected keys and keeps their spacing; typing into
// Span stretches only them from the first. One undo step each.
fn void the_key_fields_move_and_stretch_the_selection() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.click(multi_pose_point(&f, 1));
	f.shift_click(multi_pose_point(&f, 2));
	f.feed({ 0, 0 });
	// The key fields sit in the interpolation popover.
	test::@check(crig::anim_interp_open_at_button(f.ui), "the popover would not open");
	f.ui.flush();
	test::eq(f.ui.find_id(crig::ANIM_KEY_TIME_ID)!!.widget_as(TextField).value(), "1.00 s");
	test::eq(f.ui.find_id(crig::ANIM_KEY_SPAN_ID)!!.widget_as(TextField).value(), "1.00 s");

	sz history = f.app.undo_stack.cursor;
	repair_submit(&f, crig::ANIM_KEY_TIME_ID, "1.5 s", &crig::anim_key_time_submitted);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(math::abs(repair_key_time(&f, 1) - 1.5f) < 1e-4f && math::abs(repair_key_time(&f, 2) - 2.5f) < 1e-4f,
		"the keys did not move together (%s, %s)", repair_key_time(&f, 1), repair_key_time(&f, 2));
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)2);
	test::eq(f.ui.find_id(crig::ANIM_KEY_TIME_ID)!!.widget_as(TextField).value(), "1.50 s");

	history = f.app.undo_stack.cursor;
	repair_submit(&f, crig::ANIM_KEY_SPAN_ID, "60", &crig::anim_key_span_submitted);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(math::abs(repair_key_time(&f, 0)) < 1e-4f, "an unselected key moved");
	test::@check(math::abs(repair_key_time(&f, 1) - 1.5f) < 1e-4f && math::abs(repair_key_time(&f, 2) - 3.5f) < 1e-4f,
		"the span did not stretch from the first key (%s, %s)", repair_key_time(&f, 1), repair_key_time(&f, 2));
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)2);

	// Past the clip's end is refused and changes nothing.
	history = f.app.undo_stack.cursor;
	repair_submit(&f, crig::ANIM_KEY_SPAN_ID, "9 s", &crig::anim_key_span_submitted);
	test::eq(f.app.undo_stack.cursor, history);

	test::@check(f.app.undo(), "the stretch did not undo");
	test::@check(math::abs(repair_key_time(&f, 2) - 2.5f) < 1e-4f, "undo did not bring the span back");
	test::@check(f.app.undo(), "the move did not undo");
	test::@check(math::abs(repair_key_time(&f, 1) - 1.0f) < 1e-4f, "undo did not bring the keys back");
}

// A channel selection stretches only its own keys; the rest of the pose stays.
fn void stretching_channel_keys_leaves_the_other_joints() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	String joint = clip.keyframes[1].dots[0].joint_name.copy(mem);
	defer joint.free(mem);
	AnimChannels channel = clip.keyframes[1].dots[0].keys_rotation() ? AnimChannels.ROTATION : AnimChannels.TRANSLATION;
	test::@check(f.app.select_animation_channel_key(f.app.editing, 1, joint, channel), "could not select a channel key");
	test::@check(f.app.select_animation_channel_key(f.app.editing, 2, joint, channel, additive: true), "could not add a channel key");
	sz frames = clip.keyframes.len;
	test::@check(f.app.scale_selected_animation_keys(f.app.editing, 2), "the channel keys would not stretch");
	clip = f.app.clip(f.app.editing);
	test::eq(clip.keyframes.len, frames + 1);
	test::@check(math::abs(clip.keyframes[frames].time - 3) < 1e-4f, "the stretched key is not at 3 s");
	test::eq(clip.keyframes[frames].dots.len, (sz)1);
	test::eq(clip.keyframes[frames].dots[0].joint_name, joint);
}

// A clip whose hips sway while the feet rest on the floor: its feet slide.
fn AnimTemplate swaying_clip(float sway)
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 3);
	foreach (usz i, &frame : frames)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = "hips".copy(mem), .channels = TRANSLATION,
			.move = { i == 1 ? sway : 0, 0, 0 } };
		*frame = { .time = (float)i * 0.5f, .dots = dots };
	}
	return { .name = "Sway".copy(mem), .duration = 1.0f, .loop = true, .keyframes = frames, .owned = true };
}

fn float worst_slide(Fixture* f)
{
	float worst = 0;
	foreach (issue : f.app.anim_check.issues) if (issue.kind == FOOT_SLIDE) worst = math::max(worst, issue.magnitude);
	return worst;
}

// Check reads the feet off a clip that declares none, marks their slide on the
// ruler, and Plant feet takes most of it away in one undo step.
fn void check_marks_sliding_feet_and_plant_feet_holds_them() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	test::@check(f.app.has_dot_named("hips"), "the biped has no hips");
	f.app.editing = f.app.author_clip(swaying_clip(0.06f));
	test::@check(f.app.editing.valid(), "the swaying clip did not land");
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_CHECK_ID);
	f.feed({ 0, 0 });
	float before = worst_slide(&f);
	test::@check(before > crig::ISSUE_SLIDE_TOLERANCE, "Check did not report the sliding feet (%s)", before);
	test::@check(f.in_tree(crig::ANIM_CHECK_LIST_ID), "the issues are not listed");
	Timeline* sheet = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::eq(sheet.flags.len, f.app.anim_check.issues.len);

	// A row puts the playhead on its issue.
	crig::anim_check_go(f.ui, 0);
	test::@check(math::abs(f.app.edit_time - f.app.anim_check.issues[0].time) < 1e-4f, "the row did not go to its issue");

	sz history = f.app.undo_stack.cursor;
	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_PLANT_FEET_ID);
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	float after = worst_slide(&f);
	test::@check(after < before * 0.6f, "Plant feet did not hold the feet (%s -> %s)", before, after);

	test::@check(f.app.undo(), "Plant feet did not undo");
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)3);
}

// Fix mapping, from the ⋯ menu: a library clip's joint sent to (none) stops
// playing and is reported; Reset to automatic brings it back. One undo each.
fn void fix_mapping_matches_a_library_joint_by_hand() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef ref = crig::NO_ANIM;
	foreach (usz p, &pack : f.app.packs)
	{
		foreach (usz c, clip : pack.clips)
		{
			AnimRef candidate = { (int)p, (int)c };
			if (f.app.clip_mappable(candidate) && f.app.clip_applies(candidate)) { ref = candidate; break; }
		}
		if (ref.valid()) break;
	}
	if (!ref.valid())
	{
		test::@check(false, "SKIPPED — the library offers no clip for the biped");
		return;
	}
	test::@check(f.app.bind_ref_recorded(ref), "the clip did not bind");
	f.app.editing = ref;
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	test::eq(f.app.unmatched_joints(ref), (usz)0);
	test::@check(!f.in_tree(crig::ANIM_FIX_MAPPING_INLINE_ID), "a clip that matches offers a fix");

	f.click(f.center_of(crig::ANIM_MORE_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_FIX_MAPPING_ID)!!);
	f.ui.flush();
	test::@check(f.ui.find_id(crig::ANIM_MAPPING_DIALOG_ID)!!.widget_as(Dialog).open, "Fix mapping did not open");
	test::@check(f.app.mapping_draft.rows.len > 0, "the dialog lists no joints");
	test::@check(f.app.mapping_draft.rows[0].chosen > 0, "a matched joint is not pre-filled");
	String source = f.app.mapping_draft.rows[0].source.copy(mem);
	defer source.free(mem);

	Element* pick = f.ui.find(crig::AnimMappingPick)!!;
	pick.children[0].widget_as(Select).selected = 0;
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_MAPPING_APPLY_ID)!!);
	f.ui.flush();
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(f.app.doc.joint_maps.len, (sz)1);
	test::eq(f.app.doc.joint_maps[0].source, source);
	test::@check(!f.app.pack_reach((usz)ref.pack).answers(source), "the joint sent to (none) still plays");
	test::eq(f.app.unmatched_joints(ref), (usz)1);
	test::@check(f.in_tree(crig::ANIM_FIX_MAPPING_INLINE_ID), "the unmatched joint is not reported");

	f.click(f.center_of(crig::ANIM_FIX_MAPPING_INLINE_ID)!!);
	f.ui.flush();
	test::@check(f.app.mapping_draft.rows.len == 1 && f.app.mapping_draft.rows[0].source == source,
		"the dialog does not list the unmatched joint");
	f.click(f.center_of(crig::ANIM_MAPPING_RESET_ID)!!);
	f.ui.flush();
	test::eq(f.app.doc.joint_maps.len, (sz)0);
	test::eq(f.app.unmatched_joints(ref), (usz)0);

	test::@check(f.app.undo(), "the reset did not undo");
	test::eq(f.app.doc.joint_maps.len, (sz)1);
	test::@check(f.app.undo(), "the mapping did not undo");
	test::eq(f.app.doc.joint_maps.len, (sz)0);
	test::@check(f.app.pack_reach((usz)ref.pack).answers(source), "undo did not bring the joint back");
}

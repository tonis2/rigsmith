module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

fn Vec2 channel_ui_point(Fixture* f, usz lane, float time)
{
	Element* sheet = f.ui.find(Timeline)!!;
	Timeline* timeline = sheet.widget_as(Timeline);
	return sheet.absolute + (Vec2){ timeline.x_of(sheet, time), timeline.lane_y(lane) };
}

fn void animation_key_context_deletes_pose_or_only_clicked_channel() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.right_click(multi_pose_point(&f, 1));
	test::@check(f.in_tree("anim-context-delete"), "key menu did not open");
	Dialog* popup = f.ui.find_id("anim-key-context")!!.widget_as(Dialog);
	test::@check(popup.popup, "key menu retained dialog chrome");
	test::@check(!f.in_tree(widgets::DIALOG_CLOSE_ID), "key menu retained a close button");
	f.click(f.center_of("anim-context-delete")!!);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)2);
	test::@check(f.app.undo(), "context delete did not undo");
	f.feed(VIEWPORT_CENTER);
	f.click(f.center_of("anim-show-tracks")!!);
	String joint = f.ui.find(Timeline)!!.widget_as(Timeline).lanes[0].label.copy(mem);
	defer joint.free(mem);
	f.right_click(channel_ui_point(&f, 0, 1));
	f.click(f.center_of("anim-context-delete")!!);
	AnimKeyframe key = f.app.clip(f.app.editing).keyframes[1];
	test::@check(!key.has_channel(joint, ROTATION) && key.has_channel(joint, TRANSLATION),
		"context deletion changed a sibling channel");
}

fn void animation_key_context_copies_and_pastes_keys() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	sz history = f.app.undo_stack.cursor;

	// Empty clipboard: the sheet's menu says so rather than hiding the verb.
	Element* sheet = f.ui.find(Timeline)!!;
	Vec2 space = sheet.absolute + (Vec2){ sheet.widget_as(Timeline).x_of(sheet, 3), sheet.widget_as(Timeline).lane_y(0) };
	f.right_click(space);
	test::@check(f.in_tree(crig::ANIM_CONTEXT_PASTE_ID), "empty sheet opened no menu");
	test::@check(!f.in_tree(crig::ANIM_CONTEXT_COPY_ID) && !f.in_tree("anim-context-delete"),
		"empty sheet offered key verbs with no key under the press");
	PopupMenuItem* paste = f.ui.find_id(crig::ANIM_CONTEXT_PASTE_ID)!!.widget_as(PopupMenuItem);
	test::@check(paste.item.disabled && paste.item.label == "Nothing copied yet",
		"paste was offered with nothing copied");
	test::@check(math::abs(f.app.edit_time - 3.0f) < 0.001f, "the right press did not move the playhead");
	f.click(VIEWPORT_CENTER);
	test::@check(!f.in_tree(crig::ANIM_CONTEXT_PASTE_ID), "outside click did not dismiss the menu");

	// On a key: copy is the first item and takes that key.
	f.right_click(multi_pose_point(&f, 1));
	test::@check(f.in_tree(crig::ANIM_CONTEXT_COPY_ID) && f.in_tree("anim-context-delete"),
		"key menu lost its verbs");
	test::eq(f.ui.find_id(crig::ANIM_CONTEXT_COPY_ID)!!.widget_as(PopupMenuItem).item.label, "Copy key");
	f.click(f.center_of(crig::ANIM_CONTEXT_COPY_ID)!!);
	test::@check(!f.in_tree(crig::ANIM_CONTEXT_COPY_ID), "copy left the menu open");
	test::eq(f.app.anim_key_clipboard.keyframes.len, (sz)1);
	test::eq(f.app.undo_stack.cursor, history);

	// Empty sheet again: paste lands where the press was, and is one undo.
	f.right_click(space);
	paste = f.ui.find_id(crig::ANIM_CONTEXT_PASTE_ID)!!.widget_as(PopupMenuItem);
	test::@check(!paste.item.disabled && paste.item.label == "Paste copied keys here",
		"paste stayed disabled with a key copied");
	f.click(f.center_of(crig::ANIM_CONTEXT_PASTE_ID)!!);
	test::@check(!f.in_tree(crig::ANIM_CONTEXT_PASTE_ID), "paste left the menu open");
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)4);
	test::@check(math::abs(f.app.clip(f.app.editing).keyframes[3].time - 3.0f) < 0.001f,
		"the key did not land at the pressed time");
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(math::abs(f.app.edit_time - 3.0f) < 0.001f, "the playhead left the pasted key");

	// A group: the label counts it, and the copy takes both.
	f.click(multi_pose_point(&f, 1));
	f.shift_click(multi_pose_point(&f, 2));
	f.right_click(multi_pose_point(&f, 1));
	test::eq(f.ui.find_id(crig::ANIM_CONTEXT_COPY_ID)!!.widget_as(PopupMenuItem).item.label, "Copy selected keys");
	f.click(f.center_of(crig::ANIM_CONTEXT_COPY_ID)!!);
	test::eq(f.app.anim_key_clipboard.keyframes.len, (sz)2);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes.len == 3, "the paste did not undo");
}

fn void animation_key_context_preserves_group_and_dismisses_without_deleting() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.click(multi_pose_point(&f, 1));
	f.shift_click(multi_pose_point(&f, 2));
	sz history = f.app.undo_stack.cursor;
	f.right_click(multi_pose_point(&f, 1));
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)2);
	f.click(VIEWPORT_CENTER);
	test::@check(!f.in_tree("anim-context-delete"), "outside click did not dismiss menu");
	test::eq(f.app.undo_stack.cursor, history);
	f.right_click(multi_pose_point(&f, 1));
	f.click(f.center_of("anim-context-delete")!!);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)1);
	test::@check(f.app.undo(), "group deletion did not undo");
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)3);
	test::eq(f.app.undo_stack.cursor, history);
}

fn void animation_key_context_sets_outgoing_pose_or_channel_interpolation() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	sz history = f.app.undo_stack.cursor;

	// The fixture is a legacy/default linear clip, and the popup reports the
	// resolved behavior rather than an internal "inherit" format value.
	f.right_click(multi_pose_point(&f, 1));
	f.click(f.center_of(crig::ANIM_CONTEXT_INTERP_ID)!!);
	f.ui.flush();
	test::eq(crig::anim_interp_label(crig::anim_interp_state(&f.app)), "Linear");
	f.click(f.center_of(crig::ANIM_INTERP_THUMB_IDS[2])!!);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	foreach (dot : clip.keyframes[1].dots)
	{
		if (dot.keys_rotation()) test::eq(dot.rotation_interpolation, AnimInterpolation.HOLD);
		if (dot.keys_translation()) test::eq(dot.translation_interpolation, AnimInterpolation.HOLD);
	}
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.undo(), "pose interpolation did not undo");
	test::eq(f.app.undo_stack.cursor, history);

	// Expanded tracks scope the same operation to the clicked channel.
	f.feed(VIEWPORT_CENTER);
	f.click(f.center_of("anim-show-tracks")!!);
	String joint = f.ui.find(Timeline)!!.widget_as(Timeline).lanes[0].label.copy(mem);
	defer joint.free(mem);
	f.right_click(channel_ui_point(&f, 0, 1));
	f.click(f.center_of(crig::ANIM_CONTEXT_INTERP_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_INTERP_THUMB_IDS[0])!!);
	clip = f.app.clip(f.app.editing);
	foreach (dot : clip.keyframes[1].dots) if (dot.joint_name == joint)
	{
		test::eq(dot.rotation_interpolation, AnimInterpolation.AUTO);
		test::eq(dot.translation_interpolation, AnimInterpolation.INHERIT);
	}
	test::eq(f.app.undo_stack.cursor, history + 1);
}

fn void animation_delete_removes_clip_and_binding_and_releases_name() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	sz history = f.app.undo_stack.cursor;
	// The animation view no longer deletes project clips — that moved out with the
	// "Delete animation..." dialog. Exercise the surviving engine directly, the way
	// MCP `tool_delete_clip` does.
	test::@check(f.app.delete_authored_clip("Multiple poses"), "delete_authored_clip refused");
	f.app.undo_stack.commit();
	test::@check(!f.app.clip_named_in_authored("Multiple poses").valid(), "clip survived deletion");
	test::eq(f.app.doc.bound_index("", "Multiple poses"), (sz)-1);
	test::@check(f.app.undo_stack.cursor > history, "deletion was not recorded");
	test::@check(f.app.undo(), "deletion did not undo");
	test::eq(f.app.undo_stack.cursor, history);
	test::@check(f.app.clip_named_in_authored("Multiple poses").valid(), "undo lost clip");
	test::@check(f.app.doc.bound_index("", "Multiple poses") >= 0, "undo lost binding");
	test::@check(f.app.redo(), "deletion did not redo");
	AnimRef fresh = f.app.new_clip("Multiple poses", 1);
	test::eq(f.app.clip(fresh).name, "Multiple poses");
}

fn void animation_unbind_keeps_the_authored_clip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	// Un-bind takes the clip off the character but leaves the project copy: the
	// authored pack still holds it, so it can be re-bound or deleted deliberately.
	f.click(f.center_of("anim-more")!!);
	f.click(f.center_of(crig::ANIM_UNBIND_ID)!!);
	test::@check(f.app.clip_named_in_authored("Multiple poses").valid(), "un-bind lost the authored clip");
	test::eq(f.app.doc.bound_index("", "Multiple poses"), (sz)-1);
}

fn void animation_save_pose_button_records_draft_and_refreshes_player() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.auto_key = false;
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	f.app.select(view.dot_ids[1]);
	Element* sheet = f.ui.find(Timeline)!!;
	f.click(sheet.absolute + (Vec2){ sheet.widget_as(Timeline).x_of(sheet, 3), 5 });
	test::@check(f.app.begin_turn(), "could not begin posing");
	f.app.turn_joint({ 0, 0, 1 }, 0.7f);
	f.app.end_drag();
	f.feed(VIEWPORT_CENTER);
	test::@check(f.app.pose_edit_pending, "gesture did not retain a draft");
	f.click(f.center_of(crig::ANIM_KEY_ID)!!);
	test::@check(!f.app.pose_edit_pending, "Save pose did not save the draft");
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)4);
	test::eq(f.ui.find(Timeline)!!.widget_as(Timeline).marks.len, (sz)4);
	test::eq(f.app.current_anim.keyframes.len, (sz)4);
}

fn void animation_channels_ui_keeps_simple_default_and_moves_only_rotation() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	Timeline* timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::eq(timeline.lanes.len, (sz)1);
	test::eq(timeline.lanes[0].label, "Poses");
	test::@check(!f.in_tree("anim-selected-joints-only"), "advanced filter leaked into simple pose view");
	f.click(f.center_of("anim-show-tracks")!!);
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(timeline.lanes.len >= 2, "Show tracks did not expand channels");
	test::eq(timeline.lanes[0].trailing, "Rotation");
	test::eq(timeline.lanes[1].trailing, "Position");
	String joint = timeline.lanes[0].label.copy(mem);
	defer joint.free(mem);
	sz history = f.app.undo_stack.cursor;
	Vec2 from = channel_ui_point(&f, 0, 1);
	f.click(from);
	test::eq(multi_selected_marks(&f), (usz)1);
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 1, joint, ROTATION),
		"rotation marker did not select its channel");
	Vec2 to = channel_ui_point(&f, 0, 1.5f);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	f.feed(to);
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	sz old = f.app.key_near(f.app.editing, 1, crig::ANIM_SAME_TIME);
	sz moved = f.app.key_near(f.app.editing, 1.5f, crig::ANIM_SAME_TIME);
	test::@check(old >= 0 && moved >= 0, "channel move removed the sibling pose or failed to insert");
	test::@check(clip.keyframes[old].has_channel(joint, TRANSLATION)
		&& !clip.keyframes[old].has_channel(joint, ROTATION)
		&& clip.keyframes[moved].has_channel(joint, ROTATION),
		"drag changed channels outside the selected rotation");
	f.click(f.center_of("anim-show-tracks")!!);
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::eq(timeline.lanes.len, (sz)1);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)0);
	f.click(multi_pose_point(&f, 1));
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)1);
}

fn void animation_channels_ui_filter_follows_joint_identity_and_clears_hidden_selection() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.click(f.center_of("anim-show-tracks")!!);
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	test::@check(view.dot_ids.len >= 2, "fixture needs two joints");
	f.app.select(view.dot_ids[0]);
	f.feed(VIEWPORT_CENTER);
	f.click(f.center_of("anim-selected-joints-only")!!);
	Timeline* timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::eq(timeline.lanes.len, (sz)2);
	test::eq(timeline.lanes[0].label, view.names[0]);
	f.click(channel_ui_point(&f, 0, 1));
	test::eq(multi_selected_marks(&f), (usz)1);
	// Same selection count, different identity: the filter must still rebuild.
	f.app.select(view.dot_ids[1]);
	f.feed(VIEWPORT_CENTER);
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::eq(timeline.lanes.len, (sz)2);
	test::eq(timeline.lanes[0].label, view.names[1]);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)0);
	f.app.select(0);
	f.feed(VIEWPORT_CENTER);
	timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::eq(timeline.marks.len, (sz)0);
}

fn void animation_channels_ui_range_selects_only_crossed_rows() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.click(f.center_of("anim-show-tracks")!!);
	sz history = f.app.undo_stack.cursor;
	Vec2 from = channel_ui_point(&f, 0, 0.75f);
	Vec2 to = channel_ui_point(&f, 0, 2.25f);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	f.feed(to);
	test::eq(multi_selected_marks(&f), (usz)2);
	Timeline* timeline = f.ui.find(Timeline)!!.widget_as(Timeline);
	foreach (mark : timeline.marks)
	{
		if (mark.selected) test::@check(mark.lane == 0 && mark.channel == ROTATION,
			"range selected keys outside the crossed rotation row");
	}
	to = channel_ui_point(&f, 1, 2.25f);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	f.feed(to);
	test::eq(multi_selected_marks(&f), (usz)4);
	test::eq(f.app.undo_stack.cursor, history);
}

fn void animation_channels_ui_paste_never_leaves_invisible_selection() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.click(f.center_of("anim-show-tracks")!!);
	Vec2 point = channel_ui_point(&f, 0, 1);
	f.click(point);
	f.feed(point, keys: { Key.LEFT_CTRL, Key.C });
	f.feed(point);
	test::@check(f.app.anim_key_clipboard_sparse, "track copy did not keep sparse scope");
	f.click(f.center_of("anim-show-tracks")!!);
	Element* sheet = f.ui.find(Timeline)!!;
	point = sheet.absolute + (Vec2){ sheet.widget_as(Timeline).x_of(sheet, 3), 5 };
	f.click(point);
	f.feed(point, keys: { Key.LEFT_CTRL, Key.V });
	f.feed(point);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)4);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)0);
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)0);
	sz history = f.app.undo_stack.cursor;
	f.feed(point, keys: { Key.DELETE });
	f.feed(point);
	test::eq(f.app.undo_stack.cursor, history);
	// The inverse transition is also safe: copying an entire pose does not
	// silently leave whole-column selection behind the expanded channel sheet.
	f.click(multi_pose_point(&f, 1));
	f.feed(point, keys: { Key.LEFT_CTRL, Key.C });
	f.feed(point);
	f.click(f.center_of("anim-show-tracks")!!);
	sheet = f.ui.find(Timeline)!!;
	point = sheet.absolute + (Vec2){ sheet.widget_as(Timeline).x_of(sheet, 3), 5 };
	f.click(point);
	f.feed(point, keys: { Key.LEFT_CTRL, Key.V });
	f.feed(point);
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)0);
	test::eq(multi_selected_marks(&f), (usz)0);
	f.click(channel_ui_point(&f, 0, 1));
	f.feed(point, keys: { Key.LEFT_CTRL, Key.C });
	f.feed(point);
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	f.app.select(view.dot_ids[1]);
	f.feed(VIEWPORT_CENTER);
	f.click(f.center_of("anim-selected-joints-only")!!);
	sheet = f.ui.find(Timeline)!!;
	point = sheet.absolute + (Vec2){ sheet.widget_as(Timeline).x_of(sheet, 3), 5 };
	f.click(point);
	f.feed(point, keys: { Key.LEFT_CTRL, Key.V });
	f.feed(point);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)0);
	test::eq(multi_selected_marks(&f), (usz)0);
}

module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

fn Vec3 own_in(Fixture* f, sz key, String joint)
	=> crig::effective_rotation_tangent(*f.app.clip(f.app.editing), (usz)key, joint, true);

// The popover's Smooth thumbnail, the way a click on it applies it.
fn void anim_interp_apply_preset_smooth(Fixture* f)
{
	crig::anim_interp_apply_preset(f.ui, crig::INTERP_SMOOTH);
	f.ui.flush();
}

fn Element* curve_plot(Fixture* f) => f.ui.find_id(crig::ANIM_CURVES_ID)!!;

// Where the plot draws a data point, in window pixels.
fn Vec2 curve_pixel(Fixture* f, Vec2 at)
{
	Element* plot = curve_plot(f);
	return plot.absolute + plot.widget_as(CurvePlot).pixel_of(plot, at);
}

// The Z (third) point of the key at `time` on the first joint's curves.
fn usz curve_point(Fixture* f, float time)
{
	CurvePlot* plot = curve_plot(f).widget_as(CurvePlot);
	foreach (usz i, p : plot.points)
	{
		if (math::abs(p.at.x - time) < 1.0e-4f && i % 3 == 2) return i;
	}
	return 0;
}

fn void click_segment(Fixture* f, String id, sz index)
{
	Element* strip = f.ui.find_id(id)!!;
	if (strip.children.len() > 0 && !strip.is_widget(Segmented)) strip = strip.children[0];
	Segmented* segmented = strip.widget_as(Segmented);
	float x = 0;
	while (x < strip.size.x && segmented.index_at(strip, x) != index) x += 1;
	f.click(strip.absolute + (Vec2){ x + 4, strip.size.y * 0.5f });
	f.ui.flush();
}

<*
 Curves mode plots the selected joint's rotation, a key drag up or down sets
 its value as one undo step, an ease preset reaches the selected key, and its
 tangent handles then set the key's slope, freeing it or (with Alt) breaking it.
*>
fn void curves_mode_edits_values_and_easing() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.select(f.app.doc.root_id);
	f.ui.flush();

	click_segment(&f, crig::ANIM_SHEET_MODE_ID, 1);
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(f.app.anim_show_curves && f.in_tree(crig::ANIM_CURVES_ID), "Curves did not replace the sheet");
	test::@check(f.in_tree(crig::ANIM_CURVE_LIST_ID) && !f.in_tree("anim-show-tracks"),
		"the channel list did not appear beside the curves");
	// Rotation and position are drawn together: three curves and nine keys of each.
	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.series.len == 6, "%d curves", plot.series.len);
	test::@check(plot.points.len == 18, "%d points", plot.points.len);
	// The fixture's curves are all flat, so they would lie on one another: only the
	// rotation is kept, which is what this test edits.
	for (int axis = 0; axis < 3; axis++) f.app.set_graph_hidden(f.app.doc.root_id, false, axis, true);
	crig::anim_curves_redraw(f.ui);
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.series.len == 3 && plot.points.len == 9, "%d curves, %d points", plot.series.len, plot.points.len);

	// Press the key at 1 s: it becomes the channel selection.
	usz index = curve_point(&f, 1.0f);
	Vec2 at = curve_pixel(&f, plot.points[index].at);
	f.click(at);
	f.ui.flush();
	f.feed({ 0, 0 });
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)1);

	// Drag it up: one undo step, the key's Z turn changes, its time does not.
	String joint = f.app.anim_channel_key_selection[0].joint.tcopy();
	AnimTemplate* clip = f.app.clip(f.app.editing);
	sz key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	float before = crig::euler_of(clip.keyframes[key].rotation_of(joint), {}).z;
	sz history = f.app.undo_stack.cursor;
	sz base = history;
	at = curve_pixel(&f, curve_plot(&f).widget_as(CurvePlot).points[index].at);
	f.drag(at, at - (Vec2){ 0, 40 });
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	clip = f.app.clip(f.app.editing);
	key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	test::@check(key >= 0, "the dragged key left its time");
	float after = crig::euler_of(clip.keyframes[key].rotation_of(joint), {}).z;
	test::@check(after > before + 0.1f, "the drag did not raise the value (%f -> %f)", before, after);
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 1.0f, joint, ROTATION),
		"the value edit dropped the selection");

	// Ease in-out from the toolbar: one step, on the selected rotation only.
	f.feed({ 0, 0 });
	f.ui.flush();
	history = f.app.undo_stack.cursor;
	crig::anim_interp_apply_preset(f.ui, 5);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	clip = f.app.clip(f.app.editing);
	AnimKeyDot dot;
	test::@check(clip.keyframes[key].channel_dot(joint, true, &dot) && dot.rotation_ease.same({ 1, 1 }),
		"Ease in-out did not reach the selected key");
	test::@check(clip.keyframes[0].dots[0].rotation_ease.none(), "Ease in-out reached an unselected key");
	f.feed({ 0, 0 });
	test::eq(crig::anim_interp_preset(crig::anim_interp_state(&f.app)), (sz)5);

	// The selected key's tangent handles, once its segments are smooth: pull the
	// outgoing Z one up and the key goes Free, its other side following.
	anim_interp_apply_preset_smooth(&f);
	f.feed({ 0, 0 });
	f.ui.flush();
	plot = curve_plot(&f).widget_as(CurvePlot);
	// The segment before the key is the previous key's, still linear: only the outgoing side shows.
	test::@check(plot.handles.len == 3, "a selected key shows %d handles, not one per axis", plot.handles.len);
	if (plot.handles.len != 3) return;
	test::@check(f.app.clip(f.app.editing).keyframes[key].dots[0].rotation_tangents.mode == AUTO, "the key was not Auto");
	Vec3 before_out = crig::effective_rotation_tangent(*f.app.clip(f.app.editing), (usz)key, joint, false);
	Vec2 grip = curve_pixel(&f, plot.handles[2].at);
	history = f.app.undo_stack.cursor;
	f.drag(grip, grip - (Vec2){ 0, 25 });
	f.ui.flush();
	test::@check(f.app.undo_stack.cursor > history, "the handle drag wrote nothing");
	test::eq(f.app.undo_stack.cursor, history + 1);
	clip = f.app.clip(f.app.editing);
	key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	test::@check(clip.keyframes[key].channel_dot(joint, true, &dot) && dot.rotation_tangents.mode == FREE,
		"dragging a handle did not free the key (%s)", dot.rotation_tangents.mode);
	Vec3 after_out = crig::effective_rotation_tangent(*clip, (usz)key, joint, false);
	test::@check((after_out - before_out).length() > 1.0e-3f, "the outgoing rate did not change");
	test::@check(clip.keyframes[key].time == 1.0f, "a handle drag moved the key in time");
	test::@check(f.app.animation_channel_key_selected(f.app.editing, 1.0f, joint, ROTATION), "the handle drag dropped the selection");

	// Alt on the handle breaks the key; the incoming side stays where the Free drag left it.
	Vec3 held_in = own_in(&f, key, joint);
	f.feed({ 0, 0 });
	f.ui.flush();
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.handles.len == 3, "%d handles after the drag", plot.handles.len);
	if (plot.handles.len != 3) return;
	grip = curve_pixel(&f, plot.handles[2].at);
	f.alt_drag(grip, grip + (Vec2){ 0, 20 });
	f.ui.flush();
	clip = f.app.clip(f.app.editing);
	key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	test::@check(clip.keyframes[key].channel_dot(joint, true, &dot) && dot.rotation_tangents.mode == BROKEN,
		"Alt on a handle did not break the key (%s)", dot.rotation_tangents.mode);
	test::@check((dot.rotation_tangents.incoming - held_in).length() < 1.0e-5f, "breaking moved the other side");
	test::@check((dot.rotation_tangents.outgoing - after_out).length() > 1.0e-4f, "the Alt drag did not move the outgoing side");

	while (f.app.undo_stack.cursor > base) test::@check(f.app.undo(), "an edit did not undo");
	clip = f.app.clip(f.app.editing);
	key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	test::@check(math::abs(crig::euler_of(clip.keyframes[key].rotation_of(joint), {}).z - before) < 1.0e-3f
		&& !clip.uses_easing(), "undo did not restore the key");
}

// The one state the panel cannot recover from: a pending banner with no draft
// behind it, which Revert has nothing to discard.
fn bool pending_has_an_edit(Fixture* f)
	=> !f.app.pose_edit_pending || f.app.pose_edit_active || f.app.aim_draft.len > 0;

<*
 Dragging keys, handles and empty space on the curves, with or without a
 posed joint, never leaves a "Pose changed" banner that Revert cannot clear:
 back on Keys the panel still takes edits.
*>
fn void leaving_curves_after_key_drags_leaves_the_panel_usable() @test
{
	bool[2] auto_keys = { true, false };
	KeyReach[3] reaches = { FRAME, SELECTED_KEYS, WHOLE_CLIP };
	foreach (auto_key : auto_keys)
	foreach (reach : reaches)
	{
		Fixture f;
		f.open()!!;
		defer f.close();
		multi_pose_workspace(&f);
		f.app.auto_key = auto_key;
		f.app.key_reach = reach;
		f.app.select(f.app.doc.root_id);
		f.ui.flush();
		click_segment(&f, crig::ANIM_SHEET_MODE_ID, 1);
		f.feed({ 0, 0 });
		f.ui.flush();

		// Vertical, sideways and diagonal drags of the key at 1 s.
		Vec2[3] pulls = { { 0, -40 }, { 60, 0 }, { 40, -30 } };
		foreach (pull : pulls)
		{
			usz index = curve_point(&f, f.app.edit_time > 1.5f ? 2.0f : 1.0f);
			Vec2 at = curve_pixel(&f, curve_plot(&f).widget_as(CurvePlot).points[index].at);
			f.click(at);
			f.ui.flush();
			f.feed({ 0, 0 });
			f.drag(at, at + pull);
			f.ui.flush();
			f.feed({ 0, 0 });
			f.ui.flush();
			test::@check(pending_has_an_edit(&f), "auto-key %s: a drag of %f,%f left a pending pose without a draft",
				auto_key ? "on" : "off", pull.x, pull.y);
		}

		// A handle, then empty plot space scrubbed.
		CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
		if (plot.handles.len > 0)
		{
			Vec2 grip = curve_pixel(&f, plot.handles[0].at);
			f.drag(grip, grip + (Vec2){ 0, 25 });
			f.ui.flush();
			test::@check(pending_has_an_edit(&f), "a handle drag left a pending pose without a draft");
		}
		Element* element = curve_plot(&f);
		Vec2 space = element.absolute + (Vec2){ element.size.x * 0.9f, element.size.y * 0.1f };
		f.drag(space, space - (Vec2){ 30, 0 });
		f.ui.flush();
		test::@check(pending_has_an_edit(&f), "scrubbing the plot left a pending pose without a draft");

		click_segment(&f, crig::ANIM_SHEET_MODE_ID, 0);
		f.feed({ 0, 0 });
		f.ui.flush();
		test::@check(pending_has_an_edit(&f), "leaving Curves left a pending pose without a draft");
		test::@check(!f.in_tree(crig::ANIM_PENDING_BANNER_ID), "the banner stayed up");
		f.app.select_animation_key(f.app.editing, 2.0f);
		test::@check(f.app.animation_key_selected(f.app.editing, 2.0f), "the panel refused a key selection");

		// A posed joint, then a key dragged: the pose is the edit that stays pending.
		test::@check(f.app.pose_from_clip(f.app.editing, f.app.edit_time)
			&& f.app.set_working_pose(f.app.doc.root_id, quaternion::from_euler{float}(0.4f, 0.0f, 0.0f), {}),
			"the root would not turn");
		f.app.pose_edit_pending = true;
		f.ui.flush();
		test::@check(pending_has_an_edit(&f), "posing the joint broke the invariant");
		click_segment(&f, crig::ANIM_SHEET_MODE_ID, 1);
		f.feed({ 0, 0 });
		f.ui.flush();
		foreach (pull : pulls)
		{
			usz index = curve_point(&f, f.app.edit_time > 1.5f ? 2.0f : 1.0f);
			Vec2 at = curve_pixel(&f, curve_plot(&f).widget_as(CurvePlot).points[index].at);
			f.click(at);
			f.ui.flush();
			f.drag(at, at + pull);
			f.ui.flush();
			f.feed({ 0, 0 });
			f.ui.flush();
			test::@check(pending_has_an_edit(&f), "auto-key %s: a drag of %f,%f over a posed joint left a pending pose without a draft",
				auto_key ? "on" : "off", pull.x, pull.y);
		}

		// Whatever is left of the pose, Revert in the banner takes it back.
		crig::anim_pending_discard(f.ui);
		f.ui.flush();
		test::@check(!f.app.pose_edit_pending && !f.in_tree(crig::ANIM_PENDING_BANNER_ID), "Revert did not clear the banner");
	}
}

<*
 The key menu carries the ease presets beside the interpolation, and Keys
 brings the sheet back.
*>
fn void the_key_menu_offers_ease_presets() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);

	f.app.select_animation_key(f.app.editing, 2.0f);
	crig::anim_key_context(f.ui, { .at = 2.0f }, { 200, 200 });
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_CONTEXT_INTERP_ID), "the key menu has no Interpolation item");
	test::@check(!f.in_tree("anim-context-ease-in"), "the flat ease items are still in the key menu");
	f.click(f.center_of(crig::ANIM_CONTEXT_INTERP_ID)!!);
	f.ui.flush();
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_INTERP_THUMB_IDS[4])!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.keyframes[2].dots[0].rotation_ease.same({ 0, 1 })
		&& clip.keyframes[2].dots[0].translation_ease.same({ 0, 1 }), "Ease out did not reach the whole key");

	// The popover is modal; its own route into Curves is checked beside it.
	f.click(f.center_of(crig::ANIM_INTERP_CURVES_ID)!!);
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_CURVES_ID), "Open in Curves did not open the curve editor");
	click_segment(&f, crig::ANIM_SHEET_MODE_ID, 0);
	test::@check(!f.in_tree(crig::ANIM_CURVES_ID) && f.in_tree(crig::ANIM_SHEET_ID), "Keys did not bring the sheet back");
}

<*
 On the Curves sheet the key menu lists the five tangent modes, the current one
 ticked, and the popover has the same choice as a row; each is one undo step.
 The Keys sheet's menu has no tangents.
*>
fn void the_key_menu_and_popover_set_tangent_modes() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	f.app.select_animation_key(f.app.editing, 2.0f);
	crig::anim_key_context(f.ui, { .at = 2.0f }, { 200, 200 });
	f.ui.flush();
	test::@check(!f.in_tree(crig::ANIM_CONTEXT_TANGENT_IDS[0]), "the Keys sheet's menu has tangents");
	crig::set_dialog_open(f.ui, "anim-key-context", false);

	open_curves(&f);
	f.app.select_animation_key(f.app.editing, 2.0f);
	crig::anim_key_context(f.ui, { .at = 2.0f }, { 200, 200 });
	f.ui.flush();
	foreach (id : crig::ANIM_CONTEXT_TANGENT_IDS) test::@check(f.in_tree(id), "the key menu has no %s", id);
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_CONTEXT_TANGENT_IDS[3])!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	sz key = f.app.key_near(f.app.editing, 2.0f, crig::ANIM_SAME_TIME);
	test::@check(clip.keyframes[key].dots[0].rotation_tangents.mode == FREE
		&& clip.keyframes[key].dots[0].translation_tangents.mode == FREE, "Free did not reach the whole key");

	// The menu ticks what the keys are; the popover's row lights the same mode.
	crig::anim_key_context(f.ui, { .at = 2.0f }, { 200, 200 });
	f.ui.flush();
	PopupMenuItem* ticked = f.ui.find_id(crig::ANIM_CONTEXT_TANGENT_IDS[3])!!.widget_as(PopupMenuItem);
	test::@check(ticked.item.checked, "the menu does not tick Free");
	crig::set_dialog_open(f.ui, "anim-key-context", false);
	test::@check(crig::anim_interp_open(f.ui, { 200, 200 }), "the popover did not open");
	f.ui.flush();
	Segmented* row = f.ui.find_id(crig::ANIM_INTERP_TANGENT_ID)!!.widget_as(Segmented);
	test::@check(row.selected == 3, "the popover row reads %d, not Free", row.selected);
	history = f.app.undo_stack.cursor;
	crig::anim_interp_tangent_chosen(f.ui, 1);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.clip(f.app.editing).keyframes[key].dots[0].rotation_tangents.mode == FLAT, "the row did not set Flat");
	row = f.ui.find_id(crig::ANIM_INTERP_TANGENT_ID)!!.widget_as(Segmented);
	test::@check(row.selected == 1, "the row did not follow to Flat");
}

// ---------------------------------------------------------------------------
// The channel list, both channels at once, and framing

// The Curves sheet on the root joint's curves, ready for clicks.
fn void open_curves(Fixture* f)
{
	multi_pose_workspace(f);
	f.app.select(f.app.doc.root_id);
	f.ui.flush();
	click_segment(f, crig::ANIM_SHEET_MODE_ID, 1);
	f.feed({ 0, 0 });
	f.ui.flush();
}

fn CurveChannelList* channel_list(Fixture* f) => f.ui.find_id(crig::ANIM_CURVE_LIST_ID)!!.widget_as(CurveChannelList);

// A row's name, or its eye, in window pixels.
fn Vec2 list_row_pixel(Fixture* f, usz row, bool eye = false)
{
	Element* list = f.ui.find_id(crig::ANIM_CURVE_LIST_ID)!!;
	Element* tree = list.children[0];
	float x = eye ? tree.size.x - 18.0f : 60.0f;
	return tree.absolute + (Vec2){ x, (float)row * crig::OUTLINER_STYLE.row_height + 12.0f };
}

fn void click_key_held(Fixture* f, Vec2 at, Key key)
{
	Key[1] held = { key };
	f.feed(at, keys: held[..]);
	f.feed(at, left: true, keys: held[..]);
	f.feed(at, keys: held[..]);
	f.feed(at);
	f.ui.flush();
}

fn void click_list(Fixture* f, usz row, bool eye = false)
{
	f.click(list_row_pixel(f, row, eye));
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
}

<*
 The list has a row for the joint, its Rotation and Position and their axes.
 The eye hides one curve with its keys; clicking a name solos it, Shift adds
 one, Ctrl toggles one, and "All curves" brings every curve back.
*>
fn void the_channel_list_hides_and_solos_curves() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_curves(&f);

	// All curves, the joint, Rotation, X Y Z, Position, X Y Z.
	test::eq(channel_list(&f).rows.len, (sz)10);
	test::@check(channel_list(&f).rows[1].expandable, "no joint row");
	test::@check(channel_list(&f).rows[2].label == "Rotation" && channel_list(&f).rows[6].label == "Position",
		"the channel rows are %s, %s", channel_list(&f).rows[2].label, channel_list(&f).rows[6].label);
	test::eq(curve_plot(&f).widget_as(CurvePlot).series.len, (sz)6);

	// The eye on Rotation X: its series and its three points are gone.
	click_list(&f, 3, true);
	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(f.app.graph_hidden(f.app.doc.root_id, true, 0), "the eye did not hide rotation X");
	test::eq(plot.series.len, (sz)5);
	test::eq(plot.points.len, (sz)15);
	test::eq(channel_list(&f).rows.len, (sz)10);
	test::@check(!channel_list(&f).rows[3].toggles[0].on && channel_list(&f).rows[4].toggles[0].on,
		"the eyes do not show what is hidden");

	// Its eye again shows it.
	click_list(&f, 3, true);
	test::eq(curve_plot(&f).widget_as(CurvePlot).series.len, (sz)6);

	// Solo Rotation Z: only that curve, and with one kind drawn the axis is real degrees.
	click_list(&f, 5);
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::eq(plot.series.len, (sz)1);
	test::eq(plot.points.len, (sz)3);
	test::@check(plot.y_label_scale == 1.0f && plot.y_label_offset == 0.0f && plot.y_suffix == "°",
		"a lone rotation curve is not in degrees");

	// Shift adds Position X; Ctrl on it takes it away again.
	click_key_held(&f, list_row_pixel(&f, 7), Key.LEFT_SHIFT);
	test::eq(curve_plot(&f).widget_as(CurvePlot).series.len, (sz)2);
	click_key_held(&f, list_row_pixel(&f, 7), Key.LEFT_CTRL);
	test::eq(curve_plot(&f).widget_as(CurvePlot).series.len, (sz)1);

	// A channel row solos its whole group.
	click_list(&f, 6);
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::eq(plot.series.len, (sz)3);
	test::@check(plot.y_suffix == "", "position curves read in degrees");

	// Folding a channel drops its axis rows but not its curves.
	f.app.toggle_graph_fold(f.app.doc.root_id, 2);
	crig::anim_curves_redraw(f.ui);
	f.ui.flush();
	test::eq(channel_list(&f).rows.len, (sz)7);
	test::eq(curve_plot(&f).widget_as(CurvePlot).series.len, (sz)3);
	f.app.toggle_graph_fold(f.app.doc.root_id, 2);

	click_list(&f, 0);
	test::eq(curve_plot(&f).widget_as(CurvePlot).series.len, (sz)6);
	test::@check(f.app.anim_graph_hidden.len() == 0, "All curves left curves hidden");
}

<*
 With rotation and position drawn together each is held to -1..1 and the axis
 reads the hovered or primary curve's units; a key drag still writes the real
 value, in degrees for a turn and in rig units for a move.
*>
fn void normalised_curves_still_write_real_values() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_curves(&f);

	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.series.len == 6 && plot.y_label_scale > 0.0f && plot.y_label_scale != 1.0f,
		"two kinds are not normalised (scale %f)", plot.y_label_scale);
	foreach (line : plot.series)
	{
		foreach (p : line.points) test::@check(math::abs(p.y) <= 1.0001f, "a curve leaves -1..1 at %f", p.y);
	}

	// The fixture's curves are flat and would lie on one another: lift the root's
	// rotation Z at 1 s and sink its position Y there, so each has a key of its own.
	for (int pass = 0; pass < 2; pass++)
	{
		bool rotation = pass == 0;
		Graph graph = f.app.build_graph(f.app.editing);
		defer graph.free();
		foreach (key : graph.keys)
		{
			GraphCurve curve = graph.curves[key.curve];
			if (curve.rotation != rotation || curve.axis != (rotation ? 2 : 1) || math::abs(key.time - 1.0f) > 1.0e-4f) continue;
			test::@check(f.app.set_graph_key_value(f.app.editing, curve.joint, rotation, 1.0f, key.shown, curve.axis,
				rotation ? 30.0f : -0.3f * graph.unit, graph.unit), "the setup edit was refused");
		}
	}
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();

	// The most varied rotation and position curve each, and their keys at 1 s.
	usz hover_key = ~(usz)0;
	for (int pass = 0; pass < 2; pass++)
	{
		bool rotation = pass == 0;
		Graph graph = f.app.build_graph(f.app.editing);
		usz best = ~(usz)0;
		foreach (usz i, curve : graph.curves)
		{
			if (curve.rotation == rotation && (best == ~(usz)0 || curve.half > graph.curves[best].half)) best = i;
		}
		test::@check(best != ~(usz)0, "no curve of that kind");
		GraphCurve curve = graph.curves[best];
		usz index = ~(usz)0;
		foreach (usz i, key : graph.keys) if (key.curve == best && math::abs(key.time - 1.0f) < 1.0e-4f) index = i;
		GraphKey key = graph.keys[index];
		if (!rotation) hover_key = index;
		String joint = curve.joint.tcopy();
		float unit = graph.unit;
		graph.free();

		plot = curve_plot(&f).widget_as(CurvePlot);
		Vec2 from = curve_pixel(&f, plot.points[index].at);
		Vec2 to = from - (Vec2){ 0, 30 };
		Element* element = curve_plot(&f);
		float moved = plot.data_of(element, to - element.absolute).y - plot.data_of(element, from - element.absolute).y;
		f.click(from);
		f.ui.flush();
		f.feed({ 0, 0 });
		sz history = f.app.undo_stack.cursor;
		f.drag(from, to);
		f.ui.flush();
		test::eq(f.app.undo_stack.cursor, history + 1);

		sz at = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
		AnimTemplate* clip = f.app.clip(f.app.editing);
		float want = key.value + moved * curve.half;
		float got = rotation ? crig::euler_of(clip.keyframes[at].rotation_of(joint), {})[curve.axis]
			: clip.keyframes[at].offset_of(joint)[curve.axis] * unit;
		float within = rotation ? 0.02f : 1.0e-5f * unit + 1.0e-4f * math::abs(want);
		test::@check(math::abs(got - want) <= within, "%s: the drag wrote %f, not %f",
			rotation ? "rotation" : "position", got, want);
		f.feed({ 0, 0 });
		f.ui.flush();
	}

	// Hovering a curve's key puts that curve's units on the axis.
	plot = curve_plot(&f).widget_as(CurvePlot);
	float primary_scale = plot.y_label_scale;
	f.feed(curve_pixel(&f, plot.points[hover_key].at));
	f.ui.flush();
	test::@check(plot.lit == (int)hover_key + 1 && plot.y_suffix == "" && plot.y_label_scale != primary_scale,
		"hovering a position key left the axis in degrees (%s, %f)", plot.y_suffix, plot.y_label_scale);
}

<*
 F frames the selected keys in time and value, A frames every shown curve.
*>
fn void f_and_a_frame_the_curves() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_curves(&f);

	Element* element = curve_plot(&f);
	CurvePlot* plot = element.widget_as(CurvePlot);
	test::@check(plot.zoom <= 1.0f, "the plot starts zoomed");

	// The keys at 1 and 2 s of a 4 s clip.
	f.app.select_animation_key(f.app.editing, 1.0f);
	f.app.select_time(2.0f);
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	element = curve_plot(&f);
	f.click(element.absolute + (Vec2){ element.size.x * 0.95f, 8.0f }); // focus the plot
	f.ui.flush();
	f.feed_key(Key.F);
	f.ui.flush();
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.zoom > 1.5f, "F did not zoom in on the keys (zoom %f)", plot.zoom);
	test::@check(plot.view_start <= 1.0f && plot.view_start + plot.visible_width() >= 2.0f,
		"the framed time %f..%f misses 1..2 s", plot.view_start, plot.view_start + plot.visible_width());
	test::@check(math::abs(f.app.anim_timeline_zoom - plot.zoom) < 1.0e-4f, "the sheet's zoom did not follow");
	Vec2 range = plot.y_range();
	foreach (p : plot.points)
	{
		if (p.selected) test::@check(p.at.y >= range.x && p.at.y <= range.y, "a framed key is out of view at %f", p.at.y);
	}

	f.feed_key(Key.A);
	f.ui.flush();
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.zoom <= 1.0f && plot.view_start == 0.0f, "A did not show the whole clip (%f, %f)", plot.zoom, plot.view_start);
	range = plot.y_range();
	foreach (line : plot.series)
	{
		foreach (p : line.points) test::@check(p.y >= range.x - 1.0e-4f && p.y <= range.y + 1.0e-4f, "A left a curve out at %f", p.y);
	}
}

// ---------------------------------------------------------------------------
// Several keys at once

// The Curves sheet on the biped's root, with only its three keys' rotation drawn.
fn void open_rotation_curves(Fixture* f)
{
	open_curves(f);
	for (int axis = 0; axis < 3; axis++) f.app.set_graph_hidden(f.app.doc.root_id, false, axis, true);
	crig::anim_curves_redraw(f.ui);
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
}

// The Z angle of a joint's rotation key at `time`, in degrees.
fn float key_z(Fixture* f, String joint, float time)
{
	AnimTemplate* clip = f.app.clip(f.app.editing);
	sz key = f.app.key_near(f.app.editing, time, crig::ANIM_SAME_TIME);
	return crig::euler_of(clip.keyframes[key].rotation_of(joint), {}).z;
}

// The distinct key times the plot draws, in order.
fn float[] curve_times(Fixture* f)
{
	CurvePlot* plot = curve_plot(f).widget_as(CurvePlot);
	float[] times = alloc::new_array(tmem, float, plot.points.len);
	usz count;
	foreach (usz i, p : plot.points) if (i % 3 == 0) times[count++] = p.at.x;
	return times[:count];
}

// Drag a box that holds the points of the keys at `times`, with `keys` held.
fn void box_keys(Fixture* f, float first, float last, Key[] keys = { })
{
	CurvePlot* plot = curve_plot(f).widget_as(CurvePlot);
	Vec2 low = curve_pixel(f, { first, plot.points[0].at.y });
	Vec2 high = curve_pixel(f, { last, plot.points[0].at.y });
	// Above and below the plot's points, clear of every one of them.
	Element* elem = curve_plot(f);
	Vec4 r = plot.plot_rect(elem);
	Vec2 from = { low.x - 4, elem.absolute.y + r.y + 2 };
	Vec2 to = { high.x + 14, elem.absolute.y + r.y + r.w - 2 };
	f.feed(from, keys: keys);
	f.feed(from, left: true, keys: keys);
	f.feed((from + to) * 0.5f, left: true, keys: keys);
	f.feed(to, left: true, keys: keys);
	f.feed(to, keys: keys);
	f.feed(to);
	f.ui.flush();
}

<*
 A drag over empty plot space picks the keys whose points it covers: plain
 replaces the selection, Shift adds, Ctrl toggles. A click on empty space still
 sets the playhead, and a box edits nothing.
*>
fn void a_box_picks_curve_keys() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_rotation_curves(&f);
	float[] times = curve_times(&f);
	test::@check(times.len == 3, "%d keys drawn", times.len);
	if (times.len != 3) return;
	sz history = f.app.undo_stack.cursor;

	box_keys(&f, times[1], times[2]);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)2);
	test::@check(f.app.animation_channel_key_selected(f.app.editing, times[1], f.app.anim_channel_key_selection[0].joint,
		ROTATION) || f.app.animation_channel_key_selected(f.app.editing, times[2],
		f.app.anim_channel_key_selection[0].joint, ROTATION), "the box picked the wrong keys");
	String joint = f.app.anim_channel_key_selection[0].joint.tcopy();
	test::@check(!f.app.animation_channel_key_selected(f.app.editing, times[0], joint, ROTATION),
		"the box picked a key outside it");
	test::eq(f.app.undo_stack.cursor, history);

	// A plain box over one key replaces; Shift over another adds; Ctrl removes.
	box_keys(&f, times[0], times[0]);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)1);
	test::@check(f.app.animation_channel_key_selected(f.app.editing, times[0], joint, ROTATION), "the box did not replace");
	Key[1] shift = { Key.LEFT_SHIFT };
	box_keys(&f, times[1], times[2], shift[..]);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)3);
	Key[1] ctrl = { Key.LEFT_CTRL };
	box_keys(&f, times[1], times[1], ctrl[..]);
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)2);
	test::@check(!f.app.animation_channel_key_selected(f.app.editing, times[1], joint, ROTATION),
		"Ctrl did not take the key out");

	// A click without a drag is still the playhead.
	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	Element* elem = curve_plot(&f);
	Vec4 r = plot.plot_rect(elem);
	Vec2 empty = elem.absolute + (Vec2){ r.x + r.z * 0.9f, r.y + 2 };
	f.click(empty);
	f.ui.flush();
	test::@check(f.app.edit_time > times[2] || f.app.anim_time > times[2] || f.app.edit_time != 0,
		"a click on empty space did not set the playhead");
}

<*
 Dragging a selected key up or down moves that axis of every selected key by
 the same amount, as one undo step; a key outside the selection is untouched.
*>
fn void a_value_drag_moves_every_selected_key() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_rotation_curves(&f);
	float[] times = curve_times(&f);
	if (times.len != 3) return;
	box_keys(&f, times[1], times[2]);
	String joint = f.app.anim_channel_key_selection[0].joint.tcopy();
	float a = key_z(&f, joint, times[1]);
	float b = key_z(&f, joint, times[2]);
	float other = key_z(&f, joint, times[0]);
	sz history = f.app.undo_stack.cursor;

	// Press the Z point of the first picked key and pull it up.
	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	usz index = curve_point(&f, times[1]);
	Vec2 at = curve_pixel(&f, plot.points[index].at);
	f.drag(at, at - (Vec2){ 0, 30 });
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	float da = key_z(&f, joint, times[1]) - a;
	float db = key_z(&f, joint, times[2]) - b;
	test::@check(da > 0.05f && math::abs(da - db) < 1.0e-2f, "the keys moved by %f and %f", da, db);
	test::@check(math::abs(key_z(&f, joint, times[0]) - other) < 1.0e-3f, "an unselected key moved");
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)2);
	test::@check(f.app.undo(), "the drag did not undo as one step");
	test::@check(math::abs(key_z(&f, joint, times[1]) - a) < 1.0e-3f && math::abs(key_z(&f, joint, times[2]) - b) < 1.0e-3f,
		"undo did not restore both keys");
}

<*
 Alt + drag on a selected key scales the selected values about their middle in
 one step: the farther key moves farther, the middle stays.
*>
fn void alt_drag_scales_the_selected_values() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_rotation_curves(&f);
	float[] times = curve_times(&f);
	if (times.len != 3) return;
	box_keys(&f, times[1], times[2]);
	String joint = f.app.anim_channel_key_selection[0].joint.tcopy();
	// Give the two keys different values to scale between.
	Graph graph = f.app.build_graph(f.app.editing);
	foreach (key : graph.keys)
	{
		if (key.curve % 3 != 2 || key.time != times[1] && key.time != times[2]) continue;
		f.app.set_graph_key_value(f.app.editing, joint, true, key.time, key.shown, 2, key.time == times[1] ? 10.0f : 30.0f);
	}
	graph.free();
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	test::eq(f.app.animation_channel_key_selection_count(f.app.editing), (usz)2);
	float a = key_z(&f, joint, times[1]);
	float b = key_z(&f, joint, times[2]);
	sz history = f.app.undo_stack.cursor;

	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	usz index = curve_point(&f, times[2]);
	Vec2 at = curve_pixel(&f, plot.points[index].at);
	f.alt_drag(at, at - (Vec2){ 0, 30 });
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	float na = key_z(&f, joint, times[1]);
	float nb = key_z(&f, joint, times[2]);
	float middle = (a + b) * 0.5f;
	float factor = (nb - middle) / (b - middle);
	test::@check(factor > 1.05f && math::abs((na - middle) / (a - middle) - factor) < 1.0e-2f,
		"the values scaled by %f and %f", factor, (na - middle) / (a - middle));
	test::@check(f.app.undo(), "the scale did not undo as one step");
}

<*
 The frame and value fields show what the selected keys share, blank when they
 differ, and Enter in one applies it to every selected key as one step.
*>
fn void the_key_fields_apply_an_exact_value() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_rotation_curves(&f);
	float[] times = curve_times(&f);
	if (times.len != 3) return;
	box_keys(&f, times[1], times[2]);
	f.feed({ 0, 0 });
	f.ui.flush();
	String joint = f.app.anim_channel_key_selection[0].joint.tcopy();
	Element* z = f.ui.find_id(crig::ANIM_CURVE_VALUE_IDS[2])!!;
	test::@check(z.widget_as(TextField).value() == "0.0" || z.widget_as(TextField).value() == "",
		"the Z field reads '%s'", z.widget_as(TextField).value());
	Element* frame = f.ui.find_id(crig::ANIM_CURVE_FRAME_ID)!!;
	test::@check(frame.widget_as(TextField).value().len > 0, "the frame field is blank with keys selected");

	sz history = f.app.undo_stack.cursor;
	z.widget_as(TextField).set_text(z, "");
	f.type_into(z, "25");
	f.feed_key(Key.RETURN);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(math::abs(key_z(&f, joint, times[1]) - 25.0f) < 1.0e-2f
		&& math::abs(key_z(&f, joint, times[2]) - 25.0f) < 1.0e-2f, "the keys read %f and %f",
		key_z(&f, joint, times[1]), key_z(&f, joint, times[2]));
	test::@check(math::abs(key_z(&f, joint, times[0]) - 25.0f) > 1.0f, "the unselected key took the value");
	f.feed({ 0, 0 });
	f.ui.flush();
	z = f.ui.find_id(crig::ANIM_CURVE_VALUE_IDS[2])!!;
	test::@check(z.widget_as(TextField).value() == "25.0", "the Z field now reads '%s'", z.widget_as(TextField).value());
}

module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

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
 handle then sets the ease as one more.
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
	test::@check(f.in_tree(crig::ANIM_GRAPH_CHANNEL_ID) && !f.in_tree("anim-show-tracks"),
		"the Rotation/Position switch did not replace Show tracks");
	CurvePlot* plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.series.len == 3, "%d curves", plot.series.len);
	test::@check(plot.points.len == 9, "%d points", plot.points.len);

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

	// The selected key's handles: pull the outgoing one off the flat line.
	f.feed({ 0, 0 });
	f.ui.flush();
	plot = curve_plot(&f).widget_as(CurvePlot);
	test::@check(plot.handles.len > 0, "a selected eased key shows no handles");
	if (plot.handles.len == 0) return;
	CurveHandle handle = plot.handles[0];
	Vec2 grip = curve_pixel(&f, handle.at);
	history = f.app.undo_stack.cursor;
	f.drag(grip, grip + (Vec2){ 0, 25 });
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	clip = f.app.clip(f.app.editing);
	key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	test::@check(clip.keyframes[key].channel_dot(joint, true, &dot)
		&& dot.rotation_ease.start < 0.95f && dot.rotation_ease.end == 1.0f,
		"the handle did not loosen the ease leaving the key (%f, %f)", dot.rotation_ease.start, dot.rotation_ease.end);

	test::@check(f.app.undo() && f.app.undo() && f.app.undo(), "the three edits did not undo");
	clip = f.app.clip(f.app.editing);
	key = f.app.key_near(f.app.editing, 1.0f, crig::ANIM_SAME_TIME);
	test::@check(math::abs(crig::euler_of(clip.keyframes[key].rotation_of(joint), {}).z - before) < 1.0e-3f
		&& !clip.uses_easing(), "undo did not restore the key");
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

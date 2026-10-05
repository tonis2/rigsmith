module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

fn Vec2 multi_pose_point(Fixture* f, float time)
{
	Element* sheet = f.ui.find(Timeline)!!;
	Timeline* timeline = sheet.widget_as(Timeline);
	return sheet.absolute + (Vec2){ timeline.x_of(sheet, time), timeline.lane_y(0) };
}

fn usz multi_selected_marks(Fixture* f)
{
	usz count = 0;
	foreach (mark : f.ui.find(Timeline)!!.widget_as(Timeline).marks)
	{
		if (mark.selected) count++;
	}
	return count;
}

fn void multi_ctrl_shift_click(Fixture* f, Vec2 at)
{
	Key[2] held = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	f.feed(at, keys: held[..]);
	f.feed(at, left: true, keys: held[..]);
	f.feed(at, keys: held[..]);
	f.feed(at);
}

fn void multi_pose_workspace(Fixture* f)
{
	// The UI fixture already borrows the process-wide coarse cube grid, so undo
	// exercises a real bind without rebuilding or replacing that shared cache.
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Multiple poses", 4);
	clip = f.app.key_here(clip, 1);
	f.app.editing = f.app.key_here(clip, 2);
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
}

fn void animation_multikey_ui_shift_copy_paste_delete_are_grouped() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	sz history = f.app.undo_stack.cursor;
	f.click(multi_pose_point(&f, 0));
	f.shift_click(multi_pose_point(&f, 1));
	test::eq(multi_selected_marks(&f), (usz)2);
	test::eq(f.app.undo_stack.cursor, history);
	Vec2 point = multi_pose_point(&f, 1);
	f.feed(point, keys: { Key.LEFT_CTRL, Key.C });
	f.feed(point);
	test::eq(f.app.anim_key_clipboard.keyframes.len, (sz)2);
	Element* sheet = f.ui.find(Timeline)!!;
	point = sheet.absolute + (Vec2){ sheet.widget_as(Timeline).x_of(sheet, 3), 5 };
	f.click(point);
	f.feed(point, keys: { Key.LEFT_CTRL, Key.V });
	f.feed(point);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)5);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(multi_selected_marks(&f), (usz)2);
	f.feed(point, keys: { Key.DELETE });
	f.feed(point);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)3);
	test::eq(f.app.undo_stack.cursor, history + 2);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes.len == 5,
		"group delete did not undo together");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes.len == 3,
		"group paste did not undo together");
}

fn void animation_multikey_ui_ctrl_shift_click_selects_the_span() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	// A fourth key, so a span of three can be selected and deleted with one left over.
	f.app.editing = f.app.key_here(f.app.editing, 3);
	f.app.show_edited();
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)4);
	sz history = f.app.undo_stack.cursor;
	// Click one key, then Ctrl+Shift-click a later one: the keys between are caught
	// too, so the whole span is selected.
	f.click(multi_pose_point(&f, 1));
	test::eq(multi_selected_marks(&f), (usz)1);
	multi_ctrl_shift_click(&f, multi_pose_point(&f, 3));
	test::eq(multi_selected_marks(&f), (usz)3);
	test::eq(f.app.undo_stack.cursor, history);
	// Delete the span as one undo step; the untouched key keeps the clip alive.
	Vec2 point = multi_pose_point(&f, 3);
	f.feed(point, keys: { Key.DELETE });
	f.feed(point);
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)1);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes.len == 4,
		"range delete did not undo together");
}

fn void animation_multikey_ui_box_move_and_escape_preserve_history() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	multi_pose_workspace(&f);
	sz history = f.app.undo_stack.cursor;
	// Empty lane drag encloses keys at one and two seconds, not the rest key.
	Vec2 from = multi_pose_point(&f, 0.75f);
	Vec2 to = multi_pose_point(&f, 2.25f);
	from.y -= 5;
	to.y += 5;
	// The band ends just before two seconds. Frame snapping would round that
	// edge onto the key, but selection follows the visible band, not the grid.
	Vec2 before_two = multi_pose_point(&f, 1.99f);
	before_two.y += 5;
	f.feed(from);
	f.feed(from, left: true);
	f.feed(before_two, left: true);
	f.feed(before_two);
	test::eq(multi_selected_marks(&f), (usz)1);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	f.feed(to);
	test::eq(multi_selected_marks(&f), (usz)2);
	test::eq(f.app.undo_stack.cursor, history);
	from = multi_pose_point(&f, 1);
	to = multi_pose_point(&f, 1.5f);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	f.feed(to, left: true, keys: { Key.ESCAPE });
	f.feed(to);
	test::eq(f.app.undo_stack.cursor, history);
	test::@check(f.app.clip(f.app.editing).keyframes[1].time == 1,
		"Escape committed the dragged group");
	from = multi_pose_point(&f, 1);
	to = multi_pose_point(&f, 1.5f);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	f.feed(to);
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(math::abs(clip.keyframes[1].time - 1.5f) < 0.00001f
		&& math::abs(clip.keyframes[2].time - 2.5f) < 0.00001f,
		"group drag lost selection or changed spacing");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).keyframes[1].time == 1
		&& f.app.clip(f.app.editing).keyframes[2].time == 2, "group move did not undo together");
}

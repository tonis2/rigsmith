// The Trim dialog: keep a range or remove one, each as one undo entry, with
// the playhead and the selection following.
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::io;
import std::math;

// A 2 s clip keyed every half second, parked at 1.2 s with the Animations tab up.
fn void trim_workspace(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Trim", 2.0f);
	foreach (t : (float[]) { 0.5f, 1.0f, 1.5f, 2.0f }) clip = f.app.key_here(clip, t);
	f.app.editing = clip;
	f.app.edit_time = 1.2f;
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).keyframes.len, (sz)5);
}

fn void trim_open(Fixture* f, String start, String end)
{
	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-trim")!!);
	f.ui.flush();
	Element* from = f.ui.find_id(crig::ANIM_TRIM_START_ID)!!;
	Element* to = f.ui.find_id(crig::ANIM_TRIM_END_ID)!!;
	if (start.len > 0) from.widget_as(TextField).set_text(from, start);
	if (end.len > 0) to.widget_as(TextField).set_text(to, end);
}

fn bool trim_key_at(Fixture* f, float time)
{
	foreach (frame : f.app.clip(f.app.editing).keyframes) if (math::abs(frame.time - time) < 1.0e-5f) return true;
	return false;
}

fn void animation_trim_dialog_keeps_a_range_and_undoes_once() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	trim_workspace(&f);

	sz history = f.app.undo_stack.cursor;
	trim_open(&f, "0.5", "1.5");
	f.click(f.center_of(crig::ANIM_TRIM_KEEP_ID)!!);
	f.ui.flush();
	AnimTemplate* kept = f.app.clip(f.app.editing);
	test::@check(math::abs(kept.duration - 1.0f) < 1.0e-6f, "the duration is %.3f, wanted the range", kept.duration);
	test::@check(kept.keyframes.len == 3 && trim_key_at(&f, 0) && trim_key_at(&f, 0.5f) && trim_key_at(&f, 1.0f),
		"%d keys; wanted the three from 0.5, 1.0 and 1.5 s rebased", kept.keyframes.len);
	test::@check(math::abs(f.app.edit_time - 0.7f) < 1.0e-6f, "the playhead was not rebased with the keys: %.3f", f.app.edit_time);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(!f.ui.find_id(crig::ANIM_TRIM_DIALOG_ID)!!.widget_as(Dialog).open, "the dialog stayed open");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).duration == 2.0f
		&& f.app.clip(f.app.editing).keyframes.len == 5, "the crop did not undo in one step");
}

fn void animation_trim_dialog_removes_a_range_and_joins_the_edges() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	trim_workspace(&f);

	sz history = f.app.undo_stack.cursor;
	trim_open(&f, "0.5", "1.5");
	f.click(f.center_of(crig::ANIM_TRIM_REMOVE_ID)!!);
	f.ui.flush();
	AnimTemplate* joined = f.app.clip(f.app.editing);
	test::@check(math::abs(joined.duration - 1.0f) < 1.0e-6f, "the duration is %.3f, wanted a second less", joined.duration);
	test::@check(joined.keyframes.len == 3 && trim_key_at(&f, 0) && trim_key_at(&f, 0.5f) && trim_key_at(&f, 1.0f),
		"%d keys; wanted 0, the joined edge at 0.5 and the 2 s key moved to 1", joined.keyframes.len);
	test::@check(math::abs(f.app.edit_time - 0.5f) < 1.0e-6f,
		"a playhead inside the cut should land on the seam, not %.3f", f.app.edit_time);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.undo() && f.app.clip(f.app.editing).duration == 2.0f
		&& f.app.clip(f.app.editing).keyframes.len == 5, "the cut did not undo in one step");
}

fn void animation_trim_dialog_refuses_bad_ranges_and_cancels_cleanly() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	trim_workspace(&f);

	sz history = f.app.undo_stack.cursor;
	trim_open(&f, "1.5", "0.5");
	f.click(f.center_of(crig::ANIM_TRIM_KEEP_ID)!!);
	f.ui.flush();
	test::@check(f.ui.find_id(crig::ANIM_TRIM_DIALOG_ID)!!.widget_as(Dialog).open, "a backwards range closed the dialog");
	test::eq(f.app.undo_stack.cursor, history);

	Element* to = f.ui.find_id(crig::ANIM_TRIM_END_ID)!!;
	to.widget_as(TextField).set_text(to, "2.5");
	Element* from = f.ui.find_id(crig::ANIM_TRIM_START_ID)!!;
	from.widget_as(TextField).set_text(from, "0.5");
	f.click(f.center_of(crig::ANIM_TRIM_REMOVE_ID)!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).duration == 2.0f, "a range past the end was applied");
	test::eq(f.app.undo_stack.cursor, history);

	to.widget_as(TextField).set_text(to, "2");
	from.widget_as(TextField).set_text(from, "0");
	f.click(f.center_of(crig::ANIM_TRIM_REMOVE_ID)!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).duration == 2.0f && f.app.clip(f.app.editing).keyframes.len == 5,
		"removing the whole clip was applied");
	test::eq(f.app.undo_stack.cursor, history);

	f.click(f.center_of(crig::ANIM_TRIM_CANCEL_ID)!!);
	f.ui.flush();
	test::@check(!f.ui.find_id(crig::ANIM_TRIM_DIALOG_ID)!!.widget_as(Dialog).open, "Cancel left the dialog open");
	test::@check(f.app.clip(f.app.editing).keyframes.len == 5, "Cancel changed the clip");

	f.app.pose_edit_pending = true;
	crig::anim_trim_clicked(f.ui);
	test::@check(!f.ui.find_id(crig::ANIM_TRIM_DIALOG_ID)!!.widget_as(Dialog).open, "an unsaved pose did not block trimming");
	f.app.pose_edit_pending = false;
}

fn void animation_trim_dialog_opens_on_the_selected_keys() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	trim_workspace(&f);

	// Whole clip by default.
	trim_open(&f, "", "");
	test::eq(f.ui.find_id(crig::ANIM_TRIM_START_ID)!!.widget_as(TextField).value(), "0");
	test::eq(f.ui.find_id(crig::ANIM_TRIM_END_ID)!!.widget_as(TextField).value(), "2");
	f.click(f.center_of(crig::ANIM_TRIM_CANCEL_ID)!!);
	f.ui.flush();

	// The selected keys' span when two or more are selected.
	f.app.select_animation_key(f.app.editing, 0.5f);
	f.app.select_animation_key(f.app.editing, 1.5f, additive: true);
	trim_open(&f, "", "");
	test::eq(f.ui.find_id(crig::ANIM_TRIM_START_ID)!!.widget_as(TextField).value(), "0.5");
	test::eq(f.ui.find_id(crig::ANIM_TRIM_END_ID)!!.widget_as(TextField).value(), "1.5");
	f.click(f.center_of(crig::ANIM_TRIM_KEEP_ID)!!);
	f.ui.flush();
	test::@check(math::abs(f.app.clip(f.app.editing).duration - 1.0f) < 1.0e-6f, "the selected span was not kept");
	test::eq(f.app.animation_key_selection_count(f.app.editing), (usz)0);
}

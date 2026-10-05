module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::io;

// Two library clips the fitted biped can carry, or false.
fn bool two_usable_clips(Fixture* fixture, AnimRef* first, AnimRef* second)
{
	*first = crig::NO_ANIM;
	*second = crig::NO_ANIM;
	foreach (usz p, &pack : fixture.app.packs)
	{
		foreach (usz c, clip : pack.clips)
		{
			AnimRef ref = { (int)p, (int)c };
			if (!fixture.app.clip_applies(ref)) continue;
			if (!first.valid()) { *first = ref; continue; }
			if (!second.valid()) *second = ref;
		}
	}
	return second.valid();
}

fn String bound_name(Fixture* fixture, sz row) => fixture.app.doc.animations[row].clip;

<*
 Binding, un-binding and reordering clips are each one undo step.
*>
fn void binding_clips_undoes_and_redoes() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("binding, un-binding and reordering clips undo and redo");
	fixture.reset();
	defer fixture.reset();

	test::@check(fixture.app.apply_plan_named("biped"), "the biped plan could not be fitted");
	AnimRef first;
	AnimRef second;
	if (!two_usable_clips(fixture, &first, &second))
	{
		test::@check(false, "SKIPPED — the library offers fewer than two clips this rig can carry");
		return;
	}
	String first_name = fixture.app.clip(first).name.copy(mem);
	defer first_name.free(mem);
	String second_name = fixture.app.clip(second).name.copy(mem);
	defer second_name.free(mem);
	sz history = fixture.app.undo_stack.cursor;

	// Bind → undo → redo.
	test::@check(fixture.app.bind_ref_recorded(first), "the first clip did not bind");
	test::eq(fixture.app.doc.animations.len(), (sz)1);
	test::eq(fixture.app.undo_stack.cursor, history + 1);
	test::@check(fixture.app.undo(), "the bind did not undo");
	test::eq(fixture.app.doc.animations.len(), (sz)0);
	test::@check(fixture.app.redo(), "the bind did not redo");
	test::eq(fixture.app.doc.animations.len(), (sz)1);
	test::eq(bound_name(fixture, 0), first_name);

	// Reorder → undo → redo.
	test::@check(fixture.app.bind_ref_recorded(second), "the second clip did not bind");
	test::@check(fixture.app.reorder_bound_recorded(0, 1), "the reorder was refused");
	test::eq(bound_name(fixture, 0), second_name);
	test::@check(fixture.app.undo(), "the reorder did not undo");
	test::eq(bound_name(fixture, 0), first_name);
	test::eq(bound_name(fixture, 1), second_name);
	test::@check(fixture.app.redo(), "the reorder did not redo");
	test::eq(bound_name(fixture, 0), second_name);
	test::@check(fixture.app.undo(), "the reorder did not undo again");

	// Un-bind → undo puts the row back where it was.
	fixture.app.editing = first;
	test::@check(fixture.app.unbind_recorded(0), "the un-bind was refused");
	test::eq(fixture.app.doc.animations.len(), (sz)1);
	test::eq(bound_name(fixture, 0), second_name);
	test::@check(!fixture.app.editing.valid(), "the un-bound clip is still being edited");
	test::@check(fixture.app.undo(), "the un-bind did not undo");
	test::eq(fixture.app.doc.animations.len(), (sz)2);
	test::eq(bound_name(fixture, 0), first_name);
	test::eq(fixture.app.anim_rows.len, (sz)2);
	test::eq(fixture.app.anim_rows[0].label, first_name);
}

<*
 The clip menu's Delete animation… asks first, then deletes the project clip and its
 row as one undo step.
*>
fn void the_clip_menu_deletes_an_animation_after_asking() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	io::printn("clip menu > Delete animation asks, deletes and undoes");
	multi_pose_workspace(&f);
	sz history = f.app.undo_stack.cursor;

	f.click(f.center_of("anim-more")!!);
	f.click(f.center_of(crig::ANIM_DELETE_ID)!!);
	f.ui.flush();
	Element* panel = f.ui.find_id(crig::ANIM_DELETE_CONFIRM_ID)!!;
	ConfirmDialog* ask = panel.widget_as(ConfirmDialog);
	test::@check(ask.asking(panel), "Delete animation did not ask first");
	test::@check(ask.message.str_view().contains("Multiple poses"), "the question does not name the clip");
	test::@check(f.app.clip_named_in_authored("Multiple poses").valid(), "the clip went before the answer");

	panel.widget_as(ConfirmDialog).withdraw(panel);
	crig::anim_delete_confirmed(f.ui);
	f.ui.flush();
	test::@check(!f.app.clip_named_in_authored("Multiple poses").valid(), "the clip survived the delete");
	test::eq(f.app.doc.bound_index("", "Multiple poses"), (sz)-1);
	test::@check(f.app.undo_stack.cursor > history, "the delete was not recorded");

	test::@check(f.app.undo(), "the delete did not undo");
	test::eq(f.app.undo_stack.cursor, history);
	test::@check(f.app.clip_named_in_authored("Multiple poses").valid(), "undo did not bring the clip back");
	test::@check(f.app.doc.bound_index("", "Multiple poses") >= 0, "undo did not bring the row back");
}

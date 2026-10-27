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
 The clip menu only takes a clip off the character; deleting is the asset
 browser's. An authored clip is listed under Current file, its settings panel
 deletes it with its row as one undo step, and undo puts both back with the clip
 open again in its old slot.
*>
fn void the_asset_browser_deletes_an_authored_clip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	io::printn("the clip menu has no Delete; the asset browser deletes and undoes");
	multi_pose_workspace(&f);

	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	test::@check(!f.in_tree("anim-delete"), "the clip menu still offers Delete animation");
	f.click({ 4, crig::WIN_H - 4 });
	f.ui.flush();

	AnimRef open = f.app.editing;
	test::@check(open.valid(), "the workspace has no clip open");
	sz history = f.app.undo_stack.cursor;

	f.app.refresh_ui();
	f.app.asset_filter = crig::ALL_ASSETS;
	f.app.refresh_visible_assets();
	sz row = -1;
	foreach (usz i, which : f.app.visible_assets)
	{
		crig::AssetEntry entry = f.app.assets.entries[which];
		if (entry.authored() && entry.name == "Multiple poses") row = (sz)i;
	}
	test::@check(row >= 0, "the authored clip is not listed in the asset browser");
	if (row < 0) return;
	test::@check(f.app.visible_asset((usz)row).current, "an authored clip is not under Current file");

	crig::open_asset_settings(f.ui, (usz)row);
	f.ui.flush();
	test::@check(f.in_tree(crig::ASSET_SETTINGS_DELETE_ID), "the settings panel has no Delete for an authored clip");
	f.click(f.center_of(crig::ASSET_SETTINGS_DELETE_ID)!!);
	f.ui.flush();

	test::@check(!f.app.clip_named_in_authored("Multiple poses").valid(), "the clip survived the delete");
	test::eq(f.app.doc.bound_index("", "Multiple poses"), (sz)-1);
	test::@check(!f.app.editing.valid(), "the deleted clip is still open");
	test::@check(f.app.undo_stack.cursor > history, "the delete was not recorded");
	foreach (entry : f.app.assets.entries)
	{
		test::@check(!(entry.authored() && entry.name == "Multiple poses"), "the browser still lists the deleted clip");
	}

	test::@check(f.app.undo(), "the delete did not undo");
	test::eq(f.app.undo_stack.cursor, history);
	AnimRef back = f.app.clip_named_in_authored("Multiple poses");
	test::@check(back.valid(), "undo did not bring the clip back");
	test::@check(back.same(open), "undo did not put the clip back in its slot");
	test::@check(f.app.editing.same(back), "undo did not open the clip again");
	test::@check(f.app.doc.bound_index("", "Multiple poses") >= 0, "undo did not bring the row back");
}

// File › New scene over unsaved work asks "Unsaved changes" with Yes / No, not
// the body plan's question, and No keeps the scene.
fn void a_new_scene_over_unsaved_work_asks_yes_or_no() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	test::@check(f.app.any_character_unsaved(), "fitting a rig is unsaved work");
	Element* panel = f.ui.find_id(crig::UNSAVED_DIALOG_ID)!!;
	ConfirmDialog* ask = panel.widget_as(ConfirmDialog);
	Element* rig = f.ui.find_id(crig::CONFIRM_DIALOG_ID)!!;

	crig::menu_new_scene(f.ui);
	f.ui.flush();
	test::@check(ask.asking(panel), "New scene did not ask");
	test::@check(!rig.widget_as(ConfirmDialog).asking(rig), "New scene asked through the body plan dialog");
	test::eq(ask.title, "Unsaved changes");
	test::eq(ask.confirm_text(), "Yes");
	test::eq(ask.decline_text(), "No");
	test::@check(ask.message.str_view().contains("unsaved changes"), "the question does not say why it asks");

	f.close_menu();
	test::@check(!ask.asking(panel), "Escape did not answer No");
	test::@check(f.app.has_mesh() && f.app.doc.dots.len() > 0, "answering No emptied the scene");
}

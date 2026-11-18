<*
 The Cutscene tab: the list's icons, its fields and their undo, the actors list,
 the problems, the preview switch and the timeline's playhead.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;
import std::math::quaternion;

// The Cutscene tab in a pane of its own under the model, one frame later.
fn void open_cutscene_tab(Fixture* f) @local
{
	crig::show_pane_view(f.ui, crig::CUTSCENE_VIEW, SplitAxis.VERTICAL, 0.5f);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

fn AreaNode* leaf_showing(AreaNode* node, usz view) @local
{
	if (!node) return null;
	if (node.is_leaf()) return node.active == view ? node : null;
	AreaNode* found = leaf_showing(node.first, view);
	return found ? found : leaf_showing(node.second, view);
}

fn Vec2 cut_centre(Fixture* f, String id) @local
{
	Element* elem = f.ui.find_id(id)!!;
	return elem.absolute + elem.size * 0.5f;
}

fn void the_cutscene_tab_edits_its_list_and_undoes_each_edit() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_cutscene_tab(&f);
	test::@check(has_id(&f, crig::CUT_PANEL_ID), "no Cutscene panel");
	test::@check(f.app.cut_panes == 1, "the pane is not counted: %d", f.app.cut_panes);
	test::@check(has_id(&f, crig::CUT_ADD_ID), "no New cutscene icon");
	test::@check(!has_id(&f, crig::CUT_LIST_ID), "a list before there is a cutscene");
	test::@check(!has_id(&f, crig::CUT_DELETE_ID), "Delete with nothing to delete");

	// The cube is a character but no actor: its row in the list makes it one.
	f.ui.find_id(crig::CUT_ACTORS_ID)!!.widget_as(Tree).on_select(f.ui, 0);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.actor_row.len > 0, "the row did not make the cube an actor");
	test::@check(has_id(&f, crig::CUT_ROW_ID), "no row field for the actor");

	// A click on the icon adds a cutscene holding the actor.
	f.click(cut_centre(&f, crig::CUT_ADD_ID));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscenes.len() == 1, "the icon added %d cutscenes", f.app.cutscenes.len());
	test::@check(has_id(&f, crig::CUT_LIST_ID) && has_id(&f, crig::CUT_DELETE_ID), "no list or Delete after adding");
	test::@check(f.app.cutscene().actors.len == 1, "the actor is not in the new cutscene");
	Element* name = f.ui.find_id(crig::CUT_NAME_ID)!!;
	test::@check(name.widget_as(TextField).text.str_view() == "Cutscene", "the name field reads '%s'", name.widget_as(TextField).text.str_view());

	crig::cut_name_submitted(f.ui, "Opening");
	f.feed(f.ui.input.mouse);
	crig::cut_duration_submitted(f.ui, "4");
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().name == "Opening", "rename");
	test::@check(math::abs(f.app.cutscene().duration - 4.0f) < 1e-6f, "the length");
	name = f.ui.find_id(crig::CUT_NAME_ID)!!;
	test::@check(name.widget_as(TextField).text.str_view() == "Opening", "the field follows the rename");

	// Ctrl+Z takes each back alone.
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(math::abs(f.app.cutscene().duration - crig::CUT_NEW_DURATION) < 1e-6f, "undo the length");
	test::@check(f.app.cutscene().name == "Opening", "one undo took back more than the length");
	crig::menu_undo(f.ui);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscenes.len() == 0, "undo the add");
	test::@check(!has_id(&f, crig::CUT_LIST_ID), "the list stayed after the undo");
	for (int i = 0; i < 3; i++) crig::menu_redo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscenes.len() == 1 && f.app.cutscene().name == "Opening", "redo");

	// A strip whose clip the cube lacks is a problem the list names.
	test::@check(has_id(&f, crig::CUT_PROBLEMS_ID), "no problems list");
	Cutscene changed = f.app.cutscene().copy(mem);
	CutStrip wave = crig::cut_strip(PLAY, 0.5f, 1.5f);
	wave.clip = "Wave".copy(mem);
	changed.actors[0].free(mem);
	changed.actors[0] = { .row = f.app.actor_row.copy(mem), .home_rotation = quaternion::IDENTITY, .strips = alloc::clone_slice(mem, (CutStrip[]){ wave }) };
	f.app.replace_cutscene(0, changed);
	f.feed(f.ui.input.mouse);
	Element* problems = f.ui.find_id(crig::CUT_PROBLEMS_ID)!!;
	test::@check(problems.children.len() == 1, "%d problem lines", problems.children.len());
	String said = problems.children[0].widget_as(Label).text;
	test::@check(said.contains("Wave"), "the problem reads '%s'", said);

	// The preview stands the actor in the cutscene and puts it back.
	f.click(cut_centre(&f, crig::CUT_PREVIEW_ID));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_preview && f.app.staged, "the preview icon did not stage the actor");
	f.click(cut_centre(&f, crig::CUT_PREVIEW_ID));
	f.feed(f.ui.input.mouse);
	test::@check(!f.app.cut_preview && !f.app.staged, "the second click did not put it back");

	// A press on the timeline moves the playhead to the time under it.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	float x = drawn.x_of(timeline, f.app.cutscene(), 2.0f);
	Vec2 at = timeline.absolute + (Vec2){ x, crig::TIMELINE_STYLE.ruler_height + 4.0f };
	f.feed(at);
	f.feed(at, left: true);
	f.feed(at);
	test::@check(math::abs(f.app.cut_time - 2.0f) < 0.05f, "the playhead is at %f, not 2 s", f.app.cut_time);
	CutTimelineHit hit = drawn.hit(timeline, f.app.cutscene(), (Vec2){ drawn.x_of(timeline, f.app.cutscene(), 1.0f), crig::TIMELINE_STYLE.ruler_height + crig::CUT_LANE_H * 1.5f });
	test::@check(hit.actor == 0 && hit.lane == CutLane.WHAT && hit.strip == 0, "the wave is not under its own lane: actor %d strip %d", hit.actor, hit.strip);
}

fn void closing_the_tab_stops_counting_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	open_cutscene_tab(&f);
	test::@check(f.app.cut_panes == 1, "one pane shows the tab");
	AreaNode* leaf = leaf_showing(crig::area_layout.root, crig::CUTSCENE_VIEW);
	test::@check(leaf != null, "no pane shows the tab");
	if (!leaf) return;
	leaf.active = 0;
	f.ui.@each(AreaHost; host) { host.request_build(); };
	f.ui.flush();
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_panes == 0, "a tab switched away is still counted: %d", f.app.cut_panes);
}

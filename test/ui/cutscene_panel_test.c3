<*
 A cutscene in the Animations dock: + New › Cutscene, the chooser's cutscene rows, its
 fields and their undo, the Add actor list, the problems, a clip picked to leave the
 preview, the timeline's playhead, and the keys.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;
import std::math::quaternion;

// The Animations dock in a pane of its own under the model, one frame later.
fn void open_cutscene_tab(Fixture* f) @local
{
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

fn Vec2 cut_centre(Fixture* f, String id) @local
{
	Element* elem = f.ui.find_id(id)!!;
	return elem.absolute + elem.size * 0.5f;
}

// The chooser's option that reads `label`, or -1.
fn sz chooser_row(Fixture* f, String label)
{
	Element*? found = f.ui.find_id("anim-chooser");
	if (catch found) return -1;
	foreach (usz i, option : found.widget_as(Select).options) if (option == label) return (sz)i;
	return -1;
}

// Whether the chooser lists a cutscene.
fn bool chooser_lists_cutscenes(Fixture* f)
{
	Element*? found = f.ui.find_id("anim-chooser");
	if (catch found) return false;
	foreach (option : found.widget_as(Select).options) if (option.starts_with(crig::ANIM_CHOOSER_CUT_PREFIX)) return true;
	return false;
}

// Open the chooser and click its option `label`.
fn bool chooser_pick(Fixture* f, String label)
{
	sz row = chooser_row(f, label);
	if (row < 0) return false;
	f.click(f.center_of("anim-chooser")!!);
	f.ui.flush();
	Vec2 target;
	bool found;
	f.ui.@each(SelectOption; option)
	{
		if (option.widget_as(SelectOption).index == (usz)row)
		{
			target = option.absolute + option.size * 0.5f;
			found = true;
		}
	};
	if (!found) return false;
	f.click(target);
	f.feed(f.ui.input.mouse);
	return true;
}

// + New, then its Cutscene row.
fn void new_cutscene_clicked(Fixture* f)
{
	f.click(cut_centre(f, crig::ANIM_NEW_ID));
	f.ui.flush();
	f.click(cut_centre(f, crig::ANIM_NEW_CUTSCENE_ID));
	f.feed(f.ui.input.mouse);
}

fn void the_cutscene_tab_edits_its_list_and_undoes_each_edit() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	// A rig and a clip, for the chooser to pick.
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef idle_ref = f.app.new_clip("Idle", 1.0f);
	test::@check(idle_ref.valid(), "no clip to pick");
	String idle = f.app.clip(idle_ref).name.tcopy();
	f.app.stop_animation();
	open_cutscene_tab(&f);
	test::@check(has_id(&f, crig::ANIM_PANEL_ID), "no Animations dock");
	test::@check(!f.app.cutscene_in_dock(), "the dock shows a cutscene before there is one");
	test::@check(has_id(&f, crig::ANIM_NEW_ID), "no + New");
	test::@check(!chooser_lists_cutscenes(&f), "a list before there is a cutscene");
	test::@check(!has_id(&f, crig::CUT_DELETE_ID), "Delete with nothing to delete");

	// The cube is a character but no actor: its row in the Add actor list makes it one.
	crig::cut_add_actor_clicked(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(cut_sheet_list_pick(&f, crig::CUT_ACTOR_LIST_ID, "no actor · make one"), "the Add actor list does not offer the cube");
	test::@check(f.app.actor_row.len > 0, "the row did not make the cube an actor");

	// + New › Cutscene adds a cutscene holding the actor, and the dock shows it.
	new_cutscene_clicked(&f);
	test::@check(f.app.cutscenes.len() == 1, "the icon added %d cutscenes", f.app.cutscenes.len());
	test::@check(chooser_row(&f, "Cutscene · Cutscene") >= 0 && has_id(&f, crig::CUT_DELETE_ID), "no list or Delete after adding");
	test::@check(has_id(&f, crig::CUT_SIDE_ID), "no Cutscene panel");
	test::@check(f.app.cutscene_in_dock(), "the dock does not show the new cutscene");
	test::@check(f.app.cutscene().actors.len == 1, "the actor is not in the new cutscene");
	// Its header's menu has Rename row…, the row's field.
	f.right_click(cut_sheet_header(&f, 0));
	(void)cut_sheet_menu_click(&f, crig::CUT_ACTOR_RENAME_ID);
	test::@check(has_id(&f, crig::CUT_ROW_ID), "no row field for the actor");
	crig::close_cut_rename(f.ui);
	f.feed(f.ui.input.mouse);
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
	test::@check(!chooser_lists_cutscenes(&f), "the list stayed after the undo");
	for (int i = 0; i < 3; i++) crig::menu_redo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscenes.len() == 1 && f.app.cutscene().name == "Opening", "redo");
	// The undo gave the dock back; the chooser shows the cutscene again.
	test::@check(chooser_pick(&f, "Cutscene · Opening"), "the chooser does not list the redone cutscene");

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

	// The dock's preview stands the actor in the cutscene; a clip picked puts it back, the cutscene picked stands it again.
	test::@check(f.app.cut_preview && f.app.staged, "the preview icon did not stage the actor");
	test::@check(chooser_pick(&f, idle), "the chooser does not list %s", idle);
	test::@check(!f.app.cut_preview && !f.app.staged, "the second click did not put it back");
	test::@check(f.app.editing.same(idle_ref) && !has_id(&f, crig::CUT_TIMELINE_ID), "the clip is not what the dock shows");
	test::@check(chooser_pick(&f, "Cutscene · Opening"), "the chooser does not list the cutscene");
	test::@check(f.app.cutscene_in_dock() && f.app.staged && has_id(&f, crig::CUT_TIMELINE_ID), "the cutscene picked did not show it again");

	// A press on the timeline moves the playhead to the time under it.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	float x = drawn.x_of(timeline, f.app.cutscene(), 2.0f);
	Vec2 at = timeline.absolute + (Vec2){ x, crig::TIMELINE_STYLE.ruler_height * 0.5f };
	f.feed(at);
	f.feed(at, left: true);
	f.feed(at);
	test::@check(math::abs(f.app.cut_time - 2.0f) < 0.05f, "the playhead is at %f, not 2 s", f.app.cut_time);
	CutTimelineHit hit = drawn.hit(timeline, f.app.cutscene(), (Vec2){ drawn.x_of(timeline, f.app.cutscene(), 1.0f), drawn.lane_top(timeline, f.app.cutscene(), 0, WHAT) + crig::CUT_LANE_H * 0.5f });
	test::@check(hit.actor == 0 && hit.lane == CutLane.WHAT && hit.strip == 0, "the wave is not under its own lane: actor %d strip %d", hit.actor, hit.strip);
}

fn void picking_a_cutscene_in_the_chooser_shows_it_in_the_dock() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	open_cutscene_tab(&f);
	test::@check(!f.app.cutscene_in_dock() && !has_id(&f, crig::CUT_SIDE_ID), "the dock shows the cutscene before it is picked");
	test::@check(chooser_pick(&f, "Cutscene · Cutscene"), "the chooser does not list the cutscene");
	test::@check(f.app.cut_preview && f.app.cutscene_in_dock() && f.app.staged, "picking the cutscene did not preview it");
	Select* chooser = f.ui.find_id("anim-chooser")!!.widget_as(Select);
	test::@check(chooser.selected == (usz)chooser_row(&f, "Cutscene · Cutscene"), "the chooser does not show the cutscene picked");

	// The dock's frame: the bin and the sheet in the sheet's place, CutSide in the right column.
	test::@check(f.ui.find_id(crig::ANIM_SHEET_SLOT_ID)!!.is_widget(AnimLayerDeck), "the sheet slot is no deck");
	test::@check(has_id(&f, crig::CUT_PIECE_BIN_ID) && has_id(&f, crig::CUT_TIMELINE_ID), "no Pieces bin or sheet");
	Element* side = f.ui.find_id(crig::CUT_SIDE_ID)!!;
	Element* divider = f.ui.find_id(crig::ANIM_DIVIDER_ID)!!;
	test::@check(has_id(&f, crig::ANIM_LAYERS_SIDE_ID) && side.absolute.x >= divider.absolute.x + divider.size.x, "CutSide is not the right column");
	foreach (id : (String[]) { crig::CUT_START_ID, crig::CUT_PLAY_ID, crig::CUT_END_ID, crig::CUT_TIME_ID, crig::ANIM_NEW_ID })
	{
		test::@check(has_id(&f, id), "the cutscene dock has no %s", id);
	}
	foreach (id : (String[]) { crig::ANIM_KEY_ROW_ID, crig::ANIM_MORE_ID, crig::ANIM_SHEET_MODE_ID, crig::ANIM_TRANSPORT_PLAY_ID, crig::ANIM_LAYERS_ID })
	{
		test::@check(!has_id(&f, id), "the cutscene dock shows %s", id);
	}
}

fn void picking_a_clip_gives_the_dock_back_and_hides_the_knots_and_path_lines() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef idle_ref = f.app.new_clip("Idle", 1.0f);
	test::@check(idle_ref.valid(), "no clip to pick");
	String idle = f.app.clip(idle_ref).name.tcopy();
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	open_cutscene_tab(&f);
	test::@check(f.app.cut_picked_path() != null && !crig::cut_knots_shown(&f.app) && !crig::cut_path_lines_shown(&f.app),
		"knots or path lines with no cutscene in the dock");
	test::@check(chooser_pick(&f, "Cutscene · Cutscene"), "the chooser does not list the cutscene");
	test::@check(crig::cut_knots_shown(&f.app) && crig::cut_path_lines_shown(&f.app), "the cutscene in the dock shows no knots or path lines");

	test::@check(chooser_pick(&f, idle), "the chooser does not list %s", idle);
	test::@check(!f.app.cut_preview && !f.app.cutscene_in_dock() && !f.app.staged, "picking a clip did not leave the preview");
	test::@check(!crig::cut_knots_shown(&f.app) && !crig::cut_path_lines_shown(&f.app), "the knots or path lines outlived the cutscene in the dock");
	test::@check(!has_id(&f, crig::CUT_SIDE_ID) && has_id(&f, crig::ANIM_TRANSPORT_PLAY_ID), "the dock did not go back to the clip");
}

fn void the_dock_transport_plays_and_steps_the_cutscene() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	open_cutscene_tab(&f);
	test::@check(f.app.show_cutscene(0), "no cutscene to show");
	f.feed(f.ui.input.mouse);

	f.feed_key(Key.SPACE);
	test::@check(f.app.cut_playing, "Space did not play the cutscene");
	test::@check(f.ui.find_id(crig::CUT_PLAY_ID)!!.widget_as(Button).label == "❚❚", "the play button does not offer a pause");
	f.feed_key(Key.SPACE);
	test::@check(!f.app.cut_playing, "Space did not pause the cutscene");

	float frame = 1.0f / f.app.cutscene().fps;
	f.feed_key(Key.END);
	test::@check(math::abs(f.app.cut_time - f.app.cutscene().duration) < 1e-5f, "End put the playhead at %f", f.app.cut_time);
	f.feed_key(Key.HOME);
	test::@check(f.app.cut_time == 0.0f, "Home put the playhead at %f", f.app.cut_time);
	f.feed_key(Key.RIGHT_ARROW);
	test::@check(math::abs(f.app.cut_time - frame) < 1e-5f, "Right stepped to %f, not one frame", f.app.cut_time);
	f.feed_key(Key.PERIOD);
	test::@check(math::abs(f.app.cut_time - 2.0f * frame) < 1e-5f, "a period stepped to %f", f.app.cut_time);
	f.feed_key(Key.COMMA);
	f.feed_key(Key.LEFT_ARROW);
	test::@check(math::abs(f.app.cut_time) < 1e-5f, "comma and Left stepped back to %f", f.app.cut_time);

	// The buttons do the same.
	f.click(cut_centre(&f, crig::CUT_END_ID));
	f.feed(f.ui.input.mouse);
	test::@check(math::abs(f.app.cut_time - f.app.cutscene().duration) < 1e-5f, ">| put the playhead at %f", f.app.cut_time);
	f.click(cut_centre(&f, crig::CUT_PLAY_ID));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_playing && f.app.cut_time < 0.5f, "play at the end did not start over");
	f.click(cut_centre(&f, crig::CUT_START_ID));
	f.feed(f.ui.input.mouse);
	test::@check(!f.app.cut_playing && f.app.cut_time == 0.0f, "|< did not pause at the start");
}

fn void delete_in_the_dock_takes_the_picked_strip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	Cutscene changed = f.app.cutscene().copy(mem);
	CutStrip wave = crig::cut_strip(PLAY, 0.5f, 1.5f);
	wave.clip = "Wave".copy(mem);
	changed.actors[0].free(mem);
	changed.actors[0] = { .row = f.app.actor_row.copy(mem), .home_rotation = quaternion::IDENTITY, .strips = alloc::clone_slice(mem, (CutStrip[]){ wave }) };
	f.app.replace_cutscene(0, changed);
	open_cutscene_tab(&f);
	test::@check(f.app.show_cutscene(0), "no cutscene to show");
	f.feed(f.ui.input.mouse);

	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	f.click(timeline.absolute + (Vec2){ drawn.x_of(timeline, c, 1.0f), drawn.lane_top(timeline, c, 0, WHAT) + crig::CUT_LANE_H * 0.5f });
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_selected != 0, "the click did not pick the strip");
	f.feed_key(Key.DELETE);
	test::@check(f.app.cutscene().actors[0].strips.len == 0, "Delete did not take the picked strip");
	test::@check(f.app.cut_selected == 0, "the pick outlived its strip");
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().actors[0].strips.len == 1, "undo did not bring the strip back");
}

fn void a_one_off_edit_shows_its_clip_and_back_shows_the_cutscene_again() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	open_cutscene_tab(&f);
	test::@check(f.app.show_cutscene(0), "no cutscene to show");
	f.app.show_cutscene_at(1.0f);
	test::@check(f.app.new_cut_one_off(0) >= 0, "no one-off");
	f.feed(f.ui.input.mouse);

	// Enter on the picked one-off edits it: the dock shows its clip alone, with the way back.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	f.click(timeline.absolute + (Vec2){ drawn.x_of(timeline, c, 2.0f), drawn.lane_top(timeline, c, 0, WHAT) + crig::CUT_LANE_H * 0.5f });
	f.feed(f.ui.input.mouse);
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.one_off_open() && !f.app.cutscene_in_dock(), "Enter did not open the one-off");
	test::@check(has_id(&f, crig::ANIM_BACK_ID) && !has_id(&f, crig::CUT_TIMELINE_ID), "the dock does not show the one-off as a clip");
	Select* chooser = f.ui.find_id("anim-chooser")!!.widget_as(Select);
	test::@check(chooser.options.len == 1 && !chooser_lists_cutscenes(&f), "the chooser lists %d rows while the one-off is edited", chooser.options.len);

	// Back: the cutscene is in the dock again.
	f.click(cut_centre(&f, crig::ANIM_BACK_ID));
	f.feed(f.ui.input.mouse);
	test::@check(!f.app.one_off_open() && f.app.cutscene_in_dock(), "Back did not show the cutscene in the dock");
	test::@check(has_id(&f, crig::CUT_TIMELINE_ID) && has_id(&f, crig::CUT_SIDE_ID), "the dock did not show the cutscene again");
}

fn void no_pane_is_a_cutscene_tab() @test
{
	foreach (view : crig::area_views) test::@check(view.name != "Cutscene", "a pane is still the Cutscene tab");
}

fn void a_scene_with_no_model_still_shows_its_cutscene_in_the_dock() @test
{
	Fixture f;
	f.open({})!!;
	defer f.close();
	(void)f.app.add_cutscene();
	open_cutscene_tab(&f);
	test::@check(chooser_row(&f, "Cutscene · Cutscene") == 0, "the chooser does not offer the cutscene with no model");
	test::@check(chooser_pick(&f, "Cutscene · Cutscene"), "the chooser does not list the cutscene");
	test::@check(f.app.cutscene_in_dock() && has_id(&f, crig::CUT_TIMELINE_ID) && has_id(&f, crig::CUT_SIDE_ID),
		"the dock does not show the cutscene with no model");
}

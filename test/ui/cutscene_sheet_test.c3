<*
 The cutscene sheet and its Pieces bin: pieces clicked and dropped, a play's speed
 and fade dragged, the path, header and strip menus, the Add actor list, and a
 header click retargeting the bin.

     `c3c test --test-filter crig_tests::ui::cut_sheet`
*>
module crig_tests::ui;
import crig;
import crig_tests::helpers;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

const String CUT_SHEET_FOLDER @local = "build/cutscene-sheet";

// The cutscene bin's rows as they are now.
fn PieceEntry[] cut_bin_entries(Fixture* f)
{
	Element* elem = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	// Describing it brings its rows up to date.
	@pool() { (void)elem.describe(); };
	return elem.widget_as(PieceBin).entries;
}

fn bool cut_bin_has(Fixture* f, String label)
{
	foreach (&entry : cut_bin_entries(f)) if (!entry.header && entry.label == label) return true;
	return false;
}

fn bool cut_bin_has_kind(Fixture* f, CutPieceKind kind)
{
	foreach (&entry : cut_bin_entries(f)) if (!entry.header && entry.for_cut && entry.cut.kind == kind) return true;
	return false;
}

// The bin's header or note rows, by their words.
fn bool cut_bin_notes(Fixture* f, String label)
{
	foreach (&entry : cut_bin_entries(f)) if (entry.header && entry.label == label) return true;
	return false;
}

// The middle of the bin's piece `label`, in window pixels, as the agent tools find it.
fn Vec2 cut_bin_row(Fixture* f, String label)
{
	Element* elem = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	Vec2 found;
	bool seen;
	@pool()
	{
		Description d = elem.describe();
		String want = string::tformat("piece-%s", label);
		foreach (part : d.parts)
		{
			if (part.label != want) continue;
			found = elem.absolute + part.pos + part.size * 0.5f;
			seen = true;
			break;
		}
	};
	test::@check(seen, "the bin shows no piece %s", label);
	return found;
}

// Time `t` on a lane of actor `actor`, in window pixels.
fn Vec2 cut_sheet_point(Fixture* f, usz actor, CutLane lane, float t, float down = 0.5f)
{
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	return timeline.absolute + (Vec2){ drawn.x_of(timeline, c, t), drawn.lane_top(timeline, c, actor, lane) + crig::CUT_LANE_H * down };
}

// The middle of actor `actor`'s header; with the actor count, of "+ Add actor".
fn Vec2 cut_sheet_header(Fixture* f, usz actor)
{
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	return timeline.absolute + (Vec2){ drawn.span(timeline).x + 40.0f, drawn.actor_top(timeline, c, actor) + crig::CUT_HEADER_H * 0.5f };
}

// Click the open menu's row `id`.
fn bool cut_sheet_menu_click(Fixture* f, String id)
{
	Element*? row = f.ui.find_id(id);
	if (catch row)
	{
		test::@check(false, "the menu has no %s", id);
		return false;
	}
	f.click(row.absolute + row.size * 0.5f);
	f.feed(f.ui.input.mouse);
	return true;
}

// Whether the open menu's row `id` is greyed out.
fn bool cut_sheet_menu_disabled(Fixture* f, String id)
{
	Element*? row = f.ui.find_id(id);
	if (catch row) return false;
	return row.widget_as(PopupMenuItem).item.disabled;
}

// Click the row of choice list `list_id` whose label or trailing words are `text`.
fn bool cut_sheet_list_pick(Fixture* f, String list_id, String text)
{
	Element*? found = f.ui.find_id(list_id);
	if (catch found) return false;
	Tree* tree = found.widget_as(Tree);
	float row_h = tree.style.resolved().row_height;
	foreach (usz i, row : tree.rows)
	{
		if (row.label != text && row.trailing != text) continue;
		f.click(found.absolute + (Vec2){ found.size.x * 0.5f, ((float)i + 0.5f) * row_h });
		f.feed(f.ui.input.mouse);
		return true;
	}
	return false;
}

fn bool cut_sheet_dialog_open(Fixture* f, String id) @local
{
	Element*? found = f.ui.find_id(id);
	if (catch found) return false;
	return found.widget_as(Dialog).open;
}

// The biped as the actor "hero" in a cutscene, with a clip `clip` one second long.
fn String cut_sheet_hero(Fixture* f, String clip, bool loop = true) @local
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef made = f.app.new_clip(clip, 1.0f, loop: loop);
	test::@check(made.valid(), "no clip %s", clip);
	String name = f.app.clip(made).name.tcopy();
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	return name;
}

fn void cut_sheet_a_path_dropped_is_a_move_and_a_walk_dropped_over_it_pairs() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String walk = cut_sheet_hero(&f, "Walk");
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	(void)f.app.pick_cut_path(-1);
	show_cutscene_tab(&f);
	usz steps = helpers::cut_steps(&f.app);

	// The path dropped on the hero's Path lane at 2 s: a move there that plays nothing, its path picked.
	f.drag(cut_bin_row(&f, "Road"), cut_sheet_point(&f, 0, WHERE, 2.0f));
	f.feed(f.ui.input.mouse);
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 1 && laid[0].kind == MOVE && laid[0].clip.len == 0 && laid[0].path == 0 && math::is_approx(laid[0].start, 2.0f, 1e-4f),
		"the drop laid %d strips", laid.len);
	if (laid.len != 1) return;
	test::eq(helpers::cut_steps(&f.app), steps + 1);
	test::@check(!f.app.piece_drag.active, "the drag outlived the drop");
	test::@check(f.app.cut_path_pick == 1, "the move's path is not picked");
	float move_end = laid[0].end;

	// The walk dropped on its Clip lane over the move: a looping play to the move's end, which pairs with it.
	f.drag(cut_bin_row(&f, walk), cut_sheet_point(&f, 0, WHAT, 2.0f));
	f.feed(f.ui.input.mouse);
	laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 2, "%d strips after the walk", laid.len);
	if (laid.len != 2) return;
	usz play = laid[0].kind == PLAY ? 0 : 1;
	CutStrip* s = &laid[play];
	test::@check(s.kind == PLAY && s.clip == walk && s.loop && math::is_approx(s.start, 2.0f, 1e-4f) && math::is_approx(s.end, move_end, 1e-4f),
		"the walk is %s %f-%f", s.clip, s.start, s.end);
	test::@check(crig::cut_paired_move(laid, play, f.app.cutscene().paths) >= 0, "the walk does not pair with the move");
	test::eq(helpers::cut_steps(&f.app), steps + 2);
	test::@check(has_id(&f, crig::CUT_CARD_GROUND_ID), "the paired walk's card has no ground speed");

	// "+ Add actor" and the ruler take nothing.
	f.drag(cut_bin_row(&f, "Road"), cut_sheet_header(&f, 1));
	f.feed(f.ui.input.mouse);
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	f.drag(cut_bin_row(&f, "Road"), timeline.absolute + (Vec2){ timeline.size.x * 0.5f, crig::TIMELINE_STYLE.ruler_height * 0.5f });
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().actors[0].strips.len == 2, "a drop off the actors laid a strip");
	test::eq(helpers::cut_steps(&f.app), steps + 2);
}

fn void cut_sheet_pieces_clicked_lay_at_the_playhead() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String wave = cut_sheet_hero(&f, "Wave", loop: false);
	show_cutscene_tab(&f);
	test::@check(cut_bin_notes(&f, "Clips · hero"), "the clips are not the hero's");
	usz steps = helpers::cut_steps(&f.app);

	// A clip: one pass of it at the playhead, picked.
	f.app.show_cutscene_at(1.0f);
	f.click(cut_bin_row(&f, wave));
	CutStrip* s = f.app.cut_selected_strip();
	test::@check(s && s.kind == PLAY && s.clip == wave && math::is_approx(s.start, 1.0f, 1e-4f) && math::is_approx(s.end, 2.0f, 1e-4f) && !s.one_off,
		"the clip piece laid no play at the playhead");
	test::eq(helpers::cut_steps(&f.app), steps + 1);

	// + One-off: a new one-off at the playhead, which then is a piece of its own.
	f.app.show_cutscene_at(3.0f);
	f.click(cut_bin_row(&f, "+ One-off"));
	s = f.app.cut_selected_strip();
	test::@check(s && s.one_off && math::is_approx(s.start, 3.0f, 1e-4f), "+ One-off laid no one-off");
	if (!s) return;
	String one = s.clip.tcopy();
	test::eq(helpers::cut_steps(&f.app), steps + 2);
	f.app.show_cutscene_at(6.0f);
	f.click(cut_bin_row(&f, string::tformat("%s%s", one, crig::CUT_ONE_OFF_MARK)));
	s = f.app.cut_selected_strip();
	test::@check(s && s.one_off && s.clip == one && math::is_approx(s.start, 6.0f, 1e-4f), "the one-off piece did not lay it again");
	test::@check(f.app.cutscene().one_offs.len == 1, "laying a one-off again made another");
	test::eq(helpers::cut_steps(&f.app), steps + 3);

	// A path is only picked; + Path draws a new one.
	(void)f.app.add_cut_path("Road");
	(void)f.app.pick_cut_path(-1);
	steps = helpers::cut_steps(&f.app);
	usz strips = f.app.cutscene().actors[0].strips.len;
	f.click(cut_bin_row(&f, "Road"));
	test::@check(f.app.cut_path_pick == 1 && f.app.cutscene().actors[0].strips.len == strips, "the path click laid a strip or picked no path");
	test::eq(helpers::cut_steps(&f.app), steps);
	f.click(cut_bin_row(&f, "+ Path"));
	test::@check(f.app.cut_pick == PATH_KNOT && f.app.cut_path_pick == 2 && f.app.cutscene().paths.len == 2, "+ Path did not start a new path");
	f.app.cancel_cut_pick();

	// Turn opens the list of what to face.
	f.click(cut_bin_row(&f, "Turn"));
	test::@check(cut_sheet_dialog_open(&f, crig::CUT_TURN_MENU_ID), "Turn did not open the turn list");
	f.feed_key(Key.ESCAPE);
}

fn void cut_sheet_alt_dragging_a_plays_end_changes_its_speed_and_holds_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String wave = cut_sheet_hero(&f, "Wave", loop: false);
	show_cutscene_tab(&f);
	test::@check(f.app.add_cut_play(0, wave) == 0, "no play");
	f.feed(f.ui.input.mouse);
	usz steps = helpers::cut_steps(&f.app);

	f.alt_drag(cut_sheet_point(&f, 0, WHAT, 1.0f), cut_sheet_point(&f, 0, WHAT, 2.0f));
	f.feed(f.ui.input.mouse);
	CutStrip* s = &f.app.cutscene().actors[0].strips[0];
	test::@check(math::is_approx(s.end, 2.0f, 1e-4f) && math::is_approx(s.speed, 0.5f, 1e-3f) && s.speed_held,
		"the Alt-drag left %f-%f at %fx, held %s", s.start, s.end, s.speed, s.speed_held);
	test::@check(math::is_approx(s.start, 0.0f, 1e-4f), "the start moved to %f", s.start);
	test::eq(helpers::cut_steps(&f.app), steps + 1);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	s = &f.app.cutscene().actors[0].strips[0];
	test::@check(math::is_approx(s.end, 1.0f, 1e-4f) && math::is_approx(s.speed, 1.0f, 1e-4f) && !s.speed_held, "one undo did not take the whole drag back");

	// A plain drag of the end only trims it.
	f.drag(cut_sheet_point(&f, 0, WHAT, 1.0f), cut_sheet_point(&f, 0, WHAT, 1.5f));
	f.feed(f.ui.input.mouse);
	s = &f.app.cutscene().actors[0].strips[0];
	test::@check(math::is_approx(s.end, 1.5f, 1e-4f) && math::is_approx(s.speed, 1.0f, 1e-4f) && !s.speed_held, "a plain drag changed the speed");
}

fn void cut_sheet_the_fade_handle_drags_a_plays_fade() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String idle = cut_sheet_hero(&f, "Idle");
	show_cutscene_tab(&f);
	test::@check(f.app.add_cut_play(0, idle) == 0, "no play");
	CutStrip longer = f.app.cutscene().actors[0].strips[0].copy(mem);
	longer.end = 2.0f;
	test::@check(f.app.set_cut_strip(0, 0, longer), "the play would not lengthen");
	f.feed(f.ui.input.mouse);
	CutStrip* s = &f.app.cutscene().actors[0].strips[0];
	float fade = s.fade;
	test::@check(fade > 0.0f, "a new play has no fade");
	usz steps = helpers::cut_steps(&f.app);

	// The handle sits on the strip's top edge where its fade ends.
	float top = 4.0f / crig::CUT_LANE_H;
	f.drag(cut_sheet_point(&f, 0, WHAT, fade, top), cut_sheet_point(&f, 0, WHAT, fade + 0.5f, top));
	f.feed(f.ui.input.mouse);
	s = &f.app.cutscene().actors[0].strips[0];
	test::@check(math::is_approx(s.fade, fade + 0.5f, 1e-3f) && math::is_approx(s.start, 0.0f, 1e-4f) && math::is_approx(s.end, 2.0f, 1e-4f),
		"the fade is %f and the strip %f-%f", s.fade, s.start, s.end);
	test::eq(helpers::cut_steps(&f.app), steps + 1);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(math::is_approx(f.app.cutscene().actors[0].strips[0].fade, fade, 1e-4f), "undo did not put the fade back");
}

fn void cut_sheet_the_path_menu_renames_draws_walks_and_deletes() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	(void)cut_sheet_hero(&f, "Walk");
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	(void)f.app.pick_cut_path(-1);
	show_cutscene_tab(&f);
	f.app.show_cutscene_at(1.0f);
	usz steps = helpers::cut_steps(&f.app);

	// A right-click picks the path and opens its menu.
	f.right_click(cut_bin_row(&f, "Road"));
	test::@check(f.app.cut_path_pick == 1, "the right-click did not pick the path");
	foreach (id : (String[]){ crig::CUT_PATH_RENAME_ID, crig::CUT_PATH_DRAW_ID, crig::CUT_PATH_WALK_ID, crig::CUT_PATH_DELETE_ID })
	{
		test::@check(has_id(&f, id), "the path menu has no %s", id);
	}

	// Rename…: one dialog, its field showing the name; Return renames.
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_RENAME_ID);
	test::@check(cut_sheet_dialog_open(&f, crig::CUT_RENAME_DIALOG_ID), "Rename… opened no dialog");
	Element* field = f.ui.find_id(crig::CUT_PATH_NAME_ID)!!;
	test::eq(field.widget_as(TextField).text.str_view(), "Road");
	type_field(&f, crig::CUT_PATH_NAME_ID, "Round");
	test::@check(f.app.cutscene().paths[0].name == "Round", "the path is called %s", f.app.cutscene().paths[0].name);
	test::@check(!cut_sheet_dialog_open(&f, crig::CUT_RENAME_DIALOG_ID), "the dialog stayed open");
	test::eq(helpers::cut_steps(&f.app), steps + 1);

	// Walk here: a move and a walk over it from the playhead, one step.
	f.right_click(cut_bin_row(&f, "Round"));
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_WALK_ID);
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 2 && laid[0].kind == MOVE && laid[0].path == 0 && laid[1].kind == PLAY && math::is_approx(laid[0].start, 1.0f, 1e-4f),
		"Walk here laid %d strips", laid.len);
	test::eq(helpers::cut_steps(&f.app), steps + 2);

	// Draw more: ground clicks extend it.
	f.right_click(cut_bin_row(&f, "Round"));
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_DRAW_ID);
	test::@check(f.app.cut_pick == PATH_KNOT && f.app.cut_path_pick == 1, "Draw more did not draw the path");
	f.app.cancel_cut_pick();

	// Delete: the path goes, and the move walks nothing.
	f.right_click(cut_bin_row(&f, "Round"));
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_DELETE_ID);
	test::@check(f.app.cutscene().paths.len == 0 && f.app.cutscene().actors[0].strips[0].path < 0, "Delete kept the path");
	test::@check(!cut_bin_has_kind(&f, PATH), "the bin still offers the path");
	test::eq(helpers::cut_steps(&f.app), steps + 3);
}

fn void cut_sheet_actors_are_added_retargeted_and_edited_from_their_headers() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	(void)f.app.add_cutscene();
	show_cutscene_tab(&f);
	test::@check(f.app.cutscene().actors.len == 0, "a cutscene with actors already");

	// "+ Add actor": from a file, or the cube, which is no actor yet.
	f.click(cut_sheet_header(&f, 0));
	test::@check(cut_sheet_dialog_open(&f, crig::CUT_ADD_ACTOR_MENU_ID), "+ Add actor opened no list");
	Tree* list = f.ui.find_id(crig::CUT_ACTOR_LIST_ID)!!.widget_as(Tree);
	test::@check(list.rows.len == 2 && list.rows[0].label == "From a file…", "the list has %d rows", list.rows.len);
	test::@check(cut_sheet_list_pick(&f, crig::CUT_ACTOR_LIST_ID, "no actor · make one"), "the cube is not offered");
	test::@check(f.app.actor_row.len > 0 && f.app.cutscene().actors.len == 1, "the cube is no actor of the cutscene");
	test::@check(f.app.cut_target_actor() == 0, "the new actor is not the one pieces go to");
	String row = f.app.actor_row.tcopy();

	// A second actor no character plays; a header click retargets the bin.
	Cutscene two = f.app.cutscene().copy(mem);
	CutActor[] actors = alloc::new_array(mem, CutActor, 2);
	actors[0] = two.actors[0];
	actors[1] = { .row = "guide".copy(mem), .home_rotation = quaternion::IDENTITY };
	free(two.actors);
	two.actors = actors;
	f.app.replace_cutscene(0, two);
	f.feed(f.ui.input.mouse);
	f.click(cut_sheet_header(&f, 1));
	test::@check(f.app.cut_lane_actor == 2 && f.app.cut_target_actor() == 1, "the header did not retarget");
	test::@check(cut_bin_notes(&f, "Clips · guide") && cut_bin_notes(&f, "no clips"), "the bin does not list the guide's clips");
	f.click(cut_sheet_header(&f, 0));
	test::@check(cut_bin_notes(&f, string::tformat("Clips · %s", row)), "the bin does not list the cube's clips again");

	// The guide's header menu: nothing to do without a character.
	f.right_click(cut_sheet_header(&f, 1));
	test::@check(cut_sheet_dialog_open(&f, crig::CUT_ACTOR_MENU_ID) && f.app.cut_target_actor() == 1, "no menu for the guide");
	test::@check(cut_sheet_menu_disabled(&f, crig::CUT_ACTOR_RENAME_ID) && cut_sheet_menu_disabled(&f, crig::CUT_ACTOR_REMOVE_ID),
		"the guide's rows work without a character");
	f.feed_key(Key.ESCAPE);

	// The cube's: no own file outside a level; the ground needs a level.
	f.right_click(cut_sheet_header(&f, 0));
	test::@check(!has_id(&f, crig::CUT_ACTOR_OWN_FILE_ID) && has_id(&f, crig::CUT_ACTOR_GROUND_ID), "the cube's menu");
	(void)cut_sheet_menu_click(&f, crig::CUT_ACTOR_GROUND_ID);
	test::@check(f.notice_text().contains("no level ground"), "Drop onto ground said %s", f.notice_text());

	// Rename row…: the dialog's row field renames it in the cutscene.
	f.right_click(cut_sheet_header(&f, 0));
	(void)cut_sheet_menu_click(&f, crig::CUT_ACTOR_RENAME_ID);
	Element* field = f.ui.find_id(crig::CUT_ROW_ID)!!;
	test::eq(field.widget_as(TextField).text.str_view(), row);
	type_field(&f, crig::CUT_ROW_ID, "lead");
	test::@check(f.app.actor_row == "lead" && f.app.cutscene().actors[0].row == "lead", "the row is %s", f.app.cutscene().actors[0].row);

	// Remove: a second actor from a file goes out of the scene and the cutscene.
	(void)path::mkdir(CUT_SHEET_FOLDER, true);
	String extra = CUT_SHEET_FOLDER.tconcat("/second.glb");
	char[] bytes = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer free(bytes);
	(void)file::save(extra, bytes);
	test::@check(f.app.add_actor_from_file(extra, "second"), "no second actor");
	f.feed(f.ui.input.mouse);
	test::@check(f.app.character_count() == 2 && f.app.cutscene().actors.len == 3, "the second actor is not in the cutscene");
	f.right_click(cut_sheet_header(&f, 2));
	(void)cut_sheet_menu_click(&f, crig::CUT_ACTOR_REMOVE_ID);
	test::@check(f.app.character_count() == 1 && f.app.cutscene().actors.len == 2, "Remove kept the second actor");
}

fn void cut_sheet_the_strip_menu_deletes_and_edits_a_one_off() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String wave = cut_sheet_hero(&f, "Wave", loop: false);
	show_cutscene_tab(&f);
	f.app.show_cutscene_at(1.0f);
	test::@check(f.app.new_cut_one_off(0) >= 0, "no one-off");
	f.app.show_cutscene_at(4.0f);
	test::@check(f.app.add_cut_play(0, wave) >= 0, "no play");
	f.feed(f.ui.input.mouse);
	usz steps = helpers::cut_steps(&f.app);

	// A plain play: picked by the right-click, no one-off to edit; Delete takes it.
	f.right_click(cut_sheet_point(&f, 0, WHAT, 4.5f));
	CutStrip* s = f.app.cut_selected_strip();
	test::@check(s && s.clip == wave && cut_sheet_dialog_open(&f, crig::CUT_STRIP_MENU_ID), "the right-click did not pick the play");
	test::@check(cut_sheet_menu_disabled(&f, crig::CUT_STRIP_EDIT_ID) && !cut_sheet_menu_disabled(&f, crig::CUT_STRIP_DELETE_ID),
		"Edit one-off is offered for a plain play");
	(void)cut_sheet_menu_click(&f, crig::CUT_STRIP_DELETE_ID);
	test::@check(f.app.cutscene().actors[0].strips.len == 1, "Delete kept the play");
	test::eq(helpers::cut_steps(&f.app), steps + 1);

	// The one-off's strip: Edit one-off opens it.
	f.right_click(cut_sheet_point(&f, 0, WHAT, 2.0f));
	test::@check(!cut_sheet_menu_disabled(&f, crig::CUT_STRIP_EDIT_ID), "Edit one-off is greyed out for a one-off");
	(void)cut_sheet_menu_click(&f, crig::CUT_STRIP_EDIT_ID);
	test::@check(f.app.one_off_open(), "Edit one-off did not open it");
	(void)f.app.back_to_cutscene();
	f.feed(f.ui.input.mouse);
}

// The bin's part `piece-<label>`, element-local, when it is in view.
fn bool cut_bin_part(Fixture* f, String label, Vec2* at, Vec2* size) @local
{
	Element* elem = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	bool seen;
	@pool()
	{
		Description d = elem.describe();
		String want = string::tformat("piece-%s", label);
		foreach (part : d.parts)
		{
			if (part.label != want) continue;
			*at = part.pos;
			*size = part.size;
			seen = true;
			break;
		}
	};
	return seen;
}

fn void cut_sheet_the_bins_rows_scroll_under_the_wheel() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String walk = cut_sheet_hero(&f, "Walk");
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	(void)f.app.pick_cut_path(-1);
	show_cutscene_tab(&f);
	Vec2 at;
	Vec2 size;
	test::@check(cut_bin_part(&f, "Road", &at, &size) && cut_bin_part(&f, walk, &at, &size), "the path or the clip is out of view");

	// A dozen paths more than fit: the clip goes out of view, and the wheel brings it back up.
	for (int i = 0; i < 12; i++) (void)f.app.add_cut_path(string::tformat("Spare %d", i));
	(void)f.app.pick_cut_path(-1);
	f.feed(f.ui.input.mouse);
	(void)cut_bin_entries(&f);
	// The dock was built again for the new paths.
	Element* elem = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	PieceBin* bin = elem.widget_as(PieceBin);
	test::@check(!cut_bin_part(&f, walk, &at, &size), "the clip is in view under a dozen paths");
	Vec2 over = elem.absolute + (Vec2){ elem.size.x * 0.5f, elem.size.y * 0.5f };
	for (int i = 0; i < 12; i++) f.ui.wheel(over, -1.0f);
	test::@check(cut_bin_part(&f, walk, &at, &size), "the wheel did not bring the clip into view: %d rows in %f px, scrolled %f",
		bin.rows, elem.size.y, bin.scroll);
	test::@check(cut_bin_part(&f, "+ Path", &at, &size) && at.y == 0.0f, "the cells scrolled away");
}

fn void cut_sheet_the_clips_header_opens_the_targets_clips_in_assets() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	(void)cut_sheet_hero(&f, "Walk");
	usz hero = f.app.active;
	(void)path::mkdir(CUT_SHEET_FOLDER, true);
	String extra = CUT_SHEET_FOLDER.tconcat("/browsing.glb");
	char[] bytes = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer free(bytes);
	(void)file::save(extra, bytes);
	test::@check(f.app.add_actor_from_file(extra, "newcomer"), "no second actor");
	usz newcomer = f.app.active;
	test::@check(f.app.focus_character(hero), "the hero did not take the focus back");
	show_cutscene_tab(&f);
	test::@check(!f.in_tree(crig::ASSETS_GRID_ID), "the Assets pane is up already");

	// The newcomer's lane name makes him the target; the hero stays the focus.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	f.click({ timeline.absolute.x + crig::CUT_GUTTER_W * 0.5f, cut_sheet_point(&f, 1, WHAT, 0.0f).y });
	test::@check(f.app.cut_target_actor() == 1 && f.app.active == hero, "the lane name made %d the target, %d the focus",
		f.app.cut_target_actor(), f.app.active);
	test::@check(cut_bin_notes(&f, "Clips · newcomer"), "the clips are not the newcomer's");

	// A click: the newcomer takes the focus, and the Assets pane, beside the sheet, shows his group.
	f.click(cut_bin_row(&f, "to-assets"));
	f.ui.flush();
	f.feed(f.ui.input.mouse);
	test::@check(f.app.active == newcomer, "the focus is %d, not the newcomer", f.app.active);
	test::@check(f.in_tree(crig::ASSETS_GRID_ID), "the Assets pane is not up");
	crig::AssetFilter shown = f.app.asset_filter;
	test::@check(shown.current_file && !shown.any_kind && shown.kind == ANIMATION, "the Assets pane is not narrowed to his group");
	test::@check(f.in_tree(crig::CUT_TIMELINE_ID) && f.app.cut_target_actor() == 1, "the sheet went, or the newcomer is not the target");
}

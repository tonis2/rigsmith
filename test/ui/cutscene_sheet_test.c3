<*
 The cutscene sheet and its Pieces bin: pieces clicked and dropped, a play's speed
 and fade dragged, the path, header and strip menus, the Add actor list, and a
 header click retargeting the bin.

     `c3c test --test-filter crig_tests::ui::cut_sheet`
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

const String CUT_SHEET_FOLDER @local = "build/cutscene-sheet";

// The Animations dock in a pane under the model, showing the first cutscene, one frame later.
fn void cut_sheet_tab(Fixture* f) @local
{
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	(void)f.app.show_cutscene(0);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

fn usz cut_sheet_steps(Fixture* f) @local => (usz)f.app.cut_history.undo.len();

fn bool cut_sheet_near(float a, float b, float eps = 1e-4f) @local => math::abs(a - b) <= eps;

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

// Type `text` into field `id`, replacing what it shows, and press Return.
fn void cut_sheet_type(Fixture* f, String id, String text) @local
{
	Element* field = f.ui.find_id(id)!!;
	field.widget_as(TextField).set_text(field, "");
	f.type_into(field, text);
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
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
	cut_sheet_tab(&f);
	usz steps = cut_sheet_steps(&f);

	// The path dropped on the hero's Path lane at 2 s: a move there that plays nothing, its path picked.
	f.drag(cut_bin_row(&f, "Road"), cut_sheet_point(&f, 0, WHERE, 2.0f));
	f.feed(f.ui.input.mouse);
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 1 && laid[0].kind == MOVE && laid[0].clip.len == 0 && laid[0].path == 0 && cut_sheet_near(laid[0].start, 2.0f),
		"the drop laid %d strips", laid.len);
	if (laid.len != 1) return;
	test::eq(cut_sheet_steps(&f), steps + 1);
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
	test::@check(s.kind == PLAY && s.clip == walk && s.loop && cut_sheet_near(s.start, 2.0f) && cut_sheet_near(s.end, move_end),
		"the walk is %s %f-%f", s.clip, s.start, s.end);
	test::@check(crig::cut_paired_move(laid, play, f.app.cutscene().paths) >= 0, "the walk does not pair with the move");
	test::eq(cut_sheet_steps(&f), steps + 2);
	test::@check(has_id(&f, crig::CUT_CARD_GROUND_ID), "the paired walk's card has no ground speed");

	// "+ Add actor" and the ruler take nothing.
	f.drag(cut_bin_row(&f, "Road"), cut_sheet_header(&f, 1));
	f.feed(f.ui.input.mouse);
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	f.drag(cut_bin_row(&f, "Road"), timeline.absolute + (Vec2){ timeline.size.x * 0.5f, crig::TIMELINE_STYLE.ruler_height * 0.5f });
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cutscene().actors[0].strips.len == 2, "a drop off the actors laid a strip");
	test::eq(cut_sheet_steps(&f), steps + 2);
}

fn void cut_sheet_pieces_clicked_lay_at_the_playhead() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String wave = cut_sheet_hero(&f, "Wave", loop: false);
	cut_sheet_tab(&f);
	test::@check(cut_bin_notes(&f, "Clips · hero"), "the clips are not the hero's");
	usz steps = cut_sheet_steps(&f);

	// A clip: one pass of it at the playhead, picked.
	f.app.show_cutscene_at(1.0f);
	f.click(cut_bin_row(&f, wave));
	CutStrip* s = f.app.cut_selected_strip();
	test::@check(s && s.kind == PLAY && s.clip == wave && cut_sheet_near(s.start, 1.0f) && cut_sheet_near(s.end, 2.0f) && !s.one_off,
		"the clip piece laid no play at the playhead");
	test::eq(cut_sheet_steps(&f), steps + 1);

	// + One-off: a new one-off at the playhead, which then is a piece of its own.
	f.app.show_cutscene_at(3.0f);
	f.click(cut_bin_row(&f, "+ One-off"));
	s = f.app.cut_selected_strip();
	test::@check(s && s.one_off && cut_sheet_near(s.start, 3.0f), "+ One-off laid no one-off");
	if (!s) return;
	String one = s.clip.tcopy();
	test::eq(cut_sheet_steps(&f), steps + 2);
	f.app.show_cutscene_at(6.0f);
	f.click(cut_bin_row(&f, string::tformat("%s%s", one, crig::CUT_ONE_OFF_MARK)));
	s = f.app.cut_selected_strip();
	test::@check(s && s.one_off && s.clip == one && cut_sheet_near(s.start, 6.0f), "the one-off piece did not lay it again");
	test::@check(f.app.cutscene().one_offs.len == 1, "laying a one-off again made another");
	test::eq(cut_sheet_steps(&f), steps + 3);

	// A path is only picked; + Path draws a new one.
	(void)f.app.add_cut_path("Road");
	(void)f.app.pick_cut_path(-1);
	steps = cut_sheet_steps(&f);
	usz strips = f.app.cutscene().actors[0].strips.len;
	f.click(cut_bin_row(&f, "Road"));
	test::@check(f.app.cut_path_pick == 1 && f.app.cutscene().actors[0].strips.len == strips, "the path click laid a strip or picked no path");
	test::eq(cut_sheet_steps(&f), steps);
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
	cut_sheet_tab(&f);
	test::@check(f.app.add_cut_play(0, wave) == 0, "no play");
	f.feed(f.ui.input.mouse);
	usz steps = cut_sheet_steps(&f);

	f.alt_drag(cut_sheet_point(&f, 0, WHAT, 1.0f), cut_sheet_point(&f, 0, WHAT, 2.0f));
	f.feed(f.ui.input.mouse);
	CutStrip* s = &f.app.cutscene().actors[0].strips[0];
	test::@check(cut_sheet_near(s.end, 2.0f) && cut_sheet_near(s.speed, 0.5f, 1e-3f) && s.speed_held,
		"the Alt-drag left %f-%f at %fx, held %s", s.start, s.end, s.speed, s.speed_held);
	test::@check(cut_sheet_near(s.start, 0.0f), "the start moved to %f", s.start);
	test::eq(cut_sheet_steps(&f), steps + 1);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	s = &f.app.cutscene().actors[0].strips[0];
	test::@check(cut_sheet_near(s.end, 1.0f) && cut_sheet_near(s.speed, 1.0f) && !s.speed_held, "one undo did not take the whole drag back");

	// A plain drag of the end only trims it.
	f.drag(cut_sheet_point(&f, 0, WHAT, 1.0f), cut_sheet_point(&f, 0, WHAT, 1.5f));
	f.feed(f.ui.input.mouse);
	s = &f.app.cutscene().actors[0].strips[0];
	test::@check(cut_sheet_near(s.end, 1.5f) && cut_sheet_near(s.speed, 1.0f) && !s.speed_held, "a plain drag changed the speed");
}

fn void cut_sheet_the_fade_handle_drags_a_plays_fade() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String idle = cut_sheet_hero(&f, "Idle");
	cut_sheet_tab(&f);
	test::@check(f.app.add_cut_play(0, idle) == 0, "no play");
	CutStrip longer = f.app.cutscene().actors[0].strips[0].copy(mem);
	longer.end = 2.0f;
	test::@check(f.app.set_cut_strip(0, 0, longer), "the play would not lengthen");
	f.feed(f.ui.input.mouse);
	CutStrip* s = &f.app.cutscene().actors[0].strips[0];
	float fade = s.fade;
	test::@check(fade > 0.0f, "a new play has no fade");
	usz steps = cut_sheet_steps(&f);

	// The handle sits on the strip's top edge where its fade ends.
	float top = 4.0f / crig::CUT_LANE_H;
	f.drag(cut_sheet_point(&f, 0, WHAT, fade, top), cut_sheet_point(&f, 0, WHAT, fade + 0.5f, top));
	f.feed(f.ui.input.mouse);
	s = &f.app.cutscene().actors[0].strips[0];
	test::@check(cut_sheet_near(s.fade, fade + 0.5f, 1e-3f) && cut_sheet_near(s.start, 0.0f) && cut_sheet_near(s.end, 2.0f),
		"the fade is %f and the strip %f-%f", s.fade, s.start, s.end);
	test::eq(cut_sheet_steps(&f), steps + 1);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(cut_sheet_near(f.app.cutscene().actors[0].strips[0].fade, fade), "undo did not put the fade back");
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
	cut_sheet_tab(&f);
	f.app.show_cutscene_at(1.0f);
	usz steps = cut_sheet_steps(&f);

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
	cut_sheet_type(&f, crig::CUT_PATH_NAME_ID, "Round");
	test::@check(f.app.cutscene().paths[0].name == "Round", "the path is called %s", f.app.cutscene().paths[0].name);
	test::@check(!cut_sheet_dialog_open(&f, crig::CUT_RENAME_DIALOG_ID), "the dialog stayed open");
	test::eq(cut_sheet_steps(&f), steps + 1);

	// Walk here: a move and a walk over it from the playhead, one step.
	f.right_click(cut_bin_row(&f, "Round"));
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_WALK_ID);
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 2 && laid[0].kind == MOVE && laid[0].path == 0 && laid[1].kind == PLAY && cut_sheet_near(laid[0].start, 1.0f),
		"Walk here laid %d strips", laid.len);
	test::eq(cut_sheet_steps(&f), steps + 2);

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
	test::eq(cut_sheet_steps(&f), steps + 3);
}

fn void cut_sheet_actors_are_added_retargeted_and_edited_from_their_headers() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	(void)f.app.add_cutscene();
	cut_sheet_tab(&f);
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
	cut_sheet_type(&f, crig::CUT_ROW_ID, "lead");
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
	cut_sheet_tab(&f);
	f.app.show_cutscene_at(1.0f);
	test::@check(f.app.new_cut_one_off(0) >= 0, "no one-off");
	f.app.show_cutscene_at(4.0f);
	test::@check(f.app.add_cut_play(0, wave) >= 0, "no play");
	f.feed(f.ui.input.mouse);
	usz steps = cut_sheet_steps(&f);

	// A plain play: picked by the right-click, no one-off to edit; Delete takes it.
	f.right_click(cut_sheet_point(&f, 0, WHAT, 4.5f));
	CutStrip* s = f.app.cut_selected_strip();
	test::@check(s && s.clip == wave && cut_sheet_dialog_open(&f, crig::CUT_STRIP_MENU_ID), "the right-click did not pick the play");
	test::@check(cut_sheet_menu_disabled(&f, crig::CUT_STRIP_EDIT_ID) && !cut_sheet_menu_disabled(&f, crig::CUT_STRIP_DELETE_ID),
		"Edit one-off is offered for a plain play");
	(void)cut_sheet_menu_click(&f, crig::CUT_STRIP_DELETE_ID);
	test::@check(f.app.cutscene().actors[0].strips.len == 1, "Delete kept the play");
	test::eq(cut_sheet_steps(&f), steps + 1);

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

fn void cut_sheet_the_bins_actions_are_icon_cells_and_its_rows_scroll_with_an_indicator() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String walk = cut_sheet_hero(&f, "Walk");
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	(void)f.app.pick_cut_path(-1);
	cut_sheet_tab(&f);
	Element* elem = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	PieceBin* bin = elem.widget_as(PieceBin);

	// + Path, Turn and + One-off: cells side by side by the title, each with its tooltip.
	float left = -1.0f;
	foreach (label : (String[]){ "+ Path", "Turn", "+ One-off" })
	{
		Vec2 at;
		Vec2 size;
		test::@check(cut_bin_part(&f, label, &at, &size), "no %s cell", label);
		test::@check(at.y == 0.0f && size.y <= crig::PIECE_ROW_H && size.x <= crig::PIECE_CELL_W && at.x > left,
			"%s is %f wide at %f, %f", label, size.x, at.x, at.y);
		left = at.x;
		String tip = crig::piece_bin_tip(elem.parent, elem.absolute + at + size * 0.5f);
		test::@check(tip.starts_with(label), "%s's tooltip is '%s'", label, tip);
	}
	test::@check(crig::piece_bin_tip(elem.parent, elem.absolute + (Vec2){ 4.0f, crig::PIECE_ROW_H * 0.5f }).len == 0, "the title has a tooltip");

	// The path and the hero's clip are rows under them, both in view; a cell click still lays.
	Vec2 at;
	Vec2 size;
	test::@check(cut_bin_part(&f, "Road", &at, &size) && cut_bin_part(&f, walk, &at, &size), "the path or the clip is out of view");
	test::@check(!bin.overflows(elem), "a bin of %d rows overflows %f px", bin.rows, elem.size.y);
	f.click(cut_bin_row(&f, "Turn"));
	test::@check(cut_sheet_dialog_open(&f, crig::CUT_TURN_MENU_ID), "the Turn cell did not open the turn list");
	f.feed_key(Key.ESCAPE);

	// A dozen paths more than fit: the bin says it scrolls, and the wheel brings the clip back up.
	for (int i = 0; i < 12; i++) (void)f.app.add_cut_path(string::tformat("Spare %d", i));
	(void)f.app.pick_cut_path(-1);
	f.feed(f.ui.input.mouse);
	(void)cut_bin_entries(&f);
	// The dock was built again for the new paths.
	elem = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	bin = elem.widget_as(PieceBin);
	test::@check(bin.overflows(elem), "%d rows in %f px do not overflow", bin.rows, elem.size.y);
	test::@check(!cut_bin_part(&f, walk, &at, &size), "the clip is in view under a dozen paths");
	Vec2 over = elem.absolute + (Vec2){ elem.size.x * 0.5f, elem.size.y * 0.5f };
	for (int i = 0; i < 12; i++) f.ui.wheel(over, -1.0f);
	test::@check(cut_bin_part(&f, walk, &at, &size), "the wheel did not bring the clip into view: %d rows in %f px, scrolled %f",
		bin.rows, elem.size.y, bin.scroll);
	test::@check(cut_bin_part(&f, "+ Path", &at, &size) && at.y == 0.0f, "the cells scrolled away");
}

fn void cut_sheet_the_add_actor_list_is_wide_enough_for_its_names() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	(void)f.app.add_cutscene();
	(void)path::mkdir(CUT_SHEET_FOLDER, true);
	String long_name = CUT_SHEET_FOLDER.tconcat("/a_wanderer_with_a_rather_long_name.glb");
	char[] bytes = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer free(bytes);
	(void)file::save(long_name, bytes);
	rig::TriMesh? mesh = rig::load_gltf(mem, long_name);
	if (catch mesh)
	{
		test::@check(false, "the copy could not be read");
		return;
	}
	(void)f.app.add_character(mesh, long_name);
	cut_sheet_tab(&f);

	f.click(cut_sheet_header(&f, 0));
	Element* found = f.ui.find_id(crig::CUT_ACTOR_LIST_ID)!!;
	Tree* list = found.widget_as(Tree);
	TreeStyle style = list.style.resolved();
	float widest;
	foreach (row : list.rows)
	{
		float need = 2.0f * style.padding + f.ui.text.measure(0, row.label, style.text_size).x
			+ (row.trailing.len > 0 ? f.ui.text.measure(0, row.trailing, style.text_size).x + 8.0f : 0.0f);
		widest = math::max(widest, need);
	}
	test::@check(widest > crig::CUT_MENU_W, "no row is wider than the old list, %f", widest);
	test::@check(found.size.x >= widest && found.size.x <= crig::CUT_MENU_MOST_W, "the list is %f wide for rows of %f", found.size.x, widest);
	test::@check(found.absolute.x + found.size.x <= f.ui.size.x, "the list runs off the window");
	f.feed_key(Key.ESCAPE);
}

// Whether field `id` of the card has `text` beside it in the row they share: before it, or after.
fn bool cut_sheet_beside(Fixture* f, String id, String text, bool before) @local
{
	Element* field = f.ui.find_id(id)!!;
	Element* row = field.parent;
	while (row && !row.is_widget(Row)) row = row.parent;
	if (!row) return false;
	foreach (child : row.children)
	{
		if (!child.is_widget(Label) || child.widget_as(Label).text != text) continue;
		float mid = child.absolute.y + child.size.y * 0.5f;
		bool level = math::abs(mid - (field.absolute.y + field.size.y * 0.5f)) <= 3.0f;
		bool placed = before ? child.absolute.x + child.size.x <= field.absolute.x + 1.0f : child.absolute.x >= field.absolute.x + field.size.x - 1.0f;
		return level && placed;
	}
	return false;
}

fn void cut_sheet_the_walks_card_keeps_each_label_by_its_field() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	(void)cut_sheet_hero(&f, "Walk");
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	cut_sheet_tab(&f);
	f.app.show_cutscene_at(1.0f);
	test::@check(f.app.walk_cut_path(0, 0) == 0, "Walk here");
	f.feed(f.ui.input.mouse);
	f.feed(f.ui.input.mouse);
	test::@check(has_id(&f, crig::CUT_CARD_GROUND_ID), "the walk's card is not up");
	test::@check(cut_sheet_beside(&f, crig::CUT_CARD_FADE_ID, "fade", true), "fade is not before its field");
	test::@check(cut_sheet_beside(&f, crig::CUT_CARD_OFFSET_ID, "offset", true), "offset is not before its field");
	test::@check(cut_sheet_beside(&f, crig::CUT_CARD_SPEED_ID, "×", false), "× is not after the speed");
	test::@check(cut_sheet_beside(&f, crig::CUT_CARD_GROUND_ID, "m/s", false), "m/s is not after the ground speed");
	test::@check(cut_sheet_beside(&f, crig::CUT_CARD_END_ID, "s", false), "s is not after the end");
}

// Whether the timeline names part `label`.
fn bool cut_timeline_has_part(Fixture* f, String label) @local
{
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	bool seen;
	@pool()
	{
		Description d = timeline.describe();
		foreach (part : d.parts) seen = seen || part.label == label;
	};
	return seen;
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
	cut_sheet_tab(&f);
	test::@check(!f.in_tree(crig::ASSETS_GRID_ID), "the Assets pane is up already");

	// The newcomer's lane name makes him the target; the hero stays the focus.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	f.click({ timeline.absolute.x + crig::CUT_GUTTER_W * 0.5f, cut_sheet_point(&f, 1, WHAT, 0.0f).y });
	test::@check(f.app.cut_target_actor() == 1 && f.app.active == hero, "the lane name made %d the target, %d the focus",
		f.app.cut_target_actor(), f.app.active);
	test::@check(cut_timeline_has_part(&f, "cut-clip-hint-1") && !cut_timeline_has_part(&f, "cut-clip-hint-0"),
		"the hint is not on the target's empty Clip lane alone");

	// The header keeps its words and ends in a cell with its tooltip.
	test::@check(cut_bin_notes(&f, "Clips · newcomer"), "the clips are not the newcomer's");
	Vec2 at;
	Vec2 size;
	test::@check(cut_bin_part(&f, "to-assets", &at, &size), "the clips' header has no cell");
	Element* bin = f.ui.find_id(crig::CUT_PIECE_BIN_ID)!!;
	test::eq(crig::piece_bin_tip(bin.parent, bin.absolute + at + size * 0.5f), "More clips: drag one from the Assets pane onto a Clip lane");
	test::@check(crig::piece_bin_tip(bin.parent, bin.absolute + (Vec2){ 8.0f, at.y + size.y * 0.5f }).len == 0, "the header's words have a tooltip");

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

fn void cut_sheet_an_empty_clip_lane_says_drag_a_clip_here() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String walk = cut_sheet_hero(&f, "Walk");
	cut_sheet_tab(&f);
	test::@check(f.app.cut_target_actor() == 0, "the hero is not the target");
	test::@check(cut_timeline_has_part(&f, "cut-clip-hint-0"), "the hero's empty Clip lane has no hint");

	// A drag over the lane shows where it lands instead.
	Vec2 from = cut_bin_row(&f, walk);
	Vec2 to = cut_sheet_point(&f, 0, WHAT, 1.0f);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(to, left: true);
	test::@check(f.app.piece_drag.active, "the walk is not being dragged");
	test::@check(!cut_timeline_has_part(&f, "cut-clip-hint-0"), "the hint stayed under the drag");

	// Laid, the hero plays it, and the hint is gone.
	f.feed(to);
	f.feed(f.ui.input.mouse);
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 1 && laid[0].kind == PLAY, "the drop laid %d strips", laid.len);
	test::@check(!cut_timeline_has_part(&f, "cut-clip-hint-0"), "the hint outlived the play");
}

<*
 A clip dragged out of the Assets pane onto a cutscene actor's Clip lane lays a
 play there: one he has, or one bound to him first, the binding its own undo step.
 A level actor, a clip named like one he has and a drop off the lanes lay nothing.

     `c3c test --test-filter cut_drop`
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import crig_tests::library;
import std::core::test;
import std::io::file;
import std::io::path;
import std::math;

const String CUT_DROP_FOLDER @local = "build/cutscene-asset-drop";

fn usz cut_drop_steps(Fixture* f) @local => (usz)f.app.cut_history.undo.len();

fn usz cut_drop_strips(Fixture* f, usz actor) @local => f.app.cutscene().actors[actor].strips.len;

fn bool cut_drop_near(float a, float b, float eps = 1e-3f) @local => math::abs(a - b) <= eps;

// The cube in the biped as actor "hero", in a cutscene with a road and a move on it
// from 1 s; the Animations dock under the model shows it, the Assets pane beside the
// model the clips.
fn void cut_drop_open(Fixture* f) @local
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	(void)f.app.pick_cut_path(-1);
	f.app.show_cutscene_at(1.0f);
	test::@check(f.app.add_cut_move(0, 0) == 0, "no move");
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	crig::show_pane_view(f.ui, crig::LIBRARY_VIEW, SplitAxis.HORIZONTAL, 0.5f);
	(void)f.app.show_cutscene(0);
	crig::AssetFilter only = crig::ALL_ASSETS;
	only.any_kind = false;
	only.kind = ANIMATION;
	(void)f.app.set_asset_filter(only);
	cut_drop_settle(f);
	test::@check(f.app.cutscene_in_dock() && f.in_tree(crig::CUT_TIMELINE_ID), "the cutscene is not in the dock");
}

fn void cut_drop_settle(Fixture* f) @local
{
	f.app.refresh_ui();
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

// A copy of `source` in the test folder; the caller deletes it.
fn String cut_drop_copy(String source, String name) @local
{
	(void)path::mkdir(CUT_DROP_FOLDER, true);
	String copy = string::tformat("%s/%s", CUT_DROP_FOLDER, name);
	char[] bytes = file::load(mem, source)!!;
	defer free(bytes);
	file::save(copy, bytes)!!;
	return copy;
}

// Whether a press at `at` reaches `elem`.
fn bool cut_drop_reaches(Fixture* f, Element* elem, Vec2 at) @local
{
	for (Element* e = f.ui.hit_test(at); e; e = e.parent)
	{
		if (e == elem) return true;
	}
	return false;
}

// The cell showing the library humanoid's clip `name`, when a press reaches it, or null.
fn Element* cut_drop_cell(Fixture* f, String name) @local
{
	Element* found = null;
	f.ui.@each(crig::AssetCell; cell)
	{
		usz row = cell.widget_as(crig::AssetCell).row;
		crig::AssetEntry* e = f.app.visible_asset(row);
		if (!found && e && e.kind == crig::AssetKind.ANIMATION && e.library >= 0 && e.name == name
			&& e.file.ends_with("humanoid.glb") && !f.app.asset_flags(row).disabled
			&& cut_drop_reaches(f, cell, cell.absolute + cell.size * 0.5f)) found = cell;
	};
	test::@check(found != null, "no %s cell in reach", name);
	return found;
}

// The clip a cell shows, copied; the caller frees it.
fn crig::AssetClip cut_drop_clip_of(Fixture* f, Element* cell) @local
{
	return crig::asset_clip_of(f.app.visible_asset(cell.widget_as(crig::AssetCell).row), mem);
}

// Time `t` on actor `actor`'s Clip lane, in window pixels, checked to be on the sheet.
fn Vec2 cut_drop_at(Fixture* f, usz actor, float t) @local
{
	Vec2 at = cut_sheet_point(f, actor, WHAT, t);
	test::@check(cut_drop_reaches(f, f.ui.find_id(crig::CUT_TIMELINE_ID)!!, at), "actor %d's Clip lane at %f s is not on the sheet", actor, t);
	return at;
}

// Press the clip `name`'s cell, move past the slop and let go at `to`.
fn void cut_drop_drag(Fixture* f, String name, Vec2 to) @local
{
	Element* cell = cut_drop_cell(f, name);
	if (!cell) return;
	Vec2 from = cell.absolute + cell.size * 0.5f;
	f.feed(from);
	f.feed(from, left: true);
	f.feed(from + (Vec2){ crig::PIECE_DRAG_SLOP * 3.0f, 0 }, left: true);
	test::@check(f.app.asset_dragging(), "the press and move started no drag");
	f.feed(to, left: true);
	f.feed(to);
	f.ui.flush();
	test::@check(!f.app.piece_drag.active, "the drag outlived the drop");
}

fn void cut_drop_a_clip_he_has_lays_a_play_that_walks_with_his_move() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	cut_drop_open(&f);
	Element* cell = cut_drop_cell(&f, "Walk");
	if (!cell) return;
	crig::AssetClip walk = cut_drop_clip_of(&f, cell);
	defer walk.free();
	test::@check(f.app.bind_asset_clip(&walk), "Walk would not bind");
	// The move slowed to 6 s, so a walk fitted to it plays slower than as made.
	CutStrip longer = f.app.cutscene().actors[0].strips[0].copy(mem);
	longer.end = 7.0f;
	test::@check(f.app.set_cut_strip(0, 0, longer), "the move would not lengthen");
	cut_drop_settle(&f);
	sz bound = f.app.doc.animations.len();
	sz rig_steps = f.app.undo_stack.cursor;
	usz steps = cut_drop_steps(&f);
	CutStrip* move = &f.app.cutscene().actors[0].strips[0];
	test::@check(move.kind == MOVE && cut_drop_near(move.start, 1.0f) && cut_drop_near(move.end, 7.0f), "the move runs %f-%f", move.start, move.end);
	float move_start = move.start;
	float move_end = move.end;

	// Dropped on his Clip lane at 2 s, inside the move: a looping play to its end, paired with it.
	cut_drop_drag(&f, "Walk", cut_drop_at(&f, 0, 2.0f));
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(laid.len == 2, "the drop left %d strips", laid.len);
	if (laid.len != 2) return;
	usz play = laid[0].kind == PLAY ? 0 : 1;
	CutStrip* s = &laid[play];
	test::@check(s.kind == PLAY && s.clip == walk.name && s.loop && cut_drop_near(s.start, 2.0f) && cut_drop_near(s.end, move_end),
		"the drop laid %s %f-%f", s.clip, s.start, s.end);
	test::@check(crig::cut_paired_move(laid, play, f.app.cutscene().paths) == (sz)(1 - play), "the play does not pair with the move");
	float ground = f.app.cut_actor_clip_speed(0, walk.name);
	test::@check(ground >= crig::CUT_PAIR_GROUND_MIN, "Walk's ground speed %f is not known", ground);
	float fit = crig::cut_walk_rate(f.app.cutscene().paths[0].length, move_end - move_start, ground);
	test::@check(cut_drop_near(s.speed, fit) && !cut_drop_near(s.speed, 1.0f), "the walk plays at %f, not %f", s.speed, fit);
	test::@check(f.app.cut_selected == s.id && cut_drop_near(f.app.cut_time, 2.0f), "the play is not picked at the drop");
	test::eq(cut_drop_steps(&f), steps + 1);
	test::eq(f.app.undo_stack.cursor, rig_steps);
	test::eq(f.app.doc.animations.len(), bound);

	// One Ctrl+Z takes it back.
	test::@check(f.app.undo_latest(), "nothing to undo");
	test::eq(cut_drop_strips(&f, 0), (usz)1);
	test::eq(cut_drop_steps(&f), steps);
	test::eq(f.app.doc.animations.len(), bound);
	cut_drop_settle(&f);

	// A header and the ruler take nothing, and the drag ends.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	Vec2[2] off = { cut_sheet_header(&f, 0), timeline.absolute + (Vec2){ timeline.size.x * 0.5f, crig::TIMELINE_STYLE.ruler_height * 0.5f } };
	foreach (at : off)
	{
		cut_drop_drag(&f, "Walk", at);
		test::@check(f.app.cutscene().actors[0].strips.len == 1, "a drop off the lanes laid a strip");
		test::eq(cut_drop_steps(&f), steps);
	}
}

fn void cut_drop_a_clip_he_lacks_is_bound_first_and_undone_after_the_play() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	cut_drop_open(&f);
	usz hero = f.app.active;
	String file = cut_drop_copy("assets/animations/humanoid.glb", "newcomer.glb");
	defer (void)file::delete(file);
	test::@check(f.app.add_actor_from_file(file, "newcomer"), "no actor from the file");
	usz newcomer = f.app.active;
	test::@check(newcomer != hero && !f.app.level_read, "the newcomer is not a character of his own file");
	test::@check(f.app.focus_character(hero), "the hero did not take the focus back");
	cut_drop_settle(&f);
	Element* cell = cut_drop_cell(&f, "Wave");
	if (!cell) return;
	crig::AssetClip wave = cut_drop_clip_of(&f, cell);
	defer wave.free();
	Character* his = f.app.character(newcomer);
	test::@check(!his.binds_clip(wave.file, wave.name), "the newcomer binds Wave already");
	sz bound = his.doc.animations.len();
	usz steps = cut_drop_steps(&f);

	// Dropped on his Clip lane: bound to him, as the focus, then laid.
	cut_drop_drag(&f, "Wave", cut_drop_at(&f, 1, 1.0f));
	test::@check(f.app.active == newcomer, "the newcomer is not the focus");
	test::eq(f.app.doc.animations.len(), bound + 1);
	test::@check(f.app.binds_clip(wave.file, wave.name), "the newcomer does not bind Wave");
	CutStrip[] laid = f.app.cutscene().actors[1].strips;
	test::@check(laid.len == 1 && laid[0].kind == PLAY && laid[0].clip == wave.name && cut_drop_near(laid[0].start, 1.0f),
		"the drop laid %d strips", laid.len);
	test::eq(cut_drop_steps(&f), steps + 1);
	test::@check(f.notice_text().contains("added Wave"), "the drop said %s", f.notice_text());

	// Ctrl+Z takes back the play, then the binding.
	test::@check(f.app.undo_latest(), "nothing to undo");
	test::eq(cut_drop_strips(&f, 1), (usz)0);
	test::eq(f.app.doc.animations.len(), bound + 1);
	test::eq(cut_drop_steps(&f), steps);
	test::@check(f.app.undo_latest(), "the binding did not undo");
	test::eq(f.app.doc.animations.len(), bound);
	test::eq(cut_drop_steps(&f), steps);
	test::@check(f.app.cutscene().actors.len == 2, "the undo took an actor");
}

fn void cut_drop_a_level_actor_and_a_clip_named_like_his_own_refuse() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	cut_drop_open(&f);
	usz hero = f.app.active;
	// One read from the level.
	usz guide = f.app.add_character({}, "");
	f.app.level_read = true;
	test::@check(f.app.make_actor(guide, "guide"), "the bare rig is no actor");
	// One from a copy of the library's file, which binds his own Walk.
	String file = cut_drop_copy(string::tformat("%s/humanoid.glb", library::ready()), "twin.glb");
	defer (void)file::delete(file);
	test::@check(f.app.add_actor_from_file(file, "twin"), "no actor from the file");
	usz twin = f.app.active;
	test::@check(f.app.binds_clip(f.app.source_path, "Walk"), "the twin does not bind his own Walk");
	test::@check(f.app.focus_character(hero), "the hero did not take the focus back");
	cut_drop_settle(&f);
	sz guide_bound = f.app.character(guide).doc.animations.len();
	sz twin_bound = f.app.character(twin).doc.animations.len();
	usz steps = cut_drop_steps(&f);

	cut_drop_drag(&f, "Wave", cut_drop_at(&f, 1, 1.0f));
	test::eq(f.notice_text(), "guide plays the level's clips only");
	test::eq(cut_drop_strips(&f, 1), (usz)0);
	test::eq(f.app.character(guide).doc.animations.len(), guide_bound);

	cut_drop_drag(&f, "Walk", cut_drop_at(&f, 2, 1.0f));
	test::eq(f.notice_text(), "twin already has a clip named Walk");
	test::eq(cut_drop_strips(&f, 2), (usz)0);
	test::eq(f.app.character(twin).doc.animations.len(), twin_bound);

	test::@check(f.app.active == hero, "a refused drop moved the focus to %d", f.app.active);
	test::eq(cut_drop_steps(&f), steps);
}

<*
 Walks made with the mouse: a path drawn by clicks on the ground, a knot dragged,
 put in and taken out, Walk here, and a move resized on the timeline, each one
 undo step.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// The Animations dock in a pane under the model, showing the first cutscene, one frame later.
fn void walk_tab(Fixture* f) @local
{
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	(void)f.app.show_cutscene(0);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
}

fn Vec2 walk_centre(Fixture* f, String id) @local
{
	Element* elem = f.ui.find_id(id)!!;
	return elem.absolute + elem.size * 0.5f;
}

// Where a point of the world is in the 3D view, in window pixels.
fn Vec2 walk_pixel(Fixture* f, Vec3 at) @local
{
	Element* view = f.ui.find(Viewport)!!;
	Matrix4f vp = view.widget_as(Viewport).world_view_projection(view);
	Vec2 local = crig::project(vp, at, view.size)!!;
	return view.absolute + local;
}

fn usz walk_steps(Fixture* f) @local => (usz)f.app.cut_history.undo.len();

fn bool walk_near(Vec3 a, Vec3 b, float eps) @local => (a - b).length() <= eps;

fn void a_path_is_drawn_on_the_ground_and_its_knots_edited_with_the_mouse() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	walk_tab(&f);
	test::@check(cut_bin_has(&f, "+ Path"), "no + Path piece");
	test::@check(!cut_bin_has_kind(&f, PATH), "a path piece with no path");
	usz steps = walk_steps(&f);

	// + Path: a new path that waits for clicks; each click on y = 0 is a knot.
	f.click(cut_bin_row(&f, "+ Path"));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_pick == PATH_KNOT && f.app.cut_path_pick == 1, "+ Path did not start a path");
	test::@check(cut_bin_has(&f, crig::CUT_PATH_NAME), "the path is not listed");
	Vec3[4] knots = { { -0.6f, 0, -0.6f }, { 0.4f, 0, -0.4f }, { 0.6f, 0, 0.5f }, { -0.4f, 0, 0.6f } };
	foreach (at : knots)
	{
		f.click(walk_pixel(&f, at));
		f.feed(f.ui.input.mouse);
	}
	f.feed_key(Key.RETURN);
	test::@check(f.app.cut_pick == NONE, "Enter did not end the drawing");
	WalkPath* path = f.app.cut_picked_path();
	test::@check(path && path.knots.len == 4, "%d knots drawn", path ? path.knots.len : 0);
	if (!path || path.knots.len != 4) return;
	foreach (usz k, at : knots) test::@check(walk_near(path.knots[k], at, 0.02f), "knot %d is at %f %f %f", k, path.knots[k].x, path.knots[k].y, path.knots[k].z);
	test::@check(path.points.len > 4, "the path is not sampled");
	test::eq(walk_steps(&f), steps + 5);

	// A knot dragged along the ground is one step; one undo puts it back.
	Vec3 to = { 0.7f, 0, -0.7f };
	f.drag(walk_pixel(&f, knots[1]), walk_pixel(&f, to));
	f.feed(f.ui.input.mouse);
	path = f.app.cut_picked_path();
	test::@check(walk_near(path.knots[1], to, 0.03f), "the knot went to %f %f %f", path.knots[1].x, path.knots[1].y, path.knots[1].z);
	test::eq(walk_steps(&f), steps + 6);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(walk_near(f.app.cut_picked_path().knots[1], knots[1], 0.02f), "undo did not put the knot back");
	crig::menu_redo(f.ui);
	f.feed(f.ui.input.mouse);

	// Esc while dragging puts it back and leaves no step.
	Vec2 grab = walk_pixel(&f, knots[2]);
	f.feed(grab);
	f.feed(grab, left: true);
	f.feed(walk_pixel(&f, { 0.9f, 0, 0.9f }), left: true);
	test::@check(!walk_near(f.app.cut_picked_path().knots[2], knots[2], 0.05f), "the drag did not move the knot");
	f.feed(walk_pixel(&f, { 0.9f, 0, 0.9f }), left: true, keys: { Key.ESCAPE });
	f.feed(walk_pixel(&f, { 0.9f, 0, 0.9f }));
	f.feed(f.ui.input.mouse);
	test::@check(walk_near(f.app.cut_picked_path().knots[2], knots[2], 0.02f), "Esc left the knot moved");
	test::eq(walk_steps(&f), steps + 6);

	// A click on the line puts a knot in there; Delete takes the picked knot out.
	path = f.app.cut_picked_path();
	Vec3 on_line = path.points[path.points.len / 2];
	f.click(walk_pixel(&f, on_line));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_picked_path().knots.len == 5, "the click on the line put in no knot");
	test::@check(f.app.cut_knot_pick > 0, "the new knot is not picked");
	test::eq(walk_steps(&f), steps + 7);
	f.feed_key(Key.DELETE);
	test::@check(f.app.cut_picked_path().knots.len == 4, "Delete did not take the knot out");
	test::eq(walk_steps(&f), steps + 8);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_picked_path().knots.len == 5, "undo did not bring the knot back");

	// The path's menu renames it, in the rename dialog.
	f.right_click(cut_bin_row(&f, crig::CUT_PATH_NAME));
	test::@check(has_id(&f, crig::CUT_PATH_WALK_ID), "the path's menu has no Walk here");
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_RENAME_ID);
	Element* field = f.ui.find_id(crig::CUT_PATH_NAME_ID)!!;
	field.widget_as(TextField).set_text(field, "");
	f.type_into(field, "Round");
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_picked_path().name == "Round", "the path is called %s", f.app.cut_picked_path().name);
}

fn void walk_here_lays_a_move_and_a_resize_on_the_timeline_sets_its_speed() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	AnimRef walk_ref = f.app.new_clip("Walk", 1.0f);
	test::@check(walk_ref.valid(), "no walk clip");
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	float length = f.app.cut_picked_path().length;
	walk_tab(&f);
	usz steps = walk_steps(&f);

	// Walk here: the hero walks the road from the playhead; a still clip is timed at 1 m/s.
	f.app.show_cutscene_at(1.0f);
	f.right_click(cut_bin_row(&f, "Road"));
	(void)cut_sheet_menu_click(&f, crig::CUT_PATH_WALK_ID);
	CutStrip* s = f.app.cut_selected_strip();
	CutStrip[] laid = f.app.cutscene().actors[0].strips;
	test::@check(s && s.kind == PLAY && s.clip == f.app.clip(walk_ref).name && laid.len == 2 && laid[0].kind == MOVE && laid[0].clip.len == 0
		&& laid[0].path == 0, "Walk here laid no move and walk");
	if (!s || laid.len != 2) return;
	test::@check(math::abs(s.start - 1.0f) < 1e-4f && math::abs(s.end - s.start - length) < 1e-3f, "the walk runs %f to %f", s.start, s.end);
	test::eq(walk_steps(&f), steps + 1);
	test::@check(has_id(&f, crig::CUT_CARD_GROUND_ID), "the walk's card has no ground speed");
	bool named;
	@pool()
	{
		foreach (text : f.app.cutscene_problem_texts(tmem)) named = named || text.contains("ground speed");
	};
	test::@check(named, "a walk with no ground speed is not named");

	// A ground speed typed in the card: the clip's speed follows.
	Element* ground = f.ui.find_id(crig::CUT_CARD_GROUND_ID)!!;
	ground.widget_as(TextField).set_text(ground, "");
	f.type_into(ground, "1.5");
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
	s = f.app.cut_selected_strip();
	test::@check(math::abs(s.ground_speed - 1.5f) < 1e-5f, "the ground speed is %f", s.ground_speed);
	float want = (length / (s.end - s.start)) / 1.5f;
	test::@check(math::abs(s.speed - want) < 1e-3f, "the speed is %f, not %f", s.speed, want);
	test::eq(walk_steps(&f), steps + 2);

	// The move's end dragged out on the timeline: longer, so the walk is slower.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	float y = drawn.lane_top(timeline, c, 0, WHERE) + crig::CUT_LANE_H * 0.5f;
	Vec2 end_at = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, s.end), y };
	float later = s.start + (s.end - s.start) * 2.0f;
	Vec2 drop_at = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, later), y };
	f.drag(end_at, drop_at);
	f.feed(f.ui.input.mouse);
	s = f.app.cut_selected_strip();
	CutStrip* walk = &f.app.cutscene().actors[0].strips[1];
	want = (length / (s.end - s.start)) / 1.5f;
	test::@check(s.kind == MOVE && s.end > later - 0.1f, "the move's end is %f, not near %f", s.end, later);
	test::@check(math::abs(walk.speed - want) < 1e-3f, "resized the speed is %f, not %f", walk.speed, want);
	test::eq(walk_steps(&f), steps + 3);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	s = f.app.cut_selected_strip();
	walk = &f.app.cutscene().actors[0].strips[1];
	test::@check(math::abs(walk.speed - (length / (s.end - s.start)) / 1.5f) < 1e-3f, "undo did not take the speed back with the length");
}

fn void a_walk_spanning_its_move_follows_the_move_dragged_on_the_timeline() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	test::@check(f.app.new_clip("Walk", 1.0f).valid(), "no walk clip");
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	test::@check(f.app.set_cutscene_timing(0, 20.0f, 30.0f), "a longer cutscene");
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	float length = f.app.cut_picked_path().length;
	walk_tab(&f);
	f.app.show_cutscene_at(1.0f);
	test::@check(f.app.walk_cut_path(0, 0) == 0 && f.app.cutscene().actors[0].strips.len == 2, "Walk here laid no move and walk");
	if (f.app.cutscene().actors[0].strips.len != 2) return;
	// The still clip has no ground speed of its own: one typed lets the walk pair.
	CutStrip typed = f.app.cutscene().actors[0].strips[1].copy(mem);
	typed.ground_speed = 1.5f;
	test::@check(f.app.set_cut_strip(0, 1, typed), "type a ground speed");
	f.feed(f.ui.input.mouse);
	CutStrip* m = &f.app.cutscene().actors[0].strips[0];
	CutStrip* w = &f.app.cutscene().actors[0].strips[1];
	float start = m.start;
	float end = m.end;
	test::@check(w.start == start && w.end == end, "the walk does not span the move");
	usz steps = walk_steps(&f);

	// The move's end dragged out: the walk's end comes along live, and its speed slows.
	Element* timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	CutsceneTimeline* drawn = timeline.widget_as(CutsceneTimeline);
	Cutscene* c = f.app.cutscene();
	float y = drawn.lane_top(timeline, c, 0, WHERE) + crig::CUT_LANE_H * 0.5f;
	Vec2 end_at = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, end), y };
	float later = start + (end - start) * 2.0f;
	Vec2 drop_at = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, later), y };
	// In small steps, as a hand drags: the walk's end moving along must not hold the move's back.
	f.feed(end_at);
	f.feed(end_at, left: true);
	float lag;
	float frame = 1.0f / f.app.cutscene().fps;
	for (Vec2 at = end_at; at.x < drop_at.x; at.x += 2.0f)
	{
		f.feed(at, left: true);
		if (at.x - end_at.x < 2.0f * crig::CUT_DRAG_SLOP) continue;
		float under = end + drawn.time_of(timeline, c, at.x - timeline.absolute.x, true) - drawn.time_of(timeline, c, end_at.x - timeline.absolute.x, true);
		lag = math::max(lag, math::abs(f.app.cutscene().actors[0].strips[0].end - under));
	}
	test::@check(lag <= frame + 1e-3f, "the move's end lagged the pointer by %f s", lag);
	f.feed(drop_at, left: true);
	m = &f.app.cutscene().actors[0].strips[0];
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(m.end > later - 0.1f && w.end == m.end, "mid-drag the walk ends at %f, the move at %f", w.end, m.end);
	f.feed(drop_at);
	f.feed(f.ui.input.mouse);
	m = &f.app.cutscene().actors[0].strips[0];
	w = &f.app.cutscene().actors[0].strips[1];
	float want = (length / (m.end - m.start)) / 1.5f;
	test::@check(w.start == m.start && w.end == m.end && m.end > later - 0.1f, "the walk runs %f to %f, the move %f to %f", w.start, w.end, m.start, m.end);
	test::@check(math::abs(w.speed - want) < 1e-3f && w.speed < 1.0f / 1.5f * length / (end - start), "the walk plays at %f, not %f", w.speed, want);
	test::eq(walk_steps(&f), steps + 1);

	// One Ctrl+Z puts both back.
	f.chord(f.ui.input.mouse, Key.LEFT_CTRL, Key.Z);
	m = &f.app.cutscene().actors[0].strips[0];
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(m.end == end && w.end == end && w.start == start, "one undo left the move at %f and the walk at %f", m.end, w.end);
	test::eq(walk_steps(&f), steps);

	// The whole move dragged 2 s later: the walk moves with it.
	timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	drawn = timeline.widget_as(CutsceneTimeline);
	c = f.app.cutscene();
	Vec2 body = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, (start + end) * 0.5f), y };
	Vec2 moved = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, (start + end) * 0.5f + 2.0f), y };
	f.drag(body, moved);
	f.feed(f.ui.input.mouse);
	m = &f.app.cutscene().actors[0].strips[0];
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(math::abs(m.start - (start + 2.0f)) < 0.05f && w.start == m.start && w.end == m.end,
		"the move went to %f-%f and the walk to %f-%f", m.start, m.end, w.start, w.end);
	test::eq(walk_steps(&f), steps + 1);

	// A walk over only part of its move stays where it is.
	CutStrip part = w.copy(mem);
	part.trim_front(m.start + 0.5f);
	test::@check(f.app.set_cut_strip(0, 1, part), "start the walk later");
	f.feed(f.ui.input.mouse);
	m = &f.app.cutscene().actors[0].strips[0];
	w = &f.app.cutscene().actors[0].strips[1];
	float part_start = w.start;
	float part_end = w.end;
	timeline = f.ui.find_id(crig::CUT_TIMELINE_ID)!!;
	drawn = timeline.widget_as(CutsceneTimeline);
	c = f.app.cutscene();
	end_at = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, m.end), y };
	drop_at = timeline.absolute + (Vec2){ drawn.x_of(timeline, c, m.end + 1.0f), y };
	f.drag(end_at, drop_at);
	f.feed(f.ui.input.mouse);
	m = &f.app.cutscene().actors[0].strips[0];
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(m.end > part_end + 0.5f && w.start == part_start && w.end == part_end, "the partial walk went to %f-%f", w.start, w.end);
}

// Type `text` into the card's number field `id` and press Return.
fn void walk_type(Fixture* f, String id, String text) @local
{
	Element* field = f.ui.find_id(id)!!;
	field.widget_as(TextField).set_text(field, "");
	f.type_into(field, text);
	f.feed_key(Key.RETURN);
	f.feed(f.ui.input.mouse);
}

fn void a_moves_card_shows_no_clip_and_a_walks_card_holds_a_typed_speed_until_fit() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	test::@check(f.app.new_clip("Walk", 1.0f).valid(), "no walk clip");
	f.app.stop_animation();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	(void)f.app.add_cut_path("Road");
	test::@check(f.app.add_cut_knot(0, { 0, 0, -1 }) && f.app.add_cut_knot(0, { 0, 0, 2 }), "knots");
	walk_tab(&f);
	f.app.show_cutscene_at(1.0f);
	sz k = f.app.walk_cut_path(0, 0);
	test::@check(k == 0 && f.app.cutscene().actors[0].strips.len == 2, "Walk here laid %d strips", f.app.cutscene().actors[0].strips.len);
	if (k != 0 || f.app.cutscene().actors[0].strips.len != 2) return;

	// The move's card: times, ease, facing and path; no clip to play.
	(void)f.app.select_cut_strip(0, 0);
	f.feed(f.ui.input.mouse);
	test::@check(has_id(&f, crig::CUT_CARD_PATH_ID) && has_id(&f, crig::CUT_CARD_EASE_ID) && has_id(&f, crig::CUT_CARD_FACE_ID), "the move's card");
	test::@check(!has_id(&f, crig::CUT_CARD_CLIP_ID) && !has_id(&f, crig::CUT_CARD_GROUND_ID) && !has_id(&f, crig::CUT_CARD_FIT_ID),
		"a move with no clip shows clip controls");

	// The walk's card: Fit, and the ground speed its pairing follows.
	(void)f.app.select_cut_strip(0, 1);
	f.feed(f.ui.input.mouse);
	test::@check(has_id(&f, crig::CUT_CARD_FIT_ID) && has_id(&f, crig::CUT_CARD_GROUND_ID) && has_id(&f, crig::CUT_CARD_CLIP_ID), "the walk's card");
	walk_type(&f, crig::CUT_CARD_GROUND_ID, "1.5");
	CutStrip* m = &f.app.cutscene().actors[0].strips[0];
	float fit = (f.app.cutscene().paths[0].length / (m.end - m.start)) / 1.5f;
	CutStrip* w = &f.app.cutscene().actors[0].strips[1];
	test::@check(math::abs(w.speed - fit) < 1e-3f && !w.speed_held, "the walk plays at %f, not %f", w.speed, fit);

	// A speed typed holds; Fit takes the pairing back, one step.
	walk_type(&f, crig::CUT_CARD_SPEED_ID, "2");
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(w.speed_held && math::abs(w.speed - 2.0f) < 1e-5f, "the typed speed is %f, held %s", w.speed, w.speed_held);
	usz steps = walk_steps(&f);
	f.click(walk_centre(&f, crig::CUT_CARD_FIT_ID));
	f.feed(f.ui.input.mouse);
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(!w.speed_held && math::abs(w.speed - fit) < 1e-3f, "Fit left the speed at %f, held %s", w.speed, w.speed_held);
	test::eq(walk_steps(&f), steps + 1);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	w = &f.app.cutscene().actors[0].strips[1];
	test::@check(w.speed_held && math::abs(w.speed - 2.0f) < 1e-5f, "undo did not hold the speed again");
}

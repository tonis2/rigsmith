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

fn void walk_tab(Fixture* f) @local
{
	crig::show_pane_view(f.ui, crig::CUTSCENE_VIEW, SplitAxis.VERTICAL, 0.5f);
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
	test::@check(has_id(&f, crig::CUT_PATH_ADD_ID) && has_id(&f, crig::CUT_PATH_DRAW_ID), "no path icons");
	test::@check(!has_id(&f, crig::CUT_PATH_WALK_ID), "Walk here with no path picked");
	usz steps = walk_steps(&f);

	// Draw: the icon adds a path and waits for clicks; each click on y = 0 is a knot.
	f.click(walk_centre(&f, crig::CUT_PATH_DRAW_ID));
	f.feed(f.ui.input.mouse);
	test::@check(f.app.cut_pick == PATH_KNOT && f.app.cut_path_pick == 1, "Draw did not start a path");
	test::@check(has_id(&f, crig::CUT_PATHS_ID) && has_id(&f, crig::CUT_PATH_NAME_ID) && has_id(&f, crig::CUT_PATH_WALK_ID), "the path is not listed");
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

	// The name field renames it.
	crig::cut_path_name_submitted(f.ui, "Round");
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
	f.click(walk_centre(&f, crig::CUT_PATH_WALK_ID));
	f.feed(f.ui.input.mouse);
	CutStrip* s = f.app.cut_selected_strip();
	test::@check(s && s.kind == MOVE && s.path == 0 && s.clip == f.app.clip(walk_ref).name, "Walk here laid no walk");
	if (!s) return;
	test::@check(math::abs(s.start - 1.0f) < 1e-4f && math::abs(s.end - s.start - length) < 1e-3f, "the walk runs %f to %f", s.start, s.end);
	test::eq(walk_steps(&f), steps + 1);
	test::@check(has_id(&f, crig::CUT_CARD_GROUND_ID), "the move's card has no ground speed");
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

	// The end dragged out on the timeline: longer, so slower.
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
	want = (length / (s.end - s.start)) / 1.5f;
	test::@check(s.end > later - 0.1f, "the end is %f, not near %f", s.end, later);
	test::@check(math::abs(s.speed - want) < 1e-3f, "resized the speed is %f, not %f", s.speed, want);
	test::eq(walk_steps(&f), steps + 3);
	crig::menu_undo(f.ui);
	f.feed(f.ui.input.mouse);
	s = f.app.cut_selected_strip();
	test::@check(math::abs(s.speed - (length / (s.end - s.start)) / 1.5f) < 1e-3f, "undo did not take the speed back with the length");
}

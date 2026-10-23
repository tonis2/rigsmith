<*
 Motion paths in the viewport (ui/path_overlay.c3, app/path_edit.c3): a point
 dragged reshapes the path as one undo step, Esc gives the drag back, a curve
 Ctrl-clicked is sliced at the playhead, and the Path tool draws a new path from
 clicks.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::path_gesture`
*>
module crig_tests::ui;

import crig;
import rig;
import cui;
import std::core::test;
import std::math;

struct PathScene
{
	String joint; // owned
	usz index;    // its place in the rig
}

// The biped, a one-second clip on show for posing, and a joint with a limb above it.
fn PathScene path_gesture_open(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Paths", 1);
	f.app.editing = f.app.key_here(clip, 0.5f);
	f.app.show_edited();
	test::@check(f.app.prepare_animation_pose(), "the clip would not go on show");
	f.app.undo_stack.commit();
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	PathScene scene;
	foreach (usz j, name : view.names)
	{
		usz[16] run;
		if (name.len == 0 || view.skeleton.ancestor_run(j, run[..]) < 2) continue;
		bool leafish = true;
		foreach (parent : view.skeleton.parents) if (parent == (int)j) leafish = false;
		if (!leafish) continue;
		scene = { .joint = name.copy(mem), .index = j };
		break;
	}
	test::@check(scene.joint.len > 0, "the biped has no limb to give a path");
	f.ui.flush();
	return scene;
}

// A small arc in front of the joint's posed place, three points and three slices.
fn void path_gesture_add_arc(Fixture* f, PathScene* scene)
{
	float height = f.app.path_height;
	test::@check(height > 0.0f, "no posed rig to draw paths over");
	Dot* dot = null;
	foreach (&each : f.doc().dots.array_view()) if (each.name == scene.joint) dot = each;
	Vec3 at = f.app.dot_position(*dot) / height;
	AnimPath path = { .joint = scene.joint.copy(mem) };
	path.points = alloc::new_array(mem, AnimPathPoint, 3);
	path.points[0] = { .at = at + (Vec3){ -0.06f, 0.0f, 0.05f } };
	path.points[1] = { .at = at + (Vec3){ 0.0f, 0.05f, 0.05f } };
	path.points[2] = { .at = at + (Vec3){ 0.06f, 0.0f, 0.05f } };
	path.slices = alloc::new_array(mem, AnimPathSlice, 3);
	path.slices[0] = { .time = 0.0f, .u = 0.0f };
	path.slices[1] = { .time = 0.5f, .u = 0.5f };
	path.slices[2] = { .time = 1.0f, .u = 1.0f };
	test::@check(f.app.add_path(f.app.editing, path) == 0, "the path would not land");
	f.app.refresh_posed();
	f.ui.flush();
}

// Where a point in model units is on screen.
fn Vec2? path_gesture_pixel(Fixture* f, Vec3 at)
{
	Vec2 local = crig::project(f.app.model_view_projection(&f.app.camera, VIEWPORT.x / VIEWPORT.y), at, VIEWPORT)!;
	return local + VIEWPORT_ORIGIN;
}

fn Vec2 path_gesture_point(Fixture* f, usz point)
{
	AnimPath* path = &f.app.clip(f.app.editing).paths[0];
	return path_gesture_pixel(f, path.points[point].at * f.app.path_height)!!;
}

fn void path_gesture_a_dragged_point_lands_once_and_esc_gives_it_back() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	PathScene scene = path_gesture_open(&f);
	defer scene.joint.free(mem);
	path_gesture_add_arc(&f, &scene);
	f.app.path_selected = 0;
	f.ui.flush();
	Vec3 before = f.app.clip(f.app.editing).paths[0].points[1].at;
	sz history = f.app.undo_stack.cursor;

	Vec2 from = path_gesture_point(&f, 1);
	f.drag(from, from + (Vec2){ 30, -20 });
	f.ui.flush();
	AnimPath* moved = &f.app.clip(f.app.editing).paths[0];
	test::@check((moved.points[1].at - before).length() > 0.005f, "the point did not move with the drag");
	test::@check(!f.app.path_draft_active && f.app.drag.dot == 0, "the drag did not end");
	test::eq(f.app.undo_stack.cursor, history + 1);

	// A drag let go with Esc changes nothing.
	Vec3 kept = moved.points[1].at;
	Vec2 again = path_gesture_point(&f, 1);
	f.feed(again);
	f.feed(again, left: true);
	f.feed(again + (Vec2){ 25, 25 }, left: true);
	Key[1] escape = { Key.ESCAPE };
	f.feed(again + (Vec2){ 25, 25 }, left: true, keys: escape[..]);
	f.feed(again + (Vec2){ 25, 25 });
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).paths[0].points[1].at == kept, "Esc left the point moved");
	test::eq(f.app.undo_stack.cursor, history + 1);
}

fn void path_gesture_ctrl_click_slices_the_curve_at_the_playhead() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	PathScene scene = path_gesture_open(&f);
	defer scene.joint.free(mem);
	path_gesture_add_arc(&f, &scene);
	f.app.path_tool = true;
	f.app.path_selected = 0;
	f.app.edit_time = 0.25f;
	f.ui.flush();
	AnimPath* path = &f.app.clip(f.app.editing).paths[0];
	Vec2 on_curve = path_gesture_pixel(&f, path.at_fraction(0.75f) * f.app.path_height)!!;
	Key[1] held = { Key.LEFT_CTRL };
	f.feed(on_curve, keys: held[..]);
	f.feed(on_curve, left: true, keys: held[..]);
	f.feed(on_curve, keys: held[..]);
	f.feed(on_curve);
	f.ui.flush();
	path = &f.app.clip(f.app.editing).paths[0];
	test::eq(path.slices.len, (sz)4);
	bool sliced;
	foreach (slice : path.slices) if (math::abs(slice.time - 0.25f) < 1.0e-4f && math::abs(slice.u - 0.75f) < 0.05f) sliced = true;
	test::@check(sliced, "no slice at the playhead where the curve was clicked");
}

fn void path_gesture_the_path_tool_draws_a_path_from_clicks() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	PathScene scene = path_gesture_open(&f);
	defer scene.joint.free(mem);
	Dot* dot = null;
	foreach (&each : f.doc().dots.array_view()) if (each.name == scene.joint) dot = each;
	f.app.select(dot.id);
	crig::menu_path_tool(f.ui);
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(f.app.path_tool, "the Path tool did not turn on: %s", f.app.notice());
	test::@check(f.in_tree(crig::PATH_DRAW_ID), "the Path tool did not bring its strip (mesh %s)", f.app.has_mesh());
	f.click(f.center_of(crig::PATH_DRAW_ID)!!);
	f.ui.flush();
	test::@check(f.app.path_drawing, "Draw did not start drawing");
	Vec2 at = f.pixel_of(dot.id)!!;
	Vec2[3] clicks = { at + (Vec2){ -40, 10 }, at + (Vec2){ 0, -30 }, at + (Vec2){ 40, 10 } };
	foreach (click : clicks)
	{
		f.click(click);
		f.ui.flush();
	}
	f.feed_key(Key.RETURN);
	f.ui.flush();
	test::@check(!f.app.path_drawing, "Enter did not finish the path");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.paths.len == 1 && clip.paths[0].points.len == 3 && clip.paths[0].slices.len == 3,
		"the drawn path is not three points and three slices");
	test::@check(clip.paths[0].joint == scene.joint, "the path is not for the selected joint");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).paths.len == 0, "one undo did not take the drawn path off");
}

// Done pressed while drawing keeps the path rather than throwing it away, and
// the Finish the strip shows while drawing lands it as Enter does.
fn void path_gesture_done_and_finish_keep_a_drawn_path() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	PathScene scene = path_gesture_open(&f);
	defer scene.joint.free(mem);
	Dot* dot = null;
	foreach (&each : f.doc().dots.array_view()) if (each.name == scene.joint) dot = each;
	f.app.select(dot.id);
	crig::menu_path_tool(f.ui);
	f.feed({ 0, 0 });
	f.ui.flush();
	Vec2 at = f.pixel_of(dot.id)!!;
	Vec2[2] clicks = { at + (Vec2){ -40, 10 }, at + (Vec2){ 40, -20 } };

	// Finish, on the strip while drawing.
	f.click(f.center_of(crig::PATH_DRAW_ID)!!);
	f.ui.flush();
	foreach (click : clicks)
	{
		f.click(click);
		f.ui.flush();
	}
	test::@check(f.in_tree(crig::PATH_FINISH_ID) && !f.in_tree(crig::PATH_DONE_ID), "drawing does not offer Finish");
	f.click(f.center_of(crig::PATH_FINISH_ID)!!);
	f.ui.flush();
	test::@check(!f.app.path_drawing && f.app.clip(f.app.editing).paths.len == 1, "Finish did not land the path");

	// Done, closing the tool mid-drawing.
	f.click(f.center_of(crig::PATH_DRAW_ID)!!);
	f.ui.flush();
	foreach (click : clicks)
	{
		f.click(click + (Vec2){ 0, 30 });
		f.ui.flush();
	}
	crig::menu_path_tool(f.ui);
	f.ui.flush();
	test::@check(!f.app.path_tool && f.app.clip(f.app.editing).paths.len == 2, "closing the tool threw the drawn path away");
}

// Follow on the strip turns the picked path's following on and off, one undo step each.
fn void path_gesture_follow_toggles_on_the_strip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	PathScene scene = path_gesture_open(&f);
	defer scene.joint.free(mem);
	path_gesture_add_arc(&f, &scene);
	crig::menu_path_tool(f.ui);
	f.feed({ 0, 0 });
	f.app.path_selected = 0;
	f.ui.flush();
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::PATH_FOLLOW_ID)!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).paths[0].follow, "Follow did not turn following on");
	test::eq(f.app.undo_stack.cursor, history + 1);
	f.click(f.center_of(crig::PATH_FOLLOW_ID)!!);
	f.ui.flush();
	test::@check(!f.app.clip(f.app.editing).paths[0].follow, "Follow did not turn following off");
}

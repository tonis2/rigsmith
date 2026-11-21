<*
 The weight brush: opening it, stroking over the mesh and over a parked clip,
 what it reaches through the model and what it never touches, its size and
 strength.
*>
module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

<*
 The weight brush opens on shift+W, borrows the falloff view, and hands it back.

 The Area tool's sibling, asserted the same way — and the shift is the point: the
 two share a letter because they are the two ways to change a bind without
 moving a joint, so a plain W must still be the Area tool and never the brush.
*>
fn void the_weight_brush_opens_beside_the_area_tool() @test
{
	io::printn("shift+W opens the weight brush and W still opens the Area tool");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "shift+W did not open the brush");
	test::@check(!fixture.app.areaing, "shift+W opened the Area tool as well");
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"the brush left the mesh on %s rather than painting what the dot holds",
		fixture.app.tint_mode);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(!fixture.app.brushing, "shift+W did not close the brush");
	test::@check(fixture.app.tint_mode == TintMode.OFF,
		"closing it left the mesh painted with %s", fixture.app.tint_mode);

	// The plain key still means the other mode, which is the whole risk of
	// hanging a second thing off one letter.
	fixture.feed_key(Key.W);
	test::@check(fixture.app.areaing && !fixture.app.brushing,
		"a plain W opened the brush instead of the Area tool");
	fixture.feed_key(Key.ESCAPE);

	// Escape closes the brush without cancelling anything: strokes went on the
	// ledger as they were made, so there is no half-finished state to put back.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not reopen");
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.brushing && fixture.app.areaing && fixture.app.tint_mode == TintMode.FALLOFF,
		"escape did not close the brush and hand the Weights card its part back");
}

<*
 shift+W opens the brush over a parked clip, and the Rig menu offers it there.

 The animation workspace is the one place a fold can be seen, so it is where
 the brush is wanted — and it used to answer "finish animation editing first"
 there, and grey its menu item. Now the only thing it asks for is a dot.
*>
fn void the_weight_brush_opens_over_a_parked_clip() @test
{
	io::printn("shift+W opens the weight brush while a clip is parked");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	AnimRef clip = fixture.app.new_clip("Bind", 1.0f, from_rest: true);
	test::@check(clip.valid() && fixture.app.park_clip(clip, 0.0f), "the fixture could not park a clip");
	test::@check(fixture.app.rig_locked(), "a parked clip did not lock the rest rig");
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	test::@check(!crig::query_brushing(fixture.ui).disabled,
		"the Rig menu greys the brush while a clip is parked");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "shift+W did not open the brush over the parked clip: \"%s\"",
		fixture.app.notice());
	test::@check(fixture.app.animating && fixture.app.anim_paused,
		"opening the brush took the clip down");
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"the brush left the mesh on %s rather than painting what the dot holds", fixture.app.tint_mode);

	// Without a dot it still refuses, and says so in the one remaining way.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	fixture.app.select(0);
	fixture.app.refresh_ui();
	test::@check(crig::query_brushing(fixture.ui).disabled, "the Rig menu offers the brush with nothing selected");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(!fixture.app.brushing && fixture.app.notice().contains("select a joint"),
		"with nothing selected the brush said \"%s\"", fixture.app.notice());
}

<*
 A stroke over a parked clip lands, reskins the body as it goes, and settles the
 posed surface on release.

 The viewport's half of what `weights_test` asserts on the state: the press
 opens the stroke, each move paints and rebinds the skin under the palette
 without rebuilding the accelerator, and the release is where that rebuild is
 paid — with the clip still parked at the end of it.
*>
fn void a_brush_stroke_over_a_parked_clip_reskins_as_it_goes() @test
{
	io::printn("a brush stroke over a parked clip reskins the body and settles on release");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);

	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	// The corner's pixel, read before the clip goes up — a clip keyed from rest
	// leaves every vertex where it was, so the pixel holds.
	uint probe = fixture.doc().add_dot({ -1, 1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? corner = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	if (catch corner)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}

	AnimRef clip = fixture.app.new_clip("Bind", 1.0f, from_rest: true);
	test::@check(clip.valid() && fixture.app.park_clip(clip, 0.0f), "the fixture could not park a clip");
	fixture.app.select(chest);
	fixture.app.refresh_ui();
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open over the parked clip");
	test::@check(fixture.app.posed_surface_shown(), "the parked clip put no posed surface up");

	uint skin_was = fixture.app.skin_generation;
	Vec2 from = corner;
	Vec2 to = { corner.x + 4, corner.y };

	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	fixture.feed(from, keys: taking[..]);
	fixture.feed(from, left: true, keys: taking[..]);
	test::@check(fixture.app.stroke_open, "the press did not open a stroke");
	test::@check(fixture.app.doc.pins.len() > 0, "the press painted nothing");
	test::@check(fixture.app.skin_generation > skin_was, "the press did not reskin the parked body");
	test::@check(fixture.app.surface_stale && fixture.app.deformed_surface.root != null,
		"the press rebuilt the posed surface instead of leaving it standing for the stroke");

	fixture.feed(to, left: true, keys: taking[..]);
	test::@check(fixture.app.stroke_open && fixture.app.surface_stale, "the move settled what the release should");

	fixture.feed(to, keys: taking[..]);
	test::@check(!fixture.app.stroke_open && !fixture.app.surface_stale,
		"the release did not rebuild the posed surface");
	test::@check(fixture.app.animating && fixture.app.anim_paused && fixture.app.posed_surface_shown(),
		"the stroke took the clip down");
	test::@check(!raised(&fixture, chest), "a taking stroke gave the chest a whole vertex");
}

<*
 A stroke paints the mesh under the circle, and one press-to-release is one step.

 The gather is the half that can be wrong without anything looking odd — a radius
 read in the wrong units, or an occlusion test that lets the far side through,
 both paint something and neither is visible in a screenshot. So this asserts the
 count moved, that it is bounded by the circle rather than the whole mesh, and
 that the ledger got exactly one entry for the gesture.

 It also holds the brush to its modifier: a stroke is a ctrl-drag, and the
 plain drag stays the orbit so the model can be turned to paint the rest of it.
*>
fn void a_brush_stroke_paints_under_the_circle() @test
{
	io::printn("a brush stroke paints what is under it, as one undo step");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	// The cursor, not the length: `undo` moves the cursor and leaves the edits in
	// place for redo, so a loop watching the length would never end.
	sz before = fixture.app.undo_stack.cursor;

	// Aimed at a corner, so the circle covers one vertex and not the whole face:
	// the fixture cube is eight of them and nothing in between, and a circle in
	// the middle of a face paints all of that face's corners.
	//
	// Found by projecting a dot placed there and taking it away again — the dot
	// and the vertex share a position, so they share a pixel.
	// Head-on, so which corners are in sight is knowable: the front face is
	// z = +1. A three-quarter view hides some corners and nothing in the test
	// could say which.
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	uint probe = fixture.doc().add_dot({ -1, -1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? corner = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	if (catch corner)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2 from = corner;
	Vec2 to = { corner.x + 4, corner.y };

	// A plain drag on the mesh paints the way the options strip says (Add), and
	// does not turn the model.
	float yaw = fixture.app.camera.yaw;
	fixture.feed(from);
	fixture.feed(from, left: true);
	fixture.feed(to, left: true);
	fixture.feed(to);
	test::@check(fixture.app.doc.pins.len() > 0, "a plain drag on the mesh did not paint with the brush open");
	test::@check(fixture.app.camera.yaw == yaw, "a plain drag on the mesh orbited as well as painting");
	test::@check(fixture.app.undo(), "the plain stroke did not undo");
	test::@check(fixture.app.doc.pins.len() == 0, "one undo left part of the plain stroke behind");

	// Off the mesh the plain drag is still the camera's, so the model can be
	// turned to reach the next part of it.
	Vec2 off = { corner.x - 120, corner.y };
	fixture.feed(off);
	fixture.feed(off, left: true);
	fixture.feed(off + (Vec2){ 30, 0 }, left: true);
	fixture.feed(off + (Vec2){ 30, 0 });
	test::@check(fixture.app.doc.pins.len() == 0, "a plain drag off the mesh painted");
	test::@check(fixture.app.camera.yaw != yaw, "a plain drag off the mesh did not orbit with the brush open");
	fixture.app.camera.yaw = yaw;
	fixture.app.refresh_ui();
	before = fixture.app.undo_stack.cursor;

	// Press, move, release — the shape of every stroke — with ctrl and shift
	// held, which is the direction that takes the dot off.
	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	fixture.feed(from, keys: taking[..]);
	fixture.feed(from, left: true, keys: taking[..]);
	fixture.feed(to, left: true, keys: taking[..]);
	fixture.feed(to, keys: taking[..]);

	sz painted = (sz)pinned_vertices(&fixture);
	test::@check(painted > 0, "the stroke painted nothing at all");
	test::@check(painted < (sz)fixture.app.geometry.positions.len,
		"the stroke painted the whole mesh (%d of %d) — the circle is not bounding it",
		painted, fixture.app.geometry.positions.len);
	test::@check(fixture.app.camera.yaw == yaw, "a ctrl+shift-drag orbited as well as painting");

	// Every row takes weight off the selected joint rather than adding it: shift
	// beside ctrl is the destructive direction.
	test::@check(!raised(&fixture, chest), "a ctrl+shift-drag added weight instead of taking it off");

	// The press and the move are two steps of one gesture: one undo takes both.
	test::@check(fixture.app.undo_stack.cursor > before, "the stroke left nothing on the ledger");
	test::@check(fixture.app.undo(), "the stroke did not undo");
	test::@check(fixture.app.doc.pins.len() == 0, "one undo left part of the stroke behind");
}

<*
 A stroke begun on another joint's dot paints the joint being painted: with the
 brush open a left press looks through the dots, and a right-click does too.
*>
fn void a_brush_stroke_on_a_joint_paints_instead_of_picking_it() @test
{
	io::printn("a brush stroke begun on a joint's dot paints rather than selecting that joint");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	// On a cube corner, the fixture mesh's only vertices, so the dot sits on what
	// the stroke paints.
	uint corner_dot = fixture.doc().add_dot({ -1, -1, 1 }, "corner");
	fixture.doc().connect(hips, corner_dot);
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");
	Vec2? corner = fixture.pixel_of(corner_dot);
	if (catch corner)
	{
		test::@check(false, "the corner dot does not project into the viewport");
		return;
	}

	fixture.drag(corner, corner + (Vec2){ 4, 0 });
	test::@check(fixture.app.selected == chest, "the press on a dot picked it instead of painting");
	test::@check(fixture.app.brushing, "the press on a dot closed the brush");
	bool chest_painted;
	foreach (pin : fixture.app.doc.pins.array_view()) chest_painted |= pin.dot_id == chest;
	test::@check(chest_painted, "the stroke begun on a dot did not paint the selected joint");

	fixture.right_click(corner);
	test::@check(fixture.app.selected == chest, "a right-click on a dot picked it with the brush open");
	test::@check(fixture.app.brushing, "a right-click on a dot closed the brush");
}

<*
 With the brush open the rig is left alone. A click on the face of a low-poly
 part, with no vertex under the circle, paints the face's corners and places no
 joint and chains none, and the keys that edit joints are refused out loud. Esc
 gives them back.

 Re-introduce: drop the face pass from `AppState.brush_vertices`.
*>
fn void the_brush_never_places_or_edits_joints() @test
{
	io::printn("the weight brush never places, connects, moves or deletes joints");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.doc.auto_connect = true;
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");
	test::@check(fixture.app.set_brush_radius(crig::BRUSH_RADIUS_MIN), "the brush did not shrink");
	sz dots = fixture.doc().dots.len();
	sz edges = fixture.doc().edges.len();
	bool anchored = fixture.app.locks_position(chest);

	// A spot on the cube's front face, clear of the bone and of the corners — the
	// face's only vertices. Found by projecting a dot put there and taken away.
	uint probe = fixture.doc().add_dot({ -0.6f, -0.5f, 1.0f }, "probe");
	fixture.app.refresh_ui();
	Vec2? spot = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();
	if (catch spot)
	{
		test::@check(false, "the face does not project into the viewport");
		return;
	}
	Vec2 face = spot;
	fixture.click(face);
	test::eq(fixture.doc().dots.len(), dots);
	test::eq(fixture.doc().edges.len(), edges);
	// The front face's corners are vertices 4 to 7; the far side stays out of it.
	test::@check(pinned_vertices(&fixture) > 0, "a click on the face painted none of its corners");
	{
		bool[] edited = edited_mask(&fixture);
		defer alloc::free(mem, edited);
		foreach (v, on : edited) test::@check(!on || v >= 4, "the click on the front face painted vertex %d on the far side", v);
	}
	test::@check(fixture.app.selected == chest && fixture.app.brushing, "the click changed the joint or closed the brush");
	test::@check(fixture.app.undo(), "the click's stroke did not undo");

	Key[1] shifted = { Key.LEFT_SHIFT };
	fixture.feed(face, keys: shifted[..]);
	fixture.feed(face, left: true, keys: shifted[..]);
	fixture.feed(face, keys: shifted[..]);
	test::eq(fixture.doc().dots.len(), dots);

	fixture.feed(face);
	foreach (key : (Key[6]){ Key.X, Key.C, Key.M, Key.L, Key.G, Key.R })
	{
		fixture.feed_key(key);
		test::@check(fixture.doc().dots.len() == dots && fixture.doc().edges.len() == edges,
			"%s edited the rig with the brush open", key);
		test::@check(fixture.app.selected == chest && fixture.app.brushing, "%s changed the joint or closed the brush", key);
		test::@check(!fixture.app.transform_interaction.active && fixture.app.drag.dot == 0, "%s started moving a joint", key);
		test::@check(fixture.app.notice().contains("stop the brush"), "%s said \"%s\"", key, fixture.app.notice());
	}
	test::@check(fixture.app.locks_position(chest) == anchored, "L anchored the joint with the brush open");
	fixture.chord(face, Key.LEFT_SHIFT, Key.M);
	test::@check(fixture.app.notice().contains("stop the brush"), "shift+M said \"%s\"", fixture.app.notice());
	fixture.chord(face, Key.LEFT_CTRL, Key.A);
	test::@check(fixture.app.selection_count() == 1 && fixture.app.selected == chest, "ctrl+A selected the joints with the brush open");

	// Esc closes the brush, and the same click places a joint again.
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.brushing, "esc did not close the brush");
	fixture.click(face);
	test::@check(fixture.doc().dots.len() == dots + 1, "a click with the brush closed placed no joint (%s)", fixture.app.notice());
}

// The head-on cube with the brush open over the whole silhouette, so every
// vertex is in the circle and only the visibility test keeps any of them out.
fn bool open_brush_head_on(Fixture* fixture)
{
	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	// Set rather than snapped: `snap_to` eases over frames this test has no clock for.
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	// Past the wheel's ceiling on purpose, to put every vertex in range at once.
	fixture.app.brush_radius = 4000.0f;
	fixture.app.refresh_ui();
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	return fixture.app.brushing;
}

// One press-and-release at the viewport centre with `keys` held.
fn void stroke_with(Fixture* fixture, Key[] keys)
{
	fixture.feed(VIEWPORT_CENTER, keys: keys);
	fixture.feed(VIEWPORT_CENTER, left: true, keys: keys);
	fixture.feed(VIEWPORT_CENTER, keys: keys);
}

struct XrayCase @local
{
	bool xray;
	bool alt;
	bool through;
}

<*
 The brush paints only the side of the model facing the user, unless the strip's
 X-ray box is ticked or alt is held at the press; alt with the box ticked turns
 it back to front only for that one stroke.

 A brush that reached the far side would correct an arm and silently correct the
 ribs behind it. Asserted head-on, the one view where it can be: each of the
 cube's back corners sits behind a front one, so the circle covers all eight
 and only four are in sight.

 Re-introduce: drop `self.brush_xray` from `Viewport.paint_at`'s call, or latch
 it from the box alone, or without `alt_down`.
*>
fn void the_brush_paints_through_only_with_xray_or_alt() @test
{
	io::printn("the weight brush paints the far side only with X-ray or alt");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	test::@check(open_brush_head_on(&fixture), "the brush did not open");
	fixture.feed(VIEWPORT_CENTER);
	test::@check(!fixture.app.config.brush_xray, "X-ray starts ticked");

	// Ending with the box off, as it started.
	XrayCase[4] cases = {
		{ .xray = true, .alt = false, .through = true },
		{ .xray = true, .alt = true, .through = false },
		{ .xray = false, .alt = false, .through = false },
		{ .xray = false, .alt = true, .through = true },
	};
	Key[3] alt_taking = { Key.LEFT_ALT, Key.LEFT_CTRL, Key.LEFT_SHIFT };
	foreach (one : cases)
	{
		if (fixture.app.config.brush_xray != one.xray) fixture.click(fixture.center_of(crig::BRUSH_XRAY_ID)!!);
		test::@check(fixture.app.config.brush_xray == one.xray, "clicking X-ray did not toggle it");
		stroke_with(&fixture, one.alt ? alt_taking[..] : alt_taking[1..]);

		// The chest holds the top four corners, so a stroke through takes it off
		// all four, the far two included; front only, off the near two.
		usz painted = pinned_vertices(&fixture);
		usz far = far_side_pinned(&fixture);
		if (one.through)
		{
			test::@check(painted == 4 && far == 2, "X-ray %s, alt %s: %d corners painted, %d behind, wanted 4 and 2",
				one.xray, one.alt, painted, far);
		}
		else
		{
			test::@check(painted > 0 && far == 0, "X-ray %s, alt %s: %d corners painted, %d of them behind",
				one.xray, one.alt, painted, far);
		}
		test::@check(fixture.app.undo(), "the stroke did not undo");
		test::eq(pinned_vertices(&fixture), (usz)0);
	}
}

<*
 The brush sizes itself only while F is held; the rest of the time the camera has
 the wheel back.

 A brush has to be *aimed*, and aiming means turning the model to reach the next
 part of it — so a tool that ate the orbit for as long as it was open would be
 usable from one angle only. Other 3D tools settle this by making the size a held-key
 gesture rather than a standing claim, and this is that: with F down the swipe
 sizes the circle, with F up it turns the model, and neither ever does both.

 The last check is the one that would have caught the old behaviour: it is not
 enough that F works, the wheel has to have gone *back*.
*>
fn void the_brush_sizes_only_while_its_key_is_held() @test
{
	io::printn("the weight brush sizes on held F and leaves the camera the wheel otherwise");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	float radius = fixture.app.brush_radius;
	float yaw = fixture.app.camera.yaw;
	float pitch = fixture.app.camera.pitch;

	// --- F held: the swipe is the brush's -----------------------------------

	Key[1] sizing = { Key.F };
	fixture.scroll(VIEWPORT_CENTER, { 0, 6 }, true, sizing[..]);

	test::@check(fixture.app.brush_radius != radius,
		"a swipe with F held did not size the brush");
	test::@check(fixture.app.camera.yaw == yaw && fixture.app.camera.pitch == pitch,
		"sizing the brush turned the model at the same time");

	// --- F up: the swipe is the camera's again ------------------------------

	float sized = fixture.app.brush_radius;
	fixture.scroll(VIEWPORT_CENTER, { 9, 5 }, true);

	test::@check(fixture.app.camera.yaw != yaw || fixture.app.camera.pitch != pitch,
		"the brush kept the orbit even with its key up — the model cannot be turned to paint the rest of it");
	test::@check(fixture.app.brush_radius == sized,
		"turning the model resized the brush");

	// F must not toggle the falloff view out from under the brush, since it is
	// the size key while the mode is open.
	fixture.feed_key(Key.F);
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"pressing F while brushing turned off the view the brush paints against");
}

// One dot's own weight on one vertex: what the brush moves.
fn float brush_weight_of(Fixture* f, uint vertex, uint dot)
{
	crig::RigView? opened = f.app.open_rig(mem);
	if (catch opened) return -1.0f;
	crig::RigView view = opened;
	defer view.free(mem);

	float[] column = f.app.column_of(mem, &view, dot);
	defer if (column.len > 0) alloc::free(mem, column);
	return (usz)vertex < column.len ? column[vertex] : -1.0f;
}

<*
 The strength sets how far one tap goes, all the way through the gesture: part
 of the way when it is low, the whole way at full.

 The arithmetic is asserted headlessly in `crig_tests::weights`; what this covers
 is the half that test cannot reach — that the strength is actually applied where
 the circle's falloff is computed, rather than only where a unit test hands the
 number in itself. Dropping `brush_strength` from `brush_vertices` leaves that
 one passing and this one failing, which is the whole reason it is here.
*>
fn void the_strength_slider_sets_how_far_one_tap_goes() @test
{
	io::printn("one tap of the weight brush carries a vertex as far as its strength says");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);

	// Head-on, so the front face is z = +1 and a corner there is in sight.
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.refresh_ui();

	uint probe = fixture.doc().add_dot({ -1, -1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? corner = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	if (catch corner)
	{
		test::@check(false, "the cube's front corner does not project into the viewport");
		return;
	}

	// Take it to nothing first, so the tap below has the whole range to cross and
	// "did one tap finish it" is a question with a visible answer.
	uint[1] target = { 4 };
	fixture.app.paint_share(chest, target[..], 0.0f);
	test::@check(brush_weight_of(&fixture, 4, chest) < 0.01f, "the corner did not start at nothing");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	defer fixture.app.set_brush_strength(crig::BRUSH_STRENGTH_DEFAULT);

	// One tap, dead centre, ctrl held so it adds rather than takes away.
	Key[1] adding = { Key.LEFT_CTRL };
	fixture.app.set_brush_strength(0.25f);
	fixture.feed(corner, keys: adding[..]);
	fixture.feed(corner, left: true, keys: adding[..]);
	fixture.feed(corner, keys: adding[..]);

	float after = brush_weight_of(&fixture, 4, chest);
	test::@check(after > 0.05f, "one gentle tap moved the corner not at all, measured %s", after);
	test::@check(after < 0.6f,
		"one tap at a quarter strength took the corner most of the way to full (%s)", after);

	// Back to nothing — the tap is one undo step — and the same tap at full
	// strength finishes it.
	test::@check(fixture.app.undo(), "the tap did not undo");
	test::@check(brush_weight_of(&fixture, 4, chest) < 0.01f, "the corner did not go back to nothing");
	fixture.app.set_brush_strength(crig::BRUSH_STRENGTH_MAX);
	fixture.feed(corner, keys: adding[..]);
	fixture.feed(corner, left: true, keys: adding[..]);
	fixture.feed(corner, keys: adding[..]);

	after = brush_weight_of(&fixture, 4, chest);
	test::@check(after > 0.95f, "one tap at full strength left the corner at %s", after);
}

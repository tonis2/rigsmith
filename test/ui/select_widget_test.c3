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

// ---------------------------------------------------------------------------
// The Select widget — cui's dropdown chooser, in its own little tree. crig has
// no consumer for it yet (presets and the falloff picker will be); this pins
// the widget's contract down before anything depends on it.

usz select_picked = 999;

fn void select_changed(Ui* ui, usz index)
{
	select_picked = index;
}

fn void pump(Ui* ui, Vec2 mouse, bool left = false)
{
	ui.process_input({ .mouse = mouse, .buttons = { left, false, false } }, DT);
	ui.flush();
}

fn void click_at(Ui* ui, Vec2 at)
{
	pump(ui, at);
	pump(ui, at, left: true);
	pump(ui, at);
}

fn void select_widget() @test
{
	io::printn("the Select widget chooses an option");

	Ui* ui = cui::new_ui({ 400.0, 300.0 });
	defer ui.free();
	if (catch ui.load_font(crig::FONT_PATH))
	{
		test::@check(false, "SKIPPED — the font is needed to size the options");
		return;
	}

	String[3] options = { "Linear", "Smooth", "Sharp" };
	@canvas(ui)
	{
		@tree((Stack) { })
		{
			@node((Select) { .options = options[..], .on_change = &select_changed }).with_id("select")
				.set_offset({ 40.0, 40.0 });
		};
	};
	ui.flush();

	Element*? select_elem = ui.find_id("select");
	if (catch select_elem)
	{
		test::@check(false, "SKIPPED — the Select is not in the tree");
		return;
	}
	Select* select = select_elem.widget_as(Select);
	Vec2 head      = select_elem.absolute + select_elem.size * 0.5f;

	click_at(ui, head);
	test::@check(select.open, "clicking the head opens the list");

	Element*? sharp = ui.find_id("Sharp");
	if (catch sharp)
	{
		test::@check(false, "SKIPPED — the options are not in the open list");
		return;
	}
	click_at(ui, sharp.absolute + sharp.size * 0.5f);
	test::@check(select.selected == 2, "clicking an option selects it");
	test::@check(select_picked == 2, "and the change callback fired with its index");
	test::@check(!select.open, "and the list closed");

	click_at(ui, head);
	test::@check(select.open, "it reopens");
	click_at(ui, { 300.0, 250.0 });
	test::@check(!select.open, "a click elsewhere closes it");
	test::@check(select.selected == 2, "without changing the choice");
}

<*
 The size-field convention, end to end: a widget with a `Vec2 size` field and
 no layout is sized by the field, a zero component fills the parent, and
 a fixed-size Column offers its own width downward so "fill" inherits 400
 rather than the window. Rectangle is the widget under test because it is the
 worked example — it has no layout at all.
*>
fn void size_field_convention() @test
{
	io::printn("a Vec2 size field sizes a widget with no layout code");

	Ui* ui = cui::new_ui({ 1000.0, 600.0 });
	defer ui.free();

	@canvas(ui)
	{
		@tree((Stack) { })
		{
			@node((Rectangle) { .size = { 70.0, 30.0 } }).with_id("fixed").set_offset({ 10.0, 10.0 });

			// A 400px column: the bar's zero width must become 400, not 1000.
			@tree((Column) { .size = { 400.0, 0.0 } })
			{
				@node((Rectangle) { .size = { 0.0, 24.0 } }).with_id("bar");
			}.set_offset({ 10.0, 60.0 });
		};
	};
	ui.flush();

	Element*? fixed = ui.find_id("fixed");
	if (catch fixed)
	{
		test::@check(false, "SKIPPED — the fixed rectangle is not in the tree");
		return;
	}
	test::@check(fixed.size.x == 70.0 && fixed.size.y == 30.0, "the field decides the size with no layout written");

	Element*? bar = ui.find_id("bar");
	if (catch bar)
	{
		test::@check(false, "SKIPPED — the bar rectangle is not in the tree");
		return;
	}
	test::@check(bar.size.y == 24.0, "a set component is fixed");
	test::@check(bar.size.x == 400.0, "and a zero component fills the column's own width, top-down");

	// The field is read live, so mutating it and asking for layout resizes.
	fixed.widget_as(Rectangle).size = { 90.0, 40.0 };
	fixed.request_layout();
	ui.flush();
	test::@check(fixed.size.x == 90.0 && fixed.size.y == 40.0, "mutating the field and requesting layout resizes");
}

<*
 Rig > Quadruped preset drops a whole body plan in, and one Ctrl+Z takes it out.

 Where the preset lands is `preset-test`'s question — it has fixtures with known
 insides and no window to get in the way. What only this file can answer is the
 part that makes a preset worth *trying*: whether nineteen dots and eighteen
 bones are one entry in the history or thirty-seven. A preset that unwinds a dot
 at a time is one nobody experiments with, and the only thing standing between
 those two behaviours is a single `commit` at the end of the operation.

 The fixture's mesh is a cube, which is the useful degenerate case here: solid
 everywhere, so no dot can strand, and symmetric front-to-back, so the facing
 measurement ties and the table's own orientation stands. Both mean this check
 fails for one reason only — the grouping.
*>
fn void preset_lands_as_one_edit() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the body-plan chooser lands a preset as one edit");
	fixture.reset();

	// Through the library, which is the only place a body plan comes from now:
	// the quadruped pack's own rest skeleton, fitted to this mesh.
	usz quadruped = (usz)fixture.app.packs.len();
	foreach (usz i, &pack : fixture.app.packs)
	{
		if (pack.plan == "quadruped") quadruped = i;
	}
	if (quadruped >= (usz)fixture.app.packs.len())
	{
		test::@check(false, "SKIPPED — no quadruped pack in the library");
		return;
	}

	test::@check(fixture.app.apply_pack_rig(quadruped), "the quadruped pack supplies a rig");

	sz dots = fixture.doc().dots.len();
	test::@check(dots == QUADRUPED_PACK_DOTS, "using a pack's rig places its whole body plan");
	test::@check(fixture.doc().edges.len() == QUADRUPED_PACK_DOTS - 1, "every dot but the root carries a bone");
	test::@check(fixture.doc().plan == "quadruped", "and stamps the document with the pack's plan");
	if (dots != QUADRUPED_PACK_DOTS) return;

	test::@check(fixture.doc().root_id == fixture.doc().dots[0].id, "the first dot of the table is the root");

	// A rig the exporter accepts, which the dots existing does not imply: the
	// BFS has to reach every one from that root and hand them back parents
	// before children, or the preset has quietly built a shape only it can read.
	rig::Skeleton? built = crig::build_skeleton(fixture.doc(), mem);
	if (catch built)
	{
		test::@check(false, "SKIPPED — the preset produced no skeleton");
		return;
	}
	rig::Skeleton skeleton = built;
	defer skeleton.free(mem);

	usz roots    = 0;
	bool ordered = true;
	foreach (usz i, parent : skeleton.parents)
	{
		if (parent < 0)
		{
			roots++;
			continue;
		}
		if (parent >= (int)i) ordered = false;
	}
	test::@check(skeleton.joints.len == QUADRUPED_PACK_DOTS, "one joint per dot");
	test::@check(roots == 1, "the whole plan hangs off a single root");
	test::@check(ordered, "parents precede their children");

	// The other half of the grouping, and the half the *final* commit is for:
	// every edit is recorded chained, so a preset with no commit at the end
	// still unwinds in one go — it just drags whatever the user does next in
	// with it. Deleting one dot and taking that back on its own is what says the
	// group actually closed. Done here, while the preset's root is still the
	// selection: undo drops a selection whose dot has gone.
	fixture.tap(VIEWPORT_CENTER, Key.X);
	test::@check(fixture.doc().dots.len() == QUADRUPED_PACK_DOTS - 1, "X after the preset deletes one dot");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == QUADRUPED_PACK_DOTS, "and undoing it does not drag the preset out too");

	// Remembered by id, not by count: redo has to bring back the dots that were
	// there rather than the same number of new ones. Held as a set and looked up
	// by id, because list order is deliberately not meaningful — `insert_dot`
	// appends, so a dot that has been through a delete and an undo comes back at
	// the end of the list and nothing is wrong.
	Dot[] placed = alloc::new_array(mem, Dot, (sz)dots);
	defer alloc::free(mem, placed);
	foreach (usz i, dot : fixture.doc().dots.array_view()) placed[i] = dot;

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 0, "one undo takes the entire preset back");
	test::@check(fixture.doc().edges.len() == 0, "and its bones with it");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Y);
	test::@check(fixture.doc().dots.len() == QUADRUPED_PACK_DOTS, "one redo puts it back");

	bool restored = fixture.doc().dots.len() == (sz)placed.len;
	foreach (dot : placed)
	{
		Dot* back = fixture.doc().find(dot.id);
		if (back == null || back.position != dot.position) restored = false;
	}
	test::@check(restored, "under the ids and positions it had");

	// Replaced, not stacked — and the clearing rides in the same undo entry as
	// the placing, which is the half that makes replacing safe. Called through
	// the model rather than the dialog on purpose: `apply_pack_rig` is what a
	// command line reaches, and it must not need a UI to be answered.
	test::@check(fixture.app.apply_pack_rig(quadruped), "the pack's rig can be used again");

	test::@check(fixture.doc().dots.len() == QUADRUPED_PACK_DOTS, "a second preset replaces the first rather than stacking on it");
	test::@check(fixture.doc().edges.len() == QUADRUPED_PACK_DOTS - 1, "and leaves one set of bones, not two");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == QUADRUPED_PACK_DOTS, "one undo brings the whole of the old rig back");

	bool whole = true;
	foreach (dot : placed)
	{
		Dot* back = fixture.doc().find(dot.id);
		if (back == null || back.position != dot.position) whole = false;
	}
	test::@check(whole, "under the ids and positions it had before the replacement");
}

<*
 How many drawings of a kind the last emitted frame carries in a given colour.

 The canvas is the display list the renderer consumes, so this asks the same
 question a screenshot would and answers it in a test: not "did the state
 change" but "is there a red line on the screen". Fill or border, because a
 stroked circle carries its colour in one and a line in the other.
*>
fn usz drawn(Fixture* fixture, DrawingKind kind, Color color)
{
	usz found = 0;
	foreach (drawing : fixture.ui.canvas.drawings.array_view())
	{
		if (drawing.kind != kind) continue;
		if (drawing.color == (Vec4)color || drawing.border_color == (Vec4)color) found++;
	}
	return found;
}

<*
 Raised when the canvas does not hold exactly one drawing of the kind asked for.
*>
faultdef NOT_ONE_DRAWING;

<*
 Where the one drawing of this kind and colour was put, in window coordinates.

 A quad is recorded as its top-left corner and its size, both absolute by the
 time they reach the canvas, so the centre is the point the painter was asked
 for. `drawn` counts; this says where, which is the only way to tell a moving
 overlay from one that is merely being re-emitted in the same place.

 @return? NOT_ONE_DRAWING : `No such drawing, or more than one — either way there is no single place to name.`
*>
fn Vec2? drawn_at(Fixture* fixture, DrawingKind kind, Color color)
{
	Vec2 found;
	usz count = 0;
	foreach (drawing : fixture.ui.canvas.drawings.array_view())
	{
		if (drawing.kind != kind) continue;
		if (drawing.color != (Vec4)color && drawing.border_color != (Vec4)color) continue;
		found = drawing.corner + drawing.size * 0.5f;
		count++;
	}
	if (count != 1) return NOT_ONE_DRAWING~;
	return found;
}

<*
 The axis lock, frame by frame.

 Driven with raw frames rather than through a `drag` helper because every claim
 here is about the middle of a gesture: what the press latched, what the key
 did to a move already in progress, and what the pointer is allowed to change
 afterwards. A helper that pressed and released would only ever show the
 endpoints.

 The retroactive half is the one worth having. Pressing X does not merely
 constrain what happens next — it puts back the two coordinates the free drag
 had already changed, so a user who has dragged a joint out of a leg can lock
 the axis they meant and get the other two back without starting over.
*>
fn void axis_lock_confines_a_move() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an axis lock confines a move to one axis");

	// From a known camera: the default three-quarter view is the one the lock
	// has to work in, and an earlier check leaves the camera wherever it
	// orbited to.
	fixture.reset();
	fixture.click(VIEWPORT_CENTER);
	fixture.ensure_a_dot();

	Dot before = fixture.doc().dots[0];
	Vec2? at   = fixture.pixel_of(before.id);
	if (catch at)
	{
		test::@check(false, "the dot is on screen to grab");
		return;
	}

	Vec2 away     = at + (Vec2) { 120.0, 70.0 };
	// Alt marks this as the rest-rig move; without it a bare drag with no clip
	// leaves the dot alone. Only the frame that crosses CLICK_SLOP reads Alt —
	// once the move is live it continues under the button alone.
	Key[1] hold_alt = { Key.LEFT_ALT };
	Key[1] lock_x   = { Key.X };

	fixture.feed(at, keys: hold_alt[..]);
	fixture.feed(at, left: true, keys: hold_alt[..]);
	test::@check(fixture.app.drag.dot == 0 && fixture.app.selected == before.id,
		"the press selects without becoming a rest drag before the pointer moves");

	fixture.feed(away, left: true, keys: hold_alt[..]);
	test::@check(fixture.app.drag.dot == before.id, "pointer travel takes hold of the dot");
	test::@check(fixture.app.drag.axis == DragAxis.FREE, "and the move starts unconstrained");
	Dot* dot = fixture.doc().find(before.id);
	if (!dot)
	{
		test::@check(false, "the dot survives the drag");
		return;
	}
	test::@check(dot.position != before.position, "a free drag moves it");

	// The feedback is the feature, so it is asserted on the display list rather
	// than left to a screenshot nobody takes: a ghost where the dot was picked
	// up, and no axis line until an axis is chosen.
	test::@check(drawn(fixture, DrawingKind.ELLIPSE, crig::GHOST) == 1, "a ghost marks where it was grabbed");
	test::@check(
		drawn(fixture, DrawingKind.LINE, crig::AXIS_X.dim(crig::GUIDE_DIM)) == 0,
		"and an unlocked move draws no axis line"
	);

	fixture.feed(away, left: true, keys: lock_x[..]);
	fixture.feed(away, left: true);
	test::@check(fixture.app.drag.axis == DragAxis.X, "X locks the move to X");
	test::@check(fixture.doc().dots.len() == 1, "and does not delete the selection on the way");

	Vec3 locked = dot.position;
	test::@check(
		locked.y == before.position.y && locked.z == before.position.z,
		"the lock puts back the two coordinates it does not own"
	);
	test::@check(
		drawn(fixture, DrawingKind.LINE, crig::AXIS_X.dim(crig::GUIDE_DIM)) == 1,
		"and the axis it is confined to is drawn in that axis' colour"
	);

	Vec2 further = away + (Vec2) { 90.0, 40.0 };
	fixture.feed(further, left: true);
	test::@check(
		dot.position.y == before.position.y && dot.position.z == before.position.z,
		"and holds them while the pointer keeps moving"
	);
	test::@check(dot.position.x != locked.x, "which is still free to slide");

	fixture.feed(further, left: true, keys: lock_x[..]);
	fixture.feed(further, left: true);
	test::@check(fixture.app.drag.axis == DragAxis.FREE, "the same key again releases the lock");

	fixture.feed(further);
	test::@check(fixture.app.drag.dot == 0, "and the release ends the move");
	test::@check(drawn(fixture, DrawingKind.ELLIPSE, crig::GHOST) == 0, "which takes the guides off the canvas");
	test::@check(fixture.app.undo_stack.can_undo(), "which banks it as an edit");
}

<*
 The axis line survives the camera coming in close.

 The line is drawn a body's length either way from the joint, which is what makes
 it read as a direction through the model rather than a segment between two
 arbitrary points — and it is also what puts one of its ends behind the eye as
 soon as the view comes in. A guide that needed both ends to project drew nothing
 at all from there: not a shortened line, no line, at exactly the distance
 somebody works at when they reach for a lock in the first place.

 The check above locks from the framed distance, where both ends are comfortably
 in front, which is why it never saw this. Same gesture, one camera closer.
*>
fn void an_axis_line_survives_a_close_camera() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an axis line survives a close camera");

	fixture.reset();

	// In before anything is drawn, to where a rigger works when the thing being
	// placed is small. Set on the state rather than scrolled because the overlay
	// repaints on cui's own watch of the camera, and a field poked mid-gesture
	// leaves the canvas holding the frame before it — which is a stale picture
	// this check would happily read as a pass.
	fixture.click(VIEWPORT_CENTER);
	fixture.ensure_a_dot();
	fixture.app.camera.distance *= 0.15f;

	Vec2? at = fixture.pixel_of(fixture.doc().dots[0].id);
	if (catch at)
	{
		test::@check(false, "the dot is on screen to grab");
		return;
	}

	// Alt held throughout — the rest-rig move is Alt's gesture now, and the axis
	// lock rides on top of it. X joins Alt on the frame that locks.
	Key[1] hold_alt = { Key.LEFT_ALT };
	Key[2] alt_and_x = { Key.LEFT_ALT, Key.X };
	Vec2 away = at + (Vec2) { 60.0, 40.0 };

	fixture.feed(at, keys: hold_alt[..]);
	fixture.feed(at, left: true, keys: hold_alt[..]);
	fixture.feed(away, left: true, keys: hold_alt[..]);
	fixture.feed(away, left: true, keys: alt_and_x[..]);
	fixture.feed(away, left: true, keys: hold_alt[..]);
	test::@check(fixture.app.drag.axis == DragAxis.X, "X locks the move to X");

	// The premise: one end of the guide really is behind the eye from here, so
	// the fixture poses the question rather than passing by luck.
	Vec3 reach = { fixture.app.picker.scale, 0, 0 };
	Matrix4f view_projection = fixture.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y);
	bool one_is_lost = false;
	if (catch crig::project(view_projection, fixture.app.drag.from - reach, VIEWPORT)) one_is_lost = true;
	if (catch crig::project(view_projection, fixture.app.drag.from + reach, VIEWPORT)) one_is_lost = true;
	test::@check(one_is_lost,
		"both ends of the guide still project from here, so this fixture no longer poses the question");

	test::@check(
		drawn(fixture, DrawingKind.LINE, crig::AXIS_X.dim(crig::GUIDE_DIM)) == 1,
		"the guide is drawn with one end behind the camera"
	);

	fixture.feed(away);
}

<*
 ESC during a move puts the dot back and records nothing.

 Undo would also put it back, but only once the move has become an edit, and
 the history is not where a half-finished gesture belongs. The check that the
 stack did not grow is the whole point: a cancel that recorded a move to the
 same place would still cost the user a Ctrl+Z later.
*>
fn void escape_abandons_a_move() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("escape abandons a move");

	fixture.reset();
	fixture.click(VIEWPORT_CENTER);
	fixture.ensure_a_dot();

	Dot before = fixture.doc().dots[0];
	Vec2? at   = fixture.pixel_of(before.id);
	if (catch at)
	{
		test::@check(false, "the dot is on screen to grab");
		return;
	}

	sz banked     = fixture.app.undo_stack.edits.len();
	// Alt held to start the rest-rig move; ESC joins it to cancel.
	Key[1] hold_alt   = { Key.LEFT_ALT };
	Key[2] alt_escape = { Key.LEFT_ALT, Key.ESCAPE };
	Vec2 away         = at + (Vec2) { 100.0, 60.0 };

	fixture.feed(at, keys: hold_alt[..]);
	fixture.feed(at, left: true, keys: hold_alt[..]);
	fixture.feed(away, left: true, keys: hold_alt[..]);
	test::@check(fixture.doc().find(before.id).position != before.position, "the drag moved it");

	fixture.feed(away, left: true, keys: alt_escape[..]);
	fixture.feed(away, left: true);
	test::@check(fixture.doc().find(before.id).position == before.position, "escape puts it back");
	test::@check(fixture.app.drag.dot == 0, "and ends the move there and then");

	// The pointer is still down: what it does next must not pick the dot back up.
	fixture.feed(away + (Vec2) { 40.0, 0 }, left: true);
	test::@check(fixture.doc().find(before.id).position == before.position, "moving on does not resume it");

	fixture.feed(away + (Vec2) { 40.0, 0 });
	test::@check(fixture.app.undo_stack.edits.len() == banked, "and nothing reached the history");
}

<*
 The clamp, against the fixture cube.

 Asserted on the function rather than through a gesture because what it claims
 is about the model and not about the pointer: a locked move may travel as far
 along its line as the solid material it started in reaches, and no further.
 Aiming a drag at a wall through the camera would be testing the projection.
*>
fn void a_locked_move_stays_in_the_body() @test
{
	io::printn("a locked move stops at the far wall");

	rig::MeshVoxels voxels = rig::build_voxels(mem, cube());
	defer voxels.free(mem);
	if (!voxels.usable())
	{
		test::@check(false, "SKIPPED — the cube did not voxelize");
		return;
	}

	// The cube runs from -1 to 1 on every axis, so a target ten bodies away is
	// one the clamp has to stop short of.
	Vec3 inside  = { 0, 0, 0 };
	Vec3 stopped = crig::clamp_inside(&voxels.grid, inside, { 20.0, 0, 0 });
	test::@check(stopped.x > 0.0f, "it travels toward the target");
	test::@check(stopped.x <= 1.0f + voxels.grid.cell, "but no further than the surface");
	test::@check(stopped.y == 0.0f && stopped.z == 0.0f, "and only along the line it was given");

	// Reaching for a point inside costs nothing: the clamp is a limit, not a snap.
	Vec3 near = crig::clamp_inside(&voxels.grid, inside, { 0.5f, 0, 0 });
	test::@check(near.x == 0.5f, "a target inside the body is reached exactly");

	// No grid at all — an open or tiny mesh — is not a reason to freeze a drag.
	collision::VoxelGrid nothing;
	Vec3 unclamped = crig::clamp_inside(&nothing, inside, { 20.0, 0, 0 });
	test::@check(unclamped.x == 20.0f, "with no grid the move is taken at its word");
}

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
// B5.5 — the view gizmo
// 
// Two halves, and the second is the one that matters. The snap math is pure and
// checkable with no window; the part that has bitten crig twice already is a
// thing drawn over the viewport quietly eating — or quietly *not* eating — the
// clicks that land on it.

<*
 A snap ends looking exactly down the axis it was given.

 No fixture: `snap_to`/`advance` are on the camera precisely so the numpad path
 and the gizmo path run the same code, and so this can be asserted without a
 window.
*>
fn void snap_lands_on_the_axis() @test
{
	io::printn("a snap lands on its axis");

	crig::OrbitCamera camera = crig::framed(cube().bounds());
	camera.snap_to(crig::ViewAxis.POS_X);

	// Bounded, so a snap that never clears its flag fails the run instead of
	// hanging it.
	uint frames = 0;
	while (camera.advance(DT) && frames < 1000) frames++;

	test::@check(!camera.snapping, "the animation finishes");
	test::@check(frames > 1, "and takes more than one frame — it is eased, not a cut");

	Vec3 expected = camera.target + (Vec3) { camera.distance, 0.0, 0.0 };
	test::@check((camera.eye() - expected).length() < 1e-3, "the eye ends on +X, looking back at the target");

	// The other half of "looking down the axis": that ball is now dead-on, so
	// the gizmo draws it at its own centre with nothing offset.
	Vec3 on_screen = camera.view_direction(crig::ViewAxis.POS_X.direction);
	test::@check(math::abs(on_screen.x) < 1e-3 && math::abs(on_screen.y) < 1e-3, "and the +X ball sits on the gizmo's centre");
	test::@check(on_screen.z > 0.99, "pointing straight at the viewer");
}

<*
 Yaw takes the short way round.

 350° to 0° is 10° of turn, but the naive interpolation runs it backwards
 through 349, 348 … and spins the model almost the whole way about. For a
 quarter of a second the user cannot tell what happened, which is worse than no
 animation at all.
*>
fn void snap_takes_the_short_way() @test
{
	io::printn("a snap turns the short way");

	crig::OrbitCamera camera = crig::framed(cube().bounds());
	camera.yaw = 350.0;
	camera.snap_to(crig::ViewAxis.POS_Z); // yaw 0

	float travel = math::abs(camera.snap_to_yaw - 350.0f);
	test::@check(travel < 180.0f, "the turn is under half a revolution");
	test::@check(math::abs(travel - 10.0f) < 1e-3, "and is the 10° one, not the 350° one");

	uint frames = 0;
	while (camera.advance(DT) && frames < 1000) frames++;

	// 360, not 0: the same camera, reached by going forwards. Normalizing the
	// angle afterwards would be tidier to read and would throw away the only
	// evidence of which way it went.
	test::@check(math::abs(camera.yaw - 360.0f) < 1e-3, "and lands on the front view");
	Vec3 expected = camera.target + (Vec3) { 0.0, 0.0, camera.distance };
	test::@check((camera.eye() - expected).length() < 1e-3, "with the eye actually on +Z");
}

<*
 A click on the gizmo must not also place a dot.

 This is the same class of bug as both B4 failures and it cannot be seen in a
 screenshot: the gizmo is a child of the viewport, so anything it declines
 bubbles down to the model underneath and places a joint the user never asked
 for. It has to *consume*.
*>
fn void gizmo_click_does_not_place_a_dot() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the gizmo swallows its own clicks");
	fixture.reset();

	Element*? gizmo = fixture.ui.find_id("gizmo");
	if (catch gizmo)
	{
		test::@check(false, "SKIPPED — the gizmo is not in the tree");
		return;
	}

	crig::ViewGizmo* widget = gizmo.widget_as(crig::ViewGizmo);
	Viewport* under         = fixture.viewport.widget_as(Viewport);

	// Asserted on which widget latched the press, not on "no dot appeared". The
	// gizmo sits in a corner of the viewport with no model behind it, so nothing
	// is placed there whatever happens and the obvious assertion is vacuous —
	// which is the same trap `widget_as` laid at B4. What is being claimed is
	// that the press stopped at the gizmo, and that is what gets checked.
	fixture.feed(gizmo.absolute + gizmo.size * 0.5f);
	fixture.feed(gizmo.absolute + gizmo.size * 0.5f, left: true);
	test::@check(widget.dragging, "a press on the body is taken by the gizmo");
	test::@check(!under.orbiting, "and never reaches the viewport underneath");
	fixture.feed(gizmo.absolute + gizmo.size * 0.5f);
	test::@check(fixture.doc().dots.len() == 0, "so the release places nothing");

	// The corners of its square are not a dead zone: the gizmo is a disc inside
	// a box, and everything outside the disc has to bubble down to the model.
	// 3px in from the corner is 55px from the centre, comfortably outside the
	// 42px body.
	Vec2 corner = gizmo.absolute + (Vec2) { 3.0, 3.0 };
	fixture.feed(corner);
	fixture.feed(corner, left: true);
	test::@check(!widget.dragging, "a press on the corner of its box is declined");
	test::@check(under.orbiting, "and falls through to the viewport");
	fixture.feed(corner);
}

<*
 Clicking a ball snaps the view, driven end to end: through `process_input`, the
 hit test, the widget, the camera and `Viewport.update`'s per-frame tick.
*>
fn void gizmo_ball_snaps_the_view() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("clicking a ball snaps the view");
	fixture.reset();

	Element*? gizmo = fixture.ui.find_id("gizmo");
	if (catch gizmo)
	{
		test::@check(false, "SKIPPED — the gizmo is not in the tree");
		return;
	}

	// Where the +X ball actually is right now, asked of the widget rather than
	// recomputed here — a test that reimplements the layout it is checking
	// agrees with itself and with nothing else.
	crig::ViewGizmo* widget = gizmo.widget_as(crig::ViewGizmo);
	Vec3 ball               = widget.ball_at(gizmo, &fixture.app.camera, crig::ViewAxis.POS_X);
	fixture.click(gizmo.absolute + (Vec2) { ball.x, ball.y });

	test::@check(fixture.app.camera.snapping, "the press starts a snap");
	test::@check(fixture.doc().dots.len() == 0, "and places no dot");

	// Run it out. `update` is ticked by process_input, so plain mouse frames
	// away from everything are enough to drive the animation.
	for (uint i = 0; i < 40 && fixture.app.camera.snapping; i++) fixture.feed(VIEWPORT_CENTER);

	test::@check(!fixture.app.camera.snapping, "which finishes on its own");
	Vec3 expected = fixture.app.camera.target + (Vec3) { fixture.app.camera.distance, 0.0, 0.0 };
	test::@check((fixture.app.camera.eye() - expected).length() < 1e-3, "with the camera on +X");
}

<*
 The numpad reaches the same operation as the gizmo.

 Ctrl is the opposite face here rather than a different command, which is the
 one place the view keys have to be tested *before* the undo/redo block they
 would otherwise fall into.
*>
fn void numpad_snaps_the_view() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the numpad snaps the view");
	fixture.reset();

	// Focus the viewport: keys only reach the focused element, and a left press
	// inside it is what grants that.
	fixture.click(VIEWPORT_CENTER);

	fixture.tap(VIEWPORT_CENTER, Key.NUM_3); // right side
	test::@check(fixture.app.camera.snapping, "numpad 3 starts a snap");
	for (uint i = 0; i < 40 && fixture.app.camera.snapping; i++) fixture.feed(VIEWPORT_CENTER);

	Vec3 right = fixture.app.camera.target + (Vec3) { fixture.app.camera.distance, 0.0, 0.0 };
	test::@check((fixture.app.camera.eye() - right).length() < 1e-3, "and lands on +X");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.NUM_3); // and the far side
	for (uint i = 0; i < 40 && fixture.app.camera.snapping; i++) fixture.feed(VIEWPORT_CENTER);

	Vec3 left = fixture.app.camera.target - (Vec3) { fixture.app.camera.distance, 0.0, 0.0 };
	test::@check((fixture.app.camera.eye() - left).length() < 1e-3, "ctrl+numpad 3 lands on -X");

	// The undo/redo block sits behind the same ctrl test, so a view key routed
	// past its own case would land there instead. One dot exists; if ctrl+Z had
	// run it would be gone.
	test::@check(fixture.doc().dots.len() == 1, "and did not fall through to undo");
}

<*
 The digits along the top row reach the same three views as the numpad.

 The keyboard most of this is used on has no numpad, and the View menu and the
 Controls sheet both say "1 / 3 / 7" without saying where — so on a laptop the
 three orthogonal views were advertised and unreachable. All three plus their
 ctrl faces, because a binding that covered only the plain press would leave
 half of what the menu lists still out of reach.
*>
fn void the_top_row_digits_snap_the_view() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the top-row digits snap the view, the same as the numpad");
	fixture.reset();

	fixture.click(VIEWPORT_CENTER);

	// Front, right, top and their opposite faces, each as the axis the numpad
	// case answers with. Read off `view_key` rather than off the camera's own
	// enum, so a case wired to the wrong axis is caught here rather than looking
	// like a camera bug.
	Key[3] top_row = { Key.KEY_1, Key.KEY_3, Key.KEY_7 };
	Key[3] numpad = { Key.NUM_1, Key.NUM_3, Key.NUM_7 };

	for (usz i = 0; i < 3; i++)
	{
		for (usz c = 0; c < 2; c++)
		{
			bool ctrl = c == 1;

			crig::ViewAxis? wanted = crig::view_key(numpad[i], ctrl);
			if (catch wanted)
			{
				test::@check(false, "the numpad key %d answers nothing", (int)i);
				continue;
			}

			crig::ViewAxis? got = crig::view_key(top_row[i], ctrl);
			if (catch got)
			{
				test::@check(false, "top-row %d%s reaches no view at all",
					(int)i, ctrl ? " with ctrl" : "");
				continue;
			}
			test::@check(got == wanted, "top-row %d%s points the camera at %d, the numpad at %d",
				(int)i, ctrl ? " with ctrl" : "", (int)got.ordinal, (int)wanted.ordinal);
		}
	}

	// And the whole way through the window, not only through `view_key`: the
	// press has to survive the ctrl block in `AppRoot.on_key` the same way the
	// numpad does.
	fixture.tap(VIEWPORT_CENTER, Key.KEY_3);
	test::@check(fixture.app.camera.snapping, "top-row 3 starts a snap");
	for (uint i = 0; i < 40 && fixture.app.camera.snapping; i++) fixture.feed(VIEWPORT_CENTER);

	Vec3 right = fixture.app.camera.target + (Vec3) { fixture.app.camera.distance, 0.0, 0.0 };
	test::@check((fixture.app.camera.eye() - right).length() < 1e-3, "and lands on +X");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.KEY_3);
	for (uint i = 0; i < 40 && fixture.app.camera.snapping; i++) fixture.feed(VIEWPORT_CENTER);

	Vec3 left = fixture.app.camera.target - (Vec3) { fixture.app.camera.distance, 0.0, 0.0 };
	test::@check((fixture.app.camera.eye() - left).length() < 1e-3, "ctrl+3 on the top row lands on -X");

	// The same guard the numpad test keeps: ctrl+3 must not have fallen through
	// to the undo block behind it.
	test::@check(fixture.doc().dots.len() == 1, "and did not fall through to undo");
}

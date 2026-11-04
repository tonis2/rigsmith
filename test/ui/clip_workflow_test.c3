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
// M5.

<*
 The header's shading buttons, the View menu and Z are one switch: a button
 picks the shading, Z goes to Wireframe and back to the fill it left — Textured
 included, not always Solid — and the choice is the config's, so it is kept
 between runs.
*>
fn void the_shading_buttons_switch_solid_textured_and_wireframe() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	Element* strip = fixture.ui.find_id("shading")!!;
	Vec2 cell = { crig::TINT_CELL_W, 0 };
	Vec2 first = strip.absolute + (Vec2) { crig::TINT_CELL_W * 0.5f, crig::TINT_CELL_H * 0.5f };

	test::@check(fixture.app.config.viewport_shading == ShadingMode.SOLID, "Solid is the default");
	fixture.click(first + cell * 2.0f);
	test::@check(fixture.app.config.viewport_shading == ShadingMode.TEXTURED, "the third button is Textured");
	test::@check(crig::query_shading_textured(fixture.ui).checked && !crig::query_shading_solid(fixture.ui).checked,
		"the View menu does not agree with the buttons");

	fixture.tap(VIEWPORT_CENTER, Key.Z);
	test::@check(fixture.app.wireframe(), "Z goes to Wireframe");
	fixture.tap(VIEWPORT_CENTER, Key.Z);
	test::@check(fixture.app.config.viewport_shading == ShadingMode.TEXTURED, "Z goes back to Textured, the fill it left");

	strip = fixture.ui.find_id("shading")!!;
	first = strip.absolute + (Vec2) { crig::TINT_CELL_W * 0.5f, crig::TINT_CELL_H * 0.5f };
	fixture.click(first);
	test::@check(fixture.app.wireframe(), "the first button is Wireframe");
	fixture.click(first + cell);
	test::@check(fixture.app.config.viewport_shading == ShadingMode.SOLID, "the second button is Solid");
}

<*
 Wireframe: the surface drawn as lines, and the rig readable through it.

 The pipeline swap itself is not assertable here — there is no GPU in this run —
 so what is checked is everything on this side of it: that the two ways in agree
 on one flag, and that the overlay changes with it. The second half is the one
 worth having. A wireframe that still dimmed the dots behind the body would be a
 mode whose whole reason for existing had been cancelled by a cue about skin
 that is no longer painted, and nothing about the flag says so.

 Driven from a front view rather than the default three-quarter one, because
 "behind the body" has to mean something exact: the eye ends on +Z, and a dot
 past the far wall on the same axis is then occluded by construction.
*>
fn void wireframe_shows_the_rig_through_the_mesh() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("wireframe draws the mesh as lines and stops hiding the rig");
	fixture.reset();

	test::@check(!fixture.app.wireframe(), "it starts off");

	fixture.tap(VIEWPORT_CENTER, Key.Z);
	test::@check(fixture.app.wireframe(), "Z turns it on");
	fixture.tap(VIEWPORT_CENTER, Key.Z);
	test::@check(!fixture.app.wireframe(), "and again turns it off");

	// The menu item and the key are the same operation reached two ways, which is
	// only true while they are the same implementation.
	Vec2? view_title = fixture.center_of("View");
	if (catch view_title)
	{
		test::@check(false, "SKIPPED — the View title is not on the pane header");
		return;
	}
	fixture.click(view_title);
	Vec2? item = fixture.center_of("Wireframe");
	if (catch item)
	{
		test::@check(false, "SKIPPED — Wireframe is not in the View menu");
		return;
	}
	fixture.click(item);
	test::@check(fixture.app.wireframe(), "View > Wireframe turns it on too");

	fixture.tap(VIEWPORT_CENTER, Key.Z);
	test::@check(!fixture.app.wireframe(), "and the key takes the menu's state back off");

	// Straight down +Z, so the occlusion cast has an answer that does not depend
	// on where an earlier check left the camera.
	fixture.app.camera.snap_to(crig::ViewAxis.POS_Z);
	for (uint i = 0; i < 1000 && fixture.app.camera.advance(DT); i++)
	{
	}

	// Past the cube's far wall, on the view axis: on screen, and with the whole
	// body between it and the eye.
	fixture.app.place({ 0, 0, -1.5 });
	fixture.app.select(0); // placing selects, and a selected dot draws in its own colour
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	test::@check(
		fixture.app.picker.occluded(fixture.app.camera.eye(), { 0, 0, -1.5 }),
		"the dot is behind the body from here"
	);
	test::@check(
		drawn(fixture, DrawingKind.ELLIPSE, crig::rig_overlay_ink(crig::DOT, crig::rig_overlay_opacity(0, 0, 0, true, false, 1.0f))) == 1,
		"and the shaded view dims it for being there"
	);
	Viewport* faded_view = fixture.viewport.widget_as(Viewport);
	Matrix4f projection = fixture.app.camera.view_projection(fixture.viewport.size.x / fixture.viewport.size.y);
	Vec2? faded_at = crig::project(projection, { 0, 0, -1.5 }, fixture.viewport.size);
	if (try faded_at)
	{
		test::@check(faded_view.pick_dot(fixture.viewport, faded_at) != 0,
			"a translucent occluded dot remains selectable");
	}
	else { test::@check(false, "the faded test dot must project into view"); }

	fixture.tap(VIEWPORT_CENTER, Key.Z);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(
		drawn(fixture, DrawingKind.ELLIPSE, crig::rig_overlay_ink(crig::DOT, crig::rig_overlay_opacity(0, 0, 0, true, false, 1.0f))) == 0,
		"wireframe takes the dimming off"
	);
	test::@check(drawn(fixture, DrawingKind.ELLIPSE, crig::rig_overlay_ink(crig::DOT, 0.8f)) == 1, "and removes mesh occlusion while retaining the restrained overlay");

	fixture.tap(VIEWPORT_CENTER, Key.Z);
}

<*
 The two things the overlay says about a placed dot: what it is called, and
 where its body plan wanted it.

 Driven in wireframe throughout, so occlusion never enters into it. Labels dim
 with the dots when the body is in front of them, and a dot fitted into a cube
 can land either side of the skin depending on the plan — which would make every
 colour below a coin toss. That the dimming happens at all is
 `check_wireframe_shows_the_rig_through_the_mesh`'s claim, not this one's.

 The ring and the line are asserted by colour on the canvas rather than by
 reading the state back, because the state is a lookup that a paint can perfectly
 well ignore. What the user is owed is a mark on the screen.
*>
fn void a_dot_shows_its_name_and_where_the_plan_wants_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a dot shows its name, and where the body plan wants it");
	fixture.reset();

	// Joint names live on the View menu now (N moved to the joint panel), so the
	// toggle is exercised through the menu handler the item calls.
	test::@check(!fixture.app.show_joint_names, "joint names start off");
	crig::menu_joint_names(fixture.ui);
	test::@check(fixture.app.show_joint_names, "the View menu turns them on");
	crig::menu_joint_names(fixture.ui);
	test::@check(!fixture.app.show_joint_names, "and again turns them off");

	// Nothing placed carries a name, so the item is greyed and the click that
	// would have toggled it has to do nothing at all.
	Vec2? view_title = fixture.center_of("View");
	if (catch view_title)
	{
		test::@check(false, "SKIPPED — the View title is not on the pane header");
		return;
	}
	fixture.click(view_title);
	Vec2? item = fixture.center_of("Joint names");
	if (catch item)
	{
		test::@check(false, "SKIPPED — Joint names is not in the View menu");
		return;
	}
	fixture.click(item);
	test::@check(!fixture.app.show_joint_names, "with no named dot the menu item is dead");
	test::@check(fixture.in_tree("Joint names"), "and the click on it does not even close the menu");

	// Which leaves the dropdown open over the middle of the view, where the rest
	// of this check aims — a greyed item swallows the click without dismissing.
	fixture.tap(view_title, Key.ESCAPE);

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — no biped plan in this library");
		return;
	}

	uint chosen = fixture.app.selected;
	Dot* dot = fixture.doc().find(chosen);
	if (!dot || dot.name.len == 0)
	{
		test::@check(false, "SKIPPED — the plan placed no named dot to select");
		return;
	}
	String named = dot.name;

	fixture.app.config.viewport_shading = ShadingMode.WIREFRAME;
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	test::@check(
		drawn(fixture, DrawingKind.GLYPH, crig::LABEL) == named.len,
		"the selected dot prints its name with the toggle still off"
	);
	test::@check(
		drawn(fixture, DrawingKind.GLYPH, crig::LABEL_DIM) == 0,
		"and no other dot prints anything"
	);

	crig::menu_joint_names(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(
		drawn(fixture, DrawingKind.GLYPH, crig::LABEL_DIM) > 0,
		"the toggle brings the rest of the names in"
	);
	test::@check(
		drawn(fixture, DrawingKind.GLYPH, crig::LABEL) == named.len,
		"and leaves the selected one in its own colour"
	);
	crig::menu_joint_names(fixture.ui);

	// The plan placed this dot, so the plan wants it exactly where it is — and a
	// dot already right must not grow decoration.
	test::@check(fixture.app.plan_target(named) != null, "the plan carries a target for that name");
	if (try fixture.app.selected_plan_target())
	{
		test::@check(false, "a freshly fitted dot reports an offset from its own target");
	}
	else
	{
		test::@check(true, "a freshly fitted dot has no offset to show");
	}
	fixture.feed(VIEWPORT_CENTER);
	test::@check(drawn(fixture, DrawingKind.ELLIPSE, crig::TARGET_RING) == 0, "so no ring is drawn");

	// Far enough to clear the threshold, which is a fraction of the mesh rather
	// than a distance — the cube is one unit across and another mesh would not be.
	Vec3 wanted = dot.position;
	dot.position = wanted + (Vec3) { fixture.app.picker.scale * 0.1f, 0, 0 };
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	if (try Vec3 target = fixture.app.selected_plan_target())
	{
		test::@check(
			(target - wanted).length() < 1.0e-5f,
			"dragged off, the target stays where the plan put it"
		);
	}
	else
	{
		test::@check(false, "dragged off its target, the dot still reports no offset");
	}

	// An offset to show and still nothing shown, because the names are off. A
	// plan is fitted to a bounding box, so on a body no preset describes most of
	// its targets point somewhere the dot should not go — a ring on every
	// selection would be a standing instruction to drag the rig wrong. The Joint
	// names toggle is how the guesses are asked for, which is what the Controls
	// sheet says it does.
	test::@check(drawn(fixture, DrawingKind.ELLIPSE, crig::TARGET_RING) == 0,
		"the plan target is drawn over a dot nobody asked the plan about");

	crig::menu_joint_names(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(drawn(fixture, DrawingKind.ELLIPSE, crig::TARGET_RING) == 1, "a ring marks where it belongs");
	test::@check(drawn(fixture, DrawingKind.LINE, crig::TARGET_LINE) == 1, "and a line joins the two");

	// A hand-placed dot is unnamed, so there is nothing to look a target up by.
	// Placed through the operation rather than by clicking: the plan has just
	// covered the model in dots, and a click landing on one of them selects it
	// instead — which would leave this asserting about a named dot again.
	fixture.app.place({ 0.4, -0.4, 0.4 });
	Dot* placed = fixture.doc().find(fixture.app.selected);
	test::@check(placed != null && placed.name.len == 0, "a hand-placed dot carries no name");
	if (try fixture.app.selected_plan_target())
	{
		test::@check(false, "an unnamed dot claims a plan target");
	}
	else
	{
		test::@check(true, "and so has no target to be measured against");
	}

	fixture.app.config.viewport_shading = ShadingMode.SOLID;

	// The order startup actually uses: a saved session restores its plan tag
	// before the library it names has been read. A fit cached against the empty
	// library would then never be revisited, and the ring would never appear.
	fixture.app.load_packs("build/no-such-animation-folder");
	fixture.doc().set_plan("biped");
	test::@check(fixture.app.plan_target(named) == null, "with no library there is nothing to fit against");

	fixture.app.load_packs(library::ready());
	test::@check(fixture.app.plan_target(named) != null, "and the library arriving is what the fit was waiting for");

	fixture.app.expanded_pack = fixture.app.packs.len() > 0 ? 0 : -1;
}

<*
 The rig travels with the body while a clip plays.

 Two halves, and the second is the one worth having. That the numbers move is
 arithmetic; that the *pointer* follows them is what makes a moving overlay
 usable — a dot drawn mid-stride and picked where it rests is a dot nobody can
 click for as long as the clip runs, and every dot is mid-stride.

 Driven in wireframe, because an occluded dot is drawn in a dimmed colour and
 the colour is how the drawings below are found. Whether the cube's skin happens
 to be in front of a given joint is `check_occlusion_only_dims_what_is_behind`'s
 question.
*>
fn void the_rig_walks_with_the_body() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the rig walks with the body while a clip plays");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — no biped plan in this library");
		return;
	}
	fixture.ui.flush();
	fixture.app.config.viewport_shading = ShadingMode.WIREFRAME;

	bool wandered = false;
	foreach (dot : fixture.doc().dots.array_view())
	{
		if (fixture.app.dot_position(dot) != dot.position) wandered = true;
	}
	test::@check(!wandered, "with nothing playing the overlay is the document, dot for dot");

	if (!fixture.app.start_animation_at(0))
	{
		test::@check(false, "SKIPPED — the first clip would not play on the plan's own rig");
		fixture.app.config.viewport_shading = ShadingMode.SOLID;
		return;
	}
	// Away from the start of the cycle, which is the instant nearest the rest
	// pose the rig was fitted in.
	fixture.app.tick_animation(0.25f);

	test::@check(
		fixture.app.posed_dots.len == (usz)fixture.doc().dots.len(),
		"playing carries one posed position per dot"
	);

	// Whichever joint this clip throws furthest across the screen. Asking for a
	// named limb would work too, but the claim is about the overlay rather than
	// about which part of a walk swings hardest.
	Matrix4f projection = fixture.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y);
	uint mover = 0;
	float furthest = 0.0f;
	Vec2 posed_at;
	Vec2 rest_at;

	foreach (dot : fixture.doc().dots.array_view())
	{
		Vec2? resting = crig::project(projection, dot.position, VIEWPORT);
		Vec2? now = crig::project(projection, fixture.app.dot_position(dot), VIEWPORT);
		if (catch resting) continue;
		if (catch now) continue;

		float travelled = (now - resting).length();
		if (travelled <= furthest) continue;

		furthest = travelled;
		mover = dot.id;
		posed_at = now;
		rest_at = resting;
	}

	// Two grab radii, so the dot has visibly left the circle a click would have
	// found it in a moment ago — the whole reason the pick test has to move with
	// the paint.
	test::@check(
		mover != 0 && furthest > crig::PICK_RADIUS * 2.0f,
		"the clip carries a dot well clear of where it rests"
	);
	if (mover == 0 || furthest <= crig::PICK_RADIUS * 2.0f)
	{
		fixture.app.stop_animation();
		fixture.app.config.viewport_shading = ShadingMode.SOLID;
		return;
	}

	fixture.app.select(mover);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	// Re-read after the frame, not before it: a frame advances the clock and then
	// paints, so the pixels measured above are one tick stale — which is a real
	// couple of pixels here and the reason this is not compared to them.
	Dot* moved = fixture.doc().find(mover);
	Vec2? shown = crig::project(projection, fixture.app.dot_position(*moved), VIEWPORT);
	Vec2? stored = crig::project(projection, moved.position, VIEWPORT);
	Vec2? circle = drawn_at(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED);
	if (catch shown)
	{
		test::@check(false, "SKIPPED — the moving dot left the screen");
		fixture.app.stop_animation();
		fixture.app.config.viewport_shading = ShadingMode.SOLID;
		return;
	}
	if (catch stored)
	{
		test::@check(false, "SKIPPED — the moving dot rests off screen");
		fixture.app.stop_animation();
		fixture.app.config.viewport_shading = ShadingMode.SOLID;
		return;
	}
	if (catch circle)
	{
		test::@check(false, "SKIPPED — the canvas holds no single selected-dot circle");
		fixture.app.stop_animation();
		fixture.app.config.viewport_shading = ShadingMode.SOLID;
		return;
	}
	posed_at = shown;
	rest_at = stored;

	test::@check(
		(circle - (posed_at + VIEWPORT_ORIGIN)).length() < 1.0f,
		"and paints its circle where the pose put it"
	);
	test::@check(
		(circle - (rest_at + VIEWPORT_ORIGIN)).length() > crig::PICK_RADIUS,
		"which is nowhere near where the document still keeps it"
	);

	Viewport* view = fixture.viewport.widget_as(Viewport);
	test::@check(view.pick_dot(fixture.viewport, posed_at) == mover, "a pick at the circle finds that dot");
	test::@check(view.pick_dot(fixture.viewport, rest_at) != mover, "and one at its rest position does not");

	// A press that finds no dot places one every other moment. Not through a
	// clip: the ray reaches the body as modelled, so the dot would land in a pose
	// nobody is looking at.
	Vec2[3] clear = { SPOT_A, SPOT_C, VIEWPORT_CENTER };
	Vec2 empty = { -1, -1 };
	foreach (spot : clear)
	{
		if (view.pick_dot(fixture.viewport, spot - VIEWPORT_ORIGIN) != 0) continue;
		empty = spot;
		break;
	}
	if (empty.x < 0.0f)
	{
		test::@check(false, "SKIPPED — every spot aimed at has a dot on it");
	}
	else
	{
		sz before = fixture.doc().dots.len();
		fixture.click(empty);
		test::@check(fixture.doc().dots.len() == before, "a click past the dots places nothing while it plays");
		test::@check(fixture.notice_text().starts_with("stop the clip"), "and says so rather than doing it quietly");
	}

	// A frame with no input in it and nobody asking for a repaint. The overlay is
	// cached per element, so unless playback invalidates it on its own the rig
	// stands still under a body walking out from under it — and every check above
	// would pass anyway, because each of them refreshed the interface by hand.
	Vec2? standing = drawn_at(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED);
	fixture.feed(VIEWPORT_CENTER);
	Vec2? ticked = drawn_at(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED);
	if (catch standing)
	{
		test::@check(false, "SKIPPED — no single selected-dot circle before the idle frame");
	}
	else if (catch ticked)
	{
		test::@check(false, "SKIPPED — no single selected-dot circle after it");
	}
	else
	{
		test::@check(ticked != standing, "and the overlay keeps up on a frame nobody asked it to repaint");
	}

	// The gesture itself, which is the pick test plus three frames of the clock —
	// the dot drifts a pixel or two between the press and the release, and that is
	// the point: a click has to land on a target that is still moving. A plain
	// click only selects; travelling beyond CLICK_SLOP is what takes hold of the
	// rest dot and stops the preview.
	fixture.app.select(0);
	fixture.app.refresh_ui();
	fixture.click(posed_at + VIEWPORT_ORIGIN);
	test::@check(fixture.app.selected == mover, "and a click on it selects it");
	test::@check(fixture.app.animating, "without stopping the pose merely to change selection");
	test::@check(fixture.app.drag.dot == 0, "or turning the click into a rest-dot drag");

	fixture.app.stop_animation();
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	test::@check(fixture.app.posed_dots.len == 0, "stopping drops the posed overlay");
	bool home = true;
	foreach (dot : fixture.doc().dots.array_view())
	{
		if (fixture.app.dot_position(dot) != dot.position) home = false;
	}
	test::@check(home, "and the rig is drawn from the document again");

	fixture.app.config.viewport_shading = ShadingMode.SOLID;
	fixture.app.refresh_ui();
}

<*
 The mesh and the rig are two pictures, and either can be put away.

 The renderer is what stops drawing the mesh, so a headless run cannot see that
 half directly — what it can see is everything the flag decides on this side of
 the GPU, which is the more interesting half anyway. Hiding the body takes the
 occlusion cue with it, because there is no longer any skin for a dot to be
 behind; hiding the rig takes the overlay away from the pointer as well as from
 the eye, so a click cannot select a dot nobody can see or add one to keep it
 company.

 Driven from a front view with a dot past the far wall, the same construction
 `check_wireframe_shows_the_rig_through_the_mesh` uses: "behind the body" has to
 be exact, not a guess about where an earlier check left the camera.
*>
fn void the_mesh_and_the_rig_hide_apart() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the mesh and the rig hide one at a time");
	fixture.reset();

	test::@check(fixture.app.show_mesh && fixture.app.show_rig, "both halves start on screen");
	test::@check(crig::effective_rig_overlay_strength(&fixture.app) == crig::DEFAULT_RIG_OVERLAY_STRENGTH,
		"the overlay starts at its restrained default");

	fixture.tap(VIEWPORT_CENTER, Key.B);
	test::@check(!fixture.app.show_mesh, "B puts the mesh away");
	test::@check(fixture.app.show_rig, "and leaves the rig where it was");

	fixture.tap(VIEWPORT_CENTER, Key.S);
	test::@check(!fixture.app.show_rig, "S puts the rig away as well");

	fixture.tap(VIEWPORT_CENTER, Key.B);
	fixture.tap(VIEWPORT_CENTER, Key.S);
	test::@check(fixture.app.show_mesh && fixture.app.show_rig, "and each key brings back its own half");

	// The menu item and the key are the same operation reached two ways, which is
	// only true while they are the same implementation.
	Vec2? view_title = fixture.center_of("View");
	if (catch view_title)
	{
		test::@check(false, "SKIPPED — the View title is not on the pane header");
		return;
	}
	fixture.click(view_title);
	Vec2? item = fixture.center_of("Skeleton");
	if (catch item)
	{
		test::@check(false, "SKIPPED — Skeleton is not in the View menu");
		return;
	}
	fixture.click(item);
	test::@check(!fixture.app.show_rig, "View > Skeleton hides it too");
	fixture.tap(VIEWPORT_CENTER, Key.S);

	// Straight down +Z, so a dot past the cube's far wall is occluded by
	// construction rather than by luck.
	fixture.app.camera.snap_to(crig::ViewAxis.POS_Z);
	for (uint i = 0; i < 1000 && fixture.app.camera.advance(DT); i++)
	{
	}

	fixture.app.place({ 0, 0, -1.5 });
	uint hidden = fixture.app.selected;
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	test::@check(
		drawn(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED) == 1,
		"a selected dot remains clear even behind the body"
	);

	fixture.tap(VIEWPORT_CENTER, Key.B);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(
		drawn(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED) == 1,
		"with the mesh gone the rig is still drawn"
	);
	test::@check(
		drawn(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED.dim(crig::OCCLUDED_DIM)) == 0,
		"and at full strength, because there is no skin left in front of it"
	);

	fixture.tap(VIEWPORT_CENTER, Key.B);
	fixture.tap(VIEWPORT_CENTER, Key.S);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(
		drawn(fixture, DrawingKind.ELLIPSE, crig::DOT_SELECTED) == 0
			&& drawn(fixture, DrawingKind.ELLIPSE, crig::DOT_ROOT) == 0,
		"hiding the rig takes the whole overlay, rings and all"
	);

	// The stats block is a child of the viewport, and the overlay leaves paint
	// early — a hidden rig must not take the corner block down with it, which is
	// also where the mode line says the rig was hidden on purpose.
	test::@check(
		drawn(fixture, DrawingKind.GLYPH, crig::ACCENT) > 0,
		"but leaves the stats block over it, saying so"
	);

	// One gesture for both halves of "hidden means gone": aimed straight at the
	// dot, so a rig that still answered the pick would select it, and one that
	// merely stopped painting would place a second dot on top of the first.
	Vec2? at = fixture.pixel_of(hidden);
	if (catch at)
	{
		test::@check(false, "SKIPPED — the hidden dot does not project on screen");
		fixture.tap(VIEWPORT_CENTER, Key.S);
		return;
	}

	fixture.app.select(0);
	sz before = fixture.doc().dots.len();
	fixture.click(at);
	test::@check(fixture.app.selected == 0, "a hidden dot cannot be picked");
	test::@check(fixture.doc().dots.len() == before, "and the click that missed it places nothing either");
	test::@check(fixture.notice_text().starts_with("the rig is hidden"), "but says why rather than going quiet");

	fixture.tap(VIEWPORT_CENTER, Key.S);
	test::@check(fixture.app.show_rig, "S brings it back");
}

<*
 The idle loop: what the tree does on a frame where nothing arrived.

 `Renderer.frame` sleeps in the kernel when a frame ends with nothing scheduled,
 which turns every animation in the program into a claim it has to make for
 itself — the loop cannot know that a countdown is halfway through, only that
 the last frame asked for another. So the failure this pins is not a crash or a
 wrong number: it is the weight debounce that never expires and the clip that
 stops mid-stride the moment the user takes their hand off the mouse, on a build
 that looks perfect to every other check in this file because they all feed
 frames unconditionally.

 Both directions matter. A tree that never settles is the bug in the other
 direction — it costs the user a busy core to show a picture that is not
 changing, which is the whole thing the loop mode buys.
*>
fn void the_idle_loop_settles_and_wakes() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the idle loop settles and wakes");
	fixture.reset();

	test::@check(fixture.settles(), "an interface with nothing running stops asking for frames");

	// The player is the timer with the most to lose: it advances by elapsed time
	// alone, so a loop that slept would freeze a clip mid-stride with nothing on
	// screen to say why. A fitted biped, because a clip only runs on a rig whose
	// joints it can name.
	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — no biped plan in this library");
		return;
	}
	fixture.ui.flush();
	if (!fixture.app.start_animation_at(0) || !fixture.app.animating)
	{
		test::@check(false, "SKIPPED — the first clip did not start");
		return;
	}
	fixture.ui.flush();

	// The result line the plan and the clip each left up is a timer of its own —
	// NOTICE_LIFE is eight seconds against the forty frames `settles` runs — and
	// it would answer every question below before the player got to. Cleared so
	// that what keeps the loop awake from here is the clip and nothing else.
	fixture.app.notice_length = 0;

	// The predicate first, then the frame. `AppRoot.update` also repaints the
	// viewport while a clip runs, and a repaint is a frame request too — so the
	// idle frame below would come back true on a build that had dropped the
	// player from `ticking` altogether, and the list is what this check is for.
	float was = fixture.app.anim_time;
	test::@check(fixture.app.ticking(), "a running clip is on the list of what is owed a frame");
	test::@check(fixture.idle_frame(), "and the frame after it is asked for");
	test::@check(fixture.app.anim_time > was, "and the clock advances on a frame with no input at all");

	// Paused is a still picture: nothing is owed a frame until an edit or a scrub
	// asks for one, or the fan spins redrawing (and re-casting occlusion rays
	// through) a body that is not moving.
	fixture.app.pause_clip();
	fixture.app.refresh_ui();
	fixture.ui.flush();
	test::@check(fixture.app.animating && fixture.app.anim_paused, "the clip did not pause");
	test::@check(fixture.settles(), "a paused clip kept the loop awake");
	fixture.app.resume_clip();

	fixture.app.stop_animation();
	fixture.app.refresh_ui();
	fixture.ui.flush();
	test::@check(fixture.settles(), "stopping it lets the loop sleep again");

	// Back to the bare cube for the debounce below, which places a dot of its own
	// and needs the click to land on the mesh rather than on a fitted joint.
	fixture.reset();
	fixture.click(VIEWPORT_CENTER);
	fixture.ensure_a_dot();

	// The debounce is the one that fails quietly: nothing is on screen counting
	// down, so a loop that slept through it would leave the view showing the rig
	// as it was before the last edit, indefinitely and with no error anywhere.
	fixture.toggle_weights(VIEWPORT_CENTER);
	if (fixture.app.tint_mode != TintMode.TERRITORY)
	{
		test::@check(false, "SKIPPED — the weight view did not open");
		return;
	}
	fixture.settle_weights();

	fixture.click(SPOT_A);
	test::@check(fixture.app.weights_stale, "an edit under the weight view owes a rebind");
	test::@check(fixture.idle_frame(), "which keeps asking for frames while it counts down");
	fixture.settle_weights();
	test::@check(!fixture.app.weights_stale, "until it fires");
	test::@check(fixture.settles(), "and then the loop can sleep again");

	// The camera is the one timer that is not in `AppState.ticking`: it schedules
	// its next frame through the repaint it already asks for, and this is what
	// says that second path is real.
	fixture.app.camera.snap_to(crig::ViewAxis.POS_X);
	test::@check(fixture.idle_frame(), "a camera snap in flight keeps the frames coming");
	for (uint i = 0; i < 1000 && fixture.app.camera.advance(DT); i++)
	{
	}
	test::@check(fixture.settles(), "and stops when it arrives");

	fixture.toggle_weights(VIEWPORT_CENTER);
}

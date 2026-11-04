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
// The lasso
//
// Three modes claim the plain drag over the model — the brush, the lasso, and
// the camera underneath both — and the ladder that resolves them is hand
// ordered in three places. What these cover is that slot: the key that opens the
// mode, the gesture that draws a region, the two modifiers latched at the press,
// and the four ways out.

<*
 Where a cube corner lands on screen, with the camera set head-on.
 
 Found by projecting a dot placed there and taking it away again — the dot and
 the vertex share a position, so they share a pixel, and removing it leaves the
 gesture clear of every dot. Head-on so that which corners are in sight is
 knowable: the front face is z = +1, and each back corner sits exactly behind a
 front one.
*>
fn Vec2? corner_pixel(Fixture* fixture, Vec3 at)
{
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	uint probe = fixture.doc().add_dot(at, "probe");
	fixture.app.refresh_ui();
	Vec2? found = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.refresh_ui();
	return found;
}

// A triangle around a pixel, wide enough that nothing else on this fixture's
// mesh projects inside it.
fn Vec2[3] triangle_around(Vec2 at)
{
	return { { at.x, at.y - 30 }, { at.x + 30, at.y + 25 }, { at.x - 30, at.y + 25 } };
}

<*
 A triangle around *both* pixels, and so around anything between them.

 What the single-pixel version cannot pose: a region catching a mix of joints,
 some already selected and some not. Every add-or-remove rule looks identical on
 a region over one joint — the difference between "add these" and "toggle these"
 only shows when the region straddles the boundary.

 The apex is centred between the two, so a pair sharing a screen x — which a rig
 built up the spine does — sits on the centre line rather than out at a corner.
*>
fn Vec2[3] triangle_over(Vec2 a, Vec2 b)
{
	float top = math::min(a.y, b.y) - 30;
	float bottom = math::max(a.y, b.y) + 25;
	float middle = (a.x + b.x) * 0.5f;
	float half = math::abs(a.x - b.x) * 0.5f + 40;
	return { { middle, top }, { middle + half, bottom }, { middle - half, bottom } };
}

// Draw a region, one frame per point, the way the loop delivers a drag.
fn void Fixture.lasso(&self, Vec2[3] shape, Key[] keys = {})
{
	self.feed(shape[0], keys: keys);
	self.feed(shape[0], left: true, keys: keys);
	self.feed(shape[1], left: true, keys: keys);
	self.feed(shape[2], left: true, keys: keys);
	self.feed(shape[2], keys: keys);
	self.feed(shape[2]);
}

// The two dots and the selection every lasso check starts from.
fn uint Fixture.two_dots(&self)
{
	uint hips = self.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = self.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	self.doc().connect(hips, chest);
	self.app.select(chest);
	self.app.refresh_ui();
	return chest;
}

<*
 One tool, two jobs, and the letter that walks between them.

 T is the lasso's key: closed it opens selecting, selecting it switches to
 pinning, pinning it switches back. shift+T is the shortcut to the far job — it
 lands on pinning from anywhere and only closes the tool when pinning is what was
 already running.

 Every step is checked against the *items* as well as the state, because the two
 jobs share a mode flag and nothing else: an item that lit for "the lasso is
 open" rather than for its own job would put a check mark on the wrong row, and a
 cell in the tool column would show the wrong glyph.
*>
fn void the_lasso_walks_its_two_jobs() @test
{
	io::printn("T walks the lasso between selecting and pinning, and shift+T goes straight to pinning");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	fixture.two_dots();

	// --- the shifted letter: straight to pinning, and out again ---------------
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(fixture.app.lassoing, "shift+T did not open the lasso");
	test::@check(fixture.app.lasso_job == crig::LassoJob.PIN, "shift+T opened the lasso on the wrong job");
	test::@check(crig::query_lasso(fixture.ui).checked, "the pinning item is not checked while pinning");
	test::@check(!crig::query_lasso_select(fixture.ui).checked, "the selecting item is checked while pinning");
	test::@check(crig::query_lasso_tool(fixture.ui).checked, "the tool cell is not lit while the lasso runs");
	test::@check(!crig::query_tweak(fixture.ui).checked, "the tweak cell is lit while a tool runs");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(!fixture.app.lassoing, "shift+T did not close the lasso");
	test::@check(!crig::query_lasso(fixture.ui).checked, "the item stayed checked after the mode closed");
	test::@check(crig::query_tweak(fixture.ui).checked, "the tweak cell is not lit with no tool running");

	// --- the plain letter: on, along, and back --------------------------------
	fixture.feed_key(Key.T);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.SELECT,
		"a plain T did not open the lasso on the selecting job");
	test::@check(crig::query_lasso_select(fixture.ui).checked, "the selecting item is not checked while selecting");
	test::@check(!crig::query_lasso(fixture.ui).checked, "the pinning item is checked while selecting");

	fixture.feed_key(Key.T);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.PIN,
		"a second T did not walk the tool on to pinning");

	fixture.feed_key(Key.T);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.SELECT,
		"a third T did not walk it back to selecting");

	// The shortcut reaches pinning from the other job without closing anything —
	// which is the whole difference between a shortcut and a toggle.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.PIN,
		"shift+T from the selecting job did not land on pinning");

	// Escape is the way out, one press, whichever job is running.
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.lassoing, "escape did not close the lasso");

	// And the brush closes it, which is the symmetry the three modes owe each
	// other: all of them claim the plain drag over the model.
	fixture.feed_key(Key.T);
	test::@check(fixture.app.lassoing, "the lasso did not reopen");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing && !fixture.app.lassoing,
		"opening the brush left the lasso open beside it");

	// With the brush open no cell in the column is lit: it lists neither the brush
	// nor reach, and a tweak cell that lit for "not my tools" would be claiming a
	// drag it has not got.
	test::@check(!crig::query_tweak(fixture.ui).checked, "the tweak cell is lit while the brush has the drag");
	test::@check(!crig::query_lasso_tool(fixture.ui).checked, "the lasso cell is lit while the brush has the drag");
}

<*
 The pinning job opens over an animated body — the region is gathered against
 the body on screen (`lasso_vertices`) — and is still refused with no joint to
 hand a region to, with the item greyed before the click.
*>
fn void the_lasso_pins_while_an_animation_is_shown() @test
{
	io::printn("the lasso pins over an animated body, and needs a joint");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	fixture.two_dots();

	AnimRef clip = fixture.app.new_clip("Lasso lock", 1.0f, from_rest: true);
	fixture.app.editing = clip;
	test::@check(fixture.app.park_clip(clip, 0.0f), "the lasso lock clip would not park");
	test::@check(fixture.app.rig_locked(), "a parked clip should lock the rest rig");

	test::@check(!crig::query_lasso(fixture.ui).disabled, "the item is greyed while an animation is shown");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.PIN,
		"the lasso would not pin over an animated body");
	fixture.app.end_lasso();

	// With nothing selected it is refused, since there is nothing to hand a
	// region to.
	fixture.app.select(0);
	fixture.app.refresh_ui();
	test::@check(crig::query_lasso(fixture.ui).disabled, "the item is not greyed with nothing selected");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(!fixture.app.lassoing, "the lasso opened with no dot to pin to");
	test::@check(fixture.app.notice().len > 0, "and said nothing about why");
	fixture.app.stop_animation();
}

<*
 A drawn region selects the joints inside it, and the modifiers say which way.

 The whole of the lasso's other job, driven through the press ladder rather than
 through `lasso_select_commit`: the modifiers are latched by the *press*, so a
 test that called the commit directly would be setting the latches by hand and
 proving nothing about which key sets which.

 Three readings, all of them here because they cannot be derived from each other
 — a plain region replaces, ctrl removes, alt adds — plus the two facts that keep
 the two jobs apart: selecting neither pins anything nor reaches the ledger.
*>
fn void a_drawn_region_selects_the_joints_inside_it() @test
{
	io::printn("the lasso's selecting job picks the joints it is drawn around");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	// Three joints up the middle, spread far enough that a region around one does
	// not reach its neighbours — which the first assertion below is what proves,
	// rather than something this arrangement is trusted for.
	uint hips = fixture.doc().add_dot({ 0, -0.6f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0, 0 }, "chest");
	uint head = fixture.doc().add_dot({ 0, 0.6f, 0 }, "head");
	fixture.app.select(0);
	fixture.app.refresh_ui();

	Vec2? at_head = fixture.pixel_of(head);
	Vec2? at_hips = fixture.pixel_of(hips);
	if (catch at_head) { test::@check(false, "the head does not project into the viewport"); return; }
	if (catch at_hips) { test::@check(false, "the hips do not project into the viewport"); return; }

	// The joint panel is anchored top-right and one of the regions below is drawn
	// out there over empty space; hide the card so the lasso reaches the viewport
	// rather than the panel now that the panel carries an align section and is
	// taller. This check is about the lasso, not the card.
	fixture.app.show_joint_panel = false;
	fixture.app.refresh_ui();

	// The plain letter, with nothing selected — which the pinning job refuses and
	// this one has no reason to.
	fixture.feed_key(Key.T);
	test::@check(fixture.app.lassoing && fixture.app.lasso_job == crig::LassoJob.SELECT,
		"a plain T did not open the lasso on its selecting job");

	sz ledger = fixture.app.undo_stack.cursor;

	fixture.lasso(triangle_around(at_head));
	test::@check(fixture.app.selected == head,
		"the region did not select the joint inside it");
	test::@check(fixture.app.selection_count() == 1,
		"the region caught %d joints where one was inside it — the polygon is not bounding it",
		fixture.app.selection_count());

	// Alt adds, which is what lets a selection be built out of several strokes.
	// Shift would have been the obvious key and is pan over the model.
	fixture.lasso(triangle_around(at_hips), keys: { Key.LEFT_ALT });
	test::@check(fixture.app.selection_count() == 2
		&& fixture.app.is_selected(head) && fixture.app.is_selected(hips),
		"an alt-region did not add its catch to the selection already there");

	// Ctrl takes its catch out and leaves the rest — and it must not toggle: the
	// joints it caught that were *not* selected have to stay that way.
	fixture.lasso(triangle_around(at_head), keys: { Key.LEFT_CTRL });
	test::@check(fixture.app.selection_count() == 1 && fixture.app.is_selected(hips),
		"a ctrl-region did not take out exactly what it caught");

	// And a plain one replaces rather than adding, the way a click does.
	fixture.lasso(triangle_around(at_head));
	test::@check(fixture.app.selection_count() == 1 && fixture.app.is_selected(head),
		"a plain region added to the selection instead of replacing it");

	// A region catching a *mix* — all three joints, one of them already selected.
	// This is the case the two directions cannot fake: `extend_selection` on its
	// own toggles, so an unguarded add would take the head straight back out while
	// putting the other two in, and every check above would still have passed.
	fixture.lasso(triangle_over(at_head, at_hips), keys: { Key.LEFT_ALT });
	test::@check(fixture.app.selection_count() == 3,
		"an alt-region over three joints, one of them already selected, left %d selected",
		fixture.app.selection_count());
	test::@check(fixture.app.is_selected(head) && fixture.app.is_selected(chest)
		&& fixture.app.is_selected(hips),
		"and it dropped one of the three it caught");

	// The same mix the other way: ctrl takes out the ones it caught and adds
	// nothing, so a region over everything from a selection of everything leaves
	// nothing at all.
	fixture.lasso(triangle_over(at_head, at_hips), keys: { Key.LEFT_CTRL });
	test::@check(fixture.app.selected == 0,
		"a ctrl-region over the whole selection left %d joints selected",
		fixture.app.selection_count());

	// A region drawn around nothing empties it. "Replace the selection with what I
	// circled" is what a plain region means, and nothing is what was circled.
	fixture.lasso(triangle_around(at_head));
	Vec2 empty = { at_head.x + VIEWPORT.x * 0.3f, at_head.y };
	fixture.lasso(triangle_around(empty));
	test::@check(fixture.app.selected == 0,
		"a region around no joints left %d selected", fixture.app.selection_count());

	// The two jobs do not leak into each other, and a selection is not an edit.
	test::@check(fixture.app.doc.pins.len() == 0, "the selecting job pinned something");
	test::eq(fixture.app.undo_stack.cursor, ledger);
}

<*
 The lasso pins under any transform tool. Opening it does not reset the tool
 column, and a Move tool left on used to turn the drag into an orbit before the
 lasso ever saw it.
*>
fn void the_lasso_pins_with_the_move_tool_left_on() @test
{
	io::printn("the lasso pins what it is drawn around with the Move tool still on");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	fixture.two_dots();
	Vec2? found = corner_pixel(&fixture, { -1, -1, 1 });
	if (catch found)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2[3] shape = triangle_around(found);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(fixture.app.lassoing, "the lasso did not open");
	fixture.app.transform_tool = MOVE_TOOL;

	fixture.feed(shape[0]);
	fixture.feed(shape[0], left: true);
	fixture.feed(shape[1], left: true);
	fixture.feed(shape[2], left: true);
	fixture.feed(shape[2]);
	fixture.feed(shape[2]);

	test::@check(fixture.app.doc.pins.len() > 0, "with the Move tool on, the lasso pinned nothing: %s",
		fixture.notice_text());
}

<*
 A drawn region pins what is inside it, in one Ctrl+Z, and the outline is on
 screen while it is being drawn.

 Unlike the brush, which commits per mouse move: a region is not finished until
 it is closed, so half a polygon has nothing to commit and the whole gesture is
 one entry.
*>
fn void a_drawn_region_pins_in_one_step() @test
{
	io::printn("a lasso pins what it is drawn around, as one undo step");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint chest = fixture.two_dots();

	Vec2? found = corner_pixel(&fixture, { -1, -1, 1 });
	if (catch found)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2[3] shape = triangle_around(found);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	test::@check(fixture.app.lassoing, "the lasso did not open");

	sz before = fixture.app.undo_stack.cursor;

	// Half a gesture first, so the outline can be looked at while it is in flight.
	fixture.feed(shape[0]);
	fixture.feed(shape[0], left: true);
	fixture.feed(shape[1], left: true);
	fixture.feed(shape[2], left: true);

	test::@check(fixture.app.lasso_active, "the press did not start a region");
	test::@check(drawn(&fixture, DrawingKind.LINE, crig::LASSO_PINNING) >= 2,
		"the viewport drew %d segments of a three-point region",
		drawn(&fixture, DrawingKind.LINE, crig::LASSO_PINNING));
	test::@check(fixture.app.doc.pins.len() == 0, "half a region already pinned something");

	fixture.feed(shape[2]);
	fixture.feed(shape[2]);

	usz pinned = pinned_vertices(&fixture);
	test::@check(pinned > 0, "the region pinned nothing at all");
	test::@check(pinned < fixture.app.geometry.positions.len,
		"the region pinned the whole mesh (%d of %d) — the polygon is not bounding it",
		pinned, fixture.app.geometry.positions.len);

	foreach (pin : fixture.app.doc.pins.array_view())
	{
		test::@check(pin.dot_id == chest, "a weight landed on a dot other than the selected one");
	}
	{
		bool[] edited = edited_mask(&fixture);
		defer alloc::free(mem, edited);
		foreach (v, on : edited)
		{
			if (on) test::@check(brush_weight_of(&fixture, (uint)v, chest) == 1.0f, "a lasso left vertex %d at %s rather than full", v,
				brush_weight_of(&fixture, (uint)v, chest));
		}
	}
	sz stored = fixture.app.doc.pins.len();

	// The outline goes with the gesture.
	test::@check(drawn(&fixture, DrawingKind.LINE, crig::LASSO_PINNING) == 0,
		"the region outlived its own release");

	test::@check(fixture.app.undo_stack.cursor > before, "the region left nothing on the ledger");
	test::@check(fixture.app.undo(), "the region is one step on the ledger");
	test::eq(fixture.app.doc.pins.len(), (sz)0);
	test::@check(fixture.app.undo_stack.cursor == before, "the region was more than one step on the ledger");

	test::@check(fixture.app.redo() && fixture.app.doc.pins.len() == stored, "and it redoes as one");
}

<*
 A region drawn around the whole silhouette takes the far side of the model too.

 The defect the gather's rule answers, through the gesture rather than under it: a
 leg lassoed from the front would otherwise keep its old bone on the back, with
 nothing on screen to say half the limb had been missed. `lasso_vertices` is
 asserted on its own arithmetic in test/weights_test.c3; this is the same claim
 through the press ladder and the commit, which is where a rule can be right and
 unreachable.
*>
fn void a_drawn_region_reaches_the_far_side_of_the_model() @test
{
	io::printn("a lasso around the silhouette pins the back of the model as well as the front");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	fixture.two_dots();

	// Backed off first: a region is drawn with the pointer and the pointer cannot
	// leave the window, so the whole cube has to fit inside a triangle that fits
	// inside the pane.
	fixture.app.camera.distance *= 3.0f;

	Vec2? found = corner_pixel(&fixture, { 1, 1, 1 });
	if (catch found)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}

	// A triangle around the whole silhouette, and clear of it on every side: the
	// cube projects into a square this far from the middle, and a corner sitting
	// exactly on an edge of the region is the crossing test's boundary case rather
	// than a claim about the gather.
	float half = math::max(
		math::abs(found.x - VIEWPORT_CENTER[0]), math::abs(found.y - VIEWPORT_CENTER[1]));
	Vec2[3] shape = {
		{ VIEWPORT_CENTER[0], VIEWPORT_CENTER[1] - 4.0f * half },
		{ VIEWPORT_CENTER[0] + 4.0f * half, VIEWPORT_CENTER[1] + 1.5f * half },
		{ VIEWPORT_CENTER[0] - 4.0f * half, VIEWPORT_CENTER[1] + 1.5f * half },
	};

	// Half the cube is genuinely behind the other half. Without that this asserts
	// nothing the front-faces rule would not have said as readily.
	Vec3 eye = fixture.app.camera.eye();
	usz unseen = 0;
	foreach (position : fixture.app.geometry.positions)
	{
		if (fixture.app.picker.hidden_surface(eye, position)) unseen++;
	}
	test::eq(unseen, (usz)4);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	fixture.lasso(shape);

	test::eq(fixture.app.doc.pins.len(), (sz)fixture.app.geometry.positions.len);
}

<*
 Ctrl-drag takes a region back off, and the outline says which way it is armed
 before the button goes down.
*>
fn void a_ctrl_drawn_region_unpins() @test
{
	io::printn("ctrl-drag with the lasso unpins the region it is drawn around");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	fixture.two_dots();

	Vec2? found = corner_pixel(&fixture, { -1, -1, 1 });
	if (catch found)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2[3] shape = triangle_around(found);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	fixture.lasso(shape);

	sz pinned = fixture.app.doc.pins.len();
	test::@check(pinned > 0, "the first region pinned nothing, so there is nothing to take back");
	bool[] region = edited_mask(&fixture);
	defer alloc::free(mem, region);
	uint chest = fixture.app.selected;

	Key[1] ctrl = { Key.LEFT_CTRL };
	fixture.feed(shape[0], keys: ctrl[..]);
	fixture.feed(shape[0], left: true, keys: ctrl[..]);
	fixture.feed(shape[1], left: true, keys: ctrl[..]);

	test::@check(fixture.app.lasso_removes, "the press did not latch the removing direction");
	test::@check(drawn(&fixture, DrawingKind.LINE, crig::LASSO_CLEARING) >= 1,
		"an unpinning region is drawn in the pinning colour");

	fixture.feed(shape[2], left: true, keys: ctrl[..]);
	fixture.feed(shape[2], keys: ctrl[..]);
	fixture.feed(shape[2]);

	foreach (v, on : region)
	{
		if (on) test::@check(brush_weight_of(&fixture, (uint)v, chest) == 0.0f, "the removal left the joint on vertex %d", v);
	}
	test::@check(fixture.app.undo() && fixture.app.doc.pins.len() == pinned,
		"undoing the removal did not bring the region back");
}

<*
 Escape mid-drag drops the region and keeps the mode; a scroll mid-drag does not
 move the camera.

 Both are about a gesture measured in *pixels*: a wheel that dollied halfway
 through would leave the half already drawn describing a different part of the
 model from the half still to come, and an outline that could not be abandoned
 would have to be committed wrong and undone.
*>
fn void a_region_can_be_abandoned_and_does_not_dolly() @test
{
	io::printn("escape drops a region in flight, and the wheel is swallowed while one is");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	fixture.two_dots();

	Vec2? found = corner_pixel(&fixture, { -1, -1, 1 });
	if (catch found)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2[3] shape = triangle_around(found);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.T);
	sz before = fixture.app.undo_stack.cursor;

	fixture.feed(shape[0]);
	fixture.feed(shape[0], left: true);
	fixture.feed(shape[1], left: true);

	// --- the wheel, mid-gesture ---------------------------------------------

	float distance = fixture.app.camera.distance;
	fixture.scroll(shape[1], { 0, 3 }, false, left: true);
	test::@check(fixture.app.camera.distance == distance,
		"a wheel notch mid-region moved the camera from %.6f to %.6f", distance, fixture.app.camera.distance);

	// --- escape, mid-gesture -------------------------------------------------

	Key[1] escape = { Key.ESCAPE };
	fixture.feed(shape[1], left: true, keys: escape[..]);
	fixture.feed(shape[1], left: true);

	test::@check(!fixture.app.lasso_active, "escape did not drop the region in flight");
	test::@check(fixture.app.lassoing, "escape closed the mode as well as the region");
	test::@check(drawn(&fixture, DrawingKind.LINE, crig::LASSO_PINNING) == 0,
		"the abandoned outline is still on screen");

	// The rest of the drag adds nothing back, and the release commits nothing.
	fixture.feed(shape[2], left: true);
	fixture.feed(shape[2]);
	fixture.feed(shape[2]);

	test::eq(fixture.app.doc.pins.len(), (sz)0);
	test::eq(fixture.app.undo_stack.cursor, before);
	test::@check(fixture.app.lassoing, "the mode did not survive the abandoned gesture");

	// And escape again leaves the mode, which is the layer below.
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.lassoing, "a second escape did not close the mode");
}

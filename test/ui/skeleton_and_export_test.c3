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
// B6 — the skeleton, the weight preview and the export button
// 
// The skeleton is the one conversion in crig: an undirected graph the user
// edited in whatever order they liked becomes an ordered tree where a parent is
// always a lower index than its children. Everything downstream — the prune's
// ancestor walk, the glTF node order, the direction `tails` points a bone —
// assumes that ordering and none of them check it.

<*
 The app is actually measuring through the mesh, and not quietly falling back.

 M3's binder falls back to straight lines for every reason it cannot proceed —
 no grid, a grid built from a different mesh, a bone that touches nothing — and
 every one of those failures produces a rig rather than an error. That is the
 right behaviour and it is also why this check has to exist: if the app's grid
 were empty or mismatched, nothing anywhere else would look wrong. Every other
 test in this file would still pass, and the milestone would be off.

 So the last check is the one that cannot be satisfied by a fallback: bind the
 same rig twice, once with the app's grid and once with none, and require the
 two to disagree. The cube is convex, so the two are close — a path through a
 box is nearly the straight line — which makes disagreeing the weaker claim and
 therefore the safer one to assert.
*>
fn void the_app_measures_through_the_mesh() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the app binds through the mesh rather than across it");
	fixture.reset();

	test::@check(fixture.app.voxels.usable(), "the mesh it opened has an inside to travel through");
	test::@check(
		fixture.app.voxels.anchors.len == fixture.app.geometry.positions.len,
		"and the grid is indexed by that same mesh's vertices"
	);

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — two dots expected");
		return;
	}

	rig::Skeleton? built = crig::build_skeleton(fixture.doc(), mem);
	if (catch built)
	{
		test::@check(false, "SKIPPED — no skeleton from two dots");
		return;
	}
	rig::Skeleton skeleton = built;
	defer skeleton.free(mem);

	Vec3[] positions = fixture.app.geometry.positions;
	float[] through = rig::bind_geodesic(mem, &fixture.app.voxels, positions, skeleton.joints, skeleton.parents);
	defer alloc::free(mem, through);

	float[] straight = rig::bind_geometric(mem, positions, skeleton.joints, skeleton.parents);
	defer alloc::free(mem, straight);

	bool differs = false;
	foreach (usz i, weight : through) if (weight != straight[i]) differs = true;
	test::@check(differs, "and the weights it produces are not the straight-line ones");
}

<*
 A chain walks out from the root in order, and moving the root turns it around.

 The second half is the part worth having. The root is the only thing that says
 which end of a chain is the hip and which is the ankle, so a `set_root` that
 did not reach the export would produce a rig that looks right on screen and
 bends backwards in Blender.
*>
fn void skeleton_walks_out_from_the_root() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the skeleton walks out from the root");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);
	if (fixture.doc().dots.len() != 3)
	{
		test::@check(false, "SKIPPED — three dots expected");
		return;
	}

	uint first = fixture.doc().dots[0].id;
	uint last  = fixture.doc().dots[2].id;

	rig::Skeleton? built = crig::build_skeleton(fixture.doc(), mem);
	if (catch built)
	{
		test::@check(false, "SKIPPED — no skeleton from three dots");
		return;
	}
	rig::Skeleton chain = built;
	defer chain.free(mem);

	test::@check(chain.joints.len == 3, "one joint per dot");
	test::@check(
		chain.parents.len == 3 && chain.parents[0] == -1 && chain.parents[1] == 0 && chain.parents[2] == 1,
		"each joint hangs from the one before it"
	);
	test::@check(chain.joints[0] == fixture.doc().find(first).position, "and joint 0 is the root dot");

	// Every consumer walks ancestors assuming a parent is a lower index.
	bool ordered = true;
	foreach (usz i, parent : chain.parents) if (parent >= (int)i) ordered = false;
	test::@check(ordered, "parents precede their children");

	Vec2? at = fixture.pixel_of(last);
	if (catch at)
	{
		test::@check(false, "SKIPPED — the last dot is off screen");
		return;
	}
	fixture.click(at);
	fixture.chord(at, Key.LEFT_CTRL, Key.R);

	rig::Skeleton? turned = crig::build_skeleton(fixture.doc(), mem);
	if (catch turned)
	{
		test::@check(false, "SKIPPED — no skeleton after moving the root");
		return;
	}
	rig::Skeleton reversed = turned;
	defer reversed.free(mem);

	test::@check(reversed.joints[0] == fixture.doc().find(last).position, "moving the root re-roots the skeleton");
	test::@check(reversed.joints[2] == fixture.doc().find(first).position, "and the chain now walks the other way");
}

<*
 A dot the root cannot reach is exported as another root, not dropped.

 Dropping it would be the tidy answer and the wrong one: it is work the user
 did, it is visible on screen, and a rig that silently loses joints between the
 viewport and the file is one nobody can trust.
*>
fn void stray_dots_become_extra_roots() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("stray dots become extra roots");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);

	fixture.tap(SPOT_B, Key.A); // chaining off, so the next dot bonds to nothing
	test::@check(!fixture.app.doc.auto_connect, "A turns chaining off");
	fixture.click(SPOT_C);

	if (fixture.doc().dots.len() != 3 || fixture.doc().edges.len() != 1)
	{
		test::@check(false, "SKIPPED — expected three dots and one bone");
		return;
	}

	rig::Skeleton? built = crig::build_skeleton(fixture.doc(), mem);
	if (catch built)
	{
		test::@check(false, "SKIPPED — no skeleton");
		return;
	}
	rig::Skeleton split = built;
	defer split.free(mem);

	test::@check(split.joints.len == 3, "the unreachable dot is still a joint");
	test::@check(split.parents[0] == -1 && split.parents[1] == 0, "the connected pair keeps its chain");
	test::@check(split.parents[2] == -1, "and the stray one is a root of its own");
}

<*
 The weight preview colours every vertex, after the debounce and not before.

 The timing is half the feature. Binding on the spot would run the whole
 vertex-by-bone pass on every mouse move of a drag, so the check that it does
 *not* fire on the edit itself is as load-bearing as the one that says it
 eventually does.
*>
fn void weight_preview_paints_every_vertex() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the weight preview paints every vertex");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);
	test::@check(fixture.app.tints.len == 0, "an edit alone binds nothing");

	fixture.toggle_weights(SPOT_C);
	test::@check(fixture.app.tint_mode == TintMode.TERRITORY, "the menu item turns the preview on");
	test::@check(fixture.hud_text().contains("3 joints · ") && fixture.hud_text().contains("weights"),
		"and the block does not name the view: \"%s\"", fixture.hud_text());

	// One frame is enough *because* switching the preview on clears the timer;
	// the debounce is there to swallow a stream of edits, and a keypress is not
	// one.
	fixture.feed(SPOT_C);
	test::@check(fixture.app.tints.len == cube().positions.len, "one colour per vertex");

	bool opaque = true;
	foreach (tint : fixture.app.tints) if ((tint >> 24) != 0xFF) opaque = false;
	test::@check(opaque, "and every one of them was actually written");

	// The point of the preview is seeing where one dot's territory ends, which
	// requires more than one colour to be on the model.
	test::@check(distinct_tints(fixture) >= 2, "different dots own different parts of the mesh");

	uint painted = fixture.app.tint_generation;

	// Undo the whole rig away. An empty document owns nothing, and the pass
	// reads an empty tint array as "stop tinting" — so the colours have to come
	// off the model rather than the last rig staying painted on it.
	fixture.chord(SPOT_C, Key.LEFT_CTRL, Key.Z);
	fixture.chord(SPOT_C, Key.LEFT_CTRL, Key.Z);
	fixture.chord(SPOT_C, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 0, "undo empties the document");

	// The last undo is three frames back and the debounce is ten, so nothing has
	// rebound yet. This is the half of the timing that stops a drag rebinding on
	// every mouse move, and the only way to see it is to look before it fires.
	test::@check(fixture.app.tint_generation == painted, "an edit waits out the debounce");

	fixture.settle_weights();
	test::@check(fixture.app.tint_generation != painted, "then rebinds, so the pass notices");
	test::@check(fixture.app.tints.len == 0, "and an empty rig takes the colours off");
}

<*
 File > Export writes a rigged .glb, from two clicks through the menu.

 What is new here is only the path from the item to the file — that the
 handler finds the AppState, that the export runs, and that the notice says
 where it went. The file's *contents* are `export-test`'s job, which re-opens a
 real export and checks every joint index and weight sum in it; all this
 asserts is the glTF magic, i.e. that a glb came out rather than a zero-length
 file.
*>
fn void export_button_writes_a_glb() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("File > Export writes a glb");
	fixture.reset();

	// Beside a mesh that does not exist, in the build directory — export only
	// reads the path to decide where its answer goes.
	fixture.app.point_at("build/ui_test_cube.glb");
	String written = "build/ui_test_cube_rigged.glb";
	(void)io::file::delete(written);

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);

	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);

	Vec2? export_item = fixture.center_of("Export .glb…");
	if (catch export_item)
	{
		test::@check(false, "SKIPPED — the Export item is not in the dropdown");
		return;
	}
	fixture.click(export_item);

	// The item raises the panel; the panel's own button is what writes. With
	// nothing ticked and Export rig on — which is how it opens — that is exactly
	// the rigged export the item used to perform by itself.
	test::@check(!io::file::is_file(written), "the menu item alone writes nothing");
	if (!fixture.confirm_export())
	{
		test::@check(false, "SKIPPED — the export panel has no Export button");
		return;
	}

	test::@check(io::file::is_file(written), "the panel writes the file beside the mesh");
	test::@check(fixture.notice_text().starts_with("wrote "), "and the notice says so");

	char[]? content = io::file::load(mem, written);
	if (catch content)
	{
		test::@check(false, "SKIPPED — the file could not be read back");
		return;
	}
	defer free(content);

	test::@check(content.len > 12 && ((String)content[:4]) == "glTF", "and what it wrote is a glb");
	(void)io::file::delete(written);

	// An empty document has no rig to export, and saying so beats writing a file
	// with no joints in it that fails to import.
	fixture.reset();
	fixture.app.point_at("build/ui_test_cube.glb");
	fixture.click(file_title);
	Vec2? again = fixture.center_of("Export .glb…");
	if (catch again)
	{
		test::@check(false, "SKIPPED — the Export item did not come back");
		return;
	}
	fixture.click(again);
	test::@check(fixture.confirm_export(), "the panel comes back up over an empty document");
	test::@check(!io::file::is_file(written), "an empty document writes nothing");
	test::@check(fixture.notice_text().starts_with("nothing to export"), "and says why");
}

<*
 A fork aims its bone at the child that continues it, not at whichever child
 BFS happened to reach first.

 Built as a skeleton literal rather than clicked into place, because the thing
 under test is geometric — a chest with two legs under it and a neck ahead of
 it — and steering synthetic clicks into that arrangement would be testing the
 picker's arithmetic instead of the tail rule.

 The joint order is the one BFS actually produces on a quadruped: the forelegs
 come before the neck, because both hang off the chest and the legs are reached
 first. That ordering is exactly what used to send the chest bone down a
 foreleg and leave the neck floating in Blender.
*>
fn void a_fork_aims_at_the_straightest_child() @test
{
	io::printn("a fork aims along the chain, not down the first leg");

	// 0 belly → 1 chest → { 2 foreleg L, 3 foreleg R, 4 neck }
	Vec3[5] joints = {
		{ 0.0, 0.4, -0.3 }, // belly: the chest is arrived at heading +Z
		{ 0.0, 0.4, 0.0 }, // chest, the fork
		{ -0.1, 0.1, 0.0 }, // foreleg, straight down
		{ 0.1, 0.1, 0.0 }, // foreleg, straight down
		{ 0.0, 0.5, 0.3 }, // neck, carrying on forward
	};
	int[5] parents = { -1, 0, 1, 1, 1 };

	// Borrows the stack arrays above, so no Skeleton.free — only `tails` was
	// allocated and only `tails` is freed.
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	Vec3[] tails           = skeleton.tails(mem);
	defer alloc::free(mem, tails);

	test::@check((tails[1] - joints[4]).length() < 1.0e-6f, "the chest bone reaches the neck");
	test::@check((tails[1] - joints[2]).length() > 1.0e-6f, "rather than the foreleg BFS saw first");
	test::@check((tails[0] - joints[1]).length() < 1.0e-6f, "a lone child is still the heir");
	test::@check((tails[2] - joints[2]).length() > 0.0f, "and a leaf still gets a direction to extrude");
}

<*
 A trackpad and a wheel send the same event down different paths: a swipe
 orbits, a wheel notch zooms, and ctrl turns a swipe into a zoom.

 Each of the three is checked to do its own thing *and* to leave the others
 alone, because the failure this is guarding against is not "nothing happened" —
 it is a swipe that orbits and quietly dollies as well, which a check that only
 read yaw would pass.

 The gesture goes through `process_input` rather than straight into
 `OrbitCamera`, so what is under test includes the two things that actually
 broke on the way here: that a horizontal-only swipe is dispatched at all, and
 that the viewport is what the scroll is hit-tested onto.
*>
fn void trackpad_and_wheel_scroll_differently() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a swipe orbits, a wheel notch zooms");

	Vec2 over = VIEWPORT_CENTER;

	// --- a bare swipe orbits on both axes and does not zoom ---
	fixture.reset();
	fixture.feed(over);
	float yaw      = fixture.app.camera.yaw;
	float pitch    = fixture.app.camera.pitch;
	float distance = fixture.app.camera.distance;

	fixture.scroll(over, { 40.0, 20.0 }, precise: true);
	test::@check(fixture.app.camera.yaw != yaw, "a swipe sideways turns the camera");
	test::@check(fixture.app.camera.pitch != pitch, "a swipe up or down tilts it");
	test::@check(fixture.app.camera.distance == distance, "and neither one zooms");

	// --- sideways alone still counts, which is the axis that did not exist ---
	fixture.reset();
	fixture.feed(over);
	yaw = fixture.app.camera.yaw;

	fixture.scroll(over, { 40.0, 0.0 }, precise: true);
	test::@check(fixture.app.camera.yaw != yaw, "a purely horizontal swipe is not dropped");

	// --- a wheel notch zooms, whatever the trackpad now does ---
	fixture.reset();
	fixture.feed(over);
	yaw = fixture.app.camera.yaw;
	distance = fixture.app.camera.distance;

	fixture.scroll(over, { 0.0, 1.0 }, precise: false);
	test::@check(fixture.app.camera.distance < distance, "a wheel notch moves in");
	test::@check(fixture.app.camera.yaw == yaw, "and leaves the orbit alone");

	// --- ctrl turns a swipe into that same zoom ---
	fixture.reset();
	Key[1] ctrl = { Key.LEFT_CTRL };
	fixture.feed(over, keys: ctrl[..]);
	yaw = fixture.app.camera.yaw;
	distance = fixture.app.camera.distance;

	fixture.scroll(over, { 0.0, 20.0 }, precise: true, keys: ctrl[..]);
	test::@check(fixture.app.camera.distance < distance, "ctrl and a swipe zooms in");
	test::@check(fixture.app.camera.yaw == yaw, "rather than orbiting");
}

<*
 Ctrl is the wheel's fine step: the same zoom, a fraction of a notch at a time.

 Compared against the plain notch rather than against a distance, because what
 has to hold is that one is a fraction of the other. A fine step checked against
 a number would be a check on `framed`'s starting distance as much as on the
 modifier, and would pass on a rig of a different size for the wrong reason.

 Both directions, because a modifier that scales a step must not also pin its
 sign — creeping in on a knuckle and creeping back off it are the same gesture.
*>
fn void ctrl_makes_the_wheel_zoom_finer() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("ctrl and the wheel zooms in smaller steps");

	Vec2 over = VIEWPORT_CENTER;
	Key[1] ctrl = { Key.LEFT_CTRL };

	// --- one plain notch, as the thing to measure against ---
	fixture.reset();
	fixture.feed(over);
	float start = fixture.app.camera.distance;

	fixture.scroll(over, { 0.0, 1.0 }, precise: false);
	float coarse = start - fixture.app.camera.distance;
	test::@check(coarse > 0.0f, "a bare notch forward did not move in");

	// --- the same notch with ctrl held ---
	fixture.reset();
	fixture.feed(over, keys: ctrl[..]);
	test::@check(fixture.app.camera.distance == start, "the two legs did not start from the same distance");

	fixture.scroll(over, { 0.0, 1.0 }, precise: false, keys: ctrl[..]);
	float fine = start - fixture.app.camera.distance;
	test::@check(fine > 0.0f, "ctrl and a notch forward stopped zooming altogether");
	test::@check(fine < coarse * 0.5f,
		"ctrl moved in %.4f against the plain notch's %.4f, which is not a finer step",
		fine, coarse);

	// --- and back out, at that same finer rate ---
	float from = fixture.app.camera.distance;
	fixture.scroll(over, { 0.0, -1.0 }, precise: false, keys: ctrl[..]);
	test::@check(fixture.app.camera.distance > from, "ctrl and a notch back did not move out");
	test::@check(math::abs(fixture.app.camera.distance - start) < start * 1.0e-4f,
		"a notch in and a notch back out left the camera at %.4f rather than the %.4f it started at",
		fixture.app.camera.distance, start);
}

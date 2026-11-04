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
// B5: semantics

<*
 Auto-connect turns placement into chain-building: each dot bonds to the one
 before it, which is the whole reason it defaults on.
*>
fn void auto_connect_chains() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("auto-connect chains placements");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);

	test::@check(fixture.doc().dots.len() == 3, "three clicks place three dots");
	test::@check(fixture.doc().edges.len() == 2, "and two bones, not three and not none");
	if (fixture.doc().dots.len() != 3) return;

	uint a = fixture.doc().dots[0].id;
	uint b = fixture.doc().dots[1].id;
	uint c = fixture.doc().dots[2].id;
	test::@check(fixture.doc()
		.has_edge(a, b) && fixture.doc().has_edge(b, c), "the bones follow the order they were placed in");
	test::@check(!fixture.doc().has_edge(a, c), "and skip no links");
	test::@check(fixture.doc().root_id == a, "the first dot is the root");
}

<*
 C bonds the selection into a chain, in the order the dots were picked, and a
 second C takes that chain back apart.

 The order is the whole point of the check: the dots are picked b, a, c — which
 is neither the order they were placed in nor any order their positions suggest
 — so a chain that came out a-b-c would mean something other than the picking
 decided it.
*>
fn void c_bonds_the_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("C bonds the selected dots into a chain");
	fixture.reset();

	// A turns auto-connect off through the same key path the user has, so the
	// dots below start with no bones at all.
	fixture.click(SPOT_B);
	fixture.tap(SPOT_B, Key.A);
	test::@check(!fixture.app.doc.auto_connect, "A toggles auto-connect off");

	fixture.click(SPOT_A);
	fixture.click(SPOT_C);
	test::@check(fixture.doc().edges.len() == 0, "with chaining off, placing bonds nothing");
	if (fixture.doc().dots.len() != 3)
	{
		test::@check(false, "SKIPPED — three dots expected");
		return;
	}

	uint b = fixture.doc().dots[0].id;
	uint a = fixture.doc().dots[1].id;
	uint c = fixture.doc().dots[2].id;

	Vec2? pa = fixture.pixel_of(a);
	Vec2? pb = fixture.pixel_of(b);
	Vec2? pc = fixture.pixel_of(c);
	if (catch pa)
	{
		test::@check(false, "SKIPPED — a dot is off screen");
		return;
	}
	if (catch pb)
	{
		test::@check(false, "SKIPPED — a dot is off screen");
		return;
	}
	if (catch pc)
	{
		test::@check(false, "SKIPPED — a dot is off screen");
		return;
	}

	fixture.click(pb);
	fixture.tap(pb, Key.C);
	test::@check(fixture.doc().edges.len() == 0, "C on a single dot bonds nothing");

	fixture.shift_click(pa);
	fixture.shift_click(pc);
	test::@check(fixture.app.selection_count() == 3, "shift-clicking gathers three dots");

	fixture.tap(pc, Key.C);
	test::@check(fixture.doc().edges.len() == 2, "C bonds them into two bones");
	test::@check(fixture.doc().dots.len() == 3, "and places nothing");
	test::@check(fixture.doc().has_edge(b, a) && fixture.doc().has_edge(a, c),
		"the chain follows the order the dots were picked");
	test::@check(!fixture.doc().has_edge(b, c), "and skips no links");

	fixture.tap(pc, Key.C);
	test::@check(fixture.doc().edges.len() == 0, "a second C takes the whole chain apart");

	fixture.tap(pc, Key.C);
	test::@check(fixture.doc().edges.len() == 2, "and a third builds it again");

	fixture.chord(pc, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().edges.len() == 0, "one undo takes the whole chain back");
}

<*
 R moves the root, and the move is undoable — export BFSes from it, so this
 decides which way every bone points.
*>
fn void root_follows_the_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("R sets the root");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — two dots expected");
		return;
	}

	uint first  = fixture.doc().dots[0].id;
	uint second = fixture.doc().dots[1].id;
	test::@check(fixture.doc().root_id == first, "the root starts on the first dot");

	Vec2? at = fixture.pixel_of(second);
	if (catch at)
	{
		test::@check(false, "SKIPPED — the dot is off screen");
		return;
	}

	fixture.click(at);
	fixture.chord(at, Key.LEFT_CTRL, Key.R);
	test::@check(fixture.doc().root_id == second, "ctrl+R hands the root to the selection");

	fixture.chord(at, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().root_id == first, "and undo hands it back");
}

<*
 A body plan can face the opposite way to the loaded model. The rotation dialog
 defaults to the useful glTF correction, Y by 180 degrees, and keeps the whole
 operation under one undo step without changing names or topology.
*>
fn void a_whole_skeleton_can_be_rotated_from_the_dialog() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a whole skeleton can be rotated from the dialog");
	fixture.reset();

	Vec3 pivot = fixture.app.geometry.bounds().center();
	float unit = fixture.app.picker.scale * 0.2f;
	uint root = fixture.app.add_recorded(pivot + (Vec3){ 0, 0.8f, 0 }, "hips");
	uint left = fixture.app.add_recorded(pivot + (Vec3){ unit, 0.5f, unit * 0.5f }, "hand_L");
	uint right = fixture.app.add_recorded(pivot + (Vec3){ -unit * 1.5f, 0.4f, -unit }, "hand_R");
	fixture.app.connect_recorded(root, left);
	fixture.app.connect_recorded(root, right);
	crig::JointRotationLimits limits = crig::unconstrained_rotation(left);
	limits.has_saved_frame = true;
	limits.saved_frame = quaternion::IDENTITY;
	test::@check(fixture.app.set_rotation_limits_recorded(left, limits),
		"could not prepare a saved joint frame");
	fixture.app.undo_stack.commit();

	Vec3 left_before = fixture.doc().find(left).position;
	Vec3 right_before = fixture.doc().find(right).position;
	crig::open_skeleton_rotation_dialog(fixture.ui);
	fixture.ui.flush();
	Dialog* dialog = fixture.ui.find_id(crig::SKELETON_ROTATION_DIALOG_ID)!!.widget_as(Dialog);
	Select* axis = fixture.ui.get_widget_id(crig::SKELETON_ROTATION_AXIS_ID, Select)!!;
	TextField* angle = fixture.ui.get_widget_id(crig::SKELETON_ROTATION_ANGLE_ID, TextField)!!;
	test::@check(dialog.open && axis.selected == 1 && angle.value() == "180",
		"the rotation dialog did not open on Y by 180 degrees");
	crig::apply_skeleton_rotation(fixture.ui);

	Dot* left_after = fixture.doc().find(left);
	Dot* right_after = fixture.doc().find(right);
	test::@check(left_after != null
		&& math::abs(left_after.position.x - (pivot.x - unit)) < 1.0e-5f
		&& math::abs(left_after.position.z - (pivot.z - unit * 0.5f)) < 1.0e-5f,
		"the left joint did not turn 180 degrees around Y");
	test::@check(right_after != null
		&& math::abs(right_after.position.x - (pivot.x + unit * 1.5f)) < 1.0e-5f
		&& math::abs(right_after.position.z - (pivot.z + unit)) < 1.0e-5f,
		"the right joint did not turn 180 degrees around Y");
	test::@check(left_after.name == "hand_L" && right_after.name == "hand_R",
		"rotating the skeleton changed its joint names");
	test::@check(fixture.doc().has_edge(root, left) && fixture.doc().has_edge(root, right),
		"rotating the skeleton changed its bones");
	Vec3 frame_x = fixture.doc().rotation_limits_of(left).saved_frame.rotate_vec3({ 1, 0, 0 });
	test::@check(math::abs(frame_x.x + 1.0f) < 1.0e-5f && math::abs(frame_x.z) < 1.0e-5f,
		"the saved joint frame did not turn with the skeleton");
	test::@check(fixture.notice_text().starts_with("rotated 2 joints 180° around Y axis"),
		"the result was not reported: \"%s\"", fixture.notice_text());

	fixture.app.undo();
	test::@check(fixture.doc().find(left).position == left_before
		&& fixture.doc().find(right).position == right_before,
		"one undo did not restore the whole skeleton");
	test::@check(fixture.doc().rotation_limits_of(left).saved_frame.v == limits.saved_frame.v,
		"one undo did not restore the saved joint frame");
}

<*
 M never builds a side that is not there: a chain placed down one half of the
 body, with no twins to mirror onto, is left untouched and the notice warns.

 Mirror moves an existing joint into line; it does not create one. A mirror that
 placed the missing side turned a mistyped or half-named rig into a litter of
 stray joints — a dot per finger a hand short — so a source with no twin is
 counted and warned about rather than answered with a new dot.
*>
fn void mirror_selection_never_places_a_missing_side() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror selection never places a missing side, it warns");
	fixture.reset();

	// Two dots down one side, chained by auto-connect — a rig with no other side.
	fixture.click(SPOT_LEFT);
	fixture.click(SPOT_A);
	if (fixture.doc().dots.len() != 2 || fixture.doc().edges.len() != 1)
	{
		test::@check(false, "SKIPPED — the chain to mirror did not build");
		return;
	}

	sz history = fixture.app.undo_stack.cursor;
	fixture.app.select_all();
	fixture.tap(SPOT_A, Key.M);

	// Mirror finds no twin for either dot and creates nothing — it warns instead.
	test::@check(fixture.doc().dots.len() == 2, "Mirror placed a joint where it should only warn (%d dots)", fixture.doc().dots.len());
	test::@check(fixture.doc().edges.len() == 1, "Mirror added an edge");
	test::@check(fixture.notice_text().starts_with("no twin to line up"),
		"the notice does not warn about the missing side: \"%s\"", fixture.notice_text());
	test::eq(fixture.app.undo_stack.cursor, history);
}

<*
 M mirrors under a parked clip too, and the body on screen is rebuilt for the
 rig it squared.

 The animation workspace keeps a clip parked between edits, so a mirror that
 refused there — it used to answer "finish animation editing first" — refused
 in the one place a rig is worked on. Squaring a crooked twin up moves a rest
 dot, which changes the bind the parked palette was built for, so what is
 asserted is not only that the dot moved but that the posed display took it:
 the clip came down, the skin was rebound, and undo puts both back.
*>
fn void mirror_selection_works_under_a_parked_clip() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror selection works under a parked clip");
	fixture.reset();

	// A named pair with the far side crooked, so M has an existing twin to pull
	// into line — Mirror never places one.
	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;
	uint hip = fixture.app.add_recorded({ plane, 0.9f, 0.0f }, "hip");
	uint good = fixture.app.add_recorded({ plane + unit, 0.5f, 0.0f }, "arm_L");
	uint crooked = fixture.app.add_recorded({ plane - unit * 1.6f, 0.42f, 0.05f }, "arm_R");
	fixture.app.connect_recorded(hip, good);
	fixture.app.connect_recorded(hip, crooked);
	fixture.app.undo_stack.commit();

	AnimRef clip = fixture.app.new_clip("Parked", 1.0f, from_rest: true);
	test::@check(clip.valid() && fixture.app.park_clip(clip, 0.0f), "the fixture could not park a clip");
	test::@check(fixture.app.rig_locked() && fixture.app.pose_palette.len == 3,
		"the parked clip did not put a three-joint palette up");
	uint skin_was = fixture.app.skin_generation;

	fixture.app.select(good);
	fixture.app.refresh_ui();
	test::@check(!crig::query_mirror_selection(fixture.ui).disabled,
		"the Edit menu greys Mirror selection while a clip is parked");
	fixture.tap(SPOT_A, Key.M);

	test::@check(fixture.doc().dots.len() == 3, "M under a parked clip placed a joint: \"%s\"", fixture.notice_text());
	test::@check(fixture.notice_text().starts_with("pulled 1 joint"), "the notice was \"%s\"", fixture.notice_text());
	test::@check(fixture.app.animating && fixture.app.anim_paused, "mirroring took the clip down");
	Dot* moved = fixture.doc().find(crooked);
	test::@check(moved != null && math::abs(moved.position.x - (plane - unit)) < 1e-5f,
		"arm_R was not squared up against arm_L under the parked clip (x=%.4f)", moved ? moved.position.x : 0.0f);
	test::@check(fixture.app.skin_generation > skin_was, "the skin was not rebound after the rig moved");
	test::@check(fixture.app.posed_surface_shown(), "the posed surface does not serve the rebuilt bind");

	fixture.chord(SPOT_A, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 3 && fixture.app.pose_palette.len == 3,
		"undo did not restore the crooked pair and its palette");
	Dot* back = fixture.doc().find(crooked);
	test::@check(back != null && math::abs(back.position.x - (plane - unit * 1.6f)) < 1e-5f
		&& math::abs(back.position.z - 0.05f) < 1e-5f,
		"undo did not put arm_R back where it was");
}

<*
 And on a rig that already has both halves, M pulls the far side into line
 rather than placing a second copy of it.

 The repair a hand-built rig needs, and the reason a twin is looked up by name:
 the partner here is a long way from where it belongs — further than any
 position match would reach — which is exactly the state that makes the arms of
 a rig bind to unequal amounts of the mesh.
*>
fn void mirror_selection_squares_up_a_crooked_pair() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror selection squares up a crooked pair");
	fixture.reset();

	// Placed outright rather than clicked, because the point of the check is a
	// pair that is named and badly out of line, and neither is something the
	// pointer can produce. Quoted in the picker's own scale, like the tolerance
	// they are being measured against.
	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;
	Vec3 kept = { plane + unit, 0.5f, 0.0f };
	Vec3 crooked = { plane - unit * 1.6f, 0.42f, 0.05f };

	uint left = fixture.app.add_recorded(kept, "elbow_L");
	uint right = fixture.app.add_recorded(crooked, "elbow_R");
	fixture.app.undo_stack.commit();

	test::@check(
		math::abs((kept.x - plane) + (crooked.x - plane)) > fixture.app.picker.scale * crig::MIRROR_EPSILON,
		"the pair really is crooked to begin with"
	);

	fixture.app.select(left);
	fixture.tap(SPOT_LEFT, Key.M);

	test::@check(fixture.doc().dots.len() == 2, "no second copy is placed");
	test::@check(fixture.notice_text().starts_with("pulled 1 joint"), "and the notice says what it did");

	Dot* moved = fixture.doc().find(right);
	if (!moved)
	{
		test::@check(false, "SKIPPED — the twin went missing");
		return;
	}
	test::@check(
		math::abs((kept.x - plane) + (moved.position.x - plane)) < 1e-5f
		&& math::abs(kept.y - moved.position.y) < 1e-5f
		&& math::abs(kept.z - moved.position.z) < 1e-5f,
		"the twin lands on the selection's reflection"
	);
	test::@check(
		(fixture.doc().find(left).position - kept).length() < 1e-5f,
		"and the side that was selected does not move"
	);

	fixture.chord(SPOT_LEFT, Key.LEFT_CTRL, Key.Z);
	test::@check(
		(fixture.doc().find(right).position - crooked).length() < 1e-5f,
		"one undo puts the twin back where it was"
	);
}

<*
 The context-menu Mirror builds the missing other side — the one thing the M-key
 mirror deliberately refuses to do.

 A named source with no twin becomes a twin at the reflection, carrying its name
 (mirrored), its reach and its bones: the source hangs off the hip, which is on
 the plane, so the built twin hangs off the same hip. One undo takes it all back.
*>
fn void mirror_create_builds_the_other_side() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create builds the other side");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;
	float reach = fixture.app.picker.scale * 0.15f;

	uint hip = fixture.app.add_recorded({ plane, 0.9f, 0.0f }, "hip");
	uint armR = fixture.app.add_recorded({ plane - unit, 0.5f, 0.1f }, "arm_R");
	fixture.app.connect_recorded(hip, armR);
	fixture.app.set_reach_recorded(armR, reach);
	fixture.app.undo_stack.commit();

	fixture.app.select(armR);
	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	usz total = fixture.app.mirror_create_selection(&made, &moved, &already, &skipped, &painted);

	test::eq(total, (usz)1);
	test::eq(made, (usz)1);
	test::eq(moved, (usz)0);
	test::@check(fixture.doc().dots.len() == 3, "the twin was not created (%d dots)", fixture.doc().dots.len());

	Dot* twin = fixture.app.dot_named("arm_L");
	if (!twin)
	{
		test::@check(false, "no arm_L was created");
		return;
	}
	uint twin_id = twin.id;
	test::@check(math::abs(twin.position.x - (plane + unit)) < 1e-4f
		&& math::abs(twin.position.y - 0.5f) < 1e-4f
		&& math::abs(twin.position.z - 0.1f) < 1e-4f,
		"arm_L landed at (%.3f,%.3f,%.3f), not the reflection", twin.position.x, twin.position.y, twin.position.z);
	test::@check(math::abs(twin.reach - reach) < 1e-4f, "arm_L did not take the reach (%.4f vs %.4f)", twin.reach, reach);

	bool wired = false;
	foreach (edge : fixture.doc().edges.array_view())
	{
		if ((edge.a == twin_id && edge.b == hip) || (edge.b == twin_id && edge.a == hip)) wired = true;
	}
	test::@check(wired, "arm_L was not bonded to the mirror of the source's bone (the hip)");

	test::@check(fixture.app.undo(), "undo did nothing");
	test::@check(fixture.doc().dots.len() == 2 && fixture.app.dot_named("arm_L") == null,
		"one undo did not take the whole mirror back");
}

<*
 And where the other side already exists, it is moved into line rather than
 duplicated — running Mirror twice does not litter a second twin.
*>
fn void mirror_create_moves_an_existing_twin() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create moves an existing twin");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;

	uint hip = fixture.app.add_recorded({ plane, 0.9f, 0.0f }, "hip");
	uint armR = fixture.app.add_recorded({ plane - unit, 0.5f, 0.1f }, "arm_R");
	// The twin exists but is out of line along X only, so the plane stays world X.
	uint armL = fixture.app.add_recorded({ plane + unit * 1.6f, 0.5f, 0.1f }, "arm_L");
	fixture.app.connect_recorded(hip, armR);
	fixture.app.connect_recorded(hip, armL);
	fixture.app.undo_stack.commit();

	fixture.app.select(armR);
	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	usz total = fixture.app.mirror_create_selection(&made, &moved, &already, &skipped, &painted);

	test::eq(total, (usz)1);
	test::eq(made, (usz)0);
	test::eq(moved, (usz)1);
	test::@check(fixture.doc().dots.len() == 3, "an existing twin was duplicated (%d dots)", fixture.doc().dots.len());

	Dot* twin = fixture.doc().find(armL);
	test::@check(twin != null && math::abs(twin.position.x - (plane + unit)) < 1e-4f
		&& math::abs(twin.position.z - 0.1f) < 1e-4f,
		"arm_L was not pulled into line (x=%.4f)", twin ? twin.position.x : 0.0f);
}

<*
 A joint with no side in its name is named by the side of the plane it falls on,
 and its twin gets the other side — one undo takes back the names and the twin.
 A joint on the centre line is still skipped.
*>
fn void mirror_create_names_a_joint_with_no_side() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create names a joint with no side");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;

	uint hip = fixture.app.add_recorded({ plane, 0.9f, 0.0f }, "hip");
	// Off the plane on -X, with no side in its name and nothing near its reflection.
	uint spine = fixture.app.add_recorded({ plane - unit, 0.3f, 0.0f }, "spine");
	// And one with no name at all, on +X.
	uint bare = fixture.app.add_recorded({ plane + unit, 0.5f, 0.0f });
	fixture.app.undo_stack.commit();

	fixture.app.select(spine);
	fixture.app.extend_selection(bare);
	fixture.app.extend_selection(hip);
	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	usz named;
	usz total = fixture.app.mirror_create_selection(&made, &moved, &already, &skipped, &painted, &named);

	test::eq(total, (usz)2);
	test::eq(made, (usz)2);
	test::eq(named, (usz)2);
	test::eq(skipped, (usz)1);
	test::@check(fixture.doc().dots.len() == 5, "expected two twins (%d dots)", fixture.doc().dots.len());

	// With no sided names to read, the left side is +X, as a fitted plan has it.
	Dot* spine_dot = fixture.doc().find(spine);
	test::@check(spine_dot != null && spine_dot.name == "spine_R", "spine on -X was not named spine_R");
	Dot* spine_twin = fixture.app.dot_named("spine_L");
	test::@check(spine_twin != null && math::abs(spine_twin.position.x - (plane + unit)) < 1e-4f,
		"spine_L was not built at the reflection");
	String bare_name = string::tformat("joint_%d_L", bare);
	String bare_twin = string::tformat("joint_%d_R", bare);
	test::@check(fixture.app.dot_named(bare_name) != null, "the unnamed joint was not named %s", bare_name);
	test::@check(fixture.app.dot_named(bare_twin) != null, "its twin %s was not built", bare_twin);
	Dot* hip_dot = fixture.doc().find(hip);
	test::@check(hip_dot != null && hip_dot.name == "hip", "the centre joint was renamed");

	test::@check(fixture.app.undo(), "undo did nothing");
	test::@check(fixture.doc().dots.len() == 3, "one undo did not take the twins back");
	spine_dot = fixture.doc().find(spine);
	test::@check(spine_dot != null && spine_dot.name == "spine", "one undo did not restore the name");
}

<*
 The side names follow the rig's own spelling: a rig whose right side is on +X
 and spelled `_r` names a new +X joint `_r`.
*>
fn void mirror_create_names_follow_the_rigs_convention() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create names follow the rig's convention");
	fixture.reset();
	fixture.app.doc.set_sym_x(0.0f);

	fixture.app.add_recorded({ 0.08f, 0.13f, 0.06f }, "hip_r");
	fixture.app.add_recorded({ -0.08f, 0.13f, 0.06f }, "hip_l");
	uint tail = fixture.app.add_recorded({ 0.2f, 0.3f, 0.05f }, "fin");
	fixture.app.undo_stack.commit();

	fixture.app.select(tail);
	usz made;
	usz named;
	(void)fixture.app.mirror_create_selection(&made, null, null, null, null, &named);
	test::eq(made, (usz)1);
	test::eq(named, (usz)1);
	test::@check(fixture.app.dot_named("fin_r") != null, "the +X joint was not named fin_r");
	Dot* twin = fixture.app.dot_named("fin_l");
	test::@check(twin != null && math::abs(twin.position.x + 0.2f) < 1e-3f, "fin_l was not built on -X");
}

<*
 The created twin lands on the plane the rig's *pairs* pin, not one an un-sided
 limb joint drags off the midline.

 The bug from the field: a rig symmetric about x=0 (its legs mirror exactly) but
 carrying a few limb joints named without a side — a finger called `ring_f`, an
 `elbow` with no `_r` — all sitting well off the midline. Read as centre joints
 those pull the plane off to +x, and every arm twin lands a bare fraction across
 instead of on the far side, bundled up against the original. Reading the plane
 off the existing square pairs instead puts it back on x=0.
*>
fn void mirror_create_reads_the_plane_off_the_pairs_not_stray_joints() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create reads the plane off the pairs, not stray joints");
	fixture.reset();
	fixture.app.doc.set_sym_x(0.0f);

	// A rig symmetric about x=0: two leg pairs that mirror exactly pin the plane.
	fixture.app.add_recorded({ 0.08f, 0.13f, 0.06f }, "hip_r");
	fixture.app.add_recorded({ -0.08f, 0.13f, 0.06f }, "hip_l");
	fixture.app.add_recorded({ 0.084f, 0.07f, 0.05f }, "knee_r");
	fixture.app.add_recorded({ -0.084f, 0.07f, 0.05f }, "knee_l");
	// A true centre joint, on the midline.
	fixture.app.add_recorded({ 0.0f, 0.25f, 0.07f }, "stomach");
	// The pollution: limb joints named without a side, far off the midline. A
	// centre-joint centroid folds these in and lands the plane near x=0.12.
	fixture.app.add_recorded({ 0.30f, 0.39f, 0.05f }, "ring_f");
	fixture.app.add_recorded({ 0.089f, 0.42f, 0.05f }, "elbow");
	// The joint to mirror: no twin yet, well out on +x.
	uint elbowR = fixture.app.add_recorded({ 0.18f, 0.40f, 0.05f }, "elbow_r");
	fixture.app.undo_stack.commit();

	fixture.app.select(elbowR);
	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	usz total = fixture.app.mirror_create_selection(&made, &moved, &already, &skipped, &painted);

	test::eq(total, (usz)1);
	test::eq(made, (usz)1);

	Dot* twin = fixture.app.dot_named("elbow_l");
	if (!twin)
	{
		test::@check(false, "no elbow_l was created");
		return;
	}
	// Reflected across x=0 (where the legs say the plane is), not across the ~0.12
	// the stray joints would drag it to — which would leave the twin near +0.06.
	test::@check(math::abs(twin.position.x - (-0.18f)) < 1e-3f,
		"elbow_l landed at x=%.4f, not the reflection across the pair plane at -0.18", twin.position.x);
	test::@check(twin.position.x < -0.1f, "elbow_l is still bundled on the +x side (x=%.4f)", twin.position.x);
}

<*
 The mirrored chain wires to its own twins and to shared midline joints — never
 back across the body to an original that has no twin.

 The field report after the plane fix: the twins landed right but each hung off
 the joints it was copied from, because a neighbour with no other side (an
 un-sided finger, a shoulder named without a side) fell back to itself and the
 new joint bonded to the original — a bone slung straight across the body.
*>
fn void mirror_create_does_not_wire_across_the_body() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create does not wire across the body");
	fixture.reset();
	fixture.app.doc.set_sym_x(0.0f);

	// Leg pairs pin the plane at x=0.
	fixture.app.add_recorded({ 0.08f, 0.13f, 0.06f }, "hip_r");
	fixture.app.add_recorded({ -0.08f, 0.13f, 0.06f }, "hip_l");
	// A centre joint on the midline, and the arm's shared root.
	uint chest = fixture.app.add_recorded({ 0.0f, 0.45f, 0.06f }, "chest");
	// An un-sided joint off the midline — the far end that has no twin.
	uint clav = fixture.app.add_recorded({ 0.04f, 0.44f, 0.06f }, "clav");
	// The right arm: shoulder rooted on the centre chest, then out through clav.
	uint shldrR = fixture.app.add_recorded({ 0.10f, 0.42f, 0.05f }, "shoulder_r");
	uint elbowR = fixture.app.add_recorded({ 0.18f, 0.40f, 0.05f }, "elbow_r");
	fixture.app.connect_recorded(chest, shldrR);   // to a centre joint
	fixture.app.connect_recorded(shldrR, clav);    // to an un-sided off-plane joint
	fixture.app.connect_recorded(shldrR, elbowR);  // to a joint being mirrored too
	fixture.app.undo_stack.commit();

	fixture.app.select(shldrR);
	fixture.app.extend_selection(elbowR);
	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	(void)fixture.app.mirror_create_selection(&made, &moved, &already, &skipped, &painted);
	test::eq(made, (usz)2);

	Dot* shldrL = fixture.app.dot_named("shoulder_l");
	Dot* elbowL = fixture.app.dot_named("elbow_l");
	if (!shldrL || !elbowL)
	{
		test::@check(false, "the twins were not created");
		return;
	}

	bool to_chest = false;   // shoulder_l -- chest (shared midline joint): wanted
	bool to_elbowL = false;  // shoulder_l -- elbow_l (its own twin): wanted
	bool to_clav = false;    // shoulder_l -- clav (un-sided original): a cross-body bone
	bool to_shldrR = false;  // any left joint -- shoulder_r (the original): cross-body
	foreach (edge : fixture.doc().edges.array_view())
	{
		uint a = edge.a;
		uint b = edge.b;
		if ((a == shldrL.id && b == chest) || (b == shldrL.id && a == chest)) to_chest = true;
		if ((a == shldrL.id && b == elbowL.id) || (b == shldrL.id && a == elbowL.id)) to_elbowL = true;
		if ((a == shldrL.id && b == clav) || (b == shldrL.id && a == clav)) to_clav = true;
		if ((a == shldrL.id || a == elbowL.id) && b == shldrR) to_shldrR = true;
		if ((b == shldrL.id || b == elbowL.id) && a == shldrR) to_shldrR = true;
	}

	test::@check(to_chest, "shoulder_l was not bonded to the shared centre joint");
	test::@check(to_elbowL, "shoulder_l was not bonded to its own twin elbow_l");
	test::@check(!to_clav, "shoulder_l was slung across the body to the un-sided clav");
	test::@check(!to_shldrR, "a mirrored joint was bonded back to the original shoulder_r");
}

<*
 A whole-hand selection mirrors every joint, naming by side the ones that name
 none.

 The field report: a hand where some finger joints carry `_r` and some carry no
 side at all (`ring_f`, `middle_f_tip`). Mirroring the lot builds a twin for every
 sided joint — none is lost to a neighbour claiming it — and the count of the
 un-sided ones comes back so the notice can say why they stayed put.
*>
fn void mirror_create_builds_every_named_side_and_counts_the_rest() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror create builds every named side and counts the rest");
	fixture.reset();
	fixture.app.doc.set_sym_x(0.0f);

	// Leg pairs pin the plane at x=0.
	fixture.app.add_recorded({ 0.08f, 0.13f, 0.06f }, "hip_r");
	fixture.app.add_recorded({ -0.08f, 0.13f, 0.06f }, "hip_l");

	// A hand and its fingers, out on +x. Some carry a side, some none — the exact
	// mix the report came from.
	uint[8] sided;
	sided[0] = fixture.app.add_recorded({ 0.27f, 0.40f, 0.05f }, "hand_r");
	sided[1] = fixture.app.add_recorded({ 0.28f, 0.39f, 0.09f }, "thumb_r");
	sided[2] = fixture.app.add_recorded({ 0.31f, 0.38f, 0.09f }, "thumb_r_tip");
	sided[3] = fixture.app.add_recorded({ 0.31f, 0.39f, 0.05f }, "middle_f_r");
	sided[4] = fixture.app.add_recorded({ 0.31f, 0.39f, 0.03f }, "pinky_r");
	sided[5] = fixture.app.add_recorded({ 0.34f, 0.39f, 0.03f }, "pinky_r_tip");
	sided[6] = fixture.app.add_recorded({ 0.18f, 0.40f, 0.05f }, "elbow_r");
	sided[7] = fixture.app.add_recorded({ 0.19f, 0.39f, 0.06f }, "wrist_r");

	uint[3] unsided;
	unsided[0] = fixture.app.add_recorded({ 0.30f, 0.39f, 0.07f }, "ring_f");
	unsided[1] = fixture.app.add_recorded({ 0.34f, 0.39f, 0.07f }, "ring_f_tip");
	unsided[2] = fixture.app.add_recorded({ 0.35f, 0.39f, 0.05f }, "middle_f_tip");
	fixture.app.undo_stack.commit();

	// Select the whole hand — sided and un-sided together.
	fixture.app.select(sided[0]);
	for (usz i = 1; i < sided.len; i++) fixture.app.extend_selection(sided[i]);
	foreach (u : unsided) fixture.app.extend_selection(u);

	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	(void)fixture.app.mirror_create_selection(&made, &moved, &already, &skipped, &painted);

	// Every sided joint gets its twin, and every un-sided one is named by side
	// (the rig spells right `_r` on +X) and mirrored too.
	test::eq(made, (usz)11);
	test::eq(skipped, (usz)0);
	test::@check(fixture.app.dot_named("ring_f_r") != null && fixture.app.dot_named("ring_f_l") != null,
		"ring_f was not named ring_f_r and mirrored to ring_f_l");

	String[8] twins = { "hand_l", "thumb_l", "thumb_l_tip", "middle_f_l", "pinky_l", "pinky_l_tip", "elbow_l", "wrist_l" };
	foreach (name : twins)
	{
		test::@check(fixture.app.dot_named(name) != null, "%s was not built", name);
	}
	test::@check(fixture.app.dot_named("middle_f_tip_l") != null, "middle_f_tip was not mirrored");
}

<*
 A right-press on a joint raises the context menu. (A press on empty space is
 declined so the pane's own split/merge menu still answers — see
 `context_menu_splits_and_merges`, which right-clicks empty pane space.)
*>
fn void a_right_press_on_a_joint_opens_the_context_menu() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a right press on a joint opens the context menu");
	fixture.reset();

	fixture.click(SPOT_A);
	if (fixture.doc().dots.len() != 1)
	{
		test::@check(false, "SKIPPED — the dot to right-click did not place");
		return;
	}
	Element* ctx = fixture.ui.find_id(crig::VIEWPORT_CONTEXT_ID)!!;
	test::@check(!ctx.widget_as(Dialog).open, "the context menu starts closed");

	fixture.right_click(SPOT_A);
	test::@check(ctx.widget_as(Dialog).open, "a right-press on a joint did not open the context menu");
}

<*
 The context menu's Mirror runs the *building* mirror — it makes the other side —
 and closes the menu behind it.
*>
fn void the_viewport_context_menu_mirrors_the_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the viewport context menu mirrors the selection");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;
	uint hip = fixture.app.add_recorded({ plane, 0.9f, 0.0f }, "hip");
	uint armR = fixture.app.add_recorded({ plane - unit, 0.5f, 0.1f }, "arm_R");
	fixture.app.connect_recorded(hip, armR);
	fixture.app.undo_stack.commit();
	fixture.app.select(armR);
	fixture.app.refresh_ui();

	// Opened as the right-press would, then the menu's own Mirror item is run.
	crig::open_viewport_context(fixture.ui, { 0, 0 });
	Element* ctx = fixture.ui.find_id(crig::VIEWPORT_CONTEXT_ID)!!;
	test::@check(ctx.widget_as(Dialog).open, "the context menu did not open");

	crig::viewport_context_mirror(fixture.ui);
	test::@check(!ctx.widget_as(Dialog).open, "the menu did not close after mirroring");
	test::@check(fixture.app.dot_named("arm_L") != null, "the menu's Mirror did not build the other side");
	test::@check(fixture.notice_text().starts_with("mirrored 1 joint"),
		"the notice did not report the mirror: \"%s\"", fixture.notice_text());
}

<*
 And the context menu's Delete takes the whole selection away in one undo step.
*>
fn void the_viewport_context_menu_deletes_the_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the viewport context menu deletes the selection");
	fixture.reset();

	fixture.click(SPOT_LEFT);
	fixture.click(SPOT_A);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the two dots to delete did not place");
		return;
	}
	fixture.app.select_all();
	fixture.app.refresh_ui();

	crig::viewport_context_delete(fixture.ui);
	test::@check(fixture.doc().dots.len() == 0, "the context Delete did not remove the selection (%d left)", fixture.doc().dots.len());
	test::@check(fixture.notice_text().starts_with("deleted 2 joint"),
		"the notice did not report the delete: \"%s\"", fixture.notice_text());

	test::@check(fixture.app.undo(), "undo did nothing");
	test::@check(fixture.doc().dots.len() == 2, "one undo did not bring the deleted joints back");
}

<*
 And it squares up a pair the *file* named, not one crig did.

 The case this was reported from, and it is the ordinary one rather than the
 exotic one: a rig is named after whichever body plan it matched, a plan's words
 are its pack file's own joint names, and a pack a user downloads is as likely
 as not a downloaded export. So an imported figure wears `armature:LeftHandThumb1`
 on every joint it has, and while the twin was looked up by `_L`/`_R` alone that
 name said nothing — Mirror placed a whole second hand on top of the hand that
 was already there, one spare dot per finger joint, and left the crooked side
 crooked.

 Fingers because that is where it was seen and where it hurts: a hand is a dozen
 dots a few millimetres apart, so the spares are invisible until something binds
 to them.
*>
fn void mirror_reads_the_side_out_of_an_imported_name() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("mirror reads the side out of an imported name");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;
	Vec3 kept = { plane + unit, 0.5f, 0.0f };
	Vec3 crooked = { plane - unit * 1.6f, 0.42f, 0.05f };

	uint left = fixture.app.add_recorded(kept, "armature:LeftHandThumb1");
	uint right = fixture.app.add_recorded(crooked, "armature:RightHandThumb1");
	fixture.app.undo_stack.commit();

	fixture.app.select(left);
	fixture.tap(SPOT_LEFT, Key.M);

	test::@check(fixture.doc().dots.len() == 2, "no spare joint is placed beside the one that answers");
	test::@check(fixture.notice_text().starts_with("pulled 1 joint"), "and the notice says it squared one up");

	Dot* moved = fixture.doc().find(right);
	if (!moved)
	{
		test::@check(false, "SKIPPED — the twin went missing");
		return;
	}
	test::@check(
		math::abs((kept.x - plane) + (moved.position.x - plane)) < 1e-5f
		&& math::abs(kept.y - moved.position.y) < 1e-5f
		&& math::abs(kept.z - moved.position.z) < 1e-5f,
		"the joint the file already named is the one that moves"
	);
}

<*
 A dot whose name names no side is still paired by where it sits.

 The other half of the same repair, and the one that catches a convention nobody
 has thought of yet: `mirror_name` reads the spellings it knows, and a name it
 cannot read has to fall through to position rather than take the rig's silence
 for an answer. Before, only a dot with no name at all did — so a joint called
 `bone_12` got a second `bone_12` on top of it while an unnamed one was pulled
 into line, which is the same rig treated two ways.
*>
fn void a_name_with_no_side_in_it_still_pairs_by_position() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a name with no side in it still pairs by position");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;

	// Square enough that a position match reaches it, which is the whole of what
	// this path can promise: a nameless pair further apart than the tolerance is
	// two dots, and the doc comment on `mirror_selection` says so.
	Vec3 kept = { plane + unit, 0.5f, 0.0f };
	Vec3 nearly = { plane - unit, 0.5f + fixture.app.picker.scale * 0.005f, 0.0f };

	uint left = fixture.app.add_recorded(kept, "bone_11");
	uint right = fixture.app.add_recorded(nearly, "bone_12");
	fixture.app.undo_stack.commit();

	fixture.app.select(left);
	fixture.tap(SPOT_LEFT, Key.M);

	test::@check(fixture.doc().dots.len() == 2, "the dot across the plane is taken for the twin");

	Dot* moved = fixture.doc().find(right);
	if (!moved)
	{
		test::@check(false, "SKIPPED — the twin went missing");
		return;
	}
	test::@check(
		math::abs((kept.x - plane) + (moved.position.x - plane)) < 1e-5f
		&& math::abs(kept.y - moved.position.y) < 1e-5f,
		"and pulled onto the reflection"
	);
}

<*
 The mirror says when paint went across, since nothing on screen shows it
 unless the falloff view happens to be on the twin.
*>
fn void the_mirror_notice_says_when_paint_crossed() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the mirror notice says when weight paint crossed");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;
	// Both sides placed, square about the plane — the paint crosses onto the twin
	// that is there, it is never made.
	uint left = fixture.app.add_recorded({ plane - unit, 0.5f, 0.0f }, "arm_L");
	uint right = fixture.app.add_recorded({ plane + unit, 0.5f, 0.0f }, "arm_R");
	fixture.app.undo_stack.commit();
	uint[1] dab = { 0 };
	test::eq(fixture.app.set_weight_vertices(dab[..], left, 0.4f), (usz)1);

	fixture.app.select(left);
	fixture.tap(SPOT_LEFT, Key.M);
	test::@check(fixture.doc().dots.len() == 2, "the arm did not mirror: \"%s\"", fixture.notice_text());
	test::@check(fixture.notice_text().ends_with("weight paint crossed too"),
		"the notice does not mention the paint: \"%s\"", fixture.notice_text());
	test::@check(fixture.app.weights_held(right), "the edited weights did not cross");

	// Nothing painted on the source: the plain wording — the pair is now square
	// with no paint, so the mirror finds nothing to do.
	fixture.chord(SPOT_LEFT, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.app.release_all_recorded() > 0, "the edited weights would not let go");
	fixture.app.select(left);
	fixture.tap(SPOT_LEFT, Key.M);
	test::@check(fixture.doc().dots.len() == 2 && !fixture.notice_text().contains("paint"),
		"an unpainted mirror mentioned paint: \"%s\"", fixture.notice_text());
}

<*
 A reach crosses the symmetry plane with its dot, onto an existing twin — one
 that had to move and one that was already square.

 A rig reined in down one side and mirrored has to be symmetric in what it binds
 and not only in where it sits — an arm limited to 0.2 whose partner reaches
 forever is as lopsided as an arm 20% longer, and the falloff view is the only
 place it shows.

 The already-square leg is the one that gets left out. Position is the whole of
 what mirroring used to carry, so a twin standing exactly where it belongs was
 skipped before anything else could be read off its source — and a pair squared
 up earlier is precisely the pair someone then tunes one side of.
*>
fn void a_mirrored_dot_takes_the_reach_with_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a reach crosses the symmetry plane with the dot it belongs to");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;

	uint lone = fixture.app.add_recorded({ plane + unit, 0.5f, 0.0f }, "elbow_L");
	fixture.app.undo_stack.commit();
	fixture.app.set_reach_recorded(lone, 0.31f);
	fixture.app.undo_stack.commit();

	// --- onto a twin that has to move into line -----------------------------

	uint drifted = fixture.app.add_recorded({ plane - unit * 1.4f, 0.55f, 0.04f }, "elbow_R");
	fixture.app.undo_stack.commit();
	test::@check(fixture.doc().find(drifted).reach == 0.0f, "the twin starts unlimited");

	fixture.app.select(lone);
	fixture.tap(SPOT_LEFT, Key.M);

	Dot* pulled = fixture.doc().find(drifted);
	test::@check(pulled != null && math::abs(pulled.reach - 0.31f) < 1.0e-6f,
		"the twin pulled into line reaches %.4f where its source reaches 0.3100", pulled ? pulled.reach : -1.0f);
	test::@check(pulled != null && math::abs(pulled.position.x - (plane - unit)) < 1.0e-5f,
		"and it was pulled onto the reflection");
	test::@check(fixture.doc().dots.len() == 2, "no second copy was placed to carry it");

	// --- and onto a twin that is now already exactly where it belongs -------
	// The twin sits on the reflection after the move above; clear its reach and
	// mirror again — nothing moves, but the reach still crosses.

	fixture.app.set_reach_recorded(drifted, 0.0f);
	fixture.app.undo_stack.commit();

	fixture.app.select(lone);
	fixture.tap(SPOT_LEFT, Key.M);

	Dot* partner = fixture.doc().find(drifted);
	test::@check(partner != null && math::abs(partner.reach - 0.31f) < 1.0e-6f,
		"a twin needing no move still took the reach — it reaches %.4f",
		partner ? partner.reach : -1.0f);
	test::@check(fixture.doc().dots.len() == 2, "and no second copy was placed to carry it");

	fixture.chord(SPOT_LEFT, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().find(drifted).reach == 0.0f,
		"one undo puts the twin's own reach back");
}

<*
 A joint's rotation limits cross the symmetry plane with it, reflected — not
 copied. A hip reined in to flex forward, twist a little out and abduct gets a
 twin that flexes forward the same way and twists and abducts the other way
 round; the numbers a copy would have written put the other leg's twist and
 abduction inward. The signs are the core's business (`joint_limits_test`
 checks them against the turns themselves); what the interface owes is that M
 carries the table at all, in the same undo step as the dot, and clears it on
 the reach's terms when the source has none.
*>
fn void a_mirrored_joint_takes_its_rotation_limits_reflected() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a mirrored joint takes its rotation limits reflected");
	fixture.reset();

	float plane = fixture.app.doc.sym_x;
	float unit = fixture.app.picker.scale * 0.2f;

	// A pelvis on the plane with a leg hanging off each side — both already
	// placed, since Mirror carries the table onto the far hip, it never makes it.
	// The knee is what gives a hip a bone, and so an X to read the table against.
	uint pelvis = fixture.app.add_recorded({ plane, 0.9f, 0.0f }, "pelvis");
	uint hip = fixture.app.add_recorded({ plane + unit, 0.85f, 0.0f }, "hip_L");
	uint knee = fixture.app.add_recorded({ plane + unit, 0.45f, 0.0f }, "knee_L");
	uint hip_r = fixture.app.add_recorded({ plane - unit, 0.85f, 0.0f }, "hip_R");
	uint knee_r = fixture.app.add_recorded({ plane - unit, 0.45f, 0.0f }, "knee_R");
	fixture.app.connect_recorded(pelvis, hip);
	fixture.app.connect_recorded(hip, knee);
	fixture.app.connect_recorded(pelvis, hip_r);
	fixture.app.connect_recorded(hip_r, knee_r);
	fixture.app.undo_stack.commit();

	crig::JointRotationLimits limits = crig::unconstrained_rotation(hip);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -0.5f, .maximum = 1.6f, .locked = 0.0f };
	limits.axes[1] = { .allowed = false, .minimum = -1.0f, .maximum = 1.0f, .locked = 0.2f };
	limits.axes[2] = { .allowed = true, .minimum = -0.2f, .maximum = 0.8f, .locked = 0.0f };
	test::@check(fixture.app.set_rotation_limits_recorded(hip, limits), "the hip's table was refused");
	fixture.app.undo_stack.commit();

	fixture.app.select(hip);
	fixture.app.extend_selection(knee);
	fixture.tap(SPOT_LEFT, Key.M);

	crig::Dot* twin = fixture.app.dot_named("hip_R");
	if (!twin || fixture.doc().dots.len() != 5)
	{
		test::@check(false, "SKIPPED — the other hip went missing (%d dots)", fixture.doc().dots.len());
		return;
	}
	crig::JointRotationLimits carried = fixture.doc().rotation_limits_of(twin.id);
	test::@check(carried.constrained, "the other hip took no limits");
	test::@check(math::abs(carried.axes[0].minimum + 0.5f) < 1.0e-5f && math::abs(carried.axes[0].maximum - 1.6f) < 1.0e-5f,
		"flexion reads [%.2f, %.2f] on the other hip, wanted [-0.50, 1.60]", carried.axes[0].minimum, carried.axes[0].maximum);
	test::@check(!carried.axes[1].allowed && math::abs(carried.axes[1].locked + 0.2f) < 1.0e-5f,
		"the twist lock reads %.2f on the other hip, wanted -0.20", carried.axes[1].locked);
	test::@check(math::abs(carried.axes[2].minimum + 0.8f) < 1.0e-5f && math::abs(carried.axes[2].maximum - 0.2f) < 1.0e-5f,
		"abduction reads [%.2f, %.2f] on the other hip, wanted [-0.80, 0.20]", carried.axes[2].minimum, carried.axes[2].maximum);
	test::@check(!carried.has_saved_frame, "the other hip was pinned to a frame when its own bone carries the axes");

	fixture.chord(SPOT_LEFT, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 5 && fixture.doc().rotation_limits.len() == 1,
		"one undo takes back the reflected table, leaving only the source's (%d dots, %d tables)",
		fixture.doc().dots.len(), fixture.doc().rotation_limits.len());

	// --- and a source with no table clears its twin's, like a reach of zero ---
	fixture.app.redo();
	twin = fixture.app.dot_named("hip_R");
	if (!twin)
	{
		test::@check(false, "SKIPPED — redo did not bring the other hip back");
		return;
	}
	uint other = twin.id;
	test::@check(fixture.app.set_rotation_limits_recorded(hip, crig::unconstrained_rotation(hip)), "the hip's table would not clear");
	fixture.app.undo_stack.commit();
	test::@check(fixture.doc().rotation_limits_of(other).constrained, "the other hip lost its table before anything mirrored it");

	fixture.app.select(hip);
	fixture.tap(SPOT_LEFT, Key.M);
	test::@check(!fixture.doc().rotation_limits_of(other).constrained,
		"the other hip kept a table its source no longer has");
	test::@check(fixture.notice_text().starts_with("pulled 1 joint"),
		"clearing a table counts as pulling the twin into line — the notice says \"%s\"", fixture.notice_text());
	test::@check(fixture.doc().dots.len() == 5, "and no second copy was placed to carry it");

	fixture.chord(SPOT_LEFT, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().rotation_limits_of(other).constrained, "one undo puts the other hip's own table back");
}

<*
 The plain history: undo unwinds in order, redo rebuilds, and a redone dot keeps
 the id it had — every edit recorded after it still names that id.
*>
fn void undo_and_redo() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("undo and redo");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — two dots expected");
		return;
	}

	uint first           = fixture.doc().dots[0].id;
	uint second          = fixture.doc().dots[1].id;
	Vec3 second_position = fixture.doc().dots[1].position;

	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc()
		.dots.len() == 1 && fixture.doc().edges.len() == 0, "one undo takes back the dot and its bone together");

	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 0, "the next takes back the first dot");
	test::@check(fixture.doc().root_id == 0, "and the document has no root left to point at");
	test::@check(fixture.hud_text().contains("0 joints · 0 bones"),
		"the block does not follow undo: \"%s\"", fixture.hud_text());

	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.Y);
	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.Y);
	test::@check(fixture.doc().dots.len() == 2 && fixture.doc().edges.len() == 1, "redo rebuilds both placements");
	test::@check(fixture.doc().dots[0].id == first && fixture.doc().dots[1].id == second, "with the ids they had");
	test::@check((fixture.doc().dots[1].position - second_position).length() < 1e-6f, "and the positions they had");
	test::@check(fixture.doc().root_id == first, "and the root back on the first dot");
}

<*
 Deleting a dot takes its bones with it, so undoing has to put all of them back
 — and in an order where the dot exists before anything is hung off it.
*>
fn void undo_restores_bones_with_the_dot() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("undo restores bones with the dot");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);
	if (fixture.doc().dots.len() != 3)
	{
		test::@check(false, "SKIPPED — three dots expected");
		return;
	}

	uint middle = fixture.doc().dots[1].id;
	Vec2? at    = fixture.pixel_of(middle);
	if (catch at)
	{
		test::@check(false, "SKIPPED — the dot is off screen");
		return;
	}

	fixture.click(at);
	fixture.tap(at, Key.X);
	test::@check(fixture.doc().dots.len() == 2, "deleting the middle dot leaves two");
	test::@check(fixture.doc().edges.len() == 0, "and takes both of its bones with it");

	fixture.chord(at, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 3, "undo puts the dot back");
	test::@check(fixture.doc().edges.len() == 2, "and both bones with it");
	test::@check(fixture.doc().find(middle) != null, "under the id it had");
}

<*
 Editing after an undo forks the timeline, and the branch not taken cannot be
 re-entered.
*>
fn void new_edit_discards_the_redo_tail() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a new edit discards the redo tail");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.chord(SPOT_B, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.app.undo_stack.can_redo(), "the undone placement is redoable");

	fixture.click(SPOT_C);
	test::@check(!fixture.app.undo_stack.can_redo(), "placing something else drops it");

	sz count = fixture.doc().dots.len();
	fixture.chord(SPOT_C, Key.LEFT_CTRL, Key.Y);
	test::@check(fixture.doc().dots.len() == count, "and redo then does nothing");
}

<*
 The Edit menu's Undo and Ctrl+Z are the same operation, reached two ways —
 what the panel's buttons used to assert, driven through a dropdown that only
 exists while it is open.
*>
fn void menu_undo_matches_the_keyboard() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Edit menu's undo matches the keyboard");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);

	Vec2? edit_title = fixture.center_of("Edit");
	if (catch edit_title)
	{
		test::@check(false, "SKIPPED — the Edit title is not on the bar");
		return;
	}

	fixture.click(edit_title);
	Vec2? undo_item = fixture.center_of("Undo");
	if (catch undo_item)
	{
		test::@check(false, "SKIPPED — the Undo item is not in the dropdown");
		return;
	}

	fixture.click(undo_item);
	test::@check(fixture.doc().dots.len() == 1, "Edit > Undo takes back the last placement");
	test::@check(fixture.hud_text().contains("1 joint · "),
		"and the block does not follow the menu's undo: \"%s\"", fixture.hud_text());
	test::@check(!fixture.in_tree("Undo"), "and choosing an item closes the menu");

	fixture.click(edit_title);
	Vec2? redo_item = fixture.center_of("Redo");
	if (catch redo_item)
	{
		test::@check(false, "SKIPPED — the Redo item is not in the dropdown");
		return;
	}

	fixture.click(redo_item);
	test::@check(fixture.doc().dots.len() == 2, "and Edit > Redo puts it back");

	// File > Quit raises the flag main's loop reads; nothing else observes it.
	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);
	Vec2? quit_item = fixture.center_of("Quit");
	if (catch quit_item)
	{
		test::@check(false, "SKIPPED — the Quit item is not in the dropdown");
		return;
	}
	fixture.click(quit_item);
	test::@check(fixture.app.quit_requested, "File > Quit raises the quit flag");
	fixture.app.quit_requested = false;
}

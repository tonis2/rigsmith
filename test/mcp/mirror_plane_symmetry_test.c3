module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// mirror plane (symmetry)
//
// The mirror reflects across the skeleton's own midline, read off its named
// joints, rather than trusting the mesh's bounding-box centre — which is not the
// body's midline when the mesh is asymmetric (a tail, an off-centre export).

<*
 The plane is read off the rig's centre joint and named pair, not the mesh.
*>
fn void symmetry_plane_reads_the_rig_not_the_mesh() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "an empty mesh's plane starts at x=0");

	// A skeleton centred at x = 2, nowhere near the empty mesh's x = 0.
	app.doc.add_dot({ 2.0f, 1.0f, 0 }, "spine");   // centre joint, on the plane
	app.doc.add_dot({ 1.7f, 0.5f, 0 }, "arm_l");   // a pair straddling it
	app.doc.add_dot({ 2.3f, 0.5f, 0 }, "arm_r");

	float plane;
	test::@check(app.symmetry_plane(&plane), "a plane should read off the named joints");
	test::@check(math::abs(plane - 2.0f) < 1e-4f, "the plane is the rig's centre x=2, got %.4f", plane);
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "reading the plane does not change the stored one");
}

<*
 A tail curling to one side is side-less joints off the midline. They must not
 drag the plane after them: averaged in, four tail joints moved it 4 cm on a
 1 m figure and M put a pinky's twin inside the palm. The plane is the median of
 the centre joints and the pairs, so the twin lands at the exact reflection.

 *Re-introduce:* take `MirrorSurvey.centre_point` (the mean) for the plane and
 pinky_r lands near -0.33 rather than at -0.42.
*>
fn void a_curled_tail_does_not_move_the_mirror_plane() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	uint hips = app.doc.add_dot({ 0.0f, 0.5f, 0.0f }, "hips");
	app.doc.add_dot({ 0.0f, 0.6f, 0.0f }, "spine");
	app.doc.add_dot({ 0.0f, 0.7f, 0.0f }, "chest");
	app.doc.add_dot({ 0.0f, 0.9f, 0.0f }, "head");
	// The tail curls off to +X, the way Zidane's does.
	app.doc.add_dot({ 0.00f, 0.45f, -0.10f }, "tail_1");
	app.doc.add_dot({ 0.06f, 0.45f, -0.20f }, "tail_2");
	app.doc.add_dot({ 0.17f, 0.46f, -0.28f }, "tail_3");
	app.doc.add_dot({ 0.25f, 0.47f, -0.33f }, "tail_4");
	app.doc.add_dot({ 0.35f, 0.72f, 0.06f }, "wrist_l");
	app.doc.add_dot({ -0.35f, 0.72f, 0.06f }, "wrist_r");
	uint pinky_l = app.doc.add_dot({ 0.42f, 0.71f, 0.03f }, "pinky_l");
	app.doc.add_dot({ -0.40f, 0.70f, 0.04f }, "pinky_r");
	app.doc.root_id = hips;

	Vec3 point;
	Vec3 normal;
	app.mirror_plane(&point, &normal, app.picker.scale * 0.01f);
	test::@check(math::abs(point.x) < 1e-4f, "the tail dragged the plane to x=%.4f", point.x);

	app.select(pinky_l);
	(void)app.mirror_selection();
	crig::Dot* twin = app.dot_named("pinky_r");
	test::@check(twin != null, "no pinky_r");
	if (twin == null) return;
	test::@check((twin.position - (Vec3){ -0.42f, 0.71f, 0.03f }).length() < 1e-4f,
		"pinky_r is not pinky_l's reflection: %s", twin.position);
}

<*
 Once the plane is corrected off the rig, the mirror reflects across it — not the
 mesh's centre — and the correction takes back with one undo.
*>
fn void the_corrected_plane_makes_the_mirror_land_right() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "the plane starts at the empty mesh's x=0");

	// A skeleton sitting around x = 2, far from the mesh's x = 0. The left hand is
	// placed roughly, for the mirror to square up against the right.
	uint spine = app.doc.add_dot({ 2.0f, 1.0f, 0 }, "spine");
	uint hr = app.doc.add_dot({ 2.6f, 0.5f, 0 }, "hand_r");
	app.doc.add_dot({ 1.8f, 0.5f, 0 }, "hand_l");
	app.doc.root_id = spine;
	app.doc.connect(spine, hr);

	// Correct the plane off the rig — what edit_rig's symmetry op does — banked as
	// its own undo step.
	float plane;
	test::@check(app.symmetry_plane(&plane), "a plane should read off the rig");
	test::@check(app.set_sym_x_recorded(plane), "the plane should move off the mesh's 0");
	app.undo_stack.commit();
	test::@check(app.doc.sym_x > 1.5f, "the plane is now the rig's own (sym_x=%.4f)", app.doc.sym_x);

	app.select(hr);
	(void)app.mirror_selection();

	crig::Dot* twin = app.dot_named("hand_l");
	test::@check(twin != null, "no hand_l twin");
	if (twin == null) return;
	// Across the rig's plane the twin lands near the skeleton (x>1), not flung to
	// about -2.6 where reflecting across x=0 would have put it.
	test::@check(twin.position.x > 1.0f, "hand_l reflected across the wrong plane (x=%.4f)", twin.position.x);
	test::@check(math::abs(twin.position.x - (2.0f * app.doc.sym_x - 2.6f)) < 1e-3f,
		"hand_l is not the reflection of hand_r across the plane");

	// One undo takes the plane correction back to the mesh's 0.
	test::@check(app.undo(), "the mirror would not undo");
	test::@check(app.undo(), "the plane correction would not undo");
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "undo did not restore the plane to 0 (%.4f)", app.doc.sym_x);
}

<*
 The reported case: a lopsided mesh leaves `sym_x` off the body's midline, and
 pressing M with no plane set at all still lands the twin by the skeleton — the
 mirror reads its own centre line off the centre joints. It corrects on its own,
 without touching the stored plane, so a rig on a symmetric mesh is unaffected.
*>
fn void the_mirror_reads_the_plane_off_the_skeleton_on_its_own() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	// Stand in for a lopsided mesh: the plane the box would give sits at 0, well
	// off the skeleton, which is centred on x = 2 by its named centre joints.
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "the stored plane starts off the skeleton at 0");

	app.doc.add_dot({ 2.0f, 1.2f, 0 }, "spine");
	app.doc.add_dot({ 2.0f, 1.6f, 0 }, "chest");
	uint sr = app.doc.add_dot({ 2.7f, 0.9f, 0 }, "shoulder_r");
	app.doc.add_dot({ 1.4f, 0.9f, 0.1f }, "shoulder_l");  // roughly placed, to be squared

	app.select(sr);
	// No symmetry op first — this is the plain-M path.
	(void)app.mirror_selection();

	crig::Dot* twin = app.dot_named("shoulder_l");
	test::@check(twin != null, "no shoulder_l twin");
	if (twin == null) return;
	// Reflected across the skeleton's x = 2, shoulder_l lands at 2*2 - 2.7 = 1.3 —
	// near the body — not at -2.7 where the stored x = 0 plane would fling it.
	test::@check(math::abs(twin.position.x - 1.3f) < 1e-4f,
		"shoulder_l reflected across the skeleton's midline (x=%.4f)", twin.position.x);
	test::@check(math::abs(twin.position.y - 0.9f) < 1e-4f && math::abs(twin.position.z) < 1e-4f,
		"the twin took the source's y and z, only x reflected");
	// The stored plane is left where it was — the correction is the mirror's own,
	// not a silent edit to the document.
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "the mirror did not move the stored plane (%.4f)", app.doc.sym_x);
}

<*
 The turned-character case: a rig modelled facing a diagonal, not straight +Z, so
 its left-right axis is tilted about the vertical. The mirror must reflect across
 that tilted plane — carrying a twin around to the other side of the *body*, at
 the same body-depth — not across the world-X plane, which keeps world depth and
 throws the twin out in front. The plane's orientation comes off the rig's own
 paired joints; a near-square rig keeps the world-aligned plane (see the tests
 above), so only a genuinely turned rig is tilted.
*>
fn void the_mirror_follows_a_turned_characters_own_plane() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	// A rig turned 45° about Y: its left-right axis, world X for a forward-facing
	// rig, is now n = (cos45, 0, -sin45). Centre joints on the plane through the
	// origin's vertical; limb pairs straddle it evenly, except the hand, placed
	// crooked for the mirror to square up.
	float k = 0.70710678f;  // cos45 = sin45

	app.doc.add_dot({ 0, 1.0f, 0 }, "spine");   // centre joints, on the plane
	app.doc.add_dot({ 0, 1.5f, 0 }, "chest");
	// arm and leg pairs sit exactly symmetric about the tilted plane, so they
	// pin the orientation; the hand is placed off, to be squared.
	app.doc.add_dot({ k*0.6f, 1.0f, -k*0.6f }, "arm_r");
	app.doc.add_dot({ -k*0.6f, 1.0f, k*0.6f }, "arm_l");
	app.doc.add_dot({ 0.354f, 0.2f, -0.354f }, "leg_r");
	app.doc.add_dot({ -0.354f, 0.2f, 0.354f }, "leg_l");
	uint hr = app.doc.add_dot({ 0.636f, 0.8f, -0.636f }, "hand_r");
	app.doc.add_dot({ -0.5f, 0.85f, 0.5f }, "hand_l");  // crooked

	// The plane read off the rig is tilted, not world-aligned.
	float[<3>] point;
	float[<3>] normal;
	app.mirror_plane(&point, &normal, app.picker.scale * 0.01f);
	test::@check(math::abs(normal.x) < 0.9f && math::abs(normal.z) > 0.4f,
		"the plane normal is tilted, not world X (n = %.3f, %.3f, %.3f)", normal.x, normal.y, normal.z);

	// The expected reflection across the derived plane, computed from the source's
	// position captured before the mirror runs.
	float[<3>] src = app.dot_named("hand_r").position;
	float d = (src - point).dot(normal);
	float[<3>] want = src - normal * (2.0f * d);

	app.select(hr);
	(void)app.mirror_selection();

	crig::Dot* twin = app.dot_named("hand_l");
	test::@check(twin != null, "no hand_l twin");
	if (twin == null) return;

	// It landed on the tilted reflection — the +z side of the body — not where the
	// world-X mirror would keep it (z ≈ -0.636, out in front).
	test::@check(twin.position.z > 0.4f,
		"hand_l went around to the body's other side (z=%.3f), not kept in front by a world-X flip", twin.position.z);
	test::@check((twin.position - want).length() < 1e-3f,
		"hand_l is the reflection across the rig's own tilted plane (got %.3f,%.3f,%.3f want %.3f,%.3f,%.3f)",
		twin.position.x, twin.position.y, twin.position.z, want.x, want.y, want.z);
}

<*
 edit_rig's symmetry op sets the plane — explicitly, or derived from the rig —
 and get_scene reports it.
*>
fn void edit_rig_symmetry_sets_the_plane() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// An explicit plane.
	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"symmetry","plane":0.25}]}`);
	if (catch set) { test::@check(false, "the explicit symmetry op answers"); return; }
	set.free();
	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene) { test::@check(false, "get_scene answers"); return; }
	double reported = scene.get("rig")!!.get_float("symmetry_x") ?? 999.0;
	scene.free();
	test::@check(math::abs(reported - 0.25) < 1e-4, "get_scene should report the plane just set (%.4f)", reported);

	// Derived from the skeleton — the fixture's hips/knee/foot are all at x=0, so
	// the plane comes back at 0.
	Object*? derived = f.call_tool("edit_rig", `{"ops":[{"op":"symmetry","from":"skeleton"}]}`);
	if (catch derived) { test::@check(false, "the derive-from-skeleton op answers"); return; }
	derived.free();
	Object*? scene2 = f.call_tool("get_scene", "{}");
	if (catch scene2) { test::@check(false, "get_scene answers again"); return; }
	double back = scene2.get("rig")!!.get_float("symmetry_x") ?? 999.0;
	scene2.free();
	test::@check(math::abs(back) < 1e-3, "deriving the plane off a centred rig gives x=0 (%.4f)", back);

	// A symmetry op with neither plane nor from is refused by name.
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"symmetry"}]}`, "plane", "from"),
		"a symmetry op with nothing to set is refused");
}

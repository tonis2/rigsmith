<*
 B4: the picking math, offline and with no GPU.

     `c3c test --trust=full --test-filter crig_tests::pick`

 Everything between a mouse position and a dot position. This is where crig is
 most likely to be quietly wrong, because the failure mode is not a crash: the
 mesh renders, dots appear, and they sit a little away from where the user
 clicked. Nobody can tell by looking whether the projection or the ray is the
 half that lied.

 So the test pins both halves against each other:

     round trip   for a grid of pixels, unproject to a world point and project
                  it straight back. Any disagreement between the two
                  directions — a y flip, the bar height, an aspect ratio —
                  shows up here as pixels.
     snapping     a click at the middle of the viewport lands *inside* the
                  mesh, and projects back to the pixel it came from.
     inside       the snapped point can see a surface both forwards and
                  backwards along the view ray, which a point on the skin or
                  outside the body cannot.

 The viewport is deliberately not square and not the window: it is the region
 the mesh renders into, with the menu bar's height taken off. That is the
 exact mistake this test exists to catch.
*>
module crig_tests::pick;

import crig;
import rig;
import gltf;
import collision;
import std::core::test;
import std::io;
import std::math;
import std::math::matrix;


<*
 A real model to aim at, kept in the repo so these run everywhere.

 Relative, so the run has to start from the crig directory. The mesh only has to
 be closed and roughly centred for the claims below to hold — none of them
 depends on its shape.
*>
const String MESH = "assets/animations/humanoid.glb";

// The viewport crig actually renders into: the window minus the menu bar.
// Viewport-LOCAL space — the bar offsets where this region sits in the window,
// not the pixels inside it, so no origin appears anywhere in this test.
const Vec2 VIEWPORT = { 1280.0, 800.0 - 28.0 };

// A round trip through two 4x4 matrices in float32, over a viewport a thousand
// pixels wide. Sub-pixel is the claim; this is the float noise around it.
const float PIXEL_TOLERANCE = 0.05;

<*
 The same claim for a model that does not sit on the world origin.

 Looser, and not by taste: `ray_direction` builds a world point as
 `eye + direction * distance` and the view matrix then subtracts the eye back
 out, so the significant bits spent on the offset are bits not spent on the
 result. The error tracks distance from the origin and not model size — a unit
 box at the origin round trips to 0.04 px and the same box a hundred units out
 to 0.62 px, while a two-hundred-unit box at the origin stays at 0.04.

 `assets/animations/humanoid.glb` stands on the ground plane rather than around
 the origin — centred across and front-to-back, but running 0..1 upward — so the
 camera that frames it sits half a body height off the origin, which is why it
 needs its own figure.
*>
const float OFF_ORIGIN_TOLERANCE = 0.15;

<*
 A loaded mesh with a camera framed on it and a picker built over it.

 The camera is `framed`, which aims at the bounding-box centre — so the centre
 pixel looks straight down the barrel of the mesh, which is what makes the snap
 checks below predictable.
*>
struct Aimed
{
	rig::TriMesh geometry;
	crig::OrbitCamera camera;
	crig::Picker picker;
}

<*
 Load `MESH` and aim at it. Allocates from `mem`; freed with `Aimed.free`.
*>
fn Aimed? aimed()
{
	rig::TriMesh geometry = rig::load_gltf(mem, MESH)!;
	return { geometry, crig::framed(geometry.bounds()), crig::build_picker(geometry) };
}

fn void Aimed.free(&self)
{
	self.picker.free();
	self.geometry.free(mem);
}

<*
 The worst round-trip error over a grid of pixels, and where it happened.

 For each pixel: unproject to a world point at the target's depth, then project
 that point straight back. If the two directions disagree about which way y
 points, or about how wide the viewport is, the returned pixel drifts from the
 one asked for.

 Faults out if any pixel resolves to no ray at all, which is a different failure
 from an inaccurate one and deserves to be reported as itself.
*>
fn float? worst_round_trip(crig::OrbitCamera camera, Vec2* worst_at)
{
	float worst = 0.0f;

	// Inset from the edges: the pixel at exactly x = width maps to NDC 1.0,
	// which is on the frustum plane rather than inside it. The corners are
	// included on purpose — a y flip is invisible at the centre and worth 800
	// pixels at the top.
	for (int row = 0; row <= 8; row++)
	{
		for (int column = 0; column <= 8; column++)
		{
			Vec2 pixel = {
				(0.5f + (float)column / 8.0f * (VIEWPORT.x - 1.0f)),
				(0.5f + (float)row / 8.0f * (VIEWPORT.y - 1.0f)),
			};

			Vec3 direction = camera.ray_direction(pixel, VIEWPORT)!;

			// Any distance in front of the camera works; the target's depth is
			// where the model is, so it is the honest place to test.
			Vec3 world = camera.eye() + direction * camera.distance;
			Vec2 back = crig::project(camera.view_projection(VIEWPORT.x / VIEWPORT.y), world, VIEWPORT)!;

			float off = (back - pixel).length();
			if (off > worst)
			{
				worst = off;
				*worst_at = pixel;
			}
		}
	}

	return worst;
}

<*
 project and ray_direction have to be inverses.

 No mesh: a box around the origin, which is where float32 has the most to spend
 on the answer, so what is left is the projection math rather than cancellation.
 See `OFF_ORIGIN_TOLERANCE` for the other half of the story.
*>
fn void project_and_ray_direction_are_inverses() @test
{
	Vec2 worst_at = { 0, 0 };
	crig::OrbitCamera camera = crig::framed({ .min = { -1, -1, -1 }, .max = { 1, 1, 1 } });

	float? worst = worst_round_trip(camera, &worst_at);
	if (catch fault error = worst)
	{
		test::@check(false, "a viewport pixel resolved to no ray (%s)", error);
		return;
	}

	test::@check(worst < PIXEL_TOLERANCE, "worst round trip %.4f px at (%.0f, %.0f)",
		worst, worst_at.x, worst_at.y);
}

<*
 And on the framing of a real model, which is not centred on the origin.

 Pins the cost of that offset rather than leaving it to be discovered when a dot
 lands beside the pointer. A model placed much further out than this one pays
 proportionally more — see `OFF_ORIGIN_TOLERANCE`.
*>
fn void the_round_trip_survives_a_model_off_the_origin() @test
{
	Aimed? scene = aimed();
	if (catch fault error = scene)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", MESH, error);
		return;
	}
	defer scene.free();

	Vec2 worst_at = { 0, 0 };
	float? worst = worst_round_trip(scene.camera, &worst_at);
	if (catch fault error = worst)
	{
		test::@check(false, "a viewport pixel resolved to no ray (%s)", error);
		return;
	}

	test::@check(worst < OFF_ORIGIN_TOLERANCE, "worst round trip %.4f px at (%.0f, %.0f)",
		worst, worst_at.x, worst_at.y);
}

<*
 A click at the middle of the viewport has to land inside the model.

 `framed` aims the camera at the bounding-box centre, so the centre pixel is
 looking straight down the barrel of the mesh — if that misses, the camera and
 the picker do not agree on where the model is.
*>
fn void a_click_at_the_centre_lands_inside_the_mesh() @test
{
	Aimed? scene = aimed();
	if (catch fault error = scene)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", MESH, error);
		return;
	}
	defer scene.free();

	Vec3 snapped = snap_at_centre(&scene)!!;

	rig::Bounds box = scene.geometry.bounds();
	for (usz axis = 0; axis < 3; axis++)
	{
		test::@check(snapped[axis] >= box.min[axis] && snapped[axis] <= box.max[axis],
			"the dot's axis %d landed at %.4f, outside the mesh bounds %.4f..%.4f",
			axis, snapped[axis], box.min[axis], box.max[axis]);
	}
}

// And that it comes back to the pixel that placed it. A dot the user cannot
// click again is the same bug as a dot placed in the wrong spot.
fn void a_placed_dot_projects_back_to_its_pixel() @test
{
	Aimed? scene = aimed();
	if (catch fault error = scene)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", MESH, error);
		return;
	}
	defer scene.free();

	Vec3 snapped = snap_at_centre(&scene)!!;
	Vec2 centre = VIEWPORT * 0.5f;

	Vec2? back = crig::project(
		scene.camera.view_projection(VIEWPORT.x / VIEWPORT.y), snapped, VIEWPORT);
	if (catch back)
	{
		test::@check(false, "the dot projects nowhere on the screen");
		return;
	}

	float off = (back - centre).length();
	test::@check(off < PIXEL_TOLERANCE, "the dot reprojected %.4f px from the pixel that placed it", off);
}

<*
 The snapped point is in the interior, not welded to the skin.

 Casts back along the view ray from the snapped point. A point in the interior
 sees the near wall behind it and the far wall ahead; a point on the skin sees
 nothing behind it, and a point floating outside the mesh entirely sees nothing
 in one direction or the other. A proxy rather than a parity test, but it fails
 for exactly the ways `snap_inside` can go wrong.
*>
fn void a_placed_dot_has_surface_on_both_sides() @test
{
	Aimed? scene = aimed();
	if (catch fault error = scene)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", MESH, error);
		return;
	}
	defer scene.free();

	Vec2 centre = VIEWPORT * 0.5f;
	Vec3 direction = scene.camera.ray_direction(centre, VIEWPORT)!!;
	Vec3 snapped = snap_at_centre(&scene)!!;

	// Started far enough off the point that the cast does not immediately
	// re-find a triangle it is sitting on.
	float step = scene.picker.scale * 0.0001f;
	collision::Ray forward = { .origin = snapped + direction * step, .direction = direction };
	collision::Ray backward = { .origin = snapped - direction * step, .direction = -direction };

	test::@check(scene.picker.bvh.ray_intersects(forward).collided, "nothing ahead of the dot along the view ray");
	test::@check(scene.picker.bvh.ray_intersects(backward).collided, "nothing behind the dot along the view ray");
}

<*
 Where a click at the centre of the viewport puts a dot.

 Shared by the three snap checks so each states one claim about the same point
 rather than re-deriving it and asserting the derivation too.
*>
fn Vec3? snap_at_centre(Aimed* scene)
{
	Vec3 direction = scene.camera.ray_direction(VIEWPORT * 0.5f, VIEWPORT)!;
	return scene.picker.snap_inside({ .origin = scene.camera.eye(), .direction = direction });
}

// ---------------------------------------------------------------------------
// Models that are not one closed surface
//
// A generator emits a heap of interpenetrating primitives, not a watertight
// body: the robot shipped in `assets/animations` is seventy separate pieces,
// seven of them making up a single hand. The fixtures below are the smallest
// statement of each way that meets a ray, built by hand so every claim can name
// the coordinate it expects rather than measuring the mesh and believing it.

// The twelve triangles of a box, wound outward.
//
// `snap_inside` reads a face's facing off its winding, so a box wound the other
// way is a box the walk sees inside-out — which is the one way these fixtures
// could quietly stop testing what they claim to.
const uint[36] BOX_FACES @local = {
	4, 5, 6, 4, 6, 7,   // +Z
	0, 3, 2, 0, 2, 1,   // -Z
	1, 2, 6, 1, 6, 5,   // +X
	0, 4, 7, 0, 7, 3,   // -X
	3, 7, 6, 3, 6, 2,   // +Y
	0, 1, 5, 0, 5, 4,   // -Y
};

<*
 Two axis-aligned boxes, as one mesh.

 The storage is the struct's own, and the mesh borrows it — so this has to
 outlive the `Picker` built over it, which inside one test it does. Nothing here
 allocates, which is what keeps these tests free of teardown that could hide a
 fault.
*>
struct TwoBoxes @local
{
	Vec3[16] positions;
	uint[72] indices;
}

fn rig::TriMesh TwoBoxes.mesh(&self, Vec3 low, Vec3 high, Vec3 other_low, Vec3 other_high)
{
	corners(self.positions[:8], low, high);
	corners(self.positions[8:8], other_low, other_high);

	foreach (usz i, corner : BOX_FACES)
	{
		self.indices[i] = corner;
		self.indices[i + 36] = corner + 8;
	}
	return { .positions = self.positions[..], .indices = self.indices[..] };
}

// The eight corners of a box, in the order `BOX_FACES` winds them.
fn void corners(Vec3[] into, Vec3 low, Vec3 high) @local
{
	into[0] = { low.x, low.y, low.z };
	into[1] = { high.x, low.y, low.z };
	into[2] = { high.x, high.y, low.z };
	into[3] = { low.x, high.y, low.z };
	into[4] = { low.x, low.y, high.z };
	into[5] = { high.x, low.y, high.z };
	into[6] = { high.x, high.y, high.z };
	into[7] = { low.x, high.y, high.z };
}

// Straight at the model from in front, which is where every claim below reads
// its depth along.
fn collision::Ray down_z() @local => { .origin = { 0, 0, 3 }, .direction = { 0, 0, -1 } };

// Loose enough for float error in a BVH and the epsilon each cast steps by,
// tight enough that none of the depths below could be mistaken for another.
const float DEPTH_TOLERANCE = 0.002;

<*
 Two boxes that interpenetrate are the one solid they look like.

 The ray meets them front, front, back, back. Pairing each face with the next
 calls that second front face an unrelated part of the model and gives up on
 finding a midpoint at all, which leaves the dot just under the skin of the
 nearer box; counting how many solids the ray is inside reads the union, and its
 middle is where a bone through the pair belongs.

 This is the shape a limb on a kitbashed model is actually made of, so it is the
 ordinary case rather than a degenerate one.
*>
fn void two_interpenetrating_boxes_are_read_as_one_piece() @test
{
	TwoBoxes fixture;
	rig::TriMesh mesh = fixture.mesh(
		{ -0.25, -0.25, 0.00 }, { 0.25, 0.25, 0.10 },
		{ -0.25, -0.25, 0.06 }, { 0.25, 0.25, 0.16 });

	crig::Picker picker = crig::build_picker(mesh);
	defer picker.free();

	Vec3 snapped = picker.snap_inside(down_z())!!;

	// The union runs 0.00 to 0.16, so its middle is 0.08. Under the old pairing
	// the answer was 0.1455 — inside the nearer box, and a whole box away from
	// the material's centre.
	test::@check(math::abs(snapped.z - 0.08f) < DEPTH_TOLERANCE,
		"the dot landed at z %.4f, not in the middle of the union at 0.08", snapped.z);
}

<*
 A drag keeps the dot in the piece it is already in.

 With nothing to go on the nearest piece wins, because the thing under the
 cursor is the thing in front — that is a fresh placement, and it is unchanged.
 A drag has something to go on: where the dot is now. Without it the depth is
 re-chosen from nothing on every mouse move, and on a model whose ray passes
 through more than one piece the answer changes between neighbouring pixels,
 which is the whole of what the user sees as the dot jumping.
*>
fn void a_hint_holds_the_dot_in_its_own_piece() @test
{
	TwoBoxes fixture;
	rig::TriMesh mesh = fixture.mesh(
		{ -0.25, -0.25, 0.60 }, { 0.25, 0.25, 0.90 },   // near the eye
		{ -0.25, -0.25, 0.00 }, { 0.25, 0.25, 0.30 });  // and well behind it

	crig::Picker picker = crig::build_picker(mesh);
	defer picker.free();

	Vec3 fresh = picker.snap_inside(down_z())!!;
	test::@check(math::abs(fresh.z - 0.75f) < DEPTH_TOLERANCE,
		"a click with no hint landed at z %.4f, not in the near box at 0.75", fresh.z);

	Vec3 in_far = { 0, 0, 0.15 };
	Vec3 held = picker.snap_inside(down_z(), &in_far)!!;
	test::@check(math::abs(held.z - 0.15f) < DEPTH_TOLERANCE,
		"a dot in the far box was pulled to z %.4f, out of the piece it was in", held.z);

	// And the hint is a preference, not a lock: a dot in the near box stays there
	// rather than being dragged to whichever piece was hinted last.
	Vec3 in_near = { 0, 0, 0.75 };
	Vec3 kept = picker.snap_inside(down_z(), &in_near)!!;
	test::@check(math::abs(kept.z - 0.75f) < DEPTH_TOLERANCE,
		"a dot in the near box moved to z %.4f", kept.z);
}

<*
 A hint that sits in no piece snaps to the front, never onto what is behind it.

 The continuity only holds a dot in a piece it is genuinely *inside*. A drag that
 has carried the dot into the gap between two limbs — or in front of the whole
 model, or clean off the back of it — is inside neither, and the front-most piece
 wins exactly as a fresh click's would. Nearest-to-the-hint used to win here
 instead, so a dot nudged into the gap and a hair nearer the far box was pulled
 through to the back of the body; that is the jump the user reported, and the
 hint at 0.35 below is closer to the far box's face than to the near box's yet
 still lands in front.
*>
fn void a_hint_in_no_piece_snaps_to_the_front() @test
{
	TwoBoxes fixture;
	rig::TriMesh mesh = fixture.mesh(
		{ -0.25, -0.25, 0.60 }, { 0.25, 0.25, 0.90 },   // near the eye
		{ -0.25, -0.25, 0.00 }, { 0.25, 0.25, 0.30 });  // and well behind it

	crig::Picker picker = crig::build_picker(mesh);
	defer picker.free();

	// In the 0.30..0.60 gap, nearer the far box's face (0.30) than the near box's
	// (0.60) — the exact bias that used to drag the dot to the back.
	Vec3 in_gap = { 0, 0, 0.35 };
	Vec3 forward = picker.snap_inside(down_z(), &in_gap)!!;
	test::@check(math::abs(forward.z - 0.75f) < DEPTH_TOLERANCE,
		"a dot in the gap landed at z %.4f, not pulled forward into the near box at 0.75", forward.z);

	// In front of the whole model, and clean off the back of it — both are in no
	// piece, and both take the front rather than holding a phantom depth.
	Vec3 ahead = { 0, 0, 1.50 };
	Vec3 from_ahead = picker.snap_inside(down_z(), &ahead)!!;
	test::@check(math::abs(from_ahead.z - 0.75f) < DEPTH_TOLERANCE,
		"a dot in front of the model landed at z %.4f, not in the near box at 0.75", from_ahead.z);

	Vec3 behind = { 0, 0, -0.50 };
	Vec3 from_behind = picker.snap_inside(down_z(), &behind)!!;
	test::@check(math::abs(from_behind.z - 0.75f) < DEPTH_TOLERANCE,
		"a dot behind the model landed at z %.4f, not in the near box at 0.75", from_behind.z);
}

<*
 Stepping in from an open surface stops short of the next one.

 Two facing sheets with no back between them close no run at all, so there is no
 midpoint to take and the dot steps in from the entry face instead. How far used
 to be `OPEN_MESH_DEPTH` of the model's diagonal and nothing else — a figure of
 the whole model applied to a local surface. Here that is 0.028 against material
 0.020 thick, so the dot went in one side and out the other, and came to rest
 outside the mesh it was placed on. That is a metre-wide robot with
 two-centimetre fingers, which is exactly where it was reported.
*>
fn void an_open_surface_is_not_stepped_straight_through() @test
{
	// Two sheets a fifth of the step apart, both facing the eye: front, front,
	// and no back face to close on.
	Vec3[8] positions = {
		{ -0.5, -0.5, 0.10 }, { 0.5, -0.5, 0.10 }, { 0.5, 0.5, 0.10 }, { -0.5, 0.5, 0.10 },
		{ -0.5, -0.5, 0.08 }, { 0.5, -0.5, 0.08 }, { 0.5, 0.5, 0.08 }, { -0.5, 0.5, 0.08 },
	};
	uint[12] indices = { 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 };

	rig::TriMesh mesh = { .positions = positions[..], .indices = indices[..] };
	crig::Picker picker = crig::build_picker(mesh);
	defer picker.free();

	// The diagonal is 1.414, so the ceiling is 0.0283 — more than the 0.02 there
	// is to step into. Half the gap is 0.01, which lands halfway between.
	test::@check(picker.scale * crig::OPEN_MESH_DEPTH > 0.02f,
		"the fixture no longer has a step larger than its own material");

	Vec3 snapped = picker.snap_inside(down_z())!!;

	test::@check(snapped.z < 0.10f && snapped.z > 0.08f,
		"the dot landed at z %.4f, not between the two sheets at 0.08..0.10", snapped.z);
	test::@check(math::abs(snapped.z - 0.09f) < DEPTH_TOLERANCE,
		"the dot landed at z %.4f, not half the gap in at 0.09", snapped.z);
}

<*
 A face the walk sees the ray leave without seeing it enter still ends material
 there.

 Two things produce one, and both matter. A ray grazing a silhouette edge misses
 the entry triangle on a float's last bit and finds only the exit — on the hand
 this was reported against, that is one pixel in twenty. And a camera pushed
 inside the model starts every ray in solid material, which is the case stated
 here because it is the one that can be written down exactly.

 Dropping the face sends the dot to whatever solid lies further back, which on a
 hand built from overlapping boxes is a different finger.
*>
fn void material_the_ray_starts_inside_ends_where_it_leaves() @test
{
	TwoBoxes fixture;
	rig::TriMesh mesh = fixture.mesh(
		{ -0.25, -0.25, 0.00 }, { 0.25, 0.25, 1.00 },      // the ray begins in this one
		{ -0.25, -0.25, -1.00 }, { 0.25, 0.25, -0.50 });   // and this one is behind it

	crig::Picker picker = crig::build_picker(mesh);
	defer picker.free();

	collision::Ray from_within = { .origin = { 0, 0, 0.5 }, .direction = { 0, 0, -1 } };
	Vec3 snapped = picker.snap_inside(from_within)!!;

	test::@check(math::abs(snapped.z) < DEPTH_TOLERANCE,
		"the dot landed at z %.4f, not where the material it began in ends at 0.00", snapped.z);
}

<*
 Posed overlay occlusion follows the same triangles the GPU skins, without
 rebuilding the mesh or its BVH for each palette.

 A cube moves five units sideways, entirely away from its rest picker. The lazy
 query has to agree with a reference picker built over fully CPU-skinned
 vertices, then follow a second palette using the same acceleration structure.
 That last step is the cache regression: generation one must not leave either a
 transformed node box or a skinned leaf vertex behind in generation two.
*>
fn void posed_occlusion_follows_the_palette_and_invalidates_its_lazy_cache() @test
{
	Vec3[8] rest;
	corners(rest[..], { -1, -1, -1 }, { 1, 1, 1 });
	uint[36] indices = BOX_FACES;
	rig::TriMesh mesh = { .positions = rest[..], .indices = indices[..] };

	ushort[32] joints;
	float[32] weights;
	for (usz vertex = 0; vertex < rest.len; vertex++) weights[vertex * 4] = 1.0f;
	gltf::SkinBinding binding = {
		.joints = joints[..],
		.weights = weights[..],
		.slots = 4,
		.vertices = rest.len,
	};

	crig::Picker rest_picker = crig::build_picker(mesh);
	defer rest_picker.free();
	crig::DeformedCollisionSurface posed = crig::build_deformed_collision_surface(&rest_picker, binding, 1);
	defer posed.free();

	Matrix4f[1] palette = { matrix::IDENTITY4 };
	palette[0].m[12] = 5.0f;

	Vec3[8] moved;
	rig::skin_positions(moved[..], rest[..], binding, palette[..])!!;
	rig::TriMesh reference_mesh = { .positions = moved[..], .indices = indices[..] };
	crig::Picker reference = crig::build_picker(reference_mesh);
	defer reference.free();

	Vec3 eye = { 5, 0, 6 };
	Vec3 behind = { 5, 0, -2 };
	test::@check(!rest_picker.occluded(eye, behind),
		"the rest picker unexpectedly reaches the translated cube fixture");
	test::eq(posed.occluded(eye, behind, binding, palette[..], 1),
		reference.occluded(eye, behind));
	test::eq(posed.occluded(eye, { 5, 0, 0 }, binding, palette[..], 1),
		reference.occluded(eye, { 5, 0, 0 }));
	test::eq(posed.occluded(eye, { 5, 0, 2 }, binding, palette[..], 1),
		reference.occluded(eye, { 5, 0, 2 }));

	// The UI-facing door chooses that posed surface while retaining the simple
	// clean-mesh and wireframe rules. This is what all three viewport callers —
	// bones, dots and names — use.
	crig::AppState app = {
		.picker = rest_picker,
		.deformed_surface = posed,
		.skin = binding,
		.pose_palette = palette[..],
		.pose_generation = 1,
		.show_mesh = true,
	};
	test::@check(app.rig_overlay_occluded(eye, behind),
		"the overlay door consulted the rest mesh instead of the posed one");
	app.config.viewport_shading = crig::ShadingMode.WIREFRAME;
	test::@check(!app.rig_overlay_occluded(eye, behind),
		"wireframe still applies mesh occlusion");
	app.config.viewport_shading = crig::ShadingMode.SOLID;
	app.show_mesh = false;
	test::@check(!app.rig_overlay_occluded(eye, behind),
		"a hidden mesh still applies mesh occlusion");

	// Reuse the exact same occluder with a new evaluated pose. If either cache
	// ignores the generation, one of these two answers remains at +5.
	palette[0].m[12] = -5.0f;
	test::@check(!posed.occluded(eye, behind, binding, palette[..], 2),
		"generation two retained generation one's posed surface");
	test::@check(posed.occluded({ -5, 0, 6 }, { -5, 0, -2 }, binding, palette[..], 2),
		"generation two did not move the surface with its palette");
}

// ---------------------------------------------------------------------------
// A line that runs past the camera
// ---------------------------------------------------------------------------

<*
 A guide long enough to read as a direction is long enough to run behind the
 eye, and the two have to be reconcilable.

 The axis lock draws its constraint line a body's length either way from the
 joint being moved, which is the length that makes it read as a direction
 through the model rather than a segment between two arbitrary points. Project
 the two ends separately and the moment the camera comes in close — which is
 exactly when somebody reaches for a lock — one end is behind the eye, `project`
 rightly refuses it, and a caller needing both ends draws nothing at all. The
 whole guide disappears at the moment it is most wanted, and it looks like a
 missing feature rather than a bug.
*>
fn void a_segment_running_past_the_camera_still_draws() @test
{
	Aimed? ready = aimed();
	if (catch ready)
	{
		test::@check(false, "could not load %s — run from the crig directory", MESH);
		return;
	}
	Aimed scene = ready;
	defer scene.free();

	// In close, the way a rigger is when placing a finger.
	crig::OrbitCamera camera = scene.camera;
	camera.distance *= 0.12f;
	Matrix4f view_projection = camera.view_projection(VIEWPORT.x / VIEWPORT.y);

	// A guide through the point being looked at, along the axis the camera is
	// most side-on to, so the line crosses the screen rather than vanishing to a
	// dot. A body's length either way, which is what `paint_move_guides` uses.
	Vec3 at = camera.target;
	Vec3 reach = { scene.picker.scale, 0, 0 };

	// The premise: one end really is behind the eye here, so the fixture poses
	// the question rather than passing by luck.
	Vec2? behind = crig::project(view_projection, at - reach, VIEWPORT);
	Vec2? ahead = crig::project(view_projection, at + reach, VIEWPORT);

	bool one_is_lost = false;
	if (catch behind) one_is_lost = true;
	if (catch ahead) one_is_lost = true;
	test::@check(one_is_lost,
		"both ends of the guide project from here, so this fixture no longer poses the question");

	Vec2[2]? drawn = crig::project_segment(view_projection, at - reach, at + reach, VIEWPORT);
	if (catch fault error = drawn)
	{
		test::@check(false, "a guide through the point being looked at was refused entirely (%s)", error);
		return;
	}
	Vec2[2] line = drawn;

	test::@check(math::is_finite(line[0].x) && math::is_finite(line[0].y)
		&& math::is_finite(line[1].x) && math::is_finite(line[1].y),
		"the clipped guide came back as (%.1f, %.1f)-(%.1f, %.1f)",
		line[0].x, line[0].y, line[1].x, line[1].y);

	// And it is a line rather than a point: a clip that collapsed both ends onto
	// the eye plane would satisfy everything above and draw nothing visible.
	test::@check((line[1] - line[0]).length() > VIEWPORT.x,
		"the guide came back %.1f px long, which is shorter than the screen it should cross",
		(line[1] - line[0]).length());

	// The end that was always visible must land exactly where it always did:
	// clipping is about the other end, and moving this one would move the guide
	// off the joint it belongs to.
	if (try Vec2 kept = ahead)
	{
		test::@check((line[1] - kept).length() < PIXEL_TOLERANCE,
			"the visible end moved %.3f px when the far end was clipped",
			(line[1] - kept).length());
	}
}

// A segment wholly behind the eye has no image, and says so rather than
// returning two numbers a caller would draw a line between.
fn void a_segment_wholly_behind_the_camera_is_refused() @test
{
	Aimed? ready = aimed();
	if (catch ready)
	{
		test::@check(false, "could not load %s — run from the crig directory", MESH);
		return;
	}
	Aimed scene = ready;
	defer scene.free();

	Matrix4f view_projection = scene.camera.view_projection(VIEWPORT.x / VIEWPORT.y);

	// Behind the eye, along the line from the target through it and out the back.
	Vec3 back = scene.camera.eye() + (scene.camera.eye() - scene.camera.target);
	Vec3 further = back + (scene.camera.eye() - scene.camera.target);

	Vec2[2]? drawn = crig::project_segment(view_projection, back, further, VIEWPORT);
	if (try drawn) test::@check(false, "a segment behind the camera came back with an image");
}

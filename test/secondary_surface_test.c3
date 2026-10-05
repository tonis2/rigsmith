<*
 S2: a chain against the character's own skin, with no window.

     `c3c test --trust=full --test-filter crig_tests::secondary_surface`

 The fixture is a body with a tail: a box for the body, a thin box for the
 tail sticking out over it, each pinned outright to its own dots so the skin
 regions are exactly what the check says they are. The tail is let go over
 the body — no spring, gravity on — and has to come to rest *on* the body
 rather than in it, standing off by its own girth, which nobody typed: the
 tail's thickness is read off the tail box, the tail box is left out of what
 the tail is pushed off, and the body box is what stops it.

 That is the whole of S2 in one drop: the surface is the deformed skin the
 rest of crig reads, the thickness is measured, and the two run through the
 same `JiggleSurface` seam `jiggle_test` checks against a plane.
*>
module crig_tests::secondary_surface;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;

const uint[36] BOX_FACES @local = {
	4, 5, 6, 4, 6, 7,
	0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5,
	0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2,
	0, 1, 5, 0, 5, 4,
};

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

// The body's top face, and how far the tail's axis stands above it.
const float BODY_TOP = 0.5f;
const float TAIL_HEIGHT = 1.0f;
// The tail box is 0.2 across, so its corners stand 0.1·√2 off the axis.
const float TAIL_GIRTH = 0.14142f;

<*
 The body, a box from y = -0.5 to the top; the tail, a thin box along +X a
 half unit above it. Sixteen vertices, twenty-four triangles, and a rig of
 three dots: the body's, inside its box, and two down the tail.
*>
struct Figure
{
	Vec3[16] positions;
	uint[72] indices;
	rig::TriMesh mesh;
	crig::AppGeometryCache cache;
	crig::AppState app;
	uint body;
	uint tail_root;
	uint tail_tip;
}

fn void Figure.open(&self)
{
	corners(self.positions[:8], { -1.0f, -0.5f, -1.0f }, { 1.0f, BODY_TOP, 1.0f });
	corners(self.positions[8:8], { 0.2f, TAIL_HEIGHT - 0.1f, -0.1f }, { 1.4f, TAIL_HEIGHT + 0.1f, 0.1f });
	foreach (usz i, corner : BOX_FACES)
	{
		self.indices[i] = corner;
		self.indices[i + 36] = corner + 8;
	}
	self.mesh = { .positions = self.positions[..], .indices = self.indices[..] };
	self.cache = crig::build_app_geometry_cache(self.mesh, resolution: 12);
	self.app = crig::new_app_from_cache(&self.cache);

	self.body = self.app.doc.add_dot({ 0.0f, 0.0f, 0.0f }, "body");
	self.tail_root = self.app.doc.add_dot({ 0.3f, TAIL_HEIGHT, 0.0f }, "tail_1");
	self.tail_tip = self.app.doc.add_dot({ 0.9f, TAIL_HEIGHT, 0.0f }, "tail_2");
	self.app.doc.connect(self.body, self.tail_root);
	self.app.doc.connect(self.tail_root, self.tail_tip);

	// Every vertex handed to its dot outright, so the regions are the boxes:
	// the body's eight to the body, the tail's front four to the root and its
	// back four to the tip.
	for (uint vertex = 0; vertex < 8; vertex++) self.app.doc.set_pin(vertex, self.body, 1.0f);
	for (uint vertex = 8; vertex < 16; vertex++)
	{
		bool front = self.positions[vertex].x < 0.8f;
		self.app.doc.set_pin(vertex, front ? self.tail_root : self.tail_tip, 1.0f);
	}
}

fn void Figure.close(&self)
{
	self.app.free();
	self.cache.free();
}

// How far a point stands off the body box; zero inside it.
fn float body_gap(Vec3 at)
{
	Vec3 gap = {
		math::max(-1.0f - at.x, math::max(0.0f, at.x - 1.0f)),
		math::max(-0.5f - at.y, math::max(0.0f, at.y - BODY_TOP)),
		math::max(-1.0f - at.z, math::max(0.0f, at.z - 1.0f)),
	};
	return gap.length();
}

// Bind the skin and build the sim over it, the way the first frame of
// playback does. The view is the caller's to free.
fn crig::RigView Figure.bound(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	test::@check(self.app.rebind_skin(&view), "the figure would not bind");
	self.app.rebuild_jiggle(&view);
	return view;
}

<*
 The thickness comes off the skin, the tail's own skin is set aside, and the
 tail comes to rest on the body a girth above it.
*>
fn void a_tail_rests_on_the_body_by_its_own_girth() @test
{
	Figure figure;
	figure.open();
	defer figure.close();
	crig::AppState* app = &figure.app;
	io::printn("a tail rests on the body by its own girth");

	crig::SecondaryChain chain = (crig::SecondaryChain){ .root = figure.tail_root, .tip = figure.tail_tip }
		.with_preset(crig::SecondaryPreset.TAIL);
	// Let go, near enough: the loosest spring a chain has still holds a tail a
	// tenth of a unit under its target against earth gravity, so the weight
	// is turned up until the body is what stops it and nothing else.
	chain.flexibility = 1.0f;
	chain.damping = 0.2f;
	chain.gravity = 6.0f;
	app.doc.set_secondary(chain);

	crig::RigView view = figure.bound();
	defer view.free(mem);

	test::@check(app.jiggle_sim.solves() && app.jiggle_sim.chains.len == 1, "the tail did not become a chain");
	if (!app.jiggle_sim.solves()) return;
	crig::JiggleChain* tail = &app.jiggle_sim.chains[0];

	// --- the measurements -----------------------------------------------------
	test::@check(app.jiggle_sim.surface.present(), "the sim was built with no surface to be held off");

	float clearance = app.collision_clearance();
	float want = TAIL_GIRTH + clearance;
	for (sz i = 1; i < tail.body.particle_radius.len(); i++)
	{
		float radius = tail.body.particle_radius[i];
		test::@check(math::abs(radius - want) < 1.0e-3f,
			"particle %d is %.4f fat; the tail box's girth plus the clearance is %.4f", i, radius, want);
	}

	usz skipped = 0;
	foreach (flag : app.jiggle_skip) if (flag) skipped++;
	test::@check(skipped == 12, "%d triangles are left out of the surface; the tail box is 12", skipped);
	foreach (usz triangle, flag : app.jiggle_skip)
	{
		test::@check(flag == (triangle >= 12), "triangle %d is %s", triangle, flag ? "the tail's" : "the body's");
	}

	// --- the drop -------------------------------------------------------------
	rig::Pose rest = rig::rest_pose(mem, view.len());
	defer rest.free(mem);

	// Every free particle's closest approach to the body box, over the whole
	// drop: a particle may come no nearer than its radius, less the substep of
	// approach a contact is found after.
	float nearest_ever = 1.0e9f;
	for (usz frame = 0; frame < 240; frame++)
	{
		rig::Pose pose = rig::rest_pose(mem, view.len());
		defer pose.free(mem);
		app.tick_jiggle(&view, &pose, 1.0f / 60.0f);
		for (sz i = 1; i < tail.body.positions.len(); i++)
		{
			nearest_ever = math::min(nearest_ever, body_gap(tail.body.positions[i]));
		}
	}

	// The middle particle comes down over the body and rests on its top, a
	// girth and a clearance above it; the tip hangs past the body's edge and
	// rests against the corner, the same distance off it.
	float floor = BODY_TOP + want;
	Vec3 middle = tail.body.positions[1];
	Vec3 tip = tail.body.positions[2];
	test::@check(math::abs(middle.x) < 1.0f && math::abs(middle.y - floor) < 0.02f,
		"the tail rests at %s; the body's top plus the tail's girth and the clearance is %.4f", middle, floor);
	test::@check(math::abs(body_gap(tip) - want) < 0.02f,
		"the tip rests %.4f off the body at %s, not its %.4f", body_gap(tip), tip, want);
	test::@check(nearest_ever > want - 0.03f, "a particle came within %.4f of the body, inside its %.4f", nearest_ever, want);
	test::@check(tail.body.positions[0].y == TAIL_HEIGHT, "the pinned root moved");

	// And the display palette is not the sim's: a fresh stamp after the run,
	// so the overlay's lazy vertices are never the ones posed for the probe.
	test::@check(app.jiggle_palette.len == 0, "the sim kept a palette it had finished with");

	// --- the same tail told not to collide falls through ----------------------
	chain.collide = false;
	app.doc.set_secondary(chain);
	app.jiggle_reset();
	for (usz frame = 0; frame < 240; frame++)
	{
		rig::Pose pose = rig::rest_pose(mem, view.len());
		defer pose.free(mem);
		app.tick_jiggle(&view, &pose, 1.0f / 60.0f);
	}
	// The spring and the weight settle it a little under where the body's top
	// held it: through the contact floor, which is all "not held off" means
	// for a tail that hangs from a spring.
	tail = &app.jiggle_sim.chains[0];
	test::@check(tail.body.positions[1].y < floor - 0.02f,
		"a tail told not to collide was still held off the body, at %.4f", tail.body.positions[1].y);
	test::@check(tail.body.particle_radius[1] == 0.0f, "a tail told not to collide was still measured");
}

<*
 The surface answers what the probe asks: the nearest point within reach, the
 skipped triangles left out, and nothing beyond reach.
*>
fn void the_skin_answers_a_nearest_point_within_reach() @test
{
	Figure figure;
	figure.open();
	defer figure.close();
	crig::AppState* app = &figure.app;
	io::printn("the skin answers a nearest point within reach");

	crig::RigView view = figure.bound();
	defer view.free(mem);
	rig::Pose rest = rig::rest_pose(mem, view.len());
	defer rest.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, rest)!!;
	defer alloc::free(mem, palette);
	uint generation = app.next_pose_generation();

	// A point a tenth above the body's top, inside the tail box's shadow.
	Vec3 above = { 0.5f, BODY_TOP + 0.1f, 0.0f };
	crig::SurfaceContact near = app.deformed_surface.nearest_within(above, 0.3f, {}, app.skin, palette, generation);
	test::@check(near.hit && math::abs(near.distance - 0.1f) < 1.0e-4f && math::abs(near.point.y - BODY_TOP) < 1.0e-4f,
		"the nearest skin to a point over the body is %.4f away at y %.4f", near.distance, near.point.y);
	test::@check(near.hit && near.normal.y > 0.99f, "the body's top face has a normal of %s", near.normal);

	crig::SurfaceContact far = app.deformed_surface.nearest_within(above, 0.05f, {}, app.skin, palette, generation);
	test::@check(!far.hit, "a surface beyond reach was still found");

	// A point just under the tail: nearest to the tail box, unless the tail's
	// triangles are left out — then the body's top, further away.
	Vec3 under = { 0.5f, TAIL_HEIGHT - 0.15f, 0.0f };
	crig::SurfaceContact tail_skin = app.deformed_surface.nearest_within(under, 0.5f, {}, app.skin, palette, generation);
	test::@check(tail_skin.hit && math::abs(tail_skin.distance - 0.05f) < 1.0e-4f && tail_skin.triangle >= 12,
		"the tail's own skin is %.4f away on triangle %d", tail_skin.distance, tail_skin.triangle);

	bool[] skip = alloc::new_array(mem, bool, 24);
	defer alloc::free(mem, skip);
	for (usz i = 12; i < 24; i++) skip[i] = true;
	crig::SurfaceContact body_skin = app.deformed_surface.nearest_within(under, 0.5f, skip, app.skin, palette, generation);
	test::@check(body_skin.hit && math::abs(body_skin.distance - (TAIL_HEIGHT - 0.15f - BODY_TOP)) < 1.0e-4f && body_skin.triangle < 12,
		"with the tail left out the nearest skin is %.4f away on triangle %d", body_skin.distance, body_skin.triangle);

	// The girth of each bone, off its own vertices: the tail's two, and the
	// body's, whose eight corners stand a diagonal off a bone through its middle.
	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);
	sz root = view.joint_of(figure.tail_root);
	float girth = app.deformed_surface.joint_thickness((uint)root, view.skeleton.joints[root], tails[root]);
	test::@check(math::abs(girth - TAIL_GIRTH) < 1.0e-3f, "the tail's root bone measures %.4f, not %.4f", girth, TAIL_GIRTH);
	sz nobody = view.joint_of(figure.body);
	test::@check(app.deformed_surface.joint_thickness((uint)nobody + 100, {}, {}) == 0.0f, "a joint the skin does not know has a girth");
}

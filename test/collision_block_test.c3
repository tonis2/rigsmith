<*
 C3: a turn stops at the mesh.

 Three boxes on two limbs under one hub h: the base a on one, the pivot b
 with the arm c on the other, each box rigid to its joint. Turning b swings
 c's box down onto a's — cousins across the hub, so nothing in the policy
 explains the contact away — and the checks say where the joint lands, that
 it stays there while the sweep goes on, frees itself on the way back,
 escapes to the start, banks as one edit, and is left alone when the
 gesture began in contact or blocking is off.
*>
module crig_tests::collision_block;

import crig;
import rig;
import gltf;
import collision;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::quaternion;
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

const float DEG @local = (float)math::PI / 180.0f;

fn Quaternionf about_z(float degrees) @local => quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), degrees * DEG);

// The signed angle of a rotation about z, in degrees.
fn float degrees_about_z(Quaternionf q) @local
{
	float angle = 2.0f * (float)math::atan2(q.v.z, q.v.w) / DEG;
	while (angle > 180.0f) angle -= 360.0f;
	while (angle <= -180.0f) angle += 360.0f;
	return angle;
}

<*
 The base box around a at the origin, a small pivot block around b two units
 up, and the arm box around c two units above that; the hub h, which skins
 nothing, sits between a and b and is the parent of both. c's box is what b
 swings; a's is what it meets. Joints in the skeleton's order: h, a, b, c.
*>
struct Pivot
{
	Vec3[24] positions;
	uint[108] indices;
	crig::AppState app;
	uint h;
	uint a;
	uint b;
	uint c;
}

fn bool Pivot.open(&self)
{
	corners(self.positions[0:8], { -0.5, -0.5, -0.5 }, { 0.5, 0.5, 0.5 });
	corners(self.positions[8:8], { -0.2, 1.8, -0.2 }, { 0.2, 2.2, 0.2 });
	corners(self.positions[16:8], { -0.5, 3.5, -0.5 }, { 0.5, 4.5, 0.5 });
	for (usz box = 0; box < 3; box++)
	{
		foreach (usz i, corner : BOX_FACES) self.indices[box * 36 + i] = corner + (uint)(box * 8);
	}
	rig::TriMesh mesh = { .positions = self.positions[..], .indices = self.indices[..] };
	self.app = crig::new_app(mesh);
	shared_app::attach_library(&self.app);

	self.h = self.app.doc.add_dot({ 0, 1, 0 }, "h");
	self.a = self.app.doc.add_dot({ 0, 0, 0 }, "a");
	self.b = self.app.doc.add_dot({ 0, 2, 0 }, "b");
	self.c = self.app.doc.add_dot({ 0, 4, 0 }, "c");
	self.app.doc.connect(self.h, self.a);
	self.app.doc.connect(self.h, self.b);
	self.app.doc.connect(self.b, self.c);
	self.app.doc.root_id = self.h;

	// Bound by hand rather than through the binder: each box rigid to its own
	// joint, in the skeleton's breadth-first order, which is the fact the
	// checks are about. The arrays are the app's to free with the binding.
	ushort[] joints = alloc::new_array(mem, ushort, 24);
	float[] weights = alloc::new_array(mem, float, 24);
	for (usz vertex = 0; vertex < 24; vertex++)
	{
		joints[vertex] = (ushort)(vertex / 8 + 1);
		weights[vertex] = 1.0f;
	}
	self.app.skin = { .joints = joints, .weights = weights, .slots = 1, .vertices = 24 };
	self.app.skin_joints = 4;
	// The system is off unless a user switches it on; these checks are about
	// what it does when it is.
	self.app.config.self_collision = true;
	self.app.deformed_surface = crig::build_deformed_collision_surface(&self.app.picker, self.app.skin, 4);
	int[4] parents = { -1, 0, 0, 2 };
	uint[4] dot_ids = { self.h, self.a, self.b, self.c };
	self.app.collision_policy = crig::build_collision_policy(
		&self.app.deformed_surface, parents[..], dot_ids[..], self.app.collision_clearance(), &self.app.doc);
	self.app.skin_stale = false;
	self.app.skin_generation = 1;
	if (!self.app.collision_policy.ready) return false;

	crig::AnimRef clip = self.app.new_clip("pose", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.0f;
	self.app.select(self.b);
	return true;
}

fn void Pivot.close(&self) => self.app.free();

fn float Pivot.turn_of(&self) => degrees_about_z(self.app.working_pose(self.b).rotation);

// What the clip being edited holds for b at the playhead, once a release has
// keyed the draft into it and parked it.
fn float Pivot.keyed_turn(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &view, *self.app.clip(self.app.editing),
		self.app.editing, self.app.edit_time, false);
	defer pose.free(mem);
	return degrees_about_z(pose.rotations[(usz)view.joint_of(self.b)]);
}

<*
 How close c's box comes to a's in the draft as it stands, measured straight
 off the skinned triangles rather than through the accelerator being checked.
*>
fn float Pivot.gap(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.app.draft_pose(mem, &view);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	Vec3[24] posed;
	rig::skin_positions(posed[..], self.positions[..], self.app.skin, palette)!!;

	float nearest = float::max;
	for (usz arm = 24; arm < 36; arm++)
	{
		for (usz base = 0; base < 12; base++)
		{
			collision::TriangleVerts one = {
				posed[self.indices[arm * 3]], posed[self.indices[arm * 3 + 1]], posed[self.indices[arm * 3 + 2]] };
			collision::TriangleVerts other = {
				posed[self.indices[base * 3]], posed[self.indices[base * 3 + 1]], posed[self.indices[base * 3 + 2]] };
			nearest = math::min(nearest, crig::triangle_distance(one, other));
		}
	}
	return nearest;
}

const Vec3 Z @local = { 0, 0, 1 };

fn void a_turn_stops_at_the_mesh_and_frees_itself_on_the_way_back() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	float clearance = app.collision_policy.clearance;
	test::@check(clearance > 0.0f && clearance < 0.1f, "clearance %.4f is not a small fraction of the mesh", clearance);

	test::@check(app.begin_turn(), "R did not begin");
	test::@check(app.pose_edit_active && app.drag.verb == TURN, "the turn did not open a pose draft");
	test::@check(!app.collision_suspended, "a clear start was read as in contact");
	test::@check(app.collision_blocking_active(), "blocking is not on with the system switched on");

	// A quarter turn swings the arm out to the side: nothing in the way.
	app.turn_joint(Z, 60.0f * DEG);
	test::@check(app.last_block.tested && !app.last_block.blocked, "a clear turn was blocked");
	test::@check(math::abs(fixture.turn_of() - 60.0f) < 0.01f, "a clear turn landed at %.2f, not 60", fixture.turn_of());
	test::@check(app.last_block.tests == 1, "a clear turn cost %d tests, not one", app.last_block.tests);
	test::@check(math::abs(app.last_block.fraction - 1.0f) < 1.0e-6f, "a clear turn reports fraction %.3f", app.last_block.fraction);

	// Asked for a half turn, the arm meets the base on the way and stops there.
	app.turn_joint(Z, 180.0f * DEG);
	float landed = fixture.turn_of();
	test::@check(app.last_block.blocked, "the arm went through the base");
	test::@check(landed > 60.0f && landed < 180.0f, "the arm stopped at %.2f", landed);
	test::@check(app.last_block.fraction > 0.0f && app.last_block.fraction < 1.0f,
		"a blocked turn reports fraction %.3f", app.last_block.fraction);
	float gap = fixture.gap();
	test::@check(gap > clearance && gap < clearance + 0.1f,
		"the arm sits %.4f from the base; the clearance is %.4f", gap, clearance);
	test::@check(app.last_block.contact.hit && app.last_block.contact.gap.distance <= clearance,
		"the blocking contact was not reported");
	uint region_a = app.deformed_surface.region_for_triangle(app.last_block.contact.pair.a);
	uint region_b = app.deformed_surface.region_for_triangle(app.last_block.contact.pair.b);
	test::@check((region_a == 1 && region_b == 3) || (region_a == 3 && region_b == 1),
		"the contact is between regions %d and %d, not the arm and the base", region_a, region_b);
	test::@check(app.last_block.tests > 1 && app.last_block.tests <= crig::COLLISION_SEARCH_STEPS + 2,
		"a blocked turn cost %d tests", app.last_block.tests);

	// The readout does not say so: the turn line reads the sweep the pointer
	// asked for and nothing about the stop — the joint standing where it does
	// is the whole announcement.
	crig::HudSnapshot shown = {
		.drag_dot = app.drag.dot,
		.drag_verb = TURN,
		.drag_turn = app.drag.turned,
	};
	char[512] scratch;
	crig::HudLine[crig::HUD_MAX_LINES] lines;
	usz count = crig::hud_lines(app, shown, scratch[..], lines[..]);
	bool turn_line;
	foreach (line : lines[:count])
	{
		if (line.text.contains("turn")) turn_line = true;
		test::@check(!line.text.contains("stopped") && !line.text.contains("mesh"),
			"the readout announces the stop: \"%s\"", line.text);
	}
	test::@check(turn_line, "the readout lost the turn line");

	// The pointer keeps going: the joint stays put, and learns so in two tests
	// rather than a whole search — the frame a hand pressed against the body
	// costs.
	app.turn_joint(Z, 200.0f * DEG);
	test::@check(app.last_block.blocked, "a deeper request was not blocked");
	test::@check(math::abs(fixture.turn_of() - landed) < 1.0f,
		"the joint crept from %.2f to %.2f while the sweep went on", landed, fixture.turn_of());
	test::@check(app.last_block.tests == 2 && app.last_block.fraction == 0.0f,
		"a pinned joint cost %d tests for fraction %.3f", app.last_block.tests, app.last_block.fraction);

	// A nudge of two degrees against the surface — a pointer's step between
	// two frames — is searched to the resolution, not to the depth: the
	// request, the smallest step, and three halvings at most.
	app.turn_joint(Z, (landed + 2.0f) * DEG);
	test::@check(app.last_block.blocked, "a nudge into the base was not blocked");
	test::@check(app.last_block.tests <= 5, "a two-degree nudge cost %d tests", app.last_block.tests);
	test::@check(fixture.gap() > clearance, "the nudge put the arm into the base");

	// And back out: the request is clear again and is taken as it is.
	app.turn_joint(Z, 60.0f * DEG);
	test::@check(!app.last_block.blocked, "sweeping back out was blocked");
	test::@check(math::abs(fixture.turn_of() - 60.0f) < 0.01f, "sweeping back landed at %.2f", fixture.turn_of());

	// Escape puts the start back, blocked or not.
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.cancel_drag(), "escape found no gesture");
	test::@check(math::abs(fixture.turn_of()) < 0.01f, "escape left the joint at %.2f", fixture.turn_of());
	test::@check(app.drag.dot == 0, "escape left the gesture open");
	test::@check(app.skin_generation == 1, "something rebound the skin under the checks");
}

fn void a_blocked_turn_banks_as_one_edit_and_a_blocked_gesture_ends_clean() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	sz history = app.undo_stack.cursor;
	test::@check(app.begin_turn(), "R did not begin");
	app.turn_joint(Z, 180.0f * DEG);
	float landed = fixture.turn_of();
	test::@check(app.last_block.blocked && landed < 180.0f, "the arm was not stopped");
	app.end_drag();
	test::@check(app.drag.dot == 0, "the release left the gesture open");
	test::eq(app.undo_stack.cursor, history + 1);
	// Auto-key is on, so the release keyed the draft into the clip and parked
	// it: what the clip holds is where the arm stopped, not where the pointer was.
	test::@check(!app.pose_edit_active, "the release did not key the pose");
	test::@check(math::abs(fixture.keyed_turn() - landed) < 0.05f, "the clip keyed %.2f, not the %.2f the arm stopped at",
		fixture.keyed_turn(), landed);
	// The next gesture begins from the keyed pose — the arm just clear of the
	// base, to within the rounding a key and its sample cost — and is checked:
	// a start at the surface is not a start in contact, and pushing on stays
	// stopped rather than passing through.
	test::@check(app.begin_turn(), "R did not begin from where the arm stopped");
	test::@check(!app.collision_suspended, "a gesture beginning where the last block left the arm was left unchecked");
	app.turn_joint(Z, (180.0f - landed) * DEG);
	test::@check(app.last_block.blocked && app.last_block.fraction < 0.05f,
		"pushing on from the surface went %.0f%% of the way into the base", app.last_block.fraction * 100.0f);
	test::@check(fixture.gap() > app.collision_policy.clearance * crig::COLLISION_SUSPEND_FRACTION,
		"the arm is inside the clearance");
	test::@check(app.cancel_drag(), "escape found no gesture");
	test::@check(math::abs(fixture.turn_of() - landed) < 0.05f, "escape left the arm at %.2f, not %.2f", fixture.turn_of(), landed);

	test::@check(app.undo(), "the blocked turn would not undo");
	test::@check(app.undo_stack.cursor == history, "one undo did not take the whole gesture back");
	test::@check(math::abs(fixture.keyed_turn()) < 0.01f, "undo left the clip at %.2f", fixture.keyed_turn());

	// A gesture that ends where it began records nothing, blocked or not: the
	// request went through the base and came back.
	test::@check(app.begin_turn(), "R did not begin again");
	app.turn_joint(Z, 180.0f * DEG);
	app.turn_joint(Z, 0.0f);
	app.end_drag();
	test::@check(app.undo_stack.cursor == history, "a gesture that came back to its start recorded an edit");
}

fn void a_gesture_that_begins_in_contact_is_not_blocked_and_neither_is_one_with_blocking_off() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	// Drive the arm into the base with blocking off, as a clip or a scrub could.
	app.set_prevent_intersections(false);
	test::@check(app.begin_turn(), "R did not begin");
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(!app.last_block.tested, "a turn with blocking off was tested");
	test::@check(math::abs(fixture.turn_of() - 180.0f) < 0.01f, "with blocking off the arm stopped at %.2f", fixture.turn_of());
	app.end_drag();
	test::@check(math::abs(fixture.keyed_turn() - 180.0f) < 0.05f, "the clip did not key the arm inside the base");

	// With blocking on again, a gesture from inside the base moves freely: the
	// user is on the way out, and there is no clear fraction to stop at.
	app.set_prevent_intersections(true);
	test::@check(app.begin_turn(), "R did not begin from inside the base");
	test::@check(fixture.gap() < app.collision_policy.clearance, "the arm is not in the base");
	test::@check(app.collision_suspended, "a start in contact was not noticed");
	test::@check(app.last_block.contact.hit, "the contact the gesture began in was not reported");
	// The sweep is measured from where the gesture began, at 180.
	app.turn_joint(Z, -10.0f * DEG);
	test::@check(!app.last_block.tested && !app.last_block.blocked, "a suspended gesture was blocked");
	test::@check(math::abs(fixture.turn_of() - 170.0f) < 0.01f, "a suspended gesture landed at %.2f", fixture.turn_of());
	app.turn_joint(Z, -120.0f * DEG);
	test::@check(math::abs(fixture.turn_of() - 60.0f) < 0.01f, "the way out landed at %.2f", fixture.turn_of());
	app.end_drag();

	// Out again, the next gesture is checked as usual: a sweep of 120 from 60
	// is the half turn that meets the base.
	test::@check(app.begin_turn(), "R did not begin once clear");
	test::@check(!app.collision_suspended, "a clear start is still suspended");
	app.turn_joint(Z, 120.0f * DEG);
	test::@check(app.last_block.blocked, "blocking did not resume once clear");
	test::@check(fixture.turn_of() > 60.0f && fixture.turn_of() < 180.0f, "the arm stopped at %.2f", fixture.turn_of());
	app.cancel_drag();
}

fn void a_number_typed_into_the_joint_card_lands_where_the_mesh_stops_it() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.prepare_animation_pose(), "the draft did not open");

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits limits = app.doc.rotation_limits_of(fixture.b);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, limits);

	Quaternionf clear = app.numeric_joint_rotation(&view, fixture.b, about_z(60.0f), frame, limits);
	test::@check(!app.last_block.blocked && math::abs(degrees_about_z(clear) - 60.0f) < 0.01f,
		"a clear number landed at %.2f", degrees_about_z(clear));

	Quaternionf stopped = app.numeric_joint_rotation(&view, fixture.b, about_z(150.0f), frame, limits);
	float landed = degrees_about_z(stopped);
	test::@check(app.last_block.blocked, "a number through the base was not blocked");
	test::@check(landed > 60.0f && landed < 150.0f, "the number landed at %.2f", landed);
	test::@check(app.set_working_pose(fixture.b, stopped, {}), "the landed rotation could not be written");
	float gap = fixture.gap();
	test::@check(gap > app.collision_policy.clearance && gap < app.collision_policy.clearance + 0.1f,
		"the arm sits %.4f from the base after the numeric entry", gap);

	// Limits still come first: a number the limits refuse never reaches the mesh.
	crig::JointRotationLimits tight = crig::unconstrained_rotation(fixture.b);
	tight.constrained = true;
	tight.axes[2] = { .allowed = true, .minimum = -0.5f, .maximum = 0.5f };
	test::@check(app.doc.set_rotation_limits(fixture.b, tight), "the limit was refused");
	crig::JointRotationLimits held = app.doc.rotation_limits_of(fixture.b);
	crig::JointLimitFrame limited = crig::joint_limit_frame(&view.skeleton, view.dot_ids, held);
	Quaternionf request = crig::constrain_joint_rotation(limited, held, about_z(150.0f));
	Quaternionf within = app.numeric_joint_rotation(&view, fixture.b, request, limited, held);
	test::@check(!app.last_block.blocked, "a request the limits already cut short was blocked by the mesh");
	test::@check(math::abs(degrees_about_z(within) - degrees_about_z(request)) < 0.01f,
		"a limited request landed at %.2f, not the limit", degrees_about_z(within));
}

fn void the_subtree_is_the_joint_and_everything_below_it() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::RigView view = fixture.app.open_rig(mem)!!;
	defer view.free(mem);

	uint[] whole = crig::subtree_joints(mem, &view.skeleton, 0);
	defer alloc::free(mem, whole);
	test::eq((usz)whole.len, (usz)4);
	uint[] lower = crig::subtree_joints(mem, &view.skeleton, 2);
	defer alloc::free(mem, lower);
	test::@check(lower.len == 2 && lower[0] == 2 && lower[1] == 3, "b's subtree is not b and c");
	uint[] base = crig::subtree_joints(mem, &view.skeleton, 1);
	defer alloc::free(mem, base);
	test::@check(base.len == 1 && base[0] == 1, "a's subtree is not a alone");
	uint[] leaf = crig::subtree_joints(mem, &view.skeleton, 3);
	defer alloc::free(mem, leaf);
	test::@check(leaf.len == 1 && leaf[0] == 3, "a leaf's subtree is not itself alone");
	uint[] none = crig::subtree_joints(mem, &view.skeleton, 9);
	test::eq((usz)none.len, (usz)0);
}

fn void the_plane_test_only_ever_clears_pairs_the_exact_distance_would() @test
{
	collision::TriangleVerts floor = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 0, 1 } };
	// Parallel and above by 0.3: apart by any clearance under that.
	collision::TriangleVerts above = { { 0, 0.3f, 0 }, { 1, 0.3f, 0 }, { 0, 0.3f, 1 } };
	test::@check(crig::triangles_apart_by_plane(floor, above, 0.1f), "a triangle 0.3 above the plane was not read as apart");
	test::@check(!crig::triangles_apart_by_plane(floor, above, 0.3f), "a triangle exactly a clearance away was read as apart");
	test::@check(!crig::triangles_apart_by_plane(floor, above, 0.5f), "a triangle within the clearance was read as apart");
	// Tilted through the floor's plane: nothing the planes can say, and the
	// exact distance agrees the two touch.
	collision::TriangleVerts through = { { 0.2f, -0.1f, 0.2f }, { 0.4f, 0.4f, 0.2f }, { 0.2f, 0.4f, 0.4f } };
	test::@check(!crig::triangles_apart_by_plane(floor, through, 0.05f), "a triangle crossing the plane was read as apart");
	test::@check(crig::triangle_distance(floor, through) == 0.0f, "the crossing pair is not at distance zero");
	// Either plane may decide, whichever side it is passed on.
	collision::TriangleVerts tilted = { { 2, 0.5f, 0 }, { 3, 0.5f, 0 }, { 2, 0.5f, 1 } };
	test::@check(crig::triangles_apart_by_plane(floor, tilted, 0.2f) && crig::triangles_apart_by_plane(tilted, floor, 0.2f),
		"a parallel triangle half a unit up was not read as apart");
	// A degenerate triangle has no plane and decides nothing; the other's
	// plane still can, and two of them cannot.
	collision::TriangleVerts line = { { 0, 1, 0 }, { 1, 1, 0 }, { 2, 1, 0 } };
	collision::TriangleVerts other_line = { { 0, 2, 0 }, { 1, 2, 0 }, { 2, 2, 0 } };
	test::@check(crig::triangles_apart_by_plane(line, floor, 0.1f), "the floor's plane did not decide against a degenerate triangle");
	test::@check(!crig::triangles_apart_by_plane(line, other_line, 0.1f), "two degenerate triangles were read as apart");
}

fn void a_turn_of_the_root_moves_the_whole_skin_and_is_not_tested() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	// Everything turns with h: no two triangles change their distance, so
	// there is nothing to refit and nothing to measure, and the request is
	// taken whole.
	app.select(fixture.h);
	test::@check(app.begin_turn(), "R did not begin on the root");
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.last_block.tested && !app.last_block.blocked, "a turn of the root was blocked");
	test::@check(app.last_block.tests == 0, "a turn of the root cost %d tests", app.last_block.tests);
	float turned = degrees_about_z(app.working_pose(fixture.h).rotation);
	test::@check(math::abs(math::abs(turned) - 180.0f) < 0.01f, "the root landed at %.2f, not 180", turned);
	app.cancel_drag();
}

// ---------------------------------------------------------------------------
// C4: a pull stops at the mesh too

fn Vec3 Pivot.tip(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.app.draft_pose(mem, &view);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	sz j = view.joint_of(self.c);
	float[<4>] moved = palette[(usz)j].apply({ 0, 4, 0, 1 });
	return { moved.x, moved.y, moved.z };
}

fn void a_pull_stops_at_the_mesh_reports_what_it_lacks_and_reaches_around() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	app.select(fixture.c);
	float clearance = app.collision_policy.clearance;

	test::@check(app.begin_pose(), "G did not begin");
	test::@check(app.drag.verb == POSE && !app.collision_suspended, "the pull did not open clear");

	// Out to the side: nothing in the way, and the tip arrives. One test is
	// the whole price — the solve is checked once, not every pass of it.
	float gap = app.pose_toward({ 2, 2, 0 });
	test::@check(app.last_block.tested && !app.last_block.blocked, "a clear pull was blocked");
	test::@check(!app.last_block.unreached && gap < 0.05f, "a reachable target was left %.3f away", gap);
	test::@check((fixture.tip() - (Vec3){ 2, 2, 0 }).length() < 0.05f, "the tip did not arrive");
	test::@check(app.last_block.tests == 1, "a clear pull cost %d tests, not one", app.last_block.tests);

	// Down through the base: the arm stops on it, and the readout knows why
	// and by how much. The stop is searched to the depth, so the arm sits
	// within a fraction of a degree of the surface, not somewhere short of
	// it that the first blocked halving happened to leave.
	gap = app.pose_toward({ 0, -1, 0 });
	test::@check(app.last_block.blocked, "the arm went through the base");
	test::@check(app.last_block.unreached && app.last_block.residual > clearance,
		"a blocked pull reports residual %.3f, unreached %s", app.last_block.residual, app.last_block.unreached);
	test::@check(math::abs(app.last_block.residual - gap) < 1.0e-6f, "the residual is not the gap the solve returned");
	float held = fixture.gap();
	test::@check(held > clearance && held < clearance + 0.05f,
		"the arm sits %.4f from the base; the clearance is %.4f", held, clearance);
	test::@check(app.last_block.contact.hit, "the blocking contact was not reported");
	uint region_a = app.deformed_surface.region_for_triangle(app.last_block.contact.pair.a);
	uint region_b = app.deformed_surface.region_for_triangle(app.last_block.contact.pair.b);
	test::@check((region_a == 1 && region_b == 3) || (region_a == 3 && region_b == 1),
		"the contact is between regions %d and %d", region_a, region_b);
	test::@check(app.last_block.tests <= crig::COLLISION_SEARCH_STEPS + 2 + crig::IK_MAX_CHAIN,
		"a blocked pull cost %d tests", app.last_block.tests);

	// The readout keeps quiet about it: the move line is the move, and the
	// residual stays in the report for the dialog and the tools.
	crig::HudSnapshot shown = {
		.drag_dot = app.drag.dot,
		.drag_verb = POSE,
	};
	char[512] scratch;
	crig::HudLine[crig::HUD_MAX_LINES] lines;
	usz count = crig::hud_lines(app, shown, scratch[..], lines[..]);
	foreach (line : lines[:count])
	{
		test::@check(!line.text.contains("short by") && !line.text.contains("stopped"),
			"the readout announces the stop: \"%s\"", line.text);
	}

	// Pulling into the base itself may slide the arm along it — the careful
	// pass lets the pivots whose arcs stay clear move — but never through it,
	// and a target inside the base is never reached.
	app.pose_toward({ 0, 0, 0 });
	test::@check(app.last_block.blocked && app.last_block.unreached, "a pull into the base reads as reached");
	test::@check(fixture.gap() > clearance, "pulling harder drove the arm into the base");
	gap = app.pose_toward({ 2, 2, 0 });
	test::@check(!app.last_block.unreached && gap < 0.05f, "pulling back out to the side left the tip %.3f short", gap);
	test::@check(fixture.gap() > clearance, "the arm came out through the base");

	// Escape puts the start back.
	app.pose_toward({ 0, -1, 0 });
	test::@check(app.cancel_drag(), "escape found no gesture");
	test::@check((fixture.tip() - (Vec3){ 0, 4, 0 }).length() < 1.0e-4f, "escape left the tip at %s", fixture.tip());
	test::@check(app.skin_generation == 1, "something rebound the skin under the checks");
}

fn void a_pull_that_begins_in_contact_or_with_blocking_off_is_left_alone() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	app.select(fixture.c);
	sz history = app.undo_stack.cursor;

	app.set_prevent_intersections(false);
	test::@check(app.begin_pose(), "G did not begin");
	float gap = app.pose_toward({ 0, 0, 0 });
	test::@check(!app.last_block.tested && !app.last_block.blocked, "a pull with blocking off was tested");
	test::@check(gap < 0.05f, "with blocking off the tip was left %.3f from a reachable target", gap);
	app.end_drag();
	test::eq(app.undo_stack.cursor, history + 1);

	// From inside the base, the next pull is free to leave.
	app.set_prevent_intersections(true);
	test::@check(app.begin_pose(), "G did not begin from inside the base");
	test::@check(app.collision_suspended, "a start in contact was not noticed");
	gap = app.pose_toward({ 2, 2, 0 });
	test::@check(!app.last_block.tested && gap < 0.05f, "a suspended pull was held back: %.3f", gap);
	app.end_drag();
	test::eq(app.undo_stack.cursor, history + 2);

	// A pull that ends where it began records nothing.
	test::@check(app.begin_pose(), "G did not begin again");
	Vec3 start = fixture.tip();
	app.pose_toward({ 0, -1, 0 });
	app.pose_toward(start);
	app.end_drag();
	test::@check(app.undo_stack.cursor == history + 2 || (fixture.tip() - start).length() > 1.0e-3f,
		"a pull back to its start recorded an edit");
}

// ---------------------------------------------------------------------------
// C5: a mesh that cannot keep up says so

fn void a_check_over_budget_is_reduced_then_paused_and_says_so() @test
{
	Pivot fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	// Measured at the default budget: a blocked turn on three boxes is far
	// inside it, so the mode stands.
	test::@check(app.begin_turn(), "R did not begin");
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.last_block.blocked && app.collision_mode == FULL, "a cheap blocked turn changed the mode");
	float cost = app.last_block.seconds;
	usz tests = app.last_block.tests;
	test::@check(cost > 0.0f && tests > 1, "the write was not timed: %.6f s over %d tests", cost, tests);
	test::@check(app.last_block.mode == FULL, "the report does not carry the mode it ran under");
	app.cancel_drag();

	// A budget below the write but above one test: the next blocked write is
	// judged over it, and the one after runs reduced — fewer halvings, and the
	// modes line and the status say so.
	app.collision_budget = cost * 0.5f;
	test::@check(app.begin_turn(), "R did not begin again");
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.collision_mode == REDUCED, "a write over budget did not reduce the check (%.4f s against %.4f)",
		app.last_block.seconds, app.collision_budget);
	test::@check(app.notice().contains("reduced"), "reducing the check was not said: %s", app.notice());
	app.turn_joint(Z, 60.0f * DEG);
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.last_block.blocked && app.last_block.mode == REDUCED, "the reduced write does not report its mode");
	test::@check(app.last_block.tests <= crig::COLLISION_SEARCH_STEPS_REDUCED + 2,
		"a reduced write still cost %d tests", app.last_block.tests);
	test::@check(fixture.gap() > app.collision_policy.clearance, "the reduced check let the arm into the base");
	app.cancel_drag();

	// A budget no single test can meet pauses the check: nothing is blocked,
	// the arm goes through, and every surface says so rather than staying quiet.
	app.collision_budget = 1.0e-9f;
	test::@check(app.begin_turn(), "R did not begin a third time");
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.collision_mode == PAUSED, "a test over budget did not pause the check");
	test::@check(app.notice().contains("paused"), "pausing the check was not said: %s", app.notice());
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(!app.last_block.tested && !app.collision_blocking_active(), "a paused check still tested");
	test::@check(math::abs(fixture.turn_of() - 180.0f) < 0.01f, "a paused check still blocked: %.2f", fixture.turn_of());
	String status = crig::collision_status_text(app);
	defer status.free(mem);
	test::@check(status.starts_with("Live blocking paused"), "the status does not say paused: %s", status);
	app.cancel_drag();

	// Toggling the control is the retry.
	app.set_prevent_intersections(false);
	app.set_prevent_intersections(true);
	test::@check(app.collision_mode == FULL, "toggling the control did not retry the check");
	app.collision_budget = 0.0f;
	test::@check(app.begin_turn(), "R did not begin after the retry");
	app.turn_joint(Z, 180.0f * DEG);
	test::@check(app.last_block.blocked && app.collision_mode == FULL, "the check did not come back in full");
	app.cancel_drag();
}

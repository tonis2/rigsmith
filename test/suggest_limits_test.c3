<*
 Suggest limits on rigs with no body plan: a joint bent at rest is a hinge that
 folds the way it bends, a limb's base a cone, matching legs match, the mesh
 stops a fold, a clip widens a row, and tables already set are left alone.
*>
module crig_tests::suggest_limits;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

const float DEG @local = (float)math::PI / 180.0f;

// A bent leg off a body: body → coxa → femur → tibia → tarsus → tip.
struct Leg
{
	uint body;
	uint coxa;
	uint femur;
	uint tibia;
	uint tarsus;
	uint tip;
}

fn Leg add_leg(crig::AppState* app, uint body, float turn, float femur_lift = 0.5f, bool named = false) @local
{
	Vec3 along = { (float)math::cos(turn), 0, (float)math::sin(turn) };
	Vec3 up = { 0, 1, 0 };
	Vec3 hip = { 0, 2, 0 };
	Leg leg = { .body = body };
	leg.coxa = app.doc.add_dot(hip + along * 0.5f, named ? "coxa" : "");
	leg.femur = app.doc.add_dot(hip + along * 1.0f + up * femur_lift, named ? "femur" : "");
	leg.tibia = app.doc.add_dot(hip + along * 1.5f, named ? "tibia" : "");
	leg.tarsus = app.doc.add_dot(hip + along * 1.8f - up * 1.0f, named ? "tarsus" : "");
	leg.tip = app.doc.add_dot(hip + along * 1.9f - up * 1.5f, named ? "tip" : "");
	app.doc.connect(body, leg.coxa);
	app.doc.connect(leg.coxa, leg.femur);
	app.doc.connect(leg.femur, leg.tibia);
	app.doc.connect(leg.tibia, leg.tarsus);
	app.doc.connect(leg.tarsus, leg.tip);
	return leg;
}

fn Vec3 at(crig::AppState* app, uint id) @local => app.doc.find(id).position;

// The angle between where `turned` points after `rotation` and the bone into the joint.
fn float bend_after(Vec3 into, Vec3 out, Quaternionf rotation) @local
{
	Vec3 bone = rotation.rotate_vec3(out).normalize();
	return (float)math::acos(math::clamp(into.normalize().dot(bone), -1.0f, 1.0f));
}

<*
 A joint bent at rest is a hinge that folds further the way it bends and stops
 short of folding back past straight; the joint where the leg meets the body is
 a cone.

 Re-introduce: read the fold axis the other way round in `read_limit_shapes`, and
 the fold is refused.
*>
fn void a_bent_joint_folds_the_way_it_bends() @test
{
	io::printn("a bent joint folds the way it bends");
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint body = app.doc.add_dot({ 0, 2, 0 }, "body");
	Leg leg = add_leg(&app, body, 0.0f);
	app.doc.root_id = body;

	crig::LimitSuggestion done = app.suggest_limits();
	test::@check(done.written >= 4, "only %d joints took a limit", done.written);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits tibia = app.doc.rotation_limits_of(leg.tibia);
	test::@check(tibia.constrained && tibia.has_saved_frame, "the tibia is not a hinge");
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, tibia);
	test::@check(frame.usable(), "the tibia's frame is not usable");

	Vec3 into = at(&app, leg.tibia) - at(&app, leg.femur);
	Vec3 out = at(&app, leg.tarsus) - at(&app, leg.tibia);
	Vec3 fold = into.cross(out).normalize();
	float bend = bend_after(into, out, quaternion::IDENTITY);

	Quaternionf further = quaternion::from_axis_angle{float}(fold, 40.0f * DEG);
	test::@check(bend_after(into, out, further) > bend, "the fold axis opens the joint");
	Quaternionf kept = crig::constrain_joint_rotation(frame, tibia, further);
	test::@check(1.0f - math::abs(kept.v.dot(further.v)) < 1.0e-5f, "folding 40 degrees further was refused");

	Quaternionf back = quaternion::from_axis_angle{float}(fold, -(bend + 40.0f * DEG));
	Quaternionf held = crig::constrain_joint_rotation(frame, tibia, back);
	test::@check(bend_after(into, out, held) < bend_after(into, out, back),
		"folding back past straight was allowed");

	crig::JointRotationLimits coxa = app.doc.rotation_limits_of(leg.coxa);
	test::@check(coxa.constrained && !coxa.has_saved_frame, "the coxa is not a cone");
	test::@check(coxa.axes[0].minimum == -coxa.axes[0].maximum, "the coxa's cone is not even");
	test::@check(!app.doc.rotation_limits_of(body).constrained, "the root took a limit");
}

<*
 Eight legs, one with a longer femur: every femur takes the same table.

 Re-introduce: drop `share_in_groups`, and the odd leg's femur opens further.
*>
fn void matching_legs_take_the_same_limits() @test
{
	io::printn("matching legs take the same limits");
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint body = app.doc.add_dot({ 0, 2, 0 }, "body");
	Leg[8] legs;
	foreach (usz i, &leg : legs) *leg = add_leg(&app, body, (float)i * 45.0f * DEG, i == 3 ? 0.9f : 0.5f);
	app.doc.root_id = body;

	(void)app.suggest_limits();
	crig::JointRotationLimits first = app.doc.rotation_limits_of(legs[0].femur);
	test::@check(first.constrained, "the femur took no limit");
	foreach (leg : legs[1..])
	{
		crig::JointRotationLimits other = app.doc.rotation_limits_of(leg.femur);
		for (usz a = 0; a < 3; a++)
		{
			test::@check(math::abs(other.axes[a].minimum - first.axes[a].minimum) < 1.0e-5f
				&& math::abs(other.axes[a].maximum - first.axes[a].maximum) < 1.0e-5f,
				"femur axis %d differs: %f..%f against %f..%f", a,
				other.axes[a].minimum, other.axes[a].maximum, first.axes[a].minimum, first.axes[a].maximum);
		}
	}
}

<*
 The menu leaves a table already set alone; the card's Suggest overwrites it,
 as one undo step that undo takes back.
*>
fn void a_set_table_is_kept_unless_named() @test
{
	io::printn("a set table is kept unless named");
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint body = app.doc.add_dot({ 0, 2, 0 }, "body");
	Leg leg = add_leg(&app, body, 0.0f);
	app.doc.root_id = body;

	crig::JointRotationLimits mine = crig::unconstrained_rotation(leg.tibia);
	mine.constrained = true;
	mine.axes[0] = { .allowed = true, .minimum = -0.1f, .maximum = 0.2f };
	test::@check(app.doc.set_rotation_limits(leg.tibia, mine), "the hand table was refused");

	(void)app.suggest_limits();
	test::@check(app.doc.rotation_limits_of(leg.tibia).same(mine), "the menu overwrote a hand table");
	test::@check(app.doc.rotation_limits_of(leg.femur).constrained, "the menu skipped an empty joint");

	sz before = app.undo_stack.edits.len();
	crig::LimitSuggestion done = app.suggest_limits(only: { leg.tibia });
	test::eq(done.written, (usz)1);
	test::eq(app.undo_stack.edits.len(), before + 1);
	test::@check(!app.doc.rotation_limits_of(leg.tibia).same(mine), "naming the joint did not overwrite it");
	(void)app.undo();
	test::@check(app.doc.rotation_limits_of(leg.tibia).same(mine), "undo did not bring the hand table back");
}

// Four cubes along a segment, rigid to `joint`.
fn void add_cubes(Vec3[] positions, uint[] indices, ushort[] joints, usz first, Vec3 start, Vec3 step, ushort joint) @local
{
	const uint[36] FACES = {
		4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1, 1, 2, 6, 1, 6, 5,
		0, 4, 7, 0, 7, 3, 3, 7, 6, 3, 6, 2, 0, 1, 5, 0, 5, 4,
	};
	for (usz c = 0; c < 4; c++)
	{
		usz cube = first + c;
		Vec3 centre = start + step * ((float)c + 0.5f);
		Vec3 low = centre - (Vec3){ 0.2f, 0.2f, 0.2f };
		Vec3 high = centre + (Vec3){ 0.2f, 0.2f, 0.2f };
		Vec3[] p = positions[cube * 8 : 8];
		p[0] = { low.x, low.y, low.z };
		p[1] = { high.x, low.y, low.z };
		p[2] = { high.x, high.y, low.z };
		p[3] = { low.x, high.y, low.z };
		p[4] = { low.x, low.y, high.z };
		p[5] = { high.x, low.y, high.z };
		p[6] = { high.x, high.y, high.z };
		p[7] = { low.x, high.y, high.z };
		foreach (usz i, corner : FACES) indices[cube * 36 + i] = corner + (uint)(cube * 8);
		for (usz v = 0; v < 8; v++) joints[cube * 8 + v] = joint;
	}
}

<*
 An upper segment of cubes standing up from a, and a lower one bent out
 sideways from b: folding b further swings its cubes down onto a's, and the
 suggested fold stops short of where they meet.

 Re-introduce: skip `sweep_limits`, and b keeps the full default fold.
*>
fn void the_mesh_stops_a_fold() @test
{
	io::printn("the mesh stops a fold");
	Vec3[64] positions;
	uint[288] indices;
	ushort[] joints = alloc::new_array(mem, ushort, 64);
	float[] weights = alloc::new_array(mem, float, 64);
	weights[..] = 1.0f;
	add_cubes(positions[..], indices[..], joints, 0, { 0, 0, 0 }, { 0, 0.5f, 0 }, 1);
	add_cubes(positions[..], indices[..], joints, 4, { 0, 2, 0 }, { 0.5f, 0, 0 }, 2);

	rig::TriMesh mesh = { .positions = positions[..], .indices = indices[..] };
	crig::AppState app = crig::new_app(mesh);
	defer app.free();
	shared_app::attach_library(&app);
	uint h = app.doc.add_dot({ 0, -1, 0 }, "h");
	uint a = app.doc.add_dot({ 0, 0, 0 }, "a");
	uint b = app.doc.add_dot({ 0, 2, 0 }, "b");
	uint c = app.doc.add_dot({ 2, 2, 0 }, "c");
	app.doc.connect(h, a);
	app.doc.connect(a, b);
	app.doc.connect(b, c);
	app.doc.root_id = h;
	app.skin = { .joints = joints, .weights = weights, .slots = 1, .vertices = 64 };
	app.skin_joints = 4;
	app.deformed_surface = crig::build_deformed_collision_surface(&app.picker, app.skin, 4);
	app.skin_stale = false;
	app.skin_generation = 1;

	crig::LimitSuggestion done = app.suggest_limits(only: { b });
	test::eq(done.written, (usz)1);
	test::eq(done.from_mesh, (usz)1);
	crig::JointRotationLimits hinge = app.doc.rotation_limits_of(b);
	test::@check(hinge.has_saved_frame, "b is not a hinge");
	float fold = hinge.axes[0].maximum / DEG;
	test::@check(fold > 30.0f && fold < 110.0f, "b folds %f degrees, not stopped by a's cubes", fold);
}

<*
 A bound clip that turns a joint past its suggestion widens that row to cover
 the clip, and a little more.
*>
fn void a_clip_widens_a_row() @test
{
	io::printn("a clip widens a row");
	crig::AppState app = crig::new_app({});
	defer app.free();
	shared_app::attach_library(&app);
	uint body = app.doc.add_dot({ 0, 2, 0 }, "body");
	Leg leg = add_leg(&app, body, 0.0f, named: true);
	app.doc.root_id = body;

	// A twist of the tarsus well past the 30 degrees a straight joint is given.
	crig::AnimRef clip = app.new_clip("twist", 1.0f, from_rest: true);
	test::@check(clip.valid(), "no clip");
	app.editing = clip;
	test::@check(app.pose_from_clip(clip, 0.5f), "no pose at 0.5");
	Vec3 bone = (at(&app, leg.tip) - at(&app, leg.tarsus)).normalize();
	test::@check(app.set_working_pose(leg.tarsus, quaternion::from_axis_angle{float}(bone, 70.0f * DEG), {}), "no draft");
	app.pose_edit_pending = true;
	test::@check(app.key_pose_edit(), "the twist was not keyed");
	app.stop_animation();
	test::@check(app.resolve_bound(0).valid(), "the clip is not bound to the rig");

	crig::LimitSuggestion done = app.suggest_limits();
	test::@check(done.from_clips >= 1, "no row was widened");
	crig::JointRotationLimits tarsus = app.doc.rotation_limits_of(leg.tarsus);
	test::@check(tarsus.axes[1].maximum >= 70.0f * DEG, "the twist row reaches %f degrees", tarsus.axes[1].maximum / DEG);
}

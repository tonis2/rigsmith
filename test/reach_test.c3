<*
 The reach rule: what a dot with no stated reach is given when the rig binds.

 **A mixed rig has no unlimited dots.** Once any dot is limited, one that is not
 gets `default_reach` rather than zero, because `reach_bias` scores an unlimited
 bone 1 at every distance and a few unsized dots on a mostly-sized rig outrank
 everything everywhere. `reach_joints` is where that rule lives; these checks are
 over it.
*>
module crig_tests::reach;

import crig;
import rig;
import std::math;

// Declared as `Vec3` rather than as floats cast to it. `Vec3` is `float[<3>]`
// — a vector type — and casting a `float[]` to `Vec3*` is a bus error on the
// first read: the size is 12 but the alignment a vector load wants is not the
// one a float array is given.
Vec3[8] box_positions @local = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 },  { 1, -1, 1 },  { 1, 1, 1 },  { -1, 1, 1 },
};
uint[36] box_indices @local = {
	0, 1, 2,  0, 2, 3,  4, 6, 5,  4, 7, 6,
	0, 4, 5,  0, 5, 1,  3, 2, 6,  3, 6, 7,
	0, 3, 7,  0, 7, 4,  1, 5, 6,  1, 6, 2,
};

fn rig::TriMesh box() => { .positions = box_positions[..], .indices = box_indices[..] };

<*
 One dot limited sizes every other one with `default_reach`.

 `loose` is unconnected on purpose: it is the only dot that reaches the
 bounding-box fallback.
*>
fn void a_mixed_rig_sizes_every_dot() @test
{
	crig::AppState app = crig::new_app(box());
	defer app.free();

	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = app.doc.add_dot({ 0, 0, 0 }, "foot");
	app.doc.connect(hips, knee);
	app.doc.connect(knee, foot);
	app.doc.add_dot({ 0.5, 0.25, 0 }, "loose");

	app.doc.set_reach(knee, 0.4f);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);

	assert(view.reaches.len == view.len(), "reach_joints answered %d for %d joints", view.reaches.len, view.len());
	foreach (usz j, id : view.dot_ids)
	{
		float want = id == knee ? 0.4f : app.default_reach(id);
		assert(want > 0.0f, "joint %d (%s) has no default to compare", j, view.names[j]);
		assert(math::abs(view.reaches[j] - want) < 1.0e-5f,
			"joint %d (%s): reach_joints says %f, default_reach %f", j, view.names[j], view.reaches[j], want);
	}
}

<*
 With no dot limited, the rule is off: `reach_joints` answers an empty array,
 which `bind_geodesic` reads as "unlimited from here on".
*>
fn void an_unlimited_rig_stays_unlimited() @test
{
	crig::AppState app = crig::new_app(box());
	defer app.free();

	uint hips = app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	app.doc.connect(hips, knee);

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	assert(view.reaches.len == 0, "reach_joints sized an unlimited rig");
}

<*
 `default_reach` comes from the joint's own bone — the segment to its primary
 child — and not from the longest bone touching it. A hips joint with a short
 spine above and long thighs below is sized from the spine.
*>
fn void a_default_reach_follows_the_joints_own_bone() @test
{
	crig::AppState app = crig::new_app(box());
	defer app.free();

	uint hips = app.doc.add_dot({ 0, 0.5, 0 }, "hips");
	uint spine = app.doc.add_dot({ 0, 0.6, 0 }, "spine");
	uint thigh = app.doc.add_dot({ 0.1, 0.4, 0 }, "thigh");
	uint knee = app.doc.add_dot({ 0.1, -0.4, 0 }, "knee");
	uint foot = app.doc.add_dot({ 0.1, -0.9, 0.3 }, "foot");
	uint toe = app.doc.add_dot({ 0.1, -0.95, 0.2 }, "toe");
	app.doc.connect(hips, spine);
	app.doc.connect(hips, thigh);
	app.doc.connect(thigh, knee);
	app.doc.connect(knee, foot);
	app.doc.connect(foot, toe);
	assert(app.doc.root_id == hips, "the first dot is not the root");

	// The root: nothing arrives, so the shortest child bone — the spine's 0.1,
	// where the old rule took the thigh's.
	float hips_reach = app.default_reach(hips);
	assert(math::abs(hips_reach - 0.1f * 1.5f) < 1.0e-4f, "hips reach %f is not from its own bone", hips_reach);

	// A chain joint: the bone to its child.
	float knee_reach = app.default_reach(knee);
	float shin = ((Vec3){ 0.1, -0.9, 0.3 } - (Vec3){ 0.1, -0.4, 0 }).length();
	assert(math::abs(knee_reach - shin * 1.5f) < 1.0e-4f, "knee reach %f is not the shin's", knee_reach);

	// A leaf: the bone arriving at it.
	float toe_reach = app.default_reach(toe);
	float tip = ((Vec3){ 0.1, -0.95, 0.2 } - (Vec3){ 0.1, -0.9, 0.3 }).length();
	assert(math::abs(toe_reach - tip * 1.5f) < 1.0e-4f, "toe reach %f is not its own bone's", toe_reach);

	// A primary child named in the limits wins over the rule.
	crig::JointRotationLimits limits = crig::unconstrained_rotation(hips);
	limits.primary_child = thigh;
	assert(app.doc.set_rotation_limits(hips, limits), "the limits did not take");
	float thigh_bone = ((Vec3){ 0.1, 0.4, 0 } - (Vec3){ 0, 0.5, 0 }).length();
	assert(math::abs(app.default_reach(hips) - thigh_bone * 1.5f) < 1.0e-4f,
		"the named primary child did not size the hips");
}

<*
 The first joint-limit slice: dot-keyed data and deterministic bone frames.

 No UI is involved here. These are the invariants the inspector, gizmo, MCP and
 IK solver will all share rather than reimplementing their own reading of X/Y/Z.
*>
module crig_tests::joint_limits;

import crig;
import crig_tests::euler_reference;
import crig_tests::library;
import rig;
import collision;
import std::collections::list;
import std::encoding::json;
import std::collections::object;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::os::env;

fn bool near(float a, float b) => math::abs(a - b) < 1.0e-5f;
fn bool near_vec(Vec3 a, Vec3 b) => (a - b).length_sq() < 1.0e-10f;

struct LimitRig
{
	crig::RigDocument doc;
	uint root;
	uint middle;
	uint leaf;
}

fn void LimitRig.open(&self)
{
	self.doc.dots.init(mem);
	self.doc.edges.init(mem);
	self.doc.rotation_limits.init(mem);
	self.root = self.doc.add_dot({ 0, 0, 0 }, "root");
	self.middle = self.doc.add_dot({ 0, 1, 0 }, "middle");
	self.leaf = self.doc.add_dot({ 0, 2, 0 }, "leaf");
	self.doc.connect(self.root, self.middle);
	self.doc.connect(self.middle, self.leaf);
}

fn void LimitRig.close(&self) => self.doc.free();

fn crig::JointLimitFrame frame_of(crig::RigDocument* doc, uint id)
{
	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	return crig::joint_limit_frame(&skeleton, ids, doc.rotation_limits_of(id));
}

fn void absent_limits_are_really_unconstrained() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	crig::JointRotationLimits limits = fixture.doc.rotation_limits_of(fixture.middle);
	test::@check(!limits.constrained, "an untouched joint was constrained");
	test::@check(limits.axes[0].allowed && limits.axes[1].allowed && limits.axes[2].allowed,
		"the panel defaults do not allow all three axes");
	test::@check(near(limits.axes[0].minimum, -(float)math::PI)
		&& near(limits.axes[0].maximum, (float)math::PI),
		"the default X range was %.3f..%.3f", limits.axes[0].minimum, limits.axes[0].maximum);
	test::@check(fixture.doc.rotation_limits.len() == 0,
		"reading defaults materialized document data");
}

fn void settings_are_dot_keyed_normalized_and_reset_to_absence() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	crig::JointRotationLimits limits = crig::unconstrained_rotation(fixture.middle);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -0.1f, .maximum = 2.5f };
	limits.axes[1] = { .allowed = false, .minimum = 0, .maximum = 0, .locked = 0.2f };
	limits.axes[2] = { .allowed = false, .minimum = 0, .maximum = 0, .locked = 0 };
	limits.has_saved_frame = true;
	limits.saved_frame = { 0, 0, 0, 2 };
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, limits), "the settings were refused");

	crig::JointRotationLimits held = fixture.doc.rotation_limits_of(fixture.middle);
	test::@check(held.dot_id == fixture.middle && held.constrained, "settings landed on the wrong dot");
	test::@check(near(held.saved_frame.v.w, 1.0f), "saved frame was not normalized (w %.3f)", held.saved_frame.v.w);
	test::@check(!held.axes[1].allowed && near(held.axes[1].locked, 0.2f),
		"the locked Y row changed");
	test::@check(!fixture.doc.set_rotation_limits(fixture.middle, held), "an exact no-op reported a change");
	held.constrained = false;
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, held), "limits could not be switched off");
	test::@check(fixture.doc.rotation_limits.len() == 1
		&& near(fixture.doc.rotation_limits_of(fixture.middle).axes[1].locked, 0.2f),
		"switching limits off erased the editable axis values");

	crig::JointRotationLimits reset = crig::unconstrained_rotation(fixture.middle);
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, reset), "reset changed nothing");
	test::@check(fixture.doc.rotation_limits.len() == 0, "reset left a sparse entry behind");

	reset.constrained = true;
	reset.axes[0].minimum = 1.0f;
	reset.axes[0].maximum = -1.0f;
	test::@check(!fixture.doc.set_rotation_limits(fixture.middle, reset),
		"an inverted range entered the document");
	test::@check(fixture.doc.rotation_limits.len() == 0,
		"refusing invalid data still materialized an entry");
}

fn void chain_frames_follow_the_child_and_leaf_follows_its_parent() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	crig::JointLimitFrame root = frame_of(&fixture.doc, fixture.root);
	crig::JointLimitFrame leaf = frame_of(&fixture.doc, fixture.leaf);
	test::@check(root.usable() && leaf.usable(), "a plain chain did not produce frames");
	test::@check(near_vec(root.axis(crig::JointRotationAxis.Y), { 0, 1, 0 }),
		"root +Y did not follow its child");
	test::@check(near_vec(root.axis(crig::JointRotationAxis.X), { 1, 0, 0 })
		&& near_vec(root.axis(crig::JointRotationAxis.Z), { 0, 0, 1 }),
		"upright chain got a rolled or left-handed frame");
	test::@check(near_vec(leaf.axis(crig::JointRotationAxis.Y), { 0, 1, 0 }),
		"leaf +Y did not continue parent to joint");
}

fn void bone_local_angles_round_trip_through_the_named_frame() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	// A diagonal bone makes the frame materially different from model axes, so
	// this catches a conversion that merely calls to_euler on the stored pose.
	fixture.doc.move_dot(fixture.leaf, { 1, 2, 1 });
	crig::JointLimitFrame frame = frame_of(&fixture.doc, fixture.middle);
	test::@check(frame.usable(), "the diagonal bone did not produce a frame");

	Vec3 entered = { 0.35f, -0.20f, 0.50f };
	Quaternionf rotation = crig::rotation_from_joint_angles(frame, entered);
	Vec3 shown = crig::joint_angles_from_rotation(frame, rotation);
	test::@check(near_vec(entered, shown),
		"bone-local angles changed across the quaternion (%s -> %s)", entered, shown);

	Quaternionf rebuilt = crig::rotation_from_joint_angles(frame, shown);
	test::@check(1.0f - math::abs(rotation.v.dot(rebuilt.v)) < 1.0e-6f,
		"the displayed values did not rebuild the same joint rotation");
}

fn void simple_axis_table_clamps_allowed_axes_and_holds_locked_ones() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();
	crig::JointLimitFrame frame = frame_of(&fixture.doc, fixture.middle);
	crig::JointRotationLimits limits = crig::unconstrained_rotation(fixture.middle);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -0.2f, .maximum = 0.4f };
	limits.axes[1] = { .allowed = false, .minimum = -1, .maximum = 1, .locked = 0.15f };
	limits.axes[2] = { .allowed = true, .minimum = -0.3f, .maximum = 0.3f };

	Quaternionf asked = crig::rotation_from_joint_angles(frame, { 0.8f, -0.7f, -0.6f });
	Quaternionf constrained = crig::constrain_joint_rotation(frame, limits, asked);
	Vec3 got = crig::joint_angles_from_rotation(frame, constrained);
	test::@check(near_vec(got, { 0.4f, 0.15f, -0.3f }),
		"constraint produced %s instead of the allowed/locked values", got);

	limits.constrained = false;
	Quaternionf free = crig::constrain_joint_rotation(frame, limits, asked);
	test::@check(1.0f - math::abs(free.v.dot(asked.v)) < 1.0e-6f,
		"an inactive table changed a free quaternion");
}

fn void sampled_playback_obeys_limits_without_rewriting_its_keys() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint root = app.doc.add_dot({ 0, 0, 0 }, "root");
	uint joint = app.doc.add_dot({ 0, 1, 0 }, "joint");
	uint tip = app.doc.add_dot({ 0, 2, 0 }, "tip");
	app.doc.connect(root, joint);
	app.doc.connect(joint, tip);

	AnimKeyDot[1] first_dots = {
		{ .joint_name = "joint", .axis = { 1, 0, 0 }, .angle = 0.6f,
			.move = { 0.1f, 0.0f, 0.0f } },
	};
	AnimKeyDot[1] last_dots = {
		{ .joint_name = "joint", .axis = { 1, 0, 0 }, .angle = 1.0f,
			.move = { 0.3f, 0.0f, 0.0f } },
	};
	AnimKeyframe[2] keys = {
		{ .time = 0.0f, .dots = first_dots[..] },
		{ .time = 1.0f, .dots = last_dots[..] },
	};
	AnimTemplate clip = {
		.name = "limited playback",
		.duration = 1.0f,
		.keyframes = keys[..],
	};

	crig::JointRotationLimits limits = crig::unconstrained_rotation(joint);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -0.2f, .maximum = 0.25f };
	limits.axes[1] = { .allowed = false, .locked = 0.0f };
	limits.axes[2] = { .allowed = false, .locked = 0.0f };
	test::@check(app.doc.set_rotation_limits(joint, limits),
		"the playback limit was refused");

	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	sz found = view.joint_of(joint);
	test::@check(found >= 0, "the limited joint was absent from its own rig view");
	if (found < 0) return;
	usz at = (usz)found;
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton,
		view.dot_ids, app.doc.rotation_limits_of(joint));

	// Halfway between two violating keys proves this is evaluation-time behavior,
	// not a one-off clamp when a key is read or authored.
	rig::Pose raw = clip.pose(mem, &view.skeleton, view.names, 0.5f, false);
	defer raw.free(mem);
	Vec3 raw_angles = crig::joint_angles_from_rotation(frame, raw.rotations[at]);
	test::@check(near(raw_angles.x, 0.8f),
		"the raw midpoint was %.3f, so the fixture never crossed the limit", raw_angles.x);

	app.current_anim = clip;
	app.current_ref = crig::NO_ANIM;
	app.anim_time = 0.5f;
	rig::Pose shown = app.sampled_pose(mem, &view);
	defer shown.free(mem);
	Vec3 shown_angles = crig::joint_angles_from_rotation(frame, shown.rotations[at]);
	test::@check(near_vec(shown_angles, { 0.25f, 0.0f, 0.0f }),
		"playback showed %s instead of the constrained midpoint", shown_angles);
	test::@check(near_vec(shown.offsets[at], raw.offsets[at]),
		"limit evaluation changed the clip's translation channel");

	// Exercise the crossfade branch too: its final blended quaternion must cross
	// the same evaluator rather than trusting constrained endpoints.
	app.fade_from = clip;
	app.fade_from_time = 0.5f;
	app.fade_span = 1.0f;
	app.fade_left = 0.5f;
	rig::Pose faded = app.sampled_pose(mem, &view);
	defer faded.free(mem);
	Vec3 faded_angles = crig::joint_angles_from_rotation(frame, faded.rotations[at]);
	test::@check(near_vec(faded_angles, { 0.25f, 0.0f, 0.0f }),
		"crossfade bypassed the playback limits and showed %s", faded_angles);

	// Grounding must measure the constrained limb. With the raw 0.8 rad bend the
	// tip falls below its rest floor and raises the root; an all-axis lock makes
	// the same limb straight, so applying the old ground correction afterwards
	// would leave the whole figure visibly floating.
	limits.axes[0] = { .allowed = false, .locked = 0.0f };
	test::@check(app.doc.set_rotation_limits(joint, limits),
		"the locked grounding limit was refused");
	AnimFoot[1] feet = { { .joint = "tip", .down = 0.0f, .up = 1.0f } };
	AnimTemplate grounded = clip;
	grounded.ground = { .feet = feet[..] };
	rig::Pose raw_grounded = grounded.pose(mem, &view.skeleton, view.names, 0.5f);
	defer raw_grounded.free(mem);
	rig::Pose evaluated_grounded = app.evaluated_clip_pose(mem, &view, grounded,
		crig::NO_ANIM, 0.5f);
	defer evaluated_grounded.free(mem);
	sz root_at = view.joint_of(root);
	test::@check(root_at >= 0, "the root was absent from its own rig view");
	if (root_at >= 0)
	{
		test::@check(raw_grounded.offsets[(usz)root_at].y > 0.1f,
			"the raw bend did not require a useful ground correction");
		test::@check(near(evaluated_grounded.offsets[(usz)root_at].y, 0.0f),
			"grounding ran before limits and left a %.3f root lift",
			evaluated_grounded.offsets[(usz)root_at].y);
	}

	test::@check(near(first_dots[0].angle, 0.6f) && near(last_dots[0].angle, 1.0f),
		"evaluating the clip rewrote its stored keys");
}

fn void direct_fk_turn_stops_at_the_same_axis_limit() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint root = app.doc.add_dot({ 0, 0, 0 }, "root");
	uint joint = app.doc.add_dot({ 0, 1, 0 }, "joint");
	uint tip = app.doc.add_dot({ 0, 2, 0 }, "tip");
	app.doc.connect(root, joint);
	app.doc.connect(joint, tip);

	crig::JointRotationLimits limits = crig::unconstrained_rotation(joint);
	limits.constrained = true;
	limits.axes[0].minimum = -0.2f;
	limits.axes[0].maximum = 0.25f;
	test::@check(app.doc.set_rotation_limits(joint, limits), "the FK limit was refused");

	AnimRef clip = app.new_clip("FK limits", 1.0f, from_rest: true);
	app.editing = clip;
	test::@check(app.park_clip(clip, 0.0f), "the FK clip would not park");
	app.select(joint);
	test::@check(app.begin_turn(), "a direct turn would not begin");
	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton,
		view.dot_ids, app.doc.rotation_limits_of(joint));
	app.turn_joint(frame.axis(crig::JointRotationAxis.X), 1.0f);
	Vec3 got = crig::joint_angles_from_rotation(frame, app.working_pose(joint).rotation);
	test::@check(near(got.x, 0.25f), "R crossed the X maximum and reached %.3f", got.x);
	app.cancel_drag();
}

fn void foot_ik_carries_only_the_turn_a_locked_knee_allows() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	// The fork keeps the hips out of the solve, leaving the ordinary two-pivot
	// leg: thigh and knee move the ankle, while the chest stays untouched.
	uint hips = app.doc.add_dot({ 0, 0.2f, 0 }, "hips");
	uint chest = app.doc.add_dot({ 0, 0.6f, 0 }, "chest");
	uint thigh = app.doc.add_dot({ 0, -0.1f, 0 }, "thigh");
	uint knee = app.doc.add_dot({ 0, -0.4f, 0 }, "knee");
	uint ankle = app.doc.add_dot({ 0, -0.7f, 0 }, "ankle");
	app.doc.connect(hips, chest);
	app.doc.connect(hips, thigh);
	app.doc.connect(thigh, knee);
	app.doc.connect(knee, ankle);
	app.doc.root_id = hips;

	crig::JointRotationLimits limits = crig::unconstrained_rotation(knee);
	limits.constrained = true;
	foreach (&axis : limits.axes)
	{
		axis.allowed = false;
		axis.locked = 0.0f;
	}
	test::@check(app.doc.set_rotation_limits(knee, limits), "the knee lock was refused");

	AnimRef clip = app.new_clip("IK limits", 1.0f, from_rest: true);
	app.editing = clip;
	test::@check(app.park_clip(clip, 0.0f), "the IK clip would not park");
	app.select(ankle);
	test::@check(app.begin_pose(), "G would not begin on the ankle");
	Vec3 ankle_was = app.dot_position(*app.doc.find(ankle));
	Vec3 target = { 0.25f, -0.45f, 0 };
	for (usz i = 0; i < 4; i++) app.pose_toward(target);

	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton,
		view.dot_ids, app.doc.rotation_limits_of(knee));
	Vec3 knee_angles = crig::joint_angles_from_rotation(frame,
		app.working_pose(knee).rotation);
	test::@check(near_vec(knee_angles, {}),
		"foot IK moved a locked knee to %s", knee_angles);
	test::@check(app.working_pose(thigh).rotation.v.w != 1.0f,
		"locking the knee prevented the free thigh from helping");
	test::@check((app.dot_position(*app.doc.find(ankle)) - ankle_was).length() > 0.05f,
		"the locked limb did not move at all");
	app.cancel_drag();
}

fn void limit_frame_is_carried_by_the_parent_but_not_the_joint_it_limits() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	pose.rotations[0] = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.7f);
	pose.rotations[1] = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 1.1f);
	Quaternionf[] world = pose.world_rotations(mem, &skeleton)!!;
	defer alloc::free(mem, world);

	crig::JointLimitFrame frame = crig::joint_limit_frame(&skeleton, ids,
		fixture.doc.rotation_limits_of(fixture.middle));
	Quaternionf carried = crig::carried_joint_limit_frame(frame, &skeleton, world, 1);
	Vec3 expected = pose.rotations[0].rotate_vec3(frame.axis(crig::JointRotationAxis.Y));
	Vec3 got = carried.rotate_vec3({ 0, 1, 0 });
	test::@check(near_vec(got, expected),
		"the parent's pose did not carry the local Y gizmo axis (%s vs %s)", got, expected);

	Vec3 wrongly_carried = world[1].rotate_vec3(frame.axis(crig::JointRotationAxis.Y));
	test::@check(!near_vec(got, wrongly_carried),
		"the selected joint rotated its own limit boundary");
}

fn void switching_a_local_turn_lock_replays_from_the_gesture_start() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	uint root = app.doc.add_dot({ 0, 0, 0 }, "root");
	uint joint = app.doc.add_dot({ 0.3f, 1, 0.2f }, "joint");
	uint tip = app.doc.add_dot({ 0.8f, 1.8f, 0.5f }, "tip");
	app.doc.connect(root, joint);
	app.doc.connect(joint, tip);
	Quaternionf parent_pose = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.55f);
	AnimRef clip = app.new_clip("Axis switch", 1.0f, from_rest: true);
	app.editing = clip;
	test::@check(app.pose_from_clip(clip, 0.0f), "the axis-switch draft would not open");
	test::@check(app.set_working_pose(root, parent_pose, {}), "the parent pose did not change");

	app.select(joint);
	test::@check(app.begin_turn(), "the local turn did not begin");
	test::@check(app.lock_drag(crig::DragAxis.X), "X did not claim the turn");
	Vec3 x_axis = app.drag.lock_direction;
	app.drag.turned = 0.4f;
	app.turn_joint(x_axis, app.drag.turned);

	// Switching to Z invokes turn_joint immediately with the same accumulated
	// screen sweep, and turn_joint always reads pose_before as its baseline.
	test::@check(app.lock_drag(crig::DragAxis.Z), "Z did not replace X");
	Vec3 z_axis = app.drag.lock_direction;
	Quaternionf expected = parent_pose.invert()
		.mul(quaternion::from_axis_angle{float}(z_axis, 0.4f))
		.mul(parent_pose).normalize();
	Quaternionf got = app.working_pose(joint).rotation;
	test::@check(1.0f - math::abs(expected.v.dot(got.v)) < 1.0e-6f,
		"switching X to Z accumulated both turns instead of replaying from the snapshot");
	app.cancel_drag();
}

fn void directional_and_plane_locks_project_the_pointer_without_drift() @test
{
	collision::Ray down = { .origin = { 4, 5, 10 }, .direction = { 0, 0, -1 } };
	Vec3 in_xy = crig::slide_in_plane({ 1, 2, 3 }, crig::DragAxis.XY, down)!!;
	test::@check(near_vec(in_xy, { 4, 5, 3 }),
		"the XY lock changed its held Z coordinate (%s)", in_xy);

	Vec3 diagonal = (Vec3){ 1, 1, 0 }.normalize();
	Vec3 along = crig::slide_along_direction({}, diagonal,
		{ .origin = { 2, 0, 5 }, .direction = { 0, 0, -1 } })!!;
	test::@check(near_vec(along, { 1, 1, 0 }),
		"the bone-direction projection missed the closest point (%s)", along);
}

<*
 A fork's bone axes follow the child that carries its bone on, with nothing to
 choose: the child along the bone coming in, or at the root, where none comes
 in, the child leading the most of the skeleton — the hips' spine, not a thigh.
 A named child or a saved frame still wins.
*>
fn void a_fork_follows_the_child_that_carries_its_bone_on() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	uint side = fixture.doc.add_dot({ 1, 1, 0 }, "side");
	fixture.doc.connect(fixture.middle, side);
	crig::JointLimitFrame automatic = frame_of(&fixture.doc, fixture.middle);
	test::@check(automatic.usable() && automatic.direction_dot == fixture.leaf,
		"a fork did not follow the child along its bone (%s, dot %d)", automatic.status, automatic.direction_dot);
	test::@check(near_vec(automatic.axis(crig::JointRotationAxis.Y), { 0, 1, 0 }),
		"the continuing child did not become +Y");

	uint tail = fixture.doc.add_dot({ -1, -0.5f, 0 }, "tail");
	fixture.doc.connect(fixture.root, tail);
	crig::JointLimitFrame root = frame_of(&fixture.doc, fixture.root);
	test::@check(root.usable() && root.direction_dot == fixture.middle,
		"the root followed its short branch (%s, dot %d)", root.status, root.direction_dot);

	crig::JointRotationLimits settings = crig::unconstrained_rotation(fixture.middle);
	settings.primary_child = side;
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, settings), "primary child was not stored");
	crig::JointLimitFrame chosen = frame_of(&fixture.doc, fixture.middle);
	test::@check(chosen.usable() && chosen.direction_dot == side,
		"the chosen child did not define the frame");
	test::@check(near_vec(chosen.axis(crig::JointRotationAxis.Y), { 1, 0, 0 }),
		"the selected side child did not become +Y");

	settings.primary_child = 0;
	settings.has_saved_frame = true;
	settings.saved_frame = { .v = { 0, 0, 0.70710678f, 0.70710678f } };
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, settings), "explicit frame was not stored");
	crig::JointLimitFrame explicit = frame_of(&fixture.doc, fixture.middle);
	test::@check(explicit.usable()
		&& near_vec(explicit.axis(crig::JointRotationAxis.Y), { -1, 0, 0 }),
		"a saved frame did not win over the fork's own child");
}

<*
 On the shipped humanoid, the forks follow the bones a person would name with
 no child stored: the hips the spine, the chest the neck, each wrist its middle
 finger — the last two what the file names outright.
*>
fn void the_humanoids_forks_follow_its_spine_neck_and_middle_fingers() @test
{
	String path = library::shipped_humanoid();
	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	crig::AppState app = crig::new_app(mesh, path);
	defer
	{
		app.free();
		mesh.free(mem);
	}
	test::@check(app.import_rig_from_source(), "%s must import its rig", path);
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);

	String[2][4] forks = { { "hips", "spine" }, { "chest", "neck" },
		{ "wrist_L", "middle_1_L" }, { "wrist_R", "middle_1_R" } };
	foreach (fork : forks)
	{
		crig::Dot* joint = app.dot_named(fork[0]);
		crig::Dot* child = app.dot_named(fork[1]);
		if (!joint || !child) { test::@check(false, "the humanoid has no %s or %s", fork[0], fork[1]); continue; }
		crig::JointRotationLimits limits = crig::unconstrained_rotation(joint.id);
		crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		crig::Dot* followed = app.doc.find(frame.direction_dot);
		test::@check(frame.usable() && frame.direction_dot == child.id,
			"%s followed %s, not %s", fork[0], followed ? followed.name : "nothing", fork[1]);
	}
}

fn void zero_length_and_invalid_primary_edges_are_reported() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	uint coincident = fixture.doc.add_dot({ 0, 2, 0 }, "coincident");
	fixture.doc.connect(fixture.leaf, coincident);
	crig::JointRotationLimits settings = crig::unconstrained_rotation(fixture.leaf);
	settings.primary_child = coincident;
	test::@check(fixture.doc.set_rotation_limits(fixture.leaf, settings), "zero child choice was not stored");
	crig::JointLimitFrame zero = frame_of(&fixture.doc, fixture.leaf);
	test::@check(zero.status == crig::JointLimitFrameStatus.ZERO_LENGTH,
		"a zero-length chosen edge reported %s", zero.status);

	settings.primary_child = fixture.root;
	test::@check(fixture.doc.set_rotation_limits(fixture.leaf, settings), "existing invalid child choice was not stored");
	crig::JointLimitFrame wrong = frame_of(&fixture.doc, fixture.leaf);
	test::@check(wrong.status == crig::JointLimitFrameStatus.PRIMARY_CHILD_INVALID,
		"a non-child primary reported %s", wrong.status);
}

fn crig::JointRotationLimits bent_knee(uint id, uint child)
{
	crig::JointRotationLimits limits = crig::unconstrained_rotation(id);
	limits.constrained = true;
	limits.primary_child = child;
	limits.axes[0] = { .allowed = true, .minimum = -0.125f, .maximum = 2.375f, .locked = 0.25f };
	limits.axes[1] = { .allowed = false, .minimum = -0.5f, .maximum = 0.75f, .locked = 0.0625f };
	limits.axes[2] = { .allowed = false, .minimum = -0.25f, .maximum = 0.25f, .locked = -0.03125f };
	limits.has_saved_frame = true;
	limits.saved_frame = { .v = { 0, 0, 0, 2 } };
	return limits;
}

<*
 The session leaves the limits to the model, and carries them only when asked
 — for a model that could not take them — round-tripping every value then.
*>
fn void limits_round_trip_through_the_project_session() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	crig::JointRotationLimits limits = bent_knee(fixture.middle, fixture.leaf);
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, limits), "the source limits were refused");

	String bare = crig::session_text(mem, &fixture.doc, "limited.glb");
	defer bare.free(mem);
	test::@check(bare.contains(`"version": 25`) && !bare.contains(`"rotation_limits"`),
		"a session written for a model that carries the limits wrote them too");

	String text = crig::session_text(mem, &fixture.doc, "limited.glb", limits: true);
	defer text.free(mem);
	test::@check(text.contains(`"rotation_limits"`), "a session asked to carry the limits did not");

	crig::RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session carrying limits did not parse");
		return;
	}
	crig::RigDocument back = parsed;
	defer back.free();

	crig::JointRotationLimits held = back.rotation_limits_of(fixture.middle);
	test::@check(held.constrained && held.primary_child == fixture.leaf,
		"active state or primary child was lost");
	test::@check(held.axes[0].same(limits.axes[0]) && held.axes[1].same(limits.axes[1])
		&& held.axes[2].same(limits.axes[2]), "an active or parked axis value changed");
	test::@check(held.has_saved_frame && near(held.saved_frame.v.w, 1.0f),
		"the normalized saved frame did not round-trip");

	String older = `{"version":12,"dots":[{"id":1,"position":[0,0,0]}],"edges":[]}`;
	crig::RigDocument? legacy = crig::parse_session(mem, older);
	if (catch legacy)
	{
		test::@check(false, "a session from before limits no longer opens");
		return;
	}
	crig::RigDocument old = legacy;
	defer old.free();
	test::@check(!old.rotation_limits_of(1).constrained && old.rotation_limits.len() == 0,
		"an older session invented constraints");
}

fn void malformed_limit_sessions_are_refused() @test
{
	String inverted = `{"version":13,"dots":[{"id":1,"position":[0,0,0]}],"edges":[],"rotation_limits":[{"id":1,"active":true,"axes":[{"allow":true,"minimum":1,"maximum":-1,"locked":0},{"allow":true,"minimum":-3,"maximum":3,"locked":0},{"allow":true,"minimum":-3,"maximum":3,"locked":0}],"frame":[0,0,0,1]}]}`;
	crig::RigDocument? bad = crig::parse_session(mem, inverted);
	if (try crig::RigDocument accepted = bad)
	{
		accepted.free();
		test::@check(false, "a session with an inverted axis range was accepted");
	}

	String repeated = `{"version":13,"dots":[{"id":1,"position":[0,0,0]}],"edges":[],"rotation_limits":[{"id":1,"active":true,"axes":[{"allow":true,"minimum":-1,"maximum":1,"locked":0},{"allow":true,"minimum":-1,"maximum":1,"locked":0},{"allow":true,"minimum":-1,"maximum":1,"locked":0}],"frame":[0,0,0,1]},{"id":1,"active":true,"axes":[{"allow":true,"minimum":-1,"maximum":1,"locked":0},{"allow":true,"minimum":-1,"maximum":1,"locked":0},{"allow":true,"minimum":-1,"maximum":1,"locked":0}],"frame":[0,0,0,1]}]}`;
	bad = crig::parse_session(mem, repeated);
	if (try crig::RigDocument accepted = bad)
	{
		accepted.free();
		test::@check(false, "duplicate limit entries for one dot were accepted");
	}
}

fn void a_recorded_limit_table_undoes_and_redoes_as_one_edit() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	uint root = app.doc.add_dot({ 0, 0, 0 }, "root");
	uint knee = app.doc.add_dot({ 0, 1, 0 }, "knee");
	uint foot = app.doc.add_dot({ 0, 2, 0 }, "foot");
	app.doc.connect(root, knee);
	app.doc.connect(knee, foot);

	crig::JointRotationLimits limits = bent_knee(knee, foot);
	test::@check(app.set_rotation_limits_recorded(knee, limits), "the recorded setter changed nothing");
	app.undo_stack.commit();
	test::@check(app.undo_stack.cursor == 1 && app.undo_stack.rotation_limits.len() == 1,
		"one table did not become one payload edit");
	test::@check(app.doc.rotation_limits_of(knee).constrained, "the table did not land");

	test::@check(app.undo(), "the limit edit would not undo");
	test::@check(!app.doc.rotation_limits_of(knee).constrained && app.doc.rotation_limits.len() == 0,
		"undo left a sparse constraint entry");
	test::@check(app.redo(), "the limit edit would not redo");
	test::@check(app.doc.rotation_limits_of(knee).constrained
		&& near(app.doc.rotation_limits_of(knee).axes[0].maximum, 2.375f),
		"redo did not restore the complete table");

	// Fork the history after undo. The abandoned payload must be dropped before
	// the replacement takes its slot, exactly like an abandoned clip edit.
	test::@check(app.undo(), "the edit would not undo before a history fork");
	crig::JointRotationLimits replacement = bent_knee(knee, foot);
	replacement.axes[0].maximum = 1.5f;
	test::@check(app.set_rotation_limits_recorded(knee, replacement), "the replacement table did not land");
	app.undo_stack.commit();
	test::@check(!app.undo_stack.can_redo() && app.undo_stack.rotation_limits.len() == 1,
		"forking history retained the abandoned limit payload");
}

<*
 A thigh leaning past the near-axis band derives its X from whichever way it
 leans least, so a knee moved from leaning forward to leaning sideways would turn
 the hip's axes a quarter turn and put its forward swing on the sideways row. The move keeps the
 hip's axes instead, carried onto the new bone, and one undo takes both back.
*>
fn void moving_a_joint_keeps_its_parents_limit_axes() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	uint hip = app.doc.add_dot({ 0, 1, 0 }, "hip");
	uint knee = app.doc.add_dot({ 0.06f, 0.5f, 0.125f }, "knee");
	uint foot = app.doc.add_dot({ 0.06f, 0, 0.125f }, "foot");
	app.doc.connect(hip, knee);
	app.doc.connect(knee, foot);

	crig::JointRotationLimits limits = crig::unconstrained_rotation(hip);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -2.0f, .maximum = 0.5f };
	test::@check(app.set_rotation_limits_recorded(hip, limits), "the table did not land");
	app.undo_stack.commit();
	Vec3 x_before = frame_of(&app.doc, hip).axis(X);

	// Leaning sideways more than forward: the derived rule would now seed Z.
	test::@check(app.move_recorded(knee, { 0.06f, 0.5f, 0.125f }, { 0.125f, 0.5f, 0.06f }), "the knee did not move");
	app.undo_stack.commit();
	crig::JointRotationLimits held = app.doc.rotation_limits_of(hip);
	test::@check(held.has_saved_frame, "the move let the hip's axes be re-derived");
	Vec3 x_after = frame_of(&app.doc, hip).axis(X);
	test::@check(x_after.dot(x_before) > 0.99f, "the hip's X turned %s -> %s", x_before, x_after);
	test::@check(near(frame_of(&app.doc, hip).axis(Y).dot(((Vec3){ 0.125f, -0.5f, 0.06f }).normalize()), 1.0f),
		"the kept axes do not follow the bone");

	test::@check(app.undo(), "the move would not undo");
	test::@check(!app.doc.rotation_limits_of(hip).has_saved_frame, "undo left the kept frame behind");

	// A move that does not switch the seed leaves the table derived.
	test::@check(app.move_recorded(knee, { 0.06f, 0.5f, 0.125f }, { 0.065f, 0.5f, 0.13f }), "the knee did not move");
	app.undo_stack.commit();
	test::@check(!app.doc.rotation_limits_of(hip).has_saved_frame, "a small move saved a frame");
}

// ---------------------------------------------------------------------------
// The other side of the symmetry plane

<*
 A figure with both sides placed, so a table can be read from one and checked
 against the other: legs hanging from a pelvis on the plane, arms held out
 sideways from a chest on it. The two make the two shapes the automatic frame
 rule gives mirrored bones — a leg's X stays the reflection of its twin's,
 an arm's Z does — and a hip whose table reflected the same way as a shoulder's
 would put someone's left knee on backwards.
*>
struct Sides
{
	crig::RigDocument doc;
	uint pelvis;
	uint hip_l, knee_l, foot_l;
	uint hip_r, knee_r, foot_r;
	uint chest;
	uint shoulder_l, elbow_l;
	uint shoulder_r, elbow_r;
}

fn void Sides.open(&self)
{
	self.doc.dots.init(mem);
	self.doc.edges.init(mem);
	self.doc.rotation_limits.init(mem);
	self.pelvis = self.doc.add_dot({ 0, 0, 0 }, "pelvis");
	self.hip_l = self.doc.add_dot({ 0.1f, 0, 0 }, "hip_L");
	self.knee_l = self.doc.add_dot({ 0.1f, -0.4f, 0 }, "knee_L");
	self.foot_l = self.doc.add_dot({ 0.1f, -0.8f, 0.05f }, "foot_L");
	self.hip_r = self.doc.add_dot({ -0.1f, 0, 0 }, "hip_R");
	self.knee_r = self.doc.add_dot({ -0.1f, -0.4f, 0 }, "knee_R");
	self.foot_r = self.doc.add_dot({ -0.1f, -0.8f, 0.05f }, "foot_R");
	self.chest = self.doc.add_dot({ 0, 0.5f, 0 }, "chest");
	self.shoulder_l = self.doc.add_dot({ 0.15f, 0.5f, 0 }, "shoulder_L");
	self.elbow_l = self.doc.add_dot({ 0.45f, 0.5f, 0 }, "elbow_L");
	self.shoulder_r = self.doc.add_dot({ -0.15f, 0.5f, 0 }, "shoulder_R");
	self.elbow_r = self.doc.add_dot({ -0.45f, 0.5f, 0 }, "elbow_R");
	self.doc.connect(self.pelvis, self.hip_l);
	self.doc.connect(self.hip_l, self.knee_l);
	self.doc.connect(self.knee_l, self.foot_l);
	self.doc.connect(self.pelvis, self.hip_r);
	self.doc.connect(self.hip_r, self.knee_r);
	self.doc.connect(self.knee_r, self.foot_r);
	self.doc.connect(self.pelvis, self.chest);
	self.doc.connect(self.chest, self.shoulder_l);
	self.doc.connect(self.shoulder_l, self.elbow_l);
	self.doc.connect(self.chest, self.shoulder_r);
	self.doc.connect(self.shoulder_r, self.elbow_r);
}

fn void Sides.close(&self) => self.doc.free();

// The table the mirror would give `twin` for `source`'s, or false.
fn bool Sides.mirrored(&self, uint source, uint twin, uint twin_primary, crig::JointRotationLimits* out)
{
	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&self.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	return crig::mirrored_rotation_limits(&skeleton, ids, self.doc.rotation_limits_of(source), twin, twin_primary, out);
}

<*
 Whether a twin's table is the source's seen in a mirror: constraining a turn
 and reflecting it lands where reflecting it and constraining it does, for
 turns inside each range, at its edges and past them.

 The invariant the whole thing exists for, stated without naming a sign. The
 tables are handed in rather than read, so a caller can check a result before
 it is stored.
*>
fn bool Sides.reflects_the_same(&self, crig::JointRotationLimits source, crig::JointRotationLimits twin)
{
	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&self.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	crig::JointLimitFrame from = crig::joint_limit_frame(&skeleton, ids, source);
	crig::JointLimitFrame to = crig::joint_limit_frame(&skeleton, ids, twin);
	if (!from.usable() || !to.usable()) return false;

	Vec3[] probes = {
		{ 0.1f, 0.2f, 0.3f }, { 1.2f, -0.6f, 0.4f }, { -0.9f, 0.5f, -1.1f },
		{ 2.0f, 0.0f, 0.0f }, { 0.0f, 1.4f, 0.0f }, { 0.0f, 0.0f, -1.3f }, { -1.5f, 1.0f, 0.9f },
		// A twist past a quarter turn, with a swing, which the Euler reading could not name.
		{ 0.9f, 2.6f, 0.7f }, { -1.0f, -2.9f, 0.5f }, { 1.4f, 0.5f, -1.3f }, { 0.4f, 3.0f, -0.6f },
	};
	foreach (angles : probes)
	{
		Quaternionf turn = crig::rotation_from_joint_angles(from, angles);
		Quaternionf held_then_reflected = crig::reflected_rotation(crig::constrain_joint_rotation(from, source, turn));
		Quaternionf reflected_then_held = crig::constrain_joint_rotation(to, twin, crig::reflected_rotation(turn));
		// The same rotation, either sign of quaternion.
		float agreement = math::abs(held_then_reflected.v.dot(reflected_then_held.v));
		if (agreement < 1.0f - 1.0e-4f) return false;
	}
	return true;
}

fn void reflecting_a_rotation_keeps_the_turn_about_the_normal() @test
{
	Quaternionf nod = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.7f);
	test::@check(math::abs(crig::reflected_rotation(nod).v.dot(nod.v)) > 1.0f - 1.0e-6f,
		"a turn about the plane's normal is its own reflection");
	Quaternionf twist = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.7f);
	Quaternionf untwist = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -0.7f);
	test::@check(math::abs(crig::reflected_rotation(twist).v.dot(untwist.v)) > 1.0f - 1.0e-6f,
		"a turn about an axis in the plane reflects to the turn the other way");

	// A reflected frame is a frame: right-handed, whichever axis turned about.
	Quaternionf frame = quaternion::from_axis_angle{float}((Vec3){ 0.3f, 0.5f, 0.8f }.normalize(), 1.1f);
	Vec3[2] choices = { { -1, 1, 1 }, { 1, 1, -1 } };
	foreach (signs : choices)
	{
		Quaternionf mirrored = crig::reflected_limit_frame(frame, signs);
		Vec3 x = mirrored.rotate_vec3({ 1, 0, 0 });
		Vec3 y = mirrored.rotate_vec3({ 0, 1, 0 });
		Vec3 z = mirrored.rotate_vec3({ 0, 0, 1 });
		Vec3 bone = frame.rotate_vec3({ 0, 1, 0 });
		test::@check(near_vec(x.cross(y), z), "the reflected frame with signs %s is not right-handed", signs);
		test::@check(near_vec(y, { -bone.x, bone.y, bone.z }), "the bone axis did not reflect with signs %s", signs);
		Vec3 read;
		test::@check(crig::reflection_signs_between(frame, mirrored, &read) && near_vec(read, signs),
			"the signs read back off the reflection are %s for %s", read, signs);
	}
}

fn void a_hip_reflects_its_flexion_as_is_and_its_twist_and_abduction_the_other_way() @test
{
	Sides sides;
	sides.open();
	defer sides.close();

	// Flexes forward further than back, twists a little outward, abducts.
	crig::JointRotationLimits hip = crig::unconstrained_rotation(sides.hip_l);
	hip.constrained = true;
	hip.axes[0] = { .allowed = true, .minimum = -0.5f, .maximum = 1.6f, .locked = 0.0f };
	hip.axes[1] = { .allowed = false, .minimum = -1.0f, .maximum = 1.0f, .locked = 0.2f };
	hip.axes[2] = { .allowed = true, .minimum = -0.2f, .maximum = 0.8f, .locked = 0.0f };
	test::@check(sides.doc.set_rotation_limits(sides.hip_l, hip), "the hip's table was refused");

	crig::JointRotationLimits twin;
	test::@check(sides.mirrored(sides.hip_l, sides.hip_r, 0, &twin), "the hip's table has no reflection");
	test::@check(twin.dot_id == sides.hip_r && twin.constrained && !twin.has_saved_frame,
		"the other hip's table is its own bone's, not a pinned frame");

	// A leg's X is the plane's normal: flexion reads the same on both sides.
	test::@check(twin.axes[0].allowed && near(twin.axes[0].minimum, -0.5f) && near(twin.axes[0].maximum, 1.6f),
		"flexion came back as [%.2f, %.2f], wanted [-0.50, 1.60]", twin.axes[0].minimum, twin.axes[0].maximum);
	// Twist and abduction run the other way round.
	test::@check(!twin.axes[1].allowed && near(twin.axes[1].locked, -0.2f),
		"the twist lock came back as %.2f, wanted -0.20", twin.axes[1].locked);
	test::@check(twin.axes[2].allowed && near(twin.axes[2].minimum, -0.8f) && near(twin.axes[2].maximum, 0.2f),
		"abduction came back as [%.2f, %.2f], wanted [-0.80, 0.20]", twin.axes[2].minimum, twin.axes[2].maximum);

	test::@check(sides.reflects_the_same(hip, twin), "constraining and reflecting do not commute on the hips");

	// And the check has teeth: the table copied across unreflected is what a
	// mirror that ignored the axes would write, and it is not the same joint.
	crig::JointRotationLimits copied = hip;
	copied.dot_id = sides.hip_r;
	test::@check(!sides.reflects_the_same(hip, copied), "a table copied across unreflected passes for a reflection");
}

fn void a_shoulder_reflects_its_raise_as_is_and_its_swing_and_twist_the_other_way() @test
{
	Sides sides;
	sides.open();
	defer sides.close();

	crig::JointRotationLimits shoulder = crig::unconstrained_rotation(sides.shoulder_l);
	shoulder.constrained = true;
	shoulder.axes[0] = { .allowed = true, .minimum = -1.0f, .maximum = 0.5f, .locked = 0.0f };
	shoulder.axes[1] = { .allowed = true, .minimum = -0.3f, .maximum = 0.9f, .locked = 0.0f };
	shoulder.axes[2] = { .allowed = false, .minimum = -1.0f, .maximum = 1.0f, .locked = 0.4f };
	test::@check(sides.doc.set_rotation_limits(sides.shoulder_l, shoulder), "the shoulder's table was refused");

	crig::JointRotationLimits twin;
	test::@check(sides.mirrored(sides.shoulder_l, sides.shoulder_r, 0, &twin), "the shoulder's table has no reflection");
	test::@check(!twin.has_saved_frame, "the other shoulder was pinned to a frame its own bone carries");

	// An arm's bone lies in the plane, so its Z is the one that keeps its
	// direction: the raise reads the same, the swing and the twist reverse.
	test::@check(near(twin.axes[0].minimum, -0.5f) && near(twin.axes[0].maximum, 1.0f),
		"the swing came back as [%.2f, %.2f], wanted [-0.50, 1.00]", twin.axes[0].minimum, twin.axes[0].maximum);
	test::@check(near(twin.axes[1].minimum, -0.9f) && near(twin.axes[1].maximum, 0.3f),
		"the twist came back as [%.2f, %.2f], wanted [-0.90, 0.30]", twin.axes[1].minimum, twin.axes[1].maximum);
	test::@check(!twin.axes[2].allowed && near(twin.axes[2].locked, 0.4f),
		"the raise lock came back as %.2f, wanted 0.40", twin.axes[2].locked);

	test::@check(sides.reflects_the_same(shoulder, twin), "constraining and reflecting do not commute on the shoulders");
}

<*
 A chosen child crosses as its twin, a twin's fork follows its own matching
 child, a saved frame crosses reflected, and a twin whose own bone cannot carry
 the axes is pinned to the reflection — each still the source's table seen in a
 mirror.
*>
fn void a_primary_child_and_a_saved_frame_cross_the_plane_with_the_table() @test
{
	Sides sides;
	sides.open();
	defer sides.close();

	// --- a chosen child, on a knee that branches into a foot and a heel -------
	uint heel_l = sides.doc.add_dot({ 0.1f, -0.7f, -0.1f }, "heel_L");
	uint heel_r = sides.doc.add_dot({ -0.1f, -0.7f, -0.1f }, "heel_R");
	sides.doc.connect(sides.knee_l, heel_l);
	sides.doc.connect(sides.knee_r, heel_r);

	crig::JointRotationLimits knee = crig::unconstrained_rotation(sides.knee_l);
	knee.constrained = true;
	knee.primary_child = sides.foot_l;
	knee.axes[0] = { .allowed = true, .minimum = 0.0f, .maximum = 2.4f, .locked = 0.0f };
	knee.axes[1] = { .allowed = false, .minimum = -1.0f, .maximum = 1.0f, .locked = 0.1f };
	knee.axes[2] = { .allowed = false, .minimum = -1.0f, .maximum = 1.0f, .locked = 0.0f };
	test::@check(sides.doc.set_rotation_limits(sides.knee_l, knee), "the knee's table was refused");

	crig::JointRotationLimits twin;
	test::@check(sides.mirrored(sides.knee_l, sides.knee_r, sides.foot_r, &twin), "the knee's table has no reflection");
	test::@check(twin.primary_child == sides.foot_r && !twin.has_saved_frame,
		"the other knee did not take the other foot for its bone");
	test::@check(sides.reflects_the_same(knee, twin), "constraining and reflecting do not commute on the knees");

	// --- without the child crossing, the twin's fork follows its own foot ------
	test::@check(sides.mirrored(sides.knee_l, sides.knee_r, 0, &twin), "the reflection was refused with no child named");
	test::@check(!twin.has_saved_frame && twin.primary_child == 0,
		"a twin whose fork follows the matching child was pinned to a frame");
	test::@check(sides.reflects_the_same(knee, twin), "the twin's own fork does not read the table the same way");

	// --- and a twin whose bone runs on elsewhere is pinned to the reflection ---
	uint spur_r = sides.doc.add_dot({ -0.1f, -0.8f, 0 }, "spur_R");
	sides.doc.connect(sides.knee_r, spur_r);
	test::@check(sides.mirrored(sides.knee_l, sides.knee_r, 0, &twin), "the reflection was refused for the spurred knee");
	test::@check(twin.has_saved_frame && twin.primary_child == 0,
		"a twin whose fork follows another bone was not pinned to the reflected frame");
	test::@check(sides.reflects_the_same(knee, twin), "the pinned frame does not read the table the same way");

	// --- a saved frame: the hip's, rolled a little about its bone --------------
	crig::JointRotationLimits hip = crig::unconstrained_rotation(sides.hip_l);
	hip.constrained = true;
	hip.axes[0] = { .allowed = true, .minimum = -0.5f, .maximum = 1.6f, .locked = 0.0f };
	hip.axes[1] = { .allowed = true, .minimum = -0.4f, .maximum = 0.4f, .locked = 0.0f };
	hip.axes[2] = { .allowed = true, .minimum = -0.2f, .maximum = 0.8f, .locked = 0.0f };
	crig::JointLimitFrame derived = frame_of(&sides.doc, sides.hip_l);
	hip.has_saved_frame = true;
	hip.saved_frame = derived.rotation.mul(quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f)).normalize();
	test::@check(sides.doc.set_rotation_limits(sides.hip_l, hip), "the hip's saved frame was refused");

	test::@check(sides.mirrored(sides.hip_l, sides.hip_r, 0, &twin), "the rolled hip's table has no reflection");
	test::@check(twin.has_saved_frame, "a saved frame did not cross as one");
	test::@check(sides.reflects_the_same(hip, twin), "constraining and reflecting do not commute on the rolled hips");

	// The roll crosses as the same roll the other way off the other hip's own
	// bone — what the twin's table would read as if its frame were derived.
	crig::JointLimitFrame twin_derived = frame_of(&sides.doc, sides.hip_r);
	Quaternionf adjustment = twin_derived.rotation.invert().mul(twin.saved_frame).normalize();
	Quaternionf unrolled = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -0.3f);
	test::@check(math::abs(adjustment.v.dot(unrolled.v)) > 1.0f - 1.0e-4f,
		"the saved roll crossed as %s rather than the same roll the other way", adjustment.v);

	// --- a source with no axes has nothing to reflect --------------------------
	crig::JointRotationLimits stale = crig::unconstrained_rotation(sides.knee_l);
	stale.constrained = true;
	stale.primary_child = sides.hip_l;
	test::@check(sides.doc.set_rotation_limits(sides.knee_l, stale), "the stale table was refused");
	test::@check(!sides.mirrored(sides.knee_l, sides.knee_r, 0, &twin),
		"a table whose bone follows no child claimed a reflection");
}

// ---------------------------------------------------------------------------
// Swing and twist
//
// A limit frame's X and Z are the swing across the bone and its Y the twist about
// it: `M = swing * twist`, twist first. These hold the reading to what that says,
// and the old Euler reading (`crig_tests::euler_reference`) is the yardstick where
// the two must agree.

const float DEG = (float)math::PI / 180.0f;

// A line of the report: on the screen, and appended to the file named by the
// `LIMITS_LOG` environment variable when there is one (the runner hides the screen
// of a test that passes).
fn void note(String format, args...)
{
	String line = string::tformat(format, ...args);
	io::printn(line);
	String? path = env::tget_var("LIMITS_LOG");
	if (catch path) return;
	File? out = file::open(path, "a");
	if (catch out) return;
	(void)io::fprintn(&out, line);
	(void)out.close();
}

fn crig::JointLimitFrame frame_from(Quaternionf rotation)
{
	crig::JointLimitFrame frame;
	frame.status = crig::JointLimitFrameStatus.READY;
	frame.rotation = rotation.normalize();
	return frame;
}

// Three frames: the model's own, and two turned a good way off it.
fn crig::JointLimitFrame[3] test_frames()
{
	return {
		frame_from(quaternion::IDENTITY),
		frame_from(quaternion::from_axis_angle{float}((Vec3){ 0.3f, 0.5f, 0.8f }.normalize(), 1.1f)),
		frame_from(quaternion::from_axis_angle{float}((Vec3){ -0.7f, 0.2f, 0.4f }.normalize(), -2.4f)),
	};
}

// The turn between two rotations, in radians, 0 to pi: read off the vector part so a
// small gap keeps its precision, and q and -q are the same rotation.
fn float rotation_gap(Quaternionf a, Quaternionf b)
{
	Quaternionf d = a.invert().mul(b).normalize();
	float vector = math::sqrt(d.v.x * d.v.x + d.v.y * d.v.y + d.v.z * d.v.z);
	return 2.0f * (float)math::atan2(vector, math::abs(d.v.w));
}

// The distance between two angles round the circle, 0 to pi.
fn float circle_gap(float a, float b)
{
	float d = a - b;
	d -= (float)math::TAU * (float)math::floor(d / (float)math::TAU + 0.5f);
	return math::abs(d);
}

// A repeatable stream of numbers in [0, 1).
struct Dice
{
	uint state;
}

fn float Dice.next(&self)
{
	self.state = self.state * 1664525 + 1013904223;
	return (float)(self.state >> 8) / (float)(1 << 24);
}

fn float Dice.between(&self, float low, float high) => low + (high - low) * self.next();

// Angles for a swing of up to `reach` radians in any direction across the bone, and any twist.
fn Vec3 Dice.angles(&self, float reach)
{
	float direction = self.between(0.0f, (float)math::TAU);
	float swing = self.between(0.0f, reach);
	return { swing * (float)math::cos(direction), self.between(-(float)math::PI, (float)math::PI),
		swing * (float)math::sin(direction) };
}

fn crig::JointRotationLimits box_limits(Vec3 low, Vec3 high)
{
	crig::JointRotationLimits limits = crig::unconstrained_rotation(1);
	limits.constrained = true;
	for (usz i = 0; i < 3; i++) limits.axes[i] = { .allowed = true, .minimum = low[i], .maximum = high[i] };
	return limits;
}

<*
 X and Z are the swing and Y the twist, and a turn about one axis alone reads as
 that angle on that axis — including a twist past a quarter turn, which the
 Euler reading flipped.
*>
fn void a_rotation_reads_as_where_the_bone_points_and_how_it_rolls() @test
{
	foreach (frame : test_frames())
	{
		// A twist of 143 degrees with a swing: all three come back as entered.
		Vec3 entered = { 0.5f, 2.5f, 0.3f };
		Vec3 shown = crig::joint_angles_from_rotation(frame, crig::rotation_from_joint_angles(frame, entered));
		test::@check(near_vec(entered, shown), "swing and twist %s read back as %s", entered, shown);

		// The twist goes first, so the bone points where the swing alone says.
		Vec3 bone = frame.axis(crig::JointRotationAxis.Y);
		Vec3 swung = crig::rotation_from_joint_angles(frame, { entered.x, 0.0f, entered.z }).rotate_vec3(bone);
		float[5] twists = { -3.0f, -1.2f, 0.0f, 1.5f, 3.0f };
		foreach (twist : twists)
		{
			Vec3 pointed = crig::rotation_from_joint_angles(frame, { entered.x, twist, entered.z }).rotate_vec3(bone);
			test::@check(near_vec(pointed, swung), "twist %.1f moved the bone from %s to %s", twist, swung, pointed);
		}

		// One axis alone is that angle on that axis, however far.
		float[6] angles = { -2.9f, -1.3f, -0.4f, 0.4f, 1.3f, 2.9f };
		foreach (angle : angles)
		{
			for (usz axis = 0; axis < 3; axis++)
			{
				Vec3 alone;
				alone[axis] = angle;
				Vec3 back = crig::joint_angles_from_rotation(frame, crig::rotation_from_joint_angles(frame, alone));
				test::@check(near_vec(back, alone), "%.1f about axis %d read as %s", angle, axis, back);
			}
		}

		// The twist is in (-pi, pi]: past it, it comes round.
		Vec3 past = crig::joint_angles_from_rotation(frame, crig::rotation_from_joint_angles(frame, { 0.0f, 3.3f, 0.0f }));
		test::@check(near(past.y, 3.3f - (float)math::TAU), "a twist of 3.3 read as %.4f", past.y);

		// A half-turn swing has no twist to read; it is the swing, whole.
		Vec3 half = { (float)math::PI * (float)math::cos(0.3f), 0.0f, (float)math::PI * (float)math::sin(0.3f) };
		Quaternionf over = crig::rotation_from_joint_angles(frame, half);
		Vec3 seen = crig::joint_angles_from_rotation(frame, over);
		test::@check(near(seen.y, 0.0f) && near(math::sqrt(seen.x * seen.x + seen.z * seen.z), (float)math::PI),
			"a half-turn swing read as %s", seen);
		test::@check(rotation_gap(crig::rotation_from_joint_angles(frame, seen), over) < 1.0e-4f,
			"a half-turn swing did not read back to itself");
	}
}

<*
 The reading and its inverse are the same thing both ways for any rotation whose
 swing is short of a half turn.
*>
fn void swing_and_twist_round_trip_for_any_rotation_short_of_a_half_turn() @test
{
	Dice dice = { .state = 7 };
	float worst = 0.0f;
	usz checked = 0;
	foreach (frame : test_frames())
	{
		for (int run = 0; run < 3000; run++)
		{
			// A random rotation of the frame's, not one built from angles.
			Quaternionf local = { dice.between(-1, 1), dice.between(-1, 1), dice.between(-1, 1), dice.between(-1, 1) };
			local = local.normalize();
			// Its swing, 2 acos of the (w, y) part, must be short of 175 degrees.
			if (math::sqrt(local.v.w * local.v.w + local.v.y * local.v.y) < math::cos(87.5f * DEG)) continue;
			Quaternionf rotation = frame.rotation.mul(local).mul(frame.rotation.invert()).normalize();
			Quaternionf back = crig::rotation_from_joint_angles(frame, crig::joint_angles_from_rotation(frame, rotation));
			worst = math::max(worst, rotation_gap(rotation, back));
			checked++;
		}
	}
	note("  swing-twist round trip: %d rotations, worst %.2e rad", checked, worst);
	test::@check(checked > 3000, "only %d rotations were checked", checked);
	test::@check(worst < 1.0e-5f, "a rotation came back %.2e rad away", worst);
}

<*
 No flips: sweeping a rotation through the old gimbal point (a twist of a quarter
 turn with a swing) or round the twist's wrap at a half turn moves the reading, and
 the clamp's answer, only as far as the sweep moves.
*>
fn void the_reading_and_the_clamp_are_continuous_through_the_old_gimbal_and_the_wrap() @test
{
	float step = 0.25f * DEG;
	// A box tight on the swing, so the clamp is working through the whole sweep, and
	// open all the way round on the twist, so the sweep can cross the half turn.
	crig::JointRotationLimits box = box_limits({ -0.2f, -(float)math::PI, -0.2f }, { 0.3f, (float)math::PI, 0.3f });
	Vec3[4] swings = { { 0.5f, 0.0f, 0.0f }, { 0.0f, 0.0f, 0.5f }, { 0.3f, 0.0f, 0.4f }, { -0.6f, 0.0f, 0.2f } };
	// A quarter turn of twist either way, and the half turn itself.
	float[2][4] spans = { { 70.0f, 110.0f }, { -110.0f, -70.0f }, { 160.0f, 200.0f }, { -200.0f, -160.0f } };
	float worst_reading = 0.0f;
	float worst_clamp = 0.0f;
	foreach (frame : test_frames())
	{
		foreach (swing : swings)
		{
			foreach (span : spans)
			{
				Vec3 last_angles;
				Quaternionf last_held;
				bool first = true;
				for (float twist = span[0] * DEG; twist <= span[1] * DEG; twist += step)
				{
					Quaternionf rotation = crig::rotation_from_joint_angles(frame, { swing.x, twist, swing.z });
					Vec3 angles = crig::joint_angles_from_rotation(frame, rotation);
					Quaternionf clamped = crig::constrain_joint_rotation(frame, box, rotation);
					if (!first)
					{
						float moved = math::max(circle_gap(angles.y, last_angles.y), math::max(math::abs(angles.x - last_angles.x), math::abs(angles.z - last_angles.z)));
						worst_reading = math::max(worst_reading, moved);
						worst_clamp = math::max(worst_clamp, rotation_gap(clamped, last_held));
					}
					last_angles = angles;
					last_held = clamped;
					first = false;
				}
			}
		}
	}
	note("  continuity: the reading moved at most %.4f and the clamp %.4f rad for a %.4f rad step", worst_reading, worst_clamp, step);
	test::@check(worst_reading < step * 1.01f, "the reading jumped by %.4f for a sweep step of %.4f", worst_reading, step);
	test::@check(worst_clamp < step * 1.01f, "the clamp jumped by %.4f for a sweep step of %.4f", worst_clamp, step);

	// The twist is the one angle that goes round: through a half turn the clamp is still
	// continuous where the allowed arc spans it.
	crig::JointRotationLimits round = box_limits({ -1.0f, 150.0f * DEG, -1.0f }, { 1.0f, 180.0f * DEG, 1.0f });
	crig::JointLimitFrame turned_frame = test_frames()[1];
	Quaternionf before;
	bool begun = false;
	float jump = 0.0f;
	for (float twist = 140.0f * DEG; twist <= 220.0f * DEG; twist += step)
	{
		Quaternionf asked = crig::rotation_from_joint_angles(turned_frame, { 0.4f, twist, -0.3f });
		Quaternionf got = crig::constrain_joint_rotation(turned_frame, round, asked);
		if (begun) jump = math::max(jump, rotation_gap(got, before));
		before = got;
		begun = true;
	}
	note("  continuity through a half turn of twist: the clamp moved at most %.4f rad for a %.4f rad step", jump, step);
	test::@check(jump < step * 1.01f, "the clamp jumped by %.4f through a twist of a half turn", jump);

	// The same through the old gimbal as the old reading built it: R = Rz(z) Ry(t) Rx(x), the
	// Euler middle angle t swept through a quarter turn. The rotation itself moves smoothly, so
	// the reading and the clamp may move only a few times as far as it does — a flip is a
	// jump of most of a half turn, hundreds of steps.
	float worst_ratio = 0.0f;
	float worst_flip = 0.0f;
	Vec3[4] eulers = { { 0.5f, 0.0f, 0.0f }, { 0.0f, 0.0f, 0.5f }, { 0.3f, 0.0f, -0.4f }, { -0.6f, 0.0f, 0.2f } };
	float[2][2] quarter = { { 80.0f, 100.0f }, { -100.0f, -80.0f } };
	foreach (frame : test_frames())
	{
		foreach (euler : eulers)
		{
			foreach (span : quarter)
			{
				Quaternionf last;
				Vec3 last_angles;
				Vec3 last_old;
				Quaternionf last_held;
				bool first = true;
				for (float t = span[0] * DEG; t <= span[1] * DEG; t += step)
				{
					Quaternionf rotation = euler_reference::euler_rotation(frame, { euler.x, t, euler.z });
					Vec3 angles = crig::joint_angles_from_rotation(frame, rotation);
					Quaternionf clamped = crig::constrain_joint_rotation(frame, box, rotation);
					Vec3 old = euler_reference::euler_angles(frame, rotation);
					if (!first)
					{
						float travelled = rotation_gap(rotation, last);
						Vec3 delta = { circle_gap(angles.x, last_angles.x), circle_gap(angles.y, last_angles.y), circle_gap(angles.z, last_angles.z) };
						worst_ratio = math::max(worst_ratio, math::max(delta.length(), rotation_gap(clamped, last_held)) / travelled);
						worst_flip = math::max(worst_flip, (old - last_old).length());
					}
					last = rotation;
					last_angles = angles;
					last_old = old;
					last_held = clamped;
					first = false;
				}
			}
		}
	}
	note("  through the Euler gimbal: the reading and the clamp moved at most %.2f times the rotation; the Euler reading jumped %.2f rad", worst_ratio, worst_flip);
	test::@check(worst_ratio < 4.0f, "the reading or the clamp moved %.2f times as far as the rotation through the old gimbal", worst_ratio);
	// The old reading did flip there, so the sweep has teeth.
	test::@check(worst_flip > 1.0f, "the old reading no longer flips through its gimbal (%.2f rad), so this sweep proves nothing", worst_flip);
}

<*
 A knee that bends 0..150 degrees and is asked for -170 goes to 150, the short way
 round; asked for -20 it goes to 0. Every row wraps the same way.
*>
fn void an_angle_past_a_range_goes_to_the_nearer_end_round_the_circle() @test
{
	crig::JointRotationLimits knee = crig::unconstrained_rotation(1);
	knee.constrained = true;
	knee.axes[0] = { .allowed = true, .minimum = 0.0f, .maximum = 150.0f * DEG };
	knee.axes[1] = { .allowed = false, .locked = 0.0f };
	knee.axes[2] = { .allowed = false, .locked = 0.0f };
	float[7] asked = { -170.0f, -20.0f, -100.0f, 170.0f, 100.0f, -130.0f, 160.0f };
	float[7] lands = { 150.0f, 0.0f, 0.0f, 150.0f, 100.0f, 150.0f, 150.0f };
	foreach (frame : test_frames())
	{
		foreach (usz i, degrees : asked)
		{
			Quaternionf bent = crig::rotation_from_joint_angles(frame, { degrees * DEG, 0.0f, 0.0f });
			Vec3 got = crig::joint_angles_from_rotation(frame, crig::constrain_joint_rotation(frame, knee, bent));
			test::@check(near_vec(got, { lands[i] * DEG, 0.0f, 0.0f }), "%.0f degrees landed at %s, wanted %.0f", degrees, got * (1.0f / DEG), lands[i]);
		}
	}

	// The twist wraps too, and a range that crosses the half turn takes angles on both sides of it.
	crig::JointRotationLimits twist = box_limits({ -1.0f, -120.0f * DEG, -1.0f }, { 1.0f, 120.0f * DEG, 1.0f });
	crig::JointLimitFrame frame = test_frames()[2];
	float[4] twist_asked = { 175.0f, -175.0f, 100.0f, -110.0f };
	float[4] twist_lands = { 120.0f, -120.0f, 100.0f, -110.0f };
	foreach (usz i, degrees : twist_asked)
	{
		Quaternionf turned = crig::rotation_from_joint_angles(frame, { 0.3f, degrees * DEG, 0.2f });
		Vec3 got = crig::joint_angles_from_rotation(frame, crig::constrain_joint_rotation(frame, twist, turned));
		test::@check(near_vec(got, { 0.3f, twist_lands[i] * DEG, 0.2f }), "a twist of %.0f landed at %s, wanted %.0f", degrees, got * (1.0f / DEG), twist_lands[i]);
	}
	crig::JointRotationLimits across = box_limits({ -1.0f, 150.0f * DEG, -1.0f }, { 1.0f, 180.0f * DEG, 1.0f });
	Quaternionf over = crig::rotation_from_joint_angles(frame, { 0.0f, 190.0f * DEG, 0.0f });
	Vec3 held = crig::joint_angles_from_rotation(frame, crig::constrain_joint_rotation(frame, across, over));
	// 180 degrees is the wrap itself, so it may read as either side of it.
	test::@check(circle_gap(held.y, 180.0f * DEG) < 1.0e-4f, "a twist of 190 past a range ending at 180 landed at %.1f", held.y / DEG);
	Quaternionf inside = crig::rotation_from_joint_angles(frame, { 0.0f, 160.0f * DEG, 0.0f });
	test::@check(rotation_gap(crig::constrain_joint_rotation(frame, across, inside), inside) < 1.0e-5f, "an angle inside its range moved");
	crig::JointAxisLimit row = { .allowed = true, .minimum = 150.0f * DEG, .maximum = 200.0f * DEG };
	test::@check(near(row.clamp(-170.0f * DEG), -170.0f * DEG) && near(row.overshoot(-170.0f * DEG), 0.0f),
		"-170 is 190 round the circle, inside a range of 150..200");
}

<*
 What "nearest" means for the box's clamp. Each row is clamped on its own, so the
 result is the nearest point of the box in the reading's own coordinates (swing
 x and z, and twist y round the circle), and that is exact. As an angle between
 rotations it is exact where those coordinates are the rotation's own angle — a
 hinge, and a twist with no swing — and elsewhere falls short of the true nearest
 by a second-order amount in the swing: a twist past its range, put on the bound,
 leaves the bone where it points, while a nearer rotation would nudge the swing
 too. For this box the twist can be at most 1.94 rad past a bound, which puts the
 shortfall at under 0.4 * swing^2. The last check holds it to that, and prints it.
*>
fn void the_clamp_lands_no_farther_than_sampled_allowed_rotations() @test
{
	crig::JointRotationLimits box = box_limits({ -0.6f, -1.1f, -0.5f }, { 0.9f, 1.3f, 0.7f });
	// The faces of the box: one coordinate on a bound, the others across their ranges.
	Vec3[] faces = alloc::new_array(mem, Vec3, 6 * 9 * 9);
	defer alloc::free(mem, faces);
	crig::JointLimitFrame identity = test_frames()[0];
	usz count = 0;
	for (usz fixed = 0; fixed < 3; fixed++)
	{
		for (usz side = 0; side < 2; side++)
		{
			for (usz a = 0; a < 9; a++)
			{
				for (usz b = 0; b < 9; b++)
				{
					Vec3 at;
					usz first = (fixed + 1) % 3;
					usz second = (fixed + 2) % 3;
					at[fixed] = side == 0 ? box.axes[fixed].minimum : box.axes[fixed].maximum;
					at[first] = box.axes[first].minimum + (box.axes[first].maximum - box.axes[first].minimum) * (float)a / 8.0f;
					at[second] = box.axes[second].minimum + (box.axes[second].maximum - box.axes[second].minimum) * (float)b / 8.0f;
					faces[count++] = at;
				}
			}
		}
	}

	// In the reading's coordinates the clamp is exactly the nearest.
	Dice dice = { .state = 11 };
	for (int run = 0; run < 2000; run++)
	{
		Vec3 asked = dice.angles(1.5f);
		Vec3 got = crig::joint_angles_from_rotation(identity, crig::constrain_joint_rotation(identity, box,
			crig::rotation_from_joint_angles(identity, asked)));
		Vec3 here = { asked.x - got.x, circle_gap(asked.y, got.y), asked.z - got.z };
		foreach (face : faces)
		{
			Vec3 there = { asked.x - face.x, circle_gap(asked.y, face.y), asked.z - face.z };
			test::@check(here.length() <= there.length() + 1.0e-4f, "%s clamped to %s, but %s is nearer in its coordinates", asked, got, face);
		}
	}

	// As a rotation, exact for a twist with no swing...
	foreach (frame : test_frames())
	{
		for (int run = 0; run < 200; run++)
		{
			Quaternionf asked = crig::rotation_from_joint_angles(frame, { 0.0f, dice.between(-(float)math::PI, (float)math::PI), 0.0f });
			float own = rotation_gap(asked, crig::constrain_joint_rotation(frame, box, asked));
			float nearest = float::max;
			foreach (face : faces) nearest = math::min(nearest, rotation_gap(asked, crig::rotation_from_joint_angles(frame, face)));
			test::@check(own <= nearest + 2.0e-5f, "a bare twist: the clamp is %.5f away, a face rotation %.5f", own, nearest);
		}
	}
	// ...and for a hinge, whose faces are its two ends.
	crig::JointRotationLimits hinge = crig::unconstrained_rotation(1);
	hinge.constrained = true;
	hinge.axes[0] = { .allowed = true, .minimum = -0.6f, .maximum = 0.9f };
	hinge.axes[1] = { .allowed = false, .locked = 0.0f };
	hinge.axes[2] = { .allowed = false, .locked = 0.0f };
	for (int run = 0; run < 400; run++)
	{
		float turn = dice.between(-(float)math::PI, (float)math::PI);
		Quaternionf asked = crig::rotation_from_joint_angles(identity, { turn, 0.0f, 0.0f });
		float own = rotation_gap(asked, crig::constrain_joint_rotation(identity, hinge, asked));
		float nearest = float::max;
		for (usz a = 0; a <= 150; a++)
		{
			float angle = -0.6f + 1.5f * (float)a / 150.0f;
			nearest = math::min(nearest, rotation_gap(asked, crig::rotation_from_joint_angles(identity, { angle, 0.0f, 0.0f })));
		}
		test::@check(own <= nearest + 2.0e-5f, "a hinge turned %.3f: the clamp is %.5f away, an allowed angle %.5f", turn, own, nearest);
	}

	// ...and otherwise short of the nearest by a second-order amount in the swing.
	float[3] reaches = { 0.2f, 0.5f, 1.0f };
	foreach (reach : reaches)
	{
		float worst = 0.0f;
		for (int run = 0; run < 1500; run++)
		{
			Quaternionf asked = crig::rotation_from_joint_angles(identity, dice.angles(reach));
			float own = rotation_gap(asked, crig::constrain_joint_rotation(identity, box, asked));
			float nearest = float::max;
			foreach (face : faces) nearest = math::min(nearest, rotation_gap(asked, crig::rotation_from_joint_angles(identity, face)));
			worst = math::max(worst, own - nearest);
		}
		note("  nearest: with a swing up to %.1f rad the clamp is at most %.4f rad (%.2f deg) past the nearest sampled face rotation (bound %.4f)", reach, worst, worst / DEG, 0.4f * reach * reach);
		test::@check(worst <= 0.4f * reach * reach, "with a swing up to %.1f rad the clamp was %.4f rad past the nearest", reach, worst);
	}
}

<*
 A hinge — one axis allowed, the others held at zero — clamps as it did under the
 Euler reading, for turns about that axis with a little off-axis noise. Out past
 the range the answer is the bound itself, exactly, whatever the noise; inside it
 the two readings of the same noise differ at second order in the noise. The
 inputs stay where going straight and going the short way round agree, since the
 wrap is the one thing that changed.
*>
fn void a_hinge_clamps_as_it_did_under_the_euler_reading() @test
{
	// One axis free over a range, per axis: a knee-like X, a twist-like Y, a swing-like Z.
	float[3] low = { 0.0f, -60.0f * DEG, -45.0f * DEG };
	float[3] high = { 150.0f * DEG, 60.0f * DEG, 45.0f * DEG };
	// Furthest the turn goes past a bound, and furthest a twist goes: the Euler middle angle
	// has no reading past a quarter turn.
	float past = 0.8f;
	Dice dice = { .state = 5 };
	float worst_small = 0.0f;
	float worst_large = 0.0f;
	usz clamped = 0;
	foreach (frame : test_frames())
	{
		for (usz axis = 0; axis < 3; axis++)
		{
			crig::JointRotationLimits hinge = crig::unconstrained_rotation(1);
			hinge.constrained = true;
			for (usz i = 0; i < 3; i++)
			{
				hinge.axes[i] = i == axis
					? (crig::JointAxisLimit){ .allowed = true, .minimum = low[axis], .maximum = high[axis] }
					: (crig::JointAxisLimit){ .allowed = false, .locked = 0.0f };
			}
			float top = axis == 1 ? 85.0f * DEG : 3.0f;
			for (int run = 0; run < 300; run++)
			{
				float turn = math::clamp(dice.between(low[axis] - past, high[axis] + past), -top, top);
				bool outside = turn < low[axis] || turn > high[axis];
				// Noise on the other two angles: a hair for any turn, a good deal for one past its bound.
				foreach (float noise : (float[2]){ 1.0e-3f, 0.05f })
				{
					if (noise > 0.01f && (!outside || math::min(math::abs(turn - low[axis]), math::abs(turn - high[axis])) < 0.2f)) continue;
					Vec3 angles = { dice.between(-noise, noise), dice.between(-noise, noise), dice.between(-noise, noise) };
					angles[axis] = turn;
					Quaternionf asked = euler_reference::euler_rotation(frame, angles);
					Quaternionf before = euler_reference::euler_clamp(frame, hinge, asked);
					Quaternionf now = crig::constrain_joint_rotation(frame, hinge, asked);
					float gap = rotation_gap(before, now);
					if (noise > 0.01f)
					{
						worst_large = math::max(worst_large, gap);
					}
					else
					{
						worst_small = math::max(worst_small, gap);
					}
					if (outside) clamped++;
				}
			}
		}
	}
	note("  hinge parity: %d turns past a bound; worst difference from the Euler clamp %.2e rad with 1e-3 noise, %.2e rad with 0.05 noise past a bound", clamped, worst_small, worst_large);
	test::@check(worst_small < 1.0e-5f, "a hinge with a hair of noise differs from the Euler clamp by %.2e rad", worst_small);
	test::@check(worst_large < 1.0e-5f, "a hinge past its bound differs from the Euler clamp by %.2e rad", worst_large);
}

<*
 The reading survives a reflection one angle at a time: a turn about the source's
 axis by theta is a turn about the twin's by -s*theta, s the sign that axis
 reflects with, for the swing's two components and the twist alike — including a
 twist past a quarter turn and a swing past a right angle. That is why the box a
 mirrored table describes is still a box.
*>
fn void the_swing_twist_reading_reflects_one_angle_at_a_time() @test
{
	Sides sides;
	sides.open();
	defer sides.close();

	uint[2][3] pairs = { { sides.hip_l, sides.hip_r }, { sides.shoulder_l, sides.shoulder_r }, { sides.knee_l, sides.knee_r } };
	Dice dice = { .state = 17 };
	foreach (pair : pairs)
	{
		crig::JointLimitFrame from = frame_of(&sides.doc, pair[0]);
		crig::JointLimitFrame to = frame_of(&sides.doc, pair[1]);
		Vec3 signs;
		test::@check(crig::reflection_signs_between(from.rotation, to.rotation, &signs), "the pair has no reflected frame");
		float worst = 0.0f;
		for (int run = 0; run < 500; run++)
		{
			Vec3 angles = dice.angles(2.6f);
			Quaternionf reflected = crig::reflected_rotation(crig::rotation_from_joint_angles(from, angles));
			Vec3 read = crig::joint_angles_from_rotation(to, reflected);
			Vec3 expected = { -signs.x * angles.x, -signs.y * angles.y, -signs.z * angles.z };
			float gap = math::max(math::abs(read.x - expected.x), math::max(circle_gap(read.y, expected.y), math::abs(read.z - expected.z)));
			worst = math::max(worst, gap);
		}
		note("  mirror: pair %d, signs %s, the reflected reading is off by %.2e rad at worst", (int)pair[0], signs, worst);
		test::@check(worst < 5.0e-5f, "a reflected rotation read %.2e rad from the mirrored angles (signs %s)", worst, signs);
	}
}

// ---------------------------------------------------------------------------
// The shipped clips

// How many times each clip is sampled across its length.
const usz CLIP_SAMPLES = 240;

// The old Euler clamp is taken not to have moved a joint when it moved it by less than
// this many degrees, and two clamps are taken to have moved it equally far within the second.
const float EULER_UNMOVED_DEGREES = 0.01f;
const float MOVED_ALIKE_DEGREES = 0.001f;

<*
 One clip's limited-joint samples, split by whether the old Euler clamp moved the joint.

 Inside the old box, the Euler clamp left the authored pose alone; the question is how
 far the swing-twist clamp moves it. Outside, the authored pose already broke the old
 limits and both clamps moved it; the question is which stays nearer the clip.
*>
struct ClipGroups
{
	usz inside;
	float inside_worst; // degrees the swing-twist clamp moved an authored pose that was inside the old box
	String inside_joint;
	float inside_time;
	usz outside;
	usz closer;  // the swing-twist clamp landed nearer the authored pose than the Euler clamp did
	usz farther;
	usz alike;
	float farther_worst; // the largest (swing-twist moved) - (Euler moved), degrees
	String farther_joint;
	float farther_time;
	float farther_new;
	float farther_old;
}

<*
 One clip, sampled and put through both clamps: the largest difference between the
 old and the new answer for any limited joint and where it was, and the samples split
 into the two groups.
*>
struct ClipDifference
{
	String clip;
	float degrees;
	String joint;
	float time;
	Vec3 asked;      // the clip's own rotation, read as swing-twist
	Vec3 asked_old;  // ... and as Euler angles
	Vec3 limits_low;
	Vec3 limits_high;
	Vec3 kept_old;   // what the Euler clamp left, read as Euler angles
	Vec3 kept_new;   // what the swing-twist clamp left, read as swing-twist
	float moved_old; // how far each clamp moved the clip's rotation here, in degrees
	float moved_new;
	usz moved; // limited joints the clamp moved at all, over every sample
	usz differing; // limited joints the two clamps put more than a degree apart, over every sample
	usz samples;
	ClipGroups groups;
}

<*
 @param failing : `Gets a line for each joint of this clip whose authored pose, inside the old box, the swing-twist clamp moved by a degree or more.`
*>
fn ClipDifference compare_clamps(crig::AppState* app, crig::RigView* view, crig::AnimTemplate* clip, usz count, DString* failing)
{
	ClipDifference out = { .clip = clip.name, .joint = "" };
	ClipGroups groups = { .inside_joint = "", .farther_joint = "" };
	usz joints = view.dot_ids.len;
	float[] joint_worst = alloc::new_array(mem, float, (sz)joints);
	float[] joint_time = alloc::new_array(mem, float, (sz)joints);
	Vec3[] joint_euler = alloc::new_array(mem, Vec3, (sz)joints);
	Vec3[] joint_swing = alloc::new_array(mem, Vec3, (sz)joints);
	defer alloc::free(mem, joint_worst);
	defer alloc::free(mem, joint_time);
	defer alloc::free(mem, joint_euler);
	defer alloc::free(mem, joint_swing);
	for (usz s = 0; s < count; s++)
	{
		float time = clip.duration * (float)s / (float)count;
		rig::Pose pose = clip.pose(mem, &view.skeleton, view.names, time, false);
		defer pose.free(mem);
		out.samples++;
		foreach (usz j, id : view.dot_ids)
		{
			crig::JointRotationLimits limits = app.doc.rotation_limits_of(id);
			if (!limits.constrained) continue;
			crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, limits);
			if (!frame.usable()) continue;
			Quaternionf asked = pose.rotations[j];
			Quaternionf before = euler_reference::euler_clamp(frame, limits, asked);
			Quaternionf now = crig::constrain_joint_rotation(frame, limits, asked);
			float moved_old = rotation_gap(asked, before) / DEG;
			float moved_new = rotation_gap(asked, now) / DEG;
			if (rotation_gap(asked, now) > 1.0e-4f) out.moved++;

			if (moved_old < EULER_UNMOVED_DEGREES)
			{
				groups.inside++;
				if (moved_new > joint_worst[j])
				{
					joint_worst[j] = moved_new;
					joint_time[j] = time;
					joint_euler[j] = euler_reference::euler_angles(frame, asked);
					joint_swing[j] = crig::joint_angles_from_rotation(frame, asked);
				}
				if (moved_new > groups.inside_worst)
				{
					groups.inside_worst = moved_new;
					groups.inside_joint = view.names[j];
					groups.inside_time = time;
				}
			}
			else
			{
				groups.outside++;
				float excess = moved_new - moved_old;
				if (excess > MOVED_ALIKE_DEGREES)
				{
					groups.farther++;
				}
				else if (excess < -MOVED_ALIKE_DEGREES)
				{
					groups.closer++;
				}
				else
				{
					groups.alike++;
				}
				if (excess > groups.farther_worst)
				{
					groups.farther_worst = excess;
					groups.farther_joint = view.names[j];
					groups.farther_time = time;
					groups.farther_new = moved_new;
					groups.farther_old = moved_old;
				}
			}

			float degrees = rotation_gap(before, now) / DEG;
			if (degrees >= 1.0f) out.differing++;
			if (degrees > out.degrees)
			{
				ClipDifference worse = {
					.clip = clip.name, .degrees = degrees, .joint = view.names[j], .time = time,
					.asked = crig::joint_angles_from_rotation(frame, asked),
					.asked_old = euler_reference::euler_angles(frame, asked),
					.kept_old = euler_reference::euler_angles(frame, before),
					.kept_new = crig::joint_angles_from_rotation(frame, now),
					.moved_old = moved_old,
					.moved_new = moved_new,
				};
				for (usz a = 0; a < 3; a++)
				{
					worse.limits_low[a] = limits.axes[a].allowed ? limits.axes[a].minimum : limits.axes[a].locked;
					worse.limits_high[a] = limits.axes[a].allowed ? limits.axes[a].maximum : limits.axes[a].locked;
				}
				worse.moved = out.moved;
				worse.differing = out.differing;
				worse.samples = out.samples;
				out = worse;
			}
		}
	}
	out.groups = groups;
	foreach (usz j, worst : joint_worst)
	{
		if (worst < 1.0f) continue;
		crig::JointRotationLimits limits = app.doc.rotation_limits_of(view.dot_ids[j]);
		Vec3 low;
		Vec3 high;
		for (usz a = 0; a < 3; a++)
		{
			low[a] = limits.axes[a].allowed ? limits.axes[a].minimum : limits.axes[a].locked;
			high[a] = limits.axes[a].allowed ? limits.axes[a].maximum : limits.axes[a].locked;
		}
		failing.appendf("\n  - %s: %s moved %.3f deg at t=%.3f; authored %s as Euler (table %s .. %s), %s as swing-twist",
			clip.name, view.names[j], worst, joint_time[j], joint_euler[j] * (1.0f / DEG),
			low * (1.0f / DEG), high * (1.0f / DEG), joint_swing[j] * (1.0f / DEG));
	}
	return out;
}

<*
 Existing animation does not change where it was inside the limits. Every clip the
 shipped humanoid carries (`Walk_slow`, `Climb ladder`), the sample clips the test
 library puts on its copy, and a generated walk, are sampled 240 times, and every
 limited joint is put through the old Euler clamp and the new swing-twist one. The
 samples fall in two groups.

 Inside the old box, the Euler clamp left the authored pose alone. Those are the
 poses the old limits allowed, and the new clamp must not disturb them: it moves
 each by under a degree. That is the assertion.

 Outside it, the authored pose already broke the old limits and both clamps moved
 it. There is no "before" to keep for such a pose, and which result is right depends
 on what the table's numbers meant, which is what changed. So the two clamps are not
 asked to agree; the change is judged on which stays nearer the clip, and the counts
 and the worst case are printed. The old test, that no clamp differs from the
 Euler one by a degree, is kept only as a printed note.

 The numbers are printed, and written to the `LIMITS_LOG` file when there is one.
*>
fn void clips_inside_the_old_limits_play_within_a_degree_of_the_authored_pose() @test
{
	String path = library::shipped_humanoid();
	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	crig::AppState app = crig::new_app(mesh, path);
	defer
	{
		app.free();
		mesh.free(mem);
	}
	test::@check(app.import_rig_from_source(), "%s must import its rig", path);
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);

	usz limited = 0;
	foreach (id : view.dot_ids) if (app.doc.rotation_limits_of(id).constrained) limited++;
	note("  %d of %d joints carry limits", limited, view.dot_ids.len);
	test::@check(limited > 20, "only %d joints carry limits", limited);

	DString failing = dstring::new(mem);
	defer failing.free();
	List{ClipDifference} found;
	found.init(mem);
	defer found.free();

	// What the shipped file carries.
	crig::AnimPack shipped = crig::read_pack(mem, path)!!;
	defer shipped.free(mem);
	bool walk_slow;
	bool ladder;
	foreach (&clip : shipped.clips)
	{
		if (clip.name == "Walk_slow") walk_slow = true;
		if (clip.name == "Climb ladder") ladder = true;
		found.push(compare_clamps(&app, &view, clip, CLIP_SAMPLES, &failing));
	}
	test::@check(walk_slow && ladder, "the shipped humanoid no longer carries Walk_slow and Climb ladder");

	// The sample clips the test library puts on its copy.
	String library_path = string::tformat("%s/humanoid.glb", library::ready());
	crig::AnimPack samples = crig::read_pack(mem, library_path)!!;
	defer samples.free(mem);
	foreach (&clip : samples.clips) found.push(compare_clamps(&app, &view, clip, CLIP_SAMPLES, &failing));

	// A generated walk, the way the gait tests make one.
	Object*? args = json::parse(mem, `{"name":"Gait Biped","duration":1.0,"gait":"walk"}`);
	if (try args)
	{
		defer args.free();
		DString detail = dstring::new(mem);
		defer detail.free();
		String? text = crig::author_gait_json(&app, args, &detail);
		if (try text)
		{
			defer text.free(mem);
			crig::AnimRef ref = app.clip_named_in_authored("Gait Biped");
			if (ref.valid())
			{
				found.push(compare_clamps(&app, &view, app.clip(ref), CLIP_SAMPLES, &failing));
			}
			else
			{
				test::@check(false, "the generated walk did not land");
			}
		}
		else
		{
			test::@check(false, "the walk would not generate: %s", detail.str_view());
		}
	}

	// Everything is printed first, so one clip does not hide the rest.
	float inside_worst = 0.0f;
	usz inside_over = 0;
	foreach (result : found)
	{
		ClipGroups g = result.groups;
		note("clip %s (%d samples of each limited joint)", result.clip, result.samples);
		note("  (a) inside the old box: %d samples; the swing-twist clamp moved one by at most %.4f deg (%s, t=%.3f)",
			g.inside, g.inside_worst, g.inside_joint, g.inside_time);
		note("  (b) outside it: %d samples; the swing-twist clamp landed nearer the authored pose %d times, farther %d, as near %d; the largest excess of its move over the Euler clamp's is %.3f deg (%s, t=%.3f: it moved %.3f, Euler %.3f)",
			g.outside, g.closer, g.farther, g.alike, g.farther_worst, g.farther_joint, g.farther_time, g.farther_new, g.farther_old);
		note("  note: against the Euler clamp the largest difference is %.4f deg at %s, t=%.3f, and they differ by a degree or more %d times",
			result.degrees, result.joint, result.time, result.differing);
		if (g.inside_worst > inside_worst) inside_worst = g.inside_worst;
		if (g.inside_worst >= 1.0f) inside_over++;
	}
	note("  largest move of a pose inside the old box, over every clip: %.4f deg", inside_worst);
	test::@check(inside_over == 0, "the new clamp moved poses that were inside the old limits by a degree or more in %d of %d clips:%s",
		inside_over, found.len(), failing.str_view());
}

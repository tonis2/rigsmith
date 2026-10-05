<*
 The first joint-limit slice: dot-keyed data and deterministic bone frames.

 No UI is involved here. These are the invariants the inspector, gizmo, MCP and
 IK solver will all share rather than reimplementing their own reading of X/Y/Z.
*>
module crig_tests::joint_limits;

import crig;
import rig;
import collision;
import std::core::test;
import std::math;

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

fn void a_fork_requires_an_explicit_primary_child() @test
{
	LimitRig fixture;
	fixture.open();
	defer fixture.close();

	uint side = fixture.doc.add_dot({ 1, 1, 0 }, "side");
	fixture.doc.connect(fixture.middle, side);
	crig::JointLimitFrame refused = frame_of(&fixture.doc, fixture.middle);
	test::@check(refused.status == crig::JointLimitFrameStatus.NEEDS_PRIMARY_CHILD,
		"a fork silently chose a child (%s)", refused.status);

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
	settings.saved_frame = quaternion::IDENTITY;
	test::@check(fixture.doc.set_rotation_limits(fixture.middle, settings), "explicit frame was not stored");
	crig::JointLimitFrame explicit = frame_of(&fixture.doc, fixture.middle);
	test::@check(explicit.usable()
		&& near_vec(explicit.axis(crig::JointRotationAxis.Y), { 0, 1, 0 }),
		"a saved frame did not resolve the fork");
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
	test::@check(bare.contains(`"version": 23`) && !bare.contains(`"rotation_limits"`),
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
 A chosen child crosses as its twin, a saved frame crosses reflected, and a
 twin whose own bone cannot carry the axes is pinned to the reflection — each
 still the source's table seen in a mirror.
*>
fn void a_primary_child_and_a_saved_frame_cross_the_plane_with_the_table() @test
{
	Sides sides;
	sides.open();
	defer sides.close();

	// --- a chosen child, on a knee that branches into a foot and a heel -------
	uint heel_l = sides.doc.add_dot({ 0.1f, -0.8f, -0.05f }, "heel_L");
	uint heel_r = sides.doc.add_dot({ -0.1f, -0.8f, -0.05f }, "heel_R");
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

	// --- and without the child crossing, the twin cannot carry the axes itself
	test::@check(sides.mirrored(sides.knee_l, sides.knee_r, 0, &twin), "the reflection was refused with no child named");
	test::@check(twin.has_saved_frame && twin.primary_child == 0,
		"a twin that branches with no child chosen was not pinned to the reflected frame");
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
	crig::JointRotationLimits fork = crig::unconstrained_rotation(sides.knee_l);
	fork.constrained = true;
	test::@check(sides.doc.set_rotation_limits(sides.knee_l, fork), "the fork's table was refused");
	test::@check(!sides.mirrored(sides.knee_l, sides.knee_r, 0, &twin),
		"a table on a fork with no child chosen claimed a reflection");
}

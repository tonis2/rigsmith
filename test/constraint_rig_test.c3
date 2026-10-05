<*
 P1: the document's editable dot-keyed limits cross into an owned, dense,
 joint-indexed constraint rig without becoming jiggle physics.
*>
module crig_tests::constraint_rig;

import crig;
import rig;
import gltf;
import std::core::test;
import std::math;
import std::io::file;
import std::core::string;
import std::collections::list;

fn bool near(float a, float b) => math::abs(a - b) < 1.0e-5f;
fn bool near_vec(Vec3 a, Vec3 b) => (a - b).length() < 1.0e-4f;
fn bool near_quat(Quaternionf a, Quaternionf b)
{
	float same = (a.v - b.v).dot(a.v - b.v);
	float negated = (a.v + b.v).dot(a.v + b.v);
	return same < 1.0e-8f || negated < 1.0e-8f;
}

struct ConstraintFixture
{
	crig::RigDocument doc;
	uint root;
	uint knee;
	uint foot;
}

fn void ConstraintFixture.open(&self)
{
	self.doc.dots.init(mem);
	self.doc.edges.init(mem);
	self.doc.secondary.init(mem);
	self.doc.rotation_limits.init(mem);
	self.root = self.doc.add_dot({ 0, 0, 0 }, "hips");
	self.knee = self.doc.add_dot({ 0, -1, 0 }, "knee");
	self.foot = self.doc.add_dot({ 0, -2, 0 }, "foot");
	self.doc.connect(self.root, self.knee);
	self.doc.connect(self.knee, self.foot);
}

fn void ConstraintFixture.close(&self) => self.doc.free();

fn int joint_of(uint[] ids, uint id)
{
	foreach (usz joint, held : ids) if (held == id) return (int)joint;
	return -1;
}

fn crig::JointRotationLimits knee_limits(uint knee, uint foot)
{
	crig::JointRotationLimits limits = crig::unconstrained_rotation(knee);
	limits.constrained = true;
	limits.primary_child = foot;
	limits.axes[0] = { .allowed = true, .minimum = -0.2f, .maximum = 2.4f };
	limits.axes[1] = { .allowed = false, .locked = 0.125f };
	limits.axes[2] = { .allowed = false, .locked = -0.25f };
	return limits;
}

fn void constraints_are_dense_owned_and_not_jiggle_physics() @test
{
	ConstraintFixture fixture;
	fixture.open();
	defer fixture.close();

	crig::JointRotationLimits limits = knee_limits(fixture.knee, fixture.foot);
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the knee constraint was refused");
	test::@check(fixture.doc.set_secondary((crig::SecondaryChain){ .root = fixture.foot, .tip = fixture.foot }
		.with_preset(crig::SecondaryPreset.TAIL)),
		"the independent secondary-motion chain was refused");

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}

	crig::ConstraintRig constraints = crig::constraint_rig_of(mem, &fixture.doc,
		&skeleton, ids);
	defer constraints.free(mem);

	int knee = joint_of(ids, fixture.knee);
	int foot = joint_of(ids, fixture.foot);
	test::@check(constraints.joints.len == skeleton.len(),
		"the constraint table is not dense (%d rows for %d joints)",
		constraints.joints.len, skeleton.len());
	test::@check(knee >= 0 && foot >= 0, "the fixture did not build in joint order");
	if (knee < 0 || foot < 0) return;

	crig::JointConstraint carried = constraints.joints[(usz)knee];
	test::@check(carried.status == crig::JointConstraintStatus.EXACT,
		"the knee was not carried exactly (%s)", carried.status);
	test::@check(carried.frame_intent == crig::ConstraintFrameIntent.PRIMARY_CHILD
		&& carried.primary_child == foot,
		"primary-child intent did not become a joint index");
	test::@check(carried.axes[0].same(limits.axes[0])
		&& carried.axes[1].same(limits.axes[1])
		&& carried.axes[2].same(limits.axes[2]),
		"an axis changed at the dot-to-joint boundary");
	test::@check(constraints.joints[(usz)foot].status == crig::JointConstraintStatus.FREE,
		"a jiggle-only foot became an anatomical constraint");
	test::@check(constraints.joints[(usz)foot].axes[0].allowed
		&& near(constraints.joints[(usz)foot].axes[0].minimum, -(float)math::PI)
		&& near(constraints.joints[(usz)foot].axes[0].maximum, (float)math::PI),
		"a free row carries locked-looking axis defaults");

	// The result owns a copy rather than borrowing the document's editable row.
	limits.axes[0].maximum = 0.5f;
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the source constraint could not be edited after conversion");
	test::@check(near(carried.axes[0].maximum, 2.4f),
		"editing the document mutated the already-built constraint rig");
}

fn void a_saved_frame_becomes_a_bone_relative_adjustment() @test
{
	ConstraintFixture fixture;
	fixture.open();
	defer fixture.close();

	crig::JointRotationLimits limits = knee_limits(fixture.knee, fixture.foot);
	Quaternionf adjustment = quaternion::from_euler{float}(0.0f, 0.35f, -0.15f);

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}

	crig::JointRotationLimits derived = limits;
	derived.has_saved_frame = false;
	crig::JointLimitFrame base = crig::joint_limit_frame(&skeleton, ids, derived);
	test::@check(base.usable(), "the source bone frame could not be derived");
	if (!base.usable()) return;

	limits.has_saved_frame = true;
	limits.saved_frame = base.rotation.mul(adjustment).normalize();
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the adjusted source frame was refused");

	crig::ConstraintRig constraints = crig::constraint_rig_of(mem, &fixture.doc,
		&skeleton, ids);
	defer constraints.free(mem);
	int knee = joint_of(ids, fixture.knee);
	if (knee < 0) { test::@check(false, "the knee did not build"); return; }

	crig::JointConstraint carried = constraints.joints[(usz)knee];
	test::@check(carried.status == crig::JointConstraintStatus.EXACT
		&& carried.frame_intent == crig::ConstraintFrameIntent.ADJUSTED_PRIMARY_CHILD,
		"the saved primary-child frame lost its intent");
	test::@check(near_quat(carried.frame_adjustment, adjustment),
		"the saved model-space frame was copied instead of made bone-relative");
	test::@check(near_quat(base.rotation.mul(carried.frame_adjustment).normalize(),
		limits.saved_frame.normalize()),
		"the carried adjustment does not reconstruct the source frame");
}

fn void ambiguous_transfer_frames_are_reported_not_guessed() @test
{
	ConstraintFixture fixture;
	fixture.open();
	defer fixture.close();

	uint toe = fixture.doc.add_dot({ 1, -1, 0 }, "toe");
	fixture.doc.connect(fixture.knee, toe);
	crig::JointRotationLimits limits = knee_limits(fixture.knee, 0);
	limits.primary_child = 0;
	limits.has_saved_frame = true;
	limits.saved_frame = quaternion::IDENTITY;
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the explicit source frame was refused");

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	crig::ConstraintRig constraints = crig::constraint_rig_of(mem, &fixture.doc,
		&skeleton, ids);
	defer constraints.free(mem);

	int knee = joint_of(ids, fixture.knee);
	if (knee < 0) { test::@check(false, "the knee did not build"); return; }
	crig::JointConstraint carried = constraints.joints[(usz)knee];
	test::@check(carried.status == crig::JointConstraintStatus.UNSUPPORTED,
		"an ambiguous reusable frame was silently accepted");
	test::@check(carried.frame_status == crig::JointLimitFrameStatus.NEEDS_PRIMARY_CHILD,
		"the unsupported row lost the reason it cannot transfer (%s)", carried.frame_status);
	test::@check(constraints.unsupported() == 1,
		"the constraint report counted %d unsupported rows", constraints.unsupported());
}

const String PACK_CONSTRAINT_GLB = "test/out_constraint_pack.glb";
const String RIGGED_CONSTRAINT_GLB = "test/out_constraint_rigged.glb";
const String FOREIGN_CONSTRAINT_GLB = "test/out_constraint_foreign.glb";
const String FOREIGN_ROUNDTRIP_GLB = "test/out_constraint_foreign_roundtrip.glb";

fn int node_named(gltf::GltfStream* stream, String name)
{
	for (sz i = 0; i < stream.gltf.nodes.len(); i++)
	{
		if (stream.gltf.nodes[i].name == name) return (int)i;
	}
	return -1;
}

fn int named_joint(crig::AnimPack* pack, String name)
{
	foreach (usz joint, held : pack.joint_names) if (held == name) return (int)joint;
	return -1;
}

fn void inspect_constraint_file(
	String path,
	rig::Skeleton* skeleton,
	usz knee,
	usz foot,
	crig::JointRotationLimits authored)
{
	gltf::GltfStream? opened = gltf::open(path, mem);
	if (catch opened)
	{
		test::@check(false, "the constraint file would not reopen");
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();

	// This deliberately tiny three-point fixture has no volumetric weighted
	// region, so P5 honestly omits its target bodies. A reviewed knee still must
	// not become a jiggle motion meanwhile.
	test::@check(stream.gltf.physics_joints.len() == 1,
		"the file carries %d KHR joint settings, not 1", stream.gltf.physics_joints.len());
	test::@check(stream.gltf.motions.len() == 0,
		"an anatomical constraint created %d dynamic motions", stream.gltf.motions.len());
	test::@check(stream.gltf.shapes.len() == 0,
		"an anatomical constraint invented %d source-sized shapes", stream.gltf.shapes.len());
	if (stream.gltf.physics_joints.len() != 1) return;

	gltf::PhysicsJoint settings = stream.gltf.physics_joints[0];
	test::@check(settings.linear_limits.len() == 1,
		"the attachment has %d translation rows, not one weld", settings.linear_limits.len());
	if (settings.linear_limits.len() == 1)
	{
		gltf::Limit locked = settings.linear_limits[0];
		test::@check(locked.axes.x == 1 && locked.axes.y == 1 && locked.axes.z == 1
			&& locked.min == 0.0f && locked.max == 0.0f,
			"the three attachment translations are not locked at zero");
	}

	test::@check(settings.angular_limits.len() == 3,
		"the independent X/Y/Z table became %d angular rows", settings.angular_limits.len());
	foreach (usz axis, limit : settings.angular_limits)
	{
		if (axis >= 3) break;
		float axes = limit.axes.x + limit.axes.y + limit.axes.z;
		test::@check(axes == 1.0f && limit.axes[axis] == 1.0f,
			"angular row %d is not its own scalar axis", axis);
		float expected_min = authored.axes[axis].allowed
			? authored.axes[axis].minimum : authored.axes[axis].locked;
		float expected_max = authored.axes[axis].allowed
			? authored.axes[axis].maximum : authored.axes[axis].locked;
		test::@check(near(limit.min, expected_min) && near(limit.max, expected_max),
			"axis %d came back [%.4f, %.4f], expected [%.4f, %.4f]",
			axis, limit.min, limit.max, expected_min, expected_max);
	}

	int parent_frame = node_named(&stream, "knee.constraint.parent");
	int child_frame = node_named(&stream, "knee.constraint.child");
	test::@check(parent_frame >= 0 && child_frame >= 0,
		"the two named constraint attachment frames are missing");
	if (parent_frame < 0 || child_frame < 0) return;

	gltf::Node* a = stream.gltf.nodes.get_ref(parent_frame);
	gltf::Node* b = stream.gltf.nodes.get_ref(child_frame);
	test::@check(a.parent != null && b.parent != null,
		"a constraint attachment is not parented to its adjacent body");
	if (a.parent != null && b.parent != null)
	{
		test::@check(a.parent.name == "hips" && b.parent.name == "knee",
			"the attachments belong to '%s' and '%s', not hips and knee",
			a.parent.name, b.parent.name);
	}
	test::@check(b.joint == 0 && b.connected_node == parent_frame,
		"the child attachment does not name the parent attachment once");
	test::@check(a.joint < 0, "the KHR joint was duplicated on both attachments");

	Vec3 pivot = skeleton.joints[knee];
	test::@check(near_vec(a.world_position(), pivot) && near_vec(b.world_position(), pivot),
		"the attachment frames are not coincident at the skeleton joint");
	test::@check(near_quat(a.world_rotation(), b.world_rotation()),
		"the coincident attachments disagree about their angular frame");
	crig::JointLimitFrame expected = crig::joint_limit_frame_by_index(skeleton, knee, (int)foot);
	test::@check(expected.usable() && near_quat(a.world_rotation(), expected.rotation),
		"the KHR axes do not match crig's bone-local limit frame");
}

fn rig::TriMesh constraint_triangle(Vec3[]* positions_out, uint[]* indices_out)
{
	Vec3[] positions = alloc::new_array(mem, Vec3, 3);
	positions[0] = { -0.1f, 0, 0 };
	positions[1] = { 0.1f, 0, 0 };
	positions[2] = { 0, -2, 0.1f };
	uint[] indices = alloc::new_array(mem, uint, 3);
	indices[0] = 0;
	indices[1] = 1;
	indices[2] = 2;
	*positions_out = positions;
	*indices_out = indices;
	return { .positions = positions, .indices = indices };
}

fn void khr_writer_emits_independent_limits_and_coincident_pack_frames() @test
{
	ConstraintFixture fixture;
	fixture.open();
	defer fixture.close();
	crig::JointRotationLimits limits = knee_limits(fixture.knee, fixture.foot);
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the knee constraint was refused");

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	String[3] names;
	foreach (usz joint, id : ids) names[joint] = fixture.doc.find(id).name;
	crig::ConstraintRig constraints = crig::constraint_rig_of(mem, &fixture.doc,
		&skeleton, ids);
	defer constraints.free(mem);

	Vec3[] positions;
	uint[] indices;
	rig::TriMesh body = constraint_triangle(&positions, &indices);
	defer
	{
		alloc::free(mem, positions);
		alloc::free(mem, indices);
		(void)file::delete(PACK_CONSTRAINT_GLB);
	}
	if (catch fault error = crig::export_pack_glb(mem, PACK_CONSTRAINT_GLB,
		&skeleton, names[..], {}, body, {}, {}, constraints))
	{
		test::@check(false, "the constraint pack could not be written (%s)", error);
		return;
	}

	int knee = joint_of(ids, fixture.knee);
	int foot = joint_of(ids, fixture.foot);
	if (knee < 0 || foot < 0) { test::@check(false, "the constrained chain did not build"); return; }
	inspect_constraint_file(PACK_CONSTRAINT_GLB, &skeleton, (usz)knee, (usz)foot, limits);

	crig::AnimPackReport report;
	crig::AnimPack? reopened = crig::read_pack(mem, PACK_CONSTRAINT_GLB, &report);
	if (catch reopened)
	{
		test::@check(false, "the constrained pack did not read back");
		return;
	}
	crig::AnimPack pack = reopened;
	defer pack.free(mem);
	int read_knee = named_joint(&pack, "knee");
	int read_foot = named_joint(&pack, "foot");
	test::@check(report.constraints_read == 1 && report.constraints_foreign == 0,
		"the reader reported %d exact and %d foreign constraints",
		report.constraints_read, report.constraints_foreign);
	test::@check(read_knee >= 0 && read_foot >= 0,
		"the constrained joints did not come back by name");
	if (read_knee >= 0 && read_foot >= 0)
	{
		crig::JointConstraint read = pack.constraints.joints[(usz)read_knee];
		test::@check(read.status == crig::JointConstraintStatus.EXACT,
			"the crig-authored KHR graph did not become an exact row");
		test::@check(read.frame_intent == crig::ConstraintFrameIntent.PRIMARY_CHILD
			&& read.primary_child == read_foot,
			"the primary-child frame intent did not round-trip");
		foreach (usz axis, authored : limits.axes)
		{
			test::@check(read.axes[axis].same(authored),
				"axis %d lost its authored enabled/parked values", axis);
		}
	}
}

fn void rigged_export_converts_attachment_frames_out_of_bone_aligned_nodes() @test
{
	ConstraintFixture fixture;
	fixture.open();
	defer fixture.close();
	crig::JointRotationLimits limits = knee_limits(fixture.knee, fixture.foot);
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the knee constraint was refused");

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	String[3] names;
	foreach (usz joint, id : ids) names[joint] = fixture.doc.find(id).name;
	crig::ConstraintRig constraints = crig::constraint_rig_of(mem, &fixture.doc,
		&skeleton, ids);
	defer constraints.free(mem);

	Vec3[] positions;
	uint[] indices;
	rig::TriMesh body = constraint_triangle(&positions, &indices);
	defer
	{
		alloc::free(mem, positions);
		alloc::free(mem, indices);
		(void)file::delete(RIGGED_CONSTRAINT_GLB);
	}
	if (catch fault error = crig::export_rigged_animated_glb(mem,
		RIGGED_CONSTRAINT_GLB, body, &skeleton, names[..], {}, {}, "Body", 4, {}, constraints))
	{
		test::@check(false, "the constraint-only rigged file could not be written (%s)", error);
		return;
	}

	int knee = joint_of(ids, fixture.knee);
	int foot = joint_of(ids, fixture.foot);
	if (knee < 0 || foot < 0) { test::@check(false, "the constrained chain did not build"); return; }
	inspect_constraint_file(RIGGED_CONSTRAINT_GLB, &skeleton, (usz)knee, (usz)foot, limits);
}

fn void adjusted_constraint_frames_round_trip_as_bone_relative_intent() @test
{
	ConstraintFixture fixture;
	fixture.open();
	defer fixture.close();

	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(&fixture.doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
		(void)file::delete(PACK_CONSTRAINT_GLB);
	}
	int knee = joint_of(ids, fixture.knee);
	int foot = joint_of(ids, fixture.foot);
	if (knee < 0 || foot < 0) { test::@check(false, "the constrained chain did not build"); return; }

	crig::JointRotationLimits limits = knee_limits(fixture.knee, fixture.foot);
	crig::JointLimitFrame base = crig::joint_limit_frame_by_index(&skeleton,
		(usz)knee, foot);
	Quaternionf adjustment = quaternion::from_euler{float}(0.15f, -0.2f, 0.35f);
	limits.has_saved_frame = true;
	limits.saved_frame = base.rotation.mul(adjustment).normalize();
	test::@check(fixture.doc.set_rotation_limits(fixture.knee, limits),
		"the adjusted knee constraint was refused");

	String[3] names;
	foreach (usz joint, id : ids) names[joint] = fixture.doc.find(id).name;
	crig::ConstraintRig constraints = crig::constraint_rig_of(mem, &fixture.doc,
		&skeleton, ids);
	defer constraints.free(mem);
	Vec3[] positions;
	uint[] indices;
	rig::TriMesh body = constraint_triangle(&positions, &indices);
	defer
	{
		alloc::free(mem, positions);
		alloc::free(mem, indices);
	}
	crig::export_pack_glb(mem, PACK_CONSTRAINT_GLB, &skeleton, names[..], {}, body,
		{}, {}, constraints)!!;

	crig::AnimPack pack = crig::read_pack(mem, PACK_CONSTRAINT_GLB)!!;
	defer pack.free(mem);
	int read_knee = named_joint(&pack, "knee");
	int read_foot = named_joint(&pack, "foot");
	if (read_knee < 0 || read_foot < 0)
	{
		test::@check(false, "the adjusted constraint joints did not read back");
		return;
	}
	crig::JointConstraint read = pack.constraints.joints[(usz)read_knee];
	test::@check(read.status == crig::JointConstraintStatus.EXACT
		&& read.frame_intent == crig::ConstraintFrameIntent.ADJUSTED_PRIMARY_CHILD
		&& read.primary_child == read_foot,
		"the adjusted primary-child intent did not survive KHR round-trip");
	test::@check(near_quat(read.frame_adjustment, adjustment),
		"the bone-relative frame adjustment changed on read");
}

fn void write_foreign_constraint_fixture(
	String path,
	bool cone,
	bool driven,
	bool offset_frame)
{
	gltf::GltfBuilder builder = gltf::builder(mem);
	defer builder.free();
	uint hips = builder.add_node("hips");
	uint knee = builder.add_node("knee", translation: { 0, -1, 0 });
	uint foot = builder.add_node("foot", translation: { 0, -1, 0 });
	builder.add_child(hips, knee);
	builder.add_child(knee, foot);
	builder.add_root(hips);
	uint[3] bones = { hips, knee, foot };
	(void)builder.add_skin("rig", bones[..], skeleton: (int)hips);

	uint parent_frame = builder.add_node("foreign.parent", translation: { 0, -1, 0 });
	uint child_frame = builder.add_node("foreign.child",
		translation: offset_frame ? (Vec3){ 0.1f, 0, 0 } : (Vec3){ 0, 0, 0 });
	builder.add_child(hips, parent_frame);
	builder.add_child(knee, child_frame);

	gltf::PhysicsJoint settings;
	settings.angular_limits.init(mem);
	settings.linear_limits.init(mem);
	settings.drives.init(mem);
	defer settings.free();
	settings.linear_limits.push({ .axes = { 1, 1, 1 }, .min = 0, .max = 0 });
	if (cone)
	{
		settings.angular_limits.push({ .axes = { 1, 0, 1 }, .min = 0, .max = 0.7f });
	}
	else
	{
		settings.angular_limits.push({ .axes = { 1, 0, 0 }, .min = -0.2f, .max = 0.8f });
		settings.angular_limits.push({ .axes = { 0, 1, 0 }, .min = 0, .max = 0 });
		settings.angular_limits.push({ .axes = { 0, 0, 1 }, .min = 0, .max = 0 });
	}
	if (driven)
	{
		settings.drives.push({
			.type = gltf::DriveType.ANGULAR,
			.drive = gltf::DriveMode.FORCE,
			.axis = 2,
			.stiffness = 42.0f,
			.damping = 0.25f,
		});
	}
	uint joint = builder.add_physics_joint_settings(settings);
	builder.add_node_joint(child_frame, parent_frame, joint);
	builder.save_glb(path)!!;
}

fn void foreign_cones_and_drives_are_reported_and_passed_through() @test
{
	defer
	{
		(void)file::delete(FOREIGN_CONSTRAINT_GLB);
		(void)file::delete(FOREIGN_ROUNDTRIP_GLB);
	}
	write_foreign_constraint_fixture(FOREIGN_CONSTRAINT_GLB, true, true, false);
	crig::AnimPackReport report;
	crig::AnimPack pack = crig::read_pack(mem, FOREIGN_CONSTRAINT_GLB, &report)!!;
	defer pack.free(mem);
	test::@check(report.constraints_read == 0 && report.constraints_foreign == 1,
		"the cone/drive graph was not classified as one foreign constraint");
	test::@check(report.constraint_cones == 1 && report.constraint_drives == 1,
		"the report lost the cone (%d) or drive (%d) diagnostic",
		report.constraint_cones, report.constraint_drives);
	test::@check(pack.constraints.foreign.len == 1
		&& pack.constraints.unsupported() == 1,
		"the unsupported graph was not retained as owned pass-through data");

	Vec3[] positions;
	uint[] indices;
	rig::TriMesh body = constraint_triangle(&positions, &indices);
	defer
	{
		alloc::free(mem, positions);
		alloc::free(mem, indices);
	}
	crig::export_pack_glb(mem, FOREIGN_ROUNDTRIP_GLB, &pack.rest,
		pack.joint_names, {}, body, {}, {}, pack.constraints)!!;
	gltf::GltfStream stream = gltf::open(FOREIGN_ROUNDTRIP_GLB, mem)!!;
	defer stream.close();
	test::@check(stream.gltf.physics_joints.len() == 1,
		"pass-through wrote %d settings records, not 1", stream.gltf.physics_joints.len());
	if (stream.gltf.physics_joints.len() == 1)
	{
		gltf::PhysicsJoint settings = stream.gltf.physics_joints[0];
		test::@check(settings.angular_limits.len() == 1
			&& settings.angular_limits[0].axes.x == 1
			&& settings.angular_limits[0].axes.z == 1,
			"the foreign cone was split or changed");
		test::@check(settings.drives.len() == 1
			&& near(settings.drives[0].stiffness, 42.0f),
			"the foreign drive was discarded or changed");
	}
}

fn void malformed_attachment_frames_are_reported_not_projected() @test
{
	defer (void)file::delete(FOREIGN_CONSTRAINT_GLB);
	write_foreign_constraint_fixture(FOREIGN_CONSTRAINT_GLB, false, false, true);
	crig::AnimPackReport report;
	crig::AnimPack pack = crig::read_pack(mem, FOREIGN_CONSTRAINT_GLB, &report)!!;
	defer pack.free(mem);
	test::@check(report.constraints_read == 0 && report.constraints_foreign == 1
		&& report.constraint_graphs == 1,
		"the noncoincident attachments were not reported as a foreign graph");
	int knee = named_joint(&pack, "knee");
	if (knee >= 0)
	{
		test::@check(pack.constraints.joints[(usz)knee].status
			== crig::JointConstraintStatus.FREE,
			"a malformed attachment graph became an editable knee limit");
	}
}

// ---------------------------------------------------------------------------
// P4: applying reusable constraints with a fitted body plan

Vec3[8] fit_box_positions @local = {
	{ -2, -3, -1 }, { 2, -3, -1 }, { 2, 3, -1 }, { -2, 3, -1 },
	{ -2, -3, 1 }, { 2, -3, 1 }, { 2, 3, 1 }, { -2, 3, 1 },
};

uint[36] fit_box_indices @local = {
	4, 5, 6, 4, 6, 7,  0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5,  0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2,  0, 1, 5, 0, 5, 4,
};

fn crig::JointConstraint exact_constraint(
	int primary,
	crig::ConstraintFrameIntent intent,
	Quaternionf adjustment = quaternion::IDENTITY)
{
	crig::JointRotationLimits defaults = crig::unconstrained_rotation(0);
	return {
		.status = crig::JointConstraintStatus.EXACT,
		.axes = defaults.axes,
		.frame_intent = intent,
		.primary_child = primary,
		.frame_adjustment = adjustment,
		.frame_status = crig::JointLimitFrameStatus.READY,
	};
}

fn void fitted_templates_apply_exact_constraints_in_one_undo_step() @test
{
	rig::TriMesh body = {
		.positions = fit_box_positions[..],
		.indices = fit_box_indices[..],
	};
	crig::AppState app = crig::new_app(body);
	defer app.free();

	// Existing authored work must come back whole when the fitted template is
	// undone, including its own sparse limit row.
	uint old_root = app.doc.add_dot({ 0, 0, 0 }, "old_root");
	uint old_tip = app.doc.add_dot({ 0, 1, 0 }, "old_tip");
	app.doc.connect(old_root, old_tip);
	crig::JointRotationLimits old_limits = crig::unconstrained_rotation(old_root);
	old_limits.constrained = true;
	old_limits.axes[2] = { .allowed = false, .locked = 0.3f };
	test::@check(app.doc.set_rotation_limits(old_root, old_limits),
		"the old rig's limit fixture was refused");
	app.undo_stack.clear();

	crig::PresetDot[5] dots = {
		{ .name = "root", .at = { 0.50f, 0.88f, 0.50f }, .parent = -1 },
		{ .name = "upper", .at = { 0.38f, 0.66f, 0.42f }, .parent = 0 },
		{ .name = "knee", .at = { 0.27f, 0.43f, 0.36f }, .parent = 1 },
		{ .name = "foot", .at = { 0.43f, 0.18f, 0.70f }, .parent = 2 },
		{ .name = "toe", .at = { 0.58f, 0.10f, 0.90f }, .parent = 3, .optional = true },
	};
	crig::Preset preset = {
		.name = "Constraint fixture",
		.plan = "constraint-fixture",
		.dots = dots[..],
		// Deliberately unlike the target box. Angles and frame adjustment are
		// dimensionless and must survive without copying a source-space frame.
		.extent = { 1, 2, 4 },
	};

	Quaternionf adjustment = quaternion::from_euler{float}(0.22f, -0.31f, 0.17f);
	crig::JointConstraint[5] rows;
	foreach (&row : rows)
	{
		*row = { .status = crig::JointConstraintStatus.FREE, .primary_child = -1,
			.frame_adjustment = quaternion::IDENTITY,
			.frame_status = crig::JointLimitFrameStatus.READY };
	}
	rows[2] = exact_constraint(3,
		crig::ConstraintFrameIntent.ADJUSTED_PRIMARY_CHILD, adjustment);
	rows[2].axes[0] = { .allowed = true, .minimum = -0.25f, .maximum = 1.75f };
	rows[2].axes[1] = { .allowed = false, .minimum = -0.8f, .maximum = 0.9f, .locked = 0.12f };
	rows[2].axes[2] = { .allowed = true, .minimum = -0.4f, .maximum = 0.35f };

	// `toe` is optional, so both a constraint on it and a requested primary
	// child pointing to it have to be reported rather than guessed elsewhere.
	rows[3] = exact_constraint(4, crig::ConstraintFrameIntent.PRIMARY_CHILD);
	rows[4] = exact_constraint(-1, crig::ConstraintFrameIntent.AUTOMATIC);
	crig::ForeignConstraint[1] foreign;
	crig::ConstraintRig constraints = {
		.joints = rows[..],
		.foreign = foreign[..],
		.skipped = 1,
	};

	app.apply_preset(preset, preset.plan, {}, constraints);
	crig::Dot* knee = app.dot_named("knee");
	crig::Dot* foot = app.dot_named("foot");
	test::@check(knee != null && foot != null && app.doc.dots.len() == 4,
		"the required target chain was not fitted without its optional toe");
	if (!knee || !foot) return;

	crig::JointRotationLimits landed = app.doc.rotation_limits_of(knee.id);
	test::@check(landed.constrained && landed.primary_child == foot.id,
		"the exact knee constraint did not map its named primary child");
	test::@check(landed.axes[0].same(rows[2].axes[0])
		&& landed.axes[1].same(rows[2].axes[1])
		&& landed.axes[2].same(rows[2].axes[2]),
		"the fitted constraint changed an axis value");
	test::@check(landed.has_saved_frame,
		"the fitted constraint lost its bone-relative frame adjustment");

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits automatic = landed;
	automatic.has_saved_frame = false;
	automatic.saved_frame = quaternion::IDENTITY;
	crig::JointLimitFrame target_base = crig::joint_limit_frame(
		&view.skeleton, view.dot_ids, automatic);
	test::@check(target_base.usable(), "the fitted target frame is unusable");
	if (target_base.usable())
	{
		Quaternionf expected = target_base.rotation.mul(adjustment).normalize();
		test::@check(near_quat(landed.saved_frame, expected),
			"the adjustment was not rebuilt against the fitted target bone");
		test::@check(!near_quat(landed.saved_frame, adjustment),
			"the source-relative adjustment was copied as an absolute target frame");
	}
	test::@check(app.notice().contains("1 joint limit, 4 didn't match"),
		"the fit did not report missing and foreign constraints (%s)", app.notice());

	// One undo crosses the whole operation. A second should not be needed to
	// remove constraints separately from the newly fitted dots.
	test::@check(app.undo(), "the fitted preset did not enter history");
	test::@check(app.dot_named("old_root") != null && app.dot_named("knee") == null,
		"one undo did not restore the replaced rig");
	test::@check(app.doc.rotation_limits_of(old_root).constrained
		&& !app.undo_stack.can_undo(),
		"one undo did not restore the old limits or left part of the fit behind");

	test::@check(app.redo(), "the fitted preset could not be redone");
	knee = app.dot_named("knee");
	test::@check(knee != null && app.dot_named("old_root") == null,
		"redo did not replace the old rig again");
	if (knee)
	{
		test::@check(app.doc.rotation_limits_of(knee.id).constrained,
			"redo restored the fitted dots without their constraint");
	}
}

// ---------------------------------------------------------------------------
// P5: target-derived physical bodies

const String PHYSICAL_BODY_GLB = "test/out_constraint_bodies.glb";
const String PHYSICAL_BODY_BASELINE_GLB = "test/out_constraint_bodies_baseline.glb";
const String PHYSICAL_BODY_COEXIST_GLB = "test/out_constraint_bodies_coexist.glb";

alias P5Vec3List = List{Vec3};
alias P5UintList = List{uint};
alias P5FloatList = List{float};

fn void p5_weights(P5FloatList* weights, usz joint, usz joints)
{
	for (usz j = 0; j < joints; j++) weights.push(j == joint ? 1.0f : 0.0f);
}

fn void p5_box(P5Vec3List* positions, P5UintList* indices,
	P5FloatList* weights, Vec3 low, Vec3 high, usz joint, usz joints)
{
	uint first = (uint)positions.len();
	Vec3[8] corners = {
		{ low.x, low.y, low.z }, { high.x, low.y, low.z },
		{ high.x, high.y, low.z }, { low.x, high.y, low.z },
		{ low.x, low.y, high.z }, { high.x, low.y, high.z },
		{ high.x, high.y, high.z }, { low.x, high.y, high.z },
	};
	foreach (corner : corners)
	{
		positions.push(corner);
		p5_weights(weights, joint, joints);
	}
	uint[36] faces = {
		0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7,
		0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2,
		0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
	};
	foreach (face : faces) indices.push(first + face);
}

fn rig::TriMesh p5_target_mesh(float[]* dense)
{
	const usz JOINTS = 4;
	P5Vec3List positions;
	P5UintList indices;
	P5FloatList weights;
	positions.init(mem);
	indices.init(mem);
	weights.init(mem);
	defer
	{
		positions.free();
		indices.free();
		weights.free();
	}

	// More source points than P5 permits in one hull. They lie on an ellipsoid,
	// so without support reduction most would survive QuickHull.
	for (usz i = 0; i < 96; i++)
	{
		float z = 1.0f - 2.0f * ((float)i + 0.5f) / 96.0f;
		float ring = math::sqrt(math::max(0.0f, 1.0f - z * z));
		float angle = (float)i * 2.39996323f;
		positions.push({
			0.30f * ring * math::cos(angle),
			0.30f + 0.50f * z,
			0.25f * ring * math::sin(angle),
		});
		p5_weights(&weights, 0, JOINTS);
	}

	// The fork owns only this narrow middle region. Child geometry sits far to
	// either side, making a borrowed-child branch rule immediately visible.
	p5_box(&positions, &indices, &weights,
		{ -0.18f, 0.82f, -0.15f }, { 0.18f, 1.35f, 0.15f }, 1, JOINTS);
	p5_box(&positions, &indices, &weights,
		{ -1.25f, 1.70f, -0.12f }, { -0.75f, 2.25f, 0.12f }, 2, JOINTS);
	// Joint 3 deliberately owns no vertices: a terminal body must be reported
	// missing rather than extrapolated from its parent or mirrored sibling.

	*dense = weights.to_array(mem);
	return {
		.positions = positions.to_array(mem),
		.indices = indices.to_array(mem),
	};
}

fn crig::TargetPhysicalBody* p5_body(crig::TargetPhysicalBodies* bodies,
	usz joint)
{
	foreach (&body : bodies.bodies) if (body.joint == joint) return body;
	return null;
}

fn void target_hulls_are_small_weighted_and_form_a_complete_available_graph() @test
{
	Vec3[4] joints = {
		{ 0, 0, 0 }, { 0, 1, 0 }, { -1, 2, 0 }, { 1, 2, 0 },
	};
	int[4] parents = { -1, 0, 1, 1 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[4] names = { "root", "branch", "tip_L", "tip_R" };

	crig::JointConstraint[4] rows;
	foreach (&row : rows)
	{
		*row = { .status = crig::JointConstraintStatus.FREE,
			.primary_child = -1,
			.frame_adjustment = quaternion::IDENTITY,
			.frame_status = crig::JointLimitFrameStatus.READY };
	}
	rows[1] = exact_constraint(2, crig::ConstraintFrameIntent.PRIMARY_CHILD);
	rows[2] = exact_constraint(-1, crig::ConstraintFrameIntent.AUTOMATIC);
	rows[3] = exact_constraint(-1, crig::ConstraintFrameIntent.AUTOMATIC);
	crig::ConstraintRig constraints = { .joints = rows[..] };

	float[] dense;
	rig::TriMesh mesh = p5_target_mesh(&dense);
	defer
	{
		mesh.free(mem);
		alloc::free(mem, dense);
		(void)file::delete(PHYSICAL_BODY_GLB);
		(void)file::delete(PHYSICAL_BODY_BASELINE_GLB);
		(void)file::delete(PHYSICAL_BODY_COEXIST_GLB);
	}

	gltf::SkinBinding binding = gltf::sparsify_weights(mem, dense,
		mesh.positions.len, skeleton.len(), 4)!!;
	defer binding.free(mem);
	crig::TargetPhysicalBodies bodies = crig::target_physical_bodies(mem,
		mesh, &skeleton, binding, constraints);
	defer bodies.free(mem);

	test::@check(bodies.requested == 4 && bodies.bodies.len == 3
		&& bodies.skipped == 1,
		"P5 built %d/%d bodies and skipped %d, expected the empty terminal alone to be omitted",
		bodies.bodies.len, bodies.requested, bodies.skipped);
	crig::TargetPhysicalBody* root = p5_body(&bodies, 0);
	crig::TargetPhysicalBody* branch = p5_body(&bodies, 1);
	crig::TargetPhysicalBody* terminal = p5_body(&bodies, 2);
	test::@check(root != null && branch != null && terminal != null
		&& p5_body(&bodies, 3) == null,
		"the generated bodies do not match the weighted root/branch/terminal regions");
	if (!root || !branch || !terminal) return;

	test::@check(root.positions.len <= crig::PHYSICAL_BODY_MAX_VERTICES,
		"a %d-point root region produced %d hull vertices past the %d-point cap",
		96, root.positions.len, crig::PHYSICAL_BODY_MAX_VERTICES);
	test::@check(branch.branch && !branch.terminal && terminal.terminal,
		"branch/terminal topology was not classified explicitly");
	float branch_x = 0.0f;
	foreach (point : branch.positions) branch_x = math::max(branch_x,
		math::abs(point.x));
	test::@check(branch_x < 0.30f,
		"the fork hull reached %.3f into child geometry instead of using its own weighted region",
		branch_x);
	test::@check(near(root.mass, root.volume * crig::PHYSICAL_BODY_DENSITY)
		&& near(branch.mass, branch.volume * crig::PHYSICAL_BODY_DENSITY)
		&& near(terminal.mass, terminal.volume * crig::PHYSICAL_BODY_DENSITY),
		"target body mass was not derived from final hull volume");
	test::@check(bodies.payload_bytes < 6 * 1024,
		"three small collision hulls claim %.2f KiB of raw geometry",
		(float)bodies.payload_bytes / 1024.0f);

	crig::PhysicalBodyWriteReport report;
	if (catch fault error = crig::export_pack_glb(mem, PHYSICAL_BODY_GLB,
		&skeleton, names[..], {}, mesh, { .name = "P5 target" }, {},
		constraints, dense, &report))
	{
		test::@check(false, "the target physical graph could not be written (%s)", error);
		return;
	}
	crig::export_pack_glb(mem, PHYSICAL_BODY_BASELINE_GLB, &skeleton,
		names[..], {}, mesh, { .name = "P5 baseline" })!!;
	test::@check(report.requested == 4 && report.written == 3
		&& report.skipped == 1 && report.payload_bytes == bodies.payload_bytes,
		"the writer report disagrees with the generated hull set");

	char[] physical_bytes = file::load(mem, PHYSICAL_BODY_GLB)!!;
	defer alloc::free(mem, physical_bytes);
	char[] baseline_bytes = file::load(mem, PHYSICAL_BODY_BASELINE_GLB)!!;
	defer alloc::free(mem, baseline_bytes);
	test::@check(physical_bytes.len < baseline_bytes.len + 24 * 1024,
		"three bodies and their constraints grew the GLB by %.2f KiB",
		(float)(physical_bytes.len - baseline_bytes.len) / 1024.0f);

	gltf::GltfStream stream = gltf::open(PHYSICAL_BODY_GLB, mem)!!;
	defer stream.close();
	test::@check(stream.gltf.colliders.len() == 3
		&& stream.gltf.motions.len() == 3,
		"the GLB carries %d colliders and %d motions, expected three available bodies",
		stream.gltf.colliders.len(), stream.gltf.motions.len());
	test::@check(stream.gltf.shapes.len() == 0,
		"target hulls were written as %d source-sized implicit shapes",
		stream.gltf.shapes.len());
	foreach (collider : stream.gltf.colliders)
	{
		test::@check(collider.convex_hull && collider.has_mesh()
			&& collider.mesh < stream.gltf.meshes.len(),
			"a physical body does not reference its own convex mesh resource");
		foreach (node : stream.gltf.nodes)
		{
			test::@check(node.mesh != collider.mesh,
				"collision-only hull mesh %d was also attached to a visual scene node",
				collider.mesh);
		}
	}
	foreach (node : stream.gltf.nodes)
	{
		if (node.joint >= 0)
		{
			test::@check(!node.enable_collision,
				"an adjacent constrained body pair was left colliding");
		}
	}

	int root_node = node_named(&stream, "root");
	int branch_node = node_named(&stream, "branch");
	int left_node = node_named(&stream, "tip_L");
	int right_node = node_named(&stream, "tip_R");
	test::@check(root_node >= 0 && branch_node >= 0 && left_node >= 0
		&& right_node >= 0, "the body-bearing skeleton nodes are missing");
	if (root_node >= 0 && branch_node >= 0 && left_node >= 0 && right_node >= 0)
	{
		gltf::Node* root_out = stream.gltf.nodes.get_ref(root_node);
		gltf::Node* branch_out = stream.gltf.nodes.get_ref(branch_node);
		gltf::Node* left_out = stream.gltf.nodes.get_ref(left_node);
		gltf::Node* right_out = stream.gltf.nodes.get_ref(right_node);
		test::@check(root_out.motion >= 0
			&& stream.gltf.motions[(uint)root_out.motion].is_kinematic,
			"the physical component root is not its kinematic anchor");
		test::@check(branch_out.motion >= 0 && left_out.motion >= 0
			&& !stream.gltf.motions[(uint)branch_out.motion].is_kinematic
			&& !stream.gltf.motions[(uint)left_out.motion].is_kinematic,
			"connected child bodies were not emitted as dynamic");
		test::@check(right_out.motion < 0 && right_out.collider < 0,
			"the geometry-free terminal received an invented body");
	}

	// Reopening a physical template recovers anatomical limits but does not turn
	// each target rigid body into an old-style secondary-motion joint.
	crig::AnimPackReport reopened_report;
	crig::AnimPack reopened = crig::read_pack(mem, PHYSICAL_BODY_GLB,
		&reopened_report)!!;
	defer reopened.free(mem);
	test::@check(reopened_report.constraints_read == 3
		&& reopened.physics.joints.len == 0
		&& reopened.physics.colliders.len == 0
		&& reopened.physics.skipped == 0,
		"P5 round-trip recovered %d constraints but projected bodies into %d jiggle joints, %d capsules and %d skips",
		reopened_report.constraints_read, reopened.physics.joints.len,
		reopened.physics.colliders.len, reopened.physics.skipped);
	test::@check(reopened.mesh.positions.len == mesh.positions.len,
		"collision-only hull resources leaked into the pack's visible target mesh");

	// A constrained bone may still use the legacy secondary-motion system while
	// that workflow is being replaced. Since one glTF node cannot carry two
	// colliders, P5 preserves the existing body and reports it instead of silently
	// overwriting its sphere, damping and gravity with a target hull.
	crig::JiggleParams jiggle_params = {
		.stiffness = 2.0f,
		.damping = 0.30f,
		.gravity = 0.25f,
		.radius = 0.04f,
	};
	crig::JiggleJoint[1] jiggle_joints = {
		{ .joint = 1, .params = jiggle_params },
	};
	crig::RigPhysics existing_physics = { .joints = jiggle_joints[..] };
	crig::PhysicalBodyWriteReport coexist_report;
	crig::export_pack_glb(mem, PHYSICAL_BODY_COEXIST_GLB, &skeleton,
		names[..], {}, mesh, { .name = "P5 coexist" }, existing_physics,
		constraints, dense, &coexist_report)!!;
	test::@check(coexist_report.requested == 4 && coexist_report.written == 2
		&& coexist_report.skipped == 1 && coexist_report.preserved_jiggle == 1,
		"P5 coexistence wrote %d hulls, skipped %d and preserved %d jiggle bodies",
		coexist_report.written, coexist_report.skipped,
		coexist_report.preserved_jiggle);

	crig::AnimPackReport coexist_read_report;
	crig::AnimPack coexist = crig::read_pack(mem, PHYSICAL_BODY_COEXIST_GLB,
		&coexist_read_report)!!;
	defer coexist.free(mem);
	test::@check(coexist_read_report.constraints_read == 3
		&& coexist.physics.joints.len == 1 && coexist.physics.skipped == 0,
		"coexisting physical data reopened as %d constraints, %d jiggle joints and %d skips",
		coexist_read_report.constraints_read, coexist.physics.joints.len,
		coexist.physics.skipped);
	if (coexist.physics.joints.len == 1)
	{
		crig::JiggleJoint held = coexist.physics.joints[0];
		test::@check(held.joint == 1
			&& near(held.params.stiffness, jiggle_params.stiffness)
			&& near(held.params.damping, jiggle_params.damping)
			&& near(held.params.gravity, jiggle_params.gravity)
			&& near(held.params.radius, jiggle_params.radius),
			"the existing branch jiggle body changed while P5 hulls were added");
	}
}

// ---------------------------------------------------------------------------
// P6: complete physical-export acceptance on a differently proportioned target

const String P6_SOURCE_GLB = "test/out_physical_source.glb";
const String P6_TARGET_GLB = "test/out_physical_target.glb";

alias P6UshortList = List{ushort};

struct P6HullMeasure
{
	rig::Bounds bounds;
	float volume;
	usz vertices;
	usz triangles;
	bool valid;
}

// A closed prism with several rings gives every member of a straight chain a
// real three-dimensional weighted surface region. Source and target use
// different axis scales, which makes copied source hulls easy to detect.
fn rig::TriMesh p6_prism(Vec3 low, Vec3 high, usz segments)
{
	P5Vec3List positions;
	P5UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	for (usz ring = 0; ring <= segments; ring++)
	{
		float phase = (float)ring / (float)segments;
		float y = low.y + (high.y - low.y) * phase;
		positions.push({ low.x, y, low.z });
		positions.push({ high.x, y, low.z });
		positions.push({ high.x, y, high.z });
		positions.push({ low.x, y, high.z });
	}

	for (usz ring = 0; ring < segments; ring++)
	{
		uint here = (uint)(ring * 4);
		uint next = here + 4;
		for (uint side = 0; side < 4; side++)
		{
			uint across = (side + 1) % 4;
			indices.push(here + side);
			indices.push(here + across);
			indices.push(next + across);
			indices.push(here + side);
			indices.push(next + across);
			indices.push(next + side);
		}
	}

	uint top = (uint)(segments * 4);
	uint[12] caps = {
		0, 2, 1, 0, 3, 2,
		top, top + 1, top + 2, top, top + 2, top + 3,
	};
	foreach (index : caps) indices.push(index);

	return {
		.positions = positions.to_array(mem),
		.indices = indices.to_array(mem),
	};
}

fn float[] p6_rigid_weights(rig::TriMesh mesh, rig::Skeleton* skeleton)
{
	usz joints = skeleton.len();
	float[] dense = alloc::new_array(mem, float,
		(sz)(mesh.positions.len * joints));
	foreach (usz vertex, position : mesh.positions)
	{
		usz closest = 0;
		float distance = (position - skeleton.joints[0]).length_sq();
		for (usz joint = 1; joint < joints; joint++)
		{
			float candidate = (position - skeleton.joints[joint]).length_sq();
			if (candidate >= distance) continue;
			closest = joint;
			distance = candidate;
		}
		dense[vertex * joints + closest] = 1.0f;
	}
	return dense;
}

fn int p6_named_joint(String[] names, String name)
{
	foreach (usz joint, held : names) if (held == name) return (int)joint;
	return -1;
}

fn int p6_scalar_axis(Vec3 axes)
{
	int found = -1;
	for (usz axis = 0; axis < 3; axis++)
	{
		if (math::abs(axes[axis]) < 1.0e-6f) continue;
		if (math::abs(axes[axis] - 1.0f) >= 1.0e-6f || found >= 0) return -1;
		found = (int)axis;
	}
	return found;
}

fn bool p6_relative(float actual, float expected)
{
	float scale = math::max(1.0f, math::abs(expected));
	return math::abs(actual - expected) <= scale * 1.0e-4f;
}

// Read the collider bytes and reconstruct their rest-world bounds and volume.
// This deliberately uses the public glTF stream rather than crig's P5 builder.
fn P6HullMeasure p6_measure_hull(gltf::GltfStream* stream, int node_index)
{
	P6HullMeasure out = {};
	if (node_index < 0 || node_index >= (int)stream.gltf.nodes.len()) return out;
	gltf::Node* node = stream.gltf.nodes.get_ref(node_index);
	if (node.collider < 0 || node.collider >= (int)stream.gltf.colliders.len()) return out;
	gltf::Collider collider = stream.gltf.colliders[(uint)node.collider];
	if (!collider.convex_hull || !collider.has_mesh()
		|| collider.mesh >= (int)stream.gltf.meshes.len()) return out;

	gltf::Mesh mesh = stream.gltf.meshes[(uint)collider.mesh];
	if (mesh.primitives.len() != 1) return out;
	gltf::Primitive primitive = mesh.primitives[0];
	P5Vec3List local;
	P6UshortList indices;
	local.init(mem);
	indices.init(mem);
	defer
	{
		local.free();
		indices.free();
	}
	stream.@each_position(primitive; Vec3 position, sz index)
	{
		local.push(position);
	};
	stream.@each_index_as_ushort(primitive; ushort value, sz index)
	{
		indices.push(value);
	};
	if (local.len() < 4 || indices.len() < 12 || indices.len() % 3 != 0) return out;

	Vec3 origin = node.world_position();
	Quaternionf rotation = node.world_rotation();
	foreach (usz i, position : local)
	{
		Vec3 world = origin + rotation * position;
		if (i == 0)
		{
			out.bounds = { .min = world, .max = world };
		}
		else
		{
			out.bounds.min = math::min(out.bounds.min, world);
			out.bounds.max = math::max(out.bounds.max, world);
		}
	}

	double volume = 0.0;
	for (sz i = 0; i < indices.len(); i += 3)
	{
		usz a = indices[i];
		usz b = indices[i + 1];
		usz c = indices[i + 2];
		if (a >= (usz)local.len() || b >= (usz)local.len()
			|| c >= (usz)local.len()) return {};
		volume += (double)local[(sz)a].dot(
			local[(sz)b].cross(local[(sz)c])) / 6.0;
	}
	out.volume = (float)math::abs(volume);
	out.vertices = (usz)local.len();
	out.triangles = (usz)indices.len() / 3;
	out.valid = out.volume > 0.0f;
	return out;
}

// Independently inspect one KHR attachment pair and its scalar angular rows.
fn void p6_check_constraint_graph(
	gltf::GltfStream* stream,
	rig::Skeleton* skeleton,
	String[] names,
	uint[] joint_nodes,
	ConstraintRig constraints,
	usz joint)
{
	String parent_label = string::format(mem, "%s.constraint.parent", names[joint]);
	String child_label = string::format(mem, "%s.constraint.child", names[joint]);
	defer
	{
		parent_label.free(mem);
		child_label.free(mem);
	}
	int parent_attachment = node_named(stream, parent_label);
	int child_attachment = node_named(stream, child_label);
	test::@check(parent_attachment >= 0 && child_attachment >= 0,
		"%s is missing one of its two attachment nodes", names[joint]);
	if (parent_attachment < 0 || child_attachment < 0) return;

	gltf::Node* parent_frame = stream.gltf.nodes.get_ref(parent_attachment);
	gltf::Node* child_frame = stream.gltf.nodes.get_ref(child_attachment);
	usz parent = (usz)skeleton.parents[joint];
	test::@check(parent_frame.parent != null && child_frame.parent != null
		&& parent_frame.parent.index == joint_nodes[parent]
		&& child_frame.parent.index == joint_nodes[joint],
		"%s attachment nodes do not belong to the adjacent target bodies",
		names[joint]);
	test::@check(child_frame.connected_node == parent_attachment
		&& child_frame.joint >= 0
		&& child_frame.joint < (int)stream.gltf.physics_joints.len(),
		"%s does not connect its child attachment to its parent attachment",
		names[joint]);
	if (child_frame.joint < 0
		|| child_frame.joint >= (int)stream.gltf.physics_joints.len()) return;

	Vec3 pivot = skeleton.joints[joint];
	test::@check(near_vec(parent_frame.world_position(), pivot)
		&& near_vec(child_frame.world_position(), pivot),
		"%s attachment pair does not replay at the target pivot", names[joint]);
	JointConstraint expected = constraints.joints[joint];
	JointLimitFrame base = crig::joint_limit_frame_by_index(skeleton, joint,
		expected.primary_child);
	Quaternionf frame = expected.frame_intent.has_adjustment()
		? base.rotation.mul(expected.frame_adjustment).normalize()
		: base.rotation;
	test::@check(base.usable()
		&& near_quat(parent_frame.world_rotation(), frame)
		&& near_quat(child_frame.world_rotation(), frame),
		"%s attachment frame did not replay in the target bone frame", names[joint]);

	gltf::PhysicsJoint settings = stream.gltf.physics_joints[(uint)child_frame.joint];
	test::@check(settings.linear_limits.len() == 1
		&& near_vec(settings.linear_limits[0].axes, { 1, 1, 1 })
		&& near(settings.linear_limits[0].min, 0.0f)
		&& near(settings.linear_limits[0].max, 0.0f),
		"%s does not carry one zero-range XYZ translation weld", names[joint]);
	test::@check(settings.angular_limits.len() == 3,
		"%s carries %d angular rows rather than three independent axes",
		names[joint], settings.angular_limits.len());
	bool[3] seen;
	foreach (limit : settings.angular_limits)
	{
		int axis = p6_scalar_axis(limit.axes);
		test::@check(axis >= 0 && !seen[(usz)math::max(axis, 0)],
			"%s contains a coupled or duplicate angular row", names[joint]);
		if (axis < 0 || seen[(usz)axis]) continue;
		seen[(usz)axis] = true;
		JointAxisLimit wanted = expected.axes[(usz)axis];
		float minimum = wanted.allowed ? wanted.minimum : wanted.locked;
		float maximum = wanted.allowed ? wanted.maximum : wanted.locked;
		test::@check(near(limit.min, minimum) && near(limit.max, maximum),
			"%s axis %d changed from [%.3f, %.3f] to [%.3f, %.3f]",
			names[joint], axis, minimum, maximum, limit.min, limit.max);
	}
	test::@check(seen[0] && seen[1] && seen[2] && !child_frame.enable_collision,
		"%s lost an angular axis or enables adjacent-body collision", names[joint]);
}

fn void constrained_template_regenerates_a_complete_target_specific_khr_graph() @test
{
	defer
	{
		(void)file::delete(P6_SOURCE_GLB);
		(void)file::delete(P6_TARGET_GLB);
	}

	Vec3[4] source_joints = {
		{ 0, 1.5f, 0 }, { 0, 0.5f, 0 }, { 0, -0.5f, 0 }, { 0, -1.5f, 0 },
	};
	int[4] parents = { -1, 0, 1, 2 };
	String[4] source_names = { "root", "upper", "knee", "foot" };
	rig::Skeleton source_skeleton = {
		.joints = source_joints[..],
		.parents = parents[..],
	};
	rig::TriMesh source_mesh = p6_prism({ -0.5f, -2.0f, -0.5f },
		{ 0.5f, 2.0f, 0.5f }, 16);
	defer source_mesh.free(mem);
	float[] source_weights = p6_rigid_weights(source_mesh, &source_skeleton);
	defer alloc::free(mem, source_weights);

	JointConstraint[4] source_rows;
	foreach (&row : source_rows)
	{
		*row = exact_constraint(-1, ConstraintFrameIntent.AUTOMATIC);
		row.status = JointConstraintStatus.FREE;
	}
	Quaternionf adjustment = quaternion::from_euler{float}(0.17f, -0.23f, 0.31f);
	source_rows[1] = exact_constraint(2,
		ConstraintFrameIntent.ADJUSTED_PRIMARY_CHILD, adjustment);
	source_rows[1].axes[0] = { .allowed = true, .minimum = -0.35f, .maximum = 1.10f };
	source_rows[1].axes[1] = { .allowed = false, .locked = 0.12f };
	source_rows[1].axes[2] = { .allowed = true, .minimum = -0.45f, .maximum = 0.25f };
	source_rows[2] = exact_constraint(3, ConstraintFrameIntent.PRIMARY_CHILD);
	source_rows[2].axes[0] = { .allowed = true, .minimum = -0.10f, .maximum = 1.80f };
	source_rows[2].axes[1] = { .allowed = false, .locked = -0.08f };
	source_rows[2].axes[2] = { .allowed = false, .locked = 0.03f };
	source_rows[3] = exact_constraint(-1, ConstraintFrameIntent.AUTOMATIC);
	source_rows[3].axes[0] = { .allowed = true, .minimum = -0.30f, .maximum = 0.40f };
	source_rows[3].axes[1] = { .allowed = true, .minimum = -0.20f, .maximum = 0.20f };
	source_rows[3].axes[2] = { .allowed = false, .locked = 0.0f };
	ConstraintRig source_constraints = { .joints = source_rows[..] };

	PhysicalBodyWriteReport source_physical;
	crig::export_pack_glb(mem, P6_SOURCE_GLB, &source_skeleton,
		source_names[..], {}, source_mesh,
		{ .plan = "p6-chain", .name = "P6 source" }, {},
		source_constraints, source_weights, &source_physical)!!;
	test::@check(source_physical.complete() && source_physical.written == 4,
		"the source template did not begin as a complete four-body physical asset");

	AnimPackReport source_report;
	AnimPack source_pack = crig::read_pack(mem, P6_SOURCE_GLB, &source_report)!!;
	defer source_pack.free(mem);
	test::@check(source_pack.is_body_plan() && source_report.constraints_read == 3
		&& source_pack.physics.joints.len == 0 && source_pack.physics.skipped == 0,
		"the source physical template did not round-trip as three anatomical constraints");

	// The target is 3x as wide, 2x as tall and 2x as deep. Its fitted joint
	// spacing therefore doubles, while its collision hull cross-section changes
	// independently on X and Z.
	rig::TriMesh target_mesh = p6_prism({ -1.5f, -4.0f, -1.0f },
		{ 1.5f, 4.0f, 1.0f }, 16);
	defer target_mesh.free(mem);
	AppState target_app = crig::new_app(target_mesh);
	defer target_app.free();
	Preset source_preset = source_pack.preset(mem);
	defer crig::free_preset(mem, source_preset);
	target_app.apply_preset(source_preset, source_pack.plan, {}, source_pack.constraints);
	test::@check(target_app.notice().contains("· 3 joint limits"),
		"the source constraints did not all apply to the target (%s)", target_app.notice());

	RigView target = target_app.open_rig(mem)!!;
	defer target.free(mem);
	int source_upper = p6_named_joint(source_names[..], "upper");
	int source_knee = p6_named_joint(source_names[..], "knee");
	int target_upper = p6_named_joint(target.names, "upper");
	int target_knee = p6_named_joint(target.names, "knee");
	test::@check(source_upper >= 0 && source_knee >= 0
		&& target_upper >= 0 && target_knee >= 0,
		"the named source or target chain is incomplete");
	if (source_upper < 0 || source_knee < 0 || target_upper < 0 || target_knee < 0) return;
	float source_bone = (source_skeleton.joints[(usz)source_upper]
		- source_skeleton.joints[(usz)source_knee]).length();
	float target_bone = (target.skeleton.joints[(usz)target_upper]
		- target.skeleton.joints[(usz)target_knee]).length();
	test::@check(target_bone > source_bone * 1.8f,
		"the acceptance target was not actually reproportioned (%.3f vs %.3f)",
		target_bone, source_bone);

	ConstraintRig target_constraints = crig::constraint_rig_of(mem,
		&target_app.doc, &target.skeleton, target.dot_ids);
	defer target_constraints.free(mem);
	float[] target_weights = p6_rigid_weights(target_mesh, &target.skeleton);
	defer alloc::free(mem, target_weights);
	PhysicalBodyWriteReport target_physical;
	crig::export_rigged_animated_glb(mem, P6_TARGET_GLB, target_mesh,
		&target.skeleton, target.names, target_weights, {}, "P6 target", 4,
		{}, target_constraints, &target_physical)!!;
	test::@check(target_physical.complete() && target_physical.requested == 4
		&& target_physical.written == 4,
		"the fitted target exported %d/%d bodies with %d omissions",
		target_physical.written, target_physical.requested, target_physical.skipped);
	test::@check(target_physical.payload_bytes
		<= source_physical.payload_bytes + 1024,
		"larger target dimensions grew the bounded hull payload from %.2f to %.2f KiB",
		(float)source_physical.payload_bytes / 1024.0f,
		(float)target_physical.payload_bytes / 1024.0f);

	gltf::GltfStream source_stream = gltf::open(P6_SOURCE_GLB, mem)!!;
	defer source_stream.close();
	source_stream.load_all_buffers()!!;
	gltf::GltfStream target_stream = gltf::open(P6_TARGET_GLB, mem)!!;
	defer target_stream.close();
	target_stream.load_all_buffers()!!;
	test::@check(target_stream.gltf.colliders.len() == 4
		&& target_stream.gltf.motions.len() == 4
		&& target_stream.gltf.physics_joints.len() == 3
		&& target_stream.gltf.shapes.len() == 0,
		"target KHR graph has %d colliders, %d motions, %d joints and %d implicit shapes",
		target_stream.gltf.colliders.len(), target_stream.gltf.motions.len(),
		target_stream.gltf.physics_joints.len(), target_stream.gltf.shapes.len());

	uint[4] target_nodes;
	for (usz joint = 0; joint < target.skeleton.len(); joint++)
	{
		int source_node = node_named(&source_stream, target.names[joint]);
		int target_node = node_named(&target_stream, target.names[joint]);
		test::@check(source_node >= 0 && target_node >= 0,
			"%s has no source or target body node", target.names[joint]);
		if (source_node < 0 || target_node < 0) return;
		target_nodes[joint] = (uint)target_node;

		P6HullMeasure source_hull = p6_measure_hull(&source_stream, source_node);
		P6HullMeasure target_hull = p6_measure_hull(&target_stream, target_node);
		test::@check(source_hull.valid && target_hull.valid,
			"%s does not carry a readable closed convex hull", target.names[joint]);
		if (!source_hull.valid || !target_hull.valid) continue;
		Vec3 source_extent = source_hull.bounds.extent();
		Vec3 target_extent = target_hull.bounds.extent();
		test::@check(target_extent.x > source_extent.x * 2.5f
			&& target_extent.y > source_extent.y * 1.7f
			&& target_extent.z > source_extent.z * 1.7f,
			"%s reused source hull dimensions instead of the 3x/2x/2x target",
			target.names[joint]);

		gltf::Node body_node = target_stream.gltf.nodes[target_node];
		test::@check(body_node.motion >= 0,
			"%s has collision geometry but no rigid-body motion", target.names[joint]);
		if (body_node.motion >= 0)
		{
			gltf::Motion motion = target_stream.gltf.motions[(uint)body_node.motion];
			test::@check(p6_relative(motion.mass,
				target_hull.volume * crig::PHYSICAL_BODY_DENSITY),
				"%s mass %.4f does not match independently measured hull volume %.6f",
				target.names[joint], motion.mass, target_hull.volume);
			test::@check(motion.is_kinematic == (joint == 0),
				"%s has the wrong kinematic/dynamic role", target.names[joint]);
		}
	}

	for (usz joint = 1; joint < target.skeleton.len(); joint++)
	{
		p6_check_constraint_graph(&target_stream, &target.skeleton,
			target.names, target_nodes[..], target_constraints, joint);
	}

	// Finally pass the target through crig's reader as a separate compatibility
	// check. The independent assertions above are the acceptance oracle; this
	// confirms the file is also reusable as the next template in the workflow.
	AnimPackReport target_report;
	AnimPack reopened_target = crig::read_pack(mem, P6_TARGET_GLB,
		&target_report)!!;
	defer reopened_target.free(mem);
	test::@check(target_report.constraints_read == 3
		&& reopened_target.physics.joints.len == 0
		&& reopened_target.physics.skipped == 0,
		"the accepted target did not reopen as a reusable anatomical rig");
}

<*
 Limit rows are read against the pack's *real* rest skeleton, not the plan's
 proportions. A biped plan keeps every joint at mid-depth, so its thigh leans only
 sideways and its derived frame's X points forward — where the real thigh, leaning
 a touch forward, has X across. Read against the flattened frame, the hip's
 forward swing landed on the sideways axis and a fitted leg could not sit.
*>
fn void fitted_limits_read_rows_against_the_real_source_frames() @test
{
	rig::TriMesh body = {
		.positions = fit_box_positions[..],
		.indices = fit_box_indices[..],
	};
	crig::AppState app = crig::new_app(body);
	defer app.free();

	// Flat: every dot at the same depth, the thigh leaning outward only.
	crig::PresetDot[3] dots = {
		{ .name = "hips", .at = { 0.50f, 0.60f, 0.50f }, .parent = -1 },
		{ .name = "thigh", .at = { 0.60f, 0.55f, 0.50f }, .parent = 0 },
		{ .name = "knee", .at = { 0.63f, 0.25f, 0.50f }, .parent = 1 },
	};
	crig::Preset preset = { .name = "Flat leg", .plan = "flat-leg", .dots = dots[..] };

	// The real source the rows were written on: the same leg, straight down with a
	// slight forward lean, so its frame's X runs across the body.
	Vec3[3] joints = { { 0, 1.0f, 0 }, { 0.1f, 0.95f, 0 }, { 0.1f, 0.5f, 0.02f } };
	int[3] parents = { -1, 0, 1 };
	rig::Skeleton source = { .joints = joints[..], .parents = parents[..] };

	crig::JointConstraint[3] rows;
	foreach (&row : rows)
	{
		*row = { .status = crig::JointConstraintStatus.FREE, .primary_child = -1,
			.frame_adjustment = quaternion::IDENTITY,
			.frame_status = crig::JointLimitFrameStatus.READY };
	}
	// Forward swing about X (across), a narrow sideways range about Z.
	rows[1] = exact_constraint(-1, crig::ConstraintFrameIntent.AUTOMATIC);
	rows[1].axes[0] = { .allowed = true, .minimum = -2.0f, .maximum = 0.3f };
	rows[1].axes[2] = { .allowed = true, .minimum = -0.5f, .maximum = 0.4f };
	crig::ConstraintRig constraints = { .joints = rows[..] };

	app.apply_preset(preset, preset.plan, {}, constraints, source);
	crig::Dot* thigh = app.dot_named("thigh");
	test::@check(thigh != null, "the thigh was not fitted");
	if (!thigh) return;

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits landed = app.doc.rotation_limits_of(thigh.id);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, landed);
	test::@check(landed.constrained && frame.usable(), "the thigh took no usable limit");

	// Whichever target axis runs across the body must carry the forward swing.
	bool found = false;
	for (usz k = 0; k < 3; k += 2)
	{
		Vec3 axis = frame.rotation.rotate_vec3(crig::AXIS_DIRECTION[k]);
		if (math::abs(axis.x) < 0.9f) continue;
		found = true;
		float span = landed.axes[k].maximum - landed.axes[k].minimum;
		test::@check(math::abs(span - 2.3f) < 1.0e-3f,
			"the across axis carries a %.2f-wide range, not the 2.30-wide forward swing", span);
	}
	test::@check(found, "no target swing axis runs across the body");
}

module crig_tests::transform;

import crig;
import rig;
import gltf;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

fn bool near(float a, float b) => math::abs(a - b) < 1.0e-5f;
fn bool near_vec(Vec3 a, Vec3 b) => (a - b).length_sq() < 1.0e-10f;
fn bool near_vec2(Vec2 a, Vec2 b) => (a - b).length_sq() < 1.0e-10f;

struct TransformRig
{
	crig::AppState app;
	uint root;
	uint child;
	uint side;
}

fn void TransformRig.open(&self)
{
	self.app = crig::new_app({});
	self.root = self.app.doc.add_dot({ 0, 0, 0 }, "root");
	self.child = self.app.doc.add_dot({ 1, 0, 0 }, "child");
	self.side = self.app.doc.add_dot({ 0, 0, 1 }, "side");
	self.app.doc.connect(self.root, self.child);
	self.app.doc.connect(self.root, self.side);
	self.app.select_scene(crig::SceneSelection.SKELETON);
}

fn void TransformRig.close(&self) => self.app.free();

fn void selection_resolves_to_transform_targets() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	crig::TransformTarget target = fixture.app.transform_target();
	test::@check(target.kind == crig::TransformTargetKind.SKELETON_TARGET && target.joint_count == 3,
		"the skeleton row did not resolve to the whole rig");

	fixture.app.select_scene(crig::SceneSelection.MODEL);
	target = fixture.app.transform_target();
	test::@check(target.kind == crig::TransformTargetKind.MODEL_TARGET,
		"the model row did not resolve to the model target");
	test::@check(fixture.app.begin_transform(crig::TransformOperation.MOVE_TRANSFORM),
		"the model target did not start its persistent transform");
	fixture.app.cancel_transform();

	fixture.app.select_scene(crig::SceneSelection.MESH);
	target = fixture.app.transform_target();
	test::@check(target.kind == crig::TransformTargetKind.MESH_TARGET,
		"the mesh row did not resolve to the mesh target");
	test::@check(!fixture.app.begin_transform(crig::TransformOperation.MOVE_TRANSFORM),
		"mesh-only movement started without rebuilding geometry consumers");

	fixture.app.select(fixture.child);
	fixture.app.extend_selection(fixture.side);
	target = fixture.app.transform_target();
	test::@check(target.kind == crig::TransformTargetKind.JOINT_TARGETS
		&& target.active_joint == fixture.child && target.joint_count == 2,
		"the joint selection did not resolve with its active joint and count");
}

fn void model_transform_is_non_destructive_undoable_and_persistent() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	fixture.app.select_scene(crig::SceneSelection.MODEL);
	Vec3 local_root = fixture.app.doc.find(fixture.root).position;
	Vec3 local_child = fixture.app.doc.find(fixture.child).position;

	test::@check(fixture.app.begin_transform(crig::TransformOperation.MOVE_TRANSFORM),
		"the model move did not begin");
	fixture.app.update_transform_translation({ 2, 3, 4 });
	test::@check(fixture.app.commit_transform(), "the model move did not commit");
	test::@check(fixture.app.doc.find(fixture.root).position == local_root
		&& fixture.app.doc.find(fixture.child).position == local_child,
		"moving the model rewrote local rig coordinates");
	test::@check(near_vec(fixture.app.doc.model_transform.point(local_root), { 2, 3, 4 })
		&& near_vec(fixture.app.doc.model_transform.point(local_child), { 3, 3, 4 }),
		"the model placement does not carry mesh-space points together");

	test::@check(fixture.app.undo(), "the model move did not undo");
	test::@check(fixture.app.doc.model_transform.is_identity(), "undo left the model displaced");
	test::@check(fixture.app.redo(), "the model move did not redo");
	test::@check(near_vec(fixture.app.doc.model_transform.location, { 2, 3, 4 }),
		"redo did not restore the model placement");

	String text = crig::session_text(tmem, &fixture.app.doc, "model.glb");
	crig::RigDocument reopened = crig::parse_session(mem, text)!!;
	defer reopened.free();
	test::@check(reopened.model_transform.same(fixture.app.doc.model_transform),
		"the project sidecar lost the model placement");
}

fn void model_rotation_keeps_the_character_center_fixed() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	fixture.app.select_scene(crig::SceneSelection.MODEL);
	Vec3 center = { 1.0f / 3.0f, 0, 1.0f / 3.0f };
	test::@check(fixture.app.begin_transform(crig::TransformOperation.ROTATE_TRANSFORM),
		"the model turn did not begin");
	fixture.app.update_transform_rotation_axis({ 0, 1, 0 }, (float)math::PI);
	test::@check(near_vec(fixture.app.doc.model_transform.point(center), center),
		"the model rotated around the origin instead of its median pivot");
	test::@check(near_vec(fixture.app.doc.model_transform.point({ 1, 0, 0 }),
		{ -1.0f / 3.0f, 0, 2.0f / 3.0f }),
		"the mesh/rig model-space rotation was not applied around the pivot");
	test::@check(fixture.app.commit_transform(), "the model turn did not commit");
}

fn void transform_updates_are_absolute_and_cancel_exactly() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	Vec3 before_root = fixture.app.doc.find(fixture.root).position;
	Vec3 before_child = fixture.app.doc.find(fixture.child).position;
	test::@check(fixture.app.begin_transform(crig::TransformOperation.MOVE_TRANSFORM), "the skeleton move did not begin");
	test::@check(fixture.app.update_transform_translation({ 2, 0, 0 }), "the first preview was refused");
	test::@check(fixture.app.update_transform_translation({ 3, 0, 0 }), "the second preview was refused");
	test::@check(near_vec(fixture.app.doc.find(fixture.root).position, before_root + (Vec3){ 3, 0, 0 })
		&& near_vec(fixture.app.doc.find(fixture.child).position, before_child + (Vec3){ 3, 0, 0 }),
		"preview deltas accumulated instead of being measured from the snapshot");
	test::@check(fixture.app.cancel_transform(), "the move would not cancel");
	test::@check(fixture.app.doc.find(fixture.root).position == before_root
		&& fixture.app.doc.find(fixture.child).position == before_child,
		"cancel did not restore the exact starting positions");
	test::@check(!fixture.app.undo_stack.can_undo(), "a cancelled transform entered history");
}

fn void local_space_uses_the_active_joints_bone_frame() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	// Leave one child so the root has an unambiguous local +Y: along the bone,
	// which points down world +X in this fixture.
	fixture.app.doc.disconnect(fixture.root, fixture.side);
	fixture.app.select(fixture.root);
	fixture.app.extend_selection(fixture.child);
	fixture.app.transform_space = crig::TransformSpace.LOCAL_SPACE;

	test::@check(fixture.app.begin_transform(crig::TransformOperation.MOVE_TRANSFORM), "the local move did not begin");
	fixture.app.update_transform_translation({ 0, 1, 0 });
	test::@check(near_vec(fixture.app.doc.find(fixture.root).position, { 1, 0, 0 })
		&& near_vec(fixture.app.doc.find(fixture.child).position, { 2, 0, 0 }),
		"local +Y did not follow the active bone along world +X");
	test::@check(fixture.app.commit_transform(), "the local move did not commit");
}

fn void active_and_median_pivots_are_explicit() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	fixture.app.select(fixture.root);
	fixture.app.extend_selection(fixture.child);
	fixture.app.transform_pivot = crig::TransformPivot.ACTIVE_PIVOT;
	test::@check(fixture.app.begin_transform(crig::TransformOperation.ROTATE_TRANSFORM), "the active-pivot turn did not begin");
	fixture.app.update_transform_rotation_axis({ 0, 1, 0 }, (float)math::PI);
	test::@check(near_vec(fixture.app.doc.find(fixture.root).position, { 0, 0, 0 })
		&& near_vec(fixture.app.doc.find(fixture.child).position, { -1, 0, 0 }),
		"the active joint was not the rotation pivot");
	fixture.app.cancel_transform();

	fixture.app.transform_pivot = crig::TransformPivot.MEDIAN_PIVOT;
	test::@check(fixture.app.begin_transform(crig::TransformOperation.ROTATE_TRANSFORM), "the median-pivot turn did not begin");
	fixture.app.update_transform_rotation_axis({ 0, 1, 0 }, (float)math::PI);
	test::@check(near_vec(fixture.app.doc.find(fixture.root).position, { 1, 0, 0 })
		&& near_vec(fixture.app.doc.find(fixture.child).position, { 0, 0, 0 }),
		"the selection midpoint was not the rotation pivot");
	fixture.app.cancel_transform();
}

fn void skeleton_rotation_is_one_undo_step_and_carries_limit_frames() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	crig::JointRotationLimits limits = crig::unconstrained_rotation(fixture.child);
	limits.has_saved_frame = true;
	limits.saved_frame = quaternion::IDENTITY;
	test::@check(fixture.app.doc.set_rotation_limits(fixture.child, limits), "the saved frame was refused");

	Vec3 before_child = fixture.app.doc.find(fixture.child).position;
	Vec3 before_side = fixture.app.doc.find(fixture.side).position;
	test::@check(fixture.app.begin_transform(crig::TransformOperation.ROTATE_TRANSFORM), "the skeleton turn did not begin");
	fixture.app.update_transform_rotation_axis({ 0, 1, 0 }, (float)math::PI);
	test::@check(fixture.app.commit_transform(), "the skeleton turn did not commit");
	test::@check(fixture.app.undo_stack.can_undo(), "the turn entered no history");

	Vec3 frame_x = fixture.app.doc.rotation_limits_of(fixture.child).saved_frame.rotate_vec3({ 1, 0, 0 });
	test::@check(near(frame_x.x, -1.0f) && near(frame_x.z, 0.0f),
		"the saved limit frame did not rotate with the rig");

	test::@check(fixture.app.undo(), "the turn did not undo");
	test::@check(fixture.app.doc.find(fixture.child).position == before_child
		&& fixture.app.doc.find(fixture.side).position == before_side,
		"one undo did not restore every joint");
	test::@check(fixture.app.doc.rotation_limits_of(fixture.child).saved_frame.v == limits.saved_frame.v,
		"one undo did not restore the limit frame");
	test::@check(!fixture.app.undo_stack.can_undo(), "the transform split into more than one undo step");

	test::@check(fixture.app.redo(), "the turn did not redo");
	test::@check(near_vec(fixture.app.doc.find(fixture.child).position,
		{ -1.0f / 3.0f, 0, 2.0f / 3.0f }),
		"redo did not restore the rotated joints");
}

fn void moving_joints_with_saved_limit_frames_does_not_snapshot_them() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	foreach (id : (uint[]){ fixture.child, fixture.side })
	{
		crig::JointRotationLimits limits = crig::unconstrained_rotation(id);
		limits.has_saved_frame = true;
		limits.saved_frame = quaternion::IDENTITY;
		test::@check(fixture.app.doc.set_rotation_limits(id, limits), "the saved frame was refused");
	}
	fixture.app.select(fixture.child);
	fixture.app.extend_selection(fixture.side);
	test::@check(fixture.app.begin_transform(crig::TransformOperation.MOVE_TRANSFORM), "the move did not begin");
	test::@check(fixture.app.transform_transaction.limits.len == 0, "a move snapshotted the limit frames");
	fixture.app.update_transform_translation({ 0, 1, 0 });
	test::@check(fixture.app.commit_transform(), "the move did not commit");
	test::@check(near_vec(fixture.app.doc.find(fixture.child).position, { 1, 1, 0 })
		&& near_vec(fixture.app.doc.find(fixture.side).position, { 0, 1, 1 }),
		"the selected joints did not move together");
}

fn void model_transform_exports_as_a_shared_mesh_and_rig_parent() @test
{
	const String PATH = "build/model-transform-export.glb";
	const String SIDECAR = "build/model-transform-export.rigsmith.json";
	defer (void)file::delete(PATH);
	defer (void)file::delete(SIDECAR);
	Vec3[3] positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };
	uint[3] indices = { 0, 1, 2 };
	rig::TriMesh mesh = { .positions = positions[..], .indices = indices[..] };
	Vec3[1] joints = { { 0, 0, 0 } };
	int[1] parents = { -1 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[1] names = { "root" };
	crig::ProjectTransform placement = {
		.location = { 2, 3, 4 },
		.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI),
	};

	crig::export_rigged_animated_glb(mem, PATH, mesh, &skeleton, names[..], {}, {},
		model_transform: placement)!!;
	gltf::GltfStream stream = gltf::open(PATH, mem)!!;
	defer stream.close();

	usz placed = (usz)stream.gltf.nodes.len();
	foreach (usz i, node : stream.gltf.nodes)
	{
		if (node.name == "crig:model_transform") { placed = i; break; }
	}
	test::@check(placed < (usz)stream.gltf.nodes.len(), "the export has no shared transform parent");
	if (placed >= (usz)stream.gltf.nodes.len()) return;
	gltf::Node* parent = &stream.gltf.nodes[(sz)placed];
	test::@check(near_vec(parent.translation, placement.location)
		&& parent.rotation.v == placement.orientation().v,
		"the exported parent does not carry the project placement");
	test::@check(parent.children.len() == 2,
		"mesh and skeleton root were not both parented to the placement");

	rig::TriMesh reopened_mesh = rig::load_gltf(mem, PATH)!!;
	defer reopened_mesh.free(mem);
	test::@check(near_vec(reopened_mesh.positions[0], placement.location),
		"the exported model placement was not visible to a glTF mesh reader");
	String[] reopened_names;
	rig::Skeleton reopened_rig = crig::read_rest_skeleton(mem, &stream, &reopened_names)!!;
	defer
	{
		reopened_rig.free(mem);
		foreach (name : reopened_names) name.free(mem);
		if (reopened_names.len > 0) alloc::free(mem, reopened_names);
	}
	test::@check(near_vec(reopened_rig.joints[0], placement.location),
		"the exported model placement was not visible to a glTF skeleton reader");

	crig::RigDocument project;
	project.dots.init(mem);
	project.edges.init(mem);
	defer project.free();
	(void)project.add_dot({ 0, 0, 0 }, "root");
	project.model_transform = placement;
	crig::write_session(SIDECAR, &project, PATH, model_transform_in_mesh: true)!!;

	crig::AppState reopened = crig::new_app(reopened_mesh, PATH);
	reopened.adopt_source_rig();
	test::@check(reopened.source_has_model_transform,
		"the project did not recognize its placement as baked into the export");
	test::@check(near_vec(reopened.geometry.positions[0], { 0, 0, 0 })
		&& reopened.doc.model_transform.same(placement),
		"reopening a transformed export would apply its placement twice");
	reopened.free();
}

fn void model_projection_and_queries_share_the_render_transform() @test
{
	TransformRig fixture;
	fixture.open();
	defer fixture.close();

	fixture.app.doc.model_transform = {
		.location = { 2, 3, 4 },
		.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI * 0.5f),
	};
	crig::OrbitCamera camera = {
		.target = { 2, 3, 4 },
		.distance = 8,
		.yaw = 25,
		.pitch = 15,
		.fov = 45,
		.near_plane = 0.01,
		.far_plane = 100,
	};
	Vec2 viewport = { 800, 600 };
	Vec3 local = { 1, 0.5f, -0.25f };
	Vec2 through_model = crig::project(
		fixture.app.model_view_projection(&camera, viewport.x / viewport.y), local, viewport)!!;
	Vec2 through_world = crig::project(
		camera.view_projection(viewport.x / viewport.y),
		fixture.app.doc.model_transform.point(local), viewport)!!;
	test::@check(near_vec2(through_model, through_world),
		"the rig overlay and transformed mesh do not project to the same pixel");

	Vec3 local_eye = fixture.app.model_eye(&camera);
	test::@check(near_vec(fixture.app.doc.model_transform.point(local_eye), camera.eye()),
		"picking and occlusion do not query from the rendered camera position");
	Vec3 world_direction = (camera.target - camera.eye()).normalize();
	test::@check(near_vec(
		fixture.app.doc.model_transform.direction(fixture.app.model_direction(world_direction)),
		world_direction), "collision rays do not share the rendered model orientation");
}

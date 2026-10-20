<*
 render_poses' poses: drawn inside the rig's own limits and spread over them,
 the same pose for the same seed and index, and the exam's movement smooth.

 A joint finder trained on these pictures learns only what the rig can do, so
 a draw past a limit teaches it a pose no clip will ever play; and one that
 stays near rest teaches it nothing about the ends of the range.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::render_poses`
*>
module crig_tests::render_poses;

import crig;
import crig_tests::mcp;
import rig;
import std::collections::object;
import three;
import std::core::test;
import std::math;

struct PoseRig
{
	crig::RigDocument doc;
	uint hips;
	uint knee;
	uint foot;
	rig::Skeleton skeleton;
	uint[] ids;
	int knee_joint;
}

// Hips, a knee that bends one way only (x from -0.2 to 2.4, the other two
// axes locked), and a foot.
fn void PoseRig.open(&self)
{
	self.doc.dots.init(mem);
	self.doc.edges.init(mem);
	self.doc.secondary.init(mem);
	self.doc.rotation_limits.init(mem);
	self.hips = self.doc.add_dot({ 0, 0, 0 }, "hips");
	self.knee = self.doc.add_dot({ 0, -1, 0 }, "knee");
	self.foot = self.doc.add_dot({ 0, -2, 0 }, "foot");
	self.doc.connect(self.hips, self.knee);
	self.doc.connect(self.knee, self.foot);
	crig::JointRotationLimits limits = crig::unconstrained_rotation(self.knee);
	limits.constrained = true;
	limits.primary_child = self.foot;
	limits.axes[0] = { .allowed = true, .minimum = -0.2f, .maximum = 2.4f };
	limits.axes[1] = { .allowed = false, .locked = 0.125f };
	limits.axes[2] = { .allowed = false, .locked = -0.25f };
	test::@check(self.doc.set_rotation_limits(self.knee, limits), "the knee's limits were refused");
	self.skeleton = crig::build_skeleton(&self.doc, mem, &self.ids)!!;
	self.knee_joint = -1;
	foreach (usz joint, id : self.ids) if (id == self.knee) self.knee_joint = (int)joint;
}

fn void PoseRig.close(&self)
{
	self.skeleton.free(mem);
	alloc::free(mem, self.ids);
	self.doc.free();
}

// The knee's turn read back as its three angles.
fn Vec3 PoseRig.knee_angles(&self, rig::Pose pose)
{
	crig::JointLimitFrame frame = crig::joint_limit_frame(&self.skeleton, self.ids, self.doc.rotation_limits_of(self.knee));
	return crig::joint_angles_from_rotation(frame, pose.rotations[(usz)self.knee_joint]);
}

fn bool inside_the_knee(Vec3 angles)
{
	return angles.x >= -0.2f - 1.0e-3f && angles.x <= 2.4f + 1.0e-3f
		&& math::abs(angles.y - 0.125f) < 1.0e-3f && math::abs(angles.z + 0.25f) < 1.0e-3f;
}

fn void random_poses_stay_inside_the_limits_and_reach_their_ends() @test
{
	PoseRig r;
	r.open();
	defer r.close();
	crig::PoseShoot shoot = crig::pose_shoot_defaults();
	float least = 10.0f;
	float most = -10.0f;
	usz outside = 0;
	for (ulong index = 0; index < 400; index++)
	{
		rig::Pose pose = crig::random_pose(&r.doc, &r.skeleton, r.ids, &shoot, index, 0);
		defer pose.free(mem);
		Vec3 angles = r.knee_angles(pose);
		if (!inside_the_knee(angles)) outside++;
		least = math::min(least, angles.x);
		most = math::max(most, angles.x);
	}
	test::@check(outside == 0, "%d of 400 poses bent the knee past its limits", outside);
	test::@check(least < -0.1f && most > 2.0f, "the poses kept to the middle of the knee's range (%f to %f of -0.2 to 2.4)", least, most);

	rig::Pose a = crig::random_pose(&r.doc, &r.skeleton, r.ids, &shoot, 7, 0);
	defer a.free(mem);
	rig::Pose b = crig::random_pose(&r.doc, &r.skeleton, r.ids, &shoot, 7, 0);
	defer b.free(mem);
	bool same = true;
	foreach (usz i, q : a.rotations) same = same && q.v == b.rotations[i].v;
	test::@check(same, "the same seed and index drew two different poses");
}

fn void the_exam_moves_smoothly_inside_the_limits() @test
{
	PoseRig r;
	r.open();
	defer r.close();
	crig::PoseShoot shoot = crig::pose_shoot_defaults();
	shoot.motion = true;
	usz outside = 0;
	float jump = 0.0f;
	Vec3 before;
	for (int frame = 0; frame < 96; frame++)
	{
		rig::Pose pose = crig::motion_pose(&r.doc, &r.skeleton, r.ids, &shoot, (float)frame / shoot.fps);
		defer pose.free(mem);
		Vec3 angles = r.knee_angles(pose);
		if (!inside_the_knee(angles)) outside++;
		if (frame > 0) jump = math::max(jump, math::abs(angles.x - before.x));
		before = angles;
	}
	test::@check(outside == 0, "%d of 96 exam frames bent the knee past its limits", outside);
	// At most 1.2 Hz over the whole 2.6-radian range: about 0.4 a frame at 24 fps.
	test::@check(jump < 0.45f, "the exam's knee jumped %f radians between frames", jump);
}

// A clip's exam: the walk played as the player plays it, on the spot, moving
// and smooth from frame to frame, the same every time it is asked for.
fn void a_clips_exam_walks_on_the_spot_smoothly() @test
{
	mcp::Fixture f;
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	Object*? landed = f.call_tool("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Exam walk"}`);
	if (catch landed) { test::@check(false, "import_clip refused the humanoid's own walk"); return; }
	landed.free();
	crig::AnimRef? ref = crig::resolve_clip(&f.app, "Exam walk");
	if (catch ref) { test::@check(false, "the imported walk cannot be found"); return; }
	f.app.ensure_clip_imported(ref);
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	crig::PoseShoot shoot = crig::pose_shoot_defaults();
	shoot.motion = true;
	shoot.clip = "Exam walk";

	usz joints = view.skeleton.len();
	rig::Pose before = crig::exam_pose(&f.app, &view, &shoot, ref, 0.0f);
	defer before.free(mem);
	rig::Pose first = before.copy(mem);
	defer first.free(mem);
	float jump = 0.0f;
	float moved = 0.0f;
	float slid = 0.0f;
	for (int frame = 1; frame < 96; frame++)
	{
		rig::Pose pose = crig::exam_pose(&f.app, &view, &shoot, ref, (float)frame / shoot.fps);
		for (usz j = 0; j < joints; j++)
		{
			float step = 2.0f * (float)math::acos(math::min(1.0f, math::abs(pose.rotations[j].v.dot(before.rotations[j].v))));
			float from_first = 2.0f * (float)math::acos(math::min(1.0f, math::abs(pose.rotations[j].v.dot(first.rotations[j].v))));
			jump = math::max(jump, step);
			moved = math::max(moved, from_first);
			if (view.skeleton.parents[j] < 0 && j < pose.offsets.len) slid = math::max(slid, math::abs(pose.offsets[j].x) + math::abs(pose.offsets[j].z));
		}
		before.free(mem);
		before = pose;
	}
	test::@check(moved > 0.3f, "the clip's exam hardly moves (%f radians at most from frame 0)", moved);
	test::@check(jump < 0.35f, "a joint jumped %f radians between frames", jump);
	test::@check(slid < 1.0e-6f, "the root slid %f across the floor without travel", slid);

	rig::Pose again = crig::exam_pose(&f.app, &view, &shoot, ref, 0.0f);
	defer again.free(mem);
	bool same = true;
	foreach (usz i, q : again.rotations) same = same && q.v == first.rotations[i].v;
	test::@check(same, "the same time drew two different poses");
}

// Each picture's light is its own and the same every time it is drawn; the sun
// stays above the horizon; with no jitter it is the scene's own.
fn void each_pictures_light_is_its_own_and_from_above() @test
{
	crig::PoseShoot shoot = crig::pose_shoot_defaults();
	three::Lighting base = three::DEFAULT_LIGHTING;
	three::Lighting a = crig::picture_lighting(&base, &shoot, 7, 1);
	three::Lighting b = crig::picture_lighting(&base, &shoot, 7, 1);
	three::Lighting other = crig::picture_lighting(&base, &shoot, 8, 1);
	test::@check(a.lights[0].direction == b.lights[0].direction && a.lights[0].color == b.lights[0].color && a.ambient == b.ambient,
		"one picture drew two lights");
	test::@check(a.lights[0].direction != other.lights[0].direction, "two pictures drew the same light");
	usz below = 0;
	float least = 10.0f;
	float most = 0.0f;
	for (ulong index = 0; index < 200; index++)
	{
		three::Lighting lit = crig::picture_lighting(&base, &shoot, index, 0);
		if (lit.lights[0].direction[1] <= 0.0f) below++;
		least = math::min(least, lit.ambient);
		most = math::max(most, lit.ambient);
	}
	test::@check(below == 0, "%d of 200 suns were below the horizon", below);
	test::@check(least < 0.35f && most > 0.6f, "the shadowed side was lifted only from %f to %f", least, most);
	shoot.light_jitter = 0.0f;
	three::Lighting still = crig::picture_lighting(&base, &shoot, 7, 1);
	test::@check(still.ambient == base.ambient && still.lights[0].color == base.lights[0].color, "no jitter still changed the light");
}

// The surface points the humanoid gets: the front and back of the head and of
// the root, a heel under each foot, no mirror pair on one joint (the head's
// sides); each out from its joint the way it is named, on the surface that
// joint carries.
fn void landmarks_ride_the_head_root_and_heels() @test
{
	mcp::Fixture f;
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	if (!f.app.rebind_skin(&view)) { test::@check(false, "the humanoid could not be skinned"); return; }
	rig::Bounds bounds = f.app.world_bounds();
	float height = bounds.max.y - bounds.min.y;
	crig::PoseLandmark[24] marks;
	usz count = crig::pose_landmarks(&f.app, &view, height, marks[..]);
	usz heads = 0;
	usz heels = 0;
	usz wrong = 0;
	for (usz k = 0; k < count; k++)
	{
		crig::PoseLandmark m = marks[k];
		if (m.side == "heel") heels++;
		if (m.side == "left" || m.side == "right") heads++;
		Vec3 toward = m.side == "front" ? (Vec3){ 0, 0, 1 } : (Vec3){ 0, 0, -1 };
		Vec3 out = f.app.geometry.positions[m.vertex] - view.skeleton.joints[m.named];
		if (m.side == "heel" ? out.z >= 0.0f || out.length() < 0.01f * height : out.dot(toward) < 0.02f * height) wrong++;
		Vec3 at = f.app.geometry.positions[m.vertex] - view.skeleton.joints[m.joint];
		if ((at - m.offset).length() > 1.0e-5f) wrong++;
	}
	test::@check(count >= 5, "only %d landmarks", count);
	test::@check(heads == 0, "%d landmarks on the head's sides, a mirror pair a finder confuses", heads);
	test::@check(heels == 2, "%d heels, not 2", heels);
	test::@check(wrong == 0, "%d landmarks are not out from their joint the way they are named", wrong);
}

// A clip's poses, nudged, stay inside the rig's limits.
fn void clip_poses_nudged_stay_inside_the_limits() @test
{
	mcp::Fixture f;
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	Object*? landed = f.call_tool("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Nudged walk"}`);
	if (catch landed) { test::@check(false, "import_clip refused the humanoid's own walk"); return; }
	landed.free();
	crig::AnimRef? ref = crig::resolve_clip(&f.app, "Nudged walk");
	if (catch ref) { test::@check(false, "the imported walk cannot be found"); return; }
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	crig::PoseShoot shoot = crig::pose_shoot_defaults();
	shoot.clip_noise = 25;
	float moved = 0.0f;
	float past = 0.0f;
	for (ulong index = 0; index < 40; index++)
	{
		rig::Pose pose = crig::clip_drawn_pose(&f.app, &view, &shoot, ref, index, (float)index * 0.1f);
		defer pose.free(mem);
		rig::Pose held = pose.copy(mem);
		defer held.free(mem);
		crig::constrain_pose_to_joint_limits(&f.app.doc, &view.skeleton, view.dot_ids, &held);
		foreach (usz j, q : pose.rotations)
		{
			if (view.skeleton.parents[j] < 0) continue;
			past = math::max(past, 2.0f * (float)math::acos(math::min(1.0f, math::abs(q.v.dot(held.rotations[j].v)))));
		}
		rig::Pose plain = f.app.evaluated_clip_pose(mem, &view, *f.app.clip(ref), ref, (float)index * 0.1f, false);
		defer plain.free(mem);
		foreach (usz j, q : pose.rotations)
		{
			if (view.skeleton.parents[j] < 0) continue;
			moved = math::max(moved, 2.0f * (float)math::acos(math::min(1.0f, math::abs(q.v.dot(plain.rotations[j].v)))));
		}
	}
	test::@check(past < 0.01f, "a nudged pose went %f radians past a limit", past);
	test::@check(moved > 0.1f, "the nudges barely moved the clip (%f radians at most)", moved);
}

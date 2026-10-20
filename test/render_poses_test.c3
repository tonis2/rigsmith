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
import rig;
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

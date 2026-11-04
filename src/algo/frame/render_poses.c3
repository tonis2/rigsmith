<* The pure half of src/mcp/render_poses.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::list;
import std::collections::object;
import std::math;
import std::math::quaternion;
import std::time;

// Poses one call may draw, and cameras it may draw them from.
const usz POSES_MOST = 1000;

const usz POSES_CAMERAS = 8;

// Sub-frames a blurred picture averages.
const usz BLUR_FRAMES = 4;

// Clips one call may draw poses from, and points on the surface it may follow.
const usz POSES_CLIPS = 32;

const usz POSES_LANDMARKS = 24;

// How far from rest a limited axis is drawn at most, whatever its row allows:
// about 150 degrees, so a row left at a whole turn does not fold the body.
const float LIMIT_REACH = 2.6f;

// Goes up when the same settings start drawing other poses, so a kept set is drawn again.
const int POSE_DRAW_VERSION = 3;

struct PoseCamera
{
	String name;
	float yaw;
	float pitch;
	float distance;
	float yaw_jitter;
	float pitch_jitter;
}

// What a call was asked for; `pose_shoot_defaults` has a call's defaults.
struct PoseShoot
{
	String out;
	usz count;
	usz first;
	ulong seed;
	uint size;
	PoseCamera[POSES_CAMERAS] cameras;
	usz camera_count;
	float fill_least;
	float fill_most;
	float shift;
	float spread;
	float heading;
	float tilt;
	float blur;
	bool motion;
	float fps;
	// The exam's clip, when it plays one; empty for the made-up movement.
	String clip;
	float clip_start;
	float clip_speed;
	bool travel;
	// Clips the random poses are drawn from (a share of them, each nudged);
	// `all_clips` for every clip that plays on the rig.
	String[POSES_CLIPS] clips;
	usz clip_count;
	bool all_clips;
	float clip_share;
	float clip_noise;
	// Random poses with the legs bent hard.
	float leg_share;
	// How far each picture's light strays from the scene's, 0 to 1.
	float light_jitter;
	// Follow points on the surface as well as the joints.
	bool landmarks;
}

// The settings a call with nothing but `out` draws with.
fn PoseShoot pose_shoot_defaults()
{
	PoseShoot shoot = {
		.count = 100, .seed = 1, .size = 448, .camera_count = 2,
		.fill_least = 0.45f, .fill_most = 0.75f, .shift = 0.08f,
		.spread = 20, .heading = 30, .tilt = 10, .blur = 0.3f, .fps = 24, .clip_speed = 1,
		.clip_share = 0.5f, .clip_noise = 12, .light_jitter = 1,
	};
	shoot.cameras[0] = { .name = "front", .yaw = 0, .pitch = 8, .distance = 4, .yaw_jitter = 15, .pitch_jitter = 8 };
	shoot.cameras[1] = { .name = "side", .yaw = 90, .pitch = 8, .distance = 4, .yaw_jitter = 15, .pitch_jitter = 8 };
	return shoot;
}

struct PoseDraw
{
	ulong state;
}

fn ulong PoseDraw.next(&self)
{
	self.state += 0x9e3779b97f4a7c15UL;
	ulong z = self.state;
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
	return z ^ (z >> 31);
}

// In [0, 1).
fn float PoseDraw.unit(&self) => (float)((double)(self.next() >> 11) / 9007199254740992.0);

fn float PoseDraw.between(&self, float least, float most) => least + (most - least) * self.unit();

// A direction uniform on the sphere.
fn Vec3 PoseDraw.direction(&self)
{
	float z = self.between(-1.0f, 1.0f);
	float around = self.between(0.0f, (float)math::TAU);
	float across = (float)math::sqrt(math::max(0.0f, 1.0f - z * z));
	return { across * (float)math::cos(around), across * (float)math::sin(around), z };
}

// Purposes, each its own stream.
const ulong DRAW_POSE = 0;

const ulong DRAW_BLUR = 1;

const ulong DRAW_CAMERA = 2;

const ulong DRAW_MOTION = 3;

const ulong DRAW_SOURCE = 4;

const ulong DRAW_NUDGE = 5;

const ulong DRAW_LIGHT = 6;

const ulong DRAW_LEGS = 7;

<*
 A limited joint's row read as the range a draw spans: its own, cut to
 LIMIT_REACH from rest, and rest itself held inside it.
*>
fn void drawn_range(JointAxisLimit row, float* least, float* most, float* rest)
{
	*least = math::max(row.minimum, -LIMIT_REACH);
	*most = math::min(row.maximum, LIMIT_REACH);
	if (*most < *least)
	{
		*least = row.minimum;
		*most = row.maximum;
	}
	*rest = math::clamp(0.0f, *least, *most);
}

<*
 Joint `joint`'s turn in a random pose: inside its limits when it has them,
 `spread` radians at most when it has none. `calm` in [0, 1] pulls a limited
 draw back toward rest.
*>
fn Quaternionf random_turn(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz joint, PoseDraw* draw, float spread, float calm)
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
	JointLimitFrame frame;
	if (limits.constrained) frame = joint_limit_frame(skeleton, dot_ids, limits);
	if (!limits.constrained || !frame.usable())
	{
		Vec3 axis = draw.direction();
		return quaternion::from_axis_angle{float}(axis, draw.between(0.0f, spread));
	}
	Vec3 angles;
	for (usz axis = 0; axis < 3; axis++)
	{
		JointAxisLimit row = limits.axes[axis];
		if (!row.allowed)
		{
			angles[axis] = row.locked;
			continue;
		}
		float least, most, rest;
		drawn_range(row, &least, &most, &rest);
		angles[axis] = rest + (draw.between(least, most) - rest) * (1.0f - calm);
	}
	return rotation_from_joint_angles(frame, angles);
}

// The root's turn: about the vertical, then tipped.
fn Quaternionf root_turn(float heading, float tilt_axis, float tilt)
{
	Quaternionf turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, heading);
	Vec3 across = { (float)math::cos(tilt_axis), 0, (float)math::sin(tilt_axis) };
	return quaternion::from_axis_angle{float}(across, tilt).mul(turn).normalize();
}

<*
 A leg joint's turn bent hard: each allowed axis between halfway to an end of
 its range and the end, the end drawn. A free joint turns as `random_turn`'s.
*>
fn Quaternionf leg_turn(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz joint, PoseDraw* draw, float spread)
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
	JointLimitFrame frame;
	if (limits.constrained) frame = joint_limit_frame(skeleton, dot_ids, limits);
	if (!limits.constrained || !frame.usable()) return random_turn(doc, skeleton, dot_ids, joint, draw, spread, 0);
	Vec3 angles;
	for (usz axis = 0; axis < 3; axis++)
	{
		JointAxisLimit row = limits.axes[axis];
		if (!row.allowed)
		{
			angles[axis] = row.locked;
			continue;
		}
		float least, most, rest;
		drawn_range(row, &least, &most, &rest);
		// The far or the near end, not the low or the high: a joint and its mate
		// have mirrored ranges, and legs drawn alike then spread, not lean.
		float far = math::abs(least - rest) >= math::abs(most - rest) ? least : most;
		float near = far == least ? most : least;
		float end = draw.unit() < 0.5f ? far : near;
		angles[axis] = rest + (end - rest) * draw.between(0.5f, 1.0f);
	}
	return rotation_from_joint_angles(frame, angles);
}

// `from` turned `share` of the way to `to`, joint by joint. The caller frees it.
fn rig::Pose between_poses(rig::Pose from, rig::Pose to, float share)
{
	rig::Pose out = from.copy(mem);
	foreach (usz i, rotation : from.rotations) out.rotations[i] = rotation.slerp(to.rotations[i], share).normalize();
	return out;
}

<*
 Joint `joint`'s `turn` nudged by up to `noise` radians: each limited axis moved
 inside its range, a joint without limits turned about an axis of its own.
*>
fn Quaternionf nudged_turn(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz joint, Quaternionf turn, PoseDraw* draw, float noise)
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
	JointLimitFrame frame;
	if (limits.constrained) frame = joint_limit_frame(skeleton, dot_ids, limits);
	if (!limits.constrained || !frame.usable())
	{
		Vec3 axis = draw.direction();
		return quaternion::from_axis_angle{float}(axis, draw.between(-noise, noise)).mul(turn).normalize();
	}
	Vec3 angles = joint_angles_from_rotation(frame, turn);
	for (usz axis = 0; axis < 3; axis++)
	{
		JointAxisLimit row = limits.axes[axis];
		float step = draw.between(-noise, noise);
		if (!row.allowed)
		{
			angles[axis] = row.locked;
			continue;
		}
		float least, most, rest;
		drawn_range(row, &least, &most, &rest);
		angles[axis] = math::clamp(angles[axis] + step, least, most);
	}
	return rotation_from_joint_angles(frame, angles);
}

// A vertex followed as a landmark: the joint it is named for and which way
// from it, and the joint it rides (the one its skin follows) with its offset
// from that joint at rest.
struct PoseLandmark
{
	usz named;
	usz joint;
	usz vertex;
	Vec3 offset;
	String side;
}

// A landmark looked for: on which joint, which way from it, and its name's end.
struct LandmarkWant
{
	usz joint;
	Vec3 toward;
	String side;
}

<*
 Each joint's mirror partner when it is a leg's (it has one, and the joints
 below it reach the floor), else -1; empty without legs. The caller frees it.
*>
fn int[] leg_mates(RigView* view)
{
	rig::Skeleton* skeleton = &view.skeleton;
	usz count = skeleton.len();
	if (count == 0) return {};
	float ground = 1.0e30f;
	float top = -1.0e30f;
	foreach (p : skeleton.joints)
	{
		ground = math::min(ground, p.y);
		top = math::max(top, p.y);
	}
	// The lowest point at or below each joint, children after their parents.
	float[] lowest = alloc::new_array(tmem, float, (sz)count);
	foreach (usz j, p : skeleton.joints) lowest[j] = p.y;
	for (usz k = count; k > 0; k--)
	{
		int parent = skeleton.parents[k - 1];
		if (parent >= 0) lowest[parent] = math::min(lowest[parent], lowest[k - 1]);
	}
	int[] mates = alloc::new_array(mem, int, (sz)count);
	bool found = false;
	foreach (usz j, name : view.names)
	{
		mates[j] = -1;
		if (skeleton.parents[j] < 0 || lowest[j] - ground > 0.05f * (top - ground)) continue;
		String twin = mirror_name(tmem, name);
		if (twin.len == 0 || twin == name) continue;
		foreach (usz k, other : view.names)
		{
			if (other != twin) continue;
			mates[j] = (int)k;
			found = true;
		}
	}
	if (!found)
	{
		alloc::free(mem, mates);
		return {};
	}
	return mates;
}

// Where the posed joints are, in model space. The caller frees it.
fn Vec3[] posed_joints(RigView* view, Matrix4f[] palette) @private
{
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)view.skeleton.len());
	foreach (usz i, joint : view.skeleton.joints) at[i] = joint.transform(palette[i]);
	return at;
}

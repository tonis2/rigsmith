<*
 Small checks and builders more than one test file uses, over the lower layers
 only: `tools/test_algo.sh` compiles this half alone. `test/helpers.c3` is the
 editor's half of the same module.
*>
module crig_tests::helpers;

import crig;
import rig;
import std::io::file;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// Measures

// Two points no further than `eps` apart.
fn bool near3(Vec3 a, Vec3 b, float eps) => (a - b).length() <= eps;

// The angle of a rotation, in degrees, 0 to 180. Read off the vector part so a
// tiny turn keeps its precision.
fn float angle_of(Quaternionf q)
{
	q = q.normalize();
	float vector = math::sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2]);
	return 2.0f * (float)math::atan2(vector, math::abs(q.v[3])) * 57.29578f;
}

// How far the up axis has leaned from `was` to `now`, in degrees: a yaw is not a tilt.
fn float tilt_of(Quaternionf was, Quaternionf now)
{
	Vec3 before = was.rotate_vec3({ 0, 1, 0 });
	Vec3 after = now.rotate_vec3({ 0, 1, 0 });
	return (float)math::atan2(before.cross(after).length(), before.dot(after)) * 57.29578f;
}

// Two rotations within `eps` of the same turn, either sign of the quaternion.
fn bool same_rotation(Quaternionf a, Quaternionf b, float eps) => 1.0f - math::abs(a.v.dot(b.v)) <= eps;

// The angle between two unit rotations, in radians.
fn float turn_between(Quaternionf a, Quaternionf b)
{
	float d = math::min(math::abs(a.v.dot(b.v)), 1.0f);
	return 2.0f * math::acos(d);
}

// |cos| of half the angle between two rotations: 1 for the same turn.
fn float closeness(Quaternionf a, Quaternionf b) => math::abs(a.v.dot(b.v));

// A turn as one vector, its axis scaled by its angle: unlike the axis and angle
// apart, the same turn always reads the same.
fn Vec3 turn_of(crig::AnimKeyDot dot) => dot.axis.normalize() * dot.angle;

fn Vec3 turn_of_quaternion(Quaternionf q)
{
	Vec3 axis;
	float angle;
	crig::axis_angle_of(q, &axis, &angle);
	return axis * angle;
}

// ---------------------------------------------------------------------------
// Rigs

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

<*
 Where `joint` stands in `pose`.

 @require joint < skeleton.joints.len : "No such joint"
*>
fn Vec3 joint_at(rig::Skeleton* skeleton, rig::Pose pose, usz joint)
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);
	return skeleton.joints[joint].transform(palette[joint]);
}

// root
//  |- a - b - c
//  `- d
Vec3[5] small_rig_joints @local = {
	{ 0, 1, 0 }, { 0, 0.8f, 0 }, { 0, 0.6f, 0 }, { 0, 0.4f, 0 }, { 0.3f, 0.9f, 0 },
};
int[5] small_rig_parents @local = { -1, 0, 1, 2, 0 };
String[5] small_rig_names = { "root", "a", "b", "c", "d" };

fn rig::Skeleton small_rig() => { .joints = small_rig_joints[..], .parents = small_rig_parents[..] };

// The twelve triangles of a box laid out by `corners`, wound outward: a picker reads
// a face's facing off its winding, so the other way round is a box seen inside-out.
const uint[36] BOX_FACES = {
	4, 5, 6, 4, 6, 7,   // +Z
	0, 3, 2, 0, 2, 1,   // -Z
	1, 2, 6, 1, 6, 5,   // +X
	0, 4, 7, 0, 7, 3,   // -X
	3, 7, 6, 3, 6, 2,   // +Y
	0, 1, 5, 0, 5, 4,   // -Y
};

<*
 The eight corners of a box, in the order `BOX_FACES` winds them.

 @require into.len >= 8 : "Room for eight corners"
*>
fn void corners(Vec3[] into, Vec3 low, Vec3 high)
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

// ---------------------------------------------------------------------------
// Clips

fn crig::AnimKeyframe key_of(float time, String joint, Vec3 axis, float angle)
{
	crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 1);
	dots[0] = { .joint_name = joint.copy(mem), .axis = axis, .angle = angle, .channels = ROTATION };
	return { .time = time, .dots = dots };
}

fn crig::AnimTemplate clip_of(String name, float duration, bool loop, crig::AnimKeyframe[] keys)
{
	return { .name = name.copy(mem), .duration = duration, .keyframes = keys, .loop = loop, .owned = true };
}

fn crig::CutStrip play(float start, float end, String clip, bool loop = false)
{
	crig::CutStrip s = crig::cut_strip(PLAY, start, end);
	s.clip = clip.copy(mem);
	s.loop = loop;
	return s;
}

// ---------------------------------------------------------------------------
// Files

fn bool same_bytes(char[] a, char[] b)
{
	if (a.len != b.len) return false;
	foreach (usz i, c : a) if (b[i] != c) return false;
	return true;
}

// A copy of `source` in `folder` under `name`.
fn String copy_into(String folder, String source, String name)
{
	String target = string::format(mem, "%s/%s", folder, name);
	char[] bytes = file::load(mem, source)!!;
	defer alloc::free(mem, bytes);
	file::save(target, bytes)!!;
	return target;
}

fn void copy_humanoid(String path)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
}

fn void remove_with_sidecar(String path)
{
	(void)file::delete(path);
	String sidecar = crig::session_path(mem, path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

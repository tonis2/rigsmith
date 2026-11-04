<* The pure half of src/app/pose_align.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::quaternion;

<*
 How close a joint has to come to the line to count as on it, as a fraction of
 rig height: a tenth of a millimetre on a figure a metre tall. Float noise
 through a palette is far below it; a limit holding a bone short is far above.
*>
const float POSE_ALIGN_TOLERANCE = 1.0e-4f;

<*
 What lining up one pose did: whether any bone turned, and how many of the
 joints asked for ended on the line.
*>
struct PoseAlignment
{
	bool turned;
	usz lined;
	usz asked;
}

<*
 How many times a key is rewritten and played back before what it plays is
 taken as the answer. One pass is exact for a joint the clip already keys; the
 others are for a joint keyed here for the first time, a root, or a limit.
*>
const int POSE_ALIGN_ROUNDS = 3;

// How far a rotation turns, in radians — near enough for small ones.
fn float turn_size(Quaternionf q) => 2.0f * ((Vec3){ q.v.x, q.v.y, q.v.z }).length();

<*
 Turn `name`'s key at `time` in `clip` so the joint plays turned by `change`
 in its parent's frame.

 Playback carries a joint's key onto this rig as `M · turn · carry⁻¹`, where
 `carry` takes the bone the clip recorded onto the rig's own and `M` comes from
 the joints above it alone (`AnimTemplate.pose`). So `turn · carry⁻¹ · change ·
 carry` plays turned by `change`, and the key keeps the bone it was recorded
 against — the clip stays one rig's motion, which `span_bone` relies on. The
 key is edited in place when there is one at `time` that turns the joint;
 otherwise the joint is keyed there, rotation only.
*>
fn void turn_key(AnimTemplate* clip, String name, Vec3 rig_bone, float time, Quaternionf change)
{
	Vec3 bone;
	Quaternionf turn = clip.rotation_and_bone_at(name, time, &bone);
	Quaternionf carry = bone_carry(bone, rig_bone);
	Vec3 axis;
	float angle;
	axis_angle_of(turn.mul(carry.invert()).mul(change).mul(carry).normalize(), &axis, &angle);
	foreach (&frame : clip.keyframes)
	{
		if (math::abs(frame.time - time) >= ANIM_SAME_TIME) continue;
		foreach (&dot : frame.dots)
		{
			if (dot.joint_name != name || !dot.keys_rotation()) continue;
			dot.axis = axis;
			dot.angle = angle;
			return;
		}
	}
	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
	dots[0] = { .joint_name = name.copy(mem), .channels = ROTATION, .axis = axis, .angle = angle, .bone = bone };
	AnimTemplate keyed = clip_with_key(mem, *clip, { .time = time, .dots = dots });
	clip.free(mem);
	*clip = keyed;
}

fn usz joint_depth(rig::Skeleton* skeleton, usz joint)
{
	usz depth;
	for (int at = skeleton.parents[joint]; at >= 0; at = skeleton.parents[(usz)at]) depth++;
	return depth;
}

<*
 The bone `from` swung the shortest way about its root until its `component`
 is `along`, its length kept. Past the bone's reach it points straight along
 the axis, as near as it can come. A bone already on the axis has no shortest
 way and leans toward the next axis round.
*>
fn Vec3 swung_onto(Vec3 from, float along, int component)
{
	float length = from.length();
	if (length < 1.0e-9f) return from;
	along = math::clamp(along, -length, length);
	Vec3 across = from;
	across[component] = 0.0f;
	float spread = across.length();
	if (spread < 1.0e-6f * length)
	{
		across = {};
		across[(component + 1) % 3] = 1.0f;
		spread = 1.0f;
	}
	Vec3 to = across * (math::sqrt(math::max(length * length - along * along, 0.0f)) / spread);
	to[component] = along;
	return to;
}

fn usz lined_up(RigView* view, Vec3[] at, usz anchor, usz[] order, int component) @local
{
	float tolerance = POSE_ALIGN_TOLERANCE * view.skeleton.height();
	usz lined;
	foreach (joint : order)
	{
		if (math::abs(at[joint][component] - at[anchor][component]) <= tolerance) lined++;
	}
	return lined;
}

// Where `pose` puts every joint, in model space, into `at`.
fn bool posed_points(RigView* view, rig::Pose pose, Vec3[] at) @local
{
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return false;
	Matrix4f[] palette = built;
	foreach (usz i, joint : view.skeleton.joints) at[i] = joint.transform(palette[i]);
	alloc::free(mem, palette);
	return true;
}

<*
 The bones `turned` marks, as rig-named entries at `time` — what `land_pose`
 and `entries_in_clip_words` take. The caller owns the result.
*>
fn AnimKeyframe keyed_bones(RigView* view, rig::Pose pose, bool[] turned, float time)
{
	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	AnimKeyframe every = keyframe_of_pose(mem, pose, view.names, bones, view.skeleton.height(), time);

	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : every.dots)
	{
		bool keep;
		foreach (usz j, name : view.names)
		{
			if (name != dot.joint_name) continue;
			keep = j < turned.len && turned[j];
			break;
		}
		if (keep) { kept.push(dot); }
		else if (dot.joint_name.len > 0) { alloc::free(mem, dot.joint_name.ptr); }
	}
	if (every.dots.len > 0) alloc::free(mem, every.dots);
	return { .time = time, .dots = kept.to_array(mem) };
}

<*
 Swing `pose` so each joint of `order` takes the anchor's coordinate on
 `component`, shallowest first, each through its parent bone's limits.
 `turned` is marked for every bone that moved; a root has no bone above it to
 swing and stays where it is.
*>
fn PoseAlignment align_pose(RigDocument* doc, RigView* view, rig::Pose* pose, usz anchor, usz[] order,
	int component, bool[] turned)
{
	PoseAlignment done = { .asked = order.len };
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)view.len());
	defer alloc::free(mem, at);
	if (!posed_points(view, *pose, at)) return done;
	float target = at[anchor][component];

	foreach (joint : order)
	{
		int parent = view.skeleton.parents[joint];
		if (parent < 0) continue;
		Vec3 from = at[joint] - at[(usz)parent];
		Vec3 to = swung_onto(from, target - at[(usz)parent][component], component);
		if ((to - from).length_sq() < 1.0e-14f) continue;

		Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
		if (catch read) break;
		Quaternionf[] world = read;
		int above = view.skeleton.parents[(usz)parent];
		Quaternionf over = above >= 0 ? world[(usz)above] : quaternion::IDENTITY;
		alloc::free(mem, world);

		// The swing is a world turn; in the parent's frame it is conjugated by the
		// world rotation above it, as `turn_joint` measures a sweep.
		Quaternionf swing = bone_carry(from, to);
		Quaternionf local = over.invert().mul(swing).mul(over).mul(pose.rotations[(usz)parent]).normalize();
		JointRotationLimits limits = doc.rotation_limits_of(view.dot_ids[(usz)parent]);
		local = constrain_joint_rotation(joint_limit_frame(&view.skeleton, view.dot_ids, limits), limits, local);
		if (1.0f - math::abs(local.v.dot(pose.rotations[(usz)parent].v)) < 1.0e-9f) continue;

		pose.rotations[(usz)parent] = local;
		turned[(usz)parent] = true;
		done.turned = true;
		if (!posed_points(view, *pose, at)) return done;
	}

	done.lined = lined_up(view, at, anchor, order, component);
	return done;
}

// How many of `order` sit on the anchor's coordinate on `component` in `pose`.
fn usz lined_on(RigView* view, rig::Pose pose, usz anchor, usz[] order, int component)
{
	Vec3[] at = alloc::new_array(mem, Vec3, (sz)view.len());
	defer alloc::free(mem, at);
	if (!posed_points(view, pose, at)) return 0;
	return lined_up(view, at, anchor, order, component);
}

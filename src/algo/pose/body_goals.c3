<* What the body solve is asked to do: its joints and its goals, gathered from the rig. *>
module crig;

import rig;
import std::collections::list;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::math::vector;

<*
 Every joint of the figure, with its mass, its limits and what holds it. The
 masses are the shape's and the mesh's, with no joint made as heavy as the one it
 hangs from: the solve turns real joints, and a hip socket stays on its pelvis
 because the pelvis carries it.

 @param [&inout] out : `Receives one entry per joint of the figure.`
 @param [&in] frozen : `The joints an aim holds; they keep their local rotation.`
 @param standing : `The joints the floor holds up.`
*>
fn void body_joints(List{PointJoint}* out, RigDocument* doc, RigView* view, usz root, float[] inv_mass, bool[] trunk,
	AimAppliedSet* frozen, usz[] standing)
{
	rig::Skeleton* skeleton = &view.skeleton;
	for (usz j = 0; j < skeleton.len(); j++)
	{
		if (tree_root_of(skeleton, j) != root) continue;
		JointRotationLimits limits = doc.rotation_limits_of(view.dot_ids[j]);
		out.push({
			.joint = j,
			.inv_mass = inv_mass[j],
			.trunk = trunk[j],
			.frozen = frozen.has(j),
			.floored = array::contains(standing, j),
			.limits = limits,
			.frame = limits.constrained ? joint_limit_frame(skeleton, view.dot_ids, limits) : (JointLimitFrame){},
		});
	}
}

<*
 The gesture's goals, then the pins, then the planted feet.

 @param [&inout] out : `Receives the goals, the gesture's first.`
 @param gesture : `The gesture's own goals, in the solve's frame.`
 @param locks : `The rig's pins.`
 @param dragged : `The dot in the user's hand; its pin doesn't hold it.`
 @param shift : `The ground correction from the solve's frame to the one shown.`
 @param palette : `The pose the gesture started from.`
 @param world : `The same pose's world rotations.`
 @param standing : `The joints the floor holds up.`
 @param planted : `Per entry of standing, whether it is planted.`
*>
fn void body_goals(List{PointGoal}* out, RigView* view, usz root, PointGoal[] gesture, PositionLock[] locks, uint dragged,
	Vec3 shift, Matrix4f[] palette, Quaternionf[] world, usz[] standing, bool[] planted)
{
	rig::Skeleton* skeleton = &view.skeleton;
	float h = skeleton.height();
	foreach (goal : gesture) out.push(goal);
	// In the rig's own order, so the answer does not depend on which pin was set
	// first.
	for (usz j = 0; j < skeleton.len(); j++)
	{
		sz i = lock_index_of(locks, view.dot_ids[j]);
		if (i < 0 || view.dot_ids[j] == dragged) continue;
		PositionLock lock = locks[(usz)i];
		if (tree_root_of(skeleton, j) != root || body_goal_of(out.array_view(), j) >= 0) continue;
		// A pin on the position alone keeps the part's angle too, softly, as the
		// gesture found it: not `lock.orient`, which is the angle it had when the
		// pin was set and may be long stale. A pin on the angle holds `lock.orient`
		// hard, and the body gives way before it does.
		bool keeps_angle = lock.position && !lock.rotation;
		out.push({
			.joint = j,
			.position = lock.position,
			.target = lock.target - shift,
			.rotation = lock.rotation || keeps_angle,
			.orient = keeps_angle ? world[j] : lock.orient,
			.turn_weight = keeps_angle ? POINT_POSE_PIN_SOFT_TURN : 0.0f,
		});
	}
	foreach (usz i, foot : standing)
	{
		if (!planted[i] || tree_root_of(skeleton, foot) != root || body_goal_of(out.array_view(), foot) >= 0) continue;
		// A foot the gesture itself takes hold of is being lifted, not stood on.
		if (under_the_gesture(skeleton, gesture, foot)) continue;
		// A toe under a pinned ankle rides on it when the pin holds the angle too.
		if (rides_a_pin(skeleton, out.array_view(), foot)) continue;
		out.push({ .joint = foot, .position = true, .target = skeleton.joints[foot].transform(palette[foot]) });
		// And the end of a short foot bone above a planted toe, so the foot stays flat
		// rather than pivoting on its toe as the leg folds. The toe and the heel fix
		// the line between them and leave the foot free to roll about it, so the heel
		// keeps its angle softly too, as a position pin does.
		int heel = skeleton.parents[foot];
		if (heel < 0 || (usz)heel == root || body_goal_of(out.array_view(), (usz)heel) >= 0) continue;
		if ((skeleton.joints[foot] - skeleton.joints[(usz)heel]).length() > h * CURL_CHAIN_SHARE) continue;
		out.push({
			.joint = (usz)heel,
			.position = true,
			.target = skeleton.joints[(usz)heel].transform(palette[(usz)heel]),
			.rotation = true,
			.orient = world[(usz)heel],
			.turn_weight = POINT_POSE_PIN_SOFT_TURN,
		});
	}
}

// The pin on this dot, or -1.
fn sz lock_index_of(PositionLock[] locks, uint dot_id)
{
	foreach (usz i, lock : locks) if (lock.dot_id == dot_id) return (sz)i;
	return -1;
}

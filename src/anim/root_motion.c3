<*
 Root motion: where a clip's travel lives.

 A walk can carry the figure forward on its hips (the usual authored form), on a
 dedicated root joint under the hips (what a game engine reads as root motion),
 or not at all (in place, for an engine that moves the character itself).

 **Travel** is the straight line from where the hips start to where they are at
 the clip's last key, spread evenly over time, the same rule import uses to take
 a walk off the treadmill. Sway and bob around that line stay on the hips.
 Across the ground plane always; height and turning (yaw about the vertical)
 only when asked.
**Pinned** travel is not a line: the hips are held over where they start at
every moment, so a walk that speeds up, curves or comes back stays on the spot.

 **The root joint** is a skeleton root with a single child (the hips) that sits
 near the floor below it, or one named like "root". A rig without one can be
 made in place but has nothing to carry root motion.

 Two uses share `move_root_in_pose`: the export applies it to every baked sample
 (exact, the project clip untouched), and `clip_root_moved` rewrites the clip's
 own keys for the Animations menu.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;

enum RootMotionMode : char
{
	KEEP,     // as authored
	IN_PLACE, // the figure stays where it starts
	ON_ROOT,  // the travel moves from the hips onto the root joint
}

struct RootMotionPolicy
{
	RootMotionMode mode;
	bool vertical; // move height changes with the travel, not only the ground plane
	bool turning;  // move the net turn about the vertical as well
	bool pinned;   // hold the hips over where they start at every moment, not just take off the start-to-end line
	bool turn_only; // leave the travel where it is and move only the turn
}

fn bool RootMotionPolicy.active(self) => self.mode != KEEP;

enum RootMotionOutcome : char
{
	MOVED,
	NO_TRAVEL,     // nothing to move: already in place, or already on the root joint
	NO_ROOT_JOINT, // ON_ROOT on a rig without one
	NO_KEYS,       // a clip too short to travel
	UNNAMED,       // a joint the change has to key has no name
}

<*
 The joints root motion is about: the dedicated root joint (-1 when the rig has
 none) and the hips, the joint whose travel is measured.
*>
struct MotionRoots
{
	sz root;
	sz hips;
}

// The root joint sits within this share of the rig's height of the floor, and
// the hips at least this far above it.
const float ROOT_JOINT_FLOOR @local = 0.1f;
const float ROOT_JOINT_BELOW_HIPS @local = 0.15f;

fn MotionRoots motion_roots(rig::Skeleton* skeleton, String[] names = {})
{
	usz joints = skeleton.len();
	if (joints == 0) return { -1, -1 };
	sz top = -1;
	for (usz j = 0; j < joints; j++)
	{
		if (skeleton.parents[j] < 0) { top = (sz)j; break; }
	}
	if (top < 0) return { -1, -1 };

	sz child = -1;
	usz children = 0;
	for (usz j = 0; j < joints; j++)
	{
		if (skeleton.parents[j] != top) continue;
		if (children++ == 0) child = (sz)j;
	}
	if (children != 1) return { -1, top };

	float height = skeleton.height();
	float floor = skeleton.joints[0].y;
	foreach (joint : skeleton.joints) floor = math::min(floor, joint.y);
	Vec3 at = skeleton.joints[(usz)top];
	Vec3 below = skeleton.joints[(usz)child];
	bool grounded = at.y <= floor + ROOT_JOINT_FLOOR * height
		&& below.y >= at.y + ROOT_JOINT_BELOW_HIPS * height;
	bool named = (usz)top < names.len && named_root(names[(usz)top]);
	if (grounded || named) return { top, child };
	return { -1, top };
}

fn bool named_root(String name) @local
{
	if (name.len < 4) return false;
	for (usz i = 0; i + 4 <= name.len; i++)
	{
		String part = name[i:4];
		if (part.len == 4 && (part[0] | 0x20) == 'r' && (part[1] | 0x20) == 'o'
			&& (part[2] | 0x20) == 'o' && (part[3] | 0x20) == 't') return true;
	}
	return false;
}

// A joint's world position and rotation under a pose, walked from its root.
fn void world_of(rig::Skeleton* skeleton, rig::Pose* pose, usz joint, Vec3* at, Quaternionf* turn)
{
	int parent = skeleton.parents[joint];
	if (parent < 0)
	{
		*at = skeleton.joints[joint] + pose.offsets[joint];
		*turn = pose.rotations[joint];
		return;
	}
	Vec3 above;
	Quaternionf above_turn;
	world_of(skeleton, pose, (usz)parent, &above, &above_turn);
	*at = above + above_turn.rotate_vec3(skeleton.joints[joint] - skeleton.joints[(usz)parent] + pose.offsets[joint]);
	*turn = above_turn.mul(pose.rotations[joint]).normalize();
}

// The part of a turn about the vertical, in radians.
fn float yaw_of(Quaternionf turn) @local
{
	float y = turn.v.y;
	float w = turn.v.w;
	if (math::abs(y) < 1.0e-9f && math::abs(w) < 1.0e-9f) return 0.0f;
	float angle = 2.0f * math::atan2(y, w);
	if (angle > (float)math::PI) angle -= 2.0f * (float)math::PI;
	if (angle < -(float)math::PI) angle += 2.0f * (float)math::PI;
	return angle;
}

fn Quaternionf yaw_turn(float angle) @local
	=> quaternion::from_axis_angle{float}({ 0, 1, 0 }, angle);

<*
 How far a joint travels between two poses, as the policy counts travel.
*>
struct RootTravel
{
	Vec3 hips_shift;
	float hips_yaw;
	Vec3 root_shift;
	float root_yaw;
	float until; // seconds over which the travel is spread
	// Pinned: where the hips and root joint start, held there at every sample.
	bool pinned;
	bool vertical;
	Vec3 hips_start;
	Vec3 root_start;
}

fn RootTravel measure_root_travel(rig::Skeleton* skeleton, MotionRoots roots, rig::Pose* first,
	rig::Pose* last, float until, RootMotionPolicy policy)
{
	RootTravel out = { .until = until, .pinned = policy.pinned && !policy.turn_only, .vertical = policy.vertical };
	if (roots.hips < 0) return out;
	Vec3 a;
	Vec3 b;
	Quaternionf ta;
	Quaternionf tb;
	world_of(skeleton, first, (usz)roots.hips, &a, &ta);
	world_of(skeleton, last, (usz)roots.hips, &b, &tb);
	out.hips_start = a;
	out.hips_shift = b - a;
	if (!policy.vertical) out.hips_shift.y = 0.0f;
	if (policy.turning) out.hips_yaw = yaw_of(tb.mul(ta.invert()).normalize());
	if (policy.turn_only) out.hips_shift = {};
	if (roots.root >= 0)
	{
		world_of(skeleton, first, (usz)roots.root, &a, &ta);
		world_of(skeleton, last, (usz)roots.root, &b, &tb);
		out.root_start = a;
		out.root_shift = b - a;
		if (!policy.vertical) out.root_shift.y = 0.0f;
		if (policy.turning) out.root_yaw = yaw_of(tb.mul(ta.invert()).normalize());
		if (policy.turn_only) out.root_shift = {};
	}
	return out;
}

<*
 Whether this travel is worth moving at all, measured against the rig.
*>
fn bool RootTravel.moves(self, float height, RootMotionMode mode)
{
	float least = math::max(height, 1.0e-6f) * 1.0e-4f;
	const float LEAST_TURN = 1.0e-4f;
	Vec3 hips = self.hips_shift;
	Vec3 root = self.root_shift;
	if (mode == IN_PLACE)
	{
		return hips.length() > least || root.length() > least
			|| math::abs(self.hips_yaw) > LEAST_TURN || math::abs(self.root_yaw) > LEAST_TURN;
	}
	return (hips - root).length() > least || math::abs(self.hips_yaw - self.root_yaw) > LEAST_TURN;
}

<*
 How far a pose strays from where a pinned travel starts, as the mode counts
 it: in place, the hips or root joint off their start; on the root joint, the
 hips off the root's own path.
*>
fn float RootTravel.strays(self, rig::Skeleton* skeleton, MotionRoots roots, rig::Pose* pose, RootMotionMode mode)
{
	if (roots.hips < 0) return 0.0f;
	Vec3 at;
	Quaternionf turn;
	world_of(skeleton, pose, (usz)roots.hips, &at, &turn);
	Vec3 hips = self.ground(at - self.hips_start);
	Vec3 root;
	if (roots.root >= 0)
	{
		world_of(skeleton, pose, (usz)roots.root, &at, &turn);
		root = self.ground(at - self.root_start);
	}
	if (mode == IN_PLACE) return math::max(hips.length(), root.length());
	return (hips - root).length();
}

// A shift as the travel counts it: the ground plane only, unless height moves too.
fn Vec3 RootTravel.ground(self, Vec3 shift)
{
	if (!self.vertical) shift.y = 0.0f;
	return shift;
}

// A world transform with the ramped travel taken off, turning about `pivot`.
fn void take_off(Vec3* at, Quaternionf* turn, Vec3 pivot, Vec3 shift, float yaw) @local
{
	Quaternionf back = yaw_turn(-yaw);
	*at = pivot + back.rotate_vec3(*at - pivot) - shift;
	*turn = back.mul(*turn).normalize();
}

<*
 Move a pose's travel at time `t`, exactly.

 In place: the root joint loses its own travel and the hips (with everything
 else hanging off the root) lose theirs. On the root joint: the root takes the
 hips' travel in place of its own, and everything under it keeps its world
 place. Only the root joint and its children change.

 @require roots.hips >= 0
*>
fn void move_root_in_pose(rig::Skeleton* skeleton, rig::Pose* pose, MotionRoots roots,
	RootMotionMode mode, RootTravel travel, float t)
{
	if (mode == KEEP) return;
	float through = travel.until > 0.0f ? math::clamp(t / travel.until, 0.0f, 1.0f) : 1.0f;
	Vec3 hips_shift = travel.hips_shift * through;
	float hips_yaw = travel.hips_yaw * through;
	Vec3 hips_at;
	Quaternionf hips_turn;
	world_of(skeleton, pose, (usz)roots.hips, &hips_at, &hips_turn);
	if (travel.pinned) hips_shift = travel.ground(hips_at - travel.hips_start);

	if (roots.root < 0)
	{
		if (mode != IN_PLACE) return;
		usz top = (usz)roots.hips;
		Vec3 at;
		Quaternionf turn;
		world_of(skeleton, pose, top, &at, &turn);
		take_off(&at, &turn, hips_at, hips_shift, hips_yaw);
		if (skeleton.parents[top] >= 0) return;
		pose.offsets[top] = at - skeleton.joints[top];
		pose.rotations[top] = turn;
		return;
	}

	usz root = (usz)roots.root;
	if (skeleton.parents[root] >= 0) return;
	Vec3 root_at;
	Quaternionf root_turn;
	world_of(skeleton, pose, root, &root_at, &root_turn);
	Vec3 root_pivot = root_at;
	Vec3 root_shift = travel.pinned ? travel.ground(root_at - travel.root_start) : travel.root_shift * through;

	// Where each child of the root belongs in the world once the root changes.
	usz joints = skeleton.len();
	List{usz} children;
	children.init(mem);
	defer children.free();
	List{Vec3} child_at;
	child_at.init(mem);
	defer child_at.free();
	List{Quaternionf} child_turn;
	child_turn.init(mem);
	defer child_turn.free();
	for (usz j = 0; j < joints; j++)
	{
		if (skeleton.parents[j] != (int)root) continue;
		Vec3 at;
		Quaternionf turn;
		world_of(skeleton, pose, j, &at, &turn);
		if (mode == IN_PLACE) take_off(&at, &turn, hips_at, hips_shift, hips_yaw);
		children.push(j);
		child_at.push(at);
		child_turn.push(turn);
	}

	take_off(&root_at, &root_turn, root_pivot, root_shift, travel.root_yaw * through);
	if (mode == ON_ROOT)
	{
		root_at += hips_shift;
		root_turn = yaw_turn(hips_yaw).mul(root_turn).normalize();
	}
	pose.offsets[root] = root_at - skeleton.joints[root];
	pose.rotations[root] = root_turn;

	Quaternionf into_root = root_turn.invert();
	foreach (sz i, j : children)
	{
		pose.offsets[j] = into_root.rotate_vec3(child_at[i] - root_at)
			- (skeleton.joints[j] - skeleton.joints[root]);
		pose.rotations[j] = into_root.mul(child_turn[i]).normalize();
	}
}

// The joints whose keys a root-motion change rewrites.
fn usz[] root_motion_joints(Allocator allocator, rig::Skeleton* skeleton, MotionRoots roots) @local
{
	List{usz} out;
	out.init(allocator);
	defer out.free();
	if (roots.root < 0)
	{
		if (roots.hips >= 0) out.push((usz)roots.hips);
	}
	else
	{
		out.push((usz)roots.root);
		for (usz j = 0; j < skeleton.len(); j++)
		{
			if (skeleton.parents[j] == (int)roots.root) out.push(j);
		}
	}
	return out.to_array(allocator);
}

// Seconds over which a clip's travel is spread: up to its last key.
fn float travel_until(AnimTemplate clip)
{
	if (clip.keyframes.len == 0) return 0.0f;
	return math::min(clip.keyframes[clip.keyframes.len - 1].time, clip.duration);
}

<*
 The clip with its travel moved, rewritten as keys.

 The root joint (or the hips on a rig without one) and the root's children are
 keyed at every time any of them was keyed, plus the start and the last key, with
 the values `move_root_in_pose` gives the sampled pose there. Between keys the
 clip's own interpolation carries the new values, so an eased or smooth span
 follows its travel closely rather than exactly. With turning, rotation keys are
 carried back into the clip's own bone frame.

 @param names : `The rig's joints in the clip's words.`
 @param out : `The rewritten clip, owned, when this returns MOVED.`
*>
fn RootMotionOutcome clip_root_moved(Allocator allocator, AnimTemplate source, rig::Skeleton* skeleton,
	String[] names, RootMotionPolicy policy, AnimTemplate* out)
{
	if (!policy.active()) return NO_TRAVEL;
	MotionRoots roots = motion_roots(skeleton, names);
	if (roots.hips < 0) return NO_KEYS;
	if (policy.mode == ON_ROOT && roots.root < 0) return NO_ROOT_JOINT;
	float until = travel_until(source);
	if (until <= 0.0f) return NO_KEYS;

	usz[] moved = root_motion_joints(mem, skeleton, roots);
	defer alloc::free(mem, moved);
	foreach (j : moved)
	{
		if (j >= names.len || names[j].len == 0) return UNNAMED;
	}

	float height = skeleton.height();
	rig::Pose first = source.pose(mem, skeleton, names, 0.0f, false);
	defer first.free(mem);
	rig::Pose last = source.pose(mem, skeleton, names, until, false);
	defer last.free(mem);
	RootTravel travel = measure_root_travel(skeleton, roots, &first, &last, until, policy);
	// Pinned, an out-and-back walk ends where it began, so look at every key.
	bool moves = travel.moves(height, policy.mode);

	// Every time one of the moved joints is keyed, and the two ends of the travel.
	List{float} times;
	times.init(mem);
	defer times.free();
	times.push(0.0f);
	foreach (frame : source.keyframes)
	{
		bool keyed = false;
		foreach (dot : frame.dots)
		{
			foreach (j : moved) if (dot.joint_name == names[j]) keyed = true;
		}
		if (keyed || math::abs(frame.time - until) < ANIM_SAME_TIME) times.push(frame.time);
	}
	times.push(until);
	if (!moves && travel.pinned)
	{
		float least = math::max(height, 1.0e-6f) * 1.0e-4f;
		foreach (t : times.array_view())
		{
			rig::Pose pose = source.pose(mem, skeleton, names, t, false);
			defer pose.free(mem);
			if (travel.strays(skeleton, roots, &pose, policy.mode) > least) { moves = true; break; }
		}
	}
	if (!moves) return NO_TRAVEL;

	Vec3[] bones = skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	float unit = height > 0.0f ? height : 1.0f;

	AnimTemplate current = clip_copy(allocator, source);
	float previous = -1.0f;
	foreach (t : times.array_view())
	{
		if (previous >= 0.0f && math::abs(t - previous) < ANIM_SAME_TIME) continue;
		previous = t;
		rig::Pose pose = source.pose(mem, skeleton, names, t, false);
		defer pose.free(mem);
		move_root_in_pose(skeleton, &pose, roots, policy.mode, travel, t);

		AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, (sz)moved.len);
		Quaternionf root_authored = quaternion::IDENTITY;
		foreach (usz i, j : moved)
		{
			AnimKeyDot dot = {
				.joint_name = names[j].copy(allocator),
				.channels = policy.turning ? BOTH : TRANSLATION,
				.move = pose.offsets[j] / unit,
			};
			if (policy.turning)
			{
				Vec3 source_bone = clip_bone_of(source, names[j]);
				Quaternionf onto = bone_carry(source_bone, j < bones.len ? bones[j] : (Vec3){});
				Quaternionf authored;
				if (skeleton.parents[j] < 0)
				{
					authored = onto.invert().mul(pose.rotations[j]).mul(onto).normalize();
					root_authored = authored;
				}
				else
				{
					usz parent = (usz)skeleton.parents[j];
					Quaternionf carried = pose.rotations[parent].mul(pose.rotations[j]);
					authored = root_authored.invert()
						.mul(onto.invert().mul(carried).mul(onto)).normalize();
				}
				axis_angle_of(authored, &dot.axis, &dot.angle);
				dot.bone = source_bone;
			}
			dots[i] = dot;
		}
		AnimTemplate next = clip_with_key(allocator, current, { .time = t, .dots = dots });
		current.free(allocator);
		current = next;
	}
	current.duration = source.duration;
	*out = current;
	return MOVED;
}

// The bone direction a clip recorded for a joint, or zero when it recorded none.
fn Vec3 clip_bone_of(AnimTemplate clip, String joint) @local
{
	foreach (frame : clip.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.joint_name == joint && dot.bone.length_sq() > 1.0e-12f) return dot.bone;
		}
	}
	return {};
}


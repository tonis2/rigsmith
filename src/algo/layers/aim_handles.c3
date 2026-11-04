<* The pure half of src/app/aim_edit.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 One target being moved: the target's name and where it is now, a fraction of
 rig height in model space. Owned, `target` included; see
 `AppState.drop_aim_draft`.
*>
struct AimDraft
{
	String target;
	Vec3 at;
}

<*
 One look-at target as the viewport shows it, built beside `posed_dots`. One per
 target of the clip, locked to a joint or not. `target` is an owned copy of the
 target's name; free a list of them with `free_aim_handles`.
*>
struct AimHandle
{
	String target;
	Vec3 at;    // the target, in model units
	bool muted; // the target is muted
}

<*
 One lock as the viewport draws it: a line from the locked joint to the handle
 `handle` (an index into `posed_aims`) of its target. `muted` is the lock or its
 target.
*>
struct AimLink
{
	usz handle;
	uint dot;       // the locked joint's dot id
	Vec3 joint_at;  // where the joint is, in model units
	bool muted;
}

// Free handles built by `aim_handles`.
fn void free_aim_handles(AimHandle[] handles)
{
	foreach (&handle : handles) if (handle.target.len > 0) alloc::free(mem, handle.target.ptr);
	if (handles.len > 0) alloc::free(mem, handles);
}

// Stands in for `DragState.dot` during a target drag, which has no joint: a value
// no document dot has, so the "a gesture is active" readers still see non-zero
// and no lookup of it finds anything. The target is `DragState.aim`.
const uint AIM_DRAG_DOT = 0xFFFF_FFFF;

const usz NO_HANDLE = (usz)-1;

// How far in front of the joint a new target is put, as a share of rig height.
const float AIM_FRONT_REACH = 0.6f;

// How steeply the selected bones may point up or down (the sine of it) and still
// have a new target placed along them rather than out of their front.
const float AIM_UPRIGHT = 0.7f;

<*
 The aim axis, in the joint's own frame, that makes an aim at `at` (a fraction of
 rig height) turn nothing while the joint stands at `position` with rotation
 `world`; +Z when the target is on the joint.
*>
fn Vec3 aim_forward_for(Vec3 position, Quaternionf world, float height, Vec3 at)
{
	Vec3 to = at * height - position;
	if (to.length_sq() < 1.0e-12f) return { 0, 0, 1 };
	return world.invert().rotate_vec3(to.normalize());
}

<*
 Where `joint` stands in `pose` and which way it faces there: its world position
 and world rotation.

 @return `False when the palette could not be built.`
*>
fn bool aim_frame(RigView* view, rig::Pose pose, usz joint, Vec3* position, Quaternionf* world)
{
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return false;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? spun = pose.world_rotations(mem, &view.skeleton);
	if (catch spun) return false;
	Quaternionf[] rotations = spun;
	defer alloc::free(mem, rotations);
	if (joint >= palette.len || joint >= rotations.len) return false;
	*position = view.skeleton.joints[joint].transform(palette[joint]);
	*world = rotations[joint];
	return true;
}

// Whether joint `at` is one of `dots` other than `dots[i]`.
fn bool locked_with(RigView* view, uint[] dots, usz i, int at) @private
{
	foreach (usz k, other : dots) if (k != i && view.joint_of(other) == (sz)at) return true;
	return false;
}

<*
 What a fresh lock of `dots[i]` turns, among `dots` locked together.

 A joint locked alone spreads over three. Locked with others, each turns up its
 own limb as far as the next joint locked with it, at most three: a finger locked
 knuckle by knuckle gives each only its own turn, two heads each their necks.
 A leaf (a fingertip, a head-top) is the end of a bone, and turning it alone
 shows next to nothing: it is aimed with a weight of nothing while its parent and
 up to two above it — never the root — share the turn, so four fingertips locked
 together bend four whole fingers.
*>
fn void fresh_aim_spread(RigView* view, uint[] dots, usz i, AnimAim* lock) @private
{
	sz joint = view.joint_of(dots[i]);
	if (joint < 0) return;
	int[] parents = view.skeleton.parents;
	bool leaf = true;
	foreach (parent : parents) if (parent == (int)joint) { leaf = false; break; }
	int first = parents[(usz)joint];
	if (leaf && (first < 0 || locked_with(view, dots, i, first))) leaf = false;

	if (!leaf)
	{
		if (dots.len == 1) { lock.spread = 3; return; }
		// Steps up to the nearest joint locked with this one, three at most.
		usz steps = 0;
		for (int at = parents[(usz)joint]; at >= 0 && steps < 3; at = parents[(usz)at])
		{
			steps++;
			if (locked_with(view, dots, i, at)) break;
		}
		lock.spread = math::max(steps, (usz)1);
		return;
	}

	// The joints above the leaf that turn: its parent, then up to two more, short
	// of the root and of any joint locked with it.
	usz own = 1;
	for (int at = parents[(usz)first]; at >= 0 && own < 3; at = parents[(usz)at])
	{
		if (parents[(usz)at] < 0 || locked_with(view, dots, i, at)) break;
		own++;
	}
	lock.spread = own + 1;
	lock.weights[0] = 0.0f;
	for (usz k = 0; k < own; k++) lock.weights[k + 1] = AIM_DEFAULT_WEIGHTS[k];
	for (usz k = own + 1; k < AIM_MAX_SPREAD; k++) lock.weights[k] = 0.0f;
}

<*
 Where a new target goes, as a fraction of rig height: in front of the joints, or
 with none in front of the root at about chest height.

 @param dots : `The joints being locked.`
 @param positions : `Each one's world position.`
 @param worlds : `Each one's world rotation.`
 @param [&out] at : `Receives the spot.`
 @return `False when the pose can't be read.`
*>
fn bool aim_spot_for(RigView* view, rig::Pose pose, uint[] dots, Vec3[] positions, Quaternionf[] worlds, Vec3* at)
{
	float height = view.skeleton.height();
	Vec3 centre;
	Vec3 front = { 0, 0, 1 };
	if (dots.len > 0)
	{
		foreach (point : positions) centre += point;
		centre = centre / (float)dots.len;
		front = worlds[0].rotate_vec3({ 0, 0, 1 });
		if (front.length_sq() < 1.0e-12f) front = { 0, 0, 1 };
		front = front.normalize();
		// A limb held out — fingers, a hand, a foot — is aimed along where it
		// points, so moving the target bends it; one standing up, a head on its
		// neck, looks out its front.
		Vec3 along;
		foreach (dot : dots)
		{
			sz joint = view.joint_of(dot);
			int parent = joint >= 0 ? view.skeleton.parents[(usz)joint] : -1;
			Vec3 from;
			Quaternionf ignored;
			if (parent < 0 || !aim_frame(view, pose, (usz)parent, &from, &ignored)) continue;
			Vec3 to;
			if (!aim_frame(view, pose, (usz)joint, &to, &ignored)) continue;
			if ((to - from).length_sq() > 1.0e-12f) along += (to - from).normalize();
		}
		if (along.length_sq() > 1.0e-6f && math::abs(along.normalize().y) < AIM_UPRIGHT)
		{
			front = along.normalize();
		}
	}
	else
	{
		// Nothing selected: in front of the root, up about chest height.
		usz root;
		foreach (usz j, parent : view.skeleton.parents) if (parent < 0) { root = j; break; }
		Quaternionf ignored;
		if (!aim_frame(view, pose, root, &centre, &ignored)) return false;
		centre.y += 0.2f * height;
	}
	*at = (centre + front * (AIM_FRONT_REACH * height)) / height;
	return true;
}

<*
 One lock per joint on `target`: an existing lock keeps its settings and takes the
 new target and forward axis.

 @param aims : `The clip's locks.`
 @param names : `Each joint's name in the clip.`
 @param positions : `Each joint's world position.`
 @param worlds : `Each joint's world rotation.`
 @param dots : `Each joint's dot.`
 @param at : `The target, as a fraction of rig height.`
 @return `Owned by the caller.`
*>
fn AnimAim[] aim_locks_for(Allocator allocator, RigView* view, AnimAim[] aims, String[] names, Vec3[] positions,
	Quaternionf[] worlds, uint[] dots, String target, Vec3 at)
{
	float height = view.skeleton.height();
	AnimAim[] locks = alloc::new_array(allocator, AnimAim, (sz)names.len);
	foreach (i, &lock : locks)
	{
		Vec3 forward = aim_forward_for(positions[i], worlds[i], height, at);
		sz held = aim_index_of(aims, names[i]);
		if (held >= 0)
		{
			*lock = aims[(usz)held].copy(allocator);
			alloc::free(allocator, lock.target.ptr);
			lock.target = target.copy(allocator);
			lock.forward = forward;
		}
		else
		{
			*lock = aim_defaults(allocator, names[i], target, forward);
			fresh_aim_spread(view, dots, (usz)i, lock);
		}
	}
	return locks;
}

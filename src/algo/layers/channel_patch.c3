<* The pure half of src/mcp/patch.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// The most joints one call offsets. A patch is meant to be a few tracks; a call
// that names a whole biped is almost certainly a clip apply_clip should write.
const usz PATCH_JOINTS_MOST = 64;

// One joint to offset, resolved against the clip's rig.
struct PatchJoint
{
	String name;
	sz joint;              // skeleton index, -1 until resolved; only read for world space
	bool has_rotation;
	Quaternionf rotation;  // the additive turn
	bool has_move;
	Vec3 move;             // the additive slide, fraction of height
	bool world;            // space: false = parent frame (local), true = model frame
	usz rot_keys;          // how many rotation keys this joint's patch touched
	usz move_keys;
}

// Whether this joint's channel should be keyed at this instant: an edge always,
// an instant the joint already keys the channel at, or — for a whole-clip offset
// on a channel the joint never keys — the single fallback key at `start`.
fn bool channel_keyed_here(AnimTemplate* src, String name, bool rotation,
	float t, bool is_edge, bool whole, float start)
{
	if (is_edge) return true;
	foreach (frame : src.keyframes)
	{
		if (math::abs(frame.time - t) >= ANIM_SAME_TIME) continue;
		AnimKeyDot ignored;
		return frame.channel_dot(name, rotation, &ignored);
	}
	// The fallback key an unkeyed channel got in collect_channel_times.
	return whole && math::abs(t - start) < ANIM_SAME_TIME && src.channel_count(name, rotation) == 0;
}

// A time added to the list only if no near-equal one is there, so the joints'
// key sets and the range edges union into one set of distinct instants.
fn void push_unique(AnimFloatList* list, float t)
{
	foreach (held : list.array_view()) if (math::abs(held - t) < ANIM_SAME_TIME) return;
	list.push(t);
}

// Add the times where this joint keys this channel within the range: every one
// over the whole clip, the interior ones (edges are added separately) over a
// sub-range. A channel the joint never keys at all gets a key at `start`, so a
// whole-clip offset on an otherwise-unmoved joint is still expressed.
fn void collect_channel_times(AnimTemplate* src, String name, bool rotation,
	float start, float end, bool whole, AnimFloatList* into)
{
	foreach (frame : src.keyframes)
	{
		float t = frame.time;
		bool inside = whole
			? true
			: (t > start + ANIM_SAME_TIME && t < end - ANIM_SAME_TIME);
		if (!inside) continue;
		AnimKeyDot ignored;
		if (frame.channel_dot(name, rotation, &ignored)) push_unique(into, t);
	}
	if (whole && src.channel_count(name, rotation) == 0) push_unique(into, start);
}

// A joint's parent's world orientation at `time`, read from the clip's own
// rotations up the hierarchy. The skeleton supplies the parent chain and the
// names; the turns are the clip's. Shared with apply_clip's world-space keys.
fn Quaternionf parent_world_at(AnimTemplate* clip, RigView* view, sz joint, float time)
{
	Quaternionf world = quaternion::IDENTITY;
	if (joint < 0) return world;
	int parent = view.skeleton.parents[joint];
	while (parent >= 0)
	{
		String name = (usz)parent < view.names.len ? view.names[(usz)parent] : "";
		Quaternionf local = clip.rotation_at(name, time);
		world = local.mul(world).normalize();
		parent = view.skeleton.parents[(usz)parent];
	}
	return world;
}

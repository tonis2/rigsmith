<* The pure half of src/mcp/clip.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::quaternion;

// Which entry of this keyframe turns `name`, or `dots.len` when none does.
// Names are unique within a keyframe — `parse_clip` refuses a repeat — so the
// first match is the only one.
fn usz entry_turning(AnimKeyframe* frame, String name)
{
	if (name.len == 0) return frame.dots.len;
	foreach (d, dot : frame.dots)
	{
		if (dot.joint_name == name) return (usz)d;
	}
	return frame.dots.len;
}

// Whether an earlier entry already named this joint — how a walk over every
// keyframe lists the dots a clip moves once each rather than once per key.
fn bool named_earlier(AnimTemplate* clip, sz frame, sz dot, String name)
{
	foreach (f, held : clip.keyframes)
	{
		if (f > frame) return false;
		foreach (d, entry : held.dots)
		{
			if (f == frame && d >= dot) return false;
			if (entry.joint_name == name) return true;
		}
	}
	return false;
}

// What set_layer and patch_clip answer with when they move the root of a
// grounded clip up or down: the floor solve cancels that while a foot is down.
const String ROOT_Y_NOTE = `a move on the root's Y in a grounded clip is cancelled by the floor solve while a foot is down, so it changes nothing there; stance height comes from how the legs bend (get_crig_docs topic ground)`;

<*
 Rewrite this keyframe's world-space entries as the parent-relative turns a
 template stores.

 **Why the wire needs this at all.** `AnimTemplate.pose` composes
 `authored[j] = authored[parent] · turn`, so an entry's axis is read in whatever
 frame the joints above it have been turned into — the model's own axes only
 while none of them is turned. On a rig that rests in a T-pose and animates with
 the arms down, that makes an elbow's hinge depend on how far the shoulder has
 already rolled, which is not an arithmetic a caller who cannot see the rig can
 be asked to do. So a caller may state where the joint points instead, and this
 is where that becomes what the format holds.

 Two passes, both root-first, which `RigView.skeleton` guarantees:

 1. Every joint's world orientation under this keyframe — a world entry taken at
    its word, a local one carried through its parent, and a joint this keyframe
    does not name given its parent's exactly. That last is not an approximation:
    `pose` gives an undriven joint `authored[j] = from_parent` too, so the two
    agree by construction, and it is what lets a caller leave forty finger
    joints unwritten.
 2. Each world entry turned back into the turn that reproduces it,
    `R = Rw_parent⁻¹ · Rw`.

 `move` travels with the rotation, since `joint_palette` applies an offset in the
 parent's world frame as well. On a root the two frames are the same and this
 changes nothing, which is where a slide is usually written anyway.

 A local entry is left exactly as it arrived. Mixing the two inside one keyframe
 is well defined and useful: the shoulder absolutely, the elbow as a hinge off it.
*>
fn void sparse_to_parent_frame(RigView* view, AnimTemplate* clip, bool[][] in_world)
{
	// All keys of each ancestor are converted before descendants. An ancestor
	// absent at this frame still contributes its sampled sparse track, including
	// keys later in the clip and across the wrap interval.
	for (usz j = 0; j < view.skeleton.len(); j++)
	{
		foreach (usz f, frame : clip.keyframes)
		{
			usz at = entry_turning(&frame, j < view.names.len ? view.names[j] : "");
			if (at >= frame.dots.len || !in_world[f][at]) continue;
			Quaternionf back = parent_world_at(clip, view, (sz)j, frame.time).invert();
			AnimKeyDot* dot = &clip.keyframes[f].dots[at];
			if (dot.keys_rotation())
			{
				Quaternionf desired = quaternion::from_axis_angle{float}(dot.axis, dot.angle);
				axis_angle_of(back.mul(desired).normalize(), &dot.axis, &dot.angle);
			}
			if (dot.keys_translation()) dot.move = back.rotate_vec3(dot.move);
		}
	}
}

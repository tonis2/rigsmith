<* The pure half of src/app/layer_edit.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 The clip with its whole stack replaced by `next`, which is taken over.

 The caller lands the result (`land_clip` / `author_clip`).
*>
fn AnimTemplate clip_with_layers(Allocator allocator, AnimTemplate source, AnimLayer[] next)
{
	AnimTemplate clip = clip_copy(allocator, source);
	free_layers(allocator, clip.layers);
	clip.layers = next;
	return clip;
}

// A copy of the shared layer for a clip that does not have it yet: the motion,
// played the way a fresh layer is — full weight, the whole clip, no fades.
fn AnimLayer shared_layer_for(AnimLayer* shared, AnimLayerFit fit)
{
	AnimLayer copy = shared.copy(mem);
	copy.fit = fit;
	copy.weight = 1.0f;
	copy.mute = false;
	copy.solo = false;
	copy.start = copy.end = copy.fade_in = copy.fade_out = 0.0f;
	return copy;
}

// Whether the layer keys this joint's rotation (or translation) anywhere.
fn bool layer_keys_channel(AnimLayer* layer, String joint, bool rotation)
{
	foreach (&frame : layer.keyframes)
	{
		AnimKeyDot dot;
		if (frame.channel_dot(joint, rotation, &dot)) return true;
	}
	return false;
}

// `q` turned `factor` times as far: the same axis, the angle stretched. A
// half-turn or more is held just short of one so the shortest-way blend the
// evaluator uses still takes the intended side.
fn Quaternionf scaled_turn(Quaternionf q, float factor)
{
	if (factor == 1.0f) return q;
	Vec3 axis;
	float angle;
	if (!axis_angle_of(q, &axis, &angle)) return quaternion::IDENTITY;
	return quaternion::from_axis_angle{float}(axis, math::min(angle * factor, 3.1f));
}

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

fn String unused_layer_name(AnimTemplate* clip, String base)
{
	for (uint n = 1; n < 1000; n++)
	{
		String tried = n == 1 ? base : string::tformat("%s %d", base, n);
		bool taken = false;
		foreach (&layer : clip.layers) if (layer.name == tried) { taken = true; break; }
		if (!taken) return tried.copy(mem);
	}
	return base.copy(mem);
}

enum AnimKeyScope
{
	ALL,
	SELECTED,
	CHANGED,
}

<*
 What keying a pose into a layer needs. `below_clip` is the clip with only the
 layers under the active one.
*>
struct LayerKeyAsk
{
	rig::Skeleton* skeleton;
	String[] names;
	AnimTemplate* clip;
	AnimTemplate* below_clip;
	AnimLayer* layer;
	float time;
	float gain;
	rig::Pose below;   // the stack below, evaluated
	rig::Pose incl;    // the stack up to and including the layer, evaluated
	rig::Pose wanted;  // the pose the stack has to reach
	AnimKeyScope scope;
	bool[] selected;   // per joint
}

<*
 The pose the person made, with the layers above the active one taken back out.

 @param [&inout] wanted : `A copy of drafted; the answer.`
 @param full : `The whole stack, as on screen.`
 @param incl : `The stack up to and including the active layer.`
*>
fn void take_out_layers_above(rig::Pose* wanted, rig::Pose drafted, rig::Pose full, rig::Pose incl)
{
	foreach (usz j, turn : wanted.rotations)
	{
		if (j >= full.rotations.len) break;
		wanted.rotations[j] = (drafted.rotations[j].v - full.rotations[j].v).length_sq() < 1.0e-14f ? incl.rotations[j]
			: incl.rotations[j].mul(full.rotations[j].invert().mul(drafted.rotations[j])).normalize();
		wanted.offsets[j] = incl.offsets[j] + (drafted.offsets[j] - full.offsets[j]);
	}
}

<*
 The key that takes the stack to `ask.wanted`. Empty dots when nothing is keyed.

 @return `On mem, owned by the caller; its time is not yet the layer's.`
*>
fn AnimKeyframe layer_key_for(LayerKeyAsk* ask)
{
	AnimLayer* layer = ask.layer;
	String[] names = ask.names;
	float time = ask.time;
	float gain = ask.gain;
	rig::Pose below = ask.below;
	rig::Pose incl = ask.incl;
	rig::Pose wanted = ask.wanted;
	AnimKeyScope scope = ask.scope;

	// What the layer has to hold for the stack to reach `wanted`. A layer turns a
	// joint before the limits hold it and before it is carried onto the rig's
	// bones, so the gap is read against the stack below as keyed, and stated in
	// the bone frame the joint is carried from (see `AnimTemplate.pose`).
	rig::Pose below_raw = ask.below_clip.pose(mem, ask.skeleton, names, time, false);
	defer below_raw.free(mem);
	LayerStack under = ask.below_clip.layer_stack(mem, ask.skeleton, names, time);
	defer under.free(mem);
	Vec3[] bones = ask.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	Vec3[] sources = alloc::new_array(mem, Vec3, (sz)ask.skeleton.len());
	defer alloc::free(mem, sources);
	// Whether the joint differs on screen from the stack below: what decides it is keyed.
	bool[] differs = alloc::new_array(mem, bool, (sz)ask.skeleton.len());
	defer alloc::free(mem, differs);
	rig::Pose delta = rig::rest_pose(mem, ask.skeleton.len());
	defer delta.free(mem);
	float inverse_gain = 1.0f / gain;
	foreach (usz j, turn : delta.rotations)
	{
		String name = j < names.len ? names[j] : "";
		Vec3 target = j < bones.len ? bones[j] : (Vec3){};
		Vec3 source;
		Quaternionf kept_turn = name.len > 0 ? ask.clip.rotation_and_bone_at(name, time, &source) : quaternion::IDENTITY;
		Vec3 kept_slide;
		bool rotates, translates;
		under.apply(j, &kept_turn, &kept_slide, &rotates, &translates);
		if (source.length_sq() < 1.0e-12f) source = under.bone(j);
		if (source.length_sq() < 1.0e-12f) source = target;
		sources[j] = source;
		Quaternionf onto = bone_carry(source, target);
		differs[j] = angle_between_turns(below.rotations[j], wanted.rotations[j]) > 1.0e-5f;
		Quaternionf gap = below_raw.rotations[j].invert().mul(wanted.rotations[j]).normalize();
		Quaternionf step = onto.invert().mul(scaled_turn(gap, inverse_gain)).mul(onto).normalize();
		Vec3 slide = (wanted.offsets[j] - below.offsets[j]) * inverse_gain;
		if (layer.mode == ADDITIVE)
		{
			delta.rotations[j] = step;
			delta.offsets[j] = slide;
		}
		else
		{
			delta.rotations[j] = kept_turn.mul(step).normalize();
			delta.offsets[j] = below.offsets[j] + slide;
		}
	}
	AnimKeyframe key = keyframe_of_pose(mem, delta, names, bones, ask.skeleton.height(), time);
	foreach (&dot : key.dots)
	{
		sz j = array::index_of(names, dot.joint_name) ?? -1;
		if (j >= 0) dot.bone = sources[(usz)j];
	}

	// Which joints and channels are written. A sparse layer stays sparse: a
	// joint enters it by differing from the stack below, and stays in once keyed.
	// Nothing outside its mask, which would only be keys the layer never plays.
	bool[] inside = alloc::new_array(mem, bool, (sz)ask.skeleton.len());
	defer alloc::free(mem, inside);
	layer.mask_inside(ask.skeleton, names, inside);
	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : key.dots)
	{
		sz j = array::index_of(names, dot.joint_name) ?? -1;
		bool rotation, translation;
		if (j >= 0 && (usz)j < ask.selected.len && inside[(usz)j])
		{
			bool moved_rotation = differs[(usz)j];
			bool moved_translation = dot.move.length_sq() > 1.0e-12f;
			switch (scope)
			{
				case ALL:
					rotation = moved_rotation || layer_keys_channel(layer, dot.joint_name, true);
					translation = moved_translation || layer_keys_channel(layer, dot.joint_name, false);
				case SELECTED:
					rotation = translation = ask.selected[(usz)j];
				case CHANGED:
					rotation = 1.0f - math::abs(wanted.rotations[(usz)j].v.dot(incl.rotations[(usz)j].v)) > 1.0e-7f;
					translation = (wanted.offsets[(usz)j] - incl.offsets[(usz)j]).length_sq() > 1.0e-12f;
			}
		}
		if (!rotation && !translation)
		{
			if (dot.joint_name.len > 0) alloc::free(mem, dot.joint_name.ptr);
			continue;
		}
		AnimKeyDot written = dot;
		written.channels = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION);
		kept.push(written);
	}
	if (key.dots.len > 0) alloc::free(mem, key.dots);
	key.dots = kept.to_array(mem);
	return key;
}

<*
 A copy of the clip with `key` put into layer `at`. A shared layer keeps its own
 seconds: the key goes where the playhead falls among them, and a kept layer grows
 to hold one past its end.

 @return `Owned by the caller.`
*>
fn AnimTemplate clip_with_layer_key(Allocator allocator, AnimTemplate* clip, usz at, AnimKeyframe key, float time)
{
	AnimLayer* layer = &clip.layers[at];
	key.time = layer.key_time(clip, time);
	AnimTemplate keys = layer.keys_view(clip);
	key.ease_new_channels(&keys);
	AnimTemplate grown = clip_with_key(allocator, keys, key);
	AnimTemplate full_clip = clip_copy(allocator, *clip);
	AnimLayer* target = &full_clip.layers[at];
	foreach (&frame : target.keyframes) frame.free(allocator);
	if (target.keyframes.len > 0) alloc::free(allocator, target.keyframes);
	target.keyframes = grown.keyframes;
	grown.keyframes = {};
	if (target.own_clock())
	{
		if (target.fit == KEEP) target.length = math::max(target.length, grown.duration);
	}
	else
	{
		full_clip.duration = math::max(full_clip.duration, grown.duration);
	}
	grown.free(allocator);
	return full_clip;
}

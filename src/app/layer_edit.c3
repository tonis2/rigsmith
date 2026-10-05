<*
 Editing a clip's layer stack: the one path the Animations pane and the MCP
 `set_layer` / `merge_layers` tools both take.

 A layer is an adjustment laid over a clip's keys (anim/layers.c3). Everything a
 person or an agent does to the stack is *build the new stack aside, swap it in*:
 the clip is copied, its `layers` replaced, and the copy lands as one undo step
 (`land_clip` forks a library clip into the authored pack first, as any other
 edit does). Nothing here mutates a layer in place.

 **The active layer.** The pane works on one layer at a time, or on the base keys
 (`active_layer` == -1). It belongs to one clip (`active_layer_ref`): choosing
 another clip makes the base active again, and a stack that shrinks under it
 (undo, a delete) clamps it back to the base rather than pointing past the end.

 **Keys follow the active layer.** With a *keyed* layer active the timeline shows
 and edits that layer's keys, not the base's. The key editors all read the clip
 through `key_clip` and land through `land_key_edit`, which dress the layer's keys
 as a clip and fold the result back into the layer, so a move, delete, paste or
 ease edits the layer with no editor knowing about layers.

 **Keying into a layer stores a delta.** The pose on screen is the whole stack at
 the playhead; what a keyed layer has to hold is whatever makes the stack
 *up to and including that layer* reproduce it. So `key_into_layer` samples the
 stack below the layer and stores the difference:

 - ADDITIVE: rotation `inverse(below) * wanted`, translation `wanted - below`,
   both stretched by `1 / gain` so the layer at its weight (and fade) lands
   exactly on the pose.
 - OVERRIDE: the wanted local values, stretched the same way about `below`.

 **Layers above the active one are ignored while keying**, as in any layered
 tool: the pose on screen still carries them, so their contribution is taken back
 out (`incl * inverse(full) * draft`) and only the edit the person made goes into
 the layer. A layer that is silent at the playhead (weight 0, outside its range,
 faded out) cannot be keyed and says so.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// Stack arithmetic, shared with the MCP `set_layer` op

<*
 `source` with `layer` put in at `at` (0 = bottom of the stack). The layer is
 taken over; the returned array replaces `source`, which is released.
*>
fn AnimLayer[] layers_inserted(Allocator allocator, AnimLayer[] source, usz at, AnimLayer layer)
{
	AnimLayer[] grown = alloc::new_array(allocator, AnimLayer, (sz)(source.len + 1));
	usz write = 0;
	for (usz i = 0; i <= source.len; i++)
	{
		if (i == at) { grown[i] = layer; continue; }
		grown[i] = source[write++];
	}
	if (source.len > 0) alloc::free(allocator, source);
	return grown;
}

<*
 `source` without the layer at `at`, which is freed. The returned array replaces
 `source`, which is released.
*>
fn AnimLayer[] layers_removed(Allocator allocator, AnimLayer[] source, usz at)
{
	AnimLayer[] shrunk = alloc::new_array(allocator, AnimLayer, (sz)(source.len - 1));
	usz write = 0;
	for (usz i = 0; i < source.len; i++)
	{
		if (i == at) { source[i].free(allocator); continue; }
		shrunk[write++] = source[i];
	}
	alloc::free(allocator, source);
	return shrunk;
}

<*
 The layer at `at` moved to `dest`, the ones between shifting over by one.
*>
fn void layers_moved(AnimLayer[] layers, usz at, usz dest)
{
	AnimLayer moving = layers[at];
	if (dest > at)
	{
		for (usz i = at; i < dest; i++) layers[i] = layers[i + 1];
	}
	else
	{
		for (usz i = at; i > dest; i--) layers[i] = layers[i - 1];
	}
	layers[dest] = moving;
}

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

<*
 The clip's stack baked into its own keys, no layers left.

 Needs the open rig: a layer's chains and masks are read against its joints.
 Shared by `merge_layers` and the pane's Merge.

 @return? RIG_EMPTY : `There is no rig to read the stack against.`
*>
fn AnimTemplate? AppState.flattened_clip(&self, AnimRef ref)
{
	AnimTemplate* src = self.clip(ref);
	if (!src) return RIG_EMPTY~;
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);
	return clip_flattened(mem, *src, &view.skeleton, self.names_for(&view, ref));
}

// ---------------------------------------------------------------------------
// Which layer is active

<*
 The active layer of this clip, or -1 for the base. Anything that is not the
 clip the choice was made on, or an index the stack no longer has, is the base.
*>
fn sz AppState.active_layer_of(&self, AnimRef ref)
{
	if (!ref.valid()) return -1;
	// A different clip than the choice was made on: the base, and the choice is
	// forgotten so coming back to the first clip does not resurrect it.
	if (!ref.same(self.active_layer_ref))
	{
		self.active_layer_ref = ref;
		self.active_layer = -1;
		return -1;
	}
	if (self.active_layer < 0) return -1;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || self.active_layer >= (sz)clip.layers.len) return -1;
	return self.active_layer;
}

fn AnimLayer* AppState.active_layer_ptr(&self, AnimRef ref)
{
	sz at = self.active_layer_of(ref);
	return at < 0 ? null : &self.clip(ref).layers[(usz)at];
}

<*
 Choose the layer to work on (-1 = base). A different layer shows different
 keys, so the key selection, which names keys by time, is dropped.
*>
fn void AppState.set_active_layer(&self, AnimRef ref, sz index)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || index < -1 || index >= (sz)clip.layers.len) index = -1;
	sz before = self.active_layer_of(ref);
	self.active_layer_ref = ref;
	self.active_layer = index;
	if (before != index) self.clear_animation_key_selection();
	self.refresh_ui();
}

// The keyed layer key edits should act on, or null: the base is active, or the
// active layer is a generator (it holds no keys).
fn AnimLayer* AppState.keyed_layer_of(&self, AnimRef ref)
{
	AnimLayer* layer = self.active_layer_ptr(ref);
	return layer && layer.kind == KEYED ? layer : null;
}

// The active layer when it is a generator (wave, noise, pulse): it holds no keys,
// so the Curves view has nothing to draw or drag for it (`Graph.procedural`).
fn AnimLayer* AppState.procedural_layer_of(&self, AnimRef ref)
{
	AnimLayer* layer = self.active_layer_ptr(ref);
	return layer && layer.procedural() ? layer : null;
}

fn bool AppState.layer_keys_active(&self, AnimRef ref) => self.keyed_layer_of(ref) != null;

<*
 The clip whose keys the timeline edits: the clip itself, or with a keyed layer
 active a view of that layer's keys dressed as a clip (same name, length, loop and
 blend; no layers, no ground).

 Borrowed, and only good until the next edit lands — every editor reads it, builds
 a replacement and lands it through `land_key_edit`, which is what folds the
 replacement back into the layer.
*>
fn AnimTemplate* AppState.key_clip(&self, AnimRef ref)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return null;
	AnimLayer* layer = self.keyed_layer_of(ref);
	if (!layer) return clip;
	self.layer_keys_view = {
		.name = clip.name,
		.duration = clip.duration,
		.loop = clip.loop,
		.blend = clip.blend,
		.keyframes = layer.keyframes,
	};
	return &self.layer_keys_view;
}

<*
 Land a rewritten `key_clip` (see there): the replacement's keys go into the
 active layer of a copy of the real clip, which then lands as one undo step.
 With the base active it is exactly `land_clip`.

 `built` is taken over.
*>
fn AnimRef AppState.land_key_edit(&self, AnimRef ref, AnimTemplate built)
{
	AnimTemplate* clip = self.clip(ref);
	sz at = self.active_layer_of(ref);
	if (!clip || at < 0 || clip.layers[(usz)at].kind != KEYED) return self.land_clip(ref, built);

	AnimTemplate full = clip_copy(mem, *clip);
	AnimLayer* layer = &full.layers[(usz)at];
	foreach (&frame : layer.keyframes) frame.free(mem);
	if (layer.keyframes.len > 0) alloc::free(mem, layer.keyframes);
	layer.keyframes = built.keyframes;
	built.keyframes = {};
	full.duration = math::max(full.duration, built.duration);
	built.free(mem);
	return self.land_layered(ref, full);
}

// Land a clip that is this clip's successor, carrying the active-layer choice
// across a fork (a library clip edited for the first time moves packs).
fn AnimRef AppState.land_layered(&self, AnimRef ref, AnimTemplate built)
{
	bool held = self.active_layer_ref.same(ref);
	AnimRef landed = self.land_clip(ref, built);
	if (held && landed.valid()) self.active_layer_ref = landed;
	return landed;
}

// ---------------------------------------------------------------------------
// Stack edits. Each is one undo step.

fn String AppState.unused_layer_name(&self, AnimTemplate* clip, String base)
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

<*
 The names of the dots the viewport has selected, in rig order, for a layer's
 mask or for the joint a generator starts at. The caller frees the array and
 each name.
*>
fn String[] AppState.selected_joint_names(&self, Allocator allocator)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);
	StringList names;
	names.init(mem);
	defer names.free();
	foreach (usz j, name : view.names)
	{
		if (name.len == 0 || j >= view.dot_ids.len || !self.is_selected(view.dot_ids[j])) continue;
		names.push(name);
	}
	String[] out = alloc::new_array(allocator, String, (sz)names.len());
	foreach (usz i, name : names.array_view()) out[i] = name.copy(allocator);
	return out;
}

<*
 A fresh layer with the values the pane promises: a keyed layer starts with one
 identity key at 0 on the selected joints (or the first joint, so it is never an
 empty shell); a generator starts on the selected joint with a gentle move.
 The caller owns the result.
*>
fn AnimLayer AppState.default_layer(&self, AnimTemplate* clip, AnimLayerKind kind, AnimLayerMode mode)
{
	String base = "Keyed";
	switch (kind)
	{
		case KEYED: base = mode == OVERRIDE ? "Override" : "Keyed";
		case WAVE: base = "Wave";
		case NOISE: base = "Noise";
		case PULSE: base = "Pulse";
	}
	AnimLayer layer = anim_layer_defaults(self.unused_layer_name(clip, base));
	layer.kind = kind;
	layer.mode = mode;

	String[] picked = self.selected_joint_names(mem);
	defer
	{
		foreach (name : picked) name.free(mem);
		if (picked.len > 0) alloc::free(mem, picked);
	}
	String first = picked.len > 0 ? picked[0] : (self.doc.dots.len() > 0 ? self.doc.dots.array_view()[0].name : "");

	if (kind == KEYED)
	{
		StringList joints;
		joints.init(mem);
		defer joints.free();
		if (picked.len > 0) { foreach (name : picked) joints.push(name); }
		else if (first.len > 0) { joints.push(first); }
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, (sz)joints.len());
		foreach (usz i, name : joints.array_view())
		{
			dots[i] = { .joint_name = name.copy(mem), .channels = ROTATION, .axis = { 0, 1, 0 } };
		}
		layer.keyframes = alloc::new_array(mem, AnimKeyframe, 1);
		layer.keyframes[0] = { .time = 0.0f, .dots = dots };
		return layer;
	}

	layer.joint = first.len > 0 ? first.copy(mem) : "";
	layer.axis = { 0, 1, 0 };
	layer.amplitude = 15.0f * (float)math::PI / 180.0f;
	layer.cycles = 2.0f;
	layer.lag = 0.12f;
	layer.falloff = 1.1f;
	layer.width = 0.2f;
	layer.at = clip.duration * 0.5f;
	return layer;
}

<*
 Put a new layer on top of the clip's stack and make it the active one.

 @return `The index of the new layer, or -1 when the clip could not be edited.`
*>
fn sz AppState.add_clip_layer(&self, AnimRef ref, AnimLayerKind kind, AnimLayerMode mode)
{
	if (!self.ensure_clip_imported(ref)) return -1;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || clip.keyframes.len == 0) return -1;
	AnimLayer layer = self.default_layer(clip, kind, mode);
	AnimLayer[] next = layers_inserted(mem, layers_copy(mem, clip.layers), clip.layers.len, layer);
	usz top = next.len - 1;
	AnimRef landed = self.land_clip(ref, clip_with_layers(mem, *clip, next));
	if (!landed.valid()) return -1;
	self.set_active_layer(landed, (sz)top);
	return (sz)top;
}

<*
 The layer at `at` replaced by `changed`, which is taken over. The one door every
 parameter edit goes through.
*>
fn bool AppState.replace_clip_layer(&self, AnimRef ref, usz at, AnimLayer changed)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len) { changed.free(mem); return false; }
	AnimLayer[] next = layers_copy(mem, clip.layers);
	next[at].free(mem);
	next[at] = changed;
	return self.land_layered(ref, clip_with_layers(mem, *clip, next)).valid();
}

<*
 A copy of the layer at `at` for the caller to edit and hand back to
 `replace_clip_layer`; `layer.free(mem)` if it is not handed back.
*>
fn AnimLayer AppState.layer_copy_at(&self, AnimRef ref, usz at)
{
	AnimTemplate* clip = self.clip(ref);
	return clip && at < clip.layers.len ? clip.layers[at].copy(mem) : anim_layer_defaults("");
}

fn bool AppState.remove_clip_layer(&self, AnimRef ref, usz at)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len) return false;
	sz active = self.active_layer_of(ref);
	AnimLayer[] next = layers_removed(mem, layers_copy(mem, clip.layers), at);
	if (!self.land_layered(ref, clip_with_layers(mem, *clip, next)).valid()) return false;
	// The stack under the active layer keeps its place; one above it shifts down.
	if (active >= 0 && (usz)active > at) { active--; }
	else if (active >= 0 && (usz)active == at) { active = -1; }
	self.set_active_layer(self.editing, active);
	return true;
}

<*
 Move the layer one place toward the top of the stack (`up`) or the bottom, and
 keep it active if it was.
*>
fn bool AppState.move_clip_layer(&self, AnimRef ref, usz at, bool up)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len) return false;
	if ((up && at + 1 >= clip.layers.len) || (!up && at == 0)) return false;
	usz dest = up ? at + 1 : at - 1;
	sz active = self.active_layer_of(ref);
	AnimLayer[] next = layers_copy(mem, clip.layers);
	layers_moved(next, at, dest);
	if (!self.land_layered(ref, clip_with_layers(mem, *clip, next)).valid()) return false;
	if (active >= 0 && (usz)active == at) { active = (sz)dest; }
	else if (active >= 0 && (usz)active == dest) { active = (sz)at; }
	self.set_active_layer(self.editing, active);
	return true;
}

<*
 Bake the whole stack into the clip's own keys and clear it.

 @return `False when there is no rig, no layers, or the clip could not be edited.`
*>
fn bool AppState.merge_clip_layers(&self, AnimRef ref)
{
	if (!self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || clip.layers.len == 0) return false;
	AnimTemplate? flat = self.flattened_clip(ref);
	if (catch flat)
	{
		self.@notice("merging layers needs a rig: a layer's chains and masks are read against its joints");
		return false;
	}
	AnimRef landed = self.land_clip(ref, flat);
	if (!landed.valid()) return false;
	self.set_active_layer(landed, -1);
	return true;
}

// ---------------------------------------------------------------------------
// Keying into a layer

// Whether the layer keys this joint's rotation (or translation) anywhere.
fn bool layer_keys_channel(AnimLayer* layer, String joint, bool rotation) @local
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
fn Quaternionf scaled_turn(Quaternionf q, float factor) @local
{
	if (factor == 1.0f) return q;
	Vec3 axis;
	float angle;
	if (!axis_angle_of(q, &axis, &angle)) return quaternion::IDENTITY;
	return quaternion::from_axis_angle{float}(axis, math::min(angle * factor, 3.1f));
}

<*
 Key the pose on screen into the active keyed layer at `time`, as a delta from
 the stack below it (see the file header). `scope` has its usual meaning: ALL
 keys every joint that differs from what is below or that the layer already
 keys, SELECTED the selected joints, CHANGED only the channels that differ from
 what the layer gives now.

 @return `The reference to hold afterwards, or NO_ANIM when nothing was written.`
*>
fn AnimRef AppState.key_into_layer(&self, AnimRef ref, float time, AnimKeyScope scope = ALL)
{
	AnimTemplate* clip = self.clip(ref);
	sz at = self.active_layer_of(ref);
	if (!clip || at < 0) return NO_ANIM;
	AnimLayer* layer = &clip.layers[(usz)at];
	if (layer.kind != KEYED) return NO_ANIM;

	float gain = layer.gain_at(clip.layer_clock(time), clip.duration);
	if (gain < 1.0e-3f)
	{
		self.@notice("layer \"%s\" is silent at %.2fs (weight 0, outside its range or faded out) — raise its weight or move the playhead to key it", layer.name, time);
		return NO_ANIM;
	}

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("there is no rig to key a pose from");
		return NO_ANIM;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);

	// The stack as it is on screen, and the two stacks keying cares about: the
	// layers below the active one, and those up to and including it. Solo is an
	// auditioning aid, so the two are sampled without it.
	rig::Pose full = self.evaluated_clip_pose(mem, &view, *clip, ref, time, false);
	defer full.free(mem);
	AnimLayer[] stripped = alloc::new_array(mem, AnimLayer, (sz)clip.layers.len);
	defer alloc::free(mem, stripped);
	bool soloed = false;
	foreach (usz i, &other : clip.layers)
	{
		stripped[i] = *other;
		stripped[i].solo = false;
		if (other.solo && !other.mute) soloed = true;
	}
	AnimTemplate below_clip = *clip;
	below_clip.layers = stripped[:(usz)at];
	rig::Pose below = self.evaluated_clip_pose(mem, &view, below_clip, ref, time, false);
	defer below.free(mem);
	AnimTemplate incl_clip = *clip;
	incl_clip.layers = stripped[:(usz)at + 1];
	rig::Pose incl = self.evaluated_clip_pose(mem, &view, incl_clip, ref, time, false);
	defer incl.free(mem);

	// The pose the person made, with the layers above this one taken back out.
	rig::Pose drafted;
	if (!self.pose_edit_active && self.animating && self.anim_paused && self.current_ref.same(ref))
	{
		drafted = full.copy(mem);
	}
	else
	{
		drafted = self.draft_pose(mem, &view);
	}
	defer drafted.free(mem);
	rig::Pose wanted = drafted.copy(mem);
	defer wanted.free(mem);
	bool above = soloed || (usz)at + 1 < clip.layers.len;
	if (above)
	{
		foreach (usz j, turn : wanted.rotations)
		{
			if (j >= full.rotations.len) break;
			wanted.rotations[j] = (drafted.rotations[j].v - full.rotations[j].v).length_sq() < 1.0e-14f ? incl.rotations[j]
				: incl.rotations[j].mul(full.rotations[j].invert().mul(drafted.rotations[j])).normalize();
			wanted.offsets[j] = incl.offsets[j] + (drafted.offsets[j] - full.offsets[j]);
		}
	}

	// What the layer has to hold for the stack to reach `wanted`.
	rig::Pose delta = rig::rest_pose(mem, view.len());
	defer delta.free(mem);
	float inverse_gain = 1.0f / gain;
	foreach (usz j, turn : delta.rotations)
	{
		Quaternionf gap = below.rotations[j].invert().mul(wanted.rotations[j]).normalize();
		Vec3 slide = (wanted.offsets[j] - below.offsets[j]) * inverse_gain;
		if (layer.mode == ADDITIVE)
		{
			delta.rotations[j] = scaled_turn(gap, inverse_gain);
			delta.offsets[j] = slide;
		}
		else
		{
			delta.rotations[j] = below.rotations[j].mul(scaled_turn(gap, inverse_gain)).normalize();
			delta.offsets[j] = below.offsets[j] + slide;
		}
	}
	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	AnimKeyframe key = keyframe_of_pose(mem, delta, names, bones, view.skeleton.height(), time);

	// Which joints and channels are written. A sparse layer stays sparse: a
	// joint enters it by differing from the stack below, and stays in once keyed.
	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : key.dots)
	{
		sz j = array::index_of(names, dot.joint_name) ?? -1;
		bool rotation, translation;
		if (j >= 0 && (usz)j < view.dot_ids.len)
		{
			bool moved_rotation = dot.angle > 1.0e-5f;
			bool moved_translation = dot.move.length_sq() > 1.0e-12f;
			switch (scope)
			{
				case ALL:
					rotation = moved_rotation || layer_keys_channel(layer, dot.joint_name, true);
					translation = moved_translation || layer_keys_channel(layer, dot.joint_name, false);
				case SELECTED:
					rotation = translation = self.is_selected(view.dot_ids[(usz)j]);
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
	if (key.dots.len == 0)
	{
		key.free(mem);
		self.@notice(scope == SELECTED ? "select joints to key" : "nothing to key: the pose matches what is under layer \"%s\"", layer.name);
		return NO_ANIM;
	}

	// The layer's keys with this one put in, on a real copy of the clip.
	AnimTemplate keys = {
		.name = clip.name, .duration = clip.duration, .loop = clip.loop, .blend = clip.blend,
		.keyframes = layer.keyframes,
	};
	AnimTemplate grown = clip_with_key(mem, keys, key);
	AnimTemplate full_clip = clip_copy(mem, *clip);
	AnimLayer* target = &full_clip.layers[(usz)at];
	foreach (&frame : target.keyframes) frame.free(mem);
	if (target.keyframes.len > 0) alloc::free(mem, target.keyframes);
	target.keyframes = grown.keyframes;
	grown.keyframes = {};
	full_clip.duration = math::max(full_clip.duration, grown.duration);
	grown.free(mem);

	// As `key_here` does: the draft belongs to this editing transaction, not to
	// the playback restart the landing causes.
	PosedJoint[] draft = self.pose_edit_draft;
	bool active = self.pose_edit_active;
	bool pending = self.pose_edit_pending;
	self.pose_edit_draft = {};
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	// A moved target lands with the pose, on the base clip.
	AnimRef landed = self.land_layered(ref, self.with_aim_keys(full_clip, time));
	self.pose_edit_draft = draft;
	self.pose_edit_active = active;
	self.pose_edit_pending = pending;
	if (landed.valid()) self.drop_aim_draft();
	if (active) self.refresh_posed();
	return landed;
}

// ---------------------------------------------------------------------------
// Keying into the base under a layer stack

// Override weights at or above this leave nothing of what is underneath.
const float OVERRIDE_COVERS = 0.999f;

<*
 The base keyframe for the pose on screen, with the layers that are playing
 taken back out of it.

 The pose on screen (or the draft made from it) already carries the stack, so
 keying it into the base as it stands would bake the layers in and then play
 them a second time. Each joint's channels are walked down the stack from the
 top and every layer's step undone:

 - ADDITIVE: the layer's turn (stretched by its gain) and slide are taken back off.
 - OVERRIDE with weight below 1: the blend toward the layer's values is undone.
 - OVERRIDE covering the joint (weight 1 here, inside its mask): the base shows
   through nowhere, so there is nothing to recover. That channel is left out of
   the key — the base keeps whatever it had — and named in a notice.

 The stack is undone in the clip's own frame, which is the screen's when the
 clip's bones agree with the rig's (the ordinary case for a clip authored on it).

 @param sampled : `Take the pose from the clip at the time (a parked, unedited frame) instead of the open draft.`
 @return? RIG_EMPTY : `There is no rig to read a pose off.`
*>
fn AnimKeyframe? AppState.keyframe_under_layers(&self, AnimRef ref, AnimTemplate* clip, float time, bool sampled)
{
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);

	rig::Pose base = sampled
		? self.evaluated_clip_pose(mem, &view, *clip, ref, time, false)
		: self.draft_pose(mem, &view);
	defer base.free(mem);
	usz count = base.rotations.len;
	bool[] lost_rotation = alloc::new_array(mem, bool, (sz)count);
	bool[] lost_slide = alloc::new_array(mem, bool, (sz)count);
	defer
	{
		alloc::free(mem, lost_rotation);
		alloc::free(mem, lost_slide);
	}

	LayerStack stack = clip.layer_stack(mem, &view.skeleton, names, time);
	defer stack.free(mem);
	float height = view.skeleton.height();
	for (usz j = 0; j < count; j++)
	{
		for (sz l = (sz)stack.layers.len - 1; l >= 0; l--)
		{
			ActiveLayer* layer = &stack.layers[(usz)l];
			if (j >= layer.samples.len) continue;
			LayerSample s = layer.samples[j];
			if (s.rot && !lost_rotation[j])
			{
				if (layer.mode == ADDITIVE)
				{
					base.rotations[j] = base.rotations[j].mul(scaled_turn(s.turn, layer.gain).invert()).normalize();
				}
				else if (layer.gain >= OVERRIDE_COVERS)
				{
					lost_rotation[j] = true;
				}
				else
				{
					Quaternionf gap = s.turn.invert().mul(base.rotations[j]).normalize();
					base.rotations[j] = s.turn.mul(scaled_turn(gap, 1.0f / (1.0f - layer.gain))).normalize();
				}
			}
			if (s.move && !lost_slide[j])
			{
				Vec3 slide = s.offset * height;
				if (layer.mode == ADDITIVE)
				{
					base.offsets[j] = base.offsets[j] - slide * layer.gain;
				}
				else if (layer.gain >= OVERRIDE_COVERS)
				{
					lost_slide[j] = true;
				}
				else
				{
					base.offsets[j] = (base.offsets[j] - slide * layer.gain) * (1.0f / (1.0f - layer.gain));
				}
			}
		}
	}

	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	AnimKeyframe key = keyframe_of_pose(mem, base, names, bones, height, time);

	// Channels an override hides are not keyed: the base's own value stands.
	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	DString list;
	list.init(mem);
	defer list.free();
	usz covered;
	foreach (dot : key.dots)
	{
		sz j = array::index_of(names, dot.joint_name) ?? -1;
		bool rotation = j < 0 || !lost_rotation[(usz)j];
		bool slide = j < 0 || !lost_slide[(usz)j];
		if (!rotation || !slide)
		{
			if (covered > 0 && covered < 4) list.append(", ");
			if (covered < 4) list.append(dot.joint_name);
			if (covered == 4) list.append(", …");
			covered++;
		}
		if (!rotation && !slide)
		{
			if (dot.joint_name.len > 0) alloc::free(mem, dot.joint_name.ptr);
			continue;
		}
		AnimKeyDot written = dot;
		if (!rotation) written.channels = TRANSLATION;
		if (!slide) written.channels = ROTATION;
		kept.push(written);
	}
	if (key.dots.len > 0) alloc::free(mem, key.dots);
	key.dots = kept.to_array(mem);
	if (covered > 0)
	{
		self.@notice("%d joint%s fully overridden by a layer at %.2fs (%s): the base keys there are left as they were", covered,
			covered == 1 ? " is" : "s are", time, list.str_view());
	}
	return key;
}

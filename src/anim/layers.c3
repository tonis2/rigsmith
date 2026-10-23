<*
 Animation layers: a stack of adjustments on top of a clip's own keys.

 A clip is its base — the keys every reader has always seen — plus an ordered
 list of layers. A layer is either a second, sparse set of keys (a nod, a limp,
 a breath) or a generator (a wave travelling down a tail, noise on a hand, one
 pulse at a hit), and it is laid over the base with a weight, optionally for
 only part of the clip and only on some joints:

 - **ADDITIVE** adds to whatever is underneath. A keyed additive layer holds
   *deltas from rest* — identity and zero mean "no change" — so one breath
   layer rides on any walk. Per joint, in the clip's own (pre-retarget) frame,
   `turn := turn · slerp(I, delta, w)` and `slide += w · delta`.
 - **OVERRIDE** replaces what is underneath, blended by the weight, and only on
   the channels the layer actually keys: `turn := slerp(turn, layer, w)`.

 **Where it is evaluated.** Inside `AnimTemplate.pose`, on the per-joint turn
 and slide the base produced and *before* they are carried onto the rig's own
 bones. So every consumer that samples a pose — playback, render, get_pose,
 measure_clip, the physics bake, baked exports — sees the layers without being
 told about them, and everything after (retarget, joint limits, ground solve,
 secondary motion) works on the layered result exactly as it does on a base.

 **Where it is stored.** Layers live in the project sidecar only. A `.glb`
 carries no layer data and no engine reads any: what a file gets is the
 flattened channels — a baked export samples `pose`, and the writers that keep
 authored keys bake a layered clip first (`clip_flattened`).

 **Solo and mute.** Mute is part of the data. Solo is an editing aid: while any
 layer of a clip is solo only solo layers play, but an export ignores solo and
 uses mute alone, so a file never depends on which layer someone last
 auditioned.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::sort;

enum AnimLayerMode
{
	ADDITIVE,
	OVERRIDE,
}

enum AnimLayerKind
{
	KEYED,  // sparse keys in the clip's own format
	WAVE,   // a sine travelling down a chain, each joint lagging the last
	NOISE,  // three seeded sines that loop seamlessly
	PULSE,  // one gaussian bump at a moment in time
}

<*
 One layer of a clip. Every string and array is owned by the clip's allocator
 and released with it; see `AnimLayer.free`.

 The zero value is a muted-by-weight layer (weight 0), so anything building one
 states `weight`; `anim_layer_defaults` gives the values a caller who says
 nothing means.
*>
struct AnimLayer
{
	String name;
	bool mute;
	bool solo;    // editor-only: see the file comment
	float weight; // 0 to 1
	// Seconds the layer is active over. `end <= start` means the whole clip.
	float start;
	float end;
	float fade_in;  // seconds to ramp up from the start of the range (or clip)
	float fade_out; // seconds to ramp down to its end
	// Joints the layer touches; each entry includes everything below it. Empty
	// is the whole body.
	String[] mask;
	AnimLayerMode mode;
	AnimLayerKind kind;

	// KEYED. The clip's own keyframe format; additive values are deltas.
	AnimKeyframe[] keyframes;

	// Generators. `joint` starts the chain and `tip` ends it; with no tip the
	// chain follows single-child runs down from `joint`, as a secondary-motion
	// chain does.
	String joint;
	String tip;
	Vec3 axis;       // local axis the generator turns about
	float amplitude; // radians
	float cycles;    // per clip duration; rounded to a whole number on a looping clip
	float lag;       // wave: fraction of a cycle each joint down the chain trails
	float falloff;   // wave: amplitude multiplier per joint down the chain
	float phase;     // wave: fraction of a cycle
	uint seed;       // noise
	float at;        // pulse: seconds
	float width;     // pulse: seconds

	// Sharing. A layer one or more other clips also hold has a `link` (the same
	// id in each) and keeps its own clock: its keys span `length` seconds, and
	// each clip lays them on its own duration by its `fit`. Unshared, `length` is
	// zero and the keys are in the clip's own seconds.
	String link;
	float length;
	AnimLayerFit fit;

	// Strips. On the Layers sheet a layer is a strip on a track: strips higher up
	// play over lower ones, and strips on one track never overlap (see
	// `layers_settle_tracks`). A layer on its own clock is placed in time by
	// `offset` — the clip second its own zero lands on — and played `speed` of its
	// seconds per clip second (zero reads as one); a stretched one fills the clip
	// and ignores both.
	uint track;
	float offset;
	float speed;
	// A linked piece: the authored clip of the character this layer plays, its
	// keys a flattened copy of that clip kept up to date whenever it changes
	// (`AppState.sync_clip_pieces`). Empty for a layer of the clip's own.
	String source;
}

<*
 How a layer on its own clock meets a clip of another length.
*>
enum AnimLayerFit
{
	STRETCH, // its length spread over the clip's: a cycle stays one cycle
	KEEP,    // its own seconds, holding its last pose past its end
	REPEAT,  // its own seconds, over and over
}

<*
 A layer saying nothing beyond its name: full weight, additive, a wave about X.
*>
fn AnimLayer anim_layer_defaults(String name)
{
	return {
		.name = name,
		.weight = 1.0f,
		.mode = ADDITIVE,
		.kind = KEYED,
		.axis = { 1, 0, 0 },
		.amplitude = 0.2f,
		.cycles = 1.0f,
		.falloff = 1.0f,
		.width = 0.2f,
	};
}

fn bool AnimLayer.procedural(self) => self.kind != KEYED;

<*
 Whether the layer keeps its own clock: a shared layer's keys are stated over its
 own `length` and laid on each clip by its `fit`, rather than in the clip's
 seconds. A clip edit that moves time — a retime, a crop, a cut — leaves such
 keys alone.
*>
fn bool AnimLayer.own_clock(&self) => self.kind == KEYED && self.length > 0.0f;

<*
 The layer's keys as a clip to sample, borrowed for as long as the layer is. On
 the clip's clock that is the clip's length and loop. On its own clock it spans
 its own length: looping when its fit repeats it (or when the clip loops a
 stretched one), holding its ends when it keeps its seconds.
*>
fn AnimTemplate AnimLayer.keys_view(&self, AnimTemplate* clip)
{
	AnimTemplate view = {
		.name = clip.name,
		.duration = clip.duration,
		.loop = clip.loop,
		.blend = clip.blend,
		.keyframes = self.keyframes,
	};
	if (!self.own_clock()) return view;
	view.duration = self.length;
	if (self.fit == KEEP) view.loop = false;
	if (self.fit == REPEAT) view.loop = true;
	return view;
}

<*
 Where in its keys the layer is when the clip is at `time`: the clip's seconds
 on the clip's clock; on its own, the clip's place in its cycle, spread over the
 layer's length when it stretches. `keys_view` wraps a repeat.
*>
fn float AnimLayer.local_time(&self, AnimTemplate* clip, float time)
{
	if (!self.own_clock()) return time;
	float clock = clip.layer_clock(time);
	if (self.fit != STRETCH) return (clock - self.offset) * self.pace();
	if (!(clip.duration > 0.0f) || self.length == clip.duration) return clock;
	return clock * self.length / clip.duration;
}

<*
 How many of its own seconds the layer plays per clip second: its `speed`, or
 one when it states none. Only a layer on its own clock that is not stretched
 has a pace of its own.
*>
fn float AnimLayer.pace(&self) => self.speed > 0.0f ? self.speed : 1.0f;

<*
 Whether `offset` and `speed` place the layer: a layer on its own clock that
 keeps or repeats its seconds. A stretched one is spread over the whole clip.
*>
fn bool AnimLayer.placed(&self) => self.own_clock() && self.fit != STRETCH;

<*
 Where among its keys one made at the clip's `time` goes: `local_time`, with a
 repeated layer's folded back into its first pass.
*>
fn float AnimLayer.key_time(&self, AnimTemplate* clip, float time)
{
	float at = self.local_time(clip, time);
	if (!self.own_clock() || self.fit != REPEAT) return at;
	return at - self.length * math::floor(at / self.length);
}

// Two keyframe lists that say the same thing, entry for entry.
fn bool keyframes_same(AnimKeyframe[] a, AnimKeyframe[] b) @local
{
	if (a.len != b.len) return false;
	foreach (usz i, frame : a)
	{
		AnimKeyframe other = b[i];
		if (frame.time != other.time || frame.dots.len != other.dots.len) return false;
		foreach (usz d, dot : frame.dots)
		{
			AnimKeyDot them = other.dots[d];
			if (dot.joint_name != them.joint_name || dot.channels != them.channels
				|| dot.rotation_interpolation != them.rotation_interpolation
				|| dot.translation_interpolation != them.translation_interpolation
				|| dot.rotation_ease.start != them.rotation_ease.start || dot.rotation_ease.end != them.rotation_ease.end
				|| dot.translation_ease.start != them.translation_ease.start
				|| dot.translation_ease.end != them.translation_ease.end
				|| dot.axis != them.axis || dot.angle != them.angle || dot.move != them.move || dot.bone != them.bone)
			{
				return false;
			}
		}
	}
	return true;
}

<*
 Whether two copies of a shared layer carry the same motion: everything but how
 each clip plays it (weight, mute, solo, range, fades, fit, track, offset, speed)
 and the link itself.
*>
fn bool AnimLayer.same_shared(&self, AnimLayer* other)
{
	if (self.name != other.name || self.kind != other.kind || self.mode != other.mode) return false;
	if (self.length != other.length || self.joint != other.joint || self.tip != other.tip) return false;
	if (self.source != other.source) return false;
	if (self.axis != other.axis || self.amplitude != other.amplitude || self.cycles != other.cycles
		|| self.lag != other.lag || self.falloff != other.falloff || self.phase != other.phase
		|| self.seed != other.seed || self.at != other.at || self.width != other.width) return false;
	if (self.mask.len != other.mask.len) return false;
	foreach (usz i, entry : self.mask) if (entry != other.mask[i]) return false;
	return keyframes_same(self.keyframes, other.keyframes);
}

<*
 This layer's motion, as `local` plays it: a deep copy of `self` with `local`'s
 weight, mute, solo, range, fades and fit. What a shared layer's other copies
 become when one is edited.
*>
fn AnimLayer AnimLayer.shared_onto(&self, Allocator allocator, AnimLayer* local)
{
	AnimLayer out = self.copy(allocator);
	out.weight = local.weight;
	out.mute = local.mute;
	out.solo = local.solo;
	out.start = local.start;
	out.end = local.end;
	out.fade_in = local.fade_in;
	out.fade_out = local.fade_out;
	out.fit = local.fit;
	out.track = local.track;
	out.offset = local.offset;
	out.speed = local.speed;
	return out;
}

<*
 The index of this clip's layer that shares `link`, or -1.
*>
fn sz AnimTemplate.layer_linked(&self, String link)
{
	if (link.len == 0) return -1;
	foreach (usz i, &layer : self.layers) if (layer.link == link) return (sz)i;
	return -1;
}

<*
 How far one of the layer's seconds stretches on the clip's timeline: the clip's
 length over the layer's for a stretched layer on its own clock, 1 otherwise.
*>
fn float AnimLayer.display_scale(&self, AnimTemplate* clip)
{
	if (self.placed()) return 1.0f / self.pace();
	if (!self.own_clock() || !(clip.duration > 0.0f)) return 1.0f;
	return clip.duration / self.length;
}

<*
 Where the layer's own zero falls on the clip's timeline: its `offset` when it
 is placed, the clip's start otherwise. A key at `t` of its own shows at
 `t * display_scale + display_shift`.
*>
fn float AnimLayer.display_shift(&self) => self.placed() ? self.offset : 0.0f;

// Most repeats a repeated layer is laid out over, whatever its length.
const usz LAYER_REPEAT_LIMIT @local = 1024;

<*
 The instants in the clip's seconds the layer's keys fall at, up to the clip's
 end: as they are on the clip's clock, stretched on a stretched one, and every
 repeat of a repeated one. Writes as many as `out` has room for and answers how
 many there are, so an empty `out` counts them.
*>
fn usz AnimLayer.clip_key_times(&self, AnimTemplate* clip, float[] out)
{
	usz count;
	float duration = clip.duration;
	float scale = self.display_scale(clip);
	float shift = self.display_shift();
	float period = self.own_clock() && self.fit == REPEAT ? self.length * scale : 0.0f;
	// A repeat placed late still plays its earlier passes before its offset.
	float first = period > 0.0f && shift > 0.0f ? -math::ceil(shift / period) : 0.0f;
	for (usz k = 0; k < LAYER_REPEAT_LIMIT; k++)
	{
		float pass = shift + (first + (float)k) * period;
		if (pass > duration) break;
		foreach (frame : self.keyframes)
		{
			float at = frame.time * scale + pass;
			if (at > duration || at < 0.0f) continue;
			if (count < out.len) out[count] = at;
			count++;
		}
		if (period <= 0.0f) break;
	}
	return count;
}

<*
 The layer on the clip's own clock: a shared layer made independent. Its keys
 are restated in the clip's seconds the way its fit lays them — stretched, kept
 (holding past their end, cut at the clip's) or repeated across the clip — and it
 has no link or length of its own. A layer already on the clip's clock is only
 unlinked.
*>
fn AnimLayer AnimLayer.plain(&self, Allocator allocator, AnimTemplate* clip)
{
	AnimLayer out = self.copy(allocator);
	if (out.link.len > 0) alloc::free(allocator, out.link.ptr);
	if (out.source.len > 0) alloc::free(allocator, out.source.ptr);
	out.link = "";
	out.source = "";
	out.length = 0.0f;
	out.fit = STRETCH;
	out.offset = 0.0f;
	out.speed = 0.0f;
	if (!self.own_clock() || self.keyframes.len == 0) return out;

	float duration = clip.duration;
	float scale = self.display_scale(clip);
	float shift = self.display_shift();
	float period = self.fit == REPEAT ? self.length * scale : 0.0f;
	// The passes that reach the clip: from the one playing at its start (an
	// earlier one when the layer is placed late) to the one under its end.
	float first = 0.0f;
	usz repeats = 1;
	if (self.fit == REPEAT)
	{
		first = math::floor(-shift / period);
		repeats = math::clamp((usz)math::ceil((duration - shift) / period - first), (usz)1, LAYER_REPEAT_LIMIT);
	}
	// Laid out from `pad` on, so a pass before the clip's start has room, and
	// cropped back to the clip's seconds below.
	float pad = math::max(0.0f, -(shift + first * period));
	// One more for the held pose a kept layer ends on.
	AnimKeyframe[] laid = alloc::new_array(allocator, AnimKeyframe, (sz)(self.keyframes.len * repeats + 1));
	usz count;
	float last = -1.0f;
	for (usz k = 0; k < repeats; k++)
	{
		foreach (frame : self.keyframes)
		{
			float at = frame.time * scale + shift + (first + (float)k) * period + pad;
			if (count > 0 && at <= last + ANIM_SAME_TIME)
			{
				// A repeat's opening key meets the last pass's closing key. Saying the
				// same, one is enough. Otherwise the motion goes on from the opening
				// one, and the closing one steps back a hair so the jump between the
				// passes stays a jump — or goes, when there is no room before it.
				AnimKeyframe[1] closing = { laid[count - 1] };
				AnimKeyframe[1] opening = { frame };
				opening[0].time = closing[0].time;
				if (keyframes_same(closing[..], opening[..])) continue;
				float back = at - 2.0f * ANIM_SAME_TIME;
				if (count > 1 && back <= laid[count - 2].time + ANIM_SAME_TIME)
				{
					laid[count - 1].free(allocator);
					count--;
				}
				else
				{
					laid[count - 1].time = back;
				}
			}
			laid[count] = keyframe_copy(allocator, frame);
			laid[count].time = at;
			last = at;
			count++;
		}
	}
	// Kept seconds hold their last pose to the clip's end, where a looping clip
	// would otherwise wander back to the first.
	if (self.fit == KEEP && last < pad + duration - ANIM_SAME_TIME)
	{
		laid[count] = keyframe_copy(allocator, self.keyframes[^1]);
		laid[count].time = pad + duration;
		last = pad + duration;
		count++;
	}
	AnimTemplate keys = {
		.name = "keys",
		.duration = math::max(last, pad + duration),
		.blend = clip.blend,
		.keyframes = laid[:count],
	};
	AnimTemplate cut = last > pad + duration + ANIM_SAME_TIME || pad > 0.0f
		? clip_cropped(allocator, keys, pad, pad + duration)
		: clip_copy(allocator, keys);
	foreach (&frame : laid[:count]) frame.free(allocator);
	alloc::free(allocator, laid);
	foreach (&frame : out.keyframes) frame.free(allocator);
	if (out.keyframes.len > 0) alloc::free(allocator, out.keyframes);
	out.keyframes = cut.keyframes;
	cut.keyframes = {};
	cut.free(allocator);
	return out;
}

fn bool AnimTemplate.has_layers(&self) => self.layers.len > 0;

<*
 Whether any layer would contribute when the stack is evaluated.

 @param honor_solo : `False for an export: solo is an editing aid and is ignored, only mute counts.`
*>
fn bool AnimTemplate.plays_layers(&self, bool honor_solo = true)
{
	foreach (&layer : self.layers) if (layer.plays(self.layers, honor_solo)) return true;
	return false;
}

fn bool AnimLayer.plays(&self, AnimLayer[] stack, bool honor_solo)
{
	if (self.mute) return false;
	if (!honor_solo) return true;
	bool any_solo = false;
	foreach (&other : stack) if (other.solo && !other.mute) { any_solo = true; break; }
	return !any_solo || self.solo;
}

<*
 Release everything the layer owns.
*>
fn void AnimLayer.free(&self, Allocator allocator)
{
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	if (self.joint.len > 0) alloc::free(allocator, self.joint.ptr);
	if (self.tip.len > 0) alloc::free(allocator, self.tip.ptr);
	if (self.link.len > 0) alloc::free(allocator, self.link.ptr);
	if (self.source.len > 0) alloc::free(allocator, self.source.ptr);
	foreach (entry : self.mask) if (entry.len > 0) alloc::free(allocator, entry.ptr);
	if (self.mask.len > 0) alloc::free(allocator, self.mask);
	foreach (&frame : self.keyframes) frame.free(allocator);
	if (self.keyframes.len > 0) alloc::free(allocator, self.keyframes);
	*self = {};
}

fn void free_layers(Allocator allocator, AnimLayer[] layers)
{
	foreach (&layer : layers) layer.free(allocator);
	if (layers.len > 0) alloc::free(allocator, layers);
}

<*
 A deep copy of the layer, its times mapped `t' = t * scale + shift` — identity
 by default. A retime scales, a crop shifts; key times never go below zero. The
 keys of a layer on its own clock are its own and stay where they are; only its
 range and fades, which are the clip's seconds, move.
*>
fn AnimLayer AnimLayer.copy(&self, Allocator allocator, float scale = 1.0f, float shift = 0.0f)
{
	AnimLayer out = *self;
	// An empty string is left a literal: `copy` would allocate its terminator,
	// and `free` releases only what has a length.
	out.name = self.name.len > 0 ? self.name.copy(allocator) : "";
	out.joint = self.joint.len > 0 ? self.joint.copy(allocator) : "";
	out.tip = self.tip.len > 0 ? self.tip.copy(allocator) : "";
	out.link = self.link.len > 0 ? self.link.copy(allocator) : "";
	out.source = self.source.len > 0 ? self.source.copy(allocator) : "";
	out.mask = alloc::new_array(allocator, String, (sz)self.mask.len);
	foreach (usz i, entry : self.mask) out.mask[i] = entry.copy(allocator);
	out.keyframes = alloc::new_array(allocator, AnimKeyframe, (sz)self.keyframes.len);
	bool own = self.own_clock();
	foreach (usz i, frame : self.keyframes)
	{
		out.keyframes[i] = keyframe_copy(allocator, frame);
		if (!own) out.keyframes[i].time = math::max(0.0f, frame.time * scale + shift);
	}
	if (scale != 1.0f || shift != 0.0f)
	{
		out.start = math::max(0.0f, self.start * scale + shift);
		out.end = self.end > self.start ? math::max(out.start, self.end * scale + shift) : 0.0f;
		out.fade_in = self.fade_in * scale;
		out.fade_out = self.fade_out * scale;
		out.at = self.at * scale + shift;
		out.width = self.width * scale;
		// A placed layer plays the same stretch of the clip: its zero moves with
		// the clip's seconds, and a retime plays its own seconds as much slower.
		if (self.placed())
		{
			out.offset = self.offset * scale + shift;
			if (scale > 0.0f && scale != 1.0f) out.speed = self.pace() / scale;
		}
	}
	return out;
}

fn AnimLayer[] layers_copy(Allocator allocator, AnimLayer[] source, float scale = 1.0f, float shift = 0.0f)
{
	AnimLayer[] out = alloc::new_array(allocator, AnimLayer, (sz)source.len);
	foreach (usz i, &layer : source) out[i] = layer.copy(allocator, scale, shift);
	return out;
}

// ---------------------------------------------------------------------------
// Stack arithmetic, shared by the pane, the MCP `set_layer` op and the clip
// rewriters that build a layer (anim/keying.c3)

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
 The seconds of the clip a layer covers as a strip: its range, or the whole clip
 when it has none.
*>
fn void AnimLayer.span(&self, float duration, float* from, float* to)
{
	if (self.end > self.start)
	{
		*from = self.start;
		*to = self.end;
		return;
	}
	*from = 0.0f;
	*to = duration;
}

// Whether two strips share any stretch of time; touching ends do not count.
fn bool AnimLayer.overlaps(&self, AnimLayer* other, float duration)
{
	float a0, a1, b0, b1;
	self.span(duration, &a0, &a1);
	other.span(duration, &b0, &b1);
	return a0 < b1 - ANIM_SAME_TIME && b0 < a1 - ANIM_SAME_TIME;
}

<*
 Give every layer a track the Layers sheet can draw, in place. Tracks rise with
 the stack: a layer stays on the track of the one beneath it only when it asks
 for the same track and overlaps no strip already there; anything else — a
 higher track, a lower one, an overlap — goes on the next track up. So the
 tracks come out numbered from zero without gaps, strips on one track never
 overlap, and a stack that names no tracks (an older file, a fresh layer put on
 top) comes out one layer per track.
*>
fn void layers_settle_tracks(AnimLayer[] layers, float duration)
{
	uint[] rows = alloc::new_array(tmem, uint, (sz)layers.len);
	layers_settled_tracks(layers, duration, rows);
	foreach (usz i, &layer : layers) layer.track = rows[i];
}

<*
 The tracks `layers_settle_tracks` would give, into `rows` (one per layer),
 leaving the layers as they are: what a writer states for a stack built in
 memory that never went through the authored pack.
*>
fn void layers_settled_tracks(AnimLayer[] layers, float duration, uint[] rows)
{
	uint row;
	usz row_from;
	foreach (usz i, &layer : layers)
	{
		if (i > 0)
		{
			bool stays = layer.track == layers[i - 1].track;
			if (stays)
			{
				foreach (&other : layers[row_from:i - row_from]) if (layer.overlaps(other, duration)) { stays = false; break; }
			}
			if (!stays)
			{
				row++;
				row_from = i;
			}
		}
		rows[i] = row;
	}
}

<*
 Put the stack in track order, lower tracks first and each track's strips by
 their start, keeping the order of equals. `moved[i]` receives where the layer
 now at `i` was, when given (one slot per layer).
*>
fn void layers_sort_by_track(AnimLayer[] layers, float duration, usz[] moved = {})
{
	foreach (usz i, &slot : moved) *slot = i;
	for (usz i = 1; i < layers.len; i++)
	{
		AnimLayer held = layers[i];
		usz was = moved.len > i ? moved[i] : i;
		float held_from, held_to;
		held.span(duration, &held_from, &held_to);
		usz j = i;
		while (j > 0)
		{
			float from, to;
			layers[j - 1].span(duration, &from, &to);
			bool after = layers[j - 1].track > held.track || (layers[j - 1].track == held.track && from > held_from);
			if (!after) break;
			layers[j] = layers[j - 1];
			if (moved.len > j) moved[j] = moved[j - 1];
			j--;
		}
		layers[j] = held;
		if (moved.len > j) moved[j] = was;
	}
}

// ---------------------------------------------------------------------------
// Evaluation

// What one layer says about one joint at one instant: which channels it speaks
// to (independent of its weight), and the values.
struct LayerSample
{
	bool rot;
	bool move;
	Quaternionf turn;
	Vec3 offset; // fraction of rig height, like AnimKeyDot.move
	Vec3 bone;   // what a keyed layer's turn was recorded against; zero for a generator
}

struct ActiveLayer
{
	AnimLayerMode mode;
	float gain; // weight times the time window and fades
	LayerSample[] samples;
}

// The layers of one clip at one instant, sampled per joint.
struct LayerStack
{
	ActiveLayer[] layers;
}

fn void LayerStack.free(&self, Allocator allocator)
{
	foreach (&layer : self.layers) if (layer.samples.len > 0) alloc::free(allocator, layer.samples);
	if (self.layers.len > 0) alloc::free(allocator, self.layers);
	*self = {};
}

// The clock as layers see it: wrapped into the cycle on a looping clip, so the
// inclusive end sample a baked export takes reads exactly as the start does.
fn float AnimTemplate.layer_clock(&self, float time)
{
	if (!self.loop || !(self.duration > 0.0f)) return time;
	return time - self.duration * math::floor(time / self.duration);
}

<*
 The layer's multiplier at `time`: its weight inside its range, ramped by the
 fades, zero outside.
*>
fn float AnimLayer.gain_at(&self, float time, float duration)
{
	float gain = math::clamp(self.weight, 0.0f, 1.0f);
	float from = 0.0f;
	float to = duration;
	if (self.end > self.start)
	{
		from = self.start;
		to = self.end;
		if (time < from || time > to) return 0.0f;
	}
	if (self.fade_in > 0.0f && time < from + self.fade_in)
	{
		gain *= math::clamp((time - from) / self.fade_in, 0.0f, 1.0f);
	}
	if (self.fade_out > 0.0f && time > to - self.fade_out)
	{
		gain *= math::clamp((to - time) / self.fade_out, 0.0f, 1.0f);
	}
	return gain;
}

// Whole-number cycles on a looping clip, so the generator closes on itself; at
// least one, because rounding a small request to none would silently still it.
fn float AnimTemplate.loop_cycles(&self, float cycles)
{
	if (!self.loop || cycles <= 0.0f) return cycles;
	return math::max(1.0f, math::round(cycles));
}

// A small integer mixer. Only the seed's spread matters here, not its quality.
fn uint layer_hash(uint seed, uint salt) @local
{
	uint h = seed * 2654435761u + salt * 40503u + 374761393u;
	h ^= h >> 15;
	h *= 2246822519u;
	h ^= h >> 13;
	h *= 3266489917u;
	h ^= h >> 16;
	return h;
}

<*
 A noise layer's sample for link `k` of its chain at fraction `u` of the cycle.

 Three sines, integer multiples of the base frequency so the sum loops with the
 clip, each with a seeded multiple and phase; the weights sum to one, so the
 peak is the amplitude. Each link is also offset in phase, so a chain does not
 move in lockstep.
*>
fn float noise_angle(uint seed, float amplitude, float cycles, float u, usz k)
{
	const float[3] WEIGHTS = { 0.5f, 0.3f, 0.2f };
	float sum = 0.0f;
	for (uint i = 0; i < 3; i++)
	{
		uint h = layer_hash(seed, i);
		float multiple = (float)(i + 1 + (h % 2));
		float phase = (float)((h >> 8) % 1000) / 1000.0f;
		sum += WEIGHTS[i] * math::sin(2.0f * (float)math::PI
			* (multiple * cycles * u + phase + 0.13f * (float)k * (float)(i + 1)));
	}
	return amplitude * sum;
}

<*
 The joints a generator drives, in chain order.

 From `joint` to `tip` when a tip is named and lies below it, otherwise down
 from `joint` through every joint with exactly one child. An unknown joint is an
 empty chain; a tip that is not below `joint` is ignored.

 The caller owns the result.
*>
fn usz[] layer_chain(Allocator allocator, rig::Skeleton* skeleton, String[] names, String joint, String tip)
{
	usz count = skeleton.len();
	usz first = count;
	usz last = count;
	foreach (usz j, name : names)
	{
		if (j >= count) break;
		if (name == joint && first == count) first = j;
		if (tip.len > 0 && name == tip && last == count) last = j;
	}
	if (first == count) return {};

	usz[] run = alloc::new_array(allocator, usz, (sz)count);
	usz length = 0;
	if (last != count)
	{
		// Up from the tip; valid only if it meets the joint.
		usz walk = last;
		bool met = false;
		for (usz guard = 0; guard < count; guard++)
		{
			run[length++] = walk;
			if (walk == first) { met = true; break; }
			int parent = skeleton.parents[walk];
			if (parent < 0) break;
			walk = (usz)parent;
		}
		if (met)
		{
			for (usz i = 0; i < length / 2; i++)
			{
				usz swap = run[i];
				run[i] = run[length - 1 - i];
				run[length - 1 - i] = swap;
			}
			usz[] out = alloc::new_array(allocator, usz, (sz)length);
			foreach (usz i, joint_index : run[:length]) out[i] = joint_index;
			alloc::free(allocator, run);
			return out;
		}
		length = 0;
	}

	usz walk = first;
	for (usz guard = 0; guard < count; guard++)
	{
		run[length++] = walk;
		usz children = 0;
		usz only = count;
		foreach (usz j, parent : skeleton.parents)
		{
			if (parent == (int)walk) { children++; only = (usz)j; }
		}
		if (children != 1) break;
		walk = only;
	}
	usz[] out = alloc::new_array(allocator, usz, (sz)length);
	foreach (usz i, joint_index : run[:length]) out[i] = joint_index;
	alloc::free(allocator, run);
	return out;
}

<*
 Which joints the layer's mask lets it touch, one flag per joint of `inside`: a
 mask entry and everything below it, or every joint for an empty mask.
*>
fn void AnimLayer.mask_inside(&self, rig::Skeleton* skeleton, String[] names, bool[] inside)
{
	foreach (usz j, &flag : inside)
	{
		bool own = self.mask.len == 0;
		String name = j < names.len ? names[j] : "";
		if (!own) foreach (entry : self.mask) if (name.len > 0 && entry == name) { own = true; break; }
		int parent = j < skeleton.parents.len ? skeleton.parents[j] : -1;
		*flag = own || (parent >= 0 && inside[(usz)parent]);
	}
}

<*
 Whether the layer, unmuted, moves any of the joints `joints` flags anywhere in
 the clip: a keyed layer that keys one inside its mask, a generator whose chain
 runs through one.
*>
fn bool AnimLayer.drives_any(&self, Allocator allocator, rig::Skeleton* skeleton, String[] names, bool[] joints)
{
	if (self.mute) return false;
	usz count = skeleton.len();
	bool[] inside = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, inside);
	self.mask_inside(skeleton, names, inside);
	if (self.kind == KEYED)
	{
		foreach (&frame : self.keyframes) foreach (dot : frame.dots)
		{
			sz j = array::index_of(names, dot.joint_name) ?? -1;
			if (j >= 0 && (usz)j < count && (usz)j < joints.len && joints[(usz)j] && inside[(usz)j]) return true;
		}
		return false;
	}
	usz[] chain = layer_chain(allocator, skeleton, names, self.joint, self.tip);
	defer if (chain.len > 0) alloc::free(allocator, chain);
	foreach (j : chain) if (j < joints.len && joints[j] && inside[j]) return true;
	return false;
}

<*
 Sample one layer into `out`, one slot per joint, already limited to its mask.
 `clip` supplies the loop and blend a keyed layer is read under.
*>
fn void AnimLayer.sample(&self, Allocator allocator, AnimTemplate* clip,
	rig::Skeleton* skeleton, String[] names, float time, LayerSample[] out)
{
	usz count = out.len;
	bool[] inside = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, inside);
	self.mask_inside(skeleton, names, inside);

	float clock = clip.layer_clock(time);

	if (self.kind == KEYED)
	{
		AnimTemplate view = self.keys_view(clip);
		float at = self.local_time(clip, time);
		for (usz j = 0; j < count; j++)
		{
			String name = j < names.len ? names[j] : "";
			if (!inside[j] || name.len == 0) continue;
			if (view.channel_count(name, true) > 0)
			{
				out[j].rot = true;
				out[j].turn = view.rotation_and_bone_at(name, at, &out[j].bone);
			}
			if (view.channel_count(name, false) > 0)
			{
				out[j].move = true;
				out[j].offset = view.translation_at(name, at);
			}
		}
		return;
	}

	usz[] chain = layer_chain(allocator, skeleton, names, self.joint, self.tip);
	defer if (chain.len > 0) alloc::free(allocator, chain);
	float u = clip.duration > 0.0f ? clock / clip.duration : 0.0f;
	float cycles = clip.loop_cycles(self.cycles);
	Vec3 axis = self.axis.length_sq() > 1.0e-12f ? self.axis.normalize() : (Vec3){ 1, 0, 0 };
	float two_pi = 2.0f * (float)math::PI;
	foreach (usz k, j : chain)
	{
		if (!inside[j]) continue;
		float angle;
		switch (self.kind)
		{
			case WAVE:
				angle = self.amplitude * math::pow(self.falloff, (float)k)
					* math::sin(two_pi * (cycles * u - self.phase - self.lag * (float)k));
			case NOISE:
				angle = noise_angle(self.seed, self.amplitude, cycles, u, k);
			case PULSE:
			{
				float width = math::max(self.width, 1.0e-4f);
				float away = (clock - self.at) / width;
				angle = self.amplitude * math::exp(-away * away);
			}
			default:
				angle = 0.0f;
		}
		out[j].rot = true;
		out[j].turn = quaternion::from_axis_angle{float}(axis, angle);
	}
}

<*
 Sample every playing layer of this clip at `time`.

 Layers that are muted, silenced by another's solo, or at zero gain at this
 instant are left out. The caller frees the result.

 @param honor_solo : `False for an export; see the file comment.`
*>
fn LayerStack AnimTemplate.layer_stack(&self, Allocator allocator, rig::Skeleton* skeleton,
	String[] names, float time, bool honor_solo = true)
{
	if (self.layers.len == 0) return {};
	float clock = self.layer_clock(time);
	usz playing = 0;
	foreach (&layer : self.layers) if (layer.plays(self.layers, honor_solo)) playing++;
	if (playing == 0) return {};

	ActiveLayer[] active = alloc::new_array(allocator, ActiveLayer, (sz)playing);
	usz used = 0;
	foreach (&layer : self.layers)
	{
		if (!layer.plays(self.layers, honor_solo)) continue;
		float gain = layer.gain_at(clock, self.duration);
		if (gain <= 0.0f) continue;
		active[used] = {
			.mode = layer.mode,
			.gain = gain,
			.samples = alloc::new_array(allocator, LayerSample, (sz)skeleton.len()),
		};
		layer.sample(allocator, self, skeleton, names, time, active[used].samples);
		used++;
	}
	// The whole block, so `free` releases all of it; a slot left unused (a layer
	// at zero gain) holds no samples and `apply` passes over it.
	return { .layers = active };
}

<*
 Fold the stack into one joint's turn and slide, in order. The two flags are
 raised when a layer speaks to that channel, so a joint only layers drive is
 still a driven joint.
*>
fn void LayerStack.apply(&self, usz joint, Quaternionf* turn, Vec3* slide, bool* rotates, bool* translates)
{
	foreach (&layer : self.layers)
	{
		if (joint >= layer.samples.len) continue;
		LayerSample s = layer.samples[joint];
		// An override at full strength is its own values outright: the blend would
		// only round them (and a slerp of a key that is already the identity drops
		// a sliver of it), and a joint moved out of the base into one has to come
		// back exactly as it was.
		bool replaces = layer.mode == OVERRIDE && layer.gain >= 1.0f;
		if (s.rot)
		{
			if (replaces) { *turn = s.turn; }
			else
			{
				*turn = layer.mode == ADDITIVE
					? turn.mul(slerp_short(quaternion::IDENTITY, s.turn, layer.gain)).normalize()
					: slerp_short(*turn, s.turn, layer.gain);
			}
			*rotates = true;
		}
		if (s.move)
		{
			if (replaces) { *slide = s.offset; }
			else
			{
				*slide = layer.mode == ADDITIVE
					? *slide + s.offset * layer.gain
					: *slide + (s.offset - *slide) * layer.gain;
			}
			*translates = true;
		}
	}
}

<*
 The bone a joint's layered turn is carried from when the base does not key it:
 the first playing layer, from the bottom, that turns the joint and records one.
 Zero when none does. See `AnimTemplate.pose`.
*>
fn Vec3 LayerStack.bone(&self, usz joint)
{
	foreach (&layer : self.layers)
	{
		if (joint >= layer.samples.len) continue;
		LayerSample s = layer.samples[joint];
		if (s.rot && s.bone.length_sq() >= 1.0e-12f) return s.bone;
	}
	return {};
}

// ---------------------------------------------------------------------------
// Flattening

// Most keys a flattened clip is given.
const usz LAYER_FLAT_KEY_LIMIT = 4096;
// Samples per second at the least, and per cycle of the fastest generator.
const float LAYER_FLAT_MIN_RATE = 30.0f;
const float LAYER_FLAT_PER_CYCLE = 16.0f;

// The fastest thing the layers do, in cycles per second.
fn float AnimTemplate.layer_peak_hz(&self)
{
	float hz = 0.0f;
	float duration = math::max(self.duration, 1.0e-3f);
	foreach (&layer : self.layers)
	{
		if (layer.mute) continue;
		switch (layer.kind)
		{
			case WAVE: hz = math::max(hz, self.loop_cycles(layer.cycles) / duration);
			case NOISE: hz = math::max(hz, 4.0f * self.loop_cycles(layer.cycles) / duration);
			case PULSE: hz = math::max(hz, 0.5f / math::max(layer.width, 1.0e-3f));
			default: {}
		}
	}
	return hz;
}

<*
 `times` with the instants the layers need added: their own key times, and a
 uniform grid fine enough for the fastest generator. Sorted; consumes `times`.
 An added instant within `ANIM_SAME_TIME` of one already there is skipped.
*>
fn float[] layer_sample_times(Allocator allocator, AnimTemplate* clip, float[] times)
{
	if (!clip.plays_layers(false) || !(clip.duration > 0.0f)) return times;

	float rate = math::max(LAYER_FLAT_MIN_RATE, LAYER_FLAT_PER_CYCLE * clip.layer_peak_hz());
	usz steps = (usz)math::ceil(clip.duration * rate);
	if (steps > LAYER_FLAT_KEY_LIMIT) steps = LAYER_FLAT_KEY_LIMIT;

	float[] merged = alloc::new_array(allocator, float, (sz)(times.len + steps + 1));
	usz used = 0;
	foreach (time : times) merged[used++] = time;
	alloc::free(allocator, times);

	// Sorted already; each candidate is checked against the list by bisection.
	sort::quicksort(merged[:used]);
	usz keyed;
	foreach (&layer : clip.layers) if (!layer.mute) keyed += layer.clip_key_times(clip, {}) + 4;
	float[] extra = alloc::new_array(allocator, float, (sz)(steps + 1 + keyed));
	defer alloc::free(allocator, extra);
	usz extras = 0;
	for (usz i = 0; i <= steps; i++) extra[extras++] = clip.duration * (float)i / (float)steps;
	foreach (&layer : clip.layers)
	{
		if (layer.mute) continue;
		extras += layer.clip_key_times(clip, extra[extras..]);
		// A strip's edges and the corners of its fades, where its gain turns.
		float from, to;
		layer.span(clip.duration, &from, &to);
		float[4] corners = { from, to, from + layer.fade_in, to - layer.fade_out };
		foreach (corner : corners)
		{
			if (corner >= 0.0f && corner <= clip.duration) extra[extras++] = corner;
		}
	}
	for (usz i = 0; i < extras; i++)
	{
		bool near = false;
		for (usz j = 0; j < used; j++)
		{
			if (math::abs(merged[j] - extra[i]) < ANIM_SAME_TIME) { near = true; break; }
		}
		if (!near && used < merged.len) merged[used++] = extra[i];
	}
	sort::quicksort(merged[:used]);
	float[] out = alloc::new_array(allocator, float, (sz)used);
	foreach (usz i, time : merged[:used]) out[i] = time;
	alloc::free(allocator, merged);
	return out;
}

<*
 The clip with its unmuted layers baked into its keys, and no layers left.

 Sampled at the base's own instants plus the ones the layers need, each key
 holding the layered turn and slide in the clip's own frame — the same values
 `pose` composes before it carries them onto a rig, so the result plays
 identically. Keys are linear (the dense sampling carries the curve); name, loop,
 duration and ground are kept. Solo is ignored: only mute counts.

 A clip with nothing to bake comes back as a plain copy.

 @param times : `The base instants to keep; empty derives them from the keys.`
*>
fn AnimTemplate clip_flattened(Allocator allocator, AnimTemplate source,
	rig::Skeleton* skeleton, String[] names, float[] times = {})
{
	if (!source.plays_layers(false)) return clip_copy_without_layers(allocator, source);

	float[] at;
	if (times.len > 0)
	{
		at = alloc::new_array(allocator, float, (sz)times.len);
		foreach (usz i, t : times) at[i] = t;
	}
	else
	{
		at = alloc::new_array(allocator, float, (sz)source.keyframes.len);
		foreach (usz i, frame : source.keyframes) at[i] = frame.time;
	}
	at = layer_sample_times(allocator, &source, at);
	defer alloc::free(allocator, at);

	usz joints = skeleton.len();
	usz samples = at.len;
	Quaternionf[] turns = alloc::new_array(allocator, Quaternionf, (sz)(joints * samples));
	Vec3[] slides = alloc::new_array(allocator, Vec3, (sz)(joints * samples));
	bool[] drives_rot = alloc::new_array(allocator, bool, (sz)joints);
	bool[] drives_move = alloc::new_array(allocator, bool, (sz)joints);
	// For a joint only layers turn, the bone their keys record (see `pose`).
	Vec3[] layer_bones = alloc::new_array(allocator, Vec3, (sz)joints);
	defer
	{
		alloc::free(allocator, turns);
		alloc::free(allocator, slides);
		alloc::free(allocator, drives_rot);
		alloc::free(allocator, drives_move);
		alloc::free(allocator, layer_bones);
	}

	foreach (usz s, time : at)
	{
		LayerStack stack = source.layer_stack(allocator, skeleton, names, time, false);
		defer stack.free(allocator);
		for (usz j = 0; j < joints; j++)
		{
			String name = j < names.len ? names[j] : "";
			Quaternionf turn = quaternion::IDENTITY;
			Vec3 slide = {};
			bool rotates = name.len > 0 && source.channel_count(name, true) > 0;
			bool translates = name.len > 0 && source.channel_count(name, false) > 0;
			if (rotates) turn = source.rotation_at(name, time);
			if (translates) slide = source.translation_at(name, time);
			if (!rotates && layer_bones[j].length_sq() < 1.0e-12f) layer_bones[j] = stack.bone(j);
			stack.apply(j, &turn, &slide, &rotates, &translates);
			turns[s * joints + j] = turn;
			slides[s * joints + j] = slide;
			if (rotates) drives_rot[j] = true;
			if (translates) drives_move[j] = true;
		}
	}

	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)samples);
	foreach (usz s, time : at)
	{
		AnimDotList dots;
		dots.init(allocator);
		for (usz j = 0; j < joints; j++)
		{
			if (!drives_rot[j] && !drives_move[j]) continue;
			String name = names[j];
			AnimKeyDot dot = {
				.joint_name = name.copy(allocator),
				.channels = drives_rot[j] ? (drives_move[j] ? BOTH : ROTATION) : TRANSLATION,
				.axis = { 0, 1, 0 },
			};
			if (drives_rot[j]) axis_angle_of(turns[s * joints + j], &dot.axis, &dot.angle);
			if (drives_move[j]) dot.move = slides[s * joints + j];
			// The bone direction rides along so retargeting still applies: the base's,
			// or the layer's for a joint only a layer turns.
			dot.bone = source.channel_count(name, true) > 0 ? source.entry_at(name, time).bone : layer_bones[j];
			dots.push(dot);
		}
		frames[s] = { .time = time, .dots = dots.to_array(allocator) };
		dots.free();
	}

	AnimTemplate out = clip_with_frames(allocator, source, frames, source.duration);
	free_layers(allocator, out.layers);
	out.layers = {};
	out.blend = LINEAR;
	out.compile_tracks(allocator);
	return out;
}

// `clip_copy`, dropping the layers.
fn AnimTemplate clip_copy_without_layers(Allocator allocator, AnimTemplate source)
{
	AnimTemplate out = clip_copy(allocator, source);
	free_layers(allocator, out.layers);
	out.layers = {};
	return out;
}

// ---------------------------------------------------------------------------
// JSON — the scalar half shared by the sidecar and the MCP wire. The keyed
// content is each side's own format (the sidecar's `keys`, the wire's
// `keyframes`), so it is written and read by them.

fn String AnimLayerMode.wire(self) => self == OVERRIDE ? "override" : "additive";

fn String AnimLayerFit.wire(self)
{
	switch (self)
	{
		case STRETCH: return "stretch";
		case KEEP: return "keep";
		case REPEAT: return "repeat";
	}
}

fn bool parse_layer_fit(String text, AnimLayerFit* out)
{
	switch (text)
	{
		case "stretch": *out = STRETCH; return true;
		case "keep": *out = KEEP; return true;
		case "repeat": *out = REPEAT; return true;
		default: return false;
	}
}

fn String AnimLayerKind.wire(self)
{
	switch (self)
	{
		case KEYED: return "keyed";
		case WAVE: return "wave";
		case NOISE: return "noise";
		case PULSE: return "pulse";
	}
}

<*
 The layer's fields as members of a JSON object, each preceded by a comma —
 everything but the keyed content. Fields at their default are left out.
*>
fn void append_layer_fields(DString* out, AnimLayer* layer)
{
	out.append_string(`"name":`);
	append_json_string(out, layer.name);
	out.appendf(`,"kind":"%s","mode":"%s","weight":%s`, layer.kind.wire(), layer.mode.wire(),
		(JsonFloat)layer.weight)!!;
	if (layer.mute) out.append_string(`,"mute":true`);
	if (layer.solo) out.append_string(`,"solo":true`);
	if (layer.end > layer.start || layer.start > 0.0f)
	{
		out.appendf(`,"start":%s,"end":%s`, (JsonFloat)layer.start, (JsonFloat)layer.end)!!;
	}
	if (layer.fade_in > 0.0f) out.appendf(`,"fade_in":%s`, (JsonFloat)layer.fade_in)!!;
	if (layer.fade_out > 0.0f) out.appendf(`,"fade_out":%s`, (JsonFloat)layer.fade_out)!!;
	if (layer.mask.len > 0)
	{
		out.append_string(`,"mask":[`);
		foreach (usz i, entry : layer.mask)
		{
			if (i > 0) out.append_char(',');
			append_json_string(out, entry);
		}
		out.append_char(']');
	}
	if (layer.link.len > 0)
	{
		out.append_string(`,"link":`);
		append_json_string(out, layer.link);
	}
	if (layer.length > 0.0f) out.appendf(`,"length":%s`, (JsonFloat)layer.length)!!;
	if (layer.fit != STRETCH) out.appendf(`,"fit":"%s"`, layer.fit.wire())!!;
	out.appendf(`,"track":%d`, layer.track)!!;
	if (layer.offset != 0.0f) out.appendf(`,"offset":%s`, (JsonFloat)layer.offset)!!;
	if (layer.speed > 0.0f) out.appendf(`,"speed":%s`, (JsonFloat)layer.speed)!!;
	if (layer.source.len > 0)
	{
		out.append_string(`,"source":`);
		append_json_string(out, layer.source);
	}
	if (!layer.procedural()) return;
	out.append_string(`,"joint":`);
	append_json_string(out, layer.joint);
	if (layer.tip.len > 0)
	{
		out.append_string(`,"tip":`);
		append_json_string(out, layer.tip);
	}
	out.appendf(`,"axis":%s,"amplitude":%s`, (JsonVec3)layer.axis, (JsonFloat)layer.amplitude)!!;
	switch (layer.kind)
	{
		case WAVE:
			out.appendf(`,"cycles":%s,"lag":%s,"falloff":%s,"phase":%s`, (JsonFloat)layer.cycles,
				(JsonFloat)layer.lag, (JsonFloat)layer.falloff, (JsonFloat)layer.phase)!!;
		case NOISE:
			out.appendf(`,"cycles":%s,"seed":%d`, (JsonFloat)layer.cycles, layer.seed)!!;
		case PULSE:
			out.appendf(`,"at":%s,"width":%s`, (JsonFloat)layer.at, (JsonFloat)layer.width)!!;
		default: {}
	}
}

// A number field: untouched when absent, refused with a sentence when it is not
// a finite number. `detail` may be null, for a reader with nobody to tell.
fn bool layer_number(Object* obj, String key, float* into, DString* detail) @local
{
	Object* found = member(obj, key);
	if (found == null) return true;
	double? value = obj.get_float(key);
	if (catch value)
	{
		if (detail) detail.appendf(`layer "%s" must be a finite number`, key);
		return false;
	}
	if (!math::is_finite((float)value))
	{
		if (detail) detail.appendf(`layer "%s" must be a finite number`, key);
		return false;
	}
	*into = (float)value;
	return true;
}

fn bool layer_text(Object* obj, String key, Allocator allocator, String* into, DString* detail) @local
{
	Object* found = member(obj, key);
	if (found == null) return true;
	String? value = obj.get_string(key);
	if (catch value)
	{
		if (detail) detail.appendf(`layer "%s" must be a string`, key);
		return false;
	}
	if (into.len > 0) alloc::free(allocator, into.ptr);
	*into = value.len > 0 ? value.copy(allocator) : "";
	return true;
}

<*
 Read the layer fields `append_layer_fields` writes from a JSON object, on top
 of `layer` (which a caller seeds with `anim_layer_defaults`, or with the layer
 being replaced). Validates the values, not the joint names — that is the
 caller's, who knows the rig. Does not read keyed content.

 @param detail : `Filled with the refusal; may be null.`
 @return `False when a field is malformed or out of range.`
*>
fn bool read_layer_fields(Object* obj, Allocator allocator, AnimLayer* layer, DString* detail)
{
	if (obj == null || !obj.is_keyable())
	{
		if (detail) detail.append_string("a layer must be an object");
		return false;
	}
	if (!layer_text(obj, "name", allocator, &layer.name, detail)) return false;
	if (!layer_text(obj, "joint", allocator, &layer.joint, detail)) return false;
	if (!layer_text(obj, "tip", allocator, &layer.tip, detail)) return false;
	if (!layer_text(obj, "link", allocator, &layer.link, detail)) return false;
	if (!layer_text(obj, "source", allocator, &layer.source, detail)) return false;
	if (!layer_number(obj, "length", &layer.length, detail)) return false;
	if (!layer_number(obj, "offset", &layer.offset, detail)) return false;
	if (!layer_number(obj, "speed", &layer.speed, detail)) return false;
	if (!layer_number(obj, "weight", &layer.weight, detail)) return false;
	if (!layer_number(obj, "start", &layer.start, detail)) return false;
	if (!layer_number(obj, "end", &layer.end, detail)) return false;
	if (!layer_number(obj, "fade_in", &layer.fade_in, detail)) return false;
	if (!layer_number(obj, "fade_out", &layer.fade_out, detail)) return false;
	if (!layer_number(obj, "amplitude", &layer.amplitude, detail)) return false;
	if (!layer_number(obj, "cycles", &layer.cycles, detail)) return false;
	if (!layer_number(obj, "lag", &layer.lag, detail)) return false;
	if (!layer_number(obj, "falloff", &layer.falloff, detail)) return false;
	if (!layer_number(obj, "phase", &layer.phase, detail)) return false;
	if (!layer_number(obj, "at", &layer.at, detail)) return false;
	if (!layer_number(obj, "width", &layer.width, detail)) return false;

	if (member(obj, "seed") != null)
	{
		double? seed = obj.get_float("seed");
		if (catch seed)
		{
			if (detail) detail.append_string(`layer "seed" must be a whole number, zero or more`);
			return false;
		}
		if (seed < 0 || seed > 4.0e9)
		{
			if (detail) detail.append_string(`layer "seed" must be a whole number, zero or more`);
			return false;
		}
		layer.seed = (uint)seed;
	}
	if (member(obj, "track") != null)
	{
		double? track = obj.get_float("track");
		if (catch track)
		{
			if (detail) detail.append_string(`layer "track" must be a whole number, zero or more`);
			return false;
		}
		if (track < 0 || track > 1.0e6)
		{
			if (detail) detail.append_string(`layer "track" must be a whole number, zero or more`);
			return false;
		}
		layer.track = (uint)track;
	}
	if (member(obj, "mute") != null) layer.mute = obj.get_bool("mute") ?? false;
	if (member(obj, "solo") != null) layer.solo = obj.get_bool("solo") ?? false;

	if (member(obj, "axis") != null)
	{
		Vec3 axis;
		if (!as_vec3(member(obj, "axis"), &axis) || axis.length_sq() < 1.0e-12f
			|| !math::is_finite(axis.length_sq()))
		{
			if (detail) detail.append_string(`layer "axis" must be a non-zero [x,y,z], the local axis the generator turns about`);
			return false;
		}
		layer.axis = axis.normalize();
	}

	if (member(obj, "mode") != null)
	{
		String? mode = obj.get_string("mode");
		if (catch mode)
		{
			if (detail) detail.append_string(`layer "mode" must be "additive" or "override"`);
			return false;
		}
		if (mode != "additive" && mode != "override")
		{
			if (detail) detail.append_string(`layer "mode" must be "additive" or "override"`);
			return false;
		}
		layer.mode = mode == "override" ? OVERRIDE : ADDITIVE;
	}
	if (member(obj, "fit") != null)
	{
		String fit = obj.get_string("fit") ?? "";
		AnimLayerFit parsed;
		if (!parse_layer_fit(fit, &parsed))
		{
			if (detail) detail.append_string(`layer "fit" must be "stretch", "keep" or "repeat"`);
			return false;
		}
		layer.fit = parsed;
	}
	if (member(obj, "kind") != null)
	{
		String? kind = obj.get_string("kind");
		if (catch kind)
		{
			if (detail) detail.append_string(`layer "kind" must be "keyed", "wave", "noise" or "pulse"`);
			return false;
		}
		if (kind != "keyed" && kind != "wave" && kind != "noise" && kind != "pulse")
		{
			if (detail) detail.append_string(`layer "kind" must be "keyed", "wave", "noise" or "pulse"`);
			return false;
		}
		layer.kind = kind == "wave" ? WAVE : (kind == "noise" ? NOISE : (kind == "pulse" ? PULSE : KEYED));
	}

	if (member(obj, "mask") != null)
	{
		Object* mask = member(obj, "mask");
		if (!mask.is_array())
		{
			if (detail) detail.append_string(`layer "mask" must be an array of joint names; each includes the joints below it`);
			return false;
		}
		foreach (entry : layer.mask) if (entry.len > 0) alloc::free(allocator, entry.ptr);
		if (layer.mask.len > 0) alloc::free(allocator, layer.mask);
		layer.mask = alloc::new_array(allocator, String, (sz)mask.get_len());
		for (sz i = 0; i < mask.get_len(); i++)
		{
			String? entry = mask.get_string_at((usz)i);
			if (catch entry)
			{
				if (detail) detail.appendf(`layer "mask"[%d] must be a joint name`, i);
				return false;
			}
			if (entry.len == 0)
			{
				if (detail) detail.appendf(`layer "mask"[%d] must be a joint name`, i);
				return false;
			}
			layer.mask[(usz)i] = entry.copy(allocator);
		}
	}

	if (layer.name.len == 0)
	{
		if (detail) detail.append_string(`a layer needs a "name"`);
		return false;
	}
	if (layer.weight < 0.0f || layer.weight > 1.0f)
	{
		if (detail) detail.appendf(`layer "weight" is %.9g; it is 0 to 1`, layer.weight);
		return false;
	}
	if (layer.start < 0.0f || layer.fade_in < 0.0f || layer.fade_out < 0.0f || layer.cycles < 0.0f || layer.length < 0.0f
		|| layer.speed < 0.0f)
	{
		if (detail) detail.append_string(`layer "start", "fade_in", "fade_out", "cycles", "length" and "speed" cannot be negative`);
		return false;
	}
	if (layer.source.len > 0 && (layer.kind != KEYED || !(layer.length > 0.0f)))
	{
		if (detail) detail.append_string(`a layer with a "source" is a keyed piece on its own clock: it needs "kind":"keyed" and a "length"`);
		return false;
	}
	if (layer.procedural())
	{
		if (layer.joint.len == 0)
		{
			if (detail) detail.appendf(`a "%s" layer needs "joint": the joint its chain starts at`, layer.kind.wire());
			return false;
		}
		if (layer.kind == PULSE && !(layer.width > 0.0f))
		{
			if (detail) detail.append_string(`a "pulse" layer needs a "width" above zero, in seconds`);
			return false;
		}
	}
	return true;
}

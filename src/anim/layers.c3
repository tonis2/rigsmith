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
 by default. A retime scales, a crop shifts; key times never go below zero.
*>
fn AnimLayer AnimLayer.copy(&self, Allocator allocator, float scale = 1.0f, float shift = 0.0f)
{
	AnimLayer out = *self;
	// An empty string is left a literal: `copy` would allocate its terminator,
	// and `free` releases only what has a length.
	out.name = self.name.len > 0 ? self.name.copy(allocator) : "";
	out.joint = self.joint.len > 0 ? self.joint.copy(allocator) : "";
	out.tip = self.tip.len > 0 ? self.tip.copy(allocator) : "";
	out.mask = alloc::new_array(allocator, String, (sz)self.mask.len);
	foreach (usz i, entry : self.mask) out.mask[i] = entry.copy(allocator);
	out.keyframes = alloc::new_array(allocator, AnimKeyframe, (sz)self.keyframes.len);
	foreach (usz i, frame : self.keyframes)
	{
		out.keyframes[i] = keyframe_copy(allocator, frame);
		out.keyframes[i].time = math::max(0.0f, frame.time * scale + shift);
	}
	if (scale != 1.0f || shift != 0.0f)
	{
		out.start = math::max(0.0f, self.start * scale + shift);
		out.end = self.end > self.start ? math::max(out.start, self.end * scale + shift) : 0.0f;
		out.fade_in = self.fade_in * scale;
		out.fade_out = self.fade_out * scale;
		out.at = self.at * scale + shift;
		out.width = self.width * scale;
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
// Evaluation

// What one layer says about one joint at one instant: which channels it speaks
// to (independent of its weight), and the values.
struct LayerSample
{
	bool rot;
	bool move;
	Quaternionf turn;
	Vec3 offset; // fraction of rig height, like AnimKeyDot.move
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

fn Quaternionf slerp_short(Quaternionf a, Quaternionf b, float t) @local
{
	return (a.v.dot(b.v) < 0.0f ? a.slerp(-b, t) : a.slerp(b, t)).normalize();
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
 Sample one layer into `out`, one slot per joint, already limited to its mask.
 `clip` supplies the loop and blend a keyed layer is read under.
*>
fn void AnimLayer.sample(&self, Allocator allocator, AnimTemplate* clip,
	rig::Skeleton* skeleton, String[] names, float time, LayerSample[] out)
{
	usz count = out.len;
	bool[] inside = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, inside);
	for (usz j = 0; j < count; j++)
	{
		bool own = self.mask.len == 0;
		String name = j < names.len ? names[j] : "";
		if (!own) foreach (entry : self.mask) if (name.len > 0 && entry == name) { own = true; break; }
		int parent = skeleton.parents[j];
		inside[j] = own || (parent >= 0 && inside[(usz)parent]);
	}

	float clock = clip.layer_clock(time);

	if (self.kind == KEYED)
	{
		AnimTemplate view = {
			.duration = clip.duration,
			.loop = clip.loop,
			.blend = clip.blend,
			.keyframes = self.keyframes,
		};
		for (usz j = 0; j < count; j++)
		{
			String name = j < names.len ? names[j] : "";
			if (!inside[j] || name.len == 0) continue;
			if (view.channel_count(name, true) > 0)
			{
				out[j].rot = true;
				out[j].turn = view.rotation_at(name, time);
			}
			if (view.channel_count(name, false) > 0)
			{
				out[j].move = true;
				out[j].offset = view.translation_at(name, time);
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
		if (s.rot)
		{
			*turn = layer.mode == ADDITIVE
				? turn.mul(slerp_short(quaternion::IDENTITY, s.turn, layer.gain)).normalize()
				: slerp_short(*turn, s.turn, layer.gain);
			*rotates = true;
		}
		if (s.move)
		{
			*slide = layer.mode == ADDITIVE
				? *slide + s.offset * layer.gain
				: *slide + (s.offset - *slide) * layer.gain;
			*translates = true;
		}
	}
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
	float[] extra = alloc::new_array(allocator, float, (sz)(steps + 1 + clip.layer_key_count()));
	defer alloc::free(allocator, extra);
	usz extras = 0;
	for (usz i = 0; i <= steps; i++) extra[extras++] = clip.duration * (float)i / (float)steps;
	foreach (&layer : clip.layers)
	{
		if (layer.mute) continue;
		foreach (frame : layer.keyframes) if (frame.time <= clip.duration) extra[extras++] = frame.time;
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

fn usz AnimTemplate.layer_key_count(&self)
{
	usz count = 0;
	foreach (&layer : self.layers) count += layer.keyframes.len;
	return count;
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
	defer
	{
		alloc::free(allocator, turns);
		alloc::free(allocator, slides);
		alloc::free(allocator, drives_rot);
		alloc::free(allocator, drives_move);
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
			// The base's bone direction rides along so retargeting still applies.
			if (source.channel_count(name, true) > 0) dot.bone = source.entry_at(name, time).bone;
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
	if (layer.start < 0.0f || layer.fade_in < 0.0f || layer.fade_out < 0.0f || layer.cycles < 0.0f)
	{
		if (detail) detail.append_string(`layer "start", "fade_in", "fade_out" and "cycles" cannot be negative`);
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

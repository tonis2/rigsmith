<* The pure half of src/app/strips.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

enum PieceKind
{
	CLIP,   // another animation: linked when it is the character's own, copied from a library
	KEYED,  // a fresh keyed layer
	WAVE,
	NOISE,
	PULSE,
	SHARED, // a shared layer another clip of the character holds, by link
}

struct Piece
{
	PieceKind kind;
	AnimRef clip;  // CLIP
	String link;   // SHARED; borrowed
}

// How deep linked pieces may nest before a chain is taken for a loop.
const usz PIECE_DEPTH_MOST = 16;

<*
 The keys of a linked piece rewritten from `flat` (taken over), its length the
 source's; everything about how it plays here stays.
*>
fn void piece_refilled(AnimLayer* layer, AnimTemplate flat)
{
	foreach (&frame : layer.keyframes) frame.free(mem);
	if (layer.keyframes.len > 0) alloc::free(mem, layer.keyframes);
	layer.keyframes = flat.keyframes;
	layer.length = math::max(flat.duration, ANIM_SAME_TIME * 4.0f);
	flat.keyframes = {};
	flat.free(mem);
}

<*
 The layer moved `delta` seconds along the clip, a copy for the caller: its
 range (a whole-clip layer gets the clip as its range first), its fades with it,
 a clip-clock layer's keys, a placed layer's offset, a pulse's moment, a wave's
 phase. Never before the clip's start.
*>
fn AnimLayer strip_shifted(AnimLayer* layer, float delta, AnimTemplate* clip)
{
	AnimLayer ranged = *layer;
	if (ranged.end <= ranged.start)
	{
		ranged.start = 0.0f;
		ranged.end = clip.duration;
	}
	delta = math::max(delta, -ranged.start);
	AnimLayer out = ranged.copy(mem, 1.0f, delta);
	// A moved range is still the range it was, not one more whole-clip layer.
	out.end = ranged.end + delta;
	if (out.placed()) out.offset = layer.offset + delta;
	if (out.kind == WAVE && clip.duration > 0.0f) out.phase += clip.loop_cycles(out.cycles) * delta / clip.duration;
	return out;
}

fn uint AnimTemplate.track_count(&self)
{
	uint top = 0;
	foreach (&layer : self.layers) top = math::max(top, layer.track + 1);
	return top;
}

// A copy of the clip's stack with `layer` (taken over) at `at`.
fn AnimLayer[] replaced_layer(AnimTemplate* clip, usz at, AnimLayer layer)
{
	AnimLayer[] next = layers_copy(mem, clip.layers);
	next[at].free(mem);
	next[at] = layer;
	return next;
}

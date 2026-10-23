<*
 Layers as strips: placing pieces on a clip's tracks, moving, trimming, fading
 and speeding strips, and keeping linked pieces in step with the clips they play.

 The Layers sheet (ui/layer_sheet.c3) and the MCP `set_layer` ops come here.
 Every edit is layer_edit.c3's *build the new stack aside, swap it in*, one undo
 step through `land_layered`, with the stack put back in track order
 (`layers_sort_by_track`) and the active layer following the strip it was on.

 **A piece is something laid on a track.** Another animation of the character
 (linked: the strip plays it and follows every edit made to it), a library clip
 (copied in), a generator (wave, noise, pulse), a shared layer, or a fresh keyed
 layer.

 **A linked piece is a cache.** Its keys are the source clip flattened
 (`clip_flattened`: its keys with its own layers baked in), on its own clock of
 the source's length, so playback, bake and export read the clip holding it and
 nothing else. Whenever the source lands, `sync_clip_pieces` rebuilds every
 strip playing it inside the same undo step — `put_authored_clip` calls it, as
 it calls `sync_linked_layers`. A source renamed is followed; a source deleted
 leaves its strips as copies of what it last was.
*>
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
 Whether the authored clip `from`, or any clip it plays as a linked piece, all
 the way down, is the clip `to` — so laying `from` into `to` would have `to` play
 itself.
*>
fn bool AppState.piece_reaches(&self, String from, String to, usz depth = 0)
{
	if (from == to || depth > PIECE_DEPTH_MOST) return true;
	AnimRef held = self.clip_named_in_authored(from);
	if (!held.valid()) return false;
	foreach (&layer : self.clip(held).layers)
	{
		if (layer.source.len > 0 && self.piece_reaches(layer.source, to, depth + 1)) return true;
	}
	return false;
}

<*
 The source clip as a piece's keys: flattened, in the rig's words. Null-safe on
 a rig that will not open — the result is then empty.
*>
fn AnimTemplate? AppState.piece_keys(&self, AnimRef source)
{
	if (!self.ensure_clip_imported(source)) return RIG_EMPTY~;
	AnimTemplate* src = self.clip(source);
	if (!src) return RIG_EMPTY~;
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);
	AnimTemplate flat = clip_flattened(mem, *src, &view.skeleton, self.names_for(&view, source));
	return self.in_rig_words(flat, source);
}

<*
 The keys of a linked piece rewritten from `flat` (taken over), its length the
 source's; everything about how it plays here stays.
*>
fn void piece_refilled(AnimLayer* layer, AnimTemplate flat) @local
{
	foreach (&frame : layer.keyframes) frame.free(mem);
	if (layer.keyframes.len > 0) alloc::free(mem, layer.keyframes);
	layer.keyframes = flat.keyframes;
	layer.length = math::max(flat.duration, ANIM_SAME_TIME * 4.0f);
	flat.keyframes = {};
	flat.free(mem);
}

<*
 A new layer for `piece`, placed at `at` on the clip, for the caller to put on a
 track. Null-safe: a piece that cannot be made (no rig, an unknown link, a clip
 that would play itself) says why in a notice and answers false.
*>
fn bool AppState.piece_layer(&self, AnimRef ref, AnimTemplate* clip, Piece piece, float at, AnimLayer* out)
{
	switch (piece.kind)
	{
		case KEYED: *out = self.default_layer(ref, clip, KEYED, ADDITIVE);
		case WAVE: *out = self.default_layer(ref, clip, WAVE, ADDITIVE);
		case NOISE: *out = self.default_layer(ref, clip, NOISE, ADDITIVE);
		case PULSE:
			*out = self.default_layer(ref, clip, PULSE, ADDITIVE);
			out.at = at + out.width * 2.0f;
		case SHARED:
		{
			AnimRef holder = self.link_holder(piece.link, ref);
			if (!holder.valid() || clip.layer_linked(piece.link) >= 0)
			{
				self.@notice("that shared layer is not held by another animation, or this one has it already");
				return false;
			}
			AnimTemplate* from = self.clip(holder);
			*out = from.layers[(usz)from.layer_linked(piece.link)].copy(mem);
			out.weight = 1.0f;
			out.mute = out.solo = false;
			out.start = out.end = out.fade_in = out.fade_out = 0.0f;
			if (out.placed())
			{
				out.offset = at;
				out.start = at;
				out.end = at + out.length / out.pace();
			}
		}
		case CLIP:
		{
			AnimTemplate* src = self.clip(piece.clip);
			if (!src) return false;
			bool linked = piece.clip.pack == self.authored_pack;
			if (linked && self.piece_reaches(src.name, clip.name))
			{
				self.@notice("%s plays %s already, so it cannot be laid into it", src.name, clip.name);
				return false;
			}
			String name = src.name.copy(mem);
			defer name.free(mem);
			bool loops = src.loop;
			AnimTemplate? flat = self.piece_keys(piece.clip);
			if (catch flat)
			{
				self.@notice("laying an animation in needs a rig: its keys are read against the joints");
				return false;
			}
			*out = anim_layer_defaults(self.unused_layer_name(clip, name));
			out.kind = KEYED;
			out.mode = OVERRIDE;
			out.fit = loops ? REPEAT : KEEP;
			out.offset = at;
			piece_refilled(out, flat);
			if (linked) out.source = name.copy(mem);
			// One pass, or to the clip's end for a cycle.
			out.start = at;
			out.end = loops ? math::max(clip.duration, at + out.length) : at + out.length;
			return true;
		}
	}
	if (piece.kind != SHARED && piece.kind != PULSE && clip.duration > 0.0f)
	{
		// A generator or a fresh keyed layer covers the rest of the clip from where
		// it was put; at the start, that is the whole clip.
		if (at > ANIM_SAME_TIME)
		{
			out.start = at;
			out.end = clip.duration;
		}
		if (out.kind == WAVE) out.phase += clip.loop_cycles(out.cycles) * at / clip.duration;
		if (out.kind == KEYED)
		{
			foreach (&frame : out.keyframes) frame.time += at;
		}
	}
	if (piece.kind == PULSE)
	{
		out.start = at;
		out.end = math::min(clip.duration, at + out.width * 4.0f);
		if (out.end <= out.start + ANIM_SAME_TIME) out.end = clip.duration;
	}
	return true;
}

<*
 Land `next` as the clip's stack in track order, the active layer following the
 strip at `follow` (an index into `next` before sorting; -1 keeps the base).
 `next` is taken over.

 @return `The index the followed strip ends up at, or -1.`
*>
fn sz AppState.land_strips(&self, AnimRef ref, AnimTemplate* clip, AnimLayer[] next, sz follow)
{
	usz[] moved = alloc::new_array(mem, usz, (sz)next.len);
	defer alloc::free(mem, moved);
	layers_sort_by_track(next, clip.duration, moved);
	sz now = -1;
	foreach (usz i, was : moved) if ((sz)was == follow) now = (sz)i;
	AnimRef landed = self.land_layered(ref, clip_with_layers(mem, *clip, next));
	if (!landed.valid()) return -1;
	self.set_active_layer(landed, now);
	return now;
}

<*
 Lay `piece` on the clip at `at` seconds, on `track` (a track past the top makes
 a new one). A strip that would overlap another on that track goes on a new
 track of its own above. The new strip becomes the active layer. One undo step.

 @return `The new layer's index, or -1 when nothing was laid.`
*>
fn sz AppState.place_piece(&self, AnimRef ref, Piece piece, float at, uint track)
{
	if (!self.ensure_clip_imported(ref)) return -1;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || clip.keyframes.len == 0) return -1;
	at = math::clamp(at, 0.0f, clip.duration);
	AnimLayer layer;
	if (!self.piece_layer(ref, clip, piece, at, &layer)) return -1;
	// The piece may have read other clips; this one may have moved under them.
	clip = self.clip(ref);
	if (layer.end > clip.duration && layer.start < clip.duration - ANIM_SAME_TIME * 4.0f) layer.end = clip.duration;
	uint top = 0;
	foreach (&other : clip.layers) top = math::max(top, other.track + 1);
	layer.track = math::min(track, top);
	foreach (&other : clip.layers)
	{
		if (other.track == layer.track && layer.overlaps(other, clip.duration)) { layer.track = top; break; }
	}
	AnimLayer[] next = layers_inserted(mem, layers_copy(mem, clip.layers), clip.layers.len, layer);
	return self.land_strips(ref, clip, next, (sz)next.len - 1);
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

<*
 Move the strip at `at` by `delta` seconds and onto `track` (the top track plus
 one makes a new track). Refused, with a notice, when it would overlap a strip
 already on that track. One undo step; the strip stays active.

 @return `The strip's index afterwards, or -1 when nothing moved.`
*>
fn sz AppState.move_strip(&self, AnimRef ref, usz at, float delta, uint track)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len) return -1;
	AnimLayer moved = strip_shifted(&clip.layers[at], delta, clip);
	moved.track = math::min(track, clip.track_count());
	// What runs past the clip's end plays nowhere; the strip ends with the clip so
	// its end stays in reach.
	if (moved.end > clip.duration && moved.start < clip.duration - ANIM_SAME_TIME * 4.0f) moved.end = clip.duration;
	foreach (usz i, &other : clip.layers)
	{
		if (i == at || other.track != moved.track || !moved.overlaps(other, clip.duration)) continue;
		self.@notice("%s would overlap %s on that track", moved.name, other.name);
		moved.free(mem);
		return -1;
	}
	// Leaving a track it had alone and landing above it: the tracks close up.
	AnimLayer[] next = layers_copy(mem, clip.layers);
	next[at].free(mem);
	next[at] = moved;
	return self.land_strips(ref, clip, next, (sz)at);
}

<*
 The strip at `at` trimmed to `from`..`to` seconds. What plays inside stays where
 it is: a placed piece's zero does not move with its start, so trimming the
 front cuts into it. Refused when it would overlap another strip on its track.
*>
fn bool AppState.trim_strip(&self, AnimRef ref, usz at, float from, float to)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len) return false;
	from = math::max(0.0f, from);
	if (to < from + ANIM_SAME_TIME * 4.0f) return false;
	AnimLayer trimmed = clip.layers[at].copy(mem);
	trimmed.start = from;
	trimmed.end = to;
	float span = to - from;
	trimmed.fade_in = math::min(trimmed.fade_in, span);
	trimmed.fade_out = math::min(trimmed.fade_out, span - trimmed.fade_in);
	foreach (usz i, &other : clip.layers)
	{
		if (i == at || other.track != trimmed.track || !trimmed.overlaps(other, clip.duration)) continue;
		self.@notice("%s would overlap %s on that track", trimmed.name, other.name);
		trimmed.free(mem);
		return false;
	}
	return self.land_strips(ref, clip, replaced_layer(clip, at, trimmed), (sz)at) >= 0;
}

// A copy of the clip's stack with `layer` (taken over) at `at`.
fn AnimLayer[] replaced_layer(AnimTemplate* clip, usz at, AnimLayer layer) @local
{
	AnimLayer[] next = layers_copy(mem, clip.layers);
	next[at].free(mem);
	next[at] = layer;
	return next;
}

<*
 The strip's fades, each clamped to what its span has room for.
*>
fn bool AppState.set_strip_fades(&self, AnimRef ref, usz at, float fade_in, float fade_out)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len) return false;
	AnimLayer faded = clip.layers[at].copy(mem);
	float from, to;
	faded.span(clip.duration, &from, &to);
	faded.fade_in = math::clamp(fade_in, 0.0f, to - from);
	faded.fade_out = math::clamp(fade_out, 0.0f, to - from - faded.fade_in);
	return self.land_strips(ref, clip, replaced_layer(clip, at, faded), (sz)at) >= 0;
}

<*
 A placed strip played faster or slower so it ends at `to`, its start where it
 is: one pass of the piece takes as much longer as the strip grew. Only a piece
 on its own clock that keeps or repeats its seconds has a speed.
*>
fn bool AppState.speed_strip(&self, AnimRef ref, usz at, float to)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len || !clip.layers[at].placed()) return false;
	AnimLayer sped = clip.layers[at].copy(mem);
	float from, was;
	sped.span(clip.duration, &from, &was);
	if (to < from + ANIM_SAME_TIME * 4.0f) { sped.free(mem); return false; }
	float grown = (to - sped.offset) / math::max(was - sped.offset, ANIM_SAME_TIME);
	sped.speed = math::clamp(sped.pace() / grown, 0.05f, 20.0f);
	sped.start = from;
	sped.end = to;
	return self.land_strips(ref, clip, replaced_layer(clip, at, sped), (sz)at) >= 0;
}

<*
 A placed strip played at `pace` of its seconds per clip second, its end moved
 so it still plays the same stretch of the piece.
*>
fn bool AppState.set_strip_speed(&self, AnimRef ref, usz at, float pace)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len || !clip.layers[at].placed()) return false;
	float from, to;
	clip.layers[at].span(clip.duration, &from, &to);
	float was = clip.layers[at].pace();
	pace = math::clamp(pace, 0.05f, 20.0f);
	float offset = clip.layers[at].offset;
	return self.speed_strip(ref, at, offset + (to - offset) * was / pace);
}

<*
 Make a linked piece the clip's own: it keeps the keys it has and stops
 following its source.
*>
fn bool AppState.make_piece_local(&self, AnimRef ref, usz at)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.layers.len || clip.layers[at].source.len == 0) return false;
	AnimLayer local = clip.layers[at].copy(mem);
	local.source.free(mem);
	local.source = "";
	return self.land_strips(ref, clip, replaced_layer(clip, at, local), (sz)at) >= 0;
}

<*
 Rebuild every linked piece playing the clip just landed — or, after a rename,
 the clip it was called (`was`), which they then name by its new name. Called by
 `put_authored_clip` after it records the put, so the rebuilt clips land in the
 same undo step; each of those lands through it too, so pieces of pieces follow.
*>
fn void AppState.sync_clip_pieces(&self, AnimRef landed, String was = "")
{
	if (self.syncing_pieces > PIECE_DEPTH_MOST) return;
	AnimTemplate* clip = self.clip(landed);
	AnimPack* pack = self.authored();
	if (!clip || !pack) return;
	String name = clip.name.copy(mem);
	defer name.free(mem);
	bool played;
	foreach (usz i, &other : pack.clips)
	{
		if ((int)i == landed.clip) continue;
		foreach (&layer : other.layers)
		{
			if (layer.source.len > 0 && (layer.source == name || (was.len > 0 && layer.source == was))) played = true;
		}
	}
	if (!played) return;
	AnimTemplate? flat = self.piece_keys(landed);
	if (catch flat) return;
	defer flat.free(mem);

	self.syncing_pieces++;
	defer self.syncing_pieces--;
	usz clips = self.authored().clips.len;
	for (usz i = 0; i < clips; i++)
	{
		if ((int)i == landed.clip) continue;
		AnimTemplate* other = &self.authored().clips[i];
		bool plays;
		foreach (&layer : other.layers)
		{
			if (layer.source.len > 0 && (layer.source == name || (was.len > 0 && layer.source == was))) plays = true;
		}
		if (!plays) continue;
		AnimTemplate next = clip_copy(mem, *other);
		foreach (&layer : next.layers)
		{
			if (layer.source.len == 0 || (layer.source != name && (was.len == 0 || layer.source != was))) continue;
			piece_refilled(layer, clip_copy(mem, flat));
			layer.source.free(mem);
			layer.source = name.copy(mem);
		}
		(void)self.put_authored_clip(next);
	}
}

<*
 The clip called `name` is leaving the pack: every strip playing it becomes a
 copy of what it last was, recorded with the removal.
*>
fn void AppState.unlink_clip_pieces(&self, String name)
{
	AnimPack* pack = self.authored();
	if (!pack) return;
	usz clips = pack.clips.len;
	for (usz i = 0; i < clips; i++)
	{
		AnimTemplate* other = &self.authored().clips[i];
		bool plays;
		foreach (&layer : other.layers) if (layer.source == name) plays = true;
		if (!plays || other.name == name) continue;
		AnimTemplate next = clip_copy(mem, *other);
		foreach (&layer : next.layers)
		{
			if (layer.source != name) continue;
			layer.source.free(mem);
			layer.source = "";
		}
		(void)self.put_authored_clip(next);
	}
}

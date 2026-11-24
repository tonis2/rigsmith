<* The pure half of src/app/curve_cleanup.c3: no state, undo or notices. *>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;

enum CurveCleanup
{
	EULER_FILTER,
	SMOOTH,
	SIMPLIFY,
	FLATTEN,
	LOOP_SEAM,
	FIX_TWITCHES,
}

// One channel's keys in the clip, in time order.
struct CleanupKeys
{
	usz[] frames; // the keyframe holding each key
	usz[] dots;   // the entry within that keyframe
	bool[] picked;
}

fn AnimKeyDot* CleanupKeys.at(&self, AnimTemplate* clip, usz i)
{
	return &clip.keyframes[self.frames[i]].dots[self.dots[i]];
}

// The channel's keys, `picked` where `times` names the key's time. Temporary.
fn CleanupKeys cleanup_keys(AnimTemplate* clip, String joint, bool rotation, float[] times) @local
{
	List{usz} frames;
	frames.init(tmem);
	List{usz} dots;
	dots.init(tmem);
	List{bool} picked;
	picked.init(tmem);
	foreach (usz f, frame : clip.keyframes)
	{
		foreach (usz d, dot : frame.dots)
		{
			if (dot.joint_name != joint || !(rotation ? dot.keys_rotation() : dot.keys_translation())) continue;
			bool in = false;
			foreach (time : times) if (math::abs(time - frame.time) < ANIM_SAME_TIME) { in = true; break; }
			frames.push(f);
			dots.push(d);
			picked.push(in);
			break;
		}
	}
	return { .frames = frames.to_array(tmem), .dots = dots.to_array(tmem), .picked = picked.to_array(tmem) };
}

fn Quaternionf turn_of(AnimKeyDot dot)
{
	return quaternion::from_axis_angle{float}(dot.axis.normalize(), dot.angle);
}

<*
 Store `turn` in the key, written on the same side of the quaternion pair as
 `near`: `axis_angle_of` always lands on the short side, and a channel's
 continuity is the thing these tools keep. `-q` is the same axis with the angle
 a full turn away.
*>
fn void set_turn_near(AnimKeyDot* dot, Quaternionf turn, Quaternionf near) @local
{
	if (!axis_angle_of(turn, &dot.axis, &dot.angle)) return;
	if (turn_of(*dot).v.dot(near.v) < 0.0f) dot.angle += dot.angle > 0.0f ? -2.0f * (float)math::PI : 2.0f * (float)math::PI;
}

fn usz flips_fixed(AnimTemplate* clip, CleanupKeys keys) @local
{
	usz changed;
	Quaternionf before;
	for (usz i = 0; i < keys.frames.len; i++)
	{
		AnimKeyDot* dot = keys.at(clip, i);
		Quaternionf turn = turn_of(*dot);
		if (i > 0 && keys.picked[i] && before.v.dot(turn.v) < 0.0f)
		{
			dot.angle += dot.angle > 0.0f ? -2.0f * (float)math::PI : 2.0f * (float)math::PI;
			turn = turn_of(*dot);
			changed++;
		}
		before = turn;
	}
	return changed;
}

// A turn as the vector along its axis, half its angle long.
fn Vec3 turn_log(Quaternionf turn) @local
{
	Vec3 part = { turn.v[0], turn.v[1], turn.v[2] };
	float length = part.length();
	if (length < 1.0e-6f) return {};
	return part * (math::atan2(length, turn.v[3]) / length);
}

fn Quaternionf turn_exp(Vec3 half) @local
{
	float length = half.length();
	if (length < 1.0e-6f) return quaternion::IDENTITY;
	Vec3 axis = half * (math::sin(length) / length);
	return { .v = { axis.x, axis.y, axis.z, math::cos(length) } };
}

// Whether the segment leaving key `i` is a plain straight one: the only kind a
// key before it and after it can be dropped from without changing its shape.
fn bool segment_straight(AnimTemplate* clip, CleanupKeys keys, usz i, bool rotation) @local
{
	AnimKeyDot* dot = keys.at(clip, i);
	return dot.interpolation(rotation, clip.blend) == LINEAR && dot.ease(rotation).none();
}

fn bool segment_smooth(AnimTemplate* clip, CleanupKeys keys, usz i, bool rotation) @local
{
	return keys.at(clip, i).interpolation(rotation, clip.blend) == AUTO;
}

<*
 Mark in `gone` (one flag per entry of the clip, `base` giving each keyframe's
 first) the keys of one channel that the straight lines between the ones that
 stay reproduce.

 Each run of picked keys joined by straight segments goes to `curve_keys`, which
 keeps its two ends. A key next to a smooth segment stays too, since that
 segment's tangent reads it.

 @return `How many keys were marked.`
*>
fn usz keys_thinned(AnimTemplate* clip, CleanupKeys keys, bool rotation, bool[] gone, usz[] base) @local
{
	usz n = keys.frames.len;
	if (n < 3) return 0;
	bool[] stay = alloc::new_array(tmem, bool, (sz)n);
	for (usz i = 0; i < n; i++)
	{
		if (i >= 2 && segment_smooth(clip, keys, i - 2, rotation)) stay[i] = true;
		if (i + 2 < n && segment_smooth(clip, keys, i + 1, rotation)) stay[i] = true;
		// A loop's wrap is a segment between the last key and the first.
		if (clip.loop && (i == 1 || i + 2 == n)) stay[i] = true;
	}
	CurveTolerance tolerance = { .angle = KeyReduction.LIGHT.tolerance(1.0f).angle, .move = KeyReduction.LIGHT.tolerance(1.0f).move };
	usz removed;
	usz start = 0;
	while (start + 1 < n)
	{
		if (!keys.picked[start] || !keys.picked[start + 1] || !segment_straight(clip, keys, start, rotation)) { start++; continue; }
		usz end = start + 1;
		while (end + 1 < n && !stay[end] && keys.picked[end + 1] && segment_straight(clip, keys, end, rotation)) end++;
		usz count = end - start + 1;
		if (count >= 3)
		{
			float[] times = alloc::new_array(tmem, float, (sz)count);
			Quaternionf[] turns = rotation ? alloc::new_array(tmem, Quaternionf, (sz)count) : {};
			Vec3[] slides = rotation ? {} : alloc::new_array(tmem, Vec3, (sz)count);
			for (usz k = 0; k < count; k++)
			{
				AnimKeyDot* dot = keys.at(clip, start + k);
				times[k] = clip.keyframes[keys.frames[start + k]].time;
				if (rotation) { turns[k] = turn_of(*dot); } else { slides[k] = dot.move; }
			}
			usz[] kept = curve_keys(tmem, times, turns, slides, tolerance, false);
			if (kept.len > 0)
			{
				bool[] stays = alloc::new_array(tmem, bool, (sz)count);
				foreach (k : kept) stays[k] = true;
				for (usz k = 0; k < count; k++)
				{
					if (stays[k]) continue;
					bool* flag = &gone[base[keys.frames[start + k]] + keys.dots[start + k]];
					if (!*flag) removed++;
					*flag = true;
				}
			}
		}
		start = end;
	}
	return removed;
}

fn usz keys_flattened(AnimTemplate* clip, CleanupKeys keys, bool rotation) @local
{
	usz changed;
	for (usz i = 0; i < keys.frames.len; i++)
	{
		if (!keys.picked[i]) continue;
		AnimKeyDot* dot = keys.at(clip, i);
		if (dot.tangents(rotation).mode == FLAT) continue;
		if (set_tangent_mode(clip, keys.frames[i], dot.joint_name, rotation, FLAT)) changed++;
	}
	return changed;
}

fn usz seam_matched(AnimTemplate* clip, CleanupKeys keys, bool rotation) @local
{
	usz first = keys.frames.len;
	usz last = keys.frames.len;
	for (usz i = 0; i < keys.frames.len; i++)
	{
		if (!keys.picked[i]) continue;
		if (first == keys.frames.len) first = i;
		last = i;
	}
	if (first == keys.frames.len || first == last) return 0;
	AnimKeyDot* from = keys.at(clip, first);
	AnimKeyDot* to = keys.at(clip, last);
	if (rotation)
	{
		Quaternionf opening = turn_of(*from);
		Quaternionf closing = turn_of(*to);
		if (turn_apart(opening, closing) <= 1.0e-6f) return 0;
		// Written on the side the key before it is on, so the channel stays continuous.
		Quaternionf near = last > 0 ? turn_of(*keys.at(clip, last - 1)) : closing;
		set_turn_near(to, opening, near);
		return 1;
	}
	if ((from.move - to.move).length() <= 1.0e-7f) return 0;
	to.move = from.move;
	return 1;
}

// The clip's entries before each keyframe's, so an entry has one flat index.
fn usz[] entry_bases(AnimTemplate* clip) @local
{
	usz[] base = alloc::new_array(tmem, usz, (sz)clip.keyframes.len + 1);
	foreach (usz f, frame : clip.keyframes) base[f + 1] = base[f] + frame.dots.len;
	return base;
}

// `clip` without the channel keys `gone` flags: an entry left with one channel
// is narrowed to it, and a keyframe left empty is dropped.
fn AnimTemplate clip_without_flagged(Allocator allocator, AnimTemplate* clip, bool[] gone_rotation,
	bool[] gone_translation, usz[] base)
{
	List{AnimKeyframe} frames;
	frames.init(allocator);
	defer frames.free();
	foreach (usz f, frame : clip.keyframes)
	{
		List{AnimKeyDot} dots;
		dots.init(allocator);
		defer dots.free();
		foreach (usz d, dot : frame.dots)
		{
			bool rotation = dot.keys_rotation() && !gone_rotation[base[f] + d];
			bool translation = dot.keys_translation() && !gone_translation[base[f] + d];
			if (!rotation && !translation) continue;
			dots.push(dot.narrowed(allocator, rotation, translation));
		}
		if (dots.len() == 0) continue;
		frames.push({ .time = frame.time, .dots = dots.to_array(allocator) });
	}
	return clip_with_frames(allocator, *clip, frames.to_array(allocator), clip.duration);
}

// The rotation `middle` moves to when it takes a quarter of the way to each neighbour.
fn Quaternionf smoothed_turn(Quaternionf before, Quaternionf middle, Quaternionf after) @local
{
	if (before.v.dot(middle.v) < 0.0f) before = -before;
	if (after.v.dot(middle.v) < 0.0f) after = -after;
	Vec3 toward = (turn_log(middle.conjugate().mul(before)) + turn_log(middle.conjugate().mul(after))) * 0.25f;
	return middle.mul(turn_exp(toward)).normalize();
}

fn usz keys_smoothed(AnimTemplate* clip, CleanupKeys keys, bool rotation) @local
{
	usz n = keys.frames.len;
	if (n < 3) return 0;
	Quaternionf[] turns = alloc::new_array(tmem, Quaternionf, (sz)n);
	Vec3[] moves = alloc::new_array(tmem, Vec3, (sz)n);
	for (usz i = 0; i < keys.frames.len; i++)
	{
		AnimKeyDot* dot = keys.at(clip, i);
		turns[i] = turn_of(*dot);
		moves[i] = dot.move;
	}
	usz changed;
	for (usz i = 1; i + 1 < n; i++)
	{
		// The ends of a run stay, so a range keeps the values it started and ended on.
		if (!keys.picked[i - 1] || !keys.picked[i] || !keys.picked[i + 1]) continue;
		AnimKeyDot* dot = keys.at(clip, i);
		if (rotation)
		{
			Quaternionf next = smoothed_turn(turns[i - 1], turns[i], turns[i + 1]);
			if (turn_apart(next, turns[i]) <= 1.0e-6f) continue;
			set_turn_near(dot, next, turns[i]);
		}
		else
		{
			Vec3 next = moves[i] * 0.5f + (moves[i - 1] + moves[i + 1]) * 0.25f;
			if ((next - moves[i]).length() <= 1.0e-7f) continue;
			dot.move = next;
		}
		changed++;
	}
	return changed;
}

// Each channel the picks name, once, in the order they first name it: the index of that first pick.
fn usz[] picked_channels(AnimChannelKey[] picks) @local
{
	List{usz} firsts;
	firsts.init(tmem);
	for (usz p = 0; p < picks.len; p++)
	{
		if (picks[p].channel == BOTH) continue;
		bool seen = false;
		foreach (q : firsts)
		{
			if (picks[q].channel == picks[p].channel && picks[q].joint == picks[p].joint) { seen = true; break; }
		}
		if (!seen) firsts.push(p);
	}
	return firsts.to_array(tmem);
}

// The picked times of the channel pick `first` names.
fn float[] picked_times(AnimChannelKey[] picks, usz first) @local
{
	List{float} times;
	times.init(tmem);
	foreach (pick : picks)
	{
		if (pick.channel == picks[first].channel && pick.joint == picks[first].joint) times.push(pick.time);
	}
	return times.to_array(tmem);
}

<*
 `source` with one clean-up applied to the channel keys `picks` name.

 A key is addressed by time, joint and channel (`ROTATION` or `TRANSLATION`).
 Per channel the picked keys that sit next to each other in the channel's own
 order form a run, and a tool never reads a key it was not given past the run's
 ends: Smooth leaves a run's first and last key alone and Simplify keeps them.

 @param changed : `Receives how many keys were rewritten (Simplify: removed).`
 @param frame : `Seconds per frame at the sheet's rate: what Fix twitches calls crowded.`
 @return `A copy; with nothing changed, one equal to the source. The caller owns it.`
*>
fn AnimTemplate clip_curve_cleaned(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks,
	CurveCleanup op, usz* changed, float frame = 1.0f / 30.0f)
{
	*changed = 0;
	if (op == FIX_TWITCHES) return clip_twitches_fixed(allocator, source, picks, frame, changed);
	AnimTemplate clip = clip_copy(allocator, source);
	@pool()
	{
		usz[] base = entry_bases(&clip);
		bool[] gone_rotation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		bool[] gone_translation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		foreach (p : picked_channels(picks))
		{
			bool rotation = picks[p].channel == ROTATION;
			CleanupKeys keys = cleanup_keys(&clip, picks[p].joint, rotation, picked_times(picks, p));
			switch (op)
			{
				case EULER_FILTER: if (rotation) *changed += flips_fixed(&clip, keys);
				case SMOOTH: *changed += keys_smoothed(&clip, keys, rotation);
				case SIMPLIFY: *changed += keys_thinned(&clip, keys, rotation, rotation ? gone_rotation : gone_translation, base);
				case FLATTEN: *changed += keys_flattened(&clip, keys, rotation);
				case LOOP_SEAM: *changed += seam_matched(&clip, keys, rotation);
				case FIX_TWITCHES: unreachable();
			}
		}
		if (op == SIMPLIFY && *changed > 0)
		{
			AnimTemplate thinned = clip_without_flagged(allocator, &clip, gone_rotation, gone_translation, base);
			clip.free(allocator);
			return thinned;
		}
	};
	return clip;
}

<*
 Fix twitches: of two picked keys of a channel closer than a quarter frame, the
 one farther from a whole frame goes; then each segment with a picked end that
 strays past `swing_limit` has its Free and Broken ends put back to Auto. A key
 a hair from another snaps the joint back past it, and a stored tangent too
 steep for its segment spins the joint between its keys.
*>
fn AnimTemplate clip_twitches_fixed(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks, float frame,
	usz* changed) @local
{
	AnimTemplate clip = clip_copy(allocator, source);
	@pool()
	{
		usz[] channels = picked_channels(picks);
		// Crowded keys first, so a spin is read on the keys that stay.
		usz[] base = entry_bases(&clip);
		bool[] gone_rotation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		bool[] gone_translation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		usz removed;
		foreach (p : channels)
		{
			bool rotation = picks[p].channel == ROTATION;
			CleanupKeys keys = cleanup_keys(&clip, picks[p].joint, rotation, picked_times(picks, p));
			removed += keys_uncrowded(&clip, keys, frame, rotation ? gone_rotation : gone_translation, base);
		}
		if (removed > 0)
		{
			AnimTemplate thinned = clip_without_flagged(allocator, &clip, gone_rotation, gone_translation, base);
			clip.free(allocator);
			clip = thinned;
		}
		*changed += removed;
		foreach (p : channels)
		{
			bool rotation = picks[p].channel == ROTATION;
			CleanupKeys keys = cleanup_keys(&clip, picks[p].joint, rotation, picked_times(picks, p));
			*changed += spins_settled(&clip, keys, rotation);
		}
	};
	return clip;
}

// How far `time` is from the nearest whole frame.
fn float off_frame(float time, float frame) @local => math::abs(time - math::round(time / frame) * frame);

// Mark in `gone` the key of each crowded pair that sits farther from a whole frame.
fn usz keys_uncrowded(AnimTemplate* clip, CleanupKeys keys, float frame, bool[] gone, usz[] base) @local
{
	if (!(frame > 0.0f)) return 0;
	usz removed;
	sz kept = -1; // the last key that stays
	for (usz i = 0; i < keys.frames.len; i++)
	{
		if (kept < 0 || !keys.picked[i] || !keys.picked[(usz)kept]) { kept = (sz)i; continue; }
		float earlier = clip.keyframes[keys.frames[(usz)kept]].time;
		float later = clip.keyframes[keys.frames[i]].time;
		if (later - earlier >= frame * 0.25f) { kept = (sz)i; continue; }
		usz drop = off_frame(later, frame) >= off_frame(earlier, frame) ? i : (usz)kept;
		gone[base[keys.frames[drop]] + keys.dots[drop]] = true;
		removed++;
		if (drop == (usz)kept) kept = (sz)i;
	}
	return removed;
}

fn bool stores_rate(AnimKeyDot* dot, bool rotation) @local
{
	AnimTangent mode = dot.tangents(rotation).mode;
	return mode == FREE || mode == BROKEN;
}

// Put back to Auto the stored ends of every segment that strays past the limit.
fn usz spins_settled(AnimTemplate* clip, CleanupKeys keys, bool rotation) @local
{
	usz changed;
	for (usz i = 0; i + 1 < keys.frames.len; i++)
	{
		if (!keys.picked[i] && !keys.picked[i + 1]) continue;
		AnimKeyDot* from = keys.at(clip, i);
		AnimKeyDot* to = keys.at(clip, i + 1);
		bool reset_from = keys.picked[i] && stores_rate(from, rotation);
		bool reset_to = keys.picked[i + 1] && stores_rate(to, rotation);
		if (!reset_from && !reset_to) continue;
		String joint = from.joint_name;
		float t0 = clip.keyframes[keys.frames[i]].time;
		float t1 = clip.keyframes[keys.frames[i + 1]].time;
		if (segment_swing(clip, joint, rotation, t0, t1) <= swing_limit(rotation)) continue;
		if (reset_from && set_tangent_mode(clip, keys.frames[i], joint, rotation, AUTO)) changed++;
		if (reset_to && set_tangent_mode(clip, keys.frames[i + 1], joint, rotation, AUTO)) changed++;
	}
	return changed;
}

<*
 The channels a key writes, each as a channel key at the key's time. Names are
 copied to the temp allocator, so they outlive the key being taken over.
*>
fn AnimChannelKey[] written_channels(AnimKeyframe* key)
{
	List{AnimChannelKey} written;
	written.init(tmem);
	foreach (dot : key.dots)
	{
		bool rotation = dot.keys_rotation();
		bool translation = dot.keys_translation();
		if (!rotation && !translation) continue;
		written.push({ .time = key.time, .joint = dot.joint_name.tcopy(),
			.channel = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION) });
	}
	return written.to_array(tmem);
}

<*
 Drop from `clip` every other key, within `window` of `time`, of the channels
 `written` names: a key made at the playhead must not land a hair from one
 already there and snap back past it. An entry keying other channels keeps
 them, and a keyframe left empty goes.

 @param [&inout] clip : `Owned; replaced when a key goes.`
 @return `How many channel keys went.`
*>
fn usz uncrowd_clip(Allocator allocator, AnimTemplate* clip, float time, AnimChannelKey[] written, float window)
{
	if (!(window > ANIM_SAME_TIME) || written.len == 0) return 0;
	usz removed;
	@pool()
	{
		usz[] base = entry_bases(clip);
		bool[] gone_rotation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		bool[] gone_translation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		foreach (usz f, frame : clip.keyframes)
		{
			float gap = math::abs(frame.time - time);
			if (gap < ANIM_SAME_TIME || gap >= window) continue;
			foreach (usz d, dot : frame.dots)
			{
				foreach (key : written)
				{
					if (key.joint != dot.joint_name) continue;
					if (key.channel != TRANSLATION && dot.keys_rotation() && !gone_rotation[base[f] + d])
					{
						gone_rotation[base[f] + d] = true;
						removed++;
					}
					if (key.channel != ROTATION && dot.keys_translation() && !gone_translation[base[f] + d])
					{
						gone_translation[base[f] + d] = true;
						removed++;
					}
				}
			}
		}
		if (removed > 0)
		{
			AnimTemplate thinned = clip_without_flagged(allocator, clip, gone_rotation, gone_translation, base);
			clip.free(allocator);
			*clip = thinned;
		}
	};
	return removed;
}

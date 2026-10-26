<*
 Curve clean-up: five tools that tidy the channels a clip keys, each one undo
 step, each acting on the same set of channel keys.

 **Fix flips** (Euler filter): a rotation key stores a quaternion, so the same
 orientation can be written two ways (`q` and `-q`). A channel whose neighbours
 sit on opposite sides of that pair reads as a swing the long way round to
 anything that blends the components, and as a jump in the file. Each key is
 rewritten onto the side its predecessor is on. The orientation at every key is
 unchanged. The Curves sheet's Euler angles are not stored: they are unwrapped
 from the quaternions sample to sample (`euler_of`), so a wrapped angle cannot
 survive in the data and the sign is all there is to fix.

 **Smooth**: a 1-2-1 pass over the key values of each channel. A position is
 averaged directly, a rotation moves a quarter of the way toward each
 neighbour along the shortest arc. The first and last key of a run stay.

 **Simplify**: drops the keys the straight line between their neighbours
 reproduces within Optimize's Light tolerance, by `curve_keys`. A key stays
 when either segment next to it is not a plain straight one (held or smooth
 segments, an ease), so the curve's shape between the kept keys is unchanged.

 **Flatten**: gives the selected keys the `FLAT` tangent mode, so the curve
 levels out through each of them. The values are untouched.

 **Match loop seam**: the last key of each channel takes the first key's value,
 so a cycle meets itself.

 Which channels: see `AppState.cleanup_picks`. The transforms below are plain
 functions over `AnimChannelKey` lists so they need no open app.
*>
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
}

// ---------------------------------------------------------------------------
// The transforms

// One channel's keys in the clip, in time order.
struct CleanupKeys @local
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

fn Quaternionf turn_of(AnimKeyDot dot) @local
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

// The rotation `middle` moves to when it takes a quarter of the way to each neighbour.
fn Quaternionf smoothed_turn(Quaternionf before, Quaternionf middle, Quaternionf after) @local
{
	if (before.v.dot(middle.v) < 0.0f) before = -before;
	if (after.v.dot(middle.v) < 0.0f) after = -after;
	Vec3 toward = (turn_log(middle.conjugate().mul(before)) + turn_log(middle.conjugate().mul(after))) * 0.25f;
	return middle.mul(turn_exp(toward)).normalize();
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
	bool[] gone_translation, usz[] base) @local
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

<*
 `source` with one clean-up applied to the channel keys `picks` name.

 A key is addressed by time, joint and channel (`ROTATION` or `TRANSLATION`).
 Per channel the picked keys that sit next to each other in the channel's own
 order form a run, and a tool never reads a key it was not given past the run's
 ends: Smooth leaves a run's first and last key alone and Simplify keeps them.

 @param changed : `Receives how many keys were rewritten (Simplify: removed).`
 @return `A copy; with nothing changed, one equal to the source. The caller owns it.`
*>
fn AnimTemplate clip_curve_cleaned(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks,
	CurveCleanup op, usz* changed)
{
	*changed = 0;
	AnimTemplate clip = clip_copy(allocator, source);
	@pool()
	{
		usz[] base = entry_bases(&clip);
		bool[] gone_rotation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		bool[] gone_translation = alloc::new_array(tmem, bool, (sz)base[clip.keyframes.len]);
		// Each channel once, in the order the picks first name it.
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
		foreach (p : firsts)
		{
			bool rotation = picks[p].channel == ROTATION;
			List{float} times;
			times.init(tmem);
			foreach (pick : picks)
			{
				if (pick.channel == picks[p].channel && pick.joint == picks[p].joint) times.push(pick.time);
			}
			CleanupKeys keys = cleanup_keys(&clip, picks[p].joint, rotation, times.array_view());
			switch (op)
			{
				case EULER_FILTER: if (rotation) *changed += flips_fixed(&clip, keys);
				case SMOOTH: *changed += keys_smoothed(&clip, keys, rotation);
				case SIMPLIFY: *changed += keys_thinned(&clip, keys, rotation, rotation ? gone_rotation : gone_translation, base);
				case FLATTEN: *changed += keys_flattened(&clip, keys, rotation);
				case LOOP_SEAM: *changed += seam_matched(&clip, keys, rotation);
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

fn AnimTemplate curves_euler_filtered(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks, usz* changed)
	=> clip_curve_cleaned(allocator, source, picks, EULER_FILTER, changed);

fn AnimTemplate curves_smoothed(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks, usz* changed)
	=> clip_curve_cleaned(allocator, source, picks, SMOOTH, changed);

fn AnimTemplate curves_simplified(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks, usz* changed)
	=> clip_curve_cleaned(allocator, source, picks, SIMPLIFY, changed);

fn AnimTemplate curves_flattened(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks, usz* changed)
	=> clip_curve_cleaned(allocator, source, picks, FLATTEN, changed);

fn AnimTemplate curves_loop_matched(Allocator allocator, AnimTemplate source, AnimChannelKey[] picks, usz* changed)
	=> clip_curve_cleaned(allocator, source, picks, LOOP_SEAM, changed);

// ---------------------------------------------------------------------------
// On the app

<*
 The channel keys a clean-up acts on, one rule, as `animation_selection_uses_ease`
 reads a selection:

 - Channel keys picked in the sheet: exactly those.
 - Else keys picked as whole poses: every channel keyed in those columns.
 - Else nothing picked: every key, over the whole clip, of the channels of the
   joints selected in the viewport (the ones Curves draws).

 Borrows the joint names from the clip and lives in the temp allocator.
*>
fn AnimChannelKey[] AppState.cleanup_picks(&self, AnimRef ref)
{
	AnimTemplate* clip = self.key_clip(ref);
	List{AnimChannelKey} picks;
	picks.init(tmem);
	if (!clip) return {};
	bool here = self.anim_key_selection_ref.same(ref);
	bool channels = here && self.anim_channel_key_selection.len() > 0;
	bool columns = here && !channels && self.anim_key_selection.len() > 0;
	List{String} joints;
	joints.init(tmem);
	if (!channels && !columns)
	{
		if (try view = self.open_rig(mem))
		{
			defer view.free(mem);
			String[] words = self.names_for(&view, ref);
			foreach (usz i, name : words)
			{
				if (i < view.dot_ids.len && name.len > 0 && self.is_selected(view.dot_ids[i])) joints.push(name.tcopy());
			}
		}
	}
	foreach (frame : clip.keyframes) foreach (dot : frame.dots)
	{
		for (int c = 0; c < 2; c++)
		{
			bool rotation = c == 0;
			if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
			AnimChannels channel = rotation ? ROTATION : TRANSLATION;
			bool picked;
			if (channels)
			{
				picked = self.channel_selection_contains(frame.time, dot.joint_name, channel);
			}
			else if (columns)
			{
				picked = self.animation_key_selected(ref, frame.time);
			}
			else
			{
				foreach (joint : joints) if (joint == dot.joint_name) { picked = true; break; }
			}
			if (picked) picks.push({ .time = frame.time, .joint = dot.joint_name, .channel = channel });
		}
	}
	return picks.to_array(tmem);
}

<*
 Run one clean-up on the clip being edited and land it as one undo step.

 @return `False with a notice when it refused or found nothing to change.`
*>
fn bool AppState.curve_cleanup(&self, AnimRef ref, CurveCleanup op)
{
	if (!self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip)
	{
		self.@notice("Pick an animation to edit first.");
		return false;
	}
	if (self.procedural_layer_of(ref))
	{
		self.@notice("This layer is a generator with no keys: edit its parameters instead.");
		return false;
	}
	if (self.pose_edit_pending) return false;
	@pool()
	{
		AnimChannelKey[] picks = self.cleanup_picks(ref);
		if (picks.len == 0)
		{
			self.@notice("Select keys in the sheet, or joints in the viewport, to clean up their curves.");
			return false;
		}
		usz changed;
		AnimTemplate cleaned = clip_curve_cleaned(mem, *clip, picks, op, &changed);
		if (changed == 0)
		{
			cleaned.free(mem);
			switch (op)
			{
				case EULER_FILTER: self.@notice("No flips to fix: every selected rotation key already follows its neighbour.");
				case SMOOTH: self.@notice("Nothing to smooth: it needs three picked keys in a row on a channel.");
				case SIMPLIFY: self.@notice("No keys to lose: the selected curves are already as simple as they get.");
				case FLATTEN: self.@notice("The selected keys are already flat.");
				case LOOP_SEAM: self.@notice("Nothing to match: the selected channels already end where they start.");
			}
			return false;
		}
		bool landed;
		if (op == SIMPLIFY)
		{
			// Whole keys may be gone, so the picked times may name nothing now.
			AnimRef next = self.land_key_edit(ref, cleaned);
			landed = next.valid();
			if (landed)
			{
				self.clear_animation_key_selection();
				self.editing = next;
			}
		}
		else
		{
			landed = self.land_keeping_selection(ref, cleaned, true);
		}
		if (!landed) return false;
		switch (op)
		{
			case EULER_FILTER: self.@notice("Fixed %d flipped keys · Ctrl+Z undoes it", changed);
			case SMOOTH: self.@notice("Smoothed %d keys · Ctrl+Z undoes it", changed);
			case SIMPLIFY: self.@notice("Removed %d keys the curves do not need · Ctrl+Z undoes it", changed);
			case FLATTEN: self.@notice("Flattened %d keys · Ctrl+Z undoes it", changed);
			case LOOP_SEAM: self.@notice("Matched the seam on %d channels · Ctrl+Z undoes it", changed);
		}
		return true;
	};
}

fn bool AppState.euler_filter_selection(&self, AnimRef ref) => self.curve_cleanup(ref, EULER_FILTER);
fn bool AppState.smooth_selection(&self, AnimRef ref) => self.curve_cleanup(ref, SMOOTH);
fn bool AppState.simplify_selection(&self, AnimRef ref) => self.curve_cleanup(ref, SIMPLIFY);
fn bool AppState.flatten_selection(&self, AnimRef ref) => self.curve_cleanup(ref, FLATTEN);
fn bool AppState.match_loop_seam_selection(&self, AnimRef ref) => self.curve_cleanup(ref, LOOP_SEAM);

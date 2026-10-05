module crig;

import std::sort;
import std::math;

struct AnimChannelKey
{
	float time;
	String joint; // owned
	AnimChannels channel; // ROTATION or TRANSLATION, never BOTH
}

fn void AppState.free_animation_channel_selection(&self)
{
	foreach (&selected : self.anim_channel_key_selection) selected.joint.free(mem);
	self.anim_channel_key_selection.free();
}

// Selection names whole stored keyframes by time. It never borrows keyframe
// storage, which is replaced by every edit, and is meaningful only for one ref.
fn void AppState.clear_animation_key_selection(&self)
{
	self.anim_key_selection.free();
	self.free_animation_channel_selection();
	self.anim_key_selection_ref = NO_ANIM;
	self.anim_key_anchor = -1.0f;
}

<*
 Empty both selections and scope them to `ref`, ready for `select_time` or
 `select_channel`. The anchor is kept. Pair with `settle_key_selection`.
*>
fn void AppState.restart_key_selection(&self, AnimRef ref)
{
	self.anim_key_selection.clear();
	foreach (&selected : self.anim_channel_key_selection) selected.joint.free(mem);
	self.anim_channel_key_selection.clear();
	self.anim_key_selection_ref = ref;
}

// A zeroed List grows from tmem, so each is given `mem` on its first add.
fn void AppState.select_time(&self, float time)
{
	if (!self.anim_key_selection.is_initialized()) self.anim_key_selection.init(mem);
	self.anim_key_selection.push(time);
}

// `joint` is copied.
fn void AppState.select_channel(&self, float time, String joint, AnimChannels channel)
{
	if (!self.anim_channel_key_selection.is_initialized()) self.anim_channel_key_selection.init(mem);
	self.anim_channel_key_selection.push({ .time = time, .joint = joint.copy(mem), .channel = channel });
}

// An empty selection is scoped to nothing.
fn void AppState.settle_key_selection(&self)
{
	if (self.anim_key_selection.len() == 0 && self.anim_channel_key_selection.len() == 0)
	{
		self.anim_key_selection_ref = NO_ANIM;
	}
}

fn bool AppState.animation_key_selected(&self, AnimRef ref, float time)
{
	if (!self.anim_key_selection_ref.same(ref)) return false;
	foreach (selected : self.anim_key_selection)
	{
		if (math::abs(selected - time) < ANIM_SAME_TIME) return true;
	}
	return false;
}

fn usz AppState.animation_key_selection_count(&self, AnimRef ref)
{
	return self.anim_key_selection_ref.same(ref) ? (usz)self.anim_key_selection.len() : 0;
}

fn bool AppState.animation_channel_key_selected(&self, AnimRef ref, float time,
	String joint, AnimChannels channel)
{
	if (!self.anim_key_selection_ref.same(ref)) return false;
	foreach (selected : self.anim_channel_key_selection)
		if (selected.joint == joint && selected.channel == channel
			&& math::abs(selected.time - time) < ANIM_SAME_TIME) return true;
	return false;
}

fn usz AppState.animation_channel_key_selection_count(&self, AnimRef ref)
{
	return self.anim_key_selection_ref.same(ref) ? (usz)self.anim_channel_key_selection.len() : 0;
}

// Asks `channel_dot`, which reads past a rotation-only entry to a move-only
// one for the same joint: a key may hold the two halves as separate dots.
fn bool AnimKeyframe.has_channel(self, String joint, AnimChannels channel)
{
	AnimKeyDot found;
	return self.channel_dot(joint, channel == ROTATION, &found);
}

fn bool AppState.select_animation_channel_key(&self, AnimRef ref, float time,
	String joint, AnimChannels channel, bool additive = false, bool toggle = false)
{
	AnimTemplate* clip = self.key_clip(ref);
	sz key = self.key_near(ref, time, ANIM_SAME_TIME);
	if (!clip || key < 0 || channel == BOTH
		|| !clip.keyframes[key].has_channel(joint, channel)) return false;
	time = clip.keyframes[key].time;
	bool same_ref = self.anim_key_selection_ref.same(ref);
	bool already = self.animation_channel_key_selected(ref, time, joint, channel);
	usz old_count = same_ref && additive ? (usz)self.anim_channel_key_selection.len() : 0;
	if (toggle && already)
	{
		for (sz i = self.anim_channel_key_selection.len() - 1; i >= 0; i--)
		{
			AnimChannelKey* selected = &self.anim_channel_key_selection[i];
			if (selected.joint != joint || selected.channel != channel
				|| math::abs(selected.time - time) >= ANIM_SAME_TIME) continue;
			selected.joint.free(mem);
			self.anim_channel_key_selection.remove_at(i);
		}
		self.settle_key_selection();
		return true;
	}
	if (already && old_count > 0) return true;
	if (old_count == 0) self.restart_key_selection(ref);
	self.select_channel(time, joint, channel);
	return true;
}

fn usz AppState.select_animation_channel_keys_between(&self, AnimRef ref, String joint,
	AnimChannels channel, float first, float last, bool additive = false)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || channel == BOTH) return 0;
	float low = math::min(first, last);
	float high = math::max(first, last);
	bool keep = additive && self.anim_key_selection_ref.same(ref)
		&& self.anim_channel_key_selection.len() > 0;
	if (!keep) self.restart_key_selection(ref);
	foreach (frame : clip.keyframes) if (frame.time >= low && frame.time <= high
		&& frame.has_channel(joint, channel)
		&& !(keep && self.animation_channel_key_selected(ref, frame.time, joint, channel)))
	{
		self.select_channel(frame.time, joint, channel);
	}
	self.settle_key_selection();
	return (usz)self.anim_channel_key_selection.len();
}

fn bool AppState.select_animation_key(&self, AnimRef ref, float time,
	bool additive = false, bool toggle = false)
{
	AnimTemplate* clip = self.key_clip(ref);
	sz key = self.key_near(ref, time, ANIM_SAME_TIME);
	if (!clip || key < 0) return false;
	time = clip.keyframes[key].time;

	bool already = self.animation_key_selected(ref, time);
	usz old_count = self.anim_key_selection_ref.same(ref) && additive
		? (usz)self.anim_key_selection.len() : 0;
	if (toggle && already)
	{
		for (sz i = self.anim_key_selection.len() - 1; i >= 0; i--)
		{
			if (math::abs(self.anim_key_selection[i] - time) < ANIM_SAME_TIME) self.anim_key_selection.remove_at(i);
		}
		self.settle_key_selection();
		return true;
	}
	if (already && old_count > 0) return true;
	if (old_count == 0) self.restart_key_selection(ref);
	self.select_time(time);
	return true;
}

fn usz AppState.select_animation_keys_between(&self, AnimRef ref, float first,
	float last, bool additive = false)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip) return 0;
	float low = math::min(first, last);
	float high = math::max(first, last);
	bool keep = additive && self.anim_key_selection_ref.same(ref)
		&& self.anim_key_selection.len() > 0;
	if (!keep) self.restart_key_selection(ref);
	foreach (frame : clip.keyframes)
	{
		if (frame.time >= low && frame.time <= high
			&& !(keep && self.animation_key_selected(ref, frame.time))) self.select_time(frame.time);
	}
	self.settle_key_selection();
	return (usz)self.anim_key_selection.len();
}

<*
 Where a retime sends a key: scaled about `anchor`, then shifted by `delta`. A
 plain move is scale 1, which adds the delta exactly.
*>
struct KeyRetime
{
	float anchor;
	float scale;
	float delta;
}

fn float KeyRetime.map(self, float t)
	=> self.scale == 1.0f ? t + self.delta : self.anchor + (t - self.anchor) * self.scale + self.delta;

fn bool KeyRetime.identity(self) => self.scale == 1.0f && math::abs(self.delta) < ANIM_SAME_TIME;

<*
 The earliest and latest selected key times, whole keys or channel keys.
 False with nothing selected in this clip.
*>
fn bool AppState.selected_key_span(&self, AnimRef ref, float* first, float* last)
{
	if (!self.anim_key_selection_ref.same(ref)) return false;
	bool found = false;
	foreach (time : self.anim_key_selection)
	{
		if (!found || time < *first) *first = time;
		if (!found || time > *last) *last = time;
		found = true;
	}
	foreach (selected : self.anim_channel_key_selection)
	{
		if (!found || selected.time < *first) *first = selected.time;
		if (!found || selected.time > *last) *last = selected.time;
		found = true;
	}
	return found;
}

fn bool AppState.move_selected_animation_keys(&self, AnimRef ref, float delta)
	=> self.retime_selected_animation_keys(ref, { .scale = 1.0f, .delta = delta });

<*
 Move the selection so its first key lands on `at`, keeping the spacing.
*>
fn bool AppState.set_selected_key_time(&self, AnimRef ref, float at)
{
	float first;
	float last;
	if (!self.selected_key_span(ref, &first, &last)) return false;
	return self.move_selected_animation_keys(ref, at - first);
}

<*
 Stretch the selected keys so they span `span` seconds, anchored at the first
 selected key. Unselected keys stay where they are.
*>
fn bool AppState.scale_selected_animation_keys(&self, AnimRef ref, float span)
{
	float first;
	float last;
	if (!self.selected_key_span(ref, &first, &last)) return false;
	if (last - first < ANIM_SAME_TIME || !(span > 0.0f) || !math::is_finite(span)) return false;
	return self.retime_selected_animation_keys(ref, { .anchor = first, .scale = span / (last - first) });
}

<*
 Retime the selected keys in one clip swap, so one undo step. Refused when a
 key would leave the clip or land on another key.
*>
fn bool AppState.retime_selected_animation_keys(&self, AnimRef ref, KeyRetime retime)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref)
		|| (self.anim_key_selection.len() == 0 && self.anim_channel_key_selection.len() == 0)
		|| self.pose_edit_pending) return false;
	if (retime.identity()) return true;
	if (self.anim_channel_key_selection.len() > 0)
	{
		return self.retime_selected_animation_channels(ref, retime);
	}

	foreach (frame : clip.keyframes)
	{
		if (!self.animation_key_selected(ref, frame.time)) continue;
		float destination = retime.map(frame.time);
		if (!(destination >= 0.0f && destination <= clip.duration)) return false;
		foreach (other : clip.keyframes)
		{
			bool selected = self.animation_key_selected(ref, other.time);
			if (selected && math::abs(other.time - frame.time) < ANIM_SAME_TIME) continue;
			float lands = selected ? retime.map(other.time) : other.time;
			if (math::abs(lands - destination) < ANIM_SAME_TIME) return false;
		}
	}

	AnimTemplate changed = clip_copy(mem, *clip);
	foreach (&frame : changed.keyframes)
	{
		if (self.animation_key_selected(ref, frame.time)) frame.time = retime.map(frame.time);
	}
	// A selected group may pass an unselected key, so restore global time order.
	// Stable, so keys the move did not reorder keep their places.
	sort::insertionsort(changed.keyframes, &by_key_time);

	// Landing clears the selection, so it is carried over in tmem.
	float[] moved = self.anim_key_selection.to_tarray();
	foreach (&time : moved) *time = retime.map(*time);
	AnimRef landed = self.land_key_edit(ref, changed);
	if (!landed.valid()) return false;
	self.restart_key_selection(landed);
	foreach (time : moved) self.select_time(time);
	self.editing = landed;
	return true;
}

fn bool AppState.channel_selection_contains(&self, float time, String joint, AnimChannels channel)
{
	foreach (selected : self.anim_channel_key_selection)
		if (selected.joint == joint && selected.channel == channel
			&& math::abs(selected.time - time) < ANIM_SAME_TIME) return true;
	return false;
}

<*
 The part of `frame` whose channels are in the channel selection — or, with
 `selected` false, the part that is not. Each surviving entry keeps only those
 channels; a frame nothing survives in comes back with no entries.
*>
fn AnimKeyframe AppState.key_channels(&self, AnimKeyframe frame, bool selected)
{
	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : frame.dots)
	{
		bool rotation = dot.keys_rotation()
			&& self.channel_selection_contains(frame.time, dot.joint_name, ROTATION) == selected;
		bool translation = dot.keys_translation()
			&& self.channel_selection_contains(frame.time, dot.joint_name, TRANSLATION) == selected;
		if (rotation || translation) kept.push(dot.narrowed(mem, rotation, translation));
	}
	return { .time = frame.time, .dots = kept.to_array(mem) };
}

<*
 The clip cut down to its selected channels, or with `selected` false to
 everything else. Keyframes left with no entries are dropped.
*>
fn AnimTemplate AppState.clip_channels(&self, AnimTemplate source, bool selected)
{
	AnimKeyframeList kept;
	kept.init(mem);
	defer kept.free();
	foreach (frame : source.keyframes)
	{
		AnimKeyframe filtered = self.key_channels(frame, selected);
		if (filtered.dots.len == 0) { filtered.free(mem); continue; }
		kept.push(filtered);
	}
	return clip_with_frames(mem, source, kept.to_array(mem), source.duration);
}

fn bool AppState.retime_selected_animation_channels(&self, AnimRef ref, KeyRetime retime)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref)
		|| self.anim_channel_key_selection.len() == 0 || self.pose_edit_pending) return false;
	if (retime.identity()) return true;
	foreach (selected : self.anim_channel_key_selection)
	{
		float destination = retime.map(selected.time);
		if (!(destination >= 0.0f && destination <= clip.duration)) return false;
		foreach (frame : clip.keyframes) if (math::abs(frame.time - destination) < ANIM_SAME_TIME
			&& frame.has_channel(selected.joint, selected.channel)
			&& !self.channel_selection_contains(frame.time, selected.joint, selected.channel)) return false;
		foreach (other : self.anim_channel_key_selection) if (
			other.joint == selected.joint && other.channel == selected.channel
			&& math::abs(other.time - selected.time) >= ANIM_SAME_TIME
			&& math::abs(retime.map(other.time) - destination) < ANIM_SAME_TIME) return false;
	}
	AnimTemplate built = self.clip_channels(*clip, false);
	foreach (selected : self.anim_channel_key_selection)
	{
		// Distinct destinations can both merge into the same resident timestamp
		// within epsilon. Check the staged result too: never let the later moved
		// key overwrite the earlier one through an unrelated channel's frame.
		foreach (frame : built.keyframes)
		{
			if (math::abs(frame.time - retime.map(selected.time)) < ANIM_SAME_TIME
				&& frame.has_channel(selected.joint, selected.channel))
			{
				built.free(mem);
				return false;
			}
		}
		sz at = self.key_near(ref, selected.time, ANIM_SAME_TIME);
		if (at < 0) continue;
		foreach (dot : clip.keyframes[at].dots) if (dot.joint_name == selected.joint
			&& (selected.channel == ROTATION ? dot.keys_rotation() : dot.keys_translation()))
		{
			AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
			dots[0] = dot.narrowed(mem, selected.channel == ROTATION, selected.channel == TRANSLATION);
			AnimTemplate next = clip_with_key(mem, built,
				{ .time = retime.map(selected.time), .dots = dots });
			built.free(mem); built = next;
			break;
		}
	}
	// Landing clears the selection, so it is carried over in tmem.
	AnimChannelKey[] moved = self.anim_channel_key_selection.to_tarray();
	foreach (&selected : moved)
	{
		selected.joint = selected.joint.tcopy();
		selected.time = retime.map(selected.time);
		// `clip_with_key` keeps the resident frame's canonical time when a moved
		// channel lands within epsilon of an unrelated channel. Keep selection on
		// that exact time so a later move cannot accumulate the tiny discrepancy.
		foreach (frame : built.keyframes)
			if (math::abs(frame.time - selected.time) < ANIM_SAME_TIME)
			{ selected.time = frame.time; break; }
	}
	AnimRef landed = self.land_key_edit(ref, built);
	if (!landed.valid()) return false;
	self.restart_key_selection(landed);
	foreach (selected : moved) self.select_channel(selected.time, selected.joint, selected.channel);
	self.editing = landed;
	return true;
}

fn bool AppState.delete_selected_animation_keys(&self, AnimRef ref)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref)
		|| (self.anim_key_selection.len() == 0 && self.anim_channel_key_selection.len() == 0)
		|| self.pose_edit_pending) return false;
	if (self.anim_channel_key_selection.len() > 0)
	{
		AnimTemplate changed = self.clip_channels(*clip, false);
		if (changed.keyframes.len == 0)
		{
			changed.free(mem);
			self.@notice("an animation needs one key — to be rid of it, use ⋯ > Delete animation…");
			return false;
		}
		AnimRef landed = self.land_key_edit(ref, changed);
		if (!landed.valid()) return false;
		self.clear_animation_key_selection();
		self.editing = landed;
		return true;
	}
	usz remove = 0;
	foreach (frame : clip.keyframes) if (self.animation_key_selected(ref, frame.time)) remove++;
	if (remove == 0) return false;
	if (remove >= clip.keyframes.len)
	{
		self.@notice("an animation needs one key — to be rid of it, use ⋯ > Delete animation…");
		return false;
	}

	AnimTemplate changed = clip_copy(mem, *clip);
	// Rebuild once so the whole deletion is one clip swap and one undo entry.
	AnimKeyframe[] kept = alloc::new_array(mem, AnimKeyframe, (sz)(clip.keyframes.len - remove));
	usz write = 0;
	foreach (frame : clip.keyframes)
	{
		if (!self.animation_key_selected(ref, frame.time)) kept[write++] = keyframe_copy(mem, frame);
	}
	foreach (frame : changed.keyframes)
	{
		foreach (dot : frame.dots) if (dot.joint_name.len > 0) alloc::free(mem, dot.joint_name.ptr);
		if (frame.dots.len > 0) alloc::free(mem, frame.dots);
	}
	if (changed.keyframes.len > 0) alloc::free(mem, changed.keyframes);
	changed.keyframes = kept;
	AnimRef landed = self.land_key_edit(ref, changed);
	if (!landed.valid()) return false;
	self.clear_animation_key_selection();
	self.editing = landed;
	return true;
}

// Whether every selected outgoing channel resolves to `interpolation`. A pose
// selection covers all channels keyed in its selected columns; an expanded
// track selection covers only its selected rotation/position diamonds.
fn bool AppState.animation_selection_uses_interpolation(&self, AnimRef ref,
	AnimInterpolation interpolation)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref)) return false;
	usz seen;
	foreach (frame : clip.keyframes) foreach (dot : frame.dots)
	{
		if (self.anim_channel_key_selection.len() > 0)
		{
			if (dot.keys_rotation()
				&& self.channel_selection_contains(frame.time, dot.joint_name, ROTATION))
			{
				if (dot.interpolation(true, clip.blend) != interpolation) return false;
				seen++;
			}
			if (dot.keys_translation()
				&& self.channel_selection_contains(frame.time, dot.joint_name, TRANSLATION))
			{
				if (dot.interpolation(false, clip.blend) != interpolation) return false;
				seen++;
			}
			continue;
		}
		if (!self.animation_key_selected(ref, frame.time)) continue;
		if (dot.keys_rotation())
		{
			if (dot.interpolation(true, clip.blend) != interpolation) return false;
			seen++;
		}
		if (dot.keys_translation())
		{
			if (dot.interpolation(false, clip.blend) != interpolation) return false;
			seen++;
		}
	}
	return seen > 0;
}

// Rewrite all selected outgoing segments as one clip swap and therefore one
// undo transaction. Times, values and channel masks are deliberately untouched.
fn bool AppState.set_selected_animation_interpolation(&self, AnimRef ref,
	AnimInterpolation interpolation)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref) || self.pose_edit_pending
		|| interpolation == INHERIT) return false;

	AnimTemplate changed = clip_copy(mem, *clip);
	usz written;
	foreach (&frame : changed.keyframes) foreach (&dot : frame.dots)
	{
		if (self.anim_channel_key_selection.len() > 0)
		{
			if (dot.keys_rotation()
				&& self.channel_selection_contains(frame.time, dot.joint_name, ROTATION))
			{
				dot.rotation_interpolation = interpolation;
				written++;
			}
			if (dot.keys_translation()
				&& self.channel_selection_contains(frame.time, dot.joint_name, TRANSLATION))
			{
				dot.translation_interpolation = interpolation;
				written++;
			}
			continue;
		}
		if (!self.animation_key_selected(ref, frame.time)) continue;
		if (dot.keys_rotation()) { dot.rotation_interpolation = interpolation; written++; }
		if (dot.keys_translation()) { dot.translation_interpolation = interpolation; written++; }
	}
	if (written == 0) { changed.free(mem); return false; }
	return self.land_keeping_selection(ref, changed, true);
}

fn int by_key_time(AnimKeyframe a, AnimKeyframe b) @local => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0);

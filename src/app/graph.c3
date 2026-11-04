<*
 The Curves sheet: the selected joints' channels drawn as value over time, and
 the edits made on them.

 Rotations are shown as XYZ Euler degrees (applied X, then Y, then Z) of the
 key's own parent-relative turn, and positions in model units. Both are display
 only: the curve is sampled through the clip's own sampler, and an edit writes
 the quaternion or move back into the key. A curve is unwrapped sample to
 sample, so a turn past ±180° reads as a continuous line rather than a jump.

 Rotation and position curves share the plot. Which of them are drawn is the
 character's: a curve is hidden by its joint, channel and axis (`GraphSlot`), and
 `build_graph` leaves hidden ones out, so their keys cannot be picked or
 dragged. When both kinds are drawn their units differ, so each curve is shown
 normalised to its own range (`GraphCurve.shown` / `real`); alone, a kind is
 drawn in its real units.

 A handle is the Bezier control point of a key's tangent on one side, drawn a
 third of that side's segment away: the key's point plus the effective tangent
 (`effective_tangent`, whatever the key's mode) for the curve's axis, so it lies
 on the curve's own slope at the key. Handles are drawn for selected keys only,
 and not on a side whose segment holds or is linear. A drag reads only the
 slope off the handle and writes it as the key's tangent (`set_graph_tangent`).
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::sort;
import std::collections::list;

// ---------------------------------------------------------------------------
// Which curves are drawn

fn bool AppState.graph_hidden(&self, uint joint, bool rotation, int axis)
{
	foreach (slot : self.anim_graph_hidden.array_view())
	{
		if (slot.joint == joint && slot.rotation == rotation && slot.axis == axis) return true;
	}
	return false;
}

fn void AppState.set_graph_hidden(&self, uint joint, bool rotation, int axis, bool hidden)
{
	foreach (sz i, slot : self.anim_graph_hidden.array_view())
	{
		if (slot.joint != joint || slot.rotation != rotation || slot.axis != axis) continue;
		if (!hidden) self.anim_graph_hidden.remove_at(i);
		return;
	}
	if (hidden) self.anim_graph_hidden.push({ .joint = joint, .rotation = rotation, .axis = axis });
}

// Every curve back, joints that are not selected included.
fn void AppState.show_all_graph_curves(&self) => self.anim_graph_hidden.clear();

<*
 Whether some (`all` false) or every (`all` true) curve of `channels` that `pick`
 names is drawn. A pick that names none of them reads as not drawn.
*>
fn bool AppState.graph_pick_drawn(&self, GraphChannel[] channels, GraphPick pick, bool all)
{
	bool found;
	foreach (channel : channels)
	{
		for (int axis = 0; axis < 3; axis++)
		{
			if (!pick.covers(channel.id, channel.rotation, axis)) continue;
			bool drawn = !self.graph_hidden(channel.id, channel.rotation, axis);
			if (all && !drawn) return false;
			if (!all && drawn) return true;
			found = true;
		}
	}
	return all && found;
}

<*
 Draw what `pick` names among `channels` (the listed joints') as `mode` says.
 Joints that are not listed keep what they had.
*>
fn void AppState.pick_graph_curves(&self, GraphChannel[] channels, GraphPick pick, GraphPickMode mode)
{
	bool hide_picked = mode == TOGGLE && self.graph_pick_drawn(channels, pick, true);
	foreach (channel : channels)
	{
		for (int axis = 0; axis < 3; axis++)
		{
			bool picked = pick.covers(channel.id, channel.rotation, axis);
			switch (mode)
			{
				case SOLO: self.set_graph_hidden(channel.id, channel.rotation, axis, !picked);
				case ADD: if (picked) self.set_graph_hidden(channel.id, channel.rotation, axis, false);
				case TOGGLE: if (picked) self.set_graph_hidden(channel.id, channel.rotation, axis, hide_picked);
			}
		}
	}
}

fn bool AppState.graph_folded(&self, uint joint, int part)
{
	foreach (fold : self.anim_graph_folded.array_view()) if (fold.joint == joint && fold.part == part) return true;
	return false;
}

fn void AppState.toggle_graph_fold(&self, uint joint, int part)
{
	foreach (sz i, fold : self.anim_graph_folded.array_view())
	{
		if (fold.joint != joint || fold.part != part) continue;
		self.anim_graph_folded.remove_at(i);
		return;
	}
	self.anim_graph_folded.push({ .joint = joint, .part = part });
}

// ---------------------------------------------------------------------------
// Euler degrees

// ---------------------------------------------------------------------------
// Building the picture

<*
 The selected joints' curves for the clip being edited: rotation and position
 of every joint that keys them, less the ones hidden (`graph_hidden`).
*>
fn Graph AppState.build_graph(&self, AnimRef ref)
{
	Graph graph = { .unit = 1.0f };
	self.ensure_clip_imported(ref);
	// The active keyed layer's keys when there is one (see `key_clip`); a
	// generator layer has none to draw.
	if (self.procedural_layer_of(ref)) { graph.procedural = true; return graph; }
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || clip.keyframes.len == 0 || !(clip.duration > 0.0f)) return graph;

	StringList names;
	names.init(mem);
	defer names.free();
	List{uint} ids;
	ids.init(mem);
	defer ids.free();
	String primary = "";
	if (try view = self.open_rig(mem))
	{
		defer view.free(mem);
		graph.unit = math::max(view.skeleton.height(), 1.0e-6f);
		String[] words = self.names_for(&view, ref);
		foreach (usz i, name : words)
		{
			if (i >= view.dot_ids.len || name.len == 0 || !self.is_selected(view.dot_ids[i])) continue;
			if (clip.channel_count(name, true) == 0 && clip.channel_count(name, false) == 0) continue;
			names.push(name);
			ids.push(view.dot_ids[i]);
			if (view.dot_ids[i] == self.selected) primary = name;
		}
	}
	if (names.len() == 0) return graph;
	if (primary.len == 0) primary = names[0];

	List{GraphChannel} channels;
	channels.init(mem);
	defer channels.free();
	List{GraphCurve} curves;
	curves.init(mem);
	defer curves.free();
	List{GraphKey} keys;
	keys.init(mem);
	defer keys.free();
	List{GraphHandle} handles;
	handles.init(mem);
	defer handles.free();

	foreach (usz n, name : names.array_view())
	for (int pass = 0; pass < 2; pass++)
	{
		bool rotation = pass == 0;
		if (clip.channel_count(name, rotation) == 0) continue;
		uint id = ids[(sz)n];
		channels.push({ .joint = name.copy(mem), .id = id, .rotation = rotation, .primary = name == primary });
		bool[3] drawn;
		bool some;
		for (int axis = 0; axis < 3; axis++)
		{
			drawn[axis] = !self.graph_hidden(id, rotation, axis);
			some = some || drawn[axis];
		}
		if (!some) continue;

		// The channel's keys, in time order.
		List{float} key_times;
		key_times.init(mem);
		defer key_times.free();
		List{usz} key_frames; // the clip's keyframe of each
		key_frames.init(mem);
		defer key_frames.free();
		foreach (usz f, frame : clip.keyframes)
		{
			AnimKeyDot ignored;
			if (!frame.channel_dot(name, rotation, &ignored)) continue;
			key_times.push(frame.time);
			key_frames.push(f);
		}
		List{float} times;
		times.init(mem);
		defer times.free();
		for (usz i = 0; i <= GRAPH_SAMPLES; i++) times.push(clip.duration * (float)i / (float)GRAPH_SAMPLES);
		foreach (at : key_times.array_view()) times.push(at);
		float[] sorted = times.array_view();
		sort::quicksort(sorted, &by_float);

		// Sampled once per time, unwrapped along the way, shared by the three axes.
		Vec3[] values = alloc::new_array(mem, Vec3, (sz)sorted.len);
		defer alloc::free(mem, values);
		Vec3 near;
		foreach (usz i, at : sorted)
		{
			values[i] = graph_value(clip, name, rotation, at, near, graph.unit);
			near = values[i];
		}

		usz[3] curve_of;
		for (int axis = 0; axis < 3; axis++)
		{
			if (!drawn[axis]) continue;
			Vec2[] samples = alloc::new_array(mem, Vec2, (sz)sorted.len);
			foreach (usz i, at : sorted) samples[i] = { at, values[i][axis] };
			curve_of[axis] = (usz)curves.len();
			curves.push({ .joint = name.copy(mem), .rotation = rotation, .axis = axis,
				.primary = name == primary, .samples = samples });
		}

		AnimChannels channel = rotation ? ROTATION : TRANSLATION;
		foreach (usz k, at : key_times.array_view())
		{
			Vec3 shown;
			foreach (usz i, t : sorted) if (t == at) { shown = values[i]; break; }
			bool selected = self.animation_key_selected(ref, at)
				|| self.animation_channel_key_selected(ref, at, name, channel);
			usz[3] key_of;
			for (int axis = 0; axis < 3; axis++)
			{
				if (!drawn[axis]) continue;
				key_of[axis] = (usz)keys.len();
				keys.push({ .curve = curve_of[axis], .time = at, .value = shown[axis],
					.shown = shown, .selected = selected });
			}

			// Handles on this key's own ends: the tangent leaving it and the one
			// arriving at it, each a third of its segment away.
			if (!selected) continue;
			for (int side = 0; side < 2; side++)
			{
				bool incoming = side == 1;
				if (incoming ? k == 0 : (sz)k + 1 >= key_times.len()) continue;
				// The segment belongs to the key it leaves from.
				usz owner = incoming ? key_frames[(sz)k - 1] : key_frames[(sz)k];
				float span = incoming ? at - key_times[(sz)k - 1] : key_times[(sz)k + 1] - at;
				if (!(span > 0.0f)) continue;
				AnimKeyDot dot;
				if (!clip.keyframes[owner].channel_dot(name, rotation, &dot)) continue;
				AnimInterpolation curve = dot.interpolation(rotation, clip.blend);
				if (curve == HOLD || curve == LINEAR) continue;
				Vec3 rate = effective_tangent(*clip, key_frames[(sz)k], name, rotation, incoming);
				// Per second, in the units the curve is drawn in.
				Vec3 slope = rotation ? euler_rate_of_angular_rate(shown, rate) : rate * graph.unit;
				float length = span / 3.0f;
				for (int axis = 0; axis < 3; axis++)
				{
					if (!drawn[axis]) continue;
					float run = incoming ? -length : length;
					handles.push({ .key = key_of[axis], .incoming = incoming, .length = length,
						.at = { at + run, shown[axis] + slope[axis] * run } });
				}
			}
		}
	}
	graph.curves = curves.to_array(mem);
	graph.keys = keys.to_array(mem);
	graph.handles = handles.to_array(mem);
	graph.channels = channels.to_array(mem);

	// Two kinds in one plot: each curve fills -1..1 by its own range.
	bool has_rotation;
	bool has_position;
	foreach (curve : graph.curves)
	{
		has_rotation = has_rotation || curve.rotation;
		has_position = has_position || !curve.rotation;
	}
	graph.mixed = has_rotation && has_position;
	if (graph.mixed)
	{
		foreach (&curve : graph.curves)
		{
			float low = curve.samples[0].y;
			float high = low;
			foreach (p : curve.samples) { low = math::min(low, p.y); high = math::max(high, p.y); }
			curve.mid = (low + high) * 0.5f;
			curve.half = math::max((high - low) * 0.5f, curve.rotation ? 0.5f : 5.0e-5f * graph.unit);
		}
	}
	return graph;
}

// ---------------------------------------------------------------------------
// Edits, each one clip swap and so one undo step

<*
 Land `changed`, keeping the key selection across the landing: the times and
 joints still name the same keys in the rewritten clip (or its authored fork).
*>
fn bool AppState.land_keeping_selection(&self, AnimRef ref, AnimTemplate changed, bool layered = false)
{
	float[] times = self.anim_key_selection.to_tarray();
	AnimChannelKey[] channels = self.anim_channel_key_selection.to_tarray();
	foreach (&channel : channels) channel.joint = channel.joint.tcopy();
	bool had = self.anim_key_selection_ref.same(ref);
	// `layered`: `changed` was built from `key_clip`, so it is the active keyed
	// layer's keys that are being replaced, not the base's.
	AnimRef landed = layered ? self.land_key_edit(ref, changed) : self.land_clip(ref, changed);
	if (!landed.valid()) return false;
	if (had)
	{
		self.restart_key_selection(landed);
		foreach (time : times) self.select_time(time);
		foreach (channel : channels) self.select_channel(channel.time, channel.joint, channel.channel);
	}
	self.editing = landed;
	return true;
}

<*
 Set one displayed component of a channel key: an Euler angle in degrees, or a
 position in model units. `shown` is the key's three components as the graph
 drew them, so the other two stay where they were.
*>
fn bool AppState.set_graph_key_value(&self, AnimRef ref, String joint, bool rotation, float time,
	Vec3 shown, int axis, float value, float unit = 1.0f)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || self.pose_edit_pending || axis < 0 || axis > 2 || !math::is_finite(value)) return false;
	sz key = self.key_near(ref, time, ANIM_SAME_TIME);
	if (key < 0) return false;
	AnimTemplate changed = clip_copy(mem, *clip);
	AnimKeyDot* dot = channel_entry(&changed.keyframes[key], joint, rotation);
	if (!dot) { changed.free(mem); return false; }
	Vec3 next = shown;
	next[axis] = value;
	if (rotation)
	{
		axis_angle_of(quat_of_euler(next), &dot.axis, &dot.angle);
	}
	else
	{
		dot.move = next * (1.0f / math::max(unit, 1.0e-6f));
	}
	return self.land_keeping_selection(ref, changed, true);
}

<*
 Set one axis of a channel key's tangent on one side from a dragged handle, as one
 clip swap. `slope` is the handle's slope in the curve's displayed units per
 second (degrees, or model units); `shown` is the key's three components as the
 graph drew them, which turns a rotation's Euler slope into the angular rate and
 keeps the other two Euler angles' rates as they were.

 A key that is not Free or Broken becomes Free first, so the other side follows
 the drag (`set_tangent_rate` realigns it), or Broken with `broken`, which also
 breaks a Free key: the other side stays where it was.

 @param incoming : `The tangent arriving at the key, else the one leaving it.`
*>
fn bool AppState.set_graph_tangent(&self, AnimRef ref, String joint, bool rotation, float time,
	Vec3 shown, int axis, bool incoming, float slope, float unit = 1.0f, bool broken = false)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || self.pose_edit_pending || axis < 0 || axis > 2
		|| !math::is_finite(slope)) return false;
	sz key = self.key_near(ref, time, ANIM_SAME_TIME);
	if (key < 0) return false;
	AnimTemplate changed = clip_copy(mem, *clip);
	AnimKeyDot* dot = channel_entry(&changed.keyframes[key], joint, rotation);
	if (!dot) { changed.free(mem); return false; }

	AnimTangent mode = dot.tangents(rotation).mode;
	if (broken ? mode != BROKEN : (mode != FREE && mode != BROKEN))
	{
		set_tangent_mode(&changed, (usz)key, joint, rotation, broken ? BROKEN : FREE);
	}
	Vec3 rate = effective_tangent(changed, (usz)key, joint, rotation, incoming);
	if (rotation)
	{
		Vec3 euler_rate = euler_rate_of_angular_rate(shown, rate);
		euler_rate[axis] = slope;
		rate = angular_rate_of_euler_rate(shown, euler_rate);
	}
	else
	{
		rate[axis] = slope / math::max(unit, 1.0e-6f);
	}
	if (!set_tangent_rate(&changed, (usz)key, joint, rotation, incoming, rate))
	{
		changed.free(mem);
		return false;
	}
	return self.land_keeping_selection(ref, changed, true);
}

<*
 Whether every selected outgoing channel carries `ease`. As
 `animation_selection_uses_interpolation`: a pose selection covers every channel
 keyed in its columns, a channel selection only its own keys.
*>
fn bool AppState.animation_selection_uses_ease(&self, AnimRef ref, AnimEase ease)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref)) return false;
	usz seen;
	bool channels = self.anim_channel_key_selection.len() > 0;
	foreach (frame : clip.keyframes) foreach (dot : frame.dots)
	{
		for (int c = 0; c < 2; c++)
		{
			bool rotation = c == 0;
			if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
			bool picked = channels
				? self.channel_selection_contains(frame.time, dot.joint_name, rotation ? ROTATION : TRANSLATION)
				: self.animation_key_selected(ref, frame.time);
			if (!picked) continue;
			if (!dot.ease(rotation).same(ease)) return false;
			seen++;
		}
	}
	return seen > 0;
}

<*
 Give every selected outgoing channel `ease`, as one clip swap. Values, times,
 channels and interpolation are untouched; a held segment keeps the ease and
 ignores it until it is set to move.
*>
fn bool AppState.set_selected_animation_ease(&self, AnimRef ref, AnimEase ease)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || !self.anim_key_selection_ref.same(ref) || self.pose_edit_pending) return false;
	ease = ease.clamped();
	bool channels = self.anim_channel_key_selection.len() > 0;
	AnimTemplate changed = clip_copy(mem, *clip);
	usz written;
	foreach (&frame : changed.keyframes) foreach (&dot : frame.dots)
	{
		if (dot.keys_rotation() && (channels
			? self.channel_selection_contains(frame.time, dot.joint_name, ROTATION)
			: self.animation_key_selected(ref, frame.time)))
		{
			dot.rotation_ease = ease;
			written++;
		}
		if (dot.keys_translation() && (channels
			? self.channel_selection_contains(frame.time, dot.joint_name, TRANSLATION)
			: self.animation_key_selected(ref, frame.time)))
		{
			dot.translation_ease = ease;
			written++;
		}
	}
	if (written == 0) { changed.free(mem); return false; }
	return self.land_keeping_selection(ref, changed, true);
}

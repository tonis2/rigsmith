<*
 The Curves sheet: the selected joints' channels drawn as value over time, and
 the edits made on them.

 Rotations are shown as XYZ Euler degrees (applied X, then Y, then Z) of the
 key's own parent-relative turn, and positions in model units. Both are display
 only: the curve is sampled through the clip's own sampler, and an edit writes
 the quaternion or move back into the key. A curve is unwrapped sample to
 sample, so a turn past ±180° reads as a continuous line rather than a jump.

 A handle is the Bezier control point an ease sets on one end of a segment,
 drawn a third of the way along it: on the segment's own tangent when it has no
 ease, flat against the key when fully eased. Handles are drawn for selected
 keys only.
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::sort;
import std::collections::list;

// Evenly spaced samples per curve over the whole clip, plus one at every key.
const usz GRAPH_SAMPLES = 240;

struct GraphCurve
{
	String joint; // owned
	bool rotation;
	int axis; // 0 = X, 1 = Y, 2 = Z
	bool primary; // the joint selected last; others are drawn fainter
	Vec2[] samples; // owned; (seconds, value)
}

struct GraphKey
{
	usz curve;
	float time;
	float value;
	Vec3 shown; // the key's three displayed components, which an edit keeps
	bool selected;
}

struct GraphHandle
{
	usz key; // the key it hangs off
	// True: the key's outgoing ease (`AnimEase.start` of its own segment).
	// False: the arriving end of the segment before it (`AnimEase.end` there).
	bool start;
	float owner; // the key whose outgoing segment carries the ease
	float natural; // the value change over a third of the segment with no ease
	Vec2 at;
}

struct Graph
{
	GraphCurve[] curves;
	GraphKey[] keys;
	GraphHandle[] handles;
	float unit; // model units per stored move (rig height); 1 for rotations
	// A generator layer is active: it holds no keys, so there is nothing to draw
	// or drag. The sheet says "procedural layer — edit its parameters".
	bool procedural;
}

fn void Graph.free(&self)
{
	foreach (curve : self.curves)
	{
		curve.joint.free(mem);
		if (curve.samples.len > 0) alloc::free(mem, curve.samples);
	}
	if (self.curves.len > 0) alloc::free(mem, self.curves);
	if (self.keys.len > 0) alloc::free(mem, self.keys);
	if (self.handles.len > 0) alloc::free(mem, self.handles);
	*self = {};
}

// ---------------------------------------------------------------------------
// Euler degrees

fn float wrap_near(float angle, float near) @local
{
	float turn = 2.0f * (float)math::PI;
	return angle + turn * math::round((near - angle) / turn);
}

<*
 A turn as XYZ Euler degrees (R = Rz · Ry · Rx), the solution nearest `near`.
*>
fn Vec3 euler_of(Quaternionf q, Vec3 near)
{
	Vec3 c0 = q.rotate_vec3({ 1, 0, 0 });
	Vec3 c1 = q.rotate_vec3({ 0, 1, 0 });
	Vec3 c2 = q.rotate_vec3({ 0, 0, 1 });
	Vec3 n = near * (float)(math::PI / 180.0);
	float sy = math::clamp(-c0.z, -1.0f, 1.0f);
	Vec3 best;
	if (math::abs(sy) > 0.99999f)
	{
		float y = sy > 0 ? (float)math::PI * 0.5f : -(float)math::PI * 0.5f;
		float x = n.x;
		float z = sy > 0 ? x - math::atan2(c1.x, c1.y) : math::atan2(-c1.x, c1.y) - x;
		best = { x, wrap_near(y, n.y), wrap_near(z, n.z) };
	}
	else
	{
		float y = math::asin(sy);
		float x = math::atan2(c1.z, c2.z);
		float z = math::atan2(c0.y, c0.x);
		Vec3 a = { wrap_near(x, n.x), wrap_near(y, n.y), wrap_near(z, n.z) };
		float pi = (float)math::PI;
		Vec3 b = { wrap_near(x + pi, n.x), wrap_near(pi - y, n.y), wrap_near(z + pi, n.z) };
		best = (a - n).length_sq() <= (b - n).length_sq() ? a : b;
	}
	return best * (float)(180.0 / math::PI);
}

fn Quaternionf quat_of_euler(Vec3 degrees)
{
	Vec3 r = degrees * (float)(math::PI / 180.0);
	Quaternionf qx = quaternion::from_axis_angle{float}({ 1, 0, 0 }, r.x);
	Quaternionf qy = quaternion::from_axis_angle{float}({ 0, 1, 0 }, r.y);
	Quaternionf qz = quaternion::from_axis_angle{float}({ 0, 0, 1 }, r.z);
	return qz.mul(qy).mul(qx).normalize();
}

// ---------------------------------------------------------------------------
// Building the picture

// The channel's value at `time`, in display units, nearest `near`.
fn Vec3 graph_value(AnimTemplate* clip, String joint, bool rotation, float time, Vec3 near,
	float unit, bool eased = true) @local
{
	if (rotation) return euler_of(clip.rotation_at(joint, time, eased: eased), near);
	return clip.translation_at(joint, time, eased: eased) * unit;
}

fn int by_float(float a, float b) @local => a < b ? -1 : (a > b ? 1 : 0);

<*
 The selected joints' curves for one channel of the clip being edited.

 @param position : `Position curves instead of rotation ones.`
*>
fn Graph AppState.build_graph(&self, AnimRef ref, bool position)
{
	Graph graph = { .unit = 1.0f };
	self.ensure_clip_imported(ref);
	// The active keyed layer's keys when there is one (see `key_clip`); a
	// generator layer has none to draw.
	if (self.procedural_layer_of(ref)) { graph.procedural = true; return graph; }
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || clip.keyframes.len == 0 || !(clip.duration > 0.0f)) return graph;
	bool rotation = !position;

	StringList names;
	names.init(mem);
	defer names.free();
	String primary = "";
	if (try view = self.open_rig(mem))
	{
		defer view.free(mem);
		if (!rotation) graph.unit = math::max(view.skeleton.height(), 1.0e-6f);
		String[] words = self.names_for(&view, ref);
		foreach (usz i, name : words)
		{
			if (i >= view.dot_ids.len || name.len == 0 || !self.is_selected(view.dot_ids[i])) continue;
			if (clip.channel_count(name, rotation) == 0) continue;
			names.push(name);
			if (view.dot_ids[i] == self.selected) primary = name;
		}
	}
	if (names.len() == 0) return graph;
	if (primary.len == 0) primary = names[0];

	List{GraphCurve} curves;
	curves.init(mem);
	defer curves.free();
	List{GraphKey} keys;
	keys.init(mem);
	defer keys.free();
	List{GraphHandle} handles;
	handles.init(mem);
	defer handles.free();

	foreach (name : names.array_view())
	{
		// The channel's keys, in time order.
		List{float} key_times;
		key_times.init(mem);
		defer key_times.free();
		foreach (frame : clip.keyframes)
		{
			AnimKeyDot ignored;
			if (frame.channel_dot(name, rotation, &ignored)) key_times.push(frame.time);
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

		usz first_curve = (usz)curves.len();
		for (int axis = 0; axis < 3; axis++)
		{
			Vec2[] samples = alloc::new_array(mem, Vec2, (sz)sorted.len);
			foreach (usz i, at : sorted) samples[i] = { at, values[i][axis] };
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
			usz key_base = (usz)keys.len();
			for (int axis = 0; axis < 3; axis++)
			{
				keys.push({ .curve = first_curve + (usz)axis, .time = at, .value = shown[axis],
					.shown = shown, .selected = selected });
			}

			// Handles on this key's own ends: its outgoing segment's start, and the
			// arriving end of the segment before it.
			if (!selected) continue;
			for (int side = 0; side < 2; side++)
			{
				bool start = side == 0;
				if (start ? (sz)k + 1 >= key_times.len() : k == 0) continue;
				float from = start ? at : key_times[(sz)k - 1];
				float to = start ? key_times[(sz)k + 1] : at;
				float span = to - from;
				if (!(span > 0.0f)) continue;
				sz owner = self.key_near(ref, from, ANIM_SAME_TIME);
				if (owner < 0) continue;
				AnimKeyDot dot;
				if (!clip.keyframes[owner].channel_dot(name, rotation, &dot)) continue;
				if (dot.interpolation(rotation, clip.blend) == HOLD) continue;
				AnimEase ease = dot.ease(rotation);
				float step = span * 1.0e-3f;
				Vec3 moved = graph_value(clip, name, rotation, start ? at + step : at - step, shown,
					graph.unit, false);
				Vec3 natural = (start ? moved - shown : shown - moved) * (1.0f / 3.0f / 1.0e-3f);
				for (int axis = 0; axis < 3; axis++)
				{
					Vec2[] line = curves[(sz)first_curve + axis].samples;
					float low = line[0].y;
					float high = line[0].y;
					foreach (p : line) { low = math::min(low, p.y); high = math::max(high, p.y); }
					float floor = math::max(high - low, rotation ? 1.0f : 1.0e-4f * graph.unit) * 1.0e-3f;
					if (math::abs(natural[axis]) <= floor) continue;
					float pull = 1.0f - (start ? ease.start : ease.end);
					handles.push({
						.key = key_base + (usz)axis, .start = start, .owner = from,
						.natural = natural[axis],
						.at = start ? (Vec2){ at + span / 3.0f, shown[axis] + pull * natural[axis] }
							: (Vec2){ at - span / 3.0f, shown[axis] - pull * natural[axis] },
					});
				}
			}
		}
	}
	graph.curves = curves.to_array(mem);
	graph.keys = keys.to_array(mem);
	graph.handles = handles.to_array(mem);
	return graph;
}

<*
 The ease a handle dragged to `value` asks for: how far its pull toward the key
 has gone, from 0 (the segment's own tangent) to 1 (flat).
*>
fn float GraphHandle.ease_for(self, float key_value, float value)
{
	if (self.natural == 0.0f) return 0.0f;
	float pull = self.start ? (value - key_value) / self.natural : (key_value - value) / self.natural;
	return math::clamp(1.0f - pull, 0.0f, 1.0f);
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

// The entry keying this joint's channel in `frame`, or null.
fn AnimKeyDot* channel_entry(AnimKeyframe* frame, String joint, bool rotation) @local
{
	foreach (&dot : frame.dots)
	{
		if (dot.joint_name != joint) continue;
		if (rotation ? dot.keys_rotation() : dot.keys_translation()) return dot;
	}
	return null;
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
 Set one end of a channel segment's ease, from a dragged handle. `owner` is the
 key the segment leaves from.
*>
fn bool AppState.set_graph_ease(&self, AnimRef ref, String joint, bool rotation, float owner,
	bool start, float ease)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || self.pose_edit_pending || !math::is_finite(ease)) return false;
	sz key = self.key_near(ref, owner, ANIM_SAME_TIME);
	if (key < 0) return false;
	AnimTemplate changed = clip_copy(mem, *clip);
	AnimKeyDot* dot = channel_entry(&changed.keyframes[key], joint, rotation);
	if (!dot) { changed.free(mem); return false; }
	AnimEase* target = rotation ? &dot.rotation_ease : &dot.translation_ease;
	if (start) { target.start = ease; } else { target.end = ease; }
	*target = target.clamped();
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

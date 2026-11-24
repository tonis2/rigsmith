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
 A curve grabbed between keys bends through the pointer (`bend_graph_segment`).
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

	GraphLook look = { .app = self, .ref = ref };
	GraphAsk ask = {
		.clip = clip,
		.names = names.array_view(),
		.ids = ids.array_view(),
		.primary = primary,
		.axis_hidden = &graph_axis_hidden,
		.key_selected = &graph_key_selected,
		.ctx = &look,
	};
	graph_fill(&graph, &ask);
	return graph;
}

// What the plot reads back from the app as it draws.
struct GraphLook @local
{
	AppState* app;
	AnimRef ref;
}

fn bool graph_axis_hidden(void* ctx, uint id, bool rotation, int axis) @local
{
	return ((GraphLook*)ctx).app.graph_hidden(id, rotation, axis);
}

fn bool graph_key_selected(void* ctx, float at, String name, AnimChannels channel) @local
{
	GraphLook* look = ctx;
	return look.app.animation_key_selected(look.ref, at)
		|| look.app.animation_channel_key_selected(look.ref, at, name, channel);
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
 breaks a Free key: the other side stays where it was. The slope is held at what
 keeps both segments within a quarter turn (`set_capped_tangent_rate`).

 @param incoming : `The tangent arriving at the key, else the one leaving it.`
 @param held : `Set when the slope was held at the swing limit.`
*>
fn bool AppState.set_graph_tangent(&self, AnimRef ref, String joint, bool rotation, float time,
	Vec3 shown, int axis, bool incoming, float slope, float unit = 1.0f, bool broken = false, bool* held = null)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || self.pose_edit_pending || axis < 0 || axis > 2
		|| !math::is_finite(slope)) return false;
	sz key = self.key_near(ref, time, ANIM_SAME_TIME);
	if (key < 0) return false;
	AnimTemplate changed = clip_copy(mem, *clip);
	if (!channel_entry(&changed.keyframes[key], joint, rotation)) { changed.free(mem); return false; }

	free_for_drag(&changed, (usz)key, joint, rotation, broken);
	Vec3 rate = effective_tangent(changed, (usz)key, joint, rotation, incoming);
	rate = with_display_slope(rate, rotation, shown, axis, slope, unit);
	bool capped;
	if (!set_capped_tangent_rate(&changed, (usz)key, joint, rotation, incoming, rate, &capped))
	{
		changed.free(mem);
		return false;
	}
	if (held) *held = capped;
	return self.land_keeping_selection(ref, changed, true);
}

// A key about to take a dragged tangent: Free, or Broken with `broken`. `curve`
// as `set_tangent_mode`: a linear segment leaving the key turns smooth.
fn void free_for_drag(AnimTemplate* clip, usz key, String joint, bool rotation, bool broken, bool curve = true) @local
{
	AnimKeyDot* dot = channel_entry(&clip.keyframes[key], joint, rotation);
	if (!dot) return;
	AnimTangent mode = dot.tangents(rotation).mode;
	if (broken ? mode != BROKEN : (mode != FREE && mode != BROKEN))
	{
		set_tangent_mode(clip, key, joint, rotation, broken ? BROKEN : FREE, curve);
	}
}

// `rate` with one displayed axis's slope set: degrees per second on an Euler
// angle, or model units per second on a position.
fn Vec3 with_display_slope(Vec3 rate, bool rotation, Vec3 shown, int axis, float slope, float unit) @local
{
	if (rotation) return rate_with_euler_slope(shown, rate, axis, slope);
	rate[axis] = slope / math::max(unit, 1.0e-6f);
	return rate;
}

// A rate's slope on one displayed axis, in the units `with_display_slope` takes.
fn float display_slope(Vec3 rate, bool rotation, Vec3 shown, int axis, float unit) @local
{
	if (rotation) return euler_rate_of_angular_rate(shown, rate)[axis];
	return rate[axis] * unit;
}

<*
 Bend the segment of a channel that holds `at`, so the displayed `axis` passes
 through `value` there. The first key's outgoing slope and the second's incoming
 one move by the same amount in opposite senses, which lifts the middle most;
 the amount is solved on the played curve. Both keys become Free (Broken with
 `broken`), each slope held as a handle drag is. One clip swap.

 @param shown_from : `The first key's displayed components, as the graph drew them.`
 @param shown_to : `The second key's.`
 @param held : `Set when a slope was held at the swing limit.`
 @return `False, with a notice, when there is no segment there to bend.`
*>
fn bool AppState.bend_graph_segment(&self, AnimRef ref, String joint, bool rotation, int axis, float at, float value,
	Vec3 shown_from, Vec3 shown_to, float unit = 1.0f, bool broken = false, bool* held = null)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || self.pose_edit_pending || axis < 0 || axis > 2
		|| !math::is_finite(value) || !math::is_finite(at)) return false;
	sz from = -1;
	sz to = -1;
	foreach (usz f, frame : clip.keyframes)
	{
		AnimKeyDot ignored;
		if (!frame.channel_dot(joint, rotation, &ignored)) continue;
		if (frame.time < at - ANIM_SAME_TIME) from = (sz)f;
		if (frame.time > at + ANIM_SAME_TIME) { to = (sz)f; break; }
	}
	if (from < 0 || to < 0)
	{
		self.@notice("Grab the curve between two keys to bend it.");
		return false;
	}
	AnimKeyDot first;
	clip.keyframes[from].channel_dot(joint, rotation, &first);
	if (first.interpolation(rotation, clip.blend) == HOLD)
	{
		self.@notice("A held segment can't bend: set it to Smooth first.");
		return false;
	}

	// Both keys free, the segment smooth; the key at the far end keeps its own next segment.
	AnimTemplate base = clip_copy(mem, *clip);
	defer base.free(mem);
	free_for_drag(&base, (usz)from, joint, rotation, broken);
	free_for_drag(&base, (usz)to, joint, rotation, broken, false);
	AnimKeyDot* leaving = channel_entry(&base.keyframes[from], joint, rotation);
	if (leaving.interpolation(rotation, base.blend) == LINEAR)
	{
		if (rotation) { leaving.rotation_interpolation = AUTO; } else { leaving.translation_interpolation = AUTO; }
	}
	Bend bend = {
		.base = &base, .from = (usz)from, .to = (usz)to, .joint = joint, .rotation = rotation, .axis = axis,
		.shown_from = shown_from, .shown_to = shown_to, .unit = unit,
		.out_rate = effective_tangent(base, (usz)from, joint, rotation, false),
		.in_rate = effective_tangent(base, (usz)to, joint, rotation, true),
	};
	float t0 = base.keyframes[from].time;
	float t1 = base.keyframes[to].time;
	float u = (at - t0) / (t1 - t0);
	Vec3 near = shown_from + (shown_to - shown_from) * u;
	near[axis] = value;
	float tolerance = rotation ? 0.1f : 1.0e-4f * unit;

	// The lift per unit of slope at `at`, from the cubic: span · u(1 − u).
	float lift = (t1 - t0) * u * (1.0f - u);
	float error_a = graph_value(&base, joint, rotation, at, near, unit)[axis] - value;
	float slope_a = 0.0f;
	float slope_b = lift > 1.0e-6f ? -error_a / lift : 0.0f;
	bool capped;
	AnimTemplate best = bend.at(slope_b, &capped);
	float error_b = graph_value(&best, joint, rotation, at, near, unit)[axis] - value;
	float best_error = math::abs(error_b);
	// The secant on the played value: a rotation is not a cubic in its Euler angles.
	for (int step = 0; step < 6 && best_error > tolerance && math::abs(error_b - error_a) > 1.0e-6f; step++)
	{
		float next = slope_b - error_b * (slope_b - slope_a) / (error_b - error_a);
		if (!math::is_finite(next)) break;
		bool next_capped;
		AnimTemplate tried = bend.at(next, &next_capped);
		float error = graph_value(&tried, joint, rotation, at, near, unit)[axis] - value;
		slope_a = slope_b;
		error_a = error_b;
		slope_b = next;
		error_b = error;
		if (math::abs(error) < best_error)
		{
			best.free(mem);
			best = tried;
			best_error = math::abs(error);
			capped = next_capped;
		}
		else
		{
			tried.free(mem);
		}
	}
	if (held) *held = capped;
	return self.land_keeping_selection(ref, best, true);
}

// A segment being bent: its two keys freed, and their slopes before the bend.
struct Bend @local
{
	AnimTemplate* base;
	usz from;
	usz to;
	String joint;
	bool rotation;
	int axis;
	Vec3 shown_from;
	Vec3 shown_to;
	float unit;
	Vec3 out_rate;
	Vec3 in_rate;
}

// The clip with the segment bent by `slope`: added leaving the first key, taken off arriving at the second.
fn AnimTemplate Bend.at(&self, float slope, bool* held)
{
	AnimTemplate bent = clip_copy(mem, *self.base);
	float out_slope = display_slope(self.out_rate, self.rotation, self.shown_from, self.axis, self.unit) + slope;
	float in_slope = display_slope(self.in_rate, self.rotation, self.shown_to, self.axis, self.unit) - slope;
	bool out_held;
	bool in_held;
	set_capped_tangent_rate(&bent, self.from, self.joint, self.rotation, false,
		with_display_slope(self.out_rate, self.rotation, self.shown_from, self.axis, out_slope, self.unit), &out_held);
	set_capped_tangent_rate(&bent, self.to, self.joint, self.rotation, true,
		with_display_slope(self.in_rate, self.rotation, self.shown_to, self.axis, in_slope, self.unit), &in_held);
	*held = out_held || in_held;
	return bent;
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

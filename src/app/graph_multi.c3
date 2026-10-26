<*
 Edits over the whole key selection of the Curves sheet: offset, scale or set
 one displayed axis of every selected key, or scale their times.

 The selection is channel keys (joint, channel, time); the graph draws three
 points per channel key, one per axis. A selected key means all three points,
 and an edit names the axis it acts on: the axis of the point dragged, or of the
 value field. A rotation key holds one quaternion, so changing the X angle of a
 key rewrites the key from its three displayed angles with only X replaced, and
 Y and Z read as before. Each edit is one clip swap and so one undo step, and
 keeps the selection.

 They take the `Graph` the sheet is showing, for what the points were drawn
 with: the unwrapped angles (`GraphKey.shown`) and the unit of positions. Only
 keys the graph holds are touched, so a joint not shown is never edited.
*>
module crig;

import std::math;

<*
 Rewrite `axis` of every selected key in `graph` as
 `pivot + (old - pivot) * scale + offset`: an offset is scale 1, a scale
 has no offset, and an exact value is scale 0 with the value as the pivot.
 False when nothing was written.
*>
fn bool AppState.edit_graph_keys(&self, AnimRef ref, Graph* graph, bool rotation, int axis, float scale,
	float pivot, float offset)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || self.pose_edit_pending || axis < 0 || axis > 2) return false;
	if (!math::is_finite(scale) || !math::is_finite(pivot) || !math::is_finite(offset)) return false;
	AnimTemplate changed = clip_copy(mem, *clip);
	usz written;
	foreach (key : graph.keys)
	{
		GraphCurve curve = graph.curves[key.curve];
		if (!key.selected || curve.rotation != rotation || curve.axis != axis) continue;
		sz at = self.key_near(ref, key.time, ANIM_SAME_TIME);
		if (at < 0) continue;
		AnimKeyDot* dot = channel_entry(&changed.keyframes[at], curve.joint, curve.rotation);
		if (!dot) continue;
		Vec3 next = key.shown;
		next[axis] = pivot + (key.value - pivot) * scale + offset;
		if (curve.rotation)
		{
			axis_angle_of(quat_of_euler(next), &dot.axis, &dot.angle);
		}
		else
		{
			dot.move = next * (1.0f / math::max(graph.unit, 1.0e-6f));
		}
		written++;
	}
	if (written == 0) { changed.free(mem); return false; }
	return self.land_keeping_selection(ref, changed, true);
}

// Move `axis` of every selected key by `delta` (degrees, or position units).
fn bool AppState.set_graph_keys_offset(&self, AnimRef ref, Graph* graph, bool rotation, int axis, float delta)
	=> self.edit_graph_keys(ref, graph, rotation, axis, 1.0f, 0.0f, delta);

// Scale `axis` of every selected key about `pivot`.
fn bool AppState.scale_graph_keys(&self, AnimRef ref, Graph* graph, bool rotation, int axis, float factor, float pivot)
	=> self.edit_graph_keys(ref, graph, rotation, axis, factor, pivot, 0.0f);

// Give `axis` of every selected key the same `value`.
fn bool AppState.set_graph_keys_exact(&self, AnimRef ref, Graph* graph, bool rotation, int axis, float value)
	=> self.edit_graph_keys(ref, graph, rotation, axis, 0.0f, value, 0.0f);

<*
 Scale the times of the selected keys about `pivot` (the playhead, from the
 plot), as the sheet's retime does: refused when a key would leave the clip or
 land on another key.
*>
fn bool AppState.scale_graph_key_times(&self, AnimRef ref, float factor, float pivot)
{
	if (!(factor > 0.0f) || !math::is_finite(factor) || !math::is_finite(pivot)) return false;
	return self.retime_selected_animation_keys(ref, { .anchor = pivot, .scale = factor });
}

<*
 How many selected keys of one channel the graph holds, and `axis` of them: the first one's
 value in `value`, `mixed` when they differ by more than `epsilon`.
*>
fn usz Graph.selected_values(&self, bool rotation, int axis, float* value, bool* mixed, float epsilon = 1.0e-3f)
{
	usz count;
	*mixed = false;
	foreach (key : self.keys)
	{
		GraphCurve curve = self.curves[key.curve];
		if (!key.selected || curve.rotation != rotation || curve.axis != axis) continue;
		if (count == 0)
		{
			*value = key.value;
		}
		else if (math::abs(key.value - *value) > epsilon)
		{
			*mixed = true;
		}
		count++;
	}
	return count;
}

<*
 The channel the value field speaks for: rotation when any selected key is a
 turn, else position. Both are drawn at once, and X means a different thing in each.
*>
fn bool Graph.selected_rotation(&self)
{
	foreach (key : self.keys) if (key.selected && self.curves[key.curve].rotation) return true;
	foreach (key : self.keys) if (key.selected) return false;
	return true;
}

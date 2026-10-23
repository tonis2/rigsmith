<*
 Editing a clip's motion paths: the one path the viewport's Path tool and the
 MCP `set_path` tool both take.

 A path is a curve a joint follows (anim/path.c3). Every change builds the
 clip's paths aside and lands the clip as one undo step (`land_clip`), as the
 pins and aims do. A drag in the viewport works on `path_draft`, a copy the
 player reads in place of the clip's own paths, and lands once when the pointer
 lets go; Esc drops the draft and nothing changed.
*>
module crig;

import rig;
import std::math;

fn void AppState.drop_path_draft(&self)
{
	free_anim_paths(mem, self.path_draft);
	self.path_draft = {};
	self.path_draft_active = false;
}

// ---------------------------------------------------------------------------
// Landing. Each is one undo step.

<*
 The clip with its paths replaced by `next` (taken over), landed.

 @return `Where the clip is now, or NO_ANIM when it could not land.`
*>
fn AnimRef AppState.land_paths(&self, AnimRef ref, AnimPath[] next)
{
	if (!self.ensure_clip_imported(ref))
	{
		free_anim_paths(mem, next);
		return NO_ANIM;
	}
	AnimTemplate* clip = self.clip(ref);
	if (!clip)
	{
		free_anim_paths(mem, next);
		return NO_ANIM;
	}
	self.drop_path_draft();
	return self.land_clip(ref, clip_with_paths(mem, *clip, next));
}

<*
 Add `path` (taken over) to the clip.

 @return `Its index, or -1.`
*>
fn sz AppState.add_path(&self, AnimRef ref, AnimPath path)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) { path.free(mem); return -1; }
	AnimPath[] next = alloc::new_array(mem, AnimPath, (sz)(clip.paths.len + 1));
	foreach (usz i, &held : clip.paths) next[i] = held.copy(mem);
	next[clip.paths.len] = path;
	usz at = clip.paths.len;
	if (!self.land_paths(ref, next).valid()) return -1;
	self.path_selected = (sz)at;
	return (sz)at;
}

// The path at `at` replaced by `path` (taken over).
fn bool AppState.replace_path(&self, AnimRef ref, usz at, AnimPath path)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.paths.len) { path.free(mem); return false; }
	AnimPath[] next = anim_paths_copy(mem, clip.paths);
	next[at].free(mem);
	next[at] = path;
	return self.land_paths(ref, next).valid();
}

fn bool AppState.remove_path(&self, AnimRef ref, usz at)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip || at >= clip.paths.len) return false;
	AnimPath[] next = alloc::new_array(mem, AnimPath, (sz)(clip.paths.len - 1));
	usz write;
	foreach (usz i, &held : clip.paths) if (i != at) next[write++] = held.copy(mem);
	if (!self.land_paths(ref, next).valid()) return false;
	if (self.path_selected >= (sz)next.len) self.path_selected = (sz)next.len - 1;
	return true;
}

<*
 Bake the clip's paths into its keys and take them off: the joints they bent keep
 that motion as ordinary keys, pins and aims stay live.

 @return? RIG_EMPTY : `There is no rig to bake against.`
*>
fn bool? AppState.bake_paths(&self, AnimRef ref)
{
	if (!self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || !clip.plays_paths()) return false;
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);
	// The joint limits hold the baked turns, as they do the export's.
	ConstraintRig constraints = constraint_rig_of(mem, &self.doc, &view.skeleton, view.dot_ids);
	defer constraints.free(mem);
	AnimTemplate baked = clip_paths_baked(mem, *clip, &view.skeleton, self.names_for(&view, ref), constraints);
	self.drop_path_draft();
	return self.land_clip(ref, baked).valid();
}

// How many points a path made from motion gets per second, and the most it gets.
const float PATH_FROM_MOTION_RATE = 8.0f;
const usz PATH_FROM_MOTION_MOST = 48;

<*
 A path through where `joint` goes in the clip as it plays now: a point every
 eighth of a second or so, a slice on each at its time, closed when the clip
 loops. Following it puts the joint where it already went; dragging its points
 then reshapes the motion. The caller owns the result.

 @return? RIG_EMPTY : `There is no rig, or it has no such joint.`
*>
fn AnimPath? AppState.path_from_motion(&self, AnimRef ref, String joint)
{
	if (!self.ensure_clip_imported(ref)) return RIG_EMPTY~;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || !(clip.duration > 0.0f)) return RIG_EMPTY~;
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	sz j = array::index_of(names, joint) ?? -1;
	if (j < 0) return RIG_EMPTY~;
	float height = view.skeleton.height();
	if (!(height > 0.0f)) return RIG_EMPTY~;

	usz count = math::clamp((usz)math::ceil(clip.duration * PATH_FROM_MOTION_RATE), (usz)4, PATH_FROM_MOTION_MOST);
	// A loop's last instant is its first: one point fewer, and the curve closes.
	usz points = clip.loop ? count : count + 1;
	AnimPath path = {
		.joint = joint.copy(mem),
		.name = string::format(mem, "%s path", joint),
		.closed = clip.loop,
		.points = alloc::new_array(mem, AnimPathPoint, (sz)points),
		.slices = alloc::new_array(mem, AnimPathSlice, (sz)points),
	};
	// The clip as it plays without paths of its own on this joint.
	AnimTemplate without = *clip;
	without.paths = {};
	for (usz i = 0; i < points; i++)
	{
		float time = clip.duration * (float)i / (float)count;
		rig::Pose pose = self.evaluated_clip_pose(mem, &view, without, ref, time, true);
		defer pose.free(mem);
		self.apply_clip_pins(&view, without, ref, time, &pose);
		Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
		if (catch palette) { path.free(mem); return RIG_EMPTY~; }
		defer alloc::free(mem, palette);
		path.points[i] = { .at = view.skeleton.joints[(usz)j].transform(palette[(usz)j]) / height };
		path.slices[i].time = time;
	}
	float[] lengths = path.length_table(mem);
	defer alloc::free(mem, lengths);
	float total = lengths[^1];
	foreach (usz i, &slice : path.slices)
	{
		// Every point is a slice, at its own place along the curve.
		slice.u = total > 1.0e-9f ? lengths[i * PATH_STEPS] / total : 0.0f;
		if (path.closed && slice.u >= 1.0f) slice.u = 0.0f;
	}
	return path;
}

// ---------------------------------------------------------------------------
// What the viewport shows and edits

<*
 The edited clip's paths as they stand on screen: the draft while a drag or a
 drawing has one, the clip's own otherwise. Borrowed until the next edit.
*>
fn AnimPath[] AppState.shown_paths(&self)
{
	if (self.path_draft_active) return self.path_draft;
	AnimTemplate* clip = self.clip(self.editing);
	return clip ? clip.paths : {};
}

<*
 Whether the paths are drawn and can be grabbed: with the rig, on the Pose stage,
 for the clip on show being the one edited.
*>
fn bool AppState.paths_shown(&self)
{
	if (!self.show_rig || self.stage == JOINTS_STAGE || !(self.path_height > 0.0f)) return false;
	// Over the clip as it is on show: posed for editing, or playing.
	if (self.animating ? !self.current_ref.same(self.editing) : !self.pose_edit_active) return false;
	return self.shown_paths().len > 0 || self.path_drawing;
}

// The draft as a fresh copy of the clip's paths, unless one is open already.
fn void AppState.open_path_draft(&self)
{
	if (self.path_draft_active) return;
	AnimTemplate* clip = self.clip(self.editing);
	self.path_draft = clip ? anim_paths_copy(mem, clip.paths) : {};
	self.path_draft_active = true;
}

// The point or slice being dragged, in model units.
fn Vec3 AppState.path_drag_at(&self)
{
	AnimPath[] paths = self.shown_paths();
	if (self.drag.verb != DragVerb.PATH || self.drag.path >= paths.len) return self.drag.from;
	AnimPath* path = &paths[self.drag.path];
	if (self.drag.path_slice)
	{
		if (self.drag.path_handle >= path.slices.len) return self.drag.from;
		return path.at_fraction(path.slices[self.drag.path_handle].u) * self.path_height;
	}
	if (self.drag.path_handle >= path.points.len) return self.drag.from;
	return path.points[self.drag.path_handle].at * self.path_height;
}

<*
 Begin dragging point `handle` of path `path` (or, with `slice`, that slice), on
 a draft the player shows as it changes. The gesture's usual `DragState`, so the
 axis keys, Esc and a click to confirm work as for a joint.
*>
fn bool AppState.begin_path_drag(&self, usz path, usz handle, bool slice, bool held = false)
{
	if (self.drag.dot != 0 || !self.prepare_animation_pose()) return false;
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || path >= clip.paths.len) return false;
	if (slice ? handle >= clip.paths[path].slices.len : handle >= clip.paths[path].points.len) return false;
	self.open_path_draft();
	self.path_selected = (sz)path;
	self.path_point_selected = slice ? -1 : (sz)handle;
	self.path_slice_selected = slice ? (sz)handle : -1;
	self.drag = {
		.dot = AIM_DRAG_DOT,
		.path = path,
		.path_handle = handle,
		.path_slice = slice,
		.axis = DragAxis.FREE,
		.verb = DragVerb.PATH,
		.held = held,
	};
	self.drag.from = self.path_drag_at();
	self.drag.depth = (self.drag.from - self.model_eye(&self.camera)).length();
	return true;
}

// The dragged point moved to `at_model` (model units), shown at once.
fn void AppState.path_point_toward(&self, Vec3 at_model)
{
	if (self.drag.verb != DragVerb.PATH || self.drag.path_slice || !self.path_draft_active) return;
	if (self.drag.path >= self.path_draft.len || !(self.path_height > 0.0f)) return;
	AnimPath* path = &self.path_draft[self.drag.path];
	if (self.drag.path_handle >= path.points.len) return;
	path.points[self.drag.path_handle].at = at_model / self.path_height;
	self.refresh_posed();
}

// The dragged slice moved to `u` along its curve, shown at once.
fn void AppState.path_slice_to(&self, float u)
{
	if (self.drag.verb != DragVerb.PATH || !self.drag.path_slice || !self.path_draft_active) return;
	if (self.drag.path >= self.path_draft.len) return;
	AnimPath* path = &self.path_draft[self.drag.path];
	if (self.drag.path_handle >= path.slices.len) return;
	path.slices[self.drag.path_handle].u = math::clamp(u, 0.0f, 1.0f);
	self.refresh_posed();
}

fn void AppState.cancel_path_drag(&self)
{
	self.drag = {};
	self.drop_path_draft();
	self.refresh_posed();
}

<*
 The release: a path that changed lands as one undo step and is the person's
 from then on (a gait's generated path stops being regenerated); one that ended
 where it began leaves nothing.
*>
fn void AppState.end_path_drag(&self)
{
	usz which = self.drag.path;
	self.drag = {};
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || !self.path_draft_active || which >= self.path_draft.len || which >= clip.paths.len)
	{
		self.drop_path_draft();
		self.refresh_posed();
		return;
	}
	if (paths_same(&clip.paths[which], &self.path_draft[which]))
	{
		self.drop_path_draft();
		self.refresh_posed();
		return;
	}
	// A gait's own path: its stance ends are the stride and the top of its swing
	// the lift, and dragging those writes the whole gait again.
	if (clip.paths[which].generated && clip.gait.set && self.regait_from_handle(which, self.path_draft[which]))
	{
		self.drop_path_draft();
		self.refresh_posed();
		return;
	}
	AnimPath[] next = self.path_draft;
	next[which].generated = false;
	self.path_draft = {};
	self.path_draft_active = false;
	(void)self.land_paths(self.editing, next);
	self.refresh_posed();
}

// The point of a generated foot path that is the top of its swing: the middle of
// the points after the two stance ends.
const usz GAIT_APEX_POINT = 2 + GAIT_SWING_POINTS / 2;

<*
 A gait's generated path whose stance end or swing top was dragged to where
 `moved` has it: the gait written again with that stride or lift, for every foot.
 False for any other point, which makes the path the person's instead.
*>
fn bool AppState.regait_from_handle(&self, usz which, AnimPath moved)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || which >= clip.paths.len || moved.points.len < 2 + GAIT_SWING_POINTS) return false;
	AnimPath* was = &clip.paths[which];
	usz point = self.path_point_selected >= 0 ? (usz)self.path_point_selected : (usz)PATH_POINTS_MOST;
	AnimGaitPreset preset = self.gait_preset_of(self.editing);
	defer preset.free(mem);
	if (point <= 1)
	{
		// The stance runs along the figure's facing (+Z): its length is the stride.
		preset.stride = math::max(math::abs(moved.points[0].at.z - moved.points[1].at.z), 0.01f);
		self.@notice("stride %.0f%% of the figure's height — every foot steps it", preset.stride * 100.0f);
	}
	else if (point == GAIT_APEX_POINT)
	{
		preset.lift = math::max(moved.points[GAIT_APEX_POINT].at.y - was.points[0].at.y, 0.002f);
		self.@notice("lift %.1f%% of the figure's height — every foot clears it", preset.lift * 100.0f);
	}
	else
	{
		return false;
	}
	return self.rerun_gait(self.editing, &preset).valid();
}

fn bool paths_same(AnimPath* a, AnimPath* b) @local
{
	if (a.points.len != b.points.len || a.slices.len != b.slices.len || a.closed != b.closed) return false;
	foreach (usz i, point : a.points) if (point.at != b.points[i].at || point.sharp != b.points[i].sharp) return false;
	foreach (usz i, slice : a.slices) if (slice.u != b.slices[i].u || slice.time != b.slices[i].time) return false;
	return true;
}

// The edited clip's path at `at` as a copy to change and hand to `replace_path`.
fn AnimPath? AppState.path_copy_at(&self, usz at)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || at >= clip.paths.len) return NOT_FOUND~;
	return clip.paths[at].copy(mem);
}

<*
 A point put into the curve `u` of the way along it, where it already runs, so
 nothing moves until it is dragged; the slices keep their places on the curve.
*>
fn bool AppState.insert_path_point(&self, usz at, float u)
{
	AnimPath? found = self.path_copy_at(at);
	if (catch found) return false;
	AnimPath path = found;
	if (path.points.len < 2 || path.points.len >= PATH_POINTS_MOST) { path.free(mem); return false; }
	float[] lengths = path.length_table(tmem);
	float total = lengths[^1];
	Vec3 where = path.at_fraction(u, lengths);
	// The span `u` falls in: the new point goes after its first point.
	usz span = 0;
	for (usz k = 0; k < path.span_count(); k++) if (lengths[k * PATH_STEPS] <= u * total) span = k;
	AnimPathPoint[] grown = alloc::new_array(mem, AnimPathPoint, (sz)(path.points.len + 1));
	usz write;
	foreach (usz i, point : path.points)
	{
		grown[write++] = point;
		if (i == span) grown[write++] = { .at = where };
	}
	// Where each slice was, in space, found again on the new curve.
	Vec3[] placed = alloc::new_array(tmem, Vec3, (sz)path.slices.len);
	foreach (usz i, slice : path.slices) placed[i] = path.at_fraction(slice.u, lengths);
	alloc::free(mem, path.points);
	path.points = grown;
	foreach (usz i, &slice : path.slices) slice.u = path.nearest_fraction(placed[i]);
	path.generated = false;
	self.path_point_selected = (sz)span + 1;
	return self.replace_path(self.editing, at, path);
}

<*
 A slice on path `at`: at `time` the joint is `u` along the curve. A slice already
 at that time moves there instead.
*>
fn bool AppState.add_path_slice(&self, usz at, float u, float time)
{
	AnimPath? found = self.path_copy_at(at);
	if (catch found) return false;
	AnimPath path = found;
	foreach (&slice : path.slices)
	{
		if (math::abs(slice.time - time) >= ANIM_SAME_TIME) continue;
		slice.u = u;
		path.generated = false;
		return self.replace_path(self.editing, at, path);
	}
	AnimPathSlice[] grown = alloc::new_array(mem, AnimPathSlice, (sz)(path.slices.len + 1));
	foreach (usz i, slice : path.slices) grown[i] = slice;
	grown[path.slices.len] = { .time = time, .u = math::clamp(u, 0.0f, 1.0f) };
	if (path.slices.len > 0) alloc::free(mem, path.slices);
	path.slices = grown;
	path.sort_slices();
	path.generated = false;
	return self.replace_path(self.editing, at, path);
}

<*
 Slice `slice` of path `at` moved to `time` seconds, the slices kept in time order
 and the moved one still the picked one. Refused onto another slice's time.
*>
fn bool AppState.retime_path_slice(&self, usz at, usz slice, float time)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || at >= clip.paths.len || slice >= clip.paths[at].slices.len) return false;
	time = math::clamp(time, 0.0f, clip.duration);
	foreach (usz i, other : clip.paths[at].slices)
	{
		if (i == slice || math::abs(other.time - time) >= ANIM_SAME_TIME) continue;
		self.@notice("another slice of this path is at that frame already");
		return false;
	}
	// A gait foot's landing: the foot lands there from now on, and the gait is
	// written again around it.
	AnimPath* foot = &clip.paths[at];
	if (foot.generated && clip.gait.set && foot.slices[slice].tag == DOWN && clip.duration > 0.0f)
	{
		AnimGaitPreset preset = self.gait_preset_of(self.editing);
		defer preset.free(mem);
		foreach (usz i, name : preset.feet)
		{
			if (name != foot.joint || i >= preset.offsets.len) continue;
			preset.offsets[i] = time / clip.duration;
			return self.rerun_gait(self.editing, &preset).valid();
		}
	}
	AnimPath path = clip.paths[at].copy(mem);
	float u = path.slices[slice].u;
	path.slices[slice].time = time;
	path.sort_slices();
	foreach (usz i, moved : path.slices) if (moved.time == time && moved.u == u) self.path_slice_selected = (sz)i;
	path.generated = false;
	self.path_selected = (sz)at;
	return self.replace_path(self.editing, at, path);
}

<*
 Delete what is picked on the selected path: its picked slice, else its picked
 point (a curve keeps two), else the whole path.
*>
fn bool AppState.delete_path_selection(&self)
{
	if (self.path_selected < 0) return false;
	usz at = (usz)self.path_selected;
	AnimPath? found = self.path_copy_at(at);
	if (catch found) return false;
	AnimPath path = found;
	if (self.path_slice_selected >= 0 && (usz)self.path_slice_selected < path.slices.len)
	{
		usz gone = (usz)self.path_slice_selected;
		for (usz i = gone; i + 1 < path.slices.len; i++) path.slices[i] = path.slices[i + 1];
		path.slices = path.slices[:path.slices.len - 1];
		self.path_slice_selected = -1;
		path.generated = false;
		return self.replace_path(self.editing, at, path);
	}
	if (self.path_point_selected >= 0 && (usz)self.path_point_selected < path.points.len && path.points.len > 2)
	{
		usz gone = (usz)self.path_point_selected;
		Vec3[] placed = alloc::new_array(tmem, Vec3, (sz)path.slices.len);
		float[] lengths = path.length_table(tmem);
		foreach (usz i, slice : path.slices) placed[i] = path.at_fraction(slice.u, lengths);
		for (usz i = gone; i + 1 < path.points.len; i++) path.points[i] = path.points[i + 1];
		path.points = path.points[:path.points.len - 1];
		foreach (usz i, &slice : path.slices) slice.u = path.nearest_fraction(placed[i]);
		self.path_point_selected = -1;
		path.generated = false;
		return self.replace_path(self.editing, at, path);
	}
	path.free(mem);
	return self.remove_path(self.editing, at);
}

// The selected path closed into a loop, or opened.
fn bool AppState.toggle_path_closed(&self)
{
	if (self.path_selected < 0) return false;
	AnimPath? found = self.path_copy_at((usz)self.path_selected);
	if (catch found) return false;
	AnimPath path = found;
	path.closed = !path.closed;
	path.generated = false;
	return self.replace_path(self.editing, (usz)self.path_selected, path);
}

// The selected path turning its joint along the curve, or only carrying it.
fn bool AppState.toggle_path_follow(&self)
{
	if (self.path_selected < 0) return false;
	AnimPath? found = self.path_copy_at((usz)self.path_selected);
	if (catch found) return false;
	AnimPath path = found;
	path.follow = !path.follow;
	return self.replace_path(self.editing, (usz)self.path_selected, path);
}

// The selected path muted, or heard again.
fn bool AppState.toggle_path_mute(&self)
{
	if (self.path_selected < 0) return false;
	AnimPath? found = self.path_copy_at((usz)self.path_selected);
	if (catch found) return false;
	AnimPath path = found;
	path.mute = !path.mute;
	return self.replace_path(self.editing, (usz)self.path_selected, path);
}

// ---------------------------------------------------------------------------
// Drawing a new path

<*
 Start drawing a path for `joint`: each `add_drawn_point` is a point of it, shown
 as it grows; `finish_path_drawing` lands it with its slices spread over the clip.
*>
fn bool AppState.begin_path_drawing(&self, String joint)
{
	if (joint.len == 0 || !self.prepare_animation_pose()) return false;
	self.cancel_path_drawing();
	self.open_path_draft();
	AnimPath[] grown = alloc::new_array(mem, AnimPath, (sz)(self.path_draft.len + 1));
	foreach (usz i, path : self.path_draft) grown[i] = path;
	if (self.path_draft.len > 0) alloc::free(mem, self.path_draft);
	grown[^1] = { .joint = joint.copy(mem), .name = string::format(mem, "%s path", joint) };
	self.path_draft = grown;
	self.path_drawing = true;
	self.path_selected = (sz)grown.len - 1;
	self.path_point_selected = -1;
	self.path_slice_selected = -1;
	self.refresh_ui();
	return true;
}

// A point at `at_model` (model units) on the end of the path being drawn.
fn void AppState.add_drawn_point(&self, Vec3 at_model)
{
	if (!self.path_drawing || self.path_draft.len == 0 || !(self.path_height > 0.0f)) return;
	AnimPath* path = &self.path_draft[^1];
	if (path.points.len >= PATH_POINTS_MOST) return;
	AnimPathPoint[] grown = alloc::new_array(mem, AnimPathPoint, (sz)(path.points.len + 1));
	foreach (usz i, point : path.points) grown[i] = point;
	grown[^1] = { .at = at_model / self.path_height };
	if (path.points.len > 0) alloc::free(mem, path.points);
	path.points = grown;
	self.refresh_ui();
}

<*
 Land the path being drawn: a slice on every point, spread evenly over the clip
 in the order they were drawn (a closed path's last runs back into its first), so
 it plays at once and its timing is then the slices' to change. One undo step. A
 path of fewer than two points is dropped.
*>
fn bool AppState.finish_path_drawing(&self)
{
	if (!self.path_drawing) return false;
	self.path_drawing = false;
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || self.path_draft.len == 0 || self.path_draft[^1].points.len < 2)
	{
		self.drop_path_draft();
		self.refresh_posed();
		self.@notice("a path needs two points or more: click where the joint should pass");
		return false;
	}
	AnimPath drawn = self.path_draft[^1].copy(mem);
	self.drop_path_draft();
	drawn.closed = clip.loop && drawn.points.len > 2;
	usz count = drawn.points.len;
	float[] lengths = drawn.length_table(tmem);
	float total = lengths[^1];
	drawn.slices = alloc::new_array(mem, AnimPathSlice, (sz)count);
	usz steps = drawn.closed ? count : count - 1;
	foreach (usz i, &slice : drawn.slices)
	{
		slice.time = clip.duration * (float)i / (float)steps;
		slice.u = total > 1.0e-9f ? lengths[i * PATH_STEPS] / total : 0.0f;
	}
	String joint = drawn.joint.tcopy();
	usz points = count;
	bool landed = self.add_path(self.editing, drawn) >= 0;
	self.refresh_posed();
	if (landed)
	{
		self.@notice("%s follows the path: %d slices over the clip · play to see it · drag points to reshape, slices to retime",
			joint, points);
	}
	return landed;
}

fn void AppState.cancel_path_drawing(&self)
{
	if (!self.path_drawing) return;
	self.path_drawing = false;
	self.drop_path_draft();
	self.refresh_posed();
}

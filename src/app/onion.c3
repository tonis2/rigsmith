<*
 Animation aids drawn over the rig: ghost poses (the clip at frames around the
 playhead, `ghost_step` frames apart, drawn as see-through copies of the mesh by
 engine/scene.c3, or as faint skeletons without one) and the selected joint's
 motion path.

 Both are sampled through `evaluated_clip_pose`, the door the player uses, so a
 ghost is exactly the pose the rig shows when parked on that frame. Both are
 cached: the ghosts by clip, ghost times picked and document revision, the path by
 clip, joint, display fps and revision. A frame that changes none of those reads
 the cache; a frame with the toggles off touches nothing.
*>
module crig;

import rig;
import std::math;

// Ghosts drawn at once, whatever the two sides ask for: each is a posed copy of
// the mesh, and a few dozen of them already read as a smear.
const int MAX_GHOSTS = 60;
// The farthest ghost keeps this share of the nearest one's strength.
const float GHOST_FAR_FADE = 0.2f;
const float GHOST_KEY_EPSILON = 0.0001f;
// A long clip at 60 fps stops here; the path is a picture, not a bake.
const usz MAX_PATH_SAMPLES = 2400;

struct GhostPose
{
	float time;
	bool before; // behind the playhead (warm) or ahead of it (cool)
	int step;    // 1 = the nearest ghost on its side, 2 = the one past it, …
	float fade;  // 1 for the nearest, falling to GHOST_FAR_FADE for the farthest
	PosedDot[] dots;
	Matrix4f[] palette; // the pose as a skin palette, for the mesh ghost
}

// What a cache was built against; any field moving rebuilds it.
struct OnionStamp
{
	AnimRef ref;
	uint revision;
	uint rig_generation;
	usz keys_ptr;
	usz key_count;
	float duration;
}

struct GhostCache
{
	bool built;
	OnionStamp stamp;
	usz count;
	GhostPose[MAX_GHOSTS] poses;
	uint builds; // how many times it was sampled, for the tests
	// The pose edit the ghosts were sampled with folded in (`draft_signature`).
	uint draft;
	// Written by the scene each frame: the ghosts are on screen as meshes, so the
	// viewport leaves the skeleton fallback out.
	bool meshed;
	// The rig's height the spread is a share of, kept until the model changes
	// (a bounds walk over every vertex is not a per-frame cost).
	float height;
	uint height_revision;
	uint height_generation;
	usz height_ptr;
	usz height_len;
	bool height_known;
}

struct MotionPath
{
	bool built;
	OnionStamp stamp;
	uint joint;
	int fps;
	Vec3[] points;
	float[] times;
	Vec3[] key_points;
	float[] key_times;
	uint builds;
}

fn OnionStamp AppState.onion_stamp(&self, AnimRef ref, AnimTemplate* clip)
{
	return {
		.ref = ref,
		.revision = self.undo_stack.revision,
		.rig_generation = self.rig_generation,
		.keys_ptr = (usz)clip.keyframes.ptr,
		.key_count = clip.keyframes.len,
		.duration = clip.duration,
	};
}

fn bool OnionStamp.same(&self, OnionStamp other)
{
	return self.ref.same(other.ref) && self.revision == other.revision
		&& self.rig_generation == other.rig_generation && self.keys_ptr == other.keys_ptr
		&& self.key_count == other.key_count && self.duration == other.duration;
}

// A gesture writes the document before it records, so a cache built mid-drag
// would be rebuilt every frame. Keep the last picture until the release.
fn bool AppState.onion_gesture(&self)
{
	return self.drag.dot != 0 || self.stroke_open;
}

<*
 The pending pose edit as one number: 0 with no edit open, else a hash of the
 draft, the moved targets and the time it will be keyed at. A ghost cache built
 against another number is out of date, whatever the document says.
*>
fn uint AppState.draft_signature(&self)
{
	if (!self.pose_edit_active) return 0;
	uint hash = 2166136261u;
	hash = (hash ^ bitcast(self.edit_time, uint)) * 16777619u;
	foreach (joint : self.pose_edit_draft)
	{
		float[7] parts = { joint.rotation.i, joint.rotation.j, joint.rotation.k, joint.rotation.l,
			joint.offset.x, joint.offset.y, joint.offset.z };
		hash = (hash ^ joint.dot_id) * 16777619u;
		foreach (part : parts) hash = (hash ^ bitcast(part, uint)) * 16777619u;
	}
	foreach (aim : self.aim_draft)
	{
		float[3] parts = { aim.at.x, aim.at.y, aim.at.z };
		foreach (part : parts) hash = (hash ^ bitcast(part, uint)) * 16777619u;
	}
	return hash | 1u;
}

<*
 The open clip as it would play with the pose edit in hand keyed at the playhead
 (what Auto-key, or Key pose on the changed channels, would write): the saved clip
 with the draft folded in as a key. Nothing lands and the undo stack is not
 touched; the caller frees `out`.

 @param out : `Set only when this returns true.`
 @return `False when there is no edit that would key anything, or a layer is open — its key goes into the layer, so the saved clip is what the ghosts sample.`
*>
fn bool AppState.onion_drafted_clip(&self, AnimTemplate* clip, AnimTemplate* out)
{
	if (!self.pose_edit_active || !self.editing.valid()) return false;
	if (self.active_layer_ptr(self.editing) || clip.plays_layers()) return false;
	float time = self.edit_time;
	AnimKeyframe? drafted = self.draft_key(self.editing, clip, time, CHANGED, false);
	if (catch drafted) return false;
	AnimKeyframe key = drafted;
	if (key.dots.len == 0)
	{
		key.free(mem);
		if (self.aim_draft.len == 0) return false;
		*out = self.with_aim_keys(clip_copy(mem, *clip), time);
		return true;
	}
	*out = self.with_aim_keys(clip_with_key(mem, *clip, key), time);
	return true;
}

// The playhead of the open clip: the running clock when it is the clip playing.
fn float AppState.onion_playhead(&self)
{
	return self.animating && self.current_ref.same(self.editing) ? self.anim_time : self.edit_time;
}

fn int AppState.ghost_past_count(&self) => math::clamp(self.config.ghost_past, 0, MAX_GHOST_SIDE);
fn int AppState.ghost_future_count(&self) => math::clamp(self.config.ghost_future, 0, MAX_GHOST_SIDE);
fn int AppState.ghost_step_frames(&self) => math::clamp(self.config.ghost_step, 1, MAX_GHOST_STEP);

// The strongest a ghost gets; a config that never named it reads as the default.
fn float AppState.ghost_strength(&self)
{
	float opacity = self.config.ghost_opacity;
	return opacity >= MIN_GHOST_OPACITY ? math::min(opacity, 1.0f) : DEFAULT_GHOST_OPACITY;
}

// The spread asked for, as a share of the rig's height per ghost.
fn float AppState.ghost_spread(&self)
{
	float spread = self.config.ghost_spread;
	return spread >= 0 && spread <= MAX_GHOST_SPREAD ? spread : DEFAULT_GHOST_SPREAD;
}

fn int AppState.ghost_direction(&self)
{
	int direction = self.config.ghost_direction;
	return direction >= 0 && direction < GHOST_DIRECTIONS ? direction : 0;
}

<*
 The model-space unit vector the ghosts are spread along: 0 forward (+Z, the way
 the rig faces), 1 sideways (+X), 2 up (+Y).
*>
fn Vec3 ghost_axis(int direction)
{
	switch (direction)
	{
		case 1: return { 1, 0, 0 };
		case 2: return { 0, 1, 0 };
		default: return { 0, 0, 1 };
	}
}

<*
 Where a ghost is pushed to, in model space and on top of its real pose: its
 signed index from the playhead (past -1, -2 ..., future +1, +2 ...) times
 `spread` of the rig's `height`, along the direction. Zero spread, zero offset.
*>
fn Vec3 ghost_offset(bool before, int step, float spread, float height, int direction)
{
	float signed_index = before ? -(float)step : (float)step;
	return ghost_axis(direction) * (signed_index * spread * height);
}

<*
 The rig's height, cached against the model: the mesh's extent along Y.
*>
fn float AppState.ghost_rig_height(&self)
{
	GhostCache* cache = &self.ghosts;
	usz ptr = (usz)self.geometry.positions.ptr;
	usz len = self.geometry.positions.len;
	if (!cache.height_known || cache.height_revision != self.undo_stack.revision
		|| cache.height_generation != self.rig_generation || cache.height_ptr != ptr || cache.height_len != len)
	{
		cache.height = self.model_height();
		cache.height_revision = self.undo_stack.revision;
		cache.height_generation = self.rig_generation;
		cache.height_ptr = ptr;
		cache.height_len = len;
		cache.height_known = true;
	}
	return cache.height;
}

// Where a pose's ghost sits relative to the live pose, in model space.
fn Vec3 AppState.ghost_offset_of(&self, GhostPose* ghost)
{
	float spread = self.ghost_spread();
	if (spread <= 0) return {};
	return ghost_offset(ghost.before, ghost.step, spread, self.ghost_rig_height(), self.ghost_direction());
}

// Frames per second the ghosts are spaced at: the dock's display rate.
fn int AppState.ghost_fps(&self) => self.anim_fps > 0 ? self.anim_fps : 30;

// Seconds between two neighbouring ghosts.
fn float AppState.ghost_spacing(&self) => (float)self.ghost_step_frames() / (float)self.ghost_fps();

// How far the ghosts reach either side of the playhead, in seconds. What the
// timeline shades.
fn float AppState.ghost_past_span(&self) => (float)self.ghost_past_count() * self.ghost_spacing();
fn float AppState.ghost_future_span(&self) => (float)self.ghost_future_count() * self.ghost_spacing();

<*
 Both sides trimmed to what MAX_GHOSTS allows, the larger side giving way first.
*>
fn void ghost_counts(int past, int future, int* out_past, int* out_future)
{
	while (past + future > MAX_GHOSTS)
	{
		if (past >= future) { past--; } else { future--; }
	}
	*out_past = past;
	*out_future = future;
}

// How strongly ghost number `step` of `side` shows against the nearest: 1 for
// the first, GHOST_FAR_FADE for the last.
fn float ghost_fade(int step, int side)
{
	if (side <= 1) return 1.0f;
	return 1.0f - (1.0f - GHOST_FAR_FADE) * (float)(step - 1) / (float)(side - 1);
}

// The open clip, read in if it was a deferred stub, or null.
fn AnimTemplate* AppState.onion_clip(&self)
{
	if (!self.editing.valid()) return null;
	AnimTemplate* clip = self.clip(self.editing);
	if (clip && clip.lazy)
	{
		if (!self.ensure_clip_imported(self.editing)) return null;
		clip = self.clip(self.editing);
	}
	return clip;
}

// A rig view to sample through: the player's cached one when it is still
// valid (`owned` false, not to be freed), else a fresh one the caller frees.
fn RigView? AppState.onion_view(&self, bool* owned)
{
	*owned = false;
	if (self.playback_rig_fresh()) return self.playback_rig;
	RigView view = self.open_rig(mem)!;
	*owned = true;
	return view;
}

// The clip's pose at `time` as a palette. The caller owns it; empty on a mismatch.
fn Matrix4f[] AppState.onion_palette(&self, RigView* view, AnimTemplate* clip, float time)
{
	rig::Pose pose = self.evaluated_clip_pose(mem, view, *clip, self.editing, time, aimed: true);
	defer pose.free(mem);
	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette) return {};
	return palette;
}

<*
 The times ghosts stand at: `past` of them behind `playhead` at `step` frames
 apart, then `future` ahead of it, each side nearest first. A time outside the
 clip is skipped, or wrapped round to the other end when the clip loops. A
 wrapped time that lands back on the playhead or on a ghost already placed is
 dropped, so a short looping clip is not drawn over itself.

 @param fps : `Frame rate that turns a step into seconds.`
 @return `How many were written; times, before and steps hold at least MAX_GHOSTS.`
*>
fn usz ghost_times(float duration, bool loop, float playhead, int fps, int past, int future, int step,
	float[] times, bool[] before, int[] steps, float[] fades = {})
{
	usz count;
	if (duration <= 0.0f || fps <= 0) return 0;
	ghost_counts(past, future, &past, &future);
	int side_past = past;
	int side_future = future;
	float spacing = (float)math::max(step, 1) / (float)fps;
	for (int pass = 0; pass < 2; pass++)
	{
		bool behind = pass == 0;
		int total = behind ? side_past : side_future;
		for (int k = 1; k <= total; k++)
		{
			float time = playhead + (behind ? -1.0f : 1.0f) * (float)k * spacing;
			if (time < -GHOST_KEY_EPSILON || time > duration + GHOST_KEY_EPSILON)
			{
				if (!loop) break;
				time -= math::floor(time / duration) * duration;
			}
			time = math::clamp(time, 0.0f, duration);
			bool taken = math::abs(time - playhead) < GHOST_KEY_EPSILON;
			for (usz i = 0; !taken && i < count; i++) taken = math::abs(times[i] - time) < GHOST_KEY_EPSILON;
			if (taken) continue;
			times[count] = time; before[count] = behind; steps[count] = k;
			if (fades.len > count) fades[count] = ghost_fade(k, total);
			count++;
		}
	}
	return count;
}

fn void AppState.drop_ghosts(&self)
{
	for (usz i = 0; i < self.ghosts.count; i++)
	{
		if (self.ghosts.poses[i].dots.len > 0) alloc::free(mem, self.ghosts.poses[i].dots);
		if (self.ghosts.poses[i].palette.len > 0) alloc::free(mem, self.ghosts.poses[i].palette);
		self.ghosts.poses[i] = {};
	}
	self.ghosts.count = 0;
	self.ghosts.built = false;
}

<*
 The ghost poses to draw this frame, or none: Ghosts off, no clip open, or the
 clip running (the ghosts would flicker past every frame).
*>
fn GhostPose[] AppState.ghost_poses(&self)
{
	if (!self.config.show_ghosts || self.doc.dots.len() == 0) return {};
	if (self.animating && !self.anim_paused) return {};
	AnimTemplate* clip = self.onion_clip();
	if (!clip || clip.keyframes.len == 0) return {};

	float[MAX_GHOSTS] times;
	bool[MAX_GHOSTS] before;
	int[MAX_GHOSTS] steps;
	float[MAX_GHOSTS] fades;
	usz count = ghost_times(clip.duration, clip.loop, self.onion_playhead(), self.ghost_fps(),
		self.ghost_past_count(), self.ghost_future_count(), self.ghost_step_frames(),
		times[..], before[..], steps[..], fades[..]);

	OnionStamp stamp = self.onion_stamp(self.editing, clip);
	uint draft = self.draft_signature();
	bool gesture = self.onion_gesture();
	bool same = self.ghosts.built && self.ghosts.count == count;
	// Held through a drag: re-sampling every ghost mid-gesture costs far more than
	// the drag itself, so they catch up with the draft on the release.
	if (same && !gesture)
	{
		same = self.ghosts.stamp.same(stamp) && self.ghosts.draft == draft;
	}
	for (usz i = 0; same && i < count; i++)
	{
		GhostPose* held = &self.ghosts.poses[i];
		same = held.time == times[i] && held.before == before[i] && held.step == steps[i] && held.fade == fades[i];
	}
	if (same) return self.ghosts.poses[:self.ghosts.count];

	self.drop_ghosts();
	self.ghosts.builds++;
	// The clip as it will play once the edit in hand is keyed, so the ghosts
	// show what Auto-key (or Key pose) is about to make of it.
	AnimTemplate drafted;
	bool folded = self.onion_drafted_clip(clip, &drafted);
	defer if (folded) drafted.free(mem);
	AnimTemplate* sampled = folded ? &drafted : clip;
	bool owned;
	RigView? opened = self.onion_view(&owned);
	if (try view = opened)
	{
		for (usz i = 0; i < count; i++)
		{
			Matrix4f[] palette = self.onion_palette(&view, sampled, times[i]);
			self.ghosts.poses[i] = {
				.time = times[i], .before = before[i], .step = steps[i], .fade = fades[i],
				.dots = posed_overlay(mem, &view.skeleton, view.dot_ids, palette),
				.palette = palette,
			};
		}
		self.ghosts.count = count;
		if (owned) view.free(mem);
	}
	self.ghosts.stamp = stamp;
	self.ghosts.draft = draft;
	self.ghosts.built = true;
	return self.ghosts.poses[:self.ghosts.count];
}

fn void AppState.drop_motion_path(&self)
{
	if (self.motion_path.points.len > 0) alloc::free(mem, self.motion_path.points);
	if (self.motion_path.times.len > 0) alloc::free(mem, self.motion_path.times);
	if (self.motion_path.key_points.len > 0) alloc::free(mem, self.motion_path.key_points);
	if (self.motion_path.key_times.len > 0) alloc::free(mem, self.motion_path.key_times);
	uint builds = self.motion_path.builds;
	self.motion_path = { .builds = builds };
}

fn void AppState.drop_onion(&self)
{
	self.drop_ghosts();
	self.drop_motion_path();
}

<*
 The selected joint's path through the open clip, sampled at the display fps,
 with its positions at each key time. Null when Path is off, nothing is
 selected or no clip is open.
*>
fn MotionPath* AppState.selected_motion_path(&self)
{
	if (!self.config.show_motion_path || self.selected == 0 || !self.doc.find(self.selected)) return null;
	AnimTemplate* clip = self.onion_clip();
	if (!clip || clip.keyframes.len == 0 || clip.duration <= 0.0f) return null;

	int fps = self.anim_fps > 0 ? self.anim_fps : 30;
	OnionStamp stamp = self.onion_stamp(self.editing, clip);
	MotionPath* path = &self.motion_path;
	if (path.built && path.joint == self.selected && path.fps == fps && path.stamp.ref.same(self.editing)
		&& (self.onion_gesture() || path.stamp.same(stamp)))
	{
		return path.points.len > 0 ? path : null;
	}

	self.drop_motion_path();
	path.builds++;
	path.built = true;
	path.stamp = stamp;
	path.joint = self.selected;
	path.fps = fps;

	usz samples = math::min((usz)math::ceil(clip.duration * (float)fps) + 1, MAX_PATH_SAMPLES);
	float[] key_times = distinct_key_times(clip);
	defer if (key_times.len > 0) alloc::free(mem, key_times);

	bool owned;
	RigView? opened = self.onion_view(&owned);
	if (catch opened) return null;
	RigView view = opened;
	defer if (owned) view.free(mem);

	sz joint = -1;
	foreach (usz i, id : view.dot_ids[:view.skeleton.len()])
	{
		if (id == self.selected) { joint = (sz)i; break; }
	}
	if (joint < 0) return null;

	path.points = alloc::new_array(mem, Vec3, (sz)samples);
	path.times = alloc::new_array(mem, float, (sz)samples);
	for (usz i = 0; i < samples; i++)
	{
		float t = math::min((float)i / (float)fps, clip.duration);
		path.times[i] = t;
		path.points[i] = self.onion_joint_at(&view, clip, (usz)joint, t);
	}
	if (key_times.len > 0)
	{
		path.key_times = alloc::new_array(mem, float, (sz)key_times.len);
		path.key_points = alloc::new_array(mem, Vec3, (sz)key_times.len);
		foreach (usz i, t : key_times)
		{
			path.key_times[i] = t;
			path.key_points[i] = self.onion_joint_at(&view, clip, (usz)joint, t);
		}
	}
	return path.points.len > 0 ? path : null;
}

fn Vec3 AppState.onion_joint_at(&self, RigView* view, AnimTemplate* clip, usz joint, float time)
{
	Matrix4f[] palette = self.onion_palette(view, clip, time);
	if (palette.len <= joint) return view.skeleton.joints[joint];
	defer alloc::free(mem, palette);
	return view.skeleton.joints[joint].transform(palette[joint]);
}

// The clip's key times, ascending, each once. The caller owns the array.
fn float[] distinct_key_times(AnimTemplate* clip)
{
	if (clip.keyframes.len == 0) return {};
	float[] times = alloc::new_array(mem, float, (sz)clip.keyframes.len);
	usz count;
	foreach (key : clip.keyframes)
	{
		bool seen;
		for (usz i = 0; i < count; i++)
		{
			if (math::abs(times[i] - key.time) <= GHOST_KEY_EPSILON) { seen = true; break; }
		}
		if (seen) continue;
		usz at = count;
		while (at > 0 && times[at - 1] > key.time) { times[at] = times[at - 1]; at--; }
		times[at] = key.time;
		count++;
	}
	return times[:count];
}

// Where the path puts the joint at `time`, between the two samples around it.
fn Vec3 MotionPath.at(&self, float time)
{
	usz n = self.points.len;
	if (n == 0) return {};
	if (time <= self.times[0]) return self.points[0];
	for (usz i = 1; i < n; i++)
	{
		if (time > self.times[i]) continue;
		float span = self.times[i] - self.times[i - 1];
		float f = span > 0.0f ? (time - self.times[i - 1]) / span : 1.0f;
		return self.points[i - 1] + (self.points[i] - self.points[i - 1]) * f;
	}
	return self.points[n - 1];
}

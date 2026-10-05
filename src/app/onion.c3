<*
 Animation aids drawn over the rig: ghost poses (the keys either side of the
 playhead as faint skeletons) and the selected joint's motion path.

 Both are sampled through `evaluated_clip_pose`, the door the player uses, so a
 ghost is exactly the pose the rig shows when parked on that key. Both are
 cached: the ghosts by clip, key times picked and document revision, the path by
 clip, joint, display fps and revision. A frame that changes none of those reads
 the cache; a frame with the toggles off touches nothing.
*>
module crig;

import rig;
import std::math;

const int MAX_GHOST_KEYS = 3;
const int MAX_GHOSTS = MAX_GHOST_KEYS * 2;
const float GHOST_KEY_EPSILON = 0.0001f;
// A long clip at 60 fps stops here; the path is a picture, not a bake.
const usz MAX_PATH_SAMPLES = 2400;

struct GhostPose
{
	float time;
	bool before; // a key behind the playhead (drawn cool) or ahead of it (warm)
	int step;    // 1 = the nearest key on its side, 2 = the one past it, …
	PosedDot[] dots;
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

// The playhead of the open clip: the running clock when it is the clip playing.
fn float AppState.onion_playhead(&self)
{
	return self.animating && self.current_ref.same(self.editing) ? self.anim_time : self.edit_time;
}

fn int AppState.ghost_range(&self)
{
	int keys = self.config.ghost_keys;
	return keys >= 1 && keys <= MAX_GHOST_KEYS ? keys : 1;
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
 The ghost key times for `playhead`: up to `range` keys strictly before it,
 nearest first, then up to `range` strictly after it. A key under the playhead
 is the pose on screen and gets no ghost.
*>
fn usz ghost_times(AnimTemplate* clip, float playhead, int range, float[] times, bool[] before, int[] steps)
{
	usz count;
	float bound = playhead - GHOST_KEY_EPSILON;
	for (int step = 1; step <= range; step++)
	{
		bool found;
		float best;
		foreach (key : clip.keyframes)
		{
			if (key.time < bound && (!found || key.time > best)) { best = key.time; found = true; }
		}
		if (!found) break;
		times[count] = best; before[count] = true; steps[count] = step; count++;
		bound = best - GHOST_KEY_EPSILON;
	}
	bound = playhead + GHOST_KEY_EPSILON;
	for (int step = 1; step <= range; step++)
	{
		bool found;
		float best;
		foreach (key : clip.keyframes)
		{
			if (key.time > bound && (!found || key.time < best)) { best = key.time; found = true; }
		}
		if (!found) break;
		times[count] = best; before[count] = false; steps[count] = step; count++;
		bound = best + GHOST_KEY_EPSILON;
	}
	return count;
}

fn void AppState.drop_ghosts(&self)
{
	for (usz i = 0; i < self.ghosts.count; i++)
	{
		if (self.ghosts.poses[i].dots.len > 0) alloc::free(mem, self.ghosts.poses[i].dots);
		self.ghosts.poses[i] = {};
	}
	self.ghosts.count = 0;
	self.ghosts.built = false;
}

<*
 The ghost skeletons to draw this frame, or none: Ghosts off, no clip open, or
 the clip running (the ghosts would flicker past every key).
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
	usz count = ghost_times(clip, self.onion_playhead(), self.ghost_range(), times[..], before[..], steps[..]);

	OnionStamp stamp = self.onion_stamp(self.editing, clip);
	bool same = self.ghosts.built && self.ghosts.count == count;
	if (same && !self.onion_gesture()) same = self.ghosts.stamp.same(stamp);
	for (usz i = 0; same && i < count; i++)
	{
		GhostPose* held = &self.ghosts.poses[i];
		same = held.time == times[i] && held.before == before[i] && held.step == steps[i];
	}
	if (same) return self.ghosts.poses[:self.ghosts.count];

	self.drop_ghosts();
	self.ghosts.builds++;
	bool owned;
	RigView? opened = self.onion_view(&owned);
	if (try view = opened)
	{
		for (usz i = 0; i < count; i++)
		{
			Matrix4f[] palette = self.onion_palette(&view, clip, times[i]);
			self.ghosts.poses[i] = {
				.time = times[i], .before = before[i], .step = steps[i],
				.dots = posed_overlay(mem, &view.skeleton, view.dot_ids, palette),
			};
			if (palette.len > 0) alloc::free(mem, palette);
		}
		self.ghosts.count = count;
		if (owned) view.free(mem);
	}
	self.ghosts.stamp = stamp;
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

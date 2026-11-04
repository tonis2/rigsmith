<* The pure half of src/app/onion.c3: no state, undo or notices. *>
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

fn bool OnionStamp.same(&self, OnionStamp other)
{
	return self.ref.same(other.ref) && self.revision == other.revision
		&& self.rig_generation == other.rig_generation && self.keys_ptr == other.keys_ptr
		&& self.key_count == other.key_count && self.duration == other.duration;
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

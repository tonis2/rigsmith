<* The pure half of src/mcp/targets.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// The most effectors one call places. A seconds-per-call limit like render's — each
// is a full CCD solve — and past the count of limbs a figure has anyway.
const usz TARGETS_MOST = 16;

// One target, read against the starting pose, then solved into the shared pose.
struct TargetSpec
{
	String name;
	uint dot_id;
	Vec3 target;
	Quaternionf orient;
	bool has_orient;
	Vec3 pole;
	bool has_pole;
	bool poled;   // set true when the pole actually turned the bend
	PoleAim pole_result;   // why, when it did not
	bool has_run;
	usz effector;
	float[] path_times;   // bake only: the keyed path, in time order; empty for a fixed point
	Vec3[] path_points;
	float worst_gap;      // bake only: the farthest the joint fell from its point at any instant
}

// Why a pole did not turn the bend, or an empty string when it did (or was
// clamped, which `pole_aimed` already carries). The words a caller reads to know
// its pole was ignored rather than obeyed.
fn String pole_note(PoleAim result)
{
	switch (result)
	{
		case AIMED: return "";
		case AIMED_TO_LIMIT:
			return "aimed as far as the root joint's rotation limits allow, which may leave the bend short of the pole";
		case NO_BEND:
			return "this limb has fewer than two bends, so it has no elbow or knee to aim — the pole was ignored";
		case COINCIDENT:
			return "the effector has folded back onto the chain root, leaving no line to swing the bend about — the pole was ignored";
		case STRAIGHT:
			return "the limb reaches the target straight, so its bend already lies on the root-to-effector line — the pole was ignored";
		case POLE_ON_LINE:
			return "the pole lies on the line from the chain root to the effector, so it names no side to bend toward — the pole was ignored";
	}
}

// Key `i` of a path, which for a looping one runs round: the keys repeat a
// duration apart, so a neighbour of the last is the first of the next lap.
fn Vec3 path_key(TargetSpec* spec, usz keys, float duration, bool loop, sz i, float* time) @local
{
	if (!loop)
	{
		sz at = math::clamp(i, (sz)0, (sz)keys - 1);
		*time = spec.path_times[(usz)at];
		return spec.path_points[(usz)at];
	}
	sz n = (sz)keys;
	sz at = ((i % n) + n) % n;
	*time = spec.path_times[(usz)at] + (float)((i - at) / n) * duration;
	return spec.path_points[(usz)at];
}

<*
 Where a keyed path has the joint at `time`.

 A path holds its first point before its first key and its last after its last, or
 — when the clip loops — runs round from the last key to the first of the next lap,
 so a cycle that restates its opening point at the duration closes without a
 kink. Linear goes straight between keys; smooth is a Catmull-Rom curve through
 every one of them.
*>
fn Vec3 path_at(TargetSpec* spec, float time, float duration, bool loop, bool smooth)
{
	usz n = spec.path_times.len;
	if (n == 0) return spec.target;
	if (n == 1) return spec.path_points[0];

	// A closing key that restates the opening point at the duration is the loop
	// point itself, not a second key there.
	usz keys = n;
	if (loop && spec.path_times[n - 1] >= spec.path_times[0] + duration - 1.0e-5f) keys = n - 1;
	if (keys < 2) return spec.path_points[0];

	float t = time;
	float from;
	float to;
	path_key(spec, keys, duration, loop, 0, &from);
	if (loop)
	{
		if (t < from) t += duration;
		while (t >= from + duration) t -= duration;
	}
	else
	{
		float last;
		path_key(spec, keys, duration, loop, (sz)keys - 1, &last);
		if (t <= from) return spec.path_points[0];
		if (t >= last) return spec.path_points[keys - 1];
	}

	sz seg = 0;
	sz segments = loop ? (sz)keys : (sz)keys - 1;
	for (sz i = 0; i < segments; i++)
	{
		path_key(spec, keys, duration, loop, i + 1, &to);
		if (t < to || i == segments - 1)
		{
			seg = i;
			break;
		}
	}
	float t0;
	float t1;
	Vec3 p1 = path_key(spec, keys, duration, loop, seg, &t0);
	Vec3 p2 = path_key(spec, keys, duration, loop, seg + 1, &t1);
	float s = t1 - t0 > 1.0e-9f ? math::clamp((t - t0) / (t1 - t0), 0.0f, 1.0f) : 0.0f;
	if (!smooth) return p1 + (p2 - p1) * s;

	float ignored;
	Vec3 p0 = path_key(spec, keys, duration, loop, seg - 1, &ignored);
	Vec3 p3 = path_key(spec, keys, duration, loop, seg + 2, &ignored);
	return 0.5f * ((p1 * 2.0f) + (p2 - p0) * s
		+ (p0 * 2.0f - p1 * 5.0f + p2 * 4.0f - p3) * (s * s)
		+ (p1 * 3.0f - p0 - p2 * 3.0f + p3) * (s * s * s));
}

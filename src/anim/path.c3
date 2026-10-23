<*
 Motion paths: a curve a joint follows, with slices saying where on it the joint
 is when.

 An `AnimPath` belongs to a clip, beside its pins. It names one joint (a hand, a
 foot, a tail's tip), a curve through `points` in the model's space, and
 `slices`: each says that at `time` the joint is `u` of the way along the curve
 (by length, 0 at the first point, 1 at the last or, on a closed curve, back at
 the first). Between two slices the joint runs along the curve at a steady
 speed; before the first and after the last it waits, unless the clip loops and
 the curve closes, when the last slice runs on into the first.

 **Applied live, as the pins are.** At every instant each path is turned into a
 position pin on its joint at the curve's point for that instant
 (`clip_live_pins`), and `pin_pose` solves them with the clip's own pins: after
 the limits and the floor, before the aims, the limb bending to put the joint
 on the curve and the body lowered when the curve is out of reach. The keys are
 untouched; muting the path gives the authored motion back, and an export bakes
 it as it bakes the pins.

 **The curve.** It runs through every point, a Catmull-Rom spline whose tangents
 are weighted by the lengths either side so a short span does not overshoot. A
 `sharp` point has no tangent at all, so two sharp points in a row are joined by
 a straight line — the stance of a foot on the floor.

 **Gaits are paths.** A walk lays one closed path per foot (anim/gait.c3
 `gait_foot_paths`): the stance a straight line on the floor between two sharp
 points, the swing a lifted arc, a slice where the foot comes down (`DOWN`) and
 where it lifts (`UP`) and more through the swing to give it its timing. Those
 are `generated`; one edited by hand is the person's, and a re-run of the gait
 leaves it alone.

 **Following the curve.** A path that `follow`s turns its joint as well: the
 joint keeps the world orientation its keys give it, turned by however much the
 curve has turned since its start (`AnimPath.turn_at`), so a hand swept along an
 arc or a tail's tip along a swish faces the way it goes and keeps the angle it
 was keyed at to the curve.

 Positions are fractions of the rig's height, like the pins', so a clip holds the
 same curve on a rig in metres or in centimetres.
*>
module crig;

import rig;
import std::math;
import std::sort;
import std::math::vector;
import std::math::quaternion;
import std::collections::object;

enum AnimSliceTag : char
{
	NONE,
	DOWN, // a foot comes down here: its stance starts
	UP,   // a foot lifts here: its stance ends
}

struct AnimPathPoint
{
	Vec3 at; // model space, fraction of rig height
	bool sharp;
}

struct AnimPathSlice
{
	float time; // seconds into the clip
	float u;    // how far along the curve, by length: 0..1
	AnimSliceTag tag;
}

<*
 One path. `joint` and `name` are owned by the clip's allocator, as are the two
 arrays; see `AnimPath.free`.
*>
struct AnimPath
{
	String joint;
	String name;
	AnimPathPoint[] points;
	bool closed;
	AnimPathSlice[] slices; // sorted by time
	// When it holds: `from`..`to` seconds, eased over `blend`; `to <= from` is the
	// whole clip.
	float from;
	float to;
	float blend;
	bool mute;
	bool follow;    // the joint turns as the curve turns
	bool generated; // laid by a gait and not edited since
}

fn void AnimPath.free(&self, Allocator allocator)
{
	if (self.joint.len > 0) alloc::free(allocator, self.joint.ptr);
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	if (self.points.len > 0) alloc::free(allocator, self.points);
	if (self.slices.len > 0) alloc::free(allocator, self.slices);
	*self = {};
}

fn void free_anim_paths(Allocator allocator, AnimPath[] paths)
{
	foreach (&path : paths) path.free(allocator);
	if (paths.len > 0) alloc::free(allocator, paths);
}

<*
 A deep copy with its times mapped `t' = t * scale + shift`, how a retime and a
 crop carry the slices and the window.
*>
fn AnimPath AnimPath.copy(&self, Allocator allocator, float scale = 1.0f, float shift = 0.0f)
{
	AnimPath out = *self;
	out.joint = self.joint.len > 0 ? self.joint.copy(allocator) : "";
	out.name = self.name.len > 0 ? self.name.copy(allocator) : "";
	out.points = alloc::new_array(allocator, AnimPathPoint, (sz)self.points.len);
	foreach (usz i, point : self.points) out.points[i] = point;
	out.slices = alloc::new_array(allocator, AnimPathSlice, (sz)self.slices.len);
	foreach (usz i, slice : self.slices)
	{
		out.slices[i] = slice;
		out.slices[i].time = slice.time * scale + shift;
	}
	if (self.to > self.from)
	{
		out.from = self.from * scale + shift;
		out.to = self.to * scale + shift;
	}
	out.blend = self.blend * scale;
	return out;
}

fn AnimPath[] anim_paths_copy(Allocator allocator, AnimPath[] source, float scale = 1.0f, float shift = 0.0f)
{
	AnimPath[] out = alloc::new_array(allocator, AnimPath, (sz)source.len);
	foreach (usz i, &path : source) out[i] = path.copy(allocator, scale, shift);
	return out;
}

<*
 A deep copy with `start..end` cut out of the clip's time: later slices move up
 by its length, slices inside it land on `start`.
*>
fn AnimPath[] anim_paths_cut(Allocator allocator, AnimPath[] source, float start, float end)
{
	AnimPath[] out = anim_paths_copy(allocator, source);
	float removed = end - start;
	foreach (&path : out)
	{
		foreach (&slice : path.slices) slice.time = slice.time >= end ? slice.time - removed : math::min(slice.time, start);
		if (path.to > path.from)
		{
			path.from = path.from >= end ? path.from - removed : math::min(path.from, start);
			path.to = path.to >= end ? path.to - removed : math::min(path.to, start);
		}
	}
	return out;
}

<*
 Every path reflected across the symmetry plane: its joint goes to its twin and
 every point's x is negated.
*>
fn AnimPath[] anim_paths_mirrored(Allocator allocator, AnimPath[] source)
{
	AnimPath[] out = anim_paths_copy(allocator, source);
	foreach (&path : out)
	{
		path.joint = twin_or_same(allocator, path.joint);
		foreach (&point : path.points) point.at.x = -point.at.x;
	}
	return out;
}

// The paths that still name a joint, in place, as a retarget leaves them.
fn AnimPath[] anim_paths_named(Allocator allocator, AnimPath[] paths)
{
	usz kept;
	foreach (&path : paths)
	{
		if (path.joint.len > 0) { paths[kept++] = *path; continue; }
		path.free(allocator);
	}
	if (kept > 0 || paths.len == 0) return paths[:kept];
	alloc::free(allocator, paths);
	return {};
}

// The clip with its paths replaced by `next`, which is taken over.
fn AnimTemplate clip_with_paths(Allocator allocator, AnimTemplate source, AnimPath[] next)
{
	AnimTemplate clip = clip_copy(allocator, source);
	free_anim_paths(allocator, clip.paths);
	clip.paths = next;
	return clip;
}

// Put the slices in time order, in place.
fn void AnimPath.sort_slices(&self)
{
	for (usz i = 1; i < self.slices.len; i++)
	{
		AnimPathSlice held = self.slices[i];
		usz j = i;
		while (j > 0 && self.slices[j - 1].time > held.time)
		{
			self.slices[j] = self.slices[j - 1];
			j--;
		}
		self.slices[j] = held;
	}
}

// ---------------------------------------------------------------------------
// The curve

// Steps each span is measured in for the length table.
const usz PATH_STEPS = 16;
// The most points a curve may have.
const usz PATH_POINTS_MOST = 256;

fn usz AnimPath.span_count(&self)
{
	if (self.points.len < 2) return 0;
	return self.closed ? self.points.len : self.points.len - 1;
}

fn Vec3 AnimPath.point(&self, sz i)
{
	sz count = (sz)self.points.len;
	if (self.closed) return self.points[(usz)(((i % count) + count) % count)].at;
	return self.points[(usz)math::clamp(i, (sz)0, count - 1)].at;
}

fn bool AnimPath.point_sharp(&self, sz i)
{
	sz count = (sz)self.points.len;
	if (self.closed) return self.points[(usz)(((i % count) + count) % count)].sharp;
	// An open curve's two ends have one neighbour, so they leave along it.
	return self.points[(usz)math::clamp(i, (sz)0, count - 1)].sharp;
}

<*
 The tangent at point `i`, scaled for the span from it toward `toward` (+1 the
 next point, -1 the one before): the chord through its neighbours, weighted by
 how long that span is against the two together. Zero at a sharp point.
*>
fn Vec3 AnimPath.tangent(&self, sz i, float span)
{
	if (self.point_sharp(i)) return {};
	sz count = (sz)self.points.len;
	bool first = !self.closed && i <= 0;
	bool last = !self.closed && i >= count - 1;
	Vec3 before = first ? self.point(i) : self.point(i - 1);
	Vec3 after = last ? self.point(i) : self.point(i + 1);
	float back = (self.point(i) - before).length();
	float ahead = (after - self.point(i)).length();
	float both = back + ahead;
	if (both < 1.0e-9f) return {};
	return (after - before) * (span / both);
}

<*
 The point `s` (0..1) through span `k`, from point k to point k+1: a cubic
 Hermite between them with the weighted tangents.
*>
fn Vec3 AnimPath.on_span(&self, usz k, float s)
{
	Vec3 p0 = self.point((sz)k);
	Vec3 p1 = self.point((sz)k + 1);
	float span = (p1 - p0).length();
	Vec3 m0 = self.tangent((sz)k, span);
	Vec3 m1 = self.tangent((sz)k + 1, span);
	float s2 = s * s;
	float s3 = s2 * s;
	return p0 * (2.0f * s3 - 3.0f * s2 + 1.0f) + m0 * (s3 - 2.0f * s2 + s)
		+ p1 * (-2.0f * s3 + 3.0f * s2) + m1 * (s3 - s2);
}

<*
 The curve's length so far at each of its steps, `PATH_STEPS` per span plus the
 start: `table[0]` is 0 and the last entry is the whole length. The caller owns it.
*>
fn float[] AnimPath.length_table(&self, Allocator allocator)
{
	usz spans = self.span_count();
	float[] table = alloc::new_array(allocator, float, (sz)(spans * PATH_STEPS + 1));
	Vec3 last = self.points.len > 0 ? self.points[0].at : (Vec3){};
	float run = 0.0f;
	for (usz k = 0; k < spans; k++)
	{
		for (usz step = 1; step <= PATH_STEPS; step++)
		{
			Vec3 at = self.on_span(k, (float)step / (float)PATH_STEPS);
			run += (at - last).length();
			last = at;
			table[k * PATH_STEPS + step] = run;
		}
	}
	return table;
}

<*
 The point `u` of the way along the curve by length, 0 to 1 (wrapped on a closed
 curve, held at the ends of an open one).
*>
fn Vec3 AnimPath.at_fraction(&self, float u, float[] table = {})
{
	if (self.points.len == 0) return {};
	if (self.points.len == 1) return self.points[0].at;
	if (self.closed) u -= math::floor(u);
	u = math::clamp(u, 0.0f, 1.0f);
	float[] lengths = table.len > 0 ? table : self.length_table(tmem);
	float total = lengths[^1];
	if (!(total > 1.0e-9f)) return self.points[0].at;
	float want = u * total;
	// The step the length falls in, by bisection.
	usz lo = 0;
	usz hi = lengths.len - 1;
	while (hi - lo > 1)
	{
		usz mid = (lo + hi) / 2;
		if (lengths[mid] < want) { lo = mid; } else { hi = mid; }
	}
	float piece = lengths[hi] - lengths[lo];
	float t = piece > 1.0e-12f ? (want - lengths[lo]) / piece : 0.0f;
	// Along the chord between the two steps, which is what the table measured:
	// exact on a straight run, and a sixteenth of a span from the curve elsewhere.
	return self.at_step(lo) + (self.at_step(hi) - self.at_step(lo)) * t;
}

// The curve's point at step `i` of its length table.
fn Vec3 AnimPath.at_step(&self, usz i)
{
	usz k = i / PATH_STEPS;
	if (k >= self.span_count()) return self.on_span(self.span_count() - 1, 1.0f);
	return self.on_span(k, (float)(i % PATH_STEPS) / (float)PATH_STEPS);
}

<*
 How far along the curve, 0 to 1, the point nearest `at` is — where a slice
 dropped there sits. Searched over the length table's steps and refined within
 the nearest one.
*>
fn float AnimPath.nearest_fraction(&self, Vec3 at)
{
	if (self.points.len < 2) return 0.0f;
	float[] lengths = self.length_table(tmem);
	float total = lengths[^1];
	if (!(total > 1.0e-9f)) return 0.0f;
	float best = 1.0e30f;
	float found = 0.0f;
	usz steps = lengths.len;
	for (usz i = 0; i < steps * 4; i++)
	{
		float u = (float)i / (float)(steps * 4 - 1);
		float d = (self.at_fraction(u, lengths) - at).length_sq();
		if (d < best) { best = d; found = u; }
	}
	return self.closed && found >= 1.0f ? 0.0f : found;
}

<*
 The turn the curve has made from its start to `u` (0..1 by length): the least
 rotation carrying the start's direction along the curve, step by step, to the
 direction at `u`, so the curve's own twist about itself is never added. On a
 closed curve whatever twist that gathers by the time it comes round is taken out
 evenly along it, so the turn at 1 is the turn at 0 and a loop does not jump.
 Identity on a curve of fewer than two points or no length.
*>
fn Quaternionf AnimPath.turn_at(&self, float u, float[] table = {})
{
	if (self.points.len < 2) return quaternion::IDENTITY;
	if (self.closed) u -= math::floor(u);
	u = math::clamp(u, 0.0f, 1.0f);
	float[] lengths = table.len > 0 ? table : self.length_table(tmem);
	float total = lengths[^1];
	if (!(total > 1.0e-9f)) return quaternion::IDENTITY;
	usz steps = lengths.len;
	float want = u * total;
	usz lo = 0;
	usz hi = steps - 1;
	while (hi - lo > 1)
	{
		usz mid = (lo + hi) / 2;
		if (lengths[mid] < want) { lo = mid; } else { hi = mid; }
	}
	// The direction at every step to `hi`, or round the whole curve when it closes.
	usz last = self.closed ? steps - 1 : hi;
	Vec3[] heading = alloc::new_array(tmem, Vec3, (sz)(last + 1));
	for (usz i = 0; i <= last; i++) heading[i] = self.heading_at(i, steps);
	Quaternionf[] turned = alloc::new_array(tmem, Quaternionf, (sz)(last + 1));
	turned[0] = quaternion::IDENTITY;
	for (usz i = 1; i <= last; i++) turned[i] = bone_carry(heading[i - 1], heading[i]).mul(turned[i - 1]).normalize();
	if (self.closed && heading[0].length_sq() > 1.0e-12f)
	{
		// Come round, the turn is a twist about the start's direction: unwind it
		// along the way, about each step's own direction so the heading stays.
		Vec3 axis = heading[0].normalize();
		Quaternionf round = turned[last];
		float twist = 2.0f * math::atan2(round.i * axis.x + round.j * axis.y + round.k * axis.z, round.l);
		for (usz i = 1; i <= last; i++)
		{
			if (heading[i].length_sq() < 1.0e-12f) continue;
			float back = -twist * (float)i / (float)last;
			turned[i] = quaternion::from_axis_angle{float}(heading[i].normalize(), back).mul(turned[i]).normalize();
		}
	}
	float piece = lengths[hi] - lengths[lo];
	float t = piece > 1.0e-12f ? (want - lengths[lo]) / piece : 0.0f;
	return slerp_short(turned[lo], turned[hi], t);
}

// The curve's direction at step `i` of its `steps`-long length table: the chord
// through the steps either side (wrapping round a closed curve).
fn Vec3 AnimPath.heading_at(&self, usz i, usz steps)
{
	usz end = steps - 1;
	usz before = i > 0 ? i - 1 : self.closed ? end - 1 : 0;
	usz after = i < end ? i + 1 : self.closed ? 1 : end;
	Vec3 chord = self.at_step(after) - self.at_step(before);
	if (chord.length_sq() > 1.0e-14f) return chord;
	// A step on a sharp point's corner with its neighbours on top of it: its own span.
	return i < end ? self.at_step(i + 1) - self.at_step(i) : self.at_step(i) - self.at_step(i - 1);
}

// ---------------------------------------------------------------------------
// Timing

fn bool AnimPath.plays(&self) => !self.mute && self.joint.len > 0 && self.points.len > 0 && self.slices.len > 0;

<*
 How far along the curve the joint is at `time`: between the slices on either
 side, by time; a closed curve on a looping clip runs from the last slice on
 into the first, forward. Before the first slice and after the last, an open
 path (or a clip that does not loop) waits at that slice.
*>
fn float AnimPath.fraction_at(&self, float time, float duration, bool loop)
{
	usz count = self.slices.len;
	if (count == 0) return 0.0f;
	if (count == 1) return self.slices[0].u;
	bool wraps = loop && duration > 0.0f;
	if (wraps) time -= duration * math::floor(time / duration);
	AnimPathSlice a;
	AnimPathSlice b;
	float from;
	float to;
	if (time < self.slices[0].time || time >= self.slices[^1].time)
	{
		if (!wraps) return time < self.slices[0].time ? self.slices[0].u : self.slices[^1].u;
		a = self.slices[^1];
		b = self.slices[0];
		from = a.time;
		to = b.time + duration;
		if (time < self.slices[0].time) time += duration;
	}
	else
	{
		usz k = 0;
		while (k + 1 < count && self.slices[k + 1].time <= time) k++;
		a = self.slices[k];
		b = self.slices[k + 1];
		from = a.time;
		to = b.time;
	}
	float t = to - from > 1.0e-6f ? math::clamp((time - from) / (to - from), 0.0f, 1.0f) : 1.0f;
	float u1 = b.u;
	// Around a closed curve the joint goes on forward through its start.
	if (self.closed && u1 < a.u) u1 += 1.0f;
	return a.u + (u1 - a.u) * t;
}

// Where the joint is held at `time`, a fraction of the rig's height.
fn Vec3 AnimPath.held_at(&self, float time, float duration, bool loop)
{
	return self.at_fraction(self.fraction_at(time, duration, loop));
}

fn bool AnimTemplate.plays_paths(&self)
{
	foreach (&path : self.paths) if (path.plays()) return true;
	return false;
}

<*
 The clip's paths at `time` as position pins, followed by the clip's own pins:
 what `pin_pose` lays over a pose. The pins borrow the paths' joint names and the
 clip's pins; the array is the caller's, from `allocator`.
*>
fn AnimPin[] clip_live_pins(Allocator allocator, AnimTemplate* clip, float time)
{
	if (clip.paths.len == 0) return clip.pins;
	AnimPin[] out = alloc::new_array(allocator, AnimPin, (sz)(clip.paths.len + clip.pins.len));
	usz used;
	foreach (&path : clip.paths)
	{
		if (!path.plays()) continue;
		bool whole = !(path.to > path.from);
		float u = path.fraction_at(time, clip.duration, clip.loop);
		float[] lengths = path.points.len >= 2 ? path.length_table(tmem) : {};
		out[used++] = {
			.joint = path.joint,
			.position = true,
			.at = path.at_fraction(u, lengths),
			.orient = quaternion::IDENTITY,
			.follow = path.follow,
			.turn = path.follow ? path.turn_at(u, lengths) : quaternion::IDENTITY,
			.from = whole ? 0.0f : path.from,
			// A whole-clip path holds through the loop point as well.
			.to = whole ? clip.duration + (clip.loop ? 1.0f : 0.0f) : path.to,
			.blend = whole ? 0.0f : path.blend,
		};
	}
	foreach (pin : clip.pins) out[used++] = pin;
	return out[:used];
}

<*
 `times` with what the paths need when baked: every slice, the window edges, and
 a grid of `PATH_BAKE_RATE` a second through each window, since the joint is on a
 curve between the slices. Sorted; consumes `times`.
*>
const float PATH_BAKE_RATE = 30.0f;

fn float[] path_sample_times(Allocator allocator, AnimTemplate* clip, float[] times)
{
	if (!clip.plays_paths() || !(clip.duration > 0.0f)) return times;
	usz grid = (usz)math::ceil(clip.duration * PATH_BAKE_RATE) + 1;
	usz extra = grid + 2 * clip.paths.len;
	foreach (&path : clip.paths) extra += path.slices.len;
	float[] merged = alloc::new_array(allocator, float, (sz)(times.len + extra));
	usz used;
	foreach (time : times) merged[used++] = time;
	alloc::free(allocator, times);
	usz seeded = used;
	for (usz i = 0; i < grid; i++) merged[used++] = math::min(clip.duration, (float)i / PATH_BAKE_RATE);
	foreach (&path : clip.paths)
	{
		if (!path.plays()) continue;
		foreach (slice : path.slices) if (slice.time >= 0.0f && slice.time <= clip.duration) merged[used++] = slice.time;
		if (path.to > path.from)
		{
			merged[used++] = math::clamp(path.from, 0.0f, clip.duration);
			merged[used++] = math::clamp(path.to, 0.0f, clip.duration);
		}
	}
	sort::quicksort(merged[:used]);
	// Instants within ANIM_SAME_TIME of the last kept one are one instant.
	usz kept;
	foreach (time : merged[:used])
	{
		if (kept > 0 && time - merged[kept - 1] < ANIM_SAME_TIME) continue;
		merged[kept++] = time;
	}
	(void)seeded;
	float[] out = alloc::new_array(allocator, float, (sz)kept);
	foreach (usz i, time : merged[:kept]) out[i] = time;
	alloc::free(allocator, merged);
	return out;
}

// Mark every joint a playing path's limb turns, as `pin_mark_turned` does for pins.
fn void path_mark_turned(rig::Skeleton* skeleton, String[] names, AnimTemplate* clip, bool[] turned)
{
	foreach (&path : clip.paths)
	{
		if (!path.plays()) continue;
		foreach (usz j, name : names)
		{
			if (j >= skeleton.len() || name != path.joint) continue;
			usz[IK_RUN_MAX] run;
			usz count = pin_run(skeleton, j, run[..]);
			for (usz k = 0; k < count; k++) turned[run[k]] = true;
			if (path.follow) turned[j] = true;
			break;
		}
	}
}

<*
 The clip with its playing paths baked into its keys and every path taken off,
 its pins and aims kept live. What "Bake to keys" lands.
*>
fn AnimTemplate clip_paths_baked(Allocator allocator, AnimTemplate source, rig::Skeleton* skeleton, String[] names,
	ConstraintRig constraints = {})
{
	AnimTemplate only = clip_copy(allocator, source);
	defer only.free(allocator);
	// Bake the paths alone: the pins and aims stay what they are and are put back.
	AnimPin[] pins = only.pins;
	AnimAim[] aims = only.aims;
	AnimAimTarget[] targets = only.aim_targets;
	only.pins = {};
	only.aims = {};
	only.aim_targets = {};
	AnimTemplate out = clip_aims_flattened(allocator, only, skeleton, names, constraints);
	only.pins = pins;
	only.aims = aims;
	only.aim_targets = targets;
	free_pins(allocator, out.pins);
	free_aims(allocator, out.aims);
	free_aim_targets(allocator, out.aim_targets);
	out.pins = pins_copy(allocator, source.pins);
	out.aims = aims_copy(allocator, source.aims);
	out.aim_targets = aim_targets_copy(allocator, source.aim_targets);
	free_anim_paths(allocator, out.paths);
	out.paths = {};
	return out;
}

// ---------------------------------------------------------------------------
// JSON, shared by the sidecar and the MCP wire

fn String AnimSliceTag.wire(self)
{
	switch (self)
	{
		case NONE: return "";
		case DOWN: return "down";
		case UP: return "up";
	}
}

<*
 The path as a JSON object's members, without the braces.
*>
fn void append_path_fields(DString* out, AnimPath* path)
{
	out.append_string(`"joint":`);
	append_json_string(out, path.joint);
	if (path.name.len > 0)
	{
		out.append_string(`,"name":`);
		append_json_string(out, path.name);
	}
	if (path.closed) out.append_string(`,"closed":true`);
	if (path.mute) out.append_string(`,"mute":true`);
	if (path.follow) out.append_string(`,"follow":true`);
	if (path.generated) out.append_string(`,"generated":true`);
	if (path.to > path.from) out.appendf(`,"from":%s,"to":%s`, (JsonFloat)path.from, (JsonFloat)path.to)!!;
	if (path.blend > 0.0f) out.appendf(`,"blend":%s`, (JsonFloat)path.blend)!!;
	out.append_string(`,"points":[`);
	foreach (usz i, point : path.points)
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"at":%s`, (JsonVec3)point.at)!!;
		if (point.sharp) out.append_string(`,"sharp":true`);
		out.append_char('}');
	}
	out.append_string(`],"slices":[`);
	foreach (usz i, slice : path.slices)
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"time":%s,"u":%s`, (JsonFloat)slice.time, (JsonFloat)slice.u)!!;
		if (slice.tag != NONE) out.appendf(`,"tag":"%s"`, slice.tag.wire())!!;
		out.append_char('}');
	}
	out.append_char(']');
}

<*
 Read a path from a JSON object, on top of `path` (a zero one, or the path being
 replaced: members left out keep their value). Validates the shape, not the
 joint name. Slices are put in time order.

 @param detail : `Filled with the refusal; may be null.`
*>
fn bool read_path_fields(Object* obj, Allocator allocator, AnimPath* path, DString* detail)
{
	if (obj == null || !obj.is_keyable())
	{
		if (detail) detail.append_string("a path must be an object");
		return false;
	}
	if (member(obj, "joint") != null)
	{
		String? joint = obj.get_string("joint");
		if (catch joint)
		{
			if (detail) detail.append_string(`path "joint" must be a joint name`);
			return false;
		}
		if (path.joint.len > 0) alloc::free(allocator, path.joint.ptr);
		path.joint = joint.len > 0 ? joint.copy(allocator) : "";
	}
	if (member(obj, "name") != null)
	{
		String name = obj.get_string("name") ?? "";
		if (path.name.len > 0) alloc::free(allocator, path.name.ptr);
		path.name = name.len > 0 ? name.copy(allocator) : "";
	}
	if (member(obj, "closed") != null) path.closed = obj.get_bool("closed") ?? false;
	if (member(obj, "mute") != null) path.mute = obj.get_bool("mute") ?? false;
	if (member(obj, "follow") != null) path.follow = obj.get_bool("follow") ?? false;
	if (member(obj, "generated") != null) path.generated = obj.get_bool("generated") ?? false;
	if (member(obj, "from") != null) path.from = (float)(obj.get_float("from") ?? 0.0);
	if (member(obj, "to") != null) path.to = (float)(obj.get_float("to") ?? 0.0);
	if (member(obj, "blend") != null) path.blend = math::max(0.0f, (float)(obj.get_float("blend") ?? 0.0));

	Object* points = member(obj, "points");
	if (points != null)
	{
		if (!points.is_array() || points.get_len() > (sz)PATH_POINTS_MOST)
		{
			if (detail) detail.appendf(`path "points" must be an array of up to %d {"at":[x,y,z]}`, PATH_POINTS_MOST);
			return false;
		}
		AnimPathPoint[] read = alloc::new_array(allocator, AnimPathPoint, (sz)points.get_len());
		for (sz i = 0; i < points.get_len(); i++)
		{
			Object* point = points.get_at((usz)i);
			Vec3 at;
			if (point == null || !point.is_keyable() || !as_vec3(member(point, "at"), &at) || !math::is_finite(at.length_sq()))
			{
				alloc::free(allocator, read);
				if (detail) detail.appendf(`path "points"[%d] needs "at": [x,y,z], a fraction of the rig's height`, i);
				return false;
			}
			read[(usz)i] = { .at = at, .sharp = point.get_bool("sharp") ?? false };
		}
		if (path.points.len > 0) alloc::free(allocator, path.points);
		path.points = read;
	}

	Object* slices = member(obj, "slices");
	if (slices != null)
	{
		if (!slices.is_array())
		{
			if (detail) detail.append_string(`path "slices" must be an array of {"time": s, "u": 0..1}`);
			return false;
		}
		AnimPathSlice[] read = alloc::new_array(allocator, AnimPathSlice, (sz)slices.get_len());
		for (sz i = 0; i < slices.get_len(); i++)
		{
			Object* slice = slices.get_at((usz)i);
			double? time = slice ? slice.get_float("time") : NOT_FOUND~;
			double? u = slice ? slice.get_float("u") : NOT_FOUND~;
			if (catch time, u)
			{
				alloc::free(allocator, read);
				if (detail) detail.appendf(`path "slices"[%d] needs "time" (seconds) and "u" (0..1 along the curve)`, i);
				return false;
			}
			String tag = slice.get_string("tag") ?? "";
			if (!math::is_finite((float)time) || !(u >= 0.0 && u <= 1.0) || (tag != "" && tag != "down" && tag != "up"))
			{
				alloc::free(allocator, read);
				if (detail) detail.appendf(`path "slices"[%d]: "time" must be a number, "u" 0 to 1 and "tag" "down" or "up"`, i);
				return false;
			}
			read[(usz)i] = { .time = (float)time, .u = (float)u, .tag = tag == "down" ? DOWN : tag == "up" ? UP : NONE };
		}
		if (path.slices.len > 0) alloc::free(allocator, path.slices);
		path.slices = read;
		path.sort_slices();
	}
	if (path.joint.len == 0)
	{
		if (detail) detail.append_string(`a path needs "joint": the joint that follows it`);
		return false;
	}
	return true;
}

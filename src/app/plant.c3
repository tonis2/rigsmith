<*
 Plant feet: bake a clip's stance feet still, so they stop skating.

 A planted foot holds its horizontal place while the pelvis moves over it. The
 vertical half is `ground_pose`'s, which slides the root's Y; the horizontal half
 needs the leg to bend. So across each stance window this holds the foot's XZ
 with the same limit-aware IK a pinned foot is held by
 (`solve_limited_pose_chain`), and keys the corrected leg.

 `travel` is the speed an in-place body is not really moving at: the plant
 creeps a stance foot backward by it, which is what a treadmill cycle is. Zero
 holds the foot fixed in the world.

 Shared by MCP `plant_feet` and the Animations pane's Plant feet. Neither lands
 here: the caller decides how the planted clip reaches the project.
*>
module crig;

import rig;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// The most feet one clip plants, and the key density per clip.
const usz PLANT_FEET_MOST = 8;
const usz PLANT_SAMPLES_DEFAULT = 24;
const usz PLANT_SAMPLES_MOST = 128;
const float PLANT_SAMPLES_PER_SECOND = 48.0f;
// How far inside and outside a stance window's edge its bracketing keys sit, seconds.
const float PLANT_EDGE_EPSILON = 2.0e-3f;

<*
 The key density for a clip of this length: a foot held between keys drifts
 with the gap, so a longer cycle needs more of them, not the same 24.
*>
fn usz plant_samples_for(float duration)
{
	usz wanted = (usz)math::ceil(duration * PLANT_SAMPLES_PER_SECOND);
	return math::clamp(wanted, PLANT_SAMPLES_DEFAULT, PLANT_SAMPLES_MOST);
}
// What foot_slide is measured at, before and after — independent of the key
// density, so the number read is the clip's and not the bake's sampling.
const usz PLANT_MEASURE_SAMPLES = 64;

// One foot to plant, resolved against the clip's rig and its ground window.
struct FootPlant
{
	String name;
	usz joint;
	uint dot_id;
	float down;
	float up;
	float plant_x;
	float plant_y;
	float plant_z;
	bool off_floor; // held in height too; the floor solve does not place it
	bool ok;
	usz corrections;
}

struct PlantOutcome
{
	FootPlant[PLANT_FEET_MOST] feet;
	usz foot_count;
	ClipMetrics before;
	ClipMetrics after;
	usz keys;
}

fn void PlantOutcome.free(&self)
{
	self.before.free(mem);
	self.after.free(mem);
}

// Whether a window covering [down, up) — wrapping when up is at or below down —
// contains this phase. The same rule `AnimFoot.planted` follows.
fn bool planted_at(float down, float up, float phase) @local
	=> up > down ? (phase >= down && phase < up) : (phase >= down || phase < up);

<*
 Hold every stance foot of `ground` still across its window.

 @param names : `The rig's joints in the clip's words, parallel to view's skeleton.`
 @param ground : `Which joints are feet and when each is down; the clip's own spec or one derived from its motion.`
 @param planted : `Filled with the planted clip, owned, when this returns true.`
 @return `False when nothing moved: the feet were already still, or none had a leg to bend. out.before is measured either way.`
*>
fn bool AppState.plant_clip(&self, RigView* view, String[] names, AnimTemplate* src, AnimGround ground,
	Vec3 travel, usz samples, PlantOutcome* out, AnimTemplate* planted)
{
	*out = {};
	float duration = src.duration;
	float height = view.skeleton.height();
	float tolerance = height > 0.0f ? height * IK_TOLERANCE : 0.0f;

	out.before = clip_metrics(mem, &view.skeleton, names, *src, PLANT_MEASURE_SAMPLES, contacts: ground);
	if (duration <= 0.0f) return false;

	// Resolve each foot to its leg and read where it plants — the foot's place at
	// the start of its window, which is where it is held for the window's length.
	foreach (foot : ground.feet)
	{
		if (out.foot_count >= PLANT_FEET_MOST) break;
		FootPlant fp = { .name = foot.joint, .down = foot.down, .up = foot.up, .off_floor = foot.off_floor };
		sz j = -1;
		foreach (usz i, name : names) if (foot.joint.len > 0 && name == foot.joint && i < view.dot_ids.len) { j = (sz)i; break; }
		if (j >= 0)
		{
			uint dot_id = view.dot_ids[(usz)j];
			PoseChain chain = self.pose_chain(view, dot_id);
			if (chain.count > 0)
			{
				fp.dot_id = dot_id;
				fp.joint = (usz)j;
				rig::Pose start = src.pose(mem, &view.skeleton, names, fp.down * duration, false);
				defer start.free(mem);
				if (try pal = rig::joint_palette(mem, &view.skeleton, start))
				{
					defer alloc::free(mem, pal);
					Vec3 at = view.skeleton.joints[fp.joint].transform(pal[fp.joint]);
					fp.plant_x = at.x;
					fp.plant_y = at.y;
					fp.plant_z = at.z;
					fp.ok = true;
				}
			}
		}
		out.feet[out.foot_count++] = fp;
	}

	// At each instant, hold every foot that is down there, and key the leg the
	// hold turned. Corrections are computed against the source clip, so order does
	// not matter; they are merged into a growing copy of it.
	AnimTemplate current;
	bool have_current = false;
	float[] times = plant_times(src, samples, out.feet[:out.foot_count]);
	defer alloc::free(mem, times);
	usz steps = times.len;
	for (usz i = 0; i < steps; i++)
	{
		float t = times[i];
		float phase = src.phase_at(t);

		rig::Pose pose = src.pose(mem, &view.skeleton, names, t, false);
		defer pose.free(mem);

		usz joints = view.skeleton.len();
		Quaternionf[] snapshot = alloc::new_array(mem, Quaternionf, (sz)joints);
		defer alloc::free(mem, snapshot);
		snapshot[:joints] = pose.rotations[:joints];

		// Each planted foot's current height, read once before any leg is bent —
		// legs do not share joints, so one palette answers for all of them.
		Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
		if (catch built) continue;
		Matrix4f[] pal0 = built;
		defer alloc::free(mem, pal0);

		bool moved = false;
		for (usz fi = 0; fi < out.foot_count; fi++)
		{
			FootPlant* fp = &out.feet[fi];
			if (!fp.ok || !planted_at(fp.down, fp.up, phase)) continue;

			float ep = phase >= fp.down ? phase - fp.down : (1.0f - fp.down) + phase;
			float elapsed = ep * duration;
			Vec3 current_at = view.skeleton.joints[fp.joint].transform(pal0[fp.joint]);
			Vec3 target = {
				fp.plant_x - travel.x * elapsed,
				fp.off_floor ? fp.plant_y : current_at.y,
				fp.plant_z - travel.z * elapsed,
			};

			PoseChain chain = self.pose_chain(view, fp.dot_id);
			if (chain.count == 0) continue;
			Vec3[IK_MAX_CHAIN + 1] points;
			self.chain_points(view, chain, pose, {}, points[:chain.count + 1]);
			(void)self.solve_limited_pose_chain(view, chain, &pose,
				points[:chain.count + 1], target, tolerance, {}, false);
			fp.corrections++;
			moved = true;
		}

		// The window's two neighbours: the sample just outside each edge keys the
		// leg as the source has it. Without them a smooth clip's cubic runs from its
		// sparse swing keys straight into the dense, differently-shaped window keys
		// and overshoots on the way in and out.
		PoseChain[PLANT_FEET_MOST] edges;
		usz edge_count = 0;
		for (usz fi = 0; fi < out.foot_count; fi++)
		{
			FootPlant* fp = &out.feet[fi];
			if (!fp.ok || planted_at(fp.down, fp.up, phase)) continue;
			bool before = src.loop || i > 0;
			bool after = src.loop || i + 1 < steps;
			bool next_to = (before && planted_at(fp.down, fp.up,
					src.phase_at(times[(i + steps - 1) % steps])))
				|| (after && planted_at(fp.down, fp.up,
					src.phase_at(times[(i + 1) % steps])));
			if (!next_to) continue;
			PoseChain chain = self.pose_chain(view, fp.dot_id);
			if (chain.count > 0) edges[edge_count++] = chain;
		}
		if (!moved && edge_count == 0) continue;

		// The leg joints the holds turned, keyed as rotations — the same sparse,
		// changed-only shape the timeline's Key changed writes.
		AnimKeyframe key = leg_correction_key(view, names, snapshot, pose, t);
		key = with_edge_dots(key, view, names, snapshot, edges[:edge_count]);
		if (key.dots.len == 0)
		{
			key.free(mem);
			continue;
		}

		if (!have_current)
		{
			current = clip_with_key(mem, *src, key);
			have_current = true;
		}
		else
		{
			AnimTemplate next = clip_with_key(mem, current, key);
			current.free(mem);
			current = next;
		}
		out.keys++;
	}

	if (!have_current) return false;
	out.after = clip_metrics(mem, &view.skeleton, names, current, PLANT_MEASURE_SAMPLES, contacts: ground);
	*planted = current;
	return true;
}

// The leg correction as a sparse rotation keyframe: every named joint whose
// rotation the holds turned, and no other. The double cover is why the change test
// is the absolute dot against one.
fn AnimKeyframe leg_correction_key(RigView* view, String[] names, Quaternionf[] before, rig::Pose pose, float time) @local
{
	usz joints = view.skeleton.len();
	usz changed = 0;
	for (usz j = 0; j < joints; j++)
	{
		if (j >= names.len || names[j].len == 0) continue;
		if (math::abs(before[j].v.dot(pose.rotations[j].v)) <= 0.9999999f) changed++;
	}

	AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, (sz)changed);
	usz d = 0;
	for (usz j = 0; j < joints && d < changed; j++)
	{
		if (j >= names.len || names[j].len == 0) continue;
		if (math::abs(before[j].v.dot(pose.rotations[j].v)) > 0.9999999f) continue;
		Vec3 axis;
		float angle;
		if (!axis_angle_of(pose.rotations[j], &axis, &angle)) continue;
		dots[d++] = {
			.joint_name = names[j].copy(mem),
			.channels = AnimChannels.ROTATION,
			// Linear on purpose. INHERIT becomes AUTO on a smooth clip, and the cubic
			// through these dense keys and the clip's sparse ones rings between them.
			.rotation_interpolation = LINEAR,
			.axis = axis,
			.angle = angle,
		};
	}
	return { .time = time, .dots = dots[:d] };
}

// The time of key sample `i` of `samples`: evenly round a cycle, or end to end on
// a clip that does not wrap.
fn float plant_sample_time(AnimTemplate* src, usz i, usz samples) @local
	=> src.loop
		? (float)i / (float)samples * src.duration
		: (samples > 1 ? (float)i / (float)(samples - 1) * src.duration : 0.0f);

<*
 Every instant the plant keys, in time order: the even grid, plus a key either
 side of each stance window's two edges.

 The grid alone leaves the last planted key up to a whole step short of the
 window's end, and the curve from there to the next key — on a smooth clip a cubic
 through whatever sparse keys are nearby — drags the foot across the window's tail
 and overshoots on the way out. So each edge gets a planted key a hair inside it
 (`PLANT_EDGE_EPSILON`) and a key a hair outside, which `plant_clip` keys as the
 source has it: the hold then runs to the edge and the source curve takes over
 only beyond it.

 The caller owns the result.
*>
fn float[] plant_times(AnimTemplate* src, usz samples, FootPlant[] feet) @local
{
	float duration = src.duration;
	float epsilon = math::max(PLANT_EDGE_EPSILON, duration * 2.0e-3f);
	float[] times = alloc::new_array(mem, float, (sz)(samples + feet.len * 4));
	usz count = 0;
	for (usz i = 0; i < samples; i++) times[count++] = plant_sample_time(src, i, samples);

	foreach (foot : feet)
	{
		if (!foot.ok) continue;
		float[4] edges = {
			foot.down * duration + epsilon, foot.down * duration - epsilon,
			foot.up * duration - epsilon, foot.up * duration + epsilon,
		};
		foreach (edge : edges)
		{
			float at = edge;
			if (src.loop)
			{
				if (at < 0.0f) at += duration;
				if (at >= duration) at -= duration;
			}
			if (at < 0.0f || at > duration) continue;
			bool held = false;
			for (usz k = 0; k < count; k++) if (math::abs(times[k] - at) < ANIM_SAME_TIME) held = true;
			if (!held) times[count++] = at;
		}
	}

	// Insertion sort: a hundred and a few entries, nearly ordered.
	for (usz i = 1; i < count; i++)
	{
		float at = times[i];
		usz k = i;
		while (k > 0 && times[k - 1] > at)
		{
			times[k] = times[k - 1];
			k--;
		}
		times[k] = at;
	}
	return times[:count];
}

<*
 `key` with the legs of `chains` added as the source has them, for the samples just
 outside a planted window. Joints the key already holds are left as they are.

 Takes `key` over and returns the grown one. `source` is the pose as sampled,
 before any hold bent it.
*>
fn AnimKeyframe with_edge_dots(AnimKeyframe key, RigView* view, String[] names, Quaternionf[] source, PoseChain[] chains) @local
{
	if (chains.len == 0) return key;
	AnimDotList dots;
	dots.init(mem);
	defer dots.free();
	foreach (dot : key.dots) dots.push(dot);

	foreach (chain : chains)
	{
		for (usz c = 0; c < chain.count; c++)
		{
			usz j = chain.joints[c];
			if (j >= names.len || names[j].len == 0 || j >= source.len) continue;
			bool held = false;
			foreach (dot : dots.array_view()) if (dot.joint_name == names[j]) held = true;
			if (held) continue;
			Vec3 axis;
			float angle;
			if (!axis_angle_of(source[j], &axis, &angle)) continue;
			dots.push({
				.joint_name = names[j].copy(mem),
				.channels = AnimChannels.ROTATION,
				.rotation_interpolation = LINEAR,
				.axis = axis,
				.angle = angle,
			});
		}
	}
	if (key.dots.len > 0) alloc::free(mem, key.dots.ptr);
	key.dots = dots.to_array(mem);
	return key;
}

<*
 Feet and stance windows read off a clip that declares none.

 A foot is the uppermost of a run of joints resting near the floor (an ankle over
 its toe); it is down while it is within a small height of the lowest it ever
 gets, and its window is the longest such run, wrapping on a looping clip. A
 joint down less than three samples is not a foot of this clip.

 @return `Owned; free with AnimGround.free. Empty when the rig has no such joint.`
*>
fn AnimGround derived_contacts(rig::Skeleton* skeleton, String[] names, AnimTemplate clip)
{
	usz joints = skeleton.len();
	if (joints == 0 || clip.duration <= 0.0f) return {};
	float height = skeleton.height();
	if (height <= 0.0f) return {};
	float floor = skeleton.joints[0].y;
	foreach (joint : skeleton.joints) floor = math::min(floor, joint.y);

	const float NEAR_FLOOR = 0.12f;
	const float DOWN_BAND = 0.02f;
	const usz SAMPLES = 48;

	usz[PLANT_FEET_MOST] feet;
	usz count = 0;
	for (usz j = 0; j < joints && count < PLANT_FEET_MOST; j++)
	{
		if (j >= names.len || names[j].len == 0) continue;
		if (skeleton.joints[j].y > floor + NEAR_FLOOR * height) continue;
		int parent = skeleton.parents[j];
		if (parent >= 0 && skeleton.joints[(usz)parent].y <= floor + NEAR_FLOOR * height) continue;
		feet[count++] = j;
	}
	if (count == 0) return {};

	float[SAMPLES * PLANT_FEET_MOST] heights;
	for (usz s = 0; s < SAMPLES; s++)
	{
		float t = clip.loop ? (float)s / (float)SAMPLES * clip.duration : (float)s / (float)(SAMPLES - 1) * clip.duration;
		rig::Pose pose = clip.pose(mem, skeleton, names, t);
		defer pose.free(mem);
		Matrix4f[]? built = rig::joint_palette(mem, skeleton, pose);
		if (catch built) return {};
		defer alloc::free(mem, built);
		for (usz f = 0; f < count; f++) heights[f * SAMPLES + s] = skeleton.joints[feet[f]].transform(built[feet[f]]).y;
	}

	AnimFoot[] out = alloc::new_array(mem, AnimFoot, (sz)count);
	usz kept = 0;
	for (usz f = 0; f < count; f++)
	{
		float low = heights[f * SAMPLES];
		for (usz s = 1; s < SAMPLES; s++) low = math::min(low, heights[f * SAMPLES + s]);
		bool[SAMPLES] down;
		usz total = 0;
		for (usz s = 0; s < SAMPLES; s++)
		{
			down[s] = heights[f * SAMPLES + s] <= low + DOWN_BAND * height;
			if (down[s]) total++;
		}
		float from = 0.0f;
		float until = 1.0f;
		if (total < SAMPLES)
		{
			usz best = 0;
			usz best_start = 0;
			for (usz start = 0; start < SAMPLES; start++)
			{
				if (!down[start]) continue;
				usz before = (start + SAMPLES - 1) % SAMPLES;
				if (clip.loop ? down[before] : (start > 0 && down[start - 1])) continue;
				usz length = 0;
				while (length < SAMPLES && down[(start + length) % SAMPLES]
					&& (clip.loop || start + length < SAMPLES)) length++;
				if (length > best) { best = length; best_start = start; }
			}
			if (best < 3) continue;
			float span = clip.loop ? (float)SAMPLES : (float)(SAMPLES - 1);
			from = (float)best_start / span;
			until = (float)(best_start + best) / span;
			if (until >= 1.0f && clip.loop) until -= 1.0f;
			if (!clip.loop) until = math::min(until, 1.0f);
		}
		out[kept++] = { .joint = names[feet[f]].copy(mem), .down = from, .up = until };
	}
	if (kept == 0)
	{
		alloc::free(mem, out);
		return {};
	}
	return { .feet = out[:kept] };
}

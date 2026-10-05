<*
 Key reduction: drop baked export samples that the straight line (slerp for
 turns) between their neighbours already reproduces.

 A sample goes only when every joint's turn and slide, and every end joint's
 world position (hands, feet, head), stays within tolerance of the full bake at
 every dropped sample. Tolerances are relative to the rig's height, so Light and
 Strong mean the same on a figure in metres or centimetres.

 Protected samples are never dropped: the first and last, both sides of a Step
 (held) edge, the start of every held span, the clip's contact changes and a
 loop's wrap.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;

enum KeyReduction : char
{
	OFF,
	LIGHT,
	STRONG,
}

struct ReductionTolerance
{
	float angle; // radians per joint
	float move;  // model units per joint slide
	float reach; // model units at the end joints
}

fn ReductionTolerance KeyReduction.tolerance(self, float height)
{
	float h = height > 0.0f ? height : 1.0f;
	switch (self)
	{
		case LIGHT: return { .angle = 0.25f * (float)math::PI / 180.0f, .move = 5.0e-4f * h, .reach = 1.0e-3f * h };
		case STRONG: return { .angle = (float)math::PI / 180.0f, .move = 2.0e-3f * h, .reach = 4.0e-3f * h };
		default: return {};
	}
}

<*
 Which samples of a baked run must be kept whatever the tolerance says.

 The caller owns the array.
*>
fn bool[] protected_samples(Allocator allocator, AnimTemplate template, float[] times)
{
	usz n = times.len;
	bool[] keep = alloc::new_array(allocator, bool, (sz)n);
	if (n == 0) return keep;
	keep[0] = true;
	keep[n - 1] = true;

	// Both sides of a Step edge: the adjacent-float sample and the key it jumps to.
	for (usz k = 0; k + 1 < n; k++)
	{
		if (times[k + 1] - times[k] < 1.0e-4f)
		{
			keep[k] = true;
			keep[k + 1] = true;
		}
	}

	// The start of every held span.
	foreach (frame : template.keyframes)
	{
		bool held = false;
		foreach (dot : frame.dots)
		{
			if ((dot.keys_rotation() && dot.rotation_interpolation == HOLD)
				|| (dot.keys_translation() && dot.translation_interpolation == HOLD)) held = true;
		}
		if (held) keep_nearest(keep, times, frame.time);
	}

	// Contact changes and a loop's wrap.
	if (template.ground.solves() && template.duration > 0.0f)
	{
		foreach (foot : template.ground.feet)
		{
			keep_nearest(keep, times, foot.down * template.duration);
			keep_nearest(keep, times, foot.up * template.duration);
		}
	}
	if (template.loop && template.keyframes.len > 0)
	{
		keep_nearest(keep, times, template.keyframes[template.keyframes.len - 1].time);
	}
	return keep;
}

fn void keep_nearest(bool[] keep, float[] times, float time) @local
{
	usz best = 0;
	float gap = 3.0e38f;
	foreach (usz k, t : times)
	{
		float d = math::abs(t - time);
		if (d < gap) { gap = d; best = k; }
	}
	if (times.len > 0) keep[best] = true;
}

// The end joints a reduction's reach check watches: every joint with no child.
fn usz[] end_joints(Allocator allocator, rig::Skeleton* skeleton) @local
{
	usz joints = skeleton.len();
	List{usz} out;
	out.init(allocator);
	defer out.free();
	for (usz j = 0; j < joints; j++)
	{
		bool parent_of = false;
		for (usz c = 0; c < joints; c++)
		{
			if (skeleton.parents[c] == (int)j) { parent_of = true; break; }
		}
		if (!parent_of) out.push(j);
	}
	return out.to_array(allocator);
}

// Every joint's world position under a pose, parents first.
fn void pose_positions(rig::Skeleton* skeleton, rig::Pose* pose, Vec3[] at, Quaternionf[] turn) @local
{
	foreach (usz j, joint : skeleton.joints)
	{
		int parent = skeleton.parents[j];
		if (parent < 0)
		{
			at[j] = joint + pose.offsets[j];
			turn[j] = pose.rotations[j];
			continue;
		}
		usz p = (usz)parent;
		at[j] = at[p] + turn[p].rotate_vec3(joint - skeleton.joints[p] + pose.offsets[j]);
		turn[j] = turn[p].mul(pose.rotations[j]);
	}
}

fn float turn_gap(Quaternionf a, Quaternionf b) @local
{
	float d = math::min(math::abs(a.v.dot(b.v)), 1.0f);
	return 2.0f * math::acos(d);
}

// The most samples one kept span may skip, which bounds the check's cost.
const usz REDUCTION_LONGEST_SPAN @local = 240;

struct ReductionScratch @local
{
	rig::Pose guess;
	Vec3[] at;
	Quaternionf[] turn;
}

<*
 Whether every sample strictly between `from` and `to` is within tolerance of
 the straight line between those two.
*>
fn bool span_holds(rig::Skeleton* skeleton, float[] times, rig::Pose[] posed, Vec3[] reach_at,
	usz[] ends, usz from, usz to, ReductionTolerance tolerance, ReductionScratch* scratch) @local
{
	usz joints = skeleton.len();
	float width = times[to] - times[from];
	for (usz k = from + 1; k < to; k++)
	{
		float f = width > 0.0f ? (times[k] - times[from]) / width : 0.0f;
		for (usz j = 0; j < joints; j++)
		{
			Quaternionf a = posed[from].rotations[j];
			Quaternionf b = posed[to].rotations[j];
			Quaternionf guess = a.v.dot(b.v) < 0.0f ? a.slerp(-b, f) : a.slerp(b, f);
			guess = guess.normalize();
			if (turn_gap(guess, posed[k].rotations[j]) > tolerance.angle) return false;
			Vec3 slide = posed[from].offsets[j] + (posed[to].offsets[j] - posed[from].offsets[j]) * f;
			if ((slide - posed[k].offsets[j]).length() > tolerance.move) return false;
			scratch.guess.rotations[j] = guess;
			scratch.guess.offsets[j] = slide;
		}
		pose_positions(skeleton, &scratch.guess, scratch.at, scratch.turn);
		foreach (usz e, j : ends)
		{
			if ((scratch.at[j] - reach_at[k * ends.len + e]).length() > tolerance.reach) return false;
		}
	}
	return true;
}

<*
 The indices of the samples to keep, in order. Always keeps the protected ones.

 The caller owns the result.
*>
fn usz[] reduce_samples(Allocator allocator, rig::Skeleton* skeleton, float[] times, rig::Pose[] posed,
	bool[] protect, ReductionTolerance tolerance)
{
	usz n = times.len;
	List{usz} kept;
	kept.init(allocator);
	defer kept.free();
	if (n <= 2)
	{
		for (usz k = 0; k < n; k++) kept.push(k);
		return kept.to_array(allocator);
	}

	usz joints = skeleton.len();
	usz[] ends = end_joints(mem, skeleton);
	defer alloc::free(mem, ends);

	// Every sample's end-joint positions under the full bake, read once.
	Vec3[] reach_at = alloc::new_array(mem, Vec3, (sz)(n * ends.len));
	defer alloc::free(mem, reach_at);
	ReductionScratch scratch = {
		.guess = rig::rest_pose(mem, joints),
		.at = alloc::new_array(mem, Vec3, (sz)joints),
		.turn = alloc::new_array(mem, Quaternionf, (sz)joints),
	};
	defer
	{
		scratch.guess.free(mem);
		alloc::free(mem, scratch.at);
		alloc::free(mem, scratch.turn);
	}
	for (usz k = 0; k < n; k++)
	{
		pose_positions(skeleton, &posed[k], scratch.at, scratch.turn);
		foreach (usz e, j : ends) reach_at[k * ends.len + e] = scratch.at[j];
	}

	kept.push(0);
	usz anchor = 0;
	usz candidate = 1;
	while (candidate + 1 < n)
	{
		if (protect[candidate] || candidate + 1 - anchor > REDUCTION_LONGEST_SPAN
			|| !span_holds(skeleton, times, posed, reach_at, ends, anchor, candidate + 1, tolerance, &scratch))
		{
			kept.push(candidate);
			anchor = candidate;
		}
		candidate++;
	}
	kept.push(n - 1);
	return kept.to_array(allocator);
}

<*
 Whether two poses agree within tolerance: every joint's turn and slide, and
 every end joint's place in the world.
*>
fn bool poses_agree(rig::Skeleton* skeleton, usz[] ends, rig::Pose* a, rig::Pose* b,
	ReductionTolerance tolerance, ReductionScratch* scratch, ReductionScratch* other) @local
{
	foreach (usz j, joint : skeleton.joints)
	{
		if (turn_gap(a.rotations[j], b.rotations[j]) > tolerance.angle) return false;
		if ((a.offsets[j] - b.offsets[j]).length() > tolerance.move) return false;
	}
	pose_positions(skeleton, a, scratch.at, scratch.turn);
	pose_positions(skeleton, b, other.at, other.turn);
	foreach (j : ends)
	{
		if ((scratch.at[j] - other.at[j]).length() > tolerance.reach) return false;
	}
	return true;
}

<*
 The clip with the keys it can lose without changing its motion.

 Whole keyframes go, one at a time from the start, and a key is only dropped when
 the clip without it still plays within tolerance of the original at every key
 and midway between keys over the stretch it affects. Checking the clip's own
 interpolation (smooth, eased, stepped) rather than assuming straight lines, and
 always against the original, so the errors of several drops cannot add up.
 Protected keys (the first and last, held and stepped keys, ground contacts, a
 loop's wrap) stay.

 @param names : `The rig's joints in the clip's words.`
 @param out : `The rewritten clip, owned, when this returns true.`
 @return `False when no key could go.`
*>
fn bool clip_keys_reduced(Allocator allocator, AnimTemplate source, rig::Skeleton* skeleton,
	String[] names, KeyReduction level, AnimTemplate* out)
{
	usz n = source.keyframes.len;
	if (level == OFF || n <= 2) return false;
	ReductionTolerance tolerance = level.tolerance(skeleton.height());

	float[] key_times = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, key_times);
	foreach (usz k, frame : source.keyframes) key_times[k] = frame.time;
	bool[] protect = protected_samples(mem, source, key_times);
	defer alloc::free(mem, protect);

	// What the clip plays now: at each key, and halfway to the next.
	usz checks = 2 * n - 1;
	rig::Pose[] truth = alloc::new_array(mem, rig::Pose, (sz)checks);
	defer
	{
		foreach (&pose : truth) pose.free(mem);
		alloc::free(mem, truth);
	}
	for (usz c = 0; c < checks; c++)
	{
		float t = c % 2 == 0 ? key_times[c / 2] : 0.5f * (key_times[c / 2] + key_times[c / 2 + 1]);
		truth[c] = source.pose(mem, skeleton, names, t, false, honor_solo: false);
	}

	usz joints = skeleton.len();
	usz[] ends = end_joints(mem, skeleton);
	defer alloc::free(mem, ends);
	ReductionScratch left = {
		.guess = rig::rest_pose(mem, joints),
		.at = alloc::new_array(mem, Vec3, (sz)joints),
		.turn = alloc::new_array(mem, Quaternionf, (sz)joints),
	};
	ReductionScratch right = {
		.guess = rig::rest_pose(mem, joints),
		.at = alloc::new_array(mem, Vec3, (sz)joints),
		.turn = alloc::new_array(mem, Quaternionf, (sz)joints),
	};
	defer
	{
		left.guess.free(mem);
		right.guess.free(mem);
		alloc::free(mem, left.at);
		alloc::free(mem, left.turn);
		alloc::free(mem, right.at);
		alloc::free(mem, right.turn);
	}

	bool[] kept = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, kept);
	foreach (&k : kept) *k = true;
	AnimKeyframe[] trial_frames = alloc::new_array(mem, AnimKeyframe, (sz)n);
	defer alloc::free(mem, trial_frames);

	usz dropped = 0;
	for (usz k = 1; k + 1 < n; k++)
	{
		if (protect[k]) continue;
		kept[k] = false;
		usz lo = k - 1;
		while (!kept[lo]) lo--;
		usz hi = k + 1;
		while (!kept[hi]) hi++;

		// A clip that shares the original's curves and skips the dropped keys.
		usz count = 0;
		for (usz i = 0; i < n; i++) if (kept[i]) trial_frames[count++] = source.keyframes[i];
		AnimTemplate trial = source;
		trial.keyframes = trial_frames[:count];
		trial.owned = false;
		// The source's compiled lookup indexes the source's keys, not these.
		trial.tracks = {};
		trial.tracks_compiled = false;
		trial.compile_tracks(mem);

		bool holds = true;
		for (usz c = 2 * lo + 1; c < 2 * hi && holds; c++)
		{
			float t = c % 2 == 0 ? key_times[c / 2] : 0.5f * (key_times[c / 2] + key_times[c / 2 + 1]);
			rig::Pose now = trial.pose(mem, skeleton, names, t, false, honor_solo: false);
			holds = poses_agree(skeleton, ends, &truth[c], &now, tolerance, &left, &right);
			now.free(mem);
		}
		foreach (track : trial.tracks)
		{
			if (track.rotations.len > 0) alloc::free(mem, track.rotations);
			if (track.translations.len > 0) alloc::free(mem, track.translations);
		}
		if (trial.tracks.len > 0) alloc::free(mem, trial.tracks);
		if (holds)
		{
			dropped++;
		}
		else
		{
			kept[k] = true;
		}
	}
	if (dropped == 0) return false;

	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)(n - dropped));
	usz at = 0;
	for (usz i = 0; i < n; i++)
	{
		if (kept[i]) frames[at++] = keyframe_copy(allocator, source.keyframes[i]);
	}
	*out = clip_with_frames(allocator, source, frames, source.duration);
	return true;
}

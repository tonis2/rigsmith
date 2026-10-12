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

	// A clip that keys every joint's channels on every key — a generated or baked
	// one — has nothing outside a stretch reaching into it: a dropped key changes the
	// curve only between the kept keys round it, and a smooth curve only two keys
	// further. So its trial is those keys alone rather than the whole clip, which is
	// what keeps a clip of six hundred keys from costing six hundred whole-clip
	// compiles. A loop reads round its seam, so it is always whole.
	bool local = !source.loop && keys_uniform(source);
	usz dropped = 0;
	for (usz k = 1; k + 1 < n; k++)
	{
		if (protect[k]) continue;
		kept[k] = false;
		usz lo = k - 1;
		while (!kept[lo]) lo--;
		usz hi = k + 1;
		while (!kept[hi]) hi++;

		usz from = 0;
		usz to = n - 1;
		if (local)
		{
			from = lo;
			for (usz reach = 0; reach < 2 && from > 0; reach++)
			{
				from--;
				while (from > 0 && !kept[from]) from--;
			}
			to = hi;
			for (usz reach = 0; reach < 2 && to + 1 < n; reach++)
			{
				to++;
				while (to + 1 < n && !kept[to]) to++;
			}
		}

		// A clip that shares the original's curves and skips the dropped keys.
		usz count = 0;
		for (usz i = from; i <= to; i++) if (kept[i]) trial_frames[count++] = source.keyframes[i];
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
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)(n - dropped));
	usz at = 0;
	for (usz i = 0; i < n; i++)
	{
		if (kept[i]) frames[at++] = keyframe_copy(allocator, source.keyframes[i]);
	}
	AnimTemplate reduced = clip_with_frames(allocator, source, frames, source.duration);

	// Then the joints a kept key does not need. Half the tolerance per channel,
	// since a chain's errors add up at its end, and the whole clip checked after;
	// when that check fails, tighter, and failing that the whole keys alone.
	usz thinned = 0;
	foreach (factor : (float[]){ 0.5f, 0.25f })
	{
		ReductionTolerance per_channel = { .angle = tolerance.angle * factor, .move = tolerance.move * factor, .reach = tolerance.reach };
		AnimKeyframe[] thin;
		usz removed = thin_channels(allocator, source, reduced, skeleton, key_times, per_channel, &thin);
		if (removed == 0) break;
		AnimTemplate trial = reduced;
		trial.keyframes = thin;
		trial.owned = false;
		trial.tracks = {};
		trial.tracks_compiled = false;
		trial.compile_tracks(mem);
		bool holds = true;
		for (usz c = 0; c < checks && holds; c++)
		{
			float t = c % 2 == 0 ? key_times[c / 2] : 0.5f * (key_times[c / 2] + key_times[c / 2 + 1]);
			rig::Pose now = trial.pose(mem, skeleton, names, t, false, honor_solo: false);
			holds = poses_agree(skeleton, ends, &truth[c], &now, tolerance, &left, &right);
			now.free(mem);
		}
		free_tracks(trial);
		if (!holds)
		{
			foreach (&frame : thin) frame.free(allocator);
			alloc::free(allocator, thin);
			continue;
		}
		foreach (&frame : reduced.keyframes) frame.free(allocator);
		alloc::free(allocator, reduced.keyframes);
		reduced.keyframes = thin;
		thinned = removed;
		break;
	}

	if (dropped == 0 && thinned == 0)
	{
		reduced.free(allocator);
		return false;
	}
	*out = reduced;
	return true;
}

<*
 Whether every key of the clip keys the same channels of the same joints, in the
 same order — so the curve at any time depends only on the keys round it.
*>
fn bool keys_uniform(AnimTemplate clip) @local
{
	if (clip.keyframes.len == 0) return false;
	AnimKeyDot[] first = clip.keyframes[0].dots;
	foreach (frame : clip.keyframes)
	{
		if (frame.dots.len != first.len) return false;
		foreach (usz i, dot : frame.dots)
		{
			if (dot.joint_name != first[i].joint_name || dot.channels != first[i].channels) return false;
		}
	}
	return true;
}

// Frees tracks `compile_tracks(mem)` built on a borrowed template.
fn void free_tracks(AnimTemplate clip)
{
	foreach (track : clip.tracks)
	{
		if (track.rotations.len > 0) alloc::free(mem, track.rotations);
		if (track.translations.len > 0) alloc::free(mem, track.translations);
	}
	if (clip.tracks.len > 0) alloc::free(mem, clip.tracks);
}

// Whether `joint`'s `rotation` channel keyed in `frame` is one a neighbour may
// stand in for: neither held nor eased, so the segments either side of it are
// the clip's ordinary curve. Its interpolation goes in `mode`.
fn bool plain_channel(AnimKeyframe frame, String joint, bool rotation, AnimBlend blend,
	AnimInterpolation* mode) @local
{
	AnimKeyDot dot;
	if (!frame.channel_dot(joint, rotation, &dot)) return false;
	*mode = dot.interpolation(rotation, blend);
	return *mode != HOLD && dot.ease(rotation).none();
}

<*
 `reduced`'s keys with every channel key dropped that the curve through its
 neighbours already reproduces: one joint, one channel at a time, against
 `source` — the clip before any reduction — so the error of one drop is never
 the baseline for the next.

 A drop is checked over the stretch it can reach, two of the channel's keys
 either side, since a smooth curve reads past its neighbours; and on a loop
 near its ends, over the whole clip. A track's first and last keys stay, as do
 protected keys, and held or eased ones, and one whose neighbour's segment
 would take over with a different interpolation. A key left with no channel
 goes.

 @param key_times : `The source's key times, which the checks sample at and midway between.`
 @param out : `The keys, owned, when this returns more than zero.`
 @return `How many channel keys went.`
*>
fn usz thin_channels(Allocator allocator, AnimTemplate source, AnimTemplate reduced, rig::Skeleton* skeleton,
	float[] key_times, ReductionTolerance tolerance, AnimKeyframe[]* out) @local
{
	usz n = reduced.keyframes.len;
	if (n <= 2 || key_times.len == 0) return 0;
	float height = skeleton.height() > 0.0f ? skeleton.height() : 1.0f;
	if (keys_linear(source) && keys_linear(reduced)) return thin_linear(allocator, source, reduced, height, tolerance, out);

	usz checks = 2 * key_times.len - 1;
	float[] check_at = alloc::new_array(mem, float, (sz)checks);
	defer alloc::free(mem, check_at);
	for (usz c = 0; c < checks; c++)
	{
		check_at[c] = c % 2 == 0 ? key_times[c / 2] : 0.5f * (key_times[c / 2] + key_times[c / 2 + 1]);
	}

	AnimTemplate truth = source;
	truth.owned = false;
	truth.tracks = {};
	truth.tracks_compiled = false;
	truth.compile_tracks(mem);
	defer free_tracks(truth);

	AnimTemplate probe = reduced;
	probe.owned = false;
	probe.tracks = {};
	probe.tracks_compiled = false;
	probe.compile_tracks(mem);
	usz tracks = probe.tracks.len;
	AnimTrack[] compiled = alloc::new_array(mem, AnimTrack, (sz)tracks);
	defer alloc::free(mem, compiled);
	compiled[..] = probe.tracks[..];
	defer
	{
		probe.tracks[..] = compiled[..];
		free_tracks(probe);
	}

	float[] times = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, times);
	foreach (usz k, frame : reduced.keyframes) times[k] = frame.time;
	bool[] protect = protected_samples(mem, reduced, times);
	defer alloc::free(mem, protect);

	// Which channel keys went, by key and track: [key * tracks * 2 + track * 2 + channel].
	bool[] gone = alloc::new_array(mem, bool, (sz)(n * tracks * 2));
	defer alloc::free(mem, gone);
	bool cyclic = reduced.loop && reduced.duration > 0.0f;

	usz removed = 0;
	for (usz t = 0; t < tracks; t++)
	{
		String joint = compiled[t].joint_name;
		for (usz ch = 0; ch < 2; ch++)
		{
			bool rotation = ch == 0;
			usz[] keys = rotation ? compiled[t].rotations : compiled[t].translations;
			usz m = keys.len;
			if (m <= 2) continue;

			bool[] alive = alloc::new_array(mem, bool, (sz)m);
			usz[] live = alloc::new_array(mem, usz, (sz)m);
			defer
			{
				alloc::free(mem, alive);
				alloc::free(mem, live);
				if (rotation) { probe.tracks[t].rotations = keys; } else { probe.tracks[t].translations = keys; }
			}
			foreach (&a : alive) *a = true;

			for (usz r = 1; r + 1 < m; r++)
			{
				usz key = keys[r];
				if (protect[key]) continue;
				AnimInterpolation mode;
				if (!plain_channel(reduced.keyframes[key], joint, rotation, reduced.blend, &mode)) continue;
				usz before = r - 1;
				while (!alive[before]) before--;
				AnimInterpolation previous;
				if (!plain_channel(reduced.keyframes[keys[before]], joint, rotation, reduced.blend, &previous)
					|| previous != mode) continue;

				// The stretch this drop can reach: two live keys either side.
				usz lo = before;
				usz reach = 1;
				while (lo > 0 && reach < 2)
				{
					lo--;
					if (alive[lo]) reach++;
				}
				usz hi = r + 1;
				reach = 1;
				while (hi + 1 < m && reach < 2)
				{
					hi++;
					if (alive[hi]) reach++;
				}
				bool whole = cyclic && (lo == 0 || hi == m - 1);
				float from = whole ? -1.0e30f : reduced.keyframes[keys[lo]].time;
				float to = whole ? 1.0e30f : reduced.keyframes[keys[hi]].time;

				alive[r] = false;
				usz count = 0;
				for (usz i = 0; i < m; i++) if (alive[i]) live[count++] = keys[i];
				if (rotation) { probe.tracks[t].rotations = live[:count]; } else { probe.tracks[t].translations = live[:count]; }

				bool holds = true;
				for (usz c = 0; c < checks && holds; c++)
				{
					float at = check_at[c];
					if (at < from || at > to) continue;
					if (rotation)
					{
						holds = turn_gap(probe.rotation_at(joint, at), truth.rotation_at(joint, at)) <= tolerance.angle;
					}
					else
					{
						holds = (probe.translation_at(joint, at) - truth.translation_at(joint, at)).length() * height
							<= tolerance.move;
					}
				}
				if (holds)
				{
					gone[key * tracks * 2 + t * 2 + ch] = true;
					removed++;
				}
				else
				{
					alive[r] = true;
				}
			}
		}
	}
	if (removed == 0) return 0;
	String[] track_names = alloc::new_array(mem, String, (sz)tracks);
	defer alloc::free(mem, track_names);
	foreach (usz t, track : compiled[:tracks]) track_names[t] = track.joint_name;
	*out = keys_without_channels(allocator, reduced, track_names, gone);
	return removed;
}

<*
 `reduced`'s keys with the channel keys `gone` marks left out — indexed
 [key * tracks * 2 + track * 2 + channel], channel 0 the rotation — and a key left
 with no channel dropped. Owned.
*>
fn AnimKeyframe[] keys_without_channels(Allocator allocator, AnimTemplate reduced, String[] track_names, bool[] gone) @local
{
	usz tracks = track_names.len;
	List{AnimKeyframe} kept;
	kept.init(allocator);
	defer kept.free();
	foreach (usz k, frame : reduced.keyframes)
	{
		List{AnimKeyDot} dots;
		dots.init(allocator);
		defer dots.free();
		foreach (dot : frame.dots)
		{
			usz t = 0;
			while (t < tracks && track_names[t] != dot.joint_name) t++;
			bool turns = dot.keys_rotation() && !(t < tracks && gone[k * tracks * 2 + t * 2]);
			bool slides = dot.keys_translation() && !(t < tracks && gone[k * tracks * 2 + t * 2 + 1]);
			if (!turns && !slides) continue;
			AnimKeyDot copy = dot.copy(allocator);
			if (!turns)
			{
				copy.channels = TRANSLATION;
				copy.rotation_interpolation = INHERIT;
				copy.rotation_ease = {};
			}
			else if (!slides)
			{
				copy.channels = ROTATION;
				copy.translation_interpolation = INHERIT;
				copy.translation_ease = {};
			}
			dots.push(copy);
		}
		if (dots.len() == 0) continue;
		kept.push({ .time = frame.time, .dots = dots.to_array(allocator) });
	}
	return kept.to_array(allocator);
}

<*
 Whether every key of the clip moves its channels in straight lines: the same
 channels of the same joints on every key (`keys_uniform`), each leaving linearly
 and with no ease, on a clip that does not loop. Then a channel key's drop is
 decided by the straight segment over the gap it leaves alone — what
 `thin_linear` does without evaluating the clip.
*>
fn bool keys_linear(AnimTemplate clip) @local
{
	if (clip.loop || !keys_uniform(clip)) return false;
	foreach (frame : clip.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.keys_rotation() && (dot.interpolation(true, clip.blend) != LINEAR || !dot.ease(true).none())) return false;
			if (dot.keys_translation() && (dot.interpolation(false, clip.blend) != LINEAR || !dot.ease(false).none())) return false;
		}
	}
	return true;
}

<*
 `thin_channels` for a clip of straight segments (`keys_linear`): each channel
 key, in order, goes when the straight segment from the last key kept to the next
 one stays within tolerance of `source` at every source key and midway between
 them inside it. Read off the keys' own values, with no clip evaluated, so a
 generated clip of six hundred keys thins in a moment rather than minutes.

 @return `How many channel keys went; zero when the reduced keys are not a subset of the source's.`
*>
fn usz thin_linear(Allocator allocator, AnimTemplate source, AnimTemplate reduced, float height,
	ReductionTolerance tolerance, AnimKeyframe[]* out) @local
{
	usz n = reduced.keyframes.len;
	usz s = source.keyframes.len;
	if (n <= 2 || s < n) return 0;
	AnimKeyDot[] layout = reduced.keyframes[0].dots;
	usz tracks = layout.len;
	if (source.keyframes[0].dots.len != tracks) return 0;
	foreach (usz t, dot : layout) if (source.keyframes[0].dots[t].joint_name != dot.joint_name) return 0;

	// Where each kept key is among the source's.
	usz[] at = alloc::new_array(mem, usz, (sz)n);
	defer alloc::free(mem, at);
	usz cursor = 0;
	foreach (usz k, frame : reduced.keyframes)
	{
		while (cursor < s && source.keyframes[cursor].time < frame.time - ANIM_SAME_TIME) cursor++;
		if (cursor >= s || math::abs(source.keyframes[cursor].time - frame.time) > ANIM_SAME_TIME) return 0;
		at[k] = cursor;
	}

	// Every source key's value per track, read once.
	Quaternionf[] turns = alloc::new_array(mem, Quaternionf, (sz)(s * tracks));
	defer alloc::free(mem, turns);
	Vec3[] moves = alloc::new_array(mem, Vec3, (sz)(s * tracks));
	defer alloc::free(mem, moves);
	foreach (usz i, frame : source.keyframes)
	{
		foreach (usz t, dot : frame.dots)
		{
			turns[i * tracks + t] = quaternion::from_axis_angle{float}(dot.axis.normalize(), dot.angle);
			moves[i * tracks + t] = dot.move;
		}
	}

	float[] times = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, times);
	foreach (usz k, frame : reduced.keyframes) times[k] = frame.time;
	bool[] protect = protected_samples(mem, reduced, times);
	defer alloc::free(mem, protect);

	bool[] gone = alloc::new_array(mem, bool, (sz)(n * tracks * 2));
	defer alloc::free(mem, gone);
	usz removed = 0;
	for (usz t = 0; t < tracks; t++)
	{
		for (usz ch = 0; ch < 2; ch++)
		{
			bool rotation = ch == 0;
			if (rotation ? !layout[t].keys_rotation() : !layout[t].keys_translation()) continue;
			usz before = 0;
			for (usz r = 1; r + 1 < n; r++)
			{
				if (protect[r])
				{
					before = r;
					continue;
				}
				usz a = at[before];
				usz b = at[r + 1];
				float from = source.keyframes[a].time;
				float span = source.keyframes[b].time - from;
				bool holds = span > 0.0f;
				for (usz i = a; i < b && holds; i++)
				{
					// The source key itself, then midway to the next.
					for (usz half = 0; half < 2 && holds; half++)
					{
						if (i == a && half == 0) continue;
						float time = half == 0 ? source.keyframes[i].time
							: 0.5f * (source.keyframes[i].time + source.keyframes[i + 1].time);
						float u = (time - from) / span;
						if (rotation)
						{
							Quaternionf truth = half == 0 ? turns[i * tracks + t]
								: slerp_short(turns[i * tracks + t], turns[(i + 1) * tracks + t], 0.5f);
							Quaternionf straight = slerp_short(turns[a * tracks + t], turns[b * tracks + t], u);
							holds = turn_gap(straight, truth) <= tolerance.angle;
						}
						else
						{
							Vec3 truth = half == 0 ? moves[i * tracks + t]
								: (moves[i * tracks + t] + moves[(i + 1) * tracks + t]) * 0.5f;
							Vec3 straight = moves[a * tracks + t] + (moves[b * tracks + t] - moves[a * tracks + t]) * u;
							holds = (straight - truth).length() * height <= tolerance.move;
						}
					}
				}
				if (holds)
				{
					gone[r * tracks * 2 + t * 2 + ch] = true;
					removed++;
				}
				else
				{
					before = r;
				}
			}
		}
	}
	if (removed == 0) return 0;
	String[] track_names = alloc::new_array(mem, String, (sz)tracks);
	defer alloc::free(mem, track_names);
	foreach (usz t, dot : layout) track_names[t] = dot.joint_name;
	*out = keys_without_channels(allocator, reduced, track_names, gone);
	return removed;
}

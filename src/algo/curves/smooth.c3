<*
 Smoothing: a clip's jitter filtered out of its keys.

 A generated motion is a sequence of guesses, one a frame, and the guesses
 disagree by a little from frame to frame: a hand that trembles, a head that
 nods at thirty hertz, a spine that buzzes. None of that is in the motion meant,
 and none of it can be keyed away by hand on a clip with a key every frame.

 `clip_smoothed` replaces every key's value with a Gaussian average of the curve
 round it — the same keys, at the same times, with the same interpolation, so the
 sheet looks as it did and only the values move. Rotations are averaged as small
 turns away from the key's own (the log of the difference), which is what makes
 an average of rotations a rotation, with each sample brought to the key's
 hemisphere first; slides are averaged as they are.

 **What it leaves alone.** A joint outside the mask; a key outside the range, with
 the filter eased in and out over a window's width at the range's edges; and —
 with `hold_contacts` — a joint at a time its ground window has it down or a pin
 holds it, so a planted foot is not dragged by the average of the swing either side.
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;

// How finely the curve is read for the average, seconds: the import's own key
// spacing for a generated clip.
const float SMOOTH_STEP = 1.0f / 120.0f;

<*
 The clip with its keys' values smoothed. A deep copy; `source` is untouched.

 	`AnimTemplate calm = clip_smoothed(mem, clip, {}, 0.1f, -1.0f, -1.0f, true);`

 @param joints : `Only these joints; empty for every joint the clip keys.`
 @param window : `Seconds the filter reaches over: twice its standard deviation.`
 @param start : `Seconds the smoothed range starts at; negative, with end, for the whole clip.`
 @param end : `Seconds the smoothed range ends at.`
 @param hold_contacts : `Leave a joint alone while its ground window or a pin holds it.`
*>
fn AnimTemplate clip_smoothed(Allocator allocator, AnimTemplate source, String[] joints, float window,
	float start, float end, bool hold_contacts)
{
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)source.keyframes.len);
	foreach (usz k, frame : source.keyframes) frames[k] = keyframe_copy(allocator, frame);
	AnimTemplate out = clip_with_frames(allocator, source, frames, source.duration);
	if (source.duration <= 0.0f || source.keyframes.len < 3 || !(window > 0.0f)) return out;

	AnimTemplate probe = source;
	probe.owned = false;
	probe.tracks = {};
	probe.tracks_compiled = false;
	probe.compile_tracks(mem);
	defer free_tracks(probe);

	// The curve read once per joint, every step across the clip.
	usz samples = (usz)math::ceil(source.duration / SMOOTH_STEP) + 1;
	usz tracks = probe.tracks.len;
	Quaternionf[] turns = alloc::new_array(mem, Quaternionf, (sz)(tracks * samples));
	defer alloc::free(mem, turns);
	Vec3[] slides = alloc::new_array(mem, Vec3, (sz)(tracks * samples));
	defer alloc::free(mem, slides);
	bool[] wanted = alloc::new_array(mem, bool, (sz)tracks);
	defer alloc::free(mem, wanted);
	foreach (usz t, track : probe.tracks)
	{
		wanted[t] = joints.len == 0;
		foreach (name : joints) if (name == track.joint_name) wanted[t] = true;
		if (!wanted[t]) continue;
		for (usz s = 0; s < samples; s++)
		{
			float at = math::min((float)s * SMOOTH_STEP, source.duration);
			if (track.rotations.len > 0) turns[t * samples + s] = probe.rotation_at(track.joint_name, at);
			if (track.translations.len > 0) slides[t * samples + s] = probe.translation_at(track.joint_name, at);
		}
	}

	// The Gaussian, its reach two standard deviations either side.
	float sigma = window * 0.5f;
	sz reach = (sz)math::ceil(window / SMOOTH_STEP);
	float[] weights = alloc::new_array(mem, float, (sz)(2 * reach + 1));
	defer alloc::free(mem, weights);
	for (sz i = -reach; i <= reach; i++)
	{
		float x = (float)i * SMOOTH_STEP / sigma;
		weights[(usz)(i + reach)] = (float)math::exp(-0.5f * x * x);
	}

	bool whole = start < 0.0f || !(end > start);
	foreach (&frame : out.keyframes)
	{
		float gain = whole ? 1.0f : smooth_range_gain(frame.time, start, end, window);
		if (!(gain > 0.0f)) continue;
		sz centre = (sz)math::round(frame.time / SMOOTH_STEP);
		foreach (&dot : frame.dots)
		{
			usz t = 0;
			while (t < tracks && probe.tracks[t].joint_name != dot.joint_name) t++;
			if (t >= tracks || !wanted[t]) continue;
			if (hold_contacts && smooth_holds(source, dot.joint_name, frame.time)) continue;

			Quaternionf here = quaternion::from_axis_angle{float}(dot.axis.normalize(), dot.angle);
			Vec3 turned;
			Vec3 slid;
			float total = 0.0f;
			for (sz i = -reach; i <= reach; i++)
			{
				usz s = smooth_sample(centre + i, samples, source.loop);
				float w = weights[(usz)(i + reach)];
				if (dot.keys_rotation())
				{
					Quaternionf q = turns[t * samples + s];
					if (q.v.dot(here.v) < 0.0f) q = -q;
					turned += rotation_vector(here.invert().mul(q)) * w;
				}
				if (dot.keys_translation()) slid += slides[t * samples + s] * w;
				total += w;
			}
			if (!(total > 0.0f)) continue;
			if (dot.keys_rotation())
			{
				Quaternionf calm = here.mul(from_rotation_vector(turned / total * gain)).normalize();
				axis_angle_of(calm, &dot.axis, &dot.angle);
			}
			if (dot.keys_translation()) dot.move = dot.move + (slid / total - dot.move) * gain;
		}
	}
	return out;
}

// The sample at index `i`, wrapped on a loop and held at the ends otherwise.
fn usz smooth_sample(sz i, usz samples, bool loop) @local
{
	sz count = (sz)samples;
	if (loop)
	{
		// The last sample is the first again on a loop, so the cycle is one shorter.
		sz cycle = count > 1 ? count - 1 : 1;
		sz wrapped = i % cycle;
		if (wrapped < 0) wrapped += cycle;
		return (usz)wrapped;
	}
	return (usz)math::clamp(i, (sz)0, count - 1);
}

// 1 inside the range, easing to 0 over `window` seconds outside it.
fn float smooth_range_gain(float time, float start, float end, float window) @local
{
	if (time >= start && time <= end) return 1.0f;
	float away = time < start ? start - time : time - end;
	float x = math::clamp(1.0f - away / window, 0.0f, 1.0f);
	return x * x * (3.0f - 2.0f * x);
}

// Whether the clip holds the joint at `time`: its ground window has it down, or a pin.
fn bool smooth_holds(AnimTemplate clip, String joint, float time) @local
{
	float phase = clip.phase_at(time);
	foreach (foot : clip.ground.feet)
	{
		if (!foot.off_floor && foot.joint == joint && foot.planted(phase)) return true;
	}
	foreach (&pin : clip.pins)
	{
		if (pin.joint == joint && !pin.mute && pin.weight_at(time, clip.duration, clip.loop) > 0.0f) return true;
	}
	return false;
}

// A unit quaternion's turn as a rotation vector: the axis times the angle.
fn Vec3 rotation_vector(Quaternionf q) @local
{
	if (q.v.w < 0.0f) q = -q;
	Vec3 axis = { q.v.x, q.v.y, q.v.z };
	float s = axis.length();
	if (s < 1.0e-9f) return axis * 2.0f;
	float angle = 2.0f * (float)math::atan2(s, q.v.w);
	return axis * (angle / s);
}

// The inverse of `rotation_vector`.
fn Quaternionf from_rotation_vector(Vec3 v) @local
{
	float angle = v.length();
	if (angle < 1.0e-9f) return { v.x * 0.5f, v.y * 0.5f, v.z * 0.5f, 1.0f };
	float s = (float)math::sin(angle * 0.5f) / angle;
	return { v.x * s, v.y * s, v.z * s, (float)math::cos(angle * 0.5f) };
}

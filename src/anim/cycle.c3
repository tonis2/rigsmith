<*
 Loop extraction: a seamless cycle cut out of a take.

 A generated walk is a person walking for five seconds — starting from a stand,
 settling into a stride, maybe slowing at the end — not a cycle. The cycle is in
 there: somewhere two instants a stride apart hold nearly the same pose. Finding
 them, cutting between them and closing the seam is what `clip_cycle` does, and
 what used to need a script run outside the app.

 1. **The curve is read once**, every joint's turn every `CYCLE_STEP` seconds.
 2. **The best seam** is the start and period whose two poses differ least — the
    summed squared angle between them over every joint — with the poses a few
    samples either side compared too, so the motion matches in speed through the
    seam and not only in pose.
 3. **The seam is crossfaded**: the last `crossfade` seconds blend into what led
    into the start, a smoothstep from the cycle's own motion to the take's, which
    makes the end flow into the beginning in position and velocity both.
 4. **It closes**: a key at the end restates the first, and the root's sideways
    drift is taken off the middle so the figure stays where it stands.

 The cycle is written as plain keys every `CYCLE_STEP` seconds, looping and
 linear; the caller thins them (`clip_keys_reduced`).
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;

// How finely the take is read and the cycle written, seconds.
const float CYCLE_STEP = 1.0f / 60.0f;
// How many samples either side of the seam are compared for speed.
const usz CYCLE_SPEED_REACH = 3;

// Where `clip_cycle` cut: the take's seconds the cycle starts at and lasts, and how
// far apart the poses at its two ends were before the crossfade, as the root mean
// square angle per joint in radians.
struct CycleCut
{
	float start;
	float period;
	float seam;
}

<*
 A looping cycle cut out of `source`.

 	`AnimTemplate? walk = clip_cycle(mem, take, 0.9f, 1.3f, 0.5f, 4.5f, 0.25f, "hips", "Walk", &cut);`

 @param period_min : `The shortest a cycle may last, seconds.`
 @param period_max : `The longest.`
 @param from_min : `The earliest the cycle may start, seconds into the take.`
 @param from_max : `The latest.`
 @param crossfade : `Seconds before the seam blended into what led into the start; clamped to half the period.`
 @param root : `The joint whose sideways drift is taken off the middle; "" for none.`
 @param name : `The cycle's name.`
 @return? CYCLE_TOO_SHORT : `The take cannot hold a cycle of that length starting there.`
*>
fn AnimTemplate? clip_cycle(Allocator allocator, AnimTemplate source, float period_min, float period_max,
	float from_min, float from_max, float crossfade, String root, String name, CycleCut* cut)
{
	if (source.duration <= 0.0f || source.keyframes.len < 2) return CYCLE_TOO_SHORT~;

	AnimTemplate probe = source;
	probe.owned = false;
	probe.tracks = {};
	probe.tracks_compiled = false;
	probe.compile_tracks(mem);
	defer free_tracks(probe);

	usz samples = (usz)math::floor(source.duration / CYCLE_STEP) + 1;
	usz tracks = probe.tracks.len;
	Quaternionf[] turns = alloc::new_array(mem, Quaternionf, (sz)(tracks * samples));
	defer alloc::free(mem, turns);
	foreach (usz t, track : probe.tracks)
	{
		for (usz s = 0; s < samples; s++)
		{
			float at = math::min((float)s * CYCLE_STEP, source.duration);
			if (track.rotations.len > 0) turns[t * samples + s] = probe.rotation_at(track.joint_name, at);
		}
	}

	usz shortest = (usz)math::max(2.0f, math::round(period_min / CYCLE_STEP));
	usz longest = (usz)math::round(period_max / CYCLE_STEP);
	usz earliest = (usz)math::max(0.0f, math::round(from_min / CYCLE_STEP));
	usz latest = (usz)math::round(from_max / CYCLE_STEP);
	usz reach = CYCLE_SPEED_REACH;
	earliest = math::max(earliest, reach);

	float best = math::FLOAT_MAX;
	usz best_start = 0;
	usz best_period = 0;
	for (usz s = earliest; s <= latest; s++)
	{
		for (usz p = shortest; p <= longest; p++)
		{
			if (s + p + reach >= samples) break;
			float cost = cycle_distance(turns, probe.tracks, samples, s, s + p);
			if (cost >= best) continue;
			cost += 0.5f * (cycle_distance(turns, probe.tracks, samples, s - reach, s + p - reach)
				+ cycle_distance(turns, probe.tracks, samples, s + reach, s + p + reach));
			if (cost >= best) continue;
			best = cost;
			best_start = s;
			best_period = p;
		}
	}
	if (best_period == 0) return CYCLE_TOO_SHORT~;

	usz rotating = 0;
	foreach (track : probe.tracks) if (track.rotations.len > 0) rotating++;
	float seam = (float)math::sqrt(cycle_distance(turns, probe.tracks, samples, best_start, best_start + best_period)
		/ (float)math::max(rotating, (usz)1));
	*cut = { (float)best_start * CYCLE_STEP, (float)best_period * CYCLE_STEP, seam };

	// The crossfade reaches back from the seam into what led into the start.
	usz fade = (usz)math::round(math::max(crossfade, 0.0f) / CYCLE_STEP);
	fade = math::min(fade, best_period / 2);
	fade = math::min(fade, best_start);

	usz count = best_period;
	AnimKeyframe[] frames = cycle_frames(allocator, source, best_start, count, fade, root);

	float period = (float)count * CYCLE_STEP;
	AnimTemplate out = clip_with_frames(allocator, source, frames, period, name);
	// A keyed layer is cut where the base is, crossfade and all, so a tail lifted
	// into one still moves with the stride it came from. Its range and fades move
	// with the start; generators are stated per cycle and need nothing.
	free_layers(allocator, out.layers);
	out.layers = layers_copy(allocator, source.layers, 1.0f, -cut.start);
	foreach (usz i, &layer : out.layers)
	{
		if (layer.kind != KEYED || layer.own_clock()) continue;
		AnimTemplate keys = { .duration = source.duration, .loop = source.loop, .blend = source.blend,
			.keyframes = source.layers[i].keyframes };
		AnimKeyframe[] cycled = cycle_frames(allocator, keys, best_start, count, fade, "");
		foreach (&frame : layer.keyframes) frame.free(allocator);
		if (layer.keyframes.len > 0) alloc::free(allocator, layer.keyframes);
		layer.keyframes = cycled;
	}
	out.loop = true;
	out.blend = LINEAR;
	// A take's contacts and pins are timed on the take; the cycle has its own.
	out.ground.free(allocator);
	out.ground = {};
	free_pins(allocator, out.pins);
	out.pins = {};
	free_anim_paths(allocator, out.paths);
	out.paths = {};
	out.gait.free(allocator);
	return out;
}

<*
 The cycle written as keys: `source`'s curve read every `CYCLE_STEP` from sample
 `start` for `count` steps, the last `fade` blended toward what led into the
 start, and a closing key restating the first. `root`'s sideways drift is taken
 off the middle; "" for none. A track the source keys only one channel of keeps
 that one.
*>
fn AnimKeyframe[] cycle_frames(Allocator allocator, AnimTemplate source, usz start, usz count, usz fade, String root) @local
{
	AnimTemplate probe = source;
	probe.owned = false;
	probe.tracks = {};
	probe.tracks_compiled = false;
	probe.compile_tracks(mem);
	defer free_tracks(probe);
	usz tracks = probe.tracks.len;

	// The cycle's own samples, the last `fade` blended toward the take's lead-in.
	Quaternionf[] cycle_turns = alloc::new_array(mem, Quaternionf, (sz)(tracks * count));
	defer alloc::free(mem, cycle_turns);
	Vec3[] cycle_slides = alloc::new_array(mem, Vec3, (sz)(tracks * count));
	defer alloc::free(mem, cycle_slides);
	for (usz m = 0; m < count; m++)
	{
		usz from = start + m;
		float blend = 0.0f;
		if (fade > 0 && m >= count - fade)
		{
			float x = (float)(m - (count - fade)) / (float)fade;
			blend = x * x * (3.0f - 2.0f * x);
		}
		float at = math::min((float)from * CYCLE_STEP, source.duration);
		float lead_at = blend > 0.0f ? math::min((float)(from - count) * CYCLE_STEP, source.duration) : 0.0f;
		for (usz t = 0; t < tracks; t++)
		{
			AnimTrack track = probe.tracks[t];
			Quaternionf own = track.rotations.len > 0 ? probe.rotation_at(track.joint_name, at) : quaternion::IDENTITY;
			Vec3 slid = track.translations.len > 0 ? probe.translation_at(track.joint_name, at) : (Vec3){};
			if (blend > 0.0f)
			{
				Quaternionf lead_turn = track.rotations.len > 0 ? probe.rotation_at(track.joint_name, lead_at) : quaternion::IDENTITY;
				Vec3 lead_slide = track.translations.len > 0 ? probe.translation_at(track.joint_name, lead_at) : (Vec3){};
				own = slerp_short(own, lead_turn, blend);
				slid = slid + (lead_slide - slid) * blend;
			}
			cycle_turns[t * count + m] = own;
			cycle_slides[t * count + m] = slid;
		}
	}

	// The root stays where it stands: its sideways drift off the middle.
	for (usz t = 0; t < tracks; t++)
	{
		if (root.len == 0 || probe.tracks[t].joint_name != root || probe.tracks[t].translations.len == 0) continue;
		Vec3 mean;
		for (usz m = 0; m < count; m++) mean += cycle_slides[t * count + m];
		mean /= (float)count;
		for (usz m = 0; m < count; m++)
		{
			cycle_slides[t * count + m].x -= mean.x;
			cycle_slides[t * count + m].z -= mean.z;
		}
	}

	// Keys every step, and a closing one restating the first.
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)(count + 1));
	for (usz m = 0; m <= count; m++)
	{
		usz from = m == count ? 0 : m;
		AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, (sz)tracks);
		for (usz t = 0; t < tracks; t++)
		{
			AnimTrack track = probe.tracks[t];
			bool rotates = track.rotations.len > 0;
			bool slides_too = track.translations.len > 0;
			AnimKeyDot dot = {
				.joint_name = track.joint_name.copy(allocator),
				.channels = rotates ? (slides_too ? BOTH : ROTATION) : TRANSLATION,
				.move = slides_too ? cycle_slides[t * count + from] : (Vec3){},
				.bone = cycle_bone(source, track.joint_name),
			};
			if (rotates) axis_angle_of(cycle_turns[t * count + from], &dot.axis, &dot.angle);
			dots[t] = dot;
		}
		frames[m] = { .time = (float)m * CYCLE_STEP, .dots = dots };
	}
	return frames;
}

faultdef CYCLE_TOO_SHORT;

// The summed squared angle between two samples' turns over every rotating track.
fn float cycle_distance(Quaternionf[] turns, AnimTrack[] tracks, usz samples, usz a, usz b) @local
{
	float total = 0.0f;
	foreach (usz t, track : tracks)
	{
		if (track.rotations.len == 0) continue;
		float d = math::min(1.0f, math::abs(turns[t * samples + a].v.dot(turns[t * samples + b].v)));
		float angle = 2.0f * (float)math::acos(d);
		total += angle * angle;
	}
	return total;
}

// The bone direction the source keys a joint's turns against, so the cycle is
// carried onto another rig the way the take was.
fn Vec3 cycle_bone(AnimTemplate source, String joint) @local
{
	foreach (frame : source.keyframes)
	{
		foreach (dot : frame.dots) if (dot.joint_name == joint) return dot.bone;
	}
	return {};
}

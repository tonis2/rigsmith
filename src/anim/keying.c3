<*
 Writing a pose down as a keyframe, and rewriting a clip that holds them.

 	`AnimKeyframe key = keyframe_of_pose(mem, pose, names, bones, height, 0.25f);`

 Two callers wanted the same conversion and only one of them had it. The physics
 bake walks a simulation and writes a key per sample (`anim/bake.c3`); the
 timeline's **Key** button takes the pose the user has posed by hand and writes
 one. Both are `rig::Pose` → `AnimKeyDot[]`, and the four decisions in that
 conversion — the axis-angle form, offsets as a fraction of rig height, explicit
 rest values, and the bone direction recorded per entry so the clip retargets —
 are decisions about the *format* rather than about physics. So they live here
 and `bake_keyframe` calls them, which is what makes a hand-keyed pose and a
 baked one produce byte-identical entries.

 **This primitive writes a complete pose.** Every named joint is emitted,
 including explicit identity rotation and zero translation. Higher-level Key
 All/Selected/Changed operations apply their channel masks afterwards. An
 omitted joint or channel contributes no key at this time; its own surrounding
 keys determine the sampled value, independently of unrelated global keys.

 The rewriters below are the other half. Every timeline edit — key, delete,
 move, retime, ease, close the loop — is expressed as *build a new
 `AnimTemplate` from an old one*, because `put_authored_clip` swaps a whole clip
 and records one undo entry for it (`app/library.c3`). That makes every edit one
 Ctrl+Z with no new `EditKind`, and it is why none of these mutate in place.

 All of it is `AppState`-free on purpose: `make-anims` builds `src/anim/**`
 without `src/app/`, and the clip rewriters are exactly what an offline pack
 generator wants.
*>
module crig;

import rig;


import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 How close two keyframe times have to be to count as the same instant.

 Half a millisecond, which is well under a frame at any rate anyone animates at
 and well over the error in a playhead dragged to a pixel. It is the tolerance
 keying twice at one time uses to mean "replace", and the one a key dragged onto
 a neighbour is refused by.

 Not `ANIM_SAME_POSE_EPSILON`: that one compares rotations and offsets and is
 about whether two *poses* match. This is about the clock, and the two would
 drift apart the moment either was tuned for its own reason.
*>
const float ANIM_SAME_TIME = 5.0e-4f;

<*
 One complete pose written down as a keyframe.

 	`AnimKeyframe key = keyframe_of_pose(mem, pose, view.names, bones, height, t);`

 The result owns its strings and its array; `AnimTemplate.free` releases them
 when the clip holding it is freed.

 @param pose : `Parent-relative rotations and offsets, one per joint, in joint order. Sampled ungrounded — a key records the pose as authored, not as the floor solve left it, or playback would solve it twice.`
 @param names : `One name per joint, in joint order. An unnamed joint is one no clip can address, so it is not written out.`
 @param bones : `One direction per joint, from Skeleton.bone_directions. Short or empty writes zero, which means "do not retarget this entry".`
 @param height : `What offsets are divided by, to store them as a fraction of rig height. Zero or less reads as 1 — a flat rig has no length to state a fraction of, and dividing by it would write infinities into the file.`
 @param time : `Seconds from the start of the clip.`
*>
fn AnimKeyframe keyframe_of_pose(
	Allocator allocator,
	rig::Pose pose,
	String[] names,
	Vec3[] bones,
	float height,
	float time)
{
	float unit = height > 0.0f ? height : 1.0f;

	AnimDotList dots;
	dots.init(allocator);

	foreach (usz j, joint_name : names)
	{
		if (joint_name.len == 0 || j >= pose.rotations.len) continue;

		Vec3 axis;
		float angle;
		axis_angle_of(pose.rotations[j], &axis, &angle);
		Vec3 move = j < pose.offsets.len ? pose.offsets[j] / unit : (Vec3){ 0, 0, 0 };

		// Identity is explicit here. Callers selecting a sparse set of joints or
		// channels remove entries after this conversion.

		dots.push({
			.joint_name = joint_name.copy(allocator),
			.axis = axis,
			.angle = angle,
			.move = move,
			.bone = j < bones.len ? bones[j] : (Vec3){ 0, 0, 0 },
		});
	}

	AnimKeyframe frame = { .time = time, .dots = dots.to_array(allocator) };
	dots.free();
	return frame;
}

// Merge only the incoming channels. The old frame is borrowed, the incoming
// frame is consumed. Disjoint channels at one instant coexist; incoming values
// replace matching channels. The original timestamp remains the canonical one.
fn AnimKeyframe merge_key_channels(Allocator allocator, AnimKeyframe old, AnimKeyframe incoming) @local
{
	AnimDotList dots;
	dots.init(allocator);
	defer dots.free();
	foreach (dot : old.dots)
	{
		AnimKeyDot merged = dot;
		merged.joint_name = dot.joint_name.copy(allocator);
		foreach (next : incoming.dots)
		{
			if (next.joint_name != dot.joint_name) continue;
			if (next.channels != TRANSLATION)
			{
				merged.axis = next.axis;
				merged.angle = next.angle;
				merged.bone = next.bone;
				if (next.rotation_interpolation != INHERIT)
				{
					merged.rotation_interpolation = next.rotation_interpolation;
				}
				if (!next.rotation_ease.none()) merged.rotation_ease = next.rotation_ease;
			}
			if (next.channels != ROTATION)
			{
				merged.move = next.move;
				if (next.translation_interpolation != INHERIT)
				{
					merged.translation_interpolation = next.translation_interpolation;
				}
				if (!next.translation_ease.none()) merged.translation_ease = next.translation_ease;
			}
			if (next.channels != dot.channels) merged.channels = BOTH;
			break;
		}
		dots.push(merged);
	}
	foreach (dot : incoming.dots)
	{
		if (old.names(dot.joint_name))
		{
			if (dot.joint_name.len > 0) alloc::free(allocator, dot.joint_name.ptr);
		}
		else { dots.push(dot); }
	}
	if (incoming.dots.len > 0) alloc::free(allocator, incoming.dots);
	return { .time = old.time, .dots = dots.to_array(allocator) };
}

// ---------------------------------------------------------------------------
// Rewriting a clip
//
// Every one of these returns an owned `AnimTemplate` built from `source`, which
// is left alone. The caller lands it with `put_authored_clip`, and that is what
// makes it one undo entry.

<*
 This entry with its own copy of the joint name — every other field is a value.
 A whole-struct copy rather than a field list, so a field added to `AnimKeyDot`
 is carried without anyone remembering to.
*>
fn AnimKeyDot AnimKeyDot.copy(self, Allocator allocator)
{
	AnimKeyDot out = self;
	out.joint_name = self.joint_name.copy(allocator);
	return out;
}

<*
 A copy of this entry keeping only the channels asked for. A dropped channel's
 curve goes back to INHERIT, since it no longer keys anything.

 @require rotation || translation : `An entry keys at least one channel.`
*>
fn AnimKeyDot AnimKeyDot.narrowed(self, Allocator allocator, bool rotation, bool translation)
{
	AnimKeyDot out = self.copy(allocator);
	if (!rotation) { out.rotation_interpolation = INHERIT; out.rotation_ease = {}; }
	if (!translation) { out.translation_interpolation = INHERIT; out.translation_ease = {}; }
	out.channels = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION);
	return out;
}

<*
 A deep copy of one keyframe, strings and all.
*>
fn AnimKeyframe keyframe_copy(Allocator allocator, AnimKeyframe source)
{
	AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, (sz)source.dots.len);
	foreach (usz i, dot : source.dots) dots[i] = dot.copy(allocator);
	return { .time = source.time, .dots = dots };
}

<*
 A clip that is `source` in every respect but its keys and its length: the name,
 loop, blend and ground copied, `frames` taken over. What each rewriter here
 builds its answer on, so a field added to the clip is carried by all of them.

 @param name : `Empty keeps the source's name.`
*>
fn AnimTemplate clip_with_frames(Allocator allocator, AnimTemplate source, AnimKeyframe[] frames,
	float duration, String name = "")
{
	return {
		.name = (name.len > 0 ? name : source.name).copy(allocator),
		.duration = duration,
		.keyframes = frames,
		.loop = source.loop,
		.blend = source.blend,
		.ground = ground_copy(allocator, source.ground),
		.layers = layers_copy(allocator, source.layers),
		.aims = aims_copy(allocator, source.aims),
		.aim_targets = aim_targets_copy(allocator, source.aim_targets),
		.pins = pins_copy(allocator, source.pins),
		.owned = true,
	};
}

<*
 The ground spec copied so a rewritten clip owns its own.

 The solve is a fact about the rig a clip is played on rather than about the
 one it was written against, so a rewrite or a bake carries it rather than
 freezing it.
*>
fn AnimGround ground_copy(Allocator allocator, AnimGround ground)
{
	if (!ground.solves()) return { .floor = ground.floor, .floor_set = ground.floor_set };

	AnimFoot[] feet = alloc::new_array(allocator, AnimFoot, (sz)ground.feet.len);
	foreach (usz i, foot : ground.feet)
	{
		feet[i] = foot;
		feet[i].joint = foot.joint.copy(allocator);
	}
	return { .feet = feet, .floor = ground.floor, .floor_set = ground.floor_set };
}

<*
 A whole clip copied, optionally under another name.

 	`AnimTemplate mine = clip_copy(mem, *theirs);`

 What copy-on-edit is built from: a clip that lives in a library `.glb` is copied
 into the authored pack before the first edit, because the authored pack is the
 only one crig writes and rewriting somebody's library file is a different
 operation with a different failure mode.

 Owned throughout, so `AnimTemplate.free` releases all of it.

 @param name : `Empty keeps the source's name.`
*>
fn AnimTemplate clip_copy(Allocator allocator, AnimTemplate source, String name = "")
{
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)source.keyframes.len);
	foreach (usz i, frame : source.keyframes) frames[i] = keyframe_copy(allocator, frame);
	return clip_with_frames(allocator, source, frames, source.duration, name);
}

<*
 The clip with `key` put in at its own time, merging with any key already there.

 	`AnimTemplate next = clip_with_key(mem, *clip, keyframe_of_pose(...));`

 **Merge channels when the times match.** Two global keyframes at one instant
 are not allowed. Incoming joint channels replace only their matching channels;
 existing channels the operation did not key remain intact.

 `key` is taken over: its strings and array become the new clip's and are freed
 with it. A caller that wants to keep its own copy passes one.

 Times are compared with `ANIM_SAME_TIME`, not exactly. A playhead is a float
 arrived at by dragging, and two keys a millionth of a second apart are a clip
 nobody can select the first of.
*>
fn AnimTemplate clip_with_key(Allocator allocator, AnimTemplate source, AnimKeyframe key)
{
	// Where it goes, and whether it lands on one already there.
	usz at = source.keyframes.len;
	bool replaces = false;
	foreach (usz i, frame : source.keyframes)
	{
		if (math::abs(frame.time - key.time) < ANIM_SAME_TIME)
		{
			at = i;
			replaces = true;
			break;
		}
		if (frame.time > key.time)
		{
			at = i;
			break;
		}
	}

	usz count = replaces ? source.keyframes.len : source.keyframes.len + 1;
	if (replaces) key = merge_key_channels(allocator, source.keyframes[at], key);
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)count);

	usz write = 0;
	foreach (usz i, frame : source.keyframes)
	{
		if (i == at)
		{
			frames[write++] = key;
			if (replaces) continue;
		}
		frames[write++] = keyframe_copy(allocator, frame);
	}
	if (at >= source.keyframes.len) frames[write++] = key;

	// A key past the end lengthens the clip. The alternative — refusing, or
	// silently clamping it to the duration — would make the playhead a place you
	// cannot key at, which is the one thing a timeline must not have.
	return clip_with_frames(allocator, source, frames, math::max(source.duration, key.time));
}

<*
 The clip stretched or squeezed to a new duration.

 Key times scale with it, so the motion is the same shape run at another speed —
 which is what a person changing a walk's duration means. Setting the number
 without moving the keys would leave the motion where it was and add or remove
 dead air at the end, and a dead tail is a thing to author rather than a thing to
 arrive at by typing.

 @return `The source copied unchanged when either duration is non-finite or not positive, or when squeezing would make two distinct keys collide within ANIM_SAME_TIME.`
*>
fn AnimTemplate clip_retimed(Allocator allocator, AnimTemplate source, float duration)
{
	if (!math::is_finite(duration) || duration <= 0.0f
		|| !math::is_finite(source.duration) || source.duration <= 0.0f)
	{
		return clip_copy(allocator, source);
	}

	float scale = duration / source.duration;
	for (usz i = 1; i < source.keyframes.len; i++)
	{
		if ((source.keyframes[i].time - source.keyframes[i - 1].time) * scale < ANIM_SAME_TIME)
		{
			return clip_copy(allocator, source);
		}
	}
	AnimTemplate out = clip_copy(allocator, source);
	out.duration = duration;
	// Layers keep their place in the cycle: their times scale with the keys.
	free_layers(allocator, out.layers);
	out.layers = layers_copy(allocator, source.layers, scale);
	free_aim_targets(allocator, out.aim_targets);
	out.aim_targets = aim_targets_copy(allocator, source.aim_targets, scale);
	// A pin's window and blend scale with the keys, so it holds the same stretch of motion.
	free_pins(allocator, out.pins);
	out.pins = pins_copy(allocator, source.pins, scale);
	foreach (usz i, frame : out.keyframes)
	{
		out.keyframes[i].time = frame.time * scale;
	}
	// Ground contacts are stored as normalized cycle phases, not seconds. Their
	// down/up values deliberately remain unchanged as the keys move.
	return out;
}

<*
 The clip cut down to the span between `start` and `end`.

 	`AnimTemplate part = clip_cropped(mem, *clip, 0.5f, 1.25f);`

 "Keep this range": the one destructive timing edit the format needs beside
 stretching. A take recorded with a settle at either end, an import carrying a
 second of idle before the action, one cycle lifted out of a longer capture.
 Keys inside the range are kept and rebased so `start` becomes zero, keys
 outside it are dropped, and the duration becomes the range.

 **The motion at the two edges is restated.** A channel the clip drives gets
 an explicit key at each edge, sampled from the source, when it has none
 there already — so the cropped clip starts and ends exactly where the take
 was at those instants rather than where its nearest surviving key happens to
 be. Channels are restated one by one: a joint keyed only in rotation gets a
 rotation edge key and no translation, so the sparse shape of the clip
 survives. Each restated key carries the outgoing curve of the span it was cut
 from, so a hold stays a hold.

 **Ground contacts move with the seconds.** A window is stated in cycle phase
 and the cycle has changed, so each foot's window becomes the part of it inside
 the range, as a fraction of the range. A window covering both ends of the
 range and not the middle comes back as a wrapping one, which is what it is. A
 foot never down inside the range is dropped, and with it the keep-out its
 entry gave the solve.

 Nothing else changes: name, loop, blend and floor are copied. A cropped cycle
 is unlikely to close on itself any more; that is the author's call, and Close
 loop is there for it.

 @return `The source copied unchanged for a range outside the clip, shorter than two ANIM_SAME_TIME, or from which no key would survive.`
*>
fn AnimTemplate clip_cropped(Allocator allocator, AnimTemplate source, float start, float end)
{
	if (!math::is_finite(start) || !math::is_finite(end)
		|| start < 0.0f || end > source.duration + ANIM_SAME_TIME
		|| end - start < ANIM_SAME_TIME * 2.0f)
	{
		return clip_copy(allocator, source);
	}
	end = math::min(end, source.duration);
	float length = end - start;

	usz kept;
	foreach (frame : source.keyframes) if (between(frame.time, start, end)) kept++;
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)kept);
	usz write;
	foreach (frame : source.keyframes)
	{
		if (!between(frame.time, start, end)) continue;
		frames[write] = keyframe_copy(allocator, frame);
		frames[write].time = math::clamp(frame.time - start, 0.0f, length);
		write++;
	}

	AnimTemplate out = {
		.name = source.name.copy(allocator),
		.duration = length,
		.keyframes = frames,
		.loop = source.loop,
		.blend = source.blend,
		.ground = ground_cropped(allocator, source.ground, source.duration, start, end),
		.layers = layers_copy(allocator, source.layers, 1.0f, -start),
		.aims = aims_copy(allocator, source.aims),
		.aim_targets = aim_targets_copy(allocator, source.aim_targets, 1.0f, -start),
		.pins = pins_copy(allocator, source.pins, 1.0f, -start, length),
		.owned = true,
	};
	out = edge_restated(allocator, out, source, start, 0.0f);
	out = edge_restated(allocator, out, source, end, length);
	if (out.keyframes.len == 0)
	{
		out.free(allocator);
		return clip_copy(allocator, source);
	}
	return out;
}

<*
 The clip with the span between `start` and `end` taken out and the gap closed.

 	`AnimTemplate shorter = clip_range_cut(mem, *clip, 0.5f, 1.25f);`

 "Remove this range": a stumble in the middle of a take, a pause nobody wants.
 Keys strictly inside the range are dropped, keys after it move earlier by its
 length, and the duration shrinks by the same. A key at either end of the
 range is kept — the two are what remain adjacent once the middle is gone —
 and when both exist they land on one instant, where the later one's channels
 win, because that is the key the motion goes on from.

 **Nothing is restated.** A crop has to state what the take was doing at its
 new edges; a cut joins two parts of the same take, and the motion across the
 join is whatever the surviving keys on either side interpolate. Sampling the
 old poses at the seam and writing them in would put a jump where the join
 is, which is the one thing a cut in an animation should not do. Holds
 survive: a held channel whose key sits before the range is still held after
 it.

 Ground contacts are remapped the same way the keys are: a window's seconds
 before the range stay, seconds inside it collapse onto the seam, seconds after
 it move up. A foot whose whole window was inside the range is dropped.

 @return `The source copied unchanged for a range outside the clip, shorter than two ANIM_SAME_TIME, that would leave the clip no length, or from which no key would survive.`
*>
fn AnimTemplate clip_range_cut(Allocator allocator, AnimTemplate source, float start, float end)
{
	if (!math::is_finite(start) || !math::is_finite(end)
		|| start < 0.0f || end > source.duration + ANIM_SAME_TIME
		|| end - start < ANIM_SAME_TIME * 2.0f)
	{
		return clip_copy(allocator, source);
	}
	end = math::min(end, source.duration);
	float removed = end - start;
	float length = source.duration - removed;
	if (length < ANIM_SAME_TIME * 2.0f) return clip_copy(allocator, source);

	// The two edge keys can only collide with each other, so the survivors are
	// gathered in order and the later edge key merged in through
	// `clip_with_key`, which is the one place a same-time merge is written.
	AnimKeyframe at_end = {};
	bool has_end;
	usz kept;
	foreach (frame : source.keyframes)
	{
		if (math::abs(frame.time - end) < ANIM_SAME_TIME) { has_end = true; continue; }
		if (frame.time > start + ANIM_SAME_TIME && frame.time < end) continue;
		kept++;
	}
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)kept);
	usz write;
	foreach (frame : source.keyframes)
	{
		if (math::abs(frame.time - end) < ANIM_SAME_TIME)
		{
			at_end = keyframe_copy(allocator, frame);
			at_end.time = start;
			continue;
		}
		if (frame.time > start + ANIM_SAME_TIME && frame.time < end) continue;
		frames[write] = keyframe_copy(allocator, frame);
		if (frame.time > end) frames[write].time = frame.time - removed;
		write++;
	}

	AnimTemplate out = {
		.name = source.name.copy(allocator),
		.duration = length,
		.keyframes = frames,
		.loop = source.loop,
		.blend = source.blend,
		.ground = ground_cut(allocator, source.ground, source.duration, start, end),
		.layers = layers_copy(allocator, source.layers),
		.aims = aims_copy(allocator, source.aims),
		.aim_targets = aim_targets_copy(allocator, source.aim_targets),
		.pins = pins_cut(allocator, source.pins, start, end),
		.owned = true,
	};
	if (has_end)
	{
		AnimTemplate joined = clip_with_key(allocator, out, at_end);
		out.free(allocator);
		out = joined;
	}
	if (out.keyframes.len == 0)
	{
		out.free(allocator);
		return clip_copy(allocator, source);
	}
	return out;
}

// Inside the range, with a key sitting on either edge counted in.
fn bool between(float time, float start, float end) @local
{
	return time > start - ANIM_SAME_TIME && time < end + ANIM_SAME_TIME;
}

<*
 `built` with every channel `source` drives given a key at `at_built`, sampled
 from `source` at `at_source`, unless it has one there already.

 The edge rule of `clip_cropped`, stated once for both edges. The sample comes
 through `entry_at`, so it is the value the take showed at that instant — a
 held channel's held value, a curve's point along it — and the span's own
 outgoing interpolation comes with it. Every driven joint is walked and the
 channels it lacks a key for are gathered, one entry per joint; a joint with
 both channels keyed there contributes nothing.

 `built` is consumed and the result returned in its place.
*>
fn AnimTemplate edge_restated(
	Allocator allocator,
	AnimTemplate built,
	AnimTemplate source,
	float at_source,
	float at_built) @local
{
	sz on_edge = -1;
	foreach (usz i, frame : built.keyframes)
	{
		if (math::abs(frame.time - at_built) < ANIM_SAME_TIME) { on_edge = (sz)i; break; }
	}

	AnimDotList entries;
	entries.init(allocator);
	defer entries.free();
	foreach (frame : source.keyframes) foreach (dot : frame.dots)
	{
		bool seen;
		foreach (held : entries.array_view()) if (held.joint_name == dot.joint_name) { seen = true; break; }
		if (seen) continue;

		// Driven anywhere in the source, and not already keyed on this edge.
		bool rotation = source.channel_count(dot.joint_name, true) > 0;
		bool translation = source.channel_count(dot.joint_name, false) > 0;
		if (on_edge >= 0)
		{
			AnimKeyDot ignored;
			if (rotation && built.keyframes[(usz)on_edge].channel_dot(dot.joint_name, true, &ignored)) rotation = false;
			if (translation && built.keyframes[(usz)on_edge].channel_dot(dot.joint_name, false, &ignored)) translation = false;
		}
		if (!rotation && !translation) continue;

		AnimKeyDot value = source.entry_at(dot.joint_name, at_source);
		value.joint_name = dot.joint_name.copy(allocator);
		value.channels = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION);
		if (!rotation) value.rotation_interpolation = INHERIT;
		if (!translation) value.translation_interpolation = INHERIT;
		entries.push(value);
	}
	if (entries.len() == 0) return built;

	AnimKeyframe edge = { .time = at_built, .dots = entries.to_array(allocator) };
	AnimTemplate out = clip_with_key(allocator, built, edge);
	built.free(allocator);
	return out;
}

<*
 A ground spec's windows restated for the span between `start` and `end`, as
 `clip_cropped` needs them.

 A window is a cyclic interval of the old cycle. Its intersection with the
 range is at most two pieces, and two only when it covers both ends of the
 range and not the middle — which the new window states by wrapping. A foot
 whose window misses the range is left out.
*>
fn AnimGround ground_cropped(Allocator allocator, AnimGround ground, float duration, float start, float end) @local
{
	if (!ground.solves() || duration <= 0.0f) return {};
	float length = end - start;

	AnimFootList feet;
	feet.init(allocator);
	foreach (foot : ground.feet)
	{
		float down = foot.down * duration;
		float up = foot.up * duration;
		// One interval, running past the cycle's end when the window wraps.
		if (up <= down) up += duration;

		// This turn of the window against the range, and the turn before it.
		float a1 = math::max(down, start);
		float b1 = math::min(up, end);
		float a2 = math::max(down - duration, start);
		float b2 = math::min(up - duration, end);
		bool first = b1 > a1;
		bool second = b2 > a2;
		if (!first && !second) continue;

		AnimFoot kept = { .joint = foot.joint.copy(allocator), .off_floor = foot.off_floor };
		if (first && second)
		{
			// Down through the end of the range and again from its start: the
			// later piece opens the window and the earlier one closes it.
			kept.down = (a1 - start) / length;
			kept.up = (b2 - start) / length;
		}
		else if (first)
		{
			kept.down = (a1 - start) / length;
			kept.up = (b1 - start) / length;
		}
		else
		{
			kept.down = (a2 - start) / length;
			kept.up = (b2 - start) / length;
		}
		feet.push(kept);
	}
	AnimGround out = { .feet = feet.to_array(allocator), .floor = ground.floor, .floor_set = ground.floor_set };
	feet.free();
	return out;
}

<*
 A ground spec's windows with the span between `start` and `end` taken out,
 as `clip_range_cut` needs them.

 Each edge of a window is moved the way a key at that second would be: left
 alone before the range, onto the seam inside it, earlier after it. A window
 that collapses to nothing is a foot the cut removed, and one that comes to
 cover the whole of the shorter cycle is written as the whole of it.
*>
fn AnimGround ground_cut(Allocator allocator, AnimGround ground, float duration, float start, float end) @local
{
	if (!ground.solves() || duration <= 0.0f) return {};
	float removed = end - start;
	float length = duration - removed;

	AnimFootList feet;
	feet.init(allocator);
	foreach (foot : ground.feet)
	{
		float down = foot.down * duration;
		float up = foot.up * duration;
		bool wraps = up <= down;
		float down_after = cut_second(down, start, end);
		float up_after = wraps
			? cut_second(up, start, end) + length
			: cut_second(up, start, end);
		float span = up_after - down_after;
		if (span <= 0.0f) continue;

		AnimFoot kept = { .joint = foot.joint.copy(allocator), .off_floor = foot.off_floor };
		if (span >= length)
		{
			kept.down = 0.0f;
			kept.up = 1.0f;
		}
		else
		{
			kept.down = down_after / length;
			kept.up = (up_after > length ? up_after - length : up_after) / length;
		}
		feet.push(kept);
	}
	AnimGround out = { .feet = feet.to_array(allocator), .floor = ground.floor, .floor_set = ground.floor_set };
	feet.free();
	return out;
}

// Where a second of the old clip lands once the range is taken out.
fn float cut_second(float second, float start, float end) @local
{
	if (second <= start) return second;
	if (second >= end) return second - (end - start);
	return start;
}

<*
 The clip with its first pose restated at the end, so a loop does not jump.

 The loop-seam fix. A cycle whose last key is not its first pose snaps on the
 wrap, which reads as a hitch in the walk and is the single most common thing
 wrong with a hand-keyed loop.

 Samples the opening pose across every driven channel, not just the first
 sparse frame. Does nothing when the final key already states that complete
 opening pose with the same channel masks.

 @return `The source copied unchanged when it does not loop, has no keys, or already closes.`
*>
fn AnimTemplate clip_seam_closed(Allocator allocator, AnimTemplate source)
{
	if (!source.loop || source.keyframes.len == 0) return clip_copy(allocator, source);

	AnimKeyframe closing;
	if (!seam_closing_key(allocator, source, &closing)) return clip_copy(allocator, source);

	// The restated pose goes one span past the last key rather than at `duration`,
	// when the last key already sits at the end: a key *on* the duration and a
	// closing key are the same instant. Retain the existing final authored pose
	// and extend the clip rather than overwriting it with the opening pose.
	AnimKeyframe last = source.keyframes[source.keyframes.len - 1];
	closing.time = math::max(source.duration, last.time + ANIM_SAME_TIME * 2.0f);
	return clip_with_key(allocator, source, closing);
}

<*
 The opening pose of `source` as a key, every driven channel restated at its
 value at 0 s. False, with nothing to free, when the final key already states it.
*>
fn bool seam_closing_key(Allocator allocator, AnimTemplate source, AnimKeyframe* out) @local
{
	AnimKeyframe last = source.keyframes[source.keyframes.len - 1];
	// The opening pose is not the first sparse frame: channels keyed elsewhere
	// still contribute at zero. Restate every driven channel, without inventing
	// an unkeyed rotation for a translation-only joint (or vice versa).
	AnimDotList opening;
	opening.init(allocator);
	defer opening.free();
	foreach (frame : source.keyframes) foreach (dot : frame.dots)
	{
		bool seen = false;
		foreach (held : opening.array_view()) if (held.joint_name == dot.joint_name) { seen = true; break; }
		if (seen) continue;
		AnimKeyDot value = source.entry_at(dot.joint_name, 0);
		value.joint_name = dot.joint_name.copy(allocator);
		opening.push(value);
	}
	AnimKeyframe closing = { .dots = opening.to_array(allocator) };
	if (last.same_pose(closing))
	{
		foreach (dot : closing.dots) if (dot.joint_name.len > 0) alloc::free(allocator, dot.joint_name.ptr);
		if (closing.dots.len > 0) alloc::free(allocator, closing.dots);
		return false;
	}
	*out = closing;
	return true;
}

<*
 The clip set to loop, eased back to its opening pose across the wrap.

 The sampler already carries a cycle from its last key round to its first over
 whatever time is left after the last key, so a clip ending short of its
 duration loops seamlessly as it is. What it cannot ease is a clip whose final
 key sits *on* the duration with a different pose: there is no time left to
 travel, and the wrap snaps. That clip is lengthened by its own last key
 spacing and the opening pose restated at the new end, so the return takes
 as long as its final move did. Export samples the same keys, so it matches.

 @param extended : `Set when the clip had to grow to make room for the return.`
*>
fn AnimTemplate clip_looped(Allocator allocator, AnimTemplate source, bool* extended = null)
{
	if (extended) *extended = false;
	AnimTemplate looping = clip_copy(allocator, source);
	looping.loop = true;
	usz keys = source.keyframes.len;
	if (keys < 2) return looping;
	AnimKeyframe last = source.keyframes[keys - 1];
	if (last.time < source.duration - ANIM_SAME_TIME) return looping;

	AnimKeyframe closing;
	if (!seam_closing_key(allocator, looping, &closing)) return looping;
	float span = last.time - source.keyframes[keys - 2].time;
	if (span < ANIM_SAME_TIME * 2.0f) span = math::max(source.duration * 0.25f, ANIM_SAME_TIME * 2.0f);
	closing.time = last.time + span;
	AnimTemplate eased = clip_with_key(allocator, looping, closing);
	looping.free(allocator);
	if (extended) *extended = true;
	return eased;
}

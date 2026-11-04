<*
 A clip that starts from a held pose and blends into another clip.

 The opening of most shots: a figure in its rest pose (a T-pose, for a rig that
 rests in one) or in a saved pose, easing into a walk that is already under way.
 Written by hand it is a rest key, a held key, the walk's keys shifted along and
 a ground spec redrawn for the new timing — which is exactly the arithmetic a
 caller gets wrong. Here the walk is entered at a phase of its own cycle, its
 keys are carried after the blend for as many cycles as asked, and every foot's
 contact windows are moved with them: a foot already down where the blend lands
 is down from the start, and a foot in the air there is down while the start
 pose holds and lifts half way through the blend.
*>
module crig;

import std::collections::list;
import std::math;

struct BlendIn
{
	float phase;  // where in the target's cycle the blend lands, 0 to 1
	float hold;   // seconds the start pose holds before the blend
	float blend;  // seconds from the start pose to the target
	float cycles; // how much of a looping target follows, in cycles; a one-shot plays to its end
}

<*
 The target sampled at `time` as one keyframe at `at`: every joint the target
 keys, on the channels it keys it.
*>
fn AnimKeyframe sampled_key(Allocator allocator, AnimTemplate* target, String[] joints, bool[] moves, bool[] turns, float time, float at) @local
{
	AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, (sz)joints.len);
	foreach (usz i, joint : joints)
	{
		AnimKeyDot dot = {
			.joint_name = joint.copy(allocator),
			.channels = turns[i] && moves[i] ? BOTH : (moves[i] ? TRANSLATION : ROTATION),
			.axis = { 1, 0, 0 },
		};
		if (turns[i]) axis_angle_of(target.rotation_at(joint, time), &dot.axis, &dot.angle);
		if (moves[i]) dot.move = target.translation_at(joint, time);
		dots[i] = dot;
	}
	return { .time = at, .dots = dots };
}

<*
 The start pose as one keyframe at `at`: each joint the target keys, from the
 pose when it names the joint and at rest otherwise, eased out when `eased`.
*>
fn AnimKeyframe start_key(Allocator allocator, AnimKeyDot[] start, String[] joints, bool[] moves, bool[] turns, float at, bool eased) @local
{
	AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, (sz)joints.len);
	foreach (usz i, joint : joints)
	{
		AnimKeyDot dot = { .axis = { 1, 0, 0 } };
		foreach (given : start)
		{
			if (given.joint_name != joint) continue;
			dot = given;
			break;
		}
		dot.joint_name = joint.copy(allocator);
		dot.channels = turns[i] && moves[i] ? BOTH : (moves[i] ? TRANSLATION : ROTATION);
		dot.rotation_interpolation = INHERIT;
		dot.translation_interpolation = INHERIT;
		AnimEase ease = eased ? (AnimEase){ 1.0f, 1.0f } : (AnimEase){};
		dot.rotation_ease = ease;
		dot.translation_ease = ease;
		dots[i] = dot;
	}
	return { .time = at, .dots = dots };
}

<*
 Every window `foot` is down in the target's own time, unrolled over the span
 [from, to] of target time, moved onto the new clip's seconds and appended.
*>
fn void moved_windows(List{float}* into, AnimFoot foot, float duration, bool loop, float from, float to, float shift) @local
{
	float down = foot.down * duration;
	float up = foot.up * duration;
	if (foot.up <= foot.down) up += duration;
	int first = loop ? (int)math::floor(from / duration) - 1 : 0;
	int last = loop ? (int)math::floor(to / duration) + 1 : 0;
	for (int k = first; k <= last; k++)
	{
		float a = math::max(down + (float)k * duration, from);
		float b = math::min(up + (float)k * duration, to);
		if (b <= a) continue;
		into.push(a - from + shift);
		into.push(b - from + shift);
	}
}

<*
 A new one-shot clip: the start pose, held for `spec.hold`, eased over
 `spec.blend` into `target` at `spec.phase` of its cycle, then the target's own
 keys for `spec.cycles` cycles (a one-shot target to its end).

 `target` should have its layers flattened into its keys (`clip_flattened`),
 since a layer reads the new clip's own clock. Its ground spec is carried, each
 foot's windows moved onto the new timing.

 @param start : `The start pose's entries, by joint name; a joint the target keys and this does not name starts at rest. Empty is the rest pose.`
*>
fn AnimTemplate clip_blended_in(Allocator allocator, AnimTemplate target, AnimKeyDot[] start, String name, BlendIn spec)
{
	float duration = math::max(target.duration, 1.0e-3f);
	float from = math::clamp(spec.phase, 0.0f, 1.0f) * duration;
	float to = target.loop ? from + math::max(spec.cycles, 0.0f) * duration : duration;
	if (to < from) to = from;
	float hold = math::max(spec.hold, 0.0f);
	float blend = math::max(spec.blend, 1.0e-3f);
	float entered = hold + blend;

	// The joints the target keys, and on which channels.
	List{String} joints;
	joints.init(allocator);
	defer joints.free();
	List{bool} moves;
	moves.init(allocator);
	defer moves.free();
	List{bool} turns;
	turns.init(allocator);
	defer turns.free();
	foreach (frame : target.keyframes)
	{
		foreach (dot : frame.dots)
		{
			sz at = joints.len();
			for (sz j = 0; j < joints.len(); j++) if (joints[j] == dot.joint_name) { at = j; break; }
			if (at == joints.len())
			{
				joints.push(dot.joint_name);
				moves.push(false);
				turns.push(false);
			}
			if (dot.channels != ROTATION) moves[at] = true;
			if (dot.channels != TRANSLATION) turns[at] = true;
		}
	}
	String[] names = joints.array_view();

	List{AnimKeyframe} frames;
	frames.init(allocator);
	frames.push(start_key(allocator, start, names, moves.array_view(), turns.array_view(), 0.0f, hold == 0.0f));
	if (hold > 0.0f) frames.push(start_key(allocator, start, names, moves.array_view(), turns.array_view(), hold, true));

	// The target from where the blend lands: sampled there, then its own keys
	// unrolled round the loop, then sampled where it stops.
	frames.push(sampled_key(allocator, &target, names, moves.array_view(), turns.array_view(), from, entered));
	float last = from;
	if (target.keyframes.len > 0)
	{
		int first = target.loop ? (int)math::floor(from / duration) : 0;
		int cycles = target.loop ? (int)math::ceil(to / duration) : 0;
		for (int k = first; k <= cycles; k++)
		{
			foreach (frame : target.keyframes)
			{
				// A looping clip's closing key is its opening one.
				if (target.loop && frame.time >= duration - 1.0e-5f) continue;
				float t = frame.time + (float)k * duration;
				if (t <= last + 1.0e-4f || t >= to - 1.0e-4f) continue;
				frames.push({ .time = entered + t - from, .dots = keyframe_copy(allocator, frame).dots });
				last = t;
			}
		}
	}
	if (to > from + 1.0e-4f)
	{
		float end = target.loop ? to - math::floor(to / duration - 1.0e-5f) * duration : to;
		frames.push(sampled_key(allocator, &target, names, moves.array_view(), turns.array_view(), end, entered + to - from));
	}
	float total = entered + (to - from);

	// The feet: where each is down in the target's time, moved after the blend.
	// A foot down where the blend lands stays down from the start; one in the air
	// there is down while the start pose holds, and lifts half way through the
	// blend. Contiguous windows of one foot are merged.
	List{AnimFoot} feet;
	feet.init(allocator);
	foreach (foot : target.ground.feet)
	{
		List{float} spans;
		spans.init(allocator);
		defer spans.free();
		moved_windows(&spans, foot, duration, target.loop, from, to, entered);
		bool down_at_entry = spans.len() > 0 && spans[0] <= entered + 1.0e-4f;
		if (down_at_entry)
		{
			spans[0] = 0.0f;
		}
		else
		{
			// Ahead of the rest, so the windows stay in time order.
			spans.push_front(hold + blend * 0.5f);
			spans.push_front(0.0f);
		}
		sz count = spans.len() / 2;
		for (sz w = 0; w < count; w++)
		{
			float a = spans[w * 2];
			float b = spans[w * 2 + 1];
			// Merged into the next window when they touch.
			while (w + 1 < count && spans[(w + 1) * 2] <= b + 1.0e-4f)
			{
				w++;
				b = math::max(b, spans[w * 2 + 1]);
			}
			if (b - a < 1.0e-4f) continue;
			feet.push({
				.joint = foot.joint.copy(allocator),
				.down = math::clamp(a / total, 0.0f, 1.0f),
				.up = math::clamp(b / total, 0.0f, 1.0f),
				.off_floor = foot.off_floor,
			});
		}
	}

	AnimGround ground = { .floor = target.ground.floor, .floor_set = target.ground.floor_set };
	if (feet.len() > 0) ground.feet = feet.to_array(allocator);
	feet.free();

	AnimKeyframe[] keys = frames.to_array(allocator);
	frames.free();
	return {
		.name = name.copy(allocator),
		.duration = total,
		.keyframes = keys,
		.loop = false,
		.blend = target.blend,
		.ground = ground,
		.owned = true,
	};
}

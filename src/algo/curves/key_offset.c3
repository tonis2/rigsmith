<*
 A turn and a slide added onto joints at chosen keys: what lands when a pose
 edited at one selected key is keyed onto all of them (app/key_spread.c3).

 Each key keeps its own value with the offset composed on, so the motion between
 the keys is kept and only shifted. The turn composes on the right — in the
 joint's own turned frame, as an additive layer composes (`LayerStack.apply`) —
 so a twist about the bone stays a twist about it however the joint swings over
 the range.

 ## The edges

 Keys outside the selection stay as they are, except the offset channel's own
 keys within `fade` of a selected time: they take a share that falls from the
 whole offset to none over that distance. A clip keyed every frame would
 otherwise jump at the first and last selected key; a hand-keyed clip has no keys
 that close, and its interpolation does the easing.
*>
module crig;

import std::math;
import std::math::quaternion;
import std::sort;

// How far past the selected keys the offset fades out, in seconds.
const float KEY_OFFSET_FADE = 0.1f;

<*
 One joint's offset: `turn` composes onto its rotation and `move` adds to its
 offset as a fraction of rig height, each only where its flag is set.
*>
struct KeyOffset
{
	String joint;
	bool rotates;
	Quaternionf turn;
	bool moves;
	Vec3 move;
}

<*
 `source` with `offsets` added at the `selected` times, fading out over each
 channel's own keys within `fade` of them.

 	`AnimTemplate turned = clip_with_offset(mem, *clip, offsets[..], times[..]);`

 A selected time where a joint does not key the channel gains a key there, read
 from what the clip plays at that time. An existing key keeps its interpolation,
 ease and bone; only its value changes. Every value is read from `source`, so
 the joints are independent of each other. Channels and joints not named are
 left exactly as they were.

 @param selected : `Key times, distinct, in any order.`
 @param faded : `Set to how many distinct key times took a partial share.`
 @return `A new clip; source is left alone.`
*>
fn AnimTemplate clip_with_offset(Allocator allocator, AnimTemplate source, KeyOffset[] offsets,
	float[] selected, float fade = KEY_OFFSET_FADE, usz* faded = null)
{
	// Sorted, so the nearest selected time to a key is a halving away.
	float[] sorted = alloc::new_array(mem, float, (sz)selected.len);
	defer alloc::free(mem, sorted);
	sorted[..] = selected[..];
	sort::quicksort(sorted);

	AnimKeyframeList keys;
	keys.init(allocator);
	AnimFloatList partial;
	partial.init(mem);
	defer partial.free();
	foreach (offset : offsets)
	{
		foreach (rotation : (bool[2]){ true, false })
		{
			if (rotation ? !offset.rotates : !offset.moves) continue;
			foreach (time : sorted) keys.push(offset_key(allocator, &source, offset, rotation, time, 1.0f));
			if (fade <= 0.0f || sorted.len == 0) continue;
			foreach (frame : source.keyframes)
			{
				AnimKeyDot held;
				if (!frame.channel_dot(offset.joint, rotation, &held)) continue;
				float distance = offset_distance(&source, frame.time, sorted);
				if (distance < ANIM_SAME_TIME || distance >= fade) continue;
				float x = 1.0f - distance / fade;
				keys.push(offset_key(allocator, &source, offset, rotation, frame.time, x * x * (3.0f - 2.0f * x)));
				bool counted = false;
				foreach (time : partial) if (math::abs(time - frame.time) < ANIM_SAME_TIME) counted = true;
				if (!counted) partial.push(frame.time);
			}
		}
	}
	if (faded) *faded = (usz)partial.len();
	AnimKeyframe[] written = keys.to_array(allocator);
	keys.free();
	return clip_with_keys(allocator, source, written);
}

// One channel of one joint at `time`, with `share` of the offset on: the key's own
// value where the channel is keyed there, else what the clip plays.
fn AnimKeyframe offset_key(Allocator allocator, AnimTemplate* source, KeyOffset offset,
	bool rotation, float time, float share) @local
{
	AnimKeyDot base = source.entry_at(offset.joint, time);
	sz at = keyframe_index_at(source, time);
	AnimKeyDot held;
	if (at >= 0 && source.keyframes[(usz)at].channel_dot(offset.joint, rotation, &held))
	{
		base.axis = held.axis;
		base.angle = held.angle;
		base.move = held.move;
		base.bone = held.bone;
	}

	AnimKeyDot dot = {
		.joint_name = offset.joint.copy(allocator),
		.channels = rotation ? ROTATION : TRANSLATION,
		.axis = base.axis,
		.angle = base.angle,
		.move = base.move,
		.bone = base.bone,
	};
	if (rotation)
	{
		Quaternionf turn = share >= 1.0f ? offset.turn : slerp_short(quaternion::IDENTITY, offset.turn, share);
		Quaternionf held_turn = quaternion::from_axis_angle{float}(base.axis.normalize(), base.angle);
		axis_angle_of(held_turn.mul(turn).normalize(), &dot.axis, &dot.angle);
	}
	else
	{
		dot.move = base.move + offset.move * share;
	}
	AnimKeyDot[] dots = alloc::new_array(allocator, AnimKeyDot, 1);
	dots[0] = dot;
	return { .time = time, .dots = dots };
}

// The keyframe at `time`, or -1. The keys are in time order.
fn sz keyframe_index_at(AnimTemplate* source, float time) @local
{
	usz lo = 0;
	usz hi = source.keyframes.len;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		if (source.keyframes[mid].time < time - ANIM_SAME_TIME) { lo = mid + 1; } else { hi = mid; }
	}
	if (lo < source.keyframes.len && math::abs(source.keyframes[lo].time - time) < ANIM_SAME_TIME) return (sz)lo;
	return -1;
}

// How far `time` is from the nearest of `sorted`, going round the end of a loop.
fn float offset_distance(AnimTemplate* source, float time, float[] sorted) @local
{
	usz lo = 0;
	usz hi = sorted.len;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		if (sorted[mid] < time) { lo = mid + 1; } else { hi = mid; }
	}
	float nearest = 1.0e30f;
	if (lo < sorted.len) nearest = math::min(nearest, sorted[lo] - time);
	if (lo > 0) nearest = math::min(nearest, time - sorted[lo - 1]);
	if (source.loop && source.duration > 0.0f)
	{
		// The first selected key is this far ahead once the loop comes round, and
		// the last this far behind.
		nearest = math::min(nearest, source.duration - time + sorted[0]);
		nearest = math::min(nearest, time + source.duration - sorted[^1]);
	}
	return nearest;
}

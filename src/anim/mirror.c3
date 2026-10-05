<*
 Filling in a clip's other side.

 A gait is one limb's motion twice, half a cycle apart. Writing both sides out
 longhand doubles the work and, worse, doubles it asymmetrically: a limb's
 mirror is not its copy, and the sign that flips is different for a rotation
 than for a slide. Getting one of them backwards produces a clip that plays,
 looks nearly right, and has a leg rotating the wrong way — which reads as bad
 animation rather than as a bug, so it survives review.

 So the rule is stated once, here, and an author writes one side.

 **What a reflection does to a stored entry.** A template holds an axis, an
 angle and a displacement. Reflecting in a plane whose normal is X:

 	`axis   (x, y, z)  ->  (x, -y, -z)`,  angle unchanged
 	`move   (x, y, z)  ->  (-x, y, z)`
 	`bone   (x, y, z)  ->  (-x, y, z)`

 The axis flips the two components the displacement keeps and keeps the one it
 flips, because an axis is a pseudo-vector: the reflection's determinant is -1
 and cancels one of the sign changes. That single line is the whole reason this
 is worth having as a function.

 **The plane's position does not matter**, only its normal. An axis is a
 direction and `move` is a displacement, and both are differences — translating
 the plane cancels out of each. So there is no symmetry plane to pass in, and a
 rig whose midline is nowhere near x = 0 mirrors correctly anyway.
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;


import std::collections::list;


<*
 A copy of `template` with every one-sided joint's twin filled in.

 	`AnimTemplate both = mirror_template(mem, one_side, "Run", 0.5f);`

 Every joint whose name carries an `_L` or `_R` suffix gets its opposite number
 driven by the reflected motion, delayed by `phase` of the cycle. A joint the
 template already drives on both sides is left alone on both — what the author
 wrote wins over what this would infer — and a joint with no side at all
 (a spine, a head, a root) is copied through untouched, because it has no twin
 to fill and its own motion is already the whole story.

 The result carries the same keyframe times as the source. The mirrored half is
 *sampled* at `time - phase * duration`, through the clip's own blend, so a phase
 that does not land on a keyframe is fitted rather than refused. On the ordinary
 case — an evenly-keyed cycle offset by half of it — the sample lands on a key
 and the copy is exact.

 The result is allocated from `allocator` with `owned` set; free it with
 `AnimTemplate.free`.

 @param name : `The copy's name. A clip is addressed by name, so it needs one of its own.`
 @param phase : `How much of the cycle the mirrored side lags by, 0 to 1. Half is a walk or a run.`
*>
fn AnimTemplate mirror_template(
	Allocator allocator,
	AnimTemplate template,
	String name,
	float phase)
{
	AnimTemplate out = {
		.name = name.copy(allocator),
		.duration = template.duration,
		.keyframes = alloc::new_array(allocator, AnimKeyframe, (sz)template.keyframes.len),
		.loop = template.loop,
		.blend = template.blend,
		.ground = mirror_ground(allocator, template.ground, phase),
		.layers = layers_mirrored(allocator, template.layers),
		.aims = aims_mirrored(allocator, template.aims),
		.aim_targets = aim_targets_mirrored(allocator, template.aim_targets),
		.owned = true,
	};

	float lag = phase * template.duration;

	foreach (usz k, frame : template.keyframes)
	{
		AnimDotList dots;
		dots.init(allocator);

		foreach (dot : frame.dots)
		{
			dots.push(dot.copy(allocator));
		}

		foreach (dot : frame.dots)
		{
			String twin = mirror_name(allocator, dot.joint_name);
			if (twin.len == 0) continue;
			bool rotation = dot.keys_rotation() && template.channel_count(twin, true) == 0;
			bool translation = dot.keys_translation() && template.channel_count(twin, false) == 0;
			if (!rotation && !translation) { alloc::free(allocator, twin.ptr); continue; }

			// Read back through the sampler rather than off the keyframe, so a phase
			// that falls between two keys gives the curve's value there instead of
			// the nearest key's. Folded into the cycle here rather than left to
			// `entry_at`, which holds the ends for a linear clip — correct for a
			// player and wrong for a lag, which is a walk around the loop.
			AnimKeyDot lagged = template
				.entry_at(dot.joint_name, cycled(template, frame.time - lag))
				.reflected();
			lagged.joint_name = twin;
			lagged.channels = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION);
			if (!rotation) lagged.rotation_interpolation = INHERIT;
			if (!translation) lagged.translation_interpolation = INHERIT;
			merge_flipped(&dots, lagged, allocator);
		}

		out.keyframes[k] = { .time = frame.time, .dots = dots.to_array(allocator) };
		dots.free();
	}

	return out;
}

<*
 Every layer of a stack reflected across the symmetry plane, in place.

 Unlike the base keys, which are *filled in* for a missing side and lagged by a
 gait's phase, a layer is an adjustment and is mirrored whole: what played on
 `ear_L` plays on `ear_R`, and a joint with no side is reflected where it stands.

 - Keyed layers are flipped as a pasted pose is (`keyframe_flipped`): each entry
   reflected by the three sign rules and handed to its twin.
 - A mask names the twins.
 - A generator starts at, and ends on, the twin joints, and turns about the
   reflected axis (`x, -y, -z`), so a wave about Y swings the other way and one
   about X the same way. Timing, amplitude and the rest are untouched.

 The result replaces nothing: it is a deep copy, freed with `free_layers`.
*>
fn AnimLayer[] layers_mirrored(Allocator allocator, AnimLayer[] source)
{
	AnimLayer[] out = layers_copy(allocator, source);
	foreach (&layer : out)
	{
		foreach (usz i, entry : layer.mask) layer.mask[i] = twin_or_same(allocator, entry);
		layer.joint = twin_or_same(allocator, layer.joint);
		layer.tip = twin_or_same(allocator, layer.tip);
		layer.axis = { layer.axis.x, -layer.axis.y, -layer.axis.z };
		foreach (&frame : layer.keyframes)
		{
			AnimKeyframe flipped = keyframe_flipped(allocator, *frame);
			frame.free(allocator);
			*frame = flipped;
		}
	}
	return out;
}

// The twin of a joint name, or the name itself when it has none. `name` is the
// layer's own copy, so it is freed when replaced.
fn String twin_or_same(Allocator allocator, String name)
{
	if (name.len == 0) return name;
	String twin = mirror_name(allocator, name);
	if (twin.len == 0) return name;
	alloc::free(allocator, name.ptr);
	return twin;
}

<*
 One pose reflected across the rig's symmetry plane.

 	`AnimKeyframe flipped = keyframe_flipped(mem, pose, view.names);`

 What pasting a pose *mirrored* means, and what mirroring a selected pose in
 place means — the two are one operation on different inputs. Every sided
 entry (`hip_L`, `mixamorig:LeftArm`) is reflected by the three sign rules and
 handed to its twin; an entry whose twin is also in the pose is thereby
 swapped with it. A joint with no side — a spine, the head, the root — has no
 twin to hand anything to, so it is reflected in place: a torso leaning to
 the left comes back leaning to the right, which is what a mirror shows.

 Unlike `mirror_template`, which *fills in* a side the author left blank, this
 does not keep the source entry beside its reflection. A pose is one instant,
 and mirroring it is a statement about where every joint in it goes; keeping
 the original as well would make a selection of one arm write both arms and
 the user would have to work out which one was the copy.

 A twin the rig does not have — a name written for another figure, or a side
 the rig never got — is dropped rather than invented, and counted in
 `unmatched` so the caller can say so. Pass no `joints` to accept every twin
 the names produce.

 Same time as the source. The result owns its strings and array; a caller that
 lands it with `clip_with_key` hands them over, one that does not frees them
 with `AnimKeyframe.free`.

 @param joints : `The rig's joint names. Empty means every twin is welcome.`
 @param unmatched : `Receives how many sided entries found no twin on the rig, if given.`
*>
fn AnimKeyframe keyframe_flipped(Allocator allocator, AnimKeyframe source, String[] joints = {}, usz* unmatched = null)
{
	AnimDotList dots;
	dots.init(allocator);
	defer dots.free();
	usz dropped;

	foreach (dot : source.dots)
	{
		AnimKeyDot flipped = dot.reflected();
		String twin = mirror_name(allocator, dot.joint_name);
		if (twin.len == 0)
		{
			flipped.joint_name = dot.joint_name.copy(allocator);
		}
		else if (joints.len > 0 && !array::contains(joints, twin))
		{
			alloc::free(allocator, twin.ptr);
			dropped++;
			continue;
		}
		else
		{
			flipped.joint_name = twin;
		}
		merge_flipped(&dots, flipped, allocator);
	}

	if (unmatched) *unmatched = dropped;
	return { .time = source.time, .dots = dots.to_array(allocator) };
}

// A second entry for a joint already in `dots` merges its channels into the
// held one rather than standing as a duplicate the sampler would have to choose
// between: the added channels win, and the held entry keys the union. Filling
// in a mirrored side lands an authored channel and its complement here; a
// flipped pose does only when a naming scheme is not its own inverse.
fn void merge_flipped(AnimDotList* dots, AnimKeyDot added, Allocator allocator) @local
{
	for (sz i = 0; i < dots.len(); i++)
	{
		AnimKeyDot* held = dots.get_ref(i);
		if (held.joint_name != added.joint_name) continue;
		bool rotation = held.keys_rotation() || added.keys_rotation();
		bool translation = held.keys_translation() || added.keys_translation();
		if (added.keys_rotation())
		{
			held.axis = added.axis;
			held.angle = added.angle;
			held.bone = added.bone;
			held.rotation_interpolation = added.rotation_interpolation;
			held.rotation_ease = added.rotation_ease;
		}
		if (added.keys_translation())
		{
			held.move = added.move;
			held.translation_interpolation = added.translation_interpolation;
			held.translation_ease = added.translation_ease;
		}
		held.channels = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION);
		alloc::free(allocator, added.joint_name.ptr);
		return;
	}
	dots.push(added);
}

// One entry reflected: the three sign rules at the top of this file, and
// nothing else. Kept apart from the sampling so the rules are readable as a
// block rather than buried in the walk that applies them.
fn AnimKeyDot AnimKeyDot.reflected(self)
{
	AnimKeyDot out = self;
	out.axis = { self.axis.x, -self.axis.y, -self.axis.z };
	out.move = { -self.move.x, self.move.y, self.move.z };
	out.bone = { -self.bone.x, self.bone.y, self.bone.z };
	return out;
}

<*
 The ground spec with each one-sided contact joint's twin added, its window
 shifted by the same phase the motion was.

 Without this a mirrored gait would plant only the side that was authored, and
 the solve would drop the figure onto one foot for the whole cycle.
*>
fn AnimGround mirror_ground(Allocator allocator, AnimGround ground, float phase) @local
{
	if (!ground.solves()) return {};

	AnimFootList feet;
	feet.init(allocator);

	foreach (foot : ground.feet)
	{
		feet.push({ .joint = foot.joint.copy(allocator), .down = foot.down, .up = foot.up, .off_floor = foot.off_floor });
	}

	foreach (foot : ground.feet)
	{
		String twin = mirror_name(allocator, foot.joint);
		if (twin.len == 0) continue;

		bool already = false;
		foreach (other : ground.feet)
		{
			if (other.joint == twin) already = true;
		}
		if (already)
		{
			alloc::free(allocator, twin.ptr);
			continue;
		}

		feet.push({ .joint = twin, .down = wrapped(foot.down + phase), .up = wrapped(foot.up + phase),
			.off_floor = foot.off_floor });
	}

	AnimGround out = { .feet = feet.to_array(allocator), .floor = ground.floor, .floor_set = ground.floor_set };
	feet.free();
	return out;
}

alias AnimFootList = List{AnimFoot};

// A phase folded back into [0, 1). A window whose end wraps past the loop point
// is the ordinary case, and `AnimFoot.planted` reads it correctly.
fn float wrapped(float phase) @local => phase - math::floor(phase);

// A time folded into the clip's own cycle. Left alone for a clip that does not
// loop: there is no other turn of it to have come from, and a lag off the front
// of a one-shot is the start of it.
fn float cycled(AnimTemplate template, float time) @local
{
	if (!template.loop || template.duration <= 0.0f || template.keyframes.len == 0) return time;

	float first = template.keyframes[0].time;
	return time - template.duration * math::floor((time - first) / template.duration);
}

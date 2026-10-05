<*
 Clip pins: a joint held in place while the body plays round it.

 An `AnimPin` belongs to a clip, next to its aims. It names one joint, where that
 joint stays (`at`, a point in the model's space) and, optionally, how it is
 turned (`orient`), for a window of the clip (`from`..`to`, seconds). It is what a
 foot planted on the floor is: keys move the hips, and the leg bends to keep the
 foot where it is.

 **Applied live, never written into keys**, exactly as the look-at aims are.
 Keyframes keep the authored rotations; `pin_pose` lays the pins over a pose
 wherever it is shown, played or exported, after joint limits and the ground
 solve and before the aims (a head that looks at something looks from where the
 body is *held*). Muting or removing a pin gives the authored motion back.

 **What a position pin moves.** The joint's limb: the unbranched run of
 ancestors above it, which `rig::Skeleton.ancestor_run` defines and the editor's
 gesture pins use too. A joint whose parent forks, or a root, has no limb that can
 carry it without dragging its siblings, and its position pin is skipped. Every
 turn is handed to an `AimClamp` so a knee that cannot bend further stays inside
 its limits and the foot comes as near as the limb allows.

 **The window and the blend.** Outside `from`..`to` the pin does nothing. Inside,
 its weight rises over `blend` seconds from `from` and falls over `blend` before
 `to` (a smoothstep), so a foot lands and lifts without a pop; blend 0 is a
 hard edge. The weight is applied as a slerp between the pose before the pin and
 after it, per touched joint.

 **Where a pin lives.** `at` is a fraction of the rig's height like an aim
 target, so the same clip holds the same place on a rig in metres or in
 centimetres. `orient` is a world rotation.
*>
module crig;

import rig;
import std::math;
import std::sort;
import std::math::vector;
import std::math::quaternion;

<*
 One pin. `joint` is in the clip's vocabulary (resolved with `names_for`) and is
 owned by the clip's allocator; see `AnimPin.free`. A joint has at most one pin.
 `position` and `rotation` say what is held; a pin holding neither does nothing.
*>
struct AnimPin
{
	String joint;
	bool position;
	bool rotation;
	Vec3 at;           // model space, fraction of rig height
	Quaternionf orient; // world orientation held when `rotation`
	float from;        // seconds into the clip
	float to;
	float blend;       // seconds of ease in and out inside the window; 0 is hard
	bool mute;
}

<*
 A fresh position pin on `joint` at `at`, over `from`..`to`, with no blend. The
 name is copied.
*>
fn AnimPin pin_defaults(Allocator allocator, String joint, Vec3 at, float from, float to)
{
	return {
		.joint = joint.copy(allocator),
		.position = true,
		.at = at,
		.orient = quaternion::IDENTITY,
		.from = from,
		.to = to,
	};
}

fn AnimPin AnimPin.copy(&self, Allocator allocator, float scale = 1.0f, float shift = 0.0f)
{
	AnimPin out = *self;
	out.joint = self.joint.copy(allocator);
	out.from = math::max(0.0f, self.from * scale + shift);
	out.to = math::max(0.0f, self.to * scale + shift);
	out.blend = self.blend * scale;
	return out;
}

fn void AnimPin.free(&self, Allocator allocator)
{
	if (self.joint.len > 0) alloc::free(allocator, self.joint.ptr);
	*self = {};
}

fn void free_pins(Allocator allocator, AnimPin[] pins)
{
	foreach (&pin : pins) pin.free(allocator);
	if (pins.len > 0) alloc::free(allocator, pins);
}

<*
 A deep copy with every time scaled by `scale` and then moved by `shift`, how a
 retime and a crop carry the windows. A pin left with no window (it ends before
 time zero or starts after `limit`, when `limit` is positive) is dropped.
*>
fn AnimPin[] pins_copy(Allocator allocator, AnimPin[] source, float scale = 1.0f, float shift = 0.0f, float limit = -1.0f)
{
	usz kept;
	foreach (&pin : source) if (pin_in_range(pin, scale, shift, limit)) kept++;
	AnimPin[] out = alloc::new_array(allocator, AnimPin, (sz)kept);
	usz write;
	foreach (&pin : source)
	{
		if (!pin_in_range(pin, scale, shift, limit)) continue;
		out[write] = pin.copy(allocator, scale, shift);
		if (limit > 0.0f) out[write].to = math::min(out[write].to, limit);
		write++;
	}
	return out;
}

fn bool pin_in_range(AnimPin* pin, float scale, float shift, float limit) @local
{
	if (pin.to * scale + shift < 0.0f) return false;
	return !(limit > 0.0f && pin.from * scale + shift > limit);
}

<*
 A deep copy with the window cut out of the clip's time: `start..end` is removed,
 later times move up by its length, times inside it land on `start`.
*>
fn AnimPin[] pins_cut(Allocator allocator, AnimPin[] source, float start, float end)
{
	AnimPin[] out = pins_copy(allocator, source);
	float removed = end - start;
	foreach (&pin : out)
	{
		pin.from = pin.from >= end ? pin.from - removed : math::min(pin.from, start);
		pin.to = pin.to >= end ? pin.to - removed : math::min(pin.to, start);
	}
	return out;
}

<*
 Every pin reflected across the symmetry plane: the joint goes to its twin (or
 stays when it has none), `at.x` is negated and the held orientation is reflected
 the way a keyed turn is. A deep copy.
*>
fn AnimPin[] pins_mirrored(Allocator allocator, AnimPin[] source)
{
	AnimPin[] out = pins_copy(allocator, source);
	foreach (&pin : out)
	{
		pin.joint = twin_or_same(allocator, pin.joint);
		pin.at.x = -pin.at.x;
		pin.orient = reflected_rotation(pin.orient);
	}
	return out;
}

// Where in `pins` the joint's pin is, or -1.
fn sz pin_index_of(AnimPin[] pins, String joint)
{
	foreach (usz i, &pin : pins) if (pin.joint == joint) return (sz)i;
	return -1;
}

// ---------------------------------------------------------------------------
// Rewriters. Pure: each answers a new clip and the caller lands it.

// The clip with its pins replaced by `next`, which is taken over.
fn AnimTemplate clip_with_pins(Allocator allocator, AnimTemplate source, AnimPin[] next)
{
	AnimTemplate clip = clip_copy(allocator, source);
	free_pins(allocator, clip.pins);
	clip.pins = next;
	return clip;
}

<*
 The clip with `pin` added, or replacing the pin already on its joint. `pin` is
 taken over.
*>
fn AnimTemplate clip_with_pin(Allocator allocator, AnimTemplate source, AnimPin pin)
{
	sz at = pin_index_of(source.pins, pin.joint);
	usz count = at >= 0 ? source.pins.len : source.pins.len + 1;
	AnimPin[] next = alloc::new_array(allocator, AnimPin, (sz)count);
	foreach (usz i, &held : source.pins) next[i] = (sz)i == at ? pin : held.copy(allocator);
	if (at < 0) next[count - 1] = pin;
	return clip_with_pins(allocator, source, next);
}

// The clip without the pin on `joint`; a plain copy when there is none.
fn AnimTemplate clip_without_pin(Allocator allocator, AnimTemplate source, String joint)
{
	sz at = pin_index_of(source.pins, joint);
	if (at < 0) return clip_copy(allocator, source);
	AnimPin[] next = alloc::new_array(allocator, AnimPin, (sz)(source.pins.len - 1));
	usz write;
	foreach (usz i, &held : source.pins)
	{
		if ((sz)i == at) continue;
		next[write++] = held.copy(allocator);
	}
	return clip_with_pins(allocator, source, next);
}

// `clip_copy`, dropping the pins.
fn AnimTemplate clip_copy_without_pins(Allocator allocator, AnimTemplate source)
{
	AnimTemplate out = clip_copy(allocator, source);
	free_pins(allocator, out.pins);
	out.pins = {};
	return out;
}

// ---------------------------------------------------------------------------
// Window

<*
 How much of the pin applies at `time`, 0 to 1: 0 outside `from`..`to`, a
 smoothstep over `blend` seconds at either edge, 1 between. On a looping clip a
 window that runs past either end of the clip also covers the matching time on
 the other side, so a plant that straddles the loop point holds through it.
*>
fn float AnimPin.weight_at(&self, float time, float duration, bool loop)
{
	float best = pin_window_weight(self, time);
	if (loop && duration > 0.0f)
	{
		best = math::max(best, pin_window_weight(self, time + duration));
		best = math::max(best, pin_window_weight(self, time - duration));
	}
	return best;
}

fn float pin_window_weight(AnimPin* pin, float time) @local
{
	if (!(pin.to >= pin.from) || time < pin.from || time > pin.to) return 0.0f;
	if (!(pin.blend > 0.0f)) return 1.0f;
	float rise = (time - pin.from) / pin.blend;
	float fall = (pin.to - time) / pin.blend;
	float x = math::clamp(math::min(rise, fall), 0.0f, 1.0f);
	return x * x * (3.0f - 2.0f * x);
}

// Whether the pin would hold anything: unmuted, with something to hold and a
// window that is not inverted.
fn bool pin_plays(AnimPin* pin) @local
{
	return !pin.mute && (pin.position || pin.rotation) && pin.to >= pin.from;
}

// Whether any pin would hold a joint when the clip is evaluated. What decides
// that an export has to bake the clip.
fn bool AnimTemplate.plays_pins(&self)
{
	foreach (&pin : self.pins) if (pin_plays(pin)) return true;
	return false;
}

// Whether anything is laid over the keys at evaluation time without being a key:
// pins and aims, the two live layers.
fn bool AnimTemplate.plays_live_layers(&self) => self.plays_pins() || self.plays_aims();

<*
 `times` with the unmuted pins' window edges and the ends of their blends added,
 and, for a hard edge, an instant either side of it. Sorted; consumes `times`.
*>
fn float[] pin_sample_times(Allocator allocator, AnimTemplate* clip, float[] times)
{
	if (!clip.plays_pins()) return times;
	float[] merged = alloc::new_array(allocator, float, (sz)(times.len + clip.pins.len * 6));
	usz used;
	foreach (time : times) merged[used++] = time;
	alloc::free(allocator, times);
	sort::quicksort(merged[:used]);
	foreach (&pin : clip.pins)
	{
		if (!pin_plays(pin)) continue;
		float[6] edges = {
			pin.from, pin.to, pin.from + pin.blend, pin.to - pin.blend,
			pin.blend > 0.0f ? pin.from : pin.from - ANIM_SAME_TIME * 2.0f,
			pin.blend > 0.0f ? pin.to : pin.to + ANIM_SAME_TIME * 2.0f,
		};
		foreach (edge : edges)
		{
			if (edge < 0.0f || edge > clip.duration) continue;
			bool near;
			for (usz j = 0; j < used; j++)
			{
				if (math::abs(merged[j] - edge) < ANIM_SAME_TIME) { near = true; break; }
			}
			if (!near && used < merged.len) merged[used++] = edge;
		}
	}
	sort::quicksort(merged[:used]);
	float[] out = alloc::new_array(allocator, float, (sz)used);
	foreach (usz i, time : merged[:used]) out[i] = time;
	alloc::free(allocator, merged);
	return out;
}

// ---------------------------------------------------------------------------
// Solve

// CCD passes a pin's limb gets, and the largest turn one pivot takes in one.
const uint PIN_PASSES = 24;
const float PIN_MAX_STEP = 0.5f;
// How near the joint must come before the solve stops: a twentieth of a percent
// of the rig's height, well inside what a held foot is read against.
const float PIN_TOLERANCE = 0.0005f;

<*
 The joints a pin on `joint` turns when it holds a position: the unbranched
 ancestor run, nearest first, written to `out`. Zero when the joint has none.
*>
fn usz pin_run(rig::Skeleton* skeleton, usz joint, usz[] out)
{
	return skeleton.ancestor_run(joint, out);
}

<*
 Swing a limb so the joint at its tip reaches `target`, each pivot held inside
 its limits by `clamp`: cyclic coordinate descent from the pivot nearest the tip.
 `run` is nearest first, as `ancestor_run` writes it. The tip is never turned.

 @return `How far the tip still is from the target.`
*>
fn float pin_reach(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose* pose,
	usz[] run,
	usz tip,
	Vec3 target,
	float tolerance,
	AimClamp clamp = null,
	void* ctx = null)
{
	float gap = 1.0e30f;
	pin_unstraighten(allocator, skeleton, pose, run, tip, target, clamp, ctx);
	pin_fold(allocator, skeleton, pose, run, tip, target, clamp, ctx);
	for (uint pass = 0; pass < PIN_PASSES; pass++)
	{
		for (usz k = 0; k < run.len; k++)
		{
			Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
			if (catch built) return gap;
			Matrix4f[] palette = built;
			defer alloc::free(allocator, palette);

			usz joint = run[k];
			Vec3 pivot = skeleton.joints[joint].transform(palette[joint]);
			Vec3 at = skeleton.joints[tip].transform(palette[tip]);
			gap = (target - at).length();
			if (gap <= tolerance) return gap;
			pin_swing(allocator, skeleton, pose, joint, at - pivot, target - pivot, PIN_MAX_STEP, clamp, ctx);
		}
	}
	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
	if (catch built) return gap;
	defer alloc::free(allocator, built);
	return (target - skeleton.joints[tip].transform(built[tip])).length();
}

// How far a bend is seeded into a straight limb, and how straight counts as straight:
// the chain's chord at this share of its length or more.
const float PIN_SEED_BEND = 0.3f;
const float PIN_STRAIGHT = 0.995f;

<*
 Give a straight limb a bend to start from.

 CCD turns one pivot at a time toward the target, and a limb stretched out on the
 line to a target that is nearer than its tip has no such turn: every pivot sees
 the tip and the target in the same direction, so nothing moves although the
 limb could plainly fold. This is the planted foot under hips that have dropped,
 the commonest thing a pin is for. So when the chain is straight and the target is
 inside its reach, the pivot nearest the tip (the knee, the elbow) is bent a little
 about whichever perpendicular lets it move most through its limits, and the
 passes refine from there.
*>
fn void pin_unstraighten(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose* pose,
	usz[] run,
	usz tip,
	Vec3 target,
	AimClamp clamp,
	void* ctx) @local
{
	if (run.len < 2) return;
	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(allocator, palette);

	usz root = run[run.len - 1];
	Vec3 base = skeleton.joints[root].transform(palette[root]);
	Vec3 at = skeleton.joints[tip].transform(palette[tip]);
	float length;
	Vec3 last = base;
	for (usz k = run.len; k > 0; k--)
	{
		usz next = k > 1 ? run[k - 2] : tip;
		Vec3 point = skeleton.joints[next].transform(palette[next]);
		length += (point - last).length();
		last = point;
	}
	float chord = (at - base).length();
	if (!(length > 0.0f) || chord < length * PIN_STRAIGHT) return;
	if ((target - base).length() >= chord) return;

	Quaternionf[]? spun = pose.world_rotations(allocator, skeleton);
	if (catch spun) return;
	Quaternionf[] world = spun;
	defer alloc::free(allocator, world);

	usz joint = run[0];
	Vec3 pivot = skeleton.joints[joint].transform(palette[joint]);
	Vec3 along = at - pivot;
	if (along.length_sq() < 1.0e-12f) return;
	Vec3 line = along.normalize();
	int parent = skeleton.parents[joint];
	Quaternionf above = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;

	Vec3[3] axes = { { 1, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 } };
	Quaternionf best = pose.rotations[joint];
	float moved = 1.0e-6f;
	foreach (axis : axes)
	{
		Vec3 square = axis - line * axis.dot(line);
		if (square.length_sq() < 1.0e-4f) continue;
		foreach (float sign : { 1.0f, -1.0f })
		{
			Quaternionf step = quaternion::from_axis_angle{float}(square.normalize(), PIN_SEED_BEND * sign);
			Quaternionf local = above.invert().mul(step).mul(world[joint]).normalize();
			if (clamp) local = clamp(ctx, joint, local);
			Quaternionf actual = above.mul(local).mul(world[joint].invert()).normalize();
			float travel = (actual.rotate_vec3(along) - along).length();
			if (travel > moved)
			{
				moved = travel;
				best = local;
			}
		}
	}
	pose.rotations[joint] = best;
}

<*
 Turn `joint` by the shortest arc carrying `from` onto `to` (at most `limit`
 radians when that is positive), through `clamp`.
*>
fn void pin_swing(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose* pose,
	usz joint,
	Vec3 from,
	Vec3 to,
	float limit,
	AimClamp clamp,
	void* ctx) @local
{
	Quaternionf[]? spun = pose.world_rotations(allocator, skeleton);
	if (catch spun) return;
	Quaternionf[] world = spun;
	defer alloc::free(allocator, world);
	Quaternionf arc = aim_carry(from, to, { 0, 1, 0 });
	float angle = 2.0f * (float)math::acos((double)math::clamp(math::abs(arc.v.w), 0.0f, 1.0f));
	if (limit > 0.0f && angle > limit) arc = slerp_short(quaternion::IDENTITY, arc, limit / angle);
	int parent = skeleton.parents[joint];
	Quaternionf above = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
	Quaternionf local = above.invert().mul(arc).mul(world[joint]).normalize();
	if (clamp) local = clamp(ctx, joint, local);
	pose.rotations[joint] = local;
}

<*
 Two-bone reach, the start CCD needs.

 CCD turns one pivot at a time toward the target, and on a limb whose target is
 nearer than its tip along nearly the same line (a planted foot under hips that
 have dropped) every pivot sees the tip and the target in the same direction, so
 each step is tiny and the passes crawl. A two-bone limb has a closed form: the
 mid joint goes where the law of cosines puts it, on the side it already bends
 toward (`pin_unstraighten` gives a straight limb a side), the root pivot swings it
 there and the mid pivot then aims the tip at the target. Each swing goes through
 the limits, so a hinge that cannot give simply gives less and the passes finish
 what they can. Longer or shorter limbs go straight to the passes.
*>
fn void pin_fold(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose* pose,
	usz[] run,
	usz tip,
	Vec3 target,
	AimClamp clamp,
	void* ctx) @local
{
	if (run.len != 2) return;
	usz mid = run[0];
	usz root = run[1];

	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
	if (catch built) return;
	Vec3 r = skeleton.joints[root].transform(built[root]);
	Vec3 m = skeleton.joints[mid].transform(built[mid]);
	Vec3 t = skeleton.joints[tip].transform(built[tip]);
	alloc::free(allocator, built);

	float l1 = (m - r).length();
	float l2 = (t - m).length();
	Vec3 goal = target - r;
	float reach = goal.length();
	if (l1 < 1.0e-6f || l2 < 1.0e-6f || reach < 1.0e-6f) return;
	Vec3 u = goal / reach;
	float d = math::clamp(reach, math::abs(l1 - l2) + 1.0e-4f * l1, l1 + l2 - 1.0e-4f * l1);

	Vec3 side = (m - r) - u * (m - r).dot(u);
	if (side.length() < 1.0e-5f * l1) return;
	float a = (l1 * l1 - l2 * l2 + d * d) / (2.0f * d);
	float h = math::sqrt(math::max(0.0f, l1 * l1 - a * a));
	Vec3 elbow = r + u * a + side.normalize() * h;

	pin_swing(allocator, skeleton, pose, root, m - r, elbow - r, 0.0f, clamp, ctx);
	Matrix4f[]? after = rig::joint_palette(allocator, skeleton, *pose);
	if (catch after) return;
	defer alloc::free(allocator, after);
	Vec3 m2 = skeleton.joints[mid].transform(after[mid]);
	Vec3 t2 = skeleton.joints[tip].transform(after[tip]);
	pin_swing(allocator, skeleton, pose, mid, t2 - m2, target - m2, 0.0f, clamp, ctx);
}

<*
 Hold a joint's world orientation at `held`, constrained through `clamp`: the
 local rotation that, under the parent's present world rotation, comes out as
 `held`.
*>
fn void pin_hold_rotation(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose* pose,
	usz joint,
	Quaternionf held,
	AimClamp clamp = null,
	void* ctx = null)
{
	Quaternionf[]? spun = pose.world_rotations(allocator, skeleton);
	if (catch spun) return;
	Quaternionf[] world = spun;
	defer alloc::free(allocator, world);
	int parent = skeleton.parents[joint];
	Quaternionf above = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
	Quaternionf local = above.invert().mul(held).normalize();
	if (clamp) local = clamp(ctx, joint, local);
	pose.rotations[joint] = local;
}

<*
 Lay the clip's pins over `pose`, which has had its limits and its ground solve.

 Each pin finds its joint by `names` (the clip's vocabulary), takes its weight
 from the window (`AnimPin.weight_at`) times `gain`, solves the joint's limb to
 `at * scale` and holds its orientation, then slerps every joint it touched from
 where it was to where it landed by that weight. Pins run in clip order, each on
 what the last left. A pin whose joint the rig lacks, that is muted, outside its
 window, or whose limb is empty (a root, a joint under a fork) is skipped for
 position; its rotation hold still runs.

 @param scale : `The rig's height; positions are fractions of it.`
 @param gain : `Multiplies every weight, how a crossfade weights a clip's pins.`
*>
fn void pin_pose(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimPin[] pins,
	float time,
	float duration,
	bool loop,
	rig::Pose* pose,
	float scale,
	AimClamp clamp = null,
	void* ctx = null,
	float gain = 1.0f)
{
	if (pins.len == 0 || pose.rotations.len != skeleton.len()) return;
	foreach (&pin : pins)
	{
		if (!pin_plays(pin)) continue;
		float weight = pin.weight_at(time, duration, loop) * math::clamp(gain, 0.0f, 1.0f);
		if (!(weight > 0.0f)) continue;
		sz found = -1;
		foreach (usz j, name : names) if (j < skeleton.len() && name == pin.joint) { found = (sz)j; break; }
		if (found < 0) continue;
		usz joint = (usz)found;

		usz[IK_RUN_MAX] run;
		usz count = pin.position ? pin_run(skeleton, joint, run[..]) : 0;
		Quaternionf[IK_RUN_MAX + 1] before;
		for (usz k = 0; k < count; k++) before[k] = pose.rotations[run[k]];
		before[count] = pose.rotations[joint];

		if (count > 0 && pin_finite(pin.at))
		{
			(void)pin_reach(allocator, skeleton, pose, run[:count], joint, pin.at * scale,
				PIN_TOLERANCE * scale, clamp, ctx);
		}
		if (pin.rotation && math::is_finite(pin.orient.v.x) && pin.orient.v.length_sq() > 1.0e-12f)
		{
			pin_hold_rotation(allocator, skeleton, pose, joint, pin.orient.normalize(), clamp, ctx);
		}
		if (weight < 1.0f)
		{
			for (usz k = 0; k < count; k++) pose.rotations[run[k]] = slerp_short(before[k], pose.rotations[run[k]], weight);
			pose.rotations[joint] = slerp_short(before[count], pose.rotations[joint], weight);
		}
	}
}

// How long a limb a pin solves: the editor's own bound on a run.
const usz IK_RUN_MAX = 16;

fn bool pin_finite(Vec3 v) @local => math::is_finite(v.x) && math::is_finite(v.y) && math::is_finite(v.z);

<*
 Mark every joint a playing pin turns in `turned`: its limb for a position, the
 joint itself for a rotation. What a bake writes keys for.
*>
fn void pin_mark_turned(rig::Skeleton* skeleton, String[] names, AnimTemplate* clip, bool[] turned)
{
	foreach (&pin : clip.pins)
	{
		if (!pin_plays(pin)) continue;
		foreach (usz j, name : names)
		{
			if (j >= skeleton.len() || name != pin.joint) continue;
			if (pin.rotation) turned[j] = true;
			if (pin.position)
			{
				usz[IK_RUN_MAX] run;
				usz count = pin_run(skeleton, j, run[..]);
				for (usz k = 0; k < count; k++) turned[run[k]] = true;
			}
			break;
		}
	}
}

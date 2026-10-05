<*
 Look-at targets: a joint, usually the head, turned toward a point in space.

 An `AnimAim` belongs to a clip, next to its layers. It names one joint, the
 axis of that joint which should face the target (`forward`, in the joint's own
 frame), and a track of target positions over time. The turn is *spread* over the
 aimed joint and a few of its parents (head, neck, chest) with a weight each, so
 a body looks round the way a person does rather than the head screwing off.

 **The aim is applied live, never written into keys.** Keyframes keep holding
 the authored rotations; the aim is laid over a pose wherever it is shown,
 played or exported (`aim_pose`), after joint limits and after the ground solve.
 Muting or removing an aim gives the authored motion back exactly, and a target
 may move between body keys.

 **Where a target lives.** `AnimAimKey.at` is in model space as a fraction of the
 rig's height, like `AnimKeyDot.move`, so the same clip looks at the same place
 on a rig exported in metres or in centimetres.

 **Limits.** Every joint the turn touches is handed to an `AimClamp` after it is
 turned, so a neck that cannot go further leaves its share to the joint below.
 The app clamps against the document's limits, an export against the portable
 constraint table.
*>
module crig;

import rig;
import std::math;
import std::sort;
import std::math::vector;
import std::math::quaternion;

<*
 One placement of a target. `interpolation` is how the segment *leaving* this key
 is read: HOLD keeps the position, LINEAR (and INHERIT, and AUTO — which would
 overshoot a point in space) blends to the next.
*>
struct AnimAimKey
{
	float time;
	Vec3 at; // model space, fraction of rig height
	AnimInterpolation interpolation;
}

// The most joints one aim turns: the aimed joint and three parents.

// The most joints one lock turns: the locked joint and three parents.
const usz AIM_MAX_SPREAD = 4;

<*
 A look-at target: a named point in space that locks turn their joints toward,
 keyed over time. Keys are sorted by time, at least one. The name is unique in
 its clip ("Target 1"). Owned by the clip's allocator; see `AnimAimTarget.free`.
*>
struct AnimAimTarget
{
	String name;
	bool mute;
	AnimAimKey[] keys;
}

<*
 One lock on a clip: a joint that turns toward the target named `target`. Every
 string is owned by the clip's allocator and released with it; see
 `AnimAim.free`. A joint has at most one lock.
*>
struct AnimAim
{
	String joint;                  // clip vocabulary, resolved with `names_for`
	String target;                 // the name of an `AnimAimTarget` of the same clip
	Vec3 forward;                  // aim axis in the joint's frame, captured when it was locked
	usz spread;                    // 1..AIM_MAX_SPREAD joints, the aimed one first then its parents
	float[AIM_MAX_SPREAD] weights; // each joint's share, aimed joint first
	float influence;               // 0..1, how much of the turn is taken
	bool mute;
}

// What a new lock spreads over: head, neck, chest.
const float[AIM_MAX_SPREAD] AIM_DEFAULT_WEIGHTS = { 0.5f, 0.3f, 0.2f, 0.0f };

<*
 A fresh lock of `joint` on `target`, forward as given, spread over three joints
 with the default weights and full influence. Strings are copied.
*>
fn AnimAim aim_defaults(Allocator allocator, String joint, String target, Vec3 forward)
{
	return {
		.joint = joint.copy(allocator),
		.target = target.copy(allocator),
		.forward = forward,
		.spread = 3,
		.weights = AIM_DEFAULT_WEIGHTS,
		.influence = 1.0f,
	};
}

<*
 A fresh target named `name` with one LINEAR key at `at`. `name` is copied.
*>
fn AnimAimTarget aim_target_defaults(Allocator allocator, String name, Vec3 at, float time = 0.0f)
{
	AnimAimTarget out = {
		.name = name.copy(allocator),
		.keys = alloc::new_array(allocator, AnimAimKey, 1),
	};
	out.keys[0] = { .time = time, .at = at, .interpolation = LINEAR };
	return out;
}

fn void AnimAim.free(&self, Allocator allocator)
{
	if (self.joint.len > 0) alloc::free(allocator, self.joint.ptr);
	if (self.target.len > 0) alloc::free(allocator, self.target.ptr);
	*self = {};
}

fn void AnimAimTarget.free(&self, Allocator allocator)
{
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	if (self.keys.len > 0) alloc::free(allocator, self.keys);
	*self = {};
}

fn void free_aims(Allocator allocator, AnimAim[] aims)
{
	foreach (&aim : aims) aim.free(allocator);
	if (aims.len > 0) alloc::free(allocator, aims);
}

fn void free_aim_targets(Allocator allocator, AnimAimTarget[] targets)
{
	foreach (&target : targets) target.free(allocator);
	if (targets.len > 0) alloc::free(allocator, targets);
}

fn AnimAim AnimAim.copy(&self, Allocator allocator)
{
	AnimAim out = *self;
	out.joint = self.joint.len > 0 ? self.joint.copy(allocator) : "";
	out.target = self.target.len > 0 ? self.target.copy(allocator) : "";
	return out;
}

<*
 A deep copy of the target, its key times mapped `t' = t * scale + shift` —
 identity by default. A retime scales, a crop shifts. Keys that a shift would
 push below zero are dropped except the last of them, which is held at zero, so
 the target a crop starts on is still where it was.
*>
fn AnimAimTarget AnimAimTarget.copy(&self, Allocator allocator, float scale = 1.0f, float shift = 0.0f)
{
	AnimAimTarget out = *self;
	out.name = self.name.len > 0 ? self.name.copy(allocator) : "";
	usz first = 0;
	foreach (usz i, key : self.keys)
	{
		if (key.time * scale + shift <= 0.0f && i + 1 < self.keys.len
			&& self.keys[i + 1].time * scale + shift <= 0.0f) first = i + 1;
	}
	out.keys = alloc::new_array(allocator, AnimAimKey, (sz)(self.keys.len - first));
	foreach (usz i, key : self.keys[first..])
	{
		out.keys[i] = key;
		out.keys[i].time = math::max(0.0f, key.time * scale + shift);
	}
	return out;
}

fn AnimAim[] aims_copy(Allocator allocator, AnimAim[] source)
{
	AnimAim[] out = alloc::new_array(allocator, AnimAim, (sz)source.len);
	foreach (usz i, &aim : source) out[i] = aim.copy(allocator);
	return out;
}

fn AnimAimTarget[] aim_targets_copy(Allocator allocator, AnimAimTarget[] source, float scale = 1.0f, float shift = 0.0f)
{
	AnimAimTarget[] out = alloc::new_array(allocator, AnimAimTarget, (sz)source.len);
	foreach (usz i, &target : source) out[i] = target.copy(allocator, scale, shift);
	return out;
}

<*
 Every lock of a clip reflected across the symmetry plane: the joint goes to its
 twin (or stays when it has none), `forward.x` is negated; the target name stays.
 A deep copy.
*>
fn AnimAim[] aims_mirrored(Allocator allocator, AnimAim[] source)
{
	AnimAim[] out = aims_copy(allocator, source);
	foreach (&aim : out)
	{
		aim.joint = twin_or_same(allocator, aim.joint);
		aim.forward.x = -aim.forward.x;
	}
	return out;
}

// Every target reflected across the symmetry plane: `at.x` is negated, names stay.
fn AnimAimTarget[] aim_targets_mirrored(Allocator allocator, AnimAimTarget[] source)
{
	AnimAimTarget[] out = aim_targets_copy(allocator, source);
	foreach (&target : out) foreach (&key : target.keys) key.at.x = -key.at.x;
	return out;
}

// Where in `aims` the joint's lock is, or -1.
fn sz aim_index_of(AnimAim[] aims, String joint)
{
	foreach (usz i, &aim : aims) if (aim.joint == joint) return (sz)i;
	return -1;
}

// Where in `targets` the one named `name` is, or -1.
fn sz aim_target_index_of(AnimAimTarget[] targets, String name)
{
	foreach (usz i, &target : targets) if (target.name == name) return (sz)i;
	return -1;
}

// The lowest "Target N" no target uses. Owned by `allocator`.
fn String next_target_name(Allocator allocator, AnimAimTarget[] targets)
{
	for (usz n = 1;; n++)
	{
		String name = string::format(allocator, "Target %d", n);
		if (aim_target_index_of(targets, name) < 0) return name;
		alloc::free(allocator, name.ptr);
	}
}

// How many locks of `aims` point at the target `name`.
fn usz aim_target_users(AnimAim[] aims, String name)
{
	usz count;
	foreach (&aim : aims) if (aim.target == name) count++;
	return count;
}

// ---------------------------------------------------------------------------
// Sampling

<*
 Where the target is at `time`, a fraction of rig height in model space.

 The edge values are held outside the keyed range. On a looping clip the cycle
 closes: past the last key the target travels back toward the first, and before
 the first it arrives from the last, so a looking-around loop has no seam.
 HOLD keeps a key's value until the next; everything else blends linearly.

 @param duration : `The clip's length, used to wrap a looping clip's clock.`
*>
fn Vec3 AnimAimTarget.target_at(&self, float time, float duration, bool loop)
{
	usz count = self.keys.len;
	if (count == 0) return {};
	if (count == 1) return self.keys[0].at;

	bool cyclic = loop && duration > 0.0f;
	float t = time;
	if (cyclic) t = time - duration * math::floor(time / duration);

	AnimAimKey first = self.keys[0];
	AnimAimKey last = self.keys[count - 1];
	if (t <= first.time)
	{
		if (!cyclic) return first.at;
		return aim_segment(last, first, last.time - duration, first.time, t);
	}
	if (t >= last.time)
	{
		if (!cyclic) return last.at;
		return aim_segment(last, first, last.time, first.time + duration, t);
	}
	for (usz i = 0; i + 1 < count; i++)
	{
		AnimAimKey a = self.keys[i];
		AnimAimKey b = self.keys[i + 1];
		if (t >= a.time && t < b.time) return aim_segment(a, b, a.time, b.time, t);
	}
	return last.at;
}

// One segment: `a` at `from` to `b` at `to`, read at `t`.
fn Vec3 aim_segment(AnimAimKey a, AnimAimKey b, float from, float to, float t) @local
{
	if (a.interpolation == HOLD) return a.at;
	if (!(to > from)) return b.at;
	float f = math::clamp((t - from) / (to - from), 0.0f, 1.0f);
	return a.at + (b.at - a.at) * f;
}

// ---------------------------------------------------------------------------
// Clip rewriters. Pure: each answers a new owned clip and leaves its source be.

<*
 The clip with its locks and targets replaced by `next_aims` and `next_targets`,
 both taken over. The caller lands the result.
*>
fn AnimTemplate clip_with_aim_set(Allocator allocator, AnimTemplate source, AnimAim[] next_aims,
	AnimAimTarget[] next_targets)
{
	AnimTemplate clip = clip_copy(allocator, source);
	free_aims(allocator, clip.aims);
	free_aim_targets(allocator, clip.aim_targets);
	clip.aims = next_aims;
	clip.aim_targets = next_targets;
	return clip;
}

// The clip with its locks replaced by `next`, which is taken over; targets kept.
fn AnimTemplate clip_with_aims(Allocator allocator, AnimTemplate source, AnimAim[] next)
{
	return clip_with_aim_set(allocator, source, next, aim_targets_copy(allocator, source.aim_targets));
}

// The clip with its targets replaced by `next`, which is taken over; locks kept.
fn AnimTemplate clip_with_aim_targets(Allocator allocator, AnimTemplate source, AnimAimTarget[] next)
{
	return clip_with_aim_set(allocator, source, aims_copy(allocator, source.aims), next);
}

<*
 The clip with `aim` added, or replacing the lock already on its joint. `aim` is
 taken over.
*>
fn AnimTemplate clip_with_aim(Allocator allocator, AnimTemplate source, AnimAim aim)
{
	AnimAim[] one = alloc::new_array(allocator, AnimAim, 1);
	one[0] = aim;
	return clip_with_aims_added(allocator, source, one);
}

<*
 The clip with every lock of `added` put on it, each replacing the one already on
 its joint. `added` and what it holds are taken over (the array is released).
*>
fn AnimTemplate clip_with_aims_added(Allocator allocator, AnimTemplate source, AnimAim[] added)
{
	AnimAim[] next = alloc::new_array(allocator, AnimAim, (sz)(source.aims.len + added.len));
	foreach (usz i, &held : source.aims) next[i] = held.copy(allocator);
	usz used = source.aims.len;
	foreach (&aim : added)
	{
		sz at = aim_index_of(next[:used], aim.joint);
		if (at >= 0)
		{
			next[(usz)at].free(allocator);
			next[(usz)at] = *aim;
		}
		else
		{
			next[used++] = *aim;
		}
	}
	AnimAim[] fitted = alloc::new_array(allocator, AnimAim, (sz)used);
	foreach (usz i, &held : next[:used]) fitted[i] = *held;
	alloc::free(allocator, next);
	if (added.len > 0) alloc::free(allocator, added);
	return clip_with_aims(allocator, source, fitted);
}

<*
 The clip without the lock on `joint`; a plain copy when there is none. Targets
 stay.
*>
fn AnimTemplate clip_without_aim(Allocator allocator, AnimTemplate source, String joint)
{
	sz at = aim_index_of(source.aims, joint);
	if (at < 0) return clip_copy(allocator, source);
	AnimAim[] next = alloc::new_array(allocator, AnimAim, (sz)(source.aims.len - 1));
	usz write;
	foreach (usz i, &held : source.aims)
	{
		if ((sz)i == at) continue;
		next[write++] = held.copy(allocator);
	}
	return clip_with_aims(allocator, source, next);
}

<*
 The clip with `target` added, or replacing the one of its name; locks kept.
 `target` is taken over.
*>
fn AnimTemplate clip_with_aim_target(Allocator allocator, AnimTemplate source, AnimAimTarget target)
{
	sz at = aim_target_index_of(source.aim_targets, target.name);
	usz count = at >= 0 ? source.aim_targets.len : source.aim_targets.len + 1;
	AnimAimTarget[] next = alloc::new_array(allocator, AnimAimTarget, (sz)count);
	foreach (usz i, &held : source.aim_targets)
	{
		next[i] = (sz)i == at ? target : held.copy(allocator);
	}
	if (at < 0) next[count - 1] = target;
	return clip_with_aim_targets(allocator, source, next);
}

<*
 The clip without the target `name`, and without every lock that names it; a
 plain copy when there is no such target.
*>
fn AnimTemplate clip_without_aim_target(Allocator allocator, AnimTemplate source, String name)
{
	sz at = aim_target_index_of(source.aim_targets, name);
	if (at < 0) return clip_copy(allocator, source);
	AnimAimTarget[] targets = alloc::new_array(allocator, AnimAimTarget, (sz)(source.aim_targets.len - 1));
	usz write;
	foreach (usz i, &held : source.aim_targets)
	{
		if ((sz)i == at) continue;
		targets[write++] = held.copy(allocator);
	}
	AnimAim[] locks = alloc::new_array(allocator, AnimAim, (sz)(source.aims.len - aim_target_users(source.aims, name)));
	write = 0;
	foreach (&held : source.aims)
	{
		if (held.target == name) continue;
		locks[write++] = held.copy(allocator);
	}
	return clip_with_aim_set(allocator, source, locks, targets);
}

<*
 The clip with a key put on the target `name` at its own time, replacing any key
 within ANIM_SAME_TIME of it. A plain copy when there is no such target.
*>
fn AnimTemplate clip_with_target_key(Allocator allocator, AnimTemplate source, String name, AnimAimKey key)
{
	sz at = aim_target_index_of(source.aim_targets, name);
	if (at < 0) return clip_copy(allocator, source);
	AnimAimTarget[] next = aim_targets_copy(allocator, source.aim_targets);
	AnimAimTarget* target = &next[(usz)at];

	foreach (&held : target.keys)
	{
		if (math::abs(held.time - key.time) < ANIM_SAME_TIME)
		{
			*held = key;
			held.time = key.time;
			return clip_with_aim_targets(allocator, source, next);
		}
	}
	usz place = target.keys.len;
	foreach (usz i, held : target.keys)
	{
		if (held.time > key.time) { place = i; break; }
	}
	AnimAimKey[] keys = alloc::new_array(allocator, AnimAimKey, (sz)(target.keys.len + 1));
	for (usz i = 0; i < place; i++) keys[i] = target.keys[i];
	keys[place] = key;
	for (usz i = place; i < target.keys.len; i++) keys[i + 1] = target.keys[i];
	if (target.keys.len > 0) alloc::free(allocator, target.keys);
	target.keys = keys;
	return clip_with_aim_targets(allocator, source, next);
}

<*
 The clip with the keys of the target `name` at `times` (each within
 ANIM_SAME_TIME) removed. A target left with no keys goes altogether, locks and
 all, so a target is never left without a place; a plain copy when nothing matches.
*>
fn AnimTemplate clip_without_target_keys(Allocator allocator, AnimTemplate source, String name, float[] times)
{
	sz at = aim_target_index_of(source.aim_targets, name);
	if (at < 0) return clip_copy(allocator, source);
	AnimAimTarget* held = &source.aim_targets[(usz)at];

	usz kept;
	foreach (key : held.keys) if (!aim_time_listed(times, key.time)) kept++;
	if (kept == held.keys.len) return clip_copy(allocator, source);
	if (kept == 0) return clip_without_aim_target(allocator, source, name);

	AnimAimTarget[] next = aim_targets_copy(allocator, source.aim_targets);
	AnimAimTarget* target = &next[(usz)at];
	AnimAimKey[] keys = alloc::new_array(allocator, AnimAimKey, (sz)kept);
	usz write;
	foreach (key : target.keys) if (!aim_time_listed(times, key.time)) keys[write++] = key;
	alloc::free(allocator, target.keys);
	target.keys = keys;
	return clip_with_aim_targets(allocator, source, next);
}

fn bool aim_time_listed(float[] times, float time) @local
{
	foreach (t : times) if (math::abs(t - time) < ANIM_SAME_TIME) return true;
	return false;
}

// ---------------------------------------------------------------------------
// Math

<*
 Hands a joint's candidate local rotation back inside its limits. `ctx` is the
 provider's own state; `joint` indexes the skeleton the aim runs on.
*>
alias AimClamp = fn Quaternionf(void* ctx, usz joint, Quaternionf local);

<*
 The shortest turn carrying `from` onto `to`: `bone_carry`, except that when the
 two are antiparallel the half-turn is about `up` (the joint's own up axis) so a
 head told to look straight behind turns about its spine and not about a random
 perpendicular. Identity for a missing or non-finite direction.
*>
fn Quaternionf aim_carry(Vec3 from, Vec3 to, Vec3 up)
{
	if (!aim_finite(from) || !aim_finite(to)) return quaternion::IDENTITY;
	if (from.length_sq() < 1.0e-12f || to.length_sq() < 1.0e-12f) return quaternion::IDENTITY;

	Vec3 a = from.normalize();
	Vec3 b = to.normalize();
	if (a.cross(b).length() < 1.0e-6f && a.dot(b) < 0.0f)
	{
		Vec3 square = up - a * up.dot(a);
		if (!aim_finite(up) || square.length_sq() < 1.0e-8f) return bone_carry(from, to);
		return quaternion::from_axis_angle{float}(square.normalize(), (float)math::PI);
	}
	return bone_carry(from, to);
}

fn bool aim_finite(Vec3 v) @local => math::is_finite(v.x) && math::is_finite(v.y) && math::is_finite(v.z);

<*
 The shortest-arc slerp: `b` is flipped onto the same hemisphere as `a` first.
*>
fn Quaternionf slerp_short(Quaternionf a, Quaternionf b, float t)
{
	return (a.v.dot(b.v) < 0.0f ? a.slerp(-b, t) : a.slerp(b, t)).normalize();
}

<*
 The joints one aim turns: `joint` first, then its parents, at most `spread`
 (clamped to 1..AIM_MAX_SPREAD) and stopping at the root.
*>
struct AimChain
{
	usz[AIM_MAX_SPREAD] joints;
	usz count;
}

fn AimChain aim_chain_of(rig::Skeleton* skeleton, usz joint, usz spread)
{
	AimChain chain;
	usz wanted = math::clamp(spread, (usz)1, AIM_MAX_SPREAD);
	int at = (int)joint;
	while (at >= 0 && chain.count < wanted && (usz)at < skeleton.len())
	{
		chain.joints[chain.count++] = (usz)at;
		at = skeleton.parents[(usz)at];
	}
	return chain;
}

<*
 Turn `chain` so that the aimed joint's `forward` axis faces `target`.

 	`float left = aim_chain(mem, &skeleton, &pose, chain, weights, { 0, 0, 1 }, target, 1.0f, &clamp, ctx);`

 `chain` runs aimed joint first, then parents; it is walked from the top down. At
 each joint the whole turn still needed is read off the current pose and this
 joint takes its weight's share of what is left (`w_k` over the weights of it and
 the joints below it, times `influence`), so the last joint takes whatever
 remains and the aim lands on the target unless a limit stops it. A clamp that
 cuts one joint short leaves the rest for the joints below. The turn is the
 shortest arc, so the authored roll is kept. Rotations in `pose` are edited in
 place; offsets are not read or changed.

 @param pose : `Changed in place.`
 @param target : `Model-space point, in the units of the skeleton.`
 @param clamp : `Called after each joint is turned; may be null.`
 @return `The angle in radians still between the aimed axis and the target, 0 when there was nothing to aim at.`
*>
fn float aim_chain(
	Allocator allocator,
	rig::Skeleton* skeleton,
	rig::Pose* pose,
	AimChain chain,
	float[AIM_MAX_SPREAD] weights,
	Vec3 forward,
	Vec3 target,
	float influence,
	AimClamp clamp = null,
	void* ctx = null)
{
	if (chain.count == 0 || pose.rotations.len != skeleton.len() || !aim_finite(target)
		|| !aim_finite(forward) || forward.length_sq() < 1.0e-12f) return 0.0f;
	usz aimed = chain.joints[0];
	float gain = math::clamp(influence, 0.0f, 1.0f);

	float below = 0.0f; // the weight still to spend, this joint and the ones under it
	for (usz k = 0; k < chain.count; k++) below += math::max(0.0f, weights[k]);
	if (!(below > 1.0e-6f))
	{
		below = 1.0f;
		weights[0] = 1.0f;
	}

	for (usz n = chain.count; n > 0; n--)
	{
		usz k = n - 1;
		float w = math::max(0.0f, weights[k]);
		float share = math::clamp(w / below, 0.0f, 1.0f) * gain;
		below -= w;
		if (w <= 0.0f || share <= 0.0f) continue;

		Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
		if (catch built) return 0.0f;
		Matrix4f[] palette = built;
		defer alloc::free(allocator, palette);
		Quaternionf[]? spun = pose.world_rotations(allocator, skeleton);
		if (catch spun) return 0.0f;
		Quaternionf[] world = spun;
		defer alloc::free(allocator, world);

		Vec3 at = skeleton.joints[aimed].transform(palette[aimed]);
		Quaternionf turn = aim_carry(world[aimed].rotate_vec3(forward), target - at,
			world[aimed].rotate_vec3({ 0, 1, 0 }));
		Quaternionf part = slerp_short(quaternion::IDENTITY, turn, share);

		usz joint = chain.joints[k];
		int parent = skeleton.parents[joint];
		Quaternionf above = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
		Quaternionf local = above.invert().mul(part).mul(above).mul(pose.rotations[joint]).normalize();
		if (clamp) local = clamp(ctx, joint, local);
		pose.rotations[joint] = local;
	}

	Matrix4f[]? built = rig::joint_palette(allocator, skeleton, *pose);
	if (catch built) return 0.0f;
	Matrix4f[] palette = built;
	defer alloc::free(allocator, palette);
	Quaternionf[]? spun = pose.world_rotations(allocator, skeleton);
	if (catch spun) return 0.0f;
	Quaternionf[] world = spun;
	defer alloc::free(allocator, world);
	Vec3 to = target - skeleton.joints[aimed].transform(palette[aimed]);
	Vec3 now = world[aimed].rotate_vec3(forward);
	if (to.length_sq() < 1.0e-12f) return 0.0f;
	float sine = now.normalize().cross(to.normalize()).length();
	return math::atan2(sine, now.normalize().dot(to.normalize()));
}

<*
 The rotation each joint an aim touched had before it, so a gesture can take the
 aim back off. Each joint is recorded once, the first time any aim reaches it.
*>
struct AimAppliedSet
{
	usz[] joints;
	Quaternionf[] before;
}

fn bool AimAppliedSet.has(&self, usz joint)
{
	foreach (j : self.joints) if (j == joint) return true;
	return false;
}

// The recorded rotation of a joint, identity when the aims never touched it.
fn Quaternionf AimAppliedSet.before_of(&self, usz joint)
{
	foreach (usz i, j : self.joints) if (j == joint) return self.before[i];
	return quaternion::IDENTITY;
}

fn void AimAppliedSet.record(&self, Allocator allocator, usz joint, Quaternionf before)
{
	if (self.has(joint)) return;
	usz count = self.joints.len;
	usz[] joints = alloc::new_array(allocator, usz, (sz)(count + 1));
	Quaternionf[] was = alloc::new_array(allocator, Quaternionf, (sz)(count + 1));
	foreach (usz i, j : self.joints) { joints[i] = j; was[i] = self.before[i]; }
	joints[count] = joint;
	was[count] = before;
	self.free(allocator);
	self.joints = joints;
	self.before = was;
}

fn void AimAppliedSet.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.before.len > 0) alloc::free(allocator, self.before);
	*self = {};
}

<*
 Lay every unmuted lock over a pose.

 	`aim_pose(mem, &skeleton, names, clip.aims, clip.aim_targets, time, clip.duration, clip.loop, &pose, skeleton.height(), &clamp, ctx);`

 Each lock finds its joint by `names` (the clip's vocabulary) and its target by
 name, reads the target at `time` and runs `aim_chain`. Locks are applied
 parents-first (by skeleton depth), so a child locked with its parent aims after
 the parent has turned. Run it after joint limits and after the ground solve: the
 aim never feeds back into either. A lock whose joint the rig lacks, whose target
 is missing or muted, or which is muted itself is skipped.

 @param scale : `The rig's height; targets are fractions of it.`
 @param applied : `When given, receives each touched joint's rotation from before the aims. May be null.`
 @param gain : `Multiplies every influence, how a crossfade weights a clip's aims.`
*>
fn void aim_pose(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimAim[] aims,
	AnimAimTarget[] targets,
	float time,
	float duration,
	bool loop,
	rig::Pose* pose,
	float scale,
	AimClamp clamp = null,
	void* ctx = null,
	AimAppliedSet* applied = null,
	float gain = 1.0f)
{
	if (aims.len == 0) return;
	usz[] order = alloc::new_array(allocator, usz, (sz)aims.len);
	usz[] depth = alloc::new_array(allocator, usz, (sz)aims.len);
	sz[] joints = alloc::new_array(allocator, sz, (sz)aims.len);
	defer alloc::free(allocator, order);
	defer alloc::free(allocator, depth);
	defer alloc::free(allocator, joints);
	usz used;
	foreach (usz i, &aim : aims)
	{
		joints[i] = -1;
		float influence = math::clamp(aim.influence, 0.0f, 1.0f) * math::clamp(gain, 0.0f, 1.0f);
		if (aim.mute || !(influence > 0.0f)) continue;
		sz t = aim_target_index_of(targets, aim.target);
		if (t < 0 || targets[(usz)t].mute || targets[(usz)t].keys.len == 0) continue;
		foreach (usz j, name : names) if (j < skeleton.len() && name == aim.joint) { joints[i] = (sz)j; break; }
		if (joints[i] < 0) continue;
		usz d;
		int at = skeleton.parents[(usz)joints[i]];
		while (at >= 0 && d <= skeleton.len())
		{
			d++;
			at = skeleton.parents[(usz)at];
		}
		depth[i] = d;
		// Insertion by depth, stable: parents first, ties in clip order.
		usz place = used;
		while (place > 0 && depth[order[place - 1]] > d) { order[place] = order[place - 1]; place--; }
		order[place] = i;
		used++;
	}

	foreach (i : order[:used])
	{
		AnimAim* aim = &aims[i];
		AnimAimTarget* target = &targets[(usz)aim_target_index_of(targets, aim.target)];
		float influence = math::clamp(aim.influence, 0.0f, 1.0f) * math::clamp(gain, 0.0f, 1.0f);
		AimChain chain = aim_chain_of(skeleton, (usz)joints[i], aim.spread);
		if (applied)
		{
			for (usz k = 0; k < chain.count; k++)
			{
				if (aim.weights[k] > 0.0f) applied.record(allocator, chain.joints[k], pose.rotations[chain.joints[k]]);
			}
		}
		aim_chain(allocator, skeleton, pose, chain, aim.weights, aim.forward,
			target.target_at(time, duration, loop) * scale, influence, clamp, ctx);
	}
}

// Whether the lock would turn anything: unmuted, with influence, on a target
// that exists, is unmuted and has keys.
fn bool aim_plays(AnimTemplate* clip, AnimAim* aim) @local
{
	if (aim.mute || !(aim.influence > 0.0f)) return false;
	sz t = aim_target_index_of(clip.aim_targets, aim.target);
	return t >= 0 && !clip.aim_targets[(usz)t].mute && clip.aim_targets[(usz)t].keys.len > 0;
}

// ---------------------------------------------------------------------------
// Export. An aim is not a key, so a file that carries keys has to be written
// from the aimed result.

<*
 Whether any lock would turn a joint when the clip is evaluated: unmuted, on an
 unmuted target with keys, and some influence. What decides that an export has
 to bake the clip.
*>
fn bool AnimTemplate.plays_aims(&self)
{
	foreach (&aim : self.aims) if (aim_plays(self, aim)) return true;
	return false;
}

<*
 `times` with the unmuted targets' own key times added. Sorted; consumes `times`.
 A time within `ANIM_SAME_TIME` of one already there is skipped.
*>
fn float[] aim_sample_times(Allocator allocator, AnimTemplate* clip, float[] times)
{
	if (!clip.plays_aims()) return times;
	usz extra;
	foreach (&target : clip.aim_targets) if (!target.mute) extra += target.keys.len;

	float[] merged = alloc::new_array(allocator, float, (sz)(times.len + extra));
	usz used;
	foreach (time : times) merged[used++] = time;
	alloc::free(allocator, times);
	sort::quicksort(merged[:used]);
	foreach (&target : clip.aim_targets)
	{
		if (target.mute) continue;
		foreach (key : target.keys)
		{
			if (key.time > clip.duration) continue;
			bool near;
			for (usz j = 0; j < used; j++)
			{
				if (math::abs(merged[j] - key.time) < ANIM_SAME_TIME) { near = true; break; }
			}
			if (!near && used < merged.len) merged[used++] = key.time;
		}
	}
	sort::quicksort(merged[:used]);
	float[] out = alloc::new_array(allocator, float, (sz)used);
	foreach (usz i, time : merged[:used]) out[i] = time;
	alloc::free(allocator, merged);
	return out;
}

// `clip_copy`, dropping the locks and targets.
fn AnimTemplate clip_copy_without_aims(Allocator allocator, AnimTemplate source)
{
	AnimTemplate out = clip_copy(allocator, source);
	free_aims(allocator, out.aims);
	free_aim_targets(allocator, out.aim_targets);
	out.aims = {};
	out.aim_targets = {};
	return out;
}

// Samples per span when an aimed or pinned clip is written into keys.
const usz AIM_FLAT_STEPS = 4;

<*
 The clip with its unmuted aims and pins baked into its keys, and none left.

 Pins are laid over each sample first and the aims after, the viewport's order; the
 joints a pin's limb turns get keys like the aimed ones.

 Sampled at the clip's key times, the aims' own key times and a few instants in
 every span between them (the turn is not linear in the target), each sample the
 aimed pose. Only the joints an aim turns get keys written, rotation only and
 linear, so the rest of the clip keeps the keys it was authored with. Layers are
 not touched; flatten them first.

 A clip with nothing to bake comes back as a plain copy without aims.

 @param constraints : `Limits the turn is held inside; empty for none.`
*>
fn AnimTemplate clip_aims_flattened(Allocator allocator, AnimTemplate source,
	rig::Skeleton* skeleton, String[] names, ConstraintRig constraints = {})
{
	if (!source.plays_live_layers() || !(source.duration > 0.0f))
	{
		AnimTemplate plain = clip_copy_without_aims(allocator, source);
		free_pins(allocator, plain.pins);
		plain.pins = {};
		return plain;
	}

	float[] seed = alloc::new_array(allocator, float, (sz)source.keyframes.len);
	foreach (usz i, frame : source.keyframes) seed[i] = frame.time;
	float[] keyed = pin_sample_times(allocator, &source, aim_sample_times(allocator, &source, seed));
	defer alloc::free(allocator, keyed);

	// The spans between those, cut finer.
	usz steps = AIM_FLAT_STEPS;
	float[] at = alloc::new_array(allocator, float, (sz)(keyed.len * steps + 1));
	defer alloc::free(allocator, at);
	usz count;
	foreach (usz i, time : keyed)
	{
		float to = i + 1 < keyed.len ? keyed[i + 1] : time;
		for (usz s = 0; s < steps; s++)
		{
			if (i + 1 >= keyed.len && s > 0) break;
			at[count++] = time + (to - time) * (float)s / (float)steps;
		}
	}

	// Which joints the aims turn.
	bool[] turned = alloc::new_array(allocator, bool, (sz)skeleton.len());
	defer alloc::free(allocator, turned);
	foreach (&aim : source.aims)
	{
		if (!aim_plays(&source, aim)) continue;
		foreach (usz j, name : names)
		{
			if (j >= skeleton.len() || name != aim.joint) continue;
			AimChain chain = aim_chain_of(skeleton, j, aim.spread);
			for (usz k = 0; k < chain.count; k++) if (aim.weights[k] > 0.0f) turned[chain.joints[k]] = true;
			break;
		}
	}

	pin_mark_turned(skeleton, names, &source, turned);

	ConstraintRig held = constraints;
	ConstraintAimContext ctx = { .skeleton = skeleton, .constraints = &held };
	Vec3[] bones = skeleton.bone_directions(allocator);
	defer alloc::free(allocator, bones);

	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, (sz)count);
	foreach (usz s, time : at[:count])
	{
		rig::Pose pose = source.pose(allocator, skeleton, names, time, false, honor_solo: false);
		defer pose.free(allocator);
		if (source.ground.solves()) ground_pose(allocator, skeleton, names, source.ground, &pose, source.phase_at(time));
		pin_pose(allocator, skeleton, names, source.pins, time, source.duration, source.loop, &pose,
			skeleton.height(), constraints.constrains_pose() ? &constraint_rig_aim_clamp : null, &ctx);
		aim_pose(allocator, skeleton, names, source.aims, source.aim_targets, time, source.duration, source.loop, &pose,
			skeleton.height(), constraints.constrains_pose() ? &constraint_rig_aim_clamp : null, &ctx);

		AnimDotList dots;
		dots.init(allocator);
		sz own = -1;
		foreach (usz k, frame : source.keyframes) if (math::abs(frame.time - time) < ANIM_SAME_TIME) { own = (sz)k; break; }
		if (own >= 0) foreach (dot : source.keyframes[(usz)own].dots) dots.push(dot.copy(allocator));
		foreach (usz j, name : names)
		{
			if (j >= skeleton.len() || !turned[j] || name.len == 0) continue;
			Vec3 axis;
			float angle;
			axis_angle_of(pose.rotations[j], &axis, &angle);
			bool found;
			foreach (&dot : dots)
			{
				if (dot.joint_name != name) continue;
				dot.channels = dot.channels == TRANSLATION ? BOTH : (dot.channels == BOTH ? BOTH : ROTATION);
				dot.rotation_interpolation = LINEAR;
				dot.rotation_ease = {};
				dot.axis = axis;
				dot.angle = angle;
				dot.bone = bones[j];
				found = true;
				break;
			}
			if (found) continue;
			dots.push({
				.joint_name = name.copy(allocator),
				.channels = ROTATION,
				.rotation_interpolation = LINEAR,
				.axis = axis,
				.angle = angle,
				.bone = bones[j],
			});
		}
		frames[s] = { .time = time, .dots = dots.to_array(allocator) };
		dots.free();
	}

	AnimTemplate out = clip_with_frames(allocator, source, frames, source.duration);
	free_aims(allocator, out.aims);
	free_aim_targets(allocator, out.aim_targets);
	out.aims = {};
	out.aim_targets = {};
	free_pins(allocator, out.pins);
	out.pins = {};
	out.compile_tracks(allocator);
	return out;
}

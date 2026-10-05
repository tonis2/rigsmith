<*
 What an animation template is, and what playing one means.

 A template is a sequence of per-joint rotations and slides that can be applied
 to a rigged mesh to preview motion — a walk, a run. This file is the shape and
 the arithmetic; it holds no animations of its own. They are data: read off disk
 by anim/import.c3 at startup, written by anim/export.c3, and the ones
 crig ships with are made by tools/make_anims.c3.

 A keyframe gives a joint a rotation, a slide, or both, all relative to rest.
 Omission means no key on that channel: sampling uses that channel's own
 surrounding keys rather than pulling it toward rest at unrelated whole-pose
 frames. `AnimTemplate.pose` is the common sampler used by playback and export.

 The joint names must match the names on the document's dots, which are set by
 the body-plan presets (BIPED_DOTS etc) and persisted in the session file.
 Mirror pairs carry _L / _R suffixes, set by fit_preset in core/presets.c3.

 **Which way an angle turns.** A pose rotation here is about a *world* axis
 through the joint, not about the bone — see the frames note in rig/pose.c3 —
 and a glTF model faces +Z with +Y up. Rotating a limb that hangs downward by a
 positive angle about X therefore swings its far end toward -Z:

     thigh, shoulder   positive swings the limb backward, negative forward
     knee              positive only — a knee bends backward and nothing else
     elbow             negative only — a forearm comes forward
     ankle             positive points the toes down, negative lifts them
     spine             positive leans the torso forward

 A limb that bends the wrong way is the one error in a template that reads as
 broken rather than as bad timing, so the sign of a knee or an elbow is worth
 checking against this table before trusting a new pose. An imported template
 carries the bone it was authored against, and `AnimTemplate.pose` turns each
 joint's motion onto the bone the rig it is played on actually has, which is
 what makes the convention portable rather than something every source has to
 have agreed with in advance.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::sort;



<*
 One named joint's rotation and slide in a keyframe.

 One axis per joint per keyframe: a template can lean a torso or twist it, not
 both at once. Compound rotations would need a quaternion per entry, which is
 harder to author by hand — though an importer has no such trouble, and an
 axis and an angle carry a quaternion exactly, so this costs nothing there.

 `move` is measured in **fractions of the rig's height**, not in model units. A
 template is a shape, and the meshes it plays on arrive at whatever scale they
 were exported at — a bob written as "0.02" would be two centimetres on a figure
 a metre tall and invisible on one a hundred units tall. Angles need no such
 treatment, which is why this is the only field that carries the caveat.

 `bone` is which way the joint's bone pointed on the rig this entry was authored
 against, and it is what lets the entry survive being played on a different one.
 A world-axis rotation means different things on rigs whose limbs rest in
 different directions — see `Skeleton.bone_directions` — so an entry that
 remembers its origin can have its motion carried across; `AnimTemplate.pose` is
 where that happens. Zero means "no idea", which is the honest answer for a
 hand-written template and leaves the entry exactly as written.
*>
enum AnimChannels
{
	BOTH,
	ROTATION,
	TRANSLATION,
}

<*
 How one keyed channel leaves this key on its way to the next one.

 `INHERIT` is the compact legacy/default value: it resolves to the clip's
 existing blend (`LINEAR` or `SMOOTH`). The three authored choices are named
 after what the animation UI shows. Keeping an inherit value is what lets every
 clip written before segment interpolation retain exactly the curve it had.
*>
enum AnimInterpolation
{
	INHERIT,
	HOLD,
	LINEAR,
	AUTO,
}

fn String AnimInterpolation.serialized(self)
{
	switch (self)
	{
		case HOLD: return "hold";
		case LINEAR: return "linear";
		case AUTO: return "auto";
		default: return "";
	}
}

fn bool parse_anim_interpolation(String value, AnimInterpolation* out)
{
	switch (value)
	{
		case "hold": *out = HOLD; return true;
		case "linear": *out = LINEAR; return true;
		case "auto": *out = AUTO; return true;
		default: return false;
	}
}

<*
 How an outgoing segment spends its time: a remap of the fraction from 0 to 1
 before the turn or slide reads it, so a quaternion segment stays a slerp or the
 same cubic, only paced differently.

 `start` slows the segment's opening (ease in), `end` its arrival (ease out),
 each from 0 (untouched) to 1 (a flat tangent at that end). The remap is the
 cubic Bezier with values 0, (1 - start) / 3, 1 - (1 - end) / 3, 1 at evenly
 spaced times, which is monotone for both in 0..1 and exactly the identity when
 both are 0 — so an unset ease leaves every clip bit-identical.
*>
struct AnimEase
{
	float start;
	float end;
}

fn bool AnimEase.none(self) => self.start == 0.0f && self.end == 0.0f;

fn float AnimEase.remap(self, float t)
{
	if (self.none()) return t;
	float a = (1.0f - self.start) / 3.0f;
	float c = 1.0f - (1.0f - self.end) / 3.0f;
	float u = 1.0f - t;
	return 3.0f * u * u * t * a + 3.0f * u * t * t * c + t * t * t;
}

// Clamped into 0..1, a non-finite part read as 0.
fn AnimEase AnimEase.clamped(self)
{
	return {
		math::is_finite(self.start) ? math::clamp(self.start, 0.0f, 1.0f) : 0.0f,
		math::is_finite(self.end) ? math::clamp(self.end, 0.0f, 1.0f) : 0.0f,
	};
}

fn bool AnimEase.same(self, AnimEase other)
{
	return math::abs(self.start - other.start) < 1.0e-4f && math::abs(self.end - other.end) < 1.0e-4f;
}

struct AnimKeyDot
{
	String joint_name;
	AnimChannels channels; // zero/default = both, preserving existing clips
	// Outgoing segment modes are independent for the two sparse channels. A dot
	// can key both at one instant without forcing a held foot position to hold a
	// rotation as well.
	AnimInterpolation rotation_interpolation;
	AnimInterpolation translation_interpolation;
	// The outgoing segment's pacing per channel; zero = none. Hold ignores it.
	AnimEase rotation_ease;
	AnimEase translation_ease;
	Vec3 axis;   // unit vector, world frame through the joint
	float angle; // radians, right-hand rule about axis
	Vec3 move;   // fraction of rig height, parent's posed frame; zero = stays put
	Vec3 bone;   // unit direction of the source rig's bone; zero = do not retarget
}

fn bool AnimKeyDot.keys_rotation(self) => self.channels == BOTH || self.channels == ROTATION;
fn bool AnimKeyDot.keys_translation(self) => self.channels == BOTH || self.channels == TRANSLATION;
fn AnimEase AnimKeyDot.ease(self, bool rotation) => rotation ? self.rotation_ease : self.translation_ease;

fn AnimInterpolation AnimKeyDot.interpolation(self, bool rotation, AnimBlend blend)
{
	AnimInterpolation stated = rotation
		? self.rotation_interpolation : self.translation_interpolation;
	if (stated != INHERIT) return stated;
	return blend == SMOOTH ? AUTO : LINEAR;
}

<*
 One instant in time: sparse keys for whichever joint channels change here.
*>
struct AnimKeyframe
{
	float time;        // seconds from start of animation
	AnimKeyDot[] dots; // channel keys; omissions impose no constraint
}

<*
 The shortest turn carrying `from` onto `to`.

 Identity whenever there is no correction to make or no way to know one — either
 direction missing, or the two already aligned. Antiparallel directions are the
 one case with no shortest turn, since every half-turn about a perpendicular
 axis is equally short; one is picked, which is as good an answer as exists for
 a rig built pointing the other way.
*>
fn Quaternionf bone_carry(Vec3 from, Vec3 to)
{
	if (from.length_sq() < 1.0e-12f || to.length_sq() < 1.0e-12f) return quaternion::IDENTITY;

	Vec3 a = from.normalize();
	Vec3 b = to.normalize();
	Vec3 cross = a.cross(b);
	float sine = cross.length();
	float cosine = a.dot(b);

	if (sine < 1.0e-6f)
	{
		if (cosine > 0.0f) return quaternion::IDENTITY;
		// Half a turn about anything square to the bone. The cross product with
		// whichever world axis the bone leans on least is square to it and cannot
		// come out near zero.
		Vec3 world = math::abs(a.x) < 0.9f ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
		return quaternion::from_axis_angle{float}(a.cross(world).normalize(), (float)math::PI);
	}

	// atan2 rather than acos: it stays accurate for the small corrections that
	// two similar rigs produce, where acos loses most of its precision.
	return quaternion::from_axis_angle{float}(cross / sine, math::atan2(sine, cosine));
}

<*
 Whether a clip's bone and the target's differ at rest by an arm held at another
 height — the A-pose against the T-pose — rather than by how the two rigs are
 built.

 	`if (rest_pose_differs(source_bone, target_bone)) { … }`

 A clip carries its motion onto the target relative to each rig's own rest
 (`bone_carry`), which is right for everything a rig's builder decided: a
 clavicle drawn forward, a spine leaning back. It is wrong for one thing,
 which is the pose the figure was modelled standing in. A clip authored on a
 figure whose arms hang at forty-five degrees keys an idle as "the arms at
 rest", and carried relative to a T-posed target's rest, that idle holds the
 arms straight out. So for this one difference the target takes the source's
 pose: a bone that points sideways on both rigs, turned from the other's by
 more than `REST_ALIGN_MIN` about an axis within `REST_ALIGN_AXIS` of the
 figure's front — a sideways arm swung up or down, which is the whole of what
 separates an A-pose from a T-pose. Anything else is left to the carry.
*>
fn bool rest_pose_differs(Vec3 source, Vec3 target)
{
	if (source.length_sq() < 1.0e-12f || target.length_sq() < 1.0e-12f) return false;
	Vec3 a = source.normalize();
	Vec3 b = target.normalize();
	if (math::min(math::abs(a.x), math::abs(b.x)) < REST_ALIGN_SIDEWAYS) return false;
	Vec3 axis = a.cross(b);
	float sine = axis.length();
	if (math::atan2(sine, a.dot(b)) < REST_ALIGN_MIN) return false;
	return math::abs(axis.z) / sine >= REST_ALIGN_AXIS;
}

// The least turn between two rigs' rest arms that counts as a different pose
// rather than two builders placing a shoulder a little differently: ten
// degrees. An A-pose is thirty to fifty.
const float REST_ALIGN_MIN = 0.1745f;

// How nearly the turn between the two arms has to be about the figure's front,
// as the cosine of the angle between them: thirty degrees. A clavicle drawn
// forward on one rig and not the other turns about an axis far off it.
const float REST_ALIGN_AXIS = 0.866f;

// How sideways a bone has to point on both rigs to be an arm: an arm hanging at
// sixty degrees still points this far out. Both, because a joint that branches
// measures its bone toward one of its children — a chest toward a clavicle —
// and reads as sideways on one rig and upright on the other.
const float REST_ALIGN_SIDEWAYS = 0.4f;

<*
 A quaternion as the axis and angle a keyframe entry stores.

 	`if (axis_angle_of(turn, &dot.axis, &dot.angle)) { … }`

 Normalized on the way through, and negated first when the scalar part is
 negative — the same turn written the short way round, so a small correction
 reads as a small angle rather than as very nearly a full revolution. That
 matters wherever an angle is shown to somebody or compared against a threshold.

 @return `False for a quaternion with no length, which names no rotation and cannot be normalized into one. The outputs are then left at rest.`
*>
fn bool axis_angle_of(Quaternionf turn, Vec3* axis, float* angle)
{
	*axis = { 0, 1, 0 };
	*angle = 0;

	float length = turn.length();
	if (length < 1.0e-6f) return false;

	Quaternionf unit = { .v = turn.v / length };
	if (unit.v.w < 0.0f) unit = -unit;

	Vec4 decomposed = unit.to_axis_angle();
	*axis = decomposed.xyz;
	*angle = decomposed.w;
	return true;
}

<*
 The rotation key this frame gives a named joint, or identity when it has none.
 The sparse sampler checks channel presence separately, so this fallback is only
 a value convenience and never turns omission into an implicit rest key.

 This is the entry in the frame the clip was authored in. Playing it on another
 rig means carrying it first — see `AnimTemplate.pose`, which is the only place
 that is done and the only place it can be done correctly.
*>
fn Quaternionf AnimKeyframe.rotation_of(self, String joint_name)
{
	foreach (dot : self.dots)
	{
		if (dot.joint_name != joint_name || !dot.keys_rotation()) continue;

		// An entry that only slides its joint carries no axis, and needs no guard
		// for it: `normalize` returns a zero vector unchanged rather than dividing
		// by zero, and a quaternion with no vector part is not a rotation of any
		// size, so it converts to the identity whatever angle sits beside it.
		return quaternion::from_axis_angle{float}(dot.axis.normalize(), dot.angle);
	}
	return quaternion::IDENTITY;
}

<*
 Whether this keyframe has anything to say about the named joint.

 Distinct from `rotation_of` answering identity, which a keyframe also does for
 a joint it names and only slides. `AnimTemplate.pose` needs the difference: a
 joint no keyframe mentions must be left at its own rest rather than carried,
 and carrying a joint the clip never drives would move it.
*>
fn bool AnimKeyframe.names(self, String joint_name)
{
	foreach (dot : self.dots)
	{
		if (dot.joint_name == joint_name) return true;
	}
	return false;
}

<*
 Whether two sparse keyframes carry the same channel masks and keyed values.

 Compared by joint rather than array position because entries may be ordered
 differently. Omission is not an evaluated rest pose: it means no key on that
 channel, so both frames must name the same joints and the same masks before
 their rotation and translation values can be considered equal.
*>
fn bool AnimKeyframe.same_pose(self, AnimKeyframe other)
{
	foreach (dot : self.dots)
	{
		if (!other.names(dot.joint_name)) return false;
		foreach (entry : other.dots)
		{
			if (entry.joint_name == dot.joint_name && entry.channels != dot.channels) return false;
		}
	}
	foreach (dot : other.dots)
	{
		if (!self.names(dot.joint_name)) return false;

		Quaternionf mine = self.rotation_of(dot.joint_name);
		Quaternionf theirs = other.rotation_of(dot.joint_name);
		// Either sign is the same turn, so the shorter of the two comparisons is
		// the one that answers.
		if (1.0f - math::abs(mine.v.dot(theirs.v)) > ANIM_SAME_POSE_EPSILON) return false;
		if ((self.offset_of(dot.joint_name) - other.offset_of(dot.joint_name)).length() > ANIM_SAME_POSE_EPSILON) return false;
	}
	return true;
}

// How far two keyframes may differ and still count as the same pose. Loose
// enough to survive a clip that went out through a file as float32 and came
// back, tight enough that no motion anybody authored hides under it.
const float ANIM_SAME_POSE_EPSILON @local = 1.0e-5f;

<*
 The translation key this frame gives a named joint, in fractions of rig height,
 or zero when it has none. Channel presence is checked separately by the sparse
 sampler.
*>
fn Vec3 AnimKeyframe.offset_of(self, String joint_name)
{
	foreach (dot : self.dots)
	{
		if (dot.joint_name == joint_name && dot.keys_translation()) return dot.move;
	}
	return { 0, 0, 0 };
}

<*
 How a clip moves between the keyframes it is given.

 `LINEAR` turns by SLERP and slides by a straight line, and is what every
 template written before this existed does. `SMOOTH` fits a cubic through each
 keyframe and its neighbours, so a cycle can be stated as the poses it passes
 through — contact, toe-off, reach — rather than as a resampling of them.

 The difference is in the sampler, not in the data: both read the same
 keyframes, and either mode can be set on any clip.
*>
enum AnimBlend
{
	LINEAR,
	SMOOTH,
}

struct AnimTrack
{
	String joint_name; // borrowed from a key dot
	usz[] rotations;   // keyframe indices
	usz[] translations;
}

<*
 A named, reusable animation.

 `owned` separates a template an importer allocated from one written out as a
 constant — the generator's tables, a test's fixture — which points at static
 data and must never be freed. A list can hold both and free what it should by
 asking.

 The struct copies freely — the player takes one by value — so `owned` marks the
 template, not the copy. Free it once, through whoever loaded it, and only after
 nothing is still playing it.
*>
struct AnimTemplate
{
	String name;
	float duration; // total length in seconds
	AnimKeyframe[] keyframes;
	bool loop;
	AnimBlend blend;
	AnimGround ground; // no feet named = no solve; see anim/ground.c3
	// Adjustments laid over the keys, in order; see anim/layers.c3. Owned with an
	// owned template and persisted in the project sidecar only.
	AnimLayer[] layers;
	AnimTrack[] tracks; // compiled sparse lookup, owned with an owned template
	bool tracks_compiled;
	bool owned; // heap-allocated; false for a template written out as a constant

	// A stub whose keyframes have not been read yet. A pack loaded to bind a clip
	// knows every clip's name and length up front but retargets none of them — the
	// expensive part — until one is actually sampled. `source` is the clip's glTF
	// animation index, imported from the pack's held stream on demand. False (the
	// zero value) is an ordinary, fully-read template, so every literal elsewhere
	// is unaffected. See `AppState.ensure_clip_imported`.
	bool lazy;
	int source;
}

fn void AnimTemplate.compile_tracks(&self, Allocator allocator)
{
	foreach (track : self.tracks)
	{
		if (track.rotations.len > 0) alloc::free(allocator, track.rotations);
		if (track.translations.len > 0) alloc::free(allocator, track.translations);
	}
	if (self.tracks.len > 0) alloc::free(allocator, self.tracks);
	self.tracks = {};

	usz entries = 0;
	foreach (frame : self.keyframes) entries += frame.dots.len;
	if (entries == 0)
	{
		self.tracks_compiled = true;
		return;
	}

	// Discover names in temporary maximum-sized storage, then keep an exact-sized
	// track table. The sampler retains no allocation proportional to key count.
	String[] names = alloc::new_array(allocator, String, (sz)entries);
	defer alloc::free(allocator, names);
	usz unique = 0;
	foreach (frame : self.keyframes)
	{
		foreach (dot : frame.dots)
		{
			bool seen = false;
			for (usz i = 0; i < unique; i++)
			{
				if (names[i] == dot.joint_name) { seen = true; break; }
			}
			if (!seen) names[unique++] = dot.joint_name;
		}
	}
	self.tracks = alloc::new_array(allocator, AnimTrack, (sz)unique);
	foreach (usz i, name : names[:unique]) self.tracks[i].joint_name = name;

	usz[] rotations = alloc::new_array(allocator, usz, (sz)unique);
	usz[] translations = alloc::new_array(allocator, usz, (sz)unique);
	defer
	{
		alloc::free(allocator, rotations);
		alloc::free(allocator, translations);
	}
	// Count once per channel per frame; malformed duplicate entries in one frame
	// still compile to the first value the frame accessors return.
	foreach (frame : self.keyframes)
	{
		for (usz i = 0; i < unique; i++)
		{
			AnimKeyDot dot;
			if (frame.channel_dot(names[i], true, &dot)) rotations[i]++;
			if (frame.channel_dot(names[i], false, &dot)) translations[i]++;
		}
	}
	for (usz i = 0; i < unique; i++)
	{
		if (rotations[i] > 0) self.tracks[i].rotations = alloc::new_array(allocator, usz, (sz)rotations[i]);
		if (translations[i] > 0) self.tracks[i].translations = alloc::new_array(allocator, usz, (sz)translations[i]);
		rotations[i] = 0;
		translations[i] = 0;
	}
	foreach (usz f, frame : self.keyframes)
	{
		for (usz i = 0; i < unique; i++)
		{
			AnimKeyDot dot;
			if (frame.channel_dot(names[i], true, &dot)) self.tracks[i].rotations[rotations[i]++] = f;
			if (frame.channel_dot(names[i], false, &dot)) self.tracks[i].translations[translations[i]++] = f;
		}
	}
	// Sorted by name so `compiled_indices` can binary-search a joint's track rather
	// than scan every one. The sampler resolves a track many times per joint per
	// frame, so an O(log n) lookup here is the difference between a clip that plays
	// for free and one that pins a core; nothing downstream depends on discovery
	// order.
	sort::quicksort(self.tracks, &track_by_name);
	self.tracks_compiled = true;
}

// Bytewise, the order the binary search in `compiled_indices` agrees with. The
// exact order is immaterial — only that the compile and the lookup share it.
fn int track_by_name(AnimTrack a, AnimTrack b) @local => a.joint_name.compare_to(b.joint_name);

<*
 Release a keyframe nothing took ownership of.

 A key handed to `clip_with_key` is the clip's and goes with it; one built and
 kept standing — a clipboard, a rewriter's refused input — has no other owner.
*>
fn void AnimKeyframe.free(&self, Allocator allocator)
{
	foreach (dot : self.dots)
	{
		if (dot.joint_name.len > 0) alloc::free(allocator, dot.joint_name.ptr);
	}
	if (self.dots.len > 0) alloc::free(allocator, self.dots);
	*self = {};
}

<*
 Release a template an importer allocated. Does nothing to one that points at
 static data, so it is safe to call across a mixed list.
*>
fn void AnimTemplate.free(&self, Allocator allocator)
{
	if (!self.owned) return;

	foreach (frame : self.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.joint_name.len > 0) alloc::free(allocator, dot.joint_name.ptr);
		}
		if (frame.dots.len > 0) alloc::free(allocator, frame.dots);
	}
	if (self.keyframes.len > 0) alloc::free(allocator, self.keyframes);
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	foreach (track : self.tracks)
	{
		if (track.rotations.len > 0) alloc::free(allocator, track.rotations);
		if (track.translations.len > 0) alloc::free(allocator, track.translations);
	}
	if (self.tracks.len > 0) alloc::free(allocator, self.tracks);
	self.ground.free(allocator);
	free_layers(allocator, self.layers);
	*self = {};
}

// How close to `duration` a final keyframe has to sit to be read as the loop
// closing rather than as a key of its own. One microsecond: far below any
// keyframe spacing anybody would author, far above float rounding on a time
// computed as a fraction of a duration.
const float ANIM_CLOSE_EPSILON @local = 1.0e-6f;

<*
 Where the clock falls, as the two keyframes it is between plus the two the
 curve leans on outside them.

 `p1` and `p2` are the segment's own ends and are all `LINEAR` reads; `p0` and
 `p3` are their outward neighbours, which only `SMOOTH` needs. The three spans
 are seconds, taken from times that have been *unrolled* — on a looping clip
 `p0` may sit a whole duration before `p1` — so a tangent divides by the real
 gap rather than by one folded through the wrap.
*>
struct AnimSpan @local
{
	usz p0, p1, p2, p3;
	float blend; // 0 at p1, 1 at p2
	float span;  // p2's time less p1's
	float left;  // p2's time less p0's — the tangent at p1 divides by this
	float right; // p3's time less p1's — the tangent at p2 divides by this
	AnimInterpolation interpolation;
	AnimEase ease; // p1's outgoing pacing
}

// The fraction the curve reads: `blend` through the segment's ease.
fn float AnimSpan.fraction(self) => self.ease.remap(self.blend);

<*
 One scalar across the span: cubic Hermite with Catmull-Rom tangents.

 The tangents are finite differences over the *unrolled* gaps — `(v2 - v0) /
 left` and `(v3 - v1) / right` — rather than over key indices, so keys spaced
 unevenly in time produce the curve their spacing asks for instead of
 overshooting between the close-together ones. Scaling each by `span` is what
 puts the Hermite basis on the unit interval.

 This is what glTF `CUBICSPLINE` evaluates, which is why a clip written here and
 one baked into a file can be made to agree.
*>
fn float AnimSpan.through(self, float v0, float v1, float v2, float v3)
{
	float m1 = self.left > 0.0f ? (v2 - v0) / self.left * self.span : 0.0f;
	float m2 = self.right > 0.0f ? (v3 - v1) / self.right * self.span : 0.0f;

	float t = self.fraction();
	float square = t * t;
	float cube = square * t;
	return (2 * cube - 3 * square + 1) * v1
		+ (cube - 2 * square + t) * m1
		+ (-2 * cube + 3 * square) * v2
		+ (cube - square) * m2;
}

<*
 A turn across the span, in whichever way the span asks for.

 Smooth, the cubic runs component-wise and the result is normalized — a cubic
 through four points on the unit sphere leaves it, and renormalizing is what
 brings it back. The four are sign-aligned to `q1` first: a quaternion and its
 negation are the same rotation, so two adjacent keys that happen to be written
 on opposite hemispheres give a tangent pointing the long way round, and the
 clip then spins between two keys it lands on exactly.
*>
fn Quaternionf AnimSpan.turn(self, Quaternionf q0, Quaternionf q1, Quaternionf q2, Quaternionf q3)
{
	if (self.interpolation == HOLD) return self.blend >= 1.0f ? q2 : q1;
	if (self.interpolation != AUTO) return q1.slerp(q2, self.fraction()).normalize();

	if (q0.v.dot(q1.v) < 0.0f) q0 = -q0;
	if (q2.v.dot(q1.v) < 0.0f) q2 = -q2;
	if (q3.v.dot(q2.v) < 0.0f) q3 = -q3;

	Quaternionf out = { .v = {
		self.through(q0.v.x, q1.v.x, q2.v.x, q3.v.x),
		self.through(q0.v.y, q1.v.y, q2.v.y, q3.v.y),
		self.through(q0.v.z, q1.v.z, q2.v.z, q3.v.z),
		self.through(q0.v.w, q1.v.w, q2.v.w, q3.v.w),
	} };
	return out.normalize();
}

// A slide across the span. Straight line when the span is linear — a
// displacement's shortest path is the line — and the same cubic per component
// when it is not.
fn Vec3 AnimSpan.slide(self, Vec3 v0, Vec3 v1, Vec3 v2, Vec3 v3)
{
	if (self.interpolation == HOLD) return self.blend >= 1.0f ? v2 : v1;
	if (self.interpolation != AUTO) return v1 + (v2 - v1) * self.fraction();

	return {
		self.through(v0.x, v1.x, v2.x, v3.x),
		self.through(v0.y, v1.y, v2.y, v3.y),
		self.through(v0.z, v1.z, v2.z, v3.z),
	};
}

fn bool AnimKeyframe.channel_dot(self, String joint, bool rotation, AnimKeyDot* out)
{
	foreach (dot : self.dots)
	{
		if (dot.joint_name != joint) continue;
		if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
		*out = dot;
		return true;
	}
	return false;
}

fn usz[] AnimTemplate.compiled_indices(self, String joint, bool rotation)
{
	if (!self.tracks_compiled) return {};
	// The tracks were sorted by name at compile — binary-search rather than scan,
	// because this is called many times per joint per frame.
	usz lo = 0;
	usz hi = self.tracks.len;
	while (lo < hi)
	{
		usz mid = (lo + hi) / 2;
		int order = self.tracks[mid].joint_name.compare_to(joint);
		if (order == 0) return rotation ? self.tracks[mid].rotations : self.tracks[mid].translations;
		if (order < 0) { lo = mid + 1; } else { hi = mid; }
	}
	return {};
}

fn usz AnimTemplate.channel_count(self, String joint, bool rotation)
{
	if (self.tracks_compiled) return self.compiled_indices(joint, rotation).len;
	usz count = 0;
	foreach (frame : self.keyframes)
	{
		AnimKeyDot ignored;
		if (frame.channel_dot(joint, rotation, &ignored)) count++;
	}
	return count;
}

// Whether any keyed, non-held segment is paced by an ease.
fn bool AnimTemplate.uses_easing(self)
{
	foreach (frame : self.keyframes) foreach (dot : frame.dots)
	{
		if (dot.keys_rotation() && !dot.rotation_ease.none()
			&& dot.interpolation(true, self.blend) != HOLD) return true;
		if (dot.keys_translation() && !dot.translation_ease.none()
			&& dot.interpolation(false, self.blend) != HOLD) return true;
	}
	return false;
}

fn bool AnimTemplate.uses_interpolation(self, AnimInterpolation interpolation)
{
	foreach (frame : self.keyframes) foreach (dot : frame.dots)
	{
		if (dot.keys_rotation() && dot.interpolation(true, self.blend) == interpolation) return true;
		if (dot.keys_translation() && dot.interpolation(false, self.blend) == interpolation) return true;
	}
	return false;
}

// The keyframe index of a channel's `ordinal`-th key. Read straight from a
// track already resolved by the caller when the clip is compiled, and scanned
// only for the uncompiled fallback. `track` is `compiled_indices(joint,
// rotation)`, looked up once so a span search does not re-resolve the track on
// every key it visits.
fn usz AnimTemplate.key_of(self, usz[] track, String joint, bool rotation, usz ordinal)
{
	if (self.tracks_compiled) return track[ordinal];
	usz seen = 0;
	foreach (usz i, frame : self.keyframes)
	{
		AnimKeyDot ignored;
		if (!frame.channel_dot(joint, rotation, &ignored)) continue;
		if (seen++ == ordinal) return i;
	}
	return 0;
}

// A channel's `ordinal`-th key, wrapped into the cycle when the clip loops and
// clamped to the ends when it does not. `track` is as for `key_of`.
fn usz AnimTemplate.key_at(self, usz[] track, String joint, bool rotation, sz ordinal,
	usz cycle, bool cyclic, float* time)
{
	if (!cyclic)
	{
		usz at = (usz)math::clamp(ordinal, (sz)0, (sz)cycle - 1);
		usz key = self.key_of(track, joint, rotation, at);
		*time = self.keyframes[key].time;
		return key;
	}
	sz turns = ordinal >= 0 ? ordinal / (sz)cycle : -(((sz)cycle - 1 - ordinal) / (sz)cycle);
	usz at = (usz)(ordinal - turns * (sz)cycle);
	usz key = self.key_of(track, joint, rotation, at);
	*time = self.keyframes[key].time + (float)turns * self.duration;
	return key;
}

fn bool AnimTemplate.channel_span(self, String joint, bool rotation, float time, AnimSpan* out)
{
	// Resolve the joint's track once. The span search below reads keys out of it
	// repeatedly, and re-resolving the track on each read is what made a sample
	// O(keys × tracks) instead of O(keys).
	usz[] track = self.compiled_indices(joint, rotation);
	usz count = self.tracks_compiled ? track.len : self.channel_count(joint, rotation);
	if (count == 0) return false;
	if (count == 1)
	{
		usz only = self.key_of(track, joint, rotation, 0);
		out.p0 = only; out.p1 = only; out.p2 = only; out.p3 = only;
		AnimKeyDot dot;
		self.keyframes[only].channel_dot(joint, rotation, &dot);
		out.interpolation = dot.interpolation(rotation, self.blend);
		return true;
	}

	bool cyclic = self.loop && self.duration > 0.0f;
	usz cycle = count;
	bool distinct_terminal = false;
	if (cyclic && count >= 2)
	{
		usz first = self.key_of(track, joint, rotation, 0);
		usz last = self.key_of(track, joint, rotation, count - 1);
		if (math::abs(self.keyframes[first].time) <= ANIM_CLOSE_EPSILON
			&& self.keyframes[last].time >= self.duration - ANIM_CLOSE_EPSILON)
		{
			AnimKeyDot a, b;
			self.keyframes[first].channel_dot(joint, rotation, &a);
			self.keyframes[last].channel_dot(joint, rotation, &b);
			bool same = rotation
				? 1.0f - math::abs(self.keyframes[first].rotation_of(joint).v.dot(
					self.keyframes[last].rotation_of(joint).v)) <= ANIM_SAME_POSE_EPSILON
				: (a.move - b.move).length() <= ANIM_SAME_POSE_EPSILON;
			if (same) { cycle--; }
			else { distinct_terminal = true; }
		}
	}
	// Export samples the inclusive endpoint. A distinct key explicitly authored
	// at duration must be observable there even though clocks after it wrap.
	if (distinct_terminal && math::abs(time - self.duration) <= ANIM_CLOSE_EPSILON)
	{
		usz last = self.key_of(track, joint, rotation, count - 1);
		out.p0 = last; out.p1 = last; out.p2 = last; out.p3 = last;
		AnimKeyDot dot;
		self.keyframes[last].channel_dot(joint, rotation, &dot);
		out.interpolation = dot.interpolation(rotation, self.blend);
		return true;
	}
	if (cycle == 1)
	{
		usz only = self.key_of(track, joint, rotation, 0);
		out.p0 = only; out.p1 = only; out.p2 = only; out.p3 = only;
		AnimKeyDot dot;
		self.keyframes[only].channel_dot(joint, rotation, &dot);
		out.interpolation = dot.interpolation(rotation, self.blend);
		return true;
	}

	float first_time = self.keyframes[self.key_of(track, joint, rotation, 0)].time;
	float clock = time;
	if (cyclic) { clock -= self.duration * math::floor((clock - first_time) / self.duration); }
	else
	{
		float last_time = self.keyframes[self.key_of(track, joint, rotation, cycle - 1)].time;
		clock = math::clamp(clock, first_time, last_time);
	}
	sz segments = cyclic ? (sz)cycle : (sz)cycle - 1;
	sz seg = segments - 1;
	for (sz i = 0; i < segments; i++)
	{
		float upper;
		self.key_at(track, joint, rotation, i + 1, cycle, cyclic, &upper);
		if (clock < upper) { seg = i; break; }
	}
	float t0, t1, t2, t3;
	out.p1 = self.key_at(track, joint, rotation, seg, cycle, cyclic, &t1);
	out.p2 = self.key_at(track, joint, rotation, seg + 1, cycle, cyclic, &t2);
	out.p0 = self.key_at(track, joint, rotation, seg - 1, cycle, cyclic, &t0);
	out.p3 = self.key_at(track, joint, rotation, seg + 2, cycle, cyclic, &t3);
	AnimKeyDot outgoing;
	self.keyframes[out.p1].channel_dot(joint, rotation, &outgoing);
	out.interpolation = outgoing.interpolation(rotation, self.blend);
	out.ease = outgoing.ease(rotation);
	out.span = t2 - t1;
	out.left = t2 - t0;
	out.right = t3 - t1;
	out.blend = out.span > 0.0f ? math::clamp((clock - t1) / out.span, 0.0f, 1.0f) : 0.0f;
	return true;
}

// `eased` false reads the segment as if it had no ease — what a curve editor
// measures a handle's natural tangent against.
fn Quaternionf AnimTemplate.rotation_at(self, String joint, float time, AnimSpan* span = null, bool eased = true)
{
	AnimSpan at;
	if (!self.channel_span(joint, true, time, &at)) return quaternion::IDENTITY;
	if (!eased) at.ease = {};
	if (span) *span = at;
	return at.turn(self.keyframes[at.p0].rotation_of(joint), self.keyframes[at.p1].rotation_of(joint),
		self.keyframes[at.p2].rotation_of(joint), self.keyframes[at.p3].rotation_of(joint));
}

fn Vec3 AnimTemplate.translation_at(self, String joint, float time, AnimSpan* span = null, bool eased = true)
{
	AnimSpan at;
	if (!self.channel_span(joint, false, time, &at)) return {};
	if (!eased) at.ease = {};
	if (span) *span = at;
	return at.slide(self.keyframes[at.p0].offset_of(joint), self.keyframes[at.p1].offset_of(joint),
		self.keyframes[at.p2].offset_of(joint), self.keyframes[at.p3].offset_of(joint));
}

<*
 The pose this template puts a rig in at `time`.

 Everything a template means happens here: the span of keyframes the clock falls
 in, the turn and the slide across it — SLERP and a straight line, or a cubic
 through the neighbouring keys when the clip asks for one — offsets scaled by
 the rig's own height, and each joint's motion carried onto the rig's own bones.

 Walked per joint, with rotation and translation each sampling their own ordered
 track. Whole-pose frames remain compatible because their entries default to
 keying both channels.

 **Carrying happens on the world turn, not on the entry.** A template holds
 parent-relative rotations, and the correction `bone_carry` gives a joint is
 stated in world axes; conjugating a parent-relative rotation by its own joint's
 correction leaves the parent's correction standing between them, so every link
 in a chain acquires a spurious turn of `carry(parent)^-1 * carry(joint)` and
 they compound downward. Two T-pose rigs that need almost no correction at all
 come out worst, because there the spurious turn is the entire difference. So
 the source's world turn is rebuilt link by link from the authored entries,
 carried whole, and only then taken back apart:

 	`W(j) = W(parent) * authored(j)`
 	`C(j) = carry(j) * W(j) * carry(j)^-1`
 	`rotation(j) = C(parent)^-1 * C(j)`

 which is the identity when the two rigs agree at every joint, and unchanged for
 a template that records no bone to be carried from.

 A joint whose name is empty, or which no keyframe mentions, holds its rest
 rotation and passes both chains through untouched — its children still hang off
 whatever its ancestors did.

 The caller owns the returned pose.

 @param names : `One name per joint, in joint order. An empty name is a joint no template can address, and it stays at rest.`
 @param time : `Seconds from the start; non-looping tracks hold their edges and looping tracks wrap in either blend mode.`
 @param grounded : `Whether to run the clip's ground solve. False writes the pose exactly as authored, which is what a writer keeping the authored keys wants — see anim/ground.c3.`
 @param honor_solo : `Whether a solo layer silences the others. An export passes false: it goes by mute alone.`
*>
fn rig::Pose AnimTemplate.pose(
	self,
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	float time,
	bool grounded = true,
	bool honor_solo = true)
{
	rig::Pose pose = rig::rest_pose(allocator, skeleton.len());
	if (self.keyframes.len == 0) return pose;

	// The layers, sampled once for every joint. They compose onto each joint's
	// turn and slide below, before either is carried onto this rig's bones, so
	// what is carried is the layered motion.
	LayerStack stack = self.layer_stack(allocator, skeleton, names, time, honor_solo);
	defer stack.free(allocator);

	// What a template's offsets are measured against. See `AnimKeyDot.move`: an
	// offset is a fraction of the figure's height, so the same walk bobs by the
	// same proportion whether the mesh was exported in metres or centimetres.
	float height = skeleton.height();

	// Where this rig's bones point, which is what an imported template's motion
	// has to be carried onto. See `AnimKeyDot.bone`.
	Vec3[] bones = skeleton.bone_directions(allocator);
	defer alloc::free(allocator, bones);

	// The two chains the carry needs: the world turn the clip describes, and the
	// same turn on this rig's bones. Both are held per joint because the carry is
	// a world-frame operation while a Pose holds parent-relative rotations, and
	// one pass suffices for both because joints precede their children.
	usz count = pose.rotations.len;
	Quaternionf[] authored = alloc::new_array(allocator, Quaternionf, (sz)count);
	Quaternionf[] carried = alloc::new_array(allocator, Quaternionf, (sz)count);
	defer
	{
		alloc::free(allocator, authored);
		alloc::free(allocator, carried);
	}

	for (usz joint = 0; joint < count; joint++)
	{
		// Read rather than searched for, on the same parents-before-children
		// invariant `joint_palette` walks in one pass.
		int parent = skeleton.parents[joint];
		Quaternionf from_parent = parent >= 0 ? authored[(usz)parent] : quaternion::IDENTITY;
		Quaternionf onto_parent = parent >= 0 ? carried[(usz)parent] : quaternion::IDENTITY;

		// A joint neither frame mentions is at rest relative to its parent on the
		// source rig, and rest is rest on any rig — so it inherits both chains
		// rather than being carried, which would give it motion the clip never
		// asked for. Only a joint the clip drives has anything to carry.
		String name = joint < names.len ? names[joint] : "";

		// The span's own ends decide whether the joint is driven at all; the two
		// outside them only shape the curve between, and answer identity for a
		// keyframe that omits the joint, which is rest. A name no track carries
		// comes back with no span, so the joint inherits both chains rather than
		// being carried, which would give it motion the clip never asked for. The
		// span found here is used directly below — `rotation_at`/`translation_at`
		// would resolve it a second time.
		AnimSpan rotation_span;
		AnimSpan translation_span;
		bool base_rotates = name.len > 0 && self.channel_span(name, true, time, &rotation_span);
		bool base_translates = name.len > 0 && self.channel_span(name, false, time, &translation_span);
		Quaternionf turn = base_rotates
			? rotation_span.turn(
				self.keyframes[rotation_span.p0].rotation_of(name),
				self.keyframes[rotation_span.p1].rotation_of(name),
				self.keyframes[rotation_span.p2].rotation_of(name),
				self.keyframes[rotation_span.p3].rotation_of(name))
			: quaternion::IDENTITY;
		Vec3 slide = base_translates
			? translation_span.slide(
				self.keyframes[translation_span.p0].offset_of(name),
				self.keyframes[translation_span.p1].offset_of(name),
				self.keyframes[translation_span.p2].offset_of(name),
				self.keyframes[translation_span.p3].offset_of(name))
			: (Vec3){};

		// A joint only a layer drives is driven all the same: the layers may speak
		// to channels the base never keys.
		bool rotates = base_rotates;
		bool translates = base_translates;
		stack.apply(joint, &turn, &slide, &rotates, &translates);
		if (!rotates && !translates)
		{
			authored[joint] = from_parent;
			carried[joint] = onto_parent;
			continue;
		}

		authored[joint] = from_parent.mul(turn).normalize();

		// Whichever frame recorded it: an entry's bone is a property of the rig the
		// clip was authored on, so it is the same in every frame that names the
		// joint, and a frame that omits the joint has nothing to say about it. A
		// joint only layers drive has no bone to carry from and is left as written.
		if (rotates)
		{
			Vec3 source = {};
			if (base_rotates)
			{
				AnimKeyDot source_dot;
				self.keyframes[rotation_span.p1].channel_dot(name, true, &source_dot);
				source = source_dot.bone;
				if (source.length_sq() < 1.0e-12f)
				{
					self.keyframes[rotation_span.p2].channel_dot(name, true, &source_dot);
					source = source_dot.bone;
				}
			}
			Vec3 target = joint < bones.len ? bones[joint] : (Vec3){ 0, 0, 0 };
			Quaternionf onto = bone_carry(source, target);
			// An arm raised or lowered at rest is the source's pose, not a fact
			// about the target: the target's bone is turned to point where the
			// source's does, and the clip's motion carried from there.
			carried[joint] = rest_pose_differs(source, target)
				? authored[joint].mul(onto.invert()).normalize()
				: onto.mul(authored[joint]).mul(onto.invert()).normalize();
			pose.rotations[joint] = onto_parent.invert().mul(carried[joint]).normalize();
		}
		else
		{
			carried[joint] = onto_parent;
		}

		pose.offsets[joint] = slide * height;
	}

	if (grounded) ground_pose(allocator, skeleton, names, self.ground, &pose, self.phase_at(time));
	return pose;
}

<*
 What this clip says about one joint at `time`, as the entry a keyframe stores.

 The skeleton-free counterpart to `pose`. A template's entries are
 parent-relative and stated in world axes, so reading one back needs the clip and
 nothing else — no rig, no palette, no carry. That is what lets a clip be
 rewritten before it is ever matched to a figure.

 Answers rest for a joint the clip never drives, which is what rest means here:
 the joint is where it was modelled.
*>
fn AnimKeyDot AnimTemplate.entry_at(self, String joint, float time)
{
	AnimKeyDot out = { .axis = { 0, 1, 0 } };
	if (self.keyframes.len == 0) return out;

	AnimSpan rotation_span;
	AnimSpan translation_span;
	bool rotates = self.channel_span(joint, true, time, &rotation_span);
	bool translates = self.channel_span(joint, false, time, &translation_span);
	Quaternionf turn = rotates ? self.rotation_at(joint, time) : quaternion::IDENTITY;
	axis_angle_of(turn, &out.axis, &out.angle);
	out.move = translates ? self.translation_at(joint, time) : (Vec3){};
	if (rotates) out.rotation_interpolation = rotation_span.interpolation;
	if (translates) out.translation_interpolation = translation_span.interpolation;
	AnimSpan source_span = rotates ? rotation_span : translation_span;
	if (rotates || translates)
	{
		AnimKeyDot source_dot;
		self.keyframes[source_span.p1].channel_dot(joint, rotates, &source_dot);
		out.bone = source_dot.bone;
		if (out.bone.length_sq() < 1.0e-12f)
		{
			self.keyframes[source_span.p2].channel_dot(joint, rotates, &source_dot);
			out.bone = source_dot.bone;
		}
	}
	out.channels = rotates ? (translates ? BOTH : ROTATION) : (translates ? TRANSLATION : BOTH);
	return out;
}

<*
 Where in the cycle `time` falls, as a fraction from 0 to 1.

 What a ground spec's contact windows are stated in, so a clip keeps its footing
 when its duration is retimed. A clip with no duration has no cycle and answers
 zero.
*>
fn float AnimTemplate.phase_at(self, float time)
{
	if (self.duration <= 0.0f) return 0.0f;
	float turns = time / self.duration;
	return turns - math::floor(turns);
}

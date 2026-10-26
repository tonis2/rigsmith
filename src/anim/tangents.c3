<*
 Explicit tangents on a channel key: reading what plays now, switching a key's
 mode without moving the curve, and the two spellings of a turn's rate.

 `AnimTangents` (anim/animation.c3) says what is stored and which frame the
 rotation rates are in; the sampler reads them. This file is what a curve
 editor needs around that: the tangent a key has *today*, whatever its mode, so
 a handle can be drawn where the curve already goes; a mode switch that seeds
 the stored rates from it, so turning an Auto key Free changes nothing until a
 handle is dragged; and a conversion between an angular velocity and the rate
 of each displayed Euler angle, so one axis's handle can be dragged on its own.

 **Ease and tangents.** A segment with explicit tangents at either end ignores
 its ease — the tangent is the pacing. The tangent an Auto key reports folds its
 ease in (`1 - start` leaving, `1 - end` arriving, the slope the ease gives the
 curve at the key), so seeding from it keeps the key's ends where they were.
 The eased curve is a cubic of a cubic, which a single Hermite only
 approximates between the ends: exact for a key with no ease, close for one with.
*>
module crig;

import std::math;
import std::math::quaternion;
import std::math::vector;
import std::collections::object;

// A rotation vector (axis times angle, radians) for the shortest turn from
// `from` to `to`, both unit.
fn Vec3 turn_between(Quaternionf from, Quaternionf to) @local
{
	Quaternionf carry = to * from.conjugate();
	if (carry.v.w < 0.0f) carry = -carry;
	Vec3 vector = carry.v.xyz;
	float sine = vector.length();
	if (sine < 1.0e-6f) return vector * 2.0f;
	return vector / sine * (2.0f * math::atan2(sine, carry.v.w));
}

// The angular rate a quaternion slope per second stands for at `at`:
// `q' = ½ ω q`, so `ω = 2 q' q⁻¹`, and the part along `q` — which only stretches
// it — drops out.
fn Vec3 angular_rate_of_slope(Vec4 slope, Quaternionf at) @local
{
	Quaternionf derivative = { .v = slope };
	return (derivative * at.conjugate()).v.xyz * 2.0f;
}

// Quaternion `q` in the hemisphere of `reference`, the same rotation either way.
fn Quaternionf hemisphere_of(Quaternionf q, Quaternionf reference) @local
{
	return q.v.dot(reference.v) < 0.0f ? -q : q;
}

<*
 A channel key's tangent as it plays now: the rate the curve leaves the key with,
 or arrives at it with when `incoming`.

 Rotation rates are angular velocity in radians per second, in the frame of the
 key's `axis`; translation rates are the rate of `move` per second. See
 `AnimTangents`. A key in `FLAT`, `LINEAR`, `FREE` or `BROKEN` answers its own.
 An `AUTO` key answers what the sampler works out: the Catmull-Rom rate through
 its neighbours, folded with the ease of the segment it belongs to, or the
 straight rate of the segment when that is linear, or nothing when it holds.

 @param key : `The keyframe index.`
 @return `Zero for a key that does not key the channel.`
*>
fn Vec3 effective_tangent(AnimTemplate clip, usz key, String joint, bool rotation, bool incoming)
{
	if (key >= clip.keyframes.len) return {};
	AnimKeyDot dot;
	if (!clip.keyframes[key].channel_dot(joint, rotation, &dot)) return {};

	AnimTangents own = dot.tangents(rotation);
	switch (own.mode)
	{
		case FLAT: return {};
		case FREE:
		case BROKEN: return incoming ? own.incoming : own.outgoing;
		default: break; // LINEAR and AUTO need the neighbours
	}

	AnimSpan span;
	if (!clip.channel_span(joint, rotation, clip.keyframes[key].time, &span)) return {};
	// The key is the start of the segment the span found, or the end of the last
	// segment of a clip that does not loop; anything else is a key aliased onto
	// another by the loop closing, which has no tangent of its own.
	bool starts = span.p1 == key;
	if (!starts && span.p2 != key) return {};

	// The two segments at the key, each by the key that owns it, the key at its
	// other end and its length in seconds. A key at an end of the channel has one
	// side only, and that side answers for both.
	TangentSide leaving = starts ? (TangentSide){ key, span.p2, span.span } : (TangentSide){};
	TangentSide arriving = starts ? (TangentSide){ span.p0, span.p0, span.left - span.span }
		: (TangentSide){ span.p1, span.p1, span.span };
	float whole = leaving.gap + arriving.gap;
	usz before = starts ? span.p0 : span.p1;
	usz after = starts ? span.p2 : span.p3;
	if (leaving.gap <= 0.0f) leaving = arriving;
	if (arriving.gap <= 0.0f) arriving = leaving;
	TangentSide side = incoming ? arriving : leaving;
	if (side.gap <= 0.0f) return {};

	AnimKeyDot owner;
	clip.keyframes[side.owner].channel_dot(joint, rotation, &owner);
	AnimInterpolation segment = owner.interpolation(rotation, clip.blend);
	// Linear heads for the neighbour whatever the segment is; an Auto key on a
	// held segment has no rate, and on a linear one the segment's own.
	bool straight = own.mode == LINEAR;
	if (!straight && segment == HOLD) return {};

	// The key is the start of the segment when it owns it, its end otherwise.
	bool at_start = side.owner == key;
	if (straight || segment != AUTO)
	{
		return at_start
			? chord_rate(clip, joint, rotation, key, side.far, side.gap)
			: chord_rate(clip, joint, rotation, side.far, key, side.gap);
	}

	// The Catmull-Rom rate across both neighbours.
	Vec3 rate = central_rate(clip, joint, rotation, key, before, after, whole);

	// Folded with the ease of the segment, unless the segment's other end has
	// explicit tangents, which switch the ease off.
	AnimKeyDot far;
	clip.keyframes[side.far].channel_dot(joint, rotation, &far);
	AnimEase ease = owner.ease(rotation);
	if (!far.tangents(rotation).explicit() && !ease.none())
	{
		// An ease leaves the curve `1 - start` of its unpaced slope at the
		// segment's start and `1 - end` of it at its end.
		rate = rate * (at_start ? 1.0f - ease.start : 1.0f - ease.end);
	}
	return rate;
}

// One of the two segments at a key.
struct TangentSide @local
{
	usz owner; // the keyframe whose outgoing segment it is
	usz far;   // the keyframe at its other end
	float gap; // seconds; zero where the key has no segment on this side
}

fn Vec3 effective_rotation_tangent(AnimTemplate clip, usz key, String joint, bool incoming)
{
	return effective_tangent(clip, key, joint, true, incoming);
}

fn Vec3 effective_translation_tangent(AnimTemplate clip, usz key, String joint, bool incoming)
{
	return effective_tangent(clip, key, joint, false, incoming);
}

// A rotation channel key's quaternion.
fn Quaternionf key_turn(AnimTemplate clip, usz key, String joint) @local
{
	return clip.keyframes[key].rotation_of(joint);
}

// The straight rate from key `from` to key `to` over `gap` seconds.
fn Vec3 chord_rate(AnimTemplate clip, String joint, bool rotation, usz from, usz to, float gap) @local
{
	if (gap <= 0.0f || from == to) return {};
	if (!rotation) return (clip.keyframes[to].offset_of(joint) - clip.keyframes[from].offset_of(joint)) / gap;
	Quaternionf a = key_turn(clip, from, joint);
	Quaternionf b = hemisphere_of(key_turn(clip, to, joint), a);
	return turn_between(a, b) / gap;
}

// The Catmull-Rom rate at `key` through its neighbours, `whole` seconds apart.
fn Vec3 central_rate(AnimTemplate clip, String joint, bool rotation, usz key, usz before, usz after, float whole) @local
{
	if (!rotation)
	{
		return (clip.keyframes[after].offset_of(joint) - clip.keyframes[before].offset_of(joint)) / whole;
	}
	Quaternionf at = key_turn(clip, key, joint);
	Quaternionf prior = hemisphere_of(key_turn(clip, before, joint), at);
	Quaternionf next = hemisphere_of(key_turn(clip, after, joint), at);
	return angular_rate_of_slope((next.v - prior.v) / whole, at);
}

// The key's entry for a channel, writable, or null.
fn AnimKeyDot* tangent_entry(AnimTemplate* clip, usz key, String joint, bool rotation) @local
{
	if (key >= clip.keyframes.len) return null;
	foreach (&dot : clip.keyframes[key].dots)
	{
		if (dot.joint_name != joint) continue;
		if (rotation ? dot.keys_rotation() : dot.keys_translation()) return dot;
	}
	return null;
}

<*
 These tangents with the far end re-pointed along the kept one's direction, at
 the far end's own length: what keeps a `FREE` key smooth after one handle moves.

 @param keep_incoming : `The incoming rate is the one that was moved and stays; the outgoing one follows it.`
*>
fn AnimTangents AnimTangents.realigned(self, bool keep_incoming)
{
	AnimTangents out = self;
	Vec3 kept = keep_incoming ? self.incoming : self.outgoing;
	Vec3 moved = keep_incoming ? self.outgoing : self.incoming;
	if (kept.length_sq() < 1.0e-18f) return out;
	Vec3 aligned = kept.normalize() * moved.length();
	if (keep_incoming) { out.outgoing = aligned; } else { out.incoming = aligned; }
	return out;
}

// Whether two keys' tangents play the same: the mode, and the stored rates for
// the modes that read them.
fn bool AnimTangents.same(self, AnimTangents other)
{
	if (self.mode != other.mode) return false;
	if (self.mode != FREE && self.mode != BROKEN) return true;
	return (self.incoming - other.incoming).length() < 1.0e-5f && (self.outgoing - other.outgoing).length() < 1.0e-5f;
}

<*
 These tangents for keys whose times were multiplied by `scale`. Rates are per
 second, so a stretched clip (`scale` above one) moves the same pose slower:
 `FREE` and `BROKEN` rates divide by it. The other modes are worked out from the
 keys at sample time and have nothing stored.
*>
fn AnimTangents AnimTangents.retimed(self, float scale)
{
	if (self.mode != FREE && self.mode != BROKEN) return self;
	if (!(scale > 0.0f) || !math::is_finite(scale) || scale == 1.0f) return self;
	return { .mode = self.mode, .incoming = self.incoming / scale, .outgoing = self.outgoing / scale };
}

// The entry's tangents, both channels, for a clip's times multiplied by `scale`.
fn void AnimKeyDot.retime_tangents(&self, float scale)
{
	self.rotation_tangents = self.rotation_tangents.retimed(scale);
	self.translation_tangents = self.translation_tangents.retimed(scale);
}

<*
 Switch a channel key to `mode`, seeding the stored rates from what plays now so
 a key that was drawing a curve keeps drawing it: Auto to Free changes nothing.
 `FLAT` and `LINEAR` replace the curve by definition, and `AUTO` hands the key
 back to the sampler and clears the stored rates.

 `FREE` from a pair of rates pointing apart keeps the outgoing one and turns the
 incoming one onto it.

 A key that tangents are set on has to be on a curve to use them, so with
 `curve` a channel whose segment would be linear is switched to `AUTO`
 interpolation; a held channel stays held and ignores them.

 @param clip : `Edited in place; its tracks are not rebuilt, nothing structural changes.`
 @param key : `The keyframe index.`
 @param from : `Where the rates are read from, when not the clip itself: a caller switching many keys reads every seed off the clip as it was, so the order does not matter.`
 @return `False when the key does not key the channel.`
*>
fn bool set_tangent_mode(AnimTemplate* clip, usz key, String joint, bool rotation, AnimTangent mode, bool curve = true,
	AnimTemplate* from = null)
{
	AnimKeyDot* dot = tangent_entry(clip, key, joint, rotation);
	if (!dot) return false;

	AnimTangents next = { .mode = mode };
	if (mode == FREE || mode == BROKEN)
	{
		AnimTemplate source = from ? *from : *clip;
		next.incoming = effective_tangent(source, key, joint, rotation, true);
		next.outgoing = effective_tangent(source, key, joint, rotation, false);
		if (mode == FREE) next = next.realigned(false);
	}
	if (rotation) { dot.rotation_tangents = next; } else { dot.translation_tangents = next; }
	if (curve && mode != AUTO && dot.interpolation(rotation, clip.blend) == LINEAR)
	{
		if (rotation) { dot.rotation_interpolation = AUTO; } else { dot.translation_interpolation = AUTO; }
	}
	return true;
}

<*
 Set one end of a channel key's tangent, as a dragged handle does. A key that is
 not `FREE` or `BROKEN` becomes `BROKEN` first, seeded from what plays now, so
 the other end stays where it was; a `FREE` key turns the other end to follow.

 @param rate : `Radians per second for a rotation, the rate of move for a translation.`
 @return `False when the key does not key the channel or the rate is not finite.`
*>
fn bool set_tangent_rate(AnimTemplate* clip, usz key, String joint, bool rotation, bool incoming, Vec3 rate)
{
	if (!math::is_finite(rate.x) || !math::is_finite(rate.y) || !math::is_finite(rate.z)) return false;
	AnimKeyDot* dot = tangent_entry(clip, key, joint, rotation);
	if (!dot) return false;
	AnimTangents current = dot.tangents(rotation);
	if (current.mode != FREE && current.mode != BROKEN)
	{
		if (!set_tangent_mode(clip, key, joint, rotation, BROKEN)) return false;
		current = dot.tangents(rotation);
	}
	if (incoming) { current.incoming = rate; } else { current.outgoing = rate; }
	if (current.mode == FREE) current = current.realigned(incoming);
	if (rotation) { dot.rotation_tangents = current; } else { dot.translation_tangents = current; }
	return true;
}

// ---------------------------------------------------------------------------
// Angular rate and Euler rates

<*
 An angular velocity as the rate of each XYZ Euler angle (`R = Rz · Ry · Rx`,
 the Curves sheet's convention) at the turn those angles name.

 Differentiating `R(a, b, c)` gives `ω = ȧ · Rz Ry x̂ + ḃ · Rz ŷ + ċ · ẑ`, which
 is solved for the three rates. The map is singular where Y is a quarter turn
 (gimbal lock), where X and Z turn the same way and only their sum is defined:
 the rate there is read with `cos b` held off zero, so the result is large but
 finite, and round-trips through `angular_rate_of_euler_rate` only up to that.

 @param euler : `The key's displayed Euler angles in degrees, as the graph shows them.`
 @param omega : `Radians per second, in the key's axis frame.`
 @return `Degrees per second about X, Y and Z.`
*>
fn Vec3 euler_rate_of_angular_rate(Vec3 euler, Vec3 omega)
{
	Vec3 r = euler * (float)(math::PI / 180.0);
	float cb = math::cos(r.y);
	float sb = math::sin(r.y);
	float cc = math::cos(r.z);
	float sc = math::sin(r.z);
	if (math::abs(cb) < 1.0e-4f) cb = cb < 0.0f ? -1.0e-4f : 1.0e-4f;
	float x = (omega.x * cc + omega.y * sc) / cb;
	float y = -omega.x * sc + omega.y * cc;
	float z = omega.z + x * sb;
	return (Vec3){ x, y, z } * (float)(180.0 / math::PI);
}

<*
 The inverse of `euler_rate_of_angular_rate`: the angular velocity the rates of
 the three Euler angles add up to.

 @param euler : `The key's displayed Euler angles in degrees.`
 @param degrees_per_second : `The rate of each angle.`
 @return `Radians per second, in the key's axis frame.`
*>
fn Vec3 angular_rate_of_euler_rate(Vec3 euler, Vec3 degrees_per_second)
{
	Vec3 r = euler * (float)(math::PI / 180.0);
	Vec3 rate = degrees_per_second * (float)(math::PI / 180.0);
	float cb = math::cos(r.y);
	float sb = math::sin(r.y);
	float cc = math::cos(r.z);
	float sc = math::sin(r.z);
	return {
		rate.x * cc * cb - rate.y * sc,
		rate.x * sc * cb + rate.y * cc,
		-rate.x * sb + rate.z,
	};
}

// ---------------------------------------------------------------------------
// Persistence: one spelling for the session, the pack and the clip extras

fn String tangent_word(AnimTangent mode) @local
{
	switch (mode)
	{
		case FLAT: return "flat";
		case LINEAR: return "linear";
		case FREE: return "free";
		case BROKEN: return "broken";
		default: return "auto";
	}
}

fn bool parse_tangent_mode(String word, AnimTangent* out) @local
{
	switch (word)
	{
		case "auto": *out = AUTO; return true;
		case "flat": *out = FLAT; return true;
		case "linear": *out = LINEAR; return true;
		case "free": *out = FREE; return true;
		case "broken": *out = BROKEN; return true;
		default: return false;
	}
}

<*
 A key entry's tangents as `,"field":{"mode":"free","in":[x,y,z],"out":[x,y,z]}`,
 or nothing for an Auto key — so a clip with none writes exactly what it wrote
 before. Only `FREE` and `BROKEN` write their rates; the other modes work them
 out from the keys.
*>
fn void append_tangent_field(DString* out, String field, AnimTangents tangents)
{
	if (!tangents.explicit()) return;
	out.appendf(`,"%s":{"mode":"%s"`, field, tangent_word(tangents.mode))!!;
	if (tangents.mode == FREE || tangents.mode == BROKEN)
	{
		out.appendf(`,"in":%s,"out":%s`, (JsonVec3)tangents.incoming, (JsonVec3)tangents.outgoing)!!;
	}
	out.append_char('}');
}

// Read a vec3 field of a tangent object; false when it is malformed.
fn bool read_tangent_vec3(Object* tangent, String field, Vec3* out) @local
{
	*out = {};
	Object*? found = tangent.get(field);
	if (catch found) return true;
	Object* value = found;
	if (!value.is_array() || value.get_len() != 3) return false;
	Vec3 read;
	for (sz i = 0; i < 3; i++)
	{
		double? component = value.get_float_at(i);
		if (catch component) return false;
		read[i] = (float)component;
		if (!math::is_finite(read[i])) return false;
	}
	*out = read;
	return true;
}

<*
 Read an entry's tangents; absent is Auto. False for a malformed value.
*>
fn bool read_tangent_field(Object* dot, String field, AnimTangents* out)
{
	*out = {};
	Object*? found = dot.get(field);
	if (catch found) return true;
	Object* value = found;
	if (!value.is_map()) return false;
	String? word = value.get_string("mode");
	if (catch word) return false;
	AnimTangents read;
	if (!parse_tangent_mode(word, &read.mode)) return false;
	if (!read_tangent_vec3(value, "in", &read.incoming)) return false;
	if (!read_tangent_vec3(value, "out", &read.outgoing)) return false;
	if (read.mode != FREE && read.mode != BROKEN) read = { .mode = read.mode };
	*out = read;
	return true;
}

<*
 A one-off's channels carried from the joint frames they were made in into the
 frames of the rig the game plays them on, when the two rigs agree.
*>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;

// How far, in radians, two rest rotations may differ and still count as one.
const float CUT_RIG_TURN_TOLERANCE = 0.01f;
// How far a joint's rest scale may be from 1.
const float CUT_RIG_SCALE_TOLERANCE = 1e-3f;

<* One joint at rest in a rig's file: its name, its parent's ("" for none among the joints), and its local transform. *>
struct JointRest
{
	String name;   // borrowed
	String parent; // borrowed
	Vec3 translation;
	Quaternionf rotation;
	Vec3 scale;
}

enum RigMismatchKind : char
{
	NONE,
	MISSING_JOINT, // a joint the other rig lacks
	OTHER_PARENT,  // a joint hung from another parent
	OTHER_TURN,    // a joint resting at another rotation
	OTHER_SCALE,   // a joint resting scaled
}

<* Why two rigs differ, and at which joint (borrowed); NONE when they agree. *>
struct RigMismatch
{
	RigMismatchKind kind;
	String joint;
}

fn bool RigMismatch.agrees(&self) => self.kind == NONE;

<* A copy of `rig` that owns its names. *>
fn JointRest[] copy_joint_rests(Allocator allocator, JointRest[] rig)
{
	if (rig.len == 0) return {};
	JointRest[] out = alloc::clone_slice(allocator, rig);
	foreach (&j : out)
	{
		j.name = j.name.copy(allocator);
		j.parent = j.parent.copy(allocator);
	}
	return out;
}

<* Free a rig `copy_joint_rests` made. *>
fn void free_joint_rests(Allocator allocator, JointRest[] rig)
{
	foreach (&j : rig)
	{
		j.name.free(allocator);
		j.parent.free(allocator);
	}
	if (rig.len > 0) alloc::free(allocator, rig);
}

<* The joint called `name` in `rig`, or -1. *>
fn sz joint_rest_index(JointRest[] rig, String name)
{
	foreach (usz i, &j : rig) if (j.name == name) return (sz)i;
	return -1;
}

// The angle between two rotations, either sign of the quaternion.
fn float rest_turn_between(Quaternionf a, Quaternionf b) @local
{
	float d = math::min(math::abs(a.v.dot(b.v)), 1.0f);
	return 2.0f * math::acos(d);
}

fn bool unscaled(Vec3 s) @local
{
	return math::abs(s.x - 1.0f) <= CUT_RIG_SCALE_TOLERANCE && math::abs(s.y - 1.0f) <= CUT_RIG_SCALE_TOLERANCE
		&& math::abs(s.z - 1.0f) <= CUT_RIG_SCALE_TOLERANCE;
}

<*
 Whether `to` plays what was made on `from`: each of `from`'s joints is in `to` by name, under a
 parent of the same name, at the same rest rotation, and neither rests scaled. Translations may differ.

 @param any_turn : "Rest rotations may differ: the two are one rig in other joint frames"
 @return "The first difference, or NONE"
*>
fn RigMismatch rigs_agree(JointRest[] from, JointRest[] to, bool any_turn = false)
{
	foreach (&j : from)
	{
		// An unnamed joint cannot be bound by name, so a one-off never moves it.
		if (j.name.len == 0) continue;
		sz at = joint_rest_index(to, j.name);
		if (at < 0) return { MISSING_JOINT, j.name };
		JointRest* other = &to[at];
		if (other.parent != j.parent) return { OTHER_PARENT, j.name };
		if (!any_turn && rest_turn_between(j.rotation, other.rotation) > CUT_RIG_TURN_TOLERANCE) return { OTHER_TURN, j.name };
		if (!unscaled(j.scale) || !unscaled(other.scale)) return { OTHER_SCALE, j.name };
	}
	return {};
}

// A joint's rest rotation in its rig's own space: its own, under its parents'.
fn Quaternionf rest_world_turn(JointRest[] rig, sz at) @local
{
	Quaternionf turn = quaternion::IDENTITY;
	// A rig is a tree; the bound only stops a malformed loop.
	for (usz depth = 0; at >= 0 && depth <= rig.len; depth++)
	{
		turn = rig[at].rotation.mul(turn);
		at = rig[at].parent.len > 0 ? joint_rest_index(rig, rig[at].parent) : -1;
	}
	return turn.normalize();
}

// The rest rotation of a joint's parent in its rig's space; none for a root.
fn Quaternionf rest_parent_turn(JointRest[] rig, sz at) @local
{
	String parent = rig[at].parent;
	sz up = parent.len > 0 ? joint_rest_index(rig, parent) : -1;
	return up < 0 ? (Quaternionf)quaternion::IDENTITY : rest_world_turn(rig, up);
}

<*
 Carry baked channels from `from`'s joint frames into `to`'s, rigs that agree (rigs_agree). A joint
 turns the same way in both: a rotation is re-framed by the two rigs' rest rotations, the same
 rotation when they rest alike. A translation keeps its offset from its joint's rest, turned into
 the parent's frame, so a root resting at the hips in one and over the feet in the other moves the
 same way. A channel on a joint either rig lacks is left as it is.

 @param [inout] channels
*>
fn void carry_channels(CutChannel[] channels, JointRest[] from, JointRest[] to)
{
	foreach (&c : channels)
	{
		sz a = joint_rest_index(from, c.bone);
		sz b = joint_rest_index(to, c.bone);
		if (a < 0 || b < 0) continue;
		// From the parent's frame in `from` to its frame in `to`, and the joint's own frame the same way.
		Quaternionf parent_turn = rest_parent_turn(to, b).invert().mul(rest_parent_turn(from, a)).normalize();
		Quaternionf own_turn = rest_world_turn(from, a).invert().mul(rest_world_turn(to, b)).normalize();
		if (c.path == ROTATION)
		{
			for (usz k = 0; k + 3 < c.values.len; k += 4)
			{
				Quaternionf q = { .v = { c.values[k], c.values[k + 1], c.values[k + 2], c.values[k + 3] } };
				Quaternionf out = parent_turn.mul(q).mul(own_turn).normalize();
				c.values[k:4] = (float[4]){ out.v.x, out.v.y, out.v.z, out.v.w }[..];
			}
			continue;
		}
		if (c.path != TRANSLATION) continue;
		for (usz k = 0; k + 2 < c.values.len; k += 3)
		{
			Vec3 offset = (Vec3){ c.values[k], c.values[k + 1], c.values[k + 2] } - from[a].translation;
			Vec3 out = to[b].translation + parent_turn.rotate_vec3(offset);
			c.values[k:3] = (float[3]){ out.x, out.y, out.z }[..];
		}
	}
}

<* What a rig mismatch means, in words. The caller owns it. *>
fn String rig_mismatch_text(Allocator allocator, RigMismatch m)
{
	switch (m.kind)
	{
		case NONE: return "".copy(allocator);
		case MISSING_JOINT: return string::format(allocator, "the level's rig has no joint '%s'", m.joint);
		case OTHER_PARENT: return string::format(allocator, "'%s' hangs from another joint in the level's rig", m.joint);
		case OTHER_TURN: return string::format(allocator, "'%s' rests turned another way in the level's rig", m.joint);
		case OTHER_SCALE: return string::format(allocator, "'%s' rests scaled in the level's rig", m.joint);
	}
}

<* The pure half of src/app/locks.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 One anchor: the dot, the world point and orientation to hold, and which of the
 two are live. A stored entry always holds at least one half — the moment both go
 off, `set_anchor` drops it.
*>
struct PositionLock
{
	uint dot_id;
	Vec3 target;         // world position held while `position`
	Quaternionf orient;  // world orientation held while `rotation`
	bool position;
	bool rotation;

	// Derived, not part of the goal: what the last gesture left this anchor
	// holding (`measure_position_locks`), meaningless until one has run.
	// `residual` is the model-space distance the position half ended from its held
	// point; `turn_residual` the angle (radians) the rotation half ended from its
	// held orientation.
	float residual;
	float turn_residual;
}

<*
 How many joints one gesture's anchored limbs may snapshot between them.

 Generous: a position-anchored foot's limb is the knee and the thigh, a
 rotation-anchored one adds the foot itself, so four fully-anchored feet still
 fit. A gesture that would exceed it stops snapshotting rather than overrun — the
 bound `snapshot_chain` keeps against `POSE_SNAPSHOT`, for the same reason.
*>
const usz LOCK_SNAPSHOT = 32;

// One longer, with `add` on the end. The old storage is released.
fn PositionLock[] grow_locks(PositionLock[] locks, PositionLock add)
{
	PositionLock[] grown = alloc::new_array(mem, PositionLock, locks.len + 1);
	foreach (usz i, lock : locks) grown[i] = lock;
	grown[locks.len] = add;
	if (locks.len > 0) alloc::free(mem, locks);
	return grown;
}

<*
 The feet, by the canonical names every body plan and `pin_feet` use.
 @return `How many of the two there are.`
*>
fn usz foot_ids(RigDocument* doc, uint[2]* out)
{
	usz found = 0;
	foreach (dot : doc.dots.array_view())
	{
		if (found < 2 && (dot.name == "ankle_L" || dot.name == "ankle_R")) (*out)[found++] = dot.id;
	}
	return found;
}

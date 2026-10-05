<*
 Position and rotation anchors: joints held in place by IK while another moves.

 An anchor names a dot and, independently, whether to hold its world **position**,
 its world **orientation**, or both — each captured from where the joint stands
 the moment that half is switched on. It is a goal, not a constraint on the rig:
 nothing stops the joint being carried away by a gesture, but every gesture ends
 by bending the joint's own limb back toward the held point and turning the joint
 back to the held orientation. So a foot pinned position-and-rotation stays flat
 on the floor while the hips drop and the knee folds, which is a sit — and it is
 `solve_limited_pose_chain` and `hold_world_rotation` doing the work, one leg at a
 time. See `resolve_position_locks` in `pose_mode.c3`.

 **The two halves are separate on purpose.** Position alone pins the ankle but
 lets the foot pivot; rotation alone holds the foot's tilt but lets it slide;
 together they plant it. The Joint card shows them as two padlock toggles — see
 `lock_toggles.c3`.

 **Session-only, deliberately.** An anchor is a world point and orientation in one
 pose of one model, so it is editor working memory like `pose_edit_draft` —
 cleared when a document loads and never written to the `.glb`.
*>
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

	// Derived, not part of the goal: what the last `resolve_position_locks` left
	// this anchor holding, refreshed every gesture and meaningless until one has
	// run. `residual` is the model-space distance the position half ended from its
	// held point; `turn_residual` the angle (radians) the rotation half ended from
	// its held orientation. `yielded` is set when the anchor's limb shared a joint
	// with a higher-priority anchor and it was stood down so that one could hold —
	// the deterministic-conflict flag, read back through `lock_yielded`.
	float residual;
	float turn_residual;
	bool yielded;
	// Set when the current gesture began with this pin already out of its limb's
	// reach: it reports its miss but does not steer the whole-body solve.
	bool loose;
}

<*
 How many joints one gesture's anchored limbs may snapshot between them.

 Generous: a position-anchored foot's limb is the knee and the thigh, a
 rotation-anchored one adds the foot itself, so four fully-anchored feet still
 fit. A gesture that would exceed it stops snapshotting rather than overrun — the
 bound `snapshot_chain` keeps against `POSE_SNAPSHOT`, for the same reason.
*>
const usz LOCK_SNAPSHOT = 32;

// Where this dot's anchor lives in the list, or -1. The one scan the rest share.
fn sz AppState.lock_index(&self, uint dot_id)
{
	foreach (usz i, lock : self.position_locks) if (lock.dot_id == dot_id) return (sz)i;
	return -1;
}

// Whether this dot is anchored at all — either half.
fn bool AppState.is_anchored(&self, uint dot_id) => dot_id != 0 && self.lock_index(dot_id) >= 0;

// Whether this dot's world position is being held.
fn bool AppState.locks_position(&self, uint dot_id)
{
	sz i = self.lock_index(dot_id);
	return i >= 0 && self.position_locks[(usz)i].position;
}

// Whether this dot's world orientation is being held.
fn bool AppState.locks_rotation(&self, uint dot_id)
{
	sz i = self.lock_index(dot_id);
	return i >= 0 && self.position_locks[(usz)i].rotation;
}

// Whether any anchor holds a position — the condition a trunk-carry grab needs,
// since holding a foot's tilt alone does nothing to keep the body from sliding.
fn bool AppState.any_position_anchor(&self)
{
	foreach (lock : self.position_locks) if (lock.position) return true;
	return false;
}

<*
 How far this dot's position anchor ended from the point it holds, at the last
 gesture that ran the anchors — in model units, 0 for a dot with no position
 anchor. It is a reading of the settled pose, so it tells the honest miss whether
 the target was out of the limb's reach, cut short by a joint limit, or given up
 to a higher-priority anchor (`lock_yielded`). Zero until a gesture has resolved.
*>
fn float AppState.lock_position_residual(&self, uint dot_id)
{
	sz i = self.lock_index(dot_id);
	return i >= 0 ? self.position_locks[(usz)i].residual : 0.0f;
}

<*
 How far this dot's rotation anchor ended from the orientation it holds, at the
 last gesture that ran the anchors — in radians, 0 for a dot with no rotation
 anchor. The angular counterpart of `lock_position_residual`.
*>
fn float AppState.lock_rotation_residual(&self, uint dot_id)
{
	sz i = self.lock_index(dot_id);
	return i >= 0 ? self.position_locks[(usz)i].turn_residual : 0.0f;
}

<*
 Whether this dot's anchor stood down at the last resolve because its limb shared
 a joint with a higher-priority anchor — the deterministic-conflict flag. A stood-
 down anchor is not solved for that gesture, so its residual reports how far the
 higher-priority hold left it. See `resolve_position_locks`.
*>
fn bool AppState.lock_yielded(&self, uint dot_id)
{
	sz i = self.lock_index(dot_id);
	return i >= 0 && self.position_locks[(usz)i].yielded;
}

// One longer, with `add` on the end. The old storage is released.
fn PositionLock[] grow_locks(PositionLock[] locks, PositionLock add) @local
{
	PositionLock[] grown = alloc::new_array(mem, PositionLock, locks.len + 1);
	foreach (usz i, lock : locks) grown[i] = lock;
	grown[locks.len] = add;
	if (locks.len > 0) alloc::free(mem, locks);
	return grown;
}

// Drop the entry at `at`, compacting the list.
fn void AppState.drop_lock_at(&self, usz at)
{
	if (self.position_locks.len <= 1)
	{
		if (self.position_locks.len > 0) alloc::free(mem, self.position_locks);
		self.position_locks = {};
		return;
	}
	PositionLock[] rest = alloc::new_array(mem, PositionLock, self.position_locks.len - 1);
	usz w = 0;
	foreach (usz i, lock : self.position_locks)
	{
		if (i == at) continue;
		rest[w++] = lock;
	}
	alloc::free(mem, self.position_locks);
	self.position_locks = rest;
}

<*
 The joint's world orientation right now, out of the current pose — what a
 rotation anchor captures and holds. Identity when there is no rig to read it
 from, which is the same answer a joint with no pose gives.
*>
fn Quaternionf AppState.dot_world_rotation(&self, uint dot_id)
{
	Quaternionf identity = quaternion::IDENTITY;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return identity;
	RigView view = opened;
	defer view.free(mem);
	sz j = view.joint_of(dot_id);
	if (j < 0) return identity;

	rig::Pose pose = self.draft_pose(mem, &view);
	defer pose.free(mem);
	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return identity;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);
	return world[(usz)j];
}

<*
 Set which halves of this dot's anchor are live, capturing what each needs.

 	`app.set_anchor(app.selected, position: true, rotation: false);`

 Each half's held value is captured from where the joint stands now — position
 from `dot_position`, orientation from `dot_world_rotation` — the moment it turns
 on, and left alone while it stays on. With both off the anchor is dropped, so the
 list never holds an entry that anchors nothing.
*>
fn void AppState.set_anchor(&self, uint dot_id, bool position, bool rotation)
{
	Dot* dot = self.doc.find(dot_id);
	if (dot_id == 0 || !dot) return;

	sz found = self.lock_index(dot_id);
	if (!position && !rotation)
	{
		if (found >= 0) self.drop_lock_at((usz)found);
		return;
	}

	// A look-at target owns the joint's orientation, so a rotation pin on it would
	// only fight the aim: refused, the position half still allowed.
	if (rotation && !self.locks_rotation(dot_id) && self.aim_index(dot_id) >= 0)
	{
		self.@notice("a look-at target steers this joint's rotation - remove the target to pin its angle");
		rotation = false;
		if (!position) return;
	}

	PositionLock lock = found >= 0 ? self.position_locks[(usz)found] : (PositionLock){ .dot_id = dot_id };
	if (position && !lock.position) lock.target = self.dot_position(*dot);
	if (rotation && !lock.rotation) lock.orient = self.dot_world_rotation(dot_id);
	lock.position = position;
	lock.rotation = rotation;

	if (found >= 0) { self.position_locks[(usz)found] = lock; }
	else { self.position_locks = grow_locks(self.position_locks, lock); }
}

<*
 Flip this dot's position anchor, leaving its rotation half as it was.
 @return `Whether the position half is on afterwards.`
*>
fn bool AppState.toggle_position_anchor(&self, uint dot_id)
{
	bool now = !self.locks_position(dot_id);
	self.set_anchor(dot_id, now, self.locks_rotation(dot_id));
	return now;
}

<*
 Flip this dot's rotation anchor, leaving its position half as it was.
 @return `Whether the rotation half is on afterwards.`
*>
fn bool AppState.toggle_rotation_anchor(&self, uint dot_id)
{
	bool now = !self.locks_rotation(dot_id);
	self.set_anchor(dot_id, self.locks_position(dot_id), now);
	// An aimed joint refuses the pin, so what it holds is what to report.
	return self.locks_rotation(dot_id);
}

// One half of an anchor set to `on`, the other left exactly as it stands — the
// per-dot step a selection-wide set is built from.
fn void AppState.apply_anchor_half(&self, uint dot_id, bool rotation, bool on)
{
	if (rotation) { self.set_anchor(dot_id, self.locks_position(dot_id), on); }
	else { self.set_anchor(dot_id, on, self.locks_rotation(dot_id)); }
}

<*
 Set one half of the anchor — position (`rotation` false) or rotation (`rotation`
 true) — to `on` across the whole selection: the primary dot and every also-
 selected one, each keeping its other half as it was.

 	`usz n = app.set_selection_anchor_half(rotation: true, on: true);`

 What a padlock press, or L / shift+L, does with more than one joint selected —
 they lock or unlock together rather than only the anchor dot. The new state is the
 caller's to decide (it reads the primary and flips), so a selection that was mixed
 lands one way instead of each dot toggling out of step. Each dot captures its own
 held point and orientation as its half turns on, through `set_anchor`.

 @return `How many dots were acted on — what the notice counts.`
*>
fn usz AppState.set_selection_anchor_half(&self, bool rotation, bool on, usz* skipped = null)
{
	// Pinning a whole selection that sweeps up the hips or a spine joint pins the
	// body in place — a trunk joint nothing below the root can bend back — which is
	// never what locking the feet with the rest selected meant. So a multi-joint
	// press leaves those free and says so; one selected trunk joint is still pinned,
	// since that is asked for by name.
	bool several = self.selection_count() > 1;
	usz acted = 0;
	usz left = 0;
	if (self.selected != 0)
	{
		if (on && several && self.is_trunk_joint(self.selected)) { left++; }
		else { self.apply_anchor_half(self.selected, rotation, on); acted++; }
	}
	for (sz i = 0; i < self.also_selected.len(); i++)
	{
		if (on && several && self.is_trunk_joint(self.also_selected[i])) { left++; continue; }
		self.apply_anchor_half(self.also_selected[i], rotation, on);
		acted++;
	}
	if (skipped) *skipped = left;
	return acted;
}

// Whether nothing below the root can carry this joint back into place — the root,
// or a joint whose parent forks (a spine joint off the hips).
fn bool AppState.is_trunk_joint(&self, uint dot_id)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	sz j = view.joint_of(dot_id);
	if (j < 0) return false;
	return view.skeleton.ancestor_run((usz)j, (usz[IK_MAX_CHAIN]){}[..]) == 0;
}

<*
 The feet, by the canonical names every body plan and `plant_feet` use.
 @return `How many of the two there are.`
*>
fn usz AppState.foot_ids(&self, uint[2]* out)
{
	usz found = 0;
	foreach (dot : self.doc.dots.array_view())
	{
		if (found < 2 && (dot.name == "ankle_L" || dot.name == "ankle_R")) (*out)[found++] = dot.id;
	}
	return found;
}

// Whether both feet are pinned, position and angle — what the Pin feet toggle shows.
fn bool AppState.feet_pinned(&self)
{
	uint[2] feet;
	usz count = self.foot_ids(&feet);
	if (count == 0) return false;
	for (usz i = 0; i < count; i++)
	{
		if (!self.locks_position(feet[i]) || !self.locks_rotation(feet[i])) return false;
	}
	return true;
}

<*
 Pin or unpin both feet, position and angle, each where it stands now — the one
 click that sets up a sit, a crouch or a lean.

 @return `How many feet were found.`
*>
fn usz AppState.pin_feet(&self, bool on)
{
	uint[2] feet;
	usz count = self.foot_ids(&feet);
	for (usz i = 0; i < count; i++) self.set_anchor(feet[i], on, on);
	return count;
}

// Turn the position half on (leaving rotation as it was). @return false for no such dot.
fn bool AppState.lock_position(&self, uint dot_id)
{
	if (!self.doc.find(dot_id)) return false;
	self.set_anchor(dot_id, true, self.locks_rotation(dot_id));
	return true;
}

// Turn the rotation half on (leaving position as it was). @return false for no such dot.
fn bool AppState.lock_rotation(&self, uint dot_id)
{
	if (!self.doc.find(dot_id)) return false;
	self.set_anchor(dot_id, self.locks_position(dot_id), true);
	return true;
}

<*
 Move this dot's held point and orientation to where the dot now stands.

 The gesture that grabs an anchored joint is deliberately moving it, so its own
 anchor is not solved against it during the drag — see `resolve_position_locks`.
 The release calls this so the anchor follows the joint to where it was placed,
 rather than snapping it back on the next unrelated gesture. Only the live halves
 are re-captured.
*>
fn void AppState.refresh_lock_target(&self, uint dot_id)
{
	sz found = self.lock_index(dot_id);
	if (found < 0) return;
	Dot* dot = self.doc.find(dot_id);
	if (!dot) return;
	if (self.position_locks[(usz)found].position) self.position_locks[(usz)found].target = self.dot_position(*dot);
	if (self.position_locks[(usz)found].rotation) self.position_locks[(usz)found].orient = self.dot_world_rotation(dot_id);
}

<*
 Drop every anchor. The document-load reset and the teardown both come here.
*>
fn void AppState.clear_position_locks(&self)
{
	if (self.position_locks.len > 0) alloc::free(mem, self.position_locks);
	self.position_locks = {};
}

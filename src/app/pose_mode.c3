<*
 Animation posing: the rig carried by hand, and the mesh carried with it.

 Rigging asks where the bones go. This asks what happens when they move, and
 answers it with the user's own hands rather than with a canned clip — grab a
 joint and drag, and the joints above it turn until it arrives where the pointer
 is. That is inverse kinematics, and it is the difference between a rig you can
 inspect and a figure you can put in a shape.

 There is no pose mode. Mouse-dragging a dot always edits the rest rig; pressing
 G moves that joint through IK with the mesh, and R turns it. The animation
 selected in the timeline is ready for those posing keys directly in the regular
 viewport, and the first gesture seeds a transient `pose_edit_draft` from its
 playhead. Auto-key commits it on release; otherwise Save pose does.

 **Where the solving happens is not here.** A gesture on the body — a hand, a
 foot, the hips, any joint — is one `body_solve` (`core/body_solve.c3`) over the
 whole figure, with the pins, the planted feet, the floor and the balance as its
 goals, started from the pose the gesture began with on every move; this file says
 what the gesture asks for and writes back what comes out (`pose_body`). A finger or a toe's tip curls along its own short run instead,
 through the limit-aware CCD below, whose step toward a point is
 `collision::ik`'s. Both meet the rig in world space and convert what comes back
 into `rig::Pose`'s local rotations themselves.
*>
module crig;

import rig;
import std::time;
import collision::ik;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::collections::list;

<*
 The longest run of joints one gesture may turn, and the snapshot that holds
 them.

 A bound rather than a guess: `Skeleton.ancestor_run` walks unbranched ancestors,
 and no rig anybody places by hand has sixteen joints in a row with nothing
 hanging off any of them. The snapshot is one longer because the joint being
 grabbed is in it too — it is not turned, but it may be slid, and either way
 escape has to put it back.
*>
const usz IK_MAX_CHAIN = 16;
const usz POSE_SNAPSHOT = IK_MAX_CHAIN + 1;
// How many other selected joints one G carries along; see `gather_pose_mates`.
const usz POSE_MATES = 16;

struct PoseMate
{
	uint dot;
	Vec3 from; // where it stood when the grab began
}

<*
 One joint in the transient animation draft, keyed by the document dot id so a
 freshly built `RigView` can map it back to the clip's joint order.

 This is editor working memory only. Saved poses live exclusively as animation
 keyframes; the rig document stores no current pose.
*>
struct PosedJoint
{
	uint dot_id;
	Quaternionf rotation;
	Vec3 offset;
}

<*
 Whether `pose_palette` is what the mesh should be skinned by right now.

 Two states fill that palette — the player and a transient timeline pose draft.
 The draft replaces the parked player while the user edits it.
*>
fn bool Character.skinned(&self) => self.animating || self.pose_edit_active;

<*
 Whether structural/rest-mesh tools are off limits.

 The body on screen has been deformed by the skinning pass while the picker still
 describes the one it was modelled in, so a click that placed a dot would place it
 correctly in a shape nobody is looking at — which on screen is simply the wrong
 place. Direct dot dragging is the deliberate exception: it first suspends the
 posed display, making the rest dot and rest mesh agree before anything moves.

 Reads the same two flags `skinned` does, and that is a coincidence rather than
 an identity. The two ask different questions — "is the palette live" and "is
 rest editing off" — and a future display that deformed the body while allowing
 rest editing could still separate them.
*>
fn bool AppState.rig_locked(&self) => self.animating || self.pose_edit_active;

<*
 Whether the Animation workspace can pose the clip shown at its playhead.

 Before the first gesture the paused player normally owns the display. A selected
 clip can also survive a stopped preview (after loading, undo, or an external
 stop), and is still editable: the gesture samples it directly. Afterwards the
 transient draft owns the display and `animating` is false. Keeping those states
 behind one answer is what lets G/R and the Joint card's dials work in the
 regular viewport. Only while the header switch is on Pose: on Joints the same
 drag moves the joint on the model, which Pose never does.
*>
fn bool AppState.animation_pose_ready(&self)
{
	if (self.pose_edit_active) return true;
	// The header switch on Joints: a drag moves the joint, it does not pose it.
	if (self.stage != POSE_STAGE) return false;
	if (!self.editing.valid() || !self.clip(self.editing)) return false;
	if (!self.animating) return true;
	return self.anim_paused && self.current_ref.same(self.editing);
}

<*
 Opens the animation selected in the timeline as an editable transient draft.

 Usually the clip is already parked and visible. The stopped-player path is just
 as important: an editor selection outlives preview playback, so G/R and the
 inspector must not become inert merely because the player released its copy.
 There is still no document pose fallback — without a selected animation there
 is nowhere for Save pose or Auto-key to put the result, and the operation says
 so instead of silently moving rest-rig dots.
*>
fn bool AppState.prepare_animation_pose(&self)
{
	self.sync_clip_pins();
	if (self.pose_edit_active) return true;
	if (!self.editing.valid() || !self.clip(self.editing))
	{
		self.@notice("choose or create an animation before posing joints");
		return false;
	}
	if (self.animating)
	{
		if (!self.anim_paused)
		{
			self.@notice("pause playback before posing joints");
			return false;
		}
		if (!self.current_ref.same(self.editing))
		{
			self.@notice("open the shown animation in the timeline before posing it");
			return false;
		}
		self.stop_animation();
	}
	if (!self.pose_from_clip(self.editing, self.edit_time)) return false;
	self.stage = POSE_STAGE;
	return true;
}

<*
 The header's Joints: joint drags move joints on the model again, which is what
 the model shows while nothing is posed.

 The animation stays chosen in the timeline, and Pose puts it back. A changed,
 unkeyed pose would be lost by leaving, so it is keyed when Auto-key is on and
 otherwise the switch waits for Key pose or Revert.

 @return `False when a pending pose kept the switch on Pose.`
*>
fn bool AppState.enter_joint_stage(&self)
{
	if (self.stage == JOINTS_STAGE && !self.animating && !self.pose_edit_active) return true;
	if (self.pose_edit_pending && !(self.auto_key && self.key_pose_edit(CHANGED)))
	{
		self.@notice("Key pose or Revert the changed pose before switching to Joints.");
		return false;
	}
	if (self.drag.dot != 0) (void)self.cancel_drag();
	self.stop_deformed_display();
	self.stop_animation();
	self.stage = JOINTS_STAGE;
	self.@notice("Joints · drag a joint to move it on the model");
	return true;
}

<*
 The header's Pose: puts the animation chosen in the timeline on show at its
 playhead, so a joint drag poses it. With none chosen yet, the character's
 first animation is chosen.

 @return `False when the character has no animation to pose.`
*>
fn bool AppState.enter_pose_stage(&self)
{
	if (self.stage == POSE_STAGE) return true;
	(void)self.default_editing();
	if (!self.editing.valid() || !self.clip(self.editing))
	{
		self.@notice("Pose edits an animation · add or create one in the Animation pane first");
		return false;
	}
	if (self.drag.dot != 0) (void)self.cancel_drag();
	if (!self.park_clip(self.editing, self.edit_time)) return false;
	self.stage = POSE_STAGE;
	self.@notice("Pose · drag a joint to pose it · switch to Joints to move it on the model");
	return true;
}

fn PosedJoint AppState.working_pose(&self, uint id)
{
	foreach (joint : self.pose_edit_draft)
	{
		if (joint.dot_id == id) return joint;
	}
	return { .dot_id = id, .rotation = quaternion::IDENTITY };
}

fn bool AppState.set_working_pose(&self, uint id, Quaternionf rotation, Vec3 offset)
{
	if (!self.pose_edit_active) return false;
	foreach (&joint : self.pose_edit_draft)
	{
		if (joint.dot_id != id) continue;
		if (joint.rotation.v == rotation.v && joint.offset == offset) return false;
		joint.rotation = rotation;
		joint.offset = offset;
		return true;
	}
	return false;
}

<*
 Puts the mesh back at rest and closes whichever display mode is open.

 Every door into a posed mesh comes through here first, which is what makes "only
 one at a time" a property of the code rather than of a pair of assignments
 somebody has to remember. Dropping the palette is what puts the mesh back: the
 pass skins only while there is one.
*>
fn void AppState.stop_deformed_display(&self)
{
	// Every exit releases a transient clip draft, including non-UI exits such as
	// starting playback or loading another clip.
	(void)self.discard_pose_edit();
	self.animating = false;
	self.drop_palette();
}

<*
 The transient animation draft in this view's joint order — what
 `joint_palette` takes.

 Not a sixth field on `RigView`: the five it carries are what the binder reads,
 every caller of `open_rig` pays for all of them, and only the palette wants this
 one.

 A joint absent from the draft comes back at rest.

 The caller owns the returned arrays.
*>
fn rig::Pose AppState.draft_pose(&self, Allocator allocator, RigView* view)
{
	rig::Pose pose = rig::rest_pose(allocator, view.len());

	foreach (usz j, uint id : view.dot_ids)
	{
		PosedJoint held = self.working_pose(id);
		pose.rotations[j] = held.rotation;
		pose.offsets[j] = held.offset;
	}

	return pose;
}

<*
 The pose a gesture solves in: `draft_pose` with the editing clip's look-at
 targets laid over it, as they are on screen, so the IK and the turn work in the
 frame the user sees rather than the unaimed one (with the chest and neck carrying
 part of a head turn, the two differ).

 **Grounding.** `refresh_posed` aims after `ground_pose`. The gestures solve on
 the pose before the floor shift (each one adds the shift back as `ground_shift`),
 so the aim is computed here on the *grounded* frame, the one on screen, and the
 floor's translation is then taken out of the offsets again. The rotations are
 the aimed ones, the offsets the draft's own, which is what the solvers expect.
 The shift is read once per call; it can differ a little by the end of a move
 that lifts a planted foot, and the aim is then recomputed from the keyed draft
 like any other refresh.

 Records the joints the aims turned, their authored rotations and their aimed
 ones in `gesture_aim`/`gesture_aimed`, replacing the last call's. The write
 that ends the same call (`write_pose`/`write_body`) hands them to `unaim_pose`.
 A clip with no aims, or no active draft, costs nothing and records nothing.

 **Clip pins are not laid over here.** A gesture solves on the draft and holds what
 it must with its own `position_locks`; the shown pose (`refresh_posed`) puts the
 clip's pins over whatever the gesture wrote, in the same order playback uses.

 The caller owns the returned arrays.
*>
fn rig::Pose AppState.gesture_pose(&self, Allocator allocator, RigView* view)
{
	self.drop_gesture_aim();
	rig::Pose pose = self.draft_pose(allocator, view);
	if (!self.pose_edit_active) return pose;
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || clip.aims.len == 0) return pose;

	Vec3[] offsets = alloc::new_array(mem, Vec3, pose.offsets.len);
	defer alloc::free(mem, offsets);
	foreach (i, o : pose.offsets) offsets[i] = o;

	String[] names = self.names_for(view, self.editing);
	ground_pose(mem, &view.skeleton, names, clip.ground, &pose, clip.phase_at(self.edit_time));
	self.apply_clip_aims(view, *clip, self.editing, self.edit_time, &pose, &self.gesture_aim);
	foreach (i, o : offsets) pose.offsets[i] = o;

	if (self.gesture_aim.joints.len > 0)
	{
		self.gesture_aimed = alloc::new_array(mem, Quaternionf, self.gesture_aim.joints.len);
		foreach (i, joint : self.gesture_aim.joints) self.gesture_aimed[i] = pose.rotations[joint];
	}
	return pose;
}

<*
 Takes the look-at targets back out of a pose a gesture solved in
 `gesture_pose`'s aimed frame, before it is written to the draft (which holds
 authored rotations only).

 An aim turned a joint's authored local rotation `a` into `m = P * a`, where
 `P = m * a^-1` is the turn it added, expressed in the parent's frame. With `s`
 the rotation the gesture left the joint with:

   `s == m`   the gesture did not touch it: back to `a`, bit for bit
   else       `a * m^-1 * s` = `P^-1 * s`: the authored rotation that the same
              turn `P` carries to exactly `s`

 so laying the aim over what was written reproduces what the user was shown (and
 where the aim is recomputed, the target still wins the swing). Joints the aims
 did not touch are left as solved. The record is spent: a second call, as when
 `write_body` hands over to `write_pose`, does nothing.
*>
fn void AppState.unaim_pose(&self, rig::Pose* pose)
{
	foreach (i, joint : self.gesture_aim.joints)
	{
		if (joint >= pose.rotations.len) continue;
		Quaternionf was = self.gesture_aim.before[i];
		Quaternionf aimed = self.gesture_aimed[i];
		Quaternionf solved = pose.rotations[joint];
		pose.rotations[joint] = solved.v == aimed.v
			? was
			: was.mul(aimed.invert()).mul(solved).normalize();
	}
	self.drop_gesture_aim();
}

fn void AppState.drop_gesture_aim(&self)
{
	self.gesture_aim.free(mem);
	if (self.gesture_aimed.len > 0) alloc::free(mem, self.gesture_aimed);
	self.gesture_aimed = {};
}

<*
 The rotation a turn on the grabbed joint is measured from: the aimed one it
 began with when the look-at targets steer it, the snapshot's otherwise.
*>
fn Quaternionf AppState.turn_was(&self)
{
	if (self.pose_before_count == 0) return quaternion::IDENTITY;
	if (self.turn_aimed_dot != 0 && self.turn_aimed_dot == self.pose_before[0].dot_id) return self.turn_aimed_was;
	return self.pose_before[0].rotation;
}

<*
 Rebuilds the palette and posed overlay from the transient animation draft.

 **It fills `posed_dots` as well as the palette**, and that carries the whole
 screen. The bones, the dots, the names, the pick test and the reach ring all
 read `AppState.dot_position`, so every one of them follows the pose with no
 further change — and it is only safe because the mode locks rest editing, so
 nothing on screen is claiming to be somewhere a click would edit.

 Called when the pose changes rather than every frame. Nothing here moves on its
 own, which is also why `ticking` is not widened for this mode: a frame that
 redrew an unchanging picture would keep the on-demand loop awake for nothing.
*>
fn void AppState.refresh_posed(&self)
{
	self.sync_clip_pins();
	if (!self.pose_edit_active) return;
	self.drop_palette();

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		(void)self.discard_pose_edit();
		return;
	}
	RigView view = opened;
	defer view.free(mem);

	rig::Pose pose = self.draft_pose(mem, &view);
	defer pose.free(mem);
	if (self.pose_edit_active)
	{
		AnimTemplate* clip = self.clip(self.editing);
		if (clip)
		{
			String[] names = self.names_for(&view, self.editing);
			ground_pose(mem, &view.skeleton, names, clip.ground, &pose,
				clip.phase_at(self.edit_time));
			// After the floor, as everywhere: the pins and targets never feed back into it.
			self.apply_clip_pins(&view, *clip, self.editing, self.edit_time, &pose);
			self.apply_clip_aims(&view, *clip, self.editing, self.edit_time, &pose);
		}
	}

	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette) return;
	self.pose_palette = palette;

	// The overlay before the skin, and unconditionally: a rig with no mesh binds
	// nothing and still has joints to draw while its timeline draft is edited.
	self.posed_dots = posed_overlay(mem, &view.skeleton, view.dot_ids, palette);
	if (AnimTemplate* shown = self.clip(self.editing))
	{
		self.posed_aims = self.aim_handles(&view, *shown, self.editing, self.edit_time, palette, &self.posed_aim_links);
	}

	// A failed bind is not fatal here. The overlay still makes the draft legible
	// and the draft remains available to save or discard.
	(void)self.rebind_skin(&view);
}

// ---------------------------------------------------------------------------
// The chain, and the two gestures over it.

<*
 The grabbed joint and the unbranched run of joints above it, in this rig's joint
 order: what a finger curls along, what a selected mate is carried by, and what
 the MCP's target solve bends. A body gesture moves far more than this
 (`pose_body`).

 Short-lived, like the `RigView` it was read out of — joint indices are that
 build's BFS output and mean nothing after the next dot edit. What outlives the
 gesture is written back by dot id.
*>
struct PoseChain
{
	usz effector;               // the grabbed joint; it is aimed, never turned
	usz count;                  // how many ancestors turn, nearest first
	usz[IK_MAX_CHAIN] joints;
}

faultdef NO_DRAG_DIRECTION;

<*
 Resolve a temporary directional lock into the world direction this gesture
 started with.

 Placement and G keep their familiar world X/Y/Z. R reads X/Y/Z in the selected
 joint's bone-local limit frame, carried by the current parent pose; B reads the
 frame's +Y bone direction for either gesture. The result is latched into
 `DragState`, so turning the joint cannot turn its own lock underneath the hand.
*>
fn Vec3? AppState.drag_lock_direction(&self, DragAxis axis)
{
	int component = axis.component();
	bool needs_frame = axis == DragAxis.BONE || self.drag.verb == DragVerb.TURN;
	if (!needs_frame)
	{
		if (component < 0) return NO_DRAG_DIRECTION~;
		return AXIS_DIRECTION[component];
	}

	Quaternionf carried = self.joint_axes(self.drag.dot, posed: self.drag.verb != DragVerb.PLACE)!;

	JointRotationAxis local;
	if (axis == DragAxis.BONE)
	{
		local = JointRotationAxis.Y;
	}
	else
	{
		switch (axis)
		{
			case X: local = JointRotationAxis.X;
			case Y: local = JointRotationAxis.Y;
			case Z: local = JointRotationAxis.Z;
			default: return NO_DRAG_DIRECTION~;
		}
	}

	Vec3 direction;
	switch (local)
	{
		case X: direction = carried.rotate_vec3({ 1, 0, 0 });
		case Y: direction = carried.rotate_vec3({ 0, 1, 0 });
		case Z: direction = carried.rotate_vec3({ 0, 0, 1 });
	}
	if (direction.length_sq() <= 1.0e-12f) return NO_DRAG_DIRECTION~;
	return direction.normalize();
}

<*
 The joint's own X, Y and Z: its limit frame, which a turn locked to an axis
 spins about and the Rotate tool's rings are drawn along while posing.

 A rest-rig placement uses the stable rest frame. `posed` carries the same frame
 by the parent's current world rotation, which is where it is while posing.
*>
fn Quaternionf? AppState.joint_axes(&self, uint dot, bool posed)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return NO_DRAG_DIRECTION~;
	RigView view = opened;
	defer view.free(mem);
	sz found = view.joint_of(dot);
	if (found < 0) return NO_DRAG_DIRECTION~;

	JointRotationLimits limits = self.doc.rotation_limits_of(dot);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	if (!frame.usable()) return NO_DRAG_DIRECTION~;
	if (!posed) return frame.rotation;

	rig::Pose pose = self.draft_pose(mem, &view);
	defer pose.free(mem);
	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return NO_DRAG_DIRECTION~;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);
	return carried_joint_limit_frame(frame, &view.skeleton, world, (usz)found);
}

<*
 How close a solve has to get before it stops early, as a fraction of the rig's
 height.

 Against the rig rather than in model units, the same rule every other epsilon
 in crig follows: a model authored in centimetres and one in metres are the same
 figure, and a fixed distance would be a different demand on each.
*>
const float IK_TOLERANCE = 0.002;

const uint POSE_IK_PASSES = 12;

<*
 A chain no longer than this share of the figure's height is a digit — a finger,
 a toe, a tail tip — and curls rather than reaches.

 Measured by length, not by name: an arm's run is a third of the height and a
 leg's more than half, a finger's is under five percent. The line is drawn at
 a tenth, which a hand's longest finger clears three times over and no limb comes
 near.
*>
const float CURL_CHAIN_SHARE = 0.1f;

// A curl is reached by smaller steps, so it spends more of them.
const uint CURL_PASS_FACTOR = 4;
const float POSE_IK_MAX_STEP = 0.5;

<*
 The run above a dot: the joint, and the ancestors `ancestor_run` walks up to the
 first fork — the limb as the rig's own shape draws it.
*>
fn PoseChain AppState.pose_chain(&self, RigView* view, uint dot)
{
	PoseChain chain;
	sz joint = view.joint_of(dot);
	if (joint < 0) return chain;
	chain.effector = (usz)joint;
	chain.count = view.skeleton.ancestor_run((usz)joint, chain.joints[..]);
	return chain;
}

<*
 Whether a grab on this chain's joint curls it as a digit instead of moving the
 body: a run at least one joint long that, with everything hanging below the
 grabbed joint, is no longer end to end than `CURL_CHAIN_SHARE` of the figure's
 height — a finger, a toe's tip. Its knuckle is the fork it hangs from, and a
 finger closing does not lean the body. A short run with the chest and the arms
 below it is no digit.
*>
fn bool digit_chain(RigView* view, PoseChain chain) @local
{
	if (chain.count == 0) return false;
	rig::Skeleton* skeleton = &view.skeleton;
	float length = 0.0f;
	usz below = chain.effector;
	foreach (above : chain.joints[:chain.count])
	{
		length += (skeleton.joints[below] - skeleton.joints[above]).length();
		below = above;
	}
	// And the longest way down from the grabbed joint. Parents come first, so one
	// pass backwards sees every child before its parent.
	usz n = skeleton.len();
	float[] reach = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, reach);
	for (usz i = n; i > chain.effector + 1; i--)
	{
		usz j = i - 1;
		int parent = skeleton.parents[j];
		if (parent < (int)chain.effector) continue;
		float down = reach[j] + (skeleton.joints[j] - skeleton.joints[(usz)parent]).length();
		reach[(usz)parent] = math::max(reach[(usz)parent], down);
	}
	return length + reach[chain.effector] <= skeleton.height() * CURL_CHAIN_SHARE;
}

<*
 Begins a pose move on the selected joint (G).

 Any joint: a limb's end reaches, a fork or the root carries the body, and a
 finger curls (`pose_toward`). The whole figure is snapshotted, since the body
 solve may move any of it, and escape and the release then have it all.

 `depth` is latched from the joint's posed position now, for the reason on the
 field: a depth re-read each frame would follow the solve's own output.

 @param held : `True when a button is down for this — a press on the joint, ended by the release. False for the key, which has nothing to let go of and is confirmed by a click.`
 @return `False when no gesture began, so the key can fall through to whatever else it means.`
*>
fn bool AppState.begin_pose(&self, bool held = false)
{
	if (self.drag.dot != 0) return false;
	if (self.selected == 0)
	{
		self.@notice("select a joint to move");
		return false;
	}
	if (!self.prepare_animation_pose()) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	if (view.joint_of(self.selected) < 0) return false;
	PoseChain chain = self.pose_chain(&view, self.selected);

	rig::Pose pose = self.gesture_pose(mem, &view);
	defer pose.free(mem);
	// Nothing is written here: the moves bring their own record.
	defer self.drop_gesture_aim();
	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette) return false;
	defer alloc::free(mem, palette);

	Vec3 at = view.skeleton.joints[chain.effector].transform(palette[chain.effector]);
	if (self.pose_edit_active) at = self.dot_position(*self.doc.find(self.selected));

	self.snapshot_chain(&view, chain);
	self.locked_before_count = 0;
	self.gather_pose_mates(&view, chain, palette);
	self.snapshot_gesture();
	// The whole surface refitted once, and a start already in contact learned
	// now: what a pull moves is the anchor's subtree, the run and everything
	// hanging off it, and what it carries as one piece is the nearest pivot's.
	self.begin_collision_gesture(&view,
		chain.count > 0 ? chain.joints[chain.count - 1] : chain.effector,
		chain.count > 0 ? chain.joints[0] : chain.effector);
	self.drag = {
		.dot = self.selected,
		.from = at,
		.axis = DragAxis.FREE,
		.verb = DragVerb.POSE,
		.depth = (at - self.model_eye(&self.camera)).length(),
		.held = held,
		.pointer_pending = !held,
	};
	return true;
}

<*
 Begins a turn on the selected joint (R, or a press on one of the Joint card's
 dials).

 Needs no chain: a joint turns about its own position whatever is above it, and
 what it carries is everything below. A pin or a planted foot down there is held
 as the sweep goes (`land_turn`).

 The sweep is anchored on the first mouse move rather than here. A key arrives at
 the tree's root, which has no pointer — and the pixels the sweep is measured in
 belong to the pane the pointer is over, which only that pane can say.
 `TURN_UNANCHORED` is what the viewport tests for. A dial never anchors it at
 all: it measures its own sweep and lands the angle through `turn_joint_to`.
*>
fn bool AppState.begin_turn(&self, bool held = false, DragAxis axis = FREE)
{
	if (self.drag.dot != 0) return false;
	if (self.selected == 0)
	{
		self.@notice("select a joint to turn");
		return false;
	}
	if (!self.prepare_animation_pose()) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(self.selected);
	if (joint < 0) return false;

	rig::Pose pose = self.gesture_pose(mem, &view);
	defer pose.free(mem);
	// Nothing is written here: the moves bring their own record.
	defer self.drop_gesture_aim();
	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette) return false;
	defer alloc::free(mem, palette);

	// A turn on a joint the targets steer: the sweep starts from the aimed
	// rotation on screen, and the user is told what R can still do there.
	self.turn_aimed_dot = 0;
	if (self.gesture_aim.has((usz)joint))
	{
		foreach (i, j : self.gesture_aim.joints)
		{
			if (j != (usz)joint) continue;
			self.turn_aimed_dot = self.selected;
			self.turn_aimed_was = self.gesture_aimed[i];
		}
		self.@notice("a look-at target steers this joint - R changes its roll; drag the ring to aim");
	}

	PoseChain only = { .effector = (usz)joint };
	self.snapshot_chain(&view, only);
	self.locked_before_count = 0;
	self.pose_mate_count = 0;
	self.snapshot_gesture();
	// The surface is refitted whole here, once, so every request during the
	// sweep needs only the subtree's rows — and a start already in contact is
	// learned now rather than on the first mouse move.
	self.begin_collision_gesture(&view, (usz)joint);
	self.drag = {
		.dot = self.selected,
		.from = self.pose_edit_active
			? self.dot_position(*self.doc.find(self.selected))
			: view.skeleton.joints[(usz)joint].transform(palette[(usz)joint]),
		.axis = DragAxis.FREE,
		.verb = DragVerb.TURN,
		.anchor = TURN_UNANCHORED,
		.held = held,
	};
	if (axis != DragAxis.FREE && !self.lock_drag(axis))
	{
		self.cancel_drag();
		return false;
	}
	return true;
}

<*
 Records what the gesture's joints hold, so escape can put them back and the
 release can tell which of them actually moved.
*>
fn void AppState.snapshot_chain(&self, RigView* view, PoseChain chain)
{
	self.pose_before_count = 0;
	self.pose_before[self.pose_before_count++] = self.working_pose(view.dot_ids[chain.effector]);

	for (usz i = 0; i < chain.count && self.pose_before_count < POSE_SNAPSHOT; i++)
	{
		self.pose_before[self.pose_before_count++] = self.working_pose(view.dot_ids[chain.joints[i]]);
	}
}

// One entry per joint, capped at `LOCK_SNAPSHOT`: two anchors that reach the same
// joint must not snapshot it twice, or the fixed-order restore would let the
// second write win.
fn void AppState.push_locked_before(&self, uint id)
{
	if (self.locked_before_count >= LOCK_SNAPSHOT) return;
	for (usz s = 0; s < self.locked_before_count; s++)
	{
		if (self.locked_before[s].dot_id == id) return;
	}
	self.locked_before[self.locked_before_count++] = self.working_pose(id);
}

<*
 The other selected joints a G carries along with the grabbed one: each keeps
 its own limb and is pulled by the same move, so a hand's fingertips selected
 together curl together. A joint whose run shares a joint with the grab's or an
 earlier mate's is left to ride — two solves fighting over one knuckle would
 shake it — as is one nothing above can bend. Their runs are snapshotted with
 the pins', which escape restores and the release banks.
*>
fn void AppState.gather_pose_mates(&self, RigView* view, PoseChain grabbed, Matrix4f[] palette)
{
	self.pose_mate_count = 0;
	if (grabbed.count == 0) return;
	uint[LOCK_SNAPSHOT] claimed;
	usz claimed_count = claim_joint(claimed[..], 0, (uint)grabbed.effector);
	for (usz t = 0; t < grabbed.count; t++) claimed_count = claim_joint(claimed[..], claimed_count, (uint)grabbed.joints[t]);
	foreach (id : self.also_selected.array_view())
	{
		if (self.pose_mate_count >= POSE_MATES) break;
		if (id == self.selected) continue;
		PoseChain chain = self.pose_chain(view, id);
		if (chain.count == 0) continue;
		if (run_wants_claimed(chain, claimed[:claimed_count])
			|| array::contains(claimed[:claimed_count], (uint)chain.effector)) continue;
		claimed_count = claim_joint(claimed[..], claimed_count, (uint)chain.effector);
		for (usz t = 0; t < chain.count; t++)
		{
			claimed_count = claim_joint(claimed[..], claimed_count, (uint)chain.joints[t]);
			self.push_locked_before(view.dot_ids[chain.joints[t]]);
		}
		self.pose_mates[self.pose_mate_count++] = {
			.dot = id,
			.from = view.skeleton.joints[chain.effector].transform(palette[chain.effector]),
		};
	}
}

// Each mate's run solved toward where it was grabbed, moved as far as the grab.
fn void AppState.carry_pose_mates(&self, RigView* view, rig::Pose* pose, Vec3 moved, float tolerance)
{
	foreach (mate : self.pose_mates[:self.pose_mate_count])
	{
		PoseChain chain = self.pose_chain(view, mate.dot);
		if (chain.count == 0) continue;
		Vec3[IK_MAX_CHAIN + 1] points;
		self.chain_points(view, chain, *pose, {}, points[:chain.count + 1]);
		(void)self.solve_limited_pose_chain(view, chain, pose,
			points[:chain.count + 1], mate.from + moved, tolerance, {}, false);
	}
}

<*
 Snapshot every joint of the draft as the gesture begins — see `gesture_before`.
 Every gesture takes the whole figure: the body solve may move any joint of it,
 the pins' and the planted feet's limbs included, and escape and the release
 compare and restore the lot.
*>
fn void AppState.snapshot_gesture(&self)
{
	self.drop_gesture_before();
	usz count = (usz)self.doc.dots.len();
	if (count == 0) return;
	self.gesture_before = alloc::new_array(mem, PosedJoint, (sz)count);
	foreach (usz i, dot : self.doc.dots.array_view()) self.gesture_before[i] = self.working_pose(dot.id);
}

fn void AppState.drop_gesture_before(&self)
{
	if (self.gesture_before.len > 0) alloc::free(mem, self.gesture_before);
	self.gesture_before = {};
}

// Whether any joint of `chain`'s ancestor run is already claimed — the conflict
// test that stands a lower-priority anchor down.
fn bool run_wants_claimed(PoseChain chain, uint[] claimed) @local
{
	for (usz t = 0; t < chain.count; t++)
	{
		if (array::contains(claimed, (uint)chain.joints[t])) return true;
	}
	return false;
}

// Add `joint` to the claim buffer if it is new and there is room, returning the
// count after. A silent stop past the buffer's length under-claims rather than
// overrunning, which can only miss a conflict on a rig pinned past `LOCK_SNAPSHOT`.
fn usz claim_joint(uint[] buf, usz count, uint joint) @local
{
	if (array::contains(buf[:count], joint)) return count;
	if (count >= buf.len) return count;
	buf[count] = joint;
	return count + 1;
}

<*
 Read back how near each pin is to what it holds, for `lock_position_residual`
 and `lock_rotation_residual`.

 	`app.measure_position_locks(&view, pose, app.drag.dot);`

 The pins are held inside the body solve itself (`pose_body`), so what is left
 here is the honest reading: the model-space gap each position pin ended from
 its point, and the angle each rotation pin ended from its orientation — a pin
 out of its limb's reach, or one a limit or another pin would not let hold, says
 by how much. Read off `pose` as the screen will show it: a grounded clip is
 shown after the ground solve has lifted or dropped it whole, and a foot that
 could not stay flat is exactly what makes that solve move the pins, so the miss
 it causes is reported rather than hidden. The grabbed joint's own pin reads zero
 while it is carried on purpose.
*>
fn void AppState.measure_position_locks(&self, RigView* view, rig::Pose pose, uint moving_dot)
{
	if (self.position_locks.len == 0) return;
	rig::Pose shown = pose.copy(mem);
	defer shown.free(mem);
	if (self.pose_edit_active)
	{
		AnimTemplate* clip = self.clip(self.editing);
		if (clip && clip.ground.solves())
		{
			ground_pose(mem, &view.skeleton, self.names_for(view, self.editing), clip.ground, &shown,
				clip.phase_at(self.edit_time));
		}
	}
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, shown);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? spun = shown.world_rotations(mem, &view.skeleton);
	if (catch spun) return;
	Quaternionf[] world = spun;
	defer alloc::free(mem, world);
	foreach (usz i, lock : self.position_locks)
	{
		sz j = view.joint_of(lock.dot_id);
		if (j < 0) continue;
		bool carried = lock.dot_id == moving_dot;
		self.position_locks[i].residual = lock.position && !carried
			? (view.skeleton.joints[(usz)j].transform(palette[(usz)j]) - lock.target).length()
			: 0.0f;
		self.position_locks[i].turn_residual = lock.rotation && !carried
			? rotation_angle_between(world[(usz)j], lock.orient)
			: 0.0f;
	}
}

<*
 Turn a joint so its world orientation matches `held`, whatever its parents are
 now doing.

 A joint's world rotation is its parent's composed with its own, so holding the
 world at `held` means setting the local to `parent_world^-1 * held` — the same
 change of frame `pose_toward`'s pivot step runs, at one joint and with no target
 but the orientation itself. Constrained through the joint's limits when it has
 them, so a held foot never lands out of range; free otherwise, since most feet
 are. Nothing below is written — the subtree follows through `joint_palette`.
*>
fn void AppState.hold_world_rotation(&self, RigView* view, rig::Pose* pose, uint dot_id, Quaternionf held)
{
	sz found = view.joint_of(dot_id);
	if (found < 0) return;
	usz joint = (usz)found;

	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
	Quaternionf local = parent_world.invert().mul(held).normalize();

	JointRotationLimits limits = self.doc.rotation_limits_of(dot_id);
	if (limits.constrained)
	{
		JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		if (frame.usable()) local = constrain_joint_rotation(frame, limits, local);
	}
	pose.rotations[joint] = local;
}

<*
 How near to straight, or to the root-effector line, a pole may be before it
 names no bend to aim.

 A pole is defined only when the limb is meaningfully bent and the pole sits
 meaningfully off the line from the chain root to the effector. Both are read as
 a sine — a perpendicular offset over the arm it turns on — so the one threshold
 serves a fingertip and a leg alike and does not drift as a rig is scaled up or
 down, the rule every epsilon in crig follows (see `IK_TOLERANCE`). About a
 degree of bend, or of lean off the line.
*>
const float POLE_MIN_SINE = 0.02;

<*
 What `aim_chain_pole` made of a pole, so a caller can report it honestly.

 A pole is a hint, not a demand, and several honest shapes of limb leave it with
 nothing to do: a limb with one bend has no elbow or knee to point, a straight
 limb has no bend off the line to swing, a folded limb whose effector has come
 back onto its root has no line to swing about, and a pole on that line itself
 names no side. Each leaves the pose untouched. AIMED_TO_LIMIT is a real aim the
 root pivot's own limits cut short — the bend went as far toward the pole as the
 joint allows, and the effector may have drifted the residual reports.
*>
enum PoleAim
{
	AIMED,
	AIMED_TO_LIMIT,
	NO_BEND,
	COINCIDENT,
	STRAIGHT,
	POLE_ON_LINE,
}

<*
 Twist a limb's bend so its elbow or knee points toward `pole`.

 	`PoleAim done = app.aim_chain_pole(&view, &pose, chain, pole);`

 Which way a two-bone limb bends is free once it has reached its target: every
 turn of the limb about the line from its root to the effector reaches the same
 point, and only swings the elbow or knee round that line. This is the pole
 vector a game rig gives — it turns the chain's root pivot about that line until
 the first bend lies in the plane the pole names. The effector is *on* the line,
 so it does not move; only the bend swings. One turn, not a search: the reach it
 follows (`solve_limited_pose_chain`) owns the iteration budget; this is a single
 shortest arc, so the same request gives the same bend every time.

 Run after the reach, on the pose it left. Constrained through the root pivot's
 own limits, so the twist never lands it out of range; when a limit clamps it
 short the effector can drift, and the answer is `AIMED_TO_LIMIT` so the caller
 says so alongside the residual.

 The `PoleAim` says what happened. Every degeneracy is measured relative to the
 arm it turns on (`POLE_MIN_SINE`), never an absolute distance, so the reading
 holds at any scale of rig: a chain with one bend or none is `NO_BEND`, a folded
 chain whose effector has met its root is `COINCIDENT`, a straight limb is
 `STRAIGHT`, and a pole on the root-effector line is `POLE_ON_LINE`. Only `AIMED`
 and `AIMED_TO_LIMIT` write into `pose`; the subtree follows through
 `joint_palette`.
*>
fn PoleAim AppState.aim_chain_pole(&self, RigView* view, rig::Pose* pose, PoseChain chain, Vec3 pole)
{
	if (chain.count < 2) return NO_BEND;

	Vec3[IK_MAX_CHAIN + 1] points;
	self.chain_points(view, chain, *pose, {}, points[:chain.count + 1]);
	Vec3 root = points[0];
	Vec3 mid = points[1];
	Vec3 tip = points[chain.count];

	// The upper bone is the scale every test below reads against: a perpendicular
	// offset shorter than `POLE_MIN_SINE` of it is no bend, or a pole with no side,
	// whether the rig is a centimetre or a kilometre.
	float arm = (mid - root).length();
	if (arm <= 0.0f) return STRAIGHT;
	float floor = arm * POLE_MIN_SINE;

	Vec3 axis = tip - root;
	if (axis.length() <= floor) return COINCIDENT;
	Vec3 line = axis.normalize();

	// Each joint's offset from the root, with the part along the line removed: the
	// bend as it stands, and the side the pole names. Either being small against
	// its own arm means there is no plane to turn — a straight limb, or a pole on
	// the line.
	Vec3 have = mid - root;
	have = have - line * have.dot(line);
	if (have.length() <= floor) return STRAIGHT;
	Vec3 want = pole - root;
	float reach = (pole - root).length();
	want = want - line * want.dot(line);
	if (want.length() <= reach * POLE_MIN_SINE) return POLE_ON_LINE;

	// The turn about the line that carries the bend onto the pole's side — both
	// perpendicular to the line, so the shortest arc between them is about it.
	Quaternionf turn = ik::shortest_arc(have, want);

	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return NO_BEND;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	usz joint = pose_chain_joint(chain, 0);
	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0
		? world[(usz)parent]
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf candidate = parent_world.invert().mul(turn).mul(world[joint]).normalize();

	JointRotationLimits limits = self.doc.rotation_limits_of(view.dot_ids[joint]);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	Quaternionf constrained = constrain_joint_rotation(frame, limits, candidate);
	pose.rotations[joint] = constrained;

	// The turn survived its limits when the constrained rotation still matches the
	// one the pole wanted, up to sign (the quaternion double cover). Short of that,
	// a limit cut it and the effector may have drifted.
	return math::abs(constrained.v.dot(candidate.v)) > 0.9999999f ? AIMED : AIMED_TO_LIMIT;
}

<*
 Whether `target` asks a digit to open: the pointer is nearer, in angle about
 the anchor, to where the chain points when straight than the tip is now.

 Straight is the rest chord carried by the anchor's parent, so it is the finger
 laid out from the knuckle however the hand is turned. A finger at rest is
 already straight, and a pointer anywhere off that line closes it.

 @param points : `Anchor first and tip last, as the solver reads them.`
*>
fn bool digit_opening(RigView* view, PoseChain chain, Quaternionf[] world, Vec3[] points, Vec3 target) @local
{
	usz anchor = pose_chain_joint(chain, 0);
	usz effector = pose_chain_joint(chain, points.len - 1);
	int parent = view.skeleton.parents[anchor];
	Vec3 rest = view.skeleton.joints[effector] - view.skeleton.joints[anchor];
	Vec3 straight = parent >= 0 ? world[(usz)parent].rotate_vec3(rest) : rest;
	Vec3 chord = points[points.len - 1] - points[0];
	Vec3 want = target - points[0];
	if (straight.length() <= 0.0f || chord.length() <= 0.0f || want.length() <= 0.0f) return false;
	straight = straight.normalize();
	float now = chord.normalize().dot(straight);
	float asked = want.normalize().dot(straight);
	// A hair of slack so a pointer held still is not read as opening by noise.
	return asked > now + 1.0e-4f;
}

<*
 The skeleton joint represented by one point in an anchor-first pose chain.

 `ancestor_run` stores the pivots nearest-first, while CCD stores the same
 points anchor-first and appends the effector. Keeping that reversal in one
 helper prevents the solver and its world-rotation update from disagreeing
 about which joint a point belongs to.
*>
fn usz pose_chain_joint(PoseChain chain, usz point) @private
{
	return point < chain.count
		? chain.joints[chain.count - 1 - point]
		: chain.effector;
}

<*
 Where a digit's tip can go when it curls towards `target`, along the line from
 the chain's anchor to `target`.

 The pointer asks for a direction from the knuckle as much as a place. A finger
 that follows it curls — every joint bends by the same turn, the way a finger
 closes — and a curl is shorter than the straight finger it started as. So the
 target's distance is cut to the chord that curl has, when it is further than
 that: the solve then aims at a place the curled finger reaches rather than at
 one only the straight finger comes near. A target already inside the curl's
 chord is left where it is.

 With `n` bones turning at `n` joints, bone `j` has turned `j` times the one
 step by the time it is reached, and the chord points along their average, which
 is `(n + 1) / 2` steps, so for a chord turned by `angle` the step is
 `2 * angle / (n + 1)`.

 @param points : `Anchor first and tip last, as the solver reads them.`
*>
fn Vec3 curl_target(Vec3[] points, Vec3 target) @local
{
	usz bones = points.len - 1;
	Vec3 chord = points[bones] - points[0];
	Vec3 want = target - points[0];
	float straight = chord.length();
	float distance = want.length();
	if (bones < 2 || straight <= 0.0f || distance <= 0.0f) return target;

	float cosine = math::clamp(chord.dot(want) / (straight * distance), -1.0f, 1.0f);
	float angle = (float)math::acos((double)cosine);
	float step = 2.0f * angle / (float)(bones + 1);

	float along = 0.0f;
	float across = 0.0f;
	for (usz j = 1; j <= bones; j++)
	{
		float length = (points[j] - points[j - 1]).length();
		along += length * (float)math::cos((double)(step * (float)j));
		across += length * (float)math::sin((double)(step * (float)j));
	}
	float reach = math::sqrt(along * along + across * across);
	if (distance <= reach) return target;
	return points[0] + want * (reach / distance);
}

// The length of the polyline through `points`.
fn float chain_length(Vec3[] points) @local
{
	float total = 0.0f;
	for (usz i = 1; i < points.len; i++) total += (points[i] - points[i - 1]).length();
	return total;
}

<*
 Bend an anchor-first point chain while applying each joint's authored limits.

 This is collision::ik's CCD loop at crig's side of the world/local seam. A
 generic point solver cannot know a rig's bone-local frames, but clamping only
 after an unconstrained solve is not sufficient either: a parent that was
 stopped by its limit must carry its children by the *permitted* turn, not by
 the turn the solver originally wanted.

 For each pivot, the shortest world-space step is converted into the
 parent-relative rotation `rig::Pose` stores, constrained through the same
 table used by R and the Joint card, and converted back to the actual world
 step. Only that actual step is applied to the remaining points and their
 carried world rotations. The pose therefore never contains an out-of-range
 intermediate answer, even when the target is unreachable.

 Then the mesh, after the limits, once per solve rather than per pass or per
 pivot: the passes run unchecked to their answer, that answer is tested with
 the anchor's subtree moving, and a solve in contact is cut to the largest
 clear fraction of the way from the pose it began with. One test is the whole
 price of a clear move, which is nearly every move of a drag — a target the
 chain cannot quite reach runs every pass every move, and checking each of
 them made a pull cost a dozen tests where a turn costs one. The step a solve
 takes between two pointer positions is small enough that the straight slerp
 the cut measures along is as good a path as the passes' own.

 A cut solve is followed by one careful pass in which each pivot's step is
 tested on its own and taken whole or not at all, so a chain resting on the
 body can still slide along it: the pivot whose step digs in is held while
 the ones that carry the tip away are let through. Without that pass a chain
 touching the mesh could never leave it by a pull, since any solve with a
 component into the surface reads as contact at once. One test per pivot
 rather than a bisection each: the cut already found the largest fraction of
 the combined motion, and what the careful pass adds is which pivots may
 still move, at the cost of a chain's length in tests rather than eight
 times that.

 What this does not do is slide *around* a corner of the body: every pivot's
 arc from a hand pressed against the side of the torso may lead into it, and
 then the hand stays until the target moves somewhere the arcs are clear —
 back the way it came, or away from the surface. That is a local minimum of
 contact-constrained IK, not an unreachable target, and the residual reports
 it as the former would be reported.
*>
fn float AppState.solve_limited_pose_chain(
	&self,
	RigView* view,
	PoseChain chain,
	rig::Pose* pose,
	Vec3[] points,
	Vec3 target,
	float tolerance,
	Vec3 ground_shift = {},
	bool report = true)
{
	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return (target - points[chain.count]).length();
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	// The chain's joints in pivot order, and what each held when the solve
	// began: what the mesh check slerps a cut solve back toward. The moving
	// set is the anchor's whole subtree, since a pass may turn every pivot;
	// only the deepest pivot's subtree moves as one piece, since every pivot
	// above it turns by a step of its own.
	usz tip = chain.count;
	usz[IK_MAX_CHAIN + 1] pivots;
	for (usz p = 0; p < tip; p++) pivots[p] = pose_chain_joint(chain, p);
	Quaternionf[IK_MAX_CHAIN + 1] held;
	for (usz p = 0; p < tip; p++) held[p] = pose.rotations[pivots[p]];
	// A pin re-solve passes `report: false`: it runs the limited CCD passes and
	// returns the gap, but leaves the collision report to the gesture the hand is
	// actually driving. Everything below the early return touches `last_block`, so
	// clearing `checked` is the whole of what that costs.
	bool checked = report && tip > 0 && self.collision_blocking_active() && !self.collision_suspended;
	float reach = (points[tip] - points[0]).length();

	// A digit curls: every pivot takes an equal part of each pass's turn instead of
	// the nearest taking all it can and the rest finishing off. CCD run
	// greedily puts the bend where the lever is longest, which on a finger is the
	// knuckle, and drags the tip down on a finger that stays straight. Sharing the
	// turn lets the arc each pivot would take on its own — largest nearest the tip,
	// where the target is furthest in angle — decide the proportions, which is a
	// finger closing. Arms and legs run at a share of 1, exactly as before.
	//
	// And the target is pulled in to where such a curl can put the tip: a pointer
	// dragged straight across a straight finger is always a little beyond its
	// reach, and the closest the tip can come to it is by staying straight and
	// pivoting at the knuckle, which is the stiff finger this is here to avoid.
	float share = 1.0f;
	bool curl_start = false;
	uint passes = POSE_IK_PASSES;
	if (tip > 1 && chain_length(points[:tip + 1]) <= view.skeleton.height() * CURL_CHAIN_SHARE)
	{
		share = 1.0f / (float)tip;
		passes *= CURL_PASS_FACTOR;
		// Only a finger being closed is curled toward the pointer. One pulled back
		// out toward straight has the shared passes alone, which open every
		// pivot evenly; the curl's pull would bend it back in against the hand.
		if (!digit_opening(view, chain, world, points[:tip + 1], target))
		{
			target = curl_target(points[:tip + 1], target);
			curl_start = true;
		}
	}

	// The curl itself, before any pass: every pivot turns the same step about the
	// one axis that swings the finger towards the pointer. Where the passes below
	// are left to find *a* way to the target, this is the way they start from, so
	// what they refine is a finger already closing evenly rather than one that has
	// leaned on whichever joint they reached first. Through the same limits and the
	// same carry as any step, so a joint that cannot bend that way gives its part to
	// the passes instead of being forced.
	if (curl_start)
	{
		Vec3 chord = points[tip] - points[0];
		Vec3 want = target - points[0];
		Vec3 axis = chord.cross(want);
		float angle = (float)math::atan2((double)axis.length(), (double)chord.dot(want));
		if (axis.length() > 0.0f && angle > 0.0f)
		{
			Quaternionf each = quaternion::from_axis_angle{float}(axis.normalize(), 2.0f * angle / (float)(tip + 1));
			for (usz pivot = 0; pivot < tip; pivot++)
			{
				JointLimitFrame frame;
				JointRotationLimits limits;
				Quaternionf allowed = self.pivot_step(view, chain, pose, points, world, pivot, target, &frame, &limits, 1.0f, &each);
				carry_pivot(view, chain, pose, points, world, pivot, allowed);
			}
		}
	}

	for (uint pass = 0; pass < passes; pass++)
	{
		float gap = (target - points[tip]).length();
		if (tolerance > 0.0f && gap <= tolerance) break;

		// Nearest the effector first, matching collision::ik. Later pivots carry
		// the answer of the joints below them rather than replacing it.
		for (usz k = tip; k > 0; k--)
		{
			usz pivot = k - 1;
			JointLimitFrame frame;
			JointRotationLimits limits;
			Quaternionf allowed = self.pivot_step(view, chain, pose, points, world, pivot, target, &frame, &limits, share);
			carry_pivot(view, chain, pose, points, world, pivot, allowed);
		}
	}
	if (!checked) return (target - points[tip]).length();

	uint[] moving = subtree_joints(mem, &view.skeleton, pivots[0]);
	defer if (moving.len > 0) alloc::free(mem, moving);
	uint[] rigid = subtree_joints(mem, &view.skeleton, pivots[tip - 1]);
	defer if (rigid.len > 0) alloc::free(mem, rigid);
	if (self.blocked_chain_pass(view, pose, pivots[:tip], held[:tip], moving, rigid, &self.last_block, reach))
	{
		return (target - points[tip]).length();
	}

	// Cut: read the chain back off the landed pose, then the careful pass —
	// unless the mesh is over budget, when the cut solve is the whole answer.
	self.chain_points(view, chain, *pose, ground_shift, points);
	if (self.collision_mode == REDUCED) return (target - points[tip]).length();
	Quaternionf[]? landed_world = pose.world_rotations(mem, &view.skeleton);
	if (catch landed_world) return (target - points[tip]).length();
	foreach (usz i, rotation : landed_world) world[i] = rotation;
	alloc::free(mem, landed_world);
	Clock careful = clock::now();
	defer self.last_block.seconds += (float)careful.mark().to_sec();
	for (usz k = tip; k > 0; k--)
	{
		usz pivot = k - 1;
		usz joint = pivots[pivot];
		JointLimitFrame frame;
		JointRotationLimits limits;
		Quaternionf allowed = self.pivot_step(view, chain, pose, points, world, pivot, target, &frame, &limits, share);
		Quaternionf was = pose.rotations[joint];
		uint[] carried = subtree_joints(mem, &view.skeleton, joint);
		defer if (carried.len > 0) alloc::free(mem, carried);
		CollisionContact contact;
		self.last_block.tests++;
		if (self.pose_is_clear(view, pose, joint, allowed, carried, &contact))
		{
			carry_pivot(view, chain, pose, points, world, pivot, allowed);
			continue;
		}
		// Held: the step is not taken. The surface is left at the rejected
		// pose; the next pivot up refits a subtree that contains this one, at
		// the pose the pivot keeps, so only the anchor's rejection has to be
		// settled by hand.
		pose.rotations[joint] = was;
		if (pivot == 0) self.settle_collision_surface(view, *pose, carried);
		if (!self.last_block.contact.hit || contact.gap.distance < self.last_block.contact.gap.distance)
		{
			self.last_block.contact = contact;
		}
	}

	return (target - points[tip]).length();
}

<*
 The limit-permitted rotation `pivot` would take to swing the tip toward
 `target`: the shortest world-space arc, carried into the parent-relative
 form the pose stores and constrained there. Nothing is written; `carry_pivot`
 is what applies it.

 @param frame : `Receives the joint's limit frame, for a caller that constrains a further candidate.`
 @param limits : `Receives the joint's limits, likewise.`
 @param share : `The part of the arc this pivot takes; 1 is all of it, less leaves the rest to the pivots after it.`
 @param forced : `A world-space step to take instead of the arc towards the target, still carried into the parent's frame and constrained.`
*>
fn Quaternionf AppState.pivot_step(
	&self,
	RigView* view,
	PoseChain chain,
	rig::Pose* pose,
	Vec3[] points,
	Quaternionf[] world,
	usz pivot,
	Vec3 target,
	JointLimitFrame* frame,
	JointRotationLimits* limits,
	float share = 1.0f,
	Quaternionf* forced = null)
{
	usz tip = chain.count;
	usz joint = pose_chain_joint(chain, pivot);
	Quaternionf wanted = forced
		? *forced
		: ik::shortest_arc(points[tip] - points[pivot], target - points[pivot], POSE_IK_MAX_STEP);
	if (share < 1.0f && !forced) wanted = ((Quaternionf)quaternion::IDENTITY).slerp(wanted, share);

	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0
		? world[(usz)parent]
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf candidate = parent_world.invert()
		.mul(wanted).mul(world[joint]).normalize();

	uint dot = view.dot_ids[joint];
	*limits = self.doc.rotation_limits_of(dot);
	*frame = joint_limit_frame(&view.skeleton, view.dot_ids, *limits);
	return constrain_joint_rotation(*frame, *limits, candidate);
}

<*
 Writes `rotation` to `pivot` and carries the chain below it by the world
 step that actually results. Positions and orientations below the pivot must
 see the same permitted step: updating only the pose would make the rest of
 the solve continue against forbidden geometry.
*>
fn void carry_pivot(
	RigView* view,
	PoseChain chain,
	rig::Pose* pose,
	Vec3[] points,
	Quaternionf[] world,
	usz pivot,
	Quaternionf rotation) @private
{
	usz tip = chain.count;
	usz joint = pose_chain_joint(chain, pivot);
	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0
		? world[(usz)parent]
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf before_world = world[joint];
	Quaternionf after_world = parent_world.mul(rotation).normalize();
	Quaternionf actual = after_world.mul(before_world.invert()).normalize();
	pose.rotations[joint] = rotation;

	for (usz point = pivot + 1; point <= tip; point++)
	{
		points[point] = points[pivot] + actual.rotate_vec3(points[point] - points[pivot]);
	}
	for (usz point = pivot; point <= tip; point++)
	{
		usz carried = pose_chain_joint(chain, point);
		world[carried] = actual.mul(world[carried]).normalize();
	}
}

<*
 Where the chain's joints stand for `pose`, anchor first and effector last —
 the points the solver turns, and what it reads back after a cut pass.
*>
fn void AppState.chain_points(&self, RigView* view, PoseChain chain, rig::Pose pose, Vec3 ground_shift, Vec3[] points)
{
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	for (usz t = 0; t < chain.count; t++)
	{
		usz j = chain.joints[chain.count - 1 - t];
		points[t] = view.skeleton.joints[j].transform(palette[j]) + ground_shift;
	}
	points[chain.count] = view.skeleton.joints[chain.effector].transform(palette[chain.effector]) + ground_shift;
}

<*
 A digit's runs put back as the gesture found them, so every move solves from
 the same start: where the finger ends up is then a function of the pointer
 alone, and dragging back to where the grab began brings it back to what it
 was. Solved on from the last move's answer instead, a finger keeps whatever a
 limit or a pass left it holding on the way and creeps. The grabbed run comes
 from `pose_before`, each mate's from `locked_before`; a joint a look-at target
 turns is left as `gesture_pose` aimed it.
*>
fn void AppState.restore_digit_start(&self, RigView* view, rig::Pose* pose, PoseChain chain)
{
	foreach (held : self.pose_before[:self.pose_before_count])
	{
		sz j = view.joint_of(held.dot_id);
		if (j >= 0 && !self.gesture_aim.has((usz)j)) pose.rotations[(usz)j] = held.rotation;
	}
	foreach (mate : self.pose_mates[:self.pose_mate_count])
	{
		PoseChain run = self.pose_chain(view, mate.dot);
		for (usz t = 0; t < run.count; t++)
		{
			usz j = run.joints[t];
			if (self.gesture_aim.has(j)) continue;
			foreach (held : self.locked_before[:self.locked_before_count])
			{
				if (held.dot_id == view.dot_ids[j]) pose.rotations[j] = held.rotation;
			}
		}
	}
}

<*
 The whole figure put back as the gesture found it, joint by joint — turns and
 offsets — so a body solve starts every move from the same pose.

 This is what makes the pose a function of the pointer alone: where the body ends
 up for a pull to this point is the same whichever way the pointer came, and
 dragging back to where the grab began brings every joint back to what it was. Solved
 on from the last move's answer instead, a limb keeps whatever a limit, a pin or
 a cut left it holding on the way, and the same pointer gives another pose. The
 same promise `restore_digit_start` makes for a finger.

 Every joint in the tree of `root` is put back, the root's slide with it. A joint a
 look-at target turns is left as `gesture_pose` aimed it: that is the pose on
 screen, and it is frozen in the solve.
*>
fn void AppState.restore_body_start(&self, RigView* view, rig::Pose* pose, usz root)
{
	foreach (held : self.gesture_before)
	{
		sz j = view.joint_of(held.dot_id);
		if (j < 0 || self.gesture_aim.has((usz)j) || tree_root_of(&view.skeleton, (usz)j) != root) continue;
		pose.rotations[(usz)j] = held.rotation;
		pose.offsets[(usz)j] = held.offset;
	}
}

<*
 Carries the grabbed joint toward `target`, and the body with it.

 	`float gap = app.pose_toward(where_the_pointer_is);`

 Two answers, and the rig's shape picks between them. A digit — a finger, a toe's
 tip, any run up to its knuckle no longer than `CURL_CHAIN_SHARE` of the figure —
 curls along its own run (`solve_limited_pose_chain`), and the other selected
 digits with it. Anything else moves the body: every joint of the figure solved
 at once against every pin and every planted foot (`pose_body`), so a hand that
 cannot reach brings the chest, a thigh pulled moves the hips, and a waist pulled
 down sits the body on its feet.

 **The grab keeps its angle, softly.** The grabbed joint, and each selected mate
 with it, is asked to go to the pointer and to keep the world rotation it began
 with (`POINT_POSE_GRAB_HOLD`): a pulled waist drops the body with the chest
 still upright, a pulled hand arrives as it faced. The hold is light, so a limb that
 has to turn to reach turns.

 Each move is solved from the pose the gesture began with, not from the last
 move's answer, so the same pointer gives the same pose.

 The pointer is in the frame the screen shows; the solve is in the draft's, which
 for a clip shown grounded differs by the ground solve's shift. The target is
 carried back by it (`gesture_shift`).

 @param target : `Where the grabbed joint should end up, as shown.`
 @return `How far it still is from the target — what the reach, the limits, the pins or the mesh left; the same number the collision report's residual holds.`
*>
fn float AppState.pose_toward(&self, Vec3 target)
{
	if (self.drag.dot == 0 || self.drag.verb != DragVerb.POSE) return 0.0f;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0.0f;
	RigView view = opened;
	defer view.free(mem);

	sz found = view.joint_of(self.drag.dot);
	if (found < 0) return 0.0f;
	PoseChain chain = self.pose_chain(&view, self.drag.dot);

	rig::Pose pose = self.gesture_pose(mem, &view);
	defer pose.free(mem);
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return 0.0f;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);

	self.last_block = { .fraction = 1.0f };
	float height = view.skeleton.height();
	float tolerance = height > 0.0f ? height * IK_TOLERANCE : 0.0f;
	Vec3 shift = self.gesture_shift(&view, palette, (usz)found);
	float gap;
	if (digit_chain(&view, chain))
	{
		// Anchor first, effector last — the order the solver reads a chain in, and
		// the reverse of `ancestor_run`'s nearest-first.
		self.restore_digit_start(&view, &pose, chain);
		Vec3[IK_MAX_CHAIN + 1] points;
		self.chain_points(&view, chain, pose, shift, points[:chain.count + 1]);
		gap = self.solve_limited_pose_chain(&view, chain, &pose, points[:chain.count + 1], target, tolerance, shift);
		self.carry_pose_mates(&view, &pose, target - self.drag.from, tolerance);
	}
	else
	{
		// The pose the gesture began with: what the grab keeps the angle of, and
		// what the body solve starts from (`pose_body` puts it back as well).
		self.restore_body_start(&view, &pose, tree_root_of(&view.skeleton, (usz)found));
		Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
		if (catch read) return 0.0f;
		Quaternionf[] began = read;
		defer alloc::free(mem, began);
		PointGoal[POSE_MATES + 1] gesture;
		usz goals = 0;
		gesture[goals++] = {
			.joint = (usz)found,
			.position = true,
			.soft = true,
			.target = target - shift,
			.rotation = true,
			.orient = began[(usz)found],
			.turn_weight = POINT_POSE_GRAB_HOLD,
		};
		// The other selected joints follow by the same move, as far as they can.
		foreach (mate : self.pose_mates[:self.pose_mate_count])
		{
			sz j = view.joint_of(mate.dot);
			if (j < 0 || j == found) continue;
			gesture[goals++] = {
				.joint = (usz)j,
				.position = true,
				.soft = true,
				.target = mate.from + (target - self.drag.from),
				.rotation = true,
				.orient = began[(usz)j],
				.turn_weight = POINT_POSE_GRAB_HOLD,
			};
		}
		gap = self.pose_body(&view, &pose, gesture[:goals], shift, true);
	}
	// What the target asked for and did not get, whatever stood in the way: the
	// limits, the reach, the pins, or the mesh the report names.
	self.last_block.residual = gap;
	self.last_block.unreached = gap > tolerance;
	self.judge_collision_cost();
	self.measure_position_locks(&view, pose, self.drag.dot);
	self.write_body(&view, pose);
	return gap;
}

<*
 The ground correction between the frame a gesture solves in — the draft — and
 the one the screen shows: a clip shown grounded is shifted whole by the ground
 solve. Read off `joint`, whose shown position and drafted one differ by exactly
 that. Zero when nothing is being edited.
*>
fn Vec3 AppState.gesture_shift(&self, RigView* view, Matrix4f[] palette, usz joint)
{
	if (!self.pose_edit_active) return {};
	Dot* dot = self.doc.find(view.dot_ids[joint]);
	if (!dot) return {};
	return self.dot_position(*dot) - view.skeleton.joints[joint].transform(palette[joint]);
}

// The tree root above `joint`. Joints are ordered parents first, so the climb ends.
fn usz tree_root_of(rig::Skeleton* skeleton, usz joint) @local
{
	usz walk = joint;
	while (skeleton.parents[walk] >= 0) walk = (usz)skeleton.parents[walk];
	return walk;
}

// Whether `a` is `b` or one of its ancestors. Joints are ordered parents first.
fn bool at_or_above(rig::Skeleton* skeleton, usz a, usz b) @local
{
	for (int walk = (int)b; walk >= 0; walk = skeleton.parents[(usz)walk])
	{
		if ((usz)walk == a) return true;
	}
	return false;
}

<*
 The body's answer to a gesture: every joint of the figure the gesture's joint
 belongs to solved at once by `body_solve`, toward the gesture's own goals and
 against every pin and every foot the clip has planted.

 	`float miss = app.pose_body(&view, &pose, gesture[..], shift, true);`

 **From the start, every time.** The figure is first put back as the gesture found
 it (`restore_body_start`), whatever the last move left, and the solve is made
 from there: the pose is then a function of the gesture's goals alone. The same
 pointer gives the same pose however it got there, a small step of the pointer is
 a small change of the pose, and dragging away and back returns every joint
 exactly. What a planted foot holds, what a pin keeps the angle of and what the
 stiffness draws the joints back toward are all read off that start.

 What it asks of the body besides the gesture:

   each pin       held hard, where it was set — carried back into the solve's
                  frame by `shift`. A position pin holds the point, and the
                  joint's angle softly (`POINT_POSE_PIN_SOFT_TURN`): a foot stays
                  flat while its ankle's limits allow, and gives way as little as
                  it must beyond. A pin on the angle holds that hard, and the
                  body stops before it gives. The grabbed joint's own pin is not
                  held: it is being carried on purpose.
   each planted contact   on a clip shown grounded, the feet it has down at this
                  moment hold where they are, hard, and so does the end of a short
                  foot bone above a planted toe, so the foot stays flat: the
                  ground solve would otherwise lift the whole figure, pins and
                  all, to put a foot back. A toe under a pin that holds its
                  position and its angle is not held twice. Every contact stays
                  on or above the floor.
   the balance    the centre of mass held over the planted and pinned feet,
                  unless Balance is off
   the stiffness  every joint drawn back toward where the gesture began, by its
                  mass: the light limbs answer a pull first, the pelvis last

 Aimed joints are frozen: what a look-at target turns stays its own, and
 `unaim_pose` hands it back untouched. A pull is then cut by the mesh when
 blocking is on (`blocked_body_pass`), and the cut pose has its pins put back by
 a second solve that asks nothing of the gesture; a turn has had its own check.

 Written into `pose`; the caller writes it back.

 @param gesture : `The gesture's own goals, in the solve's frame. The first is the one the user holds.`
 @param shift : `The ground correction from the solve's frame to the one shown; see gesture_shift.`
 @param pull : `A G: the grab's miss says the pins are holding, and the mesh cuts the solve.`
 @return `How far the first goal's joint ended from its target.`
*>
fn float AppState.pose_body(&self, RigView* view, rig::Pose* pose, PointGoal[] gesture, Vec3 shift, bool pull)
{
	rig::Skeleton* skeleton = &view.skeleton;
	usz n = skeleton.len();
	if (gesture.len == 0 || n == 0) return 0.0f;
	usz root = tree_root_of(skeleton, gesture[0].joint);
	float h = skeleton.height();

	// Where the last move left the figure is what the mesh's surface stands at;
	// the solve begins from where the gesture did.
	rig::Pose last = pose.copy(mem);
	defer last.free(mem);
	self.restore_body_start(view, pose, root);

	Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
	if (catch built) return 0.0f;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? read = pose.world_rotations(mem, skeleton);
	if (catch read) return 0.0f;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	// Every joint of the figure, with its mass, its limits and what holds it. The
	// masses are the shape's and the mesh's, with no joint made as heavy as the
	// one it hangs from: the solve turns real joints, and a hip socket stays on its
	// pelvis because the pelvis carries it.
	float[] inv_mass = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, inv_mass);
	bool[] trunk = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, trunk);
	float[] part_mass = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, part_mass);
	point_pose_masses(skeleton, h, inv_mass, trunk, self.body_part_masses(view, part_mass) ? part_mass : {}, fork_carry: false);
	usz[GROUND_CONTACT_MAX] contact;
	bool[GROUND_CONTACT_MAX] planted;
	GroundContacts floor_spec = self.gesture_contacts(view, contact[..], planted[..]);
	List{PointJoint} joints;
	joints.init(mem);
	defer joints.free();
	for (usz j = 0; j < n; j++)
	{
		if (tree_root_of(skeleton, j) != root) continue;
		JointRotationLimits limits = self.doc.rotation_limits_of(view.dot_ids[j]);
		joints.push({
			.joint = j,
			.inv_mass = inv_mass[j],
			.trunk = trunk[j],
			.frozen = self.gesture_aim.has(j),
			.floored = array::contains(contact[:floor_spec.count], j),
			.limits = limits,
			.frame = limits.constrained ? joint_limit_frame(skeleton, view.dot_ids, limits) : (JointLimitFrame){},
		});
	}

	// The gesture's goals, then the pins, then the planted feet.
	List{PointGoal} goals;
	goals.init(mem);
	defer goals.free();
	foreach (goal : gesture) goals.push(goal);
	// In the rig's own order, so the answer does not depend on which pin was set
	// first.
	for (usz j = 0; j < n; j++)
	{
		sz i = self.lock_index(view.dot_ids[j]);
		if (i < 0 || view.dot_ids[j] == self.drag.dot) continue;
		PositionLock lock = self.position_locks[(usz)i];
		if (tree_root_of(skeleton, j) != root || body_goal_of(goals.array_view(), j) >= 0) continue;
		// A pin on the position alone keeps the part's angle too, softly, as the
		// gesture found it: not `lock.orient`, which is the angle it had when the
		// pin was set and may be long stale. A pin on the angle holds `lock.orient`
		// hard, and the body gives way before it does.
		bool keeps_angle = lock.position && !lock.rotation;
		goals.push({
			.joint = j,
			.position = lock.position,
			.target = lock.target - shift,
			.rotation = lock.rotation || keeps_angle,
			.orient = keeps_angle ? world[j] : lock.orient,
			.turn_weight = keeps_angle ? POINT_POSE_PIN_SOFT_TURN : 0.0f,
		});
	}
	for (usz i = 0; i < floor_spec.count; i++)
	{
		usz foot = contact[i];
		if (!planted[i] || tree_root_of(skeleton, foot) != root || body_goal_of(goals.array_view(), foot) >= 0) continue;
		// A foot the gesture itself takes hold of is being lifted, not stood on.
		if (under_the_gesture(skeleton, gesture, foot)) continue;
		// A toe under a pinned ankle rides on it when the pin holds the angle too.
		if (rides_a_pin(skeleton, goals.array_view(), foot)) continue;
		goals.push({ .joint = foot, .position = true, .target = skeleton.joints[foot].transform(palette[foot]) });
		// And the end of a short foot bone above a planted toe, so the foot stays flat
		// rather than pivoting on its toe as the leg folds.
		int heel = skeleton.parents[foot];
		if (heel < 0 || (usz)heel == root || body_goal_of(goals.array_view(), (usz)heel) >= 0) continue;
		if ((skeleton.joints[foot] - skeleton.joints[(usz)heel]).length() > h * CURL_CHAIN_SHARE) continue;
		goals.push({ .joint = (usz)heel, .position = true, .target = skeleton.joints[(usz)heel].transform(palette[(usz)heel]) });
	}

	PointPoseSettings settings = {
		.height = h,
		.has_floor = floor_spec.count > 0,
		.floor = floor_spec.floor - shift.y,
		.balance = !self.balance_off,
	};

	rig::Pose before = pose.copy(mem);
	defer before.free(mem);
	body_solve(skeleton, pose, joints.array_view(), goals.array_view(), &settings);

	if (pull)
	{
		// The mesh, tested with the root where the gesture found it.
		Quaternionf held_rotation = before.rotations[root];
		Vec3 held_offset = before.offsets[root];
		foreach (held : self.gesture_before)
		{
			if (held.dot_id != view.dot_ids[root]) continue;
			held_rotation = held.rotation;
			held_offset = held.offset;
		}
		if (!self.blocked_body_pass(view, pose, before, root, held_rotation, held_offset, &self.last_block, &last))
		{
			// The cut is a blend of the start and the answer, and a blend takes every
			// pin a little off its point. The pins and the planted feet alone, with
			// the cut as the pose to stay near, put them back.
			if (self.last_block.fraction > 0.0f)
			{
				PointGoal[] holds = goals.array_view()[gesture.len..];
				if (holds.len > 0) body_solve(skeleton, pose, joints.array_view(), holds, &settings);
			}
			// The cut answer is a different pose: the grab's miss is read off it.
			Matrix4f[]? cut = rig::joint_palette(mem, skeleton, *pose);
			if (try landed = cut)
			{
				goals[0].residual = (skeleton.joints[gesture[0].joint].transform(landed[gesture[0].joint]) - gesture[0].target).length();
				alloc::free(mem, landed);
			}
		}
	}

	// Said once the pins, not the pointer, are deciding where the body stops.
	float miss = goals[0].residual;
	if (pull && goals.len() > gesture.len && miss > h * 0.02f && !self.last_block.blocked)
	{
		self.@notice("the pinned joints hold the body here · unlock one to pull further");
	}
	return miss;
}

// Whether `joint` is at or below a joint the gesture holds.
fn bool under_the_gesture(rig::Skeleton* skeleton, PointGoal[] gesture, usz joint) @local
{
	foreach (goal : gesture) if (at_or_above(skeleton, goal.joint, joint)) return true;
	return false;
}

// Which goal holds `joint`, or -1.
fn sz body_goal_of(PointGoal[] goals, usz joint) @local
{
	foreach (usz g, goal : goals) if (goal.joint == joint) return (sz)g;
	return -1;
}

<*
 Whether `joint` is on the same limb as a hold that already says where it is: it
 hangs below one, or one hangs below it.

 A hold that is a position and a hard angle fixes everything below it — a toe
 under a foot pinned flat — and a second one there would only fight it. A position
 alone fixes the point and leaves the part free to turn (softly held, not fixed),
 so the toe below it still needs its own hold, or the foot could roll off it. A
 joint above a held position is on the limb either way.
*>
fn bool rides_a_pin(rig::Skeleton* skeleton, PointGoal[] goals, usz joint) @local
{
	foreach (goal : goals)
	{
		if (!goal.position || goal.soft) continue;
		if (at_or_above(skeleton, joint, goal.joint)) return true;
		bool angle_held = goal.rotation && goal.turn_weight <= 0.0f;
		if (angle_held && at_or_above(skeleton, goal.joint, joint)) return true;
	}
	return false;
}

// Contacts a ground spec can name for one gesture; a spec longer than this is cut.
const usz GROUND_CONTACT_MAX = 16;

<*
 The contact joints of the clip being posed, when it is shown grounded — the ones
 `ground_pose` will raise and lower the body by. Count 0 for a clip with no ground
 spec, or when nothing is being edited.
*>
fn GroundContacts AppState.gesture_contacts(&self, RigView* view, usz[] contact, bool[] down)
{
	if (!self.pose_edit_active) return {};
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || !clip.ground.solves()) return {};
	String[] names = self.names_for(view, self.editing);
	return ground_contacts(&view.skeleton, names, clip.ground, clip.phase_at(self.edit_time), contact, down);
}

<*
 Writes a gesture's pose back: every joint of the figure the gesture snapshotted —
 any of them the body solve may have turned, the root's slide with them — then
 puts it on screen the way `write_pose` does. A joint that did not change is
 refused by `set_working_pose`, so this records only what moved.
*>
fn void AppState.write_body(&self, RigView* view, rig::Pose pose)
{
	self.unaim_pose(&pose);
	foreach (was : self.gesture_before)
	{
		sz j = view.joint_of(was.dot_id);
		if (j >= 0) self.set_working_pose(was.dot_id, pose.rotations[(usz)j], pose.offsets[(usz)j]);
	}
	self.write_pose(view, pose);
}

<*
 Turns the grabbed joint in place by `angle` about a world `axis` (R).

 Measured from the rotation the gesture began with rather than composed onto
 whatever is there, so sweeping back to where the pointer started returns the
 joint to where it started — and so the escape has nothing to accumulate away.

 The joint's own position does not move: `joint_palette` applies a joint's
 rotation after the translation that places it, so a turn pivots the subtree and
 leaves the joint itself alone. That is the whole difference between this and G.
*>
fn void AppState.turn_joint(&self, Vec3 axis, float angle)
{
	if (self.drag.dot == 0 || self.drag.verb != DragVerb.TURN) return;
	if (axis.length_sq() < 1.0e-12f) return;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(self.drag.dot);
	if (joint < 0) return;

	rig::Pose pose = self.gesture_pose(mem, &view);
	defer pose.free(mem);

	// The parent's world rotation as the gesture found it. A turn that carries a
	// hold is solved from the start (`land_turn`), and the sweep is measured in
	// the parent's frame there: read off the last answer instead, a parent the
	// body solve has since moved would turn the same sweep to another place. With
	// nothing held nothing else moves, and the two are the same pose.
	rig::Pose began = pose.copy(mem);
	defer began.free(mem);
	self.restore_body_start(&view, &began, tree_root_of(&view.skeleton, (usz)joint));
	Quaternionf[]? read = began.world_rotations(mem, &view.skeleton);
	if (catch read) return;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	int parent = view.skeleton.parents[(usz)joint];
	Quaternionf rw_parent = parent >= 0 ? world[(usz)parent] : quaternion::IDENTITY;
	Quaternionf was = self.turn_was();

	Quaternionf turn = quaternion::from_axis_angle{float}(axis.normalize(), angle);
	Quaternionf swept = rw_parent.invert().mul(turn).mul(rw_parent).mul(was).normalize();

	// R and the numeric inspector meet at the same bone-local table. The frame
	// itself is rest/model-space; this parent-relative quaternion is therefore
	// constrained by changing basis through that frame, while the sweep's world
	// axis above remains free to follow the current camera and parent pose.
	JointRotationLimits limits = self.doc.rotation_limits_of(self.drag.dot);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	Quaternionf requested = constrain_joint_rotation(frame, limits, swept);
	self.land_turn(&view, &pose, (usz)joint, requested, frame, limits);
}

<*
 Puts the grabbed joint at `angle` about one of its bone-local axes (a dial on
 the Joint card).

 The other two angles are the gesture's own starting ones, read off the
 snapshot rather than off the draft, so a dial changes exactly the number its
 column below shows and nothing the joint had already been given — and so
 sweeping back to where the pointer started returns the joint to where it
 started, the same promise `turn_joint` makes. Lands through the same table and
 the same mesh check.
*>
fn void AppState.turn_joint_to(&self, JointRotationAxis axis, float angle)
{
	if (self.drag.dot == 0 || self.drag.verb != DragVerb.TURN) return;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(self.drag.dot);
	if (joint < 0) return;

	rig::Pose pose = self.gesture_pose(mem, &view);
	defer pose.free(mem);

	JointRotationLimits limits = self.doc.rotation_limits_of(self.drag.dot);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	if (!frame.usable()) return;

	Quaternionf was = self.turn_was();
	Vec3 angles = joint_angles_from_rotation(frame, was);
	angles[axis.component()] = angle;
	Quaternionf requested = constrain_joint_rotation(frame, limits,
		rotation_from_joint_angles(frame, angles));
	self.land_turn(&view, &pose, (usz)joint, requested, frame, limits);
}

faultdef NO_TURN;

<*
 The angle the turning joint had about one bone-local axis when the gesture
 began — where a dial's sweep is measured from.

 @return? NO_TURN : `No turn is in flight, or the joint has no usable frame.`
*>
fn float? AppState.turn_start_angle(&self, JointRotationAxis axis)
{
	if (self.drag.dot == 0 || self.drag.verb != DragVerb.TURN || self.pose_before_count == 0) return NO_TURN~;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return NO_TURN~;
	RigView view = opened;
	defer view.free(mem);

	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids,
		self.doc.rotation_limits_of(self.drag.dot));
	if (!frame.usable()) return NO_TURN~;
	return joint_angles_from_rotation(frame, self.turn_was())[axis.component()];
}

<*
 Where a turn ends up once the table has had its say: the mesh, after the
 limits. The draft still holds the rotation the last write found clear, and the
 request lands on it or short of it.

 Then the pins. Turning the hips or the spine carries the feet as surely as
 pulling them does, so when a pin or a planted foot hangs at or below the turned
 joint, the body solve takes the turn as a held world rotation — the joint's
 own point held too, softly — and bends the rest to keep them (`pose_body`). A
 turn nothing held hangs from is the plain turn.

 Like a pull, the solve is made from the pose the gesture began with, so the turn
 is a function of the sweep alone and sweeping back returns the body exactly. The
 joint's point is the one it began at, and the world rotation held is the landed
 local one in its parent's frame at the start: the parent is among the joints the
 solve may move, and the angle asked for is the one the sweep measured.
*>
fn void AppState.land_turn(
	&self,
	RigView* view,
	rig::Pose* pose,
	usz joint,
	Quaternionf requested,
	JointLimitFrame frame,
	JointRotationLimits limits)
{
	self.blocked_joint_rotation(view, pose, joint, requested, frame, limits, &self.last_block);
	self.judge_collision_cost();
	if (self.turn_carries_a_hold(view, joint))
	{
		// The shift is that of the pose on screen; the point and the parent's
		// angle are the start's.
		rig::Pose began = pose.copy(mem);
		defer began.free(mem);
		self.restore_body_start(view, &began, tree_root_of(&view.skeleton, joint));
		Matrix4f[]? shown = rig::joint_palette(mem, &view.skeleton, *pose);
		Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, began);
		Quaternionf[]? spun = began.world_rotations(mem, &view.skeleton);
		if (try palette = built)
		{
			defer alloc::free(mem, palette);
			if (try world = spun)
			{
				defer alloc::free(mem, world);
				if (try on_screen = shown)
				{
					defer alloc::free(mem, on_screen);
					int parent = view.skeleton.parents[joint];
					Quaternionf above = parent >= 0 ? world[(usz)parent] : quaternion::IDENTITY;
					PointGoal[1] gesture = {{
						.joint = joint,
						.position = true,
						.soft = true,
						.target = view.skeleton.joints[joint].transform(palette[joint]),
						.rotation = true,
						.orient = above.mul(pose.rotations[joint]).normalize(),
					}};
					(void)self.pose_body(view, pose, gesture[..], self.gesture_shift(view, on_screen, joint), false);
				}
			}
		}
	}
	self.measure_position_locks(view, *pose, self.drag.dot);
	self.write_body(view, *pose);
}

<*
 Whether a turn of `joint` moves anything the body is holding: a pin, or a foot
 the clip has planted, at or below it.
*>
fn bool AppState.turn_carries_a_hold(&self, RigView* view, usz joint)
{
	foreach (lock : self.position_locks)
	{
		sz j = view.joint_of(lock.dot_id);
		if (j >= 0 && lock.dot_id != self.drag.dot && at_or_above(&view.skeleton, joint, (usz)j)) return true;
	}
	usz[GROUND_CONTACT_MAX] contact;
	bool[GROUND_CONTACT_MAX] planted;
	GroundContacts floor_spec = self.gesture_contacts(view, contact[..], planted[..]);
	for (usz i = 0; i < floor_spec.count; i++)
	{
		if (planted[i] && at_or_above(&view.skeleton, joint, contact[i])) return true;
	}
	return false;
}

<*
 Writes a solved pose back into the document and puts it on screen.

 **By dot id**, which is the whole reason `RigView` hands out `dot_ids` beside
 the skeleton: the joint order this pose is in belongs to one build and is gone
 by the next dot edit.

 Only the joints the gesture holds are written. Walking the whole rig would be
 correct and would also record every untouched joint as an edit that changed
 nothing, which `set_pose` would refuse one at a time for no reason.
*>
fn void AppState.write_pose(&self, RigView* view, rig::Pose pose)
{
	// Only authored rotations are ever written; see `unaim_pose`.
	self.unaim_pose(&pose);
	for (usz i = 0; i < self.pose_before_count; i++)
	{
		uint id = self.pose_before[i].dot_id;
		sz j = view.joint_of(id);
		if (j < 0) continue;
		self.set_working_pose(id, pose.rotations[(usz)j], pose.offsets[(usz)j]);
	}

	// The selected mates' runs a curl carried along, written by the same rule:
	// those are the joints `gather_pose_mates` recorded.
	for (usz i = 0; i < self.locked_before_count; i++)
	{
		uint id = self.locked_before[i].dot_id;
		sz j = view.joint_of(id);
		if (j < 0) continue;
		self.set_working_pose(id, pose.rotations[(usz)j], pose.offsets[(usz)j]);
	}

	// The palette, not the binder. A pose moves no rest position, so the weights
	// underneath are exactly the ones they were before the gesture began — and
	// `mark_rig_stale` would re-run the vertex-by-bone pass on every mouse move.
	self.refresh_posed();
	// The contact was found against the pose just shown; any later refresh
	// that replaces it moves the stamp on and takes the ring with it.
	self.last_block.shown_at = self.pose_generation;
}

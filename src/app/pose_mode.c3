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

 **Where the solving happens is not here.** The chain rule and the frame
 conversion are crig's, because both are statements about *this* rig; the search
 that bends a polyline toward a point is `collision::ik`, because it is not about
 rigs at all. The seam between them is world space — the one frame two libraries
 can agree on without either learning the other's conventions — which is why this
 file gathers world positions out of the palette, hands them over as plain points,
 and converts what comes back into `rig::Pose`'s local rotations itself.
*>
module crig;

import rig;
import std::time;
import collision::ik;
import std::math;
import std::math::matrix;
import std::math::quaternion;



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
fn bool AppState.skinned(&self) => self.animating || self.pose_edit_active;

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
 drag moves the joint on the model, and Alt does that from Pose.
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
	self.@notice("Pose · drag a joint to pose it · Alt-drag still moves it");
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
			// After the floor, as everywhere: the targets never feed back into it.
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
 The joints one pose gesture may turn, in this rig's joint order.

 Short-lived, like the `RigView` it was read out of — joint indices are that
 build's BFS output and mean nothing after the next dot edit. What outlives the
 gesture is written back by dot id.
*>
struct PoseChain
{
	usz effector;               // the grabbed joint; it is aimed, never turned
	usz count;                  // how many ancestors turn, nearest first
	usz[IK_MAX_CHAIN] joints;
	bool slides;                // no ancestors and nothing above: the joint itself moves
	<*
	 A trunk joint (its parent forks) grabbed while an anchor is set: nothing above
	 it can bend to carry it, so the root translates under it instead. A root
	 translation moves every descendant by the same world vector whatever the
	 joints between turn by, so sliding the root by the grab's delta lands the
	 grabbed joint on the pointer and carries the whole figure with it — and the
	 anchored feet are then bent back into place. Off without a lock: a trunk joint
	 is still "R turns it" then, since moving the whole body from a shoulder with
	 nothing pinned is a surprise, not a pose.
	*>
	bool carries_root;
	usz root;                   // which joint the slide is written to, for carries_root
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

// A pin's weight against the grab's in the whole-body solve: far above, so when
// both cannot hold it is the grab that gives way and the feet stay planted.
const float PIN_WEIGHT = 50.0;

// A planted foot the clip's ground solve is about to hold on the floor, and that
// nobody pinned: held firmly against the grab's 1, but well under a pin, so a
// pin the user set wins where the two cannot both hold.
const float CONTACT_WEIGHT = 10.0;

// A body is held out along the ground, and sits by pitching, when a planted foot
// is further from the hips horizontally than this share of the hips' height.
const float SPREAD_BODY = 0.5;

// How much of a joint's drift from the pose the gesture began with the whole-body
// solve undoes each iteration, where the goals allow.
const float POSTURE_PULL = 0.3;

// How many times dearer a turn off the body's flex axis is, for such a body: a
// spine bends and a leg swings in its own plane before it twists or splays.
const float LATERAL_COST = 400.0; // a spine does not splay: effectively never

// How much stiffer a trunk joint is than a leg or the root's slide when a waist
// pull is shared between them: the hips drop and the legs fold before the back
// bends, the way a person sits.
const float SPINE_STIFFNESS = 4.0;

// A pin further than this share of the height from its point when a gesture
// begins was set where its limb cannot reach: it reports its miss but does not
// steer the solve.
const float PIN_LOOSE = 0.02;

// How much stiffer the root's slide is under a turn: turning the hips with the
// feet pinned bends the legs to follow rather than sliding the body.
const float TURN_ROOT_STIFFNESS = 8.0;

// How much stiffer the hips' tilt is than a leg when the body leans to keep its
// weight over the pinned feet: the lean settles in, it does not lead the pull.
const float BALANCE_TILT_STIFFNESS = 8.0;
const uint POSE_IK_PASSES = 12;
const float POSE_IK_MAX_STEP = 0.5;

<*
 What a drag on this dot may move.

 Three answers, and the rig's own shape picks between them. A joint with an
 unbranched run above it bends that run — the limb. A joint with nothing above it
 at all slides, because sliding a root is how the whole figure travels, rises or
 falls. A joint whose parent forks has neither: turning the fork would swing
 every other limb hanging off it, so nothing here can move it, and the caller
 says so rather than doing something surprising.
*>
fn PoseChain AppState.pose_chain(&self, RigView* view, uint dot)
{
	PoseChain chain;
	sz joint = view.joint_of(dot);
	if (joint < 0) return chain;

	chain.effector = (usz)joint;
	chain.count = view.skeleton.ancestor_run((usz)joint, chain.joints[..]);
	chain.slides = chain.count == 0 && view.skeleton.parents[(usz)joint] < 0;
	if (chain.count == 0 && !chain.slides && self.any_position_anchor())
	{
		// A trunk joint nothing above can bend, but a foot's position is held: the
		// root carries it instead. Walk to the root — this joint is not itself a
		// root, and joints are ordered parents-before-children, so the climb ends.
		usz walk = (usz)joint;
		while (view.skeleton.parents[walk] >= 0) walk = (usz)view.skeleton.parents[walk];
		chain.carries_root = true;
		chain.root = walk;
	}
	return chain;
}

<*
 Begins a pose move on the selected joint (G).

 The chain is worked out here, before any state is set, so a joint nothing can
 move is refused at the door — there is then nothing in flight to escape out of,
 and the message can name the key that *will* work.

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

	PoseChain chain = self.pose_chain(&view, self.selected);
	if (chain.count == 0 && !chain.slides && !chain.carries_root)
	{
		Dot* dot = self.doc.find(self.selected);
		String named = dot && dot.name.len > 0 ? dot.name : "this joint";
		self.@notice("nothing above %s can move it without moving its neighbours — R turns it, or lock a foot to move the body from here", named);
		return false;
	}

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
	// The root the trunk-carry slides is neither the effector nor an ancestor of
	// it, so it is not in the chain snapshot — but its offset is what the gesture
	// writes, so escape and the release need it here too.
	if (chain.carries_root && self.pose_before_count < POSE_SNAPSHOT)
	{
		self.pose_before[self.pose_before_count++] = self.working_pose(view.dot_ids[chain.root]);
	}
	self.snapshot_locks(&view, self.selected);
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
	};
	return true;
}

<*
 Begins a turn on the selected joint (R, or a press on one of the Joint card's
 dials).

 Needs no chain: a joint turns about its own position whatever is above it, and
 what it carries is everything below. That is why R is the answer G gives on a
 joint whose parent forks.

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
	self.snapshot_locks(&view, self.selected);
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

<*
 Records what every anchored limb holds, so escape restores them and the release
 banks the sit as one edit.

 Kept apart from `pose_before`: the grabbed chain has a fixed bound of its own and
 must not be crowded out by pins, and the two are restored by separate loops in
 `cancel_drag`/`end_drag`. Resets the count unconditionally, so a gesture with no
 anchors clears the last one's snapshot rather than inheriting it.

 The grabbed joint is skipped — its own anchor is not solved against it, so it has
 nothing to put back here. A joint reached by two anchors is snapshotted once, or
 the fixed-order restore would let the second write win.
*>
fn void AppState.snapshot_locks(&self, RigView* view, uint moving_dot)
{
	self.locked_before_count = 0;
	foreach (lock : self.position_locks)
	{
		if (lock.dot_id == moving_dot) continue;
		PoseChain chain = self.pose_chain(view, lock.dot_id);
		// Position bends the limb's ancestor run; rotation turns the joint itself.
		if (lock.position)
		{
			for (usz i = 0; i < chain.count; i++) self.push_locked_before(view.dot_ids[chain.joints[i]]);
		}
		if (lock.rotation) self.push_locked_before(view.dot_ids[chain.effector]);
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
 Snapshot every joint of the draft as the gesture begins — see `gesture_before`.
 Only when a pin is set: without one the gesture's fixed chain snapshot is all a
 plain drag touches.
*>
fn void AppState.snapshot_gesture(&self)
{
	self.drop_gesture_before();
	if (self.position_locks.len == 0) return;
	usz count = (usz)self.doc.dots.len();
	self.gesture_before = alloc::new_array(mem, PosedJoint, (sz)count);
	foreach (usz i, dot : self.doc.dots.array_view()) self.gesture_before[i] = self.working_pose(dot.id);
}

fn void AppState.drop_gesture_before(&self)
{
	if (self.gesture_before.len > 0) alloc::free(mem, self.gesture_before);
	self.gesture_before = {};
	self.body_joints = 0;
	self.body_moves_root = false;
}

<*
 The offset a joint held when the gesture began, out of the snapshot, or zero for
 one that was not snapshotted. What the root slide measures from, so the gesture
 is idempotent and the escape exact — the rule the `slides` branch already keeps.
*>
fn Vec3 AppState.snapshot_offset_of(&self, uint dot_id)
{
	for (usz i = 0; i < self.pose_before_count; i++)
	{
		if (self.pose_before[i].dot_id == dot_id) return self.pose_before[i].offset;
	}
	return {};
}

// Whether anchor a is placed before anchor b: the longer ancestor run first, the
// lower dot id breaking a tie. A strict total order, since dot ids are unique.
fn bool lock_precedes(usz run_a, uint id_a, usz run_b, uint id_b) @local
	=> run_a > run_b || (run_a == run_b && id_a < id_b);

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
 Bend and turn every anchored limb back toward what it is held at, in a fixed
 order, and read back how near each one landed.

 	`app.resolve_position_locks(&view, &pose, app.drag.dot);`

 Run after a gesture has moved the grabbed joint — the root slid, a limb bent, or
 the joint turned. For each anchor other than the one being grabbed:

   position   its ancestor run is solved toward the held point through
              `solve_limited_pose_chain`, so a foot the hips just dropped away
              from is lifted back to the floor by folding the knee.
   rotation   the joint is turned back to the held world orientation through
              `hold_world_rotation`, so a planted foot stays flat as the leg bends.

 Position runs before rotation within an anchor: it moves the joint's parent, the
 frame the orientation hold reads, so holding after placing keeps the foot flat
 wherever the limb put it. The two halves are settled one after the other on
 purpose — a single coupled position-and-orientation solve is not what this is —
 but both are done in the one pass and both misses are reported.

 **The order is fixed and independent of how the anchors were added.** The anchor
 whose limb reaches higher — the longer ancestor run — is placed first, its dot id
 breaking a tie; an anchor whose run then wants a joint one already placed has
 claimed stands down rather than fighting for it, and is marked `yielded`. So a
 foot and a knee pinned on one leg resolve the same way whichever was locked
 first: the foot holds, the knee yields, its residual reports the miss. Feet on
 separate legs share no joint, so nothing is reordered or stood down for the
 ordinary sit — the common case is left exactly as it was.

 **Every anchor's miss is measured from the one settled pose** and left on the lock
 for `lock_position_residual` / `lock_rotation_residual` / `lock_yielded` to read:
 the model-space gap the position half ended from its point, the angle the rotation
 half ended from its orientation. Measured after all the placing, so a later anchor
 that disturbed an earlier one is reported honestly, not by each solve's own gap.

 `report: false` — the pinned solves honor joint limits but leave the collision
 report to the gesture the hand is on. A position anchor whose joint has no
 ancestor run (a root, or a trunk joint) bends nothing: nothing above it can lift
 it into place, and its residual reports the distance.

 Written into `pose`; the caller's `write_pose` puts the results on screen.
*>
fn void AppState.resolve_position_locks(&self, RigView* view, rig::Pose* pose, uint moving_dot)
{
	if (self.position_locks.len == 0) return;

	float height = view.skeleton.height();
	float tolerance = height > 0.0f ? height * IK_TOLERANCE : 0.0f;

	// Gather the anchors to resolve — every one but the grabbed joint, whose own
	// anchor is not solved against it — with each one's run length, then sort so the
	// longest run is placed first. Capped like the snapshot: a rig pinned at more
	// joints than this resolves the first `LOCK_SNAPSHOT` in order.
	usz[LOCK_SNAPSHOT] order;
	usz[LOCK_SNAPSHOT] runs;
	usz picked = 0;
	foreach (usz i, lock : self.position_locks)
	{
		if (lock.dot_id == moving_dot)
		{
			// The grabbed anchor's readout is cleared, so a stale miss does not linger
			// while the user is carrying it on purpose.
			self.position_locks[i].residual = 0.0f;
			self.position_locks[i].turn_residual = 0.0f;
			self.position_locks[i].yielded = false;
			continue;
		}
		if (picked >= LOCK_SNAPSHOT) break;
		order[picked] = i;
		runs[picked] = self.pose_chain(view, lock.dot_id).count;
		picked++;
	}
	for (usz a = 1; a < picked; a++)
	{
		usz save = order[a];
		usz run = runs[a];
		uint id = self.position_locks[save].dot_id;
		usz b = a;
		while (b > 0 && !lock_precedes(runs[b - 1], self.position_locks[order[b - 1]].dot_id, run, id))
		{
			order[b] = order[b - 1];
			runs[b] = runs[b - 1];
			b--;
		}
		order[b] = save;
		runs[b] = run;
	}

	// Place each anchor in that order, standing one down when its run wants a joint
	// a higher-priority anchor has already claimed.
	uint[LOCK_SNAPSHOT] held_joints;
	usz held_count = 0;
	for (usz k = 0; k < picked; k++)
	{
		usz i = order[k];
		PositionLock lock = self.position_locks[i];
		PoseChain chain = self.pose_chain(view, lock.dot_id);
		bool yielded = false;

		if (lock.position && chain.count > 0)
		{
			if (run_wants_claimed(chain, held_joints[:held_count]))
			{
				yielded = true;
			}
			else
			{
				Vec3[IK_MAX_CHAIN + 1] points;
				self.chain_points(view, chain, *pose, {}, points[:chain.count + 1]);
				(void)self.solve_limited_pose_chain(view, chain, pose,
					points[:chain.count + 1], lock.target, tolerance, {}, false);
				for (usz t = 0; t < chain.count; t++)
				{
					held_count = claim_joint(held_joints[..], held_count, (uint)chain.joints[t]);
				}
			}
		}

		if (lock.rotation)
		{
			if (array::contains(held_joints[:held_count], (uint)chain.effector))
			{
				yielded = true;
			}
			else
			{
				self.hold_world_rotation(view, pose, lock.dot_id, lock.orient);
				held_count = claim_joint(held_joints[..], held_count, (uint)chain.effector);
			}
		}

		self.position_locks[i].yielded = yielded;
	}

	// Read back how near each anchor landed, off the one settled pose so a later
	// anchor that moved an earlier one is reported honestly rather than optimistically.
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, *pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? spun = pose.world_rotations(mem, &view.skeleton);
	if (catch spun) return;
	Quaternionf[] world = spun;
	defer alloc::free(mem, world);
	for (usz k = 0; k < picked; k++)
	{
		usz i = order[k];
		PositionLock lock = self.position_locks[i];
		sz j = view.joint_of(lock.dot_id);
		if (j < 0) continue;
		self.position_locks[i].residual = lock.position
			? (view.skeleton.joints[(usz)j].transform(palette[(usz)j]) - lock.target).length()
			: 0.0f;
		self.position_locks[i].turn_residual = lock.rotation
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

	for (uint pass = 0; pass < POSE_IK_PASSES; pass++)
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
			Quaternionf allowed = self.pivot_step(view, chain, pose, points, world, pivot, target, &frame, &limits);
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
		Quaternionf allowed = self.pivot_step(view, chain, pose, points, world, pivot, target, &frame, &limits);
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
	JointRotationLimits* limits)
{
	usz tip = chain.count;
	usz joint = pose_chain_joint(chain, pivot);
	Quaternionf wanted = ik::shortest_arc(
		points[tip] - points[pivot], target - points[pivot], POSE_IK_MAX_STEP);

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
 Carries the grabbed joint toward `target`, turning the run above it.

 	`float gap = app.pose_toward(where_the_pointer_is);`

 This is the only place crig crosses into `collision::ik`: it uses the generic
 shortest-arc step over world-space points, then converts each proposed step
 into the parent-relative rotation `rig::Pose` stores before applying crig's
 bone-local limits.

 **The conversion, and why it needs the parent's world rotation.** A joint's
 world rotation is its parent's composed with its own — see `Pose.world_rotations`
 — so asking the world to turn by `dR` about the joint's position means

     Rw' = dR * Rw   and   Rw = Rw_parent * R

 which rearranges to `R' = Rw_parent^-1 * dR * Rw`. Constraining `R'` may make
 the actual world step smaller or point it elsewhere, so that permitted step is
 what carries the points below it through the rest of the solve.

 Nothing above the run is touched, and nothing below is written: a subtree
 follows its ancestors through `joint_palette` on its own, which is what makes a
 chain worth having.

 @param target : `Where the grabbed joint should end up, in world space.`
 @return `How far it still is from the target — the gap when the target is out of the limb's reach, and zero when nothing was solved.`
*>
fn float AppState.pose_toward(&self, Vec3 target)
{
	if (self.drag.dot == 0 || self.drag.verb != DragVerb.POSE) return 0.0f;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0.0f;
	RigView view = opened;
	defer view.free(mem);

	PoseChain chain = self.pose_chain(&view, self.drag.dot);
	if (chain.count == 0 && !chain.slides && !chain.carries_root) return 0.0f;

	rig::Pose pose = self.gesture_pose(mem, &view);
	defer pose.free(mem);

	// Pinned joints the grab can move: the whole body is solved at once, so the
	// pins pull the hips down and fold the legs rather than being patched after.
	if (self.body_pose(&view, &pose, chain, target, false))
	{
		self.write_body(&view, pose);
		float h = view.skeleton.height();
		return self.body_grab_miss > h * IK_TOLERANCE ? self.body_grab_miss : 0.0f;
	}

	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return 0.0f;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);

	float gap = 0.0f;
	self.last_block = { .fraction = 1.0f };

	if (chain.slides || chain.carries_root)
	{
		// A root has no parent to divide by, so the world delta *is* the local one,
		// and a root translation carries every descendant by it whatever the joints
		// between turn by — which is what lets a grab on a trunk joint move the whole
		// figure by sliding the root under it. `slides` writes the grabbed root
		// itself; `carries_root` writes the root the grabbed trunk joint hangs from.
		// Measured from the grab rather than accumulated per move, which is what
		// makes the gesture idempotent and the escape exact.
		usz slid = chain.carries_root ? chain.root : chain.effector;
		Vec3 was = self.snapshot_offset_of(view.dot_ids[slid]);
		pose.offsets[slid] = was + (target - self.drag.from);
	}
	else
	{
		// Anchor first, effector last — the order the solver reads a chain in, and
		// the reverse of `ancestor_run`'s nearest-first.
		Vec3[IK_MAX_CHAIN + 1] points;
		Vec3 ground_shift = {};
		if (self.pose_edit_active)
		{
			Vec3 authored_effector = view.skeleton.joints[chain.effector].transform(palette[chain.effector]);
			ground_shift = self.dot_position(*self.doc.find(self.drag.dot)) - authored_effector;
		}

		for (usz t = 0; t < chain.count; t++)
		{
			usz j = chain.joints[chain.count - 1 - t];
			points[t] = view.skeleton.joints[j].transform(palette[j]) + ground_shift;
		}
		points[chain.count] = view.skeleton.joints[chain.effector].transform(palette[chain.effector]) + ground_shift;

		float height = view.skeleton.height();
		float tolerance = height > 0.0f ? height * IK_TOLERANCE : 0.0f;
		gap = self.solve_limited_pose_chain(&view, chain, &pose,
			points[:chain.count + 1], target, tolerance, ground_shift);
		// What the target asked for and did not get, whatever stood in the way:
		// the limits, the reach of the limb, or the mesh the report names.
		self.last_block.residual = gap;
		self.last_block.unreached = gap > tolerance;
		self.judge_collision_cost();
	}

	// Anchors the grab cannot move (a pinned hand while a foot is dragged) are
	// still held — rotation halves included.
	self.resolve_position_locks(&view, &pose, self.drag.dot);

	self.write_pose(&view, pose);
	return gap;
}

// The tree root above `joint`. Joints are ordered parents first, so the climb ends.
fn usz tree_root_of(rig::Skeleton* skeleton, usz joint) @local
{
	usz walk = joint;
	while (skeleton.parents[walk] >= 0) walk = (usz)skeleton.parents[walk];
	return walk;
}

<*
 The whole-body solve for a gesture that pinned joints are part of.

 	`if (app.body_pose(&view, &pose, chain, target, false)) app.write_body(&view, pose);`

 What moves:

   the grab   a trunk joint (the root, or one whose run reaches just below the
              root, like `upper_spine` or `chest`) carries its whole path to the
              root *and* the root's slide, so pulling the waist lowers the body;
              a limb joint (a wrist, a knee) turns only its own run, as a plain
              drag does
   each pin   its path up to its root, legs mostly, so a pinned foot folds its
              knee and thigh to stay where it was
   each planted contact   on a clip shown grounded (a ground spec), the feet it has
              down at this moment, unpinned ones included: the ground solve
              would otherwise lift the whole figure — pins with it — to put
              them back on the floor, so they are held too, at `CONTACT_WEIGHT`
              under a pin's. A contact left below the floor by the settled pose
              is then held on it and the solve goes again

 A body held out along the ground (a planted foot further from the hips than
 `SPREAD_BODY` of their height) sits by *pitching*: the root may turn about the
 lateral X axis, the trunk is left rigid (`body_keep_trunk_rigid`), any other
 axis costs `LATERAL_COST` times that, the balance is fore-and-aft only, and the
 joints are drawn back toward the pose the gesture began with once the goals are
 reached. Limbs not on a goal ride their parent, unsolved.

 all in one `body_ik` solve with the pins weighted far over the grab. A turn
 (`turning`) has no grab goal — the turned joint's rotation is already in `pose`
 and is left alone — and solves only the pins, so turning the hips bends the legs
 to keep the feet down. Rotation pins are held afterwards with
 `hold_world_rotation`, which keeps a planted foot flat.

 @return `False when no pin is affected by this gesture — the caller's single-chain path then runs unchanged.`
*>
fn bool AppState.body_pose(&self, RigView* view, rig::Pose* pose, PoseChain chain, Vec3 target, bool turning)
{
	if (self.position_locks.len == 0) return false;
	rig::Skeleton* skeleton = &view.skeleton;
	usz grabbed = chain.effector;
	usz root = tree_root_of(skeleton, grabbed);

	// The grab's own columns.
	bool trunk = grabbed == root || chain.count == 0
		|| skeleton.parents[chain.joints[chain.count - 1]] == (int)root;
	BodyJoint[BODY_IK_MAX_DOF] joints;
	usz joint_count = 0;
	bool moves_root = false;
	if (!turning)
	{
		if (trunk)
		{
			moves_root = true;
			for (int walk = skeleton.parents[grabbed]; walk >= 0 && (usz)walk != root; walk = skeleton.parents[(usz)walk])
			{
				joint_count = self.add_body_joint(view, joints[..], joint_count, (usz)walk, SPINE_STIFFNESS, false);
			}
		}
		else
		{
			for (usz t = 0; t < chain.count; t++)
			{
				joint_count = self.add_body_joint(view, joints[..], joint_count, chain.joints[t], 1.0f, false);
			}
		}
	}
	else
	{
		// Turning the root, or a trunk joint, swings everything hanging from it: the
		// pins then need the root's slide as well as their own legs.
		moves_root = trunk;
	}

	// The pins this gesture can disturb: under a moving root, or below a joint the
	// grab turns — or, for a turn, below the turned joint.
	// A clip with a ground spec is shown grounded — shifted as a whole so its
	// planted feet touch the floor — and the pointer and every pin were read off
	// that shown body. The solve works on the pose before the shift, so they are
	// carried back by it, the same `ground_shift` the single-chain path adds.
	Vec3 shift = {};
	if (self.pose_edit_active)
	{
		Matrix4f[]? drawn = rig::joint_palette(mem, skeleton, *pose);
		if (try palette = drawn)
		{
			shift = self.dot_position(*self.doc.find(view.dot_ids[grabbed]))
				- skeleton.joints[grabbed].transform(palette[grabbed]);
			alloc::free(mem, palette);
		}
	}

	BodyGoal[BODY_IK_MAX_GOALS] goals;
	usz goal_count = 0;
	if (!turning) goals[goal_count++] = { .joint = grabbed, .target = target - shift, .weight = 1.0f };
	float h = skeleton.height();

	// Once per gesture, before anything moves: which pins already miss (set where
	// their limb cannot reach — they report, they do not yank the body toward
	// them), and which sit on another pin's own limb run (a knee pinned under a
	// pinned foot) — those stand down so the foot, the longer run, holds.
	if (!self.drag.body_primed)
	{
		Matrix4f[]? start = rig::joint_palette(mem, skeleton, *pose);
		foreach (usz i, &lock : self.position_locks)
		{
			lock.loose = false;
			lock.yielded = false;
			sz j = view.joint_of(lock.dot_id);
			if (j < 0 || !lock.position) continue;
			if (try palette = start)
			{
				lock.loose = (skeleton.joints[(usz)j].transform(palette[(usz)j]) + shift - lock.target).length() > h * PIN_LOOSE;
			}
			foreach (other : self.position_locks)
			{
				if (other.dot_id == lock.dot_id || !other.position) continue;
				PoseChain run = self.pose_chain(view, other.dot_id);
				if (array::contains(run.joints[:run.count], (usz)j)) lock.yielded = true;
			}
		}
		if (try palette = start) alloc::free(mem, palette);
	}

	bool any_pin = false;
	Vec3 support = {};
	usz supports = 0;
	float root_height = -1.0e30f; // unread: nothing counts as underfoot
	Matrix4f[] start = {};
	Matrix4f[]? now = rig::joint_palette(mem, skeleton, *pose);
	if (try palette = now)
	{
		start = palette;
		root_height = skeleton.joints[root].transform(palette[root]).y;
	}
	defer if (start.len > 0) alloc::free(mem, start);
	foreach (lock : self.position_locks)
	{
		if (!lock.position || lock.dot_id == self.drag.dot || goal_count >= BODY_IK_MAX_GOALS) continue;
		if (lock.loose || lock.yielded) continue;
		sz found = view.joint_of(lock.dot_id);
		if (found < 0) continue;
		usz pinned = (usz)found;
		if (!self.gesture_moves(skeleton, root, grabbed, pinned, moves_root, turning, joints[:joint_count])) continue;
		any_pin = true;
		self.add_body_pin(view, joints[..], &joint_count, goals[..], &goal_count, pinned, lock.target - shift,
			PIN_WEIGHT, root_height, &support, &supports, grabbed, turning);
	}
	if (!any_pin) return false;

	// A grounded clip is shown with the ground solve applied, and that solve moves
	// the *whole* figure to put the lowest foot on the floor — pins and all. So a
	// gesture that sinks a planted foot it was not told about (the front paws as
	// the hips drop) gets the body lifted back off its pins the moment it is
	// shown, which is the "pins not respected, hips went up" failure. The planted
	// contacts therefore stand as pins of their own for the gesture, where they
	// are now, and what the solve then leaves below the floor is held on it below.
	usz first_pin = turning ? 0 : 1; // past the grab's own goal
	usz[GROUND_CONTACT_MAX] contact;
	bool[GROUND_CONTACT_MAX] planted;
	GroundContacts floor_spec = self.gesture_contacts(view, contact[..], planted[..]);
	for (usz i = 0; i < floor_spec.count && start.len > 0; i++)
	{
		usz foot = contact[i];
		if (!planted[i] || goal_count >= BODY_IK_MAX_GOALS || foot == grabbed) continue;
		if (body_goal_index(goals[:goal_count], foot) >= 0) continue;
		// A toe under a pinned ankle rides on it: the pin, and its angle if held,
		// already say where the toe is, and a second pin there would only fight them.
		if (body_rides_a_pin(skeleton, goals[first_pin:goal_count - first_pin], foot)) continue;
		if (!self.gesture_moves(skeleton, root, grabbed, foot, moves_root, turning, joints[:joint_count])) continue;
		self.add_body_pin(view, joints[..], &joint_count, goals[..], &goal_count, foot,
			skeleton.joints[foot].transform(start[foot]), CONTACT_WEIGHT, root_height, &support, &supports,
			grabbed, turning);
	}

	// A straight limb has no way to fold: start its one-sided joints a little bent,
	// once, when the gesture begins.
	if (!self.drag.body_primed)
	{
		self.drag.body_primed = true;
		body_unfold(skeleton, pose, joints[:joint_count]);
	}

	// Standing on pinned feet and pulled by the trunk, the body keeps its weight
	// over them: the hips going back lean the chest forward.
	BodyIkSettings settings = {
		.root = root,
		.moves_root = moves_root,
		.root_stiffness = turning ? TURN_ROOT_STIFFNESS : 1.0f,
		.height = h,
		.balance = !self.balance_off && !turning && trunk && supports > 0,
		.support = supports > 0 ? support / (float)supports : (Vec3){},
		.tilt_stiffness = BALANCE_TILT_STIFFNESS,
		.tilt_from = pose.rotations[root],
	};
	foreach (held : self.gesture_before)
	{
		if (held.dot_id == view.dot_ids[root]) settings.tilt_from = held.rotation;
	}
	// A body held out along the ground — a dog's, whose feet are further from the
	// hips than the hips are high — sits by *pitching*: the rear goes down and the
	// chest stays up. Left to a minimum-effort solve it reaches a planted front paw
	// by bending the spine sideways instead. So the root may turn for the goals,
	// and a turn about the model's lateral axis (X, it faces +Z) is what folding
	// costs; any other axis costs `LATERAL_COST` times that, which also keeps a
	// symmetric pull symmetric.
	if (!turning && trunk && start.len > 0)
	{
		Vec3 hips = skeleton.joints[root].transform(start[root]);
		for (usz g = first_pin; g < goal_count; g++)
		{
			Vec3 away = goals[g].target - hips;
			away.y = 0.0f;
			if (away.length() > root_height * SPREAD_BODY) settings.pitch = true;
		}
		if (settings.pitch)
		{
			settings.flex_axis = { 1, 0, 0 };
			settings.lateral_cost = LATERAL_COST;
			body_keep_trunk_rigid(skeleton, joints[..], &joint_count, goals[first_pin:goal_count - first_pin]);
		}
	}
	// Where every joint stood when the gesture began, for the solve to keep the body
	// near — see `BodyIkSettings.posture`. Only for a body that pitches, where the
	// spine's spare freedom is large.
	Quaternionf[] began = {};
	if (settings.pitch && self.gesture_before.len > 0)
	{
		began = alloc::new_array(tmem, Quaternionf, (sz)skeleton.len());
		foreach (usz j, id : view.dot_ids)
		{
			began[j] = pose.rotations[j];
			foreach (held : self.gesture_before) if (held.dot_id == id) began[j] = held.rotation;
		}
		settings.posture = began;
		settings.posture_pull = POSTURE_PULL;
	}
	rig::Pose before = pose.copy(mem);
	defer before.free(mem);
	for (usz round = 0;; round++)
	{
		if (round > 0)
		{
			pose.rotations[..] = before.rotations[..];
			pose.offsets[..] = before.offsets[..];
			body_unfold(skeleton, pose, joints[:joint_count]);
		}
		body_ik(skeleton, pose, joints[:joint_count], goals[:goal_count], &settings);

		// Rotation pins, after every position is placed: the frame they read is final.
		foreach (usz i, lock : self.position_locks)
		{
			if (!lock.rotation || lock.dot_id == self.drag.dot) continue;
			self.hold_world_rotation(view, pose, lock.dot_id, lock.orient);
		}

		// What the settled body leaves below the floor is held on it, and the solve
		// goes again from the same start — a foot held up may bring another down,
		// so twice. Read after the angles are held, which is how it will be shown.
		if (round >= 2 || floor_spec.count == 0) break;
		Matrix4f[]? settled = rig::joint_palette(mem, skeleton, *pose);
		if (catch settled) break;
		bool sunk = false;
		foreach (usz i, foot : contact[:floor_spec.count])
		{
			if (goal_count >= BODY_IK_MAX_GOALS || foot == grabbed) continue;
			if (body_goal_index(goals[:goal_count], foot) >= 0) continue;
			if (body_rides_a_pin(skeleton, goals[first_pin:goal_count - first_pin], foot)) continue;
			Vec3 at = skeleton.joints[foot].transform(settled[foot]);
			if (at.y + shift.y >= floor_spec.floor - h * BODY_IK_TOLERANCE) continue;
			sunk = true;
			self.add_body_pin(view, joints[..], &joint_count, goals[..], &goal_count, foot,
				{ at.x, floor_spec.floor - shift.y, at.z }, CONTACT_WEIGHT, root_height, &support, &supports,
				grabbed, turning);
		}
		alloc::free(mem, settled);
		if (!sunk) break;
		if (settings.pitch) body_keep_trunk_rigid(skeleton, joints[..], &joint_count, goals[first_pin:goal_count - first_pin]);
	}
	self.body_grab_miss = turning ? 0.0f : goals[0].residual;
	self.body_joints = joint_count;
	for (usz i = 0; i < joint_count; i++) self.body_joint_ids[i] = view.dot_ids[joints[i].joint];
	self.body_root = view.dot_ids[root];
	// The lean turns the root as well as sliding it: written back the same way.
	self.body_moves_root = moves_root || settings.balance || settings.pitch;

	// The readouts: each pin's miss off the settled pose *as it will be shown*. A
	// grounded clip is shown after the ground solve has lifted or dropped it whole,
	// and a foot that could not stay flat is exactly what makes that solve move the
	// pins — so the honest miss is measured against what is on screen, not against
	// the frame the solve worked in.
	rig::Pose shown = pose.copy(mem);
	defer shown.free(mem);
	Vec3 shown_shift = shift;
	if (floor_spec.count > 0)
	{
		AnimTemplate* clip = self.clip(self.editing);
		ground_pose(mem, skeleton, self.names_for(view, self.editing), clip.ground, &shown, clip.phase_at(self.edit_time));
		shown_shift = shown.offsets[root] - pose.offsets[root];
	}
	Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
	if (catch built) return true;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? spun = pose.world_rotations(mem, skeleton);
	if (catch spun) return true;
	Quaternionf[] world = spun;
	defer alloc::free(mem, world);
	foreach (usz i, lock : self.position_locks)
	{
		sz j = view.joint_of(lock.dot_id);
		if (j < 0 || lock.dot_id == self.drag.dot) continue;
		self.position_locks[i].residual = lock.position
			? (skeleton.joints[(usz)j].transform(palette[(usz)j]) + shown_shift - lock.target).length() : 0.0f;
		self.position_locks[i].turn_residual = lock.rotation
			? rotation_angle_between(world[(usz)j], lock.orient) : 0.0f;
	}

	// Said once the pins, not the pointer, are deciding where the body stops.
	if (!turning && self.body_grab_miss > h * 0.02f)
	{
		self.@notice("the pinned joints hold the body here · unlock one to pull further");
	}
	return true;
}

// Add a joint to the solve once, with its limits and frame. @return the new count.
fn usz AppState.add_body_joint(&self, RigView* view, BodyJoint[] joints, usz count, usz joint, float stiffness,
	bool bend_hint, usz child = ~(usz)0)
{
	for (usz i = 0; i < count; i++)
	{
		if (joints[i].joint != joint) continue;
		// On both a pin's path and the grab's: the cheaper, and a leg's bend hint.
		joints[i].stiffness = math::min(joints[i].stiffness, stiffness);
		if (bend_hint && !joints[i].bend_hint) joints[i].child = child;
		joints[i].bend_hint = joints[i].bend_hint || bend_hint;
		return count;
	}
	if (count >= joints.len) return count;
	JointRotationLimits limits = self.doc.rotation_limits_of(view.dot_ids[joint]);
	joints[count] = {
		.joint = joint,
		.limits = limits,
		.frame = limits.constrained ? joint_limit_frame(&view.skeleton, view.dot_ids, limits) : (JointLimitFrame){},
		.stiffness = stiffness,
		.bend_hint = bend_hint,
		.child = child,
	};
	return count + 1;
}

<*
 Takes the trunk out of a pitching body's solve: every joint on a path to a goal
 that is not one of the goal's own limb (its unbranched run — a leg, a foreleg).

 The body sits by the root turning and the limbs folding, not by curling the spine
 into a question mark: left in, the solve finds it cheaper to bend the back two
 radians than to turn the pelvis, since turning the pelvis also moves the pinned
 hind legs. A joint left out keeps the rotation it has and its subtree rides it.
*>
fn void body_keep_trunk_rigid(rig::Skeleton* skeleton, BodyJoint[] joints, usz* count, BodyGoal[] goals) @local
{
	usz kept = 0;
	for (usz i = 0; i < *count; i++)
	{
		bool limb = false;
		foreach (goal : goals)
		{
			usz[IK_MAX_CHAIN] run;
			usz n = skeleton.ancestor_run(goal.joint, run[..]);
			if (array::contains(run[:n], joints[i].joint)) { limb = true; break; }
		}
		if (limb) joints[kept++] = joints[i];
	}
	*count = kept;
}

// Whether `joint` hangs below one of these pinned joints, and so rides on it.
fn bool body_rides_a_pin(rig::Skeleton* skeleton, BodyGoal[] pins, usz joint) @local
{
	foreach (pin : pins) if (body_above(skeleton, pin.joint, joint)) return true;
	return false;
}

// Which goal holds `joint`, or -1.
fn sz body_goal_index(BodyGoal[] goals, usz joint) @local
{
	foreach (usz g, goal : goals) if (goal.joint == joint) return (sz)g;
	return -1;
}

<*
 Whether this gesture can carry `pinned` off where it stands: the root it hangs
 from slides, a joint the grab turns is above it, or — for a turn — it is at or
 below the turned joint.
*>
fn bool AppState.gesture_moves(&self, rig::Skeleton* skeleton, usz root, usz grabbed, usz pinned,
	bool moves_root, bool turning, BodyJoint[] joints)
{
	bool moved = (moves_root && tree_root_of(skeleton, pinned) == root)
		|| (turning && (pinned == grabbed || body_above(skeleton, grabbed, pinned)));
	for (usz i = 0; i < joints.len && !moved; i++)
	{
		moved = body_above(skeleton, joints[i].joint, pinned);
	}
	return moved;
}

<*
 Adds one position goal to a whole-body solve, with the joints between it and its
 root as columns. `target` is in the solve's own frame (before any ground shift).
*>
fn void AppState.add_body_pin(&self, RigView* view, BodyJoint[] joints, usz* joint_count, BodyGoal[] goals,
	usz* goal_count, usz pinned, Vec3 target, float weight, float root_height, Vec3* support, usz* supports,
	usz grabbed, bool turning)
{
	rig::Skeleton* skeleton = &view.skeleton;
	goals[*goal_count] = { .joint = pinned, .target = target, .weight = weight };
	// A pin below the root is something the body stands on.
	if (target.y < root_height)
	{
		*support = *support + target;
		(*supports)++;
		goals[*goal_count].stands = true;
	}
	(*goal_count)++;
	usz pin_root = tree_root_of(skeleton, pinned);
	usz below = pinned;
	for (int walk = skeleton.parents[pinned]; walk >= 0 && (usz)walk != pin_root; walk = skeleton.parents[(usz)walk])
	{
		// The turned joint's own rotation is the gesture; it is not re-solved.
		if (turning && (usz)walk == grabbed) break;
		*joint_count = self.add_body_joint(view, joints, *joint_count, (usz)walk, 1.0f, true, below);
		below = (usz)walk;
	}
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
 Writes a whole-body solve back: every joint it turned, the root's slide, the
 rotation pins, and the grabbed joint — then puts it on screen the way
 `write_pose` does.
*>
fn void AppState.write_body(&self, RigView* view, rig::Pose pose)
{
	self.unaim_pose(&pose);
	for (usz i = 0; i < self.body_joints; i++)
	{
		sz j = view.joint_of(self.body_joint_ids[i]);
		if (j >= 0) self.set_working_pose(self.body_joint_ids[i], pose.rotations[(usz)j], pose.offsets[(usz)j]);
	}
	if (self.body_moves_root)
	{
		sz j = view.joint_of(self.body_root);
		if (j >= 0) self.set_working_pose(self.body_root, pose.rotations[(usz)j], pose.offsets[(usz)j]);
	}
	foreach (lock : self.position_locks)
	{
		if (!lock.rotation) continue;
		sz j = view.joint_of(lock.dot_id);
		if (j >= 0) self.set_working_pose(lock.dot_id, pose.rotations[(usz)j], pose.offsets[(usz)j]);
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

	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	// The parent's world rotation is unaffected by this joint's own, so reading
	// it from the current pose is safe even though the current pose already holds
	// part of this gesture.
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
	// Turning the hips or the spine drops the feet as surely as pulling them does,
	// so the pins are honored here too: the legs bend to keep them.
	PoseChain turned = { .effector = joint };
	if (self.body_pose(view, pose, turned, {}, true))
	{
		self.write_body(view, *pose);
		return;
	}
	self.resolve_position_locks(view, pose, self.drag.dot);
	self.write_pose(view, *pose);
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

	// The anchored limbs the re-solve bent, written by the same rule: a pin turns
	// its knee and thigh, and those are the joints `snapshot_locks` recorded.
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

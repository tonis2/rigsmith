<*
 The reusable, joint-indexed form of crig's anatomical rotation constraints.

 `RigDocument` remains the editable source of truth and keys limits by dot id,
 because dot ids survive topology edits and joint indices do not. A body-plan
 pack and a glTF physics graph speak in the joint order of one built skeleton,
 so this type is the deliberate crossing between those two representations.

 This is not secondary motion. `RigPhysics` describes dynamic jiggle bones and
 their colliders; `ConstraintRig` describes the stateless ranges that FK, IK,
 playback and physical-rig export must all obey. Keeping them apart prevents a
 locked knee from accidentally becoming a simulated bone merely because both
 can eventually be written through `KHR_physics_rigid_bodies`.
*>
module crig;

import rig;
import gltf;
import std::math::vector;
import std::math::quaternion;

<*
 Whether one joint's source constraint can be reproduced by crig.

 A dense row exists for every joint. `FREE` is therefore meaningful rather
 than represented by a missing row, `EXACT` carries the independent X/Y/Z
 table, and `UNSUPPORTED` records authored intent that must be reported rather
 than silently dropped or guessed. The first unsupported cases come from an
 anatomical frame that cannot be rebuilt; the KHR reader will add foreign
 cones, drives and attachment graphs to the same category.
*>
enum JointConstraintStatus
{
	FREE,
	EXACT,
	UNSUPPORTED,
}

<*
 How a reusable bone-aligned frame is reconstructed on another skeleton.

 `ADJUSTED_*` means an authored frame was present. Its quaternion is stored as
 an adjustment from the source's derived bone frame, not as an absolute source
 model-space rotation, so P4 can apply the same roll/frame intent to a target
 with different proportions.
*>
enum ConstraintFrameIntent
{
	AUTOMATIC,
	PRIMARY_CHILD,
	ADJUSTED_AUTOMATIC,
	ADJUSTED_PRIMARY_CHILD,
}

fn bool ConstraintFrameIntent.uses_primary_child(self)
{
	return self == PRIMARY_CHILD || self == ADJUSTED_PRIMARY_CHILD;
}

fn bool ConstraintFrameIntent.has_adjustment(self)
{
	return self == ADJUSTED_AUTOMATIC || self == ADJUSTED_PRIMARY_CHILD;
}

<*
 One dense row of a `ConstraintRig`.

 `primary_child` is a joint index and is `-1` for automatic frame selection.
 `frame_adjustment` is identity unless `frame_intent.has_adjustment()`. The
 three axes have exactly the same radians and allow/lock meaning as the
 document's `JointRotationLimits`.

 `frame_status` explains a crig-authored `UNSUPPORTED` row. It is `READY` for
 free and exact rows. Foreign KHR graphs live in `ConstraintRig.foreign` because
 their cone/drive/attachment diagnostics are not frame-status values.
*>
struct JointConstraint
{
	JointConstraintStatus status;
	JointAxisLimit[3] axes;
	ConstraintFrameIntent frame_intent;
	int primary_child;
	Quaternionf frame_adjustment;
	JointLimitFrameStatus frame_status;
}

<*
 A KHR joint graph whose meaning cannot be projected into crig's independent
 X/Y/Z table without changing it.

 The two endpoint transforms are stored in model space, relative only to the
 source skeleton indices named here. This is enough to reproduce the graph when
 the same pack is saved again, while deliberately not pretending the graph is a
 transferable anatomical limit. P4 copies exact `joints` rows to a fitted rig;
 it reports and leaves these foreign rows behind.

 Limits and drives are owned arrays copied out of the glTF stream. The issue
 flags are diagnostics rather than a lossy choice of one "main" reason: a
 foreign joint may contain both a cone and a drive.
*>
struct ForeignConstraint
{
	usz attachment_joint;
	usz connected_joint;
	Vec3 attachment_position;
	Quaternionf attachment_rotation;
	Vec3 connected_position;
	Quaternionf connected_rotation;
	gltf::Limit[] angular_limits;
	gltf::Limit[] linear_limits;
	gltf::Drive[] drives;
	bool enable_collision;
	bool cone;
	bool driven;
	bool graph;
	bool limit_layout;
}

fn void ForeignConstraint.free(&self, Allocator allocator)
{
	if (self.angular_limits.len > 0) alloc::free(allocator, self.angular_limits);
	if (self.linear_limits.len > 0) alloc::free(allocator, self.linear_limits);
	if (self.drives.len > 0) alloc::free(allocator, self.drives);
	*self = {};
}

<*
 A reusable constraint table in one skeleton's joint order.

 `joints` is owned and always dense when produced by `constraint_rig_of`.
 `foreign` owns KHR graphs retained for same-pack pass-through but not template
 application.
 `skipped` counts information that cannot resolve into this skeleton: active
 stale dot-keyed rows on the editor boundary, or KHR graphs whose endpoints do
 not map to its bones on the file boundary. Neither is guessed onto a different
 joint.
*>
struct ConstraintRig
{
	JointConstraint[] joints;
	ForeignConstraint[] foreign;
	usz skipped;
}

<*
 What happened when reusable constraints were fitted onto another rig.

 The categories stay separate so tests and later UI can distinguish absent
 vocabulary from an unusable frame. The normal preset notice intentionally
 presents their sum: a simple workflow needs one actionable "skipped" count,
 while this report retains the diagnostic detail behind it.
*>
struct ConstraintApplyReport
{
	usz applied;
	usz missing_joint;
	usz missing_primary_child;
	usz invalid_frame;
	usz unsupported;
}

fn usz ConstraintApplyReport.skipped(self) => self.missing_joint
	+ self.missing_primary_child + self.invalid_frame + self.unsupported;

fn bool ConstraintApplyReport.present(self) => self.applied > 0 || self.skipped() > 0;

fn bool ConstraintRig.present(&self)
{
	foreach (joint : self.joints) if (joint.status != FREE) return true;
	return self.foreign.len > 0;
}

<*
 Whether this table contains a limit crig can evaluate on an animation pose.

 `present` is intentionally broader: unsupported and foreign KHR rows still
 need to survive a pack save and appear in diagnostics. They cannot be baked
 into ordinary glTF animation channels, however, so they must not make export
 densify a clip it cannot actually change.
*>
fn bool ConstraintRig.constrains_pose(&self)
{
	foreach (joint : self.joints) if (joint.status == EXACT) return true;
	return false;
}

fn usz ConstraintRig.unsupported(&self)
{
	usz count = self.skipped + self.foreign.len;
	foreach (joint : self.joints) if (joint.status == UNSUPPORTED) count++;
	return count;
}

fn void ConstraintRig.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	foreach (&foreign : self.foreign) foreign.free(allocator);
	if (self.foreign.len > 0) alloc::free(allocator, self.foreign);
	*self = {};
}

<*
 Apply a reusable, joint-indexed constraint table to a temporary pose.

 This is the file-boundary counterpart of `constrain_pose_to_joint_limits`.
 The editor version resolves dot ids and saved document frames; this version
 rebuilds the same anatomical frame from the portable intent held by a
 `ConstraintRig`. It is consequently suitable for game export and model
 reskinning, where the editable document must not leak into the animation
 writer.

 Unsupported and foreign KHR constraints are deliberately left alone: crig
 has promised to retain those graphs, not to guess their motion. Exact rows
 whose target topology no longer yields their requested frame are likewise
 skipped rather than evaluated in a different axis system.

 @param pose : `A sampled pose, changed in place. Offsets are preserved.`
*>
fn void constrain_pose_to_constraint_rig(
	rig::Skeleton* skeleton,
	ConstraintRig constraints,
	rig::Pose* pose)
{
	usz count = skeleton.len();
	if (constraints.joints.len < count) count = constraints.joints.len;
	if (pose.rotations.len < count) count = pose.rotations.len;

	for (usz joint = 0; joint < count; joint++)
	{
		pose.rotations[joint] = constrain_joint_to_constraint_rig(skeleton, constraints, joint,
			pose.rotations[joint]);
	}
}

<*
 One joint of `constrain_pose_to_constraint_rig`: its local rotation handed back
 inside the carried limits, or unchanged when the joint is free, unsupported, or
 has no frame to read them in.
*>
fn Quaternionf constrain_joint_to_constraint_rig(
	rig::Skeleton* skeleton,
	ConstraintRig constraints,
	usz joint,
	Quaternionf rotation)
{
	if (joint >= constraints.joints.len || joint >= skeleton.len()) return rotation;
	JointConstraint carried = constraints.joints[joint];
	if (carried.status != EXACT) return rotation;

	int primary = carried.frame_intent.uses_primary_child()
		? carried.primary_child
		: -1;
	JointLimitFrame frame = joint_limit_frame_by_index(skeleton, joint, primary);
	if (!frame.usable()) return rotation;
	if (carried.frame_intent.has_adjustment())
	{
		frame.rotation = frame.rotation.mul(carried.frame_adjustment).normalize();
	}

	JointRotationLimits limits = {
		.constrained = true,
		.axes = carried.axes,
	};
	return constrain_joint_rotation(frame, limits, rotation);
}

<*
 What `constraint_rig_aim_clamp` reads: the skeleton and the carried table.
*>
struct ConstraintAimContext
{
	rig::Skeleton* skeleton;
	ConstraintRig* constraints;
}

<*
 The export-side `AimClamp`: holds a joint inside the portable constraint table,
 the same limits `constrain_pose_to_constraint_rig` applies, over a
 `ConstraintAimContext`.
*>
fn Quaternionf constraint_rig_aim_clamp(void* ctx, usz joint, Quaternionf local)
{
	ConstraintAimContext* held = (ConstraintAimContext*)ctx;
	return constrain_joint_to_constraint_rig(held.skeleton, *held.constraints, joint, local);
}

fn int constraint_joint_of(uint[] dot_ids, usz joints, uint dot_id) @private
{
	if (dot_id == 0) return -1;
	return (int)(array::index_of(dot_ids[:(dot_ids.len < joints ? dot_ids.len : joints)], dot_id) ?? -1);
}

fn JointConstraint free_joint_constraint() @private
{
	JointRotationLimits defaults = unconstrained_rotation(0);
	return {
		.status = FREE,
		.axes = defaults.axes,
		.primary_child = -1,
		.frame_adjustment = quaternion::IDENTITY,
		.frame_status = READY,
	};
}

<*
 Resolve a document's dot-keyed anatomical limits into one owned dense table.

 Only active constraints cross this boundary. Inactive rows deliberately stay
 editor-side: they are parked UI values, not a claim that a template should
 constrain another rig. A saved frame crosses as `derived^-1 * saved`, which
 exactly reconstructs the source frame as `derived * adjustment` and remains
 meaningful when P4 derives a different target frame.

 A fork with no primary child crosses naming the child its frame followed
 here, so a target of another shape follows the same bone rather than
 whichever child its own geometry would pick.

 The returned value owns `joints`; release it with `ConstraintRig.free`.

 @param dot_ids : `The dot each joint was built from — RigView.dot_ids.`
*>
fn ConstraintRig constraint_rig_of(
	Allocator allocator,
	RigDocument* doc,
	rig::Skeleton* skeleton,
	uint[] dot_ids)
{
	ConstraintRig out = {};
	usz joints = skeleton.len();
	if (joints == 0) return out;

	out.joints = alloc::new_array(allocator, JointConstraint, (sz)joints);
	foreach (&joint : out.joints) *joint = free_joint_constraint();

	usz mapped = dot_ids.len < joints ? dot_ids.len : joints;
	for (usz joint = 0; joint < mapped; joint++)
	{
		uint dot_id = dot_ids[joint];
		if (dot_id == 0) continue;

		JointRotationLimits limits = doc.rotation_limits_of(dot_id);
		if (!limits.constrained) continue;

		JointConstraint* carried = &out.joints[joint];
		carried.status = EXACT;
		carried.axes = limits.axes;

		// Rebuild the transferable base even when the document has an explicit
		// frame: the explicit value itself is source-space and must never be the
		// value copied onto another model.
		JointRotationLimits base_limits = limits;
		base_limits.has_saved_frame = false;
		base_limits.saved_frame = quaternion::IDENTITY;
		JointLimitFrame base = joint_limit_frame(skeleton, dot_ids, base_limits);

		uint child = limits.primary_child;
		if (child == 0 && base.usable() && limit_frame_forks(skeleton, joint)) child = base.direction_dot;
		carried.primary_child = constraint_joint_of(dot_ids, joints, child);
		bool explicit_child = child != 0;
		carried.frame_intent = limits.has_saved_frame
			? (explicit_child ? ADJUSTED_PRIMARY_CHILD : ADJUSTED_AUTOMATIC)
			: (explicit_child ? PRIMARY_CHILD : AUTOMATIC);
		if (!base.usable())
		{
			carried.status = UNSUPPORTED;
			carried.frame_status = base.status;
			continue;
		}

		if (limits.has_saved_frame)
		{
			carried.frame_adjustment = base.rotation.invert()
				.mul(limits.saved_frame.normalize()).normalize();
		}
	}

	// Active stale entries remain in the editor for undo, but cannot enter a
	// joint-indexed artifact. Count them so a save/export surface can say so.
	foreach (limits : doc.rotation_limits.array_view())
	{
		if (!limits.constrained) continue;
		if (constraint_joint_of(dot_ids, joints, limits.dot_id) < 0) out.skipped++;
	}

	return out;
}

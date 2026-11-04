<*
 One clip's pose at one moment, through every stage in the one order: sample,
 limits, ground, pins, aims. Neither pins nor aims feed back into a limit or the
 floor, and a head looks from where the body is held. See rules/posing.md.
*>
module crig;

import rig;
import std::math;

struct PoseStages
{
	rig::Skeleton* skeleton;
	String[] names;

	// The limits, as the viewport holds them or as export writes them. With neither
	// a pose is free.
	RigDocument* limits;
	uint[] dot_ids;
	ConstraintRig* constraints;

	bool ignore_solo; // export plays every layer

	// What an open edit changes. A grabbed joint's own pin stands aside for the drag,
	// and a target being dragged stands in for the clip's.
	String pin_skipped;
	AnimAimTarget[] aim_targets;
	bool targets_staged;
}

// The document's joint limits as an `AimClamp`.
struct DocClamp
{
	RigDocument* limits;
	rig::Skeleton* skeleton;
	uint[] dot_ids;
}

fn Quaternionf doc_clamp(void* ctx, usz joint, Quaternionf local)
{
	DocClamp* held = (DocClamp*)ctx;
	if (joint >= held.dot_ids.len) return local;
	JointRotationLimits limits = held.limits.rotation_limits_of(held.dot_ids[joint]);
	if (!limits.constrained) return local;
	JointLimitFrame frame = joint_limit_frame(held.skeleton, held.dot_ids, limits);
	if (!frame.usable()) return local;
	return constrain_joint_rotation(frame, limits, local);
}

fn bool PoseStages.has_table(&self) => self.constraints && self.constraints.constrains_pose();

fn rig::Pose PoseStages.sample(&self, Allocator allocator, AnimTemplate clip, float time)
{
	return clip.pose(allocator, self.skeleton, self.names, time, false, honor_solo: !self.ignore_solo);
}

fn void PoseStages.limit(&self, rig::Pose* pose)
{
	if (self.has_table())
	{
		constrain_pose_to_constraint_rig(self.skeleton, *self.constraints, pose);
	}
	else if (self.limits)
	{
		constrain_pose_to_joint_limits(self.limits, self.skeleton, self.dot_ids, pose);
	}
}

fn void PoseStages.ground(&self, Allocator allocator, AnimTemplate clip, float time, rig::Pose* pose, AnimGround* floor = null)
{
	ground_pose(allocator, self.skeleton, self.names, floor ? *floor : clip.ground, pose, clip.phase_at(time));
}

fn void PoseStages.pins(&self, Allocator allocator, AnimTemplate clip, float time, rig::Pose* pose, float gain = 1.0f)
{
	if (!clip.plays_holds()) return;
	AnimPin[] pins = clip_live_pins(tmem, &clip, time);
	if (self.pin_skipped.len > 0)
	{
		AnimPin[] kept = alloc::new_array(tmem, AnimPin, (sz)pins.len);
		usz count;
		foreach (pin : pins) if (pin.joint != self.pin_skipped) kept[count++] = pin;
		pins = kept[:count];
	}
	DocClamp held = { .limits = self.limits, .skeleton = self.skeleton, .dot_ids = self.dot_ids };
	ConstraintRig table = self.constraints ? *self.constraints : (ConstraintRig){};
	ConstraintAimContext exact = { .skeleton = self.skeleton, .constraints = &table };
	if (self.has_table())
	{
		pin_pose(allocator, self.skeleton, self.names, pins, time, clip.duration, clip.loop, pose,
			self.skeleton.height(), &constraint_rig_aim_clamp, &exact, gain);
		return;
	}
	pin_pose(allocator, self.skeleton, self.names, pins, time, clip.duration, clip.loop, pose,
		self.skeleton.height(), self.limits ? &doc_clamp : null, &held, gain);
}

fn void PoseStages.aims(&self, Allocator allocator, AnimTemplate clip, float time, rig::Pose* pose,
	AimAppliedSet* applied = null, float gain = 1.0f)
{
	if (clip.aims.len == 0) return;
	AnimAimTarget[] targets = self.targets_staged ? self.aim_targets : clip.aim_targets;
	DocClamp held = { .limits = self.limits, .skeleton = self.skeleton, .dot_ids = self.dot_ids };
	ConstraintRig table = self.constraints ? *self.constraints : (ConstraintRig){};
	ConstraintAimContext exact = { .skeleton = self.skeleton, .constraints = &table };
	if (self.has_table())
	{
		aim_pose(allocator, self.skeleton, self.names, clip.aims, targets, time, clip.duration, clip.loop, pose,
			self.skeleton.height(), &constraint_rig_aim_clamp, &exact, applied, gain);
		return;
	}
	aim_pose(allocator, self.skeleton, self.names, clip.aims, targets, time, clip.duration, clip.loop, pose,
		self.skeleton.height(), self.limits ? &doc_clamp : null, &held, applied, gain);
}

<*
 The clip at `time`, through every stage. The caller owns the pose.

 @param grounded : `Run the ground solve.`
 @param held : `Run the pins and the aims.`
*>
fn rig::Pose PoseStages.pose(&self, Allocator allocator, AnimTemplate clip, float time, bool grounded = true, bool held = true)
{
	rig::Pose pose = self.sample(allocator, clip, time);
	self.finish(allocator, clip, time, &pose, grounded, held);
	return pose;
}

// Every stage after the sample, for a pose sampled or blended elsewhere.
fn void PoseStages.finish(&self, Allocator allocator, AnimTemplate clip, float time, rig::Pose* pose, bool grounded = true, bool held = true)
{
	self.limit(pose);
	if (grounded) self.ground(allocator, clip, time, pose);
	if (!held) return;
	self.pins(allocator, clip, time, pose);
	self.aims(allocator, clip, time, pose);
}

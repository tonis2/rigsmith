<*
 The joint shown at a limit while a dial's knob is dragged: the pose on show with
 one joint turned, put in the palette and keyed nowhere.
*>
module crig;

import rig;
import std::math;

<*
 Show joint `id` turned to `angle` about `axis`, the rest of the pose as shown.

 @return "False while a clip plays or the joint has no usable frame"
*>
fn bool AppState.show_limit_preview(&self, uint id, JointRotationAxis axis, float angle)
{
	// The running player rewrites the palette every frame.
	if (self.animating && !self.anim_paused && !self.pose_edit_active) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	sz joint = view.joint_of(id);
	if (joint < 0) return false;
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, self.doc.rotation_limits_of(id));
	if (!frame.usable()) return false;

	rig::Pose pose;
	if (self.pose_edit_active)
	{
		pose = self.draft_pose(mem, &view);
	}
	else if (self.animating)
	{
		pose = self.sampled_pose(mem, &view);
	}
	else
	{
		pose = rig::rest_pose(mem, view.len());
	}
	defer pose.free(mem);

	Vec3 angles = joint_angles_from_rotation(frame, pose.rotations[(usz)joint]);
	angles[axis.component()] = angle;
	pose.rotations[(usz)joint] = rotation_from_joint_angles(frame, angles);

	(void)self.rebind_skin(&view);
	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette) return false;
	self.drop_palette();
	self.pose_palette = palette;
	self.posed_dots = posed_overlay(mem, &view.skeleton, view.dot_ids, palette);
	self.path_height = view.skeleton.height();
	self.next_pose_generation();
	return true;
}

// Put back whatever the preview covered.
fn void AppState.end_limit_preview(&self)
{
	if (self.pose_edit_active || self.animating)
	{
		self.refresh_pose_display();
		return;
	}
	self.drop_palette();
}

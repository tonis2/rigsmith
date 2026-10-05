<*
 The pose library: named poses kept with the project, applied to the whole
 figure or to the selected joints, as they are or mirrored.

 	`app.save_named_pose("Contact");`
 	`app.apply_saved_pose(0, mirrored: true, selected_only: false);`

 A pose is read the way Copy pose reads one (`pose_in_hand`: the selected
 joints, or all of them) and kept in rig joint names in `RigDocument.poses`,
 so it applies in any clip and on another character named the same way.
 Saving, renaming and deleting replace the list whole as one `SET_POSES` undo
 step. Applying poses the draft at the playhead like a drag does: Auto-key
 keys it (one undo step), otherwise the pane's "Pose changed" banner asks.
 The Ctrl+C / Ctrl+V clipboard stays the quick one-slot path.
*>
module crig;

import rig;
import std::math;

fn sz AppState.saved_pose_named(&self, String name)
{
	foreach (usz i, pose : self.doc.poses) if (pose.name == name) return (sz)i;
	return -1;
}

// "Pose N", the first N from the library's size up that no pose uses.
fn String AppState.next_pose_name(&self, Allocator allocator)
{
	for (usz n = self.doc.poses.len + 1; ; n++)
	{
		String name = string::tformat("Pose %d", n);
		if (self.saved_pose_named(name) < 0) return name.copy(allocator);
	}
}

// Replace the library with `next` (taken over) as one undo step.
fn void AppState.set_poses_recorded(&self, SavedPose[] next)
{
	SavedPose[] before = copy_saved_poses(mem, self.doc.poses);
	self.doc.set_poses(next);
	self.undo_stack.record_poses(before, copy_saved_poses(mem, self.doc.poses));
	self.undo_stack.commit();
	self.refresh_ui();
}

<*
 Add `made` (taken over) to the library, or replace the pose of that name, as
 one undo step.

 @return `The pose's row.`
*>
fn sz AppState.store_pose(&self, SavedPose made)
{
	sz at = self.saved_pose_named(made.name);
	SavedPose[] next;
	if (at >= 0)
	{
		next = copy_saved_poses(mem, self.doc.poses);
		next[at].free(mem);
		next[at] = made;
	}
	else
	{
		at = (sz)self.doc.poses.len;
		next = alloc::new_array(mem, SavedPose, self.doc.poses.len + 1);
		SavedPose[] held = copy_saved_poses(mem, self.doc.poses);
		foreach (usz i, entry : held) next[i] = entry;
		if (held.len > 0) alloc::free(mem, held);
		next[at] = made;
	}
	self.set_poses_recorded(next);
	return at;
}

<*
 Save the pose at the playhead — the selected joints, or all of them — under
 `name`. A pose already called that is replaced.

 @param name : `Empty picks the next free "Pose N".`
 @return `The pose's row, or -1 when nothing was saved; the notice says why.`
*>
fn sz AppState.save_named_pose(&self, String name)
{
	if (!self.clip(self.editing))
	{
		self.@notice("pick an animation to save a pose from");
		return -1;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("there is no rig to save a pose from");
		return -1;
	}
	RigView view = opened;
	defer view.free(mem);

	AnimKeyframe pose;
	bool whole;
	if (!self.pose_in_hand(&view, &pose, &whole))
	{
		self.@notice("select named joints to save their pose");
		return -1;
	}

	name = name.trim();
	SavedPose made = { .name = name.len > 0 ? name.copy(mem) : self.next_pose_name(mem), .dots = pose.dots };
	bool replaced = self.saved_pose_named(made.name) >= 0;
	sz at = self.store_pose(made);
	usz joints = made.dots.len;
	self.pose_library_row = (usz)at;
	self.@notice("%s \"%s\" · %d joint%s%s. Apply puts it on any animation; Ctrl+Z undoes it.",
		replaced ? "Replaced" : "Saved", self.doc.poses[at].name, joints, joints == 1 ? "" : "s",
		whole ? "" : " (the selected ones)");
	return at;
}

<*
 Rename a saved pose, as one undo step. Refuses an empty name or one another
 pose already has.
*>
fn bool AppState.rename_saved_pose(&self, usz index, String name)
{
	if (index >= self.doc.poses.len) return false;
	name = name.trim();
	if (name.len == 0)
	{
		self.@notice("give the pose a name");
		return false;
	}
	if (self.doc.poses[index].name == name) return false;
	if (self.saved_pose_named(name) >= 0)
	{
		self.@notice("another pose is already called \"%s\"", name);
		return false;
	}
	SavedPose[] next = copy_saved_poses(mem, self.doc.poses);
	next[index].name.free(mem);
	next[index].name = name.copy(mem);
	self.set_poses_recorded(next);
	self.@notice("Renamed the pose to \"%s\".", name);
	return true;
}

// Delete a saved pose, as one undo step.
fn bool AppState.delete_saved_pose(&self, usz index)
{
	if (index >= self.doc.poses.len) return false;
	SavedPose[] held = copy_saved_poses(mem, self.doc.poses);
	SavedPose[] next;
	if (held.len > 1)
	{
		next = alloc::new_array(mem, SavedPose, held.len - 1);
		usz write;
		foreach (usz i, entry : held) if (i != index) next[write++] = entry;
	}
	String gone = held[index].name.tcopy();
	held[index].free(mem);
	alloc::free(mem, held);
	self.set_poses_recorded(next);
	if (self.pose_library_row >= self.doc.poses.len && self.pose_library_row > 0) self.pose_library_row--;
	self.@notice("Deleted the pose \"%s\". Ctrl+Z brings it back.", gone);
	return true;
}

<*
 Put a saved pose on the draft at the playhead of the clip being edited.

 Mirrored reflects it across the symmetry plane onto the twins, as Paste
 mirrored does. Selected-only keeps the entries that land on a selected joint.
 Joints the rig lacks are left out and counted in the notice.

 @return `How many joints were posed; zero when none were, with the reason as a notice.`
*>
fn usz AppState.apply_saved_pose(&self, usz index, bool mirrored = false, bool selected_only = false)
{
	if (index >= self.doc.poses.len)
	{
		self.@notice("pick a saved pose to apply");
		return 0;
	}
	if (!self.clip(self.editing))
	{
		self.@notice("pick an animation to apply the pose to");
		return 0;
	}
	if (selected_only && self.selected == 0)
	{
		self.@notice("select the joints to pose, or turn off Selected joints only");
		return 0;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	SavedPose saved = self.doc.poses[index];
	AnimKeyframe source = { .time = self.edit_time, .dots = saved.dots };
	usz unmatched;
	AnimKeyframe entries = mirrored
		? keyframe_flipped(mem, source, view.names, &unmatched)
		: keyframe_copy(mem, source);

	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : entries.dots)
	{
		sz joint = -1;
		foreach (usz j, name : view.names) if (name == dot.joint_name) { joint = (sz)j; break; }
		if (joint < 0) unmatched++;
		bool keep = joint >= 0 && (!selected_only
			|| ((usz)joint < view.dot_ids.len && self.is_selected(view.dot_ids[joint])));
		if (keep) { kept.push(dot); }
		else { dot.joint_name.free(mem); }
	}
	if (entries.dots.len > 0) alloc::free(mem, entries.dots);
	entries.dots = kept.to_array(mem);
	if (entries.dots.len == 0)
	{
		entries.free(mem);
		self.@notice(selected_only ? "\"%s\" has nothing for the selected joints" : "none of the joints in \"%s\" are on this rig",
			saved.name);
		return 0;
	}

	usz posed = self.pose_into_draft(&view, entries);
	if (posed == 0) return 0;
	String how = self.pose_edit_pending ? " · Key pose keeps it" : "";
	if (!self.pose_edit_active) how = " · Ctrl+Z undoes it";
	if (unmatched > 0)
	{
		self.@notice("Applied \"%s\"%s to %d joint%s at %.2fs; %d had no joint on this rig%s.", saved.name,
			mirrored ? " mirrored" : "", posed, posed == 1 ? "" : "s", self.edit_time, unmatched, how);
	}
	else
	{
		self.@notice("Applied \"%s\"%s to %d joint%s at %.2fs%s.", saved.name,
			mirrored ? " mirrored" : "", posed, posed == 1 ? "" : "s", self.edit_time, how);
	}
	return posed;
}

<*
 Pose the draft at the playhead with rig-named entries: each joint named takes
 what the clip would show with the entries keyed here (so limits apply as in
 playback); every other joint keeps what the draft held. Then Auto-key keys
 the change, or it waits as a pending pose.

 `entries` is taken over.

 @return `How many joints the entries named; zero when the draft could not be opened.`
*>
fn usz AppState.pose_into_draft(&self, RigView* view, AnimKeyframe entries)
{
	if (!self.prepare_animation_pose())
	{
		entries.free(mem);
		return 0;
	}
	AnimRef ref = self.editing;
	AnimTemplate* clip = self.clip(ref);
	bool[] written = alloc::new_array(mem, bool, (sz)view.len());
	defer alloc::free(mem, written);
	if (!clip || !self.entries_in_clip_words(view, ref, &entries, written))
	{
		entries.free(mem);
		self.@notice("this animation cannot carry the pose's joints");
		return 0;
	}
	usz count = entries.dots.len;
	entries.time = self.edit_time;

	AnimTemplate trial = clip_with_key(mem, *clip, entries);
	defer trial.free(mem);
	rig::Pose posed = self.evaluated_clip_pose(mem, view, trial, ref, self.edit_time, false);
	defer posed.free(mem);
	foreach (usz j, uint id : view.dot_ids)
	{
		if (!written[j] || j >= posed.rotations.len) continue;
		(void)self.set_working_pose(id, posed.rotations[j], posed.offsets[j]);
	}

	self.pose_edit_pending = self.pose_edit_differs(ref, self.edit_time);
	self.refresh_posed();
	if (self.pose_edit_pending && self.auto_key)
	{
		(void)self.key_pose_edit(CHANGED);
	}
	else
	{
		self.refresh_ui();
	}
	return count;
}

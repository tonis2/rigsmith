<*
 Turning the whole model about +Y by quarter turns: the mesh, the rig on it,
 and everything the character holds that has a direction, as one undo step.

 	`app.turn_model_by(-1);`   // a model facing +X, turned to face +Z

 What a generated model needs before a body plan can be fitted: many generators
 hand back a figure facing +X, and the plans fit a figure facing +Z or -Z. On
 the terms of `scale_model_by`, it is baked rather than placed: the vertices,
 their normals and the joints all turn, and Save writes the turned positions
 and normals into the model with the skin.

 **About the model's origin**, so a figure standing on the floor stays on it.
 Whole quarter turns only, because they are exact: a vertex turned and turned
 back has the same bits, so undo replays the turn instead of keeping a copy of
 the mesh.

 What turns with it, so nothing plays differently afterwards but the way the
 figure faces:

 - The limit tables' frames. A derived frame takes its roll from the world
   axes, so a table whose roll the turn would change is pinned to its turned
   frame, the way a move keeps it (`keep_limit_frames_recorded`).
 - Held props, the pose library and the authored clips: their keys, layers,
   aims, pins and paths are in model space (`AnimTemplate.turn`).

 What does not: clips from a library pack or the model's file. They are written
 for a figure facing +Z and retarget onto this rig as they play, so the turn is
 what makes them play right. The model's placement does not change either.
*>
module crig;

import rig;
import std::math;

<*
 Turn the model by whole quarter turns about +Y, counter-clockwise from above,
 as one undo step.

 @return `TURNED, UNCHANGED for a whole turn, LOCKED while a pose edit or a drag is open, REFUSED for a scene with nothing in it.`
*>
fn TurnModelResult AppState.turn_model_by(&self, int quarters)
{
	if (!self.has_mesh() && self.doc.dots.len() == 0) return REFUSED;
	if (self.transform_transaction.active || self.pose_edit_active) return LOCKED;
	int turns = quarter_turns(quarters);
	if (turns == 0) return UNCHANGED;

	// Read on the rig as it stands, before anything moves.
	JointRotationLimits[] limits = self.turned_limit_tables(mem, turns);
	defer if (limits.len > 0) alloc::free(mem, limits);

	float sym_before = self.doc.sym_x;
	float sym_after = self.turned_mirror_plane(turns);
	self.apply_model_turn(turns, sym_after);
	self.undo_stack.record({ .kind = TURN_MODEL, .quarters = turns, .sym_before = sym_before, .sym_after = sym_after });

	foreach (row : limits) self.set_rotation_limits_recorded(row.dot_id, row);
	self.turn_props_recorded(turns);
	self.turn_poses_recorded(turns);
	self.turn_authored_clips_recorded(turns);

	self.undo_stack.commit();
	return TURNED;
}

<*
 Turn the model round to face +Z from the way it faces now. See `turn_model_by`.

 @param facing : `Which way it faces; UNDECIDED reads the feet (feet_heading).`
 @param read : `The facing it went by: the one given, or the one the feet read.`
 @return `REFUSED as well when the feet do not say and no facing was given.`
*>
fn TurnModelResult AppState.turn_model_to_front(&self, MeshFacing facing, MeshFacing* read = null)
{
	MeshFacing from = facing;
	if (from == UNDECIDED && self.has_mesh()) from = self.mesh_facing();
	if (read) *read = from;
	if (from == UNDECIDED) return REFUSED;
	return self.turn_model_by(from.to_front);
}

<*
 Which way the mesh faces, as its feet read it. UNDECIDED without a mesh.
*>
fn MeshFacing AppState.mesh_facing(&self)
{
	if (!self.has_mesh()) return UNDECIDED;
	return feet_heading(self.geometry, self.geometry.bounds());
}

<*
 The turn itself, recorded by nobody: `turn_model_by` records it, and undo and
 redo replay it here with the turn or its inverse and the plane for that side.
*>
fn void AppState.apply_model_turn(&self, int quarters, float sym_x)
{
	if (self.geometry.positions.len > 0)
	{
		Vec3[] positions = alloc::new_array(mem, Vec3, (sz)self.geometry.positions.len);
		foreach (usz i, p : self.geometry.positions) positions[i] = quarter_turned(p, quarters);
		Vec3[] normals;
		if (self.geometry.normals.len > 0)
		{
			normals = alloc::new_array(mem, Vec3, (sz)self.geometry.normals.len);
			foreach (usz i, n : self.geometry.normals) normals[i] = quarter_turned(n, quarters);
		}
		self.replace_mesh_vertices(positions, normals);
		self.mesh_resized = true;
		self.mesh_turns = quarter_turns(self.mesh_turns + quarters);
	}

	foreach (&dot : self.doc.dots.array_view()) dot.position = quarter_turned(dot.position, quarters);
	self.doc.sym_x = sym_x;

	// World points on the model as it faced before.
	self.clear_position_locks();
	self.plan_targets_stale = true;
	self.mark_rig_stale();
	self.refresh_pose_display();
}

<*
 Where the mirror plane goes. A half turn reflects it through the origin; after
 a quarter turn the old plane ran front to back, so the body's middle is read
 again, from the mesh, or the joints without one.
*>
fn float AppState.turned_mirror_plane(&self, int quarters)
{
	if (quarter_turns(quarters) == 2) return -self.doc.sym_x;
	if (self.geometry.positions.len > 0)
	{
		rig::Bounds box = self.geometry.bounds();
		return quarter_turned(box.center(), quarters).x;
	}
	float low = math::FLOAT_MAX;
	float high = -math::FLOAT_MAX;
	foreach (dot : self.doc.dots.array_view())
	{
		float x = quarter_turned(dot.position, quarters).x;
		low = math::min(low, x);
		high = math::max(high, x);
	}
	return low <= high ? (low + high) * 0.5f : 0.0f;
}

<*
 Every limit table whose frame the turn would change, with its frame turned.

 A saved frame is a world orientation, so it always turns. A derived one follows
 its bone, which turns, but takes its roll about the bone from the world axes; a
 table whose derived frame would roll is pinned to the turned frame instead, so
 its rows keep the meaning they had.

 The caller owns the array.
*>
fn JointRotationLimits[] AppState.turned_limit_tables(&self, Allocator allocator, int quarters)
{
	if (self.doc.rotation_limits.len() == 0) return {};
	uint[] ids;
	rig::Skeleton? before = build_skeleton(&self.doc, mem, &ids);
	if (catch before) return {};
	defer
	{
		before.free(mem);
		alloc::free(mem, ids);
	}
	Vec3[] turned_joints = alloc::new_array(mem, Vec3, (sz)before.joints.len);
	defer alloc::free(mem, turned_joints);
	foreach (usz j, joint : before.joints) turned_joints[j] = quarter_turned(joint, quarters);
	rig::Skeleton after = { .joints = turned_joints, .parents = before.parents };

	Quaternionf turn = quarter_turn(quarters);
	JointRotationLimits[] out = alloc::new_array(allocator, JointRotationLimits, self.doc.rotation_limits.len());
	usz count = 0;
	foreach (limits : self.doc.rotation_limits.array_view())
	{
		if (limits.has_saved_frame)
		{
			JointRotationLimits turned = limits;
			turned.saved_frame = turn.mul(limits.saved_frame).normalize();
			out[count++] = turned;
			continue;
		}
		if (!limits.constrained) continue;
		JointLimitFrame was = joint_limit_frame(&before, ids, limits);
		JointLimitFrame now = joint_limit_frame(&after, ids, limits);
		if (!was.usable() || !now.usable()) continue;
		Quaternionf carried = turn.mul(was.rotation).normalize();
		if (limit_frame_roll(now.rotation, carried) <= LIMIT_FRAME_ROLL_JUMP) continue;
		JointRotationLimits pinned = limits;
		pinned.has_saved_frame = true;
		pinned.saved_frame = carried;
		out[count++] = pinned;
	}
	if (count == 0)
	{
		alloc::free(allocator, out);
		return {};
	}
	return out[:count];
}

// Each held prop's grip and turn, which are in its hand's frame, and that frame
// is the model's.
fn void AppState.turn_props_recorded(&self, int quarters)
{
	if (self.doc.props.len() == 0) return;
	Quaternionf turn = quarter_turn(quarters);
	HeldProp[] props = self.doc.props.to_array(tmem);
	foreach (prop : props)
	{
		HeldProp turned = prop;
		turned.offset = quarter_turned(prop.offset, quarters);
		turned.turn = turn.mul(prop.turn).normalize();
		self.set_prop_recorded(turned);
	}
}

fn void AppState.turn_poses_recorded(&self, int quarters)
{
	if (self.doc.poses.len == 0) return;
	SavedPose[] before = copy_saved_poses(mem, self.doc.poses);
	SavedPose[] turned = copy_saved_poses(mem, self.doc.poses);
	foreach (pose : turned)
	{
		foreach (&dot : pose.dots) dot.turn(quarters);
	}
	self.doc.set_poses(turned);
	self.undo_stack.record_poses(before, copy_saved_poses(mem, self.doc.poses));
}

<*
 Every authored clip swapped for its turned copy, each a swap in the open group.

 Straight through `swap_authored_clip` rather than `put_authored_clip`: that one
 copies a linked layer or piece into every clip sharing it, and those clips are
 turned here too, so the copy would turn them twice.
*>
fn void AppState.turn_authored_clips_recorded(&self, int quarters)
{
	AnimPack* pack = self.authored();
	if (!pack) return;
	for (usz i = 0; i < pack.clips.len; i++)
	{
		AnimTemplate clip = pack.clips[i];
		if (clip.lazy || clip.name.len == 0) continue;
		AnimTemplate turned = clip_copy(mem, clip);
		turned.turn(quarters);
		layers_settle_tracks(turned.layers, turned.duration);
		turned.compile_tracks(mem);
		String name = turned.name.copy(mem);
		AnimRef landed = NO_ANIM;
		AnimTemplate had = self.swap_authored_clip(turned.name, turned, &landed, (int)i);
		self.undo_stack.record_clip_swap(name, had, landed.clip);
		// The swap may have grown the pack array.
		pack = self.authored();
	}
	self.clear_animation_key_selection();
}

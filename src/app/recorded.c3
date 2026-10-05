<*
 A document primitive and its ledger entry, in one step.

 What the operations elsewhere in `app/` are assembled from. Each one does the
 thing and records that it did it, and **none of them commits** — the group stays
 open, so a caller can do four of these and have the user's one Ctrl+Z take back
 all four. Every operation ends with the one `commit` that closes it.

 Not commands, and not to be wired to a menu item or a key. A `*_recorded` call
 that reaches the user directly is an edit that merges into whatever they do
 next, which is the failure this split exists to make visible: the operations are
 in the other files, and everything here is beneath them.

 Most return false and record nothing when the primitive changed nothing, so a
 caller can loop over a selection without checking first and still get one group
 holding only the edits that happened.
*>
module crig;

import rig;
import std::math;

fn uint AppState.add_recorded(&self, Vec3 position, String name = "")
{
	uint id = self.doc.add_dot(position, name);
	self.undo_stack.record({ .kind = ADD_DOT, .id = id, .after = position, .name = (String)@clone_slice((char[])name) });
	return id;
}

fn void AppState.connect_recorded(&self, uint a, uint b)
{
	if (!self.doc.connect(a, b)) return;
	self.undo_stack.record({ .kind = ADD_EDGE, .id = a, .other = b });
}

fn bool AppState.disconnect_recorded(&self, uint a, uint b)
{
	if (!self.doc.disconnect(a, b)) return false;
	self.undo_stack.record({ .kind = DELETE_EDGE, .id = a, .other = b });
	return true;
}

// Unlike the rest of these, this one is given where the dot was rather than
// reading it: a drag has already moved it by the time the release is recorded.
fn bool AppState.move_recorded(&self, uint id, Vec3 from, Vec3 to)
{
	if (!self.doc.find(id)) return false;
	self.keep_limit_frames_recorded(id, from, to);
	if (!self.doc.move_dot(id, to)) return false;
	self.undo_stack.record({ .kind = MOVE_DOT, .id = id, .before = from, .after = to });
	return true;
}

<*
 How far a limited joint's derived axes may turn about its own bone, across one
 move, before the joint keeps its old axes instead. A move that swings a bone
 turns the derived frame about the bone by a fraction of the swing; a quarter
 turn is the seed switching sides.
*>
const float LIMIT_FRAME_ROLL_JUMP = 0.1f;

<*
 Keeps every limit table's axes where they were across a move of dot `id`.

 A frame that is not saved is derived from its bone, and a near-vertical bone
 takes its X from whichever world axis it leans on least — so nudging a knee
 sideways could turn the hip's frame a quarter turn about the thigh and put its
 forward swing on the sideways row. Where the derived frame would roll like
 that, the old frame is carried onto the new bone by the shortest turn and saved
 on the table, in the same undo group as the move. A move that rolls the frame
 no more than a swing does leaves the table derived, so bones keep following
 their joints.

 The dot is read at `from` and at `to` whatever the document holds, since a drag
 has already put it at `to` by the time it records.
*>
fn void AppState.keep_limit_frames_recorded(&self, uint id, Vec3 from, Vec3 to)
{
	if (self.doc.rotation_limits.len() == 0 || from == to) return;
	Dot* dot = self.doc.find(id);
	if (!dot) return;
	Vec3 held = dot.position;

	@pool()
	{
		uint[] before_ids;
		uint[] after_ids;
		dot.position = from;
		rig::Skeleton? before = build_skeleton(&self.doc, tmem, &before_ids);
		dot.position = to;
		rig::Skeleton? after = build_skeleton(&self.doc, tmem, &after_ids);
		dot.position = held;
		if (catch before) return;
		if (catch after) return;

		JointRotationLimits[] rows = alloc::new_array(tmem, JointRotationLimits,
			self.doc.rotation_limits.len());
		usz count = 0;
		foreach (limits : self.doc.rotation_limits.array_view())
		{
			if (!limits.constrained || limits.has_saved_frame) continue;
			JointLimitFrame was = joint_limit_frame(&before, before_ids, limits);
			JointLimitFrame now = joint_limit_frame(&after, after_ids, limits);
			if (!was.usable() || !now.usable()) continue;
			Vec3 was_y = was.axis(Y);
			Vec3 now_y = now.axis(Y);
			Quaternionf carried = bone_carry(was_y, now_y).mul(was.rotation).normalize();
			// The two frames share Y, so what is left between them is a roll.
			float[<4>] roll = now.rotation.invert().mul(carried).normalize().v;
			float half = math::atan2(math::sqrt(roll.x * roll.x + roll.y * roll.y + roll.z * roll.z),
				math::abs(roll.w));
			if (2.0f * half <= LIMIT_FRAME_ROLL_JUMP) continue;
			limits.has_saved_frame = true;
			limits.saved_frame = carried;
			rows[count++] = limits;
		}
		foreach (limits : rows[:count]) self.set_rotation_limits_recorded(limits.dot_id, limits);
	};
}

<*
 Pins a shell to a dot, or unpins it, leaving the group open.

 The uncommitted half of `pin_shell`, so a batch of pins is one Ctrl+Z. Zero is
 a real value for `dot_id` and means "hand it back to the binder" — the same
 reading `RigDocument.attach_shell` gives it.

 @return `False when nothing changed, in which case nothing was recorded.`
*>
fn bool AppState.attach_recorded(&self, uint shell, uint dot_id)
{
	uint before = self.doc.attachment_of(shell);
	if (!self.doc.attach_shell(shell, dot_id)) return false;

	self.undo_stack.record({
		.kind = ATTACH_SHELL,
		.shell = shell,
		.id = dot_id,
		.other = before,
	});
	return true;
}

<*
 A reach to start a joint at, when a rig has some reaches and not others.

 Sized from the joint's **own bone** — the segment to its primary child — with a
 little over, so the far end of that bone is still held. Not the longest edge
 touching the joint: a hips or chest joint touches a long spine or thigh, and
 sizing from that gave them a reach over half the body.

 A joint with no bones falls back to a tenth of the model.
*>
fn float AppState.default_reach(&self, uint id)
{
	if (!self.doc.find(id)) return 0.0f;

	float own = self.own_bone_length(id);
	if (own > 0.0f) return own * 1.5f;

	rig::Bounds box = self.geometry.bounds();
	Vec3 span = box.max - box.min;
	float size = span.max();
	return size > 0.0f ? size * 0.1f : 0.0f;
}

<*
 How long a joint's own bone is: the segment to its primary child.

 The primary child is the one its rotation limits name; otherwise the child that
 carries on most nearly straight from the bone arriving at the joint; at the root,
 with nothing arriving, the shortest. A leaf's own bone is the one arriving at it.
*>
fn float AppState.own_bone_length(&self, uint id)
{
	Dot* dot = self.doc.find(id);
	if (!dot) return 0.0f;

	uint parent = self.parent_dot(id);
	Dot* above = parent != 0 ? self.doc.find(parent) : null;
	uint primary = self.doc.rotation_limits_of(id).primary_child;

	Vec3 arriving = above ? (dot.position - above.position) : (Vec3){};
	float arriving_length = arriving.length();

	float chosen = 0.0f;
	float straightest = -2.0f;
	foreach (edge : self.doc.edges.array_view())
	{
		uint other = edge.a == id ? edge.b : (edge.b == id ? edge.a : 0);
		if (other == 0 || other == parent) continue;
		Dot* child = self.doc.find(other);
		if (!child) continue;

		Vec3 bone = child.position - dot.position;
		float length = bone.length();
		if (length <= 0.0f) continue;
		if (other == primary) return length;

		if (arriving_length > 0.0f)
		{
			float straight = bone.dot(arriving) / (length * arriving_length);
			if (straight <= straightest) continue;
			straightest = straight;
			chosen = length;
		}
		else if (chosen == 0.0f || length < chosen)
		{
			chosen = length;
		}
	}
	return chosen > 0.0f ? chosen : arriving_length;
}

<*
 The joint above this one, walking the bones out from the root; 0 for the root
 and for a joint the root cannot reach.
*>
fn uint AppState.parent_dot(&self, uint id)
{
	uint root = self.doc.root_id;
	if (root == 0 || root == id || !self.doc.find(root)) return 0;

	DotIdList frontier;
	frontier.init(mem);
	defer frontier.free();
	DotIdList parents;
	parents.init(mem);
	defer parents.free();
	frontier.push(root);
	parents.push(0);

	for (sz head = 0; head < frontier.len(); head++)
	{
		uint at = frontier[head];
		foreach (edge : self.doc.edges.array_view())
		{
			uint next = edge.a == at ? edge.b : (edge.b == at ? edge.a : 0);
			if (next == 0 || next == parents[head]) continue;
			bool seen = false;
			foreach (known : frontier.array_view())
			{
				if (known == next) { seen = true; break; }
			}
			if (seen) continue;
			if (next == id) return at;
			frontier.push(next);
			parents.push(at);
		}
	}
	return 0;
}

fn bool AppState.set_reach_recorded(&self, uint id, float reach)
{
	Dot* dot = self.doc.find(id);
	if (!dot) return false;

	float had = dot.reach;
	float want = reach > 0.0f ? reach : 0.0f;
	if (had == want) return false;

	self.doc.set_reach(id, want);
	self.undo_stack.record({ .kind = SET_REACH, .id = id, .reach_before = had, .reach_after = want });
	return true;
}

<*
 Sets how crisp this model's blends are, leaving the group open.

	The previous value is read here rather than passed: nothing writes the
	sharpness straight into the document ahead of the record, so
 what is on the document is still what it held.

 Names no dot — the setting is the model's — so the edit it records carries only
 the pair of floats. Zero is a real value on both sides and means the binder's
 own blend, the same reading `RigDocument.set_sharpness` gives it.

 @return `False when nothing changed, in which case nothing was recorded — the clamp makes that the ordinary answer at either end of the range.`
*>
fn bool AppState.set_sharpness_recorded(&self, float value)
{
	float before = self.doc.sharpness;
	if (!self.doc.set_sharpness(value)) return false;

	self.undo_stack.record({
		.kind = SET_SHARPNESS,
		.sharp_before = before,
		.sharp_after = self.doc.sharpness,
	});
	return true;
}

<*
 Move the mirror plane, recording it so one Ctrl+Z takes it back.

 Left open like `set_sharpness_recorded`, so a mirror that corrects the plane and
 squares the joints up commits the two together.

 @return `False when nothing changed — the plane was already there — in which case nothing was recorded.`
*>
fn bool AppState.set_sym_x_recorded(&self, float x)
{
	float before = self.doc.sym_x;
	if (!self.doc.set_sym_x(x)) return false;

	self.undo_stack.record({
		.kind = SET_SYM_X,
		.sym_before = before,
		.sym_after = self.doc.sym_x,
	});
	return true;
}

fn bool AppState.set_model_transform_recorded(
	&self,
	ProjectTransform before,
	ProjectTransform after)
{
	if (!after.valid() || before.same(after)) return false;
	after.rotation = after.orientation();
	self.doc.model_transform = after;
	self.undo_stack.record({
		.kind = SET_MODEL_TRANSFORM,
		.transform_before = before,
		.transform_after = after,
	});
	return true;
}

<*
 Writes a secondary-motion chain onto its root, or replaces the one there,
 leaving the group open.

 The previous record is read here rather than passed, unlike `move_recorded`:
 nothing writes a chain straight into the document ahead of the record, so what
 is on the document is still what it held. Not validated against the skeleton —
 `secondary_problem` is the check, and a caller with a sentence to deliver asks
 it first.

 @return `False when nothing changed, in which case nothing was recorded.`
*>
fn bool AppState.set_secondary_recorded(&self, SecondaryChain chain)
{
	SecondaryChain before = self.doc.secondary_of(chain.root);
	if (!self.doc.set_secondary(chain)) return false;

	// What the sim is built out of has changed, so the one that may be running is
	// describing the previous document. See `app/sim.c3`.
	self.jiggle_reset();

	self.undo_stack.record({
		.kind = SET_SECONDARY,
		.id = chain.root,
		.secondary_before = before,
		.secondary_after = self.doc.secondary_of(chain.root),
	});
	return true;
}

<*
 Takes the chain off a root, leaving the group open. The zero record on the
 edit's "after" side is what `assign_secondary` reads back as a clear.

 @return `False when the root carried no chain, in which case nothing was recorded.`
*>
fn bool AppState.clear_secondary_recorded(&self, uint root)
{
	SecondaryChain before = self.doc.secondary_of(root);
	if (!self.doc.clear_secondary(root)) return false;

	self.jiggle_reset();

	self.undo_stack.record({
		.kind = SET_SECONDARY,
		.id = root,
		.secondary_before = before,
		.secondary_after = {},
	});
	return true;
}

<*
 Sizes a dot's collider capsule, or removes it, leaving the group open.

 Zero is a real value and means "no capsule here" — the same reading
 `RigDocument.set_collider` gives it, and the same shape `attach_recorded`'s zero
 has.

 @return `False when nothing changed, in which case nothing was recorded.`
*>
fn bool AppState.set_collider_recorded(&self, uint id, float radius)
{
	float before = self.doc.collider_of(id);
	if (!self.doc.set_collider(id, radius)) return false;

	// A capsule the chains are pushed out of is part of the sim's build, so the
	// same rebuild the chain setters ask for is wanted here.
	self.jiggle_reset();

	self.undo_stack.record({
		.kind = SET_COLLIDER,
		.id = id,
		.collider_before = before,
		.collider_after = radius > 0.0f ? radius : 0.0f,
	});
	return true;
}

<*
 Tells the collision check to leave two regions alone, or to test them again,
 leaving the group open.

 Rig metadata on the limits' terms: the rig has not moved, so nothing is marked
 stale. The live policy, if there is one, adopts the change directly — its
 excluded-pair table is the one thing an exclusion edit invalidates.

 @return `False when nothing changed, in which case nothing was recorded.`
*>
fn bool AppState.exclude_recorded(&self, uint a, uint b, bool excluded)
{
	bool changed = excluded ? self.doc.add_exclusion(a, b) : self.doc.remove_exclusion(a, b);
	if (!changed) return false;
	self.undo_stack.record({ .kind = excluded ? ADD_EXCLUSION : DELETE_EXCLUSION, .id = a, .other = b });
	self.collision_policy.adopt_exclusions(&self.doc);
	return true;
}

<*
 Replaces one joint's complete rotation-limit table, leaving the undo group
 open. Constraint edits are rig metadata: they never key the current pose.

 @return `False for an invalid value or an exact no-op.`
*>
fn bool AppState.set_rotation_limits_recorded(&self, uint id, JointRotationLimits limits)
{
	JointRotationLimits before = self.doc.rotation_limits_of(id);
	if (!self.doc.set_rotation_limits(id, limits)) return false;

	JointRotationLimits after = self.doc.rotation_limits_of(id);
	self.undo_stack.record_rotation_limits(before, after);
	// A chain swings where its joints' tables say, so the sim is built over
	// them: a table that changed is a sim that describes the rig it no longer
	// has. Rebuilt on the next frame of playback, like a chain edit.
	self.jiggle_reset();
	self.refresh_pose_display();
	return true;
}

fn bool AppState.rename_recorded(&self, uint id, String name)
{
	Dot* dot = self.doc.find(id);
	if (!dot || dot.name == name) return false;

	String had = (String)@clone_slice((char[])dot.name);
	self.doc.rename_dot(id, name);

	// The one edit that leaves every joint exactly where it was and still changes
	// which of a pack's clips reach it — a rig's own spelling is preferred over the
	// shape match wherever a pack shares it. `mark_rig_stale` covers everything
	// else, including the undo of this. See `AppState.pack_reach`.
	self.reach_stale = true;
	self.undo_stack.record({
		.kind = RENAME_DOT,
		.id = id,
		.name = (String)@clone_slice((char[])name),
		.prior_name = had,
	});
	return true;
}

fn bool AppState.root_recorded(&self, uint id)
{
	if (id == 0 || id == self.doc.root_id || !self.doc.find(id)) return false;

	self.undo_stack.record({ .kind = SET_ROOT, .id = id, .other = self.doc.root_id });
	self.doc.root_id = id;
	return true;
}

<*
 Drops any held id that no longer names a dot.

 Undo and delete both remove dots the user may still be pointing at, and a
 stale id is exactly what the never-reused id scheme is supposed to make safe:
 it reads as "gone" here rather than silently becoming a different dot.
*>
fn void AppState.forget_stale_ids(&self)
{
	if (!self.doc.find(self.selected)) self.selected = 0;

	// Backwards: `remove_at` shifts everything after the hole down, and a
	// forward walk would step over whatever moved into it.
	for (sz i = self.also_selected.len() - 1; i >= 0; i--)
	{
		uint id = self.also_selected[i];
		if (!self.doc.find(id) || id == self.selected) self.also_selected.remove_at(i);
	}

	// The anchor going does not end a selection that still has members: one of
	// them takes the role, so a delete that took the anchor leaves the rest
	// selected rather than leaving a group with nothing to act through.
	if (self.selected == 0 && self.also_selected.len() > 0)
	{
		self.selected = self.also_selected[0];
		self.also_selected.remove_at(0);
		self.anchor_moved();
	}
	if (self.selected != 0) { self.scene_selection = JOINT; }
	else if (self.scene_selection == JOINT) { self.scene_selection = NONE; }
}

<*
 Look-at targets in the editor: the limits a turn is clamped to, the draft a
 target is dragged as, and the handles the viewport draws.

 The clip stores the aims (`anim/aim.c3`); this is how the app lays them over a
 pose it shows. A target being edited lives in `aim_draft`, beside
 `pose_edit_draft` and with the same rule: it is working memory, applied to the
 clip being edited and landed as one undo step when it is keyed.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

<*
 One target being moved: the target's name and where it is now, a fraction of
 rig height in model space. Owned, `target` included; see
 `AppState.drop_aim_draft`.
*>
struct AimDraft
{
	String target;
	Vec3 at;
}

<*
 One look-at target as the viewport shows it, built beside `posed_dots`. One per
 target of the clip, locked to a joint or not. `target` is an owned copy of the
 target's name; free a list of them with `free_aim_handles`.
*>
struct AimHandle
{
	String target;
	Vec3 at;    // the target, in model units
	bool muted; // the target is muted
}

<*
 One lock as the viewport draws it: a line from the locked joint to the handle
 `handle` (an index into `posed_aims`) of its target. `muted` is the lock or its
 target.
*>
struct AimLink
{
	usz handle;
	uint dot;       // the locked joint's dot id
	Vec3 joint_at;  // where the joint is, in model units
	bool muted;
}

// Free handles built by `aim_handles`.
fn void free_aim_handles(AimHandle[] handles)
{
	foreach (&handle : handles) if (handle.target.len > 0) alloc::free(mem, handle.target.ptr);
	if (handles.len > 0) alloc::free(mem, handles);
}

// Stands in for `DragState.dot` during a target drag, which has no joint: a value
// no document dot has, so the "a gesture is active" readers still see non-zero
// and no lookup of it finds anything. The target is `DragState.aim`.
const uint AIM_DRAG_DOT = 0xFFFF_FFFF;
const usz NO_HANDLE = (usz)-1;

// What `doc_aim_clamp` reads: the document that holds the limits, and the build
// whose joints it is indexed by.
struct AimClampContext
{
	AppState* app;
	RigView* view;
}

<*
 Hold one joint's candidate local rotation inside the document's limits, the same
 rule `hold_world_rotation` applies: constrained through the joint's frame when
 it has limits, free otherwise. An `AimClamp` over an `AimClampContext`.
*>
fn Quaternionf doc_aim_clamp(void* ctx, usz joint, Quaternionf local)
{
	AimClampContext* held = (AimClampContext*)ctx;
	RigView* view = held.view;
	if (joint >= view.dot_ids.len) return local;
	JointRotationLimits limits = held.app.doc.rotation_limits_of(view.dot_ids[joint]);
	if (!limits.constrained) return local;
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	if (!frame.usable()) return local;
	return constrain_joint_rotation(frame, limits, local);
}

<*
 The clip's aims laid over `pose`, which has had its limits and its ground solve.

 When `ref` is the clip being edited the drafts stand in for the target of the
 aims they name, so a target being dragged turns the head before it is keyed.

 @param applied : `Receives each touched joint's rotation from before the aims; may be null.`
 @param gain : `A crossfade's weight for this clip's aims.`
*>
fn void AppState.apply_clip_aims(
	&self,
	RigView* view,
	AnimTemplate clip,
	AnimRef ref,
	float time,
	rig::Pose* pose,
	AimAppliedSet* applied = null,
	float gain = 1.0f)
{
	if (clip.aims.len == 0) return;
	String[] names = self.names_for(view, ref);

	AnimAimTarget[] targets = clip.aim_targets;
	AnimAimTarget[] staged;
	AnimAimKey[] held;
	if (self.aim_draft.len > 0 && ref.same(self.editing))
	{
		// Shallow copies: the drafts replace the keys, the rest is the clip's own.
		staged = alloc::new_array(tmem, AnimAimTarget, (sz)clip.aim_targets.len);
		held = alloc::new_array(tmem, AnimAimKey, (sz)clip.aim_targets.len);
		foreach (usz i, target : clip.aim_targets)
		{
			staged[i] = target;
			foreach (draft : self.aim_draft)
			{
				if (draft.target != target.name) continue;
				held[i] = { .time = 0.0f, .at = draft.at, .interpolation = LINEAR };
				staged[i].keys = held[i:1];
			}
		}
		targets = staged;
	}

	AimClampContext ctx = { .app = self, .view = view };
	aim_pose(mem, &view.skeleton, names, clip.aims, targets, time, clip.duration, clip.loop, pose,
		view.skeleton.height(), &doc_aim_clamp, &ctx, applied, gain);
}

<*
 The handles of a clip's targets at `time`, for the overlay to draw and pick: one
 per target, where it is in model units, and `links` (when given) one per lock
 whose joint and target both exist, where its joint stands in `palette`. Drafts
 apply as in `apply_clip_aims`. The caller owns both arrays (`free_aim_handles`
 for the handles); empty when the clip has no targets.
*>
fn AimHandle[] AppState.aim_handles(&self, RigView* view, AnimTemplate clip, AnimRef ref, float time, Matrix4f[] palette,
	AimLink[]* links = null)
{
	if (links) *links = {};
	if (clip.aim_targets.len == 0 || palette.len < view.skeleton.len()) return {};
	String[] names = self.names_for(view, ref);
	float height = view.skeleton.height();
	bool drafting = self.aim_draft.len > 0 && ref.same(self.editing);

	AimHandle[] out = alloc::new_array(mem, AimHandle, (sz)clip.aim_targets.len);
	usz[] slot = alloc::new_array(tmem, usz, (sz)clip.aim_targets.len);
	usz count;
	foreach (usz i, &target : clip.aim_targets)
	{
		slot[i] = NO_HANDLE;
		if (target.keys.len == 0) continue;
		Vec3 at = target.target_at(time, clip.duration, clip.loop);
		if (drafting) foreach (draft : self.aim_draft) if (draft.target == target.name) at = draft.at;
		slot[i] = count;
		out[count++] = { .target = target.name.copy(mem), .at = at * height, .muted = target.mute };
	}
	if (count == 0)
	{
		alloc::free(mem, out);
		return {};
	}

	if (links && clip.aims.len > 0)
	{
		AimLink[] made = alloc::new_array(mem, AimLink, (sz)clip.aims.len);
		usz used;
		foreach (&aim : clip.aims)
		{
			sz found = -1;
			foreach (usz j, name : names) if (j < view.skeleton.len() && name == aim.joint) { found = (sz)j; break; }
			sz t = aim_target_index_of(clip.aim_targets, aim.target);
			if (found < 0 || (usz)found >= view.dot_ids.len || t < 0 || slot[(usz)t] == NO_HANDLE) continue;
			made[used++] = {
				.handle = slot[(usz)t],
				.dot = view.dot_ids[(usz)found],
				.joint_at = view.skeleton.joints[(usz)found].transform(palette[(usz)found]),
				.muted = aim.mute || clip.aim_targets[(usz)t].mute,
			};
		}
		if (used == 0)
		{
			alloc::free(mem, made);
		}
		else
		{
			*links = made[:used];
		}
	}
	return out[:count];
}

<*
 Forget every target draft. Called with the pose draft it travels with.
*>
fn void AppState.drop_aim_draft(&self)
{
	foreach (&draft : self.aim_draft) if (draft.target.len > 0) alloc::free(mem, draft.target.ptr);
	if (self.aim_draft.len > 0) alloc::free(mem, self.aim_draft);
	self.aim_draft = {};
}

// ---------------------------------------------------------------------------
// Authoring: the ops the viewport and its menu call. Each lands the clip as one
// undo step, as the MCP's `set_aim` does.

// How far in front of the joint a new target is put, as a share of rig height.
const float AIM_FRONT_REACH = 0.6f;

<*
 Where `joint` stands in `pose` and which way it faces there: its world position
 and world rotation.

 @return `False when the palette could not be built.`
*>
fn bool aim_frame(RigView* view, rig::Pose pose, usz joint, Vec3* position, Quaternionf* world)
{
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return false;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	Quaternionf[]? spun = pose.world_rotations(mem, &view.skeleton);
	if (catch spun) return false;
	Quaternionf[] rotations = spun;
	defer alloc::free(mem, rotations);
	if (joint >= palette.len || joint >= rotations.len) return false;
	*position = view.skeleton.joints[joint].transform(palette[joint]);
	*world = rotations[joint];
	return true;
}

<*
 The aim axis, in the joint's own frame, that makes an aim at `at` (a fraction of
 rig height) turn nothing while the joint stands at `position` with rotation
 `world`; +Z when the target is on the joint.
*>
fn Vec3 aim_forward_for(Vec3 position, Quaternionf world, float height, Vec3 at)
{
	Vec3 to = at * height - position;
	if (to.length_sq() < 1.0e-12f) return { 0, 0, 1 };
	return world.invert().rotate_vec3(to.normalize());
}

<*
 The aimed joint's name as the editing clip spells it, or an empty string when
 the rig has no such joint.
*>
fn String AppState.aim_name_of(&self, RigView* view, uint dot_id)
{
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || !self.editing.valid()) return "";
	String[] names = self.names_for(view, self.editing);
	if ((usz)joint >= names.len) return "";
	return names[(usz)joint];
}

<*
 The name of the target the joint on `dot_id` is locked to in the editing clip,
 or an empty string. Borrowed from the clip; copy it before landing anything.
*>
fn String AppState.aim_target_of(&self, RigView* view, uint dot_id)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return "";
	String joint = self.aim_name_of(view, dot_id);
	if (joint.len == 0) return "";
	sz at = aim_index_of(clip.aims, joint);
	return at >= 0 ? clip.aims[(usz)at].target : "";
}

<*
 Where in the editing clip's aims the joint's is, or -1 when the clip has none
 on it. Not an index into `posed_aims`, which is the handles on screen.
*>
fn sz AppState.aim_index(&self, uint dot_id)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || clip.aims.len == 0) return -1;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return -1;
	RigView view = opened;
	defer view.free(mem);
	String name = self.aim_name_of(&view, dot_id);
	if (name.len == 0) return -1;
	return aim_index_of(clip.aims, name);
}

<*
 Land a rewritten clip while the pose draft stays: landing restarts the watched
 clip, which would release a draft that belongs to this editing transaction (the
 same parking `key_here` does). `built` is taken over.
*>
fn AnimRef AppState.land_aim_clip(&self, AnimRef ref, AnimTemplate built)
{
	PosedJoint[] draft = self.pose_edit_draft;
	bool active = self.pose_edit_active;
	bool pending = self.pose_edit_pending;
	self.pose_edit_draft = {};
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	AnimRef landed = self.land_layered(ref, built);
	self.pose_edit_draft = draft;
	self.pose_edit_active = active;
	self.pose_edit_pending = pending;
	if (active) self.refresh_posed();
	return landed;
}

<*
 The clip with every pending target keyed at `time`, taking `built` over. The
 targets of aims the clip no longer has are ignored.
*>
fn AnimTemplate AppState.with_aim_keys(&self, AnimTemplate built, float time)
{
	foreach (draft : self.aim_draft)
	{
		AnimTemplate next = clip_with_target_key(mem, built, draft.target,
			{ .time = time, .at = draft.at, .interpolation = LINEAR });
		built.free(mem);
		built = next;
	}
	return built;
}

// Forget the draft of one target, if it has one.
fn void AppState.forget_aim_draft(&self, String target)
{
	foreach (i, draft : self.aim_draft)
	{
		if (draft.target != target) continue;
		alloc::free(mem, draft.target.ptr);
		if (self.aim_draft.len == 1)
		{
			alloc::free(mem, self.aim_draft);
			self.aim_draft = {};
			return;
		}
		AimDraft[] next = alloc::new_array(mem, AimDraft, self.aim_draft.len - 1);
		usz out;
		foreach (j, kept : self.aim_draft) if (j != i) next[out++] = kept;
		alloc::free(mem, self.aim_draft);
		self.aim_draft = next;
		return;
	}
}

// Set the target's draft, making one when it has none.
fn void AppState.set_aim_draft(&self, String target, Vec3 at)
{
	foreach (&draft : self.aim_draft)
	{
		if (draft.target != target) continue;
		draft.at = at;
		return;
	}
	AimDraft[] next = alloc::new_array(mem, AimDraft, self.aim_draft.len + 1);
	foreach (i, kept : self.aim_draft) next[i] = kept;
	next[self.aim_draft.len] = { .target = target.copy(mem), .at = at };
	if (self.aim_draft.len > 0) alloc::free(mem, self.aim_draft);
	self.aim_draft = next;
}

// Where target `name` stands in the editing clip now, a fraction of rig height:
// its draft when it is being dragged, else the clip's key track at the edit time.
fn Vec3 AppState.aim_target_now(&self, AnimTemplate* clip, String name)
{
	foreach (draft : self.aim_draft) if (draft.target == name) return draft.at;
	sz t = aim_target_index_of(clip.aim_targets, name);
	if (t < 0 || clip.aim_targets[(usz)t].keys.len == 0) return {};
	return clip.aim_targets[(usz)t].target_at(self.edit_time, clip.duration, clip.loop);
}

<*
 The selected joints the editing rig has, anchor first, as dot ids. The caller
 owns the array (`tmem` when `allocator` is).
*>
fn uint[] AppState.selected_aim_dots(&self, Allocator allocator, RigView* view)
{
	uint[] out = alloc::new_array(allocator, uint, (sz)self.selection_count());
	usz used;
	if (self.selected != 0 && view.joint_of(self.selected) >= 0) out[used++] = self.selected;
	if (self.selected != 0)
	{
		foreach (other : self.also_selected.array_view())
		{
			if (view.joint_of(other) >= 0) out[used++] = other;
		}
	}
	return out[:used];
}

<*
 The shared body of the lock ops: lock each of `dots` to a target and land the
 clip as one undo step. The aim axis of each fresh or re-pointed lock is read
 off the pose on screen (grounded, other aims on), so locking turns nothing.

 With `existing` empty a new target is made, keyed at the edit time: in front of
 the mean position of the joints along the first one's +Z, or, with no joints, in
 front of the rig at about chest height. Otherwise the joints lock to the
 target `existing`. A fresh lock spreads over 3 joints when it is the only one
 locked, over 1 when several are; a joint already locked elsewhere is re-pointed
 and keeps its settings. The new target is selected.
*>
fn bool AppState.land_locks(&self, uint[] dots, String existing)
{
	bool create = existing.len == 0;
	if (!create && dots.len == 0) return false;
	if (!self.prepare_animation_pose()) return false;
	AnimRef ref = self.editing;
	AnimTemplate* clip = self.clip(ref);
	if (!clip || clip.keyframes.len == 0) return false;
	if (!create && aim_target_index_of(clip.aim_targets, existing) < 0) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	float height = view.skeleton.height();
	if (height <= 1.0e-6f) return false;

	// The pose as it is shown, floor and the other targets included.
	rig::Pose pose = self.draft_pose(mem, &view);
	defer pose.free(mem);
	String[] names = self.names_for(&view, ref);
	ground_pose(mem, &view.skeleton, names, clip.ground, &pose, clip.phase_at(self.edit_time));
	self.apply_clip_aims(&view, *clip, ref, self.edit_time, &pose);

	usz count;
	String[] vocabulary = alloc::new_array(tmem, String, (sz)dots.len);
	Vec3[] positions = alloc::new_array(tmem, Vec3, (sz)dots.len);
	Quaternionf[] worlds = alloc::new_array(tmem, Quaternionf, (sz)dots.len);
	uint[] kept = alloc::new_array(tmem, uint, (sz)dots.len);
	foreach (dot : dots)
	{
		sz joint = view.joint_of(dot);
		String name = self.aim_name_of(&view, dot);
		if (joint < 0 || name.len == 0) continue;
		if (!aim_frame(&view, pose, (usz)joint, &positions[count], &worlds[count])) continue;
		vocabulary[count] = name;
		kept[count] = dot;
		count++;
	}
	if (count == 0 && !create) return false;

	Vec3 at; // a fraction of rig height
	String made;
	if (create)
	{
		Vec3 centre;
		Vec3 front = { 0, 0, 1 };
		if (count > 0)
		{
			foreach (point : positions[:count]) centre += point;
			centre = centre / (float)count;
			front = worlds[0].rotate_vec3({ 0, 0, 1 });
			if (front.length_sq() < 1.0e-12f) front = { 0, 0, 1 };
			front = front.normalize();
		}
		else
		{
			// Nothing selected: in front of the root, up about chest height.
			usz root;
			foreach (usz j, parent : view.skeleton.parents) if (parent < 0) { root = j; break; }
			Quaternionf ignored;
			if (!aim_frame(&view, pose, root, &centre, &ignored)) return false;
			centre.y += 0.2f * height;
		}
		at = (centre + front * (AIM_FRONT_REACH * height)) / height;
		made = next_target_name(mem, clip.aim_targets);
	}
	else
	{
		at = self.aim_target_now(clip, existing);
		made = existing.copy(mem);
	}
	defer alloc::free(mem, made.ptr);

	AnimAim[] locks = alloc::new_array(mem, AnimAim, (sz)count);
	foreach (i, &lock : locks)
	{
		Vec3 forward = aim_forward_for(positions[i], worlds[i], height, at);
		sz held = aim_index_of(clip.aims, vocabulary[i]);
		if (held >= 0)
		{
			*lock = clip.aims[(usz)held].copy(mem);
			alloc::free(mem, lock.target.ptr);
			lock.target = made.copy(mem);
			lock.forward = forward;
		}
		else
		{
			*lock = aim_defaults(mem, vocabulary[i], made, forward);
			lock.spread = count == 1 ? 3 : 1;
		}
	}

	AnimTemplate base = create
		? clip_with_aim_target(mem, *clip, aim_target_defaults(mem, made, at, self.edit_time))
		: clip_copy(mem, *clip);
	AnimTemplate built = clip_with_aims_added(mem, base, locks);
	base.free(mem);
	AnimRef landed = self.land_aim_clip(ref, built);
	if (!landed.valid()) return false;

	// The target owns each joint's orientation, so a rotation pin on it goes; its
	// position half stays. Told, because the padlock changes under the user.
	bool dropped;
	foreach (dot : kept[:count])
	{
		if (!self.locks_rotation(dot)) continue;
		self.set_anchor(dot, self.locks_position(dot), false);
		dropped = true;
	}
	self.select_aim_target(made);
	if (dropped)
	{
		self.@notice("locked to look-at target; rotation pins on the locked joints were dropped");
	}
	else if (create)
	{
		self.@notice("look-at target added: drag its ring to aim, Key pose to key it");
	}
	self.refresh_ui();
	return true;
}

<*
 Make a look-at target and lock the selected joints to it in one undo step. It
 goes in front of the joints, along the anchor joint's +Z; with nothing selected
 it goes in front of the rig at about chest height. One joint locks with spread
 3, several with spread 1 each. The new target is selected.

 Needs a clip to edit and, like any pose edit, a paused one.
*>
fn bool AppState.add_aim_target(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	return self.land_locks(self.selected_aim_dots(tmem, &view), "");
}

<*
 Lock every selected joint to the target `target`, in one undo step. Each stays
 where it is: the aim axis is captured from the pose on screen. A joint locked to
 another target is re-pointed and keeps its spread and influence.

 @return `False when there is no clip, no such target or no selected joint.`
*>
fn bool AppState.lock_selection_to(&self, String target)
{
	String held = target.copy(mem);
	defer alloc::free(mem, held.ptr);
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	return self.land_locks(self.selected_aim_dots(tmem, &view), held);
}

// Lock the one joint `dot_id` to `target`, as `lock_selection_to` does for the selection.
fn bool AppState.lock_joint_to(&self, uint dot_id, String target)
{
	String held = target.copy(mem);
	defer alloc::free(mem, held.ptr);
	uint[1] one = { dot_id };
	return self.land_locks(one[:1], held);
}

<*
 Give a joint a look-at target: a new target put in front of it and keyed at the
 edit time, and a lock of the joint on it (spread 3), in one undo step.

 @return `False when there is no clip, no such joint, or the joint has a target already.`
*>
fn bool AppState.add_aim(&self, uint dot_id)
{
	if (self.aim_index(dot_id) >= 0)
	{
		self.@notice("this joint already looks at a target");
		return false;
	}
	uint[1] one = { dot_id };
	return self.land_locks(one[:1], "");
}

<*
 Take the joint's lock off the clip, and its target too when no other joint
 locks to it.
*>
fn bool AppState.remove_aim(&self, uint dot_id)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String name = self.aim_name_of(&view, dot_id).copy(mem);
	defer name.free(mem);
	sz lock = aim_index_of(clip.aims, name);
	if (lock < 0) return false;
	String target = clip.aims[(usz)lock].target.copy(mem);
	defer target.free(mem);
	AnimTemplate built;
	if (aim_target_users(clip.aims, target) <= 1)
	{
		self.forget_aim_draft(target);
		if (self.aim_target_selected == target) self.clear_aim_target();
		built = clip_without_aim_target(mem, *clip, target);
	}
	else
	{
		built = clip_without_aim(mem, *clip, name);
	}
	AnimRef landed = self.land_aim_clip(self.editing, built);
	if (!landed.valid()) return false;
	self.refresh_ui();
	return true;
}

<*
 Take the joint's lock off, keeping its target; one undo step.

 @return `False when the joint is not locked.`
*>
fn bool AppState.unlock_joint(&self, uint dot_id)
{
	uint[1] one = { dot_id };
	return self.unlock_dots(one[:1]);
}

// Unlock every selected joint that is locked, in one undo step.
fn bool AppState.unlock_selection(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	return self.unlock_dots(self.selected_aim_dots(tmem, &view));
}

fn bool AppState.unlock_dots(&self, uint[] dots)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || dots.len == 0) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	AnimTemplate built;
	bool changed;
	foreach (dot : dots)
	{
		String name = self.aim_name_of(&view, dot);
		if (name.len == 0) continue;
		AnimTemplate* from = changed ? &built : clip;
		if (aim_index_of(from.aims, name) < 0) continue;
		AnimTemplate next = clip_without_aim(mem, *from, name);
		if (changed) built.free(mem);
		built = next;
		changed = true;
	}
	if (!changed) return false;
	AnimRef landed = self.land_aim_clip(self.editing, built);
	if (!landed.valid()) return false;
	self.refresh_ui();
	return true;
}

// Silence a whole target, or bring it back; the joints locked to it play their authored motion while muted.
fn bool AppState.set_target_muted(&self, String name, bool muted)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return false;
	sz t = aim_target_index_of(clip.aim_targets, name);
	if (t < 0) return false;
	if (clip.aim_targets[(usz)t].mute == muted) return true;
	AnimAimTarget[] next = aim_targets_copy(mem, clip.aim_targets);
	next[(usz)t].mute = muted;
	AnimRef landed = self.land_aim_clip(self.editing, clip_with_aim_targets(mem, *clip, next));
	if (!landed.valid()) return false;
	self.refresh_ui();
	return true;
}

<*
 Remove the target and every lock on it, forgetting its draft and its selection;
 one undo step.
*>
fn bool AppState.remove_aim_target(&self, String name)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return false;
	if (aim_target_index_of(clip.aim_targets, name) < 0) return false;
	String held = name.copy(mem);
	defer alloc::free(mem, held.ptr);
	self.forget_aim_draft(held);
	AnimRef landed = self.land_aim_clip(self.editing, clip_without_aim_target(mem, *clip, held));
	if (!landed.valid()) return false;
	if (self.aim_target_selected == held) self.clear_aim_target();
	self.refresh_ui();
	return true;
}

// Select the target `name` (copied), the one whose ring is lit and whose menu rows apply.
fn void AppState.select_aim_target(&self, String name)
{
	String held = name.copy(mem);
	self.clear_aim_target();
	self.aim_target_selected = held;
}

// No target selected.
fn void AppState.clear_aim_target(&self)
{
	if (self.aim_target_selected.len > 0) alloc::free(mem, self.aim_target_selected.ptr);
	self.aim_target_selected = "";
}

// A copy of the joint's aim for the caller to change and land, or false.
fn bool AppState.retune_aim(&self, uint dot_id, AnimAim* out)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return false;
	sz at = self.aim_index(dot_id);
	if (at < 0) return false;
	*out = clip.aims[(usz)at].copy(mem);
	return true;
}

fn bool AppState.land_aim(&self, AnimAim changed)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip)
	{
		changed.free(mem);
		return false;
	}
	AnimRef landed = self.land_aim_clip(self.editing, clip_with_aim(mem, *clip, changed));
	if (!landed.valid()) return false;
	self.refresh_ui();
	return true;
}

<*
 How many joints share the turn, the aimed joint and `spread - 1` parents.

 @return `False when the joint has no target, or spread is outside 1 to AIM_MAX_SPREAD.`
*>
fn bool AppState.set_aim_spread(&self, uint dot_id, usz spread)
{
	if (spread < 1 || spread > AIM_MAX_SPREAD) return false;
	AnimAim next;
	if (!self.retune_aim(dot_id, &next)) return false;
	if (next.spread == spread)
	{
		next.free(mem);
		return true;
	}
	next.spread = spread;
	return self.land_aim(next);
}

// How much of the turn the target takes, 0 to 1.
fn bool AppState.set_aim_influence(&self, uint dot_id, float influence)
{
	if (!math::is_finite(influence)) return false;
	AnimAim next;
	if (!self.retune_aim(dot_id, &next)) return false;
	float held = math::clamp(influence, 0.0f, 1.0f);
	if (next.influence == held)
	{
		next.free(mem);
		return true;
	}
	next.influence = held;
	return self.land_aim(next);
}

// Silence the target, or bring it back; the authored motion plays unchanged while muted.
fn bool AppState.set_aim_muted(&self, uint dot_id, bool muted)
{
	AnimAim next;
	if (!self.retune_aim(dot_id, &next)) return false;
	if (next.mute == muted)
	{
		next.free(mem);
		return true;
	}
	next.mute = muted;
	return self.land_aim(next);
}

// ---------------------------------------------------------------------------
// Dragging a target

<*
 Begin dragging the target of `handle`, an index into `posed_aims`. The drag is
 the gesture's usual `DragState` with `dot` the sentinel `AIM_DRAG_DOT` (a target
 may have no joint) and `aim` the handle, so the axis keys, Esc and Enter work as
 for any other; it snapshots no chain and no pins, because only the target moves
 and the rest of the pose is untouched.

 @param held : `The button is down, so the release ends it.`
*>
fn bool AppState.begin_aim_drag(&self, usz handle, bool held = false)
{
	if (self.drag.dot != 0 || handle >= self.posed_aims.len) return false;
	String name = self.posed_aims[handle].target.copy(mem);
	defer alloc::free(mem, name.ptr);
	// Opening the pose rebuilds the handles, so the one grabbed is found again.
	if (!self.prepare_animation_pose()) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	float height = view.skeleton.height();
	if (height <= 1.0e-6f) return false;

	foreach (usz i, grabbed : self.posed_aims)
	{
		if (grabbed.target != name) continue;
		self.aim_drag_drafted = false;
		foreach (draft : self.aim_draft) if (draft.target == name) self.aim_drag_drafted = true;
		self.aim_drag_at = grabbed.at / height;
		self.drag = {
			.dot = AIM_DRAG_DOT,
			.aim = i,
			.from = grabbed.at,
			.axis = DragAxis.FREE,
			.verb = DragVerb.AIM,
			.depth = (grabbed.at - self.model_eye(&self.camera)).length(),
			.held = held,
		};
		return true;
	}
	return false;
}

// The name of the target being dragged, copied (the handles are rebuilt as it
// moves), or empty when no target drag is on.
fn String AppState.aim_drag_target(&self, Allocator allocator)
{
	if (self.drag.verb != DragVerb.AIM || self.drag.aim >= self.posed_aims.len) return "".copy(allocator);
	return self.posed_aims[self.drag.aim].target.copy(allocator);
}

<*
 Move the dragged target to `at_model`, in model units: the draft is set and the
 pose shown again, so the joints locked to it turn toward it at once.
*>
fn void AppState.aim_target_toward(&self, Vec3 at_model)
{
	if (self.drag.dot == 0 || self.drag.verb != DragVerb.AIM) return;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	float height = view.skeleton.height();
	String name = self.aim_drag_target(mem);
	defer name.free(mem);
	if (name.len == 0 || height <= 1.0e-6f) return;
	self.set_aim_draft(name, at_model / height);
	self.refresh_posed();
}

<*
 Escape on a target drag: the draft goes back to what it was at the grab, or
 away when there was none, so history never hears of it.
*>
fn void AppState.cancel_aim_drag(&self)
{
	String name = self.aim_drag_target(mem);
	defer name.free(mem);
	if (name.len > 0)
	{
		if (self.aim_drag_drafted)
		{
			self.set_aim_draft(name, self.aim_drag_at);
		}
		else
		{
			self.forget_aim_draft(name);
		}
	}
	self.drag = {};
	self.refresh_posed();
}

<*
 The release of a target drag: a target that moved is a pending pose edit, keyed
 at once when Auto-key is on. One that finished where it began leaves nothing.
*>
fn void AppState.end_aim_drag(&self)
{
	bool moved;
	String name = self.aim_drag_target(mem);
	defer name.free(mem);
	foreach (draft : self.aim_draft)
	{
		if (draft.target == name && (draft.at - self.aim_drag_at).length_sq() > 1.0e-14f) moved = true;
	}
	if (!moved && !self.aim_drag_drafted && name.len > 0) self.forget_aim_draft(name);
	self.drag = {};
	if (!moved)
	{
		self.refresh_posed();
		return;
	}
	self.pose_edit_pending = true;
	if (self.auto_key)
	{
		(void)self.key_pose_edit(CHANGED);
		self.last_block.shown_at = self.pose_generation;
	}
	else
	{
		self.refresh_ui();
	}
}

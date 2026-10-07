<*
 A pose in hand: copying what the selected joints are doing, and putting it
 down somewhere else — later in the clip, in another clip, or on the other side
 of the body.

 	`app.copy_pose();                 // Ctrl+C over the viewport`
 	`app.paste_pose();                // Ctrl+V: the same joints, at the playhead`
 	`app.paste_pose(flipped: true);   // Ctrl+Shift+V: onto their twins, reflected`
 	`app.mirror_pose();               // Shift+M: the selection reflected in place, no clipboard`

 The dopesheet's clipboard (`animation_clipboard.c3`) carries *saved keys* — a
 column or a channel as it was written, curve and all, and only where a key
 exists. This one carries a *pose*: what the joints are doing at the playhead,
 whether that is a saved key, a point on the curve between two, or a draft the
 user has posed by hand and not yet kept. They are two clipboards on purpose.
 Ctrl+C over the timeline copies keys and Ctrl+C over the viewport copies the
 pose, a text field keeps its own, and each survives the others — copying a
 pose to carry across a clip must not throw away the keys picked up a moment
 ago, or the other way round.

 **Selected joints, or the whole pose when nothing is selected.** A walk is
 posed one limb at a time, and "copy this arm to the other key" is the common
 case; "copy this whole frame" is the other one, and asking for every joint to
 be selected first would make it the harder of the two. Which reading was
 taken is said in the notice.

 **Every paste is one clip edit.** `clip_with_key` merges the pasted channels
 into whatever key is at the playhead — or makes one — and `land_clip` records
 the swap, so one Ctrl+Z takes the whole paste back however many joints it
 carried. An open pose draft survives it: the joints pasted over are re-read
 from the clip so the screen and the key agree, and whatever else the draft
 was holding stays pending.

 Entries are kept in the **rig's own names** rather than a clip's vocabulary, so
 a pose copied out of a Mixamo clip can be pasted into an authored one on the
 same figure; on the way in they are translated to whatever the destination
 clip calls the joint, the same way the key clipboard does. What cannot be
 translated — a rig that has changed underneath, a twin the figure never had —
 is refused or dropped and said, never invented.
*>
module crig;

import rig;
import std::math;

<*
 Copy the pose at the playhead: the selected joints, or all of them.

 Reads the draft when one is open, so what is copied is what is on screen —
 including a gesture nobody has kept yet — and the evaluated clip otherwise,
 through the same limit-aware sample playback and the Joint card use.

 @return `How many joints were copied; zero when nothing was, with the reason as a notice.`
*>
fn usz AppState.copy_pose(&self)
{
	if (!self.clip(self.editing))
	{
		self.@notice("pick an animation to copy a pose from");
		return 0;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("there is no rig to copy a pose from");
		return 0;
	}
	RigView view = opened;
	defer view.free(mem);

	AnimKeyframe pose;
	bool whole;
	if (!self.pose_in_hand(&view, &pose, &whole))
	{
		self.@notice("select named joints to copy their pose");
		return 0;
	}

	self.anim_pose_clipboard.free(mem);
	self.anim_pose_clipboard = pose;
	if (whole)
	{
		self.@notice("Copied the whole pose, %d joints. Choose another time and paste; Ctrl+Shift+V pastes it mirrored.", pose.dots.len);
	}
	else
	{
		self.@notice("Copied the pose of %d selected joint%s. Choose another time and paste; Ctrl+Shift+V pastes it mirrored.",
			pose.dots.len, pose.dots.len == 1 ? "" : "s");
	}
	return pose.dots.len;
}

<*
 Put the copied pose down at the playhead of the clip being edited.

 The joints that were copied, not the ones now selected: the selection chose
 what to pick up, and what is put down is exactly that — which is what lets an
 arm be copied, the other arm selected to look at it, and the copy still land
 where it came from.

 @param flipped : `Reflect the pose across the symmetry plane and paste each joint onto its twin, as keyframe_flipped does. A joint whose twin the rig lacks is left out and counted in the notice.`
 @return `False when nothing was pasted; the notice says why.`
*>
fn bool AppState.paste_pose(&self, bool flipped = false)
{
	if (self.anim_pose_clipboard.dots.len == 0)
	{
		self.@notice("Copy a pose first — Ctrl+C over the viewport copies the selected joints.");
		return false;
	}
	if (!self.clip(self.editing))
	{
		self.@notice("pick an animation to paste the pose into");
		return false;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	usz unmatched;
	AnimKeyframe entries = flipped
		? keyframe_flipped(mem, self.anim_pose_clipboard, view.names, &unmatched)
		: keyframe_copy(mem, self.anim_pose_clipboard);
	if (entries.dots.len == 0)
	{
		entries.free(mem);
		self.@notice("none of the %d copied joints has a twin on this rig to paste onto", self.anim_pose_clipboard.dots.len);
		return false;
	}

	usz landed = self.land_pose(&view, entries);
	if (landed == 0) return false;
	if (flipped)
	{
		if (unmatched > 0)
		{
			self.@notice("Pasted %d joint%s mirrored at %.2fs; %d had no twin on this rig. Undo restores the previous keys.",
				landed, landed == 1 ? "" : "s", self.edit_time, unmatched);
		}
		else
		{
			self.@notice("Pasted the pose mirrored onto %d joint%s at %.2fs. Undo restores the previous keys.",
				landed, landed == 1 ? "" : "s", self.edit_time);
		}
	}
	else
	{
		self.@notice("Pasted the pose of %d joint%s at %.2fs. Undo restores the previous keys.",
			landed, landed == 1 ? "" : "s", self.edit_time);
	}
	return true;
}

<*
 Reflect the selected joints — or the whole pose — across the symmetry plane,
 in place, without touching the clipboard.

 Copy and paste-mirrored in one step, for the case where that is the whole
 job: the left arm is posed, the right one should do the opposite. With both
 sides selected they trade places; with one, its twin takes the reflection and
 the side that was posed stays as it is.

 @return `False when nothing was mirrored; the notice says why.`
*>
fn bool AppState.mirror_pose(&self)
{
	if (!self.clip(self.editing))
	{
		self.@notice("pick an animation to mirror a pose in");
		return false;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	AnimKeyframe pose;
	bool whole;
	if (!self.pose_in_hand(&view, &pose, &whole))
	{
		self.@notice("select named joints to mirror their pose");
		return false;
	}
	usz picked = pose.dots.len;
	usz unmatched;
	AnimKeyframe flipped = keyframe_flipped(mem, pose, view.names, &unmatched);
	pose.free(mem);
	if (flipped.dots.len == 0)
	{
		flipped.free(mem);
		self.@notice("none of the %d joint%s has a twin on this rig to mirror onto", picked, picked == 1 ? "" : "s");
		return false;
	}

	usz landed = self.land_pose(&view, flipped);
	if (landed == 0) return false;
	if (unmatched > 0)
	{
		self.@notice("Mirrored %d joint%s at %.2fs; %d had no twin on this rig. Undo restores the previous keys.",
			landed, landed == 1 ? "" : "s", self.edit_time, unmatched);
	}
	else
	{
		self.@notice("Mirrored the pose of %d joint%s at %.2fs. Undo restores the previous keys.",
			landed, landed == 1 ? "" : "s", self.edit_time);
	}
	return true;
}

// ---------------------------------------------------------------------------

<*
 The pose at the playhead as rig-named entries, cut down to the selection.

 The draft when one is open, the evaluated clip otherwise — the two states
 `animation_pose_ready` covers. `keyframe_of_pose` writes every named joint,
 rest included, and that is wanted: a copied arm hanging at rest should paste
 as an arm at rest, not as an arm nobody mentioned.

 @param whole : `Receives whether the selection was empty and the whole pose taken.`
 @return `False when no named joint was in hand; the output is then nothing to free.`
*>
fn bool AppState.pose_in_hand(&self, RigView* view, AnimKeyframe* out, bool* whole)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip) return false;

	rig::Pose pose = self.pose_edit_active
		? self.draft_pose(mem, view)
		: self.evaluated_clip_pose(mem, view, *clip, self.editing, self.edit_time, false);
	defer pose.free(mem);
	self.lay_clip_holds_over(view, *clip, &pose);
	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	AnimKeyframe every = keyframe_of_pose(mem, pose, view.names, bones,
		view.skeleton.height(), self.edit_time);

	*whole = self.selected == 0;
	if (*whole)
	{
		*out = every;
		return every.dots.len > 0;
	}

	AnimDotList kept;
	kept.init(mem);
	defer kept.free();
	foreach (dot : every.dots)
	{
		bool keep;
		foreach (usz j, name : view.names)
		{
			if (name != dot.joint_name) continue;
			keep = j < view.dot_ids.len && self.is_selected(view.dot_ids[j]);
			break;
		}
		if (keep) { kept.push(dot); }
		else if (dot.joint_name.len > 0) { alloc::free(mem, dot.joint_name.ptr); }
	}
	if (every.dots.len > 0) alloc::free(mem, every.dots);
	*out = { .time = self.edit_time, .dots = kept.to_array(mem) };
	return out.dots.len > 0;
}

<*
 The clip's pins and look-at targets laid over `pose`, as the viewport shows it.

 A hand turned by a target is turned on screen and nowhere in its keys, so what
 is in hand has to be read after the targets or a mirror hands the twin the
 unaimed keys — a hand at rest — instead of what the user posed. The floor is
 solved first because the targets are aimed from where the grounded body stands,
 and its shift is then taken out of the offsets again: the entries keep the
 clip's own, and the floor is solved afresh wherever they land.

 Keying the aimed rotation onto a joint that is itself still aimed costs nothing:
 the target finds it already turned and adds no more.
*>
fn void AppState.lay_clip_holds_over(&self, RigView* view, AnimTemplate clip, rig::Pose* pose)
{
	if (clip.aims.len == 0 && clip.pins.len == 0) return;
	Vec3[] offsets = alloc::new_array(mem, Vec3, pose.offsets.len);
	defer alloc::free(mem, offsets);
	foreach (i, o : pose.offsets) offsets[i] = o;

	String[] names = self.names_for(view, self.editing);
	ground_pose(mem, &view.skeleton, names, clip.ground, pose, clip.phase_at(self.edit_time));
	self.apply_clip_pins(view, clip, self.editing, self.edit_time, pose);
	self.apply_clip_aims(view, clip, self.editing, self.edit_time, pose);
	foreach (i, o : offsets) pose.offsets[i] = o;
}

<*
 Land rig-named entries as keys at the playhead of the clip being edited.

 Translates each entry into the clip's vocabulary, merges it in through
 `clip_with_key` and lands the result — one undo entry. A pose draft that is
 open is parked across the landing, as `key_here` does, and then handed the
 landed values for the joints written so it does not go on showing what the
 clip no longer says.

 `entries` is taken over whether or not anything lands.

 @return `How many joints were written; zero when the paste was refused whole, with the reason as a notice.`
*>
fn usz AppState.land_pose(&self, RigView* view, AnimKeyframe entries)
{
	AnimRef ref = self.editing;
	AnimTemplate* clip = self.clip(ref);
	if (!clip)
	{
		entries.free(mem);
		return 0;
	}
	// A clip with layers: what is pasted is the pose to see, so it goes through
	// the draft and is keyed where the active layer (or the base, under the
	// stack) wants it, not written into the base as a bare key.
	if (clip.layers.len > 0) return self.land_pose_layered(view, entries);
	// Which rig joints this writes, to hand back to the draft afterwards; and
	// the translation itself, refused whole when the rig has moved on since the
	// copy — a pose half pasted is not one anybody asked for.
	bool[] written = alloc::new_array(mem, bool, (sz)view.len());
	defer alloc::free(mem, written);
	if (!self.entries_in_clip_words(view, ref, &entries, written))
	{
		entries.free(mem);
		self.@notice("The copied pose belongs to a different rig; its joints must match.");
		return 0;
	}
	usz count = entries.dots.len;
	entries.time = self.edit_time;

	// The draft belongs to this editing transaction, not to the playback restart
	// that landing a clip performs. Parked, as `key_here` parks it.
	PosedJoint[] draft = self.pose_edit_draft;
	bool active = self.pose_edit_active;
	self.pose_edit_draft = {};
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	AnimRef landed = self.land_clip(ref, clip_with_key(mem, *clip, entries));
	self.pose_edit_draft = draft;
	self.pose_edit_active = active;
	if (!landed.valid())
	{
		self.pose_edit_pending = active && self.pose_edit_differs(ref, self.edit_time);
		return 0;
	}
	self.editing = landed;

	if (!active)
	{
		self.show_edited();
		return count;
	}

	// The joints just written show what the clip now says at this instant —
	// sampled through the same limits as playback, so a pasted turn the rig
	// does not permit is shown clamped, as it will play. Every other joint keeps
	// whatever the draft was holding.
	rig::Pose now = self.evaluated_clip_pose(mem, view, *self.clip(landed), landed,
		self.edit_time, false);
	defer now.free(mem);
	foreach (usz j, uint id : view.dot_ids)
	{
		if (!written[j] || j >= now.rotations.len) continue;
		(void)self.set_working_pose(id, now.rotations[j], now.offsets[j]);
	}
	self.pose_edit_pending = self.pose_edit_differs(landed, self.edit_time);
	self.refresh_posed();
	self.refresh_timeline_tracks(landed);
	self.refresh_ui();
	return count;
}

<*
 Rename rig-named entries into the words clip `ref` uses, marking in `written`
 which rig joints they name.

 @return `False when an entry names no joint of this rig, or one the clip cannot carry; the entries are then partly renamed and only fit to free.`
*>
fn bool AppState.entries_in_clip_words(&self, RigView* view, AnimRef ref, AnimKeyframe* entries, bool[] written)
{
	String[] target_names = self.names_for(view, ref);
	foreach (&dot : entries.dots)
	{
		sz joint = -1;
		foreach (usz j, name : view.names) if (name == dot.joint_name) { joint = (sz)j; break; }
		if (joint < 0 || target_names[joint].len == 0) return false;
		written[joint] = true;
		if (target_names[joint] != dot.joint_name)
		{
			dot.joint_name.free(mem);
			dot.joint_name = target_names[joint].copy(mem);
		}
	}
	return true;
}

<*
 `land_pose` for a clip with layers. The entries are the pose wanted on screen,
 so they are posed into the draft (read through the clip's bare keys, which gives
 what each joint turns to) and then keyed by `key_here`, which writes a delta
 into the active keyed layer or the base minus the layers above it. A generator
 layer has no keys to paste into and is refused before anything changes.

 `entries` is taken over.
*>
fn usz AppState.land_pose_layered(&self, RigView* view, AnimKeyframe entries)
{
	AnimRef ref = self.editing;
	AnimTemplate* clip = self.clip(ref);
	AnimLayer* generated = self.procedural_layer_of(ref);
	if (generated)
	{
		entries.free(mem);
		self.@notice("layer \"%s\" is generated, so it has no keys — choose the base or a keyed layer to paste a pose into", generated.name);
		return 0;
	}
	bool[] written = alloc::new_array(mem, bool, (sz)view.len());
	defer alloc::free(mem, written);
	if (!self.entries_in_clip_words(view, ref, &entries, written))
	{
		entries.free(mem);
		self.@notice("The copied pose belongs to a different rig; its joints must match.");
		return 0;
	}
	usz count = entries.dots.len;
	entries.time = self.edit_time;
	if (!self.prepare_animation_pose())
	{
		entries.free(mem);
		return 0;
	}
	AnimTemplate bare = clip_copy_without_layers(mem, *clip);
	defer bare.free(mem);
	AnimTemplate trial = clip_with_key(mem, bare, entries);
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
	if (!self.pose_edit_pending) return count;
	return self.key_pose_edit(CHANGED) ? count : 0;
}

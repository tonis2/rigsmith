<*
 Editing a clip from the timeline: seeding a pose out of it, keying one back in,
 and landing the result as one undo entry.

 	`app.pose_from_clip(ref, 0.25f);   // scrub here, then pose by hand`
 	`app.key_here(ref, 0.25f);         // and write the pose back into the clip`

 This is the `AppState` half of `anim/keying.c3`. The rewriters there are pure
 clip → clip; everything that needs a rig, a document, a library or an undo stack
 is here.

 **Every edit is a whole-clip replacement.** `put_authored_clip` swaps a clip and
 records `REPLACE_CLIP` for the swap (`app/library.c3`), and `swap_authored_clip`
 is deliberately self-inverse — so building a new `AnimTemplate` and landing it
 is one Ctrl+Z, for free, with no new `EditKind` and no second mutation path. It
 is the reason none of the rewriters mutate in place.

 **Copy-on-edit.** The authored pack is the only one crig writes; every other is
 a file on disk, and rewriting somebody's `biped.glb` because they dragged a key
 is a different operation with a different failure mode and no undo behind it.
 So the first edit to a library clip forks it into the authored pack under its
 own name, says so, and every edit after that lands on the fork.

 **The pose seam.** A sampled clip frame lives in a transient gesture draft,
 keyed by dot id while it is edited and converted back to joint-indexed
 keyframes when saved. It never enters the rig document. Both directions use the same
 `RigView`, so the index-to-id mapping is the build's own.
*>
module crig;

import rig;


import std::math;
import std::math::vector;
import std::core::string;
import std::collections::list;

<*
 Seed a transient pose draft from a clip at `time`, so gestures act on what
 the clip says rather than on rest.

 	`app.pose_from_clip(ref, app.anim_time);`

 The "edit at the playhead" step. Without it, pressing P on a scrubbed clip would
 snap the figure to its bind pose — the clip is drawn from `pose_palette`, and the
 gestures need an editable pose of their own.

 **Ungrounded.** A key records the pose as authored, not as the floor solve left
 it; grounding here would bake the solve into the key and then solve it again at
 playback. `bake_keyframe` samples ungrounded for the same reason.

 **History-free.** Sampling is navigation and never touches the document. Only
 the eventual clip replacement is undoable.

 @return `False when there is no rig, or no such clip.`
*>
fn bool AppState.pose_from_clip(&self, AnimRef ref, float time)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return false;
	// Starting over drops the previous transient draft before sampling another.
	(void)self.discard_pose_edit();

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	rig::Pose pose = self.evaluated_clip_pose(mem, &view, *clip, ref, time, false);
	defer pose.free(mem);

	if (self.pose_edit_draft.len > 0) alloc::free(mem, self.pose_edit_draft);
	self.pose_edit_draft = alloc::new_array(mem, PosedJoint, view.dot_ids.len);
	foreach (usz j, uint id : view.dot_ids)
	{
		if (j >= pose.rotations.len) break;
		self.pose_edit_draft[j] = {
			.dot_id = id,
			.rotation = pose.rotations[j],
			.offset = pose.offsets[j],
		};
	}
	self.pose_edit_active = true;
	self.pose_edit_pending = false;
	self.refresh_posed();
	return true;
}

fn bool AppState.discard_pose_edit(&self)
{
	if (!self.pose_edit_active) return false;
	if (self.pose_edit_draft.len > 0) alloc::free(mem, self.pose_edit_draft);
	self.pose_edit_draft = {};
	self.drop_aim_draft();
	self.drop_gesture_aim();
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	// Put the shown body back where the draft found it, now — not on the trust
	// that whatever called discard will redraw next. A parked clip refreshes from
	// its own keyframes so the overlay stops showing the thrown-away pose; with no
	// clip playing, or none with a keyframe to refresh from, drop the overlay and
	// the mesh returns to rest. Either way the discarded pose leaves the screen.
	if (self.animating && self.current_anim.keyframes.len > 0)
	{
		self.refresh_animation();
	}
	else
	{
		self.drop_palette();
	}
	return true;
}

enum AnimKeyScope
{
	ALL,
	SELECTED,
	CHANGED,
}

fn bool AppState.key_pose_edit(&self, AnimKeyScope scope = ALL)
{
	if (!self.pose_edit_active || !self.editing.valid()) return false;
	float time = self.edit_time;
	AnimRef landed = self.key_here(self.editing, time, scope);
	if (!landed.valid()) return false;
	self.editing = landed;
	self.edit_time = time;
	if (scope == SELECTED && self.pose_edit_differs(landed, self.edit_time))
	{
		self.pose_edit_pending = true;
		self.refresh_posed();
		return true;
	}
	self.discard_pose_edit();
	self.park_clip(landed, self.edit_time);
	return true;
}

fn bool AppState.pose_edit_differs(&self, AnimRef ref, float time)
{
	// A target moved and not yet keyed is a pending edit all the same.
	if (self.aim_draft.len > 0) return true;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return true;
	RigView view = opened;
	defer view.free(mem);
	rig::Pose baseline = self.evaluated_clip_pose(mem, &view, *self.clip(ref), ref,
		time, false);
	defer baseline.free(mem);
	rig::Pose current = self.draft_pose(mem, &view);
	defer current.free(mem);
	foreach (usz j, rotation : current.rotations)
	{
		if (1.0f - math::abs(rotation.v.dot(baseline.rotations[j].v)) > 1.0e-7f
			|| (current.offsets[j] - baseline.offsets[j]).length_sq() > 1.0e-12f) return true;
	}
	return false;
}

fn bool AppState.prepare_timeline_navigation(&self)
{
	bool pending = self.pose_edit_pending;
	bool discarded = self.discard_pose_edit();
	if (discarded && pending) self.@notice("discarded the unkeyed pose");
	return discarded;
}

<*
 The transient animation pose, written down as a keyframe at `time`.

 	`AnimKeyframe key = app.keyframe_here(mem, 0.25f)!;`

	The read half of the seam. `draft_pose` turns the active draft into a
 `rig::Pose` in joint order, and `keyframe_of_pose` does the rest — the same conversion the
 physics bake uses, which is what makes a hand-keyed pose and a baked one
 identical entries.

 The result owns its strings; hand it to `clip_with_key`, which takes it over.

 @return? RIG_EMPTY : `There is no rig to read a pose off.`
*>
fn AnimKeyframe? AppState.keyframe_here(&self, Allocator allocator, float time, AnimRef ref = NO_ANIM, bool rest = false)
{
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);

	rig::Pose pose = rest ? rig::rest_pose(mem, view.len()) : self.draft_pose(mem, &view);
	defer pose.free(mem);

	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);

	// The clip's own vocabulary, not the rig's, so a key written onto a rig named
	// `hips` lands in a pack that spells it `mixamorig:Hips` — the same
	// translation playback reads through. Without it, keying into a borrowed clip
	// would write entries no joint of that pack answers to.
	return keyframe_of_pose(allocator, pose, self.names_for(&view, ref), bones,
		view.skeleton.height(), time);
}

<*
 Land a rewritten clip, forking it out of its library pack first if that is where
 it lives.

 	`AnimRef now = app.land_clip(ref, clip_with_key(mem, *clip, key));`

 The one door every timeline edit goes through, so the fork rule and the undo
 entry are stated once. `built` is taken over: it becomes the authored pack's and
 is freed with it.

 The returned reference is what the panel must hold from then on — a fork moves
 the clip into another pack, so the caller's old reference names the library's
 untouched original.

 @return `NO_ANIM when the clip could not be landed. The template is taken over either way.`
*>
fn AnimRef AppState.land_clip(&self, AnimRef ref, AnimTemplate built)
{
	bool forked = ref.pack != self.authored_pack;
	String source_file = "";
	String source_name = "";
	(void)self.binding_of(ref, &source_file, &source_name);
	sz binding = self.doc.bound_index(source_file, source_name);

	// A library fork must never replace an unrelated authored clip merely
	// because both packs called theirs "Walk". Name the fork uniquely before the
	// authored upsert and carry that name into its binding.
	if (forked && self.clip_named_in_authored(built.name).valid())
	{
		String unique = self.unused_clip_name(mem, built.name);
		if (built.name.len > 0) alloc::free(mem, built.name.ptr);
		built.name = unique;
	}
	String named = built.name.copy(mem);
	defer named.free(mem);

	bool replaced = false;
	AnimRef landed = self.put_authored_clip(built, &replaced);
	if (!landed.valid()) return NO_ANIM;

	// Editing changes what this character exports. Redirect the original bound
	// row in place (preserving its order), or append an authored binding when the
	// source was not bound. Park the other side beside the clip swap so one
	// history transaction restores both.
	bool already_bound = binding >= 0
		&& self.doc.animations[binding].file.len == 0
		&& self.doc.animations[binding].clip == named;
	if (!already_bound)
	{
		sz at = binding >= 0 ? binding : self.doc.animations.len();
		BoundClip parked = self.doc.swap_bound((uint)at, owned_binding("", named));
		self.undo_stack.record_binding_swap((uint)at, parked, owned_binding("", named));
	}
	self.undo_stack.commit();
	self.editing = landed;

	if (forked)
	{
		// Said out loud, because it moves where the clip lives. A user who edits a
		// library clip and later cannot find their change in `biped.glb` was never
		// told it went somewhere else.
		self.@notice("%s now uses a copy you can edit; the library file is unchanged.", named);
	}

	self.refresh_ui();
	return landed;
}

<*
 Start a new clip in the authored pack, holding the pose the rig is in now.

 	`AnimRef ref = app.new_clip("walk", 1.0f);`

 A clip has to begin somewhere, and an empty one is not a thing this format can
 hold: `AnimTemplate.pose` reads a clip with no keyframes as a rig at rest
 forever, and `start_animation` refuses one outright. So a new clip is born with
 a single key at t = 0 carrying whatever the figure is doing — which is also the
 useful default, since the way anyone starts a cycle is to pose the first frame.

 The name is made unique against the authored pack rather than replacing what is
 there: `put_authored_clip` is an upsert, and "New clip" silently overwriting the
 walk somebody was editing is the one thing it must not do.

 The animation workspace passes `from_rest` for a fresh animation independent
 of the displayed clip. Other callers can still explicitly capture a pose.

 `loop` defaults on to keep every existing caller's cyclic clip, but the New
 Animation dialog passes it off: a hand-keyed clip holds its last pose instead
 of blending back to the first, so keying a fall (or any one-shot) can carry
 straight on past the latest key rather than springing back up. The Loop toggle
 beside Auto-key (`anim_loop_toggled`) flips this on the current clip afterwards.

 @return `NO_ANIM when there is no rig to take a pose from.`
*>
fn AnimRef AppState.new_clip(&self, String name, float duration = 1.0f, bool from_preview = false, bool from_rest = false, bool loop = true)
{
	if (from_preview && self.animating && self.current_ref.same(self.editing))
	{
		if (!self.pose_from_clip(self.editing, self.anim_time)) return NO_ANIM;
	}
	if (!from_preview) (void)self.prepare_timeline_navigation();
	AnimKeyframe? key = self.keyframe_here(mem, 0.0f, rest: from_rest);
	if (catch key)
	{
		self.@notice("place a rig first — a clip is a pose over time");
		return NO_ANIM;
	}
	if (from_preview) (void)self.prepare_timeline_navigation();

	String unique = self.unused_clip_name(mem, name.len > 0 ? name : "clip");
	defer unique.free(mem);

	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 1);
	frames[0] = key;

	AnimTemplate built = {
		.name = unique.copy(mem),
		.duration = duration > 0.0f ? duration : 1.0f,
		.keyframes = frames,
		.loop = loop,
		.owned = true,
	};

	// The pack write, the timeline binding and the selection, as one undo step:
	// `author_clip` is this same sequence, shared with the MCP writers so a New
	// clip and an applied clip land as first-class timeline clips the same way.
	AnimRef landed = self.author_clip(built);
	if (!landed.valid()) return NO_ANIM;
	self.refresh_ui();
	return landed;
}

<*
 `name`, or `name_2`, `name_3`… until the authored pack has no clip by it.

 The caller owns the result.
*>
fn String AppState.unused_clip_name(&self, Allocator allocator, String name)
{
	if (!self.clip_named_in_authored(name).valid()) return name.copy(allocator);

	for (uint n = 2; n < 1000; n++)
	{
		String tried = string::format(allocator, "%s_%d", name, n);
		if (!self.clip_named_in_authored(tried).valid()) return tried;
		tried.free(allocator);
	}
	return name.copy(allocator);
}

<*
 The keyframe `key_here` would write at `time` for the draft the document holds,
 without landing it: the sampled pose when parked, else the draft, narrowed by
 `scope` to the channels it names. Empty `dots` when there is nothing to key.
 `ref` must be the clip `clip` points to, with no layer active.

 @param notify : `Say why a narrowed scope keyed nothing.`
 @return `The key; the caller owns it.`
 @return? RIG_EMPTY : `There is no rig to read a pose off.`
*>
fn AnimKeyframe? AppState.draft_key(&self, AnimRef ref, AnimTemplate* clip, float time, AnimKeyScope scope, bool notify)
{
	AnimKeyframe? key;
	bool parked = !self.pose_edit_active && self.animating && self.anim_paused
		&& self.current_ref.same(ref);
	// Key on a parked frame means "make this sampled pose explicit", even when
	// no gesture has opened a draft yet. Reading the sampled player pose here
	// would key an unrelated saved diagnostic pose.
	if (clip.plays_layers())
	{
		// The pose on screen carries the layers; the base gets it with them
		// taken back out, or they would play twice (layer_edit.c3).
		key = self.keyframe_under_layers(ref, clip, time, parked);
	}
	else if (parked)
	{
		RigView view = self.open_rig(mem)!;
		defer view.free(mem);
		rig::Pose sampled = self.evaluated_clip_pose(mem, &view, *clip, ref, time,
			false);
		defer sampled.free(mem);
		Vec3[] bones = view.skeleton.bone_directions(mem);
		defer if (bones.len > 0) alloc::free(mem, bones);
		key = keyframe_of_pose(mem, sampled, self.names_for(&view, ref), bones,
			view.skeleton.height(), time);
	}
	else
	{
		key = self.keyframe_here(mem, time, ref);
	}
	AnimKeyframe written = key!;
	if (written.dots.len == 0) return written;
	if (scope != ALL)
	{
		RigView view = self.open_rig(mem)!!;
		defer view.free(mem);
		String[] names = self.names_for(&view, ref);
		rig::Pose baseline = self.evaluated_clip_pose(mem, &view, *clip, ref, time,
			false);
		defer baseline.free(mem);
		rig::Pose current = self.draft_pose(mem, &view);
		defer current.free(mem);
		AnimDotList filtered;
		filtered.init(mem);
		defer filtered.free();
		foreach (dot : written.dots)
		{
			bool keep = false;
			foreach (usz j, name : names)
			{
				if (name != dot.joint_name || j >= view.dot_ids.len) continue;
				if (scope == SELECTED && self.anim_channel_key_selection.len() > 0
					&& self.anim_key_selection_ref.same(ref))
				{
					bool rotation, translation;
					foreach (selected : self.anim_channel_key_selection)
					{
						if (selected.joint != dot.joint_name) continue;
						if (selected.channel == ROTATION) rotation = true;
						if (selected.channel == TRANSLATION) translation = true;
					}
					keep = rotation || translation;
					dot.channels = rotation && translation ? BOTH
						: (rotation ? ROTATION : TRANSLATION);
				}
				else if (scope == SELECTED) { keep = self.is_selected(view.dot_ids[j]); }
				else
				{
					bool rotation = 1.0f - math::abs(current.rotations[j].v.dot(baseline.rotations[j].v)) > 1.0e-7f;
					bool translation = (current.offsets[j] - baseline.offsets[j]).length_sq() > 1.0e-12f;
					keep = rotation || translation;
					dot.channels = rotation && translation ? BOTH : (rotation ? ROTATION : TRANSLATION);
				}
				break;
			}
			if (keep) { filtered.push(dot); }
			else if (dot.joint_name.len > 0) { alloc::free(mem, dot.joint_name.ptr); }
		}
		if (written.dots.len > 0) alloc::free(mem, written.dots);
		written.dots = filtered.to_array(mem);
		// Nothing left: the caller keys a moved target alone, or says so.
		if (written.dots.len == 0 && notify && self.aim_draft.len == 0)
		{
			self.@notice(scope == SELECTED ? "select joints to key" : "no changed channels to key");
		}
	}
	return written;
}

<*
 Write the pose the document is holding into a clip at `time`.

 	`app.key_here(ref, app.anim_time);`

 ALL keys every named joint, including rest. SELECTED keys both channels of
 selected joints even when unchanged. CHANGED compares the draft with the
 ungrounded sample and keys only changed channels. Same-time insertion merges
 channels through `clip_with_key`; `land_clip` supplies grouped undo and forks
 a library clip on first edit.

 @return `The reference to hold afterwards, or NO_ANIM when nothing was written.`
*>
fn AnimRef AppState.key_here(&self, AnimRef ref, float time, AnimKeyScope scope = ALL)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return NO_ANIM;
	// A layer is active: keying stores a delta into it (layer_edit.c3). A
	// generator holds no keys, so there is nothing to key into.
	AnimLayer* layered = self.active_layer_ptr(ref);
	if (layered)
	{
		// Targets key onto the base clip whichever layer is active: a layer holds
		// poses, and the aim is laid over the whole stack.
		if (layered.kind == KEYED)
		{
			AnimRef keyed = self.key_into_layer(ref, time, scope);
			if (keyed.valid() || self.aim_draft.len == 0) return keyed;
			return self.key_aims_only(ref, time);
		}
		if (self.aim_draft.len > 0) return self.key_aims_only(ref, time);
		self.@notice("layer \"%s\" is generated, so it has no keys — choose the base or a keyed layer to key a pose", layered.name);
		return NO_ANIM;
	}

	AnimKeyframe? drafted = self.draft_key(ref, clip, time, scope, true);
	if (catch drafted)
	{
		self.@notice("there is no rig to key a pose from");
		return NO_ANIM;
	}
	AnimKeyframe written = drafted;
	if (written.dots.len == 0)
	{
		written.free(mem);
		// Only a target moved: it is keyed alone, with nothing said about the pose.
		if (self.aim_draft.len > 0) return self.key_aims_only(ref, time);
		return NO_ANIM;
	}
	// Restarting the watched clip releases draft state. The draft belongs to
	// this editing transaction, not that playback restart; park it while the
	// immutable replacement lands so Selected can retain other pending channels.
	PosedJoint[] draft = self.pose_edit_draft;
	bool active = self.pose_edit_active;
	bool pending = self.pose_edit_pending;
	self.pose_edit_draft = {};
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	// The pose and any moved target land as one entry, so one Ctrl+Z takes back both.
	AnimTemplate keyed = self.with_aim_keys(clip_with_key(mem, *clip, written), time);
	AnimRef landed = self.land_clip(ref, keyed);
	self.pose_edit_draft = draft;
	self.pose_edit_active = active;
	self.pose_edit_pending = pending;
	if (landed.valid()) self.drop_aim_draft();
	if (active) self.refresh_posed();
	return landed;
}

<*
 Key the pending targets at `time` and nothing else: what Key pose does when only
 a target has moved. One undo step on the base clip.
*>
fn AnimRef AppState.key_aims_only(&self, AnimRef ref, float time)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return NO_ANIM;
	AnimRef landed = self.land_aim_clip(ref, self.with_aim_keys(clip_copy(mem, *clip), time));
	if (landed.valid()) self.drop_aim_draft();
	if (self.pose_edit_active) self.refresh_posed();
	return landed;
}

// ---------------------------------------------------------------------------
// What the dopesheet draws

<*
 One row of the dopesheet: a joint the clip drives, and where it has keys.

 The times are a *copy* rather than a view into the clip, because the clip is
 replaced wholesale by every edit and a widget borrows its rows for the life of
 its element — a slice into the old template would be pointing at freed
 keyframes the moment anything was dragged.
*>
struct TimelineTrack
{
	String joint; // borrowed from the clip, rebuilt with the rows
	float[] times; // owned; union retained for the simple pose-row UI
	float[] rotation_times; // owned
	float[] translation_times; // owned
	// How far below the rig's root this joint hangs, for the sheet to indent
	// by; zero for a joint the rig does not have.
	uint depth;
}

<*
 Rebuild the dopesheet's tracks for a clip.

 One row per joint the clip names anywhere, ordered as the **rig's tree** reads
 where the rig has the joint — each joint followed by everything under it, so
 a biped's sheet runs hips, spine, chest, neck, head, then one arm to its
 fingers, then the other — with the joint's depth recorded so the sheet can
 indent it. A tree read that way is a tree; the builder's own breadth-first
 order, which puts every thigh and shoulder on one level and every knee and
 elbow on the next, is not. Joints the rig does not have go last: they are
 what the clip drives and this figure cannot, which is worth seeing rather than
 hiding.
*>
fn void AppState.refresh_timeline_tracks(&self, AnimRef ref)
{
	self.free_timeline_tracks();

	// Showing a clip's keys in the timeline is editing it — read its curves first
	// if it was a deferred stub.
	self.ensure_clip_imported(ref);
	// The active keyed layer's keys when there is one (see `key_clip`).
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip) return;

	// Every joint named anywhere in the clip, in first-seen order to start with.
	StringList named;
	named.init(mem);
	defer named.free();

	foreach (frame : clip.keyframes)
	{
		foreach (dot : frame.dots)
		{
			bool seen = false;
			foreach (have : named.array_view())
			{
				if (have == dot.joint_name) { seen = true; break; }
			}
			if (!seen) named.push(dot.joint_name);
		}
	}
	if (named.len() == 0) return;

	// Re-ordered by the rig, when there is one to order by.
	String[] order = named.array_view();
	RigView? opened = self.open_rig(mem);
	StringList sorted;
	sorted.init(mem);
	defer sorted.free();
	List{uint} depths;
	depths.init(mem);
	defer depths.free();

	if (try RigView view = opened)
	{
		defer view.free(mem);
		String[] words = self.clip_names(&view);
		// The tree, read root first and each subtree whole: the builder's joints
		// are parents-before-children, so a stack of "next child to visit" per
		// joint walks it without recursion. Children come in joint order, which
		// is the order the builder found them in.
		usz count = view.skeleton.len();
		usz[] stack = alloc::new_array(mem, usz, (sz)count);
		uint[] depth = alloc::new_array(mem, uint, (sz)count);
		defer alloc::free(mem, stack);
		defer alloc::free(mem, depth);
		usz top;
		for (usz root = 0; root < count; root++)
		{
			if (view.skeleton.parents[root] >= 0) continue;
			stack[top++] = root;
			while (top > 0)
			{
				usz joint = stack[--top];
				String word = joint < words.len ? words[joint] : "";
				if (word.len > 0)
				{
					foreach (have : order)
					{
						if (have != word) continue;
						sorted.push(have);
						depths.push(depth[joint]);
						break;
					}
				}
				// Pushed last-first so the first child is visited next.
				for (usz child = count; child-- > joint + 1;)
				{
					if (view.skeleton.parents[child] != (int)joint) continue;
					depth[child] = depth[joint] + 1;
					stack[top++] = child;
				}
			}
		}
		// Then whatever the clip drives that this rig has no joint for.
		foreach (have : order)
		{
			bool placed = false;
			foreach (already : sorted.array_view())
			{
				if (already == have) { placed = true; break; }
			}
			if (!placed)
			{
				sorted.push(have);
				depths.push(0);
			}
		}
		order = sorted.array_view();
	}

	self.timeline_tracks = alloc::new_array(mem, TimelineTrack, (sz)order.len);
	foreach (usz i, joint : order)
	{
		usz count = 0;
		usz rotations, translations;
		foreach (frame : clip.keyframes)
		{
			if (frame.names(joint)) count++;
			if (frame.has_channel(joint, ROTATION)) rotations++;
			if (frame.has_channel(joint, TRANSLATION)) translations++;
		}

		float[] times = alloc::new_array(mem, float, (sz)count);
		float[] rotation_times = alloc::new_array(mem, float, (sz)rotations);
		float[] translation_times = alloc::new_array(mem, float, (sz)translations);
		usz write = 0;
		usz rotation_write, translation_write;
		foreach (frame : clip.keyframes)
		{
			if (frame.names(joint)) times[write++] = frame.time;
			if (frame.has_channel(joint, ROTATION)) rotation_times[rotation_write++] = frame.time;
			if (frame.has_channel(joint, TRANSLATION)) translation_times[translation_write++] = frame.time;
		}
		self.timeline_tracks[i] = { .joint = joint, .times = times,
			.rotation_times = rotation_times, .translation_times = translation_times,
			.depth = i < (usz)depths.len() ? depths[(sz)i] : 0 };
	}
}

fn void AppState.free_timeline_tracks(&self)
{
	foreach (track : self.timeline_tracks)
	{
		if (track.times.len > 0) alloc::free(mem, track.times);
		if (track.rotation_times.len > 0) alloc::free(mem, track.rotation_times);
		if (track.translation_times.len > 0) alloc::free(mem, track.translation_times);
	}
	if (self.timeline_tracks.len > 0) alloc::free(mem, self.timeline_tracks);
	self.timeline_tracks = {};
}

<*
 Whether the open rig has a joint the clip would address by this name.

 What a dimmed lane means: the clip drives this joint and the figure on screen
 has nothing to answer to it. Asked through `clip_names`, not through the dots,
 because that is the vocabulary playback matches against — a rig named `hips`
 playing a pack that spells it `mixamorig:Hips` answers to the pack's spelling
 and to nothing else.
*>
fn bool AppState.rig_answers_to(&self, String joint)
{
	if (joint.len == 0) return false;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);

	foreach (word : self.clip_names(&view))
	{
		if (word == joint) return true;
	}
	return false;
}

<*
 The keyframe index nearest `time`, or -1 when the clip has none within a
 tolerance.

 What a click on the ruler resolves to, and what a drag moves. `ANIM_SAME_TIME`
 is too tight for a pointer — it is the "same instant" rule, not the "near
 enough to grab" one — so this takes a window from the caller, which is the
 widget's pixels turned into seconds.
*>
fn sz AppState.key_near(&self, AnimRef ref, float time, float within)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip) return -1;

	sz best = -1;
	float closest = within;
	foreach (usz i, frame : clip.keyframes)
	{
		float gap = math::abs(frame.time - time);
		if (gap <= closest)
		{
			closest = gap;
			best = (sz)i;
		}
	}
	return best;
}

<*
 Settle on a clip to edit when nothing is chosen.

 The Animations pane calls this as it builds. A pane that came up saying "pick an
 animation" over a character with four of them asks for a click that has only one
 sensible answer — and the first bound clip is the one an export puts first, so
 it is the one to open on.

 A choice already made is left alone, including one whose clip has since gone: a
 binding that stops resolving is a thing to *see* in the list, and quietly
 sliding the sheet onto a different animation would hide it.

 @return `True when this settled on something it had not been editing.`
*>
fn bool AppState.default_editing(&self)
{
	if (self.editing.valid()) return false;

	for (sz i = 0; i < self.doc.animations.len(); i++)
	{
		AnimRef ref = self.resolve_bound(i);
		if (!ref.valid()) continue;

		self.editing = ref;
		self.edit_time = 0.0f;
		// The implicit first selection follows the same rule as choosing a row:
		// show its first frame, so the regular viewport is immediately poseable.
		(void)self.park_clip(ref, 0.0f);
		return true;
	}
	return false;
}

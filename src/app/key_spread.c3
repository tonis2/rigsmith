<*
 Keying one pose edit onto many keys at once.

 Where an edit lands is the Apply to switch in the Animations dock (`key_reach`):

 - **This frame**: the playhead only, through `key_here`.
 - **Selected keys**: every key picked in the sheet, when at least two are and
   the playhead is anywhere from the first of them to the last. No key is added
   at the playhead itself. Keys just outside the selection take a fading share.
 - **Whole clip**: every key of the clip, or of the active keyed layer. Nothing
   needs to be picked.

 Whichever it is, a keyed edit — K, Auto-key, the banner's Key pose, a typed
 joint value — adds the turn and slide it made at the playhead to each key's own
 value (`clip_with_offset`), so the motion through the keys is kept and shifted
 rather than flattened to one pose. The whole change is one undo step.

 The edit is measured on screen, as the change from what the clip played at the
 playhead to the pose made there, and composed into the keys the timeline shows:
 the base clip's, or the active keyed layer's. That is exact for a clip authored
 on this rig and a joint no other layer turns, which is the same assumption
 `keyframe_under_layers` makes.
*>
module crig;

import std::math;
import rig;
import std::collections::list;
import std::sort;

<*
 The times picked in the sheet for `ref`, whole keys and channel keys together,
 sorted and distinct. Target keys are not pose keys and do not count.
*>
fn void AppState.selected_key_times(&self, AnimRef ref, AnimFloatList* into)
{
	if (!self.anim_key_selection_ref.same(ref)) return;
	foreach (time : self.anim_key_selection) into.push(time);
	foreach (selected : self.anim_channel_key_selection) into.push(selected.time);
	// Sorted first, so a time picked twice — a whole key and a channel key of it —
	// sits beside itself, and the whole selection of a long take stays cheap.
	sort::quicksort(into.array_view());
	sz kept = 0;
	foreach (time : *into)
	{
		if (kept > 0 && math::abs((*into)[kept - 1] - time) < ANIM_SAME_TIME) continue;
		(*into)[kept++] = time;
	}
	while (into.len() > kept) into.remove_last();
}

<*
 Where a keyed pose edit goes; see the file's header.
*>
enum KeyReach
{
	FRAME,
	SELECTED_KEYS,
	WHOLE_CLIP,
}

<*
 The key times a pose keyed at `time` would land on under `key_reach`, sorted
 and distinct; nothing when it keys the playhead alone.

 Selected keys need at least two picked and the playhead inside their span —
 the span rather than the keys themselves, as on a dense clip a scrubbed
 playhead lands a millisecond beside a key far more often than on one, and an
 edit made there is still an edit to the range picked around it.
*>
fn void AppState.reach_key_times(&self, AnimRef ref, float time, AnimFloatList* into)
{
	if (!ref.valid()) return;
	switch (self.key_reach)
	{
		case FRAME:
			return;
		case SELECTED_KEYS:
			if (self.picked_keys_around(ref, time) == 0) return;
			self.selected_key_times(ref, into);
		case WHOLE_CLIP:
			// A generated layer holds no keys; `key_here` says so.
			AnimLayer* layered = self.active_layer_ptr(ref);
			if (layered && layered.kind != KEYED) return;
			AnimTemplate* clip = self.key_clip(ref);
			if (!clip) return;
			foreach (frame : clip.keyframes) into.push(frame.time);
	}
}

<*
 How many keys are picked in the sheet for `ref` with `time` inside their span,
 or 0 when fewer than two are or the playhead is outside them. Whatever the
 switch says: the dock reads it to point at Selected keys.
*>
fn usz AppState.picked_keys_around(&self, AnimRef ref, float time)
{
	if (!ref.valid() || !self.anim_key_selection_ref.same(ref)) return 0;
	AnimFloatList times;
	times.init(tmem);
	self.selected_key_times(ref, &times);
	if (times.len() < 2) return 0;
	if (time < times[0] - ANIM_SAME_TIME || time > times[times.len() - 1] + ANIM_SAME_TIME) return 0;
	return (usz)times.len();
}

<*
 How many keys a pose keyed at `time` would land on: the length of
 `reach_key_times`, 0 for the playhead alone.
*>
fn usz AppState.spread_key_count(&self, AnimRef ref, float time)
{
	AnimFloatList times;
	times.init(tmem);
	self.reach_key_times(ref, time, &times);
	return (usz)times.len();
}

<*
 Key the pose edit made at `time` onto the keys of `ref` at `times`, as one undo
 step, and keep the selection for the next edit.

 	`AnimRef landed = app.key_onto_keys(app.editing, app.edit_time, times, CHANGED);`

 Only the joints the edit changed get an offset, and only in the channels it
 changed. SELECTED narrows them further, as it does for one key: to the joints
 and channels of selected channel keys, or else to the joints selected on the
 model. With nothing changed this is `key_here`, which keys a moved target alone.

 @param times : `Key times from reach_key_times: sorted, distinct, not empty.`
 @return `The reference to hold afterwards, or NO_ANIM when nothing was written.`
*>
fn AnimRef AppState.key_onto_keys(&self, AnimRef ref, float time, float[] times, AnimKeyScope scope = CHANGED)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return NO_ANIM;
	// A generated layer holds no keys, which `key_here` says.
	AnimLayer* layered = self.active_layer_ptr(ref);
	if (layered && layered.kind != KEYED) return self.key_here(ref, time, scope);

	RigView? opened = self.open_rig(mem);
	if (catch opened) return self.key_here(ref, time, scope);
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	float height = view.skeleton.height();
	rig::Pose baseline = self.evaluated_clip_pose(mem, &view, *clip, ref, time, false);
	defer baseline.free(mem);
	rig::Pose current = self.draft_pose(mem, &view);
	defer current.free(mem);

	bool by_channel = scope == SELECTED && self.anim_channel_key_selection.len() > 0;
	List{KeyOffset} offsets;
	offsets.init(mem);
	defer offsets.free();
	bool turns, moves;
	foreach (usz j, rotation : current.rotations)
	{
		if (j >= baseline.rotations.len || j >= names.len || j >= view.dot_ids.len) break;
		if (names[j].len == 0) continue;
		bool turned = 1.0f - math::abs(rotation.v.dot(baseline.rotations[j].v)) > 1.0e-7f;
		bool moved = (current.offsets[j] - baseline.offsets[j]).length_sq() > 1.0e-12f;
		if (by_channel)
		{
			turned = turned && self.channel_key_selected(names[j], ROTATION);
			moved = moved && self.channel_key_selected(names[j], TRANSLATION);
		}
		else if (scope == SELECTED && !self.is_selected(view.dot_ids[j]))
		{
			continue;
		}
		if (!turned && !moved) continue;
		offsets.push({
			.joint = names[j],
			.rotates = turned,
			.turn = baseline.rotations[j].invert().mul(rotation).normalize(),
			.moves = moved,
			.move = height > 0.0f ? (current.offsets[j] - baseline.offsets[j]) / height : (Vec3){},
		});
		turns |= turned;
		moves |= moved;
	}
	if (offsets.len() == 0) return self.key_here(ref, time, scope);

	// The selection by value: landing lets it go, and it is put back afterwards so
	// the next turn lands on the same keys.
	float[] whole = self.anim_key_selection.to_tarray();
	AnimChannelKey[] channels = self.anim_channel_key_selection.to_tarray();
	foreach (&selected : channels) selected.joint = selected.joint.tcopy();
	String joint = offsets[0].joint.tcopy();
	usz joint_count = (usz)offsets.len();

	usz faded;
	AnimTemplate built = clip_with_offset(mem, *self.key_clip(ref), offsets.array_view(),
		times, KEY_OFFSET_FADE, &faded);
	// A moved target keys onto the base, at the playhead only.
	if (!layered) built = self.with_aim_keys(built, time);

	// Parked across the landing for the reason `key_here` gives.
	PosedJoint[] draft = self.pose_edit_draft;
	bool active = self.pose_edit_active;
	bool pending = self.pose_edit_pending;
	self.pose_edit_draft = {};
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	bool forked = ref.pack != self.authored_pack;
	AnimRef landed = self.land_key_edit(ref, built);
	self.pose_edit_draft = draft;
	self.pose_edit_active = active;
	self.pose_edit_pending = pending;
	if (!landed.valid()) return NO_ANIM;
	if (!layered) self.drop_aim_draft();
	if (active) self.refresh_posed();

	self.restart_key_selection(landed);
	foreach (selected : whole) self.select_time(selected);
	foreach (selected : channels) self.select_channel(selected.time, selected.joint, selected.channel);
	self.settle_key_selection();

	// A fork's notice says where the change went, which matters more.
	if (forked) return landed;
	String verb = turns && moves ? "Posed" : (turns ? "Turned" : "Moved");
	String subject = joint_count == 1 ? joint : string::tformat("%d joints", joint_count);
	String edges = faded > 0 ? string::tformat(" (%d more faded at the edges)", faded) : "";
	String keys = self.key_reach == WHOLE_CLIP ? string::tformat("all %d keys", times.len)
		: string::tformat("%d selected keys", times.len);
	self.@notice("%s %s on %s%s · Ctrl+Z undoes it", verb, subject, keys, edges);
	return landed;
}

// Whether a selected channel key names `joint` on `channel`.
fn bool AppState.channel_key_selected(&self, String joint, AnimChannels channel)
{
	foreach (selected : self.anim_channel_key_selection)
	{
		if (selected.joint == joint && selected.channel == channel) return true;
	}
	return false;
}

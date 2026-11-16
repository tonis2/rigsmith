<*
 Held props as commands: put one in a hand, place it, size it, take it away, and
 grip it with the other hand. Each is one undo step unless it says it leaves the
 group open for a slider; the maths is `algo/pose/held_prop.c3`.
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;

// Whether the joint is a hand a prop can be put in (`rig_arm_wrists`).
fn bool AppState.is_hand(&self, uint dot_id)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	sz j = view.joint_of(dot_id);
	if (j < 0) return false;
	bool[] hands = rig_arm_wrists(mem, &view.skeleton, view.names);
	defer alloc::free(mem, hands);
	return hands[(usz)j];
}

<*
 Put a prop of `kind` in the hand, where it sits by default, as one undo step.

 @return "False when the dot is not a joint of the rig"
*>
fn bool AppState.hold_prop(&self, uint dot_id, PropKind kind)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	sz j = view.joint_of(dot_id);
	if (j < 0) return false;
	return self.place_prop(default_prop(&view.skeleton, view.names, (usz)j, dot_id, kind));
}

<*
 Replace the hand's prop with `prop` (length 0 takes it away), as one undo step.

 @return "False when nothing changed"
*>
fn bool AppState.place_prop(&self, HeldProp prop)
{
	if (prop.held()) prop.length = math::clamp(prop.length, PROP_MIN_LENGTH, PROP_MAX_LENGTH);
	if (!self.set_prop_recorded(prop)) return false;
	self.undo_stack.commit();
	self.refresh_ui();
	return true;
}

// Takes the prop out of the hand, as one undo step.
fn bool AppState.drop_prop(&self, uint dot_id) => self.place_prop({ .dot_id = dot_id, .turn = quaternion::IDENTITY });

<*
 Set the hand's prop length (a fraction of the rig's height) and leave the undo
 group open, so a slider's drag lands as one step when it commits.

 @return "False when the hand holds nothing or nothing changed"
*>
fn bool AppState.size_prop(&self, uint dot_id, float length)
{
	HeldProp prop = self.doc.prop_of(dot_id);
	if (!prop.held()) return false;
	prop.length = math::clamp(length, PROP_MIN_LENGTH, PROP_MAX_LENGTH);
	if (!self.set_prop_recorded(prop)) return false;
	self.refresh_ui();
	return true;
}

<*
 Change the hand's prop to `kind` where it sits, at that kind's length, as one
 undo step. A hand holding nothing gets one where it sits by default.

 @return "False when the dot is not a joint of the rig or nothing changed"
*>
fn bool AppState.retype_prop(&self, uint dot_id, PropKind kind)
{
	HeldProp prop = self.doc.prop_of(dot_id);
	if (!prop.held()) return self.hold_prop(dot_id, kind);
	if (prop.kind == kind) return false;
	prop.kind = kind;
	prop.length = kind.default_length();
	return self.place_prop(prop);
}

<*
 The prop's turn as XYZ Euler degrees (`euler_of`), each in -180..180. Returns
 `near` itself while it still names that turn, so a slider set from it doesn't
 jump to the twin reading.
*>
fn Vec3 AppState.prop_angles(&self, uint dot_id, Vec3 near = {})
{
	Quaternionf turn = self.doc.prop_of(dot_id).turn;
	if (turn.v.length_sq() < 1.0e-12f) return {};
	turn = turn.normalize();
	if (math::abs(quat_of_euler(near).v.dot(turn.v)) > 1.0f - 1.0e-6f) return near;
	Vec3 angles = euler_of(turn, near);
	// The nearest reading may sit a full turn past the sliders' range.
	for (usz i = 0; i < 3; i++) angles[i] -= 360.0f * math::round(angles[i] / 360.0f);
	return angles;
}

<*
 Set where the hand's prop sits: `offset` a fraction of the rig's height in the
 joint's rest axes, turned by the XYZ Euler `angles` in degrees. Leaves the undo
 group open, so a slider's drag lands as one step when it commits.

 @return "False when the hand holds nothing or nothing changed"
*>
fn bool AppState.set_prop_placement(&self, uint dot_id, Vec3 offset, Vec3 angles)
{
	HeldProp prop = self.doc.prop_of(dot_id);
	if (!prop.held()) return false;
	prop.offset = offset;
	prop.turn = quat_of_euler(angles);
	if (!self.set_prop_recorded(prop)) return false;
	self.refresh_ui();
	return true;
}

<*
 Put the hand's prop back where a new one sits (`default_prop`), keeping its
 kind and length, as one undo step.

 @return "False when the hand holds nothing, isn't a joint of the rig, or the prop is already there"
*>
fn bool AppState.reset_prop_placement(&self, uint dot_id)
{
	HeldProp prop = self.doc.prop_of(dot_id);
	if (!prop.held()) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	sz j = view.joint_of(dot_id);
	if (j < 0) return false;
	HeldProp fresh = default_prop(&view.skeleton, view.names, (usz)j, dot_id, prop.kind);
	prop.offset = fresh.offset;
	prop.turn = fresh.turn;
	return self.place_prop(prop);
}

<*
 The rig's other hands (`rig_arm_wrists`), in joint order: the ones that could
 grip the prop `holder` carries.

 @return "Their dot ids, owned by the caller; empty without a rig"
*>
fn uint[] AppState.grip_hands(&self, Allocator allocator, uint holder)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);
	bool[] hands = rig_arm_wrists(mem, &view.skeleton, view.names);
	defer alloc::free(mem, hands);
	usz count;
	foreach (usz j, hand : hands) if (hand && j < view.dot_ids.len && view.dot_ids[j] != holder) count++;
	if (count == 0) return {};
	uint[] out = alloc::new_array(allocator, uint, (sz)count);
	usz n;
	foreach (usz j, hand : hands) if (hand && j < view.dot_ids.len && view.dot_ids[j] != holder) out[n++] = view.dot_ids[j];
	return out;
}

<*
 Fill the Attachment panel's grip choice with `holder`'s other hands, and keep
 its support hand among them: the twin when it has none yet, else the first.
*>
fn void AppState.list_attachment_hands(&self, uint holder)
{
	self.free_attachment_hands();
	uint[] ids = self.grip_hands(mem, holder);
	if (ids.len == 0)
	{
		self.attachment_support = 0;
		return;
	}
	self.attachment_hand_ids = ids;
	self.attachment_hand_names = alloc::new_array(mem, String, (sz)ids.len);
	bool kept;
	foreach (usz i, id : ids)
	{
		Dot* dot = self.doc.find(id);
		self.attachment_hand_names[i] = (dot && dot.name.len > 0 ? dot.name : "unnamed").copy(mem);
		if (id == self.attachment_support) kept = true;
	}
	if (kept) return;
	uint twin = self.mirror_twin(holder);
	self.attachment_support = ids[0];
	foreach (id : ids) if (id == twin) self.attachment_support = twin;
}

fn void AppState.free_attachment_hands(&self)
{
	foreach (name : self.attachment_hand_names) alloc::free(mem, name.ptr);
	if (self.attachment_hand_names.len > 0) alloc::free(mem, self.attachment_hand_names);
	if (self.attachment_hand_ids.len > 0) alloc::free(mem, self.attachment_hand_ids);
	self.attachment_hand_names = {};
	self.attachment_hand_ids = {};
}

<*
 Hold `support` where it is now on the prop `holder` carries, over the whole
 clip being edited: a pin held relative to the prop hand, its position and angle.
 One undo step, which replaces the support hand's other pins on the clip.

 @return "False when there is no clip, no prop, or the grip would not land"
*>
fn bool AppState.grip_prop(&self, uint support, uint holder)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip)
	{
		self.@notice("open a clip to grip in: the grip is a pin of the clip");
		return false;
	}
	if (!self.doc.prop_of(holder).held())
	{
		self.@notice("the other hand holds no prop to grip");
		return false;
	}
	if (!self.set_clip_pin(support, true, true, 0.0f, clip.duration, 0.0f, relative_dot: holder)) return false;
	self.sync_clip_pins();
	return true;
}

<*
 The joint the editing clip's pin on `dot_id` is held on, or 0 for none: what a
 gripping hand's card names.
*>
fn uint AppState.gripped_on(&self, uint dot_id)
{
	AnimPin* pin = self.clip_pin_of(dot_id);
	if (!pin || !pin.relative()) return 0;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, self.editing);
	foreach (usz k, name : names) if (k < view.dot_ids.len && name == pin.relative_to) return view.dot_ids[k];
	return 0;
}

<*
 Clip pins as the editor's pins: while a clip is being edited, its pins ARE the
 gesture pins in `position_locks` (`locks.c3`).

 **One source of truth.** The clip owns the pins (`anim/pin.c3`); `position_locks`
 is only the view of them the gestures read, rebuilt by `sync_clip_pins` from the
 pins whose window covers `edit_time`. So a pin outside its window does not steer
 a gesture there — which is the same as it not holding in playback — and undo and
 redo restore both at once, because they restore the clip and the sync follows.
 Every way of toggling a pin goes through `set_anchor`, which writes the clip when
 one is edited (`set_clip_pin`) and lands it as one undo step like the look-at
 ops (`land_aim_clip`). With no clip open nothing here acts and the pins stay
 session-only as `locks.c3` describes.

 **Where the held point lives.** The clip stores it as a fraction of rig height
 (`AnimPin.at`); the gestures hold a model-space point, so the sync scales by the
 rig's height both ways.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

// The blend a fresh clip pin eases in and out with, seconds, before it is clamped to the clip.
const float CLIP_PIN_BLEND = 0.1f;

// Whether the pin's window covers `time`, a looping clip's wrap-around included.
fn bool pin_covers(AnimPin* pin, float time, float duration, bool loop) @local
{
	if (pin.mute || !(pin.position || pin.rotation) || !(pin.to >= pin.from)) return false;
	if (time >= pin.from && time <= pin.to) return true;
	if (!loop || duration <= 0.0f) return false;
	return (time + duration >= pin.from && time + duration <= pin.to)
		|| (time - duration >= pin.from && time - duration <= pin.to);
}

<*
 Whether the editor's pins are the clip's right now: a clip is open for editing.
*>
fn bool AppState.clip_pins_drive(&self)
{
	return self.editing.valid() && self.clip(self.editing) != null;
}

// Whether a pin on this joint would be the clip's: a clip is edited and the clip
// can name the joint. An unnamed joint keeps a session pin.
fn bool AppState.clip_pins(&self, uint dot_id)
{
	if (!self.clip_pins_drive()) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	return self.aim_name_of(&view, dot_id).len > 0;
}

<*
 Rebuild `position_locks` from the editing clip's pins that cover `edit_time`.

 Called whenever the clip, the time or the history moves (`land_clip`,
 `refresh_posed`, `refresh_animation` while paused, `stepped_history`, the start
 of a pose gesture). Left alone mid-gesture, so a pin is not swapped under a drag,
 and while the clip plays. Derived fields (`residual`, `loose`, ...) carry over
 for a pin that stays, and a list that comes out unchanged is not reallocated.
 When the clip closes, the pins it drove are dropped so they do not linger as
 session pins of a clip that is gone.
*>
fn void AppState.sync_clip_pins(&self)
{
	if (self.drag.dot != 0) return;
	if (!self.clip_pins_drive())
	{
		if (self.pins_from_clip)
		{
			self.clear_position_locks();
			self.pins_from_clip = false;
		}
		return;
	}
	if (self.animating && !self.anim_paused) return;

	AnimTemplate* clip = self.clip(self.editing);
	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, self.editing);
	float height = view.skeleton.height();

	PositionLock[] next = alloc::new_array(mem, PositionLock, (sz)(clip.pins.len + self.position_locks.len));
	usz count;
	foreach (&pin : clip.pins)
	{
		if (!pin_covers(pin, self.edit_time, clip.duration, clip.loop)) continue;
		sz joint = -1;
		foreach (usz j, name : names) if (j < view.dot_ids.len && name == pin.joint) { joint = (sz)j; break; }
		if (joint < 0) continue;
		uint id = view.dot_ids[(usz)joint];
		PositionLock lock = { .dot_id = id, .target = pin.at * height, .orient = pin.orient,
			.position = pin.position, .rotation = pin.rotation };
		sz held = self.lock_index(id);
		if (held >= 0)
		{
			PositionLock old = self.position_locks[(usz)held];
			lock.residual = old.residual;
			lock.turn_residual = old.turn_residual;
			lock.yielded = old.yielded;
			lock.loose = old.loose;
		}
		next[count++] = lock;
	}
	// A joint the clip cannot name (no name on the dot) cannot be a clip pin, so a
	// session pin on it stays as it is.
	foreach (old : self.position_locks)
	{
		sz joint = view.joint_of(old.dot_id);
		if (joint < 0 || (usz)joint >= names.len || names[(usz)joint].len > 0) continue;
		next[count++] = old;
	}
	self.pins_from_clip = true;

	bool same = count == self.position_locks.len;
	for (usz i = 0; same && i < count; i++)
	{
		PositionLock a = self.position_locks[i];
		PositionLock b = next[i];
		same = a.dot_id == b.dot_id && a.position == b.position && a.rotation == b.rotation
			&& a.target == b.target && a.orient.v == b.orient.v;
	}
	if (same || count == 0)
	{
		alloc::free(mem, next);
		if (!same) self.clear_position_locks();
		return;
	}
	PositionLock[] kept = alloc::new_array(mem, PositionLock, (sz)count);
	foreach (i, lock : next[:count]) kept[i] = lock;
	alloc::free(mem, next);
	if (self.position_locks.len > 0) alloc::free(mem, self.position_locks);
	self.position_locks = kept;
}

<*
 Set which halves of the dot's clip pin are on, and optionally its window, as one
 undo step; the pin is made (whole clip, `CLIP_PIN_BLEND`) when it has none and
 removed when neither half is left.

 A half switched on captures the joint's held point or orientation from the pose on
 screen; a half that stays on keeps what the pin has. A negative `from`, `to` or
 `blend` leaves that value as it is. The window is kept inside the clip.

 @return `False when there is no clip, no such joint, or the clip would not land.`
*>
fn bool AppState.set_clip_pin(&self, uint dot_id, bool position, bool rotation, float from = -1.0f, float to = -1.0f, float blend = -1.0f)
{
	AnimTemplate* clip = self.clip(self.editing);
	Dot* dot = self.doc.find(dot_id);
	if (!clip || !dot) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String name = self.aim_name_of(&view, dot_id).copy(mem);
	defer name.free(mem);
	if (name.len == 0) return false;
	float height = view.skeleton.height();
	if (height <= 1.0e-6f) return false;

	sz at = pin_index_of(clip.pins, name);
	if (!position && !rotation)
	{
		if (at < 0) return true;
		return self.land_aim_clip(self.editing, clip_without_pin(mem, *clip, name)).valid();
	}

	// A look-at target owns the joint's orientation: the angle half is refused, the
	// position half still allowed.
	bool was_rotating = at >= 0 && clip.pins[(usz)at].rotation;
	if (rotation && !was_rotating && self.aim_index(dot_id) >= 0)
	{
		self.@notice("a look-at target steers this joint's rotation - remove the target to pin its angle");
		rotation = false;
		if (!position) return false;
	}

	AnimPin pin = at >= 0
		? clip.pins[(usz)at].copy(mem)
		: pin_defaults(mem, name, {}, 0.0f, clip.duration);
	if (at < 0) pin.blend = CLIP_PIN_BLEND;
	bool was_holding = at >= 0 && clip.pins[(usz)at].position;
	if (position && !was_holding) pin.at = self.dot_position(*dot) / height;
	if (rotation && !was_rotating) pin.orient = self.dot_world_rotation(dot_id);
	pin.position = position;
	pin.rotation = rotation;
	if (from >= 0.0f) pin.from = math::min(from, clip.duration);
	if (to >= 0.0f) pin.to = math::min(to, clip.duration);
	if (pin.to < pin.from)
	{
		// The end that was not asked for gives way.
		if (from >= 0.0f && to < 0.0f) { pin.to = pin.from; } else { pin.from = pin.to; }
	}
	if (blend >= 0.0f) pin.blend = blend;
	pin.blend = math::min(pin.blend, clip.duration);

	AnimTemplate built = clip_with_pin(mem, *clip, pin);
	AnimRef landed = self.land_aim_clip(self.editing, built);
	if (!landed.valid()) return false;
	self.refresh_ui();
	return true;
}

<*
 Move the clip pin's held point and orientation to where its joint now stands,
 after a grab that carried the joint itself. One undo step of its own — the move's
 key (Auto-key) is a separate step, since the pose key and the pin live in two
 landings. A pin with neither half left changes nothing.
*>
fn void AppState.refresh_clip_pin_target(&self, uint dot_id)
{
	AnimTemplate* clip = self.clip(self.editing);
	Dot* dot = self.doc.find(dot_id);
	if (!clip || !dot) return;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);
	String name = self.aim_name_of(&view, dot_id).copy(mem);
	defer name.free(mem);
	sz at = name.len > 0 ? pin_index_of(clip.pins, name) : -1;
	float height = view.skeleton.height();
	if (at < 0 || height <= 1.0e-6f) return;

	AnimPin pin = clip.pins[(usz)at].copy(mem);
	if (pin.position) pin.at = self.dot_position(*dot) / height;
	if (pin.rotation) pin.orient = self.dot_world_rotation(dot_id);
	(void)self.land_aim_clip(self.editing, clip_with_pin(mem, *clip, pin));
}

<*
 Drop every pin the editor holds: the clip's when a clip is edited (one undo
 step), and the session's otherwise. What Clear all does. Not `clear_position_locks`
 itself, which a document load and a rescale call to forget session state and must
 not rewrite a clip.
*>
fn void AppState.clear_editor_pins(&self)
{
	AnimTemplate* clip = self.clip_pins_drive() ? self.clip(self.editing) : null;
	if (clip)
	{
		if (clip.pins.len > 0) (void)self.land_aim_clip(self.editing, clip_copy_without_pins(mem, *clip));
		return;
	}
	self.clear_position_locks();
}

<*
 The editing clip's pin on this joint, or null. Borrowed from the clip: copy what
 is needed before landing anything.
*>
fn AnimPin* AppState.clip_pin_of(&self, uint dot_id)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || clip.pins.len == 0) return null;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return null;
	RigView view = opened;
	defer view.free(mem);
	String name = self.aim_name_of(&view, dot_id);
	if (name.len == 0) return null;
	sz at = pin_index_of(clip.pins, name);
	return at >= 0 ? &clip.pins[(usz)at] : null;
}

<*
 Change one pin's window or blend (seconds; a negative value leaves it) as one
 undo step, keeping what it holds.

 @return `False when the joint has no clip pin.`
*>
fn bool AppState.set_clip_pin_window(&self, uint dot_id, float from, float to, float blend)
{
	AnimPin* pin = self.clip_pin_of(dot_id);
	if (!pin) return false;
	bool position = pin.position;
	bool rotation = pin.rotation;
	return self.set_clip_pin(dot_id, position, rotation, from, to, blend);
}

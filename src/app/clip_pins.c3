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
import std::collections::list;
import std::math;
import std::math::matrix;
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
 and while the clip plays. Derived fields (`residual`, `turn_residual`) carry over
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
		PositionLock lock = { .dot_id = id, .target = pin.held_at(self.edit_time, clip.duration, clip.loop) * height, .orient = pin.orient,
			.position = pin.position, .rotation = pin.rotation };
		sz held = self.lock_index(id);
		if (held >= 0)
		{
			PositionLock old = self.position_locks[(usz)held];
			lock.residual = old.residual;
			lock.turn_residual = old.turn_residual;
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
 Which of the clip's pins on `name` an edit of the joint's pin means: the one
 under the playhead, else one overlapping the window asked for, else — with no
 window asked for — the joint's first. -1 when it has none of them, which is a new
 pin.
*>
fn sz AppState.clip_pin_index(&self, AnimTemplate* clip, String name, float from = -1.0f, float to = -1.0f)
{
	sz at = pin_index_at(clip.pins, name, self.edit_time, clip.duration, clip.loop);
	if (at >= 0) return at;
	if (from >= 0.0f && to >= 0.0f) return pin_index_overlapping(clip.pins, name, from, to);
	if (from < 0.0f && to < 0.0f) return pin_index_of(clip.pins, name);
	return -1;
}

<*
 Set which halves of the dot's clip pin are on, and optionally its window, as one
 undo step; the pin is made (whole clip, `CLIP_PIN_BLEND`) when it has none and
 removed when neither half is left. The pin is the one under the playhead when the
 joint holds several (`clip_pin_index`); a window that reaches over another of the
 joint's pins takes its place.

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

	sz at = self.clip_pin_index(clip, name, from, to);
	if (!position && !rotation)
	{
		if (at < 0) return true;
		return self.land_aim_clip(self.editing, clip_without_pin_at(mem, *clip, at)).valid();
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
	// After the window, which the travel is measured from.
	if (position && !was_holding) pin.at = self.pin_origin(&pin, self.dot_position(*dot) / height);
	if (rotation && !was_rotating) pin.orient = self.dot_world_rotation(dot_id);

	AnimTemplate built = clip_with_pin_at(mem, *clip, at, pin);
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
	sz at = name.len > 0 ? self.clip_pin_index(clip, name) : -1;
	float height = view.skeleton.height();
	if (at < 0 || height <= 1.0e-6f) return;

	AnimPin pin = clip.pins[(usz)at].copy(mem);
	if (pin.position) pin.at = self.pin_origin(&pin, self.dot_position(*dot) / height);
	if (pin.rotation) pin.orient = self.dot_world_rotation(dot_id);
	(void)self.land_aim_clip(self.editing, clip_with_pin_at(mem, *clip, at, pin));
}

<*
 Where a pin has to start for its joint to be held at `here` (a fraction of the
 rig's height) at the playhead: `here` itself for a pin that stands still, and
 `here` less the slide since the window opened for one that travels.
*>
fn Vec3 AppState.pin_origin(&self, AnimPin* pin, Vec3 here)
{
	return here - pin.travel * math::max(0.0f, self.edit_time - pin.from);
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
 The editing clip's pin on this joint — the one under the playhead when it holds
 several — or null. Borrowed from the clip: copy what is needed before landing
 anything.
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
	sz at = self.clip_pin_index(clip, name);
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

<*
 Change the window or blend of the editing clip's pin at `index` (seconds; a
 negative value leaves it), as one undo step, keeping what it holds. What a pin
 bar on the sheet does: a bar is one pin, whichever joint it is on and however
 many that joint has. A window dragged over another of the joint's pins takes its
 place.

 @return `False when there is no such pin, or the clip would not land.`
*>
fn bool AppState.set_clip_pin_window_at(&self, usz index, float from, float to, float blend)
{
	AnimTemplate* clip = self.clip(self.editing);
	if (!clip || index >= clip.pins.len) return false;
	AnimPin pin = clip.pins[index].copy(mem);
	if (from >= 0.0f) pin.from = math::min(from, clip.duration);
	if (to >= 0.0f) pin.to = math::min(to, clip.duration);
	if (pin.to < pin.from) pin.to = pin.from;
	if (blend >= 0.0f) pin.blend = math::min(blend, clip.duration);
	AnimRef landed = self.land_aim_clip(self.editing, clip_with_pin_at(mem, *clip, (sz)index, pin));
	if (!landed.valid()) return false;
	self.refresh_ui();
	return true;
}

// ---------------------------------------------------------------------------
// Feet held on the floor

// The blend a foot pin eases in and out with by default, seconds: short, since a
// foot lands quickly, and never more than half its window.
const float FOOT_PIN_BLEND = 0.05f;
// Instants across a window a foot pin's hold is measured at.
const usz FOOT_PIN_PROBES = 9;

// One window a foot is pinned over, in seconds. `joint` is borrowed.
struct FootWindow
{
	String joint;
	float from;
	float to;
}

// One pin `pin_clip_feet` wrote, and how near its foot stayed to it: the worst
// distance over the window, as a fraction of the rig's height. `joint` is borrowed
// from the landed clip.
struct FootPinReport
{
	String joint;
	float from;
	float to;
	float residual;
}

<*
 Hold feet on the floor over windows of a clip, as live clip pins, one undo step.

 	`FootPinReport[] done = app.pin_clip_feet(ref, { "ankle_L", "ankle_R" }, {}, true, 0.05f, true, {}, &why)!;`

 What `plant_feet` baked into keys, done the way the editor's pins are: each
 window becomes a pin on its joint that bends the leg live while the clip plays,
 so it can be moved, re-timed, muted or cleared afterwards, and bakes into keys
 only on export. Every pin the joints had is replaced.

 - **Windows** are given, or with `auto` read off the clip: its ground spec's
   windows for each joint, or — for a joint the spec does not name — every run
   the joint spends down (`derived_contacts`), a jump's takeoff and its landing
   apart.
 - **Where** a foot is held is where the clip has it when the window opens, on the
   floor: its height is its rest height, which is where the modeller stood it,
   carried with the spec's floor when one is set.
 - **Grounded**: a clip with no ground spec gets the pinned windows as its
   contacts, so the floor solve brings the body down to where the feet can reach.
 - **Flat** holds the foot's angle too, turned only about the vertical from rest,
   so the sole stays on the ground however the clip tilts it.
 - **Travel** is the speed an in-place body is not really moving at, model units
   a second: a held foot runs back by it, which is a treadmill cycle. With
   `travel_auto` it is read off the clip: how fast the feet move along the floor,
   on average, while they are down — what a generated cycle, whose travel the
   importer took off, leaves its stance feet doing.

 @param travel : `The body's velocity the clip leaves out, model units a second; a held foot slides by its negative.`
 @param travel_auto : `Read the travel off the feet instead.`
 @param measured : `Receives the travel used, model units a second, if given.`
 @param why : `Receives the reason on refusal.`
 @return `One report per pin written, on the temp allocator.`
*>
fn FootPinReport[]? AppState.pin_clip_feet(
	&self,
	AnimRef ref,
	String[] joints,
	FootWindow[] windows,
	bool auto,
	float blend,
	bool flat,
	Vec3 travel,
	DString* why,
	bool travel_auto = false,
	Vec3* measured = null)
{
	if (!self.ensure_clip_imported(ref) || !self.clip(ref))
	{
		why.append_string("that clip cannot be read");
		return PINS_REFUSED~;
	}
	AnimTemplate clip = *self.clip(ref);
	if (clip.duration <= 0.0f)
	{
		why.append_string("the clip has no length to pin feet over");
		return PINS_REFUSED~;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		why.append_string("there is no rig to pin feet on");
		return PINS_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	float height = view.skeleton.height();
	if (height <= 1.0e-6f)
	{
		why.append_string("the rig has no height");
		return PINS_REFUSED~;
	}

	usz[] at_joint = alloc::new_array(tmem, usz, (sz)joints.len);
	foreach (usz k, joint : joints)
	{
		sz found = -1;
		foreach (usz j, name : names) if (j < view.skeleton.len() && name == joint) { found = (sz)j; break; }
		if (found < 0)
		{
			why.appendf("the clip has no joint called %s on this rig", joint)!!;
			return PINS_REFUSED~;
		}
		at_joint[k] = (usz)found;
	}

	// The windows, in seconds: given, or the clip's own.
	FootWindowList asked;
	asked.init(tmem);
	if (auto)
	{
		AnimGround derived;
		defer derived.free(mem);
		bool read = false;
		foreach (joint : joints)
		{
			sz before = asked.len();
			foreach (foot : clip.ground.feet)
			{
				if (foot.joint != joint || foot.off_floor) continue;
				asked.push(foot_window_seconds(joint, foot, clip));
			}
			if (asked.len() > before) continue;
			if (!read)
			{
				derived = derived_contacts(&view.skeleton, names, clip, every_run: true);
				read = true;
			}
			foreach (foot : derived.feet) if (foot.joint == joint) asked.push(foot_window_seconds(joint, foot, clip));
		}
	}
	else
	{
		foreach (window : windows) asked.push(window);
	}
	if (asked.len() == 0)
	{
		why.append_string(auto
			? "found no time the feet are down: the clip has no ground spec for them and they never rest near the floor. Give windows by hand."
			: "no windows to pin over");
		return PINS_REFUSED~;
	}

	// The treadmill, read off the feet: how far each moves along the floor across
	// its window, over how long the window is, averaged by time.
	if (travel_auto)
	{
		Vec3 moved;
		float spent = 0.0f;
		foreach (window : asked)
		{
			usz j = (usz)-1;
			foreach (usz k, joint : joints) if (joint == window.joint) j = at_joint[k];
			float span = window.to - window.from;
			if (j == (usz)-1 || span <= 1.0e-4f) continue;
			// Inside the window by its blend, where the foot is down rather than landing.
			float edge = math::min(blend, span * 0.25f);
			Vec3 a = self.clip_joint_at(&view, clip, ref, j, window.from + edge);
			Vec3 b = self.clip_joint_at(&view, clip, ref, j, window.to - edge);
			moved += (Vec3){ b.x - a.x, 0.0f, b.z - a.z };
			spent += span - 2.0f * edge;
		}
		travel = spent > 0.0f ? -moved / spent : (Vec3){};
	}
	if (measured) *measured = travel;

	// The floor the spec sets, against the one its contacts rest on.
	float floor_shift = 0.0f;
	if (clip.ground.floor_set)
	{
		usz[16] contact;
		bool[16] down;
		GroundContacts found = ground_contacts(&view.skeleton, names, clip.ground, 0.0f, contact[..], down[..]);
		if (found.count > 0)
		{
			float rest = view.skeleton.joints[contact[0]].y;
			for (usz i = 1; i < found.count; i++) rest = math::min(rest, view.skeleton.joints[contact[i]].y);
			floor_shift = clip.ground.floor - rest;
		}
	}

	AnimPinList next;
	next.init(mem);
	defer next.free();
	foreach (&held : clip.pins)
	{
		bool foot = false;
		foreach (joint : joints) if (held.joint == joint) foot = true;
		if (!foot) next.push(held.copy(mem));
	}
	usz first_new = (usz)next.len();

	foreach (window : asked)
	{
		usz j = (usz)-1;
		foreach (usz k, joint : joints) if (joint == window.joint) j = at_joint[k];
		if (j == (usz)-1)
		{
			why.appendf("a window names %s, which is not one of the joints being pinned", window.joint)!!;
			free_pin_list(&next);
			return PINS_REFUSED~;
		}
		float from = math::clamp(window.from, 0.0f, clip.loop ? clip.duration * 2.0f : clip.duration);
		float to = math::clamp(window.to, from, clip.loop ? clip.duration * 2.0f : clip.duration);
		float opens = clip.loop && from >= clip.duration ? from - clip.duration : from;

		rig::Pose pose = self.evaluated_clip_pose(mem, &view, clip, ref, opens);
		defer pose.free(mem);
		Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
		if (catch built) continue;
		defer alloc::free(mem, built);
		Vec3 where = view.skeleton.joints[j].transform(built[j]);
		where.y = view.skeleton.joints[j].y + floor_shift;

		AnimPin pin = pin_defaults(mem, names[j], where / height, from, to);
		pin.blend = math::min(blend, (to - from) * 0.5f);
		pin.travel = -travel / height;
		if (flat)
		{
			Quaternionf[]? world = pose.world_rotations(mem, &view.skeleton);
			if (try world)
			{
				Quaternionf turned = world[j];
				Quaternionf yaw = { 0.0f, turned.v.y, 0.0f, turned.v.w };
				pin.orient = yaw.v.length_sq() > 1.0e-12f ? yaw.normalize() : quaternion::IDENTITY;
				pin.rotation = true;
				alloc::free(mem, world);
			}
		}
		// A window that runs into one already written on this joint is dropped: a
		// joint holds one pin at a time.
		bool clash = false;
		for (usz i = first_new; i < (usz)next.len(); i++)
		{
			if (next[(sz)i].joint == pin.joint && pins_overlap(next.get_ref((sz)i), &pin)) clash = true;
		}
		if (clash)
		{
			pin.free(mem);
			continue;
		}
		next.push(pin);
	}

	AnimPin[] pins = next.len() > 0 ? next.to_array(mem) : (AnimPin[]){};
	next.clear();
	AnimTemplate pinned = clip_with_pins(mem, clip, pins);
	// A pin bends the leg; only the floor solve lowers the body. A clip with no
	// ground spec floats where it was generated, often a few centimetres up, and a
	// leg cannot stretch that far — so the windows pinned become its contacts too.
	if (!clip.ground.solves())
	{
		AnimFoot[] feet = alloc::new_array(mem, AnimFoot, (sz)(pinned.pins.len - first_new));
		for (usz i = first_new; i < pinned.pins.len; i++)
		{
			AnimPin* pin = &pinned.pins[i];
			float down = pin.from / clip.duration;
			float up = pin.to / clip.duration;
			if (clip.loop && up > 1.0f) up -= 1.0f;
			feet[i - first_new] = { .joint = pin.joint.copy(mem), .down = down, .up = math::min(up, 1.0f) };
		}
		pinned.ground.free(mem);
		pinned.ground = { .feet = feet };
	}
	AnimRef landed = self.land_aim_clip(ref, pinned);
	if (!landed.valid())
	{
		why.append_string("the pinned clip would not land");
		return PINS_REFUSED~;
	}
	if (ref.same(self.editing) || !self.editing.valid()) self.editing = landed;
	self.sync_clip_pins();
	self.refresh_ui();

	// How near each new pin held, measured on the clip as it now plays.
	AnimTemplate* now = self.clip(landed);
	FootPinReport[] out = alloc::new_array(tmem, FootPinReport, (sz)(now.pins.len - first_new));
	for (usz i = first_new; i < now.pins.len; i++)
	{
		AnimPin* pin = &now.pins[i];
		usz j = 0;
		foreach (usz k, name : names) if (name == pin.joint) { j = k; break; }
		float worst = 0.0f;
		for (usz p = 0; p < FOOT_PIN_PROBES; p++)
		{
			float t = pin.from + (pin.to - pin.from) * (float)p / (float)(FOOT_PIN_PROBES - 1);
			// Only where the pin holds fully: the blends are meant to let go.
			if (pin.weight_at(t, now.duration, now.loop) < 0.999f) continue;
			float shown = now.loop && t >= now.duration ? t - now.duration : math::min(t, now.duration);
			rig::Pose pose = self.evaluated_clip_pose(mem, &view, *now, landed, shown, aimed: true);
			defer pose.free(mem);
			Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
			if (catch built) continue;
			defer alloc::free(mem, built);
			Vec3 foot = view.skeleton.joints[j].transform(built[j]);
			worst = math::max(worst, (foot - pin.held_at(shown, now.duration, now.loop) * height).length() / height);
		}
		out[i - first_new] = { .joint = pin.joint, .from = pin.from, .to = pin.to, .residual = worst };
	}
	return out;
}

<*
 Take every pin off these joints of a clip, as one undo step.

 @return `How many pins came off.`
*>
fn usz AppState.unpin_clip_joints(&self, AnimRef ref, String[] joints)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return 0;
	AnimPinList kept;
	kept.init(mem);
	defer kept.free();
	foreach (&held : clip.pins)
	{
		bool going = false;
		foreach (joint : joints) if (held.joint == joint) going = true;
		if (!going) kept.push(held.copy(mem));
	}
	usz gone = clip.pins.len - (usz)kept.len();
	if (gone == 0) return 0;
	AnimPin[] pins = kept.len() > 0 ? kept.to_array(mem) : (AnimPin[]){};
	kept.clear();
	AnimRef landed = self.land_aim_clip(ref, clip_with_pins(mem, *clip, pins));
	if (landed.valid() && ref.same(self.editing)) self.editing = landed;
	self.sync_clip_pins();
	self.refresh_ui();
	return gone;
}

// A ground window in seconds. One that wraps the loop point runs past the end,
// which a looping clip's pin window reaches round (`AnimPin.weight_at`).
fn FootWindow foot_window_seconds(String joint, AnimFoot foot, AnimTemplate clip) @local
{
	float from = foot.down * clip.duration;
	float up = foot.up > foot.down ? foot.up : foot.up + (clip.loop ? 1.0f : 0.0f);
	return { .joint = joint, .from = from, .to = math::max(from, up * clip.duration) };
}

fn void free_pin_list(AnimPinList* list) @local
{
	foreach (&pin : *list) pin.free(mem);
	list.clear();
}

alias FootWindowList = List{FootWindow};
alias AnimPinList = List{AnimPin};

// Where joint `j` stands in the clip at `time`, model space: limits and the ground
// solve applied, pins not. A time past the end of a looping clip wraps round.
fn Vec3 AppState.clip_joint_at(&self, RigView* view, AnimTemplate clip, AnimRef ref, usz j, float time)
{
	if (clip.loop && clip.duration > 0.0f) time = time - math::floor(time / clip.duration) * clip.duration;
	rig::Pose pose = self.evaluated_clip_pose(mem, view, clip, ref, math::clamp(time, 0.0f, clip.duration));
	defer pose.free(mem);
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return view.skeleton.joints[j];
	defer alloc::free(mem, built);
	return view.skeleton.joints[j].transform(built[j]);
}

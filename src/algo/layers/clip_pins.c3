<* The pure half of src/app/clip_pins.c3: no state, undo or notices. *>
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
fn bool pin_covers(AnimPin* pin, float time, float duration, bool loop)
{
	if (pin.mute || !(pin.position || pin.rotation) || !(pin.to >= pin.from)) return false;
	if (time >= pin.from && time <= pin.to) return true;
	if (!loop || duration <= 0.0f) return false;
	return (time + duration >= pin.from && time + duration <= pin.to)
		|| (time - duration >= pin.from && time - duration <= pin.to);
}

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

// A ground window in seconds. One that wraps the loop point runs past the end,
// which a looping clip's pin window reaches round (`AnimPin.weight_at`).
fn FootWindow foot_window_seconds(String joint, AnimFoot foot, AnimTemplate clip)
{
	float from = foot.down * clip.duration;
	float up = foot.up > foot.down ? foot.up : foot.up + (clip.loop ? 1.0f : 0.0f);
	return { .joint = joint, .from = from, .to = math::max(from, up * clip.duration) };
}

alias FootWindowList = List{FootWindow};

alias AnimPinList = List{AnimPin};

fn void free_pin_list(AnimPinList* list)
{
	foreach (&pin : *list) pin.free(mem);
	list.clear();
}

<*
 Each joint's windows read off the clip: its ground spec's, or every run the joint
 spends down when the spec does not name it.

 @param [&inout] out : `Receives the windows, in seconds.`
*>
fn void foot_windows_of(FootWindowList* out, rig::Skeleton* skeleton, String[] names, AnimTemplate clip, String[] joints)
{
	AnimGround derived;
	defer derived.free(mem);
	bool read = false;
	foreach (joint : joints)
	{
		sz before = out.len();
		foreach (foot : clip.ground.feet)
		{
			if (foot.joint != joint || foot.off_floor) continue;
			out.push(foot_window_seconds(joint, foot, clip));
		}
		if (out.len() > before) continue;
		if (!read)
		{
			derived = derived_contacts(skeleton, names, clip, every_run: true);
			read = true;
		}
		foreach (foot : derived.feet) if (foot.joint == joint) out.push(foot_window_seconds(joint, foot, clip));
	}
}

// The floor the spec sets, against the one its contacts rest on.
fn float pin_floor_shift(rig::Skeleton* skeleton, String[] names, AnimGround ground)
{
	if (!ground.floor_set) return 0.0f;
	usz[16] contact;
	bool[16] down;
	GroundContacts found = ground_contacts(skeleton, names, ground, 0.0f, contact[..], down[..]);
	if (found.count == 0) return 0.0f;
	float rest = skeleton.joints[contact[0]].y;
	for (usz i = 1; i < found.count; i++) rest = math::min(rest, skeleton.joints[contact[i]].y);
	return ground.floor - rest;
}

<*
 A pin holding joint `j` where `pose` has it, on the floor.

 @param floor_shift : `From pin_floor_shift.`
 @param travel : `The body's velocity the clip leaves out, model units a second.`
 @param flat : `Hold the foot's angle too, turned only about the vertical.`
 @return? rig::POSE_SIZE_MISMATCH : `The pose doesn't fit the skeleton.`
*>
fn AnimPin? foot_pin_at(Allocator allocator, rig::Skeleton* skeleton, rig::Pose pose, usz j, String name, float from, float to,
	float floor_shift, float blend, Vec3 travel, bool flat)
{
	float height = skeleton.height();
	Matrix4f[] built = rig::joint_palette(mem, skeleton, pose)!;
	defer alloc::free(mem, built);
	Vec3 where = skeleton.joints[j].transform(built[j]);
	where.y = skeleton.joints[j].y + floor_shift;

	AnimPin pin = pin_defaults(allocator, name, where / height, from, to);
	pin.blend = math::min(blend, (to - from) * 0.5f);
	pin.travel = -travel / height;
	if (flat)
	{
		Quaternionf[]? world = pose.world_rotations(mem, skeleton);
		if (try world)
		{
			Quaternionf turned = world[j];
			Quaternionf yaw = { 0.0f, turned.v.y, 0.0f, turned.v.w };
			pin.orient = yaw.v.length_sq() > 1.0e-12f ? yaw.normalize() : quaternion::IDENTITY;
			pin.rotation = true;
			alloc::free(mem, world);
		}
	}
	return pin;
}

<*
 Pinned windows as ground contacts, for a clip with no ground spec.

 @return `Owned by the caller.`
*>
fn AnimFoot[] pins_as_feet(Allocator allocator, AnimPin[] pins, AnimTemplate clip)
{
	AnimFoot[] feet = alloc::new_array(allocator, AnimFoot, (sz)pins.len);
	foreach (i, &pin : pins)
	{
		float down = pin.from / clip.duration;
		float up = pin.to / clip.duration;
		if (clip.loop && up > 1.0f) up -= 1.0f;
		feet[i] = { .joint = pin.joint.copy(allocator), .down = down, .up = math::min(up, 1.0f) };
	}
	return feet;
}

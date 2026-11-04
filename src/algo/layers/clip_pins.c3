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

<* The pure half of src/app/animation_key_selection.c3: no state, undo or notices. *>
module crig;

import std::sort;
import std::math;

struct AnimChannelKey
{
	float time;
	String joint; // owned
	AnimChannels channel; // ROTATION or TRANSLATION, never BOTH
}

<*
 One look-at target key picked in the sheet: the aim's target (owned, as the clip
 spells it) and where along the clip. Never mixed with pose keys; see
 `select_animation_aim_key`.
*>
struct AimKeyRef
{
	String target; // owned
	float time;
}

// Asks `channel_dot`, which reads past a rotation-only entry to a move-only
// one for the same joint: a key may hold the two halves as separate dots.
fn bool AnimKeyframe.has_channel(self, String joint, AnimChannels channel)
{
	AnimKeyDot found;
	return self.channel_dot(joint, channel == ROTATION, &found);
}

<*
 Where a retime sends a key: scaled about `anchor`, then shifted by `delta`. A
 plain move is scale 1, which adds the delta exactly.
*>
struct KeyRetime
{
	float anchor;
	float scale;
	float delta;
}

fn float KeyRetime.map(self, float t)
	=> self.scale == 1.0f ? t + self.delta : self.anchor + (t - self.anchor) * self.scale + self.delta;

fn bool KeyRetime.identity(self) => self.scale == 1.0f && math::abs(self.delta) < ANIM_SAME_TIME;

fn int by_key_time(AnimKeyframe a, AnimKeyframe b) => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0);

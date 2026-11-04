<* The pure half of src/app/cast.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

<*
 Where in its own clip a character is at scene time `t`: wrapped when the clip
 loops, held at the ends when it does not.
*>
fn float clip_local_time(AnimTemplate* clip, float t)
{
	if (!clip || clip.duration <= 0.0f) return 0.0f;
	if (t <= 0.0f) return 0.0f;
	if (clip.loop) return t - math::floor(t / clip.duration) * clip.duration;
	return math::min(t, clip.duration);
}

<* Two poses of one rig mixed, as a cross-fade from one clip into another mixes them. *>
module crig;

import rig;
import std::math;

<*
 `into` mixed from `from` by `weight` (0 is `from`, 1 is `into`): each rotation the short way round,
 each offset in a straight line. A joint `keyed` leaves false takes `from` whole, as a clip fading
 in leaves alone a bone it does not animate.

 @param [&inout] into : "The pose fading in; it becomes the mix"
 @param keyed : "One flag a joint, or empty for all of them"
 @require from.rotations.len == into.rotations.len && from.offsets.len == into.offsets.len : "Poses of one rig"
 @require keyed.len == 0 || keyed.len == into.rotations.len : "One flag a joint"
*>
fn void blend_poses(rig::Pose* into, rig::Pose from, float weight, bool[] keyed = {})
{
	float w = math::clamp(weight, 0.0f, 1.0f);
	foreach (usz j, &r : into.rotations)
	{
		bool fades = keyed.len == 0 || keyed[j];
		*r = fades ? slerp_short(from.rotations[j], *r, w) : from.rotations[j];
		into.offsets[j] = fades ? from.offsets[j] + (into.offsets[j] - from.offsets[j]) * w : from.offsets[j];
	}
}

<* The pure half of src/app/pose.c3: no state, undo or notices. *>
module crig;

import rig;
import gltf;
import std::math;
import std::math::matrix;
import std::collections::list;

<*
 A bone as the overlay draws it: the two dots it joins and where they stand.
*>
struct RigBone
{
	uint a, b;
	Vec3 from, to;
}

<*
 Whether the bone nearest `at` meets `a` or `b`: the surface there is the body
 around that joint, or around either end of that bone.
*>
fn bool owns_surface(RigBone[] bones, Vec3 at, uint a, uint b)
{
	float best = float::max;
	RigBone* nearest = null;
	foreach (&bone : bones)
	{
		Vec3 along = bone.to - bone.from;
		float length2 = along.dot(along);
		float t = length2 > 0.0f ? math::clamp((at - bone.from).dot(along) / length2, 0.0f, 1.0f) : 0.0f;
		float gap = (at - (bone.from + along * t)).length();
		if (gap < best)
		{
			best = gap;
			nearest = bone;
		}
	}
	if (!nearest) return false;
	return nearest.a == a || nearest.b == a || (b != 0 && (nearest.a == b || nearest.b == b));
}

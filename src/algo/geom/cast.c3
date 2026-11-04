<* The pure half of src/app/cast.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

<*
 Where in its own clip a character is at scene time `t`: wrapped when the clip
 loops, held at the ends when it does not.
*>
fn float clip_local_time(AnimTemplate* clip, float t) => clip ? clip.local_time(t) : 0.0f;

<*
 The character's mesh, in the world: its rest bounds carried through its
 placement. Empty bounds for a character with no mesh.
*>
fn rig::Bounds world_bounds(RigDocument* doc, rig::TriMesh* geometry)
{
	if (!has_mesh(geometry)) return {};
	rig::Bounds local = geometry.bounds();
	rig::Bounds out;
	for (int corner = 0; corner < 8; corner++)
	{
		Vec3 at = {
			corner & 1 ? local.max.x : local.min.x,
			corner & 2 ? local.max.y : local.min.y,
			corner & 4 ? local.max.z : local.min.z,
		};
		Vec3 world = doc.model_transform.point(at);
		if (corner == 0)
		{
			out = { world, world };
			continue;
		}
		out.min = math::min(out.min, world);
		out.max = math::max(out.max, world);
	}
	return out;
}

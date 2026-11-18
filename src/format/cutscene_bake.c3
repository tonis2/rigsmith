<* A one-off clip baked into the channels the cutscene file carries, in the frames of the rig's own file. *>
module crig;

import rig;
import gltf_edit;
import std::collections::list;
import std::math::vector;
import std::math::quaternion;

<*
 The rig at rest as Rigsmith writes it into a file: each joint unrotated, unscaled, at its offset
 from its parent.

 @param [in] skeleton
 @param names : "One per joint"
 @require names.len >= skeleton.len() : "One name per joint"
 @return "Names borrowed from `names`; the caller frees the array"
*>
fn JointRest[] skeleton_rests(Allocator allocator, rig::Skeleton* skeleton, String[] names)
{
	usz count = skeleton.len();
	if (count == 0) return {};
	JointRest[] out = alloc::new_array(allocator, JointRest, (sz)count);
	foreach (usz j, &r : out)
	{
		int parent = skeleton.parents[j];
		*r = {
			.name = names[j],
			.parent = parent >= 0 && (usz)parent < count ? names[(usz)parent] : "",
			.translation = rest_offset(skeleton, j),
			.rotation = { 0, 0, 0, 1 },
			.scale = { 1, 1, 1 },
		};
	}
	return out;
}

// The samples a curve keeps, its first and last always among them so every channel spans the clip.
fn usz[] kept_samples(Allocator allocator, usz[] keys, usz count) @local
{
	List{usz} out;
	out.init(allocator);
	defer out.free();
	if (keys.len == 0)
	{
		for (usz k = 0; k < count; k++) out.push(k);
	}
	else
	{
		if (keys[0] != 0) out.push(0);
		foreach (k : keys) out.push(k);
		if (keys[^1] != count - 1) out.push(count - 1);
	}
	return out.to_array(allocator);
}

<*
 `clip` as the game plays it on the rig's own file: sampled with its pins, aims and layers, the way a
 clip saved into the character is, with a channel for each named joint it turns or slides.

 @param [in] skeleton
 @param names : "One per joint, the clip's words"
 @param [in] clip : "Its tracks compiled"
 @return "The caller owns it; no channels when the clip moves nothing"
*>
fn CutAnimation bake_one_off(Allocator allocator, rig::Skeleton* skeleton, String[] names, AnimTemplate* clip, usz actor, String name)
{
	CutAnimation out = { .name = name.copy(allocator), .actor = actor };
	gltf_edit::ReskinClip[] baked = reskin_clips(mem, skeleton, names, { *clip });
	defer free_reskin_clips(mem, baked);
	if (baked.len == 0) return out;
	gltf_edit::ReskinClip* only = &baked[0];
	List{CutChannel} channels;
	channels.init(allocator);
	defer channels.free();
	foreach (&curve : only.curves)
	{
		if (curve.joint >= names.len || names[curve.joint].len == 0) continue;
		if (curve.turns.len > 0)
		{
			usz[] kept = kept_samples(mem, curve.turn_keys, only.times.len);
			defer free(kept);
			CutChannel c = { .bone = names[curve.joint].copy(allocator), .path = ROTATION };
			c.times = alloc::new_array(allocator, float, (sz)kept.len);
			c.values = alloc::new_array(allocator, float, (sz)kept.len * 4);
			foreach (usz i, k : kept)
			{
				c.times[i] = only.times[k];
				Quaternionf q = curve.turns[k].normalize();
				c.values[i * 4:4] = (float[4]){ q.v.x, q.v.y, q.v.z, q.v.w }[..];
			}
			channels.push(c);
		}
		if (curve.slides.len > 0)
		{
			usz[] kept = kept_samples(mem, curve.slide_keys, only.times.len);
			defer free(kept);
			CutChannel c = { .bone = names[curve.joint].copy(allocator), .path = TRANSLATION };
			c.times = alloc::new_array(allocator, float, (sz)kept.len);
			c.values = alloc::new_array(allocator, float, (sz)kept.len * 3);
			foreach (usz i, k : kept)
			{
				c.times[i] = only.times[k];
				Vec3 v = curve.slides[k];
				c.values[i * 3:3] = (float[3]){ v.x, v.y, v.z }[..];
			}
			channels.push(c);
		}
	}
	if (channels.len() > 0) out.channels = channels.to_array(allocator);
	return out;
}

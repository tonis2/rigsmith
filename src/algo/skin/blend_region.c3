<*
 Cloth weights for a region: one joint at its top, the joints at its sides
 blended in toward its bottom and toward each side.

 	`float[] side = blend_side_shares(mem, positions, vertices, plane, shape);`

 What a skirt wants and the binder does not give it. Weighted as body, a hem goes
 to the knees and the middle of the skirt is shared by two thighs, so every step
 splits it down the front. Here the waist rides the hips whole; toward the hem
 each side takes on its thigh, most at the outside and least at the middle, so
 the two halves part only as far as the legs do at the sides and the middle
 follows the hips.
*>
module crig;

import std::math;

<*
 How the side joints come in. `share` is what a side joint takes at the bottom of
 the region on its outside edge, `share_top` the same at the top, and `middle`
 how much of either is left on the mirror plane, as a fraction.
*>
struct BlendShape
{
	float share;
	float share_top;
	float middle;
}

const BlendShape SKIRT_BLEND = { .share = 0.8f, .share_top = 0.24f, .middle = 0.15f };

fn float blend_smooth(float t) @local
{
	float c = math::clamp(t, 0.0f, 1.0f);
	return c * c * (3.0f - 2.0f * c);
}

<*
 For each of `vertices`, the share its side joint takes: from the top of the
 region to its bottom (by height) and from the mirror plane to the region's
 widest point either side. The top joint takes the rest. The caller owns the
 result.

 @param [in] positions : "Every vertex of the mesh"
 @param [in] vertices : "The region, as indices into positions"
*>
fn float[] blend_side_shares(Allocator allocator, Vec3[] positions, uint[] vertices, float plane, BlendShape shape)
{
	if (vertices.len == 0) return {};
	float top = -math::FLOAT_MAX;
	float bottom = math::FLOAT_MAX;
	float across = 0.0f;
	foreach (v : vertices)
	{
		Vec3 at = positions[v];
		top = math::max(top, at.y);
		bottom = math::min(bottom, at.y);
		across = math::max(across, math::abs(at.x - plane));
	}
	float tall = top - bottom;
	float[] out = alloc::new_array(allocator, float, (sz)vertices.len);
	foreach (usz i, v : vertices)
	{
		Vec3 at = positions[v];
		float down = tall > 0.0f ? blend_smooth((top - at.y) / tall) : 1.0f;
		float out_side = across > 0.0f ? blend_smooth(math::abs(at.x - plane) / across) : 1.0f;
		float height_share = shape.share_top + (shape.share - shape.share_top) * down;
		float side_factor = shape.middle + (1.0f - shape.middle) * out_side;
		out[i] = math::clamp(height_share * side_factor, 0.0f, 1.0f);
	}
	return out;
}

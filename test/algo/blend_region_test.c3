// Cloth weights: the side joints' share over a region, from its top to its bottom
// and from the mirror plane out.
module crig_tests::blend_region;

import crig;
import std::core::test;
import std::math;

<*
 On a skirt's outline the side share is the shape's own numbers at its four
 corners: share_top at the top's edge, share at the hem's, and the middle's
 fraction of each on the plane.
*>
fn void the_side_share_runs_from_waist_to_hem_and_middle_to_side() @test
{
	Vec3[6] at = {
		{ 1, 1, 0 },  // waist, outside
		{ 0, 1, 0 },  // waist, middle
		{ 1, 0, 0 },  // hem, outside
		{ 0, 0, 0 },  // hem, middle
		{ -1, 0, 0 }, // hem, other side
		{ 0.5f, 0.5f, 0 },
	};
	uint[6] all = { 0, 1, 2, 3, 4, 5 };
	crig::BlendShape shape = crig::SKIRT_BLEND;
	float[] share = crig::blend_side_shares(mem, at[..], all[..], 0.0f, shape);
	defer alloc::free(mem, share);
	test::@check(math::abs(share[0] - shape.share_top) < 1.0e-5f, "the waist's edge takes %f, not %f", share[0], shape.share_top);
	test::@check(math::abs(share[1] - shape.share_top * shape.middle) < 1.0e-5f, "the waist's middle takes %f", share[1]);
	test::@check(math::abs(share[2] - shape.share) < 1.0e-5f, "the hem's edge takes %f, not %f", share[2], shape.share);
	test::@check(math::abs(share[3] - shape.share * shape.middle) < 1.0e-5f, "the hem's middle takes %f", share[3]);
	test::@check(share[4] == share[2], "the two sides are not mirrored");
	test::@check(share[5] > share[1] && share[5] < share[2], "halfway is not between the waist's middle and the hem's edge");
}

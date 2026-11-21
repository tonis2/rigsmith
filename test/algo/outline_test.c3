<* The lines a collider is drawn with: its rim and creases, not its flat seams. *>
module crig_tests::outline;

import crig;
import std::core::test;
import std::math;

const Vec3[8] CUBE @local = {
	{ 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 }, { 0, 0, 1 }, { 1, 0, 1 }, { 0, 1, 1 }, { 1, 1, 1 },
};
const uint[36] CUBE_TRIANGLES @local = {
	0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3, 0, 4, 5, 0, 5, 1,
	2, 3, 7, 2, 7, 6, 0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5,
};

// Each face with corners of its own, as a file splits them at uv seams.
fn void split_corners_are_welded() @test
{
	Vec3[36] corners;
	uint[36] order;
	foreach (i, v : CUBE_TRIANGLES)
	{
		corners[i] = CUBE[v];
		order[i] = (uint)i;
	}
	uint[] edges = crig::outline_edges(mem, corners[..], order[..]);
	defer alloc::free(mem, edges);
	test::eq(edges.len, 24);
}

fn void a_gentle_fold_is_no_crease() @test
{
	Vec3[4] bent = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0.1f, 1 }, { 0, 0, 1 } };
	uint[6] triangles = { 0, 2, 1, 0, 3, 2 };
	uint[] soft = crig::outline_edges(mem, bent[..], triangles[..]);
	defer alloc::free(mem, soft);
	test::eq(soft.len, 8);
	uint[] sharp = crig::outline_edges(mem, bent[..], triangles[..], 0.01f);
	defer alloc::free(mem, sharp);
	test::eq(sharp.len, 10);
}

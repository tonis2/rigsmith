// Mesh sections: a plane's cut as separate loops, each with its middle and extent.
module crig_tests::sections;

import crig;
import crig_tests::helpers;
import rig;
import std::core::test;
import std::math;

// The twelve triangles of a box, its eight corners shared, or every face with
// corners of its own (a box split along its uv seams).
fn rig::TriMesh box_mesh(Vec3 low, Vec3 high, bool split = false)
{
	Vec3[8] at;
	for (usz c = 0; c < 8; c++)
	{
		at[c] = { (c & 1) ? high.x : low.x, (c & 2) ? high.y : low.y, (c & 4) ? high.z : low.z };
	}
	uint[36] faces = {
		0, 1, 3, 0, 3, 2, 4, 6, 7, 4, 7, 5,
		0, 4, 5, 0, 5, 1, 2, 3, 7, 2, 7, 6,
		0, 2, 6, 0, 6, 4, 1, 5, 7, 1, 7, 3,
	};
	if (!split)
	{
		Vec3[] positions = alloc::new_array(mem, Vec3, 8);
		positions[..] = at[..];
		uint[] indices = alloc::new_array(mem, uint, 36);
		indices[..] = faces[..];
		return { .positions = positions, .indices = indices };
	}
	Vec3[] positions = alloc::new_array(mem, Vec3, 36);
	uint[] indices = alloc::new_array(mem, uint, 36);
	foreach (usz i, corner : faces)
	{
		positions[i] = at[corner];
		indices[i] = (uint)i;
	}
	return { .positions = positions, .indices = indices };
}

// Two meshes as one, the second's indices moved past the first's vertices.
fn rig::TriMesh joined(rig::TriMesh a, rig::TriMesh b)
{
	Vec3[] positions = alloc::new_array(mem, Vec3, (sz)(a.positions.len + b.positions.len));
	positions[:a.positions.len] = a.positions[..];
	positions[a.positions.len..] = b.positions[..];
	uint[] indices = alloc::new_array(mem, uint, (sz)(a.indices.len + b.indices.len));
	indices[:a.indices.len] = a.indices[..];
	foreach (usz i, v : b.indices) indices[a.indices.len + i] = v + (uint)a.positions.len;
	a.free(mem);
	b.free(mem);
	return { .positions = positions, .indices = indices };
}

<*
 A box cut across its middle is one closed loop round its four sides: its
 middle the box's, its size the box's footprint, its length the perimeter.
 Split along every face, it still is: the corners are welded first.
*>
fn void a_box_cuts_into_one_closed_loop() @test
{
	bool[2] splits = { false, true };
	foreach (split : splits)
	{
		rig::TriMesh box = box_mesh({ 0, 0, 0 }, { 2, 1, 1 }, split);
		defer box.free(mem);
		float[1] at = { 0.5f };
		crig::MeshSection[] cuts = crig::mesh_sections(mem, box, {}, 1, at[..]);
		defer crig::free_mesh_sections(mem, cuts);
		test::@check(cuts.len == 1 && cuts[0].loops.len == 1, "a box cut %d ways (split %s)",
			cuts.len == 1 ? cuts[0].loops.len : 0, split);
		if (cuts.len != 1 || cuts[0].loops.len != 1) continue;
		crig::SectionLoop loop = cuts[0].loops[0];
		test::@check(loop.closed, "the box's cut is not closed (split %s)", split);
		test::@check(helpers::near3(loop.centre, { 1, 0.5f, 0.5f }, 1.0e-5f), "the cut's middle is %s", loop.centre);
		test::@check(math::abs(loop.length - 6.0f) < 1.0e-4f, "the cut runs %f round, not 6", loop.length);
		test::@check(helpers::near3(loop.high - loop.low, { 2, 0, 1 }, 1.0e-5f), "the cut's extent is %s", loop.high - loop.low);
	}
}

<*
 Two legs cut below the hips are two loops, left to right, each round its own
 leg; a plane past the mesh cuts nothing; a box keeps only what is in it.
*>
fn void two_pieces_cut_into_two_loops_in_order() @test
{
	rig::TriMesh legs = joined(box_mesh({ 0.5f, 0, 0 }, { 1, 1, 0.5f }), box_mesh({ -1, 0, 0 }, { -0.5f, 1, 0.5f }));
	defer legs.free(mem);
	float[2] at = { 0.25f, 3.0f };
	crig::MeshSection[] cuts = crig::mesh_sections(mem, legs, {}, 1, at[..]);
	defer crig::free_mesh_sections(mem, cuts);
	test::@check(cuts[0].loops.len == 2, "two legs cut %d ways", cuts[0].loops.len);
	if (cuts[0].loops.len == 2)
	{
		test::@check(cuts[0].loops[0].centre.x < 0 && cuts[0].loops[1].centre.x > 0, "the loops are not left to right");
		test::@check(helpers::near3(cuts[0].loops[1].centre, { 0.75f, 0.25f, 0.25f }, 1.0e-5f), "the right leg's middle is %s", cuts[0].loops[1].centre);
	}
	test::@check(cuts[1].loops.len == 0, "a plane above the mesh cut %d loops", cuts[1].loops.len);

	float[1] middle = { 0.25f };
	crig::MeshSection[] boxed = crig::mesh_sections(mem, legs, {}, 1, middle[..], true, { 0, -1, -1 }, { 2, 2, 2 });
	defer crig::free_mesh_sections(mem, boxed);
	test::@check(boxed[0].loops.len == 1 && boxed[0].loops[0].centre.x > 0, "the box did not keep only the right leg");
}

<*
 The shipped humanoid cut through the thighs is two closed loops either side of
 its middle, mirrored; through the chest, one.
*>
fn void the_humanoid_cuts_into_two_legs_and_one_chest() @test
{
	rig::TriMesh body = rig::load_gltf(mem, "assets/animations/humanoid.glb")!!;
	defer body.free(mem);
	rig::Bounds box = body.bounds();
	float height = box.max.y - box.min.y;
	float[2] at = { box.min.y + height * 0.35f, box.min.y + height * 0.70f };
	rig::MeshShells shells = rig::build_shells(mem, body);
	defer shells.free(mem);
	crig::MeshSection[] cuts = crig::mesh_sections(mem, body, shells.of, 1, at[..]);
	defer crig::free_mesh_sections(mem, cuts);

	usz legs = 0;
	float left = 0;
	float right = 0;
	foreach (loop : cuts[0].loops)
	{
		if (loop.length < height * 0.05f) continue;
		legs++;
		if (loop.centre.x < 0) left = loop.centre.x;
		if (loop.centre.x > 0) right = loop.centre.x;
	}
	test::@check(legs == 2, "the thighs cut into %d loops", legs);
	test::@check(math::abs(left + right) < height * 0.02f, "the legs sit at %f and %f, not mirrored", left, right);
	usz chest = 0;
	foreach (loop : cuts[1].loops) if (loop.length >= height * 0.1f) chest++;
	test::@check(chest == 1, "the chest cut into %d large loops", chest);
}

<*
 A point off-centre in a long box is carried to the middle of the box's
 cross-section square to the run; one far from any loop is left alone.
*>
fn void a_point_is_centred_in_the_limb_it_sits_in() @test
{
	rig::TriMesh finger = box_mesh({ 0, 0, 0 }, { 4, 1, 1 });
	defer finger.free(mem);
	Vec3 at;
	test::@check(crig::section_centre_near(finger, {}, { 2, 0.9f, 0.7f }, { 1, 0, 0 }, 0.5f, &at), "no loop under a point inside the box");
	test::@check(helpers::near3(at, { 2, 0.5f, 0.5f }, 1.0e-5f), "the point went to %s, not the box's middle", at);
	Vec3 far = { -9, -9, -9 };
	test::@check(!crig::section_centre_near(finger, {}, { 2, 5, 5 }, { 1, 0, 0 }, 0.5f, &far), "a point far off the box found a loop");
	// Square to a slanted run the cut is slanted too, and still finds the box.
	test::@check(crig::section_centre_near(finger, {}, { 2, 0.6f, 0.4f }, { 1, 0.1f, 0 }, 0.5f, &at), "a slanted cut found nothing");
}

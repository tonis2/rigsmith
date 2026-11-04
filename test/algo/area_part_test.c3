module crig_tests::area_part;

import crig;
import rig;
import std::core::test;
import std::math::vector;

// Six vertices over a three-joint chain: two rows for each joint.
Vec3[6] area_positions = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { 1, 1, 0 }, { 0, 2, 0 }, { 1, 2, 0 } };
Vec3[3] area_joints = { { 0, 0, 0 }, { 0, 1, 0 }, { 0, 2, 0 } };
int[3] area_parents = { -1, 0, 1 };
float[18] area_painted = {
	1, 0, 0,
	1, 0, 0,
	0, 1, 0,
	0, 1, 0,
	0, 0, 1,
	0, 0, 1,
};
// Two pieces: the bottom vertex pair, and the rest.
int[6] area_shell_of = { 0, 0, 1, 1, 1, 1 };
// Three islands, one per joint's pair.
int[6] area_island_of = { 0, 0, 1, 1, 2, 2 };

struct AreaCase @local
{
	String name;
	usz joint;
	crig::AreaPart part;
	sz seed;
	bool[6] want;
}

const AreaCase[*] CASES @local = {
	{ "own", 1, OWN, -1, { false, false, true, true, false, false } },
	{ "with children", 1, WITH_CHILDREN, -1, { false, false, true, true, true, true } },
	{ "a leaf with children", 2, WITH_CHILDREN, -1, { false, false, false, false, true, true } },
	{ "the piece of a seed", 0, PIECE, 3, { false, false, true, true, true, true } },
	{ "the piece with most of the part", 0, PIECE, -1, { true, true, false, false, false, false } },
	{ "the island it holds", 2, ISLANDS, -1, { false, false, false, false, true, true } },
};

fn void a_joints_parts_are_read_from_the_weights() @test
{
	rig::TriMesh mesh = { .positions = area_positions[..] };
	rig::Skeleton skeleton = { .joints = area_joints[..], .parents = area_parents[..] };
	rig::MeshShells shells = { .of = area_shell_of[..], .count = 2 };
	rig::MeshShells islands = { .of = area_island_of[..], .count = 3 };
	crig::AreaSource source = {
		.geometry = &mesh,
		.skeleton = &skeleton,
		.painted = area_painted[..],
		.shells = &shells,
		.islands = &islands,
	};
	foreach (entry : CASES)
	{
		bool[] mask = crig::area_part_of(mem, &source, entry.joint, entry.part, entry.seed);
		defer if (mask.len > 0) alloc::free(mem, mask);
		test::@check(mask.len == 6, "%s: empty", entry.name);
		if (mask.len != 6) continue;
		foreach (v, on : mask) test::@check(on == entry.want[v], "%s: vertex %d", entry.name, v);
	}
}

fn void a_custom_part_and_a_short_weight_table_read_as_nothing() @test
{
	rig::TriMesh mesh = { .positions = area_positions[..] };
	rig::Skeleton skeleton = { .joints = area_joints[..], .parents = area_parents[..] };
	rig::MeshShells shells = { .of = area_shell_of[..], .count = 2 };
	crig::AreaSource source = { .geometry = &mesh, .skeleton = &skeleton, .painted = area_painted[..], .shells = &shells };
	test::@check(crig::area_part_of(mem, &source, 1, CUSTOM).len == 0, "custom has no rule of its own");
	source.painted = area_painted[:3];
	test::@check(crig::area_part_of(mem, &source, 1, OWN).len == 0, "a short table was read");
}

fn void an_island_goes_to_the_joint_holding_most_of_it() @test
{
	float[6] painted = { 1, 0, 1, 0, 0, 1 }; // three vertices over two joints
	int[3] of = { 0, 0, 0 };
	rig::MeshShells split = { .of = of[..], .count = 1 };
	bool[] owned = crig::islands_owned(mem, &split, 3, painted[..], 2, 0);
	defer if (owned.len > 0) alloc::free(mem, owned);
	test::@check(owned.len == 1 && owned[0], "the joint with two of three does not own the island");

	bool[] lesser = crig::islands_owned(mem, &split, 3, painted[..], 2, 1);
	defer if (lesser.len > 0) alloc::free(mem, lesser);
	test::@check(lesser.len == 1 && lesser[0], "with no island of its own a joint takes the one holding most of it");
}

<*
 C1: the posed triangle surface collision stages can share.

 These tests stop at broad phase on purpose. Pair exclusions belong to C2 and
 gesture blocking belongs to C3/C4; C1 promises exact topology, affected skin
 regions and an accelerator that can be refitted without touching the other
 half of the body.
*>
module crig_tests::deformed_collision;

import crig;
import rig;
import gltf;
import collision;
import std::core::test;
import std::math;
import std::math::matrix;


const uint[36] BOX_FACES @local = {
	4, 5, 6, 4, 6, 7,
	0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5,
	0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2,
	0, 1, 5, 0, 5, 4,
};

fn void corners(Vec3[] into, Vec3 low, Vec3 high) @local
{
	into[0] = { low.x, low.y, low.z };
	into[1] = { high.x, low.y, low.z };
	into[2] = { high.x, high.y, low.z };
	into[3] = { low.x, high.y, low.z };
	into[4] = { low.x, low.y, high.z };
	into[5] = { high.x, low.y, high.z };
	into[6] = { high.x, high.y, high.z };
	into[7] = { low.x, high.y, high.z };
}

struct SurfaceFixture @local
{
	Vec3[16] positions;
	uint[72] indices;
	ushort[16] joints;
	float[16] weights;
	rig::TriMesh mesh;
	gltf::SkinBinding binding;
	crig::Picker picker;
	crig::DeformedCollisionSurface surface;
}

fn void SurfaceFixture.init(&self)
{
	corners(self.positions[:8], { -2.5, -0.5, -0.5 }, { -1.5, 0.5, 0.5 });
	corners(self.positions[8:8], { 1.5, -0.5, -0.5 }, { 2.5, 0.5, 0.5 });
	foreach (usz i, corner : BOX_FACES)
	{
		self.indices[i] = corner;
		self.indices[i + 36] = corner + 8;
	}
	for (usz vertex = 0; vertex < 16; vertex++)
	{
		self.joints[vertex] = vertex < 8 ? 0 : 1;
		self.weights[vertex] = 1.0f;
	}
	self.mesh = { .positions = self.positions[..], .indices = self.indices[..] };
	self.binding = {
		.joints = self.joints[..],
		.weights = self.weights[..],
		.slots = 1,
		.vertices = 16,
	};
	self.picker = crig::build_picker(self.mesh);
	self.surface = crig::build_deformed_collision_surface(&self.picker, self.binding, 2);
}

fn void SurfaceFixture.free(&self)
{
	self.surface.free();
	self.picker.free();
}

fn bool has_cross_region_pair(
	crig::DeformedCollisionSurface* surface,
	crig::DeformedTrianglePair[] pairs) @local
{
	foreach (pair : pairs)
	{
		if (surface.region_for_triangle(pair.a) != surface.region_for_triangle(pair.b)) return true;
	}
	return false;
}

fn void topology_and_skin_regions_are_cached_once() @test
{
	SurfaceFixture fixture;
	fixture.init();
	defer fixture.free();
	uint[] joint_zero_triangles = fixture.surface.triangles_for_joint(0);
	uint[] joint_one_triangles = fixture.surface.triangles_for_joint(1);

	test::eq(fixture.surface.vertices, (usz)16);
	test::eq(fixture.surface.triangles, (usz)24);
	test::eq(joint_zero_triangles.len, (sz)12);
	test::eq(joint_one_triangles.len, (sz)12);
	test::eq(fixture.surface.region_for_vertex(0), (uint)0);
	test::eq(fixture.surface.region_for_vertex(8), (uint)1);
	test::eq(fixture.surface.region_for_triangle(0), (uint)0);
	test::eq(fixture.surface.region_for_triangle(12), (uint)1);

	// A perpendicular face that meets the first only at vertex 6 still shares
	// a vertex with it.
	test::@check(fixture.surface.triangles_share_vertex(0, 4),
		"vertex incidence was lost");
	test::@check(!fixture.surface.triangles_share_vertex(0, 12),
		"disconnected boxes unexpectedly share topology");
}

fn void a_joint_refit_only_reskins_its_affected_region() @test
{
	SurfaceFixture fixture;
	fixture.init();
	defer fixture.free();

	Matrix4f[2] palette = { matrix::IDENTITY4, matrix::IDENTITY4 };
	crig::DeformedRefitStats full = fixture.surface.refit_all(fixture.binding, palette[..], 1);
	test::@check(full.full, "the explicit initial refit was not reported as full");
	test::eq(full.vertices, (usz)16);
	test::eq(full.triangles, (usz)24);
	test::@check(full.nodes > 0, "the BVH did not refit any nodes");

	uint[1] moving = { 0 };
	crig::DeformedTrianglePair[] apart = fixture.surface.broad_phase_pairs_for_joints(mem, moving[..]);
	test::@check(!has_cross_region_pair(&fixture.surface, apart),
		"separated skin regions produced a broad-phase pair");
	if (apart.len > 0) alloc::free(mem, apart);

	// Move only joint zero's box onto joint one's box. The exact bounds for the
	// stationary region must survive byte-for-byte while only eight vertices
	// and twelve triangles are revisited.
	collision::Aabb3 still = fixture.surface.triangle_bounds[12];
	palette[0].m[12] = 4.0f;
	crig::DeformedRefitStats partial = fixture.surface.refit_joints(
		moving[..], fixture.binding, palette[..], 2);
	test::@check(!partial.full, "a regional edit fell back to a full surface refit");
	test::eq(partial.vertices, (usz)8);
	test::eq(partial.triangles, (usz)12);
	test::@check(partial.nodes > 0 && partial.nodes < full.nodes,
		"the regional refit visited %d of %d nodes", partial.nodes, full.nodes);
	test::eq(fixture.surface.triangle_bounds[12], still);
	test::eq(fixture.surface.surface_generation, (uint)2);

	crig::DeformedTrianglePair[] touching = fixture.surface.broad_phase_pairs_for_joints(mem, moving[..]);
	test::@check(has_cross_region_pair(&fixture.surface, touching),
		"overlapping deformed regions were absent from broad phase");
	if (touching.len > 0) alloc::free(mem, touching);

	collision::TriangleVerts moved = fixture.surface.deformed_triangle(
		0, fixture.binding, palette[..], 2);
	test::@check(moved[0].x > 1.0f && moved[1].x > 1.0f,
		"the collision triangle still contains rest-pose vertices");
}

fn void the_first_regional_refit_initializes_the_whole_surface() @test
{
	SurfaceFixture fixture;
	fixture.init();
	defer fixture.free();

	Matrix4f[2] palette = { matrix::IDENTITY4, matrix::IDENTITY4 };
	uint[1] moving = { 0 };
	crig::DeformedRefitStats first = fixture.surface.refit_joints(
		moving[..], fixture.binding, palette[..], 1);
	test::@check(first.full, "the uninitialized surface accepted a partial refit");
	test::eq(first.triangles, (usz)24);
}

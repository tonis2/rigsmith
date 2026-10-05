<*
 The mesh's own inside, and where each of its vertices sits in it.

 The grid and the distance fields over it are `collision::VoxelGrid` — solid
 voxelization and a flood distance through solid space are not rigging, and
 nothing in them knows what a joint is. What belongs here is the pairing of a
 grid with the mesh it was built from: `anchors` maps every vertex to the
 interior cell nearest it, which the binder needs per vertex per bone and which
 the shell search is far too slow to recompute at that rate.

     `rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);`
     `defer voxels.free(mem);`
     `float[] skin = rig::bind_geodesic(mem, &voxels, positions, joints, parents);`

 Built once when the mesh loads and reused for every rebind: it depends on the
 mesh and nothing else, so moving a dot does not touch it. See PLAN §13.
*>
module rig;

import collision;
import std::math;



<*
 A grid, and the vertex-to-cell map that ties it to one mesh.

 The pair travels together because the binder cannot use either half alone, and
 because a grid holding anchors for a *different* mesh is the one way this can
 be silently wrong — `bind_geodesic` checks the lengths agree and falls back to
 straight lines when they do not.
*>
struct MeshVoxels
{
	collision::VoxelGrid grid;
	int[] anchors;   // mesh vertex -> cell entry, or -1 with nothing near
}

<*
 Whether there is an inside to travel through.

 A mesh that is open everywhere, flat, or smaller than one cell produces
 nothing. Callers treat that as "no grid" and measure straight lines instead of
 refusing to rig it.
*>
fn bool MeshVoxels.usable(self) => self.grid.usable() && self.anchors.len > 0;

<*
 Voxelize a mesh and locate its vertices in the result.

 @param resolution : `Cells along the model's longest side; see VOXEL_RESOLUTION. Zero fits one to the model — see fitted_resolution, which needs the pieces below to have anything to fit to.`
 @param bvh : `A BVH over this same geometry to march instead of building one — a Picker's, normally. Borrowed for the call only, and never freed here. Null builds one.`
 @param pieces : `The mesh's shells, from build_shells over this same geometry. Read only to choose the resolution, and only when one was not given.`
*>
fn MeshVoxels build_voxels(
	alloc::Allocator allocator,
	TriMesh geometry,
	uint resolution = 0,
	collision::TriBVHNode* bvh = null,
	MeshShells* pieces = null)
{
	if (geometry.positions.len == 0 || geometry.triangle_count() == 0) return {};

	if (resolution == 0) resolution = fitted_resolution(allocator, geometry, pieces);

	collision::Triangle[] triangles =
		((collision::Triangle*)geometry.indices.ptr)[:geometry.triangle_count()];

	collision::VoxelGrid grid =
		collision::create_voxel_grid(geometry.positions, triangles, resolution, bvh);
	if (!grid.usable()) return {};

	// A vertex sits on the surface, which is exactly where the inside stops, so
	// about half of them fall in a cell the parity test called empty and have to
	// reach in one step to find one. How far they may reach has to be a distance
	// through the *model*, not a count of cells: quoted in cells it halves every
	// time the grid is refined, so a horn tip or a finger that needed the reach at
	// one resolution loses it at the next and comes out anchored nowhere at all.
	// That was the standing argument against a finer grid — at 96, 703 of the
	// shipped Mixamo character's vertices lost their cell, and none do now.
	//
	// A twenty-fourth of the model, which is what two cells used to be at 48.
	int reach = (int)math::max((float)collision::VOXEL_PAD, math::round((float)resolution / 24.0f));

	int[] anchors = alloc::new_array(allocator, int, (sz)geometry.positions.len);
	foreach (usz i, position : geometry.positions)
	{
		anchors[i] = grid.nearest_cell(position, reach);
	}

	return { .grid = grid, .anchors = anchors };
}

fn void MeshVoxels.free(&self, alloc::Allocator allocator)
{
	self.grid.free();
	if (self.anchors.len > 0) alloc::free(allocator, self.anchors);
	*self = {};
}

// The same reinterpret the picker makes: collision's Triangle has to be three
// packed uints or the indices are read at the wrong stride and the grid
// describes a different mesh than the one on screen.
$assert collision::Triangle::size == uint::size * 3 : "collision::Triangle is no longer three packed uints";

<*
 Cells along the model's longest side, for a model made of one skin.

 48 puts a cow's leg three to four cells across — enough to carry a path down it
 and thin enough that two legs never touch. Finer was measured and is not worth
 it here: 64 doubles the cost of a rebind and returns the same weights (leg-to-leg
 bleed on the cow is 2.0% at 48 against 2.1% at 64).

 The knob to reach for is a model whose limbs are thinner than the grid: a limb
 that does not fill is one no path can travel down, and the rig comes out worse
 than the straight-line one rather than subtly softer. `fitted_resolution` is
 what reaches for it, on the models that need it.
*>
const uint VOXEL_RESOLUTION = 48;

<*
 How many cells across the piece a typical vertex belongs to has to be before the
 grid is called fine enough to hold two of them apart.

 Two pieces touching need a cell between them or the 26-neighbour step walks
 straight across, and neither piece can spare that cell if it is only two or
 three wide itself. Eight is comfortably more than that and comfortably less than
 what a one-skin model measures, which is the whole grid: the two populations sit
 fifteen times apart and there is nothing in between to get wrong.
*>
const float PIECE_CELLS = 8.0;

<*
 What a model built out of solids costs the grid, and what to do about it.

 A hand is where every distance-through-the-body binder goes wrong, and the
 reason is arithmetic rather than anything about hands: `VOXEL_RESOLUTION` is
 quoted on the whole model, so a cell is a fiftieth of a body however small the
 part being asked about. On the shipped robot that puts adjacent finger bones
 0.86 to 1.05 cells apart — one voxel spanning two fingers — and 55% of that
 hand's vertices come out held by a bone on a *different finger*. Every model in
 the repo gets between one and two thousand interior cells at 48 whatever its
 shape, so this is not a property of any one of them.

 Refining the grid everywhere is the obvious answer and the wrong one: it costs
 three to ten times as much on every model, including the ones with nothing finer
 than a thigh to resolve. So it is spent where it buys something. Measured over
 the models here, the piece a typical vertex sits in is 48 cells across on a
 one-skin character and **two to three** on a model assembled from solids — the
 robot at 3.19, the Mixamo character at 2.17, everything else at 47.7 or more.
 Nothing lands between, so the test needs no care beyond being on the right side
 of the gap.

 One doubling, and no more. A model whose pieces are finer still exists, and it
 would rather have a rig that binds in a fifth of a second than a better one it
 has to wait two seconds for after every dot it moves.

 @param pieces : `From build_shells over this same geometry. Null or a single shell answers VOXEL_RESOLUTION, since a skin has no pieces to hold apart.`
*>
fn uint fitted_resolution(alloc::Allocator allocator, TriMesh geometry, MeshShells* pieces)
{
	if (pieces == null || !pieces.split()) return VOXEL_RESOLUTION;
	if (pieces.of.len != geometry.positions.len) return VOXEL_RESOLUTION;

	Vec3 extent = geometry.bounds().extent();
	float longest = extent.max();
	if (!(longest > 0.0f)) return VOXEL_RESOLUTION;

	Vec3[] low = alloc::new_array(allocator, Vec3, (sz)pieces.count);
	Vec3[] high = alloc::new_array(allocator, Vec3, (sz)pieces.count);
	defer
	{
		alloc::free(allocator, low);
		alloc::free(allocator, high);
	}
	foreach (&box : low) *box = { 1.0e30f, 1.0e30f, 1.0e30f };
	foreach (&box : high) *box = { -1.0e30f, -1.0e30f, -1.0e30f };

	foreach (usz v, id : pieces.of)
	{
		if (id < 0 || (usz)id >= pieces.count) continue;
		Vec3 at = geometry.positions[v];
		low[id] = { math::min(low[id].x, at.x), math::min(low[id].y, at.y), math::min(low[id].z, at.z) };
		high[id] = { math::max(high[id].x, at.x), math::max(high[id].y, at.y), math::max(high[id].z, at.z) };
	}

	// The share of the *mesh* that sits in narrow pieces, not the share of the
	// pieces that are narrow. A model is a hundred rivets and a body either way,
	// and it is where the vertices are that decides whether the grid is wrong.
	float cell = longest / (float)VOXEL_RESOLUTION;
	usz cramped = 0;
	foreach (usz v, id : pieces.of)
	{
		if (id < 0 || (usz)id >= pieces.count) continue;
		Vec3 size = high[id] - low[id];
		float widest = size.max();
		if (widest < PIECE_CELLS * cell) cramped++;
	}

	return cramped * 2 > geometry.positions.len ? VOXEL_RESOLUTION * 2 : VOXEL_RESOLUTION;
}

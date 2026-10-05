<*
 Does measuring distance through the body actually stop one limb dragging the
 other one along?

     `c3c test --trust=full --test-filter crig_tests::geodesic`

 The fixture is a solid two-legged slab — a closed surface, because a surface
 with holes has no inside to voxelize and this is the one test where that
 matters. It is shaped like the failure M3 exists to remove: two limbs hanging
 side by side with a gap between them, close enough in a straight line that the
 old binder hands each leg a share of the other's skin.

 Every claim here is made twice, once per binder, and the check is that the
 second number is better than the first. An absolute threshold would say
 nothing — the interesting quantity is the improvement, and stating both is what
 makes a regression legible when it arrives.

 The last two run the binder over a real model from the repo. The numbers there
 depend on the mesh, so what is asserted is only what holds for any of them: it
 has an inside, nothing comes back as NaN, and no vertex is left unheld.
*>
module crig_tests::geodesic;

import rig;
import gltf;
import collision;
import std::core::test;
import std::io;
import std::time;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import std::collections::list;



alias Vec3List = List{Vec3};
alias UintList = List{uint};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

<*
 A quad as a grid of triangles.

 Everything below is built from these, subdivided, so the fixture has enough
 vertices to say something about weights rather than just about corners.
 Vertices are not welded between quads: the surface is closed geometrically,
 which is all the parity test asks of it.
*>
fn void add_quad(Vec3List* positions, UintList* indices, Vec3 a, Vec3 b, Vec3 c, Vec3 d, int steps)
{
	uint first = (uint)positions.len();

	for (int j = 0; j <= steps; j++)
	{
		float v = (float)j / (float)steps;
		for (int i = 0; i <= steps; i++)
		{
			float u = (float)i / (float)steps;
			Vec3 top = a + (b - a) * u;
			Vec3 bottom = d + (c - d) * u;
			positions.push(top + (bottom - top) * v);
		}
	}

	int stride = steps + 1;
	for (int j = 0; j < steps; j++)
	{
		for (int i = 0; i < steps; i++)
		{
			uint corner = first + (uint)(j * stride + i);
			indices.push(corner);
			indices.push(corner + (uint)stride);
			indices.push(corner + 1);
			indices.push(corner + 1);
			indices.push(corner + (uint)stride);
			indices.push(corner + (uint)stride + 1);
		}
	}
}

// A closed axis-aligned box, six subdivided quads.
fn void add_box(Vec3List* positions, UintList* indices, Vec3 low, Vec3 high, int steps)
{
	Vec3 a = { low.x, low.y, low.z };
	Vec3 b = { high.x, low.y, low.z };
	Vec3 c = { high.x, high.y, low.z };
	Vec3 d = { low.x, high.y, low.z };
	Vec3 e = { low.x, low.y, high.z };
	Vec3 f = { high.x, low.y, high.z };
	Vec3 g = { high.x, high.y, high.z };
	Vec3 h = { low.x, high.y, high.z };

	add_quad(positions, indices, a, b, c, d, steps);   // -Z
	add_quad(positions, indices, f, e, h, g, steps);   // +Z
	add_quad(positions, indices, e, f, b, a, steps);   // -Y
	add_quad(positions, indices, d, c, g, h, steps);   // +Y
	add_quad(positions, indices, e, a, d, h, steps);   // -X
	add_quad(positions, indices, b, f, g, c, steps);   // +X
}

<*
 How far apart the legs stand, and how thick everything is.

 The gap is narrow on purpose — narrower than a leg is wide. That is the
 arrangement straight-line distance gets wrong: from the inner face of one
 thigh the other thigh's bone is closer *across the gap* than the vertex's own
 bone is through the meat of its own leg, and the weights come out saying so.
 Legs set wide apart would make the old binder look fine and prove nothing.
*>
const float LEG_INNER = 0.06;
const float LEG_OUTER = 0.26;
const float HIP_Y = 0.0;
const float FOOT_Y = -1.0;
const float HEAD_Y = 0.3;
const float SLAB_Z = 0.15;

<*
 The two-legged slab: one closed prism, not three boxes stacked.

 Three overlapping solids would defeat the parity test — a line through the
 overlap crosses four surfaces and the span in the middle, which is the most
 solid part of the model, would come out empty. So the outline is walked once
 as a single simple polygon and extruded, and the caps are laid over the three
 disjoint rectangles it encloses.
*>
fn rig::TriMesh staple_mesh(Allocator allocator, int steps = 5)
{
	Vec3List positions;
	UintList indices;
	positions.init(allocator);
	indices.init(allocator);

	// `to_array` copies, so the builders are scratch and have to go back — the
	// mesh handed out below does not point into them.
	defer
	{
		positions.free();
		indices.free();
	}

	float back = -SLAB_Z;
	float front = SLAB_Z;

	// The outline, counter-clockwise from the left foot.
	float[8] outline_x = { -LEG_OUTER, -LEG_INNER, -LEG_INNER, LEG_INNER, LEG_INNER, LEG_OUTER, LEG_OUTER, -LEG_OUTER };
	float[8] outline_y = { FOOT_Y, FOOT_Y, HIP_Y, HIP_Y, FOOT_Y, FOOT_Y, HEAD_Y, HEAD_Y };

	for (usz i = 0; i < 8; i++)
	{
		usz next = (i + 1) % 8;
		add_quad(&positions, &indices,
			{ outline_x[i], outline_y[i], back },
			{ outline_x[next], outline_y[next], back },
			{ outline_x[next], outline_y[next], front },
			{ outline_x[i], outline_y[i], front },
			steps);
	}

	// The three rectangles the outline encloses, front and back.
	float[3] low_x = { -LEG_OUTER, LEG_INNER, -LEG_OUTER };
	float[3] high_x = { -LEG_INNER, LEG_OUTER, LEG_OUTER };
	float[3] low_y = { FOOT_Y, FOOT_Y, HIP_Y };
	float[3] high_y = { HIP_Y, HIP_Y, HEAD_Y };

	for (usz r = 0; r < 3; r++)
	{
		add_quad(&positions, &indices,
			{ low_x[r], low_y[r], back }, { high_x[r], low_y[r], back },
			{ high_x[r], high_y[r], back }, { low_x[r], high_y[r], back }, steps);
		add_quad(&positions, &indices,
			{ low_x[r], low_y[r], front }, { high_x[r], low_y[r], front },
			{ high_x[r], high_y[r], front }, { low_x[r], high_y[r], front }, steps);
	}

	return { .positions = positions.to_array(allocator), .indices = indices.to_array(allocator) };
}

// Pelvis, hip and foot down each side — the same five joints anim-test poses,
// placed for the slab and running down the middle of each leg.
const float LEG_MID = (LEG_INNER + LEG_OUTER) * 0.5f;
const usz HIP_L = 1;
const usz FOOT_L = 2;
const usz HIP_R = 3;
const usz FOOT_R = 4;

fn rig::Skeleton staple_skeleton(Allocator allocator)
{
	Vec3[] joints = alloc::new_array(allocator, Vec3, 5);
	int[] parents = alloc::new_array(allocator, int, 5);

	joints[0] = { 0, HEAD_Y * 0.4f, 0 };        parents[0] = -1;
	joints[HIP_L] = { -LEG_MID, HIP_Y, 0 };     parents[HIP_L] = 0;
	joints[FOOT_L] = { -LEG_MID, FOOT_Y, 0 };   parents[FOOT_L] = (int)HIP_L;
	joints[HIP_R] = { LEG_MID, HIP_Y, 0 };      parents[HIP_R] = 0;
	joints[FOOT_R] = { LEG_MID, FOOT_Y, 0 };    parents[FOOT_R] = (int)HIP_R;

	return { .joints = joints, .parents = parents };
}

// Whether a vertex belongs to the left leg, the right leg, or neither.
fn int leg_of(Vec3 point)
{
	if (point.y > HIP_Y - 0.05f) return -1;
	return point.x < 0.0f ? 0 : 1;
}

// ---------------------------------------------------------------------------
// Measurements
// ---------------------------------------------------------------------------

<*
 The share of one leg's skin that the *other leg* holds.

 The opposite leg's own bone only — the hip-to-foot segment that is the leg,
 which is the bone belonging to the *hip* joint, since a joint holds the bone
 below it. The foot's own bone extrudes past the sole into open air and the
 pelvis bone lies across the root, so a thigh leaning on either is not a leg
 reaching across a gap, which is the thing being counted here.

 Measured on the normalised top-four weights rather than on the raw matrix,
 because that is the rig the file is made of and the only one anybody sees.
*>
fn float leg_bleed(Vec3[] positions, rig::Skeleton* skeleton, float[] dense)
{
	usz bones = skeleton.len();
	float worst = 0.0f;

	for (int side = 0; side < 2; side++)
	{
		usz other_leg = side == 0 ? HIP_R : HIP_L;

		float other = 0.0f;
		float total = 0.0f;

		foreach (usz v, position : positions)
		{
			if (leg_of(position) != side) continue;

			// Rank the row and keep the four the exporter would keep.
			float[4] best_weight = { 0, 0, 0, 0 };
			usz[4] best_bone = { 0, 0, 0, 0 };
			for (usz b = 0; b < bones; b++)
			{
				float weight = dense[v * bones + b];
				for (usz slot = 0; slot < 4; slot++)
				{
					if (weight <= best_weight[slot]) continue;
					for (usz shift = 3; shift > slot; shift--)
					{
						best_weight[shift] = best_weight[shift - 1];
						best_bone[shift] = best_bone[shift - 1];
					}
					best_weight[slot] = weight;
					best_bone[slot] = b;
					break;
				}
			}

			for (usz slot = 0; slot < 4; slot++)
			{
				total += best_weight[slot];
				if (best_bone[slot] == other_leg) other += best_weight[slot];
			}
		}

		if (total <= 0.0f) continue;
		float bleed = other / total;
		if (bleed > worst) worst = bleed;
	}

	return worst;
}

// The furthest any vertex of one leg travels when the other leg's hip turns.
fn float swing_travel(Vec3[] positions, rig::Skeleton* skeleton, float[] dense, usz turned, int watched)
{
	gltf::SkinBinding binding = gltf::sparsify_weights(mem, dense, positions.len, skeleton.len(), 4)!!;
	defer binding.free(mem);

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	pose.turn(turned, { 0, 0, 1 }, (float)math::PI * 0.4f);

	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);

	Vec3[] posed = alloc::new_array(mem, Vec3, (sz)positions.len);
	defer alloc::free(mem, posed);
	rig::skin_positions(posed, positions, binding, palette)!!;

	float worst = 0.0f;
	foreach (usz v, position : positions)
	{
		if (leg_of(position) != watched) continue;
		float moved = (posed[v] - position).length();
		if (moved > worst) worst = moved;
	}
	return worst;
}

fn bool all_finite(float[] values)
{
	foreach (value : values)
	{
		if (!math::is_finite(value)) return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
// Fixtures the checks share
// ---------------------------------------------------------------------------

<*
 A real model from the repo, for the two checks that want a real vertex count.

 Relative, so the run has to start from the crig directory.
*>
const String REAL_MESH = "assets/animations/humanoid.glb";

<*
 The two-legged slab, its skeleton and its grid — the shape M3 exists for.

 Rebuilt per check rather than shared between them: `build_voxels` is the
 expensive half and it is still under a tenth of a second, which is a cheaper
 price than every check below depending on what the one above it left behind.
*>
struct Slab
{
	rig::TriMesh mesh;
	rig::Skeleton skeleton;
	rig::MeshVoxels voxels;
}

// Allocates from `mem`; the caller frees it with `Slab.free`.
fn Slab slab()
{
	rig::TriMesh mesh = staple_mesh(mem);
	rig::Skeleton skeleton = staple_skeleton(mem);
	return { mesh, skeleton, rig::build_voxels(mem, mesh) };
}

fn void Slab.free(&self)
{
	self.voxels.free(mem);
	self.skeleton.free(mem);
	self.mesh.free(mem);
}

<*
 Two boxes with air between them: the smallest mesh that is two bodies.

 The load-bearing property behind every claim in this file is that a path cannot
 cross a gap, because there is nothing in the gap to step on. This is the
 smallest statement of it. The caller frees the mesh.
*>
fn rig::TriMesh two_boxes()
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	add_box(&positions, &indices, { -0.5, -0.25, -0.25 }, { -0.2, 0.25, 0.25 }, 4);
	add_box(&positions, &indices, { 0.2, -0.25, -0.25 }, { 0.5, 0.25, 0.25 }, 4);
	return { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
}

<*
 A two-joint chain inside the left box of `two_boxes`, reaching nothing else.

 Both joints sit in the near piece, so the far one is unreachable by any path —
 which is the case the straight-line repair exists for. The caller frees both
 arrays.
*>
fn void left_box_chain(Vec3[]* joints, int[]* parents)
{
	*joints = alloc::new_array(mem, Vec3, 2);
	*parents = alloc::new_array(mem, int, 2);
	(*joints)[0] = { -0.42f, 0, 0 };
	(*parents)[0] = -1;
	(*joints)[1] = { -0.28f, 0, 0 };
	(*parents)[1] = 0;
}

<*
 A tall body with a small box floating clear of it: the sword case.

 The prop is level with the top of a three-joint chain and clear of the body by
 several cells — a gap of one is a gap a diagonal step crosses — and long enough
 to run the length of both upper bones, which is what makes the choice of bone
 interesting rather than obvious.

 Writes the number of body vertices to `body_vertices`; everything at or after
 that index is the prop. The caller frees the mesh.
*>
fn rig::TriMesh body_with_prop(usz* body_vertices)
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	add_box(&positions, &indices, { -0.15, -0.5, -0.15 }, { 0.15, 0.5, 0.15 }, 6);
	*body_vertices = (usz)positions.len();
	add_box(&positions, &indices, { 0.25, -0.05, -0.05 }, { 0.35, 0.50, 0.05 }, 1);

	return { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
}

// The three-joint spine the prop hangs beside. The caller frees both arrays.
fn void spine_chain(Vec3[]* joints, int[]* parents)
{
	*joints = alloc::new_array(mem, Vec3, 3);
	*parents = alloc::new_array(mem, int, 3);
	(*joints)[0] = { 0, -0.3f, 0 };
	(*parents)[0] = -1;
	(*joints)[1] = { 0, 0, 0 };
	(*parents)[1] = 0;
	(*joints)[2] = { 0, 0.3f, 0 };
	(*parents)[2] = 1;
}

// ---------------------------------------------------------------------------
// The grid, before any skinning touches it
// ---------------------------------------------------------------------------

<*
 A closed box has an inside, and it is the size of the box.

 A box is the one shape whose interior volume is known in closed form, so it is
 the only place the fill can be checked against something other than itself.
*>
fn void a_closed_box_is_filled_to_its_own_volume() @test
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	add_box(&positions, &indices, { -0.5, -0.25, -0.25 }, { 0.5, 0.25, 0.25 }, 4);
	rig::TriMesh box = { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
	defer box.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, box);
	defer voxels.free(mem);

	test::@check(voxels.usable(), "a closed box has no inside");

	collision::VoxelGrid grid = voxels.grid;
	float filled = (float)grid.cells.len * grid.cell * grid.cell * grid.cell;
	float actual = 1.0f * 0.5f * 0.5f;
	float error = math::abs(filled - actual) / actual;
	test::@check(error < 0.15f, "filled %.4f against the box's own %.4f — %.1f%% out",
		filled, actual, error * 100.0f);

	foreach (vertex, anchor : voxels.anchors)
	{
		test::@check(anchor >= 0, "surface vertex %d found no interior cell to sit in", vertex);
	}
}

<*
 No path crosses a gap, and a bone touching nothing says so.

 What makes a limb unable to drag its neighbour is that there is nothing between
 them to step on. If this fails, every other claim in the file is meaningless
 even when it passes.
*>
fn void a_gap_stops_every_path() @test
{
	rig::TriMesh pair = two_boxes();
	defer pair.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, pair);
	defer voxels.free(mem);
	collision::VoxelGrid grid = voxels.grid;

	float[] field = alloc::new_array(mem, float, (sz)grid.cells.len);
	defer alloc::free(mem, field);

	test::@check(grid.distance_from_segment({ -0.35f, 0, 0 }, { -0.35f, 0, 0 }, field),
		"a bone inside the left box seeded nothing");

	usz reached = 0;
	foreach (usz entry, distance : field)
	{
		if (distance >= collision::VOXEL_UNREACHED) continue;
		if (grid.center(grid.cells[entry]).x > 0.0f) reached++;
	}
	test::@check(reached == 0, "%d cells across the gap were reached anyway", reached);

	// A bone that misses the body entirely has nothing to seed, and says so
	// rather than handing back a field of infinities.
	test::@check(!grid.distance_from_segment({ 0, 5, 0 }, { 0, 5, 0 }, field),
		"a bone outside the mesh claimed to have seeded something");
}

<*
 Two slabs with a gap a cell and a half wide: near enough that a search around a
 point in one of them finds the other.

 Which is the arrangement a hand is, at the resolution a hand gets. The caller
 frees the mesh.
*>
fn rig::TriMesh two_slabs()
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	add_box(&positions, &indices, { -0.50, -0.10, -0.10 }, { -0.015, 0.10, 0.10 }, 4);
	add_box(&positions, &indices, { 0.015, -0.10, -0.10 }, { 0.50, 0.10, 0.10 }, 4);
	return { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
}

<*
 A seed lands where the segment is, and not on whatever is nearby.

 `nearest_cell` reaches outward on purpose — a point on the surface sits exactly
 where the inside stops, so half of them need a step in to find a cell at all.
 Seeding is the one caller that must not have it, and the reason is that a seed
 is not an approximation: it is a *zero*, and a zero says the bone is inside that
 material. A bone that reached across a gap for want of a cell under itself would
 declare the piece it landed on to be at no distance whatever, which no later
 measurement can argue down.

 Two slabs a cell and a half apart, with a bone in the first reaching to within
 a third of a cell of the second — comfortably inside the search radius, which is
 what makes the fixture pose the question rather than pass it by luck.
*>
fn void a_seed_does_not_reach_across_a_gap() @test
{
	rig::TriMesh pair = two_slabs();
	defer pair.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, pair);
	defer voxels.free(mem);
	collision::VoxelGrid grid = voxels.grid;

	Vec3 tip = { 0.008f, 0, 0 };

	// The premise: the far slab really is within reach of the bone's tip, so a
	// search around it would find that slab before it found anything else.
	int found = grid.nearest_cell(tip);
	test::@check(found >= 0, "nothing at all was found near the bone's tip");
	test::@check(grid.center(grid.cells[found]).x > 0.0f,
		"the search around the tip landed at x %.4f, so this fixture no longer poses the question",
		grid.center(grid.cells[found]).x);

	float[] field = alloc::new_array(mem, float, (sz)grid.cells.len);
	defer alloc::free(mem, field);

	test::@check(grid.distance_from_segment({ -0.30f, 0, 0 }, tip, field),
		"a bone inside the near slab seeded nothing");

	foreach (usz entry, distance : field)
	{
		if (distance >= collision::VOXEL_UNREACHED) continue;
		Vec3 at = grid.center(grid.cells[entry]);
		test::@check(at.x < 0.0f,
			"a cell of the far slab at x %.4f came out %.4f from a bone that never touches it",
			at.x, distance);
	}
}

// ---------------------------------------------------------------------------
// The binder, on the shape the whole milestone is about
// ---------------------------------------------------------------------------

// Before any comparison means anything: the slab has an inside, the binder
// answers in numbers, and it leaves no vertex unheld.
fn void the_slab_binds_to_finite_weights() @test
{
	Slab fixture = slab();
	defer fixture.free();

	test::@check(fixture.voxels.usable(), "the slab has no inside to measure through");

	float[] through = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, through);

	test::@check(all_finite(through), "the binder produced a weight that is not a number");

	usz bones = fixture.skeleton.len();
	for (usz v = 0; v < fixture.mesh.positions.len; v++)
	{
		float total = 0.0f;
		for (usz b = 0; b < bones; b++) total += through[v * bones + b];
		test::@check(total > 0.0f, "vertex %d is left with nothing to hold it", v);
	}
}

<*
 Measuring through the body removes most of the leg-to-leg bleed.

 Both numbers are in the failure message. The assertion is on the improvement
 rather than on an absolute, because a threshold picked to pass today is a
 threshold that stops meaning anything tomorrow.
*>
fn void measuring_through_the_body_removes_the_bleed() @test
{
	Slab fixture = slab();
	defer fixture.free();

	float[] straight = rig::bind_geometric(
		mem, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, straight);

	float[] through = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, through);

	float before = leg_bleed(fixture.mesh.positions, &fixture.skeleton, straight);
	float after = leg_bleed(fixture.mesh.positions, &fixture.skeleton, through);

	// Without this the comparison below could be won by a binder that simply
	// fails to reach anything.
	test::@check(before > 0.05f, "straight-line distance bled only %.1f%% — nothing to improve on",
		before * 100.0f);
	test::@check(after < before * 0.25f, "bleed %.1f%% straight-line against %.1f%% through the body",
		before * 100.0f, after * 100.0f);
}

// The same thing again, seen as motion rather than as a number — a leg that
// holds none of its neighbour's weight does not follow it.
fn void the_still_leg_stops_following_the_swung_one() @test
{
	Slab fixture = slab();
	defer fixture.free();

	float[] straight = rig::bind_geometric(
		mem, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, straight);

	float[] through = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, through);

	float before = swing_travel(fixture.mesh.positions, &fixture.skeleton, straight, HIP_L, 1);
	float after = swing_travel(fixture.mesh.positions, &fixture.skeleton, through, HIP_L, 1);

	test::@check(after < before * 0.25f, "the still leg travels %.4f straight-line, %.4f through the body",
		before, after);
}

<*
 A joint deforms the bone below it, not the bone above it.

 `joint_palette` turns a joint about its own position, so the skin a joint holds
 has to be the skin that swings when it turns: the thigh answers to the hip, the
 shin to the knee, the foot to the ankle. Measuring to the segment that
 *arrives* at a joint puts every limb one link too far down the chain, and the
 error is invisible until a mid-chain joint turns — whereupon the bone above the
 one being bent swings with it.

 The slab's leg is the one bone between `HIP_L` and `FOOT_L`, so there is
 exactly one right answer to who holds it. Nothing else in this file would
 notice getting it wrong: every other check measures bleed from one limb to the
 other, and that stays put whichever end of a bone owns it.
*>
fn void a_joint_owns_the_bone_below_it() @test
{
	Slab fixture = slab();
	defer fixture.free();

	float[] dense = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, dense);

	// The middle half of the leg. Both ends are left out deliberately: at the hip
	// the bone across the pelvis is a fair competitor, and at the foot the two
	// candidate segments meet, so neither answer there is wrong.
	float low = FOOT_Y + (HIP_Y - FOOT_Y) * 0.25f;
	float high = FOOT_Y + (HIP_Y - FOOT_Y) * 0.75f;

	usz bones = fixture.skeleton.len();
	usz counted = 0;
	usz on_the_hip = 0;

	foreach (usz v, position : fixture.mesh.positions)
	{
		if (leg_of(position) != 0) continue;
		if (position.y < low || position.y > high) continue;

		usz best = 0;
		float strongest = dense[v * bones];
		for (usz b = 1; b < bones; b++)
		{
			if (dense[v * bones + b] <= strongest) continue;
			strongest = dense[v * bones + b];
			best = b;
		}

		counted++;
		if (best == HIP_L) on_the_hip++;
	}

	test::@check(counted > 0, "the fixture left no vertices in the middle of the left leg");
	if (counted == 0) return;

	test::@check(on_the_hip == counted,
		"the hip holds %d of %d mid-leg vertices; the rest answer to the foot, which is below them",
		on_the_hip, counted);
}

<*
 A leaf's skin is measured along its bone, not out from a point.

 The last joint of a chain has no child to aim at, so a binder that measures to
 the bone *arriving* at a joint has nothing past the tip to measure against: the
 field goes spherical about the joint exactly where a head, a hand or a foot is.
 `Skeleton.tails` extrudes a leaf half a bone further on and the binder uses
 that, which keeps the field elongated along the limb.

 Two probes at the same distance from the tip say it exactly — one carrying on
 up the limb, one straight out to the side. A spherical field cannot tell them
 apart and holds both equally; a field that runs along the bone holds the one in
 front of it far harder. No mesh: `bind_geometric` weights whatever positions it
 is handed, and triangles would only add tessellation noise to an argument about
 two points.

 Ownership would show none of this — the leaf wins both probes under either
 rule. What it decides is how much the joint below drags the mesh along when it
 turns, which is the whole complaint about a head that smears.
*>
fn void a_leaf_reaches_past_its_tip() @test
{
	Vec3[] joints = alloc::new_array(mem, Vec3, 3);
	int[] parents = alloc::new_array(mem, int, 3);
	Vec3[] probes = alloc::new_array(mem, Vec3, 2);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
		alloc::free(mem, probes);
	}

	joints[0] = { 0, 0, 0 };      parents[0] = -1;
	joints[1] = { 0, 0.35f, 0 };  parents[1] = 0;
	joints[2] = { 0, 0.7f, 0 };   parents[2] = 1;

	const float REACH = 0.2f;
	probes[0] = { 0, 0.7f + REACH, 0 }; // on along the limb
	probes[1] = { REACH, 0.7f, 0 };     // out to the side

	float[] dense = rig::bind_geometric(mem, probes, joints, parents);
	defer alloc::free(mem, dense);

	float ahead = dense[0 * 3 + 2];
	float aside = dense[1 * 3 + 2];

	test::@check(ahead > aside * 10.0f,
		"the leaf holds %.1f in front of its tip and %.1f beside it, a ratio of %.2f — a spherical field gives 1.00",
		ahead, aside, aside > 0.0f ? ahead / aside : 0.0f);
}

// ---------------------------------------------------------------------------
// Reaches
// ---------------------------------------------------------------------------

// A reach per joint, all unlimited. The caller frees it.
fn float[] no_reaches(usz bones)
{
	float[] reaches = alloc::new_array(mem, float, (sz)bones);
	foreach (&reach : reaches) *reach = 0.0f;
	return reaches;
}

<*
 An unlimited reach is not a reach at all.

 Every rig in the library was bound before reaches existed and none of them sets
 one, so the window has to be exactly 1 where no limit was asked for — not
 nearly 1. Anything else silently restates every shipped rig, and the only place
 it would show is somebody's mesh.
*>
fn void a_reach_of_zero_binds_exactly_as_before() @test
{
	Slab fixture = slab();
	defer fixture.free();

	usz bones = fixture.skeleton.len();
	float[] unlimited = no_reaches(bones);
	defer alloc::free(mem, unlimited);

	float[] without = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, without);

	float[] with_zeros = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents,
		reaches: unlimited);
	defer alloc::free(mem, with_zeros);

	usz differing = 0;
	for (usz i = 0; i < without.len; i++)
	{
		if (without[i] != with_zeros[i]) differing++;
	}

	test::@check(differing == 0, "%d of %d weights moved when every reach was set to nothing",
		differing, without.len);
}

// The share below which crig stops reporting a dot as reaching a vertex at all
// — `BLEND_FLOOR` in `app/weights.c3`, restated here rather than imported so
// this file keeps saying what it means by "stops".
const float REPORTED_AT = 0.05f;

<*
 A reach ends a dot's influence, and the mesh it drops is picked up rather than
 lost.

 Both halves matter. Stopping is the point of the feature; the vertices that
 stop answering to a bounded dot still have to answer to something, or a reach
 becomes a way to punch a hole in the skin.

 **"Stops" is a share, not a zero** (M3.7). `reach_bias` has no cutoff in it, so
 the honest question is not whether the bounded hip's weight is exactly 0 out
 here — it never is, for any bone, anywhere — but whether it is small enough
 that nothing downstream can see it. Below `REPORTED_AT` the weights survey does
 not count the dot as reaching the vertex and `sparsify_weights` has four
 stronger influences to keep instead, so the skin cannot move with it.

 Measuring the same band against the same slab bound with no reaches at all is
 what makes this a claim about the reach rather than about the fixture's
 proportions.

 *Re-introduce:* delete the `reach_bias` call from `fill_geometric` and the
 geodesic pass, leaving `1 / (d^2 + eps)`, and the share check fails while the
 stranding check still passes.
*>
fn void a_bounded_dot_stops_reaching_past_its_reach() @test
{
	Slab fixture = slab();
	defer fixture.free();

	usz bones = fixture.skeleton.len();

	float[] unlimited = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, unlimited);

	float[] reaches = no_reaches(bones);
	defer alloc::free(mem, reaches);

	// The left leg's own bone runs hip to foot; a fifth of a leg's length keeps
	// it to its own limb and well short of the other one.
	reaches[HIP_L] = 0.15f;

	float[] dense = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents,
		reaches: reaches);
	defer alloc::free(mem, dense);

	usz far_away = 0;
	usz still_held = 0;
	usz stranded = 0;
	float worst = 0.0f;
	float worst_unbounded = 0.0f;

	foreach (usz v, position : fixture.mesh.positions)
	{
		// Comfortably outside the reach: the bone sits at x = -0.16, so anything
		// past x = 0.1 is more than 0.25 from it whatever its height.
		if (position.x < 0.1f) continue;
		far_away++;

		float total = 0.0f;
		for (usz b = 0; b < bones; b++) total += dense[v * bones + b];
		if (total <= 0.0f) { stranded++; continue; }

		float share = dense[v * bones + HIP_L] / total;
		if (share >= REPORTED_AT) still_held++;
		if (share > worst) worst = share;

		float loose = 0.0f;
		for (usz b = 0; b < bones; b++) loose += unlimited[v * bones + b];
		if (loose <= 0.0f) continue;

		float was = unlimited[v * bones + HIP_L] / loose;
		if (was > worst_unbounded) worst_unbounded = was;
	}

	test::@check(far_away > 0, "the fixture put nothing outside the reach");
	if (far_away == 0) return;

	test::@check(still_held == 0,
		"the bounded hip still holds %d of the %d vertices past its reach at a readable share; worst %.4f",
		still_held, far_away, worst);
	test::@check(stranded == 0,
		"%d of them came out holding nothing at all", stranded);
	test::@check(worst < worst_unbounded,
		"the reach did not lower the hip's grip out here at all: %.4f bounded against %.4f unbounded",
		worst, worst_unbounded);
}

<*
 No reach is small enough to leave a vertex with nothing.

 `sparsify_weights` has no reading for a row that sums to zero. Since M3.7 the
 binder cannot produce one from a reach at all — `reach_bias` ranks a distant
 bone far down but never to nothing — so this is the check that the property
 holds rather than the check that the repair behind it still runs. Set every
 reach to a hair and the whole mesh is bound at the very bottom of the bias at
 once, which is the cheapest way to ask.

 *Re-introduce:* give `reach_bias` a cutoff — `if (d2 >= span) return 0.0f;` —
 and this fails on its own, with every other check in this file still passing.
 That cutoff is what the old `reach_window` was, and what stranding it caused is
 written up on `reach_bias` itself.
*>
fn void no_vertex_is_stranded_by_a_small_reach() @test
{
	Slab fixture = slab();
	defer fixture.free();

	usz bones = fixture.skeleton.len();
	float[] reaches = no_reaches(bones);
	defer alloc::free(mem, reaches);
	foreach (&reach : reaches) *reach = 0.001f;

	float[] dense = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents,
		reaches: reaches);
	defer alloc::free(mem, dense);

	usz stranded = 0;
	for (usz v = 0; v < fixture.mesh.positions.len; v++)
	{
		float total = 0.0f;
		for (usz b = 0; b < bones; b++) total += dense[v * bones + b];
		if (total <= 0.0f) stranded++;
	}

	test::@check(stranded == 0,
		"%d of %d vertices hold nothing once every reach is a thousandth of a unit",
		stranded, fixture.mesh.positions.len);
}

<*
 A reach too small to cover a limb must not hand that limb's skin to the one
 beside it.

 The repair above exists because `sparsify_weights` cannot normalise a row of
 zeros, so a vertex outside every reach has to be given something. What it is
 given is `1 / (d^2 + eps)` against every bone *by straight line* — and from the
 inner face of one leg the other leg's bone is nearer across the gap than its
 own bone is through the meat of its own leg. That is the exact failure this
 whole file exists to remove, re-entering behind it on the rigs likeliest to
 meet it: the carefully bounded ones.

 A reach of 0.08 is under half a leg's width, so the faces fall outside every
 reach and the core stays inside one. That is what tightening a ring until it
 looks right around a joint produces, and it is the rig the other two reach
 checks do not cover: they ask whether a bounded dot stops, and whether anything
 is left holding nothing, but never who picks up what it drops.

 Both halves are measured against the same slab bound with no reaches at all,
 so the claim is that adding a reach does not make the bleed worse — an absolute
 threshold would be a statement about the fixture's proportions instead.

 *Found by:* a bandicoot whose shoes tore apart in pose mode, where the resting
 foot's toe answered to the moving leg's knee at eight per cent.
*>
fn void a_tight_reach_does_not_hand_a_leg_to_its_neighbour() @test
{
	Slab fixture = slab();
	defer fixture.free();

	usz bones = fixture.skeleton.len();

	float[] unlimited = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, unlimited);

	float[] reaches = no_reaches(bones);
	defer alloc::free(mem, reaches);
	foreach (&reach : reaches) *reach = 0.08f;

	float[] bounded = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents,
		reaches: reaches);
	defer alloc::free(mem, bounded);

	float loose = leg_bleed(fixture.mesh.positions, &fixture.skeleton, unlimited);
	float tight = leg_bleed(fixture.mesh.positions, &fixture.skeleton, bounded);

	test::@check(tight <= loose + 0.01f,
		"each leg holds %.2f per cent of the other's skin under a reach of 0.08, against %.2f per cent under none",
		tight * 100.0f, loose * 100.0f);

	// And the same claim as the user meets it: turn one hip, watch the other leg.
	float loose_travel = swing_travel(fixture.mesh.positions, &fixture.skeleton, unlimited, HIP_L, 1);
	float tight_travel = swing_travel(fixture.mesh.positions, &fixture.skeleton, bounded, HIP_L, 1);

	test::@check(tight_travel <= loose_travel + 0.02f,
		"turning the left hip drags the right leg %.4f under a reach of 0.08, against %.4f under none",
		tight_travel, loose_travel);
}

<*
 Well past both reaches, the dot with the longer one still holds more.

 A reach is the user saying how far a dot is meant to carry, and a binder that
 reads only `1 / d^2` out here gives a dot told to keep to itself exactly the
 same standing as one that was not.

 Before M3.7 this band was *stranded* — outside every reach, so every bone
 answered zero and the row fell to a repair, and this test was named for it. The
 cutoff is gone and the band is now bound by the main pass, but the number is
 unchanged to three figures, because `reach_bias` and the geodesic distance it
 reads were always the same on both paths. What changed is that nothing has to
 be rescued for the ranking to happen.

 Measured on the slab's mirror symmetry, which is what makes the claim a
 comparison rather than a threshold: every vertex above the hips has a twin at
 `-x`, so the two hips' totals over that band come out level whenever their
 reaches are — level to within the grid's own asymmetry, which is three parts in
 a thousand here and nowhere near the margin below. Give one hip four times the
 other's and its total has to rise; keep the band clear of both reaches — `0.24`
 is past the wider one from every point of it. It comes out 146-fold (28.6
 against 0.196); the check asks for 1.5.

 *Found by:* a bandicoot whose hood moved when its right shoulder turned. The
 shoulder had a 6 cm ring and the hood's collar was 21 cm away, over the far
 side of the neck, and it held a twelfth of it.
*>
fn void a_longer_reach_outranks_a_shorter_one_far_from_both() @test
{
	Slab fixture = slab();
	defer fixture.free();

	usz bones = fixture.skeleton.len();
	float[] reaches = no_reaches(bones);
	defer alloc::free(mem, reaches);

	// Small enough that the band below sits well past every one of them, deep in
	// the bias where the ranking is all there is, and the right hip's is the only
	// one that differs from its mirror.
	foreach (&reach : reaches) *reach = 0.05f;
	reaches[HIP_R] = 0.20f;

	float[] dense = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents,
		reaches: reaches);
	defer alloc::free(mem, dense);

	float left = 0.0f;
	float right = 0.0f;
	usz counted = 0;

	foreach (usz v, position : fixture.mesh.positions)
	{
		if (position.y < 0.24f) continue;
		counted++;
		left += dense[v * bones + HIP_L];
		right += dense[v * bones + HIP_R];
	}

	test::@check(counted > 0, "the fixture put nothing above the hips");
	if (counted == 0) return;

	test::@check(right > left * 1.5f,
		"over %d vertices past either reach, the hip with a reach of 0.20 holds %.4g against the hip with 0.05 holding %.4g",
		counted, right, left);
}

<*
 With no grid the geodesic binder is the geometric one, number for number.

 Nothing to travel through is not a reason to refuse a rig — a mesh with holes
 in it has no inside, and it still has to bind.
*>
fn void with_no_grid_it_falls_back_to_straight_lines() @test
{
	Slab fixture = slab();
	defer fixture.free();

	float[] straight = rig::bind_geometric(
		mem, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, straight);
	// The binder keeps a vertex to its own chain, which the baseline does not.
	rig::isolate_chains(mem, straight, fixture.skeleton.parents);

	float[] fallback = rig::bind_geodesic(
		mem, null, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, fallback);

	test::@check(fallback.len == straight.len, "the fallback produced %d weights against straight lines' %d", fallback.len, straight.len);
	foreach (usz i, weight : fallback)
	{
		test::@check(weight == straight[i], "weight %d is %.7f with no grid against %.7f without one",
			i, weight, straight[i]);
	}
}

// ---------------------------------------------------------------------------
// The influence limit, which separates a soft body from a mechanical one
// ---------------------------------------------------------------------------

<*
 Four influences blend most of the slab.

 Not for its own sake: it is what makes `one_influence_leaves_every_vertex_on_its_strongest_bone`
 non-vacuous. On a mesh where nothing blends anyway, a broken limit would pass
 unnoticed.
*>
fn void four_influences_blend_most_of_the_slab() @test
{
	Slab fixture = slab();
	defer fixture.free();

	gltf::SkinBinding? bound = rig::bind_skin(
		mem, fixture.mesh.positions, &fixture.skeleton, &fixture.voxels);
	if (catch fault error = bound)
	{
		test::@check(false, "the slab does not bind at four influences (%s)", error);
		return;
	}
	gltf::SkinBinding soft = bound;
	defer soft.free(mem);

	usz blended = 0;
	for (usz v = 0; v < fixture.mesh.positions.len; v++)
	{
		usz held = 0;
		for (usz s = 0; s < soft.slots; s++)
		{
			if (soft.weights[v * soft.slots + s] > 0.0f) held++;
		}
		if (held > 1) blended++;
	}

	test::@check(blended > fixture.mesh.positions.len / 10, "only %d of %d vertices blend at four influences",
		blended, fixture.mesh.positions.len);
}

<*
 At one influence every vertex rides a single bone, at full weight, and it is
 the bone the dense matrix ranks highest.

 Structural rather than visual: this is what makes the territory tint stop being
 an approximation of the bind and become a picture of it. A limit that quietly
 left a second bone at a small weight would still smear the boundary between two
 parts meant to be separate castings, which is the whole thing it exists to stop.
*>
fn void one_influence_leaves_every_vertex_on_its_strongest_bone() @test
{
	Slab fixture = slab();
	defer fixture.free();

	float[] dense = rig::bind_geodesic(
		mem, &fixture.voxels, fixture.mesh.positions, fixture.skeleton.joints, fixture.skeleton.parents);
	defer alloc::free(mem, dense);

	gltf::SkinBinding? bound = rig::bind_skin(
		mem, fixture.mesh.positions, &fixture.skeleton, &fixture.voxels, null, {}, 1);
	if (catch fault error = bound)
	{
		test::@check(false, "the slab does not bind at one influence (%s)", error);
		return;
	}
	gltf::SkinBinding rigid = bound;
	defer rigid.free(mem);

	usz bones = fixture.skeleton.len();
	for (usz v = 0; v < fixture.mesh.positions.len; v++)
	{
		usz held = 0;
		usz which = 0;
		float carried = 0.0f;
		for (usz s = 0; s < rigid.slots; s++)
		{
			float weight = rigid.weights[v * rigid.slots + s];
			if (weight <= 0.0f) continue;
			held++;
			which = (usz)rigid.joints[v * rigid.slots + s];
			carried = weight;
		}

		test::@check(held == 1, "vertex %d rides %d bones at one influence", v, held);
		test::@check(math::abs(carried - 1.0f) < 1.0e-5f,
			"vertex %d rides its bone at %.6f rather than at full weight", v, carried);

		usz strongest = 0;
		for (usz b = 1; b < bones; b++)
		{
			if (dense[v * bones + b] > dense[v * bones + strongest]) strongest = b;
		}
		test::@check(which == strongest, "vertex %d was left on bone %d, not on bone %d which the weights rank highest",
			v, which, strongest);
	}
}

// ---------------------------------------------------------------------------
// Dots and pieces the binder cannot reach
// ---------------------------------------------------------------------------

<*
 A dot outside the mesh keeps the weights it would have had.

 The alternative is a joint that quietly holds nothing, which looks in the
 editor exactly like a joint that is working. Leaving the straight-line column
 in place keeps the misplaced dot visible in the preview, where the user can
 see it and move it.

 It has to be an *unconnected* root, not a child of something inside the body.
 A bone is a segment from its parent, so hanging a far joint off the root gives
 it a segment that starts inside the mesh — and a segment with one end inside
 seeds normally. Unparented, it is a point, and a point outside the body
 touches nothing at all. That is also the case the editor produces: a dot
 placed and never connected exports as an extra skeleton root.
*>
fn void a_dot_outside_the_mesh_keeps_its_column() @test
{
	rig::TriMesh mesh = staple_mesh(mem);
	defer mesh.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, mesh);
	defer voxels.free(mem);

	Vec3[] joints = alloc::new_array(mem, Vec3, 2);
	int[] parents = alloc::new_array(mem, int, 2);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}
	joints[0] = { 0, HEAD_Y * 0.4f, 0 };
	parents[0] = -1;
	joints[1] = { 0, 9.0f, 0 };            // far above the model, touching nothing
	parents[1] = -1;

	float[] through = rig::bind_geodesic(mem, &voxels, mesh.positions, joints, parents);
	defer alloc::free(mem, through);

	for (usz v = 0; v < mesh.positions.len; v++)
	{
		test::@check(through[v * 2 + 1] > 0.0f,
			"the stray dot silently holds nothing of vertex %d", v);
	}
}

<*
 A piece no bone can reach still has weights to be normalised from.

 The pieces are separate bodies, so no path leads from the dots to the far one
 and the geodesic pass leaves that half of the matrix empty — which
 `sparsify_weights` cannot normalise, and which would export as a mesh with a
 hole in its skin. The straight-line repair is what stops that, and two boxes
 are the shape that reaches it: two limbs one voxel apart would not, because a
 single diagonal step is all it takes to make them one body.
*>
fn void an_unreachable_piece_still_has_weights() @test
{
	rig::TriMesh split = two_boxes();
	defer split.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, split);
	defer voxels.free(mem);

	Vec3[] joints;
	int[] parents;
	left_box_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	float[] through = rig::bind_geodesic(mem, &voxels, split.positions, joints, parents);
	defer alloc::free(mem, through);

	usz far_side = 0;
	foreach (usz v, position : split.positions)
	{
		if (position.x <= 0.0f) continue;
		far_side++;
		test::@check(through[v * 2] + through[v * 2 + 1] > 0.0f,
			"vertex %d on the unreachable piece has no weights to normalise from", v);
	}

	test::@check(far_side > 0, "the far piece has no vertices — the fixture is wrong, not the binder");
}

<*
 Half a mesh is too much of it to call a prop.

 The far box is half the mesh, which is what keeps it out of the prop rule: a
 piece that large is a body part, and freezing it is the failure that rule's
 size guard exists to avoid.
*>
fn void a_piece_too_big_to_be_a_prop_keeps_its_blend() @test
{
	rig::TriMesh split = two_boxes();
	defer split.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, split);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, split);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	left_box_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	float[] bound = rig::bind_geodesic(mem, &voxels, split.positions, joints, parents, &shells);
	defer alloc::free(mem, bound);

	test::@check(shells.count == 2, "the two boxes came back as %d shells", shells.count);

	foreach (usz v, position : split.positions)
	{
		if (position.x <= 0.0f) continue;
		test::@check(bound[v * 2] > 0.0f && bound[v * 2 + 1] > 0.0f,
			"vertex %d of a body-sized piece was frozen onto one bone", v);
	}
}

// ---------------------------------------------------------------------------
// A model built one solid per bone: the hard-surface case
// ---------------------------------------------------------------------------

<*
 Thirteen small boxes in a row, each a couple of cells across: a model assembled
 out of solids rather than modelled as a skin.

 The caller frees the mesh.
*>
fn rig::TriMesh a_row_of_solids()
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	for (int i = 0; i < 13; i++)
	{
		float at = -0.50f + (float)i * 0.08f;
		add_box(&positions, &indices, { at, -0.05, -0.05 }, { at + 0.06f, 0.05, 0.05 }, 2);
	}
	return { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
}

<*
 A model made of solids is given a finer grid; a skin is not.

 The whole reason a hand binds badly is that the resolution is quoted on the
 model and a finger is a fraction of one, so a cell spans two fingers and a path
 walks between them in a step. Refining everywhere costs several times as much on
 every model including the ones with nothing finer than a thigh in them, so it is
 spent only where the pieces say it will buy something.

 Three cases, because the middle one is the one a careless rule gets wrong: a
 mesh in one surface, a mesh in a few large pieces, and a mesh in many small
 ones. Only the last is cramped, and being *split* is not on its own the test.
*>
fn void a_model_made_of_solids_gets_a_finer_grid() @test
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}
	add_box(&positions, &indices, { -0.60, -0.25, -0.25 }, { 0.60, 0.25, 0.25 }, 4);
	rig::TriMesh skin = { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
	defer skin.free(mem);

	rig::MeshShells one = rig::build_shells(mem, skin);
	defer one.free(mem);
	test::@check(rig::fitted_resolution(mem, skin, &one) == rig::VOXEL_RESOLUTION,
		"a mesh in one surface was given %d cells rather than the ordinary %d",
		rig::fitted_resolution(mem, skin, &one), rig::VOXEL_RESOLUTION);

	rig::TriMesh row = boxes_in_a_row();
	defer row.free(mem);
	rig::MeshShells few = rig::build_shells(mem, row);
	defer few.free(mem);
	test::@check(few.count == 3, "the three boxes came back as %d pieces", few.count);
	test::@check(rig::fitted_resolution(mem, row, &few) == rig::VOXEL_RESOLUTION,
		"three pieces a third of the model wide were treated as fine detail");

	rig::TriMesh solids = a_row_of_solids();
	defer solids.free(mem);
	rig::MeshShells many = rig::build_shells(mem, solids);
	defer many.free(mem);
	test::@check(many.count == 13, "the row of solids came back as %d pieces", many.count);
	test::@check(rig::fitted_resolution(mem, solids, &many) == rig::VOXEL_RESOLUTION * 2,
		"a model of solids a couple of cells across was left at %d cells",
		rig::fitted_resolution(mem, solids, &many));

	// And the grid really is built at the finer figure, not merely reported.
	rig::MeshVoxels voxels = rig::build_voxels(mem, solids, pieces: &many);
	defer voxels.free(mem);

	Vec3 extent = solids.bounds().extent();
	float longest = math::max(extent.x, math::max(extent.y, extent.z));
	test::@check(voxels.grid.cell < longest / (float)rig::VOXEL_RESOLUTION * 0.75f,
		"the grid was built with %.5f cells against a model %.4f across", voxels.grid.cell, longest);
}

<*
 Three boxes in a row, overlapping enough that a path runs the whole length.

 The arrangement is the one a generator emits for a limb, and it poses both
 halves of the question at once. The first box lies entirely alongside the first
 bone, so it is that bone's outright and has nothing to gain from a falloff. The
 middle box straddles the joint between the first two, so freezing it would weld
 the hinge — and the two are told apart by nothing but where their vertices sit.

 Every box is a third of the mesh, which is deliberate: far over the size bar the
 sword rule works under, so any piece that comes out rigid here came out rigid
 because it is one bone's and not because it is small.

 The caller frees the mesh.
*>
fn rig::TriMesh boxes_in_a_row()
{
	Vec3List positions;
	UintList indices;
	positions.init(mem);
	indices.init(mem);
	defer
	{
		positions.free();
		indices.free();
	}

	add_box(&positions, &indices, { -0.60, -0.25, -0.25 }, { -0.18, 0.25, 0.25 }, 4);
	add_box(&positions, &indices, { -0.22, -0.25, -0.25 }, { 0.22, 0.25, 0.25 }, 4);
	add_box(&positions, &indices, { 0.18, -0.25, -0.25 }, { 0.60, 0.25, 0.25 }, 4);
	return { .positions = positions.to_array(mem), .indices = indices.to_array(mem) };
}

// Three joints down the row, so bone 0 runs -0.40 to 0.00 and bone 1 runs 0.00
// to 0.40. The caller frees both arrays.
fn void row_chain(Vec3[]* joints, int[]* parents)
{
	*joints = alloc::new_array(mem, Vec3, 3);
	*parents = alloc::new_array(mem, int, 3);
	(*joints)[0] = { -0.40f, 0, 0 };
	(*joints)[1] = { 0.00f, 0, 0 };
	(*joints)[2] = { 0.40f, 0, 0 };
	(*parents)[0] = -1;
	(*parents)[1] = 0;
	(*parents)[2] = 1;
}

<*
 A piece that lies wholly alongside one bone is bound to it and nothing else.

 The whole of hard-surface rigging: a solid hinged at its ends does not stretch,
 so every gram of a neighbouring bone's influence on it is a gram of wrong. This
 is also what makes a machine's hand read as fingers rather than as a smear — the
 shipped Mixamo character is ninety-five pieces bound almost exactly this way in
 the weights it arrives with.
*>
fn void a_piece_wholly_one_bones_rides_it_rigidly() @test
{
	rig::TriMesh row = boxes_in_a_row();
	defer row.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, row);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, row);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	row_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	test::@check(shells.count == 3, "the three boxes came back as %d pieces", shells.count);

	int[] riders = alloc::new_array(mem, int, (sz)shells.count);
	defer alloc::free(mem, riders);

	float[] bound = rig::bind_geodesic(
		mem, &voxels, row.positions, joints, parents, &shells, {}, riders);
	defer alloc::free(mem, bound);

	// The first box is a third of the mesh, so the prop rule's size bar cannot
	// have pinned it and the flood reaches it, so neither can the unreached rule.
	test::@check(riders[0] == 0, "the first box rides joint %d rather than the one bone it lies along", riders[0]);

	foreach (usz v, position : row.positions)
	{
		if (shells.of[v] != 0) continue;
		test::@check(bound[v * 3] == 1.0f && bound[v * 3 + 1] == 0.0f && bound[v * 3 + 2] == 0.0f,
			"vertex %d at x %.2f holds (%.3f, %.3f, %.3f) rather than all of its own bone",
			v, position.x, bound[v * 3], bound[v * 3 + 1], bound[v * 3 + 2]);
	}
}

<*
 A piece the joint runs through keeps its falloff, so the hinge still bends.

 The failure this guards is not subtle and not recoverable by hand: a box covering
 both sides of a knuckle, bound rigidly, is a finger that cannot close. It is also
 the common case rather than the exotic one — a generator sizes its boxes to the
 shape it is drawing and not to the skeleton somebody will fit later.
*>
fn void a_piece_that_spans_a_joint_keeps_its_blend() @test
{
	rig::TriMesh row = boxes_in_a_row();
	defer row.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, row);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, row);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	row_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	int[] riders = alloc::new_array(mem, int, (sz)shells.count);
	defer alloc::free(mem, riders);

	float[] bound = rig::bind_geodesic(
		mem, &voxels, row.positions, joints, parents, &shells, {}, riders);
	defer alloc::free(mem, bound);

	test::@check(riders[1] < 0, "the box the joint runs through was frozen onto joint %d", riders[1]);

	usz blended = 0;
	usz members = 0;
	foreach (usz v, id : shells.of)
	{
		if (id != 1) continue;
		members++;
		usz holding = 0;
		for (usz b = 0; b < 3; b++) if (bound[v * 3 + b] > 0.0f) holding++;
		if (holding > 1) blended++;
	}

	test::@check(blended > members / 2, "only %d of %d vertices of the hinged box blend across their bones",
		blended, members);
}

<*
 The same mesh, described as one piece, is left entirely alone.

 The rule reads a *piece* as a solid, and a model in one surface has no pieces to
 read — it is a skin, and a skin stretches. Nothing else in the binder asks
 whether the mesh came apart, so without this guard the rule would reach every
 organic model crig has ever bound correctly.

 The chain is a wide one, under which nine tenths of the whole row is the first
 bone's nearest — so the row is over the bar whether it is read as three pieces
 or as one, and only the split can decide the outcome. The test binds it both
 ways and asserts the two differ, which is the guard stated as directly as it can
 be: the geometry is the same array both times.
*>
fn void a_mesh_in_one_piece_is_never_frozen() @test
{
	rig::TriMesh row = boxes_in_a_row();
	defer row.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, row);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, row);
	defer shells.free(mem);

	// One bone under the whole row, and a leaf past its far end.
	Vec3[] joints = alloc::new_array(mem, Vec3, 2);
	int[] parents = alloc::new_array(mem, int, 2);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}
	joints[0] = { -0.40f, 0, 0 };
	joints[1] = { 0.40f, 0, 0 };
	parents[0] = -1;
	parents[1] = 0;

	int[] split_riders = alloc::new_array(mem, int, (sz)shells.count);
	defer alloc::free(mem, split_riders);

	float[] as_pieces = rig::bind_geodesic(
		mem, &voxels, row.positions, joints, parents, &shells, {}, split_riders);
	defer alloc::free(mem, as_pieces);

	// The premise: read as pieces, this row does get frozen.
	test::@check(split_riders[0] == 0, "the first box rides joint %d, so this fixture no longer poses the question",
		split_riders[0]);

	// One piece by construction rather than by welding the mesh, so the geometry
	// bound twice here is byte for byte the same one.
	int[] whole = alloc::new_array(mem, int, (sz)row.positions.len);
	defer alloc::free(mem, whole);
	rig::MeshShells single = { .of = whole, .count = 1 };

	int[] riders = alloc::new_array(mem, int, 1);
	defer alloc::free(mem, riders);

	float[] as_skin = rig::bind_geodesic(
		mem, &voxels, row.positions, joints, parents, &single, {}, riders);
	defer alloc::free(mem, as_skin);

	test::@check(riders[0] < 0, "a mesh in one piece was frozen onto joint %d", riders[0]);

	usz blended = 0;
	for (usz v = 0; v < row.positions.len; v++)
	{
		if (as_skin[v * 2] > 0.0f && as_skin[v * 2 + 1] > 0.0f) blended++;
	}
	test::@check(blended > row.positions.len / 2,
		"only %d of %d vertices of a one-piece mesh blend, so one surface was bound as solids",
		blended, row.positions.len);
}

// ---------------------------------------------------------------------------
// A loose piece beside a body: the sword case
// ---------------------------------------------------------------------------

// The prop is a shell of its own — everything below is a claim about that shell,
// so a mesh that came back as one piece would make all of them vacuous.
fn void a_loose_prop_is_a_shell_of_its_own() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_with_prop(&body_vertices);
	defer mesh.free(mem);

	rig::MeshShells shells = rig::build_shells(mem, mesh);
	defer shells.free(mem);

	test::@check(shells.count == 2, "the body and the prop came back as %d shells", shells.count);
	test::@check(shells.of[0] == 0, "the first body vertex landed in shell %d", shells.of[0]);
	test::@check(shells.of[mesh.positions.len - 1] == 1, "the last prop vertex landed in shell %d", shells.of[mesh.positions.len - 1]);
}

<*
 Every vertex of the prop holds the same weights, and one joint holds all of
 each — which is what "rigid" means under linear blend skinning.

 Nothing reaches the prop — that is what the gap means — so the binder has no
 distance through the body to weight it by, and the straight-line repair would
 hand the near end to one joint and the far end to another. A prop held at two
 ends by two bones is a prop that bends, and a box strapped to a back does not
 bend.
*>
fn void a_loose_prop_rides_one_bone_rigidly() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_with_prop(&body_vertices);
	defer mesh.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, mesh);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, mesh);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	spine_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	float[] bound = rig::bind_geodesic(mem, &voxels, mesh.positions, joints, parents, &shells);
	defer alloc::free(mem, bound);

	// Rigid is a statement about the rows, not about any one of them: identical
	// rows are what collapse to a single transform under linear blend skinning.
	usz first = body_vertices;
	for (usz v = body_vertices; v < mesh.positions.len; v++)
	{
		usz holding = 0;
		for (usz b = 0; b < 3; b++)
		{
			test::@check(bound[v * 3 + b] == bound[first * 3 + b],
				"prop vertex %d holds %.6f of joint %d where the first holds %.6f",
				v, bound[v * 3 + b], b, bound[first * 3 + b]);
			if (bound[v * 3 + b] > 0.0f) holding++;
		}
		test::@check(holding == 1, "prop vertex %d is held by %d joints, so the piece bends", v, holding);
	}
}

<*
 The prop rides the bone carrying the whole piece, not the one it sits nearest.

 The whole reason the rule sums over subtrees rather than measuring distance. A
 piece spanning two bones is held by neither of them: hang it off the nearer one
 and it swings when that one does, which on a figure is a sword strapped to a
 shoulder instead of to the back it lies across.
*>
fn void a_loose_prop_rides_the_bone_that_carries_it() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_with_prop(&body_vertices);
	defer mesh.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, mesh);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, mesh);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	spine_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	float[] bound = rig::bind_geodesic(mem, &voxels, mesh.positions, joints, parents, &shells);
	defer alloc::free(mem, bound);

	int rides = -1;
	for (usz b = 0; b < 3; b++)
	{
		if (bound[body_vertices * 3 + b] > 0.0f) rides = (int)b;
	}

	// Which bone is merely *nearest* the piece, for the contrast.
	Vec3 centre = { 0, 0, 0 };
	usz prop_vertices = mesh.positions.len - body_vertices;
	for (usz v = body_vertices; v < mesh.positions.len; v++) centre += mesh.positions[v];
	centre = centre * (1.0f / (float)prop_vertices);

	int nearest = 0;
	float best = float::max;
	for (usz b = 0; b < 3; b++)
	{
		Vec3 head = parents[b] >= 0 ? joints[(usz)parents[b]] : joints[b];
		Vec3 axis = joints[b] - head;
		float span = axis.dot(axis);
		float t = span > 0.0f ? math::clamp((centre - head).dot(axis) / span, 0.0f, 1.0f) : 0.0f;
		float d = (centre - (head + axis * t)).length();
		if (d < best) { best = d; nearest = (int)b; }
	}

	test::@check(nearest == 2, "the prop sits nearest joint %d, so this fixture no longer poses the question", nearest);
	test::@check(rides == 1, "the prop rides joint %d rather than joint 1, the bone carrying the whole piece", rides);
}

// The body is not a prop and must come out untouched: a rule that froze the
// mesh it was measuring would pass every check above.
fn void the_body_beside_a_prop_still_blends() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_with_prop(&body_vertices);
	defer mesh.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, mesh);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, mesh);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	spine_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	float[] bound = rig::bind_geodesic(mem, &voxels, mesh.positions, joints, parents, &shells);
	defer alloc::free(mem, bound);

	usz blended = 0;
	for (usz v = 0; v < body_vertices; v++)
	{
		usz holding = 0;
		for (usz b = 0; b < 3; b++) if (bound[v * 3 + b] > 0.0f) holding++;
		if (holding > 1) blended++;
	}

	test::@check(blended > body_vertices / 2, "only %d of %d body vertices blend across their own joints",
		blended, body_vertices);
}

<*
 An attachment moves the whole piece to the joint it names.

 The user's answer beats the binder's. Which bone a prop rides is a fact about
 the character — a scabbard is strapped to a torso however near the shoulder it
 hangs — so an attachment is obeyed rather than weighed.
*>
fn void an_attachment_overrides_the_binder() @test
{
	usz body_vertices;
	rig::TriMesh mesh = body_with_prop(&body_vertices);
	defer mesh.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, mesh);
	defer voxels.free(mem);
	rig::MeshShells shells = rig::build_shells(mem, mesh);
	defer shells.free(mem);

	Vec3[] joints;
	int[] parents;
	spine_chain(&joints, &parents);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	int[] attachments = alloc::new_array(mem, int, 2);
	defer alloc::free(mem, attachments);
	attachments[0] = -1;
	attachments[1] = 0;

	int[] riders = alloc::new_array(mem, int, 2);
	defer alloc::free(mem, riders);

	float[] pinned = rig::bind_geodesic(
		mem, &voxels, mesh.positions, joints, parents, &shells, attachments, riders);
	defer alloc::free(mem, pinned);

	for (usz v = body_vertices; v < mesh.positions.len; v++)
	{
		test::@check(pinned[v * 3] == 1.0f && pinned[v * 3 + 1] == 0.0f && pinned[v * 3 + 2] == 0.0f,
			"prop vertex %d holds (%.4f, %.4f, %.4f) rather than all of the joint it was pinned to",
			v, pinned[v * 3], pinned[v * 3 + 1], pinned[v * 3 + 2]);
	}

	// And says so, which is what the tint views read to grey a pinned piece out.
	test::@check(riders[1] == 0, "the prop was reported as riding %d rather than the joint it was pinned to", riders[1]);
	test::@check(riders[0] < 0, "the body was reported as a rider at %d", riders[0]);
}

// ---------------------------------------------------------------------------
// A real model
// ---------------------------------------------------------------------------

<*
 The binder survives a real mesh at a real vertex count.

 Only what holds for any model is asserted: the numbers — how much of the
 bounding box is interior, how many vertices strand, how long a rebind takes —
 are properties of the mesh and of where its dots would go, so they appear in
 the failure messages rather than as thresholds.
*>
fn void a_real_mesh_binds_without_stranding_a_vertex() @test
{
	rig::TriMesh? loaded = rig::load_gltf(mem, REAL_MESH);
	if (catch fault error = loaded)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", REAL_MESH, error);
		return;
	}
	rig::TriMesh geometry = loaded;
	defer geometry.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);

	test::@check(voxels.usable(), "%s has no inside — the geodesic binder cannot be exercised on it", REAL_MESH);

	// A chain down the longest axis, standing in for dots the user would place.
	usz chain = 12;
	Vec3[] joints = alloc::new_array(mem, Vec3, (sz)chain);
	int[] parents = alloc::new_array(mem, int, (sz)chain);
	defer
	{
		alloc::free(mem, joints);
		alloc::free(mem, parents);
	}

	rig::Bounds bounds = geometry.bounds();
	Vec3 extent = bounds.extent();
	Vec3 center = bounds.center();
	int axis = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2);
	for (usz i = 0; i < chain; i++)
	{
		float t = (float)i / (float)(chain - 1);
		joints[i] = center;
		joints[i][axis] = bounds.min[axis] + extent[axis] * (0.1f + t * 0.8f);
		parents[i] = i == 0 ? -1 : (int)i - 1;
	}

	float[] dense = rig::bind_geodesic(mem, &voxels, geometry.positions, joints, parents);
	defer alloc::free(mem, dense);

	test::@check(all_finite(dense), "a real mesh produced a weight that is not a number");

	for (usz v = 0; v < geometry.positions.len; v++)
	{
		float total = 0.0f;
		for (usz b = 0; b < chain; b++) total += dense[v * chain + b];
		test::@check(total > 0.0f, "vertex %d of a real mesh is left with nothing to hold it", v);
	}
}

// A closed square tube along +X, `rings` cross-sections from 0 to `length`.
fn rig::TriMesh tube(List{Vec3}* positions, List{uint}* indices, float length, float width, uint rings)
{
	float h = width * 0.5f;
	Vec2[4] corners = { { -h, -h }, { h, -h }, { h, h }, { -h, h } };
	for (uint r = 0; r < rings; r++)
	{
		float x = length * (float)r / (float)(rings - 1);
		foreach (c : corners) positions.push({ x, c.x, c.y });
	}
	for (uint r = 0; r + 1 < rings; r++)
	{
		for (uint k = 0; k < 4; k++)
		{
			uint a = r * 4 + k;
			uint b = r * 4 + (k + 1) % 4;
			indices.push(a); indices.push(b); indices.push(a + 4);
			indices.push(b); indices.push(b + 4); indices.push(a + 4);
		}
	}
	uint last = (rings - 1) * 4;
	indices.push(0); indices.push(2); indices.push(1);
	indices.push(0); indices.push(3); indices.push(2);
	indices.push(last); indices.push(last + 1); indices.push(last + 2);
	indices.push(last); indices.push(last + 2); indices.push(last + 3);
	return { .positions = positions.array_view(), .indices = indices.array_view() };
}

<*
 Joints closer together than one voxel still split the skin between them. The
 flood measures in whole cells, so on a small hand two finger joints in the one
 cell used to come out the same distance — none — from everything around them,
 and one took the whole finger.
*>
fn void joints_inside_one_voxel_still_split_the_skin() @test
{
	List{Vec3} positions;
	positions.init(mem);
	defer positions.free();
	List{uint} indices;
	indices.init(mem);
	defer indices.free();
	rig::TriMesh mesh = tube(&positions, &indices, 1.0f, 0.012f, 101);

	rig::MeshVoxels voxels = rig::build_voxels(mem, mesh, 8);
	defer voxels.free(mem);
	test::@check(voxels.usable(), "the tube has no inside to measure through");

	// Three short bones end to end, all inside one 0.125-wide cell.
	Vec3[4] joints = { { 0.40f, 0, 0 }, { 0.44f, 0, 0 }, { 0.48f, 0, 0 }, { 0.52f, 0, 0 } };
	int[4] parents = { -1, 0, 1, 2 };
	float[] through = rig::bind_geodesic(mem, &voxels, mesh.positions, joints[..], parents[..]);
	defer alloc::free(mem, through);

	usz bones = joints.len;
	usz[4] owned;
	for (usz v = 0; v < mesh.positions.len; v++)
	{
		float x = mesh.positions[v].x;
		if (x < 0.405f || x > 0.475f) continue;
		usz best = 0;
		for (usz b = 1; b < bones; b++) if (through[v * bones + b] > through[v * bones + best]) best = b;
		// Within each bone's own stretch, that bone is strongest.
		usz expected = x < 0.44f ? 0 : 1;
		if (math::abs(x - 0.44f) < 0.006f) continue;
		test::@check(best == expected, "vertex at x=%.3f is held most by bone %d, not %d", x, best, expected);
		owned[best]++;
	}
	test::@check(owned[0] > 0 && owned[1] > 0, "the bones did not split the stretch: %d / %d", owned[0], owned[1]);
}

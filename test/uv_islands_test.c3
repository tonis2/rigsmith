// UV islands: the pieces a texture layout cuts a mesh into, and the Area tool's
// part built from them. The body is a tube in four islands stacked along y,
// each seam a ring of vertices copied with another uv, rigged by a two-bone
// chain whose joint sits on the middle seam.
module crig_tests::uv_islands;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::vector;

const usz TUBE_SIDES = 8;
const usz TUBE_ISLANDS = 4;
const usz ISLAND_RINGS = 3; // the rings of one island: the seam rings are copied, one per side
const float RING_STEP = 0.25;
const float TUBE_RADIUS = 0.2;

// The tube, with each island's uvs shifted off the others' when `seams` is set,
// or one layout across it when not (the copies are then a hard edge, not a seam).
fn rig::TriMesh tube(Vec2[]* uvs_out, bool seams)
{
	usz per_island = ISLAND_RINGS * TUBE_SIDES;
	Vec3[] positions = mem::new_array(Vec3, (sz)(TUBE_ISLANDS * per_island));
	Vec2[] uvs = mem::new_array(Vec2, (sz)positions.len);
	uint[] indices = mem::new_array(uint, (sz)(TUBE_ISLANDS * (ISLAND_RINGS - 1) * TUBE_SIDES * 6));
	usz at = 0;
	for (usz island = 0; island < TUBE_ISLANDS; island++)
	{
		for (usz ring = 0; ring < ISLAND_RINGS; ring++)
		{
			float y = (float)(island * (ISLAND_RINGS - 1) + ring) * RING_STEP;
			for (usz side = 0; side < TUBE_SIDES; side++)
			{
				float turn = (float)side / (float)TUBE_SIDES * (float)math::PI * 2.0f;
				usz v = (island * ISLAND_RINGS + ring) * TUBE_SIDES + side;
				positions[v] = { math::cos(turn) * TUBE_RADIUS, y, math::sin(turn) * TUBE_RADIUS };
				uvs[v] = { (float)side / (float)TUBE_SIDES + (seams ? (float)island * 2.0f : 0.0f), y };
			}
		}
		for (usz ring = 0; ring + 1 < ISLAND_RINGS; ring++)
		{
			uint here = (uint)((island * ISLAND_RINGS + ring) * TUBE_SIDES);
			uint next = here + (uint)TUBE_SIDES;
			for (uint side = 0; side < (uint)TUBE_SIDES; side++)
			{
				uint across = (side + 1) % (uint)TUBE_SIDES;
				uint[6] quad = { here + side, next + side, next + across, here + side, next + across, here + across };
				foreach (index : quad) indices[at++] = index;
			}
		}
	}
	*uvs_out = uvs;
	return { .positions = positions, .indices = indices };
}

fn int island_of_vertex(sz v) => (int)(v / (sz)(ISLAND_RINGS * TUBE_SIDES));

// Which islands a vertex mask takes in, as one bit each.
fn uint islands_in(bool[] mask)
{
	uint bits = 0;
	foreach (v, on : mask)
	{
		if (on) bits |= 1u << (uint)island_of_vertex(v);
	}
	return bits;
}

// Whether a mask is exactly the islands in `bits`, every vertex of each.
fn bool exactly(bool[] mask, uint bits)
{
	foreach (v, on : mask)
	{
		if (on != (((bits >> (uint)island_of_vertex(v)) & 1u) != 0)) return false;
	}
	return true;
}

fn void a_seam_parts_islands_and_a_hard_edge_does_not() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}

	rig::MeshShells islands = rig::build_uv_islands(mem, mesh, uvs);
	defer islands.free(mem);
	test::eq(islands.count, TUBE_ISLANDS);
	foreach (v, id : islands.of)
	{
		test::@check(id == island_of_vertex(v), "vertex %d is in island %d, not %d", v, id, island_of_vertex(v));
	}
	rig::MeshShells shells = rig::build_shells(mem, mesh);
	defer shells.free(mem);
	test::eq(shells.count, (usz)1);

	// The same copies with one layout across them: a hard edge, one island.
	foreach (v, &uv : uvs) uv.x -= (float)island_of_vertex(v) * 2.0f;
	rig::MeshShells closed = rig::build_uv_islands(mem, mesh, uvs);
	defer closed.free(mem);
	test::eq(closed.count, (usz)1);
}

// The tube in an app with its islands handed over, rigged hip → knee → tip with
// the knee on the middle seam: the hip's bone runs through islands 0 and 1.
fn uint rigged_tube(crig::AppState* app, Vec2[] uvs)
{
	app.uv_islands = rig::build_uv_islands(mem, app.geometry, uvs);
	app.uv_islands_read = true;
	app.uv_islands_geometry = app.geometry_generation;

	app.select(0);
	uint hip = app.place({ 0, 0.02f, 0 });
	app.select(hip);
	uint knee = app.place({ 0, 1.0f, 0 });
	app.select(knee);
	app.place({ 0, 1.98f, 0 });
	app.select(hip);
	return hip;
}

fn void the_uv_islands_part_takes_whole_islands_and_steps_by_them() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}
	crig::AppState app = crig::new_app(mesh);
	defer app.free();

	// Before any islands are known the part is refused, not empty.
	test::@check(!app.area_has_islands(), "a mesh with no uvs read claims islands");
	uint hip = rigged_tube(&app, uvs);
	test::@check(app.area_has_islands(), "four islands on one piece are not a part of their own");

	test::@check(app.begin_area(), "the Area tool did not open on the hip");
	test::@check(app.set_area_part(ISLANDS), "the hip holds no islands: %s", app.notice());
	test::@check(app.area_islands, "the part is not marked as islands");
	test::@check(exactly(app.area_mask, 0b0011), "the hip's islands are %b, not the lower two", islands_in(app.area_mask));
	test::eq(app.area_island_count(), (usz)2);

	// Grow takes the island across the seam; shrink walks it back.
	test::@check(app.resize_area(1), "grow did not add an island");
	test::@check(exactly(app.area_mask, 0b0111), "grow took %b, not the next island up", islands_in(app.area_mask));
	test::@check(app.area_islands, "growing by islands dropped the island mode");
	test::@check(app.resize_area(-1), "shrink did not take an island off");
	test::@check(exactly(app.area_mask, 0b0011), "shrink left %b, not the hip's own islands", islands_in(app.area_mask));

	// Past its own islands a shrink keeps the largest, never empties the part.
	test::@check(app.resize_area(-1), "shrink stopped at the hip's own islands");
	test::eq(app.area_island_count(), (usz)1);
	test::@check(!app.resize_area(-1), "shrink took the last island");
	test::eq(app.area_island_count(), (usz)1);
	uint left = islands_in(app.area_mask);

	// A click adds the island under it and a second click takes it out again.
	usz top_vertex = app.geometry.positions.len - 1;
	test::@check(app.area_click((sz)top_vertex), "a click did not add the top island");
	test::@check(exactly(app.area_mask, left | 0b1000), "the click left %b", islands_in(app.area_mask));
	test::@check(app.area_click((sz)top_vertex), "a second click did not take the top island out");
	test::@check(exactly(app.area_mask, left), "the second click left %b", islands_in(app.area_mask));

	// The last island can go too, and an empty part is not applied.
	sz last = -1;
	foreach (v, on : app.area_mask) if (on) { last = (sz)v; break; }
	test::@check(app.area_click(last), "the last island could not be taken out");
	test::@check(app.area_pending() && app.area_empty(), "taking the last island out did not leave an empty part");
	test::eq(app.commit_area(), (usz)0);
	test::@check(app.notice().contains("island"), "an empty part was refused without saying why: %s", app.notice());

	// Applied, the hip moves its islands and nothing past the seam.
	app.area_soft = 0.0f;
	test::@check(app.set_area_part(ISLANDS), "could not pick the islands again");
	test::@check(app.commit_area() > 0, "applying the islands wrote nothing");
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz joint = (usz)view.joint_of(hip);
	float[] painted = app.painted_bind(mem, &view);
	defer alloc::free(mem, painted);
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		sz owner = crig::row_owner(painted[v * bones:bones]);
		bool mine = owner == (sz)joint;
		test::@check(mine == (island_of_vertex((sz)v) < 2), "vertex %d (island %d) applied to the wrong joint", v, island_of_vertex((sz)v));
	}
}

fn void the_ladder_has_an_islands_rung_only_when_the_layout_cuts_the_mesh() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}
	crig::AppState app = crig::new_app(mesh);
	defer app.free();
	rigged_tube(&app, uvs);
	test::@check(app.begin_area(), "the Area tool did not open");

	test::@check(app.set_area_part(OWN), "the hip has no own part");
	test::@check(app.step_area(1) && app.area_part == WITH_CHILDREN, "one step up is not with children");
	test::@check(app.step_area(1) && app.area_part == ISLANDS, "two steps up is not UV islands");
	app.step_area(1);
	test::@check(app.area_part == OWN, "a one-piece tube has a rung past islands");

	// The same tube with no seams has no islands to pick.
	app.end_area();
	foreach (v, &uv : uvs) uv.x -= (float)island_of_vertex(v) * 2.0f;
	app.uv_islands.free(mem);
	app.uv_islands = rig::build_uv_islands(mem, app.geometry, uvs);
	test::@check(!app.area_has_islands(), "one island claimed to cut the mesh");
	test::@check(app.begin_area(), "the Area tool did not reopen");
	test::@check(!app.set_area_part(ISLANDS), "UV islands was picked on a mesh with no seams");
	test::@check(app.notice().contains("UV"), "the refusal did not say why: %s", app.notice());
}

// The tube's Area tool on the hip with the hip's own islands picked.
fn void open_islands(crig::AppState* app, Vec2[] uvs)
{
	rigged_tube(app, uvs);
	test::@check(app.begin_area(), "the Area tool did not open on the hip");
	test::@check(app.set_area_part(ISLANDS), "the hip holds no islands: %s", app.notice());
}

fn sz vertex_in_island(usz island) => (sz)(island * ISLAND_RINGS * TUBE_SIDES + 1);

fn void islands_can_be_cleared_and_picked_one_by_one() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}
	crig::AppState app = crig::new_app(mesh);
	defer app.free();
	open_islands(&app, uvs);

	test::@check(app.clear_area_islands(), "Clear did nothing");
	test::@check(app.area_islands && app.area_pending() && app.area_empty(), "Clear did not leave an empty island part");
	test::eq(app.commit_area(), (usz)0);

	test::@check(app.pick_area_island(vertex_in_island(0), ADD), "adding the bottom island did nothing");
	test::@check(app.pick_area_island(vertex_in_island(3), ADD), "adding the top island did nothing");
	test::@check(!app.pick_area_island(vertex_in_island(3), ADD), "adding an island already in changed the part");
	test::@check(exactly(app.area_mask, 0b1001), "picked %b, not the bottom and top islands", islands_in(app.area_mask));
	test::@check(app.pick_area_island(vertex_in_island(3), REMOVE), "removing the top island did nothing");
	test::@check(exactly(app.area_mask, 0b0001), "left %b, not the bottom island", islands_in(app.area_mask));
	test::@check(!app.pick_area_island(vertex_in_island(2), REMOVE), "removing an island not in changed the part");

	// Shift and ctrl clicks on the mesh go through the same picks.
	test::@check(app.area_click(vertex_in_island(2), ADD), "a shift-click did not add");
	test::@check(exactly(app.area_mask, 0b0101), "the shift-click left %b", islands_in(app.area_mask));
	test::@check(app.commit_area() > 0, "the picked islands were not applied");
}

fn void invert_takes_the_other_islands() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}
	crig::AppState app = crig::new_app(mesh);
	defer app.free();
	open_islands(&app, uvs);

	test::@check(exactly(app.area_mask, 0b0011), "the hip's own islands are %b", islands_in(app.area_mask));
	test::@check(app.invert_area_islands(), "Invert did nothing");
	test::@check(exactly(app.area_mask, 0b1100), "Invert left %b, not the upper two", islands_in(app.area_mask));
	test::@check(app.area_islands, "Invert dropped the island mode");
}

fn void painting_islands_sets_each_island_crossed() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}
	crig::AppState app = crig::new_app(mesh);
	defer app.free();
	open_islands(&app, uvs);

	test::@check(app.begin_island_paint(vertex_in_island(2), add: true), "painting in did not start");
	app.island_paint_to(vertex_in_island(2) + 3);
	app.island_paint_to(vertex_in_island(3));
	test::@check(exactly(app.area_mask, 0b1111), "painting in left %b", islands_in(app.area_mask));

	test::@check(app.begin_island_paint(vertex_in_island(3), add: false), "painting out did not start");
	app.island_paint_to(vertex_in_island(2));
	test::@check(exactly(app.area_mask, 0b0011), "painting out left %b", islands_in(app.area_mask));
}

fn void hovering_an_island_changes_only_on_a_new_island() @test
{
	Vec2[] uvs;
	rig::TriMesh mesh = tube(&uvs, seams: true);
	defer
	{
		mesh.free(mem);
		free(uvs);
	}
	crig::AppState app = crig::new_app(mesh);
	defer app.free();
	open_islands(&app, uvs);

	uint start = app.area_generation;
	app.hover_area_island(app.island_under(vertex_in_island(1)));
	test::eq(app.area_hover_island, 1);
	test::eq(app.area_generation, start + 1);
	app.hover_area_island(app.island_under(vertex_in_island(1) + 2));
	test::eq(app.area_generation, start + 1);
	app.hover_area_island(app.island_under(-1));
	test::eq(app.area_hover_island, -1);

	// Off the islands part there is nothing to light.
	app.set_area_part(OWN);
	app.hover_area_island(1);
	test::eq(app.area_hover_island, -1);
}

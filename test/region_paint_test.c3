// Vertices by where they are: get_vertices reads a region's positions, and the
// same region keys narrow paint_weights, so no caller parses the model for numbers.
module crig_tests::region_paint;

import crig;
import crig_tests::mcp;
import std::collections::object;
import std::core::test;
import std::io;
import std::math;

const String HUMANOID = "assets/animations/humanoid.glb";

<*
 Each part of a region narrows it: a box, a height range, a side, a shell.
*>
fn void a_region_narrows_by_each_part() @test
{
	Vec3[4] at = { { 1, 0.5f, 0 }, { -1, 0.5f, 0 }, { 0, 2, 0 }, { 0.0001f, 0.2f, 0 } };
	int[4] shell = { 0, 0, 1, 1 };
	crig::VertexRegion all = {};
	test::@check(crig::region_vertices(mem, &all, at[..], shell[..]).len == 4, "an empty region did not hold everything");

	crig::VertexRegion left = { .side = LEFT };
	uint[] lefts = crig::region_vertices(mem, &left, at[..], shell[..]);
	defer alloc::free(mem, lefts);
	test::@check(lefts.len == 2 && lefts[0] == 0 && lefts[1] == 3, "the left side is not the +X vertices");

	crig::VertexRegion middle = { .side = MIDDLE, .middle = 0.01f };
	uint[] mids = crig::region_vertices(mem, &middle, at[..], shell[..]);
	defer alloc::free(mem, mids);
	test::@check(mids.len == 2, "the middle holds %d vertices, not the two on the plane", mids.len);

	crig::VertexRegion low = { .banded = true, .from = 0, .to = 1 };
	low.shells[0] = 1;
	low.shell_count = 1;
	uint[] lows = crig::region_vertices(mem, &low, at[..], shell[..]);
	defer alloc::free(mem, lows);
	test::@check(lows.len == 1 && lows[0] == 3, "shell 1 below a height of 1 is not the one vertex");

	crig::VertexRegion boxed = { .boxed = true, .low = { -2, 0, -1 }, .high = { 0, 1, 1 } };
	uint[] inside = crig::region_vertices(mem, &boxed, at[..], shell[..]);
	defer alloc::free(mem, inside);
	test::@check(inside.len == 1 && inside[0] == 1, "the box holds the wrong vertices");
}

<*
 get_vertices hands over exactly the region's vertices with their positions; a
 paint over the same region writes the same vertices and no others.
*>
fn void paint_by_region_writes_the_vertices_get_vertices_lists() @test
{
	io::printn("region paint: get_vertices and paint_weights agree on a region");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	crig::Dot* knee = f.app.dot_named("knee_L");
	if (!knee) return;
	float height = f.app.model_height();
	float from = knee.position.y - height * 0.03f;
	float to = knee.position.y + height * 0.03f;
	String region = string::tformat(`"height":[%f,%f],"side":"left"`, from, to);

	Object* listed = f.call_checked("get_vertices", string::tformat(`{%s,"owners":true}`, region));
	if (!listed) return;
	defer listed.free();
	long count = listed.get_int("count") ?? 0;
	Object* indices = crig::member(listed, "indices");
	Object* positions = crig::member(listed, "positions");
	Object* owners = crig::member(listed, "owners");
	test::@check(count > 4 && indices && indices.get_len() == count, "the left knee's band lists %d vertices", count);
	test::@check(positions && positions.get_len() == count && owners && owners.get_len() == count, "the positions or owners do not match the indices");
	if (!indices || !positions) return;
	for (usz i = 0; i < (usz)indices.get_len(); i++)
	{
		Vec3 p;
		test::@check(crig::as_vec3(positions.get_at((sz)i), &p), "a position is not three numbers");
		uint v = (uint)(indices.get_int_at((sz)i) ?? 0);
		test::@check(p == f.app.geometry.positions[v], "vertex %d is not where get_vertices says", v);
		test::@check(p.x > f.app.doc.sym_x && p.y >= from && p.y <= to, "vertex %d is outside the region", v);
	}

	Object* painted = f.call_checked("paint_weights", string::tformat(`{"dot":"knee_L","weight":1,%s}`, region));
	if (!painted) return;
	defer painted.free();
	test::@check((painted.get_int("selected") ?? -1) == count, "the paint selected %d vertices, not the %d listed",
		painted.get_int("selected") ?? -1, count);
}

<*
 A skirt's worth of the torso weighted as cloth: every vertex rides the hips and
 its own side's thigh and nothing else, the thighs come in toward the bottom and
 the sides and stay off the middle, and one undo takes it all back.
*>
fn void a_region_blended_as_cloth_rides_its_top_and_its_side() @test
{
	io::printn("region paint: blend_weights weights a skirt as cloth");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(HUMANOID)) return;
	defer f.close();
	crig::AppState* app = &f.app;

	crig::Dot* hips = app.dot_named("hips");
	if (!hips) return;
	float height = app.model_height();
	float from = hips.position.y - height * 0.08f;
	float to = hips.position.y + height * 0.02f;
	String args = string::tformat(`{"top":"hips","sides":["thigh_L","thigh_R"],"height":[%f,%f]}`, from, to);
	crig::RigView before_view = app.open_rig(mem)!!;
	float[] before = app.weights(mem, &before_view);
	before_view.free(mem);
	defer alloc::free(mem, before);
	Object* blended = f.call_checked("blend_weights", args);
	if (!blended) return;
	defer blended.free();
	long selected = blended.get_int("selected") ?? 0;
	test::@check(selected > 10, "the band selected %d vertices", selected);
	// The humanoid's file brings its own weights, so its joints are held already
	// and none is newly held; the list is still there to say so.
	Object* held = crig::member(blended, "held");
	test::@check(held != null && held.is_array(), "the answer does not list the joints it held");

	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	float[] dense = app.weights(mem, &view);
	defer alloc::free(mem, dense);
	usz bones = view.len();
	sz hip = view.joint_of(app.dot_named("hips").id);
	sz left = view.joint_of(app.dot_named("thigh_L").id);
	sz right = view.joint_of(app.dot_named("thigh_R").id);
	float bottom_side = 0.0f;
	float worst_middle = 0.0f;
	usz strays = 0;
	usz crossed = 0;
	foreach (usz v, p : app.geometry.positions)
	{
		if (p.y < from || p.y > to) continue;
		float total = 0.0f;
		for (usz j = 0; j < bones; j++) total += dense[v * bones + j];
		if (total <= 0.0f) continue;
		for (usz j = 0; j < bones; j++)
		{
			if (j == (usz)hip || j == (usz)left || j == (usz)right) continue;
			if (dense[v * bones + j] / total > 1.0e-3f) strays++;
		}
		float l = dense[v * bones + (usz)left] / total;
		float r = dense[v * bones + (usz)right] / total;
		if ((p.x > app.doc.sym_x && r > 1.0e-3f) || (p.x < app.doc.sym_x && l > 1.0e-3f)) crossed++;
		float side = math::max(l, r);
		if (math::abs(p.x - app.doc.sym_x) < height * 0.005f) worst_middle = math::max(worst_middle, side);
		bottom_side = math::max(bottom_side, side);
	}
	test::@check(strays == 0, "%d vertices of the band are still held by other joints", strays);
	test::@check(crossed == 0, "%d vertices took the thigh on the other side", crossed);
	test::@check(worst_middle <= 0.8f * 0.15f + 1.0e-3f, "the middle took %f of a thigh", worst_middle);
	// The humanoid's torso narrows to the crotch, so its widest point is at the
	// band's top: the thighs come in there, more than at the middle, under share.
	test::@check(bottom_side > 0.24f && bottom_side <= 0.8f + 1.0e-3f, "the band's sides took %f of a thigh", bottom_side);

	Object* undone = f.call_checked("undo", "{}");
	if (undone) undone.free();
	crig::RigView again = app.open_rig(mem)!!;
	defer again.free(mem);
	float[] after = app.weights(mem, &again);
	defer alloc::free(mem, after);
	usz differ = 0;
	foreach (usz i, w : after) if (i < before.len && w != before[i]) differ++;
	test::@check(after.len == before.len && differ == 0, "undo left %d weights changed", differ);
}

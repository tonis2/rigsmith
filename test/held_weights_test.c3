// A joint's weights are automatic until it is edited and its own from then on:
// no edit to one joint, and nothing the rig does around it, moves another
// joint's weights. On the shipped humanoid, on crig's automatic weights.
module crig_tests::held_weights;

import crig;
import rig;
import std::core::test;
import std::io::file;
import std::math;

const String HELD_COPY = "build/held-weights-humanoid.glb";

fn void open_held(crig::AppState* app, rig::TriMesh* mesh)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(HELD_COPY, original)!!;
	*mesh = rig::load_gltf(mem, HELD_COPY)!!;
	*app = crig::new_app(*mesh, HELD_COPY);
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	(void)app.release_all_recorded();
	app.mark_rig_stale();
	app.undo_stack.clear();
	app.area_solo = true;
}

fn void close_held(crig::AppState* app, rig::TriMesh* mesh)
{
	app.free();
	mesh.free(mem);
	(void)file::delete(HELD_COPY);
	String sidecar = crig::session_path(mem, HELD_COPY);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

fn uint held_dot(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

fn float[] held_matrix(crig::AppState* app, usz* bones)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	*bones = view.len();
	return app.weights(mem, &view);
}

fn usz held_joint(crig::AppState* app, uint dot)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return (usz)view.joint_of(dot);
}

// Up to four vertices the ankle holds most of, given to it wholly: its weight
// full and every other joint off them.
fn usz ankle_alone(crig::AppState* app, uint ankle, uint[] out)
{
	usz bones;
	float[] shown = held_matrix(app, &bones);
	defer alloc::free(mem, shown);
	usz a = held_joint(app, ankle);
	usz found = 0;
	for (usz v = 0; v < app.geometry.positions.len && found < out.len; v++)
	{
		if (crig::row_owner(shown[v * bones:bones]) == (sz)a) out[found++] = (uint)v;
	}
	foreach (dot : app.doc.dots.array_view()) app.set_weight_vertices(out[:found], dot.id, dot.id == ankle ? 1.0f : 0.0f);
	return found;
}

// Entries outside joint `except` that differ between two matrices, bit for bit.
fn usz moved_outside(float[] before, float[] after, usz bones, usz except)
{
	if (before.len != after.len) return before.len + after.len + 1;
	usz moved = 0;
	foreach (usz i, w : before) if (i % bones != except && after[i] != w) moved++;
	return moved;
}

<*
 The first edit to a joint holds it, starting from the column it showed, so
 the one vertex edited is the only number that moves anywhere.

 *Re-introduce:* hold the joint without copying its automatic column, and every
 vertex it held drops to nothing.
*>
fn void the_first_edit_holds_a_joint_and_moves_only_what_it_edits() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_held(&app, &mesh);
	defer close_held(&app, &mesh);

	uint knee = held_dot(&app, "knee_L");
	usz k = held_joint(&app, knee);
	usz bones;
	float[] before = held_matrix(&app, &bones);
	defer alloc::free(mem, before);
	test::@check(!app.weights_held(knee), "the knee started held");

	uint[1] one = { 0 };
	for (usz v = 0; v < app.geometry.positions.len; v++)
	{
		if (before[v * bones + k] > 0.3f) { one[0] = (uint)v; break; }
	}
	app.set_weight_vertices(one[..], knee, 0.25f);
	test::@check(app.weights_held(knee), "an edit did not hold the knee");

	float[] after = held_matrix(&app, &bones);
	defer alloc::free(mem, after);
	usz moved = 0;
	foreach (usz i, w : before) if (after[i] != w && i != (usz)one[0] * bones + k) moved++;
	test::@check(moved == 0, "editing one vertex of the knee moved %d other weights", moved);
	test::@check(after[(usz)one[0] * bones + k] == 0.25f, "the edit did not land");

	// And taken back whole: the knee follows the automatic weights again.
	test::@check(app.undo(), "the first edit left nothing to undo");
	test::@check(!app.weights_held(knee) && app.doc.pins.len() == 0, "undoing the first edit left the knee held");
}

<*
 Grow, Shrink and Soft edge reshape one joint and no other: every neighbour's
 column is bit for bit what it was, automatic ones included — the grow is read
 in the joint's own bind, never in the one its neighbours follow.

 *Re-introduce:* put the grows and soft edges back into `bind_key` and the live
 bind, and the neighbours' windows move with the grown joint.
*>
fn void an_edge_moves_no_neighbour() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_held(&app, &mesh);
	defer close_held(&app, &mesh);

	uint knee = held_dot(&app, "knee_L");
	usz k = held_joint(&app, knee);
	usz bones;
	float[] before = held_matrix(&app, &bones);
	defer alloc::free(mem, before);

	app.select(knee);
	test::@check(app.grow_joint(2), "the knee would not grow");
	float[] grown = held_matrix(&app, &bones);
	defer alloc::free(mem, grown);
	test::eq(moved_outside(before, grown, bones, k), (usz)0);

	test::@check(app.soften_joint(1.5f), "the knee would not soften");
	app.commit_soft_edge();
	float[] softened = held_matrix(&app, &bones);
	defer alloc::free(mem, softened);
	test::eq(moved_outside(before, softened, bones, k), (usz)0);
	test::@check(moved_outside(grown, softened, bones, bones) > 0, "the soft edge changed nothing of the knee");
}

<*
 A grow drag rewrites the joint once the hand is still, and the whole drag is
 one undo step that lets the joint go again.
*>
fn void a_grow_drag_is_one_undo_step() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_held(&app, &mesh);
	defer close_held(&app, &mesh);

	uint knee = held_dot(&app, "knee_L");
	app.select(knee);
	test::@check(app.begin_area(), "the Area tool would not open");
	test::@check(app.begin_grow_drag(), "the grow drag would not start");
	app.grow_drag_to(1);
	app.grow_drag_to(2);
	test::@check(app.edge_pending, "the drag rewrote the column on every step");
	app.tick_edges(1.0f);
	test::@check(!app.edge_pending && app.weights_held(knee), "the still hand did not rewrite the knee");
	app.grow_drag_to(3);
	app.end_grow_drag();
	test::@check(!app.edge_pending, "the release left the drag waiting");

	test::@check(app.undo(), "the drag left nothing to undo");
	test::@check(app.doc.find(knee).grow == 0.0f && !app.weights_held(knee) && app.doc.pins.len() == 0,
		"one undo did not take the whole drag back");
}

<*
 A joint placed on a rig follows the automatic weights; the held joints around
 it keep theirs.
*>
fn void a_new_joint_is_automatic_and_moves_no_held_one() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_held(&app, &mesh);
	defer close_held(&app, &mesh);

	uint knee = held_dot(&app, "knee_L");
	app.select(knee);
	test::@check(app.grow_joint(1), "the knee would not grow");
	usz k = held_joint(&app, knee);
	usz bones;
	float[] before = held_matrix(&app, &bones);
	defer alloc::free(mem, before);
	usz count = app.geometry.positions.len;
	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	for (usz v = 0; v < count; v++) column[v] = before[v * bones + k];

	crig::Dot* at = app.doc.find(knee);
	uint added = app.add_recorded(at.position + (Vec3){ 0.0f, -0.05f, 0.0f }, "shin_extra");
	app.connect_recorded(knee, added);
	app.undo_stack.commit();
	app.mark_rig_stale();
	test::@check(!app.weights_held(added), "a new joint came in held");

	float[] after = held_matrix(&app, &bones);
	defer alloc::free(mem, after);
	usz k_after = held_joint(&app, knee);
	usz drifted = 0;
	for (usz v = 0; v < count; v++) if (after[v * bones + k_after] != column[v]) drifted++;
	test::@check(drifted == 0, "placing a joint moved %d of the held knee's weights", drifted);
}

<*
 A held joint deleted takes its weights with it, so the vertices only it held
 are left to nobody — the Unused overlay marks them — and undo brings them back.
*>
fn void deleting_a_held_joint_leaves_its_vertices_unused_until_undo() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_held(&app, &mesh);
	defer close_held(&app, &mesh);

	uint ankle = held_dot(&app, "ankle_L");
	uint[4] some;
	usz alone = ankle_alone(&app, ankle, some[..]);
	test::@check(alone == 4 && app.weights_held(ankle), "the ankle could not be given vertices of its own");
	test::@check(app.remove_recorded(ankle), "the ankle would not delete");
	app.undo_stack.commit();
	app.mark_rig_stale();
	app.forget_stale_ids();

	crig::WeightSurvey gone = app.survey_weights(mem)!!;
	defer gone.free(mem);
	test::@check(gone.unused >= alone, "%d vertices are unused, not the %d only the ankle held", gone.unused, alone);

	test::@check(app.undo(), "the delete left nothing to undo");
	crig::WeightSurvey back = app.survey_weights(mem)!!;
	defer back.free(mem);
	test::eq(back.unused, (usz)0);
	test::@check(app.weights_held(ankle), "the ankle came back without its weights");
}

<*
 A joint brushed off vertices nobody else holds leaves them unused, and the
 Unused overlay draws them magenta.
*>
fn void a_joint_brushed_off_alone_shows_magenta() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_held(&app, &mesh);
	defer close_held(&app, &mesh);

	uint ankle = held_dot(&app, "ankle_L");
	uint[4] some;
	test::@check(ankle_alone(&app, ankle, some[..]) == 4, "the ankle could not be given vertices of its own");

	crig::PaintResult did = app.paint_share(ankle, some[..], 0.0f);
	test::eq(did.emptied, (usz)4);
	app.toggle_unused();
	app.rebind_tints();
	test::eq(app.unused_count, (usz)4);
	foreach (v : some)
	{
		uint tint = app.tints[v];
		test::@check((tint & 0xFF) == 0xFF && ((tint >> 8) & 0xFF) == 0 && ((tint >> 16) & 0xFF) == 0xFF,
			"unused vertex %d is not magenta", v);
	}
}

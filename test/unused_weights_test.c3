// The Unused overlay: the vertices no joint holds, marked magenta over whichever
// weight view is up or over the plain mesh, from the menu, the header strip and
// MCP alike. On the shipped humanoid.
module crig_tests::unused_weights;

import crig;
import rig;
import std::core::test;
import std::io::file;

const String UNUSED_COPY = "build/unused-humanoid.glb";

fn void open_unused_fixture(crig::AppState* app, rig::TriMesh* mesh)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(UNUSED_COPY, original)!!;
	*mesh = rig::load_gltf(mem, UNUSED_COPY)!!;
	*app = crig::new_app(*mesh, UNUSED_COPY);
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
}

fn void close_unused_fixture(crig::AppState* app, rig::TriMesh* mesh)
{
	app.free();
	mesh.free(mem);
	(void)file::delete(UNUSED_COPY);
	String sidecar = crig::session_path(mem, UNUSED_COPY);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

// Full red and blue, no green: `UNUSED_MAGENTA` packed, whatever the transfer.
fn bool is_magenta(uint tint)
{
	return (tint & 0xFF) == 0xFF && ((tint >> 8) & 0xFF) == 0 && ((tint >> 16) & 0xFF) == 0xFF;
}

<*
 A row is unused when its joints hold nothing between them, whatever its width.
*>
fn void a_row_holding_nothing_is_unused() @test
{
	float[3] empty = { 0.0f, 0.0f, 0.0f };
	float[3] faint = { 0.0f, 0.001f, 0.0f };
	test::@check(crig::unused_row(empty[..]), "an empty row was not unused");
	test::@check(!crig::unused_row(faint[..]), "a row holding a thousandth was unused");
}

<*
 With no weight view up, the overlay paints the plain mesh colour and marks only
 the vertices no joint holds; under the falloff view it marks them over the
 ramp. The rows here are made up: the humanoid's own weights hold every vertex.

 *Re-introduce:* gate the recolour on `tint_mode` alone, and switching the
 overlay on with no view up paints nothing.
*>
fn void the_overlay_marks_vertices_no_joint_holds() @test
{
	crig::AppState app;
	rig::TriMesh mesh;
	open_unused_fixture(&app, &mesh);
	defer close_unused_fixture(&app, &mesh);

	test::@check(app.tint_mode == OFF && !app.tinting(), "the fixture opened with something painted");
	app.toggle_unused();
	test::@check(app.tinting() && app.ticking(), "the overlay did not ask for a recolour");
	app.tick_weights(0.0f);
	usz count = app.geometry.positions.len;
	test::@check(app.tints.len == count, "the overlay with no view painted nothing");
	test::@check(app.unused_count == 0, "the humanoid's own weights left %d vertices unused", app.unused_count);

	uint plain = app.tints[0];
	test::@check(!is_magenta(plain), "a held vertex was marked unused");

	// Two bones, every vertex on the first but the first three.
	float[] rows = alloc::new_array(mem, float, (sz)count * 2);
	defer alloc::free(mem, rows);
	for (usz v = 3; v < count; v++) rows[v * 2] = 1.0f;
	app.overlay_unused_tints(2, rows);
	test::@check(app.unused_count == 3, "%d vertices counted unused, not 3", app.unused_count);
	test::@check(is_magenta(app.tints[0]) && is_magenta(app.tints[2]), "an unused vertex was not marked");
	test::@check(app.tints[3] == plain, "a held vertex was marked");

	// Switched off, the count is still kept but nothing is marked.
	app.toggle_unused();
	app.rebind_tints();
	app.overlay_unused_tints(2, rows);
	test::@check(app.unused_count == 3, "the count was dropped with the overlay");
	test::@check(app.tints.len == 0 || !is_magenta(app.tints[0]), "the overlay marked with it off");
}

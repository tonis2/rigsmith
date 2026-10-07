module crig_tests::back_facing_model;

import crig;
import gltf;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;

<*
 A rigged model facing −Z opens with its mesh and its rig standing together.

 crig reads every figure as facing +Z, so a skeleton whose left side sits on −X
 is turned half round as it is read (`source_origin`). The mesh it was skinned to
 has to turn with it: left behind, the rig stands inside the body backwards and
 the file's weights drag the left arm's vertices after joints sitting in the
 right arm — the model tears apart the moment anything moves, and an export
 carries the backwards skeleton out with it.

 The fixture is the shipped humanoid turned round, written by the rigged
 exporter: the same body, the same rig and the same weights, facing −Z.

 *Re-introduce:* drop the `turn_geometry_half_round` call in
 `import_rig_from_source` and the mesh stays facing −Z under a rig facing +Z; drop
 `source_turn` from `read_mesh_parts` and the export writes that rig over the
 untouched positions with no turn in the bind.
*>
fn void a_model_facing_back_turns_with_its_rig() @test
{
	io::printn("a model facing -Z opens, and exports, with its mesh and rig together");
	String humanoid = "build/back-facing-source.glb";
	String turned = "build/back-facing.glb";
	String exported = "build/back-facing-exported.glb";
	copy_file_bytes("assets/animations/humanoid.glb", humanoid);
	defer
	{
		remove_with_sidecar(humanoid);
		remove_with_sidecar(turned);
		remove_with_sidecar(exported);
	}

	// The humanoid as crig holds it: facing +Z, rig, weights and all.
	rig::TriMesh mesh = rig::load_gltf(mem, humanoid)!!;
	defer mesh.free(mem);
	crig::AppState facing = crig::new_app(mesh, humanoid);
	defer facing.free();
	test::@check(facing.import_rig_from_source(), "the humanoid rig must import");
	crig::RigView view = facing.open_rig(mem)!!;
	defer view.free(mem);
	float[] weights = facing.bind_dense(mem, &view);
	defer alloc::free(mem, weights);

	// Turned round and written out: what a model authored facing −Z looks like.
	rig::TriMesh back = turned_copy(facing.geometry);
	defer back.free(mem);
	rig::Skeleton back_rig = { .joints = alloc::new_array(mem, Vec3, (sz)view.len()), .parents = view.skeleton.parents };
	defer alloc::free(mem, back_rig.joints);
	foreach (usz j, joint : view.skeleton.joints) back_rig.joints[j] = turn(joint);
	crig::export_rigged_animated_glb(mem, turned, back, &back_rig, view.names, weights, {}, "body")!!;
	{
		gltf::GltfStream stream = gltf::open(turned, mem)!!;
		defer stream.close();
		test::@check(crig::faces_back(&stream), "the turned humanoid has to read as facing -Z");
	}

	rig::TriMesh opened = rig::load_gltf(mem, turned)!!;
	defer opened.free(mem);
	crig::AppState app = crig::new_app(opened, turned);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the turned humanoid's rig must import");
	test::@check(app.doc.skin_from_file, "and with the file's own weights");

	test::@check(app.geometry.positions.len == facing.geometry.positions.len, "the same body, vertex for vertex");
	if (app.geometry.positions.len != facing.geometry.positions.len) return;
	test::@check(worst_vertex_gap(app.geometry.positions, facing.geometry.positions) < 1e-4f,
		"the mesh turned round to face +Z with its rig");
	test::@check(worst_dot_gap(&app, &facing) < 1e-4f, "every joint stands where the same joint does facing +Z");

	// The export keeps them together: the file's positions are written as they
	// were, and the bind turns them to meet the rig.
	app.export_rig(exported);
	test::@check(file::is_file(exported), "the export wrote nothing: %s", app.notice());
	rig::TriMesh reread = rig::load_gltf(mem, exported)!!;
	defer reread.free(mem);
	test::@check(reread.positions.len == facing.geometry.positions.len, "the export keeps every vertex");
	if (reread.positions.len != facing.geometry.positions.len) return;
	test::@check(worst_vertex_gap(reread.positions, facing.geometry.positions) < 1e-3f,
		"the exported mesh stands facing +Z, where its rig is");

	crig::AppState again = crig::new_app(reread, exported);
	defer again.free();
	test::@check(again.import_rig_from_source(), "the exported rig must import");
	test::@check(worst_dot_gap(&again, &facing) < 1e-3f, "and its joints stand where they were exported");
	test::@check(worst_vertex_gap(again.geometry.positions, facing.geometry.positions) < 1e-3f,
		"with the mesh still around them, turned once and not twice");
}

fn Vec3 turn(Vec3 p) => { -p.x, p.y, -p.z };

fn rig::TriMesh turned_copy(rig::TriMesh mesh)
{
	rig::TriMesh out = {
		.positions = alloc::new_array(mem, Vec3, (sz)mesh.positions.len),
		.normals = alloc::new_array(mem, Vec3, (sz)mesh.normals.len),
		.indices = alloc::new_array(mem, uint, (sz)mesh.indices.len),
	};
	foreach (usz i, p : mesh.positions) out.positions[i] = turn(p);
	foreach (usz i, n : mesh.normals) out.normals[i] = turn(n);
	out.indices[..] = mesh.indices[..];
	return out;
}

fn float worst_vertex_gap(Vec3[] a, Vec3[] b)
{
	float worst = 0.0f;
	foreach (usz i, p : a) worst = math::max(worst, (p - b[i]).length());
	return worst;
}

// Every dot of `app` against the dot of the same name in `reference`; a dot with
// no namesake counts as infinitely far.
fn float worst_dot_gap(crig::AppState* app, crig::AppState* reference)
{
	if (app.doc.dots.len() != reference.doc.dots.len()) return float::max;
	float worst = 0.0f;
	foreach (dot : app.doc.dots.array_view())
	{
		crig::Dot* same = reference.dot_named(dot.name);
		if (!same) return float::max;
		worst = math::max(worst, (dot.position - same.position).length());
	}
	return worst;
}

fn void copy_file_bytes(String from, String to)
{
	char[] bytes = file::load(mem, from)!!;
	defer alloc::free(mem, bytes);
	file::save(to, bytes)!!;
}

fn void remove_with_sidecar(String path)
{
	(void)file::delete(path);
	String sidecar = crig::session_path(mem, path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

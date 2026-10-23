module crig_tests::trust_fixes;

import crig;
import gltf;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;

// Every primitive keeps its UVs, the file keeps its materials and texture, and it has a skin.
fn bool keeps_the_model(String path)
{
	gltf::GltfStream? opened = gltf::open(path, mem);
	if (catch opened) return false;
	gltf::GltfStream stream = opened;
	defer stream.close();
	if (stream.gltf.materials.len() == 0 || stream.gltf.skins.len() == 0) return false;
	if (stream.gltf.images.len() == 0 || stream.gltf.textures.len() == 0) return false;
	if (stream.gltf.meshes.len() == 0) return false;
	foreach (mesh : stream.gltf.meshes)
	{
		foreach (primitive : mesh.primitives)
		{
			if (!primitive.attributes.has_key("TEXCOORD_0")) return false;
		}
	}
	return true;
}

fn void copy_humanoid(String path)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(path, original)!!;
}

fn void remove_with_sidecar(String path)
{
	(void)file::delete(path);
	String sidecar = crig::session_path(mem, path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

<*
 Export carries the model whole — UVs, materials and texture — and Ctrl+S
 afterwards writes into that export without losing them.
*>
fn void an_export_keeps_uvs_and_materials_and_save_follows_it() @test
{
	io::printn("an export keeps UVs and materials, and a save after it does too");
	String source = "build/trust-export-source.glb";
	String exported = "build/trust-export-rigged.glb";
	copy_humanoid(source);
	remove_with_sidecar(exported);
	defer
	{
		remove_with_sidecar(source);
		remove_with_sidecar(exported);
	}
	test::@check(keeps_the_model(source), "the humanoid should carry UVs, materials and its texture");

	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	app.export_rig(exported);
	test::@check(file::is_file(exported), "the export wrote nothing");
	test::@check(keeps_the_model(exported), "the export lost UVs or materials: %s", app.notice());
	test::@check(app.source_path == exported, "a whole export should become where saves go");

	app.save_session();
	test::@check(app.source_path == exported, "the save went somewhere other than the export");
	test::@check(keeps_the_model(exported), "saving after the export lost UVs or materials: %s", app.notice());
}

<*
 A model set down away from the origin — beside another in a scene — exports
 the same as one that was not: whole, with its UVs and texture, standing at its
 own origin. The placement stays in the project beside the file.
*>
fn void a_placed_model_exports_whole_at_its_origin() @test
{
	String source = "build/trust-placed-source.glb";
	String exported = "build/trust-placed-rigged.glb";
	copy_humanoid(source);
	remove_with_sidecar(exported);
	defer
	{
		remove_with_sidecar(source);
		remove_with_sidecar(exported);
	}

	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	crig::ProjectTransform placement = {
		.location = { 4.4f, 0, 0 },
		.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI * 0.5f),
	};
	app.doc.model_transform = placement;

	app.export_rig(exported);
	test::@check(keeps_the_model(exported), "a placed export lost UVs or materials: %s", app.notice());
	test::@check(app.source_path == exported, "a whole export should become where saves go");
	test::@check(!app.source_has_model_transform, "the export claims to carry the placement");

	gltf::GltfStream stream = gltf::open(exported, mem)!!;
	defer stream.close();
	foreach (node : stream.gltf.nodes)
	{
		test::@check(node.name != "crig:model_transform", "the export wrote the scene placement into the file");
	}
	rig::TriMesh written = rig::load_gltf(mem, exported)!!;
	defer written.free(mem);
	float worst = 0.0f;
	foreach (usz i, position : written.positions)
	{
		worst = math::max(worst, (position - mesh.positions[i]).length());
	}
	test::@check(worst < 1.0e-4f, "the exported model moved %s off its own origin", worst);

	// Reopened, it is the same model in the same place in the scene.
	crig::AppState reopened = crig::new_app(written, exported);
	defer reopened.free();
	reopened.adopt_source_rig();
	test::@check(reopened.doc.model_transform.same(placement), "the project lost the placement");
	test::@check(!reopened.source_has_model_transform, "the reopened file claims to carry the placement");
	test::@check(near_positions(reopened.geometry.positions, mesh.positions),
		"the reopened model is not the one exported");
}

fn bool near_positions(Vec3[] a, Vec3[] b) @local
{
	if (a.len != b.len) return false;
	foreach (usz i, p : a) if ((p - b[i]).length() > 1.0e-4f) return false;
	return true;
}

<*
 The model's own weights arrive as every joint's held column, and stay put: a
 rename changes none of them, and neither does a joint added beside them — it
 follows the automatic weights while the file's columns stay as painted.

 *Re-introduce:* let an added joint drop the file's weights for the binder's, as
 the import's whole-rig flag did, and every column moves.
*>
fn void an_added_joint_keeps_the_imported_weights() @test
{
	io::printn("a rename and an added joint keep the imported weights");
	String path = "build/trust-rename.glb";
	copy_humanoid(path);
	defer remove_with_sidecar(path);

	rig::TriMesh mesh = rig::load_gltf(mem, path)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, path);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	usz dots = (usz)app.doc.dots.len();
	foreach (dot : app.doc.dots.array_view()) test::@check(dot.held, "%s arrived without the file's weights", dot.name);

	crig::RigView view = app.open_rig(mem)!!;
	uint renamed = view.dot_ids[1];
	float[][] before = alloc::new_array(mem, float[], (sz)dots);
	foreach (j, id : view.dot_ids) before[j] = app.column_of(mem, &view, id);
	uint[] ids = alloc::clone_slice(mem, view.dot_ids);
	view.free(mem);
	defer
	{
		foreach (column : before) alloc::free(mem, column);
		alloc::free(mem, before);
		alloc::free(mem, ids);
	}

	test::@check(app.rename(renamed, "renamed_joint"), "the rename was refused");
	uint added = app.add_recorded(app.doc.dots[0].position + (Vec3){ 0.01f, 0.0f, 0.0f });
	app.undo_stack.commit();
	app.mark_rig_stale();
	test::@check(!app.weights_held(added), "the added joint came in holding weights");

	view = app.open_rig(mem)!!;
	defer view.free(mem);
	usz moved = 0;
	foreach (j, id : ids)
	{
		float[] now = app.column_of(mem, &view, id);
		defer alloc::free(mem, now);
		foreach (v, w : now) if (w != before[j][v]) moved++;
	}
	test::@check(moved == 0, "a rename and an added joint moved %d of the file's weights", moved);
}

<*
 A model crig exported carries crig's own weights, and says so: opened again
 without its sidecar, they are rebuilt from the joints rather than adopted as the
 file's — so moving a joint afterwards takes its vertices with it. Adopted as
 authored, they stayed put, and a finger joint moved to the next finger left its
 vertices behind (a thumb whose weights were the middle finger's).

 *Re-introduce:* drop the `PACK_KEY_WEIGHTS` check in `import_rig_from_source`
 and the reopened export comes back with every joint held.
*>
fn void crig_weights_reopen_as_crig_weights() @test
{
	io::printn("a model crig wrote reopens with weights bound from its joints");
	String source = "build/trust-weights-source.glb";
	String exported = "build/trust-weights-exported.glb";
	copy_humanoid(source);
	remove_with_sidecar(exported);
	defer
	{
		remove_with_sidecar(source);
		remove_with_sidecar(exported);
	}

	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	test::@check(app.weights_edited(), "the humanoid arrives with weights of its own");

	// Let go: crig's weights for the joints, which the export then writes and marks.
	(void)app.release_all_recorded();
	app.mark_rig_stale();
	app.export_rig(exported);
	test::@check(file::is_file(exported), "the export wrote nothing: %s", app.notice());
	{
		gltf::GltfStream stream = gltf::open(exported, mem)!!;
		defer stream.close();
		String said = stream.gltf.extras.get(crig::PACK_KEY_WEIGHTS) ?? "";
		test::@check(said == crig::PACK_WEIGHTS_AUTOMATIC, "the export did not mark its weights as crig's: '%s'", said);
	}

	remove_with_sidecar(exported);
	app.export_rig(exported);
	String sidecar = crig::session_path(mem, exported);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);

	rig::TriMesh again = rig::load_gltf(mem, exported)!!;
	defer again.free(mem);
	crig::AppState reopened = crig::new_app(again, exported);
	defer reopened.free();
	test::@check(reopened.import_rig_from_source(), "the exported rig must import");
	test::@check(!reopened.weights_edited(), "crig's own weights came back held as the file's");
	test::@check(reopened.imported_skin.present(), "the file's weights should still be read, for the menu to offer");
}

// Save into the model needs one connected skeleton. A chain placed and never
// connected — an antenna on its own — is a second root, and the save says which
// joint is loose instead of only that the model would not take the skin.
module crig_tests::save_loose_joint;

import crig;
import rig;
import std::core::test;
import std::io::file;
import std::math::vector;

const String LOOSE_COPY = "build/loose-joint-humanoid.glb";

fn void a_loose_joint_is_named_and_connecting_it_saves() @test
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(LOOSE_COPY, original)!!;
	defer (void)file::delete(LOOSE_COPY);

	rig::TriMesh mesh = rig::load_gltf(mem, LOOSE_COPY)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, LOOSE_COPY);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");

	uint head;
	foreach (dot : app.doc.dots.array_view()) if (dot.name == "head") head = dot.id;
	test::@check(head != 0, "the humanoid has no head");
	Vec3 above = app.doc.find(head).position + (Vec3){ 0, 0.05f, 0 };

	// Placed with nothing selected: a joint of its own, connected to nothing.
	app.select(0);
	uint loose = app.place(above);
	test::@check(app.rename(loose, "antenna_root"), "could not name the loose joint");

	test::@check(!app.write_rig_into_model(LOOSE_COPY), "a rig in two pieces was written into the model");
	test::@check(app.notice().contains("antenna_root") && app.notice().contains("not connected"),
		"the refusal did not name the loose joint: %s", app.notice());

	app.connect_recorded(head, loose);
	test::@check(app.write_rig_into_model(LOOSE_COPY), "connecting the joint did not let the model take the rig: %s", app.notice());
}

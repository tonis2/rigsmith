// Saving under a name: the model copied to the path asked for, its sidecar beside
// it naming it, the original untouched — and never over the model that was opened.
module crig_tests::save_as;

import crig;
import crig_tests::mcp;
import rig;
import std::core::test;
import std::io;
import std::io::file;

const String HUMANOID = "assets/animations/humanoid.glb";

fn void remove_pair(String path)
{
	(void)file::delete(path);
	String sidecar = crig::session_path(mem, path);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

fn void a_save_under_a_name_writes_the_copy_and_its_sidecar() @test
{
	io::printn("save as: the model copied to the path, its sidecar beside it");
	String source = "build/save-as-source.glb";
	String target = "build/save-as-target.glb";
	char[] original = file::load(mem, HUMANOID)!!;
	defer alloc::free(mem, original);
	file::save(source, original)!!;
	defer remove_pair(source);
	remove_pair(target);
	defer remove_pair(target);
	String copy_aside = crig::copy_path(mem, source);
	defer copy_aside.free(mem);
	defer remove_pair(copy_aside);

	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	app.adopt_source_rig();
	app.saves_in_place = false;

	test::@check(app.save_as_refusal(source, false).len > 0, "a save over the opened model was allowed");
	test::@check(app.save_as_refusal("build/save-as-target.txt", false).len > 0, "a save to a non-model path was allowed");
	test::@check(app.save_as_refusal(target, false).len == 0, "a fresh path was refused: %s", app.save_as_refusal(target, false));

	app.save_session(target);
	test::@check(app.source_path == target, "the project follows %s, not the copy", app.source_path);
	test::@check(file::is_file(target), "nothing was written at the path");
	String sidecar = crig::session_path(mem, target);
	defer sidecar.free(mem);
	char[]? text = file::load(mem, sidecar);
	test::@check(@ok(text), "no sidecar beside the copy");
	if (try text)
	{
		defer alloc::free(mem, text);
		test::@check(((String)text).contains(`"save-as-target.glb"`), "the sidecar does not name the copy");
	}
	char[] after = file::load(mem, source)!!;
	defer alloc::free(mem, after);
	test::@check(after.len == original.len && (String)after == (String)original, "the original changed");
	test::@check(!file::is_file(copy_aside), "a _copy was made beside the original as well");

	// A file at the path is refused without overwrite.
	test::@check(app.save_as_refusal("build/save-as-source.glb", false).len > 0, "a save over another existing model was allowed");
}

<*
 open replaces what is open with the file asked for, refuses while there is
 unsaved work, and reads the open file again when told to let the work go.
*>
fn void open_replaces_the_scene_and_guards_unsaved_work() @test
{
	io::printn("save as: open replaces the scene, guarding unsaved work");
	crig_tests::mcp::Fixture* f = mem::new(crig_tests::mcp::Fixture);
	defer free(f);
	if (!f.open_model(HUMANOID)) return;
	defer f.close();
	// As the app's own open leaves it: the rig the file brought is no unsaved work.
	f.app.mark_saved();

	String? opened = f.call_tool_text("open", `{"path":"assets/animations/quadruped.glb"}`);
	test::@check(@ok(opened), "open refused a clean scene");
	if (try opened) opened.free(mem);
	test::@check(f.app.source_path == "assets/animations/quadruped.glb", "the scene is %s, not the quadruped", f.app.source_path);
	test::@check(f.app.character_count() == 1, "open left %d characters", f.app.character_count());

	String? moved = f.call_tool_text("edit_rig", `{"ops":[{"op":"symmetry","plane":0.01}]}`);
	if (try moved) moved.free(mem);
	String? guarded = f.call_tool_text("open", `{"path":"assets/animations/humanoid.glb"}`);
	test::@check(!@ok(guarded), "open let unsaved work go without being told to");
	if (try guarded) guarded.free(mem);

	String? again = f.call_tool_text("open", `{"path":"assets/animations/humanoid.glb","discard_unsaved":true}`);
	test::@check(@ok(again), "open refused with discard_unsaved");
	if (try again) again.free(mem);
	test::@check(f.app.source_path == HUMANOID, "the scene is %s, not the humanoid", f.app.source_path);
}

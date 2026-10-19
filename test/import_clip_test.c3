<*
 import_clip: an animation in a .glb file lands on the character as generate_motion's
 clips do — bound, in the authored pack, keyed under the rig's own joint names —
 and every way the file can be wrong is refused with the reason.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::import_clip`
*>
module crig_tests::import_clip;

import crig;
import crig_tests::mcp;
import std::collections::object;
import std::core::test;

const String PERSON = "assets/animations/humanoid.glb";

fn void a_files_clip_lands_bound_under_the_rigs_names() @test
{
	mcp::Fixture f;
	if (!f.open_model(PERSON)) return;
	defer f.close();
	sz bound = f.app.doc.animations.len();

	Object*? landed = f.call_tool("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Imported walk"}`);
	if (catch landed) { test::@check(false, "import_clip refused the humanoid's own walk"); return; }
	defer landed.free();
	test::@check((landed.get_string("clip") ?? "") == "Imported walk", "named %s", landed.get_string("clip") ?? "?");
	test::@check((landed.get_int("keyframes") ?? 0) > 0, "the clip landed with no keys");
	test::@check(f.app.doc.animations.len() == bound + 1, "the clip was not bound");

	crig::AnimRef? ref = crig::resolve_clip(&f.app, "Imported walk");
	if (catch ref) { test::@check(false, "the landed clip cannot be found by name"); return; }
	test::@check(ref.pack == f.app.authored_pack, "the clip is not the character's own");
	crig::AnimTemplate* clip = f.app.clip(ref);
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	usz named;
	foreach (dot : clip.keyframes[0].dots)
	{
		foreach (joint : view.names) if (joint == dot.joint_name) { named++; break; }
	}
	test::@check(named == clip.keyframes[0].dots.len, "%d of %d keys name a joint of the rig", named, clip.keyframes[0].dots.len);
}

fn void a_file_it_cannot_use_is_refused_with_the_reason() @test
{
	mcp::Fixture f;
	if (!f.open_model(PERSON)) return;
	defer f.close();
	sz bound = f.app.doc.animations.len();

	test::@check(f.refuses_tool("import_clip", `{}`, "path"), "no path was taken");
	test::@check(f.refuses_tool("import_clip", `{"path":"walk.bvh"}`, ".glb"), "a .bvh was taken");
	test::@check(f.refuses_tool("import_clip", `{"path":"build/no-such-file.glb"}`, "could not be read"), "a missing file was taken");
	test::@check(f.refuses_tool("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Moonwalk"}`, "Moonwalk"),
		"a clip the file does not hold was taken");
	test::@check(f.app.doc.animations.len() == bound, "a refused import bound a clip");
}

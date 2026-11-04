module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// get_crig_docs, save_project, and get_scene's project state
//
// The plumbing repairs of the 2026-09-18 recommendations a headless check can
// hold down: crig's documentation reachable under a name three does not own, an
// explicit project save distinct from publishing a pack, and the authored-dirty
// cue get_scene now carries. The `crig` scripting global the same repair binds is
// exercised live — it needs a JavaScript runtime these checks do not stand up —
// but its doors are `ToolTable.invoke`, driven all through this file, and this
// documentation.

<*
 crig's docs answer under get_crig_docs, the same three shapes get_api_docs does.

 The tool three's get_api_docs shadows on the shipped build, given a name of its
 own so it is reachable there too. Asserted to be that same renderer — an index
 that names every section and every tool, and one tool's schema off the registry
 — rather than a second copy that would drift.
*>
fn void get_crig_docs_answers_under_its_own_name() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String? index = f.call_tool_text("get_crig_docs", "{}");
	if (catch index)
	{
		test::@check(false, "get_crig_docs answers with no arguments");
		return;
	}
	defer alloc::free(mem, index);

	Object*? menu = json::parse(mem, index);
	if (catch menu)
	{
		test::@check(false, "and the index parses");
		return;
	}
	defer menu.free();

	test::@check((menu.get_int("version") ?? 0) == DOCS_VERSION, "the index is versioned like get_api_docs");

	Object*? topics = menu.get("topics");
	if (catch topics)
	{
		test::@check(false, "and names the sections");
		return;
	}
	test::@check(topics.get_len() == doc_topics.len, "every section is in the index");

	Object*? listed = menu.get("tools");
	if (catch listed)
	{
		test::@check(false, "and names the tools");
		return;
	}
	test::@check(listed.get_len() == tool_names.len, "every tool is in the index, hidden or not");

	// One tool's registration, off the same registry the wire validates against —
	// and get_crig_docs is itself one of the tools it can describe.
	Object*? one = f.call_tool("get_crig_docs", `{"tool":"apply_clip"}`);
	if (catch one)
	{
		test::@check(false, "get_crig_docs answers for one tool");
		return;
	}
	defer one.free();
	test::@check((one.get_string("name") ?? "") == "apply_clip", "a tool answer names the tool");
	Object*? schema = one.get("schema");
	test::@check(@ok(schema), "and carries its JSON Schema verbatim");
}

<*
 save_project with no open document refuses in the reply, not with a fault.

 A missing project path is a state a caller asks about, so the answer is JSON that
 says so — `saved` is null and the note points at the difference between saving a
 project and publishing a pack — rather than an error that a script would have to
 catch to read.
*>
fn void save_project_reports_no_open_project() @test
{
	Fixture fixture;
	fixture.open_bare();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? saved = f.call_tool("save_project", "{}");
	if (catch saved)
	{
		test::@check(false, "save_project answers with JSON even with nothing to save");
		return;
	}
	defer saved.free();

	test::@check(saved.get("saved")!!.is_null(), "it saved nothing, and says so with a null");
	test::@check((saved.get_string("note") ?? "").contains("no open project"),
		"and the note names why");
	test::@check((saved.get_string("note") ?? "").contains("save_pack"),
		"and points at the pack door it is not");
}

<*
 get_scene carries the authored-dirty cue, and it tracks an authored edit.

 The listed orientation call is where an agent learns a save is owed. False on a
 freshly opened document, true once a clip has been authored into it — the same
 flag save_project reports and Ctrl+S clears.
*>
fn void get_scene_reports_authored_dirty() @test
{
	Fixture clean;
	clean.open();
	defer clean.close();
	Object*? before = ((Fixture*)&clean).call_tool("get_scene", "{}");
	if (catch before)
	{
		test::@check(false, "get_scene answers on a clean document");
		return;
	}
	defer before.free();
	Object*? clean_project = before.get("project");
	if (catch clean_project)
	{
		test::@check(false, "get_scene carries a project block");
		return;
	}
	test::@check(clean_project.get_bool("authored_dirty")!! == false,
		"a freshly opened document has nothing unsaved");

	Fixture edited;
	edited.open_authored();
	defer edited.close();
	Object*? after = ((Fixture*)&edited).call_tool("get_scene", "{}");
	if (catch after)
	{
		test::@check(false, "get_scene answers after authoring");
		return;
	}
	defer after.free();
	test::@check(after.get("project")!!.get_bool("authored_dirty")!! == true,
		"authoring a clip leaves the project dirty until it is saved");
}

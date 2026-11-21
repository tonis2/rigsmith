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
// get_api_docs
//
// The document is twenty thousand characters and a caller almost never wants all
// of it, so it is sectioned — and the tool reference inside it is not prose kept
// here at all, but the registry rendered. Both of those are things a test has to
// hold down, because both are invisible from a reply that merely parses.

// Every section, in the order the index reports them. By hand, like `tool_names`:
// a section added without a line here fails rather than passing unnoticed.
String[23] doc_topics = {
	"quality", "clips", "authoring", "turning", "targets", "editing", "playback", "cycles",
	"ground", "looking", "rigging", "scripting", "weights", "physics", "review", "gaits", "layers", "paths", "pins", "props", "repair",
	"levels", "cutscenes",
};

<*
 With no arguments the docs are a menu, not the document.

 The point of the sectioning: what comes back names every section and every tool
 without carrying either one's prose, so a caller chooses what to read and pays
 for that. Both halves are asserted — the names are all there, *and* the
 descriptions are not, since an index that quietly carried them would be the
 twenty thousand characters again under a new key.
*>
fn void the_api_docs_index_is_a_menu() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String? text = f.call_tool_text("get_api_docs", "{}");
	if (catch text)
	{
		test::@check(false, "get_api_docs answers with no arguments");
		return;
	}
	defer alloc::free(mem, text);

	Object*? docs = json::parse(mem, text);
	if (catch docs)
	{
		test::@check(false, "and the index parses");
		return;
	}
	defer docs.free();

	test::@check((docs.get_int("version") ?? 0) == DOCS_VERSION, "the index is versioned");
	test::@check((docs.get_string("space") ?? "").contains("+Y up"),
		"and carries the two conventions everything else assumes");

	Object*? topics = docs.get("topics");
	if (catch topics)
	{
		test::@check(false, "and names the sections");
		return;
	}
	test::@check(topics.get_len() == doc_topics.len,
		"every section is in the index (%d of %d)", (int)topics.get_len(), doc_topics.len);
	foreach (wanted : doc_topics)
	{
		bool found = false;
		for (sz i = 0; i < topics.get_len(); i++)
		{
			if ((topics.get_at(i).get_string("name") ?? "") == wanted) found = true;
		}
		test::@check(found, "the index names the %s section", wanted);
	}

	Object*? tools = docs.get("tools");
	if (catch tools)
	{
		test::@check(false, "and names the tools");
		return;
	}
	test::@check(tools.get_len() == tool_names.len,
		"every tool is in the index, hidden or not (%d of %d)",
		(int)tools.get_len(), tool_names.len);
	bool described = false;
	for (sz i = 0; i < tools.get_len(); i++)
	{
		if (try tools.get_at(i).get_string("description")) described = true;
	}
	test::@check(!described,
		"and none of them brings its description along — that is what the tool argument is for");

	// The measurement the whole arrangement is for. `all` is the old document, and
	// the index has to be a small fraction of it or the sectioning bought nothing.
	String? whole = f.call_tool_text("get_api_docs", `{"topic":"all"}`);
	if (catch whole)
	{
		test::@check(false, "and all still answers");
		return;
	}
	defer alloc::free(mem, whole);
	test::@check(text.len * 4 < whole.len,
		"the index is a small fraction of the whole (%d against %d characters)",
		(int)text.len, (int)whole.len);
}

<*
 One section comes back on its own, and nothing else does.

 A tool that answered with everything whatever it was asked would parse, read
 correctly, and cost exactly what it cost before — so what is checked is the
 absence: the section asked for is here in full and its neighbours are not here
 at all.
*>
fn void a_topic_is_served_on_its_own() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String? text = f.call_tool_text("get_api_docs", `{"topic":"ground"}`);
	if (catch text)
	{
		test::@check(false, "get_api_docs answers for one topic");
		return;
	}
	defer alloc::free(mem, text);

	Object*? docs = json::parse(mem, text);
	if (catch docs)
	{
		test::@check(false, "and the section parses");
		return;
	}
	defer docs.free();

	test::@check((docs.get_string("topic") ?? "") == "ground", "the section says which it is");
	test::@check((docs.get_string("text") ?? "").contains("foot_slide"),
		"and carries that section's own prose");
	test::@check(!text.contains("14400"),
		"and not the physics section's");
	test::@check(!text.contains("crig.data.dots"),
		"and not the scripting section's");
}

<*
 A topic or tool the docs do not have, or both at once, is refused with what to
 ask for instead: a wrong guess costs one retry rather than a fishing trip.
*>
fn void the_docs_refuse_what_they_cannot_answer() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("get_api_docs", `{"topic":"weight"}`,
		"there is no topic called weight", "weights", "physics", `"all"`),
		"an unknown topic is refused naming every real one and the way to ask for the lot");
	test::@check(f.refuses_tool("get_api_docs", `{"topic":"ground","tool":"apply_clip"}`,
		"not both", "ground", "apply_clip"),
		"a topic and a tool at once is refused, naming both");
	test::@check(f.refuses_tool("get_api_docs", `{"tool":"apply_clips"}`,
		"there is no tool called apply_clips", "no arguments"),
		"an unknown tool is refused by pointing at the index");
}

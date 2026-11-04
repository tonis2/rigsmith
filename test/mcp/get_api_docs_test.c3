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
String[20] doc_topics = {
	"quality", "clips", "authoring", "turning", "targets", "editing", "playback", "cycles",
	"ground", "looking", "rigging", "scripting", "weights", "physics", "review", "gaits", "layers", "paths", "pins", "repair",
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
 A section that does not exist is refused by naming the ones that do.

 The failure mode a sectioned document invents: a caller that guessed "weight"
 for "weights" and has no way to find out. The refusal is the index in one
 sentence, so a wrong guess costs one retry rather than a fishing trip.
*>
fn void an_unknown_topic_names_the_real_ones() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_api_docs","arguments":{"topic":"weight"}}}`);
	if (catch root)
	{
		test::@check(false, "a bad topic answers");
		return;
	}
	defer root.free();

	test::@check(error_message_contains(root, "there is no topic called weight"),
		"the refusal says what was asked for");
	test::@check(error_message_contains(root, "weights"),
		"and names the section that was meant");
	test::@check(error_message_contains(root, "physics"),
		"and every other one");
	test::@check(error_message_contains(root, `"all"`),
		"and the way to ask for the lot");
}

<*
 A topic and a tool at once is refused rather than half-answered.

 They are different questions — a convention every tool follows against one
 tool's own arguments — and there is no reply that is both. Picking one silently
 would hand back an answer to a question the caller did not ask and give it no
 way to notice.
*>
fn void the_docs_refuse_a_topic_and_a_tool_together() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_api_docs","arguments":{"topic":"ground","tool":"apply_clip"}}}`);
	if (catch root)
	{
		test::@check(false, "asking for both answers");
		return;
	}
	defer root.free();

	test::@check(error_message_contains(root, "not both"), "and is refused in so many words");
	test::@check(error_message_contains(root, "ground") && error_message_contains(root, "apply_clip"),
		"naming both of the things it was asked for");
}

<*
 A tool name that is not a tool is refused by pointing at the index.
*>
fn void the_docs_refuse_a_name_that_is_not_a_tool() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_api_docs","arguments":{"tool":"apply_clips"}}}`);
	if (catch root)
	{
		test::@check(false, "a bad tool name answers");
		return;
	}
	defer root.free();

	test::@check(error_message_contains(root, "there is no tool called apply_clips"),
		"the refusal says what was asked for");
	test::@check(error_message_contains(root, "no arguments"),
		"and where the list of them is");
}

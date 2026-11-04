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
// What the relay depends on
//
// `crig --mcp-stdio` forwards each message to the port and answers the handshake
// itself while the editor is down, out of a catalog server registered over a
// zeroed AppState. Two things have to hold for that, and neither is visible from
// the relay's own code.

fn void the_catalog_answers_with_no_document_behind_it() @test
{
	// No mesh, no dots, no library — and not even `new_app`. This is the value
	// `serve_relay` builds its catalog over, and a handler that reached into it
	// for anything would fault here rather than in front of a user.
	crig::AppState empty = {};
	crig::ToolTable catalog_tools = crig::new_tool_table(&empty);
	mcp::Server catalog = crig::serve_table(&catalog_tools, &empty);

	String response = catalog.handle_message(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
	defer alloc::free(mem, response);

	Object*? root = json::parse(mem, response);
	if (catch root)
	{
		test::@check(false, "a catalog with no document still answers tools/list as JSON");
		return;
	}
	defer root.free();

	sz listed = root.get("result").get("tools").get_len() ?? 0;
	test::@check(listed == listed_tools.len,
		"the whole catalog is a property of the build, not of the rig — so it answers before crig is up");
}

<*
 The catalog survives being written as one line.

 `send_message` frames a stdio answer as one line, and a tool's `input_schema` is
 the JSON most likely to have been typed across several — it is the part a person
 reads. Spliced into a response those newlines are legal whitespace between
 tokens, and a client reading line-delimited JSON gets a truncated first line.
 The transport replaces them, which is only safe if no two tokens in this
 server's own catalog needed one to stay apart.
*>
fn void the_catalog_survives_being_written_as_one_line() @test
{
	crig::AppState empty = {};
	crig::ToolTable catalog_tools = crig::new_tool_table(&empty);
	mcp::Server catalog = crig::serve_table(&catalog_tools, &empty);

	String response = catalog.handle_message(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
	defer alloc::free(mem, response);

	// The payload really does carry them, or this check would pass by proving
	// nothing — `get_api_docs`' schema is written across several lines, and it is
	// one of the five that are listed.
	bool wrapped = response.contains("\n");

	DString flat = dstring::new(mem);
	defer flat.free();
	foreach (character : response)
	{
		flat.append_char(character == '\n' || character == '\r' ? ' ' : character);
	}

	Object*? root = json::parse(mem, flat.str_view());
	if (catch root)
	{
		test::@check(false, "the catalog still parses once its newlines are spaces");
		return;
	}
	defer root.free();

	sz listed = root.get("result").get("tools").get_len() ?? 0;
	test::@check(wrapped, "the catalog is written across lines, so flattening it is a real question");
	test::@check(listed == listed_tools.len, "and every listed tool survives being flattened onto one");
}

fn void unknown_method() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":9,"method":"bogus/method"}`);
	if (catch root)
	{
		test::@check(false, "unknown method answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32601), "unknown method is -32601");
}

fn void garbage_is_a_parse_error() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":`);
	if (catch root)
	{
		test::@check(false, "garbage answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32700), "garbage is -32700");
}

fn void unknown_tool() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope","arguments":{}}}`);
	if (catch root)
	{
		test::@check(false, "unknown tool answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32602), "unknown tool is -32602");
}

fn bool? string_id_body(Object* root)
{
	return root.get_string("id")! == "session-7";
}

fn void string_ids_echo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":"session-7","method":"ping"}`);
	if (catch root)
	{
		test::@check(false, "ping answers");
		return;
	}
	defer root.free();
	test::@check(string_id_body(root) ?? false, "string ids echo back quoted");
}

fn void the_notification_passes_silently() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	// The no-response return is the empty string literal — nothing to free.
	String response = f.server.handle_message(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
	test::@check(response.len == 0, "a notification gets no response");
}

fn bool? resources_list_body(Object* root)
{
	Object* resources = root.get("result")!.get("resources")!;
	return resources.get_len() == 1 && resources.get_at(0).get_string("uri")! == "crig://api-docs";
}

// The version every reply carries. Asserted rather than read out of the source so
// that a change to the conventions has to be a deliberate bump, which is the only
// thing that tells a caller working from memory that the two have diverged.
const int DOCS_VERSION = 53;

fn bool? resources_read_body(Object* root)
{
	String text = root.get("result")!.get("contents")!.get_at(0).get_string("text")!;
	Object* docs = json::parse(mem, text)!;
	defer docs.free();
	bool ok = docs.get_int("version")! == DOCS_VERSION;
	// Every tool, hidden or not: the docs are where a hidden one is found, so a
	// tool missing from here is a tool nothing will ever call.
	ok = ok && docs.get("tools")!.get_len() == tool_names.len;
	ok = ok && docs.get_string("space")!.contains("+Y up");
	// The resource is the whole document — every section, not the index's hooks.
	ok = ok && docs.get_string("physics")!.contains("set_secondary_motion");
	ok = ok && docs.get_string("ground")!.contains("foot_slide");
	return ok;
}

fn void the_api_docs_resource() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":11,"method":"resources/list"}`);
	if (catch root)
	{
		test::@check(false, "resources/list answers");
		return;
	}
	defer root.free();
	test::@check(resources_list_body(root) ?? false, "resources/list carries the api docs");

	Object*? read = f.request(`{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"crig://api-docs"}}`);
	if (catch read)
	{
		test::@check(false, "resources/read answers");
		return;
	}
	defer read.free();
	test::@check(resources_read_body(read) ?? false, "resources/read returns the versioned conventions");
}

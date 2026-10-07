<*
 A JSON-RPC server over crig's tool table — the harness `mcp_test.c3` drives.

 This used to live in `src/main.c3` and belong to the executable. The executable
 is gone: three owns the window, the frame loop and the MCP transport now, and
 `plugin/tools.c3` registers crig's handlers into three's server. What is left of
 `mcp.c3l` in this repository is this file, and it is test-only.

 **It is scaffolding with a known end.** `three.c3/plugin_plan.md` item 6 replaces
 crig's twenty-seven tools with JavaScript, and `mcp_test.c3` goes with them. Six
 thousand lines of checks over the tool surface are what makes that rewrite
 verifiable — they are the answer the JavaScript has to reproduce, the way
 `get_weights` was the answer `bind()` had to reproduce — so they have to keep
 running until there is something to compare against. Rebasing them onto
 `ToolTable.invoke` first would have been three hundred edits to a file that is
 being deleted; keeping thirty lines of bridge is the cheaper truth.

 Nothing in `src/` imports `mcp` any more. When item 6 lands, this file, both mcp
 test suites and the `mcp` dependency come out together.
*>
module crig;

import mcp;

<*
 crig's registry as a live `mcp::Server`.

 `ToolDef` is `mcp::ToolDef`, so each entry goes in as it is.

 @param table : `Borrowed. Its tool records must outlive the server, which they do: it is a field of the fixture.`
*>
fn mcp::Server serve_table(ToolTable* table, AppState* app)
{
	mcp::Server server = mcp::new_server({ .name = "crig", .version = "0.1.0" });
	for (usz i = 0; i < table.tools_len; i++)
	{
		// As `install_tools` hands them over, routed — but on the schema as it was,
		// so a fixture leaves nothing allocated behind it.
		ToolDef routed = table.tools[i];
		routed.handler = &routed_tool;
		routed.user_data = &table.tools[i];
		server.add_tool(routed);
	}
	server.add_resource({
		.uri = API_DOCS_URI,
		.name = "crig API conventions",
		.description = "Every section of the document get_api_docs serves a piece at a time.",
		.mime_type = "application/json",
		.handler = &served_api_docs,
		.user_data = app,
	});
	return server;
}

// The resource `new_tool_table` used to register. A resource is an `mcp.c3l`
// concept and this is the only file left with one — under the plugin the same
// document is `mcp_docs`, registered from `plugin/tools.c3`.
fn String? served_api_docs(void* user_data) @local
{
	return crig_api_docs((AppState*)user_data);
}

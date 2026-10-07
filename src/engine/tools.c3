<*
 crig's tool registry, and how it reaches the MCP server.

 crig's handlers and its object model are its own; the server, its transports and
 the JSON-RPC envelope are `mcp.c3l`'s, and three's `new_mcp_server` is what
 builds one. This file is the seam between those two halves.

 ## The adapter that stopped being needed

 While crig was a plugin this file carried a thunk. three's ABI wanted
 `fn bool(void* user, McpCall)`, crig's handlers are
 `fn String?(Object*, void*, DString*)`, and `crig_tool_thunk` converted between
 them for all twenty-seven — packing a `String?` and a detail buffer into a bool
 and a reply call, because a C ABI has neither.

 There is no ABI now. `ToolDef` is `mcp::ToolDef` itself, so `install_tools`
 hands each entry to the server as it is.

 ## `invoke` is what the tests drive

 `test/mcp_test.c3` is six thousand lines over this surface and it is the reason
 the migration can be trusted. It calls `invoke`, the same dispatch the server
 performs, so what the tests exercise is what three dispatches rather than a parallel
 path that agrees until one of them is fixed.
*>
module crig;

import mcp;
import std::collections::object;
import std::encoding::json;
import std::io;

faultdef TOOL_NOT_FOUND, TOOL_REFUSED;

// mcp's own tool record and handler signature: crig registers straight into an
// `mcp::Server`, so there is nothing to convert between. The table stays crig's
// because `mcp/docs.c3` walks it to build the API document and the tests drive
// `invoke` over it without a server.
alias ToolHandlerFn = mcp::ToolHandlerFn;
alias ToolDef = mcp::ToolDef;

// Room for crig's twenty-seven and the ones after them. Fixed rather than a List
// because the table is built once, at startup, and never grows afterwards.
const usz MAX_TOOLS = 64;

<*
 The registry.

 `tools_len` rather than `len`, matching `ToolTable` field for field, because
 `mcp/docs.c3` walks this table to build the API document and every one of those
 loops stayed as it was written.
*>
struct ToolTable
{
	ToolDef[MAX_TOOLS] tools;
	usz tools_len;
}

fn void ToolTable.add_tool(&self, ToolDef def)
{
	assert(self.tools_len < MAX_TOOLS, "too many tools registered");
	self.tools[self.tools_len++] = def;
}

fn ToolDef* ToolTable.find(&self, String name)
{
	for (usz i = 0; i < self.tools_len; i++)
	{
		if (self.tools[i].name == name) return &self.tools[i];
	}
	return null;
}

<*
 Run one tool by name.

 The single path into crig's tool surface: three's thunk calls it and so does
 every check in `test/mcp_test.c3`. Arguments arrive as the JSON *object* the
 caller sent — `{}` for a call with none — because that is the shape both sides
 already have and the only one that needs no collection type in common.

 @param arguments : `The tool's arguments as JSON text. Parsed here, so a malformed one is this function's refusal rather than a handler's.`
 @param detail : `Filled with why, when the answer is a fault. Borrowed for the call.`
 @return `The tool's reply, owned by the caller.`
 @return? TOOL_NOT_FOUND : `No tool by that name.`
 @return? TOOL_REFUSED : `The arguments were not JSON. Whatever the handler itself raises comes back unchanged.`
*>
fn String? ToolTable.invoke(&self, String name, String arguments, DString* detail)
{
	ToolDef* tool = self.find(name);
	if (tool == null)
	{
		detail.appendf("there is no tool called '%s'", name)!!;
		return TOOL_NOT_FOUND~;
	}

	// A tool with no arguments is called with none, not with a parse error: an
	// empty string and `{}` mean the same thing to every handler here.
	String source = arguments.len == 0 ? "{}" : arguments;
	Object*? parsed = json::parse(mem, source);
	if (catch parsed)
	{
		detail.append_string("the arguments would not parse as JSON");
		return TOOL_REFUSED~;
	}
	defer parsed.free();

	// The character the call names, if it names one — see `mcp/cast_tools.c3`.
	route_character((AppState*)tool.user_data, parsed, detail)!;
	return tool.handler(parsed, tool.user_data, detail);
}

// ------------------------------------------------------------ the server seam

<*
 The table the server dispatches into.

 Static because the server holds a `ToolDef*` from it for the life of the run, so
 it must not move. Not `@local`: a script's `crig.call` and a wire tool call go
 through the same table, which is the whole point of there being one.
*>
ToolTable tools;

<*
 Fills the table, once, whichever door asks for it first.

 **The doors are independent and neither may assume the other ran.** A wire tool
 call arrives through `install_tools`, which only happens when a server was asked
 for; anything else reaching the table arrives on its own path. Building the
 table in the first of those left the others empty in every run without a
 server — a caller asking for `get_weights` was told there is no such tool, which
 is true of the table and false of crig.

 Built once rather than per call for a reason that outlives the bug: the server
 holds a `ToolDef*` into this table for the life of the run, so a rebuild after
 registration would hand it pointers into a table whose contents had been
 written again underneath it.
*>
fn void ensure_tools(AppState* self)
{
	if (tools.tools_len > 0) return;
	tools = new_tool_table(self);
}

<*
 Registers every tool with the server.

 Once per run, when `main` builds one — which is not every run, since a port is
 what brings a server up. Nothing here is undone: the table outlives the
 registration and the server borrows the strings, which live in the table.

 @param server : `Built by three's new_mcp_server, already carrying its own three tools.`
*>
fn void install_tools(AppState* self, mcp::Server* server)
{
	ensure_tools(self);

	for (usz i = 0; i < tools.tools_len; i++)
	{
		ToolDef* def = &tools.tools[i];
		// `mcp::Server.add_tool` keeps a second copy of a name it already has,
		// and `tools/list` would print both: three's `screenshot` and
		// `get_api_docs` are the ones that win when the server comes with them.
		if (server_has_tool(server, def.name)) continue;
		// Routed, so a call naming a character is about that character. The table
		// is static, so the record the wrapper points at outlives the server; so
		// does the widened schema, which lives as long as the run.
		String schema;
		server.add_tool(routed_def(def, mem, &schema));
	}
}

fn bool server_has_tool(mcp::Server* server, String name) @local
{
	for (usz i = 0; i < server.tools_len; i++)
	{
		if (server.tools[i].name == name) return true;
	}
	return false;
}

<*
 The `crig` object a `run_script` body is written against.

 ## What went, and what came back

 crig used to own its own QuickJS context, with `crig.ops`, `crig.help` and
 `crig.data` hung off it by a deleted `src/mcp/script.c3` and `src/mcp/jsdata.c3`.
 When crig stopped being its own program the context went with it: the only
 JavaScript engine left in the process is three's, and its `run_script` scripts
 three's *scene*. `crig` came back `undefined` in a script — the twenty-odd tools
 were still reachable by name over the wire, but a script could not drive them.

 This file is the re-wire the old `assets/mcp_prelude.js` header specified: two
 native doors bound onto three's global object —

   __crig_call(name, argsJson) -> resultJson   every tool in `ToolTable`
   __crig_help(name)           -> jsonText      the conventions and tool reference

 — and `assets/mcp_prelude.js` evaluated on top of them, which is where the
 friendly `crig.ops.<camelCase>` / `crig.help` / `crig.call` surface is written.
 `crig.data` — the live document as writable objects — did not come back; it
 needed a property model over the document that went for good, and a script reads
 the same facts through `crig.ops.getScene` and `crig.ops.getSkeleton`.

 ## Why the natives need no `AppState`

 `__crig_call` dispatches through the module-global `tools` table, whose handlers
 already carry their `AppState*` as `user_data` from registration — the same
 table, and the same dispatch, a wire call goes through. So a script call and a
 wire call cannot diverge, which is the whole reason there is one table. The
 reply is caller-owned and freed here exactly as `mcp.c3l`'s `protocol.c3` frees
 the wire's.
*>
module crig;

import three;
import qjs;
import std::collections::object;
import std::io;

<*
 Install the `crig` scripting surface into three's runtime.

 Called once at boot, after `runtime.open`. `ensure_tools` first so the global
 table is populated whether or not a server was asked for — a script drives it
 either way. Then the two natives onto the global object, then the prelude that
 dresses them. A prelude that will not evaluate is logged and left out rather
 than fatal: it is a convenience layer over a wire surface that still answers by
 name, and a boot that dies because a comfort script had a typo is the worse
 outcome.
*>
fn void install_crig_script(three::JsRuntime* runtime, AppState* app)
{
	ensure_tools(app);

	qjs::Value global = runtime.js.global();
	defer runtime.js.release(global);
	runtime.bind(global, "__crig_call", &js_crig_call, 2);
	runtime.bind(global, "__crig_help", &js_crig_help, 1);

	three::RunResult booted = runtime.run((String)CRIG_PRELUDE_JS[..], "crig:mcp_prelude.js", drain_frame: false);
	defer booted.free();
	if (!booted.ok)
	{
		io::printfn("crig: mcp_prelude.js failed to evaluate: %s", booted.error);
	}
}

// The prelude, carried in the binary. Evaluated as a classic script — no
// import/export, no top-level await — which is why its surface hangs off
// `globalThis` rather than being returned. See the file's own header.
const char[*] CRIG_PRELUDE_JS = $embed("../../assets/mcp_prelude.js");

// One string argument, read into the temp arena. Empty for one that is absent or
// not a string, which every caller below turns into its own refusal sentence.
fn String arg_str(qjs::Context* js, int argc, qjs::Value* args, int at) @local
{
	if (at >= argc) return "";
	return js.text(args[at], tmem);
}

<*
 `__crig_call(name, argsJson) -> resultJson`.

 The one door under `crig.ops` and `crig.call`. `name` is a tool in the table and
 `argsJson` is its arguments as a JSON string — `""` and `"{}"` both mean none.
 The reply is the tool's own JSON, handed back for the prelude to `JSON.parse`; a
 refusal is raised as a JS `Error` carrying the tool's own sentence, so a script's
 `try/catch` reads exactly what the wire would have said.
*>
fn void js_crig_call(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out)
{
	qjs::Context js = qjs::wrap(ctx);
	@pool()
	{
		String name = arg_str(&js, argc, args, 0);
		if (name.len == 0)
		{
			*out = js.raise("__crig_call(name, argsJson) needs a tool name — crig.help() lists every one.");
			return;
		}
		String args_json = arg_str(&js, argc, args, 1);

		DString detail = dstring::new(tmem);
		String? payload = tools.invoke(name, args_json, &detail);
		if (catch payload)
		{
			// The handler's own refusal when it wrote one, its fault name otherwise —
			// the same choice `protocol.c3` makes for the wire.
			String why = detail.len() > 0 ? detail.str_view() : "the tool refused";
			*out = js.raise(why);
			return;
		}
		// Caller-owned, freed after `string` has copied it into the engine — the
		// same `alloc::free(mem, payload)` the wire's dispatch does.
		defer alloc::free(mem, payload);
		*out = js.string(payload);
	};
}

<*
 `__crig_help(name) -> jsonText`.

 `crig.help()` with no name is the index; `crig.help("apply_clip")` is that tool's
 description and JSON Schema off the registry the wire validates against;
 `crig.help("ground")` is a conventions section; `crig.help("all")` is every
 section. A name that is none of those hands back the index rather than an error,
 so a script that guessed wrong sees what it can ask for.
*>
fn void js_crig_help(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out)
{
	qjs::Context js = qjs::wrap(ctx);
	@pool()
	{
		String name = arg_str(&js, argc, args, 0);
		String doc = crig_help_text(name);
		defer alloc::free(mem, doc);
		*out = js.string(doc);
	};
}

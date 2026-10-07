<*
 The cast over the wire: which character a tool call is about, and the tools
 that load, remove, save and export characters together.

 **Every tool takes an optional `character`.** A name (the model's file name
 without its folder or extension) or a position in the cast; given, the call is
 about that character, and it becomes the one being edited — exactly what a click
 on it would do, so what an agent did and what the person sees next agree. Left
 out, the call is about whoever is being edited, which is every call ever written
 before there was more than one.

 The routing sits in front of the handlers rather than in them: `ToolTable.invoke`
 asks first, and the server is handed a wrapper that asks first — see
 `routed_tool`. No handler knows there is more than one character.
*>
module crig;

import mcp;
import rig;
import std::collections::object;
import std::io;

const String CHARACTER_ARGUMENT = "character";

<*
 Make the character a call names the focus. Nothing named is nothing to do.

 @return? TOOL_REFUSED : `The name or position names no loaded character; detail lists those there are.`
*>
fn void? route_character(AppState* app, Object* args, DString* detail)
{
	Object* named = member(args, CHARACTER_ARGUMENT);
	if (!named) return;

	sz found = -1;
	if (named.is_string())
	{
		String wanted = named.s;
		for (usz i = 0; i < app.character_count(); i++)
		{
			Character* c = app.character(i);
			if (c.label() == wanted || c.source_path == wanted) found = (sz)i;
		}
	}
	else if (try long at = args.get_long(CHARACTER_ARGUMENT))
	{
		if (at >= 0 && (usz)at < app.character_count()) found = (sz)at;
	}

	if (found < 0)
	{
		detail.append_string("no such character — loaded: ");
		for (usz i = 0; i < app.character_count(); i++)
		{
			detail.appendf("%s%d %s", i == 0 ? "" : ", ", i, app.character(i).label())!!;
		}
		return TOOL_REFUSED~;
	}
	if ((usz)found != app.active && !app.focus_character((usz)found))
	{
		detail.append_string("the character cannot be switched to while a clip is being generated");
		return TOOL_REFUSED~;
	}
}

<*
 The handler the server is given for every tool: route, then the tool's own.
 `user_data` is the tool's record in a table that does not move for the life of
 the server — the global `tools`, or a test fixture's.
*>
fn String? routed_tool(Object* args, void* user_data, DString* detail)
{
	ToolDef* inner = (ToolDef*)user_data;
	route_character((AppState*)inner.user_data, args, detail)!;
	return inner.handler(args, inner.user_data, detail);
}

<*
 A tool as the server is given it: routed through `routed_tool`, its schema
 saying it takes a `character`.

 @param def : `Must outlive the server.`
 @param allocator : `For the widened schema, which the caller owns when it is set.`
*>
fn ToolDef routed_def(ToolDef* def, Allocator allocator, String* schema)
{
	ToolDef out = *def;
	out.handler = &routed_tool;
	out.user_data = def;
	*schema = with_character_property(allocator, def.input_schema);
	if (schema.len > 0) out.input_schema = *schema;
	return out;
}

const String CHARACTER_PROPERTY = `"character":{"type":["string","integer"],"description":"Which loaded character this is about: its model's file name without the extension, or its position in get_scene's characters. Makes it the one being edited. Omit for the one being edited now."}`;

<*
 The schema with a `character` property added, or "" when it has no
 `properties` to add one to or already names one. The caller owns the result.
*>
fn String with_character_property(Allocator allocator, String schema) @local
{
	if (schema.contains(`"character"`)) return "";
	sz? at = schema.index_of(`"properties":{`);
	if (catch at) return "";
	usz open = (usz)at + `"properties":{`.len;
	bool empty = open < schema.len && schema[open] == '}';
	return string::format(allocator, "%s%s%s%s", schema[:open], CHARACTER_PROPERTY, empty ? "" : ",", schema[open..]);
}

// ---------------------------------------------------------------------------
// The tools
// ---------------------------------------------------------------------------

fn void add_cast_tools(ToolTable* table, AppState* app)
{
	table.add_tool({
		.name = "focus_character",
		.description = "Make one loaded character the one being edited, by the model's file name or its position in get_scene's characters. Every tool also takes a `character` argument that does the same for one call; this is for switching without doing anything else. Answers the cast.",
		.input_schema = `{"type":"object","properties":{"character":{"type":["string","integer"]}},"required":["character"]}`,
		.handler = &tool_focus_character,
		.user_data = app,
	});
	table.add_tool({
		.name = "add_character",
		.description = "Load a model beside the ones already open, as another character with its own rig, clips, poses and undo — the rig comes from its sidecar or its file, as on open. It becomes the one being edited. A file already loaded is focused instead. Answers the cast.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}`,
		.handler = &tool_add_character,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "remove_character",
		.description = "Take a character out of the scene. Its unsaved work goes with it — save_project it first. The last character cannot be removed. Answers the cast.",
		.input_schema = `{"type":"object","properties":{"character":{"type":["string","integer"]}},"required":["character"]}`,
		.handler = &tool_remove_character,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "save_scene",
		.description = "Save every character with unsaved work into its own model and sidecar, then write a .rigsmith-scene.json naming them, where each stands, the clip each plays and the scene's time, so open_scene brings the whole arrangement back.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}`,
		.handler = &tool_save_scene,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "open_scene",
		.description = "Replace everything loaded with a saved scene: every model it names, placed as it was, with its clip open at the scene's time. Refused whole if any model is missing.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}`,
		.handler = &tool_open_scene,
		.user_data = app,
		.hidden = true,
	});
	table.add_tool({
		.name = "export_scene",
		.description = "Write every rigged character into one .glb with one animation that plays each character's open clip on the shared clock, as long as the longest — a cutscene for an engine. Meshes are rebuilt (no materials or UVs), and physics and joint limits are left out.",
		.input_schema = `{"type":"object","properties":{"path":{"type":"string"},"fps":{"type":"number"}},"required":["path"]}`,
		.handler = &tool_export_scene,
		.user_data = app,
		.hidden = true,
	});
}

<*
 The loaded characters, for get_scene and every cast tool's answer: each one's
 position, name, file, joint count, where it stands, the clip the shared clock
 moves on it, and which is being edited.
*>
fn void append_cast_json(DString* out, AppState* app)
{
	out.append_string(`"characters":[`);
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (i > 0) out.append_char(',');
		out.appendf(`{"index":%d,"name":"`, i)!!;
		json_escape_into(out, c.label());
		out.append_string(`","model":"`);
		json_escape_into(out, c.source_path);
		out.appendf(`","joints":%d,"active":%s,"hidden":%s,"location":`, c.doc.dots.len(), i == app.active, c.hidden)!!;
		append_vec3(out, c.doc.model_transform.location);
		out.append_char('}');
	}
	out.appendf(`],"scene_time":%s`, (JsonFloat)app.scene_time)!!;
}

fn String cast_json(AppState* app) @local
{
	DString out = dstring::new(mem);
	defer out.free();
	out.append_char('{');
	append_cast_json(&out, app);
	out.append_char('}');
	return out.copy_str(mem);
}

fn String? tool_focus_character(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	route_character(app, args, detail)!;
	return cast_json(app);
}

fn String? tool_add_character(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, "add_character takes {\"path\": \"model.glb\"}")) return TOOL_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, "add_character needs the model's path")) return TOOL_REFUSED~;
	if (!file::is_file(path))
	{
		detail.appendf("there is no file at %s", path)!!;
		return TOOL_REFUSED~;
	}
	usz before = app.character_count();
	app.request_add_character(path);
	app.service_pending_add();
	if (app.character_count() == before && app.source_path != path)
	{
		detail.appendf("%s did not load: %s", path, app.notice())!!;
		return TOOL_REFUSED~;
	}
	return cast_json(app);
}

fn String? tool_remove_character(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	route_character(app, args, detail)!;
	if (!app.remove_character(app.active))
	{
		detail.append_string("the last character stays: a scene always has one");
		return TOOL_REFUSED~;
	}
	return cast_json(app);
}

fn String? tool_save_scene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, "save_scene takes {\"path\": \"duel.rigsmith-scene.json\"}")) return TOOL_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, "save_scene needs where to write the scene")) return TOOL_REFUSED~;
	if (!app.save_scene(path))
	{
		detail.append_string(app.notice());
		return TOOL_REFUSED~;
	}
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"scene":"`);
	json_escape_into(&out, app.scene_path);
	out.append_string(`",`);
	append_cast_json(&out, app);
	out.append_char('}');
	return out.copy_str(mem);
}

fn String? tool_open_scene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, "open_scene takes {\"path\": \"duel.rigsmith-scene.json\"}")) return TOOL_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, "open_scene needs the scene's path")) return TOOL_REFUSED~;
	if (!app.open_scene(path))
	{
		detail.append_string(app.notice());
		return TOOL_REFUSED~;
	}
	app.refresh_ui();
	return cast_json(app);
}

fn String? tool_export_scene(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, "export_scene takes {\"path\": \"duel.glb\"}")) return TOOL_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, "export_scene needs where to write the .glb")) return TOOL_REFUSED~;
	double fps = args.get_float("fps") ?? 30.0;
	if (!app.export_scene(path, fps > 0.0 ? (float)fps : 30.0f))
	{
		detail.append_string(app.notice());
		return TOOL_REFUSED~;
	}
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"written":"`);
	json_escape_into(&out, path);
	out.append_string(`","note":"`);
	json_escape_into(&out, app.notice());
	out.append_string(`"}`);
	return out.copy_str(mem);
}

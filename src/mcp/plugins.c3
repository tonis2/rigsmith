<*
 plugins: Settings › AI › Plugins for an agent (`app/plugins.c3`).

 `{"action": "list"}` answers the llm folder in use, its core, and each
 plugin (name, version, linked and where to, why it would not run). `link`
 makes a plugin's `folder` one of them — a symlink, so the folder's own files
 are what jobs run — and `unlink` takes a linked one (`name`) out again; a
 plugin folder that is really there is never deleted.
*>
module crig;

import std::collections::object;
import llm::pipeline;

faultdef PLUGINS_REFUSED;

const String PLUGINS_SCHEMA = `{"type":"object","properties":{
	"action":{"type":"string","enum":["list","link","unlink"],"description":"What to do."},
	"folder":{"type":"string","description":"link: a plugin's folder, with a plugin.json and a main.js."},
	"name":{"type":"string","description":"unlink: the linked plugin's folder name, as list gives it."}
},"required":["action"]}`;

fn String? tool_plugins(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `plugins takes an object: {"action": "list" | "link" | "unlink", ...}`)) return PLUGINS_REFUSED~;
	String action;
	if (!required_string(args, "action", &action, detail, `plugins needs "action": list, link or unlink.`)) return PLUGINS_REFUSED~;
	switch (action)
	{
		case "list":
			return plugins_json(app);
		case "link":
			String folder;
			if (!required_string(args, "folder", &folder, detail, `plugins' link needs "folder": a plugin's folder.`)) return PLUGINS_REFUSED~;
			if (catch err = app.link_llm_plugin(folder))
			{
				detail.appendf("%s: %s", folder, plugin_fault_text(err));
				return PLUGINS_REFUSED~;
			}
		case "unlink":
			String name;
			if (!required_string(args, "name", &name, detail, `plugins' unlink needs "name": a linked plugin's name.`)) return PLUGINS_REFUSED~;
			if (catch err = app.unlink_llm_plugin(name))
			{
				detail.appendf("%s: %s", name, plugin_fault_text(err));
				return PLUGINS_REFUSED~;
			}
		default:
			detail.appendf(`plugins has no action "%s": list, link or unlink.`, action);
			return PLUGINS_REFUSED~;
	}
	app.refresh_ui();
	return plugins_json(app);
}

// The llm folder and what is in its plugins/, as JSON. Owned.
fn String plugins_json(AppState* app) @private
{
	String root = app.llm_plugins_directory();
	defer alloc::free(mem, root.ptr);
	llm::pipeline::CoreInfo core = llm::pipeline::core_info(root);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"folder":"`);
	json_escape_into(&out, root);
	out.appendf(`","core":%s,"plugins":[`, core.found ? string::tformat("%d", core.version) : "null");
	llm::pipeline::PluginInfo[] plugins = llm::pipeline::list_plugins(mem, root);
	defer llm::pipeline::free_plugins(mem, plugins);
	foreach (i, p : plugins)
	{
		out.append_string(i == 0 ? `{"name":"` : `,{"name":"`);
		json_escape_into(&out, p.dir);
		out.append_string(`","version":"`);
		json_escape_into(&out, p.version);
		out.appendf(`","linked":%s,"target":"`, p.linked ? "true" : "false");
		json_escape_into(&out, p.target);
		out.append_string(`","problem":"`);
		json_escape_into(&out, p.error.len > 0 ? p.error : llm::pipeline::check_plugin(root, p.dir));
		out.append_string(`"}`);
	}
	out.append_string("]}");
	return out.copy_str(mem);
}

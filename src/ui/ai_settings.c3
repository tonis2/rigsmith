<*
 Settings › AI: the llm folder the pipelines run from. Kimodo and creature are
 JavaScript plugins read from there when a job starts, not compiled in; the
 page says which folder, what is in it, and links a plugin's folder in or out.
 The model files themselves are set on the Nodes pane's model nodes
 (`ui/nodes_panel.c3`) and kept in the config.

 The page is built by `SettingsPanel.build` with the rest of the dialog; what is
 here is its rows and what they do.
*>
module crig;

import cui;
import cui::widgets;
import std::io::file;
import std::io::path;
import llm::pipeline;

const float AI_PATH_LABEL_W = 96.0;
const float AI_PATH_FIELD_W = 330.0;

const String SETTINGS_PLUGINS_ID = "settings-plugins";
const String SETTINGS_PLUGINS_FOLDER_ID = "settings-plugins-folder";
const String AI_PLUGINS_STATUS_ID = "settings-plugins-status";
const String SETTINGS_NO_PLUGINS = "No plugins in this folder";
// Four rows: lib's neighbours are a handful, and the dialog keeps one size.
const float SETTINGS_PLUGINS_H = 4 * TREE_STYLE.row_height;

<*
 Open Settings on its AI page: from the Nodes pane, when a plugin is missing.
*>
fn void open_ai_settings(Ui* ui)
{
	ui.inherit(AppState)!!.settings_tab = SETTINGS_TAB_AI;
	open_settings_dialog(ui);
	refresh_settings_dialog(ui);
}

<*
 Take a path for `key`, from a Browse or from code, into the config and its field.
*>
fn void set_motion_path(Ui* ui, String key, String path)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.set_motion_path(key, path);
	refresh_settings_dialog(ui);
	refresh_nodes_view(ui);
}

// ---------------------------------------------------------------------------
// Plugins: the folder the pipelines run from.

fn void plugins_folder_typed(Ui* ui, String text) @private
{
	ui.inherit(AppState)!!.config.set_motion_path("plugins", text);
}

fn void plugins_folder_browse(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String root = app.llm_plugins_directory();
	defer alloc::free(mem, root.ptr);
	if (path::is_dir((Path)root)) app.remember_directory(root);
	open_file_dialog(ui, FilePurpose.PLUGINS_FOLDER);
}

fn void settings_link_plugin(Ui* ui) @private
{
	open_file_dialog(ui, FilePurpose.PLUGIN_LINK);
}

<*
 Link the chosen folder in, from the chooser. The list is read again from disk.
*>
fn void link_plugin_chosen(Ui* ui, String folder)
{
	AppState* app = ui.inherit(AppState)!!;
	if (catch err = app.link_llm_plugin(folder))
	{
		app.@notice("Could not link %s: %s", folder, plugin_fault_text(err));
	}
	else
	{
		app.@notice("Linked %s — its jobs run from that folder as it is", folder);
	}
	refresh_settings_dialog(ui);
	refresh_nodes_view(ui);
}

<*
 Unlink the selected plugin. Only a link goes; no confirmation, since nothing
 on disk but the link is touched and Link… brings it back.
*>
fn void settings_unlink_plugin(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	Tree*? list = ui.get_widget_id(SETTINGS_PLUGINS_ID, Tree);
	if (catch list) return;
	if (list.selected >= app.plugin_list.len)
	{
		app.@notice("pick a linked plugin to unlink");
		return;
	}
	String dir = app.plugin_list[list.selected].dir.tcopy();
	if (catch err = app.unlink_llm_plugin(dir))
	{
		app.@notice("Could not unlink %s: %s", dir, plugin_fault_text(err));
		return;
	}
	app.@notice("Unlinked %s; its folder is untouched", dir);
	refresh_settings_dialog(ui);
	refresh_nodes_view(ui);
}

fn TreeRow[] settings_plugin_rows(Element* elem, usz* selected) @private
{
	AppState* app = elem.inherit(AppState)!!;
	*selected = app.plugin_rows.len;
	return app.plugin_rows;
}

<*
 The line under the plugins: which folder is in use, its core, and whether the
 two plugins Rigsmith runs are there. Live, so it follows typing. Owned.
*>
fn String plugins_setup_status(Element* elem)
{
	AppState* app = elem.inherit(AppState)!!;
	String root = app.llm_plugins_directory();
	defer alloc::free(mem, root.ptr);
	llm::pipeline::CoreInfo core = llm::pipeline::core_info(root);
	if (!core.found) return string::format(mem, "%s has no core/llm.js — choose an llm folder.", root);
	String kimodo = llm::pipeline::check_plugin(root, "kimodo").len == 0 ? "ready" : "missing";
	String creature = llm::pipeline::check_plugin(root, "creature").len == 0 ? "ready" : "missing";
	return string::format(mem, "%s · core %d · Kimodo %s · creature %s", root, core.version, kimodo, creature);
}

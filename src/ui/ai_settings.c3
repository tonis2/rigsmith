<*
 Settings › AI: the model files crig's AI features run.

 Text to motion and video capture. The pipelines run on crig's own GPU through
 llm.c3l (`app/generate.c3`, `app/capture.c3`), from the llm folder — Kimodo
 and creature are JavaScript plugins read from there when a job starts, not
 compiled in. What a user supplies is the weights: the Kimodo text encoder, the
 motion model and, when it is not beside the text encoder, its tokenizer; the
 DINOv3 backbone. A field and a Browse… for each, saved as typed, and a line
 saying what is still missing. Under Plugins: which folder, what is in it, and
 linking a plugin's folder in or out.

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
const String AI_MOTION_STATUS_ID = "settings-motion-status";

<*
 One model file on the page: its `MotionGenerator` key, the field's id, what the
 row is called and what the empty field says.
*>
struct MotionPathRow
{
	String key;
	String id;
	String label;
	String placeholder;
}

// The two the pipeline cannot run without first.
MotionPathRow[3] motion_path_rows = {
	{ "text_model", "settings-motion-text-model", "Text model", "Llama-3-Kimodo-*.gguf" },
	{ "model", "settings-motion-model", "Motion model", "Kimodo-* folder, its model.safetensors, or kimodo-*.gguf" },
	{ "tokenizer", "settings-motion-tokenizer", "Tokenizer", "optional — tokenizer.gguf beside the text model" },
};
const usz MOTION_REQUIRED_PATHS = 2;

// Video capture's one file: the DINOv3 backbone the Capture pane runs.
MotionPathRow[1] capture_path_rows = {
	{ "creature_model", "settings-capture-backbone", "Backbone", "SAM 3D Body's model.ckpt (DINOv3), or its folder" },
};
const String AI_CAPTURE_STATUS_ID = "settings-capture-status";

const String SETTINGS_PLUGINS_ID = "settings-plugins";
const String SETTINGS_PLUGINS_FOLDER_ID = "settings-plugins-folder";
const String AI_PLUGINS_STATUS_ID = "settings-plugins-status";
const String SETTINGS_NO_PLUGINS = "No plugins in this folder";
// Four rows: lib's neighbours are a handful, and the dialog keeps one size.
const float SETTINGS_PLUGINS_H = 4 * TREE_STYLE.row_height;

<*
 Open Settings on its AI page: from the Generate pane, when text to motion is
 not set up yet.
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
	refresh_generate_view(ui);
	refresh_capture_view(ui);
}

fn void motion_path_typed(Ui* ui, String key, String text) @private
{
	ui.inherit(AppState)!!.config.set_motion_path(key, text);
}

fn void motion_path_browse(Ui* ui, String key) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.motion_path_key = key;
	// Start beside what is set, since the other weights are usually next to it.
	String held = *app.config.motion_generator.path_of(key);
	if (try slash = held.rindex_of_char('/'))
	{
		String dir = held[:(usz)slash];
		if (path::is_dir((Path)dir)) app.remember_directory(dir);
	}
	open_file_dialog(ui, FilePurpose.MOTION_FILE);
}

// A field's callback carries no id, so each file has its own pair.
fn void motion_text_model_changed(Ui* ui, String text) @private => motion_path_typed(ui, "text_model", text);
fn void motion_model_changed(Ui* ui, String text) @private => motion_path_typed(ui, "model", text);
fn void motion_tokenizer_changed(Ui* ui, String text) @private => motion_path_typed(ui, "tokenizer", text);
fn void motion_text_model_browse(Ui* ui) @private => motion_path_browse(ui, "text_model");
fn void motion_model_browse(Ui* ui) @private => motion_path_browse(ui, "model");
fn void motion_tokenizer_browse(Ui* ui) @private => motion_path_browse(ui, "tokenizer");
fn void capture_backbone_changed(Ui* ui, String text) @private => motion_path_typed(ui, "creature_model", text);
fn void capture_backbone_browse(Ui* ui) @private => motion_path_browse(ui, "creature_model");

fn OnChange motion_path_changed_fn(String key) @private
{
	switch (key)
	{
		case "text_model": return &motion_text_model_changed;
		case "model": return &motion_model_changed;
		case "creature_model": return &capture_backbone_changed;
		default: return &motion_tokenizer_changed;
	}
}

fn OnClick motion_path_browse_fn(String key) @private
{
	switch (key)
	{
		case "text_model": return &motion_text_model_browse;
		case "model": return &motion_model_browse;
		case "creature_model": return &capture_backbone_browse;
		default: return &motion_tokenizer_browse;
	}
}

<*
 The line under the files: what is still missing, what is not there, or that
 the Generate tab is ready. Live, so it follows typing. Owned.
*>
fn String motion_setup_status(Element* elem)
{
	MotionGenerator* g = &elem.inherit(AppState)!!.config.motion_generator;
	DString missing;
	missing.init(tmem);
	foreach (row : motion_path_rows[:MOTION_REQUIRED_PATHS])
	{
		if (g.path_of(row.key).len > 0) continue;
		missing.appendf("%s%s", missing.len() > 0 ? ", " : "", row.label);
	}
	if (missing.len() > 0) return string::format(mem, "Still needed: %s.", missing.str_view());
	foreach (row : motion_path_rows)
	{
		String held = *g.path_of(row.key);
		if (row.key == "model") continue;
		if (held.len > 0 && !file::exists(held)) return string::format(mem, "%s not found: %s", row.label, held);
	}
	String gap = motion_checkpoint_gap(g.model);
	if (gap.len > 0) return string::format(mem, "Motion model not found: %s", gap);
	return "Ready — the Generate tab can make clips.".copy(mem);
}

<*
 The line under the backbone: what is missing, or that the Capture pane is
 ready, and whether videos can be read straight (ffmpeg) or need their frames
 given. Live, so it follows typing. Owned.
*>
fn String capture_setup_status(Element* elem)
{
	String backbone = elem.inherit(AppState)!!.config.motion_generator.creature_model;
	String ffmpeg = find_program("ffmpeg");
	String videos = ffmpeg.len > 0 ? string::tformat("videos read with %s", ffmpeg) : "ffmpeg not found: give the Capture pane folders of frames";
	if (backbone.len == 0) return string::format(mem, "Still needed: the backbone · %s.", videos);
	if (!path::exists((Path)backbone)) return string::format(mem, "Backbone not found: %s", backbone);
	return string::format(mem, "Ready — the Capture pane can train and read · %s.", videos);
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
	refresh_generate_view(ui);
	refresh_capture_view(ui);
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
	refresh_generate_view(ui);
	refresh_capture_view(ui);
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

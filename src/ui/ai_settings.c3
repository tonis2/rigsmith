<*
 Settings › AI: the model files crig's AI features run.

 Today that is text to motion. The Kimodo pipeline itself is built in — llm.c3l,
 linked into crig and run on its own GPU (`app/generate.c3`) — so all a user
 supplies is the weights: the Kimodo text encoder, the motion model and,
 when it is not beside the text encoder, its tokenizer. A field and a Browse…
 for each, saved as typed, and a line saying what is still missing.

 The page is built by `SettingsPanel.build` with the rest of the dialog; what is
 here is its rows and what they do.
*>
module crig;

import cui;
import cui::widgets;
import std::io::file;
import std::io::path;

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

fn OnChange motion_path_changed_fn(String key) @private
{
	switch (key)
	{
		case "text_model": return &motion_text_model_changed;
		case "model": return &motion_model_changed;
		default: return &motion_tokenizer_changed;
	}
}

fn OnClick motion_path_browse_fn(String key) @private
{
	switch (key)
	{
		case "text_model": return &motion_text_model_browse;
		case "model": return &motion_model_browse;
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

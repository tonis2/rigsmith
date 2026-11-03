// The clip menu's Reference picture…: the frame at the playhead or a saved pose,
// drawn by the studio's two cameras at a video model's frame size, and saved
// into a folder of your choosing. See app/capture.c3.
module crig;
import cui;
import cui::widgets;
import std::io::path;

const String ANIM_REFERENCE_ID = "anim-reference";
const String REFERENCE_DIALOG_ID = "reference-dialog";
const String REFERENCE_POSE_ID = "reference-pose";
const String REFERENCE_SIZE_ID = "reference-size";
const String REFERENCE_FOLDER_ID = "reference-folder";
const String REFERENCE_DRAW_ID = "reference-draw";
const String REFERENCE_BROWSE_ID = "reference-browse";
const String REFERENCE_VIDEO_PROMPT_ID = "reference-video-prompt";
const String REFERENCE_IMAGE_PROMPT_ID = "reference-image-prompt";
const float REFERENCE_DIALOG_W = 440;
String[REFERENCE_SIZE_NAMES.len] reference_size_names = REFERENCE_SIZE_NAMES;

fn void reference_dialog_clicked(Ui* ui)
{
	anim_clip_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	free_names(mem, app.reference_pose_names);
	app.reference_pose_names = alloc::new_array(mem, String, app.doc.poses.len + 1);
	app.reference_pose_names[0] = (app.clip(app.editing) ? "Frame at the playhead" : "Rest pose").copy(mem);
	foreach (usz i, pose : app.doc.poses) app.reference_pose_names[i + 1] = string::format(mem, "Pose: %s", pose.name);
	app.reference_pose_row = 0;
	set_dialog_open(ui, REFERENCE_DIALOG_ID, true);
}

fn void reference_dialog_closed(Ui* ui) => set_dialog_open(ui, REFERENCE_DIALOG_ID, false);

fn Element* build_reference_dialog_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { REFERENCE_DIALOG_W, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Pose", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((Select) { .options = app.reference_pose_names, .selected = app.reference_pose_row, .width = REFERENCE_DIALOG_W,
				.style = VIEW_MENU_STYLE, .on_change = &reference_pose_chosen }).with_id(REFERENCE_POSE_ID);
			@node((Label) { .text = "Size: the frame size your video model makes", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((Select) { .options = reference_size_names[..], .selected = app.reference_size_row(), .width = 160,
				.style = VIEW_MENU_STYLE, .on_change = &reference_size_chosen }).with_id(REFERENCE_SIZE_ID);
			@node((Label) { .text = "Save to", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node((TextField) { .placeholder = "folder (empty: only the character's own copy)", .style = TEXT_FIELD_STYLE,
					.width = REFERENCE_DIALOG_W - 80 }).with_id(REFERENCE_FOLDER_ID);
				@node(panel_button("Browse", &reference_browse)).with_id(REFERENCE_BROWSE_ID);
			};
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(panel_button("Copy video prompt", &reference_video_prompt_clicked)).with_id(REFERENCE_VIDEO_PROMPT_ID);
				@node(panel_button("Copy image prompt", &reference_image_prompt_clicked)).with_id(REFERENCE_IMAGE_PROMPT_ID);
			};
			@tree((Row) { .gap = ANIM_GAP, .main_align = END })
			{
				@node(panel_button("Close", &reference_dialog_closed));
				@node(accent_button("Draw", &reference_draw_clicked)).with_id(REFERENCE_DRAW_ID);
			};
		};
	};
	if (try Element* field = body.find_id(REFERENCE_FOLDER_ID))
	{
		field.widget_as(TextField).set_text(field, app.config.reference_folder);
	}
	return body;
}

fn void reference_pose_chosen(Ui* ui, usz row) @private => ui.inherit(AppState)!!.reference_pose_row = row;
fn void reference_size_chosen(Ui* ui, usz row) @private => ui.inherit(AppState)!!.set_reference_size(row);

// What the file chooser answers, opened from Browse.
fn void set_reference_folder_field(Ui* ui, String folder)
{
	if (try Element* field = ui.find_id(REFERENCE_FOLDER_ID))
	{
		field.widget_as(TextField).set_text(field, folder);
	}
}

fn void reference_browse(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String typed = field_text(ui, REFERENCE_FOLDER_ID).trim();
	if (typed.len > 0 && path::is_dir((Path)typed)) app.remember_directory(typed);
	open_file_dialog(ui, FilePurpose.REFERENCE_FOLDER);
}

// The chosen pose's name ("" for the frame), and the reference it is drawn into.
fn String reference_choice(AppState* app, String* pose) @private
{
	*pose = "";
	usz row = app.reference_pose_row;
	if (row > 0 && row <= app.doc.poses.len)
	{
		*pose = app.doc.poses[row - 1].name;
		return capture_reference_name(*pose);
	}
	AnimTemplate* clip = app.clip(app.editing);
	return capture_reference_name(clip ? clip.name : "rest");
}

fn void reference_draw_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String folder = field_text(ui, REFERENCE_FOLDER_ID).trim();
	if (folder.len > 1 && folder[^1] == '/') folder = folder[:folder.len - 1];
	if (folder != app.config.reference_folder)
	{
		if (app.config.reference_folder.len > 0) alloc::free(mem, app.config.reference_folder.ptr);
		app.config.reference_folder = folder.len > 0 ? folder.copy(mem) : "";
		app.config.save();
	}
	String pose;
	String name = reference_choice(app, &pose);
	String clip_name = "";
	float time = 0;
	AnimTemplate* clip = app.clip(app.editing);
	if (pose.len == 0 && clip)
	{
		String pack = app.editing.pack >= 0 && app.editing.pack < (int)app.packs.len() ? app.packs[app.editing.pack].name : "";
		clip_name = pack.len > 0 ? string::tformat("%s/%s", pack, clip.name) : clip.name;
		time = anim_live_time(app);
	}
	String copy = folder.len > 0 ? string::tformat("%s/%s.png", folder, name) : "";
	if (catch err = app.request_capture_reference(app.capture_reference_path(name), clip_name, time, pose, 0, 0, copy))
	{
		app.@notice("No reference picture: %s", capture_fault_text(err));
	}
}

fn void reference_prompt(Ui* ui, bool video) @private
{
	AppState* app = ui.inherit(AppState)!!;
	String pose;
	float yaw = capture_left_yaw(app.capture_reference_path(reference_choice(app, &pose)));
	ui.clipboard_write(video ? capture_prompt("", yaw) : capture_pose_prompt("", yaw));
	app.@notice(video ? "Video prompt copied · write the action on its first line"
		: "Image prompt copied · write the pose on its first line");
}

fn void reference_video_prompt_clicked(Ui* ui) @private => reference_prompt(ui, true);
fn void reference_image_prompt_clicked(Ui* ui) @private => reference_prompt(ui, false);

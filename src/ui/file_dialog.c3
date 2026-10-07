<*
 The file chooser: a `FileBrowser` and a path field, assembled into the shape
 `Dialog.body` takes.

 One dialog answers two questions — which model to open, and where to write the
 export — because they are the same list of the same files, differing only in
 what the button at the bottom does. Which one is being asked is
 `AppState.file_purpose`; `Dialog.body` is a builder with no payload, so it
 cannot be carried in the call.

 **The field is the breadcrumb.** There is no separate line saying where the
 browser is: the field holds the full path of what will be opened, walking into a
 folder rewrites it, and selecting a row rewrites it again. That makes the one
 thing the dialog produces also the one thing it displays, so they cannot
 disagree — and it is what lets a path be typed that no amount of clicking would
 reach.
*>
module crig;

import cui;
import cui::widgets;
import std::io;
import std::io::path;
import std::core::string;

const float FILE_DIALOG_W = 560.0;
const float FILE_LIST_H = 300.0;
const float FILE_DIALOG_GAP = 10.0;

// The listing's background, a step darker than the dialog it sits in.
const Color FILE_LIST_WELL = BG;

// The "Recent" heading over the shortcut rows. The listing's own text size, so
// the heading and the names it heads read as one panel.
const float FILE_HEADING_SIZE = 13.0;

// Element ids inside the dialog. Named here rather than spelled at each use
// because the callbacks below reach across the subtree by id — the browser
// writes into the field, and the buttons read it back.
const String FILE_BROWSER_ID = "file-browser";
const String FILE_PATH_ID = "file-path";
const String FILE_DIALOG_ID = "file-dialog";

// The recent rows, which are in the tree only when opening a model and only
// when something has been opened before. Named so a check can ask whether they
// are there at all, which is half of what there is to assert about them.
const String RECENT_LIST_ID = "recent-list";

<*
 What the dialog is called and what its confirming button says, for the purpose
 it was opened with.

 Both come from one place so a dialog titled "Open model" can never carry a
 button that says "Export" — and Browse, which only picks where the export
 panel writes, says "Select", not "Export".
*>
struct FileDialogWords
{
	String title;
	String confirm;
}

<*
 Ask before an open that would drop characters holding unsaved work. The path
 waits on the app, since the answer arrives through a bare callback.
*>
fn void ask_before_replacing_scene(Ui* ui, String path, bool scene) @private
{
	AppState* app = ui.inherit(AppState)!!;
	Element*? panel = ui.find_id(CONFIRM_DIALOG_ID);
	if (catch panel)
	{
		app.@notice("save the scene first — opening replaces it");
		return;
	}
	if (app.open_waiting.len > 0) alloc::free(mem, app.open_waiting.ptr);
	app.open_waiting = path.copy(mem);
	app.open_waiting_scene = scene;
	panel.widget_as(ConfirmDialog).ask(panel,
		"The scene has unsaved changes. Opening replaces it — continue without saving them?",
		&replace_scene_confirmed, &replace_scene_declined);
}

fn void replace_scene_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.open_waiting.len == 0) return;
	if (app.open_waiting_scene) { app.request_open_scene(app.open_waiting); }
	else { app.request_open(app.open_waiting); }
	replace_scene_declined(ui);
}

fn void replace_scene_declined(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.open_waiting.len > 0) alloc::free(mem, app.open_waiting.ptr);
	app.open_waiting = "";
}

<*
 File › New scene over unsaved work: the same question opening asks, since an
 empty stage loses that work just as surely.
*>
fn void ask_before_new_scene(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Element*? panel = ui.find_id(CONFIRM_DIALOG_ID);
	if (catch panel)
	{
		app.@notice("save the scene first — a new one replaces it");
		return;
	}
	panel.widget_as(ConfirmDialog).ask(panel,
		"The scene has unsaved changes. Start a new one without saving them?",
		&new_scene_confirmed, null);
}

fn void new_scene_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.new_scene();
	app.refresh_ui();
}

fn FileDialogWords file_dialog_words(FilePurpose purpose) @private
{
	switch (purpose)
	{
		case EXPORT_TARGET: return { "Export to", "Select" }; // picks the path; the panel exports
		case ASSET_LIBRARY: return { "Add asset library", "Add" };
		case MOTION_FILE: return { "Choose a model file", "Select" };
		case ADD_CHARACTER: return { "Import .glb into the scene", "Import" };
		case OPEN_SCENE: return { "Open scene", "Open" };
		case SAVE_SCENE: return { "Save scene as", "Save" };
		case EXPORT_SCENE: return { "Export the scene to", "Export" };
		default: return { "Open model", "Open" };
	}
}

<*
 Build the chooser as a detached subtree — the shape `Dialog.body` is called for.

 Called afresh on every opening, which is what lets the browser start in the
 remembered directory rather than wherever it was left: the widgets are new, and
 `AppState.browse_start` is asked here.
*>
fn Element* build_file_dialog_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	return @subtree(ui)
	{
		@tree((Column) { .size = { FILE_DIALOG_W, 0 }, .gap = FILE_DIALOG_GAP })
		{
			// The shortcut, above the long way round. Only when opening: a recent
			// project is somewhere to read a model from, and the export dialog's
			// Browse is asking where to write one — offering the same five paths
			// there invites overwriting a model with a rig of itself.
			//
			// Both the heading and the rows are absent when nothing has been
			// opened yet, rather than a heading over a blank strip. `RecentList`
			// sizes itself to its rows, so the empty case costs no height; the
			// heading has to be asked for separately.
			if ((app.file_purpose == FilePurpose.OPEN_SCENE || app.file_purpose == FilePurpose.OPEN_MESH) && app.config.recent.len() > 0)
			{
				@node((Label) {
					.text = "Recent",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});
				@node((RecentList) { }).with_id(RECENT_LIST_ID);
			}

			// Fixed height, unlike the rest of the column: a dialog that grew with
			// the number of files in a folder would be a different size in every
			// directory, and taller than the screen in some of them.
			//
			// On a sunken well the size of the scroll, so the listing reads as one
			// box with an edge rather than rows floating on the dialog.
			@tree((Stack) { .size = { FILE_DIALOG_W, FILE_LIST_H } })
			{
				@node((Rectangle) {
					.size = { FILE_DIALOG_W, FILE_LIST_H },
					.style = { .color = FILE_LIST_WELL, .border_color = PANEL_BORDER, .border_width = 1.0, .border_radius = R8 },
				});
				@tree((Scroll) { .size = { FILE_DIALOG_W, FILE_LIST_H }, .radii = R8 })
				{
					// `start` is the AppState's own buffer, not a temporary: a widget
					// borrows its strings for the life of its element, and this one
					// is read again at the browser's first layout.
					@node((FileBrowser) {
						.start = app.config.browse_directory,
						.mask = file_dialog_mask(app),
						.style = FILE_BROWSER_STYLE,
						.on_select = &file_row_selected,
						.on_choose = &file_row_chosen,
						.on_directory = &file_directory_changed,
					}).with_id(FILE_BROWSER_ID);
				};
			};

			@node((TextField) {
				.placeholder = "path",
				.style = TEXT_FIELD_STYLE,
				.on_submit = &file_path_submitted,
			}).with_id(FILE_PATH_ID);

			@node(
				(Row) { .gap = FILE_DIALOG_GAP, .main_align = END },
				panel_button("Cancel", &file_dialog_cancelled),
				accent_button(file_dialog_words(app.file_purpose).confirm, &file_dialog_confirmed)
			);
		};
	};
}

<*
 Which files the list shows: models to rig, or Kimodo's weights for Settings › AI.
*>
fn String[] file_dialog_mask(AppState* app) @private
{
	switch (app.file_purpose)
	{
		case MOTION_FILE: return motion_file_mask[..];
		case OPEN_SCENE:
		case SAVE_SCENE: return scene_mask[..];
		default: return mesh_mask[..];
	}
}

<*
 Open the chooser for `purpose`.

 The title and the confirming button are rebuilt with the body, so the purpose
 has to be set before the dialog is opened rather than after.
*>
fn void open_file_dialog(Ui* ui, FilePurpose purpose)
{
	AppState* app = ui.inherit(AppState)!!;
	app.file_purpose = purpose;

	// Settled before the body is built, because the browser reads it from its
	// literal and holds the slice — a directory decided afterwards would be read
	// from a field that was still empty when the widget copied it.
	//
	// A remembered folder that has gone is forgotten first: an AppImage is
	// mounted somewhere new each run, so one remembered inside the bundled
	// library names a mount point that no longer exists.
	if (app.config.browse_directory.len > 0 && !file::is_dir(app.config.browse_directory))
	{
		app.remember_directory("");
	}
	if (app.config.browse_directory.len == 0)
	{
		String start = app.browse_start(mem);
		defer if (start.len > 0) start.free(mem);
		app.remember_directory(start);
	}

	if (try Element* dialog = ui.find_id(FILE_DIALOG_ID))
	{
		Dialog* widget = dialog.widget_as(Dialog);
		widget.title = file_dialog_words(purpose).title;
		widget.set_open(dialog, true);
	}
}

fn void close_file_dialog(Ui* ui) @private
{
	set_dialog_open(ui, FILE_DIALOG_ID, false);
}

// The field, as the one place the dialog's answer lives. Empty when the dialog
// is closed, since its subtree is released then.
fn String file_path(Ui* ui) @private
{
	if (try TextField* field = ui.get_widget_id(FILE_PATH_ID, TextField)) return field.value();
	return "";
}

fn void set_file_path(Ui* ui, String path) @private
{
	if (try Element* elem = ui.find_id(FILE_PATH_ID))
	{
		elem.widget_as(TextField).set_text(elem, path);
	}
}

// ---------------------------------------------------------------------------
// What the browser reports

fn void file_row_selected(Ui* ui, String path) @private
{
	set_file_path(ui, path);
}

// A file activated in the list is the same answer as the confirming button, and
// has to mean the same thing — so it goes through it rather than beside it.
fn void file_row_chosen(Ui* ui, String path) @private
{
	set_file_path(ui, path);
	file_dialog_confirmed(ui);
}

<*
 Follow the browser into a folder: remember it, and show it in the field.

 The trailing separator is deliberate. It says the field holds a place rather
 than a file, which is the difference between Export writing `models/goat.glb`
 and writing a file called `models`.
*>
fn void file_directory_changed(Ui* ui, String directory) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.remember_directory(directory);

	String shown = string::tformat("%s/", directory);
	set_file_path(ui, shown);
}

// ---------------------------------------------------------------------------
// What the buttons do

fn void file_dialog_cancelled(Ui* ui) @private
{
	close_file_dialog(ui);
}

fn void file_path_submitted(Ui* ui, String text) @private
{
	file_dialog_confirmed(ui);
}

<*
 Take what is in the field and act on it.

 A directory is not an answer to either question, so it navigates instead —
 which is what makes typing a path work: the field takes you there, and the next
 confirmation takes the file.
*>
fn void file_dialog_confirmed(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;

	String typed = file_path(ui).trim();
	if (typed.len == 0) return;

	// Walking there rather than opening it. A trailing separator means the same
	// thing, and is what `file_directory_changed` leaves behind.
	String bare = typed.len > 1 && typed[^1] == '/' ? typed[:typed.len - 1] : typed;
	if (path::is_dir((Path)bare) && app.file_purpose != FilePurpose.ASSET_LIBRARY)
	{
		if (try Element* elem = ui.find_id(FILE_BROWSER_ID))
		{
			elem.widget_as(FileBrowser).go_to(elem, bare);
		}
		return;
	}

	// A library is a folder, so the folder in the field is the answer and there is
	// nothing to navigate into. Which also means it is the one purpose here that
	// must refuse a *file*: adding one as a library would make a browser that lists
	// nothing and says nothing about why.
	if (app.file_purpose == FilePurpose.ASSET_LIBRARY && !path::is_dir((Path)bare))
	{
		app.@notice("%s is not a folder", bare);
		app.refresh_ui();
		return;
	}

	// Copied before the dialog closes: the field is inside the subtree that
	// closing releases, and this string is a view into its buffer.
	String path = bare.copy(mem);
	defer path.free(mem);

	close_file_dialog(ui);

	switch (app.file_purpose)
	{
		case OPEN_MESH:
			// Opening a model replaces the scene: the others' work goes with it.
			if (app.any_character_unsaved())
			{
				ask_before_replacing_scene(ui, path, false);
				return;
			}
			app.request_open(path);
		case ADD_CHARACTER:
			app.request_add_character(path);
		case OPEN_SCENE:
			if (app.any_character_unsaved())
			{
				ask_before_replacing_scene(ui, path, true);
				return;
			}
			app.request_open_scene(path);
		case SAVE_SCENE:
			(void)app.save_scene(path);
		case EXPORT_SCENE:
			(void)app.export_scene(path.ends_with(".glb") ? path : string::tformat("%s.glb", path));
		case EXPORT_TARGET:
			// The chooser was opened from the export panel's Browse, and the
			// panel is still up behind it: this answers where, and the panel's
			// own Export answers what goes in it.
			set_export_path(ui, path);
		case ASSET_LIBRARY:
			// The settings panel is still up behind this, the way the export panel
			// is: this answers which folder, and the panel goes on listing them.
			add_asset_library(ui, path);
		case MOTION_FILE:
			set_motion_path(ui, app.motion_path_key, path);
	}
	app.refresh_ui();
}

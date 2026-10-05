<*
 Settings: how big the interface is drawn, whether posing is checked against
 the body, which folders the asset browser reads, where text-to-motion's
 llm-runner and Kimodo weights are, and the MCP port.

 	File > Settings

 The libraries are the substance of it. crig used to read one hard-coded folder;
 what is here is the list that replaced it, and adding to it is how a user's own
 rigs and clips get into the browser at all.

 The interface size is above them, and it is the one thing here that is not about
 what crig has open — it is about being able to read crig at all, which is why it
 has the top of the panel and a pair of keys besides. `ui/ui_scale.c3` owns what
 the number means; this file owns the row.

 **The list is a `Tree`, not a widget of its own.** A row is a name and a path and
 nothing else, and the one action on it acts on the selected row — which is
 exactly what a `Tree` reports. Painting a listing here with a remove target in
 each row would be a second copy of hit-test arithmetic for no gain.

 What is here and what is not: this holds settings that outlive the run, which is
 the same rule `core/config.c3` follows. Anything about the document belongs to
 the document, and anything about the view belongs to the view's own menu.

 Nothing in the subtree is state. `Dialog.body` is rebuilt on every opening and
 released on every close, so every answer is read out of `app.config` and written
 straight back to it — and a string taken out of a field is copied before the
 panel can close under it.
*>
module crig;

import cui;
import cui::widgets;


import std::math::vector;
import std::io::file;
import std::io::path;

const String SETTINGS_DIALOG_ID = "settings-dialog";
const String SETTINGS_PANEL_ID = "settings-panel";
const String SETTINGS_LIBRARIES_ID = "settings-libraries";
const String SETTINGS_PORT_ID = "settings-port";
const String SETTINGS_SCALE_ID = "settings-scale";
const String SETTINGS_RIG_OVERLAY_ID = "settings-rig-overlay";
const String SETTINGS_COLLISION_ID = "settings-self-collision";

const float SETTINGS_DIALOG_W = 520.0;
const float SETTINGS_GAP = 10.0;

// Five rows: a handful of libraries without scrolling, and fixed so the panel is
// the same size however many are configured — a dialog that grew with the list
// would jump under the pointer as rows were added and removed. Not more, because
// one or two libraries is the usual configuration and the rest of the box is
// blank in it.
const float SETTINGS_LIST_H = 5 * TREE_STYLE.row_height;

const float SETTINGS_PORT_W = 100.0;
const String SETTINGS_TABS_ID = "settings-tabs";

// The panel's pages: everything about crig itself, and the models the AI
// features run (`ui/ai_settings.c3`).
const usz SETTINGS_TAB_GENERAL = 0;
const usz SETTINGS_TAB_AI = 1;
String[2] settings_tab_names = { "General", "AI" };

<*
 The interface-scale row: how wide its track is, and what a drag can land on.

 The slider is given a width rather than left to fill the row, because the Reset
 button shares that row and a slider that filled it would push the button off the
 panel. 0.05 steps because that is finer than the eye can tell apart at a glance
 and coarse enough that the readout is two decimals rather than five.
*>
const float SETTINGS_SCALE_SLIDER_W = 320.0;
const float SETTINGS_SCALE_STEP = 0.05;
const float SETTINGS_RIG_OVERLAY_MIN = 10.0;
const float SETTINGS_RIG_OVERLAY_MAX = 100.0;
const float SETTINGS_RIG_OVERLAY_STEP = 5.0;

// Says what the setting multiplies, since 1× is not "one pixel per point" — the
// display's own density is already in there, which is why the default is right
// on a retina panel without anybody touching it. The keys are named because they
// are the way out of an interface too small to find this panel in.
const String SETTINGS_SCALE_NOTE =
	"Interface size — on top of what the display asks for. ctrl+= and ctrl+- step it, ctrl+0 resets.";

// What the list says when there are none. An empty box reads as a broken panel
// rather than as a setting waiting to be made.
const String SETTINGS_NO_LIBRARIES = "No asset libraries — add a folder of .glb files";

<*
 Rebuild the library rows from the config.

 The labels are borrowed from `config.libraries`, which outlives the panel — but
 not a rescan, so anything that changes the config rebuilds these before the tree
 is drawn again. Held on the AppState rather than beside this panel for the
 reason `category_rows` is: a `Tree` borrows its rows for the life of its
 element, and this panel's subtree is released every time it closes.
*>
fn void AppState.refresh_library_rows(&self)
{
	self.free_library_rows();

	AssetLibrary[] libraries = self.config.libraries.array_view();
	if (libraries.len == 0) return;

	self.library_rows = alloc::new_array(mem, TreeRow, (sz)libraries.len);
	foreach (usz i, library : libraries)
	{
		self.library_rows[i] = {
			.label = library.name.len > 0 ? library.name : UNNAMED_LIBRARY_LABEL,
			// The path in the right-hand column, because the name is a label the
			// user chose and the path is what actually decides what shows up.
			.trailing = library.path,
			.depth = 0,
		};
	}
}

fn void AppState.free_library_rows(&self)
{
	if (self.library_rows.len > 0) alloc::free(mem, self.library_rows);
	self.library_rows = {};
}

<*
 Open the settings panel.
*>
fn void open_settings_dialog(Ui* ui)
{
	set_dialog_open(ui, SETTINGS_DIALOG_ID, true);
}

<*
 Rebuild the panel's contents in place.

 Called after anything changes the config, so the list shows what is configured
 now. A rebuild rather than closing and reopening the dialog: reopening recentres
 it, and a panel that jumped back to the middle of the screen every time a folder
 was added would be a panel nobody could put anywhere.
*>
fn void refresh_settings_dialog(Ui* ui)
{
	if (try Element* panel = ui.find_id(SETTINGS_PANEL_ID)) panel.request_build();
}

// The body is one widget rather than a subtree so that `refresh_settings_dialog`
// has something to ask for a rebuild of — `request_paint` on a plain Column
// would repaint the rows it already has.
fn Element* build_settings_body(Ui* ui)
{
	return @subtree(ui)
	{
		@node((SettingsPanel) { }).with_id(SETTINGS_PANEL_ID);
	};
}

struct SettingsPanel (Widget)
{
	// Nothing to hold: everything shown is read out of `app.config` in `build`,
	// and the element itself is the handle `refresh_settings_dialog` asks for a
	// rebuild of. The field is here only because C3 forbids a zero-sized struct.
	//
	// Deliberately not named `size`: a `Vec2 size` on a widget with no `layout`
	// is cui's size-field convention, and a zero one fills whatever the parent
	// offered. That is right for a window root and wrong here — the dialog offers
	// the whole screen less its margin, so the panel would take all of it and the
	// chrome would close around 500 points of content in a 1200-point box.
	// Without the field the composite default applies: the built Column decides
	// the size and the dialog fits it.
	char no_state;
}

fn Element* SettingsPanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	app.refresh_library_rows();

	Element* body = @subtree(elem.ui)
	{
		@tree((Column) { .size = { SETTINGS_DIALOG_W, 0 }, .gap = SETTINGS_GAP })
		{
			@node((Segmented) {
				.options = settings_tab_names[..],
				.selected = (sz)app.settings_tab,
				.on_change = &settings_tab_chosen,
				.style = SEGMENTED_STYLE,
			}).with_id(SETTINGS_TABS_ID);

			if (app.settings_tab == SETTINGS_TAB_AI)
			{
				// Text to motion: the Kimodo pipeline is built in (llm.c3l);
				// what it needs from the user is the weights. Saved as typed.
				@node((Label) {
					.text = "Text to motion (Kimodo) — the weights the Generate tab runs.",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});
				foreach (row : motion_path_rows)
				{
					@tree((Row) { .gap = SETTINGS_GAP, .cross_align = CENTER })
					{
						@tree((Row) { .size = { AI_PATH_LABEL_W, 0 } })
						{
							@node((Label) { .text = row.label, .size = FILE_HEADING_SIZE, .color = TEXT });
						};
						@node((TextField) {
							.placeholder = row.placeholder,
							.style = TEXT_FIELD_STYLE,
							.width = AI_PATH_FIELD_W,
							.on_change = motion_path_changed_fn(row.key),
						}).with_id(row.id);
						@node(panel_button("Browse…", motion_path_browse_fn(row.key)));
					};
				}
				@node((LiveLabel) { .text_of = &motion_setup_status, .size = { SETTINGS_DIALOG_W, TREE_STYLE.row_height },
					.text_size = FILE_HEADING_SIZE, .color = TEXT_DIM }).with_id(AI_MOTION_STATUS_ID);
			}
			else
			{
				// First, above the libraries, and that is about who opens this panel
				// and why. A person whose interface came up half-size cannot read the
				// rest of it well enough to hunt, and this is the one setting here
				// that is about being able to see the program at all.
				@node((Label) {
					.text = SETTINGS_SCALE_NOTE,
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});

				// A `@tree` rather than a `@node` with two children, only so the slider
				// itself can carry an id: the id belongs to the element, and the
				// children of a `@node` are widgets that have none yet.
				@tree((Row) { .gap = SETTINGS_GAP, .cross_align = CENTER })
				{
					@node((Slider) {
						.label = "Interface",
						.suffix = "×",
						.value = clamp_ui_scale(app.config.ui_scale),
						// The ends this display can actually deliver, not the two
						// constants: the engine clamps the density and the setting
						// multiplied together, so on a 2× output the top of the taste
						// range is a stretch of track that would move nothing.
						.min = usable_ui_scale_min(),
						.max = usable_ui_scale_max(),
						.step = SETTINGS_SCALE_STEP,
						.decimals = 2,
						// The release only — see `ui_scale_committed` for why the
						// drag must not be the thing that re-lays out the panel it is
						// being dragged on.
						.on_commit = &ui_scale_committed,
						.style = SETTINGS_SLIDER_STYLE,
						.size = { SETTINGS_SCALE_SLIDER_W, 0 },
					}).with_id(SETTINGS_SCALE_ID);

					@node(panel_button("Reset", &menu_ui_reset));
				};

				@node((Label) {
					.text = "Rig overlay strength — rear joints remain faded.",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});
				@node((Label) {
					.text = "Selected joints stay clear. S hides the rig.",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});

				@tree((Row) { .gap = SETTINGS_GAP, .cross_align = CENTER })
				{
					@node((Slider) {
						.label = "Rig overlay",
						.suffix = "%",
						.value = effective_rig_overlay_strength(app) * 100.0f,
						.min = SETTINGS_RIG_OVERLAY_MIN,
						.max = SETTINGS_RIG_OVERLAY_MAX,
						.step = SETTINGS_RIG_OVERLAY_STEP,
						.decimals = 0,
						.on_commit = &rig_overlay_strength_committed,
						.style = SETTINGS_SLIDER_STYLE,
						.size = { SETTINGS_SCALE_SLIDER_W, 0 },
					}).with_id(SETTINGS_RIG_OVERLAY_ID);

					@node(panel_button("Reset", &reset_rig_overlay_strength));
				};

				// The self-collision system, whole, and off unless asked for — see
				// `CrigConfig.self_collision`. Takes effect at once: the policy is
				// built or released with the click, and the posing row gains or
				// loses its control on the refresh.
				@node((Label) {
					.text = "Posing — experimental. Stops hands and legs at the body while posing.",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});
				@node((Checkbox) {
					.label = "Prevent self-collisions",
					.checked = app.config.self_collision,
					.on_change = &settings_self_collision_toggled,
					.style = CHECKBOX_STYLE,
				}).with_id(SETTINGS_COLLISION_ID);

				@node((Label) {
					.text = "Asset libraries",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});

				@tree((Scroll) { .size = { SETTINGS_DIALOG_W, SETTINGS_LIST_H } })
				{
					@node((EmptyStateTree) { .rows_of = &settings_library_rows, .empty = SETTINGS_NO_LIBRARIES,
						.empty_color = TEXT_DIM, .style = TREE_STYLE, .tree_id = SETTINGS_LIBRARIES_ID });
				};

				@node(
					(Row) { .gap = SETTINGS_GAP },
					panel_button("Add folder", &settings_add_library),
					panel_button("Remove selected", &settings_remove_library)
				);

				@node((Label) {
					.text = "MCP server — lets AI agents drive Rigsmith. Port, or 0 to turn it off.",
					.size = FILE_HEADING_SIZE,
					.color = TEXT_DIM,
				});

				@tree((Row) { .gap = SETTINGS_GAP })
				{
					@node((TextField) {
						.placeholder = "port",
						.style = TEXT_FIELD_STYLE,
						.on_submit = &settings_port_submitted,
						.width = SETTINGS_PORT_W,
					}).with_id(SETTINGS_PORT_ID);
					@node(panel_button("Copy client config", &settings_copy_mcp_config));
				};

				@node((LiveLabel) { .text_of = &mcp_status_text, .size = { 0, TREE_STYLE.row_height },
					.text_size = 12, .color = TEXT_DIM });
			}
		};
	};

	// What is configured, into fields that do not hold state of their own.
	foreach (row : motion_path_rows)
	{
		if (try Element* field = body.find_id(row.id))
		{
			field.widget_as(TextField).set_text(field, *app.config.motion_generator.path_of(row.key));
		}
	}
	if (try Element* field = body.find_id(SETTINGS_PORT_ID))
	{
		field.widget_as(TextField).set_text(field, string::tformat("%d", app.config.mcp_port));
	}
	return body;
}

// The library folders for the settings list. Past the end selected, so the
// panel opens with nothing selected and "Remove selected" has nothing to take
// until a row is picked.
fn TreeRow[] settings_library_rows(Element* elem, usz* selected) @private
{
	AppState* app = elem.inherit(AppState)!!;
	*selected = app.library_rows.len;
	return app.library_rows;
}

// ---------------------------------------------------------------------------
// What the buttons do

<*
 Ask for a folder.

 Through the file chooser, which comes up over this panel the way it does over
 the export panel — this stays open behind it, and `add_asset_library` is what
 the chooser calls back into.
*>
fn void settings_add_library(Ui* ui)
{
	open_file_dialog(ui, FilePurpose.ASSET_LIBRARY);
}

<*
 Take a folder into the library list and read it.

 Called by the file chooser once it has a directory. The rescan is immediate
 rather than deferred to the next start: a folder added in the settings that did
 not appear in the browser until crig was restarted would read as not having been
 added at all.
*>
fn void add_asset_library(Ui* ui, String directory)
{
	AppState* app = ui.inherit(AppState)!!;

	if (!app.config.add_library(directory))
	{
		app.@notice("%s is already a library", directory);
		return;
	}

	app.scan_libraries();
	refresh_settings_dialog(ui);
	app.@notice("added %s — %d assets", directory, app.assets.entries.len);
}

<*
 Drop the selected library.

 No confirmation: nothing on disk is touched, and the folder goes back with one
 more click of Add. The confirm is for things that replace a document.
*>
fn void settings_remove_library(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	Tree*? list = ui.get_widget_id(SETTINGS_LIBRARIES_ID, Tree);
	if (catch list) return;
	if (list.selected >= app.library_rows.len)
	{
		app.@notice("pick a library to remove");
		return;
	}

	if (!app.config.remove_library((sz)list.selected)) return;

	// The rows point into the config entry that was just freed, so nothing may
	// read them again before they are rebuilt — which the rebuild below does
	// before the tree is next drawn.
	app.scan_libraries();
	refresh_settings_dialog(ui);
	app.@notice("%d assets in %d libraries",
		app.assets.entries.len, app.config.libraries.len());
}

<*
 Take the typed port: saved, and applied at once — `main` rebinds the listener
 between frames, so nothing is mid-answer when the old port closes.
*>
fn void settings_port_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;

	int? given = text.trim().to_int();
	if (catch given)
	{
		app.@notice("a port is a number, not '%s'", text.trim());
		return;
	}
	if (given < 0 || given > 65535)
	{
		app.@notice("%d is not a port", given);
		return;
	}

	app.config.mcp_port = given;
	app.config.save();
	app.mcp_restart_wanted = true;
	app.@notice(given == 0 ? "MCP server off" : "MCP server on port %d", given);
}

<*
 What the MCP server is doing, under the port field. Owned, as LiveLabel wants.
*>
fn String mcp_status_text(Element* elem)
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.mcp_serving_port > 0)
	{
		return string::format(mem, "Serving at %s", mcp_url(app.mcp_serving_port));
	}
	if (app.mcp_port_busy)
	{
		return string::format(mem, "Port %d is in use — another Rigsmith? Pick another port.", app.config.mcp_port);
	}
	return "Off".copy(mem);
}

fn String mcp_url(int port) @private => string::tformat("http://127.0.0.1:%d/mcp", port);

<*
 The server's entry for an MCP client's config file, onto the clipboard — the
 shape Claude Code's `.mcp.json` and most other clients read.
*>
fn void settings_copy_mcp_config(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.mcp_serving_port == 0)
	{
		app.@notice("the MCP server is off — set a port first");
		return;
	}
	ui.clipboard_write(string::tformat(`{"mcpServers": {"rigsmith": {"type": "http", "url": "%s"}}}`,
		mcp_url(app.mcp_serving_port)));
	app.@notice("copied — paste it into your agent's MCP config");
}

fn void settings_self_collision_toggled(Ui* ui, bool checked)
{
	AppState* app = ui.inherit(AppState)!!;
	app.set_self_collision(checked);
	// The posing row gains or loses its control: a build, not a paint.
	refresh_animations_view(ui);
	app.refresh_ui();
}

fn void adopt_rig_overlay_strength(Ui* ui, float value)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.rig_overlay_strength = math::clamp(value,
		MIN_RIG_OVERLAY_STRENGTH, MAX_RIG_OVERLAY_STRENGTH);
	app.config.save();
	app.refresh_ui();
}

fn void rig_overlay_strength_committed(Ui* ui, float value)
{
	adopt_rig_overlay_strength(ui, value / 100.0f);
}

fn void reset_rig_overlay_strength(Ui* ui)
{
	adopt_rig_overlay_strength(ui, DEFAULT_RIG_OVERLAY_STRENGTH);
	refresh_settings_dialog(ui);
}

fn void settings_tab_chosen(Ui* ui, usz tab) @private
{
	ui.inherit(AppState)!!.settings_tab = tab;
	refresh_settings_dialog(ui);
}

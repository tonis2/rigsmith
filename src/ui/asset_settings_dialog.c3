<*
 What one asset in the browser is called, and what its file is for.

 	The gear on a hovered cell in the Assets view

 Two scopes in one panel, and the labels say which is which. **The name is the
 item's** — the glTF animation's or the skin's own — and only that cell changes
 when it is edited. **The plan and the tags are the file's**, because glTF's
 root `extras` is the only place there is to put them, so every cell out of that
 file is retagged together.

 Both are written into the .glb where it lies; see `AppState.retag_asset` and
 `patch_gltf` for why that costs nothing but the bytes it changes. Saving
 rereads every library, which stops playback and replaces the index — so the
 panel closes before it saves, and the three answers are copied out of their
 fields first.

 Nothing here is state. `Dialog.body` is rebuilt on every opening and released
 on every close, so the fields are filled from the index each time and read
 straight back into the file.
*>
module crig;

import cui;
import cui::widgets;


import std::math::vector;

const String ASSET_SETTINGS_DIALOG_ID = "asset-settings-dialog";
const String ASSET_SETTINGS_NAME_ID = "asset-settings-name";
const String ASSET_SETTINGS_PLAN_ID = "asset-settings-plan";
const String ASSET_SETTINGS_TAGS_ID = "asset-settings-tags";
const String ASSET_SETTINGS_DELETE_ID = "asset-settings-delete";

// Wide enough for a tag line of several words without wrapping, which is the
// longest thing typed in here.
const float ASSET_SETTINGS_W = 420.0;
const float ASSET_SETTINGS_GAP = 8.0;
const float ASSET_SETTINGS_HEAD_H = 20.0;
const float ASSET_SETTINGS_TEXT = 12.0;

<*
 Open the panel on one visible cell.

 The row is resolved to a position in the whole index before the dialog opens:
 the panel outlives a search, and a row number does not.

 @param row : `A position in the visible list; out of range opens nothing.`
*>
fn void open_asset_settings(Ui* ui, usz row)
{
	AppState* app = ui.inherit(AppState)!!;
	if (row >= app.visible_assets.len) return;

	// Before the dialog opens, not after: opening builds the body, and the body
	// is what reads this.
	app.settings_asset = (int)app.visible_assets[row];

	set_dialog_open(ui, ASSET_SETTINGS_DIALOG_ID, true);
}

<*
 Build the panel as a detached subtree — the shape `Dialog.body` takes.
*>
fn Element* build_asset_settings_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	// Fetched before the subtree, so the footer can gate its Delete on it. Delete is
	// for the loaded model's own animations alone: a library file is not this model's
	// to rewrite, and a model that cannot take a skin in place cannot be re-saved
	// without the clip.
	AssetEntry* entry = app.settings_entry();
	bool can_delete = entry != null && entry.kind == AssetKind.ANIMATION
		&& app.source_path.len > 0 && entry.file == app.source_path && app.has_mesh();

	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { ASSET_SETTINGS_W, 0 }, .gap = ASSET_SETTINGS_GAP })
		{
			@node((AssetSettingsHead) { });

			@node((Label) { .text = "Name", .size = ASSET_SETTINGS_TEXT, .color = TEXT_DIM });
			@node((TextField) {
				.placeholder = "unnamed",
				.style = TEXT_FIELD_STYLE,
				.width = ASSET_SETTINGS_W,
			}).with_id(ASSET_SETTINGS_NAME_ID);

			@node((Label) {
				.text = "Body plan — the whole file's. Blank leaves it untagged.",
				.size = ASSET_SETTINGS_TEXT,
				.color = TEXT_DIM,
			});
			@node((TextField) {
				.placeholder = "biped",
				.style = TEXT_FIELD_STYLE,
				.width = ASSET_SETTINGS_W,
			}).with_id(ASSET_SETTINGS_PLAN_ID);

			@node((Label) {
				.text = "Tags — the whole file's, comma separated. Searched by the box above the grid.",
				.size = ASSET_SETTINGS_TEXT,
				.color = TEXT_DIM,
			});
			@node((TextField) {
				.placeholder = "walking, slow",
				.style = TEXT_FIELD_STYLE,
				.width = ASSET_SETTINGS_W,
			}).with_id(ASSET_SETTINGS_TAGS_ID);

			if (can_delete)
			{
				@node((Label) {
					.text = "Delete takes this animation out of the model on disk and re-saves it.",
					.size = ASSET_SETTINGS_TEXT,
					.color = TEXT_DIM,
				});
			}

			@tree((Row) { .gap = ASSET_SETTINGS_GAP, .main_align = END })
			{
				if (can_delete)
				{
					@node(danger_button("Delete", &asset_settings_delete)).with_id(ASSET_SETTINGS_DELETE_ID);
				}
				@node(panel_button("Cancel", &asset_settings_cancelled));
				@node(accent_button("Save", &asset_settings_saved));
			};
		};
	};

	// Through the subtree, not the Ui: `Dialog.build` has not attached any of
	// this yet, so the tree-wide lookup cannot see it.
	if (entry)
	{
		fill_field(body, ASSET_SETTINGS_NAME_ID, entry.name);
		fill_field(body, ASSET_SETTINGS_PLAN_ID, entry.plan);
		fill_field(body, ASSET_SETTINGS_TAGS_ID, entry.tags);
	}

	return body;
}

// An empty value is left on the placeholder rather than set to "": a field
// holding an empty string and one holding nothing look the same, and setting it
// would cost a copy for no difference.
fn void fill_field(Element* body, String id, String value) @local
{
	if (value.len == 0) return;
	if (try Element* field = body.find_id(id))
	{
		field.widget_as(TextField).set_text(field, value);
	}
}

<*
 The line at the top: which file is about to be written, and what the cell is.

 A widget rather than a `Label` because the text is composed per opening and a
 Label borrows what it is given for the life of its element — the composed
 string would have to be parked on the AppState to outlive the build. This reads
 the index on every paint instead, which is also what makes it right after a
 rescan.
*>
struct AssetSettingsHead (Widget)
{
	Vec2 size;
}

fn Vec2 AssetSettingsHead.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ constraints.max.x, ASSET_SETTINGS_HEAD_H });
}

fn void AssetSettingsHead.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	AssetEntry* entry = app.settings_entry();
	if (!entry) return;

	String line = string::tformat("%s in %s", entry.kind.label(), file_stem(entry.file));
	painter.text({ 0, 0 }, elide(elem, line, elem.size.x, ASSET_SETTINGS_TEXT), {
		.size = ASSET_SETTINGS_TEXT,
		.color = TEXT_DIM,
	});
}

// ---------------------------------------------------------------------------
// What the buttons do

fn void asset_settings_cancelled(Ui* ui) @private
{
	close_asset_settings(ui);
}

<*
 Write the three answers into the file.

 Copied out before the panel closes, because closing releases the subtree the
 fields live in and each value is a view into one of their buffers — the rule
 `export_confirmed` follows for the same reason.

 The panel closes *before* the write rather than after it: the write rereads
 every library, and a panel still on screen would be showing an index that no
 longer exists.
*>
fn void asset_settings_saved(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.settings_asset < 0) return;
	usz which = (usz)app.settings_asset;

	String name = field_text(ui, ASSET_SETTINGS_NAME_ID).copy(mem);
	defer name.free(mem);
	String plan = field_text(ui, ASSET_SETTINGS_PLAN_ID).copy(mem);
	defer plan.free(mem);
	String tags = field_text(ui, ASSET_SETTINGS_TAGS_ID).copy(mem);
	defer tags.free(mem);

	close_asset_settings(ui);

	app.retag_asset(which, name, plan, tags);
	app.refresh_ui();
}

<*
 Delete the animation this panel is open on from the loaded model.

 Closes first, for `asset_settings_saved`'s reason: the re-save `delete_model_animation`
 does rereads the index this panel is drawn from. The position is read before the
 close, which resets it.
*>
fn void asset_settings_delete(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.settings_asset < 0) return;
	usz which = (usz)app.settings_asset;

	close_asset_settings(ui);

	app.delete_model_animation(which);
	app.refresh_ui();
}

fn void close_asset_settings(Ui* ui) @local
{
	ui.inherit(AppState)!!.settings_asset = -1;
	set_dialog_open(ui, ASSET_SETTINGS_DIALOG_ID, false);
}

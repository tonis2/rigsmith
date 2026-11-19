<*
 The cutscene sheet's menus: a path piece's, an actor header's and a strip's on a
 right-click, the "+ Add actor" list, and one small dialog that renames a path or
 an actor's row. Each menu works on what the right-click picked: the path, the
 actor pieces go to, or the strip.
*>
module crig;

import cui;
import cui::widgets;
import std::collections::list;
import std::math;

const String CUT_PATH_MENU_ID = "cut-path-menu";
const String CUT_PATH_RENAME_ID = "cut-path-rename";
const String CUT_PATH_DRAW_ID = "cut-path-draw";
const String CUT_PATH_WALK_ID = "cut-path-walk";
const String CUT_PATH_DELETE_ID = "cut-path-delete";
const String CUT_ACTOR_MENU_ID = "cut-actor-menu";
const String CUT_ACTOR_OWN_FILE_ID = "cut-actor-own-file";
const String CUT_ACTOR_GROUND_ID = "cut-actor-ground";
const String CUT_ACTOR_RENAME_ID = "cut-actor-rename";
const String CUT_ACTOR_REMOVE_ID = "cut-actor-remove";
const String CUT_STRIP_MENU_ID = "cut-strip-menu";
const String CUT_STRIP_EDIT_ID = "cut-strip-menu-edit";
const String CUT_STRIP_DELETE_ID = "cut-strip-menu-delete";
const String CUT_ADD_ACTOR_MENU_ID = "cut-add-actor-menu";
const String CUT_ACTOR_LIST_ID = "cut-actor-list";
const String CUT_RENAME_DIALOG_ID = "cut-rename-dialog";
const String CUT_RENAME_OK_ID = "cut-rename-ok";
const String CUT_ROW_ID = "cut-row";
const String CUT_PATH_NAME_ID = "cut-path-name";

const float CUT_RENAME_W = 240.0;

enum CutPick : char
{
	FROM_FILE,   // a character file, loaded as an actor
	LEVEL_SLOT,  // a level character no actor stands in for: take it
	CHARACTER,   // a character that is no actor yet: make it one
	ACTOR,       // an actor of the scene this cutscene lacks: add it
}

<* What a row of the Add actor list stands for. *>
struct CutActorPickRow
{
	CutPick kind;
	usz character;
	String node; // borrowed from the level
}

enum CutRenaming : char
{
	PATH, // the picked path
	ROW,  // the focused character's row
}

// What the rename dialog renames, set as it opens.
CutRenaming cut_renaming @private;

<* Open popup `id` with its top-left at `at`. *>
fn void cut_open_popup(Ui* ui, String id, Vec2 at)
{
	Element*? found = ui.find_id(id);
	if (catch found) return;
	Dialog* menu = found.widget_as(Dialog);
	menu.at = at;
	menu.placed = true;
	menu.set_open(found, true);
}

// A popup menu's width, from its rows' labels.
fn float cut_menu_width(Ui* ui, String[] labels) @local
{
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : labels) width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	return width;
}

macro void @cut_menu_row(String label, OnClick on_select, String id, float width, bool disabled = false, bool danger = false)
{
	@node((PopupMenuItem) { .item = { .label = label, .on_select = on_select, .disabled = disabled },
		.style = danger ? DANGER_MENU_STYLE : VIEW_MENU_STYLE, .width = width }).with_id(id);
}

macro void @cut_menu_separator(float width)
{
	@node((MenuSeparator) { .style = VIEW_MENU_STYLE.resolved(), .size = { width, widgets::SEPARATOR_H } });
}

// ---------------------------------------------------------------------------
// A path piece's menu

fn void cut_path_menu_closed(Ui* ui) @local => set_dialog_open(ui, CUT_PATH_MENU_ID, false);

fn void cut_path_rename_clicked(Ui* ui)
{
	cut_path_menu_closed(ui);
	if (ui.inherit(AppState)!!.cut_picked_path()) open_cut_rename(ui, PATH);
}

fn void cut_path_draw_clicked(Ui* ui)
{
	cut_path_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	if (!app.begin_cut_path_drawing()) app.@notice("add a cutscene first");
	app.refresh_ui();
}

fn void cut_path_walk_clicked(Ui* ui)
{
	cut_path_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	sz actor = app.cut_target_actor();
	WalkPath* path = app.cut_picked_path();
	if (!path) return;
	if (actor < 0)
	{
		app.@notice("click an actor first: that actor walks");
	}
	else if (path.points.len < 2)
	{
		app.@notice("%s needs two knots to walk", path.name);
	}
	else if (app.walk_cut_path((usz)actor, app.cut_path_pick - 1) >= 0)
	{
		CutStrip* s = app.cut_selected_strip();
		if (s) app.@notice("%s walks %s · %.1f m in %.2f s at %.2fx", app.cutscene().actors[actor].row, path.name, path.length, s.end - s.start, s.speed);
	}
	app.refresh_ui();
}

fn void cut_path_delete_clicked(Ui* ui)
{
	cut_path_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	WalkPath* path = app.cut_picked_path();
	if (!path) return;
	String name = path.name.tcopy();
	(void)app.delete_cut_path(app.cut_path_pick - 1);
	app.@notice("deleted %s · Ctrl+Z brings it back", name);
	app.refresh_ui();
}

fn Element* build_cut_path_menu(Ui* ui)
{
	bool none = !ui.inherit(AppState)!!.cut_picked_path();
	float width = cut_menu_width(ui, { "Rename…", "Draw more", "Walk here", "Delete" });
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@cut_menu_row("Rename…", &cut_path_rename_clicked, CUT_PATH_RENAME_ID, width, none);
			@cut_menu_row("Draw more", &cut_path_draw_clicked, CUT_PATH_DRAW_ID, width, none);
			@cut_menu_row("Walk here", &cut_path_walk_clicked, CUT_PATH_WALK_ID, width, none);
			@cut_menu_separator(width);
			@cut_menu_row("Delete", &cut_path_delete_clicked, CUT_PATH_DELETE_ID, width, none, danger: true);
		};
	};
}

// ---------------------------------------------------------------------------
// An actor header's menu

// The character playing the actor pieces go to, or null.
fn Character* cut_target_character(AppState* app) @local
{
	Cutscene* c = app.cutscene();
	sz actor = app.cut_target_actor();
	if (!c || actor < 0) return null;
	sz holder = app.actor_character(c.actors[actor].row);
	return holder >= 0 ? app.character((usz)holder) : null;
}

// The menu closed and its actor's character focused, for a handler that works on the focus.
fn bool cut_focus_target(Ui* ui) @local
{
	set_dialog_open(ui, CUT_ACTOR_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* c = app.cutscene();
	sz actor = app.cut_target_actor();
	if (!c || actor < 0) return false;
	sz holder = app.actor_character(c.actors[actor].row);
	if (holder < 0)
	{
		app.@notice("no character plays %s", c.actors[actor].row);
		return false;
	}
	return (usz)holder == app.active || app.focus_character((usz)holder);
}

fn void cut_actor_menu_own_file(Ui* ui)
{
	if (cut_focus_target(ui)) cut_actor_own_file_clicked(ui);
}

fn void cut_actor_menu_ground(Ui* ui)
{
	if (cut_focus_target(ui)) cut_actor_ground_clicked(ui);
}

fn void cut_actor_menu_rename(Ui* ui)
{
	if (cut_focus_target(ui)) open_cut_rename(ui, ROW);
}

fn void cut_actor_menu_remove(Ui* ui)
{
	if (cut_focus_target(ui)) cut_actor_remove_clicked(ui);
}

fn void cut_actor_file_clicked(Ui* ui) => open_file_dialog(ui, FilePurpose.ADD_ACTOR);

fn void cut_actor_own_file_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.level_read) return;
	if (app.cut_pending_node.len > 0) alloc::free(mem, app.cut_pending_node.ptr);
	app.cut_pending_node = app.level_node.copy(mem);
	open_file_dialog(ui, FilePurpose.TAKE_LEVEL_ACTOR);
}

fn void cut_actor_ground_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.drop_actor_to_ground(app.active)) app.@notice("there is no level ground under %s", app.label());
	app.refresh_ui();
}

fn void cut_actor_remove_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String row = app.actor_row.tcopy();
	if (!app.remove_actor(app.active))
	{
		app.@notice("the last character stays: a scene always has one");
	}
	else
	{
		app.@notice("removed %s", row);
	}
	app.refresh_ui();
}

fn Element* build_cut_actor_menu(Ui* ui)
{
	Character* c = cut_target_character(ui.inherit(AppState)!!);
	bool none = c == null;
	bool from_level = c && c.level_read;
	float width = cut_menu_width(ui, { "Use its own file…", "Drop onto ground", "Rename row…", "Remove" });
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			// Read from the level, it can have its own file stand in for the level's copy.
			if (from_level) @cut_menu_row("Use its own file…", &cut_actor_menu_own_file, CUT_ACTOR_OWN_FILE_ID, width);
			@cut_menu_row("Drop onto ground", &cut_actor_menu_ground, CUT_ACTOR_GROUND_ID, width, none || from_level);
			@cut_menu_row("Rename row…", &cut_actor_menu_rename, CUT_ACTOR_RENAME_ID, width, none);
			@cut_menu_separator(width);
			@cut_menu_row("Remove", &cut_actor_menu_remove, CUT_ACTOR_REMOVE_ID, width, none, danger: true);
		};
	};
}

// ---------------------------------------------------------------------------
// A strip's menu

fn void cut_strip_menu_edit(Ui* ui)
{
	set_dialog_open(ui, CUT_STRIP_MENU_ID, false);
	(void)edit_picked_one_off(ui);
}

fn void cut_strip_menu_delete(Ui* ui)
{
	set_dialog_open(ui, CUT_STRIP_MENU_ID, false);
	(void)delete_picked_cut_strip(ui);
}

fn Element* build_cut_strip_menu(Ui* ui)
{
	CutStrip* s = ui.inherit(AppState)!!.cut_selected_strip();
	bool one_off = s && s.kind != TURN && s.one_off;
	float width = cut_menu_width(ui, { "Edit one-off", "Delete" });
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@cut_menu_row("Edit one-off", &cut_strip_menu_edit, CUT_STRIP_EDIT_ID, width, !one_off);
			@cut_menu_separator(width);
			@cut_menu_row("Delete", &cut_strip_menu_delete, CUT_STRIP_DELETE_ID, width, !s, danger: true);
		};
	};
}

// ---------------------------------------------------------------------------
// The Add actor list

<* Open the Add actor list at `at`: from a file, the level's free characters, and characters that are no actor here yet. *>
fn void cut_open_actor_list(Ui* ui, Vec2 at) => cut_open_popup(ui, CUT_ADD_ACTOR_MENU_ID, at);

fn void cut_add_actor_clicked(Ui* ui) => cut_open_actor_list(ui, ui.input.mouse);

<* The Add actor list's rows and what each stands for. *>
fn void CutChoiceList.actor_rows(&self, AppState* app, List{TreeRow}* rows)
{
	List{CutActorPickRow} picks;
	picks.init(mem);
	defer picks.free();
	rows.push(((TreeRow) { .label = "From a file…", .trailing = "a .glb" }).owned());
	picks.push({ .kind = FROM_FILE });
	@pool()
	{
		foreach (lc : level_characters(tmem))
		{
			if (app.level_node_character(lc.name) >= 0) continue;
			rows.push(((TreeRow) { .label = lc.name, .trailing = "in the level · take" }).owned());
			picks.push({ .kind = LEVEL_SLOT, .node = lc.name });
		}
	};
	Cutscene* cutscene = app.cutscene();
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (c.actor_row.len > 0)
		{
			if (!cutscene || cutscene.actor_by_row(c.actor_row) >= 0) continue;
			rows.push(((TreeRow) { .label = c.actor_row, .trailing = "an actor · add it here" }).owned());
			picks.push({ .kind = ACTOR, .character = i });
			continue;
		}
		if (!c.has_mesh() && !c.level_read) continue;
		rows.push(((TreeRow) { .label = c.label(), .trailing = "no actor · make one" }).owned());
		picks.push({ .kind = CHARACTER, .character = i });
	}
	self.picks = picks.to_array(mem);
}

// The actor character `character` plays becomes the one pieces go to.
fn void cut_target_character_index(AppState* app, sz character) @local
{
	Cutscene* c = app.cutscene();
	if (!c || character < 0 || (usz)character >= app.character_count()) return;
	int at = c.actor_by_row(app.character((usz)character).actor_row);
	if (at < 0) return;
	app.cut_lane_actor = (usz)at + 1;
	app.clear_cut_selection();
}

fn void cut_actor_list_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	Element*? found = ui.find_id(CUT_ACTOR_LIST_ID);
	if (catch found) return;
	CutChoiceList* list;
	for (Element* e = found; e; e = e.parent)
	{
		if (!e.is_widget(CutChoiceList)) continue;
		list = e.widget_as(CutChoiceList);
		break;
	}
	if (!list || index >= list.picks.len) return;
	CutActorPickRow pick = list.picks[index];
	String node = pick.node.tcopy();
	set_dialog_open(ui, CUT_ADD_ACTOR_MENU_ID, false);
	switch (pick.kind)
	{
		case FROM_FILE:
			cut_actor_file_clicked(ui);
			return;
		case LEVEL_SLOT:
			// Read straight from the level; Use its own file puts a file in its place.
			if (app.take_level_actor(node)) cut_target_character_index(app, app.level_node_character(node));
		case CHARACTER:
			if (app.make_actor(pick.character)) cut_target_character_index(app, (sz)pick.character);
		case ACTOR:
			String row = app.character(pick.character).actor_row.tcopy();
			if (app.make_actor(pick.character, row)) cut_target_character_index(app, (sz)pick.character);
	}
	app.refresh_ui();
}

// ---------------------------------------------------------------------------
// The rename dialog

<* Open the rename dialog for the picked path or the focused character's row. *>
fn void open_cut_rename(Ui* ui, CutRenaming what)
{
	cut_renaming = what;
	Element*? found = ui.find_id(CUT_RENAME_DIALOG_ID);
	if (catch found) return;
	Dialog* dialog = found.widget_as(Dialog);
	dialog.title = what == ROW ? "Rename row" : "Rename path";
	dialog.set_open(found, true);
}

fn void close_cut_rename(Ui* ui) => set_dialog_open(ui, CUT_RENAME_DIALOG_ID, false);

fn void cut_rename_confirmed(Ui* ui)
{
	if (cut_renaming == ROW)
	{
		cut_row_submitted(ui, field_text(ui, CUT_ROW_ID));
	}
	else
	{
		cut_path_name_submitted(ui, field_text(ui, CUT_PATH_NAME_ID));
	}
}

fn void cut_row_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	if (text.trim().len == 0)
	{
		app.@notice("an actor needs a row, the name the game finds it by");
	}
	else if (app.make_actor(app.active, text))
	{
		close_cut_rename(ui);
	}
	refresh_animations_view(ui);
	app.refresh_ui();
}

fn void cut_path_name_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.cut_path_pick == 0 || !app.rename_cut_path(app.cut_path_pick - 1, text))
	{
		app.@notice("a path needs a name");
	}
	else
	{
		close_cut_rename(ui);
	}
	refresh_animations_view(ui);
	app.refresh_ui();
}

fn Element* build_cut_rename_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	bool row = cut_renaming == ROW;
	WalkPath* path = app.cut_picked_path();
	String now = row ? app.actor_row : path ? path.name : "";
	String id = row ? CUT_ROW_ID : CUT_PATH_NAME_ID;
	String tip = row ? "Row — the name the game finds this actor by; Return renames it in every cutscene"
		: "Path name — Return renames it; the moves on it keep walking it";
	Element* body = @subtree(ui)
	{
		@tree((Column) { .gap = 10 })
		{
			@tree(widgets::tip(tip))
			{
				@node((TextField) { .width = CUT_RENAME_W, .style = TEXT_FIELD_STYLE,
					.on_submit = row ? &cut_row_submitted : &cut_path_name_submitted }).with_id(id);
			};
			@tree((Row) { .gap = 10 })
			{
				@node(accent_button("Rename", &cut_rename_confirmed)).with_id(CUT_RENAME_OK_ID);
				@node(panel_button("Cancel", &close_cut_rename));
			};
		};
	};
	focus_field(body, id, now);
	return body;
}

<* The sheet's menus, the Add actor list and the rename dialog, among the window's dialogs. *>
fn void cutscene_menu_dialogs()
{
	@node((Dialog) { .body = &build_cut_path_menu, .style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
		.popup_insets = { 0, 5, 0, 5 } }).with_id(CUT_PATH_MENU_ID);
	@node((Dialog) { .body = &build_cut_actor_menu, .style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
		.popup_insets = { 0, 5, 0, 5 } }).with_id(CUT_ACTOR_MENU_ID);
	@node((Dialog) { .body = &build_cut_strip_menu, .style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
		.popup_insets = { 0, 5, 0, 5 } }).with_id(CUT_STRIP_MENU_ID);
	@node((Dialog) { .body = &build_cut_actor_list, .style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
		.popup_insets = { 0, 5, 0, 5 } }).with_id(CUT_ADD_ACTOR_MENU_ID);
	@node((Dialog) { .title = "Rename", .body = &build_cut_rename_body, .style = DIALOG_STYLE, .modal = true }).with_id(CUT_RENAME_DIALOG_ID);
}

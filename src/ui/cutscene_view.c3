<*
 The Cutscene tab: the scene's cutscenes on the left with their actors and what is
 wrong with them, the transport and the timeline on the right.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::collections::list;

const String CUT_PANEL_ID = "cut-panel";
const String CUT_LIST_ID = "cut-list";
const String CUT_ADD_ID = "cut-add";
const String CUT_DELETE_ID = "cut-delete";
const String CUT_EXPORT_ID = "cut-export";
const String CUT_NAME_ID = "cut-name";
const String CUT_DURATION_ID = "cut-duration";
const String CUT_FPS_ID = "cut-fps";
const String CUT_ACTORS_ID = "cut-actors";
const String CUT_ACTOR_FILE_ID = "cut-actor-file";
const String CUT_ACTOR_GROUND_ID = "cut-actor-ground";
const String CUT_ACTOR_REMOVE_ID = "cut-actor-remove";
const String CUT_ACTOR_OWN_FILE_ID = "cut-actor-own-file";
const String CUT_ROW_ID = "cut-row";
const String CUT_PROBLEMS_ID = "cut-problems";
const String CUT_PREVIEW_ID = "cut-preview";
const String CUT_PLAY_ID = "cut-play";
const String CUT_TIME_ID = "cut-time";
const String CUT_PATHS_ID = "cut-paths";
const String CUT_PATH_ADD_ID = "cut-path-add";
const String CUT_PATH_DRAW_ID = "cut-path-draw";
const String CUT_PATH_WALK_ID = "cut-path-walk";
const String CUT_PATH_DELETE_ID = "cut-path-delete";
const String CUT_PATH_NAME_ID = "cut-path-name";
const String CUT_NEW_ONE_OFF_ID = "cut-new-one-off";
const String CUT_BACK_ID = "cut-back";

const float CUT_SIDE_W = 260.0;
const float CUT_PAD = 8.0;
const float CUT_GAP = 6.0;
const float CUT_FIELD_W = 70.0;
const Color CUT_PROBLEM_INK = { 1.0, 0.62, 0.15, 1.0 };

enum CutPick : char
{
	ACTOR,       // a scene actor: focus its character
	LEVEL_SLOT,  // a level character no actor stands in for: take it
	CHARACTER,   // a character that is no actor yet: make it one
}

<* What a row of the actors list stands for. *>
struct CutActorPickRow
{
	CutPick kind;
	usz character;
	String node; // borrowed from the level
}

<* What decides the panel's shape; a change rebuilds it. *>
struct CutPanelShape
{
	uint revision;
	usz cutscenes;
	usz active;
	usz characters;
	uint focus;
	bool preview;
	bool playing;
	bool level;
	usz level_characters;
	uint links;
	uint selected;
	CutGroundPick pick;
	usz path;
	bool one_off;
}

fn CutPanelShape cut_panel_shape(AppState* app) @private
{
	CutPanelShape out = {
		.revision = app.cut_revision,
		.cutscenes = (usz)app.cutscenes.len(),
		.active = app.cut_active,
		.characters = app.character_count(),
		.focus = app.focus.id,
		.preview = app.cut_preview,
		.playing = app.cut_playing,
		.level = level_shown(),
		.selected = app.cut_selected,
		.pick = app.cut_pick,
		.path = app.cut_path_pick,
		.one_off = app.one_off_open(),
	};
	uint hash = 2166136261u;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		hash = (hash ^ c.id) * 16777619u;
		hash = (hash ^ (uint)c.doc.animations.len()) * 16777619u;
		foreach (ch : c.actor_row) hash = (hash ^ ch) * 16777619u;
		foreach (ch : c.level_node) hash = (hash ^ ch) * 16777619u;
	}
	out.links = hash;
	@pool()
	{
		out.level_characters = level_characters(tmem).len;
	};
	return out;
}

fn bool cut_shape_differs(CutPanelShape a, CutPanelShape b) @private
{
	return a.revision != b.revision || a.cutscenes != b.cutscenes || a.active != b.active || a.characters != b.characters
		|| a.focus != b.focus || a.preview != b.preview || a.playing != b.playing || a.level != b.level
		|| a.level_characters != b.level_characters || a.links != b.links || a.selected != b.selected || a.pick != b.pick
		|| a.path != b.path || a.one_off != b.one_off;
}

<* The two sides: the list column at a fixed width, the timeline filling the rest. *>
struct CutDock (Widget)
{
	float unused;
}

fn Vec2 CutDock.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float w = constraints.max.x;
	float h = constraints.max.y >= cui::UNBOUNDED ? ANIMATION_DOCK_H : constraints.max.y;
	if (elem.children.len() < 2) return constraints.constrain({ w, h });
	float side = math::min(CUT_SIDE_W, w * 0.45f);
	elem.layout_child(0, cui::tight({ side, h }));
	elem.layout_child(1, cui::tight({ math::max(w - side - 1.0f, 0.0f), h }));
	elem.place_child(0, { 0, 0 });
	elem.place_child(1, { side + 1.0f, 0 });
	return constraints.constrain({ w, h });
}

fn void CutDock.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (elem.children.len() < 2) return;
	painter.rect({ elem.children[1].offset.x - 1.0f, 0 }, { 1.0f, elem.size.y }, { .color = PANEL_BORDER });
}

<* The transport over the timeline, the timeline taking what is left. *>
struct CutStage (Widget)
{
	float unused;
}

fn Vec2 CutStage.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = constraints.max;
	if (elem.children.len() < 2) return own;
	Vec2 bar = elem.layout_child(0, cui::loose({ own.x - 2.0f * CUT_PAD, own.y }));
	float top = bar.y + 2.0f * CUT_PAD;
	elem.place_child(0, { CUT_PAD, CUT_PAD });
	elem.layout_child(1, cui::tight({ own.x, math::max(own.y - top, 0.0f) }));
	elem.place_child(1, { 0, top });
	return own;
}

struct CutscenePanel (Widget)
{
	CutPanelShape shown;
	TreeRow[] cut_rows;
	TreeRow[] actor_rows;
	TreeRow[] path_rows;
	CutActorPickRow[] picks;
	// The problems the labels show, owned for as long as they do.
	String[] problems;
	usz actor_selected;
	bool counted;
	// What the strip card's choosers offer.
	CutCardChoices card;
}

fn void CutscenePanel.release(&self)
{
	self.card.free();
	widgets::free_tree_rows(&self.cut_rows);
	widgets::free_tree_rows(&self.actor_rows);
	widgets::free_tree_rows(&self.path_rows);
	if (self.picks.len > 0) alloc::free(mem, self.picks);
	self.picks = {};
	free_names(mem, self.problems);
	self.problems = {};
}

fn void CutscenePanel.mount(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState) ?? null;
	if (!app || self.counted) return;
	app.cut_panes++;
	self.counted = true;
}

fn void CutscenePanel.unmount(&self, Element* elem) @dynamic
{
	self.release();
	AppState* app = elem.inherit(AppState) ?? null;
	if (app && self.counted) app.cut_panes--;
	self.counted = false;
}

// The list rows: each cutscene with its length.
fn void CutscenePanel.list_rows(&self, AppState* app)
{
	if (app.cutscenes.len() == 0) return;
	self.cut_rows = alloc::new_array(mem, TreeRow, app.cutscenes.len());
	foreach (usz i, &c : app.cutscenes)
	{
		self.cut_rows[i] = ((TreeRow) { .label = c.name, .trailing = string::tformat("%.1f s", c.duration) }).owned();
	}
}

// The paths list: each path of the active cutscene with its length and knots.
fn void CutscenePanel.path_list(&self, Cutscene* cutscene)
{
	if (!cutscene || cutscene.paths.len == 0) return;
	self.path_rows = alloc::new_array(mem, TreeRow, cutscene.paths.len);
	foreach (usz i, &p : cutscene.paths)
	{
		String label = p.name.len > 0 ? p.name : string::tformat("path %d", i + 1);
		self.path_rows[i] = ((TreeRow) { .label = label, .trailing = string::tformat("%.1f m · %d knots", p.length, p.knots.len) }).owned();
	}
}

// The actors list: the scene's actors, then the level characters free to take, then characters that are no actor.
fn void CutscenePanel.actor_list(&self, AppState* app)
{
	List{TreeRow} rows;
	rows.init(mem);
	defer rows.free();
	List{CutActorPickRow} picks;
	picks.init(mem);
	defer picks.free();
	self.actor_selected = ~(usz)0;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (c.actor_row.len == 0) continue;
		if (i == app.active) self.actor_selected = (usz)rows.len();
		String from = c.level_read ? string::tformat("%s · from the level", c.level_node)
			: c.level_node.len > 0 ? string::tformat("for %s", c.level_node) : c.label();
		rows.push(((TreeRow) { .label = c.actor_row, .trailing = from }).owned());
		picks.push({ .kind = ACTOR, .character = i });
	}
	@pool()
	{
		foreach (lc : level_characters(tmem))
		{
			if (app.level_node_character(lc.name) >= 0) continue;
			rows.push(((TreeRow) { .label = lc.name, .trailing = "in the level · take" }).owned());
			picks.push({ .kind = LEVEL_SLOT, .node = lc.name });
		}
	};
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (c.actor_row.len > 0 || (!c.has_mesh() && !c.level_read)) continue;
		rows.push(((TreeRow) { .label = c.label(), .trailing = "no actor · make one" }).owned());
		picks.push({ .kind = CHARACTER, .character = i });
	}
	if (rows.len() > 0)
	{
		self.actor_rows = rows.to_array(mem);
		self.picks = picks.to_array(mem);
	}
}

fn Element* CutscenePanel.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.shown = cut_panel_shape(app);
	self.release();
	self.list_rows(app);
	self.actor_list(app);
	Cutscene* cutscene = app.cutscene();
	self.path_list(cutscene);
	WalkPath* picked_path = app.cut_picked_path();
	Element* path_field;
	bool actor = app.actor_row.len > 0;
	self.problems = app.cutscene_problem_texts(mem);
	String[] problems = self.problems;
	Element* name_field;
	Element* duration_field;
	Element* fps_field;
	Element* row_field;
	CutCardFields card_fields;
	CutStrip* picked = app.cut_selected_strip();
	usz picked_actor;
	usz picked_strip;
	if (picked) (void)app.cut_selection(&picked_actor, &picked_strip);

	Element* body = @subtree(elem.ui)
	{
		@tree((CutDock) { })
		{
			@tree((Scroll) { })
			{
				@tree((Padding) { .insets = widgets::insets_all(CUT_PAD) })
				{
					@tree((Column) { .gap = CUT_GAP })
					{
						@tree((Row) { .gap = 2.0f, .cross_align = CENTER })
						{
							@card_icon(ADD_GLYPH, "New cutscene — a cutscene of its own, holding every actor of the scene", &cut_add_clicked).with_id(CUT_ADD_ID);
							if (cutscene)
							{
								@card_icon(DELETE_GLYPH, "Delete cutscene — this one goes; Ctrl+Z brings it back", &cut_delete_clicked).with_id(CUT_DELETE_ID);
								@card_icon(EXPORT_GLYPH, "Export cutscene — write this cutscene as a .cutscene.glb for the game", &cut_export_clicked, COMMIT).with_id(CUT_EXPORT_ID);
							}
						};
						if (cutscene)
						{
							@node((Tree) { .rows = self.cut_rows, .selected = app.cut_active, .on_select = &cut_list_chosen,
								.style = TREE_STYLE }).with_id(CUT_LIST_ID);
							@tree(widgets::tip("Name — Return renames this cutscene; it names the exported file too"))
							{
								name_field = @node((TextField) { .width = CUT_SIDE_W - 2.0f * CUT_PAD, .style = TEXT_FIELD_STYLE,
									.on_submit = &cut_name_submitted }).with_id(CUT_NAME_ID);
							};
							@tree((Row) { .gap = CUT_GAP, .cross_align = CENTER })
							{
								@tree(widgets::tip("Length in seconds — Return sets how long the cutscene runs"))
								{
									duration_field = @node((TextField) { .width = CUT_FIELD_W, .style = TEXT_FIELD_STYLE,
										.on_submit = &cut_duration_submitted }).with_id(CUT_DURATION_ID);
								};
								@node((Label) { .text = "s", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
								@tree(widgets::tip("Frames per second — the rate the timeline snaps to and tools author at"))
								{
									fps_field = @node((TextField) { .width = CUT_FIELD_W, .style = TEXT_FIELD_STYLE,
										.on_submit = &cut_fps_submitted }).with_id(CUT_FPS_ID);
								};
								@node((Label) { .text = "fps", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
							};
						}
						else
						{
							@node((Label) { .text = "No cutscene yet", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
						}

						@tree((Row) { .gap = 2.0f, .cross_align = CENTER })
						{
							@card_icon(ACTOR_GLYPH, "Add actor — load a character file as an actor, dropped onto the level's ground", &cut_actor_file_clicked).with_id(CUT_ACTOR_FILE_ID);
							if (actor && app.level_read)
							{
								@card_icon(OWN_FILE_GLYPH, "Use its own file — the character's own .glb stands in for the level's copy, keeping the row",
									&cut_actor_own_file_clicked).with_id(CUT_ACTOR_OWN_FILE_ID);
							}
							if (actor && !app.level_read)
							{
								@card_icon(GROUND_GLYPH, "Drop onto the ground — stand this actor on the level's ground under it", &cut_actor_ground_clicked).with_id(CUT_ACTOR_GROUND_ID);
							}
							if (actor)
							{
								@card_icon(REMOVE_ACTOR_GLYPH, "Remove actor — out of every cutscene and the scene; a level copy it stood in for shows again", &cut_actor_remove_clicked).with_id(CUT_ACTOR_REMOVE_ID);
							}
						};
						if (self.actor_rows.len > 0)
						{
							@node((Tree) { .rows = self.actor_rows, .selected = self.actor_selected, .on_select = &cut_actor_chosen,
								.style = TREE_STYLE }).with_id(CUT_ACTORS_ID);
						}
						if (actor)
						{
							@tree(widgets::tip("Row — the name the game finds this actor by; Return renames it in every cutscene"))
							{
								row_field = @node((TextField) { .width = CUT_SIDE_W - 2.0f * CUT_PAD, .style = TEXT_FIELD_STYLE,
									.on_submit = &cut_row_submitted }).with_id(CUT_ROW_ID);
							};
						}
						if (cutscene)
						{
							@tree((Row) { .gap = 2.0f, .cross_align = CENTER })
							{
								@card_icon(ADD_PATH_GLYPH, "New path — a walk path of this cutscene, picked so Draw extends it", &cut_path_add_clicked).with_id(CUT_PATH_ADD_ID);
								@card_icon(PEN_GLYPH, "Draw — click the ground knot by knot to extend the picked path; Enter or Esc ends it",
									&cut_path_draw_clicked, app.cut_pick == PATH_KNOT ? LIT : PLAIN).with_id(CUT_PATH_DRAW_ID);
								if (picked_path)
								{
									@card_icon(WALK_HERE_GLYPH, "Walk here — the actor walks this path from the playhead, as long as its walk clip's ground speed takes",
										&cut_path_walk_clicked, COMMIT).with_id(CUT_PATH_WALK_ID);
									@card_icon(DELETE_GLYPH, "Delete path — the moves on it lose their path; Ctrl+Z brings it back", &cut_path_delete_clicked).with_id(CUT_PATH_DELETE_ID);
								}
							};
							if (self.path_rows.len > 0)
							{
								@node((Tree) { .rows = self.path_rows, .selected = app.cut_path_pick > 0 ? app.cut_path_pick - 1 : ~(usz)0,
									.on_select = &cut_path_chosen, .style = TREE_STYLE }).with_id(CUT_PATHS_ID);
							}
							if (picked_path)
							{
								@tree(widgets::tip("Path name — Return renames it; its knots show in the 3D view to drag, put in on its line, or Delete"))
								{
									path_field = @node((TextField) { .width = CUT_SIDE_W - 2.0f * CUT_PAD, .style = TEXT_FIELD_STYLE,
										.on_submit = &cut_path_name_submitted }).with_id(CUT_PATH_NAME_ID);
								};
							}
							Element* listed = @tree((Column) { .gap = 2.0f })
							{
								if (problems.len == 0)
								{
									@node((Label) { .text = "No problems", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
								}
								foreach (text : problems)
								{
									@node((Label) { .text = text, .size = ANIM_TEXT_SIZE, .color = CUT_PROBLEM_INK, .overflow = WRAP });
								}
							};
							listed.with_id(CUT_PROBLEMS_ID);
						}
					};
				};
			};
			@tree((CutStage) { })
			{
				@tree((Column) { .gap = CUT_GAP })
				{
					@tree((Row) { .gap = 2.0f, .cross_align = CENTER })
					{
						if (app.one_off_open())
						{
							@card_icon(BACK_GLYPH, "Back to cutscene — end editing the one-off; its edits are one step Ctrl+Z takes back",
								&cut_back_clicked, COMMIT).with_id(CUT_BACK_ID);
						}
						@card_icon(PREVIEW_GLYPH, "Preview — stand every actor where the cutscene has it at the playhead; off puts each back as it was",
							&cut_preview_clicked, app.cut_preview ? LIT : PLAIN).with_id(CUT_PREVIEW_ID);
						@card_icon(app.cut_playing ? PAUSE_GLYPH : RUN_GLYPH, "Play / pause the cutscene from the playhead",
							&cut_play_clicked).with_id(CUT_PLAY_ID);
						@node((CutTimeLabel) { }).with_id(CUT_TIME_ID);
						if (cutscene && cutscene.actors.len > 0)
						{
							@card_icon(ADD_PLAY_GLYPH, "Add play — one of the actor's clips at the playhead, on its What lane",
								&cut_add_play_clicked).with_id(CUT_ADD_PLAY_ID);
							@card_icon(ADD_TURN_GLYPH, "Add turn — at the playhead, facing another actor or a point on the ground",
								&cut_add_turn_clicked, app.cut_pick == NEW_TURN ? LIT : PLAIN).with_id(CUT_ADD_TURN_ID);
							@card_icon(NEW_ONE_OFF_GLYPH, "New one-off — a clip of this cutscene alone, 2 s at the playhead, to pose with the character's own tools",
								&cut_new_one_off_clicked).with_id(CUT_NEW_ONE_OFF_ID);
						}
					};
					// The card's row is kept when nothing is picked, so a pick never moves the timeline.
					if (picked)
					{
						build_cut_card(&self.card, app, cutscene, picked_actor, picked, &card_fields);
					}
					else if (cutscene)
					{
						@node((Stack) { .size = { 1.0f, CARD_ICON_VIEW } });
					}
				};
				@node((CutsceneTimeline) { }).with_id(CUT_TIMELINE_ID);
			};
		};
	};
	if (name_field && cutscene) name_field.widget_as(TextField).set_text(name_field, cutscene.name);
	if (duration_field && cutscene) duration_field.widget_as(TextField).set_text(duration_field, string::tformat("%.2f", cutscene.duration));
	if (fps_field && cutscene) fps_field.widget_as(TextField).set_text(fps_field, string::tformat("%g", cutscene.fps));
	if (row_field) row_field.widget_as(TextField).set_text(row_field, app.actor_row);
	if (path_field && picked_path) path_field.widget_as(TextField).set_text(path_field, picked_path.name);
	if (picked) fill_cut_card(&card_fields, picked);
	return body;
}

fn void CutscenePanel.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	CutPanelShape now = cut_panel_shape(app);
	if (!cut_shape_differs(now, self.shown)) return;
	// A press on the timeline holds its widget; the card catches up on the release.
	if (cut_timeline_busy(elem.ui)) return;
	// A field being typed in keeps its text until it is submitted.
	if (elem.ui.focused && elem.ui.focused.is_widget(TextField) && now.revision == self.shown.revision) return;
	elem.request_build();
}

<* Delete or Backspace deletes the picked strip, wherever in the tab the last click was; Enter edits its one-off. *>
fn bool CutscenePanel.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;
	if (event.key == Key.RETURN || event.key == Key.KP_RETURN) return edit_picked_one_off(elem.ui);
	if (event.key != Key.DELETE && event.key != Key.BACKSPACE) return false;
	return delete_picked_cut_strip(elem.ui);
}

fn Vec2 CutscenePanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.max;
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

fn Element* build_cutscene_view(Ui* ui)
{
	return @subtree(ui)
	{
		@node((CutscenePanel) { }).with_id(CUT_PANEL_ID);
	};
}

<* The playhead's time over the cutscene's length, kept current while it plays. *>
struct CutTimeLabel (Widget)
{
	char[48] said; // what `describe` answers, kept while it is read
	float painted; // the time last drawn, so a move from anywhere repaints it
}

fn Vec2 CutTimeLabel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ 120.0f, CARD_ICON_VIEW });
}

fn void CutTimeLabel.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return;
	self.painted = app.cut_time;
	String text = string::tformat("%.2f / %.2f s", app.cut_time, cutscene.duration);
	painter.text({ 6.0f, (elem.size.y - ANIM_TEXT_SIZE) * 0.5f }, text, { .size = ANIM_TEXT_SIZE, .color = TEXT });
}

fn void CutTimeLabel.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.inherit(AppState)!!.cut_time != self.painted) elem.request_paint();
}

fn void CutTimeLabel.describe(&self, Element* elem, Description* out) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (cutscene) out.text = string::bformat(&self.said, "%.2f / %.2f s", app.cut_time, cutscene.duration);
}

// Every pane showing the tab, after a change from outside it.
fn void refresh_cutscene_view(Ui* ui)
{
	ui.@each_id(CUT_PANEL_ID; panel) { panel.request_build(); };
}

// ---------------------------------------------------------------------------
// What the controls do

fn void cut_add_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz made = app.add_cutscene();
	app.@notice("added %s · Ctrl+Z takes it back", app.cutscenes.get_ref((sz)made).name);
	app.refresh_ui();
}

fn void cut_delete_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return;
	String name = cutscene.name.tcopy();
	(void)app.delete_cutscene(app.cut_active);
	app.@notice("deleted %s · Ctrl+Z brings it back", name);
	app.refresh_ui();
}

fn void cut_export_clicked(Ui* ui) => open_file_dialog(ui, FilePurpose.EXPORT_CUTSCENE);

fn void cut_list_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.select_cutscene(index);
	app.refresh_ui();
}

fn void cut_name_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.rename_cutscene(app.cut_active, text)) app.@notice("a cutscene needs a name");
	app.refresh_ui();
}

fn void cut_timing_submitted(Ui* ui, String text, bool rate) @private
{
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return;
	double? value = text.trim().to_double();
	bool done = false;
	if (try value)
	{
		done = rate ? app.set_cutscene_timing(app.cut_active, cutscene.duration, (float)value)
			: app.set_cutscene_timing(app.cut_active, (float)value, cutscene.fps);
	}
	if (!done) app.@notice(rate ? "the frame rate is a number above 0" : "the length is seconds above 0");
	refresh_cutscene_view(ui);
	app.refresh_ui();
}

fn void cut_duration_submitted(Ui* ui, String text) => cut_timing_submitted(ui, text, false);
fn void cut_fps_submitted(Ui* ui, String text) => cut_timing_submitted(ui, text, true);

fn void cut_actor_file_clicked(Ui* ui) => open_file_dialog(ui, FilePurpose.ADD_ACTOR);

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

fn void cut_actor_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	Element*? found = ui.find_id(CUT_PANEL_ID);
	if (catch found) return;
	CutscenePanel* panel = found.widget_as(CutscenePanel);
	if (index >= panel.picks.len) return;
	CutActorPickRow pick = panel.picks[index];
	// The list's choice is the actor adds go to, until a lane is pressed.
	app.cut_lane_actor = 0;
	switch (pick.kind)
	{
		case ACTOR:
			(void)app.focus_character(pick.character);
		case CHARACTER:
			(void)app.make_actor(pick.character);
		case LEVEL_SLOT:
			// Read straight from the level; Use its own file puts a file in its place.
			(void)app.take_level_actor(pick.node.tcopy());
	}
	app.refresh_ui();
}

fn void cut_actor_own_file_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.level_read) return;
	if (app.cut_pending_node.len > 0) alloc::free(mem, app.cut_pending_node.ptr);
	app.cut_pending_node = app.level_node.copy(mem);
	open_file_dialog(ui, FilePurpose.TAKE_LEVEL_ACTOR);
}

fn void cut_row_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	if (text.trim().len == 0)
	{
		app.@notice("an actor needs a row, the name the game finds it by");
	}
	else
	{
		(void)app.make_actor(app.active, text);
	}
	refresh_cutscene_view(ui);
	app.refresh_ui();
}

fn void cut_path_add_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz made = app.add_cut_path();
	if (made >= 0) app.@notice("added %s · Draw puts its knots on the ground", app.cutscene().paths[made].name);
	app.refresh_ui();
}

fn void cut_path_draw_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.cut_pick == PATH_KNOT)
	{
		app.cancel_cut_pick();
	}
	else if (!app.begin_cut_path_drawing())
	{
		app.@notice("add a cutscene first");
	}
	refresh_cutscene_view(ui);
	app.refresh_ui();
}

fn void cut_path_walk_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz actor = app.cut_target_actor();
	WalkPath* path = app.cut_picked_path();
	if (!path) return;
	if (actor < 0)
	{
		app.@notice("click an actor's lane first: that actor walks");
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
	AppState* app = ui.inherit(AppState)!!;
	WalkPath* path = app.cut_picked_path();
	if (!path) return;
	String name = path.name.tcopy();
	(void)app.delete_cut_path(app.cut_path_pick - 1);
	app.@notice("deleted %s · Ctrl+Z brings it back", name);
	app.refresh_ui();
}

fn void cut_path_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	// The picked row again unpicks it.
	(void)app.pick_cut_path(app.cut_path_pick == index + 1 ? -1 : (sz)index);
	app.refresh_ui();
}

fn void cut_path_name_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.cut_path_pick == 0 || !app.rename_cut_path(app.cut_path_pick - 1, text)) app.@notice("a path needs a name");
	refresh_cutscene_view(ui);
	app.refresh_ui();
}

fn void cut_back_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.back_to_cutscene();
	app.refresh_ui();
}

fn void cut_new_one_off_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz actor = app.cut_target_actor();
	if (!app.cutscene())
	{
		app.@notice("add a cutscene first");
	}
	else if (actor < 0)
	{
		app.@notice("click an actor's lane first: that actor gets the one-off");
	}
	else if (app.new_cut_one_off((usz)actor) >= 0)
	{
		CutStrip* s = app.cut_selected_strip();
		if (s) app.@notice("added the one-off %s · double-click or Enter edits it", s.clip);
	}
	app.refresh_ui();
}

fn void cut_preview_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.set_cutscene_preview(!app.cut_preview)) app.@notice("add a cutscene to preview");
	app.refresh_ui();
}

fn void cut_play_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.play_cutscene(!app.cut_playing)) app.@notice("add a cutscene to play");
	app.refresh_ui();
}

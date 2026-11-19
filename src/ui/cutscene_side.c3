<*
 The cutscene's right column: the picked strip's card, or with none picked the
 cutscene's name, length, fps, Delete, Export and problems.
*>
module crig;

import cui;
import cui::widgets;

const String CUT_SIDE_ID = "cut-side";
const String CUT_DELETE_ID = "cut-delete";
const String CUT_EXPORT_ID = "cut-export";
const String CUT_NAME_ID = "cut-name";
const String CUT_DURATION_ID = "cut-duration";
const String CUT_FPS_ID = "cut-fps";
const String CUT_PROBLEMS_ID = "cut-problems";

// Shared with the card.
const float CUT_SIDE_W = 260.0;
const float CUT_PAD = 8.0;
const float CUT_GAP = 6.0;
const float CUT_FIELD_W = 70.0;
const Color CUT_PROBLEM_INK = { 1.0, 0.62, 0.15, 1.0 };

// What the actors, the problems and the clip choices read from the characters.
fn uint cut_cast_links(AppState* app) @private
{
	uint hash = 2166136261u;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		hash = (hash ^ c.id) * 16777619u;
		hash = (hash ^ (uint)c.doc.animations.len()) * 16777619u;
		foreach (ch : c.actor_row) hash = (hash ^ ch) * 16777619u;
		foreach (ch : c.level_node) hash = (hash ^ ch) * 16777619u;
	}
	return hash;
}

// Whether `elem` waits to rebuild: a held timeline press would lose its widget, a field typed in its text.
fn bool cut_rebuild_waits(Element* elem, bool same_revision) @private
{
	// A press on the timeline holds its widget; the rebuild catches up on the release.
	if (cut_timeline_busy(elem.ui)) return true;
	// A field of its own being typed in keeps its text until it is submitted.
	Element* focused = elem.ui.focused;
	if (!same_revision || !focused || !focused.is_widget(TextField)) return false;
	for (Element* e = focused; e != null; e = e.parent)
	{
		if (e == elem) return true;
	}
	return false;
}

<* What decides the side's content; a change rebuilds it. *>
struct CutSideShape
{
	uint revision;
	usz cutscenes;
	usz active;
	uint selected;
	CutGroundPick pick;
	bool one_off;
	usz characters;
	uint links;
	bool level;
}

fn CutSideShape cut_side_shape(AppState* app) @private
{
	return {
		.revision = app.cut_revision,
		.cutscenes = (usz)app.cutscenes.len(),
		.active = app.cut_active,
		.selected = app.cut_selected,
		.pick = app.cut_pick,
		.one_off = app.one_off_open(),
		.characters = app.character_count(),
		.links = cut_cast_links(app),
		.level = level_shown(),
	};
}

fn bool CutSideShape.differs(self, CutSideShape other)
{
	return self.revision != other.revision || self.cutscenes != other.cutscenes || self.active != other.active
		|| self.selected != other.selected || self.pick != other.pick || self.one_off != other.one_off
		|| self.characters != other.characters || self.links != other.links || self.level != other.level;
}

struct CutSide (Widget)
{
	CutSideShape shown;
	// What the strip card's choosers offer.
	CutCardChoices card;
	// The problems the labels show, owned for as long as they do.
	String[] problems;
}

fn void CutSide.release(&self)
{
	self.card.free();
	free_names(mem, self.problems);
	self.problems = {};
}

fn void CutSide.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* CutSide.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.shown = cut_side_shape(app);
	self.release();
	Cutscene* cutscene = app.cutscene();
	CutStrip* picked = app.cut_selected_strip();
	usz picked_actor;
	usz picked_strip;
	if (picked) (void)app.cut_selection(&picked_actor, &picked_strip);
	if (!picked) self.problems = app.cutscene_problem_texts(mem);
	String[] problems = self.problems;
	CutCardFields card_fields;
	Element* name_field;
	Element* duration_field;
	Element* fps_field;

	Element* body = @subtree(elem.ui)
	{
		@tree((Scroll) { })
		{
			@tree((Padding) { .insets = widgets::insets_all(CUT_PAD) })
			{
				@tree((Column) { .gap = CUT_GAP })
				{
					if (picked)
					{
						build_cut_card(&self.card, app, cutscene, picked_actor, picked_strip, &card_fields);
					}
					else if (cutscene)
					{
						@tree((Row) { .gap = 2.0f, .cross_align = CENTER })
						{
							@card_icon(DELETE_GLYPH, "Delete cutscene — this one goes; Ctrl+Z brings it back", &cut_delete_clicked).with_id(CUT_DELETE_ID);
							@card_icon(EXPORT_GLYPH, "Export — open the Export panel on this cutscene, to write its .cutscene.glb for the game", &cut_export_clicked, COMMIT).with_id(CUT_EXPORT_ID);
						};
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
	};
	if (name_field) name_field.widget_as(TextField).set_text(name_field, cutscene.name);
	if (duration_field) duration_field.widget_as(TextField).set_text(duration_field, string::tformat("%.2f", cutscene.duration));
	if (fps_field) fps_field.widget_as(TextField).set_text(fps_field, string::tformat("%g", cutscene.fps));
	if (picked) fill_cut_card(&card_fields, picked);
	return body;
}

fn void CutSide.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	CutSideShape now = cut_side_shape(app);
	if (!now.differs(self.shown)) return;
	if (cut_rebuild_waits(elem, now.revision == self.shown.revision)) return;
	elem.request_build();
}

// ---------------------------------------------------------------------------
// What the cutscene's own controls do

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

fn void cut_export_clicked(Ui* ui) => open_export_for(ui, CUTSCENE);

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
	refresh_animations_view(ui);
	app.refresh_ui();
}

fn void cut_duration_submitted(Ui* ui, String text) => cut_timing_submitted(ui, text, false);
fn void cut_fps_submitted(Ui* ui, String text) => cut_timing_submitted(ui, text, true);

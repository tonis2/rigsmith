<*
 The cutscene's strip card and its choice lists. The card shows the picked strip's
 times and what it plays, walks or faces; each change is one undo step. A move
 shows its clip only when it carries one of its own; a play over a move is a walk,
 with the ground speed its speed follows while Fit is on. The Turn piece lays a
 turn at the playhead for the actor pieces go to (AppState.cut_target_actor),
 from a list of the other actors; "+ Add actor" lists what can become an actor.
*>
module crig;

import cui;
import cui::widgets;
import std::collections::list;
import std::math;

const String CUT_TURN_MENU_ID = "cut-turn-menu";
const String CUT_TURN_LIST_ID = "cut-turn-list";
const String CUT_CARD_ID = "cut-strip-card";
const String CUT_CARD_START_ID = "cut-strip-start";
const String CUT_CARD_END_ID = "cut-strip-end";
const String CUT_CARD_CLIP_ID = "cut-strip-clip";
const String CUT_CARD_LOOP_ID = "cut-strip-loop";
const String CUT_CARD_SPEED_ID = "cut-strip-speed";
const String CUT_CARD_FADE_ID = "cut-strip-fade";
const String CUT_CARD_OFFSET_ID = "cut-strip-offset";
const String CUT_CARD_EASE_ID = "cut-strip-ease";
const String CUT_CARD_FACE_ID = "cut-strip-face";
const String CUT_CARD_PATH_ID = "cut-strip-path";
const String CUT_CARD_GROUND_ID = "cut-strip-ground";
const String CUT_CARD_FIT_ID = "cut-strip-fit";
const String CUT_CARD_TARGET_ID = "cut-strip-target";
const String CUT_CARD_PICK_ID = "cut-strip-pick";
const String CUT_CARD_DELETE_ID = "cut-strip-delete";
const String CUT_CARD_ONE_OFF_ID = "cut-one-off-name";
const String CUT_CARD_EDIT_ID = "cut-one-off-edit";
const String CUT_CARD_DROP_ID = "cut-one-off-delete";
// What marks the actor's one-offs among its character's clips in the choosers.
const String CUT_ONE_OFF_MARK = " · one-off";

const float CUT_NUMBER_W = 52.0;
// Between a field and the label or unit kept beside it.
const float CUT_PAIR_GAP = 3.0;
const float CUT_CHOOSER_W = 110.0;
const float CUT_MENU_W = 200.0;
// The widest a choice list grows to read its rows whole, and what its popup puts around it.
const float CUT_MENU_MOST_W = 420.0;
const float CUT_LIST_INSETS = 12.0;
const usz CUT_MENU_ROWS = 12;
const String CUT_NO_CHOICE = "(none)";
const String CUT_POINT_CHOICE = "point";

// Select borrows its options after the build returns.
String[4] cut_ease_options = { "linear", "ease in", "ease out", "ease in-out" };

<* What the card's choosers offer, owned by CutSide for as long as they show. *>
struct CutCardChoices
{
	String[] clips;   // a move's start with CUT_NO_CHOICE; the actor's one-offs come last, marked
	String[] one_offs; // their names, the last rows of `clips`
	String[] paths;   // CUT_NO_CHOICE, then the cutscene's paths
	String[] targets; // the other actors' rows, then CUT_POINT_CHOICE
}

fn void CutCardChoices.free(&self)
{
	free_names(mem, self.clips);
	free_names(mem, self.one_offs);
	free_names(mem, self.paths);
	free_names(mem, self.targets);
	*self = {};
}

<* The one-off a clip row names, or "" for one of the character's clips. *>
fn String CutCardChoices.one_off_at(&self, usz row)
{
	usz first = self.clips.len - self.one_offs.len;
	return row >= first && row < self.clips.len ? self.one_offs[row - first] : "";
}

<* The card's number fields, to be filled once the build is done. *>
struct CutCardFields
{
	Element* start;
	Element* end;
	Element* speed;
	Element* fade;
	Element* offset;
	Element* ground;
	float ground_speed; // what the ground field shows, 0 for not known
	Element* one_off;
	String one_off_name; // borrowed from the strip
}

fn String[] cut_owned(List{String}* names) @local
{
	if (names.len() == 0) return {};
	String[] out = alloc::new_array(mem, String, (sz)names.len());
	foreach (usz i, name : *names) out[i] = name.copy(mem);
	return out;
}

// The actors a turn of `actor` can face: every other one, by index.
fn usz[] cut_other_actors(Allocator allocator, Cutscene* cutscene, usz actor) @local
{
	List{usz} out;
	out.init(allocator);
	foreach (usz i, &who : cutscene.actors) if (i != actor) out.push(i);
	return out.array_view();
}

<* The choosers for strip `s` of `actor`, and the row each shows picked. *>
fn void CutCardChoices.fill(&self, AppState* app, Cutscene* cutscene, usz actor, CutStrip* s, usz* clip_row, usz* path_row, usz* target_row)
{
	self.free();
	@pool()
	{
		List{String} names;
		names.tinit();
		if (s.kind == MOVE) names.push(CUT_NO_CHOICE);
		CutCast[] cast = app.cut_cast(cutscene, tmem);
		*clip_row = 0;
		bool listed = s.clip.len == 0;
		foreach (clip : cast[actor].clips)
		{
			if (clip == s.clip)
			{
				*clip_row = (usz)names.len();
				listed = true;
			}
			names.push(clip);
		}
		// A clip the file lacks still shows; the problems list names it.
		if (!listed && !s.one_off)
		{
			*clip_row = (usz)names.len();
			names.push(s.clip);
		}
		List{String} own;
		own.tinit();
		foreach (&one : cutscene.one_offs)
		{
			if (one.row != cutscene.actors[actor].row) continue;
			if (s.one_off && one.clip.name == s.clip) *clip_row = (usz)names.len();
			names.push(string::tformat("%s%s", one.clip.name, CUT_ONE_OFF_MARK));
			own.push(one.clip.name);
		}
		// One that is gone still shows; the problems list names it.
		if (s.one_off && cutscene.one_off_index(cutscene.actors[actor].row, s.clip) < 0)
		{
			*clip_row = (usz)names.len();
			names.push(string::tformat("%s%s", s.clip, CUT_ONE_OFF_MARK));
			own.push(s.clip);
		}
		self.clips = cut_owned(&names);
		self.one_offs = cut_owned(&own);

		names.clear();
		names.push(CUT_NO_CHOICE);
		foreach (usz i, &walk : cutscene.paths) names.push(walk.name.len > 0 ? walk.name : string::tformat("path %d", i + 1));
		*path_row = s.path >= 0 && s.path < cutscene.paths.len ? (usz)s.path + 1 : 0;
		self.paths = cut_owned(&names);

		names.clear();
		*target_row = ~(usz)0;
		foreach (other : cut_other_actors(tmem, cutscene, actor))
		{
			if (cutscene.actors[other].row == s.target_row) *target_row = (usz)names.len();
			names.push(cutscene.actors[other].row);
		}
		if (s.target_row.len > 0 && *target_row == ~(usz)0)
		{
			*target_row = (usz)names.len();
			names.push(s.target_row);
		}
		if (s.target_row.len == 0) *target_row = (usz)names.len();
		names.push(CUT_POINT_CHOICE);
		self.targets = cut_owned(&names);
	};
}

fn String cut_kind_word(CutStripKind kind) @local
{
	switch (kind)
	{
		case MOVE: return "Move";
		case TURN: return "Turn";
		case PLAY: return "Play";
	}
}

macro Element* @cut_number(String tip, OnText on_submit, String id)
{
	Element* field;
	@tree(widgets::tip(tip))
	{
		field = @node((TextField) { .width = CUT_NUMBER_W, .style = TEXT_FIELD_STYLE, .on_submit = on_submit }).with_id(id);
	};
	return field;
}

macro void @cut_unit(String text)
{
	@node((Label) { .text = text, .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
}

macro void @cut_chooser(String tip, String[] options, usz selected, OnIndex on_change, String id)
{
	@tree(widgets::tip(tip))
	{
		@node((Select) { .options = options, .selected = selected, .width = CUT_CHOOSER_W, .on_change = on_change,
			.style = VIEW_MENU_STYLE }).with_id(id);
	};
}

// The ground speed field, for the clip of a walk or of a move that carries its own.
fn void cut_ground_field(AppState* app, usz actor, CutStrip* s, CutCardFields* fields) @local
{
	String tip = s.kind == PLAY
		? "Ground speed — m/s the clip's feet cover the ground at, which the walk's speed follows while Fit is on; typed, it holds for this strip; empty takes the clip's"
		: "Ground speed — m/s the clip's feet cover the ground at, which the speed follows; typed, it holds for this move; empty takes the clip's";
	@tree((Row) { .gap = CUT_PAIR_GAP, .cross_align = CENTER })
	{
		fields.ground = @cut_number(tip, &cut_card_ground_submitted, CUT_CARD_GROUND_ID);
		@cut_unit("m/s");
	};
	fields.ground_speed = app.cut_ground_speed(actor, s);
}

<*
 The picked strip's card, inside CutSide's build: its times, then what it plays,
 walks or faces. The number fields are left for `fill_cut_card` to fill.

 @param [in] cutscene
 @param [&out] fields
 @require actor < cutscene.actors.len && strip < cutscene.actors[actor].strips.len : "No such strip"
*>
fn void build_cut_card(CutCardChoices* choices, AppState* app, Cutscene* cutscene, usz actor, usz strip, CutCardFields* fields)
{
	CutStrip* s = &cutscene.actors[actor].strips[strip];
	usz clip_row;
	usz path_row;
	usz target_row;
	choices.fill(app, cutscene, actor, s, &clip_row, &path_row, &target_row);
	// A move the UI lays plays nothing; one that carries a clip of its own still shows it, to change or take off.
	bool plays = s.kind == PLAY || (s.kind == MOVE && s.clip.len > 0);
	bool paired = cut_paired_move(cutscene.actors[actor].strips, strip, cutscene.paths) >= 0;
	Element* card = @tree((Wrap) { .gap_x = CUT_GAP, .gap_y = 4.0f, .cross_align = CENTER })
	{
		@node((Label) { .text = cut_kind_word(s.kind), .size = ANIM_TEXT_SIZE, .color = TEXT });
		// Each field keeps its label or unit beside it, so a narrow column wraps them together.
		@tree((Row) { .gap = CUT_PAIR_GAP, .cross_align = CENTER })
		{
			fields.start = @cut_number("Start — seconds; Return sets it", &cut_card_start_submitted, CUT_CARD_START_ID);
			@cut_unit("–");
			fields.end = @cut_number("End — seconds; Return sets it", &cut_card_end_submitted, CUT_CARD_END_ID);
			@cut_unit("s");
		};
		if (plays)
		{
			@cut_chooser(s.kind == MOVE ? "Clip — the move's own clip, or none to take it off; a walk is a play strip over the move" : "Clip — what the strip plays; a one-off is this cutscene's own",
				choices.clips, clip_row, &cut_card_clip_chosen, CUT_CARD_CLIP_ID);
			if (s.one_off)
			{
				@tree(widgets::tip("One-off name — Return renames it and every strip that plays it"))
				{
					fields.one_off = @node((TextField) { .width = CUT_CHOOSER_W, .style = TEXT_FIELD_STYLE,
						.on_submit = &cut_card_one_off_named }).with_id(CUT_CARD_ONE_OFF_ID);
				};
				fields.one_off_name = s.clip;
				@card_icon(EDIT_ONE_OFF_GLYPH, "Edit one-off — pose it with the character's own tools where the cutscene stands it (double-click the strip, or Enter)",
					&cut_card_edit_clicked, app.one_off_open() ? LIT : PLAIN).with_id(CUT_CARD_EDIT_ID);
				@card_icon(DELETE_ONE_OFF_GLYPH, "Delete one-off — the clip and every strip that plays it; Ctrl+Z brings them back",
					&cut_card_drop_clicked).with_id(CUT_CARD_DROP_ID);
			}
			@card_icon(LOOP_GLYPH, "Loop — repeat the clip; off holds its last frame", &cut_card_loop_clicked,
				s.loop ? LIT : PLAIN).with_id(CUT_CARD_LOOP_ID);
			@tree((Row) { .gap = CUT_PAIR_GAP, .cross_align = CENTER })
			{
				fields.speed = @cut_number(s.kind == PLAY ? "Speed — the clip's playback rate; typed, it holds and Fit turns off" : "Speed — the clip's playback rate",
					&cut_card_speed_submitted, CUT_CARD_SPEED_ID);
				@cut_unit("×");
			};
			if (s.kind == PLAY && !s.one_off)
			{
				@card_icon(FIT_GLYPH, "Fit — over a move, the walk plays at the pace that keeps its feet on the path; typing a speed turns it off",
					&cut_card_fit_clicked, s.speed_held ? PLAIN : LIT).with_id(CUT_CARD_FIT_ID);
			}
			if (paired) cut_ground_field(app, actor, s, fields);
			@tree((Row) { .gap = CUT_PAIR_GAP, .cross_align = CENTER })
			{
				@cut_unit("fade");
				fields.fade = @cut_number("Fade — seconds to blend in from what played before", &cut_card_fade_submitted, CUT_CARD_FADE_ID);
			};
			@tree((Row) { .gap = CUT_PAIR_GAP, .cross_align = CENTER })
			{
				@cut_unit("offset");
				fields.offset = @cut_number("Offset — the clip time, in seconds, the strip starts at", &cut_card_offset_submitted, CUT_CARD_OFFSET_ID);
			};
		}
		if (s.kind != PLAY)
		{
			@cut_chooser(s.kind == MOVE ? "Ease — how the walk covers its path over the strip" : "Ease — how the turn covers its angle over the strip",
				cut_ease_options[..], (usz)s.ease.ordinal, &cut_card_ease_chosen, CUT_CARD_EASE_ID);
		}
		if (s.kind == MOVE)
		{
			@card_icon(FACE_PATH_GLYPH, "Face along the path — off keeps the facing the actor had", &cut_card_face_clicked,
				s.turn ? LIT : PLAIN).with_id(CUT_CARD_FACE_ID);
			@cut_chooser("Path — the walk path this move follows", choices.paths, path_row, &cut_card_path_chosen, CUT_CARD_PATH_ID);
			if (s.clip.len > 0) cut_ground_field(app, actor, s, fields);
		}
		if (s.kind == TURN)
		{
			@cut_chooser("Faces — another actor where it stands when the turn starts, or a point", choices.targets,
				target_row, &cut_card_target_chosen, CUT_CARD_TARGET_ID);
			@card_icon(PICK_POINT_GLYPH, "Pick the point — click the level's ground the turn should face; Esc gives it up",
				&cut_card_pick_clicked, app.cut_pick == TURN_TARGET ? LIT : PLAIN).with_id(CUT_CARD_PICK_ID);
		}
		@card_icon(DELETE_GLYPH, "Delete strip — Delete or Backspace too; Ctrl+Z brings it back", &cut_card_delete_clicked).with_id(CUT_CARD_DELETE_ID);
	};
	card.with_id(CUT_CARD_ID);
}

<* The card's number fields, from strip `s`. *>
fn void fill_cut_card(CutCardFields* fields, CutStrip* s)
{
	if (fields.start) fields.start.widget_as(TextField).set_text(fields.start, string::tformat("%.3f", s.start));
	if (fields.end) fields.end.widget_as(TextField).set_text(fields.end, string::tformat("%.3f", s.end));
	if (fields.speed) fields.speed.widget_as(TextField).set_text(fields.speed, string::tformat("%g", s.speed));
	if (fields.fade) fields.fade.widget_as(TextField).set_text(fields.fade, string::tformat("%g", s.fade));
	if (fields.offset) fields.offset.widget_as(TextField).set_text(fields.offset, string::tformat("%g", s.offset));
	if (fields.ground)
	{
		fields.ground.widget_as(TextField).set_text(fields.ground, fields.ground_speed > 0.0f ? string::tformat("%.3g", fields.ground_speed) : "");
	}
	if (fields.one_off) fields.one_off.widget_as(TextField).set_text(fields.one_off, fields.one_off_name);
}

// ---------------------------------------------------------------------------
// What the card does

<* A copy of the picked strip to change, and where it goes back. *>
struct CutEdit
{
	usz actor;
	usz index;
	CutStrip strip;
}

fn bool cut_edit_begin(AppState* app, CutEdit* edit) @local
{
	if (!app.cut_selection(&edit.actor, &edit.index)) return false;
	edit.strip = app.cutscene().actors[edit.actor].strips[edit.index].copy(mem);
	return true;
}

// Land the edit as one undo step, or drop it with a notice when `why` is set.
fn void cut_edit_land(Ui* ui, AppState* app, CutEdit* edit, String why = "") @local
{
	if (why.len > 0)
	{
		edit.strip.free(mem);
		app.@notice("%s", why);
	}
	else
	{
		(void)app.set_cut_strip(edit.actor, edit.index, edit.strip);
	}
	edit.strip = {};
	// The fields show what the strip holds, also after a refusal.
	refresh_animations_view(ui);
	app.refresh_ui();
}

excuse CUT_NOT_A_NUMBER;

fn float? cut_number_in(String text) @local
{
	double value = text.trim().to_double()!;
	if (!math::is_finite(value)) return CUT_NOT_A_NUMBER~;
	return (float)value;
}

enum CutNumber : char
{
	START,
	END,
	SPEED,
	FADE,
	OFFSET,
}

// Why `value` cannot be the strip's `field`, or "" when it can.
fn String cut_number_refused(CutStrip* s, CutNumber field, float value) @local
{
	switch (field)
	{
		case START: return value < s.end ? "" : "a strip starts before it ends";
		case END: return value > s.start ? "" : "a strip ends after it starts";
		case SPEED: return value > 0.0f ? "" : "the speed is a number above 0";
		case FADE: return value >= 0.0f ? "" : "the fade is seconds, 0 or more";
		case OFFSET: return value >= 0.0f ? "" : "the offset is seconds of the clip, 0 or more";
	}
}

// One number field of the card submitted.
fn void cut_card_number(Ui* ui, String text, CutNumber field) @local
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	float? value = cut_number_in(text);
	String why = "type a number";
	if (try value) why = cut_number_refused(&edit.strip, field, value);
	if (why.len == 0)
	{
		switch (field)
		{
			case START: edit.strip.trim_front(value!!);
			case END: edit.strip.end = value!!;
			case SPEED:
				edit.strip.speed = value!!;
				// A walk's speed typed holds; Fit lets pairing set it again.
				if (edit.strip.kind == PLAY) edit.strip.speed_held = true;
			case FADE: edit.strip.fade = value!!;
			case OFFSET: edit.strip.offset = value!!;
		}
	}
	cut_edit_land(ui, app, &edit, why);
}

fn void cut_card_start_submitted(Ui* ui, String text) => cut_card_number(ui, text, START);
fn void cut_card_end_submitted(Ui* ui, String text) => cut_card_number(ui, text, END);
fn void cut_card_speed_submitted(Ui* ui, String text) => cut_card_number(ui, text, SPEED);
fn void cut_card_fade_submitted(Ui* ui, String text) => cut_card_number(ui, text, FADE);
fn void cut_card_offset_submitted(Ui* ui, String text) => cut_card_number(ui, text, OFFSET);

// The ground speed typed on a walk or a move's own clip: its speed follows; empty goes back to the clip's.
fn void cut_card_ground_submitted(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	String why = "";
	if (text.trim().len == 0)
	{
		edit.strip.ground_speed = 0.0f;
	}
	else if (try value = cut_number_in(text))
	{
		if (value > 0.0f)
		{
			edit.strip.ground_speed = value;
		}
		else
		{
			why = "the ground speed is metres a second above 0";
		}
	}
	else
	{
		why = "type a number, or nothing for the clip's own";
	}
	cut_edit_land(ui, app, &edit, why);
}

// CutSide's choosers, for an index from one of them.
fn CutCardChoices* cut_card_choices(Ui* ui) @local
{
	Element*? found = ui.find_id(CUT_SIDE_ID);
	if (catch found) return null;
	return &found.widget_as(CutSide).card;
}

fn void cut_card_clip_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	CutCardChoices* choices = cut_card_choices(ui);
	CutEdit edit;
	if (!choices || index >= choices.clips.len || !cut_edit_begin(app, &edit)) return;
	String one_off = choices.one_off_at(index);
	String clip = one_off.len > 0 ? one_off : choices.clips[index];
	if (edit.strip.clip.len > 0) alloc::free(mem, edit.strip.clip.ptr);
	bool none = edit.strip.kind == MOVE && index == 0;
	edit.strip.clip = none ? "" : clip.copy(mem);
	edit.strip.one_off = one_off.len > 0;
	// A move's clip taken off takes its typed ground speed with it.
	if (none) edit.strip.ground_speed = 0.0f;
	cut_edit_land(ui, app, &edit);
}

// The picked strip's one-off renamed, and every strip that plays it.
fn void cut_card_one_off_named(Ui* ui, String text)
{
	AppState* app = ui.inherit(AppState)!!;
	CutStrip* s = app.cut_selected_strip();
	usz actor;
	usz strip;
	if (!s || !s.one_off || !app.cut_selection(&actor, &strip)) return;
	String name = s.clip.tcopy();
	if (text.trim().len == 0) app.@notice("a one-off needs a name");
	if (text.trim().len > 0) (void)app.rename_cut_one_off(actor, name, text);
	refresh_animations_view(ui);
	app.refresh_ui();
}

<* Edit the picked strip's one-off, as Enter, a double-click and the card's icon do. *>
fn bool edit_picked_one_off(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz actor;
	usz strip;
	if (cut_timeline_busy(ui) || !app.cut_selection(&actor, &strip)) return false;
	CutStrip* s = &app.cutscene().actors[actor].strips[strip];
	if (s.kind == TURN || !s.one_off) return false;
	(void)app.edit_cut_one_off(actor, strip);
	app.refresh_ui();
	return true;
}

fn void cut_card_edit_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.one_off_open())
	{
		(void)app.back_to_cutscene();
		app.refresh_ui();
		return;
	}
	(void)edit_picked_one_off(ui);
}

fn void cut_card_drop_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	CutStrip* s = app.cut_selected_strip();
	usz actor;
	usz strip;
	if (!s || !s.one_off || !app.cut_selection(&actor, &strip)) return;
	String name = s.clip.tcopy();
	if (app.delete_cut_one_off(actor, name)) app.@notice("deleted the one-off %s and its strips · Ctrl+Z brings them back", name);
	app.refresh_ui();
}

fn void cut_card_loop_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	edit.strip.loop = !edit.strip.loop;
	cut_edit_land(ui, app, &edit);
}

// Fit on: the walk's speed follows its move again; off holds the speed it has.
fn void cut_card_fit_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	if (edit.strip.kind != PLAY)
	{
		edit.strip.free(mem);
		return;
	}
	edit.strip.speed_held = !edit.strip.speed_held;
	cut_edit_land(ui, app, &edit);
}

fn void cut_card_ease_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (index >= cut_ease_options.len || !cut_edit_begin(app, &edit)) return;
	edit.strip.ease = CutEase::from_ordinal(index);
	cut_edit_land(ui, app, &edit);
}

fn void cut_card_face_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	edit.strip.turn = !edit.strip.turn;
	cut_edit_land(ui, app, &edit);
}

fn void cut_card_path_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	edit.strip.path = (int)index - 1;
	cut_edit_land(ui, app, &edit);
}

fn void cut_card_target_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	CutCardChoices* choices = cut_card_choices(ui);
	if (!choices || index >= choices.targets.len) return;
	// The last is a point: it is picked on the ground.
	if (index == choices.targets.len - 1)
	{
		cut_card_pick_clicked(ui);
		return;
	}
	CutEdit edit;
	if (!cut_edit_begin(app, &edit)) return;
	if (edit.strip.target_row.len > 0) alloc::free(mem, edit.strip.target_row.ptr);
	edit.strip.target_row = choices.targets[index].copy(mem);
	cut_edit_land(ui, app, &edit);
}

fn void cut_card_pick_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.cut_pick == TURN_TARGET)
	{
		app.cancel_cut_pick();
	}
	else
	{
		(void)app.begin_cut_pick(TURN_TARGET);
	}
	refresh_animations_view(ui);
	app.refresh_ui();
}

<* Delete the picked strip, as the card's icon and Delete do. *>
fn bool delete_picked_cut_strip(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz actor;
	usz strip;
	if (cut_timeline_busy(ui) || !app.cut_selection(&actor, &strip)) return false;
	(void)app.delete_cut_strip(actor, strip);
	app.@notice("deleted the strip · Ctrl+Z brings it back");
	app.refresh_ui();
	return true;
}

fn void cut_card_delete_clicked(Ui* ui) => (void)delete_picked_cut_strip(ui);

<* Whether the keyboard is with the turn list, after a choice there. *>
fn bool cut_menus_focused(Ui* ui)
{
	for (Element* e = ui.focused; e != null; e = e.parent)
	{
		if (e.has_id(CUT_TURN_MENU_ID)) return true;
	}
	return false;
}

// ---------------------------------------------------------------------------
// The choice lists

enum CutMenu : char
{
	TURN_MENU,  // the other actors, then a point on the ground
	ACTOR_MENU, // what can become an actor of this cutscene (cutscene_menus.c3)
}

<* A popup's rows: built from the app on every open, so each lists what is there now. *>
struct CutChoiceList (Widget)
{
	CutMenu menu;
	TreeRow[] rows;
	CutActorPickRow[] picks; // an ACTOR_MENU's, one per row
}

fn void CutChoiceList.release(&self)
{
	widgets::free_tree_rows(&self.rows);
	if (self.picks.len > 0) alloc::free(mem, self.picks);
	self.picks = {};
}

fn void CutChoiceList.unmount(&self, Element* elem) @dynamic => self.release();

fn Element* CutChoiceList.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.release();
	Cutscene* cutscene = app.cutscene();
	sz actor = app.cut_target_actor();
	List{TreeRow} rows;
	rows.init(mem);
	defer rows.free();
	if (self.menu == ACTOR_MENU)
	{
		self.actor_rows(app, &rows);
	}
	else if (cutscene && actor >= 0)
	{
		@pool()
		{
			foreach (other : cut_other_actors(tmem, cutscene, (usz)actor))
			{
				rows.push(((TreeRow) { .label = cutscene.actors[other].row, .trailing = "actor" }).owned());
			}
		};
		rows.push(((TreeRow) { .label = "A point on the ground", .trailing = "click it" }).owned());
	}
	if (rows.len() > 0) self.rows = rows.to_array(mem);
	String empty = "No cutscene";
	float h = (float)math::min(math::max((usz)self.rows.len, (usz)1), CUT_MENU_ROWS) * TREE_STYLE.resolved().row_height;
	float w = cut_list_width(elem, self.rows);
	String list_id = self.menu == ACTOR_MENU ? CUT_ACTOR_LIST_ID : CUT_TURN_LIST_ID;
	OnIndex chosen = self.menu == ACTOR_MENU ? &cut_actor_list_chosen : &cut_turn_chosen;
	return @subtree(elem.ui)
	{
		@tree((Scroll) { .size = { w, h } })
		{
			if (self.rows.len == 0)
			{
				@node((Label) { .text = empty, .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			}
			else
			{
				@node((Tree) { .rows = self.rows, .selected = ~(usz)0, .on_select = chosen, .style = TREE_STYLE }).with_id(list_id);
			}
		};
	};
}

<*
 How wide a choice list is: its widest row, label and trailing words both whole,
 from CUT_MENU_W up to CUT_MENU_MOST_W and never wider than the screen leaves.

 @param [&in] elem : "The list's element, for its text and its screen"
*>
fn float cut_list_width(Element* elem, TreeRow[] rows)
{
	TreeStyle style = TREE_STYLE.resolved();
	float widest;
	foreach (row : rows)
	{
		float label = elem.ui.text.measure(0, row.label, style.text_size).x;
		float note = row.trailing.len > 0 ? elem.ui.text.measure(0, row.trailing, style.text_size).x + 8.0f : 0.0f;
		// Two pixels over, so rounding never cuts a row that fits.
		widest = math::max(widest, 2.0f * style.padding + label + note + 2.0f);
	}
	// The scroll indicator takes the right edge of a list too long to show whole.
	if (rows.len > CUT_MENU_ROWS) widest += widgets::THUMB_WIDTH + 2.0f * widgets::THUMB_MARGIN;
	float room = elem.media().size.x - 2.0f * widgets::DIALOG_MARGIN - CUT_LIST_INSETS;
	return math::max(math::min(math::clamp(math::ceil(widest), CUT_MENU_W, CUT_MENU_MOST_W), room), 0.0f);
}

fn Element* build_cut_turn_menu(Ui* ui) => ui.@node((CutChoiceList) { .menu = TURN_MENU });
fn Element* build_cut_actor_list(Ui* ui) => ui.@node((CutChoiceList) { .menu = ACTOR_MENU });

// The cutscene's popups and dialogs, among the window's dialogs.
fn void cutscene_dialogs()
{
	@node((Dialog) { .body = &build_cut_turn_menu, .style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
		.popup_insets = { 0, 5, 0, 5 } }).with_id(CUT_TURN_MENU_ID);
	cutscene_menu_dialogs();
}

<* Open choice list `id` at the pointer, for the actor pieces go to. *>
fn void cut_open_menu(Ui* ui, String id)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.cutscene())
	{
		app.@notice("add a cutscene first");
		return;
	}
	if (app.cut_target_actor() < 0)
	{
		app.@notice("click an actor first: that actor gets the strip");
		return;
	}
	cut_open_popup(ui, id, ui.input.mouse);
}

fn void cut_turn_chosen(Ui* ui, usz index)
{
	set_dialog_open(ui, CUT_TURN_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	sz actor = app.cut_target_actor();
	if (!cutscene || actor < 0) return;
	@pool()
	{
		usz[] others = cut_other_actors(tmem, cutscene, (usz)actor);
		if (index < others.len)
		{
			String row = cutscene.actors[others[index]].row.tcopy();
			(void)app.add_cut_turn((usz)actor, row);
		}
		else
		{
			(void)app.begin_cut_pick(NEW_TURN, (usz)actor);
		}
	};
	refresh_animations_view(ui);
	app.refresh_ui();
}

<*
 The Pieces bin beside a cutscene's sheet: + Path, Turn and + One-off as icon cells
 beside its title, then its walk paths and the clips and one-offs of the actor
 pieces go to (cut_target_actor). A click lays one at the playhead; a drop on the
 sheet lays it for the actor under the pointer at the time there
 (CutsceneTimeline.drop). A path clicked is only picked; dropped, it is a move.
 The clips' header ends in a folder cell that opens the Assets pane on his clips.
*>
module crig;

import cui;
import std::collections::list;
import std::math::vector;

enum CutPieceKind : char
{
	NEW_PATH,    // a path drawn on the ground, knot by knot
	PATH,        // one of the cutscene's paths
	TURN,        // a turn toward another actor or a point
	NEW_ONE_OFF, // a new one-off for the actor
	CLIP,        // a clip of the actor's character
	ONE_OFF,     // one of the actor's one-offs
}

<* What a cutscene's bin row lays. *>
struct CutPiece
{
	CutPieceKind kind;
	usz path;    // PATH
	String clip; // CLIP and ONE_OFF; borrowed
}

<* A piece's chip, in the colour of the strip it lays. *>
fn Color cut_piece_color(CutPieceKind kind)
{
	switch (kind)
	{
		case NEW_PATH:
		case PATH:
			return STRIP_GENERATOR;
		case TURN:
			return STRIP_SHARED;
		case NEW_ONE_OFF:
		case ONE_OFF:
			return STRIP_LINKED;
		case CLIP:
			return STRIP_KEYED;
	}
}

fn PieceEntry cut_entry(String label, CutPiece piece, String clip = "", String trailing = "") @local
{
	return { .label = label.copy(mem), .link = clip.len > 0 ? clip.copy(mem) : "", .trailing = trailing.len > 0 ? trailing.copy(mem) : "",
		.for_cut = true, .cut = piece };
}

fn PieceEntry cut_note(String label) @local => { .label = label.copy(mem), .header = true };

const String CUT_TO_ASSETS_TIP = "More clips: drag one from the Assets pane onto a Clip lane";

// An action of the top row: its glyph in a cell, what it does in the tooltip.
fn PieceEntry cut_action(String label, CutPieceKind kind, CardGlyph glyph, String tip) @local
{
	PieceEntry entry = cut_entry(label, { .kind = kind });
	entry.icon = glyph.svg;
	entry.tip = tip;
	return entry;
}

<* The bin's entries for the active cutscene: the three actions, its paths, then the target actor's clips and one-offs. *>
fn void PieceBin.refresh_cut(&self, AppState* app)
{
	self.release();
	PieceEntryList rows;
	rows.init(mem);
	defer rows.free();
	Cutscene* cutscene = app.cutscene();
	sz target = app.cut_target_actor();
	if (!cutscene)
	{
		rows.push(cut_note("Add a cutscene first"));
	}
	else
	{
		rows.push(cut_action("+ Path", NEW_PATH, ADD_PATH_GLYPH,
			"+ Path — draw a new walk path, a click on the ground per knot; drag a path onto a Path lane to walk it"));
		rows.push(cut_action("Turn", TURN, ADD_TURN_GLYPH,
			"Turn — at the playhead, facing another actor or a point on the ground; or drag it onto a Path lane"));
		rows.push(cut_action("+ One-off", NEW_ONE_OFF, NEW_ONE_OFF_GLYPH,
			"+ One-off — a clip of this cutscene alone, at the playhead, to pose with the character's own tools; or drag it onto a Clip lane"));
		if (cutscene.paths.len > 0) rows.push(cut_note("Paths"));
		foreach (usz i, &walk : cutscene.paths)
		{
			String name = walk.name.len > 0 ? walk.name : string::tformat("path %d", i + 1);
			rows.push(cut_entry(name, { .kind = PATH, .path = i }, trailing: string::tformat("%.1f m", walk.length)));
		}
		if (target < 0)
		{
			rows.push(cut_note("Clips"));
			rows.push(cut_note("click an actor"));
		}
		else
		{
			String row = cutscene.actors[target].row;
			PieceEntry clips = cut_note(string::tformat("Clips · %s", row));
			clips.to_assets = true;
			clips.tip = CUT_TO_ASSETS_TIP;
			rows.push(clips);
			usz before = (usz)rows.len();
			@pool()
			{
				CutCast[] cast = app.cut_cast(cutscene, tmem);
				foreach (clip : cast[target].clips) rows.push(cut_entry(clip, { .kind = CLIP }, clip));
			};
			foreach (&one : cutscene.one_offs)
			{
				if (one.row != row) continue;
				rows.push(cut_entry(string::tformat("%s%s", one.clip.name, CUT_ONE_OFF_MARK), { .kind = ONE_OFF }, one.clip.name));
			}
			if ((usz)rows.len() == before) rows.push(cut_note("no clips"));
		}
	}
	self.entries = rows.to_array(mem);
	foreach (&entry : self.entries) if (entry.for_cut) entry.cut.clip = entry.link;
	self.place();
	self.built_revision = app.cut_revision;
	self.built_target = target;
	self.built_links = cut_cast_links(app);
	self.built = true;
}

<* Whether a cutscene's bin lists something no longer there: any cutscene edit, another target, or the characters' clips changed. *>
fn bool PieceBin.cut_stale(&self, AppState* app)
{
	return !self.built || self.built_revision != app.cut_revision || self.built_target != app.cut_target_actor()
		|| self.built_links != cut_cast_links(app);
}

<*
 Lay `piece` as a click on it does: at the playhead, for the actor pieces go to.
 A path is only picked unless `dropped`, when it is a move; Turn opens the turn
 chooser; + Path draws a new path on the ground.
*>
fn void cut_lay_piece(Ui* ui, CutPiece piece, bool dropped)
{
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene)
	{
		app.@notice("add a cutscene first");
		app.refresh_ui();
		return;
	}
	sz actor = app.cut_target_actor();
	bool needs_actor = piece.kind != NEW_PATH && piece.kind != TURN && (piece.kind != PATH || dropped);
	if (needs_actor && actor < 0)
	{
		app.@notice("click an actor first: that actor gets the strip");
		app.refresh_ui();
		return;
	}
	String row = actor >= 0 ? cutscene.actors[actor].row.tcopy() : "";
	switch (piece.kind)
	{
		case NEW_PATH:
			(void)app.pick_cut_path(-1);
			(void)app.begin_cut_path_drawing();
		case PATH:
			if (!dropped)
			{
				(void)app.pick_cut_path((sz)piece.path);
			}
			else if (app.add_cut_move((usz)actor, piece.path) >= 0)
			{
				(void)app.pick_cut_path((sz)piece.path);
			}
			else if (piece.path < app.cutscene().paths.len)
			{
				app.@notice("%s needs two knots to walk", app.cutscene().paths[piece.path].name);
			}
		case TURN:
			cut_open_menu(ui, CUT_TURN_MENU_ID);
		case NEW_ONE_OFF:
			if (app.new_cut_one_off((usz)actor) >= 0)
			{
				CutStrip* s = app.cut_selected_strip();
				if (s) app.@notice("added the one-off %s · double-click or Enter edits it", s.clip);
			}
		case CLIP:
			if (app.add_cut_play((usz)actor, piece.clip) < 0) app.@notice("%s has no clip %s", row, piece.clip);
		case ONE_OFF:
			if (app.add_cut_one_off_play((usz)actor, piece.clip) < 0) app.@notice("%s has no one-off %s", row, piece.clip);
	}
	app.refresh_ui();
}

<* The clip header's browse cell: the target actor's character takes the focus, then the Assets pane shows his clips. *>
fn void cut_browse_clips(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	sz target = app.cut_target_actor();
	if (!cutscene || target < 0) return;
	sz holder = app.actor_character(cutscene.actors[target].row);
	if (holder < 0)
	{
		app.@notice("%s has no character", cutscene.actors[target].row);
		app.refresh_ui();
		return;
	}
	// A refused move of the focus says why itself.
	if ((usz)holder != app.active && !app.focus_character((usz)holder)) return;
	show_assets_group(ui);
}

<* A right press on a piece: a path's menu, the path picked first; the others have none. *>
fn bool cut_piece_menu(Ui* ui, CutPiece piece, Vec2 at)
{
	if (piece.kind != PATH) return false;
	AppState* app = ui.inherit(AppState)!!;
	if (!app.pick_cut_path((sz)piece.path)) return false;
	cut_open_popup(ui, CUT_PATH_MENU_ID, at);
	app.refresh_ui();
	return true;
}

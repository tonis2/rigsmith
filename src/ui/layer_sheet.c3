<*
 The Layers sheet: the sheet's third mode, the clip's layers as strips on tracks.

 	Keys | Curves | Layers

 One row per track, the top track first as in Blender's NLA editor, the Base row
 (the clip's own keys) at the bottom and an empty row on top that makes a new
 track. A layer is a strip from where it starts to where it ends; strips higher
 up play over the ones below.

 - **Drag a strip** to move it in time, or up and down onto another track. A
   placed piece carries what it plays with it; a strip that would overlap another
   on the track it is dropped on goes back.
 - **Drag an edge** to trim it, **Alt-drag its end** to play a placed piece
   faster or slower, **drag a top corner's handle** to fade it in or out.
 - **Click** a strip to make it the active layer (the Layers column shows its
   properties, Key pose keys into it); click the Base row for the clip's own keys.
 - **Right-click** a strip for Edit source, Make local, Mute, Solo, the mask,
   Add to animations… and Delete.

 The Pieces bin on the left lists what can be laid on a track: the generators,
 a fresh keyed layer, the character's other animations — linked, so the strip
 follows every edit made to them — and the layers other animations share. Drag
 one onto a track at the time it should start, or click it to lay it at the
 playhead on a new track. cui has no drag and drop, so the bin holds the drag
 (`AppState.piece_drag`) and, on release, asks the UI what is under the pointer.

 Every gesture lands once, on release, through app/strips.c3: one undo step.
*>
module crig;

import cui;
import cui::widgets;
import std::collections::list;
import std::math;
import std::math::vector;

const String ANIM_LAYER_DECK_ID = "anim-layer-deck";
const String ANIM_PIECE_BIN_ID = "anim-piece-bin";
const String ANIM_LAYER_SHEET_ID = "anim-layer-sheet";
const String ANIM_STRIP_MENU_ID = "anim-strip-menu";
const String ANIM_STRIP_SOURCE_ID = "anim-strip-source";
const String ANIM_STRIP_LOCAL_ID = "anim-strip-local";
const String ANIM_STRIP_MUTE_ID = "anim-strip-mute";
const String ANIM_STRIP_SOLO_ID = "anim-strip-solo";
const String ANIM_STRIP_MASK_ID = "anim-strip-mask";
const String ANIM_STRIP_MASK_CLEAR_ID = "anim-strip-mask-clear";
const String ANIM_STRIP_SHARE_ID = "anim-strip-share";
const String ANIM_STRIP_DELETE_ID = "anim-strip-delete";

const Vec4 LAYER_R4 = { 4.0, 4.0, 4.0, 4.0 };
const Vec4 LAYER_R2 = { 2.0, 2.0, 2.0, 2.0 };
const float PIECE_BIN_W = 150.0;
const float PIECE_ROW_H = 20.0;
const float LAYER_SHEET_LANE_H = 26.0;
const float LAYER_SHEET_GUTTER = 112.0;
// How near an edge, in pixels, a press trims rather than moves.
const float STRIP_EDGE_GRIP = 5.0;
// How near a fade handle a press takes it.
const float STRIP_FADE_GRIP = 6.0;
// How far the pointer moves before a press on a bin row becomes a drag.
const float PIECE_DRAG_SLOP = 4.0;

const Color STRIP_KEYED = { 0.33, 0.52, 0.86, 0.85 };
const Color STRIP_GENERATOR = { 0.34, 0.68, 0.47, 0.85 };
const Color STRIP_LINKED = { 0.60, 0.44, 0.84, 0.85 };
const Color STRIP_SHARED = { 0.28, 0.66, 0.70, 0.85 };
const Color STRIP_BASE = { 0.42, 0.44, 0.50, 0.70 };

<*
 What the Pieces bin is dragging: the piece and its name, and where the pointer
 is in UI coordinates, which the sheet reads to draw where it would land.
*>
struct PieceDrag
{
	bool active;
	Piece piece;
	String label; // owned
	String link;  // owned; the piece's `link` borrows it
	Vec2 at;
}

fn void PieceDrag.clear(&self)
{
	if (self.label.len > 0) self.label.free(mem);
	if (self.link.len > 0) self.link.free(mem);
	*self = {};
}

fn Color strip_color(AnimLayer* layer)
{
	if (layer.source.len > 0) return STRIP_LINKED;
	if (layer.link.len > 0) return STRIP_SHARED;
	return layer.procedural() ? STRIP_GENERATOR : STRIP_KEYED;
}

// ---------------------------------------------------------------------------
// The deck: the bin beside the sheet, both as tall as the slot

struct AnimLayerDeck (Widget)
{
	float unused;
}

fn Vec2 AnimLayerDeck.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float w = constraints.max.x;
	float h = constraints.max.y >= cui::UNBOUNDED ? ANIM_SHEET_H : constraints.max.y;
	if (elem.children.len() < 2) return constraints.constrain({ w, h });
	float bin = math::min(PIECE_BIN_W, w * 0.4f);
	elem.layout_child(0, cui::tight({ bin, h }));
	elem.layout_child(1, cui::tight({ math::max(w - bin - ANIM_GAP, 0.0f), h }));
	elem.place_child(0, { 0, 0 });
	elem.place_child(1, { bin + ANIM_GAP, 0 });
	return constraints.constrain({ w, h });
}

// ---------------------------------------------------------------------------
// The Pieces bin

struct PieceEntry
{
	String label;   // owned
	String link;    // owned, SHARED
	Piece piece;    // its link borrows `link`
	bool header;    // a section title, not a piece
	bool disabled;  // would make the clip play itself
}

struct PieceBin (Widget)
{
	PieceEntry[] entries;
	uint built_revision;
	AnimRef built_for;
	bool built;
	float scroll;
	int lit;      // hovered row, one-based
	int pressed;  // row pressed, one-based
	Vec2 press_at;
}

fn void PieceBin.release(&self)
{
	foreach (&entry : self.entries)
	{
		if (entry.label.len > 0) entry.label.free(mem);
		if (entry.link.len > 0) entry.link.free(mem);
	}
	if (self.entries.len > 0) alloc::free(mem, self.entries);
	self.entries = {};
}

fn void PieceBin.unmount(&self, Element* elem) @dynamic
{
	self.release();
	AppState* app = elem.inherit(AppState) ?? null;
	if (app && app.piece_drag.active) app.piece_drag.clear();
}

fn void PieceBin.refresh(&self, AppState* app)
{
	self.release();
	PieceEntryList rows;
	rows.init(mem);
	defer rows.free();
	rows.push({ .label = "Motion".copy(mem), .header = true });
	rows.push({ .label = "Wave".copy(mem), .piece = { .kind = WAVE } });
	rows.push({ .label = "Noise".copy(mem), .piece = { .kind = NOISE } });
	rows.push({ .label = "Pulse".copy(mem), .piece = { .kind = PULSE } });
	rows.push({ .label = "Keyed".copy(mem), .piece = { .kind = KEYED } });
	AnimTemplate* editing = app.clip(app.editing);
	String here = editing ? editing.name : "";
	bool titled = false;
	foreach (sz i, bound : app.doc.animations.array_view())
	{
		AnimRef ref = app.resolve_bound(i);
		if (!ref.valid() || ref.same(app.editing)) continue;
		AnimTemplate* clip = app.clip(ref);
		if (!clip) continue;
		if (!titled) rows.push({ .label = "Animations".copy(mem), .header = true });
		titled = true;
		bool own = ref.pack == app.authored_pack;
		rows.push({
			.label = clip.name.copy(mem),
			.piece = { .kind = CLIP, .clip = ref },
			.disabled = own && here.len > 0 && app.piece_reaches(clip.name, here),
		});
	}
	// Shared layers other animations hold and this one does not.
	AnimPack* pack = app.authored();
	titled = false;
	if (pack && editing)
	{
		foreach (&clip : pack.clips) foreach (&layer : clip.layers)
		{
			if (layer.link.len == 0 || editing.layer_linked(layer.link) >= 0) continue;
			bool seen;
			foreach (&row : rows.array_view()) if (row.link == layer.link) seen = true;
			if (seen) continue;
			if (!titled) rows.push({ .label = "Shared layers".copy(mem), .header = true });
			titled = true;
			rows.push({ .label = layer.name.copy(mem), .link = layer.link.copy(mem), .piece = { .kind = SHARED } });
		}
	}
	self.entries = rows.to_array(mem);
	foreach (&entry : self.entries) if (entry.piece.kind == SHARED && !entry.header) entry.piece.link = entry.link;
	self.built_revision = app.undo_stack.revision;
	self.built_for = app.editing;
	self.built = true;
}

alias PieceEntryList = List{PieceEntry};

fn bool PieceBin.stale(&self, AppState* app)
{
	return !self.built || self.built_revision != app.undo_stack.revision || !self.built_for.same(app.editing);
}

fn void PieceBin.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (!self.stale(app)) return;
	self.refresh(app);
	elem.request_paint();
}

fn Vec2 PieceBin.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ constraints.max.x, constraints.max.y >= cui::UNBOUNDED ? ANIM_SHEET_H : constraints.max.y });
}

fn int PieceBin.row_at(&self, Element* elem, Vec2 pos)
{
	float y = pos.y + self.scroll - PIECE_ROW_H;
	if (y < 0 || pos.x < 0 || pos.x > elem.size.x) return 0;
	usz row = (usz)(y / PIECE_ROW_H);
	return row < self.entries.len ? (int)row + 1 : 0;
}

fn void PieceBin.paint(&self, Element* elem, Painter* painter) @dynamic
{
	TimelineStyle s = TIMELINE_STYLE;
	// A frame can be painted with no input before it (a screenshot, a script's
	// edit): the rows are brought up to date here too, not only in `update`.
	AppState* app = elem.inherit(AppState)!!;
	if (self.stale(app)) self.refresh(app);
	painter.rect({ 0, 0 }, elem.size, { .color = s.lane, .border_radius = R8 });
	painter.text({ s.pad_x, (PIECE_ROW_H - s.text_size) * 0.5f }, "Pieces",
		{ .size = s.text_size, .color = s.text });
	foreach (usz i, &entry : self.entries)
	{
		float y = PIECE_ROW_H * (float)(i + 1) - self.scroll;
		// Whole rows only: the bin scrolls rather than spilling past its edge.
		if (y < PIECE_ROW_H - 1.0f || y + PIECE_ROW_H > elem.size.y) continue;
		if (entry.header)
		{
			painter.text({ s.pad_x, y + (PIECE_ROW_H - s.text_size) * 0.5f }, entry.label,
				{ .size = s.text_size - 1.0f, .color = s.dim_text });
			continue;
		}
		bool lit = self.lit == (int)i + 1 || self.pressed == (int)i + 1;
		if (lit && !entry.disabled)
		{
			painter.rect({ 2, y }, { elem.size.x - 4, PIECE_ROW_H }, { .color = s.lane_alt, .border_radius = LAYER_R4 });
		}
		Color chip = STRIP_KEYED;
		switch (entry.piece.kind)
		{
			case WAVE: case NOISE: case PULSE: chip = STRIP_GENERATOR;
			case CLIP: chip = STRIP_LINKED;
			case SHARED: chip = STRIP_SHARED;
			default: {}
		}
		if (entry.disabled) chip.a = 0.25f;
		painter.rect({ s.pad_x, y + 5.0f }, { 10.0f, PIECE_ROW_H - 10.0f }, { .color = chip, .border_radius = LAYER_R2 });
		float room = elem.size.x - s.pad_x * 2.0f - 16.0f;
		painter.text({ s.pad_x + 16.0f, y + (PIECE_ROW_H - s.text_size) * 0.5f },
			elide(elem, entry.label, room, s.text_size),
			{ .size = s.text_size, .color = entry.disabled ? s.dim_text : s.text });
	}
}

fn void PieceBin.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

fn bool PieceBin.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	switch (event.kind)
	{
		case SCROLL:
			float most = math::max(0.0f, PIECE_ROW_H * (float)(self.entries.len + 1) - elem.size.y);
			self.scroll = math::clamp(self.scroll - event.scroll * PIECE_ROW_H * 2.0f, 0.0f, most);
			elem.request_paint();
			return true;
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			int row = self.row_at(elem, event.pos);
			if (row == 0) return false;
			PieceEntry* entry = &self.entries[(usz)(row - 1)];
			if (entry.header) return false;
			if (entry.disabled)
			{
				app.@notice("%s plays this animation already, so laying it in would have it play itself", entry.label);
				return true;
			}
			self.pressed = row;
			self.press_at = event.absolute;
			elem.request_paint();
			return true;
		case MOVE:
			if (self.pressed == 0)
			{
				int over = self.row_at(elem, event.pos);
				if (over != self.lit)
				{
					self.lit = over;
					elem.request_paint();
				}
				return false;
			}
			if (!app.piece_drag.active && (event.absolute - self.press_at).length() >= PIECE_DRAG_SLOP)
			{
				PieceEntry* entry = &self.entries[(usz)(self.pressed - 1)];
				app.piece_drag.clear();
				app.piece_drag.active = true;
				app.piece_drag.piece = entry.piece;
				app.piece_drag.label = entry.label.copy(mem);
				if (entry.link.len > 0)
				{
					app.piece_drag.link = entry.link.copy(mem);
					app.piece_drag.piece.link = app.piece_drag.link;
				}
			}
			if (app.piece_drag.active)
			{
				app.piece_drag.at = event.absolute;
				elem.ui.@each(LayerSheet; sheet) { sheet.request_paint(); };
			}
			return true;
		case RELEASE:
			if (event.button != MouseButton.LEFT || self.pressed == 0) return false;
			PieceEntry entry = self.entries[(usz)(self.pressed - 1)];
			self.pressed = 0;
			elem.request_paint();
			if (app.piece_drag.active)
			{
				Piece piece = app.piece_drag.piece;
				Element* under = elem.ui.hit_test(event.absolute);
				Element* target = null;
				for (Element* at = under; at; at = at.parent)
				{
					if (at.is_widget(LayerSheet)) { target = at; break; }
				}
				if (target)
				{
					target.widget_as(LayerSheet).drop(target, event.absolute - target.absolute, piece);
				}
				app.piece_drag.clear();
				elem.ui.@each(LayerSheet; sheet) { sheet.request_paint(); };
				return true;
			}
			// A click lays the piece at the playhead, on a track of its own.
			if (!anim_can_rewrite(elem.ui)) return true;
			AnimTemplate* clip = app.clip(app.editing);
			if (!clip) return true;
			if (app.place_piece(app.editing, entry.piece, app.edit_time, clip.track_count()) >= 0)
			{
				refresh_animations_view(elem.ui);
			}
			return true;
		default:
			return false;
	}
}

fn bool PieceBin.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (!event.down || event.key != Key.ESCAPE || !app.piece_drag.active) return false;
	app.piece_drag.clear();
	self.pressed = 0;
	elem.ui.@each(LayerSheet; sheet) { sheet.request_paint(); };
	elem.request_paint();
	return true;
}

// ---------------------------------------------------------------------------
// The sheet

enum StripGrip : char
{
	NONE,
	MOVE,
	FROM,
	TO,
	SPEED,
	FADE_IN,
	FADE_OUT,
}

struct LayerSheet (Widget)
{
	// What a press holds: a strip (one-based layer index) and the part of it.
	int held;
	StripGrip grip;
	Vec2 press_pos;
	Vec2 now_pos;
	bool dragged;
	bool scrubbing;
	int lit;
	StripGrip lit_grip;
}

fn AnimTemplate* LayerSheet.clip(&self, AppState* app) => app.clip(app.editing);

// Rows: the new-track row, then each track from the top down, then Base.
fn usz LayerSheet.lane_count(&self, AnimTemplate* clip) => clip ? (usz)clip.track_count() + 2 : 1;

fn float LayerSheet.lane_top(&self, usz lane) => TIMELINE_STYLE.ruler_height + LAYER_SHEET_LANE_H * (float)lane;

fn usz LayerSheet.lane_of_track(&self, AnimTemplate* clip, uint track) => (usz)(clip.track_count() - track);

<*
 The lane under `y`: 0 the new-track row, the last the Base row, -1 above
 them all (the ruler).
*>
fn sz LayerSheet.lane_at(&self, AnimTemplate* clip, float y)
{
	if (y < TIMELINE_STYLE.ruler_height) return -1;
	sz lane = (sz)((y - TIMELINE_STYLE.ruler_height) / LAYER_SHEET_LANE_H);
	return math::min(lane, (sz)self.lane_count(clip) - 1);
}

// The track a lane holds: the new-track row is one past the top; Base is none (-1).
fn sz LayerSheet.track_of_lane(&self, AnimTemplate* clip, sz lane)
{
	uint tracks = clip.track_count();
	if (lane <= 0) return (sz)tracks;
	if (lane > (sz)tracks) return -1;
	return (sz)tracks - lane;
}

fn Vec2 LayerSheet.span(&self, Element* elem)
{
	float left = LAYER_SHEET_GUTTER + TIMELINE_STYLE.pad_x;
	return { left, math::max(elem.size.x - left - TIMELINE_STYLE.pad_x, 0.0f) };
}

fn float LayerSheet.visible(&self, AppState* app, AnimTemplate* clip) => clip.duration / math::max(app.anim_timeline_zoom, 1.0f);

fn float LayerSheet.view_start(&self, AppState* app, AnimTemplate* clip)
{
	return math::clamp(app.anim_timeline_start, 0.0f, clip.duration - self.visible(app, clip));
}

fn float LayerSheet.x_of(&self, Element* elem, AppState* app, AnimTemplate* clip, float at)
{
	Vec2 span = self.span(elem);
	if (!(clip.duration > 0.0f)) return span.x;
	return span.x + span.y * (at - self.view_start(app, clip)) / self.visible(app, clip);
}

// Seconds per pixel, for turning a drag into a time.
fn float LayerSheet.at_of(&self, Element* elem, AppState* app, AnimTemplate* clip, float x, bool snapped = true)
{
	Vec2 span = self.span(elem);
	if (span.y <= 0.0f) return 0.0f;
	float at = self.view_start(app, clip) + (x - span.x) / span.y * self.visible(app, clip);
	if (snapped && !app.anim_snap_off && app.anim_fps > 0) at = math::round(at * (float)app.anim_fps) / (float)app.anim_fps;
	return at;
}

fn float LayerSheet.snap_delta(&self, AppState* app, float delta)
{
	if (app.anim_snap_off || app.anim_fps <= 0) return delta;
	return math::round(delta * (float)app.anim_fps) / (float)app.anim_fps;
}

fn Vec2 LayerSheet.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ constraints.max.x, constraints.max.y >= cui::UNBOUNDED ? ANIM_SHEET_H : constraints.max.y });
}

<*
 The strip under a point, one-based, and which part of it: an edge within
 `STRIP_EDGE_GRIP` (Alt on the end is its speed), a fade handle on its top edge,
 else the strip.
*>
fn int LayerSheet.strip_at(&self, Element* elem, AppState* app, AnimTemplate* clip, Vec2 pos, StripGrip* grip)
{
	sz lane = self.lane_at(clip, pos.y);
	sz track = self.track_of_lane(clip, lane);
	if (lane <= 0 || track < 0) return 0;
	float top = self.lane_top((usz)lane);
	foreach (usz i, &layer : clip.layers)
	{
		if ((sz)layer.track != track) continue;
		float from, to;
		layer.span(clip.duration, &from, &to);
		float left = self.x_of(elem, app, clip, from);
		float right = self.x_of(elem, app, clip, math::min(to, clip.duration));
		if (pos.x < left - STRIP_EDGE_GRIP || pos.x > right + STRIP_EDGE_GRIP) continue;
		// The fade handles sit on the top edge, at the end of each ramp.
		float fade_in_x = self.x_of(elem, app, clip, from + layer.fade_in);
		float fade_out_x = self.x_of(elem, app, clip, math::min(to, clip.duration) - layer.fade_out);
		if (pos.y < top + STRIP_FADE_GRIP + 2.0f)
		{
			if (math::abs(pos.x - fade_in_x) <= STRIP_FADE_GRIP && fade_in_x < right - STRIP_FADE_GRIP) { *grip = FADE_IN; return (int)i + 1; }
			if (math::abs(pos.x - fade_out_x) <= STRIP_FADE_GRIP && fade_out_x > left + STRIP_FADE_GRIP) { *grip = FADE_OUT; return (int)i + 1; }
		}
		bool wide = right - left > STRIP_EDGE_GRIP * 3.0f;
		if (math::abs(pos.x - left) <= STRIP_EDGE_GRIP && (wide || pos.x < left)) { *grip = FROM; return (int)i + 1; }
		if (math::abs(pos.x - right) <= STRIP_EDGE_GRIP && (wide || pos.x > right))
		{
			*grip = elem.ui.input.alt_down() && layer.placed() ? SPEED : TO;
			return (int)i + 1;
		}
		if (pos.x >= left && pos.x <= right) { *grip = MOVE; return (int)i + 1; }
	}
	return 0;
}

<*
 Where the held strip is drawn while a drag is in flight: its seconds and the
 lane it would land on.
*>
fn void LayerSheet.shown(&self, Element* elem, AppState* app, AnimTemplate* clip, usz index, float* from, float* to, usz* lane)
{
	AnimLayer* layer = &clip.layers[index];
	layer.span(clip.duration, from, to);
	*lane = self.lane_of_track(clip, layer.track);
	if (self.held != (int)index + 1 || !self.dragged) return;
	float delta = self.snap_delta(app, self.at_of(elem, app, clip, self.now_pos.x, false) - self.at_of(elem, app, clip, self.press_pos.x, false));
	switch (self.grip)
	{
		case MOVE:
			delta = math::max(delta, -*from);
			*from += delta;
			*to += delta;
			sz over = self.lane_at(clip, self.now_pos.y);
			if (over >= 0 && over < (sz)self.lane_count(clip) - 1) *lane = (usz)over;
		case FROM: *from = math::clamp(*from + delta, 0.0f, *to - ANIM_SAME_TIME * 4.0f);
		case TO: case SPEED: *to = math::max(*to + delta, *from + ANIM_SAME_TIME * 4.0f);
		default: {}
	}
}

fn void LayerSheet.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	TimelineStyle s = TIMELINE_STYLE;
	AnimTemplate* clip = self.clip(app);
	painter.rect({ 0, 0 }, elem.size, { .color = s.gutter });
	painter.rect({ 0, 0 }, { elem.size.x, s.ruler_height }, { .color = s.ruler });
	if (!clip || !(clip.duration > 0.0f))
	{
		painter.text({ s.pad_x, s.ruler_height + 6.0f }, "Pick an animation to see its layers",
			{ .size = s.text_size, .color = s.dim_text });
		return;
	}
	Vec2 span = self.span(elem);
	usz lanes = self.lane_count(clip);
	uint tracks = clip.track_count();

	// The lanes and their names.
	for (usz lane = 0; lane < lanes; lane++)
	{
		float y = self.lane_top(lane);
		painter.rect({ LAYER_SHEET_GUTTER, y }, { elem.size.x - LAYER_SHEET_GUTTER, LAYER_SHEET_LANE_H },
			{ .color = (lane & 1) == 0 ? s.lane : s.lane_alt });
		String label;
		Color ink = s.text;
		if (lane == 0)
		{
			label = "+ new track";
			ink = s.dim_text;
		}
		else if (lane == lanes - 1)
		{
			label = "Base";
		}
		else
		{
			uint track = tracks - (uint)lane;
			label = string::tformat("Track %d", track + 1);
			usz on;
			bool muted = true;
			foreach (&layer : clip.layers)
			{
				if (layer.track != track) continue;
				if (on == 0) label = layer.name;
				on++;
				if (!layer.mute) muted = false;
			}
			if (on > 1) label = string::tformat("%s +%d", label, on - 1);
			if (muted) ink = s.dim_text;
		}
		painter.text({ s.pad_x, y + (LAYER_SHEET_LANE_H - s.text_size) * 0.5f },
			elide(elem, label, LAYER_SHEET_GUTTER - s.pad_x * 2.0f, s.text_size), { .size = s.text_size, .color = ink });
	}

	// The ruler's ticks, as the key sheet draws them.
	float visible = self.visible(app, clip);
	float start = self.view_start(app, clip);
	float step = visible / 4.0f;
	if (app.anim_fps > 0)
	{
		float ticks = math::max(1.0f, math::floor(span.y / 80.0f));
		step = math::max(1.0f, math::ceil(visible * (float)app.anim_fps / ticks)) / (float)app.anim_fps;
	}
	float first = math::ceil(start / step) * step;
	for (int i = 0; i < 256; i++)
	{
		float at = first + (float)i * step;
		if (at > start + visible + 0.00001f) break;
		float x = self.x_of(elem, app, clip, at);
		painter.line({ x, s.ruler_height }, { x, elem.size.y }, 1.0, s.grid);
		String label = app.anim_fps > 0 ? string::tformat("%.0ff", math::round(at * (float)app.anim_fps))
			: string::tformat("%.2f", at);
		Vec2 measured = elem.ui.text.measure(s.font, label, s.text_size);
		painter.text({ math::min(x + 2.0f, elem.size.x - measured.x), (s.ruler_height - s.text_size) * 0.5f }, label,
			{ .size = s.text_size, .color = s.dim_text });
	}

	// The Base strip: the clip's own keys, the whole clip.
	sz active = app.active_layer_of(app.editing);
	{
		float y = self.lane_top(lanes - 1) + 3.0f;
		float left = self.x_of(elem, app, clip, 0.0f);
		float right = self.x_of(elem, app, clip, clip.duration);
		painter.rect({ left, y }, { right - left, LAYER_SHEET_LANE_H - 6.0f }, { .color = STRIP_BASE, .border_radius = LAYER_R4,
			.border_color = active < 0 ? ACCENT : STRIP_BASE, .border_width = active < 0 ? 2.0f : 0.0f });
		painter.text({ left + 6.0f, y + (LAYER_SHEET_LANE_H - 6.0f - s.text_size) * 0.5f },
			elide(elem, string::tformat("%s · %d keys", clip.name, clip.keyframes.len), math::max(right - left - 12.0f, 0.0f), s.text_size),
			{ .size = s.text_size, .color = s.text });
		foreach (frame : clip.keyframes)
		{
			float x = self.x_of(elem, app, clip, frame.time);
			painter.line({ x, y + LAYER_SHEET_LANE_H - 9.0f }, { x, y + LAYER_SHEET_LANE_H - 6.0f }, 1.0f, s.text);
		}
	}

	// The strips.
	foreach (usz i, &layer : clip.layers)
	{
		float from, to;
		usz lane;
		self.shown(elem, app, clip, i, &from, &to, &lane);
		float y = self.lane_top(lane) + 3.0f;
		float h = LAYER_SHEET_LANE_H - 6.0f;
		float left = self.x_of(elem, app, clip, math::max(from, start));
		float right = self.x_of(elem, app, clip, math::min(math::min(to, clip.duration), start + visible));
		if (right <= left) continue;
		Color fill = strip_color(layer);
		if (layer.mute) fill.a = 0.3f;
		bool selected = active == (sz)i;
		bool lit = self.lit == (int)i + 1 || self.held == (int)i + 1;
		if (lit) fill.a = math::min(fill.a + 0.12f, 1.0f);
		painter.rect({ left, y }, { right - left, h }, { .color = fill, .border_radius = LAYER_R4,
			.border_color = selected ? ACCENT : fill, .border_width = selected ? 2.0f : 0.0f });
		// A repeated piece shows where each pass begins.
		if (layer.placed() && layer.fit == REPEAT && layer.length > 0.0f)
		{
			float period = layer.length / layer.pace();
			for (int k = 1; k < 256; k++)
			{
				float pass = layer.offset + period * (float)k;
				if (pass >= to) break;
				if (pass <= from) continue;
				float x = self.x_of(elem, app, clip, pass);
				if (x > left && x < right) painter.line({ x, y + 3.0f }, { x, y + h - 3.0f }, 1.0f, { 1, 1, 1, 0.45f });
			}
		}
		// The fades: a ramp from the strip's foot to its top, and a handle at its end.
		if (layer.fade_in > 0.0f)
		{
			float x = self.x_of(elem, app, clip, from + layer.fade_in);
			painter.line({ self.x_of(elem, app, clip, from), y + h }, { x, y }, 1.5f, { 1, 1, 1, 0.7f });
		}
		if (layer.fade_out > 0.0f)
		{
			float x = self.x_of(elem, app, clip, to - layer.fade_out);
			painter.line({ x, y }, { self.x_of(elem, app, clip, to), y + h }, 1.5f, { 1, 1, 1, 0.7f });
		}
		if (selected || lit)
		{
			painter.circle({ self.x_of(elem, app, clip, from + layer.fade_in), y + 1.0f }, 3.0f, { .color = s.text });
			painter.circle({ self.x_of(elem, app, clip, to - layer.fade_out), y + 1.0f }, 3.0f, { .color = s.text });
		}
		String name = layer.weight < 0.999f ? string::tformat("%s · %d%%", layer.name, (int)(layer.weight * 100.0f + 0.5f)) : layer.name;
		float text_x = left + 6.0f;
		if (layer.source.len > 0 && right - left > 30.0f)
		{
			// Two links of a chain: the strip plays another animation and follows it.
			float cy = y + h * 0.5f;
			painter.circle({ text_x + 3.5f, cy }, 3.0f, { .border_width = 1.3f, .border_color = s.text });
			painter.circle({ text_x + 8.0f, cy }, 3.0f, { .border_width = 1.3f, .border_color = s.text });
			text_x += 15.0f;
		}
		painter.text({ text_x, y + (h - s.text_size) * 0.5f }, elide(elem, name, math::max(right - text_x - 6.0f, 0.0f), s.text_size),
			{ .size = s.text_size, .color = layer.mute ? s.dim_text : s.text });
	}

	// A piece being dragged in from the bin, where it would land.
	if (app.piece_drag.active)
	{
		Vec2 local = app.piece_drag.at - elem.absolute;
		if (local.x >= span.x && local.x <= elem.size.x && local.y >= s.ruler_height && local.y < elem.size.y)
		{
			sz lane = self.lane_at(clip, local.y);
			if (lane == (sz)lanes - 1) lane = 0;
			float at = math::clamp(self.at_of(elem, app, clip, local.x), 0.0f, clip.duration);
			float x = self.x_of(elem, app, clip, at);
			float y = self.lane_top((usz)lane) + 3.0f;
			painter.rect({ x, y }, { math::max(math::min(80.0f, span.x + span.y - x), 4.0f), LAYER_SHEET_LANE_H - 6.0f },
				{ .border_color = ACCENT, .border_width = 1.5f, .border_radius = LAYER_R4 });
			painter.text({ x + 6.0f, y + (LAYER_SHEET_LANE_H - 6.0f - s.text_size) * 0.5f }, app.piece_drag.label,
				{ .size = s.text_size, .color = ACCENT });
		}
	}

	// The playhead over everything.
	float head = anim_live_time(app);
	if (head >= start && head <= start + visible)
	{
		float x = self.x_of(elem, app, clip, head);
		painter.line({ x, 0 }, { x, elem.size.y }, s.playhead_width, s.playhead);
	}
}

fn void LayerSheet.update(&self, Element* elem, float dt) @dynamic
{
	// The playhead moves while a clip plays; the strips are redrawn with it.
	AppState* app = elem.inherit(AppState)!!;
	if (app.animating && !app.anim_paused) elem.request_paint();
}

fn void LayerSheet.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

<*
 A piece dropped from the bin at `pos` (element-local): on the track under it at
 the time under it, the new-track row and the Base row making a new track.
*>
fn void LayerSheet.drop(&self, Element* elem, Vec2 pos, Piece piece)
{
	AppState* app = elem.inherit(AppState)!!;
	AnimTemplate* clip = self.clip(app);
	if (!clip || pos.x < self.span(elem).x || pos.y < TIMELINE_STYLE.ruler_height) return;
	if (!anim_can_rewrite(elem.ui)) return;
	sz lane = self.lane_at(clip, pos.y);
	sz track = self.track_of_lane(clip, lane);
	if (track < 0) track = (sz)clip.track_count();
	float at = math::clamp(self.at_of(elem, app, clip, pos.x), 0.0f, clip.duration);
	if (app.place_piece(app.editing, piece, at, (uint)track) >= 0) refresh_animations_view(elem.ui);
}

fn bool LayerSheet.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	AnimTemplate* clip = self.clip(app);
	if (!clip || !(clip.duration > 0.0f)) return false;
	switch (event.kind)
	{
		case SCROLL:
			if (self.held != 0) return false;
			float delta = event.scroll_x != 0 ? event.scroll_x : event.scroll;
			float zoom = math::max(app.anim_timeline_zoom, 1.0f);
			float start = self.view_start(app, clip);
			if (elem.ui.input.ctrl_down())
			{
				Vec2 span = self.span(elem);
				float fraction = span.y > 0 ? math::clamp((event.pos.x - span.x) / span.y, 0.0f, 1.0f) : 0;
				float anchor = start + fraction * self.visible(app, clip);
				zoom = math::clamp(zoom * (delta > 0 ? 1.25f : 0.8f), 1.0f, 32.0f);
				start = anchor - fraction * clip.duration / zoom;
			}
			else
			{
				if (zoom <= 1) return false;
				start += delta * self.visible(app, clip) * 0.1f;
			}
			start = math::clamp(start, 0.0f, clip.duration - clip.duration / zoom);
			anim_timeline_view_changed(elem.ui, zoom, start);
			elem.request_paint();
			return true;
		case PRESS:
			if (event.pos.x < LAYER_SHEET_GUTTER) return false;
			StripGrip grip;
			int hit = self.strip_at(elem, app, clip, event.pos, &grip);
			if (event.button == MouseButton.RIGHT)
			{
				if (hit == 0) return false;
				app.set_active_layer(app.editing, (sz)(hit - 1));
				Element*? menu_elem = elem.ui.find_id(ANIM_STRIP_MENU_ID);
				if (catch menu_elem) return true;
				Dialog* menu = menu_elem.widget_as(Dialog);
				menu.at = event.absolute;
				menu.placed = true;
				menu.set_open(menu_elem, true);
				return true;
			}
			if (event.button != MouseButton.LEFT) return false;
			self.press_pos = event.pos;
			self.now_pos = event.pos;
			self.dragged = false;
			if (hit != 0)
			{
				self.held = hit;
				self.grip = grip;
				elem.request_paint();
				return true;
			}
			// Off the strips: the playhead goes there; the Base row also makes the
			// clip's own keys the ones being edited.
			if (self.lane_at(clip, event.pos.y) == (sz)self.lane_count(clip) - 1 && app.active_layer_of(app.editing) >= 0)
			{
				app.set_active_layer(app.editing, -1);
				app.refresh_timeline_tracks(app.editing);
			}
			self.scrubbing = true;
			anim_seek(elem.ui, math::clamp(self.at_of(elem, app, clip, event.pos.x), 0.0f, clip.duration));
			return true;
		case MOVE:
			if (self.held != 0)
			{
				self.now_pos = event.pos;
				if ((event.pos - self.press_pos).length() >= 3.0f) self.dragged = true;
				elem.request_paint();
				return true;
			}
			if (self.scrubbing)
			{
				anim_seek(elem.ui, math::clamp(self.at_of(elem, app, clip, event.pos.x), 0.0f, clip.duration));
				return true;
			}
			StripGrip grip;
			int over = event.pos.x < LAYER_SHEET_GUTTER ? 0 : self.strip_at(elem, app, clip, event.pos, &grip);
			if (over != self.lit || grip != self.lit_grip)
			{
				self.lit = over;
				self.lit_grip = grip;
				if (over != 0)
				{
					elem.set_cursor(grip == MOVE ? Cursor.OPEN_HAND : Cursor.RESIZE_H);
				}
				elem.request_paint();
			}
			return false;
		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;
			if (self.scrubbing)
			{
				self.scrubbing = false;
				return true;
			}
			if (self.held == 0) return false;
			usz index = (usz)(self.held - 1);
			bool moved = self.dragged;
			self.held = 0;
			self.dragged = false;
			elem.request_paint();
			if (index >= clip.layers.len) return true;
			if (!moved)
			{
				app.set_active_layer(app.editing, (sz)index);
				app.refresh_timeline_tracks(app.editing);
				refresh_animations_view(elem.ui);
				return true;
			}
			if (!anim_can_rewrite(elem.ui)) return true;
			self.commit(elem, app, clip, index, event.pos);
			app.refresh_timeline_tracks(app.editing);
			refresh_animations_view(elem.ui);
			return true;
		default:
			return false;
	}
}

// Land the drag that just ended on the strip at `index`.
fn void LayerSheet.commit(&self, Element* elem, AppState* app, AnimTemplate* clip, usz index, Vec2 pos)
{
	AnimLayer* layer = &clip.layers[index];
	float delta = self.snap_delta(app, self.at_of(elem, app, clip, pos.x, false) - self.at_of(elem, app, clip, self.press_pos.x, false));
	float from, to;
	layer.span(clip.duration, &from, &to);
	switch (self.grip)
	{
		case MOVE:
			uint track = layer.track;
			sz lane = self.lane_at(clip, pos.y);
			sz over = self.track_of_lane(clip, lane);
			if (over >= 0) track = (uint)over;
			if (math::abs(delta) < ANIM_SAME_TIME && track == layer.track) return;
			(void)app.move_strip(app.editing, index, delta, track);
		case FROM: (void)app.trim_strip(app.editing, index, from + delta, to);
		case TO: (void)app.trim_strip(app.editing, index, from, to + delta);
		case SPEED: (void)app.speed_strip(app.editing, index, to + delta);
		case FADE_IN: (void)app.set_strip_fades(app.editing, index, layer.fade_in + delta, layer.fade_out);
		case FADE_OUT: (void)app.set_strip_fades(app.editing, index, layer.fade_in, layer.fade_out - delta);
		default: {}
	}
}

fn bool LayerSheet.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;
	if (event.key == Key.ESCAPE && (self.held != 0 || self.scrubbing))
	{
		self.held = 0;
		self.dragged = false;
		self.scrubbing = false;
		elem.request_paint();
		return true;
	}
	if (event.key == Key.DELETE && self.held == 0)
	{
		anim_layer_delete_clicked(elem.ui);
		return true;
	}
	return false;
}

// Whether a drag on the sheet or the bin is in flight: a rebuild then would
// replace the widget that holds the pointer.
fn bool layer_sheet_busy(Ui* ui)
{
	bool busy;
	ui.@each(LayerSheet; sheet)
	{
		LayerSheet* it = sheet.widget_as(LayerSheet);
		if (it.held != 0 || it.scrubbing) busy = true;
	};
	ui.@each(PieceBin; bin)
	{
		if (bin.widget_as(PieceBin).pressed != 0) busy = true;
	};
	return busy;
}

// ---------------------------------------------------------------------------
// The strip menu: what is done to the strip under the pointer

fn void anim_strip_menu_closed(Ui* ui) @private => set_dialog_open(ui, ANIM_STRIP_MENU_ID, false);

fn void anim_strip_edit_source(Ui* ui)
{
	anim_strip_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	AnimLayer* layer = app.active_layer_ptr(app.editing);
	if (!layer || layer.source.len == 0) return;
	AnimRef source = app.clip_named_in_authored(layer.source);
	sz row = app.bound_row_of(source);
	if (row < 0)
	{
		app.@notice("%s is not one of this character's animations any more", layer.source);
		return;
	}
	anim_choose_clip(ui, (usz)row);
}

fn void anim_strip_make_local(Ui* ui)
{
	anim_strip_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	if (app.make_piece_local(app.editing, (usz)at))
	{
		app.@notice("the strip keeps what it plays now and no longer follows its animation");
	}
	refresh_animations_view(ui);
}

fn void anim_strip_toggle(Ui* ui, bool solo) @private
{
	anim_strip_menu_closed(ui);
	AppState* app = ui.inherit(AppState)!!;
	sz at = app.active_layer_of(app.editing);
	if (at < 0 || !anim_can_rewrite(ui)) return;
	AnimLayer edited = app.layer_copy_at(app.editing, (usz)at);
	if (solo) { edited.solo = !edited.solo; }
	else { edited.mute = !edited.mute; }
	(void)app.replace_clip_layer(app.editing, (usz)at, edited);
	refresh_animations_view(ui);
}

fn void anim_strip_mute(Ui* ui) => anim_strip_toggle(ui, false);
fn void anim_strip_solo(Ui* ui) => anim_strip_toggle(ui, true);

fn void anim_strip_mask(Ui* ui)
{
	anim_strip_menu_closed(ui);
	anim_layer_mask_clicked(ui);
}

fn void anim_strip_mask_clear(Ui* ui)
{
	anim_strip_menu_closed(ui);
	anim_layer_mask_clear_clicked(ui);
}

fn void anim_strip_share(Ui* ui)
{
	anim_strip_menu_closed(ui);
	anim_layer_menu_share(ui);
}

fn void anim_strip_delete(Ui* ui)
{
	anim_strip_menu_closed(ui);
	anim_layer_delete_clicked(ui);
}

fn Element* build_anim_strip_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimLayer* layer = app.active_layer_ptr(app.editing);
	bool none = layer == null;
	bool linked = layer && layer.source.len > 0;
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	String mute = layer && layer.mute ? "Unmute" : "Mute";
	String solo = layer && layer.solo ? "Unsolo" : "Solo";
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Edit source", "Make local", mute, solo, "Mask from selection", "Clear mask",
		"Add to animations…", "Delete" })
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = "Edit source", .on_select = &anim_strip_edit_source,
				.disabled = !linked }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_SOURCE_ID);
			@node((PopupMenuItem) { .item = { .label = "Make local", .on_select = &anim_strip_make_local,
				.disabled = !linked }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_LOCAL_ID);
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			@node((PopupMenuItem) { .item = { .label = mute, .on_select = &anim_strip_mute,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_MUTE_ID);
			@node((PopupMenuItem) { .item = { .label = solo, .on_select = &anim_strip_solo,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_SOLO_ID);
			@node((PopupMenuItem) { .item = { .label = "Mask from selection", .on_select = &anim_strip_mask,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_MASK_ID);
			@node((PopupMenuItem) { .item = { .label = "Clear mask", .on_select = &anim_strip_mask_clear,
				.disabled = none || layer.mask.len == 0 }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_MASK_CLEAR_ID);
			@node((PopupMenuItem) { .item = { .label = "Add to animations…", .on_select = &anim_strip_share,
				.disabled = none }, .style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_SHARE_ID);
			@node((MenuSeparator) { .style = style, .size = { width, widgets::SEPARATOR_H } });
			@node((PopupMenuItem) { .item = { .label = "Delete", .on_select = &anim_strip_delete,
				.disabled = none }, .style = DANGER_MENU_STYLE, .width = width }).with_id(ANIM_STRIP_DELETE_ID);
		};
	};
}

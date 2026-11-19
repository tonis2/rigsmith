<*
 The cutscene's sheet, in the Layers sheet's look: a ruler in seconds, the
 playhead, and per actor a header over two lanes, Path (moves and turns) and Clip
 (plays). A move that plays a clip of its own spans both. "+ Add actor" ends it.

 - Click a strip to pick it (a move picks its path too); click an empty lane to
   drop the pick and move the playhead there. A header click makes its actor the
   one pieces go to and focuses its character.
 - Drag a strip to move it, an end to resize it, Alt-drag a play's end to change
   its speed, the handle at a play's top to change its fade. Times snap to frames
   and, within a few pixels, to other strips' ends, the playhead and the ends;
   Shift drags free. The release is one undo step; Esc puts it back.
 - Right-click a header or a strip for its menu (cutscene_menus.c3).
 - Ctrl+wheel zooms about the pointer, Shift+wheel pans time, and the wheel
   scrolls the actors when they do not fit, else pans time once zoomed in.

 Delete is the dock's (AnimPanel.on_key), so it works after a card click too.
*>
module crig;

import cui;
import cui::widgets;
import std::collections::list;
import std::math;

const String CUT_TIMELINE_ID = "cut-timeline";
const float CUT_GUTTER_W = LAYER_SHEET_GUTTER;
const float CUT_LANE_H = LAYER_SHEET_LANE_H;
const float CUT_HEADER_H = 20.0;
// An actor's rows: its header, then its Path and Clip lanes.
const float CUT_ACTOR_H = CUT_HEADER_H + 2.0 * CUT_LANE_H;
// The empty room the timeline asks for when nothing is offered.
const float CUT_TIMELINE_H = 160.0;
// How near, in pixels, a dragged time snaps to a mark.
const float CUT_SNAP_PX = 6.0;
// How far the pointer moves before a press on a strip drags it.
const float CUT_DRAG_SLOP = 3.0;
const float CUT_ZOOM_MOST = 64.0;

const Color CUT_PAST_END = { 0.0, 0.0, 0.0, 0.25 };
// What the target actor's Clip lane says while he plays nothing.
const String CUT_CLIP_HINT = "drag a clip here";

enum CutRowKind : char
{
	NONE,      // the ruler, or below the rows
	HEADER,    // an actor's header
	LANE,      // an actor's Path or Clip lane
	ADD_ACTOR, // the "+ Add actor" row
}

<* What lies under a point of the timeline. *>
struct CutTimelineHit
{
	bool ruler;
	CutRowKind row;
	sz actor;       // -1 off the actors
	CutLane lane;   // a LANE's
	sz strip;       // -1 between strips
	StripGrip grip; // the part of the strip: its body, an end, its speed or its fade
	float at;       // seconds under the point
}

struct CutsceneTimeline (Widget)
{
	bool scrubbing;
	// What was last drawn, so a change from anywhere repaints.
	float painted_time;
	uint painted_revision;
	uint painted_selected;
	sz painted_target;
	// The strip under the pointer, one-based, for its highlight; and the "+ Add actor" row.
	int lit;
	sz lit_actor;
	bool lit_add;
	// A press on a strip: which one, the part pressed and where; `dragging` once past the slop.
	bool holding;
	bool dragging;
	usz held_actor;
	usz held_strip;
	StripGrip grip;
	Vec2 press_pos;
	// The seconds shown when the press began, so the scale holds still under a drag.
	float held_end;
	// What `describe` answers, kept while it is read.
	char[32] said;
}

// The seconds the lanes show: the cutscene, and any strip that runs past it.
fn float cut_view_end(Cutscene* cutscene)
{
	float end = math::max(cutscene.duration, 0.1f);
	foreach (&actor : cutscene.actors)
	{
		foreach (&s : actor.strips) end = math::max(end, s.end);
	}
	return end;
}

// How tall the rows are: each actor's, then "+ Add actor".
fn float cut_rows_height(Cutscene* cutscene) => CUT_ACTOR_H * (float)cutscene.actors.len + CUT_HEADER_H;

<* A strip's colour, the Layers sheet's: a move a generator's, a turn a shared layer's, a one-off a linked piece's. *>
fn Color cut_strip_color(CutStrip* s)
{
	switch (s.kind)
	{
		case MOVE: return STRIP_GENERATOR;
		case TURN: return STRIP_SHARED;
		case PLAY: return s.one_off ? STRIP_LINKED : STRIP_KEYED;
	}
}

fn void CutsceneTimeline.mount(&self, Element* elem) @dynamic => elem.clips = true;

fn float CutsceneTimeline.full(&self, Cutscene* cutscene) => self.holding ? self.held_end : cut_view_end(cutscene);

// The seconds the lanes show at once, and the first of them.
fn float CutsceneTimeline.visible(&self, AppState* app, Cutscene* cutscene) => self.full(cutscene) / math::clamp(app.cut_zoom, 1.0f, CUT_ZOOM_MOST);

fn float CutsceneTimeline.view_start(&self, AppState* app, Cutscene* cutscene)
{
	return math::clamp(app.cut_view_start, 0.0f, self.full(cutscene) - self.visible(app, cutscene));
}

// How far the rows are scrolled up, in pixels, inside what they need.
fn float CutsceneTimeline.scroll_top(&self, Element* elem, AppState* app, Cutscene* cutscene)
{
	float room = elem.size.y - TIMELINE_STYLE.ruler_height;
	return math::clamp(app.cut_view_top, 0.0f, math::max(cut_rows_height(cutscene) - room, 0.0f));
}

<* The top of actor `actor`'s header, element-local; the actor count gives the "+ Add actor" row's. *>
fn float CutsceneTimeline.actor_top(&self, Element* elem, Cutscene* cutscene, usz actor)
{
	AppState* app = elem.inherit(AppState)!!;
	return TIMELINE_STYLE.ruler_height + CUT_ACTOR_H * (float)actor - self.scroll_top(elem, app, cutscene);
}

fn float CutsceneTimeline.lane_top(&self, Element* elem, Cutscene* cutscene, usz actor, CutLane lane)
{
	return self.actor_top(elem, cutscene, actor) + CUT_HEADER_H + CUT_LANE_H * (float)lane.ordinal;
}

fn Vec2 CutsceneTimeline.span(&self, Element* elem)
{
	float left = CUT_GUTTER_W + TIMELINE_STYLE.pad_x;
	return { left, math::max(elem.size.x - left - TIMELINE_STYLE.pad_x, 1.0f) };
}

fn float CutsceneTimeline.x_of(&self, Element* elem, Cutscene* cutscene, float t)
{
	AppState* app = elem.inherit(AppState)!!;
	Vec2 span = self.span(elem);
	return span.x + span.y * (t - self.view_start(app, cutscene)) / self.visible(app, cutscene);
}

<* Seconds under `x`, snapped to the cutscene's frames unless `free`. *>
fn float CutsceneTimeline.time_of(&self, Element* elem, Cutscene* cutscene, float x, bool free = false)
{
	AppState* app = elem.inherit(AppState)!!;
	Vec2 span = self.span(elem);
	float t = self.view_start(app, cutscene) + (x - span.x) / span.y * self.visible(app, cutscene);
	if (!free && cutscene.fps > 0.0f) t = math::round(t * cutscene.fps) / cutscene.fps;
	return t;
}

// Seconds per pixel at the present zoom.
fn float CutsceneTimeline.per_pixel(&self, Element* elem, AppState* app, Cutscene* cutscene)
{
	return self.visible(app, cutscene) / self.span(elem).y;
}

<* What is under `pos`, element-local. *>
fn CutTimelineHit CutsceneTimeline.hit(&self, Element* elem, Cutscene* cutscene, Vec2 pos)
{
	AppState* app = elem.inherit(AppState)!!;
	CutTimelineHit out = { .actor = -1, .strip = -1, .at = self.time_of(elem, cutscene, pos.x, true) };
	if (pos.y < TIMELINE_STYLE.ruler_height)
	{
		out.ruler = true;
		return out;
	}
	float down = pos.y - TIMELINE_STYLE.ruler_height + self.scroll_top(elem, app, cutscene);
	usz group = (usz)(down / CUT_ACTOR_H);
	if (group >= cutscene.actors.len)
	{
		if (down - CUT_ACTOR_H * (float)cutscene.actors.len < CUT_HEADER_H) out.row = ADD_ACTOR;
		return out;
	}
	out.actor = (sz)group;
	float within = down - CUT_ACTOR_H * (float)group;
	if (within < CUT_HEADER_H)
	{
		out.row = HEADER;
		return out;
	}
	out.row = LANE;
	out.lane = within < CUT_HEADER_H + CUT_LANE_H ? WHERE : WHAT;
	if (pos.x < CUT_GUTTER_W) return out;
	// The last drawn is on top.
	CutStrip[] strips = cutscene.actors[out.actor].strips;
	foreach_r (usz k, &s : strips)
	{
		CutLane first;
		CutLane last;
		cut_strip_lanes(s, &first, &last);
		if (out.lane.ordinal < first.ordinal || out.lane.ordinal > last.ordinal) continue;
		float left = self.x_of(elem, cutscene, s.start);
		float right = self.x_of(elem, cutscene, s.end);
		if (pos.x < left - STRIP_EDGE_GRIP || pos.x > right + STRIP_EDGE_GRIP) continue;
		out.strip = (sz)k;
		// A play's fade handle sits on its top edge, where the fade ends.
		if (s.kind == PLAY && pos.y < self.lane_top(elem, cutscene, group, first) + STRIP_FADE_GRIP + 2.0f)
		{
			float fade_x = self.x_of(elem, cutscene, s.start + s.fade);
			if (math::abs(pos.x - fade_x) <= STRIP_FADE_GRIP && fade_x < right - STRIP_FADE_GRIP)
			{
				out.grip = FADE_IN;
				return out;
			}
		}
		// A narrow strip keeps its body: its ends are grabbed from outside it.
		bool wide = right - left > STRIP_EDGE_GRIP * 3.0f;
		if (math::abs(pos.x - left) <= STRIP_EDGE_GRIP && (wide || pos.x < left))
		{
			out.grip = FROM;
		}
		else if (math::abs(pos.x - right) <= STRIP_EDGE_GRIP && (wide || pos.x > right))
		{
			out.grip = s.kind == PLAY && elem.ui.input.alt_down() ? SPEED : TO;
		}
		else if (pos.x >= left && pos.x <= right)
		{
			out.grip = MOVE;
		}
		else
		{
			out.strip = -1;
			continue;
		}
		return out;
	}
	return out;
}

fn Vec2 CutsceneTimeline.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float h = constraints.max.y >= cui::UNBOUNDED ? CUT_TIMELINE_H : constraints.max.y;
	return constraints.constrain({ constraints.max.x, h });
}

// A strip's words: what it plays, or where it goes.
fn String cut_strip_label(Cutscene* cutscene, CutStrip* s) @local
{
	switch (s.kind)
	{
		case MOVE:
			String walk = s.path >= 0 && s.path < cutscene.paths.len ? cutscene.paths[s.path].name : "no path";
			if (walk.len == 0) walk = "path";
			return s.clip.len > 0 ? string::tformat("%s · %s", s.clip, walk) : string::tformat("move · %s", walk);
		case TURN:
			return s.target_row.len > 0 ? string::tformat("turn → %s", s.target_row) : "turn → point";
		case PLAY:
			if (s.one_off) return string::tformat("%s · one-off", s.clip);
			return s.clip.len > 0 ? s.clip : "play";
	}
}

// Where an actor's character comes from, dim on its header: the level, the node it stands in for, or its file.
fn String cut_actor_from(AppState* app, String row) @local
{
	sz i = app.actor_character(row);
	if (i < 0) return "no character";
	Character* c = app.character((usz)i);
	if (c.level_read) return "level";
	return c.level_node.len > 0 ? string::tformat("for %s", c.level_node) : c.label();
}

<* The box a strip is drawn in, element-local, or false when none of it shows. *>
fn bool CutsceneTimeline.strip_box(&self, Element* elem, Cutscene* cutscene, usz actor, CutStrip* strip, Vec2* at, Vec2* size)
{
	CutLane first;
	CutLane last;
	cut_strip_lanes(strip, &first, &last);
	float top = self.lane_top(elem, cutscene, actor, first) + 3.0f;
	float bottom = self.lane_top(elem, cutscene, actor, last) + CUT_LANE_H - 3.0f;
	float left = math::max(self.x_of(elem, cutscene, strip.start), CUT_GUTTER_W);
	float right = math::max(self.x_of(elem, cutscene, strip.end), self.x_of(elem, cutscene, strip.start) + 3.0f);
	right = math::min(right, elem.size.x);
	if (right <= left || bottom <= TIMELINE_STYLE.ruler_height || top >= elem.size.y) return false;
	*at = { left, top };
	*size = { right - left, bottom - top };
	return true;
}

// The lane a piece lays on: a path or a turn on Path, the rest on Clip.
fn CutLane cut_piece_lane(CutPiece piece) @local
{
	switch (piece.kind)
	{
		case NEW_PATH:
		case PATH:
		case TURN:
			return WHERE;
		case NEW_ONE_OFF:
		case CLIP:
		case ONE_OFF:
			return WHAT;
	}
}

<*
 The actor a piece dragged in from the bin or the Assets pane would land on, and the lane its outline is on; -1 for none.

 @param [&out] lane : "Set only when an actor is returned"
*>
fn sz CutsceneTimeline.landing(&self, Element* elem, AppState* app, Cutscene* cutscene, CutLane* lane)
{
	if (!app.piece_drag.active || !(app.piece_drag.for_cut || app.piece_drag.from_asset)) return -1;
	Vec2 local = app.piece_drag.at - elem.absolute;
	if (local.x < CUT_GUTTER_W || local.x > elem.size.x) return -1;
	CutTimelineHit hit = self.hit(elem, cutscene, local);
	if (hit.row != LANE) return -1;
	*lane = cut_piece_lane(app.piece_drag.cut);
	return hit.actor;
}

<*
 Where the target actor's Clip lane says a clip may be dragged there, element-local:
 while he has no play and no drag lands on it. False when it is not shown.

 @param [&out] actor
 @param [&out] at
 @param [&out] size
*>
fn bool CutsceneTimeline.clip_hint_box(&self, Element* elem, AppState* app, Cutscene* cutscene, usz* actor, Vec2* at, Vec2* size)
{
	sz target = app.cut_target_actor();
	if (target < 0) return false;
	foreach (&strip : cutscene.actors[target].strips) if (strip.kind == PLAY) return false;
	CutLane lane;
	if (self.landing(elem, app, cutscene, &lane) == target && lane == WHAT) return false;
	TimelineStyle s = TIMELINE_STYLE;
	float y = self.lane_top(elem, cutscene, (usz)target, WHAT);
	float left = self.span(elem).x + 6.0f;
	float room = elem.size.x - left - s.pad_x;
	if (y < s.ruler_height || y + CUT_LANE_H > elem.size.y || room <= 0.0f) return false;
	*actor = (usz)target;
	*at = { left, y };
	*size = { math::min(elem.ui.text.measure(s.font, CUT_CLIP_HINT, s.text_size).x, room), CUT_LANE_H };
	return true;
}

fn void CutsceneTimeline.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.painted_time = app.cut_time;
	self.painted_revision = app.cut_revision;
	self.painted_selected = app.cut_selected;
	self.painted_target = app.cut_target_actor();
	TimelineStyle s = TIMELINE_STYLE;
	painter.rect({ 0, 0 }, elem.size, { .color = s.gutter });
	Cutscene* cutscene = app.cutscene();
	if (!cutscene)
	{
		painter.rect({ 0, 0 }, { elem.size.x, s.ruler_height }, { .color = s.ruler });
		painter.text({ s.pad_x, s.ruler_height + 6.0f }, "Add a cutscene to see its timeline", { .size = s.text_size, .color = s.dim_text });
		return;
	}
	Vec2 span = self.span(elem);
	float visible = self.visible(app, cutscene);
	float start = self.view_start(app, cutscene);
	sz target = self.painted_target;
	float text_dy = (CUT_LANE_H - s.text_size) * 0.5f;

	// Each actor's two lanes, as the Layers sheet's tracks.
	foreach (usz a, &actor : cutscene.actors)
	{
		for (int lane = 0; lane < 2; lane++)
		{
			float y = self.lane_top(elem, cutscene, a, lane == 0 ? WHERE : WHAT);
			if (y + CUT_LANE_H < s.ruler_height || y > elem.size.y) continue;
			painter.rect({ CUT_GUTTER_W, y }, { elem.size.x - CUT_GUTTER_W, CUT_LANE_H }, { .color = lane == 0 ? s.lane : s.lane_alt });
			painter.text({ s.pad_x + s.indent, y + text_dy }, lane == 0 ? "Path" : "Clip", { .size = s.text_size, .color = s.dim_text });
		}
	}

	// A tick every whole step of seconds that leaves room for its label.
	float step = 0.1f;
	foreach (candidate : (float[]){ 0.05f, 0.1f, 0.25f, 0.5f, 1.0f, 2.0f, 5.0f, 10.0f, 30.0f, 60.0f })
	{
		step = candidate;
		if (span.y * candidate / visible >= 60.0f) break;
	}
	float first_tick = math::ceil(start / step - 1e-4f) * step;
	for (int i = 0; i < 1000; i++)
	{
		float at = first_tick + (float)i * step;
		if (at > start + visible + 1e-4f) break;
		float x = self.x_of(elem, cutscene, at);
		painter.line({ x, s.ruler_height }, { x, elem.size.y }, 1.0, s.grid);
	}

	// The headers over the ticks: the actor pieces go to named in the accent, where it comes from dim.
	foreach (usz a, &actor : cutscene.actors)
	{
		float top = self.actor_top(elem, cutscene, a);
		if (top + CUT_HEADER_H < s.ruler_height || top > elem.size.y) continue;
		painter.rect({ 0, top }, { elem.size.x, CUT_HEADER_H }, { .color = s.gutter });
		painter.rect({ 0, top }, { elem.size.x, 1.0f }, { .color = s.grid });
		float text_y = top + (CUT_HEADER_H - s.text_size) * 0.5f;
		String name = elide(elem, actor.row, CUT_GUTTER_W - s.pad_x * 2.0f, s.text_size);
		painter.text({ s.pad_x, text_y }, name, { .size = s.text_size, .color = (sz)a == target ? ACCENT : s.text });
		float after = s.pad_x + elem.ui.text.measure(s.font, name, s.text_size).x + s.pad_x;
		painter.text({ after, text_y }, elide(elem, cut_actor_from(app, actor.row), math::max(elem.size.x - after - s.pad_x, 0.0f), s.text_size),
			{ .size = s.text_size, .color = s.dim_text });
	}
	float add_top = self.actor_top(elem, cutscene, cutscene.actors.len);
	if (add_top + CUT_HEADER_H >= s.ruler_height && add_top <= elem.size.y)
	{
		painter.rect({ 0, add_top }, { elem.size.x, CUT_HEADER_H }, { .color = s.gutter });
		painter.rect({ 0, add_top }, { elem.size.x, 1.0f }, { .color = s.grid });
		if (self.lit_add) painter.rect({ 2, add_top + 1.0f }, { CUT_GUTTER_W - 4.0f, CUT_HEADER_H - 2.0f }, { .color = s.lane_alt, .border_radius = LAYER_R4 });
		painter.text({ s.pad_x, add_top + (CUT_HEADER_H - s.text_size) * 0.5f }, "+ Add actor", { .size = s.text_size, .color = s.dim_text });
	}

	// After the end: shaded, so a strip that runs past it shows.
	float stop = self.x_of(elem, cutscene, cutscene.duration);
	float right_edge = span.x + span.y;
	if (stop < right_edge)
	{
		float from = math::max(stop, CUT_GUTTER_W);
		painter.rect({ from, s.ruler_height }, { right_edge - from, elem.size.y - s.ruler_height }, { .color = CUT_PAST_END });
	}

	// Under the strips: a move that plays its own clip may cover it.
	usz hinted;
	Vec2 hint_at;
	Vec2 hint_size;
	if (self.clip_hint_box(elem, app, cutscene, &hinted, &hint_at, &hint_size))
	{
		painter.text({ hint_at.x, hint_at.y + text_dy }, elide(elem, CUT_CLIP_HINT, hint_size.x, s.text_size), { .size = s.text_size, .color = s.dim_text });
	}

	// The strips, the picked one outlined; a play's fade a ramp up to its handle.
	foreach (usz a, &actor : cutscene.actors)
	{
		foreach (usz k, &strip : actor.strips)
		{
			Vec2 at;
			Vec2 size;
			if (!self.strip_box(elem, cutscene, a, strip, &at, &size)) continue;
			Color fill = cut_strip_color(strip);
			bool lit = (self.lit == (int)k + 1 && self.lit_actor == (sz)a) || (self.holding && self.held_actor == a && self.held_strip == k);
			bool picked = strip.id != 0 && strip.id == app.cut_selected;
			if (lit) fill.a = math::min(fill.a + 0.12f, 1.0f);
			painter.rect(at, size, { .color = fill, .border_radius = LAYER_R4,
				.border_color = picked ? ACCENT : fill, .border_width = picked ? 2.0f : 0.0f });
			if (strip.kind == PLAY)
			{
				float fade_x = self.x_of(elem, cutscene, strip.start + strip.fade);
				if (strip.fade > 0.0f && fade_x > at.x)
				{
					painter.line({ self.x_of(elem, cutscene, strip.start), at.y + size.y }, { math::min(fade_x, at.x + size.x), at.y }, 1.5f, { 1, 1, 1, 0.7f });
				}
				if ((picked || lit) && fade_x >= at.x && fade_x <= at.x + size.x) painter.circle({ fade_x, at.y + 1.0f }, 3.0f, { .color = s.text });
			}
			String name = cut_strip_label(cutscene, strip);
			painter.text({ at.x + 6.0f, at.y + (size.y - s.text_size) * 0.5f },
				elide(elem, name, math::max(size.x - 12.0f, 0.0f), s.text_size), { .size = s.text_size, .color = s.text });
		}
	}

	// A piece being dragged in from the bin or the Assets pane, where it would land.
	CutLane landing_lane;
	sz landing = self.landing(elem, app, cutscene, &landing_lane);
	if (landing >= 0)
	{
		float x = self.x_of(elem, cutscene, self.drop_time(elem, app, cutscene, app.piece_drag.at.x - elem.absolute.x));
		float y = self.lane_top(elem, cutscene, (usz)landing, landing_lane) + 3.0f;
		painter.rect({ x, y }, { math::max(math::min(80.0f, right_edge - x), 4.0f), CUT_LANE_H - 6.0f },
			{ .border_color = ACCENT, .border_width = 1.5f, .border_radius = LAYER_R4 });
		painter.text({ x + 6.0f, y + (CUT_LANE_H - 6.0f - s.text_size) * 0.5f }, app.piece_drag.label,
			{ .size = s.text_size, .color = ACCENT });
	}

	// The ruler over the rows scrolled under it, then its labels.
	painter.rect({ 0, 0 }, { elem.size.x, s.ruler_height }, { .color = s.ruler });
	for (int i = 0; i < 1000; i++)
	{
		float at = first_tick + (float)i * step;
		if (at > start + visible + 1e-4f) break;
		float x = self.x_of(elem, cutscene, at);
		String label = string::tformat(step < 0.1f ? "%.2fs" : step < 1.0f ? "%.1fs" : "%.0fs", at);
		Vec2 measured = elem.ui.text.measure(s.font, label, s.text_size);
		painter.text({ math::min(x + 2.0f, elem.size.x - measured.x), (s.ruler_height - s.text_size) * 0.5f }, label,
			{ .size = s.text_size, .color = s.dim_text });
	}
	if (stop >= CUT_GUTTER_W && stop <= elem.size.x) painter.line({ stop, 0 }, { stop, elem.size.y }, 1.5f, s.dim_text);

	// The playhead over everything.
	float x = self.x_of(elem, cutscene, app.cut_time);
	if (x >= CUT_GUTTER_W && x <= elem.size.x) painter.line({ x, 0 }, { x, elem.size.y }, s.playhead_width, s.playhead);
}

fn void CutsceneTimeline.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.cut_time != self.painted_time || app.cut_revision != self.painted_revision || app.cut_selected != self.painted_selected
		|| app.cut_target_actor() != self.painted_target)
	{
		elem.request_paint();
	}
}

<*
 Each actor's header as a part named `cut-actor-<actor>`, each strip in view as `cut-strip-<actor>-<strip>`,
 `cut-add-actor`, and the target's empty Clip lane hint as `cut-clip-hint-<actor>`.
*>
fn void CutsceneTimeline.describe(&self, Element* elem, Description* out) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	out.text = "Cutscene timeline";
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return;
	usz picked_actor;
	usz picked_strip;
	if (app.cut_selection(&picked_actor, &picked_strip))
	{
		out.value = string::bformat(&self.said, "picked %d-%d", picked_actor, picked_strip);
	}
	float floor = TIMELINE_STYLE.ruler_height;
	foreach (usz a, &actor : cutscene.actors)
	{
		float y = self.actor_top(elem, cutscene, a);
		if (y >= floor && y + CUT_HEADER_H <= elem.size.y) out.part(string::tformat("cut-actor-%d", a), { 0, y }, { elem.size.x, CUT_HEADER_H });
		foreach (usz k, &strip : actor.strips)
		{
			Vec2 at;
			Vec2 size;
			if (self.strip_box(elem, cutscene, a, strip, &at, &size)) out.part(string::tformat("cut-strip-%d-%d", a, k), at, size);
		}
	}
	float add = self.actor_top(elem, cutscene, cutscene.actors.len);
	if (add >= floor && add + CUT_HEADER_H <= elem.size.y) out.part("cut-add-actor", { 0, add }, { elem.size.x, CUT_HEADER_H });
	usz hinted;
	Vec2 at;
	Vec2 size;
	if (self.clip_hint_box(elem, app, cutscene, &hinted, &at, &size)) out.part(string::tformat("cut-clip-hint-%d", hinted), at, size);
}

fn void CutsceneTimeline.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || (self.lit == 0 && !self.lit_add)) return;
	self.lit = 0;
	self.lit_add = false;
	elem.request_paint();
}

<* Move the playhead to the time under `x`. *>
fn void CutsceneTimeline.seek(&self, Element* elem, Cutscene* cutscene, float x)
{
	AppState* app = elem.inherit(AppState)!!;
	app.show_cutscene_at(self.time_of(elem, cutscene, x, elem.ui.input.shift_down()));
	elem.request_paint();
	app.refresh_ui();
}

// What a time snaps to: the strips' ends but the held one's and the walks it carries, the playhead and the cutscene's ends.
fn float[] CutsceneTimeline.marks(&self, AppState* app, Cutscene* cutscene)
{
	List{float} out;
	out.tinit();
	out.push(0.0f);
	out.push(cutscene.duration);
	out.push(app.cut_time);
	foreach (usz a, &actor : cutscene.actors)
	{
		foreach (usz k, &s : actor.strips)
		{
			if (self.holding && a == self.held_actor && k == self.held_strip) continue;
			// A tied walk follows the held move, so its ends would hold the drag where it was.
			if (self.holding && a == self.held_actor && app.cut_drag_carries(a, self.held_strip, k)) continue;
			out.push(s.start);
			out.push(s.end);
		}
	}
	return out.array_view();
}

<* The time a piece dropped at `x` lays at: snapped as a dragged start snaps, never before 0. *>
fn float CutsceneTimeline.drop_time(&self, Element* elem, AppState* app, Cutscene* cutscene, float x)
{
	float t = self.time_of(elem, cutscene, x, true);
	if (elem.ui.input.shift_down()) return math::max(t, 0.0f);
	@pool()
	{
		t = cut_snap_time(t, cutscene.fps, self.marks(app, cutscene), CUT_SNAP_PX * self.per_pixel(elem, app, cutscene));
	};
	return math::max(t, 0.0f);
}

<* The held strip follows the pointer at `pos`: moved, an end resized, its speed or its fade, snapped unless Shift is down. *>
fn void CutsceneTimeline.drag_to(&self, Element* elem, AppState* app, Cutscene* cutscene, Vec2 pos)
{
	CutStrip* was = app.cut_gesture_strip(self.held_actor, self.held_strip);
	if (!was) return;
	bool free = elem.ui.input.shift_down();
	float delta = self.time_of(elem, cutscene, pos.x, true) - self.time_of(elem, cutscene, self.press_pos.x, true);
	float fps = free ? 0.0f : cutscene.fps;
	float reach = free ? -1.0f : CUT_SNAP_PX * self.per_pixel(elem, app, cutscene);
	float frame = cutscene.fps > 0.0f ? 1.0f / cutscene.fps : 0.01f;
	// A strip may start before 0 only when it already did.
	float floor = math::min(was.start, 0.0f);
	float start = was.start;
	float end = was.end;
	float fade = was.fade;
	@pool()
	{
		float[] marks = free ? (float[]){} : self.marks(app, cutscene);
		switch (self.grip)
		{
			case FROM:
				float snapped = cut_snap_time(was.start + delta, fps, marks, reach);
				start = math::clamp(snapped, floor, math::max(was.end - frame, floor));
			case TO:
			case SPEED:
				end = math::max(cut_snap_time(was.end + delta, fps, marks, reach), was.start + frame);
			case FADE_IN:
				fade = cut_snap_time(was.start + was.fade + delta, fps, marks, reach) - was.start;
			default:
				float length = was.end - was.start;
				start = math::max(cut_snap_span(was.start + delta, length, fps, marks, reach), floor);
				end = start + length;
		}
	};
	switch (self.grip)
	{
		case SPEED: (void)app.drag_cut_speed(self.held_actor, self.held_strip, end);
		case FADE_IN: (void)app.drag_cut_fade(self.held_actor, self.held_strip, fade);
		default: (void)app.drag_cut_strip(self.held_actor, self.held_strip, start, end, self.grip == FROM);
	}
}

// Let go of a strip: the drag lands, or a plain click leaves only the pick.
fn void CutsceneTimeline.release_strip(&self, Element* elem, AppState* app)
{
	if (self.dragging) (void)app.end_cut_gesture(self.held_actor, self.held_strip);
	self.holding = false;
	self.dragging = false;
	elem.request_paint();
	app.refresh_ui();
}

fn bool CutsceneTimeline.scroll(&self, Element* elem, AppState* app, Cutscene* cutscene, MouseEvent event)
{
	float delta = event.scroll_x != 0 ? event.scroll_x : event.scroll;
	float zoom = math::clamp(app.cut_zoom, 1.0f, CUT_ZOOM_MOST);
	float start = self.view_start(app, cutscene);
	float full = self.full(cutscene);
	Input* input = &elem.ui.input;
	if (input.ctrl_down())
	{
		Vec2 span = self.span(elem);
		float fraction = math::clamp((event.pos.x - span.x) / span.y, 0.0f, 1.0f);
		float anchor = start + fraction * self.visible(app, cutscene);
		zoom = math::clamp(zoom * (delta > 0 ? 1.25f : 0.8f), 1.0f, CUT_ZOOM_MOST);
		start = anchor - fraction * full / zoom;
	}
	else
	{
		float room = elem.size.y - TIMELINE_STYLE.ruler_height;
		bool tall = cut_rows_height(cutscene) > room;
		if (tall && !input.shift_down() && event.scroll_x == 0)
		{
			app.cut_view_top = self.scroll_top(elem, app, cutscene) - delta * CUT_LANE_H;
			app.cut_view_top = self.scroll_top(elem, app, cutscene);
			elem.request_paint();
			return true;
		}
		if (zoom <= 1.0f) return false;
		start += delta * self.visible(app, cutscene) * 0.1f;
	}
	app.cut_zoom = zoom;
	app.cut_view_start = math::clamp(start, 0.0f, full - full / zoom);
	elem.request_paint();
	return true;
}

<* Pick strip `strip` of `actor`; a move picks its path too, so its knots show. *>
fn void CutsceneTimeline.pick(&self, AppState* app, Cutscene* cutscene, usz actor, usz strip)
{
	(void)app.select_cut_strip(actor, strip);
	CutStrip* s = &cutscene.actors[actor].strips[strip];
	if (s.kind == MOVE && s.path >= 0 && s.path < cutscene.paths.len && app.cut_path_pick != (usz)s.path + 1) (void)app.pick_cut_path(s.path);
}

<* A header pressed: its actor is the one pieces go to, nothing picked, and its character the focus. *>
fn void CutsceneTimeline.target(&self, Element* elem, AppState* app, Cutscene* cutscene, usz actor)
{
	app.cut_lane_actor = actor + 1;
	app.clear_cut_selection();
	sz holder = app.actor_character(cutscene.actors[actor].row);
	if (holder >= 0 && (usz)holder != app.active) (void)app.focus_character((usz)holder);
	elem.request_paint();
	app.refresh_ui();
}

// A right press: a header's menu or a strip's.
fn bool CutsceneTimeline.menu(&self, Element* elem, AppState* app, Cutscene* cutscene, CutTimelineHit hit, MouseEvent event)
{
	if (hit.row == HEADER)
	{
		app.cut_lane_actor = (usz)hit.actor + 1;
		app.clear_cut_selection();
		cut_open_popup(elem.ui, CUT_ACTOR_MENU_ID, event.absolute);
		elem.request_paint();
		return true;
	}
	if (hit.strip < 0) return false;
	self.pick(app, cutscene, (usz)hit.actor, (usz)hit.strip);
	cut_open_popup(elem.ui, CUT_STRIP_MENU_ID, event.absolute);
	elem.request_paint();
	app.refresh_ui();
	return true;
}

<*
 The actor whose lanes are under a drop at `pos` (element-local): pieces go to him,
 nothing is picked and the playhead moves to the snapped drop time. Only a lane
 takes a drop: not the ruler, a header, "+ Add actor" or the gutter.

 @param [&inout] app
 @return "The actor, or -1 off the lanes"
*>
fn sz CutsceneTimeline.drop_actor(&self, Element* elem, AppState* app, Vec2 pos)
{
	Cutscene* cutscene = app.cutscene();
	if (!cutscene || pos.x < CUT_GUTTER_W || pos.x > elem.size.x) return -1;
	CutTimelineHit hit = self.hit(elem, cutscene, pos);
	if (hit.row != LANE) return -1;
	app.cut_lane_actor = (usz)hit.actor + 1;
	app.clear_cut_selection();
	app.show_cutscene_at(self.drop_time(elem, app, cutscene, pos.x));
	return hit.actor;
}

<*
 A piece dropped from the bin at `pos` (element-local): the actor under it gets it
 at the time under it, laid as a click lays it, and a path as a move.
*>
fn void CutsceneTimeline.drop(&self, Element* elem, Vec2 pos, CutPiece piece)
{
	AppState* app = elem.inherit(AppState)!!;
	if (self.drop_actor(elem, app, pos) < 0) return;
	cut_lay_piece(elem.ui, piece, true);
	elem.request_paint();
}

<*
 An Assets clip dropped at `pos` (element-local): a play of it for the actor under
 it, bound to him first if he lacks it. `piece_drag_drop` ends the drag after.

 @param [&in] c : "The clip, valid for the call"
*>
fn void CutsceneTimeline.drop_asset(&self, Element* elem, Vec2 pos, AssetClip* c)
{
	AppState* app = elem.inherit(AppState)!!;
	sz actor = self.drop_actor(elem, app, pos);
	if (actor < 0) return;
	(void)app.add_cut_asset_play((usz)actor, c);
	app.refresh_ui();
	elem.request_paint();
}

fn bool CutsceneTimeline.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Cutscene* cutscene = app.cutscene();
	if (!cutscene) return false;
	switch (event.kind)
	{
		case SCROLL:
			if (self.holding || self.scrubbing) return false;
			return self.scroll(elem, app, cutscene, event);
		case PRESS:
			CutTimelineHit hit = self.hit(elem, cutscene, event.pos);
			if (event.button == MouseButton.RIGHT) return self.menu(elem, app, cutscene, hit, event);
			if (event.button != MouseButton.LEFT) return false;
			switch (hit.row)
			{
				case ADD_ACTOR:
					cut_open_actor_list(elem.ui, event.absolute);
					return true;
				case HEADER:
					self.target(elem, app, cutscene, (usz)hit.actor);
					return true;
				case LANE:
					app.cut_lane_actor = (usz)hit.actor + 1;
					// A lane's name: the actor pieces go to, nothing picked.
					if (event.pos.x < CUT_GUTTER_W)
					{
						app.clear_cut_selection();
						elem.request_paint();
						return true;
					}
				case NONE:
					if (event.pos.x < CUT_GUTTER_W) return false;
			}
			if (hit.strip >= 0)
			{
				self.pick(app, cutscene, (usz)hit.actor, (usz)hit.strip);
				// A double-click on a one-off's strip edits it.
				CutStrip* pressed = &cutscene.actors[hit.actor].strips[hit.strip];
				if (event.clicks >= 2 && pressed.kind != TURN && pressed.one_off)
				{
					(void)app.edit_cut_one_off((usz)hit.actor, (usz)hit.strip);
					elem.request_paint();
					app.refresh_ui();
					return true;
				}
				self.holding = true;
				self.dragging = false;
				self.held_actor = (usz)hit.actor;
				self.held_strip = (usz)hit.strip;
				self.grip = hit.grip;
				self.press_pos = event.pos;
				self.held_end = cut_view_end(cutscene);
				elem.request_paint();
				return true;
			}
			if (!hit.ruler) app.clear_cut_selection();
			self.scrubbing = true;
			self.seek(elem, cutscene, event.pos.x);
			return true;
		case MOVE:
			if (self.holding)
			{
				if (!self.dragging && (event.pos - self.press_pos).length() >= CUT_DRAG_SLOP) self.dragging = app.begin_cut_gesture();
				// Something replaced the cutscenes under the drag: it is over.
				if (self.dragging && !app.cut_gesture_open)
				{
					self.holding = false;
					self.dragging = false;
					return true;
				}
				if (self.dragging) self.drag_to(elem, app, cutscene, event.pos);
				elem.request_paint();
				return true;
			}
			if (self.scrubbing)
			{
				self.seek(elem, cutscene, event.pos.x);
				return true;
			}
			CutTimelineHit hit = self.hit(elem, cutscene, event.pos);
			int over = hit.strip >= 0 ? (int)hit.strip + 1 : 0;
			bool add = hit.row == ADD_ACTOR;
			if (over != self.lit || hit.actor != self.lit_actor || add != self.lit_add)
			{
				self.lit = over;
				self.lit_actor = hit.actor;
				self.lit_add = add;
				elem.request_paint();
			}
			if (over != 0) elem.set_cursor(hit.grip == MOVE ? Cursor.OPEN_HAND : Cursor.RESIZE_H);
			if (over == 0) elem.set_cursor(Cursor.DEFAULT);
			return false;
		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;
			if (self.holding)
			{
				self.release_strip(elem, app);
				return true;
			}
			if (!self.scrubbing) return false;
			self.scrubbing = false;
			return true;
		default:
			return false;
	}
}

fn bool CutsceneTimeline.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down || event.key != Key.ESCAPE) return false;
	if (self.holding)
	{
		AppState* app = elem.inherit(AppState)!!;
		if (self.dragging) app.cancel_cut_gesture();
		self.holding = false;
		self.dragging = false;
		elem.request_paint();
		app.refresh_ui();
		return true;
	}
	if (!self.scrubbing) return false;
	self.scrubbing = false;
	return true;
}

// Whether a press on a timeline, or on a cutscene's Pieces bin, is in flight: a rebuild then would drop the widget holding it.
fn bool cut_timeline_busy(Ui* ui)
{
	bool busy;
	ui.@each(CutsceneTimeline; timeline)
	{
		CutsceneTimeline* it = timeline.widget_as(CutsceneTimeline);
		if (it.holding || it.scrubbing) busy = true;
	};
	ui.@each(PieceBin; bin)
	{
		PieceBin* it = bin.widget_as(PieceBin);
		if (it.for_cut && it.pressed != 0) busy = true;
	};
	return busy;
}

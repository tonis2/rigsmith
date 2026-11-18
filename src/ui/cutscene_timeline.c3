<*
 The Cutscene tab's timeline: a ruler in seconds, the playhead, and two lanes per
 actor, Where (moves and turns) and What (clips). A move that plays a clip spans both.

 - Click a strip to pick it; click an empty lane to drop the pick and move the
   playhead there. A click in a lane also makes its actor the one adds go to.
 - Drag a strip to move it, an end to resize it. Times snap to the cutscene's
   frames, and within a few pixels to other strips' ends, the playhead and the
   cutscene's ends; Shift drags free. The preview follows the drag, the release
   settles the lanes as one undo step, and Esc puts it back.
 - Ctrl+wheel zooms about the pointer, Shift+wheel pans time, and the wheel
   scrolls the actors when they do not fit, else pans time once zoomed in.

 Delete is the panel's (CutscenePanel.on_key), so it works after a card click too.
*>
module crig;

import cui;
import cui::widgets;
import std::collections::list;
import std::math;

const String CUT_TIMELINE_ID = "cut-timeline";
const float CUT_GUTTER_W = 132.0;
const float CUT_LANE_H = 22.0;
// The empty room the timeline asks for when nothing is offered.
const float CUT_TIMELINE_H = 160.0;
// How near, in pixels, a dragged time snaps to a mark.
const float CUT_SNAP_PX = 6.0;
// How far the pointer moves before a press on a strip drags it.
const float CUT_DRAG_SLOP = 3.0;
const float CUT_ZOOM_MOST = 64.0;

const Color CUT_MOVE_FILL = { 0.34, 0.68, 0.47, 0.85 };
const Color CUT_TURN_FILL = { 0.28, 0.66, 0.70, 0.85 };
const Color CUT_PLAY_FILL = { 0.33, 0.52, 0.86, 0.85 };
const Color CUT_PAST_END = { 0.0, 0.0, 0.0, 0.25 };

<* What lies under a point of the timeline. *>
struct CutTimelineHit
{
	bool ruler;
	sz actor;       // -1 off the lanes
	CutLane lane;
	sz strip;       // -1 between strips
	StripGrip grip; // the part of the strip: its body or an end
	float at;       // seconds under the point
}

struct CutsceneTimeline (Widget)
{
	bool scrubbing;
	// What was last drawn, so a change from anywhere repaints.
	float painted_time;
	uint painted_revision;
	uint painted_selected;
	// The strip under the pointer, one-based, for its highlight.
	int lit;
	sz lit_actor;
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

fn void CutsceneTimeline.mount(&self, Element* elem) @dynamic => elem.clips = true;

fn float CutsceneTimeline.full(&self, Cutscene* cutscene) => self.holding ? self.held_end : cut_view_end(cutscene);

// The seconds the lanes show at once, and the first of them.
fn float CutsceneTimeline.visible(&self, AppState* app, Cutscene* cutscene) => self.full(cutscene) / math::clamp(app.cut_zoom, 1.0f, CUT_ZOOM_MOST);

fn float CutsceneTimeline.view_start(&self, AppState* app, Cutscene* cutscene)
{
	return math::clamp(app.cut_view_start, 0.0f, self.full(cutscene) - self.visible(app, cutscene));
}

// How far the lanes are scrolled up, in pixels, inside what they need.
fn float CutsceneTimeline.scroll_top(&self, Element* elem, AppState* app, Cutscene* cutscene)
{
	float room = elem.size.y - TIMELINE_STYLE.ruler_height;
	float need = CUT_LANE_H * (float)(cutscene.actors.len * 2);
	return math::clamp(app.cut_view_top, 0.0f, math::max(need - room, 0.0f));
}

fn float CutsceneTimeline.lane_top(&self, Element* elem, Cutscene* cutscene, usz actor, CutLane lane)
{
	AppState* app = elem.inherit(AppState)!!;
	return TIMELINE_STYLE.ruler_height + CUT_LANE_H * (float)(actor * 2 + lane.ordinal) - self.scroll_top(elem, app, cutscene);
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
	usz row = (usz)(down / CUT_LANE_H);
	if (row >= cutscene.actors.len * 2) return out;
	out.actor = (sz)(row / 2);
	out.lane = row % 2 == 0 ? WHERE : WHAT;
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
		// A narrow strip keeps its body: its ends are grabbed from outside it.
		bool wide = right - left > STRIP_EDGE_GRIP * 3.0f;
		out.strip = (sz)k;
		if (math::abs(pos.x - left) <= STRIP_EDGE_GRIP && (wide || pos.x < left))
		{
			out.grip = FROM;
		}
		else if (math::abs(pos.x - right) <= STRIP_EDGE_GRIP && (wide || pos.x > right))
		{
			out.grip = TO;
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

fn void CutsceneTimeline.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.painted_time = app.cut_time;
	self.painted_revision = app.cut_revision;
	self.painted_selected = app.cut_selected;
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
	sz target = app.cut_target_actor();

	// The lanes, an actor's two in one shade; the one adds go to is named in the accent.
	foreach (usz a, &actor : cutscene.actors)
	{
		for (int lane = 0; lane < 2; lane++)
		{
			float y = self.lane_top(elem, cutscene, a, lane == 0 ? WHERE : WHAT);
			if (y + CUT_LANE_H < s.ruler_height || y > elem.size.y) continue;
			painter.rect({ CUT_GUTTER_W, y }, { elem.size.x - CUT_GUTTER_W, CUT_LANE_H }, { .color = (a & 1) == 0 ? s.lane : s.lane_alt });
			String label = lane == 0 ? elide(elem, actor.row, CUT_GUTTER_W - s.pad_x * 2.0f - 40.0f, s.text_size) : "  what";
			Color ink = lane == 0 ? ((sz)a == target ? ACCENT : s.text) : s.dim_text;
			painter.text({ s.pad_x, y + (CUT_LANE_H - s.text_size) * 0.5f }, label, { .size = s.text_size, .color = ink });
			if (lane == 0)
			{
				Vec2 measured = elem.ui.text.measure(s.font, "where", s.text_size);
				painter.text({ CUT_GUTTER_W - measured.x - 4.0f, y + (CUT_LANE_H - s.text_size) * 0.5f }, "where",
					{ .size = s.text_size, .color = s.dim_text });
			}
		}
	}
	if (cutscene.actors.len == 0)
	{
		painter.text({ s.pad_x, s.ruler_height + 6.0f }, "No actors in this cutscene yet", { .size = s.text_size, .color = s.dim_text });
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

	// After the end: shaded, so a strip that runs past it shows.
	float stop = self.x_of(elem, cutscene, cutscene.duration);
	float right_edge = span.x + span.y;
	if (stop < right_edge)
	{
		float from = math::max(stop, CUT_GUTTER_W);
		painter.rect({ from, s.ruler_height }, { right_edge - from, elem.size.y - s.ruler_height }, { .color = CUT_PAST_END });
	}

	// The strips, the picked one outlined.
	foreach (usz a, &actor : cutscene.actors)
	{
		foreach (usz k, &strip : actor.strips)
		{
			Vec2 at;
			Vec2 size;
			if (!self.strip_box(elem, cutscene, a, strip, &at, &size)) continue;
			Color fill = strip.kind == MOVE ? CUT_MOVE_FILL : strip.kind == TURN ? CUT_TURN_FILL : CUT_PLAY_FILL;
			bool lit = (self.lit == (int)k + 1 && self.lit_actor == (sz)a) || (self.holding && self.held_actor == a && self.held_strip == k);
			bool picked = strip.id != 0 && strip.id == app.cut_selected;
			if (lit) fill.a = 1.0f;
			painter.rect(at, size, { .color = fill, .border_radius = LAYER_R4,
				.border_color = picked ? ACCENT : fill, .border_width = picked ? 2.0f : 0.0f });
			String name = cut_strip_label(cutscene, strip);
			painter.text({ at.x + 6.0f, at.y + (size.y - s.text_size) * 0.5f },
				elide(elem, name, math::max(size.x - 12.0f, 0.0f), s.text_size), { .size = s.text_size, .color = s.text });
		}
	}

	// The ruler over the lanes scrolled under it, then its labels.
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
	if (app.cut_time != self.painted_time || app.cut_revision != self.painted_revision || app.cut_selected != self.painted_selected)
	{
		elem.request_paint();
	}
}

<* Each strip in view as a part named `cut-strip-<actor>-<strip>`, and each actor's name cell as `cut-actor-<actor>`. *>
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
	foreach (usz a, &actor : cutscene.actors)
	{
		float y = self.lane_top(elem, cutscene, a, WHERE);
		if (y >= TIMELINE_STYLE.ruler_height && y + CUT_LANE_H <= elem.size.y)
		{
			out.part(string::tformat("cut-actor-%d", a), { 0, y }, { CUT_GUTTER_W, CUT_LANE_H });
		}
		foreach (usz k, &strip : actor.strips)
		{
			Vec2 at;
			Vec2 size;
			if (self.strip_box(elem, cutscene, a, strip, &at, &size)) out.part(string::tformat("cut-strip-%d-%d", a, k), at, size);
		}
	}
}

fn void CutsceneTimeline.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered || self.lit == 0) return;
	self.lit = 0;
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

// What a dragged time snaps to: every other strip's ends, the playhead and the cutscene's ends.
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
			if (a == self.held_actor && k == self.held_strip) continue;
			out.push(s.start);
			out.push(s.end);
		}
	}
	return out.array_view();
}

<* The held strip follows the pointer at `pos`: moved, or an end resized, snapped unless Shift is down. *>
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
	@pool()
	{
		float[] marks = free ? (float[]){} : self.marks(app, cutscene);
		switch (self.grip)
		{
			case FROM:
				float snapped = cut_snap_time(was.start + delta, fps, marks, reach);
				start = math::clamp(snapped, floor, math::max(was.end - frame, floor));
			case TO:
				end = math::max(cut_snap_time(was.end + delta, fps, marks, reach), was.start + frame);
			default:
				float length = was.end - was.start;
				start = math::max(cut_snap_span(was.start + delta, length, fps, marks, reach), floor);
				end = start + length;
		}
	};
	(void)app.drag_cut_strip(self.held_actor, self.held_strip, start, end, self.grip == FROM);
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
		bool tall = CUT_LANE_H * (float)(cutscene.actors.len * 2) > room;
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
			if (event.button != MouseButton.LEFT) return false;
			CutTimelineHit hit = self.hit(elem, cutscene, event.pos);
			if (hit.actor >= 0) app.cut_lane_actor = (usz)hit.actor + 1;
			if (!hit.ruler && hit.actor >= 0 && event.pos.x < CUT_GUTTER_W)
			{
				// The name cell: the actor adds go to, nothing picked.
				app.clear_cut_selection();
				elem.request_paint();
				return true;
			}
			if (event.pos.x < CUT_GUTTER_W) return false;
			if (hit.strip >= 0)
			{
				(void)app.select_cut_strip((usz)hit.actor, (usz)hit.strip);
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
			if (over != self.lit || hit.actor != self.lit_actor)
			{
				self.lit = over;
				self.lit_actor = hit.actor;
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

// Whether a press on a timeline is in flight: a rebuild then would drop the widget holding it.
fn bool cut_timeline_busy(Ui* ui)
{
	bool busy;
	ui.@each(CutsceneTimeline; timeline)
	{
		CutsceneTimeline* it = timeline.widget_as(CutsceneTimeline);
		if (it.holding || it.scrubbing) busy = true;
	};
	return busy;
}

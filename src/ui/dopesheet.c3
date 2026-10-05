<*
 The dopesheet: a ruler, a playhead, and a lane of keys per joint.

 	`@node((Timeline) { .lanes = lanes, .marks = marks, .duration = clip.duration,`
 	`                   .playhead = t, .on_scrub = &anim_seek, .style = TIMELINE_STYLE });`

 **A widget rather than a composition**, because the three things it does — paint
 a grid, hit-test markers, and drag them — are none of them expressible as a tree
 of `Row`s and `Button`s. Everything around it that *is* expressible is left to
 `animation_view.c3`: the transport, the clip list and the buttons under the
 sheet are ordinary rows there.

 **And in crig rather than in cui**, unlike the other widgets crig draws with.
 The project's rule is to push reusable widgets down into the library, and this
 one looked like a candidate — a lane is a name and a marker is a `(lane,
 position)` pair, with nothing rig-shaped in the types. But the *shape of the
 problem* is animation: a ruler in seconds, a playhead you scrub, keys you drag
 between them. cui is layout, input and paint primitives, and a base widget that
 only ever has one caller is a dependency pointing the wrong way. It lives with
 the pane that uses it.

 **The caller owns the data and the meaning of a drag.** `marks` is borrowed for
 the life of the element, the widget never edits it, and a drag reports where the
 pointer went — the caller rebuilds the clip and hands back new marks. That is
 what lets every timeline edit be "replace the whole clip", which is what makes
 each one a single undo entry.

 `on_scrub` is every position a playhead drag passes through, so the figure can
 follow the pointer live.
*>
module crig;

import cui;
import cui::widgets;
import std::core::string;
import std::math;
import std::math::vector;

<*
 One lane of the sheet: a row with a name.

 `TreeRow`'s shape and its conventions — strings borrowed, `dimmed` for a row
 that is present but not currently meaningful, which crig uses for a joint the
 clip drives that the open rig does not have.
*>
struct TimelineLane
{
	String label; // borrowed; must outlive the element
	String trailing; // borrowed; drawn right-aligned in the gutter, may be empty
	bool dimmed;
	String joint; // empty for the summary Poses lane
	AnimChannels channel;
	// Levels to indent the label by, so rows read as the tree they come from.
	uint depth;
	// A contact lane: thinner, holding bars rather than keys.
	bool contact;
}

<*
 One marker: which lane it is in, and where along the axis.

 A flat array rather than a list per lane, because that is the shape the data
 usually has — crig's keyframes are a list of times each naming some joints — and
 because one array is one borrow to keep valid.
*>
struct TimelineMark
{
	usz lane;
	float at;
	bool selected;
	// Meaning travels with a marker so filtered/reordered channel rows never
	// have to reconstruct it from a global flat index. Empty/BOTH is a summary
	// pose marker.
	String joint;
	AnimChannels channel;
	// How this key leaves for the next one in its lane, which sets its shape
	// (see `paint_key`). A held key also draws a bar across the span it holds,
	// so a frozen channel reads as authored rather than as a curve that failed
	// to move. INHERIT is a mix, drawn as a diamond.
	AnimInterpolation curve;
}

<*
 A place on the ruler worth looking at, such as an issue Check found. Drawn as
 a small flag on the ruler with a faint line down the lanes; pressing it
 reports its index through `on_flag`.
*>
struct TimelineFlag
{
	float at;
}

<*
 A span on a contact lane, such as when a foot is planted. `window` is the
 caller's; a window drawn in two pieces across a loop's seam gives both the
 same one, and an `open_` end is the seam rather than a grabbable edge.
*>
struct TimelineBar
{
	usz lane;
	float from;
	float to;
	usz window;
	bool open_from;
	bool open_to;
}

// Which part of a bar a drag holds.
enum TimelineGrip : char
{
	MOVE,
	FROM,
	TO,
}

struct TimelineStyle
{
	Color gutter; // behind the lane names
	Color lane; // a lane's own strip
	Color lane_alt; // every other one, so long rows stay readable across
	Color ruler; // the strip along the top
	Color grid; // the vertical ticks
	Color text;
	Color dim_text;
	Color mark;
	Color mark_hover;
	Color mark_selected;
	Color hold; // the bar a held key draws to the next
	Color playhead;
	Color flag; // a ruler flag and its line
	Color contact; // a contact bar
	FontId font; // 0 = the first loaded font
	float text_size;
	float lane_height;
	float ruler_height;
	float gutter_width; // column for the names; 0 = no gutter
	float mark_radius;
	float playhead_width;
	float pad_x; // inside the track, so a marker at 0 is not half off the edge
	float indent; // per level of `TimelineLane.depth`, in the gutter
}

// Deeper than this and a name has lost the room it needs; a hand's finger
// joints sit seven levels down on a humanoid and still have to be legible.
const uint TIMELINE_INDENT_LEVELS = 4;

<*
 The fallback for a sheet given no style.

 crig's own `TIMELINE_STYLE` in `theme.c3`, rather than a palette of this file's
 own. A library widget carries its own defaults because it cannot see the
 application's; this one lives in the application, so a second set of colours
 here would be a copy of the theme that drifts from it.
*>
fn TimelineStyle TimelineStyle.resolved(self)
{
	return self.lane_height > 0 ? self : TIMELINE_STYLE;
}

alias OnTimelineScrub = fn void(Ui* ui, float at);
alias OnTimelineMark = fn void(Ui* ui, TimelineMark mark, bool toggle);
// A Ctrl+Shift press on a marker: extend the selection to it. Distinct from
// `OnTimelineMark` because a range click carries no per-key toggle — it always
// selects the span from the caller's anchor to this marker.
alias OnTimelineMarkExtend = fn void(Ui* ui, TimelineMark mark);
alias OnTimelineContext = fn void(Ui* ui, TimelineMark mark, Vec2 at);
// A right press on the sheet that landed on no marker: the time under the
// pointer, snapped as a scrub would be, and where on screen it happened.
alias OnTimelineSpace = fn void(Ui* ui, float at, Vec2 pixel);
alias OnTimelineMarkDrag = fn void(Ui* ui, TimelineMark mark, float to, bool done);
alias OnTimelineRange = fn void(Ui* ui, TimelineLane[] lanes, usz first_lane, usz last_lane,
	float from, float to, bool additive);
alias OnTimelineView = fn void(Ui* ui, float zoom, float start);
alias OnTimelineFlag = fn void(Ui* ui, usz index);
// A bar was dragged: `delta` seconds on the edge `grip` names, or on both.
alias OnTimelineBarEdit = fn void(Ui* ui, TimelineBar bar, TimelineGrip grip, float delta);
// A drag on empty contact lane drew a new span.
alias OnTimelineBarAdd = fn void(Ui* ui, TimelineLane lane, float from, float to);
alias OnTimelineBarContext = fn void(Ui* ui, TimelineBar bar, Vec2 pixel);
alias OnTimelineLaneContext = fn void(Ui* ui, TimelineLane lane, float at, Vec2 pixel);

// How near an edge a press grabs it rather than the whole bar, in pixels.
const float TIMELINE_BAR_GRIP = 5.0;
// A contact lane's height against an ordinary one.
const float TIMELINE_CONTACT_SCALE = 0.75;

// How wide a ruler flag is either side of its time, and how near a press has to be.
const float TIMELINE_FLAG_RADIUS = 5.0;

<*
 The flag under a point on the ruler, or -1.
*>
fn sz Timeline.flag_at(&self, Element* elem, Vec2 pos)
{
	TimelineStyle s = self.style.resolved();
	if (pos.y > s.ruler_height || self.duration <= 0.0f) return -1;
	sz found = -1;
	float closest = TIMELINE_FLAG_RADIUS + 2.0f;
	foreach (usz i, flag : self.flags)
	{
		if (!self.visible_time(flag.at)) continue;
		float dx = math::abs(pos.x - self.x_of(elem, flag.at));
		if (dx <= closest) { closest = dx; found = (sz)i; }
	}
	return found;
}

// Nothing is hovered or held. Indices are stored one-based so that zero can mean
// "none" — the encoding `Tree` and `FileBrowser` already use for the same job.
const int TIMELINE_NONE = 0;

<*
 The sheet.

 `duration` is the axis, from 0 to it. A zero or negative one makes the widget
 inert rather than dividing by it: a clip with no length is a real state, and
 drawing an empty ruler for it is the honest picture.
*>
struct Timeline (Widget)
{
	TimelineLane[] lanes; // borrowed for the life of the element
	TimelineMark[] marks; // borrowed; any order
	TimelineFlag[] flags; // borrowed; drawn on the ruler
	OnTimelineFlag on_flag; // a flag was pressed
	TimelineBar[] bars; // borrowed; drawn in contact lanes
	OnTimelineBarEdit on_bar_edit;
	OnTimelineBarAdd on_bar_add;
	OnTimelineBarContext on_bar_context;
	OnTimelineLaneContext on_lane_context;
	float duration;
	float playhead;
	int fps; // 0 retains the seconds ruler
	float zoom; // <= 1 fits the entire clip
	float view_start;
	OnTimelineView on_view;

	// What a drag lands on, in seconds; 0 is continuous. Quantising here rather
	// than in the caller keeps the marker under the pointer while it snaps.
	float snap;

	OnTimelineScrub on_scrub; // live, every position the playhead passes through
	OnTimelineMark on_mark; // a marker was pressed
	OnTimelineMarkExtend on_mark_range; // a marker was Ctrl+Shift-pressed: extend to it
	OnTimelineContext on_context; // a marker was right-pressed
	OnTimelineSpace on_space_context; // a right press off every marker
	OnTimelineMarkDrag on_mark_drag; // a marker is being moved; `done` on release
	OnTimelineRange on_range; // an empty-lane drag selected this time range
	OnTimelineMark on_cancel_drag; // Escape restored a held marker without committing
	OnClick on_copy;
	OnClick on_paste;
	OnClick on_delete;

	TimelineStyle style;
	Vec2 size; // per axis: 0 = fill the width, and as tall as the lanes need

	// What the pointer is doing. The widget owns this; what it means is the
	// caller's.
	int lit; // hovered marker, one-based
	int held; // marker being dragged, one-based
	float mark_press_x;
	float drag_to;
	bool mark_dragged;
	bool mark_toggle;
	bool scrubbing;
	bool box_candidate;
	bool boxing;
	bool box_additive;
	Vec2 box_from;
	Vec2 box_to;
	int bar_held; // one-based
	TimelineGrip bar_grip;
	float bar_press_x;
	float bar_delta;
	bool bar_dragged;
	bool adding; // a press on an empty contact lane that may draw a bar
	bool add_drawn;
	usz add_lane;
	float add_from_x;
	float add_to_x;
}

<*
 How tall the sheet wants to be: the ruler plus a row per lane.
*>
fn float Timeline.wanted_height(&self)
{
	TimelineStyle s = self.style.resolved();
	return s.ruler_height + self.lanes_height(self.lanes.len);
}

// How tall one lane is: a contact lane is thinner.
fn float Timeline.lane_h(&self, usz lane)
{
	TimelineStyle s = self.style.resolved();
	if (lane < self.lanes.len && self.lanes[lane].contact) return s.lane_height * TIMELINE_CONTACT_SCALE;
	return s.lane_height;
}

// How tall the first `count` lanes are together.
fn float Timeline.lanes_height(&self, usz count)
{
	float h = 0;
	for (usz i = 0; i < count && i < self.lanes.len; i++) h += self.lane_h(i);
	return h;
}

// The top of a lane's strip, in element-local pixels.
fn float Timeline.lane_top(&self, usz lane)
{
	return self.style.resolved().ruler_height + self.lanes_height(lane);
}

fn Vec2 Timeline.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float w = self.size.x > 0 ? self.size.x : constraints.max.x;
	float h = self.size.y > 0 ? self.size.y : self.wanted_height();
	return constraints.constrain({ w, h });
}

<*
 Where the track starts and how wide it is, in element-local pixels.

 One arithmetic shared by the paint and the hit test, so the two cannot disagree
 about where a marker is — the same bargain `Slider.track_span` strikes.

 @return `x = the left edge of the track, y = its width.`
*>
fn Vec2 Timeline.track_span(&self, Element* elem)
{
	TimelineStyle s = self.style.resolved();
	float left = s.gutter_width + s.pad_x;
	float width = math::max(elem.size.x - left - s.pad_x, 0.0f);
	return { left, width };
}

<*
 The pixel a position on the axis sits at.
*>
fn float Timeline.x_of(&self, Element* elem, float at)
{
	if (self.duration <= 0.0f) return self.track_span(elem).x;
	Vec2 span = self.track_span(elem);
	return span.x + span.y * (at - self.view_start) / self.visible_duration();
}

fn float Timeline.visible_duration(&self) => self.duration / math::max(self.zoom, 1.0f);

fn bool Timeline.visible_time(&self, float at)
{
	return at >= self.view_start && at <= self.view_start + self.visible_duration();
}

<*
 The position a pixel means, clamped to the axis and snapped if asked.

 The inverse of `x_of`, so the two round-trip: a marker drawn at a pixel is the
 marker a press on that pixel finds.
*>
fn float Timeline.at_of(&self, Element* elem, float x)
{
	float at = self.raw_at_of(elem, x);
	if (self.snap > 0.0f) at = math::round(at / self.snap) * self.snap;
	return math::clamp(at, 0.0f, self.duration);
}

// Pointer-to-time conversion without frame snapping. A selection band's edge
// follows the pointer itself, so its inclusion test must use that same edge.
fn float Timeline.raw_at_of(&self, Element* elem, float x)
{
	if (self.duration <= 0.0f) return 0.0f;
	Vec2 span = self.track_span(elem);
	if (span.y <= 0.0f) return 0.0f;

	float at = self.view_start + math::clamp((x - span.x) / span.y, 0.0f, 1.0f) * self.visible_duration();
	return math::clamp(at, 0.0f, self.duration);
}

// The middle of a lane's strip, in element-local pixels.
fn float Timeline.lane_y(&self, usz lane)
{
	return self.lane_top(lane) + self.lane_h(lane) * 0.5f;
}

<*
 The marker under a point, one-based, or `TIMELINE_NONE`.

 Nearest wins rather than first, so overlapping markers in one lane resolve to
 the one actually being aimed at. The reach is the marker's radius plus a little:
 these are small targets and a pointer is not a pixel.
*>
fn int Timeline.mark_at(&self, Element* elem, Vec2 pos)
{
	TimelineStyle s = self.style.resolved();
	float reach = s.mark_radius + 3.0f;

	int found = TIMELINE_NONE;
	float closest = reach;
	foreach (usz i, mark : self.marks)
	{
		if (mark.lane >= self.lanes.len) continue;
		if (!self.visible_time(mark.at)) continue;

		float dy = math::abs(pos.y - self.lane_y(mark.lane));
		if (dy > self.lane_h(mark.lane) * 0.5f) continue;

		float dx = math::abs(pos.x - self.x_of(elem, mark.at));
		if (dx <= closest)
		{
			closest = dx;
			found = (int)i + 1;
		}
	}
	return found;
}

fn void Timeline.paint(&self, Element* elem, Painter* painter) @dynamic
{
	TimelineStyle s = self.style.resolved();
	Vec2 span = self.track_span(elem);

	// The ruler, and the gutter beside it.
	painter.rect({ 0, 0 }, { elem.size.x, s.ruler_height }, { .color = s.ruler });
	if (s.gutter_width > 0)
	{
		painter.rect({ 0, 0 }, { s.gutter_width, elem.size.y }, { .color = s.gutter });
	}

	// Lane strips, alternating so a row can be followed across a wide sheet.
	foreach (usz i, lane : self.lanes)
	{
		float y = self.lane_top(i);
		float lh = self.lane_h(i);
		painter.rect({ s.gutter_width, y }, { elem.size.x - s.gutter_width, lh },
			{ .color = (i & 1) == 0 ? s.lane : s.lane_alt });

		if (s.gutter_width > 0)
		{
			Color ink = lane.dimmed || lane.contact ? s.dim_text : s.text;
			float indent = s.indent * (float)math::min(lane.depth, TIMELINE_INDENT_LEVELS);
			float label_room = s.gutter_width - s.pad_x * 2.0f - indent;
			if (lane.trailing.len > 0)
			{
				Vec2 measured = elem.ui.text.measure(s.font, lane.trailing, s.text_size);
				label_room -= measured.x + s.pad_x;
				painter.text(
					{ s.gutter_width - s.pad_x - measured.x, y + (lh - s.text_size) * 0.5f },
					lane.trailing,
					{ .font = s.font, .size = s.text_size, .color = s.dim_text });
			}
			if (label_room > 0)
			{
				painter.text({ s.pad_x + indent, y + (lh - s.text_size) * 0.5f },
					elide(elem, lane.label, label_room, s.text_size),
					{ .font = s.font, .size = s.text_size, .color = ink });
			}
		}
	}

	// Frame ticks adapt to the visible range without becoming a hatch pattern.
	if (self.duration > 0.0f && span.y > 0.0f)
	{
		float step = self.visible_duration() / 4.0f;
		if (self.fps > 0)
		{
			float ticks = math::max(1.0f, math::floor(span.y / 80.0f));
			step = math::max(1.0f, math::ceil(self.visible_duration() * (float)self.fps / ticks)) / (float)self.fps;
		}
		float first = math::ceil(self.view_start / step) * step;
		for (int i = 0; i < 256; i++)
		{
			float at = first + (float)i * step;
			if (at > self.view_start + self.visible_duration() + 0.00001f) break;
			float x = self.x_of(elem, at);
			painter.line({ x, s.ruler_height }, { x, elem.size.y }, 1.0, s.grid);

			char[16] buffer;
			String label = self.fps > 0
				? string::bformat(buffer[..], "%.0ff", math::round(at * (float)self.fps))
				: string::bformat(buffer[..], "%.2f", at);
			Vec2 measured = elem.ui.text.measure(s.font, label, s.text_size);
			// The last one pulled in, so the axis end does not hang off the edge.
			float text_x = math::min(x + 2.0f, elem.size.x - measured.x);
			painter.text({ text_x, (s.ruler_height - s.text_size) * 0.5f }, label,
				{ .font = s.font, .size = s.text_size, .color = s.dim_text });
		}
	}

	// What a held key holds: a bar from it to the next key in its lane, or to
	// the end of the clip when it is the last. Under the markers, so a diamond
	// at either end sits on top of it.
	if (self.duration > 0.0f)
	{
		foreach (mark : self.marks)
		{
			if (mark.curve != HOLD || mark.lane >= self.lanes.len) continue;
			float until = self.duration;
			foreach (other : self.marks)
			{
				if (other.lane != mark.lane || other.at <= mark.at) continue;
				until = math::min(until, other.at);
			}
			if (until <= mark.at) continue;
			float from = math::max(mark.at, self.view_start);
			float to = math::min(until, self.view_start + self.visible_duration());
			if (to <= from) continue;
			float y = self.lane_y(mark.lane);
			painter.line({ self.x_of(elem, from), y }, { self.x_of(elem, to), y }, 2.0f, s.hold);
		}
	}

	self.paint_bars(elem, painter);

	// The markers. One under the playhead is ringed in the playhead's colour:
	// the answer to "is this frame a saved pose" read off the lane rather than
	// off the status line, which is the question every key press is about.
	foreach (usz i, mark : self.marks)
	{
		if (mark.lane >= self.lanes.len) continue;
		if (!self.visible_time(mark.at)) continue;

		Color ink = s.mark;
		if (mark.selected) { ink = s.mark_selected; }
		else if (self.lit == (int)i + 1 || self.held == (int)i + 1) { ink = s.mark_hover; }

		Vec2 at = { self.x_of(elem, mark.at), self.lane_y(mark.lane) };
		if (math::abs(mark.at - self.playhead) < ANIM_SAME_TIME)
		{
			paint_key(painter, at, s.mark_radius + 2.5f, s.playhead, mark.curve);
			paint_key(painter, at, s.mark_radius + 1.0f, (i & 1) == 0 ? s.lane : s.lane_alt, mark.curve);
		}
		paint_key(painter, at, s.mark_radius, ink, mark.curve);
	}
	if (self.mark_dragged && self.held != TIMELINE_NONE)
	{
		usz anchor = (usz)(self.held - 1);
		if (anchor < self.marks.len)
		{
			float delta = self.drag_to - self.marks[anchor].at;
			foreach (usz i, mark : self.marks)
			{
				if (!mark.selected && i != anchor) continue;
				float ghost = mark.at + delta;
				if (ghost < 0 || ghost > self.duration || !self.visible_time(ghost)) continue;
				paint_diamond(painter, { self.x_of(elem, ghost), self.lane_y(mark.lane) },
					s.mark_radius + 1.0f, s.mark_selected);
			}
		}
	}

	// An empty-lane drag is a time-range selection. Keep it as an outline so
	// keys and the alternating track rows remain legible underneath it.
	if (self.boxing)
	{
		float left = math::min(self.box_from.x, self.box_to.x);
		float right = math::max(self.box_from.x, self.box_to.x);
		usz first_lane = self.lane_at(self.box_from.y);
		usz last_lane = self.lane_at(self.box_to.y);
		float top = self.lane_top(math::min(first_lane, last_lane));
		float bottom = self.lane_top(math::max(first_lane, last_lane) + 1);
		painter.line({ left, top }, { right, top }, 1.0f, s.mark_selected);
		painter.line({ right, top }, { right, bottom }, 1.0f, s.mark_selected);
		painter.line({ right, bottom }, { left, bottom }, 1.0f, s.mark_selected);
		painter.line({ left, bottom }, { left, top }, 1.0f, s.mark_selected);
	}

	// Flags on the ruler, with a faint line down the lanes so the moment they
	// name can be read against the keys.
	foreach (flag : self.flags)
	{
		if (self.duration <= 0.0f || !self.visible_time(flag.at)) continue;
		float x = self.x_of(elem, flag.at);
		Color faint = s.flag;
		faint.a *= 0.35f;
		painter.line({ x, s.ruler_height }, { x, elem.size.y }, 1.0f, faint);
		float r = TIMELINE_FLAG_RADIUS;
		for (float row = 0; row < r * 1.6f; row += 1.0f)
		{
			float half = r * (1.0f - row / (r * 1.6f));
			painter.line({ x - half, s.ruler_height - 2.0f - row }, { x + half, s.ruler_height - 2.0f - row }, 1.0f, s.flag);
		}
	}

	// The playhead last, over everything, because it is the thing being aimed.
	if (self.duration > 0.0f && self.visible_time(self.playhead))
	{
		float x = self.x_of(elem, self.playhead);
		painter.line({ x, 0 }, { x, elem.size.y }, s.playhead_width, s.playhead);
	}
}

<*
 A key in the shape of how it leaves for the next one: a circle eases (Smooth),
 a diamond moves in a straight line (Linear, and a mix), a square holds (Step).
*>
fn void paint_key(Painter* painter, Vec2 at, float r, Color color, AnimInterpolation curve)
{
	switch (curve)
	{
		case AUTO: painter.circle(at, r * 0.85f, { .color = color });
		case HOLD: painter.rect(at - (Vec2){ r * 0.75f, r * 0.75f }, { r * 1.5f, r * 1.5f }, { .color = color });
		default: paint_diamond(painter, at, r, color);
	}
}

// A four-line diamond: the painter has no polygon, so a rotated square is drawn
// as stacked spans.
fn void paint_diamond(Painter* painter, Vec2 at, float r, Color color)
{
	// Filled by stacking horizontal spans, three of them, which at this size is
	// indistinguishable from a solid diamond and costs less than a scanline loop.
	painter.line({ at.x - r, at.y }, { at.x + r, at.y }, 1.5, color);
	painter.line({ at.x - r * 0.55f, at.y - r * 0.45f }, { at.x + r * 0.55f, at.y - r * 0.45f }, 1.5, color);
	painter.line({ at.x - r * 0.55f, at.y + r * 0.45f }, { at.x + r * 0.55f, at.y + r * 0.45f }, 1.5, color);
	painter.line({ at.x, at.y - r }, { at.x, at.y + r }, 1.5, color);
}

fn void Timeline.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) return;
	if (self.lit == TIMELINE_NONE) return;
	self.lit = TIMELINE_NONE;
	elem.request_paint();
}

<*
 A press on a marker drags it; a press anywhere else on the track moves the
 playhead.

 The gutter is declined rather than swallowed, so a sheet can sit inside
 something that scrolls: a press on a lane's *name* is not a press on the sheet.

 @return `True for a press that starts something, and everything that follows it.`
*>
fn bool Timeline.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	TimelineStyle s = self.style.resolved();

	switch (event.kind)
	{
		case SCROLL:
			if (self.duration <= 0 || self.held != TIMELINE_NONE || self.scrubbing || self.bar_held != TIMELINE_NONE) return false;
			float delta = event.scroll_x != 0 ? event.scroll_x : event.scroll;
			if (elem.ui.input.ctrl_down())
			{
				Vec2 span = self.track_span(elem);
				float fraction = span.y > 0 ? math::clamp((event.pos.x - span.x) / span.y, 0.0f, 1.0f) : 0;
				float anchor = self.view_start + fraction * self.visible_duration();
				self.zoom = math::clamp(math::max(self.zoom, 1.0f) * (delta > 0 ? 1.25f : 0.8f), 1.0f, 32.0f);
				self.view_start = anchor - fraction * self.visible_duration();
			}
			else
			{
				if (self.zoom <= 1) return false;
				self.view_start += delta * self.visible_duration() * 0.1f;
			}
			self.view_start = math::clamp(self.view_start, 0.0f, self.duration - self.visible_duration());
			self.lit = TIMELINE_NONE;
			if (self.on_view) self.on_view(elem.ui, self.zoom, self.view_start);
			elem.request_paint();
			return true;
		case PRESS:
			if (event.button == MouseButton.RIGHT)
			{
				if (event.pos.x >= s.gutter_width && self.duration > 0.0f)
				{
					TimelineGrip grip;
					int bar = self.bar_at(elem, event.pos, &grip);
					if (bar != TIMELINE_NONE)
					{
						if (!self.on_bar_context) return false;
						self.on_bar_context(elem.ui, self.bars[(usz)(bar - 1)], elem.absolute + event.pos);
						return true;
					}
					usz contact_lane;
					if (self.contact_lane_at(event.pos, &contact_lane))
					{
						if (!self.on_lane_context) return false;
						self.on_lane_context(elem.ui, self.lanes[contact_lane], self.at_of(elem, event.pos.x), elem.absolute + event.pos);
						return true;
					}
				}
				int hit = self.mark_at(elem, event.pos);
				if (hit != TIMELINE_NONE)
				{
					if (!self.on_context) return false;
					self.on_context(elem.ui, self.marks[(usz)(hit - 1)], elem.absolute + event.pos);
					return true;
				}
				// Off every marker, the press names a time rather than a key — where
				// copied keys would be pasted. Snapped the way a scrub is, so the
				// menu's paste lands on the frame the ruler shows.
				if (!self.on_space_context || event.pos.x < s.gutter_width || self.duration <= 0.0f) return false;
				self.on_space_context(elem.ui, self.at_of(elem, event.pos.x), elem.absolute + event.pos);
				return true;
			}
			if (event.button != MouseButton.LEFT) return false;
			if (event.pos.x < s.gutter_width) return false;
			if (self.duration <= 0.0f) return false;
			if (self.on_flag)
			{
				sz flag = self.flag_at(elem, event.pos);
				if (flag >= 0)
				{
					self.on_flag(elem.ui, (usz)flag);
					return true;
				}
			}

			TimelineGrip grip;
			int bar = self.bar_at(elem, event.pos, &grip);
			if (bar != TIMELINE_NONE)
			{
				self.bar_held = bar;
				self.bar_grip = grip;
				self.bar_press_x = event.pos.x;
				self.bar_delta = 0;
				self.bar_dragged = false;
				elem.request_paint();
				return true;
			}

			int hit = self.mark_at(elem, event.pos);
			if (hit != TIMELINE_NONE)
			{
				self.held = hit;
				self.mark_press_x = event.pos.x;
				self.drag_to = self.marks[(usz)(hit - 1)].at;
				self.mark_dragged = false;
				elem.request_paint();
				bool shift = elem.ui.input.shift_down();
				bool ctrl = elem.ui.input.ctrl_down();
				self.mark_toggle = shift; // Ctrl+Shift holds shift too, so a range press never drags.
				// Ctrl+Shift on a key extends the selection from the last-clicked key
				// to this one; plain Shift still toggles the single key it lands on.
				if (ctrl && shift && self.on_mark_range)
				{
					self.on_mark_range(elem.ui, self.marks[(usz)(hit - 1)]);
				}
				else if (self.on_mark) self.on_mark(elem.ui, self.marks[(usz)(hit - 1)], shift);
				return true;
			}

			self.scrubbing = true;
			usz add_lane;
			self.adding = self.on_bar_add && self.contact_lane_at(event.pos, &add_lane);
			if (self.adding)
			{
				self.add_lane = add_lane;
				self.add_drawn = false;
				self.add_from_x = event.pos.x;
				self.add_to_x = event.pos.x;
			}
			self.box_candidate = !self.adding && event.pos.y >= s.ruler_height;
			self.box_additive = elem.ui.input.shift_down();
			self.box_from = event.pos;
			self.box_to = event.pos;
			self.take(elem, event.pos.x);
			return true;

		case MOVE:
			if (self.bar_held != TIMELINE_NONE)
			{
				if (math::abs(event.pos.x - self.bar_press_x) >= 3.0f) self.bar_dragged = true;
				self.bar_delta = self.at_of(elem, event.pos.x) - self.at_of(elem, self.bar_press_x);
				elem.request_paint();
				return true;
			}
			if (self.adding && self.scrubbing)
			{
				if (math::abs(event.pos.x - self.add_from_x) >= 3.0f) self.add_drawn = true;
				if (self.add_drawn)
				{
					self.add_to_x = event.pos.x;
					elem.request_paint();
					return true;
				}
				self.take(elem, event.pos.x);
				return true;
			}
			if (self.held != TIMELINE_NONE)
			{
				if (self.mark_toggle) return true;
				if (math::abs(event.pos.x - self.mark_press_x) >= 3.0f) self.mark_dragged = true;
				self.drag_to = self.at_of(elem, event.pos.x);
				elem.request_paint();
				if (self.mark_dragged && self.on_mark_drag)
				{
					self.on_mark_drag(elem.ui, self.marks[(usz)(self.held - 1)], self.at_of(elem, event.pos.x), false);
				}
				return true;
			}
			if (self.scrubbing)
			{
				if (self.box_candidate && math::abs(event.pos.x - self.box_from.x) >= 3.0f)
				{
					self.boxing = true;
					self.box_to = event.pos;
					elem.request_paint();
					return true;
				}
				if (self.boxing)
				{
					self.box_to = event.pos;
					elem.request_paint();
					return true;
				}
				self.take(elem, event.pos.x);
				return true;
			}

			// Hover, so a marker lights before it is grabbed.
			int over = event.pos.x < s.gutter_width ? TIMELINE_NONE : self.mark_at(elem, event.pos);
			if (over != self.lit)
			{
				self.lit = over;
				elem.request_paint();
			}
			return false;

		case RELEASE:
			if (event.button != MouseButton.LEFT) return false;

			if (self.bar_held != TIMELINE_NONE)
			{
				TimelineBar bar = self.bars[(usz)(self.bar_held - 1)];
				bool moved = self.bar_dragged;
				float delta = self.at_of(elem, event.pos.x) - self.at_of(elem, self.bar_press_x);
				self.bar_held = TIMELINE_NONE;
				self.bar_dragged = false;
				self.bar_delta = 0;
				elem.request_paint();
				if (moved && math::abs(delta) > 1e-6f && self.on_bar_edit)
				{
					self.on_bar_edit(elem.ui, bar, self.bar_grip, delta);
				}
				else if (!moved)
				{
					self.take(elem, event.pos.x);
				}
				return true;
			}
			if (self.adding)
			{
				bool drawn = self.add_drawn;
				self.adding = false;
				self.add_drawn = false;
				self.scrubbing = false;
				elem.request_paint();
				if (drawn && self.on_bar_add)
				{
					float from = self.at_of(elem, math::min(self.add_from_x, event.pos.x));
					float to = self.at_of(elem, math::max(self.add_from_x, event.pos.x));
					if (to > from && self.add_lane < self.lanes.len) self.on_bar_add(elem.ui, self.lanes[self.add_lane], from, to);
				}
				return true;
			}

			if (self.held != TIMELINE_NONE)
			{
				usz which = (usz)(self.held - 1);
				self.held = TIMELINE_NONE;
				elem.request_paint();
				// The committing report, which is where a caller closes its undo
				// group — `Slider.on_commit`'s job, and the reason the live one
				// above must not be doing it.
				if (self.mark_dragged && self.on_mark_drag)
				{
					self.on_mark_drag(elem.ui, self.marks[which], self.at_of(elem, event.pos.x), true);
				}
				self.mark_dragged = false;
				self.mark_toggle = false;
				return true;
			}
			if (!self.scrubbing) return false;

			self.scrubbing = false;
			self.box_candidate = false;
			if (self.boxing)
			{
				self.boxing = false;
				self.box_to = event.pos;
				if (self.on_range)
				{
					usz first_lane = self.lane_at(self.box_from.y);
					usz last_lane = self.lane_at(self.box_to.y);
					self.on_range(elem.ui, self.lanes, math::min(first_lane, last_lane),
						math::max(first_lane, last_lane), self.raw_at_of(elem, self.box_from.x),
						self.raw_at_of(elem, self.box_to.x), self.box_additive);
				}
				elem.request_paint();
			}
			return true;

		default:
			return false;
	}
}

// The position at a pixel, taken and reported. Silent when the pixel means the
// position the playhead already has: a snapped drag passes through the same
// value many times, and a caller re-posing the figure on every one of them
// would do the work sixty times for one frame of motion.
fn bool Timeline.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;
	if (event.key == Key.ESCAPE && (self.bar_held != TIMELINE_NONE || self.adding))
	{
		self.bar_held = TIMELINE_NONE;
		self.bar_dragged = false;
		self.bar_delta = 0;
		self.adding = false;
		self.add_drawn = false;
		self.scrubbing = false;
		elem.request_paint();
		return true;
	}
	if (event.key == Key.ESCAPE && (self.scrubbing || self.held != TIMELINE_NONE))
	{
		if (self.held != TIMELINE_NONE && self.mark_dragged && self.on_cancel_drag)
		{
			self.on_cancel_drag(elem.ui, self.marks[(usz)(self.held - 1)], false);
		}
		self.scrubbing = false;
		self.box_candidate = false;
		self.boxing = false;
		self.held = TIMELINE_NONE;
		self.mark_dragged = false;
		self.mark_toggle = false;
		elem.request_paint();
		return true;
	}
	if (self.scrubbing || self.held != TIMELINE_NONE || self.bar_held != TIMELINE_NONE) return false;
	bool control = elem.ui.input.ctrl_down();
	if (control && event.key == Key.C && self.on_copy) { self.on_copy(elem.ui); return true; }
	if (control && event.key == Key.V && self.on_paste) { self.on_paste(elem.ui); return true; }
	if (event.key == Key.DELETE && self.on_delete) { self.on_delete(elem.ui); return true; }
	return false;
}

fn void Timeline.take(&self, Element* elem, float x)
{
	float at = self.at_of(elem, x);
	if (at == self.playhead) return;

	self.playhead = at;
	elem.request_paint();
	if (self.on_scrub) self.on_scrub(elem.ui, at);
}

fn usz Timeline.lane_at(&self, float y)
{
	if (self.lanes.len == 0) return 0;
	float top = self.style.resolved().ruler_height;
	foreach (usz i, lane : self.lanes)
	{
		top += self.lane_h(i);
		if (y < top) return i;
	}
	return self.lanes.len - 1;
}

// Whether a point is inside a contact lane's strip, and which.
fn bool Timeline.contact_lane_at(&self, Vec2 pos, usz* lane)
{
	TimelineStyle s = self.style.resolved();
	if (pos.y < s.ruler_height || pos.y >= s.ruler_height + self.lanes_height(self.lanes.len)) return false;
	usz at = self.lane_at(pos.y);
	if (at >= self.lanes.len || !self.lanes[at].contact) return false;
	*lane = at;
	return true;
}

<*
 The bar under a point, one-based, or `TIMELINE_NONE`, and which part of it:
 an edge within `TIMELINE_BAR_GRIP` pixels, else the whole bar.
*>
fn int Timeline.bar_at(&self, Element* elem, Vec2 pos, TimelineGrip* grip)
{
	usz lane;
	if (!self.contact_lane_at(pos, &lane)) return TIMELINE_NONE;
	int found = TIMELINE_NONE;
	float best = TIMELINE_BAR_GRIP + 1.0f;
	foreach (usz i, bar : self.bars)
	{
		if (bar.lane != lane) continue;
		float left = self.x_of(elem, bar.from);
		float right = self.x_of(elem, bar.to);
		if (pos.x < left - TIMELINE_BAR_GRIP || pos.x > right + TIMELINE_BAR_GRIP) continue;
		float to_left = bar.open_from ? 1e9f : math::abs(pos.x - left);
		float to_right = bar.open_to ? 1e9f : math::abs(pos.x - right);
		// Edges win when near, the nearer one; a narrow bar keeps its middle.
		float edge = math::min(to_left, to_right);
		if (edge <= TIMELINE_BAR_GRIP && (right - left > TIMELINE_BAR_GRIP * 3.0f || pos.x < left || pos.x > right))
		{
			if (edge < best)
			{
				best = edge;
				found = (int)i + 1;
				*grip = to_left <= to_right ? TimelineGrip.FROM : TimelineGrip.TO;
			}
			continue;
		}
		if (pos.x >= left && pos.x <= right && found == TIMELINE_NONE)
		{
			found = (int)i + 1;
			*grip = MOVE;
		}
	}
	return found;
}

// A bar as a drag in flight shows it: the held one, and on a move every piece
// of its window, shifted by the drag so far.
fn TimelineBar Timeline.shown_bar(&self, usz index)
{
	TimelineBar bar = self.bars[index];
	if (self.bar_held == TIMELINE_NONE || !self.bar_dragged) return bar;
	TimelineBar held = self.bars[(usz)(self.bar_held - 1)];
	if (bar.window != held.window || bar.lane != held.lane) return bar;
	switch (self.bar_grip)
	{
		case MOVE:
			bar.from += self.bar_delta;
			bar.to += self.bar_delta;
		case FROM:
			if (index == (usz)(self.bar_held - 1)) bar.from = math::min(bar.from + self.bar_delta, bar.to);
		case TO:
			if (index == (usz)(self.bar_held - 1)) bar.to = math::max(bar.to + self.bar_delta, bar.from);
	}
	return bar;
}

fn void Timeline.paint_bars(&self, Element* elem, Painter* painter)
{
	if (self.duration <= 0.0f) return;
	TimelineStyle s = self.style.resolved();
	float end = self.view_start + self.visible_duration();
	foreach (usz i, unused : self.bars)
	{
		TimelineBar bar = self.shown_bar(i);
		if (bar.lane >= self.lanes.len) continue;
		float from = math::max(bar.from, self.view_start);
		float to = math::min(bar.to, end);
		if (to <= from) continue;
		float top = self.lane_top(bar.lane) + 2.0f;
		float h = self.lane_h(bar.lane) - 4.0f;
		float left = self.x_of(elem, from);
		float right = self.x_of(elem, to);
		bool lit = self.bar_held == (int)i + 1;
		Color fill = s.contact;
		if (lit) fill.a = 1.0f;
		painter.rect({ left, top }, { math::max(right - left, 1.0f), h }, { .color = fill });
		// Grabbable ends drawn as darker ticks; an open end runs off at the seam.
		if (!bar.open_from && bar.from >= self.view_start) painter.line({ left + 1.0f, top }, { left + 1.0f, top + h }, 2.0f, s.text);
		if (!bar.open_to && bar.to <= end) painter.line({ right - 1.0f, top }, { right - 1.0f, top + h }, 2.0f, s.text);
	}
	if (self.adding && self.add_drawn && self.add_lane < self.lanes.len)
	{
		float left = math::min(self.add_from_x, self.add_to_x);
		float right = math::max(self.add_from_x, self.add_to_x);
		Color ghost = s.contact;
		ghost.a *= 0.5f;
		float top = self.lane_top(self.add_lane) + 2.0f;
		painter.rect({ left, top }, { right - left, self.lane_h(self.add_lane) - 4.0f }, { .color = ghost });
	}
}

<*
 The Weights card's icon buttons: a glyph in a tool-column cell, under a tooltip
 that says what it does.

 Blender's N-panel bargain. A row of named buttons and the paragraphs that
 explained them made the card taller than the view it floats in; a row of
 glyphs says the actions are there in a fifth of the room, and the words they
 had move into the tooltip, where they are read once and then out of the way.

 Composed like the tool column (`tool_column.c3`) and from its parts: cui's
 `Tooltip` around `tool_button`, with only the glyph painted here. A lit cell is
 a switch that is on (Mirror, the brush); a commit (Apply, Fix strays) keeps the
 plain cell and draws its glyph in the accent, so the two never read alike. An
 action with nothing to act on stays off the card rather than greyed — Fix
 strays appears once Find strays has something for it.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

// The glyphs are drawn a touch smaller than the tool column's, whose cells are
// the same size: there the glyph is the whole message, here a row of six reads
// as one strip, and a little air inside each cell is what separates them.
const float CARD_ICON_R = 7.0;
const float CARD_ICON_STROKE = 1.5;
const float CARD_ICON_HEAD = 3.5;

// How a cell is drawn: see the file's comment.
enum CardCell
{
	PLAIN,
	LIT,
	COMMIT,
}

enum CardGlyph
{
	APPLY_GLYPH,
	RESET_GLYPH,
	MIRROR_GLYPH,
	BRUSH_GLYPH,
	GROW_GLYPH,
	SHRINK_GLYPH,
	CLEAR_GLYPH,
	INVERT_GLYPH,
	FIND_STRAYS_GLYPH,
	FIX_STRAYS_GLYPH,
	LASSO_GLYPH,
	// The Path toolbar's.
	PEN_GLYPH,
	FROM_MOTION_GLYPH,
	SLICE_GLYPH,
	CLOSE_PATH_GLYPH,
	BAKE_GLYPH,
	MUTE_GLYPH,
	FOLLOW_GLYPH,
}

<*
 One icon button, inside the `@tree` building the card.

 @param glyph : `What the cell shows.`
 @param text : `The tooltip: what a click does, in a literal or a buffer that outlives the build.`
 @param on_click : `The action.`
 @param cell : `A switch that is on, a commit, or neither.`
 @param hint : `The keys line for the hint bar while the pointer is on the cell.`
 @return `The button, for with_id — a click on its centre is a click on the cell.`
*>
macro Element* @card_icon(CardGlyph glyph, String text, OnClick on_click, CardCell cell = PLAIN, String hint = "")
{
	// Dark ink on the lit cell, for the tool column's reason.
	Color ink = TEXT;
	if (cell == LIT) ink = DOT_OUTLINE;
	if (cell == COMMIT) ink = ACCENT;
	Element* button;
	@tree(widgets::tip(text, hint))
	{
		button = @tree(tool_button({ .checked = cell == LIT }, on_click))
		{
			@node((CardIcon) { .glyph = glyph, .ink = ink });
		};
	};
	return button;
}

struct CardIcon (Widget)
{
	CardGlyph glyph;
	Color ink;
}

fn Vec2 CardIcon.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.max;
}

// An open arrowhead at `tip`, pointing along `dir` (a unit vector).
fn void card_arrow_head(Painter* painter, Vec2 tip, Vec2 dir, Color ink) @private
{
	Vec2 back = -dir * CARD_ICON_HEAD;
	Vec2 side = { -dir.y * CARD_ICON_HEAD * 0.75f, dir.x * CARD_ICON_HEAD * 0.75f };
	painter.line(tip, tip + back + side, CARD_ICON_STROKE, ink);
	painter.line(tip, tip + back - side, CARD_ICON_STROKE, ink);
}

fn void CardIcon.paint(&self, Element* elem, Painter* painter) @dynamic
{
	Vec2 c = elem.size * 0.5f;
	float r = CARD_ICON_R;
	float w = CARD_ICON_STROKE;
	Color ink = self.ink;

	switch (self.glyph)
	{
		case APPLY_GLYPH:
			// A tick: the commit, and the one cell drawn heavier.
			Vec2 knee = c + (Vec2){ -r * 0.25f, r * 0.6f };
			painter.line(c + (Vec2){ -r * 0.85f, 0 }, knee, w * 1.4f, ink);
			painter.line(knee, c + (Vec2){ r * 0.9f, -r * 0.65f }, w * 1.4f, ink);
		case RESET_GLYPH:
			// Turning back: a circle open at the top-left whose arrow arrives at the
			// top going left — the glyph for "as it was" in every program.
			float start = -(float)math::PI * 0.5f;
			float sweep = (float)math::PI * 1.6f;
			float radius = r * 0.85f;
			painter.arc(c, radius, start, sweep, w, ink);
			card_arrow_head(painter, c + (Vec2){ 0, -radius }, { -1.0f, 0 }, ink);
		case MIRROR_GLYPH:
			// Two halves facing across a dashed axis, Blender's mirror.
			for (int i = 0; i < 3; i++)
			{
				float y = c.y - r + (float)i * r * 0.75f;
				painter.line({ c.x, y }, { c.x, y + r * 0.45f }, 1.0f, ink);
			}
			float[2] sides = { -1.0f, 1.0f };
			foreach (side : sides)
			{
				Vec2 top = c + (Vec2){ side * 2.5f, -r * 0.8f };
				Vec2 foot = c + (Vec2){ side * 2.5f, r * 0.8f };
				Vec2 point = c + (Vec2){ side * (r + 2.0f), r * 0.8f };
				painter.line(top, foot, w, ink);
				painter.line(foot, point, w, ink);
				painter.line(point, top, w, ink);
			}
		case BRUSH_GLYPH:
			// A round brush down to the left: a thin handle, the band holding the
			// bristles, and the bristles swelling and then drawn to a point.
			Vec2 along = { -0.7071f, 0.7071f };
			Vec2 grip = c - along * r;
			Vec2 band = c + along * (r * 0.05f);
			Vec2 belly = c + along * (r * 0.55f);
			painter.line(grip, band, w, ink);
			painter.line(band, band + along * (r * 0.25f), w * 2.4f, ink);
			painter.circle(belly, r * 0.36f, { .color = ink });
			painter.line(belly, c + along * (r * 1.15f), w * 1.3f, ink);
		case GROW_GLYPH:
		case SHRINK_GLYPH:
			// Four corners pulled out, or pushed in: the part one ring wider or narrower.
			bool out = self.glyph == GROW_GLYPH;
			Vec2[4] corners = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } };
			foreach (d : corners)
			{
				Vec2 near = c + d * (r * 0.25f);
				Vec2 far = c + d * (r * 0.95f);
				painter.line(near, far, w, ink);
				Vec2 tip = out ? far : near;
				float sign = out ? -1.0f : 1.0f;
				painter.line(tip, tip + (Vec2){ sign * d.x * CARD_ICON_HEAD, 0 }, w, ink);
				painter.line(tip, tip + (Vec2){ 0, sign * d.y * CARD_ICON_HEAD }, w, ink);
			}
		case CLEAR_GLYPH:
			// Nothing picked: an empty ring struck through.
			painter.circle(c, r * 0.8f, { .border_width = w, .border_color = ink });
			painter.line(c + (Vec2){ -r, r }, c + (Vec2){ r, -r }, w, ink);
		case INVERT_GLYPH:
			// Half and half: the picked islands swapped for the rest. The filled
			// half is one stroke as wide as the radius, since the painter has no fan.
			painter.circle(c, r * 0.85f, { .border_width = w, .border_color = ink });
			painter.arc(c, r * 0.425f, (float)math::PI * 0.5f, (float)math::PI, r * 0.85f, ink);
		case FIND_STRAYS_GLYPH:
			// A lens over a lone dot.
			Vec2 lens = c + (Vec2){ -r * 0.25f, -r * 0.25f };
			painter.circle(lens, r * 0.62f, { .border_width = w, .border_color = ink });
			painter.circle(lens, 1.4f, { .color = ink });
			painter.line(lens + (Vec2){ r * 0.45f, r * 0.45f }, c + (Vec2){ r, r }, w * 1.4f, ink);
		case FIX_STRAYS_GLYPH:
			// A wand with a spark at its tip: put right in one go.
			Vec2 spark = c + (Vec2){ r * 0.5f, -r * 0.5f };
			painter.line(c + (Vec2){ -r, r }, spark + (Vec2){ -2.0f, 2.0f }, w * 1.4f, ink);
			float arm = r * 0.45f;
			painter.line(spark + (Vec2){ -arm, 0 }, spark + (Vec2){ arm, 0 }, w, ink);
			painter.line(spark + (Vec2){ 0, -arm }, spark + (Vec2){ 0, arm }, w, ink);
			float tick = arm * 0.55f;
			painter.line(spark + (Vec2){ -tick, -tick }, spark + (Vec2){ tick, tick }, 1.0f, ink);
			painter.line(spark + (Vec2){ -tick, tick }, spark + (Vec2){ tick, -tick }, 1.0f, ink);
		case LASSO_GLYPH:
			// A loop drawn round something, its rope trailing off below.
			Vec2 loop = c + (Vec2){ 0, -r * 0.2f };
			painter.arc(loop, r * 0.75f, (float)math::PI * 0.65f, (float)math::PI * 1.75f, w, ink);
			Vec2 knot = loop + (Vec2){ -r * 0.6f, r * 0.45f };
			painter.line(knot, c + (Vec2){ -r * 0.2f, r }, w, ink);
		case PEN_GLYPH:
			// A curve with a point on it, the pen that lays it.
			Vec2 last = c + (Vec2){ -r, r * 0.6f };
			for (int i = 1; i <= 8; i++)
			{
				float u = (float)i / 8.0f;
				Vec2 next = c + (Vec2){ -r + 2.0f * r * u, r * 0.6f - r * 1.2f * math::sin(u * (float)math::PI) };
				painter.line(last, next, w, ink);
				last = next;
			}
			painter.rect(c + (Vec2){ -2.5f, -r * 0.6f - 2.5f }, { 5.0f, 5.0f }, { .color = ink });
		case FROM_MOTION_GLYPH:
			// A joint's dot leaving a trail behind it.
			painter.circle(c + (Vec2){ r * 0.55f, -r * 0.4f }, 2.6f, { .color = ink });
			for (int i = 0; i < 3; i++)
			{
				float x = c.x - r + (float)i * r * 0.5f;
				float y = c.y + r * 0.6f - (float)i * r * 0.3f;
				painter.circle({ x, y }, 1.2f, { .color = ink });
			}
		case SLICE_GLYPH:
			// A curve cut across by one slice.
			painter.arc(c + (Vec2){ 0, r * 0.9f }, r * 1.1f, (float)math::PI * 1.2f, (float)math::PI * 0.6f, w, ink);
			painter.line(c + (Vec2){ 0, -r * 0.9f }, c + (Vec2){ 0, r * 0.4f }, w, ink);
			painter.circle(c + (Vec2){ 0, -r * 0.2f }, 2.4f, { .border_width = w, .border_color = ink });
		case CLOSE_PATH_GLYPH:
			// A loop with its ends joined by an arrow.
			painter.arc(c, r * 0.8f, (float)math::PI * 0.1f, (float)math::PI * 1.7f, w, ink);
			card_arrow_head(painter, c + (Vec2){ r * 0.78f, -r * 0.25f }, { 0.2f, 0.98f }, ink);
		case BAKE_GLYPH:
			// Down into keys: an arrow onto a row of diamonds.
			painter.line(c + (Vec2){ 0, -r }, c + (Vec2){ 0, r * 0.2f }, w, ink);
			card_arrow_head(painter, c + (Vec2){ 0, r * 0.2f }, { 0, 1.0f }, ink);
			for (int i = -1; i <= 1; i++) paint_diamond(painter, c + (Vec2){ (float)i * r * 0.7f, r * 0.8f }, 2.2f, ink);
		case FOLLOW_GLYPH:
			// An arc with an arrow riding it, turned the way it goes.
			painter.arc(c + (Vec2){ 0, r * 0.7f }, r * 1.1f, (float)math::PI * 1.15f, (float)math::PI * 0.7f, w, ink);
			Vec2 tip = c + (Vec2){ r * 0.75f, -r * 0.05f };
			painter.line(tip - (Vec2){ r * 0.55f, r * 0.45f }, tip, w, ink);
			card_arrow_head(painter, tip, { 0.77f, 0.64f }, ink);
		case MUTE_GLYPH:
			// An eye shut: the path is still there and does nothing.
			painter.arc(c + (Vec2){ 0, -r * 0.5f }, r, (float)math::PI * 0.2f, (float)math::PI * 0.6f, w, ink);
			for (int i = -1; i <= 1; i++)
			{
				Vec2 root = c + (Vec2){ (float)i * r * 0.45f, r * 0.35f };
				painter.line(root, root + (Vec2){ (float)i * 2.0f, 3.0f }, 1.0f, ink);
			}
	}
}

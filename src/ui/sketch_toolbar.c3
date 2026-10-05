<*
 The sketch toolbar: what the Sketch tool offers while it is running, in a strip
 across the top of the viewport.

 	red / green / blue ink · eraser | undo last mark | clear all | done

 It is zero-sized unless sketching, so it takes itself out of the picture the
 way OpenPrompt does. What a cell does goes through the same AppState ops the
 View menu uses.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

enum SketchCell : int
{
	RED,
	GREEN,
	BLUE,
	ERASER,
	UNDO,
	CLEAR,
	DONE,
}

const usz SKETCH_CELLS = 7;
// The cells before the gap: what a drag lays down (or takes off).
const usz SKETCH_PICKS = 4;

const String[SKETCH_CELLS] SKETCH_TIPS = {
	"Red ink — mark what is wrong",
	"Green ink — mark what to keep",
	"Blue ink — a note",
	"Eraser — drag over a mark to take it off",
	"Undo — take off the last mark",
	"Clear — take off every mark",
	"Done — put the Sketch tool away",
};
const float SKETCH_GAP = 6.0f;

faultdef NO_SKETCH_CELL;

struct SketchToolbar (Widget)
{
	// The hovered cell as its index + 1; zero is none.
	int lit;
	bool shown;
	// Marks and ink at the last paint, so a change repaints.
	usz marks;
	SketchInk ink;
	bool erasing;
}

fn Vec2 SketchToolbar.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.shown = app.sketching;
	if (!self.shown) return constraints.constrain({ 0, 0 });
	return constraints.constrain({ TINT_CELL_W * (float)SKETCH_CELLS + SKETCH_GAP, TINT_CELL_H });
}

fn void SketchToolbar.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (self.shown != app.sketching)
	{
		elem.request_layout();
		return;
	}
	if (!self.shown) return;
	usz marks = (usz)app.annotations.len();
	if (marks != self.marks || app.sketch_ink != self.ink || app.sketch_erasing != self.erasing)
	{
		self.marks = marks;
		self.ink = app.sketch_ink;
		self.erasing = app.sketch_erasing;
		elem.request_paint();
	}
}

fn float sketch_cell_x(usz cell) => TINT_CELL_W * (float)cell + (cell >= SKETCH_PICKS ? SKETCH_GAP : 0.0f);

fn void SketchToolbar.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (!app.sketching) return;

	painter.rect({ 0, 0 }, elem.size, { .color = BTN, .border_radius = TINT_STRIP_RADII });
	for (usz i = 0; i < SKETCH_CELLS; i++)
	{
		SketchCell cell = (SketchCell)i;
		float x = sketch_cell_x(i);
		bool hovered = self.lit == (int)i + 1;
		bool on = cell == ERASER ? app.sketch_erasing : i < 3 && !app.sketch_erasing && (int)app.sketch_ink == (int)i;
		bool off = (cell == UNDO || cell == CLEAR) && app.annotations.len() == 0;
		if (on || hovered)
		{
			painter.rect({ x + 2.0f, 2.0f }, { TINT_CELL_W - 4.0f, TINT_CELL_H - 4.0f }, {
				.color = on ? ACCENT : BTN_HOVER,
				.border_radius = TINT_CELL_RADII,
			});
		}
		Vec2 c = { x + TINT_CELL_W * 0.5f, TINT_CELL_H * 0.5f };
		Color ink = off ? TEXT_DIM.dim(0.5f) : TEXT;
		float r = TINT_ICON_R;
		switch (cell)
		{
			case RED:
				painter.circle(c, r, { .color = SKETCH_RED });
			case GREEN:
				painter.circle(c, r, { .color = SKETCH_GREEN });
			case BLUE:
				painter.circle(c, r, { .color = SKETCH_BLUE });
			case ERASER:
				// A tilted block, its rubber end filled.
				Vec2 along = { r * 0.7f, -r * 0.7f };
				Vec2 across = { r * 0.35f, r * 0.35f };
				Color eraser_ink = on ? DOT_OUTLINE : ink;
				painter.line(c - along - across, c + along - across, TINT_STROKE, eraser_ink);
				painter.line(c - along + across, c + along + across, TINT_STROKE, eraser_ink);
				painter.line(c + along - across, c + along + across, TINT_STROKE, eraser_ink);
				painter.line(c - along - across, c - along + across, TINT_STROKE * 2.4f, eraser_ink);
			case UNDO:
				// A hooked arrow back: the last mark goes.
				painter.line({ c.x + r, c.y + r * 0.6f }, { c.x + r, c.y - r * 0.2f }, TINT_STROKE, ink);
				painter.line({ c.x + r, c.y - r * 0.2f }, { c.x - r * 0.6f, c.y - r * 0.2f }, TINT_STROKE, ink);
				painter.line({ c.x - r * 0.6f, c.y - r * 0.2f }, { c.x - r * 0.1f, c.y - r * 0.8f }, TINT_STROKE, ink);
				painter.line({ c.x - r * 0.6f, c.y - r * 0.2f }, { c.x - r * 0.1f, c.y + r * 0.4f }, TINT_STROKE, ink);
			case CLEAR:
				// A cross: everything goes.
				painter.line({ c.x - r * 0.7f, c.y - r * 0.7f }, { c.x + r * 0.7f, c.y + r * 0.7f }, TINT_STROKE, ink);
				painter.line({ c.x - r * 0.7f, c.y + r * 0.7f }, { c.x + r * 0.7f, c.y - r * 0.7f }, TINT_STROKE, ink);
			case DONE:
				painter.line({ c.x - r * 0.8f, c.y }, { c.x - r * 0.2f, c.y + r * 0.6f }, TINT_STROKE, ink);
				painter.line({ c.x - r * 0.2f, c.y + r * 0.6f }, { c.x + r * 0.8f, c.y - r * 0.6f }, TINT_STROKE, ink);
		}
	}
}

fn usz? SketchToolbar.cell_at(&self, Vec2 pixel)
{
	if (pixel.x < 0 || pixel.y < 0 || pixel.y >= TINT_CELL_H) return NO_SKETCH_CELL~;
	for (usz i = 0; i < SKETCH_CELLS; i++)
	{
		float x = sketch_cell_x(i);
		if (pixel.x >= x && pixel.x < x + TINT_CELL_W) return i;
	}
	return NO_SKETCH_CELL~;
}

fn void SketchToolbar.press(&self, Element* elem, usz cell)
{
	AppState* app = elem.inherit(AppState)!!;
	switch ((SketchCell)cell)
	{
		case RED: app.pick_sketch_ink(SketchInk.RED);
		case GREEN: app.pick_sketch_ink(SketchInk.GREEN);
		case BLUE: app.pick_sketch_ink(SketchInk.BLUE);
		case ERASER: app.sketch_erasing = true;
		case UNDO:
			if (app.delete_last_annotation()) app.@notice("Removed the last sketch.");
		case CLEAR:
			usz gone = app.clear_annotations();
			if (gone > 0) app.@notice("Cleared %d sketch%s.", gone, gone == 1 ? "" : "es");
		case DONE:
			app.end_sketch();
	}
	app.refresh_ui();
	elem.request_paint();
}

fn bool SketchToolbar.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			if (try usz cell = self.cell_at(event.pos)) self.press(elem, cell);
			return true;
		case MOVE:
			int was = self.lit;
			self.lit = 0;
			if (try usz cell = self.cell_at(event.pos)) self.lit = (int)cell + 1;
			if (self.lit != was) elem.request_paint();
			return true;
		default:
			return false;
	}
}

fn void SketchToolbar.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

// The hovered cell's tooltip, for `tip_probe` around the strip.
fn String sketch_tip(Element* holder, Vec2 pos)
{
	Element* strip = holder.children[0];
	if (try usz cell = strip.widget_as(SketchToolbar).cell_at(pos - strip.absolute)) return SKETCH_TIPS[cell];
	return "";
}

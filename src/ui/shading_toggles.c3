<*
 The shading switch: three icon buttons in a 3D view's header — Wireframe,
 Solid, Textured — with the one showing lit. Blender's sphere cluster, in the
 same order.

 Exactly one is always on, so unlike the tint strip beside it a lit button
 does not switch itself off. What lights up and what a click does come from the
 View menu's own functions, so the menu, Z and the buttons cannot disagree —
 the tint strip's rule, see tint_toggles.c3.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const float SHADING_STRIP_W = TINT_CELL_W * 3.0;

faultdef NO_SHADING_CELL;

struct ShadingToggle
{
	ShadingMode mode;
	MenuQuery state;
	OnClick on_select;
}

ShadingToggle[3] shading_toggles = {
	{ .mode = ShadingMode.WIREFRAME, .state = &query_wireframe, .on_select = &menu_shading_wireframe },
	{ .mode = ShadingMode.SOLID, .state = &query_shading_solid, .on_select = &menu_shading_solid },
	{ .mode = ShadingMode.TEXTURED, .state = &query_shading_textured, .on_select = &menu_shading_textured },
};

struct ShadingToggles (Widget)
{
	// The hovered cell as its index + 1; zero is none.
	int lit;
	// What the last repaint drew, polled per frame as the tint strip does.
	MenuItemFlags[3] shown;
}

fn Vec2 ShadingToggles.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ SHADING_STRIP_W, TINT_CELL_H });
}

fn void ShadingToggles.update(&self, Element* elem, float dt) @dynamic
{
	bool changed = false;
	foreach (i, toggle : shading_toggles)
	{
		MenuItemFlags now = toggle.state(elem.ui);
		if (now.checked != self.shown[i].checked)
		{
			self.shown[i] = now;
			changed = true;
		}
	}
	if (changed) elem.request_paint();
}

fn void ShadingToggles.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.rect({ 0, 0 }, elem.size, { .color = BTN, .border_radius = TINT_STRIP_RADII });

	foreach (i, toggle : shading_toggles)
	{
		bool on = self.shown[i].checked;
		float x = TINT_CELL_W * (float)i;
		bool hovered = self.lit == (int)i + 1;

		if (on || hovered)
		{
			painter.rect({ x + 2.0f, 2.0f }, { TINT_CELL_W - 4.0f, TINT_CELL_H - 4.0f }, {
				.color = on ? ACCENT : BTN_HOVER,
				.border_radius = TINT_CELL_RADII,
			});
		}
		paint_shading_icon(painter, toggle.mode, { x + TINT_CELL_W * 0.5f, TINT_CELL_H * 0.5f },
			on ? DOT_OUTLINE : TEXT, on ? ACCENT : BTN);
	}
}

<*
 Three spheres, the way Blender draws them: an outline with a meridian and an
 equator for the wireframe, a flat disc for solid, and a disc with a lit side
 and a shadowed side for the textured look.

 @param ink : `Stroke and fill colour.`
 @param ground : `What the cell behind the icon is, for the textured sphere's shadow.`
*>
fn void paint_shading_icon(Painter* painter, ShadingMode mode, Vec2 centre, Color ink, Color ground)
{
	switch (mode)
	{
		case WIREFRAME:
			painter.circle(centre, TINT_ICON_R, { .border_width = TINT_STROKE, .border_color = ink });
			painter.ellipse(centre, { TINT_ICON_R * 0.45f, TINT_ICON_R }, { .border_width = 1.2f, .border_color = ink });
			painter.line(centre - (Vec2) { TINT_ICON_R, 0 }, centre + (Vec2) { TINT_ICON_R, 0 }, 1.2f, ink);
		case SOLID:
			painter.circle(centre, TINT_ICON_R, { .color = ink });
		case TEXTURED:
			painter.circle(centre, TINT_ICON_R, { .color = ink });
			// The shadowed half: a disc of the ground laid over the lower right, so
			// the lit crescent stays at the upper left.
			painter.circle(centre + (Vec2) { 2.5f, 2.5f }, TINT_ICON_R * 0.72f, { .color = ink.dim(0.55f) });
			painter.circle(centre + (Vec2) { -2.5f, -2.5f }, 1.6f, { .color = ground });
	}
}

fn usz? ShadingToggles.cell_at(&self, Vec2 pixel)
{
	if (pixel.x < 0 || pixel.y < 0 || pixel.y >= TINT_CELL_H) return NO_SHADING_CELL~;
	usz cell = (usz)(pixel.x / TINT_CELL_W);
	if (cell >= shading_toggles.len) return NO_SHADING_CELL~;
	return cell;
}

fn bool ShadingToggles.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			// The press that dismisses an open dropdown, as on the tint strip.
			close_menus(elem.ui);
			if (try usz cell = self.cell_at(event.pos))
			{
				shading_toggles[cell].on_select(elem.ui);
				elem.request_paint();
			}
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

fn void ShadingToggles.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

// One sentence per cell, in `shading_toggles` order.
String[3] shading_tips = {
	"Wireframe (Z) — draw the model as its edges",
	"Solid — draw the model in plain grey",
	"Textured — draw the model with its own textures",
};

fn String shading_tip(Element* holder, Vec2 pos)
{
	Element* strip = holder.children[0];
	if (try usz cell = strip.widget_as(ShadingToggles).cell_at(pos - strip.absolute)) return shading_tips[cell];
	return "";
}

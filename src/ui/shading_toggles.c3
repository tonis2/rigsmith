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

IconStripCell[3] shading_cells = {
	{ &query_wireframe, &menu_shading_wireframe, "Wireframe (Z) — draw the model as its edges" },
	{ &query_shading_solid, &menu_shading_solid, "Solid — draw the model in plain grey" },
	{ &query_shading_textured, &menu_shading_textured, "Textured — draw the model with its own textures" },
};

fn IconStrip shading_strip()
{
	return { .cells = shading_cells[..], .paint_icon = &paint_shading_icon, .on_press = &close_menus, .style = view_strip_style() };
}

<*
 Three spheres, the way Blender draws them, by `shading_cells` order: an outline
 with a meridian and an equator for the wireframe, a flat disc for solid, and a
 disc with a lit side and a shadowed side for the textured look.

 @param ground : `What is behind the icon, for the textured sphere's highlight.`
*>
fn void paint_shading_icon(Painter* painter, usz cell, Vec2 centre, Color ink, Color ground)
{
	switch (cell)
	{
		case 0: painter.icon(centre, STRIP_ICON_VIEW, ICON_WIREFRAME, ink);
		case 1: painter.icon(centre, STRIP_ICON_VIEW, ICON_SOLID, ink);
		default:
			painter.icon(centre, STRIP_ICON_VIEW, ICON_TEXTURED, ink);
			painter.icon(centre, STRIP_ICON_VIEW, ICON_TEXTURED_SHADE, ink.dim(0.55f));
			painter.icon(centre, STRIP_ICON_VIEW, ICON_TEXTURED_LIGHT, ground);
	}
}

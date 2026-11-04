<*
 The tint-view switch: icon buttons at the right of a 3D view's header, one per
 diagnostic colouring of the mesh, lit while it is showing.

 Blender's shading-mode cluster, and for the same reason it is a cluster: the
 first two are answers to one question — what is painted on the model — so at
 most one of them is ever on, and a segmented strip says that where two separate
 checkboxes would not. The third, Unused, is an overlay rather than a view: it
 marks the vertices no joint holds over either of them, or over the plain mesh.
 It sits in the pane rather than on the window bar because that is the
 question it answers: the model in *this* pane.

 Nothing here decides anything. What lights up, what greys out and what a click
 does all come from the same functions the Rig and View menus poll and run, so
 the key, the menu item and the button cannot disagree: a rule added to a query
 greys the item and the button in the same edit.

 A cui `IconStrip`, built after the header strip so it takes its own clicks. A
 press closes any open dropdown by hand, as the viewport's does.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

// One cell. Shorter than the bar on purpose: the bar's own colour frames the
// strip, which is what makes the buttons read as one control.
const float TINT_CELL_W = 28.0;
const float TINT_CELL_H = 22.0;

// Gap between the strip and the right edge of the pane it sits in. Read by
// ViewPanel, which is what places it.
const float TINT_MARGIN = 12.0;

const Vec4 TINT_STRIP_RADII = { 6.0, 6.0, 6.0, 6.0 };
const Vec4 TINT_CELL_RADII = { 5.0, 5.0, 5.0, 5.0 };

// A global rather than a const: these initialisers take function addresses.
IconStripCell[3] tint_cells = {
	{ &query_weights, &menu_weights, "Weight preview — tint the mesh by which joint owns each part" },
	{ &query_falloff, &menu_falloff, "Weight falloff (F) — tint the mesh by how strongly the selected joint pulls" },
	{ &query_unused, &menu_unused, "Unused weights — mark the vertices no joint holds; posed, they follow the root" },
};

// The look both header strips share. Dark ink on a lit cell: the accent is a
// light warm fill, and a pale icon would vanish exactly when it matters most.
fn IconStripStyle view_strip_style()
{
	return {
		.fill = BTN,
		.hover = BTN_HOVER,
		.lit = ACCENT,
		.ink = TEXT,
		.lit_ink = DOT_OUTLINE,
		.disabled_ink = TEXT_DIM.dim(0.55),
		.border_radius = TINT_STRIP_RADII,
		.cell_radius = TINT_CELL_RADII,
		.inset = 2.0,
		.cell = { TINT_CELL_W, TINT_CELL_H },
	};
}

// The press also dismisses an open dropdown: the bar's catcher sits under the
// strip and will never be handed it.
fn IconStrip tint_strip()
{
	return { .cells = tint_cells[..], .paint_icon = &paint_tint_icon, .on_press = &close_menus, .style = view_strip_style() };
}

<*
 The glyphs, SVGs in assets/icons/strip, by `tint_cells` order. All are built on
 a circle so the strip reads as one control, and they are told apart by what is
 inside it: wedges, rings, a slash.
*>
fn void paint_tint_icon(Painter* painter, usz cell, Vec2 centre, Color ink, Color ground)
{
	switch (cell)
	{
		case 0: painter.icon(centre, STRIP_ICON_VIEW, ICON_TERRITORY, ink);
		case 1:
			// Rings fading outward from one point, only slightly dimmer per ring:
			// the ink may already be greyed.
			painter.icon(centre, STRIP_ICON_VIEW, ICON_FALLOFF, ink);
			painter.icon(centre, STRIP_ICON_VIEW, ICON_FALLOFF_INNER, ink.dim(0.85));
			painter.icon(centre, STRIP_ICON_VIEW, ICON_FALLOFF_OUTER, ink.dim(0.65));
		default: painter.icon(centre, STRIP_ICON_VIEW, ICON_UNUSED, ink);
	}
}

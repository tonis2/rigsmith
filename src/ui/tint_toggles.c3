<*
 The tint-view switch: two icon buttons at the right of a 3D view's header, one
 per diagnostic colouring of the mesh, lit while its view is the one showing.

 Blender's shading-mode cluster, and for the same reason it is a cluster: the
 two are answers to one question — what is painted on the model — so at most one
 is ever on, and a segmented strip says that where two separate checkboxes would
 not. It sits in the pane rather than on the window bar because that is the
 question it answers: the model in *this* pane.

 Nothing here decides anything. What lights up, what greys out and what a click
 does all come from the same functions the Rig and View menus poll and run, so
 the key, the menu item and the button cannot disagree: a rule added to a query
 greys the item and the button in the same edit.

 A sibling of the header strip, built after it so it takes its own clicks. A
 press closes any open dropdown by hand, as the viewport's does.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

// One cell, and the strip the two sit in. Shorter than the bar on purpose: the
// bar's own colour frames the strip, which is what makes two buttons read as
// one control instead of two.
const float TINT_CELL_W = 28.0;
const float TINT_CELL_H = 22.0;
const float TINT_STRIP_W = TINT_CELL_W * 2.0;

// Gap between the strip and the right edge of the pane it sits in. Read by
// ViewPanel, which is what places it.
const float TINT_MARGIN = 12.0;

const float TINT_ICON_R = 7.0;
const float TINT_STROKE = 1.5;

const Vec4 TINT_STRIP_RADII = { 6.0, 6.0, 6.0, 6.0 };
const Vec4 TINT_CELL_RADII = { 5.0, 5.0, 5.0, 5.0 };

// Where the territory glyph's wedges divide, in degrees clockwise from +x.
const float[3] TERRITORY_CUTS = { 70.0, 150.0, 300.0 };

faultdef NO_TINT_CELL;

<*
 One button. `mode` chooses the icon and nothing else — the state and the action
 are the menu's own wiring, borrowed whole.
*>
struct TintToggle
{
	TintMode mode;
	MenuQuery state;
	OnClick on_select;
}

// A global rather than a const for the same reason the menus below `build_ui`
// are: these initialisers take function addresses.
TintToggle[2] tint_toggles = {
	{ .mode = TintMode.TERRITORY, .state = &query_weights, .on_select = &menu_weights },
	{ .mode = TintMode.FALLOFF, .state = &query_falloff, .on_select = &menu_falloff },
};

struct TintToggles (Widget)
{
	// The hovered cell as its index + 1, so the zero default means "none" rather
	// than "the first one" — the same encoding the view gizmo's highlight uses.
	int lit;

	// What the last repaint drew. Polled per frame rather than pushed, because
	// the keyboard and the rig change these as much as a click does and neither
	// path knows this widget exists.
	MenuItemFlags[2] shown;
}

fn Vec2 TintToggles.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ TINT_STRIP_W, TINT_CELL_H });
}

<*
 Re-reads the two queries and repaints when one of them moved.

 The cheap half of the same bargain the HUD makes: two struct calls a frame buys
 a strip that is right after a keypress, after an undo, and after the last dot
 is deleted out from under an open view.
*>
fn void TintToggles.update(&self, Element* elem, float dt) @dynamic
{
	bool changed = false;
	foreach (i, toggle : tint_toggles)
	{
		MenuItemFlags now = toggle.state(elem.ui);
		if (now.checked != self.shown[i].checked || now.disabled != self.shown[i].disabled)
		{
			self.shown[i] = now;
			changed = true;
		}
	}
	if (changed) elem.request_paint();
}

fn void TintToggles.paint(&self, Element* elem, Painter* painter) @dynamic
{
	painter.rect({ 0, 0 }, elem.size, { .color = BTN, .border_radius = TINT_STRIP_RADII });

	foreach (i, toggle : tint_toggles)
	{
		MenuItemFlags flags = self.shown[i];
		float x = TINT_CELL_W * (float)i;
		bool hovered = self.lit == (int)i + 1 && !flags.disabled;

		if (flags.checked || hovered)
		{
			painter.rect({ x + 2.0f, 2.0f }, { TINT_CELL_W - 4.0f, TINT_CELL_H - 4.0f }, {
				.color = flags.checked ? ACCENT : BTN_HOVER,
				.border_radius = TINT_CELL_RADII,
			});
		}

		// Dark ink on the lit cell: the accent is a light warm fill, and an icon
		// that stayed pale on it would vanish exactly when it matters most.
		Color ink = TEXT;
		if (flags.checked)
		{
			ink = DOT_OUTLINE;
		}
		else if (flags.disabled)
		{
			ink = TEXT_DIM.dim(0.55);
		}

		paint_tint_icon(painter, toggle.mode, { x + TINT_CELL_W * 0.5f, TINT_CELL_H * 0.5f }, ink);
	}
}

<*
 The two glyphs, drawn from primitives rather than loaded from an atlas — there
 is no icon font in the build and two shapes do not justify one.

 Both are built on a circle so the strip reads as one control, and they are told
 apart by what is inside it: wedges, rings.

 @param centre : `Middle of the cell, in element-local pixels.`
 @param ink : `Stroke colour; the caller has already resolved lit and greyed.`
*>
fn void paint_tint_icon(Painter* painter, TintMode mode, Vec2 centre, Color ink)
{
	switch (mode)
	{
		case TERRITORY:
			// A disc cut into wedges — one region per joint, which is what the
			// territory map paints. The wedges are deliberately uneven: three
			// equal ones meet at 120° and the glyph starts reading as a wireframe
			// cube, which in a mesh tool means something else entirely.
			painter.circle(centre, TINT_ICON_R, { .border_width = TINT_STROKE, .border_color = ink });
			foreach (degrees : TERRITORY_CUTS)
			{
				float angle = math::deg_to_rad(degrees);
				Vec2 arm = { math::cos(angle), math::sin(angle) };
				painter.line(centre, centre + arm * TINT_ICON_R, TINT_STROKE, ink);
			}
		case FALLOFF:
			// Rings fading outward from one point: one joint's weight over the
			// distance it reaches, and the shape Blender already uses for
			// proportional editing.
			painter.circle(centre, 2.0f, { .color = ink });
			// Only slightly dimmer per ring. The fade is the point of the glyph,
			// but it compounds with the greying the caller may already have
			// applied, and two multiplications of a dim ink is an invisible one.
			painter.circle(centre, TINT_ICON_R * 0.6f, {
				.border_width = TINT_STROKE,
				.border_color = ink.dim(0.85),
			});
			painter.circle(centre, TINT_ICON_R, {
				.border_width = TINT_STROKE,
				.border_color = ink.dim(0.65),
			});
		default:
			break;
	}
}

<*
 The cell under a point, in element-local pixels.

 @param pixel : `Element-local.`
*>
fn usz? TintToggles.cell_at(&self, Vec2 pixel)
{
	if (pixel.x < 0 || pixel.y < 0 || pixel.y >= TINT_CELL_H) return NO_TINT_CELL~;
	usz cell = (usz)(pixel.x / TINT_CELL_W);
	if (cell >= tint_toggles.len) return NO_TINT_CELL~;
	return cell;
}

fn bool TintToggles.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;

			// This press is also the one that dismisses an open dropdown: the
			// bar's catcher sits under this widget and will never be handed it.
			close_menus(elem.ui);

			if (try usz cell = self.cell_at(event.pos))
			{
				// A greyed button still swallows the click. It is a control on a
				// bar, and letting the press through would be a click on the bar.
				if (self.shown[cell].disabled) return true;
				tint_toggles[cell].on_select(elem.ui);
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

fn void TintToggles.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	// Leaving produces no MOVE inside the widget, so the highlight has to be
	// cleared here or the last cell stays lit with the pointer gone.
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

// One sentence per cell, in `tint_toggles` order.
String[2] tint_tips = {
	"Weight preview — tint the mesh by which joint owns each part",
	"Weight falloff (F) — tint the mesh by how strongly the selected joint pulls",
};

fn String tint_tip(Element* holder, Vec2 pos)
{
	Element* strip = holder.children[0];
	if (try usz cell = strip.widget_as(TintToggles).cell_at(pos - strip.absolute)) return tint_tips[cell];
	return "";
}

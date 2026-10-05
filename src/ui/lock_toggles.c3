<*
 The two anchor padlocks on the Joint card: hold this joint's position, its
 rotation, or both, while another joint is moved.

 Two icons rather than one checkbox because the two halves are genuinely separate
 — a foot pinned by position alone still pivots, one held by rotation alone still
 slides, and only together is it planted flat. Each padlock is drawn open when its
 half is off and closed-and-lit when on, so the pair reads at a glance without a
 word of label doing the work; the words are there anyway, since "Pin position"
 and "Pin angle" name what is held better than a lock alone can. ("Move" read as
 *allow moving* — the opposite of what the padlock does.)

 A press on a half sets that half across the whole selection through
 `set_selection_anchor_half` — several joints selected lock or unlock together, the
 new state taken from the primary so a mixed selection lands one way; one joint
 selected is just that joint. Session state, so nothing is committed and there is no
 undo step, the anchor simply is or is not. The viewport's red ring on each joint is
 the same state seen on the model; `refresh_ui` catches it up on the click.

 Drawn rather than built from glyphs for the reason `JointDials` is: the font has
 no padlock, and a lock that is clearly open or shut says more than a checkbox.
*>
module crig;

import cui;
import std::math;

const String LOCK_TOGGLES_ID = "joint-lock-toggles";
const float LOCK_TOGGLES_H = 30.0f;

// The padlock: a rounded body under a shackle, sized to sit beside a 12px label.
const float LOCK_BODY_W = 13.0f;
const float LOCK_BODY_H = 10.0f;
const float LOCK_SHACKLE_R = 4.0f;
const float LOCK_STROKE = 1.8f;
const float LOCK_LABEL_SIZE = 12.0f;
// Where each half's padlock centre sits, from the half's left edge.
const float LOCK_ICON_X = 15.0f;

struct LockToggles (Widget)
{
	int lit; // hovered half + 1, zero for none
}

fn Vec2 LockToggles.layout(&self, Element* elem, Constraints constraints) @dynamic
	=> constraints.constrain({ JOINT_PANEL_W, LOCK_TOGGLES_H });

// Which half a pixel is over: 0 = Move (left), 1 = Rotate (right), -1 = outside.
fn int lock_half_at(Element* elem, Vec2 pixel) @local
{
	if (pixel.y < 0.0f || pixel.y > elem.size.y) return -1;
	if (pixel.x < 0.0f || pixel.x > elem.size.x) return -1;
	return pixel.x < elem.size.x * 0.5f ? 0 : 1;
}

<*
 One padlock, drawn open (off) or shut (on).

 `body_top` is the middle of the body's top edge; the shackle rises from there.
 The arc runs the painter's way — clockwise from +x — so from the left side over
 the top to the right side is start `PI`, sweep `PI`. Shut: both legs reach the
 body. Open: the shackle lifts and only the near leg stays, the far side ajar.
*>
fn void draw_padlock(Painter* painter, Vec2 body_top, bool on, Color ink) @local
{
	const float PI = (float)math::PI;
	float shackle_h = on ? 3.0f : 5.0f;
	Vec2 sc = { body_top.x, body_top.y - shackle_h };

	painter.arc(sc, LOCK_SHACKLE_R, PI, PI, LOCK_STROKE, ink);
	painter.line({ sc.x - LOCK_SHACKLE_R, sc.y }, { sc.x - LOCK_SHACKLE_R, body_top.y }, LOCK_STROKE, ink);
	if (on) painter.line({ sc.x + LOCK_SHACKLE_R, sc.y }, { sc.x + LOCK_SHACKLE_R, body_top.y }, LOCK_STROKE, ink);

	painter.rect({ body_top.x - LOCK_BODY_W * 0.5f, body_top.y }, { LOCK_BODY_W, LOCK_BODY_H }, {
		.color = on ? ink : (Color){ 0, 0, 0, 0 },
		.border_width = on ? 0.0f : 1.6f,
		.border_color = ink,
		.border_radius = { 2.5f, 2.5f, 2.5f, 2.5f },
	});
	// The keyhole reads against whichever fill it sits on.
	painter.circle({ body_top.x, body_top.y + LOCK_BODY_H * 0.55f }, 1.5f, { .color = on ? PANEL : ink });
}

fn void draw_lock_half(Element* elem, Painter* painter, float left, float width, String label, bool on, bool lit) @local
{
	Color ink = on ? DOT_LOCKED : (lit ? TEXT : TEXT_DIM);
	float mid = elem.size.y * 0.5f;
	draw_padlock(painter, { left + LOCK_ICON_X, mid - 4.0f }, on, ink);

	Vec2 size = elem.ui.text.measure(0, label, LOCK_LABEL_SIZE);
	painter.text({ left + LOCK_ICON_X + 13.0f, mid - size.y * 0.5f }, label, { .size = LOCK_LABEL_SIZE, .color = ink });
}

fn void LockToggles.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	uint sel = app.selected;
	float half = elem.size.x * 0.5f;

	draw_lock_half(elem, painter, 0.0f, half, "Pin position",
		sel != 0 && app.locks_position(sel), self.lit == 1);
	draw_lock_half(elem, painter, half, half, "Pin angle",
		sel != 0 && app.locks_rotation(sel), self.lit == 2);
}

fn void LockToggles.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) return;
	if (self.lit != 0)
	{
		self.lit = 0;
		elem.request_paint();
	}
	elem.set_cursor(Cursor.DEFAULT);
}

fn bool LockToggles.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			int half = lock_half_at(elem, event.pos);
			if (half < 0) return false;
			if (app.selected == 0)
			{
				app.@notice("select a joint to anchor it");
				return true;
			}
			// The whole selection, not only the anchor dot: several joints selected
			// lock or unlock together, the new state taken from the primary so a
			// mixed selection lands one way.
			bool rotation = half == 1;
			bool now = rotation ? !app.locks_rotation(app.selected) : !app.locks_position(app.selected);
			usz skipped = 0;
			usz acted = app.set_selection_anchor_half(rotation, now, &skipped);
			String kind = rotation ? "angle" : "position";
			String left_out = skipped > 0
				? string::tformat(" · %d trunk joint%s left free, so the body can move", (int)skipped, skipped == 1 ? "" : "s")
				: "";
			if (acted > 1)
			{
				app.@notice(now ? "%s pinned on %d joints%s" : "%s unpinned on %d joints", kind, (int)acted, left_out);
			}
			else
			{
				app.@notice(now ? "%s pinned%s" : "%s unpinned", kind, left_out);
			}
			// The icon here, and the ring on the model out there.
			elem.request_paint();
			app.refresh_ui();
			return true;
		case MOVE:
			int over = lock_half_at(elem, event.pos);
			int lit = over < 0 ? 0 : over + 1;
			if (lit != self.lit)
			{
				self.lit = lit;
				elem.request_paint();
			}
			elem.set_cursor(over < 0 ? Cursor.DEFAULT : Cursor.POINTING_HAND);
			return false;
		default:
			return false;
	}
}

// The two padlocks' tooltip: which half the pointer is on.
fn String lock_tip(Element* holder, Vec2 pos)
{
	Element* locks = holder.children[0];
	if (pos.x - locks.absolute.x < locks.size.x * 0.5f)
	{
		return "Pin position (L) — hold this joint in place while you pose another; with a clip open it holds in playback too";
	}
	return "Pin angle (Shift+L) — hold this joint's orientation while you pose another; with a clip open it holds in playback too";
}

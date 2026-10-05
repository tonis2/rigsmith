<*
 The corner axis gizmo: six balls showing which way the model is facing, click
 one to look down that axis.

 A child of `Viewport`, not a sibling — the same constraint everything drawn
 over the viewport is under (PLAN R3). It has to be a child so that clicking it
 does not also place a dot: cui hit-tests to the deepest element and then bubbles
 to *parents*, so an event the gizmo does not consume reaches the viewport
 underneath. Everything inside the body is therefore consumed, and everything
 outside it is returned unhandled so the corners of this widget's square stay
 live model.

 Nothing here is 3D. The balls have no world position, only a direction, so
 there is no projection and no depth buffer: `view_direction` rotates each unit
 axis into view space, and the result is used directly as a pixel offset from
 the centre. `z` is kept only to sort the painting back-to-front and to fade the
 balls pointing away.
*>
module crig;

import cui;
import std::math::vector; // for Vec2/Vec3; no `math::` call appears below

// Diameter of the gizmo's body, in pixels — the circle the balls sit on.
const float GIZMO_SIZE = 84.0;

// And how far its box sits from the viewport's top-right corner.
const float GIZMO_MARGIN = 16.0;

const float BALL_RADIUS = 9.0;
const float AXIS_WIDTH = 2.0;

// How much of a ball's colour survives when it is pointing straight away.
// Not zero: a ball you cannot see is a ball you cannot click, and the far
// three are exactly the views the user most often wants.
const float FAR_DIM = 0.45;

const float GIZMO_LABEL_SIZE = 11.0;

faultdef NO_BALL, NO_VIEW_KEY;

struct ViewGizmo (Widget)
{
	// No state pointer. The camera arrives by type from the element —
	// `build_ui` provides it — and deliberately only the camera: this widget
	// steers the view and has no business reaching the document. A field of
	// type `AppState*` would have given it that reach for free.
	//
	// Resolved once per hook and passed down, not looked up per ball. A lookup
	// is a typeid compare over the provider list, which is cheap but not free,
	// and `paint` would otherwise do 36 of them sorting six balls.

	bool dragging; // the body is being dragged to orbit

	// The highlighted ball, as its ordinal + 1, so the zero default means "none"
	// rather than "+X" — a widget that lights up wrong until first hovered would
	// be a bug the tree had to remember not to write.
	int lit;
}

<*
 A fixed square. It does not fill its parent — the viewport lays children out
 loosely and this one is positioned by `set_offset`.
*>
fn Vec2 ViewGizmo.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ GIZMO_SIZE, GIZMO_SIZE });
}

fn Element* gizmo_viewport(Element* elem) @local
{
	Element* at = elem;
	while (at != null && !at.is_widget(Viewport)) at = at.parent;
	return at;
}

<*
 Where a ball sits, in element-local pixels, and how far toward the viewer.

 @return `x/y are the centre in element pixels; z > 0 points toward the viewer.`
*>
fn Vec3 ViewGizmo.ball_at(&self, Element* elem, OrbitCamera* camera, ViewAxis axis)
{
	Vec3 view = camera.view_direction(axis.direction);

	// The balls have to stay inside the body, so the arm is short of the radius
	// by exactly one ball.
	float arm = elem.size.x * 0.5f - BALL_RADIUS;
	Vec2 centre = elem.size * 0.5f;

	// y negated by hand: `view_direction` skips `projection()`, which is where
	// the Vulkan flip lives, and cui's canvas has y down.
	return { centre.x + view.x * arm, centre.y - view.y * arm, view.z };
}

fn void ViewGizmo.paint(&self, Element* elem, Painter* painter) @dynamic
{
	(void)elem.watch(OrbitCamera)!!;
	Element* viewport = gizmo_viewport(elem);
	if (viewport == null) return;
	OrbitCamera* camera = viewport.widget_as(Viewport).view_camera(viewport);
	Vec2 centre = elem.size * 0.5f;

	// Back to front, so a near ball covers the arm of a far one rather than
	// being sliced by it. Six items, so a selection sort by depth is both the
	// clearest way to write it and the fastest.
	ViewAxis[ViewAxis::values.len] order = ViewAxis::values;

	foreach (usz i, value: ViewAxis::values) {
		usz furthest = i;
		for (usz j = i + 1; j < order.len; j++)
		{
			if (self.ball_at(elem, camera, order[j]).z < self.ball_at(elem, camera, order[furthest]).z) furthest = j;
		}
		@swap(order[i], order[furthest]);
	}

	foreach (axis : order)
	{
		Vec3 ball = self.ball_at(elem, camera, axis);
		Vec2 at = { ball.x, ball.y };

		// z runs -1..1 over the sphere, so this is 1 dead-on and FAR_DIM dead
		// away — a continuous cue rather than a front/back switch that would
		// pop as a ball crossed the middle.
		float facing = FAR_DIM + (1.0f - FAR_DIM) * (ball.z * 0.5f + 0.5f);
		Color tint = axis_color(axis).dim(facing);

		bool named = axis.label.len > 0;
		bool lit = self.lit == axis.ordinal + 1;

		// Only the named end gets an arm. Drawing both would put a full
		// diameter of line through the middle and bury the centre.
		if (named) painter.line(centre, at, AXIS_WIDTH, tint);

		painter.circle(at, BALL_RADIUS, {
			// Hollow on the negative half — Blender's convention, and it reads
			// as "the other end of this axis" without a second colour.
			.color = named || lit ? tint : PANEL,
			.border_width = named ? 0.0f : AXIS_WIDTH,
			.border_color = tint,
		});

		if (named)
		{
			Vec2 size = elem.ui.text.measure(0, axis.label, GIZMO_LABEL_SIZE);
			painter.text(at - size * 0.5f, axis.label, {
				.size = GIZMO_LABEL_SIZE,
				.color = DOT_OUTLINE,
			});
		}
	}
}

<*
 The ball under a pointer.

 Screen space for the same reason dots are picked that way: the ball draws at a
 fixed pixel radius, so the thing being aimed at is the circle. Where two
 overlap at a shallow angle the frontmost wins — which is the one painted on
 top, so what gets clicked is what the user can see.

 @param pixel : `Element-local.`
*>
fn ViewAxis? ViewGizmo.pick_ball(&self, Element* elem, OrbitCamera* camera, Vec2 pixel)
{
	ViewAxis best;
	bool found = false;
	float best_depth = 0.0f;

	foreach (axis : ViewAxis::values)
	{
		Vec3 ball = self.ball_at(elem, camera, axis);
		if ((((Vec2){ ball.x, ball.y }) - pixel).length() > BALL_RADIUS) continue;
		if (found && ball.z <= best_depth) continue;
		best = axis;
		best_depth = ball.z;
		found = true;
	}

	if (!found) return NO_BALL~;
	return best;
}

<*
 True when a pointer is over the gizmo's body rather than the corners of its
 box. Everything inside is consumed; everything outside falls through to the
 viewport, so the corners stay live model instead of a dead square.
*>
fn bool ViewGizmo.in_body(&self, Element* elem, Vec2 pixel)
{
	return (pixel - elem.size * 0.5f).length() <= elem.size.x * 0.5f;
}

fn bool ViewGizmo.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	Element* viewport = gizmo_viewport(elem);
	if (viewport == null) return false;
	Viewport* view = viewport.widget_as(Viewport);
	if (event.kind == PRESS) view.activate_camera(viewport);
	OrbitCamera* camera = view.view_camera(viewport);

	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			if (!self.in_body(elem, event.pos)) return false;

			if (try ViewAxis axis = self.pick_ball(elem, camera, event.pos))
			{
				camera.snap_to(axis);
				// Nothing has moved yet — the snap eases over the next quarter
				// second under `OrbitCamera.advance`. Invalidating anyway is what
				// schedules the frame that runs it; without it the loop may go
				// back to sleep and the turn never starts.
				elem.ui.invalidate(OrbitCamera);
				return true;
			}

			// Off the balls but on the body: drag to orbit, same as the
			// viewport. Consuming the press captures the pointer, so the drag
			// survives leaving this 84px square — which it will immediately.
			self.dragging = true;
			return true;
		case MOVE:
			if (self.dragging)
			{
				camera.orbit(elem.ui.input.mouse_delta);
				elem.ui.invalidate(OrbitCamera);
				return true;
			}

			// Hover highlight. Only worth a repaint when it actually changed.
			int was = self.lit;
			self.lit = 0;
			if (try ViewAxis axis = self.pick_ball(elem, camera, event.pos)) self.lit = axis.ordinal + 1;
			if (self.lit != was) elem.request_paint();
			return self.in_body(elem, event.pos);
		case RELEASE:
			if (event.button != MouseButton.LEFT || !self.dragging) return false;
			self.dragging = false;
			return true;
		default:
			return false;
	}
}

fn void ViewGizmo.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) elem.set_cursor(Cursor.POINTING_HAND);
	// Leaving the widget produces no MOVE inside it, so the highlight has to be
	// cleared here or the last ball stays lit after the pointer is gone.
	if (entered || self.lit == 0) return;
	self.lit = 0;
	elem.request_paint();
}

<*
 The orthogonal view a key asks for.

 Numpad 1/3/7 are front/right/top with ctrl giving the opposite face — Blender's
 mapping, unchanged, because the people this tool is for already have it in
 their hands and a better arrangement they have to learn is not better.

 The digits along the top row answer to the same three, because most of the
 laptops this runs on have no numpad at all and the menu and the Controls sheet
 both advertise "1 / 3 / 7" without saying where. A second door rather than a
 move: a desk keyboard's numpad is still the one a Blender hand reaches for, and
 the top row is free — no other handler in the app claims a digit.
*>
fn ViewAxis? view_key(Key key, bool ctrl)
{
	switch (key)
	{
		case Key.NUM_1:
		case Key.KEY_1:
			return ctrl ? ViewAxis.NEG_Z : ViewAxis.POS_Z;
		case Key.NUM_3:
		case Key.KEY_3:
			return ctrl ? ViewAxis.NEG_X : ViewAxis.POS_X;
		case Key.NUM_7:
		case Key.KEY_7:
			return ctrl ? ViewAxis.NEG_Y : ViewAxis.POS_Y;
		default: return NO_VIEW_KEY~;
	}
}

fn Color axis_color(ViewAxis axis)
{
	switch (axis)
	{
		case POS_X:
		case NEG_X:
			return AXIS_X;
		case POS_Y:
		case NEG_Y:
			return AXIS_Y;
		default:
			return AXIS_Z;
	}
}

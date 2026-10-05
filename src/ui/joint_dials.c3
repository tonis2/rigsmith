<*
 The selected joint's three rotation dials, on the Joint card: one ring per
 bone-local axis, dragged to turn the joint about that axis.

 These are the rotation rings that used to be drawn around the joint in the
 viewport, moved off the model. Around the joint they sat exactly where the eye
 needed to be — turning a wrist or a head meant turning the thing the rings
 covered — and at a fixed radius they hid a whole finger. On the card they hide
 nothing, sit above the numbers they drive, and each is a full circle at a known
 size whatever the camera is doing.

 What a ring showed, a dial shows the same way: the allowed span bright, the
 blocked span dim, the endpoints marked, and a bead at the current angle. Zero
 is at the top and positive angles run anticlockwise — the right-hand rule for
 an axis pointing out of the card at the viewer. An axis the limits lock gets no
 dial at all: the card builds this widget with only the axes the joint may turn
 about, one column each, over the degree fields for the same axes.

 A press on a dial is a held turn through `begin_turn`, the same gesture a ring
 began. The sweep is the pointer's angle about the dial's centre, unwrapped so
 a revolution is a revolution, and it lands through `turn_joint_to`: that axis's
 own number, the other two left where the gesture found them, so the dial
 changes exactly what the field under it shows. The release is `end_drag`, so one
 drag is one pose edit and Auto-key keys it once; Escape mid-drag cancels
 through the shortcut every gesture answers to, and the dial notices on its next
 event that the gesture is gone.
*>
module crig;

import cui;
import rig;
import std::math;

const String JOINT_DIALS_ID = "joint-dials";

const float JOINT_DIAL_ROW_H = 62.0f;
const float JOINT_DIAL_RADIUS = 23.0f;
const float JOINT_DIAL_WIDTH = 2.0f;
const float JOINT_DIAL_ACTIVE_WIDTH = 3.2f;
// The blocked span, and the whole ring of an axis the table locks.
const float JOINT_DIAL_DIM = 0.22f;
const float JOINT_DIAL_IDLE = 0.72f;
const float JOINT_DIAL_MARK = 3.4f;
const float JOINT_DIAL_LIMIT_MARK = 2.4f;
const float JOINT_DIAL_LABEL_SIZE = 12.0f;
// How far outside the ring a press still takes the dial. The disc inside it is
// all handle: a knob is grabbed anywhere on its face.
const float JOINT_DIAL_GRIP = 6.0f;

struct JointDials (Widget)
{
	JointRotationAxis[3] axes; // one column each, in X/Y/Z order — see `posable_axes`
	usz count;
	int lit;      // hovered column + 1, zero for none
	int held;     // the column being dragged, + 1
	float anchor; // the pointer's angle about the held dial at the last move
	float start;  // the joint's angle about the held axis when the press landed
	float turned; // the sweep since, unwrapped
}

<*
 What the dials show, read off the document once per paint or press.

 `ready` is false whenever the card would not offer the rotation fields either:
 nothing selected, no animation to pose, a branching joint with no child chosen.
 The dials then draw as dim rings with dim letters — the shape of the control
 with nothing to turn — rather than vanishing and shifting the card.
*>
struct DialState
{
	bool ready;
	JointRotationLimits limits;
	Vec3 angles;
}

fn DialState dial_state(AppState* app) @private
{
	DialState out;
	if (app.selected == 0 || !app.animation_pose_ready()) return out;

	RigView? opened = app.open_rig(mem);
	if (catch opened) return out;
	RigView view = opened;
	defer view.free(mem);
	if (view.joint_of(app.selected) < 0) return out;

	out.limits = app.doc.rotation_limits_of(app.selected);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, out.limits);
	if (!frame.usable()) return out;

	PosedJoint pose = joint_panel_pose(app, &view, app.selected);
	out.angles = joint_angles_from_rotation(frame, pose.rotation);
	out.ready = true;
	return out;
}

fn Color joint_axis_color(usz axis)
{
	switch (axis)
	{
		case 0: return AXIS_X;
		case 1: return AXIS_Y;
		default: return AXIS_Z;
	}
}

const JointRotationAxis[3] JOINT_DIAL_AXES = {
	JointRotationAxis.X, JointRotationAxis.Y, JointRotationAxis.Z,
};

// One dial per column of the degree fields beneath, so a ring sits over the
// number it turns.
fn Vec2 dial_centre(Element* elem, usz column)
{
	float pitch = JOINT_ROTATION_CELL_W + JOINT_PANEL_GRID_GAP;
	return { JOINT_ROTATION_CELL_W * 0.5f + pitch * (float)column, elem.size.y * 0.5f };
}

// Where an angle sits on a dial: zero at the top, positive anticlockwise.
fn Vec2 dial_point(Vec2 centre, float angle)
{
	return centre + (Vec2){ -math::sin(angle), -math::cos(angle) } * JOINT_DIAL_RADIUS;
}

// The inverse: the angle a pixel is at about a dial's centre.
fn float dial_angle_at(Vec2 centre, Vec2 pixel)
{
	return (float)math::atan2(-(pixel.x - centre.x), -(pixel.y - centre.y));
}

// The painter's arc runs clockwise from +x; a dial's angles run anticlockwise
// from the top. An arc from `from` to `to` on the dial starts at `to` in the
// painter's terms and sweeps `to - from`.
fn float dial_arc_start(float to) @private => -(float)math::PI * 0.5f - to;

fn Vec2 JointDials.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ JOINT_PANEL_W, JOINT_DIAL_ROW_H });
}

<*
 The column under a pixel, or -1. The whole face and a band outside the ring.
*>
fn int JointDials.dial_at(&self, Element* elem, Vec2 pixel)
{
	for (usz column = 0; column < self.count; column++)
	{
		if ((pixel - dial_centre(elem, column)).length() <= JOINT_DIAL_RADIUS + JOINT_DIAL_GRIP) return (int)column;
	}
	return -1;
}

fn void JointDials.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	DialState state = dial_state(app);

	for (usz column = 0; column < self.count; column++)
	{
		usz axis = self.axes[column].component();
		Vec2 centre = dial_centre(elem, column);
		Color base = joint_axis_color(axis);
		bool active = self.held == (int)column + 1 && app.drag.dial;
		bool lit = self.lit == (int)column + 1;
		float width = active || lit ? JOINT_DIAL_ACTIVE_WIDTH : JOINT_DIAL_WIDTH;

		// The whole ring, dim: what a blocked span looks like, and all an idle
		// card has to show.
		painter.arc(centre, JOINT_DIAL_RADIUS, 0.0f, (float)math::TAU, width, base.dim(JOINT_DIAL_DIM));

		if (state.ready)
		{
			// The allowed span, bright. A free axis is a whole bright ring; an
			// endpoint past the half turn the dial can show clamps correctly but
			// has no mark of its own, as on the rings before.
			float lo = -(float)math::PI;
			float hi = (float)math::PI;
			if (state.limits.constrained)
			{
				JointAxisLimit limit = state.limits.axes[axis];
				lo = math::max(limit.minimum, lo);
				hi = math::min(limit.maximum, hi);
			}
			float strength = active || lit ? 1.0f : JOINT_DIAL_IDLE;
			if (hi > lo) painter.arc(centre, JOINT_DIAL_RADIUS, dial_arc_start(hi), hi - lo, width, base.dim(strength));

			if (state.limits.constrained)
			{
				JointAxisLimit limit = state.limits.axes[axis];
				float[2] ends = { limit.minimum, limit.maximum };
				foreach (boundary : ends)
				{
					if (boundary < -(float)math::PI || boundary > (float)math::PI) continue;
					bool reached = active && math::abs(state.angles[axis] - boundary) < 0.015f;
					painter.circle(dial_point(centre, boundary),
						reached ? JOINT_DIAL_MARK + 1.5f : JOINT_DIAL_LIMIT_MARK, {
							.color = reached ? ACCENT : base,
							.border_width = reached ? 1.0f : 0.0f,
							.border_color = PANEL,
						});
				}
			}
		}

		// The bead is the current value, on the ring the spans occupy, so
		// reaching a limit reads as the bead arriving at its mark.
		if (state.ready)
		{
			painter.circle(dial_point(centre, state.angles[axis]), JOINT_DIAL_MARK, {
				.color = base.dim(active || lit ? 1.0f : 0.85f),
				.border_width = 1.0f,
				.border_color = PANEL,
			});
		}

		String name = self.axes[column].label();
		Vec2 size = elem.ui.text.measure(0, name, JOINT_DIAL_LABEL_SIZE);
		painter.text(centre - size * 0.5f, name, {
			.size = JOINT_DIAL_LABEL_SIZE,
			.color = state.ready ? base : TEXT_DIM,
		});
	}
}

fn void JointDials.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) return;
	if (self.lit != 0)
	{
		self.lit = 0;
		elem.request_paint();
	}
	elem.set_cursor(Cursor.DEFAULT);
}

fn bool JointDials.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	switch (event.kind)
	{
		case PRESS:
			if (event.button != MouseButton.LEFT) return false;
			int column = self.dial_at(elem, event.pos);
			if (column < 0) return false;
			self.grab(elem, app, (usz)column, event.pos);
			return true; // consuming the press captures the pointer
		case MOVE:
			if (self.held == 0)
			{
				int over = self.dial_at(elem, event.pos);
				int lit = over < 0 ? 0 : over + 1;
				if (lit != self.lit)
				{
					self.lit = lit;
					elem.request_paint();
				}
				elem.set_cursor(lit > 0 ? Cursor.CROSSHAIR : Cursor.DEFAULT);
				return false;
			}
			// The gesture can end underneath the hand — Escape cancels it from the
			// shortcut layer — and the dial finds that out here rather than
			// turning a joint nothing is holding.
			if (app.drag.dot == 0 || !app.drag.dial)
			{
				self.held = 0;
				elem.request_paint();
				return true;
			}
			self.sweep(elem, app, event.pos);
			return true;
		case RELEASE:
			// Also a release the widget did not see the press of: a card rebuilt
			// under the hand hands the gesture to a fresh dials row with no `held`,
			// and the turn it is carrying must still land here rather than hang
			// until Escape.
			if (event.button != MouseButton.LEFT) return false;
			bool dial_turn = app.drag.dot != 0 && app.drag.dial;
			if (self.held == 0 && !dial_turn) return false;
			self.held = 0;
			if (dial_turn) app.end_drag();
			app.refresh_ui();
			elem.request_paint();
			return true;
		default:
			return false;
	}
}

<*
 A press on a dial: the same held turn a viewport ring began, with the sweep
 measured here from now on.

 A dial only exists for an axis the joint may turn about — the card builds none
 for a locked one — so the only refusal left is `begin_turn`'s own, which says
 why in the notice.
*>
fn void JointDials.grab(&self, Element* elem, AppState* app, usz column, Vec2 pixel)
{
	// R's own sweep, or a move, is in flight: the dial stays out of it. A click
	// is what confirms a key-begun gesture, and it belongs to the viewport.
	if (app.drag.dot != 0) return;

	DialState state = dial_state(app);
	if (!state.ready) return;
	if (!app.begin_turn(held: true)) return;

	JointRotationAxis axis = self.axes[column];
	app.drag.dial = true;
	self.held = (int)column + 1;
	self.anchor = dial_angle_at(dial_centre(elem, column), pixel);
	// Off the snapshot the gesture just took, not off the card: the two agree
	// now, and only the snapshot is what `turn_joint_to` measures from.
	self.start = app.turn_start_angle(axis) ?? state.angles[axis.component()];
	self.turned = 0.0f;
	app.refresh_ui();
	elem.request_paint();
}

<*
 One mouse move of a dial drag. The delta is unwrapped, as the viewport's sweep
 is, so passing the bottom of the dial is a step and not most of a revolution
 the other way.
*>
fn void JointDials.sweep(&self, Element* elem, AppState* app, Vec2 pixel)
{
	usz column = (usz)(self.held - 1);
	float now = dial_angle_at(dial_centre(elem, column), pixel);
	self.turned += wrapped_to_pi(now - self.anchor);
	self.anchor = now;

	app.turn_joint_to(self.axes[column], self.start + self.turned);
	// The fields under the dials are the same numbers, kept live by hand: the
	// card holds its subtree still for the drag, so nothing rebuilds them.
	refresh_joint_degree_fields(elem.ui, app);
	app.refresh_ui();
	elem.request_paint();
}

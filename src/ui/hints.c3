<*
 The keymap for whatever is running, along the bottom edge of the pane.

 Split from the stats block in the opposite corner because the two answer
 different questions and go stale on different clocks. The block says what is
 true; this says what the keys mean *now*, and it is derived from the app state
 every frame instead of being printed once into the notice line. A hint written
 as a notice outlives the mode that wrote it — which is how "scroll to size the
 ring" stayed on screen with no ring anywhere and no wheel bound to one.

 With nothing modal running the bar shows the workflow guide's next step, or is
 blank. Keys that always work belong in Help > Controls, where they can be read
 without covering the model.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::io;

<*
 The box the line is painted in.

 Fixed rather than measured per line: the bar is anchored by its own edges, so a
 width that moved with the text would move the text with it, and a hint that
 changed length would need the pane laid out again instead of repainted. Wide
 enough for the longest line in `hint_line`; a pane narrower than this clips the
 tail, which is the same bargain the stats block makes.
*>
const float HINT_BOX_W = 760.0;

// The chaining line names a joint, so it is formatted rather than static; here
// rather than in temp memory because the bar polls it every frame.
char[192] chain_hint_buffer;

<*
 What the keys do right now, or the empty string when nothing modal is running.

 Ordered by what actually has the keyboard, not by importance: a move in
 progress claims X/Y/Z and escape before any mode is asked, and the brush claims
 the plain drag and escape before the lasso is. `AppRoot.on_key` and
 `Viewport.on_event` resolve them in this order, and a bar that listed them in
 any other would promise a key that the layer above it is going to eat.

 The returned strings are printed verbatim, so the wording here is the wording
 on screen. The chaining line is formatted into `chain_hint_buffer`.
*>
fn String hint_line(AppState* app)
{
	if (app.transform_interaction.active) return app.transform_status();

	// The pointer is on a tool cell: its keys, which wins over the idle lines
	// below but not over a gesture already in hand above.
	String hovered = app.ui ? widgets::tooltip_hint(app.ui) : "";
	if (hovered.len > 0 && app.drag.dot == 0 && !tool_hint_running(app, hovered)) return hovered;

	if (app.drag.dot != 0)
	{
		// A dial's turn has its axis in hand already; the only key it answers
		// to is the one that lets go.
		if (app.drag.dial) return "drag · turn about the dial's axis     esc · cancel";
		if (app.drag.verb == DragVerb.TURN)
		{
			return app.drag.axis == DragAxis.FREE
				? "X / Y / Z · bone-local rotation axis     Y or B · twist along bone     esc · cancel"
				: "X / Y / Z · switch local axis     same key · free rotation     Y or B · bone twist     esc · cancel";
		}
		return app.drag.axis == DragAxis.FREE
			? "X / Y / Z · world axis     shift + axis · world plane     B · bone axis     esc · cancel"
			: "X / Y / Z · switch axis     shift + axis · plane     B · bone axis     same key · free     esc · cancel";
	}

	// A plain drag on the mesh paints the way the options strip says; off the
	// mesh it orbits. The modifiers are accelerators.
	if (app.brushing)
	{
		return app.brush_removes
			? "drag the mesh · take the joint off     drag off it · orbit     ctrl-drag · put on     hold F · size     esc · leave"
			: "drag the mesh · put the joint on     drag off it · orbit     ctrl+shift-drag · take off     hold F · size     esc · leave";
	}

	// Directly under the brush, matching the order the press ladder resolves
	// them in — the two never open together, so the pair is listed adjacent
	// rather than interleaved with the modes that can.
	//
	// One tool, two lines: the gesture is the same and everything it does is
	// different, so a line covering both would describe neither. The selecting
	// half names the letter that walks on to the other job, and only while that
	// step can be taken — a bar that offered it with nothing selected would be
	// promising a key that is about to refuse.
	if (app.sketching)
	{
		if (app.sketch_erasing) return "drag · take off the marks you pass     pick a colour at the top to draw again     esc · leave";
		return "drag · draw a mark (red wrong, green keep, blue note)     colours and eraser · the strip at the top     esc · leave";
	}

	if (app.lassoing)
	{
		if (app.lasso_job == LassoJob.PIN)
		{
			return "drag · circle vertices to pin to the selected joint     ctrl-drag · unpin     hold alt · through the model     esc · leave";
		}
		return app.selected != 0 && !app.rig_locked()
			? "drag · circle joints to select them     ctrl-drag · deselect     alt-drag · add     T · pin instead     esc · leave"
			: "drag · circle joints to select them     ctrl-drag · deselect     alt-drag · add to the selection     esc · leave";
	}

	if (app.areaing)
	{
		if (app.area_islands)
		{
			return "click · add or remove an island     shift-drag · paint islands in     ctrl-drag · paint them out     enter · apply     esc · drop";
		}
		return app.area_pending()
			? "click or scroll · own / children / islands     shift-drag · grow     ctrl-drag · shrink     enter · apply     esc · drop"
			: "click the mesh · pick a part     shift-drag · grow from a point     esc · leave";
	}

	String tool = transform_tool_hint(app);
	if (tool.len > 0) return tool;

	// Auto-connect made visible: the pointer is over the mesh and a click would
	// bond the new joint to the selected one (the viewport draws the dashed bone).
	if (app.chain_preview != 0 && app.chain_preview == app.selected && chaining_ready(app))
	{
		Dot* from = app.doc.find(app.selected);
		String name = from && from.name.len > 0 ? from.name : "the selected joint";
		char[]? line = io::bprintf(chain_hint_buffer[..], "chaining from %s · esc to start a new limb     A · auto-connect off", name);
		if (try line) return (String)line;
		return "chaining from the selected joint · esc to start a new limb";
	}
	return "";
}

<*
 What the bar shows: the running tool's keys, or with none running the workflow
 guide's next step.
*>
fn String bar_line(AppState* app)
{
	String line = hint_line(app);
	return line.len > 0 ? line : guide_next_line(app);
}

<*
 Paints `bar_line`, and nothing when it has nothing to say.

 Holds the line it last drew for the same reason `HudOverlay` holds a snapshot:
 the bar has no event to repaint on — the state it reads is changed by keys the
 root handles and by a wheel the viewport handles — so it polls once a frame and
 asks for paint only when the answer moved.
*>
struct HintBar (Widget)
{
	String shown;
	char[256] storage; // `shown` points here: a line may be formatted per frame
}

// Text over an interactive surface: a click along the bottom of the pane is
// aimed at the model, not at the reminder printed over it.
fn void HintBar.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

fn Vec2 HintBar.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ HINT_BOX_W, HUD_LINE_H });
}

fn void HintBar.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	String now = bar_line(app);
	if (now != self.shown)
	{
		sz n = math::min(now.len, (sz)self.storage.len);
		self.storage[:n] = now[:n];
		self.shown = (String)self.storage[:n];
		elem.request_paint();
	}
}

fn void HintBar.paint(&self, Element* elem, Painter* painter) @dynamic
{
	if (self.shown.len == 0) return;
	painter.text({ 0, 0 }, self.shown, { .size = HUD_TEXT_SIZE, .color = TEXT_DIM });
}

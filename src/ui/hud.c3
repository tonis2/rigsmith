<*
 The on-canvas stats block, Blender-style: the mesh and its counts, the modes
 that are on, what is selected and the last result, drawn in the viewport's
 top-left corner instead of a panel.

 Only what is *true and changing*. Keys go in `HintBar` along the bottom of the
 pane, and everything that is always true goes in Help > Controls: a line the
 reader has learned to skip costs the same screen as one they read, and the
 block sits over the model either way.

 A single widget painting lines rather than a column of Labels, because every
 line is derived from AppState and half of them come and go — a Label per line
 means re-pointing borrowed slices on every change, which is the bookkeeping
 the old side panel spent most of its code on. Text is formatted into a local
 buffer at paint time; `Painter.text` emits glyphs immediately and keeps no
 pointer into the string, so the buffer can live on the stack.

 What the block says is `hud_lines` and what it looks like is `HudOverlay.paint`,
 which is a split worth the indirection: the display list records text as atlas
 quads, so with the wording inside the paint the only question a test could ask
 about this block was how many glyphs of a colour it emitted.

 Transparent to the pointer: it is decoration over an interactive surface, and
 a click through "12 dots" should place a dot.
*>
module crig;

import cui;
import std::io;
import std::math;

const float HUD_LINE_H = 19.0;
const float HUD_TEXT_SIZE = 13.0;

// Between the state block and the result under it — see `HudLine.set_off`.
const float HUD_GAP = 6.0;

// One byte-width of " · ", the separator the mode line is built from — a
// leading separator per part, sliced off the front of the finished string.
const usz HUD_SEPARATOR_LEN = 4;

// The file, the modes, the move readout, the selection, the result. Every one
// of them can be up at once, and none of them can be up twice.
const usz HUD_MAX_LINES = 5;

<*
 Everything the block prints, flattened to the fields that decide it. `update`
 diffs one of these per frame against the last one painted, so the HUD repaints
 exactly when a line would change — turning on a mode relights the mode line
 with no one calling refresh, and an idle frame re-emits nothing.
*>
struct HudSnapshot
{
	bool has_mesh;
	usz dots;
	usz edges;
	uint selected;
	usz selection; // how many dots are selected, so the count repaints when it moves
	uint root;
	bool areaing;
	bool auto_connect;
	TintMode tint_mode;
	bool wireframe;
	bool show_mesh;
	bool show_rig;
	String anim_name; // empty when no animation is playing
	usz notice_length;

	// How far the selected joint's influence carries, or 0 for no limit — a
	// number set over MCP now that there is no ring for it.
	float reach;

	// How many vertices the Area tool's pending part holds, or 0 for none.
	usz held;

	// The move in progress. The delta is in here rather than derived at paint
	// time because it changes on every mouse move and the readout is the one
	// line that has to keep up with the pointer.
	uint drag_dot;
	DragAxis drag_axis;
	Vec3 drag_delta;

	// The pose gesture's sweep, here for the same reason as the delta: it changes
	// on every mouse move.
	DragVerb drag_verb;
	float drag_turn;

	// The check's standing, for the modes line.
	bool allow_intersections;
	CollisionMode collision_mode;
}

fn HudSnapshot snapshot(AppState* app) @private
{
	return {
		.has_mesh = app.has_mesh(),
		.dots = (usz)app.doc.dots.len(),
		.edges = (usz)app.doc.edges.len(),
		.selected = app.selected,
		.selection = app.selection_count(),
		.root = app.doc.root_id,
		.areaing = app.areaing,
		.auto_connect = app.doc.auto_connect,
		.tint_mode = app.tint_mode,
		.wireframe = app.wireframe(),
		.show_mesh = app.show_mesh,
		.show_rig = app.show_rig,
		.anim_name = app.animating ? app.current_anim.name : "",
		.notice_length = app.notice_length,
		.drag_dot = app.drag.dot,
		.drag_axis = app.drag.axis,
		.drag_delta = app.drag_delta(),
		.drag_verb = app.drag.verb,
		.drag_turn = app.drag.turned,
		.allow_intersections = app.doc.allow_intersections,
		.collision_mode = app.collision_mode,
		.reach = selected_reach(app),

		// Only while the falloff view is up, because that is the pass that counts
		// it — anywhere else the field still holds whichever joint was painted
		// last, and a number about the wrong dot is worse than no number.
		.held = app.areaing ? app.area_held() : 0,
	};
}

<*
 How far the selected dot's influence carries, or 0 when it carries as far as
 the falloff takes it.

 Zero also when nothing is selected, which is the same blank line: a reach is a
 property of one dot, and with none chosen there is no dot for the number to be
 about.
*>
fn float selected_reach(AppState* app) @private
{
	Dot* dot = app.doc.find(app.selected);
	return dot ? dot.reach : 0.0f;
}

<*
 What to call the selected dot: its name, or "joint <id>" while it has none.

 The name, because that is what the rest of the program calls it — the label in
 the viewport, the joint in a clip, the argument to every MCP op — and an id is
 a number the user never types. The fallback is not cosmetic: a hand-placed dot
 has no name until it is given one, and it still has to be identifiable while
 the pin and the previews are aiming at it.

 @param text : `Where the fallback is formatted. A named dot does not touch it.`
 @return `A slice of the dot's own name, or of the scratch, or "nothing" when the selection is empty.`
*>
fn String selected_label(AppState* app, HudText* text) @private
{
	Dot* dot = app.doc.find(app.selected);
	if (!dot) return "nothing";
	if (dot.name.len > 0) return dot.name;

	String written = text.@printf("joint %d", dot.id);
	return written.len > 0 ? written : "a joint";
}

<*
 A bump over the caller's buffer.

 Every line the block prints is a slice of one buffer and they all have to
 survive until the last one is painted, so each formatted piece takes what it
 needs from the front and leaves the rest. Nothing is freed or rewound: the
 block builds each line exactly once.
*>
struct HudText
{
	char[] buffer;
	usz used;
}

<*
 Formats onto the end of the buffer and hands back what was written.

 A macro so the text is built in place and nothing is allocated to say
 something — the same trade `AppState.@notice` makes.

 @return `The formatted text, or the empty string when what is left of the buffer could not hold it.`
*>
macro String HudText.@printf(&self, String format, args...)
{
	char[]? written = io::bprintf(self.buffer[self.used..], format, ...args);
	if (catch written) return "";
	self.used += written.len;
	return (String)written;
}

<*
 One line of the block and the colour it is drawn in.
*>
struct HudLine
{
	String text;
	Color color;

	// Set off from what is above it by a gap. Carried on the line rather than
	// worked out at paint time so `hud_lines` stays the only place that decides
	// what the block says and how it is grouped.
	bool set_off;
}

<*
 Everything the block prints, in order, as text and colour.

 The wording of the whole panel lives here and nowhere else. Split from the
 paint because a display list records text as atlas quads: with these strings
 built inside `HudOverlay.paint`, nothing could ask what the block actually says.

 @param app : `The editor being described.`
 @param shown : `The snapshot the last frame accepted, for the values that move faster than paints — the drag delta and the reach.`
 @param buffer : `Scratch every formatted line is carved out of. Must outlive the lines written to out.`
 @param out : `Filled from the front. Shorter than HUD_MAX_LINES and the tail is dropped.`
 @return `How many entries of out were filled.`
*>
fn usz hud_lines(AppState* app, HudSnapshot shown, char[] buffer, HudLine[] out)
{
	HudText text = { .buffer = buffer };
	usz count = 0;

	// --- what is loaded, and how much of a rig is on it ----------------------
	//
	// Three cases for the first half: a path names the file; no mesh at all says
	// so, since an empty block over an empty view reads as an editor that has
	// lost track of what it is showing; and a mesh with no path — a test's, built
	// in memory — leaves that half out, having nothing true to put in it.
	usz dots = (usz)app.doc.dots.len();
	usz bones = (usz)app.doc.edges.len();
	String source = app.source_path.len > 0
		? base_name(app.source_path)
		: (app.has_mesh() ? "" : "no model");
	String head = source.len > 0
		? text.@printf("%s · %d joint%s · %d bone%s",
			source, dots, dots == 1 ? "" : "s", bones, bones == 1 ? "" : "s")
		: text.@printf("%d joint%s · %d bone%s",
			dots, dots == 1 ? "" : "s", bones, bones == 1 ? "" : "s");
	if (head.len > 0 && count < out.len) out[count++] = { .text = head, .color = TEXT };

	// --- the modes that are on -----------------------------------------------
	//
	// Only the non-default ones are named: a line that always says "chain" is a
	// line nobody reads, and one that appears only when something is off is a
	// line that is read every time.
	String tinting = "";
	switch (app.tint_mode)
	{
		case TERRITORY:
			tinting = " · weights";
		case FALLOFF:
			{
				// The joint being shown is the selection, and the chip names it —
				// "falloff" alone does not say falloff of what.
				String about = selected_label(app, &text);
				tinting = text.@printf(" · falloff of %s", about);
			}
		default:
			break;
	}

	// The clip carries its own name rather than a second line saying it plays:
	// the chips are a list of what is on, and which clip is on is part of that.
	String playing = "";
	if (app.animating)
	{
		playing = app.current_anim.name.len > 0
			? text.@printf(" · %s", app.current_anim.name)
			: " · animation";
	}

	// The self-collision check, when it is not simply on: off, or cut back
	// for a mesh that cannot keep up. Named here for the reason the hidden
	// halves are: a joint that passes through the body, or stops stopping at
	// it, must be a state the screen admits to rather than a bug to wonder at.
	// Nothing at all with the system switched off: a joint passing through
	// the body is then the ordinary state, not a mode.
	String colliding = !app.config.self_collision
		? ""
		: app.doc.allow_intersections
			? " · intersections allowed"
			: app.collision_mode == PAUSED
				? " · collision check paused"
				: app.collision_mode == REDUCED
					? " · collision check reduced"
					: "";

	// The two hidden states earn their place for a reason the rest of this line
	// does not need: a half of the view that is simply absent looks like a bug,
	// and this is the only thing on screen that can say it was asked for.
	String modes = text.@printf("%s%s%s%s%s%s%s%s",
		app.areaing ? " · area" : "",
		app.doc.auto_connect ? "" : " · no chain",
		app.show_mesh ? "" : " · mesh hidden",
		app.show_rig ? "" : " · rig hidden",
		app.wireframe() ? " · wireframe" : "",
		tinting,
		playing,
		colliding);
	if (modes.len > 0 && count < out.len)
	{
		out[count++] = { .text = modes[HUD_SEPARATOR_LEN..], .color = ACCENT };
	}

	// --- the move in progress ------------------------------------------------
	//
	// How far the dot has travelled on each axis, and which one it is confined
	// to. Locked, it prints the one number that is allowed to change, in the
	// colour of the line drawn through the dot.
	//
	// Numbers only. The keys that go with them are on the hint bar along the
	// bottom of the pane, which is where every modal tool's keys are, so a move
	// does not answer the question in a different corner from the rest.
	if (app.drag.dot != 0)
	{
		Vec3 delta = shown.drag_delta;
		int component = app.drag.axis.component();
		int plane_normal = app.drag.axis.plane_normal_component();
		// A turn carries the joint nowhere, so the delta above is three zeros and
		// says nothing. Degrees rather than radians: it is the number the person
		// doing it thinks in, and it is the only place radians would surface.
		String turn_axis = app.drag.axis == DragAxis.FREE
			? "view"
			: app.drag.axis == DragAxis.BONE
				? "local bone"
				: app.drag.axis == DragAxis.X
					? "local X"
					: app.drag.axis == DragAxis.Y
						? "local Y"
						: "local Z";
		// A blocked turn reads the sweep asked for, not where the joint stopped:
		// the number is where the pointer is, and the joint is visibly not
		// there, which is all a stop at the body has to say.
		String move = app.drag.verb == DragVerb.TURN
			? text.@printf("turn %s %+.1f\u00b0", turn_axis,
				math::rad_to_deg(shown.drag_turn))
			: component >= 0
				? text.@printf("move %s %+.3f", app.drag.axis.label(), delta[component])
				: plane_normal >= 0
					? plane_normal == 0
						? text.@printf("move YZ %+.3f %+.3f", delta.y, delta.z)
						: plane_normal == 1
							? text.@printf("move XZ %+.3f %+.3f", delta.x, delta.z)
							: text.@printf("move XY %+.3f %+.3f", delta.x, delta.y)
					: app.drag.axis == DragAxis.BONE
						? text.@printf("move bone %+.3f", delta.dot(app.drag.lock_direction))
						: text.@printf("move %+.3f %+.3f %+.3f", delta.x, delta.y, delta.z);
		if (move.len > 0 && count < out.len)
		{
			out[count++] = { .text = move, .color = app.drag.axis.color() };
		}
	}

	// --- what is selected ----------------------------------------------------
	if (app.selected != 0)
	{
		// A reach is set over MCP only; a limited joint prints the figure.
		String reach = shown.reach > 0.0f ? text.@printf(" · reach %.3f", shown.reach) : "";

		// The Area tool's pending part, as a count: what Apply would hand over.
		String holds = "";
		if (app.areaing && shown.held > 0)
		{
			holds = text.@printf(" · part %d vertices", shown.held);
		}
		else if (app.areaing)
		{
			holds = " · click the mesh to pick a part";
		}

		// A group says its size and names its anchor, since the anchor is the one
		// the modes and the previews act through — "3 dots selected" alone would
		// leave the user guessing which of them a lasso pin is about to hand to.
		String chosen = selected_label(app, &text);
		String root = app.selected == app.doc.root_id ? " · root" : "";
		String line = shown.selection > 1
			? text.@printf("%d joints selected · %s%s%s%s", shown.selection, chosen, root, reach, holds)
			: text.@printf("%s selected%s%s%s", chosen, root, reach, holds);
		if (line.len > 0 && count < out.len)
		{
			out[count++] = { .text = line, .color = TEXT_DIM };
		}
	}

	// --- the last result -----------------------------------------------------
	//
	// An event rather than state: what the last thing done came to, or why it
	// could not be. Set off from the block above, and it goes quiet by itself —
	// see `AppState.tick_notice`.
	if (app.notice().len > 0 && count < out.len)
	{
		out[count++] = { .text = app.notice(), .color = ACCENT, .set_off = true };
	}

	return count;
}

fn bool HudSnapshot.differs(self, HudSnapshot other)
{
	return self.has_mesh != other.has_mesh
		|| self.dots != other.dots
		|| self.edges != other.edges
		|| self.selected != other.selected
		|| self.selection != other.selection
		|| self.root != other.root
		|| self.areaing != other.areaing
		|| self.auto_connect != other.auto_connect
		|| self.tint_mode != other.tint_mode
		|| self.wireframe != other.wireframe
		|| self.show_mesh != other.show_mesh
		|| self.show_rig != other.show_rig
		|| self.anim_name != other.anim_name
		|| self.notice_length != other.notice_length
		|| self.drag_dot != other.drag_dot
		|| self.drag_axis != other.drag_axis
		|| self.drag_delta != other.drag_delta
		|| self.drag_verb != other.drag_verb
		|| self.drag_turn != other.drag_turn
		|| self.allow_intersections != other.allow_intersections
		|| self.collision_mode != other.collision_mode
		|| self.reach != other.reach
		|| self.held != other.held;
}

struct HudOverlay (Widget)
{
	HudSnapshot shown; // what the last repaint reflected
}

// Stats drawn over the model, and the model has to stay draggable underneath
// them: ui_test drags from the middle of this block to prove it.
fn void HudOverlay.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

fn Vec2 HudOverlay.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	// Room for every line that can be up at once — the file, the modes, the move
	// readout and the selection — plus the notice under them with its gap. A block
	// sized to the common case clips the notice away exactly when the most is
	// going on.
	return constraints.constrain({ 320.0, 6 * HUD_LINE_H });
}

fn void HudOverlay.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	HudSnapshot now = snapshot(app);
	if (now.differs(self.shown))
	{
		self.shown = now;
		elem.request_paint();
	}
}

fn void HudOverlay.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	// Big enough for every line at once with a long path on the first of them. A
	// line that will not fit comes back empty and is dropped, so overflow costs a
	// line rather than the block.
	char[512] buffer;
	HudLine[HUD_MAX_LINES] lines;
	usz count = hud_lines(app, self.shown, buffer[..], lines[..]);

	float y = 0;
	for (usz i = 0; i < count; i++)
	{
		if (lines[i].set_off) y += HUD_GAP;
		painter.text({ 0, y }, lines[i].text, { .size = HUD_TEXT_SIZE, .color = lines[i].color });
		y += HUD_LINE_H;
	}
}

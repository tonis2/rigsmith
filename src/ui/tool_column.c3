<*
 The tool column: a stack of icon buttons down the left edge of a 3D view, one
 per tool that claims the drag over the model, lit while its tool is running.

 Blender's toolbar, and for Blender's reason. A mode reached only by a key and a
 row in a menu is a mode a user has no reason to believe exists — which is
 exactly what happened to the lasso, the most capable weight tool in the program
 and the one nobody finds. A column of glyphs says the tools are there before
 anything is pressed, and says which one has the mouse while it is running.

 **Composed rather than painted.** The column is a `Column` of cui `Button`s and
 the only thing crig draws by hand is the glyph inside each one — see
 `ToolIcon`. So hover, press, the pointer capture and the cursor all come from
 the button that already had them, and this file holds no hit-testing at all.
 That is also why the state is re-*built* rather than repainted: what a cell
 looks like is its button's style, decided when the subtree is made, so a lasso
 opened from the keyboard reaches the screen by `update` noticing and asking for
 another build.

 **Seven cells.** Select/Tweak, Move, Rotate, Scale, Lasso, Area, the weight
 brush and Sketch. Scale always resizes the whole model, whatever is selected. While the brush is open its options strip (`BrushOptions`) shows beside
 the column, so painting needs no modifier; while sketching, the Sketch strip
 (`SketchToolbar`) offers the colours and the eraser. Sketch has no key at all —
 this cell is its one door.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

// One cell, and the space between two. Square, unlike the tint strip's cells:
// these hold a glyph and nothing else, and a square is what makes a vertical
// stack of them read as a column rather than as a list of rows.
const float TOOL_CELL_W = 30.0;
const float TOOL_CELL_H = 30.0;
const float TOOL_CELL_GAP = 4.0;

// Gap from the pane's own edges. The vertical matches the stats block's, so the
// column and the first line of text start at the same height.
const float TOOL_MARGIN_X = 12.0;
const float TOOL_MARGIN_Y = 14.0;

<*
 Where the stats block's left edge goes, now that the column is under it.

 Blender's arrangement: the toolbar against the edge, the text beside it rather
 than over it. Derived rather than typed so the two cannot drift — a wider cell
 moves the text with it.
*>
const float HUD_LEFT_MARGIN = TOOL_MARGIN_X * 2.0 + TOOL_CELL_W;

const float TOOL_ICON_R = 8.0;
const float TOOL_STROKE = 1.5;

// The mark in a cell's corner for a tool with more than one job, Blender's own
// affordance for it. An L rather than the triangle Blender draws, because a
// filled triangle is a triangulation and this is four pixels across.
const float TOOL_VARIANT_MARK = 5.0;
const float TOOL_VARIANT_INSET = 3.0;

// How many dashes the lasso's loop is drawn in, and how much of each step is
// ink. Marching ants: the convention for a selection boundary everywhere, and
// what tells this glyph apart from the tint strip's rings at a glance.
//
// Eight rather than the four or five that would be less work to draw. Few dashes
// leave gaps wide enough that the eye stops joining them into a circle and starts
// reading two facing arcs instead — which beside the centre dot of the pinning
// variant came out looking like an eye.
const usz TOOL_LASSO_DASHES = 8;
const float TOOL_LASSO_DASH_FILL = 0.58;

const Vec4 TOOL_CELL_RADII = { 6.0, 6.0, 6.0, 6.0 };

<*
 Which glyph a cell wears. Not "which tool" — the tool is the query and the
 handler, both borrowed from the menus, and this is only the picture.
*>
enum ToolGlyph
{
	TWEAK,
	MOVE_GLYPH,
	ROTATE_GLYPH,
	SCALE_GLYPH,
	LASSO,
	SKETCH_GLYPH,
}

<*
 One cell. The state and the action are the menu's own wiring, borrowed whole,
 so a rule added to a query greys the item and the cell in the same edit.
*>
struct ToolCell
{
	ToolGlyph glyph;
	MenuQuery state;
	OnClick on_select;
	// "Name (key) — what it does", shown as the tooltip, and the keys line the
	// hint bar shows while the pointer is on the cell. Literals, so the tooltip
	// can borrow them.
	String tip;
	String hint;
}

// A global rather than a const for the same reason the menus are: these
// initialisers take function addresses.
ToolCell[6] tool_cells = {
	{ .glyph = TWEAK, .state = &query_tweak, .on_select = &menu_tweak,
		.tip = "Tweak (Esc) — put the running tool away: click to select, drag to move or pose a joint",
		.hint = "Tweak · click a joint · select     drag a joint · move or pose it     drag off the model · orbit     esc · put a tool away" },
	{ .glyph = MOVE_GLYPH, .state = &query_move_tool, .on_select = &menu_move_tool,
		.tip = "Move (G) — drag the selected joint along the view, or lock an axis with X / Y / Z",
		.hint = "Move · G · drag the selected joint     X / Y / Z · lock an axis     shift + axis · lock a plane     esc · cancel" },
	{ .glyph = ROTATE_GLYPH, .state = &query_rotate_tool, .on_select = &menu_rotate_tool,
		.tip = "Rotate (R) — turn the selected joint about the pointer, or lock an axis with X / Y / Z",
		.hint = "Rotate · R · sweep the pointer around the joint     X / Y / Z · lock a local axis     esc · cancel" },
	// Always the whole model, whatever is selected — see `SCALE_TOOL`. An exact
	// height is the model's right-click menu, Scale model….
	{ .glyph = SCALE_GLYPH, .state = &query_scale_tool, .on_select = &menu_scale_tool,
		.tip = "Scale — drag the ring to resize the whole model and its rig; type a factor while dragging",
		.hint = "Scale · drag the ring out to grow, in to shrink     type a factor     release / enter · confirm     esc · cancel" },
	{ .glyph = LASSO, .state = &query_lasso_tool, .on_select = &menu_lasso_select,
		.tip = "Lasso (T) — circle joints to select them; shift+T pins mesh vertices to the selected joint instead",
		.hint = "Lasso · T · drag to circle joints     ctrl-drag · deselect     alt-drag · add     shift+T · pin vertices instead" },
	{ .glyph = SKETCH_GLYPH, .state = &query_sketching, .on_select = &menu_sketch,
		.tip = "Sketch — draw on the viewport to show the agent what is wrong; colours and the eraser appear at the top",
		.hint = "Sketch · drag to draw     red wrong · green keep · blue note · eraser — in the strip at the top     esc · leave" },
};

<*
 Whether `hint` is the keys line of the tool that is on right now.

 The hint bar has a fuller line for a running tool, so it offers a cell's keys
 only for the cells that are not lit. Asked of the queries rather than baked
 into the tooltip at build, which would lag a click by a build.
*>
fn bool tool_hint_running(AppState* app, String hint)
{
	foreach (cell : tool_cells)
	{
		if (cell.hint == hint) return cell.state(app.ui).checked;
	}
	return false;
}

<*
 The tooltip for a cell in the state its query put it in.

 A greyed cell says why, in the words its query used to grey it — the rules are
 the ones in `query_lasso_tool`, so a change to
 one is a change to its sentence here. Literals, so the wrapper can borrow them.
*>
fn String tool_tip(AppState* app, usz index, MenuItemFlags flags)
{
	if (!flags.disabled) return tool_cells[index].tip;
	switch (tool_cells[index].glyph)
	{
		case LASSO:
			return app.show_rig
				? "Lasso (T) — unavailable: place a joint first"
				: "Lasso (T) — unavailable: the rig is hidden (S shows it)";
		default:
			return tool_cells[index].tip;
	}
}

<*
 Whether the lasso is running, and whether it could be started.

 The cell's own query rather than either job's: a cell is the *tool*, so it is
 lit for both jobs, where `query_lasso_select` and `query_lasso` each answer
 about one. Greyed only when the tool could not be opened at all — never while
 it is running, since a lit cell that is also greyed is a cell claiming two
 things at once.
*>
fn MenuItemFlags query_lasso_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return {
		.checked = app.lassoing,
		.disabled = !app.lassoing && (app.doc.dots.len() == 0 || !app.show_rig),
	};
}

struct ToolColumn (Widget)
{
	// What the last build drew. Polled per frame rather than pushed, because the
	// keyboard opens and closes these tools as much as a click does and neither
	// path knows this widget exists — the bargain `TintToggles` and the HUD both
	// make.
	MenuItemFlags[7] shown;
	bool had_mesh;
}

<*
 The cells, or nothing at all when there is no model.

 An empty `Column` rather than an absent widget: it measures zero, so the
 anchor holding it places nothing and the tools appear with the mesh they are
 for. `OpenPrompt` does the same thing with the sense reversed.

 The queries are read here as well as in `update`, so the first frame a build
 lands on is already right rather than one frame behind — otherwise the column
 would come up with no cell lit and correct itself immediately afterwards.
*>
fn Element* ToolColumn.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.had_mesh = app.has_mesh();

	return @subtree(elem.ui)
	{
		@tree((Column) { .gap = TOOL_CELL_GAP })
		{
			if (self.had_mesh)
			{
				foreach (i, cell : tool_cells)
				{
					MenuItemFlags flags = cell.state(elem.ui);
					self.shown[i] = flags;

					// Dark ink on the lit cell: the accent is a light warm fill and
					// pale ink on it would vanish exactly when it matters most.
					Color ink = TEXT;
					if (flags.checked)
					{
						ink = DOT_OUTLINE;
					}
					else if (flags.disabled)
					{
						ink = TEXT_DIM.dim(0.55);
					}

					// A greyed cell keeps its button and loses only the handler, which
					// is what makes it still swallow the press: it is a control over
					// the model, and letting the click through would place a dot
					// behind it.
					@tree(widgets::tip(tool_tip(app, (usz)i, flags), cell.hint))
					{
						@tree(tool_button(flags, flags.disabled ? null : cell.on_select))
						{
							@node((ToolIcon) { .glyph = cell.glyph, .ink = ink });
						};
					};
				}
			}
		};
	};
}

<*
 Re-reads the queries and rebuilds when one of them moved.

 `request_build` rather than `request_paint` — the cells' colours are their
 buttons' styles, so the picture changes by making it again. Only on a real
 change: this runs every frame, and rebuilding a subtree per frame would be a
 fresh element tree sixty times a second for a column nobody touched.
*>
fn void ToolColumn.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	bool changed = app.has_mesh() != self.had_mesh;
	if (self.had_mesh)
	{
		foreach (i, cell : tool_cells)
		{
			MenuItemFlags now = cell.state(elem.ui);
			if (now.checked != self.shown[i].checked || now.disabled != self.shown[i].disabled)
			{
				self.shown[i] = now;
				changed = true;
			}
		}
	}
	if (changed) elem.request_build();
}

<*
 One cell's chrome, in the state the query put it in.

 `panel_button`'s icon-sized sibling, and the reason it is here rather than in
 `theme.c3`: the lit state is a *radio* state — at most one cell on — which is a
 fact about this column and not about buttons in general. The lit fill does not
 change on hover, for `accent_button`'s reason: the accent is already the
 loudest thing in the corner.

 @param flags : `The polled state; only the checked half changes the look here.`
 @param on_click : `Null for a greyed cell, which still takes the press.`
*>
fn Button tool_button(MenuItemFlags flags, OnClick on_click)
{
	Color fill = flags.checked ? ACCENT : BTN;
	return {
		.size = { TOOL_CELL_W, TOOL_CELL_H },
		.style = { .color = fill, .border_radius = TOOL_CELL_RADII },
		.hover_style = { .color = flags.checked ? ACCENT : BTN_HOVER, .border_radius = TOOL_CELL_RADII },
		.press_style = { .color = BTN_PRESS, .border_radius = TOOL_CELL_RADII },
		.on_click = on_click,
	};
}

<*
 The glyph inside a cell: a leaf that fills its button and draws one shape.

 Painted from primitives rather than loaded from an atlas — there is no icon font
 in the build, and `TintToggles` already draws its two the same way.

 It reads the app rather than being told, for the one thing a cell's *table entry*
 cannot know: which job the lasso is on. That changes while the column is up, and
 the glyph is what says so.
*>
struct ToolIcon (Widget)
{
	ToolGlyph glyph;
	Color ink;
}

// Fills the cell it sits in, whatever the cell's size is: the glyph is drawn
// from the centre outward, so it has no preference of its own.
fn Vec2 ToolIcon.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.max;
}

fn void ToolIcon.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Vec2 centre = elem.size * 0.5f;

	switch (self.glyph)
	{
		case TWEAK:
			// The pointer itself: what the mouse does when no tool has taken it
			// over. A closed arrowhead aimed up and left — the one arrow direction
			// that reads as "cursor" rather than as "this way" — with the shaft
			// leaving from the middle of its back edge.
			//
			// From the *back edge* and not from the tip: a shaft drawn tip-to-tail
			// crosses the head it belongs to, and what that looks like at sixteen
			// pixels across is a pennant on a pole.
			Vec2 tip = centre + (Vec2){ -TOOL_ICON_R * 0.8f, -TOOL_ICON_R * 0.8f };
			Vec2 down = tip + (Vec2){ 0, TOOL_ICON_R * 1.0f };
			Vec2 across = tip + (Vec2){ TOOL_ICON_R * 1.0f, 0 };
			painter.line(tip, down, TOOL_STROKE, self.ink);
			painter.line(tip, across, TOOL_STROKE, self.ink);
			painter.line(down, across, TOOL_STROKE, self.ink);
			painter.line((down + across) * 0.5f,
				centre + (Vec2){ TOOL_ICON_R * 0.85f, TOOL_ICON_R * 0.85f }, TOOL_STROKE, self.ink);
		case MOVE_GLYPH:
			Vec2 origin = centre + (Vec2){ -3.0f, 3.0f };
			Vec2 x_end = origin + (Vec2){ TOOL_ICON_R + 3.0f, 0 };
			Vec2 y_end = origin - (Vec2){ 0, TOOL_ICON_R + 3.0f };
			painter.line(origin, x_end, TOOL_STROKE, self.ink);
			painter.line(x_end, x_end + (Vec2){ -4.0f, -2.5f }, TOOL_STROKE, self.ink);
			painter.line(x_end, x_end + (Vec2){ -4.0f, 2.5f }, TOOL_STROKE, self.ink);
			painter.line(origin, y_end, TOOL_STROKE, self.ink);
			painter.line(y_end, y_end + (Vec2){ -2.5f, 4.0f }, TOOL_STROKE, self.ink);
			painter.line(y_end, y_end + (Vec2){ 2.5f, 4.0f }, TOOL_STROKE, self.ink);
		case ROTATE_GLYPH:
			float start = (float)math::PI * 0.18f;
			float sweep = (float)math::PI * 1.55f;
			painter.arc(centre, TOOL_ICON_R, start, sweep, TOOL_STROKE, self.ink);
			Vec2 rotate_tip = centre + (Vec2){
				math::cos(start) * TOOL_ICON_R,
				math::sin(start) * TOOL_ICON_R,
			};
			painter.line(rotate_tip, rotate_tip + (Vec2){ -1.0f, 4.5f }, TOOL_STROKE, self.ink);
			painter.line(rotate_tip, rotate_tip + (Vec2){ -4.5f, 0.5f }, TOOL_STROKE, self.ink);
		case SCALE_GLYPH:
			// A small box grown into a larger one, the arrow between their corners
			// saying which way: the resize glyph every editor uses.
			float outer = TOOL_ICON_R;
			float inner = TOOL_ICON_R * 0.45f;
			Vec2 low = centre + (Vec2){ -outer, outer };
			painter.line(low, low + (Vec2){ inner * 2.0f, 0 }, TOOL_STROKE, self.ink);
			painter.line(low, low - (Vec2){ 0, inner * 2.0f }, TOOL_STROKE, self.ink);
			painter.line(low + (Vec2){ inner * 2.0f, 0 }, low + (Vec2){ inner * 2.0f, -inner * 2.0f }, TOOL_STROKE, self.ink);
			painter.line(low - (Vec2){ 0, inner * 2.0f }, low + (Vec2){ inner * 2.0f, -inner * 2.0f }, TOOL_STROKE, self.ink);
			Vec2 far = centre + (Vec2){ outer, -outer };
			painter.line(low + (Vec2){ inner * 2.0f, 0 }, low + (Vec2){ outer * 2.0f, 0 }, TOOL_STROKE * 0.6f, self.ink);
			painter.line(low + (Vec2){ outer * 2.0f, 0 }, far, TOOL_STROKE * 0.6f, self.ink);
			painter.line(far, low - (Vec2){ 0, outer * 2.0f }, TOOL_STROKE * 0.6f, self.ink);
			painter.line(low - (Vec2){ 0, outer * 2.0f }, low - (Vec2){ 0, inner * 2.0f }, TOOL_STROKE * 0.6f, self.ink);
			Vec2 from = low + (Vec2){ inner * 2.0f + 1.5f, -inner * 2.0f - 1.5f };
			Vec2 to = far + (Vec2){ -2.0f, 2.0f };
			painter.line(from, to, TOOL_STROKE, self.ink);
			painter.line(to, to + (Vec2){ -3.5f, 0 }, TOOL_STROKE, self.ink);
			painter.line(to, to + (Vec2){ 0, 3.5f }, TOOL_STROKE, self.ink);
		case LASSO:
			// Marching ants — a dashed loop is what a selection boundary looks like
			// in every program that has one, and it is what keeps this glyph from
			// being read as the tint strip's rings.
			float step = (float)math::TAU / (float)TOOL_LASSO_DASHES;
			for (usz i = 0; i < TOOL_LASSO_DASHES; i++)
			{
				painter.arc(centre, TOOL_ICON_R, step * (float)i, step * TOOL_LASSO_DASH_FILL,
					TOOL_STROKE, self.ink);
			}

			// The dot the region is about to be handed to. Only while it is about
			// to be handed to one: this is the difference between the two jobs, and
			// the only thing on screen that states it before a drag starts.
			if (app.lassoing && app.lasso_job == LassoJob.PIN)
			{
				painter.circle(centre, TOOL_STROKE * 1.6f, { .color = self.ink });
			}

			// And the mark that says the cell has more than one job in it.
			float x = elem.size.x - TOOL_VARIANT_INSET;
			float y = elem.size.y - TOOL_VARIANT_INSET;
			painter.line({ x - TOOL_VARIANT_MARK, y }, { x, y }, 1.0f, self.ink);
			painter.line({ x, y - TOOL_VARIANT_MARK }, { x, y }, 1.0f, self.ink);
		case SKETCH_GLYPH:
			// A pencil down to the left, over the squiggle it has just drawn.
			Vec2 top = centre + (Vec2){ TOOL_ICON_R * 0.9f, -TOOL_ICON_R * 0.9f };
			Vec2 point = centre + (Vec2){ -TOOL_ICON_R * 0.3f, TOOL_ICON_R * 0.3f };
			Vec2 side = { TOOL_ICON_R * 0.22f, TOOL_ICON_R * 0.22f };
			painter.line(top - side, point - side * 0.3f, TOOL_STROKE, self.ink);
			painter.line(top + side, point + side * 0.3f, TOOL_STROKE, self.ink);
			painter.line(top - side, top + side, TOOL_STROKE, self.ink);
			painter.line(point - side * 0.3f, point + side * 0.3f, TOOL_STROKE, self.ink);
			Vec2 squiggle = centre + (Vec2){ -TOOL_ICON_R, TOOL_ICON_R * 0.95f };
			painter.arc(squiggle + (Vec2){ TOOL_ICON_R * 0.3f, 0 }, TOOL_ICON_R * 0.3f,
				(float)math::PI, (float)math::PI, TOOL_STROKE, self.ink);
	}
}

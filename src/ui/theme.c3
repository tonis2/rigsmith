<*
 Palette and the shared widget styling.

 The labelled panel button that used to live here went with the side panel: the
 actions it carried are menu items now, and cui's menu widgets take their look
 from `MENU_STYLE` below rather than from a crig widget.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::math::vector;

// ---- palette (linear RGBA 0..1) ----
const Color BG           = { 0.09, 0.10, 0.13, 1.0 };
const Color PANEL        = { 0.14, 0.15, 0.19, 1.0 };
const Color PANEL_BORDER = { 0.28, 0.30, 0.38, 1.0 };
const Color TEXT         = { 0.92, 0.93, 0.95, 1.0 };
const Color TEXT_DIM     = { 0.55, 0.58, 0.66, 1.0 };
const Color ACCENT       = { 0.95, 0.60, 0.20, 1.0 };
const Color BTN          = { 0.20, 0.22, 0.28, 1.0 };
const Color BTN_HOVER    = { 0.28, 0.31, 0.40, 1.0 };
const Color BTN_PRESS    = { 0.16, 0.17, 0.22, 1.0 };
const Vec4 R8            = { 8.0, 8.0, 8.0, 8.0 };

<*
 The model's own grey, when nothing is tinting it.

 A palette entry rather than a renderer constant: `engine/scene.c3` pushes it
 to three as a node colour, and this is the one place that answers what colour
 an untinted model is.
*>
const Color MESH_COLOR   = { 0.62, 0.64, 0.70, 1.0 };

// ---- rig overlay ----
// Drawn over the mesh with no depth test, so these have to read against both
// the lit grey of the model and the dark background. The dark outline is what
// keeps a dot visible where it crosses a highlight.
const Color DOT          = { 0.30, 0.68, 0.95, 1.0 };
const Color DOT_SELECTED = { 0.98, 0.78, 0.25, 1.0 };
const Color DOT_ROOT     = { 0.40, 0.90, 0.55, 1.0 };
const Color DOT_OUTLINE  = { 0.05, 0.06, 0.09, 1.0 };
// The anchor ring: a joint whose world position is being held while others move.
// Red, apart from every dot state — blue plain, gold selected, green root — so a
// foot pinned to the floor reads as pinned and not as one more selection.
const Color DOT_LOCKED   = { 0.98, 0.42, 0.42, 1.0 };
// The same ring on a pin that did not hold: its limb could not reach the point, or
// the joint limits stood in the way. Orange, between the pin's red and the gold of
// a selection, so a foot that has left its pin reads differently from one that holds.
const Color DOT_PIN_MISSED = { 1.0, 0.62, 0.15, 1.0 };
const Color BONE         = { 0.85, 0.88, 0.95, 0.85 };

// What the physics owns, in a hue nothing else on the overlay uses: the dots are
// blue, the selection orange, the root green, and a bone the solver moves is
// none of those things. The capsule is the same hue thinned out, because a
// collider is the same subject seen from the other side — what a chain is pushed
// out of rather than what swings.
const Color PHYSICS_BONE    = { 0.72, 0.50, 0.98, 1.0 };
const Color PHYSICS_CAPSULE = { 0.72, 0.50, 0.98, 0.55 };

// How far outside a dot its "the physics owns this" ring sits, and how thick it
// is drawn. Inside the root's ring rather than outside it, so a dynamic root —
// which the solver drops, and which the panel refuses to make — still reads as
// both rather than as one ring of an ambiguous size.
const float PHYSICS_RING_GAP = 2.5;
const float PHYSICS_RING_WIDTH = 1.5;

// The capsule outline, which is a hint at a size rather than a handle: thin,
// because it is drawn around a limb that is already there and a heavy circle
// over the mesh reads as part of the model.
const float PHYSICS_CAPSULE_WIDTH = 1.0;

// Where a dot being moved was picked up, and the trail behind it. Hollow and
// half-transparent so it reads as a memory of a position rather than a dot
// that is actually there — but not so faint that it disappears into the lit
// grey of the model, which is exactly where it is usually drawn.
const Color GHOST        = { 0.85, 0.88, 0.95, 0.75 };

// Ghost skeletons (the fallback when there is no skinned mesh): behind the
// playhead warm, ahead cool, both faint so the live rig stays the thing being
// read. Alpha falls with each ghost further out.
const Color ONION_BEFORE = { 1.00, 0.45, 0.22, 0.50 };
const Color ONION_AFTER  = { 0.30, 0.62, 1.00, 0.50 };

// Ghosts as see-through copies of the mesh and as the timeline's shade around the
// playhead: the frames behind it warm, the frames ahead cool. Their alpha is set
// where they are drawn, by distance from the playhead.
const Color GHOST_PAST_TINT   = { 1.00, 0.45, 0.22, 1.0 };
const Color GHOST_FUTURE_TINT = { 0.30, 0.62, 1.00, 1.0 };

// The selected joint's motion path, its key dots and the playhead marker on it.
const Color MOTION_PATH  = { 0.55, 0.95, 0.75, 0.70 };
const Color MOTION_KEY   = { 0.98, 0.95, 0.60, 0.95 };

// How much colour the constraint line keeps. It crosses the whole viewport, so
// at full strength it reads as part of the rig instead of scaffolding over it.
const float GUIDE_DIM = 0.6;

// ---- joint names, and where the body plan wants a dot ----
// A size down from the HUD, which is the smallest the font stays legible at over
// the lit grey of the model. Seventeen of these are on screen at once with the
// toggle on, and at HUD size they cover the rig they are annotating.
const float LABEL_SIZE = 11.0;

// Two weights, because the selected dot's name is drawn whether the toggle is on
// or off: with the toggle on it has to be findable among sixteen others, and the
// only thing distinguishing it is that it is brighter and in the selection's own
// colour.
const Color LABEL       = { 0.98, 0.78, 0.25, 1.0 };
const Color LABEL_DIM   = { 0.78, 0.82, 0.90, 0.85 };

// The plan's target for the selected dot, and the line joining the two.
//
// The selection's colour rather than a new one, and that is the whole point:
// ring, line and label are all about the same dot, and a fourth hue in the
// overlay would say they were four separate things. It also keeps the target
// clearly apart from GHOST, which is white and can be on screen at the same time
// — one marks where the dot was picked up, the other where it is wanted.
const Color TARGET_RING = { 0.98, 0.78, 0.25, 0.85 };
const Color TARGET_LINE = { 0.98, 0.78, 0.25, 0.45 };
// A look-at target: the ring and its triangle, the dashed line back to the joint
// that looks, and the same two when that joint is selected. Cool where the plan's
// target is amber, because a target the clip aims at is a different kind of
// thing from a place the rig is wanted.
const Color AIM_RING = { 0.45, 0.80, 0.98, 0.85 };
const Color AIM_LINE = { 0.45, 0.80, 0.98, 0.50 };
const Color AIM_SELECTED = { 1.00, 0.88, 0.40, 1.00 };
// Where the mesh stopped a turn. Red rather than the target's amber: a stop,
// not a suggestion.
const Color CONTACT_RING = { 0.95, 0.35, 0.30, 0.90 };
// A contact window on the sheet: when a foot or hand is planted.
const Color CONTACT_BAR = { 0.30, 0.72, 0.55, 0.80 };

// How much colour a dot keeps when the body is between it and the eye. The
// overlay has no depth test on purpose — a dot you cannot see is a dot you
// cannot click — so occlusion dims rather than hides, and this is deliberately
// well above zero: it has to read as "behind" without becoming invisible.
// Kept in the same range as the gizmo's FAR_DIM so the two cues match.
const float OCCLUDED_DIM = 0.45;

// ---- view gizmo ----
// Red/green/blue for X/Y/Z, because every other 3D tool the user has open uses
// exactly that and a private convention here would be a lie about which axis is
// which. Desaturated from the primaries so six of them in one corner do not
// outshout the rig overlay, which is the thing being worked on.
const Color AXIS_X       = { 0.91, 0.32, 0.36, 1.0 };
const Color AXIS_Y       = { 0.52, 0.78, 0.24, 1.0 };
const Color AXIS_Z       = { 0.26, 0.55, 0.93, 1.0 };

// The weight brush's circle, and which way it is about to paint. Two colours
// rather than one, because the two directions are destructive in opposite
// senses and the ring is the only thing on screen that says which is armed
// before the button goes down — the falloff underneath only shows the result.
//
// Read against the falloff ramp the mode puts up, which runs blue through green
// to red: both of these sit off that ramp so the circle never reads as a value.
const Color BRUSH_TAKING = { 0.95, 0.55, 0.15, 1.0 };
const Color BRUSH_ADDING = { 0.75, 0.45, 0.95, 1.0 };

// The lasso's outline: which job it is about to do, and which way round. Three
// colours for the brush's reason — the directions are opposite and the stroke is
// the only thing on screen that says which one the press latched — and off the
// falloff ramp and off the brush's own pair, since all of them can be looked at
// over the same weight view and a region that read as a *value* would be worse
// than none. Clearing is shared: taking a pin off and taking a joint out of the
// selection are the same word, and one red outline for "less of whatever this is
// about" is one thing to learn instead of two.
const Color LASSO_PINNING = { 0.35, 0.95, 0.70, 1.0 };
const Color LASSO_SELECTING = { 0.95, 0.85, 0.35, 1.0 };
const Color LASSO_CLEARING = { 0.95, 0.35, 0.45, 1.0 };
const float LASSO_WIDTH = 1.5;
const Color SKETCH_RED = { 0.95, 0.25, 0.22, 1.0 };
const Color SKETCH_GREEN = { 0.30, 0.85, 0.35, 1.0 };
const Color SKETCH_BLUE = { 0.30, 0.60, 1.0, 1.0 };
const float SKETCH_WIDTH = 3.0;

// How far back the segment closing the loop is taken. Drawn at all because a
// lasso is a *region* and an open curve does not look like one; drawn dimmer
// because it is the only part of the outline the hand did not draw.
const float LASSO_CLOSE_DIM = 0.4;

<*
 The colour an axis is spoken about in — by the corner gizmo, by the line a
 locked move is confined to, and by its readout in the HUD. One mapping, so
 "the red line" means the same thing wherever it appears.
*>
fn Color DragAxis.color(self)
{
	switch (self)
	{
		case X: return AXIS_X;
		case Y: return AXIS_Y;
		case Z: return AXIS_Z;
		case XY:
		case YZ:
		case XZ:
		case BONE: return TEXT;
		default: return TEXT;
	}
}

// The size the window opens at, and nothing more: it is resizable, so the tree
// is laid out against `Ui.size` from the first frame on and only these two
// numbers decide what that is at startup. Anything sized against a window has to
// read the live one — `Element.media` for a widget, `Ui.size` for the mesh pass —
// or it will be right until the first drag of an edge.
const float WIN_W = 1280.0;
const float WIN_H = 800.0;

// Height of the top menu bar. The viewport (and the mesh pass behind it) starts
// below it, so this is part of the render-region math, not just styling.
const float BAR_H = 28.0;

// The menu bar and its dropdowns in crig's colors. Passed whole: cui's menu
// widgets treat a zero bar_height as "use the library default wholesale" and do
// not merge styles field by field.
<*
 Hover tooltips (cui's TooltipHost): the panel colours, 12 px text that wraps
 past 380 px, after half a second's rest.
*>
const TooltipStyle TOOLTIP_STYLE = {
	.text = { .size = 12.0, .color = TEXT },
	.box = { .color = PANEL, .border_color = PANEL_BORDER, .border_width = 1.0, .border_radius = { 6.0, 6.0, 6.0, 6.0 } },
	.shadow = { 0, 0, 0, 0.35 },
	.shadow_blur = 8.0,
	.pad = { 8.0, 5.0 },
	.offset = { 14.0, 20.0 },
	.max_width = 380.0,
	.delay = 0.5,
	.still = 3.0,
};

const MenuStyle MENU_STYLE = {
	.bar_color = PANEL,
	.bar_border = PANEL_BORDER,
	.panel_color = PANEL,
	.panel_border = PANEL_BORDER,
	.hover_color = BTN_HOVER,
	.open_color = BTN,
	.text_color = TEXT,
	.dim_color = TEXT_DIM,
	.text_size = 14.0,
	.bar_height = BAR_H,
	.item_height = 26.0,
	.pad_x = 12.0,
};

// Height of the 3D view's own header — the strip inside the pane carrying the
// Rig and View menus and the tint switch. Part of the render-region math along
// with BAR_H and the tab strip: a pane's viewport starts below all three.
const float VIEW_BAR_H = 26.0;

// The 3D view's header, in the window bar's colors one text size down so the
// two read as different levels rather than as one bar broken in half. Passed
// whole for the same reason MENU_STYLE is: a zero bar_height means "use the
// library default wholesale", and styles are not merged field by field.
const MenuStyle VIEW_MENU_STYLE = {
	.bar_color = PANEL,
	.bar_border = PANEL_BORDER,
	.panel_color = PANEL,
	.panel_border = PANEL_BORDER,
	.hover_color = BTN_HOVER,
	.open_color = BTN,
	.text_color = TEXT,
	.dim_color = TEXT_DIM,
	.text_size = 13.0,
	.bar_height = VIEW_BAR_H,
	.item_height = 26.0,
	.pad_x = 12.0,
};

// A menu row that throws something away — Delete animation, Delete layer — in
// the red the destructive buttons use. Same metrics as VIEW_MENU_STYLE so it
// lines up with the rows beside it.
const MenuStyle DANGER_MENU_STYLE = {
	.bar_color = PANEL,
	.bar_border = PANEL_BORDER,
	.panel_color = PANEL,
	.panel_border = PANEL_BORDER,
	.hover_color = BTN_HOVER,
	.open_color = BTN,
	.text_color = DOT_LOCKED,
	.dim_color = TEXT_DIM,
	.text_size = 13.0,
	.bar_height = VIEW_BAR_H,
	.item_height = 26.0,
	.pad_x = 12.0,
};

// The Controls dialog, in the same colors, passed whole for the same reason the
// menu styles are: a zero title_height means "use the library default
// wholesale", and styles are not merged field by field.
//
// The title bar takes the button colour rather than the bar colour: a dialog
// floats over the window bar it would otherwise be indistinguishable from.
const DialogStyle DIALOG_STYLE = {
	.panel_color = PANEL,
	.panel_border = PANEL_BORDER,
	.title_color = BTN,
	.text_color = TEXT,
	.dim_color = TEXT_DIM,
	.hover_color = BTN_HOVER,
	.scrim_color = { 0.0, 0.0, 0.0, 0.45 },
	.text_size = 14.0,
	.title_height = 30.0,
	.pad_x = 16.0,
	.pad_y = 14.0,
	.radius = 8.0,
	.shadow = 18.0,
	.min_width = 260.0,
};

<*
 A button on a dialog's footer row: the ordinary one.

 The colours a `ConfirmDialog` gets from `CONFIRM_BUTTONS`, spelled as a `Button`
 for the dialogs crig builds by hand. Returned as a value to be handed straight
 to `@node`, which copies it — nothing here is borrowed except `label`, which
 must outlive the element the way every widget string must.

 @param label : `The word on it. Borrowed.`
 @param on_click : `What it does. Null makes a button that draws and does nothing.`
*>
fn Button panel_button(String label, OnClick on_click)
{
	return {
		.label = label,
		.label_style = { .size = CONTROLS_TEXT_SIZE, .color = TEXT },
		.style = { .color = BTN, .border_radius = R8 },
		.hover_style = { .color = BTN_HOVER, .border_radius = R8 },
		.press_style = { .color = BTN_PRESS, .border_radius = R8 },
		.on_click = on_click,
	};
}

<*
 The one button on a dialog that commits — Export, Save, Open.

 The accent fill with dark ink on it, which is the pairing every primary button
 in this interface has. It does not light on hover: the accent is already the
 brightest thing on the panel, and a hover state would have to go somewhere
 louder still.

 At most one per dialog. Two accents is two primary actions, which is a dialog
 that has not decided what it is asking.
*>
fn Button accent_button(String label, OnClick on_click)
{
	return {
		.label = label,
		.label_style = { .size = CONTROLS_TEXT_SIZE, .color = DOT_OUTLINE },
		.style = { .color = ACCENT, .border_radius = R8 },
		.hover_style = { .color = ACCENT, .border_radius = R8 },
		.press_style = { .color = BTN_PRESS, .border_radius = R8 },
		.on_click = on_click,
	};
}

<*
 A destructive button on a dialog's footer: the red fill for an action that
 removes something, so it does not read as an ordinary choice. Dark ink on it, the
 accent pairing. There is one such action per panel; two ways to lose data on one
 footer is a panel that has not decided what it asks.
*>
fn Button danger_button(String label, OnClick on_click)
{
	return {
		.label = label,
		.label_style = { .size = CONTROLS_TEXT_SIZE, .color = DOT_OUTLINE },
		.style = { .color = DOT_LOCKED, .border_radius = R8 },
		.hover_style = { .color = DOT_LOCKED, .border_radius = R8 },
		.press_style = { .color = BTN_PRESS, .border_radius = R8 },
		.on_click = on_click,
	};
}

// The two answers on a ConfirmDialog, in the same colours the panel buttons
// elsewhere use. The confirming one takes the accent and dark ink on it, which
// is the pairing every primary button in this interface already has.
const ConfirmButtonStyle CONFIRM_BUTTONS = {
	.fill = BTN,
	.hover = BTN_HOVER,
	.press = BTN_PRESS,
	.accent = ACCENT,
	.text = TEXT,
	.accent_text = DOT_OUTLINE,
	.text_size = CONTROLS_TEXT_SIZE,
	.height = 28.0,
	.pad_x = 14.0,
	.gap = 10.0,
	.radius = 8.0,
};

// The path field and the file listing, in the same colors and passed whole for
// the same reason every style above is.
//
// The focused border is the accent: a field that cannot be told apart from one
// that is merely on screen leaves the user typing into the last thing they
// clicked.
const TextFieldStyle TEXT_FIELD_STYLE = {
	.background = BG,
	.border = PANEL_BORDER,
	.border_focused = ACCENT,
	.text = TEXT,
	.placeholder = TEXT_DIM,
	.caret = TEXT,
	// The accent again, but thin enough to read the text through: the selection
	// is behind the glyphs, and at full strength it takes the field over.
	.selection = { ACCENT.r, ACCENT.g, ACCENT.b, 0.35 },
	.border_width = 1.0,
	.border_radius = { 4, 4, 4, 4 },
	.padding = { 8.0, 6.0 },
	.text_size = 13.0,
	.caret_width = 1.0,
};

<*
 A gear, drawn out of circles.

 Not a glyph: the loaded font is whatever the application supplied, and a cog is
 not a character it can be assumed to have — a missing one draws as a blank box
 on the only affordance saying the cell has settings behind it. Eight teeth
 around a rim with a hole punched through it reads as a gear at sixteen pixels,
 which is the size it is used at.

 @param at : `The gear's centre, in element-local pixels.`
 @param radius : `Half the width it occupies, teeth included.`
 @param ink : `The gear itself.`
 @param hole : `What shows through the middle — the surface behind it, not a shade of the ink.`
*>
fn void paint_gear(Painter* painter, Vec2 at, float radius, Color ink, Color hole)
{
	const usz TEETH = 8;
	for (usz i = 0; i < TEETH; i++)
	{
		float turn = (float)i * (float)math::TAU / (float)TEETH;
		painter.circle(
			{ at.x + math::cos(turn) * radius * 0.72f, at.y + math::sin(turn) * radius * 0.72f },
			radius * 0.28f,
			{ .color = ink });
	}
	painter.circle(at, radius * 0.66f, { .color = ink });
	painter.circle(at, radius * 0.26f, { .color = hole });
}

// A ticked box takes the accent with dark ink on it, which is what every other
// "this is on" surface in the interface does — a ticked cell in the export grid,
// the confirming button, a playing clip.
const CheckboxStyle CHECKBOX_STYLE = {
	.color = BTN,
	.hover_color = BTN_HOVER,
	.checked_color = ACCENT,
	.mark = DOT_OUTLINE,
	.text_color = TEXT,
	.border_radius = { 4, 4, 4, 4 },
	.text_size = 13.0,
	.box = 16.0,
	.gap = 8.0,
	.thickness = 2.0,
};

// Segmented controls and toggle buttons: an unlit segment is a panel button, a
// lit one the accent with dark ink, the same "this is on" as a ticked box.
const SegmentedStyle SEGMENTED_STYLE = {
	.fill = BTN,
	.hover = BTN_HOVER,
	.selected = ACCENT,
	.border = PANEL_BORDER,
	.text = TEXT,
	.selected_text = DOT_OUTLINE,
	.border_radius = R8,
	.text_size = CONTROLS_TEXT_SIZE,
	.pad_x = 12.0,
	.height = 28.0,
};

// Folders take the dot colour rather than a second blue: it is already the
// "this is a thing you can act on" colour everywhere else in the interface.
const FileBrowserStyle FILE_BROWSER_STYLE = {
	.text = TEXT,
	.directory = DOT,
	.size = TEXT_DIM,
	.icon = TEXT_DIM,
	.hover = BTN_HOVER,
	.selected = ACCENT,
	.selected_text = DOT_OUTLINE,
	.stripe = { 1.0, 1.0, 1.0, 0.025 },
	.row_height = 26.0,
	.text_size = 13.0,
	.padding = 10.0,
	.icon_size = 14.0,
	.radius = { 5, 5, 5, 5 },
};

// What the file browser lists. glTF in both its containers, and nothing else:
// every other extension in a models folder is a texture or a source file, and
// crig can open neither.
//
// A module global rather than a local, because a FileBrowser borrows this list
// for the lifetime of its element — the same rule the menu arrays follow.
String[2] mesh_mask = { "*.glb", "*.gltf" };
// Kimodo's weights: the text encoder's .gguf files, and the motion model as a
// .gguf or as NVIDIA's model.safetensors (its folder is what is read).
String[2] motion_file_mask = { "*.gguf", "*.safetensors" };

// The asset browser's category sidebar, in the listing's colours — it is the
// same kind of thing as the file browser beside a path, and a second palette for
// a second list would only say the two are unrelated.
//
// The indent is a little wider than the row is tall, so a body plan sitting under
// its kind reads as under it at a glance rather than only when the two labels are
// compared.
const TreeStyle TREE_STYLE = {
	.text = TEXT,
	.selected = ACCENT,
	.selected_text = DOT_OUTLINE,
	.hover = BTN_HOVER,
	.trailing = TEXT_DIM,
	.mark = TEXT_DIM,
	.row_height = 22.0,
	.text_size = 13.0,
	.padding = 10.0,
	.indent = 14.0,
	.radius = { 4, 4, 4, 4 },
};

// The Scene outliner, after Blender's: a calm blue bar under the selection with
// the active row's name in the accent, a lighter bar for the rest of a group,
// thin guides down each level, and a barely-there shade on every other row so a
// long joint list keeps its lines. Taller and wider-indented than the lists in
// dialogs, because it carries an icon and an eye on every row.
const TreeStyle OUTLINER_STYLE = {
	.text = TEXT,
	.selected = { 0.26, 0.36, 0.58, 1.0 },
	.selected_text = ACCENT,
	.highlighted = { 0.21, 0.27, 0.40, 1.0 },
	.hover = { 0.20, 0.22, 0.28, 1.0 },
	.trailing = TEXT_DIM,
	.mark = TEXT_DIM,
	.guide = { 0.30, 0.32, 0.40, 1.0 },
	.alternate = { 1.0, 1.0, 1.0, 0.025 },
	.row_height = 24.0,
	.text_size = 13.0,
	.padding = 6.0,
	.indent = 18.0,
	.icon_size = 14.0,
	.toggle_width = 24.0,
	.radius = { 3, 3, 3, 3 },
};

// The dopesheet, in the same palette as everything else. The two darks are the
// panel's own recess colours so the sheet reads as inset rather than as a
// picture pasted onto the pane, and the accent carries both the playhead and a
// selected key — the same "this is the one" the rest of the interface uses.
//
// The gutter is wide enough for a joint name a body plan actually produces
// (`shoulder_L`, `mixamorig:LeftHand` elides), and a lane is shorter than a tree
// row: a rig has sixty-five joints and a sheet of them has to fit in a pane.
const TimelineStyle TIMELINE_STYLE = {
	.gutter = BG,
	.lane = PANEL,
	.lane_alt = BTN,
	.ruler = BG,
	.grid = BTN_HOVER,
	.text = TEXT,
	.dim_text = TEXT_DIM,
	.mark = TEXT_DIM,
	.mark_hover = TEXT,
	.mark_selected = ACCENT,
	.hold = BTN_HOVER,
	.playhead = ACCENT,
	.flag = CONTACT_RING,
	.contact = CONTACT_BAR,
	.text_size = 12.0,
	.lane_height = 17.0,
	.ruler_height = 20.0,
	.gutter_width = 118.0,
	.mark_radius = 4.0,
	.playhead_width = 1.5,
	.pad_x = 8.0,
	.indent = 9.0,
};

// The physics panel's sliders, in the same colours as everything else that says
// "this is on": the filled part of the track takes the accent, the way a ticked
// box and a playing clip do.
//
// The caption column is wide enough for "Stiffness" and the readout column for a
// four-figure number, both fixed — a stack of sliders whose tracks started at
// different places would read as a stack of unrelated controls.
const SliderStyle PHYSICS_SLIDER_STYLE = {
	.track = BTN,
	.fill = ACCENT,
	.hover_fill = { 1.0, 0.70, 0.34, 1.0 },
	.handle = TEXT,
	.label_color = TEXT,
	.value_color = TEXT_DIM,
	.dim_color = { 0.36, 0.38, 0.44, 1.0 },
	.text_size = 13.0,
	.height = 22.0,
	.track_height = 6.0,
	.handle_width = 10.0,
	.label_width = 68.0,
	.value_width = 50.0,
	.gap = 8.0,
	.border_radius = { 3, 3, 3, 3 },
};

// The settings panel's one slider, in the physics panel's colours and with two
// columns of its own. The caption column is wide enough for "Interface" and the
// readout column for "1.25×" — narrower than the physics stack's, because there
// is one row here and nothing under it for its track to line up with.
const SliderStyle SETTINGS_SLIDER_STYLE = {
	.track = BTN,
	.fill = ACCENT,
	.hover_fill = { 1.0, 0.70, 0.34, 1.0 },
	.handle = TEXT,
	.label_color = TEXT,
	.value_color = TEXT_DIM,
	.dim_color = { 0.36, 0.38, 0.44, 1.0 },
	.text_size = 13.0,
	.height = 22.0,
	.track_height = 6.0,
	.handle_width = 10.0,
	.label_width = 62.0,
	.value_width = 44.0,
	.gap = 8.0,
	.border_radius = { 3, 3, 3, 3 },
};

// The split-area workspace in the same colors, passed whole like MENU_STYLE.
// `tab_height` joins BAR_H in the render-region math: a pane's viewport starts
// below its tab strip, and the test constants derive from it.
const AreaStyle AREA_STYLE = {
	.strip_color = PANEL,
	.strip_border = PANEL_BORDER,
	.tab_active = BTN,
	.hover_color = BTN_HOVER,
	.text_color = TEXT,
	.dim_color = TEXT_DIM,
	.splitter_color = PANEL_BORDER,
	.text_size = 13.0,
	.tab_height = 24.0,
	.pad_x = 12.0,
	.splitter_px = 5.0,
	.min_pane = 100.0,
};

<*
 Open or close the dialog with this id. A missing one is nothing to do: every
 dialog is built with the tree, so this only misses under a test that built part
 of it.
*>
fn void set_dialog_open(Ui* ui, String id, bool open)
{
	if (try Element* panel = ui.find_id(id))
	{
		panel.widget_as(Dialog).set_open(panel, open);
	}
}

<*
 What the text field with this id holds, trimmed — or empty when there is no such
 field, which reads as "nothing typed" to every caller.
*>
fn String field_text(Ui* ui, String id)
{
	if (try Element* field = ui.find_id(id)) return field.widget_as(TextField).value().trim();
	return "";
}

<*
 Fill a detached dialog's text field and put the caret in it, the whole text
 selected so typing replaces it.
*>
fn void focus_field(Element* body, String id, String text)
{
	Element* field = body.find_id(id)!!;
	TextField* widget = field.widget_as(TextField);
	widget.set_text(field, text);
	widget.select_all(field);
	field.request_focus();
}

// Either key of a modifier pair, held.
fn bool Input.shift_down(&self) => self.key_down(Key.LEFT_SHIFT) || self.key_down(Key.RIGHT_SHIFT);
fn bool Input.ctrl_down(&self) => self.key_down(Key.LEFT_CTRL) || self.key_down(Key.RIGHT_CTRL);
fn bool Input.alt_down(&self) => self.key_down(Key.LEFT_ALT) || self.key_down(Key.RIGHT_ALT);

<*
 The key and gesture reference: the table, and the widget that draws it as the
 body of the Controls dialog (Help > Controls).

 It lives in a dialog rather than along the bottom of the viewport because the
 reference outgrew a line. One window's width fits about fifteen bindings with
 no room to say what any of them does, so the line had to drop a key every time
 a feature added one — the camera's 1/3/7 went when the lasso arrived — and
 what survived was a list of letters. A panel has room for every binding and a
 sentence beside it, and it is out of the way when it is not wanted.

 The table is the only copy of this text. It is not, however, the only copy of
 the bindings themselves: those are `AppRoot.on_key` and the menus, so a key
 added there has to be added here by hand. Nothing checks that, which is the
 price of a reference written for a reader rather than generated from a switch.

 The keys of a *running* tool are also on the hint bar at the bottom of the
 viewport — `hint_line` — which shows a handful of them while they apply. This
 is the list of all of them, at the moment they are wanted.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const float CONTROLS_TEXT_SIZE = 13.0;
const float CONTROLS_ROW_H = 18.0;

// A section heading's row, gap above it included — see `row_height`.
const float CONTROLS_HEADING_H = 26.0;

// Between the binding column and the column saying what it does.
const float CONTROLS_GUTTER = 20.0;

<*
 How wide the scrolling viewport around the sheet is.

 A number rather than the measured width because the scroll has to be sized
 before the sheet inside it lays out and reports one. It must stay clear of both
 the widest row and the scrollbar riding over the right edge of the viewport;
 `help_toggles_the_controls_dialog` fails when a row outgrows it, which is the
 only thing keeping the two in step.
*>
const float CONTROLS_SHEET_W = 700.0;

<*
 One line of the reference: a binding and what it does, or — when `heading` is
 set — the title of the group the lines under it belong to, in which case the
 other two fields are ignored.
*>
struct ControlRow
{
	String heading;
	String binding;
	String action;
}

<*
 Everything crig answers to, grouped the way the interface is: what the pointer
 does in a 3D view, what the keys do to the rig, and what they do to the picture
 of it.

 Both halves of a mouse-versus-trackpad split are listed. They are genuinely
 different gestures — a wheel notch zooms where a two-finger swipe orbits — and
 which one a machine sends is the backend's report about the device, so a user
 on one of them cannot discover the other by trying it.
*>
const ControlRow[*] CONTROLS = {
	{ .heading = "Pointer" },
	{ .binding = "click", .action = "place a joint inside the model" },
	{ .binding = "click a joint", .action = "select it — on Joints, drag it to move it" },
	{ .binding = "shift-click a joint", .action = "add or remove it — dragging one moves the group" },
	{ .binding = "drag", .action = "orbit the view" },
	{ .binding = "shift-drag / middle-drag", .action = "pan" },
	{ .binding = "wheel", .action = "zoom" },
	{ .binding = "ctrl+wheel", .action = "the same, a quarter of a step at a time" },
	{ .binding = "trackpad swipe", .action = "orbit — ctrl to zoom, shift to pan" },

	{ .heading = "While a joint is being moved" },
	{ .binding = "X / Y / Z", .action = "confine the move to that axis" },
	{ .binding = "esc", .action = "put the joint back where it was" },

	{ .heading = "While the Area tool is open" },
	{ .binding = "click the mesh", .action = "pick the selected joint's own part — again for the next size up" },
	{ .binding = "click, on UV islands", .action = "add the island clicked to the part, or take it out" },
	{ .binding = "wheel", .action = "step the part: own bone, with children, UV islands, whole piece" },
	{ .binding = "shift-drag", .action = "grow the part from where you press, a tenth of the bone per step" },
	{ .binding = "ctrl-drag", .action = "shrink it" },
	{ .binding = "enter", .action = "apply: the joint moves exactly that part" },
	{ .binding = "esc", .action = "drop the part, then close the tool" },

	{ .heading = "While the weight brush is open" },
	{ .binding = "drag the mesh", .action = "paint — Add or Remove, as the strip at the top says" },
	{ .binding = "drag off the mesh", .action = "orbit, as always" },
	{ .binding = "ctrl-drag", .action = "put the joint on, whatever the strip says" },
	{ .binding = "ctrl+shift-drag", .action = "take it off" },
	{ .binding = "Size slider / hold F", .action = "size the brush — with F, right grows, left shrinks" },
	{ .binding = "hold F, then scroll", .action = "the same, by notches" },
	{ .binding = "swipe / wheel", .action = "orbit and zoom, as always" },
	{ .binding = "shift-drag", .action = "pan, as always — the brush leaves it alone" },
	{ .binding = "shift+W / esc", .action = "close it; strokes are already on the ledger" },

	{ .heading = "Rig" },
	{ .binding = "C", .action = "bond the selected joints into a chain, in the order picked — again to unbond" },
	// One tool with two jobs, and two rows for it: the plain letter walks along
	// them, the shifted one names the far one. The modifiers are on the hint bar
	// for as long as it is open, which is the only time they mean anything — see
	// `hint_line`.
	{ .binding = "T", .action = "lasso: draw around joints to select them — again to switch it to pinning" },
	{ .binding = "shift+T", .action = "the same lasso, straight to pinning vertices to the selected joint" },
	// The tool column shows the one tool that has an icon; everything else in this
	// section is a key or a menu item, which is why the column is small.
	{ .binding = "tool column", .action = "top-left of the view: select, move, rotate, lasso, area and weight brush" },
	{ .binding = "Move tool, drag a joint", .action = "move its rest position — no alt needed" },
	// No key of its own — a pane rather than a mode — and the only route to a
	// whole piece at once, so it is also the only way to see which pieces a model
	// has at all.
	{ .binding = "W", .action = "area: pick exactly which part of the mesh the selected joint moves" },
	{ .binding = "shift+W", .action = "weight brush: correct the bind by hand — on the rest mesh or a parked pose" },
	{ .binding = "] / [", .action = "sharpen or soften every blend at once — keys instead while posing a clip" },
	// No keys of their own: both are ops over the whole mesh whose result is
	// written down rather than derived, so they are listed by where they live.
	{ .binding = "Rig menu", .action = "Make rigid: give a nearly-rigid vertex wholly to the joint that holds it" },
	{ .binding = "Rig menu", .action = "Smooth weights: widen the seams where two joints meet" },
	{ .binding = "A", .action = "auto-connect: chain each new joint to the last" },
	{ .binding = "M", .action = "symmetrize: line the other side up with the selection — never adds joints" },
	{ .binding = "Rig menu", .action = "rotate the whole skeleton when a body plan faces the wrong way" },
	{ .binding = "ctrl+R", .action = "make the selected joint the root — refused while editing animation" },
	{ .binding = "Joint card", .action = "Rename: name the selected joint — what clips, plans and the .glb address it by" },
	{ .binding = "Rig menu", .action = "auto-name joints: name what a body plan has a joint for" },
	{ .binding = "ctrl+A", .action = "select every joint" },
	{ .binding = "X / del", .action = "delete every selected joint — one undo takes them all back" },
	{ .binding = "Joint panel", .action = "Align X/Y/Z: line joints up with the first-selected one" },
	{ .binding = "Joint panel", .action = "Centre on mesh: drop a lone joint to the middle" },
	{ .binding = "right-click a joint", .action = "move, rotate, select children or whole skeleton, mirror, delete" },
	{ .binding = "right-click a Scene row", .action = "move or rotate that Skeleton, Model or joint · Move by…" },
	{ .binding = "esc", .action = "clear the selection" },

	{ .heading = "Display" },
	{ .binding = "B", .action = "show or hide the mesh" },
	{ .binding = "S", .action = "show or hide the skeleton" },
	{ .binding = "Z", .action = "wireframe" },
	{ .binding = "Rig menu", .action = "weight preview: colour each vertex by its joint" },
	{ .binding = "F", .action = "weight falloff of the selected joint" },
	{ .binding = "N", .action = "show or hide the joint panel" },
	{ .binding = "View menu", .action = "joint names, and where the plan wants the selected joint" },
	// The one group here that is about the program rather than the model, and it
	// is in Display because that is where a person looks for "everything is too
	// small". File > Settings has the same setting on a slider.
	{ .binding = "ctrl+= / ctrl+-", .action = "draw the whole interface bigger or smaller" },
	{ .binding = "ctrl+0", .action = "back to the size the display asks for" },

	{ .heading = "Posing" },
	{ .binding = "Joints | Pose", .action = "top of the 3D view: whether a drag moves or poses" },
	{ .binding = "drag a joint", .action = "on Pose: pose it through IK, the same as G" },
	{ .binding = "G", .action = "pose the selected joint — sweep the pointer, click to confirm" },
	{ .binding = "R", .action = "turn the selected joint — sweep the pointer around it, click to confirm" },
	{ .binding = "Joint card dials", .action = "turn the selected joint about one bone-local axis, off the model" },
	{ .binding = "X / Y / Z", .action = "lock a move to one axis, or turn about that axis" },
	{ .binding = "esc", .action = "put the pose back where the gesture found it" },
	{ .binding = "L", .action = "anchor the selected joints' position, so other moves bend around them" },
	{ .binding = "shift+L", .action = "anchor their rotation instead" },
	{ .binding = "Anim panel", .action = "Rest pose: show the rest shape, without changing the clip" },
	// The pose clipboard, as against the timeline's key clipboard: the same
	// chords, told apart by where the pointer's focus is. See pose_clipboard.c3.
	{ .binding = "ctrl+C", .action = "copy the pose of the selected joints — all of them when none is selected" },
	{ .binding = "ctrl+V", .action = "paste that pose at the playhead, as keys — one undo takes it back" },
	{ .binding = "ctrl+shift+V", .action = "paste it mirrored: each joint onto its twin, reflected" },
	{ .binding = "shift+M", .action = "mirror the pose of the selected joints — all of them when none is selected" },
	{ .binding = "Poses", .action = "save named poses; apply one whole, mirrored or to selected joints" },
	// The key clipboard lives on the sheet itself: the menu on a key copies it,
	// the menu on empty sheet pastes at that time. The chords do the same while
	// the sheet has the focus.
	{ .binding = "right-click a key", .action = "copy or delete it, or the selected keys, and set their interpolation or ease" },
	{ .binding = "Keys / Curves", .action = "Curves plots the selected joints' rotation or position over time" },
	{ .binding = "drag a curve key", .action = "up/down sets that value, sideways moves the key; a handle sets its ease" },
	{ .binding = "in Curves", .action = "ctrl+wheel zooms time, shift+wheel zooms values, middle-drag pans, F fits" },
	{ .binding = "right-click the sheet", .action = "paste or key at that time; snap, fit and preview settings" },
	{ .binding = "+ Contact", .action = "plant the selected foot or hand from the playhead, as a bar" },
	{ .binding = "a contact bar", .action = "drag it or its ends; drag an empty lane to add; right-click deletes" },
	{ .binding = "the time readout", .action = "type a frame (15) or a time (0.5 s) and press Enter to go there" },
	{ .binding = "the ⋯ by the clip", .action = "rename, duplicate, stretch, trim, mirror, remove or delete the clip" },

	{ .heading = "Timeline (while an animation is open)" },
	{ .binding = "space", .action = "play or pause" },
	{ .binding = ", / .", .action = "step one frame back or forward" },
	{ .binding = "[ / ]", .action = "jump to the previous or next key" },
	{ .binding = "home / end", .action = "go to the first or last frame" },

	{ .heading = "Camera" },
	{ .binding = "1 / 3 / 7", .action = "front / right / top" },
	{ .binding = "ctrl+1 / 3 / 7", .action = "back / left / bottom" },

	{ .heading = "Assets" },
	{ .binding = "the + on a clip", .action = "adds it to the character — the Animations pane plays it" },
	{ .binding = "click a skin", .action = "fit that file's joints to the model" },
	{ .binding = "the search box", .action = "narrows as you type, by name or by file" },
	{ .binding = "a category", .action = "narrows to a kind, or to one body plan of it" },
	{ .binding = "File > Settings", .action = "which folders the browser reads" },

	{ .heading = "Document" },
	{ .binding = "ctrl+N", .action = "a new, empty scene" },
	{ .binding = "ctrl+O", .action = "open a scene" },
	{ .binding = "ctrl+I", .action = "import a .glb into the scene as a character" },
	{ .binding = "ctrl+E", .action = "export as .glb — the clips you tick, or the whole scene" },
	{ .binding = "ctrl+Z", .action = "undo" },
	{ .binding = "ctrl+Y", .action = "redo" },
	{ .binding = "ctrl+S", .action = "save each character into its model, and the scene file" },
	{ .binding = "ctrl+shift+S", .action = "save the scene under another name" },
};

<*
 How much vertical room the row at this index takes.

 Shared by layout and paint so the two cannot disagree about where a row sits —
 the height of a heading is not a property of the row, since the gap belongs
 above it and the first heading has nothing above it to be separated from.

 @param index : `Index into CONTROLS.`
 @return `The row's height in pixels, including any gap above a heading.`
*>
fn float row_height(usz index) @private
{
	if (CONTROLS[index].heading.len == 0) return CONTROLS_ROW_H;
	return index == 0 ? CONTROLS_ROW_H : CONTROLS_HEADING_H;
}

<*
 The height the whole reference wants, headings and their gaps included.

 Summed from the table rather than written down, so a binding added to
 `CONTROLS` makes the sheet taller instead of pushing a row off the bottom of
 it. No text is measured — every row's height is a constant — so this can be
 asked before any layout has run, which is what the enclosing scroll needs to
 size its viewport.

 @return `The natural height of the sheet in pixels.`
*>
fn float controls_height()
{
	float total = 0;
	for (usz i = 0; i < CONTROLS.len; i++) total += row_height(i);
	return total;
}

<*
 The reference drawn as two columns: the binding, then what it does.

 A widget painting rows rather than a Column of Labels, the same trade the HUD
 makes and for a sharper reason here — the two columns have to line up, which
 means one measured width shared by thirty rows. A Label per cell would give
 each row its own idea of where the second column starts unless something
 measured them all anyway.
*>
struct ControlsSheet (Widget)
{
	float column; // where the second column starts; measured by the last layout

	// What both columns together need, measured by the last layout. Kept because
	// the size the element ends up with is clamped to the viewport around it, and
	// so cannot say whether a row was cut off — this can.
	float natural_width;
}

// Decoration inside a panel that already swallows its own clicks; making it
// transparent keeps the sheet out of hover and cursor resolution entirely, and
// lets a wheel over the text land on the enclosing Scroll instead of stopping
// on the thirty rows covering it.
fn void ControlsSheet.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

<*
 Measures both columns across every row and sizes the sheet to hold them.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @return `The measured size of the whole table, clamped.`
*>
fn Vec2 ControlsSheet.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	float bindings = 0;
	float actions = 0;
	foreach (row : CONTROLS)
	{
		if (row.heading.len > 0) continue;
		bindings = math::max(bindings, elem.ui.text.measure(0, row.binding, CONTROLS_TEXT_SIZE).x);
		actions = math::max(actions, elem.ui.text.measure(0, row.action, CONTROLS_TEXT_SIZE).x);
	}

	self.column = bindings + CONTROLS_GUTTER;
	self.natural_width = self.column + actions;
	return constraints.constrain({ self.natural_width, controls_height() });
}

fn void ControlsSheet.paint(&self, Element* elem, Painter* painter) @dynamic
{
	float y = 0;
	foreach (index, row : CONTROLS)
	{
		float h = row_height((usz)index);
		if (row.heading.len > 0)
		{
			// Bottom-aligned in its taller row: the gap a heading gets is the space
			// above it, separating it from the group that ended there.
			painter.text({ 0, y + h - CONTROLS_ROW_H }, row.heading, {
				.size = CONTROLS_TEXT_SIZE, .color = ACCENT,
			});
			y += h;
			continue;
		}

		painter.text({ 0, y }, row.binding, { .size = CONTROLS_TEXT_SIZE, .color = TEXT });
		painter.text({ self.column, y }, row.action, { .size = CONTROLS_TEXT_SIZE, .color = TEXT_DIM });
		y += h;
	}
}

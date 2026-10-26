<*
 The channel list beside the Curves plot: a row for each selected joint, under
 it its Rotation and Position, under each its X, Y and Z, every one with an eye.

 The rows are cui's `Tree` (chevrons, icons, right-edge toggles); this file says
 what the rows are and what a click does. The eye shows or hides what the row
 names. Clicking the name solos it (draws only that, a joint or channel row
 soloing the whole group under it); Shift adds it to what is drawn, Ctrl toggles
 it. "All curves" brings everything back. What is hidden is the character's
 (`app/graph.c3`), so it outlasts a change of selection.
*>
module crig;

import cui;
import cui::widgets;
import std::math::vector;

const String ANIM_CURVE_LIST_ID = "anim-curve-list";
const String ANIM_CURVE_SCROLL_ID = "anim-curve-scroll";
const float ANIM_CURVE_LIST_W = 170.0;
const float ANIM_CURVE_LIST_GAP = 6.0;

// The list's icons, by the number a TreeRow carries: an axis chip (+ the axis) and the eye.
const ushort CURVE_ICON_CHIP = 1;
const ushort CURVE_ICON_EYE = 4;

// What a row names, and the fold it opens and shuts (-1 for none).
struct CurveListRow
{
	GraphPick pick;
	int fold;
}

struct CurveChannelList (Widget)
{
	GraphChannel[] channels; // owned
	TreeRow[] rows; // labels borrow `channels` and literals
	CurveListRow[] items;
}

// A copy the list can keep: the graph it came from is rebuilt under it.
fn GraphChannel[] graph_channels_copy(GraphChannel[] channels)
{
	GraphChannel[] copy = alloc::new_array(mem, GraphChannel, (sz)channels.len);
	foreach (usz i, channel : channels)
	{
		copy[i] = channel;
		copy[i].joint = channel.joint.copy(mem);
	}
	return copy;
}

fn void CurveChannelList.clear_rows(&self)
{
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	if (self.items.len > 0) alloc::free(mem, self.items);
	self.rows = {};
	self.items = {};
}

fn void CurveChannelList.unmount(&self, Element* elem) @dynamic
{
	self.clear_rows();
	foreach (channel : self.channels) channel.joint.free(mem);
	if (self.channels.len > 0) alloc::free(mem, self.channels);
	self.channels = {};
}

// A row's eye: lit while any curve it names is drawn.
fn TreeToggle curve_list_eye(AppState* app, GraphChannel[] channels, GraphPick pick) @private
{
	return { .icon = CURVE_ICON_EYE, .on = app.graph_pick_drawn(channels, pick, false), .shown = true };
}

fn Element* CurveChannelList.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.clear_rows();
	usz capacity = 1 + self.channels.len * 5;
	TreeRow[] rows = alloc::new_array(mem, TreeRow, (sz)capacity);
	CurveListRow[] items = alloc::new_array(mem, CurveListRow, (sz)capacity);
	usz count;

	GraphPick all = { .kind = -1, .axis = -1 };
	rows[count] = { .label = "All curves" };
	rows[count].toggles[0] = curve_list_eye(app, self.channels, all);
	items[count++] = { .pick = all, .fold = -1 };

	String[3] axes = { "X", "Y", "Z" };
	for (usz c = 0; c < self.channels.len; c++)
	{
		GraphChannel first = self.channels[c];
		usz end = c;
		while (end + 1 < self.channels.len && self.channels[end + 1].id == first.id) end++;

		GraphPick joint = { .joint = first.id, .kind = -1, .axis = -1 };
		bool open = !app.graph_folded(first.id, 0);
		rows[count] = { .label = first.joint, .expandable = true, .expanded = open };
		rows[count].toggles[0] = curve_list_eye(app, self.channels, joint);
		items[count++] = { .pick = joint, .fold = 0 };
		if (!open) { c = end; continue; }

		for (usz k = c; k <= end; k++)
		{
			GraphChannel channel = self.channels[k];
			int part = channel.rotation ? 1 : 2;
			GraphPick pick = { .joint = channel.id, .kind = channel.rotation ? 0 : 1, .axis = -1 };
			bool shown = !app.graph_folded(channel.id, part);
			rows[count] = { .label = channel.rotation ? "Rotation" : "Position", .depth = 1,
				.expandable = true, .expanded = shown };
			rows[count].toggles[0] = curve_list_eye(app, self.channels, pick);
			items[count++] = { .pick = pick, .fold = part };
			if (!shown) continue;
			for (int axis = 0; axis < 3; axis++)
			{
				GraphPick leaf = { .joint = channel.id, .kind = pick.kind, .axis = axis };
				rows[count] = { .label = axes[axis], .depth = 2, .icon = CURVE_ICON_CHIP + (ushort)axis };
				rows[count].toggles[0] = curve_list_eye(app, self.channels, leaf);
				items[count++] = { .pick = leaf, .fold = -1 };
			}
		}
		c = end;
	}
	self.rows = rows[:count];
	self.items = items[:count];

	return @subtree(elem.ui)
	{
		@node((Tree) {
			.rows = self.rows,
			.selected = ~(usz)0,
			.on_select = &curve_list_chosen,
			.on_toggle = &curve_list_folded,
			.on_row_toggle = &curve_list_eye_clicked,
			.paint_icon = &paint_curve_list_icon,
			.style = OUTLINER_STYLE,
		});
	};
}

fn Vec2 CurveChannelList.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, 0 });
	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return constraints.constrain({ constraints.max.x, inner.y });
}

<*
 The axis chips in the plot's own colours, and the outliner's eye.
*>
fn void paint_curve_list_icon(Painter* painter, Vec2 at, float size, ushort icon, bool dim)
{
	if (icon == CURVE_ICON_EYE)
	{
		paint_outliner_icon(painter, at, size, OUTLINER_ICON_EYE, dim);
		return;
	}
	if (icon < CURVE_ICON_CHIP || icon >= CURVE_ICON_CHIP + 3) return;
	float side = size * 0.7f;
	painter.rect({ at.x - side * 0.5f, at.y - side * 0.5f }, { side, side },
		{ .color = GRAPH_AXIS_COLORS[icon - CURVE_ICON_CHIP], .border_radius = { 2, 2, 2, 2 } });
}

fn CurveChannelList* curve_channel_list(Ui* ui) @private
{
	Element*? found = ui.find_id(ANIM_CURVE_LIST_ID);
	if (catch found) return null;
	Element* list = found;
	return list.widget_as(CurveChannelList);
}

<*
 The list changed what is drawn: the pane's curves are rebuilt, and the vertical
 view fits what is left.
*>
fn void anim_curves_redraw(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.anim_graph_y_zoom = 0;
	app.anim_graph_y_shift = 0;
	Element*? plot = ui.find_id(ANIM_CURVES_ID);
	if (try plot)
	{
		CurvePlot* widget = plot.widget_as(CurvePlot);
		widget.y_zoom = 0;
		widget.y_shift = 0;
	}
	Element*? slot = ui.find_id(ANIM_SHEET_SLOT_ID);
	if (try slot) slot.request_build();
}

<*
 A click on a row's name: solo it, or with Shift add it, with Ctrl toggle it.
 "All curves" shows everything.
*>
fn void curve_list_chosen(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CurveChannelList* list = curve_channel_list(ui);
	if (!list || row >= list.items.len) return;
	GraphPick pick = list.items[row].pick;
	if (pick.joint == 0)
	{
		app.show_all_graph_curves();
	}
	else
	{
		GraphPickMode mode = ui.input.ctrl_down() ? TOGGLE : ui.input.shift_down() ? ADD : SOLO;
		app.pick_graph_curves(list.channels, pick, mode);
	}
	anim_curves_redraw(ui);
}

// The eye: show or hide what the row names, leaving the rest as it is.
fn void curve_list_eye_clicked(Ui* ui, usz row, usz column) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CurveChannelList* list = curve_channel_list(ui);
	if (!list || row >= list.items.len) return;
	app.pick_graph_curves(list.channels, list.items[row].pick, TOGGLE);
	anim_curves_redraw(ui);
}

// A chevron: fold the joint or channel row.
fn void curve_list_folded(Ui* ui, usz row) @private
{
	AppState* app = ui.inherit(AppState)!!;
	CurveChannelList* list = curve_channel_list(ui);
	if (!list || row >= list.items.len || list.items[row].fold < 0) return;
	app.toggle_graph_fold(list.items[row].pick.joint, list.items[row].fold);
	Element*? slot = ui.find_id(ANIM_SHEET_SLOT_ID);
	if (try slot) slot.request_build();
}

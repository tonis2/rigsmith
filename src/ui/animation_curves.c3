<*
 The sheet's Curves mode: the selected joints' rotation (Euler degrees) or
 position (model units) over time on cui's `CurvePlot`, sharing the key sheet's
 horizontal zoom. A key is dragged up and down to change that component, sideways
 to move it in time; a selected key's handles set its segment's ease. Each drag
 is one undo step. The data is `app/graph.c3`'s; this file is the wiring.

 Also here: the Keys | Curves switch and `anim_apply_ease`, which the interpolation popover
 (animation_interp.c3) and the handles share.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::math::vector;

const String ANIM_SHEET_MODE_ID = "anim-sheet-mode";
const String ANIM_GRAPH_CHANNEL_ID = "anim-graph-channel";
const String ANIM_CURVES_ID = "anim-curves";
const float ANIM_CURVES_H = 240.0;

String[2] anim_sheet_mode_options = { "Keys", "Curves" };
String[2] anim_graph_channel_options = { "Rotation", "Position" };

fn void anim_sheet_mode_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	bool curves = index == 1;
	if (app.anim_show_curves == curves) return;
	app.anim_show_curves = curves;
	// The two views select different things; a hidden selection must not be
	// what the next delete acts on.
	app.clear_animation_key_selection();
	refresh_animations_view(ui);
}

fn void anim_graph_channel_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	app.anim_graph_position = index == 1;
	app.anim_graph_y_zoom = 0;
	app.anim_graph_y_shift = 0;
	refresh_animations_view(ui);
}

// ---------------------------------------------------------------------------
// Ease

<*
 Pace the selected keys' outgoing segments. With nothing selected, the key under
 the playhead is the one meant — as for Smooth / Linear / Step.
*>
fn void anim_apply_ease(Ui* ui, AnimEase ease)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	bool none = app.animation_key_selection_count(app.editing) == 0
		&& app.animation_channel_key_selection_count(app.editing) == 0;
	if (none)
	{
		sz key = app.key_near(app.editing, anim_live_time(app), ANIM_SAME_TIME);
		if (key < 0)
		{
			app.@notice("Select keys first; easing applies to the segment after each selected key.");
			return;
		}
		app.select_animation_key(app.editing, app.clip(app.editing).keyframes[key].time);
	}
	if (!app.set_selected_animation_ease(app.editing, ease)) return;
	app.@notice("%s", ease.none() ? "Keys now move at an even pace to the next key."
		: ease.start > 0 && ease.end > 0 ? "Keys now start slow and arrive slow."
		: ease.start > 0 ? "Keys now start slow and speed up." : "Keys now slow down into the next key.");
	app.show_edited();
}

// ---------------------------------------------------------------------------
// The curve view

const Color[3] GRAPH_AXIS_COLORS = { AXIS_X, AXIS_Y, AXIS_Z };

const CurvePlotStyle ANIM_CURVE_STYLE = {
	.background = PANEL,
	.gutter = BG,
	.ruler = BG,
	.grid = BTN,
	.zero = BTN_HOVER,
	.text = TEXT_DIM,
	.point_border = DOT_OUTLINE,
	.selected = ACCENT,
	.hover = TEXT,
	.handle = TEXT,
	.cursor = ACCENT,
	.text_size = 11.0,
	.ruler_height = 20.0,
	.gutter_width = 52.0,
	.point_radius = 4.0,
	.handle_radius = 3.5,
	.pad = 8.0,
	.height = ANIM_CURVES_H,
};

struct AnimCurves (Widget)
{
	Graph graph;
	CurveSeries[] series;
	CurvePoint[] points;
	CurveHandle[] handles;
	uint shown_selection; // the key selection the arrays were built for
}

// A cheap fingerprint of the key selection, so a click on a key restyles the
// points and shows its handles without rebuilding the pane.
fn uint anim_key_selection_hash(AppState* app) @private
{
	uint hash = 2166136261u;
	hash = (hash ^ (uint)app.anim_key_selection_ref.pack) * 16777619u;
	hash = (hash ^ (uint)app.anim_key_selection_ref.clip) * 16777619u;
	foreach (time : app.anim_key_selection) hash = (hash ^ bitcast(time, uint)) * 16777619u;
	foreach (key : app.anim_channel_key_selection)
	{
		hash = (hash ^ bitcast(key.time, uint) ^ (uint)key.channel) * 16777619u;
		foreach (c : key.joint) hash = (hash ^ c) * 16777619u;
	}
	return hash;
}

fn void AnimCurves.release(&self)
{
	self.graph.free();
	if (self.series.len > 0) alloc::free(mem, self.series);
	if (self.points.len > 0) alloc::free(mem, self.points);
	if (self.handles.len > 0) alloc::free(mem, self.handles);
	self.series = {};
	self.points = {};
	self.handles = {};
}

fn void AnimCurves.unmount(&self, Element* elem) @dynamic => self.release();

fn void AnimCurves.rebuild(&self, AppState* app)
{
	self.release();
	self.shown_selection = anim_key_selection_hash(app);
	self.graph = app.build_graph(app.editing, app.anim_graph_position);
	if (self.graph.curves.len == 0) return;
	self.series = alloc::new_array(mem, CurveSeries, self.graph.curves.len);
	foreach (usz i, curve : self.graph.curves)
	{
		Color color = GRAPH_AXIS_COLORS[curve.axis];
		if (!curve.primary) color.a = 0.45f;
		self.series[i] = { .points = curve.samples, .color = color, .width = curve.primary ? 1.5f : 1.0f };
	}
	self.points = alloc::new_array(mem, CurvePoint, self.graph.keys.len);
	foreach (usz i, key : self.graph.keys)
	{
		self.points[i] = { .at = { key.time, key.value }, .color = self.series[key.curve].color,
			.selected = key.selected };
	}
	if (self.graph.handles.len > 0)
	{
		self.handles = alloc::new_array(mem, CurveHandle, self.graph.handles.len);
		foreach (usz i, handle : self.graph.handles) self.handles[i] = { .point = handle.key, .at = handle.at };
	}
}

fn void AnimCurves.hand_to_plot(&self, Element* elem)
{
	if (elem.children.len() == 0) return;
	CurvePlot* plot = elem.children[0].widget_as(CurvePlot);
	plot.series = self.series;
	plot.points = self.points;
	plot.handles = self.handles;
	elem.children[0].request_paint();
}

fn Element* AnimCurves.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.rebuild(app);
	AnimTemplate* clip = app.clip(app.editing);
	float duration = clip ? clip.duration : 0.0f;
	float zoom = math::max(app.anim_timeline_zoom, 1.0f);
	return @subtree(elem.ui)
	{
		@node((CurvePlot) {
			.series = self.series,
			.points = self.points,
			.handles = self.handles,
			.x_min = 0,
			.x_max = duration,
			.zoom = zoom,
			.view_start = math::clamp(app.anim_timeline_start, 0.0f, duration - duration / zoom),
			.cursor = anim_live_time(app),
			.show_cursor = true,
			.snap_x = app.anim_snap_off ? 0 : 1.0f / (float)app.anim_fps,
			.x_label_scale = (float)app.anim_fps,
			.y_suffix = app.anim_graph_position ? "" : "°",
			.empty_text = app.selection_count() == 0
				? "Select a joint in the viewport to see its curves."
				: app.anim_graph_position ? "The selected joints have no position keys in this animation."
				: "The selected joints have no rotation keys in this animation.",
			.y_zoom = app.anim_graph_y_zoom,
			.y_shift = app.anim_graph_y_shift,
			.on_point = &anim_curve_point_pressed,
			.on_point_drag = &anim_curve_point_dragged,
			.on_handle_drag = &anim_curve_handle_dragged,
			.on_scrub = &anim_seek,
			.on_view = &anim_timeline_view_changed,
			.on_context = &anim_curve_context,
			.on_delete = &anim_delete_selection,
			.style = ANIM_CURVE_STYLE,
		}).with_id(ANIM_CURVES_ID);
	};
}

fn void AnimCurves.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.children.len() == 0) return;
	AppState* app = elem.inherit(AppState)!!;
	CurvePlot* plot = elem.children[0].widget_as(CurvePlot);
	app.anim_graph_y_zoom = plot.y_zoom;
	app.anim_graph_y_shift = plot.y_shift;
	if (plot.held_handle == 0 && anim_key_selection_hash(app) != self.shown_selection)
	{
		self.rebuild(app);
		self.hand_to_plot(elem);
	}
	float at = anim_live_time(app);
	if (plot.cursor == at) return;
	plot.cursor = at;
	elem.children[0].request_paint();
}

fn Vec2 AnimCurves.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ constraints.max.x, ANIM_CURVES_H });
	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return inner;
}

// The graph the curve view on screen was built from, or null.
fn AnimCurves* anim_curves(Ui* ui) @private
{
	Element*? found = ui.find_id(ANIM_CURVES_ID);
	if (catch found) return null;
	Element* plot = found;
	if (!plot.parent || !plot.parent.is_widget(AnimCurves)) return null;
	return plot.parent.widget_as(AnimCurves);
}

fn void anim_curve_point_pressed(Ui* ui, usz index, bool toggle) @private
{
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.keys.len) return;
	GraphKey key = curves.graph.keys[index];
	GraphCurve curve = curves.graph.curves[key.curve];
	anim_mark_pressed(ui, { .at = key.time, .joint = curve.joint.tcopy(),
		.channel = curve.rotation ? ROTATION : TRANSLATION }, toggle);
}

<*
 A key dragged on the curves: sideways moves the selected keys in time (the
 sheet's move), up or down sets this key's component. Nothing is written until
 the release, so the drag is one undo step.
*>
fn void anim_curve_point_dragged(Ui* ui, usz index, Vec2 to, bool done) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.keys.len) return;
	GraphKey key = curves.graph.keys[index];
	GraphCurve curve = curves.graph.curves[key.curve];
	curve.joint = curve.joint.tcopy();
	float unit = curves.graph.unit;
	bool timed = math::abs(to.x - key.time) >= ANIM_SAME_TIME;
	if (!done)
	{
		if (timed && anim_allow_navigation(ui, 1, to.x))
		{
			app.prepare_timeline_navigation();
			app.edit_time = to.x;
			anim_seek(ui, to.x);
		}
		return;
	}
	if (!anim_can_rewrite(ui)) return;
	if (timed)
	{
		if (app.move_selected_animation_keys(app.editing, to.x - key.time))
		{
			app.edit_time = to.x;
			app.show_edited();
		}
		else
		{
			app.@notice("Selected keys cannot move there without leaving the clip or overlapping another key.");
			anim_seek(ui, key.time);
		}
		return;
	}
	if (math::abs(to.y - key.value) < 1.0e-6f) return;
	if (!app.set_graph_key_value(app.editing, curve.joint, curve.rotation, key.time, key.shown,
		curve.axis, to.y, unit)) return;
	char[3] names = { 'X', 'Y', 'Z' };
	app.@notice(curve.rotation ? "%s rotation %c now %.1f° at %.2fs" : "%s position %c now %.3f at %.2fs",
		curve.joint, names[curve.axis], to.y, key.time);
	app.show_edited();
}

<*
 A handle dragged: its pull toward the key sets that end's ease, from 0 on the
 segment's own tangent to 1 flat. One ease serves the channel, so every axis of
 the rotation (or position) follows.
*>
fn void anim_curve_handle_dragged(Ui* ui, usz index, Vec2 to, bool done) @private
{
	if (!done) return;
	AppState* app = ui.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.handles.len) return;
	if (!anim_can_rewrite(ui)) return;
	GraphHandle handle = curves.graph.handles[index];
	GraphKey key = curves.graph.keys[handle.key];
	GraphCurve curve = curves.graph.curves[key.curve];
	curve.joint = curve.joint.tcopy();
	float ease = handle.ease_for(key.value, to.y);
	if (!app.set_graph_ease(app.editing, curve.joint, curve.rotation, handle.owner, handle.start, ease)) return;
	app.@notice("%s %s %s eases %s by %.0f%%", curve.joint, curve.rotation ? "rotation" : "position",
		handle.start ? "leaving this key" : "arriving here", handle.start ? "in" : "out", ease * 100.0f);
	app.show_edited();
}

fn void anim_curve_context(Ui* ui, sz point, float x, Vec2 pixel) @private
{
	AnimCurves* curves = anim_curves(ui);
	if (point >= 0 && curves && (usz)point < curves.graph.keys.len)
	{
		GraphKey key = curves.graph.keys[(usz)point];
		GraphCurve curve = curves.graph.curves[key.curve];
		anim_key_context(ui, { .at = key.time, .joint = curve.joint.tcopy(),
			.channel = curve.rotation ? ROTATION : TRANSLATION }, pixel);
		return;
	}
	anim_space_context(ui, x, pixel);
}

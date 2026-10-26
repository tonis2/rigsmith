<*
 The sheet's Curves mode: the selected joints' rotation (Euler degrees) and
 position (model units) over time on cui's `CurvePlot`, sharing the key sheet's
 horizontal zoom, with the channel list (animation_curve_list.c3) beside it that
 shows, hides and solos curves. A key is dragged up and down to change that
 component, sideways to move it in time, and the selected keys go with it; a box
 picks keys (animation_curve_edit.c3); a selected key's two tangent handles set the
 slope the curve leaves and arrives with. Each drag is one undo step. The data is `app/graph.c3`'s; this file is the
 wiring.

 Rotation and position have different units, so while both are drawn the plot
 holds each curve normalised to -1..1 (`GraphCurve.shown`), its y axis reads the
 real units of the hovered curve (else the primary joint's), and a drag's
 position is converted back (`GraphCurve.real`) before it is written. F frames
 the selected keys (all curves when none), A frames every drawn curve.

 Also here: the Keys | Curves switch and `anim_apply_ease`, which the interpolation popover
 (animation_interp.c3) uses, and `anim_apply_tangent_mode`, which it and the key menu share.
*>
module crig;

import cui;
import cui::widgets;
import std::math;
import std::math::vector;

const String ANIM_SHEET_MODE_ID = "anim-sheet-mode";
const String ANIM_CURVES_ID = "anim-curves";
const float ANIM_CURVES_H = 240.0;

String[3] anim_sheet_mode_options = { "Keys", "Curves", "Layers" };

fn void anim_sheet_mode_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	bool curves = index == 1;
	bool layers = index == 2;
	if (app.anim_show_curves == curves && app.anim_show_layers == layers) return;
	app.anim_show_curves = curves;
	app.anim_show_layers = layers;
	// A move held for the banner's answer belongs to the view that held it.
	if (!app.pose_edit_pending)
	{
		app.anim_pending_action = 0;
		app.anim_pending_armed = false;
	}
	// The two views select different things; a hidden selection must not be
	// what the next delete acts on.
	app.clear_animation_key_selection();
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

<*
 Give the selected keys a tangent mode. With nothing selected, the key under the
 playhead is the one meant, as for Smooth / Linear / Step.
*>
fn void anim_apply_tangent_mode(Ui* ui, AnimTangent mode)
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
			app.@notice("Select keys first; tangent modes apply to the selected keys.");
			return;
		}
		app.select_animation_key(app.editing, app.clip(app.editing).keyframes[key].time);
	}
	if (!app.set_selected_tangent_mode(app.editing, mode)) return;
	app.@notice("%s", anim_tangent_notice(mode));
	app.show_edited();
}

fn String anim_tangent_notice(AnimTangent mode)
{
	switch (mode)
	{
		case FLAT: return "Keys now level out: flat tangents.";
		case LINEAR: return "Keys now head straight for their neighbours.";
		case FREE: return "Keys now have tangent handles that turn together.";
		case BROKEN: return "Keys now have tangent handles that move apart.";
		default: return "Keys now follow their neighbours: automatic tangents.";
	}
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
	Vec2[] shown; // the series' samples as the plot draws them, end to end
	uint shown_selection; // the key selection the arrays were built for
	bool break_tangent; // Alt was down at the last move of the handle drag in progress
}

// What the plot's y axis reads: `plot y * scale + offset`, with a suffix.
struct CurveLabels
{
	float scale;
	float offset;
	String suffix;
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
	if (self.shown.len > 0) alloc::free(mem, self.shown);
	self.shown = {};
	self.series = {};
	self.points = {};
	self.handles = {};
}

fn void AnimCurves.unmount(&self, Element* elem) @dynamic => self.release();

fn void AnimCurves.rebuild(&self, AppState* app)
{
	self.release();
	self.shown_selection = anim_key_selection_hash(app);
	self.graph = app.build_graph(app.editing);
	if (self.graph.curves.len == 0) return;
	usz total;
	foreach (curve : self.graph.curves) total += curve.samples.len;
	self.shown = alloc::new_array(mem, Vec2, (sz)total);
	self.series = alloc::new_array(mem, CurveSeries, self.graph.curves.len);
	usz used;
	foreach (usz i, curve : self.graph.curves)
	{
		Vec2[] line = self.shown[used:curve.samples.len];
		foreach (usz j, p : curve.samples) line[j] = { p.x, curve.shown(p.y) };
		used += line.len;
		Color color = GRAPH_AXIS_COLORS[curve.axis];
		if (!curve.primary) color.a = 0.45f;
		self.series[i] = { .points = line, .color = color, .width = curve.primary ? 1.5f : 1.0f };
	}
	self.points = alloc::new_array(mem, CurvePoint, self.graph.keys.len);
	foreach (usz i, key : self.graph.keys)
	{
		GraphCurve drawn = self.graph.curves[key.curve];
		// A drag carries the selected points of its own group: one axis of one channel.
		self.points[i] = { .at = { key.time, drawn.shown(key.value) },
			.color = self.series[key.curve].color, .selected = key.selected,
			.group = drawn.axis + (drawn.rotation ? 0 : 3) };
	}
	if (self.graph.handles.len > 0)
	{
		self.handles = alloc::new_array(mem, CurveHandle, self.graph.handles.len);
		foreach (usz i, handle : self.graph.handles)
		{
			GraphCurve curve = self.graph.curves[self.graph.keys[handle.key].curve];
			self.handles[i] = { .point = handle.key, .at = { handle.at.x, curve.shown(handle.at.y) } };
		}
	}
}

<*
 The units the y axis reads: the hovered key's curve (`lit`, one-based, 0 for
 none), else the primary joint's first drawn one. Only a mixed graph has a scale
 to undo; alone, a curve is drawn in its own units already.
*>
fn CurveLabels AnimCurves.labels(&self, int lit)
{
	if (self.graph.curves.len == 0) return { .scale = 1.0f };
	usz which;
	if (lit > 0 && (usz)lit <= self.graph.keys.len)
	{
		which = self.graph.keys[(usz)lit - 1].curve;
	}
	else
	{
		foreach (usz i, curve : self.graph.curves) if (curve.primary) { which = i; break; }
	}
	GraphCurve curve = self.graph.curves[which];
	return { .scale = curve.half > 0.0f ? curve.half : 1.0f, .offset = curve.mid,
		.suffix = curve.rotation ? "°" : "" };
}

// The plot element, or null before the pane is built.
fn Element* AnimCurves.plot_element(&self, Element* elem)
{
	Element*? found = elem.find_id(ANIM_CURVES_ID);
	if (catch found) return null;
	return found;
}

fn void AnimCurves.hand_to_plot(&self, Element* elem)
{
	Element* plot_elem = self.plot_element(elem);
	if (!plot_elem) return;
	CurvePlot* plot = plot_elem.widget_as(CurvePlot);
	plot.series = self.series;
	plot.points = self.points;
	plot.handles = self.handles;
	plot_elem.request_paint();
}

// What the plot says when it has no series.
fn String anim_curves_empty_text(AppState* app, Graph* graph) @private
{
	if (app.selection_count() == 0) return "Select a joint in the viewport to see its curves.";
	if (graph.channels.len > 0) return "Every curve is hidden. Use the eye in the list to show some.";
	return "The selected joints have no keys in this animation.";
}

fn Element* AnimCurves.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.rebuild(app);
	// Rotation and position share the plot in different scales: a switch between
	// the two spaces leaves the old vertical view meaningless.
	if (self.graph.mixed != app.anim_graph_mixed)
	{
		app.anim_graph_mixed = self.graph.mixed;
		app.anim_graph_y_zoom = 0;
		app.anim_graph_y_shift = 0;
	}
	AnimTemplate* clip = app.clip(app.editing);
	float duration = clip ? clip.duration : 0.0f;
	float zoom = math::max(app.anim_timeline_zoom, 1.0f);
	CurveLabels labels = self.labels(0);
	return @subtree(elem.ui)
	{
		@tree((Row) { .gap = ANIM_CURVE_LIST_GAP })
		{
			if (self.graph.channels.len > 0)
			{
				Element* column = @tree((Scroll) { .size = { ANIM_CURVE_LIST_W, ANIM_CURVES_H },
					.scroll_offset = app.anim_graph_list_scroll })
				{
					@node((CurveChannelList) { .channels = graph_channels_copy(self.graph.channels) })
						.with_id(ANIM_CURVE_LIST_ID);
				};
				column.with_id(ANIM_CURVE_SCROLL_ID);
			}
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
				.y_suffix = labels.suffix,
				.y_label_scale = labels.scale,
				.y_label_offset = labels.offset,
				.empty_text = anim_curves_empty_text(app, &self.graph),
				.y_zoom = app.anim_graph_y_zoom,
				.y_shift = app.anim_graph_y_shift,
				.on_point = &anim_curve_point_pressed,
				.on_point_drag = &anim_curve_point_dragged,
				.on_box = &anim_curve_boxed,
				.on_scale = &anim_curve_scaled,
				.on_copy = &anim_curve_copy,
				.on_paste = &anim_paste_key_clicked,
				.on_handle_drag = &anim_curve_handle_dragged,
				.on_scrub = &anim_seek,
				.on_view = &anim_timeline_view_changed,
				.on_context = &anim_curve_context,
				.on_delete = &anim_delete_selection,
				.on_frame = &anim_curve_frame,
				.style = ANIM_CURVE_STYLE,
			}).with_id(ANIM_CURVES_ID);
		};
	};
}

fn void AnimCurves.update(&self, Element* elem, float dt) @dynamic
{
	Element* plot_elem = self.plot_element(elem);
	if (!plot_elem) return;
	AppState* app = elem.inherit(AppState)!!;
	CurvePlot* plot = plot_elem.widget_as(CurvePlot);
	app.anim_graph_y_zoom = plot.y_zoom;
	app.anim_graph_y_shift = plot.y_shift;
	Element*? column = elem.find_id(ANIM_CURVE_SCROLL_ID);
	if (try column) app.anim_graph_list_scroll = column.widget_as(Scroll).scroll_offset;
	if (plot.held_handle == 0 && anim_key_selection_hash(app) != self.shown_selection)
	{
		self.rebuild(app);
		self.hand_to_plot(elem);
	}
	// The axis follows the curve under the pointer.
	CurveLabels labels = self.labels(plot.lit);
	if (plot.y_label_scale != labels.scale || plot.y_label_offset != labels.offset || plot.y_suffix != labels.suffix)
	{
		plot.y_label_scale = labels.scale;
		plot.y_label_offset = labels.offset;
		plot.y_suffix = labels.suffix;
		plot_elem.request_paint();
	}
	float at = anim_live_time(app);
	if (plot.cursor == at) return;
	plot.cursor = at;
	plot_elem.request_paint();
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
	Element* row = plot.parent;
	if (!row || !row.parent || !row.parent.is_widget(AnimCurves)) return null;
	return row.parent.widget_as(AnimCurves);
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
 sheet's move), up or down moves this axis of every selected key by the same
 amount (`anim_curve_value_dragged`). Nothing is written until the release, so
 the drag is one undo step. `to.y` is in the plot's space, which is the curve's
 own units unless the graph is mixed.
*>
fn void anim_curve_point_dragged(Ui* ui, usz index, Vec2 to, bool done) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.keys.len) return;
	GraphKey key = curves.graph.keys[index];
	GraphCurve curve = curves.graph.curves[key.curve];
	curve.joint = curve.joint.tcopy();
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
	anim_curve_value_dragged(ui, index, curve.real(to.y));
}

<*
 A tangent handle dragged: the line from its key to the pointer is the slope the
 curve leaves (or arrives at) the key with. Only that slope counts: the handle
 stays a third of its segment from the key, so a drag along time changes nothing
 but the slope's steepness, and the pointer crossing the key is held off at a
 quarter of the handle's length. Nothing is written until the release; the plot
 draws the handle under the pointer meanwhile, and the release is one undo step.

 A key that was not Free becomes Free, its other handle following; with Alt held
 it becomes Broken and the other handle stays. A Free key dragged with Alt is
 broken the same way. Alt is read as the drag goes, so letting it go before the
 mouse does not undo it.
*>
fn void anim_curve_handle_dragged(Ui* ui, usz index, Vec2 to, bool done) @private
{
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.handles.len) return;
	if (!done)
	{
		curves.break_tangent = ui.input.key_down(Key.LEFT_ALT) || ui.input.key_down(Key.RIGHT_ALT);
		return;
	}
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	GraphHandle handle = curves.graph.handles[index];
	GraphKey key = curves.graph.keys[handle.key];
	GraphCurve curve = curves.graph.curves[key.curve];
	curve.joint = curve.joint.tcopy();
	float run = handle.incoming ? key.time - to.x : to.x - key.time;
	run = math::max(run, handle.length * 0.25f);
	float rise = curve.real(to.y) - key.value;
	float slope = (handle.incoming ? -rise : rise) / run;
	bool broken = curves.break_tangent;
	curves.break_tangent = false;
	if (!app.set_graph_tangent(app.editing, curve.joint, curve.rotation, key.time, key.shown, curve.axis,
		handle.incoming, slope, curves.graph.unit, broken)) return;
	app.@notice("%s %s tangent %s this key: %.2f %s per second%s", curve.joint, curve.rotation ? "rotation" : "position",
		handle.incoming ? "arriving at" : "leaving", slope, curve.rotation ? "degrees" : "units",
		broken ? ", handles apart" : "");
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

<*
 F frames the selected keys (every drawn curve when none is selected), A frames
 every drawn curve: both in time and in the plot's values.
*>
fn void anim_curve_frame(Ui* ui, bool all) @private
{
	Element*? found = ui.find_id(ANIM_CURVES_ID);
	if (catch found) return;
	Element* plot_elem = found;
	CurvePlot* plot = plot_elem.widget_as(CurvePlot);
	Vec2 x = { 1.0e30f, -1.0e30f };
	Vec2 y = { 1.0e30f, -1.0e30f };
	bool picked;
	if (!all)
	{
		foreach (p : plot.points)
		{
			if (!p.selected) continue;
			picked = true;
			x = { math::min(x.x, p.at.x), math::max(x.y, p.at.x) };
			y = { math::min(y.x, p.at.y), math::max(y.y, p.at.y) };
		}
	}
	if (!picked)
	{
		foreach (line : plot.series) foreach (p : line.points)
		{
			x = { math::min(x.x, p.x), math::max(x.y, p.x) };
			y = { math::min(y.x, p.y), math::max(y.y, p.y) };
		}
		// Every curve spans the clip, and the whole of it is what the time view shows.
		x = { plot.x_min, plot.x_max };
	}
	if (x.x > x.y) return;
	plot.frame(plot_elem, x, y);
	AppState* app = ui.inherit(AppState)!!;
	app.anim_graph_y_zoom = plot.y_zoom;
	app.anim_graph_y_shift = plot.y_shift;
}

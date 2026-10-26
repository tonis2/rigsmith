<*
 Editing several keys at once on the Curves sheet: a box to pick them, a value
 drag or Alt scale that carries the whole selection, copy and paste, and a small
 field to type an exact frame or value.

 The plot (cui's `CurvePlot`) only reports gestures; `app/graph_multi.c3` does
 the edits, each one undo step. The selection is the sheet's channel keys, so a
 point stands for its key: see that file for which axis an edit means.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String ANIM_CURVE_KEY_FIELD_ID = "anim-curve-key-field";
const String ANIM_CURVE_FRAME_ID = "anim-curve-frame";
const String[3] ANIM_CURVE_VALUE_IDS = { "anim-curve-value-x", "anim-curve-value-y", "anim-curve-value-z" };

// ---------------------------------------------------------------------------
// Gestures on the plot

<*
 A key dragged up or down: every selected key's value on that axis moves by the
 same amount, as one undo step. A key that is not in the selection moves alone.
 `to` is in the curve's real units; the caller converts from the plot's.
*>
fn void anim_curve_value_dragged(Ui* ui, usz index, float to) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.keys.len) return;
	GraphKey key = curves.graph.keys[index];
	GraphCurve curve = curves.graph.curves[key.curve];
	curve.joint = curve.joint.tcopy();
	if (math::abs(to - key.value) < 1.0e-6f) return;
	char[3] names = { 'X', 'Y', 'Z' };
	if (!key.selected)
	{
		if (!app.set_graph_key_value(app.editing, curve.joint, curve.rotation, key.time, key.shown,
			curve.axis, to, curves.graph.unit)) return;
		app.@notice(curve.rotation ? "%s rotation %c now %.1f° at %.2fs" : "%s position %c now %.3f at %.2fs",
			curve.joint, names[curve.axis], to, key.time);
		app.show_edited();
		return;
	}
	if (!app.set_graph_keys_offset(app.editing, &curves.graph, curve.rotation, curve.axis, to - key.value)) return;
	app.@notice(curve.rotation ? "%c rotation moved by %.1f° on the selected keys"
		: "%c position moved by %.3f on the selected keys", names[curve.axis], to - key.value);
	app.show_edited();
}

<*
 Alt + drag: the selection's values scaled about their middle, or its times
 about the playhead. Only the release writes.
*>
fn void anim_curve_scaled(Ui* ui, usz index, CurveLock axis, float factor, float pivot, bool done) @private
{
	if (!done) return;
	AppState* app = ui.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(ui);
	if (!curves || index >= curves.graph.keys.len || math::abs(factor - 1.0f) < 1.0e-4f) return;
	if (!anim_can_rewrite(ui)) return;
	if (axis == X)
	{
		if (app.scale_graph_key_times(app.editing, factor, pivot))
		{
			app.show_edited();
		}
		else
		{
			app.@notice("Selected keys cannot scale there without leaving the clip or overlapping another key.");
		}
		return;
	}
	// The plot's pivot is in its own space, which is normalised per curve while
	// both channels are drawn; the middle of the selection in real units is the
	// same point for one curve and the right one for several.
	GraphCurve curve = curves.graph.curves[curves.graph.keys[index].curve];
	float low = 1.0e30f;
	float high = -1.0e30f;
	foreach (key : curves.graph.keys)
	{
		GraphCurve other = curves.graph.curves[key.curve];
		if (!key.selected || other.rotation != curve.rotation || other.axis != curve.axis) continue;
		low = math::min(low, key.value);
		high = math::max(high, key.value);
	}
	if (low > high) return;
	if (app.scale_graph_keys(app.editing, &curves.graph, curve.rotation, curve.axis, factor, (low + high) * 0.5f))
	{
		app.show_edited();
	}
}

<*
 A box released over points: pick their keys. Plain replaces the selection,
 Shift adds, Ctrl toggles; an empty box with no modifier clears it.
*>
fn void anim_curve_boxed(Ui* ui, usz[] indices, CurveBox mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(ui);
	if (!curves) return;
	if (mode == REPLACE) app.clear_animation_key_selection();
	foreach (usz n, index : indices)
	{
		if (index >= curves.graph.keys.len) continue;
		GraphKey key = curves.graph.keys[index];
		GraphCurve curve = curves.graph.curves[key.curve];
		// A key's three points are one pick: one toggle, however many are in the box.
		bool again = false;
		foreach (earlier : indices[:n])
		{
			if (earlier >= curves.graph.keys.len) continue;
			GraphKey other = curves.graph.keys[earlier];
			if (other.time == key.time && curves.graph.curves[other.curve].joint == curve.joint
				&& curves.graph.curves[other.curve].rotation == curve.rotation) { again = true; break; }
		}
		if (again) continue;
		app.select_animation_channel_key(app.editing, key.time, curve.joint,
			curve.rotation ? ROTATION : TRANSLATION, additive: true, toggle: mode == TOGGLE);
		app.anim_key_anchor = key.time;
	}
}

fn void anim_curve_copy(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.copy_selected_animation_keys(app.editing);
}

// ---------------------------------------------------------------------------
// The exact field

<*
 Frame and X / Y / Z fields for the selected curve keys. A value field shows the
 value the selected keys share on that axis and is blank when they differ;
 Return gives every selected key that value. The frame field names the first
 selected key and Return moves the selection so it starts there, keeping the
 spacing. Each Return is one undo step.
*>
struct AnimCurveKeyField (Widget)
{
	bool synced;
	uint shown; // fingerprint of what the fields were last filled from
}

fn Element* AnimCurveKeyField.build(&self, Element* elem) @dynamic
{
	self.synced = false;
	return @subtree(elem.ui)
	{
		@tree((Row) { .gap = ANIM_GAP, .cross_align = CENTER })
		{
			@tree(widgets::tip("Frame of the first selected key. Enter moves the selected keys to start there."))
			{
				@node((TextField) { .width = 52, .style = TEXT_FIELD_STYLE, .placeholder = "frame",
					.on_submit = &anim_curve_frame_submitted }).with_id(ANIM_CURVE_FRAME_ID);
			};
			@tree(widgets::tip("X value of the selected keys, blank when they differ. Enter sets them all."))
			{
				@node((TextField) { .width = 60, .style = TEXT_FIELD_STYLE, .placeholder = "X",
					.on_submit = &anim_curve_x_submitted }).with_id(ANIM_CURVE_VALUE_IDS[0]);
			};
			@tree(widgets::tip("Y value of the selected keys, blank when they differ. Enter sets them all."))
			{
				@node((TextField) { .width = 60, .style = TEXT_FIELD_STYLE, .placeholder = "Y",
					.on_submit = &anim_curve_y_submitted }).with_id(ANIM_CURVE_VALUE_IDS[1]);
			};
			@tree(widgets::tip("Z value of the selected keys, blank when they differ. Enter sets them all."))
			{
				@node((TextField) { .width = 60, .style = TEXT_FIELD_STYLE, .placeholder = "Z",
					.on_submit = &anim_curve_z_submitted }).with_id(ANIM_CURVE_VALUE_IDS[2]);
			};
		};
	};
}

fn Vec2 AnimCurveKeyField.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return constraints.constrain({ 0, 0 });
	Vec2 inner = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return inner;
}

fn void AnimCurveKeyField.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.children.len() == 0) return;
	AppState* app = elem.inherit(AppState)!!;
	AnimCurves* curves = anim_curves(elem.ui);
	float first;
	float last;
	bool selected = app.selected_key_span(app.editing, &first, &last);
	String[4] texts;
	uint hash = selected ? bitcast(first, uint) : 0;
	for (int axis = 0; axis < 3; axis++)
	{
		float value;
		bool mixed;
		bool rotation = !curves || curves.graph.selected_rotation();
		usz count = curves ? curves.graph.selected_values(rotation, axis, &value, &mixed) : 0;
		if (count > 0 && !mixed) texts[axis + 1] = string::tformat(rotation ? "%.1f" : "%.3f", value);
		hash = (hash ^ (uint)count ^ (mixed ? 7u : 0u) ^ (count > 0 && !mixed ? bitcast(value, uint) : 0)) * 16777619u;
	}
	if (selected) texts[0] = string::tformat("%d", (int)math::round(first * (float)app.anim_fps));
	if (self.synced && hash == self.shown) return;
	self.synced = true;
	self.shown = hash;
	String[4] ids = { ANIM_CURVE_FRAME_ID, ANIM_CURVE_VALUE_IDS[0], ANIM_CURVE_VALUE_IDS[1], ANIM_CURVE_VALUE_IDS[2] };
	foreach (i, id : ids)
	{
		if (try Element* field = elem.find_id(id)) field.widget_as(TextField).set_text(field, texts[i]);
	}
}

fn void anim_curve_frame_submitted(Ui* ui, String text) @private
{
	AppState* app = ui.inherit(AppState)!!;
	float? frame = text.trim().to_float();
	if (catch frame) return;
	if (!anim_can_rewrite(ui)) return;
	float at = math::round(frame) / (float)app.anim_fps;
	if (!app.set_selected_key_time(app.editing, at))
	{
		app.@notice("Select curve keys first, and keep them inside the clip and off other keys.");
		return;
	}
	app.show_edited();
}

fn void anim_curve_value_submitted(Ui* ui, String text, int axis) @private
{
	AppState* app = ui.inherit(AppState)!!;
	float? value = text.trim().to_float();
	if (catch value) return;
	AnimCurves* curves = anim_curves(ui);
	if (!curves || !anim_can_rewrite(ui)) return;
	if (!app.set_graph_keys_exact(app.editing, &curves.graph, curves.graph.selected_rotation(), axis, value))
	{
		app.@notice("Select curve keys first.");
		return;
	}
	app.show_edited();
}

fn void anim_curve_x_submitted(Ui* ui, String text) @private => anim_curve_value_submitted(ui, text, 0);
fn void anim_curve_y_submitted(Ui* ui, String text) @private => anim_curve_value_submitted(ui, text, 1);
fn void anim_curve_z_submitted(Ui* ui, String text) @private => anim_curve_value_submitted(ui, text, 2);

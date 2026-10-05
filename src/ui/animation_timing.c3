// The transport's timing controls: the frame/time readout you can type into,
// frame rate and preview speed, and the sheet's view settings.
module crig;
import cui;
import cui::widgets;
import std::math;
import std::core::string;

// Select borrows its option slice after the pane's build function returns.
String[3] timing_rate_options = { "24 fps", "30 fps", "60 fps" };
String[5] timing_speed_options = { "0.25x", "0.5x", "1x", "1.5x", "2x" };
const int[3] TIMING_RATES = { 24, 30, 60 };
const float[5] TIMING_SPEEDS = { 0.25f, 0.5f, 1, 1.5f, 2 };

faultdef ANIM_TIME_UNREADABLE;

fn void anim_timeline_view_changed(Ui* ui, float zoom, float start)
{
	AppState* app = ui.inherit(AppState)!!;
	app.anim_timeline_zoom = zoom;
	app.anim_timeline_start = start;
	// Keep other animation panes in sync without replacing the active gesture.
	ui.@each(Timeline; sheet)
	{
		Timeline* timeline = sheet.widget_as(Timeline);
		timeline.zoom = zoom;
		timeline.view_start = start;
		sheet.request_paint();
	};
	ui.@each(CurvePlot; graph)
	{
		CurvePlot* plot = graph.widget_as(CurvePlot);
		plot.zoom = zoom;
		plot.view_start = start;
		graph.request_paint();
	};
}

fn usz anim_rate_row(AppState* app) => app.anim_fps == 24 ? 0 : app.anim_fps == 60 ? 2 : 1;

fn usz anim_speed_row(AppState* app)
{
	foreach (usz i, speed : TIMING_SPEEDS) if (app.anim_preview_speed == speed) return i;
	return 2;
}

fn void anim_rate_chosen(Ui* ui, usz row)
{
	if (row >= TIMING_RATES.len) return;
	ui.inherit(AppState)!!.anim_fps = TIMING_RATES[row];
	refresh_animations_view(ui);
}

fn void anim_speed_chosen(Ui* ui, usz row)
{
	if (row >= TIMING_SPEEDS.len) return;
	ui.inherit(AppState)!!.anim_preview_speed = TIMING_SPEEDS[row];
}

fn void anim_snap_toggled(Ui* ui, bool checked)
{
	ui.inherit(AppState)!!.anim_snap_off = !checked;
	refresh_animations_view(ui);
}

fn void anim_preview_loop_chosen(Ui* ui, usz row)
{
	if (row > 2) return;
	ui.inherit(AppState)!!.anim_preview_loop = (AnimPreviewLoop)row;
	refresh_animations_view(ui);
}

fn void anim_zoom_set(Ui* ui, float zoom)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	zoom = math::clamp(zoom, 1.0f, 32.0f);
	float width = clip.duration / zoom;
	float start = math::clamp(anim_live_time(app) - width * 0.5f, 0.0f, clip.duration - width);
	anim_timeline_view_changed(ui, zoom, start);
}

fn void anim_zoom_in(Ui* ui) => anim_zoom_set(ui, math::max(ui.inherit(AppState)!!.anim_timeline_zoom, 1.0f) * 2);
fn void anim_zoom_out(Ui* ui) => anim_zoom_set(ui, math::max(ui.inherit(AppState)!!.anim_timeline_zoom, 1.0f) / 2);
fn void anim_zoom_fit(Ui* ui) => anim_zoom_set(ui, 1);

<*
 What the readout shows: the frame at the pane's rate and the time in seconds.
*>
fn String anim_time_text(AppState* app, char[] buffer)
{
	float at = anim_live_time(app);
	return string::bformat(buffer, "f %d · %.2f s", (int)math::round(at * (float)app.anim_fps), at);
}

<*
 Read what was typed into the readout as seconds: "15" and "f 15" are frames,
 "0.5s" and "0.5 s" are seconds, and the readout's own "f 15 · 0.50 s" is its
 frame. Frames may be fractional, which is how a key between frames is reached.
*>
fn float? anim_parse_time(String typed, int fps)
{
	String text = typed.trim();
	if (try sz dot = text.index_of("·")) text = text[:dot].trim();
	bool seconds = false;
	if (text.len > 0 && (text[^1] == 's' || text[^1] == 'S'))
	{
		seconds = true;
		text = text[:^1].trim();
	}
	else if (text.len > 0 && (text[0] == 'f' || text[0] == 'F'))
	{
		text = text[1..].trim();
	}
	else if (text.len > 0 && (text[^1] == 'f' || text[^1] == 'F'))
	{
		text = text[:^1].trim();
	}
	float value = text.to_float()!;
	if (!math::is_finite(value)) return ANIM_TIME_UNREADABLE~;
	return seconds ? value : value / (float)fps;
}

fn void anim_time_submitted(Ui* ui, String typed)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	ui.focused = null;
	float? at = anim_parse_time(typed, app.anim_fps);
	if (catch at)
	{
		app.@notice("Type a frame (15) or a time in seconds (0.5 s).");
		return;
	}
	if (!clip || !(at >= 0 && at <= clip.duration + ANIM_SAME_TIME))
	{
		app.@notice("Choose a time within the animation.");
		return;
	}
	anim_seek(ui, math::min(at, clip.duration));
}

<*
 The transport's clock, and where "go to" is typed.

 A field that follows the playhead while it is not being typed in; Return seeks
 to what was typed. Owned text rather than a LiveLabel so the one control both
 reads and writes the time.
*>
struct AnimTimeField (Widget)
{
	char[40] shown;
	usz shown_len;
}

fn Element* AnimTimeField.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	String text = anim_time_text(app, self.shown[..]);
	self.shown_len = text.len;
	Element* body = @subtree(elem.ui)
	{
		@node((TextField) { .width = 124, .style = TEXT_FIELD_STYLE, .on_submit = &anim_time_submitted });
	};
	body.widget_as(TextField).set_text(body, text);
	return body;
}

fn void AnimTimeField.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.children.len() == 0) return;
	Element* field = elem.children[0];
	if (elem.ui.focused == field) return;
	AppState* app = elem.inherit(AppState)!!;
	char[40] buffer;
	String text = anim_time_text(app, buffer[..]);
	if (text == (String)self.shown[:self.shown_len]) return;
	self.shown[:text.len] = text[..];
	self.shown_len = text.len;
	field.widget_as(TextField).set_text(field, text);
}

fn Vec2 AnimTimeField.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

const String ANIM_KEY_TIME_ID = "anim-key-time";
const String ANIM_KEY_SPAN_ID = "anim-key-span";

// The selected keys' first time and span, as the two fields print them. Empty
// with nothing selected, and the span only for keys at two or more times.
fn void anim_key_field_texts(AppState* app, char[] time_buffer, char[] span_buffer, String* time, String* span)
{
	*time = "";
	*span = "";
	float first;
	float last;
	if (!app.selected_key_span(app.editing, &first, &last)) return;
	*time = string::bformat(time_buffer, "%.2f s", first);
	if (last - first >= ANIM_SAME_TIME) *span = string::bformat(span_buffer, "%.2f s", last - first);
}

fn void anim_key_time_submitted(Ui* ui, String typed)
{
	AppState* app = ui.inherit(AppState)!!;
	ui.focused = null;
	if (!anim_can_rewrite(ui)) return;
	float first;
	float last;
	if (!app.selected_key_span(app.editing, &first, &last))
	{
		app.@notice("Select keys first; the time moves the selected keys.");
		return;
	}
	float? at = anim_parse_time(typed, app.anim_fps);
	if (catch at)
	{
		app.@notice("Type a frame (15) or a time in seconds (0.5 s).");
		return;
	}
	if (math::abs(at - first) < ANIM_SAME_TIME) return;
	if (!app.set_selected_key_time(app.editing, at))
	{
		app.@notice("The selected keys cannot move there without leaving the clip or landing on another key.");
		return;
	}
	app.@notice("Moved the selected keys to %.2f s.", at);
	app.show_edited();
}

fn void anim_key_span_submitted(Ui* ui, String typed)
{
	AppState* app = ui.inherit(AppState)!!;
	ui.focused = null;
	if (!anim_can_rewrite(ui)) return;
	float first;
	float last;
	if (!app.selected_key_span(app.editing, &first, &last) || last - first < ANIM_SAME_TIME)
	{
		app.@notice("Select keys at two or more times; the span stretches them from the first.");
		return;
	}
	float? span = anim_parse_time(typed, app.anim_fps);
	if (catch span)
	{
		app.@notice("Type a span in frames (12) or seconds (0.4 s).");
		return;
	}
	if (math::abs(span - (last - first)) < ANIM_SAME_TIME) return;
	if (!app.scale_selected_animation_keys(app.editing, span))
	{
		app.@notice("The selected keys cannot stretch to that without leaving the clip or landing on another key.");
		return;
	}
	app.@notice("The selected keys now span %.2f s from %.2f s.", span, first);
	app.show_edited();
}

<*
 The selected keys' time and span. Typing a time moves the selection, keeping
 its spacing; typing a span stretches only the selected keys from the first.
 Both follow the selection while not being typed in.
*>
struct AnimKeyFields (Widget)
{
	char[24] time_shown;
	usz time_len;
	char[24] span_shown;
	usz span_len;
}

fn Element* AnimKeyFields.build(&self, Element* elem) @dynamic
{
	self.time_len = 0;
	self.span_len = 0;
	Element* body = @subtree(elem.ui)
	{
		@tree((Row) { .gap = 6, .cross_align = CENTER })
		{
			@node((Label) { .text = "Key", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((TextField) { .width = 72, .style = TEXT_FIELD_STYLE, .placeholder = "–",
				.on_submit = &anim_key_time_submitted }).with_id(ANIM_KEY_TIME_ID);
			@node((Label) { .text = "Span", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((TextField) { .width = 72, .style = TEXT_FIELD_STYLE, .placeholder = "–",
				.on_submit = &anim_key_span_submitted }).with_id(ANIM_KEY_SPAN_ID);
		};
	};
	self.sync(body, true);
	return body;
}

fn void AnimKeyFields.sync(&self, Element* body, bool force)
{
	AppState* app = body.inherit(AppState)!!;
	char[24] time_buffer;
	char[24] span_buffer;
	String time;
	String span;
	anim_key_field_texts(app, time_buffer[..], span_buffer[..], &time, &span);
	Element* time_field = body.find_id(ANIM_KEY_TIME_ID)!!;
	Element* span_field = body.find_id(ANIM_KEY_SPAN_ID)!!;
	if (body.ui.focused != time_field && (force || time != (String)self.time_shown[:self.time_len]))
	{
		self.time_shown[:time.len] = time[..];
		self.time_len = time.len;
		time_field.widget_as(TextField).set_text(time_field, time);
	}
	if (body.ui.focused != span_field && (force || span != (String)self.span_shown[:self.span_len]))
	{
		self.span_shown[:span.len] = span[..];
		self.span_len = span.len;
		span_field.widget_as(TextField).set_text(span_field, span);
	}
}

fn void AnimKeyFields.update(&self, Element* elem, float dt) @dynamic
{
	if (elem.children.len() == 0) return;
	self.sync(elem.children[0], false);
}

fn Vec2 AnimKeyFields.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return own;
}

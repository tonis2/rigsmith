// Trim a clip: keep a range of it, or take a range out of it.
//
// The Stretch dialog's sibling, and the explicitly destructive one. Stretch
// changes every saved time and keeps every key; this drops keys. Both edits go
// through `land_clip`, so each is one undo entry, and the playhead follows the
// second it was on: rebased for a crop, moved up for a cut.
module crig;

import cui;
import cui::widgets;
import std::math;

const String ANIM_TRIM_DIALOG_ID = "anim-trim-dialog";
const String ANIM_TRIM_START_ID = "anim-trim-start";
const String ANIM_TRIM_END_ID = "anim-trim-end";
const String ANIM_TRIM_KEEP_ID = "anim-trim-keep";
const String ANIM_TRIM_REMOVE_ID = "anim-trim-remove";
const String ANIM_TRIM_CANCEL_ID = "anim-trim-cancel";

fn void anim_trim_clicked(Ui* ui) => anim_open_rewrite_dialog(ui, ANIM_TRIM_DIALOG_ID);
fn void anim_trim_closed(Ui* ui) => set_dialog_open(ui, ANIM_TRIM_DIALOG_ID, false);

<*
 The range the dialog opens on: the selected saved keys when two or more are
 selected, so "select what to keep, then Keep range" is the workflow; the
 whole clip otherwise, so the fields read as the clip's own bounds and either
 end can be typed over.
*>
fn void anim_trim_default_range(AppState* app, float* start, float* end) @private
{
	AnimTemplate* clip = app.clip(app.editing);
	*start = 0.0f;
	*end = clip ? clip.duration : 0.0f;
	if (!app.anim_key_selection_ref.same(app.editing)) return;

	float low = (float)math::FLOAT_MAX;
	float high = -(float)math::FLOAT_MAX;
	foreach (time : app.anim_key_selection)
	{
		low = math::min(low, time);
		high = math::max(high, time);
	}
	foreach (key : app.anim_channel_key_selection)
	{
		low = math::min(low, key.time);
		high = math::max(high, key.time);
	}
	if (high - low >= ANIM_SAME_TIME * 2.0f)
	{
		*start = low;
		*end = high;
	}
}

fn Element* build_anim_trim_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	float start, end;
	anim_trim_default_range(app, &start, &end);
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 360, 0 }, .gap = ANIM_GAP })
		{
			@tree((Row) { .gap = ANIM_GAP })
			{
				@tree((Column) { .gap = ANIM_GAP })
				{
					@node((Label) { .text = "Start (seconds)", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 140, .style = TEXT_FIELD_STYLE }).with_id(ANIM_TRIM_START_ID);
				};
				@tree((Column) { .gap = ANIM_GAP })
				{
					@node((Label) { .text = "End (seconds)", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
					@node((TextField) { .width = 140, .style = TEXT_FIELD_STYLE }).with_id(ANIM_TRIM_END_ID);
				};
			};
			@node((Label) { .text = "Keep range makes the range the whole animation, keying the pose at each edge.",
				.size = 12, .color = TEXT_DIM });
			@node((Label) { .text = "Remove range cuts it out and closes the gap; keys inside it are lost.",
				.size = 12, .color = TEXT_DIM });
			@node((Label) { .text = "Ground contacts follow the seconds they were on. Either edit undoes as one step.",
				.size = 12, .color = TEXT_DIM });
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Keep range", &anim_trim_keep)).with_id(ANIM_TRIM_KEEP_ID);
				@node(panel_button("Remove range", &anim_trim_remove)).with_id(ANIM_TRIM_REMOVE_ID);
				@node(panel_button("Cancel", &anim_trim_closed)).with_id(ANIM_TRIM_CANCEL_ID);
			};
		};
	};
	Element* to = body.find_id(ANIM_TRIM_END_ID)!!;
	to.widget_as(TextField).set_text(to, string::tformat("%.9g", end));
	focus_field(body, ANIM_TRIM_START_ID, string::tformat("%.9g", start));
	return body;
}

// Both fields read and checked against the clip. False with the reason said.
fn bool anim_trim_range(Ui* ui, AnimTemplate* clip, float* start, float* end) @private
{
	AppState* app = ui.inherit(AppState)!!;
	float? from = field_text(ui, ANIM_TRIM_START_ID).to_float();
	float? to = field_text(ui, ANIM_TRIM_END_ID).to_float();
	if (catch from) { app.@notice("Enter a start time in seconds, for example 0.5."); return false; }
	if (catch to) { app.@notice("Enter an end time in seconds, for example 1.5."); return false; }
	if (!math::is_finite(from) || !math::is_finite(to) || from < 0.0f || to > clip.duration + ANIM_SAME_TIME)
	{
		app.@notice("The range must lie inside the animation, 0 to %.3g seconds.", clip.duration);
		return false;
	}
	if (to - from < ANIM_SAME_TIME * 2.0f)
	{
		app.@notice("The end must come after the start.");
		return false;
	}
	*start = from;
	*end = math::min(to, clip.duration);
	return true;
}

fn void anim_trim_keep(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) { anim_trim_closed(ui); return; }
	float start, end;
	if (!anim_trim_range(ui, clip, &start, &end)) return;
	if (start < ANIM_SAME_TIME && end > clip.duration - ANIM_SAME_TIME)
	{
		anim_trim_closed(ui);
		return;
	}

	usz before = clip.keyframes.len;
	float playhead = math::clamp(app.edit_time - start, 0.0f, end - start);
	usz dropped = before - kept_within(clip, start, end);
	AnimTemplate part = clip_cropped(mem, *clip, start, end);
	if (!anim_land_rewrite(ui, ANIM_TRIM_DIALOG_ID, part, end - start, playhead,
		"That range keeps no saved pose.", drop_key_selection: true)) return;
	app.@notice("Kept %.3g to %.3g seconds; %d key%s outside it dropped. Ctrl+Z undoes.",
		start, end, dropped, dropped == 1 ? "" : "s");
}

fn void anim_trim_remove(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) { anim_trim_closed(ui); return; }
	float start, end;
	if (!anim_trim_range(ui, clip, &start, &end)) return;

	float length = clip.duration - (end - start);
	if (length < ANIM_SAME_TIME * 2.0f)
	{
		app.@notice("Removing the whole animation leaves nothing to play; to be rid of it, use ⋯ > Delete animation…");
		return;
	}
	usz before = clip.keyframes.len;
	float playhead = app.edit_time <= start ? app.edit_time
		: (app.edit_time >= end ? app.edit_time - (end - start) : start);
	AnimTemplate joined = clip_range_cut(mem, *clip, start, end);
	usz dropped = before - joined.keyframes.len;
	if (!anim_land_rewrite(ui, ANIM_TRIM_DIALOG_ID, joined, length, playhead,
		"That range cannot be removed.", drop_key_selection: true)) return;
	app.@notice("Removed %.3g to %.3g seconds; %d key%s went with it. Ctrl+Z undoes.",
		start, end, dropped, dropped == 1 ? "" : "s");
}

// How many of the clip's keys a crop to `start..end` carries over.
fn usz kept_within(AnimTemplate* clip, float start, float end) @private
{
	usz kept;
	foreach (frame : clip.keyframes)
	{
		if (frame.time > start - ANIM_SAME_TIME && frame.time < end + ANIM_SAME_TIME) kept++;
	}
	return kept;
}

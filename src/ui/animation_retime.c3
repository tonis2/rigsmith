// Stretch a clip without changing the shape of its motion.
module crig;

import cui;
import cui::widgets;
import std::math;

const String ANIM_RETIME_DIALOG_ID = "anim-retime-dialog";

fn void anim_retime_clicked(Ui* ui) => anim_open_rewrite_dialog(ui, ANIM_RETIME_DIALOG_ID);
fn void anim_retime_closed(Ui* ui) => set_dialog_open(ui, ANIM_RETIME_DIALOG_ID, false);

fn Element* build_anim_retime_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	Element* body = @subtree(ui)
	{
		@tree((Column) { .size = { 360, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "New duration (seconds)", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
			@node((TextField) { .width = 140, .style = TEXT_FIELD_STYLE }).with_id("anim-retime-duration");
			@node((Label) { .text = "Keys keep their relative timing.",
				.size = 12, .color = TEXT_DIM });
			@node((Label) { .text = "Ground contacts keep the same cycle phase.",
				.size = 12, .color = TEXT_DIM });
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Stretch timing", &anim_retime_confirmed)).with_id("anim-retime-confirm");
				@node(panel_button("Cancel", &anim_retime_closed)).with_id("anim-retime-cancel");
			};
		};
	};
	focus_field(body, "anim-retime-duration", clip ? string::tformat("%.9g", clip.duration) : "");
	return body;
}

fn void anim_retime_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) { anim_retime_closed(ui); return; }

	float? parsed = field_text(ui, "anim-retime-duration").to_float();
	if (catch parsed)
	{
		app.@notice("Enter a duration in seconds, for example 1.5.");
		return;
	}
	float duration = parsed;
	if (!math::is_finite(duration) || !(duration > 0.0f && duration <= 3600.0f))
	{
		app.@notice("Duration must be between 0 and 3600 seconds.");
		return;
	}
	if (math::abs(duration - clip.duration) < 1.0e-6f)
	{
		anim_retime_closed(ui);
		return;
	}

	float old_duration = clip.duration;
	float phase = old_duration > 0.0f ? math::clamp(app.edit_time / old_duration, 0.0f, 1.0f) : 0.0f;
	AnimTemplate stretched = clip_retimed(mem, *clip, duration);
	if (!anim_land_rewrite(ui, ANIM_RETIME_DIALOG_ID, stretched, duration, phase * duration,
		"That duration would place saved poses too close together.")) return;
	app.@notice("Animation timing stretched to %.3g seconds.", duration);
}

<*
 Open Stretch or Trim, from the More menu, on the clip being edited.
*>
fn void anim_open_rewrite_dialog(Ui* ui, String dialog_id)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui) || !app.clip(app.editing)) return;
	anim_clip_menu_closed(ui);
	set_dialog_open(ui, dialog_id, true);
}

<*
 Land a clip that Stretch or Trim built, as one undo step, and close its dialog.

 `built` is refused, freed and `refusal` shown when its length is not the one
 asked for — the rewrite could not place the saved poses where they belong.
 Taken over either way.

 @param playhead : `Where the edit time lands in the new clip.`
 @param drop_key_selection : `Clear the saved-key selection first, for an edit that removes keys.`
 @return `True when the clip landed.`
*>
fn bool anim_land_rewrite(Ui* ui, String dialog_id, AnimTemplate built, float expected, float playhead,
	String refusal, bool drop_key_selection = false)
{
	AppState* app = ui.inherit(AppState)!!;
	if (math::abs(built.duration - expected) >= 1.0e-6f)
	{
		built.free(mem);
		app.@notice("%s", refusal);
		return false;
	}
	if (drop_key_selection) app.clear_animation_key_selection();
	app.editing = app.land_clip(app.editing, built);
	if (!app.editing.valid()) return false;
	app.edit_time = playhead;
	set_dialog_open(ui, dialog_id, false);
	app.show_edited();
	return true;
}

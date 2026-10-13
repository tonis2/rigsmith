<*
 Optimize and Optimize keys: the whole-clip clean-ups in the Animations pane.

 Both rewrite the clip being edited, as one undo step, so the viewport and the
 timeline show the result at once. They replace what used to be export options:
 an export writes the clip as it is, and these change the clip.

 **Optimize** (the pane's own button) takes out what is ticked: translation holds
 the hips over where the clip starts and rotation takes off its net turn — so a
 walk animates on the spot, keeping its bob — and jitter smooths out a take's
 small shakes, leaving planted feet alone. With a root joint under the hips the
 travel can be carried on it instead of discarded. `AppState.clean_clip` does it.

 **Optimize keys** (Clip tools) drops the keys the clip can lose without changing
 how it moves.
*>
module crig;

import cui;
import cui::widgets;

const String ANIM_CLEANUP_ID = "anim-cleanup";
const String ANIM_OPTIMIZE_ID = "anim-optimize";
const String ANIM_CLEANUP_DIALOG_ID = "anim-cleanup-dialog";
const String ANIM_OPTIMIZE_DIALOG_ID = "anim-optimize-dialog";
const String ANIM_CLEANUP_MODE_ID = "anim-cleanup-mode";
const String ANIM_CLEANUP_TRANSLATION_ID = "anim-cleanup-translation";
const String ANIM_CLEANUP_ROTATION_ID = "anim-cleanup-rotation";
const String ANIM_CLEANUP_JITTER_ID = "anim-cleanup-jitter";
const String ANIM_CLEANUP_APPLY_ID = "anim-cleanup-apply";
const String ANIM_OPTIMIZE_LEVEL_ID = "anim-optimize-level";
const String ANIM_OPTIMIZE_APPLY_ID = "anim-optimize-apply";

String[2] anim_cleanup_modes = { "In place", "On root joint" };
String[2] anim_optimize_levels = { "Light", "Strong" };

fn void anim_cleanup_clicked(Ui* ui) => anim_open_rewrite_dialog(ui, ANIM_CLEANUP_DIALOG_ID);

fn void anim_tools_optimize(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_open_rewrite_dialog(ui, ANIM_OPTIMIZE_DIALOG_ID);
}

fn void anim_cleanup_closed(Ui* ui) => set_dialog_open(ui, ANIM_CLEANUP_DIALOG_ID, false);
fn void anim_optimize_closed(Ui* ui) => set_dialog_open(ui, ANIM_OPTIMIZE_DIALOG_ID, false);

// Nothing is ticked when the dialog opens: taking the travel out of a walk is not
// something to do by accident, and each box says what it removes.
fn Element* build_anim_cleanup_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return @subtree(ui)
	{
		@tree((Column) { .size = { 380, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Take out what is ticked. Without translation and rotation the figure stays on the spot and its limbs keep moving; without jitter the small shakes are smoothed out and planted feet are left alone.",
				.size = ANIM_TEXT_SIZE, .color = TEXT_DIM, .overflow = WRAP });
			if (app.has_root_joint())
			{
				@node((Segmented) { .options = anim_cleanup_modes[..], .selected = 0, .style = SEGMENTED_STYLE })
					.with_id(ANIM_CLEANUP_MODE_ID);
			}
			@node((Checkbox) { .label = "Remove translation", .style = CHECKBOX_STYLE })
				.with_id(ANIM_CLEANUP_TRANSLATION_ID);
			@node((Checkbox) { .label = "Remove rotation", .style = CHECKBOX_STYLE })
				.with_id(ANIM_CLEANUP_ROTATION_ID);
			@node((Checkbox) { .label = "Remove jitter", .style = CHECKBOX_STYLE })
				.with_id(ANIM_CLEANUP_JITTER_ID);
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Apply", &anim_cleanup_confirmed)).with_id(ANIM_CLEANUP_APPLY_ID);
				@node(panel_button("Cancel", &anim_cleanup_closed));
			};
		};
	};
}

fn void anim_cleanup_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	ClipCleanup cleanup = {
		.translation = ui.find_id(ANIM_CLEANUP_TRANSLATION_ID)!!.widget_as(Checkbox).checked,
		.rotation = ui.find_id(ANIM_CLEANUP_ROTATION_ID)!!.widget_as(Checkbox).checked,
		.jitter = ui.find_id(ANIM_CLEANUP_JITTER_ID)!!.widget_as(Checkbox).checked,
	};
	if (try mode = ui.find_id(ANIM_CLEANUP_MODE_ID))
	{
		cleanup.on_root = mode.widget_as(Segmented).selected == 1;
	}
	// Nothing ticked leaves the dialog up, for the box that was meant.
	if (!cleanup.asks())
	{
		app.@notice("Tick translation, rotation or jitter to remove.");
		return;
	}
	anim_cleanup_closed(ui);
	if (app.clean_clip(app.editing, cleanup)) app.show_edited();
}

fn Element* build_anim_optimize_body(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((Column) { .size = { 380, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Drop the keys this clip can lose without changing how it moves. Light keeps the motion almost exact; Strong removes more.",
				.size = ANIM_TEXT_SIZE, .color = TEXT_DIM, .overflow = WRAP });
			@node((Segmented) { .options = anim_optimize_levels[..], .selected = 0, .style = SEGMENTED_STYLE })
				.with_id(ANIM_OPTIMIZE_LEVEL_ID);
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Optimize keys", &anim_optimize_confirmed)).with_id(ANIM_OPTIMIZE_APPLY_ID);
				@node(panel_button("Cancel", &anim_optimize_closed));
			};
		};
	};
}

fn void anim_optimize_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	KeyReduction level = ui.find_id(ANIM_OPTIMIZE_LEVEL_ID)!!.widget_as(Segmented).selected == 1 ? STRONG : LIGHT;
	anim_optimize_closed(ui);
	if (app.optimize_clip_keys(app.editing, level)) app.show_edited();
}

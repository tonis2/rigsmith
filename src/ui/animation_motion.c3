<*
 Remove movement and Optimize keys: the two whole-clip motion tools in Clip tools.

 Both rewrite the clip being edited, as one undo step, so the viewport and the
 timeline show the result at once. They replace what used to be export options:
 an export writes the clip as it is, and these change the clip.

 **Remove movement** takes the travel out of a walk so the figure animates on the
 spot: the hips are held over where the clip starts (translation) and the net
 turn is taken off (rotation), each when ticked; height is left alone so the
 walk keeps its bob. With a root joint under the hips the travel can be carried
 on it instead of discarded.

 **Optimize keys** drops the keys the clip can lose without changing how it moves.
*>
module crig;

import cui;
import cui::widgets;

const String ANIM_MOTION_ID = "anim-motion";
const String ANIM_OPTIMIZE_ID = "anim-optimize";
const String ANIM_MOTION_DIALOG_ID = "anim-motion-dialog";
const String ANIM_OPTIMIZE_DIALOG_ID = "anim-optimize-dialog";
const String ANIM_MOTION_MODE_ID = "anim-motion-mode";
const String ANIM_MOTION_TRANSLATION_ID = "anim-motion-translation";
const String ANIM_MOTION_TURNING_ID = "anim-motion-turning";
const String ANIM_MOTION_APPLY_ID = "anim-motion-apply";
const String ANIM_OPTIMIZE_LEVEL_ID = "anim-optimize-level";
const String ANIM_OPTIMIZE_APPLY_ID = "anim-optimize-apply";

String[2] anim_motion_modes = { "In place", "On root joint" };
String[2] anim_optimize_levels = { "Light", "Strong" };

fn void anim_tools_motion(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_open_rewrite_dialog(ui, ANIM_MOTION_DIALOG_ID);
}

fn void anim_tools_optimize(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_open_rewrite_dialog(ui, ANIM_OPTIMIZE_DIALOG_ID);
}

fn void anim_motion_closed(Ui* ui) => set_dialog_open(ui, ANIM_MOTION_DIALOG_ID, false);
fn void anim_optimize_closed(Ui* ui) => set_dialog_open(ui, ANIM_OPTIMIZE_DIALOG_ID, false);

fn Element* build_anim_motion_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return @subtree(ui)
	{
		@tree((Column) { .size = { 380, 0 }, .gap = ANIM_GAP })
		{
			@node((Label) { .text = "Keep the figure on the spot: its position and facing stay where the clip starts, and the limbs keep moving.",
				.size = ANIM_TEXT_SIZE, .color = TEXT_DIM, .overflow = WRAP });
			if (app.has_root_joint())
			{
				@node((Segmented) { .options = anim_motion_modes[..], .selected = 0, .style = SEGMENTED_STYLE })
					.with_id(ANIM_MOTION_MODE_ID);
			}
			@node((Checkbox) { .label = "Remove translation", .checked = true, .style = CHECKBOX_STYLE })
				.with_id(ANIM_MOTION_TRANSLATION_ID);
			@node((Checkbox) { .label = "Remove rotation", .checked = true, .style = CHECKBOX_STYLE })
				.with_id(ANIM_MOTION_TURNING_ID);
			@tree((Row) { .gap = ANIM_GAP })
			{
				@node(accent_button("Remove movement", &anim_motion_confirmed)).with_id(ANIM_MOTION_APPLY_ID);
				@node(panel_button("Cancel", &anim_motion_closed));
			};
		};
	};
}

fn void anim_motion_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	RootMotionPolicy policy = { .mode = IN_PLACE };
	if (try mode = ui.find_id(ANIM_MOTION_MODE_ID))
	{
		if (mode.widget_as(Segmented).selected == 1) policy.mode = ON_ROOT;
	}
	policy.pinned = ui.find_id(ANIM_MOTION_TRANSLATION_ID)!!.widget_as(Checkbox).checked;
	policy.turning = ui.find_id(ANIM_MOTION_TURNING_ID)!!.widget_as(Checkbox).checked;
	anim_motion_closed(ui);
	if (!policy.pinned && !policy.turning)
	{
		app.@notice("Tick translation, rotation or both to remove.");
		return;
	}
	policy.turn_only = !policy.pinned;
	if (app.move_clip_travel(app.editing, policy)) app.show_edited();
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

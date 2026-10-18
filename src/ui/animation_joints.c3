// Taking chosen joints out of a clip from the Animations pane: Clip tools'
// Remove joint animation (asks first) and Move joints to layer, which the layer
// strip's + menu offers too. Each takes the selected joints and every joint
// below them; the work is app/joint_strip.c3's.
module crig;

import cui;
import cui::widgets;

const String ANIM_REMOVE_JOINTS_ID = "anim-remove-joints";
const String ANIM_REMOVE_JOINTS_CONFIRM_ID = "anim-remove-joints-confirm";
const String ANIM_MOVE_JOINTS_ID = "anim-move-joints";
const String ANIM_LAYER_FROM_JOINTS_ID = "anim-layer-from-joints";

fn void anim_tools_remove_joints(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to edit first");
		return;
	}
	String phrase;
	usz count = app.covered_joints_summary(app.editing, &phrase);
	if (count == 0)
	{
		app.@notice("select a joint first: it and every joint below it lose their keys");
		return;
	}
	Element*? panel = ui.find_id(ANIM_REMOVE_JOINTS_CONFIRM_ID);
	if (catch panel)
	{
		app.@notice("nowhere to confirm removing keys from %s", clip.name);
		return;
	}
	panel.widget_as(ConfirmDialog).ask(panel,
		string::tformat("Removes the animation of %s from %s; they hold their rest pose. Ctrl+Z brings it back.",
			phrase, app.key_target_label(app.editing)),
		&anim_remove_joints_confirmed);
}

fn void anim_remove_joints_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	if (!app.remove_joint_animation(app.editing)) return;
	app.show_edited();
	refresh_animations_view(ui);
}

fn void anim_move_joints(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	if (!app.clip(app.editing))
	{
		app.@notice("pick an animation to edit first");
		return;
	}
	if (app.move_joints_to_layer(app.editing) < 0) return;
	app.show_edited();
	refresh_animations_view(ui);
}

fn void anim_tools_move_joints(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_move_joints(ui);
}

fn void anim_layer_add_from_joints(Ui* ui)
{
	set_dialog_open(ui, ANIM_LAYER_MENU_ID, false);
	anim_move_joints(ui);
}

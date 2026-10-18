// Repairing a take from the Animations pane: Make loop (Clip tools). It replaces
// the clip with the cycle cut from it, so it asks first; one undo step either
// way. The work is app/repair.c3's. Smoothing jitter is one of Optimize's boxes
// (animation_motion.c3).
module crig;

import cui;
import cui::widgets;

const String ANIM_MAKE_LOOP_ID = "anim-make-loop";
const String ANIM_MAKE_LOOP_CONFIRM_ID = "anim-make-loop-confirm";

fn void anim_tools_make_loop(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to cut a loop from first");
		return;
	}
	Element*? panel = ui.find_id(ANIM_MAKE_LOOP_CONFIRM_ID);
	if (catch panel)
	{
		app.@notice("nowhere to confirm replacing %s", clip.name);
		return;
	}
	panel.widget_as(ConfirmDialog).ask(panel,
		string::tformat("Make loop replaces %s with one cycle cut from it; the rest of the take is dropped. Ctrl+Z brings it back.",
			clip.name),
		&anim_make_loop_confirmed);
}

fn void anim_make_loop_confirmed(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	float period_min;
	float period_max;
	float from_min;
	float from_max;
	cycle_defaults(clip.duration, &period_min, &period_max, &from_min, &from_max);
	CycleCut cut;
	DString why = dstring::temp();
	AnimRef landed = app.cut_cycle(app.editing, period_min, period_max, from_min, from_max, period_min * 0.25f, "", &cut, &why,
		in_place: true);
	if (!landed.valid())
	{
		app.@notice("%s", why.str_view());
		return;
	}
	app.@notice("%s is now a %.3g s loop, cut from %.3g s into the take · Ctrl+Z undoes it",
		app.clip(landed).name, cut.period, cut.start);
	app.show_edited();
}

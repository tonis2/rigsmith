// Repairing a take from the Animations pane: Make loop (Clip tools). It replaces
// the clip with a loop, so it asks first, on a ChoiceDialog with two ways ahead:
// Whole take keeps all of it and blends its end into its start (an idle), One
// cycle cuts the best repeat out of it and drops the rest (a walk's stride). Each
// button closes the question itself. One undo step either way. The work is
// app/repair.c3's. Smoothing jitter is one of Optimize's boxes
// (animation_motion.c3).
module crig;

import cui;
import cui::widgets;

const String ANIM_MAKE_LOOP_ID = "anim-make-loop";
const String ANIM_MAKE_LOOP_CONFIRM_ID = "anim-make-loop-confirm";
const String ANIM_MAKE_LOOP_CYCLE_ID = "anim-make-loop-cycle";
const String ANIM_MAKE_LOOP_WHOLE_ID = "anim-make-loop-whole";

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
	float kept = clip.duration - whole_loop_crossfade(clip.duration);
	panel.widget_as(ChoiceDialog).ask(panel,
		string::tformat("Whole take keeps %.3g of %s's %.3g s and blends its end into its start. One cycle cuts the best repeat out of it — a walk's stride — and drops the rest. Ctrl+Z brings it back.",
			kept, clip.name, clip.duration));
}

fn void anim_make_loop_cancel(Ui* ui) => withdraw_choice(ui, ANIM_MAKE_LOOP_CONFIRM_ID);

fn void anim_make_loop_whole(Ui* ui)
{
	withdraw_choice(ui, ANIM_MAKE_LOOP_CONFIRM_ID);
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip) return;
	CycleCut cut;
	DString why = dstring::temp();
	AnimRef landed = app.loop_whole_take(app.editing, whole_loop_crossfade(clip.duration), "", &cut, &why, in_place: true);
	if (!landed.valid())
	{
		app.@notice("%s", why.str_view());
		return;
	}
	app.@notice("%s now loops over its whole %.3g s, its end blended into its start · Ctrl+Z undoes it",
		app.clip(landed).name, cut.period);
	app.show_edited();
}

fn void anim_make_loop_cycle(Ui* ui)
{
	withdraw_choice(ui, ANIM_MAKE_LOOP_CONFIRM_ID);
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

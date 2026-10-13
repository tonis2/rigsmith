// Repairing a take from the Animations pane: Make loop (⋯). One click and one
// undo step; the work is app/repair.c3's. Smoothing jitter is one of Optimize's
// boxes (animation_motion.c3).
module crig;

import cui;

const String ANIM_MAKE_LOOP_ID = "anim-make-loop";

fn void anim_menu_make_loop(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	anim_clip_menu_closed(ui);
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to cut a loop from first");
		return;
	}
	float period_min;
	float period_max;
	float from_min;
	float from_max;
	cycle_defaults(clip.duration, &period_min, &period_max, &from_min, &from_max);
	CycleCut cut;
	DString why = dstring::temp();
	AnimRef landed = app.cut_cycle(app.editing, period_min, period_max, from_min, from_max, period_min * 0.25f, "", &cut, &why);
	if (!landed.valid())
	{
		app.@notice("%s", why.str_view());
		return;
	}
	app.@notice("Cut a %.3g s loop from %.3g s into the take, as %s · Ctrl+Z undoes it",
		cut.period, cut.start, app.clip(landed).name);
	app.show_edited();
}

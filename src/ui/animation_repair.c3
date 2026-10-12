// Repairing a take from the Animations pane: Smooth jitter (Clip tools) and Make
// loop (⋯). Each is one click and one undo step; the work is app/repair.c3's.
module crig;

import cui;

const String ANIM_SMOOTH_ID = "anim-smooth";
const String ANIM_MAKE_LOOP_ID = "anim-make-loop";

fn void anim_tools_smooth(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	if (!anim_can_rewrite(ui)) return;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip)
	{
		app.@notice("pick an animation to smooth first");
		return;
	}
	String name = clip.name.tcopy();
	if (!app.smooth_clip(app.editing, {}, SMOOTH_DEFAULT_WINDOW).valid()) return;
	app.@notice("Smoothed %s: the jitter under %.2g s is filtered out, planted feet left as they are · Ctrl+Z undoes it",
		name, SMOOTH_DEFAULT_WINDOW);
	app.show_edited();
}

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

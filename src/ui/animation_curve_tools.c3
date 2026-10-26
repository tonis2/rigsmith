// Curve clean-up from the Animations pane: Fix flips, Smooth, Simplify, Flatten
// and Match loop seam, in Clip tools and as buttons beside the Curves switch.
// Each is one undo step; the work and the rule for which keys it acts on are
// app/curve_cleanup.c3's.
module crig;

import cui;
import cui::widgets;

const String ANIM_CURVE_FLIPS_ID = "anim-curve-flips";
const String ANIM_CURVE_SMOOTH_ID = "anim-curve-smooth";
const String ANIM_CURVE_SIMPLIFY_ID = "anim-curve-simplify";
const String ANIM_CURVE_FLATTEN_ID = "anim-curve-flatten";
const String ANIM_CURVE_SEAM_ID = "anim-curve-seam";
const String ANIM_CURVE_FLIPS_MENU_ID = "anim-curve-flips-menu";
const String ANIM_CURVE_SMOOTH_MENU_ID = "anim-curve-smooth-menu";
const String ANIM_CURVE_SIMPLIFY_MENU_ID = "anim-curve-simplify-menu";
const String ANIM_CURVE_FLATTEN_MENU_ID = "anim-curve-flatten-menu";
const String ANIM_CURVE_SEAM_MENU_ID = "anim-curve-seam-menu";

fn void anim_curve_cleanup(Ui* ui, CurveCleanup op)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	if (app.curve_cleanup(app.editing, op)) app.show_edited();
}

fn void anim_curve_flips_clicked(Ui* ui) => anim_curve_cleanup(ui, EULER_FILTER);
fn void anim_curve_smooth_clicked(Ui* ui) => anim_curve_cleanup(ui, SMOOTH);
fn void anim_curve_simplify_clicked(Ui* ui) => anim_curve_cleanup(ui, SIMPLIFY);
fn void anim_curve_flatten_clicked(Ui* ui) => anim_curve_cleanup(ui, FLATTEN);
fn void anim_curve_seam_clicked(Ui* ui) => anim_curve_cleanup(ui, LOOP_SEAM);

// The menu rows close the menu before they act, as the others in Clip tools do.
fn void anim_tools_curve_flips(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_curve_flips_clicked(ui);
}

fn void anim_tools_curve_smooth(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_curve_smooth_clicked(ui);
}

fn void anim_tools_curve_simplify(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_curve_simplify_clicked(ui);
}

fn void anim_tools_curve_flatten(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_curve_flatten_clicked(ui);
}

fn void anim_tools_curve_seam(Ui* ui)
{
	set_dialog_open(ui, ANIM_TOOLS_MENU_ID, false);
	anim_curve_seam_clicked(ui);
}

<*
 The five clean-ups as small tipped buttons, built into the enclosing scope.
 Shown beside the Curves switch only while the sheet is in Curves mode.
*>
fn void build_curve_tools()
{
	@tree(widgets::tip("Fix flips — put each rotation key on the same side as the one before it. Poses are unchanged."))
	{
		@node(panel_button("Flips", &anim_curve_flips_clicked)).with_id(ANIM_CURVE_FLIPS_ID);
	};
	@tree(widgets::tip("Smooth — blend each picked key a quarter of the way toward its neighbours; the ends of the range stay."))
	{
		@node(panel_button("Smooth", &anim_curve_smooth_clicked)).with_id(ANIM_CURVE_SMOOTH_ID);
	};
	@tree(widgets::tip("Simplify — remove keys the straight line between their neighbours already reproduces."))
	{
		@node(panel_button("Simplify", &anim_curve_simplify_clicked)).with_id(ANIM_CURVE_SIMPLIFY_ID);
	};
	@tree(widgets::tip("Flatten — level the curve out through the picked keys (flat tangents)."))
	{
		@node(panel_button("Flatten", &anim_curve_flatten_clicked)).with_id(ANIM_CURVE_FLATTEN_ID);
	};
	@tree(widgets::tip("Match loop seam — make each channel's last key equal its first, so the cycle meets itself."))
	{
		@node(panel_button("Seam", &anim_curve_seam_clicked)).with_id(ANIM_CURVE_SEAM_ID);
	};
}

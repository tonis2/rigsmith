// Curve clean-up from the Animations pane: Fix flips, Smooth, Simplify, Flatten
// and Match loop seam, in the Curve tools menu that Curves mode shows. Each is one
// undo step; the work and the rule for which keys it acts on are
// app/curve_cleanup.c3's.
module crig;

import cui;
import cui::widgets;
import std::math;

const String ANIM_CURVE_TOOLS_ID = "anim-curve-tools";
const String ANIM_CURVE_TOOLS_MENU_ID = "anim-curve-tools-menu";
const String ANIM_CURVE_FLIPS_ID = "anim-curve-flips";
const String ANIM_CURVE_SMOOTH_ID = "anim-curve-smooth";
const String ANIM_CURVE_SIMPLIFY_ID = "anim-curve-simplify";
const String ANIM_CURVE_FLATTEN_ID = "anim-curve-flatten";
const String ANIM_CURVE_SEAM_ID = "anim-curve-seam";

fn void anim_curve_tools_clicked(Ui* ui) => open_anim_popup(ui, ANIM_CURVE_TOOLS_MENU_ID);

fn void anim_curve_cleanup(Ui* ui, CurveCleanup op)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, ANIM_CURVE_TOOLS_MENU_ID, false);
	if (!anim_can_rewrite(ui)) return;
	if (app.curve_cleanup(app.editing, op)) app.show_edited();
}

fn void anim_curve_flips_clicked(Ui* ui) => anim_curve_cleanup(ui, EULER_FILTER);
fn void anim_curve_smooth_clicked(Ui* ui) => anim_curve_cleanup(ui, SMOOTH);
fn void anim_curve_simplify_clicked(Ui* ui) => anim_curve_cleanup(ui, SIMPLIFY);
fn void anim_curve_flatten_clicked(Ui* ui) => anim_curve_cleanup(ui, FLATTEN);
fn void anim_curve_seam_clicked(Ui* ui) => anim_curve_cleanup(ui, LOOP_SEAM);

// Each row acts on the picked keys, else the selected joints' whole curves.
fn Element* build_anim_curve_tools_menu(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	bool none = app.clip(app.editing) == null;
	MenuStyle style = VIEW_MENU_STYLE.resolved();
	float width = widgets::PANEL_MIN_W;
	foreach (label : (String[]) { "Fix flips", "Smooth curves", "Simplify curves", "Flatten keys", "Match loop seam" })
	{
		width = math::max(width, widgets::CHECK_GUTTER + ui.text.measure(style.font, label, style.text_size).x + 2 * style.pad_x);
	}
	return @subtree(ui)
	{
		@tree((Column) { })
		{
			@node((PopupMenuItem) { .item = { .label = "Fix flips", .on_select = &anim_curve_flips_clicked, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CURVE_FLIPS_ID);
			@node((PopupMenuItem) { .item = { .label = "Smooth curves", .on_select = &anim_curve_smooth_clicked, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CURVE_SMOOTH_ID);
			@node((PopupMenuItem) { .item = { .label = "Simplify curves", .on_select = &anim_curve_simplify_clicked, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CURVE_SIMPLIFY_ID);
			@node((PopupMenuItem) { .item = { .label = "Flatten keys", .on_select = &anim_curve_flatten_clicked, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CURVE_FLATTEN_ID);
			@node((PopupMenuItem) { .item = { .label = "Match loop seam", .on_select = &anim_curve_seam_clicked, .disabled = none },
				.style = VIEW_MENU_STYLE, .width = width }).with_id(ANIM_CURVE_SEAM_ID);
		};
	};
}

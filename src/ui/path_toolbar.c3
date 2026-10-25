<*
 The Path toolbar: what the Path tool offers while it is on, across the top of
 the 3D view.

 	draw · from motion · slice · close · mute · bake · delete

 A path is a curve a joint follows (anim/path.c3), drawn and edited over the
 posed rig (ui/path_overlay.c3). The cells act on the selected joint (draw, from
 motion) or on the selected path (the rest), each through app/path_edit.c3, one
 undo step apiece. The line beside them says which path is picked and what
 clicking does next.

 On a clip a gait wrote, a second row is the gait itself: Walk, Trot, Pace or
 Gallop, how long each foot is down (duty), the stride and the lift. Each writes
 the gait again (`AppState.rerun_gait`), as dragging a foot path's stance end
 (stride) or the top of its swing (lift) in the viewport does, and as moving a
 foot's landing slice on the sheet does for that foot.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String PATH_TOOLBAR_ID = "path-toolbar";
const String PATH_DRAW_ID = "path-draw";
const String PATH_FROM_MOTION_ID = "path-from-motion";
const String PATH_SLICE_ID = "path-slice";
const String PATH_CLOSE_ID = "path-close";
const String PATH_MUTE_ID = "path-mute";
const String PATH_FOLLOW_ID = "path-follow";
const String PATH_BAKE_ID = "path-bake";
const String PATH_DELETE_ID = "path-delete";
const String PATH_DONE_ID = "path-done";
const String PATH_FINISH_ID = "path-finish";
const String PATH_CANCEL_ID = "path-cancel";
const String PATH_GAIT_KIND_ID = "path-gait-kind";
const String PATH_GAIT_DUTY_ID = "path-gait-duty";
const String PATH_GAIT_STRIDE_ID = "path-gait-stride";
const String PATH_GAIT_LIFT_ID = "path-gait-lift";
const String ANIM_NEW_WALK_ID = "anim-new-walk";

const float PATH_GAIT_SLIDER_W = 150.0;

String[4] path_gait_options = { "Walk", "Trot", "Pace", "Gallop" };

struct PathToolbar (Widget)
{
	bool had;
	bool drawing;
	usz drawn;
	sz selected;
	usz paths;
	uint revision;
	bool gaited;
}

fn bool path_toolbar_shown(AppState* app) => app.path_tool && app.has_mesh();

fn Element* PathToolbar.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.had = path_toolbar_shown(app);
	self.drawing = app.path_drawing;
	self.drawn = path_drawn_points(app);
	self.selected = app.path_selected;
	self.paths = app.shown_paths().len;
	self.revision = app.undo_stack.revision;
	AnimTemplate* clip = app.clip(app.editing);
	self.gaited = clip && clip.gait.set;
	AnimGaitPreset* gait = self.gaited ? &clip.gait : null;
	AnimPath* picked = app.path_selected >= 0 && (usz)app.path_selected < app.shown_paths().len
		? &app.shown_paths()[(usz)app.path_selected] : null;
	String status = path_toolbar_status(app, picked);

	return @subtree(elem.ui)
	{
		@tree((Column) { })
		{
			if (self.had)
			{
				@tree(JOINT_PANEL_SURFACE)
				{
					@tree((Row) { .gap = 4, .cross_align = CENTER })
					{
						@node((Label) { .text = "Path", .size = 13.0f, .color = TEXT });
						@card_icon(PEN_GLYPH, "Draw — click points for a new path for the selected joint; Enter finishes, Esc gives up",
							&path_draw_clicked, app.path_drawing ? LIT : PLAIN).with_id(PATH_DRAW_ID);
						@card_icon(FROM_MOTION_GLYPH, "From motion — a path through where the selected joint goes now; drag its points to reshape the motion",
							&path_from_motion_clicked).with_id(PATH_FROM_MOTION_ID);
						@card_icon(SLICE_GLYPH, "Slice at playhead — the joint is where it is on the path at this frame; drag the slice along the curve to move it (Ctrl-click a curve slices there)",
							&path_slice_clicked).with_id(PATH_SLICE_ID);
						@card_icon(CLOSE_PATH_GLYPH, "Close — join the path's ends into a loop, or open it again",
							&path_close_clicked, picked && picked.closed ? LIT : PLAIN).with_id(PATH_CLOSE_ID);
						@card_icon(FOLLOW_GLYPH, "Follow — the joint turns as the curve turns, keeping the angle its keys give it to the curve: a hand sweeping an arc, a tail's tip through a swish",
							&path_follow_clicked, picked && picked.follow ? LIT : PLAIN).with_id(PATH_FOLLOW_ID);
						@card_icon(MUTE_GLYPH, "Mute — the joint goes back to its keys; the path stays to turn on again",
							&path_mute_clicked, picked && picked.mute ? LIT : PLAIN).with_id(PATH_MUTE_ID);
						@card_icon(BAKE_GLYPH, "Bake to keys — write every path into the keys of the joints it bends and take the paths off",
							&path_bake_clicked, COMMIT).with_id(PATH_BAKE_ID);
						@card_icon(CLEAR_GLYPH, "Delete (Del) — the picked slice, else the picked point, else the whole path",
							&path_delete_clicked).with_id(PATH_DELETE_ID);
						@node((Label) { .text = status, .size = 12.0f, .color = TEXT_DIM });
						if (app.path_drawing)
						{
							@node(accent_button("Finish", &path_finish_clicked)).with_id(PATH_FINISH_ID);
							@node(panel_button("Cancel", &path_cancel_clicked)).with_id(PATH_CANCEL_ID);
						}
						else
						{
							@node(panel_button("Done", &path_done_clicked)).with_id(PATH_DONE_ID);
						}
					};
				};
				if (gait)
				{
					@tree(JOINT_PANEL_SURFACE)
					{
						@tree((Row) { .gap = JOINT_PANEL_GAP, .cross_align = CENTER })
						{
							@node((Segmented) { .options = path_gait_options[..],
								.selected = gait.kind == CUSTOM ? -1 : (sz)gait.kind,
								.on_change = &path_gait_kind_chosen, .style = SEGMENTED_STYLE }).with_id(PATH_GAIT_KIND_ID);
							@tree(widgets::tip("Duty — how much of the cycle each foot is down: more for a slow walk, less for a run"))
							{
								@node((Slider) { .label = "Duty", .value = gait.duty, .min = 0.1f, .max = 0.9f, .step = 0.01f,
									.decimals = 2, .on_commit = &path_gait_duty_committed, .style = SETTINGS_SLIDER_STYLE,
									.size = { PATH_GAIT_SLIDER_W, 0 } }).with_id(PATH_GAIT_DUTY_ID);
							};
							@tree(widgets::tip("Stride — how far a foot travels while it is down, a share of the figure's height; or drag a foot path's stance end"))
							{
								@node((Slider) { .label = "Stride", .suffix = "%", .value = gait.stride * 100.0f, .min = 2.0f,
									.max = 120.0f, .step = 1.0f, .decimals = 0, .on_commit = &path_gait_stride_committed,
									.style = SETTINGS_SLIDER_STYLE, .size = { PATH_GAIT_SLIDER_W, 0 } }).with_id(PATH_GAIT_STRIDE_ID);
							};
							@tree(widgets::tip("Lift — how high a foot clears the floor, a share of the figure's height; or drag the top of a foot path's swing"))
							{
								@node((Slider) { .label = "Lift", .suffix = "%", .value = gait.lift * 100.0f, .min = 0.2f,
									.max = 40.0f, .step = 0.2f, .decimals = 1, .on_commit = &path_gait_lift_committed,
									.style = SETTINGS_SLIDER_STYLE, .size = { PATH_GAIT_SLIDER_W, 0 } }).with_id(PATH_GAIT_LIFT_ID);
							};
						};
					};
				}
			}
		};
	};
}

// Points of the path being drawn so far.
fn usz path_drawn_points(AppState* app) @private
{
	if (!app.path_drawing || app.shown_paths().len == 0) return 0;
	return app.shown_paths()[^1].points.len;
}

// What the strip says beside its cells: what is picked, or what to do first.
fn String path_toolbar_status(AppState* app, AnimPath* picked) @private
{
	if (app.path_drawing)
	{
		usz count = path_drawn_points(app);
		if (count < 2) return string::tformat("Drawing · %d point%s · click where the joint should pass", count, count == 1 ? "" : "s");
		return string::tformat("Drawing · %d points · Finish (Enter) lands it", count);
	}
	if (!app.editing.valid()) return "Open an animation to give it paths";
	if (picked)
	{
		return string::tformat("%s · %d points · %d slices%s", picked.joint, picked.points.len, picked.slices.len,
			picked.generated ? " · from the gait" : "");
	}
	if (app.shown_paths().len > 0) return "Click a path to pick it";
	return "Pick a joint, then Draw or From motion";
}

fn void PathToolbar.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	bool gaited = clip && clip.gait.set;
	if (path_toolbar_shown(app) != self.had || app.path_drawing != self.drawing || path_drawn_points(app) != self.drawn
		|| app.path_selected != self.selected
		|| app.shown_paths().len != self.paths || app.undo_stack.revision != self.revision || gaited != self.gaited)
	{
		elem.request_build();
	}
}

// The name of the selected joint in the edited clip's words, or empty.
fn String path_selected_joint(AppState* app) @private
{
	if (app.selected == 0) return "";
	String[] picked = app.selected_joint_names(mem, app.editing);
	defer
	{
		foreach (name : picked) name.free(mem);
		if (picked.len > 0) alloc::free(mem, picked);
	}
	return picked.len > 0 ? picked[0].tcopy() : "";
}

fn void path_draw_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.path_drawing)
	{
		path_finish_clicked(ui);
		return;
	}
	String joint = path_selected_joint(app);
	if (joint.len == 0)
	{
		app.@notice("pick the joint the path is for — a hand, a foot, a tail's tip — then Draw");
		return;
	}
	if (app.begin_path_drawing(joint)) app.@notice("Draw: click where %s should pass, in order · Enter finishes · Esc gives up", joint);
	app.refresh_ui();
}

fn void path_from_motion_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	String joint = path_selected_joint(app);
	if (joint.len == 0 || !app.editing.valid())
	{
		app.@notice("open an animation and pick the joint whose motion becomes a path");
		return;
	}
	AnimPath? made = app.path_from_motion(app.editing, joint);
	if (catch made)
	{
		app.@notice("%s's motion could not be read", joint);
		return;
	}
	if (app.add_path(app.editing, made) >= 0) app.@notice("%s follows a path through its own motion now — drag its points to change it", joint);
	app.refresh_ui();
}

fn void path_slice_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimTemplate* clip = app.clip(app.editing);
	if (!clip || app.path_selected < 0 || (usz)app.path_selected >= clip.paths.len)
	{
		app.@notice("pick a path first");
		return;
	}
	AnimPath* path = &clip.paths[(usz)app.path_selected];
	float u = path.fraction_at(app.edit_time, clip.duration, clip.loop);
	(void)app.add_path_slice((usz)app.path_selected, u, app.edit_time);
	app.refresh_ui();
}

fn void path_close_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.toggle_path_closed()) app.@notice("pick a path first");
	app.refresh_ui();
}

fn void path_mute_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.toggle_path_mute()) app.@notice("pick a path first");
	app.refresh_ui();
}

fn void path_bake_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	bool? baked = app.bake_paths(app.editing);
	if (catch baked)
	{
		app.@notice("baking needs a rig");
		return;
	}
	app.@notice(baked ? "the paths are keys now — Undo brings them back" : "this animation has no playing path to bake");
	app.refresh_ui();
}

fn void path_delete_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.delete_path_selection()) app.@notice("pick a path, or one of its points or slices, first");
	app.refresh_ui();
}

fn void path_done_clicked(Ui* ui) => menu_path_tool(ui);

fn void path_follow_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.toggle_path_follow())
	{
		app.@notice("pick a path first");
		return;
	}
	AnimTemplate* clip = app.clip(app.editing);
	if (clip && app.path_selected >= 0 && (usz)app.path_selected < clip.paths.len)
	{
		AnimPath* path = &clip.paths[(usz)app.path_selected];
		app.@notice(path.follow ? "%s turns along its path" : "%s only rides its path now", path.joint);
	}
	app.refresh_ui();
}

fn void path_finish_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	(void)app.finish_path_drawing();
	refresh_animations_view(ui);
	app.refresh_ui();
}

fn void path_cancel_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.cancel_path_drawing();
	app.refresh_ui();
}

fn void path_gait_kind_chosen(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	if (index >= path_gait_options.len || !anim_can_rewrite(ui)) return;
	GaitKind kind = (GaitKind)index;
	if (app.regait(kind)) app.@notice("written again as a %s", kind.label());
	refresh_animations_view(ui);
	app.refresh_ui();
}

// The gait written again with one number of its preset changed.
fn void path_gait_number(Ui* ui, int which, float value) @private
{
	AppState* app = ui.inherit(AppState)!!;
	if (!anim_can_rewrite(ui)) return;
	AnimGaitPreset preset = app.gait_preset_of(app.editing);
	defer preset.free(mem);
	if (!preset.set) return;
	switch (which)
	{
		case 0: preset.duty = math::clamp(value, 0.1f, 0.9f);
		case 1: preset.stride = math::max(value / 100.0f, 0.01f);
		default: preset.lift = math::max(value / 100.0f, 0.001f);
	}
	(void)app.rerun_gait(app.editing, &preset);
	refresh_animations_view(ui);
	app.refresh_ui();
}

fn void path_gait_duty_committed(Ui* ui, float value) => path_gait_number(ui, 0, value);
fn void path_gait_stride_committed(Ui* ui, float value) => path_gait_number(ui, 1, value);
fn void path_gait_lift_committed(Ui* ui, float value) => path_gait_number(ui, 2, value);

<*
 "+ New › Walk cycle": a walk written on the rig's feet, open with the Path tool
 so its feet's paths are there to drag.
*>
fn void anim_new_walk_cycle(Ui* ui)
{
	set_dialog_open(ui, ANIM_NEW_MENU_ID, false);
	AppState* app = ui.inherit(AppState)!!;
	AnimRef made = app.new_walk_cycle();
	if (!made.valid()) return;
	app.editing = made;
	app.edit_time = 0.0f;
	app.show_edited();
	if (!app.path_tool) menu_path_tool(ui);
	app.@notice("%s: drag a foot's stance end for stride, the top of its swing for lift; the strip at the top picks the gait",
		app.clip(made).name);
	refresh_animations_view(ui);
	app.refresh_ui();
}

<*
 The tool column's Path cell and the View menu's: the Path toolbar on or off.
 Turning it on puts the clip on show for posing, where paths are drawn.
*>
fn void menu_path_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.path_tool)
	{
		// A path drawn far enough to land is kept: only Esc or Cancel gives it up.
		if (path_drawn_points(app) >= 2)
		{
			(void)app.finish_path_drawing();
			refresh_animations_view(ui);
		}
		app.cancel_path_drawing();
		app.path_tool = false;
	}
	else
	{
		if (!app.editing.valid())
		{
			app.@notice("open an animation first: a path belongs to one");
			return;
		}
		app.end_brush();
		app.end_lasso();
		app.end_area();
		app.end_sketch();
		app.path_tool = true;
		if (app.stage != POSE_STAGE) (void)app.prepare_animation_pose();
	}
	app.refresh_ui();
}

fn MenuItemFlags query_path_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .checked = app.path_tool, .disabled = !app.path_tool && !app.editing.valid() };
}

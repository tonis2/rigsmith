<*
 The workflow guide bar: Model › Skeleton › Skin › Animations › Export across the
 left of the 3D view's header, each step marked done, needs attention or not yet,
 from `AppState.guide_status`. A click goes to where that step is done; the
 hovered step's tip says in plain words what its mark means.

 The same status gives the hint bar its "Next:" line when no tool is running —
 see `guide_next_line`. View > Workflow guide hides both.
*>
module crig;

import cui;
import cui::widgets;
import std::io;
import std::math::vector;

const String GUIDE_BAR_ID = "guide-bar";
const String GUIDE_STEPS_ID = "guide-steps";

// Gap between the bar and the left edge of its pane.
const float GUIDE_MARGIN = 8.0;

const StepsStyle GUIDE_STEPS_STYLE = {
	.text = TEXT,
	.dim = TEXT_DIM,
	.done = { 0.36, 0.72, 0.45, 1.0 },
	.attention = { 0.95, 0.66, 0.22, 1.0 },
	.mark = { 0.05, 0.06, 0.09, 1.0 },
	.hover = BTN_HOVER,
	.current = ACCENT,
	.tip_fill = PANEL,
	.tip_border = { 0.28, 0.30, 0.38, 1.0 },
	.tip_text = TEXT,
	.border_radius = { 5.0, 5.0, 5.0, 5.0 },
	.text_size = 12.0,
	.pad_x = 7.0,
	.icon = 11.0,
	.icon_gap = 5.0,
	.note_gap = 4.0,
	.chevron = 12.0,
	.height = 20.0,
};

String[5] guide_labels = { "Model", "Skeleton", "Skin", "Animations", "Export" };

struct GuideText
{
	char[32] note;
	char[160] detail;
}

// The "Next:" line is formatted, so it lives here rather than in temp memory:
// the hint bar polls it every frame.
char[160] guide_next_buffer;

fn String format_into(char[] buffer, String format, args...) @private
{
	char[]? line = io::bprintf(buffer, format, ...args);
	if (catch line) return "";
	return (String)line;
}

fn String plural(usz count) @private => count == 1 ? "" : "s";

<*
 The words for one step: a short note after its label and the hover tip.
*>
fn void guide_words(AppState* app, GuideStatus g, GuideStep step, GuideText* out, String* note, String* detail)
{
	*note = "";
	GuideState state = g.state(step);
	switch (step)
	{
		case MODEL:
			*detail = g.has_mesh
				? format_into(out.detail[..], "%s · %d vertices · click to frame it",
					app.source_path.len > 0 ? base_name(app.source_path) : "Model", app.geometry.positions.len)
				: "No character yet · click to import one (File › Import .glb)";
		case SKELETON:
			if (!g.has_mesh) { *detail = "Open a model first"; break; }
			if (state == NOT_YET) { *detail = "No skeleton yet · click to fit one (Rig › Apply body plan)"; break; }
			*detail = state == ATTENTION
				? format_into(out.detail[..], "%d joint%s have no name, so animations can't be exported · click to select one",
					g.unnamed, plural(g.unnamed))
				: format_into(out.detail[..], "%d joint%s · click to show it in the Scene list", g.joints, plural(g.joints));
		case SKIN:
			if (!g.has_mesh || g.joints == 0) { *detail = "Fit a skeleton first"; break; }
			if (!g.skin_known) { *detail = "Checking the skin…"; break; }
			if (g.skin_from_file)
			{
				*detail = g.skinless > 0
					? format_into(out.detail[..], "The model's own weights · %d joint%s hold none · click to show the weights",
						g.skinless, plural(g.skinless))
					: "The model's own weights · click to show the weights";
				break;
			}
			*detail = state == ATTENTION
				? format_into(out.detail[..], "%d joint%s hold no skin · click to show the weights and select one",
					g.skinless, plural(g.skinless))
				: "Every joint holds skin · click to show the weights";
		case ANIMATIONS:
			if (g.clips > 0) *note = format_into(out.note[..], "(%d)", g.clips);
			if (g.clips == 0) { *detail = "No animations yet · click to create or add one"; break; }
			*detail = state == ATTENTION
				? format_into(out.detail[..], "%d of %d animation%s can't be found · click to open the list",
					g.clips - g.clips_found, g.clips, plural(g.clips))
				: format_into(out.detail[..], "%d animation%s · click to open them", g.clips, plural(g.clips));
		case EXPORT:
			if (state == ATTENTION) *note = "unsaved";
			if (!g.has_mesh || g.joints == 0) { *detail = "Nothing to export yet"; break; }
			*detail = state == ATTENTION ? "Unsaved changes · Ctrl+S saves · click to export a .glb"
				: state == DONE ? "Saved · click to export a .glb"
				: "Ready · click to export a .glb";
	}
}

<*
 One line for the hint bar about the step to do next, or "" when every step is
 done or the guide is hidden.
*>
fn String guide_next_line(AppState* app)
{
	if (app.config.hide_guide) return "";
	GuideStatus g = app.guide_status();
	sz next = g.next_step();
	if (next < 0) return "";
	GuideStep step = (GuideStep)next;
	GuideState state = g.state(step);
	switch (step)
	{
		case MODEL:
			return "Next: import a character — File › Import .glb";
		case SKELETON:
			if (state == ATTENTION)
			{
				return format_into(guide_next_buffer[..], "Next: name the %d unnamed joint%s — Rig › Auto-name joints",
					g.unnamed, plural(g.unnamed));
			}
			return "Next: fit a skeleton — Rig › Apply body plan, or click the model to place joints";
		case SKIN:
			if (!g.skin_known) return "";
			return format_into(guide_next_buffer[..], "Next: %d joint%s hold no skin — click Skin above to see them",
				g.skinless, plural(g.skinless));
		case ANIMATIONS:
			if (state == ATTENTION)
			{
				return format_into(guide_next_buffer[..], "Next: %d animation%s can't be found — remove or re-add them in Animations",
					g.clips - g.clips_found, plural(g.clips - g.clips_found));
			}
			return "Next: create or add an animation — + New or + From library in Animations";
		case EXPORT:
			return state == ATTENTION ? "Next: save your changes — Ctrl+S, or File › Export .glb"
				: "Next: export — File › Export .glb";
	}
}

struct GuideBar (Widget)
{
	GuideStatus shown;
	char* source;
	usz source_len;
	uint geometry;
	bool hidden;
	Step[5] steps;
	GuideText[5] text;
}

fn void GuideBar.fill(&self, AppState* app, GuideStatus g)
{
	self.shown = g;
	self.source = app.source_path.ptr;
	self.source_len = app.source_path.len;
	self.geometry = app.geometry_generation;
	for (usz i = 0; i < GuideStep::len; i++)
	{
		GuideStep step = (GuideStep)i;
		String note;
		String detail;
		guide_words(app, g, step, &self.text[i], &note, &detail);
		GuideState state = g.state(step);
		self.steps[i] = {
			.label = guide_labels[i],
			.note = note,
			.detail = detail,
			.state = state == DONE ? StepState.DONE : state == ATTENTION ? StepState.ATTENTION : StepState.TODO,
		};
	}
}

fn bool GuideBar.differs(&self, AppState* app, GuideStatus g)
{
	GuideStatus s = self.shown;
	return s.has_mesh != g.has_mesh || s.joints != g.joints || s.unnamed != g.unnamed
		|| s.skin_known != g.skin_known || s.skin_from_file != g.skin_from_file || s.skinless != g.skinless || s.first_skinless != g.first_skinless
		|| s.first_unnamed != g.first_unnamed || s.clips != g.clips || s.clips_found != g.clips_found
		|| s.unsaved != g.unsaved || s.saved != g.saved
		|| self.source != app.source_path.ptr || self.source_len != app.source_path.len
		|| self.geometry != app.geometry_generation;
}

fn Element* GuideBar.build(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	self.hidden = app.config.hide_guide;
	GuideStatus g = app.guide_status();
	self.fill(app, g);
	return @subtree(elem.ui)
	{
		@tree((Column) { })
		{
			if (!self.hidden)
			{
				@node((Steps) {
					.steps = self.steps[..],
					.current = g.next_step(),
					.on_click = &guide_step_clicked,
					.style = GUIDE_STEPS_STYLE,
				}).with_id(GUIDE_STEPS_ID);
			}
		};
	};
}

fn Vec2 GuideBar.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	if (elem.children.len() == 0) return { 0, 0 };
	Vec2 size = elem.layout_child(0, constraints);
	elem.place_child(0, { 0, 0 });
	return size;
}

fn void GuideBar.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.config.hide_guide != self.hidden)
	{
		elem.request_build();
		return;
	}
	if (self.hidden) return;
	GuideStatus g = app.guide_status();
	if (!self.differs(app, g)) return;
	self.fill(app, g);
	if (try Element* steps = elem.ui.find_id(GUIDE_STEPS_ID))
	{
		steps.widget_as(Steps).current = g.next_step();
		steps.request_layout();
		steps.request_paint();
	}
}

// ---------------------------------------------------------------------------
// What a click on each step does.

<*
 Leaves some pane showing `view`: one already does, or a spare pane (not the 3D
 view, Animations, Scene or Generate) is switched to it, or else the first 3D
 view's pane is split to make room.
*>
fn void show_pane_view(Ui* ui, usz view, SplitAxis axis, float ratio)
{
	if (find_leaf_showing(area_layout.root, view)) return;
	AreaNode* target = find_spare_leaf(area_layout.root);
	if (target)
	{
		target.active = view;
		ui.@each(AreaPane; pane)
		{
			if (pane.widget_as(AreaPane).node == target) pane.request_build();
		};
		return;
	}
	AreaNode* model = find_leaf_showing(area_layout.root, 0);
	if (!model) return;
	area_layout.split_leaf(model, axis);
	model.ratio = ratio;
	model.second.active = view;
	ui.@each(AreaHost; host) { host.request_build(); };
}

fn AreaNode* find_spare_leaf(AreaNode* node) @private
{
	if (!node) return null;
	if (node.is_leaf())
	{
		return node.active != 0 && node.active != ANIMATION_VIEW && node.active != SCENE_VIEW
			&& node.active != GENERATE_VIEW ? node : null;
	}
	AreaNode* found = find_spare_leaf(node.first);
	return found ? found : find_spare_leaf(node.second);
}

fn void guide_frame_model(Ui* ui) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.camera = framed(app.geometry.bounds());
	app.camera_reset_generation++;
	ui.invalidate(OrbitCamera);
}

fn void guide_step_clicked(Ui* ui, usz index)
{
	AppState* app = ui.inherit(AppState)!!;
	close_menus(ui);
	GuideStatus g = app.guide_status();
	GuideStep step = (GuideStep)index;
	if (step != EXPORT && !g.has_mesh)
	{
		menu_import(ui);
		return;
	}
	switch (step)
	{
		case MODEL:
			guide_frame_model(ui);
		case SKELETON:
			if (g.joints == 0)
			{
				open_rig_prompt(ui);
				return;
			}
			if (g.state(SKELETON) == ATTENTION && app.doc.find(g.first_unnamed))
			{
				app.select(g.first_unnamed);
			}
			else
			{
				app.select_scene(SKELETON);
			}
			show_pane_view(ui, SCENE_VIEW, SplitAxis.HORIZONTAL, 2.0f / 3.0f);
		case SKIN:
			if (g.joints == 0)
			{
				open_rig_prompt(ui);
				return;
			}
			if (app.tint_mode != TintMode.TERRITORY) app.toggle_weights();
			if (g.state(SKIN) == ATTENTION && app.doc.find(g.first_skinless)) app.select(g.first_skinless);
		case ANIMATIONS:
			show_pane_view(ui, ANIMATION_VIEW, SplitAxis.VERTICAL, 0.65f);
			if (g.clips == 0 && (find_leaf_showing(area_layout.root, LIBRARY_VIEW)
				|| find_leaf_showing(area_layout.root, SCENE_VIEW) || find_other_leaf(area_layout.root)))
			{
				anim_from_library_clicked(ui);
			}
		case EXPORT:
			if (!g.has_mesh)
			{
				app.@notice("Import a character first — File › Import .glb");
				break;
			}
			open_export_dialog(ui);
	}
	app.refresh_ui();
}

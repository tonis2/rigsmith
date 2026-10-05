// Ghosts: onion skin for the open clip, and the small floating panel that tunes it.
//
// The Ghosts button in the transport row turns them on and opens the panel; the
// panel is a cui `Dialog` left non-modal, so it is dragged by its bar and stays
// put while the viewport and the timeline behind it keep working. Everything it
// edits is in the saved config (`ghost_past`, `ghost_future`, `ghost_step`,
// `ghost_opacity`, `ghost_spread`, `ghost_direction`, `show_ghosts`, `show_motion_path`), and the View menu reads
// and writes the same fields.
module crig;
import cui;
import cui::widgets;
import std::math;

const String ANIM_GHOSTS_ID = "anim-ghosts-button";
const String ANIM_GHOSTS_DIALOG_ID = "anim-ghosts-dialog";
const String ANIM_GHOSTS_ON_ID = "anim-ghosts-on";
const String ANIM_GHOSTS_PAST_ID = "anim-ghosts-past";
const String ANIM_GHOSTS_FUTURE_ID = "anim-ghosts-future";
const String ANIM_GHOSTS_STEP_ID = "anim-ghosts-step";
const String ANIM_GHOSTS_OPACITY_ID = "anim-ghosts-opacity";
const String ANIM_GHOSTS_SPREAD_ID = "anim-ghosts-spread";
const String ANIM_GHOSTS_DIRECTION_ID = "anim-ghosts-direction";
const String ANIM_GHOSTS_PATH_ID = "anim-ghosts-path";

const SliderStyle GHOST_SLIDER_STYLE = {
	.track = BTN,
	.fill = ACCENT,
	.hover_fill = { 1.0, 0.70, 0.34, 1.0 },
	.handle = TEXT,
	.label_color = TEXT,
	.value_color = TEXT_DIM,
	.dim_color = { 0.36, 0.38, 0.44, 1.0 },
	.text_size = 13.0,
	.height = 22.0,
	.track_height = 6.0,
	.handle_width = 10.0,
	.label_width = 112.0,
	.value_width = 40.0,
	.gap = 8.0,
	.border_radius = { 3, 3, 3, 3 },
};

fn bool anim_ghosts_dialog_open(Ui* ui)
{
	if (try Element* panel = ui.find_id(ANIM_GHOSTS_DIALOG_ID)) return panel.widget_as(Dialog).open;
	return false;
}

// What the panel shows follows the config; rebuilt when something else (the View
// menu) changed it while the panel is up, never while one of its own sliders is
// being dragged, which only writes the config and repaints.
fn void anim_ghosts_dialog_refresh(Ui* ui)
{
	if (try Element* panel = ui.find_id(ANIM_GHOSTS_DIALOG_ID))
	{
		if (panel.widget_as(Dialog).open) panel.request_build();
	}
}

// Ghosts and the timeline's shading change with the config; the dock rebuilds off
// its snapshot, the viewport needs a paint.
fn void anim_ghosts_changed(Ui* ui, bool save)
{
	AppState* app = ui.inherit(AppState)!!;
	if (save) app.config.save();
	app.refresh_ui();
}

fn void anim_ghosts_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.show_ghosts = on;
	anim_ghosts_changed(ui, true);
	anim_ghosts_dialog_refresh(ui);
}

fn void anim_path_toggled(Ui* ui, bool on)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.show_motion_path = on;
	anim_ghosts_changed(ui, true);
	anim_ghosts_dialog_refresh(ui);
}

fn void anim_ghosts_closed(Ui* ui) => set_dialog_open(ui, ANIM_GHOSTS_DIALOG_ID, false);

<*
 The transport row's Ghosts button. Off: turns them on and opens the panel. On
 with the panel closed: opens it. On with the panel up: turns them off and puts
 the panel away.
*>
fn void anim_ghosts_clicked(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	bool open = anim_ghosts_dialog_open(ui);
	if (app.config.show_ghosts && open)
	{
		anim_ghosts_toggled(ui, false);
		anim_ghosts_closed(ui);
		return;
	}
	if (!app.config.show_ghosts) anim_ghosts_toggled(ui, true);
	set_dialog_open(ui, ANIM_GHOSTS_DIALOG_ID, true);
}

fn void anim_ghost_past_moved(Ui* ui, float value)
{
	ui.inherit(AppState)!!.config.ghost_past = math::clamp((int)math::round(value), 0, MAX_GHOST_SIDE);
	anim_ghosts_changed(ui, false);
}

fn void anim_ghost_future_moved(Ui* ui, float value)
{
	ui.inherit(AppState)!!.config.ghost_future = math::clamp((int)math::round(value), 0, MAX_GHOST_SIDE);
	anim_ghosts_changed(ui, false);
}

fn void anim_ghost_step_moved(Ui* ui, float value)
{
	ui.inherit(AppState)!!.config.ghost_step = math::clamp((int)math::round(value), 1, MAX_GHOST_STEP);
	anim_ghosts_changed(ui, false);
}

fn void anim_ghost_opacity_moved(Ui* ui, float value)
{
	ui.inherit(AppState)!!.config.ghost_opacity = math::clamp(value, MIN_GHOST_OPACITY, 1.0f);
	anim_ghosts_changed(ui, false);
}

fn void anim_ghost_spread_moved(Ui* ui, float value)
{
	ui.inherit(AppState)!!.config.ghost_spread = math::clamp(value, 0.0f, MAX_GHOST_SPREAD);
	anim_ghosts_changed(ui, false);
}

fn void anim_ghost_direction_chosen(Ui* ui, usz index)
{
	if (index >= GHOST_DIRECTIONS) return;
	ui.inherit(AppState)!!.config.ghost_direction = (int)index;
	anim_ghosts_changed(ui, true);
}

String[3] anim_ghost_directions = { "Forward", "Sideways", "Up" };

// Once, when the button comes up: the config is written to disk.
fn void anim_ghost_committed(Ui* ui, float value) => anim_ghosts_changed(ui, true);

fn Element* build_anim_ghosts_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return @subtree(ui)
	{
		@tree((Column) { .size = { 300, 0 }, .gap = ANIM_GAP })
		{
			@node((Checkbox) { .label = "Ghosts", .checked = app.config.show_ghosts,
				.on_change = &anim_ghosts_toggled, .style = CHECKBOX_STYLE }).with_id(ANIM_GHOSTS_ON_ID);
			@node((Slider) { .label = "Past ghosts", .value = (float)app.ghost_past_count(),
				.max = (float)MAX_GHOST_SIDE, .step = 1.0, .decimals = 0,
				.on_change = &anim_ghost_past_moved, .on_commit = &anim_ghost_committed,
				.style = GHOST_SLIDER_STYLE }).with_id(ANIM_GHOSTS_PAST_ID);
			@node((Slider) { .label = "Future ghosts", .value = (float)app.ghost_future_count(),
				.max = (float)MAX_GHOST_SIDE, .step = 1.0, .decimals = 0,
				.on_change = &anim_ghost_future_moved, .on_commit = &anim_ghost_committed,
				.style = GHOST_SLIDER_STYLE }).with_id(ANIM_GHOSTS_FUTURE_ID);
			@node((Slider) { .label = "Every N frames", .value = (float)app.ghost_step_frames(),
				.min = 1.0, .max = (float)MAX_GHOST_STEP, .step = 1.0, .decimals = 0,
				.on_change = &anim_ghost_step_moved, .on_commit = &anim_ghost_committed,
				.style = GHOST_SLIDER_STYLE }).with_id(ANIM_GHOSTS_STEP_ID);
			@node((Slider) { .label = "Opacity", .value = app.ghost_strength(),
				.min = MIN_GHOST_OPACITY, .max = 1.0, .step = 0.05, .decimals = 2,
				.on_change = &anim_ghost_opacity_moved, .on_commit = &anim_ghost_committed,
				.style = GHOST_SLIDER_STYLE }).with_id(ANIM_GHOSTS_OPACITY_ID);
			@node((Slider) { .label = "Spread", .value = app.ghost_spread(),
				.max = MAX_GHOST_SPREAD, .step = 0.01, .decimals = 2,
				.on_change = &anim_ghost_spread_moved, .on_commit = &anim_ghost_committed,
				.style = GHOST_SLIDER_STYLE }).with_id(ANIM_GHOSTS_SPREAD_ID);
			@node((Segmented) { .options = anim_ghost_directions[..], .selected = (sz)app.ghost_direction(),
				.on_change = &anim_ghost_direction_chosen, .style = SEGMENTED_STYLE })
				.with_id(ANIM_GHOSTS_DIRECTION_ID);
			@node((Checkbox) { .label = "Motion path of the selected joint", .checked = app.config.show_motion_path,
				.on_change = &anim_path_toggled, .style = CHECKBOX_STYLE }).with_id(ANIM_GHOSTS_PATH_ID);
			@node((Label) { .text = "Past frames are warm and drawn behind the body; future frames are cool and drawn over it. Spread pushes them apart in rig heights, back for past and forward for future.",
				.size = 12, .color = TEXT_DIM, .overflow = WRAP });
		};
	};
}

<*
 Key interpolation in one place: a single button in the key toolbar that draws the
 selected keys' curve, and the popover it opens. The popover holds the preset
 thumbnails (Smooth, Linear, Step, Ease in, Ease out, Ease in-out), the two ease
 sliders, the key's Time and Span, and a way into the Curves editor.

 Nothing here edits the clip itself: every choice goes through `anim_apply_interpolation`
 and `anim_apply_ease`, which reach `set_selected_animation_interpolation` /
 `set_selected_animation_ease` — one undo step each, and the key under the playhead
 when nothing is selected.
*>
module crig;

import cui;
import cui::widgets;
import std::math;

const String ANIM_INTERP_ID = "anim-interp";
const String ANIM_INTERP_POPOVER_ID = "anim-interp-popover";
const String ANIM_INTERP_EASE_IN_ID = "anim-interp-ease-in";
const String ANIM_INTERP_EASE_OUT_ID = "anim-interp-ease-out";
const String ANIM_INTERP_CURVES_ID = "anim-interp-curves";
const String ANIM_CONTEXT_INTERP_ID = "anim-context-interp";

// One per preset, in INTERP_PRESETS order.
const String[6] ANIM_INTERP_THUMB_IDS = {
	"anim-interp-smooth", "anim-interp-linear", "anim-interp-step",
	"anim-interp-ease-in-preset", "anim-interp-ease-out-preset", "anim-interp-ease-in-out",
};

const float INTERP_BUTTON_W = 116.0;
const float INTERP_BUTTON_H = 24.0;
const float INTERP_THUMB_W = 70.0;
const float INTERP_THUMB_H = 56.0;
const float INTERP_GAP = 6.0;
const float INTERP_NAME_H = 16.0;
// Plain Smooth is drawn as a gentle S: a real eased curve reaches further.
const AnimEase INTERP_SMOOTH_SHAPE = { 0.5, 0.5 };

struct InterpPreset
{
	String name;
	AnimInterpolation interpolation;
	AnimEase ease;
}

const InterpPreset[6] INTERP_PRESETS = {
	{ "Smooth", AUTO, { 0, 0 } },
	{ "Linear", LINEAR, { 0, 0 } },
	{ "Step", HOLD, { 0, 0 } },
	{ "Ease in", AUTO, { 1, 0 } },
	{ "Ease out", AUTO, { 0, 1 } },
	{ "Ease in-out", AUTO, { 1, 1 } },
};

const usz INTERP_SMOOTH = 0;
const usz INTERP_LINEAR = 1;
const usz INTERP_STEP = 2;

<*
 What the keys being edited agree on. `keyed` is false with no key to read;
 `mixed` when their outgoing segments differ (a held segment's ease is ignored).
*>
struct AnimInterpState
{
	bool keyed;
	bool mixed;
	AnimInterpolation interpolation;
	AnimEase ease;
}

fn bool AnimInterpState.same(self, AnimInterpState other)
{
	return self.keyed == other.keyed && self.mixed == other.mixed
		&& self.interpolation == other.interpolation && self.ease.same(other.ease);
}

<*
 Read the selected keys' outgoing segments; with nothing selected, the key under
 the playhead, as the buttons that apply to it do.
*>
fn AnimInterpState anim_interp_state(AppState* app)
{
	AnimInterpState state;
	AnimTemplate* clip = app.key_clip(app.editing);
	if (!clip) return state;
	bool selected = app.anim_key_selection_ref.same(app.editing)
		&& (app.animation_key_selection_count(app.editing) > 0
			|| app.animation_channel_key_selection_count(app.editing) > 0);
	bool channels = selected && app.anim_channel_key_selection.len() > 0;
	float playhead = anim_live_time(app);
	// While the clip runs, the playhead passes a key for a frame or two at a time,
	// so "the key under it" would flash between a name and "No key" the whole way.
	// The running readout is the segment the playhead is in: the last key at or
	// before it. A paused playhead still means exactly the key under it.
	bool running = !selected && app.animating && !app.anim_paused;
	sz holding = 0;
	if (running)
	{
		foreach (i, frame : clip.keyframes) if (frame.time <= playhead + ANIM_SAME_TIME) holding = i;
	}
	foreach (i, frame : clip.keyframes)
	{
		if (running && i != holding) continue;
		if (!running && !selected && math::abs(frame.time - playhead) >= ANIM_SAME_TIME) continue;
		if (selected && !channels && !app.animation_key_selected(app.editing, frame.time)) continue;
		foreach (dot : frame.dots)
		{
			for (int c = 0; c < 2; c++)
			{
				bool rotation = c == 0;
				if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
				if (channels && !app.channel_selection_contains(frame.time, dot.joint_name, rotation ? ROTATION : TRANSLATION)) continue;
				AnimInterpolation curve = dot.interpolation(rotation, clip.blend);
				if (curve == INHERIT) curve = AUTO;
				AnimEase ease = dot.ease(rotation);
				if (!state.keyed)
				{
					state = { .keyed = true, .interpolation = curve, .ease = ease };
					continue;
				}
				if (curve != state.interpolation || (curve != HOLD && !ease.same(state.ease))) state.mixed = true;
			}
		}
	}
	return state;
}

// Which preset the state is, or -1 for a mix, no key, or an ease of the person's own.
fn sz anim_interp_preset(AnimInterpState state)
{
	if (!state.keyed || state.mixed) return -1;
	if (state.interpolation == HOLD) return (sz)INTERP_STEP;
	if (state.ease.none()) return state.interpolation == LINEAR ? (sz)INTERP_LINEAR : (sz)INTERP_SMOOTH;
	for (usz i = 3; i < INTERP_PRESETS.len; i++)
	{
		if (state.ease.same(INTERP_PRESETS[i].ease)) return (sz)i;
	}
	return -1;
}

fn String anim_interp_label(AnimInterpState state)
{
	if (!state.keyed) return "No key";
	if (state.mixed) return "Mixed";
	sz preset = anim_interp_preset(state);
	return preset < 0 ? "Custom" : INTERP_PRESETS[(usz)preset].name;
}

<*
 The curve of a key's outgoing segment, drawn in a box: value against time, from
 the first key's pose at the lower left to the next one's at the upper right.
*>
fn void paint_interp_curve(Painter* painter, Vec2 at, Vec2 size, AnimInterpolation interpolation, AnimEase ease, Color ink)
{
	if (interpolation == HOLD)
	{
		Vec2 low_left = { at.x, at.y + size.y };
		Vec2 low_right = { at.x + size.x, at.y + size.y };
		painter.line(low_left, low_right, 1.6f, ink);
		painter.line(low_right, { at.x + size.x, at.y }, 1.6f, ink);
		return;
	}
	AnimEase shape = interpolation == AUTO && ease.none() ? INTERP_SMOOTH_SHAPE : ease;
	const int STEPS = 14;
	Vec2 prev = { at.x, at.y + size.y };
	for (int i = 1; i <= STEPS; i++)
	{
		float t = (float)i / (float)STEPS;
		Vec2 next = { at.x + t * size.x, at.y + size.y - shape.remap(t) * size.y };
		painter.line(prev, next, 1.6f, ink);
		prev = next;
	}
}

// ---------------------------------------------------------------------------
// Applying

<*
 Choose a preset. Smooth, Linear and Step set the interpolation and clear any
 ease (a held segment keeps its ease, which it ignores); the ease presets set
 the ease and bring a held segment back to Smooth so the choice shows.
*>
fn void anim_interp_apply_preset(Ui* ui, usz preset)
{
	if (preset >= INTERP_PRESETS.len) return;
	AppState* app = ui.inherit(AppState)!!;
	InterpPreset chosen = INTERP_PRESETS[preset];
	AnimInterpState before = anim_interp_state(app);
	if (preset <= INTERP_STEP)
	{
		anim_apply_interpolation(ui, chosen.interpolation);
		if (chosen.interpolation != HOLD && before.keyed && (before.mixed || !before.ease.none()))
		{
			anim_apply_ease(ui, chosen.ease);
		}
	}
	else
	{
		if (before.keyed && before.interpolation == HOLD) anim_apply_interpolation(ui, AUTO);
		anim_apply_ease(ui, chosen.ease);
	}
	anim_interp_refresh(ui);
}

// The two sliders: each sets its own end of the ease and keeps the other.
fn void anim_interp_set_ease(Ui* ui, float value, bool start)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimInterpState state = anim_interp_state(app);
	AnimEase ease = state.keyed && !state.mixed ? state.ease : (AnimEase){ 0, 0 };
	if (start) { ease.start = value; } else { ease.end = value; }
	anim_apply_ease(ui, ease.clamped());
	anim_interp_refresh(ui);
}

fn void anim_interp_ease_in_committed(Ui* ui, float value) => anim_interp_set_ease(ui, value, true);
fn void anim_interp_ease_out_committed(Ui* ui, float value) => anim_interp_set_ease(ui, value, false);

// What the popover shows follows the keys, so it is rebuilt after an edit.
fn void anim_interp_refresh(Ui* ui)
{
	if (try Element* popover = ui.find_id(ANIM_INTERP_POPOVER_ID))
	{
		if (popover.widget_as(Dialog).open) popover.request_build();
	}
}

fn void anim_interp_curves_clicked(Ui* ui)
{
	set_dialog_open(ui, ANIM_INTERP_POPOVER_ID, false);
	anim_sheet_mode_chosen(ui, 1);
}


<*
 Open the popover at `at`. Refused, quietly, with no clip to edit.
*>
fn bool anim_interp_open(Ui* ui, Vec2 at)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.editing.valid() || !app.key_clip(app.editing)) return false;
	Element*? elem = ui.find_id(ANIM_INTERP_POPOVER_ID);
	if (catch elem) return false;
	Dialog* popover = elem.widget_as(Dialog);
	popover.at = at;
	popover.placed = true;
	popover.set_open(elem, true);
	return true;
}

// Under the dock's button when it is there, else under the pointer.
fn bool anim_interp_open_at_button(Ui* ui)
{
	if (try Element* button = ui.find_id(ANIM_INTERP_ID))
	{
		return anim_interp_open(ui, button.absolute + (Vec2){ 0, button.size.y + 2 });
	}
	return anim_interp_open(ui, ui.input.mouse);
}

// The I key: the popover, while a clip is open in the dock.
fn bool animation_interp_key(Ui* ui, Key key)
{
	if (key != Key.I) return false;
	return anim_interp_open_at_button(ui);
}

// The key menu's one Interpolation item: the same popover, where the menu was.
fn void anim_context_interpolation_menu(Ui* ui)
{
	set_dialog_open(ui, "anim-key-context", false);
	anim_interp_open(ui, ui.input.mouse);
}

// ---------------------------------------------------------------------------
// The popover

fn Element* build_anim_interp_body(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	AnimInterpState state = anim_interp_state(app);
	sz now = anim_interp_preset(state);
	AnimEase ease = state.keyed && !state.mixed ? state.ease : (AnimEase){ 0, 0 };
	bool disabled = !state.keyed;
	float width = 3.0f * INTERP_THUMB_W + 2.0f * INTERP_GAP;
	return @subtree(ui)
	{
		@tree((Column) { .size = { width, 0 }, .gap = INTERP_GAP })
		{
			@tree((Row) { .gap = INTERP_GAP, .cross_align = CENTER })
			{
				@node((Label) { .text = "Interpolation", .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
				@node((Label) { .text = anim_interp_label(state), .size = ANIM_TEXT_SIZE, .color = now < 0 && state.keyed ? ACCENT : TEXT });
			};
			for (usz row = 0; row < 2; row++)
			{
				@tree((Row) { .gap = INTERP_GAP })
				{
					for (usz col = 0; col < 3; col++)
					{
						@node((InterpThumb) { .preset = row * 3 + col, .lit = (sz)(row * 3 + col) == now })
							.with_id(ANIM_INTERP_THUMB_IDS[row * 3 + col]);
					}
				};
			}
			@node((Slider) { .label = "Ease in", .value = ease.start, .max = 1.0, .step = 0.05, .decimals = 2,
				.disabled = disabled, .on_commit = &anim_interp_ease_in_committed,
				.style = PHYSICS_SLIDER_STYLE }).with_id(ANIM_INTERP_EASE_IN_ID);
			@node((Slider) { .label = "Ease out", .value = ease.end, .max = 1.0, .step = 0.05, .decimals = 2,
				.disabled = disabled, .on_commit = &anim_interp_ease_out_committed,
				.style = PHYSICS_SLIDER_STYLE }).with_id(ANIM_INTERP_EASE_OUT_ID);
			@node((AnimKeyFields) { }).with_id("anim-key-fields");
			@node(panel_button("Open in Curves", &anim_interp_curves_clicked)).with_id(ANIM_INTERP_CURVES_ID);
		};
	};
}

<*
 One preset: its curve drawn over a box with its name under it. The current one
 is ringed in the accent colour.
*>
struct InterpThumb (Widget)
{
	usz preset;
	bool lit;
	bool hovered;
}

fn Vec2 InterpThumb.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ INTERP_THUMB_W, INTERP_THUMB_H + INTERP_NAME_H });
}

fn void InterpThumb.paint(&self, Element* elem, Painter* painter) @dynamic
{
	InterpPreset preset = INTERP_PRESETS[self.preset];
	Color fill = self.hovered ? BTN_HOVER : BTN;
	painter.rect({ 0, 0 }, { INTERP_THUMB_W, INTERP_THUMB_H },
		{ .color = fill, .border_color = self.lit ? ACCENT : PANEL_BORDER,
			.border_width = self.lit ? 2.0f : 1.0f, .border_radius = { 4, 4, 4, 4 } });
	float pad = 10.0f;
	paint_interp_curve(painter, { pad, pad }, { INTERP_THUMB_W - 2 * pad, INTERP_THUMB_H - 2 * pad },
		preset.interpolation, preset.ease, self.lit ? ACCENT : TEXT);
	painter.text({ 2, INTERP_THUMB_H + 1 }, preset.name, { .size = 11.0f, .color = self.lit ? TEXT : TEXT_DIM });
}

fn void InterpThumb.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (self.hovered == entered) return;
	self.hovered = entered;
	elem.request_paint();
}

fn bool InterpThumb.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != PRESS || event.button != MouseButton.LEFT) return false;
	anim_interp_apply_preset(elem.ui, self.preset);
	return true;
}

// ---------------------------------------------------------------------------
// The dock button

<*
 The one button: a small drawing of the keys' curve and its name. It follows the
 selection each frame without rebuilding the pane, and opens the popover.
*>
struct AnimInterpPicker (Widget)
{
	AnimInterpState shown;
	bool hovered;
}

fn Vec2 AnimInterpPicker.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	return constraints.constrain({ INTERP_BUTTON_W, INTERP_BUTTON_H });
}

fn void AnimInterpPicker.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AnimInterpState state = anim_interp_state(elem.inherit(AppState)!!);
	self.shown = state;
	painter.rect({ 0, 0 }, { INTERP_BUTTON_W, INTERP_BUTTON_H },
		{ .color = self.hovered ? BTN_HOVER : BTN, .border_radius = { 4, 4, 4, 4 } });
	Color ink = state.keyed ? TEXT : TEXT_DIM;
	if (state.keyed && !state.mixed)
	{
		paint_interp_curve(painter, { 7, 5 }, { 20, INTERP_BUTTON_H - 10 }, state.interpolation, state.ease, ink);
	}
	else
	{
		painter.line({ 7, INTERP_BUTTON_H - 5 }, { 27, 5 }, 1.6f, TEXT_DIM);
	}
	painter.text({ 34, 4 }, anim_interp_label(state), { .size = ANIM_TEXT_SIZE, .color = ink });
	painter.text({ INTERP_BUTTON_W - 14, 4 }, "▾", { .size = ANIM_TEXT_SIZE, .color = TEXT_DIM });
}

fn void AnimInterpPicker.update(&self, Element* elem, float dt) @dynamic
{
	if (!anim_interp_state(elem.inherit(AppState)!!).same(self.shown)) elem.request_paint();
}

fn void AnimInterpPicker.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (self.hovered == entered) return;
	self.hovered = entered;
	elem.request_paint();
}

fn bool AnimInterpPicker.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	if (event.kind != PRESS || event.button != MouseButton.LEFT) return false;
	anim_interp_open(elem.ui, elem.absolute + (Vec2){ 0, elem.size.y + 2 });
	return true;
}

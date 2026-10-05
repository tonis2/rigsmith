<*
 How big the interface is drawn.

 	File > Settings > Interface, or ctrl+= / ctrl+- / ctrl+0

 ## Two numbers, and only one of them is a setting

 three lays cui out in the render target's *pixels*. On a display with no
 magnification that is also the number of points a person sees, and the two
 questions never come apart. On a HiDPI output they do: a Wayland session at
 200%, or any retina panel, gives crig a 2560×1440 target for a 1280×720 window,
 and an interface laid out in 2560 points across draws every glyph, row and
 margin at half the physical size it was designed at. That is not a preference
 anybody expressed — it is the display's density leaking into the layout — so it
 is not what the setting is for. `display_scale` reads it off the window and
 `ui_wanted` folds it in, which is why the shipped default is 1.0 and looks right
 everywhere rather than being a number each machine has to be told.

 What `config.ui_scale` holds is the *taste* half on top of that: a dense laptop
 panel read at arm's length wants 1.25 whatever the compositor thinks, and a 4K
 television across a room wants 2. It multiplies, so a person who has set 1.25
 keeps 1.25 when they plug in a second monitor of a different density.

 ## Why it is re-applied every frame

 `UiLayer.set_scale` returns immediately when the number has not moved, so the
 per-frame call in `run_loop` costs a compare. What it buys is every case where
 the density is not known when the tree is mounted or does not stay put: Wayland
 reports a surface's preferred scale only once the surface has entered an output,
 which is after the first frame, and dragging the window to a display of another
 density changes the answer with no event crig subscribes to. Latching it at
 startup would leave both of those half-sized until the next run.
*>
module crig;

import three;
import cui;
import c3w;
import std::math;

<*
 The sizes ctrl+= and ctrl+- walk between.

 Stops rather than a fixed increment, because the useful settings are not evenly
 spaced: the difference between 1.0 and 1.1 is worth a keystroke and the
 difference between 2.5 and 2.6 is not. `MIN_UI_SCALE` and `MAX_UI_SCALE` are the
 ends of it, so the two keys reach everything the slider does.
*>
const float[*] UI_SCALE_STOPS = { 0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 };

// Below which two stops count as the same one. A stop is stored as a float and
// comes back through a config file as a decimal string, so "is the setting
// already on this stop" cannot be asked with `==` without ctrl+= sticking on
// whichever stop the round trip moved by a bit.
const float UI_SCALE_EPSILON @local = 0.001;

<*
 What the display says a point is worth, in the pixels three lays the interface
 out in.

 1.0 with no engine — a unit check links these sources without ever opening a
 window — and 1.0 for any window that answers with nothing, which a minimised one
 does. Never zero, because it is a divisor two lines later.
*>
fn float display_scale()
{
	if (!hosted()) return 1.0f;

	c3w::Window* window = engine.viewer();
	if (window == null) return 1.0f;

	float scale = window.get_scale();
	return scale > 0.0f ? scale : 1.0f;
}

<*
 The range `three::UiLayer.set_scale` will actually lay an interface out in.

 Mirrored here rather than asked for, because three does not export it — it is a
 `math::clamp` inside that function. crig has to know it anyway: what the engine
 clamps is the *product*, so on a 2× display a 3× setting silently becomes 4/2 =
 2× and the top third of the slider does nothing. `usable_ui_scale_max` is what
 keeps the control honest about that, and this pair is the only thing in crig
 that would go stale if that clamp ever moved.
*>
const float ENGINE_MIN_UI_SCALE @local = 0.25;
const float ENGINE_MAX_UI_SCALE @local = 4.0;

<*
 The ends of the setting *on this display*.

 Never wider than `MIN_UI_SCALE`..`MAX_UI_SCALE`, which is the taste judgement,
 and never wider than what the display leaves of the engine's range once the
 density is multiplied in. On an ordinary output the second is not the binding
 one and these are simply the two constants; at 2× the top comes down to 2, which
 is the same *apparent* size a 4× setting would have been asking for.

 A density high enough to invert the two — which needs a scale of 8 and does not
 exist — is guarded rather than reasoned about, since the alternative is a
 `math::clamp` with its ends the wrong way round.
*>
fn float usable_ui_scale_max() => math::min(MAX_UI_SCALE, ENGINE_MAX_UI_SCALE / display_scale());

fn float usable_ui_scale_min()
{
	return math::min(math::max(MIN_UI_SCALE, ENGINE_MIN_UI_SCALE / display_scale()), usable_ui_scale_max());
}

<*
 A setting as it is allowed to be held: inside what this display can deliver, and
 never the zero a config nobody loaded carries.

 The zero case is the one that matters. `CrigConfig` is a plain struct and an
 `AppState` built in a check has one full of zeroes; a scale of zero would lay
 the whole interface out in an infinitely large space, which is a blank window
 rather than a small one.

 Deliberately not the clamp `CrigConfig.adopt` applies. What the *file* is
 allowed to hold is display-independent — a config is carried between machines,
 and a 3× written on a laptop must still say 3× after a session on a 2× monitor
 narrowed what could be shown. This is the clamp at the point of use.
*>
fn float clamp_ui_scale(float wanted)
{
	if (wanted <= 0.0f) return DEFAULT_UI_SCALE;
	return math::clamp(wanted, usable_ui_scale_min(), usable_ui_scale_max());
}

<*
 Target pixels per interface point: the display's density and the user's
 preference, multiplied.

 Inside the engine's own range by construction — that is what `clamp_ui_scale`
 narrowing to the usable ends buys — so nothing downstream quietly re-clamps a
 number the interface is showing as though it had been taken.
*>
fn float ui_wanted(AppState* app) => display_scale() * clamp_ui_scale(app.config.ui_scale);

<*
 Push the setting at the interface layer.

 Idempotent and cheap — `UiLayer.set_scale` compares before it does anything —
 which is what lets `run_loop` call this on every iteration. A no-op with no
 engine, so the settings panel is drivable in a check with no window.
*>
fn void apply_ui_scale(AppState* app)
{
	three::Renderer* renderer = stage_renderer();
	if (renderer == null) return;
	renderer.ui.set_scale(ui_wanted(app));
}

<*
 Take a new setting, write it down and put it on screen.

 Saves, because a size the user picked is the last thing that should need
 picking twice — and the file is a few hundred bytes, the same reasoning
 `remember_recent` uses.

 The notice is sent whether or not the number moved: the two keys run out of
 range eventually, and a keystroke that reports nothing at all reads as a
 keystroke the program did not receive.

 @param wanted : `The multiplier asked for; clamped into range rather than refused.`
*>
fn void adopt_ui_scale(AppState* app, float wanted)
{
	app.config.ui_scale = clamp_ui_scale(wanted);
	app.config.save();
	apply_ui_scale(app);
	app.@notice("interface at %d%%", (int)math::round(app.config.ui_scale * 100.0f));
	app.refresh_ui();
}

<*
 The stop one step from here.

 Falls off neither end: past the last stop in either direction the answer is that
 stop, clamped to what this display can deliver — which is what makes holding
 ctrl+= settle at the top instead of wrapping round to the smallest, and what
 stops it walking into the range the engine would silently take back.

 @param from : `Where the setting is now — not required to be a stop, since the slider can leave it between two.`
 @param direction : `Positive for the next stop up, negative for the next one down.`
 @return `The stop to move to.`
*>
fn float next_ui_scale_stop(float from, int direction)
{
	float here = clamp_ui_scale(from);

	if (direction > 0)
	{
		foreach (stop : UI_SCALE_STOPS)
		{
			if (stop > here + UI_SCALE_EPSILON) return clamp_ui_scale(stop);
		}
		return clamp_ui_scale(UI_SCALE_STOPS[UI_SCALE_STOPS.len - 1]);
	}

	// Backwards over the same table rather than a second one, so the two
	// directions cannot disagree about where the stops are.
	for (usz i = UI_SCALE_STOPS.len; i > 0; i--)
	{
		float stop = UI_SCALE_STOPS[i - 1];
		if (stop < here - UI_SCALE_EPSILON) return clamp_ui_scale(stop);
	}
	return clamp_ui_scale(UI_SCALE_STOPS[0]);
}

<*
 What ctrl+= , ctrl+- and ctrl+0 do.

 One entry point for all three so the keys, the menu and the panel cannot drift
 — the same rule the menu actions in `ui_tree.c3` already follow.

 The settings panel is asked to rebuild whether or not it is open, because it is
 the one place showing this number that does not read it every frame: the slider
 is built from `config.ui_scale` and would otherwise still be sitting where the
 pointer left it while the keys moved the interface around it.

 @param direction : `Positive for bigger, negative for smaller, zero to go back to the default.`
*>
fn void nudge_ui_scale(Ui* ui, int direction)
{
	AppState* app = ui.inherit(AppState)!!;

	adopt_ui_scale(app, direction == 0
		? DEFAULT_UI_SCALE
		: next_ui_scale_stop(app.config.ui_scale, direction));

	refresh_settings_dialog(ui);
}

// The settings panel's reset button, in the shape cui's buttons take.
fn void menu_ui_reset(Ui* ui) => nudge_ui_scale(ui, 0);

<*
 Take the value the settings slider was released on.

 The release rather than every value the drag passes through, and that is not a
 performance judgement: re-laying the interface out mid-drag moves the track
 under the pointer, and a slider whose own handle runs away from the finger
 holding it cannot be aimed. The readout follows the drag either way — the widget
 paints its own number — so the only thing deferred is the part that would fight
 the gesture.
*>
fn void ui_scale_committed(Ui* ui, float value)
{
	adopt_ui_scale(ui.inherit(AppState)!!, value);
}

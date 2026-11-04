<* What the keyboard does in the window: each stage in turn, until one answers. *>
module crig;

import cui;
import cui::widgets;
import std::math;

<*
 One key press, for the stages to read.
*>
struct KeyPress @private
{
	Ui* ui;
	AppState* app;
	Key key;
	bool ctrl;
	bool shift;
	TransportRepeat* repeat;
}

enum KeyAnswer @private
{
	PASS,     // not this stage's: the next one reads it
	DECLINED, // nobody's
	TAKEN,    // handled
	REFRESH,  // handled, and the interface has to catch up
}

alias KeyStage @private = fn KeyAnswer(KeyPress* press);

// In this order: a gesture in hand owns its keys before any mode is asked.
const KeyStage[*] KEY_STAGES @private = {
	&transform_stage,
	&view_stage,
	&ctrl_stage,
	&path_stage,
	&path_delete_stage,
	&drag_stage,
	&clip_stage,
	&move_verb_stage,
	&letter_stage,
};

// A keyboard move or turn owns every key, ctrl chords too.
fn KeyAnswer transform_stage(KeyPress* press) @private
{
	if (!press.app.transform_interaction.active) return PASS;
	(void)handle_transform_key(press.app, press.key, press.shift);
	return TAKEN;
}

// Before the ctrl chords: here ctrl picks the opposite face.
fn KeyAnswer view_stage(KeyPress* press) @private
{
	if (try ViewAxis view = view_key(press.key, press.ctrl))
	{
		snap_view(press.ui, view);
		return TAKEN;
	}
	return PASS;
}

// With ctrl down nothing goes on to the letters.
fn KeyAnswer ctrl_stage(KeyPress* press) @private
{
	if (!press.ctrl) return PASS;
	AppState* app = press.app;
	// Ctrl+Shift+Z as well as Ctrl+Y: the two conventions split by platform
	// and neither is wrong, so both work.
	switch (press.key)
	{
		case Key.Z:
			if (press.shift) { menu_redo(press.ui); } else { menu_undo(press.ui); }
			return TAKEN;
		case Key.Y:
			menu_redo(press.ui);
			return TAKEN;
		case Key.S:
			if (press.shift) { menu_save_as(press.ui); } else { menu_save(press.ui); }
			return TAKEN;
		case Key.N:
			menu_new_scene(press.ui);
			return TAKEN;
		case Key.O:
			menu_open_scene(press.ui);
			return TAKEN;
		case Key.I:
			menu_import(press.ui);
			return TAKEN;
		case Key.E:
			// Mirrors the menu item, greying and all: nothing to choose
			// clips or a destination for when there is no model to write.
			menu_export(press.ui);
			return TAKEN;
		case Key.A:
			// Reached only with Ctrl down, so plain A still toggles
			// auto-connect: this switch returns before the letter shortcuts
			// below are ever consulted.
			menu_select_all(press.ui);
			return TAKEN;
		// The viewport's clipboard: the pose of the selected joints. Only
		// reached when nothing nearer the focus claimed the chord — the
		// dopesheet takes Ctrl+C/V for saved keys and a text field for its
		// text, and each returns before bubbling here — which is what keeps
		// the three clipboards apart without any of them knowing about the
		// others. Shift on the paste flips it onto the twins. Outside
		// animation editing there is no pose to copy, and the chord is left
		// unclaimed rather than answered with a refusal.
		case Key.C:
			if (!app.animation_pose_ready()) return DECLINED;
			app.copy_pose();
		case Key.V:
			if (!app.animation_pose_ready()) return DECLINED;
			if (brush_holds_joints(app)) break;
			app.paste_pose(flipped: press.shift);
		case Key.R:
			// Set root, which used to be plain R and gave the letter up —
			// first to a rename panel, now to the turn alone. Through the menu
			// handler so the item and the key refuse an empty selection
			// identically.
			//
			// In this block so it holds in animation editing too — where it is
			// refused, and has to be: re-rooting re-parents every joint, and a
			// pose is a set of parent-relative rotations, so it would silently
			// reinterpret every one of them.
			if (app.rig_locked())
			{
				app.@notice("finish animation editing before moving the root");
				return TAKEN;
			}
			menu_set_root(press.ui);
		// How big the interface is drawn, on the three keys every application
		// that has the setting uses for it — and the plus on both rows,
		// because the one beside the digits needs shift on most layouts and
		// the one on the numpad does not.
		//
		// Above the letter shortcuts for the reason the whole ctrl block is:
		// plain 0 belongs to nothing, but plain = and - are free and are not
		// worth claiming for a setting that is changed twice a year.
		case Key.EQUALS:
		case Key.KP_ADD:
			nudge_ui_scale(press.ui, 1);
		case Key.MINUS:
		case Key.KP_SUBTRACT:
			nudge_ui_scale(press.ui, -1);
		case Key.KEY_0:
		case Key.NUM_0:
			nudge_ui_scale(press.ui, 0);
		default:
			return DECLINED;
	}
	return REFRESH;
}

// Drawing a path takes Enter to finish it and Esc to give it up, and no other key.
fn KeyAnswer path_stage(KeyPress* press) @private
{
	AppState* app = press.app;
	if (!app.path_drawing) return PASS;
	switch (press.key)
	{
		case Key.RETURN:
		case Key.KP_RETURN: (void)app.finish_path_drawing();
		case Key.ESCAPE: app.cancel_path_drawing();
		default: return DECLINED;
	}
	return REFRESH;
}

// A picked point or slice of a path is what Delete takes.
fn KeyAnswer path_delete_stage(KeyPress* press) @private
{
	AppState* app = press.app;
	if (app.drag.dot != 0 || (press.key != Key.DELETE && press.key != Key.BACKSPACE)) return PASS;
	if (!app.paths_shown() || (app.path_point_selected < 0 && app.path_slice_selected < 0)) return PASS;
	(void)app.delete_path_selection();
	return REFRESH;
}

// A joint in hand owns the axis letters and Esc, and no other key.
fn KeyAnswer drag_stage(KeyPress* press) @private
{
	AppState* app = press.app;
	if (app.drag.dot == 0) return PASS;
	bool plane = press.shift && app.drag.verb != DragVerb.TURN;
	switch (press.key)
	{
		case Key.X: app.lock_drag(plane ? DragAxis.YZ : DragAxis.X);
		case Key.Y: app.lock_drag(plane ? DragAxis.XZ : DragAxis.Y);
		case Key.Z: app.lock_drag(plane ? DragAxis.XY : DragAxis.Z);
		case Key.B: app.lock_drag(DragAxis.BONE);
		case Key.ESCAPE: app.cancel_drag();
		default: return DECLINED;
	}
	return REFRESH;
}

// The open clip's keys: transport, the interpolation popover, and keying.
fn KeyAnswer clip_stage(KeyPress* press) @private
{
	if (animation_transport_key(press.ui, press.key))
	{
		press.repeat.press(press.key);
		return TAKEN;
	}
	if (animation_interp_key(press.ui, press.key)) return TAKEN;
	if (animation_keying_key(press.ui, press.key, press.shift)) return TAKEN;
	return PASS;
}

// G and R: a pose verb on a clip, or a transform of the rest rig. Neither moves a
// joint while the brush is open, and a refused verb still takes its key.
fn KeyAnswer move_verb_stage(KeyPress* press) @private
{
	if (press.key != Key.G && press.key != Key.R) return PASS;
	AppState* app = press.app;
	if (brush_holds_joints(app)) return REFRESH;
	if (app.animation_pose_ready())
	{
		if (press.key == Key.G) { app.begin_pose(); } else { app.begin_turn(); }
		return REFRESH;
	}
	(void)begin_keyboard_transform(press.ui, press.key == Key.G ? MOVE_TRANSFORM : ROTATE_TRANSFORM);
	return TAKEN;
}

fn KeyAnswer letter_stage(KeyPress* press) @private
{
	AppState* app = press.app;
	switch (press.key)
	{
		// Backspace deletes too: on a Mac keyboard the key labelled "delete" is
		// Backspace, and reaching forward delete there means holding fn.
		case Key.X:
		case Key.DELETE:
		case Key.BACKSPACE:
			if (app.selected == 0) return DECLINED;
			menu_delete(press.ui);
			return TAKEN;
		case Key.C:
			// Through the menu handler, so the keyboard and the item report the
			// same counts — this is the one operation whose result is a number.
			menu_connect_selection(press.ui);
			return TAKEN;
		case Key.T:
			// The lasso's letter, both halves of it: the plain press walks the tool
			// along its two jobs, the shifted one goes straight to pinning. Which
			// makes the pair the same shape as W and shift+W — the plain letter for
			// the job that reads the rig, the shifted one for the job that writes
			// the bind.
			//
			// The plain letter was unclaimed until now: it used to open a viewport
			// mode that pinned a whole piece of the mesh on a click, a Shells pane
			// took that job over, and the pane has since gone for now. Through the
			// menu handlers, so the key and the items refuse in the same words.
			if (press.shift)
			{
				menu_lasso_mode(press.ui);
				return TAKEN;
			}
			menu_lasso_select(press.ui);
			return TAKEN;
		// No plain R here. It is the turn, claimed by the posing block above,
		// and nothing else: it was set root once (a once-per-rig operation that an
		// imported rig never needs — glTF's node hierarchy already says which way
		// the chain runs — so it keeps ctrl+R and its Edit menu item), then a
		// rename panel, which reached the letter only outside animation posing.
		// Since posing is always ready with a clip parked, that door was mostly
		// shut, and it opened a second panel over the Joint card, which already
		// showed the name. The card edits it now, with the button beside its
		// title, and R means one thing in every state.
		case Key.M:
			// Two things reflect across the symmetry plane, and the shift tells
			// them apart the way it does for W and T: the plain letter mirrors the
			// rest dots, the shifted one mirrors the *pose* of the selected joints
			// — the More menu's Mirror pose — and neither depends on which
			// workspace is up. M used to take the pose's meaning whenever a clip
			// was open to posing, which is a state nothing on screen names, so a
			// person could not say which of the two a press was about to do.
			//
			// Within each, one reading: `mirror_selection` decides per dot whether
			// the twin has to be made or an existing one pulled into line, so
			// there is nothing further for a modifier to choose — which is why the
			// menu item and this case both go through `menu_mirror_selection` and
			// report the split as a notice instead.
			//
			// Left unhandled with nothing selected rather than consumed into a
			// no-op, so the press is still an unclaimed key rather than a command
			// that silently did nothing. The pose is the exception: with nothing
			// selected the whole pose is mirrored, as the button does.
			if (brush_holds_joints(app)) break;
			if (press.shift)
			{
				anim_pose_op(press.ui, MIRROR);
				return TAKEN;
			}
			if (app.selected == 0) return DECLINED;
			menu_mirror_selection(press.ui);
			return TAKEN;
		case Key.L:
			// The anchor: hold this joint's world position so moving another bends
			// the limb to keep it there — lock the feet, pull the hips, the figure
			// sits. The Joint card's two padlock toggles are the same pair; this is
			// their keyboard copy (shift+L is rotation). Nothing selected leaves the
			// press unclaimed rather than a silent no-op, the way M does.
			if (brush_holds_joints(app)) break;
			if (app.selected == 0)
			{
				app.@notice("select a joint to anchor it");
				return DECLINED;
			}
			{
				// The whole selection, like the card's padlocks: several joints locked
				// or unlocked together, the new state read off the primary.
				bool now = press.shift ? !app.locks_rotation(app.selected) : !app.locks_position(app.selected);
				usz acted = app.set_selection_anchor_half(press.shift, now);
				String half = press.shift ? "rotation" : "position";
				if (acted > 1)
				{
					app.@notice(now ? "%s anchored on %d joints" : "%s released on %d joints", half, (int)acted);
				}
				else
				{
					Dot* locked_dot = app.doc.find(app.selected);
					String locked_name = locked_dot && locked_dot.name.len > 0 ? locked_dot.name : "joint";
					app.@notice(now ? "%s of %s anchored" : "%s of %s released", half, locked_name);
				}
			}
			refresh_joint_panel(press.ui);
			return TAKEN;
		case Key.A:
			menu_auto_connect(press.ui);
			return TAKEN;
		case Key.W:
			// Shift picks the sibling tool rather than a second meaning: the Area
			// tool hands a joint a whole part and the brush corrects it by hand,
			// the two ways to change a bind without moving a joint.
			if (press.shift)
			{
				menu_weight_brush(press.ui);
				return TAKEN;
			}
			menu_weights_panel(press.ui);
			return TAKEN;
		case Key.RIGHT_BRACKET:
			// The third way to change a bind without moving a dot, and the only one
			// that acts on every boundary at once. A bracket pair rather than a
			// letter: the two are one control with two directions, and no letter
			// says "more of that" and "less of it" the way ] and [ sitting beside
			// each other do. Both are free — neither reaches any other handler.
			menu_sharpen_blend(press.ui);
			return TAKEN;
		case Key.LEFT_BRACKET:
			menu_soften_blend(press.ui);
			return TAKEN;
		case Key.F:
			// While the brush is open F is its size key, held rather than pressed,
			// and the viewport reads it live. Swallowed here so a press does not
			// also turn off the very view the brush put up to paint against —
			// which would leave the user sizing a circle over a mesh showing
			// something else.
			if (!app.brushing) menu_falloff(press.ui);
			return TAKEN;
		case Key.N:
			// Blender's N-panel key, and its job here: show or hide the selected-
			// joint settings card. Joint names moved to the View menu (no letter of
			// their own) when N took this — they are a niche overlay, the card is
			// the panel a rig is built through.
			//
			// A notice as well as the toggle: it confirms the keyboard path while
			// the rail itself remains available for the mouse path.
			menu_show_joint_panel(press.ui);
			return TAKEN;
		case Key.B:
			menu_show_mesh(press.ui);
			return TAKEN;
		case Key.S:
			// Plain S only; ctrl+S saved the session and returned above.
			menu_show_rig(press.ui);
			return TAKEN;
		case Key.Z:
			// Plain Z only. Ctrl+Z returned above as undo and a move in progress
			// claimed it as an axis lock before that, so this is the reading left
			// over — which is also Blender's, where Z is the shading key.
			menu_wireframe(press.ui);
			return TAKEN;
		case Key.RETURN:
		case Key.KP_RETURN:
			// Apply in the Area tool, and done with the brush; otherwise the key
			// is not ours.
			if (!app.areaing && !app.brushing) return DECLINED;
			app.commit_area();
			refresh_joint_panel(press.ui);
		case Key.ESCAPE:
			// Backs out one layer at a time: the mode first, then the
			// selection, so leaving a mode does not also lose your place.
			//
			// The brush: escape closes it and nothing is cancelled, because every stroke already went on the ledger
			// as it was made. There is no half-finished state for the key to undo,
			// and taking a stroke back is Ctrl+Z like taking anything back.
			if (app.sketching)
			{
				app.end_sketch();
			}
			else if (app.brushing)
			{
				// The Weights card the brush was opened from takes its tool back.
				app.leave_brush();
			}
			else if (app.lasso_active)
			{
				// A region half drawn is the one half-finished state either of
				// these modes has, and escape is what a hand reaches for when the
				// outline has gone wrong. It cancels the gesture and nothing else
				// — the mode stays open, because the next thing wanted is another
				// try rather than a different tool. Nothing to undo: a lasso
				// commits on its release, so an abandoned one never reached the
				// ledger.
				app.drop_lasso_stroke();
				app.lasso_active = false;
			}
			else if (app.lassoing)
			{
				app.leave_lasso();
			}
			else if (app.areaing && app.area_pending())
			{
				// A picked part is dropped first, the tool second.
				app.drop_area_part();
			}
			else if (app.areaing)
			{
				app.end_area();
			}
			// Picked keys go before the joint, so one Esc doesn't lose both.
			else if (!animation_escape_keys(press.ui))
			{
				app.select(0);
			}
		default:
			return DECLINED;
	}

	return REFRESH;
}

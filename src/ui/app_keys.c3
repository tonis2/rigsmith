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
	Shortcut* ran;
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

// Runs the plain command on this key, if there is one.
fn KeyAnswer table_stage(KeyPress* press) @private
{
	Shortcut row = shortcut_of(press.key, press.ctrl, press.shift);
	if (row == NONE) return PASS;
	*press.ran = row;
	row.run(press.ui);
	return row.refresh ? REFRESH : TAKEN;
}

// With ctrl down nothing goes on to the letters.
fn KeyAnswer ctrl_stage(KeyPress* press) @private
{
	if (!press.ctrl) return PASS;
	KeyAnswer plain = table_stage(press);
	if (plain != PASS) return plain;
	AppState* app = press.app;
	switch (press.key)
	{
		// The pose clipboard. Left unclaimed with no pose to copy; see rules/shortcuts.md.
		case Key.C:
			if (!app.animation_pose_ready()) return DECLINED;
			app.copy_pose();
		case Key.V:
			if (!app.animation_pose_ready()) return DECLINED;
			if (brush_holds_joints(app)) break;
			app.paste_pose(flipped: press.shift);
		case Key.R:
			// Refused while editing: re-rooting would reinterpret every pose.
			if (app.rig_locked())
			{
				app.@notice("finish animation editing before moving the root");
				return TAKEN;
			}
			menu_set_root(press.ui);
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
	KeyAnswer plain = table_stage(press);
	if (plain != PASS) return plain;
	AppState* app = press.app;
	switch (press.key)
	{
		// Backspace too: it is the key labelled delete on a Mac.
		case Key.X:
		case Key.DELETE:
		case Key.BACKSPACE:
			if (app.selected == 0) return DECLINED;
			menu_delete(press.ui);
			return TAKEN;
		case Key.M:
			// Plain mirrors the rest dots, shifted the pose. With nothing selected the
			// pose mirrors whole and the plain key is left unclaimed.
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
			// Hold the joint's world position, or with shift its rotation.
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
		case Key.F:
			// With the brush open F is its size key, held, and the viewport reads it.
			if (!app.brushing) menu_falloff(press.ui);
			return TAKEN;
		case Key.RETURN:
		case Key.KP_RETURN:
			// Apply in the Area tool, and done with the brush; otherwise the key
			// is not ours.
			if (!app.areaing && !app.brushing) return DECLINED;
			app.commit_area();
			refresh_joint_panel(press.ui);
		case Key.ESCAPE:
			// Backs out one layer at a time: the mode, then the selection.
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
				// Drops the outline and keeps the tool: the next thing wanted is another try.
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

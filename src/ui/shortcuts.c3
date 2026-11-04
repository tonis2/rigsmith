<*
 Every key the window answers to: one row each, read by the key stages, the
 Controls dialog and the menus, so the three can't disagree.

 A row with a `run` is a plain command and runs from here (`shortcut_of`). One
 without depends on the state, so a stage in app_keys.c3 reads it; the row is what
 the interface says about it.
*>
module crig;

import cui;
import cui::widgets;

<*
 When a key means this. Two rows in one mode can't share a key.
*>
enum ShortcutMode : char
{
	COMMAND,
	MOVING,   // a joint in hand
	WEIGHTS,  // the Area tool
	BRUSHING,
	POSING,
	SHEET,    // a clip open
	PATH,
	ALIAS,    // a second key for a row, not listed
}

fn void ui_scale_up(Ui* ui) @private => nudge_ui_scale(ui, 1);
fn void ui_scale_down(Ui* ui) @private => nudge_ui_scale(ui, -1);
fn void ui_scale_reset(Ui* ui) @private => nudge_ui_scale(ui, 0);

enum Shortcut : char (Key key, bool ctrl, bool shift, ShortcutMode mode, OnClick run, bool refresh, String label, String action)
{
	NONE { (Key)0, false, false, ALIAS, null, false, "", "" },
	NEW_SCENE { Key.N, true, false, COMMAND, &menu_new_scene, false, "Ctrl+N", "a new, empty scene" },
	OPEN_SCENE { Key.O, true, false, COMMAND, &menu_open_scene, false, "Ctrl+O", "open a scene" },
	IMPORT_GLB { Key.I, true, false, COMMAND, &menu_import, false, "Ctrl+I", "import a .glb into the scene as a character" },
	EXPORT_GLB { Key.E, true, false, COMMAND, &menu_export, false, "Ctrl+E", "export as .glb — the clips you tick, or the whole scene" },
	UNDO { Key.Z, true, false, COMMAND, &menu_undo, false, "Ctrl+Z", "undo" },
	REDO { Key.Y, true, false, COMMAND, &menu_redo, false, "Ctrl+Y", "redo" },
	REDO_SHIFTED { Key.Z, true, true, ALIAS, &menu_redo, false, "Ctrl+Shift+Z", "redo" },
	SAVE { Key.S, true, false, COMMAND, &menu_save, false, "Ctrl+S", "save each character into its model, and the scene file" },
	SAVE_AS { Key.S, true, true, COMMAND, &menu_save_as, false, "Ctrl+Shift+S", "save the scene under another name" },
	SELECT_ALL { Key.A, true, false, COMMAND, &menu_select_all, false, "Ctrl+A", "select every joint" },
	SET_ROOT { Key.R, true, false, COMMAND, null, false, "Ctrl+R", "make the selected joint the root — refused while editing animation" },
	UI_BIGGER { Key.EQUALS, true, false, COMMAND, &ui_scale_up, true, "Ctrl+=", "draw the whole interface bigger" },
	UI_BIGGER_PAD { Key.KP_ADD, true, false, ALIAS, &ui_scale_up, true, "Ctrl+=", "draw the whole interface bigger" },
	UI_SMALLER { Key.MINUS, true, false, COMMAND, &ui_scale_down, true, "Ctrl+-", "draw the whole interface smaller" },
	UI_SMALLER_PAD { Key.KP_SUBTRACT, true, false, ALIAS, &ui_scale_down, true, "Ctrl+-", "draw the whole interface smaller" },
	UI_DEFAULT { Key.KEY_0, true, false, COMMAND, &ui_scale_reset, true, "Ctrl+0", "back to the size the display asks for" },
	UI_DEFAULT_PAD { Key.NUM_0, true, false, ALIAS, &ui_scale_reset, true, "Ctrl+0", "back to the size the display asks for" },
	CONNECT { Key.C, false, false, COMMAND, &menu_connect_selection, false, "C", "bond the selected joints into a chain, in the order picked — again to unbond" },
	LASSO_SELECT { Key.T, false, false, COMMAND, &menu_lasso_select, false, "T", "lasso: draw around joints to select them — again to switch it to pinning" },
	LASSO_PIN { Key.T, false, true, COMMAND, &menu_lasso_mode, false, "Shift+T", "the same lasso, straight to pinning vertices to the selected joint" },
	AREA_TOOL { Key.W, false, false, COMMAND, &menu_weights_panel, false, "W", "area: pick exactly which part of the mesh the selected joint moves" },
	WEIGHT_BRUSH { Key.W, false, true, COMMAND, &menu_weight_brush, false, "Shift+W", "weight brush: correct the bind by hand — on the rest mesh or a parked pose" },
	SHARPEN { Key.RIGHT_BRACKET, false, false, COMMAND, &menu_sharpen_blend, false, "]", "sharpen every blend at once — the next key instead while posing a clip" },
	SOFTEN { Key.LEFT_BRACKET, false, false, COMMAND, &menu_soften_blend, false, "[", "soften every blend at once — the previous key instead while posing a clip" },
	AUTO_CONNECT { Key.A, false, false, COMMAND, &menu_auto_connect, false, "A", "auto-connect: chain each new joint to the last" },
	MIRROR { Key.M, false, false, COMMAND, null, false, "M", "symmetrize: line the other side up with the selection — never adds joints" },
	DELETE { Key.X, false, false, COMMAND, null, false, "X", "delete every selected joint — one undo takes them all back" },
	DELETE_KEY { Key.DELETE, false, false, COMMAND, null, false, "del / backspace", "the same" },
	CLEAR_SELECTION { Key.ESCAPE, false, false, COMMAND, null, false, "esc", "clear the selection" },
	SHOW_MESH { Key.B, false, false, COMMAND, &menu_show_mesh, false, "B", "show or hide the mesh" },
	SHOW_RIG { Key.S, false, false, COMMAND, &menu_show_rig, false, "S", "show or hide the skeleton" },
	WIREFRAME { Key.Z, false, false, COMMAND, &menu_wireframe, false, "Z", "wireframe" },
	FALLOFF { Key.F, false, false, COMMAND, null, false, "F", "weight falloff of the selected joint" },
	JOINT_PANEL { Key.N, false, false, COMMAND, &menu_show_joint_panel, false, "N", "show or hide the joint panel" },
	VIEW_FRONT { Key.KEY_1, false, false, COMMAND, null, false, "1", "look from the front" },
	VIEW_BACK { Key.KEY_1, true, false, COMMAND, null, false, "Ctrl+1", "look from the back" },
	VIEW_RIGHT { Key.KEY_3, false, false, COMMAND, null, false, "3", "look from the right" },
	VIEW_LEFT { Key.KEY_3, true, false, COMMAND, null, false, "Ctrl+3", "look from the left" },
	VIEW_TOP { Key.KEY_7, false, false, COMMAND, null, false, "7", "look from the top" },
	VIEW_BOTTOM { Key.KEY_7, true, false, COMMAND, null, false, "Ctrl+7", "look from the bottom" },
	MOVE_AXIS { Key.X, false, false, MOVING, null, false, "X / Y / Z", "confine the move to that axis" },
	MOVE_CANCEL { Key.ESCAPE, false, false, MOVING, null, false, "esc", "put the joint back where it was" },
	AREA_APPLY { Key.RETURN, false, false, WEIGHTS, null, false, "enter", "apply the part on show" },
	AREA_BACK { Key.ESCAPE, false, false, WEIGHTS, null, false, "esc", "drop the part, then close the tool" },
	BRUSH_CLOSE { Key.ESCAPE, false, false, BRUSHING, null, false, "Shift+W / esc", "close it; strokes are already on the ledger" },
	POSE_MOVE { Key.G, false, false, POSING, null, false, "G", "pose the selected joint — sweep the pointer, click to confirm" },
	POSE_TURN { Key.R, false, false, POSING, null, false, "R", "turn the selected joint — sweep the pointer around it, click to confirm" },
	POSE_AXIS { Key.X, false, false, POSING, null, false, "X / Y / Z", "lock a move to one axis, or turn about that axis" },
	POSE_CANCEL { Key.ESCAPE, false, false, POSING, null, false, "esc", "put the pose back where the gesture found it" },
	ANCHOR { Key.L, false, false, POSING, null, false, "L", "anchor the selected joints' position, so other moves bend around them" },
	ANCHOR_TURN { Key.L, false, true, POSING, null, false, "Shift+L", "anchor their rotation instead" },
	COPY_POSE { Key.C, true, false, POSING, null, false, "Ctrl+C", "copy the pose of the selected joints — all of them when none is selected" },
	PASTE_POSE { Key.V, true, false, POSING, null, false, "Ctrl+V", "paste that pose at the playhead, as keys — one undo takes it back" },
	PASTE_MIRRORED { Key.V, true, true, POSING, null, false, "Ctrl+Shift+V", "paste it mirrored: each joint onto its twin, reflected" },
	MIRROR_POSE { Key.M, false, true, POSING, null, false, "Shift+M", "mirror the selected joints' pose (all if none) on the keys Apply to reaches" },
	KEYS_CLEAR { Key.ESCAPE, false, false, SHEET, null, false, "esc", "let go of the selected keys — again clears the joint selection" },
	PLAY { Key.SPACE, false, false, SHEET, null, false, "space", "play or pause" },
	STEP { Key.LEFT_ARROW, false, false, SHEET, null, false, "left / right, or , / .", "step one frame back or forward; hold to keep going" },
	JUMP_KEY { Key.LEFT_BRACKET, false, false, SHEET, null, false, "[ / ]", "jump to the previous or next key" },
	ENDS { Key.HOME, false, false, SHEET, null, false, "home / end", "go to the first or last frame" },
	INTERPOLATION { Key.I, false, false, SHEET, null, false, "I", "set how the keys at the playhead ease" },
	KEY_POSE { Key.K, false, false, SHEET, null, false, "K", "key the pose at the playhead" },
	AUTO_KEY { Key.K, false, true, SHEET, null, false, "Shift+K", "turn Auto-key on or off" },
	PATH_FINISH { Key.RETURN, false, false, PATH, null, false, "enter", "finish the path being drawn" },
	PATH_CANCEL { Key.ESCAPE, false, false, PATH, null, false, "esc", "give up the path being drawn" },
	PATH_DELETE { Key.DELETE, false, false, PATH, null, false, "del / backspace", "delete the picked point or slice of a path" },
}

<*
 The plain command on this key. Shift alone doesn't change a letter that has no
 shifted row: shift+B is B.

 @return `NONE when no command has it.`
*>
fn Shortcut shortcut_of(Key key, bool ctrl, bool shift)
{
	Shortcut fallback = NONE;
	foreach (row : Shortcut::values)
	{
		if (!row.run || row.key != key || row.ctrl != ctrl) continue;
		if (row.shift == shift) return row;
		if (!row.shift) fallback = row;
	}
	return fallback;
}

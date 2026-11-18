# Editing

## Every edit undoes, redoes and saves exactly
- **Rule:** one undo puts the document and the authored clips back exactly. Redo gives the same result again. What an edit leaves survives the session file.
- **Why:** an edit that forgets a step has been the commonest way for a bug to come back through a new door.
- **Tests:** `test/rules/every_edit_test.c3`. It runs on the humanoid, so its rows use that rig's joint names. Held props (`set_prop`) and a pin held relative to another joint are rows too. With leak tracking on it takes about 70 seconds.

## Cutscene edits undo on the scene's own history
- **Rule:** a cutscene edit (the list, a cutscene's timing, strips or walk paths, an actor's row) is one step of the scene's cutscene history, a snapshot of every cutscene and every character's row; it never enters a character's history. Ctrl+Z and Edit › Undo take back whichever step came last, a cutscene's or the character's own; MCP `undo` and `redo` step the rig's history unless given `history: "cutscene"`. While a one-off is edited, its character's own clips, bindings and history are put aside: Ctrl+Z steps only the one-off's edits, Back to cutscene makes the whole edit one cutscene step, and any edit to the rig itself made meanwhile joins the character's own history.
- **Why:** cutscenes are the scene's, shared by its characters; steps in a character's history would be taken back, saved and replayed with that character, and lost when it is removed.
- **Tests:** `test/cutscene_app_test.c3`.

## A character read from the level is the level's
- **Rule:** a character read from the level file by its armature is read-only outside one-off editing. An edit that lands on it (its rig, clips, bindings or place) is taken back at once with a notice saying why, and an MCP tool that made one is refused; while a one-off is edited on it, only the one-off's own clip edits are kept. Saving it or exporting it as a model is refused.
- **Why:** the game takes that character and its clips out of the level file by the armature's name, and the level comes from another tool: an edit Rigsmith kept would be one the game never sees, and Rigsmith never writes the level or anything beside it.
- **Tests:** `test/level_actor_test.c3`.

## A new tool joins the sweep, or says why not
- **Rule:** every tool is a row in the sweep or has a named excuse.
- **Tests:** `every_tool_is_swept_or_excused`.

## A modal dialog keeps the keyboard
- **Rule:** while a modal dialog is open, every key stays with it; Esc closes it. Shortcuts don't reach the rig behind it. A non-modal dialog, such as Controls, leaves shortcuts working.
- **Why:** keys bubbled past a modal to the app's shortcuts, so G, Delete or Ctrl+Z acted on a rig the user couldn't see or reach.
- **Tests:** `test/rules/modal_keys_test.c3`.

## One refresh after a rig edit
- **Rule:** after a rig edit commits, `AppState.finish_rig_edit` marks the rig stale, drops selected ids that no longer exist, marks the plan's targets and refreshes.
- **Why:** seven callers each listed their own steps, and they differed.
- **Tests:** `test/rules/rig_edit_test.c3`.

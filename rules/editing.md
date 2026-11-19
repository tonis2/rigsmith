# Editing

## Every edit undoes, redoes and saves exactly
- **Rule:** one undo puts the document and the authored clips back exactly. Redo gives the same result again. What an edit leaves survives the session file.
- **Why:** an edit that forgets a step has been the commonest way for a bug to come back through a new door.
- **Tests:** `test/rules/every_edit_test.c3`. It runs on the humanoid, so its rows use that rig's joint names. Held props (`set_prop`) and a pin held relative to another joint are rows too. With leak tracking on it takes about 70 seconds.

## Cutscene edits undo on the scene's own history
- **Rule:** a cutscene edit (the list, a cutscene's timing, strips or walk paths, an actor's row) is one step of the scene's cutscene history, a snapshot of every cutscene and every character's row; it never enters a character's history. Ctrl+Z and Edit › Undo take back whichever step came last, a cutscene's or the character's own; MCP `undo` and `redo` step the rig's history unless given `history: "cutscene"`. While a one-off is edited, its character's own clips, bindings and history are put aside: Ctrl+Z steps only the one-off's edits, Back to cutscene makes the whole edit one cutscene step, and any edit to the rig itself made meanwhile joins the character's own history.
- **Why:** cutscenes are the scene's, shared by its characters; steps in a character's history would be taken back, saved and replayed with that character, and lost when it is removed.
- **Tests:** `test/cutscene_app_test.c3`.

## A walk's clip keeps its feet on the path
- **Rule:** a move the UI lays plays no clip; what plays while it walks is a play strip over it. A play pairs with the latest-begun move of its actor that has a path of two points or more and runs when the play starts; one that starts as the move ends does not, and a one-off never does. While its speed is not held and its clip's ground speed (typed on the play, else measured) is 0.1 m/s or more, it plays at (path length ÷ move length) ÷ that ground speed, set again whenever the move, its path or the play changes. A play that starts and ends with its move is tied to it: when the move is moved or trimmed at either end (dragged on the sheet, live and again as it lands; its card's Start or End; or cut back by another strip), the play takes the move's new start and end in the same undo step, keeping its clip offset so its cycle starts where the move does, and the lanes settle around it. A play over only part of its move keeps its own times. Typing a speed, or Alt-dragging the play's end on the sheet, holds it; the card's Fit lets it follow again. Walk here lays the move and a looping walk over it as one undo step, the move first. A move that carries a clip of its own is still read, drawn and exported, and its clip follows its own length. The problems list names a walk whose clip still travels or has no ground speed.
- **Why:** a clip played at its own rate over a path walked faster or slower slides its feet, and a walk that stops before its move slides the actor for the rest; with where and what apart, one path takes any clip.
- **Tests:** `test/algo/cutscene_walk_test.c3`, `test/algo/cutscene_problems_test.c3`, `test/cutscene_app_test.c3`, `test/ui/cutscene_walk_test.c3`, `test/ui/cutscene_sheet_test.c3`.

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

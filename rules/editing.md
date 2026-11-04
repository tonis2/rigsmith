# Editing

## Every edit undoes, redoes and saves exactly
- **Rule:** one undo puts the document and the authored clips back exactly. Redo gives the same result again. What an edit leaves survives the session file.
- **Why:** an edit that forgets a step has been the commonest way for a bug to come back through a new door.
- **Tests:** `test/rules/every_edit_test.c3`. It runs on the humanoid, so its rows use that rig's joint names. With leak tracking on it takes about 70 seconds.

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

# Clips

## One door to land a clip
- **Rule:** `land_clip` lands an edit to an existing clip. `author_clip` lands a new one. A library clip that's edited forks into the authored pack, in the rig's joint names, and its row moves with it, so there's one row and that row is the edit.
- **Why:** MCP edits used `author_clip`, which left a second row with the same name, and saving kept the first: the unedited library clip.
- **Tests:** `test/rules/clip_landing_test.c3`.

## A copy of a clip is in the rig's words
- **Rule:** `AppState.duplicate_clip` makes every copy, so a copy of a library clip keeps moving its joints.
- **Why:** the UI's Duplicate skipped the respelling, and those joints stopped moving.
- **Tests:** `a_copy_of_a_library_clip_keeps_moving_its_joints`.

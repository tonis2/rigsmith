# Posing

## What a grabbed joint keeps
- **Rule:** a limb joint keeps its angle to its parent, so a forearm turns with the upper arm. A foot keeps its world angle, so it stays flat. The root and spine keep their world angle. Alt swaps a limb's or foot's choice, and the Keep angle cell flips it per joint. A wrist is a limb joint.
- **Why:** `PoseHold` in `pose_mode.c3`. A hand follows its arm; a foot is planted.
- **Tests:** `pinning_test.c3`, `joint_panel_ui_test.c3`.
- **Tried and rejected:** this flipped three times between 25 and 28 October 2026: world angle for the wrist, then following the forearm, then a `WRIST` hold, then following again (`3ffd03e`, `162d515`, `a5a080d`). The reasons weren't recorded. The owner should confirm this rule before it gets a case table, because the cases it must answer are not written down anywhere.

## Posing never edits the rest rig
- **Rule:** a pose drag changes the pose only.
- **Why:** `003b533`.
- **Tests:** `pose_mode` tests in `ui_test.c3`.

## Pose stages run in one order
- **Rule:** sample, limits, ground, pins, aims. Neither pins nor aims feed back into a limit or the floor, and a head looks from where the body is held. Every reader of a pose gets the same result, except that export ignores solo layers on purpose.
- **Why:** pins were added to the player, export, bake and pose mode, then mirror lacked them, then position locks did (`f47281d`, `e04cc2d`, `162d515`).
- **Tests:** `test/rules/pose_readers_test.c3`. `PoseStages` (`src/algo/pose/pose_stages.c3`) is the only caller of the stage functions, and `tools/check_layers.sh` refuses any other.

## Renders show what plays
- **Rule:** studio pictures and training renders show pins and aims, matching the player.
- **Why:** the owner's decision (2026-11-04).
- **Tests:** `every_reader_sees_the_pose_that_plays`.

## A time lands in a clip by one rule
- **Rule:** a loop goes round again; a one-shot holds its ends, so the end of a one-shot has phase 1, not 0. Use `AnimTemplate.local_time` and `phase_at`.
- **Why:** renders wrapped a one-shot back to its start while the player and export held its end.
- **Tests:** `test/rules/clip_time_test.c3`.

## A foot is found by its shape
- **Rule:** a rig's feet are `ankle_L` and `ankle_R` when it has them, and otherwise what `gait_find_feet` finds.
- **Why:** Pin feet refused every rig spelt another way.
- **Tests:** `test/rules/feet_test.c3`.

## Limits are read one way
- **Rule:** one clamp, `doc_clamp`, holds a turn inside the document's limits for aims, pins, gaits and bakes.
- **Why:** three copies of the same steps.

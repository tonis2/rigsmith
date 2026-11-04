# Known bugs

Found by the code audit of 2026-11-04. Delete each entry when it's fixed, and this file when it's empty.

"Read" means both sides of the code were read. "Not run" means the failure was reasoned, not reproduced.

## Posing
- `patch.c3:466` reads raw rotation with no layers or limits. It may be right for a patch, which edits keys. Unconfirmed.
- `gesture_pose` in `pose_mode.c3` lays the floor and aims but not pins, while a drag solves its own pins. It may be deliberate. Unconfirmed.
- `bake_keyframe` (`bake.c3:391`) solves pins and aims without the floor. Likely misplaces pinned limbs. Not run.
- Viewport clamps a joint with a saved frame and unusable base; export leaves it free (`constraint_rig.c3:363`). Needs a decision.
- `derived_contacts` samples grounded with no limits; `contact_runs` samples limited and ungrounded. Whether that should change is unconfirmed; changing it moves detected contacts.
- `foot_ids` (`locks.c3`) still reads only `ankle_L` and `ankle_R`. Only tests reach it.
- Stdlib `slerp` falls back to lerp near identity, unlike `curve_slerp`, so viewport and glTF readers differ slightly. Read.

## Decisions for the owner
- Key reduction measures angles with `acos`, whose float rounding keeps keys an exact angle would drop. Using `angle_between_turns` cut the humanoid's imported Walk_slow from 6,435 joint keys to 2,099. The worst pose change across three clips was 1.6 mm at a fingertip and 0.16°. Smaller clips, but fewer keys to edit, so it stays as it was until decided.

## Weights
- `lasso_mirror` and `limb_mask` lost their tests in `9fdd74a` and have no direct test now.
- `normalise_rows`, `top_row`, `strongest_shares` and `guide.c3:110` keep the strongest shares by different rules. Whether all the differences are intended isn't known.

## Clips
- `between_poses` (`render_poses.c3:506`) keeps `from`'s offsets; `rig::blend_poses` lerps them. Read.

## Files
- `config.c3:932` ignores write errors and `pipeline_graph.c3:531` discards the result. `write_glb` (`patch.c3:863`) saves over the model directly. Read.
- Scene path in `export.c3` lacks the `joints > 0` guard and hard-codes 4 influences. Read.
- Only 2 of 7 JSON number readers reject non-finite values. Read.
- `capture.c3:211,626,979` don't handle `\` in paths. Read.

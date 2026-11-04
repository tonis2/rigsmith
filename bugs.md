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

## Weights
- `lasso_mirror` and `limb_mask` lost their tests in `9fdd74a` and have no direct test now.
- `normalise_rows`, `top_row`, `strongest_shares` and `guide.c3:110` keep the strongest shares by different rules. Whether all the differences are intended isn't known.

## Clips
- MCP patch and layer edits on a library clip (`mcp/patch.c3:358`, `mcp/layers.c3:374,638`) use `author_clip`, which adds a second row with the same name. `model_clips` keeps the first row, so saving would keep the unpatched original. Read, not run.
- `author_clip` overwrites an unrelated authored clip on a name clash; `land_clip` makes the name unique. Read.
- MCP `merge_layers` in place never respells the clip. Read.
- UI bake (`physics_panel.c3:1029`) uses `put_authored_clip`, leaving the clip unbound. Read.
- UI Duplicate (`animation_actions.c3:527`) passes `NO_ANIM`, so a library clip keeps library names and those joints stop moving, and even an authored clip gets the "now uses a copy" notice. Read.
- MCP edits don't redisplay a clip that isn't playing; `show_edited` is UI only. Read.
- `get_clip` then `parse_clip` loses tangents and gait. A ground with `floor_set` and no feet survives only in the session writer. Read.
- `between_poses` (`render_poses.c3:506`) keeps `from`'s offsets; `rig::blend_poses` lerps them. Read.

## Rig edits
- Plan fit and import call `clear_rig_recorded`, which owes `forget_stale_ids`, and neither calls it. Read.

## Files
- `config.c3:932` ignores write errors and `pipeline_graph.c3:531` discards the result. `write_glb` (`patch.c3:863`) saves over the model directly. Read.
- Scene path in `export.c3` lacks the `joints > 0` guard and hard-codes 4 influences. Read.
- Only 2 of 7 JSON number readers reject non-finite values. Read.
- `capture.c3:211,626,979` don't handle `\` in paths. Read.

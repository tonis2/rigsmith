# Known bugs

Found by the code audit of 2026-11-04. Delete each entry when it's fixed, and this file when it's empty.

"Read" means both sides of the code were read. "Not run" means the failure was reasoned, not reproduced.

## Posing
- `aim_edit.c3:532` says "as it is shown" but leaves out pins, as does `pose_mode.c3:307`. MCP's `aim_forward_at` includes them, so UI and MCP aim setup read different poses. Read.
- `exam_pose` and the studio (`render_poses.c3:491`, `render_studio.c3:565`) skip pins and aims. Read.
- `tool_save_pose` (`mcp/poses.c3:125`) saves limits only; the UI save includes holds. Read.
- `targets.c3:150` reads raw keys with no limits; `patch.c3:466` reads raw rotation with no layers or limits. Read.
- `clip_aims_flattened` (`aim.c3:917`) has no limit stage before ground. Read.
- `bake_keyframe` (`bake.c3:391`) solves pins and aims without the floor. Likely misplaces pinned limbs. Not run.
- `played_pose` claims "as it plays and as it exports", which disagree on solo layers. Read.
- `render_poses.c3:490,553` and `render_studio.c3:564` wrap time even when the clip doesn't loop. Read.
- `phase_at` returns 1 at a one-shot's end; `phase_wrapped`, `wrapped` and `wrapped_phase` don't. Read.
- Viewport clamps a joint with a saved frame and unusable base; export leaves it free (`constraint_rig.c3:363`). Needs a decision.
- What counts as a foot differs: `locks.c3:309` and `mcp/pins.c3:546` use hard-coded names, and height bands are 12% and a fifth of rig height. `derived_contacts` samples grounded with no limits; `contact_runs` samples limited, ungrounded. Read.
- Rotation helpers differ: `curve_cleanup.c3:140` has no `w<0` flip and is half length; `acos` loses small angles where `atan2` doesn't; stdlib `slerp` falls back to lerp near identity, unlike `curve_slerp`. Read.

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

## Names
- `gait_twin_name`, `side_sign` and `plans.c3:242` only read suffixes, so `armature:LeftFoot` has a twin under `mirror_name` and none under them. `side_sign` feeds `rig_facing`. Read.

## Rig edits
- Plan fit and import call `clear_rig_recorded`, which owes `forget_stale_ids`, and neither calls it. Read.

## Files
- `config.c3:932` ignores write errors and `pipeline_graph.c3:531` discards the result. `write_glb` (`patch.c3:863`) saves over the model directly. Read.
- Scene path in `export.c3` lacks the `joints > 0` guard and hard-codes 4 influences. Read.
- Only 2 of 7 JSON number readers reject non-finite values. Read.
- `capture.c3:211,626,979` don't handle `\` in paths. Read.

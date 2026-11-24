# Files

## A save lands whole or not at all
- **Rule:** files are written through `save_safely`, a temporary file beside the target, renamed over it. A failed save leaves the old file as it was.
- **Why:** the model file was saved over directly, so a full disk could destroy it. The config and pipeline files had the same risk.
- **Tests:** `test/algo/save_safely_test.c3`.

## One session version is read
- **Rule:** a session is read only at `SESSION_VERSION`. An older one is refused and the model opens on its own rig. Bumping the version is a deliberate break; adding a key does not bump it, and an absent key reads as its default.
- **Why:** the app is early and old files don't matter yet. Migrations kept every old format alive in the reader, and a bump per key would refuse every session on the next new key.
- **Tests:** `an_older_session_is_refused` in `test/ui/session_and_occlusion_test.c3`, `an_old_sidecar_leaves_the_models_own_rig` in `test/weight_field_test.c3`.

## Every run leaves a log
- **Rule:** Rigsmith runs under a watcher process. The watcher copies all output to the terminal and, time-stamped, to `<config dir>/logs/rigsmith.log`, then writes how the run ended. The last 5 runs are kept. Tool calls are noted in the log only. After a crash, the next start says so and names the log. `--mcp-stdio` and `RIGSMITH_NO_LOG=1` run without it.
- **Why:** a crash during an MCP batch left nothing: the C3 runtime's backtrace went to a terminal, and a SIGKILL prints nothing at all. Only a second process can record those.
- **Tests:** `test/run_log_test.c3`.

## A scene's level is a backdrop
- **Rule:** a scene file names its level as `level`, relative to the scene where the characters' paths are, absolute otherwise; no key means no level. Opening the scene opens the level again, and a level file that has gone is a notice, not a refused scene. Rigsmith never saves, edits or undoes the level, and the ground under a point is its colliders only.
- **Why:** cutscenes are made in the level the game plays them in, and the level comes from another tool.
- **Tests:** `test/level_test.c3`.

## An imported .glb is a character, a level or refused
- **Rule:** File › Import .glb and a model's + on the Models shelf read only the file's JSON (a `.glb`'s JSON chunk, not its buffer) and decide. A root `CUSTOM_cutscene` extension is a cutscene file: it is refused with a notice. A `KHR_physics_rigid_bodies` collider or trigger on a node that is neither a skin joint nor below one, or two or more named nodes with a skinned mesh under them, is a level: it opens behind the scene, replacing the open one, and the notice names what it replaced. Anything else is a character, and so is a file whose JSON does not read, whose load then says why. A file is a `.glb` or `.gltf` by its extension in any case, wherever a path is typed or a folder is read. MCP `add_character` refuses a level and a cutscene file; `open_level` opens any file as the level without asking.
- **Why:** characters, levels and cutscenes are all `.glb`, so one Import is enough. Rigsmith writes its own colliders on a rig's joints, so a character with physics is still a character.
- **Tests:** `test/algo/glb_kind_test.c3`, the import checks in `test/level_test.c3`.

## A scene's cutscenes and actors
- **Rule:** the scene file holds the scene's cutscenes as `cutscenes` (each one the cutscene file's fields, with a move's `path` an index into its own paths, a play's typed `ground_speed` and `speed_held` and a move's typed `ground_speed` for a clip of its own, none of them in the `.cutscene.glb`, and each path's `knots`; the points are sampled from the knots on reading, and dropped onto the level's ground again when the level is in), the picked one as `cutscene`, and on each character that is an actor its `row`, the `level_node` it stands in for, the `scale` it is drawn at and the `lift` of that node's origin over its feet. Absent keys read as defaults; the version does not change. An actor's home is where its character stands; a position in a cutscene is where its feet stand, and the export lifts a level node's walks by its `lift`. A cutscene's `one_offs` are `{row, clip}`, the clip in the session file's clip form, and a strip with `one_off` plays its actor's one-off by name; a one-off is never written into its character's `.glb` or sidecar, and the export writes it as an animation in the joint frames of the file the game plays it on. When the level comes in, each actor standing in for a level node reads that node's place, facing, scale, lift and rig again. An actor read from the level file itself has no `model`: its `level_node` finds it again, and when the level comes in its rig and clips are read again from the level by that armature; a node that is gone is a problem line. Nothing of it is ever written, beside the level or anywhere else.
- **Why:** the scene is the project; the `.cutscene.glb` is only what the game plays.
- **Tests:** `test/cutscene_app_test.c3`, `test/level_actor_test.c3`.

## A save under a name copies the model
- **Rule:** `save_project {path}` copies the opened model to the path, a .glb or .gltf, writes the rig into the copy with its sidecar beside it naming it, and the project follows the copy. It never writes over the model that was opened unless Rigsmith made that model, and it never replaces another file without `overwrite`. `open {path}` replaces the scene with the model, and is refused while any character has unsaved changes unless `discard_unsaved` says to let them go.
- **Why:** saving the goblin wrote `goblin_copy.glb` and a sidecar naming it, and renaming the pair meant editing the sidecar by hand. Reopening a file changed outside Rigsmith took four calls: add a second model, remove the first, add it back, remove the second.
- **Tests:** `test/save_as_test.c3`.

## Changing the libraries redraws the Assets pane
- **Rule:** adding or removing a library folder rescans it at once, and `rescan_assets` rebuilds every Assets pane before it is drawn again: the library chooser and the sidebar borrow what the rescan frees.
- **Why:** adding a folder in the settings with the Assets pane up crashed: the chooser drew labels the rescan had freed.
- **Tests:** `changing_the_libraries_rebuilds_the_assets_pane` in `test/ui/workspace_areas_test.c3`.

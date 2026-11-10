# Capture

## Train says what it is doing
- **Rule:** before a run, the Train finder node says how many pictures it will use and about how long it takes. During a run it names the stage out of five, and the time left covers the whole run. The plugin's own lines reach the status only through the stage they belong to.
- **Why:** the node showed the plugin's raw counters, which changed from poses to pictures to batches. 1000 poses at 768 px looked finished after about 2 of 41 minutes (2026-11-06).
- **Tests:** `test/capture_test.c3`: `a_run_says_how_many_pictures_fit`, `a_run_says_how_long_it_takes`, `the_node_says_what_a_run_will_do`, `each_step_line_lands_in_its_stage`, `a_training_says_its_stage_and_the_whole_runs_time`, `a_slower_machine_corrects_the_time_left`.

## A run trains on the poses asked for
- **Rule:** a run uses no more pictures than its Poses setting draws, even if the folder holds more from an earlier run. Rigsmith sends the plugin the limit, the memory cap and the feature width, so the node's count is the plugin's.
- **Why:** the plugin reads every chunk in the folder, so lowering Poses from 1500 to 500 still trained on all 1500.
- **Tests:** `test/capture_test.c3`: `the_train_task_is_valid_json_with_its_paths`.

## A finder is trained once
- **Rule:** a run trains the body once.
- **Why:** a second training on half the poses took about 4 minutes of every run. Its weights were thrown away, and all it gave was one figure.
- **Tests:** `test/capture_test.c3`: `the_train_task_is_valid_json_with_its_paths`.

## A video is read mirrored unless turned off
- **Rule:** an Animate node reads each frame mirrored as well, for a video and for a picture, until its Mirror check is turned off. MCP `capture` has the same default.
- **Why:** with it off, a 5 second run lost 2 of its 12 steps. The two views read the legs opposite ways, the fit landed between them, and the legs hung near the middle while the video's feet were wide apart. The same run with it on took all 12, for 205 s against 134 s (2026-11-06).
- **Tests:** `test/capture_test.c3`: `an_animate_node_starts_with_the_mirror_check_on`. `test/ui/workspace_areas_test.c3`: `the_nodes_pane_is_open_and_keeps_what_is_typed`.

## A view that slips is put back in step
- **Rule:** when one half of a studio video jumps back partway through and stays behind, its repeated frames are cut and both views end that much sooner. The notice says so, because the clip comes out shorter than its video. Views in step are not touched.
- **Why:** `nero_walk.mp4`'s three-quarter half jumped back 14 frames at 2.2 s. From there the halves showed different moments, and the only pose fitting both had the legs crossed, for half the clip, with the Mirror check on (2026-11-06).
- **Tests:** `test/capture_test.c3`: `the_animate_notice_says_when_a_view_slipped`. In llm-runner, `llm/tests/creature_sync.js`.

## A run keeps what it read
- **Rule:** an Animate run asks for its tracks and a sheet of nine frames with the fit and every read drawn on them. It writes `tracks.json`, `reads.png` and `report.json` into `runs/<clip>/` beside its reference. The plugin's lines go to the run log. The notice names the joints whose sure reads the fit left behind, and MCP `capture` `reads` gives the last run's files.
- **Why:** a spider's clip lifted two legs on one side where the video lifted both front legs, and nothing was left to show which reads were wrong (2026-11-10).
- **Tests:** `test/capture_test.c3`: `the_animate_task_asks_for_the_clip_and_what_it_read`, `a_run_keeps_what_it_read_beside_its_reference`, `the_animate_notice_names_the_joints_read_off_the_fit`. `test/mcp/render_and_set_camera_test.c3`: `capture_reads_gives_the_last_runs_files`. In llm-runner, `llm/tests/creature_reads.js`.

## A video starts on its reference
- **Rule:** an Animate run of a video tells the plugin its first frame is the reference picture, so frame 0's joints are taken from `studio.json`. A picture into Animate is that pose changed, and does not.
- **Why:** the fit started every clip from rest and found frame 0 like any other, though the picture's pose is known exactly (2026-11-10).
- **Tests:** `test/capture_test.c3`: `the_animate_task_asks_for_the_clip_and_what_it_read`. In llm-runner, `llm/tests/creature_start.js`.

## Limbs are followed from the reference
- **Rule:** in a video that starts on its reference, the plugin follows the picture's joints through the frames and holds each limb joint's reads against where it was followed to. A read on a leg that another joint was followed to is dropped.
- **Why:** on `spider_scary.mp4` the finder named the lifted right front leg's joints on the planted leg beside it, in both views, so the clip left that leg down and lifted a mid leg. About one limb read in six had its first peak on another limb. Followed, both front legs rise and the mid legs stay down (2026-11-10).
- **Cost:** the run took 366 s against 200 s.
- **Tests:** in llm-runner, `llm/tests/creature_follow.js`.

## A capture's clip lands on its own joints
- **Rule:** a clip that comes back on the rig it was sent reaches every joint under its own name, also on a rig with many legs of one shape.
- **Why:** the clip is landed by matching shapes, and eight alike legs were the suspect when a spider's clip moved the wrong legs. The match held (2026-11-10).
- **Tests:** `test/algo/reach_by_name_test.c3`: `a_clip_on_this_rig_reaches_every_joint_by_its_name`.

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

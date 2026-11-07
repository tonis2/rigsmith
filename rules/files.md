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

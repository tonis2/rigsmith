# Files

## A save lands whole or not at all
- **Rule:** files are written through `save_safely`, a temporary file beside the target, renamed over it. A failed save leaves the old file as it was.
- **Why:** the model file was saved over directly, so a full disk could destroy it. The config and pipeline files had the same risk.
- **Tests:** `test/algo/save_safely_test.c3`.

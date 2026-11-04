# Rigging

## Left and right are read one way
- **Rule:** `name_side` and `mirror_name` read a joint's side. A side letter is its own word (`thigh_L`, `L_Upperarm`), and a written side can sit anywhere (`armature:LeftFoot`).
- **Why:** gaits and the rig-facing check read suffixes only, so prefixed names had a twin in one place and none in another.
- **Tests:** `test/algo/side_names_test.c3`.

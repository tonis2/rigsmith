# Rigging

## Left and right are read one way
- **Rule:** `name_side` and `mirror_name` read a joint's side. A side letter is its own word (`thigh_L`, `L_Upperarm`), and a written side can sit anywhere (`armature:LeftFoot`).
- **Why:** gaits and the rig-facing check read suffixes only, so prefixed names had a twin in one place and none in another.
- **Tests:** `test/algo/side_names_test.c3`.

## A clip follows a joint's new name
- **Rule:** renaming a joint respells every authored clip that names it, and one undo takes both back.
- **Why:** authored clips address joints by name, so a rename silently stopped the clip moving that joint.
- **Tests:** `renaming_a_joint_keeps_its_keys`, and a row in the every-edit sweep.

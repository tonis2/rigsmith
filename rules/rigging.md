# Rigging

## Left and right are read one way
- **Rule:** `name_side` and `mirror_name` read a joint's side. A side letter is its own word (`thigh_L`, `L_Upperarm`), and a written side can sit anywhere (`armature:LeftFoot`).
- **Why:** gaits and the rig-facing check read suffixes only, so prefixed names had a twin in one place and none in another.
- **Tests:** `test/algo/side_names_test.c3`.

## A clip follows a joint's new name
- **Rule:** renaming a joint respells every authored clip that names it, and one undo takes both back.
- **Why:** authored clips address joints by name, so a rename silently stopped the clip moving that joint.
- **Tests:** `renaming_a_joint_keeps_its_keys`, and a row in the every-edit sweep.

## A turned model plays the same, turned
- **Rule:** Turn model turns the model about +Y by whole quarter turns as one undo step: the mesh and its normals, the joints, the limit tables' frames, held props, saved poses, and every authored clip's keys, layers, aims, pins and paths. Every joint of an authored clip then plays where the turn carries it from where it played before. Undo gives back the same bits. Save writes the turned positions and normals into the model and drops its tangents. Clips from a library pack or the model's file are not turned: they are written for a figure facing +Z.
- **Why:** generators hand back figures facing +X, the body plans fit +Z or -Z, and a turn made outside Rigsmith had to be redone by hand on every file. A derived limit frame takes its roll from the world axes, so a turn that left it derived played every knee and hip clamped wrong.
- **Tests:** `test/turn_model_test.c3`, and a row in the every-edit sweep.

## A plan fits only a figure facing +Z or -Z
- **Rule:** `apply_plan` with facing auto refuses a mesh whose feet point along X (`feet_heading`), and names `turn_model` as the fix.
- **Why:** on a goblin facing +X the biped plan fitted across the body, 40 joints outside the mesh, and the answer still said applied.
- **Tests:** `test/turn_model_test.c3`.

## The rig's answers say how it sits on the mesh
- **Rule:** `apply_plan` answers with its fit: the facing, the joints left off the mesh (`dots_off_mesh`: outside it and more than a voxel from its surface), and a verdict of fits, some_outside or poor. A quarter of the joints off is poor. `get_scene`'s `rig_issues` lists every joint off the mesh as `outside_mesh`. `edit_rig` lists each dot its snap or a chain's centring moved and by how much, and after a move it lists the limit tables the moves left pointing off their bones, owed a `plan_limits`.
- **Why:** on a chibi goblin the biped left 40 joints outside the mesh, the hands at the ear tips, while `apply_plan` answered applied and `rig_issues` stayed empty. Later a snap moved the hips 2 cm unannounced, and 23 tables went stale without a word.
- **Tests:** `test/fit_report_test.c3`.

## A chain lays a finger in one op
- **Rule:** `edit_rig`'s `chain` lays 1 to 16 dots from a base (a joint it hangs from, or a point) to a tip, each hung off the one before. The last dot sits exactly at the tip, and every other dot goes to the middle of the limb's cross-section square to the run (`section_centre_near`), the smaller loop where two hold it.
- **Why:** the goblin's thumb and three fingers were read off close-up renders pixel by pixel, a joint at a time.
- **Tests:** `a_chain_lays_a_run_of_dots_down_the_limb` in `test/fit_report_test.c3`, `test/algo/sections_test.c3`.

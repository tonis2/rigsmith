# Weights

## An edit to one joint never changes another
- **Rule:** a joint follows the automatic bind until it is edited. Then it holds its own column. No tool rescales or re-derives another joint's weights.
- **Why:** predictability. In the owner's words (2026-10-23): "I don't like rigsmith forcing its automatic changes once I try to edit certain joints".
- **Tests:** `an_edit_to_one_joint_never_changes_another` in `test/rules/weight_rules_test.c3`; `held_weights_test.c3`.
- **Tried and rejected:** handing weight to neighbours when a joint is taken off (`others_of`, `field_row`, `restate_share`). Keeping every vertex owned. Make rigid and Smooth weights wrote several columns and were deleted on 2026-10-26.

## Rows need not sum to 1
- **Rule:** a row summing to about 0 is an unused vertex (`UNUSED_TOTAL`), shown by the Unused overlay. Nothing fills it in.
- **Why:** follows from the rule above; filling it would move another joint.
- **Tests:** `unused_weights_test.c3`.

## Removing the last joint leaves a vertex truly unused
- **Rule:** a brush Remove on a vertex nobody else holds takes the joint off all the way, in one pass.
- **Why:** a soft stroke left crumbs (1e-5) that still counted as 100% share: the recurring "can't remove thumb from palm" bug. Given the choice of handing the weight on or leaving it unused, the owner chose unused (2026-10-26).
- **Tests:** `weights_test.c3`.
- **Tried and rejected:** handing the weight to the surrounding joint or the parent.

## Every weight write goes through `replace_column`
- **Rule:** one write primitive. `store_column` is the documented exception, for importing a file's weights.
- **Why:** the guards live there. Reading goes through one funnel too, `AppState.weights`.
- **Tests:** `every_reader_counts_the_same_owners`.

## Seam copies keep one weight
- **Rule:** vertices stored twice for UVs or hard edges always take the same weight. `join_column` runs inside `replace_column`, and only writes the column being written.
- **Why:** on nero_3d the run clip opened holes at the neck, collar and hood, and painting one area tore another (2026-10-28). 93 seam pairs had different weights, all from hand edits.
- **Tests:** `copies_of_a_point_keep_one_weight`; tears tests in `weights_test.c3`.

## The tear fix repairs seams only
- **Rule:** it covers seam copies. Each copy takes the row the edits moved furthest from automatic, so the painted side wins.
- **Why:** seams alone (106 vertices) closed every visible hole in the run.
- **Tried and rejected:** automatic layer repair. A cluster copy, a directional copy and a distance blend changed 600 to 1,400 vertices, and broke a belt strap, created spine strays, or never reached zero tears. Don't bring it back without a before and after on a scratch copy.

## Tears close before strays
- **Rule:** Fix weights closes tears first, then fixes strays, as one undo step. Paint a tear hands to a point far from the rest of its joint is a stray, so the same click takes it off.
- **Why:** the stray survey reads one copy of a point, so a stray on the other copy only shows once the copies agree.
- **Tests:** `a_stray_on_a_torn_point_goes_from_both_copies`, `one_fix_closes_tears_and_strays_in_one_undo` in `weights_test.c3`.

## A stray fix never empties a vertex
- **Rule:** a stray's joint stays on a vertex the rest of its row holds less than `STRAY_REST_FLOOR` of. The vertex stays listed. When Fix weights leaves anything, it turns on Weight preview, because the red only paints over a weight view.
- **Why:** on steiner one click left 17 torso vertices with nothing or a crumb, so they rode the root or a shoulder at full share and made a new spike (2026-11-06). The card said "marked red" over a textured mesh with no red on it.
- **Tests:** `a_stray_keeps_its_joint_where_nothing_else_holds_the_vertex`, `two_strays_on_a_vertex_leave_one_joint_on_it`, `what_fix_weights_leaves_shows_on_the_mesh` in `weights_test.c3`.

## Paint carries only downward
- **Rule:** a layer partner takes the painted value only when automatic rows agree and it lies under the painted surface or back to back with it. Paint never carries up onto a covering layer, or sideways.
- **Why:** paint carried onto a hidden layer must not appear as a stray; paint on a covering layer would show.

## One view of the weights
- **Rule:** weight views always draw the edited weights, plainly.
- **Why:** the owner couldn't tell which weights were active.
- **Tried and rejected:** the Compare toggle and the blue hand-edit cast, both removed 2026-10-22.

## Offer one button that finds and fixes, not a readout
- **Rule:** for a defect the user can't fix by hand, add one action that finds it and fixes it, one undo step. What it can't fix stays marked.
- **Why:** the owner called an "Under the cursor" readout useless: hovering never lands on the bad vertex, and it showed a blend they still couldn't fix (2026-10-21). Separate find and fix buttons for strays and tears then cost up to four clicks, and the owner chose one button with no preview (2026-11-06).
- **Tried and rejected:** the cursor readout. Separate find and fix buttons.

## One weight tool at a time
- **Rule:** brush, area and lasso never overlap, and whichever is open owns a press on the mesh, whatever transform tool was left on. Read it through `AppState.weight_tool`.
- **Why:** each mode had this fixed separately (`bcbb7a2`, `25975bf`, `00a32ef`): grow, island click and lasso drag quietly orbited.
- **Tests:** `one_weight_mode_at_a_time`.

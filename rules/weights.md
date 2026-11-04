# Weights

## An edit to one joint never changes another
- **Rule:** a joint follows the automatic bind until it is edited. Then it holds its own column. No tool rescales or re-derives another joint's weights.
- **Why:** predictability. In the owner's words (2026-10-23): "I don't like rigsmith forcing its automatic changes once I try to edit certain joints".
- **Tests:** `test/rules/` (to be written); `held_weights_test.c3`.
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
- **Tests:** tears tests in `weights_test.c3`.

## Fix tears repairs seams only
- **Rule:** Find and Fix tears cover seam copies. Each copy takes the row the edits moved furthest from automatic, so the painted side wins.
- **Why:** seams alone (106 vertices) closed every visible hole in the run.
- **Tried and rejected:** automatic layer repair. A cluster copy, a directional copy and a distance blend changed 600 to 1,400 vertices, and broke a belt strap, created spine strays, or never reached zero tears. Don't bring it back without a before and after on a scratch copy.

## Paint carries only downward
- **Rule:** a layer partner takes the painted value only when automatic rows agree and it lies under the painted surface or back to back with it. Paint never carries up onto a covering layer, or sideways.
- **Why:** paint carried onto a hidden layer must not appear as a stray; paint on a covering layer would show.

## One view of the weights
- **Rule:** weight views always draw the edited weights, plainly.
- **Why:** the owner couldn't tell which weights were active.
- **Tried and rejected:** the Compare toggle and the blue hand-edit cast, both removed 2026-10-22.

## Offer a find button and a fix button, not a readout
- **Rule:** for a defect the user can't fix by hand, add one action that finds it and one that fixes it, one undo step.
- **Why:** the owner called an "Under the cursor" readout useless: hovering never lands on the bad vertex, and it showed a blend they still couldn't fix (2026-10-21).
- **Tried and rejected:** the cursor readout.

# Shortcuts

## One table
- **Rule:** every key is one row of `Shortcut` in `src/ui/shortcuts.c3`. The key stages, the Controls dialog and the menus read it. A plain command runs from its row; a key that depends on the state is read by a stage in `src/ui/app_keys.c3` and still has a row.
- **Why:** keys were listed by hand in four places, and they disagreed.
- **Tests:** `test/ui/shortcuts_test.c3`.

## What has the keyboard
- **Rule:** a gesture in hand owns its keys before any mode is asked, in the order of `KEY_STAGES`. A keyboard move takes every key. A joint in hand takes X, Y, Z, B and Esc, and only those; Ctrl+Z still reaches undo. Ctrl keeps a chord away from the letters.
- **Why:** with a dot in hand X means lock to X, not delete it.
- **Tests:** `test/ui/key_order_test.c3`.

## A key is let go when the window loses the keyboard
- **Rule:** when Rigsmith loses the keyboard, every held key reads as released, with a normal key-up. A held mouse button stays held. Every backend in the window library does this, through `EventMap.release_keys`.
- **Why:** no release arrives after focus leaves, so Alt+Tab left Alt down. Every drag then swapped Keep angle while the cell stayed lit, until a restart (2026-11-06).
- **Tests:** `a_key_held_as_the_keyboard_leaves_is_let_go` (Wayland), `a_key_held_as_x11_focus_goes_is_let_go`. Windows and macOS have no test and haven't been run.

## Esc backs out one layer at a time
- **Rule:** the mode first, then picked keys, then the joint selection. Leaving a mode doesn't lose your place.
- **Tests:** `esc_backs_out_a_layer_at_a_time`.

## R is the turn
- **Rule:** plain R turns, and means that in every state. Set root is Ctrl+R, and is refused while editing animation.
- **Why:** re-rooting re-parents every joint, and a pose is parent-relative rotations, so it would reinterpret every one of them.
- **Tried and rejected:** set root on plain R; a rename panel on R, which opened a second panel over the Joint card.
- **Tests:** `r_turns_an_animation_and_ctrl_r_roots_the_rest_rig`.

## Three clipboards, told apart by focus
- **Rule:** a text field takes Ctrl+C and Ctrl+V first, then the dopesheet for saved keys, then the window for the pose. Each returns before the next, so none needs to know about the others. With no pose to copy the chord is left unclaimed, not refused.

## A shifted letter is the sibling job
- **Rule:** plain M mirrors the rest dots and Shift+M the pose. W and T work the same way: plain reads the rig, shifted writes the bind. Which one a key does never depends on a state nothing on screen names.
- **Tried and rejected:** M taking the pose's meaning whenever a clip was open to posing.

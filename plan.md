# Animation by direct manipulation — remaining work

Follow-ups to the Layers sheet / motion paths / gait-as-paths work (2026-10-23).
Phases 0–5 and phase 6 item 5 (paths that turn the joint, `AnimPath.follow`) are
done. What is left is below, in the order I would do it.

Ground rules for each item: cui widgets only, one undo step per gesture (land
through `land_clip` / `put_authored_clip`), tests on `assets/*.glb` only,
`c3c test --test-noleak` while working, full `c3c test` and 0 build warnings at
the end, one Rigsmith test instance at a time on a scratch copy.

---

## 1. Trim and Stretch by dragging the clip's end

**Now:** Clip tools › "Trim…" (`src/ui/animation_trim.c3`) and "Stretch timing…"
(`src/ui/animation_retime.c3`) are dialogs with typed seconds.

**Instead:** the end of the clip is a handle on the timeline ruler, in every sheet
mode (Keys, Curves, Layers).

- **Drag the end marker** left to trim: the part after it greys out as you drag
  and is cut on release. Drag right to lengthen: the new time is empty, the last
  pose held.
- **Alt-drag** stretches: every key, slice, pin, strip and ground window scales
  with it (`clip_with_frames` retime, which already carries paths, layers' offset
  and speed, and pins). A readout over the handle shows the new length and the
  percentage, e.g. `1.20 s · 150%`.
- **Ctrl-drag the start marker** trims the front, rebasing the clip to 0
  (the existing crop path, as the Trim dialog's Keep range does).
- **Shift-drag across the ruler** selects a range. The ruler's right-click menu
  then offers Keep range, Cut range and Stretch range, which replace the dialog's
  two buttons.
- The playhead follows as it does today: rebased for a crop, moved up for a cut.
- Snaps to frames. With a gait or a looping clip, snaps to whole cycles while
  stretching, so the loop still closes.
- Typed values stay possible: double-click the end marker for a small inline
  field with the duration.

**Code:**
- `Timeline` ruler (`src/ui/dopesheet.c3`): an end grip and a start grip, drawn in
  the ruler, picked before keys.
- New `src/app/clip_length.c3`: `begin_length_drag`, `length_drag_to`,
  `end_length_drag`, `cancel_length_drag` (Esc). A draft clip plays while
  dragging, as `path_draft` does.
- Remove the Trim and Stretch dialogs and their menu items once the gestures
  cover them. Keep the MCP tools as they are.

**Tests:** drag the end to trim (keys after it gone, one undo step), drag past the
end to lengthen, Alt-drag to stretch (key times scaled, a path's slices and a
strip's offset scaled with them), Ctrl-drag the start to crop, Esc gives the drag
back, a stretch on a looping gait snaps to the cycle.

---

## 2. 3D handles for Wave / Noise / Pulse layers

**Now:** a generator layer is set up in the Layers column with dropdowns: Joint,
Tip ("follow the chain"), an X/Y/Z axis switch, and Amplitude / Cycles / Lag /
Falloff / Phase sliders (`src/ui/layer_strip.c3`, around line 440).

**Instead:** with a generator strip selected, the viewport shows its chain and
handles, as the Path tool shows a path.

- **The chain:** the joints it moves are drawn highlighted, root to tip.
  - Click a joint to make it the root; Shift-click to make it the tip. The
    status line says which is next.
- **Amplitude and axis:** an arc at the tip shows how far it swings, with a
  grip at each end.
  - Drag the grip to change the amplitude.
  - The arc's plane is the axis: drag the ring around the tip to tilt it. It
    snaps to X / Y / Z, with Ctrl for a free axis, which needs a `Vec3` axis on
    `AnimLayer` in place of the X/Y/Z index.
- **Wave:** small ticks along the chain show the lag (how the wave travels down
  the chain). Drag the tip's tick to change lag; scroll on the arc to change
  cycles.
- **Pulse:** the bump's time is where its strip sits on the Layers sheet, so it
  moves with the strip and needs no "at" slider. The arc grip sets its strength.
- **Noise:** the arc shows the range; one grip for amplitude, scroll for speed.
- The Layers column keeps the numbers, read-only or as fine adjustment, for
  people who want to type.

**Code:**
- New `src/ui/layer_overlay.c3` (paint, pick, press, drag, following
  `path_overlay.c3`) and `src/app/layer_handles.c3` (a layer draft played while
  dragging, landed once).
- `DragVerb.LAYER` in `src/core/dragging.c3`; hooks in `viewport.c3` beside the
  path ones.
- Shows only when the Layers sheet has a generator strip selected and the edited
  clip is on show.

**Tests:** click root / Shift-click tip sets joint and tip, dragging the amplitude
grip changes amplitude in one undo step, Esc gives it back, the axis snaps,
moving a pulse strip moves its bump.

---

## 3. Optimize as an inline card

**Now:** the pane's "Optimize…" button opens a dialog
(`src/ui/animation_motion.c3`) with a mode and three checkboxes (translation,
rotation, jitter). Clip tools › "Optimize keys…" is a second dialog.

**Instead:** one compact card that folds out under the key row, in the style of
the N-panel cards (icon cells with tooltips, no paragraphs):

- **Toggle cells:** Hold in place (translation), Remove turn (rotation), Smooth
  jitter, and Reduce keys with Off / Light / Strong.
- **Live preview:** while the card is open, the clip plays as it would come out,
  with a ghost of the original (onion style) to compare. The key count before and
  after is shown in the status line (`412 → 96 keys`).
- **Apply** lands it as one undo step; closing the card without applying changes
  nothing.
- The "Optimize keys…" menu item goes away; its Light / Strong is the Reduce cell.

**Code:** a `OptimizeCard` widget in `src/ui/animation_motion.c3`; a preview clip
cached by the clip's stamp and the card's settings, built by the existing
`clean_clip` and key-reduction code; `anim_cleanup_*` dialogs removed.

**Tests:** opening the card does not change the clip, toggling a cell changes the
preview only, Apply lands one undo step with the expected key count, closing
discards.

---

## 4. Per-track mute and solo on the Layers sheet

**Now:** mute and solo are per strip (strip right-click menu, layer column).

**Instead:** each track row on the Layers sheet gets a small header at its left
with an eye (mute) and an S (solo). They set mute or solo on every strip on that
track. A track holding a mix shows the eye half-lit, and clicking it makes them
all the same.

- **Solo:** Shift-click solos several tracks together.
- **The Base row** gets mute only: mute it to hear the strips alone. This is an
  editor-only flag, never exported, like `solo`.
- **Track names:** double-click a track's header to name it, stored as a small
  `track_names` list on the clip. This is optional and can be left out.

**Code:** `LayerSheet` header column (`src/ui/layer_sheet.c3`, near
`lane_top` / `lane_at`); `mute_track` / `solo_track` in `src/app/strips.c3`, each
one undo step. The base mute needs a flag on `AnimTemplate` that playback honours
and export ignores.

**Tests:** muting a track mutes all its strips in one undo step, solo plays only
that track's strips, a mixed track's eye shows half and clicking unifies it, the
base mute silences the keys in playback but not in an export.

---

## Also still open

- **"Keying into: <layer>"** in the key row in Keys / Curves mode, so it is
  always visible which layer a new key goes into. Skipped earlier because the
  Layers column already shows it; a compact Select next to the key buttons.
- **Facing:** paths and the gait preset assume the figure faces +Z. Read the
  rig's facing (as gait does for the leg plane) and lay the gait and the drawn
  paths' default depth from it.
- **Drawn path depth:** a click while drawing lands on the plane facing the
  camera through the joint. Optional: snap to the floor with Shift, or to the
  plane of the last two points.
- **Strips across the loop seam:** a strip on a looping clip is clamped to
  0..duration; letting it wrap round the seam would suit tail swishes on a walk.

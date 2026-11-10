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
- `DragVerb.LAYER` in `src/model/dragging.c3`; hooks in `viewport.c3` beside the
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

## 5. Clips for three.c3 cutscenes

three.c3 now plays cutscenes: `three.cutscene` with a `.cutscene.json`, edited
in `examples/editor.js` under View › Cutscene. An actor is a level row.
- A **Move** strip walks the actor's object along a path, facing +Z along it,
  and loops a clip such as `walk`.
- A **Play** strip plays a clip such as `wave`.
- **Events** are named markers the game handles.

Rigsmith supplies the clips through its normal Export .glb. These items make
those clips fit that workflow. Each one stands alone, and the order is the order
I'd do them in. Where three.c3 needs a matching change, it is named under
**three.c3** and is done there, not here.

### 5a. Travel speed in the clip's extras

**Now:**
- A walk made in place loses how fast it travelled.
- A Move strip in three.c3 plays the clip at speed 1 whatever the path's speed,
  so the feet slide.

**Instead:**
- Each exported clip with travel writes `"travel": { "distance", "speed" }` into
  its clip extras (`clip_extras_text`, `src/format/export.c3:978`):
  - `distance` is metres per cycle along the ground.
  - `speed` is metres per second.
- Both are measured on the hips or root before any Make in place, so an in-place
  walk keeps its stride.
- Read them back in `apply_clip_extras` (`src/format/pack.c3`), so a re-import
  keeps them.

**Code:**
- An algo function `clip_travel(clip, rig) -> ClipTravel` in
  `src/algo/curves/`, with no AppState.
- When Make in place runs (`src/app/root_motion.c3`), store the measured travel
  on the `AnimTemplate`, so it survives the travel being removed.
- Save it in the sidecar with the rest of the clip.

**Tests:**
- A walk from `assets/` that travels writes a speed within 5% of its hips'
  distance divided by its duration.
- After Make in place, the same number is still written.
- A clip that stays still writes no `travel`.

**three.c3:**
- Expose the asset's per-clip extras.
- Add a Move strip clip speed of `"auto"`, meaning path length ÷ strip time ÷
  travel speed.

### 5b. Say which clips travel, at export

**Now:** with root motion on Keep, a walk that travels is exported with its
travel. A Move strip then moves the actor twice: once along the path and once in
the clip.

**Instead:**
- The export panel's summary line names the clips that still travel, for example
  "walk, run travel — use Make in place for cutscenes and controllers".
- It does nothing more than say so. Root motion is still chosen in the Animations
  panel, where the viewport shows it.

**Code:** `ExportSummary` (`src/ui/export_dialog.c3`) gets a second line from a
`travelling_clips()` that reuses `clip_travel`.

**Tests:**
- A bound walk with travel is named in the summary.
- The same walk made in place is not.

### 5c. Markers on a clip

**Now:** a clip has no named moments. A game cannot know when the punch lands or
when a foot is down. The only option is hard-coding seconds that go stale when
the clip is retimed.

**Instead:**
- **Add:** right-click on the timeline ruler › Add marker. It goes at the
  playhead and is named on the spot.
- **Edit:** drag a marker to move it, double-click it to rename, and Delete
  removes it.
- **Shown** in every sheet mode, as flags under the ruler.
- **Retiming:** markers move with a Stretch, and a Trim drops the ones that are
  cut away. This uses the same `clip_with_frames` path that keys, pins and strips
  already take.
- **Feet:** Export writes the found foot contacts as markers when the export
  panel's "Footstep markers" tick is on. The names are `foot_l` and `foot_r`, at
  the start of each ground window (`"ground"` in the clip extras). These markers
  are made at export time and never stored on the clip.
- **Written** to clip extras as `"markers": [{ "t": 0.35, "name": "hit" }]`, and
  to the sidecar.

**Code:**
- `AnimTemplate.markers` (`src/algo/curves/animation.c3:537`).
- A new `src/app/clip_markers.c3`, where every edit is one undo step through
  `land_clip`.
- The ruler grips go in `src/ui/dopesheet.c3`.
- An MCP `set_markers` tool beside `set_path`.

**Tests:**
- Add, move, rename and delete each take one undo step.
- A stretch to 150% moves a marker at 0.4 s to 0.6 s.
- A trim drops the markers after the cut.
- The markers round-trip through export and import.
- The footstep tick writes one marker per ground window.

**three.c3:**
- `object.on('marker', fn)` fires as a playing clip crosses a marker.
- A cutscene forwards marker events from its actors, so a Play strip of `punch`
  can fire `hit`.

### 5d. Export facing +Z

**Now:** a cutscene turns an actor to walk along its path, and assumes the model
faces +Z. A model that faces −X walks sideways.

**Instead:**
- Export reads the rig's facing, the same way gait does for the leg plane.
- When the facing is more than 30° off +Z, the export panel says so and offers
  **Turn to face +Z**.
- That button writes the turn into the model transform (`doc.model_transform`)
  as one undo step, so the source file is unchanged.
- This also covers "Facing" under *Also still open* for paths and gait.

**Code:**
- An algo `rig_facing(doc, geometry) -> Vec3`, shared with gait.
- A notice row and button in the export panel.

**Tests:**
- An `assets/` character turned 90° reports its facing off by 90°.
- The button turns it back.
- The exported root faces +Z.

### 5e. Export a scene as a cutscene

**Now:** Export scene writes every character into one .glb with one shared
animation. A three.c3 cutscene drives level rows, which are separate objects with
separate clips, so a fight or a handshake made in Rigsmith cannot be used as one.

**Instead:**
- With more than one character loaded, the Export .glb panel offers three
  choices:
  - **This character**
  - **All characters, one file** (the current scene export)
  - **All characters, for a cutscene**
- The cutscene choice writes:
  - each character to its own .glb, as a plain export does, with its scene clip
    under one shared name and length so their timing matches
  - a `<scene>.cutscene.json` beside them, with:
    - one actor per character (`row` set to the character's label)
    - a Play strip of that clip at 0
    - each character's scene placement as `place: { position, rotation }`
      relative to the first character
- This is the dialog with export options asked for on 2026-11-08. It replaces
  the separate file chooser that `menu_export` opens for scenes.

**Code:**
- `export_dialog.c3`: a `Segmented` for the three choices, using the
  `SEGMENTED_STYLE` pattern.
- `menu_export` always opens the panel.
- `FilePurpose.EXPORT_SCENE` goes away.
- A writer for the cutscene stub goes in `src/format/`.

**Tests:**
- With two characters, the cutscene choice writes two .glb files with one clip
  each, of the same name and duration.
- The stub's two actors carry placements matching the scene.
- The one-character panel is unchanged.

**three.c3:**
- An optional actor `place`, applied relative to `create(spec, { origin })` when
  the cutscene starts.
- In the editor, **+ Actors from stub** places the stub's characters as rows.

---

## 6. Video to animation on many-legged rigs

A spider's `warn` clip, captured from a video where both front legs rise, lifts
two legs on one side and leaves the other front leg down: leg reads land on the
wrong legs. The joints are found and the rig is fitted in llm-runner's
`creature` plugin; Rigsmith draws the pictures, sends the request and lands the
clip. Items marked **plugin** are done there.

What is known (2026-11-10):
- Each studio view sees one side of a wide body. From the side, a left and a
  right joint share a pixel at rest.
- The spider's finder scores hidden joints 0.54 and seen ones 0.58, so a guess
  at a hidden leg pulls as hard as a real read. A biped's finder: 0.40 and 0.70.
- Each joint is found alone on each frame. Two names can claim one leg.
- Only left and right are ever swapped back, never two neighbouring legs.
- Mirror reads the three-quarter view as a −45° view, which no training camera
  covers.
- The fit starts from rest, though the first frame's pose is known.
- A run keeps no tracks and no log lines, so the wrong reads cannot be seen.

### 6a. Keep a run's evidence

**Done 2026-11-10.**

- An Animate run asks for `tracks` and `draw`, and writes `tracks.json`,
  `report.json` and `reads.png` into `<reference folder>/runs/<clip>/`.
- Every plugin line goes to the run log. The notice names the joints whose
  sure reads the fit left behind. MCP `capture` `{"action":"reads"}` gives the
  last run's files.
- **plugin:** `/animate` takes `draw`; the report lists each point's weight
  and miss per view.

### 6b. What the reads showed

Run on `spider_scary.mp4` outside Rigsmith (`tests/creature_studio_clip.js`):

- The finder put the lifted right front leg's names on the planted leg beside
  it, in both views, and read the lifted leg weakly. Both views agreed on the
  wrong leg, so no check between views could catch it.
- The clip landed on the right joints: the shape match pairs an eight-leg
  rig's own clip correctly (`test/algo/reach_by_name_test.c3`).

### 6c. Fixes

Done:
1. **Start from the reference pose.** Rigsmith sends `start: "reference"` for a
   video; the plugin takes frame 0's joints from `studio.json`'s pixels. Works
   for references drawn before.
2. **Limbs followed from the reference** (plugin, `follow.js`). The picture's
   joints are tracked through the frames, and each limb joint's reads are held
   against where it was followed to. On the spider video both front legs now
   rise and the mid legs stay down, in the reads and in the landed clip.

Open:
- **The run is slower:** 366 s against 200 s, because following needs each view
  at 1024 px. At 768 px the tracker took the leg beside the lifted one in the
  three-quarter view. A crop to the figure would cut the time.
- **A spider exam with known answers** is not drawn yet. `studio.json` now has
  `shown` per joint and view, and `tests/creature_studio_exam.js` grades by the
  rig's own limbs, by side, shown against hidden, and counts reads on another
  limb. It has not been run.
- **Hidden joints score low:** train with `hidden_joint_width` 2
  (`CAPTURE_TRAIN_EXTRA`), measured on the exam. Not tried.
- **A −45 training camera** in `capture_cameras`. Not tried.
- **The bundle** `libs/llm.c3l` does not have these plugin changes. Repack
  from a clean llm-runner tree once they are committed.

Dropped:
- **Land by name:** the shape match already does it.
- **Trading reads between any two alike limbs in `agreeViews`:** tried; whole
  limbs are too coarse when only a leg's middle joints are on the wrong leg.

### 6d. Later

- Studio views chosen by what they show of the body, with a raised camera.
- Fit again from saved tracks with a corrected pose pinned, without the GPU.
- A node check to turn following off, and its time in the node's estimate.

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

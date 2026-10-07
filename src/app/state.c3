<*
 `AppState` itself: what the viewport edits and the renderer reads, plus the
 lifecycle, the status line and the redraw.

 One struct, borrowed by both halves: the `Viewport` widget mutates the camera
 and the document from cui's input dispatch, and `engine/scene.c3` reads the
 camera back and pushes it to three — same frame, because cui runs input before
 the scene hook. Neither owns the other, and the state does not exist in two
 places.

 Every operation the user can invoke is a method on this struct, and they live
 across the rest of `app/`. They touch the selection as much as the document, so
 `core/document.c3` cannot hold them, and splitting them from the state they
 mutate only makes them harder to find. The ledger they record into is
 `core/editing.c3`.

 **`app/` is the seam, and this file is its floor.** `core/` is the document and
 the math under it and imports no cui; `ui/` is the widget tree over it; `app/`
 is the one folder that faces both, which is why it is where the `Ui*` back-edge
 lives. The split below it is by subject and nothing more — every file is
 `module crig`, so a method's file says where to look for it and decides nothing
 about what it can reach.

     state.c3      the struct, new_app / load_mesh / free, the file-dialog
                   purpose, the recent list and the export-clip set, @notice,
                   refresh_ui
     edit_ops.c3   selection, placing, deleting, mirroring, connecting, renaming
                   and the drag, plus set_root and pin_shell
     plans.c3      presets and body plans: apply, refit, the target overlay
     history.c3    undo / redo, the rig export, the session commands
     weights.c3    the two tint views, the rebind debounce, the weight survey
     pose.c3       the palette and the skin binding the posed modes share
     player.c3     the animation player and the posed-dot overlay
     library.c3    packs on disk and the authored pack written back to them
     assets.c3     the browser's model: the index, its categories and its filter
     recorded.c3   primitive-plus-edit pairs — the internals the operations
                   above are assembled from, none of which commits
     rig_view.c3   the skeleton and everything indexed by its joint order

 What is not here: the file *formats* (`core/session.c3`, `core/config.c3`,
 `anim/pack.c3`) and the geometry (`core/`, `rig/`). This folder holds the
 operations over them.
*>
module crig;

import cui;
import three;
import cui::widgets;
import rig;
import gltf;
import std::io;
import std::io::path;
import std::math;
import std::math::matrix;
import std::math::quaternion;


import std::collections::list;
import std::collections::map;

// Named for what it holds rather than for its element type: `rig` exports a
// `UintList` of its own, and an unqualified name that resolves to either is a
// name worth not having.
alias DotIdList = List{uint};

// The dots that ride along in a group rest move, snapshotted at the grab. See
// `DragMate` and `begin_drag`. Growable because a selection is any size — Ctrl+A
// puts the whole rig in it — so a fixed cap would silently drop the rest.
alias DragMateList = List{DragMate};

// Category selected on the 3D View's Blender-style sidebar rail. JOINT is the
// zero value, so a fresh viewport opens on the joint inspector.
enum JointPanelTab : int
{
	JOINT,
	ALIGN,
	WEIGHTS,
	POSE,
}

// What a drag on a joint changes: its place on the model (JOINTS) or the pose of
// the animation on show (POSE). The 3D View header's "Joints | Pose" switch.
// JOINTS is the zero value, so a model with no animation opens ready to rig;
// putting a clip on show moves to POSE, and the switch moves back.
enum EditStage : int
{
	JOINTS_STAGE,
	POSE_STAGE,
}

// The logical scene object selected outside the joint selection. JOINT mirrors
// `selected`; the object variants are the targets the Outliner introduces for
// the transform tools that follow it.
enum SceneSelection : int
{
	NONE,
	SCENE,
	MODEL,
	MESH,
	SKELETON,
	JOINT,
}

// The lasso's polygon while it is being drawn. Growable rather than a fixed
// buffer because a region has no length a drag can be held to — the points are
// thinned by distance instead, see `LASSO_STEP`.
alias Vec2List = List{Vec2};

<*
 Draw one frame and write it to `path` as a PNG, overwriting whatever is there.

 What `AppState.screenshot` holds. **Nothing installs it.** It was the
 executable's, which was the only place with a renderer to draw with; three has
 no readback verb on `HostApi` for the plugin to install one in its place, so
 `grab_screenshot` refuses with the headless sentence and only the checks set the
 hook. The shape stays because the tools that call through it — `screenshot` and
 `render` — are real, and the day the ABI grows a readback this is where it
 lands.

 @param ctx : `Whatever was put in AppState.screenshot_ctx.`
 @param path : `Where the PNG goes. Borrowed for the call; the file is the caller's to delete.`
 @return `False when no frame was drawn, and so no file written — a surface with no readback, a window on its way closed.`
*>
alias ScreenshotFn = fn bool(void* ctx, String path);

<*
 How the 3D view draws the model's surface, as Blender's shading buttons do:
 the plain grey model, the model's own base-colour textures, or its edges.
 SOLID first, so a config without the key reads as what crig always drew.
*>
enum ShadingMode : int
{
	SOLID,
	TEXTURED,
	WIREFRAME,
}

<*
 Which recolouring the mesh is showing, if any.

 Both draw through the same tint buffer, debounce and generation counter B6
 built — only the row-to-colour function differs. TERRITORY is the argmax map
 ("which dot owns this vertex"), FALLOFF one joint's weight on a ramp ("how far
 does this dot's influence reach"). The two answer different questions and are
 mutually exclusive, which is why this is one field and not two flags.
*>
enum TintMode
{
	OFF,
	TERRITORY,
	FALLOFF,
}

<*
 What the lasso does with the region it is handed.

 One tool with two jobs rather than two tools, because the *gesture* is the same
 one either way — draw a closed outline over the model — and what changes is only
 who receives it: the selection, or the pin layer. So the two share the point
 buffer, the outline, the escape rung and the modifiers, and differ in a single
 branch at the release.

 They do not share what they demand. PIN is a weight edit against the rest mesh,
 so it needs a dot to pin *to* and refuses over a pose; SELECT reads the same
 projected circles a click reads, so it needs neither — see `begin_lasso`.
*>
enum LassoJob
{
	SELECT,
	PIN,
}

<*
 How the editor's transport treats the end of an animation preview.

 FOLLOW_CLIP preserves the animation's authored intent.  The other two are
 session-only viewing choices: they must never be copied into AnimTemplate,
 saved, exported, or recorded in undo history.
*>
enum AnimPreviewLoop
{
	FOLLOW_CLIP,
	LOOP,
	PLAY_ONCE,
}

struct AppState
{
	// The character being edited. Its fields read as the app's own — `self.doc`,
	// `app.editing` — and every other loaded character waits in `cast`, see
	// `src/app/cast.c3`. First, so an `AppState*` is a `Character*`.
	inline Character focus;
	// Every other loaded character, by value; `cast[active]` is a hollow slot
	// where the focus stands. Empty while only one character has ever been
	// loaded — see `character_count`.
	List{Character} cast;
	usz active;
	// Moves on every change of focus, and on a character added or removed, for
	// the panels that redraw when the character they show is someone else.
	uint focus_generation;
	// The shared clock: the instant every loaded character is shown at, and
	// whether it is running. Read off the focus's clip — see `sync_cast`.
	float scene_time;
	bool scene_running;

	OrbitCamera camera;

	// `camera` belongs to this viewport while it is active; other visible
	// viewports keep their camera on their widget.
	Viewport* active_viewport;
	uint camera_reset_generation;

	<*
	 Whether the weight brush is open (shift+W).

	 The Area tool's sibling: both change a bind without moving a joint, both are
	 about the selected joint, and both borrow the falloff view while open. Each
	 press-to-release is one undo step, because that is the unit a hand thinks in.
	*>
	bool brushing;

	<*
	 The brush's radius in screen pixels, and the view it interrupted.

	 Screen-space rather than model-space, the same choice `PICK_RADIUS` makes:
	 the brush is aimed with a pointer, so the size that matters is the one under
	 it. Zooming in therefore paints finer detail without touching the setting,
	 which is what a hand expects.
	*>
	float brush_radius;
	TintMode brush_tint;

	// The joint a click on the mesh would chain a new joint from, while the
	// pointer is over the mesh in a 3D View and auto-connect would bond it; 0
	// otherwise. Set by the viewport's hover probe, read by the hint bar.
	uint chain_preview;

	// The tool options strip's Add / Remove: which way a plain drag paints.
	// Ctrl-drag and ctrl+shift-drag still add and remove whatever this says.
	bool brush_removes;

	<*
	 Whether the lasso is open (T, or shift+T straight to pinning), and which of
	 its two jobs it is doing.

	 `pin_shell`'s sibling one level finer — that one hands a whole piece of the
	 mesh to a dot, this hands whichever vertices the user draws around — and
	 the brush's sibling in what it claims: both take the plain
	 drag over the model outright, which is why opening either closes the other.

	 What it does *not* share with the brush is the ledger. A stroke is a stream
	 the hand is still adding to, so each mouse move commits; a region is not
	 finished until it is closed, so the whole gesture is one entry. Selecting
	 does not reach the ledger at all — a selection is not a document edit.

	 `lasso_job` is meaningful only while `lassoing`, the arrangement
	 `area_dot` and `brush_tint` already use: a mode's own particulars are
	 read by the mode and by nothing else. Two fields rather than one three-valued
	 enum so that every existing test of "is the lasso open" still asks the
	 question it was written to ask.
	*>
	bool lassoing;
	LassoJob lasso_job;

	<*
	 The region being drawn: its points in this pane's pixels, whether a gesture
	 is in flight, and the three things the press latched about it.

	 Pixels rather than model space, the same choice the brush radius makes: a
	 region is drawn with a pointer, so what it means is what it covers on screen.
	 It follows that the points are only meaningful for as long as the camera has
	 not moved, which is exactly the length of one press-to-release.

	 All three are read once, at the press, so a modifier let go halfway does not
	 turn a region that was unpinning into one that is pinning — the
	 `Viewport.brush_adds` rule.

	 One field per meaning, rather than one alt-shaped field read two ways: alt
	 reaches through the model while pinning and adds to the selection while
	 selecting, and a single field carrying both would be a field whose name is
	 true under one job only.
	*>
	Vec2List lasso_points;
	bool lasso_active;
	bool lasso_removes;
	bool lasso_xray;
	bool lasso_adds;

	// Shared by gizmos, shortcuts and numeric fields. The presentation layers
	// only feed deltas into this transaction; it owns preview, cancel and undo.
	TransformSpace transform_space;
	TransformPivot transform_pivot;
	TransformTransaction transform_transaction;
	TransformTool transform_tool;
	TransformInteraction transform_interaction;

	<*
	 The mesh recolouring (W territory map, F falloff): what the model is painted
	 with while `tint_mode` is not OFF.

	 `tints` is one packed colour per vertex, owned here and read by
	 `engine/scene.c3`, which pushes it to three when `tint_generation` moves. It
	 lives on the app rather than in the renderer for the same reason the camera
	 does — the thing that decides it is the document, and a test with no GPU
	 still gets to check what the user would be looking at.

	 `stale`/`due` are the debounce. A drag re-snaps its dot every mouse move and
	 every one of those is a rig change, so binding on the spot would run the
	 whole vertex-by-bone pass at mouse rate for a picture nobody can read
	 mid-drag. Nothing recomputes until the user has held still.
	*>
	TintMode tint_mode;

	<*
	 What Z goes back to from Wireframe: the fill the user was looking at.

	 The shading itself is `config.viewport_shading`, remembered between runs.
	 Wireframe answers "is the surface filled in", which is not a third
	 `TintMode` — the tint modes answer "what is painted on the model", and both
	 questions have answers at once, so a wireframe weight map is a picture the
	 user can ask for.

	 What it buys in a rigger: dots live on the medial axis, inside the body,
	 where the skin is permanently between them and the camera. Drawn as lines
	 the body stops hiding them — which is also why `Viewport.paint` stops
	 dimming occluded dots in wireframe.
	*>
	ShadingMode fill_shading;

	<*
	 What the 3D view draws at all: the mesh (View > Mesh, B) and the rig overlay
	 (View > Skeleton, S).

	 Two flags rather than one three-way mode, because the questions are
	 independent. Watching a clip play on the bare body and reading a rig with the
	 skin out of the way are both things worth asking for, and so is either alone.

	 Hiding the rig takes it away from the pointer as well — see
	 `Viewport.pick_dot`. A dot nobody can see must not be selectable or
	 draggable, and a click must not place another one where it cannot be seen
	 either.
	*>
	bool show_mesh;
	bool show_rig;

	<*
	 What the physics owns, marked on the rig overlay (View > Physics overlay).

	 A view rather than a mode: it changes nothing about what is simulated, only
	 whether the rig says which of its bones are. On by default, because a rig with
	 no dynamic bones draws nothing extra for it — the cost of the answer is
	 nothing until there is an answer — and a user who has just ticked Dynamic
	 needs to see that it took.

	 Under `show_rig` rather than beside it: these are marks on the overlay, and an
	 overlay that is off has nothing to mark.
	*>
	bool show_physics;

	<*
	 Joint names drawn beside the dots (View > Joint names, N).

	 Off by default. Seventeen names over the model is a wall of text next to the
	 one name the user is actually asking about, and that one is drawn regardless
	 of this — see `Viewport.paint_joint_names`.
	*>
	bool show_joint_names;

	<*
	 Whether the selected-joint settings panel (the "N-panel") is up (N, View >
	 Joint panel).

	 Closed by default, so a first run opens on a clear viewport: a vertical rail selects Joint or
	 Align, while N toggles the selected category's body. Clicking the active rail
	 tab closes it and clicking either tab opens that category. The rail remains so
	 the mouse can reopen a hidden body. Open on Joint with no selection it prompts
	 for one rather than vanishing.
	*>
	bool show_joint_panel;

	// The category whose body is shown when the sidebar is open.
	JointPanelTab joint_panel_tab;

	// Independent disclosure state. Zero values leave both sections open in a
	// fresh session, matching Blender's inspector panels.
	bool joint_info_collapsed;
	bool align_info_collapsed;
	bool weights_info_collapsed;

	// The Pose tab's three sections and the layer form's three: folded states,
	// remembered across runs with the rest (`ui_memory.c3`).
	bool pose_info_collapsed;
	bool pose_options_collapsed;
	bool pose_library_collapsed;
	bool layer_blend_collapsed;
	bool layer_motion_collapsed;
	bool layer_mask_collapsed;

	<*
	 How much of the check this mesh can afford at interactive rates — full,
	 reduced, or paused — judged from what the last write cost against
	 `collision_budget`. Sticky until the skin is rebound or *Prevent
	 intersections* is toggled, so a dense mesh is not re-measured on every
	 gesture; see `judge_collision_cost`.
	*>
	CollisionMode collision_mode;

	// Seconds one checked write may take before the check is cut back; zero
	// reads as `COLLISION_TIME_BUDGET`. A field so a test can set it.
	float collision_budget;

	// The bisection depth the Advanced dialog asked for; zero is the default.
	usz collision_search_steps_override;

	// Whether the view draws the contact that stopped the last gesture, as
	// the two closest points joined, while that pose is on screen. Off by
	// default: a stop is meant to be felt, not announced. The Advanced dialog
	// turns it on for whoever wants to know which two regions met.
	bool show_collision_contacts;
	bool auto_key;
	bool anim_show_tracks;

	// The sheet shows the selected joints' curves instead of key lanes, their
	// position or rotation channel, and the curve view's vertical zoom and pan.
	bool anim_show_curves;
	bool anim_graph_position;
	float anim_graph_y_zoom;
	float anim_graph_y_shift;
	AnimTemplate anim_key_clipboard;
	bool anim_key_clipboard_sparse;

	// The viewport's clipboard: a pose in rig names, separate from the saved
	// keys above so copying one never discards the other. See pose_clipboard.c3.
	AnimKeyframe anim_pose_clipboard;
	bool pose_library_selected_only;
	bool pose_library_renaming;
	String pose_library_name;

	// Sketching (sketch.c3): the tool, the stroke in flight (pixels), the ink or
	// the eraser, and the marks drawn so far.
	bool sketching;
	bool sketch_active;
	bool hide_annotations;
	SketchInk sketch_ink;

	// The eraser is on in place of an ink: a drag takes off the marks it passes.
	bool sketch_erasing;
	Vec2List sketch_points;
	AnnotationList annotations;
	uint annotation_serial;
	bool anim_tracks_selected_only;
	int anim_fps;
	bool anim_snap_off;
	float anim_preview_speed;
	AnimPreviewLoop anim_preview_loop;
	float anim_timeline_zoom;
	float anim_timeline_start;
	bool anim_edit_properties;
	int anim_pending_action;
	float anim_pending_time;
	usz anim_pending_row;

	// The held move's gesture has ended, so the next move drops the pending pose.
	bool anim_pending_armed;
	bool sim_enabled;

	// The context menu was raised from that target's ring, so it offers the target's rows.
	bool aim_menu_from_ring;

	// The pointer rests on a target's ring; the hint bar says what it does.
	bool aim_ring_hover;

	<*
	 Every animation pack the app knows about, read from ANIM_DIRECTORY at startup.

	 Data rather than code: dropping a .glb in that folder adds a pack, and the
	 ones crig ships with are made the same way — see tools/make_anims.c3. Owned
	 here, and outlives every copy taken out of it, since `current_anim` is a
	 copy that does not own what it points at.
	*>
	List{AnimPack} packs;

	<*
	 The folder `packs` was last read from, owned and empty until the first read.

	 Kept because writing a pack has to land where reading one looks, and the two
	 agreeing by both naming the same constant is an agreement nothing enforces.
	 `save_authored_pack` writes here and re-reads here.
	*>
	String library_path;

	<*
	 Which pack's card is open in the library, or -1 for none.

	 One at a time: the cards are how a pack is inspected before its rig is
	 taken, and two open at once turns the list into a wall of clips with no
	 sense of which body plan any of them belong to.

	 Starts at 0, so opening crig with a library shows the first pack's clips
	 rather than a column of closed rows saying nothing.
	*>
	int expanded_pack;

	<*
	 What every configured library holds, read from JSON alone — see `assets.c3`.

	 The browser's list. Separate from `packs` because it is a different reading
	 of the same folders: this one names each skin, clip and mesh individually and
	 costs one `gltf::open` per file, where a pack is a whole file loaded. An
	 entry here may name a file no pack has been read from yet; `pack_for_file` is
	 how it becomes one.
	*>
	AssetIndex assets;

	<*
	 The sidebar rows for `assets`, rebuilt with it. Owned.

	 Held rather than derived per build for the `pack_labels` reason: a widget
	 borrows what it is given for the life of its element, and a temporary made
	 inside a build does not last that long.
	*>
	AssetCategory[] asset_categories;

	<*
	 Which kinds the sidebar has closed, by `AssetKind.ordinal`.

	 On the state rather than on the rows it hides, because the rows do not last:
	 `refresh_category_rows` builds them again on every pane build, and
	 `rescan_assets` throws away the categories under them whenever a library is
	 added. A flag kept on either would be reset by the next thing that touched
	 the browser.
	*>
	bool[AssetKind::len] collapsed_kinds;

	// The library names the browser's chooser offers, "All libraries" first, so
	// its index is one past the position in `config.libraries`. Owned, and held
	// for the same reason `pack_labels` is.
	String[] library_labels;

	<*
	 The two lists of rows the interface's `Tree`s draw: the browser's categories,
	 and the settings panel's libraries. Owned.

	 Here rather than beside the widgets that fill them, for the reason
	 `pack_labels` is here — a `Tree` borrows its rows for the life of its element,
	 and a pane rebuilds its widgets from nothing when it splits or changes tab, so
	 the rows have to outlive any subtree. This is the thing that does.

	 Their labels point into `asset_categories` and `config.libraries`, so whatever
	 replaces either has to rebuild these before the trees are drawn again.
	*>
	TreeRow[] category_rows;
	TreeRow[] library_rows;

	<*
	 The Motion & Physics pane's menus and lines. Owned.

	 The tip choice: the dots below the edited chain's root, as the labels a
	 `Select` borrows and the ids that turn "row 3 was chosen" back into a dot.
	 The two lines are formatted out of the document rather than strings it
	 holds — which chains the rig carries, and how the edited one's swing is
	 bounded — so they are allocated with the menus and released with them; see
	 `free_physics_menus`. `physics_advanced` is the pane's disclosure: whether
	 the capsule and clear-all controls under *Advanced* are open.
	*>
	String[] physics_tip_options;
	uint[] physics_tip_ids;
	String physics_summary;
	String physics_swing_text;
	bool physics_advanced;

	<*
	 The body plans the "this mesh has no skeleton" panel offers, and the pack each
	 row stands for. Owned; here for the reason every other row list is.

	 The label is the **pack's name** with its plan tag alongside, never the tag
	 alone: three of the shipped library files declare `biped`, so a list keyed on
	 the tag would be three rows saying the same word.
	*>
	TreeRow[] plan_rows;
	int[] plan_row_packs;

	<*
	 That a mesh arrived with nothing to pose it by, and nobody has been told yet.

	 Raised by `adopt_source_rig` when it settles on "a bare mesh waiting to be
	 rigged", and lowered by `AppRoot.update` when it opens the panel that says so.
	 A flag rather than a call because the decision is made where there is no `Ui*`
	 — `load_mesh` runs between frames, and the command line runs before the tree
	 exists at all — and both routes have to end at the same panel.
	*>
	bool wants_rig_prompt;

	// The "No skeleton" panel was opened over an empty rig. `AppRoot.update` closes
	// it the frame a joint exists, however it got there — the panel's own button, an
	// MCP apply_plan, a dot placed by hand — since what it says is then untrue.
	// Opened from the menu over a rig, it stays down and the panel stays open.
	bool rig_prompt_while_bare;

	// The guided tour (src/ui/tutorial.c3): running, and which step it is on.
	// `welcome_checked` is the first-run offer having been looked at this session,
	// so a dismissed dialog does not come back on the next frame.
	bool tutorial_active;
	usz tutorial_step;
	bool welcome_checked;

	// Whether the last body plan fitted came out facing -Z (away from the front
	// view). The interactive fit (`request_pack_rig`) offers Turn around on it.
	bool fit_reversed;

	<*
	 Which assets the browser is showing, as positions into `assets.entries`.

	 Recomputed when `asset_filter` changes and not per frame — a grid rebuilding
	 its cells on every frame would drop the hover state under the pointer.
	*>
	usz[] visible_assets;

	// What produced `visible_assets`. Compared against a new filter to decide
	// whether the grid has to be rebuilt at all.
	AssetFilter asset_filter;

	<*
	 The body plans a lazily-read file is matched against, derived from the packs
	 that declared one. Owned.

	 Kept rather than derived at each read because it is the whole of what the
	 declared pass is *for*: a file from another tool has its joints named in a
	 plan's words only if there is a plan in hand to name them from, and reading
	 the library again to find one would undo the point of not reading it.
	*>
	Preset[] reference_plans;

	// The cell the pointer last acted on, as a position into `assets.entries`, or
	// -1 for none. Drawn as the selected cell; carries no other meaning, since
	// activating an asset acts at once rather than on a second click.
	int selected_asset;

	<*
	 The asset whose settings panel is open, as a position into `assets.entries`,
	 or -1 when none is.

	 Here for `pending_rig_pack`'s reason: `Dialog.body` is a builder with no
	 payload, so which cell's gear was clicked cannot travel in the call. A
	 position in the whole index rather than in the visible list, because the
	 panel outlives a search — typing in the box behind it renumbers the rows.
	*>
	int settings_asset;

	<*
	 The dot whose name is open in the Joint card's field, or 0 when the title
	 is a title.

	 Here for `settings_asset`'s reason — the card is a builder with no payload,
	 so which dot the Rename button was pressed on cannot travel in the call —
	 and pinned at the opening for one of its own: the confirm names this dot,
	 not whatever `selected` says by then. The card keeps the two in step —
	 `JointPanel.update` drops the rename the moment the selection moves on, so
	 a field is never rebuilt on another dot's card holding this one's name.

	 No sentinel: dot ids start at 1, so the zero this is born with already means
	 "none" and `RigDocument.find` answers null for it.
	*>
	uint renaming_dot;

	<*
	 Set by File > Quit; main's frame loop reads it and stops. A flag rather
	 than an exit because widgets do not own the loop, and everything below the
	 loop is a defer that still has to run.
	*>
	bool quit_requested;

	<*
	 The MCP server, as Settings sees it. The listener belongs to `main`, so the
	 port field only raises `mcp_restart_wanted`, and the loop rebinds to
	 `config.mcp_port` between frames and writes back what came of it:
	 `mcp_serving_port` is the port answering (0 when none), and `mcp_port_busy`
	 says the last bind was refused — most often another Rigsmith on that port.
	*>
	bool mcp_restart_wanted;
	int mcp_serving_port;
	bool mcp_port_busy;

	<*
	 A mesh the interface has asked for, for `main` to load between frames.

	 The same bargain `quit_requested` strikes, and for a harder reason: loading a
	 model frees the `MeshPass` and builds another, and its buffers may still be
	 in flight while a frame is being recorded. Nothing inside a widget callback
	 can wait for the device, so the widget asks and the loop — which is between
	 frames by definition — does it.

	 Owned; `main` frees it as it takes it. Empty means nothing is pending.
	*>
	String pending_open;
	// A model to bring in as another character, the same way: File > Add
	// character and the browser's Models shelf set it, the loop services it.
	String pending_add;
	// A scene to open, serviced between frames the same way; and the file the
	// scene on screen was last opened from or saved to, for Save scene.
	String pending_scene;
	String scene_path;
	// A model or scene chosen to open while other characters hold unsaved work,
	// waiting on the question that asks whether to drop it.
	String open_waiting;
	bool open_waiting_scene;

	<*
	 The pack whose rig is waiting on the user's answer, or -1 when none is.

	 A body plan replaces the rig in the document, so an interactive path asks
	 first, and the question outlives the click that raised it — `Dialog.body` is
	 a builder with no payload, so which pack was asked about cannot travel in
	 the call. Same reason `file_purpose` lives here.

	 Not a request `main` services, unlike `pending_open`: nothing about
	 replacing a rig has to wait for a frame boundary, and the dialog's own
	 button is what acts on it.
	*>
	int pending_rig_pack;

	<*
	 What crig carries between runs: the recent projects, where the file browser
	 last was, the MCP port.

	 Zero-initialised here, which is a config backed by no file — `main` is what
	 loads the real one and hands it over, so an `AppState` built in a check
	 cannot read or write the settings of whoever is running the checks. See
	 `CrigConfig.directory`.
	*>
	CrigConfig config;

	<*
	 Whether the export writes the rigged model, or only the clips.

	 On the state rather than in the panel because `Dialog.body` is rebuilt on
	 every opening and its subtree released on every close — and closing is
	 exactly what happens when the user goes to pick a destination. Initialised
	 on: the mesh bound to its skeleton is what the command has always written,
	 and a panel that opened with it off would make the ordinary export a
	 two-click one.

	 It is the only answer this panel still keeps. *Which* clips go in used to
	 live here too, as a tick set the export dialog owned and `load_mesh` cleared;
	 that is `RigDocument.animations` now, chosen in the Assets pane and saved with
	 the character.
	*>
	bool export_with_rig;

	<*
	 What the file dialog is currently being used for.

	 `Dialog.body` is a builder with no payload — the same `ViewBuilder` shape a
	 workspace view takes — so which question the browser is asking cannot be
	 carried in the call. It lives here, where the callbacks that answer it also
	 look.
	*>
	FilePurpose file_purpose;

	// Which model file a MOTION_FILE chooser answers: a `MotionGenerator`
	// config key, static.
	String motion_path_key;

	// The Settings page showing: SETTINGS_TAB_GENERAL or SETTINGS_TAB_AI.
	usz settings_tab;

	<*
	 The interface built over this state, so a change made from anywhere can
	 push itself to the panel.

	 Set by `build_ui`; null until then, and null in tests that drive the
	 document without a tree. It is a back-edge — the tree already points here —
	 which is worth it because the alternative is every editing operation
	 returning "and by the way, redraw", and the panel's Undo button has no
	 `Element*` to work from at all.
	*>
	Ui* ui;

	<*
	 Draws one frame and writes it to a PNG, or null when nothing can.

	 **Null in every run.** The executable installed it, being the only place that
	 held both the renderer and the `Ui` a frame needs; under the plugin three
	 owns both and exposes neither, so nothing fills this in and the checks are
	 the only callers that ever do. `screenshot_ctx` is handed back untouched.

	 **Only safe to call between frames.** It draws one, so calling it from
	 inside a widget callback would recurse into the frame that is already
	 running. The MCP pump is between frames by construction, which is what makes
	 `AppState.grab_screenshot` callable from a tool handler and from nowhere
	 else.
	*>
	ScreenshotFn screenshot;
	void* screenshot_ctx;

	<*
	 Where in the window the model is drawn: `{x0, y0, x1, y1}` as shares of the
	 window, 0 to 1. Zero until a viewport has painted once.

	 Shares rather than pixels because the two readers measure in different
	 units — cui lays out in UI points and a screenshot comes back in device
	 pixels — and a ratio is the same number in both. `render`'s `crop` is the
	 only thing that reads it.

	 With the workspace split, this is whichever viewport painted last. In the
	 ordinary single-pane case that is the only one; with two it is a viewport
	 either way, which is all the crop needs to be useful.
	*>
	Vec4 viewport_share;

	<*
	 The result of the last thing the user pressed a button for — where the
	 export went, or why it did not.

	 A second line rather than part of the status one, and for a reason worth
	 stating: the status line is *state*, rewritten whenever the document
	 changes, and an export result is an *event*. Folding the two together means
	 the answer to "did that work" is erased by the next click.
	*>
	char[160] notice_storage;
	usz notice_length;

	<*
	 How long the notice has been up, in seconds. See `tick_notice`.
	*>
	float notice_age;

	// Text to motion: the llm-runner job generating a clip, if one runs. See
	// `app/generate.c3`.
	MotionJob motion_job;

	// The renderer the pipeline runs its kernels on: the window's, set by `main`.
	// Null in a headless AppState, which cannot generate.
	three::Renderer* motion_gpu;

	// The Generate panel: what is typed in it.
	MotionDraft motion_draft;
}

<*
 The immutable measurements an editor derives from one mesh.

 The mesh arrays themselves are borrowed and must outlive this cache.  The
 picker, voxels and shells are owned by the cache unless their values are
 transferred into an ordinary `AppState` by `new_app`.
*>
struct AppGeometryCache
{
	rig::TriMesh geometry;
	Picker picker;
	rig::MeshVoxels voxels;
	rig::MeshShells shells;
}

<*
 Build the immutable geometry measurements an editor keeps for a mesh.

 A cache may be shared by sequential editor states through
 `new_app_from_cache`.  Its mesh arrays are borrowed; the picker, voxel grid
 and shell table are owned by the cache.  The caller must keep both the mesh
 and cache alive until every borrowing state has been freed.

 @param resolution : `Zero uses the production fitted resolution. Tests that do not measure binding fidelity can ask for a smaller real grid.`
*>
fn AppGeometryCache build_app_geometry_cache(rig::TriMesh geometry, uint resolution = 0)
{
	// Built ahead of the literal so the voxelizer can march this BVH rather than
	// building a second one over the same triangles — on a 48k-triangle mesh that
	// was the larger half of the startup cost. Copied into the struct by value;
	// the cache is the owner, whether it is transferred into one app or borrowed
	// by a sequence of test apps.
	Picker picker = build_picker(geometry);

	// And the shells ahead of the voxels, which is an ordering the grid depends
	// on rather than a tidiness: how fine a grid this model needs is decided from
	// how small its pieces are. See `rig::fitted_resolution`.
	rig::MeshShells shells = rig::build_shells(mem, geometry);

	return {
		.geometry = geometry,
		.picker = picker,
		.voxels = rig::build_voxels(mem, geometry, resolution: resolution,
			bvh: picker.bvh, pieces: &shells),
		.shells = shells,
	};
}

fn void AppGeometryCache.free(&self)
{
	self.picker.free();
	self.voxels.free(mem);
	self.shells.free(mem);
	*self = {};
}

fn AppState new_app_with_geometry(
	rig::TriMesh geometry,
	String source_path,
	Picker picker,
	rig::MeshVoxels voxels,
	rig::MeshShells shells,
	bool borrowed)
{
	AppState app = {
		// Neither is the zero value: a view that opened showing nothing at all
		// would read as a mesh that failed to load.
		.show_mesh = true,
		.show_rig = true,
		.show_physics = true,
		// Closed by default so the viewport opens clear; the rail stays at the
		// edge, and N or a click on a rail tab opens it.
		.show_joint_panel = false,

		.focus = new_character(geometry, source_path, picker, voxels, shells, borrowed),
		.camera = framed(geometry.bounds()),

		// Secondary motion runs unless something asks it not to: a dynamic bone
		// that had to be switched on is one nobody sees the effect of. Nothing is
		// built here — `tick_jiggle` does that on the first frame of playback
		// that wants it, and a rig with no dynamic bones never builds anything.
		.sim_enabled = true,
		.auto_key = true,
		.anim_fps = 30,
		.anim_preview_speed = 1.0f,

		// Pack 0 is a real pack, so -1 says "none": pack 0 would be a standing request to
		// replace the rig with the library's first body plan.
		.pending_rig_pack = -1,

		// Once more, and the worst of them: a zero `AssetFilter` selects the
		// first kind in the first library, so a browser left to the default would
		// open showing the skins of one folder and nothing would say why.
		.asset_filter = ALL_ASSETS,
		.selected_asset = -1,
		.settings_asset = -1,
		.export_with_rig = true,

		// A zero radius would open the brush unable to touch anything, which reads
		// as the mode being broken rather than as a setting wanting a scroll.
		.brush_radius = BRUSH_RADIUS_DEFAULT,

		// The config `main` hands over is the one with a file behind it — see
		// there — and this is the one field of it that is read before that
		// happens, by a check that never gets one at all. Zero would be an
		// interface laid out in an infinitely large space; `clamp_ui_scale`
		// catches it anyway, and a struct that never held the impossible value is
		// one fewer place that has to.
		.config = {
			.ui_scale = DEFAULT_UI_SCALE,
			.ghost_past = DEFAULT_GHOST_SIDE,
			.ghost_future = DEFAULT_GHOST_SIDE,
			.ghost_step = 1,
			.ghost_opacity = DEFAULT_GHOST_OPACITY,
		},
	};
	// A List has to be given its allocator before anything is pushed, and doing
	// it here rather than lazily means every toggle is a plain push — a lazy
	// init has to ask "is this the first one", and "the list is empty" is also
	// true of a list everything has been unticked from.
	app.annotations.init(mem);
	app.sketch_points.init(mem);

	return app;
}

<*
 An editor over `geometry`, or over nothing at all.

 An empty mesh is a legitimate argument: `crig` started with no file opens on
 one, and every derived structure below is empty-tolerant — the picker misses
 everything, the voxels and shells come back `{}` and the camera frames a unit
 box. `AppState.load_mesh` is what fills it in later.

 @param geometry : `Borrowed by the picker's BVH; it must outlive the AppState. May be empty.`
 @param source_path : `Where the mesh was loaded from; export writes beside it. Empty disables export.`
*>
fn AppState new_app(rig::TriMesh geometry, String source_path = "")
{
	AppGeometryCache cache = build_app_geometry_cache(geometry);
	return new_app_with_geometry(geometry, source_path, cache.picker, cache.voxels, cache.shells, false);
}

<*
 Open a fresh editor state over a longer-lived immutable geometry cache.

 Only geometry-derived acceleration data is shared.  The document, animation
 state, undo history, configuration and every UI-facing collection are new, so
 one check cannot leave editor state for the next one.  Pair the result with
 `AppState.free`; it detaches the borrowed cache without releasing it.
*>
fn AppState new_app_from_cache(AppGeometryCache* cache, String source_path = "")
{
	if (!cache) return new_app({}, source_path);
	return new_app_with_geometry(cache.geometry, source_path,
		cache.picker, cache.voxels, cache.shells, true);
}

<*
 Detach or release the immutable structures measured from the current mesh.

 Borrowed caches belong to their process-level owner and are only zeroed out of
 the state.  Ordinary application states own the same fields and release them.
 Keeping this decision here prevents a load, a generated-body swap and final
 cleanup from drifting into three subtly different ownership rules.
*>
fn void AppState.drop_geometry_cache(&self)
{
	if (self.borrows_geometry_cache)
	{
		self.picker = {};
		self.voxels = {};
		self.shells = {};
		self.borrows_geometry_cache = false;
		return;
	}

	self.picker.free();
	self.voxels.free(mem);
	self.shells.free(mem);
}

<*
 Whether there is a model to rig.

 False between startup and the first `load_mesh` when crig was run with no
 file. Everything that reads the mesh — placing a dot, binding, exporting, the
 occlusion cue — has to ask, because with no mesh they have nothing to answer
 about rather than an empty answer to give.
*>
fn bool Character.has_mesh(&self) => self.geometry.positions.len > 0;

<*
 The mesh's own edges, built if they are not already in hand.

 	`rig::MeshAdjacency* around = app.adjacency_for();`

 **Lazy, because almost nothing wants it.** The binder measures distance through
 the voxel grid rather than along the edges, so the only caller is
 `smooth_boundaries` — building this beside the shells would make every model
 load pay for a sort most sessions never read.

 Rebuilt when the vertex count no longer matches the mesh, which is the one way
 the mesh can change under it without going through `load_mesh` or
 `replace_geometry`; both of those free it outright, so this is a guard rather
 than the mechanism. A mesh of the same length is a mesh this still describes.

 **Borrowed.** What comes back points into the AppState and lives until the mesh
 is replaced. A caller may read it and must not free it.

 @return `The adjacency, empty and unusable for a mesh with no triangles.`
*>
fn rig::MeshAdjacency* AppState.adjacency_for(&self)
{
	if (self.adjacency.vertices() != self.geometry.positions.len)
	{
		self.adjacency.free(mem);
		self.adjacency = rig::build_adjacency(mem, self.geometry);
	}
	return &self.adjacency;
}

<*
 Point the document at a file it does not own.

 	`app.point_at("build/model.glb");`

 For a caller holding the bytes itself — `main` with a path off the command line,
 a check naming a file it wrote. Use `retarget_source` for a path crig produced
 and must keep.
*>
fn void AppState.point_at(&self, String path)
{
	if (self.source_path.len > 0 && self.owns_path) alloc::free(mem, self.source_path.ptr);

	// Borrowed, the way `new_app` takes the one off the command line: the caller
	// owns the bytes and outlives this. Assigning the field directly would do the
	// same thing and skip the release above, which is a leak on a state that had
	// been retargeted and a double free on the next one.
	self.source_path = path;
	self.owns_path = false;

	// Somebody else's file until proven otherwise, exactly as on an open.
	self.saves_in_place = false;
	self.source_has_model_transform = false;
}

<*
 Point the document at a different file, and let crig write it.

 	`app.retarget_source(exported);`

 What **Export** and the first **Save** both do: the file they produced is now
 the one this rig belongs to, so the next Ctrl+S writes it rather than making
 another copy, the session would land beside *it*, and the HUD names it. That
 last part is not a side effect — a user whose save went somewhere other than the
 file they opened has to be able to see where.

 The mesh is untouched. This says where the document lives, not what it is over,
 which is why an export retargeting does not reload the stripped model it wrote.

 @param path : `The file to adopt. Empty, or the path already held, does nothing.`
*>
fn void AppState.retarget_source(&self, String path, bool model_transform_in_mesh = false)
{
	if (path.len == 0) return;
	if (path == self.source_path)
	{
		self.source_has_model_transform = model_transform_in_mesh;
		return;
	}

	// Copied before the old one goes, in case the caller handed us a view into it.
	String held = path.copy(mem);
	if (self.source_path.len > 0 && self.owns_path) alloc::free(mem, self.source_path.ptr);

	self.source_path = held;
	self.owns_path = true;
	self.saves_in_place = true;
	self.source_has_model_transform = model_transform_in_mesh;
}

<*
 Whether the model is drawn as edges (Z, or the Wireframe shading button).
*>
fn bool AppState.wireframe(&self) => self.config.viewport_shading == ShadingMode.WIREFRAME;

<*
 Switches the 3D view's shading, remembering it between runs. Wireframe keeps
 the fill it replaced so Z can go back to it.
*>
fn void AppState.set_shading(&self, ShadingMode mode)
{
	ShadingMode was = self.config.viewport_shading;
	if (was == mode) return;
	if (was != ShadingMode.WIREFRAME) self.fill_shading = was;
	self.config.viewport_shading = mode;
	self.config.save();
}

<*
 Replace the mesh, and everything derived from it, with a fresh document over it.

 	`app.load_mesh(loaded, "goat.glb");`

 The rig does not survive: a dot is a position inside a particular body, and
 carrying one onto a different mesh puts a joint wherever the old model happened
 to be thick. The session file beside the new mesh is loaded instead, so
 reopening a model you have rigged before gets that rig back — and the undo
 history is cleared with the document, since an undo across a model change would
 restore dots into a body that no longer has room for them.

 **Does not touch the GPU.** What is on screen is three's asset, rebuilt when
 `geometry_generation` moves — see `sync_scene` in `engine/scene.c3`, and
 `AppState.pending_open` / `service_open` in `main.c3` for the door a file
 comes through. So the new model appears on the next frame rather than this one,
 which is what a caller reading straight back will see.

 @param geometry : `Taken over: freed by this state when it is replaced or the state goes.`
 @param path : `Where it came from. Export writes beside it and the session is looked for there.`
 @param reframe : `Whether the camera moves to frame the new mesh.`
*>
fn void AppState.load_mesh(&self, rig::TriMesh geometry, String path, bool reframe = true)
{
	self.discard_transform_transaction();
	self.transform_interaction = {};
	self.stop_animation();
	// A timeline draft belongs to the rig that was open.
	self.stop_deformed_display();

	// Editing belongs to the previous character, including its cached lanes.
	self.editing = NO_ANIM;
	self.edit_time = 0.0f;
	self.free_timeline_tracks();
	self.clear_animation_key_selection();

	self.swap_mesh(geometry);
	self.mesh_resized = false;

	if (self.source_path.len > 0 && self.owns_path) alloc::free(mem, self.source_path.ptr);
	// Only when there is one to copy. Both the release above and the one in
	// `free` are guarded on the length, so a copy of an empty path is a byte
	// nothing ever frees — and a mesh handed over without a path is ordinary:
	// it is what an importer that built the mesh itself passes.
	self.source_path = path.len > 0 ? path.copy(mem) : "";
	self.owns_path = path.len > 0;

	// Not for a character added beside others: the view is on the scene, and
	// jumping it to the newcomer would lose the one the user was looking at.
	if (reframe)
	{
		self.camera = framed(geometry.bounds());
		self.camera_reset_generation++;
	}

	self.doc.free();
	self.doc = {
		.auto_connect = true,
		.sym_x = geometry.bounds().center().x,
	};

	self.undo_stack.clear();

	// A part picked on the model that just left names its vertices.
	self.end_area();
	self.select(0);
	self.outliner_scene_collapsed = false;
	self.outliner_model_collapsed = false;
	self.outliner_skeleton_collapsed = false;
	self.outliner_collapsed_joints.clear();

	// A question asked about the model that just left. Whatever the answer would
	// have been, it is not an answer about this one.
	self.pending_rig_pack = -1;

	// Belongs to the model that just left, and is about to be answered again for
	// this one — by the session load, by the import, or by neither.
	self.imported_skin.free(mem);
	if (self.pose_edit_draft.len > 0) alloc::free(mem, self.pose_edit_draft);
	self.pose_edit_draft = {};
	self.drop_aim_draft();
	self.clear_aim_target();
	self.pose_edit_active = false;
	self.pose_edit_pending = false;
	self.stage = JOINTS_STAGE;
	// The anchors named the joints of the model that just left, and their targets
	// are world points in its pose. Neither means anything for the next one.
	self.clear_position_locks();
	self.replace_authored_clips({});
	self.authored_dirty = false;

	// The rig for this model: the session beside it, or the one the file carries.
	// Same call the command line makes — see `adopt_source_rig` for the order and
	// why it is one decision rather than two.
	self.adopt_source_rig();
}

<*
 Swap the mesh under a rig that stays where it is.

 `load_mesh` is the other door and takes the document with it, for the reason
 written there: a dot is a position inside a particular body. This one is for a
 body built *around* the rig already open — every dot is inside it by
 construction, so discarding the document would throw away the only thing the
 new mesh was shaped to fit.

 Everything derived from the geometry is rebuilt: the picker's BVH, the voxels,
 the shells, the tints and the skin binding. The camera is left where the user
 put it, unless there was nothing to look at before.

 **Attachments are the caller's problem.** They key on shell id, and the shells
 of a generated body are its bones — nothing like the pieces of the model it
 replaced. Nothing here sweeps them, because clearing them would be a document
 change with no undo behind it; `build_body` refuses instead, and says so.

 **Does not touch the GPU**, exactly as `load_mesh` does not. Reach it through
 `AppState.swap_geometry`, which is the door that sequences the upload.

 @param geometry : `Taken over: freed by this state when it is replaced or the state goes.`
*>
fn void AppState.replace_geometry(&self, rig::TriMesh geometry)
{
	// The arrays freed below are exactly what a script's typed arrays look into.
	// No JavaScript can run between here and the detach — the script is parked
	// inside the call that got here — so the counter moving is what the bridge
	// reads on the way back out.

	self.stop_animation();
	self.stop_deformed_display();

	// Asked before the old mesh goes: an empty document has no framing worth
	// keeping, and a first body should arrive in view.
	bool had_mesh = self.geometry.positions.len > 0;

	self.swap_mesh(geometry);

	if (!had_mesh)
	{
		self.camera = framed(geometry.bounds());
		self.camera_reset_generation++;
	}

	// The mirror line follows the body, since that is what it was measured from.
	self.doc.sym_x = geometry.bounds().center().x;
}

<*
 The half `load_mesh` and `replace_geometry` share: drop everything measured
 against the old mesh, take the new one over, and rebuild what is derived from
 it. The document, the camera and the path are the callers' to decide.

 @param geometry : `Taken over: freed by this state when it is replaced or the state goes.`
*>
fn void AppState.swap_mesh(&self, rig::TriMesh geometry)
{
	// Before anything is rebuilt, and in this order: posed occlusion borrows the
	// picker's BVH, which in turn points into the arrays being freed.
	self.collision_policy.free();
	self.deformed_surface.free();
	self.drop_geometry_cache();
	self.drop_base_bind();
	self.drop_stroke_memory();
	self.end_area();
	// Beside the shells rather than rebuilt with them: it is keyed to vertices
	// the model arriving does not have, and nothing needs it until an op asks —
	// see `adjacency_for`.
	self.adjacency.free(mem);
	self.uv_islands.free(mem);
	self.uv_islands_read = false;
	// With the shells, because they are keyed to them: a rider is one entry per
	// piece, and the pieces of the model arriving are not the pieces of the one
	// leaving.
	self.drop_shell_riders();
	if (self.owns_geometry) self.geometry.free(mem);

	self.geometry = geometry;
	self.geometry_generation = next_generation();
	self.owns_geometry = true;

	// Somebody else's file until something says otherwise — `adopt_source_rig` is
	// what says otherwise, for a model carrying crig's own document. And a body
	// swapped under a rig no longer matches the file the rig came from, so
	// writing the rig back into it would put this rig on somebody else's mesh.
	self.saves_in_place = false;
	self.source_has_model_transform = false;

	self.picker = build_picker(geometry);
	// Shells first: how fine a grid this model needs is decided from how small
	// its pieces are. See `rig::fitted_resolution`.
	self.shells = rig::build_shells(mem, geometry);
	self.voxels = rig::build_voxels(mem, geometry, bvh: self.picker.bvh, pieces: &self.shells);
	self.borrows_geometry_cache = false;

	// Everything measured against the old mesh. Dropped rather than left to be
	// replaced on the next rebind: both are sized to a vertex count that no
	// longer exists, and the render pass reads a mismatched tint array as
	// "stop tinting" — which is the right answer, but only because nothing
	// hands it the old one in the meantime.
	if (self.tints.len > 0) alloc::free(mem, self.tints);
	self.tints = {};

	// Emptied, not merely freed: `SkinBinding.free` releases its arrays and
	// leaves the slices pointing at them, so a binding freed here and left in
	// place is freed a second time by the rebind that starts the next preview —
	// an abort in the allocator, not a wrong picture.
	self.skin.free(mem);
	self.skin = {};
	self.skin_joints = 0;

	self.mark_rig_stale();
	self.plan_targets_stale = true;
}

<*
 Which question the file browser is being opened to answer.

 Two dialogs would be the other way to say this, and it is the wrong one: they
 would be the same list of the same files differing only in what the button at
 the bottom does.
*>
enum FilePurpose
{
	OPEN_MESH,
	// A model to load beside the open one, as another character.
	ADD_CHARACTER,
	// A scene file to open, and where to save the one on screen.
	OPEN_SCENE,
	SAVE_SCENE,
	// Where the whole scene goes as one .glb.
	EXPORT_SCENE,
	EXPORT_TARGET,

	// Picking a folder rather than a file, which is the one question here whose
	// answer a directory *is* — the other two navigate into one instead. See
	// `file_dialog_confirmed`.
	ASSET_LIBRARY,

	// One of the model files on Settings › AI, named by
	// `AppState.motion_path_key`: a .gguf or .safetensors.
	MOTION_FILE,
}

<*
 Where the file browser should start, as an absolute directory.

 The last place it was, then the directory of the current mesh, then — in a
 packaged build — the built-in animations, in the user's Documents when
 `install_user_library` put them there — then the working directory, each a better
 guess than the one after it, and the last one always answers. A packaged app is
 started from wherever its launcher likes (`/` from the Finder), so there the
 working directory is no guess at all, and the shipped library is.

 The caller owns the returned string.
*>
fn String AppState.browse_start(&self, Allocator allocator)
{
	if (self.config.browse_directory.len > 0) return self.config.browse_directory.copy(allocator);

	if (self.source_path.len > 0)
	{
		String directory = widgets::parent_of(self.source_path);
		if (directory.len > 0) return directory.copy(allocator);
	}

	if (user_library.len > 0 && file::is_dir(user_library)) return user_library.copy(allocator);
	if (bundle_root.len > 0 && file::is_dir(bundled(DEFAULT_LIBRARY_PATH)))
	{
		if (try Path shipped = path::new(tmem, bundled(DEFAULT_LIBRARY_PATH)).absolute(allocator)) return (String)shipped;
	}

	if (try Path here = path::cwd(allocator)) return (String)here;

	// Nothing left to guess with. Empty rather than a copied literal: a caller
	// that frees what this returns would be freeing static data.
	return "";
}

<*
 Remember where the browser is, so the next opening starts there.

 Kept but not written out: the browser reports this on every step into a folder,
 and a file per double-click is not worth the setting. `main` saves the config
 when the run ends, and `remember_project` saves it before then.
*>
fn void AppState.remember_directory(&self, String directory)
{
	self.config.set_browse_directory(directory);
}

<*
 Put a model at the top of the recent list, and write the config out.

 Called where a project is *established* rather than merely touched — a model
 opened, a session saved — because that is what the list is a list of. Reading a
 model to screenshot it is not one.

 Does nothing for a config with no file behind it, which is every `AppState`
 that `main` did not build.
*>
fn void AppState.remember_project(&self, String mesh_path)
{
	self.config.remember_recent(mesh_path);
}

<*
 The clips bound to this character, as templates the writer can take.

 Borrowed from the library, which owns them — the same bargain `AppState.clip`
 makes. A binding that will not resolve is skipped rather than raising: a library
 can be re-read, a folder can be moved, and an export that refused because one
 clip of twelve went missing would be refusing the wrong thing. The panel is
 where a missing binding is *shown*; this is the writer's path and it takes what
 is there.

 The caller owns the array; the templates in it are the library's.
*>
fn AnimTemplate[] AppState.bound_templates(&self, Allocator allocator)
{
	AnimTemplateList out;
	out.init(allocator);

	for (sz i = 0; i < self.doc.animations.len(); i++)
	{
		AnimRef ref = self.resolve_bound(i);
		if (!ref.valid()) continue;
		// A deferred stub has no curves until it is read; see `model_clips`.
		self.ensure_clip_imported(ref);
		AnimTemplate* template = self.clip(ref);
		if (template) out.push(*template);
	}

	AnimTemplate[] clips = out.to_array(allocator);
	out.free();
	return clips;
}

<*
 Ask `main` to load this mesh before the next frame. See `AppState.pending_open`.
*>
fn void AppState.request_open(&self, String path)
{
	if (self.pending_open.len > 0) alloc::free(mem, self.pending_open.ptr);
	self.pending_open = path.copy(mem);
}

<*
 Take the pending request, leaving none. The caller owns the string and frees it.

 A take rather than a read, so a request cannot be serviced twice — the loop
 clears it before it does anything that might fail, and a failed load leaves the
 model that was already there rather than retrying forever.
*>
fn String AppState.take_pending_open(&self)
{
	String path = self.pending_open;
	self.pending_open = "";
	return path;
}

fn void AppState.free(&self)
{
	// A generation still running is killed rather than left writing into a
	// library nobody is watching.
	(void)self.stop_motion_generation();
	self.motion_job.clear();
	self.motion_draft.free();
	self.discard_transform_transaction();
	self.transform_interaction = {};

	// Every character, the one being edited last: each waiting one is brought in
	// to be freed, so its authored pack lands in `packs` and goes with the rest.
	self.free_cast();
	self.free_character_state();

	self.anim_key_clipboard.free(mem);
	self.anim_pose_clipboard.free(mem);
	self.pose_library_name.free(mem);
	if (self.pending_open.len > 0) alloc::free(mem, self.pending_open.ptr);
	if (self.pending_add.len > 0) alloc::free(mem, self.pending_add.ptr);
	if (self.pending_scene.len > 0) alloc::free(mem, self.pending_scene.ptr);
	if (self.scene_path.len > 0) alloc::free(mem, self.scene_path.ptr);
	if (self.open_waiting.len > 0) alloc::free(mem, self.open_waiting.ptr);
	self.config.free();
	self.free_annotations();
	// Not beside the stroke memory in the two mesh-replace paths, unlike that
	// one: a stroke's memory is one float per vertex and dies with the mesh,
	// while a lasso's points are pixels and belong to a gesture that cannot
	// outlive the frame it is in.
	self.drop_lasso_memory();
	self.drop_packs();
	if (self.library_path.len > 0) alloc::free(mem, self.library_path.ptr);
	free_assets(mem, self.assets);
	if (self.asset_categories.len > 0) alloc::free(mem, self.asset_categories);
	if (self.visible_assets.len > 0) alloc::free(mem, self.visible_assets);
	if (self.asset_filter.search.len > 0) alloc::free(mem, self.asset_filter.search.ptr);
	self.free_library_labels();
	self.free_reference_plans();
	self.free_category_rows();
	self.free_library_rows();
	self.free_physics_menus();
	self.free_plan_rows();
	*self = {};
}

<*
 Free everything the character being edited owns, and zero it.

 The half of `free` that belongs to one character, so removing a character and
 tearing the whole app down release exactly the same things. Its authored pack
 stays in `packs` for `drop_packs`, or for the caller to take out.
*>
fn void AppState.free_character_state(&self)
{
	self.drop_gesture_before();
	self.drop_gesture_aim();
	self.clear_animation_key_selection();
	if (self.source_path.len > 0 && self.owns_path) alloc::free(mem, self.source_path.ptr);
	self.also_selected.free();
	self.outliner_collapsed_joints.free();
	self.drag_mates.free();
	if (self.occlusion_memo_ready) self.occlusion_memo.free();
	self.player_pose.free(mem);
	self.drop_playback_rig();
	self.drop_onion();

	// Borrowing order: the posed accelerator names picker nodes and the picker
	// names geometry arrays. Release all three in that order.
	self.collision_policy.free();
	self.deformed_surface.free();
	self.drop_geometry_cache();
	if (self.owns_geometry) self.geometry.free(mem);
	self.drop_base_bind();
	self.drop_stroke_memory();
	self.drop_area_part();
	self.drop_area_base();
	self.adjacency.free(mem);
	self.uv_islands.free(mem);
	self.drop_shell_riders();
	self.doc.free();
	self.undo_stack.free();
	free_fitted(mem, self.plan_targets);
	if (self.plan_fitted.len > 0) alloc::free(mem, self.plan_fitted.ptr);
	if (self.tints.len > 0) alloc::free(mem, self.tints);
	self.skin.free(mem);
	self.imported_skin.free(mem);
	if (self.pose_edit_draft.len > 0) alloc::free(mem, self.pose_edit_draft);
	self.drop_aim_draft();
	self.clear_aim_target();
	self.clear_position_locks();
	self.drop_palette();
	// Outlives every frame of playback by design, so it is here rather than in
	// `drop_palette` beside the things one frame owns.
	self.jiggle_sim.free(mem);
	if (self.jiggle_skip.len > 0) alloc::free(mem, self.jiggle_skip);
	if (self.dynamic_dots.len > 0) alloc::free(mem, self.dynamic_dots);
	if (self.dynamic_dot_roots.len > 0) alloc::free(mem, self.dynamic_dot_roots);
	self.free_pack_reaches();
	self.free_anim_rows();
	self.free_timeline_tracks();
	self.mapping_draft.free();
	self.anim_check.free();
	self.authored_store.free(mem);
	// Its authored pack is in `packs` while it is the focus; out with it, so a
	// removed character takes its clips along rather than leaving them listed.
	self.replace_authored_clips({});
	self.focus = {};
	// Zero is pack 0, a real pack — see `new_character`.
	self.authored_pack = -1;
}

<*
 The result line — empty until something has been done that has one.

 A method rather than a field, so the pointer is always derived from the address
 the AppState is being read at: a String field would be a pointer INTO this
 struct, and `new_app` returns the struct by value, so the slice would point at
 dead stack. Valid until the next `@notice`.
*>
fn String AppState.notice(&self) => (String)self.notice_storage[:self.notice_length];

<*
 Replaces the result line, formatted straight into the panel's own buffer.

 A macro rather than a function so the message is built in place and nothing is
 allocated to say something. Overflow keeps whatever fitted — `bprintf` fills
 the buffer before it complains — because the only argument long enough to cause
 it is a path, and most of a path still tells the user where the file went.
*>
macro void AppState.@notice(&self, String format, args...)
{
	self.notice_age = 0.0f;

	char[]? written = io::bprintf(self.notice_storage[..], format, ...args);
	if (catch written)
	{
		self.notice_length = self.notice_storage.len;
		return;
	}
	self.notice_length = written.len;
}

<*
 How long a result stays on screen, in seconds.

 Long enough to read an exported path back, short enough that the answer to
 "did that work" is not still sitting over the model several operations later.
*>
const float NOTICE_LIFE = 8.0;

<*
 Ages the result line and takes it down once it has been up long enough.

 A result is an event, and an event that never ends stops reading as one: a
 notice still on screen after the next four things were done is indistinguishable
 from a caption on the picture. Taking it down is also the only thing that keeps
 a refusal — "select a dot first" — from following the user around after they
 have selected one.

 Driven from `AppRoot.update`, which runs once per frame for the whole window
 rather than once per pane. `AppState.ticking` counts a live notice, so the
 frames that age it keep coming even when nothing else is moving.

 @param dt : `Seconds since the last frame.`
*>
fn void AppState.tick_notice(&self, float dt)
{
	if (self.notice_length == 0) return;

	self.notice_age += dt;
	if (self.notice_age >= NOTICE_LIFE) self.notice_length = 0;
}

<*
 Draw one frame and leave it at `path` as a PNG.

 The picture is of whatever the document says right now, so a caller that has
 just changed something does not need a repaint of its own — the frame this
 draws is the one that shows the change.

 **Between frames only.** It draws one; see `AppState.screenshot` for what
 calling it from inside a frame would do.

 @return `False when nothing was drawn — no window, no readback, or a window on its way closed. No file is written then, and whatever was already at the path is left alone.`
*>
fn bool AppState.grab_screenshot(&self, String path)
{
	if (!self.screenshot) return false;
	return self.screenshot(self.screenshot_ctx, path);
}

<*
 Push a document change to the interface: repaint the overlay and the HUD.

 The HUD would notice on its own — its update() diffs the state every frame —
 but repainting it here keeps a change visible on the very frame it was made,
 which is what a headless test asserts against.

 Safe to call with no tree; that is what makes the operations below usable from
 a test that never builds one.
*>
fn void AppState.refresh_ui(&self)
{
	if (!self.ui) return;

	// Repaints every match rather than the first: each split pane holds its own
	// viewport, HUD and animation list, and a pane that is skipped goes on
	// showing the old dot count or the old playing highlight. All three
	// questions ride one walk, because testing an element costs far less than
	// walking the tree to reach it and this runs on every step of a drag.
	self.ui.@walk(; elem)
	{
		// The asset sheet is asked for a *build*, not a paint. Its cells are child
		// elements, so what has to be re-run when the visible list changes is the
		// build that makes them — and `request_paint` would not get there: it
		// forwards to a rebuild only for a widget that builds and does not paint,
		// and this one does both, since it draws the line that stands in for an
		// empty grid.
		if (elem.is_widget(AssetSheet))
		{
			elem.request_build();
		}
		else if (elem.is_widget(SceneOutliner))
		{
			elem.widget_as(SceneOutliner).refresh(elem, self);
		}
		// The chooser is on the list because it *builds* rather than paints, and
		// `request_paint` does forward for it — without which its head goes on
		// showing the plan before last.
		else if (elem.is_widget(Viewport) || elem.is_widget(AssetCell)
			|| elem.is_widget(Select) || elem.has_id("hud"))
		{
			elem.request_paint();
		}
	};
}

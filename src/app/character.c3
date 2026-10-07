<*
 One loaded character: a mesh, the rig authored on it, its clips' playback and
 its own undo history.

 **Every field here used to be the app's.** The app still reads them as its own:
 `AppState` holds the character being edited inline, as its first field `focus`,
 so `self.doc`, `app.editing` and a method declared on `Character` all resolve
 through it, and an `AppState*` converts to a `Character*` where one is asked
 for. The other loaded characters wait in `AppState.cast`, and switching between
 them is a value swap — see `src/app/cast.c3` — which is safe because nothing in
 here points into the struct itself, only to the heap.

 What is *not* here is what every character shares: the camera and the
 viewports, the view toggles, the clipboards, the library and its packs, the
 configuration. One rule decides: a field belongs here when it describes one
 mesh, the document authored on it, or that document's playback.
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

struct Character
{
	// Stable for the session and never reused, so a renderer keying its draw
	// state on it cannot mistake a new character for the one it replaced.
	uint id;
	// The size a live Scale drag shows the model at, about its origin, before
	// anything is baked; zero when no drag is running. Drawn only — the mesh,
	// the dots and every cache keep their real size until the release bakes it
	// once through `scale_model_by`, so a drag costs a matrix, not a rebuild per
	// frame.
	float preview_scale;
	<*
	 Where clips authored through the MCP tools land: an index into `packs`, or
	 -1 until something writes one.

	 A pack like any other, so an authored clip is a clip like any other —
	 `AnimRef`, `play_clip`, the library card and the exporter all reach it
	 without knowing it was not read off a file. It is appended last and created
	 on first write, which leaves every disk pack at the index it was read in.

	 Nothing on disk backs it. It is built, played and dropped in memory, and
	 dies with the process; `load_packs` carries it across a re-read because a
	 library reload is about the folder, not about what an agent has written.
	*>
	int authored_pack;
	// This character's authored pack while it waits in `AppState.cast`. Only the
	// character being edited has its clips in `packs`, so the library, the browser
	// and every clip lookup see one character's work; a parked one's slot there is
	// left empty and `authored_pack` keeps its index, so its clip refs still name
	// the right pack when it comes back. Zero while this character is the focus.
	AnimPack authored_store;

	// Whether the shared clock drives this character while another is edited.
	// Off, it holds whatever pose it was left in.
	bool holds_pose;
	// Left out of the viewport: not drawn and not picked.
	bool hidden;

	Picker picker;

	// Static topology shared by lazy rig-overlay rays and exact regional
	// collision refits. It borrows the picker's BVH and is rebuilt with the skin
	// binding, never per animation frame — see `core/posed_occlusion.c3`.
	DeformedCollisionSurface deformed_surface;

	// Which of that surface's broad-phase pairs a self-collision check may test,
	// built beside it from the same binding — see `core/collision_policy.c3`.
	CollisionPolicy collision_policy;
	RigDocument doc;

	<*
	 The mesh being rigged, and where it came from.

	 Both may be empty, and that is a state crig runs in: it opens with no model
	 until one is loaded — see `AppState.has_mesh`. An empty mesh leaves the
	 picker, the voxels and the shells empty too, and every one of them answers
	 "nothing there" rather than faulting.

	 Ownership is `owns_geometry`, not a property of the type: the mesh handed to
	 `new_app` is borrowed (it is `main`'s, or a test's static array), while one
	 `load_mesh` read off disk belongs to this struct and is freed when it is
	 replaced. The picker's BVH points into whichever array is current, so the
	 two are always replaced together.

	 **The path has a flag of its own**, because it outlives the arrangement that
	 gave it: `retarget_source` moves the document onto a file crig wrote — the
	 copy a save made, or the file an export produced — and that path is allocated
	 whether or not the geometry beneath it ever was.

	 The path is what `export_rig` writes beside and what **Save** writes into. It
	 is empty in a test that built its mesh in memory, and both say so rather than
	 guessing a directory.
	*>
	rig::TriMesh geometry;

	<*
	 Bumped whenever `geometry` is replaced by a different mesh.

	 What a renderer that does not own the arrays watches. `MeshPass` never needed
	 one — it is torn down and rebuilt by the same two calls that replace the mesh
	 — but the plugin's renderer is three's, which crig reaches through a handle
	 and cannot rebuild from the inside. Comparing pointers instead would be wrong
	 the moment an allocator reused an address, which is exactly what freeing one
	 mesh and reading another makes likely.
	*>
	uint geometry_generation;
	String source_path;
	bool owns_geometry;
	bool owns_path;

	<*
	 Whether `source_path` is a file crig may write over.

	 False for a model somebody else made — which is every model on its first
	 open, and the whole of the protection: **Save** copies it to
	 `<stem>_copy.glb` and works there instead, so the file the user opened is the
	 file the user still has. See `AppState.save_session`.

	 True once the document is pointed at a file crig produced: the copy a save
	 made, the file an export wrote, or a model reopened that carries crig's own
	 document in its `extras` — that last one is what makes the second save of a
	 session write the same file as the first rather than a copy of a copy.
	*>
	bool saves_in_place;
	bool source_has_model_transform;

	<*
	 The mesh was resized in crig (Scale model by…) and the file at `source_path`
	 still holds it at the old size. Save writes the vertex positions too while
	 this is up, and lowers it once they are in the file the document follows.
	*>
	bool mesh_resized;

	<*
	 The mesh's own inside, for measuring distance through it (M3).

	 Built once beside the picker, because it depends on the mesh and nothing
	 else — every rebind reads it and none of them rebuild it. A mesh with no
	 inside to find leaves this unusable, and every binder falls back to
	 straight lines rather than refusing to rig it.
	*>
	rig::MeshVoxels voxels;

	<*
	 The mesh's separate pieces, for the binder's prop rule.

	 Built once beside the voxels and for the same reason: a shell is a property
	 of the mesh, so no edit to the rig can change it. What the rig decides is
	 only which bone each piece rides — `doc.attachments`, resolved to joint
	 indices by `attachment_joints` at every bind.
	*>
	rig::MeshShells shells;

	<*
	 Whether `picker`, `voxels` and `shells` belong to a longer-lived geometry
	 cache rather than to this editor state.

	 Normal application states own all three.  Headless checks over the same
	 static mesh can borrow one immutable cache for the test process, while the
	 document, history and UI remain fresh for every check.  A mesh replacement
	 drops the borrow and owns the structures it builds for the new mesh.
	*>
	bool borrows_geometry_cache;

	<*
	 Which points of the mesh touch which, for the ops that average over a
	 neighbourhood.

	 Not built beside the shells and the voxels, unlike everything else derived
	 from the mesh: nothing on the binder's path wants it, and only Smooth
	 boundaries ever asks — so a session that never runs that op never pays for
	 the sort. `AppState.adjacency_for` is the door, and the two mesh-replace
	 paths free it beside the shells.
	*>
	rig::MeshAdjacency adjacency;

	<*
	 The mesh's UV islands, for the Area tool's UV islands part. Read from the
	 source file on first ask, like `adjacency`, and only kept while
	 `uv_islands_geometry` is the geometry it was read for — see `islands_for`.
	 Empty when the file has no texture coordinates or no longer fits the mesh.
	*>
	rig::MeshShells uv_islands;
	uint uv_islands_geometry;
	bool uv_islands_read;

	<*
	 Which joint the binder decided each piece rides, or -1 for a piece it left
	 to the falloff. One entry per shell, owned.

	 An output of the bind rather than a property of the mesh: `rig::rigid_shells`
	 makes the choice for every piece the flood never reached and for every piece
	 that turns out to be one bone's outright, and until this array existed it
	 made it inside `bind_dense` and threw it away. What it buys is that
	 `get_shells` can say *why* a piece is rigid without binding again to find
	 out — and so could a Shells pane, which read them until it went for now.

	 A user's own pin lands here too, since `bind_geodesic` reports what it obeyed
	 as readily as what it decided — so a reader that wants the automatic half
	 asks `doc.attachment_of` first.
	*>
	int[] shell_riders;

	<*
	 That the rig has moved since `shell_riders` was filled, so the indices in it
	 name the wrong bones.

	 Raised by `mark_rig_stale` and lowered by the bind. Joint indices are
	 breadth-first output: adding a dot, deleting one or re-rooting renumbers
	 every joint after it, and an index read across such an edit resolves to a
	 real bone that is not the one the binder chose. Nothing may show a rider
	 while this is up — see `AppState.shell_rider`.
	*>
	bool riders_stale;

	<*
	 Bumped by every `mark_rig_stale`, so a watcher can tell a rig that is still
	 being edited from one that has stopped.

	 A debounce is what wants it — the Joint card's snapshot reads it, and the
	 Shells pane's riders refresh did: `riders_stale` says only that a refresh
	 is owed, and a stream of edits leaves it up the whole time. This moving is
	 what restarts the wait.
	*>
	uint rig_generation;
	uint selected; // dot id, 0 = nothing selected
	SceneSelection scene_selection;

	// Disclosure state shared by every Scene pane. Branches start open; joint
	// ids appear here only after their disclosure mark is closed.
	bool outliner_scene_collapsed;
	bool outliner_model_collapsed;
	bool outliner_skeleton_collapsed;
	DotIdList outliner_collapsed_joints;

	<*
	 The rest of the selection, when more than one dot is selected.

	 `selected` stays the anchor and this holds the others, rather than one list
	 with a designated first entry. Nearly everything that acts on "the
	 selection" acts on exactly one dot — a pin hands vertices to it, the
	 falloff view is a picture of it, a drag moves it — and a flat list would
	 leave each of those choosing an element, and choosing it differently.
	 Deleting and bonding are the operations that genuinely take all of them.

	 The order matters to one of them: `connect_selection` chains the dots in the
	 order they were shift-clicked, anchor first, so this is a list rather than a
	 set.

	 Two invariants, both kept by `forget_stale_ids`: this never holds
	 `selected`, and it is empty whenever `selected` is 0.
	*>
	DotIdList also_selected;

	<*
	 The move the pointer is in the middle of, if any — which dot, where it
	 started, and the axis it has been locked to. See `core/dragging.c3`.

	 Here rather than on the viewport because the keys that steer a move arrive
	 at the tree's root: capturing the pointer does not move keyboard focus, so
	 the widget holding the dot is not the one that hears X pressed.
	*>
	DragState drag;

	<*
	 The other selected dots a rest move is carrying, and where each began.

	 Filled by `begin_drag` when more than one dot is selected and the grabbed one
	 is among them; empty for a lone drag and for every pose or turn, which move one
	 joint only. `drag.dot` leads and these follow it — see `follow_drag_mates`. Held
	 here beside `drag` for the same reason `drag` is on the AppState at all: the
	 keys that steer and end a move arrive at the tree's root, and one copy of the
	 state lets a headless test assert what the whole group did.
	*>
	DragMateList drag_mates;

	<*
	 The Area tool (W): the selected joint's pending part of the mesh, shown on
	 the mesh until Apply writes it as pins or Esc drops it.

	 `area_mask` is one flag per vertex, empty while nothing is picked;
	 `area_twin_mask` is the same part on `area_twin`, the joint across the
	 plane, empty when there is none or mirroring is off. Both are what Apply
	 writes, so the picture and the result cannot disagree. `area_base` is the
	 part a grow or shrink drag started from. `area_solo` is "Also mirror" off,
	 so the zero value mirrors.
	*>
	bool areaing;
	AreaPart area_part;
	AreaPart area_origin; // the ladder part the pending one started as, for the card's dropdown
	uint area_dot;
	uint area_twin;
	sz area_seed;
	bool[] area_mask;
	bool[] area_twin_mask;
	bool[] area_base;
	float area_soft; // fraction of the joint's own bone
	bool area_solo;
	bool area_by_card; // opened by showing the Weights card, so hiding it closes it
	bool area_islands; // the part is whole UV islands, and grows, shrinks and clicks by island
	int area_hover_island; // the island under the pointer while picking islands, or -1
	bool area_paint_adds; // an island paint drag puts islands in, rather than taking them out
	TintMode area_tint;
	uint area_generation; // moves whenever the pending part does, for the card to follow

	<*
	 The current rig's bind with no hand corrections on it, kept so a stroke can
	 redraw the view without rebinding.

	 A bind is the expensive thing in crig and a correction is the cheap one, so
	 caching the half that a stroke does not change is what lets the falloff
	 repaint on every mouse move. Dropped by `mark_rig_stale` — see
	 `painted_bind`, which is the only thing that fills it.
	*>
	float[] base_bind;

	<*
	 How far the stroke in flight has already carried each vertex, 0 to 1.

	 What makes the brush depend on where the circle went rather than on how long
	 it was held there — see `begin_stroke`, which is the only thing that clears
	 it, and `stroke_pull`, which is the only thing that reads it.
	*>
	float[] stroke_seen;

	<*
	 Whether a stroke is between its press and its release, and whether the
	 posed surface fell behind the binding while one was.

	 A stroke over a parked clip reskins the mesh on every move, and the
	 accelerator over it — the mirrored tree, the joint tables, the collision
	 policy — costs more to rebuild than the rest of the frame put together.
	 So `rebind_skin` leaves it standing while the button is down and raises
	 `surface_stale`; `end_stroke` is where the rebuild is paid, once.
	*>
	bool stroke_open;
	bool surface_stale;
	UndoStack undo_stack;
	bool weights_stale;
	float weights_due;
	uint[] tints;
	uint tint_generation;

	<*
	 How many vertices the falloff view's joint holds at least `BLEND_FLOOR` of,
	 counted in the same pass that paints the ramp.

	 How many vertices the falloff view's joint holds: the count `get_weights`
	 reports over the wire, so the screen and the tool agree.

	 Only meaningful while `tint_mode` is FALLOFF; stale otherwise.
	*>
	usz falloff_held;

	<*
	 The document's body plan re-fitted onto this mesh: where the plan wants each
	 of its dots, as against where the dots actually are.

	 A cache, and one that has to stay a cache: `fit_preset` searches the voxel
	 grid around every dot it places, which is far too much to repeat per frame.
	 Two things can move the answer and both are checked before it is read —
	 `plan_fitted` records the plan tag it was built from, and `plan_targets_stale`
	 covers the library arriving after the plan does, which is the order
	 `main` loads them in. The mesh is not one of them: it is built once in
	 `new_app` and borrowed for the life of the state.

	 Both owned. Read through `plan_target`, never directly.
	*>
	FittedDot[] plan_targets;
	String plan_fitted;
	bool plan_targets_stale;

	<*
	 What a deformed mesh is made of, shared by every mode that deforms one.

	 `skin` is the per-vertex influences the GPU skins with, rebound when the rig
	 changes rather than every frame — the binder is the expensive part and the
	 rig usually does not move while a mode runs. `pose_palette` is one matrix per
	 joint and *is* refreshed every frame a clip plays; it is the cheap part,
	 sized by joint count rather than by vertex count.

	 Filled by the animation player or a transient timeline pose draft — see
	 `skinned` in `pose_mode.c3`. The player hands ownership to the draft on the
	 first edit. The
	 renderer skins only while `pose_palette` is non-empty, so dropping it is what
	 puts the body back at rest.
	*>
	bool skin_stale;

	// The countdown `tick_skin` runs while a parked body waits on a rebind —
	// `weights_due`'s twin, set by the same marks.
	float skin_due;
	gltf::SkinBinding skin;

	<*
	 How many joints the joint indices in `skin` name — the rig's joint count at
	 the moment it was bound.

	 Kept beside the binding because it cannot be recovered from one:
	 `SkinBinding` holds four indices per vertex and the largest of them is the
	 last joint anything is *weighted to*, which is not the same number as the
	 last joint in the rig. `engine/scene.c3` sizes three's skin with it, and a
	 skin one joint short is a palette the renderer refuses.
	*>
	uint skin_joints;
	uint skin_generation;
	Matrix4f[] pose_palette;

	// Every replacement of `pose_palette` moves this stamp, and so does every
	// candidate palette a collision check skins — see `next_pose_generation`.
	// Posed occlusion and the collision refit use it to invalidate lazy
	// node/vertex caches without walking either one.
	uint pose_generation;

	// The overlay's behind-the-mesh dimming, remembered per dot and per bone so a
	// running clip does not cast a fresh ray through the deforming body for every
	// one of them on every frame. Exact while the view is still; refreshed a
	// rotating slice at a time while the clock runs — see `overlay_occluded`.
	// `_ready` guards a zero-initialised state (a headless check) that never
	// called `init`.
	HashMap{uint, bool} occlusion_memo;
	bool occlusion_memo_ready;
	uint occlusion_phase;

	// The pose the player built for the frame on screen. A panel that shows one
	// joint's value reads it from here while a clip runs instead of sampling the
	// whole clip a second time — grounding only shifts the root's height, so every
	// other joint holds exactly what a fresh sample would give. `_live` is set the
	// frames the clock is running and the buffer is sized to the rig; a paused,
	// scrubbed or edited pose is sampled fresh.
	rig::Pose player_pose;
	bool player_pose_live;

	// The skeleton and lookups the player builds from the document. Kept across
	// frames while a clip runs and nothing edits the rig — `open_rig` is cheap but
	// not free, and a clip that moves nothing but the clock has no reason to
	// rebuild it. Held valid by `playback_rig_fresh`: any committed edit (the undo
	// revision), any geometry mark (`rig_generation`) or any gesture in flight
	// forces a rebuild, so a stale skeleton or a renamed joint can never be read.
	RigView playback_rig;
	bool playback_rig_built;
	uint playback_rig_revision;
	uint playback_rig_generation;

	<*
	 True for the length of a gesture that began with the skin already in
	 contact. Nothing is blocked then — there is no clear fraction of a move to
	 stop at, and the user is presumably moving *out* — and the report says so
	 rather than the joint refusing to move at all.
	*>
	bool collision_suspended;

	// What the latest checked write met, for the Advanced dialog, the tests
	// and `get_scene`. Reset when a gesture begins. The pane says nothing of
	// it by default; see `show_collision_contacts`.
	CollisionBlock last_block;

	<*
	 What the joints one pose gesture touches held when it began.

	 Escape puts these back, and the release compares against them to record one
	 edit per joint that actually moved. Fixed rather than allocated: a chain is
	 bounded by the run above one joint, and a gesture that leaked would leak once
	 per drag.

	 By dot id, like everything else that outlives a single `RigView`.
	*>
	PosedJoint[POSE_SNAPSHOT] pose_before;
	usz pose_before_count;

	<*
	 What the pinned limbs held when a lock-honoring gesture began.

	 A pose gesture that honors position locks also turns each pinned limb's own
	 chain to hold its foot in place; those joints are snapshotted here so escape
	 restores them and the release banks the whole sit as one edit — the role
	 `pose_before` plays for the grabbed chain, kept apart so the grabbed chain's
	 fixed bound is not spent on pins. By dot id, like `pose_before`.
	*>
	PosedJoint[LOCK_SNAPSHOT] locked_before;
	usz locked_before_count;

	// The other selected joints a G is carrying, and where each began.
	PoseMate[POSE_MATES] pose_mates;
	usz pose_mate_count;

	<*
	 Every joint as the draft held it when a pose gesture began — the body solve
	 (`pose_body`) may move any joint of the figure, the root's slide with them,
	 so escape and the release compare and restore the lot rather than a fixed
	 chain. Owned; freed when the gesture ends.
	*>
	PosedJoint[] gesture_before;

	// Whether a gesture with the feet pinned or planted leaves the body where the
	// pointer puts it rather than keeping its weight over them (`pose_body`). Off
	// by default — balanced — so it is spelt as the exception.
	bool balance_off;

	<*
	 Session-only IK anchors: joints whose posed world position the solver holds
	 while another joint is moved. Locking the feet and pulling the hips is how the
	 figure sits. Editor working memory, like `pose_edit_draft` below — never
	 written to the model, cleared when a document is loaded. See `locks.c3`.
	*>
	PositionLock[] position_locks;

	// Whether `position_locks` was last rebuilt from the editing clip's pins
	// (`sync_clip_pins`), so closing the clip knows to drop them. See `clip_pins.c3`.
	bool pins_from_clip;
	PosedJoint[] pose_edit_draft;

	// Look-at targets being moved, applied to the clip being edited like the pose
	// draft; see `aim_edit.c3`. Owned, cleared with the pose draft.
	AimDraft[] aim_draft;

	// What a target drag began from, for Esc: whether the joint had a draft at the
	// grab, and where the target was then (a fraction of rig height).
	bool aim_drag_drafted;
	Vec3 aim_drag_at;

	<*
	 What the look-at targets turned in the pose the last `gesture_pose` handed
	 out: the joints (that build's indices), the authored rotation each held
	 before the aims, and the aimed one the gesture solved from (`gesture_aimed`,
	 parallel). `unaim_pose` reads them to take the aims back out of what the
	 gesture wrote, and spends them. Owned; freed with the gesture.
	*>
	AimAppliedSet gesture_aim;
	Quaternionf[] gesture_aimed;

	// A turn on an aimed joint measures its sweep from the aimed rotation it began
	// with, not the authored one the snapshot holds: the joint and that rotation.
	uint turn_aimed_dot;
	Quaternionf turn_aimed_was;

	// Timeline-only state. A paused edited clip creates this on the first joint
	// gesture; it deliberately does not touch the rest rig.
	bool pose_edit_active;
	bool pose_edit_pending;
	EditStage stage;

	// The layer of the edited clip that the Animations pane is working on, -1
	// for the base keys. It belongs to `active_layer_ref`: pick another clip and
	// the base is active again (see `AppState.active_layer_of`, layer_edit.c3).
	sz active_layer;
	AnimRef active_layer_ref;

	// A borrowed view of the active keyed layer's keys dressed as a clip, for
	// the key editors (`key_clip`). Never owned, never freed.
	AnimTemplate layer_keys_view;

	// The pose library panel (pose_library.c3): the picked row, whether
	// Apply writes only the selected joints, renaming the picked row, and the
	// name being typed (owned).
	usz pose_library_row;

	// Whole saved-key columns selected in the dopesheet. Times are owned and
	// scoped to the clip reference; see animation_key_selection.c3.
	AnimRef anim_key_selection_ref;
	List{float} anim_key_selection;
	List{AnimChannelKey} anim_channel_key_selection;

	// Look-at target keys picked in the sheet; never held beside the two above.
	List{AimKeyRef} anim_aim_key_selection;

	// The key a range extend measures from — the time of the last key clicked in
	// this selection. A Ctrl+Shift press on another key selects the span between
	// the two. Negative means no anchor yet; reset by `clear_animation_key_selection`.
	float anim_key_anchor;

	// Ghost poses and the selected joint's motion path; see `app/onion.c3`.
	GhostCache ghosts;
	MotionPath motion_path;

	// The Joint mapping dialog's rows while it is open; see joint_mapping.c3.
	MappingDraft mapping_draft;

	// The last Check of the edited clip; see clip_check.c3.
	ClipCheck anim_check;

	// What the contact lane menu is about: a window (-1 for the lane), the
	// lane's first window, and the time pressed; see animation_contacts.c3.
	sz anim_contact_window;
	usz anim_contact_foot;
	float anim_contact_time;

	<*
	 The weights the mesh's own file carried, when the rig came out of it — see
	 `import_rig.c3`. Empty for a rig built here, which is most of them.

	 Held rather than re-read because both the preview and the export ask for it,
	 and it is the whole file's skin: re-parsing a .glb to answer one rebind would
	 cost more than the binder it is standing in for. `doc.skin_from_file` is what
	 says it should be used; this is only what it is.
	*>
	ImportedSkin imported_skin;

	// Whether the imported weights have covered the rig since they were read,
	// and whether the one warning that crig's own now replace them has been said.
	bool imported_skin_covered;
	bool imported_skin_warned;

	<*
	 The animation player: a template-driven full-body animation, running on the
	 rig on screen.

	 A timeline draft replaces the parked player while it is edited, then keying
	 parks the rewritten clip again. Both write through the same `pose_palette`
	 the renderer reads.
	*>
	bool animating;

	<*
	 Whether the running clip's *clock* is stopped, as against playback being off.

	 What a timeline scrub is: the mesh keeps showing the clip, `skinned()` and
	 `rig_locked()` keep answering as they do while it runs, and only
	 `tick_animation` sits out. A scrub that turned `animating` off instead would
	 put the mesh back at rest between drags, which is the one thing the playhead
	 must not do.

	 Cleared by `start_animation` and `stop_animation`, so nothing has to remember
	 to un-pause: the two doors into and out of playback both settle it.
	*>
	bool anim_paused;
	float anim_time;
	AnimTemplate current_anim; // zero value = no animation; copy of the selected template
	AnimRef current_ref; // which pack and clip that copy came from; `{-1,-1}` = neither

	<*
	 The clip being faded out of, while a crossfade is in flight — see
	 `begin_blend`. Zero keyframes means no fade, which is what `blending()` asks.

	 Shallow, exactly as `current_anim` is: the template belongs to the library
	 and this borrows it for the length of the fade. Nothing here is freed.

	 `fade_from_ref` is kept alongside because the two clips need not come from the
	 same pack, and a pack is what says how its clip's joint names spell this rig's.
	*>
	AnimTemplate fade_from;
	AnimRef fade_from_ref;
	float fade_from_time;

	// Seconds left, and how many there were. Both are needed: the fraction is
	// what the blend takes, and a fade cannot report its own progress from a
	// countdown alone.
	float fade_left;
	float fade_span;

	<*
	 The dynamic bones running under the clip, and whether they are running at
	 all — see `app/sim.c3`.

	 Owned and persistent, unlike everything else the player rebuilds each
	 frame: a sim *is* its particle state, so one thrown away between frames
	 would be thrown away before it could show the thing it exists for. Built
	 lazily by `tick_jiggle`, on the first frame of playback that wants it, and
	 released by `AppState.free`.

	 `sim_stale` says the sim no longer describes the document, or that its
	 history has been cut — a seek, a clip change, an edit to the physics. Either
	 way the next frame of playback builds a fresh one, which is also how a chain
	 is primed, so it is the only reset there is.

	 `sim_enabled` is what MCP's `play` turns off for a caller that wants the
	 keyed pose and nothing else. It outlives that one call, which is deliberate:
	 nothing else in the app reads it yet, and a flag that reset itself would
	 make "play it again without the physics" a thing that could not be said.
	*>
	JiggleSim jiggle_sim;
	bool sim_stale;

	<*
	 The surface the chains are held off, as the sim's probe reads it: one
	 flag per triangle of the bound skin for the triangles the chains
	 themselves drive — left out of what a chain is pushed off — the palette
	 the current step is aimed at, borrowed for the length of that step, and
	 the pose generation that palette's posed vertices are cached under. See
	 `AppState.rebuild_jiggle` and `jiggle_surface_probe`.
	*>
	bool[] jiggle_skip;
	Matrix4f[] jiggle_palette;
	uint jiggle_generation;

	<*
	 Which dots sit inside some chain's run, and which chain's — for the
	 overlay's "is this bone dynamic" and the panel's "which chain is this dot
	 part of", both asked per frame, both questions that need the skeleton to
	 answer. Resolved once per change rather than once per ask: the two
	 generations say which rig and which edit to the chains it was built for,
	 and `AppState.is_dynamic` rebuilds it when either has moved.
	 `secondary_generation` is bumped by `jiggle_reset`, which every chain and
	 capsule setter already calls.
	*>
	uint[] dynamic_dots;
	uint[] dynamic_dot_roots;
	uint dynamic_dots_rig;
	uint dynamic_dots_sim;
	bool dynamic_dots_built;
	uint secondary_generation;

	<*
	 Where the running clip has carried each dot, or empty when none is running.

	 The overlay is drawn from this while it is filled, so the rig on screen
	 travels with the body under it instead of standing in the rest pose the clip
	 has left behind. Rebuilt by `refresh_animation` every frame, which already
	 holds the skeleton and the palette — one matrix applied per joint, beside a
	 per-vertex skinning pass on the GPU.

	 Filled by timeline pose drafts as well as by the player, and for the same reason: both
	 are modes the rig is watched in rather than edited in, so the dots are free
	 to leave the positions the document stores. See `Viewport.on_mouse`.

	 Owned. Read through `dot_position`, never directly.
	*>
	PosedDot[] posed_dots;

	<*
	 The look-at targets of the clip on show, built beside `posed_dots` by
	 `refresh_animation` and `refresh_posed`: where each aimed joint stands and
	 where its target is. Owned; freed with the palette in `drop_palette`.
	*>
	AimHandle[] posed_aims;

	<*
	 One entry per lock of that clip: the line from a locked joint to its target's
	 handle in `posed_aims`. Built and freed with it.
	*>
	AimLink[] posed_aim_links;

	// The look-at target whose ring is selected (its name, owned), empty when none.
	// Cleared when a model loads and when the target is removed; see `aim_edit.c3`.
	String aim_target_selected;

	<*
	 What each pack's clips can reach on the rig as it stands — one entry per
	 pack, in the same order, and empty until something asks.

	 The shape match behind it costs a few milliseconds per pack, which is nothing
	 against a rig edit and far too much against a repaint: `clip_applies` is
	 asked once per visible cell per frame. So it is derived once and held, and
	 `reach_stale` is what says the rig has moved out from under it.

	 Owned. Read through `AppState.pack_reach`, never directly — the field may be
	 stale or the wrong length, and that method is where both are settled.
	*>
	PackReach[] pack_reaches;

	<*
	 Whether `pack_reaches` still describes the open rig.

	 Raised by `mark_rig_stale`, which every edit that moves a joint comes through
	 including an undo step, and by `rename_recorded`, which is the one change
	 that leaves every joint where it was and still changes the answer.
	*>
	bool reach_stale;
	bool authored_dirty;

	// The workflow guide's inputs — see `app/guide.c3`. `saved_revision` is the
	// history revision the last save wrote.
	uint saved_revision;
	SkinSurvey skin_survey;
	BoundTally bound_tally;

	<*
	 The Animations pane's rows: one per clip bound to this character. Owned, and
	 here for the reason every other row list is.

	 Labels are borrowed from `doc.animations`, and the trailing text is allocated
	 per row — so anything that binds, unbinds or reorders has to rebuild these
	 before the tree is drawn again, which the panel's own `update` does.
	*>
	TreeRow[] anim_rows;

	<*
	 Which of those rows the pane is acting on.

	 On the state rather than inside the `Tree`, for `editing`'s reason one step
	 further: the pane rebuilds when it splits or changes tab, and it *also*
	 rebuilds whenever playback starts or stops, because `AnimSnapshot` watches
	 which clip is running. A selection living in the widget was therefore thrown
	 back to the first row by the Play button itself — press Play on the third clip
	 and the third clip played while the first row lit up.

	 Kept inside the list by `refresh_anim_rows`, so every button in the pane has a
	 row to act on. Shared by every pane showing the list, which is right: there is
	 one bound set and one clip being worked on, not one per pane.
	*>
	usz anim_selected;

	<*
	 The dopesheet's tracks for whichever clip is being edited. Owned.

	 Here for the reason every other row list is, with one of its own: a track's
	 key times are copied out of the clip rather than viewed into it, because
	 every timeline edit replaces the whole `AnimTemplate` — a slice into the old
	 one would point at freed keyframes the instant anything was dragged.
	*>
	TimelineTrack[] timeline_tracks;

	<*
	 Which clip the Animations pane is editing, and where its playhead is.

	 On the state rather than in the pane for the workspace's usual reason: a pane
	 rebuilds its widgets from nothing when it splits or changes tab, and a
	 playhead that reset every time somebody looked at the 3D view would be
	 useless. `NO_ANIM` means nothing is being edited and the dopesheet is empty.
	*>
	AnimRef editing;
	float edit_time;}

uint generation_counter @local;

<*
 A fresh value for any of a character's generation and revision counters.

 One counter for the whole process rather than one per field per character, so
 two characters can never hold the same number: a watcher that remembers "the
 skin it last drew was generation 7" sees a switch to another character as a
 change, which it is. Never 0, which every watcher reads as "never seen".
*>
fn uint next_generation()
{
	generation_counter++;
	if (generation_counter == 0) generation_counter = 1;
	return generation_counter;
}

<*
 A character over `geometry`, with nothing rigged on it yet.

 The per-character half of what `new_app_with_geometry` used to set up: the
 values that are not the zero value, and the lists that need their allocator
 before the first push. The mesh-derived structures are passed in rather than
 built, so a caller holding a shared cache can lend it.

 @param geometry : `Borrowed by the picker's BVH; it must outlive the character. May be empty.`
 @param source_path : `Where the mesh was loaded from. Empty for one built in memory.`
 @param borrowed : `Whether picker, voxels and shells belong to someone else.`
*>
fn Character new_character(rig::TriMesh geometry, String source_path,
	Picker picker, rig::MeshVoxels voxels, rig::MeshShells shells, bool borrowed)
{
	Character character = {
		.id = next_generation(),
		.picker = picker,
		.voxels = voxels,
		.shells = shells,
		.borrows_geometry_cache = borrowed,
		.geometry = geometry,
		.source_path = source_path,

		// Nothing has been bound yet, so the first time the preview is switched
		// on there is something to compute rather than an empty array to show.
		.weights_stale = true,

		// Same for the binder's rigid choices, which come out of that first bind.
		.riders_stale = true,
		.sim_stale = true,

		// Nothing is playing, and "nothing" is not the zero value: pack 0 is a
		// real pack, so an unset reference would claim its first clip.
		.current_ref = NO_ANIM,
		.editing = NO_ANIM,
		.active_layer = -1,
		.active_layer_ref = NO_ANIM,

		// And again: nothing has been authored, and pack 0 is a real pack whose
		// clips must not be freed and replaced as if an agent had written them.
		.authored_pack = -1,

		// Zero is a real shell id, so "nothing is being pointed at" has to be said
		// with a number that is not one.
		.area_soft = AREA_SOFT_DEFAULT,
		.area_seed = -1,
		.area_hover_island = -1,

		.doc = {
			// On by default: placing a chain of joints is the common case, and
			// having to connect them afterwards doubles the clicks for it.
			.auto_connect = true,

			// The mesh's own middle, not x = 0. crig never normalizes, so a
			// model authored off-origin would otherwise mirror to somewhere
			// outside itself.
			.sym_x = geometry.bounds().center().x,
		},
	};
	// A List has to be given its allocator before anything is pushed, and doing
	// it here rather than lazily means every toggle is a plain push — a lazy
	// init has to ask "is this the first one", and "the list is empty" is also
	// true of a list everything has been unticked from.
	character.also_selected.init(mem);
	character.outliner_collapsed_joints.init(mem);
	character.drag_mates.init(mem);
	character.occlusion_memo.init(mem);
	character.occlusion_memo_ready = true;
	return character;
}

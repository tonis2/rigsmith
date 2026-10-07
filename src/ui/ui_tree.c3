<*
 The interface, as one function a test can call.

 Split out of `main` for exactly one reason: nothing that skips
 `Ui.process_input` can catch a layout that steals the hit test. B4 shipped with
 the control panel covering the entire window — the viewport received no mouse
 events at all — and that passed the headless picking test, the validation
 layers and a screenshot, because none of them dispatch a click. `test/ui_test.c3`
 builds this same tree with no window and pushes synthetic input at it.

 A window menu bar across the top, a tree of panes
 filling everything under it, and each pane carrying its own header for the
 commands that only mean something inside it. The window bar holds what is true
 wherever you are — File, Edit, Help — and the 3D view's header holds the Rig
 and View menus and the tint switch, so a pane showing the animation library
 does not offer to snap a camera it has none of. The stats are drawn on the
 canvas rather than in a panel: the old right-hand panel is gone, its buttons
 are menu items and its status text is the HUD block in the viewport's corner.

 Everything here borrows. The tree holds an `AppState*`, so the state has to
 outlive the Ui and must not be moved after this returns. Menu data lives in
 module globals below for the same reason: cui borrows the item arrays.
*>
module crig;

import cui;
import cui::widgets;
import std::io;
import std::math;
import std::math::vector;


// Still resolved against the working directory, so crig has to be run from its
// own directory. Lives here rather than in main because it is the interface's
// asset, and the test loads it too — glyph metrics decide the menu titles'
// widths, and a layout test against a fontless bar is testing a different bar.
const String FONT_PATH = "assets/DejaVuSans.ttf";


// ---------------------------------------------------------------------------
// Menu actions. All take the Ui and reach the app by type — cui's menu items
// carry `fn void(Ui*)`, the same shape as its Button, and `ui.inherit` is the
// bridge back to crig. Each one is the same operation the keyboard reaches;
// two paths into one implementation, so the menus cannot drift from the keys.

// The File menu is about the scene: the characters on stage and where each
// stands. A scene starts empty (New) or from a file (Open), characters come
// into it from .glb files (Import), and Save writes it all — each character
// into its own model and sidecar, and the scene file that points at them.

fn void menu_new_scene(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.any_character_unsaved())
	{
		ask_before_new_scene(ui);
		return;
	}
	(void)app.new_scene();
	app.refresh_ui();
}

fn void menu_open_scene(Ui* ui)
{
	open_file_dialog(ui, FilePurpose.OPEN_SCENE);
}

// A model into the scene as another character, with its own rig, clips and
// history. Into an empty scene it is simply the first.
fn void menu_import(Ui* ui)
{
	open_file_dialog(ui, FilePurpose.ADD_CHARACTER);
}

// Into the scene file it came from, or asking where the first time. A lone
// character with no scene file saves into its own model and sidecar, which is
// all a scene of one needs: the model reopens it from the recent list.
fn void menu_save(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.has_mesh()) return;
	if (app.scene_path.len == 0 && app.character_count() == 1)
	{
		app.save_session();
		app.refresh_ui();
		return;
	}
	if (app.scene_path.len == 0)
	{
		open_file_dialog(ui, FilePurpose.SAVE_SCENE);
		return;
	}
	String path = app.scene_path.copy(mem);
	defer path.free(mem);
	(void)app.save_scene(path);
	app.refresh_ui();
}

fn void menu_save_as(Ui* ui)
{
	if (!ui.inherit(AppState)!!.has_mesh()) return;
	open_file_dialog(ui, FilePurpose.SAVE_SCENE);
}

// One character: the export panel, which picks the clips and keeps UVs and
// materials. More than one: all of them in one file, with one shared animation.
fn void menu_export(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (!app.has_mesh()) return;
	if (app.character_count() > 1)
	{
		open_file_dialog(ui, FilePurpose.EXPORT_SCENE);
		return;
	}
	open_export_dialog(ui);
}

fn MenuItemFlags query_scene_has_characters(Ui* ui) => { .disabled = !ui.inherit(AppState)!!.has_mesh() };

fn void menu_settings(Ui* ui)
{
	open_settings_dialog(ui);
}

fn void menu_quit(Ui* ui)
{
	// A request, not an exit: widgets do not own the frame loop. main reads it.
	ui.inherit(AppState)!!.quit_requested = true;
}

fn void menu_undo(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.undo();
	app.refresh_ui();
}

fn void menu_redo(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.redo();
	app.refresh_ui();
}

fn void menu_select_all(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.select_all();
	app.refresh_ui();
}

fn void menu_delete(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0) return;
	app.remove_selection();
	app.refresh_ui();
}

fn void menu_set_root(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.selected == 0) return;
	app.set_root(app.selected);
	app.refresh_ui();
}

// The count is worth a notice because the two outcomes are told apart by it
// rather than by the picture: a chain that was bonded and one that was taken
// apart both leave the same dots on screen, and on a dense rig the bones that
// changed are a few pixels among dozens.
fn void menu_connect_selection(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	bool removed;
	usz bones = app.connect_selection(&removed);
	if (bones == 0)
	{
		app.@notice("shift-click two or more joints, then press C to bond them");
	}
	else
	{
		app.@notice("%d bone%s %s", bones, bones == 1 ? "" : "s", removed ? "removed" : "added");
	}
	app.refresh_ui();
}

<*
 Rig > Weight brush: open or close the brush on the selected dot (shift+W).

 The Area tool's sibling, and it refuses on the same terms — a joint to work on
 — and no others: it opens over a parked clip or a pose draft as readily as over
 the rest mesh, since a fold is only visible while the joint is bent.
*>
fn void menu_weight_brush(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	if (app.brushing)
	{
		app.end_brush();
		// The Weights card the brush was opened from takes its part back.
		app.sync_weights_card();
	}
	else if (app.begin_brush())
	{
		// The brush claims a press on the mesh, which the Move and Rotate tools
		// would take for the camera first.
		if (app.transform_interaction.active) (void)app.finish_transform_interaction(false);
		app.transform_tool = SELECT_TOOL;
	}
	else
	{
		app.@notice("select a joint to paint its weights");
	}
	app.refresh_ui();
}

<*
 Why the pinning job would not open, in the words both keys use.

 One wording in one place: the plain letter reaches this refusal by asking for
 the next job along and the shifted one by asking for it outright, and the two
 explaining the same "no" in different sentences is how a keymap starts reading
 like two programs.
*>
fn String lasso_pin_refusal(AppState* app) @private
{
	return app.rig_locked()
		? "the lasso draws on the rest mesh — finish animation editing first"
		: "select a joint to pin vertices to";
}

<*
 Rig > Lasso pin: straight to the pinning job, or out of it (shift+T).

 The only pin the interface offers, and one level finer than the other kind:
 `pin_shell` hands a whole *piece* of the mesh to the selected dot (the MCP
 wire's `edit_rig` attach, and once a Shells pane that has gone for now), shift+T
 hands whichever *vertices* the user draws around. It refuses on the brush's
 terms, and for the brush's reason — the region is gathered against the rest
 mesh.

 The shifted key is a *shortcut*, not a toggle over the whole tool: it lands on
 pinning from anywhere, including from the lasso already open on the other job,
 and only closes the tool when pinning is what was already running. So the pair
 reads as it looks — the plain letter walks the tool along, the shifted one names
 the job it wants.
*>
fn void menu_lasso_mode(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	if (app.lassoing && app.lasso_job == LassoJob.PIN)
	{
		app.end_lasso();
	}
	else if (!app.begin_lasso(PIN))
	{
		app.@notice(lasso_pin_refusal(app));
	}
	app.refresh_ui();
}

<*
 Rig > Lasso select: the lasso's own key, one step along (T).

 Closed opens it selecting joints, selecting switches to pinning, pinning
 switches back — `AppState.advance_lasso` owns the cycle and this owns the words
 for a step that could not be taken.

 Which refusal it is depends on which step was attempted, and the two have
 nothing in common: opening from cold wants circles on screen to draw around,
 while the step onto pinning wants a dot to pin *to* and a body at rest. Asked
 before the call, since afterwards the tool is in the state that makes the
 question unanswerable.
*>
fn void menu_lasso_select(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	bool from_cold = !app.lassoing;
	if (!app.advance_lasso())
	{
		if (from_cold)
		{
			app.@notice(app.show_rig
				? "place a joint before selecting one"
				: "the rig is hidden — press S to bring it back");
		}
		else
		{
			app.@notice(lasso_pin_refusal(app));
		}
	}
	app.refresh_ui();
}

<*
 The tool column's first cell: put every tool away.

 One cell rather than one per tool, and it closes the brush and reach as well as
 the lasso even though the column does not list those two — it means *no tool*,
 which is a statement about all of them. Reach closes the way its own item
 closes it, keeping what the wheel did; escape is the door that puts it back.
*>
fn void menu_tweak(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.transform_interaction.active) (void)app.finish_transform_interaction(false);
	app.end_brush();
	app.end_lasso();
	app.end_area();
	app.end_sketch();
	app.transform_tool = SELECT_TOOL;
	app.refresh_ui();
}

fn void menu_move_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.transform_interaction.active) (void)app.finish_transform_interaction(false);
	app.end_brush();
	app.end_lasso();
	app.end_area();
	app.end_sketch();
	app.transform_tool = MOVE_TOOL;
	app.@notice("%s", transform_tool_hint(app));
	app.refresh_ui();
}

fn void menu_rotate_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.transform_interaction.active) (void)app.finish_transform_interaction(false);
	app.end_brush();
	app.end_lasso();
	app.end_area();
	app.end_sketch();
	app.transform_tool = ROTATE_TOOL;
	app.@notice("%s", transform_tool_hint(app));
	app.refresh_ui();
}

<*
 Rig > Weights panel (W): show the sidebar's Weights card, which opens the Area
 tool on the selected joint, or hide it again.
*>
// Quietly: the card opening is its own answer, and the hint bar carries the keys.
fn void menu_weights_panel(Ui* ui) => joint_panel_tab_pressed(ui, JointPanelTab.WEIGHTS, say: false);

<*
 Open or close the Area tool on the selected joint. Closing
 drops a part still pending; Apply is what writes one.
*>
fn void menu_area_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	if (app.areaing)
	{
		app.end_area();
	}
	else if (app.begin_area())
	{
		if (app.transform_interaction.active) (void)app.finish_transform_interaction(false);
		app.transform_tool = SELECT_TOOL;
	}
	else
	{
		app.@notice(app.has_mesh() ? "select a joint to pick its part of the mesh" : "open a model first");
	}
	app.refresh_ui();
	refresh_joint_panel(ui);
}

<*
 Rig > Sharpen blending: narrow every transition band at once (]).

 The one weight verb that is not about a single dot, which is why it is a plain
 item rather than a mode: there is nothing to select first and nothing to leave.
 `step_sharpness` says what a press is worth and puts the new value on the
 result line, since the change is a few pixels wide at every boundary at once
 and unreadable as a picture until the debounced rebind lands.
*>
fn void menu_sharpen_blend(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.step_sharpness(true);
	app.refresh_ui();
}

<*
 Rig > Make rigid: hand every nearly-rigid vertex to the joint that holds it.

 An op rather than a mode, which is why it has no key: there is nothing to enter
 and nothing to leave, and the whole mesh answers at once. `harden_weights` puts
 the count on the result line either way — the change is one influence per vertex
 disappearing, which shows on screen as almost nothing until something bends.
*>
fn void menu_harden_weights(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.harden_weights();
	app.refresh_ui();
}

<*
 Rig > Smooth weights: soften the seams where two joints meet.

 Harden's opposite number and the other half of the pair — one makes the flat
 regions flatter, the other widens the steps between them — so the two sit
 together and neither takes a key.
*>
fn void menu_smooth_boundaries(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.smooth_boundaries();
	app.refresh_ui();
}

// Rig > Soften blending ([): the same step the other way, back toward the
// binder's own blend and no further.
fn void menu_soften_blend(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.step_sharpness(false);
	app.refresh_ui();
}

fn void menu_auto_connect(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.doc.auto_connect = !app.doc.auto_connect;
	app.refresh_ui();
}

// Worth a notice rather than leaving the user to spot the difference: the two
// halves of what this does look identical on screen — a twin that was created
// and one that was pulled into line both end up in the right place — and which
// of the two happened is the difference between building a rig and repairing
// one.
fn void menu_mirror_selection(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	usz moved;
	usz square;
	usz unmatched;
	bool painted;
	usz total = app.mirror_selection(&moved, &square, &unmatched, &painted);
	// A rest-rig edit under a posed body, the way a history step is: the twins
	// that were squared change the rig the palette was built for, so the body on
	// screen is rebuilt before the notice rather than left showing the old rig
	// until the playhead moves.
	if (total > 0) app.refresh_pose_display();
	if (total > 0 && unmatched > 0)
	{
		app.@notice("pulled %d joint%s into line%s — %d had no twin to mirror onto, left alone",
			moved, moved == 1 ? "" : "s", paint_crossed(painted), unmatched);
	}
	else if (total > 0)
	{
		app.@notice("pulled %d joint%s into line with the selection%s", moved, moved == 1 ? "" : "s", paint_crossed(painted));
	}
	else if (unmatched > 0)
	{
		// The one thing Mirror does not do is build the missing side. Say so
		// plainly rather than leaving a stray joint behind, which is what placing
		// a twin here turned a mistyped or half-named rig into.
		app.@notice("no twin to line up — %d selected joint%s with no other side. Symmetrize lines an existing joint up; right-click › Mirror joint builds the other side",
			unmatched, unmatched == 1 ? "" : "s");
	}
	else if (square > 0)
	{
		// The rig is already symmetric here, which used to be reported as if
		// nothing were selected — the words that sent someone who had just
		// mirrored a rig looking for a different selection.
		app.@notice("already mirrored — the other side of %d joint%s is in place, nothing to change",
			square, square == 1 ? "" : "s");
	}
	else
	{
		app.@notice("nothing to mirror — select joints off the symmetry plane first");
	}
	app.refresh_ui();
}

// The tail of a mirror notice when hand-painted weight went across with the
// dots. Said out loud because it is the half of the mirror nothing on screen
// shows unless the falloff view happens to be on the twin.
fn String paint_crossed(bool painted) @private => painted ? " — weight paint crossed too" : "";

// ---------------------------------------------------------------------------
// Viewport right-click context menu
//
// Delete and Mirror on the current selection, raised by a right-press in the
// viewport (see Viewport.on_mouse). The same two acts the menu bar carries,
// brought to the cursor — except Mirror here is the *building* mirror that
// creates the other side (`mirror_create_selection`), as against the menu bar's
// M-key mirror that only lines an existing twin up and never invents one.

const String VIEWPORT_CONTEXT_ID = "viewport-context";

<*
 Raise the viewport context menu at a point in UI coordinates.

 The caller has already made sure something is selected — the menu acts on the
 selection, and an empty one has nothing to offer.
*>
fn void open_viewport_context(Ui* ui, Vec2 at, bool from_ring = false)
{
	AppState* app = ui.inherit(AppState)!!;
	app.aim_menu_from_ring = from_ring;
	Element* elem = ui.find_id(VIEWPORT_CONTEXT_ID)!!;
	Dialog* menu = elem.widget_as(Dialog);
	menu.at = at;
	menu.placed = true;
	// Closed first so a menu already up is rebuilt from the selection it now has.
	menu.set_open(elem, false);
	menu.set_open(elem, true);
}

fn void viewport_context_delete(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, VIEWPORT_CONTEXT_ID, false);
	if (app.selected == 0) return;
	usz gone = app.remove_selection();
	if (gone > 0) app.@notice("deleted %d joint%s", gone, gone == 1 ? "" : "s");
	app.refresh_ui();
}

fn void viewport_context_mirror(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	set_dialog_open(ui, VIEWPORT_CONTEXT_ID, false);

	usz made;
	usz moved;
	usz already;
	usz skipped;
	bool painted;
	usz named;
	usz total = app.mirror_create_selection(&made, &moved, &already, &skipped, &painted, &named);
	// A rest-rig edit under a posed body, the way a history step is: the twins that
	// were made or squared change the rig the palette was built for, so the body on
	// screen is rebuilt before the notice rather than left showing the old rig.
	if (total > 0) app.refresh_pose_display();

	// The skipped joints are always counted when anything else happened, because
	// that is the answer to "why did only some of my selection mirror": a joint on
	// the centre line is its own other side. Joints that had no side in the name
	// were given one, and the notice says so, since their names changed.
	String tail = string::tformat("%s%s",
		named > 0 ? string::tformat(" · gave %d joint%s a side in the name", named, named == 1 ? "" : "s") : "",
		skipped > 0 ? string::tformat(" — %d on the centre line, skipped", skipped) : "");

	if (made > 0 && moved > 0)
	{
		app.@notice("mirrored %d joint%s and squared %d already there%s%s", made, made == 1 ? "" : "s",
			moved, paint_crossed(painted), tail);
	}
	else if (made > 0)
	{
		app.@notice("mirrored %d joint%s to the other side%s%s", made, made == 1 ? "" : "s", paint_crossed(painted), tail);
	}
	else if (moved > 0)
	{
		app.@notice("pulled %d existing twin%s into line%s%s", moved, moved == 1 ? "" : "s", paint_crossed(painted), tail);
	}
	else if (skipped > 0)
	{
		// Nothing built or moved: the whole selection sits on the centre line.
		app.@notice("nothing to mirror — %d selected joint%s on the centre line, which is its own other side",
			skipped, skipped == 1 ? " is" : "s are");
	}
	else if (already > 0)
	{
		app.@notice("already mirrored — the other side of %d joint%s is in place", already, already == 1 ? "" : "s");
	}
	else
	{
		app.@notice("nothing to mirror — select joints off the symmetry plane first");
	}
	app.refresh_ui();
}

// The counts are the message, not decoration. A shape match is a guess, and how
// much of the plan it covered is the only thing separating a rig that will play
// correctly from one that matched a spine and two arms — which looks identical
// from here, because both come back with names on the dots.
<*
 Rig > Apply body plan — the same panel a skinless import raises.

 One panel for both, because whatever taught the user the verb it is the same
 verb. From the menu it is a deliberate act rather than an announcement, which is
 why the panel's list preselects a row and its confirming button carries the
 weight rather than the title.
*>
fn void menu_apply_body_plan(Ui* ui)
{
	open_rig_prompt(ui);
}

fn void menu_auto_name(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;

	AutoNaming named = app.auto_name();
	if (named.total == 0)
	{
		app.@notice("no body plan to name against — add a library that holds one");
	}
	else if (!named.usable())
	{
		app.@notice("%s fits only %d of %d joints — nothing renamed",
			named.plan, named.matched, named.total);
	}
	else if (named.unnamed > 0)
	{
		app.@notice("%s · named %d joints, %d of %d in the plan · %d joint%s the plan has no name for",
			named.plan, named.renamed, named.matched, named.total,
			named.unnamed, named.unnamed == 1 ? "" : "s");
	}
	else
	{
		app.@notice("%s · named %d joints, %d of %d in the plan",
			named.plan, named.renamed, named.matched, named.total);
	}
	app.refresh_ui();
}

fn void menu_rename_dot(Ui* ui)
{
	begin_joint_rename(ui);
}

fn void menu_weights(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.toggle_weights();
	app.refresh_ui();
}

fn void menu_falloff(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.toggle_falloff();
	app.refresh_ui();
}

<*
 Wireframe on or off. The refresh is not decoration: the overlay stops dimming
 occluded dots in wireframe, so the dots have to be repainted with the mesh.
*>
fn void menu_wireframe(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.set_shading(app.wireframe() ? app.fill_shading : ShadingMode.WIREFRAME);
	app.refresh_ui();
}

<*
 The three shading buttons, and the View menu's radio of the same: the model in
 plain grey, in its own textures, or as its edges.
*>
fn void menu_shading_solid(Ui* ui) => set_viewport_shading(ui, ShadingMode.SOLID);
fn void menu_shading_textured(Ui* ui) => set_viewport_shading(ui, ShadingMode.TEXTURED);
fn void menu_shading_wireframe(Ui* ui) => set_viewport_shading(ui, ShadingMode.WIREFRAME);

fn void set_viewport_shading(Ui* ui, ShadingMode mode) @private
{
	AppState* app = ui.inherit(AppState)!!;
	app.set_shading(mode);
	app.refresh_ui();
}

<*
 The mesh on or off. Nothing but the renderer reads this — `engine/scene.c3`
 hands three no mesh for a hidden body — so the refresh is for the overlay, which
 stops dimming dots the moment there is no skin left to be behind.
*>
fn void menu_show_mesh(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.show_mesh = !app.show_mesh;
	app.refresh_ui();
}

<*
 The rig overlay on or off. Takes the dots away from the pointer as well as from
 the eye — `Viewport.pick_dot` answers nothing while it is off — so this is the
 one display toggle that changes what a click does.
*>
fn void menu_show_rig(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.show_rig = !app.show_rig;
	app.refresh_ui();
}

<*
 The physics marks on the overlay on or off: the ring on a dynamic joint, the
 tint on the bones between them, and the circle saying how fat a collider is.
 Nothing about what is simulated changes — the Physics pane's own Simulate box is
 what does that.
*>
fn void menu_show_physics(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.show_physics = !app.show_physics;
	app.refresh_ui();
}

<*
 Joint names over the dots on or off. Like wireframe, the refresh is what
 repaints the overlay — nothing about the mesh or the document has changed.
*>
fn void menu_joint_names(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.show_joint_names = !app.show_joint_names;
	app.refresh_ui();
}

<*
 The selected-joint settings card (the N-panel) on or off. The card builds to
 nothing on its own when no joint is selected; this is the toggle that hides it
 even when one is, and shows it again — bound to N, like Blender's.
*>
fn void menu_show_joint_panel(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.show_joint_panel = !app.show_joint_panel;
	app.sync_weights_card();
	app.@notice(app.show_joint_panel ? "joint panel shown (N)" : "joint panel hidden (N)");
	app.refresh_ui();
}

<*
 The workflow guide bar (and the hint bar's "Next:" line) on or off, remembered
 in the config.
*>
fn void menu_workflow_guide(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.hide_guide = !app.config.hide_guide;
	app.config.save();
	app.refresh_ui();
}

fn MenuItemFlags query_workflow_guide(Ui* ui) => { .checked = !ui.inherit(AppState)!!.config.hide_guide };

// The Generate pane on screen, the caret in its prompt.
fn void menu_generate_motion(Ui* ui) => open_generate_panel(ui);

fn MenuItemFlags query_generate_motion(Ui* ui) => { .checked = find_leaf_showing(area_layout.root, GENERATE_VIEW) != null };

<*
 The floor grid under the model on or off, remembered in the config.
*>
// The body plan's joint limits rebuilt on the rig as placed — see
// `AppState.reapply_plan_limits`.
fn void menu_reapply_plan_limits(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	sz landed = app.reapply_plan_limits();
	if (landed < 0)
	{
		app.@notice("this rig has no body plan with limits · apply one from Rig › Apply body plan");
	}
	else
	{
		app.@notice("joint limits re-applied from the %s plan on %d joints · Ctrl+Z undoes", app.doc.plan, (int)landed);
	}
	app.refresh_ui();
}

fn void menu_show_floor(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.config.hide_floor = !app.config.hide_floor;
	app.config.save();
	app.refresh_ui();
}

fn MenuItemFlags query_show_floor(Ui* ui) => { .checked = !ui.inherit(AppState)!!.config.hide_floor };

// The animation aids: onion-skin ghosts of the mesh around the playhead (tuned in
// the floating Ghosts panel the transport row's button opens) and the selected
// joint's path. Remembered in the config like the floor.
fn void menu_ghosts(Ui* ui) => anim_ghosts_toggled(ui, !ui.inherit(AppState)!!.config.show_ghosts);
fn MenuItemFlags query_ghosts(Ui* ui) => { .checked = ui.inherit(AppState)!!.config.show_ghosts };

fn void menu_ghost_settings(Ui* ui) => set_dialog_open(ui, ANIM_GHOSTS_DIALOG_ID, true);

fn void menu_motion_path(Ui* ui) => anim_path_toggled(ui, !ui.inherit(AppState)!!.config.show_motion_path);
fn MenuItemFlags query_motion_path(Ui* ui) => { .checked = ui.inherit(AppState)!!.config.show_motion_path };

// The presets (M2). `apply_preset` refreshes the interface itself, the way the
// session load does — it replaces the whole rig rather than nudging it.
fn void menu_view_front(Ui* ui) => snap_view(ui, ViewAxis.POS_Z);
fn void menu_view_back(Ui* ui) => snap_view(ui, ViewAxis.NEG_Z);
fn void menu_view_right(Ui* ui) => snap_view(ui, ViewAxis.POS_X);
fn void menu_view_left(Ui* ui) => snap_view(ui, ViewAxis.NEG_X);
fn void menu_view_top(Ui* ui) => snap_view(ui, ViewAxis.POS_Y);
fn void menu_view_bottom(Ui* ui) => snap_view(ui, ViewAxis.NEG_Y);

<*
 Starts the quarter-second turn onto an axis view — the View menu, the gizmo and
 the 1/3/7 keys on either the numpad or the top row all land here.

 The camera is provided separately from the state that contains it, so a view
 command reaches exactly the thing it steers and nothing else.

 The invalidation is for the frame, not for the pixels: `snap_to` only sets the
 turn up, and `AppRoot.update` eases it. Without a frame scheduled here the loop
 can sleep before running the first `advance`.

 @param axis : `Which face to end up looking at.`
*>
fn void snap_view(Ui* ui, ViewAxis axis)
{
	// The camera of the last 3D View used — `app.camera` is always that one.
	ui.inherit(OrbitCamera)!!.snap_to(axis);
	ui.invalidate(OrbitCamera);
}

<*
 Dismisses every open dropdown, wherever it hangs from.

 While a menu is open its bar covers the space it owns with a catcher, and a
 press that reaches that catcher closes the menu instead of acting. Two kinds of
 press never reach it: one on a widget built *after* the bar (the tint strip
 sits above its own bar's catcher), and one landing outside the bar's reach at
 all — a 3D view's header only blankets its own pane, so a click in the pane
 next door leaves its dropdown hanging.

 Every bar, not the one that owns the click: with a header per pane there is no
 way to tell from here which dropdown is the stale one, and closing a menu that
 was already closed costs nothing.
*>
fn void close_menus(Ui* ui)
{
	ui.@each(MenuBar; bar) { bar.widget_as(MenuBar).close(bar); };
	// The plan chooser too. Its catcher is placed against the window, so a pane
	// clips it and a press in the next pane never reaches it — the same reason
	// the bars above need saying twice.
	ui.@each(Select; chooser) { chooser.widget_as(Select).close(chooser); };
}

<*
 Help > Controls: show or hide the key reference.

 The dialog holds its own open state, so there is nothing on the AppState to
 keep in step — `query_controls_shown` reads the widget back for the check mark,
 and the dialog's own close button and ESC go through the same `set_open` this
 does.

 **By id, not by type.** There is more than one `Dialog` in the tree now, and
 `ui.find(Dialog)` answers with the first in tree order — which would leave this
 item toggling whichever dialog happened to be built first.
*>
fn void menu_toggle_controls(Ui* ui)
{
	if (try Element* dialog = ui.find_id(CONTROLS_DIALOG_ID))
	{
		dialog.widget_as(Dialog).toggle(dialog);
	}
}

// ---------------------------------------------------------------------------
// Item state, polled by cui each time a dropdown opens — so a check mark set by
// the keyboard is already right the next time the menu drops.

// Two dots, not one: bonding is the operation that needs a pair, and greying it
// on a single selection is what says so before the click rather than after.
fn MenuItemFlags query_connectable(Ui* ui) => { .disabled = ui.inherit(AppState)!!.selection_count() < 2 };
// Lit while the sidebar shows the Weights card.
fn MenuItemFlags query_weights_panel(Ui* ui) => { .checked = ui.inherit(AppState)!!.weights_card_open() };

// Greyed only without a dot to paint. Not while the rig is locked: the stroke
// reads the body on screen, posed or not, so a bent joint is somewhere to
// paint rather than a reason to wait.
fn MenuItemFlags query_brushing(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .checked = app.brushing, .disabled = app.selected == 0 };
}

// Greyed without a dot, like the brush, and while the rig is locked besides: a
// region has to be handed to some dot, and it is still gathered against the
// rest mesh. Lit for the pinning job alone — the lasso being open is not the
// question this item asks.
<*
 The tool column's Sketch cell: draw on the viewport to show the agent what is
 wrong. Red marks a fault, green a keeper, blue a note, and the eraser takes a
 mark off — all picked in the strip across the top while sketching. No keys, on
 purpose. A stroke is one mark and the agent reads them with get_annotations.
*>
fn void menu_sketch(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.sketching)
	{
		app.end_sketch();
	}
	else
	{
		app.begin_sketch();
		app.hide_annotations = false;
		app.@notice("Sketch: drag on the viewport to draw. Pick a colour or the eraser in the strip at the top.");
	}
	app.refresh_ui();
}

fn void menu_show_sketches(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	app.hide_annotations = !app.hide_annotations;
	app.refresh_ui();
}

fn void menu_clear_sketches(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	usz gone = app.clear_annotations();
	app.@notice("Cleared %d sketch%s.", gone, gone == 1 ? "" : "es");
	app.refresh_ui();
}

fn MenuItemFlags query_sketching(Ui* ui) => { .checked = ui.inherit(AppState)!!.sketching };
fn MenuItemFlags query_show_sketches(Ui* ui) => { .checked = !ui.inherit(AppState)!!.hide_annotations };
fn MenuItemFlags query_has_sketches(Ui* ui) => { .disabled = ui.inherit(AppState)!!.annotations.len() == 0 };

fn MenuItemFlags query_lasso(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return {
		.checked = app.lassoing && app.lasso_job == LassoJob.PIN,
		.disabled = app.selected == 0 || app.rig_locked(),
	};
}

// The other job, greyed on what *it* needs instead: circles to draw around. It
// asks for no selection and does not care whether the rig is locked, which is the
// whole difference between reading the screen and writing the bind.
fn MenuItemFlags query_lasso_select(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return {
		.checked = app.lassoing && app.lasso_job == LassoJob.SELECT,
		.disabled = app.doc.dots.len() == 0 || !app.show_rig,
	};
}

<*
 Whether no tool is running — the tool column's first cell.

 "None of the three that claim a drag over the model", which is a narrower
 statement than it looks: with the brush open this is false and *no* cell in the
 column is lit, because the column does not list the brush. A cell that lit up
 for "not my tools" would be claiming the drag it does not have.
*>
fn MenuItemFlags query_tweak(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .checked = !app.lassoing && !app.brushing && !app.areaing && !app.sketching
		&& app.transform_tool == SELECT_TOOL };
}

fn MenuItemFlags query_move_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .checked = !app.lassoing && !app.brushing && !app.areaing && !app.sketching
		&& app.transform_tool == MOVE_TOOL };
}

fn MenuItemFlags query_rotate_tool(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .checked = !app.lassoing && !app.brushing && !app.areaing && !app.sketching
		&& app.transform_tool == ROTATE_TOOL };
}

<*
 The two cleanup ops, which want a mesh, a rig and a body at rest.

 All three greyed rather than left to refuse, for `query_lasso`'s reason: they
 read the bind as the screen has it, so there is nothing to read without a mesh
 or without dots, and a bind against a posed body describes shares nobody is
 looking at. The ops say the same three things out loud — a menu is not the only
 door — but the item is where a user finds out before clicking.
*>
fn MenuItemFlags query_weight_ops(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .disabled = !app.has_mesh() || app.doc.dots.len() == 0 || app.rig_locked() };
}

// The camera items want a 3D View to show the turn in.
fn MenuItemFlags query_has_view(Ui* ui)
{
	if (try ui.find(Viewport)) return { };
	return { .disabled = true };
}

fn MenuItemFlags query_auto_connect(Ui* ui) => { .checked = ui.inherit(AppState)!!.doc.auto_connect };
fn MenuItemFlags query_selection(Ui* ui) => { .disabled = ui.inherit(AppState)!!.selected == 0 };

// Set root wants a selection like the rest, and wants the rig unlocked besides:
// re-rooting re-parents every joint, and a pose is a set of parent-relative
// rotations, so doing it mid-pose would silently reinterpret every one of them.
// Greyed rather than left to refuse, so the reason is visible before the click.
fn MenuItemFlags query_set_root(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .disabled = app.selected == 0 || app.rig_locked() };
}
// Symmetrize wants a selection and nothing else: it moves rest joints (never
// adds one), under a parked clip as readily as at rest, since
// `menu_mirror_selection` rebuilds the body on screen for the rig it made.
fn MenuItemFlags query_mirror_selection(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return { .disabled = app.selected == 0 };
}
fn MenuItemFlags query_any_dots(Ui* ui) => { .disabled = ui.inherit(AppState)!!.doc.dots.len() == 0 };
// A plan is fitted to a mesh's bounding box and snapped against its voxels, so
// with no mesh there is nothing to fit one to — the same reason `--preset`
// refuses on the command line.
fn MenuItemFlags query_any_mesh(Ui* ui) => { .disabled = !ui.inherit(AppState)!!.has_mesh() };
fn MenuItemFlags query_undo(Ui* ui) => { .disabled = !ui.inherit(AppState)!!.undo_stack.can_undo() };
fn MenuItemFlags query_redo(Ui* ui) => { .disabled = !ui.inherit(AppState)!!.undo_stack.can_redo() };
<*
 The two tint views, whose greying rule is the same in shape: entering needs
 something to colour by, leaving is always allowed. A view left on while its
 subject disappears is turned off by its own toggle, not blocked by this.

 Read by the Rig and View dropdowns and by the icon strip on the bar, which is
 what keeps the two from drifting.
*>
fn MenuItemFlags query_weights(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return {
		.checked = app.tint_mode == TERRITORY,
		.disabled = app.tint_mode != TERRITORY && app.doc.dots.len() == 0,
	};
}

<*
 Falloff shows one joint — the selected one — so entering with no selection is
 meaningless and the item says so by greying out, the same rule the F key
 notices for. A rig with no dots has no selection either, so this covers the
 empty document too.
*>
fn MenuItemFlags query_falloff(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	return {
		.checked = app.tint_mode == FALLOFF,
		.disabled = app.tint_mode != FALLOFF && app.selected == 0,
	};
}

<*
 Is this clip worth clicking, and is it the one playing?

 `disabled` is `AppState.clip_playable` — either the rig can carry the clip
 already, or the document is empty and the pack can supply a rig to carry it.
 `checked` is what the Animations view paints as the playing highlight, and what
 its click reads to decide play or stop.

 The playing test compares the *reference* rather than the name. One pack per
 body plan puts a "Walk" in most of them, so a name comparison lights every
 walk in the library at once. A template started from outside the library
 carries no reference, and falls back to the name for want of anything better.
*>
fn MenuItemFlags clip_flags(AppState* app, AnimRef ref)
{
	AnimTemplate* anim = app.clip(ref);
	if (!anim) return { .disabled = true };

	bool playing = app.animating && (app.current_ref.valid()
		? app.current_ref.same(ref)
		: app.current_anim.name == anim.name);

	return { .disabled = !app.clip_playable(ref), .checked = playing };
}

// The dialog is the state: an item that reads the widget cannot disagree with
// what is on screen, whichever way it was last closed. By id for the reason
// `menu_toggle_controls` gives — the tree holds more than one Dialog.
fn MenuItemFlags query_controls_shown(Ui* ui)
{
	if (try Dialog* dialog = ui.get_widget_id(CONTROLS_DIALOG_ID, Dialog)) return { .checked = dialog.open };
	return { };
}

<*
 Export greys out with no model at all — and only then.

 An empty *rig* is deliberately still clickable: `export_rig` answers it with
 "place some dots first", which tells the user what to do next, where a greyed
 item tells them nothing. Greying is the hint and the operation is the guard.
 With no model there is nothing to hint about: the view already says so in the
 middle of the screen.
*>
// Never greyed, unlike the tint views: drawing the surface as lines needs
// no rig, no selection and nothing bound — there is always a mesh to draw.
fn MenuItemFlags query_wireframe(Ui* ui) => { .checked = ui.inherit(AppState)!!.wireframe() };
fn MenuItemFlags query_shading_solid(Ui* ui) => { .checked = ui.inherit(AppState)!!.config.viewport_shading == ShadingMode.SOLID };
fn MenuItemFlags query_shading_textured(Ui* ui) => { .checked = ui.inherit(AppState)!!.config.viewport_shading == ShadingMode.TEXTURED };

// Checked when the thing is *shown*, so the mark reads as "this is on screen"
// rather than as "this is suppressed" — a hidden half is an unticked box, which
// is the reading a menu full of view toggles has already taught.
fn MenuItemFlags query_show_mesh(Ui* ui) => { .checked = ui.inherit(AppState)!!.show_mesh };
fn MenuItemFlags query_show_rig(Ui* ui) => { .checked = ui.inherit(AppState)!!.show_rig };
fn MenuItemFlags query_show_joint_panel(Ui* ui) => { .checked = ui.inherit(AppState)!!.show_joint_panel };

// Greyed on a rig the physics owns nothing on, the way the weight views grey
// with no weights: the marks are drawn over dynamic bones and capsules, and with
// neither there is nothing for the toggle to show or hide.
fn MenuItemFlags query_show_physics(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.doc.secondary.len() == 0 && app.doc.colliders.len() == 0) return { .disabled = true };
	return { .checked = app.show_physics };
}

<*
 Joint names grey out with nothing to name.

 Only hand-placed dots are unnamed, so a rig with dots but no names is one built
 entirely by clicking, and the toggle would do nothing visible on it. Leaving is
 always allowed, the same rule the tint views follow.
*>
fn MenuItemFlags query_joint_names(Ui* ui)
{
	AppState* app = ui.inherit(AppState)!!;
	if (app.show_joint_names) return { .checked = true };

	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len > 0) return { };
	}
	return { .disabled = true };
}

// ---------------------------------------------------------------------------
// The menus. Module globals rather than locals because cui borrows these
// arrays for the lifetime of the widget; `menus` is stitched together in
// `build_ui` because a global initializer cannot slice another global.
//
// One bar for the window. Rig and View act on the document and on the camera of
// the last 3D View used, so they stay reachable while no 3D View is showing; the
// camera items grey when there is none (`query_has_view`).

// The key reference's own dialog. Named here because two dialogs now live in
// the tree and every lookup for either has to say which — see
// `menu_toggle_controls`.
const String CONTROLS_DIALOG_ID = "controls-dialog";

MenuItem[12] file_items = {
	{ .label = "New scene", .shortcut = "Ctrl+N", .on_select = &menu_new_scene },
	{ .label = "Open scene…", .shortcut = "Ctrl+O", .on_select = &menu_open_scene },
	{ .separator = true },
	{ .label = "Import .glb…", .shortcut = "Ctrl+I", .on_select = &menu_import },
	{ .separator = true },
	{ .label = "Save", .shortcut = "Ctrl+S", .on_select = &menu_save, .state = &query_scene_has_characters },
	{ .label = "Save as…", .shortcut = "Ctrl+Shift+S", .on_select = &menu_save_as, .state = &query_scene_has_characters },
	{ .label = "Export .glb…", .shortcut = "Ctrl+E", .on_select = &menu_export, .state = &query_scene_has_characters },
	{ .separator = true },
	// Above Quit rather than in a menu of its own: one panel of settings does not
	// earn a top-level title, and the asset libraries it holds are the same kind
	// of thing as the recent scenes the File menu already remembers.
	{ .label = "Settings", .on_select = &menu_settings },
	{ .separator = true },
	{ .label = "Quit", .on_select = &menu_quit },
};

// Select all sits above the two that consume a selection, since that is the
// order they are used in. It greys on an empty document rather than on an empty
// selection: it is the item that *makes* one.
MenuItem[6] edit_items = {
	{ .label = "Undo", .shortcut = "Ctrl+Z", .on_select = &menu_undo, .state = &query_undo },
	{ .label = "Redo", .shortcut = "Ctrl+Y", .on_select = &menu_redo, .state = &query_redo },
	{ .separator = true },
	{ .label = "Select all", .shortcut = "Ctrl+A", .on_select = &menu_select_all, .state = &query_any_dots },
	{ .label = "Delete selected", .shortcut = "X", .on_select = &menu_delete, .state = &query_selection },
	{ .label = "Set root", .shortcut = "Ctrl+R", .on_select = &menu_set_root, .state = &query_set_root },
};

// The Rig menu holds the modes and the previews, and — first — the one verb a
// mesh with no skeleton needs.
//
// Body plans used to be deliberately absent here, on the grounds that they come
// out of whichever pack the user picks in the library, because the file carrying
// a clip is the only thing that knows which joints that clip needs. That is
// still true of *which* plan, and it turned out to be the wrong conclusion about
// *where the verb lives*: a game developer opening their own untextured T-pose
// looks in the menus for "rig this", finds nothing, and has no reason to think a
// cell in the Assets pane is the answer. So the item is here and it opens the
// same panel a skinless import raises, which still gets its list from the packs.
// The Assets route is unchanged.
MenuItem[19] rig_items = {
	{ .label = "Apply body plan…", .on_select = &menu_apply_body_plan, .state = &query_any_mesh },
	{ .label = "Rotate skeleton…", .on_select = &open_skeleton_rotation_dialog, .state = &query_any_dots },
	{ .label = "Re-apply plan limits", .on_select = &menu_reapply_plan_limits, .state = &query_any_dots },
	{ .separator = true },
	{ .label = "Connect selected", .shortcut = "C", .on_select = &menu_connect_selection, .state = &query_connectable },
	// The two jobs of one tool, adjacent and in the order the plain letter walks
	// them. Both are listed even though a single cell in the tool column covers
	// them both: a glyph says which job is running, and only a name says what the
	// job is.
	{ .label = "Lasso select", .shortcut = "T", .on_select = &menu_lasso_select, .state = &query_lasso_select },
	// Above the brush rather than beside it, because it is a pin, not a weight:
	// it hands whichever vertices you draw around to the selected dot for good.
	// It keeps shift+T from when a coarser pin — a whole piece of the mesh on a
	// click, later a Shells pane's row — had the plain letter; that pane is gone
	// for now and the piece-sized pin is the MCP wire's alone.
	{ .label = "Lasso pin", .shortcut = "shift+T", .on_select = &menu_lasso_mode, .state = &query_lasso },
	{ .label = "Weights panel", .shortcut = "W", .on_select = &menu_weights_panel, .state = &query_weights_panel },
	{ .label = "Weight brush", .shortcut = "shift+W", .on_select = &menu_weight_brush, .state = &query_brushing },
	// With the two above rather than beside the weight previews below: all three
	// change what the bind says without moving a dot, and these are the pair that
	// says it about the whole model at once. Greyed on an empty document, since a
	// sharpness is a power applied to weights and there are none.
	{ .label = "Sharpen blending", .shortcut = "]", .on_select = &menu_sharpen_blend, .state = &query_any_dots },
	{ .label = "Soften blending", .shortcut = "[", .on_select = &menu_soften_blend, .state = &query_any_dots },
	// Under the pair above, since all four change what the bind says without
	// moving a dot — but these two are ops rather than settings: they read the
	// bind once and write the answer down. No keys, because a key invites the
	// repeat that a baked result does not want by accident.
	{ .label = "Make rigid", .on_select = &menu_harden_weights, .state = &query_weight_ops },
	{ .label = "Smooth weights", .on_select = &menu_smooth_boundaries, .state = &query_weight_ops },
	{ .label = "Auto-connect", .shortcut = "A", .on_select = &menu_auto_connect, .state = &query_auto_connect },
	{ .label = "Symmetrize selected", .shortcut = "M", .on_select = &menu_mirror_selection, .state = &query_mirror_selection },
	// Both name joints, and they are the two halves of it: the plan names what it
	// has a joint for, and this names everything it does not — a tail, a prop, a
	// third arm. Beside each other because a user who has just been told "3 dots
	// the plan has no joint for" is one keystroke from dealing with them.
	{ .label = "Auto-name joints", .on_select = &menu_auto_name, .state = &query_any_dots },
	// No key: the name is edited on the Joint card, where the Rename button
	// beside the title does what this does. R is the turn, and only the turn.
	{ .label = "Rename joint", .on_select = &menu_rename_dot, .state = &query_selection },
	{ .separator = true },
	{ .label = "Weight preview", .on_select = &menu_weights, .state = &query_weights },
};

// Six ways to point the camera, then five ways to draw what it points at, then
// the rig overlay's own annotation. The second group runs outward: Mesh and
// Skeleton say whether each half is on screen at all, Wireframe changes the
// surface itself, and the two under it change what is painted on it. Joint names
// are apart from all of them — drawn over the mesh rather than on it, and the
// only item here that says anything about a rig that is already visible.
//
// B for the mesh because M is already the mirror. S is free and is the letter
// the item starts with, which is as much as either key can claim.
MenuItem[26] view_items = {
	{ .label = "Front", .shortcut = "1", .on_select = &menu_view_front, .state = &query_has_view },
	{ .label = "Back", .shortcut = "Ctrl+1", .on_select = &menu_view_back, .state = &query_has_view },
	{ .label = "Right", .shortcut = "3", .on_select = &menu_view_right, .state = &query_has_view },
	{ .label = "Left", .shortcut = "Ctrl+3", .on_select = &menu_view_left, .state = &query_has_view },
	{ .label = "Top", .shortcut = "7", .on_select = &menu_view_top, .state = &query_has_view },
	{ .label = "Bottom", .shortcut = "Ctrl+7", .on_select = &menu_view_bottom, .state = &query_has_view },
	{ .separator = true },
	{ .label = "Mesh", .shortcut = "B", .on_select = &menu_show_mesh, .state = &query_show_mesh },
	{ .label = "Skeleton", .shortcut = "S", .on_select = &menu_show_rig, .state = &query_show_rig },
	{ .label = "Solid", .on_select = &menu_shading_solid, .state = &query_shading_solid },
	{ .label = "Textured", .on_select = &menu_shading_textured, .state = &query_shading_textured },
	{ .label = "Wireframe", .shortcut = "Z", .on_select = &menu_wireframe, .state = &query_wireframe },
	{ .label = "Floor", .on_select = &menu_show_floor, .state = &query_show_floor },
	{ .label = "Ghosts", .on_select = &menu_ghosts, .state = &query_ghosts },
	{ .label = "Ghost settings...", .on_select = &menu_ghost_settings },
	{ .label = "Motion path", .on_select = &menu_motion_path, .state = &query_motion_path },
	{ .label = "Weight falloff", .shortcut = "F", .on_select = &menu_falloff, .state = &query_falloff },
	// With the tint views rather than beside the mesh toggles: like them it
	// paints an answer onto a rig that is already on screen, and like them it is
	// meaningless until the document has something to say.
	{ .label = "Physics overlay", .on_select = &menu_show_physics, .state = &query_show_physics },
	{ .separator = true },
	{ .label = "Joint panel", .shortcut = "N", .on_select = &menu_show_joint_panel, .state = &query_show_joint_panel },
	{ .label = "Joint names", .on_select = &menu_joint_names, .state = &query_joint_names },
	{ .label = "Workflow guide", .on_select = &menu_workflow_guide, .state = &query_workflow_guide },
	{ .label = "Generate motion", .on_select = &menu_generate_motion, .state = &query_generate_motion },
	{ .separator = true },
	{ .label = "Show sketches", .on_select = &menu_show_sketches, .state = &query_show_sketches },
	{ .label = "Clear sketches", .on_select = &menu_clear_sketches, .state = &query_has_sketches },
};

MenuItem[2] help_items = {
	{ .label = "Tutorial", .on_select = &menu_start_tutorial },
	{ .label = "Controls", .on_select = &menu_toggle_controls, .state = &query_controls_shown },
};

// The window bar.
Menu[5] menus;

// ---------------------------------------------------------------------------
// The work area: the region under the menu bar is a tree of panes (cui's split
// areas), and each pane shows one of these views, picked from its tab strip.
// Globals for the same reason the menus are — cui borrows them for the
// lifetime of the widget; not const because the initialisers take function
// addresses, the same note as tint_toggles.

AreaLayout area_layout;

AreaView[6] area_views = {
	{ .name = "3D View", .build = &build_3d_view },
	{ .name = "Assets", .build = &build_assets_view },
	// Last, because it is the pane a user goes to and comes back from: the rig
	// and the clips are where the work is, and the physics is a property of the
	// rig that is tuned once and then watched in the 3D view.
	{ .name = "Motion & Physics", .build = &build_physics_view },
	// **Appended, never inserted.** `LIBRARY_VIEW` below is a position in this
	// array, so a view added anywhere but the end silently opens the wrong pane
	// in the asset pane.
	{ .name = "Animations", .build = &build_animations_view },
	// Spatial selection lives here; animations stay in the two dedicated views
	// above. Appended so every existing registry position remains stable.
	{ .name = "Scene", .build = &build_scene_view },
	// Two panes sat after this. A "Script" pane, while crig was a plugin: a
	// region three grafted a script's `three.ui.set` snapshot into, and nothing
	// else; it went with the plugin's JavaScript surface, and `UiLayer.set_slot`
	// in three is still the verb that would bring it back. Then a "Shells" pane
	// — every piece of the mesh, largest first, with a Pin per row — which was
	// the right mechanism behind the wrong face: a list of numbered pieces is
	// not how anyone finds the head, so it is out for now while the pin and the
	// riders it read (`pin_shell`, `shell_riders`, the wire's `get_shells`) stay.
	// The append-only rule above is why the gaps are at the end rather than in
	// the middle, and why whatever comes back goes here too.
	// Text to motion: the prompt, its progress and the session's takes.
	{ .name = "Generate", .build = &build_generate_view },
};

// Registry positions stay stable when new pane types are appended.
const usz LIBRARY_VIEW = 1;
const usz ANIMATION_VIEW = 3;
const usz SCENE_VIEW = 4;
const usz GENERATE_VIEW = 5;

// Enough space for the timeline, pose controls and status at the startup size.
// Split ratios remain user-adjustable and scale with subsequent window resizing.
const float ANIMATION_DOCK_H = 260.0f;

<*
 Open the default workspace: model beside a column of the Scene Outliner over
 the Generate pane, above a full-width animation dock. Assets remains one tab
 away in the right column. Every pane keeps the ordinary draggable dividers and
 tabs.

 @require areas.root != null : `An uninitialised layout has no leaf to split.`
 @require areas.root.is_leaf() : `Only a fresh single-pane workspace can be opened this way.`
*>
fn void open_default_workspace(AreaLayout* areas)
{
	areas.split_leaf(areas.root, SplitAxis.VERTICAL);
	areas.root.ratio = 1.0f - ANIMATION_DOCK_H / (WIN_H - BAR_H - AREA_STYLE.splitter_px);
	areas.root.second.active = ANIMATION_VIEW;
	areas.split_leaf(areas.root.first, SplitAxis.HORIZONTAL);
	areas.root.first.ratio = 2.0f / 3.0f;
	areas.root.first.second.active = SCENE_VIEW;
	areas.split_leaf(areas.root.first.second, SplitAxis.VERTICAL);
	areas.root.first.second.ratio = 0.4f;
	areas.root.first.second.second.active = GENERATE_VIEW;
}

<*
 A pane whose content wears a header: the bar across the top, everything else
 filling the rest. Blender's editor headers.

 A widget of its own rather than a Column, for the tree order: the bar is built
 *after* the content, so it hit-tests first, and is drawn back at the top.

 Takes two children in build order — the content, then the bar — and optionally a
 third: a control strip pinned to the bar's right-hand end, for what the bar's
 own layout leaves no room for. The Assets view has no strip; the 3D view's is
 the tint switch.
*>
struct ViewPanel (Widget)
{
	float bar_height;
	float strip_margin; // gap between the right-hand control strip and the edge
	float lead_margin; // gap between the left-hand strip and the edge
}

<*
 Places the bar, the strip in it, and the content under both.

 @param elem : `The element this widget is attached to.`
 @param constraints : `The size range offered by the parent.`
 @require elem.children.len() >= 2 && elem.children.len() <= 4 : `A ViewPanel is built with content, bar, a right-hand strip and a left-hand one.`
 @return `The size taken: everything offered.`
*>
fn Vec2 ViewPanel.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	Vec2 own = constraints.max;

	// Tight, and the rest of the panel exactly: `sync_views` reads the
	// viewport element's rect back out of the tree, so this is also the region
	// the model is drawn into.
	Vec2 content = { own.x, math::max(own.y - self.bar_height, 0.0f) };
	elem.layout_child(0, cui::tight(content));
	elem.place_child(0, { 0, self.bar_height });

	// The header strip sizes itself to the bar's height across the panel.
	elem.layout_child(1, cui::loose(own));
	elem.place_child(1, { 0, 0 });

	// Centred in the bar it sits in rather than in the panel, hence the height
	// swapped for the bar's.
	float strip_w = 0;
	if (elem.children.len() >= 3)
	{
		Vec2 strip = elem.layout_child(2, cui::loose(own));
		strip_w = strip.x;
		elem.place_child(2, widgets::align_in(
			{ own.x, self.bar_height }, strip, CrossAlign.END, CrossAlign.CENTER, { self.strip_margin, 0 }
		));
	}

	// The left-hand strip (the 3D view's workflow guide) gets what the right one
	// leaves, less a margin either side.
	if (elem.children.len() == 4)
	{
		float room = math::max(own.x - strip_w - 2 * self.strip_margin - self.lead_margin, 0.0f);
		Vec2 lead = elem.layout_child(3, cui::loose({ room, self.bar_height }));
		elem.place_child(3, widgets::align_in(
			{ own.x, self.bar_height }, lead, CrossAlign.START, CrossAlign.CENTER, { self.lead_margin, 0 }
		));
	}
	return own;
}

<*
 The model view, built once per pane that shows it: its header, then the
 Viewport filling the rest, and the overlays as anchored children — corners of
 the pane, wherever the pane is.

 Each viewport supplies its own camera and rect. three renders the shared scene
 once into each of them, while crig paints the matching overlays on top.

 Anything drawn over the viewport (the HUD, the gizmo) is its child, not a
 sibling — hit testing picks the deepest element but events bubble to parents,
 so a sibling overlay would be a dead zone.

 The header is a plain strip holding the tint switch; the Rig and View menus are
 on the window bar.

 Ids repeat across panes by design — "hud", "gizmo", "viewbar" and "tints" all
 name one-per-pane widgets. Anything that has to reach all of them
 walks with `@each_id`; `find_id` answers with the first pane in tree order,
 which is only ever what a single-pane test wants.
*>
fn Element* build_3d_view(Ui* ui)
{
	return @subtree(ui)
	{
		@tree((ViewPanel) { .bar_height = VIEW_BAR_H, .strip_margin = TINT_MARGIN, .lead_margin = GUIDE_MARGIN })
		{
			@tree((Viewport) { })
			{
				// The Blender-corner stats block. A child of the viewport rather
				// than a sibling, and transparent to the pointer — ui_test drags
				// from its middle to prove a click through it still reaches the
				// model.
				//
				// Indented past the tool column rather than starting at the edge,
				// which is also Blender's arrangement: the toolbar against the
				// edge and the text beside it. See `HUD_LEFT_MARGIN`.
				@tree((Anchored) { .h = START, .v = START, .margin = { HUD_LEFT_MARGIN, 14.0 } })
				{
					@node((HudOverlay) { }).with_id("hud");
				};

				// The tools that claim the drag over the model, against the edge
				// the stats block just made room for. After the block in tree
				// order, so a cell would take a click the block was over — which
				// cannot arise while the block starts where the column ends, and
				// is the right way round if a narrow pane ever brings them
				// together, the block being transparent to the pointer anyway.
				@tree((Anchored) { .h = START, .v = START, .margin = { TOOL_MARGIN_X, TOOL_MARGIN_Y } })
				{
					@node((ToolColumn) { }).with_id("tools");
				};

				// The running tool's options, across the top: the brush's size and
				// Add / Remove, so painting needs no modifier.
				@tree((Anchored) { .h = CENTER, .v = START, .margin = { 0, 10.0 } })
				{
					@node((BrushOptions) { }).with_id(BRUSH_OPTIONS_ID);
				};

				// The Sketch tool's inks, eraser and undo / clear / done. Zero-sized unless
				// sketching, so it shares the slot the brush options use.
				@tree((Anchored) { .h = CENTER, .v = START, .margin = { 0, 10.0 } })
				{
					@tree(widgets::tip_probe(&sketch_tip)) { @node((SketchToolbar) { }).with_id("sketch-toolbar"); };
				};

				// The keys the running tool answers to, opposite the block that
				// says what is true. Along the bottom because that is where a
				// keymap goes and because the top-left corner is already spoken
				// for — and because a hint under the model is out of the way of
				// the model.
				@tree((Anchored) { .h = START, .v = END, .margin = { 24.0, 14.0 } })
				{
					@node((HintBar) { }).with_id("hints");
				};

				// The selected joint's numeric pose and limit editor. Below the view
				// gizmo rather than replacing Assets on the right or narrowing the
				// animation dock below. Its Blender-style category rail remains at the
				// edge when the panel body is closed, so either category can reopen it.
				@tree((Anchored) { .h = END, .v = START,
					.margin = { GIZMO_MARGIN, GIZMO_MARGIN + GIZMO_SIZE + 6.0f } })
				{
					@node((JointPanel) { }).with_id(JOINT_PANEL_ID);
				};

				// Unlike a Label it *handles* clicks, and as a child whatever the
				// gizmo does not consume bubbles down to the model.
				@tree((Anchored) { .h = END, .v = START, .margin = { GIZMO_MARGIN, GIZMO_MARGIN } })
				{
					@node((ViewGizmo) { }).with_id("gizmo");
				};

				// What an empty view says for itself. Centred rather than tucked
				// into a corner: it is the only thing on screen when it shows, and
				// it lays out to nothing the moment a model arrives.
				@tree((Anchored) { .h = CENTER, .v = CENTER })
				{
					@node((OpenPrompt) { }).with_id("prompt");
				};
			}.with_id("viewport");

			// ---- the pane's own header ----
			// A plain strip now that Rig and View are on the window bar: it holds
			// the tint switch and says where the pane's model begins.
			@node((Rectangle) { .size = { 0, VIEW_BAR_H }, .style = { .color = PANEL } })
				.with_id("viewbar");

			// ---- Joints | Pose, then the tint view switch ----
			// Last, and raised from its own layout, so it is above the bar's
			// catcher however the bar orders itself — see tint_toggles.c3.
			@tree((Row) { .gap = STAGE_SWITCH_GAP, .cross_align = CENTER })
			{
				@tree(widgets::tip_probe(&stage_tip)) { @node((StageSwitch) { }); };
				@tree(widgets::tip_probe(&shading_tip)) { @node((ShadingToggles) { }).with_id("shading"); };
				@tree(widgets::tip_probe(&tint_tip)) { @node((TintToggles) { }).with_id("tints"); };
			};

			// ---- workflow guide ----
			// Left of the header: where the project stands, one click from each step.
			@node((GuideBar) { }).with_id(GUIDE_BAR_ID);
		};
	};
}



// ---------------------------------------------------------------------------

<*
 The root of the tree: a fill-window container that also owns every global
 keyboard shortcut.

 The shortcuts live here and not on the viewport because of how cui focuses: a
 left press focuses the deepest hit element whose widget implements on_key, and
 clears the focus when there is none in the chain. With the keys on the
 viewport, clicking any other widget silently killed the keyboard until the
 model was clicked again. With them on the root, every click focuses something
 whose ancestor chain ends here, and keys the focused widget declines — which
 is all of them, unless a menu is open eating ESC — bubble down and land.

 They can live here because none of them needs anything viewport-local: they
 act on the AppState and the camera, both of which any element in the tree
 reaches by type — see `build_ui`.

 It carries no state of its own: what it does is entirely a function of the
 AppState it inherits and the event it was handed.
*>
struct AppRoot (Widget)
{
	// Zero on both axes: the size-field convention, which fills the window —
	// the same answer cui gives a widget that says nothing about its size, and
	// children are laid out loosely either way. Present because C3 forbids a
	// zero-sized struct, so a widget with nothing to hold has to hold this.
	Vec2 size;
}

<*
 Drives the per-frame app state. cui calls this every frame with the frame's dt.

 On the root rather than the viewport for the same reason the shortcuts are:
 these tick the app, not a pane. The viewport can be split into several copies
 — an update on each would advance the animation once per pane — and it can be
 tabbed away entirely, which must not freeze the weight debounce.
*>
fn void AppRoot.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	// A mesh that arrived with nothing to pose it by. Drained here rather than
	// where it is raised because both routes into `adopt_source_rig` are places
	// with no `Ui*` — `load_mesh` runs between frames, and the command line runs
	// before this tree exists — and both have to end at the same panel.
	//
	// Lowered before the panel opens, not after: opening is what discharges the
	// request, and a panel the user closes must not come back on the next frame.
	if (app.wants_rig_prompt)
	{
		app.wants_rig_prompt = false;
		open_rig_prompt(elem.ui);
	}
	// And closed again once a rig has arrived some other way than its own button.
	if (app.rig_prompt_while_bare && app.doc.dots.len() > 0)
	{
		app.rig_prompt_while_bare = false;
		close_rig_prompt(elem.ui);
	}

	// The first-run welcome, once per session and only until it has been answered.
	tutorial_offer_welcome(elem.ui, app);

	// Ahead of the camera's early-out, because the weight debounce has to keep
	// running through the frames where nothing is moving — which is every frame
	// that matters to it, since what it is waiting for is the user going still.
	app.tick_weights(dt);
	// Its twin for the skin under a parked body, which the player's tick below
	// leaves alone while the clock is stopped.
	app.tick_skin(dt);

	// The animation player, if active. A timeline draft has already stopped its
	// clock and taken over the same palette, so only one of them runs at a time.
	app.tick_animation(dt);
	// Every other loaded character, to the instant the one being edited shows.
	bool cast_moved = app.sync_cast(dt);

	// One step of the overlay's occlusion refresh cycle per frame, so a running
	// clip re-tests a rotating slice of the dots and bones rather than all of them
	// — see `overlay_occluded`. Once here, not per pane.
	app.advance_occlusion_phase();

	// The result line, which is the one timer the camera's early-out below must
	// not skip either: a notice that stopped ageing when the user stopped moving
	// would never come down, since going still is exactly what follows a result.
	app.tick_notice(dt);

	// The workflow guide's skin survey, debounced like the weights.
	app.tick_guide(dt);

	// A text-to-motion job: its progress, and the clip it lands.
	tick_generation(elem.ui, app);

	// The render loop sleeps as soon as a frame ends with nothing scheduled, and
	// the ticks above are advanced by frames — so anything mid-flight has
	// to ask for the frame that will advance it next, or it stops the moment the
	// user goes still. `AppState.ticking` is the list of what counts.
	if (app.ticking() || app.guide_pending()) elem.ui.request_frame();

	// A clip moves the dots as well as the mesh, and the two are drawn by
	// different halves of the program: the mesh is re-recorded every frame, the
	// overlay is cached per element until something invalidates it. Without this
	// the rig would sit at rest under a body walking out from under it.
	//
	// The viewport only, not its subtree: the HUD and the gizmo below it are
	// driven by their own update, and neither reads the pose. A paused clip's
	// pose only changes through an edit or a scrub, which repaint on their own.
	if ((app.animating && !app.anim_paused) || cast_moved)
	{
		elem.ui.@each(Viewport; viewport) { viewport.request_paint(); };
	}

	// The camera schedules its own: `advance` reports that it moved, and the
	// invalidation below is already a request for a frame, so a running snap
	// keeps the loop awake to the end of its own easing.
	if (!app.camera.advance(dt)) return;
	elem.ui.invalidate(OrbitCamera);
}

fn bool AppRoot.on_key(&self, Element* elem, KeyEvent event) @dynamic
{
	if (!event.down) return false;

	AppState* app = elem.inherit(AppState)!!;
	Input* input = &elem.ui.input;
	bool ctrl = input.ctrl_down();
	bool shift = input.shift_down();

	if (app.transform_interaction.active)
	{
		(void)handle_transform_key(app, event.key, shift);
		return true;
	}

	// View snaps are tested before the ctrl block, because here ctrl picks the
	// opposite face rather than selecting a different command.
	if (try ViewAxis view = view_key(event.key, ctrl))
	{
		snap_view(elem.ui, view);
		return true;
	}

	if (ctrl)
	{
		// Ctrl+Shift+Z as well as Ctrl+Y: the two conventions split by platform
		// and neither is wrong, so both work.
		switch (event.key)
		{
			case Key.Z:
				if (shift) { menu_redo(elem.ui); } else { menu_undo(elem.ui); }
				return true;
			case Key.Y:
				menu_redo(elem.ui);
				return true;
			case Key.S:
				if (shift) { menu_save_as(elem.ui); } else { menu_save(elem.ui); }
				return true;
			case Key.N:
				menu_new_scene(elem.ui);
				return true;
			case Key.O:
				menu_open_scene(elem.ui);
				return true;
			case Key.I:
				menu_import(elem.ui);
				return true;
			case Key.E:
				// Mirrors the menu item, greying and all: nothing to choose
				// clips or a destination for when there is no model to write.
				menu_export(elem.ui);
				return true;
			case Key.A:
				// Reached only with Ctrl down, so plain A still toggles
				// auto-connect: this switch returns before the letter shortcuts
				// below are ever consulted.
				menu_select_all(elem.ui);
				return true;
			// The viewport's clipboard: the pose of the selected joints. Only
			// reached when nothing nearer the focus claimed the chord — the
			// dopesheet takes Ctrl+C/V for saved keys and a text field for its
			// text, and each returns before bubbling here — which is what keeps
			// the three clipboards apart without any of them knowing about the
			// others. Shift on the paste flips it onto the twins. Outside
			// animation editing there is no pose to copy, and the chord is left
			// unclaimed rather than answered with a refusal.
			case Key.C:
				if (!app.animation_pose_ready()) return false;
				app.copy_pose();
			case Key.V:
				if (!app.animation_pose_ready()) return false;
				app.paste_pose(flipped: shift);
			case Key.R:
				// Set root, which used to be plain R and gave the letter up —
				// first to a rename panel, now to the turn alone. Through the menu
				// handler so the item and the key refuse an empty selection
				// identically.
				//
				// In this block so it holds in animation editing too — where it is
				// refused, and has to be: re-rooting re-parents every joint, and a
				// pose is a set of parent-relative rotations, so it would silently
				// reinterpret every one of them.
				if (app.rig_locked())
				{
					app.@notice("finish animation editing before moving the root");
					return true;
				}
				menu_set_root(elem.ui);
			// How big the interface is drawn, on the three keys every application
			// that has the setting uses for it — and the plus on both rows,
			// because the one beside the digits needs shift on most layouts and
			// the one on the numpad does not.
			//
			// Above the letter shortcuts for the reason the whole ctrl block is:
			// plain 0 belongs to nothing, but plain = and - are free and are not
			// worth claiming for a setting that is changed twice a year.
			case Key.EQUALS:
			case Key.KP_ADD:
				nudge_ui_scale(elem.ui, 1);
			case Key.MINUS:
			case Key.KP_SUBTRACT:
				nudge_ui_scale(elem.ui, -1);
			case Key.KEY_0:
			case Key.NUM_0:
				nudge_ui_scale(elem.ui, 0);
			default:
				return false;
		}
		app.refresh_ui();
		return true;
	}

	// A move in progress takes the axis keys off the shortcuts: with a dot in
	// hand X means "lock this to X", not "delete it", and ESC means "put it
	// back" rather than "deselect". Both readings are the one the user wants
	// while dragging and the wrong one every other time, so the drag claims
	// them only for as long as it lasts.
	if (app.drag.dot != 0)
	{
		switch (event.key)
		{
			case Key.X: app.lock_drag(shift && app.drag.verb != DragVerb.TURN ? DragAxis.YZ : DragAxis.X);
			case Key.Y: app.lock_drag(shift && app.drag.verb != DragVerb.TURN ? DragAxis.XZ : DragAxis.Y);
			case Key.Z: app.lock_drag(shift && app.drag.verb != DragVerb.TURN ? DragAxis.XY : DragAxis.Z);
			case Key.B: app.lock_drag(DragAxis.BONE);
			case Key.ESCAPE: app.cancel_drag();
			default: return false;
		}
		app.refresh_ui();
		return true;
	}

	// The animation sheet's universal transport: arrows step one blocking frame
	// and Space toggles its clock. Text fields consume these before bubbling here.
	if (animation_transport_key(elem.ui, event.key)) return true;
	// I opens the interpolation popover while a clip is open; text fields took
	// their own letters before this.
	if (animation_interp_key(elem.ui, event.key)) return true;
	// K keys the pose and Shift+K flips Auto-key, while a clip is open in Pose.
	if (animation_keying_key(elem.ui, event.key, shift)) return true;

	// Animation posing's two verbs, above the plain letters and below the block that
	// claims them: a gesture already in flight owns X/Y/Z and ESC, and G or R
	// pressed during one falls through to that block's `default` rather than
	// starting a second gesture on top of the first.
	//
	// R was set root once. Taking it for the turn here was forced rather than
	// chosen: moving the root re-parents every joint, and the pose is a set of
	// parent-relative rotations, so re-rooting mid-pose would silently
	// reinterpret every one of them. Set root has to be refused in this mode
	// whatever key it sits on (it went to ctrl+R), which left R free for the
	// verb that reads the same way as Blender's — and it is now the letter's
	// only meaning: the rename that briefly shared it lives on the Joint card.
	// A selected editing clip is pose-ready: G seeds its transient draft from the
	// playhead whether preview is parked or stopped. R begins a turn the same
	// way: the pointer sweeps around the joint and a click confirms, with X/Y/Z
	// locking a bone-local axis. One axis at a time by hand is the Joint card's
	// dials, which is where the rings that used to appear here went — drawn over
	// the joint they hid the very hand or head being turned.
	if (app.animation_pose_ready())
	{
		switch (event.key)
		{
			case Key.G: app.begin_pose();
			case Key.R: app.begin_turn();
			default: break;
		}
		if (app.drag.dot != 0)
		{
			app.refresh_ui();
			return true;
		}
		// A refused verb still consumed its key — G or R with no animation to pose
		// has already said so, and letting it fall through to `set_root` below
		// would re-root the rig instead.
		if (event.key == Key.G || event.key == Key.R)
		{
			app.refresh_ui();
			return true;
		}
	}

	if (event.key == Key.G || event.key == Key.R)
	{
		(void)begin_keyboard_transform(elem.ui,
			event.key == Key.G ? MOVE_TRANSFORM : ROTATE_TRANSFORM);
		return true;
	}

	switch (event.key)
	{
		// Backspace deletes too: on a Mac keyboard the key labelled "delete" is
		// Backspace, and reaching forward delete there means holding fn.
		case Key.X:
		case Key.DELETE:
		case Key.BACKSPACE:
			if (app.selected == 0) return false;
			menu_delete(elem.ui);
			return true;
		case Key.C:
			// Through the menu handler, so the keyboard and the item report the
			// same counts — this is the one operation whose result is a number.
			menu_connect_selection(elem.ui);
			return true;
		case Key.T:
			// The lasso's letter, both halves of it: the plain press walks the tool
			// along its two jobs, the shifted one goes straight to pinning. Which
			// makes the pair the same shape as W and shift+W — the plain letter for
			// the job that reads the rig, the shifted one for the job that writes
			// the bind.
			//
			// The plain letter was unclaimed until now: it used to open a viewport
			// mode that pinned a whole piece of the mesh on a click, a Shells pane
			// took that job over, and the pane has since gone for now. Through the
			// menu handlers, so the key and the items refuse in the same words.
			if (shift)
			{
				menu_lasso_mode(elem.ui);
				return true;
			}
			menu_lasso_select(elem.ui);
			return true;
		// No plain R here. It is the turn, claimed by the posing block above,
		// and nothing else: it was set root once (a once-per-rig operation that an
		// imported rig never needs — glTF's node hierarchy already says which way
		// the chain runs — so it keeps ctrl+R and its Edit menu item), then a
		// rename panel, which reached the letter only outside animation posing.
		// Since posing is always ready with a clip parked, that door was mostly
		// shut, and it opened a second panel over the Joint card, which already
		// showed the name. The card edits it now, with the button beside its
		// title, and R means one thing in every state.
		case Key.M:
			// Two things reflect across the symmetry plane, and the shift tells
			// them apart the way it does for W and T: the plain letter mirrors the
			// rest dots, the shifted one mirrors the *pose* of the selected joints
			// — the More menu's Mirror pose — and neither depends on which
			// workspace is up. M used to take the pose's meaning whenever a clip
			// was open to posing, which is a state nothing on screen names, so a
			// person could not say which of the two a press was about to do.
			//
			// Within each, one reading: `mirror_selection` decides per dot whether
			// the twin has to be made or an existing one pulled into line, so
			// there is nothing further for a modifier to choose — which is why the
			// menu item and this case both go through `menu_mirror_selection` and
			// report the split as a notice instead.
			//
			// Left unhandled with nothing selected rather than consumed into a
			// no-op, so the press is still an unclaimed key rather than a command
			// that silently did nothing. The pose is the exception: with nothing
			// selected the whole pose is mirrored, as the button does.
			if (shift)
			{
				anim_pose_op(elem.ui, MIRROR);
				return true;
			}
			if (app.selected == 0) return false;
			menu_mirror_selection(elem.ui);
			return true;
		case Key.L:
			// The anchor: hold this joint's world position so moving another bends
			// the limb to keep it there — lock the feet, pull the hips, the figure
			// sits. The Joint card's two padlock toggles are the same pair; this is
			// their keyboard copy (shift+L is rotation). Nothing selected leaves the
			// press unclaimed rather than a silent no-op, the way M does.
			if (app.selected == 0)
			{
				app.@notice("select a joint to anchor it");
				return false;
			}
			{
				// The whole selection, like the card's padlocks: several joints locked
				// or unlocked together, the new state read off the primary.
				bool now = shift ? !app.locks_rotation(app.selected) : !app.locks_position(app.selected);
				usz acted = app.set_selection_anchor_half(shift, now);
				String half = shift ? "rotation" : "position";
				if (acted > 1)
				{
					app.@notice(now ? "%s anchored on %d joints" : "%s released on %d joints", half, (int)acted);
				}
				else
				{
					Dot* locked_dot = app.doc.find(app.selected);
					String locked_name = locked_dot && locked_dot.name.len > 0 ? locked_dot.name : "joint";
					app.@notice(now ? "%s of %s anchored" : "%s of %s released", half, locked_name);
				}
			}
			refresh_joint_panel(elem.ui);
			return true;
		case Key.A:
			menu_auto_connect(elem.ui);
			return true;
		case Key.W:
			// Shift picks the sibling tool rather than a second meaning: the Area
			// tool hands a joint a whole part and the brush corrects it by hand,
			// the two ways to change a bind without moving a joint.
			if (shift)
			{
				menu_weight_brush(elem.ui);
				return true;
			}
			menu_weights_panel(elem.ui);
			return true;
		case Key.RIGHT_BRACKET:
			// The third way to change a bind without moving a dot, and the only one
			// that acts on every boundary at once. A bracket pair rather than a
			// letter: the two are one control with two directions, and no letter
			// says "more of that" and "less of it" the way ] and [ sitting beside
			// each other do. Both are free — neither reaches any other handler.
			menu_sharpen_blend(elem.ui);
			return true;
		case Key.LEFT_BRACKET:
			menu_soften_blend(elem.ui);
			return true;
		case Key.F:
			// While the brush is open F is its size key, held rather than pressed,
			// and the viewport reads it live. Swallowed here so a press does not
			// also turn off the very view the brush put up to paint against —
			// which would leave the user sizing a circle over a mesh showing
			// something else.
			if (!app.brushing) menu_falloff(elem.ui);
			return true;
		case Key.N:
			// Blender's N-panel key, and its job here: show or hide the selected-
			// joint settings card. Joint names moved to the View menu (no letter of
			// their own) when N took this — they are a niche overlay, the card is
			// the panel a rig is built through.
			//
			// A notice as well as the toggle: it confirms the keyboard path while
			// the rail itself remains available for the mouse path.
			menu_show_joint_panel(elem.ui);
			return true;
		case Key.B:
			menu_show_mesh(elem.ui);
			return true;
		case Key.S:
			// Plain S only; ctrl+S saved the session and returned above.
			menu_show_rig(elem.ui);
			return true;
		case Key.Z:
			// Plain Z only. Ctrl+Z returned above as undo and a move in progress
			// claimed it as an axis lock before that, so this is the reading left
			// over — which is also Blender's, where Z is the shading key.
			menu_wireframe(elem.ui);
			return true;
		case Key.RETURN:
		case Key.KP_RETURN:
			// Apply in the Area tool; otherwise the key is not ours.
			if (!app.areaing) return false;
			app.commit_area();
			refresh_joint_panel(elem.ui);
		case Key.ESCAPE:
			// Backs out one layer at a time: the mode first, then the
			// selection, so leaving a mode does not also lose your place.
			//
			// The brush: escape closes it and nothing is cancelled, because every stroke already went on the ledger
			// as it was made. There is no half-finished state for the key to undo,
			// and taking a stroke back is Ctrl+Z like taking anything back.
			if (app.sketching)
			{
				app.end_sketch();
			}
			else if (app.brushing)
			{
				app.end_brush();
				// The Weights card the brush was opened from takes its part back.
				app.sync_weights_card();
			}
			else if (app.lasso_active)
			{
				// A region half drawn is the one half-finished state either of
				// these modes has, and escape is what a hand reaches for when the
				// outline has gone wrong. It cancels the gesture and nothing else
				// — the mode stays open, because the next thing wanted is another
				// try rather than a different tool. Nothing to undo: a lasso
				// commits on its release, so an abandoned one never reached the
				// ledger.
				app.drop_lasso_stroke();
				app.lasso_active = false;
			}
			else if (app.lassoing)
			{
				app.end_lasso();
			}
			else if (app.areaing && app.area_pending())
			{
				// A picked part is dropped first, the tool second.
				app.drop_area_part();
			}
			else if (app.areaing)
			{
				app.end_area();
			}
			else
			{
				app.select(0);
			}
		default:
			return false;
	}

	app.refresh_ui();
	return true;
}

<*
 Builds the whole window as a detached tree: the pane tree under the bar, the
 menu bar over everything.

 cui hit-tests in reverse paint order, so the bar being painted last is what
 lets an open dropdown cover the model and swallow the click that closes it.
 Everything a pane puts over its own content follows the same rule one level
 down — see ViewPanel.

 Detached rather than installed: `main.c3` installs it itself and then focuses
 the workspace, and the tests install it through `build_ui` below. `@subtree` is
 the detached twin of `@canvas` and is the whole difference.

 @param ui : `Receives the tree; must outlive it.`
 @param app : `Borrowed by the viewport, the shortcuts and the HUD — must outlive the Ui and must not move.`
 @param with_library : `True for the workspace crig opens on; false for a bare single pane.`
*>
fn Element* build_ui_tree(Ui* ui, AppState* app, bool with_library = true)
{
	// The back-edge, so an edit made from a menu can find the HUD and the
	// viewport without an Element* to start from.
	app.ui = ui;

	// The forward edge: state reachable by type from any element in the tree,
	// so a widget does not have to be handed a pointer in its struct literal.
	// Two entries, deliberately — the camera separately from the state that
	// contains it, so a widget that only steers the view (the gizmo, the View
	// menu) can ask for exactly that and be unable to touch the document.
	//
	// Both borrow from `app`, which the doc comment above already requires to
	// outlive the Ui and not move.
	ui.provide(app);
	ui.provide(&app.camera);

	// The animation library is deliberately absent from the menu bar: it lives
	// in the Animations view, where a clip is a cell that plays on click and
	// stops on a second click. Listing clips here instead would cap how many
	// there can be — `MenuItem.on_select` carries no payload, so every row needs
	// a callback of its own and the row count has to be fixed at compile time.
	menus = {
		{ .title = "File", .items = file_items[..] },
		{ .title = "Edit", .items = edit_items[..] },
		{ .title = "Rig", .items = rig_items[..] },
		{ .title = "View", .items = view_items[..] },
		{ .title = "Help", .items = help_items[..] },
	};

	// Re-init on every build, so a fixture that rebuilds its UI starts from the
	// same workspace the app does rather than from whatever the last build left.
	// Splitting further, closing and tab switching are the strip's own controls
	// from here.
	area_layout.init(area_views[..], AREA_STYLE);
	if (with_library) open_default_workspace(&area_layout);

	return @subtree(ui)
	{
		@tree((AppRoot) { })
		{
			// ---- work area ----
			// The pane tree fills everything below the bar. No background
			// rectangle: the mesh is already on the color attachment by the
			// time the UI paints, and cui's clear to BG is the viewport
			// background. `sync_views` reads each Viewport element's rect back
			// out of this tree, so the pixels a pane's overlay projects into
			// and the ones its mesh was drawn with are the same by
			// construction.
			//
			// Inset by the bar's height rather than sized to the window and
			// pushed down by it: a zero size fills whatever the parent offers,
			// so the workspace follows the window when it is resized, and the
			// Padding is what keeps "whatever the parent offers" from including
			// the strip the bar is drawn on.
			@tree((Padding) { .insets = { .top = BAR_H } })
			{
				@node((AreaHost) { .areas = &area_layout }).with_id("areas");
			};

			// ---- the Controls reference ----
			// A window fixture, not a pane's: it is the same reference whatever a
			// pane happens to be showing, and one per split would be three copies
			// of it. Built here rather than inside the workspace for the reason
			// AreaPane's own comment gives — a pane clips, and a panel this size
			// would be cut off by the pane it floated in.
			//
			// Before the bar, so an open dropdown still covers it: the dialog wins
			// the paint order against the model and loses it against the menus,
			// which is the order both of them expect. Closed it is a zero-size
			// element that paints nothing, so it costs nothing to leave here.
			@node((Dialog) {
				.title = "Controls",
				.body = fn Element*(Ui* ui)
				{
					// Asked for its own height, not the room the window has: the
					// viewport is clamped to whatever the dialog can offer, so this
					// is "as tall as the reference, or as tall as it fits" in one
					// number. Handing it 0 — fill the space — would leave a short
					// screen scrolling correctly and a tall one with a dialog full
					// of blank space under the last binding.
					return @subtree(ui)
					{
						@tree((Scroll) { .size = { CONTROLS_SHEET_W, controls_height() } })
						{
							@node((ControlsSheet) { }).with_id("controls");
						};
					};
				},
				.style = DIALOG_STYLE,
			}).with_id(CONTROLS_DIALOG_ID);

			// ---- the file chooser ----
			// Beside the reference and for the same reasons, with one of its own:
			// it is modal. Opening a model or choosing where to write replaces
			// what every other control acts on, so the rest of the interface has
			// to stop answering until the question is settled — and a click on
			// the scrim is a way out that needs no button.
			//
			// Its title and its confirming button are rewritten per opening by
			// `open_file_dialog`; both are what the purpose decides.
			// ---- what goes into an export ----
			// Before the chooser, so a Browse opened from inside it floats over
			// this one rather than under it: siblings paint in tree order, and
			// the chooser is the answer to a question this panel asked.
			@node((Dialog) {
				.title = "Export",
				.body = &build_export_dialog_body,
				.style = DIALOG_STYLE,
				.modal = true,
			}).with_id(EXPORT_DIALOG_ID);

			// ---- the settings ----
			// Before the chooser for the export panel's reason: Add folder opens
			// it, and the answer has to float over the question.
			//
			// Not modal, unlike the two around it. It changes nothing the rest of
			// the interface is acting on — the document is untouched by every
			// control in it — and a panel of settings is a reasonable thing to
			// leave open while looking at what the browser did with them.
			@node((Dialog) {
				.title = "Settings",
				.body = &build_settings_body,
				.style = DIALOG_STYLE,
				.close_outside = true,
			}).with_id(SETTINGS_DIALOG_ID);

			// ---- one asset's name and tags ----
			// Beside the settings and for the same reasons: it changes nothing the
			// rest of the interface is acting on until Save, and it is raised from a
			// pane rather than from the menu bar.
			@node((Dialog) {
				.title = "Asset settings",
				.body = &build_asset_settings_body,
				.style = DIALOG_STYLE,
				.close_outside = true,
			}).with_id(ASSET_SETTINGS_DIALOG_ID);

			@node((Dialog) {
				.title = "Open model",
				.body = &build_file_dialog_body,
				.style = DIALOG_STYLE,
				.modal = true,
				.close_outside = true,
			}).with_id(FILE_DIALOG_ID);

			// ---- a mesh that arrived with no skeleton ----
			// After the chooser, because opening a model is what raises it and the
			// answer has to float over the question that produced it.
			//
			// Not modal, unlike the chooser: it is an offer rather than a question.
			// A user who would rather place dots by hand should be able to start
			// doing that by clicking the model, and a scrim would make them dismiss
			// a panel first to reach the thing it is talking about.
			@node((Dialog) {
				.title = "No skeleton",
				.body = &build_rig_prompt_body,
				.style = DIALOG_STYLE,
				.close_outside = true,
			}).with_id(RIG_PROMPT_DIALOG_ID);

			@node((Dialog) {
				.title = "Skeleton faces away",
				.body = &build_turn_offer_body,
				.style = DIALOG_STYLE,
				.close_outside = true,
			}).with_id(TURN_OFFER_DIALOG_ID);

			@node((Dialog) {
				.title = "Rotate skeleton",
				.body = &build_skeleton_rotation_body,
				.style = DIALOG_STYLE,
				.modal = true,
			}).with_id(SKELETON_ROTATION_DIALOG_ID);
			@node((Dialog) { .title = "Move by", .body = &build_move_by_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(MOVE_BY_DIALOG_ID);
			@node((Dialog) { .title = "Scale model", .body = &build_scale_model_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(SCALE_MODEL_DIALOG_ID);

			@node((Dialog) { .title = "Create animation", .body = &build_anim_new_body,
				.style = DIALOG_STYLE, .modal = true }).with_id("anim-new-dialog");
			@node((Dialog) { .title = "Gait", .body = &build_gait_body, .style = DIALOG_STYLE, .modal = true }).with_id(GAIT_DIALOG_ID);
			@node((Dialog) { .body = &build_anim_clip_menu,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(ANIM_CLIP_MENU_ID);
			@node((Dialog) { .body = &build_anim_key_context,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id("anim-key-context");
			@node((Dialog) { .body = &build_anim_interp_body,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 8, 8, 8, 8 } }).with_id(ANIM_INTERP_POPOVER_ID);
			@node((Dialog) { .body = &build_anim_contact_menu,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(ANIM_CONTACT_MENU_ID);
			@node((Dialog) { .body = &build_anim_layer_menu,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(ANIM_LAYER_MENU_ID);
			@node((Dialog) { .body = &build_anim_layer_row_menu,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(ANIM_LAYER_ROW_MENU_ID);
			@node((Dialog) { .body = &build_anim_new_menu,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(ANIM_NEW_MENU_ID);
			@node((Dialog) { .body = &build_anim_tools_menu,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(ANIM_TOOLS_MENU_ID);
			// The last Check's findings. Floats over the dock instead of pushing the
			// sheet down; not modal, so the ruler's flags stay clickable.
			// Ghosts' settings float the same way, and move: dragged by the bar.
			@node((Dialog) { .title = "Ghosts", .body = &build_anim_ghosts_body,
				.style = DIALOG_STYLE }).with_id(ANIM_GHOSTS_DIALOG_ID);
			@node((Dialog) { .title = "Check", .body = &build_anim_check_body,
				.style = DIALOG_STYLE }).with_id(ANIM_CHECK_DIALOG_ID);
			@node((Dialog) { .body = &build_viewport_context,
				.style = DIALOG_STYLE, .modal = true, .close_outside = true, .popup = true,
				.popup_insets = { 0, 5, 0, 5 } }).with_id(VIEWPORT_CONTEXT_ID);
			@node((Dialog) { .title = "Stretch animation timing", .body = &build_anim_retime_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(ANIM_RETIME_DIALOG_ID);
			@node((Dialog) { .title = "Remove movement", .body = &build_anim_motion_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(ANIM_MOTION_DIALOG_ID);
			@node((Dialog) { .title = "Optimize keys", .body = &build_anim_optimize_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(ANIM_OPTIMIZE_DIALOG_ID);
			@node((Dialog) { .title = "Trim animation", .body = &build_anim_trim_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(ANIM_TRIM_DIALOG_ID);
			@node((Dialog) { .title = "Joint mapping", .body = &build_anim_mapping_body,
				.style = DIALOG_STYLE, .modal = true, .on_close = &anim_mapping_closed }).with_id(ANIM_MAPPING_DIALOG_ID);
			@node((Dialog) { .title = "Collision (advanced)", .body = &build_collision_body,
				.style = DIALOG_STYLE, .modal = true }).with_id(COLLISION_DIALOG_ID);

			// ---- before something is thrown away ----
			// Last, so it floats over every other panel: it is raised from the
			// library, which is a pane, and from anywhere else that later grows a
			// way to replace the rig. It carries its own question — the sentence
			// is formatted when the question is asked and copied into the widget,
			// so nothing about it is parked anywhere else.
			@node((ConfirmDialog) {
				.title = "Apply body plan",
				.confirm_label = "Replace rig",
				.style = DIALOG_STYLE,
				.buttons = CONFIRM_BUTTONS,
			}).with_id(CONFIRM_DIALOG_ID);
			@node((ConfirmDialog) {
				.title = "Delete animation",
				.confirm_label = "Delete",
				.style = DIALOG_STYLE,
				.buttons = CONFIRM_BUTTONS,
			}).with_id(ANIM_DELETE_CONFIRM_ID);

			// ---- window menu bar ----
			// Painted after the pane tree, so the bar and an open dropdown win
			// every hit test over the model. Its element reports only the bar
			// strip as its size; the open state escapes that rect by design.
			// Rig and View are here too: they act on the rig and on the camera of
			// the last 3D View used, and View's camera items grey with none open.
			@node((MenuBar) { .menus = menus[..], .style = MENU_STYLE })
				.with_id("menubar");

			// ---- the guided tour ----
			// After the menu bar so the dim covers it and can light a menu title,
			// and the welcome and the card after the dim so both float over it.
			@node((TutorialOverlay) { }).with_id(TUTORIAL_OVERLAY_ID);

			@node((Dialog) {
				.title = "Welcome to Rigsmith",
				.body = &build_welcome_body,
				.style = DIALOG_STYLE,
				.modal = true,
				.on_close = &welcome_closed,
			}).with_id(WELCOME_DIALOG_ID);

			@node((Dialog) {
				.title = "Tutorial",
				.body = &build_tutorial_body,
				.style = DIALOG_STYLE,
				.on_close = &tutorial_card_closed,
			}).with_id(TUTORIAL_DIALOG_ID);

			// ---- tooltips ----
			// Last, and raised from its own layout, so a label is over the menus
			// and every pane. Transparent to the pointer.
			@node((TooltipHost) { .style = TOOLTIP_STYLE }).with_id("tooltip-host");
		};
	};
}

<*
 The workspace, installed as the Ui's root.

 What the tests call. The executable calls `build_ui_tree` itself — see there.
*>
fn void build_ui(Ui* ui, AppState* app, bool with_library = true)
{
	ui.build(build_ui_tree(ui, app, with_library));
	focus_workspace(ui);
}

<*
 Puts the keyboard in the workspace.

 Focused from the start so ctrl+Z works before the first click: cui only assigns
 focus on presses, and without this the keyboard is dead until then. Called by
 both paths — a plugin's tree is mounted by three, so it has to ask for this
 after the mount rather than as part of the build.
*>
fn void focus_workspace(Ui* ui)
{
	if (try Element* root = ui.find(AppRoot)) root.request_focus();
}

module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// Gestures
// 
// One InputFrame per call, flushed after, the way the frame loop runs it.
// process_input works off level state and derives its own edges, so a press is
// a frame with the button down between two frames with it up.

fn void Fixture.feed(&self, Vec2 mouse, bool left = false, Key[] keys = { }, bool right = false, String text = "")
{
	self.ui.process_input(
		{
			.mouse = mouse,
			.buttons = { left, right, false },
			.keys_down = keys,
			.text = text,
		},
		DT
	);
	self.ui.flush();
}

<*
 Click the middle of a row in a listing, in window coordinates.

 The row's y comes from the browser's own row height, so a change to the style
 moves the click with it rather than leaving this aiming at the row above.
*>
fn void Fixture.browser_click(&self, Element* browser, int row)
{
	if (row < 0) return;

	FileBrowserStyle style = browser.widget_as(FileBrowser).style.resolved();
	Vec2 at = browser.absolute + (Vec2){
		browser.size.x * 0.5f,
		((float)row + 0.5f) * style.row_height,
	};
	self.click(at);
}

<*
 Type into a focused field the way the platform reports typing: the characters
 as text, **and** the key that produced them as a key event, in the same frame.

 Both halves matter. The text is what the field inserts; the key is what would
 reach the application's shortcuts if the field failed to consume it. A helper
 that sent only the text would exercise the insertion and prove nothing about
 the thing that is actually easy to get wrong.

 @param keys : `The key codes the platform would report beside this text.`
*>
fn void Fixture.type_into(&self, Element* field, String text, Key[] keys = { })
{
	field.request_focus();
	self.feed(field.absolute + field.size * 0.5f, keys: keys, text: text);

	// A second frame with neither: `Input.text` is per-frame state, and leaving
	// it set would have the field take the same characters again — and a key held
	// across two frames produces no second press edge, which is what a release
	// frame here restores.
	self.feed(field.absolute + field.size * 0.5f);
}

<*
 The browser's cell for a visible row, or null.

 Found by asking each cell which row it stands for, rather than by computing a
 position from the grid's constants: a cell is a real element, so its own rect is
 the authority on where it is and a change to the metrics moves the click with
 it.
*>
fn Element* Fixture.asset_cell_at(&self, usz row)
{
	// `@each` over the widget type rather than `@walk` over everything: the cells
	// live inside a `Grid` inside a `Scroll` inside a pane, and this is how every
	// other check in this file reaches them. No early exit — a bare `return`
	// inside the body would leave this function, not the iteration.
	Element* found = null;
	self.ui.@each(AssetCell; cell)
	{
		if (!found && cell.widget_as(AssetCell).row == row) found = cell;
	};
	return found;
}

<*
 Press the bind target on a browser cell — the + that puts a clip on the
 character.

 Aimed through the cell's own `bind_at`, so the check cannot drift from the paint
 and the hit test the way a hard-coded corner offset would.

 @return `False when there is no such cell, which is a skip rather than a failure.`
*>
fn bool Fixture.bind_click(&self, usz row)
{
	Element* cell = self.asset_cell_at(row);
	if (!cell) return false;

	AssetCell* widget = cell.widget_as(AssetCell);
	self.click(cell.absolute + widget.bind_at(cell.size));
	return true;
}

<*
 Press the export panel's Export button.

 The panel is what writes now — the menu item only raises it — so every check
 that used to end at a menu click ends here instead.

 @return `False when the panel is not up, which is a skip rather than a failure.`
*>
fn bool Fixture.confirm_export(&self)
{
	Vec2? button = self.center_of(crig::EXPORT_CONFIRM_ID);
	if (catch button) return false;
	self.click(button);
	return true;
}

<*
 Pick a bound clip in the Animations pane's chooser, by opening it and pressing
 the option.

 @return `False when the chooser is not in the tree or has no such option.`
*>
fn bool Fixture.pick_anim_row(&self, usz row)
{
	Vec2? chooser = self.center_of("anim-chooser");
	if (catch chooser) return false;
	self.click(chooser);
	self.ui.flush();
	Vec2 at;
	bool found = false;
	self.ui.@each(SelectOption; option)
	{
		if (option.widget_as(SelectOption).index == row)
		{
			at = option.absolute + option.size * 0.5f;
			found = true;
		}
	};
	if (!found) return false;
	self.click(at);
	return true;
}

<*
 One key, pressed and released, delivered to whatever holds the focus.
*>
fn void Fixture.feed_key(&self, Key key)
{
	Vec2 where = self.ui.input.mouse;
	self.feed(where, keys: { key });
	self.feed(where);
}

<*
 Turn the weight preview on or off the way the View menu does.

 Not a key any more: W opens the Area tool, and the preview kept the menu item it
 always had. Routed through `menu_weights` rather than `AppState.toggle_weights`
 so the refresh the item performs stays part of what is exercised — the header
 strip polls state per frame, and that is only worth asserting against a route
 that does not go through the strip.

 @param mouse : `Where to leave the pointer, since some checks read hover afterwards.`
*>
fn void Fixture.toggle_weights(&self, Vec2 mouse)
{
	self.feed(mouse);
	crig::menu_weights(self.ui);
	self.feed(mouse);
}

<*
 Press and release without moving: a click, in the sense the viewport resolves
 on release.
*>
fn void Fixture.click(&self, Vec2 at) => self.ui.click(at);

<*
 A click with shift held: what adds a dot to the selection, or takes it out.

 The modifier goes down on its own frame first and is still down on the release,
 because the viewport reads it live from `Input` at the press rather than off the
 event — the same reason `chord` spreads a Ctrl shortcut over four frames.
*>
fn void Fixture.shift_click(&self, Vec2 at) => self.ui.click(at, held: { Key.LEFT_SHIFT });

<*
 The same edge with the right button — what opens a context menu.
*>
fn void Fixture.right_click(&self, Vec2 at) => self.ui.click(at, RIGHT);

fn void Fixture.drag(&self, Vec2 from, Vec2 to)
{
	self.feed(from);
	self.feed(from, left: true);
	self.feed(to, left: true);
	self.feed(to);
}

<*
 A drag with Alt held throughout — the deliberate "edit the rest dot" gesture on
 the posing stage, where a bare drag poses the joint instead. The viewport reads
 the modifier live from `Input` when the pointer crosses `CLICK_SLOP`, so Alt has
 to be down on the moving frames, not only the press.
*>
fn void Fixture.alt_drag(&self, Vec2 from, Vec2 to)
{
	Key[1] held = { Key.LEFT_ALT };
	self.feed(from, keys: held[..]);
	self.feed(from, left: true, keys: held[..]);
	self.feed(to, left: true, keys: held[..]);
	self.feed(to, keys: held[..]);
	self.feed(to);
}

<*
 Tap a key. Only reaches a widget that already has focus, which a left press
 inside it grants — the same coupling the user sees when clicking a panel button
 stops Delete from working.
*>
fn void Fixture.tap(&self, Vec2 mouse, Key key)
{
	Key[1] held = { key };
	self.feed(mouse, keys: held[..]);
	self.feed(mouse);
}

<*
 Hold a modifier, tap a key under it, let go.

 Four frames rather than one, because cui derives key edges by diffing the held
 set: pressing Ctrl and Z in the same frame makes both new that frame, and
 whether the Z handler sees Ctrl already down depends on the order the diff
 happens to walk. Pressing the modifier first is both realistic and unambiguous.
*>
fn void Fixture.chord(&self, Vec2 mouse, Key modifier, Key key)
{
	Key[1] held = { modifier };
	Key[2] both = { modifier, key };
	self.feed(mouse, keys: held[..]);
	self.feed(mouse, keys: both[..]);
	self.feed(mouse, keys: held[..]);
	self.feed(mouse);
}

<*
 A scroll over the viewport, as one frame the way the loop delivers it.

 `precise` is the backend's report about the device — true for a trackpad
 gesture, false for a wheel with detents — and crig sends the two to different
 operations entirely, so a fixture that could only produce one of them could not
 tell the split had broken.

 @param delta : `Scroll this frame: x positive to the right, y positive for a swipe down.`
 @param precise : `True for a trackpad, false for a wheel.`
 @param left : `Hold the left button through the frame — a scroll arriving mid-drag, which is a frame the loop really does deliver and the only way to reach the handlers that turn one down.`
*>
fn void Fixture.scroll(&self, Vec2 mouse, Vec2 delta, bool precise, Key[] keys = { }, bool left = false)
{
	self.ui.process_input(
		{
			.mouse = mouse,
			.buttons = { left, false, false },
			.scroll = delta.y,
			.scroll_x = delta.x,
			.scroll_precise = precise,
			.keys_down = keys,
		},
		DT
	);
	self.ui.flush();
}

<*
 Empty the dot list, releasing the names the document owns.

 `dots.clear()` on its own drops one string per named dot. In the app a document
 is only ever emptied by `RigDocument.free`, which releases them and then throws
 the list's storage away too; a fixture reused across checks keeps the storage,
 so it needs the first half without the second.
*>
fn void Fixture.clear_dots(&self)
{
	foreach (dot : self.app.doc.dots.array_view())
	{
		if (dot.name.len > 0) alloc::free(mem, dot.name.ptr);
	}
	self.app.doc.dots.clear();
}

<*
 An empty document, a fresh history and the camera back where `framed` put it.

 The B5 checks assert on exact dot and edge counts, so each one starts from a
 known rig rather than from whatever the check above it left behind. The tree
 and the AppState's address are untouched — rebuilding either would invalidate
 every pointer the widgets hold.
*>
fn void Fixture.reset(&self)
{
	self.clear_dots();
	self.app.doc.edges.clear();
	// Ids restart at 0 here, unlike in the app where they are never reused, so a
	// pin left behind would come back attached to whichever dot inherited its
	// id — an unrelated one, in an unrelated check.
	self.app.doc.attachments.clear();
	// And a limit table, which is keyed by dot id the same way a pin is.
	self.app.doc.rotation_limits.clear();
	// Same reasoning as the pins above: a body plan left behind would make the
	// next check's hand-built rig claim to be a biped, and the library would
	// offer or refuse packs on a tag nothing in that check ever set.
	self.app.doc.set_plan("");
	// The open card is view state, but the checks below read clips through it —
	// one left closed by an earlier check would make the next one's library
	// look empty.
	self.app.expanded_pack = self.app.packs.len() > 0 ? 0 : -1;
	self.app.doc.next_id = 0;
	self.app.doc.root_id = 0;
	self.app.doc.auto_connect = true;

	// `UndoStack.clear`, not the list's own: an ADD_DOT or DELETE_DOT edit owns
	// a copy of the dot's name, and emptying the list underneath the stack drops
	// one string per named dot.
	self.app.undo_stack.clear();

	self.app.selected = 0;
	self.app.also_selected.clear();
	self.app.scene_selection = SceneSelection.NONE;
	self.app.outliner_scene_collapsed = false;
	self.app.outliner_model_collapsed = false;
	self.app.outliner_skeleton_collapsed = false;
	self.app.outliner_collapsed_joints.clear();
	self.app.config.viewport_shading = ShadingMode.SOLID;
	self.app.fill_shading = ShadingMode.SOLID;
	self.app.show_mesh = true;
	self.app.show_rig = true;

	// A tick is a choice about a rig this reset is throwing away, and one left
	// behind would go into the next check's export without it asking.
	self.app.doc.free_animations();

	// Off and owing a rebind, the state `new_app` starts in. The tints array
	// itself is left alone — `rebind_tints` frees it before it replaces it, and
	// `AppState.free` frees whatever is last.
	self.app.tint_mode = TintMode.OFF;
	self.app.weights_stale = true;
	self.app.notice_length = 0;

	// Overlay state, and off is what `new_app` starts in. Left on it would print
	// a name over every dot the next check places, which several of them count
	// glyphs against.
	self.app.show_joint_names = false;

	// Both halves visible, which is `new_app` again — and here it is not a matter
	// of tidiness: a hidden rig answers no pick and refuses to place, so a check
	// that inherited one would fail on its very first click with nothing to say
	// why.
	self.app.show_mesh = true;
	self.app.show_rig = true;

	self.app.camera = crig::framed(cube().bounds());

	// The dialogs are widget state, not app state, so nothing above puts them
	// away — and a panel left open covers the middle of the window, which is
	// where nearly every check below aims its clicks. The file chooser is worse
	// than the reference: it is modal, so it swallows every click rather than
	// merely sitting under some of them.
	//
	// By type, over every match: `find` answers with the first Dialog in tree
	// order, which would leave the other one open.
	self.ui.@each(Dialog; dialog) { dialog.widget_as(Dialog).set_open(dialog, false); };

	self.app.refresh_ui();
	self.ui.flush();
}

<*
 Where a dot currently is on screen, in WINDOW coordinates a gesture can be
 aimed at. The projection answers in viewport-local pixels; the viewport sits
 below the bar, and forgetting to add that origin back is exactly the class of
 off-by-a-region mistake this suite exists to catch.

 Through `dot_position`, so while a clip is playing this answers where the dot
 is *drawn* rather than where the document stores it. Aiming a gesture anywhere
 else would be aiming at a circle nobody can see.
*>
fn Vec2? Fixture.pixel_of(&self, uint id)
{
	Dot* dot = self.doc().find(id);
	if (!dot) return crig::BEHIND_CAMERA~;
	Vec2 local = crig::project(
		self.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y),
		self.app.dot_position(*dot),
		VIEWPORT)!;
	return local + VIEWPORT_ORIGIN;
}

<*
 Where a dot's rest position lands on screen, in the same WINDOW coordinates —
 which is a different pixel from `pixel_of` exactly while a clip is running.
*>
fn Vec2? Fixture.rest_pixel_of(&self, uint id)
{
	Dot* dot = self.doc().find(id);
	if (!dot) return crig::BEHIND_CAMERA~;
	Vec2 local = crig::project(
		self.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y), dot.position, VIEWPORT)!;
	return local + VIEWPORT_ORIGIN;
}

<*
 What the stats block currently reads, its lines joined by newlines.

 The block itself, not a copy of it: `hud_lines` is the function the paint
 walks, so an assertion against this is an assertion about the screen. The
 snapshot comes from the widget, so the values that move faster than paints —
 the drag delta, the reach — are the ones the last frame accepted.

 Valid until the next call: both buffers live on the fixture and are reused.
*>
fn String Fixture.hud_text(&self)
{
	crig::HudOverlay*? hud = self.ui.get_widget(crig::HudOverlay);
	if (catch hud) return "";

	crig::HudLine[crig::HUD_MAX_LINES] lines;
	usz count = crig::hud_lines(&self.app, hud.shown, self.hud_scratch[..], lines[..]);

	usz used = 0;
	for (usz i = 0; i < count; i++)
	{
		if (i > 0 && used < self.hud_joined.len) self.hud_joined[used++] = '\n';
		foreach (c : lines[i].text)
		{
			if (used >= self.hud_joined.len) break;
			self.hud_joined[used++] = c;
		}
	}
	return (String)self.hud_joined[:used];
}

<*
 Whether an element with this id currently exists — which for a dropdown item
 is the same question as "is that menu open", since the items are built when it
 opens and released when it closes.
*>
fn bool Fixture.in_tree(&self, String id)
{
	if (catch self.ui.find_id(id)) return false;
	return true;
}

<*
 Run frames until the weight debounce has fired, or long enough to prove it
 never will.

 Bounded rather than `while (stale)`, so a debounce that stops counting down
 fails the run instead of hanging it.
*>
fn void Fixture.settle_weights(&self)
{
	for (uint i = 0; i < 40 && self.app.weights_stale; i++) self.feed(VIEWPORT_CENTER);
}

<*
 One frame with nothing arriving, and whether anything asked for another.

 The pointer is fed back at exactly where it already is, so the frame dispatches
 nothing at all: no move, no hover change, no press. That is the frame the idle
 render loop is deciding whether to sleep after, and it decides it the same way
 — clear `frame_requested`, run the frame, read the flag back — so this is the
 real question and not a model of it.

 @return `True if the frame scheduled another one, i.e. the loop must not sleep.`
*>
fn bool Fixture.idle_frame(&self)
{
	self.ui.frame_requested = false;
	self.feed(self.ui.input.mouse);
	return self.ui.frame_requested;
}

<*
 Run idle frames until one schedules nothing, or long enough to say none ever
 will.

 Bounded for the same reason `settle_weights` is: a tree that repaints itself
 every frame forever should fail the run rather than hang it.

 @return `True if the interface went quiet.`
*>
fn bool Fixture.settles(&self)
{
	for (uint i = 0; i < 40; i++)
	{
		if (!self.idle_frame()) return true;
	}
	return false;
}

<*
 What the result line currently says — the HUD paints `AppState.notice()`
 directly, so the state is the display.
*>
fn String Fixture.notice_text(&self) => self.app.notice();

<*
 The middle of an element, in window coordinates.

 Read back from the tree rather than recomputed from the constants in
 `ui/ui_tree.c3`: the point of aiming at a widget is to hit where it actually
 ended up.
*>
fn Vec2? Fixture.center_of(&self, String id)
{
	return self.ui.target_id(id)!.center();
}

<*
 Open a dock popup menu (⋯, Clip tools) with its button, and click one of its
 rows. The rows are built when the menu opens, so they are found by id only then.
*>
fn void Fixture.pick_menu_item(&self, String button_id, String item_id)
{
	self.click(self.center_of(button_id)!!);
	self.ui.flush();
	self.click(self.center_of(item_id)!!);
	self.ui.flush();
}

<*
 Open a popup menu and leave it open; `close_menu` dismisses it.
*>
fn void Fixture.open_menu(&self, String button_id)
{
	self.click(self.center_of(button_id)!!);
	self.ui.flush();
}

fn void Fixture.close_menu(&self)
{
	self.feed_key(Key.ESCAPE);
	self.ui.flush();
}

<*
 The N-panel's Pose tab, open: the 3D view's pane, where the panel lives, brought
 up first (a one-pane fixture may be showing the Animations dock).
*>
fn void Fixture.open_pose_tab(&self)
{
	if (try Element* strip = self.ui.find(AreaTabStrip)) self.click(tab_center(self, strip, 0));
	self.ui.flush();
	if (!(self.app.show_joint_panel && self.app.joint_panel_tab == crig::JointPanelTab.POSE))
	{
		self.click(self.center_of(crig::JOINT_TAB_POSE_ID)!!);
	}
	self.ui.flush();
}

// ---------------------------------------------------------------------------

<*
 crig with no model: it opens, it is usable, and it says what is missing.

 The claim is that "no mesh" is a state rather than an error. Two things make it
 one and both are asserted here: nothing on the way up faults — `build_picker`
 cannot be asked for a BVH over zero triangles, and every cast through it has to
 answer "missed" instead of dereferencing null — and a click on the empty view
 says why it did nothing, because a pointer that silently stops working is the
 same picture as a broken one.

 Its own fixture, and the only check that has one: see `Fixture.open`.
*>
fn void an_empty_app_opens_and_says_so() @test
{
	io::printn("an empty app opens and says so");

	Fixture fixture;
	if (catch fixture.open(mesh: {}))
	{
		test::@check(false, "SKIPPED — the interface would not build over an empty mesh");
		return;
	}
	defer fixture.close();

	test::@check(!fixture.app.has_mesh(), "an app built on nothing knows it has no mesh");

	// The two casts a click goes through, each asked directly: the picker is
	// empty, so both have to answer without a BVH to read.
	collision::Ray ray = { .origin = { 0, 0, 10 }, .direction = { 0, 0, -1 } };
	Vec3? snapped = fixture.app.picker.snap_inside(ray);
	test::@check(@ok(snapped) == false, "a ray into an empty scene finds no surface");
	test::@check(!fixture.app.picker.occluded({ 0, 0, 10 }, { 0, 0, 0 }), "and hides nothing behind nothing");

	Element* prompt = fixture.ui.find_id("prompt")!!;
	test::@check(prompt.size.x > 0.0f && prompt.size.y > 0.0f, "the empty view carries a line saying so");

	// Centred in the pane rather than parked at its corner: it is the only thing
	// on screen, and the check is that `Anchored` was given a measured size to
	// centre — a zero-sized prompt would sit at the exact middle and pass a
	// looser test than this one.
	Vec2 middle = prompt.absolute + prompt.size * 0.5f;
	test::@check((middle - VIEWPORT_CENTER).length() < 2.0f, "in the middle of it");

	sz before = fixture.doc().dots.len();
	fixture.click(VIEWPORT_CENTER);
	test::@check(fixture.doc().dots.len() == before, "a click places no dot when there is nothing to place it in");
	test::@check(fixture.notice_text().len > 0, "and says why rather than going quiet");
}

<*
 The file chooser: File > Import .glb brings it up, the listing walks, and
 picking a model asks for it rather than loading it.

 The last of those is the one that is easy to get wrong and impossible to see. A
 model cannot be loaded from inside a frame — the mesh pass holds buffers the GPU
 may still be reading — so the dialog raises `pending_add` and main's loop, which
 is between frames by definition, does the work. A version that loaded it here
 would pass every visible test and crash on a real machine under load.
*>
fn void the_file_dialog_opens_and_walks() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the file dialog opens, walks and asks");
	fixture.reset();

	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);

	Vec2? open_item = fixture.center_of("Import .glb…");
	if (catch open_item)
	{
		test::@check(false, "SKIPPED — the Import item is not in the dropdown");
		return;
	}
	fixture.click(open_item);

	Dialog*? dialog = fixture.ui.get_widget_id(crig::FILE_DIALOG_ID, Dialog);
	if (catch dialog)
	{
		test::@check(false, "SKIPPED — there is no file dialog in the tree");
		return;
	}
	test::@check(dialog.open, "File > Import .glb brings up the chooser");
	test::@check(dialog.title == "Import .glb into the scene", "titled for the question it is asking");

	Element*? browser_elem = fixture.ui.find_id(crig::FILE_BROWSER_ID);
	if (catch browser_elem)
	{
		test::@check(false, "SKIPPED — the chooser has no listing in it");
		return;
	}
	FileBrowser* browser = browser_elem.widget_as(FileBrowser);

	// Somewhere known, with folders in it and .glb files one level down: the
	// repository this test is run from.
	browser.go_to(browser_elem, "assets");
	fixture.ui.flush();

	test::@check(browser.rows() > 1, "the listing shows what is in a folder");
	test::@check(browser.entry_at_name("animations") >= 0, "including the folders");

	// A .glb sits inside assets/animations, not in assets — so if the row for
	// the folder walks in, the listing that comes back is a different one.
	int folder = browser.entry_at_name("animations");
	fixture.browser_click(browser_elem, folder);
	fixture.browser_click(browser_elem, folder); // the second click on the selected row activates
	fixture.ui.flush();

	test::@check(browser.directory.str_view().ends_with("animations"), "clicking a folder twice walks into it");
	test::@check(browser.entry_at_name("humanoid.glb") >= 0, "and lists the models inside");
	test::@check(browser.entry_at_name("DejaVuSans.ttf") < 0, "and nothing that is not a model");

	// The field follows the browser, which is what makes it the breadcrumb.
	TextField*? field = fixture.ui.get_widget_id(crig::FILE_PATH_ID, TextField);
	if (catch field)
	{
		test::@check(false, "SKIPPED — the chooser has no path field");
		return;
	}
	test::@check(field.value().ends_with("animations/"), "the path field says where the listing is");

	int model = browser.entry_at_name("humanoid.glb");
	fixture.browser_click(browser_elem, model);
	fixture.ui.flush();
	test::@check(field.value().ends_with("humanoid.glb"), "and names the file when one is picked");

	// The parent row walks back out, and it is row 0 wherever there is one.
	fixture.browser_click(browser_elem, 0);
	fixture.browser_click(browser_elem, 0);
	fixture.ui.flush();
	test::@check(browser.directory.str_view().ends_with("assets"), "the top row goes back up");

	// --- and the loading itself is deferred ---

	browser.go_to(browser_elem, "assets/animations");
	fixture.ui.flush();
	model = browser.entry_at_name("humanoid.glb");
	fixture.browser_click(browser_elem, model);
	fixture.browser_click(browser_elem, model);
	fixture.ui.flush();

	test::@check(fixture.app.pending_add.ends_with("humanoid.glb"), "choosing a model asks main to import it");
	test::@check(!fixture.app.has_mesh() || fixture.app.geometry.positions.len == 8,
		"and does not load it here: the mesh pass has to be rebuilt between frames");
	test::@check(!dialog.open, "and the chooser closes behind it");

	// Cleared, or the fixture's next check would inherit a load request that
	// nothing in this test binary is going to service.
	alloc::free(mem, fixture.app.pending_add.ptr);
	fixture.app.pending_add = "";
}

// A model that is genuinely on disk, for the row that has to be openable.
const String RECENT_MESH = "assets/animations/humanoid.glb";

<*
 The recent projects, at the top of the chooser.

 Three things, and the second is the one worth having a check for. A row is a
 shortcut to `request_open`, so it must ask `main` to load rather than load here
 — the same bargain the browser strikes, and the same use-after-free if it were
 broken. A row whose file has gone has to consume its click: falling through
 would put the click on whatever the dialog redraws underneath.

 The fixture's config is backed by no file, so remembering a project here stays
 in memory and writes nothing — see `CrigConfig.directory`.
*>
fn void the_chooser_offers_recent_projects() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("recent projects in the chooser:");
	fixture.reset();

	test::@check(fixture.app.config.directory.len == 0,
		"the fixture's config is backed by no file, so nothing here touches one");

	// --- with nothing opened yet, the rows are absent rather than empty ---

	open_the_chooser(fixture);
	test::@check(!fixture.in_tree(crig::RECENT_LIST_ID), "a first run offers no recent rows at all");
	close_the_chooser(fixture);

	// --- and with something opened, they are there ---

	// One that is really on disk and one that is not, because the difference
	// between them is most of what a row does. `SESSION_MESH` will not do for
	// the live one: the session checks write only the .json beside it, so the
	// model it names has never existed and the row would grey.
	fixture.app.config.remember_recent(RECENT_MESH);
	fixture.app.config.remember_recent("/gone/nowhere.glb");

	open_the_chooser(fixture);
	Element*? rows_elem = fixture.ui.find_id(crig::RECENT_LIST_ID);
	if (catch rows_elem)
	{
		test::@check(false, "SKIPPED — the chooser has no recent rows");
		return;
	}
	test::@check(rows_elem.size.y > 0, "two projects give the panel a height (%f)", rows_elem.size.y);

	// Newest first, so the one that does not exist is row 0. Clicking it says so
	// and goes no further — the check is that nothing was asked to load.
	fixture.recent_click(rows_elem, 0);
	test::@check(fixture.app.pending_open.len == 0, "a row whose model is gone opens nothing");
	test::@check(fixture.ui.find_id(crig::FILE_DIALOG_ID)!!.widget_as(Dialog).open,
		"and leaves the chooser up rather than closing on a dead end");

	// The one that is there.
	fixture.recent_click(rows_elem, 1);
	test::@check(fixture.app.pending_open.ends_with(crig::base_name(RECENT_MESH)),
		"a row that is there asks main to load it (%s)", fixture.app.pending_open);
	test::@check(!fixture.ui.find_id(crig::FILE_DIALOG_ID)!!.widget_as(Dialog).open,
		"and the chooser closes behind it");

	String taken = fixture.app.take_pending_open();
	taken.free(mem);

	// --- but not when the question is where to write ---

	// Browse from the export panel opens the same chooser for the other purpose.
	// Offering the five models most recently opened as somewhere to *write* is
	// an invitation to overwrite one with a rig of itself.
	crig::open_file_dialog(fixture.ui, crig::FilePurpose.EXPORT_TARGET);
	fixture.ui.flush();
	test::@check(!fixture.in_tree(crig::RECENT_LIST_ID), "picking an export target offers no recent models");
	close_the_chooser(fixture);
}

// The chooser, up and laid out, however the menu happens to be arranged.
fn void open_the_chooser(Fixture* fixture)
{
	crig::open_file_dialog(fixture.ui, crig::FilePurpose.OPEN_MESH);
	fixture.ui.flush();
}

fn void close_the_chooser(Fixture* fixture)
{
	if (try Element* dialog = fixture.ui.find_id(crig::FILE_DIALOG_ID))
	{
		dialog.widget_as(Dialog).set_open(dialog, false);
	}
	fixture.ui.flush();
}

<*
 Click the middle of a recent row, as one press-release over it.

 The move first is not decoration: the row under the pointer is what `hit_at`
 answers for, and a press with no preceding move arrives from wherever the last
 check left the mouse.
*>
fn void Fixture.recent_click(&self, Element* rows, usz row)
{
	Vec2 at = rows.absolute + (Vec2){ rows.size.x * 0.5f, ((float)row + 0.5f) * crig::RECENT_ROW_H };
	self.feed(at);
	self.click(at);
}

<*
 Loading a model replaces everything that was measured against the old one.

 The half of Open that `main` performs, minus the GPU: a picker, a voxel grid, a
 shell decomposition, a camera and a symmetry plane are all functions of the
 mesh, and a stale one of any of them is a dot placed in the wrong body. Runs on
 a real file rather than a second cube, because the claim is about a mesh whose
 bounds and vertex count differ from what was there before.
*>
fn void loading_a_model_rebuilds_what_it_measured() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("loading a model rebuilds what it measured");
	fixture.reset();

	// A rig over the old mesh, so there is something that must not survive.
	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.ensure_a_dot();

	// This test is about importing a bare glTF, not reopening an authored
	// project. The user's source may legitimately have a .rigsmith.json beside it.
	String source = string::format(mem, "%s/humanoid.glb", library::ready());
	defer source.free(mem);
	rig::TriMesh? loaded = rig::load_gltf(mem, source);
	if (catch loaded)
	{
		test::@check(false, "SKIPPED — the fixture mesh could not be read from assets");
		return;
	}

	float old_scale = fixture.app.picker.scale;
	usz old_vertices = fixture.app.geometry.positions.len;

	fixture.app.load_mesh(loaded, source);
	fixture.ui.flush();

	test::@check(fixture.app.geometry.positions.len != old_vertices, "the mesh is the one that was opened");
	test::@check(fixture.app.picker.scale != old_scale, "the picker was rebuilt around it");
	test::@check(fixture.app.voxels.usable(), "and so was the voxel grid");
	test::@check(fixture.app.source_path == source, "the path follows the mesh");

	// The old rig is gone, and what stands in its place is the new file's own —
	// `humanoid.glb` is a pack, so it carries a skeleton and opening it adopts that
	// rather than leaving an empty document over a model that already has one.
	// Checked by name, since "some dots" would also be true of the two that were
	// here.
	usz named = 0;
	foreach (dot : fixture.app.doc.dots.array_view())
	{
		if (dot.name.len > 0) named++;
	}
	test::@check(named == (usz)fixture.app.doc.dots.len() && named > 2,
		"the file's own rig came in, all of it named — %d dots, %d named",
		fixture.app.doc.dots.len(), named);

	// One entry, and it is the import: the old model's history went with the old
	// model, and undoing here empties the document rather than bringing its dots
	// back.
	test::@check(fixture.app.undo_stack.can_undo(), "the import is on the history");
	fixture.app.undo();
	test::@check(fixture.app.doc.dots.len() == 0, "which undoes to an empty rig, not to the old one");
	test::@check(!fixture.app.undo_stack.can_undo(), "and nothing of the old model's history is under it");

	// The symmetry plane is the new body's middle, not the old one's — mirroring
	// against a plane measured on another mesh puts every twin outside it.
	float middle = fixture.app.geometry.bounds().center().x;
	test::@check(math::abs(fixture.app.doc.sym_x - middle) < 1.0e-4f, "the mirror plane is this body's middle");

	// A click still lands inside, which is the end-to-end version of all of the
	// above: the ray, the BVH and the camera all have to agree about one mesh.
	fixture.click(VIEWPORT_CENTER);
	test::@check(fixture.doc().dots.len() == 1, "and a click places a dot in the new body");

	// Back to the cube the rest of the file is written against. `load_mesh` frees
	// what it owns, so the fixture's original static mesh has to go back in as a
	// borrowed one — which is what `new_app` handed it.
	fixture.app.load_mesh(cube(), "");
	fixture.app.owns_geometry = false;
	fixture.reset();
}

<*
 A skin binding does not outlive the mesh it describes.

 The binding is one row per vertex of one particular model, so `load_mesh` has
 to let go of it — and letting go is two things, not one. `SkinBinding.free`
 releases its arrays and leaves the slices pointing at them, so a binding that
 is freed and left in place is freed a second time by the next rebind, which
 aborts in the allocator rather than drawing something wrong.

 Both halves are asserted: that the binding is empty after the swap, and that
 posing the new model — which frees whatever the field holds before rebinding —
 gets all the way through.
*>
fn void a_binding_does_not_outlive_its_mesh() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a skin binding does not outlive its mesh");
	fixture.reset();

	// A parked animation binds a skin over the cube. The binding is the thing
	// this check is about rather than the animation that asked for one.
	fixture.click(SPOT_A);
	fixture.click(SPOT_C);
	AnimRef cube_clip = fixture.app.new_clip("Cube bind", 1.0f, from_rest: true);
	fixture.app.editing = cube_clip;
	fixture.app.park_clip(cube_clip, 0.0f);
	if (!fixture.app.animating || fixture.app.skin.vertices == 0)
	{
		test::@check(false, "SKIPPED — the parked animation did not bind the cube");
		return;
	}

	String source = RECENT_MESH;
	rig::TriMesh? loaded = rig::load_gltf(mem, source);
	if (catch loaded)
	{
		test::@check(false, "SKIPPED — the fixture mesh could not be read from assets");
		return;
	}

	fixture.app.load_mesh(loaded, source);
	fixture.ui.flush();

	test::@check(fixture.app.skin.vertices == 0, "the binding goes with the mesh it counted");
	test::@check(fixture.app.skin.joints.len == 0 && fixture.app.skin.weights.len == 0,
		"and is emptied rather than left pointing at what it released");

	// The rebind the user reaches for next, and the one that would free those
	// slices again. Nothing here can assert an abort — it takes the process with
	// it — so the check is that the frame after it still runs.
	fixture.click(VIEWPORT_CENTER);
	AnimRef loaded_clip = fixture.app.new_clip("Loaded bind", 1.0f, from_rest: true);
	fixture.app.editing = loaded_clip;
	fixture.app.park_clip(loaded_clip, 0.0f);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.app.skin.vertices != cube().positions.len,
		"and animating the new model binds it rather than the mesh that is gone");

	fixture.app.load_mesh(cube(), "");
	fixture.app.owns_geometry = false;
	fixture.reset();
}

<*
 A body plan over an existing rig asks before it replaces one.

 Three claims, and the middle one is the reason the dialog exists at all: an
 empty document is not asked, a rig that is there is asked and *nothing changes
 until the answer*, and Cancel really does leave the work alone. The fourth —
 that Replace swaps rather than stacks — is `check_preset_lands_as_one_edit`'s,
 which drives the model directly.

 Driven through `request_pack_rig` rather than through the library's pixels,
 because what is being asserted is the gate rather than the button: anything
 that later grows a way to apply a plan comes through the same door.
*>
fn void applying_a_rig_asks_before_replacing() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("applying a body plan asks before it replaces one");
	fixture.reset();

	int biped = fixture.app.plan_pack("biped");
	if (biped < 0)
	{
		test::@check(false, "SKIPPED — the fixture found no biped plan");
		return;
	}

	Element*? panel = fixture.ui.find_id(crig::CONFIRM_DIALOG_ID);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — there is no confirm dialog in the tree");
		return;
	}
	ConfirmDialog* ask = panel.widget_as(ConfirmDialog);

	// Nothing to lose: applied on the spot, and no panel. A confirmation nobody
	// could answer differently is a click taken from the user.
	crig::request_pack_rig(fixture.ui, biped);
	fixture.ui.flush();
	test::@check(!ask.asking(panel), "an empty document is not asked");
	sz fitted = fixture.doc().dots.len();
	test::@check(fitted > 0, "and the plan lands straight away");

	// Now there is. The question goes up and the document is untouched until it
	// is answered — the whole point of asking.
	crig::request_pack_rig(fixture.ui, biped);
	fixture.ui.flush();
	test::@check(ask.asking(panel), "a rig already placed brings up the question");
	test::@check(fixture.doc().dots.len() == fitted, "and nothing is replaced while it stands");
	test::@check(fixture.app.pending_rig_pack == biped, "the pack asked about is the one parked");

	// The message is the widget's own, copied out of the temporary that named
	// the pack — the whole reason this is a cui widget rather than a buffer on
	// the app.
	test::@check(ask.message.str_view().contains("replace the rig"), "the panel carries the question it was asked");

	// And it is on screen, not merely open in the state. The confirming button
	// is the one thing in this tree painted in the accent as a rounded rect, so
	// counting them before and after says the panel actually reached the canvas
	// — the difference between a dialog and a flag called `open`.
	usz accents = drawn(fixture, DrawingKind.RECT, crig::ACCENT);
	test::@check(accents > 0, "and paints a panel with a confirming button in it");

	// Dismissed rather than answered: ESC and the close button both land on
	// `on_decline`, so this is the same route the user's Escape key takes.
	panel.widget_as(ConfirmDialog).withdraw(panel);
	crig::answer_rig_dialog(fixture.ui, false);
	fixture.ui.flush();
	test::@check(!ask.asking(panel), "declining closes it");
	test::@check(fixture.doc().dots.len() == fitted, "and leaves the rig exactly as it was");
	test::@check(fixture.app.pending_rig_pack < 0, "with no question still standing");

	fixture.reset();
}

<*
 A mesh that arrives with no skeleton is offered one.

 The third tier of `adopt_source_rig` used to be silent: an empty document over a
 model with no skin, no notice, and the only route to a body plan a cell in a
 pane that may not be open. This is the panel that replaced the silence, and the
 four claims are the whole of what makes it better than a sentence — it comes up
 by itself, it discharges its request so closing it is final, it *lists* the
 plans rather than naming the pane that lists them, and its button actually fits
 one.

 The list's labels are the last claim, and the one that is easy to get wrong:
 three of the shipped library files declare `biped`, so a list keyed on the plan
 tag would be three rows reading the same word.
*>
fn void a_mesh_with_no_skeleton_is_offered_a_body_plan() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a mesh with no skeleton is offered a body plan");
	fixture.reset();

	Element*? panel = fixture.ui.find_id(crig::RIG_PROMPT_DIALOG_ID);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — there is no rig prompt in the tree");
		return;
	}
	Dialog* prompt = panel.widget_as(Dialog);
	test::@check(!prompt.open, "the panel stays closed until something raises it");

	// What a skinless import leaves behind — `adopt_source_rig`'s third tier sets
	// exactly this, from a place that has no `Ui*` to open a panel with.
	fixture.app.wants_rig_prompt = true;
	fixture.idle_frame();

	test::@check(prompt.open, "a mesh with no skeleton raises the panel");
	test::@check(!fixture.app.wants_rig_prompt,
		"and the request is discharged, so dismissing it is final rather than a one-frame reprieve");

	// It offers the plans rather than pointing at the pane that holds them.
	test::@check(fixture.app.plan_rows.len > 0,
		"the panel lists the body plans it found — %d", fixture.app.plan_rows.len);
	test::@check(fixture.app.plan_rows.len == fixture.app.plan_row_packs.len,
		"with a pack behind every row");

	// Named by pack, not by tag. Rows that share a plan must still be tellable
	// apart, which is the whole reason the label is the pack's name.
	foreach (usz i, row : fixture.app.plan_rows)
	{
		foreach (usz j, other : fixture.app.plan_rows)
		{
			if (i >= j || row.trailing != other.trailing) continue;
			test::@check(row.label != other.label,
				"two packs tagged '%s' are told apart by name, not by tag", row.trailing);
		}
	}

	// And the button fits one. Through `request_pack_rig`, so an empty document
	// is not asked — which is the case this panel exists for.
	crig::rig_prompt_apply(fixture.ui);
	fixture.ui.flush();

	test::@check(fixture.doc().dots.len() > 0, "fitting the selected plan leaves a rig behind");
	test::@check(!prompt.open, "and closes the panel behind it");

	fixture.reset();
}

<*
 The "No skeleton" panel goes away once a skeleton exists, whoever made it.

 Its own button closes it on the way through; a rig fitted from anywhere else — an
 MCP apply_plan, the Assets pane — used to leave it standing over a rigged mesh,
 saying the opposite of what the viewport showed. Opened from Rig › Apply body
 plan over a rig that is already there, it is a deliberate choice of a new plan
 and must not close itself on the next frame.
*>
fn void the_no_skeleton_panel_closes_when_a_rig_arrives_elsewhere() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the no-skeleton panel closes when a rig arrives elsewhere");
	fixture.reset();

	Element*? panel = fixture.ui.find_id(crig::RIG_PROMPT_DIALOG_ID);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — there is no rig prompt in the tree");
		return;
	}
	Dialog* prompt = panel.widget_as(Dialog);

	fixture.app.wants_rig_prompt = true;
	fixture.idle_frame();
	test::@check(prompt.open, "a mesh with no skeleton raises the panel");
	test::@check(fixture.app.plan_row_packs.len > 0, "the library offers a body plan to fit");
	if (fixture.app.plan_row_packs.len == 0) return;

	// Not through the panel: the way an agent's apply_plan arrives.
	test::@check(fixture.app.apply_pack_rig((usz)fixture.app.plan_row_packs[0]), "the plan fits");
	fixture.idle_frame();
	test::@check(!prompt.open, "the panel closes once the mesh has a skeleton");

	// The menu over a rig that is already there: a choice, so it stays.
	crig::menu_apply_body_plan(fixture.ui);
	fixture.idle_frame();
	fixture.idle_frame();
	test::@check(prompt.open, "Rig › Apply body plan over a rig keeps the panel open");
	crig::close_rig_prompt(fixture.ui);

	fixture.reset();
}

<*
 A pose keyed into a clip comes back when the playhead returns to it.

 The whole of pose-and-key, end to end, through the seam both halves cross: the
 transient editor draft is keyed by dot id while a clip is sampled by joint
 index. Saving reads one and `pose_from_clip` writes the other, and if the two
 disagree about the mapping the figure comes back
 posed as a different animal.

 Two keys, because one proves nothing: a clip with a single key holds that pose
 at every instant, so scrubbing anywhere would "work". With two, the playhead has
 to land on the right one.

 The scrub is `park_clip`, which is what the timeline drags — so this also
 asserts the thing that makes a scrub a scrub: the clip stays on screen with its
 clock stopped, rather than playback stopping and the mesh going back to rest.
*>
fn void a_keyed_pose_comes_back_when_scrubbed_to() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a keyed pose comes back when the playhead returns to it");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	// A joint to move, and the dot id to read it back by.
	uint moved = 0;
	foreach (dot : fixture.doc().dots.array_view())
	{
		if (dot.name == PLAN_THIGH_L) moved = dot.id;
	}
	if (moved == 0)
	{
		test::@check(false, "SKIPPED — the fitted plan has no %s to pose", PLAN_THIGH_L);
		return;
	}

	// Two forward swings of the thigh, both inside the plan's hip limit — a swing
	// backwards past 20° is clamped, and this is about keys, not limits.
	Quaternionf first = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), -0.6f);
	Quaternionf second = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), -0.2f);

	// Start from rest, then replace its first key with the first edited pose.
	AnimRef ref = fixture.app.new_clip("test_walk", 1.0f, from_rest: true);
	if (!ref.valid())
	{
		test::@check(false, "a new clip could not be started");
		return;
	}
	fixture.app.editing = ref;
	test::@check(fixture.app.pose_from_clip(ref, 0.0f), "the first pose would not open");
	test::@check(fixture.app.set_working_pose(moved, first, {}), "the first pose did not change");
	fixture.app.pose_edit_pending = true;
	test::@check(fixture.app.key_pose_edit(), "the first pose could not be keyed");
	ref = fixture.app.editing;
	test::@check(fixture.app.clip(ref).keyframes.len == 1, "replacing the first pose added another key");

	// Pose differently, and key that in half a second later.
	fixture.app.edit_time = 0.5f;
	test::@check(fixture.app.pose_from_clip(ref, 0.5f), "the second pose would not open");
	test::@check(fixture.app.set_working_pose(moved, second, {}), "the second pose did not change");
	fixture.app.pose_edit_pending = true;
	test::@check(fixture.app.key_pose_edit(), "the second pose could not be keyed");
	ref = fixture.app.editing;
	if (!ref.valid())
	{
		test::@check(false, "the second pose could not be keyed");
		return;
	}
	test::@check(fixture.app.clip(ref).keyframes.len == 2,
		"%d keys after keying a second pose", fixture.app.clip(ref).keyframes.len);

	// Now scrub back to the first key and read the pose out of the document.
	test::@check(fixture.app.park_clip(ref, 0.0f), "the clip would not park");
	test::@check(fixture.app.animating, "parking stopped playback rather than the clock");
	test::@check(fixture.app.anim_paused, "and it did not park");

	test::@check(fixture.app.pose_from_clip(ref, 0.0f), "the clip would not seed a pose");
	Quaternionf back;
	foreach (posed : fixture.app.pose_edit_draft)
	{
		if (posed.dot_id == moved) back = posed.rotation;
	}
	test::@check(1.0f - math::abs(back.v.dot(first.v)) < 1.0e-3f,
		"the first key came back as %s rather than the pose that was keyed", back.v);

	// And the second, which is what says the playhead is being read at all.
	test::@check(fixture.app.pose_from_clip(ref, 0.5f), "the clip would not seed at the second key");
	foreach (posed : fixture.app.pose_edit_draft)
	{
		if (posed.dot_id == moved) back = posed.rotation;
	}
	test::@check(1.0f - math::abs(back.v.dot(second.v)) < 1.0e-3f,
		"the second key came back as %s", back.v);

	// The clock really is stopped: ticking a parked clip must not move it.
	float held = fixture.app.anim_time;
	fixture.app.tick_animation(0.25f);
	test::@check(fixture.app.anim_time == held,
		"a parked clip advanced to %s under a tick", fixture.app.anim_time);

	// And letting it go starts it running again.
	fixture.app.resume_clip();
	fixture.app.tick_animation(0.1f);
	test::@check(fixture.app.anim_time > held, "resuming left the clock stopped");

	fixture.app.stop_animation();
	fixture.app.discard_pose_edit();
	fixture.reset();
}

<*
 The dopesheet draws the clip being edited, and a key lands where the playhead is.

 The pane's second half, driven the way a person drives it: pick an animation,
 press Edit, and the sheet fills with a lane per joint the clip drives and a
 marker per key. Then pose, key, and watch a marker appear at the playhead.

 The lane count is the interesting assertion. A clip's keyframes are a list of
 times each naming *some* joints, and a sheet is the transpose of that — one row
 per joint, markers along it. Getting the transpose wrong is the kind of mistake
 that still draws something plausible, so the check counts both ways: as many
 lanes as the clip has distinct joints, and as many markers as there are
 (joint, key) pairs.
*>
fn void the_dopesheet_draws_the_clip_being_edited() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the dopesheet draws the clip being edited");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	// A clip of this rig's own making, so every lane is a joint the rig has.
	uint moved = 0;
	foreach (dot : fixture.doc().dots.array_view())
	{
		if (dot.name == PLAN_THIGH_L) moved = dot.id;
	}
	if (moved == 0)
	{
		test::@check(false, "SKIPPED — the fitted plan has no %s to pose", PLAN_THIGH_L);
		return;
	}

	AnimRef ref = fixture.app.new_clip("sheet_test", 1.0f, from_rest: true);
	if (!ref.valid())
	{
		test::@check(false, "a clip could not be started");
		return;
	}
	fixture.app.bind_ref(ref);
	fixture.app.editing = ref;
	fixture.app.edit_time = 0.0f;
	// Keying is a posing job: the key row is greyed out in the Joints stage.
	fixture.app.stage = crig::EditStage.POSE_STAGE;

	// Onto the pane.
	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, TAB_ANIMATIONS));
	fixture.ui.flush();

	// The id sits on the wrapper widget; the `Timeline` is its child, so the
	// sheet is reached by type rather than by id.
	Element*? found = fixture.ui.find(Timeline);
	if (catch found)
	{
		test::@check(false, "SKIPPED — the pane has no dopesheet");
		return;
	}
	Element* elem = found;
	Timeline* sheet = elem.widget_as(Timeline);

	// The beginner view summarizes all driven joints in one pose lane.
	usz joints = fixture.app.timeline_tracks.len;
	test::@check(joints > 0, "the clip drives no joints, so the sheet has nothing to draw");
	test::@check(sheet.lanes.len == 1, "the default sheet should summarize poses");

	test::@check(sheet.marks.len == fixture.app.clip(ref).keyframes.len,
		"the summary should show one marker per keyframe");

	// A lane for a joint this rig has must not be dimmed — dimming means "the clip
	// drives this and the figure cannot", and every joint here came off the figure.
	foreach (lane : sheet.lanes)
	{
		test::@check(!lane.dimmed, "%s was dimmed on the rig it was keyed from", lane.label);
	}

	// The sheet's axis is the clip's duration, so a marker at t maps to a pixel
	// inside the track. Round-tripping through the widget's own arithmetic is what
	// says the paint and the hit test agree.
	float mid = sheet.at_of(elem, sheet.x_of(elem, 0.5f));
	test::@check(math::abs(mid - 0.5f) < 0.1f,
		"a position round-tripped through the track as %s", mid);

	// Key a second pose half a second in, and the sheet grows markers.
	usz before = sheet.marks.len;
	fixture.app.edit_time = 0.5f;
	test::@check(fixture.app.pose_from_clip(ref, fixture.app.edit_time),
		"the second sheet pose would not open");
	test::@check(fixture.app.set_working_pose(moved,
		quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), -0.4f), {}),
		"the second sheet pose did not change");
	fixture.app.pose_edit_pending = true;

	Vec2? key_button = fixture.center_of(crig::ANIM_KEY_ID);
	if (catch key_button)
	{
		test::@check(false, "SKIPPED — the pane has no Key pose button");
		return;
	}
	fixture.click(key_button);
	fixture.ui.flush();

	test::@check(fixture.app.clip(fixture.app.editing).keyframes.len == 2,
		"%d keys after pressing Key pose", fixture.app.clip(fixture.app.editing).keyframes.len);

	Timeline* after = fixture.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(after.marks.len > before, "the sheet still shows %d markers", after.marks.len);

	// The scoped buttons stay below a bounded, independently scrolling sheet.
	// Selected adds only the selected joint at the parked time; Changed without
	// a draft is deliberately a no-op rather than manufacturing a whole-pose key.
	fixture.app.select(moved);
	fixture.app.edit_time = 0.75f;
	crig::anim_space_context(fixture.ui, 0.75f, fixture.center_of(crig::ANIM_KEY_ID)!!);
	fixture.ui.flush();
	Vec2? selected_button = fixture.center_of(crig::ANIM_KEY_SELECTED_ID);
	if (catch selected_button)
	{
		test::@check(false, "the dense dopesheet pushed Selected out of the pane");
		return;
	}
	fixture.click(selected_button);
	fixture.ui.flush();
	test::@check(fixture.app.clip(fixture.app.editing).keyframes.len == 3,
		"Selected did not add a key at the parked time");
	test::@check(fixture.app.clip(fixture.app.editing).keyframes[2].dots.len == 1,
		"Selected keyed %d joints", fixture.app.clip(fixture.app.editing).keyframes[2].dots.len);

	usz scoped_keys = fixture.app.clip(fixture.app.editing).keyframes.len;
	crig::anim_space_context(fixture.ui, 0.75f, fixture.center_of(crig::ANIM_KEY_ID)!!);
	fixture.ui.flush();
	Vec2? changed_button = fixture.center_of(crig::ANIM_KEY_CHANGED_ID);
	if (catch changed_button)
	{
		test::@check(false, "the dense dopesheet pushed Changed out of the pane");
		return;
	}
	fixture.click(changed_button);
	fixture.ui.flush();
	test::@check(fixture.app.clip(fixture.app.editing).keyframes.len == scoped_keys,
		"Changed created a key without an edited draft");
	test::@check(fixture.notice_text().starts_with("no unkeyed pose changes"),
		"Changed did not explain its no-op: %s", fixture.notice_text());

	// Stable transport hooks and automatic pose saving by default.
	String[] transport = {
		crig::ANIM_START_ID, crig::ANIM_PREV_ID, crig::ANIM_TRANSPORT_PLAY_ID,
		crig::ANIM_NEXT_ID, crig::ANIM_END_ID, crig::ANIM_TIME_ID,
	};
	foreach (id : transport)
	{
		test::@check(fixture.ui.find_id(id)!! != null, "the animation pane has no %s", id);
	}
	test::@check(fixture.app.authored_dirty, "keying did not mark animation work unsaved");
	test::@check(fixture.ui.find_id(crig::ANIM_SAVE_STATUS_ID)!!.widget_as(Label).text
		== "Animation changes unsaved · Ctrl+S to save", "the pane hides unsaved animation work");
	// Saving changes the status without recording an edit. Exercise that update
	// independently of the filesystem round trips in animation persistence tests.
	fixture.app.authored_dirty = false;
	fixture.feed({ 0, 0 });
	fixture.ui.flush();
	test::@check(fixture.ui.find_id(crig::ANIM_SAVE_STATUS_ID)!!.widget_as(Label).text
		== "Animation keys saved with project", "saving did not refresh the animation status");
	fixture.app.authored_dirty = true;
	ToggleButton*? auto_key = fixture.ui.get_widget_id(crig::ANIM_AUTO_KEY_ID, ToggleButton);
	if (catch auto_key)
	{
		test::@check(false, "the animation pane has no Auto-key toggle");
	}
	else
	{
		test::@check(auto_key.on, "Auto-key should be on by default");
	}

	fixture.click(fixture.center_of(crig::ANIM_START_ID)!!);
	fixture.ui.flush();
	test::@check(math::abs(fixture.app.edit_time) < 0.001f, "Start left the playhead at %s", fixture.app.edit_time);
	fixture.feed_key(Key.PERIOD);
	fixture.ui.flush();
	test::@check(math::abs(fixture.app.edit_time - 1.0f / 30.0f) < 0.001f,
		"Period stepped to %s rather than one frame", fixture.app.edit_time);
	fixture.feed_key(Key.END);
	fixture.ui.flush();
	test::@check(math::abs(fixture.app.edit_time - 1.0f) < 0.001f,
		"End left the playhead at %s", fixture.app.edit_time);

	// The arrows step a frame the way , and . do.
	fixture.feed_key(Key.LEFT_ARROW);
	test::@check(math::abs(fixture.app.edit_time - (1.0f - 1.0f / 30.0f)) < 0.001f,
		"Left stepped to %s rather than one frame back", fixture.app.edit_time);
	fixture.feed_key(Key.RIGHT_ARROW);
	test::@check(math::abs(fixture.app.edit_time - 1.0f) < 0.001f,
		"Right stepped to %s rather than one frame on", fixture.app.edit_time);

	// Held, an arrow keeps stepping once the repeat delay is up — at the clip's
	// frame rate, so never further than the time it was held — and stops on release.
	fixture.feed_key(Key.HOME);
	Vec2 where = fixture.ui.input.mouse;
	for (int i = 0; i < 40; i++) fixture.feed(where, keys: { Key.RIGHT_ARROW });
	float held = fixture.app.edit_time;
	test::@check(held > 3.0f / 30.0f, "holding Right for %s s stepped only to %s", 40 * DT, held);
	test::@check(held <= 40 * DT + 0.001f, "holding Right ran ahead of the clock, to %s", held);
	fixture.feed(where);
	fixture.feed(where);
	fixture.feed(where);
	test::@check(math::abs(fixture.app.edit_time - held) < 0.0001f,
		"the playhead kept moving after Right came up: %s from %s", fixture.app.edit_time, held);

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.app.stop_animation();
	fixture.app.discard_pose_edit();
	fixture.doc().free_animations();
	fixture.app.editing = crig::NO_ANIM;
	fixture.reset();
}

<*
 The Animations pane lists what is bound, and its buttons act on the selection.

 The pane is the working set made visible, so the claims are that it shows the
 set, that it shows a binding it *cannot resolve* rather than hiding it, and that
 unbinding through it really takes the clip off the character.

 The unresolvable row is the one worth driving: it is the state a moved library
 folder leaves behind, it is the state the format was shaped to preserve, and it
 is the one a naive list would drop on the floor.
*>
fn void the_animations_pane_lists_what_is_bound() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the animations pane lists what is bound");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	// One real binding, and one naming a file that does not exist.
	AnimRef usable = crig::NO_ANIM;
	foreach (usz p, &pack : fixture.app.packs)
	{
		foreach (usz c, clip : pack.clips)
		{
			AnimRef ref = { (int)p, (int)c };
			if (fixture.app.clip_applies(ref) && !usable.valid()) usable = ref;
		}
	}
	if (!usable.valid())
	{
		test::@check(false, "SKIPPED — no clip in the library can address the fitted rig");
		return;
	}
	test::@check(fixture.app.bind_ref(usable), "the real clip did not bind");
	test::@check(fixture.doc().bind_clip("nowhere/gone.glb", "Vanished"), "the missing one did not bind");

	// Onto the pane. It is the fourth view, appended so `LIBRARY_VIEW` stays put.
	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, TAB_ANIMATIONS));
	fixture.ui.flush();

	if (catch fixture.ui.find_id(crig::ANIM_PANEL_ID))
	{
		test::@check(false, "SKIPPED — the Animations pane is not in the tree");
		return;
	}

	test::@check(fixture.app.anim_rows.len == 2,
		"the pane lists both bindings — %d rows", fixture.app.anim_rows.len);

	// The one that cannot be found is listed, and says which file it wanted.
	bool listed_missing = false;
	foreach (row : fixture.app.anim_rows)
	{
		if (row.label == "Vanished" && row.trailing.contains("gone.glb")) listed_missing = true;
	}
	test::@check(listed_missing, "a binding that cannot be resolved is dropped rather than shown as missing");

	// And only one of the two resolves, which is what the export summary counts.
	usz total;
	usz found;
	fixture.app.bound_counts(&total, &found);
	test::@check(total == 2 && found == 1, "%d of %d bindings resolve", found, total);

	// Unbind through the pane. The selection starts on the first row, so the second
	// is picked the way a person picks it.
	if (!fixture.pick_anim_row(1))
	{
		test::@check(false, "SKIPPED — the pane has no second row to pick");
		return;
	}
	fixture.ui.flush();
	test::@check(fixture.app.anim_selected == 1, "pressing the second row did not select it");
	fixture.click(fixture.center_of("anim-more")!!);
	fixture.ui.flush();

	Vec2? unbind = fixture.center_of(crig::ANIM_UNBIND_ID);
	if (catch unbind)
	{
		test::@check(false, "SKIPPED — the pane has no Unbind button");
		return;
	}
	fixture.click(unbind);
	fixture.ui.flush();

	test::@check(fixture.doc().animations.len() == 1, "unbinding left %d", fixture.doc().animations.len());
	test::@check(fixture.doc().bound_index("nowhere/gone.glb", "Vanished") < 0,
		"and it took the row that was selected");
	test::@check(!fixture.ui.find_id(crig::ANIM_CLIP_MENU_ID)!!.widget_as(Dialog).open,
		"the clip menu stayed open after Remove from character");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.doc().free_animations();
	fixture.reset();
}

<*
 Play leaves the highlight on the row that was pressed.

 The pane rebuilds itself when playback starts — `AnimSnapshot` watches which clip
 is running — and the selection used to live inside the `Tree`, initialised to row
 0 by the build. So pressing Play on the third clip played the third clip and lit
 the first row: the pane's own button moved the highlight off the thing it had just
 started, and every button in the pane acts on that highlight.

 Both the state and the widget are asserted. The state is what the buttons read
 and the widget is what is painted, and the bug was invisible in the first and
 plain in the second.

 Stop is checked as well as Play, because it is the same rebuild in the other
 direction — the fix has to be about where the selection lives, not about which
 handler was taught to put it back.
*>
fn void playing_keeps_the_row_that_was_pressed() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("play leaves the highlight on the row that was pressed");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	// Two clips this rig can carry, so the row pressed is not the row a reset would
	// land on — with one binding, or with the first one picked, the bug is invisible.
	AnimRef first = crig::NO_ANIM;
	AnimRef second = crig::NO_ANIM;
	foreach (usz p, &pack : fixture.app.packs)
	{
		foreach (usz c, clip : pack.clips)
		{
			AnimRef ref = { (int)p, (int)c };
			if (!fixture.app.clip_applies(ref)) continue;
			if (!first.valid()) { first = ref; continue; }
			if (!second.valid()) second = ref;
		}
	}
	if (!second.valid())
	{
		test::@check(false, "SKIPPED — the library offers fewer than two clips this rig can carry");
		return;
	}
	test::@check(fixture.app.bind_ref(first) && fixture.app.bind_ref(second),
		"SKIPPED — the two clips did not bind");

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, TAB_ANIMATIONS));
	fixture.ui.flush();

	fixture.click(fixture.center_of("anim-chooser")!!);
	fixture.ui.flush();
	Vec2 choose_second;
	fixture.ui.@each(SelectOption; option)
	{
		if (option.widget_as(SelectOption).index == 1)
		{
			choose_second = option.absolute + option.size * 0.5f;
		}
	};
	fixture.click(choose_second);
	fixture.ui.flush();
	if (fixture.app.anim_selected != 1)
	{
		test::@check(false, "SKIPPED — the pane has no second row to press");
		return;
	}
	fixture.ui.flush();
	test::@check(fixture.app.anim_selected == 1, "pressing the second row did not select it");

	String wanted = fixture.app.clip(fixture.app.editing).name.copy(mem);
	defer wanted.free(mem);

	Vec2? play = fixture.center_of(crig::ANIM_TRANSPORT_PLAY_ID);
	if (catch play)
	{
		test::@check(false, "SKIPPED — the pane has no Play button");
		return;
	}
	fixture.click(play);
	fixture.ui.flush();

	test::@check(fixture.app.animating, "SKIPPED — the editing clip did not start");
	test::@check(fixture.app.current_anim.name == wanted,
		"Play started %s rather than the editing clip, %s",
		fixture.app.current_anim.name, wanted);
	test::@check(fixture.app.anim_selected == 1,
		"pressing Play moved the selection to row %d", (int)fixture.app.anim_selected);

	Select*? list = fixture.ui.get_widget_id("anim-chooser", Select);
	if (catch list)
	{
		test::@check(false, "SKIPPED — the pane has no list after the rebuild");
		return;
	}
	test::@check(list.selected == 1,
		"the list draws row %d as the chosen one, not the row that was pressed", (int)list.selected);

	// The same rebuild the other way round.
	fixture.app.stop_animation();
	fixture.ui.flush();
	test::@check(fixture.app.anim_selected == 1, "stopping moved the selection");
	if (try Select* after = fixture.ui.get_widget_id("anim-chooser", Select))
	{
		test::@check(after.selected == 1, "and the list drew a different row after the stop");
	}

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.doc().free_animations();
	fixture.reset();
}

<*
 The viewport says which of the two things is missing.

 `OpenPrompt` was the empty-state line for "no model loaded". A mesh with no rig
 is the same situation one step along and used to draw nothing at all, which left
 a loaded-but-unrigged model looking finished. `shown` is what the check reads
 because it is also what sizes the element: a prompt that decided to speak but
 measured zero would be centred correctly and invisible.
*>
fn void the_viewport_names_whichever_half_is_missing() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the viewport names whichever half is missing");
	fixture.reset();

	OpenPrompt*? line = fixture.ui.get_widget_id("prompt", OpenPrompt);
	if (catch line)
	{
		test::@check(false, "SKIPPED — there is no prompt in the tree");
		return;
	}

	// The fixture opens on a cube, so the model is there and the rig is not.
	fixture.idle_frame();
	test::@check(line.shown, "a mesh with no dots still has something to say");

	// One dot is a rig. Nothing is missing any more and the line goes away —
	// zero-sized, which is what takes it out of the layout rather than merely
	// painting nothing over the top of the model.
	fixture.ensure_a_dot();
	fixture.idle_frame();
	test::@check(!line.shown, "and a rig placed takes the line away");
	test::@check(line.measured.x == 0.0f && line.measured.y == 0.0f,
		"leaving nothing in the layout — measured %s", line.measured);

	fixture.reset();
}

<*
 Ctrl+A takes the whole document, and does not collide with plain A.

 The collision is the point: A alone toggles auto-connect, and the two live in
 the same key handler. A Ctrl+A that also flipped auto-connect would be a
 shortcut nobody could use twice.
*>
fn void ctrl_a_selects_every_dot() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("ctrl+A selects every dot");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);
	if (fixture.doc().dots.len() != 3)
	{
		test::@check(false, "SKIPPED — the three dots did not land");
		return;
	}

	// Deselected first, so what Ctrl+A produces cannot be mistaken for what the
	// last click left behind.
	fixture.app.select(0);
	bool auto_connect = fixture.doc().auto_connect;

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.A);
	test::@check(fixture.app.selection_count() == 3, "ctrl+A selects every dot in the document");
	test::@check(fixture.doc().auto_connect == auto_connect, "and does not toggle auto-connect on the way");
	test::@check(fixture.app.selected != 0, "with one of them as the anchor");

	// The same chord with both keys new in one frame, which is what the event
	// queue delivers whenever they were pressed between the same two frames —
	// on a render loop that sleeps between them, most of them. A handler reading
	// the previous frame's held set sees a bare A and toggles auto-connect.
	fixture.app.select(0);
	Key[2] together = { Key.LEFT_CTRL, Key.A };
	fixture.feed(VIEWPORT_CENTER, keys: together[..]);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.app.selection_count() == 3, "a chord pressed inside one frame is still a chord");
	test::@check(fixture.doc().auto_connect == auto_connect, "and does not fall through to the bare key");

	// The anchor stays put when there already is one, so Ctrl+A adds the rest
	// rather than moving what the modes act through.
	uint anchor = fixture.doc().dots[1].id;
	fixture.app.select(anchor);
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.A);
	test::@check(fixture.app.selected == anchor, "an existing anchor keeps the role");
	test::@check(fixture.app.selection_count() == 3, "and the rest join it");

	fixture.tap(VIEWPORT_CENTER, Key.X);
	test::@check(fixture.doc().dots.len() == 0, "X then clears the document");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == 3, "and one undo brings all of it back");
}

<*
 Binding a clip puts it on the character, and it stays there.

 What replaced the export panel's picker. The set of animations a character has
 used to be a tick list owned by the export dialog — created when it opened,
 destroyed by the next `load_mesh`, and invisible in between. It is the
 document's now, so the claims are about the document: the browser's + binds and
 unbinds, the binding survives the rig being cleared and refitted, it is what an
 export would ship, and it goes into the session text.

 Driven through the cell's own bind target rather than through `toggle_bound`, so
 the check covers the hit test as well as the state — the two small targets in a
 cell are diagonally opposite for a reason, and this is what would notice them
 overlapping.
*>
fn void binding_a_clip_puts_it_on_the_character() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("binding a clip puts it on the character");
	fixture.reset();

	if (fixture.app.packs.len() == 0)
	{
		test::@check(false, "SKIPPED — the fixture found no animation packs");
		return;
	}

	// A rig the biped clips can address. The plan names every dot it places, so
	// this is the state a user is in when the question is worth asking at all.
	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}
	fixture.ui.flush();

	// The browser's cells only exist while the Assets pane is the one showing —
	// a pane builds the view its tab selects and nothing else.
	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, 1));
	fixture.ui.flush();

	// The first animation cell that is actually on screen — binding is driven
	// through its bind target, so a row with no element cannot be used.
	usz row = fixture.app.visible_assets.len;
	for (usz i = 0; i < fixture.app.visible_assets.len; i++)
	{
		AssetEntry* entry = fixture.app.visible_asset(i);
		if (entry && entry.kind == AssetKind.ANIMATION && fixture.asset_cell_at(i))
		{
			row = i;
			break;
		}
	}
	if (row >= fixture.app.visible_assets.len)
	{
		test::@check(false, "SKIPPED — no animation cell is on screen to bind");
		return;
	}

	String clip_name = fixture.app.visible_asset(row).name.copy(mem);
	defer clip_name.free(mem);

	test::@check(!fixture.app.is_bound_entry(fixture.app.visible_asset(row)),
		"nothing is bound to a fresh character");

	if (!fixture.bind_click(row))
	{
		test::@check(false, "SKIPPED — the cell went away between finding it and clicking it");
		return;
	}
	fixture.ui.flush();

	test::@check(fixture.doc().animations.len() == 1, "the + binds the clip — %d bound",
		fixture.doc().animations.len());
	test::@check(fixture.app.is_bound_entry(fixture.app.visible_asset(row)),
		"and the cell knows it without opening a file");

	// A rig cleared and refitted. A binding is about the character rather than
	// about whichever skeleton it currently has, so it must not be collateral.
	fixture.clear_dots();
	fixture.ui.flush();
	test::@check(fixture.doc().animations.len() == 1, "clearing the rig does not unbind anything");
	fixture.app.apply_plan_named("biped");
	fixture.ui.flush();

	// What an export would ship. Resolved through the library, which is the step
	// that turns a stored path and name back into a template.
	AnimTemplate[] shipping = fixture.app.bound_templates(mem);
	defer if (shipping.len > 0) alloc::free(mem, shipping);
	test::@check(shipping.len == 1, "and it is what an export would carry — %d clips", shipping.len);

	// Into the session text, which is what makes it survive a restart.
	String text = crig::session_text(mem, fixture.doc(), "cube.glb");
	defer text.free(mem);
	test::@check(text.contains(`"animations"`), "the session writes the bound set");
	test::@check(text.contains(clip_name), "naming the clip it bound");

	// And off again, through the same target.
	fixture.bind_click(row);
	fixture.ui.flush();
	test::@check(fixture.doc().animations.len() == 0, "a second press unbinds it");

	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, 0));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.reset();
}

<*
 The + refuses a clip whose name is not in the file, instead of binding whatever
 is at that position.

 A binding is a path plus a name, and `resolve_bound` looks it up by name and by
 nothing else — so the name the browser binds under has to be one the file really
 carries, or the binding is made and then can never be found again. `ref_for_asset`
 is happy to answer by *position* when the name missed, which is a fair guess for
 greying a cell and the wrong one here: it would put a different animation on the
 character than the one that was pressed, and the cell's mark would stay out.

 The state is reached by renaming the index entry in place, which is the state a
 file re-authored under crig's feet leaves behind — the clip renamed inside it
 while the scan still remembers the old spelling. Restored afterwards, and the same
 press is made again to show the refusal was about the name and not about the file.
*>
fn void the_bind_target_refuses_a_clip_it_cannot_name() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the + refuses a clip whose name the file does not carry");
	fixture.reset();

	usz row = fixture.app.visible_assets.len;
	for (usz i = 0; i < fixture.app.visible_assets.len; i++)
	{
		AssetEntry* entry = fixture.app.visible_asset(i);
		if (entry && entry.kind == AssetKind.ANIMATION)
		{
			row = i;
			break;
		}
	}
	if (row >= fixture.app.visible_assets.len)
	{
		test::@check(false, "SKIPPED — the fixture library holds no clip");
		return;
	}

	AssetEntry* entry = fixture.app.visible_asset(row);
	String kept = entry.name;
	entry.name = "Ghost clip";

	test::@check(!fixture.app.toggle_bound_row(row), "a clip the file does not name was bound anyway");
	test::@check(fixture.doc().animations.len() == 0,
		"and something went onto the character — %d bound", fixture.doc().animations.len());

	// In words, at that. A + that does nothing and says nothing is indistinguishable
	// from a + that is broken, which is how the last mismatch of this kind survived.
	test::@check(fixture.app.notice().contains("Ghost clip"),
		"the refusal did not name the clip it refused — the line reads \"%s\"", fixture.app.notice());

	entry.name = kept;
	test::@check(fixture.app.toggle_bound_row(row), "and the same clip, named as its file names it, did not bind");
	test::@check(fixture.app.is_bound_entry(fixture.app.visible_asset(row)),
		"the binding it made is not one the grid can see");

	fixture.doc().free_animations();
	fixture.reset();
}

<*
 Pressing the body of a clip cell neither starts an animation nor stops one.

 The grid lists the library and the Animations pane lists the character, so
 playing is the second pane's. It used to be the first's: a click on a cell played
 the clip and a click on the playing one stopped it, which left the pane that
 knows nothing about a character as the only place an animation could be started
 from, and the pane that lists the character's own clips with less to do than it.

 Both halves of that toggle are checked, because they failed differently — one
 would start playback nothing asked for, the other would stop playback started
 somewhere else. What is left is the selection moving, which is the whole of the
 feedback for a press with no other effect.

 Aimed at the middle of the cell on purpose. The + and the gear are in the top
 corners, and this is the check that would notice one of them spreading over the
 middle and quietly turning a press into a binding.
*>
fn void a_clip_cell_no_longer_plays_what_it_shows() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a clip cell does not play the clip it shows");
	fixture.reset();

	if (fixture.app.packs.len() == 0)
	{
		test::@check(false, "SKIPPED — the fixture found no animation packs");
		return;
	}

	// A rig the biped clips can address, so the cell about to be pressed is one the
	// old click would have played rather than refused.
	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}
	fixture.ui.flush();

	Element*? strip = fixture.ui.find(AreaTabStrip);
	if (catch strip)
	{
		test::@check(false, "SKIPPED — no tab strip in the tree");
		return;
	}
	fixture.click(tab_center(fixture, strip, TAB_ASSETS));
	fixture.ui.flush();

	// A clip out of the biped pack, which is the one this rig was fitted from — a
	// clip from another plan is greyed, and a greyed cell would pass this check
	// without ever reaching the code it is about.
	usz row = fixture.app.visible_assets.len;
	for (usz i = 0; i < fixture.app.visible_assets.len; i++)
	{
		AssetEntry* entry = fixture.app.visible_asset(i);
		if (!entry || entry.kind != AssetKind.ANIMATION) continue;
		if (!crig::base_name(entry.file).contains("humanoid")) continue;
		if (fixture.app.asset_flags(i).disabled) continue;
		if (!fixture.asset_cell_at(i)) continue;
		row = i;
		break;
	}
	if (row >= fixture.app.visible_assets.len)
	{
		test::@check(false, "SKIPPED — no playable clip from the biped plan is on screen");
		return;
	}

	int pack = fixture.app.loaded_pack_for(fixture.app.visible_asset(row).file);
	if (pack < 0)
	{
		test::@check(false, "SKIPPED — the biped pack is not loaded");
		return;
	}
	AnimRef ref = fixture.app.ref_for_asset(pack, fixture.app.visible_asset(row));
	if (!ref.valid())
	{
		test::@check(false, "SKIPPED — the cell names no clip in its pack");
		return;
	}

	// The body of the cell, clear of both corners.
	Element* cell = fixture.asset_cell_at(row);
	fixture.click(cell.absolute + cell.size * 0.5f);
	fixture.ui.flush();

	test::@check(!fixture.app.animating, "pressing a clip cell started the animation");
	test::@check(fixture.doc().animations.len() == 0,
		"pressing the body of a cell bound the clip — that is the + on it, not the cell");

	// It was felt, though. Nothing else in the grid says a press landed on a clip.
	test::@check(fixture.app.selected_asset == (int)fixture.app.visible_assets[row],
		"the press moved no selection, so a click on a clip has no answer at all");

	// And the other half: playback started where playback lives is not stopped by
	// pressing the cell of the clip that is running.
	if (!fixture.app.play_clip(ref))
	{
		test::@check(false, "SKIPPED — the biped clip would not play on the biped rig");
		return;
	}
	fixture.app.refresh_ui();
	fixture.ui.flush();
	test::@check(fixture.app.animating, "SKIPPED — the clip did not start");

	cell = fixture.asset_cell_at(row);
	if (!cell)
	{
		test::@check(false, "SKIPPED — the cell went away when the clip started");
		return;
	}
	fixture.click(cell.absolute + cell.size * 0.5f);
	fixture.ui.flush();
	test::@check(fixture.app.animating, "pressing the playing clip's cell stopped it");

	fixture.app.stop_animation();
	if (try Element* back = fixture.ui.find(AreaTabStrip)) fixture.click(tab_center(fixture, back, TAB_3D));
	fixture.viewport = fixture.ui.find(Viewport)!!;
	fixture.reset();
}

<*
 An export with clips bound writes a file that carries them.

 The end of the chain binding starts: bound entries resolve to templates,
 templates become channels, and the file comes back with as many animations as
 were bound. Everything between here and the glTF is asserted in
 `anim-import-test`; what this adds is that the interface hands the writer what
 the user chose rather than something else.
*>
fn void an_export_carries_the_bound_clips() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an export carries the bound clips");
	fixture.reset();

	if (!fixture.app.apply_plan_named("biped"))
	{
		test::@check(false, "SKIPPED — the biped plan could not be fitted to the cube");
		return;
	}

	AnimRef usable = crig::NO_ANIM;
	foreach (usz p, &pack : fixture.app.packs)
	{
		foreach (usz c, clip : pack.clips)
		{
			AnimRef ref = { (int)p, (int)c };
			if (fixture.app.clip_applies(ref) && !usable.valid()) usable = ref;
		}
	}
	if (!usable.valid())
	{
		test::@check(false, "SKIPPED — no clip in the library can address the fitted rig");
		return;
	}

	fixture.app.bind_ref(usable);

	String written = "build/ui_test_export_clips.glb";
	(void)io::file::delete(written);

	AnimTemplate[] chosen = fixture.app.bound_templates(mem);
	defer if (chosen.len > 0) alloc::free(mem, chosen);

	fixture.app.point_at("build/ui_test_cube.glb");
	fixture.app.export_rig(written, chosen);

	test::@check(io::file::is_file(written), "the export writes the file it was pointed at");
	test::@check(fixture.notice_text().contains("1 clips"), "and the notice counts what went into it");

	crig::AnimPack? read_back = crig::read_pack(mem, written);
	if (catch read_back)
	{
		test::@check(false, "SKIPPED — what it wrote could not be read back");
		(void)io::file::delete(written);
		return;
	}
	crig::AnimPack pack = read_back;
	defer pack.free(mem);

	test::@check(pack.clips.len == 1, "and the file carries the clip that was bound");
	test::@check(pack.mesh.positions.len == 8, "beside the body it was skinned to");

	(void)io::file::delete(written);

	// The binding belongs to this check; the ones after it start from nothing.
	fixture.doc().free_animations();
}

<*
 The key a Mac keyboard labels "delete" erases the character behind the caret.

 The interesting half is the platform table, not the widget. macOS names the
 backspace key kVK_Delete (51) and the forward-delete key kVK_ForwardDelete
 (117), so a mapping written from those names hands cui a `Key.DELETE` for the
 key the user reaches for to correct a typo. `TextField` then does exactly what
 it was told and deletes forwards, which with the caret at the end of what was
 just typed is nothing — the key reads as dead rather than as wrong.

 So the code is taken from the platform's own table rather than assumed, and the
 field is driven with whatever that table produced. Asserting the two separately
 would let them drift back apart and still pass.
*>
fn void the_delete_key_erases_what_was_typed() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the delete key erases what was typed");
	fixture.reset();

	crig::open_file_dialog(fixture.ui, crig::FilePurpose.OPEN_MESH);
	fixture.ui.flush();

	Element*? field_elem = fixture.ui.find_id(crig::FILE_PATH_ID);
	if (catch field_elem)
	{
		test::@check(false, "SKIPPED — the chooser has no path field");
		return;
	}
	TextField* field = field_elem.widget_as(TextField);

	field.set_text(field_elem, "ab");
	field_elem.request_focus();
	fixture.ui.flush();

	Key erase = Key.BACKSPACE;
	Key forward = Key.DELETE;
	$if env::DARWIN:
		erase = (Key)c3w::darwinKeycodeToEventKey(51).code;
		forward = (Key)c3w::darwinKeycodeToEventKey(117).code;
		test::@check(erase == Key.BACKSPACE, "the mac delete key arrives as backspace");
		test::@check(forward == Key.DELETE, "and fn+delete arrives as delete");
	$endif

	// The caret is at the end, which is where it sits after typing and is the
	// position at which erasing backwards and erasing forwards differ most: one
	// takes a character, the other has none to take.
	fixture.feed_key(erase);
	test::@check(field.value() == "a", "the delete key takes the character behind the caret");

	fixture.feed_key(forward);
	test::@check(field.value() == "a", "and forward delete at the end has nothing to take");

	field.caret = 0;
	fixture.feed_key(forward);
	test::@check(field.value() == "", "but from the start it takes the character ahead");

	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();
}

<*
 Typing in the path field does not reach the application's shortcuts.

 The one property a text field in this interface must have. `AppRoot` owns every
 single-letter command — B hides the mesh, X deletes the selected dot — and cui
 bubbles a key the focused widget declines all the way down to it. A field that
 does not consume what it types edits the document on every character.
*>
fn void typing_a_path_does_not_reach_the_shortcuts() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("typing a path does not reach the shortcuts");
	fixture.reset();

	crig::open_file_dialog(fixture.ui, crig::FilePurpose.OPEN_MESH);
	fixture.ui.flush();

	Element*? field_elem = fixture.ui.find_id(crig::FILE_PATH_ID);
	if (catch field_elem)
	{
		test::@check(false, "SKIPPED — the chooser has no path field");
		return;
	}
	TextField* field = field_elem.widget_as(TextField);

	field.set_text(field_elem, "");
	field_elem.request_focus();
	fixture.ui.flush();

	bool mesh_before = fixture.app.show_mesh;
	bool rig_before = fixture.app.show_rig;

	// B and S are the two that would be felt: they hide the halves of the view.
	// Each goes in as the platform sends it — the character on `Input.text` and
	// the key code beside it, which is the half that would reach `AppRoot`.
	fixture.type_into(field_elem, "b", keys: { Key.B });
	fixture.type_into(field_elem, "s", keys: { Key.S });

	test::@check(field.value() == "bs", "what was typed lands in the field");
	test::@check(fixture.app.show_mesh == mesh_before, "and B does not hide the mesh");
	test::@check(fixture.app.show_rig == rig_before, "and S does not hide the rig");

	// Backspace is a key rather than text, and has to be the field's too.
	fixture.feed_key(Key.BACKSPACE);
	test::@check(field.value() == "b", "backspace takes the last character back");

	// ESC is the exception, and it is what closes the dialog: a field that
	// swallowed it would take the keyboard hostage inside a modal panel.
	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();

	Dialog*? dialog = fixture.ui.get_widget_id(crig::FILE_DIALOG_ID, Dialog);
	if (catch dialog)
	{
		test::@check(false, "SKIPPED — there is no file dialog in the tree");
		return;
	}
	test::@check(!dialog.open, "and escape still reaches the dialog");
}

<*
 The shortcuts still work once the dialog that had the keyboard is gone.

 Focus is granted by left presses and by nothing else, so an element holding it
 when its subtree is released takes every shortcut in the window with it: the
 path field is focused by the click that puts the caret in it, and dismissing
 the chooser left the keyboard pointed at nothing at all. Ctrl+A is only the
 witness — undo, delete and the display toggles were all dead in the same
 window, until whatever the user clicked next happened to restore it.
*>
fn void the_keyboard_outlives_a_dialog() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the keyboard outlives a dialog");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the two dots did not land");
		return;
	}
	fixture.app.select(0);

	crig::open_file_dialog(fixture.ui, crig::FilePurpose.OPEN_MESH);
	fixture.ui.flush();

	Element*? field_elem = fixture.ui.find_id(crig::FILE_PATH_ID);
	if (catch field_elem)
	{
		test::@check(false, "SKIPPED — the chooser has no path field");
		return;
	}

	// Clicked rather than focused by hand: the click is what a user does, and it
	// is what puts the doomed element in the focus slot.
	fixture.click(field_elem.absolute + field_elem.size * 0.5f);
	test::@check(fixture.ui.focused == field_elem, "clicking the path field gives it the keyboard");

	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();

	// No click in between — that would paper over the whole thing.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.A);
	test::@check(fixture.app.selection_count() == 2, "and the shortcuts answer again once it closes");
}

<*
 The end-to-end claim: a click on the model becomes a dot where it was clicked.

 The reprojection is the half that pick-test already covers in isolation; what
 is new here is that the pixel came through `Ui.process_input` and the widget
 tree, so the viewport's element has to be sized and positioned to the render
 region for it to land.
*>
fn void click_places_a_dot() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("click places a dot");

	sz before = fixture.doc().dots.len();
	fixture.click(VIEWPORT_CENTER);
	sz after = fixture.doc().dots.len();

	test::@check(after == before + 1, "a press and release on the model adds one dot");
	if (after != before + 1) return;

	Dot dot    = fixture.doc().dots[after - 1];
	Vec2? back = fixture.pixel_of(dot.id);
	if (catch back)
	{
		test::@check(false, "the new dot projects back onto the screen");
		return;
	}

	float error = (back - VIEWPORT_CENTER).length();
	io::printfn("       placed %.4f px from the click", error);
	test::@check(error < PIXEL_TOLERANCE, "the dot lands under the pixel that placed it");

	test::@check(fixture.hud_text().contains("1 joint · 0 bones"),
		"the block does not count the dot it just gained: \"%s\"", fixture.hud_text());
}

<*
 The B4 regression class, and the reason this file exists — now aimed at the
 menu bar, which is what paints over the viewport since the panel left.

 A gesture on the bar must do nothing to the model underneath, including a drag
 that starts on the bar and ends over the model: the bar consumes the press, so
 the capture belongs to it. The camera is the sharper assertion of the two:
 placing needs the ray to hit the mesh, so "no dot appeared" can be true for
 the wrong reason, whereas yaw moves on any orbit at all.
*>
fn void menu_bar_blocks_the_viewport() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the menu bar is opaque to the viewport");

	sz before = fixture.doc().dots.len();
	float yaw = fixture.app.camera.yaw;

	fixture.drag(BAR_POINT, BAR_POINT + (Vec2) { DRAG_PIXELS, DRAG_PIXELS });

	test::@check(fixture.doc().dots.len() == before, "a drag off the bar places no dot");
	test::@check(fixture.app.camera.yaw == yaw, "and does not orbit the camera");

	// The other direction, so the two checks above cannot both be passing
	// because input stopped arriving anywhere at all.
	test::@check(fixture.ui.hit_test(VIEWPORT_CENTER) == fixture.viewport, "the viewport still owns the middle of the window");
}

<*
 The `ignores_pointer` regression.

 The HUD is painted over the viewport, so before cui grew `ignores_pointer` an
 overlay like it won the hit test and events bubbled to its parents — never to
 the surface underneath. It is a child of the viewport now, so bubbling would
 reach the viewport either way; aiming at it still catches the case where a
 future annotation is added as a sibling instead.
*>
fn void the_hud_is_click_through() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the HUD block is click-through");

	Vec2? hud = fixture.center_of("hud");
	if (catch hud)
	{
		test::@check(false, "the HUD block is in the tree");
		return;
	}

	test::@check(fixture.ui.hit_test(hud) == fixture.viewport, "the hit test on the HUD text resolves to the viewport");

	float yaw = fixture.app.camera.yaw;
	fixture.drag(hud, hud + (Vec2) { DRAG_PIXELS, 0 });
	test::@check(fixture.app.camera.yaw != yaw, "a drag starting on the HUD text orbits");
}

<*
 The crosshair covers the whole view, including the overlays drawn on it.

 Viewport declares it from `mount` rather than `on_hover` precisely because
 hover fires on the deepest element only: the HUD block is painted on top, so a
 shape asked for on the way in would go unasked whenever the pointer entered
 the view over it. Resolution walks up from the hovered element instead, which
 is what makes one declaration answer for the subtree.

 An overlay that IS interactive still speaks for itself — the gizmo asks for
 the hand and gets it, since the walk stops at the deepest element with a
 preference. The two halves together are the rule: the viewport answers for
 everything that does not.
*>
fn void the_crosshair_covers_the_whole_view() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the crosshair covers the view and its overlays");

	Vec2 middle = fixture.viewport.absolute + fixture.viewport.size * 0.5f;
	fixture.feed(middle);
	test::@check(fixture.ui.cursor == Cursor.CROSSHAIR, "over bare model, the pointer is a crosshair");

	Vec2? hud   = fixture.center_of("hud");
	Vec2? gizmo = fixture.center_of("gizmo");
	if (catch hud)
	{
		test::@check(false, "the HUD block is in the tree");
		return;
	}
	if (catch gizmo)
	{
		test::@check(false, "the view gizmo is in the tree");
		return;
	}

	fixture.feed(hud);
	test::@check(fixture.ui.cursor == Cursor.CROSSHAIR, "entering over the HUD text keeps the crosshair");

	fixture.feed(gizmo);
	test::@check(fixture.ui.cursor == Cursor.POINTING_HAND, "but the gizmo asks for the hand and wins");

	// And back out onto bare model: the shape follows the pointer, not the last
	// widget that asked.
	fixture.feed(middle);
	test::@check(fixture.ui.cursor == Cursor.CROSSHAIR, "leaving it returns to the crosshair");
}

<*
 Left-button ambiguity: past CLICK_SLOP the press was an orbit, and nothing is
 placed when it comes back up.
*>
fn void drag_orbits_instead_of_placing() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a drag orbits rather than placing");

	// Clear of the dot placed above. A press that lands within PICK_RADIUS of a
	// dot grabs the dot instead — which is the right behaviour and the next
	// check, but it is not an orbit, and this test asserted it was until the
	// first run said otherwise.
	Vec2 empty = VIEWPORT_CENTER + (Vec2) { 0, -200 };

	sz before = fixture.doc().dots.len();
	float yaw = fixture.app.camera.yaw;

	fixture.drag(empty, empty + (Vec2) { DRAG_PIXELS, 0 });

	test::@check(fixture.app.camera.yaw != yaw, "the camera orbited");
	test::@check(fixture.doc().dots.len() == before, "a drag over empty space places no dot");
}

<*
 The other reading of the same gesture: a drag that starts on a dot moves that
 dot and leaves the camera alone. Both are the left button, and which one happens
 is decided by what the press landed on. Only on Joints: on Pose no drag, Alt
 held or not, moves a joint on the model.
*>
fn void drag_on_a_dot_moves_it() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("a drag on a dot moves the dot");

	// Guarded rather than indexed straight in: an earlier failure leaves the
	// document empty, and a test that aborts on the way to reporting hides
	// every check after it. Reintroducing the B4 layout bug did exactly that.
	fixture.ensure_a_dot();
	Dot before = fixture.doc().dots[0];
	Vec2? at   = fixture.pixel_of(before.id);
	if (catch at)
	{
		test::@check(false, "the dot is on screen to grab");
		return;
	}

	float yaw = fixture.app.camera.yaw;

	// On Joints, the header switch's default, a bare drag moves the joint.
	test::@check(fixture.app.stage == crig::EditStage.JOINTS_STAGE, "a fresh model did not open on Joints");
	fixture.drag(at, at + (Vec2) { DRAG_PIXELS, 0 });
	Dot* dragged = fixture.doc().find(before.id);
	test::@check(dragged != null && dragged.position != before.position,
		"a bare drag on Joints left the dot where it was");
	test::@check(fixture.app.undo(), "the move did not undo");

	// On Pose it poses rather than moves: with no clip to pose, the dot stays.
	fixture.app.stage = crig::EditStage.POSE_STAGE;
	fixture.drag(at, at + (Vec2) { DRAG_PIXELS, 0 });
	Dot* held = fixture.doc().find(before.id);
	test::@check(held != null && held.position == before.position,
		"a bare drag on Pose moved the rest dot");

	// Nor with Alt held: Pose never moves a joint on the model.
	fixture.alt_drag(at, at + (Vec2) { DRAG_PIXELS, 0 });

	Dot* kept = fixture.doc().find(before.id);
	test::@check(kept != null && kept.position == before.position, "an Alt-drag on Pose moved the rest dot");
	test::@check(fixture.app.camera.yaw == yaw, "grabbing a dot does not orbit");
}

<*
 A drag across a model built from separate pieces keeps the dot in its own
 piece.

 What the pick does about this is `crig_tests::pick`'s subject. What this pins is
 the wiring: an *Alt-drag* hands the pick the dot's own position and a fresh
 placement does not. Without it the depth is re-chosen from nothing on every mouse move,
 and a dot in the piece behind is pulled to the one in front the instant the
 pointer twitches — which on the seventy-piece robot this was reported against
 is the dot jumping about under the hand.

 Two copies of the fixture cube either side of the origin, along the line the
 camera looks down, so one sits squarely behind the other and one ray meets both.
*>
fn void a_drag_keeps_a_dot_in_its_own_piece() @test
{
	// `framed` fixes the yaw and the pitch, so which way the eye lies is a fact
	// about the camera and not about the mesh — which is what lets the mesh be
	// built around it rather than the other way about.
	crig::OrbitCamera aim = crig::framed({ .min = { -1, -1, -1 }, .max = { 1, 1, 1 } });
	Vec3 toward_eye = (aim.eye() - aim.target).normalize();

	Vec3[16] positions;
	uint[72] indices;
	foreach (usz i, corner : cube().positions)
	{
		positions[i] = corner * 0.25f + toward_eye * 0.6f;
		positions[i + 8] = corner * 0.25f - toward_eye * 0.6f;
	}
	// The cube's own winding for both copies. `snap_inside` reads a face's facing
	// off the winding, so a second table here would be a second chance to be
	// wrong about which way these faces point.
	foreach (usz i, index : cube().indices)
	{
		indices[i] = index;
		indices[i + 36] = index + 8;
	}

	Fixture harness;
	if (catch fault error = harness.open({ .positions = positions[..], .indices = indices[..] }))
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;

	// In the piece behind: the half of the model the ray reaches second.
	Vec3 started = toward_eye * -0.6f;
	uint id = fixture.app.place(started);
	fixture.ui.flush();

	Vec2? at = fixture.pixel_of(id);
	if (catch at)
	{
		test::@check(false, "the dot is on screen to grab");
		return;
	}

	fixture.alt_drag(at, at + (Vec2) { DRAG_PIXELS, 0 });

	Dot* moved = fixture.doc().find(id);
	if (!moved)
	{
		test::@check(false, "the dot survived the drag");
		return;
	}

	test::@check(moved.position != started, "the dot followed the pointer at all");
	test::@check(moved.position.dot(toward_eye) < 0.0f,
		"the dot crossed into the near piece, %.3f along the view axis past the middle",
		moved.position.dot(toward_eye));
}

<*
 Select then delete, both through the widget: the click has to pick the dot
 rather than place a second one, and the key has to arrive at a viewport that
 the same click just focused.
*>
fn void delete_removes_the_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("delete removes the selection");

	fixture.ensure_a_dot();

	// Wherever the orbit above left the camera, this is where that dot is now.
	Dot dot  = fixture.doc().dots[0];
	Vec2? at = fixture.pixel_of(dot.id);
	if (catch at)
	{
		test::@check(false, "the existing dot is on screen");
		return;
	}

	sz before = fixture.doc().dots.len();
	fixture.click(at);
	test::@check(fixture.app.selected == dot.id, "clicking a dot selects it");
	test::@check(fixture.doc().dots.len() == before, "clicking a dot does not place another");

	fixture.tap(at, Key.X);
	test::@check(fixture.doc().dots.len() == before - 1, "X deletes the selected dot");
	test::@check(fixture.app.selected == 0, "the selection is cleared");
	test::@check(fixture.hud_text().contains("0 joints · 0 bones"),
		"the block does not follow the deletion: \"%s\"", fixture.hud_text());
}

<*
 Several dots picked with shift, deleted together, and taken back as one.

 The three claims a group selection has to make: shift adds to it rather than
 replacing it, a plain click ends it, and X takes every member — as *one* entry
 in the history, since a delete that needed one Ctrl+Z per dot would be a
 worse way to say the same thing than deleting them one at a time.

 Shift is also asserted not to drag. It is the same button that moves a dot, and
 a modifier that both selects and grabs would nudge a joint every time one was
 added to the group.
*>
fn void shift_click_builds_a_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("shift-click builds a selection that deletes in one go");
	fixture.reset();

	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	fixture.click(SPOT_C);
	if (fixture.doc().dots.len() != 3)
	{
		test::@check(false, "SKIPPED — the three dots did not land");
		return;
	}

	Dot[3] placed;
	foreach (usz i, dot : fixture.doc().dots.array_view()) placed[i] = dot;

	Vec2? first  = fixture.pixel_of(placed[0].id);
	Vec2? second = fixture.pixel_of(placed[1].id);
	if (catch first) { test::@check(false, "SKIPPED — a dot is off screen"); return; }
	if (catch second) { test::@check(false, "SKIPPED — a dot is off screen"); return; }

	fixture.click(first);
	test::@check(fixture.app.selection_count() == 1, "a plain click selects exactly one dot");

	Vec3 was = placed[1].position;
	fixture.shift_click(second);
	test::@check(fixture.app.selection_count() == 2, "shift-click adds the second without dropping the first");
	test::@check(fixture.app.is_selected(placed[0].id), "the first is still in");
	test::@check(fixture.app.selected == placed[0].id, "and it is still the anchor the modes act through");

	Dot* untouched = fixture.doc().find(placed[1].id);
	test::@check(untouched != null && untouched.position == was, "a shift-click does not drag the dot it adds");

	// Toggling, not just adding — otherwise a mis-shift-click could only be
	// undone by starting the selection over.
	fixture.shift_click(second);
	test::@check(fixture.app.selection_count() == 1, "shift-clicking it again takes it back out");
	fixture.shift_click(second);

	sz before = fixture.doc().dots.len();
	fixture.tap(second, Key.X);
	test::@check(fixture.doc().dots.len() == before - 2, "X deletes every selected dot");
	test::@check(fixture.doc().find(placed[2].id) != null, "and leaves the one that was not selected");
	test::@check(fixture.app.selection_count() == 0, "nothing is selected afterwards");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().dots.len() == before, "one undo brings the whole group back");
	test::@check(fixture.doc().find(placed[0].id) != null && fixture.doc().find(placed[1].id) != null,
		"under the ids they had");

	// A plain click ends a group rather than growing it, which is what keeps
	// "click a dot" meaning the same thing however many were selected before.
	if (try Vec2 again = fixture.pixel_of(placed[2].id))
	{
		fixture.click(first);
		fixture.shift_click(again);
		test::@check(fixture.app.selection_count() == 2, "a group is built again");
		fixture.click(again);
		test::@check(fixture.app.selection_count() == 1, "and a plain click replaces it with one dot");
	}
}

<*
 A key held as the window loses the keyboard is let go. No release follows, so
 Alt would stay down and swap Keep angle on every drag until a restart.
*>
fn void a_key_held_as_the_keyboard_leaves_is_let_go() @test
{
	$if env::LINUX:
		c3w::WaylandWindow window;
		window.event_map.init(mem);
		defer window.event_map.free();
		window.event_map.set(LEFT_ALT, true);
		window.event_map.set(LEFT_SHIFT, true);
		window.event_map.set(LEFT_MOUSE, true);

		c3w::kbLeave(&window, null, 0, null);

		test::@check(!window.event_map.is_pressed(LEFT_ALT), "Alt stayed down after the keyboard left");
		test::@check(!window.event_map.is_pressed(LEFT_SHIFT), "Shift stayed down after the keyboard left");
		test::@check(window.event_map.is_pressed(LEFT_MOUSE), "the mouse button went with the keyboard");
		usz released = 0;
		foreach (event : window.event_log.view()) if (event.type == KEY_RELEASED) released++;
		test::@check(released == 2, "%d key releases logged, not one for each held key", released);
	$endif
}

// X11 says the same with a FocusOut: a held key is let go, a held button is not.
fn void a_key_held_as_x11_focus_goes_is_let_go() @test
{
	$if env::LINUX:
		c3w::X11Window window;
		window.event_map.init(mem);
		defer window.event_map.free();
		window.event_map.set(LEFT_ALT, true);
		window.event_map.set(LEFT_MOUSE, true);

		c3w::KeyPressEvent focus_out = { .type = 10 };
		c3w::x11_handleEvent(&window, &focus_out);

		test::@check(!window.event_map.is_pressed(LEFT_ALT), "Alt stayed down after focus left");
		test::@check(window.event_map.is_pressed(LEFT_MOUSE), "the mouse button went with the focus");
		test::@check(window.event_log.view().len == 1, "%d events logged, not one key release", window.event_log.view().len);
	$endif
}

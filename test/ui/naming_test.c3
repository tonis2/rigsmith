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
// Naming one dot by hand

<*
 The Joint card's Rename button turns its title into a field, and what is typed
 lands on the dot.

 The whole point of the field: a name is the only handle a clip, a body plan or
 a `.glb`'s rig extras has on a joint, and without it there is no way to give
 one to a dot no body plan covers — a tail, a prop, a third arm. It lives on the
 card rather than in a panel of its own because the card already shows the name,
 and because the card is up whenever a dot is selected, in every state — the
 panel's key, R, reached it only outside animation posing.

 One click, one word, one edit: the rename goes through `AppState.rename`, which
 commits, so a single Ctrl+Z takes it back. Asserted here rather than left to
 `rename_recorded`'s own checks, because a card that recorded without committing
 would leave the next unrelated edit sharing an undo step with it.
*>
fn void the_joint_card_names_the_selected_dot() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Joint card names the selected dot");
	fixture.reset();

	// Two dots, because the selection has to have somewhere else to go below.
	// The second is placed first so the card opens on a settled rig.
	fixture.click(SPOT_B);
	uint id = fixture.app.selected;
	fixture.click(SPOT_A);
	uint other = fixture.app.selected;
	test::@check(id != 0 && other != 0 && id != other, "the two clicks did not place two dots");
	if (id == 0 || other == 0 || id == other) return;

	fixture.app.select(id);
	fixture.ui.flush();

	test::@check(fixture.in_tree(crig::JOINT_RENAME_ID), "the card has no Rename button");
	test::@check(!fixture.in_tree(crig::JOINT_NAME_FIELD_ID), "the name field is up before anyone asked");

	// R does not open it: the letter is a transform now, in every state.
	fixture.feed_key(Key.R);
	fixture.ui.flush();
	test::@check(!fixture.in_tree(crig::JOINT_NAME_FIELD_ID) && fixture.app.renaming_dot == 0,
		"R opened the name field");
	test::@check(fixture.app.transform_interaction.active,
		"R did not begin the selected joint's rest transform");
	fixture.feed_key(Key.ESCAPE);

	Vec2? button = fixture.center_of(crig::JOINT_RENAME_ID);
	if (catch button) return;
	fixture.click(button);
	fixture.ui.flush();

	test::@check(fixture.app.renaming_dot == id,
		"the field opened on dot %d rather than on the selected %d", fixture.app.renaming_dot, id);
	test::@check(!fixture.in_tree(crig::JOINT_RENAME_ID), "the Rename button stayed up beside the field");

	Element*? field_elem = fixture.ui.find_id(crig::JOINT_NAME_FIELD_ID);
	if (catch field_elem)
	{
		test::@check(false, "the Rename button raised no field");
		return;
	}

	// A hand-placed dot has no name, so the field comes up empty on the
	// placeholder — there is nothing to correct, only something to supply.
	test::@check(field_elem.widget_as(TextField).value() == "",
		"an unnamed dot's field came up holding something");

	// And the keyboard is already in it. The click that pressed the button left
	// the focus on the card, so a field that did not take it would answer a
	// typed name with nothing at all until the user found it with the mouse.
	test::@check(fixture.ui.focused == field_elem,
		"opening the field left the keyboard somewhere other than in it");

	fixture.type_into(field_elem, "tail_1");
	fixture.feed_key(Key.RETURN);
	fixture.ui.flush();

	test::@check(fixture.app.renaming_dot == 0, "confirming left the card pointed at a dot");
	test::@check(!fixture.in_tree(crig::JOINT_NAME_FIELD_ID) && fixture.in_tree(crig::JOINT_RENAME_ID),
		"confirming did not put the title and its button back");

	Dot* dot = fixture.app.doc.find(id);
	if (!dot)
	{
		test::@check(false, "the dot went away");
		return;
	}
	test::eq(dot.name, "tail_1");
	test::@check(fixture.app.doc.find(other).name == "", "the name landed on the other dot as well");

	// Committed, not merely recorded. `UndoStack.record` chains by default, so an
	// operation that forgets to commit merges into whatever the user does next —
	// and the witness for that is the *next* edit, not this one: a lone
	// uncommitted edit still undoes on its own. Place a dot and take it back, and
	// the name has to survive.
	sz before = fixture.app.doc.dots.len();
	fixture.click(SPOT_C);
	test::@check(fixture.app.doc.dots.len() == before + 1, "the third click placed nothing");

	fixture.app.undo();
	test::@check(fixture.app.doc.dots.len() == before, "one undo did not take the new dot back");
	test::@check(fixture.app.doc.find(id).name == "tail_1",
		"undoing the next edit also took the name — the rename was recorded without being committed");

	fixture.app.undo();
	test::@check(fixture.app.doc.find(id).name == "", "a second undo did not take the name back");
}

<*
 The Joint card carries the two anchor padlocks — Move and Rotate — and L /
 shift+L are their keyboard copies.

 The anchors are what let a figure sit — lock the feet, pull the hips — so they
 live where the joint's other facts are, the way the rename does. No keyframe is
 written: an anchor is session state, a world point and orientation.
*>
fn void the_joint_card_anchors_the_selected_joint() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Joint card anchors the selected joint");
	fixture.reset();

	fixture.click(SPOT_A);
	uint id = fixture.app.selected;
	test::@check(id != 0, "the click placed no dot");
	if (id == 0) return;

	// The anchors live with the pose controls, so a clip has to be open to posing
	// for the card to show them — the state the sit workflow is always in.
	crig::AnimRef clip = fixture.app.new_clip("pose", 1);
	test::@check(clip.valid(), "the clip did not author");
	fixture.app.stop_animation();
	fixture.app.editing = clip;
	fixture.app.edit_time = 0.0f;
	fixture.app.stage = crig::EditStage.POSE_STAGE;

	fixture.app.select(id);
	fixture.feed(fixture.ui.input.mouse);

	test::@check(fixture.in_tree(crig::LOCK_TOGGLES_ID), "the card has no anchor toggles");
	test::@check(!fixture.app.is_anchored(id), "the joint came up anchored");

	Element*? toggles = fixture.ui.find_id(crig::LOCK_TOGGLES_ID);
	if (catch toggles)
	{
		test::@check(false, "the anchor toggles have no place on screen");
		return;
	}
	Vec2 move_pt = toggles.absolute + (Vec2){ toggles.size.x * 0.25f, toggles.size.y * 0.5f };
	Vec2 rotate_pt = toggles.absolute + (Vec2){ toggles.size.x * 0.75f, toggles.size.y * 0.5f };

	// The left padlock holds position, the right holds rotation, independently.
	fixture.click(move_pt);
	fixture.feed(fixture.ui.input.mouse);
	test::@check(fixture.app.locks_position(id) && !fixture.app.locks_rotation(id),
		"the Move padlock did not anchor position alone");

	fixture.click(rotate_pt);
	fixture.feed(fixture.ui.input.mouse);
	test::@check(fixture.app.locks_position(id) && fixture.app.locks_rotation(id),
		"the Rotate padlock did not add rotation");

	// L toggles position from the keyboard; shift+L toggles rotation.
	fixture.feed(SPOT_A, keys: { Key.L });
	fixture.feed(SPOT_A);
	test::@check(!fixture.app.locks_position(id) && fixture.app.locks_rotation(id),
		"L did not release position alone");

	fixture.feed(SPOT_A, keys: { Key.LEFT_SHIFT, Key.L });
	fixture.feed(SPOT_A);
	test::@check(!fixture.app.is_anchored(id), "shift+L did not release rotation");
}

<*
 The Keep angle cell sits under the pins for a limb joint: lit when a drag keeps
 the joint's angle to its parent, and a click sets it the other way. The trunk always
 keeps its world angle, so its card has no cell.
*>
fn void the_joint_card_keep_angle_cell_flips_a_limb() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Joint card's Keep angle cell flips a limb joint");
	fixture.reset();

	PosedLimb limb = build_limb(fixture);
	crig::AnimRef clip = fixture.app.new_clip("pose", 1);
	test::@check(clip.valid(), "the clip did not author");
	fixture.app.stop_animation();
	fixture.app.editing = clip;
	fixture.app.edit_time = 0.0f;
	fixture.app.stage = crig::EditStage.POSE_STAGE;

	fixture.app.select(limb.ankle);
	fixture.feed(fixture.ui.input.mouse);
	test::@check(fixture.in_tree(crig::JOINT_KEEP_ANGLE_ID), "the limb's card has no Keep angle cell");
	test::@check(fixture.app.pose_keeps_angle(limb.ankle), "a joint with no twin came up keeping its world angle");

	fixture.click(fixture.center_of(crig::JOINT_KEEP_ANGLE_ID)!!);
	fixture.feed(fixture.ui.input.mouse);
	test::@check(!fixture.app.pose_keeps_angle(limb.ankle), "the click did not turn Keep angle off");
	fixture.click(fixture.center_of(crig::JOINT_KEEP_ANGLE_ID)!!);
	fixture.feed(fixture.ui.input.mouse);
	test::@check(fixture.app.pose_keeps_angle(limb.ankle), "a second click did not put it back");
	test::@check(fixture.app.angle_flips.len() == 0, "putting it back left %d flips", fixture.app.angle_flips.len());

	fixture.app.select(limb.hips);
	fixture.feed(fixture.ui.input.mouse);
	test::@check(!fixture.in_tree(crig::JOINT_KEEP_ANGLE_ID), "the trunk's card shows a Keep angle cell");
}

<*
 The field is the selected dot's: move the selection and it goes, unwritten.

 The card is rebuilt for whatever is selected, so a field left open through a
 change of selection would come back on the next dot's card holding the last
 dot's half-typed name — and Return there would put it on the wrong joint. The
 rename ends with the card it was opened on instead, and nothing reaches the
 document: the field is not the document until Return says so.
*>
fn void selecting_another_dot_drops_the_name_field() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("selecting another dot drops the name field");
	fixture.reset();

	fixture.click(SPOT_B);
	uint id = fixture.app.selected;
	fixture.click(SPOT_A);
	uint other = fixture.app.selected;
	if (id == 0 || other == 0 || id == other) { test::@check(false, "the two clicks did not place two dots"); return; }

	fixture.app.select(id);
	fixture.ui.flush();
	crig::begin_joint_rename(fixture.ui);
	fixture.ui.flush();

	Element*? field_elem = fixture.ui.find_id(crig::JOINT_NAME_FIELD_ID);
	if (catch field_elem) { test::@check(false, "SKIPPED — the card has no name field"); return; }
	fixture.type_into(field_elem, "tail_1");

	// A frame, not just a flush: the card notices the selection moving in its
	// per-frame update, the way it notices everything else about the dot.
	fixture.app.select(other);
	fixture.feed(fixture.ui.input.mouse);

	test::@check(fixture.app.renaming_dot == 0, "the rename outlived the selection it was opened on");
	test::@check(!fixture.in_tree(crig::JOINT_NAME_FIELD_ID), "the other dot's card came up with the field");
	test::@check(fixture.app.doc.find(id).name == "" && fixture.app.doc.find(other).name == "",
		"the half-typed name landed on a dot");

	// Return now reaches the shortcuts, not a field: nothing to submit.
	fixture.feed_key(Key.RETURN);
	fixture.ui.flush();
	test::@check(fixture.app.doc.find(id).name == "" && fixture.app.doc.find(other).name == "",
		"Return after the field was gone still renamed something");
}

<*
 Typing in the name field does not reach the application's shortcuts.

 `typing_a_path_does_not_reach_the_shortcuts` makes this claim for the chooser,
 and it has to hold here for a harder reason: that panel is modal and this card
 is not, so the rig it is renaming is live behind it. A field that let its
 characters through would delete the dot being named the moment somebody typed
 an `x`.
*>
fn void the_name_field_does_not_reach_the_shortcuts() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the name field does not reach the shortcuts");
	fixture.reset();

	fixture.ensure_a_dot();
	uint id = fixture.app.selected;
	if (id == 0) { test::@check(false, "placing a dot did not select it"); return; }

	crig::begin_joint_rename(fixture.ui);
	fixture.ui.flush();

	Element*? field_elem = fixture.ui.find_id(crig::JOINT_NAME_FIELD_ID);
	if (catch field_elem)
	{
		test::@check(false, "SKIPPED — the card has no name field");
		return;
	}

	bool mesh_before = fixture.app.show_mesh;
	bool rig_before = fixture.app.show_rig;
	sz dots_before = fixture.app.doc.dots.len();

	// B and S hide the halves of the view; X deletes the dot being renamed, which
	// is the one that would be unrecoverable from inside the field.
	fixture.type_into(field_elem, "b", keys: { Key.B });
	fixture.type_into(field_elem, "s", keys: { Key.S });
	fixture.type_into(field_elem, "x", keys: { Key.X });

	test::@check(field_elem.widget_as(TextField).value() == "bsx", "what was typed lands in the field");
	test::@check(fixture.app.show_mesh == mesh_before, "and B does not hide the mesh");
	test::@check(fixture.app.show_rig == rig_before, "and S does not hide the rig");
	test::@check(fixture.app.doc.dots.len() == dots_before, "and X does not delete the dot being renamed");

	// ESC closes the field and writes nothing: the field is not the document
	// until Return says so, the same bargain a cancelled drag strikes. And it
	// closes the *field*: the card lets Escape through to nothing further, so
	// the selection — and with it the card — stays. Left to bubble, the root's
	// reading of a bare Escape would have cleared the selection and taken the
	// whole card away with the field.
	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();

	test::@check(fixture.app.renaming_dot == 0 && !fixture.in_tree(crig::JOINT_NAME_FIELD_ID),
		"escape did not close the field");
	test::@check(fixture.app.selected == id, "escape cleared the selection along with the field");
	test::@check(fixture.in_tree(crig::JOINT_RENAME_ID), "escape did not put the title and its button back");
	test::@check(fixture.app.doc.find(id).name == "", "escape wrote the half-typed name onto the dot");
	test::@check(!fixture.app.undo_stack.can_undo() || fixture.app.doc.find(id).name == "",
		"escape recorded an edit");
}

<*
 With nothing selected there is nothing to rename, and both doors say so.

 The menu item and its handler have to agree: an item that greys while the
 handler still opens something is a refusal nobody can discover. There is no
 card without a selection, so there is nowhere for the field to be either.
*>
fn void renaming_needs_a_selection() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("renaming needs a selection");
	fixture.reset();

	fixture.ensure_a_dot();
	fixture.app.select(0);
	fixture.feed(fixture.ui.input.mouse);

	test::@check(crig::query_selection(fixture.ui).disabled, "the menu item is not greyed with nothing selected");
	test::@check(!fixture.in_tree(crig::JOINT_RENAME_ID), "a Rename button is up with nothing selected");

	crig::menu_rename_dot(fixture.ui);
	fixture.ui.flush();

	test::@check(fixture.app.renaming_dot == 0, "the handler took a rename with nothing selected");
	test::@check(!fixture.in_tree(crig::JOINT_NAME_FIELD_ID), "a name field opened with nothing selected");
	test::@check(fixture.notice_text().contains("select a joint"),
		"the refusal did not say what to do (%s)", fixture.notice_text());
}

<*
 A dot that already has a name comes up with it, selected.

 The commonest rename replaces the name outright rather than tweaking it — a
 plan named a limb the wrong side round, or a joint arrived from a file as
 `joint_7` — so the field is filled *and* its contents are selected, and typing
 the new name is the whole gesture. Filled with the caret at the end would make
 every one of those start with a held backspace.
*>
fn void an_already_named_dot_comes_up_selected() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("an already named dot comes up selected");
	fixture.reset();

	fixture.ensure_a_dot();
	uint id = fixture.app.selected;
	if (id == 0) { test::@check(false, "placing a dot did not select it"); return; }

	fixture.app.rename(id, "thigh_R");
	fixture.ui.flush();

	crig::begin_joint_rename(fixture.ui);
	fixture.ui.flush();

	Element*? field_elem = fixture.ui.find_id(crig::JOINT_NAME_FIELD_ID);
	if (catch field_elem)
	{
		test::@check(false, "SKIPPED — the card has no name field");
		return;
	}
	TextField* field = field_elem.widget_as(TextField);

	test::eq(field.value(), "thigh_R");

	usz low = min(field.caret, field.anchor);
	usz high = max(field.caret, field.anchor);
	test::@check(low == 0 && high == "thigh_R".len,
		"the name came up unselected — %d..%d of %d", low, high, "thigh_R".len);

	// Typing over it is one word, not a word after nine backspaces.
	fixture.type_into(field_elem, "thigh_L");
	fixture.feed_key(Key.RETURN);
	fixture.ui.flush();

	test::eq(fixture.app.doc.find(id).name, "thigh_L");
}

<*
 R is the turn, and ctrl+R is the root — and the rest rig knows both readings.

 R used to mean two things, and the animation context decided which: the posing
 block in `AppRoot.on_key` claims R for `begin_turn` and returns before the
 plain-letter switch is consulted, and a rename panel took the letter in the
 switch below. The panel is gone — the Joint card names the dot now — so the
 switch has no R at all, and on the rest rig, where nothing is pose-ready, the
 key does nothing: no field, no panel, no root moved.

 On the rest rig plain R now starts the shared rest transform. Set root, which
 gave R up first, remains on ctrl+R and must still work after that transform is
 cancelled.
*>
fn void r_turns_an_animation_and_ctrl_r_roots_the_rest_rig() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("R turns a paused animation and ctrl+R roots the rest rig");
	fixture.reset();

	// The forked limb the pose checks use, because the pose half of this needs a
	// joint R can genuinely turn — a dot with nothing above it refuses, and a
	// refusal proves nothing about which block claimed the key.
	PosedLimb limb = build_limb(fixture);

	// --- on the rest rig: R transforms, ctrl+R roots -----------------------

	fixture.app.select(limb.thigh);
	fixture.ui.flush();
	test::@check(fixture.doc().root_id == limb.hips, "the limb did not come rooted at the hips");

	fixture.feed_key(Key.R);
	fixture.ui.flush();
	test::@check(fixture.app.renaming_dot == 0 && !fixture.in_tree(crig::JOINT_NAME_FIELD_ID),
		"R opened the name field on the rest rig");
	test::@check(fixture.doc().root_id == limb.hips, "R moved the root");
	test::@check(fixture.app.drag.dot == 0 && fixture.app.transform_interaction.active,
		"R did not begin the rest-joint transform");
	test::@check(fixture.app.selected == limb.thigh, "R changed the selection");
	fixture.feed_key(Key.ESCAPE);

	fixture.chord(fixture.ui.input.mouse, Key.LEFT_CTRL, Key.R);
	test::@check(fixture.doc().root_id == limb.thigh, "ctrl+R did not hand the root to the selection");
	test::@check(fixture.app.renaming_dot == 0, "ctrl+R opened the name field");

	// Back, so the pose half starts from the shape build_limb described.
	fixture.app.select(limb.hips);
	fixture.chord(fixture.ui.input.mouse, Key.LEFT_CTRL, Key.R);
	test::@check(fixture.doc().root_id == limb.hips, "the root did not go back to the hips");

	// --- on a paused animation: R turns, and ctrl+R is refused -------------

	AnimRef clip = fixture.app.new_clip("R context", 1.0f, from_rest: true);
	fixture.app.editing = clip;
	test::@check(fixture.app.park_clip(clip, 0.0f), "the R context clip would not park");
	fixture.app.select(limb.thigh);

	Vec2? pivot_px = fixture.pixel_of(limb.thigh);
	if (catch pivot_px)
	{
		test::@check(false, "SKIPPED — the thigh did not project");
		return;
	}

	fixture.tap(pivot_px, Key.R);
	fixture.ui.flush();

	test::@check(fixture.app.renaming_dot == 0, "R opened the name field while editing an animation");
	test::@check(fixture.app.drag.dot == limb.thigh && fixture.app.drag.verb == DragVerb.TURN,
		"R on the paused animation did not begin turning the thigh (%s)",
		fixture.notice_text());

	// Escape cancels the turn, not the selection, so the thigh is still what
	// ctrl+R would act on if it were allowed to.
	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();
	test::@check(fixture.app.drag.dot == 0, "escape did not cancel the turn");
	test::@check(fixture.app.selected == limb.thigh, "cancelling the turn also dropped the selection");

	// Re-rooting mid-pose would reinterpret every parent-relative rotation in the
	// pose, so the item greys and the key refuses.
	test::@check(crig::query_set_root(fixture.ui).disabled, "Set root is not greyed while editing an animation");

	fixture.chord(fixture.ui.input.mouse, Key.LEFT_CTRL, Key.R);
	test::@check(fixture.doc().root_id == limb.hips, "ctrl+R moved the root while editing an animation");

	fixture.app.discard_pose_edit();
	fixture.app.stop_animation();
	fixture.ui.flush();
}

<*
 The weight brush opens on shift+W, borrows the falloff view, and hands it back.

 The Area tool's sibling, asserted the same way — and the shift is the point: the
 two share a letter because they are the two ways to change a bind without
 moving a joint, so a plain W must still be the Area tool and never the brush.
*>
fn void the_weight_brush_opens_beside_the_area_tool() @test
{
	io::printn("shift+W opens the weight brush and W still opens the Area tool");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "shift+W did not open the brush");
	test::@check(!fixture.app.areaing, "shift+W opened the Area tool as well");
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"the brush left the mesh on %s rather than painting what the dot holds",
		fixture.app.tint_mode);

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(!fixture.app.brushing, "shift+W did not close the brush");
	test::@check(fixture.app.tint_mode == TintMode.OFF,
		"closing it left the mesh painted with %s", fixture.app.tint_mode);

	// The plain key still means the other mode, which is the whole risk of
	// hanging a second thing off one letter.
	fixture.feed_key(Key.W);
	test::@check(fixture.app.areaing && !fixture.app.brushing,
		"a plain W opened the brush instead of the Area tool");
	fixture.feed_key(Key.ESCAPE);

	// Escape closes the brush without cancelling anything: strokes went on the
	// ledger as they were made, so there is no half-finished state to put back.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not reopen");
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.brushing && fixture.app.areaing && fixture.app.tint_mode == TintMode.FALLOFF,
		"escape did not close the brush and hand the Weights card its part back");
}

<*
 shift+W opens the brush over a parked clip, and the Rig menu offers it there.

 The animation workspace is the one place a fold can be seen, so it is where
 the brush is wanted — and it used to answer "finish animation editing first"
 there, and grey its menu item. Now the only thing it asks for is a dot.
*>
fn void the_weight_brush_opens_over_a_parked_clip() @test
{
	io::printn("shift+W opens the weight brush while a clip is parked");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	AnimRef clip = fixture.app.new_clip("Bind", 1.0f, from_rest: true);
	test::@check(clip.valid() && fixture.app.park_clip(clip, 0.0f), "the fixture could not park a clip");
	test::@check(fixture.app.rig_locked(), "a parked clip did not lock the rest rig");
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	test::@check(!crig::query_brushing(fixture.ui).disabled,
		"the Rig menu greys the brush while a clip is parked");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "shift+W did not open the brush over the parked clip: \"%s\"",
		fixture.app.notice());
	test::@check(fixture.app.animating && fixture.app.anim_paused,
		"opening the brush took the clip down");
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"the brush left the mesh on %s rather than painting what the dot holds", fixture.app.tint_mode);

	// Without a dot it still refuses, and says so in the one remaining way.
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	fixture.app.select(0);
	fixture.app.refresh_ui();
	test::@check(crig::query_brushing(fixture.ui).disabled, "the Rig menu offers the brush with nothing selected");
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(!fixture.app.brushing && fixture.app.notice().contains("select a joint"),
		"with nothing selected the brush said \"%s\"", fixture.app.notice());
}

<*
 A stroke over a parked clip lands, reskins the body as it goes, and settles the
 posed surface on release.

 The viewport's half of what `weights_test` asserts on the state: the press
 opens the stroke, each move paints and rebinds the skin under the palette
 without rebuilding the accelerator, and the release is where that rebuild is
 paid — with the clip still parked at the end of it.
*>
fn void a_brush_stroke_over_a_parked_clip_reskins_as_it_goes() @test
{
	io::printn("a brush stroke over a parked clip reskins the body and settles on release");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);

	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	// The corner's pixel, read before the clip goes up — a clip keyed from rest
	// leaves every vertex where it was, so the pixel holds.
	uint probe = fixture.doc().add_dot({ -1, 1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? corner = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	if (catch corner)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}

	AnimRef clip = fixture.app.new_clip("Bind", 1.0f, from_rest: true);
	test::@check(clip.valid() && fixture.app.park_clip(clip, 0.0f), "the fixture could not park a clip");
	fixture.app.select(chest);
	fixture.app.refresh_ui();
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open over the parked clip");
	test::@check(fixture.app.posed_surface_shown(), "the parked clip put no posed surface up");

	uint skin_was = fixture.app.skin_generation;
	Vec2 from = corner;
	Vec2 to = { corner.x + 4, corner.y };

	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	fixture.feed(from, keys: taking[..]);
	fixture.feed(from, left: true, keys: taking[..]);
	test::@check(fixture.app.stroke_open, "the press did not open a stroke");
	test::@check(fixture.app.doc.pins.len() > 0, "the press painted nothing");
	test::@check(fixture.app.skin_generation > skin_was, "the press did not reskin the parked body");
	test::@check(fixture.app.surface_stale && fixture.app.deformed_surface.root != null,
		"the press rebuilt the posed surface instead of leaving it standing for the stroke");

	fixture.feed(to, left: true, keys: taking[..]);
	test::@check(fixture.app.stroke_open && fixture.app.surface_stale, "the move settled what the release should");

	fixture.feed(to, keys: taking[..]);
	test::@check(!fixture.app.stroke_open && !fixture.app.surface_stale,
		"the release did not rebuild the posed surface");
	test::@check(fixture.app.animating && fixture.app.anim_paused && fixture.app.posed_surface_shown(),
		"the stroke took the clip down");
	test::@check(!raised(&fixture, chest), "a taking stroke gave the chest a whole vertex");
}

<*
 A stroke paints the mesh under the circle, and one press-to-release is one step.

 The gather is the half that can be wrong without anything looking odd — a radius
 read in the wrong units, or an occlusion test that lets the far side through,
 both paint something and neither is visible in a screenshot. So this asserts the
 count moved, that it is bounded by the circle rather than the whole mesh, and
 that the ledger got exactly one entry for the gesture.

 It also holds the brush to its modifier: a stroke is a ctrl-drag, and the
 plain drag stays the orbit so the model can be turned to paint the rest of it.
*>
fn void a_brush_stroke_paints_under_the_circle() @test
{
	io::printn("a brush stroke paints what is under it, as one undo step");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	// The cursor, not the length: `undo` moves the cursor and leaves the edits in
	// place for redo, so a loop watching the length would never end.
	sz before = fixture.app.undo_stack.cursor;

	// Aimed at a corner, so the circle covers one vertex and not the whole face:
	// the fixture cube is eight of them and nothing in between, and a circle in
	// the middle of a face paints all of that face's corners.
	//
	// Found by projecting a dot placed there and taking it away again — the dot
	// and the vertex share a position, so they share a pixel.
	// Head-on, so which corners are in sight is knowable: the front face is
	// z = +1. A three-quarter view hides some corners and nothing in the test
	// could say which.
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	uint probe = fixture.doc().add_dot({ -1, -1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? corner = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	if (catch corner)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2 from = corner;
	Vec2 to = { corner.x + 4, corner.y };

	// A plain drag on the mesh paints the way the options strip says (Add), and
	// does not turn the model.
	float yaw = fixture.app.camera.yaw;
	fixture.feed(from);
	fixture.feed(from, left: true);
	fixture.feed(to, left: true);
	fixture.feed(to);
	test::@check(fixture.app.doc.pins.len() > 0, "a plain drag on the mesh did not paint with the brush open");
	test::@check(fixture.app.camera.yaw == yaw, "a plain drag on the mesh orbited as well as painting");
	test::@check(fixture.app.undo(), "the plain stroke did not undo");
	test::@check(fixture.app.doc.pins.len() == 0, "one undo left part of the plain stroke behind");

	// Off the mesh the plain drag is still the camera's, so the model can be
	// turned to reach the next part of it.
	Vec2 off = { corner.x - 120, corner.y };
	fixture.feed(off);
	fixture.feed(off, left: true);
	fixture.feed(off + (Vec2){ 30, 0 }, left: true);
	fixture.feed(off + (Vec2){ 30, 0 });
	test::@check(fixture.app.doc.pins.len() == 0, "a plain drag off the mesh painted");
	test::@check(fixture.app.camera.yaw != yaw, "a plain drag off the mesh did not orbit with the brush open");
	fixture.app.camera.yaw = yaw;
	fixture.app.refresh_ui();
	before = fixture.app.undo_stack.cursor;

	// Press, move, release — the shape of every stroke — with ctrl and shift
	// held, which is the direction that takes the dot off.
	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	fixture.feed(from, keys: taking[..]);
	fixture.feed(from, left: true, keys: taking[..]);
	fixture.feed(to, left: true, keys: taking[..]);
	fixture.feed(to, keys: taking[..]);

	sz painted = (sz)pinned_vertices(&fixture);
	test::@check(painted > 0, "the stroke painted nothing at all");
	test::@check(painted < (sz)fixture.app.geometry.positions.len,
		"the stroke painted the whole mesh (%d of %d) — the circle is not bounding it",
		painted, fixture.app.geometry.positions.len);
	test::@check(fixture.app.camera.yaw == yaw, "a ctrl+shift-drag orbited as well as painting");

	// Every row takes weight off the selected joint rather than adding it: shift
	// beside ctrl is the destructive direction.
	test::@check(!raised(&fixture, chest), "a ctrl+shift-drag added weight instead of taking it off");

	// The press and the move are two steps of one gesture: one undo takes both.
	test::@check(fixture.app.undo_stack.cursor > before, "the stroke left nothing on the ledger");
	test::@check(fixture.app.undo(), "the stroke did not undo");
	test::@check(fixture.app.doc.pins.len() == 0, "one undo left part of the stroke behind");
}

<*
 A stroke begun on another joint's dot paints the joint being painted: with the
 brush open a left press looks through the dots, and a right-click does too.
*>
fn void a_brush_stroke_on_a_joint_paints_instead_of_picking_it() @test
{
	io::printn("a brush stroke begun on a joint's dot paints rather than selecting that joint");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	// On a cube corner, the fixture mesh's only vertices, so the dot sits on what
	// the stroke paints.
	uint corner_dot = fixture.doc().add_dot({ -1, -1, 1 }, "corner");
	fixture.doc().connect(hips, corner_dot);
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");
	Vec2? corner = fixture.pixel_of(corner_dot);
	if (catch corner)
	{
		test::@check(false, "the corner dot does not project into the viewport");
		return;
	}

	fixture.drag(corner, corner + (Vec2){ 4, 0 });
	test::@check(fixture.app.selected == chest, "the press on a dot picked it instead of painting");
	test::@check(fixture.app.brushing, "the press on a dot closed the brush");
	bool chest_painted;
	foreach (pin : fixture.app.doc.pins.array_view()) chest_painted |= pin.dot_id == chest;
	test::@check(chest_painted, "the stroke begun on a dot did not paint the selected joint");

	fixture.right_click(corner);
	test::@check(fixture.app.selected == chest, "a right-click on a dot picked it with the brush open");
	test::@check(fixture.app.brushing, "a right-click on a dot closed the brush");
}

<*
 With the brush open the rig is left alone. A click on the face of a low-poly
 part, with no vertex under the circle, paints the face's corners and places no
 joint and chains none, and the keys that edit joints are refused out loud. Esc
 gives them back.

 Re-introduce: drop the face pass from `AppState.brush_vertices`.
*>
fn void the_brush_never_places_or_edits_joints() @test
{
	io::printn("the weight brush never places, connects, moves or deletes joints");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.doc.auto_connect = true;
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");
	test::@check(fixture.app.set_brush_radius(crig::BRUSH_RADIUS_MIN), "the brush did not shrink");
	sz dots = fixture.doc().dots.len();
	sz edges = fixture.doc().edges.len();
	bool anchored = fixture.app.locks_position(chest);

	// A spot on the cube's front face, clear of the bone and of the corners — the
	// face's only vertices. Found by projecting a dot put there and taken away.
	uint probe = fixture.doc().add_dot({ -0.6f, -0.5f, 1.0f }, "probe");
	fixture.app.refresh_ui();
	Vec2? spot = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();
	if (catch spot)
	{
		test::@check(false, "the face does not project into the viewport");
		return;
	}
	Vec2 face = spot;
	fixture.click(face);
	test::eq(fixture.doc().dots.len(), dots);
	test::eq(fixture.doc().edges.len(), edges);
	// The front face's corners are vertices 4 to 7; the far side stays out of it.
	test::@check(pinned_vertices(&fixture) > 0, "a click on the face painted none of its corners");
	{
		bool[] edited = edited_mask(&fixture);
		defer alloc::free(mem, edited);
		foreach (v, on : edited) test::@check(!on || v >= 4, "the click on the front face painted vertex %d on the far side", v);
	}
	test::@check(fixture.app.selected == chest && fixture.app.brushing, "the click changed the joint or closed the brush");
	test::@check(fixture.app.undo(), "the click's stroke did not undo");

	Key[1] shifted = { Key.LEFT_SHIFT };
	fixture.feed(face, keys: shifted[..]);
	fixture.feed(face, left: true, keys: shifted[..]);
	fixture.feed(face, keys: shifted[..]);
	test::eq(fixture.doc().dots.len(), dots);

	fixture.feed(face);
	foreach (key : (Key[6]){ Key.X, Key.C, Key.M, Key.L, Key.G, Key.R })
	{
		fixture.feed_key(key);
		test::@check(fixture.doc().dots.len() == dots && fixture.doc().edges.len() == edges,
			"%s edited the rig with the brush open", key);
		test::@check(fixture.app.selected == chest && fixture.app.brushing, "%s changed the joint or closed the brush", key);
		test::@check(!fixture.app.transform_interaction.active && fixture.app.drag.dot == 0, "%s started moving a joint", key);
		test::@check(fixture.app.notice().contains("stop the brush"), "%s said \"%s\"", key, fixture.app.notice());
	}
	test::@check(fixture.app.locks_position(chest) == anchored, "L anchored the joint with the brush open");
	fixture.chord(face, Key.LEFT_SHIFT, Key.M);
	test::@check(fixture.app.notice().contains("stop the brush"), "shift+M said \"%s\"", fixture.app.notice());
	fixture.chord(face, Key.LEFT_CTRL, Key.A);
	test::@check(fixture.app.selection_count() == 1 && fixture.app.selected == chest, "ctrl+A selected the joints with the brush open");

	// Esc closes the brush, and the same click places a joint again.
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.brushing, "esc did not close the brush");
	fixture.click(face);
	test::@check(fixture.doc().dots.len() == dots + 1, "a click with the brush closed placed no joint (%s)", fixture.app.notice());
}

<*
 The brush does not paint through the model, with X-ray off.

 **Front faces only by default**: a brush that reached
 the far side would correct an arm and silently correct the ribs behind it —
 manufacturing exactly the bleed crig exists to remove, with nothing on screen to
 say it happened.

 Asserted head-on, because that is the one view where it can be: from the front
 each of the cube's back corners sits directly behind a front one, so a circle
 wide enough to cover the silhouette covers all eight vertices and only four of
 them are in sight. A three-quarter view cannot show this — the corners project
 to eight different pixels and a broken occlusion test looks identical to a
 working one.
*>
fn void the_brush_does_not_paint_through_the_model() @test
{
	io::printn("the weight brush paints only the side of the model facing the user");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);

	// Head-on, set rather than snapped: `snap_to` eases over several frames and
	// this test has no clock to run them on.
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	// Wide enough to cover the whole silhouette, so every vertex is inside the
	// circle and the only thing keeping any of them out is the visibility test.
	// Set past the wheel's own ceiling on purpose: this is not a gesture, it is a
	// way of putting every vertex in range at once.
	fixture.app.brush_radius = 4000.0f;
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	fixture.feed(VIEWPORT_CENTER, keys: taking[..]);
	fixture.feed(VIEWPORT_CENTER, left: true, keys: taking[..]);
	fixture.feed(VIEWPORT_CENTER, keys: taking[..]);

	usz painted = pinned_vertices(&fixture);
	test::@check(painted > 0, "the stroke painted nothing — the circle did not cover the model");
	test::@check(painted < 8, "the stroke painted all eight corners, so it reached through the cube");

	// The front face is z = +1, which is vertices 4 through 7 in `cube_positions`.
	// Anything below that index is a corner on the far side.
	{
		bool[] edited = edited_mask(&fixture);
		defer alloc::free(mem, edited);
		foreach (v, on : edited) test::@check(!on || v >= 4, "vertex %d is on the far side of the cube and was painted anyway", v);
	}
}

// The head-on cube of `the_brush_does_not_paint_through_the_model`, with the brush
// open over the whole silhouette.
fn bool open_brush_head_on(Fixture* fixture)
{
	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.brush_radius = 4000.0f;
	fixture.app.refresh_ui();
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	return fixture.app.brushing;
}

// One press-and-release at the viewport centre with `keys` held.
fn void stroke_with(Fixture* fixture, Key[] keys)
{
	fixture.feed(VIEWPORT_CENTER, keys: keys);
	fixture.feed(VIEWPORT_CENTER, left: true, keys: keys);
	fixture.feed(VIEWPORT_CENTER, keys: keys);
}

<*
 The strip's X-ray box paints every vertex under the circle, the cube's back
 corners included, and alt held at the press turns it back to front only for
 that stroke.

 Re-introduce: drop `self.brush_xray` from `Viewport.paint_at`'s call, or latch
 it without `alt_down`.
*>
fn void the_xray_box_paints_through_the_model() @test
{
	io::printn("the weight brush's X-ray box paints the far side too, and alt undoes it for a stroke");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	test::@check(open_brush_head_on(&fixture), "the brush did not open");
	fixture.feed(VIEWPORT_CENTER);

	test::@check(!fixture.app.config.brush_xray, "X-ray starts ticked");
	fixture.click(fixture.center_of(crig::BRUSH_XRAY_ID)!!);
	test::@check(fixture.app.config.brush_xray, "clicking X-ray did not tick it");

	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	// The chest holds the top four corners and nothing of the bottom four — its
	// weight ends a band past the hips' — so a stroke through the model takes it
	// off all four, the far two included.
	stroke_with(&fixture, taking[..]);
	test::eq(pinned_vertices(&fixture), (usz)4);
	test::@check(far_side_pinned(&fixture) == 2, "the X-ray stroke did not reach the far side");

	test::@check(fixture.app.undo(), "the stroke did not undo");
	test::eq(pinned_vertices(&fixture), (usz)0);

	Key[3] front_only = { Key.LEFT_ALT, Key.LEFT_CTRL, Key.LEFT_SHIFT };
	stroke_with(&fixture, front_only[..]);
	usz painted = pinned_vertices(&fixture);
	test::@check(painted > 0 && painted < 4, "alt with X-ray ticked painted %d corners, not the front ones", painted);
	{
		bool[] edited = edited_mask(&fixture);
		defer alloc::free(mem, edited);
		foreach (v, on : edited) test::@check(!on || v >= 4, "vertex %d is on the far side of the cube and was painted anyway", v);
	}
}

<*
 With the box off, alt held at the press paints through for that one stroke.

 Re-introduce: latch `brush_xray` from the box alone.
*>
fn void alt_paints_through_with_the_box_off() @test
{
	io::printn("alt held at the press paints through the model for one stroke");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	test::@check(open_brush_head_on(&fixture), "the brush did not open");

	Key[3] through = { Key.LEFT_ALT, Key.LEFT_CTRL, Key.LEFT_SHIFT };
	stroke_with(&fixture, through[..]);
	test::eq(pinned_vertices(&fixture), (usz)4);
	test::@check(far_side_pinned(&fixture) == 2, "alt did not reach the far side");

	// The next stroke without alt is front only again.
	test::@check(fixture.app.undo(), "the stroke did not undo");
	Key[2] taking = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	stroke_with(&fixture, taking[..]);
	usz painted = pinned_vertices(&fixture);
	test::@check(painted > 0 && far_side_pinned(&fixture) == 0, "the stroke after alt painted %d corners, %d of them behind",
		painted, far_side_pinned(&fixture));
}

<*
 A plain drag in Remove mode, started in the middle of a big face with no vertex
 under the circle, takes the joint off that face's corners — the front ones only
 — and does not turn the model. The fixture cube is the coarse mesh: eight
 corners and nothing between them.

 Re-introduce: drop the face pass from `AppState.brush_vertices`; the press then
 finds nothing and the drag orbits.
*>
fn void a_brush_stroke_in_the_middle_of_a_face_paints_it() @test
{
	io::printn("a remove stroke in the middle of a big face takes the joint off its corners");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	test::@check(open_brush_head_on(&fixture), "the brush did not open");
	fixture.app.brush_radius = crig::BRUSH_RADIUS_DEFAULT;
	fixture.app.brush_removes = true;
	uint chest = fixture.app.selected;

	float yaw = fixture.app.camera.yaw;
	Vec2 to = VIEWPORT_CENTER + (Vec2){ 6, 0 };
	fixture.feed(VIEWPORT_CENTER);
	fixture.feed(VIEWPORT_CENTER, left: true);
	fixture.feed(to, left: true);
	fixture.feed(to);
	test::@check(fixture.app.camera.yaw == yaw, "the drag in the middle of the face turned the model");
	test::@check(pinned_vertices(&fixture) > 0, "the stroke in the middle of the face painted none of its corners");
	{
		bool[] edited = edited_mask(&fixture);
		defer alloc::free(mem, edited);
		foreach (v, on : edited) test::@check(!on || v >= 4, "vertex %d is on the far side of the cube and was painted anyway", v);
	}
	test::@check(!raised(&fixture, chest), "the remove stroke put the joint on");
}

<*
 The brush sizes itself only while F is held; the rest of the time the camera has
 the wheel back.

 A brush has to be *aimed*, and aiming means turning the model to reach the next
 part of it — so a tool that ate the orbit for as long as it was open would be
 usable from one angle only. Blender settles this by making the size a held-key
 gesture rather than a standing claim, and this is that: with F down the swipe
 sizes the circle, with F up it turns the model, and neither ever does both.

 The last check is the one that would have caught the old behaviour: it is not
 enough that F works, the wheel has to have gone *back*.
*>
fn void the_brush_sizes_only_while_its_key_is_held() @test
{
	io::printn("the weight brush sizes on held F and leaves the camera the wheel otherwise");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	float radius = fixture.app.brush_radius;
	float yaw = fixture.app.camera.yaw;
	float pitch = fixture.app.camera.pitch;

	// --- F held: the swipe is the brush's -----------------------------------

	Key[1] sizing = { Key.F };
	fixture.scroll(VIEWPORT_CENTER, { 0, 6 }, true, sizing[..]);

	test::@check(fixture.app.brush_radius != radius,
		"a swipe with F held did not size the brush");
	test::@check(fixture.app.camera.yaw == yaw && fixture.app.camera.pitch == pitch,
		"sizing the brush turned the model at the same time");

	// --- F up: the swipe is the camera's again ------------------------------

	float sized = fixture.app.brush_radius;
	fixture.scroll(VIEWPORT_CENTER, { 9, 5 }, true);

	test::@check(fixture.app.camera.yaw != yaw || fixture.app.camera.pitch != pitch,
		"the brush kept the orbit even with its key up — the model cannot be turned to paint the rest of it");
	test::@check(fixture.app.brush_radius == sized,
		"turning the model resized the brush");

	// F must not toggle the falloff view out from under the brush, since it is
	// the size key while the mode is open.
	fixture.feed_key(Key.F);
	test::@check(fixture.app.tint_mode == TintMode.FALLOFF,
		"pressing F while brushing turned off the view the brush paints against");
}

// One dot's own weight on one vertex: what the brush moves.
fn float brush_weight_of(Fixture* f, uint vertex, uint dot)
{
	crig::RigView? opened = f.app.open_rig(mem);
	if (catch opened) return -1.0f;
	crig::RigView view = opened;
	defer view.free(mem);

	float[] column = f.app.column_of(mem, &view, dot);
	defer if (column.len > 0) alloc::free(mem, column);
	return (usz)vertex < column.len ? column[vertex] : -1.0f;
}

<*
 The strength sets how far one tap goes, all the way through the gesture: part
 of the way when it is low, the whole way at full.

 The arithmetic is asserted headlessly in `crig_tests::weights`; what this covers
 is the half that test cannot reach — that the strength is actually applied where
 the circle's falloff is computed, rather than only where a unit test hands the
 number in itself. Dropping `brush_strength` from `brush_vertices` leaves that
 one passing and this one failing, which is the whole reason it is here.
*>
fn void the_strength_slider_sets_how_far_one_tap_goes() @test
{
	io::printn("one tap of the weight brush carries a vertex as far as its strength says");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	uint hips = fixture.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = fixture.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	fixture.doc().connect(hips, chest);
	fixture.app.select(chest);

	// Head-on, so the front face is z = +1 and a corner there is in sight.
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;
	fixture.app.refresh_ui();

	uint probe = fixture.doc().add_dot({ -1, -1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? corner = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();

	if (catch corner)
	{
		test::@check(false, "the cube's front corner does not project into the viewport");
		return;
	}

	// Take it to nothing first, so the tap below has the whole range to cross and
	// "did one tap finish it" is a question with a visible answer.
	uint[1] target = { 4 };
	fixture.app.paint_share(chest, target[..], 0.0f);
	test::@check(brush_weight_of(&fixture, 4, chest) < 0.01f, "the corner did not start at nothing");

	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.W);
	test::@check(fixture.app.brushing, "the brush did not open");

	defer fixture.app.set_brush_strength(crig::BRUSH_STRENGTH_DEFAULT);

	// One tap, dead centre, ctrl held so it adds rather than takes away.
	Key[1] adding = { Key.LEFT_CTRL };
	fixture.app.set_brush_strength(0.25f);
	fixture.feed(corner, keys: adding[..]);
	fixture.feed(corner, left: true, keys: adding[..]);
	fixture.feed(corner, keys: adding[..]);

	float after = brush_weight_of(&fixture, 4, chest);
	test::@check(after > 0.05f, "one gentle tap moved the corner not at all, measured %s", after);
	test::@check(after < 0.6f,
		"one tap at a quarter strength took the corner most of the way to full (%s)", after);

	// Back to nothing — the tap is one undo step — and the same tap at full
	// strength finishes it.
	test::@check(fixture.app.undo(), "the tap did not undo");
	test::@check(brush_weight_of(&fixture, 4, chest) < 0.01f, "the corner did not go back to nothing");
	fixture.app.set_brush_strength(crig::BRUSH_STRENGTH_MAX);
	fixture.feed(corner, keys: adding[..]);
	fixture.feed(corner, left: true, keys: adding[..]);
	fixture.feed(corner, keys: adding[..]);

	after = brush_weight_of(&fixture, 4, chest);
	test::@check(after > 0.95f, "one tap at full strength left the corner at %s", after);
}

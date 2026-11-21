<*
 The Joint card: its Rename field, the anchor padlocks and the Keep angle cell,
 and R and ctrl+R on the rest rig and on a paused clip.
*>
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
 commits, so a single Ctrl+Z takes it back. A name already there comes up
 selected, so typing over it replaces it. Asserted here rather than left to
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

	// A dot that already has a name comes up with it, selected: the commonest
	// rename replaces the name outright, so typing it is the whole gesture.
	fixture.app.rename(id, "thigh_R");
	fixture.app.select(id);
	fixture.ui.flush();
	crig::begin_joint_rename(fixture.ui);
	fixture.ui.flush();
	Element*? named_elem = fixture.ui.find_id(crig::JOINT_NAME_FIELD_ID);
	if (catch named_elem)
	{
		test::@check(false, "a named dot's card raised no field");
		return;
	}
	TextField* field = named_elem.widget_as(TextField);
	test::eq(field.value(), "thigh_R");
	usz low = min(field.caret, field.anchor);
	usz high = max(field.caret, field.anchor);
	test::@check(low == 0 && high == "thigh_R".len,
		"the name came up unselected — %d..%d of %d", low, high, "thigh_R".len);
	fixture.type_into(named_elem, "thigh_L");
	fixture.feed_key(Key.RETURN);
	fixture.ui.flush();
	test::eq(fixture.app.doc.find(id).name, "thigh_L");
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

	// One undo hands it back, so the pose half starts from build_limb's shape.
	// Export walks out from the root, so this decides which way every bone points.
	fixture.chord(fixture.ui.input.mouse, Key.LEFT_CTRL, Key.Z);
	test::@check(fixture.doc().root_id == limb.hips, "undo did not hand the root back to the hips");

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

module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::io;
import std::math;

<*
 With auto-connect on and a joint selected, hovering the mesh shows where a click
 would chain the next joint: the dashed bone ends where the joint lands, and the
 hint names the joint it chains from. Esc starts a new limb.
*>
fn void auto_connect_shows_where_the_next_joint_chains() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("auto-connect shows where the next joint chains");
	fixture.reset();

	fixture.ensure_a_dot();
	uint first = fixture.app.selected;
	test::@check(first != 0, "placing a joint did not select it");
	fixture.app.rename(first, "spine_02");

	fixture.feed(SPOT_A);
	fixture.feed(SPOT_A + (Vec2){ 5, 0 });
	Viewport* view = fixture.viewport.widget_as(Viewport);
	test::@check(view.chain_valid && fixture.app.chain_preview == first,
		"hovering the mesh with a joint selected shows no preview bone");
	String hint = crig::hint_line(&fixture.app);
	test::@check(hint.starts_with("chaining from spine_02"), "the hint does not say what it chains from: \"%s\"", hint);
	Vec3 preview = view.chain_to;

	fixture.click(SPOT_A + (Vec2){ 5, 0 });
	uint second = fixture.app.selected;
	test::@check(second != first && second != 0, "the click did not place a joint");
	Dot* placed = fixture.doc().find(second);
	test::@check(placed != null && (placed.position - preview).length() < 1e-4f,
		"the joint did not land where the preview bone ended");
	bool bonded = false;
	foreach (edge : fixture.doc().edges.array_view())
	{
		if ((edge.a == first && edge.b == second) || (edge.a == second && edge.b == first)) bonded = true;
	}
	test::@check(bonded, "the new joint was not chained to the one the preview came from");

	// Esc clears the selection, so the next click starts a new limb.
	fixture.feed_key(Key.ESCAPE);
	fixture.feed(SPOT_C);
	test::@check(fixture.app.selected == 0, "esc did not clear the selection");
	test::@check(!crig::hint_line(&fixture.app).starts_with("chaining"), "the chaining hint outlived the selection");
	test::@check(!view.chain_valid, "the preview bone outlived the selection");

	// With auto-connect off there is nothing to preview.
	fixture.app.select(second);
	fixture.app.doc.auto_connect = false;
	fixture.feed(SPOT_C + (Vec2){ 6, 0 });
	test::@check(!view.chain_valid && fixture.app.chain_preview == 0, "a preview bone showed with auto-connect off");
	fixture.app.doc.auto_connect = true;
}

<*
 The weight brush opens from the Weights card (it has no tool column cell), and
 while it is open an options strip gives its size and Add / Remove as controls:
 a plain drag on the mesh then paints in the chosen direction with no modifier
 held. Closing it hands the card its part back.
*>
fn void the_brush_button_and_strip_paint_without_a_modifier() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Weights card's brush button and its options strip paint without a modifier");
	fixture.reset();
	uint chest = fixture.two_dots();
	fixture.feed(VIEWPORT_CENTER);

	foreach (cell : crig::tool_cells)
	{
		test::@check(cell.on_select != &crig::menu_weight_brush, "the brush still has a tool column cell");
	}
	test::@check(!fixture.in_tree(crig::BRUSH_MODE_ID), "the brush strip shows with no brush open");
	fixture.click(fixture.center_of(crig::JOINT_TAB_WEIGHTS_ID)!!);
	test::@check(fixture.app.areaing, "the Weights card did not open the Area tool");
	fixture.click(fixture.center_of(crig::WEIGHTS_BRUSH_ID)!!);
	test::@check(fixture.app.brushing && !fixture.app.areaing, "the card's brush button did not open the brush");
	fixture.feed(VIEWPORT_CENTER);
	Element* button = fixture.ui.find_id(crig::WEIGHTS_BRUSH_ID)!!;
	test::@check(button.widget_as(Button).label == "Stop painting", "the brush button does not say it stops painting");
	test::@check(fixture.in_tree(crig::BRUSH_MODE_ID) && fixture.in_tree(crig::BRUSH_SIZE_ID),
		"the options strip did not appear with the brush");

	// The size slider sets the radius.
	Element* size = fixture.ui.find_id(crig::BRUSH_SIZE_ID)!!;
	float was = fixture.app.brush_radius;
	fixture.click(size.absolute + (Vec2){ size.size.x * 0.6f, size.size.y * 0.5f });
	test::@check(fixture.app.brush_radius != was, "the size slider did not change the brush");
	fixture.app.set_brush_radius(was);

	// Remove on the strip.
	Element* mode = fixture.ui.find_id(crig::BRUSH_MODE_ID)!!;
	fixture.click(mode.absolute + (Vec2){ mode.size.x * 0.75f, mode.size.y * 0.5f });
	test::@check(fixture.app.brush_removes, "clicking Remove did not switch the brush");

	// Head-on, at a cube corner (the fixture cube's only vertices).
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

	float yaw = fixture.app.camera.yaw;
	fixture.drag(corner, corner + (Vec2){ 4, 0 });
	test::@check(fixture.app.doc.pins.len() > 0, "a plain drag on the mesh in Remove painted nothing");
	foreach (pin : fixture.app.doc.pins.array_view())
	{
		test::@check(pin.dot_id != chest || pin.share < 1.0f, "Remove added weight instead of taking it off");
	}
	test::@check(fixture.app.camera.yaw == yaw, "the stroke also orbited");
	test::@check(fixture.app.undo(), "the stroke did not undo");

	// Picking another joint keeps the brush rather than reopening the part.
	fixture.app.select(chest);
	test::@check(fixture.app.brushing && !fixture.app.areaing, "selecting a joint closed the brush");

	fixture.feed_key(Key.ESCAPE);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(!fixture.app.brushing, "esc did not close the brush");
	test::@check(!fixture.in_tree(crig::BRUSH_MODE_ID), "the strip stayed up after the brush closed");
	test::@check(fixture.app.areaing && fixture.app.area_pending(), "closing the brush did not give the card its part back");
	fixture.app.brush_removes = false;
}

<*
 With the Move tool a plain drag on a joint moves its rest position — one undo —
 while under the Select tool the same drag needs Alt.
*>
fn void the_move_tool_drags_a_joints_rest_position() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Move tool drags a joint's rest position");
	fixture.reset();

	fixture.click(SPOT_A);
	uint first = fixture.app.selected;
	fixture.feed_key(Key.ESCAPE);
	fixture.click(SPOT_C);
	if (first == 0 || fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the joints did not place");
		return;
	}
	fixture.feed_key(Key.ESCAPE);

	Vec3 before = fixture.doc().find(first).position;
	Vec2 at = fixture.pixel_of(first)!!;

	// Select tool on Pose, no Alt: the rest position stays.
	fixture.app.stage = crig::EditStage.POSE_STAGE;
	fixture.drag(at, at + (Vec2){ 0, 30 });
	test::@check(fixture.doc().find(first).position == before, "a bare drag under the Select tool on Pose moved the rest position");
	fixture.feed_key(Key.ESCAPE);

	// Nor the Move tool's: on Pose it poses, never moves the joint on the model.
	crig::menu_move_tool(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	fixture.drag(at, at + (Vec2){ 0, 30 });
	test::@check(fixture.doc().find(first).position == before, "the Move tool's drag on Pose moved the rest position");
	fixture.feed_key(Key.ESCAPE);

	// On Joints it moves the joint.
	fixture.app.stage = crig::EditStage.JOINTS_STAGE;
	fixture.drag(at, at + (Vec2){ 0, 30 });
	test::@check(fixture.doc().find(first).position != before, "a plain drag with the Move tool did not move the joint");
	test::@check(fixture.app.undo(), "the move did not undo");
	test::@check(fixture.doc().find(first).position == before, "one undo did not put the joint back");
	crig::menu_tweak(fixture.ui);
}

<*
 After a fit that faces away, the offer's Turn around turns the whole skeleton
 180° about Y as one undo step.
*>
fn void turn_around_turns_the_skeleton_in_one_step() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Turn around turns the skeleton in one step");
	fixture.reset();

	uint hips = fixture.app.add_recorded({ 0.1f, 0.0f, 0.3f }, "hips");
	uint head = fixture.app.add_recorded({ 0.1f, 0.6f, 0.3f }, "head");
	fixture.app.connect_recorded(hips, head);
	fixture.app.undo_stack.commit();

	Vec3 centre = fixture.app.geometry.bounds().center();
	crig::open_turn_offer(fixture.ui);
	fixture.ui.flush();
	Vec2? apply = fixture.center_of(crig::TURN_OFFER_APPLY_ID);
	if (catch apply)
	{
		test::@check(false, "the offer has no Turn around button");
		return;
	}
	fixture.click(apply);
	test::@check(!fixture.in_tree(crig::TURN_OFFER_APPLY_ID), "the offer stayed open");

	Vec3 turned = fixture.doc().find(hips).position;
	test::@check(math::abs(turned.x - (2.0f * centre.x - 0.1f)) < 1e-4f
		&& math::abs(turned.z - (2.0f * centre.z - 0.3f)) < 1e-4f
		&& math::abs(turned.y) < 1e-4f,
		"hips did not turn 180° about Y (%.3f, %.3f, %.3f)", turned.x, turned.y, turned.z);

	test::@check(fixture.app.undo(), "Turn around did not undo");
	Vec3 back = fixture.doc().find(hips).position;
	test::@check((back - (Vec3){ 0.1f, 0.0f, 0.3f }).length() < 1e-5f, "one undo did not turn it back");
}

<*
 G on Pose with nothing to pose — no clip, several joints selected — is refused,
 not turned into a move of the rest skeleton: Pose never edits the rig.
*>
fn void g_on_pose_never_moves_the_rest_skeleton() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("G on Pose never moves the rest skeleton");
	fixture.reset();

	fixture.click(SPOT_A);
	uint first = fixture.app.selected;
	fixture.feed_key(Key.ESCAPE);
	fixture.click(SPOT_C);
	uint second = fixture.app.selected;
	if (first == 0 || second == 0 || fixture.doc().dots.len() != 2)
	{
		test::@check(false, "SKIPPED — the joints did not place");
		return;
	}
	fixture.feed_key(Key.ESCAPE);
	Vec3 first_was = fixture.doc().find(first).position;
	Vec3 second_was = fixture.doc().find(second).position;

	fixture.app.stage = crig::EditStage.POSE_STAGE;
	fixture.app.select(first);
	fixture.app.extend_selection(second);
	fixture.feed(VIEWPORT_CENTER);
	fixture.feed_key(Key.G);
	fixture.feed(VIEWPORT_CENTER + (Vec2){ 40, 25 });
	fixture.click(VIEWPORT_CENTER + (Vec2){ 40, 25 });
	test::@check(!fixture.app.transform_interaction.active, "G began a rest transform on Pose");
	test::@check(fixture.doc().find(first).position == first_was, "G on Pose moved a joint on the model");
	test::@check(fixture.doc().find(second).position == second_was, "G on Pose moved a joint on the model");
}

// Scale model's dialog, driven through the interface fixture.
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

<*
 The model's right-click menu offers Scale model…, and typing a height in its
 dialog states the factor beside it.
*>
fn void the_scale_dialog_turns_a_height_into_a_factor() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	fixture.app.select_scene(MODEL);
	fixture.app.refresh_ui();
	fixture.ui.flush();
	crig::scene_context_scale_model(fixture.ui);
	fixture.ui.flush();
	Element* dialog = fixture.ui.find_id(crig::SCALE_MODEL_DIALOG_ID)!!;
	test::@check(dialog.widget_as(Dialog).open, "Scale model… did not open its dialog");

	float height = fixture.app.model_height();
	crig::scale_model_height_typed(fixture.ui, string::tformat("%f", height * 2.0f));
	test::@check(math::abs(crig::field_text(fixture.ui, crig::SCALE_MODEL_FACTOR_ID).to_float()!! - 2.0f) < 1.0e-3f,
		"typing twice the height did not state a factor of 2: %s", crig::field_text(fixture.ui, crig::SCALE_MODEL_FACTOR_ID));

	crig::apply_scale_model(fixture.ui);
	test::@check(!dialog.widget_as(Dialog).open, "Scale did not close the dialog");
	test::@check(math::abs(fixture.app.model_height() - height * 2.0f) < 1.0e-3f * height,
		"the model stands %f, not twice %f", fixture.app.model_height(), height);
	test::@check(fixture.app.undo(), "the scale did not undo");
	fixture.reset();
}

<*
 The Scale cell under Rotate picks the Scale tool, and dragging its ring resizes
 the model live: the drawn size follows the pointer while the mesh itself waits,
 and the release bakes it once — one undo step, about the model's origin.
*>
fn void the_scale_tool_resizes_the_model_live() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	test::@check(crig::tool_cells[3].glyph == crig::ToolGlyph.SCALE_GLYPH, "the cell under Rotate is not Scale");
	Element* tools = fixture.ui.find_id("tools")!!;
	Element* cell = tools.children[0].children[3];
	fixture.click(cell.absolute + cell.size * 0.5f);
	test::@check(fixture.app.transform_tool == crig::TransformTool.SCALE_TOOL, "the Scale cell did not pick the Scale tool");
	test::@check(crig::query_scale_tool(fixture.ui).checked, "the Scale cell is not lit with its tool up");

	Element* view = fixture.ui.find(crig::Viewport)!!;
	crig::TransformGizmoFrame? framed = view.widget_as(crig::Viewport).transform_gizmo_frame(view);
	if (catch framed)
	{
		test::@check(false, "the Scale tool drew no ring");
		return;
	}
	Vec2 pivot = view.absolute + framed.projected_pivot;
	test::@check(framed.operation == crig::TransformOperation.SCALE_TRANSFORM, "the gizmo up is not the scale ring");

	float height = fixture.app.model_height();
	usz vertices = fixture.app.geometry.positions.len;
	Vec3 first = fixture.app.geometry.positions[0];
	Vec2 from = pivot + (Vec2){ 20.0f, 0.0f };
	Vec2 to = pivot + (Vec2){ 40.0f, 0.0f };

	fixture.feed(from);
	fixture.feed(from, left: true);
	fixture.feed(to, left: true);
	test::@check(fixture.app.transform_interaction.active, "pressing in the ring started no scale");
	test::@check(math::abs(fixture.app.preview_scale - 2.0f) < 0.05f,
		"twice as far from the pivot should show twice the size, shows %f", fixture.app.preview_scale);
	test::@check(fixture.app.geometry.positions[0] == first, "the drag baked the mesh before the release");

	fixture.feed(to);
	test::@check(!fixture.app.transform_interaction.active, "the release did not end the scale");
	test::@check(fixture.app.preview_scale == 0.0f, "the preview outlived the release");
	test::@check(fixture.app.geometry.positions.len == vertices, "the bake changed the vertex count");
	test::@check(math::abs(fixture.app.model_height() - height * 2.0f) < 0.05f * height,
		"the model stands %f after the release, not twice %f", fixture.app.model_height(), height);
	test::@check(fixture.app.undo(), "the scale did not undo");
	test::@check(math::abs(fixture.app.model_height() - height) < 1.0e-3f * height, "one undo did not take the whole scale back");
	fixture.app.transform_tool = SELECT_TOOL;
	fixture.reset();
}

<*
 The transaction underneath: a scale shows and does not bake, a cancel leaves the
 model as it was, and a commit is `scale_model_by` — one undo step.
*>
fn void a_scale_transform_previews_then_bakes_once() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();
	crig::AppState* app = &fixture.app;
	float height = app.model_height();

	test::@check(app.begin_transform_target(SCALE_TRANSFORM, { .kind = MODEL_TARGET }), "a model scale would not begin");
	test::@check(app.update_transform_scale(0.5f), "the scale would not move");
	test::@check(app.shown_scale() == 0.5f && math::abs(app.model_height() - height) < 1.0e-6f,
		"a scale in progress should be drawn at half and still measure whole");
	test::@check(app.cancel_transform(), "the scale would not cancel");
	test::@check(app.preview_scale == 0.0f && math::abs(app.model_height() - height) < 1.0e-6f,
		"a cancelled scale left the model changed");

	test::@check(app.begin_transform_target(SCALE_TRANSFORM, { .kind = MODEL_TARGET }), "a second scale would not begin");
	(void)app.update_transform_scale(0.5f);
	test::@check(app.commit_transform(), "the scale did not commit");
	test::@check(math::abs(app.model_height() - height * 0.5f) < 1.0e-3f * height, "the commit did not bake half the size");
	test::@check(app.undo(), "the committed scale did not undo");
	test::@check(math::abs(app.model_height() - height) < 1.0e-3f * height, "undo did not restore the size");

	test::@check(!app.begin_transform_target(SCALE_TRANSFORM, { .kind = SKELETON_TARGET }),
		"a scale is the whole model's, never the skeleton's alone");
	fixture.reset();
}

<*
 With Rotate up and a joint selected, a click on the body selects the model, and
 the tool's ring moves onto it — the tool turns the mesh and its rig together
 rather than the joint's branch inside the body. A drag off the joints still
 orbits and selects nothing.
*>
fn void a_click_on_the_body_gives_the_rotate_tool_the_model() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();

	fixture.click(SPOT_A);
	test::@check(fixture.app.selected != 0, "placing a joint did not select it");
	crig::menu_rotate_tool(fixture.ui);
	fixture.ui.flush();

	fixture.drag(SPOT_B, SPOT_B + (Vec2){ 40.0f, 0.0f });
	test::@check(fixture.app.selected != 0 && fixture.app.scene_selection != MODEL,
		"an orbit drag changed the selection");

	fixture.click(SPOT_B);
	test::@check(fixture.app.selected == 0 && fixture.app.scene_selection == MODEL,
		"a click on the body did not select the model");
	Element* view = fixture.ui.find(crig::Viewport)!!;
	crig::TransformGizmoFrame? framed = view.widget_as(crig::Viewport).transform_gizmo_frame(view);
	if (catch framed)
	{
		test::@check(false, "the Rotate tool drew no ring on the model");
		return;
	}
	test::@check(framed.target.kind == MODEL_TARGET && framed.operation == ROTATE_TRANSFORM,
		"the Rotate ring is not on the model");
	fixture.app.transform_tool = SELECT_TOOL;
	fixture.reset();
}

<*
 Move picked with nothing selected — a model just opened from its sidecar —
 puts its gizmo on the whole model at once, rather than a sentence about the
 Scene outliner and no gizmo. A joint already selected keeps the tool.
*>
fn void a_tool_picked_with_nothing_selected_takes_the_model() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	fixture.reset();
	fixture.app.select_scene(NONE);
	fixture.app.refresh_ui();
	fixture.ui.flush();

	crig::menu_move_tool(fixture.ui);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.app.scene_selection == MODEL, "Move with nothing selected did not take the model");
	Element* view = fixture.ui.find(crig::Viewport)!!;
	crig::TransformGizmoFrame? framed = view.widget_as(crig::Viewport).transform_gizmo_frame(view);
	if (catch framed)
	{
		test::@check(false, "Move with nothing selected drew no gizmo");
		return;
	}
	test::@check(framed.target.kind == MODEL_TARGET, "the Move gizmo is not on the model");
	test::@check(crig::hint_line(&fixture.app).contains("the whole model"), "the hint does not say the model moves: %s",
		crig::hint_line(&fixture.app));

	fixture.app.transform_tool = SELECT_TOOL;
	fixture.click(SPOT_A);
	uint joint = fixture.app.selected;
	test::@check(joint != 0, "placing a joint did not select it");
	crig::menu_rotate_tool(fixture.ui);
	test::@check(fixture.app.selected == joint, "picking Rotate took the selected joint away");
	fixture.app.transform_tool = SELECT_TOOL;
	fixture.reset();
}

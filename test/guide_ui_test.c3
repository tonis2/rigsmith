module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::io;
import std::math::vector;

fn Steps* guide_steps(Fixture* f)
{
	return f.ui.find_id(crig::GUIDE_STEPS_ID)!!.widget_as(Steps);
}

fn StepState guide_state(Fixture* f, GuideStep step) => guide_steps(f).steps[step.ordinal].state;

// Frames until the skin survey has run (it waits for the rig to be still).
fn void settle_guide(Fixture* f)
{
	f.feed(f.ui.input.mouse);
	for (uint i = 0; i < 60 && !f.app.skin_survey.ready; i++) f.feed(f.ui.input.mouse);
	f.feed(f.ui.input.mouse);
}

fn Vec2 guide_step_point(Fixture* f, GuideStep step)
{
	Element* strip = f.ui.find_id(crig::GUIDE_STEPS_ID)!!;
	Steps* steps = strip.widget_as(Steps);
	return strip.absolute + (Vec2){ steps.step_left(strip, (sz)step.ordinal) + 4.0f, strip.size.y * 0.5f };
}

fn bool dialog_open(Fixture* f, String id) => f.ui.find_id(id)!!.widget_as(Dialog).open;

<*
 With nothing loaded every step is not yet, the next step is opening a model and
 clicking Model opens the file chooser.
*>
fn void the_guide_starts_at_open_a_model() @test
{
	io::printn("the workflow guide starts at opening a model");
	Fixture f;
	if (catch f.open(mesh: {}))
	{
		test::@check(false, "the interface would not build over an empty mesh");
		return;
	}
	defer f.close();
	settle_guide(&f);

	test::@check(f.in_tree(crig::GUIDE_STEPS_ID), "the 3D view has no workflow guide");
	foreach (i, step : guide_steps(&f).steps) test::@check(step.state == TODO, "step %d is not 'not yet' with no model", i);
	test::eq(guide_steps(&f).current, (sz)0);
	test::@check(crig::bar_line(&f.app).starts_with("Next: open a model"),
		"the hint bar does not say to open a model: \"%s\"", crig::bar_line(&f.app));

	// It sits in the header, clear of the view's own overlays.
	Element* strip = f.ui.find_id(crig::GUIDE_STEPS_ID)!!;
	test::@check(strip.absolute.y + strip.size.y <= f.viewport.absolute.y + 0.5f, "the guide overlaps the viewport");
	Element* tints = f.ui.find_id("tints")!!;
	test::@check(strip.absolute.x + strip.size.x <= tints.absolute.x, "the guide runs into the tint switch");

	f.click(guide_step_point(&f, MODEL));
	test::@check(dialog_open(&f, crig::FILE_DIALOG_ID), "clicking Model did not open the file chooser");
}

<*
 A loaded mesh with no rig: Model is done and Skeleton is next; clicking Model
 frames the model, clicking Skeleton opens the body-plan picker.
*>
fn void the_guide_asks_for_a_skeleton_on_a_bare_mesh() @test
{
	io::printn("the workflow guide asks for a skeleton on a bare mesh");
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	settle_guide(&f);

	test::@check(guide_state(&f, MODEL) == DONE, "Model is not done with a mesh loaded");
	test::@check(guide_state(&f, SKELETON) == TODO, "Skeleton is done with no joints");
	test::eq(guide_steps(&f).current, (sz)GuideStep.SKELETON.ordinal);
	test::@check(crig::bar_line(&f.app).starts_with("Next: fit a skeleton"),
		"the hint bar does not say to fit a skeleton: \"%s\"", crig::bar_line(&f.app));

	f.app.camera.yaw += 1.0f;
	uint reset = f.app.camera_reset_generation;
	f.click(guide_step_point(&f, MODEL));
	test::@check(f.app.camera_reset_generation != reset, "clicking Model did not frame the model");

	f.click(guide_step_point(&f, SKELETON));
	test::@check(dialog_open(&f, crig::RIG_PROMPT_DIALOG_ID), "clicking Skeleton did not open the body-plan picker");
	f.ui.find_id(crig::RIG_PROMPT_DIALOG_ID)!!.widget_as(Dialog).set_open(f.ui.find_id(crig::RIG_PROMPT_DIALOG_ID)!!, false);
}

<*
 A rig whose middle joint sits far outside the mesh: Skin needs attention with
 the count in its tip, and a click turns the weight view on and selects that
 joint. Skeleton selects the Skeleton row.
*>
fn void the_guide_flags_a_joint_holding_no_skin() @test
{
	io::printn("the workflow guide flags a joint holding no skin");
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	uint hips = f.doc().add_dot({ 0, -0.2f, 0 }, "hips");
	uint chest = f.doc().add_dot({ 0, 0.2f, 0 }, "chest");
	uint far = f.doc().add_dot({ 6, 6, 6 }, "far");
	uint tip = f.doc().add_dot({ 7, 7, 7 }, "tip");
	f.doc().connect(hips, chest);
	// Enough joints inside the cube that the far one is nobody's top four.
	foreach (usz i, at : (Vec3[]) { { 0.7f, 0.7f, 0.7f }, { -0.7f, 0.7f, -0.7f }, { 0.7f, -0.7f, -0.7f }, { -0.7f, -0.7f, 0.7f } })
	{
		uint limb = f.doc().add_dot(at, i == 0 ? "limb_a" : i == 1 ? "limb_b" : i == 2 ? "limb_c" : "limb_d");
		f.doc().connect(chest, limb);
	}
	f.doc().connect(chest, far);
	f.doc().connect(far, tip);
	f.app.mark_rig_stale();
	f.app.refresh_ui();
	settle_guide(&f);

	test::@check(f.app.skin_survey.ready, "the skin survey never ran");
	test::@check(guide_state(&f, SKELETON) == DONE, "a named rig is not a done skeleton");
	test::@check(guide_state(&f, SKIN) == ATTENTION, "a joint outside the mesh did not flag Skin");
	test::eq(f.app.skin_survey.skinless, (usz)1);
	test::eq(f.app.skin_survey.first_skinless, far);
	test::@check(guide_steps(&f).steps[(usz)GuideStep.SKIN.ordinal].detail.starts_with("1 joint hold no skin")
		|| guide_steps(&f).steps[(usz)GuideStep.SKIN.ordinal].detail.contains("hold no skin"),
		"the Skin tip does not say what is wrong: \"%s\"", guide_steps(&f).steps[(usz)GuideStep.SKIN.ordinal].detail);
	test::@check(crig::bar_line(&f.app).contains("hold no skin"), "the next line is not about the skin: \"%s\"", crig::bar_line(&f.app));

	f.app.select(0);
	f.click(guide_step_point(&f, SKIN));
	test::@check(f.app.tint_mode == TintMode.TERRITORY, "clicking Skin did not turn the weight view on");
	test::eq(f.app.selected, far);

	f.click(guide_step_point(&f, SKELETON));
	test::@check(f.app.scene_selection == SceneSelection.SKELETON, "clicking Skeleton did not select the Skeleton");

	// The far joint gone: the survey follows the edit.
	f.app.select(0);
	f.doc().remove_dot(tip);
	f.doc().remove_dot(far);
	f.app.mark_rig_stale();
	f.app.refresh_ui();
	settle_guide(&f);
	test::@check(guide_state(&f, SKIN) == DONE, "Skin still needs attention with every joint inside (%d, first %d, dots %d)", f.app.skin_survey.skinless, f.app.skin_survey.first_skinless, f.doc().dots.len());
}

<*
 A fitted rig with clips: Animations counts them, Export says unsaved changes,
 and the clicks show the Animations pane and open the Export dialog. Hiding the
 guide from the View menu takes the bar and the next-step line away.
*>
fn void the_guide_counts_animations_and_opens_export() @test
{
	io::printn("the workflow guide counts animations and opens export");
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	settle_guide(&f);
	test::@check(guide_state(&f, ANIMATIONS) == TODO, "Animations is done with nothing bound");
	test::@check(guide_state(&f, EXPORT) == ATTENTION, "a fitted rig is not an unsaved change");

	f.app.new_clip("Walk", 4);
	f.app.refresh_ui();
	settle_guide(&f);
	test::@check(guide_state(&f, ANIMATIONS) == DONE, "a bound clip did not mark Animations done");
	test::@check(guide_steps(&f).steps[(usz)GuideStep.ANIMATIONS.ordinal].note == "(1)",
		"Animations does not count its clip: \"%s\"", guide_steps(&f).steps[(usz)GuideStep.ANIMATIONS.ordinal].note);
	test::@check(guide_steps(&f).steps[(usz)GuideStep.EXPORT.ordinal].note == "unsaved", "Export does not say unsaved");

	// One pane: showing Animations splits the model's pane rather than replacing it.
	f.click(guide_step_point(&f, ANIMATIONS));
	f.ui.flush();
	test::@check(!crig::area_layout.root.is_leaf() && crig::area_layout.root.second.active == crig::ANIMATION_VIEW,
		"clicking Animations did not show the Animations pane");
	test::eq(crig::area_layout.root.first.active, (usz)TAB_3D);
	f.viewport = f.ui.find(Viewport)!!;

	f.click(guide_step_point(&f, EXPORT));
	test::@check(dialog_open(&f, crig::EXPORT_DIALOG_ID), "clicking Export did not open the Export dialog");
	f.ui.find_id(crig::EXPORT_DIALOG_ID)!!.widget_as(Dialog).set_open(f.ui.find_id(crig::EXPORT_DIALOG_ID)!!, false);

	crig::menu_workflow_guide(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(!f.in_tree(crig::GUIDE_STEPS_ID), "View › Workflow guide did not hide the bar");
	test::eq(crig::bar_line(&f.app), "");
	crig::menu_workflow_guide(f.ui);
	f.feed(f.ui.input.mouse);
	test::@check(f.in_tree(crig::GUIDE_STEPS_ID), "View › Workflow guide did not bring the bar back");
}

<*
 A save clears the unsaved mark; a later edit raises it again.
*>
fn void the_guide_follows_saving() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	f.two_dots();
	f.app.rename(f.app.selected, "chest_2");
	test::@check(f.app.unsaved(), "a rename is not an unsaved change");
	f.app.mark_saved();
	test::@check(!f.app.unsaved(), "a save left the project unsaved");
	f.app.rename(f.app.selected, "chest_3");
	test::@check(f.app.unsaved(), "an edit after a save is not unsaved");
}

<*
 A finger bone on a dense mesh holds a few dozen vertices, far under half a
 percent of eleven thousand, and still holds skin; a joint that holds nothing
 does not.
*>
fn void a_small_part_on_a_dense_mesh_holds_skin() @test
{
	usz vertices = 11000;
	usz joints = 3;
	float[] skin = alloc::new_array(mem, float, (sz)(vertices * joints));
	defer alloc::free(mem, skin);
	for (usz v = 0; v < vertices; v++) skin[v * joints + (v < 20 ? (usz)1 : (usz)0)] = 1.0f;
	bool[] idle = crig::skinless_joints(mem, skin, vertices, joints, crig::SKIN_INFLUENCES);
	defer alloc::free(mem, idle);
	test::@check(!idle[0], "the body joint reads as empty");
	test::@check(!idle[1], "a 20-vertex finger bone reads as holding no skin");
	test::@check(idle[2], "a joint holding nothing was not flagged");
}

<*
 View › Floor starts ticked and turns the floor off and back on.
*>
fn void the_floor_toggles_from_the_view_menu() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	test::@check(crig::query_show_floor(f.ui).checked, "the floor does not start shown");
	crig::menu_show_floor(f.ui);
	test::@check(f.app.config.hide_floor && !crig::query_show_floor(f.ui).checked, "View › Floor did not hide the floor");
	crig::menu_show_floor(f.ui);
	test::@check(!f.app.config.hide_floor, "View › Floor did not bring the floor back");
}

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

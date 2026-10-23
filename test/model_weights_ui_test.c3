// Rig › Use the model's own weights, and Rig › Reset all weights to automatic.
module crig_tests::ui;

import crig;
import cui;
import std::core::test;

<*
 With no weights of the file's to adopt, Use the model's own weights says so and
 holds nothing; Reset all weights is greyed until a joint keeps edited weights,
 and then lets every one go in one step.
*>
fn void the_model_weights_items_adopt_and_let_go() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	uint chest = f.two_dots();

	test::@check(crig::query_reset_all_weights(f.ui).disabled, "Reset all weights is offered with nothing edited");
	crig::menu_model_weights(f.ui);
	test::@check(f.app.notice().contains("no weights of its own"), "the item said nothing: %s", f.app.notice());
	test::@check(!f.app.weights_edited(), "a model with no weights of its own held a joint");

	uint[1] one = { 0 };
	f.app.set_weight_vertices(one[..], chest, 0.5f);
	test::@check(!crig::query_reset_all_weights(f.ui).disabled, "Reset all weights is greyed over an edited joint");
	crig::menu_reset_all_weights(f.ui);
	test::@check(!f.app.weights_edited() && f.app.doc.pins.len() == 0, "Reset all weights left a joint held");
	test::@check(f.app.notice().contains("automatic weights again"), "the reset said nothing: %s", f.app.notice());
	test::@check(f.app.undo() && f.app.weights_held(chest), "one undo did not bring the edit back");
	f.reset();
}

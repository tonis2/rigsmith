// Rig › Use the model's own weights.
module crig_tests::ui;

import crig;
import cui;
import std::core::test;

<*
 Turning the model's own weights off puts crig's automatic weights on the rig as
 it stands, and says so; with no weights of the file's to go back to, the item
 is then greyed rather than offering a switch that cannot happen.
*>
fn void the_model_weights_item_hands_the_skin_to_the_joints() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	f.two_dots();

	f.app.doc.skin_from_file = true;
	test::@check(crig::query_model_weights(f.ui).checked, "the item is not checked over the model's own weights");
	crig::menu_model_weights(f.ui);
	test::@check(!f.app.doc.skin_from_file, "the item did not hand the skin to crig's weights");
	test::@check(f.app.notice().contains("automatic weights"), "the switch said nothing: %s", f.app.notice());
	test::@check(f.app.unsaved(), "switching weights left nothing to save");
	test::@check(crig::query_model_weights(f.ui).disabled, "with no file weights to return to, the item is not greyed");
	f.reset();
}

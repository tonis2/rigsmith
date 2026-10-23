// The Unused overlay's switches: the View menu and the header strip.
module crig_tests::ui;

import crig;
import cui;
import std::math;
import std::core::test;

<*
 View › Unused weights and the header's third cell flip the same switch, and
 neither switches a weight view on.
*>
fn void unused_weights_toggle_from_the_menu_and_the_strip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	test::@check(crig::query_unused(f.ui).disabled, "the overlay was offered with no rig to read");
	f.click(SPOT_A);
	f.click(SPOT_B);
	f.ensure_a_dot();
	test::@check(!crig::query_unused(f.ui).disabled, "the overlay stayed greyed over a rig");

	crig::menu_unused(f.ui);
	test::@check(f.app.show_unused && crig::query_unused(f.ui).checked, "View › Unused weights did not turn it on");

	f.feed(VIEWPORT_CENTER);
	Element* strip = f.ui.find_id("tints")!!;
	test::@check(strip.widget_as(crig::TintToggles).shown[2].checked, "the header's third cell did not light");
	f.click(strip.absolute + (Vec2){ crig::TINT_CELL_W * 2.5f, crig::TINT_CELL_H * 0.5f });
	test::@check(!f.app.show_unused, "the header's third cell did not turn it off");
	test::@check(f.app.tint_mode == OFF, "the overlay switched a view on");
}

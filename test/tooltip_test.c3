<*
 crig's tooltips: the tool column's hover text, what a greyed tool says, the
 hint bar following the pointer, and an audit that no icon-only control in the
 tool column, the N-panel rail or the view header is left without one. How the
 widget itself behaves (the delay, hiding on leave, press and scroll, wrapping)
 is cui's, and tested there: cui test/unit/tooltip_test.c3.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::tooltip`
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// Longer than the delay, in frames of `DT`.
const int TIP_FRAMES = 45;

// The wrapper around the tool column's cell `index`.
fn Element* tip_cell(Fixture* f, usz index)
{
	Element* tools = f.ui.find_id("tools")!!;
	return tools.children[0].children[(sz)index];
}

fn Vec2 tip_centre(Element* e) => e.absolute + e.size * 0.5f;

// Rest the pointer at `at` for longer than the delay.
fn void tip_hover(Fixture* f, Vec2 at)
{
	for (int i = 0; i < TIP_FRAMES; i++) f.feed(at);
}

fn void tooltip_on_rotate_says_its_name_key_and_what_it_does() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	tip_hover(&f, tip_centre(tip_cell(&f, 2)));
	String shown = widgets::tooltip_shown(f.ui);
	test::@check(shown == crig::tool_cells[2].tip, "hovering Rotate did not show its text");
	test::@check(shown.len > 0 && shown[:6] == "Rotate" && shown.contains("(R)") && shown.contains(" — "),
		"the text is not name, key and description");
}

fn void tooltip_each_tool_has_its_own_text() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	for (usz i = 0; i < crig::tool_cells.len; i++)
	{
		tip_hover(&f, tip_centre(tip_cell(&f, i)));
		String shown = widgets::tooltip_shown(f.ui);
		test::@check(shown.len > 0, "a tool cell showed no tooltip");
		test::@check(shown.contains(crig::tool_cells[i].tip[:4]), "a tool cell showed another tool's text");
		f.feed(VIEWPORT_CENTER);
	}
}

fn void tooltip_on_a_greyed_tool_says_why() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	// No joints: the lasso is greyed.
	tip_hover(&f, tip_centre(tip_cell(&f, 4)));
	test::@check(widgets::tooltip_shown(f.ui).contains("unavailable: place a joint"), "the greyed lasso did not explain itself");

	// With a joint it is live again, and says what it does.
	f.ensure_a_dot();
	f.app.select(f.app.doc.dots[0].id);
	f.feed(VIEWPORT_CENTER);
	f.ui.flush();
	tip_hover(&f, tip_centre(tip_cell(&f, 4)));
	test::@check(!widgets::tooltip_shown(f.ui).contains("unavailable"), "a live lasso still says it is unavailable");
}

fn void tooltip_hover_puts_the_tools_keys_on_the_hint_bar() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	f.feed(VIEWPORT_CENTER);
	test::@check(widgets::tooltip_hint(f.ui).len == 0, "a hint lingered with the pointer off the tools");
	f.feed(tip_centre(tip_cell(&f, 1)));
	f.feed(tip_centre(tip_cell(&f, 1)));
	test::@check(widgets::tooltip_hint(f.ui) == crig::tool_cells[1].hint, "the hint was not the Move tool's keys");
	test::@check(crig::hint_line(&f.app) == crig::tool_cells[1].hint, "the bar does not show the hovered tool's keys");
	f.feed(VIEWPORT_CENTER);
	f.feed(VIEWPORT_CENTER);
	test::@check(widgets::tooltip_hint(f.ui).len == 0, "the hint stayed after the pointer left");
}

// Every Button under `e` must sit under a tooltip that has something to say.
fn usz tip_audit(Element* e, bool* ok)
{
	usz buttons = 0;
	if (e.is_widget(Button))
	{
		buttons++;
		Element* holder = widgets::tooltip_above(e);
		if (!holder || holder.widget_as(Tooltip).text_at(holder, tip_centre(e)).len == 0) *ok = false;
	}
	foreach (child : e.children) buttons += tip_audit(child, ok);
	return buttons;
}

fn void tooltip_audit_no_icon_only_control_is_without_one() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.ensure_a_dot();
	f.app.select(f.app.doc.dots[0].id);
	f.feed(VIEWPORT_CENTER);
	f.ui.flush();

	bool ok = true;

	// The tool column: one button per tool, each under its own wrapper.
	Element* tools = f.ui.find_id("tools")!!;
	test::eq(tip_audit(tools, &ok), (usz)crig::tool_cells.len);
	test::@check(ok, "a tool column button has no tooltip text");

	// The N-panel's tab rail.
	String[4] rail = { crig::JOINT_TAB_JOINT_ID, crig::JOINT_TAB_ALIGN_ID, crig::JOINT_TAB_WEIGHTS_ID, crig::JOINT_TAB_POSE_ID };
	foreach (id : rail)
	{
		Element* tab = f.ui.find_id(id)!!;
		test::eq(tip_audit(tab, &ok), (usz)1);
		test::@check(ok, "an N-panel tab has no tooltip text");
	}

	// The header's icon strips and the stage switch: hand-painted or segmented
	// rather than Buttons, so each must sit under a wrapper that answers for
	// every cell.
	String[3] header = { "shading", "tints", crig::STAGE_SWITCH_ID };
	foreach (id : header)
	{
		Element* strip = f.ui.find_id(id)!!;
		Element* holder = widgets::tooltip_above(strip);
		test::@check(holder != null, "a header control has no tooltip wrapper");
		float[2] xs = { 0.2f, 0.8f };
		foreach (x : xs)
		{
			Vec2 at = strip.absolute + (Vec2){ strip.size.x * x, strip.size.y * 0.5f };
			test::@check(holder.widget_as(Tooltip).text_at(holder, at).len > 0, "a header cell has no tooltip text");
		}
	}
}

// How many Buttons under `e` say something in words.
fn usz labelled_buttons(Element* e)
{
	usz labelled = 0;
	if (e.is_widget(Button) && e.widget_as(Button).label.len > 0) labelled++;
	foreach (child : e.children) labelled += labelled_buttons(child);
	return labelled;
}

<*
 The Weights card is a strip of icons, each with a tooltip saying what it does,
 and narrower than the cards whose controls are words: no button on it carries
 a label, every one sits under text, Apply and Reset have a row of their own
 below Mirror and the brush, the Apply cell names its key, the brush puts its
 keys on the hint bar, and Mirror's tooltip follows the switch.

 *Re-introduce:* put a `panel_button("Grow", …)` back on the card, or drop the
 `widgets::tip` from `@card_icon`, or move Apply and Reset back into the Mirror row.
*>
fn void tooltip_audit_the_weights_card_is_icons_that_say_what_they_do() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.two_dots();
	f.app.show_joint_panel = true;
	f.app.joint_panel_tab = crig::JointPanelTab.JOINT;
	f.app.refresh_ui();
	f.feed(VIEWPORT_CENTER);
	float joint_w = f.ui.find_id(crig::JOINT_SECTION_ID)!!.size.x;
	f.click(f.center_of(crig::JOINT_TAB_WEIGHTS_ID)!!);
	test::@check(f.app.weights_card_open(), "the Weights tab did not open the card");

	Element* card = f.ui.find_id(crig::WEIGHTS_SECTION_ID)!!;
	test::@check(card.size.x < joint_w, "the Weights card is %f wide, no narrower than the Joint card's %f", card.size.x, joint_w);
	bool ok = true;
	usz buttons = tip_audit(card, &ok);
	test::@check(buttons >= 7, "the card has %d buttons, short of its seven icons", buttons);
	test::@check(ok, "a button on the Weights card has no tooltip text");
	test::eq(labelled_buttons(card), (usz)0);

	// Grouped by job: Apply and Reset share a row of their own, below the one
	// with Mirror and the brush.
	Vec2 apply = f.center_of(crig::WEIGHTS_APPLY_ID)!!;
	Vec2 reset = f.center_of(crig::WEIGHTS_RESET_ID)!!;
	Vec2 mirror_at = f.center_of(crig::WEIGHTS_MIRROR_ID)!!;
	Vec2 brush_at = f.center_of(crig::WEIGHTS_BRUSH_ID)!!;
	test::@check(math::abs(apply.y - reset.y) < 0.5f && math::abs(mirror_at.y - brush_at.y) < 0.5f,
		"Apply and Reset, or Mirror and the brush, are not on one row");
	test::@check(apply.y > mirror_at.y + 1.0f, "Apply and Reset are not on a row below Mirror and the brush");

	tip_hover(&f, f.center_of(crig::WEIGHTS_APPLY_ID)!!);
	String shown = widgets::tooltip_shown(f.ui);
	test::@check(shown.starts_with("Apply") && shown.contains("(Enter)"), "hovering Apply showed \"%s\"", shown);
	f.feed(f.center_of(crig::WEIGHTS_BRUSH_ID)!!);
	f.feed(f.center_of(crig::WEIGHTS_BRUSH_ID)!!);
	test::@check(widgets::tooltip_hint(f.ui).starts_with("Paint brush"), "the brush put \"%s\" on the hint bar",
		widgets::tooltip_hint(f.ui));

	test::@check(f.app.area_mirrors(), "the card opened with Mirror off");
	f.click(f.center_of(crig::WEIGHTS_MIRROR_ID)!!);
	test::@check(!f.app.area_mirrors(), "the Mirror cell did not switch mirroring off");
	Element* mirror = f.ui.find_id(crig::WEIGHTS_MIRROR_ID)!!;
	String says = widgets::tooltip_above(mirror).widget_as(Tooltip).text;
	test::@check(says.starts_with("Mirror is off"), "the switched-off Mirror says \"%s\"", says);
}

module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;

<*
 Clip tools offers Remove movement and Optimize keys. Each opens its dialog, and
 Apply runs the tool on the clip being edited: a clip with nothing to take out
 or drop says so and leaves the undo history alone.
*>
fn void the_motion_tools_open_from_clip_tools_and_say_when_there_is_nothing_to_do() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.app.new_clip("Walk", 2);
	f.app.show_edited();

	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	sz cursor = f.app.undo_stack.cursor;

	f.click(f.center_of(crig::ANIM_TOOLS_BUTTON_ID)!!);
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_MOTION_ID) && f.in_tree(crig::ANIM_OPTIMIZE_ID), "Clip tools lacks the motion tools");
	f.click(f.center_of(crig::ANIM_MOTION_ID)!!);
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_MOTION_TRANSLATION_ID) && f.in_tree(crig::ANIM_MOTION_TURNING_ID),
		"Remove movement did not open its dialog");
	test::@check(!f.in_tree(crig::ANIM_MOTION_MODE_ID), "On root joint is offered on a rig with none");
	f.click(f.center_of(crig::ANIM_MOTION_APPLY_ID)!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, cursor);
	test::@check(f.app.notice().contains("already stays in place"), "Remove movement said: %s", f.app.notice());

	f.click(f.center_of(crig::ANIM_TOOLS_BUTTON_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_OPTIMIZE_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_OPTIMIZE_APPLY_ID)!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, cursor);
	test::@check(f.app.notice().contains("no keys to lose"), "Optimize keys said: %s", f.app.notice());
}

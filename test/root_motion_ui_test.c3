module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;

<*
 The pane's Optimize button opens one dialog with Remove translation, rotation and
 jitter, none ticked; Clip tools keeps Optimize keys and no longer offers the
 three. Apply with nothing ticked leaves the dialog up; a clip with nothing to
 take out or drop says so and leaves the undo history alone.
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
	test::@check(f.in_tree(crig::ANIM_OPTIMIZE_ID), "Clip tools lacks Optimize keys");
	test::@check(!f.in_tree("anim-motion") && !f.in_tree("anim-smooth"), "Clip tools still offers Remove movement or Smooth jitter");
	f.close_menu();

	f.click(f.center_of(crig::ANIM_CLEANUP_ID)!!);
	f.ui.flush();
	String[3] boxes = { crig::ANIM_CLEANUP_TRANSLATION_ID, crig::ANIM_CLEANUP_ROTATION_ID, crig::ANIM_CLEANUP_JITTER_ID };
	foreach (id : boxes)
	{
		test::@check(f.in_tree(id), "Optimize did not open its dialog with %s", id);
		if (f.in_tree(id)) test::@check(!f.ui.find_id(id)!!.widget_as(Checkbox).checked, "%s is ticked on opening", id);
	}
	test::@check(!f.in_tree(crig::ANIM_CLEANUP_MODE_ID), "On root joint is offered on a rig with none");

	f.click(f.center_of(crig::ANIM_CLEANUP_APPLY_ID)!!);
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_CLEANUP_APPLY_ID), "Apply with nothing ticked closed the dialog");
	test::eq(f.app.undo_stack.cursor, cursor);

	f.click(f.center_of(crig::ANIM_CLEANUP_TRANSLATION_ID)!!);
	f.click(f.center_of(crig::ANIM_CLEANUP_ROTATION_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_CLEANUP_APPLY_ID)!!);
	f.ui.flush();
	test::@check(!f.in_tree(crig::ANIM_CLEANUP_APPLY_ID), "Apply did not close the dialog");
	test::eq(f.app.undo_stack.cursor, cursor);
	test::@check(f.app.notice().contains("already stays in place"), "Optimize said: %s", f.app.notice());

	f.click(f.center_of(crig::ANIM_TOOLS_BUTTON_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_OPTIMIZE_ID)!!);
	f.ui.flush();
	f.click(f.center_of(crig::ANIM_OPTIMIZE_APPLY_ID)!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, cursor);
	test::@check(f.app.notice().contains("no keys to lose"), "Optimize keys said: %s", f.app.notice());
}

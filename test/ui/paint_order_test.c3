module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;

// Siblings paint in tree order: the second of each pair floats over the first.
const String[2][*] PAINT_ORDER @local = {
	{ crig::EXPORT_DIALOG_ID, crig::FILE_DIALOG_ID },
	{ crig::SETTINGS_DIALOG_ID, crig::FILE_DIALOG_ID },
	{ crig::REFERENCE_DIALOG_ID, crig::FILE_DIALOG_ID },
	{ crig::FILE_DIALOG_ID, crig::RIG_PROMPT_DIALOG_ID },
	{ crig::COLLISION_DIALOG_ID, crig::CONFIRM_DIALOG_ID },
	{ crig::CONFIRM_DIALOG_ID, crig::UNSAVED_DIALOG_ID },
	{ crig::ANIM_REMOVE_JOINTS_CONFIRM_ID, "menubar" },
	{ crig::CONTROLS_DIALOG_ID, "menubar" },
	{ "menubar", crig::TUTORIAL_OVERLAY_ID },
	{ crig::TUTORIAL_OVERLAY_ID, crig::WELCOME_DIALOG_ID },
	{ crig::TUTORIAL_OVERLAY_ID, crig::TUTORIAL_DIALOG_ID },
	{ crig::TUTORIAL_DIALOG_ID, "tooltip-host" },
};

// Where an element's branch sits among the root's children, or -1.
fn sz paint_place(Ui* ui, Element* root, String id) @local
{
	Element*? found = ui.find_id(id);
	if (catch found) return -1;
	Element* at = found;
	while (at && at.parent != root) at = at.parent;
	foreach (usz i, child : root.children.array_view()) if (child == at) return (sz)i;
	return -1;
}

fn void the_windows_paint_in_the_order_they_answer_each_other() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s)", error);
		return;
	}
	defer fixture.close();
	Element* root = fixture.ui.find(crig::AppRoot)!!;
	foreach (pair : PAINT_ORDER)
	{
		sz under = paint_place(fixture.ui, root, pair[0]);
		sz over = paint_place(fixture.ui, root, pair[1]);
		test::@check(under >= 0 && over >= 0, "%s or %s is not in the tree", pair[0], pair[1]);
		test::@check(under < over, "%s paints over %s", pair[0], pair[1]);
	}
}

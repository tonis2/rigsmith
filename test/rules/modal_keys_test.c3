<*
 A modal dialog keeps every key but its own Esc. See rules/editing.md.
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import c3w;
import std::core::test;

struct ModalKey @local
{
	String name;
	Key key;
	bool ctrl;
}

const ModalKey[*] MODAL_KEYS @local = {
	{ "Delete", Key.DELETE, false },
	{ "X", Key.X, false },
	{ "G", Key.G, false },
	{ "M", Key.M, false },
	{ "Ctrl+Z", Key.Z, true },
	{ "Ctrl+A", Key.A, true },
};

// Two dots with the first selected, so every key above has something to act on.
fn bool two_dots(Fixture* fixture) @local
{
	fixture.reset();
	fixture.click(SPOT_A);
	fixture.click(SPOT_B);
	if (fixture.doc().dots.len() != 2)
	{
		test::@check(false, "the two dots did not land");
		return false;
	}
	return true;
}

fn void a_modal_keeps_the_keys_from_the_rig() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s)", error);
		return;
	}
	defer fixture.close();
	if (!two_dots(&fixture)) return;

	crig::open_file_dialog(fixture.ui, crig::FilePurpose.OPEN_MESH);
	fixture.ui.flush();
	Dialog* dialog = fixture.ui.get_widget_id(crig::FILE_DIALOG_ID, Dialog)!!;

	foreach (entry : MODAL_KEYS)
	{
		sz dots = fixture.doc().dots.len();
		uint selected = fixture.app.selected;
		sz also = fixture.app.also_selected.len();
		if (entry.ctrl)
		{
			fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, entry.key);
		}
		else
		{
			fixture.feed_key(entry.key);
		}
		test::@check(fixture.doc().dots.len() == dots, "%s changed the rig behind a modal", entry.name);
		test::@check(fixture.app.selected == selected && fixture.app.also_selected.len() == also,
			"%s changed the selection behind a modal", entry.name);
		test::@check(!fixture.app.transform_interaction.active, "%s started a move behind a modal", entry.name);
		test::@check(dialog.open, "%s closed the modal", entry.name);
	}

	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();
	test::@check(!dialog.open, "Esc did not close the modal");
}

// The chooser opens over Export, and closing it hands the keys back to Export.
fn void a_modal_under_a_closed_one_keeps_the_keys() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s)", error);
		return;
	}
	defer fixture.close();
	if (!two_dots(&fixture)) return;

	crig::set_dialog_open(fixture.ui, crig::EXPORT_DIALOG_ID, true);
	fixture.ui.flush();
	crig::open_file_dialog(fixture.ui, crig::FilePurpose.OPEN_MESH);
	fixture.ui.flush();
	fixture.feed_key(Key.ESCAPE);
	fixture.ui.flush();

	sz dots = fixture.doc().dots.len();
	fixture.feed_key(Key.DELETE);
	test::@check(fixture.doc().dots.len() == dots, "Delete reached the rig behind Export");
}

fn void a_plain_dialog_leaves_the_shortcuts_live() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s)", error);
		return;
	}
	defer fixture.close();
	if (!two_dots(&fixture)) return;

	crig::set_dialog_open(fixture.ui, crig::CONTROLS_DIALOG_ID, true);
	fixture.ui.flush();
	sz dots = fixture.doc().dots.len();
	fixture.feed_key(Key.DELETE);
	test::@check(fixture.doc().dots.len() == dots - 1, "Delete did not reach the rig past the Controls dialog");
}

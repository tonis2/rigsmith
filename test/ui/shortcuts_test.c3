module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import c3w;
import std::core::test;

fn void no_two_rows_of_a_mode_share_a_key() @test
{
	foreach (a : crig::Shortcut::values)
	{
		if (a.mode == ALIAS) continue;
		foreach (b : crig::Shortcut::values)
		{
			if (a.ordinal >= b.ordinal || b.mode != a.mode) continue;
			bool same = a.key == b.key && a.ctrl == b.ctrl && a.shift == b.shift;
			test::@check(!same, "%s and %s share a key", a, b);
		}
	}
}

fn void every_shortcut_is_listed() @test
{
	foreach (row : crig::Shortcut::values)
	{
		if (row.mode == ALIAS) continue;
		bool listed;
		foreach (control : crig::CONTROLS) if (control.key == row) listed = true;
		test::@check(listed, "%s isn't in the Controls dialog", row);
	}
}

fn void every_row_says_what_it_does() @test
{
	foreach (row : crig::Shortcut::values)
	{
		if (row == NONE) continue;
		test::@check(row.label.len > 0 && row.action.len > 0, "%s has no text", row);
	}
}

fn void every_plain_row_is_found_by_its_key() @test
{
	foreach (row : crig::Shortcut::values)
	{
		if (!row.run) continue;
		test::@check(crig::shortcut_of(row.key, row.ctrl, row.shift) == row, "%s isn't reached by its key", row);
	}
}

fn void shift_only_changes_a_letter_with_a_shifted_row() @test
{
	test::@check(crig::shortcut_of(Key.B, false, true) == SHOW_MESH, "shift+B");
	test::@check(crig::shortcut_of(Key.T, false, true) == LASSO_PIN, "shift+T");
	test::@check(crig::shortcut_of(Key.Z, true, true) == REDO_SHIFTED, "ctrl+shift+Z");
	test::@check(crig::shortcut_of(Key.Q, false, false) == NONE, "a key with no row");
}

fn void the_menus_show_the_tables_keys() @test
{
	test::@check(crig::file_items[0].shortcut == crig::Shortcut.NEW_SCENE.label, "the File menu");
	test::eq(crig::Shortcut.SAVE_AS.label, "Ctrl+Shift+S");
	test::eq(crig::Shortcut.LASSO_PIN.label, "Shift+T");
}

fn void pressing_each_plain_row_runs_it() @test
{
	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s)", error);
		return;
	}
	defer fixture.close();
	test::@check(fixture.app.config.directory.len == 0, "this would write the real config");
	crig::AppRoot* root = fixture.ui.find(crig::AppRoot)!!.widget_as(crig::AppRoot);

	foreach (row : crig::Shortcut::values)
	{
		if (!row.run) continue;
		fixture.reset();
		root.last_shortcut = NONE;
		Key[2] mods;
		usz held;
		if (row.ctrl) mods[held++] = Key.LEFT_CTRL;
		if (row.shift) mods[held++] = Key.LEFT_SHIFT;
		Key[3] all;
		all[:held] = mods[:held];
		all[held] = row.key;
		fixture.feed(VIEWPORT_CENTER, keys: mods[:held]);
		fixture.feed(VIEWPORT_CENTER, keys: all[:held + 1]);
		fixture.feed(VIEWPORT_CENTER, keys: mods[:held]);
		fixture.feed(VIEWPORT_CENTER);
		test::@check(root.last_shortcut == row, "%s didn't run: %s did", row, root.last_shortcut);
	}
}

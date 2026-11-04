module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// The menu bar

<*
 The dropdown life cycle: open on a title click, close on the same title, close
 on a click anywhere else — with that click swallowed rather than acted on —
 switch on hover while open, and close on ESC without the key falling through
 to the app's own ESC handling.

 The items are asserted through `in_tree` because they genuinely are not in the
 tree while the menu is closed: the composite builds them on open and releases
 them on close, so existence and openness are the same fact.
*>
fn void menus_open_and_dispatch() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("menus open, dispatch and close");
	fixture.reset();

	// A dot to endanger: the clicks and the ESC below must all leave it alone.
	fixture.click(SPOT_B);
	sz dots = fixture.doc().dots.len();
	test::@check(dots == 1 && fixture.app.selected != 0, "a dot is placed and selected to start");

	test::@check(!fixture.in_tree("Undo"), "no dropdown items exist before a click");

	Vec2? edit_title = fixture.center_of("Edit");
	if (catch edit_title)
	{
		test::@check(false, "SKIPPED — the Edit title is not on the bar");
		return;
	}

	fixture.click(edit_title);
	test::@check(fixture.in_tree("Undo"), "clicking a title opens its dropdown");
	test::@check(fixture.doc().dots.len() == dots, "and places nothing");

	fixture.click(edit_title);
	test::@check(!fixture.in_tree("Undo"), "clicking the title again closes it");

	// The click-elsewhere close, and the half that matters: the closing click
	// is consumed by the catcher, so the model under it never sees a press.
	fixture.click(edit_title);
	fixture.click(SPOT_A);
	test::@check(!fixture.in_tree("Undo"), "a click on the canvas closes the menu");
	test::@check(fixture.doc().dots.len() == dots, "and does not also place a dot through it");

	// Hover slides between menus once one is open, Blender-style. Between titles
	// on the SAME bar: the sliding is a bar's own state, and the window bar and a
	// pane's header are two of them — see check_view_bar_is_the_panes_own.
	fixture.click(edit_title);
	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.feed(file_title);
	test::@check(fixture.in_tree("Quit"), "hovering another title switches to its menu");
	test::@check(!fixture.in_tree("Undo"), "and the first one closed");

	// ESC stops at the bar while a menu is open. The app's own ESC clears the
	// selection, so the selection surviving is the proof of where the key died.
	fixture.tap(file_title, Key.ESCAPE);
	test::@check(!fixture.in_tree("Quit"), "ESC closes the open menu");
	test::@check(fixture.app.selected != 0, "and is consumed there — the selection survives");
}

<*
 Check marks and greying are polled from the app when a dropdown opens, so a
 state changed by the keyboard is already right on the next open — there is no
 push path to forget.
*>
fn void menu_checkmarks_follow_state() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("menu check marks follow the app state");
	fixture.reset();

	fixture.tap(SPOT_B, Key.A);
	test::@check(!fixture.app.doc.auto_connect, "A turns chaining off from the keyboard");

	Vec2? rig_title = fixture.center_of("Rig");
	if (catch rig_title)
	{
		test::@check(false, "SKIPPED — the Rig title is not on the bar");
		return;
	}
	fixture.click(rig_title);

	Element*? item = fixture.ui.find_id("Auto-connect");
	if (catch item)
	{
		test::@check(false, "SKIPPED — the Auto-connect item is not in the dropdown");
		return;
	}
	test::@check(!item.widget_as(MenuItemRow).item.checked, "the item shows the keyboard's toggle");

	fixture.click(item.absolute + item.size * 0.5f);
	test::@check(fixture.app.doc.auto_connect, "clicking the item toggles it back on");
	test::@check(!fixture.in_tree("Auto-connect"), "and closes the menu");

	// Disabled: Undo with an empty history declines the click — and does not
	// close, because the press must also not fall through to the catcher.
	fixture.reset();
	Vec2? edit_title = fixture.center_of("Edit");
	if (catch edit_title)
	{
		test::@check(false, "SKIPPED — the Edit title is not on the bar");
		return;
	}
	fixture.click(edit_title);

	Element*? undo_item = fixture.ui.find_id("Undo");
	if (catch undo_item)
	{
		test::@check(false, "SKIPPED — the Undo item is not in the dropdown");
		return;
	}
	test::@check(undo_item.widget_as(MenuItemRow).item.disabled, "Undo is greyed with nothing to undo");

	fixture.click(undo_item.absolute + undo_item.size * 0.5f);
	test::@check(fixture.in_tree("Undo"), "clicking a greyed item does nothing, not even close");
	fixture.tap(edit_title, Key.ESCAPE);
}

<*
 The focus fix this restructure carries: keys used to be dead after clicking
 anything that was not the viewport, because cui clears the focus when a press
 lands on nothing that handles keys. The shortcuts live on the tree's root now,
 so the bar declining a key is enough for it to land.
*>
fn void shortcuts_survive_menu_clicks() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("shortcuts survive a trip to the menu bar");
	fixture.reset();

	fixture.click(SPOT_B);
	test::@check(fixture.doc().dots.len() == 1 && fixture.app.selected != 0, "a dot is placed and selected");

	// Open and close a menu: whatever is focused now, it is not the viewport.
	Vec2? file_title = fixture.center_of("File");
	if (catch file_title)
	{
		test::@check(false, "SKIPPED — the File title is not on the bar");
		return;
	}
	fixture.click(file_title);
	fixture.click(file_title);

	fixture.tap(file_title, Key.X);
	test::@check(fixture.doc().dots.len() == 0, "X still deletes with the focus on the bar");
}

<*
 Help > Controls puts the key reference up, and the dialog takes itself down —
 from its own button, and from ESC without ever being clicked.

 The Dialog element is stable across all of it: it lives outside the bar's
 rebuilt subtree and only its own contents come and go, so one handle observes
 every state. What has to be checked through the tree instead is the *panel*,
 which is exactly what a close releases.
*>
fn void help_toggles_the_controls_dialog() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Help > Controls toggles the Controls dialog");
	fixture.reset();

	Element*? dialog = fixture.ui.find(Dialog);
	if (catch dialog)
	{
		test::@check(false, "SKIPPED — the Controls dialog is not in the tree");
		return;
	}
	test::@check(!dialog.widget_as(Dialog).open, "the reference starts put away");
	test::@check(fixture.in_tree(widgets::DIALOG_CLOSE_ID) == false, "with no panel in the tree at all");

	Vec2? help_title = fixture.center_of("Help");
	if (catch help_title)
	{
		test::@check(false, "SKIPPED — the Help title is not on the bar");
		return;
	}

	fixture.click(help_title);
	Vec2? controls = fixture.center_of("Controls");
	if (catch controls)
	{
		test::@check(false, "SKIPPED — the Controls item is not in the dropdown");
		return;
	}
	fixture.click(controls);
	test::@check(dialog.widget_as(Dialog).open, "one click opens it");

	// The panel is on the window, whole and centred on it. Centring is cui's, but
	// where the dialog is *mounted* is crig's: hung inside a pane it would be
	// centred on the pane and clipped by it.
	Element*? panel = fixture.ui.find(DialogFrame);
	if (catch panel)
	{
		test::@check(false, "SKIPPED — the dialog opened with no panel");
		return;
	}
	test::@check(
		panel.absolute.x >= 0 && panel.absolute.x + panel.size.x <= crig::WIN_W && panel.absolute.y >= 0
			&& panel.absolute.y + panel.size.y <= crig::WIN_H,
		"and the panel sits inside the window"
	);
	test::@check(math::abs(panel.absolute.x + panel.size.x * 0.5f - crig::WIN_W * 0.5f) < 1.0, "centred across it");

	// Every row is measured, so a binding whose text outgrows the panel is a
	// failure here rather than a line clipped off the side of it. Asserted on the
	// width the rows *wanted*, not the one the element got: the sheet sits in a
	// scroll that clamps it, so its own size would report a fit either way.
	Element*? sheet = fixture.ui.find_id("controls");
	if (catch sheet)
	{
		test::@check(false, "SKIPPED — the dialog has no reference sheet");
		return;
	}
	ControlsSheet* rows = sheet.widget_as(ControlsSheet);
	test::@check(sheet.size.x > 0 && sheet.size.y > 0, "the reference measured itself");
	test::@check(
		rows.natural_width <= crig::CONTROLS_SHEET_W - widgets::THUMB_WIDTH - widgets::THUMB_MARGIN,
		"and every row fits the panel clear of the scrollbar (widest %f, room %f)",
		rows.natural_width, crig::CONTROLS_SHEET_W
	);

	// The reason the scroll is there: the reference is taller than the window can
	// give it, so the bottom of the list is reachable only by scrolling to it.
	// Without the scroll those rows are not clipped-but-there, they are gone.
	Element* scroller = sheet.parent;
	if (!scroller || !scroller.is_widget(Scroll))
	{
		test::@check(false, "SKIPPED — the reference is not inside a scroll");
		return;
	}
	Scroll* scroll = scroller.widget_as(Scroll);
	test::@check(
		scroll.content_extent > scroller.size.y,
		"the reference outgrows its viewport (%f into %f)", scroll.content_extent, scroller.size.y
	);
	fixture.scroll(scroller.absolute + scroller.size * 0.5f, { 0.0, -3.0 }, precise: false);
	test::@check(scroll.scroll_offset > 0, "and a wheel over it reaches the rows below the fold");

	test::@check(
		fixture.ui.hit_test(panel.absolute + (Vec2) { 4.0, panel.size.y - 4.0 }) != fixture.viewport,
		"the panel is opaque to the model behind it"
	);

	// The dialog's own close button, which is the half of this that the menu
	// cannot do.
	Vec2? close = fixture.center_of(widgets::DIALOG_CLOSE_ID);
	if (catch close)
	{
		test::@check(false, "SKIPPED — the dialog has no close button");
		return;
	}
	fixture.click(close);
	test::@check(!dialog.widget_as(Dialog).open, "the × in its bar closes it");
	test::@check(fixture.in_tree("controls") == false, "and the sheet goes with it");

	// Reopened from the menu, the item now carries a check mark — the dialog is
	// the state, so this is the same question asked from the other side.
	fixture.click(help_title);
	Vec2? again = fixture.center_of("Controls");
	if (catch again)
	{
		test::@check(false, "SKIPPED — the Controls item did not come back");
		return;
	}
	fixture.click(again);
	test::@check(dialog.widget_as(Dialog).open, "the menu brings it back");
	test::@check(crig::query_controls_shown(fixture.ui).checked, "and the item shows it as shown");

	// ESC, with nothing clicked since: opening focuses the dialog, which is what
	// puts the key in reach at all.
	fixture.tap(VIEWPORT_CENTER, Key.ESCAPE);
	test::@check(!dialog.widget_as(Dialog).open, "esc puts it away");

	// The keyboard is the app's again: ESC on a selection is crig's, and the
	// dialog must not still be holding it.
	fixture.click(SPOT_A);
	if (fixture.app.selected == 0)
	{
		test::@check(false, "SKIPPED — the click placed no dot");
		return;
	}
	fixture.tap(SPOT_A, Key.ESCAPE);
	test::@check(fixture.app.selected == 0, "and the shortcuts have the key back");
}

<*
 Help ends on the build's version: `dev` from a checkout, the tag's number from
 a release. Greyed, so it reads as a note and a click on it does nothing, the
 dropdown staying open around it.
*>
fn void help_shows_the_version() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("Help names the version");
	fixture.reset();

	Vec2? help_title = fixture.center_of("Help");
	if (catch help_title)
	{
		test::@check(false, "SKIPPED — the Help title is not on the bar");
		return;
	}
	fixture.click(help_title);
	Element*? row = fixture.ui.find_id(crig::VERSION_LABEL);
	if (catch row)
	{
		test::@check(false, "the dropdown has no %s row", crig::VERSION_LABEL);
		return;
	}
	test::@check(crig::VERSION_LABEL.starts_with("Rigsmith "), "the row names the app");
	test::@check(row.widget_as(MenuItemRow).item.disabled, "and is greyed");

	fixture.click(row.absolute + row.size * 0.5f);
	fixture.ui.flush();
	test::@check(fixture.in_tree(crig::VERSION_LABEL), "a click on it leaves the dropdown open");
	test::@check(fixture.in_tree(widgets::DIALOG_CLOSE_ID) == false, "and opens nothing");
}

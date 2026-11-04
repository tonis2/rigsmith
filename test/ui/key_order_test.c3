<* Which handler wins when one key has several readings: AppRoot.on_key's order. *>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import c3w;
import std::core::test;
import std::math::vector;

fn bool key_order_rig(Fixture* fixture) @local
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

fn void shift_leaves_a_plain_letter_reading_as_itself() @test
{
	Fixture fixture;
	if (catch fixture.open()) return;
	defer fixture.close();
	if (!key_order_rig(&fixture)) return;

	bool mesh = fixture.app.show_mesh;
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.B);
	test::@check(fixture.app.show_mesh != mesh, "shift+B is B");
}

fn void ctrl_keeps_a_chord_away_from_the_letters() @test
{
	Fixture fixture;
	if (catch fixture.open()) return;
	defer fixture.close();
	if (!key_order_rig(&fixture)) return;

	bool mesh = fixture.app.show_mesh;
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.B);
	test::@check(fixture.app.show_mesh == mesh, "ctrl+B reached B");

	bool auto = fixture.doc().auto_connect;
	fixture.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.A);
	test::@check(fixture.doc().auto_connect == auto, "ctrl+A reached A");
	test::@check(fixture.app.also_selected.len() + 1 >= 2, "ctrl+A selected nothing");
}

fn void undo_reaches_past_a_drag_that_owns_the_letters() @test
{
	Fixture fixture;
	if (catch fixture.open()) return;
	defer fixture.close();
	if (!key_order_rig(&fixture)) return;

	Vec2 at = SPOT_B;
	Vec2 away = at + (Vec2) { 120.0, 70.0 };
	Key[1] hold_alt = { Key.LEFT_ALT };
	fixture.feed(at, keys: hold_alt[..]);
	fixture.feed(at, left: true, keys: hold_alt[..]);
	fixture.feed(away, left: true, keys: hold_alt[..]);
	test::@check(fixture.app.drag.dot != 0, "the drag did not start");

	// Plain Z is the drag's; with ctrl it is undo, and the wireframe stays.
	ulong revision = fixture.app.undo_stack.revision;
	Key[2] undo = { Key.LEFT_CTRL, Key.Z };
	Key[1] ctrl = { Key.LEFT_CTRL };
	fixture.feed(away, left: true, keys: ctrl[..]);
	fixture.feed(away, left: true, keys: undo[..]);
	fixture.feed(away, left: true, keys: ctrl[..]);
	test::@check(fixture.app.undo_stack.revision != revision, "ctrl+Z did not reach undo during a drag");
	test::@check(fixture.app.drag.axis == DragAxis.FREE, "ctrl+Z locked the drag to Z");
}

fn void delete_is_not_a_joints_while_a_path_is_drawn() @test
{
	Fixture fixture;
	if (catch fixture.open()) return;
	defer fixture.close();
	if (!key_order_rig(&fixture)) return;

	fixture.app.path_drawing = true;
	sz dots = fixture.doc().dots.len();
	fixture.feed_key(Key.DELETE);
	fixture.app.path_drawing = false;
	test::@check(fixture.doc().dots.len() == dots, "Delete took a joint while drawing a path");
}

fn void esc_backs_out_a_layer_at_a_time() @test
{
	Fixture fixture;
	if (catch fixture.open()) return;
	defer fixture.close();
	if (!key_order_rig(&fixture)) return;

	uint selected = fixture.app.selected;
	test::@check(selected != 0, "nothing selected");
	fixture.app.lassoing = true;
	fixture.feed_key(Key.ESCAPE);
	test::@check(!fixture.app.lassoing, "esc left the lasso open");
	test::@check(fixture.app.selected == selected, "esc lost the joint along with the tool");
	fixture.feed_key(Key.ESCAPE);
	test::@check(fixture.app.selected == 0, "a second esc kept the joint");
}

fn void a_key_with_nothing_to_act_on_changes_nothing() @test
{
	Fixture fixture;
	if (catch fixture.open()) return;
	defer fixture.close();
	if (!key_order_rig(&fixture)) return;

	fixture.app.select(0);
	sz dots = fixture.doc().dots.len();
	fixture.feed_key(Key.X);
	fixture.feed_key(Key.M);
	test::@check(fixture.doc().dots.len() == dots, "X or M acted with nothing selected");
}

module crig_tests::mcp;
import crig;
import image;
import image::png;
import mcp;
import three;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::collections::object;
import std::encoding::base64;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// pin_weights — the other weight tool that writes: the lasso over the wire.
//
// It borrows `paint_weights`' selection outright, so what these cover is what
// the two do *not* share: the default weight, and that a second dot over the
// same vertices takes nothing from the first.

<*
 A weight can be set by predicate and by explicit vertices, one call is one
 undo step, and another dot over the same vertices leaves the first one's alone.
*>
fn void pinning_is_selectable_and_undoable() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	uint knee = f.app.doc.dots[1].id;

	Object*? pinned = f.call_tool("pin_weights", `{"dot":"knee","vertices":[0,1,2,3]}`);
	if (catch pinned)
	{
		test::@check(false, "pin_weights takes an explicit vertex list");
		return;
	}
	defer pinned.free();

	// No weight given, so the full one — what "these belong to that dot" means.
	test::@check((pinned.get_float("weight") ?? 0.0) == 1.0, "an unstated weight is not the full one");
	for (uint v = 0; v < 4; v++) test::@check(f.app.doc.pin_of(v, knee) == 1.0f, "vertex %d is not the knee's fully", v);
	sz stored = f.app.doc.pins.len();

	Object*? stepped = f.call_tool("undo", "{}");
	if (catch stepped)
	{
		test::@check(false, "undo answers");
		return;
	}
	stepped.free();
	test::eq(f.app.doc.pins.len(), (sz)0);

	f.call_tool("redo", "{}")!!.free();
	test::eq(f.app.doc.pins.len(), stored);

	// By predicate, in `get_weights`' own vocabulary — the same words the paint
	// tool takes, which is the point of sharing the selection.
	Object*? swept = f.call_tool("pin_weights", `{"dot":"knee","weight":0.5,"at_least":0.05}`);
	if (catch swept)
	{
		test::@check(false, "pin_weights takes a predicate selection");
		return;
	}
	defer swept.free();
	test::@check((swept.get_int("selected") ?? 0) > 0, "the predicate selected nothing to pin");

	// A second dot over the same vertex takes nothing from the first: the two blend.
	float had = f.app.doc.pin_of(0, knee);
	f.call_tool("pin_weights", `{"dot":"hips","vertices":[0]}`)!!.free();
	test::@check(f.app.doc.pin_of(0, knee) == had, "the hips took the knee's weight on a vertex they were given");

	Object*? cleared = f.call_tool("pin_weights", `{"dot":"knee","reset":true,"all":true}`);
	if (catch cleared)
	{
		test::@check(false, "reset answers");
		return;
	}
	defer cleared.free();
	test::@check((cleared.get_bool("reset") ?? false) && f.app.doc.pins.len() == 0,
		"reset with all did not put every dot back on the automatic weights");
}

<*
 paint_weights and pin_weights write the same thing — the dot's own weights —
 and either's reset lets the dot go.
*>
fn void paint_and_pin_weights_write_one_layer() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	uint knee = f.app.doc.dots[1].id;

	f.call_tool("paint_weights", `{"dot":"knee","weight":0.1,"vertices":[0,1]}`)!!.free();
	f.call_tool("pin_weights", `{"dot":"knee","vertices":[2,3]}`)!!.free();
	test::@check(f.app.weights_held(knee), "the knee's weights were not held as its own");
	test::@check(f.app.doc.pin_of(0, knee) == 0.1f && f.app.doc.pin_of(2, knee) == 1.0f, "the two calls did not write the knee's own weights");

	f.call_tool("paint_weights", `{"dot":"knee","reset":true}`)!!.free();
	test::eq(f.app.doc.pins.len(), (sz)0);

	f.call_tool("paint_weights", `{"dot":"knee","weight":0.1,"vertices":[0,1]}`)!!.free();
	f.call_tool("pin_weights", `{"dot":"knee","reset":true}`)!!.free();
	test::eq(f.app.doc.pins.len(), (sz)0);
	test::@check(!f.app.weights_held(knee), "pin_weights' reset left the knee held");
}

<*
 A refusal says which value was wrong, on `paint_weights`' terms.
*>
fn void pin_weights_refuses_with_a_sentence() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("pin_weights", `{"dot":"nosuchdot"}`, "nosuchdot"),
		"an unknown dot is named back");
	test::@check(f.refuses_tool("pin_weights", `{"dot":"knee","weight":4}`, "between 0 and 1"),
		"a weight out of range says what the range is");
	test::@check(f.refuses_tool("pin_weights", `{"dot":"knee","exclusive":true}`, "weight"),
		"exclusive is not refused now that no dot takes another's vertices");
}

<*
 build_body refuses a rig whose joints keep edited weights.

 The attachment refusal one level finer, and for the same reason: a generated
 body's vertices are built from its bones, so an index that named a point on the
 loaded mesh names a different point on the new one — and losing hand-drawn
 regions with no undo behind it is worse than being asked.
*>
fn void build_body_refuses_a_rig_whose_vertices_are_pinned() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	f.call_tool("pin_weights", `{"dot":"knee","vertices":[0,1]}`)!!.free();

	test::@check(f.refuses_tool("build_body", `{}`, "edited weights"),
		"a rig with edited weights was built over without a word");
	test::@check(f.refuses_tool("build_body", `{}`, "paint_weights reset"),
		"and the refusal does not name the way out");
}

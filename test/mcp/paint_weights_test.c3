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
// paint_weights — the one weight tool that writes.
//
// The selection is get_weights' own vocabulary read backwards, so what these
// assert is the loop an agent actually runs: read the shared rows, name the same
// vertices back, and see the survey move.

<*
 The survey names a smear and the paint tool takes the same words back.

 The whole design in one check. `get_weights` reports that one dot reaches into
 another's territory; `paint_weights` is handed that row's own fields and the
 overlap goes away — with no vertex indices crossing the wire in either
 direction.
*>
fn void a_shared_row_can_be_painted_away() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? before = f.call_tool("get_weights", `{"dot":"knee"}`);
	if (catch before)
	{
		test::@check(false, "get_weights answers for the knee");
		return;
	}
	defer before.free();

	Object*? rows = before.get("shared");
	if (catch rows)
	{
		test::@check(false, "get_weights reports a shared list for the knee");
		return;
	}
	Object* shared = rows;
	if (shared.get_len() == 0)
	{
		test::@check(false, "the fixture rig has a knee that shares vertices with something");
		return;
	}
	String owner = shared.get_at(0).get_string("name") ?? "";
	usz taken = (usz)(shared.get_at(0).get_int("vertices") ?? 0);
	test::@check(taken > 0, "the worst row names vertices the knee takes from %s", owner);

	// The row's own fields, handed straight back. 0.05 is the floor get_weights
	// reports at, so this selects exactly what it just listed.
	String arguments = string::format(mem,
		`{"dot":"knee","weight":0,"owned_by":"%s","at_least":0.05}`, owner);
	defer alloc::free(mem, arguments);

	Object*? painted = f.call_tool("paint_weights", arguments);
	if (catch painted)
	{
		test::@check(false, "paint_weights takes the row back");
		return;
	}
	defer painted.free();

	test::@check((painted.get_int("painted") ?? 0) > 0, "it corrected something");

	Object*? after = f.call_tool("get_weights", `{"dot":"knee"}`);
	if (catch after)
	{
		test::@check(false, "get_weights answers afterwards");
		return;
	}
	defer after.free();

	usz still = 0;
	if (try Object* left = after.get("shared"))
	{
		for (sz i = 0; i < left.get_len(); i++)
		{
			if ((left.get_at(i).get_string("name") ?? "") == owner)
			{
				still = (usz)(left.get_at(i).get_int("vertices") ?? 0);
			}
		}
	}
	test::@check(still < taken, "the smear the survey named is smaller than it was (%d, was %d)", still, taken);
}

<*
 A correction is one undo step, and reset puts the dot back on the automatic
 weights.
*>
fn void painting_is_undoable_and_resettable() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? painted = f.call_tool("paint_weights", `{"dot":"knee","weight":0.1,"vertices":[0,1,2,3]}`);
	if (catch painted)
	{
		test::@check(false, "paint_weights takes an explicit vertex list");
		return;
	}
	defer painted.free();
	test::@check((painted.get_int("painted") ?? 0) > 0, "the explicit list was painted");
	test::@check(f.app.doc.pins.len() > 0, "and the document holds it");

	Object*? stepped = f.call_tool("undo", "{}");
	if (catch stepped)
	{
		test::@check(false, "undo answers");
		return;
	}
	stepped.free();
	test::@check(f.app.doc.pins.len() == 0, "one undo took the whole call back");

	f.call_tool("redo", "{}")!!.free();
	test::@check(f.app.doc.pins.len() > 0, "and redo put it back");

	Object*? cleared = f.call_tool("paint_weights", `{"dot":"knee","reset":true}`);
	if (catch cleared)
	{
		test::@check(false, "reset answers");
		return;
	}
	defer cleared.free();
	test::@check((cleared.get_bool("reset") ?? false) && f.app.doc.pins.len() == 0,
		"reset took every correction off");
	test::@check(!f.app.weights_held(f.app.doc.dots[1].id), "reset left the knee's weights held");
}

<*
 A refusal says which value was wrong and what would have been right.

 The J6 rule, and it matters more here than for a read tool: an agent that
 cannot tell "the weight was out of range" from "that dot is not on this rig"
 retries the same call. A `share`, which meant a whole row before weights were
 per joint, is refused with what to pass instead.
*>
fn void paint_weights_refuses_with_a_sentence() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("paint_weights", `{"dot":"nosuchdot","weight":0}`, "nosuchdot"),
		"an unknown dot is named back");
	test::@check(f.refuses_tool("paint_weights", `{"dot":"knee","weight":4}`, "between 0 and 1"),
		"a weight out of range says what the range is");
	test::@check(f.refuses_tool("paint_weights", `{"dot":"knee"}`, "reset"),
		"a missing weight points at the other thing the tool can do");
	test::@check(f.refuses_tool("paint_weights", `{"dot":"knee","share":0.5}`, "weight"),
		"a share is not refused in favour of a weight");
}

<*
 A selection matching nothing is an answer, not an error.

 It is the rig saying the overlap being aimed at is not there — and a caller told
 that in a sentence goes and looks, where one handed a fault retries.
*>
fn void a_selection_matching_nothing_is_reported() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Nothing holds a share above 1, so this matches no vertex anywhere.
	Object*? nothing = f.call_tool("paint_weights", `{"dot":"knee","weight":0,"at_least":1.5}`);
	if (catch nothing)
	{
		test::@check(false, "an empty selection is answered rather than refused");
		return;
	}
	defer nothing.free();

	test::@check((nothing.get_int("selected") ?? -1) == 0, "it reports selecting nothing");
	test::@check((nothing.get_string("note") ?? "").contains("get_weights"),
		"and points at the tool that lists what does share vertices");
}

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
// A body of the rig's own
//
// A pack with no body plays but can never be *fitted*, because `AnimPack.preset`
// normalises its joints against the body's bounding box and has none to use. That
// one empty argument was the whole of what the offline pack builder could do and
// the wire could not, and these are the two halves of closing it: generating a
// body around a rig, and writing one into a pack.

fn void a_generated_body_keeps_the_rig_it_was_built_around() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	sz dots_before = f.app.doc.dots.len();

	Object*? built = f.call_tool("build_body", `{"thickness":0.05}`);
	if (catch built)
	{
		test::@check(false, "build_body answers on a rig with three connected dots");
		return;
	}
	defer built.free();

	test::@check((built.get_int("vertices") ?? 0) > 0 && (built.get_int("triangles") ?? 0) > 0,
		"a body arrives with a surface on it");
	test::@check(f.app.doc.dots.len() == dots_before,
		"and the rig it was built around is still there — unlike load_mesh, which takes the document with it");

	// The property the whole design rests on: a body built *around* the dots
	// cannot leave one outside itself, which is what makes discarding the
	// document unnecessary here and necessary everywhere else.
	rig::Bounds box = f.app.geometry.bounds();
	bool inside = true;
	foreach (dot : f.app.doc.dots.array_view())
	{
		Vec3 at = dot.position;
		inside = inside
			&& at.x >= box.min.x - 0.001f && at.x <= box.max.x + 0.001f
			&& at.y >= box.min.y - 0.001f && at.y <= box.max.y + 0.001f
			&& at.z >= box.min.z - 0.001f && at.z <= box.max.z + 0.001f;
	}
	test::@check(inside, "every dot is inside the body that was built around it");

	// Weights are derived and the mesh under them changed, so the binder has to
	// have answered again. A stale binding would be sized to the cube.
	Object*? weights = f.call_tool("get_weights", `{}`);
	if (catch weights)
	{
		test::@check(false, "the weights rebind onto the new body");
		return;
	}
	defer weights.free();
	test::@check((weights.get_int("vertices") ?? 0) == f.app.geometry.positions.len,
		"and they were measured against the body, not the mesh it replaced");
}

fn void build_body_names_what_it_will_not_shape() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("build_body", `{"joints":[{"joint":"elbow"}]}`, "elbow", "not a dot on this rig"),
		"a joint that is not on the rig is named, rather than shaped into nothing");

	test::@check(f.refuses_tool("build_body", `{"thickness":40}`, "thickness", "fraction"),
		"a thickness that would swallow the rig says what the number means");

	test::@check(f.refuses_tool("build_body", `{"joints":[{"joint":"knee","ball":-1}]}`, "ball", "negative"),
		"a negative measure is refused rather than clamped");
}

fn void build_body_refuses_a_rig_whose_shells_are_pinned() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? pinned = f.call_tool("edit_rig", `{"ops":[{"op":"attach","shell":0,"joint":"knee"}]}`);
	if (catch pinned)
	{
		test::@check(false, "the fixture's cube has a shell to pin");
		return;
	}
	pinned.free();

	if (f.app.doc.attachments.len() == 0)
	{
		test::@check(false, "the attach op put a pin in the document to refuse over");
		return;
	}

	// Refused rather than swept: a pin is document state with no undo behind a
	// mesh swap, so losing one silently is worse than being asked to detach.
	test::@check(f.refuses_tool("build_body", `{}`, "pinned to dots", "Detach them with edit_rig"),
		"a rig with pinned shells is told to detach them first");
}

fn void an_empty_document_has_nothing_to_build_a_body_around() @test
{
	Fixture fixture;
	fixture.open_bare();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("build_body", `{}`, "no dots", "apply_plan"),
		"a body needs a rig to be built around, and the refusal says how to get one");
}

<*
 A pack saved with a body can be fitted onto a fresh model.

 The check that matters is not that a mesh went into the file — it is that the
 pack comes back off disk as something `apply_plan` can place, which is the whole
 difference between a clip file and a body plan.
*>
fn void a_pack_saved_with_a_body_is_a_body_plan() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Kit","plan":"kit","body":"dummy"}`);
	if (catch saved)
	{
		test::@check(false, "a pack may be saved with a generated body");
		return;
	}
	defer saved.free();

	// Read off the file the writer just re-read, not off the argument: a body
	// that did not survive the round trip would otherwise report as present.
	test::@check((saved.get_int("vertices") ?? 0) > 0 && (saved.get_bool("body_plan") ?? false),
		"the pack comes back off disk carrying a body");

	Object*? fitted = f.call_tool("apply_plan", `{"plan":"Kit"}`);
	if (catch fitted)
	{
		test::@check(false, "a pack with a body can be fitted as a plan");
		return;
	}
	defer fitted.free();
	test::@check((fitted.get_int("dots") ?? 0) == 3,
		"and fitting it places the rig it was written from");
}

fn void a_pack_that_declares_a_plan_and_carries_no_body_says_so() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Bodyless","plan":"kit"}`);
	if (catch saved)
	{
		test::@check(false, "a pack with no body is still a legal save");
		return;
	}
	defer saved.free();

	// Said rather than refused: a clip file written for a plan the library
	// already has a body for is the case where this is exactly right.
	test::@check((saved.get_bool("body_plan") ?? true) == false
		&& (saved.get_string("note") ?? "").contains("can never fit one"),
		"a plan declared with no body is written, and answered with what it cannot do");
}

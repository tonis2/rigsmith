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
// get_weights / show_weights

<*
 Ownership is exclusive and total: every vertex belongs to exactly one dot.

 The strongest claim the survey makes, and the one that catches a loop counting
 twice or skipping. Asserted as a sum against the vertex count rather than per
 dot, because no single dot's share is a number this test could know.
*>
fn void get_weights_accounts_for_every_vertex() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? weights = f.call_tool("get_weights", `{}`);
	if (catch weights)
	{
		test::@check(false, "get_weights answers");
		return;
	}
	defer weights.free();

	Object*? dots = weights.get("dots");
	if (catch dots)
	{
		test::@check(false, "get_weights carries a dot table");
		return;
	}
	long vertices = weights.get_int("vertices") ?? -1;
	if (vertices < 0)
	{
		test::@check(false, "get_weights carries a vertex count");
		return;
	}

	long owned = 0;
	bool reaches_what_it_owns = true;
	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* dot = dots.get_at(i);
		long owns = dot.get_int("owns") ?? -1;
		long reaches = dot.get_int("reaches") ?? -1;
		if (owns < 0 || reaches < owns) reaches_what_it_owns = false;
		owned += owns;
	}

	test::@check(dots.get_len() == 4, "get_weights reports one row per dot, unnamed ones included");
	test::@check(owned == vertices, "every vertex is owned by exactly one dot");
	test::@check(reaches_what_it_owns, "and no dot owns mass it does not reach");

	// The stranded count rides along, and it is the answer to a different
	// question: ownership is exclusive and total by construction — a vertex has
	// *some* nearest bone — while this says how far away that bone actually is.
	// It is the only way left to ask, so a survey that dropped the field would
	// take the diagnostic with it.
	long stranded = weights.get_int("unclaimed") ?? -1;
	test::@check(stranded >= 0, "get_weights still carries the unclaimed count");
	test::@check(stranded <= vertices, "and it cannot strand more than the mesh has, %d of %d", stranded, vertices);
}

<*
 The surveyed half adds up against the table: reaches = owns + what it shares.

 An exact identity, not a bound. A vertex the dot reaches is either its own or
 someone else's, and the shared list groups the second kind by owner — so a
 survey that double-counted, dropped a neighbour or floored two rows differently
 breaks this and nothing else here would notice.
*>
fn void a_surveyed_dot_adds_up() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? weights = f.call_tool("get_weights", `{"dot":"knee"}`);
	if (catch weights)
	{
		test::@check(false, "get_weights surveys a named dot");
		return;
	}
	defer weights.free();

	Object*? shared = weights.get("shared");
	if (catch shared)
	{
		test::@check(false, "a surveyed dot carries a list of what it shares");
		return;
	}
	String named = weights.get_string("dot") ?? "";
	long owns = weights.get_int("owns") ?? -1;
	long reaches = weights.get_int("reaches") ?? -1;
	if (named.len == 0 || owns < 0 || reaches < 0)
	{
		test::@check(false, "a surveyed dot carries its name, owns and reaches");
		return;
	}

	long elsewhere = 0;
	bool names_itself = false;
	for (sz i = 0; i < shared.get_len(); i++)
	{
		Object* row = shared.get_at(i);
		elsewhere += row.get_int("vertices") ?? 0;
		if ((row.get_string("name") ?? "") == "knee") names_itself = true;
	}

	test::@check(named == "knee", "the survey names the dot it was pointed at");
	test::@check(reaches == owns + elsewhere, "and reaches exactly what it owns plus what it shares");
	test::@check(!names_itself, "a dot is never its own neighbour");

	// The fixture's own arrangement, and worth naming: every vertex of the cube is
	// a corner, so the middle of a three-dot chain is nearer to nothing and owns
	// none of it — while still pulling hard enough on its neighbours' mass to
	// matter. Owning nothing and reaching plenty is the shape of a joint that
	// smears the mesh without holding any of it, which is what these two numbers
	// are separate in order to show.
	test::@check(owns == 0, "a dot can own nothing");
	test::@check(reaches > 0, "and still reach into what its neighbours own");
}

<*
 `bone_<id>` is addressable here, unlike in a clip.

 The distinction is the point: a clip matches the name a dot carries, so an
 unnamed dot cannot be animated — but it is bound like every other, and a survey
 that could not reach it would be blind to whatever it is holding.
*>
fn void a_weight_survey_addresses_an_unnamed_dot() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? skeleton = f.call_tool("get_skeleton", `{}`);
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers");
		return;
	}
	defer skeleton.free();

	String address = "";
	Object*? dots = skeleton.get("dots");
	if (try dots)
	{
		for (sz i = 0; i < dots.get_len(); i++)
		{
			String name = dots.get_at(i).get_string("name") ?? "";
			if (name.len > 5 && name[:5] == "bone_") address = name;
		}
	}
	if (address.len == 0)
	{
		test::@check(false, "SKIPPED — the fixture rig has no unnamed dot");
		return;
	}

	String arguments = string::format(mem, `{"dot":"%s"}`, address);
	defer alloc::free(mem, arguments);

	Object*? weights = f.call_tool("get_weights", arguments);
	if (catch weights)
	{
		test::@check(false, "get_weights surveys an unnamed dot by bone_<id>");
		return;
	}
	defer weights.free();

	test::@check((weights.get_string("dot") ?? "") == address, "a survey reaches an unnamed dot by bone_<id>");
}

fn void a_weight_survey_says_which_dots_it_has() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(
		f.refuses_tool("get_weights", `{"dot":"tentacle"}`, "tentacle", "hips", "knee"),
		"a dot no rig carries is refused with the ones it does");
}

fn void show_weights_puts_a_named_view_on_the_screen() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? shown = f.call_tool("show_weights", `{"mode":"territory"}`);
	if (catch shown)
	{
		test::@check(false, "show_weights answers");
		return;
	}
	defer shown.free();
	test::@check((shown.get_string("showing") ?? "") == "territory", "show_weights turns the named view on");
	test::@check((shown.get_string("painting") ?? "").len > 0, "and says what a person looking at it is seeing");

	// Named rather than toggled: asking twice for the same view leaves it on. The
	// F key would have turned it off here, which is right for a key and wrong for
	// a caller that was told which view to show.
	Object*? again = f.call_tool("show_weights", `{"mode":"territory"}`);
	if (catch again)
	{
		test::@check(false, "show_weights answers a second time");
		return;
	}
	defer again.free();
	test::@check((again.get_string("showing") ?? "") == "territory", "and asking for it again leaves it on");

	Object*? falloff = f.call_tool("show_weights", `{"mode":"falloff","dot":"knee"}`);
	if (catch falloff)
	{
		test::@check(false, "show_weights ramps from a dot");
		return;
	}
	defer falloff.free();
	test::@check((falloff.get_string("dot") ?? "") == "knee", "the falloff view reports the dot it ramps from");

	Object*? off = f.call_tool("show_weights", `{"mode":"off"}`);
	if (catch off)
	{
		test::@check(false, "show_weights turns off");
		return;
	}
	defer off.free();
	test::@check((off.get_string("showing") ?? "") == "off", "and off takes the view away again");
}

<*
 show_weights flips the Unused overlay on its own, leaving the view as it is,
 and says so; get_weights counts the vertices it would mark.
*>
fn void show_weights_marks_unused_vertices_beside_the_view() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? shown = f.call_tool("show_weights", `{"unused":true}`);
	if (catch shown)
	{
		test::@check(false, "show_weights answers unused alone");
		return;
	}
	defer shown.free();
	test::@check(f.app.show_unused, "show_weights {unused:true} did not turn the overlay on");
	test::@check(f.app.tint_mode == OFF, "and switched a view on with it");
	test::@check((shown.get_bool("unused") ?? false) && (shown.get_string("unused_marks") ?? "").len > 0,
		"and did not say what the magenta means");

	Object*? weighed = f.call_tool("get_weights", `{}`);
	if (catch weighed)
	{
		test::@check(false, "get_weights answers");
		return;
	}
	defer weighed.free();
	test::@check((weighed.get_int("unused") ?? -1) == 0, "get_weights does not count the unused vertices");
}

fn void show_weights_refuses_a_view_it_does_not_have() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(
		f.refuses_tool("show_weights", `{"mode":"heatmap"}`, "heatmap", "territory", "falloff", "off"),
		"a view that does not exist is refused with the ones that do");
	test::@check(
		f.refuses_tool("show_weights", `{}`, "mode", "territory"),
		"and a call with no mode says which field it wanted");
}

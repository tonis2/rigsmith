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
// measure_clip localization
//
// The aggregate numbers say a clip is wrong; the issues say where (animation_plan.md,
// MCP5). Each fixture drives one fault and asserts it comes back named to a joint
// and a phase, and that a clean clip names none.

// The first issue of a given kind, or null when the answer names none.
fn Object* find_issue(Object* metrics, String kind)
{
	Object*? issues = metrics.get("issues");
	if (catch issues) return null;
	for (sz i = 0; i < issues.get_len(); i++)
	{
		Object* it = issues.get_at(i);
		String? k = it.get_string("kind");
		if (catch k) continue;
		if (k == kind) return it;
	}
	return null;
}

// A clip whose root sways out and back while the foot is meant to be down the
// whole cycle — a foot that skates.
const String SKATING_CLIP = `{"name":"step","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,0,0]}]},{"time":0.5,"joints":[{"name":"hips","move":[0.2,0,0]}]},{"time":1.0,"joints":[{"name":"hips","move":[0,0,0]}]}],"ground":{"feet":[{"joint":"foot","down":0.0,"up":1.0}]}}`;

<*
 A skating foot is named to the foot and a phase, not just summed into foot_slide.
*>
fn void measure_clip_localizes_a_foot_slide() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", SKATING_CLIP);
	if (catch authored) { test::@check(false, "the skating clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"step"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* slide = find_issue(m, "foot_slide");
	test::@check(slide != null, "the slide is reported as an issue");
	if (slide == null) return;
	test::@check(slide.get_string("joint")!! == "foot", "named to the foot that slid");
	test::@check((slide.get_float("magnitude") ?? 0.0) > 0.01, "with the magnitude that cleared tolerance");
	double phase = slide.get_float("phase") ?? -1.0;
	test::@check(phase >= 0.0 && phase <= 1.0, "and a phase in the cycle");
}

<*
 A joint sunk through the floor is named to the deepest joint and where.
*>
fn void measure_clip_localizes_floor_penetration() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"sink","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,-0.3,0]}]}]}`);
	if (catch authored) { test::@check(false, "the sinking clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"sink"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* sunk = find_issue(m, "floor_penetration");
	test::@check(sunk != null, "the penetration is reported as an issue");
	if (sunk == null) return;
	test::@check(sunk.get_string("joint")!! == "foot", "named to the deepest joint");
	test::@check((sunk.get_float("magnitude") ?? 0.0) > 0.2, "with a magnitude of how deep it got");
}

<*
 An animated rotation past a joint's limit is named to the joint and the axis.
*>
fn void measure_clip_localizes_a_limit_saturation() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Lock every bone-local axis of the knee: any turn now runs past the table.
	uint knee = f.app.dot_named("knee").id;
	crig::JointRotationLimits lim = crig::unconstrained_rotation(knee);
	lim.constrained = true;
	for (usz i = 0; i < 3; i++)
	{
		lim.axes[i].allowed = false;
		lim.axes[i].locked = 0.0f;
	}
	test::@check(f.app.doc.set_rotation_limits(knee, lim), "the knee's limit table is set");

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"strain","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}]}`);
	if (catch authored) { test::@check(false, "the straining clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"strain"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* hit = find_issue(m, "limit_saturation");
	test::@check(hit != null, "the joint fighting its limit is reported");
	if (hit == null) return;
	test::@check(hit.get_string("joint")!! == "knee", "named to the joint");
	test::@check(@ok(hit.get_string("axis")), "and the bone-local axis it was hit on");
	test::@check((hit.get_float("magnitude") ?? 0.0) > 0.02, "with the radians past the limit");
}

<*
 A loop that reverses direction at the seam is named as a velocity break there.
*>
fn void measure_clip_localizes_a_loop_seam() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// A triangle over the cycle: the knee swings up then down, so its direction
	// flips at the seam — a velocity discontinuity the finite differences catch.
	Object*? authored = f.call_tool("apply_clip",
		`{"name":"hitch","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":0.5,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}]}`);
	if (catch authored) { test::@check(false, "the hitching clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"hitch"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* seam = find_issue(m, "loop_velocity");
	test::@check(seam != null, "the loop's velocity break is reported");
	if (seam == null) return;
	test::@check(seam.get_string("joint")!! == "foot", "named to the joint that swings");
	test::@check((seam.get_float("phase") ?? -1.0) == 0.0, "at the seam");
}

<*
 A smooth swing whose seam falls where it turns round — its speed changing
 fastest — is motion, not a break: the seam check allows for the acceleration
 either side of it.
*>
fn void a_smooth_turn_at_the_seam_is_not_a_velocity_break() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"swing","duration":1.0,"loop":true,"blend":"smooth","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.8}}]},{"time":0.25,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.0}}]},{"time":0.5,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":-0.8}}]},{"time":0.75,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.0}}]}]}`);
	if (catch authored) { test::@check(false, "the swinging clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"swing","samples":64}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();
	test::@check(find_issue(m, "loop_velocity") == null, "a smooth turn at the seam was reported as a velocity break");
}

<*
 A clip with none of the four faults reports an empty issues list.
*>
fn void measure_clip_finds_nothing_in_a_clean_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Non-looping (no seam), no ground (no feet to skate), no limits set, a gentle
	// turn that lifts the foot rather than sinking it.
	Object*? authored = f.call_tool("apply_clip",
		`{"name":"calm","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":1.0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.3}}]}]}`);
	if (catch authored) { test::@check(false, "the calm clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"calm"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	test::@check(m.get("issues")!!.get_len() == 0, "a clean clip names no issue");
}

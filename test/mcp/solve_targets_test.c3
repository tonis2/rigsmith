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
// solve_targets
//
// The IK the interactive poser bends a pinned foot back to the floor with,
// exposed for authoring (animation_plan.md, MCP1): a joint and a point in, the
// pose that reaches it out, as a keyframe apply_clip bakes. The fixture's one
// chain is foot -> knee -> hips, a metre of straight leg from the root at
// (0,1,0), so a point within a metre of there is reachable and one far outside
// is not — which is the whole of what these checks turn on.

<*
 A reachable point is reached, and the answer is a keyframe that turned the chain.
*>
fn void solve_targets_reaches_a_point() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.5,0.7,0]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers");
		return;
	}
	defer solved.free();

	test::@check(solved.get_bool("reached")!! == true, "a point within a metre of the hip is reached");

	Object* targets = solved.get("targets")!!;
	test::@check(targets.get_len() == 1, "one target, one result");
	test::@check((targets.get_at(0).get_float("residual") ?? 1.0) < 0.05,
		"and the foot ended up on the point");

	Object* joints = solved.get("keyframe")!!.get("joints")!!;
	test::@check(joints.get_len() > 0, "the reach turned the joints above the foot");
	test::@check(@ok(joints.get_at(0).get_string("name")), "each keyed joint is named");
	test::@check(@ok(joints.get_at(0).get("rotation")!!.get_float("w")),
		"and carries a quaternion apply_clip can take");
}

<*
 A point the limb cannot touch is not reached, and the residual is the shortfall.
*>
fn void solve_targets_reports_an_unreachable_point() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[5,5,5]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers for an unreachable point");
		return;
	}
	defer solved.free();

	test::@check(solved.get_bool("reached")!! == false, "a metre-long leg cannot touch it");
	Object* first = solved.get("targets")!!.get_at(0);
	test::@check(first.get_bool("reached")!! == false, "the target says so");
	test::@check((first.get_float("residual") ?? 0.0) > 1.0, "and the residual is how far it fell short");
}

<*
 A joint with no run of ancestors to bend cannot be placed, and says why.
*>
fn void solve_targets_refuses_a_joint_with_no_run() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"hips","position":[0.3,0.9,0]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers even when a target cannot be placed");
		return;
	}
	defer solved.free();

	Object* first = solved.get("targets")!!.get_at(0);
	test::@check(first.get_bool("reached")!! == false, "the hips are a root — nothing above them bends");
	test::@check((first.get_string("note") ?? "").contains("run"), "and the note says why");
}

<*
 Holding an orientation turns the effector itself, so the keyframe keys it.
*>
fn void solve_targets_holds_an_orientation() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// A quarter turn about X as the foot's world orientation.
	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.5,0.7,0],"orientation":{"x":0.3826834,"y":0,"z":0,"w":0.9238795}}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers with an orientation");
		return;
	}
	defer solved.free();

	Object* joints = solved.get("keyframe")!!.get("joints")!!;
	bool foot_keyed = false;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		if ((joints.get_at(i).get_string("name") ?? "") == "foot") foot_keyed = true;
	}
	test::@check(foot_keyed, "holding an orientation turns the effector, so it is in the keyframe");
}

<*
 The keyframe solve_targets answers with is exactly what apply_clip takes.

 The claim the whole tool rests on — solve here, bake there — checked by feeding
 one straight into the other rather than by inspecting the shape. Rebuilt from the
 parsed answer because no serialiser is at hand; the rotations are the solved ones.
*>
fn void solve_targets_keyframe_feeds_apply_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.5,0.7,0]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers");
		return;
	}
	defer solved.free();

	Object* joints = solved.get("keyframe")!!.get("joints")!!;
	test::@check(joints.get_len() > 0, "there is a keyframe to bake");

	DString kf = dstring::new(mem);
	defer kf.free();
	kf.append_string(`{"name":"reach","duration":1.0,"keyframes":[{"time":0,"joints":[`);
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* e = joints.get_at(i);
		Object* r = e.get("rotation")!!;
		if (i > 0) kf.append_char(',');
		kf.appendf(`{"name":"%s","rotation":{"x":%.9g,"y":%.9g,"z":%.9g,"w":%.9g}}`,
			e.get_string("name")!!, r.get_float("x")!!, r.get_float("y")!!, r.get_float("z")!!, r.get_float("w")!!);
	}
	kf.append_string(`]}]}`);

	Object*? applied = f.call_tool("apply_clip", kf.str_view());
	if (catch applied)
	{
		test::@check(false, "the solved keyframe bakes through apply_clip unchanged");
		return;
	}
	defer applied.free();
	test::@check(true, "solve here, apply_clip bakes there");
}

<*
 An unknown joint is refused by name, not solved for silently.
*>
fn void solve_targets_refuses_an_unknown_joint() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"solve_targets","arguments":{"targets":[{"joint":"elbow","position":[0,0,0]}]}}}`);
	if (catch root)
	{
		test::@check(false, "an unknown-joint request answers");
		return;
	}
	defer root.free();
	test::@check(error_message_contains(root, "not a dot on this rig"),
		"an unknown joint is refused by name");
}

// Solve the foot to a bent target with the given pole, bake the keyframe, and
// read the knee's world Z after — which way the knee bowed.
fn double? knee_z_for_pole(Fixture* f, String pole)
{
	String args = string::format(mem,
		`{"targets":[{"joint":"foot","position":[0.15,0.55,0],"pole":%s}]}`, pole);
	defer alloc::free(mem, args);
	Object* solved = f.call_tool("solve_targets", args)!;
	defer solved.free();

	// The solved keyframe, handed back to apply_clip as a one-frame clip.
	Object* joints = solved.get("keyframe")!.get("joints")!;
	DString kf = dstring::new(mem);
	defer kf.free();
	kf.append_string(`{"name":"pole","duration":1.0,"keyframes":[{"time":0,"joints":[`);
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* e = joints.get_at(i);
		Object* r = e.get("rotation")!;
		if (i > 0) kf.append_char(',');
		kf.appendf(`{"name":"%s","rotation":{"x":%.9g,"y":%.9g,"z":%.9g,"w":%.9g}}`,
			e.get_string("name")!, r.get_float("x")!, r.get_float("y")!, r.get_float("z")!, r.get_float("w")!);
	}
	kf.append_string(`]}]}`);
	Object* applied = f.call_tool("apply_clip", kf.str_view())!;
	applied.free();

	Object* pose = f.call_tool("get_pose", `{"clip":"pole","t":0}`)!;
	defer pose.free();
	Object* pjoints = pose.get("joints")!;
	for (sz i = 0; i < pjoints.get_len(); i++)
	{
		Object* j = pjoints.get_at(i);
		if (j.get_string("name")! == "knee") return j.get("position")!.get_float_at(2)!;
	}
	return NOT_FOUND~;
}

<*
 A pole settles which way the knee bends: one pole bows it toward +Z, the
 opposite pole toward -Z, and the effector still reaches its point.
*>
fn void solve_targets_pole_aims_the_bend() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	double? front = knee_z_for_pole(f, "[0,0.5,5]");
	double? back = knee_z_for_pole(f, "[0,0.5,-5]");
	if (catch front) { test::@check(false, "the +Z pole solve did not complete"); return; }
	if (catch back) { test::@check(false, "the -Z pole solve did not complete"); return; }

	test::@check(front > 0.02, "a +Z pole should bow the knee toward +Z (z=%.4f)", front);
	test::@check(back < -0.02, "a -Z pole should bow the knee toward -Z (z=%.4f)", back);
	test::@check(front > back + 0.1, "the pole flips the bend from one side to the other");
}

<*
 A pole reports whether it was aimed: yes on a two-bone limb, no on a limb with
 one bend, where there is no elbow or knee to point.
*>
fn void solve_targets_pole_reports_when_it_cannot_aim() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? two = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.15,0.55,0],"pole":[0,0.5,5]}]}`);
	if (catch two) { test::@check(false, "the two-bone solve answers"); return; }
	defer two.free();
	test::@check(two.get("targets")!!.get_at(0).get_bool("pole_aimed")!! == true,
		"a foot's two-bone limb aims the pole");

	// The knee has only one bend above it (the hips), so there is no joint to aim.
	Object*? one = f.call_tool("solve_targets",
		`{"targets":[{"joint":"knee","position":[0.2,0.55,0],"pole":[0,0.5,5]}]}`);
	if (catch one) { test::@check(false, "the one-bone solve answers"); return; }
	defer one.free();
	test::@check(one.get("targets")!!.get_at(0).get_bool("pole_aimed")!! == false,
		"a one-bone limb reports the pole was not aimed");
}

<*
 A pole the limb reaches straight through is ignored, and the note says why it
 was — not that the limb had too few bends.
*>
fn void solve_targets_pole_notes_a_straight_limb() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The foot is already at its rest place, so the leg stays straight down its
	// axis: a real two-bone limb, but with no bend off the line for the pole to aim.
	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0,0,0],"pole":[0,0.5,5]}]}`);
	if (catch solved) { test::@check(false, "the straight solve answers"); return; }
	defer solved.free();

	Object* first = solved.get("targets")!!.get_at(0);
	test::@check(first.get_bool("pole_aimed")!! == false, "a straight limb aims no pole");
	test::@check((first.get_string("pole_note") ?? "").contains("straight"),
		"and the note names the straight limb, not a missing bend");
}

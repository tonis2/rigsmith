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
// patch_clip
//
// The additive counterpart to apply_clip (animation_plan.md, MCP3): a few joints
// offset over a range, every other track left as it was. The fixture's knee is the
// joint offset; hips is the unrelated track that must survive it.

// A clip driving the knee (identity throughout) and sliding the hips, so a knee
// patch has an unrelated hips track to leave alone and its own keys to offset.
const String PATCH_CLIP = `{"name":"c","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}},{"name":"hips","move":[0,0,0]}]},{"time":0.5,"joints":[{"name":"hips","move":[0.1,0,0]}]},{"time":1.0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}},{"name":"hips","move":[0,0,0]}]}]}`;

// A joint's world rotation quaternion out of a get_pose answer, by name.
fn bool joint_quat(Object* pose, String name, double[] out)
{
	Object*? joints = pose.get("joints");
	if (catch joints) return false;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* j = joints.get_at(i);
		String? held = j.get_string("name");
		if (catch held) continue;
		if (held != name) continue;
		Object*? r = j.get("rotation");
		if (catch r) return false;
		for (usz k = 0; k < 4; k++) out[k] = r.get_float_at((sz)k) ?? 0.0;
		return true;
	}
	return false;
}

// A joint's world position out of a get_pose answer, by name.
fn bool joint_pos(Object* pose, String name, double[] out)
{
	Object*? joints = pose.get("joints");
	if (catch joints) return false;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* j = joints.get_at(i);
		String? held = j.get_string("name");
		if (catch held) continue;
		if (held != name) continue;
		Object*? p = j.get("position");
		if (catch p) return false;
		for (usz k = 0; k < 3; k++) out[k] = p.get_float_at((sz)k) ?? 0.0;
		return true;
	}
	return false;
}

// How aligned a joint's rotation is between two poses: 1 is unchanged, less is
// turned. The absolute dot, since q and -q are one rotation.
fn double rotation_alignment(Object* before, Object* after, String name)
{
	double[4] a;
	double[4] b;
	if (!joint_quat(before, name, a[..]) || !joint_quat(after, name, b[..])) return -2.0;
	return math::abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]);
}

<*
 A whole-clip rotation offset turns the joint at every one of its keys, and lands.
*>
fn void patch_clip_offsets_a_joint() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", PATCH_CLIP);
	if (catch authored) { test::@check(false, "the clip authors"); return; }
	authored.free();

	Object*? before = f.call_tool("get_pose", `{"clip":"c","t":0.5}`);
	if (catch before) { test::@check(false, "get_pose reads the clip"); return; }
	defer before.free();

	Object*? patched = f.call_tool("patch_clip",
		`{"clip":"c","joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6}}]}`);
	if (catch patched) { test::@check(false, "patch_clip answers"); return; }
	defer patched.free();

	test::@check((patched.get("joints")!!.get_at(0).get_int("rotation_keys") ?? 0) >= 2,
		"both of the knee's keys were offset");
	test::@check((patched.get_int("keys_written") ?? 0) > 0, "and keys were written");
	test::@check(@ok(patched.get("landed")!!.get_string("clip")), "and it landed in the pack");
	test::@check(patched.get("range")!!.get_bool("whole")!! == true, "no range given is the whole clip");

	Object*? after = f.call_tool("get_pose", `{"clip":"c","t":0.5}`);
	if (catch after) { test::@check(false, "get_pose reads the patched clip"); return; }
	defer after.free();

	test::@check(rotation_alignment(before, after, "knee") < 0.999,
		"the knee is turned from where it was");
}

<*
 A sub-range holds the offset inside it and leaves the clip untouched outside —
 and never touches a joint it did not name.
*>
fn void patch_clip_bounds_a_sub_range() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", PATCH_CLIP);
	if (catch authored) { test::@check(false, "the clip authors"); return; }
	authored.free();

	Object*? at_edge = f.call_tool("get_pose", `{"clip":"c","t":0}`);
	Object*? at_mid = f.call_tool("get_pose", `{"clip":"c","t":0.5}`);
	if (catch at_edge) { test::@check(false, "get_pose reads t=0"); return; }
	if (catch at_mid) { test::@check(false, "get_pose reads t=0.5"); return; }
	defer at_edge.free();
	defer at_mid.free();

	double[3] hips_before;
	joint_pos(at_mid, "hips", hips_before[..]);

	Object*? patched = f.call_tool("patch_clip",
		`{"clip":"c","range":{"phase":[0.3,0.7]},"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6}}]}`);
	if (catch patched) { test::@check(false, "patch_clip answers"); return; }
	defer patched.free();

	test::@check(patched.get("range")!!.get_bool("whole")!! == false, "a sub-range is not the whole clip");

	Object*? edge_after = f.call_tool("get_pose", `{"clip":"c","t":0}`);
	Object*? mid_after = f.call_tool("get_pose", `{"clip":"c","t":0.5}`);
	if (catch edge_after) { test::@check(false, "get_pose reads t=0 after"); return; }
	if (catch mid_after) { test::@check(false, "get_pose reads t=0.5 after"); return; }
	defer edge_after.free();
	defer mid_after.free();

	test::@check(rotation_alignment(at_edge, edge_after, "knee") > 0.9999,
		"outside the range the knee is exactly where it was");
	test::@check(rotation_alignment(at_mid, mid_after, "knee") < 0.999,
		"inside the range the knee is turned");

	double[3] hips_after;
	joint_pos(mid_after, "hips", hips_after[..]);
	double drift = math::abs(hips_before[0] - hips_after[0])
		+ math::abs(hips_before[1] - hips_after[1])
		+ math::abs(hips_before[2] - hips_after[2]);
	test::@check(drift < 1e-6, "and the hips track it did not name never moved (%.9g)", drift);
}

<*
 world and local are different frames: under a rolled parent, the same offset
 lands the knee in two different places.
*>
fn void patch_clip_world_differs_from_local() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The hips rolled a quarter turn about Z, so the knee's parent frame is not the
	// model's — the one condition under which world and local part ways.
	String local_clip = `{"name":"cl","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":{"x":0,"y":0,"z":0.7071067811865476,"w":0.7071067811865476}},{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":1.0,"joints":[{"name":"hips","rotation":{"x":0,"y":0,"z":0.7071067811865476,"w":0.7071067811865476}},{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]}]}`;
	String world_clip = `{"name":"cw","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":{"x":0,"y":0,"z":0.7071067811865476,"w":0.7071067811865476}},{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":1.0,"joints":[{"name":"hips","rotation":{"x":0,"y":0,"z":0.7071067811865476,"w":0.7071067811865476}},{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]}]}`;

	Object*? a = f.call_tool("apply_clip", local_clip);
	Object*? b = f.call_tool("apply_clip", world_clip);
	if (catch a) { test::@check(false, "the local clip authors"); return; }
	if (catch b) { test::@check(false, "the world clip authors"); return; }
	a.free();
	b.free();

	Object*? pl = f.call_tool("patch_clip",
		`{"clip":"cl","joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6},"space":"local"}]}`);
	Object*? pw = f.call_tool("patch_clip",
		`{"clip":"cw","joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.6},"space":"world"}]}`);
	if (catch pl) { test::@check(false, "the local patch answers"); return; }
	if (catch pw) { test::@check(false, "the world patch answers"); return; }
	pl.free();
	pw.free();

	Object*? posed_local = f.call_tool("get_pose", `{"clip":"cl","t":0}`);
	Object*? posed_world = f.call_tool("get_pose", `{"clip":"cw","t":0}`);
	if (catch posed_local) { test::@check(false, "get_pose reads the local patch"); return; }
	if (catch posed_world) { test::@check(false, "get_pose reads the world patch"); return; }
	defer posed_local.free();
	defer posed_world.free();

	test::@check(rotation_alignment(posed_local, posed_world, "knee") < 0.999,
		"the same offset in world and local frames turns the knee two different ways");
}

<*
 The refusals name the value they reject and what would have been taken instead.
*>
fn void patch_clip_refuses_what_it_cannot_do() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", PATCH_CLIP);
	if (catch authored) { test::@check(false, "the clip authors"); return; }
	authored.free();

	test::@check(
		f.refuses_tool("patch_clip", `{"clip":"c","joints":[{"name":"knee"}]}`,
			"rotation", "move"),
		"a joint with no offset is refused");
	test::@check(
		f.refuses_tool("patch_clip",
			`{"clip":"c","joints":[{"name":"elbow","rotation":{"axis":[1,0,0],"angle":0.6}}]}`,
			"not a dot on this rig"),
		"an unknown joint is refused by name");
	test::@check(
		f.refuses_tool("patch_clip",
			`{"clip":"c","range":{"phase":[0,1],"time":[0,1]},"joints":[{"name":"knee","move":[0,0.1,0]}]}`,
			"not both"),
		"a range given as both phase and time is refused");
	test::@check(
		f.refuses_tool("patch_clip",
			`{"clip":"c","range":{"phase":[0.7,0.3]},"joints":[{"name":"knee","move":[0,0.1,0]}]}`,
			"start < end"),
		"a backwards range is refused");
}

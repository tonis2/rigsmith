<*
 What a clip keeps when a tool writes it again: the ground spec through a
 get_clip → apply_clip round trip, the layers through a second author_gait, and
 a layer's name through a set_layer replace that sends only new keys.

     `c3c test --test-noleak --test-filter crig_tests::mcp_roundtrip`
*>
module crig_tests::mcp_roundtrip;

import crig;
import crig_tests::mcp;
import std::collections::object;
import std::encoding::json;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

const String HUMANOID = "assets/animations/humanoid.glb";

fn crig::AnimTemplate* authored(mcp::Fixture* f, String name)
{
	crig::AnimRef ref = f.app.clip_named_in_authored(name);
	return ref.valid() ? f.app.clip(ref) : null;
}

fn bool tool_ok(mcp::Fixture* f, String tool, String arguments)
{
	String? text = f.call_tool_text(tool, arguments);
	if (catch text)
	{
		test::@check(false, "%s did not answer", tool);
		return false;
	}
	defer text.free(mem);
	Object*? parsed = json::parse(mem, text);
	if (catch parsed)
	{
		test::@check(false, "%s refused: %s", tool, text);
		return false;
	}
	parsed.free();
	return true;
}

<*
 get_clip writes the ground spec in apply_clip's shape, and apply_clip keeps a
 clip's own spec when the call leaves it out, so read → write back loses no
 floor solve; an explicit null clears it.

 Re-introduce: drop the `ground` member from `clip_json`, or the
 `ground_copy(mem, held.ground)` carry-over in `parse_clip`, and the clip
 written back is no longer grounded.
*>
fn void a_get_clip_round_trip_keeps_the_ground_spec() @test
{
	io::printn("get_clip → apply_clip keeps the clip's ground spec");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	if (!tool_ok(&f, "author_gait", `{"name":"Round","duration":1.0,"upper_body":false,"pin_feet":false}`)) return;
	crig::AnimTemplate* walked = authored(&f, "Round");
	test::@check(walked != null && walked.ground.solves(), "the gait has no ground spec to keep");
	if (walked == null) return;
	usz windows = walked.ground.feet.len;
	float down = walked.ground.feet[0].down;

	String? read = f.call_tool_text("get_clip", `{"clip":"Round"}`);
	if (catch read) { test::@check(false, "get_clip did not answer"); return; }
	defer read.free(mem);
	Object*? shape = json::parse(mem, read);
	if (catch shape) { test::@check(false, "get_clip refused: %s", read); return; }
	defer shape.free();
	test::@check(shape.has_key("ground"), "get_clip does not report the ground spec");

	// The answer handed straight back.
	if (!tool_ok(&f, "apply_clip", read)) return;
	crig::AnimTemplate* back = authored(&f, "Round");
	test::@check(back.ground.feet.len == windows && back.ground.feet[0].down == down,
		"the written-back clip has %d windows, not %d", back.ground.feet.len, windows);

	// Left out: kept. Null: cleared.
	if (!tool_ok(&f, "apply_clip", `{"name":"Round","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":[0,0,0]}]}]}`)) return;
	test::@check(authored(&f, "Round").ground.feet.len == windows, "apply_clip without ground dropped the spec");
	if (!tool_ok(&f, "apply_clip", `{"name":"Round","duration":1.0,"loop":true,"ground":null,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":[0,0,0]}]}]}`)) return;
	test::@check(!authored(&f, "Round").ground.solves(), "ground null did not clear the spec");
}

<*
 Running author_gait again over a clip keeps the layers laid over it, as
 apply_clip does, unless keep_layers is false.

 Re-introduce: remove the carry-over before `author_clip` in
 `AppState.author_gait`, and the second gait lands with no layers.
*>
fn void a_second_author_gait_keeps_the_layers() @test
{
	io::printn("author_gait over an existing clip keeps its layers");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	if (!tool_ok(&f, "author_gait", `{"name":"Again","duration":1.0,"pin_feet":false}`)) return;
	// The gait's own body layer is there from the start.
	test::@check(authored(&f, "Again").layers.len == 1 && authored(&f, "Again").layers[0].name == crig::GAIT_BODY_LAYER,
		"the gait has no body layer");
	if (!tool_ok(&f, "set_layer", `{"clip":"Again","layer":{"name":"Lean","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}}`)) return;
	test::@check(authored(&f, "Again").layers.len == 2, "the layer did not land");

	Object*? answer = f.call_tool("author_gait", `{"name":"Again","duration":1.2,"stride":0.4,"pin_feet":false}`);
	if (catch answer) { test::@check(false, "the second author_gait refused"); return; }
	defer answer.free();
	// The body layer written again, the person's layer kept over it.
	test::@check(authored(&f, "Again").layers.len == 2 && authored(&f, "Again").layers[0].name == crig::GAIT_BODY_LAYER
		&& authored(&f, "Again").layers[1].name == "Lean", "the second gait dropped the layer");
	test::@check((answer.get_float("kept_layers") ?? 0.0) == 1.0, "the answer does not say the layer was kept");

	if (!tool_ok(&f, "author_gait", `{"name":"Again","duration":1.0,"pin_feet":false,"keep_layers":false}`)) return;
	test::@check(authored(&f, "Again").layers.len == 1, "keep_layers false kept the layer");
}

<*
 A set_layer replace that sends new keyframes and no name inside the layer
 object keeps the layer's name, instead of being refused as an apply_clip
 with no name.

 Re-introduce: call `parse_clip` from `parse_layer` without the layer's name,
 and this replace is refused.
*>
fn void a_layer_replace_with_only_keys_keeps_its_name() @test
{
	io::printn("set_layer replace with only keyframes keeps the layer's name");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	if (!tool_ok(&f, "author_gait", `{"name":"Keys","duration":1.0,"pin_feet":false,"upper_body":false}`)) return;
	if (!tool_ok(&f, "set_layer", `{"clip":"Keys","layer":{"name":"Bend","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}}`)) return;
	if (!tool_ok(&f, "set_layer", `{"clip":"Keys","op":"replace","name":"Bend","layer":{"keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.2}}]}]}}`)) return;

	crig::AnimTemplate* clip = authored(&f, "Keys");
	test::@check(clip.layers.len == 1 && clip.layers[0].name == "Bend", "the replace renamed or lost the layer");
	float angle = clip.layers[0].keyframes[0].dots[0].angle;
	test::@check(angle > 0.19f && angle < 0.21f, "the new key did not land (angle %f)", angle);
}

fn uint dot_named(mcp::Fixture* f, String name)
{
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

<*
 A stale limit table on a finger is a fault of the rig: it is listed after the
 clip's own issues, the clip's keys still read clip_verdict usable, and its fix
 carries that one table onto its bone instead of re-planning every joint under
 the label limits_inverted.

 Re-introduce: put `LIMITS_STALE` back under `LIMITS_INVERTED` in
 `append_fixes`, or drop `ignore_rig` from the clip_verdict line, and this fails.
*>
fn void a_stale_finger_table_is_the_rigs_fault_and_mended_alone() @test
{
	io::printn("a stale finger table: clip_verdict usable, its own fix, nothing else touched");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	uint finger = dot_named(&f, "index_1_L");
	uint neck = dot_named(&f, "neck");
	test::@check(finger != 0 && neck != 0, "the humanoid has no index_1_L or neck");
	if (finger == 0 || neck == 0) return;
	// A table pinned to the rest axes: the finger's bone runs along X, so Y is a
	// quarter turn off it.
	crig::JointRotationLimits pinned = f.app.doc.rotation_limits_of(finger);
	pinned.constrained = true;
	pinned.has_saved_frame = true;
	pinned.saved_frame = { 0, 0, 0, 1 };
	test::@check(f.app.set_rotation_limits_recorded(finger, pinned), "the stale table did not land");
	f.app.undo_stack.commit();
	crig::JointRotationLimits neck_before = f.app.doc.rotation_limits_of(neck);

	if (!tool_ok(&f, "author_gait", `{"name":"Clean","duration":1.0,"pin_feet":false}`)) return;
	Object*? measured = f.call_tool("measure_clip", `{"clip":"Clean"}`);
	if (catch measured) { test::@check(false, "measure_clip refused"); return; }
	defer measured.free();
	test::@check((measured.get_string("verdict") ?? "") == "needs_work", "a rig fault should keep verdict needs_work");
	test::@check((measured.get_string("clip_verdict") ?? "") == "usable", "the clip's own keys should read usable");

	Object* issues = measured.get("issues")!!;
	usz last = (usz)issues.get_len() - 1;
	test::@check((issues.get_at((sz)last).get_string("kind") ?? "") == "limits_stale", "the rig's fault is not listed last");

	Object* fixes = measured.get("fixes")!!;
	String ops = "";
	for (sz i = 0; i < fixes.get_len(); i++)
	{
		String kind = fixes.get_at(i).get_string("issue") ?? "";
		test::@check(kind != "limits_inverted", "a stale table is offered the limits_inverted fix");
		if (kind != "limits_stale") continue;
		Object* op = fixes.get_at(i).get("args")!!.get("ops")!!.get_at(0);
		test::@check((op.get_string("op") ?? "") == "limits" && (op.get_string("joint") ?? "") == "index_1_L"
			&& (op.get_bool("bone_axes") ?? false), "the stale fix is not a limits bone_axes op on the finger");
		ops = "found";
	}
	test::@check(ops == "found", "no limits_stale fix is offered");

	// The fix as offered: the finger comes onto its bone, the neck is untouched.
	if (!tool_ok(&f, "edit_rig", `{"ops":[{"op":"limits","joint":"index_1_L","bone_axes":true}]}`)) return;
	test::@check(!f.app.doc.rotation_limits_of(finger).has_saved_frame
		|| f.app.doc.rotation_limits_of(finger).saved_frame.v != pinned.saved_frame.v, "the finger table was not carried");
	crig::JointRotationLimits neck_after = f.app.doc.rotation_limits_of(neck);
	test::@check(neck_after.constrained == neck_before.constrained && neck_after.axes[0].maximum == neck_before.axes[0].maximum,
		"mending the finger changed the neck");
}

<*
 A layer that moves the root up or down on a grounded clip is cancelled by the
 floor solve while a foot is down, and set_layer says so; a layer that does not
 touch the root gets no such note.

 Re-introduce: drop the `layers_lift_root` note from `layers_answer`, and the
 caller is left believing the bob it added plays.
*>
fn void a_root_bob_layer_on_a_grounded_clip_is_flagged() @test
{
	io::printn("set_layer notes that a root Y move on a grounded clip is cancelled");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	if (!tool_ok(&f, "author_gait", `{"name":"Bob","duration":1.0,"pin_feet":false}`)) return;
	Object*? lean = f.call_tool("set_layer", `{"clip":"Bob","layer":{"name":"Lean","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}}`);
	if (catch lean) { test::@check(false, "the lean layer was refused"); return; }
	defer lean.free();
	test::@check(!lean.has_key("note"), "a layer that leaves the root alone was given the root note");

	Object*? bob = f.call_tool("set_layer", `{"clip":"Bob","layer":{"name":"Bob","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,0.03,0]}]}]}}`);
	if (catch bob) { test::@check(false, "the bob layer was refused"); return; }
	defer bob.free();
	test::@check((bob.get_string("note") ?? "").contains("floor solve"), "a root Y layer on a grounded clip was not flagged");
}

<*
 duplicate_clip copies a clip with its layers and ground spec under a new name,
 and refuses a name already taken; merge_layers into bakes a copy and leaves the
 source layered.

 Re-introduce: build the copy without `clip_copy` (keys only), or let
 merge_layers into bake the source in place, and this fails.
*>
fn void a_clip_is_duplicated_and_merged_into_a_copy() @test
{
	io::printn("duplicate_clip keeps layers and ground; merge_layers into leaves the source layered");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	// Legs only, so the gait's own body layer does not join the count.
	if (!tool_ok(&f, "author_gait", `{"name":"Orig","duration":1.0,"pin_feet":false,"upper_body":false}`)) return;
	if (!tool_ok(&f, "set_layer", `{"clip":"Orig","layer":{"name":"Lean","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}}`)) return;

	if (!tool_ok(&f, "duplicate_clip", `{"clip":"Orig"}`)) return;
	crig::AnimTemplate* copy = authored(&f, "Orig copy");
	test::@check(copy != null, "the copy did not land as \"Orig copy\"");
	if (copy == null) return;
	test::@check(copy.layers.len == 1 && copy.ground.solves(), "the copy lost its layer or its ground spec");
	String? taken = f.call_tool_text("duplicate_clip", `{"clip":"Orig","name":"Orig copy"}`);
	if (try taken)
	{
		test::@check(!taken.contains(`"clip"`) || taken.contains("already has"), "a taken name was overwritten: %s", taken);
		taken.free(mem);
	}

	if (!tool_ok(&f, "merge_layers", `{"clip":"Orig","into":"Orig flat"}`)) return;
	test::@check(authored(&f, "Orig").layers.len == 1, "merge_layers into baked the source in place");
	crig::AnimTemplate* flat = authored(&f, "Orig flat");
	test::@check(flat != null && flat.layers.len == 0 && flat.ground.solves(), "the baked copy is missing, layered or ungrounded");
}

<*
 blend_in starts a one-shot clip at rest, lands on the walk's own pose at the
 phase asked for after the blend, follows it for the cycles asked, and moves the
 contact windows with it: a foot down where the blend lands is down from the
 start.

 Re-introduce: drop the sampled key at the landing in `clip_blended_in`, or the
 `spans[0] = 0.0f` extension, and the pose or the windows are off.
*>
fn void a_clip_blends_in_from_rest() @test
{
	io::printn("blend_in eases from rest into a walk and carries its footfalls");
	mcp::Fixture f;
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	if (!tool_ok(&f, "author_gait", `{"name":"Walker","duration":1.0,"pin_feet":false,"upper_body":false}`)) return;
	if (!tool_ok(&f, "blend_in", `{"name":"Start","clip":"Walker","phase":0.6,"blend":0.6,"cycles":2}`)) return;
	crig::AnimTemplate* walk = authored(&f, "Walker");
	crig::AnimTemplate* start = authored(&f, "Start");
	test::@check(start != null && !start.loop, "the blend did not land as a one-shot");
	if (start == null) return;
	test::@check(math::abs(start.duration - 2.6f) < 1.0e-3f, "duration %f, not 0.6 + 2 cycles", start.duration);

	// Rest at the start.
	foreach (dot : start.keyframes[0].dots)
	{
		test::@check(math::abs(dot.angle) < 1.0e-5f && dot.move.length() < 1.0e-6f, "%s does not start at rest", dot.joint_name);
	}
	// The walk's own pose once the blend is over, and a cycle later.
	Quaternionf want = walk.rotation_at("thigh_L", 0.6f);
	Quaternionf got = start.rotation_at("thigh_L", 0.6f);
	test::@check(math::abs(want.v.dot(got.v)) > 0.9999f, "the blend does not land on the walk's pose");
	Quaternionf later = start.rotation_at("thigh_L", 1.6f);
	test::@check(math::abs(want.v.dot(later.v)) > 0.9999f, "a cycle on, the clip is not the walk's pose again");

	// Each foot planted at the start, by the window it was in or the one added.
	foreach (name : (String[]){ "toe_L", "toe_R" })
	{
		bool from_start = false;
		foreach (foot : start.ground.feet) if (foot.joint == name && foot.down == 0.0f) from_start = true;
		test::@check(from_start, "%s is not down from the start", name);
	}
}

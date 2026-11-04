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
// apply_clip
//
// Run against a fixture of their own: the first write adds a pack, and the read
// checks above are worth keeping honest about a library that is exactly what is
// on disk.

<*
 One tools/call to apply_clip that is expected to be refused.

 The needles are the check, not decoration. An agent cannot see the rig, so a
 refusal that fails to name the value it rejected — and what it would have taken
 instead — costs a whole turn to guess at, and a refusal that merely names a
 fault would pass a test that only asked whether the call failed.

 @return `False if the call was accepted, or if the refusal left any of these unsaid.`
*>
fn bool Fixture.refuses(&self, String arguments, String... needles)
{
	return self.refuses_tool("apply_clip", arguments, ...needles);
}

// The same, for the tools whose refusals are not a clip's.
fn bool Fixture.refuses_tool(&self, String tool, String arguments, String... needles)
{
	String message = string::format(
		mem,
		`{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"%s","arguments":%s}}`,
		tool,
		arguments);
	defer alloc::free(mem, message);

	Object*? root = self.request(message);
	if (catch root) return false;
	defer root.free();

	if (!error_code_is(root, -32603)) return false;
	foreach (needle : needles)
	{
		if (!error_message_contains(root, needle)) return false;
	}
	return true;
}

// A clip's entry in get_scene's pack list, or null when no pack has that name.
fn Object* scene_pack(Object* scene, String name)
{
	Object*? packs = scene.get("packs");
	if (catch packs) return null;
	for (sz i = 0; i < packs.get_len(); i++)
	{
		Object* pack = packs.get_at(i);
		String? held = pack.get_string("name");
		if (catch held) continue;
		if (held == name) return pack;
	}
	return null;
}

// How many clips a get_scene pack entry lists; -1 when there is no such pack.
fn sz scene_clip_count(Object* pack)
{
	if (pack == null) return -1;
	Object*? clips = pack.get("clips");
	if (catch clips) return -1;
	return clips.get_len();
}

// Where get_pose put a named joint. Faults NOT_FOUND when the answer has no
// such joint, which is itself a failure worth seeing.
fn Vec3? posed_at(Object* pose, String name)
{
	Object* joints = pose.get("joints")!;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* joint = joints.get_at(i);
		if (joint.get_string("name")! != name) continue;
		Object* at = joint.get("position")!;
		return { (float)at.get_float_at(0)!, (float)at.get_float_at(1)!, (float)at.get_float_at(2)! };
	}
	return NOT_FOUND~;
}

// The knee bent a quarter turn about world X, written three ways. Applied to
// the fixture's hips-knee-foot chain, this swings the foot backward — see the
// turning table in algo/curves/animation.c3.
const String QUARTER_TURN_AXIS = `{"axis":[1,0,0],"angle":1.5707963267948966}`;
const String QUARTER_TURN_QUAT = `{"x":0.7071067811865476,"y":0,"z":0,"w":0.7071067811865476}`;
const String QUARTER_TURN_EULER = `[1.5707963267948966,0,0]`;

fn String bend_clip(String name, String rotation)
{
	return string::format(
		mem,
		`{"name":"%s","loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0,0,0]}]},{"time":0.5,"joints":[{"name":"knee","rotation":%s}]}]}`,
		name,
		rotation);
}

fn bool? applied_body(Object* applied)
{
	bool ok = applied.get_string("clip")! == "bend";
	ok = ok && applied.get_string("pack")! == "Authored";
	ok = ok && applied.get_bool("replaced")! == false;
	ok = ok && applied.get_int("keyframes")! == 2;
	ok = ok && applied.get_float("duration")! == 0.5;
	ok = ok && applied.get_bool("loop")! == true;
	ok = ok && applied.get_bool("applies")! == true;

	Object* joints = applied.get("joints")!;
	ok = ok && joints.get_len() == 1 && joints.get_string_at(0)! == "knee";
	return ok;
}

<*
 A clip read back out and written straight back in is the same clip.

 The whole point of `get_clip`: what it hands over is `apply_clip`'s input, so
 "read it, change one key, write it back" needs no reconstruction from samples.
 A round trip that came home different would make that the one thing an agent
 could not safely do.

 The `bone` entry is the part that had to be *added* to `apply_clip` for this to
 be true. Every imported clip carries the bone directions of the rig it was
 authored against — that is the whole of retargeting — and a parser that ignored
 them would drop retargeting on exactly the clips that need it, silently, on the
 way back in.
*>
fn void a_clip_read_back_out_writes_back_the_same() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// A clip with a bone on it, which is what an imported clip looks like.
	String arguments = string::format(mem,
		`{"name":"bend","loop":true,"keyframes":[{"time":0,"joints":[]},{"time":0.5,"joints":[{"name":"knee","rotation":%s,"rotation_interpolation":"hold","move":[0,0.25,0],"translation_interpolation":"auto","bone":[0,-1,0]}]}]}`,
		QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);

	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the clip with a bone on it was refused");
		return;
	}
	applied.free();

	Object*? read = f.call_tool("get_clip", `{"clip":"bend"}`);
	if (catch read)
	{
		test::@check(false, "get_clip would not read back a clip apply_clip had just written");
		return;
	}
	defer read.free();

	test::@check((read.get_string("name") ?? "") == "bend", "get_clip named the clip wrong");
	test::@check((read.get_bool("loop") ?? false), "the loop flag did not come back");
	test::@check((read.get_bool("editable") ?? false),
		"an authored clip came back as not editable, so apply_clip would be said to fork it");

	Object*? keys = read.get("keyframes");
	if (catch keys)
	{
		test::@check(false, "get_clip returned no keyframes");
		return;
	}
	test::@check(keys.get_len() == 2, "%d keyframes came back", keys.get_len());

	// The entry, with everything the format stores on it.
	Object* second = keys.get_at(1);
	Object*? joints = second.get("joints");
	if (catch joints)
	{
		test::@check(false, "the second keyframe came back with no joints");
		return;
	}
	test::@check(joints.get_len() == 1, "%d joints in the second key", joints.get_len());

	Object* entry = joints.get_at(0);
	test::@check((entry.get_string("name") ?? "") == "knee", "the joint name did not survive");
	test::@check(@ok(entry.get("rotation")), "the rotation did not survive");
	test::@check(@ok(entry.get("move")), "the move did not survive");
	test::@check(@ok(entry.get("bone")), "the bone did not survive — retargeting is silently gone");
	test::@check((entry.get_string("rotation_interpolation") ?? "") == "hold",
		"the outgoing rotation interpolation did not survive");
	test::@check((entry.get_string("translation_interpolation") ?? "") == "auto",
		"the outgoing translation interpolation did not survive");

	// And back in again, verbatim, under another name so the two can be compared.
	// The *text* the tool returned, not a re-serialisation of the parse: feeding
	// one tool's output to another's input is the claim, and rendering it again
	// here would be testing this file's writer instead.
	String? raw = f.call_tool_text("get_clip", `{"clip":"bend"}`);
	if (catch raw)
	{
		test::@check(false, "get_clip returned nothing the second time");
		return;
	}
	defer raw.free(mem);

	String renamed = raw.replace(mem, `"name":"bend"`, `"name":"bend2"`);
	defer renamed.free(mem);

	Object*? rewritten = f.call_tool("apply_clip", renamed);
	if (catch rewritten)
	{
		test::@check(false, "what get_clip handed back was not something apply_clip would take");
		return;
	}
	rewritten.free();

	Object*? twice = f.call_tool("get_clip", `{"clip":"bend2"}`);
	if (catch twice)
	{
		test::@check(false, "the rewritten clip could not be read back");
		return;
	}
	defer twice.free();

	Object*? keys2 = twice.get("keyframes");
	if (catch keys2)
	{
		test::@check(false, "the rewritten clip came back with no keyframes");
		return;
	}
	test::@check(keys2.get_len() == keys.get_len(),
		"the round trip changed the key count from %d to %d", keys.get_len(), keys2.get_len());

	Object* entry2 = keys2.get_at(1).get("joints")!!.get_at(0);
	test::@check(@ok(entry2.get("bone")), "the bone was dropped on the way back in");
	test::@check((entry2.get_string("name") ?? "") == "knee", "the joint changed on the round trip");
}

fn void apply_clip_answers_where_the_clip_landed() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);

	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip accepts a well-formed clip");
		return;
	}
	defer applied.free();
	test::@check(applied_body(applied) ?? false, "apply_clip answers with the clip, its pack and the joints it moves");
}

<*
 The authored pack holds `held` clips, one of them "bend" and `duration` long.

 The count is half the check: a rewrite that appended instead of replacing
 would leave a correct-looking clip beside a stale one of the same name, and
 `resolve_clip` would then call the name ambiguous for the rest of the session.
*>
fn bool? authored_in_scene_body(Object* scene, float duration, sz held)
{
	Object* pack = scene_pack(scene, "Authored");
	if (pack == null) return false;

	Object* clips = pack.get("clips")!;
	if (clips.get_len() != held) return false;

	for (sz i = 0; i < clips.get_len(); i++)
	{
		Object* clip = clips.get_at(i);
		if (clip.get_string("name")! != "bend") continue;
		return (float)clip.get_float("duration")! == duration && clip.get_int("keyframes")! == 2;
	}
	return false;
}

fn void an_applied_clip_joins_the_library() @test
{
	Fixture fixture;
	fixture.open_one_clip();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after a write");
		return;
	}
	defer scene.free();
	test::@check(authored_in_scene_body(scene, 0.5, 1) ?? false, "an applied clip shows up in the library as a pack of its own");
}

<*
 The clip actually turns the rig, read back through the same tool an agent
 would read it with.

 The knee bends a quarter turn about world X at t = 0.5, so the foot leaves rest
 at (0,0,0) and swings to knee + R*(foot - knee) = (0, 0.5, -0.5). Asserting the
 arithmetic rather than "it moved" is what makes the check fail on a rotation
 that was parsed into the wrong axis or the wrong sign.
*>
fn bool? bent_pose_body(Object* pose)
{
	Vec3 foot = posed_at(pose, "foot")!;
	Vec3 knee = posed_at(pose, "knee")!;

	bool ok = (foot - (Vec3){ 0, 0.5, -0.5 }).length() < 0.001f;
	// The joint above the turn does not move: a rotation belongs to the joint it
	// is written on and everything below it.
	ok = ok && (knee - (Vec3){ 0, 0.5, 0 }).length() < 0.001f;
	return ok;
}

fn void an_applied_clip_moves_the_rig() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? pose = f.call_tool("get_pose", `{"clip":"bend","t":0.5}`);
	if (catch pose)
	{
		test::@check(false, "get_pose answers for an applied clip");
		return;
	}
	defer pose.free();
	test::@check(bent_pose_body(pose) ?? false, "an applied clip swings the joints below the one it turns");
}

<*
 An applied clip is an editable timeline clip, not merely a playable one.

 The trap this closes: a clip written only into the authored pack plays, but is
 invisible to the timeline — absent from the clip chooser and the Animations
 list, unselectable — so the transport's Play/Pause keeps controlling whatever
 clip is loaded there, and pausing a played-but-unbound clip snaps the mesh back
 to it. apply_clip now binds the clip into the document and makes it the editing
 clip, exactly as the UI's New clip does.

 The witness is the precise condition the transport's pause branch tests: with
 the applied clip selected (`editing`) and then played (`current_ref`), the two
 refs agree, so `current_ref.same(editing)` holds and pause keeps the frame
 rather than parking a different clip.
*>
fn void an_applied_clip_is_the_editable_timeline_clip() @test
{
	Fixture fixture;
	fixture.open_one_clip();
	defer fixture.close();
	Fixture* f = &fixture;

	// Bound: it appears in the document's animation list, which is what the clip
	// chooser and the Animations pane draw from.
	test::@check(f.app.doc.bound_index("", "bend") >= 0,
		"an applied clip was not bound into the timeline");

	// Selected: it is the editing clip, so the transport acts on it.
	AnimTemplate* edited = f.app.clip(f.app.editing);
	test::@check(f.app.editing.valid() && edited != null && edited.name == "bend",
		"an applied clip did not become the editing clip");

	// Played: the player's ref lands on the same clip, so a pause holds instead
	// of parking whatever else the timeline held.
	test::@check(f.app.play_clip(f.app.editing), "the applied clip would not play");
	test::@check(f.app.current_ref.same(f.app.editing),
		"playing the applied clip left the player on a different clip than the timeline");
}

<*
 The clip and its timeline binding are one undo step.

 apply_clip does two writes — the pack swap and the binding — and a single
 Ctrl+Z has to take back both, or an undo leaves a chooser row that resolves to
 nothing, or a clip with no way to reach it.
*>
fn void applying_a_clip_binds_and_unbinds_in_one_undo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	sz bound_before = f.app.doc.animations.len();

	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied) { test::@check(false, "apply_clip accepts a well-formed clip"); return; }
	applied.free();

	test::@check(f.app.doc.bound_index("", "bend") >= 0, "the applied clip was not bound");
	test::@check(f.app.clip_named_in_authored("bend").valid(), "the applied clip is not in the pack");

	f.app.undo();

	test::@check(!f.app.clip_named_in_authored("bend").valid(),
		"one undo left the clip in the pack");
	test::@check(f.app.doc.bound_index("", "bend") < 0,
		"one undo left the timeline binding behind");
	test::@check(f.app.doc.animations.len() == bound_before,
		"one undo did not restore the binding count");
}

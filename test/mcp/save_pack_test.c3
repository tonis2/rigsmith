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
// save_pack

// Everything a previous run left in the save folder. The checks below count
// clips, and a stale pack would be counted along with them.
fn void discard_saved_packs()
{
	PathList? entries = path::ls(mem, (Path)SAVE_DIRECTORY, no_dirs: true);
	if (catch entries) return;

	// The names, then the array that held them — see `scan_packs`.
	defer
	{
		foreach (entry : entries) entry.free(mem);
		entries.free();
	}

	foreach (entry : entries)
	{
		String full = string::format(mem, "%s/%s", SAVE_DIRECTORY, (String)entry);
		defer alloc::free(mem, full.ptr);
		if (catch file::delete(full)) continue;
	}
}

fn bool? saved_body(Object* saved, String pack, sz clips)
{
	bool ok = saved.get_string("pack")! == pack;
	ok = ok && saved.get_string("file")!.contains(SAVE_DIRECTORY);
	ok = ok && saved.get("clips")!.get_len() == clips;
	return ok;
}

// How many joints the reloaded pack of that name marks optional, or -1 when the
// library holds no pack by it — so a check cannot read a pack that failed to
// write as one that marked none.
fn int pack_spare(crig::AppState* app, String pack)
{
	foreach (&held : app.packs)
	{
		if (held.name != pack) continue;
		int spare = 0;
		foreach (marked : held.joint_optional)
		{
			if (marked) spare++;
		}
		return spare;
	}
	return -1;
}

// Whether that pack marks that particular joint optional. The count alone would
// pass on a pack that marked the right number of the wrong joints.
fn bool pack_marks(crig::AppState* app, String pack, String joint)
{
	foreach (&held : app.packs)
	{
		if (held.name != pack) continue;
		foreach (usz j, marked : held.joint_optional)
		{
			if (marked && j < held.joint_names.len && held.joint_names[j] == joint) return true;
		}
	}
	return false;
}

// Whether the reloaded library holds this clip in the pack of that name.
fn bool pack_holds(crig::AppState* app, String pack, String clip)
{
	foreach (held : app.packs)
	{
		if (held.name != pack) continue;
		foreach (template : held.clips)
		{
			if (template.name == clip) return true;
		}
	}
	return false;
}

<*
 The whole point of the tool: clips an agent wrote, on disk, read back off it.

 Read back rather than asserted from memory — a pack that wrote and could not be
 re-read would pass any check made against what was handed to the writer, and
 that is exactly the failure worth catching.
*>
fn void save_pack_lands_on_disk() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;
	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Kit"}`);
	if (catch saved)
	{
		test::@check(false, "save_pack accepts a named rig with clips to save");
		return;
	}
	defer saved.free();

	test::@check((saved_body(saved, "Kit", 1) ?? false)
		&& (saved.get_int("saved") ?? 0) == 1
		&& io::file::is_file("build/mcp-packs/Kit.glb"),
		"save_pack writes the authored clips to a file and answers with what is in it");

	test::@check(pack_holds(&f.app, "Kit", "Bend") && f.app.authored() != null
		&& f.app.clip_named_in_authored("Bend").valid(),
		"publishing reads the disk pack back without consuming the project's authored clip");
}

<*
 A rig and a body, with nothing animated on it, is a body plan and is written.

 The case this exists for is the first thing anybody does with a fresh model:
 open it, place a rig, and want that rig back as a plan the next model can be
 fitted from. `fit_preset` reads a pack's skeleton and its body and never looks
 at its clips, so the clip a save used to insist on was an animation authored for
 a figure nobody had animated yet, purely to satisfy the writer.

 Three gates had to agree — the tool, `save_authored_pack` and `export_pack_glb`
 all refused an empty clip list — so the check reads the file back rather than
 trusting the answer: `body_plan` comes off the reloaded pack.
*>
fn void save_pack_writes_a_body_plan_with_no_clips() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	// Deliberately no apply_clip: nothing is authored, which is the whole point.
	test::@check(f.app.authored() == null, "nothing has been authored");

	Object*? saved = f.call_tool("save_pack", `{"name":"Plan","plan":"biped","body":"mesh"}`);
	if (catch saved)
	{
		test::@check(false, "save_pack takes a rig and a body with no clip authored");
		return;
	}
	defer saved.free();

	test::@check(io::file::is_file("build/mcp-packs/Plan.glb"), "the file is on disk");
	test::@check((saved.get("clips") ?? null) != null && saved.get("clips")!!.get_len() == 0,
		"and carries no clips");
	test::@check((saved.get_bool("body_plan") ?? false),
		"the reloaded pack is a body plan — a plan tag and a body, which is all fitting needs");
	test::@check((saved.get_int("vertices") ?? 0) > 0, "with the loaded model as its body");

	// Off the library rather than off the answer: the answer describes what was
	// written, this is what crig can reach afterwards.
	bool listed = false;
	foreach (&held : f.app.packs)
	{
		if (held.name == "Plan" && held.is_body_plan()) listed = true;
	}
	test::@check(listed, "and the library holds it as one");
}

<*
 A save carrying neither a clip nor a body is still refused.

 The one combination that reads back as nothing: `read_pack` would take it —
 it refuses only a file with no clips *and* no joints — but a skeleton alone can
 neither be played nor fitted, so writing one is always a mistake. The refusal
 has to name both ways out, because a caller who has just rigged a model by hand
 has done nothing wrong and only needs to say what the file carries.
*>
fn void save_pack_refuses_a_file_that_would_hold_nothing() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? refused = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"save_pack","arguments":{"name":"Hollow"}}}`);
	if (catch refused)
	{
		test::@check(false, "save_pack answers a save with nothing to write");
		return;
	}
	defer refused.free();

	test::@check(error_message_contains(refused, "body"),
		"a save with no clip and no body is refused, and the refusal names the body");
	test::@check(!io::file::is_file("build/mcp-packs/Hollow.glb"), "and writes nothing");
}

<*
 A second save under the same name adds rather than replaces.

 The check that matters most here: writing only the authored clips would mean
 every save after the first silently discarded the one before it, and there is
 no undo behind this tool.
*>
fn void saving_again_adds_to_the_pack() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	// The first save, which this check is about adding to. Made here rather than
	// inherited from `save_pack_lands_on_disk`: checks run in name order.
	if (!f.save_one("Bend", QUARTER_TURN_AXIS)) return;

	String arguments = bend_clip("Straighten", QUARTER_TURN_EULER);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a second clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Kit"}`);
	if (catch saved)
	{
		test::@check(false, "save_pack accepts a save into a pack that exists");
		return;
	}
	defer saved.free();

	test::@check((saved_body(saved, "Kit", 2) ?? false)
		&& pack_holds(&f.app, "Kit", "Bend")
		&& pack_holds(&f.app, "Kit", "Straighten"),
		"saving again keeps what the pack already held and adds the new clip");
}

<*
 A joint named optional is written as one, and read back as one off the file.

 What it decides is what `apply_plan` does with the pack later: an optional joint
 is held back when the plan is fitted, and one that is not is placed on every
 model the plan ever meets. A pack that marked none is why a wire-built humanoid
 guesses forty knuckles onto a figure that has no hands.
*>
fn void save_pack_marks_the_joints_it_was_told_are_optional() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Kit","optional":["foot"]}`);
	if (catch saved)
	{
		test::@check(false, "save_pack takes a list of optional joints");
		return;
	}
	defer saved.free();

	test::@check((saved.get_int("optional") ?? -1) == 1,
		"the answer counts what was marked, so a caller can see the list landed");
	test::@check(pack_spare(&f.app, "Kit") == 1 && pack_marks(&f.app, "Kit", "foot"),
		"the file marks that joint and only that joint");
	test::@check(!pack_marks(&f.app, "Kit", "hips") && !pack_marks(&f.app, "Kit", "knee"),
		"and leaves the joints it was not told about alone");
}

<*
 The list survives a second save that says nothing about it, and `[]` clears it.

 The same rule the plan tag and the tags follow, and for a sharper reason: those
 change which rigs are offered a pack, and this changes what a plan places onto a
 user's model. A list that evaporated because the second call did not repeat it
 would turn a careful pack into a careless one with nothing said.

 So silence carries it and an empty array is how a caller means none — the one
 place in this surface where those two differ, which is why both are checked.
*>
fn void saving_again_keeps_the_optional_joints() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String first = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, first);
	Object*? applied = f.call_tool("apply_clip", first);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? marked = f.call_tool("save_pack", `{"name":"Kit","optional":["foot"]}`);
	if (catch marked)
	{
		test::@check(false, "save_pack takes a list of optional joints");
		return;
	}
	marked.free();

	String second = bend_clip("Straighten", QUARTER_TURN_EULER);
	defer alloc::free(mem, second);
	Object*? again = f.call_tool("apply_clip", second);
	if (catch again)
	{
		test::@check(false, "the saver fixture takes a second clip");
		return;
	}
	again.free();

	Object*? quiet = f.call_tool("save_pack", `{"name":"Kit"}`);
	if (catch quiet)
	{
		test::@check(false, "save_pack accepts a save that says nothing about optional");
		return;
	}
	quiet.free();

	test::@check(pack_spare(&f.app, "Kit") == 1 && pack_marks(&f.app, "Kit", "foot"),
		"a save that does not mention the list keeps the one the pack already carried");

	String third = bend_clip("Reach", QUARTER_TURN_QUAT);
	defer alloc::free(mem, third);
	Object*? more = f.call_tool("apply_clip", third);
	if (catch more)
	{
		test::@check(false, "the saver fixture takes a third clip");
		return;
	}
	more.free();

	Object*? cleared = f.call_tool("save_pack", `{"name":"Kit","optional":[]}`);
	if (catch cleared)
	{
		test::@check(false, "save_pack accepts an empty optional list");
		return;
	}
	defer cleared.free();

	test::@check((cleared.get_int("optional") ?? -1) == 0 && pack_spare(&f.app, "Kit") == 0,
		"and an empty array is how a caller says it means none");
}

fn void save_pack_will_not_mark_a_joint_the_rig_has_not_got() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	// A misspelling here writes into the file and shows up as a finger being
	// placed on a model much later, so it is named at the moment it is sent.
	test::@check(f.refuses_tool("save_pack", `{"name":"Kit","optional":["ankle"]}`,
			"ankle", "no dot of that name"),
		"an optional joint the rig does not carry is named rather than written");
	test::@check(f.refuses_tool("save_pack", `{"name":"Kit","optional":[7]}`,
			"optional", "dot name"),
		"and an entry that is not a string says which position it was in");
	test::@check(f.refuses_tool("save_pack", `{"name":"Kit","optional":"foot"}`,
			"optional", "array of dot names"),
		"a bare string in place of the array is turned away with the shape it wanted");

	test::@check(!io::file::is_file("build/mcp-packs/Kit.glb"),
		"and nothing was written on the way to any of those refusals");
}

<*
 Saving the clip that is on screen leaves it on screen.

 The reload frees every clip in the library, including the one the player holds a
 copy of, so this is the path where getting it wrong is a use-after-free rather
 than a wrong answer.
*>
fn void saving_what_is_playing_keeps_it_playing() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;
	String arguments = bend_clip("Watched", QUARTER_TURN_QUAT);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes the clip to watch");
		return;
	}
	applied.free();

	Object*? playing = f.call_tool("play", `{"clip":"Watched"}`);
	if (catch playing)
	{
		test::@check(false, "the clip to watch plays");
		return;
	}
	playing.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Kit"}`);
	if (catch saved)
	{
		test::@check(false, "save_pack accepts a save while something is playing");
		return;
	}
	defer saved.free();

	test::@check((saved.get_bool("playing") ?? false) == true
		&& f.app.animating
		&& f.app.current_anim.name == "Watched"
		&& f.app.clip(f.app.current_ref) != null,
		"publishing a clip preserves its active project playback");

	f.app.stop_animation();
}

<*
 Every refusal, on the fixture that cannot write.

 That fixture carries one unnamed dot, so `save_pack` is turned away before it
 reaches the filesystem — which is what makes it safe to point these at the real
 animation library.
*>
fn void save_pack_says_what_it_will_not_do() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses_tool("save_pack", `{}`, `"name"`),
		"a save with no name says which field it wanted");

	test::@check(f.refuses_tool("save_pack", `{"name":"///"}`, "///", "no letter or digit"),
		"a name that cannot become a file name says so, rather than writing somewhere odd");

	test::@check(f.refuses_tool("save_pack", `{"name":"Kit"}`, "bone_4", "addresses joints by name"),
		"an unnamed dot is named, because a pack could carry no joint for it");

	test::@check(!io::file::is_file("assets/animations/Kit.glb"),
		"and none of that wrote anything");
}

<*
 The library's own body plans cannot be saved over.

 They are the reference rigs every untagged pack is matched against, and this
 writer emits no body — so the refusal is not about losing a file, it is about
 losing the plan the rest of the library is read through.
*>
fn void a_body_plan_is_not_saved_over() @test
{
	Fixture guard;
	guard.open_saver();
	defer guard.close();

	// A body plan out of the fixture library, under its own file name: the guard
	// keys on the *path*, so the saver has to be pointed at the same folder the
	// plan was found in or there is nothing standing there to guard.
	//
	// It used to look in `assets/animations` while taking the name from the
	// fixture library, which worked only while the two folders happened to hold a
	// pack of the same name. When they stopped agreeing the guard could not fire,
	// and the check did not merely fail — it wrote its pack into the shipped
	// asset folder, where ten other checks then tried to load it as a model.
	Fixture shipped;
	shipped.open();
	String plan_file = "";
	foreach (held : shipped.app.packs)
	{
		if (held.is_body_plan() && plan_file.len == 0) plan_file = held.path.copy(mem);
	}
	shipped.close();
	if (plan_file.len == 0)
	{
		test::@check(false, "the shipped library holds a body plan to guard");
		return;
	}
	defer alloc::free(mem, plan_file.ptr);

	guard.app.load_packs(library::ready());

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = guard.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the guard fixture takes a clip");
		return;
	}
	applied.free();

	String stem = crig::base_name(plan_file);
	String name = stem[:stem.len - 4];
	String call = string::format(mem, `{"name":"%s"}`, name);
	defer alloc::free(mem, call.ptr);

	test::@check(guard.refuses_tool("save_pack", call, "body plan", "no body"),
		"saving over a body plan is refused, and says what would have been lost");
}

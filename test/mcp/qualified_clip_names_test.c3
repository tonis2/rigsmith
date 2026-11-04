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
// Qualified clip names
//
// A bare name is looked for across the whole library, and three of the shipped
// packs call something "Idle". `"Pack/Clip"` is the way through that. These
// check both halves: that qualifying reaches a clip a bare name cannot, and
// that a pair which misses says which half of it missed.

<*
 A clip name more than one pack holds, with the first holder's display name
 written into `pack_name`.

 Found rather than written down: which packs ship and what they call their clips
 is a property of the library folder, and a check hard-coding "Idle" would fail
 for the wrong reason the day one is renamed. A pack whose own display name is
 shared is passed over — qualifying with that is ambiguous too, which is not
 what this is looking for.

 Empty when the library holds no shared name, which the caller reports rather
 than passing over: it means the whole path went unchecked.
*>
fn String shared_clip_name(crig::AppState* app, String* pack_name)
{
	foreach (pack : app.packs)
	{
		int packs_called = 0;
		foreach (other : app.packs)
		{
			if (other.name == pack.name) packs_called++;
		}
		if (packs_called != 1) continue;

		foreach (clip : pack.clips)
		{
			if (name_count(app, clip.name) < 2) continue;
			*pack_name = pack.name;
			return clip.name;
		}
	}
	return "";
}

fn void qualifying_reaches_a_clip_a_bare_name_ranks_past() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The ambiguity is made here rather than found in the library, and that is a
	// change of circumstance rather than of subject. Two shipped packs used to
	// share a clip name — `biped.glb` and `bird.glb` both carried an "Idle" — and
	// the library ships two packs now whose clip names do not overlap. Authoring
	// a clip under a name the shipped pack already uses puts the collision back
	// where the check needs it, and it is the collision a user actually hits:
	// their own clip, named the obvious thing, beside a library one.
	String colliding = bend_clip("Walk", QUARTER_TURN_AXIS);
	defer alloc::free(mem, colliding);
	Object*? authored = f.call_tool("apply_clip", colliding);
	if (catch authored)
	{
		test::@check(false, "the fixture takes a clip named after a library one");
		return;
	}
	authored.free();

	String pack_name = "";
	String clip = shared_clip_name(&f.app, &pack_name);
	if (clip.len == 0)
	{
		test::@check(false, "the library holds a clip name more than one pack uses");
		return;
	}

	// Ranked, not refused: the bare name reaches the clip bound to the character —
	// the one just authored — where the library's copy needs "Pack/Clip".
	String bare = string::format(mem, `{"clip":"%s"}`, clip);
	defer alloc::free(mem, bare);
	Object*? own = f.call_tool("get_clip", bare);
	if (catch own)
	{
		test::@check(false, "a bare shared name answers");
		return;
	}
	defer own.free();
	test::@check(own.get_bool("editable") ?? false,
		"a bare name two packs share reaches the bound, authored clip");

	String qualified = string::format(mem, `{"clip":"%s/%s"}`, pack_name, clip);
	defer alloc::free(mem, qualified);
	Object*? pose = f.call_tool("get_pose", qualified);
	if (catch pose)
	{
		test::@check(false, "%s/%s resolves as well", pack_name, clip);
		return;
	}
	defer pose.free();
	// The clip's own name comes back, not the pair that asked for it: the pack
	// half is how it was addressed, not part of what it is called.
	test::@check((pose.get_string("clip") ?? "") == clip,
		"a qualified name samples the clip in the pack it named");
}

fn void a_qualified_name_that_misses_says_which_half() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? no_pack = f.request(
		`{"jsonrpc":"2.0","id":91,"method":"tools/call","params":{"name":"get_pose","arguments":{"clip":"Nosuchpack/bend"}}}`);
	if (catch no_pack)
	{
		test::@check(false, "an unknown pack answers");
		return;
	}
	defer no_pack.free();
	test::@check(error_message_contains(no_pack, `no pack is called "Nosuchpack"`)
		&& error_message_contains(no_pack, "Authored"),
		"a pair naming no pack says so and lists the packs there are");

	Object*? no_clip = f.request(
		`{"jsonrpc":"2.0","id":92,"method":"tools/call","params":{"name":"get_pose","arguments":{"clip":"Authored/nosuchclip"}}}`);
	if (catch no_clip)
	{
		test::@check(false, "an unknown clip in a known pack answers");
		return;
	}
	defer no_clip.free();
	test::@check(error_message_contains(no_clip, `pack "Authored" holds no clip called "nosuchclip"`)
		&& error_message_contains(no_clip, "bend"),
		"a pair naming a real pack lists that pack's clips, not the whole library's");
}

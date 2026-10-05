<*
 Editing a glTF file's metadata without disturbing the rest of it.

 Two things are being checked, and the second is the one that matters. The first
 is that the edit lands: the name says what it was told to say. The second is
 that **nothing else moved** — the numbers around it byte for byte, and a .glb's
 binary chunk byte for byte. A patcher that got the first right and the second
 wrong would rename a clip and quietly round every accessor bound in the file,
 which is a corruption nobody would connect to having typed a name.

 The real-file checks run against a copy of a generated pack, never the shipped
 one: these write to what they open.
*>
module crig_tests::gltf_patch;

import crig;
import gltf_edit;
import crig_tests::library;


import std::core::test;
import std::io;
import std::io::file;

// A document with the two shapes every edit here touches: an array of objects
// with names in them, and numbers that must not be re-formatted.
const String DOCUMENT @local = `{"accessors":[{"min":[-0.10000000149011612,1.0e-7],"count":24}],"animations":[{"name":"mixamo.com","channels":[]},{"channels":[]}],"asset":{"version":"2.0"}}`;

// One edit's worth of path, held in a static so the slice outlives the call that
// built it. One static per helper, so two calls to the same one alias — every
// check below uses each at most once per patch.
fn gltf_edit::JsonEdit[] one_edit(gltf_edit::JsonStep[] path, String value) @local
{
	static gltf_edit::JsonEdit[1] held;
	held[0] = { .path = path, .value = value };
	return held[..];
}

fn gltf_edit::JsonStep[] animation_name(usz which) @local
{
	static gltf_edit::JsonStep[3] held;
	held = { { .key = "animations" }, { .at = which }, { .key = "name" } };
	return held[..];
}

fn gltf_edit::JsonStep[] extras_key(String key) @local
{
	static gltf_edit::JsonStep[2] held;
	held = { { .key = "extras" }, { .key = key } };
	return held[..];
}

<*
 A name that is already there is written over, and nothing else in the document
 changes.

 The numbers are the point. `-0.10000000149011612` is what a float writes as
 when a tool round-trips it through a double, and `1.0e-7` is an exponent form a
 re-printer would spell differently. Both come back untouched only if the text
 outside the value was copied rather than regenerated.
*>
fn void a_name_is_written_over_and_nothing_else_moves() @test
{
	io::printn("renaming an animation changes the name and no other byte");

	String? patched = gltf_edit::patch_gltf_text(mem, DOCUMENT, one_edit(animation_name(0), "Walk"));
	if (catch patched)
	{
		test::@check(false, "the document could not be patched");
		return;
	}
	defer alloc::free(mem, patched.ptr);

	test::@check(patched.contains(`"name":"Walk"`), "the new name is not in %s", patched);
	test::@check(!patched.contains("mixamo.com"), "the old name survived in %s", patched);

	// Everything before the animations array and everything after it, unchanged.
	test::@check(patched.contains(`"min":[-0.10000000149011612,1.0e-7]`),
		"the accessor bounds were re-formatted: %s", patched);
	test::@check(patched.contains(`"asset":{"version":"2.0"}`),
		"the tail of the document was disturbed: %s", patched);
}

<*
 A member the object does not have is written in, rather than being an error.

 The second animation in the fixture carries no name at all, which is legal glTF
 and is what a clip exported without one looks like. Renaming it has to work;
 refusing would mean the only clips that can be renamed are the ones that
 already had a name.
*>
fn void a_missing_member_is_written_in() @test
{
	io::printn("naming an animation that had no name adds the member");

	String? patched = gltf_edit::patch_gltf_text(mem, DOCUMENT, one_edit(animation_name(1), "Idle"));
	if (catch patched)
	{
		test::@check(false, "the document could not be patched");
		return;
	}
	defer alloc::free(mem, patched.ptr);

	test::@check(patched.contains(`"name":"Idle"`), "the name was not added: %s", patched);
	// The first animation keeps its own name: an insertion into the wrong object
	// is the failure this catches.
	test::@check(patched.contains(`"name":"mixamo.com"`),
		"the other animation lost its name: %s", patched);
}

<*
 A root `extras` that is not there is created, and a second key goes in beside
 the first.

 Nothing crig did not write carries `extras`, so this is the path every tag on a
 downloaded file takes. The second key is checked because creating the object and
 adding to it are different branches, and an insertion that forgot the comma
 would leave a document that will not parse.
*>
fn void extras_are_created_when_the_file_has_none() @test
{
	io::printn("tagging a file with no extras creates the object");

	String? tagged = gltf_edit::patch_gltf_text(mem, DOCUMENT, one_edit(extras_key("plan"), "biped"));
	if (catch tagged)
	{
		test::@check(false, "the plan could not be written");
		return;
	}
	defer alloc::free(mem, tagged.ptr);

	String? twice = gltf_edit::patch_gltf_text(mem, tagged, one_edit(extras_key("tags"), "walking, idle"));
	if (catch twice)
	{
		test::@check(false, "the tags could not be written");
		return;
	}
	defer alloc::free(mem, twice.ptr);

	test::@check(twice.contains(`"plan":"biped"`), "the plan is not in %s", twice);
	test::@check(twice.contains(`"tags":"walking, idle"`), "the tags are not in %s", twice);
	test::@check(twice.contains(`"extras":{`), "no extras object was made: %s", twice);
	test::@check(twice.contains(`"asset":{"version":"2.0"}`),
		"the rest of the document was disturbed: %s", twice);
}

<*
 An empty value takes the member out rather than writing a blank one.

 Clearing a plan has to leave a file that reads as untagged, and `"plan":""`
 would do that — but it would also leave a key in every file anyone ever typed
 into and then thought better of.
*>
fn void an_empty_value_removes_the_member() @test
{
	io::printn("clearing a tag removes the key");

	String? tagged = gltf_edit::patch_gltf_text(mem, DOCUMENT, one_edit(extras_key("plan"), "biped"));
	if (catch tagged) { test::@check(false, "the plan could not be written"); return; }
	defer alloc::free(mem, tagged.ptr);

	String? cleared = gltf_edit::patch_gltf_text(mem, tagged, one_edit(extras_key("plan"), ""));
	if (catch cleared) { test::@check(false, "the plan could not be cleared"); return; }
	defer alloc::free(mem, cleared.ptr);

	test::@check(!cleared.contains(`"plan"`), "the key survived: %s", cleared);
	test::@check(cleared.contains(`"extras":{}`),
		"the empty object was not left behind cleanly: %s", cleared);

	// And removing what is not there is not an error.
	String? again = gltf_edit::patch_gltf_text(mem, cleared, one_edit(extras_key("plan"), ""));
	if (catch again) { test::@check(false, "removing a key twice raised"); return; }
	defer alloc::free(mem, again.ptr);
	test::eq((usz)again.len, (usz)cleared.len);
}

<*
 A name with a quote in it is escaped on the way in.

 A person can type one, and a raw quote closes the string early — the document
 that comes out then parses as something else entirely, or not at all. Also the
 case that says the scanner reads *back* over an escape correctly: the second
 patch has to find a later member in a document whose earlier value now contains
 a quote.
*>
fn void a_quote_in_a_name_is_escaped() @test
{
	io::printn("a name containing a quote survives being written and found again");

	String? patched = gltf_edit::patch_gltf_text(mem, DOCUMENT, one_edit(animation_name(0), `say "hi"`));
	if (catch patched) { test::@check(false, "the name could not be written"); return; }
	defer alloc::free(mem, patched.ptr);

	test::@check(patched.contains(`"name":"say \"hi\""`), "the quote was not escaped: %s", patched);

	String? again = gltf_edit::patch_gltf_text(mem, patched, one_edit(animation_name(1), "Idle"));
	if (catch again) { test::@check(false, "the escaped value broke the scan"); return; }
	defer alloc::free(mem, again.ptr);
	test::@check(again.contains(`"name":"Idle"`), "the second animation was not reached: %s", again);
}

<*
 An element the array does not have is refused rather than invented.

 The one case that must fail: a caller holding a stale index would otherwise
 write a name into whichever animation happened to be nearest.
*>
fn void a_path_past_the_end_is_refused() @test
{
	io::printn("naming an animation that is not there is an error");

	String? patched = gltf_edit::patch_gltf_text(mem, DOCUMENT, one_edit(animation_name(7), "Nowhere"));
	if (try patched)
	{
		defer alloc::free(mem, patched.ptr);
		test::@check(false, "a path past the end was accepted: %s", patched);
		return;
	}
	test::@check(true, "refused");
}

// ---------------------------------------------------------------------------
// A real .glb

// A copy of one of the generated packs, under `build` so a run leaves nothing to
// commit. These checks write to what they open, so never the shipped file.
fn String? scratch_pack(String name) @local
{
	String source = string::format(mem, "%s/humanoid.glb", library::ready());
	defer alloc::free(mem, source.ptr);

	char[] bytes = file::load(mem, source)!;
	defer alloc::free(mem, bytes);

	String destination = string::format(mem, "build/%s", name);
	file::save(destination, bytes)!;
	return destination;
}

<*
 Everything after the JSON chunk: the binary, and any chunk after that.

 What a patch must not touch a byte of. Returned as a String so it can be copied
 and compared with one call.
*>
fn String tail_of(char[] bytes) @local
{
	if (bytes.len < 20) return "";
	usz json_length = (usz)bytes[12] | ((usz)bytes[13] << 8) | ((usz)bytes[14] << 16) | ((usz)bytes[15] << 24);
	usz at = 20 + ((json_length + 3) & ~(usz)3);
	if (at >= bytes.len) return "";
	return (String)bytes[at..];
}

<*
 Patching a .glb leaves its binary chunk byte for byte, and the file still reads.

 The strongest thing this suite says. The tail comparison is what asserts that
 the vertices, the keyframes and the inverse binds are exactly the ones that went
 in; `read_pack` afterwards is what asserts the header lengths were recomputed,
 because a .glb whose total length is wrong does not open at all and nothing
 above would notice.
*>
fn void a_glb_keeps_its_binary_chunk() @test
{
	io::printn("patching a .glb rewrites only its JSON");

	String? path = scratch_pack("patch_test_binary.glb");
	if (catch path) { test::@check(false, "the fixture pack could not be copied"); return; }
	defer alloc::free(mem, path.ptr);

	char[]? before = file::load(mem, path);
	if (catch before) { test::@check(false, "the copy could not be read"); return; }
	defer alloc::free(mem, before);

	// Copied rather than viewed: the patch is written over the same file, and the
	// comparison is against what was there first.
	String original_tail = tail_of(before).copy(mem);
	defer alloc::free(mem, original_tail.ptr);
	test::@check(original_tail.len > 0, "the fixture has no binary chunk to protect");

	if (catch gltf_edit::patch_gltf(mem, path, one_edit(extras_key("tags"), "checked")))
	{
		test::@check(false, "the pack could not be patched");
		return;
	}

	char[]? after = file::load(mem, path);
	if (catch after) { test::@check(false, "the patched pack could not be read"); return; }
	defer alloc::free(mem, after);

	String patched_tail = tail_of(after);
	test::eq((usz)patched_tail.len, (usz)original_tail.len);
	test::@check(patched_tail == original_tail, "the bytes after the JSON chunk changed");

	crig::AnimPack? reopened = crig::read_pack(mem, path);
	if (catch reopened) { test::@check(false, "the patched pack no longer opens"); return; }
	defer reopened.free(mem);
	test::@check(reopened.clips.len > 0, "the patched pack came back with no clips");
}

<*
 What was written into the file is what the reader reads back out.

 The round trip the whole feature rests on: a tag typed into the panel has to be
 the tag the library sees on the next scan, and a renamed clip has to come back
 under its new name. Three edits in one call, because that is how the panel
 saves — and because a second edit reading offsets from before the first is the
 mistake it would make.
*>
fn void a_patched_pack_reads_back_what_was_written() @test
{
	io::printn("a tag and a rename survive the round trip");

	String? path = scratch_pack("patch_test_round_trip.glb");
	if (catch path) { test::@check(false, "the fixture pack could not be copied"); return; }
	defer alloc::free(mem, path.ptr);

	gltf_edit::JsonStep[2] tag_path = { { .key = "extras" }, { .key = "tags" } };
	gltf_edit::JsonStep[2] plan_path = { { .key = "extras" }, { .key = "plan" } };
	gltf_edit::JsonStep[3] name_path = { { .key = "animations" }, { .at = 0 }, { .key = "name" } };
	gltf_edit::JsonEdit[3] edits = {
		{ .path = tag_path[..], .value = "swimming, slow" },
		{ .path = plan_path[..], .value = "biped" },
		{ .path = name_path[..], .value = "Renamed Clip" },
	};

	if (catch gltf_edit::patch_gltf(mem, path, edits[..]))
	{
		test::@check(false, "the pack could not be patched");
		return;
	}

	crig::AnimPack? reopened = crig::read_pack(mem, path);
	if (catch reopened) { test::@check(false, "the patched pack no longer opens"); return; }
	defer reopened.free(mem);

	test::eq(reopened.plan, "biped");
	test::eq((usz)reopened.tags.len, (usz)2);
	if (reopened.tags.len == 2)
	{
		test::eq(reopened.tags[0], "swimming");
		test::eq(reopened.tags[1], "slow");
	}

	bool renamed = false;
	foreach (clip : reopened.clips)
	{
		if (clip.name == "Renamed Clip") renamed = true;
	}
	test::@check(renamed, "no clip came back under the new name");
}

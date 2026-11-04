<*
 Editing a glTF in place: the container split, and the JSON member splice.

 The claim these exist to hold up is "everything you did not edit survives
 exactly", so the central check is a byte comparison against files nothing in
 this repository wrote — `truck.glb` with its images and animations, `duck.gltf`
 with a base64 buffer inline. A round trip that reformats is a round trip that
 has silently rewritten somebody's asset.

 These came over with `src/gltf/` when the patcher left `gltf.c3l`. The two
 sample files did not: they are the library's own fixtures, still used by its own
 suite, so this reads them where they live rather than keeping a second copy of
 six hundred kilobytes. Nothing here writes to them.
*>
module crig_tests::gltf_edit;

import gltf;
import gltf_edit;
import std::core;

import std::core::test;
import std::io;
import std::io::file;
import std::math::vector;
import std::math::quaternion;

const String TRUCK @local = "libs/three/lib/gltf.c3l/test/truck.glb";
const String DUCK @local = "libs/three/lib/gltf.c3l/test/duck.gltf";

macro bool @same_bytes(char[] a, char[] b) @local
{
	if (a.len != b.len) return false;
	foreach (i, c : a)
	{
		if (c != b[i]) return false;
	}
	return true;
}

<*
 A .glb split and written straight back is the same file, bit for bit.

 The strongest form of the promise, and the only one worth making: not "it still
 loads", not "the meshes are the same", but that the bytes did not move. Anything
 weaker leaves room for a reformat nobody notices until a file goes somewhere
 strict.
*>
fn void a_binary_round_trip_changes_nothing() @test
{
	char[] before = file::load(mem, TRUCK)!!;
	defer free(before);

	gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, TRUCK)!!;
	defer parts.free(mem);

	test::@check(parts.binary, "a .glb reads as binary");
	test::@check(parts.rest.len > 0, "and its buffer chunk comes back whole");

	String out = "build/gltf-edit-truck-copy.glb";
	gltf_edit::write_glb(out, parts)!!;
	defer (void)file::delete(out);

	char[] after = file::load(mem, out)!!;
	defer free(after);

	test::@check(@same_bytes(before, after), "the file is unchanged");
}

// The text form has no container to rebuild, so the bytes have even less excuse
// to move.
fn void a_text_round_trip_changes_nothing() @test
{
	char[] before = file::load(mem, DUCK)!!;
	defer free(before);

	gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, DUCK)!!;
	defer parts.free(mem);

	test::@check(!parts.binary, "a .gltf reads as text");
	test::@check(parts.rest.len == 0, "with nothing after the JSON");

	String out = "build/gltf-edit-duck-copy.gltf";
	gltf_edit::write_glb(out, parts)!!;
	defer (void)file::delete(out);

	char[] after = file::load(mem, out)!!;
	defer free(after);

	test::@check(@same_bytes(before, after), "the file is unchanged");
}

<*
 Stamping metadata onto a real file leaves its binary chunk alone.

 The whole reason for editing text rather than re-encoding: `truck.glb` carries
 442 kilobytes of vertices, images and animation samplers, and adding forty bytes
 of `extras` must not touch one of them.
*>
fn void patching_a_real_file_keeps_its_buffer() @test
{
	gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, TRUCK)!!;
	defer parts.free(mem);

	char[] original_bin = (char[])alloc::clone_slice(mem, parts.rest);
	defer free(original_bin);

	gltf_edit::JsonStep[2] where = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = "tool" } };
	gltf_edit::JsonEdit[1] edits = { { .path = where[..], .value = "crig" } };
	String stamped = gltf_edit::patch_gltf_text(mem, (String)parts.json, edits[..])!!;

	// Handed over rather than aliased: the old text is released here and the new
	// text becomes the part set's, so `parts.free` is the only release either
	// needs. A `defer stamped.free` beside this would be the second one.
	free(parts.json);
	parts.json = (char[])stamped;

	String out = "build/gltf-edit-truck-stamped.glb";
	gltf_edit::write_glb(out, parts)!!;
	defer (void)file::delete(out);

	gltf_edit::GlbParts back = gltf_edit::split_glb(mem, out)!!;
	defer back.free(mem);

	test::@check(@same_bytes(original_bin, back.rest), "every byte after the JSON is where it was");

	// And the file is still a glTF to a reader that knows nothing about the edit.
	gltf::GltfStream stream = gltf::open(out)!!;
	defer stream.close();
	test::@check(stream.gltf.extras.get("tool")!! == "crig");
	test::@check(stream.gltf.meshes.len() > 0, "the meshes survived");
	test::@check(stream.gltf.images.len() > 0, "and so did the images");
}

<*
 Stamping one tool's metadata leaves another tool's alone.

 `extras` is shared: Blender writes custom properties there, exporters leave
 notes. A tool that replaces the whole object to add its own key deletes theirs,
 and nothing reports it — the file still loads, it has just quietly lost
 somebody's data.
*>
fn void an_extra_does_not_clobber_its_neighbours() @test
{
	String text = `{"extras":{"blender":"3.6"},"scene":0}`;

	gltf_edit::JsonStep[2] mine = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = "crig" } };
	gltf_edit::JsonEdit[1] edits = { { .path = mine[..], .value = `{"version":6}` } };

	String out = gltf_edit::patch_gltf_text(mem, text, edits[..])!!;
	defer out.free(mem);

	gltf_edit::JsonStep[2] theirs = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = "blender" } };
	test::@check(gltf_edit::read_gltf_member(out, theirs[..]) == `"3.6"`, "got %s", gltf_edit::read_gltf_member(out, theirs[..]));
	test::@check(gltf_edit::read_gltf_member(out, mine[..]) == `"{\"version\":6}"`, "got %s", gltf_edit::read_gltf_member(out, mine[..]));
}

// The one-call form over a real file, with the buffer still intact after it.
fn void patching_a_file_in_place() @test
{
	char[] source = file::load(mem, TRUCK)!!;
	defer free(source);

	String path = "build/gltf-edit-truck-patched.glb";
	file::save(path, source)!!;
	defer (void)file::delete(path);

	gltf_edit::patch_extra(mem, path, "crig", `{"version":6,"reach":{"hips":0.25}}`)!!;

	gltf_edit::GlbParts before = gltf_edit::split_glb(mem, TRUCK)!!;
	defer before.free(mem);
	gltf_edit::GlbParts after = gltf_edit::split_glb(mem, path)!!;
	defer after.free(mem);

	test::@check(@same_bytes(before.rest, after.rest), "the buffer chunk is untouched");

	// Read back through the ordinary parser, which is how a consumer gets it: the
	// extras map is string-valued, so a structured payload rides as its own text.
	gltf::GltfStream stream = gltf::open(path)!!;
	defer stream.close();
	test::@check(stream.gltf.extras.get("crig")!! == `{"version":6,"reach":{"hips":0.25}}`);
	test::@check(stream.gltf.meshes.len() > 0, "and it is still a glTF");
}

<*
 Numbers come back as the numbers they went in as.

 The check that says why the text is spliced rather than reprinted: `%g` gives six
 significant digits, so a node translation reprinted through it is wrong in the
 fourth decimal place and wrong everywhere in the model.
*>
fn void a_double_survives_being_written() @test
{
	double[4] awkward = { 0.352910727, 1.0 / 3.0, 1.0e-8, 123456789.123456789 };

	foreach (value : awkward)
	{
		DString out = dstring::new(mem);
		defer out.free();
		gltf_edit::write_json_double(&out, value);

		double back = out.str_view().to_double()!!;
		test::@check(back == value, "%s did not round-trip", out.str_view());
	}

	// Readable where it can be: a value that needs no digits does not get
	// seventeen of them.
	DString half = dstring::new(mem);
	defer half.free();
	gltf_edit::write_json_double(&half, 0.5);
	test::@check(half.str_view() == "0.5", "got %s", half.str_view());

	// And nothing that cannot be JSON.
	DString bad = dstring::new(mem);
	defer bad.free();
	gltf_edit::write_json_double(&bad, (double)(0.0 / 0.0));
	test::@check(bad.str_view() == "null", "got %s", bad.str_view());
}

<*
 The same for a float, and the reason it is not the double writer with a cast.

 A float widened to double round-trips through nine digits at most, but the
 *double* it widened to needs seventeen — so the digits past the ninth are the
 only difference between the two writers, and they say nothing a reader can use.
*>
fn void a_float_survives_being_written() @test
{
	float[4] awkward = { 0.12267040f, 1.0f / 3.0f, 1.0e-8f, 12345.6789f };

	foreach (value : awkward)
	{
		DString out = dstring::new(mem);
		defer out.free();
		gltf_edit::write_json_float(&out, value);

		float back = out.str_view().to_float()!!;
		test::@check(back == value, "%s did not round-trip", out.str_view());
	}

	// Shorter than the same value through the double writer, which is the point.
	DString shorter = dstring::new(mem);
	defer shorter.free();
	gltf_edit::write_json_float(&shorter, 0.12267040f);
	test::@check(shorter.str_view() == "0.1226704", "got %s", shorter.str_view());

	DString half = dstring::new(mem);
	defer half.free();
	gltf_edit::write_json_float(&half, 0.5f);
	test::@check(half.str_view() == "0.5", "got %s", half.str_view());

	DString bad = dstring::new(mem);
	defer bad.free();
	gltf_edit::write_json_float(&bad, (float)(0.0 / 0.0));
	test::@check(bad.str_view() == "null", "got %s", bad.str_view());

	// The vector forms are arrays of the same numbers.
	DString vectors = dstring::new(mem);
	defer vectors.free();
	vectors.appendf("%s %s", (gltf_edit::JsonVec3)(Vec3){ 0.12267040f, 0.5f, (float)(0.0 / 0.0) },
		(gltf_edit::JsonQuat)(Quaternionf){ 0.0f, 0.0f, 1.0f / 3.0f, 1.0f });
	test::@check(vectors.str_view() == "[0.1226704,0.5,null] [0,0,0.33333334,1]", "got %s", vectors.str_view());
}

// The escapes JSON names, and the control characters it does not.
fn void a_string_is_escaped() @test
{
	DString out = dstring::new(mem);
	defer out.free();

	gltf_edit::escape_json_string(&out, "Glass \"front\"\\back\n\x01 é");
	test::@check(out.str_view() == `"Glass \"front\"\\back\n\u0001 é"`, "got %s", out.str_view());
}

<*
 A key of the same name nested inside something else is not the root's.

 `extras` occurs on nodes, on meshes, on primitives; `name` occurs a thousand
 times. A scanner that matched the first one it saw would edit whichever happened
 to come first in the file, which is a different member on every asset.
*>
fn void a_nested_key_of_the_same_name_is_not_matched() @test
{
	String text = `{"nodes":[{"extras":{"deep":"no"}}],"scene":0}`;

	gltf_edit::JsonStep[2] root = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = "top" } };
	gltf_edit::JsonEdit[1] edits = { { .path = root[..], .value = "yes" } };

	String out = gltf_edit::patch_gltf_text(mem, text, edits[..])!!;
	defer out.free(mem);

	test::@check(out == `{"extras":{"top":"yes"},"nodes":[{"extras":{"deep":"no"}}],"scene":0}`, "got %s", out);

	// And the nested one is still exactly where it was.
	gltf_edit::JsonStep[3] nested = { { .key = "nodes" }, { .at = 0 }, { .key = "extras" } };
	test::@check(gltf_edit::read_gltf_member(out, nested[..]) == `{"deep":"no"}`, "got %s", gltf_edit::read_gltf_member(out, nested[..]));
}

<*
 Braces and brackets inside a string close nothing.

 Texture URIs, material names and copyright strings all carry punctuation, and a
 scanner that counted depth without knowing where the strings are would lose its
 place partway through the file and edit at an offset that means nothing.
*>
fn void punctuation_inside_a_string_is_not_structure() @test
{
	String text = `{"images":[{"uri":"a}b],c\"d"}],"scene":"7"}`;

	gltf_edit::JsonStep[1] scene = { { .key = "scene" } };
	test::@check(gltf_edit::read_gltf_member(text, scene[..]) == `"7"`, "got %s", gltf_edit::read_gltf_member(text, scene[..]));

	gltf_edit::JsonStep[3] uri = { { .key = "images" }, { .at = 0 }, { .key = "uri" } };
	test::@check(gltf_edit::read_gltf_member(text, uri[..]) == `"a}b],c\"d"`, "got %s", gltf_edit::read_gltf_member(text, uri[..]));
}

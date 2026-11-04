<*
 Editing a clip through any door lands it the same way. See rules/clips.md.
*>
module crig_tests::clip_landing;

import crig;
import crig_tests::mcp;
import crig_tests::shared_app;
import std::core::test;

struct LibraryEdit @local
{
	String tool;
	String args;
}

const LibraryEdit[*] EDITS @local = {
	{ "patch_clip", `{"clip":"Walk","joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.1}}]}` },
	{ "set_layer", `{"clip":"Walk","layer":{"name":"Lean","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}}` },
	{ "retime_clip", `{"clip":"Walk","duration":3.0}` },
	{ "smooth_clip", `{"clip":"Walk","window":0.1}` },
};

fn usz rows_named(AppState* app, String name) @local
{
	usz rows;
	foreach (row : app.doc.animations.array_view()) if (row.clip == name) rows++;
	return rows;
}

// A library clip, edited: one row still, and that row is the edit.
fn void editing_a_library_clip_keeps_one_row() @test
{
	foreach (edit : EDITS)
	{
		Fixture* f = mem::new(Fixture);
		defer free(f);
		f.open();
		defer f.close();
		DString why = dstring::new(mem);
		defer why.free();
		AnimRef ref = crig::resolve_named(&f.app, "Walk", &why)!!;
		test::@check(f.app.bind_ref(ref), "the clip bound");
		test::@check(rows_named(&f.app, "Walk") == 1, "the rig binds it once");

		String raw = f.server.handle_message(string::tformat(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}`, edit.tool, edit.args));
		defer raw.free(mem);
		test::@check(!raw.contains(`"error"`), "%s refused: %s", edit.tool, raw[:raw.len < 240 ? raw.len : 240]);
		test::@check(rows_named(&f.app, "Walk") == 1, "%s left %s rows", edit.tool, rows_named(&f.app, "Walk"));

		// What saves is the edit, not the library's original.
		AnimRef bound = f.app.resolve_bound(0);
		test::@check(bound.pack == f.app.authored_pack, "%s left the row on the library clip", edit.tool);
	}
}

// A copy of a library clip speaks the rig's words, whichever door made it.
fn void a_copy_of_a_library_clip_keeps_moving_its_joints() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	f.open();
	defer f.close();
	DString why = dstring::new(mem);
	defer why.free();
	AnimRef ref = crig::resolve_named(&f.app, "Walk", &why)!!;
	AnimRef copy = f.app.duplicate_clip(ref, "Walk copy");
	test::@check(copy.pack == f.app.authored_pack, "the copy is authored");
	test::@check(f.app.editing.same(copy), "the copy is being edited");
	test::@check(rows_named(&f.app, "Walk copy") == 1, "the copy is bound once");
}

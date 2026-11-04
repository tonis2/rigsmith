<*
 Every edit undoes, redoes and saves exactly, on a real rig.

 One table instead of one test per door: a step a new edit forgets shows up here
 whichever tool it came in through. See rules/editing.md.
*>
module crig_tests::every_edit;

import crig;
import crig_tests::mcp;
import std::core::test;
import std::io;
import std::math;

const String MODEL @local = "assets/animations/humanoid.glb";

struct Edit @local
{
	String tool;
	String args;
	String setup_tool; // run first and undone last, for an edit that needs something to act on
	String setup_args;
}

const String KEYED_LAYER @local = `{"clip":"Base","layer":{"name":"Lean","kind":"keyed","keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}}`;

const Edit[*] EDITS @local = {
	{ "edit_rig", `{"ops":[{"op":"symmetry","plane":0.25}]}`, "", "" },
	{ "edit_rig", `{"ops":[{"op":"grow","joint":"knee_L","grow":0.1,"soft":0.8}]}`, "", "" },
	{ "edit_rig", `{"ops":[{"op":"reach","joint":"knee_L","reach":0.25}]}`, "", "" },
	{ "edit_rig", `{"ops":[{"op":"exclude","a":"hips","b":"head"}]}`, "", "" },
	{ "set_secondary_motion", `{"chains":[{"root":"head_top"}]}`, "", "" },
	{ "scale_model", `{"factor":2}`, "", "" },
	{ "paint_weights", `{"dot":"knee_L","weight":0.1,"vertices":[0,1,2,3]}`, "", "" },
	{ "pin_weights", `{"dot":"knee_L","vertices":[0,1,2,3]}`, "", "" },
	{ "save_pose", `{"name":"Start","clip":"Base","t":0}`, "", "" },
	{ "delete_pose", `{"pose":"Start"}`, "save_pose", `{"name":"Start","clip":"Base","t":0}` },
	{ "tween_poses", `{"from":"Start","to":"Start","name":"Between","duration":0.8}`, "save_pose", `{"name":"Start","clip":"Base","t":0}` },
	{ "apply_clip", `{"name":"Fresh","duration":1,"keyframes":[{"time":0,"joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}]}`, "", "" },
	{ "import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Run","name":"Second"}`, "", "" },
	{ "bake_physics", `{"clip":"Base","name":"Base baked","hz":30}`, "set_secondary_motion", `{"chains":[{"root":"head_top"}]}` },
	{ "patch_clip", `{"clip":"Base","joints":[{"name":"chest","rotation":{"axis":[1,0,0],"angle":0.1}}]}`, "", "" },
	{ "duplicate_clip", `{"clip":"Base","name":"Base copy"}`, "", "" },
	{ "delete_clip", `{"clip":"Base"}`, "", "" },
	{ "unbind_clip", `{"clip":"Base"}`, "", "" },
	{ "author_gait", `{"name":"Stride","duration":1.1,"gait":"walk"}`, "", "" },
	{ "set_layer", KEYED_LAYER, "", "" },
	{ "merge_layers", `{"clip":"Base"}`, "set_layer", KEYED_LAYER },
	{ "blend_in", `{"name":"Into","clip":"Base"}`, "", "" },
	{ "set_aim_target", `{"clip":"Base","name":"Look","at":[0,1.5,1]}`, "", "" },
	{ "set_aim", `{"clip":"Base","joint":"head","target":"Look"}`, "set_aim_target", `{"clip":"Base","name":"Look","at":[0,1.5,1]}` },
	{ "set_path", `{"clip":"Base","path":{"joint":"wrist_L","name":"Arc","points":[{"at":[0.3,0.6,0]},{"at":[0.3,0.8,0.2]}]}}`, "", "" },
	{ "set_pins", `{"clip":"Base","pins":[{"joint":"ankle_L","from":0,"to":0.2}]}`, "", "" },
	{ "pin_feet", `{"clip":"Base"}`, "", "" },
	{ "trim_clip", `{"clip":"Base","keep":[0.1,0.5]}`, "", "" },
	{ "retime_clip", `{"clip":"Base","duration":3.0}`, "", "" },
	{ "optimize_clip", `{"clip":"Base","strength":"strong"}`, "", "" },
	{ "remove_movement", `{"clip":"Base","mode":"in_place","vertical":true}`, "", "" },
	{ "remove_keys", `{"clip":"Base","joints":["knee_L"]}`, "", "" },
	{ "smooth_clip", `{"clip":"Base","window":0.1}`, "", "" },
	{ "make_loop", `{"clip":"Base","name":"Looped","whole":true,"crossfade":0.2}`, "", "" },
	{ "pose_joint", `{"clip":"Base","joint":"hips","move":[0,-0.1,0]}`, "", "" },
};

// Everything else in the tool table, and why it isn't a row above.
const String[2][*] EXCUSED @local = {
	{ "focus_character", "changes the view" }, { "get_scene", "reads" }, { "get_skeleton", "reads" }, { "get_pose", "reads" },
	{ "measure_clip", "reads" }, { "get_clip", "reads" }, { "list_poses", "reads" },
	{ "get_saved_pose", "reads" }, { "get_annotations", "reads" }, { "get_weights", "reads" },
	{ "get_shells", "reads" }, { "get_api_docs", "reads" }, { "get_crig_docs", "reads" },
	{ "get_paths", "reads" }, { "get_aims", "reads" }, { "get_pins", "reads" },
	{ "find_contacts", "reads" }, { "plugins", "reads" },
	{ "show_weights", "changes the view" }, { "play", "changes the view" }, { "stop", "changes the view" },
	{ "set_camera", "changes the view" }, { "screenshot", "changes the view" }, { "render", "changes the view" },
	{ "render_poses", "writes pictures" }, { "render_studio", "writes pictures" },
	{ "capture", "runs an outside job" }, { "generate_motion", "runs an outside job" },
	{ "save_pack", "writes a file" }, { "save_project", "writes a file" },
	{ "delete_model_clip", "rewrites the model file, which undo can't reach" },
	{ "apply_plan", "needs a pack with a body; plan_limits_test covers it" },
	{ "fix_strays", "needs a rig with strays; weights_test covers it" },
	{ "fix_tears", "needs a rig with tears; weights_test covers it" },
	{ "solve_targets", "answers a pose; it edits nothing" },
	{ "build_body", "builds a mesh, which the document doesn't hold" },
	{ "close_loop", "needs a clip with an open seam; mcp_test covers it" },
	{ "add_character", "changes the scene, not a document" }, { "remove_character", "changes the scene, not a document" },
	{ "open_scene", "changes the scene, not a document" }, { "save_scene", "writes a file" }, { "export_scene", "writes a file" },
	{ "undo", "is what this checks" }, { "redo", "is what this checks" },
};

// The whole document and the authored clips, as the session file writes them.
fn String print_of(AppState* app) @local
{
	AnimPack* pack = app.authored();
	return crig::session_text(mem, &app.doc, "", pack ? pack.clips : {}, limits: true);
}

fn void step(Fixture* f, String tool) @local
{
	String? answer = f.call_tool_text(tool, "{}");
	if (try answer) answer.free(mem);
}

// Whether two prints match, numbers to within reading's rounding: a limit frame
// is normalised as it loads, which can move its last digit.
fn bool same_print(String a, String b) @local
{
	usz i;
	usz j;
	while (i < a.len && j < b.len)
	{
		if (a[i] == b[j])
		{
			i++;
			j++;
			continue;
		}
		usz from_a = i;
		usz from_b = j;
		while (from_a > 0 && number_char(a[from_a - 1])) from_a--;
		while (from_b > 0 && number_char(b[from_b - 1])) from_b--;
		while (i < a.len && number_char(a[i])) i++;
		while (j < b.len && number_char(b[j])) j++;
		if (i == from_a || j == from_b) return false;
		double? p = a[from_a..i - 1].to_double();
		double? q = b[from_b..j - 1].to_double();
		if (catch p, q) return false;
		if (math::abs(p - q) > 1.0e-6) return false;
	}
	return i == a.len && j == b.len;
}

fn bool number_char(char c) @local => c.is_digit() || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E';

// The same print, after a trip through the session reader.
fn String reread(String print) @local
{
	RigDocument? doc = crig::parse_session(mem, print);
	if (catch doc) return "";
	defer doc.free();
	AnimTemplate[]? clips = crig::parse_session_clips(mem, print);
	if (catch clips) return "";
	defer
	{
		foreach (&clip : clips) clip.free(mem);
		alloc::free(mem, clips);
	}
	return crig::session_text(mem, &doc, "", clips, limits: true);
}

fn bool listed(String tool) @local
{
	foreach (edit : EDITS) if (edit.tool == tool) return true;
	foreach (excuse : EXCUSED) if (excuse[0] == tool) return true;
	return false;
}

// A new tool has to be a row, or say why not.
fn void every_tool_is_swept_or_excused() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	f.open_bare();
	defer f.close();
	for (usz i = 0; i < f.tools.tools_len; i++)
	{
		String name = f.tools.tools[i].name;
		test::@check(listed(name), "%s is neither swept nor excused", name);
	}
}

fn void every_edit_undoes_redoes_and_saves() @test
{
	DString out = dstring::new(mem);
	defer out.free();
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(MODEL)) return;
	defer f.close();
	String? base = f.call_tool_text("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Base"}`);
	if (catch base)
	{
		test::@check(false, "the base clip did not import");
		return;
	}
	base.free(mem);

	foreach (edit : EDITS)
	{
		if (edit.setup_tool.len > 0)
		{
			String? ready = f.call_tool_text(edit.setup_tool, edit.setup_args);
			if (catch ready)
			{
				out.appendf("%s: setup %s refused\n", edit.tool, edit.setup_tool);
				continue;
			}
			ready.free(mem);
		}
		String before = print_of(&f.app);
		defer before.free(mem);

		String? answer = f.call_tool_text(edit.tool, edit.args);
		if (catch answer)
		{
			out.appendf("%s: refused\n", edit.tool);
		}
		else
		{
			answer.free(mem);
			String after = print_of(&f.app);
			defer after.free(mem);
			if (after == before)
			{
				out.appendf("%s: changed nothing\n", edit.tool);
				if (edit.setup_tool.len > 0) step(f, "undo");
				continue;
			}

			String saved = reread(after);
			defer saved.free(mem);
			if (!same_print(saved, after)) out.appendf("%s: lost in the session file\n", edit.tool);

			step(f, "undo");
			String undone = print_of(&f.app);
			defer undone.free(mem);
			if (undone != before) out.appendf("%s: undo differs\n", edit.tool);

			step(f, "redo");
			String redone = print_of(&f.app);
			defer redone.free(mem);
			if (redone != after) out.appendf("%s: redo differs\n", edit.tool);

			step(f, "undo");
		}
		if (edit.setup_tool.len > 0) step(f, "undo");
	}
	test::@check(out.len() == 0, "%s", out.str_view());
}

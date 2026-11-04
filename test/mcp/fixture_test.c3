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
// Fixture

<*
 A cube, a three-dot chain plus one unnamed free dot, the real animation
 library, and the MCP server over all of it.

 Opened through a pointer, never returned by value: the server's tool
 handlers keep the `AppState*`, so moving the AppState afterwards leaves
 them reading dead stack.
*>
struct Fixture
{
	crig::AppState app;
	// The one registry, and a server built over it. crig's tools stopped being an
	// `mcp::Server` when the plugin took over — three registers them now — so the
	// table is what `new_tool_table` answers and `serve_table` is the executable's
	// bridge from it, shared with these checks so that both drive the same list.
	crig::ToolTable tools;
	mcp::Server server;
	// The model's mesh when the fixture opened a .glb (`open_model`); the app only
	// borrows it, so it is freed after the app.
	rig::TriMesh mesh;
}

fn void Fixture.open(&self)
{
	self.app = shared_app::open_cube();

	uint hips = self.app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = self.app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = self.app.doc.add_dot({ 0, 0, 0 }, "foot");
	self.app.doc.connect(hips, knee);
	self.app.doc.connect(knee, foot);
	// Unconnected and unnamed: joints list it as a second root named bone_<id>.
	self.app.doc.add_dot({ 0.5, 0.25, 0 });

	shared_app::attach_all_packs(&self.app);
	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
}

<*
 The same fixture with no mesh and no dots — the state crig opens in, and
 the one an agent asks about first. `build_skeleton` faults NO_DOTS there,
 and the answer still has to be JSON a client can parse.
*>
fn void Fixture.open_bare(&self)
{
	self.app = crig::new_app({});
	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
}

<*
 A rig whose dots are named after nothing in the library.

 The hips-knee-foot fixture can play most of what is on disk, and every clip it
 cannot play is one of the three called "Idle" — which is refused for the name
 being ambiguous, before the rig is ever consulted. A rig sharing no name with
 any pack is what leaves a uniquely-named clip genuinely out of reach.
*>
fn void Fixture.open_stranger(&self)
{
	self.app = shared_app::open_cube();

	uint alpha = self.app.doc.add_dot({ 0, 1, 0 }, "alpha");
	uint beta = self.app.doc.add_dot({ 0, 0.5, 0 }, "beta");
	self.app.doc.connect(alpha, beta);

	shared_app::attach_all_packs(&self.app);
	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
}

// Where the save checks are allowed to write. Not the real library: a test that
// left files in assets/animations would change what every other check reads, and
// what crig ships with.
const String SAVE_DIRECTORY = "build/mcp-packs";

<*
 A rig every dot of which is named, over a library folder of its own.

 Both halves are needed to save: a pack keys its clips on joint names, so the
 unnamed dot the ordinary fixture carries would refuse the write — deliberately,
 and that refusal is checked separately.
*>
fn void Fixture.open_saver(&self)
{
	// Made and emptied here rather than once for the run: these checks assert
	// what a pack holds, and a file left by another check — or by an earlier
	// run — would be counted as this one's work.
	if (catch path::mkdir((Path)SAVE_DIRECTORY))
	{
		// Already there, which is the ordinary case on a second run.
	}
	discard_saved_packs();

	self.app = shared_app::open_cube();

	uint hips = self.app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = self.app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = self.app.doc.add_dot({ 0, 0, 0 }, "foot");
	self.app.doc.connect(hips, knee);
	self.app.doc.connect(knee, foot);

	self.app.load_packs(SAVE_DIRECTORY);
	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
}

<*
 The fixture with the clips the library and playback checks read.

 Those checks were written as one narrative over a single fixture: the first
 authored `bend`, the next three authored a clip per rotation form, and
 everything after read what they left behind. `c3c test` runs checks in name
 order, so the narrative is reproduced here instead — each check gets the state
 it needs rather than the state its neighbour happened to leave.

 The two checks that assert the authoring itself — `apply_clip_answers_where_the_clip_landed`
 and `the_three_rotation_forms_agree` — open a plain fixture, since a clip
 already in the library is the one thing they must not start with.
*>
fn void Fixture.open_authored(&self)
{
	self.open();

	String[4] names = { "bend", "as_axis", "as_quaternion", "as_euler" };
	String[4] rotations = { QUARTER_TURN_AXIS, QUARTER_TURN_AXIS, QUARTER_TURN_QUAT, QUARTER_TURN_EULER };

	foreach (i, name : names)
	{
		String arguments = bend_clip(name, rotations[i]);
		defer alloc::free(mem, arguments);

		Object*? applied = self.call_tool("apply_clip", arguments);
		if (catch applied)
		{
			test::@check(false, "the fixture could not author %s", name);
			return;
		}
		applied.free();
	}
}

<*
 Author one clip and save it into the pack, reporting whether both took.

 Returns false having already failed the calling test.
*>
fn bool Fixture.save_one(&self, String clip, String rotation)
{
	String arguments = bend_clip(clip, rotation);
	defer alloc::free(mem, arguments);

	Object*? applied = self.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture would not take %s", clip);
		return false;
	}
	applied.free();

	Object*? saved = self.call_tool("save_pack", `{"name":"Kit"}`);
	if (catch saved)
	{
		test::@check(false, "the saver fixture would not save %s", clip);
		return false;
	}
	saved.free();
	return true;
}

<*
 The fixture the playback checks read: the four authored clips, with `bend`
 rewritten to the three-second one-shot they expect.

 The rewrite is `rewriting_the_running_clip_restarts_it`'s doing in the original
 narrative, and every play and stop check downstream was reading its result.
*>
fn void Fixture.open_played(&self)
{
	self.open_authored();

	Object*? applied = self.call_tool("apply_clip",
		`{"name":"bend","duration":3,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0,0,0]}]},{"time":1.5,"joints":[{"name":"knee","rotation":[0.25,0,0]}]}]}`);
	if (catch applied)
	{
		test::@check(false, "the fixture could not rewrite bend to its played length");
		return;
	}
	applied.free();
}

<*
 The fixture with one authored clip and nothing else, for the checks that count
 what a single `apply_clip` put in the library.
*>
fn void Fixture.open_one_clip(&self)
{
	self.open();

	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);

	Object*? applied = self.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the fixture could not author bend");
		return;
	}
	applied.free();
}

<*
 The fixture with `bend` on screen, wrapped to 1.5 by a looping play.

 Two checks are about what happens to a player that is already running — a
 refusal that must disturb nothing, and a stop that must name what it took off
 the screen — so what they need is not a library but a live player.
*>
fn void Fixture.open_playing(&self)
{
	self.open_played();

	Object*? played = self.call_tool("play", `{"clip":"bend","t":7.5,"loop":true}`);
	if (catch played)
	{
		test::@check(false, "the fixture could not start bend playing");
		return;
	}
	played.free();
}

fn void Fixture.close(&self)
{
	self.app.free();
	self.mesh.free(mem);
}

<*
 Opens a model from assets/animations with the rig it carries, and serves the
 tools over it. False, with a failed check, when the rig would not import.
*>
fn bool Fixture.open_model(&self, String path)
{
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	self.app.adopt_source_rig();
	if (self.app.doc.dots.len() == 0)
	{
		test::@check(false, "%s would not import its rig", path);
		self.close();
		return false;
	}
	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
	return true;
}

<*
 One JSON-RPC round trip. The response is parsed and returned; the caller
 frees it. Faults NOT_FOUND when the server answered with nothing — the
 notification case, which check_the_notification_passes_silently wants.
*>
fn Object*? Fixture.request(&self, String message)
{
	String response = self.server.handle_message(message);
	if (response.len == 0) return NOT_FOUND~;
	defer alloc::free(mem, response);
	return json::parse(mem, response);
}

<*
 One tools/call round trip, unwrapped: the response must be a result whose
 first content text itself parses as JSON. An error response faults
 TOOL_ERROR — the checks that expect an error read the raw response instead.
*>
fn Object*? Fixture.call_tool(&self, String name, String arguments)
{
	String message = string::format(
		mem,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}`,
		name,
		arguments);
	defer alloc::free(mem, message);

	Object* root = self.request(message)!;
	defer root.free();
	Object*? result = root.get("result");
	if (catch result) return TOOL_ERROR~;
	Object*? content = result.get("content");
	if (catch content) return TOOL_ERROR~;
	if (content.get_len() == 0) return TOOL_ERROR~;
	String? text = content.get_at(0).get_string("text");
	if (catch text) return TOOL_ERROR~;
	return json::parse(mem, text);
}

<*
 The same round trip, as the text the tool actually returned.

 `call_tool` parses and throws the text away, which is right for almost every
 check — but a *round trip* has to feed one tool's output to another's input
 verbatim, and re-serialising a parsed object would be testing the test's writer
 rather than the tool's.

 The caller owns the returned string.
*>
fn String? Fixture.call_tool_text(&self, String name, String arguments)
{
	String message = string::format(
		mem,
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}`,
		name,
		arguments);
	defer alloc::free(mem, message);

	Object* root = self.request(message)!;
	defer root.free();
	Object*? result = root.get("result");
	if (catch result) return TOOL_ERROR~;
	Object*? content = result.get("content");
	if (catch content) return TOOL_ERROR~;
	if (content.get_len() == 0) return TOOL_ERROR~;
	String? text = content.get_at(0).get_string("text");
	if (catch text) return TOOL_ERROR~;
	return text.copy(mem);
}

faultdef TOOL_ERROR;

fn bool error_code_is(Object* root, int code)
{
	Object*? error = root.get("error");
	if (catch error) return false;
	int? actual = error.get_int("code");
	if (catch actual) return false;
	return actual == code;
}

fn bool error_message_contains(Object* root, String needle)
{
	Object*? error = root.get("error");
	if (catch error) return false;
	String? message = error.get_string("message");
	if (catch message) return false;
	return message.contains(needle);
}

// ---------------------------------------------------------------------------

fn bool? initialize_body(Object* root)
{
	Object* result = root.get("result")!;
	String version = result.get_string("protocolVersion")!;
	String name = result.get("serverInfo")!.get_string("name")!;
	return version == "2025-03-26" && name == "crig";
}

fn void initialize() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`);
	if (catch root)
	{
		test::@check(false, "initialize answers");
		return;
	}
	defer root.free();
	test::@check(initialize_body(root) ?? false, "initialize echoes the protocol version and names the server");
}

// Every tool the surface registers, listed or not. The length is asserted as well
// as the contents, so a tool added without a line here fails rather than passing
// unnoticed — which is what makes this table worth keeping by hand.
String[76] tool_names = {
	"get_scene", "get_skeleton", "get_pose", "get_weights", "paint_weights",
	"pin_weights", "fix_strays", "fix_tears",
	"get_shells", "measure_clip", "get_clip", "apply_clip", "bake_physics",
	"delete_clip", "apply_plan", "edit_rig", "set_secondary_motion", "build_body",
	"undo", "redo", "play", "stop", "show_weights", "save_pack", "screenshot",
	"render", "set_camera", "get_api_docs", "get_crig_docs", "save_project",
	"solve_targets", "patch_clip", "trim_clip", "retime_clip", "optimize_clip", "remove_movement",
	"close_loop", "smooth_clip", "make_loop", "remove_keys", "list_poses", "get_saved_pose",
	"save_pose", "delete_pose", "tween_poses", "get_annotations",
	"generate_motion", "unbind_clip", "delete_model_clip", "author_gait", "set_layer", "get_paths", "set_path", "merge_layers",
	"get_pins", "set_pins", "pin_feet", "find_contacts", "pose_joint", "scale_model", "get_aims", "set_aim_target", "set_aim",
	"focus_character", "add_character", "remove_character", "save_scene", "open_scene", "export_scene",
	"import_clip", "render_poses", "render_studio", "capture", "plugins", "duplicate_clip", "blend_in",
};

// The server the app boots with holds three's own tools and all of crig's, and
// `mcp::Server` keeps them in a fixed array whose overflow is an abort at launch —
// which no test that drives the tool table directly would see. Built here the way
// `main` builds it, with room still to spare. The widened schemas go on the temp
// allocator here; in `main` they live as long as the run.
fn void the_boot_server_holds_every_tool() @test
{
	crig::AppState app;
	three::ToolHost host = { };
	mcp::Server server = three::new_mcp_server(&host);
	crig::install_tools(&app, &server, tmem);
	test::@check(server.tools_len + 16 <= mcp::MAX_TOOLS,
		"the boot server holds %d tools of %d; raise mcp::MAX_TOOLS before the next one aborts the launch",
		server.tools_len, mcp::MAX_TOOLS);
}

// The ones `tools/list` reports. The rest are `hidden` — dispatched exactly as
// before, by name, because their schemas cost every session that never uses them;
// `new_mcp_server` carries the argument. Under three they are reached from a
// script as `crig.ops.<name>`; on the wire they are called directly. (In the
// shipped executable three owns `screenshot` and `get_api_docs`, so crig's own of
// those two are suppressed and its listed set is get_scene, get_crig_docs, undo
// and redo; here, headless, `hosted()` is false and crig registers its own.)
//
// Kept as a second table rather than a flag on the first, because the two are
// asserted against different things: this one against what a client is told, that
// one against what the server can do.
String[16] listed_tools = {
	"get_scene", "screenshot", "undo", "redo", "get_api_docs", "get_crig_docs", "measure_clip",
	"solve_targets", "get_annotations", "list_poses", "get_saved_pose", "tween_poses",
	"focus_character", "set_camera", "render", "import_clip",
};

fn bool? tools_list_body(Object* root)
{
	Object* tools = root.get("result")!.get("tools")!;
	if (tools.get_len() != listed_tools.len) return false;

	foreach (wanted : listed_tools)
	{
		bool found = false;
		for (sz i = 0; i < tools.get_len(); i++)
		{
			if (tools.get_at(i).get_string("name")! == wanted) found = true;
		}
		if (!found) return false;
	}
	return true;
}

fn void tools_list() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`);
	if (catch root)
	{
		test::@check(false, "tools/list answers");
		return;
	}
	defer root.free();
	test::@check(tools_list_body(root) ?? false, "tools/list names the listed tools and nothing else");
}

<*
 A hidden tool is unlisted, not unavailable.

 The whole of what the flag is allowed to mean. `tools/list` leaves `edit_rig` out
 and `tools/call` places a dot with it, in the same fixture, one after the other —
 because a flag that quietly disabled a handler would break the wire for every
 client that already knew the name, and there would be no other sign of it.
*>
fn void a_hidden_tool_is_still_called() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? listed = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
	if (catch listed)
	{
		test::@check(false, "tools/list answers");
		return;
	}
	defer listed.free();

	bool named = false;
	Object*? tools = listed.get("result").get("tools");
	if (try tools)
	{
		for (sz i = 0; i < tools.get_len(); i++)
		{
			if ((tools.get_at(i).get_string("name") ?? "") == "edit_rig") named = true;
		}
	}
	test::@check(!named, "a hidden tool is not in the list a client is handed");

	Object*? placed = f.call_tool("edit_rig",
		`{"ops":[{"op":"place","position":[0.5,0,0],"name":"toe","connect_to":"foot"}]}`);
	if (catch placed)
	{
		test::@check(false, "and the wire still dispatches to it");
		return;
	}
	defer placed.free();
	test::@check((placed.get_int("dots") ?? 0) == (int)FIXTURE_DOTS + 1,
		"and the wire still dispatches to it");
}

fn bool? scene_body(Object* scene)
{
	Object* mesh = scene.get("mesh")!;
	bool ok = mesh.get_int("vertices")! == 8;
	ok = ok && mesh.get_int("triangles")! == 12;
	ok = ok && mesh.get_bool("has_normals")! == false;

	Object* bounds = scene.get("bounds")!;
	Object* min = bounds.get("min")!;
	ok = ok && min.get_float_at(0)! == -1.0 && min.get_float_at(1)! == -1.0;

	Object* rig_info = scene.get("rig")!;
	ok = ok && rig_info.get_int("dots")! == 4;
	ok = ok && rig_info.get_int("edges")! == 2;
	ok = ok && rig_info.get_int("root")! == 1;

	Object* packs = scene.get("packs")!;
	ok = ok && packs.get_len() > 0 && packs.get_at(0).get("clips")!.get_len() > 0;

	Object* playback = scene.get("playback")!;
	ok = ok && playback.get_bool("animating")! == false;
	ok = ok && playback.get("clip")!.is_null();
	return ok;
}

fn void get_scene() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers with JSON");
		return;
	}
	defer scene.free();
	test::@check(scene_body(scene) ?? false, "get_scene carries mesh, bounds, rig, packs and playback");
}

fn bool? skeleton_body(Object* skeleton)
{
	bool ok = skeleton.get_int("root")! == 1;

	Object* dots = skeleton.get("dots")!;
	ok = ok && dots.get_len() == 4;
	ok = ok && dots.get_at(0).get_string("name")! == "hips";
	// The unnamed dot answers to bone_<id>.
	ok = ok && dots.get_at(3).get_string("name")! == "bone_4";

	Object* edges = skeleton.get("edges")!;
	ok = ok && edges.get_len() == 2;
	ok = ok && edges.get_at(0).get_int_at(0)! == 1 && edges.get_at(0).get_int_at(1)! == 2;

	// BFS from the root: hips, knee, foot, then the free dot as a second root.
	Object* joints = skeleton.get("joints")!;
	ok = ok && joints.get_len() == 4;
	ok = ok && joints.get_at(0).get_string("name")! == "hips" && joints.get_at(0).get_int("parent")! == -1;
	ok = ok && joints.get_at(1).get_string("name")! == "knee" && joints.get_at(1).get_int("parent")! == 0;
	ok = ok && joints.get_at(2).get_string("name")! == "foot" && joints.get_at(2).get_int("parent")! == 1;
	ok = ok && joints.get_at(3).get_string("name")! == "bone_4" && joints.get_at(3).get_int("parent")! == -1;

	ok = ok && math::abs(skeleton.get_float("height")! - 1.0) < 1e-4;
	return ok;
}

fn void get_skeleton() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers with JSON");
		return;
	}
	defer skeleton.free();
	test::@check(skeleton_body(skeleton) ?? false, "get_skeleton carries dots, edges, BFS joints and height");
}

// How many clips in the whole library answer to this name.
fn int name_count(crig::AppState* app, String name)
{
	int matches = 0;
	foreach (pack : app.packs)
	{
		foreach (clip : pack.clips)
		{
			if (clip.name == name) matches++;
		}
	}
	return matches;
}

<*
 The first clip name that exists in exactly one pack — get_pose rejects
 ambiguous names, so the happy-path check needs one that is not.
*>
fn String unique_clip_name(crig::AppState* app)
{
	foreach (pack : app.packs)
	{
		foreach (clip : pack.clips)
		{
			if (name_count(app, clip.name) == 1) return clip.name;
		}
	}
	return "";
}

<*
 The first uniquely-named clip on disk this rig cannot play.

 The fixture's rig is a three-dot leg, so any pack written for a real body plan
 names joints it does not have. Empty when the library holds none, which the
 caller reports rather than passing over: it means the refusal path went
 unchecked.
*>
fn String inapplicable_clip_name(crig::AppState* app)
{
	foreach (p, pack : app.packs)
	{
		foreach (c, clip : pack.clips)
		{
			if (app.clip_applies({ (int)p, (int)c })) continue;
			if (name_count(app, clip.name) == 1) return clip.name;
		}
	}
	return "";
}

fn bool? empty_skeleton_body(Object* skeleton)
{
	bool ok = skeleton.get_int("root")! == 0;
	ok = ok && skeleton.get("dots")!.get_len() == 0;
	ok = ok && skeleton.get("edges")!.get_len() == 0;
	ok = ok && skeleton.get("joints")!.get_len() == 0;
	ok = ok && skeleton.get_float("height")! == 0.0;
	return ok;
}

<*
 The empty rig, as its own fixture: `call_tool` parses the payload, so a
 skeleton that comes back malformed fails here rather than reaching a client.
*>
fn void get_skeleton_on_an_empty_rig() @test
{
	Fixture bare;
	bare.open_bare();
	defer bare.close();

	Object*? skeleton = bare.call_tool("get_skeleton", "{}");
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton on an empty rig answers with parseable JSON");
		return;
	}
	defer skeleton.free();
	test::@check(empty_skeleton_body(skeleton) ?? false, "get_skeleton on an empty rig answers with empty arrays");
}

fn bool? pose_body(Object* pose, String clip)
{
	bool ok = pose.get_string("clip")! == clip;
	Object* joints = pose.get("joints")!;
	ok = ok && joints.get_len() == 4;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* joint = joints.get_at(i);
		ok = ok && joint.get("position")!.get_len() == 3;
		Object* rotation = joint.get("rotation")!;
		ok = ok && rotation.get_len() == 4;
		// Rest or posed, a palette rotation stays unit length.
		double x = rotation.get_float_at(0)!;
		double y = rotation.get_float_at(1)!;
		double z = rotation.get_float_at(2)!;
		double w = rotation.get_float_at(3)!;
		double length = math::sqrt(x * x + y * y + z * z + w * w);
		ok = ok && math::abs(length - 1.0) < 1e-3;
	}
	return ok;
}

fn void get_pose() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	String clip = unique_clip_name(&f.app);
	if (clip.len == 0)
	{
		test::@check(false, "the library holds a uniquely-named clip");
		return;
	}

	String arguments = string::format(mem, `{"clip":"%s","t":0.3}`, clip);
	defer alloc::free(mem, arguments);
	Object*? pose = f.call_tool("get_pose", arguments);
	if (catch pose)
	{
		test::@check(false, "get_pose answers with JSON");
		return;
	}
	defer pose.free();
	test::@check(pose_body(pose, clip) ?? false, "get_pose samples every joint with unit quaternions");
}

fn void get_pose_rejects_unknown_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_pose","arguments":{"clip":"no_such_clip","t":0}}}`);
	if (catch root)
	{
		test::@check(false, "get_pose with a bad clip answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32603)
		&& error_message_contains(root, "no_such_clip")
		&& error_message_contains(root, "The library holds"),
		"get_pose on an unknown clip names it and lists the clips there are");
}

fn void get_pose_rejects_missing_arguments() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_pose"}}`);
	if (catch root)
	{
		test::@check(false, "get_pose without arguments answers");
		return;
	}
	defer root.free();
	test::@check(error_message_contains(root, `"clip"`) && error_message_contains(root, "get_scene"),
		"get_pose without arguments says which field it wanted and where to find one");
}

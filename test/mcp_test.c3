<*
 The MCP protocol and the read-only tools, with no window, no GPU and no
 socket: raw JSON-RPC strings into `mcp::Server.handle_message`, parsed
 JSON back out.

 `c3c test --trust=full --test-filter crig_tests::mcp` — run from the crig
 directory, the pack library path is
 relative.

 Worth pinning, in the order an agent hits them:

 handshake    initialize echoes the protocol version and names the server
 catalog      tools/list names the five listed tools and nothing else, a hidden
              one is still dispatched, and resources answers the api docs
 docs         get_api_docs answers with an index, one section at a time, or one
              tool's own registration — which is where the arguments of a hidden
              tool are read
 eyes         get_scene / get_skeleton / get_pose parse and carry the rig
 hands        apply_clip lands a clip in a pack of its own, replaces one of
              the same name, survives a library reload, and turns the rig by
              the arithmetic the rotation asked for
 player       play starts a clip where the user would see it, from the time
              and with the looping asked for, and stop puts it back at rest
 keeping      save_pack writes the authored clips into the library as a file
              and reads them straight back off it, and refuses every write it
              cannot make safely
 eyes again   screenshot wraps a PNG as an image block a client can decode, and
              says so plainly when there is no window to photograph
 feedback     bad JSON, unknown methods, unknown tools and bad clip names
              come back as JSON-RPC errors, not crashes — and a refused clip
              says which value was refused and what would have been taken
*>
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
// The mesh: the same 2-unit cube as ui_test — the test is about dispatch,
// not geometry. Opened through `shared_app::open_cube`, which measures it once
// for the process at a grid coarse enough that a bind is not the slowest thing
// a check does.

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
const String SAVE_DIRECTORY @local = "build/mcp-packs";

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
String[56] tool_names @local = {
	"get_scene", "get_skeleton", "get_pose", "get_weights", "paint_weights",
	"pin_weights",
	"get_shells", "measure_clip", "get_clip", "apply_clip", "bake_physics",
	"delete_clip", "apply_plan", "edit_rig", "set_secondary_motion", "build_body",
	"undo", "redo", "play", "stop", "show_weights", "save_pack", "screenshot",
	"render", "set_camera", "get_api_docs", "get_crig_docs", "save_project",
	"solve_targets", "plant_feet", "patch_clip", "list_poses", "get_saved_pose",
	"save_pose", "delete_pose", "tween_poses", "get_annotations",
	"generate_motion", "unbind_clip", "delete_model_clip", "author_gait", "set_layer", "merge_layers",
	"get_pins", "set_pins", "pose_joint", "scale_model", "get_aims", "set_aim_target", "set_aim",
	"focus_character", "add_character", "remove_character", "save_scene", "open_scene", "export_scene",
};

// The server the app boots with holds three's own tools and all of crig's, and
// `mcp::Server` keeps them in a fixed array whose overflow is an abort at launch —
// which no test that drives the tool table directly would see. Built here the way
// `main` builds it, with room still to spare.
fn void the_boot_server_holds_every_tool() @test
{
	crig::AppState app;
	three::ToolHost host = { };
	mcp::Server server = three::new_mcp_server(&host);
	crig::install_tools(&app, &server);
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
String[12] listed_tools @local = {
	"get_scene", "screenshot", "undo", "redo", "get_api_docs", "get_crig_docs",
	"solve_targets", "get_annotations", "list_poses", "get_saved_pose", "tween_poses",
	"focus_character",
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

// ---------------------------------------------------------------------------
// What the relay depends on
//
// `crig --mcp-stdio` forwards each message to the port and answers the handshake
// itself while the editor is down, out of a catalog server registered over a
// zeroed AppState. Two things have to hold for that, and neither is visible from
// the relay's own code.

fn void the_catalog_answers_with_no_document_behind_it() @test
{
	// No mesh, no dots, no library — and not even `new_app`. This is the value
	// `serve_relay` builds its catalog over, and a handler that reached into it
	// for anything would fault here rather than in front of a user.
	crig::AppState empty = {};
	crig::ToolTable catalog_tools = crig::new_tool_table(&empty);
	mcp::Server catalog = crig::serve_table(&catalog_tools, &empty);

	String response = catalog.handle_message(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
	defer alloc::free(mem, response);

	Object*? root = json::parse(mem, response);
	if (catch root)
	{
		test::@check(false, "a catalog with no document still answers tools/list as JSON");
		return;
	}
	defer root.free();

	sz listed = root.get("result").get("tools").get_len() ?? 0;
	test::@check(listed == listed_tools.len,
		"the whole catalog is a property of the build, not of the rig — so it answers before crig is up");
}

<*
 The catalog survives being written as one line.

 `send_message` frames a stdio answer as one line, and a tool's `input_schema` is
 the JSON most likely to have been typed across several — it is the part a person
 reads. Spliced into a response those newlines are legal whitespace between
 tokens, and a client reading line-delimited JSON gets a truncated first line.
 The transport replaces them, which is only safe if no two tokens in this
 server's own catalog needed one to stay apart.
*>
fn void the_catalog_survives_being_written_as_one_line() @test
{
	crig::AppState empty = {};
	crig::ToolTable catalog_tools = crig::new_tool_table(&empty);
	mcp::Server catalog = crig::serve_table(&catalog_tools, &empty);

	String response = catalog.handle_message(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`);
	defer alloc::free(mem, response);

	// The payload really does carry them, or this check would pass by proving
	// nothing — `get_api_docs`' schema is written across several lines, and it is
	// one of the five that are listed.
	bool wrapped = response.contains("\n");

	DString flat = dstring::new(mem);
	defer flat.free();
	foreach (character : response)
	{
		flat.append_char(character == '\n' || character == '\r' ? ' ' : character);
	}

	Object*? root = json::parse(mem, flat.str_view());
	if (catch root)
	{
		test::@check(false, "the catalog still parses once its newlines are spaces");
		return;
	}
	defer root.free();

	sz listed = root.get("result").get("tools").get_len() ?? 0;
	test::@check(wrapped, "the catalog is written across lines, so flattening it is a real question");
	test::@check(listed == listed_tools.len, "and every listed tool survives being flattened onto one");
}

fn void unknown_method() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":9,"method":"bogus/method"}`);
	if (catch root)
	{
		test::@check(false, "unknown method answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32601), "unknown method is -32601");
}

fn void garbage_is_a_parse_error() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":`);
	if (catch root)
	{
		test::@check(false, "garbage answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32700), "garbage is -32700");
}

fn void unknown_tool() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope","arguments":{}}}`);
	if (catch root)
	{
		test::@check(false, "unknown tool answers");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32602), "unknown tool is -32602");
}

fn bool? string_id_body(Object* root)
{
	return root.get_string("id")! == "session-7";
}

fn void string_ids_echo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":"session-7","method":"ping"}`);
	if (catch root)
	{
		test::@check(false, "ping answers");
		return;
	}
	defer root.free();
	test::@check(string_id_body(root) ?? false, "string ids echo back quoted");
}

fn void the_notification_passes_silently() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	// The no-response return is the empty string literal — nothing to free.
	String response = f.server.handle_message(`{"jsonrpc":"2.0","method":"notifications/initialized"}`);
	test::@check(response.len == 0, "a notification gets no response");
}

fn bool? resources_list_body(Object* root)
{
	Object* resources = root.get("result")!.get("resources")!;
	return resources.get_len() == 1 && resources.get_at(0).get_string("uri")! == "crig://api-docs";
}

// The version every reply carries. Asserted rather than read out of the source so
// that a change to the conventions has to be a deliberate bump, which is the only
// thing that tells a caller working from memory that the two have diverged.
const int DOCS_VERSION @local = 42;

fn bool? resources_read_body(Object* root)
{
	String text = root.get("result")!.get("contents")!.get_at(0).get_string("text")!;
	Object* docs = json::parse(mem, text)!;
	defer docs.free();
	bool ok = docs.get_int("version")! == DOCS_VERSION;
	// Every tool, hidden or not: the docs are where a hidden one is found, so a
	// tool missing from here is a tool nothing will ever call.
	ok = ok && docs.get("tools")!.get_len() == tool_names.len;
	ok = ok && docs.get_string("space")!.contains("+Y up");
	// The resource is the whole document — every section, not the index's hooks.
	ok = ok && docs.get_string("physics")!.contains("set_secondary_motion");
	ok = ok && docs.get_string("ground")!.contains("foot_slide");
	return ok;
}

fn void the_api_docs_resource() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? root = f.request(`{"jsonrpc":"2.0","id":11,"method":"resources/list"}`);
	if (catch root)
	{
		test::@check(false, "resources/list answers");
		return;
	}
	defer root.free();
	test::@check(resources_list_body(root) ?? false, "resources/list carries the api docs");

	Object*? read = f.request(`{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"crig://api-docs"}}`);
	if (catch read)
	{
		test::@check(false, "resources/read answers");
		return;
	}
	defer read.free();
	test::@check(resources_read_body(read) ?? false, "resources/read returns the versioned conventions");
}

// ---------------------------------------------------------------------------
// get_api_docs
//
// The document is twenty thousand characters and a caller almost never wants all
// of it, so it is sectioned — and the tool reference inside it is not prose kept
// here at all, but the registry rendered. Both of those are things a test has to
// hold down, because both are invisible from a reply that merely parses.

// Every section, in the order the index reports them. By hand, like `tool_names`:
// a section added without a line here fails rather than passing unnoticed.
String[17] doc_topics @local = {
	"clips", "authoring", "turning", "targets", "editing", "playback", "cycles",
	"ground", "looking", "rigging", "scripting", "weights", "physics", "review", "gaits", "layers", "pins",
};

<*
 With no arguments the docs are a menu, not the document.

 The point of the sectioning: what comes back names every section and every tool
 without carrying either one's prose, so a caller chooses what to read and pays
 for that. Both halves are asserted — the names are all there, *and* the
 descriptions are not, since an index that quietly carried them would be the
 twenty thousand characters again under a new key.
*>
fn void the_api_docs_index_is_a_menu() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String? text = f.call_tool_text("get_api_docs", "{}");
	if (catch text)
	{
		test::@check(false, "get_api_docs answers with no arguments");
		return;
	}
	defer alloc::free(mem, text);

	Object*? docs = json::parse(mem, text);
	if (catch docs)
	{
		test::@check(false, "and the index parses");
		return;
	}
	defer docs.free();

	test::@check((docs.get_int("version") ?? 0) == DOCS_VERSION, "the index is versioned");
	test::@check((docs.get_string("space") ?? "").contains("+Y up"),
		"and carries the two conventions everything else assumes");

	Object*? topics = docs.get("topics");
	if (catch topics)
	{
		test::@check(false, "and names the sections");
		return;
	}
	test::@check(topics.get_len() == doc_topics.len,
		"every section is in the index (%d of %d)", (int)topics.get_len(), doc_topics.len);
	foreach (wanted : doc_topics)
	{
		bool found = false;
		for (sz i = 0; i < topics.get_len(); i++)
		{
			if ((topics.get_at(i).get_string("name") ?? "") == wanted) found = true;
		}
		test::@check(found, "the index names the %s section", wanted);
	}

	Object*? tools = docs.get("tools");
	if (catch tools)
	{
		test::@check(false, "and names the tools");
		return;
	}
	test::@check(tools.get_len() == tool_names.len,
		"every tool is in the index, hidden or not (%d of %d)",
		(int)tools.get_len(), tool_names.len);
	bool described = false;
	for (sz i = 0; i < tools.get_len(); i++)
	{
		if (try tools.get_at(i).get_string("description")) described = true;
	}
	test::@check(!described,
		"and none of them brings its description along — that is what the tool argument is for");

	// The measurement the whole arrangement is for. `all` is the old document, and
	// the index has to be a small fraction of it or the sectioning bought nothing.
	String? whole = f.call_tool_text("get_api_docs", `{"topic":"all"}`);
	if (catch whole)
	{
		test::@check(false, "and all still answers");
		return;
	}
	defer alloc::free(mem, whole);
	test::@check(text.len * 4 < whole.len,
		"the index is a small fraction of the whole (%d against %d characters)",
		(int)text.len, (int)whole.len);
}

<*
 One section comes back on its own, and nothing else does.

 A tool that answered with everything whatever it was asked would parse, read
 correctly, and cost exactly what it cost before — so what is checked is the
 absence: the section asked for is here in full and its neighbours are not here
 at all.
*>
fn void a_topic_is_served_on_its_own() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String? text = f.call_tool_text("get_api_docs", `{"topic":"ground"}`);
	if (catch text)
	{
		test::@check(false, "get_api_docs answers for one topic");
		return;
	}
	defer alloc::free(mem, text);

	Object*? docs = json::parse(mem, text);
	if (catch docs)
	{
		test::@check(false, "and the section parses");
		return;
	}
	defer docs.free();

	test::@check((docs.get_string("topic") ?? "") == "ground", "the section says which it is");
	test::@check((docs.get_string("text") ?? "").contains("foot_slide"),
		"and carries that section's own prose");
	test::@check(!text.contains("14400"),
		"and not the physics section's");
	test::@check(!text.contains("crig.data.dots"),
		"and not the scripting section's");
}

<*
 A section that does not exist is refused by naming the ones that do.

 The failure mode a sectioned document invents: a caller that guessed "weight"
 for "weights" and has no way to find out. The refusal is the index in one
 sentence, so a wrong guess costs one retry rather than a fishing trip.
*>
fn void an_unknown_topic_names_the_real_ones() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_api_docs","arguments":{"topic":"weight"}}}`);
	if (catch root)
	{
		test::@check(false, "a bad topic answers");
		return;
	}
	defer root.free();

	test::@check(error_message_contains(root, "there is no topic called weight"),
		"the refusal says what was asked for");
	test::@check(error_message_contains(root, "weights"),
		"and names the section that was meant");
	test::@check(error_message_contains(root, "physics"),
		"and every other one");
	test::@check(error_message_contains(root, `"all"`),
		"and the way to ask for the lot");
}

<*
 A topic and a tool at once is refused rather than half-answered.

 They are different questions — a convention every tool follows against one
 tool's own arguments — and there is no reply that is both. Picking one silently
 would hand back an answer to a question the caller did not ask and give it no
 way to notice.
*>
fn void the_docs_refuse_a_topic_and_a_tool_together() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_api_docs","arguments":{"topic":"ground","tool":"apply_clip"}}}`);
	if (catch root)
	{
		test::@check(false, "asking for both answers");
		return;
	}
	defer root.free();

	test::@check(error_message_contains(root, "not both"), "and is refused in so many words");
	test::@check(error_message_contains(root, "ground") && error_message_contains(root, "apply_clip"),
		"naming both of the things it was asked for");
}

<*
 A tool name that is not a tool is refused by pointing at the index.
*>
fn void the_docs_refuse_a_name_that_is_not_a_tool() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_api_docs","arguments":{"tool":"apply_clips"}}}`);
	if (catch root)
	{
		test::@check(false, "a bad tool name answers");
		return;
	}
	defer root.free();

	test::@check(error_message_contains(root, "there is no tool called apply_clips"),
		"the refusal says what was asked for");
	test::@check(error_message_contains(root, "no arguments"),
		"and where the list of them is");
}

// ---------------------------------------------------------------------------
// get_crig_docs, save_project, and get_scene's project state
//
// The plumbing repairs of the 2026-09-18 recommendations a headless check can
// hold down: crig's documentation reachable under a name three does not own, an
// explicit project save distinct from publishing a pack, and the authored-dirty
// cue get_scene now carries. The `crig` scripting global the same repair binds is
// exercised live — it needs a JavaScript runtime these checks do not stand up —
// but its doors are `ToolTable.invoke`, driven all through this file, and this
// documentation.

<*
 crig's docs answer under get_crig_docs, the same three shapes get_api_docs does.

 The tool three's get_api_docs shadows on the shipped build, given a name of its
 own so it is reachable there too. Asserted to be that same renderer — an index
 that names every section and every tool, and one tool's schema off the registry
 — rather than a second copy that would drift.
*>
fn void get_crig_docs_answers_under_its_own_name() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String? index = f.call_tool_text("get_crig_docs", "{}");
	if (catch index)
	{
		test::@check(false, "get_crig_docs answers with no arguments");
		return;
	}
	defer alloc::free(mem, index);

	Object*? menu = json::parse(mem, index);
	if (catch menu)
	{
		test::@check(false, "and the index parses");
		return;
	}
	defer menu.free();

	test::@check((menu.get_int("version") ?? 0) == DOCS_VERSION, "the index is versioned like get_api_docs");

	Object*? topics = menu.get("topics");
	if (catch topics)
	{
		test::@check(false, "and names the sections");
		return;
	}
	test::@check(topics.get_len() == doc_topics.len, "every section is in the index");

	Object*? listed = menu.get("tools");
	if (catch listed)
	{
		test::@check(false, "and names the tools");
		return;
	}
	test::@check(listed.get_len() == tool_names.len, "every tool is in the index, hidden or not");

	// One tool's registration, off the same registry the wire validates against —
	// and get_crig_docs is itself one of the tools it can describe.
	Object*? one = f.call_tool("get_crig_docs", `{"tool":"apply_clip"}`);
	if (catch one)
	{
		test::@check(false, "get_crig_docs answers for one tool");
		return;
	}
	defer one.free();
	test::@check((one.get_string("name") ?? "") == "apply_clip", "a tool answer names the tool");
	Object*? schema = one.get("schema");
	test::@check(@ok(schema), "and carries its JSON Schema verbatim");
}

<*
 save_project with no open document refuses in the reply, not with a fault.

 A missing project path is a state a caller asks about, so the answer is JSON that
 says so — `saved` is null and the note points at the difference between saving a
 project and publishing a pack — rather than an error that a script would have to
 catch to read.
*>
fn void save_project_reports_no_open_project() @test
{
	Fixture fixture;
	fixture.open_bare();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? saved = f.call_tool("save_project", "{}");
	if (catch saved)
	{
		test::@check(false, "save_project answers with JSON even with nothing to save");
		return;
	}
	defer saved.free();

	test::@check(saved.get("saved")!!.is_null(), "it saved nothing, and says so with a null");
	test::@check((saved.get_string("note") ?? "").contains("no open project"),
		"and the note names why");
	test::@check((saved.get_string("note") ?? "").contains("save_pack"),
		"and points at the pack door it is not");
}

<*
 get_scene carries the authored-dirty cue, and it tracks an authored edit.

 The listed orientation call is where an agent learns a save is owed. False on a
 freshly opened document, true once a clip has been authored into it — the same
 flag save_project reports and Ctrl+S clears.
*>
fn void get_scene_reports_authored_dirty() @test
{
	Fixture clean;
	clean.open();
	defer clean.close();
	Object*? before = ((Fixture*)&clean).call_tool("get_scene", "{}");
	if (catch before)
	{
		test::@check(false, "get_scene answers on a clean document");
		return;
	}
	defer before.free();
	Object*? clean_project = before.get("project");
	if (catch clean_project)
	{
		test::@check(false, "get_scene carries a project block");
		return;
	}
	test::@check(clean_project.get_bool("authored_dirty")!! == false,
		"a freshly opened document has nothing unsaved");

	Fixture edited;
	edited.open_authored();
	defer edited.close();
	Object*? after = ((Fixture*)&edited).call_tool("get_scene", "{}");
	if (catch after)
	{
		test::@check(false, "get_scene answers after authoring");
		return;
	}
	defer after.free();
	test::@check(after.get("project")!!.get_bool("authored_dirty")!! == true,
		"authoring a clip leaves the project dirty until it is saved");
}

// ---------------------------------------------------------------------------
// solve_targets
//
// The IK the interactive poser bends a pinned foot back to the floor with,
// exposed for authoring (animation_plan.md, MCP1): a joint and a point in, the
// pose that reaches it out, as a keyframe apply_clip bakes. The fixture's one
// chain is foot -> knee -> hips, a metre of straight leg from the root at
// (0,1,0), so a point within a metre of there is reachable and one far outside
// is not — which is the whole of what these checks turn on.

<*
 A reachable point is reached, and the answer is a keyframe that turned the chain.
*>
fn void solve_targets_reaches_a_point() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.5,0.7,0]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers");
		return;
	}
	defer solved.free();

	test::@check(solved.get_bool("reached")!! == true, "a point within a metre of the hip is reached");

	Object* targets = solved.get("targets")!!;
	test::@check(targets.get_len() == 1, "one target, one result");
	test::@check((targets.get_at(0).get_float("residual") ?? 1.0) < 0.05,
		"and the foot ended up on the point");

	Object* joints = solved.get("keyframe")!!.get("joints")!!;
	test::@check(joints.get_len() > 0, "the reach turned the joints above the foot");
	test::@check(@ok(joints.get_at(0).get_string("name")), "each keyed joint is named");
	test::@check(@ok(joints.get_at(0).get("rotation")!!.get_float("w")),
		"and carries a quaternion apply_clip can take");
}

<*
 A point the limb cannot touch is not reached, and the residual is the shortfall.
*>
fn void solve_targets_reports_an_unreachable_point() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[5,5,5]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers for an unreachable point");
		return;
	}
	defer solved.free();

	test::@check(solved.get_bool("reached")!! == false, "a metre-long leg cannot touch it");
	Object* first = solved.get("targets")!!.get_at(0);
	test::@check(first.get_bool("reached")!! == false, "the target says so");
	test::@check((first.get_float("residual") ?? 0.0) > 1.0, "and the residual is how far it fell short");
}

<*
 A joint with no run of ancestors to bend cannot be placed, and says why.
*>
fn void solve_targets_refuses_a_joint_with_no_run() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"hips","position":[0.3,0.9,0]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers even when a target cannot be placed");
		return;
	}
	defer solved.free();

	Object* first = solved.get("targets")!!.get_at(0);
	test::@check(first.get_bool("reached")!! == false, "the hips are a root — nothing above them bends");
	test::@check((first.get_string("note") ?? "").contains("run"), "and the note says why");
}

<*
 Holding an orientation turns the effector itself, so the keyframe keys it.
*>
fn void solve_targets_holds_an_orientation() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// A quarter turn about X as the foot's world orientation.
	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.5,0.7,0],"orientation":{"x":0.3826834,"y":0,"z":0,"w":0.9238795}}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers with an orientation");
		return;
	}
	defer solved.free();

	Object* joints = solved.get("keyframe")!!.get("joints")!!;
	bool foot_keyed = false;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		if ((joints.get_at(i).get_string("name") ?? "") == "foot") foot_keyed = true;
	}
	test::@check(foot_keyed, "holding an orientation turns the effector, so it is in the keyframe");
}

<*
 The keyframe solve_targets answers with is exactly what apply_clip takes.

 The claim the whole tool rests on — solve here, bake there — checked by feeding
 one straight into the other rather than by inspecting the shape. Rebuilt from the
 parsed answer because no serialiser is at hand; the rotations are the solved ones.
*>
fn void solve_targets_keyframe_feeds_apply_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.5,0.7,0]}]}`);
	if (catch solved)
	{
		test::@check(false, "solve_targets answers");
		return;
	}
	defer solved.free();

	Object* joints = solved.get("keyframe")!!.get("joints")!!;
	test::@check(joints.get_len() > 0, "there is a keyframe to bake");

	DString kf = dstring::new(mem);
	defer kf.free();
	kf.append_string(`{"name":"reach","duration":1.0,"keyframes":[{"time":0,"joints":[`);
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* e = joints.get_at(i);
		Object* r = e.get("rotation")!!;
		if (i > 0) kf.append_char(',');
		kf.appendf(`{"name":"%s","rotation":{"x":%.9g,"y":%.9g,"z":%.9g,"w":%.9g}}`,
			e.get_string("name")!!, r.get_float("x")!!, r.get_float("y")!!, r.get_float("z")!!, r.get_float("w")!!);
	}
	kf.append_string(`]}]}`);

	Object*? applied = f.call_tool("apply_clip", kf.str_view());
	if (catch applied)
	{
		test::@check(false, "the solved keyframe bakes through apply_clip unchanged");
		return;
	}
	defer applied.free();
	test::@check(true, "solve here, apply_clip bakes there");
}

<*
 An unknown joint is refused by name, not solved for silently.
*>
fn void solve_targets_refuses_an_unknown_joint() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"solve_targets","arguments":{"targets":[{"joint":"elbow","position":[0,0,0]}]}}}`);
	if (catch root)
	{
		test::@check(false, "an unknown-joint request answers");
		return;
	}
	defer root.free();
	test::@check(error_message_contains(root, "not a dot on this rig"),
		"an unknown joint is refused by name");
}

// Solve the foot to a bent target with the given pole, bake the keyframe, and
// read the knee's world Z after — which way the knee bowed.
fn double? knee_z_for_pole(Fixture* f, String pole) @local
{
	String args = string::format(mem,
		`{"targets":[{"joint":"foot","position":[0.15,0.55,0],"pole":%s}]}`, pole);
	defer alloc::free(mem, args);
	Object* solved = f.call_tool("solve_targets", args)!;
	defer solved.free();

	// The solved keyframe, handed back to apply_clip as a one-frame clip.
	Object* joints = solved.get("keyframe")!.get("joints")!;
	DString kf = dstring::new(mem);
	defer kf.free();
	kf.append_string(`{"name":"pole","duration":1.0,"keyframes":[{"time":0,"joints":[`);
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* e = joints.get_at(i);
		Object* r = e.get("rotation")!;
		if (i > 0) kf.append_char(',');
		kf.appendf(`{"name":"%s","rotation":{"x":%.9g,"y":%.9g,"z":%.9g,"w":%.9g}}`,
			e.get_string("name")!, r.get_float("x")!, r.get_float("y")!, r.get_float("z")!, r.get_float("w")!);
	}
	kf.append_string(`]}]}`);
	Object* applied = f.call_tool("apply_clip", kf.str_view())!;
	applied.free();

	Object* pose = f.call_tool("get_pose", `{"clip":"pole","t":0}`)!;
	defer pose.free();
	Object* pjoints = pose.get("joints")!;
	for (sz i = 0; i < pjoints.get_len(); i++)
	{
		Object* j = pjoints.get_at(i);
		if (j.get_string("name")! == "knee") return j.get("position")!.get_float_at(2)!;
	}
	return NOT_FOUND~;
}

<*
 A pole settles which way the knee bends: one pole bows it toward +Z, the
 opposite pole toward -Z, and the effector still reaches its point.
*>
fn void solve_targets_pole_aims_the_bend() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	double? front = knee_z_for_pole(f, "[0,0.5,5]");
	double? back = knee_z_for_pole(f, "[0,0.5,-5]");
	if (catch front) { test::@check(false, "the +Z pole solve did not complete"); return; }
	if (catch back) { test::@check(false, "the -Z pole solve did not complete"); return; }

	test::@check(front > 0.02, "a +Z pole should bow the knee toward +Z (z=%.4f)", front);
	test::@check(back < -0.02, "a -Z pole should bow the knee toward -Z (z=%.4f)", back);
	test::@check(front > back + 0.1, "the pole flips the bend from one side to the other");
}

<*
 A pole reports whether it was aimed: yes on a two-bone limb, no on a limb with
 one bend, where there is no elbow or knee to point.
*>
fn void solve_targets_pole_reports_when_it_cannot_aim() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? two = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0.15,0.55,0],"pole":[0,0.5,5]}]}`);
	if (catch two) { test::@check(false, "the two-bone solve answers"); return; }
	defer two.free();
	test::@check(two.get("targets")!!.get_at(0).get_bool("pole_aimed")!! == true,
		"a foot's two-bone limb aims the pole");

	// The knee has only one bend above it (the hips), so there is no joint to aim.
	Object*? one = f.call_tool("solve_targets",
		`{"targets":[{"joint":"knee","position":[0.2,0.55,0],"pole":[0,0.5,5]}]}`);
	if (catch one) { test::@check(false, "the one-bone solve answers"); return; }
	defer one.free();
	test::@check(one.get("targets")!!.get_at(0).get_bool("pole_aimed")!! == false,
		"a one-bone limb reports the pole was not aimed");
}

<*
 A pole the limb reaches straight through is ignored, and the note says why it
 was — not that the limb had too few bends.
*>
fn void solve_targets_pole_notes_a_straight_limb() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The foot is already at its rest place, so the leg stays straight down its
	// axis: a real two-bone limb, but with no bend off the line for the pole to aim.
	Object*? solved = f.call_tool("solve_targets",
		`{"targets":[{"joint":"foot","position":[0,0,0],"pole":[0,0.5,5]}]}`);
	if (catch solved) { test::@check(false, "the straight solve answers"); return; }
	defer solved.free();

	Object* first = solved.get("targets")!!.get_at(0);
	test::@check(first.get_bool("pole_aimed")!! == false, "a straight limb aims no pole");
	test::@check((first.get_string("pole_note") ?? "").contains("straight"),
		"and the note names the straight limb, not a missing bend");
}

// ---------------------------------------------------------------------------
// plant_feet
//
// The horizontal half of a ground contact (animation_plan.md, MCP2): holding a
// stance foot in place while the pelvis moves, baked by leg IK. The fixture's
// foot -> knee -> hips leg over a root that sways +X and back gives a foot that
// slides; planting it bends the leg to hold the foot, dropping measure_clip's
// foot_slide.

// A clip whose root sways out and back while the foot is meant to be down the
// whole cycle — a foot that skates, for plant_feet to still.
const String SKATING_CLIP @local = `{"name":"step","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,0,0]}]},{"time":0.5,"joints":[{"name":"hips","move":[0.2,0,0]}]},{"time":1.0,"joints":[{"name":"hips","move":[0,0,0]}]}],"ground":{"feet":[{"joint":"foot","down":0.0,"up":1.0}]}}`;

<*
 A skating foot is planted still: foot_slide falls and the leg is keyed to do it.
*>
fn void plant_feet_stops_a_foot_skating() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", SKATING_CLIP);
	if (catch authored)
	{
		test::@check(false, "the skating clip authors");
		return;
	}
	authored.free();

	Object*? planted = f.call_tool("plant_feet", `{"clip":"step"}`);
	if (catch planted)
	{
		test::@check(false, "plant_feet answers");
		return;
	}
	defer planted.free();

	Object* slide = planted.get("foot_slide")!!;
	double before = slide.get_float("before")!!;
	double after = slide.get_float("after")!!;
	test::@check(before > 0.02, "the clip was skating to begin with (foot_slide %.6g)", before);
	test::@check(after < before * 0.6, "and planting cut it down (%.6g -> %.6g)", before, after);
	test::@check((planted.get_int("keys_added") ?? 0) > 0, "and it keyed the leg to do it");
	test::@check(planted.get("feet")!!.get_at(0).get_bool("planted")!! == true,
		"the foot had a leg to bend");
}

<*
 planting lands: the clip in the pack skates less than it did before.

 A separate measure_clip against the replaced clip, so what is asserted is that the
 bake reached the pack, not just that the tool's own before/after says so.
*>
fn void plant_feet_lands_the_planted_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", SKATING_CLIP);
	if (catch authored)
	{
		test::@check(false, "the skating clip authors");
		return;
	}
	authored.free();

	Object*? m0 = f.call_tool("measure_clip", `{"clip":"step"}`);
	if (catch m0)
	{
		test::@check(false, "measure_clip reads the skating clip");
		return;
	}
	double before = m0.get_float("foot_slide") ?? 0.0;
	m0.free();

	Object*? planted = f.call_tool("plant_feet", `{"clip":"step"}`);
	if (catch planted)
	{
		test::@check(false, "plant_feet answers");
		return;
	}
	planted.free();

	Object*? m1 = f.call_tool("measure_clip", `{"clip":"step"}`);
	if (catch m1)
	{
		test::@check(false, "measure_clip reads the planted clip");
		return;
	}
	double after = m1.get_float("foot_slide") ?? 0.0;
	m1.free();

	test::@check(after < before * 0.6, "the landed clip skates less (%.6g -> %.6g)", before, after);
}

<*
 A clip with no ground spec has no stance feet, and is refused by saying so.
*>
fn void plant_feet_refuses_a_clip_with_no_ground() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"flat","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]}]}`);
	if (catch authored)
	{
		test::@check(false, "the no-ground clip authors");
		return;
	}
	authored.free();

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"plant_feet","arguments":{"clip":"flat"}}}`);
	if (catch root)
	{
		test::@check(false, "plant_feet answers a no-ground clip");
		return;
	}
	defer root.free();
	test::@check(error_message_contains(root, "no ground spec"),
		"a clip with no feet is refused, and says why");
}

// ---------------------------------------------------------------------------
// patch_clip
//
// The additive counterpart to apply_clip (animation_plan.md, MCP3): a few joints
// offset over a range, every other track left as it was. The fixture's knee is the
// joint offset; hips is the unrelated track that must survive it.

// A clip driving the knee (identity throughout) and sliding the hips, so a knee
// patch has an unrelated hips track to leave alone and its own keys to offset.
const String PATCH_CLIP @local = `{"name":"c","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}},{"name":"hips","move":[0,0,0]}]},{"time":0.5,"joints":[{"name":"hips","move":[0.1,0,0]}]},{"time":1.0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}},{"name":"hips","move":[0,0,0]}]}]}`;

// A joint's world rotation quaternion out of a get_pose answer, by name.
fn bool joint_quat(Object* pose, String name, double[] out) @local
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
fn bool joint_pos(Object* pose, String name, double[] out) @local
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

// ---------------------------------------------------------------------------
// measure_clip localization
//
// The aggregate numbers say a clip is wrong; the issues say where (animation_plan.md,
// MCP5). Each fixture drives one fault and asserts it comes back named to a joint
// and a phase, and that a clean clip names none.

// The first issue of a given kind, or null when the answer names none.
fn Object* find_issue(Object* metrics, String kind) @local
{
	Object*? issues = metrics.get("issues");
	if (catch issues) return null;
	for (sz i = 0; i < issues.get_len(); i++)
	{
		Object* it = issues.get_at(i);
		String? k = it.get_string("kind");
		if (catch k) continue;
		if (k == kind) return it;
	}
	return null;
}

<*
 A skating foot is named to the foot and a phase, not just summed into foot_slide.
*>
fn void measure_clip_localizes_a_foot_slide() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip", SKATING_CLIP);
	if (catch authored) { test::@check(false, "the skating clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"step"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* slide = find_issue(m, "foot_slide");
	test::@check(slide != null, "the slide is reported as an issue");
	if (slide == null) return;
	test::@check(slide.get_string("joint")!! == "foot", "named to the foot that slid");
	test::@check((slide.get_float("magnitude") ?? 0.0) > 0.01, "with the magnitude that cleared tolerance");
	double phase = slide.get_float("phase") ?? -1.0;
	test::@check(phase >= 0.0 && phase <= 1.0, "and a phase in the cycle");
}

<*
 A joint sunk through the floor is named to the deepest joint and where.
*>
fn void measure_clip_localizes_floor_penetration() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"sink","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"hips","move":[0,-0.3,0]}]}]}`);
	if (catch authored) { test::@check(false, "the sinking clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"sink"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* sunk = find_issue(m, "floor_penetration");
	test::@check(sunk != null, "the penetration is reported as an issue");
	if (sunk == null) return;
	test::@check(sunk.get_string("joint")!! == "foot", "named to the deepest joint");
	test::@check((sunk.get_float("magnitude") ?? 0.0) > 0.2, "with a magnitude of how deep it got");
}

<*
 An animated rotation past a joint's limit is named to the joint and the axis.
*>
fn void measure_clip_localizes_a_limit_saturation() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Lock every bone-local axis of the knee: any turn now runs past the table.
	uint knee = f.app.dot_named("knee").id;
	crig::JointRotationLimits lim = crig::unconstrained_rotation(knee);
	lim.constrained = true;
	for (usz i = 0; i < 3; i++)
	{
		lim.axes[i].allowed = false;
		lim.axes[i].locked = 0.0f;
	}
	test::@check(f.app.doc.set_rotation_limits(knee, lim), "the knee's limit table is set");

	Object*? authored = f.call_tool("apply_clip",
		`{"name":"strain","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}]}`);
	if (catch authored) { test::@check(false, "the straining clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"strain"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* hit = find_issue(m, "limit_saturation");
	test::@check(hit != null, "the joint fighting its limit is reported");
	if (hit == null) return;
	test::@check(hit.get_string("joint")!! == "knee", "named to the joint");
	test::@check(@ok(hit.get_string("axis")), "and the bone-local axis it was hit on");
	test::@check((hit.get_float("magnitude") ?? 0.0) > 0.02, "with the radians past the limit");
}

<*
 A loop that reverses direction at the seam is named as a velocity break there.
*>
fn void measure_clip_localizes_a_loop_seam() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// A triangle over the cycle: the knee swings up then down, so its direction
	// flips at the seam — a velocity discontinuity the finite differences catch.
	Object*? authored = f.call_tool("apply_clip",
		`{"name":"hitch","duration":1.0,"loop":true,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":0.5,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":1.0}}]}]}`);
	if (catch authored) { test::@check(false, "the hitching clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"hitch"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	Object* seam = find_issue(m, "loop_velocity");
	test::@check(seam != null, "the loop's velocity break is reported");
	if (seam == null) return;
	test::@check(seam.get_string("joint")!! == "foot", "named to the joint that swings");
	test::@check((seam.get_float("phase") ?? -1.0) == 0.0, "at the seam");
}

<*
 A clip with none of the four faults reports an empty issues list.
*>
fn void measure_clip_finds_nothing_in_a_clean_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Non-looping (no seam), no ground (no feet to skate), no limits set, a gentle
	// turn that lifts the foot rather than sinking it.
	Object*? authored = f.call_tool("apply_clip",
		`{"name":"calm","duration":1.0,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":{"x":0,"y":0,"z":0,"w":1}}]},{"time":1.0,"joints":[{"name":"knee","rotation":{"axis":[1,0,0],"angle":0.3}}]}]}`);
	if (catch authored) { test::@check(false, "the calm clip authors"); return; }
	authored.free();

	Object*? m = f.call_tool("measure_clip", `{"clip":"calm"}`);
	if (catch m) { test::@check(false, "measure_clip answers"); return; }
	defer m.free();

	test::@check(m.get("issues")!!.get_len() == 0, "a clean clip names no issue");
}

// ---------------------------------------------------------------------------
// mirror plane (symmetry)
//
// The mirror reflects across the skeleton's own midline, read off its named
// joints, rather than trusting the mesh's bounding-box centre — which is not the
// body's midline when the mesh is asymmetric (a tail, an off-centre export).

<*
 The plane is read off the rig's centre joint and named pair, not the mesh.
*>
fn void symmetry_plane_reads_the_rig_not_the_mesh() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "an empty mesh's plane starts at x=0");

	// A skeleton centred at x = 2, nowhere near the empty mesh's x = 0.
	app.doc.add_dot({ 2.0f, 1.0f, 0 }, "spine");   // centre joint, on the plane
	app.doc.add_dot({ 1.7f, 0.5f, 0 }, "arm_l");   // a pair straddling it
	app.doc.add_dot({ 2.3f, 0.5f, 0 }, "arm_r");

	float plane;
	test::@check(app.symmetry_plane(&plane), "a plane should read off the named joints");
	test::@check(math::abs(plane - 2.0f) < 1e-4f, "the plane is the rig's centre x=2, got %.4f", plane);
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "reading the plane does not change the stored one");
}

<*
 A tail curling to one side is side-less joints off the midline. They must not
 drag the plane after them: averaged in, four tail joints moved it 4 cm on a
 1 m figure and M put a pinky's twin inside the palm. The plane is the median of
 the centre joints and the pairs, so the twin lands at the exact reflection.

 *Re-introduce:* take `MirrorSurvey.centre_point` (the mean) for the plane and
 pinky_r lands near -0.33 rather than at -0.42.
*>
fn void a_curled_tail_does_not_move_the_mirror_plane() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	uint hips = app.doc.add_dot({ 0.0f, 0.5f, 0.0f }, "hips");
	app.doc.add_dot({ 0.0f, 0.6f, 0.0f }, "spine");
	app.doc.add_dot({ 0.0f, 0.7f, 0.0f }, "chest");
	app.doc.add_dot({ 0.0f, 0.9f, 0.0f }, "head");
	// The tail curls off to +X, the way Zidane's does.
	app.doc.add_dot({ 0.00f, 0.45f, -0.10f }, "tail_1");
	app.doc.add_dot({ 0.06f, 0.45f, -0.20f }, "tail_2");
	app.doc.add_dot({ 0.17f, 0.46f, -0.28f }, "tail_3");
	app.doc.add_dot({ 0.25f, 0.47f, -0.33f }, "tail_4");
	app.doc.add_dot({ 0.35f, 0.72f, 0.06f }, "wrist_l");
	app.doc.add_dot({ -0.35f, 0.72f, 0.06f }, "wrist_r");
	uint pinky_l = app.doc.add_dot({ 0.42f, 0.71f, 0.03f }, "pinky_l");
	app.doc.add_dot({ -0.40f, 0.70f, 0.04f }, "pinky_r");
	app.doc.root_id = hips;

	Vec3 point;
	Vec3 normal;
	app.mirror_plane(&point, &normal, app.picker.scale * 0.01f);
	test::@check(math::abs(point.x) < 1e-4f, "the tail dragged the plane to x=%.4f", point.x);

	app.select(pinky_l);
	(void)app.mirror_selection();
	crig::Dot* twin = app.dot_named("pinky_r");
	test::@check(twin != null, "no pinky_r");
	if (twin == null) return;
	test::@check((twin.position - (Vec3){ -0.42f, 0.71f, 0.03f }).length() < 1e-4f,
		"pinky_r is not pinky_l's reflection: %s", twin.position);
}

<*
 Once the plane is corrected off the rig, the mirror reflects across it — not the
 mesh's centre — and the correction takes back with one undo.
*>
fn void the_corrected_plane_makes_the_mirror_land_right() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "the plane starts at the empty mesh's x=0");

	// A skeleton sitting around x = 2, far from the mesh's x = 0. The left hand is
	// placed roughly, for the mirror to square up against the right.
	uint spine = app.doc.add_dot({ 2.0f, 1.0f, 0 }, "spine");
	uint hr = app.doc.add_dot({ 2.6f, 0.5f, 0 }, "hand_r");
	app.doc.add_dot({ 1.8f, 0.5f, 0 }, "hand_l");
	app.doc.root_id = spine;
	app.doc.connect(spine, hr);

	// Correct the plane off the rig — what edit_rig's symmetry op does — banked as
	// its own undo step.
	float plane;
	test::@check(app.symmetry_plane(&plane), "a plane should read off the rig");
	test::@check(app.set_sym_x_recorded(plane), "the plane should move off the mesh's 0");
	app.undo_stack.commit();
	test::@check(app.doc.sym_x > 1.5f, "the plane is now the rig's own (sym_x=%.4f)", app.doc.sym_x);

	app.select(hr);
	(void)app.mirror_selection();

	crig::Dot* twin = app.dot_named("hand_l");
	test::@check(twin != null, "no hand_l twin");
	if (twin == null) return;
	// Across the rig's plane the twin lands near the skeleton (x>1), not flung to
	// about -2.6 where reflecting across x=0 would have put it.
	test::@check(twin.position.x > 1.0f, "hand_l reflected across the wrong plane (x=%.4f)", twin.position.x);
	test::@check(math::abs(twin.position.x - (2.0f * app.doc.sym_x - 2.6f)) < 1e-3f,
		"hand_l is not the reflection of hand_r across the plane");

	// One undo takes the plane correction back to the mesh's 0.
	test::@check(app.undo(), "the mirror would not undo");
	test::@check(app.undo(), "the plane correction would not undo");
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "undo did not restore the plane to 0 (%.4f)", app.doc.sym_x);
}

<*
 The reported case: a lopsided mesh leaves `sym_x` off the body's midline, and
 pressing M with no plane set at all still lands the twin by the skeleton — the
 mirror reads its own centre line off the centre joints. It corrects on its own,
 without touching the stored plane, so a rig on a symmetric mesh is unaffected.
*>
fn void the_mirror_reads_the_plane_off_the_skeleton_on_its_own() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	// Stand in for a lopsided mesh: the plane the box would give sits at 0, well
	// off the skeleton, which is centred on x = 2 by its named centre joints.
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "the stored plane starts off the skeleton at 0");

	app.doc.add_dot({ 2.0f, 1.2f, 0 }, "spine");
	app.doc.add_dot({ 2.0f, 1.6f, 0 }, "chest");
	uint sr = app.doc.add_dot({ 2.7f, 0.9f, 0 }, "shoulder_r");
	app.doc.add_dot({ 1.4f, 0.9f, 0.1f }, "shoulder_l");  // roughly placed, to be squared

	app.select(sr);
	// No symmetry op first — this is the plain-M path.
	(void)app.mirror_selection();

	crig::Dot* twin = app.dot_named("shoulder_l");
	test::@check(twin != null, "no shoulder_l twin");
	if (twin == null) return;
	// Reflected across the skeleton's x = 2, shoulder_l lands at 2*2 - 2.7 = 1.3 —
	// near the body — not at -2.7 where the stored x = 0 plane would fling it.
	test::@check(math::abs(twin.position.x - 1.3f) < 1e-4f,
		"shoulder_l reflected across the skeleton's midline (x=%.4f)", twin.position.x);
	test::@check(math::abs(twin.position.y - 0.9f) < 1e-4f && math::abs(twin.position.z) < 1e-4f,
		"the twin took the source's y and z, only x reflected");
	// The stored plane is left where it was — the correction is the mirror's own,
	// not a silent edit to the document.
	test::@check(math::abs(app.doc.sym_x) < 1e-4f, "the mirror did not move the stored plane (%.4f)", app.doc.sym_x);
}

<*
 The turned-character case: a rig modelled facing a diagonal, not straight +Z, so
 its left-right axis is tilted about the vertical. The mirror must reflect across
 that tilted plane — carrying a twin around to the other side of the *body*, at
 the same body-depth — not across the world-X plane, which keeps world depth and
 throws the twin out in front. The plane's orientation comes off the rig's own
 paired joints; a near-square rig keeps the world-aligned plane (see the tests
 above), so only a genuinely turned rig is tilted.
*>
fn void the_mirror_follows_a_turned_characters_own_plane() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();

	// A rig turned 45° about Y: its left-right axis, world X for a forward-facing
	// rig, is now n = (cos45, 0, -sin45). Centre joints on the plane through the
	// origin's vertical; limb pairs straddle it evenly, except the hand, placed
	// crooked for the mirror to square up.
	float k = 0.70710678f;  // cos45 = sin45

	app.doc.add_dot({ 0, 1.0f, 0 }, "spine");   // centre joints, on the plane
	app.doc.add_dot({ 0, 1.5f, 0 }, "chest");
	// arm and leg pairs sit exactly symmetric about the tilted plane, so they
	// pin the orientation; the hand is placed off, to be squared.
	app.doc.add_dot({ k*0.6f, 1.0f, -k*0.6f }, "arm_r");
	app.doc.add_dot({ -k*0.6f, 1.0f, k*0.6f }, "arm_l");
	app.doc.add_dot({ 0.354f, 0.2f, -0.354f }, "leg_r");
	app.doc.add_dot({ -0.354f, 0.2f, 0.354f }, "leg_l");
	uint hr = app.doc.add_dot({ 0.636f, 0.8f, -0.636f }, "hand_r");
	app.doc.add_dot({ -0.5f, 0.85f, 0.5f }, "hand_l");  // crooked

	// The plane read off the rig is tilted, not world-aligned.
	float[<3>] point;
	float[<3>] normal;
	app.mirror_plane(&point, &normal, app.picker.scale * 0.01f);
	test::@check(math::abs(normal.x) < 0.9f && math::abs(normal.z) > 0.4f,
		"the plane normal is tilted, not world X (n = %.3f, %.3f, %.3f)", normal.x, normal.y, normal.z);

	// The expected reflection across the derived plane, computed from the source's
	// position captured before the mirror runs.
	float[<3>] src = app.dot_named("hand_r").position;
	float d = (src - point).dot(normal);
	float[<3>] want = src - normal * (2.0f * d);

	app.select(hr);
	(void)app.mirror_selection();

	crig::Dot* twin = app.dot_named("hand_l");
	test::@check(twin != null, "no hand_l twin");
	if (twin == null) return;

	// It landed on the tilted reflection — the +z side of the body — not where the
	// world-X mirror would keep it (z ≈ -0.636, out in front).
	test::@check(twin.position.z > 0.4f,
		"hand_l went around to the body's other side (z=%.3f), not kept in front by a world-X flip", twin.position.z);
	test::@check((twin.position - want).length() < 1e-3f,
		"hand_l is the reflection across the rig's own tilted plane (got %.3f,%.3f,%.3f want %.3f,%.3f,%.3f)",
		twin.position.x, twin.position.y, twin.position.z, want.x, want.y, want.z);
}

<*
 edit_rig's symmetry op sets the plane — explicitly, or derived from the rig —
 and get_scene reports it.
*>
fn void edit_rig_symmetry_sets_the_plane() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// An explicit plane.
	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"symmetry","plane":0.25}]}`);
	if (catch set) { test::@check(false, "the explicit symmetry op answers"); return; }
	set.free();
	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene) { test::@check(false, "get_scene answers"); return; }
	double reported = scene.get("rig")!!.get_float("symmetry_x") ?? 999.0;
	scene.free();
	test::@check(math::abs(reported - 0.25) < 1e-4, "get_scene should report the plane just set (%.4f)", reported);

	// Derived from the skeleton — the fixture's hips/knee/foot are all at x=0, so
	// the plane comes back at 0.
	Object*? derived = f.call_tool("edit_rig", `{"ops":[{"op":"symmetry","from":"skeleton"}]}`);
	if (catch derived) { test::@check(false, "the derive-from-skeleton op answers"); return; }
	derived.free();
	Object*? scene2 = f.call_tool("get_scene", "{}");
	if (catch scene2) { test::@check(false, "get_scene answers again"); return; }
	double back = scene2.get("rig")!!.get_float("symmetry_x") ?? 999.0;
	scene2.free();
	test::@check(math::abs(back) < 1e-3, "deriving the plane off a centred rig gives x=0 (%.4f)", back);

	// A symmetry op with neither plane nor from is refused by name.
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"symmetry"}]}`, "plane", "from"),
		"a symmetry op with nothing to set is refused");
}

// ---------------------------------------------------------------------------
// get_weights / show_weights

<*
 Ownership is exclusive and total: every vertex belongs to exactly one dot.

 The strongest claim the survey makes, and the one that catches a loop counting
 twice or skipping. Asserted as a sum against the vertex count rather than per
 dot, because no single dot's share is a number this test could know.
*>
fn void get_weights_accounts_for_every_vertex() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? weights = f.call_tool("get_weights", `{}`);
	if (catch weights)
	{
		test::@check(false, "get_weights answers");
		return;
	}
	defer weights.free();

	Object*? dots = weights.get("dots");
	if (catch dots)
	{
		test::@check(false, "get_weights carries a dot table");
		return;
	}
	long vertices = weights.get_int("vertices") ?? -1;
	if (vertices < 0)
	{
		test::@check(false, "get_weights carries a vertex count");
		return;
	}

	long owned = 0;
	bool reaches_what_it_owns = true;
	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* dot = dots.get_at(i);
		long owns = dot.get_int("owns") ?? -1;
		long reaches = dot.get_int("reaches") ?? -1;
		if (owns < 0 || reaches < owns) reaches_what_it_owns = false;
		owned += owns;
	}

	test::@check(dots.get_len() == 4, "get_weights reports one row per dot, unnamed ones included");
	test::@check(owned == vertices, "every vertex is owned by exactly one dot");
	test::@check(reaches_what_it_owns, "and no dot owns mass it does not reach");

	// The stranded count rides along, and it is the answer to a different
	// question: ownership is exclusive and total by construction — a vertex has
	// *some* nearest bone — while this says how far away that bone actually is.
	// It is the only way left to ask, so a survey that dropped the field would
	// take the diagnostic with it.
	long stranded = weights.get_int("unclaimed") ?? -1;
	test::@check(stranded >= 0, "get_weights still carries the unclaimed count");
	test::@check(stranded <= vertices, "and it cannot strand more than the mesh has, %d of %d", stranded, vertices);
}

<*
 The surveyed half adds up against the table: reaches = owns + what it shares.

 An exact identity, not a bound. A vertex the dot reaches is either its own or
 someone else's, and the shared list groups the second kind by owner — so a
 survey that double-counted, dropped a neighbour or floored two rows differently
 breaks this and nothing else here would notice.
*>
fn void a_surveyed_dot_adds_up() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? weights = f.call_tool("get_weights", `{"dot":"knee"}`);
	if (catch weights)
	{
		test::@check(false, "get_weights surveys a named dot");
		return;
	}
	defer weights.free();

	Object*? shared = weights.get("shared");
	if (catch shared)
	{
		test::@check(false, "a surveyed dot carries a list of what it shares");
		return;
	}
	String named = weights.get_string("dot") ?? "";
	long owns = weights.get_int("owns") ?? -1;
	long reaches = weights.get_int("reaches") ?? -1;
	if (named.len == 0 || owns < 0 || reaches < 0)
	{
		test::@check(false, "a surveyed dot carries its name, owns and reaches");
		return;
	}

	long elsewhere = 0;
	bool names_itself = false;
	for (sz i = 0; i < shared.get_len(); i++)
	{
		Object* row = shared.get_at(i);
		elsewhere += row.get_int("vertices") ?? 0;
		if ((row.get_string("name") ?? "") == "knee") names_itself = true;
	}

	test::@check(named == "knee", "the survey names the dot it was pointed at");
	test::@check(reaches == owns + elsewhere, "and reaches exactly what it owns plus what it shares");
	test::@check(!names_itself, "a dot is never its own neighbour");

	// The fixture's own arrangement, and worth naming: every vertex of the cube is
	// a corner, so the middle of a three-dot chain is nearer to nothing and owns
	// none of it — while still pulling hard enough on its neighbours' mass to
	// matter. Owning nothing and reaching plenty is the shape of a joint that
	// smears the mesh without holding any of it, which is what these two numbers
	// are separate in order to show.
	test::@check(owns == 0, "a dot can own nothing");
	test::@check(reaches > 0, "and still reach into what its neighbours own");
}

<*
 `bone_<id>` is addressable here, unlike in a clip.

 The distinction is the point: a clip matches the name a dot carries, so an
 unnamed dot cannot be animated — but it is bound like every other, and a survey
 that could not reach it would be blind to whatever it is holding.
*>
fn void a_weight_survey_addresses_an_unnamed_dot() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? skeleton = f.call_tool("get_skeleton", `{}`);
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers");
		return;
	}
	defer skeleton.free();

	String address = "";
	Object*? dots = skeleton.get("dots");
	if (try dots)
	{
		for (sz i = 0; i < dots.get_len(); i++)
		{
			String name = dots.get_at(i).get_string("name") ?? "";
			if (name.len > 5 && name[:5] == "bone_") address = name;
		}
	}
	if (address.len == 0)
	{
		test::@check(false, "SKIPPED — the fixture rig has no unnamed dot");
		return;
	}

	String arguments = string::format(mem, `{"dot":"%s"}`, address);
	defer alloc::free(mem, arguments);

	Object*? weights = f.call_tool("get_weights", arguments);
	if (catch weights)
	{
		test::@check(false, "get_weights surveys an unnamed dot by bone_<id>");
		return;
	}
	defer weights.free();

	test::@check((weights.get_string("dot") ?? "") == address, "a survey reaches an unnamed dot by bone_<id>");
}

fn void a_weight_survey_says_which_dots_it_has() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(
		f.refuses_tool("get_weights", `{"dot":"tentacle"}`, "tentacle", "hips", "knee"),
		"a dot no rig carries is refused with the ones it does");
}

fn void show_weights_puts_a_named_view_on_the_screen() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? shown = f.call_tool("show_weights", `{"mode":"territory"}`);
	if (catch shown)
	{
		test::@check(false, "show_weights answers");
		return;
	}
	defer shown.free();
	test::@check((shown.get_string("showing") ?? "") == "territory", "show_weights turns the named view on");
	test::@check((shown.get_string("painting") ?? "").len > 0, "and says what a person looking at it is seeing");

	// Named rather than toggled: asking twice for the same view leaves it on. The
	// F key would have turned it off here, which is right for a key and wrong for
	// a caller that was told which view to show.
	Object*? again = f.call_tool("show_weights", `{"mode":"territory"}`);
	if (catch again)
	{
		test::@check(false, "show_weights answers a second time");
		return;
	}
	defer again.free();
	test::@check((again.get_string("showing") ?? "") == "territory", "and asking for it again leaves it on");

	Object*? falloff = f.call_tool("show_weights", `{"mode":"falloff","dot":"knee"}`);
	if (catch falloff)
	{
		test::@check(false, "show_weights ramps from a dot");
		return;
	}
	defer falloff.free();
	test::@check((falloff.get_string("dot") ?? "") == "knee", "the falloff view reports the dot it ramps from");

	Object*? off = f.call_tool("show_weights", `{"mode":"off"}`);
	if (catch off)
	{
		test::@check(false, "show_weights turns off");
		return;
	}
	defer off.free();
	test::@check((off.get_string("showing") ?? "") == "off", "and off takes the view away again");
}

fn void show_weights_refuses_a_view_it_does_not_have() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(
		f.refuses_tool("show_weights", `{"mode":"heatmap"}`, "heatmap", "territory", "falloff", "off"),
		"a view that does not exist is refused with the ones that do");
	test::@check(
		f.refuses_tool("show_weights", `{}`, "mode", "territory"),
		"and a call with no mode says which field it wanted");
}

// ---------------------------------------------------------------------------
// screenshot
//
// The only tool whose answer is not text, so the only one whose wrapping is
// worth a check of its own: an image block reaches a client as JSON with a
// base64 `data` member, and the escaped-into-text treatment every other tool
// gets would deliver the characters of that JSON instead.
//
// The renderer is stood in for. `AppState.screenshot` is a hook precisely so
// that something with no GPU can fill it, and a 4x2 PNG exercises every step
// from the grab through the decode to the base64 on the wire.

// A 4x2 checker, written where a renderer would have written its frame. `ctx`
// is a bool the check reads back, since "was the hook called at all" is not
// answerable from the response alone.
fn bool fake_grab(void* ctx, String path) @local
{
	char[4 * 2 * 4] pixels;
	foreach (i, &channel : pixels) *channel = (i / 4) % 2 == 0 ? 0 : 255;

	image::Image picture = {
		.width = 4,
		.height = 2,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels[..],
	};
	if (catch png::save_file(&picture, path)) return false;

	*(bool*)ctx = true;
	return true;
}

// A hook that reports failure without writing anything — a window on its way
// closed, which is not the same as having no window at all.
fn bool refusing_grab(void* ctx, String path) @local => false;

// A window-sized stand-in for the render checks: big enough that the tiling has
// real rows to move and the sheet's size is arithmetic rather than a floor. The
// 4x2 checker above is right for screenshot, where the picture's size is the
// whole assertion, and too small here.
fn bool wide_grab(void* ctx, String path) @local
{
	char[64 * 40 * 4] pixels;
	foreach (i, &channel : pixels) *channel = (char)(i % 251);

	image::Image picture = {
		.width = 64,
		.height = 40,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels[..],
	};
	if (catch png::save_file(&picture, path)) return false;

	*(int*)ctx = *(int*)ctx + 1;
	return true;
}

fn bool? screenshot_body(Object* root, String* mime, String* data, String* caption)
{
	Object* content = root.get("result")!.get("content")!;
	if (content.get_len() != 2) return false;

	Object* picture = content.get_at(0);
	if (picture.get_string("type")! != "image") return false;
	*mime = picture.get_string("mimeType")!;
	*data = picture.get_string("data")!;

	Object* text = content.get_at(1);
	if (text.get_string("type")! != "text") return false;
	*caption = text.get_string("text")!;
	return true;
}

fn void screenshot_answers_with_a_picture() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	bool grabbed = false;
	f.app.screenshot = &fake_grab;
	f.app.screenshot_ctx = &grabbed;

	Object*? root = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}`);
	if (catch root)
	{
		test::@check(false, "screenshot answers");
		return;
	}
	defer root.free();

	String mime;
	String data;
	String caption;
	if (!(screenshot_body(root, &mime, &data, &caption) ?? false))
	{
		test::@check(false, "screenshot answers with an image block and a caption");
		return;
	}

	test::@check(grabbed, "screenshot draws a frame rather than reusing one");
	test::@check(mime == "image/png", "and declares it a PNG");
	test::@check(caption == "4 x 2 pixels", "and says how big the picture is");

	// The base64 is the file, not a description of it: decoded, it starts with
	// the PNG signature. A tool that answered with an escaped JSON document
	// would pass every check above and fail this one.
	char[]? decoded = base64::decode(mem, (char[])data);
	if (catch decoded)
	{
		test::@check(false, "the image data is base64");
		return;
	}
	defer alloc::free(mem, decoded);
	char[8] signature = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
	test::@check(decoded.len > 8 && decoded[:8] == signature[..], "and decodes to a PNG");
}

fn void screenshot_says_when_there_is_nothing_to_photograph() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// No hook: an AppState built by anything but `main`, which is every check and
	// every headless run.
	Object*? root = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}`);
	if (catch root)
	{
		test::@check(false, "screenshot answers with no window");
		return;
	}
	defer root.free();
	test::@check(error_code_is(root, -32603) && error_message_contains(root, "no window"),
		"a crig with no window says so rather than answering with a blank picture");

	f.app.screenshot = &refusing_grab;
	Object*? refused = f.request(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}`);
	if (catch refused)
	{
		test::@check(false, "screenshot answers a refused grab");
		return;
	}
	defer refused.free();
	test::@check(error_code_is(refused, -32603) && error_message_contains(refused, "no frame was drawn"),
		"and a frame that did not happen is an error, not an empty image block");
}

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
// turning table in anim/animation.c3.
const String QUARTER_TURN_AXIS @local = `{"axis":[1,0,0],"angle":1.5707963267948966}`;
const String QUARTER_TURN_QUAT @local = `{"x":0.7071067811865476,"y":0,"z":0,"w":0.7071067811865476}`;
const String QUARTER_TURN_EULER @local = `[1.5707963267948966,0,0]`;

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

// ---------------------------------------------------------------------------
// World space
//
// `AnimTemplate.pose` composes authored[j] = authored[parent] · turn, so an
// entry's axis is the parent's as the clip has already turned it. These pin what
// "space":"world" buys over that, on the one arrangement where the two genuinely
// disagree: the hips turned a quarter about X, and something below them asked to
// go on pointing the way it rests.

// The hips turned a quarter about X. The root has no parent to be measured
// against, so this entry means the same in either frame — which is what leaves
// the joint below it as the only thing under test.
const String HIPS_QUARTER @local = `{"name":"hips","rotation":{"axis":[1,0,0],"angle":1.5707963267948966}}`;

// Identity, which in world space means "keep pointing where you rest" and in
// local space means "keep riding your parent". Those are different instructions
// and this is the clip that tells them apart.
fn String level_clip(String name, String joint, String space)
{
	String joints = string::format(
		mem,
		`%s,{"name":"%s","rotation":{"x":0,"y":0,"z":0,"w":1},"space":"%s"}`,
		HIPS_QUARTER,
		joint,
		space);
	defer alloc::free(mem, joints);

	return string::format(
		mem,
		`{"name":"%s","duration":1,"keyframes":[{"time":0,"joints":[%s]},{"time":1,"joints":[%s]}]}`,
		name,
		joints,
		joints);
}

fn float[<4>]? posed_turn(Object* pose, String name)
{
	Object* joints = pose.get("joints")!;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* joint = joints.get_at(i);
		if (joint.get_string("name")! != name) continue;
		Object* turn = joint.get("rotation")!;
		return {
			(float)turn.get_float_at(0)!,
			(float)turn.get_float_at(1)!,
			(float)turn.get_float_at(2)!,
			(float)turn.get_float_at(3)!,
		};
	}
	return NOT_FOUND~;
}

// A quaternion carrying no turn. Read off the scalar part alone, and through its
// magnitude: q and -q are the same rotation, so a check on the sign would fail
// on an answer that is right.
fn bool turns_nothing(float[<4>] turn) => math::abs(math::abs(turn[3]) - 1.0f) < 0.001f;

// Where the fixture's foot lands with the hips turned a quarter about X: the
// knee swings back to (0, 1, -0.5) either way, and then the foot either hangs
// straight down from it in world axes or goes on riding the hips.
const Vec3 FOOT_UNDER_A_LEVEL_KNEE @local = { 0, 0.5, -0.5 };
const Vec3 FOOT_RIDING_THE_HIPS @local = { 0, 1, -1 };

fn void a_world_entry_states_where_the_joint_points() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = level_clip("level_world", "knee", "world");
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "a keyframe entry may ask for world space");
		return;
	}
	applied.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"level_world","t":0}`);
	if (catch pose)
	{
		test::@check(false, "a world-space clip samples");
		return;
	}
	defer pose.free();

	float[<4>] knee = posed_turn(pose, "knee") ?? (float[<4>]){ 0, 0, 0, 0 };
	Vec3 foot = posed_at(pose, "foot") ?? (Vec3){ 100, 100, 100 };

	// The whole point of the frame: the hips turned and the knee did not, which
	// is only expressible against the model's own axes.
	test::@check(turns_nothing(knee), "a world-space entry lands the joint at the orientation it asked for");
	test::@check((foot - FOOT_UNDER_A_LEVEL_KNEE).length() < 0.001f,
		"and everything below it follows that orientation, not the parent's — foot at (%.4f, %.4f, %.4f)",
		foot.x, foot.y, foot.z);
}

fn void the_same_entry_in_local_space_means_something_else() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = level_clip("level_local", "knee", "local");
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "local is a space a keyframe entry may name");
		return;
	}
	applied.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"level_local","t":0}`);
	if (catch pose)
	{
		test::@check(false, "a local-space clip samples");
		return;
	}
	defer pose.free();

	Vec3 foot = posed_at(pose, "foot") ?? (Vec3){ 100, 100, 100 };
	// Identity against the parent leaves the knee riding the hips, so the foot
	// ends up somewhere else entirely. A conversion that quietly did nothing —
	// or did the same thing in both frames — fails here rather than passing the
	// check above by accident.
	test::@check((foot - FOOT_RIDING_THE_HIPS).length() < 0.001f,
		"the same entry read against the parent leaves the joint riding it — foot at (%.4f, %.4f, %.4f)",
		foot.x, foot.y, foot.z);
	test::@check((FOOT_UNDER_A_LEVEL_KNEE - FOOT_RIDING_THE_HIPS).length() > 0.1f,
		"the two frames are asserted against genuinely different answers");
}

fn void a_joint_a_world_keyframe_skips_inherits_its_parent() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// The knee is not named at all, and the foot below it is stated in world
	// space. Working the foot's turn out needs the knee's world orientation,
	// which is its parent's exactly — the same answer `pose` gives a joint no
	// keyframe drives. Treating the gap as identity instead would leave the foot
	// riding the hips.
	String arguments = level_clip("level_gap", "foot", "world");
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "a world-space clip may leave a joint in the chain unnamed");
		return;
	}
	applied.free();

	Object*? pose = f.call_tool("get_pose", `{"clip":"level_gap","t":0}`);
	if (catch pose)
	{
		test::@check(false, "a clip with a gap in the chain samples");
		return;
	}
	defer pose.free();

	float[<4>] foot = posed_turn(pose, "foot") ?? (float[<4>]){ 0, 0, 0, 0 };
	test::@check(turns_nothing(foot),
		"a joint the keyframe skips carries its parent's world orientation, not identity");
}

fn void sparse_channels_round_trip_and_ignore_unrelated_key_times() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	const String CLIP = `{"name":"sparse","duration":1,"keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0,0,0]}]},{"time":0.25,"joints":[{"name":"hips","move":[0.1,0,0]}]},{"time":1,"joints":[{"name":"knee","rotation":[1.5707963267948966,0,0]}]}]}`;
	Object*? applied = f.call_tool("apply_clip", CLIP);
	if (catch applied) { test::@check(false, "apply_clip accepts independent sparse channels"); return; }
	applied.free();

	Object*? read = f.call_tool("get_clip", `{"clip":"sparse"}`);
	if (catch read) { test::@check(false, "get_clip reads sparse channels back"); return; }
	defer read.free();
	Object* keys = read.get("keyframes")!!;
	Object* rotation = keys.get_at(0).get("joints")!!.get_at(0);
	Object* translation = keys.get_at(1).get("joints")!!.get_at(0);
	test::@check(@ok(rotation.get("rotation")) && !@ok(rotation.get("move")),
		"a rotation-only key grew a translation channel");
	test::@check(@ok(translation.get("move")) && !@ok(translation.get("rotation")),
		"a translation-only key grew a rotation channel");

	Object*? pose = f.call_tool("get_pose", `{"clip":"sparse","t":0.25}`);
	if (catch pose) { test::@check(false, "the sparse clip samples at the unrelated hips key"); return; }
	defer pose.free();
	Vec3 knee = posed_at(pose, "knee")!!;
	Vec3 foot = posed_at(pose, "foot")!!;
	test::@check((foot - knee).z < -0.1f,
		"the unrelated hips key interrupted the knee's own rotation track");
}

fn void a_world_key_samples_ancestor_tracks_at_other_times() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	const String CLIP = `{"name":"world-between","duration":1,"keyframes":[{"time":0,"joints":[{"name":"hips","rotation":[0,0,0]}]},{"time":0.5,"joints":[{"name":"foot","space":"world","rotation":[0,0,0]}]},{"time":1,"joints":[{"name":"hips","rotation":[1.5707963267948966,0,0]}]}]}`;
	Object*? applied = f.call_tool("apply_clip", CLIP);
	if (catch applied) { test::@check(false, "a world key may sit between its ancestor's keys"); return; }
	applied.free();
	Object*? pose = f.call_tool("get_pose", `{"clip":"world-between","t":0.5}`);
	if (catch pose) { test::@check(false, "the world-space sparse clip samples"); return; }
	defer pose.free();
	float[<4>] knee = posed_turn(pose, "knee") ?? (float[<4>]){};
	float[<4>] foot = posed_turn(pose, "foot") ?? (float[<4>]){};
	test::@check(!turns_nothing(knee), "the hips ancestor track was not sampled between its own keys");
	test::@check(turns_nothing(foot), "the world foot key did not compensate the sampled ancestor track");
}

fn void a_space_that_is_neither_is_refused() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":93,"method":"tools/call","params":{"name":"apply_clip","arguments":{"name":"sideways","duration":1,"keyframes":[{"time":0,"joints":[{"name":"knee","space":"sideways","rotation":[0,0,0]}]}]}}}`);
	if (catch root)
	{
		test::@check(false, "an unknown space answers");
		return;
	}
	defer root.free();
	test::@check(error_message_contains(root, `space is "sideways"`)
		&& error_message_contains(root, "local")
		&& error_message_contains(root, "world"),
		"a space that is neither names the value and both that would have been taken");
}

fn void the_three_rotation_forms_agree() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	Vec3[3] feet;
	String[3] names = { "as_axis", "as_quaternion", "as_euler" };
	String[3] rotations = { QUARTER_TURN_AXIS, QUARTER_TURN_QUAT, QUARTER_TURN_EULER };

	foreach (i, name : names)
	{
		String arguments = bend_clip(name, rotations[i]);
		defer alloc::free(mem, arguments);

		Object*? applied = f.call_tool("apply_clip", arguments);
		if (catch applied)
		{
			test::@check(false, "apply_clip accepts every rotation form");
			return;
		}
		applied.free();

		String ask = string::format(mem, `{"clip":"%s","t":0.5}`, name);
		defer alloc::free(mem, ask);

		Object*? pose = f.call_tool("get_pose", ask);
		if (catch pose)
		{
			test::@check(false, "get_pose answers for every rotation form");
			return;
		}
		defer pose.free();

		Vec3? at = posed_at(pose, "foot");
		if (catch at)
		{
			test::@check(false, "the posed foot comes back");
			return;
		}
		feet[i] = at;
	}

	test::@check((feet[0] - feet[1]).length() < 0.0001f && (feet[0] - feet[2]).length() < 0.0001f,
		"a quaternion, an axis and angle, and euler radians land the same turn");
}

fn void the_same_name_replaces() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	String arguments = `{"name":"bend","duration":2,"keyframes":[{"time":0,"joints":[]},{"time":1,"joints":[{"name":"knee","rotation":[0.5,0,0]}]}]}`;

	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip accepts a rewrite");
		return;
	}
	defer applied.free();
	test::@check((applied.get_bool("replaced") ?? false) == true, "rewriting a clip under the same name says it replaced one");

	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after a rewrite");
		return;
	}
	defer scene.free();
	test::@check(authored_in_scene_body(scene, 2.0f, 4) ?? false, "the rewrite replaces the clip rather than adding a second of the name");
}

<*
 The one wrinkle the authored pack has: it is not on disk, and `load_packs`
 frees the whole library to re-read the folder.
*>
fn void the_authored_pack_survives_a_library_reload() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	f.app.load_packs(library::ready());

	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after a reload");
		return;
	}
	defer scene.free();

	test::@check(scene_clip_count(scene_pack(scene, "Authored")) == 4,
		"re-reading the library keeps the clips an agent wrote, which no file can give back");
}

fn void a_clip_says_what_was_wrong_with_it() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"thigh_L","move":[0,0,0]}]}]}`,
			"thigh_L", "not a dot on this rig", "knee", "foot"),
		"an unknown joint is named, and so is every dot that would have worked");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"bone_4","move":[0,0,0]}]}]}`,
			"bone_4", "name the dot before animating it"),
		"a dot addressed by the bone_<id> get_skeleton shows is told why that cannot work");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0},{"time":0.5},{"time":0.25}]}`,
			"keyframes[2]", "0.25", "increasing time order"),
		"a keyframe out of order names itself, its time and the rule");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"joints":[{"name":"knee","move":[0,0,0]}]}]}`,
			"keyframes[0]", `"time"`),
		"a keyframe with no time says which field is missing");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":"soon"}]}`,
			"keyframes[0]", `"time"`),
		"a time that is not a number is refused rather than read as zero");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"knee","move":[0,0,0]},{"name":"knee","move":[0,0,0]}]}]}`,
			"twice", "joints[0]", "joints[1]"),
		"one joint named twice in a keyframe names both entries");

	test::@check(f.refuses(
			`{"name":"walk","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":"sideways"}]}]}`,
			"quaternion", "axis", "euler"),
		"a rotation in none of the three forms lists the three forms");

	test::@check(f.refuses(
			`{"name":"still","keyframes":[{"time":0,"joints":[{"name":"knee","move":[0,0,0]}]}]}`,
			"duration", "no length"),
		"a clip with no length is refused rather than stored unplayable");

	test::@check(f.refuses(
			`{"name":"walk","duration":0.5,"keyframes":[{"time":0},{"time":2}]}`,
			"never reaches", "0.5", "2"),
		"a duration shorter than the last keyframe is refused");

	test::@check(f.refuses(
			`{"name":"walk","duration":"a while","keyframes":[{"time":0},{"time":1}]}`,
			"duration", "must be a number"),
		"a duration that is not a number is refused rather than quietly ignored");

	test::@check(f.refuses(`{"keyframes":[{"time":0}]}`, `"name"`),
		"a clip with no name says which field is missing");

	test::@check(f.refuses(`{"name":"walk"}`, "keyframes"),
		"a clip with no keyframes says which field is missing");
}

<*
 Optional fields written as null, and an entry that then keys nothing.

 A client that builds its arguments from a record with defaults sends
 `"rotation": null` where a hand-written payload would omit the key, and the two
 say the same thing: this entry has no rotation channel. It remains valid when a
 move channel is present; with both channels absent there is no key to write and
 the entry is refused rather than silently disappearing.
*>
fn void a_null_field_reads_as_a_missing_one() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses(
		`{"name":"empty-null","duration":0.5,"keyframes":[{"time":0.5,"joints":[{"name":"knee","rotation":null,"move":null}]}]}`,
		"needs rotation or move", "explicitly"),
		"an entry whose two null fields key nothing is refused clearly");

	Object*? applied = f.call_tool("apply_clip",
		`{"name":"nulls","duration":null,"keyframes":[{"time":0,"joints":null},{"time":0.5,"joints":[{"name":"knee","rotation":null,"move":[0,0,0]}]}]}`);
	if (catch applied)
	{
		test::@check(false, "a null rotation is absent while an explicit zero move remains a key");
		return;
	}
	defer applied.free();

	test::@check((applied.get_float("duration") ?? 0.0) == 0.5,
		"and a null duration falls back to the last keyframe rather than erroring");
}

<*
 Rewriting the clip that is on screen.

 The player holds a *copy* of the template, pointing at keyframes the rewrite
 frees, so this is the one path in `put_authored_clip` where getting it wrong is
 a use-after-free rather than a wrong answer. Asserting the running copy carries
 the new duration is what proves it was retaken and not merely left alone.
*>
fn void rewriting_the_running_clip_restarts_it() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	crig::AnimRef ref = crig::resolve_clip(&f.app, "bend") ?? crig::NO_ANIM;
	if (!f.app.play_clip(ref))
	{
		test::@check(false, "the applied clip plays");
		return;
	}

	String arguments = `{"name":"bend","duration":3,"keyframes":[{"time":0,"joints":[]},{"time":1.5,"joints":[{"name":"knee","rotation":[0.25,0,0]}]}]}`;
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip accepts a rewrite of the running clip");
		return;
	}
	defer applied.free();

	test::@check(f.app.animating
		&& f.app.current_ref.same(ref)
		&& f.app.current_anim.duration == 3.0f
		&& (applied.get_bool("playing") ?? false) == true,
		"rewriting the clip on screen leaves it playing, from the new keyframes");

	f.app.stop_animation();
}

fn void a_refused_clip_changes_nothing() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene)
	{
		test::@check(false, "get_scene answers after the refusals");
		return;
	}
	defer scene.free();

	test::@check(scene_clip_count(scene_pack(scene, "Authored")) == 4,
		"nine refused clips left the library exactly as it was");
}

// ---------------------------------------------------------------------------
// play and stop
//
// The one pair whose result is meant to be looked at rather than read back, so
// each check asserts both halves: what the tool answered, and what the player
// on `AppState` — the thing the window draws from — is actually doing.

fn bool? playing_body(Object* played, String clip, double time, double duration, bool loop)
{
	bool ok = played.get_bool("playing")! == true;
	ok = ok && played.get_string("clip")! == clip;
	ok = ok && played.get_string("pack")! == "Authored";
	ok = ok && math::abs(played.get_float("time")! - time) < 1e-6;
	ok = ok && math::abs(played.get_float("duration")! - duration) < 1e-6;
	ok = ok && played.get_bool("loop")! == loop;
	// Nothing was fitted: the fixture placed its own rig before any of this.
	ok = ok && played.get_bool("fitted")! == false;
	return ok;
}

fn void play_starts_what_the_user_would_see() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? played = f.call_tool("play", `{"clip":"bend","t":1.5}`);
	if (catch played)
	{
		test::@check(false, "play accepts a clip in the library");
		return;
	}
	defer played.free();

	crig::AnimRef ref = crig::resolve_clip(&f.app, "bend") ?? crig::NO_ANIM;
	test::@check((playing_body(played, "bend", 1.5, 3.0, false) ?? false)
		&& f.app.animating
		&& f.app.current_ref.same(ref)
		&& f.app.anim_time == 1.5f,
		"play starts the clip on the live player, at the time it was asked for");
}

<*
 The loop override, and the half of it that is easy to get wrong.

 `current_anim` is a copy of the template, so overriding the copy's flag is what
 keeps the override to this run. Writing it through to the library instead would
 change a clip nobody asked to edit — and, for a clip read off disk, silently
 disagree with the file it came from.
*>
fn void play_loops_only_this_run() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? played = f.call_tool("play", `{"clip":"bend","loop":true}`);
	if (catch played)
	{
		test::@check(false, "play accepts a loop override");
		return;
	}
	defer played.free();

	crig::AnimRef ref = crig::resolve_clip(&f.app, "bend") ?? crig::NO_ANIM;
	crig::AnimTemplate* stored = f.app.clip(ref);
	test::@check((played.get_bool("loop") ?? false) == true
		&& f.app.current_anim.loop == true
		&& stored != null && stored.loop == false,
		"loop:true wraps the run without editing the clip it played");
}

fn void play_wraps_a_looping_time() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;
	// Two and a half turns through a three-second clip.
	Object*? played = f.call_tool("play", `{"clip":"bend","t":7.5,"loop":true}`);
	if (catch played)
	{
		test::@check(false, "play accepts a time past the end of a looping clip");
		return;
	}
	defer played.free();

	test::@check((playing_body(played, "bend", 1.5, 3.0, true) ?? false) && f.app.anim_time == 1.5f,
		"a time past the end of a looping clip wraps, as playback does");
}

<*
 A refused play leaves the player exactly as it was.

 Asserted here rather than in a check of its own because the refusal only has
 something to disturb while something is running: this one arrives with the
 looping clip from the check above still on screen.
*>
fn void play_refuses_a_time_past_a_one_shot() @test
{
	Fixture fixture;
	fixture.open_playing();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses_tool("play", `{"clip":"bend","t":7.5}`, "7.5", "3", "does not loop")
		&& f.app.animating
		&& f.app.anim_time == 1.5f,
		"a time past the end of a clip that does not loop is refused, and nothing stops playing");
}

<*
 A chain slack enough that the lag is the whole point.

 A flexibility of 1 is the loosest spring a chain has — see
 `secondary_stiffness` — so this one closes under a hundredth of its gap per
 substep and crosses the turn a step behind the keyframes the whole way. No
 gravity, deliberately: the fixture's leg hangs straight down, where gravity
 pulls along the chain and would prove nothing about anything.
*>
const crig::SecondaryChain SLACK_CHAIN @local = {
	.preset = crig::SecondaryPreset.CUSTOM,
	.flexibility = 1.0f,
	.damping = 0.1f,
	.gravity = 0.0f,
	.collide = false,
};

// The fixture's knee-to-foot run as that chain.
fn crig::SecondaryChain slack_leg(Fixture* f) @local
{
	crig::SecondaryChain chain = SLACK_CHAIN;
	chain.root = named_dot(f, "knee");
	chain.tip = named_dot(f, "foot");
	return chain;
}

// A second and a half of playback, hand-driven. Real frames would make this a
// check of this machine's frame rate; the sim's own substep is fixed either way.
const usz PLAYED_FRAMES @local = 90;
const float PLAYED_STEP @local = 1.0f / 60.0f;

// One run of `bend` from the top, ticked a frame at a time, and where it left
// the foot on screen — `dot_position` is what the overlay draws and what a click
// lands on, so it is the posed answer rather than a private one.
fn Vec3 played_foot(Fixture* f, String arguments, uint foot) @local
{
	Object*? played = f.call_tool("play", arguments);
	if (catch played)
	{
		test::@check(false, "play accepts %s", arguments);
		return { 0, 0, 0 };
	}
	played.free();

	for (usz i = 0; i < PLAYED_FRAMES; i++) f.app.tick_animation(PLAYED_STEP);

	crig::Dot* dot = f.app.doc.find(foot);
	return dot ? f.app.dot_position(*dot) : (Vec3){ 0, 0, 0 };
}

<*
 The dynamic bones run under the clip, and `sim` is what turns them off.

 The seam the live preview is: `refresh_animation` samples the clip, the sim is
 advanced against that pose, and the palette everything below reads is built
 from what the sim wrote — so a dynamic knee lands the foot somewhere no
 keyframe put it. Both halves are asserted against the same clip on the same
 frames, because "physics happened" and "physics happened only when asked" are
 one claim measured twice.

 Through `play` rather than through the player, since the flag is the tool's;
 the player is what the ticks below drive, so the seam is exercised either way.
*>
fn void play_simulates_the_dynamic_bones() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;

	// Knee and foot together: a chain of one bone would turn a leaf, and turning
	// a leaf moves nothing. What the check reads is the foot's *position*, which
	// is the knee's rotation carried down the bone.
	f.app.set_secondary_recorded(slack_leg(f));
	f.app.undo_stack.commit();
	uint foot = named_dot(f, "foot");

	Vec3 keyed = played_foot(f, `{"clip":"bend","sim":false}`, foot);
	Vec3 simulated = played_foot(f, `{"clip":"bend"}`, foot);

	// Neither bound is a tuning. The solve is deterministic and lands at about
	// 0.003 — a hundred-and-seventieth of the bone it hangs off, with the
	// loosest spring a chain has — so the floor is well under what the physics
	// actually does and far over anything float noise could produce, and half a
	// bone is what separates a lag from a solve that blew up and threw the foot
	// across the room.
	float lag = (simulated - keyed).length();
	test::@check(lag > 0.001f && lag < 0.5f,
		"the physics carries the foot off the keyed pose without tearing it off the knee (%.4f)", lag);

	// A repaint is not a frame: `refresh_animation` with no dt in it runs no
	// substeps and still writes, which is what holds a settled tail in place
	// instead of snapping it back onto the keyframes.
	f.app.refresh_animation();
	crig::Dot* dot = f.app.doc.find(foot);
	Vec3 held = dot ? f.app.dot_position(*dot) : (Vec3){ 0, 0, 0 };
	test::@check((held - simulated).length() < 1.0e-5f,
		"and a repaint with no time in it holds the tail where it settled");
}

<*
 A bake on a rig with nothing dynamic is refused, and the refusal says where the
 setting it is missing lives.

 The ordinary state — no rig has a dynamic bone until somebody says so — which
 is exactly why the sentence has to carry a caller who has never met the
 feature. Baking a copy of the clip instead would look like it worked.
*>
fn void bake_physics_says_when_the_rig_has_nothing_dynamic() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(
		f.refuses_tool("bake_physics", `{"clip":"bend"}`, "no secondary motion", "property of the rig"),
		"a bake with nothing dynamic says so, and says that physics is set on the rig rather than on the clip");
	test::@check(
		f.refuses_tool("bake_physics", `{"clip":"waltz"}`, "waltz", "The library holds"),
		"and an unknown clip is still named, with what could have been asked for instead");
}

<*
 A bake lands the simulation in the Authored pack as a clip of its own.

 The whole of what M4 is for, over the wire: the same knee and foot the live
 preview swings, recorded into keys that need no solver to play back. Three
 things are asserted and they are the three an agent would ask — where it
 landed, how densely, and which bones the answer is about.

 `hz` is asked for as 50 on purpose. The solver's grid is 1/120 s, so 50 is not
 expressible and the bake snaps to 60; a caller told "50" would go looking for
 its keys in the wrong places.
*>
fn void bake_physics_lands_the_simulation_as_a_clip() @test
{
	Fixture fixture;
	fixture.open_played();
	defer fixture.close();
	Fixture* f = &fixture;

	f.app.set_secondary_recorded(slack_leg(f));
	f.app.undo_stack.commit();

	Object*? answered = f.call_tool("bake_physics", `{"clip":"bend","name":"bend baked","hz":50}`);
	if (catch answered)
	{
		test::@check(false, "bake_physics answers");
		return;
	}
	defer answered.free();

	test::@check((answered.get_string("clip") ?? "") == "bend baked"
		&& (answered.get_string("pack") ?? "") == "Authored"
		&& (answered.get_string("source") ?? "") == "bend"
		&& (answered.get_bool("replaced") ?? true) == false,
		"the baked clip lands in the Authored pack under the name it was given");

	// Three seconds at 60 samples a second, plus the closing key on the duration
	// itself. Stated exactly rather than as "more than none": a bake that lost
	// its grid would still write keyframes.
	test::@check((answered.get_int("keyframes") ?? 0) == 181
		&& math::abs((answered.get_float("samples_hz") ?? 0.0) - 60.0) < 1.0e-6,
		"sampled on the solver's own grid, and the rate reported is the one used rather than the one asked for");

	Object*? dynamic = answered.get("dynamic_joints");
	bool named_both = false;
	if (try dynamic)
	{
		named_both = dynamic.get_len() == 2
			&& (dynamic.get_string_at(0) ?? "") == "knee"
			&& (dynamic.get_string_at(1) ?? "") == "foot";
	}
	test::@check(named_both, "and the answer names the bones it is about, nearest the body first");

	crig::AnimPack* pack = f.app.authored();
	bool held = false;
	if (pack)
	{
		foreach (clip : pack.clips)
		{
			if (clip.name == "bend baked" && clip.keyframes.len == 181) held = true;
		}
	}
	test::@check(held, "and the pack really holds it, not merely the answer");
}

// ---------------------------------------------------------------------------
// set_secondary_motion
//
// The authoring half of the feature, and the only one an agent can reach without
// a clip. What is worth pinning is not that the setter works — recorded.c3's own
// checks cover that — but that the wire surface says the same thing the document
// holds: the preset a bare entry resolves to, the tip a root alone infers, the
// shapes that are refused by name, and that a refusal really does leave the rig
// where it found it.

// One dot's row in get_skeleton's `dots` array, or null when no dot answers.
fn Object* skeleton_dot(Object* skeleton, String name) @local
{
	Object*? dots = skeleton.get("dots");
	if (catch dots) return null;

	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* dot = dots.get_at(i);
		if ((dot.get_string("name") ?? "") == name) return dot;
	}
	return null;
}

// The chain rooted at a named dot in get_skeleton's `secondary` list, or null
// where there is none.
fn Object* skeleton_chain(Object* skeleton, String root) @local
{
	Object*? chains = skeleton.get("secondary");
	if (catch chains) return null;

	for (sz i = 0; i < chains.get_len(); i++)
	{
		Object* chain = chains.get_at(i);
		if ((chain.get_string("root") ?? "") == root) return chain;
	}
	return null;
}

// Whether a chain row names these joints, root first.
fn bool chain_runs(Object* chain, String... joints) @local
{
	if (chain == null) return false;
	Object*? run = chain.get("joints");
	if (catch run) return false;
	if (run.get_len() != (sz)joints.len) return false;
	foreach (usz i, joint : joints)
	{
		if ((run.get_string_at((sz)i) ?? "") != joint) return false;
	}
	return true;
}

<*
 A chain added over the wire, with every value resolved in the answer, and
 get_skeleton reading the whole of it back.

 The readback is the half that matters: `set_secondary_motion` answering with
 numbers it was just handed proves nothing, and an agent's next call is
 `get_skeleton`. The entry names no tip on purpose — the inferred run and the
 preset's resolved values are the two things a caller cannot work out for
 themselves, and they have to be in the answer rather than only in the schema.
*>
fn void set_secondary_motion_adds_a_chain_and_get_skeleton_reads_it_back() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? answered = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"knee","preset":"hair","flexibility":0.8,"gravity":0.25}],`
		`"colliders":[{"joint":"knee"}]}`);
	if (catch answered)
	{
		test::@check(false, "set_secondary_motion answers");
		return;
	}
	defer answered.free();

	Object*? rows = answered.get("chains");
	bool resolved = false;
	if (try rows && rows.get_len() == 1)
	{
		Object* row = rows.get_at(0);
		// Hair's damping stays where the preset put it; the rest is what the entry
		// said; the tip is the end of the run below the knee.
		resolved = (row.get_string("root") ?? "") == "knee"
			&& (row.get_string("tip") ?? "") == "foot"
			&& chain_runs(row, "knee", "foot")
			&& (row.get_string("preset") ?? "") == "hair"
			&& math::abs((row.get_float("flexibility") ?? 0.0) - 0.8) < 1.0e-6
			&& math::abs((row.get_float("damping") ?? 0.0) - 0.6) < 1.0e-6
			&& math::abs((row.get_float("gravity") ?? 0.0) - 0.25) < 1.0e-6
			&& (row.get_bool("collide") ?? false)
			&& (row.get_bool("added") ?? false);
	}
	test::@check(resolved, "set_secondary_motion answers with the tip inferred and every omitted value resolved from the preset");

	// knee sits half a unit above foot, and foot is the tail knee's bone runs to,
	// so a capsule with no radius given is an eighth of a unit.
	Object*? capsules = answered.get("colliders");
	bool sized = false;
	if (try capsules)
	{
		sized = capsules.get_len() == 1
			&& (capsules.get_at(0).get_string("joint") ?? "") == "knee"
			&& math::abs((capsules.get_at(0).get_float("radius") ?? 0.0) - 0.125) < 1.0e-6;
	}
	test::@check(sized, "and sizes an omitted collider radius at a quarter of the bone it sweeps");

	// The counts are read back through the same resolver the viewport and the
	// bake use, which is the only thing that tells a chain of two from two of one.
	test::@check((answered.get_int("chain_count") ?? 0) == 1
		&& (answered.get_int("dynamic_bones") ?? 0) == 2
		&& (answered.get_int("capsules") ?? 0) == 1,
		"and reports the knee and the foot as one chain of two");

	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers after set_secondary_motion");
		return;
	}
	defer skeleton.free();

	Object* knee = skeleton_chain(skeleton, "knee");
	bool carried = knee != null;
	if (carried)
	{
		carried = (knee.get_string("tip") ?? "") == "foot"
			&& chain_runs(knee, "knee", "foot")
			&& (knee.get_string("preset") ?? "") == "hair"
			&& math::abs((knee.get_float("flexibility") ?? 0.0) - 0.8) < 1.0e-4
			&& math::abs((knee.get_float("damping") ?? 0.0) - 0.6) < 1.0e-4
			&& math::abs((knee.get_float("gravity") ?? 0.0) - 0.25) < 1.0e-4;
	}
	test::@check(carried, "get_skeleton carries the same chain back in the same shape");

	// The two numbers a chain no longer has are refused by name, with where
	// each of them went: a cone was a bound on the solver alone, the joint's
	// own limits are the rig's; a thickness is measured now, not typed.
	test::@check(f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","swing":0.4}]}`, "swing", "rotation limits"),
		"a swing on a chain is refused with where the limit lives now");
	test::@check(f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","thickness":0.05}]}`, "thickness", "skin"),
		"a thickness on a chain is refused with where the number comes from now");

	// Chains are a list beside the joints, not a field on every dot: the dots
	// say nothing, which is what keeps the answer for a rig with no physics
	// byte-identical to what it always was.
	Object* foot = skeleton_dot(skeleton, "foot");
	bool bare = foot != null && skeleton_chain(skeleton, "foot") == null;
	if (foot != null)
	{
		if (try Object* held = foot.get("physics")) bare = false;
		if (try Object* held = foot.get("secondary")) bare = false;
	}
	test::@check(bare, "and a bone inside the run is not reported as a chain of its own");

	Object*? read_capsules = skeleton.get("colliders");
	bool listed = false;
	if (try read_capsules)
	{
		listed = read_capsules.get_len() == 1
			&& (read_capsules.get_at(0).get_string("joint") ?? "") == "knee"
			&& math::abs((read_capsules.get_at(0).get_float("radius") ?? 0.0) - 0.125) < 1.0e-4;
	}
	test::@check(listed, "and the capsules come back as a list beside the joints");
}

<*
 A root alone is a whole tail, and a second call on the same root retunes it.

 Naming only the root is the difference between authoring a braid in one entry
 and authoring it in eleven, and the rule it walks is the rig's own shape rather
 than a length anybody configures: down while there is exactly one child. The
 second call states one value and keeps the rest, which is what makes "a bit
 looser" one field rather than a restatement of the whole chain.
*>
fn void a_root_alone_infers_the_run_and_a_second_call_retunes_it() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? answered = f.call_tool("set_secondary_motion", `{"chains":[{"root":"knee"}]}`);
	if (catch answered)
	{
		test::@check(false, "set_secondary_motion takes a bare root");
		return;
	}
	defer answered.free();

	Object*? rows = answered.get("chains");
	bool walked = false;
	if (try rows && rows.get_len() == 1)
	{
		Object* row = rows.get_at(0);
		// Tail is the preset a bare entry starts from, and these are Tail's values.
		walked = chain_runs(row, "knee", "foot")
			&& (row.get_string("preset") ?? "") == "tail"
			&& math::abs((row.get_float("flexibility") ?? 0.0) - 0.4) < 1.0e-6
			&& math::abs((row.get_float("damping") ?? 0.0) - 0.7) < 1.0e-6
			&& math::abs((row.get_float("gravity") ?? 0.0) - 1.0) < 1.0e-6
			&& (row.get_bool("collide") ?? false);
	}
	test::@check(walked && (answered.get_int("chain_count") ?? 0) == 1
		&& (answered.get_int("dynamic_bones") ?? 0) == 2,
		"a bare root infers the run below it and starts from Tail");

	// And the document really holds the chain, not merely the answer.
	crig::SecondaryChain held = f.app.doc.secondary_of(named_dot(f, "knee"));
	test::@check(held.present() && held.tip == named_dot(f, "foot"),
		"and the chain on the document runs to the foot");

	Object*? retuned = f.call_tool("set_secondary_motion", `{"chains":[{"root":"knee","flexibility":0.9,"collide":false}]}`);
	if (catch retuned)
	{
		test::@check(false, "a second call on the same root retunes it");
		return;
	}
	defer retuned.free();

	Object*? again = retuned.get("chains");
	bool kept = false;
	if (try again && again.get_len() == 1)
	{
		Object* row = again.get_at(0);
		kept = math::abs((row.get_float("flexibility") ?? 0.0) - 0.9) < 1.0e-6
			&& !(row.get_bool("collide") ?? true)
			&& math::abs((row.get_float("damping") ?? 0.0) - 0.7) < 1.0e-6
			&& (row.get_string("tip") ?? "") == "foot"
			&& !(row.get_bool("added") ?? true);
	}
	test::@check(kept, "a retune changes the values it names, keeps the rest, and says it added nothing");
	test::@check((retuned.get_int("chain_count") ?? 0) == 1, "and the rig still holds one chain, not two");
}

<*
 The shapes that are refused, each naming the joint or the field it is refusing.

 An agent cannot see the rig, so a refusal that says only "invalid" costs a whole
 turn to guess at. A root on the skeleton's root, a tip above its root and a
 run crossing another chain are refused rather than taken because
 `jiggle_specs_from_document` answers each with a shrug — it skips the chain —
 and a shrug reported as success is a chain that never moves.
*>
fn void set_secondary_motion_refuses_by_name() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"tail"}]}`, "chains[0]", "tail", "hips", "knee"),
		"an unknown root is named, with the dots that could have been asked for");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"hips"}]}`, "hips", "root", "knee"),
		"a chain on the skeleton's root is refused by name, with why it cannot hinge and which joint below it could");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"foot","tip":"knee"}]}`, "chains[0]", "below the root"),
		"a tip above its root is refused");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","preset":"fluffy"}]}`, "chains[0]", "fluffy", "hair"),
		"an unknown preset is refused naming the ones there are");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","flexibility":3}]}`, "chains[0]", "flexibility", "3"),
		"a flexibility past 1 is refused naming the field");

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"knee","damping":true}]}`, "chains[0]", "damping", "number"),
		"a damping that is not a number is refused naming the field");

	// A chain from the knee, then one from the foot: the second would cross the
	// first at the foot, and is refused rather than quietly losing its only bone.
	Object*? first = f.call_tool("set_secondary_motion", `{"chains":[{"root":"knee"}]}`);
	if (catch first)
	{
		test::@check(false, "the check could set a chain to cross");
		return;
	}
	first.free();

	test::@check(
		f.refuses_tool("set_secondary_motion", `{"chains":[{"root":"foot"}]}`, "chains[0]", "crosses a chain"),
		"a run through a joint another chain owns is refused");

	test::@check(f.app.doc.secondary.len() == 1 && f.app.doc.secondary_of(named_dot(f, "knee")).present(),
		"and the refusal leaves the first chain as it was");
}

<*
 What a call takes back, and what it says it took back.

 Only what really changed is reported: the setter answers false for a root that
 carried no chain, and listing it as cleared would describe work nobody did.
*>
fn void set_secondary_motion_clears_what_it_set() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? marked = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"knee"}],"colliders":[{"joint":"knee","radius":0.2}]}`);
	if (catch marked)
	{
		test::@check(false, "the check could give the leg a chain");
		return;
	}
	marked.free();

	Object*? answered = f.call_tool("set_secondary_motion",
		`{"clear":["knee","hips"],"clear_colliders":["knee","foot"]}`);
	if (catch answered)
	{
		test::@check(false, "set_secondary_motion clears");
		return;
	}
	defer answered.free();

	Object*? cleared = answered.get("cleared");
	Object*? uncapped = answered.get("cleared_colliders");
	bool took = false;
	if (try cleared && try uncapped)
	{
		// "hips" rooted no chain and "foot" never had a capsule: both resolve, both
		// are quietly left alone, and neither is reported as work.
		took = cleared.get_len() == 1 && (cleared.get_string_at(0) ?? "") == "knee"
			&& uncapped.get_len() == 1 && (uncapped.get_string_at(0) ?? "") == "knee";
	}
	test::@check(took, "clear reports the chains that really went and no others");

	test::@check((answered.get_int("chain_count") ?? 0) == 0
		&& (answered.get_int("dynamic_bones") ?? 0) == 0
		&& (answered.get_int("capsules") ?? 0) == 0,
		"and the rig re-resolves to nothing dynamic");

	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton answers after a clear");
		return;
	}
	defer skeleton.free();

	bool gone = skeleton_chain(skeleton, "knee") == null;
	if (try Object* leftover = skeleton.get("secondary")) gone = false;
	if (try Object* leftover = skeleton.get("colliders")) gone = false;
	test::@check(gone, "and get_skeleton stops reporting what was taken back, capsules included");

	// A clear and a set on the same root in one call is a chain moved rather than
	// two calls: the clears run first.
	Object*? moved = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"knee","tip":"knee"}],"clear":["knee"]}`);
	if (catch moved)
	{
		test::@check(false, "a clear and a set on one root in one call is taken");
		return;
	}
	defer moved.free();
	test::@check((moved.get_int("chain_count") ?? 0) == 1 && (moved.get_int("dynamic_bones") ?? 0) == 1,
		"and lands as the one-bone chain the set described");
}

<*
 A batch with one bad entry in it changes nothing at all.

 The rule `edit_rig` follows, and the reason it matters more here: a setup is
 several chains and capsules, so a call refused half-way through would leave a
 rig neither the caller nor the person at the screen described. Asserted
 against a rig that already carries a chain, so what is checked is that the
 refusal *restores* rather than that it leaves an empty list empty — and
 asserted on `get_skeleton`'s own bytes, since that is what an agent would
 compare.
*>
fn void set_secondary_motion_is_all_or_nothing() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? first = f.call_tool("set_secondary_motion",
		`{"chains":[{"root":"foot","flexibility":0.8}],"colliders":[{"joint":"knee","radius":0.2}]}`);
	if (catch first)
	{
		test::@check(false, "the check could set the chain it is about to try to disturb");
		return;
	}
	first.free();

	String before = crig::skeleton_json(&f.app);
	defer alloc::free(mem, before);

	// The foot's chain is cleared and set again looser, the capsule would move —
	// all of it behind one name that does not resolve.
	test::@check(
		f.refuses_tool("set_secondary_motion",
			`{"chains":[{"root":"foot","flexibility":0.1},{"root":"nowhere"}],`
			`"colliders":[{"joint":"foot","radius":0.3}],"clear":["foot"]}`,
			"nowhere"),
		"one entry that misses refuses the whole call");

	String after = crig::skeleton_json(&f.app);
	defer alloc::free(mem, after);

	test::@check(before == after, "and the rig is byte for byte where the call found it");
}

fn void play_names_the_clips_it_has() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	test::@check(f.refuses_tool("play", `{"clip":"waltz"}`, "waltz", "The library holds", "bend"),
		"play on an unknown clip names it and lists what could have been asked for");
}

fn void play_says_why_a_clip_will_not_take() @test
{
	Fixture stranger;
	stranger.open_stranger();
	defer stranger.close();

	String clip = inapplicable_clip_name(&stranger.app);
	if (clip.len == 0)
	{
		test::@check(false, "the library holds a uniquely-named clip this rig cannot play");
		return;
	}

	String arguments = string::format(mem, `{"clip":"%s"}`, clip);
	defer alloc::free(mem, arguments);
	test::@check(stranger.refuses_tool("play", arguments, clip, "names no joint this rig has", "get_skeleton")
		&& !stranger.app.animating,
		"a clip written for another rig is refused by name, with the joints it turns");
}

fn void stop_says_what_it_stopped() @test
{
	Fixture fixture;
	fixture.open_playing();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? stopped = f.call_tool("stop", "{}");
	if (catch stopped)
	{
		test::@check(false, "stop answers");
		return;
	}
	defer stopped.free();

	test::@check((stopped.get_bool("playing") ?? true) == false
		&& (stopped.get_string("stopped") ?? "") == "bend"
		&& !f.app.animating,
		"stop ends playback and names the clip it took off the screen");
}

// Null rather than a missing key or an empty string: an answer that names no
// clip has to be readable without guessing which of the three it meant.
fn bool? stopped_nothing_body(Object* stopped)
{
	return stopped.get_bool("playing")! == false && stopped.get("stopped")!.is_null();
}

fn void stopping_nothing_is_not_an_error() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;
	Object*? stopped = f.call_tool("stop", "{}");
	if (catch stopped)
	{
		test::@check(false, "a second stop answers");
		return;
	}
	defer stopped.free();

	test::@check(stopped_nothing_body(stopped) ?? false,
		"stopping when nothing plays says so rather than failing");
}

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
fn int pack_spare(crig::AppState* app, String pack) @local
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
fn bool pack_marks(crig::AppState* app, String pack, String joint) @local
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

// ---------------------------------------------------------------------------
// render and set_camera
//
// `render` moves the player and the camera to take its picture, which is the
// whole reason it is a second tool rather than an argument on `screenshot`. What
// has to be true is that it moves them back: a caller photographing a clip must
// not leave the person watching parked in the middle of it.

fn void render_photographs_every_instant_it_was_given() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	int frames = 0;
	f.app.screenshot = &wide_grab;
	f.app.screenshot_ctx = &frames;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"render","arguments":{"clip":"bend","times":[0,0.125,0.25,0.375],"cols":2}}}`);
	if (catch root)
	{
		test::@check(false, "render answers");
		return;
	}
	defer root.free();

	String mime;
	String data;
	String caption;
	if (!(screenshot_body(root, &mime, &data, &caption) ?? false))
	{
		test::@check(false, "render answers with an image block and a caption");
		return;
	}

	test::@check(frames == 4, "one frame is drawn per instant asked for, not one for the lot");
	test::@check(mime == "image/png", "and the sheet is a PNG");

	// Two columns of a 64-wide frame, two rows of a 40-tall one. Asserted as
	// arithmetic rather than "some size", because a tiler that overlapped its
	// tiles or left a row blank would still answer with a picture.
	test::@check(caption.contains("128 x 80 pixels"),
		"the sheet is exactly the tiles laid out, at the source's own resolution");
	test::@check(caption.contains("4 tile(s)") && caption.contains("2 column(s)"),
		"and says how to read it");
	test::@check(caption.contains("0.125"),
		"and names the instant in each tile, since nothing is drawn into the pixels");
}

fn void render_puts_the_player_and_the_camera_back() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	int frames = 0;
	f.app.screenshot = &wide_grab;
	f.app.screenshot_ctx = &frames;

	Object*? aimed = f.call_tool("set_camera", `{"camera":{"yaw":33,"pitch":12}}`);
	if (catch aimed)
	{
		test::@check(false, "the camera can be aimed");
		return;
	}
	aimed.free();

	Object*? playing = f.call_tool("play", `{"clip":"bend","t":0.2}`);
	if (catch playing)
	{
		test::@check(false, "the fixture plays a clip to be interrupted");
		return;
	}
	playing.free();

	crig::AnimRef was_ref = f.app.current_ref;
	float was_time = f.app.anim_time;

	// A different clip, a different camera, four times over: everything this
	// tool touches, touched.
	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"render","arguments":{"clip":"as_axis","times":[0,0.25],"view":"Left"}}}`);
	if (catch root)
	{
		test::@check(false, "render answers while something else is playing");
		return;
	}
	root.free();

	test::@check(f.app.animating && f.app.current_ref.same(was_ref),
		"the clip that was playing is playing again");
	test::@check(math::abs(f.app.anim_time - was_time) < 0.001f,
		"at the instant it was left at");
	test::@check(math::abs(f.app.camera.yaw - 33.0f) < 0.001f
		&& math::abs(f.app.camera.pitch - 12.0f) < 0.001f,
		"and the camera is back where the user left it, not down the axis render looked from");
}

fn void render_says_when_there_is_nothing_to_photograph() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	// No hook, which is a crig with no window — and the answer has to name the
	// two tools that do work without one.
	test::@check(f.refuses_tool("render", `{"clip":"bend"}`, "headless", "measure_clip"),
		"a render with no window says so, and says what still answers");

	int frames = 0;
	f.app.screenshot = &wide_grab;
	f.app.screenshot_ctx = &frames;

	test::@check(f.refuses_tool("render", `{"clip":"bend","times":[0,9]}`, "9", "0 to 0.5"),
		"an instant past the end of the clip is named against the length it overran");
	test::@check(frames == 0, "and nothing was drawn on the way to refusing");
}

fn void set_camera_aims_down_a_named_axis() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Lower case on purpose: "left" is what a caller writes and "Left" is what
	// the gizmo prints, and a refusal over that would be a turn spent on nothing.
	Object*? aimed = f.call_tool("set_camera", `{"view":"left"}`);
	if (catch aimed)
	{
		test::@check(false, "set_camera takes one of the six view names");
		return;
	}
	defer aimed.free();

	test::@check((aimed.get_string("view") ?? "") == "Left",
		"the camera reports the axis it is looking down, by the name the gizmo uses");
	test::@check(math::abs(f.app.camera.pitch) < 0.001f,
		"a side view is level");
	// Written straight onto the angles rather than eased through snap_to: a
	// quarter-second turn is right for a click and wrong for a frame about to
	// be grabbed.
	test::@check(!f.app.camera.snapping,
		"and it arrives at once rather than easing, since a render happens now");
}

fn void set_camera_names_a_view_it_does_not_have() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("set_camera", `{"view":"sideways"}`, "sideways", "Front"),
		"a view that is not one of the six names the value and lists what there is");
	test::@check(f.refuses_tool("set_camera", `{"camera":{"distance":0}}`, "distance", "cannot be at"),
		"an eye at the point it is looking at is refused rather than divided by");
}

<*
 `frame` backs the camera off until the model fits, and does it before the rest.

 The order is the check worth making: a caller asking to be backed off *and* put
 somewhere is asking for "far enough away, from over there", and applying the two
 the other way round silently discards the distance it named.

 `render` reads the same argument through the same function — `apply_framing` —
 and cannot be checked here, because a headless render is turned away before it
 ever reaches a camera.
*>
fn void set_camera_backs_off_until_the_model_fits() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Somewhere unhelpful, which is where a camera nobody has aimed sits: inside
	// the cube the fixture loads.
	f.app.camera.distance = 0.05f;

	Object*? framed = f.call_tool("set_camera", `{"frame":true}`);
	if (catch framed)
	{
		test::@check(false, "set_camera takes frame on a document with a mesh");
		return;
	}
	defer framed.free();

	float backed_off = f.app.camera.distance;
	test::@check(backed_off > 0.5f,
		"frame backs the camera off the model rather than leaving it inside (%.3f)", backed_off);

	// The distance is named after the framing, so it is the one that survives.
	Object*? both = f.call_tool("set_camera", `{"frame":true,"camera":{"distance":7.5}}`);
	if (catch both)
	{
		test::@check(false, "set_camera takes frame and a camera together");
		return;
	}
	defer both.free();

	test::@check(math::abs(f.app.camera.distance - 7.5f) < 0.001f,
		"an explicit distance overrides the framing rather than being overridden by it (%.3f)",
		f.app.camera.distance);
}

fn void set_camera_will_not_read_a_frame_that_is_not_a_flag() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Refused rather than ignored. A caller writing "yes" has said what it wants
	// plainly enough, and a camera that quietly stayed where it was is a picture
	// of the wrong thing with nothing in the answer to explain it.
	test::@check(f.refuses_tool("set_camera", `{"frame":"yes"}`, "frame", "true or false"),
		"a frame that is not a boolean is named rather than passed over");
}

// ---------------------------------------------------------------------------
// A body of the rig's own
//
// A pack with no body plays but can never be *fitted*, because `AnimPack.preset`
// normalises its joints against the body's bounding box and has none to use. That
// one empty argument was the whole of what the offline pack builder could do and
// the wire could not, and these are the two halves of closing it: generating a
// body around a rig, and writing one into a pack.

fn void a_generated_body_keeps_the_rig_it_was_built_around() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	sz dots_before = f.app.doc.dots.len();

	Object*? built = f.call_tool("build_body", `{"thickness":0.05}`);
	if (catch built)
	{
		test::@check(false, "build_body answers on a rig with three connected dots");
		return;
	}
	defer built.free();

	test::@check((built.get_int("vertices") ?? 0) > 0 && (built.get_int("triangles") ?? 0) > 0,
		"a body arrives with a surface on it");
	test::@check(f.app.doc.dots.len() == dots_before,
		"and the rig it was built around is still there — unlike load_mesh, which takes the document with it");

	// The property the whole design rests on: a body built *around* the dots
	// cannot leave one outside itself, which is what makes discarding the
	// document unnecessary here and necessary everywhere else.
	rig::Bounds box = f.app.geometry.bounds();
	bool inside = true;
	foreach (dot : f.app.doc.dots.array_view())
	{
		Vec3 at = dot.position;
		inside = inside
			&& at.x >= box.min.x - 0.001f && at.x <= box.max.x + 0.001f
			&& at.y >= box.min.y - 0.001f && at.y <= box.max.y + 0.001f
			&& at.z >= box.min.z - 0.001f && at.z <= box.max.z + 0.001f;
	}
	test::@check(inside, "every dot is inside the body that was built around it");

	// Weights are derived and the mesh under them changed, so the binder has to
	// have answered again. A stale binding would be sized to the cube.
	Object*? weights = f.call_tool("get_weights", `{}`);
	if (catch weights)
	{
		test::@check(false, "the weights rebind onto the new body");
		return;
	}
	defer weights.free();
	test::@check((weights.get_int("vertices") ?? 0) == f.app.geometry.positions.len,
		"and they were measured against the body, not the mesh it replaced");
}

fn void build_body_names_what_it_will_not_shape() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("build_body", `{"joints":[{"joint":"elbow"}]}`, "elbow", "not a dot on this rig"),
		"a joint that is not on the rig is named, rather than shaped into nothing");

	test::@check(f.refuses_tool("build_body", `{"thickness":40}`, "thickness", "fraction"),
		"a thickness that would swallow the rig says what the number means");

	test::@check(f.refuses_tool("build_body", `{"joints":[{"joint":"knee","ball":-1}]}`, "ball", "negative"),
		"a negative measure is refused rather than clamped");
}

fn void build_body_refuses_a_rig_whose_shells_are_pinned() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? pinned = f.call_tool("edit_rig", `{"ops":[{"op":"attach","shell":0,"joint":"knee"}]}`);
	if (catch pinned)
	{
		test::@check(false, "the fixture's cube has a shell to pin");
		return;
	}
	pinned.free();

	if (f.app.doc.attachments.len() == 0)
	{
		test::@check(false, "the attach op put a pin in the document to refuse over");
		return;
	}

	// Refused rather than swept: a pin is document state with no undo behind a
	// mesh swap, so losing one silently is worse than being asked to detach.
	test::@check(f.refuses_tool("build_body", `{}`, "pinned to dots", "Detach them with edit_rig"),
		"a rig with pinned shells is told to detach them first");
}

fn void an_empty_document_has_nothing_to_build_a_body_around() @test
{
	Fixture fixture;
	fixture.open_bare();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("build_body", `{}`, "no dots", "apply_plan"),
		"a body needs a rig to be built around, and the refusal says how to get one");
}

<*
 A pack saved with a body can be fitted onto a fresh model.

 The check that matters is not that a mesh went into the file — it is that the
 pack comes back off disk as something `apply_plan` can place, which is the whole
 difference between a clip file and a body plan.
*>
fn void a_pack_saved_with_a_body_is_a_body_plan() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Kit","plan":"kit","body":"dummy"}`);
	if (catch saved)
	{
		test::@check(false, "a pack may be saved with a generated body");
		return;
	}
	defer saved.free();

	// Read off the file the writer just re-read, not off the argument: a body
	// that did not survive the round trip would otherwise report as present.
	test::@check((saved.get_int("vertices") ?? 0) > 0 && (saved.get_bool("body_plan") ?? false),
		"the pack comes back off disk carrying a body");

	Object*? fitted = f.call_tool("apply_plan", `{"plan":"Kit"}`);
	if (catch fitted)
	{
		test::@check(false, "a pack with a body can be fitted as a plan");
		return;
	}
	defer fitted.free();
	test::@check((fitted.get_int("dots") ?? 0) == 3,
		"and fitting it places the rig it was written from");
}

fn void a_pack_that_declares_a_plan_and_carries_no_body_says_so() @test
{
	Fixture fixture;
	fixture.open_saver();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "the saver fixture takes a clip");
		return;
	}
	applied.free();

	Object*? saved = f.call_tool("save_pack", `{"name":"Bodyless","plan":"kit"}`);
	if (catch saved)
	{
		test::@check(false, "a pack with no body is still a legal save");
		return;
	}
	defer saved.free();

	// Said rather than refused: a clip file written for a plan the library
	// already has a body for is the case where this is exactly right.
	test::@check((saved.get_bool("body_plan") ?? true) == false
		&& (saved.get_string("note") ?? "").contains("can never fit one"),
		"a plan declared with no body is written, and answered with what it cannot do");
}

// ---------------------------------------------------------------------------
// Editing the rig, and reading a clip back as numbers.

// How many dots the fixture starts with: hips, knee, foot and the unnamed one.
const sz FIXTURE_DOTS = 4;

<*
 A repair is one call and one undo step.

 Place a dot, name it, hang it off the foot. What the rig gains is three
 primitives, and what a user who does not like it has to press is Ctrl+Z once —
 which is the whole reason `edit_rig` takes a list rather than being seven tools.
*>
fn void a_batch_of_rig_edits_undoes_in_one_step() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? edited = f.call_tool("edit_rig",
		`{"ops":[{"op":"place","position":[0.5,0,0],"name":"toe","connect_to":"foot"}]}`);
	if (catch edited)
	{
		test::@check(false, "edit_rig places a dot");
		return;
	}
	defer edited.free();

	test::@check((edited.get_int("dots") ?? 0) == (int)FIXTURE_DOTS + 1,
		"after placing one dot the rig has %d", edited.get_int("dots") ?? -1);
	test::@check((edited.get_int("bones") ?? 0) == 3, "the new dot arrived with its bone");
	test::@check(f.app.has_dot_named("toe"), "the placed dot carries the name it was given");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	defer back.free();

	test::@check((back.get_int("dots") ?? 0) == (int)FIXTURE_DOTS,
		"one undo left %d dots rather than %d", back.get_int("dots") ?? -1, FIXTURE_DOTS);
	test::@check((back.get_int("bones") ?? 0) == 2, "one undo left the bone behind");
	test::@check(!f.app.has_dot_named("toe"), "one undo left the name behind");
}

<*
 And the same for a batch of moves, which record differently.

 A placement is one primitive and its own edit; a move records where the dot was
 as well as where it went, so a group of them undoes only if every `before` was
 read before its own op ran. Two moves in one call is the smallest arrangement
 where reading them in the wrong order would still look right on the way in.
*>
fn void a_batch_of_moves_undoes_in_one_step() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Vec3 knee_was = f.app.doc.find(f.app.doc.dots[1].id).position;
	Vec3 foot_was = f.app.doc.find(f.app.doc.dots[2].id).position;

	Object*? moved = f.call_tool("edit_rig",
		`{"ops":[{"op":"move","joint":"knee","position":[0.2,0.5,0]},{"op":"move","joint":"foot","position":[0.3,0,0]}],"snap":false}`);
	if (catch moved)
	{
		test::@check(false, "edit_rig moves two dots");
		return;
	}
	moved.free();

	test::@check((f.app.doc.find(f.app.doc.dots[1].id).position - knee_was).length() > 0.1f,
		"the batch did not move the knee at all");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check((f.app.doc.find(f.app.doc.dots[1].id).position - knee_was).length() < 1.0e-5f,
		"one undo left the knee where the batch put it");
	test::@check((f.app.doc.find(f.app.doc.dots[2].id).position - foot_was).length() < 1.0e-5f,
		"one undo took back only the last move of the batch");
}

<*
 A reach travels the wire, changes the bind and undoes.

 The point of the op is that it changes what a dot holds *without moving it*, so
 the check is exactly that: the position is read before and after and has to be
 the same, while the reach shows up on the dot and in what `get_skeleton`
 reports. That pairing is the whole feature — before it, the only way to stop a
 dot pulling on mesh it should not was to drag the joint somewhere it does not
 belong.
*>
fn void a_reach_crosses_the_wire_and_undoes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	uint knee = f.app.doc.dots[1].id;
	Vec3 was = f.app.doc.find(knee).position;

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"reach","joint":"knee","reach":0.25}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig sets a reach");
		return;
	}
	set.free();

	test::@check(math::abs(f.app.doc.find(knee).reach - 0.25f) < 1.0e-6f,
		"the reach came out as %.4f", f.app.doc.find(knee).reach);
	test::@check((f.app.doc.find(knee).position - was).length() < 1.0e-6f,
		"setting a reach moved the dot, which is the thing it exists to avoid");

	Object*? seen = f.call_tool("get_skeleton", "{}");
	if (catch seen)
	{
		test::@check(false, "get_skeleton answers");
		return;
	}
	defer seen.free();

	bool reported = false;
	Object* dots = seen.get("dots")!!;
	for (sz i = 0; i < dots.get_len(); i++)
	{
		Object* entry = dots.get_at(i);
		if ((entry.get_string("name") ?? "") != "knee") continue;
		reported = math::abs((float)(entry.get_float("reach") ?? 0.0) - 0.25f) < 1.0e-6f;
	}
	test::@check(reported, "get_skeleton does not report the reach it was just given");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check(f.app.doc.find(knee).reach == 0.0f,
		"one undo left the reach at %.4f", f.app.doc.find(knee).reach);
}

<*
 A complete local-axis table crosses edit_rig, is read back by get_skeleton,
 and remains one history step. Numbers are deliberately uneven so a swapped
 axis or a dropped parked value cannot pass as a plausible default.
*>
fn void joint_limits_cross_the_wire_read_back_and_undo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"limits","joint":"knee","x":{"allow":true,"minimum":-0.125,"maximum":2.375,"locked":0.25},"y":{"allow":false,"minimum":-0.5,"maximum":0.75,"locked":0.0625},"z":{"allow":false,"minimum":-0.25,"maximum":0.25,"locked":-0.03125},"primary_child":"foot"}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig refused a valid limit table");
		return;
	}
	set.free();

	uint knee = f.app.doc.dots[1].id;
	crig::JointRotationLimits held = f.app.doc.rotation_limits_of(knee);
	test::@check(held.constrained && held.primary_child == f.app.doc.dots[2].id,
		"the active state or primary child did not land");
	test::@check(held.axes[0].allowed && math::abs(held.axes[0].maximum - 2.375f) < 1.0e-6f
		&& !held.axes[1].allowed && math::abs(held.axes[1].locked - 0.0625f) < 1.0e-6f,
		"axis values changed on the way into the document");

	Object*? skeleton = f.call_tool("get_skeleton", `{}`);
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton did not read limits back");
		return;
	}
	defer skeleton.free();
	Object* dot = skeleton_dot(skeleton, "knee");
	Object* limits = dot == null ? null : crig::member(dot, "limits");
	bool reported = limits != null && (limits.get_bool("active") ?? false)
		&& (limits.get_string("primary_child") ?? "") == "foot";
	if (reported)
	{
		Object* x = limits.get("x")!!;
		Object* y = limits.get("y")!!;
		reported = (x.get_bool("allow") ?? false)
			&& math::abs((float)(x.get_float("maximum") ?? 0.0) - 2.375f) < 1.0e-6f
			&& !(y.get_bool("allow") ?? true)
			&& math::abs((float)(y.get_float("locked") ?? 0.0) - 0.0625f) < 1.0e-6f;
	}
	test::@check(reported, "get_skeleton did not return the complete stored table");

	Object*? undone = f.call_tool("undo", `{}`);
	if (catch undone)
	{
		test::@check(false, "the limit edit would not undo");
		return;
	}
	undone.free();
	test::@check(!f.app.doc.rotation_limits_of(knee).constrained
		&& f.app.doc.rotation_limits.len() == 0,
		"one undo left the joint constrained");

	Object*? redone = f.call_tool("redo", `{}`);
	if (catch redone)
	{
		test::@check(false, "the limit edit would not redo");
		return;
	}
	redone.free();
	test::@check(f.app.doc.rotation_limits_of(knee).constrained,
		"redo did not restore the limit table");

	Object*? reset = f.call_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"knee","reset":true}]}`);
	if (catch reset)
	{
		test::@check(false, "edit_rig would not reset a limit table");
		return;
	}
	reset.free();
	test::@check(f.app.doc.rotation_limits.len() == 0,
		"reset left a sparse limit entry behind");
	Object*? restored = f.call_tool("undo", `{}`);
	if (catch restored)
	{
		test::@check(false, "the reset would not undo");
		return;
	}
	restored.free();
	test::@check(f.app.doc.rotation_limits_of(knee).constrained,
		"undoing reset did not restore the table");
}

<*
 A collision exclusion crosses edit_rig either way round, is listed by
 get_skeleton by name, is one history step, and is refused for one joint
 against itself.
*>
fn void collision_exclusions_cross_the_wire_read_back_and_undo() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;
	uint hips = f.app.doc.dots[0].id;
	uint foot = f.app.doc.dots[2].id;

	Object*? excluded = f.call_tool("edit_rig", `{"ops":[{"op":"exclude","a":"foot","b":"hips"}]}`);
	if (catch excluded)
	{
		test::@check(false, "edit_rig refused a valid exclusion");
		return;
	}
	excluded.free();
	test::@check(f.app.doc.has_exclusion(hips, foot), "the exclusion did not land");
	test::eq(f.app.doc.collision_exclusions.len(), (sz)1);

	Object*? skeleton = f.call_tool("get_skeleton", `{}`);
	if (catch skeleton)
	{
		test::@check(false, "get_skeleton did not read the exclusion back");
		return;
	}
	defer skeleton.free();
	Object*? listed = skeleton.get("exclusions");
	bool reported = false;
	if (try list = listed)
	{
		reported = list.get_len() == 1
			&& (list.get_at(0).get_string("a") ?? "") == "foot"
			&& (list.get_at(0).get_string("b") ?? "") == "hips";
	}
	test::@check(reported, "get_skeleton did not list the exclusion by name, foot then hips as it was given");

	// Reaching the asked-for state again records nothing.
	Object*? again = f.call_tool("edit_rig", `{"ops":[{"op":"exclude","a":"hips","b":"foot"}]}`);
	if (catch again)
	{
		test::@check(false, "excluding the same pair reversed was refused");
		return;
	}
	again.free();
	test::eq(f.app.doc.collision_exclusions.len(), (sz)1);

	// get_scene says how the check stands, so a tool whose pose came back
	// short can tell a blocked joint from an unreachable target.
	Object*? scene = f.call_tool("get_scene", `{}`);
	if (catch scene)
	{
		test::@check(false, "get_scene failed with an exclusion set");
		return;
	}
	defer scene.free();
	// Described whether or not the system is switched on — a tool reading a
	// pose that came back short needs to know which — and the switch itself
	// is the first thing said.
	Object*? collision = scene.get("collision");
	bool described = false;
	if (try state = collision)
	{
		described = !(state.get_bool("enabled") ?? true)
			&& (state.get_bool("prevent") ?? false)
			&& math::abs((float)(state.get_float("clearance") ?? 0.0) - crig::COLLISION_CLEARANCE) < 1.0e-6f
			&& (state.get_string("mode") ?? "") == "full";
	}
	test::@check(described, "get_scene does not describe the collision check, or reports the switch on");
	f.app.set_self_collision(true);
	Object*? switched = f.call_tool("get_scene", `{}`);
	if (try on = switched)
	{
		defer on.free();
		Object*? live = on.get("collision");
		bool switched_on = false;
		if (try state = live) switched_on = state.get_bool("enabled") ?? false;
		test::@check(switched_on, "get_scene does not report the switch on");
	}

	Object*? undone = f.call_tool("undo", `{}`);
	if (catch undone)
	{
		test::@check(false, "the exclusion would not undo");
		return;
	}
	undone.free();
	test::@check(!f.app.doc.has_exclusion(hips, foot), "one undo left the exclusion in place");

	Object*? redone = f.call_tool("redo", `{}`);
	if (catch redone)
	{
		test::@check(false, "the exclusion would not redo");
		return;
	}
	redone.free();
	test::@check(f.app.doc.has_exclusion(hips, foot), "redo did not restore the exclusion");

	Object*? included = f.call_tool("edit_rig", `{"ops":[{"op":"include","a":"hips","b":"foot"}]}`);
	if (catch included)
	{
		test::@check(false, "edit_rig refused to include the pair again");
		return;
	}
	included.free();
	test::@check(f.app.doc.collision_exclusions.len() == 0, "include left the exclusion behind");

	Object*? plain = f.call_tool("get_skeleton", `{}`);
	if (catch plain)
	{
		test::@check(false, "get_skeleton failed after the include");
		return;
	}
	defer plain.free();
	if (try leftover = plain.get("exclusions"))
	{
		test::@check(false, "an unexcluded rig still lists exclusions: %d", leftover.get_len());
	}

	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"exclude","a":"knee","b":"knee"}]}`, "against itself"),
		"a joint excluded against itself was accepted, or refused without saying why");
	test::@check(f.app.doc.collision_exclusions.len() == 0, "a self-exclusion was stored");
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"exclude","a":"knee"}]}`, `needs "a" and "b"`),
		"an exclusion missing its other joint was accepted, or refused without naming the fields");
}

fn void joint_limits_refuse_invalid_ranges_and_take_a_forks_own_child() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"knee","x":{"minimum":1,"maximum":-1}}]}`,
		"minimum", "above", "maximum"),
		"an inverted range did not explain why it was refused");
	test::@check(f.app.doc.rotation_limits.len() == 0 && !f.app.undo_stack.can_undo(),
		"a refused range changed the document or history");

	// Turn hips into a fork. Limits there need no primary child: the root's axes
	// follow the child leading the most of the rig, the knee, not the new leaf.
	uint branch = f.app.doc.add_dot({ 0.5f, 0.75f, 0 }, "branch");
	f.app.doc.connect(f.app.doc.dots[0].id, branch);
	Object*? set = f.call_tool("edit_rig",
		`{"ops":[{"op":"limits","joint":"hips","x":{"allow":true,"minimum":-1,"maximum":1}}]}`);
	if (catch set)
	{
		test::@check(false, "a branching joint's limits were refused");
		return;
	}
	defer set.free();
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits held = f.app.doc.rotation_limits_of(f.app.doc.dots[0].id);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, held);
	test::@check(held.constrained && held.primary_child == 0 && frame.usable()
		&& frame.direction_dot == f.app.doc.dots[1].id,
		"the fork's axes did not follow the knee (%s, dot %d)", frame.status, frame.direction_dot);
}

<*
 A blend sharpness crosses the wire, undoes in one step, and is refused outside
 the band the arithmetic survives.

 The op that names no joint. It is the only entry in `edit_rig` that is a
 property of the model rather than of a dot, so the check is that it lands
 without one — and that a caller working from a wrong idea of the scale is told
 the range rather than quietly clamped, which is the difference between "you
 asked for something that does not exist" and "your call did something other
 than what you asked for".
*>
fn void a_blend_sharpness_crosses_the_wire_and_undoes() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.app.doc.sharpness == 0.0f, "the fixture rig starts with a sharpness set");

	Object*? set = f.call_tool("edit_rig", `{"ops":[{"op":"sharpness","value":2}]}`);
	if (catch set)
	{
		test::@check(false, "edit_rig sets a blend sharpness");
		return;
	}
	set.free();

	test::@check(math::abs(f.app.doc.sharpness - 2.0f) < 1.0e-6f,
		"the sharpness came out as %.4f", f.app.doc.sharpness);

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check(f.app.doc.sharpness == 0.0f,
		"one undo left the sharpness at %.4f rather than back at unset", f.app.doc.sharpness);

	// Out of range, and the sentence carries the range — an agent that guessed a
	// percentage or an exponent in the tens can correct itself from the refusal.
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"sharpness","value":10}]}`, "ops[0]", "0.25 to 4"),
		"a sharpness of 10 is refused, naming the band it fell outside");
	test::@check(f.app.doc.sharpness == 0.0f, "the refused call left a sharpness behind");

	// And the op needs its number: `joint` is not read here, so a call carrying
	// only a joint has said nothing.
	test::@check(f.refuses_tool("edit_rig", `{"ops":[{"op":"sharpness","joint":"knee"}]}`, "ops[0]", "value"),
		"a sharpness op with no value is refused, and says which key it wanted");
}

<*
 A shell pinned over the wire is one undo step, and `get_shells` says so.

 The pin already existed for the mouse — `pin_shell` commits its own group — so
 what is being checked here is the uncommitted half: a batch has to be able to
 pin without closing the group under itself, or a repair made of two pins takes
 two Ctrl+Z to undo.
*>
fn void a_pinned_shell_is_one_edit_rig_batch() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (f.app.shells.count == 0)
	{
		test::@check(false, "the fixture mesh has no pieces to pin");
		return;
	}

	Object*? pinned = f.call_tool("edit_rig", `{"ops":[{"op":"attach","shell":0,"joint":"knee"}]}`);
	if (catch pinned)
	{
		test::@check(false, "edit_rig pins a shell");
		return;
	}
	pinned.free();

	uint knee = f.app.doc.dots[1].id;
	test::@check(f.app.doc.attachment_of(0) == knee, "the pin did not take");

	Object*? listed = f.call_tool("get_shells", "{}");
	if (catch listed)
	{
		test::@check(false, "get_shells answers");
		return;
	}
	defer listed.free();

	test::@check((listed.get_int("pieces") ?? 0) > 0, "get_shells reports no pieces at all");

	Object*? back = f.call_tool("undo", "{}");
	if (catch back)
	{
		test::@check(false, "undo answers");
		return;
	}
	back.free();

	test::@check(f.app.doc.attachment_of(0) == 0, "one undo left the shell pinned");
}

<*
 A batch that fails part-way leaves the rig where it found it.

 The first op is good and the second names a joint that does not exist. Without
 the rollback the call refuses *and* the rig keeps the first op, which is the
 worst of both — a caller told nothing happened, looking at a rig where something
 did.
*>
fn void a_refused_batch_changes_nothing() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("edit_rig",
		`{"ops":[{"op":"place","position":[0.5,0,0],"name":"toe"},{"op":"name","joint":"elbow","name":"shin"}]}`,
		"ops[1]", "elbow"),
		"a batch naming a joint the rig lacks is refused, and says which op and which joint");

	test::@check(f.app.doc.dots.len() == FIXTURE_DOTS,
		"the refused batch left %d dots behind", f.app.doc.dots.len());
	test::@check(!f.app.has_dot_named("toe"), "the refused batch left its first op applied");
}

<*
 The loop that was impossible before: name a dot, then animate it.

 A clip addresses joints by name and a hand-placed dot carries none, so the
 fixture's fourth dot could be seen, surveyed and pointed at — and never moved.
*>
fn void a_clip_can_address_a_dot_the_wire_just_named() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	uint free_dot = f.app.doc.dots[(usz)FIXTURE_DOTS - 1].id;
	String call = string::format(mem, `{"ops":[{"op":"name","joint":"bone_%d","name":"tail"}]}`, free_dot);
	defer alloc::free(mem, call.ptr);

	Object*? named = f.call_tool("edit_rig", call);
	if (catch named)
	{
		test::@check(false, "edit_rig names an unnamed dot through its bone_<id> address");
		return;
	}
	named.free();

	String arguments = bend_clip("Wag", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	String tail = arguments.treplace("knee", "tail");

	String message = string::format(
		mem,
		`{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"apply_clip","arguments":%s}}`,
		tail);
	defer alloc::free(mem, message);

	Object*? root = f.request(message);
	if (catch root)
	{
		test::@check(false, "apply_clip answers for the newly named joint");
		return;
	}
	defer root.free();
	test::@check(root.get("result") ?? null, "a clip can now turn a dot that had no name to turn by");
}

<*
 A ground spec is refused in the same voice a keyframe is: naming the value.

 Three ways to get it wrong, and each has to say which one it was. A phase given
 in seconds is the one that will actually happen — every other time on this
 surface is seconds, and the windows are the exception.
*>
fn void a_bad_ground_spec_names_the_value() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"Step","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0.2,0,0]}]}],"duration":1,"ground":{"feet":[{"joint":"heel","down":0,"up":0.4}]}}`,
		"heel", "not a dot on this rig"),
		"a foot naming no dot is refused and says so");

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"Step","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0.2,0,0]}]}],"duration":1,"ground":{"feet":[{"joint":"foot","down":0,"up":1.4}]}}`,
		"cycle phase", "not seconds"),
		"a window given in seconds is refused and says what a window is in");

	test::@check(f.refuses_tool("apply_clip",
		`{"name":"Step","keyframes":[{"time":0,"joints":[{"name":"knee","rotation":[0.2,0,0]}]}],"duration":1,"blend":"cubic"}`,
		"blend", "smooth"),
		"a blend that is neither mode is refused and names the two that are");
}

<*
 measure_clip agrees with what get_pose shows.

 The metrics exist so an agent does not have to make fifty round trips to work
 out whether a foot is sliding; if they disagreed with the fifty round trips they
 would be worse than nothing.
*>
fn void measure_answers_what_get_pose_would() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip takes the clip to measure");
		return;
	}
	applied.free();

	Object*? measured = f.call_tool("measure_clip", `{"clip":"Bend","samples":16}`);
	if (catch measured)
	{
		test::@check(false, "measure_clip answers");
		return;
	}
	defer measured.free();

	// The foot hangs off the knee the clip turns, so its travel is the one number
	// the fixture can be asked for and checked against a pose.
	double reported = 0;
	Object* rows = measured.get("joints")!!;
	for (sz i = 0; i < rows.get_len(); i++)
	{
		Object* row = rows.get_at(i);
		if ((row.get_string("name") ?? "") == "foot") reported = row.get_float("travel") ?? 0.0;
	}
	test::@check(reported > 0.0, "the clip turns the knee and the foot below it reports no travel at all");

	// The same quantity out of the other read path: the widest the foot ever gets
	// from where it was, relative to the root, over the same grid of instants the
	// metric walks. A cycle stops short of its own end — phase 1 is phase 0 again
	// — so the grid is [0, duration), which is what makes this a like-for-like
	// comparison rather than a restatement of the endpoint.
	float height = 1.0f;
	Object*? skeleton = f.call_tool("get_skeleton", "{}");
	if (try skeleton)
	{
		height = (float)(skeleton.get_float("height") ?? 1.0);
		skeleton.free();
	}

	const usz SAMPLES = 16;
	Vec3[SAMPLES] seen;
	for (usz i = 0; i < SAMPLES; i++)
	{
		float t = BEND_DURATION * (float)i / (float)SAMPLES;
		seen[i] = swing_joint(f, "Bend", t, "foot") - swing_joint(f, "Bend", t, "hips");
	}

	float widest = 0.0f;
	for (usz a = 0; a < SAMPLES; a++)
	{
		for (usz b = a + 1; b < SAMPLES; b++)
		{
			float apart = (seen[b] - seen[a]).length();
			if (apart > widest) widest = apart;
		}
	}
	widest /= height;

	test::@check(math::abs((float)reported - widest) < 1.0e-3f,
		"measure_clip reports %.5f of travel and the same walk over get_pose gives %.5f", reported, widest);
}

// How long `bend_clip` runs. Named because two checks now depend on it and a
// sampling grid that disagreed with the clip would compare two different things.
const float BEND_DURATION = 0.5f;

// One joint's world position out of get_pose, for a check that wants to compare
// the two read paths rather than trust either.
fn Vec3 swing_joint(Fixture* f, String clip, float t, String joint)
{
	String call = string::format(mem, `{"clip":"%s","t":%f}`, clip, t);
	defer alloc::free(mem, call.ptr);

	Object*? pose = f.call_tool("get_pose", call);
	if (catch pose) return { 0, 0, 0 };
	defer pose.free();

	Object* joints = pose.get("joints")!!;
	for (sz i = 0; i < joints.get_len(); i++)
	{
		Object* row = joints.get_at(i);
		if ((row.get_string("name") ?? "") != joint) continue;
		Object* at = row.get("position")!!;
		return {
			(float)(at.get_float_at(0) ?? 0.0),
			(float)(at.get_float_at(1) ?? 0.0),
			(float)(at.get_float_at(2) ?? 0.0),
		};
	}
	return { 0, 0, 0 };
}

<*
 Deleting the clip that is playing stops the player first.

 `current_anim` is a copy pointing into the keyframes about to be freed, so a
 delete that left the player running would run it over dead memory — the same
 hazard `put_authored_clip` guards, reached down the other path.
*>
fn void delete_clip_stops_a_clip_it_is_playing() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	String arguments = bend_clip("Bend", QUARTER_TURN_AXIS);
	defer alloc::free(mem, arguments);
	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip takes the clip to delete");
		return;
	}
	applied.free();

	Object*? started = f.call_tool("play", `{"clip":"Bend"}`);
	if (catch started)
	{
		test::@check(false, "play starts the clip");
		return;
	}
	started.free();
	test::@check(f.app.animating, "the clip is playing before it is deleted");

	Object*? gone = f.call_tool("delete_clip", `{"clip":"Bend"}`);
	if (catch gone)
	{
		test::@check(false, "delete_clip answers");
		return;
	}
	defer gone.free();

	test::@check(!f.app.animating, "deleting the running clip left the player running over it");
	test::@check((gone.get_int("remaining") ?? -1) == 0, "the authored pack still holds the clip");
	test::@check(f.refuses_tool("delete_clip", `{"clip":"Bend"}`, "no clip called"),
		"deleting it twice is refused and says the pack does not hold it");
}

// ---------------------------------------------------------------------------
// Clip history
//
// A clip write is one undo step however many keyframes it carried, because a
// script writes hundreds of them and taking the run back has to be one Ctrl+Z.
// The template itself moves between the pack and the undo stack rather than
// being copied, so what these are really asserting is that exactly one of the
// two owns it at any moment — the leak-tracked run is the other half of that,
// and it is the half that catches a slot dropped out of order.

// One clip under a given name, told apart from the next by its duration alone.
fn String timed_clip(String name, String duration)
{
	return string::format(
		mem,
		`{"name":"%s","duration":%s,"keyframes":[{"time":0,"joints":[]},{"time":0.25,"joints":[{"name":"knee","rotation":[0.25,0,0]}]}]}`,
		name,
		duration);
}

// Writes one, failing the calling test rather than the helper if it will not go.
fn bool write_timed(Fixture* f, String name, String duration)
{
	String arguments = timed_clip(name, duration);
	defer alloc::free(mem, arguments);

	Object*? applied = f.call_tool("apply_clip", arguments);
	if (catch applied)
	{
		test::@check(false, "apply_clip takes %s at duration %s", name, duration);
		return false;
	}
	applied.free();
	return true;
}

// What the pack holds under this name, or null when it holds nothing.
fn crig::AnimTemplate* held_clip(Fixture* f, String name)
{
	crig::AnimRef? found = crig::resolve_clip(&f.app, name);
	if (catch found) return null;
	return f.app.clip(found);
}

<*
 Rewriting a clip and taking the rewrite back.

 The template is not copied on the way in — the displaced one moves to the undo
 stack — so this is asserting that undo hands back the clip *itself*, keyframes
 and all, rather than something reconstructed from what the edit remembered.
*>
fn void a_rewritten_clip_undoes_to_the_one_before_it() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Bend", "1")) return;
	if (!write_timed(f, "Bend", "3")) return;

	crig::AnimTemplate* live = held_clip(f, "Bend");
	test::@check(live != null && live.duration == 3.0f, "the rewrite is what the pack holds");

	test::@check(f.app.undo(), "the rewrite is on the ledger to take back");
	live = held_clip(f, "Bend");
	test::@check(live != null && live.duration == 1.0f && live.keyframes.len == 2,
		"undo puts back the clip that was there, keyframes and all");

	test::@check(f.app.redo(), "and the rewrite is still ahead of the cursor");
	live = held_clip(f, "Bend");
	test::@check(live != null && live.duration == 3.0f, "redo brings the rewrite back");
}

<*
 A write that replaced nothing, undone, leaves the pack without the clip.

 The parked side of a first write is an empty template, which is the whole of
 how "there was no clip of this name" is said — so this is the check that an
 empty one going back in removes rather than writes a blank.
*>
fn void undoing_a_first_write_takes_the_clip_out() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Solo", "1")) return;
	test::@check(held_clip(f, "Solo") != null, "the clip is there before the undo");

	test::@check(f.app.undo(), "the write is on the ledger");
	test::@check(held_clip(f, "Solo") == null, "undoing a first write leaves the clip gone");
	test::@check(f.refuses_tool("delete_clip", `{"clip":"Solo"}`, "no clip called"),
		"and the pack agrees it does not hold it");

	test::@check(f.app.redo() && held_clip(f, "Solo") != null, "redo writes it again");
}

<*
 Deleting a clip and putting it back.

 `delete_clip` is a swap with an empty template going in, so undo is the same
 exchange in the other direction — the clip that comes back is the one that left,
 not a rebuild of it.
*>
fn void a_deleted_clip_comes_back_whole() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Gone", "2")) return;

	Object*? removed = f.call_tool("delete_clip", `{"clip":"Gone"}`);
	if (catch removed)
	{
		test::@check(false, "delete_clip takes the clip out");
		return;
	}
	removed.free();
	test::@check(held_clip(f, "Gone") == null, "the clip is out before the undo");

	test::@check(f.app.undo(), "the delete is on the ledger");
	crig::AnimTemplate* back = held_clip(f, "Gone");
	test::@check(back != null && back.duration == 2.0f && back.keyframes.len == 2,
		"undoing a delete puts the clip back whole");

	test::@check(f.app.redo() && held_clip(f, "Gone") == null, "redo takes it out again");
}

<*
 Forking the timeline frees the clip the abandoned branch was holding.

 The one path where a parked template is released rather than swapped back, and
 it fires on an edit that has nothing to do with clips — which is exactly why the
 payload store has to be a stack: the discarded edits own the newest slots, so
 the store is truncated from the end. A slot dropped out of order would free
 somebody else's template, so the leak-tracked run is the real assertion here.
*>
fn void forking_the_timeline_frees_the_abandoned_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Bend", "1")) return;
	if (!write_timed(f, "Bend", "3")) return;
	test::@check(f.app.undo(), "step back over the rewrite, leaving it redoable");
	test::@check(f.app.undo_stack.can_redo(), "the rewrite is sitting in the redo tail");

	// A write under a different name, which discards that tail and with it the
	// template the abandoned branch was parking.
	if (!write_timed(f, "Other", "2")) return;

	test::@check(!f.app.undo_stack.can_redo(), "the new write forked the timeline");

	crig::AnimTemplate* bend = held_clip(f, "Bend");
	crig::AnimTemplate* other = held_clip(f, "Other");
	test::@check(bend != null && bend.duration == 1.0f, "the branch that was kept is what the pack holds");
	test::@check(other != null && other.duration == 2.0f, "and the write that forked it landed");

	// Back over both, which walks the store down to empty the way `free` does.
	test::@check(f.app.undo() && f.app.undo(), "both surviving writes still undo");
	test::@check(held_clip(f, "Bend") == null && held_clip(f, "Other") == null,
		"leaving the pack as it started");
}

<*
 Undoing a rewrite while the clip is playing.

 The forward hazard is documented on `swap_authored_clip`; this is the mirror,
 and it is the worse one. After the swap the template that was live is the
 *parked* one, and a parked template is freed when the redo tail is discarded —
 on some later, unrelated edit. A player left pointing into it is a use-after-free
 that fires nowhere near the undo that caused it, so the check is that the
 running copy is the one that came back.
*>
fn void undoing_a_rewrite_retakes_the_playing_clip() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	if (!write_timed(f, "Bend", "1")) return;

	Object*? started = f.call_tool("play", `{"clip":"Bend"}`);
	if (catch started)
	{
		test::@check(false, "play starts the clip");
		return;
	}
	started.free();

	if (!write_timed(f, "Bend", "3")) return;
	test::@check(f.app.animating && f.app.current_anim.duration == 3.0f,
		"the rewrite left the player running on the new keyframes");

	test::@check(f.app.undo(), "the rewrite undoes while it is playing");
	test::@check(f.app.animating && f.app.current_anim.duration == 1.0f,
		"undo retook the player onto the clip that came back, not the one now parked");

	f.app.stop_animation();
}

// The dot a name resolves to, or 0. `resolve_dot` writes its refusal into a
// DString and has nowhere to put one here, so it gets a scratch one.
fn uint named_dot(Fixture* f, String name) @local
{
	DString said = dstring::new(mem);
	defer said.free();
	return crig::resolve_dot(&f.app, name, &said) ?? 0;
}

// ---------------------------------------------------------------------------
// paint_weights — the one weight tool that writes.
//
// The selection is get_weights' own vocabulary read backwards, so what these
// assert is the loop an agent actually runs: read the shared rows, name the same
// vertices back, and see the survey move.

<*
 The survey names a smear and the paint tool takes the same words back.

 The whole design in one check. `get_weights` reports that one dot reaches into
 another's territory; `paint_weights` is handed that row's own fields and the
 overlap goes away — with no vertex indices crossing the wire in either
 direction.
*>
fn void a_shared_row_can_be_painted_away() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? before = f.call_tool("get_weights", `{"dot":"knee"}`);
	if (catch before)
	{
		test::@check(false, "get_weights answers for the knee");
		return;
	}
	defer before.free();

	Object*? rows = before.get("shared");
	if (catch rows)
	{
		test::@check(false, "get_weights reports a shared list for the knee");
		return;
	}
	Object* shared = rows;
	if (shared.get_len() == 0)
	{
		test::@check(false, "the fixture rig has a knee that shares vertices with something");
		return;
	}
	String owner = shared.get_at(0).get_string("name") ?? "";
	usz taken = (usz)(shared.get_at(0).get_int("vertices") ?? 0);
	test::@check(taken > 0, "the worst row names vertices the knee takes from %s", owner);

	// The row's own fields, handed straight back. 0.05 is the floor get_weights
	// reports at, so this selects exactly what it just listed.
	String arguments = string::format(mem,
		`{"dot":"knee","share":0,"owned_by":"%s","at_least":0.05}`, owner);
	defer alloc::free(mem, arguments);

	Object*? painted = f.call_tool("paint_weights", arguments);
	if (catch painted)
	{
		test::@check(false, "paint_weights takes the row back");
		return;
	}
	defer painted.free();

	test::@check((painted.get_int("painted") ?? 0) > 0, "it corrected something");

	Object*? after = f.call_tool("get_weights", `{"dot":"knee"}`);
	if (catch after)
	{
		test::@check(false, "get_weights answers afterwards");
		return;
	}
	defer after.free();

	usz still = 0;
	if (try Object* left = after.get("shared"))
	{
		for (sz i = 0; i < left.get_len(); i++)
		{
			if ((left.get_at(i).get_string("name") ?? "") == owner)
			{
				still = (usz)(left.get_at(i).get_int("vertices") ?? 0);
			}
		}
	}
	test::@check(still < taken, "the smear the survey named is smaller than it was (%d, was %d)", still, taken);
}

<*
 A correction is one undo step, and reset takes the layer off.
*>
fn void painting_is_undoable_and_resettable() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? painted = f.call_tool("paint_weights", `{"dot":"knee","share":0.1,"vertices":[0,1,2,3]}`);
	if (catch painted)
	{
		test::@check(false, "paint_weights takes an explicit vertex list");
		return;
	}
	defer painted.free();
	test::@check((painted.get_int("painted") ?? 0) > 0, "the explicit list was painted");
	test::@check(f.app.doc.paint.len() > 0, "and the document holds it");

	Object*? stepped = f.call_tool("undo", "{}");
	if (catch stepped)
	{
		test::@check(false, "undo answers");
		return;
	}
	stepped.free();
	test::@check(f.app.doc.paint.len() == 0, "one undo took the whole call back");

	f.call_tool("redo", "{}")!!.free();
	test::@check(f.app.doc.paint.len() > 0, "and redo put it back");

	Object*? cleared = f.call_tool("paint_weights", `{"dot":"knee","reset":true}`);
	if (catch cleared)
	{
		test::@check(false, "reset answers");
		return;
	}
	defer cleared.free();
	test::@check((cleared.get_bool("reset") ?? false) && f.app.doc.paint.len() == 0,
		"reset took every correction off");
}

<*
 A refusal says which value was wrong and what would have been right.

 The J6 rule, and it matters more here than for a read tool: an agent that
 cannot tell "the share was out of range" from "that dot is not on this rig"
 retries the same call.
*>
fn void paint_weights_refuses_with_a_sentence() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("paint_weights", `{"dot":"nosuchdot","share":0}`, "nosuchdot"),
		"an unknown dot is named back");
	test::@check(f.refuses_tool("paint_weights", `{"dot":"knee","share":4}`, "between 0 and 1"),
		"a share out of range says what the range is");
	test::@check(f.refuses_tool("paint_weights", `{"dot":"knee"}`, "reset"),
		"a missing share points at the other thing the tool can do");
}

<*
 A selection matching nothing is an answer, not an error.

 It is the rig saying the overlap being aimed at is not there — and a caller told
 that in a sentence goes and looks, where one handed a fault retries.
*>
fn void a_selection_matching_nothing_is_reported() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	// Nothing holds a share above 1, so this matches no vertex anywhere.
	Object*? nothing = f.call_tool("paint_weights", `{"dot":"knee","share":0,"at_least":1.5}`);
	if (catch nothing)
	{
		test::@check(false, "an empty selection is answered rather than refused");
		return;
	}
	defer nothing.free();

	test::@check((nothing.get_int("selected") ?? -1) == 0, "it reports selecting nothing");
	test::@check((nothing.get_string("note") ?? "").contains("get_weights"),
		"and points at the tool that lists what does share vertices");
}

// ---------------------------------------------------------------------------
// pin_weights — the other weight tool that writes, and the one that states a
// value rather than correcting one.
//
// It borrows `paint_weights`' selection outright, so what these cover is what
// the two do *not* share: the default share, the exclusivity, and a reset that
// takes one layer off and leaves the other.

<*
 A pin can be made by predicate and by explicit vertices, and one call is one
 undo step.
*>
fn void pinning_is_selectable_and_undoable() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? pinned = f.call_tool("pin_weights", `{"dot":"knee","vertices":[0,1,2,3]}`);
	if (catch pinned)
	{
		test::@check(false, "pin_weights takes an explicit vertex list");
		return;
	}
	defer pinned.free();

	// No share given, so the rigid one — what "these belong to that dot" means.
	test::@check((pinned.get_float("share") ?? 0.0) == 1.0, "an unstated share is not the rigid one");
	test::@check((pinned.get_int("pinned") ?? 0) == 4, "the explicit list was pinned");
	test::eq(f.app.doc.pins.len(), (sz)4);

	Object*? stepped = f.call_tool("undo", "{}");
	if (catch stepped)
	{
		test::@check(false, "undo answers");
		return;
	}
	stepped.free();
	test::eq(f.app.doc.pins.len(), (sz)0);

	f.call_tool("redo", "{}")!!.free();
	test::eq(f.app.doc.pins.len(), (sz)4);

	// By predicate, in `get_weights`' own vocabulary — the same words the paint
	// tool takes, which is the point of sharing the selection.
	Object*? swept = f.call_tool("pin_weights", `{"dot":"knee","share":0.5,"at_least":0.05}`);
	if (catch swept)
	{
		test::@check(false, "pin_weights takes a predicate selection");
		return;
	}
	defer swept.free();
	test::@check((swept.get_int("selected") ?? 0) > 0, "the predicate selected nothing to pin");

	// Exclusive by default, so a second dot over the same vertices takes them.
	f.call_tool("pin_weights", `{"dot":"hips","vertices":[0]}`)!!.free();
	uint knee = f.app.doc.dots[1].id;
	test::@check(f.app.doc.pin_of(0, knee) == 0.0f, "the rival dot kept its pin on a re-pinned vertex");

	Object*? cleared = f.call_tool("pin_weights", `{"dot":"knee","reset":true}`);
	if (catch cleared)
	{
		test::@check(false, "reset answers");
		return;
	}
	defer cleared.free();
	test::@check((cleared.get_bool("reset") ?? false) && f.app.doc.pins.len() == 0,
		"reset took every pin off");
}

<*
 The two layers are independent: resetting one leaves the other standing.

 They are written by different verbs and mean different things — a correction
 rides the binder, a pin overrules it — so a caller clearing the regions it drew
 must not silently lose the corrections it painted.
*>
fn void resetting_the_pins_leaves_the_corrections() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	f.call_tool("paint_weights", `{"dot":"knee","share":0.1,"vertices":[0,1]}`)!!.free();
	f.call_tool("pin_weights", `{"dot":"knee","vertices":[2,3]}`)!!.free();

	test::@check(f.app.doc.paint.len() > 0 && f.app.doc.pins.len() > 0, "the fixture has both layers");

	// Both directions, because either one sweeping the other is the same defect
	// and neither is visible from the reply.
	f.call_tool("paint_weights", `{"dot":"knee","reset":true}`)!!.free();
	test::eq(f.app.doc.paint.len(), (sz)0);
	test::@check(f.app.doc.pins.len() > 0, "resetting the corrections took the pins with it");

	f.call_tool("paint_weights", `{"dot":"knee","share":0.1,"vertices":[0,1]}`)!!.free();
	test::@check(f.app.doc.paint.len() > 0, "the corrections did not come back");

	f.call_tool("pin_weights", `{"dot":"knee","reset":true}`)!!.free();
	test::eq(f.app.doc.pins.len(), (sz)0);
	test::@check(f.app.doc.paint.len() > 0, "resetting the pins took the corrections with it");
}

<*
 A refusal says which value was wrong, on `paint_weights`' terms.
*>
fn void pin_weights_refuses_with_a_sentence() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("pin_weights", `{"dot":"nosuchdot"}`, "nosuchdot"),
		"an unknown dot is named back");
	test::@check(f.refuses_tool("pin_weights", `{"dot":"knee","share":4}`, "between 0 and 1"),
		"a share out of range says what the range is");
}

<*
 build_body refuses a rig whose vertices are pinned.

 The attachment refusal one level finer, and for the same reason: a generated
 body's vertices are built from its bones, so an index that named a point on the
 loaded mesh names a different point on the new one — and losing hand-drawn
 regions with no undo behind it is worse than being asked.
*>
fn void build_body_refuses_a_rig_whose_vertices_are_pinned() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	f.call_tool("pin_weights", `{"dot":"knee","vertices":[0,1]}`)!!.free();

	test::@check(f.refuses_tool("build_body", `{}`, "pinned to dots"),
		"a pinned rig was built over without a word");
	test::@check(f.refuses_tool("build_body", `{}`, "pin_weights"),
		"and the refusal does not name the way out");
}

// ---------------------------------------------------------------------------
// The binder's own rigid choices, over the wire

<*
 The cube with a second solid beside it, and a dot inside that one.

 What the fixture has to produce is a piece the *binder* freezes rather than one
 the user pinned: `rig::rigid_shells` calls a reached piece one bone's outright
 when nearly all of it is nearest that bone, and a separate cube with a dot in
 the middle of it is exactly that. The main cube keeps its blend, because its
 corners are split between the three joints of the chain.
*>
Vec3[16] two_solid_positions @local = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1, 1 },  { 1, -1, 1 },  { 1, 1, 1 },  { -1, 1, 1 },

	{ 1.5, -0.5, -0.5 }, { 2.5, -0.5, -0.5 }, { 2.5, 0.5, -0.5 }, { 1.5, 0.5, -0.5 },
	{ 1.5, -0.5, 0.5 },  { 2.5, -0.5, 0.5 },  { 2.5, 0.5, 0.5 },  { 1.5, 0.5, 0.5 },
};

uint[72] two_solid_indices @local = {
	4, 5, 6, 4, 6, 7,      0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5,      0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2,      0, 1, 5, 0, 5, 4,

	12, 13, 14, 12, 14, 15,   8, 11, 10, 8, 10, 9,
	9, 10, 14, 9, 14, 13,     8, 12, 15, 8, 15, 11,
	11, 15, 14, 11, 14, 10,   8, 9, 13, 8, 13, 12,
};

fn void Fixture.open_two_solids(&self)
{
	self.app = crig::new_app(
		{ .positions = two_solid_positions[..], .indices = two_solid_indices[..] });

	uint hips = self.app.doc.add_dot({ 0, 1, 0 }, "hips");
	uint knee = self.app.doc.add_dot({ 0, 0.5, 0 }, "knee");
	uint foot = self.app.doc.add_dot({ 0, 0, 0 }, "foot");
	self.app.doc.connect(hips, knee);
	self.app.doc.connect(knee, foot);
	self.app.doc.add_dot({ 2.0, 0, 0 }, "prop");

	self.tools = crig::new_tool_table(&self.app);
	self.server = crig::serve_table(&self.tools, &self.app);
}

<*
 `get_shells` says which bone the binder froze a piece onto by itself.

 The field an agent needs to not pin a piece twice: a part that is already rigid
 looks exactly like a part that is not, and the only difference is a decision
 made inside a bind and until now thrown away. Never reported stale, because the
 answer is a joint index and joint indices are renumbered by every edit — a
 stale one names a real bone confidently and wrongly. So a rig that has moved
 since the last bind costs the tool a fresh one: the pane that used to keep the
 riders fresh behind a debounce is gone, and a tool call is the one reader left.
*>
fn void get_shells_names_the_binders_own_choice() @test
{
	Fixture fixture;
	fixture.open_two_solids();
	defer fixture.close();
	Fixture* f = &fixture;

	if (f.app.shells.count != 2)
	{
		test::@check(false, "SKIPPED — the fixture is %d pieces, not two", f.app.shells.count);
		return;
	}

	// The bind is what fills the riders, and nothing has asked for one yet.
	crig::RigView? opened = f.app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the fixture rig produced no skeleton");
		return;
	}
	crig::RigView view = opened;
	f.app.base_bind_for(&view);
	view.free(mem);

	Object*? listed = f.call_tool("get_shells", "{}");
	if (catch listed)
	{
		test::@check(false, "get_shells answers");
		return;
	}
	defer listed.free();

	Object*? shells = listed.get("shells");
	if (catch shells)
	{
		test::@check(false, "get_shells wrote no shells array");
		return;
	}

	usz decided = 0;
	for (sz i = 0; i < shells.get_len(); i++)
	{
		Object* row = shells.get_at(i);
		String named = row.get_string("auto") ?? "";
		if (named.len == 0) continue;
		decided++;
		test::@check(named == "prop",
			"a piece was reported as riding \"%s\" rather than the dot sitting inside it", named);
	}
	test::@check(decided == 1, "%d pieces carry an auto, where the fixture has one", decided);

	// And the moment the rig moves the old indices name whatever the next
	// breadth-first walk puts in their place — so the tool binds again rather
	// than reporting them, and the answer is the same dot, found afresh.
	f.app.mark_rig_stale();
	test::@check(f.app.riders_stale, "mark_rig_stale did not raise riders_stale");

	Object*? again = f.call_tool("get_shells", "{}");
	if (catch again)
	{
		test::@check(false, "get_shells answers after a rig edit");
		return;
	}
	defer again.free();
	test::@check(!f.app.riders_stale, "get_shells answered a moved rig without refreshing the riders");

	Object*? fresh = again.get("shells");
	if (catch fresh) return;

	usz refound = 0;
	for (sz i = 0; i < fresh.get_len(); i++)
	{
		String named = fresh.get_at(i).get_string("auto") ?? "";
		if (named.len == 0) continue;
		refound++;
		test::@check(named == "prop",
			"after the rig moved a piece was reported as riding \"%s\"", named);
	}
	test::@check(refound == 1, "%d pieces carry an auto after the rig moved, where the fixture has one", refound);
}

<*
 The pose library over MCP: two poses saved off a clip, then a clip written
 between them that starts and ends on those poses. Deleting one is undoable in
 the panel's own history.
*>
fn void poses_are_saved_and_tweened_over_mcp() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	Object*? first = f.call_tool("save_pose", `{"name":"Start","clip":"Authored/as_axis","t":0}`);
	Object*? second = f.call_tool("save_pose", `{"name":"End","clip":"Authored/as_axis","t":0.5}`);
	if (catch first) { test::@check(false, "save_pose answers"); return; }
	if (catch second) { test::@check(false, "second save_pose answers"); return; }
	first.free();
	defer second.free();
	test::@check(f.app.doc.poses.len == 2, "both poses are in the project's library");
	test::@check((second.get("poses").get_len() ?? 0) == 2, "the answer lists them");

	Object*? scene = f.call_tool("get_scene", "{}");
	if (catch scene) { test::@check(false, "get_scene answers"); return; }
	defer scene.free();
	test::@check((scene.get("saved_poses").get_len() ?? 0) == 2, "get_scene names the saved poses");
	test::@check((scene.get("saved_poses").get_string_at(1) ?? "") == "End", "in the library's order");

	Object*? made = f.call_tool("tween_poses", `{"from":"Start","to":"End","name":"Between","duration":0.8}`);
	if (catch made) { test::@check(false, "tween_poses answers"); return; }
	defer made.free();
	Object*? clip = f.call_tool("get_clip", `{"clip":"Authored/Between"}`);
	if (catch clip) { test::@check(false, "the tweened clip can be read back"); return; }
	defer clip.free();
	test::@check((clip.get("keyframes").get_len() ?? 0) == 2, "two poses make two keys");
	test::@check(math::abs(clip.get("keyframes").get_at(1).get_float("time") ?? 0.0 - 0.8) < 1e-4, "the last pose lands at the duration");

	Object*? gone = f.call_tool("delete_pose", `{"pose":"Start"}`);
	if (catch gone) { test::@check(false, "delete_pose answers"); return; }
	gone.free();
	test::@check(f.app.doc.poses.len == 1, "the pose is gone");
	test::@check(f.app.saved_pose_named("Start") < 0, "by name");
}

<*
 A stroke drawn in Sketch becomes a mark the agent can read: normalised points,
 its ink, the camera; and it can be cleared.
*>
fn void a_sketch_is_read_back_as_data() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	f.app.begin_sketch();
	f.app.sketch_ink = crig::SketchInk.RED;
	// Inside a scope that closes, as an MCP or UI callback runs.
	@pool()
	{
		f.app.sketch_moved({ 100, 50 });
	};
	@pool()
	{
		f.app.sketch_moved({ 300, 250 });
	};
	Matrix4f vp = f.app.model_view_projection(&f.app.camera, 2.0f);
	uint id = f.app.sketch_commit(vp, { 400, 300 }, &f.app.camera);
	test::@check(id == 1, "the stroke is mark 1");

	Object*? got = f.call_tool("get_annotations", `{}`);
	if (catch got) { test::@check(false, "get_annotations answers"); return; }
	defer got.free();
	test::@check((got.get("annotations").get_len() ?? 0) == 1, "one mark");
	Object* mark = got.get("annotations").get_at(0)!!;
	test::@check((mark.get_string("meaning") ?? "") == "wrong", "red means wrong");
	test::@check((mark.get("points").get_len() ?? 0) == 2, "both points kept");
	Object* second = mark.get("points").get_at(1)!!;
	test::@check(math::abs(second.get_at(0).f - 0.75) < 1e-3, "in fractions of the viewport");

	Object*? cleared = f.call_tool("get_annotations", `{"clear":true}`);
	if (catch cleared) { test::@check(false, "clear answers"); return; }
	cleared.free();
	test::@check(f.app.annotations.len() == 0, "and they can be cleared");
}

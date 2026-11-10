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

// render_poses reads all of its arguments before it looks for a renderer, so a
// wrong one is named even with no window; and with no window it says so.
fn void render_poses_names_a_bad_argument_and_a_missing_window() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("render_poses", `{"count":5}`, "out"),
		"a set with nowhere to go is refused, naming out");
	test::@check(f.refuses_tool("render_poses", `{"out":"set","size":100}`, "100", "multiple of 16"),
		"a size the backbone's patches do not divide is refused");
	test::@check(f.refuses_tool("render_poses", `{"out":"set","cameras":[{"name":"front"}]}`, "front", "yaw"),
		"a camera with no yaw is refused by name");
	test::@check(f.refuses_tool("render_poses", `{"out":"set","fill":[0.9,0.4]}`, "fill"),
		"a framing whose least is past its most is refused");
	test::@check(f.refuses_tool("render_poses", `{"out":"set"}`, "headless"),
		"with no renderer it says so");
}

// render_studio, like render_poses, reads its arguments before it looks for a
// renderer.
fn void render_studio_names_a_bad_argument_and_a_missing_window() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("render_studio", `{}`, "out"),
		"a picture with nowhere to go is refused, naming out");
	test::@check(f.refuses_tool("render_studio", `{"out":"studio","width":1281}`, "1281", "even"),
		"an odd width, which video encoders refuse, is refused");
	test::@check(f.refuses_tool("capture", `{"action":"reference","width":1344}`, "width", "height"),
		"a reference width without its height is refused");
	test::@check(f.refuses_tool("capture", `{"action":"reference","width":1345,"height":768}`, "even"),
		"an odd reference width is refused");
	test::@check(f.refuses_tool("render_studio", `{"out":"studio","ground_row":100}`, "ground_row", "360"),
		"a floor above the middle of the picture is refused against the range");
	test::@check(f.refuses_tool("render_studio", `{"out":"studio","front_width":1250}`, "front_width"),
		"a front view that leaves the side no room is refused");
	test::@check(f.refuses_tool("render_studio", `{"out":"studio","clip":3}`, "clip"),
		"a clip that is not a name is refused");
	test::@check(f.refuses_tool("render_studio", `{"out":"studio"}`, "headless"),
		"with no renderer it says so");
}

// capture's steps refuse what they cannot do, saying why.
fn void capture_names_what_it_cannot_do() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	test::@check(f.refuses_tool("capture", `{}`, "action"), "no action is refused, naming the actions");
	test::@check(f.refuses_tool("capture", `{"action":"dance"}`, "dance", "status"), "an unknown action is named");
	test::@check(f.refuses_tool("capture", `{"action":"train","poses":5}`, "poses", "50"), "a tiny training set is refused");
	test::@check(f.refuses_tool("capture", `{"action":"train"}`, "save it"), "a model with no file has no capture folder");
	test::@check(f.refuses_tool("capture", `{"action":"use_finder","finder":"/no/such.safetensors"}`, "not there"), "a missing finder is refused");
	test::@check(f.refuses_tool("capture", `{"action":"animate"}`, "video"), "animate needs a video");
	test::@check(f.refuses_tool("capture", `{"action":"reads"}`, "no animate run"), "reads needs a run to have finished");
}

// capture's reads says where the last run kept its files, and gives its report.
fn void capture_reads_gives_the_last_runs_files() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	String run = "build/test_capture_reads/runs/wave";
	defer (void)path::rmtree((Path)"build/test_capture_reads");
	test::@check(crig::keep_capture_run(run, "[]", "png", `{"report":{"reads":[[["hips",1,2.5,0]]]}}`), "a run's files are kept");
	f.app.capture_job.run = run.copy(mem);

	Object*? reads = f.call_tool("capture", `{"action":"reads"}`);
	if (catch reads)
	{
		test::@check(false, "reads answers once a run has finished");
		return;
	}
	defer reads.free();
	test::@check((reads.get_string("run") ?? "") == run, "it names the run's folder");
	test::@check((reads.get_string("reads") ?? "") == "build/test_capture_reads/runs/wave/reads.png", "the sheet: %s", reads.get_string("reads") ?? "");
	test::@check((reads.get_string("tracks") ?? "") == "build/test_capture_reads/runs/wave/tracks.json", "the tracks: %s", reads.get_string("tracks") ?? "");
	Object*? answer = reads.get("answer");
	test::@check(@ok(answer) && @ok(answer!!.get("report")), "and the task's answer with its report");

	Object*? status = f.call_tool("capture", `{"action":"status"}`);
	if (catch status)
	{
		test::@check(false, "status answers");
		return;
	}
	defer status.free();
	test::@check((status.get_string("run") ?? "") == run, "status names the last run too");
}

// plugins lists the folder the pipelines run from, and refuses to link what is
// not a plugin or to unlink a real folder.
fn void plugins_lists_the_folder_and_refuses_what_it_should() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	String? listed = f.call_tool_text("plugins", `{"action":"list"}`);
	test::@check(@ok(listed), "list answers");
	if (try listed)
	{
		defer alloc::free(mem, listed);
		test::@check(listed.contains(`"name":"kimodo"`) && listed.contains(`"name":"creature"`) && listed.contains(`"core":1`),
			"the carried folder's core and plugins: %s", listed);
	}
	test::@check(f.refuses_tool("plugins", `{}`, "action"), "no action is refused");
	test::@check(f.refuses_tool("plugins", `{"action":"link"}`, "folder"), "link needs a folder");
	test::@check(f.refuses_tool("plugins", `{"action":"link","folder":"src"}`, "not a plugin"), "a folder without plugin.json");
	test::@check(f.refuses_tool("plugins", `{"action":"unlink","name":"kimodo"}`, "only a linked plugin"), "a real plugin folder is not unlinked");
}

// `keys` photographs the poses a clip was written as, which is the question an
// agent has right after writing them: not "what happens at 0.3 s" but "did the
// five keys I sent come out as five sensible poses".
fn void render_photographs_a_clip_at_its_keys() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	int frames = 0;
	f.app.screenshot = &wide_grab;
	f.app.screenshot_ctx = &frames;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"render","arguments":{"clip":"bend","keys":true}}}`);
	if (catch root)
	{
		test::@check(false, "render answers for keys");
		return;
	}
	defer root.free();

	String mime;
	String data;
	String caption;
	if (!(screenshot_body(root, &mime, &data, &caption) ?? false))
	{
		test::@check(false, "render by key answers with an image block and a caption");
		return;
	}

	// bend is keyed at 0 and 0.5 and at nothing in between.
	test::@check(frames == 2, "one frame per key, %d drawn", frames);
	test::@check(caption.contains("keys 0, 1") && caption.contains("t = 0, 0.5"),
		"and the caption says which key each tile is and when it falls: %s", caption);
	test::@check(caption.contains("labelled"), "and that the tiles carry their own labels");
}

fn void render_picks_keys_by_number() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	Fixture* f = &fixture;

	int frames = 0;
	f.app.screenshot = &wide_grab;
	f.app.screenshot_ctx = &frames;

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":33,"method":"tools/call","params":{"name":"render","arguments":{"clip":"bend","keys":[1]}}}`);
	if (catch root)
	{
		test::@check(false, "render answers for one key");
		return;
	}
	defer root.free();

	String mime;
	String data;
	String caption;
	if (!(screenshot_body(root, &mime, &data, &caption) ?? false))
	{
		test::@check(false, "render of one key answers with an image block and a caption");
		return;
	}
	test::@check(frames == 1, "only the key asked for is drawn, %d drawn", frames);
	test::@check(caption.contains("keys 1 (t = 0.5"), "and it is key 1, at 0.5 s: %s", caption);

	frames = 0;
	test::@check(f.refuses_tool("render", `{"clip":"bend","keys":[2]}`, "2 key(s)", "key 1 at 0.5 s"),
		"a key past the last is refused with the keys there are");
	test::@check(f.refuses_tool("render", `{"clip":"bend","keys":[0.5]}`, "keys[0]"),
		"a key number is a whole number");
	test::@check(f.refuses_tool("render", `{"clip":"bend","keys":true,"times":[0]}`, "Give one of them"),
		"keys and times together are refused rather than one silently winning");
	test::@check(f.refuses_tool("render", `{"keys":true}`, "get_scene"),
		"keys with no clip says there is no clip to have keys");
	test::@check(frames == 0, "and nothing was drawn on the way to refusing");
}

// A clip keyed every frame — anything baked or imported — has more keys than a
// sheet holds. Every key at once is refused with the list to choose from, not
// cut short at sixteen, which would answer a different question than was asked.
fn void render_refuses_more_keys_than_a_sheet_holds() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	DString clip = dstring::new(mem);
	defer clip.free();
	clip.append_string(`{"name":"dense","keyframes":[`);
	for (int i = 0; i < 17; i++)
	{
		clip.appendf(`%s{"time":%.4g,"joints":[{"name":"knee","rotation":[0,0,0]}]}`, i > 0 ? "," : "", (double)i / 30.0);
	}
	clip.append_string(`]}`);

	Object*? applied = f.call_tool("apply_clip", clip.str_view());
	if (catch applied)
	{
		test::@check(false, "a seventeen-key clip could be authored");
		return;
	}
	applied.free();

	int frames = 0;
	f.app.screenshot = &wide_grab;
	f.app.screenshot_ctx = &frames;

	test::@check(f.refuses_tool("render", `{"clip":"dense","keys":true}`, "17 keys", "key 16 at"),
		"every key of a clip with more than a sheet holds is refused, naming them");

	Object*? root = f.request(
		`{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"render","arguments":{"clip":"dense","keys":[0,8,16]}}}`);
	if (catch root)
	{
		test::@check(false, "some of them can still be asked for");
		return;
	}
	root.free();
	test::@check(frames == 3, "and are drawn, %d drawn", frames);
}

fn void a_tile_label_is_drawn_into_the_pixels() @test
{
	char[20 * 12 * 4] pixels;
	foreach (&channel : pixels) *channel = 200;

	image::Image picture = {
		.width = 20,
		.height = 12,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels[..],
	};

	// "1" is one glyph: a box of 3 + 2 wide and 5 + 2 tall at scale 1.
	crig::draw_label(&picture, 1, 1, 1, "1");

	int white;
	int dark;
	bool alpha_kept = true;
	bool outside_untouched = true;
	for (uint y = 0; y < 12; y++)
	{
		for (uint x = 0; x < 20; x++)
		{
			char* p = &pixels[(y * 20 + x) * 4];
			bool inside = x >= 1 && x < 6 && y >= 1 && y < 8;
			if (p[3] != 200 && p[3] != 255) alpha_kept = false;
			if (!inside && (p[0] != 200 || p[3] != 200)) outside_untouched = false;
			if (inside && p[0] == 255) white++;
			if (inside && p[0] == 50) dark++;
		}
	}
	test::@check(white == 8, "the glyph's eight pixels are white, %d were", white);
	test::@check(dark == 5 * 7 - 8, "and the rest of its box is darkened, %d were", dark);
	test::@check(alpha_kept, "the box never makes the picture see-through");
	test::@check(outside_untouched, "and nothing outside the box is touched");

	// Past the right and bottom edges: clipped, not written past the buffer.
	char[4 * 3 * 4] small;
	image::Image corner = {
		.width = 4,
		.height = 3,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = small[..],
	};
	crig::draw_label(&corner, 2, 1, 3, "k15 10.00s");
	test::@check(true, "a label running off the image is clipped to it");
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

<*
 `frame` and `target` find a character that was placed away from the origin.

 The camera orbits in the world and the model is drawn through its placement, so
 framing the mesh's own bounds, or taking a model-space target as a world one,
 aims at the empty spot the model would stand on unplaced — and every picture
 after that is bare floor with nothing in the answer to say why.
*>
fn void set_camera_frames_a_placed_character_where_it_stands() @test
{
	Fixture fixture;
	fixture.open();
	defer fixture.close();
	Fixture* f = &fixture;

	f.app.doc.model_transform.location = { 5, 0, 0 };

	Object*? framed = f.call_tool("set_camera", `{"frame":true}`);
	if (catch framed)
	{
		test::@check(false, "set_camera takes frame on a placed character");
		return;
	}
	defer framed.free();

	Vec3 centre = f.app.world_bounds().center();
	test::@check((f.app.camera.target - centre).length() < 0.001f,
		"frame centres on the character where it stands, not where its mesh would be unplaced (%.3f from it)",
		(f.app.camera.target - centre).length());

	Object*? aimed = f.call_tool("set_camera", `{"camera":{"target":[0,0,0]}}`);
	if (catch aimed)
	{
		test::@check(false, "set_camera takes a target");
		return;
	}
	defer aimed.free();

	test::@check((f.app.camera.target - (Vec3){ 5, 0, 0 }).length() < 0.001f,
		"a model-space target is carried through the placement onto the world");
	Object* reported = aimed.get("target") ?? null;
	test::@check(reported != null && reported.get_len() == 3
		&& math::abs(reported.get_float_at(0) ?? 99) < 0.001,
		"and reported back in the model space it was given in");
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

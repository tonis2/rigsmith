<*
 Video capture's plumbing, without a GPU: where its files go, what ffprobe's
 answer means, the clip's name from the video's, where a stopped training set
 carries on, the train task's settings, what a finder file says of itself, the
 refusal of a model with no file to put a capture folder beside, and of a
 plugins folder without the creature plugin; and the pane's graph: its first
 shape, graph.json, its wires, and the order a run takes.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::capture`
*>
module crig_tests::capture;

import crig;
import crig_tests::mcp;
import std::core::test;
import std::collections::object;
import std::encoding::json;
import std::io::file;
import std::io::path;
import std::math;
import std::collections::list;
import gltf_edit;
import rig;
import crig_tests::trust_fixes;

fn void the_capture_folder_sits_beside_the_model() @test
{
	test::@check(crig::capture_folder_of("/models/zidane_2.glb") == "/models/zidane_2.capture", "the extension goes");
	test::@check(crig::capture_folder_of("/models/v1.2/hero") == "/models/v1.2/hero.capture", "a dot in a folder name is not an extension");
	test::@check(crig::capture_folder_of("") == "", "a model with no file has none");
}

fn void ffprobe_answers_are_read() @test
{
	float fps;
	usz frames;
	crig::parse_probe("24/1,107\n", &fps, &frames);
	test::@check(fps == 24.0f && frames == 107, "a whole rate and a count (%s, %d)", fps, frames);
	crig::parse_probe("30000/1001,N/A", &fps, &frames);
	test::@check(math::abs(fps - 29.97f) < 0.01f && frames == 0, "NTSC's rate, and no count (%s, %d)", fps, frames);
	crig::parse_probe("", &fps, &frames);
	test::@check(fps == 0.0f, "nothing said is no rate");
}

fn void a_clip_is_named_after_its_video() @test
{
	test::@check(crig::capture_clip_name("/home/me/Downloads/zidane_wave.mp4") == "zidane_wave", "the file name without its extension");
	test::@check(crig::capture_clip_name("/frames/wave_take2/") == "wave_take2", "a folder of frames by its name");
	test::@check(crig::capture_clip_name("") == "Captured", "something when there is nothing");
}

fn void a_stopped_training_set_carries_on_from_its_first_missing_chunk() @test
{
	String dir = "build/test_capture_chunks";
	(void)path::rmtree((Path)dir);
	(void)path::mkdir(dir, true);
	defer (void)path::rmtree((Path)dir);
	test::@check(crig::first_missing_chunk(dir, 40) == 0, "an empty set starts at 0");
	for (usz first = 0; first < 24; first += crig::CAPTURE_CHUNK)
	{
		(void)file::save(string::tformat("%s/poses_%06d.json", dir, first), "{}");
	}
	test::@check(crig::first_missing_chunk(dir, 40) == 24, "three chunks drawn, the fourth is next");
	(void)file::save(string::tformat("%s/poses_%06d.json", dir, 8), "{}");
	test::@check(crig::first_missing_chunk(dir, 24) == 24, "a finished set has nothing left (24 of 24)");
}

fn void the_train_task_is_valid_json_with_its_paths() @test
{
	String text = crig::capture_train_json("/AI models/model.ckpt", "/m/zid \"x\".capture/renders", "/m/f.safetensors");
	defer text.free(mem);
	Object*? parsed = json::parse(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the train settings parse as JSON: %s", text);
		return;
	}
	defer parsed.free();
	test::@check((parsed.get_string("task") ?? "") == "train", "the task is train");
	test::@check((parsed.get_string("renders") ?? "") == "/m/zid \"x\".capture/renders", "a quote in a path survives");
	test::@check((parsed.get_string("model") ?? "") == "/AI models/model.ckpt", "the backbone");
	Object*? layers = parsed.get("layers");
	test::@check(@ok(layers) && layers!!.get_len() == 1, "the 20th block's features beside the last's");
}

fn void a_finder_says_what_it_is() @test
{
	String finder = "build/test_capture_finder.safetensors";
	String meta = `{"joints":["hips","head"],"report":{"held_out_px":{"median":5.5}}}`;
	DString header = dstring::new(mem);
	defer header.free();
	header.append_string(`{"__metadata__":{"finder":`);
	gltf_edit::escape_json_string(&header, meta);
	header.append_string("}}");
	char[] bytes = alloc::new_array(mem, char, 8 + header.len());
	defer alloc::free(mem, bytes);
	ulong n = (ulong)header.len();
	for (usz i = 0; i < 8; i++) bytes[i] = (char)(n >> (8 * i));
	bytes[8..] = ((char[])header.str_view())[..];
	(void)file::save(finder, bytes);
	defer (void)file::delete(finder);
	String said = crig::finder_summary(finder);
	test::@check(said == "2 points · 5.50 px held out", "its points and held-out error (%s)", said);
	test::@check(crig::finder_summary("build/no_such_finder.safetensors") == "", "a missing file says nothing");
}

fn void a_model_with_no_file_has_no_capture() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.source_path.len == 0, "the fixture's model was never read from a file");
	test::@check(@catch(app.start_capture_training(100, "", "")) == crig::CAPTURE_NO_MODEL_FILE, "training is refused, naming the missing file");
	test::@check(@catch(app.start_capture_animation("", "", "", "")) == crig::CAPTURE_NO_MODEL_FILE, "so is reading a video");
	test::@check(@catch(app.request_capture_reference("", "", 0)) == crig::CAPTURE_NO_MODEL_FILE, "and the reference picture");
	test::@check(!app.capture_job.running && !app.capture_job.reference_pending, "nothing was started");
}

fn void a_plugins_folder_without_creature_is_refused_before_the_gpu() @test
{
	String dir = "build/test_capture_plugins";
	(void)path::mkdir(dir, true);
	defer (void)path::rmtree((Path)dir);
	String source = string::tformat("%s/humanoid.glb", dir);
	trust_fixes::copy_humanoid(source);
	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.config.motion_generator.creature_model = "/models/model.ckpt".copy(mem);
	app.config.motion_generator.plugins = string::format(mem, "%s/no_plugins", dir);
	test::@check(@catch(app.start_capture_training(100, app.capture_path("renders"), app.capture_path("finder.safetensors"))) == crig::CAPTURE_NO_PLUGIN, "training needs the creature plugin");
	test::@check(@catch(app.start_capture_animation("", "", "", "")) == crig::CAPTURE_NO_PLUGIN, "so does reading a video");
	test::@check(@catch(app.request_capture_reference(app.capture_path("studio"), "", 0)) != crig::CAPTURE_NO_PLUGIN, "the reference picture is Rigsmith's own drawing");
	test::@check(crig::capture_fault_text(crig::CAPTURE_NO_PLUGIN).contains("Plugins"), "the notice says where to fix it");
}

fn void the_animate_task_asks_for_the_tracks_too() @test
{
	String dir = "build/test_capture_animate";
	(void)path::mkdir(dir, true);
	defer (void)path::rmtree((Path)dir);
	String source = string::tformat("%s/humanoid.glb", dir);
	trust_fixes::copy_humanoid(source);
	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	String text = app.capture_animate_json();
	defer text.free(mem);
	Object*? parsed = json::parse(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the animate settings parse as JSON: %s", text);
		return;
	}
	defer parsed.free();
	Object*? outputs = parsed.get("outputs");
	test::@check(@ok(outputs) && outputs!!.get_len() == 2, "the clip and its tracks");
	test::@check((outputs!!.get_string_at(1) ?? "") == "tracks", "the tracks, to fit again without the GPU");
}

// The humanoid in a folder of its own, its capture folder empty.
fn crig::AppState capture_app(String dir, rig::TriMesh* mesh) @local
{
	(void)path::rmtree((Path)dir);
	(void)path::mkdir(dir, true);
	String source = string::tformat("%s/humanoid.glb", dir);
	trust_fixes::copy_humanoid(source);
	*mesh = rig::load_gltf(mem, source)!!;
	return crig::new_app(*mesh, source);
}

fn void a_new_capture_graph_wires_its_steps_into_animate() @test
{
	String dir = "build/test_capture_graph_new";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::CaptureGraph* g = app.capture_graph_now();
	test::@check(g.count() == 4, "four nodes (%d)", g.count());
	sz animate = g.find("animate");
	test::@check(animate >= 0 && g.at(animate).kind == crig::CaptureNodeKind.ANIMATE, "an Animate node");
	if (animate < 0) return;
	test::@check(g.at(animate).input[0] == g.find("train"), "the trained finder into Animate");
	test::@check(g.at(animate).input[1] == g.find("reference"), "the picture into Animate");
	test::@check(g.at(animate).input[2] == g.find("video"), "the video into Animate");
	g.rebuild_view(&app);
	test::@check(g.shown_wires.len() == 3 && g.shown_ports.len() == 6, "three wires, six ports (%d, %d)", g.shown_wires.len(), g.shown_ports.len());

	// A finder chosen before the graph comes in as a Finder file.
	String chosen = string::tformat("%s/other.safetensors", dir);
	(void)file::save(chosen, "x");
	(void)app.use_capture_finder(chosen);
	app.capture_graph.free();
	g = app.capture_graph_now();
	sz finder = g.find("finder");
	test::@check(finder >= 0 && g.find("train") < 0, "a Finder file instead of Train");
	if (finder < 0) return;
	test::@check(g.at(finder).params[0] == chosen, "holding the chosen file (%s)", g.at(finder).params[0]);
	test::@check(g.at(g.find("animate")).input[0] == finder, "wired into Animate");
}

fn void a_capture_graph_reads_back_what_it_saved() @test
{
	String dir = "build/test_capture_graph_json";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::CaptureGraph* g = app.capture_graph_now();
	usz video = (usz)g.find("video");
	g.set_param(video, 0, "/clips/a \"b\".mp4");
	g.at(video).pos = { 120, 640 };
	usz second = g.add(crig::CaptureNodeKind.ANIMATE, { 400, 500 });
	test::@check(g.connect((usz)g.find("train"), second, 0) && g.connect(video, second, 2), "the second Animate takes the finder and the video");
	g.view = { .pan = { 15, -30 }, .zoom = 0.5 };
	g.changed();
	app.capture_graph.free();

	g = app.capture_graph_now();
	test::@check(g.count() == 5, "five nodes read back (%d)", g.count());
	sz again = g.find("video");
	sz read_second = g.find("animate2");
	if (again < 0 || read_second < 0)
	{
		test::@check(false, "the video and the second Animate are there");
		return;
	}
	test::@check(g.at(again).params[0] == "/clips/a \"b\".mp4", "the path, quotes and all (%s)", g.at(again).params[0]);
	test::@check(g.at(again).pos.x == 120 && g.at(again).pos.y == 640, "where it was put");
	test::@check(g.at(read_second).input[0] == g.find("train") && g.at(read_second).input[1] == -1 && g.at(read_second).input[2] == again, "its wires, the picture still free");
	test::@check(g.view.zoom == 0.5f && g.view.pan.x == 15, "the view");
}

fn void capture_wires_carry_one_thing_and_go_with_their_nodes() @test
{
	String dir = "build/test_capture_graph_wires";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::CaptureGraph* g = app.capture_graph_now();
	usz animate = (usz)g.find("animate");
	usz video = (usz)g.find("video");
	test::@check(!g.connect(video, animate, 0), "a video is not a finder");
	usz other = g.add(crig::CaptureNodeKind.FINDER_FILE, { 0, 0 });
	test::@check(g.connect(other, animate, 0) && g.at(animate).input[0] == (sz)other, "a second finder takes the input over");

	g.remove((usz)g.find("reference"));
	animate = (usz)g.find("animate");
	test::@check(g.at(animate).input[1] == -1, "the picture's wire went with it");
	sz fed = g.at(animate).input[2];
	test::@check(fed >= 0 && g.at(fed).kind == crig::CaptureNodeKind.VIDEO, "the video's wire still finds the video");
}

fn void running_animate_trains_the_finder_first_unless_it_is_there() @test
{
	String dir = "build/test_capture_graph_order";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	crig::CaptureGraph* g = app.capture_graph_now();
	usz train = (usz)g.find("train");
	usz animate = (usz)g.find("animate");
	g.set_param((usz)g.find("video"), 0, app.source_path);
	g.set_param(animate, 0, "order_test");
	(void)path::mkdir(app.capture_path("studio"), true);
	(void)file::save(app.capture_path("studio/studio.json"), "{}");

	List{usz} order;
	order.init(mem);
	defer order.free();
	test::@check(@ok(app.capture_order(animate, &order)), "Animate can run");
	test::@check(order.len() == 2 && order[0] == train && order[1] == animate, "the finder is trained first: %s", order);

	(void)file::save(app.capture_path("finder.safetensors"), "x");
	order.clear();
	(void)app.capture_order(animate, &order);
	test::@check(order.len() == 1 && order[0] == animate, "a trained finder is skipped: %s", order);
	order.clear();
	(void)app.capture_order(train, &order);
	test::@check(order.len() == 1 && order[0] == train, "but trains again when run itself");

	g.disconnect(animate, 1);
	order.clear();
	test::@check(@catch(app.capture_order(animate, &order)) == crig::CAPTURE_NO_REFERENCE, "Animate without a picture is refused");
}

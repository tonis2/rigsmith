<*
 Video capture's plumbing, without a GPU: where its files go, the clip's
 name from the video's, which reference a video's first frame was made from, where a stopped training set
 carries on, the train task's settings, what a finder file says of itself, the
 refusal of a model with no file to put a capture folder beside, and of a
 plugins folder without the creature plugin; and the Nodes pane's graph: its
 first shape, nodes.json, templates, model nodes and the config, its wires,
 and the order a run takes.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::capture`
*>
module crig_tests::capture;

import crig;
import libc;
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
import image;
import image::png;
import image::mp4;
import image::h264;
import crig_tests::trust_fixes;

fn void the_capture_folder_sits_beside_the_model() @test
{
	test::@check(crig::capture_folder_of("/models/zidane_2.glb") == "/models/zidane_2.capture", "the extension goes");
	test::@check(crig::capture_folder_of("/models/v1.2/hero") == "/models/v1.2/hero.capture", "a dot in a folder name is not an extension");
	test::@check(crig::capture_folder_of("") == "", "a model with no file has none");
}

fn void a_clip_is_named_after_its_video() @test
{
	test::@check(crig::capture_clip_name("/home/me/Downloads/zidane_wave.mp4") == "zidane_wave", "the file name without its extension");
	test::@check(crig::capture_clip_name("/frames/wave_take2/") == "wave_take2", "a folder of frames by its name");
	test::@check(crig::capture_clip_name("") == "Captured", "something when there is nothing");
}

fn void the_divider_is_the_column_dark_from_top_to_bottom() @test
{
	uint width = 200;
	uint height = 100;
	char[] rgba = alloc::new_array(mem, char, (sz)(width * height * 4));
	defer alloc::free(mem, rgba);
	rgba[..] = 130;
	// A dark figure that stops short of the top is not a divider.
	for (uint y = 40; y < height; y++) for (uint x = 70; x < 90; x++) for (uint c = 0; c < 3; c++) rgba[((usz)y * width + x) * 4 + c] = 20;
	test::eq(crig::divider_column(rgba, width, height), (sz)-1);
	for (uint y = 0; y < height; y++) for (uint x = 118; x < 121; x++) for (uint c = 0; c < 3; c++) rgba[((usz)y * width + x) * 4 + c] = 34;
	test::eq(crig::divider_column(rgba, width, height), (sz)119);
}

fn void a_divider_is_held_to_its_reference_at_any_size() @test
{
	test::@check(crig::divider_fits(675, 1344, 768, 1344, 768, 676), "the reference's own split");
	test::@check(!crig::divider_fits(762, 1344, 768, 1344, 768, 676), "a split 87 pixels along");
	// The clip a little wider than the layout: scaled to cover, the sides cropped.
	test::@check(crig::divider_fits(697, 1344, 768, 1280, 720, 664), "664 of 1280, scaled to 1344 x 768");
	test::@check(!crig::divider_fits(762, 1344, 768, 1280, 720, 664), "a split elsewhere at that size");
}

fn void a_picture_that_cannot_be_read_is_not_called_wrong() @test
{
	test::@check(crig::reference_fits_picture("build/no_such_reference", "build/no_such_picture.png"), "nothing to go by");
}

fn void a_copied_reference_keeps_its_prompt_beside_it() @test
{
	test::@check(crig::reference_prompt_copy("/refs/Test.png") == "/refs/Test.txt", "the picture's name, as text");
	test::@check(crig::reference_prompt_copy("/refs.v2/Test") == "/refs.v2/Test.txt", "a dot in the folder is not the extension");
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

fn void a_finder_trained_on_half_the_poses_says_how_well() @test
{
	String finder = "build/test_capture_half.safetensors";
	String meta = `{"joints":["hips","head"],"report":{"held_out_px":{"median":5.5},"held_out_px_half":{"median":6.25}}}`;
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
	test::@check(said == "2 points · 5.50 px held out (half the poses 6.25 px)", "the half set's error (%s)", said);
}

fn void a_finder_with_hands_says_so() @test
{
	String finder = "build/test_capture_hands.safetensors";
	String meta = `{"joints":["hips","head"],"report":{"held_out_px":{"median":5.5}},"hands":{"report":{"held_out_px":{"median":3.25}}}}`;
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
	test::@check(said == "2 points · 5.50 px held out · hands 3.25 px", "its hands' held-out error (%s)", said);
}

fn void a_model_with_no_file_has_no_capture() @test
{
	Fixture fixture;
	fixture.open_authored();
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.source_path.len == 0, "the fixture's model was never read from a file");
	test::@check(@catch(app.start_capture_training(100, 448, "", "", "")) == crig::CAPTURE_NO_MODEL_FILE, "training is refused, naming the missing file");
	test::@check(@catch(app.start_capture_animation("", "", "", "", "")) == crig::CAPTURE_NO_MODEL_FILE, "so is reading a video");
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
	test::@check(@catch(app.start_capture_training(100, 448, app.capture_path("renders"), app.capture_path("finder.safetensors"), "/models/model.ckpt")) == crig::CAPTURE_NO_PLUGIN, "training needs the creature plugin");
	test::@check(@catch(app.start_capture_animation("/models/model.ckpt", "", "", "", "")) == crig::CAPTURE_NO_PLUGIN, "so does reading a video");
	test::@check(@catch(app.request_capture_reference(app.capture_path("studio"), "", 0)) != crig::CAPTURE_NO_PLUGIN, "the reference picture is Rigsmith's own drawing");
	test::@check(crig::capture_fault_text(crig::CAPTURE_NO_PLUGIN).contains("Plugins"), "the notice says where to fix it");
}

fn void the_animate_task_asks_for_the_clip_only() @test
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
	test::@check(@ok(outputs) && outputs!!.get_len() == 1 && (outputs!!.get_string_at(0) ?? "") == "glb", "the clip and nothing to write beside the model");
	test::@check(!@ok(parsed.get("flip")), "the mirror check is on unless turned off");
	app.capture_job.mirror_off = true;
	String once = app.capture_animate_json();
	defer once.free(mem);
	Object*? read_once = json::parse(mem, once);
	if (catch read_once)
	{
		test::@check(false, "the animate settings parse as JSON: %s", once);
		return;
	}
	defer read_once.free();
	test::@check(@ok(read_once.get_bool("flip")) && !read_once.get_bool("flip")!!, "with it off each frame is read once");
	test::@check(!@ok(read_once.get("max_frames")), "the whole video unless told fewer");
	app.capture_job.max_frames = 40;
	String brief = app.capture_animate_json();
	defer brief.free(mem);
	Object*? read_short = json::parse(mem, brief);
	if (catch read_short)
	{
		test::@check(false, "the animate settings parse as JSON: %s", brief);
		return;
	}
	defer read_short.free();
	test::@check((read_short.get_int("max_frames") ?? 0) == 40, "only the first 40 frames: %s", brief);
	app.capture_job.max_frames = 0;

	// A picture goes as a one-item list, read where it is.
	app.capture_job.pose = true;
	app.capture_job.frames = "/pictures/crouch.png".copy(mem);
	String pose = app.capture_animate_json();
	defer pose.free(mem);
	Object*? read_pose = json::parse(mem, pose);
	if (catch read_pose)
	{
		test::@check(false, "the pose settings parse as JSON: %s", pose);
		return;
	}
	defer read_pose.free();
	Object*? frames = read_pose.get("frames");
	test::@check(@ok(frames) && frames!!.get_len() == 1 && (frames!!.get_string_at(0) ?? "") == "/pictures/crouch.png", "the picture itself: %s", pose);
}

fn void the_reference_picture_is_drawn_at_the_chosen_size() @test
{
	String dir = "build/test_reference_size";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	test::@check(app.reference_size_row() == 0, "1280 x 720 at first");
	String studio = app.capture_path("references/rest").copy(tmem);
	app.request_capture_reference(studio, "", 0)!!;
	test::@check(app.capture_job.reference_width == 1280 && app.capture_job.reference_height == 720, "the first size by default");

	app.set_reference_size(1);
	test::@check(app.config.reference_size == 1, "the choice is kept in the settings");
	app.request_capture_reference(studio, "", 0)!!;
	test::@check(app.capture_job.reference_width == 1344 && app.capture_job.reference_height == 768,
		"the chosen size (%d x %d)", app.capture_job.reference_width, app.capture_job.reference_height);
	app.request_capture_reference(studio, "", 0, "", 832, 480)!!;
	test::@check(app.capture_job.reference_width == 832 && app.capture_job.reference_height == 480, "a size asked for wins");

	app.config.reference_size = 99;
	test::@check(app.reference_size_row() == 0, "a size past the list is the first");
	app.capture_job.reference_pending = false;
}

fn void the_animate_notice_says_how_long_it_took() @test
{
	String summary = crig::capture_result_summary(`{"report": {"reprojection_px": {"median": 11.54}, "travel": 0.25, "seconds": {"track": 330, "fit": 4.2, "total": 587.4}}}`);
	test::@check(summary == "reprojection 11.5 px, root moved 25 cm, in 9 min 47 s (fit 4 s)", "the notice reads '%s'", summary);
	test::@check(crig::capture_result_summary(`{"report": {}}`) == "done", "an empty report is just done");
}

fn void an_animate_node_starts_with_the_mirror_check_off() @test
{
	String dir = "build/test_nodes_mirror";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::PipelineGraph* g = app.pipeline_now(TRAIN_TEMPLATE);
	crig::PipelineNode* animate = g.at((usz)g.find("animate"));
	test::@check(animate.params[1] == "0" && !crig::node_mirror_on(animate), "a new Animate node reads each frame once (%s)", animate.params[1]);
	test::@check((crig::node_max_frames(animate) ?? 99) == 0, "and the whole video");
	g.set_param((usz)g.find("animate"), 3, " 40 ");
	test::@check((crig::node_max_frames(animate) ?? 0) == 40, "Frames 40 reads the first 40");
	foreach (bad : (String[]) { "0", "-3", "ten" })
	{
		g.set_param((usz)g.find("animate"), 3, bad);
		test::@check(@catch(crig::node_max_frames(animate)) == crig::CAPTURE_BAD_FRAMES, "Frames '%s' is refused", bad);
	}
}

fn void image_to_pose_makes_a_saved_pose() @test
{
	String dir = "build/test_nodes_pose";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	app.open_template_named(POSE_TEMPLATE);
	crig::PipelineGraph* g = app.pipeline();
	sz animate = g.find("pose");
	sz image = g.find("image");
	test::@check(g.count() == 5 && animate >= 0 && image >= 0 && g.at(animate).input[1] == image, "the picture into Image to pose (%d nodes)", g.count());
	if (animate < 0 || image < 0) return;
	test::@check(g.find("reference") < 0, "no reference node: references come from the clip menu");
	test::@check(!g.connect((usz)image, (usz)g.add(crig::NodeKind.ANIMATE, { 600, 0 }), 1), "a picture does not wire into Animate's video");
	test::@check(!app.node_ready(g, (usz)image), "no picture chosen, not ready");

	// Everything it needs there, so only the pose's name can refuse it.
	String picture = string::tformat("%s/crouch.png", dir);
	String finder = string::tformat("%s/finder.safetensors", dir);
	String backbone = string::tformat("%s/model.ckpt", dir);
	foreach (made : (String[]) { picture, finder, backbone }) (void)file::save(made, "x");
	g.set_param((usz)image, 0, picture);
	g.set_param((usz)g.find("finder"), 0, finder);
	g.set_param((usz)g.find("backbone"), 0, backbone);
	test::@check(app.node_ready(g, (usz)image), "the picture is there");
	test::@check(g.clip_name((usz)animate) == "crouch", "the pose is named after the picture (%s)", g.clip_name((usz)animate));
	test::@check(!app.node_ready(g, (usz)animate), "no such pose yet");
	List{usz} order;
	order.init(tmem);
	test::@check(@catch(app.node_order(g, (usz)animate, &order)) == crig::CAPTURE_NO_REFERENCE, "no reference saved yet: refused");
	(void)path::mkdir(app.capture_reference_path("Crouch"), true);
	(void)file::save(string::tformat("%s/studio.json", app.capture_reference_path("Crouch")), "{}");
	(void)app.store_pose({ .name = "crouch".copy(mem) });
	test::@check(app.node_ready(g, (usz)animate), "ready once the pose is saved");
	test::@check(@catch(app.run_node(g, (usz)animate)) == crig::CAPTURE_POSE_TAKEN, "a taken name is refused");
	test::@check(crig::node_folder_slot(POSE) == 0 && crig::node_folder_slot(ANIMATE) == 0, "Image to pose and Animate write no files: no save folder");
}

fn void references_list_newest_first_and_the_old_studio_counts() @test
{
	String dir = "build/test_capture_references";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.capture_reference_for("").len == 0, "no references: none to read with");
	test::@check(crig::capture_reference_name("Arms / up: 2") == "Arms _ up_ 2", "a pose name as a folder (%s)", crig::capture_reference_name("Arms / up: 2"));
	String[3] made = { "studio", "Wave", "Crouch" };
	foreach (usz i, name : made)
	{
		String folder = app.capture_reference_path(name);
		(void)path::mkdir(folder, true);
		String json = string::tformat("%s/studio.json", folder);
		(void)file::save(json, "{}");
		(void)file::set_modified_time(json, (libc::Time_t)(1700000000 + (long)i * 100));
	}
	List{String} found;
	found.init(tmem);
	app.capture_references(tmem, &found);
	test::@check(found.len() == 3 && found[0] == "Crouch" && found[1] == "Wave" && found[2] == "studio", "newest first, the old studio too: %s", found);
	test::@check(app.capture_reference_for("Wave") == app.capture_reference_path("Wave"), "a chosen reference is used");
	test::@check(app.capture_reference_for("Gone") == app.capture_reference_path("Crouch"), "a missing one falls back to the newest");
	test::@check(app.capture_reference_path("studio") == app.capture_path("studio"), "the old studio keeps its folder");
}

// A picture with a light figure at `at` (0..1 across) on grey.
fn void save_figure(String file_name, float at, char shade = 200) @local
{
	uint w = 192;
	uint h = 96;
	char[] rgb = alloc::new_array(tmem, char, (usz)w * h * 3);
	for (uint y = 0; y < h; y++)
	{
		for (uint x = 0; x < w; x++)
		{
			bool figure = y > h / 4 && math::abs((float)x / w - at) < 0.06f;
			rgb[((usz)y * w + x) * 3 :3] = figure ? shade : (char)90;
		}
	}
	image::Image img = { .width = w, .height = h, .bit_depth = 8, .format = image::PixelFormat.RGB, .pixels = rgb, .allocator = tmem };
	(void)png::save_file(&img, file_name, tmem);
}

fn void the_first_frame_picks_its_reference() @test
{
	String dir = "build/test_capture_matching";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.capture_reference_matching("nothing.png").len == 0, "no references: nothing to match");
	float[2] places = { 0.2f, 0.7f };
	foreach (usz i, name : (String[]) { "Left", "Right" })
	{
		String folder = app.capture_reference_path(name);
		(void)path::mkdir(folder, true);
		String json = string::tformat("%s/studio.json", folder);
		(void)file::save(json, "{}");
		(void)file::set_modified_time(json, (libc::Time_t)(1700000000 + (long)i * 100));
		save_figure(string::tformat("%s/reference.png", folder), places[i]);
	}
	String frames = string::tformat("%s/frames", dir);
	(void)path::mkdir(frames, true);
	save_figure(string::tformat("%s/f_00002.png", frames), 0.7f);
	save_figure(string::tformat("%s/f_00001.png", frames), 0.22f, 230);
	test::@check(app.capture_reference_matching(string::tformat("%s/f_00001.png", frames)) == app.capture_reference_path("Left"), "a brighter frame still finds Left");
	test::@check(app.capture_reference_matching(string::tformat("%s/f_00002.png", frames)) == app.capture_reference_path("Right"), "and Right, though Left is older");
	test::@check(app.capture_reference_matching("unreadable.png") == app.capture_reference_path("Right"), "an unreadable frame takes the newest");
	test::@check(crig::first_picture_in(frames).ends_with("f_00001.png"), "the first frame is the first by name (%s)", crig::first_picture_in(frames));

	// A video is matched by its first frame, decoded here.
	String video = "libs/three/lib/image.c3l/test/crop_70x46.mp4";
	mp4::Video v = mp4::open(video)!!;
	image::Image first = v.frame(0, tmem)!!;
	v.close();
	String clip = app.capture_reference_path("Clip");
	(void)path::mkdir(clip, true);
	(void)file::save(string::tformat("%s/studio.json", clip), "{}");
	(void)file::set_modified_time(string::tformat("%s/studio.json", clip), (libc::Time_t)1600000000);
	(void)png::save_file(&first, string::tformat("%s/reference.png", clip), tmem);
	test::@check(app.capture_reference_matching(video) == clip, "a video finds the reference its first frame is, though it is the oldest");
	test::@check(crig::capture_fault_text(h264::CABAC).starts_with("High-profile H.264"), "a video it can't read says why: %s", crig::capture_fault_text(h264::CABAC));
}

fn void a_steps_save_folder_moves_its_files() @test
{
	String dir = "build/test_nodes_folder";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::PipelineGraph* g = app.pipeline_now(TRAIN_TEMPLATE);
	usz train = (usz)g.find("train");
	test::@check(app.capture_node_finder(g.at(train)) == app.capture_path("finder.safetensors"), "no folder: the capture folder's own");
	g.set_param(train, 2, "/elsewhere/train");
	test::@check(app.capture_node_finder(g.at(train)) == "/elsewhere/train/finder.safetensors", "the finder in Train's folder (%s)", app.capture_node_finder(g.at(train)));
	test::@check(crig::node_browse_purpose(TRAIN, 2) == crig::FilePurpose.CAPTURE_FOLDER && crig::node_browse_purpose(VIDEO, 0) == crig::FilePurpose.CAPTURE_VIDEO
		&& crig::node_browse_purpose(KIMODO_TEXT, 0) == crig::FilePurpose.MOTION_FILE && crig::node_browse_purpose(DINO_BACKBONE, 0) == crig::FilePurpose.MOTION_PATH,
		"each Browse asks for what its setting takes");
}

// The humanoid in a folder of its own, its capture folder empty, its config
// folder `<dir>/config`.
fn crig::AppState capture_app(String dir, rig::TriMesh* mesh) @local
{
	(void)path::rmtree((Path)dir);
	(void)path::mkdir(dir, true);
	String source = string::tformat("%s/humanoid.glb", dir);
	trust_fixes::copy_humanoid(source);
	*mesh = rig::load_gltf(mem, source)!!;
	crig::AppState app = crig::new_app(*mesh, source);
	app.config.directory = string::format(mem, "%s/config", dir);
	return app;
}

const usz TEXT_TEMPLATE = 0;
const usz TRAIN_TEMPLATE = 2;
const usz POSE_TEMPLATE = 4;

fn void each_template_opens_on_its_own_canvas() @test
{
	String dir = "build/test_nodes_new";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	app.config.motion_generator.text_model = "/models/kimodo-text.gguf".copy(mem);
	crig::PipelineGraph* g = app.pipeline();
	test::@check(app.open_template == TEXT_TEMPLATE && g.count() == 5, "text to motion's four nodes and its note (%d)", g.count());
	sz generate = g.find("generate");
	sz note = g.find("note");
	if (generate < 0 || note < 0)
	{
		test::@check(false, "a Text to motion node and a note");
		return;
	}
	test::@check(g.at(generate).input[0] == g.find("text_encoder") && g.at(generate).input[1] == g.find("motion_model")
		&& g.at(generate).input[2] == g.find("prompt") && g.at(generate).input[3] == -1, "the models and the prompt into Text to motion");
	test::@check(g.at(note).params[0].contains("Prompt"), "the note says how to use it");
	test::@check(g.at(g.find("text_encoder")).params[0] == "/models/kimodo-text.gguf", "the text encoder starts with the config's path");
	g.rebuild_view(&app);
	test::@check(g.shown_wires.len() == 3 && g.shown_ports.len() == 7, "three wires, seven ports (%d, %d)", g.shown_wires.len(), g.shown_ports.len());
	g.set_param((usz)g.find("prompt"), 0, "a bow");

	app.open_template_named(TRAIN_TEMPLATE);
	crig::PipelineGraph* capture = app.pipeline();
	test::@check(capture != g && capture.count() == 5, "train a finder: its four nodes and its note (%d)", capture.count());
	sz animate = capture.find("animate");
	test::@check(animate >= 0 && capture.at(animate).input[0] == capture.find("train") && capture.at(animate).input[2] == capture.find("backbone"),
		"the finder and the backbone into Animate");
	test::@check(app.config.nodes_template == (int)TRAIN_TEMPLATE, "the config keeps which is open");

	app.open_template_named(TEXT_TEMPLATE);
	test::@check(app.pipeline().at(app.pipeline().find("prompt")).params[0] == "a bow", "switching back keeps the edit");
	test::@check(app.reset_template(TEXT_TEMPLATE), "reset");
	g = app.pipeline();
	test::@check(g.count() == 5 && g.at(g.find("prompt")).params[0] != "a bow", "reset puts the template back");
	test::@check(g.at(g.find("text_encoder")).params[0] == "/models/kimodo-text.gguf", "model paths stay");
}

fn void a_node_graph_reads_back_what_it_saved() @test
{
	String dir = "build/test_nodes_json";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::PipelineGraph* g = app.pipeline_now(TRAIN_TEMPLATE);
	usz video = (usz)g.find("video");
	g.set_param(video, 0, "/clips/a \"b\".mp4");
	g.at(video).pos = { 120, 640 };
	usz second = g.add(crig::NodeKind.ANIMATE, { 400, 500 });
	test::@check(g.connect((usz)g.find("train"), second, 0) && g.connect(video, second, 1), "the second Animate takes the finder and the video");
	g.set_param((usz)g.find("train"), 0, "700");
	g.set_param((usz)g.find("note"), 0, "mine\nsecond line");
	g.view = { .pan = { 15, -30 }, .zoom = 0.5 };
	g.changed();
	test::@check(file::exists(string::tformat("%s/config/nodes/train_finder.json", dir)), "saved in the config folder");
	g.free();

	g = app.pipeline_now(TRAIN_TEMPLATE);
	test::@check(g.count() == 6, "six nodes read back (%d)", g.count());
	sz again = g.find("video");
	sz read_second = g.find("animate2");
	if (again < 0 || read_second < 0)
	{
		test::@check(false, "the video and the second Animate are there");
		return;
	}
	test::@check(g.at(again).params[0] == "/clips/a \"b\".mp4", "the path, quotes and all (%s)", g.at(again).params[0]);
	test::@check(g.at(again).pos.x == 120 && g.at(again).pos.y == 640, "where it was put");
	test::@check(g.at(read_second).input[0] == g.find("train") && g.at(read_second).input[1] == again && g.at(read_second).input[2] == -1, "its wires, the backbone still free");
	test::@check(g.at(g.find("train")).params[0] == "700", "the poses as set");
	test::@check(g.at(g.find("note")).params[0] == "mine\nsecond line", "the note's text, both lines");
	test::@check(g.view.zoom == 0.5f && g.view.pan.x == 15, "the view");
}

fn void a_note_has_no_ports_and_nothing_to_run() @test
{
	String dir = "build/test_nodes_note";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::PipelineGraph* g = app.pipeline();
	usz added = app.add_node(crig::NodeKind.NOTE, { 0, 600 });
	test::@check(g.at(added).id == "note2" && g.at(added).params[0] == "", "a fresh note, empty");
	g.rebuild_view(&app);
	foreach (port : g.ports()) test::@check(port.node != added, "a note has no ports");
	test::@check(!g.connect(added, (usz)g.find("generate"), 2), "nor can it be wired");
	test::@check(@catch(app.run_node(g, added)) == crig::NODE_NOTHING_TO_RUN, "nothing runs for it");
}

fn void a_run_belongs_to_its_template() @test
{
	String dir = "build/test_nodes_run";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	app.open_template_named(TRAIN_TEMPLATE);
	crig::PipelineGraph* capture = app.pipeline();
	// As a Train step leaves it while it runs.
	capture.running = capture.find("train");
	app.open_template_named(TEXT_TEMPLATE);
	crig::PipelineGraph* text = app.pipeline();
	test::@check(@catch(app.run_node(text, (usz)text.find("generate"))) == crig::CAPTURE_BUSY, "one run at a time, whichever template");
	test::@check(@ok(app.running_pipeline()) && app.running_pipeline()!! == capture, "the run is the train template's");
	app.advance_pipeline();
	test::@check(capture.running == -1 && capture.failed == -1, "the step ended on its own graph, though another is open");
	test::@check(text.running == -1 && text.failed == -1, "the open graph untouched");
}

fn void a_model_node_path_is_the_configs_default() @test
{
	String dir = "build/test_nodes_config";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::PipelineGraph* g = app.pipeline();
	app.set_node_param((usz)g.find("motion_model"), 0, "/models/kimodo-soma");
	app.open_template_named(TRAIN_TEMPLATE);
	app.set_node_param((usz)app.pipeline().find("backbone"), 0, "/models/model.ckpt");
	app.open_template_named(TEXT_TEMPLATE);
	test::@check(app.config.motion_generator.model == "/models/kimodo-soma", "the motion model is the config's (%s)", app.config.motion_generator.model);
	test::@check(app.config.motion_generator.creature_model == "/models/model.ckpt", "so is the backbone");
	usz added = app.add_node(crig::NodeKind.KIMODO_MODEL, { 0, 0 });
	test::@check(g.at(added).params[0] == "/models/kimodo-soma", "a new motion model node starts with it");
	app.set_node_param((usz)g.find("prompt"), 0, "a wave");
	test::@check(app.config.motion_generator.model == "/models/kimodo-soma", "a prompt is not a config setting");
}

fn void text_to_motion_needs_its_prompt_and_models() @test
{
	String dir = "build/test_nodes_generate";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	crig::PipelineGraph* g = app.pipeline();
	usz generate = (usz)g.find("generate");
	List{usz} order;
	order.init(mem);
	defer order.free();
	test::@check(@catch(app.node_order(g, generate, &order)) == crig::NODE_SOURCE_MISSING && g.blocker == g.find("text_encoder"),
		"no text encoder file: refused, naming it");
	app.set_node_param((usz)g.find("text_encoder"), 0, app.source_path);
	app.set_node_param((usz)g.find("motion_model"), 0, app.source_path);
	order.clear();
	test::@check(@ok(app.node_order(g, generate, &order)) && order.len() == 1 && order[0] == generate, "set: only the generate step runs");
	g.disconnect(generate, 2);
	order.clear();
	test::@check(@catch(app.node_order(g, generate, &order)) == crig::MOTION_NO_PROMPT, "no prompt wired in");
	(void)g.connect((usz)g.find("prompt"), generate, 2);
	g.set_param(generate, 1, "40");
	order.clear();
	test::@check(@catch(app.node_order(g, generate, &order)) == crig::MOTION_BAD_SECONDS, "forty seconds is too long");
	test::@check(@catch(app.run_node(g, (usz)g.find("prompt"))) == crig::NODE_NOTHING_TO_RUN, "a prompt is a setting, not a step");
}

fn void node_wires_carry_one_thing_and_go_with_their_nodes() @test
{
	String dir = "build/test_nodes_wires";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	crig::PipelineGraph* g = app.pipeline_now(TRAIN_TEMPLATE);
	usz animate = (usz)g.find("animate");
	usz video = (usz)g.find("video");
	test::@check(!g.connect(video, animate, 0), "a video is not a finder");
	test::@check(!g.connect(g.add(crig::NodeKind.KIMODO_TEXT, { 0, 0 }), animate, 2), "a text encoder is not a backbone");
	usz other = g.add(crig::NodeKind.FINDER_FILE, { 0, 0 });
	test::@check(g.connect(other, animate, 0) && g.at(animate).input[0] == (sz)other, "a second finder takes the input over");

	g.remove((usz)g.find("train"));
	animate = (usz)g.find("animate");
	test::@check(g.at(animate).input[0] == (sz)g.find("finder"), "the other finder's wire stays");
	sz fed = g.at(animate).input[1];
	test::@check(fed >= 0 && g.at(fed).kind == crig::NodeKind.VIDEO, "the video's wire still finds the video");
}

fn void running_animate_trains_the_finder_first_unless_it_is_there() @test
{
	String dir = "build/test_nodes_order";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	crig::PipelineGraph* g = app.pipeline_now(TRAIN_TEMPLATE);
	usz train = (usz)g.find("train");
	usz animate = (usz)g.find("animate");
	g.set_param((usz)g.find("video"), 0, app.source_path);
	g.set_param((usz)g.find("backbone"), 0, app.source_path);
	g.set_param(animate, 0, "order_test");
	List{usz} early;
	early.init(tmem);
	test::@check(@catch(app.node_order(g, animate, &early)) == crig::CAPTURE_NO_REFERENCE, "Animate with no reference saved is refused");
	(void)path::mkdir(app.capture_path("studio"), true);
	(void)file::save(app.capture_path("studio/studio.json"), "{}");

	List{usz} order;
	order.init(mem);
	defer order.free();
	test::@check(@ok(app.node_order(g, animate, &order)), "Animate can run");
	test::@check(order.len() == 2 && order[0] == train && order[1] == animate, "the finder is trained first: %s", order);

	(void)file::save(app.capture_path("finder.safetensors"), "x");
	order.clear();
	(void)app.node_order(g, animate, &order);
	test::@check(order.len() == 1 && order[0] == animate, "a trained finder is skipped: %s", order);
	order.clear();
	(void)app.node_order(g, train, &order);
	test::@check(order.len() == 1 && order[0] == train, "but trains again when run itself");

	g.disconnect(animate, 2);
	order.clear();
	test::@check(@catch(app.node_order(g, animate, &order)) == crig::CAPTURE_NO_BACKBONE, "and without a backbone");
}

fn void a_train_node_checks_its_size() @test
{
	String dir = "build/test_nodes_size";
	rig::TriMesh mesh;
	crig::AppState app = capture_app(dir, &mesh);
	defer { app.free(); mesh.free(mem); (void)path::rmtree((Path)dir); }
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	crig::PipelineGraph* g = app.pipeline_now(TRAIN_TEMPLATE);
	usz train = (usz)g.find("train");
	g.set_param((usz)g.find("backbone"), 0, app.source_path);
	test::@check(g.at(train).params[1] == "448", "a new Train node draws 448 px pictures (%s)", g.at(train).params[1]);
	List{usz} order;
	order.init(mem);
	defer order.free();
	foreach (bad : (String[]) { "500", "464", "2048", "big" })
	{
		g.set_param(train, 1, bad);
		order.clear();
		test::@check(@catch(app.node_order(g, train, &order)) == crig::CAPTURE_BAD_SIZE, "%s px is refused", bad);
	}
	g.set_param(train, 1, "640");
	order.clear();
	test::@check(@ok(app.node_order(g, train, &order)) && order.len() == 1, "640 px is taken");
	test::@check(@catch(app.start_capture_training(100, 500, "", "", "")) == crig::CAPTURE_BAD_SIZE, "so is the job's own check");
}

fn void a_training_set_of_another_size_is_drawn_again() @test
{
	String dir = "build/test_capture_resize";
	(void)path::mkdir(dir, true);
	defer (void)path::rmtree((Path)dir);
	String first = string::tformat("%s/poses_000000.json", dir);
	String camera = `{"pitch": 4}`;
	String cameras = string::tformat("[%s, %s, %s, %s]", camera, camera, camera, camera);
	(void)file::save(first, string::tformat(`{"draw": 3, "size": 448, "count": 8, "blur": 0, "leg_share": 0.5, "cameras": %s, "images": []}`, cameras));
	crig::fit_renders_to(dir, 448);
	test::@check(file::exists(first), "a set at the same size is kept, to carry on");
	crig::fit_renders_to(dir, 640);
	test::@check(!file::exists(first), "a set at another size is emptied");

	// Drawn from fewer cameras, with other settings or in other chunks: drawn again too.
	String level = `[{"pitch": 8}, {"pitch": 8}, {"pitch": 8}, {"pitch": 8}]`;
	String[2][*] stale = {
		{ `{"draw": 3, "size": 448, "count": 8, "blur": 0, "leg_share": 0.5, "cameras": %s, "images": []}`, `[{"pitch": 4}]` },
		{ `{"draw": 3, "size": 448, "count": 8, "blur": 0.3, "leg_share": 0.5, "cameras": %s, "images": []}`, cameras },
		{ `{"draw": 3, "size": 448, "count": 8, "blur": 0, "leg_share": 0.5, "cameras": %s, "images": []}`, level },
		{ `{"draw": 3, "size": 448, "count": 125, "blur": 0, "leg_share": 0.5, "cameras": %s, "images": []}`, cameras },
		{ `{"size": 448, "cameras": %s, "images": []}`, cameras },
		{ `{"draw": 1, "size": 448, "count": 8, "blur": 0, "leg_share": 0.5, "cameras": %s, "images": []}`, cameras },
	};
	foreach (row : stale)
	{
		String header = string::tformat(row[0], row[1]);
		(void)path::mkdir(dir, true);
		(void)file::save(first, header);
		crig::fit_renders_to(dir, 448);
		test::@check(!file::exists(first), "a stale set is emptied: %s", header);
	}
}

fn void animate_draws_sharp_hard_legged_level_poses() @test
{
	crig::PoseShoot shoot = crig::capture_shoot(768);
	test::eq(shoot.size, 768u);
	test::@check(shoot.blur == 0 && shoot.leg_share == 0.5f, "blur %f, leg share %f", shoot.blur, shoot.leg_share);
	test::eq(shoot.camera_count, crig::CAPTURE_CAMERAS);
	for (usz c = 0; c < shoot.camera_count; c++) test::@check(shoot.cameras[c].pitch == 4, "camera %d pitch %f", c, shoot.cameras[c].pitch);
	test::@check(shoot.all_clips && shoot.landmarks, "clips and landmarks are drawn");
}

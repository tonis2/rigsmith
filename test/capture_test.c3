<*
 Video capture's plumbing, without a GPU: where its files go, what ffprobe's
 answer means, the clip's name from the video's, where a stopped training set
 carries on, the train task's settings, what a finder file says of itself, and
 the refusal of a model with no file to put a capture folder beside.

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
import gltf_edit;

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
	test::@check(@catch(app.start_capture_training(100)) == crig::CAPTURE_NO_MODEL_FILE, "training is refused, naming the missing file");
	test::@check(@catch(app.start_capture_animation()) == crig::CAPTURE_NO_MODEL_FILE, "so is reading a video");
	test::@check(@catch(app.request_capture_reference()) == crig::CAPTURE_NO_MODEL_FILE, "and the reference picture");
	test::@check(!app.capture_job.running && !app.capture_job.reference_pending, "nothing was started");
}

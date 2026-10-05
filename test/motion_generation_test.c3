<*
 Text to motion (`app/generate.c3`): the request crig hands the llm pipeline, the
 progress it reads back, and the landing of the clip on the character.

 The model itself is not run here — it needs a GPU and eight gigabytes of
 weights. A job is set up the way `start_motion_generation` leaves it and fed
 what the pipeline feeds it (its printed lines, then its end), so what crig does
 around the model runs on its production path: the progress, the landing, the
 bind.
*>
module crig_tests::motion_generation;

import crig;
import rig;
import std::math;
import std::math::vector;
import std::math::matrix;
import crig_tests::shared_app;
import crig_tests::trust_fixes;
import std::collections::object;
import std::encoding::json;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import llm::pipeline;

const String GENERATION_DIR = "build/test-generation";

fn void a_clip_name_is_the_prompts_first_words() @test
{
	String brief = crig::motion_clip_name(mem, "  a person waves  ");
	defer brief.free(mem);
	test::@check(brief == "A person waves", "named '%s'", brief);

	String cut = crig::motion_clip_name(mem, "a person walks forward, stops, looks over the left shoulder and sits down");
	defer cut.free(mem);
	test::@check(cut == "A person walks forward", "cut at the first clause: '%s'", cut);

	String worded = crig::motion_clip_name(mem, "a person walks forward and then turns around to look over the left shoulder");
	defer worded.free(mem);
	test::@check(worded == "A person walks forward and then turns", "cut at a word: '%s'", worded);
}

fn void a_file_stem_is_letters_and_dashes() @test
{
	String stem = crig::motion_file_stem(mem, "Walk / Wave!  Twice");
	defer stem.free(mem);
	test::@check(stem == "walk-wave-twice", "stem '%s'", stem);
	String empty = crig::motion_file_stem(mem, "!!!");
	defer empty.free(mem);
	test::@check(empty == "motion", "a name with no letters still names a file: '%s'", empty);
}

fn void the_runners_step_lines_are_read_and_nothing_else() @test
{
	uint step;
	uint steps;
	test::@check(crig::parse_motion_step("  step 40/100, 5.21s", &step, &steps), "a step line was not read");
	test::@check(step == 40 && steps == 100, "read %d/%d", step, steps);
	test::@check(!crig::parse_motion_step("=== Kimodo ===", &step, &steps), "a banner read as a step");
	test::@check(!crig::parse_motion_step("  step 3/0", &step, &steps), "a step of nothing read");
}

fn void the_job_file_carries_the_request_escaped() @test
{
	crig::MotionGenerator g = { .text_model = "/m/text.gguf", .model = "/m/motion.gguf" };
	crig::MotionRequest request = { .prompt = `a "quoted" wave`, .seed = 7 };
	String json = crig::motion_job_json(&g, &request, "Wave", "/out/wave.glb", 150);
	defer json.free(mem);
	test::@check(json.contains(`"prompt": "a \"quoted\" wave"`), "the prompt is not escaped: %s", json);
	test::@check(json.contains(`"frames": 150`) && json.contains(`"seed": 7`) && json.contains(`"steps": 100`),
		"frames, seed and default steps: %s", json);
	test::@check(!json.contains("tokenizer"), "an unset tokenizer was written: %s", json);
}

<*
 The motion model is a .gguf, or NVIDIA's release as downloaded: the folder or
 its .safetensors under any name. The plugin carries the motion statistics, so
 the weights are all Settings looks for.
*>
fn void a_release_folder_is_a_motion_model() @test
{
	String folder = GENERATION_DIR +++ "/Kimodo-SOMA-RP-v1.1";
	(void)path::rmtree((Path)folder);
	(void)path::mkdir((Path)folder, recursive: true);
	test::@check(crig::motion_checkpoint_gap(folder) == string::tformat("%s/model.safetensors", folder),
		"an empty folder lacks '%s'", crig::motion_checkpoint_gap(folder));
	(void)file::save(string::tformat("%s/model.safetensors", folder), "x");
	test::@check(crig::motion_checkpoint_gap(folder) == "", "a folder with its weights lacks '%s'", crig::motion_checkpoint_gap(folder));
	test::@check(crig::motion_checkpoint_gap(string::tformat("%s/", folder)) == "", "a trailing slash lacks '%s'", crig::motion_checkpoint_gap(string::tformat("%s/", folder)));
	String renamed = string::tformat("%s/kimodo_soma.safetensors", folder);
	(void)file::save(renamed, "x");
	(void)file::delete(string::tformat("%s/model.safetensors", folder));
	test::@check(crig::motion_checkpoint_gap(renamed) == "", "renamed weights on their own lack '%s'", crig::motion_checkpoint_gap(renamed));
	test::@check(crig::motion_checkpoint_gap("/nowhere/kimodo.gguf") == "/nowhere/kimodo.gguf", "a missing .gguf passed");
	test::@check(crig::motion_checkpoint_gap("/nowhere/Kimodo/model.safetensors") == "/nowhere/Kimodo/model.safetensors",
		"missing weights passed");
}

fn void the_generator_survives_a_restart() @test
{
	String directory = GENERATION_DIR +++ "/config";
	(void)path::mkdir((Path)directory, recursive: true);
	env::set_var(crig::CONFIG_DIR_VAR, directory);
	defer env::set_var(crig::CONFIG_DIR_VAR, "");
	(void)file::save(string::tformat("%s/config.json", directory),
		`{"motion_generator":{"runner":"/r/llm-runner","text_model":"/m/t.gguf","model":"/m/k.gguf","tokenizer":7}}`);

	{
		crig::CrigConfig config = crig::load_config();
		defer config.free();
		crig::MotionGenerator* g = &config.motion_generator;
		test::@check(g.text_model == "/m/t.gguf" && g.model == "/m/k.gguf",
			"the paths were not read: %s %s", g.text_model, g.model);
		test::@check(g.tokenizer.len == 0, "a number was taken as a tokenizer path");
		test::@check(config.set_motion_path("output", " /o/clips "), "output is not a generator path");
		test::@check(config.set_motion_path("text_model", ""), "text_model is not a generator path");
		test::@check(!config.set_motion_path("runner", "/x"), "the runner is built in, not a setting");
	}
	crig::CrigConfig back = crig::load_config();
	defer back.free();
	test::@check(back.motion_generator.model == "/m/k.gguf", "the generator did not survive a save");
	test::@check(back.motion_generator.output == "/o/clips", "a set path was not saved: '%s'", back.motion_generator.output);
	test::@check(back.motion_generator.text_model.len == 0, "an emptied path came back: '%s'", back.motion_generator.text_model);
}

fn void generating_without_a_generator_is_refused() @test
{
	crig::AppState app = shared_app::open_cube();
	defer app.free();
	if (catch err = app.start_motion_generation({ .prompt = "a person waves" }))
	{
		test::@check(err == crig::MOTION_NO_GENERATOR, "refused with %s", err);
		return;
	}
	test::@check(false, "a job started with no generator configured");
}

fn crig::AppState generating_app(String name)
{
	String directory = string::tformat("%s/%s", GENERATION_DIR, name);
	(void)path::rmtree((Path)directory);
	crig::AppState app = shared_app::open();
	crig::MotionGenerator* g = &app.config.motion_generator;
	g.text_model = "/m/text.gguf".copy(mem);
	g.model = "/m/motion.gguf".copy(mem);
	g.output = string::format(mem, "%s/out", directory);
	return app;
}

// The pipeline needs a GPU and the weights; a headless AppState has neither
// and says so rather than starting.
fn void generating_with_no_gpu_is_refused() @test
{
	crig::AppState app = generating_app("no-gpu");
	defer app.free();
	if (catch err = app.start_motion_generation({ .prompt = "a person waves" }))
	{
		test::@check(err == crig::MOTION_NO_GPU, "refused with %s", err);
		test::@check(!app.motion_job.running, "a refused job reads as running");
		return;
	}
	test::@check(false, "a job started with no renderer");
}

<*
 A job as `start_motion_generation` leaves it, without the pipeline: what it
 asked for and where the .glb goes. The pipeline's own part - its lines and
 its end - is then fed to the job the way `tick_motion_job` feeds it.
*>
fn void pretend_job(crig::AppState* app, String prompt, String glb)
{
	app.motion_job.clear();
	app.motion_job.name = crig::motion_clip_name(mem, prompt);
	app.motion_job.prompt = prompt.copy(mem);
	app.motion_job.glb = glb.copy(mem);
	app.motion_job.steps = 100;
	app.motion_job.running = true;
}

fn void the_pipelines_lines_move_the_progress() @test
{
	crig::MotionJob job;
	defer job.clear();
	crig::motion_line(&job, "=== Kimodo ===");
	test::@check(job.step == 0 && job.last() == "=== Kimodo ===", "a banner moved the progress");
	crig::motion_line(&job, "  step 40/100, 5.21s");
	test::@check(job.step == 40 && job.steps == 100, "read %d/%d", job.step, job.steps);
	test::@check(job.last() == "step 40/100, 5.21s", "the last line is '%s'", job.last());
}

fn void a_generated_clip_lands_bound_in_a_generated_library() @test
{
	crig::AppState app = generating_app("lands");
	defer app.free();
	sz bound = app.doc.animations.len();

	String directory = app.motion_output_directory();
	defer directory.free(mem);
	(void)path::mkdir((Path)directory, recursive: true);
	String glb = string::format(mem, "%s/a-dog-sits.glb", directory);
	defer glb.free(mem);
	char[] bytes = file::load(mem, "assets/animations/quadruped.glb")!!;
	defer alloc::free(mem, bytes);
	(void)file::save(glb, bytes);

	pretend_job(&app, "a dog sits", glb);
	test::@check(app.ticking(), "a running job does not keep frames coming");
	crig::motion_line(&app.motion_job, "  step 100/100, 3.0s");
	app.finish_motion_job(true);

	test::@check(!app.motion_job.running, "the job never finished");
	test::@check(!app.motion_job.failed, "the job failed: %s", app.motion_job.last());
	test::@check(app.doc.animations.len() == bound + 1, "the clip was not bound");
	crig::AnimRef landed;
	test::@check(app.take_generated_clip(&landed) && landed.valid(), "no clip handed to the interface");
	test::@check(!app.take_generated_clip(&landed), "the clip was handed over twice");

	bool listed = false;
	foreach (library : app.config.libraries.array_view())
	{
		if (library.name == crig::GENERATED_LIBRARY_NAME && library.path.ends_with("lands/out")) listed = true;
	}
	test::@check(listed, "the output folder was not made a library");

	String status = crig::generation_status_json(&app);
	defer status.free(mem);
	test::@check(status.contains(`"state":"done"`) && status.contains(`"clip":`), "status: %s", status);
}

fn void a_failed_generation_says_why_and_binds_nothing() @test
{
	crig::AppState app = generating_app("fails");
	defer app.free();
	sz bound = app.doc.animations.len();

	pretend_job(&app, "a person waves", GENERATION_DIR +++ "/fails/out/never.glb");
	if (catch err = app.start_motion_generation({ .prompt = "a second one" }))
	{
		test::@check(err == crig::MOTION_BUSY, "a second job was refused with %s", err);
	}
	crig::motion_line(&app.motion_job, "error: no such model");
	app.finish_motion_job(false);

	test::@check(app.motion_job.failed, "a pipeline that failed read as a success");
	test::@check(app.motion_job.last() == "error: no such model", "the reason is '%s'", app.motion_job.last());
	test::@check(app.doc.animations.len() == bound, "a failed job bound something");
	String status = crig::generation_status_json(&app);
	defer status.free(mem);
	test::@check(status.contains(`"state":"failed"`) && status.contains("no such model"), "status: %s", status);
}

<*
 The pipeline travels inside the binary: extracting it writes the Kimodo plugin
 and the kernels it dispatches, and a second extraction finds them unchanged.
*>
fn void the_built_in_pipeline_extracts_its_plugin() @test
{
	String directory = GENERATION_DIR +++ "/llm";
	(void)path::rmtree((Path)directory);
	test::@check(llm::pipeline::bundled("kimodo"), "the library does not carry kimodo");
	test::@check(@ok(llm::pipeline::extract(directory)), "the plugin files could not be written");
	foreach (name : (String[]){ "kimodo/main.js", "lib/llm.js", "lib/gpu.js", "lib/kernels/common.shady" })
	{
		test::@check(file::exists(string::tformat("%s/%s", directory, name)), "%s was not extracted", name);
	}
	test::@check(@ok(llm::pipeline::extract(directory)), "a second extraction failed");
}

<*
 A guide clip on the humanoid rig: keyed at rest with the spine keyed too (a
 whole-body pose), with only the right arm swung up at 1 s (a hand key), and
 once more past the end of a 5-second job.
*>
fn crig::AnimRef author_guide(crig::AppState* app)
{
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, 3);
	foreach (usz i, t : (float[]){ 0.0f, 1.0f, 9.0f })
	{
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, i == 0 ? 2 : 1);
		dots[0] = { .joint_name = "shoulder_R".copy(mem), .axis = { 0, 0, 1 }, .angle = i == 1 ? -1.3f : 0.0f };
		if (i == 0) dots[1] = { .joint_name = "spine".copy(mem), .axis = { 1, 0, 0 } };
		frames[i] = { .time = t, .dots = dots };
	}
	return app.author_clip({ .name = "Guide".copy(mem), .duration = 9.0f, .keyframes = frames, .owned = true });
}

fn void a_kimodo_joint_names_its_limb() @test
{
	test::@check(crig::kimodo_limb("LeftForeArm") == "LeftHand", "the left forearm");
	test::@check(crig::kimodo_limb("RightHandMiddleEnd") == "RightHand", "a right finger end");
	test::@check(crig::kimodo_limb("RightShoulder") == "RightHand", "the right shoulder");
	test::@check(crig::kimodo_limb("LeftToeBase") == "LeftFoot", "the left toes");
	test::@check(crig::kimodo_limb("RightShin") == "RightFoot", "the right shin");
	foreach (whole : (String[]){ "Hips", "Spine1", "Chest", "Neck1", "Head", "LeftEye", "RightEye", "Jaw" })
	{
		test::@check(crig::kimodo_limb(whole) == "", "%s is not a limb", whole);
	}
}

<*
 A guide clip turns into the pipeline's poses: each keyed instant inside the
 length as a frame, keyed past it left out, and every joint sent under the
 Kimodo joint it answers to — the rest pose once, then where each stands.
*>
fn void a_guide_clips_keys_become_the_pipelines_poses() @test
{
	String source = GENERATION_DIR +++ "/guide-humanoid.glb";
	(void)path::mkdir((Path)GENERATION_DIR, recursive: true);
	trust_fixes::copy_humanoid(source);
	defer trust_fixes::remove_with_sidecar(source);
	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	test::@check(author_guide(&app).valid(), "the guide clip was not authored");

	String plugins = GENERATION_DIR +++ "/guide-llm";
	test::@check(@ok(llm::pipeline::extract(plugins)), "the pipeline's files were not written");
	String skeleton = string::tformat("%s/%s", plugins, crig::MOTION_GUIDE_SKELETON);
	test::@check(file::exists(skeleton), "the library carries no rest skeleton at %s", skeleton);

	usz keyed;
	usz dropped;
	if (catch err = app.motion_guide_json("Nothing", 150, skeleton, &keyed, &dropped))
	{
		test::@check(err == crig::MOTION_GUIDE_MISSING, "an unknown guide was refused with %s", err);
	}
	else
	{
		test::@check(false, "a guide that is not bound was accepted");
	}

	usz partial;
	String? made = app.motion_guide_json("Guide", 150, skeleton, &keyed, &dropped, &partial);
	if (catch err = made) { test::@check(false, "the guide was refused: %s", err); return; }
	String poses = made;
	defer poses.free(mem);
	test::@check(keyed == 2 && dropped == 1 && partial == 1, "%d keyed, %d left out, %d partial", keyed, dropped, partial);
	test::@check(poses.contains(`"frame": 0,`) && poses.contains(`"frame": 30,`), "the frames: %s", poses);
	test::@check(!poses.contains(`"frame": 270`), "a key past the end was sent");

	Object* parsed = json::parse(mem, poses)!!;
	defer parsed.free();
	Object* rest = parsed.get("rest")!!;
	foreach (name : (String[]){ "Hips", "LeftLeg", "RightLeg", "RightArm", "RightHand", "LeftFoot" })
	{
		test::@check(rest.has_key(name), "the rest pose has no %s", name);
	}
	test::@check(!rest.has_key("hips") && !rest.has_key("Jaw"), "a name Kimodo does not use was sent");

	Object* keys = parsed.get("keys")!!;
	// The spine keyed at 0 s holds the whole body; the arm alone at 1 s holds the
	// right hand only.
	test::@check(!keys.get_at(0).has_key("effectors"), "the whole-body key was sent as a partial one: %s", poses);
	Object* held = keys.get_at(1).get("effectors")!!;
	test::@check(held.get_len() == 1 && held.get_string_at(0)!! == "RightHand", "the arm key holds: %s", poses);
	Vec3 at_rest = json_point(rest.get("RightHand")!!);
	Vec3 first = json_point(keys.get_at(0).get("joints")!!.get("RightHand")!!);
	Vec3 raised = json_point(keys.get_at(1).get("joints")!!.get("RightHand")!!);
	test::@check((first - at_rest).length() < 0.001f, "the rest key moved the hand %s", first - at_rest);
	test::@check((raised - at_rest).length() > 0.2f, "the swung arm did not move the hand: %s", raised - at_rest);

	String json = crig::motion_job_json(&app.config.motion_generator, &&(crig::MotionRequest){ .prompt = "a wave" },
		"Wave", "/out/wave.glb", 150, poses);
	defer json.free(mem);
	test::@check(json.contains(`"poses": {`), "the job was not given the poses: %s", json);
}

<*
 The guide is read in the rig's own facing: turned a quarter or half round about
 Y, the humanoid sends the same rest pose (about its hips) as it does facing +Z.
*>
fn void a_turned_rig_sends_its_guide_facing_forward() @test
{
	String source = GENERATION_DIR +++ "/turned-humanoid.glb";
	(void)path::mkdir((Path)GENERATION_DIR, recursive: true);
	trust_fixes::copy_humanoid(source);
	defer trust_fixes::remove_with_sidecar(source);
	rig::TriMesh mesh = rig::load_gltf(mem, source)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, source);
	defer app.free();
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
	test::@check(author_guide(&app).valid(), "the guide clip was not authored");
	String plugins = GENERATION_DIR +++ "/turned-llm";
	test::@check(@ok(llm::pipeline::extract(plugins)), "the pipeline's files were not written");
	String skeleton = string::tformat("%s/%s", plugins, crig::MOTION_GUIDE_SKELETON);

	usz keyed;
	usz dropped;
	String facing = app.motion_guide_json("Guide", 150, skeleton, &keyed, &dropped)!!;
	defer facing.free(mem);
	Object* parsed_a = json::parse(mem, facing)!!;
	defer parsed_a.free();
	Object* a = parsed_a.get("rest")!!;
	Vec3 hips_a = json_point(a.get("Hips")!!);
	// A quarter turn, then a half: facing +X, then −Z.
	for (int quarter = 1; quarter <= 2; quarter++)
	{
		test::@check(app.rotate_skeleton(1, (float)math::PI / 2.0f) > 0, "the skeleton did not turn");
		String turned = app.motion_guide_json("Guide", 150, skeleton, &keyed, &dropped)!!;
		defer turned.free(mem);
		Object* parsed_b = json::parse(mem, turned)!!;
		defer parsed_b.free();
		Object* b = parsed_b.get("rest")!!;
		Vec3 hips_b = json_point(b.get("Hips")!!);
		foreach (name : (String[]){ "LeftHand", "RightHand", "LeftFoot", "RightFoot", "Head" })
		{
			Vec3 from_a = json_point(a.get(name)!!) - hips_a;
			Vec3 from_b = json_point(b.get(name)!!) - hips_b;
			test::@check((from_a - from_b).length() < 0.001f * (from_a.length() + 1.0f),
				"%s sits at %s facing +Z but %s turned %d quarter(s)", name, from_a, from_b, quarter);
		}
	}
}

fn Vec3 json_point(Object* array)
{
	return { (float)array.get_float_at(0)!!, (float)array.get_float_at(1)!!, (float)array.get_float_at(2)!! };
}

// ---------------------------------------------------------------------------
// Clips marked as written for their rig (`PACK_KEY_FACING` "as-is").

fn void copy_file(String from, String to) @local
{
	char[] bytes = file::load(mem, from)!!;
	defer alloc::free(mem, bytes);
	(void)file::save(to, bytes);
}

<*
 The quadruped's own Idle (assets/animations/quadruped.glb), on the same
 sidecar rig: the file is not turned round either. It faces −X and names its sides along Z, and its hind legs a
 hand's width out of line once read as a figure facing −Z (`faces_back`) — the
 clip came out turned half round on the unturned rig, front hooves in the air.
*>
fn void the_quadrupeds_idle_lands_on_its_rig_as_written() @test
{
	String directory = GENERATION_DIR +++ "/facing-x-idle";
	(void)path::rmtree((Path)directory);
	(void)path::mkdir((Path)directory, recursive: true);
	String model = string::tformat("%s/quadruped.glb", directory);
	copy_file("assets/animations/quadruped.glb", model);
	copy_file("test/fixtures/quadruped_facing_x.rigsmith.json", string::tformat("%s/quadruped.rigsmith.json", directory));
	rig::TriMesh mesh = rig::load_gltf(mem, model)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, model);
	defer app.free();
	app.load_session();
	test::@check(app.doc.dots.len() == 19, "the quadruped's rig did not load: %d dots", app.doc.dots.len());

	int pack = app.pack_for_file(model);
	test::@check(pack >= 0, "the quadruped's own clips did not read");
	crig::AnimRef ref = app.clip_named_in(pack, "Idle");
	test::@check(ref.valid(), "the quadruped carries no Idle");
	app.ensure_clip_imported(ref);
	crig::AnimTemplate* clip = app.clip(ref);
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);

	// Joint positions from the file itself, relative to its pelvis.
	String[4] joints = { "head", "fore_hoof_R", "hind_hoof_L", "tail_tip" };
	Vec3[4][2] written = {
		{ { -0.661f, 0.2384f, 0.0024f }, { -0.4982f, -0.3808f, 0.1829f }, { -0.0254f, -0.3791f, -0.2511f }, { 0.2107f, 0.2425f, -0.0515f } },
		{ { -0.658f, 0.2432f, -0.0042f }, { -0.5163f, -0.3726f, 0.1851f }, { -0.0254f, -0.3791f, -0.2511f }, { 0.186f, 0.2487f, -0.0885f } },
	};
	foreach (usz k, float t : (float[2]){ 0.0f, 1.4f })
	{
		rig::Pose pose = clip.pose(mem, &view.skeleton, view.names, t);
		defer pose.free(mem);
		Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
		defer alloc::free(mem, palette);
		Vec3 pelvis;
		Vec3[4] at;
		foreach (usz j, name : view.names)
		{
			Vec3 p = view.skeleton.joints[j].transform(palette[j]);
			if (name == "pelvis") pelvis = p;
			foreach (usz i, wanted : joints) if (name == wanted) at[i] = p;
		}
		foreach (usz i, name : joints)
		{
			Vec3 offset = at[i] - pelvis;
			test::@check((offset - written[k][i]).length() < 2e-3f, "%s at %.1f s is %s from the pelvis, not %s",
				name, t, offset, written[k][i]);
		}
	}
}

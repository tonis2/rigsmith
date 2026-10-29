<*
 Video capture: an animation of the character out of a video of it, through
 llm-runner's `creature` plugin (DINOv3 and a rig fit), run in-process like
 Kimodo (`app/generate.c3`). The Capture pane's graph (`app/capture_graph.c3`)
 runs three steps, each of which can be done again on its own:

 1. **A joint finder** for this character: a training set drawn the way
    render_poses draws it (poses inside the rig's limits and frames of its
    clips, from the front and both sides), a few poses a frame so the window
    keeps repainting, then creature's `train` task on it, about half an hour
    on one GPU. Or a finder trained before, chosen as a file.
 2. **The reference picture**: render_studio's two cameras side by side, the
    front and the right side, from a pose the user picks (an idle's first
    frame stands best). A video model animates this picture.
 3. **The clip**: the video's frames taken out with ffmpeg (a process polled a
    frame at a time), then creature's animate task with the picture's layout
    (`studio`) and the finder; the clip lands on the character as Kimodo's do,
    one undo step.

 Everything goes in a folder beside the model, `<model>.capture/`: the
 training set (`renders/`), the finder (`finder.safetensors`), the picture
 (`studio/`), each clip's frames and the points found on them
 (`clips/<name>/frames/`, `clips/<name>/tracks.json`), the pane's graph
 (`graph.json`; a second Train or Reference node keeps its own under
 `<node>/`), and `capture.json`, which remembers a finder chosen from
 elsewhere. The model file itself is never written.

 One pipeline job runs at a time in the process, so a capture step and a text
 to motion job wait for each other.
*>
module crig;

import std::collections::object;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import std::os::process;
import std::core::string;
import std::math;
import gltf_edit;
import llm::pipeline;

faultdef CAPTURE_NO_MODEL_FILE, CAPTURE_NO_BACKBONE, CAPTURE_BUSY, CAPTURE_NO_GPU, CAPTURE_NO_SKELETON,
	CAPTURE_NO_FINDER, CAPTURE_NO_REFERENCE, CAPTURE_NO_VIDEO, CAPTURE_NO_FFMPEG, CAPTURE_NO_PLUGIN, CAPTURE_NOT_STARTED;

// The training set's size by default, and how many poses one frame draws.
const usz CAPTURE_DEFAULT_POSES = 1500;
const usz CAPTURE_CHUNK = 8;
// The finder's training as the Zidane finder that fits best was trained: the
// last block's features beside the 20th's.
const String CAPTURE_TRAIN_EXTRA = `"layers": [20]`;

enum CaptureStage
{
	IDLE,
	RENDERING,  // the training set, a chunk between frames
	TRAINING,   // creature's train task
	EXTRACTING, // ffmpeg taking the video's frames out
	ANIMATING,  // creature's animate task
}

<*
 The capture step running now, if any, and how the last one ended. Every
 String is owned; `engine` is on the heap because it must not move while it
 runs.
*>
struct CaptureJob
{
	bool running;
	CaptureStage stage;
	llm::pipeline::Job* engine;
	Process ffmpeg;
	bool ffmpeg_alive;
	uint step;
	uint steps;
	char[512] last_line;
	usz last_length;
	bool failed;
	// The training set: the next pose to draw, and how many.
	usz render_next;
	usz render_total;
	// The clip being made: its name, its frames' folder (the training set's,
	// while training), their rate and count.
	String name;
	String frames;
	float fps;
	usz frames_expected;
	uint polls;
	// The clip's finder and picture layout, for the animate task.
	String finder;
	String studio;
	// Asked for by the pane; drawn between frames, where the renderer is free:
	// its folder, its clip ("" = the rest pose) and moment, and how it went.
	bool reference_pending;
	bool reference_ok;
	String reference_studio;
	String reference_clip;
	float reference_time;
	// Bumped whenever a step ends, so the pane rebuilds its statuses.
	uint finished;
	// Set when a clip has landed, for the interface to select; taken once.
	AnimRef landed;
	bool landed_pending;
}

fn String CaptureJob.last(&self) => (String)self.last_line[:self.last_length];

fn void CaptureJob.set_last(&self, String line)
{
	usz n = line.len < self.last_line.len ? line.len : self.last_line.len;
	self.last_line[:n] = line[:n];
	self.last_length = n;
}

fn float CaptureJob.progress(&self) => self.steps == 0 ? 0.0f : (float)self.step / (float)self.steps;

fn void CaptureJob.close_engine(&self)
{
	if (!self.engine) return;
	self.engine.free();
	mem::free(self.engine);
	self.engine = null;
}

fn void CaptureJob.stop_ffmpeg(&self)
{
	if (!self.ffmpeg_alive) return;
	(void)self.ffmpeg.terminate();
	(void)self.ffmpeg.join();
	(void)self.ffmpeg.destroy();
	self.ffmpeg_alive = false;
}

fn void CaptureJob.clear(&self)
{
	self.close_engine();
	self.stop_ffmpeg();
	foreach (held : (String[]) { self.name, self.frames, self.finder, self.studio })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	self.name = self.frames = self.finder = self.studio = "";
	self.running = false;
	self.stage = IDLE;
	self.failed = false;
	self.step = self.steps = 0;
	self.last_length = 0;
}

fn void CaptureJob.free(&self)
{
	self.clear();
	foreach (held : (String[]) { self.reference_studio, self.reference_clip })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	self.reference_studio = self.reference_clip = "";
}

<*
 A line the pipeline printed: a step count moves the bar, and the last line is
 kept, which on a failure says why.
*>
fn void capture_line(void* context, String line)
{
	CaptureJob* job = context;
	if (line.trim().len == 0) return;
	uint step;
	uint steps;
	if (parse_motion_step(line, &step, &steps))
	{
		job.step = step;
		job.steps = steps;
	}
	job.set_last(line.trim());
}

// ---------------------------------------------------------------------------
// Where things go.

<*
 The capture folder of the character's model, `<model>.capture` beside it
 (the model's extension dropped), or "" for a model not read from a file.
 Temporary.
*>
fn String capture_folder_of(String model_path)
{
	if (model_path.len == 0) return "";
	usz start = 0;
	if (try slash = model_path.rindex_of_char('/')) start = (usz)slash + 1;
	usz end = model_path.len;
	if (try dot = model_path[start..].rindex_of_char('.')) end = start + (usz)dot;
	return string::tformat("%s.capture", model_path[:end]);
}

fn String AppState.capture_folder(&self) => capture_folder_of(self.source_path);

// One of the capture folder's paths, temporary.
fn String AppState.capture_path(&self, String below) => string::tformat("%s/%s", self.capture_folder(), below);

<*
 The finder this character's captures use: the one `capture.json` names, when
 it is still there, else the folder's own `finder.safetensors` once trained;
 "" when there is none. Temporary.
*>
fn String AppState.capture_finder(&self)
{
	String folder = self.capture_folder();
	if (folder.len == 0) return "";
	if (try char[] text = file::load_temp(self.capture_path("capture.json")))
	{
		if (try Object* parsed = json::parse(tmem, (String)text))
		{
			if (try String chosen = parsed.get_string("finder"))
			{
				if (chosen.len > 0 && file::exists(chosen)) return chosen.tcopy();
			}
		}
	}
	String own = self.capture_path("finder.safetensors");
	return file::exists(own) ? own : "";
}

<*
 Use the finder at `finder_path` for this character's captures from now on,
 remembered in `capture.json`.
*>
fn void? AppState.use_capture_finder(&self, String finder_path)
{
	String folder = self.capture_folder();
	if (folder.len == 0) return CAPTURE_NO_MODEL_FILE~;
	(void)path::mkdir(folder, true);
	DString out = dstring::new(tmem);
	out.append_string("{\n  \"finder\": ");
	gltf_edit::escape_json_string(&out, finder_path);
	out.append_string("\n}\n");
	file::save(self.capture_path("capture.json"), (char[])out.str_view())!;
}

<*
 What a finder file says of itself, for the pane: "49 points · 5.55 px held
 out", from the training report in its metadata; "" when it says nothing.
 Temporary.
*>
fn String finder_summary(String finder_path)
{
	if (finder_path.len == 0) return "";
	char[]? bytes = file::load_temp(finder_path);
	if (catch bytes) return "";
	if (bytes.len < 8) return "";
	ulong header = 0;
	for (usz i = 0; i < 8; i++) header |= (ulong)bytes[i] << (8 * i);
	if (header == 0 || 8 + header > bytes.len) return "";
	Object*? top = json::parse(tmem, (String)bytes[8:(usz)header]);
	if (catch top) return "";
	Object*? meta = top.get("__metadata__");
	if (catch meta) return "";
	String? finder = meta.get_string("finder");
	if (catch finder) return "";
	Object*? info = json::parse(tmem, finder);
	if (catch info) return "";
	DString out = dstring::new(tmem);
	if (try Object* joints = info.get("joints")) out.appendf("%d points", joints.get_len());
	if (try Object* report = info.get("report"))
	{
		if (try Object* held = report.get("held_out_px"))
		{
			if (try double median = held.get_float("median")) out.appendf("%s%.2f px held out", out.len() > 0 ? " · " : "", median);
		}
	}
	return out.str_view();
}

<*
 Where `program` is on the PATH, or "" when it is not. Temporary.
*>
fn String find_program(String program)
{
	String? paths = env::get_var(tmem, "PATH");
	if (catch paths) return "";
	foreach (dir : paths.tsplit(":"))
	{
		if (dir.len == 0) continue;
		String candidate = string::tformat("%s/%s", dir, program);
		if (file::exists(candidate)) return candidate;
	}
	return "";
}

<*
 The video's frame rate and frame count, as ffprobe reports them ("24/1,107",
 "30000/1001,N/A"): `fps` 0 when it cannot say.
*>
fn void parse_probe(String text, float* fps, usz* frames)
{
	*fps = 0;
	*frames = 0;
	String line = text.trim();
	if (try nl = line.index_of_char('\n')) line = line[:(usz)nl].trim();
	String[] parts = line.tsplit(",");
	if (parts.len == 0) return;
	String[] ratio = parts[0].trim().tsplit("/");
	double? top = ratio[0].to_double();
	if (catch top) return;
	double bottom = 1;
	if (ratio.len > 1)
	{
		double? given = ratio[1].to_double();
		if (catch given) return;
		bottom = given;
	}
	if (bottom > 0 && top > 0) *fps = (float)(top / bottom);
	if (parts.len > 1)
	{
		if (try count = parts[1].trim().to_uint()) *frames = count;
	}
}

<*
 The first pose of the training set not yet drawn: the training set is drawn
 CAPTURE_CHUNK poses a call, each call writing poses_<first>.json, so a set
 stopped part way carries on from its first missing chunk.
*>
fn usz first_missing_chunk(String renders, usz total)
{
	for (usz first = 0; first < total; first += CAPTURE_CHUNK)
	{
		if (!file::exists(string::tformat("%s/poses_%06d.json", renders, first))) return first;
	}
	return total;
}

// The pipeline's job is one per process: text to motion or a capture step.
fn bool AppState.capture_engine_busy(&self) => self.motion_job.running || self.capture_job.running;

fn void? AppState.capture_ready(&self, bool needs_backbone = true)
{
	if (self.source_path.len == 0) return CAPTURE_NO_MODEL_FILE~;
	if (self.doc.dots.len() == 0 || !self.has_mesh()) return CAPTURE_NO_SKELETON~;
	if (self.capture_engine_busy()) return CAPTURE_BUSY~;
	if (needs_backbone && self.config.motion_generator.creature_model.len == 0) return CAPTURE_NO_BACKBONE~;
	if (needs_backbone && self.llm_plugin_problem("creature").len > 0) return CAPTURE_NO_PLUGIN~;
	if (needs_backbone && !self.motion_gpu) return CAPTURE_NO_GPU~;
}

fn String capture_fault_text(fault err)
{
	switch (err)
	{
		case CAPTURE_NO_MODEL_FILE: return "the model has no file yet — save it as a .glb first, the capture folder goes beside it";
		case CAPTURE_NO_BACKBONE: return "choose the DINOv3 backbone (SAM 3D Body's model.ckpt) in File › Settings › AI";
		case CAPTURE_BUSY: return "another pipeline job is running";
		case CAPTURE_NO_GPU: return "there is no GPU to run it on";
		case CAPTURE_NO_SKELETON: return "the model needs a skinned skeleton first";
		case CAPTURE_NO_FINDER: return "train a joint finder, or choose one, first";
		case CAPTURE_NO_REFERENCE: return "make the reference picture first: the video is read by its layout";
		case CAPTURE_NO_VIDEO: return "choose a video, or a folder of its frames";
		case CAPTURE_NO_FFMPEG: return "ffmpeg is not on the PATH — give a folder of the video's frames instead";
		case CAPTURE_CLIP_TAKEN: return "the character already has a clip by that name — give this one another";
		case CAPTURE_BAD_POSES: return "Poses is a whole number from 50 to 20000";
		case CAPTURE_NO_PLUGIN: return "the creature plugin is not in the plugins folder — link it in File › Settings › AI › Plugins";
		default: return "the pipeline would not start";
	}
}

// ---------------------------------------------------------------------------
// 1. The joint finder.

<*
 Start drawing the training set (`poses` poses into `renders`, from where a
 stopped set left off) and then training the finder at `finder` on it.
*>
fn void? AppState.start_capture_training(&self, usz poses, String renders, String finder)
{
	self.capture_ready()!;
	(void)path::mkdir(renders, true);
	if (!path::is_dir((Path)renders)) return CAPTURE_NOT_STARTED~;
	CaptureJob* job = &self.capture_job;
	job.clear();
	job.frames = renders.copy(mem);
	job.finder = finder.copy(mem);
	job.running = true;
	job.stage = RENDERING;
	job.render_total = math::max(poses, CAPTURE_CHUNK);
	job.render_next = first_missing_chunk(renders, job.render_total);
	job.step = (uint)job.render_next;
	job.steps = (uint)job.render_total;
	job.set_last(job.render_next > 0 ? "carrying on with the training set" : "drawing the training set");
	self.@notice("Drawing %d poses of the character to train its joint finder on…", job.render_total);
}

<*
 One chunk of the training set, between frames: the poses render_poses draws
 for the same seed and index, from the front and both sides, a share of them
 frames of the clips that play on the rig, with the points of the mesh that
 show which way the head and the feet turn.
*>
fn void AppState.draw_capture_chunk(&self)
{
	CaptureJob* job = &self.capture_job;
	PoseShoot shoot = pose_shoot_defaults();
	shoot.out = job.frames;
	shoot.first = job.render_next;
	shoot.count = math::min(CAPTURE_CHUNK, job.render_total - job.render_next);
	shoot.cameras[0] = { .name = "front", .yaw = 0, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.cameras[1] = { .name = "left", .yaw = 90, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.cameras[2] = { .name = "right", .yaw = -90, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.camera_count = 3;
	shoot.all_clips = true;
	shoot.landmarks = true;
	DString detail = dstring::new(mem);
	defer detail.free();
	String? answer = self.render_pose_set(&shoot, &detail);
	if (catch answer)
	{
		self.fail_capture(detail.len() > 0 ? detail.str_view() : "the training set could not be drawn");
		return;
	}
	alloc::free(mem, answer.ptr);
	job.render_next += shoot.count;
	job.step = (uint)job.render_next;
	if (job.render_next < job.render_total) return;
	self.start_capture_engine(TRAINING, capture_train_json(self.config.motion_generator.creature_model, job.frames, job.finder));
}

// The train task's settings, as JSON. Owned.
fn String capture_train_json(String backbone, String renders, String finder)
{
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string("{\n  \"task\": \"train\",\n  \"model\": ");
	gltf_edit::escape_json_string(&out, backbone);
	out.append_string(",\n  \"renders\": ");
	gltf_edit::escape_json_string(&out, renders);
	out.append_string(",\n  \"out\": ");
	gltf_edit::escape_json_string(&out, finder);
	out.appendf(",\n  %s\n}\n", CAPTURE_TRAIN_EXTRA);
	return out.copy_str(mem);
}

// ---------------------------------------------------------------------------
// 2. The reference picture.

<*
 Draw the reference picture into `studio` next time the renderer is free:
 render_studio's two cameras on `clip` ("pack/clip"; "" or CAPTURE_REST is the
 rest pose) at `time` seconds.
*>
fn void? AppState.request_capture_reference(&self, String studio, String clip, float time)
{
	if (self.source_path.len == 0) return CAPTURE_NO_MODEL_FILE~;
	if (self.doc.dots.len() == 0 || !self.has_mesh()) return CAPTURE_NO_SKELETON~;
	CaptureJob* job = &self.capture_job;
	replace_owned(&job.reference_studio, studio);
	replace_owned(&job.reference_clip, clip == CAPTURE_REST ? "" : clip);
	job.reference_time = math::max(time, 0.0f);
	job.reference_ok = false;
	job.reference_pending = true;
}

fn void AppState.draw_capture_reference(&self)
{
	CaptureJob* job = &self.capture_job;
	job.reference_pending = false;
	String studio = job.reference_studio;
	(void)path::mkdir(studio, true);
	StudioAsk ask = studio_ask_defaults(studio);
	ask.clip = job.reference_clip;
	ask.time = job.reference_time;
	DString detail = dstring::new(mem);
	defer detail.free();
	String? answer = self.render_studio_picture(&ask, &detail);
	job.finished++;
	if (catch answer)
	{
		self.@notice("The reference picture could not be drawn: %s", detail.str_view());
		return;
	}
	alloc::free(mem, answer.ptr);
	job.reference_ok = true;
	self.@notice("Reference picture written to %s · give it to the video model with the prompt", studio);
}

// The prompt render_studio wrote, `action` filled in. Temporary.
fn String capture_prompt(String action)
{
	action = action.trim();
	if (action.len == 0) return STUDIO_PROMPT;
	if (action[^1] == '.') action = action[:action.len - 1];
	return STUDIO_PROMPT.treplace("<describe the movement here>", action);
}

// ---------------------------------------------------------------------------
// 3. The clip.

<*
 Start turning `video` into the clip `name` ("" = the video's file name) with
 `finder` and the picture in `studio`: its frames taken out with ffmpeg (or a
 folder of frames used as it is), then the animate task.
*>
fn void? AppState.start_capture_animation(&self, String finder, String studio, String video, String name)
{
	self.capture_ready()!;
	if (finder.len == 0 || !file::exists(finder)) return CAPTURE_NO_FINDER~;
	if (studio.len == 0 || !file::exists(string::tformat("%s/studio.json", studio))) return CAPTURE_NO_REFERENCE~;
	video = video.trim();
	if (video.len == 0 || !path::exists((Path)video)) return CAPTURE_NO_VIDEO~;
	bool folder = path::is_dir((Path)video);
	if (!folder && find_program("ffmpeg").len == 0) return CAPTURE_NO_FFMPEG~;

	name = name.trim();
	if (name.len == 0) name = capture_clip_name(video);
	CaptureJob* job = &self.capture_job;
	job.clear();
	job.name = name.copy(mem);
	job.finder = finder.copy(mem);
	job.studio = studio.copy(mem);
	job.fps = 24;
	if (folder)
	{
		job.frames = video.copy(mem);
		job.running = true;
		self.start_capture_engine(ANIMATING, self.capture_animate_json());
		return;
	}
	// A folder of its own for this clip's frames, emptied first: a shorter take
	// must not keep the last one's tail.
	String frames = self.capture_path(string::tformat("clips/%s/frames", name));
	if (path::is_dir((Path)frames)) (void)path::rmtree((Path)frames);
	(void)path::mkdir(frames, true);
	if (!path::is_dir((Path)frames)) return CAPTURE_NOT_STARTED~;
	job.frames = frames.copy(mem);

	char[256] probe;
	if (try String said = process::run_capture_stdout(probe[..],
		{ "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=r_frame_rate,nb_frames", "-of", "csv=p=0", video }))
	{
		float fps;
		usz count;
		parse_probe(said, &fps, &count);
		if (fps > 0) job.fps = fps;
		job.frames_expected = count;
	}
	Process? started = process::spawn({ "ffmpeg", "-nostdin", "-v", "error", "-y", "-i", video, string::tformat("%s/f_%%05d.png", frames) });
	if (catch started)
	{
		job.failed = true;
		job.set_last("ffmpeg would not start");
		return CAPTURE_NOT_STARTED~;
	}
	job.ffmpeg = started;
	job.ffmpeg_alive = true;
	job.running = true;
	job.stage = EXTRACTING;
	job.step = 0;
	job.steps = (uint)job.frames_expected;
	job.set_last("taking the video's frames out");
	self.@notice("Reading \"%s\"'s frames…", name);
}

// A clip's name out of a video's file name: "zidane_wave.mp4" is "zidane_wave". Temporary.
fn String capture_clip_name(String video)
{
	String base = video;
	while (base.len > 1 && base[^1] == '/') base = base[:base.len - 1];
	if (try slash = base.rindex_of_char('/')) base = base[(usz)slash + 1..];
	if (try dot = base.rindex_of_char('.')) if (dot > 0) base = base[:(usz)dot];
	return base.len > 0 ? base.tcopy() : "Captured";
}

// The animate task's settings, as JSON: the rig as it is now, limits and all,
// asking for the tracks too so a clip can be fitted again without the GPU. Owned.
fn String AppState.capture_animate_json(&self)
{
	CaptureJob* job = &self.capture_job;
	String rig = skeleton_json(self);
	defer alloc::free(mem, rig.ptr);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string("{\n  \"model\": ");
	gltf_edit::escape_json_string(&out, self.config.motion_generator.creature_model);
	out.append_string(",\n  \"rig\": ");
	out.append_string(rig);
	out.append_string(",\n  \"finder\": ");
	gltf_edit::escape_json_string(&out, job.finder);
	out.append_string(",\n  \"studio\": ");
	gltf_edit::escape_json_string(&out, string::tformat("%s/studio.json", job.studio));
	out.append_string(",\n  \"frames\": ");
	gltf_edit::escape_json_string(&out, job.frames);
	out.append_string(",\n  \"name\": ");
	gltf_edit::escape_json_string(&out, job.name);
	out.appendf(",\n  \"fps\": %.4f,\n  \"outputs\": [\"glb\", \"tracks\"]\n}\n", job.fps);
	return out.copy_str(mem);
}

// ---------------------------------------------------------------------------
// Running.

<*
 Start the pipeline on `json` (owned, freed here) for `stage`.
*>
fn void AppState.start_capture_engine(&self, CaptureStage stage, String json)
{
	defer alloc::free(mem, json.ptr);
	CaptureJob* job = &self.capture_job;
	String plugins = self.llm_plugins_directory();
	defer alloc::free(mem, plugins.ptr);
	llm::pipeline::Job* engine = mem::new(llm::pipeline::Job);
	job.engine = engine;
	job.stage = stage;
	job.step = job.steps = 0;
	job.running = true;
	if (catch engine.start(self.motion_gpu, "creature", json, plugins, &capture_line, job))
	{
		self.fail_capture(engine.error().len > 0 ? engine.error() : "the pipeline would not start");
		return;
	}
	job.set_last(stage == TRAINING ? "loading DINOv3 to train the finder" : "loading DINOv3 to read the video");
}

fn void AppState.fail_capture(&self, String why)
{
	CaptureJob* job = &self.capture_job;
	job.set_last(why);
	job.close_engine();
	job.stop_ffmpeg();
	job.running = false;
	job.failed = true;
	job.stage = IDLE;
	job.finished++;
	self.@notice("Video capture stopped: %s", why);
}

<*
 Between frames, where the renderer is free: a chunk of the training set, or
 the reference picture.
*>
fn void AppState.service_capture(&self)
{
	CaptureJob* job = &self.capture_job;
	if (job.reference_pending) self.draw_capture_reference();
	if (job.running && job.stage == RENDERING) self.draw_capture_chunk();
}

<*
 A frame of the running step: the pipeline pumped or ffmpeg polled, and what
 follows once it ends. Driven from `AppRoot.update`.
*>
fn void AppState.tick_capture(&self)
{
	CaptureJob* job = &self.capture_job;
	self.advance_capture_graph();
	if (!job.running) return;
	switch (job.stage)
	{
		case EXTRACTING:
			if (job.polls++ % 15 == 0)
			{
				if (try PathList listed = path::ls(tmem, (Path)job.frames, no_dirs: true, mask: "*.png")) job.step = (uint)listed.len();
			}
			bool? alive = job.ffmpeg.is_running();
			if (try alive && alive) return;
			CInt? code = job.ffmpeg.join();
			(void)job.ffmpeg.destroy();
			job.ffmpeg_alive = false;
			if (catch code)
			{
				self.fail_capture("ffmpeg stopped without saying why");
				return;
			}
			if (code != 0)
			{
				self.fail_capture(string::tformat("ffmpeg could not read the video (exit %d)", code));
				return;
			}
			self.start_capture_engine(ANIMATING, self.capture_animate_json());
		case TRAINING:
		case ANIMATING:
			if (!job.engine) return;
			if (job.engine.pump()) return;
			bool ok = job.engine.state == DONE;
			if (!ok)
			{
				self.fail_capture(job.engine.error().len > 0 ? job.engine.error() : job.last());
				return;
			}
			if (job.stage == TRAINING)
			{
				job.close_engine();
				job.running = false;
				job.stage = IDLE;
				job.finished++;
				// The folder's own finder is the one the agent's tools use from now on.
				if (job.finder == self.capture_path("finder.safetensors")) (void)self.use_capture_finder(job.finder);
				self.@notice("Joint finder trained: %s", finder_summary(job.finder));
				return;
			}
			self.save_capture_tracks(job.engine.output("tracks.json"));
			char[] handed = job.engine.output("glb");
			char[] glb = handed.len > 0 ? alloc::new_array(mem, char, handed.len) : { };
			if (handed.len > 0) glb[..] = handed[..];
			defer if (glb.len > 0) alloc::free(mem, glb);
			String summary = capture_result_summary(job.engine.result());
			job.close_engine();
			job.running = false;
			job.stage = IDLE;
			job.finished++;
			if (glb.len == 0)
			{
				job.failed = true;
				job.set_last("the pipeline handed back no clip");
				self.@notice("Video capture failed: the pipeline handed back no clip");
				return;
			}
			AnimRef landed = self.land_generated_motion(glb, job.name, LIGHT);
			if (!landed.valid())
			{
				job.failed = true;
				self.@notice("Captured \"%s\", but it did not read as a clip for this character", job.name);
				return;
			}
			job.landed = landed;
			job.landed_pending = true;
			job.set_last(summary);
			self.@notice("Captured \"%s\" from the video (%s) · save to keep it in the model", job.name, summary);
		default:
			return;
	}
}

// The points the fit was made from, kept beside the clip's frames.
fn void AppState.save_capture_tracks(&self, char[] tracks)
{
	if (tracks.len == 0) return;
	String clip = self.capture_path(string::tformat("clips/%s", self.capture_job.name));
	(void)path::mkdir(clip, true);
	(void)file::save(string::tformat("%s/tracks.json", clip), tracks);
}

<*
 The fit's numbers from the animate task's answer, for the notice:
 "reprojection 9.4 px, root moved 6 cm". Temporary.
*>
fn String capture_result_summary(String result)
{
	Object*? parsed = json::parse(tmem, result);
	if (catch parsed) return "done";
	Object*? report = parsed.get("report");
	if (catch report) return "done";
	DString out = dstring::new(tmem);
	if (try Object* reproj = report.get("reprojection_px"))
	{
		if (try double median = reproj.get_float("median")) out.appendf("reprojection %.1f px", median);
	}
	if (try double travel = report.get_float("travel")) out.appendf("%sroot moved %.0f cm", out.len() > 0 ? ", " : "", travel * 100);
	return out.len() > 0 ? out.str_view() : "done";
}

<*
 Stop the running step. A stopped training set carries on from where it was
 when Train is pressed again.

 @return `False when nothing was running.`
*>
fn bool AppState.stop_capture(&self)
{
	CaptureJob* job = &self.capture_job;
	self.capture_graph.stop_run();
	if (!job.running) return false;
	job.close_engine();
	job.stop_ffmpeg();
	job.running = false;
	job.failed = true;
	job.stage = IDLE;
	job.finished++;
	job.set_last("stopped");
	self.@notice("Stopped the video capture step");
	return true;
}

<*
 The clip a finished capture landed, once: true and the clip the first time it
 is asked after a landing.
*>
fn bool AppState.take_captured_clip(&self, AnimRef* landed)
{
	if (!self.capture_job.landed_pending) return false;
	self.capture_job.landed_pending = false;
	*landed = self.capture_job.landed;
	return true;
}

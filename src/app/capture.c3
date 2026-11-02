<*
 Video capture: an animation of the character out of a video of it, through
 llm-runner's `creature` plugin (DINOv3 and a rig fit), run in-process like
 Kimodo (`app/generate.c3`). Three steps, each of which can be done again on
 its own:

 1. **A joint finder** for this character: a training set drawn the way
    render_poses draws it (poses inside the rig's limits and frames of its
    clips, from the front, the studio's front-left three-quarter and both
    sides), a few poses a frame so the window keeps repainting, then creature's `train` task on it, about half an hour
    on one GPU, at the node's picture size (bigger is finer and slower). Or a
    finder trained before, chosen as a file.
 2. **A reference picture**, from the Pose tab: render_studio's two cameras
    side by side, a front-left three-quarter view and the right side, on a
    saved pose. A video
    model animates it, or an image model reposes it.
 3. **The clip** (Nodes: Animate): creature's animate task reads the video
    a frame at a time (image::mp4, no ffmpeg) with the reference's layout
    (`studio.json`) and the finder; the clip lands on the character as
    Kimodo's do, one undo step. Or one picture (Image to pose), which lands as
    a saved pose.

 What is kept goes in a folder beside the model, `<model>.capture/`: the
 training set (`renders/`), the finder (`finder.safetensors`), the reference
 pictures (`references/<pose>/`; `studio/` from before; a second Train node
 keeps its own under `<node>/`, or in its save folder), and `capture.json`,
 which remembers a finder chosen from elsewhere. A clip writes nothing there.
 The model file itself is never written.

 One pipeline job runs at a time in the process, so a capture step and a text
 to motion job wait for each other.
*>
module crig;

import std::collections::object;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::core::string;
import std::math;
import std::collections::list;
import gltf_edit;
import image;
import image::png;
import image::jpeg;
import image::mp4;
import image::h264;
import llm::pipeline;

faultdef CAPTURE_NO_MODEL_FILE, CAPTURE_NO_BACKBONE, CAPTURE_BUSY, CAPTURE_NO_GPU, CAPTURE_NO_SKELETON,
	CAPTURE_NO_FINDER, CAPTURE_NO_REFERENCE, CAPTURE_NO_VIDEO, CAPTURE_NO_PLUGIN, CAPTURE_NOT_STARTED,
	CAPTURE_BAD_SIZE, CAPTURE_NO_IMAGE;

// The training set's size by default, and how many poses one frame draws.
const usz CAPTURE_DEFAULT_POSES = 1500;
const usz CAPTURE_CHUNK = 8;
// The training pictures' sides in pixels a finder can be trained at (multiples
// of DINOv3's 16-px patch, up to render_poses' 1024), and the default.
const uint[6] CAPTURE_SIZES = { 448, 512, 640, 768, 896, 1024 };
const uint CAPTURE_DEFAULT_SIZE = 448;
// The finder's training as the Zidane finder that fits best was trained: the
// last block's features beside the 20th's.
const String CAPTURE_TRAIN_EXTRA = `"layers": [20]`;

enum CaptureStage
{
	IDLE,
	RENDERING,  // the training set, a chunk between frames
	TRAINING,   // creature's train task
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
	uint step;
	uint steps;
	char[512] last_line;
	usz last_length;
	bool failed;
	// The training set: the next pose to draw, how many, and their side in pixels.
	usz render_next;
	usz render_total;
	uint render_size;
	// The clip being made: its name, its video, picture or frames' folder (the
	// training set's, while training), and their rate.
	String name;
	String frames;
	float fps;
	// The clip's finder and picture layout, for the animate task, and the
	// backbone the creature tasks run on.
	String finder;
	String studio;
	String backbone;
	// Each frame read once, not also mirrored (which keeps left and right apart).
	bool mirror_off;
	// Whether the one picture lands as a saved pose instead of a clip.
	bool pose;
	// Asked for by the pane; drawn between frames, where the renderer is free:
	// its folder, its clip ("" = the rest pose) and moment, and how it went.
	bool reference_pending;
	bool reference_ok;
	String reference_studio;
	String reference_clip;
	float reference_time;
	// A saved pose to draw instead of a clip, by name.
	String reference_pose;
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

fn void CaptureJob.clear(&self)
{
	self.close_engine();
	foreach (held : (String[]) { self.name, self.frames, self.finder, self.studio, self.backbone })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	self.name = self.frames = self.finder = self.studio = self.backbone = "";
	self.pose = false;
	self.running = false;
	self.stage = IDLE;
	self.failed = false;
	self.step = self.steps = 0;
	self.last_length = 0;
}

fn void CaptureJob.free(&self)
{
	self.clear();
	foreach (held : (String[]) { self.reference_studio, self.reference_clip, self.reference_pose })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	self.reference_studio = self.reference_clip = self.reference_pose = "";
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
	// A finder that looks again at the hands says how well.
	if (try Object* hands = info.get("hands"))
	{
		out.appendf("%shands", out.len() > 0 ? " · " : "");
		if (try Object* report = hands.get("report")) if (try Object* held = report.get("held_out_px"))
		{
			if (try double median = held.get_float("median")) out.appendf(" %.2f px", median);
		}
	}
	if (try double size = info.get_float("size")) out.appendf("%s%d px pictures", out.len() > 0 ? " · " : "", (int)size);
	return out.str_view();
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

// `backbone` is DINOv3's checkpoint; "" with `needs_backbone` off.
fn void? AppState.capture_ready(&self, String backbone, bool needs_backbone = true)
{
	if (self.source_path.len == 0) return CAPTURE_NO_MODEL_FILE~;
	if (self.doc.dots.len() == 0 || !self.has_mesh()) return CAPTURE_NO_SKELETON~;
	if (self.capture_engine_busy()) return CAPTURE_BUSY~;
	if (needs_backbone && backbone.trim().len == 0) return CAPTURE_NO_BACKBONE~;
	if (needs_backbone && self.llm_plugin_problem("creature").len > 0) return CAPTURE_NO_PLUGIN~;
	if (needs_backbone && !self.motion_gpu) return CAPTURE_NO_GPU~;
}

fn String capture_fault_text(fault err)
{
	switch (err)
	{
		case CAPTURE_NO_MODEL_FILE: return "the model has no file yet — save it as a .glb first, the capture folder goes beside it";
		case CAPTURE_NO_BACKBONE: return "wire in a DINOv3 backbone node holding SAM 3D Body's model.ckpt";
		case CAPTURE_BUSY: return "another pipeline job is running";
		case CAPTURE_NO_GPU: return "there is no GPU to run it on";
		case CAPTURE_NO_SKELETON: return "the model needs a skinned skeleton first";
		case CAPTURE_NO_FINDER: return "train a joint finder, or choose one, first";
		case CAPTURE_NO_REFERENCE: return "save a reference picture first: Pose tab › Reference picture";
		case CAPTURE_NO_VIDEO: return "choose a video (H.264 .mp4 or .mov), or a folder of its frames";
		case CAPTURE_CLIP_TAKEN: return "the character already has a clip by that name — give this one another";
		case CAPTURE_POSE_TAKEN: return "a pose by that name is saved — name this one";
		case CAPTURE_NO_IMAGE: return "choose the picture: a .png or .jpg";
		case CAPTURE_BAD_POSES: return "Poses is a whole number from 50 to 20000";
		case CAPTURE_BAD_SIZE: return "Size is one of 448, 512, 640, 768, 896 or 1024 pixels";
		case CAPTURE_NO_PLUGIN: return "the creature plugin is not in the plugins folder — link it in File › Settings › AI › Plugins";
		case h264::CABAC:
		case h264::B_SLICES:
		case h264::TRANSFORM_8X8:
		case h264::SCALING_LISTS:
		case h264::WEIGHTED: return "High-profile H.264 (CABAC, B-frames) isn't read yet: export the video as H.264 Baseline";
		case h264::INTERLACED: return "interlaced H.264 isn't read";
		case h264::SAMPLING: return "only 8-bit 4:2:0 H.264 is read";
		case h264::SLICE_GROUPS:
		case h264::UNSUPPORTED: return "this H.264 uses a feature that isn't read";
		case mp4::NOT_H264: return "only H.264 video is read (not HEVC, AV1 or VP9)";
		case mp4::NO_VIDEO: return "the file has no video track";
		case mp4::NOT_MP4: return "not an MP4 or MOV file";
		case mp4::CORRUPT:
		case mp4::NO_FRAME:
		case h264::CORRUPT:
		case h264::NO_PARAMETERS: return "the video is damaged";
		default: return "the pipeline would not start";
	}
}

// ---------------------------------------------------------------------------
// 1. The joint finder.

<*
 Start drawing the training set (`poses` pictures `size` pixels a side into
 `renders`, from where a stopped set left off) and then training the finder at
 `finder` on it.
*>
fn void? AppState.start_capture_training(&self, usz poses, uint size, String renders, String finder, String backbone)
{
	if (!capture_size_ok(size)) return CAPTURE_BAD_SIZE~;
	self.capture_ready(backbone)!;
	fit_renders_to(renders, size);
	(void)path::mkdir(renders, true);
	if (!path::is_dir((Path)renders)) return CAPTURE_NOT_STARTED~;
	CaptureJob* job = &self.capture_job;
	job.clear();
	job.frames = renders.copy(mem);
	job.finder = finder.copy(mem);
	job.backbone = backbone.trim().copy(mem);
	job.running = true;
	job.stage = RENDERING;
	job.render_total = math::max(poses, CAPTURE_CHUNK);
	job.render_size = size;
	job.render_next = first_missing_chunk(renders, job.render_total);
	job.step = (uint)job.render_next;
	job.steps = (uint)job.render_total;
	job.set_last(job.render_next > 0 ? "carrying on with the training set" : "drawing the training set");
	self.@notice("Drawing %d poses of the character at %d px to train its joint finder on…", job.render_total, size);
}

fn bool capture_size_ok(uint size)
{
	foreach (s : CAPTURE_SIZES) if (s == size) return true;
	return false;
}

// A training set drawn at another size or from other cameras is emptied: train
// refuses mixed sizes, and a set must not mix camera rigs.
fn void fit_renders_to(String renders, uint size)
{
	char[]? bytes = file::load_temp(string::tformat("%s/poses_000000.json", renders));
	if (catch bytes) return;
	Object*? set = json::parse(tmem, (String)bytes);
	if (try set) if (try double drawn = set.get_float("size")) if ((uint)drawn == size)
	{
		if (try Object* cameras = set.get("cameras")) if (cameras.is_array() && (usz)cameras.get_len() == CAPTURE_CAMERAS) return;
	}
	(void)path::rmtree((Path)renders);
}

// The training set's cameras: the front, the studio's front-left three-quarter
// and both sides.
const usz CAPTURE_CAMERAS = 4;

fn void capture_cameras(PoseShoot* shoot)
{
	shoot.cameras[0] = { .name = "front", .yaw = 0, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.cameras[1] = { .name = "quarter", .yaw = 45, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.cameras[2] = { .name = "left", .yaw = 90, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.cameras[3] = { .name = "right", .yaw = -90, .pitch = 8, .distance = 4, .yaw_jitter = 20, .pitch_jitter = 8 };
	shoot.camera_count = CAPTURE_CAMERAS;
}

<*
 One chunk of the training set, between frames: the poses render_poses draws
 for the same seed and index, from the front, the front-left three-quarter
 and both sides, a share of them frames of the clips that play on the rig,
 with the points of the mesh that show which way the head and the feet turn.
*>
fn void AppState.draw_capture_chunk(&self)
{
	CaptureJob* job = &self.capture_job;
	PoseShoot shoot = pose_shoot_defaults();
	shoot.out = job.frames;
	shoot.first = job.render_next;
	shoot.count = math::min(CAPTURE_CHUNK, job.render_total - job.render_next);
	shoot.size = job.render_size;
	capture_cameras(&shoot);
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
	self.start_capture_engine(TRAINING, capture_train_json(job.backbone, job.frames, job.finder));
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
 render_studio's two cameras on the saved pose `pose`, or else on `clip`
 ("pack/clip"; "" is the rest pose) at `time` seconds.
*>
fn void? AppState.request_capture_reference(&self, String studio, String clip, float time, String pose = "")
{
	if (self.source_path.len == 0) return CAPTURE_NO_MODEL_FILE~;
	if (self.doc.dots.len() == 0 || !self.has_mesh()) return CAPTURE_NO_SKELETON~;
	CaptureJob* job = &self.capture_job;
	replace_owned(&job.reference_studio, studio);
	replace_owned(&job.reference_clip, clip);
	replace_owned(&job.reference_pose, pose);
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
	if (job.reference_pose.len > 0)
	{
		sz at = self.saved_pose_named(job.reference_pose);
		if (at < 0)
		{
			job.finished++;
			self.@notice("The reference picture could not be drawn: no saved pose \"%s\"", job.reference_pose);
			return;
		}
		ask.dots = self.doc.poses[at].dots;
		ask.clip = "";
	}
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
	if (job.reference_pose.len > 0)
	{
		self.@notice("Reference picture of \"%s\" written · copy a prompt for a video or an image model", job.reference_pose);
		return;
	}
	self.@notice("Reference picture written to %s · give it to the video model with the prompt", studio);
}

// ---------------------------------------------------------------------------
// The references: each a folder with reference.png and studio.json.

// A pose's name as a folder name. Temporary.
fn String capture_reference_name(String pose)
{
	String name = pose.trim().tcopy();
	foreach (&c : name) if (*c == '/' || *c == '\\' || *c == ':') *c = '_';
	return name.len > 0 ? name : "pose";
}

// A reference's folder: "studio" is the capture folder's own, from before references. Temporary.
fn String AppState.capture_reference_path(&self, String name)
{
	if (name == "studio") return self.capture_path("studio");
	return self.capture_path(string::tformat("references/%s", name));
}

<*
 The references saved for this character, newest first (by their studio.json),
 into `out` as names allocated with `allocator`.
*>
fn void AppState.capture_references(&self, Allocator allocator, List{String}* out)
{
	if (self.capture_folder().len == 0) return;
	List{String} names;
	names.init(tmem);
	List{long} times;
	times.init(tmem);
	String root = self.capture_path("references");
	if (try PathList listed = path::ls(tmem, (Path)root))
	{
		foreach (entry : listed)
		{
			String name = (String)entry;
			if (try time = file::last_modified(string::tformat("%s/%s/studio.json", root, name)))
			{
				names.push(name.tcopy());
				times.push((long)time);
			}
		}
	}
	if (try time = file::last_modified(self.capture_path("studio/studio.json")))
	{
		names.push("studio");
		times.push((long)time);
	}
	// Newest first; a tie by name.
	sz count = names.len();
	for (sz i = 1; i < count; i++)
	{
		for (sz k = i; k > 0; k--)
		{
			bool later = times[k] > times[k - 1] || (times[k] == times[k - 1] && names[k].compare_to(names[k - 1]) < 0);
			if (!later) break;
			times.swap(k, k - 1);
			names.swap(k, k - 1);
		}
	}
	foreach (name : names) out.push(name.copy(allocator));
}

// The reference `chosen` names when it is there, else the newest; "" when there is none. Temporary.
fn String AppState.capture_reference_for(&self, String chosen)
{
	chosen = chosen.trim();
	if (chosen.len > 0 && file::exists(string::tformat("%s/studio.json", self.capture_reference_path(chosen)))) return self.capture_reference_path(chosen);
	List{String} found;
	found.init(tmem);
	self.capture_references(tmem, &found);
	return found.len() > 0 ? self.capture_reference_path(found[0]) : "";
}

const uint MATCH_W = 48;
const uint MATCH_H = 24;
const uint MATCH_CELLS = MATCH_W * MATCH_H;

// A picture or a video's first frame; png and jpeg by extension, mp4 and mov decoded.
fn image::Image? load_picture(String file_name, Allocator allocator) @private
{
	String lower = file_name.to_lower_tcopy();
	if (lower.ends_with(".png")) return png::load_file(file_name, allocator);
	if (lower.ends_with(".mp4") || lower.ends_with(".m4v") || lower.ends_with(".mov"))
	{
		mp4::Video v = mp4::open(file_name, allocator)!;
		defer v.close();
		return v.frame(0, allocator);
	}
	return jpeg::load_file(file_name, allocator);
}

// `file_name` as a small grey grid of box averages, levelled to mean 0 and spread 1.
fn bool picture_thumb(String file_name, float[] out) @private
{
	@pool()
	{
		image::Image? img = load_picture(file_name, tmem);
		if (catch img) return false;
		if (img.bit_depth != 8 || img.width < MATCH_W || img.height < MATCH_H) return false;
		char[] rgba = img.to_rgba(tmem);
		float[MATCH_CELLS] count;
		out[..] = 0;
		for (uint y = 0; y < img.height; y++)
		{
			uint row = y * MATCH_H / img.height * MATCH_W;
			for (uint x = 0; x < img.width; x++)
			{
				usz at = ((usz)y * img.width + x) * 4;
				uint cell = row + x * MATCH_W / img.width;
				out[cell] += (float)rgba[at] + (float)rgba[at + 1] + (float)rgba[at + 2];
				count[cell] += 1;
			}
		}
		float mean = 0;
		for (uint i = 0; i < MATCH_CELLS; i++)
		{
			out[i] /= count[i];
			mean += out[i];
		}
		mean /= MATCH_CELLS;
		float spread = 0;
		for (uint i = 0; i < MATCH_CELLS; i++) spread += (out[i] - mean) * (out[i] - mean);
		spread = math::sqrt(spread / MATCH_CELLS) + 1e-3f;
		for (uint i = 0; i < MATCH_CELLS; i++) out[i] = (out[i] - mean) / spread;
		return true;
	};
}

<*
 The reference `picture` (or a video's first frame) was made from: the saved
 one whose reference.png looks most like it (the newest when it can't be
 read); "" when there is none. Temporary.
*>
fn String AppState.capture_reference_matching(&self, String picture)
{
	List{String} found;
	found.init(tmem);
	self.capture_references(tmem, &found);
	if (found.len() == 0) return "";
	sz best = 0;
	float[MATCH_CELLS] seen;
	if (found.len() > 1 && picture_thumb(picture, &seen))
	{
		float least = math::FLOAT_MAX;
		for (sz i = 0; i < found.len(); i++)
		{
			float[MATCH_CELLS] drawn;
			if (!picture_thumb(string::tformat("%s/reference.png", self.capture_reference_path(found[i])), &drawn)) continue;
			float apart = 0;
			for (uint k = 0; k < MATCH_CELLS; k++) apart += (seen[k] - drawn[k]) * (seen[k] - drawn[k]);
			if (apart < least)
			{
				least = apart;
				best = i;
			}
		}
	}
	return self.capture_reference_path(found[best]);
}

// The first picture in `folder` by name; "" when there is none. Temporary.
fn String first_picture_in(String folder)
{
	String first = "";
	PathList? listed = path::ls(tmem, (Path)folder, no_dirs: true);
	if (catch listed) return "";
	foreach (entry : listed)
	{
		String name = (String)entry;
		String lower = name.to_lower_tcopy();
		if (!lower.ends_with(".png") && !lower.ends_with(".jpg") && !lower.ends_with(".jpeg")) continue;
		if (first.len == 0 || name.compare_to(first) < 0) first = name;
	}
	return first.len > 0 ? string::tformat("%s/%s", folder, first) : "";
}

// For an image model: reference.png moved into another pose, the framing kept.
const String POSE_PROMPT = `Pose: <describe the pose here>.

Edit this split-screen image of one character into the pose above. <the views> Both show the same moment. Change only the pose, the same pose in both views. Keep the character exactly as it is: the same model, colours and proportions, nothing added or lost. Keep it the same size, centred in each view where it stands now, feet on the floor. The cameras do not move; the plain grey background, the lighter floor band and the dark vertical divider stay exactly as they are, and the image keeps its size.`;

// The left camera's yaw in the reference folder `studio` (its studio.json); 0,
// the front, for a reference from before the three-quarter view.
fn float capture_left_yaw(String studio)
{
	char[]? bytes = file::load_temp(string::tformat("%s/studio.json", studio));
	if (catch bytes) return 45;
	Object*? layout = json::parse(tmem, (String)bytes);
	if (catch layout) return 45;
	if (try Object* views = layout.get("views")) if (views.is_array() && views.get_len() > 0)
	{
		if (try double yaw = views.get_at(0).get_float("yaw")) return (float)yaw;
	}
	return 0;
}

// The prompt for an image model, `pose` filled in. Temporary.
fn String capture_pose_prompt(String pose, float left_yaw)
{
	String prompt = POSE_PROMPT.treplace("<the views>", studio_views_text(left_yaw));
	pose = pose.trim();
	if (pose.len == 0) return prompt;
	if (pose[^1] == '.') pose = pose[:pose.len - 1];
	return prompt.treplace("<describe the pose here>", pose);
}

// The prompt render_studio wrote, `action` filled in. Temporary.
fn String capture_prompt(String action, float left_yaw)
{
	String prompt = studio_prompt(left_yaw);
	action = action.trim();
	if (action.len == 0) return prompt;
	if (action[^1] == '.') action = action[:action.len - 1];
	return prompt.treplace("<describe the movement here>", action);
}

// ---------------------------------------------------------------------------
// 3. The clip.

<*
Start turning `video` into the clip `name` ("" = the video's file name) with
 `finder` and the reference in `studio` ("" = the one its first frame looks
 like): an H.264 .mp4/.mov the pipeline reads a frame at a time, or a folder
 of frames. With `pose`, `video` is one picture and the result a saved pose.
 Nothing is written beside the model.
*>
fn void? AppState.start_capture_animation(&self, String backbone, String finder, String studio, String video, String name, bool mirror = true,
	bool pose = false)
{
	self.capture_ready(backbone)!;
	if (finder.len == 0 || !file::exists(finder)) return CAPTURE_NO_FINDER~;
	if (studio.len == 0 && self.capture_reference_for("").len == 0) return CAPTURE_NO_REFERENCE~;
	if (studio.len > 0 && !file::exists(string::tformat("%s/studio.json", studio))) return CAPTURE_NO_REFERENCE~;
	video = video.trim();
	if (pose)
	{
		if (video.len == 0 || !file::is_file(video)) return CAPTURE_NO_IMAGE~;
	}
	else if (video.len == 0 || !path::exists((Path)video))
	{
		return CAPTURE_NO_VIDEO~;
	}
	bool folder = !pose && path::is_dir((Path)video);
	float fps = 24;
	if (!pose && !folder)
	{
		// Refused here, with the decoder's reason, rather than part way through.
		mp4::Video v = mp4::open(video)!;
		if (v.fps > 0) fps = v.fps;
		v.close();
	}

	name = name.trim();
	if (name.len == 0) name = capture_clip_name(video);
	CaptureJob* job = &self.capture_job;
	job.clear();
	job.name = name.copy(mem);
	job.finder = finder.copy(mem);
	job.backbone = backbone.trim().copy(mem);
	job.mirror_off = !mirror;
	job.pose = pose;
	job.fps = fps;
	job.frames = video.copy(mem);
	if (studio.len == 0) studio = self.capture_reference_matching(folder ? first_picture_in(video) : video);
	if (studio.len > 0) job.studio = studio.copy(mem);
	job.running = true;
	self.start_capture_engine(ANIMATING, self.capture_animate_json());
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
	gltf_edit::escape_json_string(&out, job.backbone);
	out.append_string(",\n  \"rig\": ");
	out.append_string(rig);
	out.append_string(",\n  \"finder\": ");
	gltf_edit::escape_json_string(&out, job.finder);
	out.append_string(",\n  \"studio\": ");
	gltf_edit::escape_json_string(&out, string::tformat("%s/studio.json", job.studio));
	out.append_string(",\n  \"frames\": ");
	if (job.pose) out.append_string("[");
	gltf_edit::escape_json_string(&out, job.frames);
	if (job.pose) out.append_string("]");
	out.append_string(",\n  \"name\": ");
	gltf_edit::escape_json_string(&out, job.name);
	if (job.mirror_off) out.append_string(",\n  \"flip\": false");
	out.appendf(",\n  \"fps\": %.4f,\n  \"outputs\": [\"glb\"]\n}\n", job.fps);
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
 A frame of the running step: the pipeline pumped, and what follows once it
 ends. Driven from `AppRoot.update`.
*>
fn void AppState.tick_capture(&self)
{
	CaptureJob* job = &self.capture_job;
	self.advance_pipeline();
	if (!job.running) return;
	switch (job.stage)
	{
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
			if (job.pose)
			{
				self.land_capture_pose(glb, summary);
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

// The one frame of a picture's fit, into the pose library as job.name.
fn void AppState.land_capture_pose(&self, char[] glb, String summary)
{
	CaptureJob* job = &self.capture_job;
	AnimTemplate? sampled = self.generated_clip_on_rig(glb, job.name, OFF);
	if (catch sampled)
	{
		job.failed = true;
		self.@notice("Read \"%s\", but it did not read as a pose for this character", job.name);
		return;
	}
	AnimTemplate clip = sampled;
	defer clip.free(mem);
	if (clip.keyframes.len == 0 || clip.keyframes[0].dots.len == 0)
	{
		job.failed = true;
		self.@notice("Read \"%s\", but the fit handed back no pose", job.name);
		return;
	}
	SavedPose made = { .name = job.name.copy(mem), .dots = keyframe_copy(mem, { .dots = clip.keyframes[0].dots }).dots };
	self.pose_library_row = (usz)self.store_pose(made);
	job.set_last(summary);
	self.@notice("Pose \"%s\" from the picture (%s) · in Poses", job.name, summary);
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
	if (try Object* seconds = report.get("seconds"))
	{
		if (try double total = seconds.get_float("total"))
		{
			out.appendf("%sin %s", out.len() > 0 ? ", " : "", capture_duration(total));
			if (try double fit = seconds.get_float("fit")) out.appendf(" (fit %s)", capture_duration(fit));
		}
	}
	return out.len() > 0 ? out.str_view() : "done";
}

// "9 min 47 s", or "4 s".
fn String capture_duration(double seconds)
{
	long s = (long)(seconds + 0.5);
	if (s < 60) return string::tformat("%d s", s);
	return string::tformat("%d min %d s", s / 60, s % 60);
}

<*
 Stop the running step. A stopped training set carries on from where it was
 when Train is pressed again.

 @return `False when nothing was running.`
*>
fn bool AppState.stop_capture(&self)
{
	CaptureJob* job = &self.capture_job;
	self.stop_runs();
	if (!job.running) return false;
	job.close_engine();
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

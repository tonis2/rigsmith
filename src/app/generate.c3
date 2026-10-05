<*
 Text to motion: a prompt in, a clip on the character out.

 	`app.start_motion_generation({ .prompt = "a person waves", .seconds = 5 })!;`

 NVIDIA's Kimodo runs as llm-runner's `kimodo` pipeline, which crig links as
 the `llm` library (`lib/llm.c3l`) and runs on its own GPU through
 `llm::pipeline::Job`. What the user supplies is only the weights — in File ›
 Settings › AI: the text encoder's .gguf files and the motion model, either
 kimodo.cpp's .gguf or NVIDIA's release folder as downloaded. The pipeline hands back a .glb — a skeleton, one
 animation, no mesh — and the clip comes in by the door every downloaded clip
 does: `pack_for_file` matches the source skeleton onto the character's body
 plan by shape, and a bind puts it on the character. A generated walk is
 retargeted exactly the way a Mixamo walk is.

 **Asynchronous because it is slow.** A generation is ten to thirty seconds of
 GPU work, most of it the diffusion loop. The pipeline breathes between blocks
 of work and the job is pumped once a frame from `AppRoot.update` — `ticking`
 keeps frames coming while it runs — so the window keeps drawing and the
 progress can be shown. Loading the weights is the one long stretch that does
 not breathe. One job at a time: the library keeps one set of open models.

 **Where the clips go.** Into the character, and never through a file. The
 pipeline hands its .glb over in memory (`glb_output`, read back with
 `Job.output("glb")`); the clip is read out of those bytes, sampled onto this
 rig and stored in the authored pack under the rig's own joint names — the same
 place a hand-keyed clip lives. Save then writes it into the model's .glb with
 the rest of the character's animations, and an unsaved one goes the way of
 every unsaved edit.

 **What a generated clip is.** In place, like every imported clip — the importer
 takes the travel off the hips (`strip_root_travel`) — at the runner's 30 fps,
 and not a loop; Kimodo generates one-off motions.

 **Guide poses.** A request can name one of the character's clips as its guide
 (`MotionRequest.guide`): every instant that clip has a key becomes a keyframe
 the generated motion passes through, and Kimodo makes what lies between. An
 instant keyed only on arms and legs holds just those hands and feet; one with
 a key on the hips, spine or head holds the whole body. Only keyed instants are
 sent, never the in-betweens crig would interpolate — those are not poses the
 user chose. The rig is matched onto Kimodo's skeleton the way a clip is
 matched onto the rig, only the other way round (`motion_guide_json`): the
 pipeline's rest skeleton, carried in the library, is measured against the
 open rig, and each joint's posed position is sent under the Kimodo joint it
 answers to, turned so the rig faces +Z as Kimodo's skeleton does. The pipeline
 rescales them to its own proportions, fills in the joints this rig has no word
 for, and after generating snaps the keyed frames onto the poses and stops
 planted feet sliding (llm-runner's plugins/kimodo/cleanup.js).
*>
module crig;

import std::math;
import std::io;
import std::io::file;
import std::io::path;
import std::core::string;
import gltf_edit;
import three;
import llm::pipeline;
import rig;

faultdef MOTION_NO_GENERATOR, MOTION_NO_GPU, MOTION_BUSY, MOTION_NO_PROMPT, MOTION_NOT_STARTED,
	MOTION_GUIDE_MISSING, MOTION_GUIDE_UNMATCHED, MOTION_GUIDE_EMPTY;

<*
 What the motion model setting still lacks: "" when the pipeline can load it,
 otherwise the missing file, as the path to look for.

 A folder is NVIDIA's release (huggingface.co/nvidia/Kimodo-*) as downloaded
 and needs its model.safetensors; any file — the .safetensors under any name,
 or kimodo.cpp's .gguf — only has to exist. The plugin carries the motion
 statistics for the models it knows and says so at generation if it does not
 know these weights and there is no stats/ folder beside them.
 Temporary.
*>
fn String motion_checkpoint_gap(String setting)
{
	if (!file::is_dir(setting)) return file::exists(setting) ? "" : setting;
	String folder = setting;
	while (folder.len > 1 && folder.ends_with("/")) folder = folder[:folder.len - 1];
	String weights = string::tformat("%s/model.safetensors", folder);
	return file::exists(weights) ? "" : weights;
}

const float MOTION_FPS = 30.0f;
const float MOTION_MIN_SECONDS = 1.0f;
// Kimodo is trained on clips of a few seconds; past ten the motion wanders.
const float MOTION_MAX_SECONDS = 10.0f;
const float MOTION_DEFAULT_SECONDS = 5.0f;
const uint MOTION_DEFAULT_STEPS = 100;
const uint MOTION_MAX_STEPS = 1000;
// The rest skeleton guide poses are matched against, under the plugins folder.
// The SOMA models are the human ones; their joint names are what the pipeline
// reads a guide pose's names as.
const String MOTION_GUIDE_SKELETON = "kimodo/skeletons/soma30.glb";

<*
 One request. Zero fields take the defaults: 5 seconds, 100 diffusion steps,
 seed 0 (a fixed seed, so the same prompt gives the same motion until it is
 changed), a name made from the prompt, and no guide poses.
*>
struct MotionRequest
{
	String prompt;
	String name;
	float seconds;
	uint steps;
	uint seed;
	// A clip bound to the character whose keyed poses the motion passes
	// through; "" for none. Borrowed.
	String guide;
}

<*
 The job running now, if any, and the outcome of the last one.

 Every String is owned. `engine` is the pipeline run, on the heap because it
 must not move while it runs. `last_line` is the last line the pipeline printed
 — which, on a failure, is the error.
*>
struct MotionJob
{
	bool running;
	llm::pipeline::Job* engine;
	String name;
	String prompt;
	// The .glb the pipeline handed over in memory, taken from the engine before
	// it closes. Owned.
	char[] glb;
	// The guide clip's keyed instants the job was given, and the ones past the
	// generated length that were left out.
	usz guide_keys;
	usz guide_dropped;
	usz guide_partial; // of guide_keys, those holding only hands and feet
	uint step;
	uint steps;
	char[512] last_line;
	usz last_length;
	double started;

	// How the last job ended, once it has: `failed` with `last_line` saying why,
	// or `landed` naming the clip it bound.
	bool failed;

	// Set when a job finishes and has landed a clip, for the interface to select
	// and play it; `take_generated_clip` hands it over once.
	AnimRef landed;
	bool landed_pending;
}

<*
 The Generate panel's fields as typed, owned, so a rebuild of the panel (a job
 starting or landing) does not lose a half-written prompt.
*>
struct MotionDraft
{
	String name;   // the clip's name as typed; "" = `next_generated_name`
	String prompt;
	String seconds;
	String seed;
	String steps;
	String guide; // the bound clip chosen under "Poses from"; "" = none
}

fn void MotionDraft.free(&self)
{
	foreach (held : (String[]){ self.name, self.prompt, self.seconds, self.seed, self.steps, self.guide })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	*self = {};
}

fn String MotionJob.last(&self) => (String)self.last_line[:self.last_length];

fn void MotionJob.clear(&self)
{
	self.close_engine();
	foreach (held : (String[]){ self.name, self.prompt })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	self.name = self.prompt = "";
	if (self.glb.len > 0) alloc::free(mem, self.glb);
	self.glb = {};
	self.running = false;
	self.failed = false;
	self.landed = NO_ANIM;
	self.guide_keys = self.guide_dropped = self.guide_partial = 0;
	self.step = self.steps = 0;
	self.last_length = 0;
}

fn void MotionJob.close_engine(&self)
{
	if (!self.engine) return;
	self.engine.free();
	mem::free(self.engine);
	self.engine = null;
}

fn void MotionJob.set_last(&self, String line)
{
	usz n = line.len < self.last_line.len ? line.len : self.last_line.len;
	self.last_line[:n] = line[:n];
	self.last_length = n;
}

<*
 A line the pipeline printed: a step count moves the progress, and any line is
 kept as the last, which on a failure is the one that says why.
*>
fn void motion_line(void* context, String line)
{
	MotionJob* job = context;
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

<*
 How far the running job is, 0 to 1. The text encoder and the weight upload come
 before the first step and read as 0.
*>
fn float MotionJob.progress(&self) => self.steps == 0 ? 0.0f : (float)self.step / (float)self.steps;

<*
 A clip name out of a prompt: its first clause, cut to about forty characters at a
 word, with the first letter raised. "a person walks forward and waves" is its own
 name; "a person jumps, then lands" is "A person jumps".
*>
fn String motion_clip_name(Allocator allocator, String prompt)
{
	String text = prompt.trim();
	// A clause is a name: "walks forward, then sits" is "Walks forward".
	foreach (usz i, c : text)
	{
		if (i >= 12 && (c == ',' || c == '.' || c == ';' || c == '!' || c == '?'))
		{
			text = text[:i];
			break;
		}
	}
	usz cut = text.len;
	if (cut > 40)
	{
		cut = 40;
		while (cut > 20 && text[cut] != ' ') cut--;
		if (text[cut] != ' ') cut = 40;
	}
	String name = text[:cut].trim().copy(allocator);
	if (name.len > 0 && name[0] >= 'a' && name[0] <= 'z') name[0] -= 32;
	return name;
}

const String GENERATED_NAME_PREFIX = "Generated";

<*
 The name the Generate pane gives a clip left unnamed: "Generated 1", then 2, and
 so on — the lowest number no clip on this character already has.

 	`String name = app.next_generated_name(mem);`
*>
fn String AppState.next_generated_name(&self, Allocator allocator)
{
	for (int n = 1; ; n++)
	{
		String name = string::tformat("%s %d", GENERATED_NAME_PREFIX, n);
		if (!self.has_bound_clip_named(name)) return name.copy(allocator);
	}
}

<*
 Whether a clip of this name is on the character, from any file.
*>
fn bool AppState.has_bound_clip_named(&self, String name)
{
	foreach (bound : self.doc.animations.array_view())
	{
		if (bound.clip == name) return true;
	}
	return false;
}

<*
 The step a line of the pipeline's output reports, as "step 40/100": true and the
 two numbers when it is one, false for every other line.
*>
fn bool parse_motion_step(String line, uint* step, uint* steps)
{
	String text = line.trim();
	if (!text.starts_with("step ")) return false;
	String rest = text[5..];
	sz? found = rest.index_of_char('/');
	if (catch found) return false;
	usz slash = (usz)found;
	usz end = slash + 1;
	while (end < rest.len && rest[end] >= '0' && rest[end] <= '9') end++;
	uint? done = rest[:slash].to_uint();
	uint? total = rest[slash + 1 : end - slash - 1].to_uint();
	if (catch done) return false;
	if (catch total) return false;
	if (total == 0) return false;
	*step = done;
	*steps = total;
	return true;
}

<*
 Where the library's plugin files are written out for the pipeline to run
 from: `llm` in crig's config directory. Owned.
*>
fn String AppState.motion_plugins_directory(&self)
{
	if (self.config.directory.len > 0) return string::format(mem, "%s/llm", self.config.directory);
	return "build/llm".copy(mem);
}

<*
 The pipeline's settings for one request, as JSON. `poses` is the guide, as
 `motion_guide_json` writes it; "" for none. Owned.
*>
fn String motion_job_json(MotionGenerator* g, MotionRequest* request, String name, uint frames,
	String poses = "")
{
	DString out;
	out.init(mem);
	out.append_string("{\n  \"text_model\": ");
	gltf_edit::escape_json_string(&out, g.text_model);
	if (g.tokenizer.len > 0)
	{
		out.append_string(",\n  \"tokenizer\": ");
		gltf_edit::escape_json_string(&out, g.tokenizer);
	}
	out.append_string(",\n  \"model\": ");
	gltf_edit::escape_json_string(&out, g.model);
	out.append_string(",\n  \"prompt\": ");
	gltf_edit::escape_json_string(&out, request.prompt);
	out.append_string(",\n  \"name\": ");
	gltf_edit::escape_json_string(&out, name);
	// The .glb is handed back in memory (Job.output("glb")): nothing on disk.
	out.append_string(",\n  \"glb_output\": true");
	if (poses.len > 0)
	{
		out.append_string(",\n  \"poses\": ");
		out.append_string(poses);
	}
	out.appendf(",\n  \"frames\": %d,\n  \"steps\": %d,\n  \"seed\": %d,\n  \"progress\": true\n}\n",
		frames, request.steps == 0 ? MOTION_DEFAULT_STEPS : request.steps, request.seed);
	String json = out.copy_str(mem);
	out.free();
	return json;
}

<*
 The bound clip called `name`, its curves read. Null when the character has
 no such clip or its file is gone.
*>
fn AnimTemplate* AppState.bound_clip_named(&self, String name, AnimRef* ref)
{
	foreach (sz i, bound : self.doc.animations.array_view())
	{
		if (bound.clip != name) continue;
		AnimRef found = self.resolve_bound(i);
		if (!found.valid()) continue;
		self.ensure_clip_imported(found);
		AnimTemplate* clip = self.clip(found);
		if (!clip) continue;
		*ref = found;
		return clip;
	}
	return null;
}

fn void append_json_point(DString* out, Vec3 p) @local
{
	out.appendf("[%.5f, %.5f, %.5f]", p.x, p.y, p.z);
}

<*
 Which of Kimodo's hands and feet a Kimodo joint belongs to: "LeftHand" for the
 left arm from the shoulder down, "LeftFoot" for the left leg from the hip down,
 and the same on the right; "" for the hips, spine, neck, head and eyes.
*>
fn String kimodo_limb(String joint)
{
	foreach (side : (String[]){ "Left", "Right" })
	{
		if (!joint.starts_with(side)) continue;
		String part = joint[side.len..];
		foreach (arm : (String[]){ "Shoulder", "Arm", "ForeArm", "Hand" })
		{
			if (part.starts_with(arm)) return side == "Left" ? "LeftHand" : "RightHand";
		}
		foreach (leg : (String[]){ "Leg", "Shin", "Foot", "Toe" })
		{
			if (part.starts_with(leg)) return side == "Left" ? "LeftFoot" : "RightFoot";
		}
	}
	return "";
}

const String[4] KIMODO_EFFECTORS = { "LeftHand", "RightHand", "LeftFoot", "RightFoot" };

<*
 The hands and feet a guide clip's keys at `time` touch, when that is all they
 touch: `held[k]` for KIMODO_EFFECTORS[k]. False when any key there is on a
 joint outside the four limbs — the hips, the spine, the head — or on a joint
 with no Kimodo joint above it, which makes it a whole-body pose.

 A key's joint counts as the nearest joint at or above it that answers to a
 Kimodo joint (`sent`), so a finger keyed on its own holds its hand.
*>
fn bool AppState.guide_effectors(&self, AnimTemplate* clip, float time, RigView* view, PackReach* reach,
	bool[] sent, bool[4]* held)
{
	*held = {};
	bool touched;
	foreach (key : clip.keyframes)
	{
		if (math::abs(key.time - time) > GHOST_KEY_EPSILON) continue;
		foreach (dot : key.dots)
		{
			int joint = -1;
			foreach (usz i, name : view.names)
			{
				if (name.len > 0 && name == dot.joint_name) { joint = (int)i; break; }
			}
			while (joint >= 0 && !sent[joint]) joint = view.skeleton.parents[joint];
			if (joint < 0) return false;
			String limb = kimodo_limb(reach.names[joint]);
			if (limb.len == 0) return false;
			foreach (usz k, name : KIMODO_EFFECTORS) if (name == limb) (*held)[k] = true;
			touched = true;
		}
	}
	return touched;
}

<*
 Which way a figure faces, as a turn about Y from +Z in radians, read the way
 Kimodo reads its own: the line from its right side to its left points along −X
 for a figure facing +Z. Zero when `across` has no length over the floor.
*>
fn float heading_of(Vec3 across) @local
{
	if (across.x * across.x + across.z * across.z < 1.0e-12f) return 0.0f;
	return math::atan2(across.z, -across.x);
}

<*
 The rig's heading from its joint names, before anything is matched: the
 average right-named joint to the average left-named one. The shape matcher
 tells left from right by the sign of x, so a rig has to be stood facing +Z
 before it is measured against Kimodo's skeleton at all — the same reading
 `faces_back` takes of a file. Zero for a rig naming fewer than two joints on
 each side.
*>
fn float rig_heading_by_names(RigView* view) @local
{
	Vec3 left;
	Vec3 right;
	usz lefts;
	usz rights;
	foreach (usz i, name : view.names)
	{
		char side = name_side(name);
		if (side == 0) continue;
		if (side == 'L' || side == 'l')
		{
			left += view.skeleton.joints[i];
			lefts++;
		}
		else
		{
			right += view.skeleton.joints[i];
			rights++;
		}
	}
	if (lefts < 2 || rights < 2) return 0.0f;
	return heading_of(right / (float)rights - left / (float)lefts);
}

<*
 What heading is left once matched, read off the joints answering to Kimodo's
 hips and shoulders — for a rig whose names say no side, or one turned by less
 than its names can tell.
*>
fn float matched_heading(rig::Skeleton* skeleton, PackReach* reach, bool[] sent) @local
{
	Vec3 across;
	foreach (pair : (String[2][]){ { "RightLeg", "LeftLeg" }, { "RightArm", "LeftArm" } })
	{
		int right = -1;
		int left = -1;
		foreach (usz i, name : reach.names)
		{
			if (i >= sent.len || !sent[i]) continue;
			if (name == pair[0]) right = (int)i;
			if (name == pair[1]) left = (int)i;
		}
		if (right >= 0 && left >= 0) across += skeleton.joints[right] - skeleton.joints[left];
	}
	return heading_of(across);
}

// `p` turned about the Y axis by `angle` radians, +Z toward +X.
fn Vec3 turned_about_y(Vec3 p, float angle) @local
{
	float c = math::cos(angle);
	float s = math::sin(angle);
	return { p.x * c + p.z * s, p.y, p.z * c - p.x * s };
}

<*
 The guide poses of bound clip `guide` for a job of `frames` frames, as the
 pipeline's `poses` JSON (see llm-runner's plugins/kimodo/poses.js): the rig
 at rest and, for each instant the clip has a key before the end, where every
 joint stands then — in the rig's own units, keyed by the Kimodo joint each
 one answers to. `skeleton` is the pipeline's rest skeleton the rig is
 matched against. Owned.

 An instant whose keys are all on arms and legs holds only those hands and
 feet (`"effectors"`), and leaves the rest of the body to the model; one with a
 key on the hips, spine or head holds the whole pose. Every point is turned
 about Y so the rig faces +Z, the way Kimodo's skeleton stands.

 @param [&inout] keyed : `The instants sent.`
 @param [&inout] dropped : `Instants keyed at or past the generated length, left out.`
 @param [inout] partial : `The instants sent that hold only hands and feet; null when not wanted.`
 @return? MOTION_GUIDE_MISSING : `The character has no clip of that name, or no skeleton.`
 @return? MOTION_GUIDE_UNMATCHED : `The rig does not match Kimodo's human skeleton.`
 @return? MOTION_GUIDE_EMPTY : `The clip has no key inside the generated length.`
*>
fn String? AppState.motion_guide_json(&self, String guide, uint frames, String skeleton, usz* keyed, usz* dropped,
	usz* partial = null)
{
	*keyed = *dropped = 0;
	if (partial) *partial = 0;
	AnimRef ref;
	AnimTemplate* clip = self.bound_clip_named(guide, &ref);
	if (!clip) return MOTION_GUIDE_MISSING~;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return MOTION_GUIDE_MISSING~;
	RigView view = opened;
	defer view.free(mem);
	AnimPack? read = read_pack(mem, skeleton);
	if (catch read) return MOTION_GUIDE_UNMATCHED~;
	AnimPack kimodo = read;
	defer kimodo.free(mem);

	// Matched stood facing +Z; the rig itself is posed where it stands, since
	// its keys turn about world axes, and only the points sent are turned.
	float named = rig_heading_by_names(&view);
	Vec3[] stood = alloc::new_array(mem, Vec3, (sz)view.skeleton.len());
	defer alloc::free(mem, stood);
	foreach (usz i, joint : view.skeleton.joints) stood[i] = turned_about_y(joint, -named);
	rig::Skeleton facing_forward = { .joints = stood, .parents = view.skeleton.parents };
	PackReach reach = measure_reach(mem, &kimodo, &facing_forward, view.names);
	defer reach.free(mem);
	if (!reach.usable) return MOTION_GUIDE_UNMATCHED~;

	// Which rig joints are sent: those answering to a Kimodo joint, each Kimodo
	// joint once.
	usz joints = view.skeleton.len();
	bool[] sent = mem::new_array(bool, (sz)joints);
	defer alloc::free(mem, sent);
	usz answered;
	for (usz i = 0; i < joints && i < reach.names.len; i++)
	{
		if (pack_joint_index(&kimodo, reach.names[i]) < 0) continue;
		bool twice;
		for (usz k = 0; k < i; k++) if (sent[k] && reach.names[k] == reach.names[i]) twice = true;
		sent[i] = !twice;
		if (sent[i]) answered++;
	}
	if (answered < 2) return MOTION_GUIDE_UNMATCHED~;

	float[] times = distinct_key_times(clip);
	defer if (times.len > 0) alloc::free(mem, times.ptr);
	float facing = -(named + matched_heading(&facing_forward, &reach, sent));

	DString out;
	out.init(mem);
	defer out.free();
	out.append_string("{\n    \"rest\": {");
	bool first = true;
	foreach (usz i, rest : view.skeleton.joints)
	{
		if (!sent[i]) continue;
		out.appendf("%s\n      ", first ? "" : ",");
		gltf_edit::escape_json_string(&out, reach.names[i]);
		out.append_string(": ");
		append_json_point(&out, turned_about_y(rest, facing));
		first = false;
	}
	out.append_string("\n    },\n    \"keys\": [");
	foreach (t : times)
	{
		int frame = (int)math::round(t * MOTION_FPS);
		if (frame < 0 || frame >= (int)frames) { (*dropped)++; continue; }
		rig::Pose pose = self.evaluated_clip_pose(mem, &view, *clip, ref, t, aimed: true);
		defer pose.free(mem);
		Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
		if (catch palette) continue;
		defer alloc::free(mem, palette);
		out.appendf("%s\n      { \"frame\": %d, \"joints\": {", *keyed > 0 ? "," : "", frame);
		first = true;
		foreach (usz i, rest : view.skeleton.joints)
		{
			if (!sent[i]) continue;
			out.appendf("%s ", first ? "" : ",");
			gltf_edit::escape_json_string(&out, reach.names[i]);
			out.append_string(": ");
			append_json_point(&out, turned_about_y(rest.transform(palette[i]), facing));
			first = false;
		}
		out.append_string(" }");
		bool[4] held;
		if (self.guide_effectors(clip, t, &view, &reach, sent, &held))
		{
			out.append_string(", \"effectors\": [");
			first = true;
			foreach (usz k, name : KIMODO_EFFECTORS)
			{
				if (!held[k]) continue;
				out.appendf(`%s"%s"`, first ? "" : ", ", name);
				first = false;
			}
			out.append_string("]");
			if (partial) (*partial)++;
		}
		out.append_string(" }");
		(*keyed)++;
	}
	out.append_string("\n    ]\n  }");
	if (*keyed == 0) return MOTION_GUIDE_EMPTY~;
	return out.copy_str(mem);
}

<*
 Start generating. Returns at once; `tick_motion_job` does the rest.

 @return? MOTION_NO_GENERATOR : `The config names no text model or motion model.`
 @return? MOTION_NO_GPU : `There is no renderer to run on — a headless AppState.`
 @return? MOTION_BUSY : `A job is already running.`
 @return? MOTION_NO_PROMPT : `The prompt is empty.`
 @return? MOTION_NOT_STARTED : `The folders could not be made or the pipeline would not load; last() says why.`
 @return? MOTION_GUIDE_MISSING : `The guide names no clip of the character.`
 @return? MOTION_GUIDE_UNMATCHED : `The rig does not match Kimodo's skeleton, so a guide cannot be sent.`
 @return? MOTION_GUIDE_EMPTY : `The guide clip has no key inside the generated length.`
*>
fn void? AppState.start_motion_generation(&self, MotionRequest request)
{
	MotionGenerator* g = &self.config.motion_generator;
	if (g.text_model.len == 0 || g.model.len == 0) return MOTION_NO_GENERATOR~;
	if (self.motion_job.running) return MOTION_BUSY~;
	if (!self.motion_gpu) return MOTION_NO_GPU~;
	String prompt = request.prompt.trim();
	if (prompt.len == 0) return MOTION_NO_PROMPT~;
	request.prompt = prompt;

	float seconds = request.seconds > 0.0f ? request.seconds : MOTION_DEFAULT_SECONDS;
	seconds = math::clamp(seconds, MOTION_MIN_SECONDS, MOTION_MAX_SECONDS);
	uint frames = (uint)(seconds * MOTION_FPS + 0.5f);
	if (request.steps > MOTION_MAX_STEPS) request.steps = MOTION_MAX_STEPS;

	// First, so the guide's rest skeleton is on disk to be matched against.
	String plugins = self.motion_plugins_directory();
	defer alloc::free(mem, plugins.ptr);
	if (catch llm::pipeline::extract(plugins))
	{
		self.motion_job.failed = true;
		self.motion_job.set_last(string::tformat("could not write the pipeline's files to %s", plugins));
		return MOTION_NOT_STARTED~;
	}

	String poses = "";
	usz keyed;
	usz dropped;
	usz partial;
	if (request.guide.len > 0)
	{
		String skeleton = string::tformat("%s/%s", plugins, MOTION_GUIDE_SKELETON);
		poses = self.motion_guide_json(request.guide, frames, skeleton, &keyed, &dropped, &partial)!;
	}
	defer if (poses.len > 0) alloc::free(mem, poses.ptr);

	String name = request.name.trim().len > 0 ? request.name.trim().copy(mem) : motion_clip_name(mem, prompt);
	String json = motion_job_json(g, &request, name, frames, poses);
	defer alloc::free(mem, json.ptr);

	self.motion_job.clear();
	self.motion_job.name = name;
	self.motion_job.prompt = prompt.copy(mem);
	self.motion_job.steps = request.steps == 0 ? MOTION_DEFAULT_STEPS : request.steps;
	self.motion_job.guide_keys = keyed;
	self.motion_job.guide_dropped = dropped;
	self.motion_job.guide_partial = partial;

	llm::pipeline::Job* engine = mem::new(llm::pipeline::Job);
	self.motion_job.engine = engine;
	if (catch engine.start(self.motion_gpu, "kimodo", json, plugins, &motion_line, &self.motion_job))
	{
		self.motion_job.failed = true;
		self.motion_job.set_last(engine.error().len > 0 ? engine.error() : "the pipeline would not start");
		self.motion_job.close_engine();
		return MOTION_NOT_STARTED~;
	}
	self.motion_job.running = true;
	if (keyed == 0)
	{
		self.@notice("Generating \"%s\"…", name);
		return;
	}
	String held = partial == 0 ? "" : partial == keyed
		? " (hands and feet only)"
		: string::tformat(" (%d of them hands and feet only)", partial);
	if (dropped > 0)
	{
		self.@notice("Generating \"%s\" through %d pose(s) of \"%s\"%s; %d keyed past %.1f s left out…",
			name, keyed, request.guide, held, dropped, (float)frames / MOTION_FPS);
	}
	else
	{
		self.@notice("Generating \"%s\" through %d pose(s) of \"%s\"%s…", name, keyed, request.guide, held);
	}
}

<*
 One frame of the running job: its progress, and its landing once it exits.
 Driven from `AppRoot.update`; nothing happens when no job runs.
*>
fn void AppState.tick_motion_job(&self)
{
	MotionJob* job = &self.motion_job;
	if (!job.running || !job.engine) return;
	if (job.engine.pump())
	{
		if (job.step > 0) self.@notice("Generating \"%s\"… %d%%", job.name, (int)(job.progress() * 100.0f));
		return;
	}
	bool ok = job.engine.state == DONE;
	if (!ok) job.set_last(job.engine.error().len > 0 ? job.engine.error() : "the pipeline stopped");
	// The engine owns what it was handed; closing it frees that.
	char[] handed = job.engine.output("glb");
	if (ok && handed.len > 0)
	{
		job.glb = alloc::new_array(mem, char, handed.len);
		job.glb[..] = handed[..];
	}
	job.close_engine();
	self.finish_motion_job(ok);
}

<*
 The end of a job: its clip landed on the character when `ok` and the .glb was
 handed back, a failure saying why otherwise (`last()` holds the reason).
*>
fn void AppState.finish_motion_job(&self, bool ok)
{
	MotionJob* job = &self.motion_job;
	job.running = false;
	// The bytes are only the pipeline's way of handing the motion over: once
	// read, they are not kept.
	defer
	{
		if (job.glb.len > 0) alloc::free(mem, job.glb);
		job.glb = {};
	}
	if (!ok || job.glb.len == 0)
	{
		if (ok) job.set_last("the pipeline handed back no clip");
		job.failed = true;
		self.@notice("Generating \"%s\" failed: %s", job.name, job.last());
		return;
	}
	AnimRef landed = self.land_generated_motion(job.glb, job.name);
	if (!landed.valid())
	{
		job.failed = true;
		self.@notice("Generated \"%s\", but it did not read as a clip for this character", job.name);
		return;
	}
	// The landed name, which differs when the authored pack already had this one.
	if (AnimTemplate* clip = self.clip(landed))
	{
		if (clip.name != job.name)
		{
			alloc::free(mem, job.name.ptr);
			job.name = clip.name.copy(mem);
		}
	}
	job.landed = landed;
	job.landed_pending = true;
	self.@notice("Generated \"%s\" and added it to the character · save to keep it in the model", job.name);
}

<*
 Stop the running job and throw away what it had done.

 @return `False when nothing was running.`
*>
fn bool AppState.stop_motion_generation(&self)
{
	MotionJob* job = &self.motion_job;
	if (!job.running) return false;
	job.close_engine();
	job.running = false;
	job.failed = true;
	job.set_last("stopped");
	self.@notice("Stopped generating \"%s\"", job.name);
	return true;
}

<*
 Take a generated .glb, as bytes, onto the character: its clip read, sampled
 onto the rig and authored into the character as one undo step, bound and
 editable like a hand-keyed clip. Nothing refers to the bytes afterwards.

 @return `The clip, or NO_ANIM when the file holds none this rig can take.`
*>
fn AnimRef AppState.land_generated_motion(&self, char[] glb, String name)
{
	AnimTemplate? sampled = self.generated_clip_on_rig(glb, name);
	if (catch sampled) return NO_ANIM;
	AnimRef landed = self.author_clip(sampled);
	if (!landed.valid()) return NO_ANIM;
	self.refresh_ui();
	return landed;
}

<*
 The first clip of a generated .glb, written against this rig rather than
 Kimodo's skeleton: sampled at each of its own keys through the same name match
 playback uses (`measure_reach`, the document's joint maps) and keyed under the
 rig's own joint names, so the authored pack — which has no skeleton of its own
 to translate from — plays it as it is.

 Sampled raw: the rig's joint limits and the ground solve are applied when it
 plays, as for every clip, so they are carried rather than baked in.

 @param name : `The clip's name, made unique against the authored pack.`
 @return? RIG_EMPTY : `There is no rig to put it on.`
 @return? MOTION_NOT_STARTED : `The file holds no clip, or one for a skeleton this rig does not relate to.`
*>
fn AnimTemplate? AppState.generated_clip_on_rig(&self, char[] glb, String name)
{
	RigView view = self.open_rig(mem)!;
	defer view.free(mem);

	AnimPack pack = read_pack(mem, "kimodo.glb", plans: self.reference_plans, bytes: glb)!;
	defer pack.free(mem);
	if (pack.clips.len == 0) return MOTION_NOT_STARTED~;
	AnimTemplate source = pack.clips[0];
	foreach (clip : pack.clips)
	{
		if (clip.name == name) { source = clip; break; }
	}
	if (source.keyframes.len == 0) return MOTION_NOT_STARTED~;

	PackReach reach = measure_reach(mem, &pack, &view.skeleton, view.names);
	defer reach.free(mem);
	apply_joint_maps(mem, &reach, &pack, view.names, self.doc.joint_maps);
	if (!reach.usable || reach.names.len != view.names.len) return MOTION_NOT_STARTED~;

	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	float height = view.skeleton.height();

	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, (sz)source.keyframes.len);
	foreach (usz i, key : source.keyframes)
	{
		rig::Pose pose = source.pose(mem, &view.skeleton, reach.names, key.time, false);
		defer pose.free(mem);
		frames[i] = keyframe_of_pose(mem, pose, view.names, bones, height, key.time);
	}

	// The feet a ground solve plants, renamed into the rig's words; a foot the
	// rig has no joint for is dropped rather than kept naming nothing.
	AnimFootList feet;
	feet.init(mem);
	defer feet.free();
	foreach (foot : source.ground.feet)
	{
		foreach (usz j, spoken : reach.names)
		{
			if (spoken != foot.joint || view.names[j].len == 0) continue;
			AnimFoot renamed = foot;
			renamed.joint = view.names[j].copy(mem);
			feet.push(renamed);
			break;
		}
	}

	String unique = self.unused_clip_name(mem, name.len > 0 ? name : source.name);
	return {
		.name = unique,
		.duration = source.duration,
		.keyframes = frames,
		.loop = source.loop,
		.blend = source.blend,
		.ground = {
			.feet = feet.len() > 0 ? feet.to_array(mem) : (AnimFoot[]){},
			.floor = source.ground.floor,
			.floor_set = source.ground.floor_set,
		},
		.owned = true,
	};
}

<*
 The clip the last job landed, once: the interface selects and plays it.

 @return `False when nothing new has landed since the last call.`
*>
fn bool AppState.take_generated_clip(&self, AnimRef* out)
{
	if (!self.motion_job.landed_pending) return false;
	self.motion_job.landed_pending = false;
	*out = self.motion_job.landed;
	return true;
}

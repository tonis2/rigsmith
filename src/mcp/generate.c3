<*
 generate_motion: text to motion over MCP. The work is `app/generate.c3`; this
 reads the arguments and says how the job stands.

 A generation takes ten to thirty seconds, longer than a tool call should hold
 the window still, so the call starts it and answers at once; the same tool with
 no prompt answers with the progress, and once the job is done, with the clip it
 bound — which is from then on an ordinary bound clip, for play, measure_clip,
 plant_feet and the rest.
*>
module crig;

import std::collections::object;
import gltf_edit;

faultdef GENERATE_REFUSED;

const String GENERATE_MOTION_SCHEMA = `{"type":"object","properties":{
	"prompt":{"type":"string","description":"What the character does, in plain words: one person, one action, a few seconds — \"a person jumps forward and lands\", \"walks in a circle, then sits down\". Omit to ask how the running or last generation stands."},
	"name":{"type":"string","description":"The clip's name. Defaults to the prompt's first words."},
	"seconds":{"type":"number","description":"Length, 1 to 10. Default 5."},
	"seed":{"type":"number","description":"Which take: the same prompt and seed give the same motion. Default 0."},
	"steps":{"type":"number","description":"Diffusion steps. Default 100; fewer is faster and rougher."},
	"poses_from":{"type":"string","description":"A clip bound to the character to guide the motion: every instant it has a key becomes a pose the generated motion passes through at that time, and Kimodo makes the motion between. An instant keyed only on arm and leg joints holds just those hands and feet (and where the hips stand); one with a key on the hips, spine or head holds the whole body. Keys past the length are left out. Make one with apply_clip or solve_targets — a start, an end and a pose or two between — for a motion the prompt alone gets wrong."}
}}`;

fn String? tool_generate_motion(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	String prompt;
	if (args != null && args.is_keyable())
	{
		if (try given = args.get_string("prompt")) prompt = given;
	}
	if (prompt.trim().len == 0) return generation_status_json(app);

	MotionRequest request = { .prompt = prompt };
	if (try name = args.get_string("name")) request.name = name;
	if (try guide = args.get_string("poses_from")) request.guide = guide;
	if (try seconds = args.get_float("seconds"))
	{
		if (!(seconds >= MOTION_MIN_SECONDS && seconds <= MOTION_MAX_SECONDS))
		{
			detail.appendf(`"seconds" is %.9g; a generated clip is %d to %d seconds long.`, seconds, (int)MOTION_MIN_SECONDS, (int)MOTION_MAX_SECONDS);
			return GENERATE_REFUSED~;
		}
		request.seconds = (float)seconds;
	}
	if (try seed = args.get_float("seed"))
	{
		if (seed < 0 || seed > 4294967295.0)
		{
			detail.append_string(`"seed" is a whole number from 0.`);
			return GENERATE_REFUSED~;
		}
		request.seed = (uint)seed;
	}
	if (try steps = args.get_float("steps"))
	{
		if (steps < 1 || steps > MOTION_MAX_STEPS)
		{
			detail.appendf(`"steps" is 1 to %d.`, MOTION_MAX_STEPS);
			return GENERATE_REFUSED~;
		}
		request.steps = (uint)steps;
	}
	if (app.doc.dots.len() == 0)
	{
		detail.append_string("There is no skeleton to put a generated clip on. Rig the model first.");
		return GENERATE_REFUSED~;
	}
	if (catch err = app.start_motion_generation(request))
	{
		switch (err)
		{
			case MOTION_BUSY:
				detail.appendf(`"%s" is still generating (%d%%); one job runs at a time. Call generate_motion with no prompt to follow it.`,
					app.motion_job.name, (int)(app.motion_job.progress() * 100.0f));
			case MOTION_NO_GENERATOR:
				detail.append_string(`Text-to-motion is not set up: the Kimodo weights are not chosen. The user picks the text model and the motion model (.gguf files) in File › Settings › AI (config.json's "motion_generator": "text_model", "model", optional "tokenizer").`);
			case MOTION_NO_GPU:
				detail.append_string("This Rigsmith has no GPU to run the pipeline on.");
			case MOTION_GUIDE_MISSING:
				detail.appendf(`"poses_from" names "%s", which is not a clip bound to this character. get_scene lists the bound clips.`, request.guide);
			case MOTION_GUIDE_UNMATCHED:
				detail.append_string(`This rig does not match Kimodo's human skeleton by shape, so its poses cannot guide a generation. Drop "poses_from".`);
			case MOTION_GUIDE_EMPTY:
				detail.appendf(`"%s" has no key inside the %.3g seconds being generated.`, request.guide,
					request.seconds > 0.0f ? request.seconds : MOTION_DEFAULT_SECONDS);
			default:
				detail.appendf("The pipeline would not start: %s", app.motion_job.last());
		}
		return GENERATE_REFUSED~;
	}
	return generation_status_json(app);
}

<*
 {"state":"running"|"done"|"failed"|"idle", ...}: the job's name and prompt,
 its progress while running, the bound clip once done, the reason once failed.
*>
fn String generation_status_json(AppState* app)
{
	MotionJob* job = &app.motion_job;
	DString out;
	out.init(mem);
	if (job.name.len == 0)
	{
		out.append_string(`{"state":"idle"}`);
	}
	else
	{
		String state = job.running ? "running" : job.failed ? "failed" : "done";
		out.appendf(`{"state":"%s","name":`, state);
		gltf_edit::escape_json_string(&out, job.name);
		out.append_string(`,"prompt":`);
		gltf_edit::escape_json_string(&out, job.prompt);
		if (job.guide_keys > 0) out.appendf(`,"guide_poses":%d,"guide_poses_hands_and_feet_only":%d,"guide_poses_left_out":%d`, job.guide_keys, job.guide_partial, job.guide_dropped);
		if (job.running)
		{
			out.appendf(`,"step":%d,"steps":%d,"note":"Call generate_motion with no prompt to follow it; the clip is bound to the character when it is done."`, job.step, job.steps);
		}
		else if (job.failed)
		{
			out.append_string(`,"reason":`);
			gltf_edit::escape_json_string(&out, job.last());
		}
		else
		{
			AnimTemplate* clip = app.clip(job.landed);
			out.append_string(`,"clip":`);
			gltf_edit::escape_json_string(&out, clip ? clip.name : job.name);
			if (clip) out.appendf(`,"duration":%.4g,"keyframes":%d`, clip.duration, clip.keyframes.len);
			out.append_string(`,"file":`);
			gltf_edit::escape_json_string(&out, job.glb);
			out.append_string(`,"note":"Bound to the character, in place (the importer takes travel off the hips). play, measure_clip and plant_feet take it by name."`);
		}
		out.append_char('}');
	}
	String json = out.copy_str(mem);
	out.free();
	return json;
}

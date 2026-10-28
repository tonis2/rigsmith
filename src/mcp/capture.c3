<*
 capture: the Capture pane's steps for an agent (`app/capture.c3`), the same
 functions behind the same job, so a step started here shows in the pane.

 `{"action": "status"}` says what the character's capture has (its folder,
 finder, reference picture) and what is running. `train` starts a training
 set and the finder's training (`poses`), `use_finder` takes a finder trained
 before (`finder`), `reference` draws the reference picture (`clip`, `time`;
 the rest pose without a clip), `animate` reads a video (`video`, `name`) into
 a clip, `stop` stops the running step. A started step answers at once; ask
 `status` for its progress.
*>
module crig;

import std::collections::object;
import std::io::file;

faultdef CAPTURE_REFUSED;

const String CAPTURE_SCHEMA = `{"type":"object","properties":{
	"action":{"type":"string","enum":["status","train","use_finder","reference","animate","stop"],"description":"What to do."},
	"poses":{"type":"integer","description":"train: the training set's size. Default 1500."},
	"finder":{"type":"string","description":"use_finder: a .safetensors trained before."},
	"clip":{"type":"string","description":"reference: the clip to take the pose from, \"pack/clip\"; the rest pose without."},
	"time":{"type":"number","description":"reference: the clip's moment in seconds. Default 0."},
	"video":{"type":"string","description":"animate: the video the picture was animated into, or a folder of its frames."},
	"name":{"type":"string","description":"animate: the clip's name. Default the video's file name."}
},"required":["action"]}`;

fn String? tool_capture(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `capture takes an object: {"action": "status" | "train" | "use_finder" | "reference" | "animate" | "stop", ...}`)) return CAPTURE_REFUSED~;
	String action;
	if (!required_string(args, "action", &action, detail, `capture needs "action": status, train, use_finder, reference, animate or stop.`)) return CAPTURE_REFUSED~;
	switch (action)
	{
		case "status":
			return capture_status_json(app);
		case "train":
			double poses = (double)CAPTURE_DEFAULT_POSES;
			if (try given = args.get_float("poses")) poses = given;
			if (poses < 50 || poses > 20000)
			{
				detail.appendf(`capture's "poses" is %s; it is from 50 to 20000.`, (JsonFloat)poses);
				return CAPTURE_REFUSED~;
			}
			if (catch err = app.start_capture_training((usz)poses)) return capture_refused(detail, err);
		case "use_finder":
			String finder;
			if (!required_string(args, "finder", &finder, detail, `capture's use_finder needs "finder": a .safetensors trained before.`)) return CAPTURE_REFUSED~;
			if (!file::exists(finder))
			{
				detail.appendf(`"%s" is not there.`, finder);
				return CAPTURE_REFUSED~;
			}
			if (catch err = app.use_capture_finder(finder)) return capture_refused(detail, err);
			app.capture_job.finished++;
		case "reference":
			String clip = "";
			if (member(args, "clip") != null && !required_string(args, "clip", &clip, detail, `capture's "clip" is a clip's name`)) return CAPTURE_REFUSED~;
			replace_owned(&app.capture_draft.pose_clip, clip.len > 0 ? clip : CAPTURE_REST);
			double time = 0;
			if (try given = args.get_float("time")) time = given;
			replace_owned(&app.capture_draft.pose_time, string::tformat("%s", (JsonFloat)time));
			if (catch err = app.request_capture_reference()) return capture_refused(detail, err);
			// MCP calls are answered between frames, where the renderer is free.
			app.draw_capture_reference();
			if (!file::exists(app.capture_path("studio/studio.json")))
			{
				detail.append_string("the reference picture could not be drawn (the notice says why).");
				return CAPTURE_REFUSED~;
			}
		case "animate":
			String video;
			if (!required_string(args, "video", &video, detail, `capture's animate needs "video": the video, or a folder of its frames.`)) return CAPTURE_REFUSED~;
			replace_owned(&app.capture_draft.video, video);
			String name = "";
			if (member(args, "name") != null && !required_string(args, "name", &name, detail, `capture's "name" is the clip's name`)) return CAPTURE_REFUSED~;
			replace_owned(&app.capture_draft.name, name);
			String named = name.len > 0 ? name : capture_clip_name(video);
			if (app.has_bound_clip_named(named))
			{
				detail.appendf(`the character already has a clip called "%s"; give "name".`, named);
				return CAPTURE_REFUSED~;
			}
			if (catch err = app.start_capture_animation()) return capture_refused(detail, err);
		case "stop":
			(void)app.stop_capture();
		default:
			detail.appendf(`capture has no action "%s": status, train, use_finder, reference, animate or stop.`, action);
			return CAPTURE_REFUSED~;
	}
	app.refresh_ui();
	return capture_status_json(app);
}

fn String? capture_refused(DString* detail, fault err) @private
{
	detail.append_string(capture_fault_text(err));
	return CAPTURE_REFUSED~;
}

// What the character's capture has and what is running, as JSON. Owned.
fn String capture_status_json(AppState* app) @private
{
	CaptureJob* job = &app.capture_job;
	DString out = dstring::new(mem);
	defer out.free();
	String finder = app.capture_finder();
	out.append_string(`{"backbone":"`);
	json_escape_into(&out, app.config.motion_generator.creature_model);
	out.append_string(`","folder":"`);
	json_escape_into(&out, app.capture_folder());
	out.append_string(`","finder":"`);
	json_escape_into(&out, finder);
	out.append_string(`","finder_summary":"`);
	json_escape_into(&out, finder_summary(finder));
	bool reference = app.source_path.len > 0 && file::exists(app.capture_path("studio/studio.json"));
	out.appendf(`","reference":%s,"running":%s,"stage":"%s","step":%d,"steps":%d,"failed":%s,"last":"`,
		reference ? "true" : "false", job.running ? "true" : "false", job.stage, job.step, job.steps, job.failed ? "true" : "false");
	json_escape_into(&out, job.last());
	out.append_string(`"}`);
	return out.copy_str(mem);
}

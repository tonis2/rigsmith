<*
 capture: the Capture pane's steps for an agent (`app/capture.c3`), the same
 functions behind the same job, so a step started here shows in the pane.

 `{"action": "status"}` says what the character's capture has (its folder,
 finder, reference picture) and what is running. `train` starts a training
 set and the finder's training (`poses`, `size`), `use_finder` takes a finder trained
 before (`finder`), `reference` draws a reference picture into `references/<name>/`
 (a saved `pose`, or `clip` at `time`; the rest pose without either), `animate` reads
 a video (`video`, `name`, `mirror`, `reference`) into a clip, or one picture in a
 reference's layout (`picture`) into a saved pose, `stop` stops the running step. A started step answers at once; ask
 `status` for its progress.
*>
module crig;

import std::collections::object;
import std::io::file;
import std::collections::list;

faultdef CAPTURE_REFUSED;

const String CAPTURE_SCHEMA = `{"type":"object","properties":{
	"action":{"type":"string","enum":["status","train","use_finder","reference","animate","stop"],"description":"What to do."},
	"poses":{"type":"integer","description":"train: the training set's size. Default 1500."},
	"size":{"type":"integer","description":"train: the pictures' side in pixels: 448, 512, 640, 768, 896 or 1024; bigger finds joints more precisely but trains slower. Default 448."},
	"finder":{"type":"string","description":"use_finder: a .safetensors trained before."},
	"pose":{"type":"string","description":"reference: a saved pose to draw, by name."},
	"clip":{"type":"string","description":"reference: the clip to take the pose from, \"pack/clip\", instead of a saved pose; the rest pose without either."},
	"time":{"type":"number","description":"reference: the clip's moment in seconds. Default 0."},
	"video":{"type":"string","description":"animate: the video the picture was animated into (H.264 .mp4 or .mov, read in Rigsmith), or a folder of its frames."},
	"picture":{"type":"string","description":"animate, instead of video: one .png or .jpg in the reference picture's layout (reference.png edited into a pose); it lands as a saved pose."},
	"name":{"type":"string","description":"animate: the clip's (or pose's) name. Default the video's (or picture's) file name."},
	"reference":{"type":"string","description":"animate: the reference the video or picture was made from, by name as status lists them. Default the one its first frame looks like."},
	"mirror":{"type":"boolean","description":"animate: also read each frame mirrored, so left and right do not swap. Default true; false is about 40% faster at finding joints."}
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
			double size = (double)CAPTURE_DEFAULT_SIZE;
			if (try given = args.get_float("size")) size = given;
			if (size != (double)(uint)size || !capture_size_ok((uint)size))
			{
				detail.appendf(`capture's "size" is %s; it is 448, 512, 640, 768, 896 or 1024.`, (JsonFloat)size);
				return CAPTURE_REFUSED~;
			}
			if (catch err = app.start_capture_training((usz)poses, (uint)size, app.capture_path("renders"), app.capture_path("finder.safetensors"), app.config.motion_generator.creature_model)) return capture_refused(detail, err);
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
			String pose = "";
			if (member(args, "pose") != null && !required_string(args, "pose", &pose, detail, `capture's "pose" is a saved pose's name`)) return CAPTURE_REFUSED~;
			if (pose.len > 0 && app.saved_pose_named(pose) < 0)
			{
				detail.appendf(`there is no saved pose "%s".`, pose);
				return CAPTURE_REFUSED~;
			}
			double time = 0;
			if (try given = args.get_float("time")) time = given;
			String named = capture_reference_name(pose.len > 0 ? pose : clip.len > 0 ? clip : "rest");
			String studio = app.capture_reference_path(named).copy(tmem);
			if (catch err = app.request_capture_reference(studio, clip, (float)time, pose)) return capture_refused(detail, err);
			// MCP calls are answered between frames, where the renderer is free.
			app.draw_capture_reference();
			if (!file::exists(string::tformat("%s/studio.json", studio)))
			{
				detail.append_string("the reference picture could not be drawn (the notice says why).");
				return CAPTURE_REFUSED~;
			}
		case "animate":
			String video;
			bool pose = member(args, "picture") != null;
			if (pose)
			{
				if (!required_string(args, "picture", &video, detail, `capture's "picture" is a .png or .jpg in the reference picture's layout.`)) return CAPTURE_REFUSED~;
			}
			else if (!required_string(args, "video", &video, detail, `capture's animate needs "video": the video, or a folder of its frames (or "picture" for a pose).`))
			{
				return CAPTURE_REFUSED~;
			}
			String name = "";
			if (member(args, "name") != null && !required_string(args, "name", &name, detail, `capture's "name" is the clip's name`)) return CAPTURE_REFUSED~;
			String named = name.len > 0 ? name : capture_clip_name(video);
			if (pose ? app.saved_pose_named(named) >= 0 : app.has_bound_clip_named(named))
			{
				detail.appendf(`the character already has a %s called "%s"; give "name".`, pose ? "pose" : "clip", named);
				return CAPTURE_REFUSED~;
			}
			String reference = "";
			if (member(args, "reference") != null && !required_string(args, "reference", &reference, detail, `capture's "reference" is a reference's name`)) return CAPTURE_REFUSED~;
			bool mirror = true;
			if (member(args, "mirror") != null)
			{
				bool? given = args.get_bool("mirror");
				if (catch given)
				{
					detail.append_string(`capture's "mirror" is true or false.`);
					return CAPTURE_REFUSED~;
				}
				mirror = given;
			}
			if (catch err = app.start_capture_animation(app.config.motion_generator.creature_model, app.capture_finder(), reference.len > 0 ? app.capture_reference_for(reference) : "", video, named, mirror, pose)) return capture_refused(detail, err);
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
	String plugins = app.llm_plugins_directory();
	defer alloc::free(mem, plugins.ptr);
	out.append_string(`","plugins_root":"`);
	json_escape_into(&out, plugins);
	out.append_string(`","folder":"`);
	json_escape_into(&out, app.capture_folder());
	out.append_string(`","finder":"`);
	json_escape_into(&out, finder);
	out.append_string(`","finder_summary":"`);
	json_escape_into(&out, finder_summary(finder));
	List{String} references;
	references.init(tmem);
	app.capture_references(tmem, &references);
	out.append_string(`","references":[`);
	foreach (usz i, name : references)
	{
		out.append_string(i == 0 ? `"` : `,"`);
		json_escape_into(&out, name);
		out.append_string(`"`);
	}
	out.appendf(`],"reference":%s,"running":%s,"stage":"%s","step":%d,"steps":%d,"failed":%s,"last":"`,
		references.len() > 0 ? "true" : "false", job.running ? "true" : "false", job.stage, job.step, job.steps, job.failed ? "true" : "false");
	json_escape_into(&out, job.last());
	out.append_string(`"}`);
	return out.copy_str(mem);
}

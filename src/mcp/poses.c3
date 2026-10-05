<*
 The pose library over MCP: save a pose from a clip, list, read and delete
 them, and `tween_poses` — the brief "start here, end there, fill in between".

 A saved pose is what the UI's Poses panel keeps (`RigDocument.poses`): joint
 names with the same key values a clip holds, so it applies on any clip. Saving
 and deleting go through the panel's own undoable ops (`store_pose`,
 `delete_saved_pose`), so the person sees the pose appear in their list.

 	`save_pose({"name": "Contact", "clip": "Authored/Walk", "t": 0.25})`
 	`tween_poses({"from": "Crouch", "to": "Leap", "duration": 0.6, "name": "Jump"})`
*>
module crig;

import rig;
import std::collections::object;
import std::math;

faultdef POSE_REFUSED;

const String SAVE_POSE_SCHEMA = `{"type":"object","properties":{
	"name":{"type":"string","description":"What to call the pose. A pose of that name is replaced. Empty picks the next free \"Pose N\"."},
	"clip":{"type":"string","description":"Clip to take the pose from, or \"Pack/Clip\"."},
	"t":{"type":"number","description":"Seconds from the clip's start.","default":0},
	"joints":{"type":"array","items":{"type":"string"},"description":"Keep only these joints. Omit for the whole figure."}
},"required":["clip"]}`;

const String TWEEN_POSES_SCHEMA = `{"type":"object","properties":{
	"from":{"type":"string","description":"Saved pose the clip starts on."},
	"to":{"type":"string","description":"Saved pose it reaches."},
	"name":{"type":"string","description":"Name of the clip written into the authored pack."},
	"duration":{"type":"number","description":"Seconds from the first pose to the last.","default":1},
	"back":{"type":"boolean","description":"Return to the first pose at the end (from, to, from), for a cycle or a there-and-back gesture.","default":false},
	"loop":{"type":"boolean","description":"Loop the clip. Implies nothing else; combine with back for a seamless cycle.","default":false},
	"blend":{"type":"string","enum":["linear","smooth"],"default":"smooth"}
},"required":["from","to","name"]}`;

fn sz named_pose(AppState* app, String name, DString* detail)
{
	sz at = app.saved_pose_named(name);
	if (at < 0)
	{
		detail.appendf(`no saved pose is called "%s". list_poses names them.`, name);
	}
	return at;
}

fn String? tool_list_poses(Object* args, void* user_data, DString* detail) @private
	=> poses_json((AppState*)user_data);

fn String poses_json(AppState* app)
{
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"poses":[`);
	foreach (i, pose : app.doc.poses)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"name":`);
		append_json_string(&out, pose.name);
		out.appendf(`,"joints":%d}`, pose.dots.len);
	}
	out.append_string(`]}`);
	return out.copy_str(mem);
}

fn String? tool_get_saved_pose(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `get_saved_pose takes an object: {"pose": name}`)) return POSE_REFUSED~;
	String name;
	if (!required_string(args, "pose", &name, detail, `get_saved_pose needs "pose": a name list_poses reports.`)) return POSE_REFUSED~;
	sz at = named_pose(app, name, detail);
	if (at < 0) return POSE_REFUSED~;

	// The same joint shape get_clip writes, so a pose can be pasted into an
	// apply_clip keyframe as it is.
	AnimKeyframe frame = { .time = 0, .dots = app.doc.poses[at].dots };
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"name":`);
	append_json_string(&out, app.doc.poses[at].name);
	out.append_string(`,"joints":[`);
	foreach (d, dot : frame.dots)
	{
		if (d > 0) out.append_char(',');
		out.append_string(`{"name":`);
		append_json_string(&out, dot.joint_name);
		if (dot.channels != TRANSLATION)
		{
			out.appendf(`,"rotation":{"axis":%s,"angle":%s}`, (JsonVec3)dot.axis, (JsonFloat)dot.angle)!!;
		}
		if (dot.channels != ROTATION) out.appendf(`,"move":%s`, (JsonVec3)dot.move)!!;
		out.append_char('}');
	}
	out.append_string(`]}`);
	return out.copy_str(mem);
}

fn String? tool_save_pose(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `save_pose takes an object: {"name": string, "clip": name, "t": seconds, "joints": [names]}`)) return POSE_REFUSED~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `save_pose needs "clip": the clip to take the pose from.`)) return POSE_REFUSED~;
	double t = args.get_float("t") ?? 0.0;
	String name = args.get_string("name") ?? "";

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	AnimTemplate* template = app.clip(ref);
	if (!template)
	{
		detail.appendf(`"%s" resolved to no clip.`, clip_name);
		return POSE_REFUSED~;
	}
	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(`this document has no dots, so there is no rig to take a pose from.`);
		return POSE_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	rig::Pose pose = app.evaluated_clip_pose(mem, &view, *template, ref, (float)t, false);
	defer pose.free(mem);
	Vec3[] bones = view.skeleton.bone_directions(mem);
	defer if (bones.len > 0) alloc::free(mem, bones);
	AnimKeyframe every = keyframe_of_pose(mem, pose, view.names, bones, view.skeleton.height(), (float)t);

	AnimKeyDot[] dots = every.dots;
	Object* only = member(args, "joints");
	if (only != null && only.is_array())
	{
		AnimDotList kept;
		kept.init(mem);
		defer kept.free();
		foreach (dot : every.dots)
		{
			bool keep;
			for (sz i = 0; i < only.get_len(); i++)
			{
				Object* entry = only.get_at(i);
				if (entry.is_string() && entry.s == dot.joint_name) keep = true;
			}
			if (keep) { kept.push(dot); }
			else if (dot.joint_name.len > 0) alloc::free(mem, dot.joint_name.ptr);
		}
		if (every.dots.len > 0) alloc::free(mem, every.dots);
		dots = kept.to_array(mem);
	}
	if (dots.len == 0)
	{
		detail.append_string(`the pose holds no joints: none of "joints" is a named joint of this rig. get_skeleton names them.`);
		return POSE_REFUSED~;
	}

	name = name.trim();
	SavedPose made = { .name = name.len > 0 ? name.copy(mem) : app.next_pose_name(mem), .dots = dots };
	sz at = app.store_pose(made);
	app.pose_library_row = (usz)at;
	return poses_json(app);
}

fn String? tool_delete_pose(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `delete_pose takes an object: {"pose": name}`)) return POSE_REFUSED~;
	String name;
	if (!required_string(args, "pose", &name, detail, `delete_pose needs "pose": a name list_poses reports.`)) return POSE_REFUSED~;
	sz at = named_pose(app, name, detail);
	if (at < 0) return POSE_REFUSED~;
	app.delete_saved_pose((usz)at);
	return poses_json(app);
}

<*
 Two saved poses become a clip: from at 0, to at `duration`, and with `back`
 from again at the end. The joints of both are keyed; one named by only one pose
 is keyed there and interpolated as the clip does for any sparse track.
*>
fn String? tool_tween_poses(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `tween_poses takes an object: {"from": pose, "to": pose, "name": clip, "duration": seconds, "back": bool, "loop": bool, "blend": "linear"|"smooth"}`)) return POSE_REFUSED~;
	String from_name, to_name, name;
	if (!required_string(args, "from", &from_name, detail, `tween_poses needs "from": the saved pose to start on.`)) return POSE_REFUSED~;
	if (!required_string(args, "to", &to_name, detail, `tween_poses needs "to": the saved pose to reach.`)) return POSE_REFUSED~;
	if (!required_string(args, "name", &name, detail, `tween_poses needs "name": what to call the clip.`)) return POSE_REFUSED~;
	if (name.trim().len == 0)
	{
		detail.append_string(`"name" is empty. A clip is addressed by name.`);
		return POSE_REFUSED~;
	}
	sz from = named_pose(app, from_name, detail);
	if (from < 0) return POSE_REFUSED~;
	sz to = named_pose(app, to_name, detail);
	if (to < 0) return POSE_REFUSED~;

	double duration = args.get_float("duration") ?? 1.0;
	if (!(duration > 0.0) || duration > 600.0)
	{
		detail.appendf(`"duration" is %.9g. It is seconds, above zero.`, duration);
		return POSE_REFUSED~;
	}
	bool back = args.get_bool("back") ?? false;
	String blend = args.get_string("blend") ?? "smooth";
	if (blend != "linear" && blend != "smooth")
	{
		detail.append_string(`"blend" is "linear" or "smooth".`);
		return POSE_REFUSED~;
	}

	usz count = back ? 3 : 2;
	AnimTemplate clip = {
		.name = name.trim().copy(mem),
		.duration = (float)duration,
		.keyframes = alloc::new_array(mem, AnimKeyframe, (sz)count),
		.loop = args.get_bool("loop") ?? false,
		.blend = blend == "linear" ? LINEAR : SMOOTH,
		.owned = true,
	};
	SavedPose[] poses = app.doc.poses;
	sz[3] order = { from, to, from };
	float[3] times = back ? (float[3]){ 0, (float)duration * 0.5f, (float)duration } : (float[3]){ 0, (float)duration, 0 };
	for (usz i = 0; i < count; i++)
	{
		AnimKeyframe source = { .time = times[i], .dots = poses[order[i]].dots };
		clip.keyframes[i] = keyframe_copy(mem, source);
	}

	bool replaced;
	AnimRef landed = app.author_clip(clip, &replaced);
	app.refresh_ui();
	return applied_json(app, landed, replaced);
}

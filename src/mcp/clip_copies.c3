<*
 duplicate_clip: a clip copied under a new name in the authored pack.

 What the Animations pane's Duplicate does, reachable from the wire: the copy
 keeps everything the clip carries — keys, layers, ground spec, pins and aims —
 so a variant can be tried without touching the original. A library clip comes
 over in this rig's own joint names, as a fork does.
*>
module crig;

import std::collections::object;

const String DUPLICATE_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip to copy, or \"Pack/Clip\"."},
	"name":{"type":"string","description":"What to call the copy in the authored pack. Default \"<clip> copy\", made unique. A name the authored pack already holds is refused rather than overwritten."}
},"required":["clip"]}`;

<*
 duplicate_clip: copy the clip and bind the copy, one undo step.

 @return? CLIP_INVALID : `The reason is in detail.`
*>
fn String? duplicate_clip_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `duplicate_clip takes an object: {"clip": name, "name": new name}`)) return CLIP_INVALID~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `duplicate_clip needs "clip": the clip to copy. get_scene lists every pack and clip.`)) return CLIP_INVALID~;

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string(`this clip could not be read back to copy.`);
		return CLIP_INVALID~;
	}
	AnimTemplate* src = app.clip(ref);
	if (!src)
	{
		detail.appendf(`"%s" resolved to no clip. get_scene lists every pack and clip.`, clip_name);
		return CLIP_INVALID~;
	}

	String name;
	if (try given = args.get_string("name"))
	{
		if (given.len == 0)
		{
			detail.append_string(`"name" is empty. Leave it out for "<clip> copy".`);
			return CLIP_INVALID~;
		}
		if (app.clip_named_in_authored(given).valid())
		{
			detail.appendf(`the authored pack already has a clip called "%s". Choose another name, or delete_clip it first.`, given);
			return CLIP_INVALID~;
		}
		name = given.copy(mem);
	}
	else
	{
		name = app.unused_clip_name(mem, string::tformat("%s copy", src.name));
	}
	defer name.free(mem);

	// In this rig's joint names, so the copy of a library clip is addressable by
	// the names the rig reports.
	AnimTemplate copy = app.in_rig_words(clip_copy(mem, *src, name), ref);
	AnimRef landed = app.author_clip(copy);
	if (!landed.valid())
	{
		detail.append_string(`the copy did not land in the authored pack.`);
		return CLIP_INVALID~;
	}
	app.refresh_ui();
	return applied_json(app, landed, false);
}

fn String? tool_duplicate_clip(Object* args, void* user_data, DString* detail)
	=> duplicate_clip_json((AppState*)user_data, args, detail);

const String BLEND_IN_SCHEMA = `{"type":"object","properties":{
	"name":{"type":"string","description":"The new clip's name in the authored pack. A name the authored pack already holds is refused rather than overwritten."},
	"clip":{"type":"string","description":"The clip to blend into, or \"Pack/Clip\" — a walk, a run, an idle. Its layers are baked into the new clip's keys."},
	"from":{"type":"string","description":"The pose to start from: \"rest\" (the default — a T-pose, on a rig that rests in one) or a saved pose's name (list_poses). A joint the pose does not name starts at rest."},
	"phase":{"type":"number","description":"Where in the clip's cycle the blend lands, 0 to 1. Default 0. Landing where a foot is passing under the body rather than reaching for the floor keeps the first step short."},
	"hold":{"type":"number","description":"Seconds the start pose holds before the blend. Default 0."},
	"blend":{"type":"number","description":"Seconds from the start pose to the clip, eased at both ends. Default 0.6."},
	"cycles":{"type":"number","description":"How much of a looping clip follows the blend, in cycles. Default 2. A clip that does not loop plays to its end."}
},"required":["name","clip"]}`;

<*
 blend_in: a one-shot clip that starts from the rest pose or a saved pose and
 eases into another clip, then follows it — one undo step.

 @return? CLIP_INVALID : `The reason is in detail.`
*>
fn String? blend_in_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `blend_in takes an object: {"name": new clip, "clip": clip to blend into, "from": "rest" or a saved pose, "phase": 0 to 1, "hold": seconds, "blend": seconds, "cycles": n}`)) return CLIP_INVALID~;
	String? named = args.get_string("name");
	if (catch named)
	{
		detail.append_string(`blend_in needs "name": what to call the new clip.`);
		return CLIP_INVALID~;
	}
	String name = named;
	if (name.len == 0 || app.clip_named_in_authored(name).valid())
	{
		detail.appendf(name.len == 0 ? `"name" is empty.` : `the authored pack already has a clip called "%s". Choose another name, or delete_clip it first.`, name);
		return CLIP_INVALID~;
	}
	String? target_name = args.get_string("clip");
	if (catch target_name)
	{
		detail.append_string(`blend_in needs "clip": the clip to blend into. get_scene lists every pack and clip.`);
		return CLIP_INVALID~;
	}
	AnimRef ref = resolve_named(app, target_name, detail)!;
	if (!app.ensure_clip_imported(ref) || !app.clip(ref))
	{
		detail.append_string(`this clip could not be read back.`);
		return CLIP_INVALID~;
	}

	BlendIn spec = { .phase = 0.0f, .hold = 0.0f, .blend = 0.6f, .cycles = 2.0f };
	if (!blend_number(args, "phase", 0.0, 1.0, &spec.phase, detail)) return CLIP_INVALID~;
	if (!blend_number(args, "hold", 0.0, 60.0, &spec.hold, detail)) return CLIP_INVALID~;
	if (!blend_number(args, "blend", 0.01, 60.0, &spec.blend, detail)) return CLIP_INVALID~;
	if (!blend_number(args, "cycles", 0.0, 100.0, &spec.cycles, detail)) return CLIP_INVALID~;

	AnimKeyDot[] start = {};
	String from = args.get_string("from") ?? "rest";
	if (from != "rest")
	{
		sz pose = app.saved_pose_named(from);
		if (pose < 0)
		{
			detail.appendf(`"from" is "%s", which is not "rest" or a saved pose. list_poses names the saved ones.`, from);
			return CLIP_INVALID~;
		}
		start = app.doc.poses[(usz)pose].dots;
	}

	// The clip with its layers baked in and in this rig's joint names: a layer
	// reads the clip's own clock, which the new clip does not share.
	AnimTemplate? flattened = app.flattened_clip(ref);
	if (catch flattened)
	{
		detail.append_string(`blend_in needs a rig: the clip's layers are read against its joints.`);
		return CLIP_INVALID~;
	}
	AnimTemplate target = app.in_rig_words(flattened, ref);
	defer target.free(mem);

	AnimTemplate made = clip_blended_in(mem, target, start, name, spec);
	AnimRef landed = app.author_clip(made);
	if (!landed.valid())
	{
		detail.append_string(`the new clip did not land in the authored pack.`);
		return CLIP_INVALID~;
	}
	app.refresh_ui();
	return applied_json(app, landed, false);
}

// One optional number argument, refused outside [least, most].
fn bool blend_number(Object* args, String key, double least, double most, float* into, DString* detail) @local
{
	if (member(args, key) == null) return true;
	double? given = args.get_float(key);
	if (catch given)
	{
		detail.appendf(`"%s" must be a number.`, key);
		return false;
	}
	if (given < least || given > most)
	{
		detail.appendf(`"%s" is %.9g. It is %.9g to %.9g.`, key, given, least, most);
		return false;
	}
	*into = (float)given;
	return true;
}

fn String? tool_blend_in(Object* args, void* user_data, DString* detail)
	=> blend_in_json((AppState*)user_data, args, detail);

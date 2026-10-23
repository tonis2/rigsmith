<*
 The path tools: `get_paths` reads a clip's motion paths, `set_path` changes them.

 A path is a curve a joint follows (anim/path.c3): `points` it runs through and
 `slices`, each saying where along it (`u`, 0..1 by length) the joint is at a
 `time`. It is solved live with the clip's pins and baked into keys on export.
 Each `set_path` call is one undo step.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

faultdef PATH_REFUSED;

const String GET_PATHS_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."}
}}`;

const String SET_PATH_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline. A library clip is forked into the authored pack first."},
	"op":{"type":"string","description":"\"add\" (the default) adds \"path\"; \"replace\" changes the path at \"index\" (fields left out keep their value); \"remove\" takes it off; \"from_motion\" adds a path through where \"joint\" goes in the clip now, a point and a slice every eighth of a second, closed on a looping clip — drag its points afterwards to reshape the motion; \"bake\" writes every path into the keys of the joints it bends and takes the paths off."},
	"index":{"type":"integer","description":"For replace and remove: which path."},
	"joint":{"type":"string","description":"For from_motion: the joint."},
	"path":{"type":"object","description":"For add and replace.","properties":{
		"joint":{"type":"string","description":"The joint that follows the curve; its limb (the unbranched run above it) bends to put it there."},
		"name":{"type":"string"},
		"points":{"type":"array","description":"[{\"at\":[x,y,z], \"sharp\":bool}] the curve runs through, model space as fractions of the rig's height. A sharp point has no tangent: two in a row are joined by a straight line.","items":{"type":"object"}},
		"closed":{"type":"boolean","description":"The curve runs from its last point back to its first. On a looping clip the joint then runs on from the last slice into the first, forward."},
		"slices":{"type":"array","description":"[{\"time\":s, \"u\":0..1, \"tag\":\"down\"|\"up\"}]: at time the joint is u of the way along the curve by length; between two slices it moves at a steady speed. tag marks a foot coming down or lifting.","items":{"type":"object"}},
		"from":{"type":"number","description":"Seconds the path starts holding; with to. Omit both for the whole clip."},
		"to":{"type":"number"},
		"blend":{"type":"number","description":"Seconds it eases in and out at the ends of its window."},
		"mute":{"type":"boolean"},
		"follow":{"type":"boolean","description":"The joint turns as the curve turns: it keeps the world orientation its keys give it, turned by however much the curve has turned since its start (the least turn, so the curve's twist about itself is not added; a closed curve comes round untwisted). Its limb still bends to carry it."}
	}}
}}`;

fn AnimRef? path_clip(AppState* app, Object* args, DString* detail) @local
{
	String name = args.get_string("clip") ?? "";
	AnimRef ref = name.len > 0 ? resolve_named(app, name, detail)! : app.editing;
	if (!ref.valid() || !app.ensure_clip_imported(ref) || app.clip(ref) == null)
	{
		detail.append_string(`no clip: name one with "clip", or open one in the timeline. get_scene lists them.`);
		return PATH_REFUSED~;
	}
	return ref;
}

fn String paths_answer(AppState* app, AnimRef ref, String op) @local
{
	AnimTemplate* clip = app.clip(ref);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, clip.name);
	if (op.len > 0) out.appendf(`,"op":"%s"`, op)!!;
	out.append_string(`,"paths":[`);
	foreach (usz i, &path : clip.paths)
	{
		if (i > 0) out.append_char(',');
		out.appendf(`{"index":%d,`, i)!!;
		append_path_fields(&out, path);
		out.append_char('}');
	}
	out.append_string("]}");
	return out.copy_str(mem);
}

fn String? get_paths_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `get_paths takes an object: {"clip": name}`)) return PATH_REFUSED~;
	return paths_answer(app, path_clip(app, args, detail)!, "");
}

fn String? set_path_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `set_path takes an object: {"clip": name, "op": "add"|"replace"|"remove"|"from_motion"|"bake", "path": {...}}`)) return PATH_REFUSED~;
	AnimRef ref = path_clip(app, args, detail)!;
	String op = args.get_string("op") ?? "add";
	AnimTemplate* clip = app.clip(ref);
	switch (op)
	{
		case "add":
		case "replace":
			Object* spec = member(args, "path");
			if (spec == null || !spec.is_keyable())
			{
				detail.appendf(`"%s" needs "path": an object with "joint", "points" and "slices"`, op);
				return PATH_REFUSED~;
			}
			sz at = -1;
			AnimPath path;
			if (op == "replace")
			{
				at = (sz)(args.get_float("index") ?? -1.0);
				if (at < 0 || (usz)at >= clip.paths.len)
				{
					detail.appendf(`"index" must name one of the clip's %d paths`, clip.paths.len);
					return PATH_REFUSED~;
				}
				path = clip.paths[(usz)at].copy(mem);
			}
			if (!read_path_fields(spec, mem, &path, detail))
			{
				path.free(mem);
				return PATH_REFUSED~;
			}
			if (!app.has_dot_named(path.joint))
			{
				detail.appendf(`path "joint" is "%s", which is not a dot on this rig`, path.joint);
				append_addressable(detail, app, path.joint);
				path.free(mem);
				return PATH_REFUSED~;
			}
			// Edited from outside: no longer what a gait laid.
			if (member(spec, "generated") == null) path.generated = false;
			bool landed = op == "add" ? app.add_path(ref, path) >= 0 : app.replace_path(ref, (usz)at, path);
			if (!landed)
			{
				detail.append_string(`the clip would not land.`);
				return PATH_REFUSED~;
			}
		case "remove":
			sz at = (sz)(args.get_float("index") ?? -1.0);
			if (at < 0 || (usz)at >= clip.paths.len)
			{
				detail.appendf(`"index" must name one of the clip's %d paths`, clip.paths.len);
				return PATH_REFUSED~;
			}
			if (!app.remove_path(ref, (usz)at))
			{
				detail.append_string(`the clip would not land.`);
				return PATH_REFUSED~;
			}
		case "from_motion":
			String joint = args.get_string("joint") ?? "";
			if (!app.has_dot_named(joint))
			{
				detail.appendf(`from_motion needs "joint", a dot on this rig; "%s" is not one`, joint);
				append_addressable(detail, app, joint);
				return PATH_REFUSED~;
			}
			AnimPath? made = app.path_from_motion(ref, joint);
			if (catch made)
			{
				detail.append_string(`the joint's motion could not be read: is there a rig, and does the clip have a length?`);
				return PATH_REFUSED~;
			}
			if (app.add_path(ref, made) < 0)
			{
				detail.append_string(`the clip would not land.`);
				return PATH_REFUSED~;
			}
		case "bake":
			bool? baked = app.bake_paths(ref);
			if (catch baked)
			{
				detail.append_string(`baking needs a rig: the paths are solved against its joints.`);
				return PATH_REFUSED~;
			}
			if (!baked)
			{
				detail.append_string(`the clip has no playing path to bake.`);
				return PATH_REFUSED~;
			}
		default:
			detail.appendf(`"op" is "%s". It is "add", "replace", "remove", "from_motion" or "bake".`, op);
			return PATH_REFUSED~;
	}
	app.refresh_ui();
	return paths_answer(app, app.editing.valid() ? app.editing : ref, op);
}

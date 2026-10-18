<*
 The layer tools: `set_layer` edits a clip's stack, `merge_layers` bakes it.

 A layer is an adjustment laid over a clip's own keys — see anim/layers.c3 for
 what one is and how it composes. Two ways in over the wire:

 - `apply_clip` takes an optional `layers` array and `get_clip` reports one, in
   the shape below, so a clip read and written back keeps its stack. Left out of
   apply_clip, the clip of that name already in the authored pack keeps its
   layers; an empty array clears them.
 - `set_layer` changes one layer without resending the clip: add, replace,
   remove or move. Each call is one undo step.

 **The wire shape of a layer.** The scalar fields of anim/layers.c3's
 `append_layer_fields`, plus for a keyed layer `keyframes`, in exactly the shape
 apply_clip's own keyframes take (rotation as a quaternion, axis/angle or euler;
 move as a fraction of height) — additive values are deltas from rest.

 **`merge_layers` is the exit.** It samples the unmuted stack into the clip's own
 keys and clears the layers, for a clip that should stop being layered: what is
 left is ordinary keys that any tool reads.
*>
module crig;

import rig;
import std::collections::object;
import std::math;

faultdef LAYER_REFUSED;

const String SET_LAYER_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip whose stack to change. A clip from a library file is forked into the authored pack first, as apply_clip does."},
	"op":{"type":"string","description":"\"add\" (the default) puts a layer in the stack, \"replace\" changes one, \"remove\" takes one out, \"move\" reorders. The stack applies bottom to top: index 0 first. \"extract\" lifts the keys of \"joints\" (each with every joint below it) out of the base into a new full-weight override layer at the bottom, the pose unchanged — a tail made a layer of its own. \"share\" gives the layer (index or name) to the clips in \"clips\", linked: an edit of any copy is an edit of all, each clip keeping its own weight, range and fit. \"unlink\" makes this clip's copy its own again."},
	"index":{"type":"integer","description":"Which layer to replace, remove or move; for add, where to insert (default: on top). Instead of an index, name the layer with \"name\"."},
	"name":{"type":"string","description":"Names the layer to replace, remove or move, when no index is given."},
	"to":{"type":"integer","description":"For move: the index the layer ends up at."},
	"joints":{"type":"array","items":{"type":"string"},"description":"For extract: the dots whose keys to lift, each taking every joint below it. \"name\" then names the new layer (default \"<joint> motion\")."},
	"clips":{"type":"array","items":{"type":"string"},"description":"For share: the clips to give the layer to, or \"Pack/Clip\". A library clip is forked first."},
	"fit":{"type":"string","description":"For share: how the layer's own length meets each clip's: \"stretch\" (the default; spread over the clip, so a cycle stays one cycle), \"keep\" (its own seconds, holding its last pose) or \"repeat\" (its own seconds, over and over)."},
	"layer":{"type":"object","description":"The layer, for add and replace. On replace, fields left out keep their current value, so {\"mute\":true} is a mute. name is required on add.","properties":{
		"name":{"type":"string"},
		"kind":{"type":"string","description":"\"keyed\" (sparse keys, in keyframes), or a generator: \"wave\" (a sine down a chain of joints, each trailing the last), \"noise\" (three seeded sines, loops seamlessly) or \"pulse\" (one bump at a moment)."},
		"mode":{"type":"string","description":"\"additive\" (the default) adds on top of what is underneath; keyed additive values are deltas from rest, identity and zero meaning no change. \"override\" blends what is underneath toward the layer, only on channels the layer keys or drives."},
		"weight":{"type":"number","description":"0 to 1, default 1."},
		"mute":{"type":"boolean","description":"Silences the layer everywhere, exports included."},
		"solo":{"type":"boolean","description":"While any layer is solo only solo layers play in crig. An export ignores solo and goes by mute alone."},
		"start":{"type":"number","description":"Seconds the layer is active from; with end. Omit both for the whole clip."},
		"end":{"type":"number","description":"Seconds the layer is active until."},
		"fade_in":{"type":"number","description":"Seconds to ramp in from the start of the range (or of the clip)."},
		"fade_out":{"type":"number","description":"Seconds to ramp out before its end."},
		"mask":{"type":"array","items":{"type":"string"},"description":"Joints the layer touches, each including everything below it. Empty or omitted is the whole body."},
		"keyframes":{"type":"array","description":"A keyed layer's keys, in apply_clip's keyframe shape: [{\"time\":s,\"joints\":[{\"name\":dot,\"rotation\":...,\"move\":[x,y,z]}]}]."},
		"joint":{"type":"string","description":"A generator's first joint. The chain runs down from it through every joint with one child, or to tip."},
		"tip":{"type":"string","description":"A generator's last joint, below joint; needed only at a fork."},
		"axis":{"type":"array","items":{"type":"number"},"description":"[x,y,z], the local axis a generator turns about. Default [1,0,0]."},
		"amplitude":{"type":"number","description":"Radians."},
		"cycles":{"type":"number","description":"Wave and noise: turns per clip duration. Rounded to a whole number on a looping clip so it closes seamlessly."},
		"lag":{"type":"number","description":"Wave: fraction of a cycle each joint down the chain trails the one above."},
		"falloff":{"type":"number","description":"Wave: amplitude multiplier per joint down the chain; above 1 grows toward the tip."},
		"phase":{"type":"number","description":"Wave: fraction of a cycle."},
		"seed":{"type":"integer","description":"Noise: the seed."},
		"at":{"type":"number","description":"Pulse: the moment, in seconds."},
		"width":{"type":"number","description":"Pulse: its width in seconds."},
		"fit":{"type":"string","description":"A shared layer's fit in this clip: \"stretch\", \"keep\" or \"repeat\". Each clip has its own."},
		"link":{"type":"string","description":"Read only in practice: the id every clip sharing this layer holds. Set by op share."},
		"length":{"type":"number","description":"A shared layer's own length in seconds, which its keys' times are on. Set by op share."}
	}}
},"required":["clip"]}`;

const String MERGE_LAYERS_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip whose layers to bake into its keys."}
},"required":["clip"]}`;

<*
 A layer's joint names, checked against the rig; the reason in `detail`.
*>
fn bool layer_names_known(AppState* app, AnimLayer* layer, DString* detail) @local
{
	if (layer.procedural())
	{
		if (!app.has_dot_named(layer.joint))
		{
			detail.appendf(`layer "joint" is "%s", which is not a dot on this rig`, layer.joint);
			append_addressable(detail, app, layer.joint);
			return false;
		}
		if (layer.tip.len > 0 && !app.has_dot_named(layer.tip))
		{
			detail.appendf(`layer "tip" is "%s", which is not a dot on this rig`, layer.tip);
			append_addressable(detail, app, layer.tip);
			return false;
		}
	}
	foreach (entry : layer.mask)
	{
		if (app.has_dot_named(entry)) continue;
		detail.appendf(`layer "mask" names "%s", which is not a dot on this rig`, entry);
		append_addressable(detail, app, entry);
		return false;
	}
	return true;
}

<*
 One layer object read on top of `layer` (defaults, or the layer being replaced),
 joint names checked and any keyframes parsed through `parse_clip`.

 @param layer : `Owned by the caller on both outcomes.`
 @return `False with the reason in detail.`
*>
fn bool parse_layer(AppState* app, Object* obj, AnimLayer* layer, float clip_duration, DString* detail)
{
	if (!read_layer_fields(obj, mem, layer, detail)) return false;
	if (!layer_names_known(app, layer, detail)) return false;

	Object* keys = member(obj, "keyframes");
	if (keys != null)
	{
		if (layer.procedural())
		{
			detail.append_string(`a "wave", "noise" or "pulse" layer is generated and takes no "keyframes"`);
			return false;
		}
		AnimTemplate? read = parse_clip(app, obj, detail, clip_duration);
		if (catch read) return false;
		AnimTemplate parsed = read;
		// Only the keys are wanted; the rest of the parsed clip is scaffolding.
		foreach (&frame : layer.keyframes) frame.free(mem);
		if (layer.keyframes.len > 0) alloc::free(mem, layer.keyframes);
		layer.keyframes = parsed.keyframes;
		parsed.keyframes = {};
		parsed.free(mem);
	}
	if (layer.kind == KEYED && layer.keyframes.len == 0)
	{
		detail.append_string(`a keyed layer needs "keyframes": a non-empty array in apply_clip's shape. For a generator, set "kind" to "wave", "noise" or "pulse" and name the "joint" it drives.`);
		return false;
	}
	return true;
}

<*
 A `layers` array read into a fresh stack, replacing whatever `into` held.

 @return `False with the reason in detail; into keeps what it held.`
*>
fn bool parse_layers(AppState* app, Object* layers, float clip_duration, AnimLayer[]* into, DString* detail)
{
	if (!layers.is_array())
	{
		detail.append_string(`"layers" must be an array of layer objects; an empty array clears the stack`);
		return false;
	}
	usz count = (usz)layers.get_len();
	AnimLayer[] built = alloc::new_array(mem, AnimLayer, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		built[i] = anim_layer_defaults("");
		Object* entry = layers.get_at((sz)i);
		DString why = dstring::new(mem);
		defer why.free();
		if (!parse_layer(app, entry, &built[i], clip_duration, &why))
		{
			detail.appendf("layers[%d]: %s", i, why.str_view());
			free_layers(mem, built);
			return false;
		}
	}
	free_layers(mem, *into);
	*into = built;
	return true;
}

<*
 A stack as JSON, bottom first: each layer's fields and, for a keyed one, its
 keyframes.
*>
fn void append_layers_json(DString* out, AnimLayer[] layers)
{
	out.append_char('[');
	foreach (usz i, &layer : layers)
	{
		if (i > 0) out.append_char(',');
		out.append_char('{');
		append_layer_fields(out, layer);
		if (!layer.procedural())
		{
			out.append_string(`,"keyframes":`);
			append_keyframes_json(out, layer.keyframes);
		}
		out.append_char('}');
	}
	out.append_char(']');
}

// Which layer an op means: `index`, else `name`. -1 with the reason in detail.
fn sz which_layer(AnimTemplate* clip, Object* args, DString* detail) @local
{
	if (member(args, "index") != null)
	{
		double? given = args.get_float("index");
		if (catch given)
		{
			detail.append_string(`"index" must be a whole number`);
			return -1;
		}
		if (given < 0 || given >= (double)clip.layers.len)
		{
			detail.appendf(`"index" is %.9g but the clip has %d layers (0 to %d)`, given, clip.layers.len, clip.layers.len);
			return -1;
		}
		return (sz)given;
	}
	String? named = args.get_string("name");
	if (try named)
	{
		foreach (usz i, &layer : clip.layers) if (layer.name == named) return (sz)i;
		detail.appendf(`the clip has no layer called "%s"`, named);
		return -1;
	}
	detail.append_string(`name the layer with "index" or "name"`);
	return -1;
}

fn String layers_answer(AppState* app, AnimRef ref, String op) @local
{
	AnimTemplate* clip = app.clip(ref);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, clip.name);
	out.appendf(`,"op":"%s","layers":`, op)!!;
	append_layers_json(&out, clip.layers);
	append_metrics_member(&out, app, ref);
	out.append_char('}');
	return out.copy_str(mem);
}

<*
 set_layer: add, replace, remove or move one layer of a clip's stack.

 One undo step: the whole clip is swapped, layers included.

 @return? LAYER_REFUSED : `The reason is in detail.`
*>
fn String? set_layer_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `set_layer takes an object: {"clip": name, "op": "add"|"replace"|"remove"|"move", "index": n, "layer": {...}}`)) return LAYER_REFUSED~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `set_layer needs "clip": the clip whose stack to change. get_scene lists every pack and clip.`)) return LAYER_REFUSED~;
	String op = args.get_string("op") ?? "add";
	if (op != "add" && op != "replace" && op != "remove" && op != "move" && op != "extract" && op != "share" && op != "unlink")
	{
		detail.appendf(`"op" is "%s". It is "add", "replace", "remove", "move", "extract", "share" or "unlink".`, op);
		return LAYER_REFUSED~;
	}

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string(`this clip could not be read back to edit.`);
		return LAYER_REFUSED~;
	}
	if (app.clip(ref) == null || app.clip(ref).keyframes.len == 0)
	{
		detail.append_string(`this clip has no keys to lay a layer over.`);
		return LAYER_REFUSED~;
	}

	if (op == "extract") return extract_layer_json(app, ref, args, detail);
	if (op == "share" || op == "unlink") return share_layer_json(app, ref, op, args, detail);

	// The layer names the rig's joints, and the clip lands in the authored pack,
	// which speaks the rig's words: a library clip spelt another way is respelt.
	AnimTemplate spelt = app.clip_in_rig_words(ref);
	defer spelt.free(mem);
	AnimTemplate* src = &spelt;

	Object* spec = member(args, "layer");
	if ((op == "add" || op == "replace") && (spec == null || !spec.is_keyable()))
	{
		detail.appendf(`"%s" needs "layer": an object describing the layer`, op);
		return LAYER_REFUSED~;
	}

	// The new stack is built aside and only swapped in on success, so a refusal
	// touches nothing.
	usz count = src.layers.len;
	AnimLayer[] next = layers_copy(mem, src.layers);
	bool landed = false;
	defer if (!landed) free_layers(mem, next);

	if (op == "add")
	{
		AnimLayer layer = anim_layer_defaults("");
		if (!parse_layer(app, spec, &layer, src.duration, detail))
		{
			layer.free(mem);
			return LAYER_REFUSED~;
		}
		usz at = count;
		if (member(args, "index") != null)
		{
			double given = args.get_float("index") ?? -1.0;
			if (given < 0 || given > (double)count)
			{
				layer.free(mem);
				detail.appendf(`"index" is %.9g; to add, it is 0 to %d`, given, count);
				return LAYER_REFUSED~;
			}
			at = (usz)given;
		}
		next = layers_inserted(mem, next, at, layer);
	}
	else
	{
		sz target = which_layer(src, args, detail);
		if (target < 0) return LAYER_REFUSED~;
		usz at = (usz)target;
		if (op == "replace")
		{
			// On top of the current layer: fields left out keep their value.
			AnimLayer merged = next[at].copy(mem);
			if (!parse_layer(app, spec, &merged, src.duration, detail))
			{
				merged.free(mem);
				return LAYER_REFUSED~;
			}
			next[at].free(mem);
			next[at] = merged;
		}
		else if (op == "remove")
		{
			next = layers_removed(mem, next, at);
		}
		else
		{
			double to = args.get_float("to") ?? -1.0;
			if (to < 0 || to >= (double)count)
			{
				detail.appendf(`"to" is %.9g; to move, it is 0 to %d`, to, count - 1);
				return LAYER_REFUSED~;
			}
			layers_moved(next, at, (usz)to);
		}
	}

	AnimTemplate clip = clip_with_layers(mem, *src, next);
	landed = true;

	AnimRef written = app.author_clip(clip);
	app.refresh_ui();
	return layers_answer(app, written, op);
}

<*
 One flag per rig joint for the dots `joints` names. False with the reason in
 detail when it is not a non-empty array of this rig's dot names.
*>
fn bool joints_picked(AppState* app, RigView* view, Object* joints, bool[]* picked, DString* detail)
{
	if (joints == null || !joints.is_array() || joints.get_len() == 0)
	{
		detail.append_string(`"joints" must be a non-empty array of dot names; each takes every joint below it too`);
		return false;
	}
	bool[] flags = alloc::new_array(mem, bool, (sz)view.len());
	for (sz i = 0; i < joints.get_len(); i++)
	{
		String? name = joints.get_string_at((usz)i);
		sz at = -1;
		if (try name) at = array::index_of(view.names, name) ?? -1;
		if (at < 0)
		{
			alloc::free(mem, flags);
			String said = name ?? "";
			detail.appendf(`"joints"[%d] is not a dot on this rig`, i);
			if (said.len > 0) append_addressable(detail, app, said);
			return false;
		}
		flags[(usz)at] = true;
	}
	*picked = flags;
	return true;
}

// set_layer op extract: the named joints' keys lifted into a layer of their own.
fn String? extract_layer_json(AppState* app, AnimRef ref, Object* args, DString* detail) @local
{
	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(`extract needs a rig: the joints are found on it.`);
		return LAYER_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);
	bool[] picked;
	if (!joints_picked(app, &view, member(args, "joints"), &picked, detail)) return LAYER_REFUSED~;
	defer alloc::free(mem, picked);
	if (app.move_joints_to_layer(ref, picked, args.get_string("name") ?? "") < 0)
	{
		detail.append_string(app.notice());
		return LAYER_REFUSED~;
	}
	app.refresh_ui();
	return layers_answer(app, app.editing, "extract");
}

// set_layer ops share and unlink, on the layer `index` or `name` picks.
fn String? share_layer_json(AppState* app, AnimRef ref, String op, Object* args, DString* detail) @local
{
	AnimTemplate* src = app.clip(ref);
	sz at = which_layer(src, args, detail);
	if (at < 0) return LAYER_REFUSED~;
	if (op == "unlink")
	{
		if (src.layers[(usz)at].link.len == 0)
		{
			detail.appendf(`layer "%s" is not shared, so there is nothing to unlink.`, src.layers[(usz)at].name);
			return LAYER_REFUSED~;
		}
		if (!app.unlink_layer(ref, (usz)at))
		{
			detail.append_string(`the unlinked clip would not land.`);
			return LAYER_REFUSED~;
		}
		app.refresh_ui();
		return layers_answer(app, ref, op);
	}

	AnimLayerFit fit = STRETCH;
	String fit_text = args.get_string("fit") ?? "stretch";
	if (!parse_layer_fit(fit_text, &fit))
	{
		detail.appendf(`"fit" is "%s". It is "stretch", "keep" or "repeat".`, fit_text);
		return LAYER_REFUSED~;
	}
	Object* clips = member(args, "clips");
	if (clips == null || !clips.is_array() || clips.get_len() == 0)
	{
		detail.append_string(`share needs "clips": the names of the clips to give the layer to. get_scene lists them.`);
		return LAYER_REFUSED~;
	}
	AnimRef[] targets = alloc::new_array(mem, AnimRef, (sz)clips.get_len());
	defer alloc::free(mem, targets);
	for (sz i = 0; i < clips.get_len(); i++)
	{
		String? named = clips.get_string_at((usz)i);
		if (catch named)
		{
			detail.appendf(`"clips"[%d] must be a clip name`, i);
			return LAYER_REFUSED~;
		}
		targets[(usz)i] = resolve_named(app, named, detail)!;
		if (targets[(usz)i].same(ref))
		{
			detail.appendf(`"clips"[%d] is the clip the layer is on`, i);
			return LAYER_REFUSED~;
		}
	}
	usz added = app.share_layer(ref, (usz)at, targets, fit);
	app.refresh_ui();
	AnimRef source = app.editing;
	AnimTemplate* clip = app.clip(source);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, clip.name);
	out.appendf(`,"op":"share","shared_with":%d,"link":`, added)!!;
	append_json_string(&out, clip.layers[(usz)at].link);
	out.appendf(`,"holders":%d,"layers":`, app.link_holders(clip.layers[(usz)at].link))!!;
	append_layers_json(&out, clip.layers);
	out.append_char('}');
	return out.copy_str(mem);
}

<*
 merge_layers: bake the unmuted stack into the clip's own keys and clear it.

 @return? LAYER_REFUSED : `The reason is in detail.`
*>
fn String? merge_layers_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `merge_layers takes an object: {"clip": name}`)) return LAYER_REFUSED~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `merge_layers needs "clip": the clip whose layers to bake. get_scene lists every pack and clip.`)) return LAYER_REFUSED~;

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string(`this clip could not be read back to edit.`);
		return LAYER_REFUSED~;
	}
	AnimTemplate* src = app.clip(ref);
	if (src == null || src.layers.len == 0)
	{
		detail.append_string(`this clip has no layers to merge.`);
		return LAYER_REFUSED~;
	}

	usz merged = src.layers.len;
	usz playing = 0;
	foreach (&layer : src.layers) if (!layer.mute) playing++;
	AnimTemplate? baked = app.flattened_clip(ref);
	if (catch baked)
	{
		detail.append_string(`merge_layers needs a rig: a layer's chains and masks are read against its joints.`);
		return LAYER_REFUSED~;
	}
	AnimTemplate flat = baked;
	usz keys = flat.keyframes.len;
	AnimRef written = app.author_clip(flat);
	app.refresh_ui();

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, flat_name(app, written));
	out.appendf(`,"merged":%d,"baked":%d,"keyframes":%d,"layers":0}`, merged, playing, keys)!!;
	return out.copy_str(mem);
}

fn String flat_name(AppState* app, AnimRef ref) @local
{
	AnimTemplate* clip = app.clip(ref);
	return clip ? clip.name : "";
}

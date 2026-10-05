<*
 unbind_clip / delete_model_clip: taking a clip off the character, and out of its model.

 Two different amounts of "remove". Unbinding only drops the binding — the clip
 stays in the library (its file, or the Authored pack) and stops being one of the
 character's animations, so the next Save no longer bakes it in. Deleting from the
 model goes further for the loaded model's own clips: it unbinds and re-saves the
 glb, which is how an animation leaves the file for good. Both are the Animations
 pane's own operations (`unbind_recorded`, `delete_model_animation`); this is the
 name-addressed door to them.
*>
module crig;

import std::collections::object;

faultdef CLIPS_REFUSED;

const String UNBIND_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The bound clip's name, as get_scene lists the character's animations. One undo step; the clip itself stays in its pack."}
},"required":["clip"]}`;

const String DELETE_MODEL_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The name of one of the loaded model's own clips (the file's animations)."}
},"required":["clip"]}`;

<*
 The bound row a clip name answers to, or -1 with the reason in `detail`.

 A bare name matches the row's clip name; two rows of one name (the same clip from
 two files) is ambiguous and the caller is told which files hold them. A
 "Pack/Clip" name, or a name the rows do not carry verbatim, is resolved through
 the library and matched by identity.
*>
fn sz bound_row_named(AppState* app, String name, DString* detail) @local
{
	sz found = -1;
	for (sz i = 0; i < app.doc.animations.len(); i++)
	{
		if (app.doc.animations[i].clip != name) continue;
		if (found >= 0)
		{
			detail.appendf(`"%s" is bound twice, from "%s" and from "%s". Ask for it as "Pack/Clip".`,
				name, app.doc.animations[found].file, app.doc.animations[i].file);
			return -1;
		}
		found = i;
	}
	if (found >= 0) return found;

	AnimRef? asked = resolve_clip(app, name);
	if (try asked)
	{
		for (sz i = 0; i < app.doc.animations.len(); i++)
		{
			if (app.resolve_bound(i).same(asked)) return i;
		}
	}
	detail.appendf(`the character has no bound clip called "%s".`, name);
	append_bound_names(detail, app);
	return -1;
}

// " It binds: A, B." — or a sentence saying nothing is bound.
fn void append_bound_names(DString* detail, AppState* app) @local
{
	if (app.doc.animations.len() == 0)
	{
		detail.append_string(" Nothing is bound to the character.");
		return;
	}
	detail.append_string(" It binds: ");
	for (sz i = 0; i < app.doc.animations.len(); i++)
	{
		if (i > 0) detail.append_string(", ");
		detail.append_string(app.doc.animations[i].clip);
	}
	detail.append_char('.');
}

// What both tools answer: the clip that went and what the character still binds.
fn String clip_management_json(AppState* app, String key, String name)
{
	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"%s":"`, key);
	json_escape_into(&out, name);
	out.append_string(`","bound":[`);
	for (sz i = 0; i < app.doc.animations.len(); i++)
	{
		if (i > 0) out.append_char(',');
		out.append_char('"');
		json_escape_into(&out, app.doc.animations[i].clip);
		out.append_char('"');
	}
	out.append_string("]}");
	return out.copy_str(mem);
}

<*
 Take a bound clip off the character, as one undo step.

 @return? CLIPS_REFUSED : `The name is not a bound clip, or is bound more than once.`
*>
fn String? tool_unbind_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `unbind_clip takes an object: {"clip": name}`)) return CLIPS_REFUSED~;
	String name;
	if (!required_string(args, "clip", &name, detail, `unbind_clip needs "clip": the name of a bound clip.`)) return CLIPS_REFUSED~;

	sz row = bound_row_named(app, name, detail);
	if (row < 0) return CLIPS_REFUSED~;

	// Copied before the row goes: the name points into the binding being removed.
	String taken = app.doc.animations[row].clip.copy(mem);
	defer taken.free(mem);
	if (!app.unbind_recorded(row))
	{
		detail.appendf(`could not unbind "%s".`, name);
		return CLIPS_REFUSED~;
	}
	return clip_management_json(app, "unbound", taken);
}

<*
 Delete one of the loaded model's own clips: unbind it and re-save the model
 without it.

 Only a clip the loaded model's file holds qualifies — a library file is not this
 model's to rewrite, and an authored clip has no file to be taken out of (that is
 `delete_clip`). The model must also be able to take the save in place, so a
 document with no mesh is refused up front.

 @return? CLIPS_REFUSED : `No model open, no mesh to re-save, or the clip is not one of the model's own.`
*>
fn String? tool_delete_model_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `delete_model_clip takes an object: {"clip": name}`)) return CLIPS_REFUSED~;
	String name;
	if (!required_string(args, "clip", &name, detail, `delete_model_clip needs "clip": the name of one of the loaded model's clips.`)) return CLIPS_REFUSED~;

	if (app.source_path.len == 0)
	{
		detail.append_string("no model is open, so there is no file to take a clip out of.");
		return CLIPS_REFUSED~;
	}
	if (!app.has_mesh())
	{
		detail.append_string("the open document has no mesh, so the model cannot be re-saved without the clip. unbind_clip drops the binding only.");
		return CLIPS_REFUSED~;
	}

	// The asset index position of the model's own ANIMATION entry.
	usz which = app.assets.entries.len;
	foreach (usz i, &entry : app.assets.entries)
	{
		if (entry.kind != AssetKind.ANIMATION || entry.name != name) continue;
		if (entry.file != app.source_path) continue;
		which = i;
		break;
	}
	if (which >= app.assets.entries.len)
	{
		detail.appendf(`"%s" is not one of the loaded model's own clips, so there is nothing in its file to delete. `
			`unbind_clip takes a clip off the character; delete_clip removes an authored one. The model's clips are: `, name);
		usz listed = 0;
		foreach (&entry : app.assets.entries)
		{
			if (entry.kind != AssetKind.ANIMATION || entry.file != app.source_path) continue;
			if (listed++ > 0) detail.append_string(", ");
			detail.append_string(entry.name);
		}
		if (listed == 0) detail.append_string("none");
		detail.append_char('.');
		return CLIPS_REFUSED~;
	}

	String taken = name.copy(mem);
	defer taken.free(mem);
	if (!app.delete_model_animation(which))
	{
		detail.appendf(`could not delete "%s" from the model.`, name);
		return CLIPS_REFUSED~;
	}
	return clip_management_json(app, "deleted", taken);
}

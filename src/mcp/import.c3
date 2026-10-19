<*
 import_clip: an animation in a .glb file onto the character. The landing is
 Kimodo's (`AppState.generated_clip_on_rig`): the file's skeleton matched onto
 this rig by shape, its clip sampled onto the rig's own joints and authored as
 one undo step. This reads the file and the arguments, and answers as apply_clip
 does.

 For motion made somewhere else for another skeleton — a capture, SAM 3D Body's
 MHR clip, a Mixamo download — which the library would only show once the file
 sat in one of its folders and the folders were scanned again.
*>
module crig;

import std::collections::object;
import std::io::file;

faultdef IMPORT_REFUSED;

const String IMPORT_CLIP_SCHEMA = `{"type":"object","properties":{
	"path":{"type":"string","description":"The .glb (or self-contained .gltf) file: an absolute path, or one relative to where Rigsmith was started. Its skeleton may be any other rig's; it is matched onto this one by shape, as a library clip is."},
	"clip":{"type":"string","description":"Which of the file's animations, by name. Default the first."},
	"name":{"type":"string","description":"What to call the clip on the character. Default the file's own name for it; made unique against the authored pack, so nothing is replaced."},
	"dense":{"type":"boolean","description":"Keep every key the import samples. Default false: the keys it can lose at Optimize keys' Light tolerance are dropped, so the clip can be edited."}
},"required":["path"]}`;

fn String? tool_import_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `import_clip takes an object: {"path": file, "clip": name, "name": name, "dense": bool}`)) return IMPORT_REFUSED~;
	String path;
	if (!required_string(args, "path", &path, detail, `import_clip needs "path": the .glb file to take the animation from.`)) return IMPORT_REFUSED~;
	String lower = path.to_lower_tcopy();
	if (!lower.ends_with(".glb") && !lower.ends_with(".gltf"))
	{
		detail.appendf(`"%s" is not a .glb or .gltf file, the animation files Rigsmith reads.`, path);
		return IMPORT_REFUSED~;
	}
	if (app.doc.dots.len() == 0)
	{
		detail.append_string("There is no skeleton to put the clip on. Rig the model first.");
		return IMPORT_REFUSED~;
	}
	char[]? bytes = file::load(mem, path);
	if (catch bytes)
	{
		detail.appendf(`"%s" could not be read.`, path);
		return IMPORT_REFUSED~;
	}
	defer alloc::free(mem, bytes);

	String from_clip = args.get_string("clip") ?? "";
	String name = (args.get_string("name") ?? "").trim();
	KeyReduction optimize = (args.get_bool("dense") ?? false) ? OFF : LIGHT;
	AnimTemplate? sampled = app.generated_clip_on_rig(bytes, name, optimize, from_clip);
	if (catch err = sampled)
	{
		switch (err)
		{
			case MOTION_CLIP_MISSING:
				detail.appendf(`"%s" has no animation called "%s".`, path, from_clip);
			case MOTION_NOT_STARTED:
				detail.appendf(`"%s" holds no animation this rig can take: none at all, or one for a skeleton that does not match this rig's body plan by shape.`, path);
			default:
				detail.appendf(`"%s" would not import: %s`, path, err);
		}
		return IMPORT_REFUSED~;
	}
	bool replaced;
	AnimRef landed = app.author_clip(sampled, &replaced);
	if (!landed.valid())
	{
		detail.appendf(`the clip from "%s" could not be added to the character.`, path);
		return IMPORT_REFUSED~;
	}
	app.refresh_ui();
	return applied_json(app, landed, replaced);
}

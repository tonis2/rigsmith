<*
 A scene: which models are loaded together, where each stands, and which clip
 each one plays — `<name>.rigsmith-scene.json`.

 **It holds no character.** Every model keeps its own `.glb` and its own
 `.rigsmith.json` exactly as when it is opened alone, and the scene only points
 at them. So a character is still a file that can be opened by itself, sent to
 someone, or put in two scenes, and nothing about it lives anywhere but beside it.
 What the scene adds is the arrangement: the placement it stands at in this
 scene, the clip it plays, and the instant the scene was left at.

 Model paths are written relative to the scene file when the model is in the
 scene's folder or below it, so a folder holding a scene and its characters can
 be moved as one; anywhere else, they are absolute. The level is written the same
 way, and a scene with none has no `level` key.

 	{ "format": "rigsmith-scene", "version": 1, "active": 0, "time": 1.25, "level": "forest.glb",
 	  "characters": [ { "model": "knight.glb",
 	                    "location": [0,0,0], "rotation": [0,0,0,1],
 	                    "clip": { "file": "", "name": "Duel" } } ] }

 A clip is named the way a bound clip is: by its file, or `""` for one authored
 on the character, and its name in that file. An actor adds `row` (and `level_node`,
 `scale`, `lift`); one read from the level has no `model`, only its `level_node`.
 `cutscenes` lists the scene's cutscenes and `cutscene` the one picked.
*>
module crig;

import std::collections::object;
import std::encoding::json;
import std::io;
import std::io::path;
import libc;
import std::math;
import gltf_edit;

const String SCENE_FORMAT = "rigsmith-scene";
const uint SCENE_VERSION = 1;
const String SCENE_SUFFIX = ".rigsmith-scene.json";

faultdef SCENE_IO, SCENE_SHAPE;

struct SceneCharacter
{
	// Absolute, or as the caller gave it: relative paths are resolved on reading.
	String model;
	ProjectTransform transform;
	String clip_file;
	String clip_name;
	bool hidden;
	bool holds_pose;
	// The name a cutscene finds it by, "" when it is no actor; the level node it stands in for.
	String row;
	String level_node;
	// The size it is drawn at, matched to a level copy's height; 1 is its own.
	float scale;
	// How far the level node's origin stands over the copy's feet, in metres.
	float lift;
}

struct SceneFile
{
	SceneCharacter[] characters;
	usz active;
	float time;
	// The level drawn behind the characters, resolved like `model`; "" for none.
	String level;
	Cutscene[] cutscenes;
	usz active_cutscene;
}

fn void SceneFile.free(&self, Allocator allocator)
{
	foreach (c : self.characters)
	{
		if (c.model.len > 0) alloc::free(allocator, c.model.ptr);
		if (c.clip_file.len > 0) alloc::free(allocator, c.clip_file.ptr);
		if (c.clip_name.len > 0) alloc::free(allocator, c.clip_name.ptr);
		if (c.row.len > 0) alloc::free(allocator, c.row.ptr);
		if (c.level_node.len > 0) alloc::free(allocator, c.level_node.ptr);
	}
	if (self.characters.len > 0) alloc::free(allocator, self.characters);
	if (self.level.len > 0) alloc::free(allocator, self.level.ptr);
	foreach (&cutscene : self.cutscenes) cutscene.free(allocator);
	if (self.cutscenes.len > 0) alloc::free(allocator, self.cutscenes);
	*self = {};
}

<*
 The folder a path sits in, without the separator; "." for a bare file name.
 Borrowed from `path`.
*>
fn String scene_folder(String file)
{
	for (usz i = file.len; i > 0; i--)
	{
		if (file[i - 1] == '/' || file[i - 1] == '\\') return i == 1 ? file[:1] : file[:i - 1];
	}
	return ".";
}

fn bool path_is_absolute(String file) @local
{
	if (file.len > 0 && (file[0] == '/' || file[0] == '\\')) return true;
	return file.len > 2 && file[1] == ':' && (file[2] == '/' || file[2] == '\\');
}

<*
 `file` made absolute against the working directory. The caller owns the result.
*>
fn String absolute_path(Allocator allocator, String file) @local
{
	if (path_is_absolute(file)) return file.copy(allocator);
	String here = ".";
	if (try Path cwd = path::tcwd()) here = (String)cwd;
	String rest = file.starts_with("./") ? file[2..] : file;
	return string::format(allocator, "%s/%s", here, rest);
}

<*
 How a model is written in a scene at `scene_path`: relative to the scene's
 folder when it is inside it, absolute otherwise. The caller owns the result.
*>
fn String scene_model_reference(Allocator allocator, String model, String scene_path)
{
	String model_abs = absolute_path(tmem, model);
	String folder_abs = absolute_path(tmem, scene_folder(scene_path));
	if (model_abs.len > folder_abs.len + 1 && model_abs.starts_with(folder_abs)
		&& (model_abs[folder_abs.len] == '/' || model_abs[folder_abs.len] == '\\'))
	{
		return model_abs[folder_abs.len + 1..].copy(allocator);
	}
	return model_abs.copy(allocator);
}

<*
 The scene as the JSON text its file is, model paths taken relative to
 `scene_path`'s folder where they can be. The caller owns the result.
*>
fn String scene_file_text(Allocator allocator, SceneFile* scene, String scene_path)
{
	DString text = dstring::new(allocator);
	defer text.free();
	text.appendf("{\n  \"format\": \"%s\",\n  \"version\": %d,\n  \"active\": %d,\n  \"time\": %s,",
		SCENE_FORMAT, SCENE_VERSION, scene.active, (JsonFloat)scene.time)!!;
	if (scene.level.len > 0)
	{
		text.append_string("\n  \"level\": ");
		@pool()
		{
			append_json_string(&text, scene_model_reference(tmem, scene.level, scene_path));
		};
		text.append_string(",");
	}
	text.append_string("\n  \"characters\": [");
	foreach (usz i, c : scene.characters)
	{
		text.append_string(i == 0 ? "\n    {" : ",\n    {");
		// One read from the level has no file: its level node finds it again.
		if (c.model.len > 0)
		{
			text.append_string("\"model\":");
			@pool()
			{
				append_json_string(&text, scene_model_reference(tmem, c.model, scene_path));
			};
			text.append_string(",");
		}
		text.appendf("\"location\":%s,\"rotation\":%s", (JsonVec3)c.transform.location,
			(JsonQuat)c.transform.orientation())!!;
		if (c.clip_name.len > 0)
		{
			text.append_string(",\"clip\":{\"file\":");
			append_json_string(&text, c.clip_file);
			text.append_string(",\"name\":");
			append_json_string(&text, c.clip_name);
			text.append_string("}");
		}
		if (c.hidden) text.append_string(",\"hidden\":true");
		if (c.holds_pose) text.append_string(",\"holds_pose\":true");
		if (c.row.len > 0)
		{
			text.append_string(",\"row\":");
			append_json_string(&text, c.row);
		}
		if (c.level_node.len > 0)
		{
			text.append_string(",\"level_node\":");
			append_json_string(&text, c.level_node);
		}
		if (c.scale > 0.0f && c.scale != 1.0f) text.appendf(",\"scale\":%s", (JsonFloat)c.scale)!!;
		if (c.lift != 0.0f) text.appendf(",\"lift\":%s", (JsonFloat)c.lift)!!;
		text.append_string("}");
	}
	text.append_string("\n  ]");
	if (scene.cutscenes.len > 0)
	{
		text.appendf(",\n  \"cutscene\": %d,\n  \"cutscenes\": [", scene.active_cutscene)!!;
		foreach (usz i, &cutscene : scene.cutscenes)
		{
			text.append_string(i == 0 ? "\n    " : ",\n    ");
			append_cutscene_json(&text, cutscene);
		}
		text.append_string("\n  ]");
	}
	text.append_string("\n}\n");
	return text.copy_str(allocator);
}

fn String? scene_string(Object* parent, String key, Allocator allocator, bool required = false) @local
{
	Object*? value = parent.get(key);
	if (catch value)
	{
		if (required) return SCENE_SHAPE~;
		return "";
	}
	if (!value.is_string()) return SCENE_SHAPE~;
	String held = value.s;
	return held.len > 0 ? held.copy(allocator) : "";
}

<*
 Read a scene's text. Relative model paths come back resolved against
 `scene_path`'s folder.

 @return? SCENE_SHAPE : `It is not a scene this version reads.`
*>
fn SceneFile? parse_scene_file(Allocator allocator, String text, String scene_path)
{
	Object*? parsed = json::parse(allocator, text);
	if (catch parsed) return SCENE_SHAPE~;
	defer parsed.free();

	String? format = parsed.get_string("format");
	if (catch format) return SCENE_SHAPE~;
	if (format != SCENE_FORMAT) return SCENE_SHAPE~;
	long? version = parsed.get_long("version");
	if (catch version) return SCENE_SHAPE~;
	if (version < 1 || version > SCENE_VERSION) return SCENE_SHAPE~;

	Object*? listed = parsed.get("characters");
	if (catch listed) return SCENE_SHAPE~;
	if (!listed.is_array() || listed.get_len() == 0) return SCENE_SHAPE~;

	SceneFile scene;
	scene.characters = alloc::new_array(allocator, SceneCharacter, listed.get_len());
	String folder = scene_folder(scene_path);
	for (usz i = 0; i < (usz)listed.get_len(); i++)
	{
		Object* entry = listed.get_at((sz)i);
		SceneCharacter* c = &scene.characters[i];
		if (!entry.is_map())
		{
			scene.free(allocator);
			return SCENE_SHAPE~;
		}
		String? model = scene_string(entry, "model", tmem);
		if (catch model)
		{
			scene.free(allocator);
			return SCENE_SHAPE~;
		}
		// No model is a character read from the level, found again by its level node.
		String node = scene_string(entry, "level_node", tmem) ?? "";
		if (model.len == 0 && node.len == 0)
		{
			scene.free(allocator);
			return SCENE_SHAPE~;
		}
		if (model.len > 0) c.model = path_is_absolute(model) ? model.copy(allocator) : string::format(allocator, "%s/%s", folder, model);
		c.transform.rotation = quaternion::IDENTITY;
		if (try Object* at = entry.get("location"))
		{
			if (try Vec3 location = session_vec3(at)) c.transform.location = location;
		}
		if (try Object* turn = entry.get("rotation"))
		{
			if (try Quaternionf rotation = session_quat(turn)) c.transform.rotation = rotation;
		}
		if (try Object* clip = entry.get("clip"))
		{
			if (clip.is_map())
			{
				c.clip_file = scene_string(clip, "file", allocator) ?? "";
				c.clip_name = scene_string(clip, "name", allocator) ?? "";
			}
		}
		c.hidden = entry.get_bool("hidden") ?? false;
		c.holds_pose = entry.get_bool("holds_pose") ?? false;
		c.row = scene_string(entry, "row", allocator) ?? "";
		c.level_node = scene_string(entry, "level_node", allocator) ?? "";
		double scale = entry.get_float("scale") ?? 1.0;
		c.scale = math::is_finite((float)scale) && scale > 0.0 ? (float)scale : 1.0f;
		double lift = entry.get_float("lift") ?? 0.0;
		c.lift = math::is_finite((float)lift) ? (float)lift : 0.0f;
	}
	Object* listed_cutscenes = member(parsed, "cutscenes");
	if (listed_cutscenes != null)
	{
		if (!listed_cutscenes.is_array())
		{
			scene.free(allocator);
			return SCENE_SHAPE~;
		}
		usz count = (usz)listed_cutscenes.get_len();
		if (count > 0) scene.cutscenes = alloc::new_array(allocator, Cutscene, (sz)count);
		for (usz i = 0; i < count; i++)
		{
			Cutscene? read = cutscene_from_json(allocator, listed_cutscenes.get_at((sz)i));
			if (catch read)
			{
				scene.free(allocator);
				return SCENE_SHAPE~;
			}
			scene.cutscenes[i] = read;
		}
		long picked = parsed.get_long("cutscene") ?? 0;
		scene.active_cutscene = picked >= 0 && (usz)picked < count ? (usz)picked : 0;
	}
	String? level = scene_string(parsed, "level", tmem);
	if (catch level)
	{
		scene.free(allocator);
		return SCENE_SHAPE~;
	}
	if (level.len > 0) scene.level = path_is_absolute(level) ? level.copy(allocator) : string::format(allocator, "%s/%s", folder, level);
	long active = parsed.get_long("active") ?? 0;
	scene.active = active >= 0 && (usz)active < scene.characters.len ? (usz)active : 0;
	double time = parsed.get_float("time") ?? 0.0;
	scene.time = math::is_finite((float)time) && time > 0.0 ? (float)time : 0.0f;
	return scene;
}

fn SceneFile? read_scene_file(Allocator allocator, String scene_path)
{
	char[]? content = io::file::load(allocator, scene_path);
	if (catch content) return SCENE_IO~;
	defer alloc::free(allocator, content);
	return parse_scene_file(allocator, (String)content, scene_path);
}

<*
 Write the scene through a temporary renamed over it, so a failed write leaves
 the previous scene readable.
*>
fn void? write_scene_file(String scene_path, SceneFile* scene)
{
	String body = scene_file_text(mem, scene, scene_path);
	defer body.free(mem);
	if (catch gltf_edit::save_safely(scene_path, body)) return SCENE_IO~;
}

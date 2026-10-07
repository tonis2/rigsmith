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
 be moved as one; anywhere else, they are absolute.

 	{ "format": "rigsmith-scene", "version": 1, "active": 0, "time": 1.25,
 	  "characters": [ { "model": "knight.glb",
 	                    "location": [0,0,0], "rotation": [0,0,0,1],
 	                    "clip": { "file": "", "name": "Duel" } } ] }

 A clip is named the way a bound clip is: by its file, or `""` for one authored
 on the character, and its name in that file.
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
}

struct SceneFile
{
	SceneCharacter[] characters;
	usz active;
	float time;
}

fn void SceneFile.free(&self, Allocator allocator)
{
	foreach (c : self.characters)
	{
		if (c.model.len > 0) alloc::free(allocator, c.model.ptr);
		if (c.clip_file.len > 0) alloc::free(allocator, c.clip_file.ptr);
		if (c.clip_name.len > 0) alloc::free(allocator, c.clip_name.ptr);
	}
	if (self.characters.len > 0) alloc::free(allocator, self.characters);
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
	text.appendf("{\n  \"format\": \"%s\",\n  \"version\": %d,\n  \"active\": %d,\n  \"time\": %s,\n  \"characters\": [",
		SCENE_FORMAT, SCENE_VERSION, scene.active, (JsonFloat)scene.time)!!;
	foreach (usz i, c : scene.characters)
	{
		text.append_string(i == 0 ? "\n    {\"model\":" : ",\n    {\"model\":");
		@pool()
		{
			append_json_string(&text, scene_model_reference(tmem, c.model, scene_path));
		};
		text.appendf(",\"location\":%s,\"rotation\":%s", (JsonVec3)c.transform.location,
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
		text.append_string("}");
	}
	text.append_string("\n  ]\n}\n");
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
		String? model = scene_string(entry, "model", tmem, required: true);
		if (catch model)
		{
			scene.free(allocator);
			return SCENE_SHAPE~;
		}
		c.model = path_is_absolute(model) ? model.copy(allocator) : string::format(allocator, "%s/%s", folder, model);
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
	}
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
	String temporary = string::format(mem, "%s.tmp", scene_path);
	defer temporary.free(mem);
	if (catch io::file::save(temporary, body)) return SCENE_IO~;
	if (libc::rename(temporary.zstr_tcopy(), scene_path.zstr_tcopy()) != 0)
	{
		(void)io::file::delete(temporary);
		return SCENE_IO~;
	}
}

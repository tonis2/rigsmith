<*
 Scenes on disk: saving every loaded character and the arrangement they stand
 in, and opening that arrangement again in one step. The file format is
 `format/scene_file.c3`; this is what the app does around it.
*>
module crig;

import rig;
import std::io;
import std::io::file;
import std::math;

<*
 Save every character that has unsaved work, then write the scene that points
 at them.

 	`app.save_scene("duel.rigsmith-scene.json");`

 Each character is saved exactly as Ctrl+S saves it alone — into its own model,
 or a `_copy.glb` beside a file crig did not write — and the scene records the
 path the save left it at, so the scene opens what was just written.

 @param path : `Where the scene goes; the suffix is added when it is missing.`
 @return `False when a character has no file to save into, or the scene would not write.`
*>
fn bool AppState.save_scene(&self, String path)
{
	if (path.len == 0) return false;
	String target = path.ends_with(SCENE_SUFFIX) ? path.copy(mem) : string::format(mem, "%s%s", path, SCENE_SUFFIX);
	defer target.free(mem);

	for (usz i = 0; i < self.character_count(); i++)
	{
		// One read from the level is found again by its level node, and never saved.
		if (self.character(i).source_path.len == 0 && !self.character(i).level_read)
		{
			self.@notice("a character built in memory has no file — export it first");
			return false;
		}
	}

	// A one-off's latest edit is in the cutscene saved here, and never in its character's files.
	self.sync_one_off_now();
	bool editing_one_off = self.one_off.open;
	// Each character's own clip and time are saved, not the preview's.
	bool previewing = self.cut_preview && !editing_one_off;
	if (!editing_one_off) self.leave_cutscene_preview();
	defer if (previewing) (void)self.set_cutscene_preview(true);
	self.read_scene_clock();
	SceneFile scene = { .active = self.active, .time = self.scene_time };
	if (self.level_path.len > 0) scene.level = self.level_path.copy(mem);
	scene.characters = alloc::new_array(mem, SceneCharacter, (sz)self.character_count());
	defer scene.free(mem);
	if (self.cutscenes.len() > 0)
	{
		scene.cutscenes = alloc::new_array(mem, Cutscene, self.cutscenes.len());
		foreach (usz i, &cutscene : self.cutscenes) scene.cutscenes[i] = cutscene.copy(mem);
		scene.active_cutscene = self.cut_active;
	}

	for (usz i = 0; i < self.character_count(); i++)
	{
		self.@as_character(i)
		{
			self.@as_own_character()
			{
				if (self.unsaved() && !self.level_read) self.save_session();
				SceneCharacter* c = &scene.characters[i];
				c.model = self.source_path.len > 0 ? self.source_path.copy(mem) : "";
				c.transform = self.doc.model_transform;
				c.hidden = self.hidden;
				c.holds_pose = self.holds_pose;
				c.row = self.actor_row.len > 0 ? self.actor_row.copy(mem) : "";
				c.level_node = self.level_node.len > 0 ? self.level_node.copy(mem) : "";
				c.scale = self.stage_scale;
				c.lift = self.stage_lift;
				String file;
				String name;
				if (self.binding_of(self.scene_clip(), &file, &name))
				{
					c.clip_file = file.len > 0 ? file.copy(mem) : "";
					c.clip_name = name.copy(mem);
				}
			};
		};
	}

	if (catch write_scene_file(target, &scene))
	{
		self.@notice("could not write %s", base_name(target));
		return false;
	}
	self.set_scene_path(target);
	// On the recent list, so the chooser that opens scenes offers it next time.
	self.remember_project(target);
	self.@notice("saved the scene · %d character%s", scene.characters.len, scene.characters.len == 1 ? "" : "s");
	return true;
}

fn void AppState.set_scene_path(&self, String path)
{
	String kept = path.len > 0 ? path.copy(mem) : "";
	if (self.scene_path.len > 0) alloc::free(mem, self.scene_path.ptr);
	self.scene_path = kept;
}

<*
 Empty the stage: every character goes, and what is left is the state Rigsmith
 starts in with no file — a scene with nobody in it yet, and no file of its own
 until it is saved. Unsaved work goes with it; asking first is the caller's job.

 @return `False while a motion is being generated, which nothing may pull the character out from under.`
*>
fn bool AppState.new_scene(&self)
{
	if (!self.focus_may_move()) return false;
	self.reset_cutscenes();
	self.drop_other_characters();
	self.close_level();
	self.load_mesh({}, "");
	self.hidden = false;
	self.holds_pose = false;
	self.scene_time = 0.0f;
	self.scene_running = false;
	self.set_scene_path("");
	self.focus_generation = next_generation();
	self.reindex_current_model();
	self.@notice("new scene · File › Import .glb brings a character in");
	return true;
}

<*
 Ask for a scene to be opened between frames, the way a model is.
*>
fn void AppState.request_open_scene(&self, String path)
{
	if (self.pending_scene.len > 0) alloc::free(mem, self.pending_scene.ptr);
	self.pending_scene = path.copy(mem);
}

fn void AppState.service_pending_scene(&self)
{
	String path = self.pending_scene;
	self.pending_scene = "";
	defer if (path.len > 0) alloc::free(mem, path.ptr);
	if (path.len > 0) (void)self.open_scene(path);
	self.refresh_ui();
}

<*
 Replace everything loaded with the scene at `path`.

 Every model is read before anything is replaced, so a scene naming a file that
 is gone or will not load leaves what was open untouched. Each character then
 comes in through the ordinary door — its own sidecar, its own rig — and is set
 where the scene stands it, with the clip the scene gave it on its timeline.

 @return `False, with a notice, when the scene or any model in it will not read.`
*>
fn bool AppState.open_scene(&self, String path)
{
	if (!self.focus_may_move()) return false;
	SceneFile? read = read_scene_file(mem, path);
	if (catch read)
	{
		self.@notice("%s is not a scene Rigsmith can read", base_name(path));
		return false;
	}
	SceneFile scene = read;
	defer scene.free(mem);

	rig::TriMesh[] meshes = alloc::new_array(mem, rig::TriMesh, (sz)scene.characters.len);
	defer alloc::free(mem, meshes);
	foreach (usz i, c : scene.characters)
	{
		// Read from the level: its rig comes when the level does.
		if (c.model.len == 0) continue;
		rig::TriMesh? mesh = file::is_file(c.model) ? rig::load_gltf(mem, c.model) : io::FILE_NOT_FOUND~;
		if (catch mesh)
		{
			for (usz k = 0; k < i; k++) meshes[k].free(mem);
			self.@notice("the scene's %s could not be opened", base_name(c.model));
			return false;
		}
		meshes[i] = mesh;
	}

	self.reset_cutscenes();
	self.drop_other_characters();
	foreach (usz i, c : scene.characters)
	{
		if (i == 0)
		{
			self.load_mesh(meshes[i], c.model, reframe: false);
		}
		else
		{
			self.add_character(meshes[i], c.model);
		}
		// Where the scene stands it wins over where its file does: the same model
		// can stand in two places in two scenes.
		self.doc.model_transform = c.transform;
		self.hidden = c.hidden;
		self.holds_pose = c.holds_pose;
		self.set_actor_row(c.row);
		self.set_level_node(c.level_node);
		self.level_read = c.model.len == 0;
		self.stage_scale = c.scale != 1.0f ? c.scale : 0.0f;
		self.stage_lift = c.lift;
		if (c.clip_name.len > 0)
		{
			self.editing = self.resolve_clip_identity(c.clip_file, c.clip_name);
			self.edit_time = 0.0f;
			self.refresh_timeline_tracks(self.editing);
		}
	}

	// The cutscenes are taken over whole; the scene's copy is left empty.
	self.adopt_cutscenes(scene.cutscenes, scene.active_cutscene);
	scene.cutscenes = {};
	self.scene_time = scene.time;
	self.scene_running = false;
	// Every character to the scene's instant, the focus last so it is the one
	// that ends up editing.
	for (usz i = 0; i < self.character_count(); i++)
	{
		self.@as_character(i)
		{
			(void)self.follow_scene_clock();
		};
	}
	if (scene.active != self.active) self.focus_character(scene.active);
	// The switch read the time back off a clip, wrapped to that clip's length;
	// the scene's own instant is the one to stand at.
	self.scene_time = scene.time;
	(void)self.follow_scene_clock();
	self.frame_cast();
	self.set_scene_path(path);
	self.remember_project(path);
	self.focus_generation = next_generation();
	self.reindex_current_model();
	// A level that is gone is a notice: the characters are the scene.
	bool level_missing = false;
	if (scene.level.len == 0)
	{
		self.close_level();
	}
	else if (!self.open_level(scene.level))
	{
		level_missing = true;
		self.close_level();
	}
	// A level already in does not come in again: its actors are read from it now.
	if (level_shown()) self.level_came_in();
	// Read from a level that is gone: kept as they are, named in the problems list.
	if (!self.has_level())
	{
		for (usz i = 0; i < self.character_count(); i++)
		{
			if (self.character(i).level_read) self.character(i).stage_missing = true;
		}
	}
	if (level_missing)
	{
		self.@notice("opened the scene · %d character%s · its level %s is missing", scene.characters.len, scene.characters.len == 1 ? "" : "s", base_name(scene.level));
		return true;
	}
	if (self.cutscenes.len() > 0)
	{
		self.@notice("opened the scene · %d character%s, %d cutscene%s", scene.characters.len, scene.characters.len == 1 ? "" : "s",
			self.cutscenes.len(), self.cutscenes.len() == 1 ? "" : "s");
		return true;
	}
	self.@notice("opened the scene · %d character%s", scene.characters.len, scene.characters.len == 1 ? "" : "s");
	return true;
}

<*
 Point the camera at every shown character at once.
*>
fn void AppState.frame_cast(&self)
{
	rig::Bounds all;
	bool found;
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if ((!c.has_mesh() && !c.level_read) || c.hidden) continue;
		rig::Bounds b = c.world_bounds();
		all = found ? (rig::Bounds){ math::min(all.min, b.min), math::max(all.max, b.max) } : b;
		found = true;
	}
	if (!found) return;
	self.camera = framed(all);
	self.camera_reset_generation++;
}

<*
 Write every loaded character into one .glb, with one animation that plays each
 one's clip on the scene's clock — the cutscene, as a file an engine opens.

 	`app.export_scene("duel.glb");`

 The length is the longest clip in the scene; a shorter one that loops goes on
 looping across it and one that does not holds its last pose. A character with no
 rig is left out, since there is nothing to animate and no skin to write.

 @return `False, with a notice, when nothing could be written.`
*>
fn bool AppState.export_scene(&self, String path, float fps = 30.0f)
{
	if (path.len == 0) return false;
	// Each character's own clip is what it plays here, never a one-off being edited.
	(void)self.back_to_cutscene();
	usz count = self.character_count();
	SceneExportCharacter[] cast = alloc::new_array(mem, SceneExportCharacter, (sz)count);
	RigView[] views = alloc::new_array(mem, RigView, (sz)count);
	String[] names = alloc::new_array(mem, String, (sz)count);
	defer
	{
		foreach (usz i, &view : views) if (cast[i].skeleton) view.free(mem);
		foreach (usz i, c : cast) if (c.skin.len > 0) alloc::free(mem, c.skin);
		foreach (name : names) if (name.len > 0) name.free(mem);
		alloc::free(mem, cast);
		alloc::free(mem, views);
		alloc::free(mem, names);
	}

	usz written;
	float duration;
	for (usz i = 0; i < count; i++)
	{
		self.@as_character(i)
		{
			if (self.has_mesh() && self.doc.dots.len() > 0)
			{
				if (try RigView view = self.open_rig(mem))
				{
					views[written] = view;
					names[written] = unique_node_prefix(mem, self.label(), names[:written]);
					SceneExportCharacter* c = &cast[written];
					c.mesh = self.geometry;
					c.skeleton = &views[written].skeleton;
					c.names = views[written].names;
					c.skin = self.weights(mem, &views[written]);
					c.name = names[written];
					c.transform = self.doc.model_transform;
					AnimRef ref = self.scene_clip();
					if (ref.valid())
					{
						self.ensure_clip_imported(ref);
						AnimTemplate* clip = self.clip(ref);
						if (clip)
						{
							c.clip = *clip;
							c.animated = true;
							duration = math::max(duration, clip.duration);
						}
					}
					written++;
				}
			}
		};
	}
	if (written == 0)
	{
		self.@notice("nothing to export — no character has a rig");
		return false;
	}

	String scene_name = self.scene_path.len > 0 ? file_stem(self.scene_path) : "Scene";
	if (scene_name.ends_with(".rigsmith-scene")) scene_name = scene_name[:scene_name.len - ".rigsmith-scene".len];
	if (catch fault error = export_scene_glb(mem, path, cast[:written], scene_name,
		duration > 0.0f ? duration : 1.0f, fps))
	{
		self.@notice("could not write %s: %s", base_name(path), error);
		return false;
	}
	self.@notice("wrote %s · %d character%s, %.2fs", base_name(path), written, written == 1 ? "" : "s", duration);
	return true;
}

<*
 A node prefix for a character, unique against the ones already given out:
 `knight`, then `knight_2`. Only letters, digits, `_` and `-`, so a file name with
 spaces or dots still makes a clean node name. The caller owns the result.
*>
fn String unique_node_prefix(Allocator allocator, String label, String[] taken) @local
{
	DString clean = dstring::new(tmem);
	foreach (ch : label)
	{
		bool plain = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-';
		clean.append_char(plain ? ch : '_');
	}
	String base = clean.len() > 0 ? clean.str_view() : "character";
	for (uint n = 1; n < 1000; n++)
	{
		String candidate = n == 1 ? base.copy(allocator) : string::format(allocator, "%s_%d", base, n);
		bool used;
		foreach (t : taken) used = used || t == candidate;
		if (!used) return candidate;
		candidate.free(allocator);
	}
	return base.copy(allocator);
}

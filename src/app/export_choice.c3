<*
 What File › Export can write: the character in focus, all characters in one .glb,
 or the active cutscene. The Export panel asks these; the writers live in
 history.c3, scene_io.c3 and cutscenes.c3.
*>
module crig;

<*
 Count the loaded characters that have a model, and those of them with a rig.

 @param [&out] models : "Characters with a model"
 @param [&out] rigged : "Of those, the ones with joints placed"
*>
fn void AppState.export_cast_counts(&self, usz* models, usz* rigged)
{
	*models = 0;
	*rigged = 0;
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (!c.has_mesh()) continue;
		(*models)++;
		if (c.doc.dots.len() > 0) (*rigged)++;
	}
}

<* Whether Export has anything to offer: a model or a cutscene. *>
fn bool AppState.can_export(&self)
{
	if (self.cutscenes.len() > 0) return true;
	for (usz i = 0; i < self.character_count(); i++)
	{
		if (self.character(i).has_mesh()) return true;
	}
	return false;
}

<*
 Why `what` cannot be exported now.

 @return "The reason in temp memory, or empty when it can be"
*>
fn String AppState.export_refusal(&self, ExportWhat what)
{
	switch (what)
	{
		case CHARACTER:
			if (self.level_read) return string::tformat("%s is read from the level and has no model of its own", self.label());
			if (!self.has_mesh()) return "the character in focus has no model to export";
		case ALL_CHARACTERS:
			usz models;
			usz rigged;
			self.export_cast_counts(&models, &rigged);
			if (rigged == 0) return "no character has a rig to export";
		case CUTSCENE:
			if (self.cutscenes.len() == 0) return "the scene has no cutscene to export";
	}
	return "";
}

<*
 The choice Export opens on: the cutscene while it is previewed, all characters
 when more than one has a model, else the character. One that does not apply
 gives way to the first that does.
*>
fn ExportWhat AppState.default_export_what(&self)
{
	usz models;
	usz rigged;
	self.export_cast_counts(&models, &rigged);
	ExportWhat what = self.cutscene_previewing() ? CUTSCENE : models > 1 ? ALL_CHARACTERS : CHARACTER;
	if (self.export_refusal(what).len == 0) return what;
	foreach (other : (ExportWhat[]){ CHARACTER, ALL_CHARACTERS, CUTSCENE })
	{
		if (self.export_refusal(other).len == 0) return other;
	}
	return what;
}

// The scene's folder, else the first character file's; empty with neither.
fn String export_folder(AppState* app) @local
{
	if (app.scene_path.len > 0) return scene_folder(app.scene_path);
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (c.source_path.len > 0) return scene_folder(c.source_path);
	}
	return "";
}

<*
 The path the Export panel suggests for `what`.

 @param [&in] app : "The state to name it from"
 @return "In temp memory; empty when there is nothing to name it from"
*>
fn String export_default_path(AppState* app, ExportWhat what)
{
	switch (what)
	{
		case CHARACTER:
			if (app.source_path.len == 0) return "";
			return rigged_path(tmem, app.source_path);
		case ALL_CHARACTERS:
			String folder = export_folder(app);
			if (folder.len == 0) return "";
			if (app.scene_path.len == 0) return string::tformat("%s/scene.glb", folder);
			String name = base_name(app.scene_path);
			String stem = name.ends_with(SCENE_SUFFIX) ? name[:name.len - SCENE_SUFFIX.len] : file_stem(name);
			return string::tformat("%s/%s.glb", folder, stem);
		case CUTSCENE:
			Cutscene* cutscene = app.cutscene();
			String folder = export_folder(app);
			if (!cutscene || folder.len == 0) return "";
			return string::tformat("%s/%s", folder, cutscene_file_name(tmem, cutscene.name));
	}
}

<*
 `typed` with the extension `what` writes: `.glb` for all characters, and
 `.cutscene.glb` for a cutscene unless it already ends in .glb or .gltf.

 @return "`typed` itself, or a copy in temp memory"
*>
fn String export_file_name(ExportWhat what, String typed)
{
	switch (what)
	{
		case CHARACTER:
			return typed;
		case ALL_CHARACTERS:
			return typed.ends_with(".glb") ? typed : string::tformat("%s.glb", typed);
		case CUTSCENE:
			bool named = typed.ends_with(".glb") || typed.ends_with(".gltf");
			return named ? typed : string::tformat("%s.cutscene.glb", typed);
	}
}

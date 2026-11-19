<* File › Import .glb: a level opens behind the scene, a cutscene file is refused, anything else is a character. *>
module crig;

<*
 Bring in the .glb at `path` as what `glb_kind` says it is.
 A file whose JSON does not read goes the character's way, whose load says what is wrong with it.

 @return "False, with a notice, when it is refused"
*>
fn bool AppState.import_glb(&self, String path)
{
	GlbKind? kind = glb_kind(path);
	if (catch kind)
	{
		self.request_add_character(path);
		return true;
	}
	switch (kind)
	{
		case CUTSCENE:
			self.@notice("%s is a cutscene file: Rigsmith writes these and doesn't open them", base_name(path));
			return false;
		case LEVEL:
			bool again = self.has_level() && self.level_path == path;
			String old = self.has_level() && !again ? base_name(self.level_path).copy(mem) : "";
			defer if (old.len > 0) old.free(mem);
			if (!self.open_level(path, frame: !self.has_mesh())) return false;
			if (again)
			{
				self.@notice("the level %s is open already", base_name(path));
			}
			else if (old.len > 0)
			{
				self.@notice("Opening the level %s… · replaces %s", base_name(path), old);
			}
			else
			{
				self.@notice("Opening the level %s…", base_name(path));
			}
			return true;
		case CHARACTER:
			self.request_add_character(path);
			return true;
	}
}

<* The level behind the scene: opened, closed and framed. It is never edited, saved or undone. *>
module crig;

import rig;
import std::io::file;
import std::math;

<*
 Open the level at `path` behind the characters, replacing any open one. It is
 read over the next frames; `level_report` says how far it has got.

 @param frame : "Point the camera at the whole level once it is in"
 @return "False, with a notice, when there is no such file"
*>
fn bool AppState.open_level(&self, String path, bool frame = false)
{
	if (path.len == 0) return false;
	if (!file::is_file(path))
	{
		self.@notice("the level %s is missing", base_name(path));
		return false;
	}
	// The level already open is kept, not read again.
	if (path == self.level_path && (level_busy() || level_shown()))
	{
		if (frame && level_shown()) self.frame_level();
		if (frame && level_busy()) frame_level_when_in();
		return true;
	}
	String kept = path.copy(mem);
	self.forget_level_path();
	self.level_path = kept;
	request_level(kept, frame);
	return true;
}

<* Take the level away. Nothing about the characters changes. *>
fn void AppState.close_level(&self)
{
	drop_level();
	self.forget_level_path();
	self.show_colliders = false;
	self.unpick_level();
}

// Whether the scene has a level, open or on its way.
fn bool AppState.has_level(&self) => self.level_path.len > 0;

<* The level would not read: the scene goes on without one. *>
fn void AppState.level_failed(&self)
{
	self.forget_level_path();
	self.show_colliders = false;
	self.unpick_level();
}

// The level row's pick goes with the level, on every character that holds it.
fn void AppState.unpick_level(&self)
{
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (c.scene_selection == LEVEL) c.scene_selection = NONE;
	}
}

fn void AppState.forget_level_path(&self)
{
	if (self.level_path.len > 0) alloc::free(mem, self.level_path.ptr);
	self.level_path = "";
}

<*
 Point the camera at the level: the shot its file was composed for, else the whole
 of it. Nothing happens until it is in.
*>
fn void AppState.frame_level(&self)
{
	rig::Bounds box;
	if (!level_bounds(&box)) return;
	self.camera = framed(box, self.camera.fov);
	// Its own camera stands inside it; outside, a level may be a shell around its ground.
	(void)level_shot(&self.camera);
	// A level is walked through, not only looked at: let the camera in close.
	float radius = box.extent().length() * 0.5f;
	self.camera.near_plane = math::max(radius * 0.001f, 0.02f);
	self.camera.far_plane = self.camera.distance + radius * 3.0f;
	self.camera.min_distance = math::min(self.camera.min_distance, 0.1f);
	self.camera_reset_generation++;
}

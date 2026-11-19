<*
 Characters read straight from the level file by their armature. Each has no
 mesh and no file of its own: its rig and clips are the level's, it stands where
 the level puts the node, and the level's own copy is drawn posed by it
 (`engine/level.c3`). It is read-only outside a one-off: an edit that lands on it
 is taken back, with a notice (`refuse_level_edits`), and nothing of it is ever
 saved, beside the level or anywhere else.
*>
module crig;

import rig;
import gltf;
import std::math;

<* Whether the scene has a character to save: one with a mesh, or one read from the level. *>
fn bool AppState.scene_has_characters(&self)
{
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (c.has_mesh() || c.level_read) return true;
	}
	return false;
}

<*
 The level character whose armature is `armature`, read out of the level file at `path`.

 @return? LEVEL_RIG_NO_ARMATURE, LEVEL_RIG_NO_SKIN : "The file has no such rigged character"
*>
fn LevelRig? read_level_rig_file(Allocator allocator, String path, String armature)
{
	gltf::GltfStream stream = gltf::open(path, mem)!;
	defer stream.close();
	return read_level_rig(allocator, &stream, armature);
}

<*
 Make the level character whose armature is `node` an actor read from the open level's file,
 with `row` (the node's name when empty): where the level puts it, at its scale, with the level's
 rig and clips. It becomes the focus; the row is one cutscene undo step.

 @return "False, with a notice, without a level, for a node the level lacks, or one already taken"
*>
fn bool AppState.read_level_actor(&self, String node, String row = "")
{
	if (!self.has_level())
	{
		self.@notice("open a level first");
		return false;
	}
	sz holder = self.level_node_character(node);
	if (holder >= 0)
	{
		Character* c = self.character((usz)holder);
		self.@notice("%s already stands in for %s", c.actor_row.len > 0 ? c.actor_row : c.label(), node);
		return false;
	}
	String wanted = row.trim().len > 0 ? row.trim() : node;
	if (self.actor_character(wanted) >= 0)
	{
		self.@notice("%s already plays '%s' — rows are how the game tells actors apart", self.character((usz)self.actor_character(wanted)).label(), wanted);
		return false;
	}
	if (!self.focus_may_move()) return false;
	LevelRig? read = read_level_rig_file(mem, self.level_path, node);
	if (catch read)
	{
		self.@notice("the level has no rigged character called %s", node);
		return false;
	}
	LevelRig rig = read;
	defer rig.free(mem);

	// An empty first character is used, as File › Open would.
	if (!self.has_mesh() && self.character_count() == 1 && !self.level_read && self.doc.dots.len() == 0)
	{
		self.load_mesh({}, "", reframe: false);
	}
	else
	{
		(void)self.add_character({}, "");
	}
	self.set_level_node(node);
	self.level_read = true;
	self.adopt_level_rig(&rig);
	(void)self.make_actor(self.active, wanted);
	self.cutscenes_changed();
	sz joints = self.doc.dots.len();
	sz clips = self.doc.animations.len();
	self.@notice("%s is read from the level · %d joint%s, %d clip%s", wanted, joints, joints == 1 ? "" : "s", clips, clips == 1 ? "" : "s");
	self.refresh_ui();
	return true;
}

<*
 Put `rig` on the focus as the level has it, recording nothing: its joints with the feet on the
 model's floor, its clips bound by name, standing where the level puts the armature at its scale,
 lifted by how far the armature's origin is over the feet. The rig's clips are taken over.

 @param [&inout] rig
*>
fn void AppState.adopt_level_rig(&self, LevelRig* rig)
{
	self.stop_animation();
	self.editing = NO_ANIM;
	self.edit_time = 0.0f;
	self.free_timeline_tracks();
	self.clear_animation_key_selection();
	self.select(0);

	// The model's origin is where the feet rest: its floor is the rest mesh's lowest point.
	Vec3 feet = { 0, rig.bounds.min.y, 0 };
	self.doc.free();
	self.doc = new_document(0.0f);
	uint[] ids = alloc::new_array(mem, uint, (sz)rig.skeleton.len());
	defer free(ids);
	foreach (usz j, at : rig.skeleton.joints)
	{
		ids[j] = self.doc.add_dot(at - feet, j < rig.names.len ? rig.names[j] : "");
		int parent = rig.skeleton.parents[j];
		if (parent >= 0 && (usz)parent < j) (void)self.doc.connect(ids[parent], ids[j]);
	}
	AnimTemplate[] clips = rig.clips;
	rig.clips = {};
	self.replace_authored_clips(clips);
	foreach (&clip : clips) (void)self.doc.bind_clip("", clip.name);
	self.authored_index_stale = true;

	float scale = math::abs(rig.scale.y) > 1e-6f ? math::abs(rig.scale.y) : 1.0f;
	Quaternionf turn = rig.rotation.normalize();
	self.stage_scale = scale == 1.0f ? 0.0f : scale;
	self.doc.model_transform = { .location = rig.position + turn.rotate_vec3(feet * scale), .rotation = turn };
	self.stage_lift = rig.position.y - self.doc.model_transform.location.y;
	self.stage_bounds = { rig.bounds.min - feet, rig.bounds.max - feet };
	self.set_stage_rig(rig.rest);
	self.stage_missing = false;

	self.undo_stack.clear();
	self.mark_saved();
	self.authored_dirty = false;
	self.mark_rig_stale();
	self.map_level_joints();
	self.reindex_current_model();
}

<* For each joint of the level copy's skin, the rig joint it follows: its own by name, else the nearest above it that has one. *>
fn void AppState.map_level_joints(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.set_level_joints({});
		return;
	}
	RigView view = opened;
	defer view.free(mem);
	int[] map = alloc::new_array(mem, int, (sz)self.stage_rig.len);
	defer free(map);
	foreach (usz k, &r : self.stage_rig)
	{
		map[k] = -1;
		String name = r.name;
		// A rig is a tree; the bound only stops a malformed loop.
		for (usz depth = 0; name.len > 0 && depth <= self.stage_rig.len && map[k] < 0; depth++)
		{
			foreach (usz i, n : view.names) if (n == name) map[k] = (int)i;
			sz up = joint_rest_index(self.stage_rig, name);
			name = up >= 0 ? self.stage_rig[up].parent : "";
		}
	}
	self.set_level_joints(map);
}

<*
 Every actor read from the level reads its armature again out of the level file: one whose
 armature is gone keeps what it had, and the problems list says so. Not an edit.
*>
fn void AppState.reread_level_actors(&self)
{
	bool some;
	for (usz i = 0; i < self.character_count(); i++) some = some || self.character(i).level_read;
	if (!some) return;
	(void)self.back_to_cutscene();
	self.leave_cutscene_preview();
	// One read of the file for all of them.
	gltf::GltfStream stream;
	bool open;
	if (self.has_level())
	{
		if (try gltf::GltfStream s = gltf::open(self.level_path, mem))
		{
			stream = s;
			open = true;
		}
	}
	defer if (open) stream.close();
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (!c.level_read) continue;
		LevelRig? read = open ? read_level_rig(mem, &stream, c.level_node) : LEVEL_RIG_NO_ARMATURE~;
		if (catch read)
		{
			c.stage_missing = true;
			continue;
		}
		LevelRig rig = read;
		self.@as_character(i) { self.adopt_level_rig(&rig); };
		rig.free(mem);
	}
}

<*
 Take back what landed on a character read from the level, with a notice: it is the level's, and
 read-only here. While a one-off is edited on it only the one-off's own clip edits are kept.

 @return "Whether anything was taken back"
*>
fn bool AppState.refuse_level_edits(&self)
{
	String refused;
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (!c.level_read || c.undo_stack.edits.len() == 0) continue;
		self.@as_character(i)
		{
			if (self.take_back_level_edits()) refused = self.actor_row.len > 0 ? self.actor_row : self.label();
		};
	}
	if (refused.len == 0) return false;
	self.@notice("%s is the level's own character, read-only here: the edit was taken back · one-offs are edited on it", refused);
	return true;
}

// The focus's edits the level does not allow, taken back: all of them, or a one-off's that change more than its clip.
fn bool AppState.take_back_level_edits(&self)
{
	if (self.one_off_here())
	{
		if (!self.undo_stack.holds_document_edit()) return false;
		while (self.undo_stack.holds_document_edit() && self.undo()) {}
		self.undo_stack.forget_redo();
		return true;
	}
	if (self.one_off.open && self.one_off.character == self.id) return false;
	// Only what was undone already: nothing landed.
	if (!self.undo_stack.can_undo())
	{
		self.undo_stack.clear();
		return false;
	}
	while (self.undo()) {}
	self.undo_stack.clear();
	self.mark_saved();
	self.authored_dirty = false;
	return true;
}

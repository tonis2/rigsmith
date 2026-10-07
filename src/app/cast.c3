<*
 The characters loaded beside the one being edited, and moving between them.

 **One character is the focus; the rest wait.** The focus is `AppState.focus`,
 held inline, so all of the app's code that reads `self.doc` or `app.editing` is
 reading the focus without knowing there are others. The waiting ones are in
 `cast`, by value, and `cast[active]` is a hollow slot standing where the focus
 came from — so a character's position in `cast` is its index everywhere, and
 the outliner, the renderer and the scene file all count the same way.

 **Switching is a value swap**, safe because a character holds only heap
 pointers, never one into itself. Two kinds:

 - `focus_character` is the user's: it ends whatever gesture is in flight and
   refreshes the interface, because what is on screen is now about someone else.
 - `@as_character` is the code's: it brings a character in for the length of a
   block — to advance its clip with the shared clock, save it or free it — and
   puts it back, touching nothing else.

 **The authored pack follows the swap.** Only the focus has its clips in
 `packs`; a waiting character's sit in `authored_store`, and its slot in `packs`
 is empty but kept, so every clip ref it holds still names its own pack when it
 comes back. The library, the browser and every lookup therefore only ever see
 the focus's work, which is what they were written against.
*>
module crig;

import rig;
import std::math;

<*
 How many characters are loaded. One before anything was added, even with no
 mesh open — the app always has a focus.
*>
fn usz AppState.character_count(&self) => (usz)self.cast.len() == 0 ? 1 : (usz)self.cast.len();

<*
 A loaded character by its position: the focus itself, or one waiting in the
 cast. Read-only use for a waiting one — its methods that refresh caches assume
 they run as the focus; bring it in with `@as_character` for those.

 @param i : `Below character_count().`
*>
fn Character* AppState.character(&self, usz i)
{
	if (i == self.active || (usz)self.cast.len() == 0) return &self.focus;
	return &self.cast[(sz)i];
}

<*
 Put the focus's authored pack aside before it leaves.

 The slot in `packs` is emptied rather than removed, so no other pack moves and
 the index the outgoing character keeps still points at a slot that is its own.
*>
fn void AppState.lift_authored(&self)
{
	if (self.authored_pack < 0 || (usz)self.authored_pack >= (usz)self.packs.len()) return;
	AnimPack* held = &self.packs[(sz)self.authored_pack];
	self.authored_store = *held;
	*held = {};
}

<*
 Put an incoming character's authored pack back where it was.

 Into its own slot when that is still the empty slot it left; appended when a
 library re-read rebuilt `packs` meanwhile — the re-read moved its refs to names
 for exactly that, see `remember_cast_refs`.
*>
fn void AppState.land_authored(&self)
{
	if (!self.authored_store.owned) return;
	AnimPack pack = self.authored_store;
	self.authored_store = {};
	usz slot = (usz)self.authored_pack;
	if (self.authored_pack >= 0 && slot < (usz)self.packs.len()
		&& !self.packs[(sz)slot].owned && self.packs[(sz)slot].name.len == 0)
	{
		self.packs[(sz)slot] = pack;
		return;
	}
	self.authored_pack = (int)self.adopt_pack(pack);
}

<*
 Exchange the focus for the character at `i`, and nothing else.

 The primitive under both kinds of switch. No gesture is ended and no interface
 refreshed — see `focus_character` for the one a person makes.
*>
fn void AppState.swap_focus(&self, usz i)
{
	if (i == self.active || i >= (usz)self.cast.len()) return;
	self.lift_authored();
	self.cast[(sz)self.active] = self.focus;
	self.focus = self.cast[(sz)i];
	self.cast[(sz)i] = {};
	self.active = i;
	self.land_authored();
}

<*
 Run a block as the character at `i`, and put the focus back afterwards.

 	`app.@as_character(1) { app.scrub_to(0.5f); };`

 Everything in the block that says `self.doc` or `app.editing` reads that
 character. Nothing outside it changes, so the block must not leave behind state
 that is about the focus — no notices meant for the user, no selection, no UI.
*>
macro void AppState.@as_character(&self, usz i; @body())
{
	usz home = self.active;
	if (i == home || i >= (usz)self.cast.len())
	{
		@body();
	}
	else
	{
		self.swap_focus(i);
		@body();
		self.swap_focus(home);
	}
}

<*
 Run a block as each waiting character in turn; the block is given the
 character's position in the cast.
*>
macro void AppState.@each_parked(&self; @body(usz i))
{
	usz home = self.active;
	for (usz i = 0; i < (usz)self.cast.len(); i++)
	{
		if (i == home) continue;
		self.swap_focus(i);
		@body(i);
		self.swap_focus(home);
	}
}

<*
 Free every waiting character and empty the cast, leaving the focus alone.
*>
fn void AppState.free_cast(&self)
{
	self.@each_parked(; usz i)
	{
		self.free_character_state();
	};
	self.cast.free();
	self.active = 0;
}

<*
 What a character is called on screen: its file's name without the folder or
 the extension, or "Untitled" for a mesh built in memory. Borrowed from the path.
*>
fn String Character.label(&self)
{
	if (self.source_path.len == 0) return "Untitled";
	return file_stem(self.source_path);
}

<*
 The character's mesh, in the world: its rest bounds carried through its
 placement. Empty bounds for a character with no mesh.
*>
fn rig::Bounds Character.world_bounds(&self)
{
	if (!self.has_mesh()) return {};
	rig::Bounds local = self.geometry.bounds();
	rig::Bounds out;
	for (int corner = 0; corner < 8; corner++)
	{
		Vec3 at = {
			corner & 1 ? local.max.x : local.min.x,
			corner & 2 ? local.max.y : local.min.y,
			corner & 4 ? local.max.z : local.min.z,
		};
		Vec3 world = self.doc.model_transform.point(at);
		if (corner == 0)
		{
			out = { world, world };
			continue;
		}
		out.min = math::min(out.min, world);
		out.max = math::max(out.max, world);
	}
	return out;
}

<*
 Which loaded character came from this file, or -1. Compared as written, so the
 same file reached by two spellings counts as two.
*>
fn int AppState.character_from(&self, String path)
{
	if (path.len == 0) return -1;
	for (usz i = 0; i < self.character_count(); i++)
	{
		if (self.character(i).source_path == path) return (int)i;
	}
	return -1;
}

<*
 Whether a character other than the one being edited has unsaved work — what
 opening a model, which replaces the scene, would throw away unasked.
*>
fn bool AppState.others_unsaved(&self)
{
	for (usz i = 0; i < self.character_count(); i++)
	{
		if (i == self.active) continue;
		Character* c = self.character(i);
		if (c.has_mesh() && c.unsaved()) return true;
	}
	return false;
}

<*
 Whether any loaded character has work a save has not written.
*>
fn bool AppState.any_character_unsaved(&self)
{
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (c.has_mesh() && c.unsaved()) return true;
	}
	return false;
}

<*
 Settle every gesture in flight before the focus moves: each one holds state
 about the character it started on, and finishing it on another would apply a
 drag meant for one body to the other.
*>
fn void AppState.end_focus_gestures(&self)
{
	self.end_drag();
	self.end_stroke();
	self.end_brush();
	self.end_lasso();
	self.end_area();
	self.end_sketch();
	self.discard_transform_transaction();
	self.transform_interaction = {};
	self.anim_pending_armed = false;
	self.anim_pending_action = 0;
	self.renaming_dot = 0;
	// Questions about the character that is leaving.
	self.wants_rig_prompt = false;
	self.pending_rig_pack = -1;
}

<*
 Whether the focus may move now. A clip being generated lands in whichever
 character is the focus when it finishes, so the focus waits for it.
*>
fn bool AppState.focus_may_move(&self)
{
	if (!self.motion_job.running) return true;
	self.@notice("Wait for the clip being generated to finish first");
	return false;
}

<*
 Make the character at `i` the one being edited.

 	`app.focus_character(1);`

 Ends whatever gesture was in flight, then swaps. The incoming character picks
 up the shared clock: its clip is shown at the scene's time, so a character
 parked at 1.3 s to be copied from leaves the one being posed at 1.3 s too.

 @return `False when i is already the focus or names no character.`
*>
fn bool AppState.focus_character(&self, usz i)
{
	if (i == self.active || i >= (usz)self.cast.len()) return false;
	if (!self.focus_may_move()) return false;
	self.end_focus_gestures();
	if (self.character_count() > 1) self.read_scene_clock();
	self.swap_focus(i);
	self.adopt_scene_clock();
	self.focus_generation = next_generation();
	self.reindex_current_model();
	self.refresh_ui();
	self.@notice("Editing %s", self.label());
	return true;
}

<*
 Load `geometry` as another character beside the ones already open, and make it
 the one being edited.

 	`app.add_character(mesh, "knight.glb");`

 The same door `load_mesh` is, rig and session and all — the new character is a
 fresh one going through it, and the others wait in the cast untouched. Set down
 beside the rest when its file does not say where it stands, so the two are not
 born inside each other.

 @param geometry : `Taken over, as load_mesh takes it.`
 @param path : `Where it came from.`
 @return `Its position in the cast.`
*>
fn usz AppState.add_character(&self, rig::TriMesh geometry, String path)
{
	self.end_focus_gestures();
	if (self.character_count() > 1 || self.has_mesh()) self.read_scene_clock();
	if (!self.cast.is_initialized()) self.cast.init(mem);
	if (self.cast.len() == 0) self.cast.push({});

	// Everyone already here, in the world, before the newcomer is placed.
	rig::Bounds taken;
	bool found;
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (!c.has_mesh()) continue;
		rig::Bounds b = c.world_bounds();
		taken = found ? (rig::Bounds){ math::min(taken.min, b.min), math::max(taken.max, b.max) } : b;
		found = true;
	}

	self.lift_authored();
	self.cast[(sz)self.active] = self.focus;
	self.cast.push({});
	self.active = (usz)self.cast.len() - 1;
	self.focus = new_character({}, "", {}, {}, {}, false);
	self.load_mesh(geometry, path, reframe: false);

	if (found && self.has_mesh() && self.doc.model_transform.location == (Vec3){})
	{
		rig::Bounds mine = self.world_bounds();
		float gap = math::max(taken.max.x - taken.min.x, mine.max.x - mine.min.x) * 0.25f;
		if (self.doc.model_transform.rotation.v == (float[<4>]){}) self.doc.model_transform.rotation = quaternion::IDENTITY;
		self.doc.model_transform.location.x = taken.max.x + gap - mine.min.x;
	}
	self.adopt_scene_clock();
	self.focus_generation = next_generation();
	self.reindex_current_model();
	return self.active;
}

<*
 Take the character at `i` out of the scene, freeing everything it held. The
 focus moves to a neighbour first when it is the one going.

 Its unsaved work goes with it; asking first is the caller's.

 @return `False for the last character, which the app always keeps.`
*>
fn bool AppState.remove_character(&self, usz i)
{
	if (self.character_count() < 2 || i >= (usz)self.cast.len()) return false;
	if (!self.focus_may_move()) return false;
	if (i == self.active) self.focus_character(i == 0 ? 1 : i - 1);

	usz home = self.active;
	self.swap_focus(i);
	self.free_character_state();
	self.swap_focus(home);
	self.cast.remove_at((sz)i);
	if (self.active > i) self.active--;
	if (self.cast.len() == 1) self.cast.clear();
	self.focus_generation = next_generation();
	self.reindex_current_model();
	self.refresh_ui();
	return true;
}

<*
 Free every character but the focus and leave it the only one. What opening a
 model with File > Open does: it replaces the scene, not one character in it.
*>
fn void AppState.drop_other_characters(&self)
{
	if (self.cast.len() == 0) return;
	self.free_cast();
	self.focus_generation = next_generation();
}

// ---------------------------------------------------------------------------
// The shared clock
// ---------------------------------------------------------------------------

<*
 Where in its own clip a character is at scene time `t`: wrapped when the clip
 loops, held at the ends when it does not.
*>
fn float clip_local_time(AnimTemplate* clip, float t) @local
{
	if (!clip || clip.duration <= 0.0f) return 0.0f;
	if (t <= 0.0f) return 0.0f;
	if (clip.loop) return t - math::floor(t / clip.duration) * clip.duration;
	return math::min(t, clip.duration);
}

<*
 The clip the shared clock moves on this character: the one open in its
 timeline, or the one playing when nothing is open. NO_ANIM when neither.
*>
fn AnimRef AppState.scene_clip(&self)
{
	if (self.editing.valid()) return self.editing;
	if (self.animating) return self.current_ref;
	return NO_ANIM;
}

<*
 Show this character's clip at the scene's time, running or stopped as the scene
 is. What a character does when it is handed the clock: the focus on arrival, and
 every waiting one on every frame.

 @param dt : `Real seconds since the last frame, for the secondary motion.`
 @return `Whether the pose on screen changed.`
*>
fn bool AppState.follow_scene_clock(&self, float dt = 0.0f)
{
	if (self.pose_edit_active) return false;
	AnimRef ref = self.scene_clip();
	if (!ref.valid()) return false;
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return false;
	float local = clip_local_time(clip, self.scene_time);
	bool showing = self.animating && self.current_ref.same(ref);

	if (self.scene_running)
	{
		if (!showing && !self.start_animation_ref(ref)) return false;
		self.anim_paused = false;
		self.anim_time = local;
		if (self.current_ref.same(self.editing)) self.edit_time = local;
		self.refresh_animation(dt);
		return true;
	}
	if (!showing) return self.park_clip(ref, local);
	if (self.anim_paused && self.anim_time == local) return false;
	self.anim_paused = true;
	return self.scrub_to(local);
}

<*
 Take the scene's time off the focus, which is the master: its clip playing or
 parked, else its open clip's playhead. A focus with no clip leaves the time as
 it was.
*>
fn void AppState.read_scene_clock(&self)
{
	if (self.animating && self.current_ref.valid())
	{
		self.scene_time = self.anim_time;
		self.scene_running = !self.anim_paused;
	}
	else if (self.editing.valid())
	{
		self.scene_time = self.edit_time;
		self.scene_running = false;
	}
	else
	{
		self.scene_running = false;
	}
}

<*
 The focus has just arrived: put its clip at the scene's time.
*>
fn void AppState.adopt_scene_clock(&self)
{
	if (self.character_count() < 2) return;
	(void)self.follow_scene_clock();
}

<*
 Move every waiting character to the focus's time. Called once a frame after the
 focus's own clock has ticked.

 **The focus is the master.** The time is read off the clip on its timeline —
 playing, or parked where the playhead was left — and every other character shows
 its own clip at that instant, wrapped or held to its own length. A focus with no
 clip leaves the time where it was, so a character scrubbed to a frame and then
 left stays on that frame while another is posed against it.

 @param dt : `Real seconds since the last frame.`
 @return `Whether any waiting character moved, so the views need a repaint.`
*>
fn bool AppState.sync_cast(&self, float dt)
{
	if (self.character_count() < 2) return false;
	self.read_scene_clock();

	bool moved;
	self.@each_parked(; usz i)
	{
		if (!self.holds_pose && !self.hidden && self.follow_scene_clock(dt)) moved = true;
	};
	return moved;
}

// ---------------------------------------------------------------------------
// Library re-reads
// ---------------------------------------------------------------------------

<*
 Before a library re-read: let every waiting character's clips go, remembering
 them by name.

 A playing clip is a shallow copy whose keyframes are the pack's, and a re-read
 frees the packs, so every character's player stops — not only the focus's — and
 its refs are held as file-and-name to be looked up again afterwards.

 @param only_pack : `Only characters touching this pack; -1 for all of them.`
 @return `One entry per position in the cast. The caller owes restore_cast_refs.`
*>
fn LibraryRefs[] AppState.remember_cast_refs(&self, int only_pack = -1)
{
	if (self.cast.len() == 0) return {};
	LibraryRefs[] out = alloc::new_array(mem, LibraryRefs, (sz)self.cast.len());
	self.@each_parked(; usz i)
	{
		if (only_pack < 0 || self.editing.pack == only_pack || self.current_ref.pack == only_pack)
		{
			out[i] = self.remember_library_refs();
			self.stop_animation();
		}
	};
	return out;
}

<*
 After a library re-read: look every waiting character's clips up again.

 @param refs : `What remember_cast_refs returned; freed here.`
 @param rebuilt : `Whether packs was rebuilt from scratch, so every kept pack index is gone.`
*>
fn void AppState.restore_cast_refs(&self, LibraryRefs[] refs, bool rebuilt)
{
	if (refs.len == 0) return;
	if (rebuilt)
	{
		// The authored slots they left are gone with the list; each lands at the
		// end when it next comes in, and its refs are found again by name.
		foreach (usz i, &c : self.cast) if (i != self.active) c.authored_pack = -1;
	}
	self.@each_parked(; usz i)
	{
		self.reach_stale = true;
		if (i < refs.len && (refs[i].edit_name.len > 0 || refs[i].play_name.len > 0))
		{
			self.restore_library_refs(&refs[i]);
		}
		if (i < refs.len) refs[i].free();
	};
	alloc::free(mem, refs);
}

// ---------------------------------------------------------------------------
// Adding from the interface
// ---------------------------------------------------------------------------

<*
 Ask for `path` to be brought in as another character between frames. A file
 already loaded is focused instead, since two of the same file would save over
 each other.
*>
fn void AppState.request_add_character(&self, String path)
{
	int already = self.character_from(path);
	if (already >= 0)
	{
		self.focus_character((usz)already);
		return;
	}
	if (self.pending_add.len > 0) alloc::free(mem, self.pending_add.ptr);
	self.pending_add = path.copy(mem);
}

<*
 Bring in the model `request_add_character` asked for. With no model open yet
 it is simply opened: there is nobody for it to stand beside.
*>
fn void AppState.service_pending_add(&self)
{
	String path = self.pending_add;
	self.pending_add = "";
	defer if (path.len > 0) alloc::free(mem, path.ptr);
	if (path.len == 0) return;
	if (!self.focus_may_move()) return;

	rig::TriMesh? loaded = rig::load_gltf(mem, path);
	if (catch error = loaded)
	{
		self.@notice("could not open %s: %s", file_stem(path), error);
		self.refresh_ui();
		return;
	}
	if (!self.has_mesh() && self.character_count() == 1)
	{
		self.load_mesh(loaded, path);
		self.remember_project(path);
	}
	else
	{
		self.add_character(loaded, path);
		// It was set down beside the others, which may be out of view.
		self.frame_cast();
		self.@notice("Added %s · click a character to edit it", self.label());
	}
	self.refresh_ui();
}

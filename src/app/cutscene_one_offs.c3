<*
 One-off acting: clips that belong to one cutscene, made and edited with the
 character's own tools, saved with the scene and baked into the cutscene file.

 **Editing one.** The actor's character becomes the focus and its own clips,
 bindings and history are put aside for the length of the edit (`OneOffEdit`):
 its authored pack holds only the one-off, its Animations list shows only it, and
 it gets a history of its own. So every tool edits the one-off as an ordinary
 clip, Ctrl+Z steps only its edits, and nothing of it can reach the character's
 files: a save while editing swaps the character's own state back in for the
 length of the save (`@as_own_character`). Each edit is copied into the cutscene
 as it lands, with no step; Back to cutscene records the whole edit as one step of
 the cutscene history. What was done to the document itself meanwhile (the pose
 library, a joint's limits) moves onto the character's own history on the way
 back. A cutscene edit or undo, or another character focused, goes back first.

 **Lengths.** A strip that does not loop follows its one-off's length; one that
 loops keeps its own.
*>
module crig;

import rig;
import std::math;

const String CUT_ONE_OFF_NAME = "one_off";
const float CUT_ONE_OFF_LENGTH = 2.0f;

<* A one-off being edited: where it is, and what its character had before. *>
struct OneOffEdit
{
	bool open;
	uint character; // the character's id
	usz cutscene;
	String row;     // owned
	String name;    // owned
	uint strip;     // the id of the strip it was opened from
	// The character's own clips, bindings and history while the one-off has the live ones.
	bool swapped;
	AnimTemplate[] kept_clips;
	BoundList kept_bindings;
	UndoStack kept_history;
	uint kept_saved;
	bool kept_dirty;
	AnimRef kept_editing;
	float kept_edit_time;
	sz kept_layer;
	AnimRef kept_layer_ref;
	// The cutscenes when it opened, the one step it becomes, and whether anything changed.
	CutSnapshot before;
	bool changed;
	bool preview_was;
	uint synced;     // the history revision last copied into the cutscene
	float shown_at;  // the cutscene time the others were last posed at
}

fn bool AppState.one_off_open(&self) => self.one_off.open;

<* Whether the focus is the character a one-off is being edited on, holding its state now. *>
fn bool AppState.one_off_here(&self) => self.one_off.open && self.one_off.swapped && self.one_off.character == self.id;

// ---------------------------------------------------------------------------
// The list, each edit one cutscene step

// A name the actor's one-offs and its character's clips do not have: `base`, then `base_2`.
fn String AppState.free_one_off_name(&self, Cutscene* c, usz actor, String base)
{
	String row = c.actors[actor].row;
	sz holder = self.actor_character(row);
	for (int n = 1; n < 1000; n++)
	{
		String candidate = n == 1 ? base.copy(mem) : string::format(mem, "%s_%d", base, n);
		bool used = c.one_off_index(row, candidate) >= 0;
		if (!used && holder >= 0)
		{
			foreach (bound : self.cut_bindings_of((usz)holder)) used = used || bound.clip == candidate;
		}
		if (!used) return candidate;
		candidate.free(mem);
	}
	return base.copy(mem);
}

<* The clip names a character binds: its own, also while a one-off has its live ones. *>
fn BoundClip[] AppState.cut_bindings_of(&self, usz character)
{
	Character* c = self.character(character);
	if (self.one_off.open && self.one_off.swapped && c.id == self.one_off.character) return self.one_off.kept_bindings.array_view();
	return c.doc.animations.array_view();
}

<* An empty clip as long as `length`: one key holding nothing, so it plays and saves like any. *>
fn AnimTemplate empty_one_off(String name, float length)
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 1);
	frames[0] = { .time = 0.0f };
	return { .name = name.copy(mem), .duration = length, .keyframes = frames, .blend = SMOOTH, .owned = true };
}

<*
 A new, empty one-off for `actor` and a play strip of it at the playhead, picked. One undo step.

 @return "The strip's index, or -1 for no such actor"
*>
fn sz AppState.new_cut_one_off(&self, usz actor, float length = CUT_ONE_OFF_LENGTH)
{
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len || !(length > 0.0f)) return -1;
	self.cut_checkpoint();
	c = self.cutscene();
	String name = self.free_one_off_name(c, actor, CUT_ONE_OFF_NAME);
	defer name.free(mem);
	usz count = c.one_offs.len;
	CutOneOff[] grown = alloc::new_array(mem, CutOneOff, (sz)count + 1);
	foreach (usz k, one : c.one_offs) grown[k] = one;
	grown[count] = { .row = c.actors[actor].row.copy(mem), .clip = empty_one_off(name, length) };
	if (count > 0) alloc::free(mem, c.one_offs);
	c.one_offs = grown;
	CutStrip s = cut_strip(PLAY, self.cut_time, self.cut_time + length);
	s.clip = name.copy(mem);
	s.one_off = true;
	return self.put_cut_strip(actor, s);
}

<*
 Another play strip of `actor`'s one-off `name` at the playhead, as long as the clip. One undo step.

 @return "Its index, or -1 for no such one-off"
*>
fn sz AppState.add_cut_one_off_play(&self, usz actor, String name)
{
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len) return -1;
	sz at = c.one_off_index(c.actors[actor].row, name);
	if (at < 0) return -1;
	float frame = c.fps > 0.0f ? 1.0f / c.fps : 0.01f;
	CutStrip s = cut_strip(PLAY, self.cut_time, self.cut_time + math::max(c.one_offs[at].clip.duration, frame));
	s.clip = name.copy(mem);
	s.one_off = true;
	return self.add_cut_strip(actor, s);
}

<*
 Rename `actor`'s one-off `name`, and every strip of the actor that plays it. One undo step.

 @return "False for no such one-off, an empty name, or one the actor already plays"
*>
fn bool AppState.rename_cut_one_off(&self, usz actor, String name, String to)
{
	Cutscene* c = self.cutscene();
	String wanted = to.trim();
	if (!c || actor >= c.actors.len || wanted.len == 0) return false;
	String row = c.actors[actor].row;
	sz at = c.one_off_index(row, name);
	if (at < 0) return false;
	if (name == wanted) return true;
	if (c.one_off_index(row, wanted) >= 0)
	{
		self.@notice("%s already has a one-off called %s", row, wanted);
		return false;
	}
	String kept = name.copy(mem);
	defer kept.free(mem);
	self.cut_checkpoint();
	c = self.cutscene();
	at = c.one_off_index(c.actors[actor].row, kept);
	AnimTemplate* clip = &c.one_offs[at].clip;
	clip.name.free(mem);
	clip.name = wanted.copy(mem);
	foreach (&s : c.actors[actor].strips)
	{
		if (!s.one_off || s.clip != kept) continue;
		s.clip.free(mem);
		s.clip = wanted.copy(mem);
	}
	self.cutscenes_changed();
	return true;
}

<*
 Delete `actor`'s one-off `name` and every strip of the actor that plays it. One undo step.

 @return "False for no such one-off"
*>
fn bool AppState.delete_cut_one_off(&self, usz actor, String name)
{
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len || c.one_off_index(c.actors[actor].row, name) < 0) return false;
	String kept = name.copy(mem);
	defer kept.free(mem);
	self.cut_checkpoint();
	c = self.cutscene();
	CutActor* who = &c.actors[actor];
	usz left;
	foreach (usz k, &s : who.strips)
	{
		if (s.one_off && s.clip == kept)
		{
			s.free(mem);
			continue;
		}
		who.strips[left++] = *s;
	}
	who.strips = who.strips[:left];
	if (left == 0 && who.strips.ptr)
	{
		alloc::free(mem, who.strips.ptr);
		who.strips = {};
	}
	c.remove_one_off(c.one_off_index(who.row, kept));
	self.cutscenes_changed();
	return true;
}

<* Take one-off `at` out of the list. *>
fn void Cutscene.remove_one_off(&self, sz at)
{
	if (at < 0 || (usz)at >= self.one_offs.len) return;
	self.one_offs[at].free(mem);
	for (usz k = (usz)at; k + 1 < self.one_offs.len; k++) self.one_offs[k] = self.one_offs[k + 1];
	self.one_offs = self.one_offs[:self.one_offs.len - 1];
	if (self.one_offs.len == 0)
	{
		alloc::free(mem, self.one_offs.ptr);
		self.one_offs = {};
	}
}

<* Which one-offs some strip plays now, one flag each. The caller frees it. *>
fn bool[] Cutscene.played_one_offs(&self)
{
	if (self.one_offs.len == 0) return {};
	bool[] out = alloc::new_array(mem, bool, (sz)self.one_offs.len);
	foreach (usz i, &one : self.one_offs) out[i] = self.one_off_uses(one.row, one.clip.name) > 0;
	return out;
}

<*
 After a strip edit, the one-offs `played` says were played and no strip plays now are deleted:
 a one-off goes with the last strip that plays it, in that edit's own step.

 @param played : "From played_one_offs before the edit; taken over"
*>
fn void Cutscene.drop_unplayed(&self, bool[] played)
{
	defer if (played.len > 0) free(played);
	for (usz i = math::min((usz)played.len, (usz)self.one_offs.len); i > 0; i--)
	{
		CutOneOff* one = &self.one_offs[i - 1];
		if (played[i - 1] && self.one_off_uses(one.row, one.clip.name) == 0) self.remove_one_off((sz)i - 1);
	}
}

// ---------------------------------------------------------------------------
// Editing one

<* The strip a one-off edit was opened from, in the active cutscene. *>
fn CutStrip* AppState.one_off_strip(&self, usz* actor = null)
{
	if (!self.one_off.open || self.cut_active != self.one_off.cutscene) return null;
	Cutscene* c = self.cutscene();
	usz a;
	usz k;
	if (!c || !c.find_strip(self.one_off.strip, &a, &k)) return null;
	if (actor) *actor = a;
	return &c.actors[a].strips[k];
}

<* The one-off being edited, in the cutscene. *>
fn CutOneOff* AppState.edited_one_off(&self)
{
	if (!self.one_off.open || self.one_off.cutscene >= (usz)self.cutscenes.len()) return null;
	Cutscene* c = self.cutscenes.get_ref((sz)self.one_off.cutscene);
	sz at = c.one_off_index(self.one_off.row, self.one_off.name);
	return at < 0 ? null : &c.one_offs[at];
}

// The character's own clips, bindings and history, exchanged with the ones the edit is using.
fn void AppState.swap_one_off_state(&self)
{
	AnimPack* pack = self.ensure_authored();
	AnimTemplate[] clips = pack.clips;
	pack.clips = self.one_off.kept_clips;
	self.one_off.kept_clips = clips;
	@swap(self.doc.animations, self.one_off.kept_bindings);
	@swap(self.undo_stack, self.one_off.kept_history);
	@swap(self.saved_revision, self.one_off.kept_saved);
	@swap(self.authored_dirty, self.one_off.kept_dirty);
	@swap(self.editing, self.one_off.kept_editing);
	@swap(self.edit_time, self.one_off.kept_edit_time);
	@swap(self.active_layer, self.one_off.kept_layer);
	@swap(self.active_layer_ref, self.one_off.kept_layer_ref);
	self.one_off.swapped = !self.one_off.swapped;
	self.authored_index_stale = true;
	self.clear_animation_key_selection();
}

<*
 Run a block with the focus's own clips, bindings and history in place, when it is holding a
 one-off's: what saves and exports go through, so none of them writes the one-off.
*>
macro void AppState.@as_own_character(&self; @body())
{
	if (self.one_off_here())
	{
		self.swap_one_off_state();
		@body();
		self.swap_one_off_state();
	}
	else
	{
		@body();
	}
}

<*
 Edit the one-off strip `strip` of `actor` plays, with the character's own posing and timeline
 tools: its character becomes the focus, standing where the cutscene has it, the others posed at
 the same cutscene time; the clip's playhead is the strip's at the cutscene's.

 @return "False, with a notice, for a strip that plays no one-off, or an actor with no rigged character"
*>
fn bool AppState.edit_cut_one_off(&self, usz actor, usz strip)
{
	if (!self.cut_strip_exists(actor, strip)) return false;
	uint id = self.cutscene().actors[actor].strips[strip].id;
	if (self.one_off.open && self.one_off.strip == id) return true;
	if (self.one_off.open) (void)self.back_to_cutscene();
	if (!self.cut_strip_exists(actor, strip)) return false;
	Cutscene* c = self.cutscene();
	CutStrip* s = &c.actors[actor].strips[strip];
	CutOneOff* one = c.one_off_of(actor, s);
	if (!one)
	{
		self.@notice("this strip plays no one-off of the cutscene");
		return false;
	}
	sz holder = self.actor_character(c.actors[actor].row);
	if (holder < 0 || self.character((usz)holder).doc.dots.len() == 0)
	{
		self.@notice("%s has no rigged character to pose", c.actors[actor].row);
		return false;
	}
	if (!self.focus_may_move()) return false;
	self.end_focus_gestures();
	self.drop_cut_gesture();
	self.cancel_cut_pick();
	self.cut_playing = false;
	if ((usz)holder != self.active) (void)self.focus_character((usz)holder);

	// The cut time the edit opens at: the playhead when it is over the strip, else its start.
	c = self.cutscene();
	s = &c.actors[actor].strips[strip];
	if (self.cut_time < s.start || self.cut_time > s.end) self.cut_time = math::max(s.start, 0.0f);
	CutSnapshot before = self.cut_snapshot();
	bool preview_was = self.cut_preview;
	if (!self.set_cutscene_preview(true))
	{
		before.free();
		return false;
	}
	c = self.cutscene();
	s = &c.actors[actor].strips[strip];
	one = c.one_off_of(actor, s);
	self.stop_animation();
	self.drop_cut_shown();
	float local = cut_clip_local(s.offset + (self.cut_time - s.start) * s.speed, one.clip.duration, s.loop);
	// The one-off's state, swapped in for the character's own: its clip alone, bound, on a fresh history.
	(void)self.ensure_authored();
	AnimTemplate[] clips = alloc::new_array(mem, AnimTemplate, 1);
	clips[0] = clip_copy(mem, one.clip);
	self.one_off = {
		.open = true,
		.character = self.id,
		.cutscene = self.cut_active,
		.row = c.actors[actor].row.copy(mem),
		.name = one.clip.name.copy(mem),
		.strip = id,
		.before = before,
		.preview_was = preview_was,
		.kept_clips = clips,
		.kept_editing = { self.authored_pack, 0 },
		.kept_edit_time = local,
		.kept_layer = -1,
		.kept_layer_ref = NO_ANIM,
	};
	self.one_off.kept_bindings.init(mem);
	self.one_off.kept_bindings.push(owned_binding("", one.clip.name));
	self.one_off.kept_history.use_heap();
	self.swap_one_off_state();
	self.one_off.synced = self.undo_stack.revision;
	self.refresh_timeline_tracks(self.editing);
	(void)self.park_clip(self.editing, local);
	self.one_off.shown_at = -1.0f;
	(void)self.tick_one_off();
	self.cutscenes_changed();
	self.@notice("editing the one-off %s of %s · Back to cutscene returns", self.one_off.name, self.one_off.row);
	self.refresh_ui();
	return true;
}

<*
 Copy the one-off's latest edit into the cutscene, with no step: its keys, and the length of each
 strip of it that does not loop. Only while its character is the focus.
*>
fn void AppState.sync_one_off(&self)
{
	if (!self.one_off_here() || self.undo_stack.revision == self.one_off.synced) return;
	CutOneOff* one = self.edited_one_off();
	AnimTemplate* edited = self.clip(self.editing);
	if (!edited)
	{
		AnimPack* pack = self.authored();
		if (pack && pack.clips.len > 0) edited = &pack.clips[0];
	}
	self.one_off.synced = self.undo_stack.revision;
	if (!one || !edited) return;
	AnimTemplate copy = clip_copy(mem, *edited, self.one_off.name);
	one.clip.free(mem);
	one.clip = copy;
	self.one_off.changed = true;
	Cutscene* c = self.cutscenes.get_ref((sz)self.one_off.cutscene);
	int actor = c.actor_by_row(self.one_off.row);
	if (actor >= 0)
	{
		foreach (&s : c.actors[actor].strips)
		{
			if (!s.one_off || s.clip != self.one_off.name || s.loop || !(s.speed > 0.0f)) continue;
			float span = (copy.duration - s.offset) / s.speed;
			if (span > CUT_SAME_TIME) s.end = s.start + span;
		}
	}
	self.cut_revision = next_generation();
}

<* Sync the one-off from wherever the focus is. *>
fn void AppState.sync_one_off_now(&self)
{
	if (!self.one_off.open) return;
	sz at = self.character_by_id(self.one_off.character);
	if (at < 0) return;
	self.@as_character((usz)at) { self.sync_one_off(); };
}

// A binding list's strings and the list.
fn void free_bindings(BoundList* list) @local
{
	foreach (&b : *list)
	{
		if (b.file.len > 0) b.file.free(mem);
		if (b.clip.len > 0) b.clip.free(mem);
	}
	list.free();
}

<* The position of the character whose id is `id`, or -1. *>
fn sz AppState.character_by_id(&self, uint id)
{
	for (usz i = 0; i < self.character_count(); i++) if (self.character(i).id == id) return (sz)i;
	return -1;
}

<* The cutscene time the one-off's playhead stands for: the strip's start plus its clip time at its speed. *>
fn float AppState.one_off_cut_time(&self)
{
	CutStrip* s = self.one_off_strip();
	if (!s || !self.one_off_here()) return self.cut_time;
	float local = self.animating && self.current_ref.same(self.editing) ? self.anim_time : self.edit_time;
	float speed = s.speed > 0.0f ? s.speed : 1.0f;
	Cutscene* c = self.cutscene();
	return math::clamp(s.start + (local - s.offset) / speed, 0.0f, math::max(c.duration, 0.0f));
}

<*
 Move the one-off's playhead to the clip time cutscene time `t` stands for, inside its strip.

 @return "False when no one-off is edited on the focus"
*>
fn bool AppState.one_off_seek(&self, float t)
{
	CutStrip* s = self.one_off_strip();
	AnimTemplate* clip = self.clip(self.editing);
	if (!s || !clip || !self.one_off_here()) return false;
	float at = math::clamp(t, s.start, math::max(s.end, s.start));
	float local = cut_clip_local(s.offset + (at - s.start) * s.speed, clip.duration, s.loop);
	(void)self.prepare_timeline_navigation();
	if (!self.scrub_to(local)) (void)self.park_clip(self.editing, local);
	self.edit_time = local;
	(void)self.tick_one_off();
	return true;
}

<*
 Once a frame while a one-off is edited: copy the latest edit into the cutscene, and pose the
 other actors, and stand this one, at the cutscene time its playhead stands for.

 @return "Whether the actors moved"
*>
fn bool AppState.tick_one_off(&self)
{
	if (!self.one_off.open) return false;
	// Its character went from the focus, or its cutscene or strip went: the edit is over.
	if (!self.one_off_here() || !self.one_off_strip() || !self.edited_one_off())
	{
		(void)self.back_to_cutscene();
		return true;
	}
	self.sync_one_off();
	float t = self.one_off_cut_time();
	if (t == self.one_off.shown_at && self.cut_time == t) return false;
	self.cut_time = t;
	self.one_off.shown_at = t;
	self.apply_cutscene();
	return true;
}

<*
 Leave the one-off edit: its last edit copied into the cutscene, the character's own clips,
 bindings and history back (with what was done to the document meanwhile on it), and the whole edit
 one step of the cutscene history. The cutscene's playhead is where the clip's was.

 @return "False when no one-off was being edited"
*>
fn bool AppState.back_to_cutscene(&self)
{
	if (!self.one_off.open) return false;
	OneOffEdit* edit = &self.one_off;
	sz at = self.character_by_id(edit.character);
	float t = self.cut_time;
	if (at >= 0)
	{
		self.@as_character((usz)at)
		{
			if (self.one_off_here())
			{
				self.end_focus_gestures();
				(void)self.prepare_timeline_navigation();
				self.sync_one_off();
				t = self.one_off_cut_time();
				self.stop_animation();
				UndoStack scratch = self.undo_stack;
				AnimPack* pack = self.ensure_authored();
				AnimTemplate[] made = pack.clips;
				BoundList bindings = self.doc.animations;
				pack.clips = {};
				self.doc.animations = {};
				self.undo_stack = {};
				self.swap_one_off_state();
				usz taken = self.undo_stack.take_document_edits(&scratch);
				if (taken > 0) self.@notice("%d edits to the rig made while editing the one-off are kept on its own history", taken);
				scratch.free();
				// Clips made beside the one-off are kept as the character's own, one step each.
				foreach (usz i, clip : made)
				{
					if (i == 0)
					{
						AnimTemplate gone = clip;
						gone.free(mem);
						continue;
					}
					(void)self.author_clip(clip);
				}
				if (made.len > 0) alloc::free(mem, made);
				free_bindings(&bindings);
				if (self.editing.valid()) self.refresh_timeline_tracks(self.editing);
			}
		};
	}
	else
	{
		// The character went with its own state; what is left here is the one-off's.
		foreach (&clip : edit.kept_clips) clip.free(mem);
		if (edit.kept_clips.len > 0) alloc::free(mem, edit.kept_clips);
		free_bindings(&edit.kept_bindings);
		edit.kept_history.free();
	}
	CutSnapshot before = edit.before;
	bool changed = edit.changed;
	bool preview_was = edit.preview_was;
	edit.row.free(mem);
	edit.name.free(mem);
	*edit = {};
	// After the edit is closed, so the record does not come back here.
	if (changed)
	{
		self.cut_record(before);
	}
	else
	{
		before.free();
	}
	self.cut_time = t;
	if (preview_was)
	{
		self.apply_cutscene();
	}
	else
	{
		self.leave_cutscene_preview();
	}
	self.cutscenes_changed();
	self.@notice("back to the cutscene at %.2f s", self.cut_time);
	self.refresh_ui();
	return true;
}

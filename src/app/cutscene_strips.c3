<*
 A cutscene's strips edited: the selection, adding, changing and deleting a
 strip, a timeline drag as one undo step, and the ground point a turn faces.
 After each, the lanes settle around the strip edited (cut_settle_strips).
*>
module crig;

import std::math;

// How long a turn added from the timeline takes.
const float CUT_TURN_LENGTH = 0.5f;

<* What the 3D view's next click on the level's ground is for. *>
enum CutGroundPick : char
{
	NONE,
	NEW_TURN,    // a turn of `cut_pick_actor`, at the playhead, facing the point
	TURN_TARGET, // the turn `cut_pick_strip` faces the point
	PATH_KNOT,   // a knot on the end of the picked path, click after click
}

// ---------------------------------------------------------------------------
// The selection

// Whether a strip before position (a, k) of the cutscene already has `id`.
fn bool cut_id_taken_before(Cutscene* c, usz a, usz k, uint id) @local
{
	foreach (usz i, &who : c.actors)
	{
		if (i > a) break;
		foreach (usz j, &s : who.strips)
		{
			if (i == a && j >= k) break;
			if (s.id == id) return true;
		}
	}
	return false;
}

<* Every strip an id unique in its cutscene; a selection or a pick whose strip is gone is dropped. *>
fn void AppState.number_cut_strips(&self)
{
	foreach (&c : self.cutscenes)
	{
		foreach (usz a, &who : c.actors)
		{
			foreach (usz k, &s : who.strips)
			{
				if (s.id == 0 || cut_id_taken_before(c, a, k, s.id)) s.id = next_generation();
			}
		}
	}
	Cutscene* active = self.cutscene();
	usz actor;
	usz strip;
	if (self.cut_selected != 0 && (!active || !active.find_strip(self.cut_selected, &actor, &strip))) self.cut_selected = 0;
	if (self.cut_lane_actor > 0 && (!active || self.cut_lane_actor > active.actors.len)) self.cut_lane_actor = 0;
	if (self.cut_pick == TURN_TARGET && (!active || !active.find_strip(self.cut_pick_strip, &actor, &strip))) self.cancel_cut_pick();
	self.check_cut_path_pick();
}

<* Where the selected strip is in the active cutscene. *>
fn bool AppState.cut_selection(&self, usz* actor, usz* strip)
{
	Cutscene* c = self.cutscene();
	return c && c.find_strip(self.cut_selected, actor, strip);
}

<* The selected strip, or null. *>
fn CutStrip* AppState.cut_selected_strip(&self)
{
	usz actor;
	usz strip;
	if (!self.cut_selection(&actor, &strip)) return null;
	return &self.cutscene().actors[actor].strips[strip];
}

<*
 Pick strip `strip` of `actor` in the active cutscene; its actor gets what is added next. A choice, not an edit.

 @return "False, with nothing picked, for no such strip"
*>
fn bool AppState.select_cut_strip(&self, usz actor, usz strip)
{
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len || strip >= c.actors[actor].strips.len)
	{
		self.cut_selected = 0;
		return false;
	}
	self.cut_selected = c.actors[actor].strips[strip].id;
	self.cut_lane_actor = actor + 1;
	return true;
}

fn void AppState.clear_cut_selection(&self) => self.cut_selected = 0;

<* The actor what is added goes to: the selected strip's, else the lane pressed last, else the focused character's; -1 for none. *>
fn sz AppState.cut_target_actor(&self)
{
	Cutscene* c = self.cutscene();
	if (!c || c.actors.len == 0) return -1;
	usz actor;
	usz strip;
	if (self.cut_selection(&actor, &strip)) return (sz)actor;
	if (self.cut_lane_actor > 0 && self.cut_lane_actor <= c.actors.len) return (sz)self.cut_lane_actor - 1;
	return self.actor_row.len > 0 ? c.actor_by_row(self.actor_row) : -1;
}

<*
 The focus's actor in the active cutscene becomes the one pieces go to; a picked strip of another actor is let go.

 @return "Whether the target or the pick changed"
*>
fn bool AppState.target_focus_actor(&self)
{
	Cutscene* c = self.cutscene();
	if (!c || self.actor_row.len == 0) return false;
	int actor = c.actor_by_row(self.actor_row);
	if (actor < 0) return false;
	bool changed;
	usz picked;
	usz strip;
	if (self.cut_selection(&picked, &strip) && picked != (usz)actor)
	{
		self.clear_cut_selection();
		changed = true;
	}
	if (self.cut_lane_actor != (usz)actor + 1)
	{
		self.cut_lane_actor = (usz)actor + 1;
		changed = true;
	}
	return changed;
}

// ---------------------------------------------------------------------------
// Edits, each one undo step

fn bool AppState.cut_strip_exists(&self, usz actor, usz strip)
{
	Cutscene* c = self.cutscene();
	return c && actor < c.actors.len && strip < c.actors[actor].strips.len;
}

<*
 Put `edited` in place of strip `strip` of `actor` in the active cutscene, keeping
 its id; the lanes settle around it, and a walk tied to a move whose times changed
 takes them (cut_carry_ties). One undo step, none when nothing changes.

 @param edited : "Owned from here"
 @return "False for no such strip"
*>
fn bool AppState.set_cut_strip(&self, usz actor, usz strip, CutStrip edited)
{
	if (!self.cut_strip_exists(actor, strip))
	{
		edited.free(mem);
		return false;
	}
	CutStrip* now = &self.cutscene().actors[actor].strips[strip];
	// A move resized, put on another path or given another clip or ground speed plays at the rate that keeps its feet on the ground.
	if (edited.kind == MOVE && (edited.start != now.start || edited.end != now.end || edited.path != now.path
		|| edited.clip != now.clip || edited.ground_speed != now.ground_speed)) self.fit_walk_speed(actor, &edited);
	if (now.same_as(&edited))
	{
		edited.free(mem);
		return true;
	}
	self.cut_checkpoint();
	bool[] played = self.cutscene().played_one_offs();
	CutActor* who = &self.cutscene().actors[actor];
	CutTie[] ties = cut_ties(mem, who.strips, self.cutscene().paths);
	defer free(ties);
	edited.id = who.strips[strip].id;
	who.strips[strip].free(mem);
	who.strips[strip] = edited;
	(void)cut_settle_strips(mem, &who.strips, strip);
	// A walk that spanned its move follows the move's new times.
	(void)cut_carry_ties(mem, &who.strips, ties);
	self.cutscene().drop_unplayed(played);
	self.fit_paired_speeds(actor);
	self.cutscenes_changed();
	return true;
}

<*
 Add `strip` to `actor` of the active cutscene and pick it; the lanes settle around it. One undo step.

 @param strip : "Owned from here"
 @return "Its index, or -1 for no such actor"
*>
fn sz AppState.add_cut_strip(&self, usz actor, CutStrip strip)
{
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len)
	{
		strip.free(mem);
		return -1;
	}
	self.cut_checkpoint();
	return self.put_cut_strip(actor, strip);
}

<*
 `add_cut_strip` inside a step already taken: the strip goes in, the lanes settle, and a one-off
 whose last strip the settling covered goes with it.

 @param strip : "Owned from here"
 @require self.cutscene() != null && actor < self.cutscene().actors.len : "No such actor"
*>
fn sz AppState.put_cut_strip(&self, usz actor, CutStrip strip)
{
	Cutscene* c = self.cutscene();
	bool[] played = c.played_one_offs();
	CutActor* who = &c.actors[actor];
	// A move the new strip cuts back takes its walk with it.
	CutTie[] ties = cut_ties(mem, who.strips, c.paths);
	defer free(ties);
	usz count = who.strips.len;
	// An id of its own now, so it is found again after the lanes settle.
	strip.id = next_generation();
	uint id = strip.id;
	slice_push(mem, &who.strips, strip);
	usz at = cut_settle_strips(mem, &who.strips, count);
	(void)cut_carry_ties(mem, &who.strips, ties);
	foreach (usz k, &s : who.strips) if (s.id == id) at = k;
	c.drop_unplayed(played);
	self.fit_paired_speeds(actor);
	self.cutscenes_changed();
	self.cut_selected = who.strips[at].id;
	self.cut_lane_actor = actor + 1;
	return (sz)at;
}

<*
 Delete strip `strip` of `actor` in the active cutscene. One undo step.

 @return "False for no such strip"
*>
fn bool AppState.delete_cut_strip(&self, usz actor, usz strip)
{
	if (!self.cut_strip_exists(actor, strip)) return false;
	self.cut_checkpoint();
	bool[] played = self.cutscene().played_one_offs();
	CutActor* who = &self.cutscene().actors[actor];
	who.strips[strip].free(mem);
	slice_remove_at(mem, &who.strips, strip);
	// A one-off goes with the last strip that plays it, in this same step.
	self.cutscene().drop_unplayed(played);
	// A walk over a move that went may walk with another one now.
	self.fit_paired_speeds(actor);
	self.cutscenes_changed();
	return true;
}

<*
 A play strip of `clip` for `actor` at the playhead, as long as one pass of the
 clip and looping when the clip loops. Over a move the actor walks then, it runs
 to that move's end and loops: a walk, whose speed follows the move. One undo step.

 @return "Its index, or -1 when the actor's character has no such clip"
*>
fn sz AppState.add_cut_play(&self, usz actor, String clip)
{
	// Its character's own clips, not a one-off's state.
	(void)self.back_to_cutscene();
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len) return -1;
	sz holder = self.actor_character(c.actors[actor].row);
	if (holder < 0) return -1;
	bool found;
	float length;
	bool loop;
	self.@as_character((usz)holder)
	{
		AnimRef ref;
		if (AnimTemplate* played = self.bound_clip_named(clip, &ref))
		{
			found = true;
			length = played.duration;
			loop = played.loop;
		}
	};
	if (!found) return -1;
	float frame = c.fps > 0.0f ? 1.0f / c.fps : 0.01f;
	CutStrip s = cut_strip(PLAY, self.cut_time, self.cut_time + math::max(length, frame));
	s.loop = loop;
	sz move = cut_move_at(c.actors[actor].strips, self.cut_time, c.paths);
	if (move >= 0)
	{
		s.end = c.actors[actor].strips[move].end;
		s.loop = true;
	}
	s.clip = clip.copy(mem);
	return self.add_cut_strip(actor, s);
}

<*
 A play of an Assets clip for `actor` at the playhead, as `add_cut_play` lays one.
 A clip his character lacks is bound to him first, as the focus, so Ctrl+Z takes
 back the play and then the binding.

 @param [&in] c : "The clip"
 @return "The new strip's index, or -1, with a notice, when he cannot play it"
*>
fn sz AppState.add_cut_asset_play(&self, usz actor, AssetClip* c)
{
	// The character's own bindings, not a one-off's.
	(void)self.back_to_cutscene();
	Cutscene* cut = self.cutscene();
	if (!cut || actor >= cut.actors.len) return -1;
	String row = cut.actors[actor].row.tcopy();
	sz holder = self.actor_character(row);
	if (holder < 0)
	{
		self.@notice("%s has no character to play %s", row, c.name);
		return -1;
	}
	// An authored row is the focus's own clip; another's same name is another clip.
	if (c.authored() && (usz)holder != self.active)
	{
		self.@notice("%s is %s's own unsaved clip", c.name, self.label());
		return -1;
	}
	Character* who = self.character((usz)holder);
	bool bound = who.binds_clip(c.file, c.name);
	if (!bound)
	{
		if (who.level_read)
		{
			self.@notice("%s plays the level's clips only", row);
			return -1;
		}
		if (has_bound_clip_named(&who.doc, c.name))
		{
			self.@notice("%s already has a clip named %s", row, c.name);
			return -1;
		}
		// Bound on the focus, whose history `undo_latest` weighs against the cutscene's.
		if ((usz)holder != self.active && !self.focus_character((usz)holder)) return -1;
		if (!self.bind_asset_clip(c)) return -1;
	}
	sz laid = self.add_cut_play(actor, c.name);
	if (laid < 0)
	{
		self.@notice("%s has no clip %s", row, c.name);
		return -1;
	}
	if (!bound) self.@notice("added %s to %s's clips", c.name, row);
	return laid;
}

<*
 A turn for `actor` at the playhead, CUT_TURN_LENGTH long, toward the actor whose row is `row`, else toward `point`. One undo step.

 @return "Its index, or -1 for no such actor"
*>
fn sz AppState.add_cut_turn(&self, usz actor, String row = "", Vec3 point = {})
{
	CutStrip s = cut_strip(TURN, self.cut_time, self.cut_time + CUT_TURN_LENGTH);
	if (row.len > 0) s.target_row = row.copy(mem);
	s.target = point;
	return self.add_cut_strip(actor, s);
}

// ---------------------------------------------------------------------------
// A drag on the timeline

<* Begin a drag: the cutscenes as they are now are kept, to become its undo step or to be put back. *>
fn bool AppState.begin_cut_gesture(&self)
{
	if (!self.cutscene()) return false;
	self.drop_cut_gesture();
	self.cut_gesture = self.cut_snapshot();
	self.cut_gesture_open = true;
	return true;
}

<* Strip `strip` of `actor` as it was when the drag began, or null. *>
fn CutStrip* AppState.cut_gesture_strip(&self, usz actor, usz strip)
{
	if (!self.cut_gesture_open || self.cut_gesture.active >= self.cut_gesture.cutscenes.len) return null;
	Cutscene* was = &self.cut_gesture.cutscenes[self.cut_gesture.active];
	if (actor >= was.actors.len || strip >= was.actors[actor].strips.len) return null;
	return &was.actors[actor].strips[strip];
}

<*
 During a drag, strip `strip` of `actor` runs from `start` to `end`; with `front`
 its clip stays where it was in time as its start moves. A move takes the walks
 tied to it along. The preview follows.

 @return "False outside a drag or for no such strip"
*>
fn bool AppState.drag_cut_strip(&self, usz actor, usz strip, float start, float end, bool front)
{
	CutStrip* was = self.cut_gesture_strip(actor, strip);
	if (!was || !self.cut_strip_exists(actor, strip)) return false;
	CutStrip* s = &self.cutscene().actors[actor].strips[strip];
	float old_start = s.start;
	float old_end = s.end;
	s.start = was.start;
	s.offset = was.offset;
	s.speed = was.speed;
	if (front)
	{
		s.trim_front(start);
	}
	else
	{
		s.start = start;
	}
	s.end = end;
	if (s.kind == MOVE)
	{
		self.fit_walk_speed(actor, s);
		self.drag_tied_plays(actor, strip);
	}
	self.fit_paired_speeds(actor);
	if (s.start != old_start || s.end != old_end) self.cutscenes_changed();
	return true;
}

<* Whether strip `other` of `actor` is a play tied to move `strip` as the drag began (cut_play_tied), so it moves with the drag. *>
fn bool AppState.cut_drag_carries(&self, usz actor, usz strip, usz other)
{
	CutStrip* held = self.cut_gesture_strip(actor, strip);
	if (!held || held.kind != MOVE || other == strip) return false;
	Cutscene* was = &self.cut_gesture.cutscenes[self.cut_gesture.active];
	CutStrip[] before = was.actors[actor].strips;
	return other < before.len && cut_play_tied(before, other, strip, was.paths);
}

// During a drag of move `strip`, each play tied to it as the drag began spans it again, its offset as it was.
fn void AppState.drag_tied_plays(&self, usz actor, usz strip)
{
	Cutscene* was = &self.cut_gesture.cutscenes[self.cut_gesture.active];
	CutStrip[] before = was.actors[actor].strips;
	CutStrip[] now = self.cutscene().actors[actor].strips;
	// A drag settles nothing until it lands, so the strips are where they were.
	if (before.len != now.len) return;
	for (usz k = 0; k < now.len; k++)
	{
		if (!self.cut_drag_carries(actor, strip, k)) continue;
		now[k].start = now[strip].start;
		now[k].end = now[strip].end;
		now[k].offset = before[k].offset;
	}
}

<*
 During a drag, play `strip` of `actor` ends at `end` and plays its clip faster or
 slower to fill the same passes: its speed scaled by its old length over the new,
 and held from then on. Never shorter than a frame. The preview follows.

 @return "False outside a drag or for no such play"
*>
fn bool AppState.drag_cut_speed(&self, usz actor, usz strip, float end)
{
	CutStrip* was = self.cut_gesture_strip(actor, strip);
	if (!was || was.kind != PLAY || !self.cut_strip_exists(actor, strip)) return false;
	Cutscene* c = self.cutscene();
	float frame = c.fps > 0.0f ? 1.0f / c.fps : 0.01f;
	end = math::max(end, was.start + frame);
	CutStrip* s = &c.actors[actor].strips[strip];
	float old_end = s.end;
	s.start = was.start;
	s.offset = was.offset;
	s.end = end;
	s.speed = was.speed * (was.end - was.start) / (end - was.start);
	// A walk stretched by hand keeps the pace it was given.
	s.speed_held = was.speed_held || end != was.end;
	if (s.end != old_end) self.cutscenes_changed();
	return true;
}

<*
 During a drag, play `strip` of `actor` fades in over `fade` seconds, from none to
 its whole length. The preview follows.

 @return "False outside a drag or for no such play"
*>
fn bool AppState.drag_cut_fade(&self, usz actor, usz strip, float fade)
{
	CutStrip* was = self.cut_gesture_strip(actor, strip);
	if (!was || was.kind != PLAY || !self.cut_strip_exists(actor, strip)) return false;
	CutStrip* s = &self.cutscene().actors[actor].strips[strip];
	fade = math::clamp(fade, 0.0f, s.end - s.start);
	if (s.fade == fade) return true;
	s.fade = fade;
	self.cutscenes_changed();
	return true;
}

// Whether actor `actor`'s strips differ from what they were when the drag began; a walk refit counts.
fn bool AppState.cut_gesture_changed(&self, usz actor)
{
	if (!self.cut_gesture_open || self.cut_gesture.active >= self.cut_gesture.cutscenes.len) return false;
	Cutscene* was = &self.cut_gesture.cutscenes[self.cut_gesture.active];
	Cutscene* now = self.cutscene();
	if (!now || actor >= was.actors.len || actor >= now.actors.len) return false;
	CutStrip[] before = was.actors[actor].strips;
	CutStrip[] after = now.actors[actor].strips;
	if (before.len != after.len) return true;
	foreach (usz k, &s : after) if (!s.same_as(&before[k])) return true;
	return false;
}

<*
 Land the drag of strip `strip` of `actor`: the lanes settle around it and its tied
 walks, the walks refit, and the drag is one undo step when it changed anything.

 @return "Whether it was kept as a step"
*>
fn bool AppState.end_cut_gesture(&self, usz actor, usz strip)
{
	if (!self.cut_gesture_open) return false;
	CutStrip* was = self.cut_gesture_strip(actor, strip);
	bool changed = was && self.cut_strip_exists(actor, strip) && self.cut_gesture_changed(actor);
	CutSnapshot before = self.cut_gesture;
	self.cut_gesture = {};
	self.cut_gesture_open = false;
	if (!changed)
	{
		before.free();
		return false;
	}
	// The walks tied as the drag began, before the snapshot goes to the history.
	Cutscene* began = &before.cutscenes[before.active];
	CutTie[] ties = actor < began.actors.len ? cut_ties(mem, began.actors[actor].strips, began.paths) : {};
	defer free(ties);
	self.cut_record(before);
	bool[] played = self.cutscene().played_one_offs();
	CutActor* who = &self.cutscene().actors[actor];
	(void)cut_settle_strips(mem, &who.strips, strip);
	// The tied walks moved with the drag; the lanes settle around them too, and around those of a move it cut back.
	(void)cut_carry_ties(mem, &who.strips, ties);
	self.cutscene().drop_unplayed(played);
	self.fit_paired_speeds(actor);
	self.cutscenes_changed();
	return true;
}

<* Put back what the drag changed, leaving no step. *>
fn void AppState.cancel_cut_gesture(&self)
{
	if (!self.cut_gesture_open) return;
	CutSnapshot before = self.cut_gesture;
	self.cut_gesture = {};
	self.cut_gesture_open = false;
	self.cut_take(&before);
}

// The drag forgotten, when the cutscenes it began on are replaced under it.
fn void AppState.drop_cut_gesture(&self)
{
	self.cut_knot_dragging = false;
	if (!self.cut_gesture_open) return;
	self.cut_gesture.free();
	self.cut_gesture_open = false;
}

// ---------------------------------------------------------------------------
// A point picked on the ground

<*
 Wait for a click on the level's ground: a new turn of `actor`, or the selected
 turn's point. Esc or a right click gives it up.

 @return "False, with a notice, without the level in or the turn"
*>
fn bool AppState.begin_cut_pick(&self, CutGroundPick pick, usz actor = 0)
{
	if (pick == NONE)
	{
		self.cancel_cut_pick();
		return true;
	}
	if (pick == PATH_KNOT)
	{
		if (!self.cut_picked_path())
		{
			self.@notice("pick a path first");
			return false;
		}
		self.cut_pick = PATH_KNOT;
		self.cut_pick_actor = 0;
		self.cut_pick_strip = 0;
		self.@notice(level_shown() ? "click the ground where the walk goes, knot by knot · Enter or Esc ends it"
			: "click where the walk goes, knot by knot, on y = 0 without a level · Enter or Esc ends it");
		return true;
	}
	if (!level_shown())
	{
		self.@notice("open a level first: the point is picked on its ground");
		return false;
	}
	CutStrip* turn = self.cut_selected_strip();
	if (pick == TURN_TARGET && (!turn || turn.kind != TURN))
	{
		self.@notice("pick a turn first");
		return false;
	}
	self.cut_pick = pick;
	self.cut_pick_actor = actor;
	self.cut_pick_strip = pick == TURN_TARGET ? turn.id : 0;
	self.@notice("click the ground the turn should face · Esc gives it up");
	return true;
}

<*
 The ground point the pick waited for: a turn is added facing it, or the picked turn faces it.

 @return "False when no pick was waiting or its turn is gone"
*>
fn bool AppState.finish_cut_pick(&self, Vec3 point)
{
	CutGroundPick pick = self.cut_pick;
	uint id = self.cut_pick_strip;
	usz for_actor = self.cut_pick_actor;
	self.cancel_cut_pick();
	switch (pick)
	{
		case NONE:
			return false;
		case PATH_KNOT:
			// Drawing goes on until it is ended.
			if (!self.cut_picked_path()) return false;
			bool added = self.add_cut_knot(self.cut_path_pick - 1, point);
			if (self.cut_picked_path()) self.cut_pick = PATH_KNOT;
			return added;
		case NEW_TURN:
			return self.add_cut_turn(for_actor, "", point) >= 0;
		case TURN_TARGET:
			Cutscene* c = self.cutscene();
			usz actor;
			usz strip;
			if (!c || !c.find_strip(id, &actor, &strip)) return false;
			CutStrip edited = c.actors[actor].strips[strip].copy(mem);
			if (edited.target_row.len > 0) alloc::free(mem, edited.target_row.ptr);
			edited.target_row = "";
			edited.target = point;
			return self.set_cut_strip(actor, strip, edited);
	}
}

fn void AppState.cancel_cut_pick(&self)
{
	self.cut_pick = NONE;
	self.cut_pick_strip = 0;
	self.cut_pick_actor = 0;
}

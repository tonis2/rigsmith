<*
 The scene's cutscenes: the list, its own history, the characters that are its
 actors, and the export. The preview is app/cutscene_preview.c3.
*>
module crig;

import rig;
import std::collections::list;
import std::io;
import std::io::file;
import std::math;

const usz CUT_HISTORY_MOST = 200;
const String CUT_DEFAULT_NAME = "Cutscene";
const float CUT_NEW_DURATION = 10.0f;

// ---------------------------------------------------------------------------
// The history

<* A character's row, as a history step remembers it. *>
struct CutActorRow
{
	uint character;
	String row; // owned
}

<* The cutscene list and every character's row, on one side of a step. *>
struct CutSnapshot
{
	Cutscene[] cutscenes;
	usz active;
	CutActorRow[] rows;
	// When the step was taken, against the characters' own edits; see `undo_latest`.
	uint stamp;
}

fn void CutSnapshot.free(&self)
{
	foreach (&c : self.cutscenes) c.free(mem);
	if (self.cutscenes.len > 0) alloc::free(mem, self.cutscenes);
	foreach (&r : self.rows) if (r.row.len > 0) alloc::free(mem, r.row.ptr);
	if (self.rows.len > 0) alloc::free(mem, self.rows);
	*self = {};
}

<* Cutscene edits, undone and redone whole. The scene's, so no character's history holds them. *>
struct CutHistory
{
	List{CutSnapshot} undo;
	List{CutSnapshot} redo;
}

fn void CutHistory.clear(&self)
{
	foreach (&s : self.undo) s.free();
	foreach (&s : self.redo) s.free();
	if (self.undo.is_initialized()) self.undo.clear();
	if (self.redo.is_initialized()) self.redo.clear();
}

fn void CutHistory.free(&self)
{
	self.clear();
	self.undo.free();
	self.redo.free();
}

// ---------------------------------------------------------------------------
// The list

<* The cutscene being edited, or null when the scene has none. *>
fn Cutscene* AppState.cutscene(&self)
{
	if (self.cut_active >= (usz)self.cutscenes.len()) return null;
	return self.cutscenes.get_ref((sz)self.cut_active);
}

fn void AppState.free_cutscenes(&self)
{
	(void)self.back_to_cutscene();
	self.drop_cut_gesture();
	self.clear_cutscene_list();
	self.cutscenes.free();
	self.cut_history.free();
	self.cut_kept.free();
	self.free_cut_measures();
	if (self.cut_pending_node.len > 0) alloc::free(mem, self.cut_pending_node.ptr);
	self.cut_pending_node = "";
}

fn void AppState.clear_cutscene_list(&self)
{
	foreach (&c : self.cutscenes) c.free(mem);
	if (self.cutscenes.is_initialized()) self.cutscenes.clear();
	self.cut_active = 0;
}

<* A new scene: no cutscenes, no history, no preview. *>
fn void AppState.reset_cutscenes(&self)
{
	(void)self.back_to_cutscene();
	self.leave_cutscene_preview();
	self.drop_cut_gesture();
	self.cancel_cut_pick();
	self.clear_cutscene_list();
	self.cut_history.clear();
	self.cut_time = 0.0f;
	self.cut_selected = 0;
	self.cut_lane_actor = 0;
	self.cut_path_pick = 0;
	self.cut_knot_pick = 0;
	self.cut_zoom = 1.0f;
	self.cut_view_start = 0.0f;
	self.cut_view_top = 0.0f;
	self.cutscenes_changed();
}

<* Take over `taken` as the scene's cutscenes, `active` the one picked. The array is freed here. *>
fn void AppState.adopt_cutscenes(&self, Cutscene[] taken, usz active)
{
	self.reset_cutscenes();
	if (!self.cutscenes.is_initialized()) self.cutscenes.init(mem);
	foreach (c : taken) self.cutscenes.push(c);
	if (taken.len > 0) alloc::free(mem, taken);
	self.cut_active = active < (usz)self.cutscenes.len() ? active : 0;
	// A level already in drops them now; one still on its way does when it is in.
	self.ground_all_cut_paths();
}

<* Something about the cutscenes moved: their views redraw and the preview poses again. *>
fn void AppState.cutscenes_changed(&self)
{
	self.number_cut_strips();
	self.cut_revision = next_generation();
	if (Cutscene* cutscene = self.cutscene())
	{
		self.cut_time = math::clamp(self.cut_time, 0.0f, math::max(cutscene.duration, 0.0f));
	}
	else
	{
		self.leave_cutscene_preview();
	}
	if (self.cut_preview) self.apply_cutscene();
}

// A name no other cutscene has: `base`, then `base 2`.
fn String AppState.free_cutscene_name(&self, String base)
{
	for (int n = 1; n < 1000; n++)
	{
		String candidate = n == 1 ? base.copy(mem) : string::format(mem, "%s %d", base, n);
		bool used;
		foreach (&c : self.cutscenes) used = used || c.name == candidate;
		if (!used) return candidate;
		candidate.free(mem);
	}
	return base.copy(mem);
}

<*
 Add a cutscene, with every actor of the scene and nothing for them to do, and pick it. One undo step.

 @return "Its index"
*>
fn usz AppState.add_cutscene(&self, String name = "")
{
	self.cut_checkpoint();
	if (!self.cutscenes.is_initialized()) self.cutscenes.init(mem);
	Cutscene made = { .duration = CUT_NEW_DURATION, .fps = CUT_DEFAULT_FPS };
	made.name = self.free_cutscene_name(name.len > 0 ? name : CUT_DEFAULT_NAME);
	List{CutActor} actors;
	actors.init(mem);
	defer actors.free();
	for (usz i = 0; i < self.character_count(); i++)
	{
		Character* c = self.character(i);
		if (c.actor_row.len > 0) actors.push({ .row = c.actor_row.copy(mem), .home_rotation = quaternion::IDENTITY });
	}
	if (actors.len() > 0) made.actors = actors.to_array(mem);
	self.cutscenes.push(made);
	self.cut_active = (usz)self.cutscenes.len() - 1;
	self.cutscenes_changed();
	return self.cut_active;
}

<*
 Rename cutscene `i`. One undo step.

 @return "False for no such cutscene or an empty name"
*>
fn bool AppState.rename_cutscene(&self, usz i, String name)
{
	String trimmed = name.trim();
	if (i >= (usz)self.cutscenes.len() || trimmed.len == 0) return false;
	Cutscene* c = self.cutscenes.get_ref((sz)i);
	if (c.name == trimmed) return true;
	self.cut_checkpoint();
	c = self.cutscenes.get_ref((sz)i);
	if (c.name.len > 0) alloc::free(mem, c.name.ptr);
	c.name = trimmed.copy(mem);
	self.cutscenes_changed();
	return true;
}

<*
 Delete cutscene `i`; the one after it is picked. One undo step.

 @return "False for no such cutscene"
*>
fn bool AppState.delete_cutscene(&self, usz i)
{
	if (i >= (usz)self.cutscenes.len()) return false;
	self.cut_checkpoint();
	self.cutscenes.get_ref((sz)i).free(mem);
	self.cutscenes.remove_at((sz)i);
	if (self.cut_active > i || self.cut_active >= (usz)self.cutscenes.len())
	{
		self.cut_active = self.cut_active > 0 ? self.cut_active - 1 : 0;
	}
	self.cutscenes_changed();
	return true;
}

<*
 Pick the cutscene being edited. A choice, not an edit: no undo step.

 @return "False for no such cutscene"
*>
fn bool AppState.select_cutscene(&self, usz i)
{
	if (i >= (usz)self.cutscenes.len()) return false;
	if (i == self.cut_active) return true;
	self.cut_active = i;
	self.cut_time = 0.0f;
	self.cut_playing = false;
	self.cutscenes_changed();
	return true;
}

<*
 Set how long cutscene `i` runs and its frame rate. One undo step.

 @return "False for no such cutscene, or a length or rate that is not positive"
*>
fn bool AppState.set_cutscene_timing(&self, usz i, float duration, float fps)
{
	if (i >= (usz)self.cutscenes.len() || !(duration > 0.0f) || !(fps > 0.0f)) return false;
	if (!math::is_finite(duration) || !math::is_finite(fps)) return false;
	Cutscene* c = self.cutscenes.get_ref((sz)i);
	if (c.duration == duration && c.fps == fps) return true;
	self.cut_checkpoint();
	c = self.cutscenes.get_ref((sz)i);
	c.duration = duration;
	c.fps = fps;
	self.cutscenes_changed();
	return true;
}

<*
 Put `taken` in place of cutscene `i`, or after the last one when `i` is the count. One undo step.

 @param taken : "Owned from here"
 @require i <= (usz)self.cutscenes.len() : "No such cutscene"
*>
fn void AppState.replace_cutscene(&self, usz i, Cutscene taken)
{
	// Its paths stand on the ground the way the path tool's do.
	foreach (&p : taken.paths) self.ground_cut_path(p);
	self.cut_checkpoint();
	if (!self.cutscenes.is_initialized()) self.cutscenes.init(mem);
	if (i == (usz)self.cutscenes.len())
	{
		self.cutscenes.push(taken);
	}
	else
	{
		self.cutscenes.get_ref((sz)i).free(mem);
		self.cutscenes.set((sz)i, taken);
	}
	self.cut_active = i;
	self.cutscenes_changed();
}

// ---------------------------------------------------------------------------
// Undo

<* The cutscenes and the rows as they are now. The caller owns it. *>
fn CutSnapshot AppState.cut_snapshot(&self)
{
	CutSnapshot out = { .active = self.cut_active };
	sz count = self.cutscenes.len();
	if (count > 0)
	{
		out.cutscenes = alloc::new_array(mem, Cutscene, count);
		for (sz i = 0; i < count; i++) out.cutscenes[i] = self.cutscenes.get_ref(i).copy(mem);
	}
	usz characters = self.character_count();
	out.rows = alloc::new_array(mem, CutActorRow, (sz)characters);
	for (usz i = 0; i < characters; i++)
	{
		Character* c = self.character(i);
		out.rows[i] = { c.id, c.actor_row.len > 0 ? c.actor_row.copy(mem) : "" };
	}
	return out;
}

// Put a snapshot back, taking its cutscenes over and freeing the rest of it.
fn void AppState.cut_take(&self, CutSnapshot* snap)
{
	self.clear_cutscene_list();
	if (!self.cutscenes.is_initialized()) self.cutscenes.init(mem);
	foreach (c : snap.cutscenes) self.cutscenes.push(c);
	if (snap.cutscenes.len > 0) alloc::free(mem, snap.cutscenes);
	snap.cutscenes = {};
	self.cut_active = snap.active;
	foreach (&r : snap.rows)
	{
		for (usz i = 0; i < self.character_count(); i++)
		{
			Character* c = self.character(i);
			if (c.id == r.character) c.set_actor_row(r.row);
		}
	}
	snap.free();
	self.cutscenes_changed();
}

<* Remember the cutscenes before an edit, as one undo step; anything undone is dropped. A one-off edit ends first. *>
fn void AppState.cut_checkpoint(&self)
{
	(void)self.back_to_cutscene();
	self.cut_record(self.cut_snapshot());
}

<* Keep `taken`, the cutscenes as they were before an edit, as one undo step. Owned from here. *>
fn void AppState.cut_record(&self, CutSnapshot taken)
{
	if (!self.cut_history.undo.is_initialized()) self.cut_history.undo.init(mem);
	if (!self.cut_history.redo.is_initialized()) self.cut_history.redo.init(mem);
	foreach (&s : self.cut_history.redo) s.free();
	self.cut_history.redo.clear();
	taken.stamp = next_generation();
	self.cut_history.undo.push(taken);
	if ((usz)self.cut_history.undo.len() > CUT_HISTORY_MOST)
	{
		self.cut_history.undo.get_ref(0).free();
		self.cut_history.undo.remove_at(0);
	}
}

fn bool AppState.can_undo_cutscene(&self) => self.cut_history.undo.len() > 0;
fn bool AppState.can_redo_cutscene(&self) => self.cut_history.redo.len() > 0;

<* Take the last cutscene step back; a one-off edit ends first, as its own step. *>
fn bool AppState.undo_cutscene(&self)
{
	(void)self.back_to_cutscene();
	if (!self.can_undo_cutscene()) return false;
	self.drop_cut_gesture();
	CutSnapshot back = self.cut_history.undo.pop()!!;
	CutSnapshot now = self.cut_snapshot();
	now.stamp = back.stamp;
	self.cut_history.redo.push(now);
	self.cut_take(&back);
	return true;
}

<* Put the last cutscene step taken back on again. *>
fn bool AppState.redo_cutscene(&self)
{
	(void)self.back_to_cutscene();
	if (!self.can_redo_cutscene()) return false;
	self.drop_cut_gesture();
	CutSnapshot ahead = self.cut_history.redo.pop()!!;
	CutSnapshot now = self.cut_snapshot();
	now.stamp = ahead.stamp;
	self.cut_history.undo.push(now);
	self.cut_take(&ahead);
	return true;
}

// The newest step each history would take back, and the oldest each would redo.
fn uint AppState.rig_undo_stamp(&self)
{
	return self.undo_stack.cursor > 0 ? self.undo_stack.edits[self.undo_stack.cursor - 1].stamp : 0;
}

fn uint AppState.rig_redo_stamp(&self)
{
	return self.undo_stack.can_redo() ? self.undo_stack.edits[self.undo_stack.cursor].stamp : 0xffff_ffff;
}

<*
 Undo whichever came last, a cutscene step or the character's own edit. The two
 histories stay apart; only the choice between them is shared.
*>
fn bool AppState.undo_latest(&self)
{
	// A one-off being edited steps its own edits only; Back to cutscene makes them one step.
	if (self.one_off_here()) return self.undo();
	if (self.can_undo_cutscene() && (!self.undo_stack.can_undo() || self.cut_history.undo.last()!!.stamp > self.rig_undo_stamp()))
	{
		return self.undo_cutscene();
	}
	return self.undo();
}

<* Redo whichever was taken back last. *>
fn bool AppState.redo_latest(&self)
{
	if (self.one_off_here()) return self.redo();
	if (self.can_redo_cutscene() && (!self.undo_stack.can_redo() || self.cut_history.redo.last()!!.stamp < self.rig_redo_stamp()))
	{
		return self.redo_cutscene();
	}
	return self.redo();
}

fn bool AppState.can_undo_latest(&self) => (!self.one_off_here() && self.can_undo_cutscene()) || self.undo_stack.can_undo();
fn bool AppState.can_redo_latest(&self) => (!self.one_off_here() && self.can_redo_cutscene()) || self.undo_stack.can_redo();

// ---------------------------------------------------------------------------
// Actors

fn void Character.set_actor_row(&self, String row)
{
	String kept = row.len > 0 ? row.copy(mem) : "";
	if (self.actor_row.len > 0) alloc::free(mem, self.actor_row.ptr);
	self.actor_row = kept;
}

fn void Character.set_level_node(&self, String node)
{
	String kept = node.len > 0 ? node.copy(mem) : "";
	if (self.level_node.len > 0) alloc::free(mem, self.level_node.ptr);
	self.level_node = kept;
}

<* Forget the actor link: the character is no actor and stands in for nothing. *>
fn void Character.drop_actor_link(&self)
{
	self.set_actor_row("");
	self.set_level_node("");
	self.stage_scale = 0.0f;
	self.stage_lift = 0.0f;
	self.staged = false;
	self.stage_missing = false;
	self.set_stage_rig({});
	self.set_level_joints({});
	self.level_read = false;
	self.stage_bounds = {};
	self.drop_cut_shown();
	self.drop_cut_fade();
}

<* Keep a copy of `joints` as the level copy's skin-to-rig map. *>
fn void Character.set_level_joints(&self, int[] joints)
{
	if (self.level_joints.len > 0) free(self.level_joints);
	self.level_joints = joints.len > 0 ? alloc::clone_slice(mem, joints) : {};
}

<* Keep a copy of `rig`, names and all, as the level node's rig. *>
fn void Character.set_stage_rig(&self, JointRest[] rig)
{
	free_joint_rests(mem, self.stage_rig);
	self.stage_rig = copy_joint_rests(mem, rig);
}

<* The preview's copy of a one-off let go; the player stops first when it shows it. *>
fn void Character.drop_cut_shown(&self)
{
	self.drop_cut_fade();
	self.drop_cut_shown_clip();
}

// The copy alone, the fade kept.
fn void Character.drop_cut_shown_clip(&self)
{
	if (self.cut_shown.keyframes.len == 0) return;
	if (self.current_anim.keyframes.ptr == self.cut_shown.keyframes.ptr)
	{
		self.animating = false;
		self.anim_paused = false;
		self.current_anim = {};
		self.current_ref = NO_ANIM;
	}
	self.cut_shown.free(mem);
	self.cut_shown = {};
	self.cut_shown_from = 0;
}

<* The preview's cross-fade let go, with its copy of a one-off. *>
fn void Character.drop_cut_fade(&self)
{
	self.cut_fading = false;
	self.cut_fade_ref = NO_ANIM;
	self.cut_fade_copy.free(mem);
	self.cut_fade_copy = {};
	self.cut_fade_copy_from = 0;
}

<* The character whose row is `row`, or -1. *>
fn sz AppState.actor_character(&self, String row)
{
	if (row.len == 0) return -1;
	for (usz i = 0; i < self.character_count(); i++)
	{
		if (self.character(i).actor_row == row) return (sz)i;
	}
	return -1;
}

<* The character standing in for level node `node`, or -1. *>
fn sz AppState.level_node_character(&self, String node)
{
	if (node.len == 0) return -1;
	for (usz i = 0; i < self.character_count(); i++)
	{
		if (self.character(i).level_node == node) return (sz)i;
	}
	return -1;
}

<* Each actor's character and level node, for get_cutscene. The caller owns the array. *>
fn CutActorLink[] AppState.cut_links(&self, Cutscene* cutscene, Allocator allocator)
{
	if (cutscene.actors.len == 0) return {};
	CutActorLink[] out = alloc::new_array(allocator, CutActorLink, (sz)cutscene.actors.len);
	foreach (usz k, &actor : cutscene.actors)
	{
		sz i = self.actor_character(actor.row);
		out[k] = { .character = (int)i, .level_node = i >= 0 ? self.character((usz)i).level_node : "" };
	}
	return out;
}

<* Every actor's home from its character: where it stands in the scene, and whether a level node is its own. *>
fn void AppState.refresh_cut_homes(&self, Cutscene* cutscene)
{
	foreach (&actor : cutscene.actors)
	{
		sz i = self.actor_character(actor.row);
		if (i < 0) continue;
		Character* c = self.character((usz)i);
		actor.home = c.doc.model_transform.location;
		actor.home_rotation = c.doc.model_transform.orientation();
		actor.no_level_node = c.level_node.len == 0;
	}
}

<*
 What each actor of `cutscene` can play, by its character's clip names; with
 `measure`, also how each clip walks and whether the character faces +Z. The
 caller frees the arrays, not the names.
*>
fn CutCast[] AppState.cut_cast(&self, Cutscene* cutscene, Allocator allocator, bool measure = false)
{
	if (cutscene.actors.len == 0) return {};
	CutCast[] out = alloc::new_array(allocator, CutCast, (sz)cutscene.actors.len);
	foreach (usz k, &actor : cutscene.actors)
	{
		sz i = self.actor_character(actor.row);
		if (i < 0) continue;
		Character* c = self.character((usz)i);
		BoundClip[] bound = self.cut_bindings_of((usz)i);
		String[] names = alloc::new_array(allocator, String, (sz)bound.len);
		foreach (usz j, b : bound) names[j] = b.clip;
		out[k] = { .found = true, .clips = names, .stands_in = c.level_node.len > 0, .node_gone = c.stage_missing,
			.level_read = c.level_read, .armature = c.level_node };
		if (!measure) continue;
		// A stand-in's one-offs play on the level's rig, read when the level came in.
		bool plays_one_off;
		foreach (&s : actor.strips) plays_one_off = plays_one_off || (s.kind != TURN && s.one_off);
		if (out[k].stands_in && plays_one_off)
		{
			out[k].rig_read = c.stage_rig.len > 0;
			if (out[k].rig_read) out[k].rig = self.cut_rig_mismatch((usz)i, allocator);
		}
		Vec3 facing;
		out[k].facing_known = rest_facing(&c.doc, &facing);
		out[k].faces_front = out[k].facing_known && facing.z >= CUT_FRONT_FACING;
		// Measuring a clip stands in as the character, which moves `c`.
		out[k].grounds = alloc::new_array(allocator, CutClipGround, (sz)names.len);
		foreach (usz j, name : names) out[k].grounds[j] = self.cut_clip_ground((usz)i, name);
		out[k].measured = true;
	}
	return out;
}

<* How character `character`'s rig differs from the level node's it stands in for; the joint named in `allocator`. *>
fn RigMismatch AppState.cut_rig_mismatch(&self, usz character, Allocator allocator)
{
	RigMismatch out;
	Character* c = self.character(character);
	RigView? opened = open_rig(&c.doc, &c.geometry, &c.shells, mem);
	if (catch opened) return { MISSING_JOINT, "".copy(allocator) };
	RigView view = opened;
	defer view.free(mem);
	JointRest[] own = skeleton_rests(mem, &view.skeleton, view.names);
	defer if (own.len > 0) free(own);
	// Read from the level, the rig is the level's in Rigsmith's joint frames: its rest turns differ by the frames alone.
	out = rigs_agree(own, c.stage_rig, any_turn: c.level_read);
	out.joint = out.joint.copy(allocator);
	return out;
}

fn void free_cut_cast(Allocator allocator, CutCast[] cast)
{
	foreach (c : cast)
	{
		if (c.clips.len > 0) alloc::free(allocator, c.clips);
		if (c.grounds.len > 0) alloc::free(allocator, c.grounds);
	}
	if (cast.len > 0) alloc::free(allocator, cast);
}

<* The active cutscene's problems in words, none without one. The caller owns them; see free_names. *>
fn String[] AppState.cutscene_problem_texts(&self, Allocator allocator)
{
	Cutscene* cutscene = self.cutscene();
	if (!cutscene) return {};
	String[] out;
	CutWalkBlock[] blocks = self.cut_walk_blocks();
	@pool()
	{
		CutCast[] cast = self.cut_cast(cutscene, tmem, measure: true);
		CutProblem[] problems = cutscene_problems(tmem, cutscene, cast);
		usz count = problems.len + blocks.len;
		if (count > 0) out = alloc::new_array(allocator, String, (sz)count);
		foreach (usz i, problem : problems) out[i] = cut_problem_text(allocator, cutscene, problem, cast);
		// A walk may go where the player can't: named, never refused.
		foreach (usz i, b : blocks)
		{
			bool there = b.actor < cutscene.actors.len && b.strip < cutscene.actors[b.actor].strips.len;
			out[problems.len + i] = string::format(allocator, "%s: the move at %.2f s walks through %s near [%.1f, %.1f]",
				there ? cutscene.actors[b.actor].row : "an actor", there ? cutscene.actors[b.actor].strips[b.strip].start : 0.0f,
				b.collider.len > 0 ? b.collider : "a collider", b.at.x, b.at.z);
		}
	};
	return out;
}

<* A row the game can find: the label's letters, digits, `_` and `-`, unique among the characters. The caller owns it. *>
fn String AppState.free_actor_row(&self, String label)
{
	DString clean = dstring::new(mem);
	defer clean.free();
	foreach (ch : label)
	{
		bool plain = ch.is_alnum() || ch == '_' || ch == '-';
		clean.append_char(plain ? ch : '_');
	}
	String base = clean.len() > 0 ? clean.str_view() : "actor";
	for (int n = 1; n < 1000; n++)
	{
		String candidate = n == 1 ? base.copy(mem) : string::format(mem, "%s_%d", base, n);
		if (self.actor_character(candidate) < 0) return candidate;
		candidate.free(mem);
	}
	return base.copy(mem);
}

// Rename a row everywhere a cutscene names it: its actors and the turns that face them.
fn void AppState.rename_row_everywhere(&self, String from, String to)
{
	foreach (&cutscene : self.cutscenes)
	{
		foreach (&actor : cutscene.actors)
		{
			if (actor.row == from)
			{
				alloc::free(mem, actor.row.ptr);
				actor.row = to.copy(mem);
			}
			foreach (&s : actor.strips)
			{
				if (s.target_row != from || s.target_row.len == 0) continue;
				alloc::free(mem, s.target_row.ptr);
				s.target_row = to.copy(mem);
			}
		}
		foreach (&one : cutscene.one_offs)
		{
			if (one.row != from) continue;
			one.row.free(mem);
			one.row = to.copy(mem);
		}
	}
}

<*
 Make character `i` an actor found by `row` (a safe name from its file when empty),
 renaming it everywhere a cutscene names its old row, and add it to the active
 cutscene when that lacks it. One undo step.

 @return "False for no such character, or a row another character has"
*>
fn bool AppState.make_actor(&self, usz i, String row = "")
{
	if (i >= self.character_count()) return false;
	Character* c = self.character(i);
	String wanted = row.trim();
	String made = wanted.len > 0 ? wanted.copy(mem) : self.free_actor_row(c.label());
	defer made.free(mem);
	sz holder = self.actor_character(made);
	if (holder >= 0 && (usz)holder != i)
	{
		self.@notice("%s already plays '%s' — rows are how the game tells actors apart", self.character((usz)holder).label(), made);
		return false;
	}
	Cutscene* active = self.cutscene();
	bool listed = active && active.actor_by_row(made) >= 0;
	if (c.actor_row == made && (listed || !active)) return true;

	self.cut_checkpoint();
	c = self.character(i);
	if (c.actor_row.len > 0 && c.actor_row != made) self.rename_row_everywhere(c.actor_row, made);
	c.set_actor_row(made);
	active = self.cutscene();
	if (active && active.actor_by_row(made) < 0)
	{
		usz count = active.actors.len;
		CutActor[] grown = alloc::new_array(mem, CutActor, (sz)count + 1);
		foreach (usz k, a : active.actors) grown[k] = a;
		grown[count] = { .row = made.copy(mem), .home_rotation = quaternion::IDENTITY };
		if (count > 0) alloc::free(mem, active.actors);
		active.actors = grown;
	}
	self.cutscenes_changed();
	return true;
}

<*
 Take character `i` out of every cutscene as one undo step, then out of the scene;
 a level copy it stood in for shows again.

 @return "False for the last character, which the scene keeps"
*>
fn bool AppState.remove_actor(&self, usz i)
{
	if (i >= self.character_count() || self.character_count() < 2) return false;
	String row = self.character(i).actor_row;
	if (row.len > 0)
	{
		self.cut_checkpoint();
		String gone = self.character(i).actor_row;
		foreach (&cutscene : self.cutscenes)
		{
			int at = cutscene.actor_by_row(gone);
			if (at < 0) continue;
			// Its one-offs were made for it alone.
			for (usz k = cutscene.one_offs.len; k > 0; k--)
			{
				if (cutscene.one_offs[k - 1].row == gone) cutscene.remove_one_off((sz)k - 1);
			}
			cutscene.actors[at].free(mem);
			for (usz k = (usz)at; k + 1 < cutscene.actors.len; k++) cutscene.actors[k] = cutscene.actors[k + 1];
			cutscene.actors = cutscene.actors[:cutscene.actors.len - 1];
			if (cutscene.actors.len == 0)
			{
				alloc::free(mem, cutscene.actors.ptr);
				cutscene.actors = {};
			}
		}
		self.cutscenes_changed();
	}
	return self.remove_character(i);
}

<*
 Load the character at `path` as an actor: beside the others, or standing at `at`,
 dropped onto the ground under it when `ground`. It becomes the focus.

 @return "False, with a notice, when it would not load or its row is taken"
*>
fn bool AppState.add_actor_from_file(&self, String path, String row = "", Vec3* at = null, bool ground = false)
{
	if (!self.focus_may_move()) return false;
	int already = self.character_from(path);
	if (already >= 0)
	{
		(void)self.focus_character((usz)already);
	}
	else
	{
		rig::TriMesh? loaded = file::is_file(path) ? rig::load_gltf(mem, path) : io::FILE_NOT_FOUND~;
		if (catch error = loaded)
		{
			self.@notice("could not open %s: %s", file_stem(path), error);
			return false;
		}
		if (!self.has_mesh() && self.character_count() == 1)
		{
			self.load_mesh(loaded, path);
			self.remember_project(path);
		}
		else
		{
			self.add_character(loaded, path);
		}
	}
	// One just loaded is set down; one already in moves as its own edit.
	if (at)
	{
		ProjectTransform placed = self.doc.model_transform;
		placed.rotation = placed.orientation();
		placed.location = *at;
		if (already >= 0)
		{
			if (self.set_model_transform_recorded(self.doc.model_transform, placed)) self.undo_stack.commit();
		}
		else
		{
			self.doc.model_transform = placed;
		}
	}
	if (ground) (void)self.drop_actor_to_ground(self.active, recorded: already >= 0);
	if (!self.make_actor(self.active, row)) return false;
	self.refresh_ui();
	return true;
}

<*
 Take the level's character `node` as an actor. With no `path` it is read from the level file
 itself (`read_level_actor`). With one, the character at `path` stands in for it: at the node's
 place and facing with its feet where the copy's are, scaled to the copy's height; the copy is
 hidden. One read from the level gives way to its own file, keeping its row. The row is the
 node's name unless `row` says otherwise.

 @return "False, with a notice, without the level in, the node, or the file"
*>
fn bool AppState.take_level_actor(&self, String node, String path = "", String row = "")
{
	if (path.len == 0) return self.read_level_actor(node, row);
	if (!level_shown())
	{
		self.@notice("open a level and let it finish loading first");
		return false;
	}
	LevelCharacter found;
	if (!level_character_named(node, &found))
	{
		self.@notice("the level has no rigged character called %s", node);
		return false;
	}
	sz holder = self.level_node_character(node);
	String kept_row = row;
	// Read from the level until now: its own file takes its place under the same row.
	if (holder >= 0 && self.character((usz)holder).level_read)
	{
		if (kept_row.len == 0) kept_row = self.character((usz)holder).actor_row.tcopy();
		if (self.character_count() > 1)
		{
			if (!self.remove_character((usz)holder)) return false;
		}
		else
		{
			self.drop_actor_link();
		}
		holder = -1;
	}
	if (holder < 0) holder = self.character_from(path);
	if (holder >= 0 && self.character((usz)holder).level_node.len > 0)
	{
		Character* c = self.character((usz)holder);
		self.@notice("%s already stands in for %s", c.label(), c.level_node);
		return false;
	}
	if (!self.add_actor_from_file(path, kept_row.len > 0 ? kept_row : node, &found.position)) return false;
	self.set_level_node(node);
	@pool()
	{
		found.rig = level_character_rig(tmem, found.entry);
		self.stand_in_for(&found);
	};
	self.cutscenes_changed();
	self.@notice("%s stands in for the level's %s", self.label(), node);
	self.refresh_ui();
	return true;
}

<*
 Stand the focus in for level character `found`: at its place and facing, its feet where the
 copy's are, scaled to the copy's height, with the node's lift over the feet and its rig at rest.
 Not an edit: the level says where it stands.

 @param [in] found
*>
fn void AppState.stand_in_for(&self, LevelCharacter* found)
{
	rig::Bounds own = placed_bounds(&self.geometry, {}, 1.0f);
	float tall = own.max.y - own.min.y;
	self.stage_scale = tall > 1e-6f && found.height > 1e-6f ? found.height / tall : 0.0f;
	// Feet where the level copy's feet are: the two files need not share an origin.
	float scale = self.stage_scale > 0.0f ? self.stage_scale : 1.0f;
	self.doc.model_transform.location = { found.position.x, found.floor - own.min.y * scale, found.position.z };
	self.doc.model_transform.rotation = found.rotation;
	// The node's origin stands this far over those feet; the export lifts its walks by it.
	self.stage_lift = found.position.y - found.floor;
	self.set_stage_rig(found.rig);
	self.stage_missing = false;
}

<*
 Every stand-in reads its level node again from `found`, as the level came in: place, facing,
 size, lift and rig; every actor read from the level reads its armature again out of the level
 file. One whose node is not there keeps what it had, and the problems list says so. Not an edit.

 @param [in] found : "Each with its rig, as level_character_rig reads it"
*>
fn void AppState.restage_actors(&self, LevelCharacter[] found)
{
	self.reread_level_actors();
	for (usz i = 0; i < self.character_count(); i++)
	{
		String node = self.character(i).level_node;
		if (node.len == 0 || self.character(i).level_read) continue;
		LevelCharacter* match = null;
		foreach (&f : found) if (f.name == node) match = f;
		if (!match)
		{
			self.character(i).stage_missing = true;
			continue;
		}
		self.@as_character(i) { self.stand_in_for(match); };
	}
	self.cutscenes_changed();
}

<*
 Drop character `i` onto the level's ground under where it stands, as its own edit.

 @param recorded : "As a step of the character's own history; false for one just placed"
 @return "False without a level in, or with no ground under it"
*>
fn bool AppState.drop_actor_to_ground(&self, usz i, bool recorded = true)
{
	if (i >= self.character_count()) return false;
	bool dropped;
	self.@as_character(i)
	{
		GroundHit hit = ground_below(self.doc.model_transform.location);
		if (hit.hit)
		{
			ProjectTransform before = self.doc.model_transform;
			ProjectTransform after = before;
			after.location.y = hit.point.y;
			if (recorded)
			{
				dropped = self.set_model_transform_recorded(before, after);
				if (dropped) self.undo_stack.commit();
			}
			else
			{
				self.doc.model_transform = after;
				dropped = true;
			}
		}
	};
	if (dropped) self.cutscenes_changed();
	return dropped;
}

// ---------------------------------------------------------------------------
// Export

// A path lifted for the export: which one, by how much, and where the copy went.
struct CutLifted @local
{
	int path;
	float lift;
	int index;
}

<*
 The walks of actors standing in for a level node lifted by how far that node's
 origin stands over its feet: the game puts the node itself on the path, so the
 feet land on the ground. A path walked at two lifts is written once for each.

 @param [inout] cutscene : "A copy about to be written"
*>
fn void AppState.lift_level_walks(&self, Cutscene* cutscene)
{
	List{WalkPath} paths;
	paths.init(mem);
	defer paths.free();
	foreach (p : cutscene.paths) paths.push(p);
	List{CutLifted} made;
	made.init(mem);
	defer made.free();
	foreach (&actor : cutscene.actors)
	{
		sz holder = self.actor_character(actor.row);
		float lift = holder >= 0 && !actor.no_level_node ? self.character((usz)holder).stage_lift : 0.0f;
		if (lift == 0.0f) continue;
		foreach (&s : actor.strips)
		{
			if (s.kind != MOVE || s.path < 0 || s.path >= cutscene.paths.len) continue;
			int found = -1;
			foreach (m : made) if (m.path == s.path && m.lift == lift) found = m.index;
			if (found < 0)
			{
				WalkPath lifted = cutscene.paths[s.path].copy(mem);
				foreach (&p : lifted.points) p.y += lift;
				found = (int)paths.len();
				paths.push(lifted);
				made.push({ s.path, lift, found });
			}
			s.path = found;
		}
	}
	if (paths.len() == cutscene.paths.len) return;
	if (cutscene.paths.len > 0) alloc::free(mem, cutscene.paths);
	cutscene.paths = paths.to_array(mem);
}

<*
 Bake the one-offs `cutscene`'s strips play into the channels the file carries, and point each
 strip at its animation. An actor with no level node plays them on its own file's rig, as they
 were made; a stand-in on the level's, whose joint frames they are carried into, refused when the
 two rigs differ.

 @param [inout] cutscene : "A copy about to be written"
 @param [out] baked : "The caller frees it"
 @param [&inout] why : "Gets the reason when it is refused"
 @return "False when a one-off cannot be written"
*>
fn bool AppState.bake_cut_one_offs(&self, Cutscene* cutscene, CutAnimation[]* baked, DString* why)
{
	List{CutAnimation} made;
	made.init(mem);
	defer made.free();
	bool ok = true;
	foreach (usz a, &actor : cutscene.actors)
	{
		foreach (&s : actor.strips)
		{
			if (s.kind == TURN || !s.one_off) continue;
			sz one = cutscene.one_off_index(actor.row, s.clip);
			// One the cutscene lacks is refused by the writer, named.
			if (one < 0) continue;
			sz found = -1;
			foreach (usz k, &m : made) if (m.actor == a && m.name == s.clip) found = (sz)k;
			if (found < 0)
			{
				CutAnimation animation;
				if (!self.bake_one_off_for(cutscene, a, &cutscene.one_offs[one], &animation, why))
				{
					ok = false;
					break;
				}
				found = (sz)made.len();
				made.push(animation);
			}
			s.animation = (int)found;
		}
		if (!ok) break;
	}
	if (!ok)
	{
		foreach (&m : made) m.free(mem);
		return false;
	}
	*baked = made.len() > 0 ? made.to_array(mem) : {};
	return true;
}

// One one-off baked on its actor's character, carried into the level's frames for a stand-in.
fn bool AppState.bake_one_off_for(&self, Cutscene* cutscene, usz actor, CutOneOff* one, CutAnimation* out, DString* why)
{
	String row = cutscene.actors[actor].row;
	sz holder = self.actor_character(row);
	if (holder < 0)
	{
		why.appendf("%s plays the one-off '%s', and no character has that row", row, one.clip.name)!!;
		return false;
	}
	Character* c = self.character((usz)holder);
	RigView? opened = open_rig(&c.doc, &c.geometry, &c.shells, mem);
	if (catch opened)
	{
		why.appendf("%s has no rig to play the one-off '%s' on", row, one.clip.name)!!;
		return false;
	}
	RigView view = opened;
	defer view.free(mem);
	AnimTemplate clip = clip_copy(mem, one.clip);
	defer clip.free(mem);
	clip.compile_tracks(mem);
	*out = bake_one_off(mem, &view.skeleton, view.names, &clip, actor, one.clip.name);
	if (out.channels.len == 0)
	{
		why.appendf("the one-off '%s' of %s keys nothing yet", one.clip.name, row)!!;
		out.free(mem);
		return false;
	}
	if (c.level_node.len == 0) return true;
	// The game plays a stand-in's one-offs on the level's armature.
	if (c.stage_rig.len == 0)
	{
		why.appendf("%s stands in for %s: open the level, so the one-off '%s' is written in its armature's joint frames",
			row, c.level_node, one.clip.name)!!;
		out.free(mem);
		return false;
	}
	JointRest[] own = skeleton_rests(mem, &view.skeleton, view.names);
	defer if (own.len > 0) free(own);
	RigMismatch differs = rigs_agree(own, c.stage_rig, any_turn: c.level_read);
	if (!differs.agrees())
	{
		@pool()
		{
			why.appendf("the one-off '%s' of %s was made on another rig than the level's %s: %s", one.clip.name, row,
				c.level_node, rig_mismatch_text(tmem, differs))!!;
		};
		out.free(mem);
		return false;
	}
	carry_channels(out.channels, own, c.stage_rig);
	return true;
}

<*
 Write the active cutscene to `path`: paths sampled from their knots and dropped on
 the ground, lifted for actors standing in for a level node, and a place only for
 actors with no level node.

 @param [inout] why : "Gets the reason when it is refused; may be null"
 @return "False, with a notice, when it is refused or would not write"
*>
fn bool AppState.export_cutscene(&self, String path, DString* why = null)
{
	Cutscene* active = self.cutscene();
	if (!active)
	{
		if (why) why.append_string("the scene has no cutscene to export");
		self.@notice("the scene has no cutscene to export");
		return false;
	}
	self.sync_one_off_now();
	active = self.cutscene();
	Cutscene copy = active.copy(mem);
	defer copy.free(mem);
	self.refresh_cut_homes(&copy);
	foreach (&walk : copy.paths) self.ground_cut_path(walk);
	self.lift_level_walks(&copy);
	DString reason = dstring::new(mem);
	defer reason.free();
	CutAnimation[] baked;
	defer free_cut_animations(mem, baked);
	if (!self.bake_cut_one_offs(&copy, &baked, &reason))
	{
		self.@notice("%s was not exported: %s", copy.name, reason.str_view());
		if (why) why.append_string(reason.str_view());
		return false;
	}
	if (catch write_cutscene_file(path, &copy, &reason, baked))
	{
		self.@notice("%s was not exported: %s", copy.name, reason.str_view());
		if (why) why.append_string(reason.str_view());
		return false;
	}
	self.@notice("exported %s · %d actor%s, %.2f s", base_name(path), copy.actors.len, copy.actors.len == 1 ? "" : "s", copy.duration);
	return true;
}

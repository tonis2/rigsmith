<* What would look wrong or be refused in a cutscene, found from the cutscene and what each actor's file can play. *>
module crig;

import std::collections::list;
import std::math;

// How far past the cutscene's end a strip may run before it counts as late.
const float CUT_LATE_SLACK = 1e-4f;

enum CutProblemKind : char
{
	NO_CHARACTER, // no scene character has the actor's row
	MISSING_CLIP, // a strip plays a clip the actor's file lacks
	ENDS_LATE,    // a strip ends after the cutscene does
	NO_PATH,      // a move with no path of two points or more
	NO_TARGET,    // a turn toward an actor this cutscene lacks
	SELF_TARGET,  // a turn toward the actor itself
	NO_LENGTH,    // a strip that ends where it starts, or before
	OVERLAP,      // two strips on one lane at once; the format allows one
	CLIP_TRAVELS, // a move's clip carries the figure itself, which the path would add to
	NOT_FRONT,    // the actor's character does not face +Z, the way a walk faces along its path
	NO_GROUND_SPEED, // a move's clip says nothing of how fast it walks, so it is timed at 1 m/s
	ONE_OFF_GONE,    // a strip plays a one-off this cutscene does not have
	ONE_OFF_UNUSED,  // a one-off no strip of its actor plays
	ONE_OFF_EMPTY,   // a one-off a strip plays that keys nothing
	ONE_OFF_NO_RIG,  // a level node's stand-in plays a one-off, and the level's rig is not read
	ONE_OFF_OTHER_RIG, // a level node's stand-in plays a one-off made on another rig than the level's
	STAND_IN_GONE,   // the level node an actor stands in for is no longer in the level
}

<*
 One problem: which actor, and which of its strips, or -1 for the actor itself. An overlap is named
 once, on the later strip of the two. A one-off no strip plays or that keys nothing names the
 one-off instead: `strip` is its index among the cutscene's one-offs.
*>
struct CutProblem
{
	CutProblemKind kind;
	usz actor;
	int strip;
}

<* How a clip walks: its ground speed in m/s as the actor is drawn (0 for not known), and whether it still travels. *>
struct CutClipGround
{
	float speed;
	bool travels;
}

<*
 What one actor's character can play: whether a scene character has its row, and
 its clip names. `measured` says the rest was read too: each clip's ground (one
 per clip) and whether the character faces +Z.
*>
struct CutCast
{
	bool found;
	String[] clips; // borrowed
	bool measured;
	CutClipGround[] grounds; // borrowed
	bool facing_known;
	bool faces_front;
	// Stands in for a level node, so its one-offs play on the level's rig: whether that is read, and how it differs.
	bool stands_in;
	bool rig_read;
	RigMismatch rig;
	// Its level node was not in the level when the level last came in.
	bool node_gone;
	// Read from the level file, its clips the ones the level has for its armature (borrowed).
	bool level_read;
	String armature;
}

fn bool cut_has_clip(String[] clips, String name) @local
{
	foreach (clip : clips) if (clip == name) return true;
	return false;
}

<* What the cast measured of the clip called `name`; nothing known for a clip it lacks. *>
fn CutClipGround CutCast.ground_of(&self, String name)
{
	foreach (usz i, clip : self.clips)
	{
		if (clip == name && i < self.grounds.len) return self.grounds[i];
	}
	return {};
}

<* The ground speed a move walks at, in m/s: the one typed on it, else its clip's, else 0 for not known. *>
fn float CutCast.move_ground_speed(&self, CutStrip* s)
{
	if (s.ground_speed > 0.0f) return s.ground_speed;
	if (s.clip.len == 0) return 0.0f;
	return self.ground_of(s.clip).speed;
}

<*
 Every problem in `cutscene`, actor by actor and strip by strip in their order.

 @param [in] cutscene
 @param [in] cast : "One entry per actor"
 @require cast.len == cutscene.actors.len : "One cast entry per actor"

 @return "The caller owns the array"
*>
fn CutProblem[] cutscene_problems(Allocator allocator, Cutscene* cutscene, CutCast[] cast)
{
	List{CutProblem} found;
	found.init(mem);
	defer found.free();
	foreach (usz a, &actor : cutscene.actors)
	{
		CutCast* who = &cast[a];
		if (!who.found) found.push({ NO_CHARACTER, a, -1 });
		if (who.found && who.measured && who.facing_known && !who.faces_front) found.push({ NOT_FRONT, a, -1 });
		if (who.found && who.node_gone) found.push({ STAND_IN_GONE, a, -1 });
		bool rig_named;
		foreach (usz k, &s : actor.strips)
		{
			bool own = s.kind != TURN && s.clip.len > 0 && !s.one_off && s.animation < 0;
			bool has_clip = who.found && own && cut_has_clip(who.clips, s.clip);
			if (who.found && own && !has_clip)
			{
				found.push({ MISSING_CLIP, a, (int)k });
			}
			if (s.kind != TURN && s.one_off)
			{
				sz one = cutscene.one_off_index(actor.row, s.clip);
				if (one < 0)
				{
					found.push({ ONE_OFF_GONE, a, (int)k });
				}
				else if (who.stands_in && !rig_named)
				{
					// Named once per actor: every one-off it plays is on the same rig.
					rig_named = !who.rig_read || !who.rig.agrees();
					if (!who.rig_read) found.push({ ONE_OFF_NO_RIG, a, (int)k });
					if (who.rig_read && !who.rig.agrees()) found.push({ ONE_OFF_OTHER_RIG, a, (int)k });
				}
			}
			if (has_clip && who.measured && s.kind == MOVE)
			{
				if (who.ground_of(s.clip).travels) found.push({ CLIP_TRAVELS, a, (int)k });
				if (!(who.move_ground_speed(s) > 0.0f)) found.push({ NO_GROUND_SPEED, a, (int)k });
			}
			if (s.end > cutscene.duration + CUT_LATE_SLACK) found.push({ ENDS_LATE, a, (int)k });
			if (s.kind == MOVE && (s.path < 0 || s.path >= cutscene.paths.len || cutscene.paths[s.path].points.len < 2))
			{
				found.push({ NO_PATH, a, (int)k });
			}
			if (s.kind == TURN && s.target_row.len > 0 && s.target_row == actor.row)
			{
				found.push({ SELF_TARGET, a, (int)k });
			}
			else if (s.kind == TURN && s.target_row.len > 0 && cutscene.actor_by_row(s.target_row) < 0)
			{
				found.push({ NO_TARGET, a, (int)k });
			}
			if (s.end - s.start <= CUT_SAME_TIME) found.push({ NO_LENGTH, a, (int)k });
			for (usz j = 0; j < k; j++)
			{
				if (!cut_strips_overlap(&actor.strips[j], s)) continue;
				found.push({ OVERLAP, a, (int)k });
				break;
			}
		}
	}
	foreach (usz i, &one : cutscene.one_offs)
	{
		int actor = cutscene.actor_by_row(one.row);
		usz uses = cutscene.one_off_uses(one.row, one.clip.name);
		if (actor < 0 || uses == 0)
		{
			found.push({ ONE_OFF_UNUSED, actor < 0 ? 0 : (usz)actor, (int)i });
		}
		else if (!clip_moves_anything(&one.clip))
		{
			found.push({ ONE_OFF_EMPTY, (usz)actor, (int)i });
		}
	}
	if (found.len() == 0) return {};
	return alloc::clone_slice(allocator, found.array_view());
}

<* Whether a clip keys a joint or holds, aims or walks one anywhere. *>
fn bool clip_moves_anything(AnimTemplate* clip)
{
	foreach (&key : clip.keyframes) if (key.dots.len > 0) return true;
	return clip.pins.len > 0 || clip.aims.len > 0 || clip.paths.len > 0 || clip.layers.len > 0;
}

fn String cut_strip_word(CutStripKind kind) @local
{
	switch (kind)
	{
		case MOVE: return "move";
		case TURN: return "turn";
		case PLAY: return "play";
	}
}

<*
 One problem in words, naming the actor, the strip and what is wrong.

 @param [in] cutscene
 @param [in] cast : "What cutscene_problems was given; names how a rig differs"
 @require problem.actor < cutscene.actors.len || problem.kind == ONE_OFF_UNUSED : "No such actor"
 @require (problem.kind != ONE_OFF_UNUSED && problem.kind != ONE_OFF_EMPTY) || (usz)problem.strip < cutscene.one_offs.len : "No such one-off"

 @return "The caller owns it"
*>
fn String cut_problem_text(Allocator allocator, Cutscene* cutscene, CutProblem problem, CutCast[] cast = {})
{
	if (problem.kind == ONE_OFF_UNUSED)
	{
		CutOneOff* one = &cutscene.one_offs[problem.strip];
		return string::format(allocator, "%s: no strip plays the one-off '%s'", one.row, one.clip.name);
	}
	if (problem.kind == ONE_OFF_EMPTY)
	{
		return string::format(allocator, "%s: the one-off '%s' keys nothing yet, so it cannot be exported",
			cutscene.actors[problem.actor].row, cutscene.one_offs[problem.strip].clip.name);
	}
	CutActor* actor = &cutscene.actors[problem.actor];
	CutStrip none = cut_strip(PLAY, 0.0f, 0.0f);
	bool on_strip = problem.strip >= 0 && problem.strip < actor.strips.len;
	CutStrip* s = on_strip ? &actor.strips[problem.strip] : &none;
	String word = cut_strip_word(s.kind);
	switch (problem.kind)
	{
		case NO_CHARACTER: return string::format(allocator, "%s: no character in the scene has this row", actor.row);
		case MISSING_CLIP:
			bool level = problem.actor < cast.len && cast[problem.actor].level_read;
			if (level)
			{
				return string::format(allocator, "%s: the %s at %.2f s plays '%s', which the level has no clip of for %s",
					actor.row, word, s.start, s.clip, cast[problem.actor].armature);
			}
			return string::format(allocator, "%s: the %s at %.2f s plays '%s', which its file lacks", actor.row, word, s.start, s.clip);
		case ENDS_LATE:
			return string::format(allocator, "%s: the %s at %.2f s ends at %.2f s, after the cutscene's %.2f s",
				actor.row, word, s.start, s.end, cutscene.duration);
		case NO_PATH:
			return string::format(allocator, "%s: the move at %.2f s has no path of two points to walk", actor.row, s.start);
		case NO_TARGET:
			return string::format(allocator, "%s: the turn at %.2f s faces '%s', who is not in this cutscene", actor.row, s.start, s.target_row);
		case SELF_TARGET:
			return string::format(allocator, "%s: the turn at %.2f s faces the actor itself", actor.row, s.start);
		case NO_LENGTH:
			return string::format(allocator, "%s: the %s at %.2f s has no length", actor.row, word, s.start);
		case OVERLAP:
			CutStrip* o = &none;
			for (int j = 0; j < problem.strip && on_strip; j++)
			{
				if (!cut_strips_overlap(&actor.strips[j], s)) continue;
				o = &actor.strips[j];
				break;
			}
			String lane = (cut_lane_bits(s) & cut_lane_bits(o) & 1) != 0 ? "Where" : "What";
			return string::format(allocator, "%s: the %s at %.2f s overlaps the %s at %.2f s on the %s lane",
				actor.row, word, s.start, cut_strip_word(o.kind), o.start, lane);
		case CLIP_TRAVELS:
			return string::format(allocator, "%s: the move at %.2f s plays '%s', which still travels: its root motion adds to the path; make it in place",
				actor.row, s.start, s.clip);
		case NOT_FRONT:
			return string::format(allocator, "%s: its character does not face +Z, so it walks its paths turned aside", actor.row);
		case NO_GROUND_SPEED:
			return string::format(allocator, "%s: the move at %.2f s plays '%s', whose ground speed is not known: timed at %.0f m/s; type one in its card",
				actor.row, s.start, s.clip, CUT_DEFAULT_GROUND_SPEED);
		case STAND_IN_GONE:
			return string::format(allocator, "%s: the level node it stands in for is no longer in the level; it keeps the place it had", actor.row);
		case ONE_OFF_GONE:
			return string::format(allocator, "%s: the %s at %.2f s plays the one-off '%s', which this cutscene does not have",
				actor.row, word, s.start, s.clip);
		case ONE_OFF_UNUSED:
		case ONE_OFF_EMPTY:
			return "".copy(allocator);
		case ONE_OFF_NO_RIG:
			return string::format(allocator, "%s: its one-offs play on the level's rig, which is read when the level is open",
				actor.row);
		case ONE_OFF_OTHER_RIG:
			RigMismatch rig = problem.actor < cast.len ? cast[problem.actor].rig : (RigMismatch){ MISSING_JOINT, "" };
			@pool()
			{
				return string::format(allocator, "%s: its one-off '%s' was made on another rig than the level's: %s",
					actor.row, s.clip, rig_mismatch_text(tmem, rig));
			};
	}
}

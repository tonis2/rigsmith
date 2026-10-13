<*
 The Animations pane's Optimize dialog: travel, turn and jitter taken out of the
 clip being edited in one go, as one undo step.

 The work is the two rewrites the MCP tools reach on their own —
 `clip_smoothed` (smooth_clip) and `clip_root_moved` (remove_movement) — chained
 so a clip that loses all three lands once, and one Ctrl+Z puts it all back.
*>
module crig;

import std::math;

<*
 What to take out of a clip. Translation holds the hips over where the clip
 starts and rotation takes off its net turn, as `RootMotionPolicy` does it;
 `on_root` carries them onto the root joint instead of discarding them.
*>
struct ClipCleanup
{
	bool translation;
	bool rotation;
	bool jitter;
	bool on_root;
}

fn bool ClipCleanup.asks(self) => self.translation || self.rotation || self.jitter;
fn bool ClipCleanup.moves(self) => self.translation || self.rotation;

<*
 Take what `cleanup` names out of the clip, as one undo step, and make the result
 the clip being edited.

 Jitter goes first, so the travel taken out afterwards is the smoothed travel
 and the hips end up exactly where the clip starts. A clip with no travel to take
 out still lands its smoothing, and the notice says it was already in place; a
 rig that cannot carry the travel as asked refuses the whole change rather than
 landing half of it.

 @return `False with a notice when nothing changed.`
*>
fn bool AppState.clean_clip(&self, AnimRef ref, ClipCleanup cleanup)
{
	if (!cleanup.asks())
	{
		self.@notice("Tick translation, rotation or jitter to remove.");
		return false;
	}
	if (!self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.clip(ref);
	if (!clip)
	{
		self.@notice("Pick an animation to optimize first.");
		return false;
	}
	String name = clip.name.copy(mem);
	defer name.free(mem);

	AnimTemplate smoothed;
	if (cleanup.jitter) smoothed = clip_smoothed(mem, *clip, {}, SMOOTH_DEFAULT_WINDOW, -1.0f, -1.0f, true);
	AnimTemplate built = smoothed;

	RootMotionMode mode = cleanup.on_root ? ON_ROOT : IN_PLACE;
	bool moved = false;
	if (cleanup.moves())
	{
		RigView? opened = self.open_rig(mem);
		if (catch opened)
		{
			if (cleanup.jitter) smoothed.free(mem);
			self.@notice("Place some joints first.");
			return false;
		}
		RigView view = opened;
		defer view.free(mem);
		RootMotionPolicy policy = {
			.mode = mode,
			.pinned = cleanup.translation,
			.turning = cleanup.rotation,
			.turn_only = !cleanup.translation,
		};
		AnimTemplate travelled;
		RootMotionOutcome outcome = clip_root_moved(mem, cleanup.jitter ? smoothed : *clip, &view.skeleton,
			self.names_for(&view, ref), policy, &travelled);
		switch (outcome)
		{
			case MOVED:
				if (cleanup.jitter) smoothed.free(mem);
				built = travelled;
				moved = true;
			case NO_TRAVEL:
			case NO_KEYS:
				// Nothing to take out: the smoothing, if asked for, is all there is.
				if (!cleanup.jitter)
				{
					self.notice_travel_refusal(outcome, mode, name);
					return false;
				}
			default:
				if (cleanup.jitter) smoothed.free(mem);
				self.notice_travel_refusal(outcome, mode, name);
				return false;
		}
	}

	bool forked = ref.pack != self.authored_pack;
	self.clear_animation_key_selection();
	AnimRef landed = self.land_clip(ref, built);
	if (!landed.valid()) return false;
	self.editing = landed;
	self.edit_time = math::min(self.edit_time, self.clip(landed).duration);
	// A fork's notice says where the change went, which matters more.
	if (forked) return true;

	DString said = dstring::temp();
	if (cleanup.jitter) said.append("smoothed out its jitter");
	if (moved)
	{
		if (said.len() > 0) said.append(", ");
		if (mode == ON_ROOT) { said.append("moved its travel onto the root joint"); }
		else if (cleanup.translation && cleanup.rotation) { said.append("held it in place and took out its turn"); }
		else if (cleanup.translation) { said.append("held it in place"); }
		else { said.append("took out its turn"); }
	}
	else if (cleanup.moves())
	{
		said.append(mode == IN_PLACE ? "; it already stays in place" : "; it has no hips travel to move");
	}
	self.@notice("%s: %s · Ctrl+Z undoes it", name, said.str_view());
	return true;
}

<*
 Tangent modes on the selected keys: reading what they agree on and setting them
 all as one clip swap. The handles themselves are `set_graph_tangent` (graph.c3);
 this is the menu and popover's side of it.

 Which channels a selection means is the same as for interpolation and ease: a
 pose selection covers every channel keyed in its columns, a channel selection
 only its own keys.
*>
module crig;

<*
 The tangent mode every selected channel key shares. False with no key selected,
 or when they differ (`mode` is left alone then, and `mixed` says which).
*>
fn bool AppState.animation_selection_tangent_mode(&self, AnimRef ref, AnimTangent* mode, bool* mixed = null)
{
	if (mixed) *mixed = false;
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || !self.anim_key_selection_ref.same(ref)) return false;
	usz seen;
	bool channels = self.anim_channel_key_selection.len() > 0;
	foreach (frame : clip.keyframes) foreach (dot : frame.dots)
	{
		for (int c = 0; c < 2; c++)
		{
			bool rotation = c == 0;
			if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
			bool picked = channels
				? self.channel_selection_contains(frame.time, dot.joint_name, rotation ? ROTATION : TRANSLATION)
				: self.animation_key_selected(ref, frame.time);
			if (!picked) continue;
			AnimTangent own = dot.tangents(rotation).mode;
			if (seen == 0)
			{
				*mode = own;
			}
			else if (own != *mode)
			{
				if (mixed) *mixed = true;
				return false;
			}
			seen++;
		}
	}
	return seen > 0;
}

<*
 Give every selected channel key tangent `mode`, as one clip swap. Each key's
 rates are seeded from what plays now (`set_tangent_mode`), so Auto to Free
 moves nothing; a segment that was linear becomes smooth so the tangent shows.
 Values, times and channels are untouched.
*>
fn bool AppState.set_selected_tangent_mode(&self, AnimRef ref, AnimTangent mode)
{
	AnimTemplate* clip = self.key_clip(ref);
	if (!clip || self.procedural_layer_of(ref) || !self.anim_key_selection_ref.same(ref) || self.pose_edit_pending) return false;
	bool channels = self.anim_channel_key_selection.len() > 0;
	AnimTemplate changed = clip_copy(mem, *clip);
	usz written;
	foreach (usz f, &frame : changed.keyframes) foreach (&dot : frame.dots)
	{
		for (int c = 0; c < 2; c++)
		{
			bool rotation = c == 0;
			if (rotation ? !dot.keys_rotation() : !dot.keys_translation()) continue;
			bool picked = channels
				? self.channel_selection_contains(frame.time, dot.joint_name, rotation ? ROTATION : TRANSLATION)
				: self.animation_key_selected(ref, frame.time);
			if (!picked) continue;
			if (set_tangent_mode(&changed, f, dot.joint_name, rotation, mode, true, clip)) written++;
		}
	}
	if (written == 0) { changed.free(mem); return false; }
	return self.land_keeping_selection(ref, changed, true);
}

<*
 Optimize keys: drop the keys a clip can lose without changing how it moves.

 Applied to the clip itself, as one undo step, so the timeline shows the result.
 `clip_keys_reduced` does the work; this lands it the way the other clip
 rewrites do.
*>
module crig;

import rig;

<*
 Optimize the clip's keys at `level`.

 @return `False with a notice when nothing changed.`
*>
fn bool AppState.optimize_clip_keys(&self, AnimRef ref, KeyReduction level)
{
	if (level == OFF || !self.ensure_clip_imported(ref)) return false;
	AnimTemplate* clip = self.clip(ref);
	if (!clip)
	{
		self.@notice("Pick an animation to edit first.");
		return false;
	}
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("Place some joints first.");
		return false;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);

	usz before = clip.keyframes.len;
	AnimTemplate reduced;
	if (!clip_keys_reduced(mem, *clip, &view.skeleton, names, level, &reduced))
	{
		self.@notice("%s has no keys to lose at this level.", clip.name);
		return false;
	}
	usz after = reduced.keyframes.len;
	String name = clip.name.copy(mem);
	defer name.free(mem);
	// The saved-key selection names times that may no longer hold a key.
	self.clear_animation_key_selection();
	bool forked = ref.pack != self.authored_pack;
	AnimRef landed = self.land_clip(ref, reduced);
	if (!landed.valid()) return false;
	self.editing = landed;
	if (!forked) self.@notice("%s: kept %d of %d keys · Ctrl+Z undoes it", name, after, before);
	return true;
}

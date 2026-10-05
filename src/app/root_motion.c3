<*
 The Animations menu's root-motion edits: Make in place, and Move travel to root
 joint. Each rewrites the edited clip's keys (`clip_root_moved`) as one undo
 step, and a library clip becomes a project copy first, as every edit does.

 Make in place stops the whole figure travelling: a rig with a root joint loses
 the travel on it as well as on the hips. Moving travel to the root joint needs
 a rig that has one; a rig rooted at the hips is told so and left alone.
*>
module crig;


<*
 Whether this rig has a root joint under the hips to carry travel.
*>
fn bool AppState.has_root_joint(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	return motion_roots(&view.skeleton, view.names).root >= 0;
}

<*
 Move the edited clip's travel. One undo step.

 @return `False with a notice when nothing changed.`
*>
fn bool AppState.move_clip_travel(&self, AnimRef ref, RootMotionPolicy policy)
{
	RootMotionMode mode = policy.mode;
	if (mode == KEEP || !self.ensure_clip_imported(ref)) return false;
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

	AnimTemplate moved;
	switch (clip_root_moved(mem, *clip, &view.skeleton, names, policy, &moved))
	{
		case MOVED:
			break;
		case NO_ROOT_JOINT:
			self.@notice("This rig has no root joint under the hips to carry the travel. Use Make in place, or add a root joint at the floor.");
			return false;
		case UNNAMED:
			self.@notice("The hips or root joint has no name, so its keys can't be written.");
			return false;
		default:
			self.@notice(mode == IN_PLACE ? "%s already stays in place." : "%s has no hips travel to move.",
				clip.name);
			return false;
	}
	String name = clip.name.copy(mem);
	defer name.free(mem);
	bool forked = ref.pack != self.authored_pack;
	AnimRef landed = self.land_clip(ref, moved);
	if (!landed.valid()) return false;
	self.editing = landed;
	// A fork's notice says where the change went, which matters more.
	if (!forked) self.@notice(mode == IN_PLACE ? "%s now stays in place · Ctrl+Z undoes it"
		: "%s now travels on the root joint · Ctrl+Z undoes it", name);
	return true;
}

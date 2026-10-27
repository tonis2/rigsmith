<*
 Repairing a take: Smooth and Make loop, the two clip tools a generated motion
 needs most. The work is `clip_smoothed`, `clip_cycle` and `clip_whole_loop` (anim/); these land it
 the way every clip rewrite lands, for the Animations pane and MCP alike.
*>
module crig;

import std::math;

// Seconds the pane's Smooth averages over: takes out jitter, keeps a step's shape.
const float SMOOTH_DEFAULT_WINDOW = 0.1f;

<*
 Smooth the clip's keys (`clip_smoothed`), as one undo step, and make it the clip
 being edited.

 @return `The landed clip, or NO_ANIM when it would not land.`
*>
fn AnimRef AppState.smooth_clip(&self, AnimRef ref, String[] joints, float window, float start = -1.0f,
	float end = -1.0f, bool hold_contacts = true)
{
	if (!self.ensure_clip_imported(ref)) return NO_ANIM;
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return NO_ANIM;
	AnimTemplate built = clip_smoothed(mem, *clip, joints, window, start, end, hold_contacts);
	self.clear_animation_key_selection();
	AnimRef landed = self.land_clip(ref, built);
	if (!landed.valid()) return NO_ANIM;
	self.editing = landed;
	self.edit_time = math::min(self.edit_time, self.clip(landed).duration);
	self.refresh_ui();
	return landed;
}

<*
 Cut a seamless cycle out of the take (`clip_cycle`) as a new looping clip, its
 keys thinned at Optimize keys' Light tolerance, bound and made the clip being
 edited, as one undo step. The take stays as it was, unless `in_place`.

 @param name : `The cycle's name, made unique; empty for the take's with " loop". Unused in place.`
 @param why : `Receives the reason on refusal.`
 @param in_place : `Replace the take with the cycle, under its name, as the pane's Make loop does.`
 @return `The new clip, or NO_ANIM.`
*>
fn AnimRef AppState.cut_cycle(&self, AnimRef ref, float period_min, float period_max, float from_min, float from_max,
	float crossfade, String name, CycleCut* cut, DString* why, bool in_place = false)
{
	if (!self.ensure_clip_imported(ref) || !self.clip(ref))
	{
		why.append_string("that clip cannot be read");
		return NO_ANIM;
	}
	AnimTemplate take = *self.clip(ref);
	String called = in_place ? take.name.copy(mem)
		: self.unused_clip_name(mem, name.len > 0 ? name : string::tformat("%s loop", take.name));
	defer called.free(mem);

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		why.append_string("there is no rig to cut a cycle for");
		return NO_ANIM;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);

	AnimTemplate? cycled = clip_cycle(mem, take, period_min, period_max, from_min, from_max, crossfade,
		root_name(&view, names), called, cut);
	if (catch cycled)
	{
		why.appendf("no cycle of %.3g to %.3g s starting between %.3g and %.3g s fits in %s (%.3g s)",
			period_min, period_max, from_min, from_max, take.name, take.duration)!!;
		return NO_ANIM;
	}
	return self.land_cycle(ref, cycled, &view, names, in_place, why);
}

<*
 Loop the whole take (`clip_whole_loop`): its end crossfaded into its start, as a
 new looping clip, thinned, bound and made the clip being edited, as one undo
 step — Make loop's Whole take. The take stays as it was, unless `in_place`.

 @param crossfade : `Seconds the end blends into the start over.`
 @param name : `The loop's name, made unique; empty for the take's with " loop". Unused in place.`
 @param why : `Receives the reason on refusal.`
 @param in_place : `Replace the take with the loop, under its name.`
 @return `The new clip, or NO_ANIM.`
*>
fn AnimRef AppState.loop_whole_take(&self, AnimRef ref, float crossfade, String name, CycleCut* cut, DString* why,
	bool in_place = false)
{
	if (!self.ensure_clip_imported(ref) || !self.clip(ref))
	{
		why.append_string("that clip cannot be read");
		return NO_ANIM;
	}
	AnimTemplate take = *self.clip(ref);
	String called = in_place ? take.name.copy(mem)
		: self.unused_clip_name(mem, name.len > 0 ? name : string::tformat("%s loop", take.name));
	defer called.free(mem);

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		why.append_string("there is no rig to loop it for");
		return NO_ANIM;
	}
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);

	AnimTemplate? looped = clip_whole_loop(mem, take, crossfade, root_name(&view, names), called, cut);
	if (catch looped)
	{
		why.appendf("%s (%.3g s) is too short to blend %.3g s of its end into its start", take.name, take.duration, crossfade)!!;
		return NO_ANIM;
	}
	return self.land_cycle(ref, looped, &view, names, in_place, why);
}

// The name of the rig's root joint in `names`; "" when it has none.
fn String root_name(RigView* view, String[] names) @local
{
	foreach (usz j, parent : view.skeleton.parents)
	{
		if (parent < 0 && j < names.len) return names[j];
	}
	return "";
}

<*
 Land a loop made from `ref`: written every sixtieth of a second, it is kept to
 the keys it needs, then replaces the take or joins the authored pack.
*>
fn AnimRef AppState.land_cycle(&self, AnimRef ref, AnimTemplate loop, RigView* view, String[] names, bool in_place,
	DString* why)
{
	loop.compile_tracks(mem);
	AnimTemplate thinner;
	if (clip_keys_reduced(mem, loop, &view.skeleton, names, LIGHT, &thinner))
	{
		loop.free(mem);
		loop = thinner;
	}

	self.clear_animation_key_selection();
	// A new clip cut from a library take goes into the authored pack, which
	// speaks the rig's words; landing in place respells a fork itself.
	AnimRef landed = in_place ? self.land_clip(ref, loop) : self.author_clip(self.in_rig_words(loop, ref));
	if (!landed.valid())
	{
		why.append_string("the loop would not land");
		return NO_ANIM;
	}
	self.edit_time = 0.0f;
	self.refresh_ui();
	return landed;
}

<*
 The period range a take's cycle is looked for in when nobody says: from a fifth
 of the take to half of it, starting after its first tenth and ending before its
 last — where a generated motion starts and stops.
*>
fn void cycle_defaults(float duration, float* period_min, float* period_max, float* from_min, float* from_max)
{
	*period_min = duration * 0.2f;
	*period_max = duration * 0.5f;
	*from_min = duration * 0.1f;
	*from_max = duration * 0.9f;
}

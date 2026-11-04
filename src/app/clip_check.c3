<*
 Check: what `clip_metrics` finds wrong with the edited clip, as a list of
 places on its timeline, and the one-click fix (Close loop).

 A clip that declares no feet has them read off its motion (`derived_contacts`),
 so a hand-keyed walk is checked for sliding feet too.
*>
module crig;

import std::math;
import std::sort;

fn void ClipCheck.free(&self)
{
	foreach (issue : self.issues)
	{
		issue.label.free(mem);
		issue.trailing.free(mem);
	}
	if (self.issues.len > 0) alloc::free(mem, self.issues);
	*self = { .ref = NO_ANIM };
}

// Whether the check on hand is about this clip as it is now.
fn bool AppState.check_current(&self, AnimRef ref)
	=> self.anim_check.ran && self.anim_check.ref.same(ref) && self.anim_check.revision == self.undo_stack.revision;

<*
 Measure the clip and keep what is wrong with it, sorted by time.

 @return `How many issues were found; the list is on anim_check.`
*>
fn usz AppState.check_clip(&self, AnimRef ref)
{
	self.anim_check.free();
	AnimTemplate* clip = self.clip(ref);
	if (!clip || !self.ensure_clip_imported(ref)) return 0;
	clip = self.clip(ref);
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);

	bool owned;
	AnimGround contacts = clip_contacts(&view, names, clip, &owned);
	defer if (owned) contacts.free(mem);
	ClipMetrics numbers = clip_metrics(mem, &view.skeleton, names, *clip, CHECK_SAMPLES,
		&self.doc, view.dot_ids, owned ? contacts : (AnimGround){});
	defer numbers.free(mem);

	CheckIssue[] issues = alloc::new_array(mem, CheckIssue, numbers.issues.len);
	foreach (usz i, found : numbers.issues)
	{
		float at = found.phase * clip.duration;
		issues[i] = {
			.kind = found.kind,
			.time = at,
			.magnitude = found.magnitude,
			.label = found.joint.len > 0 ? string::format(mem, "%s · %s", found.kind.words(), found.joint)
				: found.kind.words().copy(mem),
			.trailing = string::format(mem, "f %d · %.2f s", (int)math::round(at * (float)self.anim_fps), at),
		};
	}
	sort::insertionsort(issues, fn int(CheckIssue a, CheckIssue b) => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
	self.anim_check = { .ref = ref, .ran = true, .revision = self.undo_stack.revision, .issues = issues };
	return issues.len;
}

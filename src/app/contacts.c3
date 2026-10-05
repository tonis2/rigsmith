<*
 Contact lanes: a clip's ground windows as the sheet shows and edits them.

 A lane is one contact joint; its bars are the windows of `AnimGround.feet`
 that name it, in cycle phase. Every edit rewrites the clip's ground spec and
 lands the clip, so each is one undo step and persists wherever the clip does.
*>
module crig;

import std::math;

// A new contact covers this much of the cycle.
const float CONTACT_NEW_SPAN = 0.25f;
// A joint resting higher than this fraction of the rig's height over the
// lowest joint is not on the floor, like a hand.
const float CONTACT_FLOOR_BAND = 0.12f;

fn float phase_wrapped(float phase) => phase - math::floor(phase);

<*
 How many lanes a ground spec draws: one per distinct contact joint.
*>
fn usz contact_lane_count(AnimGround ground)
{
	usz lanes = 0;
	foreach (usz i, foot : ground.feet) if (contact_first_of(ground, foot.joint) == i) lanes++;
	return lanes;
}

// The first window naming this joint, or the window count when none does.
fn usz contact_first_of(AnimGround ground, String joint)
{
	foreach (usz i, foot : ground.feet) if (foot.joint == joint) return i;
	return ground.feet.len;
}

<*
 The lane a window is drawn in: lanes follow the order each joint first
 appears in the spec.
*>
fn usz contact_lane_of(AnimGround ground, usz window)
{
	if (window >= ground.feet.len) return 0;
	usz first = contact_first_of(ground, ground.feet[window].joint);
	usz lane = 0;
	for (usz i = 0; i < first; i++) if (contact_first_of(ground, ground.feet[i].joint) == i) lane++;
	return lane;
}

// Whether two cyclic windows, each a start and a length in phase, share time.
fn bool cyclic_overlap(float a, float a_span, float b, float b_span) @local
{
	if (a_span >= 1.0f || b_span >= 1.0f) return true;
	return phase_wrapped(b - a) < a_span - 1e-5f || phase_wrapped(a - b) < b_span - 1e-5f;
}

<*
 The shortest window the edited clip allows: one display frame.
*>
fn float AppState.contact_min_span(&self, AnimTemplate* clip)
{
	if (clip.duration <= 0.0f || self.anim_fps <= 0) return 0.01f;
	return math::clamp(1.0f / ((float)self.anim_fps * clip.duration), 0.001f, 0.5f);
}

<*
 A window from `down` lasting `span` of the cycle, as the spec stores it, or
 false when it does not fit: shorter than a frame, off a one-shot clip, or over
 another window of the same joint (`skip` is the window being replaced).
*>
fn bool AppState.contact_window(&self, AnimTemplate* clip, String joint, usz skip, float down, float span, AnimFoot* out)
{
	float least = self.contact_min_span(clip);
	if (span < least - 1e-6f) return false;
	if (clip.loop)
	{
		if (span >= 1.0f - 1e-4f)
		{
			down = 0.0f;
			span = 1.0f;
		}
		down = phase_wrapped(down);
	}
	else
	{
		if (down < -1e-5f || down + span > 1.0f + 1e-5f) return false;
		down = math::clamp(down, 0.0f, 1.0f);
		span = math::min(span, 1.0f - down);
	}
	foreach (usz i, foot : clip.ground.feet)
	{
		if (i == skip || foot.joint != joint) continue;
		if (cyclic_overlap(down, span, foot.down, foot.span())) return false;
	}
	out.down = down;
	out.up = span >= 1.0f ? 1.0f : (clip.loop ? phase_wrapped(down + span) : down + span);
	return true;
}

<*
 Land the clip with `ground` in place of its own. Takes `ground` over.
*>
fn bool AppState.land_contacts(&self, AnimRef ref, AnimGround ground)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip)
	{
		ground.free(mem);
		return false;
	}
	AnimTemplate changed = clip_copy(mem, *clip);
	changed.ground.free(mem);
	changed.ground = ground;
	return self.land_keeping_selection(ref, changed);
}

// The clip, read in full, or null.
fn AnimTemplate* AppState.contact_clip(&self, AnimRef ref)
{
	if (!self.ensure_clip_imported(ref)) return null;
	return self.clip(ref);
}

<*
 Move a window: `down` its new start and `span` its length, in phase. One
 undo step.

 @return `False with a notice when it does not fit.`
*>
fn bool AppState.set_contact_window(&self, AnimRef ref, usz window, float down, float span)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip || window >= clip.ground.feet.len) return false;
	AnimFoot placed = clip.ground.feet[window];
	if (!self.contact_window(clip, placed.joint, window, down, span, &placed))
	{
		self.@notice("A contact can't go there: it would overlap another contact of %s, leave the animation or be shorter than a frame.",
			placed.joint);
		return false;
	}
	AnimFoot was = clip.ground.feet[window];
	if (math::abs(was.down - placed.down) < 1e-6f && math::abs(was.up - placed.up) < 1e-6f) return false;
	AnimGround ground = ground_copy(mem, clip.ground);
	ground.feet[window].down = placed.down;
	ground.feet[window].up = placed.up;
	return self.land_contacts(ref, ground);
}

<*
 Whether `joint` rests on the floor on this rig: a hand does not, so its
 contacts are held but never put on the floor.
*>
fn bool AppState.joint_rests_on_floor(&self, AnimRef ref, String joint)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return true;
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	float height = view.skeleton.height();
	if (view.skeleton.len() == 0 || height <= 0.0f) return true;
	float floor = view.skeleton.joints[0].y;
	foreach (at : view.skeleton.joints) floor = math::min(floor, at.y);
	foreach (usz i, name : names)
	{
		if (name != joint || i >= view.skeleton.len()) continue;
		return view.skeleton.joints[i].y <= floor + CONTACT_FLOOR_BAND * height;
	}
	return true;
}

<*
 Add a window for `joint`, starting a new lane when it has none. One undo step.
*>
fn bool AppState.add_contact_window(&self, AnimRef ref, String joint, float down, float span)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip || joint.len == 0) return false;
	AnimFoot placed = { .joint = joint };
	usz first = contact_first_of(clip.ground, joint);
	placed.off_floor = first < clip.ground.feet.len ? clip.ground.feet[first].off_floor
		: !self.joint_rests_on_floor(ref, joint);
	if (!self.contact_window(clip, joint, ~(usz)0, down, span, &placed))
	{
		self.@notice("A contact can't go there: it would overlap another contact of %s, leave the animation or be shorter than a frame.", joint);
		return false;
	}
	AnimGround ground = clip.ground;
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, (sz)ground.feet.len + 1);
	foreach (usz i, foot : ground.feet)
	{
		feet[i] = foot;
		feet[i].joint = foot.joint.copy(mem);
	}
	placed.joint = joint.copy(mem);
	feet[ground.feet.len] = placed;
	return self.land_contacts(ref, { .feet = feet, .floor = ground.floor, .floor_set = ground.floor_set });
}

// The spec without window `window` and without every window of `joint`.
fn AnimGround ground_without(AnimGround ground, usz window, String joint) @local
{
	usz kept = 0;
	foreach (usz i, foot : ground.feet) if (i != window && foot.joint != joint) kept++;
	AnimGround out = { .floor = ground.floor, .floor_set = ground.floor_set };
	if (kept == 0) return out;
	out.feet = alloc::new_array(mem, AnimFoot, (sz)kept);
	usz at = 0;
	foreach (usz i, foot : ground.feet)
	{
		if (i == window || foot.joint == joint) continue;
		out.feet[at] = foot;
		out.feet[at++].joint = foot.joint.copy(mem);
	}
	return out;
}

<*
 Delete one window; the lane goes with its last one. One undo step.
*>
fn bool AppState.delete_contact_window(&self, AnimRef ref, usz window)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip || window >= clip.ground.feet.len) return false;
	return self.land_contacts(ref, ground_without(clip.ground, window, ""));
}

<*
 Remove every window of one joint. One undo step.
*>
fn bool AppState.remove_contact_lane(&self, AnimRef ref, String joint)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip || joint.len == 0 || contact_first_of(clip.ground, joint) >= clip.ground.feet.len) return false;
	String name = joint.copy(mem);
	defer name.free(mem);
	return self.land_contacts(ref, ground_without(clip.ground, ~(usz)0, name));
}

<*
 The selected joint in the clip's words, or "" (temporary).
*>
fn String AppState.selected_clip_joint(&self, AnimRef ref)
{
	if (self.selected == 0) return "";
	RigView? opened = self.open_rig(mem);
	if (catch opened) return "";
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	foreach (usz i, id : view.dot_ids)
	{
		if (id == self.selected && i < names.len) return names[i].tcopy();
	}
	return "";
}

<*
 + Contact: a window for the selected joint from the playhead, a quarter of
 the cycle long or up to its next window. One undo step.
*>
fn bool AppState.add_contact_for_selected(&self, AnimRef ref)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip) return false;
	String joint = self.selected_clip_joint(ref);
	if (joint.len == 0)
	{
		self.@notice("Select the joint that touches the ground (a foot, or a hand) first.");
		return false;
	}
	float down = clip.duration > 0.0f ? math::clamp(self.edit_time / clip.duration, 0.0f, 1.0f) : 0.0f;
	if (!clip.loop && down >= 1.0f) down = 0.0f;
	float span = CONTACT_NEW_SPAN;
	if (!clip.loop) span = math::min(span, 1.0f - down);
	foreach (foot : clip.ground.feet)
	{
		if (foot.joint != joint) continue;
		if (foot.planted(down))
		{
			self.@notice("%s is already in contact here.", joint);
			return false;
		}
		float ahead = clip.loop ? phase_wrapped(foot.down - down) : foot.down - down;
		if (ahead > 0.0f) span = math::min(span, ahead);
	}
	if (!self.add_contact_window(ref, joint, down, span)) return false;
	self.@notice("%s is planted from here · drag the bar's ends on the timeline to adjust", joint);
	return true;
}

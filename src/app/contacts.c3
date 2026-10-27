<*
 Contact lanes: a clip's ground windows as the sheet shows and edits them.

 A lane is one contact joint; its bars are the windows of `AnimGround.feet`
 that name it, in cycle phase. Every edit rewrites the clip's ground spec and
 lands the clip, so each is one undo step and persists wherever the clip does.
*>
module crig;

import rig;
import std::collections::list;
import std::math;
import std::math::matrix;

// The most feet `derived_contacts` reads off one clip.
const usz CONTACT_FEET_MOST = 8;

// Even instants a clip's feet are read at to find their steps.
const usz CONTACT_SAMPLES = 48;
// A foot is down within this fraction of the rig's height of the lowest foot.
const float CONTACT_DOWN_BAND = 0.02f;
// A foot this fraction of the rig's height over the lowest it gets is up,
// whatever the other feet do: both off the floor in a run's flight.
const float CONTACT_LIFT_MOST = 0.05f;
// A new contact covers this much of the cycle.
const float CONTACT_NEW_SPAN = 0.25f;

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
		return view.skeleton.joints[i].y <= floor + GROUND_FOOT_BAND * height;
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
 + Contact: a window for the selected joint's foot over the step the playhead is
 in, read off the motion (`contact_runs`). A joint of a foot names the foot's top
 (the ankle over a toe), so the floor solve reads the whole foot. With no step
 under the playhead the window runs from it, a quarter of the cycle long or up to
 the joint's next window. One undo step.
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
	float at = clip.duration > 0.0f ? math::clamp(self.edit_time / clip.duration, 0.0f, 1.0f) : 0.0f;
	if (!clip.loop && at >= 1.0f) at = 0.0f;
	AnimFoot step;
	bool matched = self.contact_step_at(ref, &joint, at, &step);
	float down = at;
	float span = CONTACT_NEW_SPAN;
	if (!clip.loop) span = math::min(span, 1.0f - down);
	if (matched)
	{
		down = step.down;
		span = step.span();
	}
	foreach (foot : clip.ground.feet)
	{
		if (foot.joint != joint) continue;
		if (foot.planted(at))
		{
			self.@notice("%s is already in contact here.", joint);
			return false;
		}
		// A step that runs into a window this foot already has starts at the
		// playhead instead, and still ends where the step does.
		if (matched && cyclic_overlap(down, span, foot.down, foot.span()))
		{
			span = clip.loop ? phase_wrapped(step.up - at) : step.up - at;
			if (step.up >= 1.0f && !clip.loop) span = 1.0f - at;
			down = at;
		}
	}
	foreach (foot : clip.ground.feet)
	{
		if (foot.joint != joint) continue;
		float ahead = clip.loop ? phase_wrapped(foot.down - down) : foot.down - down;
		if (ahead > 0.0f) span = math::min(span, ahead);
	}
	if (!self.add_contact_window(ref, joint, down, span)) return false;
	if (matched)
	{
		self.@notice("%s is planted for its step here · drag the bar's ends on the timeline to adjust", joint);
	}
	else
	{
		self.@notice("%s is planted from here · drag the bar's ends on the timeline to adjust", joint);
	}
	return true;
}

<*
 The step a foot is taking at `phase`, for the joint `*joint` names: when that
 joint rests on the floor it is renamed to its foot's top, and `step` is the run
 of `contact_runs` holding the phase. False, with the name as it was, for a joint
 off the floor or a phase in no step.
*>
fn bool AppState.contact_step_at(&self, AnimRef ref, String* joint, float phase, AnimFoot* step)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	GroundFloor level = floor_of_solve(&view.skeleton, {}, 0.0f, false);
	sz found = -1;
	foreach (usz i, name : names) if (i < view.skeleton.len() && name == *joint) { found = (sz)i; break; }
	if (found < 0 || !level.rests_low(&view.skeleton, (usz)found)) return false;
	usz top = level.foot_of(&view.skeleton, (usz)found);
	if (names[top].len == 0) return false;
	*joint = names[top].tcopy();

	String[1] asked = { *joint };
	AnimGround runs = self.contact_runs(ref, &view, asked[..]);
	defer runs.free(mem);
	foreach (run : runs.feet)
	{
		if (!run.planted(phase)) continue;
		*step = { .down = run.down, .up = run.up };
		return true;
	}
	return false;
}

<*
 Find contacts: every foot of the rig gets a window for each step it takes, read
 off the motion (`contact_runs`), in place of the windows the clip's feet had.
 Contacts off the floor (a hand on a wall) and the floor height stay. One undo
 step.
*>
fn bool AppState.find_contacts(&self, AnimRef ref)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip) return false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	GroundFloor level = floor_of_solve(&view.skeleton, {}, 0.0f, false);
	List{String} tops;
	tops.init(tmem);
	foreach (usz j, name : names)
	{
		if (j < view.skeleton.len() && name.len > 0 && level.foot_top(&view.skeleton, j)) tops.push(name);
	}
	AnimGround runs = self.contact_runs(ref, &view, tops.array_view());
	if (runs.feet.len == 0)
	{
		runs.free(mem);
		self.@notice("No steps found: the feet never come to rest near the lowest they reach.");
		return false;
	}
	usz kept = 0;
	foreach (foot : clip.ground.feet) if (foot.off_floor) kept++;
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, (sz)(runs.feet.len + kept));
	usz at = 0;
	foreach (foot : runs.feet) feet[at++] = foot;
	foreach (foot : clip.ground.feet)
	{
		if (!foot.off_floor) continue;
		feet[at] = foot;
		feet[at++].joint = foot.joint.copy(mem);
	}
	usz lanes = contact_lane_count({ .feet = runs.feet });
	usz steps = runs.feet.len;
	// The runs' names moved into `feet`; only the array is left to free.
	alloc::free(mem, runs.feet);
	if (!self.land_contacts(ref, { .feet = feet, .floor = clip.ground.floor, .floor_set = clip.ground.floor_set })) return false;
	self.@notice("Found %d steps on %d feet · drag the bars on the timeline to adjust", steps, lanes);
	return true;
}

<*
 The steps a clip's feet take, one window apiece, for each joint of `joints` that
 rests on the floor, named as given. A foot is read by its top joint, the ankle:
 the toes under it point and roll, and a clip may push them through the floor
 mid-swing. It is down while its ankle is within a small height of the lowest
 ankle of the rig at that instant — so a body the keys bob up and down, which lifts
 every foot together, does not hide a stance — and not far above the lowest it
 ever gets, so both feet off the floor in a run's flight are up. Read off the keys
 as they play but before the floor solve moves the body. A run shorter than three
 samples is not a step.

 @return `Owned; free with AnimGround.free. Windows of one joint are in order.`
*>
fn AnimGround AppState.contact_runs(&self, AnimRef ref, RigView* view, String[] joints)
{
	AnimTemplate* clip = self.contact_clip(ref);
	if (!clip || clip.duration <= 0.0f || joints.len == 0) return {};
	String[] names = self.names_for(view, ref);
	float height = view.skeleton.height();
	if (height <= 0.0f) return {};
	GroundFloor level = floor_of_solve(&view.skeleton, {}, 0.0f, false);

	// Every foot of the rig, so each is read against the others.
	List{usz} tops;
	tops.init(tmem);
	for (usz j = 0; j < view.skeleton.len() && j < names.len; j++)
	{
		if (level.foot_top(&view.skeleton, j)) tops.push(j);
	}
	if (tops.len() == 0) return {};
	usz feet = (usz)tops.len();

	float[] lift = alloc::new_array(tmem, float, (sz)(CONTACT_SAMPLES * feet));
	for (usz s = 0; s < CONTACT_SAMPLES; s++)
	{
		float t = clip.loop ? (float)s / (float)CONTACT_SAMPLES * clip.duration
			: (float)s / (float)(CONTACT_SAMPLES - 1) * clip.duration;
		rig::Pose pose = self.evaluated_clip_pose(mem, view, *clip, ref, t, grounded: false);
		defer pose.free(mem);
		Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
		if (catch built) return {};
		defer alloc::free(mem, built);
		foreach (usz f, j : tops)
		{
			lift[f * CONTACT_SAMPLES + s] = view.skeleton.joints[j].transform(built[j]).y - view.skeleton.joints[j].y;
		}
	}

	AnimFootList out;
	out.init(mem);
	defer out.free();
	bool[] down = alloc::new_array(tmem, bool, (sz)CONTACT_SAMPLES);
	foreach (joint : joints)
	{
		sz f = -1;
		foreach (usz j, name : names)
		{
			if (j >= view.skeleton.len() || name != joint || !level.rests_low(&view.skeleton, j)) continue;
			usz top = level.foot_of(&view.skeleton, j);
			foreach (usz k, t : tops) if (t == top) f = (sz)k;
			break;
		}
		if (f < 0) continue;
		float[] own = lift[(usz)f * CONTACT_SAMPLES : CONTACT_SAMPLES];
		float low = own[0];
		foreach (h : own) low = math::min(low, h);
		for (usz s = 0; s < CONTACT_SAMPLES; s++)
		{
			float lowest = own[s];
			for (usz k = 0; k < feet; k++) lowest = math::min(lowest, lift[k * CONTACT_SAMPLES + s]);
			down[s] = own[s] <= lowest + CONTACT_DOWN_BAND * height && own[s] <= low + CONTACT_LIFT_MOST * height;
		}
		push_runs(&out, joint, down, clip.loop, true);
	}
	if (out.len() == 0) return {};
	return { .feet = out.to_array(mem) };
}

<*
 Feet and stance windows read off a clip that declares none.

 A foot is the uppermost of a run of joints resting near the floor (an ankle over
 its toe); it is down while it is within a small height of the lowest it ever
 gets, and its window is the longest such run, wrapping on a looping clip. A
 joint down less than three samples is not a foot of this clip.

 `every_run` keeps each run rather than the longest, one window apiece — a jump's
 takeoff and its landing, or each step of a walk that is several cycles long. That
 is what pinning the feet wants; Check measures by the longest.

 @return `Owned; free with AnimGround.free. Empty when the rig has no such joint.`
*>
fn AnimGround derived_contacts(rig::Skeleton* skeleton, String[] names, AnimTemplate clip, bool every_run = false)
{
	usz joints = skeleton.len();
	if (joints == 0 || clip.duration <= 0.0f) return {};
	float height = skeleton.height();
	if (height <= 0.0f) return {};
	float floor = skeleton.joints[0].y;
	foreach (joint : skeleton.joints) floor = math::min(floor, joint.y);

	const float NEAR_FLOOR = GROUND_FOOT_BAND;
	const usz SAMPLES = CONTACT_SAMPLES;

	usz[CONTACT_FEET_MOST] feet;
	usz count = 0;
	for (usz j = 0; j < joints && count < CONTACT_FEET_MOST; j++)
	{
		if (j >= names.len || names[j].len == 0) continue;
		if (skeleton.joints[j].y > floor + NEAR_FLOOR * height) continue;
		int parent = skeleton.parents[j];
		if (parent >= 0 && skeleton.joints[(usz)parent].y <= floor + NEAR_FLOOR * height) continue;
		feet[count++] = j;
	}
	if (count == 0) return {};

	float[SAMPLES * CONTACT_FEET_MOST] heights;
	for (usz s = 0; s < SAMPLES; s++)
	{
		float t = clip.loop ? (float)s / (float)SAMPLES * clip.duration : (float)s / (float)(SAMPLES - 1) * clip.duration;
		rig::Pose pose = clip.pose(mem, skeleton, names, t);
		defer pose.free(mem);
		Matrix4f[]? built = rig::joint_palette(mem, skeleton, pose);
		if (catch built) return {};
		defer alloc::free(mem, built);
		for (usz f = 0; f < count; f++) heights[f * SAMPLES + s] = skeleton.joints[feet[f]].transform(built[feet[f]]).y;
	}

	AnimFootList out;
	out.init(mem);
	defer out.free();
	for (usz f = 0; f < count; f++)
	{
		push_down_runs(&out, names[feet[f]], heights[f * SAMPLES : SAMPLES], height, clip.loop, every_run);
	}
	if (out.len() == 0) return {};
	return { .feet = out.to_array(mem) };
}

<*
 The windows one joint spends down, read off its height at even samples: down
 while within CONTACT_DOWN_BAND of the rig's height over the lowest it gets.
 Pushed onto `out` under `joint`, copied, as `push_runs` does.
*>
fn void push_down_runs(AnimFootList* out, String joint, float[] heights, float height, bool loop, bool every_run) @local
{
	usz samples = heights.len;
	if (samples == 0) return;
	float low = heights[0];
	foreach (h : heights) low = math::min(low, h);
	bool[] down = alloc::new_array(tmem, bool, (sz)samples);
	foreach (usz s, h : heights) down[s] = h <= low + CONTACT_DOWN_BAND * height;
	push_runs(out, joint, down, loop, every_run);
}

<*
 The runs of even samples a joint is down, as windows: every run of three
 samples or more with `every_run`, else the longest; down the whole time is one
 window over all of it. Pushed onto `out` under `joint`, copied.
*>
fn void push_runs(AnimFootList* out, String joint, bool[] down, bool loop, bool every_run) @local
{
	usz samples = down.len;
	if (samples == 0) return;
	usz total = 0;
	foreach (d : down) if (d) total++;
	if (total == samples)
	{
		out.push({ .joint = joint.copy(mem), .down = 0.0f, .up = 1.0f });
		return;
	}
	float span = loop ? (float)samples : (float)(samples - 1);
	usz best = 0;
	usz best_start = 0;
	for (usz start = 0; start < samples; start++)
	{
		if (!down[start]) continue;
		usz before = (start + samples - 1) % samples;
		if (loop ? down[before] : (start > 0 && down[start - 1])) continue;
		usz length = 0;
		while (length < samples && down[(start + length) % samples]
			&& (loop || start + length < samples)) length++;
		if (length < 3) continue;
		if (every_run)
		{
			out.push({ .joint = joint.copy(mem) });
			contact_window_of(out.get_ref(out.len() - 1), start, length, span, loop);
			continue;
		}
		if (length > best) { best = length; best_start = start; }
	}
	if (every_run || best < 3) return;
	out.push({ .joint = joint.copy(mem) });
	contact_window_of(out.get_ref(out.len() - 1), best_start, best, span, loop);
}

// A run of `length` samples from `start` as a window in cycle phase.
fn void contact_window_of(AnimFoot* foot, usz start, usz length, float span, bool loop) @local
{
	float from = (float)start / span;
	float until = (float)(start + length) / span;
	if (until >= 1.0f && loop) until -= 1.0f;
	if (!loop) until = math::min(until, 1.0f);
	foot.down = from;
	foot.up = until;
}

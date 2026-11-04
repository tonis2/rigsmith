<* The pure half of src/app/contacts.c3: no state, undo or notices. *>
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
fn bool cyclic_overlap(float a, float a_span, float b, float b_span)
{
	if (a_span >= 1.0f || b_span >= 1.0f) return true;
	return phase_wrapped(b - a) < a_span - 1e-5f || phase_wrapped(a - b) < b_span - 1e-5f;
}

// The spec without window `window` and without every window of `joint`.
fn AnimGround ground_without(AnimGround ground, usz window, String joint)
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

<*
 How many lanes a ground spec draws: one per distinct contact joint.
*>
fn usz contact_lane_count(AnimGround ground)
{
	usz lanes = 0;
	foreach (usz i, foot : ground.feet) if (contact_first_of(ground, foot.joint) == i) lanes++;
	return lanes;
}

<*
 The runs of even samples a joint is down, as windows: every run of three
 samples or more with `every_run`, else the longest; down the whole time is one
 window over all of it. Pushed onto `out` under `joint`, copied.
*>
fn void push_runs(AnimFootList* out, String joint, bool[] down, bool loop, bool every_run)
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

<*
 Physics written down as keyframes.

 A jiggle is the one thing in crig that exists only while something is playing.
 `save_pack` writes keys, `export_rig` writes keys, and glTF has nowhere to put
 a solver — so a tail that swings beautifully in the viewport leaves the
 building as a tail that does not move at all. Baking is the answer, and it is
 not a compromise: recording what the simulation did is exactly how every engine
 consumes secondary motion as portable data.

 **The unit is the substep, not the frame.** `JiggleSim.step` advances 1/120 s
 against a palette the caller hands it, so a bake samples the source clip afresh
 at every one of them and never holds a target across a frame the way the
 viewport does. That is the one place the two differ, it is on the bake's side,
 and it is what makes the answer a property of the clip rather than of the
 machine that baked it.

 **A whole resample, because a partial one is not expressible.** `AnimTemplate.pose`
 reads a joint no keyframe mentions as being at rest, so a clip carrying only the
 dynamic joints would put every other joint back in the bind pose. What comes out
 is therefore the shape an import produces: every joint, every sample, with the
 ones that never leave rest culled by `ANIM_REST_EPSILON`.

 **Where the loop closes.** A looping clip is warmed up first — whole unrecorded
 turns of the cycle — and only then recorded, so the first key is not a chain
 hanging in its bind pose and the last is not still catching up. The first key is
 emitted *before* the recording pass steps anything and the last after a full
 cycle of it, which makes "t = 0 and t = duration agree" a real claim about a
 settled sim rather than an artefact of where the walk was cut.

 **Ground twice, carefully.** The sim is stepped against *grounded* poses, since
 that is where the figure actually is and gravity cares; the keys are written
 from the *ungrounded* one, since the baked clip carries the source's ground spec
 and would otherwise solve the root's height a second time. That is sound because
 `ground_pose` moves one root offset and nothing else, and every rotation this
 file computes is a difference of directions, which a translation does not touch.

 **Through the rig's limits, like the viewport.** Given the document and the
 build's dot ids, every sampled pose goes through `constrain_pose_to_joint_limits`
 before it is grounded or stepped against — the order `AppState.evaluated_clip_pose`
 plays it in — so a clip baked here is the clip that was watched, knee stops
 and all. Without them the source is taken as keyed, which is what a headless
 caller with no document wants.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::matrix;


import std::collections::list;

<*
 The sample rate a bake takes when none is asked for.

 Thirty is what animation is shipped at and what an eye reads as continuous; the
 solve underneath runs four times faster whatever this says, so the number here
 is the size of the file rather than the fidelity of the swing.
*>
const float BAKE_DEFAULT_HZ = 30.0f;

<*
 How many unrecorded turns of a looping cycle are run before recording starts.

 Two is enough for every parameter set in this file's own tests to come back
 under a thousandth of a unit of where it started, and cheap: a warm-up loop is
 the same 120 poses per second the recording pass takes.
*>
const usz BAKE_DEFAULT_SETTLE = 2;

// The slowest rate worth naming — one sample every ten seconds. Not a limit on
// anything real; a bound so a mistyped `hz` cannot ask for an array of samples
// the size of the clip in substeps.
const usz BAKE_MOST_SUBSTEPS @local = 1200;

// How far off the sample grid the end of a clip may sit and still be read as
// landing on it, as a fraction of one sample interval. A duration stated in
// seconds and a grid built out of 1/120 s floats disagree in the last bit or
// two, and without this every clip would gain a closing key a microsecond after
// its real last one.
const float BAKE_GRID_EPSILON @local = 1.0e-3f;

<*
 Raised when there is nothing dynamic to bake.
*>
faultdef BAKE_NOTHING_DYNAMIC;

<*
 Raised when the source clip has no keyframes or no length.
*>
faultdef BAKE_EMPTY_CLIP;

<*
 Run `source` through `sim` and write what came out as an ordinary clip.

 	`AnimTemplate baked = bake_physics_clip(mem, *source, &view.skeleton, view.names, &sim, "Tail baked")!;`

 The sim is stepped, not advanced: one 1/120 s substep per call with the source
 sampled again for each of them, which is what makes the result a function of
 the clip and the rig alone. It is left where the bake ended and is the caller's
 to free — build a private one for this rather than lending the viewport's,
 whose particles carry the display's history.

 **The sample grid.** `hz` is snapped to a whole number of substeps, so 30 is
 exactly 30 and 50 becomes 48; the actual rate is `120 / substeps_per_sample`.
 Samples run from 0 upward and the last one sits exactly on `duration`, which
 restates the opening pose on a looping clip and is the closing key
 `AnimTemplate.channel_span` already knows how to not count twice. The final interval
 is whatever is left over and is stepped in however many substeps come nearest
 to it — the one place a substep is not exactly 1/120 s of the clip.

 **Warm-up happens only on a looping clip.** A one-shot starts where its author
 said it starts, which is the rig at rest with the chain on its targets; there is
 no earlier motion for it to have arrived from and priming is the whole answer.

 The result is allocated from `allocator` with `owned` set; free it with
 `AnimTemplate.free`, or hand it to `AppState.put_authored_clip`. Nothing is
 allocated on the fault paths.

 @param names : `One name per joint, in joint order. An unnamed joint is one no clip can address, so it is not written out.`
 @param name : `The baked clip's name. Empty takes the source's with " baked" after it.`
 @param hz : `Samples per second, snapped to a divisor of 120.`
 @param settle_loops : `Unrecorded turns of the cycle before recording. Ignored for a clip that does not loop.`
 @param limits : `The document whose rotation limits every sampled pose is held inside, or null to take the clip as keyed.`
 @param dot_ids : `The dot each joint was built from, when limits is given — RigView.dot_ids.`
 @return? BAKE_NOTHING_DYNAMIC : `The sim has no chains, so a bake would only copy the clip.`
 @return? BAKE_EMPTY_CLIP : `The source has no keyframes or no duration.`
 @return? JIGGLE_POSE_MISMATCH : `The sim was built against a skeleton of another shape.`
*>
fn AnimTemplate? bake_physics_clip(
	Allocator allocator,
	AnimTemplate source,
	rig::Skeleton* skeleton,
	String[] names,
	JiggleSim* sim,
	String name,
	float hz = BAKE_DEFAULT_HZ,
	usz settle_loops = BAKE_DEFAULT_SETTLE,
	RigDocument* limits = null,
	uint[] dot_ids = {})
{
	if (sim == null || !sim.solves()) return BAKE_NOTHING_DYNAMIC~;
	if (source.keyframes.len == 0 || source.duration <= 0.0f) return BAKE_EMPTY_CLIP~;
	if (!sim.matches(skeleton)) return JIGGLE_POSE_MISMATCH~;

	usz per = bake_substeps_per_sample(hz);
	float span = JIGGLE_STEP * (float)per;

	// One key per whole interval, plus the opening one, plus a closing one when
	// the duration does not land on the grid. Two at the very least: a clip
	// shorter than one interval is still a clip with a start and an end.
	usz whole = (usz)math::floor(source.duration / span + BAKE_GRID_EPSILON);
	usz count = whole + 1;
	if (source.duration - (float)whole * span > span * BAKE_GRID_EPSILON) count++;
	if (count < 2) count = 2;

	float[] times = alloc::new_array(allocator, float, (sz)count);
	defer alloc::free(allocator, times);
	for (usz k = 0; k < count; k++) times[k] = (float)k * span;
	// Stated rather than computed, so the closing key is the duration itself and
	// a loop seam is exact instead of a float's width away from it.
	times[count - 1] = source.duration;

	BakeSampling sampling = { .source = source, .skeleton = skeleton, .names = names, .limits = limits, .dot_ids = dot_ids };

	bake_prime(allocator, sampling, sim, times[0]);

	if (source.loop)
	{
		for (usz loop = 0; loop < settle_loops; loop++)
		{
			for (usz k = 1; k < count; k++)
			{
				bake_interval(allocator, sampling, sim, times[k - 1], times[k]);
			}
		}
	}

	// Where this rig's bones point, recorded on every entry so replaying the
	// clip here needs no carry at all and replaying it elsewhere gets one.
	Vec3[] bones = skeleton.bone_directions(allocator);
	defer alloc::free(allocator, bones);

	// A flat rig has no length in it to state a slide as a fraction of, and a
	// clip's offsets are exactly that. One is the honest divisor: the numbers
	// then say model units, which is what a rig with no height leaves them as.
	float height = skeleton.height();
	if (height <= 0.0f) height = 1.0f;

	AnimKeyframe[] keyframes = alloc::new_array(allocator, AnimKeyframe, (sz)count);

	// The opening key comes off the settled state before the recording pass moves
	// anything, and the closing one after a whole cycle of it. That is what makes
	// them the same pose on a clip that loops.
	keyframes[0] = bake_keyframe(allocator, sampling, sim, times[0], bones, height);
	for (usz k = 1; k < count; k++)
	{
		bake_interval(allocator, sampling, sim, times[k - 1], times[k]);
		keyframes[k] = bake_keyframe(allocator, sampling, sim, times[k], bones, height);
	}

	return {
		.name = name.len > 0 ? name.copy(allocator) : string::format(allocator, "%s baked", source.name),
		.duration = source.duration,
		.keyframes = keyframes,
		.loop = source.loop,
		// Dense keys on a fixed grid: a cubic through them would fit a curve
		// through a curve that was already sampled, and overshoot where the
		// solver's own corrections are sharpest.
		.blend = LINEAR,
		.ground = ground_copy(allocator, source.ground),
		.owned = true,
	};
}

<*
 How many 1/120 s substeps one sample is worth.

 	`usz per = bake_substeps_per_sample(30.0f);  // 4`

 The snap is the whole of it: a rate that is not a divisor of 120 would put
 samples between substeps, and a sample the solver never stood on has to be
 interpolated from ones it did — which is the blur a bake exists to avoid.
 Report `120 / result` back to whoever asked for `hz`, not `hz` itself.
*>
fn usz bake_substeps_per_sample(float hz)
{
	if (!(hz > 0.0f)) hz = BAKE_DEFAULT_HZ;

	double steps = math::round(1.0 / ((double)JIGGLE_STEP * (double)hz));
	if (steps < 1.0) return 1;
	if (steps > (double)BAKE_MOST_SUBSTEPS) return BAKE_MOST_SUBSTEPS;
	return (usz)steps;
}

<*
 The rate a bake actually sampled at, given what it was asked for.

 Two whole numbers divided, not the reciprocal of a float product: a caller told
 it got 59.999996 samples a second learns nothing it did not already suspect.
*>
fn float bake_sample_rate(float hz)
{
	double substeps = math::round(1.0 / (double)JIGGLE_STEP);
	return (float)(substeps / (double)bake_substeps_per_sample(hz));
}

// Put every particle where the animation says its joint is at `time`, standing
// still. The grounded pose, like every other step here: the figure's real
// height off the floor is where gravity acts on it.
// What every sample is taken from: the clip, the rig it is sampled onto, and
// the limits it is held inside on the way.
struct BakeSampling @local
{
	AnimTemplate source;
	rig::Skeleton* skeleton;
	String[] names;
	RigDocument* limits;
	uint[] dot_ids;
}

// The clip at `time` as the viewport would show it before the sim: sampled,
// held inside the rig's limits, and then — when asked — put on the floor.
fn rig::Pose bake_sample(Allocator allocator, BakeSampling sampling, float time, bool grounded) @local
{
	rig::Pose pose = sampling.source.pose(allocator, sampling.skeleton, sampling.names, time, false);
	if (sampling.limits)
	{
		constrain_pose_to_joint_limits(sampling.limits, sampling.skeleton, sampling.dot_ids, &pose);
	}
	if (grounded)
	{
		ground_pose(allocator, sampling.skeleton, sampling.names, sampling.source.ground, &pose,
			sampling.source.phase_at(time));
	}
	return pose;
}

fn void bake_prime(
	Allocator allocator,
	BakeSampling sampling,
	JiggleSim* sim,
	float time) @local
{
	rig::Pose pose = bake_sample(allocator, sampling, time, true);
	defer pose.free(allocator);

	Matrix4f[]? built = rig::joint_palette(allocator, sampling.skeleton, pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(allocator, palette);

	sim.prime(palette);
}

// Step from one sample time to the next, sampling the clip afresh for every
// substep on the way.
//
// The count is however many substeps come nearest to the gap, so a whole
// interval is exactly `substeps_per_sample` of them and the leftover one at the
// end of a clip is whatever fits — never none, because a sample the sim did not
// step to is the previous sample written twice.
fn void bake_interval(
	Allocator allocator,
	BakeSampling sampling,
	JiggleSim* sim,
	float from,
	float to) @local
{
	usz steps = bake_steps_between(from, to);
	for (usz i = 1; i <= steps; i++)
	{
		float at = from + (to - from) * ((float)i / (float)steps);

		rig::Pose pose = bake_sample(allocator, sampling, at, true);
		defer pose.free(allocator);

		Matrix4f[]? built = rig::joint_palette(allocator, sampling.skeleton, pose);
		if (catch built) continue;
		Matrix4f[] palette = built;
		defer alloc::free(allocator, palette);

		sim.step(palette);
	}
}

<*
 How many substeps a gap between two sample times is worth. At least one.
*>
fn usz bake_steps_between(float from, float to) @local
{
	double steps = math::round((double)(to - from) / (double)JIGGLE_STEP);
	if (steps < 1.0) return 1;
	if (steps > (double)BAKE_MOST_SUBSTEPS) return BAKE_MOST_SUBSTEPS;
	return (usz)steps;
}

<*
 One sample: the clip as authored at `time`, with the simulation folded into it,
 written out as a keyframe.

 The ungrounded pose, and only here — see the file's note. `write_pose` reads
 the targets the last substep aimed at, so this must be called against the same
 instant that substep was stepped to, which is what the walk above arranges.
*>
fn AnimKeyframe bake_keyframe(
	Allocator allocator,
	BakeSampling sampling,
	JiggleSim* sim,
	float time,
	Vec3[] bones,
	float height) @local
{
	rig::Pose pose = bake_sample(allocator, sampling, time, false);
	defer pose.free(allocator);

	// A refusal is a sim and a skeleton that stopped agreeing about their shape,
	// which cannot happen between the check at the top and here. Were it to, the
	// key written is the clip without physics rather than no key at all — a
	// keyframe array with a hole in it is not a clip.
	if (catch sim.write_pose(allocator, sampling.skeleton, &pose)) {}

	// The conversion itself is `anim/keying.c3`, shared with the timeline's Key
	// button — so a pose baked from the simulation and the same pose keyed by
	// hand produce identical entries. What is left here is the two lines above:
	// sampling the source ungrounded, and folding the sim into what it gave.
	return keyframe_of_pose(allocator, pose, sampling.names, bones, height, time);
}


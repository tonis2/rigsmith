<*
 Baking, offline and with no window.

     `c3c test --trust=full --test-filter crig_tests::bake`

 The same three-bone tail `jiggle_test.c3` swings, on the same skeleton, with a
 clip over it that turns the body the tail hangs off — so the tail is dragged
 round, lags, and comes back. Two claims, and they are the two a bake is for:

 replay   the baked clip, sampled at its own keyframe times and posed on this
          rig, puts each chain joint where the simulation had its particle. Not
          approximately: LINEAR interpolation is exact *at* a key, and every
          entry records this rig's own bone, so the replay needs no carry.
 closure  a looping clip settled first gives the same pose at t = 0 and at
          t = duration. That is what the warm-up loops buy, and without it every
          baked cycle would jump at the seam.

 The replay check runs its own reference simulation rather than reading one out
 of the bake, and walks it by the bake's own rule — however many 1/120 s
 substeps fit between two sample times, with the clip sampled afresh for each.
 Restating the rule is the point: it is what pins the emission convention, since
 a bake that recorded its first key *after* stepping would come out shifted by a
 whole sample and match nothing here.
*>
module crig_tests::bake;

import crig;
import rig;
import crig_tests::jiggle;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;



// One name per joint of `jiggle::tail_skeleton`, in joint order. A clip
// addresses joints by name and an unnamed one is a joint no bake writes out, so
// every one of them has to carry one here.
String[6] tail_names = { "body", "tail1", "tail2", "tail3", "bar", "bar_tip" };

// What the tail is worth simulating with: stiff enough to follow the body round,
// slack enough to arrive late, and heavy enough for gravity to show.
const crig::JiggleParams SWINGING = {
	.stiffness = 900.0f,
	.damping = 0.4f,
	.gravity = 1.0f,
	.radius = 0.0f,
};

<*
 A body that turns once about Y and comes back, a second long and looping.

 The tail is not keyed at all — it is the thing being dragged — so everything
 the baked clip says about it came out of the solver, which is what makes the
 replay check a check on the bake rather than on the sampler.

 Allocated from `mem` with `owned` set; free it with `AnimTemplate.free`.
*>
fn crig::AnimTemplate swing_clip(float angle = 0.8f)
{
	crig::AnimKeyDot[] turned = alloc::new_array(mem, crig::AnimKeyDot, 1);
	turned[0] = {
		.joint_name = "body".copy(mem),
		.axis = { 0, 1, 0 },
		.angle = angle,
		.move = { 0, 0, 0 },
		.bone = { 0, 0, 0 },
	};

	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, 3);
	keys[0] = { .time = 0.0f, .dots = {} };
	keys[1] = { .time = 0.5f, .dots = turned };
	keys[2] = { .time = 1.0f, .dots = {} };
	for (usz i = 0; i < 3; i += 2)
	{
		keys[i].dots = alloc::new_array(mem, crig::AnimKeyDot, 1);
		keys[i].dots[0] = { .joint_name = "body".copy(mem), .axis = { 0, 1, 0 } };
	}

	return {
		.name = "swing".copy(mem),
		.duration = 1.0f,
		.keyframes = keys,
		.loop = true,
		.blend = crig::AnimBlend.LINEAR,
		.owned = true,
	};
}

// Put every particle where the clip says its joint is at `time`, standing still
// — `bake_physics_clip`'s own opening move.
fn void prime_at(crig::JiggleSim* sim, crig::AnimTemplate source, rig::Skeleton* skeleton, float time)
{
	rig::Pose pose = source.pose(mem, skeleton, tail_names[..], time, true);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);
	sim.prime(palette);
}

<*
 The bake's substep rule, restated: between two sample times, however many
 1/120 s substeps come nearest to the gap, and the clip sampled again for every
 one of them.

 Against the *grounded* pose, like the bake — this clip has no ground spec, so
 the two are the same pose here, and saying which one is meant costs nothing.
*>
fn void step_between(
	crig::JiggleSim* sim,
	crig::AnimTemplate source,
	rig::Skeleton* skeleton,
	float from,
	float to)
{
	double fitted = math::round((double)(to - from) / (double)crig::JIGGLE_STEP);
	usz steps = fitted < 1.0 ? 1 : (usz)fitted;

	for (usz i = 1; i <= steps; i++)
	{
		float at = from + (to - from) * ((float)i / (float)steps);

		rig::Pose pose = source.pose(mem, skeleton, tail_names[..], at, true);
		defer pose.free(mem);
		Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
		defer alloc::free(mem, palette);

		sim.step(palette);
	}
}

// Where the baked clip puts every joint at `time`, as a palette. Ungrounded,
// which is how the keys were written.
fn Matrix4f[] baked_palette(crig::AnimTemplate baked, rig::Skeleton* skeleton, float time)
{
	rig::Pose pose = baked.pose(mem, skeleton, tail_names[..], time, false);
	defer pose.free(mem);
	return rig::joint_palette(mem, skeleton, pose)!!;
}

<*
 The baked clip replays the simulation, sample for sample.

 The load-bearing claim of the whole milestone. A bake that is merely close
 produces an animation that is nearly the one that was watched — the failure
 nobody sees until the exported file is compared against the viewport frame by
 frame — so this is asserted at every sample of a whole cycle rather than at the
 end of one.
*>
fn void the_baked_clip_replays_the_simulation() @test
{
	rig::Skeleton skeleton = jiggle::tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::AnimTemplate source = swing_clip();
	defer source.free(mem);

	crig::JiggleSim sim = jiggle::tail_sim(&skeleton, SWINGING);
	defer sim.free(mem);

	crig::AnimTemplate baked = crig::bake_physics_clip(
		mem, source, &skeleton, tail_names[..], &sim, "swing baked", 30.0f, 2)!!;
	defer baked.free(mem);

	test::@check(baked.keyframes.len == 31 && baked.loop && baked.duration == source.duration,
		"a second at thirty samples is thirty keys and the one that closes the loop (%d)", baked.keyframes.len);

	// The reference the baked clip is measured against: the same sim, primed the
	// same way, settled for the same two loops, and then walked one sample at a
	// time alongside the replay.
	crig::JiggleSim reference = jiggle::tail_sim(&skeleton, SWINGING);
	defer reference.free(mem);

	usz keys = baked.keyframes.len;
	prime_at(&reference, source, &skeleton, baked.keyframes[0].time);
	for (usz loop = 0; loop < 2; loop++)
	{
		for (usz k = 1; k < keys; k++)
		{
			step_between(&reference, source, &skeleton, baked.keyframes[k - 1].time, baked.keyframes[k].time);
		}
	}

	Vec3[] tails = skeleton.tails(mem);
	defer alloc::free(mem, tails);

	crig::JiggleChain* chain = &reference.chains[0];
	usz last = chain.joints[chain.joints.len - 1];

	float worst = 0.0f;
	float lag = 0.0f;

	for (usz k = 0; k < keys; k++)
	{
		if (k > 0)
		{
			step_between(&reference, source, &skeleton, baked.keyframes[k - 1].time, baked.keyframes[k].time);
		}

		float time = baked.keyframes[k].time;

		Matrix4f[] replayed = baked_palette(baked, &skeleton, time);
		defer alloc::free(mem, replayed);

		foreach (usz i, joint : chain.joints)
		{
			Vec3 want = chain.body.positions[(sz)i];
			Vec3 got = jiggle::carried(replayed[joint], skeleton.joints[joint]);
			worst = math::max(worst, (got - want).length());
		}

		Vec3 want_tip = chain.body.positions[(sz)chain.joints.len];
		Vec3 got_tip = jiggle::carried(replayed[last], tails[last]);
		worst = math::max(worst, (got_tip - want_tip).length());

		// Vacuous unless the physics did something the clip did not: the tail is
		// keyed by nothing, so every millimetre between the two came from the
		// solver.
		Matrix4f[] keyed = baked_palette(source, &skeleton, time);
		defer alloc::free(mem, keyed);
		lag = math::max(lag, (jiggle::carried(keyed[last], tails[last]) - got_tip).length());
	}

	test::@check(lag > 0.02f, "the tail never left the keyed pose (%.5f); the check proves nothing", lag);
	test::@check(worst < 1.0e-3f, "a baked sample landed %.6f from the particle it was recorded off", worst);
}

<*
 A settled loop comes back to where it started.

 Without the warm-up the first key is a chain hanging in its bind pose and the
 last is one that has been swinging for a cycle, and a clip that jumps at the
 seam is the one thing a looping bake must never produce. Two loops is the
 default because it is what makes this claim true.
*>
fn void a_baked_loop_closes_on_itself() @test
{
	rig::Skeleton skeleton = jiggle::tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::AnimTemplate source = swing_clip();
	defer source.free(mem);

	crig::JiggleSim sim = jiggle::tail_sim(&skeleton, SWINGING);
	defer sim.free(mem);

	crig::AnimTemplate baked = crig::bake_physics_clip(
		mem, source, &skeleton, tail_names[..], &sim, "swing baked", 30.0f, 2)!!;
	defer baked.free(mem);

	Matrix4f[] opening = baked_palette(baked, &skeleton, 0.0f);
	defer alloc::free(mem, opening);
	Matrix4f[] closing = baked_palette(baked, &skeleton, baked.duration);
	defer alloc::free(mem, closing);
	Matrix4f[] middle = baked_palette(baked, &skeleton, baked.duration * 0.25f);
	defer alloc::free(mem, middle);

	Vec3[] tails = skeleton.tails(mem);
	defer alloc::free(mem, tails);

	float seam = 0.0f;
	float swing = 0.0f;
	for (usz j = 0; j < skeleton.len(); j++)
	{
		Vec3 rest = skeleton.joints[j];
		Vec3 first = jiggle::carried(opening[j], rest);
		seam = math::max(seam, (jiggle::carried(closing[j], rest) - first).length());
		swing = math::max(swing, (jiggle::carried(middle[j], rest) - first).length());
	}

	// The tip as well as the joints: it is the end of the chain the seam would
	// show at first, and no joint sits on it.
	Vec3 tip = jiggle::carried(opening[3], tails[3]);
	seam = math::max(seam, (jiggle::carried(closing[3], tails[3]) - tip).length());
	swing = math::max(swing, (jiggle::carried(middle[3], tails[3]) - tip).length());

	test::@check(swing > 0.05f, "the clip barely moves (%.5f); a seam in it would prove nothing", swing);
	test::@check(seam < 2.0e-3f, "the loop jumps %.6f between its last key and its first", seam);
}

<*
 A bake with nothing dynamic, and one with nothing to bake, are refused rather
 than answered with a copy.

 Both are the caller having asked for something that cannot mean what they think
 it means: a rig with no dynamic bones would produce the source clip resampled,
 and a clip with no length has no stretch of time to simulate over.
*>
fn void a_bake_refuses_what_it_cannot_record() @test
{
	rig::Skeleton skeleton = jiggle::tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::AnimTemplate source = swing_clip();
	defer source.free(mem);

	crig::JiggleSim idle = crig::build_jiggle_sim(mem, &skeleton, {})!!;
	defer idle.free(mem);
	if (catch excuse = crig::bake_physics_clip(mem, source, &skeleton, tail_names[..], &idle, ""))
	{
		test::@check(excuse == crig::BAKE_NOTHING_DYNAMIC, "a sim with no chains refuses by name");
	}
	else
	{
		test::@check(false, "a sim with no chains is refused");
	}

	crig::JiggleSim sim = jiggle::tail_sim(&skeleton, SWINGING);
	defer sim.free(mem);

	crig::AnimTemplate empty = { .name = "nothing", .duration = 1.0f };
	if (catch excuse = crig::bake_physics_clip(mem, empty, &skeleton, tail_names[..], &sim, ""))
	{
		test::@check(excuse == crig::BAKE_EMPTY_CLIP, "a clip with no keyframes refuses by name");
	}
	else
	{
		test::@check(false, "a clip with no keyframes is refused");
	}
}

<*
 An unnamed bake takes the source's name, and the ground spec comes with it.

 The ground solve is the one part of a clip that is re-solved against whichever
 rig it is played on, so a baked clip that lost it would plant its feet where the
 authoring rig's legs happened to reach.
*>
fn void a_bake_keeps_the_name_and_the_footing() @test
{
	rig::Skeleton skeleton = jiggle::tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::AnimTemplate source = swing_clip();
	defer source.free(mem);

	crig::AnimFoot[] feet = alloc::new_array(mem, crig::AnimFoot, 1);
	feet[0] = { .joint = "tail3".copy(mem), .down = 0.1f, .up = 0.6f };
	source.ground = { .feet = feet, .floor = 0.25f, .floor_set = true };

	crig::JiggleSim sim = jiggle::tail_sim(&skeleton, SWINGING);
	defer sim.free(mem);

	crig::AnimTemplate baked = crig::bake_physics_clip(
		mem, source, &skeleton, tail_names[..], &sim, "")!!;
	defer baked.free(mem);

	test::@check(baked.name == "swing baked", `an unnamed bake is the source "baked" (%s)`, baked.name);
	test::@check(baked.blend == crig::AnimBlend.LINEAR, "and is linear, because its keys are already a sampling");
	test::@check(baked.ground.feet.len == 1
		&& baked.ground.feet[0].joint == "tail3"
		&& baked.ground.feet[0].joint.ptr != source.ground.feet[0].joint.ptr
		&& baked.ground.floor == 0.25f
		&& baked.ground.floor_set,
		"and carries a copy of the ground spec rather than a borrow of it");
}

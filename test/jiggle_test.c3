<*
 Jiggle bones, offline and with no window.

     `c3c test --trust=full --test-filter crig_tests::jiggle`

 The fixture is a three-bone tail sticking sideways out of a body, with a bar
 slung underneath it to be collided with. Sideways rather than downward on
 purpose: a chain hanging along gravity is at equilibrium and proves nothing,
 and a chain standing against it is balanced on a point. Sideways falls.

 Nine claims, and they divide into three kinds. Two are about the solver being
 the solver — the same inputs give the same answer, and a chain already where it
 is asked to be does not drift. Five are about the parameters meaning what the
 doc comment says they mean: a spring settles, gravity swings, a capsule pushes,
 a probed surface holds a chain off, a joint's own limit table holds. The last
 two are the ones the rest of the feature rests on: the simulated points,
 converted into pose rotations and fed back through `joint_palette`, land where
 the particles were — limited or not. Anything less than that and a bake writes
 a different animation from the one that was watched.
*>
module crig_tests::jiggle;

import crig;
import rig;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;



// The bar under the tail, and how fat the tail's own particles are.
const float BAR_RADIUS = 0.15f;
const float PARTICLE_RADIUS = 0.03f;
// Radius plus radius: how far a particle's centre has to stay off the bar.
const float CLEARANCE = BAR_RADIUS + PARTICLE_RADIUS;

// The dynamic run, and the collider's joint.
const usz TAIL_ROOT = 1;
const usz TAIL_MID = 2;
const usz TAIL_TIP = 3;
const usz BAR = 4;

<*
 A body joint with a three-bone tail off it, and a bar hung below.

     0   the body, at the origin of the tail
     1   2   3   the tail, straight out along +X, 0.3 + 0.3 long
     4   5       the bar, running along Z under the body

 The tail's last bone has no child, so `Skeleton.tails` extrudes it half a
 length to `{0.95, 1, 0}` — that is the tip particle. The bar's first joint has
 exactly one child, so its own tail is that child and the capsule is the segment
 between them.
*>
fn rig::Skeleton tail_skeleton(Allocator allocator)
{
	Vec3[] joints = alloc::new_array(allocator, Vec3, 6);
	int[] parents = alloc::new_array(allocator, int, 6);

	joints[0] = { 0.0f, 1.0f, 0.0f };    parents[0] = -1;  // body
	joints[1] = { 0.2f, 1.0f, 0.0f };    parents[1] = 0;   // tail root, pinned
	joints[2] = { 0.5f, 1.0f, 0.0f };    parents[2] = 1;
	joints[3] = { 0.8f, 1.0f, 0.0f };    parents[3] = 2;
	joints[4] = { 0.2f, 0.55f, -0.4f };  parents[4] = 0;   // bar, one end
	joints[5] = { 0.2f, 0.55f, 0.4f };   parents[5] = 4;   // and the other

	return { .joints = joints, .parents = parents };
}

// The tail's joints, in run order. Written out rather than derived, so a test
// says which bones it is talking about.
fn usz[3] tail_run() => { TAIL_ROOT, TAIL_MID, TAIL_TIP };

<*
 Build a sim over the whole tail with one set of params on every bone.

 @param colliders : `Passed straight through; an empty one is a sim with nothing to hit.`
 @param limits : `One per tail bone, or empty for a chain whose joints carry none.`
*>
fn crig::JiggleSim tail_sim(
	rig::Skeleton* skeleton,
	crig::JiggleParams params,
	crig::JiggleColliderSpec[] colliders = {},
	crig::JiggleLimit[] limits = {})
{
	usz[3] joints = tail_run();
	crig::JiggleParams[3] each = { params, params, params };
	crig::JiggleChainSpec[1] chains = { { .joints = joints[..], .params = each[..], .limits = limits } };

	return crig::build_jiggle_sim(mem, skeleton, chains[..], colliders)!!;
}

// The same table on every tail bone: X and Z allowed within `half` either
// way, Y free — a bone that may swing but not far. Frames derived by index,
// the way a caller with no dot ids gets them; a tail bone has one child or
// none, so every frame resolves.
fn crig::JiggleLimit[3] swing_limits(rig::Skeleton* skeleton, float half)
{
	crig::JiggleLimit[3] out;
	usz[3] joints = tail_run();
	foreach (usz i, joint : joints)
	{
		crig::JointRotationLimits table = crig::unconstrained_rotation((uint)joint + 1);
		table.constrained = true;
		table.axes[0] = { .allowed = true, .minimum = -half, .maximum = half, .locked = 0.0f };
		table.axes[2] = { .allowed = true, .minimum = -half, .maximum = half, .locked = 0.0f };
		out[i] = { .table = table, .frame = crig::joint_limit_frame_by_index(skeleton, joint) };
	}
	return out;
}

// A floor for the tail to be held off: everything below `height` is body.
struct Floor
{
	float height;
	usz asked;
}

fn void floor_aim(void* context, Matrix4f[] palette) => (void)context;

fn bool floor_probe(void* context, Vec3 point, float radius, crig::JiggleContact* out)
{
	Floor* floor = (Floor*)context;
	floor.asked++;
	if (point.y - floor.height >= radius) return false;
	*out = { .point = { point.x, floor.height, point.z }, .normal = { 0, 1, 0 } };
	return true;
}

// The palette of a pose, and the pose of a skeleton at rest. Both allocated
// from `mem`; both freed by the caller.
fn Matrix4f[] palette_of(rig::Skeleton* skeleton, rig::Pose pose)
{
	return rig::joint_palette(mem, skeleton, pose)!!;
}

// Where a palette entry carries a rest-space point — the arithmetic every
// posed-position claim in crig is stated in.
fn Vec3 carried(Matrix4f entry, Vec3 rest)
{
	float[<4>] moved = entry.apply({ rest.x, rest.y, rest.z, 1.0f });
	return { moved.x, moved.y, moved.z };
}

// The angle between two directions, in radians. atan2 of the cross and the dot,
// so it stays accurate for the small angles a cone limit is made of.
fn float angle_between(Vec3 a, Vec3 b)
{
	if (a.length_sq() < 1.0e-18f || b.length_sq() < 1.0e-18f) return 0.0f;
	Vec3 x = a.normalize();
	Vec3 y = b.normalize();
	return math::atan2(x.cross(y).length(), x.dot(y));
}

// Distance from a point to a segment — the bar, measured the way the collider
// measures it.
fn float distance_to_segment(Vec3 p, Vec3 a, Vec3 b)
{
	Vec3 ab = b - a;
	float ab_sq = ab.dot(ab);
	if (ab_sq < 1.0e-18f) return (p - a).length();
	float t = math::clamp((p - a).dot(ab) / ab_sq, 0.0f, 1.0f);
	return (p - (a + ab * t)).length();
}

// Whether two positions are the same bits, not merely the same number. What
// determinism means: a bake replays the viewport, so "close enough" is not.
fn bool same_bits(Vec3 a, Vec3 b)
{
	return bitcast(a.x, uint) == bitcast(b.x, uint)
		&& bitcast(a.y, uint) == bitcast(b.y, uint)
		&& bitcast(a.z, uint) == bitcast(b.z, uint);
}

<*
 The same inputs give the same particles, to the bit, after five hundred
 substeps of a moving pose.

 A bake is only worth having if it reproduces what the viewport showed, and the
 viewport and the bake are two runs of this code over the same clip. Bitwise
 rather than approximate, because a drift of one ulp per substep is a different
 animation by the end of a long tail and no tolerance catches it early.
*>
fn void two_identical_sims_stay_identical() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::JiggleParams params = { .stiffness = 900.0f, .damping = 0.4f, .gravity = 1.0f, .radius = PARTICLE_RADIUS };

	crig::JiggleSim left = tail_sim(&skeleton, params);
	defer left.free(mem);
	crig::JiggleSim right = tail_sim(&skeleton, params);
	defer right.free(mem);

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);

	for (usz k = 0; k < 500; k++)
	{
		pose.turn(0, { 0, 1, 0 }, 0.6f * math::sin((float)k * 0.05f));
		pose.turn(TAIL_ROOT, { 0, 0, 1 }, 0.4f * math::sin((float)k * 0.031f));

		Matrix4f[] palette = palette_of(&skeleton, pose);
		left.step(palette);
		right.step(palette);
		alloc::free(mem, palette);
	}

	for (sz i = 0; i < left.chains[0].body.positions.len(); i++)
	{
		Vec3 a = left.chains[0].body.positions[i];
		Vec3 b = right.chains[0].body.positions[i];
		test::@check(same_bits(a, b), "particle %d diverged: %s vs %s", i, a, b);
	}
}

<*
 A chain already standing where the animation asks it to stand does not move.

 The cheapest statement that nothing in the wiring is fighting itself: the pin,
 the targets, the cone axes and the distance constraints all come out of the
 same palette, so at rest every one of them is already satisfied and the whole
 solve has to be a no-op. Anything that drifts here injects energy that no
 amount of damping is owed to remove.
*>
fn void a_rested_chain_never_stirs() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::JiggleLimit[3] limits = swing_limits(&skeleton, 0.3f);
	crig::JiggleSim sim = tail_sim(&skeleton, {
		.stiffness = 3000.0f, .damping = 0.9f, .gravity = 0.0f, .radius = PARTICLE_RADIUS }, {}, limits[..]);
	defer sim.free(mem);

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	Matrix4f[] palette = palette_of(&skeleton, pose);
	defer alloc::free(mem, palette);

	sim.prime(palette);

	Vec3[4] started;
	for (sz i = 0; i < 4; i++) started[i] = sim.chains[0].body.positions[i];

	for (usz k = 0; k < 300; k++) sim.step(palette);

	for (sz i = 0; i < 4; i++)
	{
		Vec3 now = sim.chains[0].body.positions[i];
		test::@check(same_bits(started[i], now), "particle %d drifted from %s to %s", i, started[i], now);
	}
}

<*
 A spring pulls the chain onto the pose the animation is holding.

 Stiffness is the whole of "follow the animation", and a chain that never
 arrives is a chain that lags forever — the tail of a character standing still
 would hang at an angle. Primed at rest and then handed a bent pose, so the
 particles have somewhere to travel to.
*>
fn void a_stiff_chain_settles_onto_its_targets() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::JiggleSim sim = tail_sim(&skeleton, {
		.stiffness = 4000.0f, .damping = 0.3f, .gravity = 0.0f, .radius = 0.0f });
	defer sim.free(mem);

	rig::Pose rest = rig::rest_pose(mem, skeleton.len());
	defer rest.free(mem);
	Matrix4f[] at_rest = palette_of(&skeleton, rest);
	defer alloc::free(mem, at_rest);

	rig::Pose bent = rig::rest_pose(mem, skeleton.len());
	defer bent.free(mem);
	bent.turn(TAIL_ROOT, { 0, 0, 1 }, -0.9f);
	bent.turn(TAIL_MID, { 0, 0, 1 }, 0.5f);
	Matrix4f[] posed = palette_of(&skeleton, bent);
	defer alloc::free(mem, posed);

	sim.prime(at_rest);
	for (usz k = 0; k < 1200; k++) sim.step(posed);

	crig::JiggleChain* chain = &sim.chains[0];
	for (sz i = 0; i < chain.body.positions.len(); i++)
	{
		float gap = (chain.body.positions[i] - chain.animated[i]).length();
		test::@check(gap < 1.0e-3f, "particle %d settled %.6f from its target", i, gap);
	}
}

<*
 With nothing pulling it back, a tail sticking sideways falls until it hangs,
 and never stretches on the way.

 Two claims in one run because they are the same claim from either end: gravity
 has to reach the particles at all, and the links between them have to hold
 while it does. A chain that arrives vertical having grown a centimetre has not
 simulated a tail, it has simulated a rubber band.
*>
fn void a_free_chain_falls_to_vertical_without_stretching() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::JiggleSim sim = tail_sim(&skeleton, {
		.stiffness = 0.0f, .damping = 0.02f, .gravity = 1.0f, .radius = 0.0f });
	defer sim.free(mem);

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	Matrix4f[] palette = palette_of(&skeleton, pose);
	defer alloc::free(mem, palette);

	crig::JiggleChain* chain = &sim.chains[0];

	float[3] rest_length;
	sim.prime(palette);
	for (sz i = 0; i < 3; i++)
	{
		rest_length[i] = (chain.rest[i + 1] - chain.rest[i]).length();
	}

	float worst_stretch = 0.0f;
	for (usz k = 0; k < 3000; k++)
	{
		sim.step(palette);
		for (sz i = 0; i < 3; i++)
		{
			float now = (chain.body.positions[i + 1] - chain.body.positions[i]).length();
			worst_stretch = math::max(worst_stretch, math::abs(now - rest_length[i]));
		}
	}

	test::@check(worst_stretch < 1.0e-4f, "a bone stretched by %.7f while it fell", worst_stretch);

	for (sz i = 0; i < 3; i++)
	{
		Vec3 bone = chain.body.positions[i + 1] - chain.body.positions[i];
		float off = angle_between(bone, { 0, -1, 0 });
		test::@check(off < 0.01f, "bone %d hangs %.5f rad off vertical", i, off);
	}
}

<*
 A capsule between a particle and where the animation wants it keeps the
 particle out.

 The pose is chosen so the targets are inside the bar: the tail is swung
 straight down through it, and a spring is all that acts. Without the collider
 the particles would sit on those targets, which the first check states as a
 fact about the fixture rather than as a hope. With it they come to rest on the
 surface, pressed against it, since nothing else is holding them off.

 Damping is zero — every substep starts from rest — so the approach is pure
 relaxation rather than a swing, and the surface is arrived at rather than
 collided with. That is on purpose: this is a check on the *pushout*, and a
 fast-moving particle would instead be a check on how deep discrete contact
 lets something get before it notices.
*>
fn void a_capsule_keeps_particles_off_it() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	crig::JiggleColliderSpec[1] bar = { { .joint = BAR, .radius = BAR_RADIUS } };
	crig::JiggleSim sim = tail_sim(&skeleton, {
		.stiffness = 100.0f, .damping = 0.0f, .gravity = 0.0f, .radius = PARTICLE_RADIUS },
		bar[..]);
	defer sim.free(mem);

	rig::Pose rest = rig::rest_pose(mem, skeleton.len());
	defer rest.free(mem);
	Matrix4f[] at_rest = palette_of(&skeleton, rest);
	defer alloc::free(mem, at_rest);

	rig::Pose down = rig::rest_pose(mem, skeleton.len());
	defer down.free(mem);
	down.turn(TAIL_ROOT, { 0, 0, 1 }, -(float)math::PI * 0.5f);
	Matrix4f[] hanging = palette_of(&skeleton, down);
	defer alloc::free(mem, hanging);

	Vec3 bar_a = carried(hanging[BAR], skeleton.joints[BAR]);
	Vec3 bar_b = carried(hanging[BAR], skeleton.joints[5]);

	sim.prime(at_rest);
	crig::JiggleChain* chain = &sim.chains[0];

	// The fixture has to be a trap or the check below is vacuous: at least one
	// target must be inside the capsule the particle is being pulled through.
	sim.step(hanging);
	float deepest_target = 0.0f;
	for (sz i = 1; i < chain.body.positions.len(); i++)
	{
		float gap = distance_to_segment(chain.animated[i], bar_a, bar_b);
		deepest_target = math::max(deepest_target, CLEARANCE - gap);
	}
	test::@check(deepest_target > 0.01f, "no target is inside the bar; the collider is not being asked anything");

	float worst = 0.0f;
	for (usz k = 0; k < 4000; k++)
	{
		sim.step(hanging);
		for (sz i = 1; i < chain.body.positions.len(); i++)
		{
			float gap = distance_to_segment(chain.body.positions[i], bar_a, bar_b);
			worst = math::max(worst, CLEARANCE - gap);
		}
	}
	// Contacts are found from the position at the top of a substep, so a particle
	// being pulled into a surface dips one substep's worth of approach past it
	// before the constraint that exists to stop it is generated. At this
	// stiffness that is about half a thousandth of a unit; the bound is stated
	// well above the measurement and well below the radius it is protecting.
	test::@check(worst < 2.0e-3f, "a particle sank %.5f into the bar in passing", worst);

	float settled = 0.0f;
	float touching = 1.0e9f;
	for (sz i = 1; i < chain.body.positions.len(); i++)
	{
		float gap = distance_to_segment(chain.body.positions[i], bar_a, bar_b);
		settled = math::max(settled, CLEARANCE - gap);
		touching = math::min(touching, gap);
	}
	test::@check(settled < 1.0e-4f, "a particle rests %.7f inside the bar", settled);
	test::@check(touching < CLEARANCE + 1.0e-3f, "nothing came to rest on the bar; nearest is %.5f away", touching);
}

<*
 A joint's own limit table holds however hard gravity leans on it.

 The tail sticks out sideways and gravity pulls square across it, which is the
 worst case for a limit: the whole of the force is trying to open the angle.
 A fifth of a radian on the table's swing axes, read off every bone's written
 rotation every substep rather than at the end, because a limit that is
 briefly exceeded and then recovered is a limit that pops on screen — and
 read the way the Joint card reads it, as bone-local angles, since the table
 is stated in those and not in a cone about the animated direction.

 The particles have to agree with the rotations, too: a rotation clamped on
 paper while the points went on falling would bake one tail and show another.
*>
fn void a_joint_limit_is_never_exceeded() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	const float LIMIT = 0.2f;
	crig::JiggleLimit[3] limits = swing_limits(&skeleton, LIMIT);
	crig::JiggleSim sim = tail_sim(&skeleton, {
		.stiffness = 0.0f, .damping = 0.5f, .gravity = 1.0f, .radius = 0.0f }, {}, limits[..]);
	defer sim.free(mem);

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	Matrix4f[] palette = palette_of(&skeleton, pose);
	defer alloc::free(mem, palette);

	sim.prime(palette);
	crig::JiggleChain* chain = &sim.chains[0];

	float worst = 0.0f;
	float reached = 0.0f;
	float apart = 0.0f;
	for (usz k = 0; k < 1500; k++)
	{
		sim.step(palette);
		for (usz i = 0; i < 3; i++)
		{
			Vec3 angles = crig::joint_angles_from_rotation(limits[i].frame, chain.rotations[i]);
			float swing = math::max(math::abs(angles.x), math::abs(angles.z));
			worst = math::max(worst, swing);
			reached = math::max(reached, swing);
		}

		// The rotations, fed back through the palette, put the joints on the
		// particles: what the pose says and what the points say are one tail.
		rig::Pose written = rig::rest_pose(mem, skeleton.len());
		sim.write_pose(mem, &skeleton, &written)!!;
		Matrix4f[] posed = rig::joint_palette(mem, &skeleton, written)!!;
		for (usz i = 1; i < 3; i++)
		{
			Vec3 got = carried(posed[chain.joints[i]], skeleton.joints[chain.joints[i]]);
			apart = math::max(apart, (got - chain.body.positions[(sz)i]).length());
		}
		alloc::free(mem, posed);
		written.free(mem);
	}

	test::@check(worst <= LIMIT + 1.0e-3f, "a bone turned %.6f rad on a swing axis, past a %.3f limit", worst, LIMIT);
	test::@check(reached > LIMIT * 0.5f, "nothing reached the limit; the check proves nothing");
	// Mid-fall, not settled: what is left between the two is the stretch the
	// distance constraints have not yet closed on a chain gravity is hauling
	// against its limits, a few thousandths of a bone — the rotations are read
	// as directions and rebuilt at rest length. The settled closure is the
	// extraction check's, to 1e-4.
	test::@check(apart < 5.0e-3f, "the written rotations put a joint %.5f from its particle", apart);

	// And the tail did fall as far as the table allows, bone on bone: three
	// bones each turned a fifth of a radian point well below where they started.
	Vec3 tip = chain.body.positions[3];
	test::@check(tip.y < chain.animated[3].y - 0.1f, "the tail hangs at %.4f; the limits held it up rather than back", tip.y);
}

<*
 A probed surface holds the chain off it, the pinned root aside.

 The tail is let go — no spring, gravity on — over a floor a little below it,
 stated as the two answers a `JiggleSurface` gives. It has to come to rest on
 the floor rather than in it, every free particle a radius above it, and the
 root, which is the animation's and immovable, is never asked about at all.
 Then the same drop with the chain told to ignore colliders falls straight
 through, which is what *Collide with character* being off means.
*>
fn void a_probed_surface_holds_the_chain_off_it() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	Floor floor = { .height = 0.7f };
	crig::JiggleSim sim = tail_sim(&skeleton, {
		.stiffness = 0.0f, .damping = 0.1f, .gravity = 1.0f, .radius = PARTICLE_RADIUS });
	defer sim.free(mem);
	sim.surface = { .context = &floor, .aim = &floor_aim, .probe = &floor_probe };

	rig::Pose pose = rig::rest_pose(mem, skeleton.len());
	defer pose.free(mem);
	Matrix4f[] palette = palette_of(&skeleton, pose);
	defer alloc::free(mem, palette);

	sim.prime(palette);
	crig::JiggleChain* chain = &sim.chains[0];

	float deepest = 0.0f;
	for (usz k = 0; k < 2000; k++)
	{
		sim.step(palette);
		for (sz i = 1; i < chain.body.positions.len(); i++)
		{
			deepest = math::max(deepest, floor.height + PARTICLE_RADIUS - chain.body.positions[i].y);
		}
	}
	test::@check(floor.asked > 0, "the surface was never asked anything");
	// A substep's worth of approach past the plane before the contact exists,
	// as with a capsule; well under the radius being protected.
	test::@check(deepest < 4.0e-3f, "a particle dipped %.5f into the floor in passing", deepest);

	float lowest = 1.0e9f;
	for (sz i = 1; i < chain.body.positions.len(); i++) lowest = math::min(lowest, chain.body.positions[i].y);
	test::@check(math::abs(lowest - (floor.height + PARTICLE_RADIUS)) < 2.0e-3f,
		"the tail rests at %.5f; the floor plus the radius is %.5f", lowest, floor.height + PARTICLE_RADIUS);
	test::@check(chain.body.positions[0].y == 1.0f, "the pinned root moved");

	// --- and a chain that does not collide falls through ---------------------
	usz[3] joints = tail_run();
	crig::JiggleParams through = { .stiffness = 0.0f, .damping = 0.1f, .gravity = 1.0f, .radius = PARTICLE_RADIUS };
	crig::JiggleParams[3] each = { through, through, through };
	crig::JiggleChainSpec[1] chains = { { .joints = joints[..], .params = each[..], .ignores_colliders = true } };
	crig::JiggleSim loose = crig::build_jiggle_sim(mem, &skeleton, chains[..])!!;
	defer loose.free(mem);
	usz asked_before = floor.asked;
	loose.surface = { .context = &floor, .aim = &floor_aim, .probe = &floor_probe };
	loose.prime(palette);
	for (usz k = 0; k < 2000; k++) loose.step(palette);
	test::@check(loose.chains[0].body.positions[3].y < floor.height - 0.1f,
		"a chain with colliders ignored was still held off the floor, at %.4f", loose.chains[0].body.positions[3].y);
	test::@check(floor.asked == asked_before, "a chain with colliders ignored still asked the surface");
}

<*
 Run the chain until it is somewhere else, write the result into `animated`, and
 check that posing the skeleton with it puts the joints back on the particles.

 This is the load-bearing one. Everything else here is about the solve; this is
 about the conversion out of it, and a conversion that is merely nearly right
 produces an animation that is nearly the one that was simulated — which is
 exactly the failure nobody sees until the bake is compared against the
 viewport frame by frame.

 The bone lengths are constraint-exact and the pose does not slide any of the
 chain's joints, so the animated segment and the simulated one are the same
 length and `bone_carry` between their directions carries one onto the other
 outright. That is why this can be asserted to 1e-4 rather than to a wobble.

 @param animated : `The pose the sim runs against and the extraction writes into a copy of.`
*>
fn void assert_round_trip(rig::Skeleton* skeleton, rig::Pose animated, String label, crig::JiggleLimit[] limits = {}, float least = 0.1f)
{
	crig::JiggleSim sim = tail_sim(skeleton, {
		.stiffness = 0.0f, .damping = 0.05f, .gravity = 1.0f, .radius = 0.0f }, {}, limits);
	defer sim.free(mem);

	Matrix4f[] palette = palette_of(skeleton, animated);
	defer alloc::free(mem, palette);

	sim.prime(palette);
	for (usz k = 0; k < 400; k++) sim.step(palette);

	crig::JiggleChain* chain = &sim.chains[0];

	// Vacuous unless the particles actually left the pose they were primed at.
	float travelled = 0.0f;
	for (sz i = 0; i < chain.body.positions.len(); i++)
	{
		travelled = math::max(travelled, (chain.body.positions[i] - chain.animated[i]).length());
	}
	test::@check(travelled > least, "%s: the chain only moved %.5f; nothing was extracted", label, travelled);

	rig::Pose out = rig::rest_pose(mem, skeleton.len());
	defer out.free(mem);
	foreach (usz i, rotation : animated.rotations) out.rotations[i] = rotation;
	foreach (usz i, offset : animated.offsets) out.offsets[i] = offset;

	sim.write_pose(mem, skeleton, &out)!!;

	Matrix4f[] after = rig::joint_palette(mem, skeleton, out)!!;
	defer alloc::free(mem, after);

	Vec3[] tails = skeleton.tails(mem);
	defer alloc::free(mem, tails);

	foreach (usz i, joint : chain.joints)
	{
		Vec3 want = chain.body.positions[(sz)i];
		Vec3 got = carried(after[joint], skeleton.joints[joint]);
		test::@check((got - want).length() < 1.0e-4f,
			"%s: joint %d posed to %s, particle is at %s", label, joint, got, want);
	}

	usz last = chain.joints[chain.joints.len - 1];
	Vec3 want_tip = chain.body.positions[(sz)chain.joints.len];
	Vec3 got_tip = carried(after[last], tails[last]);
	test::@check((got_tip - want_tip).length() < 1.0e-4f,
		"%s: the tip posed to %s, particle is at %s", label, got_tip, want_tip);
}

<*
 The extraction closes, both from rest and from a pose that has already turned
 the chain's ancestors.

 The second half is the one with teeth. From rest every world rotation the
 conversion divides by is the identity, so a formula that dropped them entirely
 would still pass; turning the body above the tail, and the tail's own root,
 makes the parent's world rotation something that has to be divided out
 correctly and makes the accumulated turn above each bone something that has to
 be carried down.
*>
fn void the_extraction_puts_the_joints_back_on_the_particles() @test
{
	rig::Skeleton skeleton = tail_skeleton(mem);
	defer skeleton.free(mem);

	rig::Pose rest = rig::rest_pose(mem, skeleton.len());
	defer rest.free(mem);
	assert_round_trip(&skeleton, rest, "at rest");

	rig::Pose turned = rig::rest_pose(mem, skeleton.len());
	defer turned.free(mem);
	turned.turn(0, { 0, 1, 0 }, 0.7f);
	turned.turn(TAIL_ROOT, { 0, 0, 1 }, -0.6f);
	turned.turn(TAIL_MID, { 1, 0, 0 }, 0.4f);
	assert_round_trip(&skeleton, turned, "already posed");

	// And with the tail held inside a table: the clamped rotations are what
	// the particles were put at, so the same closure has to hold.
	crig::JiggleLimit[3] limits = swing_limits(&skeleton, 0.35f);
	assert_round_trip(&skeleton, rest, "limited, at rest", limits[..], 0.05f);
	assert_round_trip(&skeleton, turned, "limited, already posed", limits[..], 0.05f);
}

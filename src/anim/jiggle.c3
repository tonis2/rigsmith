<*
 Secondary motion: bones that keep moving after the animation stops asking them
 to.

 A tail, an ear, a braid, a belly. Nobody keys those — they are what the rest of
 the body did to them a moment ago, and hand-authoring that is both tedious and
 wrong, because the answer depends on how fast the character was actually moving
 when the clip played. So they are simulated instead: the animated pose states
 where each dynamic bone *would* be, physics states where it *is*, and the
 difference is the lag, the overshoot and the swing that reads as weight.

 **What is simulated is a chain of points, not a chain of bones.** A dynamic run
 d1..dn becomes a particle per joint plus one for the last bone's tip, joined by
 distance constraints — which is `collision::SoftBody` exactly, so the solver is
 the library's and this file is only the translation either way:

     out   the animated palette says where each particle's joint went; that is
           the pin under the root particle and the target every other particle
           is sprung toward
     back  the simulated points say where the bones ended up, and `resolve`
           turns the difference into the parent-relative rotations `rig::Pose`
           stores — holding each one inside its joint's rotation limits on
           the way, so the chain swings only where the rig says a joint may

 **The limits are the rig's, not the chain's.** A joint's rotation-limit table
 (`core/joint_limits.c3`) is the one statement of where it may turn, for FK,
 IK, playback and now the simulation: after every substep each simulated bone
 is read back as a rotation, clamped through `constrain_joint_rotation` like a
 keyed one, and put back where the clamped rotation says. A chain of points
 has no twist, so the table's Y axis is honoured by the rotation written out
 rather than by anything the particles do.

 **What a chain collides with** is whatever the caller wires up: capsules,
 stated as joint-plus-radius pairs, and — through `JiggleSurface` — a probe
 the host answers from the character's own deformed skin, with the chain's
 own triangles left out of it. The solver only ever sees a contact point and
 a normal, which is what keeps this file checkable against a plane.

 **The root of a chain is pinned, not simulated.** d1's *position* is animation's
 to state — it hangs off a spine that is being keyed — and what physics owns is
 which way the bone leaving it points. So particle 0 is the pin and the rotation
 written onto d1 is the one that carries its bone onto the segment leaving the
 pin. A chain therefore simulates n bones with n+1 particles.

 **Nothing here knows about a document, a window or a clip.** Chains arrive as
 explicit joint runs and colliders as explicit joint-plus-radius pairs, which is
 what lets the whole of it be checked headless; building those from a
 `RigDocument`, and driving it from the player, are other files' jobs.

 **Determinism is a feature, not an accident.** A bake has to reproduce what the
 viewport showed, so the substep is fixed at 1/120 s and never varies with frame
 rate, constraints are built once in a stable order and never rebuilt mid-run,
 every chain is stepped in root-joint order and the limit projection walks each
 chain root to tip. Two sims given the same inputs produce bit-identical
 particles, which `test/jiggle_test.c3` asserts rather than assumes.
*>
module crig;

import std::sort;
import rig;
import collision;
import std::math;
import std::math::vector;
import std::math::quaternion;


import std::collections::list;

<*
 The fixed substep, in seconds. Everything about the solve is stated at this
 length — compliance becomes a stiffness only once a `dt` is named — so a caller
 that wants a different one has to retune, and none does: a bake and a viewport
 that disagree on the substep disagree on the result.
*>
const float JIGGLE_STEP = 1.0f / 120.0f;

<*
 How many substeps one `advance` will run before it gives up on catching up.

 Sixteen is an eighth of a second, which is more than a frame ever legitimately
 takes and less than the spiral a slow frame would otherwise start: falling
 behind makes the next frame's catch-up longer, which makes it slower still.
 Whatever is left over past the cap is dropped rather than owed.
*>
const usz JIGGLE_MAX_SUBSTEPS = 16;

<*
 How many Gauss-Seidel sweeps each substep makes over the constraints.

 The library's own default is eight, which is plenty for a chain of distance
 links on their own. Contacts need more: a particle pushed off the skin pulls
 the link above it, which the sweep has to go round again to settle. Sixteen
 keeps a three-bone chain's links within a thousandth of their length through
 a contact, and a chain is small enough that the extra sweeps cost nothing
 worth measuring.
*>
const uint JIGGLE_ITERATIONS = 16;

<*
 Standard gravity, in model units per second squared, before a chain's own
 multiplier.

 Model units, so this reads as metres per second squared on a rig modelled at
 one unit to the metre and as something else on a rig that was not — the
 multiplier is where that is corrected. Deliberately not scaled by
 `Skeleton.height()`: a scale-free gravity would make a jiggle look identical on
 a mouse and on an elephant, which is precisely the thing about mass that
 secondary motion is supposed to show.
*>
const float JIGGLE_GRAVITY = 9.8f;

<*
 Raised when a chain names no joints at all.
*>
faultdef JIGGLE_EMPTY_CHAIN;

<*
 Raised when a chain names a joint this skeleton does not have.
*>
faultdef JIGGLE_UNKNOWN_JOINT;

<*
 Raised when a chain does not carry one `JiggleParams` per joint.
*>
faultdef JIGGLE_PARAM_MISMATCH;

<*
 Raised when a chain's joints are not a run — each one the parent of the next.
*>
faultdef JIGGLE_BROKEN_CHAIN;

<*
 Raised when a sim is asked to write into a pose that is not the shape of the
 skeleton it was built against.
*>
faultdef JIGGLE_POSE_MISMATCH;

<*
 How one dynamic bone behaves.

 The units are chosen so the KHR_physics_rigid_bodies mapping is lossless in
 both directions — this is the same four numbers a `Motion` plus an angular
 `Drive` plus a sphere collider carry, and the file writer puts them straight
 out. Where the bone may *turn* is not here: that is the joint's own
 rotation-limit table, which `JiggleLimit` carries alongside.

 **stiffness** is a spring rate toward the animated pose, and it enters the
 solver as its reciprocal: `compliance = 1 / stiffness`, which XPBD turns into
 `alpha = compliance / dt^2`. At the fixed substep that is
 `alpha = 14400 / stiffness`, and a target constraint closes the fraction
 `stiffness / (stiffness + 14400)` of its remaining gap every substep. So the
 useful range is thousands, not units: 14400 halves the gap per substep, 1440
 closes about a tenth, and anything under a hundred is barely distinguishable
 from free. Zero or less removes the constraint outright, which is a bone that
 follows nothing but gravity and its own links.

 **damping** is the fraction of velocity *kept per second*, so 1 is frictionless
 and 0 is a dead stop. Per second rather than per substep, because the solver
 normalizes it by the substep length — halving the substep must not double the
 drag or a bake would not match the viewport.

 **gravity** multiplies `JIGGLE_GRAVITY`. It is read from the chain's first
 joint and applied to the whole chain: a `SoftBody` takes one gravity vector per
 solve, so per-particle gravity is not expressible here, and a run whose tip
 should fall harder than its base wants a stiffness gradient instead.

 **radius** is the particle's own collision radius in model units, added to
 whatever collider it is tested against. Zero makes the particle a point, which
 lets it sit exactly on a capsule's surface and passes straight through a
 probed skin — a surface contact needs a radius to hold something off it.
*>
struct JiggleParams
{
	float stiffness;
	float damping;
	float gravity;
	float radius;
}

<*
 Where one bone of a chain may turn: its joint's rotation-limit table and the
 bone-local frame the table is read in, resolved by the caller against the
 same skeleton the chain is built on.

 `frame` comes from `joint_limit_frame` — or `joint_limit_frame_by_index` for
 a caller with no dot ids — and a table whose frame cannot be derived is no
 limit at all, the same refusal `constrain_pose_to_joint_limits` makes for a
 keyed pose: the solver invents no axes for a fork nobody has chosen a child
 for.
*>
struct JiggleLimit
{
	JointRotationLimits table;
	JointLimitFrame frame;
}

<*
 Whether this entry limits anything.
*>
fn bool JiggleLimit.active(self) => self.table.constrained && self.frame.usable();

<*
 What a surface probe answers: the nearest point of the surface and its
 outward normal there.
*>
struct JiggleContact
{
	Vec3 point;
	Vec3 normal;
}

<*
 Called once per step with the palette the step is aimed at, before any
 particle is probed — where a host poses, or marks as posed, whatever surface
 the probe reads.
*>
alias JiggleSurfaceAim = fn void(void* context, Matrix4f[] palette);

<*
 Whether the surface comes within `radius` of `point`, and where. A hit fills
 `out`; a miss leaves it alone.
*>
alias JiggleSurfaceProbe = fn bool(void* context, Vec3 point, float radius, JiggleContact* out);

<*
 A surface for the chains to be held off, stated as the two questions the
 solver asks of one rather than as a shape.

 	`sim.surface = { .context = app, .aim = &jiggle_surface_aim, .probe = &jiggle_surface_probe };`

 The host owns whatever `context` points at and answers from it: the editor
 answers from the character's deformed skin (`app/sim.c3`), a test from a
 plane. A zero value — no probe — is a sim with no surface, which is every
 sim built before one is wired up.
*>
struct JiggleSurface
{
	void* context;
	JiggleSurfaceAim aim;
	JiggleSurfaceProbe probe;
}

fn bool JiggleSurface.present(self) => self.probe != null;

<*
 One dynamic run: the joints, nearest the body first, and what each of them
 does.

 `joints[0]` is the pinned root — its position stays animation's, its rotation
 is simulated — and every joint after it must be the previous one's child. A
 test states the run itself; `jiggle_specs_from_document` expands the
 document's `SecondaryChain` records into it, root to tip along the skeleton.

 `limits` is one `JiggleLimit` per joint, or empty for a chain whose joints
 carry no limits; `jiggle_specs_from_document` fills it from the document's
 rotation-limit rows.

 `ignores_colliders` is a chain that passes through every capsule and the
 surface both — a `SecondaryChain` whose *Collide with character* is off.
 Spelled as the exception so a spec written by hand collides, which is what
 every spec before the switch existed did.
*>
struct JiggleChainSpec
{
	usz[] joints;
	JiggleParams[] params;
	JiggleLimit[] limits;
	bool ignores_colliders;
}

<*
 One capsule for the chains to hit: the bone from `joint` to its tail, swept by
 `radius`.

 The bone rather than a free-standing shape, so a collider follows the animation
 for nothing — `Skeleton.tails` gives the far end and the joint's own palette
 entry poses both. A radius of zero collides with nothing, which is how a
 collider is disabled without removing it.
*>
struct JiggleColliderSpec
{
	usz joint;
	float radius;
}

<*
 One chain's particles, and the constraint indices that let the animation move
 without rebuilding any of them.

 The indices matter more than they look: XPBD sweeps its constraint lists in
 order, so the order in which targets were added is part of the result. They
 are assigned once, at build, and only ever written through — a rebuild mid-run
 would change the answer, which is why staleness is a rebuild of the whole sim
 rather than a repair of one.
*>
struct JiggleChain
{
	collision::SoftBody body;
	// The run itself. One bone per entry, so segment i of the particle chain is
	// the bone of joints[i] and the rotation extracted for it lands there.
	usz[] joints;
	// Where each particle sits at rest, in model space: the joints themselves,
	// then the last bone's tail.
	Vec3[] rest;
	// Where the animated palette last put each of those points. Refreshed every
	// substep, and read back by `write_pose` as the direction physics deviated
	// from.
	Vec3[] animated;
	// Target constraint index per particle, -1 for a particle with none: the
	// pinned root, and any bone whose stiffness is zero.
	sz[] targets;
	// Where each bone may turn, one per bone; see `JiggleLimit`.
	JiggleLimit[] limits;
	// Each bone's rest length: what a bone put back inside its limit is
	// rebuilt to, the same length the distance constraint holds it at.
	float[] lengths;
	// The parent-relative rotation each bone was last read back as, root
	// first — what `write_pose` writes. Set by `resolve` after every substep
	// and at priming, so it is never a substep behind the particles.
	Quaternionf[] rotations;
	// The chain's gravity multiplier, taken from its root's params.
	float gravity;
	// Whether the capsules and the surface are skipped for this chain; see
	// `JiggleChainSpec`.
	bool ignores_colliders;
}

<*
 A whole rig's worth of jiggle: every chain, every collider, and where the
 fixed-step clock has got to.

 Built once against a skeleton and thrown away when that skeleton changes shape
 — `joint_count` is what makes that check a comparison rather than a guess.
*>
struct JiggleSim
{
	JiggleChain[] chains;
	JiggleColliderSpec[] colliders;
	// Rest endpoints of each collider capsule, and the posed ones the solver is
	// handed. Two arrays rather than one of pairs, because
	// `generate_capsule_collisions` takes them apart.
	Vec3[] collider_head;
	Vec3[] collider_tail;
	Vec3[] segment_a;
	Vec3[] segment_b;
	float[] collider_radius;
	// The surface the chains are held off, when the host has wired one up.
	JiggleSurface surface;
	// One parent per joint, copied from the skeleton: what `resolve` reads
	// the palette against, kept here so a step needs no skeleton handed in.
	int[] parents;
	float accumulator;
	bool primed;
	usz joint_count;
}

<*
 Whether this sim has anything to do.
*>
fn bool JiggleSim.solves(self) => self.chains.len > 0;

<*
 Whether this sim was built against a skeleton of this shape.

 A joint count is not proof the skeleton is the same one, but it is proof it is
 not: every rig edit that adds or removes a dot changes it, and the ones that do
 not — moving a dot — are handled by rebuilding anyway.
*>
fn bool JiggleSim.matches(self, rig::Skeleton* skeleton) => self.joint_count == skeleton.len();

<*
 Build the sim for a set of dynamic runs and the capsules they collide with.

 	`JiggleSim sim = build_jiggle_sim(mem, &skeleton, chains, colliders)!;`

 Every chain is validated before anything is allocated, so a refusal leaks
 nothing and the caller gets the same sim or no sim at all. Chains are then
 built in ascending root-joint order regardless of the order they arrive in,
 which is what makes two callers that describe the same rig differently produce
 the same motion.

 The result is allocated from `allocator`; free it with `JiggleSim.free`.

 @param chains : `The dynamic runs. Joints must be a parent-to-child run inside the skeleton.`
 @param colliders : `Capsules the particles are pushed out of. Order is irrelevant — a particle is tested against all of them.`
 @return? JIGGLE_EMPTY_CHAIN : `A chain names no joints.`
 @return? JIGGLE_PARAM_MISMATCH : `A chain does not carry one params entry per joint, or has limits but not one per joint.`
 @return? JIGGLE_UNKNOWN_JOINT : `A chain or a collider names a joint this skeleton lacks.`
 @return? JIGGLE_BROKEN_CHAIN : `A chain's joints are not each the parent of the next.`
*>
fn JiggleSim? build_jiggle_sim(
	Allocator allocator,
	rig::Skeleton* skeleton,
	JiggleChainSpec[] chains,
	JiggleColliderSpec[] colliders = {})
{
	usz count = skeleton.len();

	foreach (spec : chains)
	{
		if (spec.joints.len == 0) return JIGGLE_EMPTY_CHAIN~;
		if (spec.params.len != spec.joints.len) return JIGGLE_PARAM_MISMATCH~;
		if (spec.limits.len != 0 && spec.limits.len != spec.joints.len) return JIGGLE_PARAM_MISMATCH~;

		foreach (usz i, joint : spec.joints)
		{
			if (joint >= count) return JIGGLE_UNKNOWN_JOINT~;
			if (i == 0) continue;

			int parent = skeleton.parents[joint];
			if (parent < 0 || (usz)parent != spec.joints[i - 1]) return JIGGLE_BROKEN_CHAIN~;
		}
	}

	foreach (collider : colliders)
	{
		if (collider.joint >= count) return JIGGLE_UNKNOWN_JOINT~;
	}

	JiggleSim sim = { .joint_count = count };
	if (count > 0)
	{
		sim.parents = alloc::new_array(allocator, int, (sz)count);
		foreach (usz i, parent : skeleton.parents) sim.parents[i] = parent;
	}

	Vec3[] tails = skeleton.tails(allocator);
	defer alloc::free(allocator, tails);

	if (chains.len > 0)
	{
		usz[] order = alloc::new_array(allocator, usz, (sz)chains.len);
		defer alloc::free(allocator, order);
		chain_order(chains, order);

		sim.chains = alloc::new_array(allocator, JiggleChain, (sz)chains.len);
		foreach (usz slot, usz from : order)
		{
			sim.chains[slot] = build_chain(allocator, skeleton, tails, chains[from], (sz)slot);
		}
	}

	if (colliders.len > 0)
	{
		sim.colliders = alloc::new_array(allocator, JiggleColliderSpec, (sz)colliders.len);
		sim.collider_head = alloc::new_array(allocator, Vec3, (sz)colliders.len);
		sim.collider_tail = alloc::new_array(allocator, Vec3, (sz)colliders.len);
		sim.segment_a = alloc::new_array(allocator, Vec3, (sz)colliders.len);
		sim.segment_b = alloc::new_array(allocator, Vec3, (sz)colliders.len);
		sim.collider_radius = alloc::new_array(allocator, float, (sz)colliders.len);

		foreach (usz i, collider : colliders)
		{
			sim.colliders[i] = collider;
			sim.collider_head[i] = skeleton.joints[collider.joint];
			sim.collider_tail[i] = tails[collider.joint];
			sim.segment_a[i] = sim.collider_head[i];
			sim.segment_b[i] = sim.collider_tail[i];
			sim.collider_radius[i] = math::max(collider.radius, 0.0f);
		}
	}

	return sim;
}

<*
 Put every particle exactly where the animation says its joint is, standing
 still.

 What a cut needs. A sim carried across a seek, a clip change or a scrub would
 spend the next half second whipping its tail back from wherever the previous
 frame left it, which is not lag — it is a spring being released — so the answer
 is to state that there is no history here.

 Silently does nothing when the palette is not this skeleton's, the same way
 `ground_pose` declines a pose it cannot read: a mismatched palette is a stale
 sim, and the caller's answer to that is to rebuild rather than to handle a
 fault per frame.
*>
fn void JiggleSim.prime(&self, Matrix4f[] palette)
{
	if (palette.len != self.joint_count) return;

	self.pose_colliders(palette);

	foreach (&chain : self.chains)
	{
		chain.aim(palette);

		for (sz i = 0; i < chain.body.positions.len(); i++)
		{
			Vec3 at = chain.animated[i];
			chain.body.positions[i] = at;
			chain.body.prev_positions[i] = at;
			chain.body.velocities[i] = (Vec3){ 0, 0, 0 };
		}

		chain.body.collision_constraints.clear();
		chain.resolve(palette, self.parents, 0.0f);
	}

	self.accumulator = 0.0f;
	self.primed = true;
}

<*
 Advance every chain by exactly one substep against this palette.

 	`sim.step(palette);`

 The unit a bake is written in: one call, one 1/120 s of simulated time, and the
 caller free to hand each of them a freshly sampled palette so the targets are
 exact at every substep rather than held for a frame. A viewport wants
 `advance` instead, which is this in a clock.

 Primes first if it has not been primed, so a caller that forgot does not start
 by dragging the whole chain from the rest pose to wherever the character
 actually is.
*>
fn void JiggleSim.step(&self, Matrix4f[] palette)
{
	if (palette.len != self.joint_count) return;
	if (!self.primed) self.prime(palette);
	self.aim_surface(palette);
	self.step_aimed(palette);
}

// Tell the surface which palette the coming substeps are against. Once per
// `step`, and once per `advance` however many substeps it runs, since every
// one of those chases the same pose.
fn void JiggleSim.aim_surface(&self, Matrix4f[] palette)
{
	if (self.surface.aim) self.surface.aim(self.surface.context, palette);
}

// One substep against a palette the surface has already been aimed at.
//
// The order inside a chain is the order the answer depends on: the constraints
// are pointed at the animation, the contacts are generated from where the
// particles stand, the solve moves them, and the limits put back what the
// solve moved past the rig's tables — and read every bone as a rotation on the
// way, so `write_pose` has nothing left to compute.
fn void JiggleSim.step_aimed(&self, Matrix4f[] palette)
{
	self.pose_colliders(palette);

	foreach (&chain : self.chains)
	{
		chain.aim(palette);

		if (!chain.ignores_colliders)
		{
			if (self.colliders.len > 0)
			{
				chain.body.generate_capsule_collisions(self.segment_a, self.segment_b, self.collider_radius);
			}
			if (self.surface.present()) self.probe_surface(chain);
		}

		chain.body.xpbd_solve({ 0, -JIGGLE_GRAVITY * chain.gravity, 0 }, JIGGLE_STEP);
		chain.resolve(palette, self.parents, JIGGLE_STEP);
	}
}

<*
 Hold a chain's particles off the surface: one contact per particle the probe
 finds the surface within reach of, as a plane the solve keeps the particle on
 the outside of.

 The reach is the particle's own radius, so the plane sits that far out from
 the surface point along its normal and the particle's centre stays a radius
 off the skin. A point particle asks nothing — there is no side of a surface
 for a point to be kept on. The pinned root is skipped like every immovable
 particle: the solve would ignore the constraint anyway.

 Asked from where the particle is *about to be* — a substep of its speed on
 from where it stands — rather than where it is. A contact is a plane fixed
 for the substep, and a particle moving fast enough to cross the skin inside
 one would otherwise have its contact generated a substep too late, from the
 far side; asked ahead, the plane is there when the particle arrives. The
 capsules are the library's and ask from where the particle stands, which is
 why the capsule check approaches slowly and this one need not.
*>
fn void JiggleSim.probe_surface(&self, JiggleChain* chain)
{
	for (sz i = 1; i < chain.body.positions.len(); i++)
	{
		if (chain.body.inverse_masses[i] == 0.0f) continue;
		float radius = i < chain.body.particle_radius.len() ? chain.body.particle_radius[i] : 0.0f;
		if (radius <= 0.0f) continue;

		Vec3 at = chain.body.positions[i] + chain.body.velocities[i] * JIGGLE_STEP;
		JiggleContact contact;
		if (!self.surface.probe(self.surface.context, at, radius, &contact)) continue;

		chain.body.collision_constraints.push({
			.particle = i,
			.normal = contact.normal,
			.depth = radius - (at - contact.point).dot(contact.normal),
			.contact_point = contact.point + contact.normal * radius,
			.rigidbody_id = 0,
			.friction = 0.0f,
		});
	}
}

<*
 Advance by `dt` of real time, in whole substeps, keeping the remainder for next
 time.

 A frame is however long it was and a substep is always 1/120 s, so the two are
 reconciled by an accumulator rather than by stretching the substep: a solver
 handed a variable `dt` gives a different answer at 30 fps than at 144, and a
 bake would then be unable to reproduce either.

 The targets are held constant across the substeps of one call — a frame's worth
 of catch-up all chases the same animated pose. That is the one place this is
 cheaper than a bake and not identical to it, and it is invisible except at very
 low frame rates, where the fix is to sample the palette per substep and call
 `step` directly, which is what the bake does.

 @param dt : `Seconds since the last call. Zero or less runs nothing, which is how a paused player holds a settled tail in place.`
*>
fn void JiggleSim.advance(&self, Matrix4f[] palette, float dt)
{
	if (palette.len != self.joint_count) return;
	if (!self.primed) self.prime(palette);
	if (dt > 0.0f) self.accumulator += dt;

	usz steps = 0;
	if (self.accumulator >= JIGGLE_STEP) self.aim_surface(palette);
	while (self.accumulator >= JIGGLE_STEP && steps < JIGGLE_MAX_SUBSTEPS)
	{
		self.step_aimed(palette);
		self.accumulator -= JIGGLE_STEP;
		steps++;
	}

	// Behind by more than the cap allows: drop what is owed instead of owing it
	// to the next frame, which is already going to be at least as late.
	if (self.accumulator >= JIGGLE_STEP) self.accumulator = 0.0f;
}

<*
 Write the simulated rotations onto a pose.

 	`sim.write_pose(mem, &skeleton, &pose)!;`

 The rotations themselves were read off the particles by `resolve` at the end
 of the last substep — or at priming, for a sim that has not stepped — so this
 copies them into place; see `resolve` for the conversion.

 **Rotations only.** Offsets are left exactly as the animation wrote them, which
 is what keeps a ground solve intact: the root's Y is a translation and nothing
 here is.

 **Where it is exact and where it is not.** Bone lengths are constraint-exact,
 so a chain whose animated segments are the rest lengths — any pose that does
 not slide its chain joints — reproduces the particle positions to solver
 precision when the result is fed back through `joint_palette`. A pose that
 *does* offset a chain joint stretches the animated segment away from the
 simulated one's fixed length, and then only the direction carries over.

 Call it after `step` or `advance` with the same palette those were given;
 the rotations are stated against the pose that palette was built from.

 @param pose : `The animated pose, adjusted in place. Must be the skeleton's shape.`
 @return? JIGGLE_POSE_MISMATCH : `The pose or the skeleton is not the shape this sim was built for.`
*>
fn void? JiggleSim.write_pose(&self, Allocator allocator, rig::Skeleton* skeleton, rig::Pose* pose)
{
	if (skeleton.len() != self.joint_count) return JIGGLE_POSE_MISMATCH~;
	if (pose.rotations.len != self.joint_count) return JIGGLE_POSE_MISMATCH~;

	if (!self.solves()) return;

	foreach (&chain : self.chains)
	{
		foreach (usz i, joint : chain.joints) pose.rotations[joint] = chain.rotations[i];
	}
}

<*
 Read the particles back as the rotations a pose stores, and hold each bone
 inside its joint's limits on the way.

 For each bone of the chain, the animated segment says where the animation put
 it and the particles say where physics did; `bone_carry` between the two is
 the world-space turn that separates them, and what a pose stores is a
 *parent-relative* turn, so the parent's world rotation has to be divided out
 of it:

 	`R' = (dR_above * Rw_parent)^-1 * dR * Rw_parent * R`

 — the same conversion `AppState.pose_toward` runs after an IK solve, and for
 the same reason. `dR_above` is the turn the joint above was given a moment ago
 in this very walk: by the time a chain's second bone is reached its parent's
 world rotation is no longer what the palette says it was, and this is the
 correction. Both `Rw_parent` and the animated `R` are read off the palette,
 whose rotation blocks are exactly the composed world rotations the pose was
 built from.

 **A bone past its limit is put back.** `R'` goes through
 `constrain_joint_rotation` — the table and the frame the rig's joint carries,
 the same clamp a keyed rotation gets — and when the clamp moved it, the
 particle below the bone is rebuilt where the clamped rotation points, at the
 bone's rest length, and everything below *that* is carried along by the same
 shift, so the rest of the chain keeps its shape and its link lengths rather
 than being left stretched across the correction. The correction goes into
 the velocities the way a position-based contact does: what went into the
 limit is taken out of the speed, not stored up. The turn carried to the next
 bone is then the clamped one, twist and all, so a limited bone's child is
 read against where its parent actually is.

 A chain of points has no twist of its own, so the table's Y axis changes no
 particle; it is honoured by the rotation written out, and that is the whole
 of what a pose or a bake can see anyway.

 @param dt : `The substep the velocities are stated in. Zero — priming — puts nothing into a velocity.`
*>
fn void JiggleChain.resolve(&self, Matrix4f[] palette, int[] parents, float dt)
{
	Quaternionf above = quaternion::IDENTITY;

	foreach (usz i, joint : self.joints)
	{
		int parent = parents[joint];
		Quaternionf rw_parent = parent >= 0 ? rig::quat_from_matrix(palette[(usz)parent]) : quaternion::IDENTITY;
		Quaternionf keyed = rw_parent.invert().mul(rig::quat_from_matrix(palette[joint])).normalize();

		Vec3 aimed = self.animated[i + 1] - self.animated[i];
		Vec3 held = self.body.positions[(sz)(i + 1)] - self.body.positions[(sz)i];
		Quaternionf turn = bone_carry(aimed, held);

		Quaternionf carry = above.mul(rw_parent);
		Quaternionf rotation = carry.invert().mul(turn).mul(rw_parent).mul(keyed).normalize();

		if (i < self.limits.len && self.limits[i].active() && aimed.length_sq() > 1.0e-12f)
		{
			Quaternionf clamped = constrain_joint_rotation(self.limits[i].frame, self.limits[i].table, rotation);
			// The same rotation up to the quaternion's sign is no correction.
			if (math::abs(clamped.v.dot(rotation.v)) < 1.0f - 1.0e-7f)
			{
				Quaternionf limited = carry.mul(clamped).mul(keyed.invert()).mul(rw_parent.invert()).normalize();
				Vec3 direction = limited.rotate_vec3(aimed.normalize());
				Vec3 was = self.body.positions[(sz)(i + 1)];
				Vec3 now = self.body.positions[(sz)i] + direction * self.lengths[i];
				Vec3 shift = now - was;
				for (sz below = (sz)(i + 1); below < self.body.positions.len(); below++)
				{
					self.body.positions[below] += shift;
					if (dt > 0.0f) self.body.velocities[below] += shift / dt;
				}
				rotation = clamped;
				turn = limited;
			}
		}

		self.rotations[i] = rotation;
		above = turn;
	}
}

<*
 The document's chains as the runs and capsules `build_jiggle_sim` takes.

 	`JiggleChainSpec[] chains;`
 	`JiggleColliderSpec[] colliders;`
 	`jiggle_specs_from_document(mem, &app.doc, &view.skeleton, view.dot_ids, &chains, &colliders);`
 	`defer free_jiggle_specs(mem, chains, colliders);`

 The one place the two vocabularies meet. A `SecondaryChain` says "from this
 dot to that one, and this is how it moves"; the solver wants the *run* — d1
 nearest the body, each joint after it the previous one's child — and one
 `JiggleParams` per joint. So the run is walked out of the skeleton here rather
 than stored, which is what keeps a chain correct after a dot is added in the
 middle of a tail, and the chain's shared values are expanded to every joint of
 it through `SecondaryChain.solver_params`. Each joint's rotation-limit row
 rides along as a `JiggleLimit`, frame resolved against this same build, so
 the chain swings where the Joint card says the joint may.

 The particles' radii come out as zero: what a chain is held off the skin by
 is its own girth, which only the skin knows — `AppState.rebuild_jiggle` fills
 them in from the surface, with the clearance, before the sim is built.

 **A chain that does not resolve is skipped, not refused**, because this runs on
 every rebuild and a refusal per frame is not a thing a viewport can do with:

 - a root or tip whose dot is gone, or which this build does not hold — the
   document keeps the record so undo can bring the dot back with it;
 - a tip that is no longer under its root, which a re-parenting edit leaves
   behind;
 - a root on the skeleton's own root, which has no animated point above it to
   hang from;
 - a run through a joint an earlier chain already owns. Chains are expanded in
   root-joint order, so the one nearer the body keeps the joint.

 `AppState.secondary_problem` is where a caller that can be told refuses these
 before they are written; here they are shapes to survive, not to argue with.

 The caller owns both arrays; free them with `free_jiggle_specs`.

 @param dot_ids : `The dot each joint was built from — RigView.dot_ids.`
 @param chains : `Receives the runs, ordered by root joint. Empty when nothing is dynamic.`
 @param colliders : `Receives one entry per collider whose dot this build still holds.`
*>
fn void jiggle_specs_from_document(
	Allocator allocator,
	RigDocument* doc,
	rig::Skeleton* skeleton,
	uint[] dot_ids,
	JiggleChainSpec[]* chains,
	JiggleColliderSpec[]* colliders)
{
	*chains = {};
	*colliders = {};

	usz joints = skeleton.len();
	if (joints == 0) return;

	if (doc.secondary.len() > 0)
	{
		// Root joint per chain, and the chains sorted by it: parents-before-
		// children is what lets the nearer chain claim a shared joint, and
		// root order is what `build_jiggle_sim` wants for determinism anyway.
		usz records = (usz)doc.secondary.len();
		usz[] roots = alloc::new_array(allocator, usz, (sz)records);
		defer alloc::free(allocator, roots);
		usz[] order = alloc::new_array(allocator, usz, (sz)records);
		defer alloc::free(allocator, order);

		foreach (usz i, chain : doc.secondary.array_view())
		{
			roots[i] = joint_index_of(dot_ids, chain.root, joints);
			order[i] = i;
		}
		sort::insertionsort(order, &by_value_in, roots);

		bool[] claimed = alloc::new_array(allocator, bool, (sz)joints);
		defer alloc::free(allocator, claimed);
		usz[] run = alloc::new_array(allocator, usz, (sz)joints);
		defer alloc::free(allocator, run);

		JiggleChainSpecList runs;
		runs.init(allocator);

		foreach (which : order)
		{
			SecondaryChain chain = doc.secondary.get((sz)which);
			usz root = roots[which];
			usz tip = joint_index_of(dot_ids, chain.tip, joints);
			if (root >= joints || tip >= joints) continue;
			if (skeleton.parents[root] < 0) continue;

			usz length = secondary_run(skeleton, root, tip, run);
			if (length == 0) continue;

			bool free_run = true;
			for (usz i = 0; i < length; i++)
			{
				if (claimed[run[i]]) { free_run = false; break; }
			}
			if (!free_run) continue;

			usz[] owned = alloc::new_array(allocator, usz, (sz)length);
			JiggleParams[] carried = alloc::new_array(allocator, JiggleParams, (sz)length);
			JiggleLimit[] limits = alloc::new_array(allocator, JiggleLimit, (sz)length);
			JiggleParams params = chain.solver_params();
			for (usz i = 0; i < length; i++)
			{
				owned[i] = run[i];
				carried[i] = params;
				claimed[run[i]] = true;

				JointRotationLimits table = doc.rotation_limits_of(dot_ids[run[i]]);
				limits[i] = {
					.table = table,
					.frame = table.constrained ? joint_limit_frame(skeleton, dot_ids, table) : (JointLimitFrame){},
				};
			}

			runs.push({ .joints = owned, .params = carried, .limits = limits, .ignores_colliders = !chain.collide });
		}

		// Guarded, because a document whose every chain is stale leaves this empty
		// and a zero-length allocation is one nothing here would free.
		if (runs.len() > 0) *chains = runs.to_array(allocator);
		runs.free();
	}

	sz capsules = doc.colliders.len();
	if (capsules == 0) return;

	JiggleColliderSpec[] specs = alloc::new_array(allocator, JiggleColliderSpec, capsules);
	usz kept = 0;
	foreach (entry : doc.colliders.array_view())
	{
		if (entry.radius <= 0.0f) continue;
		foreach (usz j, id : dot_ids)
		{
			if (id != entry.dot_id || j >= joints) continue;
			specs[kept++] = { .joint = j, .radius = entry.radius };
			break;
		}
	}

	if (kept > 0)
	{
		*colliders = specs[:kept];
	}
	else
	{
		alloc::free(allocator, specs);
	}
}

// Which joint a dot became in this build, or `joints` for one it did not.
fn usz joint_index_of(uint[] dot_ids, uint id, usz joints) @local
{
	if (id == 0) return joints;
	sz j = array::index_of(dot_ids[:(dot_ids.len < joints ? dot_ids.len : joints)], id) ?? -1;
	return j < 0 ? joints : (usz)j;
}

alias JiggleChainSpecList = List{JiggleChainSpec};

<*
 Release what `jiggle_specs_from_document` handed back.
*>
fn void free_jiggle_specs(Allocator allocator, JiggleChainSpec[] chains, JiggleColliderSpec[] colliders)
{
	foreach (chain : chains)
	{
		if (chain.joints.len > 0) alloc::free(allocator, chain.joints);
		if (chain.params.len > 0) alloc::free(allocator, chain.params);
		if (chain.limits.len > 0) alloc::free(allocator, chain.limits);
	}
	if (chains.len > 0) alloc::free(allocator, chains);
	if (colliders.len > 0) alloc::free(allocator, colliders);
}

fn void JiggleSim.free(&self, Allocator allocator)
{
	foreach (&chain : self.chains)
	{
		chain.body.free();
		if (chain.joints.len > 0) alloc::free(allocator, chain.joints);
		if (chain.rest.len > 0) alloc::free(allocator, chain.rest);
		if (chain.animated.len > 0) alloc::free(allocator, chain.animated);
		if (chain.targets.len > 0) alloc::free(allocator, chain.targets);
		if (chain.limits.len > 0) alloc::free(allocator, chain.limits);
		if (chain.lengths.len > 0) alloc::free(allocator, chain.lengths);
		if (chain.rotations.len > 0) alloc::free(allocator, chain.rotations);
	}

	if (self.chains.len > 0) alloc::free(allocator, self.chains);
	if (self.parents.len > 0) alloc::free(allocator, self.parents);
	if (self.colliders.len > 0) alloc::free(allocator, self.colliders);
	if (self.collider_head.len > 0) alloc::free(allocator, self.collider_head);
	if (self.collider_tail.len > 0) alloc::free(allocator, self.collider_tail);
	if (self.segment_a.len > 0) alloc::free(allocator, self.segment_a);
	if (self.segment_b.len > 0) alloc::free(allocator, self.segment_b);
	if (self.collider_radius.len > 0) alloc::free(allocator, self.collider_radius);

	*self = {};
}

<*
 Which joint carries a particle: its own, except for the tip, which rides the
 last bone.
*>
fn usz JiggleChain.owner(&self, usz particle)
{
	usz last = self.joints.len - 1;
	return particle < last ? self.joints[particle] : self.joints[last];
}

<*
 Point every constraint in this chain at where the animation currently is.

 Four things move together and none of them may be left behind: the pin under
 the root, the animated points the rest of the walk reads, the targets and the
 cone axes. All four come out of the same palette, so they cannot disagree.
*>
fn void JiggleChain.aim(&self, Matrix4f[] palette)
{
	foreach (usz i, rest : self.rest)
	{
		self.animated[i] = rest.transform(palette[self.owner(i)]);
	}

	if (self.body.pins.len() > 0) self.body.pins.get_ref(0).local_offset = self.animated[0];

	foreach (usz i, sz index : self.targets)
	{
		if (index >= 0) self.body.set_target_at(index, self.animated[i]);
	}
}

<*
 Pose every collider capsule with its own joint's palette entry.

 Once per step rather than once per chain: a capsule does not care which chain
 is asking, and posing it twice would only be a chance to pose it differently.
*>
fn void JiggleSim.pose_colliders(&self, Matrix4f[] palette)
{
	foreach (usz i, collider : self.colliders)
	{
		self.segment_a[i] = self.collider_head[i].transform(palette[collider.joint]);
		self.segment_b[i] = self.collider_tail[i].transform(palette[collider.joint]);
	}
}

<*
 The order to build chains in: ascending root joint, and ties broken by the
 order they arrived in.

 An insertion sort because a rig has a handful of chains and the stability is
 worth more than the asymptotics.
*>
fn void chain_order(JiggleChainSpec[] chains, usz[] order) @local
{
	foreach (usz i, &slot : order) *slot = i;
	sort::insertionsort(order, &by_root_joint, chains);
}

<*
 One chain's soft body, built and wired up.

 The particle layout is the whole of the mapping and is worth stating once. For
 a run of n joints there are n+1 particles: particle `i` below n is joint
 `joints[i]`'s own position, and particle n is the last bone's tail. So segment
 `i` — particle `i` to particle `i+1` — is the bone of `joints[i]`, which is the
 joint whose rotation `write_pose` writes that segment's turn back to.
*>
fn JiggleChain build_chain(
	Allocator allocator,
	rig::Skeleton* skeleton,
	Vec3[] tails,
	JiggleChainSpec spec,
	sz id) @local
{
	usz bones = spec.joints.len;
	usz particles = bones + 1;

	JiggleChain chain = {
		.joints = alloc::new_array(allocator, usz, (sz)bones),
		.rest = alloc::new_array(allocator, Vec3, (sz)particles),
		.animated = alloc::new_array(allocator, Vec3, (sz)particles),
		.targets = alloc::new_array(allocator, sz, (sz)particles),
		.limits = alloc::new_array(allocator, JiggleLimit, (sz)bones),
		.lengths = alloc::new_array(allocator, float, (sz)bones),
		.rotations = alloc::new_array(allocator, Quaternionf, (sz)bones),
		.gravity = spec.params[0].gravity,
		.ignores_colliders = spec.ignores_colliders,
	};

	foreach (usz i, joint : spec.joints)
	{
		chain.joints[i] = joint;
		chain.rest[i] = skeleton.joints[joint];
		chain.limits[i] = i < spec.limits.len ? spec.limits[i] : (JiggleLimit){};
		chain.rotations[i] = quaternion::IDENTITY;
	}
	chain.rest[bones] = tails[spec.joints[bones - 1]];
	foreach (usz i, rest : chain.rest) chain.animated[i] = rest;
	for (usz i = 0; i < bones; i++) chain.lengths[i] = (chain.rest[i + 1] - chain.rest[i]).length();

	float[] inverse_masses = alloc::new_array(allocator, float, (sz)particles);
	defer alloc::free(allocator, inverse_masses);
	inverse_masses[..] = 1.0f;

	chain.body = collision::create_particle_chain(allocator, chain.rest, inverse_masses, id);

	chain.body.substeps = 1;
	chain.body.constraint_iterations = JIGGLE_ITERATIONS;
	chain.body.pins_first = true;
	chain.body.can_sleep = false;

	// Per-particle damping has to cover every particle or the ones past its end
	// silently revert to the whole-body per-substep meaning, which is a
	// different curve entirely.
	for (usz i = 0; i < particles; i++)
	{
		JiggleParams params = spec.params[i < bones ? i : bones - 1];
		chain.body.particle_damping.push(math::clamp(params.damping, 0.0f, 1.0f));
		chain.body.particle_radius.push(math::max(params.radius, 0.0f));
	}

	// The root's position is animation's to state, so it is pinned rather than
	// sprung: no stiffness makes a bone's base wander, and a target on an
	// immovable particle does nothing anyway.
	chain.body.pin_particle(0, chain.rest[0]);
	chain.targets[0] = -1;

	for (usz i = 1; i < particles; i++)
	{
		JiggleParams params = spec.params[i < bones ? i : bones - 1];
		chain.targets[i] = params.stiffness > 0.0f
			? chain.body.add_target((sz)i, chain.rest[i], 1.0f / params.stiffness)
			: -1;
	}

	return chain;
}

// Stable orders over indices: by the value each index names, and by the root
// joint of the chain it names.
fn int by_value_in(usz a, usz b, usz[] values) @local => values[a] < values[b] ? -1 : (values[a] > values[b] ? 1 : 0);
fn int by_root_joint(usz a, usz b, JiggleChainSpec[] chains) @local
	=> chains[a].joints[0] < chains[b].joints[0] ? -1 : (chains[a].joints[0] > chains[b].joints[0] ? 1 : 0);

<*
 Writing the animations crig ships with.

     `c3c run make-anims`

 The templates below used to be compiled into the app. They are here now because
 animations are data: the app reads whatever .glb files it finds in its
 animations folder at startup, and this tool is how the ones in the box get
 made. Editing a number here and re-running is the whole loop.

 The rig they are written against is the biped preset in its own normalized box
 — the same table `fit_preset` maps onto a mesh, taken at unit height with no
 mesh to snap to. That matters twice over. The offsets below are fractions of
 the rig's height, so the rig has to have one; and the exported skeleton is what
 the importer reads bone directions from, so a template that arrives on a rig
 posed differently can be carried onto it.

 Four packs come out of here. Three are diagrams of a body plan — biped,
 quadruped, bird — with joints named for a person reading them and clip tables
 written directly below. The fourth is the humanoid: sixty-five joints in the
 same words, a mannequin rather than a diagram, and clips authored in world
 angles because a rig that rests in a T-pose cannot state an arm's motion
 parent-relative. It lives in humanoid_plan.c3 and humanoid_clips.c3, which is
 also where the reasons are.

 Regenerating is not part of the build. The .glb is checked in, and a tool that
 ran on every build would rewrite a tracked file for no reason.
*>
module make_anims;

import crig;
import rig;
import std::io;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::math::matrix;



// What the pack says about itself, written into the file's root `extras` and
// read back by anim/anim_pack.c3. `plan` is what a rig has to declare to be
// offered these clips; the tags are what the library is filtered by.
// Plain globals rather than consts, and the same for the radii below: a `const`
// holding a slice is materialized where it is used, so one stored on a spec and
// read back a loop iteration later points at nothing. Caught by two packs
// coming out with one tag each.
String[3] biped_tags = { "biped", "humanoid", "locomotion" };
String[3] quadruped_tags = { "quadruped", "animal", "locomotion" };
String[3] bird_tags = { "bird", "animal", "flight" };
String[4] humanoid_tags = { "biped", "humanoid", "locomotion", "hands" };

<*
 How thick the body is at each joint, as a fraction of the rig's height.

 In the same order `fit_preset` emits BIPED_DOTS with `place_optional`, mirrored
 rows expanded: hips, spine, chest, neck, head, then shoulder / elbow / wrist and
 thigh / knee / ankle, each left before right, then the hand and the fingers.

 Written out rather than derived from how many children a joint has. The obvious
 heuristic — thicker where the chain branches — puts the widest part of the
 figure at the hips and the second widest at the chest, which is a snowman.
*>
float[59] biped_radii = {
	0.075, 0.072, 0.085, 0.035, 0.070,
	0.045, 0.045,
	0.032, 0.032,
	0.024, 0.024,
	0.060, 0.060,
	0.042, 0.042,
	0.028, 0.028,

	// The optional joints, in the same expanded order: hand, then thumb, index,
	// middle, ring and pinky, four joints each and left before right. Explicit
	// rather than left to run off the end of the array — `radius_of` repeats its
	// last entry, and every finger would come out as thick as an ankle.
	//
	// A finger tapers, so each joint is thinner than the one above it, and the
	// tip markers get the thinnest of all. Nothing measures these: the body is
	// what a plan is looked at and normalized against, so what they have to be is
	// the right size, not the right anatomy.
	0.030, 0.030,

	0.011, 0.011, 0.009, 0.009, 0.008, 0.008, 0.006, 0.006,
	0.010, 0.010, 0.009, 0.009, 0.007, 0.007, 0.005, 0.005,
	0.010, 0.010, 0.009, 0.009, 0.007, 0.007, 0.005, 0.005,
	0.009, 0.009, 0.008, 0.008, 0.006, 0.006, 0.005, 0.005,
	0.008, 0.008, 0.007, 0.007, 0.006, 0.006, 0.004, 0.004,
};

<*
 The quadruped's, in the order QUADRUPED_DOTS expands to: pelvis, spine, chest,
 neck, head, tail_base, tail_tip, then shoulder / fore_knee / fore_hoof and
 hip / hind_knee / hind_hoof, each left before right.

 A barrel body on thin legs, which is what a four-legged animal is from the
 point of view of "which lump does this bone carry".
*>
float[19] quadruped_radii = {
	0.090, 0.095, 0.100, 0.045, 0.070,
	0.045, 0.020,
	0.040, 0.040,
	0.032, 0.032,
	0.026, 0.026,
	0.050, 0.050,
	0.038, 0.038,
	0.026, 0.026,
};

<*
 The bird's: pelvis, spine, chest, neck, head, tail, then thigh / knee / foot
 and wing_root / wing_tip.

 The chest is most of a bird, and the wings are one bone each — so they are
 written thin and long rather than tapering, which is the only way two bones
 read as a wing at all.
*>
float[16] bird_radii = {
	0.085, 0.090, 0.105, 0.040, 0.065,
	0.035,
	0.032, 0.032,
	0.024, 0.024,
	0.020, 0.020,
	0.030, 0.030,
	0.018, 0.018,
};

// ---------------------------------------------------------------------------
// Biped walk cycle.
//
// Joint names match BIPED_DOTS after _L/_R expansion in fit_preset.
//
// Four poses, quarter of a second apart: contact, passing, the mirror of
// contact, the mirror of passing. Contact is the pose the walk is recognisable
// from — one leg reaching forward with the heel about to land, the other
// trailing with the heel lifted — and passing is the one that makes it a walk
// rather than a scissor, because the swinging leg has to fold under the body
// and clear the ground while the standing leg carries the weight straight.
//
// Every keyframe names every joint the walk moves, including the ones it holds
// at zero. Interpolation handles a missing joint correctly, but a table where
// each pose lists the same rows is one where a wrong number is visible by
// reading across.
//
// The hips are never turned. They are the root, so turning them turns the whole
// figure, and a walk that rocks the entire body reads as a stumble. The torso
// lean lives on the spine, one joint further up.
//
// They do carry the bob, which is the one thing only a translation can do. Legs
// are a fixed length, so a figure standing with its feet apart is shorter than
// one standing with them together: hold the pelvis at a constant height through
// a stride and the leading foot has to hang in the air to reach. The pelvis
// drops at both contacts and rises at both passings — twice a cycle, which is
// the rhythm a walk actually has — and on the figures this was measured against
// it takes the worst gap between a planted foot and the floor from about 3% of
// the rig's height down to under 1%.
//
// What is left is the straight line between the keyframes. The height a leg
// gives up falls off with the square of how far it is swung, so a bob that
// ramps evenly from contact to passing over-drops in between; the number below
// is the one that balances the remaining float against the remaining sink
// rather than eliminating either. Closing that gap wants keyframes shaped to
// the curve, not a different constant.
const float WALK_BOB = 0.022; // fraction of rig height, see AnimKeyDot.move

const crig::AnimKeyDot[] BIPED_WALK_CONTACT_L = {
	// t = 0.00 — left heel about to land, right heel lifted and pushing off
	{ .joint_name = "hips",       .axis = { 1, 0, 0 }, .angle =  0.00f, .move = { 0, -WALK_BOB, 0 } },
	{ .joint_name = "spine",      .axis = { 1, 0, 0 }, .angle =  0.03f },
	{ .joint_name = "chest",      .axis = { 0, 1, 0 }, .angle =  0.07f }, // shoulders counter the hips
	{ .joint_name = "neck",       .axis = { 1, 0, 0 }, .angle =  0.05f },
	{ .joint_name = "head",       .axis = { 1, 0, 0 }, .angle = -0.05f },

	{ .joint_name = "thigh_L",    .axis = { 1, 0, 0 }, .angle = -0.38f },
	{ .joint_name = "knee_L",     .axis = { 1, 0, 0 }, .angle =  0.05f },
	{ .joint_name = "ankle_L",    .axis = { 1, 0, 0 }, .angle = -0.12f },

	{ .joint_name = "thigh_R",    .axis = { 1, 0, 0 }, .angle =  0.31f },
	{ .joint_name = "knee_R",     .axis = { 1, 0, 0 }, .angle =  0.26f },
	{ .joint_name = "ankle_R",    .axis = { 1, 0, 0 }, .angle =  0.31f },

	// Arms oppose legs: the leg reaching forward is the arm swinging back.
	{ .joint_name = "shoulder_L", .axis = { 1, 0, 0 }, .angle =  0.31f },
	{ .joint_name = "elbow_L",    .axis = { 1, 0, 0 }, .angle = -0.28f },

	{ .joint_name = "shoulder_R", .axis = { 1, 0, 0 }, .angle = -0.31f },
	{ .joint_name = "elbow_R",    .axis = { 1, 0, 0 }, .angle = -0.47f },
};

const crig::AnimKeyDot[] BIPED_WALK_PASS_L = {
	// t = 0.25 — left leg straight under the body carrying the weight, right
	// leg folded and swinging through
	{ .joint_name = "hips",       .axis = { 1, 0, 0 }, .angle =  0.00f, .move = { 0, 0, 0 } },
	{ .joint_name = "spine",      .axis = { 1, 0, 0 }, .angle =  0.03f },
	{ .joint_name = "chest",      .axis = { 0, 1, 0 }, .angle =  0.00f },
	{ .joint_name = "neck",       .axis = { 1, 0, 0 }, .angle =  0.05f },
	{ .joint_name = "head",       .axis = { 1, 0, 0 }, .angle = -0.05f },

	{ .joint_name = "thigh_L",    .axis = { 1, 0, 0 }, .angle =  0.02f },
	{ .joint_name = "knee_L",     .axis = { 1, 0, 0 }, .angle =  0.03f },
	{ .joint_name = "ankle_L",    .axis = { 1, 0, 0 }, .angle =  0.02f },

	{ .joint_name = "thigh_R",    .axis = { 1, 0, 0 }, .angle = -0.12f },
	{ .joint_name = "knee_R",     .axis = { 1, 0, 0 }, .angle =  0.72f }, // folds the foot clear of the floor
	{ .joint_name = "ankle_R",    .axis = { 1, 0, 0 }, .angle = -0.16f },

	{ .joint_name = "shoulder_L", .axis = { 1, 0, 0 }, .angle =  0.06f },
	{ .joint_name = "elbow_L",    .axis = { 1, 0, 0 }, .angle = -0.38f },

	{ .joint_name = "shoulder_R", .axis = { 1, 0, 0 }, .angle = -0.06f },
	{ .joint_name = "elbow_R",    .axis = { 1, 0, 0 }, .angle = -0.38f },
};

const crig::AnimKeyDot[] BIPED_WALK_CONTACT_R = {
	// t = 0.50 — CONTACT_L with the sides exchanged
	{ .joint_name = "hips",       .axis = { 1, 0, 0 }, .angle =  0.00f, .move = { 0, -WALK_BOB, 0 } },
	{ .joint_name = "spine",      .axis = { 1, 0, 0 }, .angle =  0.03f },
	{ .joint_name = "chest",      .axis = { 0, 1, 0 }, .angle = -0.07f },
	{ .joint_name = "neck",       .axis = { 1, 0, 0 }, .angle =  0.05f },
	{ .joint_name = "head",       .axis = { 1, 0, 0 }, .angle = -0.05f },

	{ .joint_name = "thigh_R",    .axis = { 1, 0, 0 }, .angle = -0.38f },
	{ .joint_name = "knee_R",     .axis = { 1, 0, 0 }, .angle =  0.05f },
	{ .joint_name = "ankle_R",    .axis = { 1, 0, 0 }, .angle = -0.12f },

	{ .joint_name = "thigh_L",    .axis = { 1, 0, 0 }, .angle =  0.31f },
	{ .joint_name = "knee_L",     .axis = { 1, 0, 0 }, .angle =  0.26f },
	{ .joint_name = "ankle_L",    .axis = { 1, 0, 0 }, .angle =  0.31f },

	{ .joint_name = "shoulder_R", .axis = { 1, 0, 0 }, .angle =  0.31f },
	{ .joint_name = "elbow_R",    .axis = { 1, 0, 0 }, .angle = -0.28f },

	{ .joint_name = "shoulder_L", .axis = { 1, 0, 0 }, .angle = -0.31f },
	{ .joint_name = "elbow_L",    .axis = { 1, 0, 0 }, .angle = -0.47f },
};

const crig::AnimKeyDot[] BIPED_WALK_PASS_R = {
	// t = 0.75 — PASS_L with the sides exchanged
	{ .joint_name = "hips",       .axis = { 1, 0, 0 }, .angle =  0.00f, .move = { 0, 0, 0 } },
	{ .joint_name = "spine",      .axis = { 1, 0, 0 }, .angle =  0.03f },
	{ .joint_name = "chest",      .axis = { 0, 1, 0 }, .angle =  0.00f },
	{ .joint_name = "neck",       .axis = { 1, 0, 0 }, .angle =  0.05f },
	{ .joint_name = "head",       .axis = { 1, 0, 0 }, .angle = -0.05f },

	{ .joint_name = "thigh_R",    .axis = { 1, 0, 0 }, .angle =  0.02f },
	{ .joint_name = "knee_R",     .axis = { 1, 0, 0 }, .angle =  0.03f },
	{ .joint_name = "ankle_R",    .axis = { 1, 0, 0 }, .angle =  0.02f },

	{ .joint_name = "thigh_L",    .axis = { 1, 0, 0 }, .angle = -0.12f },
	{ .joint_name = "knee_L",     .axis = { 1, 0, 0 }, .angle =  0.72f },
	{ .joint_name = "ankle_L",    .axis = { 1, 0, 0 }, .angle = -0.16f },

	{ .joint_name = "shoulder_R", .axis = { 1, 0, 0 }, .angle =  0.06f },
	{ .joint_name = "elbow_R",    .axis = { 1, 0, 0 }, .angle = -0.38f },

	{ .joint_name = "shoulder_L", .axis = { 1, 0, 0 }, .angle = -0.06f },
	{ .joint_name = "elbow_L",    .axis = { 1, 0, 0 }, .angle = -0.38f },
};

// The last frame repeats the first so the loop closes on the pose it opened
// with; without it the cycle would jump from the pose at 0.75 back to 0.00.
const crig::AnimKeyframe[] BIPED_WALK_FRAMES = {
	{ .time = 0.00f, .dots = BIPED_WALK_CONTACT_L[..] },
	{ .time = 0.25f, .dots = BIPED_WALK_PASS_L[..] },
	{ .time = 0.50f, .dots = BIPED_WALK_CONTACT_R[..] },
	{ .time = 0.75f, .dots = BIPED_WALK_PASS_R[..] },
	{ .time = 1.00f, .dots = BIPED_WALK_CONTACT_L[..] },
};

const crig::AnimTemplate BIPED_WALK = {
	.name = "Walk cycle",
	.duration = 1.0f,
	.keyframes = BIPED_WALK_FRAMES[..],
	.loop = true,
};

<*
 One pack to write: which plan it is, what it is called, and what goes in it.
*>
struct PackSpec
{
	String path;
	crig::Preset plan;
	crig::AnimPackMeta meta;
	float[] radii;
	crig::AnimTemplate[] clips;

	// A sphere at each joint on top of the bones, and how many faces to go round
	// with. Both optional: empty and zero give the plain eight-sided prism body
	// the first three packs have always had.
	float[] balls;
	float[] ball_back;
	usz sides;
}

<*
 A body plan as a skeleton in its own right.

 `fit_preset` normally maps the table onto a mesh's bounding box and snaps every
 dot onto something solid. Handed the unit box and no voxels it does neither, so
 what comes back is the table itself: a figure one unit tall, which is the rig
 the numbers above were written against.

 **The optional dots are placed here and nowhere else.** The pack is what the app
 rebuilds a plan out of, so a name the file's skeleton does not carry is a name no
 rig can ever be given — see `AnimPack.preset`. Which of them were optional goes
 out beside the skeleton, for the writer to record in the file.

 @param names : `Receives one owned name per joint.`
 @param optional : `Receives the names of the optional joints, a subset of the above sharing its strings.`
*>
fn rig::Skeleton plan_skeleton(crig::Preset plan, String[]* names, String[]* optional)
{
	rig::Bounds unit = { .min = { 0, 0, 0 }, .max = { 1, 1, 1 } };
	crig::FittedDot[] fitted = crig::fit_preset(mem, plan, unit, null, place_optional: true);

	usz count = fitted.len;
	rig::Skeleton skeleton = {
		.joints = alloc::new_array(mem, Vec3, (sz)count),
		.parents = alloc::new_array(mem, int, (sz)count),
	};
	String[] owned = alloc::new_array(mem, String, (sz)count);

	usz spare = 0;
	foreach (dot : fitted) if (dot.optional) spare++;
	String[] listed = alloc::new_array(mem, String, (sz)spare);

	usz next = 0;
	foreach (usz i, dot : fitted)
	{
		skeleton.joints[i] = dot.position;
		skeleton.parents[i] = dot.parent;
		owned[i] = dot.name;
		if (dot.optional) listed[next++] = dot.name;
	}

	// The names move into `owned` rather than being copied, so only the array
	// that held them is released here. `listed` borrows the same strings.
	alloc::free(mem, fitted);

	*names = owned;
	*optional = listed;
	return skeleton;
}

fn int main(String[] args)
{
	// Every pack, or just the one a path names — the second is the loop while
	// a clip is being tuned, since verifying all three takes a moment.
	String only = args.len > 1 ? args[1] : "";

	usz written = 0;
	foreach (spec : pack_specs())
	{
		if (only.len > 0 && spec.path != only) continue;
		if (!write_pack(spec)) return 1;
		written++;
	}

	if (written == 0)
	{
		io::printfn("nothing matched '%s'", only);
		return 1;
	}
	return 0;
}

// Here rather than as a constant: a `const` struct holding slices cannot be
// stored and read back later in C3 — the slice is materialized where it is
// used — and these are read one field at a time inside the loop.
fn PackSpec[] pack_specs()
{
	crig::AnimTemplate[] biped_clips = mem::new_array(crig::AnimTemplate, 2);
	biped_clips[0] = BIPED_WALK;
	biped_clips[1] = BIPED_IDLE;

	crig::AnimTemplate[] quad_clips = mem::new_array(crig::AnimTemplate, 1);
	quad_clips[0] = QUADRUPED_IDLE;

	crig::AnimTemplate[] bird_clips = mem::new_array(crig::AnimTemplate, 1);
	bird_clips[0] = BIRD_IDLE;

	PackSpec[] specs = mem::new_array(PackSpec, 4);
	specs[0] = {
		.path = "assets/animations/biped.glb",
		.plan = { .name = "Biped", .dots = biped_dots[..] },
		.meta = { .plan = "biped", .name = "Biped", .tags = biped_tags[..] },
		.radii = biped_radii[..],
		.clips = biped_clips,
	};
	specs[1] = {
		.path = "assets/animations/quadruped.glb",
		.plan = { .name = "Quadruped", .dots = quadruped_dots[..] },
		.meta = { .plan = "quadruped", .name = "Quadruped", .tags = quadruped_tags[..] },
		.radii = quadruped_radii[..],
		.clips = quad_clips,
	};
	specs[2] = {
		.path = "assets/animations/bird.glb",
		.plan = { .name = "Bird", .dots = bird_dots[..] },
		.meta = { .plan = "bird", .name = "Bird", .tags = bird_tags[..] },
		.radii = bird_radii[..],
		.clips = bird_clips,
	};

	// The one pack here that is a figure rather than a diagram: sixty-five joints
	// in the biped plan's words, a mannequin built around them, and three clips
	// of its own. It is what crig opens with, and the reason it is generated
	// rather than downloaded is in humanoid_plan.c3.
	//
	// Twelve sides rather than eight, and balls at the joints. The other three
	// packs are looked at to see which lump a bone carries; this one is looked at
	// as a body, so the seams have to stop showing.
	specs[3] = {
		.path = "assets/animations/humanoid.glb",
		.plan = { .name = "Humanoid", .dots = humanoid_dots[..] },
		.meta = { .plan = "biped", .name = "Humanoid", .tags = humanoid_tags[..] },
		.radii = humanoid_radii[..],
		.clips = humanoid_clips(mem),
		.balls = humanoid_balls[..],
		.ball_back = humanoid_ball_back[..],
		.sides = 12,
	};
	return specs;
}

fn bool write_pack(PackSpec spec)
{
	String[] names;
	String[] optional;
	rig::Skeleton skeleton = plan_skeleton(spec.plan, &names, &optional);
	defer
	{
		foreach (name : names)
		{
			if (name.len > 0) alloc::free(mem, name.ptr);
		}
		alloc::free(mem, names);
		alloc::free(mem, optional); // borrows `names`' strings; only the array is ours
		skeleton.free(mem);
	}

	// The plan decides these, not the spec: a table that gains a finger should not
	// also need the list beside it edited, and the two disagreeing would write a
	// pack whose optional joints are not the ones the table meant.
	crig::AnimPackMeta meta = spec.meta;
	meta.optional = optional;

	io::printfn("%s: %d joints (%d optional), %.4f tall",
		spec.meta.name, skeleton.len(), optional.len, skeleton.height());
	foreach (template : spec.clips)
	{
		io::printfn("  %s — %.3fs over %d keyframes", template.name, template.duration, template.keyframes.len);
	}

	// The body a pack is looked at with. Built from the same skeleton the clips
	// were written against, so the two cannot disagree about where a joint is.
	rig::TriMesh body = crig::dummy_body(mem, &skeleton, spec.radii, spec.sides == 0 ? 8 : spec.sides, spec.balls, spec.ball_back);
	defer body.free(mem);
	io::printfn("  body: %d vertices, %d triangles", body.positions.len, body.triangle_count());

	if (catch err = crig::export_pack_glb(mem, spec.path, &skeleton, names, spec.clips, body, meta))
	{
		io::printfn("could not write %s: %s", spec.path, err);
		io::printn("(the folder has to exist already)");
		return false;
	}

	io::printfn("  wrote %s", spec.path);
	return verify(spec, &skeleton, names);
}

<*
 Read back what was just written and check it still plays the same.

 A generator that cannot be checked is a generator nobody trusts to re-run. The
 conversion out and the conversion back are separate code, so agreeing at every
 joint at every instant is a real statement about both — and if they ever stop
 agreeing, this says so at the moment the file is made rather than the next time
 someone watches a walk and thinks it looks a bit off.
*>
fn bool verify(PackSpec spec, rig::Skeleton* skeleton, String[] names)
{
	// The file, not the folder it sits in. Reading the folder was fine while
	// there was one pack in it and breaks the moment there are two — and it
	// says nothing about the metadata or the body, which are half of what a
	// pack now is.
	crig::AnimPack? pack = crig::read_pack(mem, spec.path);
	if (catch pack)
	{
		io::printfn("  %s does not read back as a pack", spec.path);
		return false;
	}
	defer pack.free(mem);

	if (pack.clips.len != spec.clips.len)
	{
		io::printfn("  read back %d animations, wrote %d", pack.clips.len, spec.clips.len);
		return false;
	}
	if (pack.plan != spec.meta.plan)
	{
		io::printfn("  the pack came back for plan \"%s\", not \"%s\"", pack.plan, spec.meta.plan);
		return false;
	}
	if (pack.mesh.positions.len == 0)
	{
		io::printn("  the pack came back with no body, so it cannot be a body plan");
		return false;
	}
	io::printfn("  %s: plan \"%s\", %d tags, %d vertices in the body",
		pack.name, pack.plan, pack.tags.len, pack.mesh.positions.len);

	bool ok = true;
	foreach (usz i, original : spec.clips)
	{
		crig::AnimTemplate copy = pack.clips[i];
		if (copy.name != original.name)
		{
			io::printfn("  \"%s\" came back named \"%s\"", original.name, copy.name);
			ok = false;
		}

		// Sampled between the keyframes as well as on them: landing on the keys
		// alone would miss a clip that arrived with its timing rearranged.
		float worst = 0.0f;
		for (usz step = 0; step <= 40; step++)
		{
			float time = original.duration * (float)step / 40.0f;
			float gap = pose_gap(original, copy, skeleton, names, time);
			if (gap > worst) worst = gap;
		}

		float height = skeleton.height();
		io::printfn("  %s: worst joint %.7f out of %.4f, %.4f%% of the rig",
			original.name, worst, height, worst / height * 100.0f);
		if (worst > height * 1.0e-4f) ok = false;
	}

	io::printn(ok ? "verified: what was written plays as what went in" : "VERIFY FAILED");
	return ok;
}

// How far apart two templates put the rig at one instant.
fn float pose_gap(
	crig::AnimTemplate a,
	crig::AnimTemplate b,
	rig::Skeleton* skeleton,
	String[] names,
	float time)
{
	rig::Pose left = a.pose(mem, skeleton, names, time);
	defer left.free(mem);
	rig::Pose right = b.pose(mem, skeleton, names, time);
	defer right.free(mem);

	Matrix4f[] left_palette = rig::joint_palette(mem, skeleton, left)!!;
	defer alloc::free(mem, left_palette);
	Matrix4f[] right_palette = rig::joint_palette(mem, skeleton, right)!!;
	defer alloc::free(mem, right_palette);

	float worst = 0.0f;
	foreach (usz j, joint : skeleton.joints)
	{
		float[<4>] here = left_palette[j].apply({ joint.x, joint.y, joint.z, 1.0f });
		float[<4>] there = right_palette[j].apply({ joint.x, joint.y, joint.z, 1.0f });
		float gap = ((Vec3){ here.x - there.x, here.y - there.y, here.z - there.z }).length();
		if (gap > worst) worst = gap;
	}
	return worst;
}



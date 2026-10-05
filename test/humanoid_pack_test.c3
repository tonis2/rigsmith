<*
 The shipped humanoid rig and the generator's sample animations.

 Rig-contract checks read `assets/animations/humanoid.glb` directly. Animation
 checks read the disposable test library, which puts generated clips onto the
 current rig and round-trips them through glTF. The shipped rig template is not
 required to carry Walk, Stand or Wave.

 **What is actually at risk here.** The clips are authored in world angles and
 converted to the parent-relative turns a keyframe stores (see
 `tools/humanoid_clips.c3`). Every sign in that conversion is a coin flip that
 reads plausibly either way on the page — a walk with its arms swinging backwards
 looks like a walk in a still, and a leg that reaches back instead of forward is
 a walk played in reverse. So the checks below are about *direction*: which foot
 is in front, which arm is behind it, and whether the arms came down out of the
 T-pose at all. Nothing here checks that it looks good; that is what eyes are
 for. It checks that it is not backwards.
*>
module crig_tests::humanoid_pack;

import crig;
import rig;
import crig_tests::library;
import crig_tests::shared_app;


import std::core::test;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;

const String HUMANOID = "assets/animations/humanoid.glb";

// Animation expectations belong to generated sample clips, not to the shipped
// rig-only template. The first two checks still inspect that asset directly.
fn crig::AnimPack? animated_sample()
{
	String path = string::format(mem, "%s/humanoid.glb", library::ready());
	defer path.free(mem);
	return crig::read_pack(mem, path);
}

// The plan is written in a unit box, so every length below is a fraction of a
// figure just under one tall. A centimetre on a person is about this.
const float SMALL = 0.01f;

<*
 Where every joint of the pack's rest rig ends up at one instant of one clip.

 The same route the player takes — `AnimTemplate.pose` for the clip's turns,
 `joint_palette` to compose them down the chain, and the rest position through
 the result — so a check here is a statement about what is drawn rather than
 about the numbers on the way there.
*>
fn Vec3[] posed(Allocator allocator, crig::AnimPack* pack, usz clip, float time) @local
{
	rig::Pose pose = pack.clips[clip].pose(allocator, &pack.rest, pack.joint_names, time);
	defer pose.free(allocator);

	Matrix4f[] palette = rig::joint_palette(allocator, &pack.rest, pose)!!;
	defer alloc::free(allocator, palette);

	Vec3[] out = alloc::new_array(allocator, Vec3, (sz)pack.rest.len());
	foreach (usz j, joint : pack.rest.joints)
	{
		float[<4>] moved = palette[j].apply({ joint.x, joint.y, joint.z, 1.0f });
		out[j] = { moved.x, moved.y, moved.z };
	}
	return out;
}

// Which row a joint name sits on. Every check below goes through this rather
// than through an index: the row order is the plan table's and a joint inserted
// into it would silently re-point every hard-coded number.
fn usz row(crig::AnimPack* pack, String name) @local
{
	foreach (usz j, held : pack.joint_names)
	{
		if (held == name) return j;
	}
	test::@check(false, "the pack carries no joint named \"%s\"", name);
	return 0;
}

fn usz clip_named(crig::AnimPack* pack, String name) @local
{
	foreach (usz c, clip : pack.clips)
	{
		if (clip.name == name) return c;
	}
	test::@check(false, "the pack carries no clip named \"%s\"", name);
	return 0;
}

<*
 The vocabulary: the biped plan's words, with the figure's extra joints spelt
 the same way.

 The rotation-limit defaults, the mirror and the clip player all read these
 words, and a rig `fit_preset` places from the biped diagram is spelt with the
 same ones — so a rename that looked like tidying would quietly part the
 shipped figure from everything that knows what a `knee_L` is.
*>
fn void the_rig_carries_the_biped_plans_words() @test
{
	crig::AnimPack? pack = crig::read_pack(mem, HUMANOID);
	if (catch pack) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	defer pack.free(mem);

	test::@check(pack.rest.len() == 65, "expected 65 joints, got %d", pack.rest.len());
	test::@check(pack.plan == "biped", "expected the biped plan tag, got \"%s\"", pack.plan);

	String[7] wanted = {
		"hips", "chest", "head",
		"thigh_L", "ankle_R",
		"elbow_L", "thumb_4_R",
	};
	foreach (name : wanted) row(&pack, name);

	// The fingers, and only the fingers. A pack whose optional list drifted would
	// start refusing rigs for want of a knuckle.
	usz spare = 0;
	foreach (usz j, optional : pack.joint_optional)
	{
		if (!optional) continue;
		spare++;
		String word = pack.joint_names[j];
		test::@check(word.starts_with("thumb_") || word.starts_with("index_") || word.starts_with("middle_")
			|| word.starts_with("ring_") || word.starts_with("pinky_"),
			"\"%s\" is marked optional but is not a finger joint", pack.joint_names[j]);
	}
	// Optionality is authoring metadata, not a requirement on a template rig.
	// A user may choose to require all of its joints.
	test::@check(spare <= 40, "more optional joints than the humanoid's fingers");
}

// Whether a fitted joint's table lets a turn through as it is, or takes it back
// to rest. A turn is built from the bone's own direction, since a fitted bone
// does not lie along a world axis: the axis `bone × toward` carries the tip
// toward `toward`.
fn Quaternionf swing_of(rig::Skeleton* skeleton, usz joint, Vec3 toward, float degrees) @local
{
	Vec3 bone = {};
	foreach (usz i, int parent : skeleton.parents)
	{
		if (parent == (int)joint) { bone = (skeleton.joints[i] - skeleton.joints[joint]).normalize(); break; }
	}
	return quaternion::from_axis_angle{float}(bone.cross(toward).normalize(), degrees * (float)math::PI / 180.0f);
}

fn float turn_between(Quaternionf a, Quaternionf b) @local
{
	float dot = math::abs(a.normalize().v.dot(b.normalize().v));
	if (dot > 1.0f) dot = 1.0f;
	return 2.0f * math::acos(dot) * 180.0f / (float)math::PI;
}

// The fitted knee's answer to a fold: how far the constrained turn is from the
// asked one. Near zero means it went through; near the fold means it was
// refused.
fn float knee_fold_taken(crig::AppState* app, String knee, Vec3 toward, float degrees) @local
{
	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	crig::Dot* dot = app.dot_named(knee);
	if (!dot) { test::@check(false, "the fitted rig has no %s", knee); return 0.0f; }
	sz joint = view.joint_of(dot.id);
	crig::JointRotationLimits table = app.doc.rotation_limits_of(dot.id);
	test::@check(table.constrained, "%s carries no table after the fit", knee);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, table);
	test::@check(frame.usable(), "%s's table cannot be read on the fitted rig: %s", knee, frame.status.reason());
	Quaternionf asked = swing_of(&view.skeleton, (usz)joint, toward, degrees);
	return turn_between(asked, crig::constrain_joint_rotation(frame, table, asked));
}

<*
 The shipped humanoid carries a rotation-limit table on every joint that turns,
 as KHR constraints — the one place they are kept: a fit reads them from there,
 and so does crig opening the figure, whose sidecar says nothing about them.

 The root moves the whole body, and the crown, the toe tips and the ten
 fingertips are markers; everything else — fifty-one joints — has a table.
*>
fn void the_rig_carries_a_limit_on_every_joint_that_turns() @test
{
	crig::AnimPack? read = crig::read_pack(mem, HUMANOID);
	if (catch read) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	crig::AnimPack pack = read;
	defer pack.free(mem);

	usz rows = pack.constraints.joints.len;
	usz foreign = pack.constraints.foreign.len;
	test::@check(rows == pack.rest.len(), "%d constraint rows for %d joints", rows, pack.rest.len());
	test::@check(foreign == 0, "%d foreign constraints in a file crig wrote", foreign);
	usz exact = 0;
	foreach (usz j, constraint : pack.constraints.joints)
	{
		String name = pack.joint_names[j];
		bool marker = name == "hips" || name == "head_top" || name.starts_with("toe_tip")
			|| name.ends_with("_4_L") || name.ends_with("_4_R");
		test::@check((constraint.status == EXACT) != marker, "%s %s a table", name,
			constraint.status == EXACT ? "carries" : "carries no");
		if (constraint.status != EXACT) continue;
		exact++;
		if (name.starts_with("knee"))
		{
			test::@check(constraint.axes[0].allowed && !constraint.axes[1].allowed && !constraint.axes[2].allowed,
				"%s is not a hinge", name);
		}
		if (name == "chest" || name.starts_with("wrist"))
		{
			test::@check(constraint.frame_intent == PRIMARY_CHILD && constraint.primary_child >= 0,
				"%s forks and names no child for its axes", name);
		}
	}
	test::eq(exact, (usz)51);

	// The open reads them off the model.
	rig::TriMesh? loaded = rig::load_gltf(mem, HUMANOID);
	if (catch loaded) { test::@check(false, "%s did not load as a mesh", HUMANOID); return; }
	rig::TriMesh mesh = loaded;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, HUMANOID);
	defer app.free();
	app.adopt_source_rig();
	test::eq(app.doc.rotation_limits.len(), (sz)51);
	foreach (dot : app.doc.dots.array_view())
	{
		crig::JointRotationLimits table = app.doc.rotation_limits_of(dot.id);
		crig::JointConstraint constraint = pack.constraints.joints[row(&pack, dot.name)];
		test::@check(table.constrained == (constraint.status == EXACT),
			"opened, %s is %slimited; the model says %s", dot.name, table.constrained ? "" : "not ",
			constraint.status == EXACT ? "limited" : "free");
		if (!table.constrained) continue;
		for (usz a = 0; a < 3; a++)
		{
			test::@check(table.axes[a].same(constraint.axes[a]),
				"opened, %s's axis %d is not what the model says", dot.name, a);
		}
		test::@check(!table.has_saved_frame, "%s came off the model with a pinned frame", dot.name);
	}
}

<*
 Applied to another mesh, the limits come with the plan, and the right way round.

 Two targets. The figure's own body, which the fit puts facing the way the
 figure faces, so the rows land in frames like the ones they were written
 in; and the same body turned half way round, which the fit puts head toward
 −Z — the whole figure turned — so a row copied as it was written would fold
 every knee forward. Both knees fold back and only back.
*>
fn void applied_to_another_mesh_the_limits_carry_over_the_right_way_round() @test
{
	// The figure's own body as a bare mesh, rigged from the library's copy.
	rig::TriMesh? loaded = rig::load_gltf(mem, HUMANOID);
	if (catch loaded) { test::@check(false, "%s did not load as a mesh", HUMANOID); return; }
	rig::TriMesh mesh = loaded;
	defer mesh.free(mem); // borrowed by the app, so released after it
	crig::AppState body = crig::new_app(mesh, "build/humanoid-refit.glb");
	defer body.free();
	shared_app::attach_library(&body);
	test::@check(body.apply_plan_named("biped"), "the humanoid plan would not fit its own body");
	test::@check(body.notice().contains("joint limit") && !body.notice().contains("-Z"),
		"the fit onto the body did not adopt the limits facing +Z: %s", body.notice());
	test::@check(body.doc.rotation_limits.len() >= 19, "only %d tables came with the plan", body.doc.rotation_limits.len());
	test::@check(knee_fold_taken(&body, "knee_L", { 0, 0, -1 }, 60.0f) < 6.0f, "the refitted left knee would not fold back");
	test::@check(knee_fold_taken(&body, "knee_R", { 0, 0, -1 }, 60.0f) < 6.0f, "the refitted right knee would not fold back");
	test::@check(knee_fold_taken(&body, "knee_L", { 0, 0, 1 }, 30.0f) > 25.0f, "the refitted left knee bent forward");

	// The same body turned half way round, so it faces −Z for certain.
	rig::TriMesh? turned_loaded = rig::load_gltf(mem, HUMANOID);
	if (catch turned_loaded) { test::@check(false, "%s did not load as a mesh", HUMANOID); return; }
	rig::TriMesh turned_mesh = turned_loaded;
	defer turned_mesh.free(mem);
	foreach (&p : turned_mesh.positions) *p = { -p.x, p.y, -p.z };
	foreach (&n : turned_mesh.normals) *n = { -n.x, n.y, -n.z };
	crig::AppState turned = crig::new_app(turned_mesh, "build/humanoid-turned-refit.glb");
	defer turned.free();
	shared_app::attach_library(&turned);
	test::@check(turned.apply_plan_named("biped"), "the humanoid plan would not fit the turned body");
	test::@check(turned.notice().contains("joint limit") && turned.notice().contains("-Z"),
		"the turned body's fit did not adopt the limits facing -Z: %s", turned.notice());
	test::@check(knee_fold_taken(&turned, "knee_L", { 0, 0, 1 }, 60.0f) < 6.0f, "the turned left knee would not fold back");
	test::@check(knee_fold_taken(&turned, "knee_R", { 0, 0, 1 }, 60.0f) < 6.0f, "the turned right knee would not fold back");
	test::@check(knee_fold_taken(&turned, "knee_L", { 0, 0, -1 }, 30.0f) > 25.0f, "the turned left knee bent forward");

	// Each side lands on the figure's own side: +X is the left of a figure facing
	// +Z and its right when it faces −Z. A reflected fit kept _L on +X either way,
	// so turning it around afterwards gave a figure with its sides swapped and
	// every clip retargeted onto the wrong leg — a walk that went backwards.
	test::@check(body.dot_named("knee_L").position.x > body.dot_named("knee_R").position.x,
		"facing +Z, the left knee is not on +X");
	test::@check(turned.dot_named("knee_L").position.x < turned.dot_named("knee_R").position.x,
		"facing -Z, the left knee is not on -X: the fit reflected the figure instead of turning it");
}

<*
 The rig rests in a T-pose and the body was built around that rest.

 Both halves matter. A plan is fitted to a user's mesh by mapping fractions of
 one bounding box onto another, so a rig whose arms are not out is a rig whose
 fractions across mean nothing; and `AnimPack.preset` measures those fractions
 against the *body*, so a body that does not enclose the skeleton would hand the
 matcher a wrist past the edge of the figure.
*>
fn void the_rest_pose_is_a_t_pose_inside_its_own_body() @test
{
	crig::AnimPack? pack = crig::read_pack(mem, HUMANOID);
	if (catch pack) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	defer pack.free(mem);

	Vec3 left = pack.rest.joints[row(&pack, "wrist_L")];
	Vec3 right = pack.rest.joints[row(&pack, "wrist_R")];
	Vec3 head = pack.rest.joints[row(&pack, "head_top")];
	Vec3 hips = pack.rest.joints[row(&pack, "hips")];

	// As fractions of the figure's height, so the shape is what is tested and not
	// the units the model happens to be in.
	float height = head.y;
	test::@check(left.x > hips.x + 0.15f * height, "the left hand is not held out (x %.3f against hips %.3f)", left.x, hips.x);
	test::@check(right.x < hips.x - 0.15f * height, "the right hand is not held out (x %.3f against hips %.3f)", right.x, hips.x);
	test::@check(math::abs(left.y - right.y) < SMALL, "the hands rest at different heights");
	test::@check(math::abs(left.y - head.y) > 0.08f * height, "the arms are not level with the shoulders");

	// The body encloses the rig it was built around, which is what makes the
	// pack a body plan rather than a clip library that happens to have a mesh.
	rig::Bounds box = pack.mesh.bounds();
	foreach (usz j, joint : pack.rest.joints)
	{
		test::@check(
			joint.x >= box.min.x - SMALL && joint.x <= box.max.x + SMALL &&
			joint.y >= box.min.y - SMALL && joint.y <= box.max.y + SMALL &&
			joint.z >= box.min.z - SMALL && joint.z <= box.max.z + SMALL,
			"\"%s\" sits outside the body it was built around", pack.joint_names[j]);
	}
}

<*
 Every clip brings the arms down.

 The rig rests with its arms straight out, so an arm the clip forgot stays there
 — and a figure walking through a doorway with its arms out is the single most
 visible thing that can go wrong here. Checked at four instants rather than one
 because a keyframe that lists the arms and a keyframe that does not interpolate
 towards rest between them, so the failure would live between the keys.
*>
fn void every_clip_puts_the_arms_down() @test
{
	crig::AnimPack? pack = animated_sample();
	if (catch pack) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	defer pack.free(mem);

	usz hips = row(&pack, "hips");
	usz shoulder = row(&pack, "shoulder_L");
	usz wrist = row(&pack, "wrist_L");
	float arm_length = (pack.rest.joints[wrist] - pack.rest.joints[shoulder]).length();

	foreach (usz c, clip : pack.clips)
	{
		for (usz step = 0; step < 4; step++)
		{
			float time = clip.duration * (float)step / 4.0f;
			Vec3[] at = posed(mem, &pack, c, time);
			defer alloc::free(mem, at);

			// Measure against this rig's arm, not the original mannequin's
			// proportions. A shorter edited arm must still point down.
			test::@check(at[wrist].y < at[shoulder].y - arm_length * 0.35f,
				"\"%s\" at %.2fs leaves the left wrist up at the shoulder (%.3f against %.3f)",
				clip.name, time, at[wrist].y, at[shoulder].y);
			// Measured against this rig's own arm rather than an absolute margin,
			// so a taller figure with a longer arm is held to the same standard.
			// What the check is for is the T-pose, where the wrist stands a whole
			// arm out; at seven tenths of the arm that is still caught, and an arm
			// that merely hangs a little wide is not the failure this was written
			// to find.
			test::@check(at[wrist].x < at[shoulder].x + arm_length * 0.7f,
				"\"%s\" at %.2fs leaves the left arm sticking out (x %.3f against %.3f)",
				clip.name, time, at[wrist].x, at[shoulder].x);
			test::@check(at[hips].y > 0.4f, "\"%s\" at %.2fs dropped the figure through the floor", clip.name, time);
		}
	}
}

<*
 The walk steps forwards, and the arms swing against the legs.

 This is the check the whole file exists for. `+z` is the way the figure faces —
 the toes are the joints furthest along it in the rest pose, which is what makes
 that a fact about the rig rather than a convention asserted here. At the first
 contact the left leg is the one reaching into it and the right is trailing;
 half a cycle later they have exchanged, which is what makes it a walk and not a
 hop. The arms do the opposite of the leg on their own side, because that is what
 keeps a walking figure from rotating about its own axis.
*>
fn void the_walk_reaches_forwards_and_swings_the_arms_against_the_legs() @test
{
	crig::AnimPack? pack = animated_sample();
	if (catch pack) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	defer pack.free(mem);

	usz walk = clip_named(&pack, "Walk");
	usz hips = row(&pack, "hips");
	usz left_foot = row(&pack, "ankle_L");
	usz right_foot = row(&pack, "ankle_R");
	usz left_hand = row(&pack, "wrist_L");
	usz right_hand = row(&pack, "wrist_R");

	// The rest rig faces +z, so "forward" below is a larger z.
	Vec3 toe = pack.rest.joints[row(&pack, "toe_tip_L")];
	Vec3 heel = pack.rest.joints[left_foot];
	test::@check(toe.z > heel.z, "the rest rig does not face +z; every direction below is measured the wrong way");

	Vec3[] contact = posed(mem, &pack, walk, 0.0f);
	defer alloc::free(mem, contact);

	test::@check(contact[left_foot].z > contact[hips].z + 0.05f,
		"at contact the left foot is not reaching forwards (z %.3f against hips %.3f)",
		contact[left_foot].z, contact[hips].z);
	test::@check(contact[right_foot].z < contact[hips].z - 0.02f,
		"at contact the right foot is not trailing (z %.3f against hips %.3f)",
		contact[right_foot].z, contact[hips].z);

	// Hand against hand, not hand against hips: where the arm hangs at rest is the
	// mesh's (this one's forearm angles forwards, so both hands sit ahead of the
	// pelvis), but which hand leads is the swing.
	test::@check(contact[left_hand].z < contact[right_hand].z,
		"the left arm swings with its own leg instead of against it (z %.3f against right %.3f)",
		contact[left_hand].z, contact[right_hand].z);

	// Half a cycle on, the sides have exchanged. A clip that moved the legs but
	// never swapped them would pass every check above.
	Vec3[] mirrored = posed(mem, &pack, walk, pack.clips[walk].duration * 0.5f);
	defer alloc::free(mem, mirrored);

	test::@check(mirrored[right_foot].z > mirrored[hips].z + 0.05f, "half a cycle on, the right foot is not the one reaching");
	test::@check(mirrored[left_foot].z < mirrored[hips].z - 0.02f, "half a cycle on, the left foot is not the one trailing");
	test::@check(mirrored[right_hand].z < mirrored[left_hand].z, "half a cycle on, the arms have not exchanged");

	// And the swing is the same size on both sides: a walk built by editing one
	// contact and forgetting to mirror the other limps, which no still frame shows.
	float reach = contact[left_foot].z - contact[hips].z;
	float other = mirrored[right_foot].z - mirrored[hips].z;
	test::@check(math::abs(reach - other) < SMALL, "the two strides differ (%.3f against %.3f)", reach, other);
}

<*
 The pelvis drops at both contacts and rises between them.

 The bob is the one thing in the walk carried by a translation rather than a
 turn, and it goes in through a different field of the keyframe entry — so it is
 also the one thing that survives every rotation being wrong, and the one thing
 that breaks on its own while the rotations stay right.
*>
fn void the_walk_bobs_twice_a_cycle() @test
{
	crig::AnimPack? pack = animated_sample();
	if (catch pack) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	defer pack.free(mem);

	usz walk = clip_named(&pack, "Walk");
	usz hips = row(&pack, "hips");
	float cycle = pack.clips[walk].duration;

	float[4] height;
	for (usz step = 0; step < 4; step++)
	{
		Vec3[] at = posed(mem, &pack, walk, cycle * (float)step / 4.0f);
		defer alloc::free(mem, at);
		height[step] = at[hips].y;
	}

	// Contacts at 0 and half, passings at a quarter and three quarters.
	test::@check(height[1] > height[0] + 0.005f, "the pelvis does not rise at the first passing");
	test::@check(height[3] > height[2] + 0.005f, "the pelvis does not rise at the second passing");
	test::@check(math::abs(height[0] - height[2]) < 0.001f, "the two contacts sit at different heights");
	test::@check(math::abs(height[1] - height[3]) < 0.001f, "the two passings sit at different heights");
}

<*
 The wave raises one arm and leaves the other alone.

 It is the only clip that carries a joint past horizontal, which is the half of
 the range a walk never visits and the half a bad weight on the shoulder shows up
 in — so a wave that quietly stopped waving would take that coverage with it.
*>
fn void the_wave_raises_one_arm_and_rocks_it() @test
{
	crig::AnimPack? pack = animated_sample();
	if (catch pack) { test::@check(false, "%s did not read as a pack", HUMANOID); return; }
	defer pack.free(mem);

	usz wave = clip_named(&pack, "Wave");
	usz shoulder = row(&pack, "shoulder_R");
	usz right_hand = row(&pack, "wrist_R");
	usz left_hand = row(&pack, "wrist_L");

	Vec3[] out = posed(mem, &pack, wave, 0.0f);
	defer alloc::free(mem, out);
	Vec3[] over = posed(mem, &pack, wave, pack.clips[wave].duration * 0.25f);
	defer alloc::free(mem, over);

	test::@check(out[right_hand].y > out[shoulder].y, "the waving hand is not above the shoulder");
	test::@check(over[right_hand].y > over[shoulder].y, "the waving hand drops below the shoulder mid-wave");
	test::@check(out[left_hand].y < out[shoulder].y, "the other arm went up too");

	// The wave is a rock, so the hand has to actually travel between the two
	// poses — a clip whose halves came out identical plays as a raised arm.
	test::@check((over[right_hand] - out[right_hand]).length() > 0.05f, "the waving hand barely moves");
}

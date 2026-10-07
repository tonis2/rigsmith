<*
 Reading a glTF animation back as a template, offline and with no GPU.

     `c3c test --trust=full --test-filter crig_tests::anim_import`

 The question is whether the conversion in anim/anim_import.c3 is lossless. It
 claims to be exact, and "exact" is checkable: play the imported template
 through crig's own posing and the joints must land where the source file put
 them, to float precision, at the source's keys and between them.

 The fixture is written out by this file rather than checked in, so what it
 contains is visible here instead of being a binary nobody can read. It is a
 three-joint chain with nothing axis-aligned about it — the whole rig is turned
 by a node matrix, and both joints below rest at an angle — because a conversion
 that only works on a chain lying along an axis works by accident. The one thing
 it does not have is a mesh: the importer reads the skeleton and the channels and
 never asks what is skinned to them.
*>
module crig_tests::anim_import;

import crig;
import rig;
import gltf;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;
import std::encoding::base64;
import std::core::string;



<*
 The fixtures, each written by whichever check needs it.

 Under `c3c test` the checks run in name order rather than in the order they are
 written here, so none of them may rely on a file another one left behind.
 Writing is cheap — these are a few kilobytes of glTF apiece — and a fixture
 rewritten per check is one no other check can have corrupted.
*>
const String ANIMATED_FIXTURE = "build/anim-import-fixture.gltf";
const String FLAT_FIXTURE = "build/anim-import-flat.gltf";
const String FOLD_FIXTURE = "build/anim-import-fold.gltf";
const String ARMLESS_FIXTURE = "build/anim-import-armless.gltf";

<*
 A real pack from the repo, for the check that wants a file it did not write.

 Relative, so the run has to start from the crig directory.
*>
const String REAL_PACK = "assets/animations/humanoid.glb";

<*
 Write the animated fixture and report where it went.

 Returns false having already failed the calling test, so a check that cannot
 get its fixture says that rather than going on to blame the importer.
*>
fn bool animated_fixture(String* path)
{
	*path = ANIMATED_FIXTURE;
	if (catch fault error = write_fixture(ANIMATED_FIXTURE))
	{
		test::@check(false, "could not write %s (%s)", ANIMATED_FIXTURE, error);
		return false;
	}
	return true;
}

// A conversion that claims to be exact gets held to it. This is a few multiples
// of float rounding through a dozen quaternion products, not a tolerance.
const float EXACT = 1.0e-4f;

// ---------------------------------------------------------------------------
// The fixture.

// Nothing here is a right angle or an axis by accident. The rig is turned as a
// whole by the root's matrix, and each joint below rests rolled, so a conversion
// that quietly assumes bone-local axes are world axes has nowhere to hide.
const float ROOT_YAW = 0.9f;   // radians about Y, on the root's node matrix
const float HIPS_ROLL = 0.35f; // radians about Z
const float KNEE_ROLL = -0.6f; // radians about Z
const float KNEE_SWING = 0.7f; // radians about X, what the animation does
const float HIPS_TURN = 0.45f; // and how far the animation turns the hips
// Off every axis on purpose. The hips turning is what makes a parent-relative
// rotation different from a world one, and an axis-aligned turn would let a
// conversion that confused the two still look right down one column.
const Vec3 HIPS_TURN_AXIS = { 1.0f, 0.4f, -0.2f };

const Vec3 ROOT_SHIFT = { 0.2f, 0.0f, -0.3f };
const Vec3 HIPS_REST = { 0, 1.0f, 0 };  // the hips' rest offset from the root
const Vec3 HIPS_DIP = { 0, 0.9f, 0 };   // and where the animation dips it to
// An unnamed node sitting between the hips and the knee. Exporters emit these
// — helpers, correctives, an armature's own bookkeeping — and a template keys on
// names, so this one cannot be a joint. What it can do is move everything below
// it, and its transform has to end up baked into where those joints rest.
const Vec3 SPACER_OFFSET = { 0.05f, -0.1f, 0.03f };
const float SPACER_ROLL = 0.25f; // radians about Y

const Vec3 KNEE_OFFSET = { 0, -0.4f, 0 };
const Vec3 ANKLE_OFFSET = { 0, -0.4f, 0 };

// How far the second animation walks its root forward, in the root's frame.
const Vec3 WALK_STEP = { 0, 0, 1.0f };

// And how far the third one pivots the hips: past half a circle, which is where
// a rotation stops having a short way round and a quaternion changes the sign it
// stores the same turn under. A character turning to face the other way does
// this, and reading the axis back without allowing for it inverts the turn.
const float SPIN_TURN = 4.0f;
const Vec3 SPIN_AXIS = { 0.2f, 1.0f, 0.1f };

// Which of the fixture's animations is being talked about.
enum Clip
{
	BEND,
	WALK,
	SPIN,
}

const usz HIPS = 0;
const usz KNEE = 1;
const usz ANKLE = 2;
const String[3] JOINT_NAMES = { "hips", "knee", "ankle" };
// The same rig with only the knee driven. A joint asked for under a name no
// entry carries stays at rest, so this plays the knee's swing on its own —
// without it the hips' turn would carry the whole chain and there would be no
// way to see what the knee did by itself.
const String[3] KNEE_ONLY = { "", "knee", "" };

fn Quaternionf turn(Vec3 axis, float angle) => quaternion::from_axis_angle{float}(axis.normalize(), angle);

fn Quaternionf root_rotation() => turn({ 0, 1, 0 }, ROOT_YAW);
fn Quaternionf hips_rotation() => turn({ 0, 0, 1 }, HIPS_ROLL);
fn Quaternionf knee_rotation() => turn({ 0, 0, 1 }, KNEE_ROLL);
fn Quaternionf spacer_rotation() => turn({ 0, 1, 0 }, SPACER_ROLL);
fn Quaternionf hips_spun(float amount) => hips_rotation().mul(turn(SPIN_AXIS, amount));
fn Quaternionf knee_swung() => knee_rotation().mul(turn({ 1, 0, 0 }, KNEE_SWING));
fn Quaternionf hips_turned() => hips_rotation().mul(turn(HIPS_TURN_AXIS, HIPS_TURN));

<*
 The root's node transform, written as a matrix rather than as a translation and
 a rotation.

 glTF allows either, and an importer that only reads the second silently
 mis-places everything under a node written the first way — which is what
 several exporters do for the armature. Building it from the same quaternion the
 checks below use means the fixture and the expectation cannot disagree about
 what the matrix means; what is being tested is that it is read back.
*>
fn Matrix4f root_matrix()
{
	Matrix4f m = root_rotation().to_matrix();
	m.m[12] = ROOT_SHIFT.x;
	m.m[13] = ROOT_SHIFT.y;
	m.m[14] = ROOT_SHIFT.z;
	return m;
}

// Where the three joints sit at `time`, worked out here from the fixture's own
// numbers. Deliberately not shared with the importer: a check that recomputed
// the answer with the code under test would only prove that code agrees with
// itself.
fn Vec3[3] fixture_joints(float time, Clip clip = BEND)
{
	Quaternionf root = root_rotation();

	Vec3 hips_local = clip == WALK
		? key_lerp(HIPS_REST, HIPS_REST + WALK_STEP * 0.5f, HIPS_REST + WALK_STEP, time)
		: key_lerp(HIPS_REST, HIPS_DIP, HIPS_REST, time);
	if (clip == SPIN) hips_local = HIPS_REST;

	Quaternionf knee_local = clip == BEND
		? key_slerp(knee_rotation(), knee_swung(), knee_rotation(), time)
		: knee_rotation();

	Quaternionf hips_spin = knee_rotation();
	switch (clip)
	{
		case BEND: hips_spin = key_slerp(hips_rotation(), hips_turned(), hips_rotation(), time);
		case WALK: hips_spin = hips_rotation();
		case SPIN:
			hips_spin = key_slerp(
				hips_rotation(), hips_spun(SPIN_TURN * 0.5f), hips_spun(SPIN_TURN), time);
	}

	Quaternionf hips_world = root.mul(hips_spin);
	Vec3 hips = ROOT_SHIFT + root.rotate_vec3(hips_local);

	Quaternionf spacer_world = hips_world.mul(spacer_rotation());
	Vec3 spacer = hips + hips_world.rotate_vec3(SPACER_OFFSET);

	Quaternionf knee_world = spacer_world.mul(knee_local);
	Vec3 knee = spacer + spacer_world.rotate_vec3(KNEE_OFFSET);

	Vec3 ankle = knee + knee_world.rotate_vec3(ANKLE_OFFSET);

	return { hips, knee, ankle };
}

// The fixture's three keys sit at 0, 0.5 and 1, and glTF slides linearly
// between them — a straight line for a position, the shorter arc for an
// orientation.
fn Vec3 key_lerp(Vec3 a, Vec3 b, Vec3 c, float time)
{
	if (time <= 0.5f) return a + (b - a) * (time / 0.5f);
	return b + (c - b) * ((time - 0.5f) / 0.5f);
}

fn Quaternionf key_slerp(Quaternionf a, Quaternionf b, Quaternionf c, float time)
{
	if (time <= 0.5f) return a.slerp(b, time / 0.5f);
	return b.slerp(c, (time - 0.5f) / 0.5f);
}

<*
 Write the fixture out as a .gltf with its buffer inline.

 Two animations: "bend" turns the knee and dips the hips without going anywhere,
 and "walk" carries the root a step forward so the travel-stripping has
 something to strip.
*>
fn void? write_fixture(String path)
{
	float[66] numbers;
	usz at = 0;

	// 0: the three key times, shared by every sampler.
	numbers[at++] = 0.0f;
	numbers[at++] = 0.5f;
	numbers[at++] = 1.0f;

	// 12: the knee's rotation, out to the swing and back.
	Quaternionf[3] knee = { knee_rotation(), knee_swung(), knee_rotation() };
	foreach (rotation : knee)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	// 60: the hips' translation, dipping and coming back.
	Vec3[3] dip = { HIPS_REST, HIPS_DIP, HIPS_REST };
	foreach (offset : dip)
	{
		numbers[at++] = offset.x;
		numbers[at++] = offset.y;
		numbers[at++] = offset.z;
	}

	// 96: the ankle's scale, held at 1. A Pose has nowhere to put a scale, so
	// this is here to be counted and dropped rather than to do anything.
	for (usz i = 0; i < 3; i++)
	{
		numbers[at++] = 1.0f;
		numbers[at++] = 1.0f;
		numbers[at++] = 1.0f;
	}

	// 132: the hips' translation again, walking forward instead of dipping.
	Vec3[3] walk = { HIPS_REST, HIPS_REST + WALK_STEP * 0.5f, HIPS_REST + WALK_STEP };
	foreach (offset : walk)
	{
		numbers[at++] = offset.x;
		numbers[at++] = offset.y;
		numbers[at++] = offset.z;
	}

	// 168: the hips' rotation, turning and coming back. A joint above another
	// that also moves, which is what tells a parent-relative rotation apart from
	// a world one.
	Quaternionf[3] hips_turn = { hips_rotation(), hips_turned(), hips_rotation() };
	foreach (rotation : hips_turn)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	// 216: the hips pivoting the whole way round.
	Quaternionf[3] hips_pivot = {
		hips_rotation(), hips_spun(SPIN_TURN * 0.5f), hips_spun(SPIN_TURN),
	};
	foreach (rotation : hips_pivot)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	char[] bytes = ((char*)&numbers)[:66 * 4];
	String encoded = base64::encode(mem, bytes);
	defer encoded.free(mem);

	Matrix4f root = root_matrix();
	Quaternionf hips_rest = hips_rotation();
	Quaternionf knee_rest = knee_rotation();
	Quaternionf spacer = spacer_rotation();

	String json = string::format(mem,
		`{
  "asset": { "version": "2.0" },
  "scenes": [ { "nodes": [0] } ],
  "scene": 0,
  "nodes": [
    { "name": "armature", "matrix": [%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f], "children": [1] },
    { "name": "hips", "translation": [%f,%f,%f], "rotation": [%f,%f,%f,%f], "children": [4] },
    { "name": "knee", "translation": [%f,%f,%f], "rotation": [%f,%f,%f,%f], "children": [3] },
    { "name": "ankle", "translation": [%f,%f,%f] },
    { "translation": [%f,%f,%f], "rotation": [%f,%f,%f,%f], "children": [2] }
  ],
  "skins": [ { "joints": [1, 4, 2, 3] } ],
  "buffers": [ { "byteLength": 264, "uri": "data:application/octet-stream;base64,%s" } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,   "byteLength": 12 },
    { "buffer": 0, "byteOffset": 12,  "byteLength": 48 },
    { "buffer": 0, "byteOffset": 60,  "byteLength": 36 },
    { "buffer": 0, "byteOffset": 96,  "byteLength": 36 },
    { "buffer": 0, "byteOffset": 132, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 168, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 216, "byteLength": 48 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0.0], "max": [1.0] },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 4, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 6, "componentType": 5126, "count": 3, "type": "VEC4" }
  ],
  "animations": [
    {
      "name": "bend",
      "samplers": [
        { "input": 0, "output": 1, "interpolation": "LINEAR" },
        { "input": 0, "output": 2, "interpolation": "LINEAR" },
        { "input": 0, "output": 3, "interpolation": "LINEAR" },
        { "input": 0, "output": 5, "interpolation": "LINEAR" }
      ],
      "channels": [
        { "sampler": 0, "target": { "node": 2, "path": "rotation" } },
        { "sampler": 1, "target": { "node": 1, "path": "translation" } },
        { "sampler": 2, "target": { "node": 3, "path": "scale" } },
        { "sampler": 3, "target": { "node": 1, "path": "rotation" } }
      ]
    },
    {
      "name": "walk",
      "samplers": [ { "input": 0, "output": 4, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 1, "path": "translation" } } ]
    },
    {
      "name": "spin",
      "samplers": [ { "input": 0, "output": 6, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 1, "path": "rotation" } } ]
    }
  ]
}`,
		root.m[0], root.m[1], root.m[2], root.m[3],
		root.m[4], root.m[5], root.m[6], root.m[7],
		root.m[8], root.m[9], root.m[10], root.m[11],
		root.m[12], root.m[13], root.m[14], root.m[15],
		HIPS_REST.x, HIPS_REST.y, HIPS_REST.z, hips_rest.v.x, hips_rest.v.y, hips_rest.v.z, hips_rest.v.w,
		KNEE_OFFSET.x, KNEE_OFFSET.y, KNEE_OFFSET.z, knee_rest.v.x, knee_rest.v.y, knee_rest.v.z, knee_rest.v.w,
		ANKLE_OFFSET.x, ANKLE_OFFSET.y, ANKLE_OFFSET.z,
		SPACER_OFFSET.x, SPACER_OFFSET.y, SPACER_OFFSET.z,
		spacer.v.x, spacer.v.y, spacer.v.z, spacer.v.w,
		encoded);
	defer json.free(mem);

	return file::save(path, (char[])json);
}

// ---------------------------------------------------------------------------
// Playing a template the way the app plays it.

<*
 A second copy of a template with every entry's origin forgotten.

 That is exactly a hand-authored template — one that says nothing about the rig
 it was written against — so playing the two side by side is the difference the
 carry makes, with the same code driving both.
*>
fn crig::AnimTemplate without_bones(String path, crig::AnimImportOptions options = {})
{
	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path, options)!!;
	foreach (frame : anim.keyframes)
	{
		foreach (&dot : frame.dots) dot.bone = { 0, 0, 0 };
	}
	return anim;
}

// Where a pose puts each joint. A palette entry carries its own joint's rest
// position to its posed one, so applying it to that position is the answer.
fn Vec3[] posed_joints(rig::Skeleton* skeleton, rig::Pose pose)
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);

	Vec3[] out = alloc::new_array(mem, Vec3, (sz)skeleton.len());
	foreach (usz j, joint : skeleton.joints)
	{
		float[<4>] moved = palette[j].apply({ joint.x, joint.y, joint.z, 1.0f });
		out[j] = { moved.x, moved.y, moved.z };
	}
	return out;
}

// The three-joint chain the fixture rests in, as crig would hold it.
fn rig::Skeleton fixture_skeleton()
{
	Vec3[3] rest = fixture_joints(0.0f);

	Vec3[] joints = alloc::new_array(mem, Vec3, 3);
	int[] parents = alloc::new_array(mem, int, 3);
	joints[HIPS] = rest[HIPS];   parents[HIPS] = -1;
	joints[KNEE] = rest[KNEE];   parents[KNEE] = (int)HIPS;
	joints[ANKLE] = rest[ANKLE]; parents[ANKLE] = (int)KNEE;

	return { .joints = joints, .parents = parents };
}

fn float worst_gap(Vec3[] a, Vec3[3] b)
{
	float worst = 0.0f;
	for (usz i = 0; i < 3; i++)
	{
		float gap = (a[i] - b[i]).length();
		if (gap > worst) worst = gap;
	}
	return worst;
}

fn crig::AnimKeyDot dot_named(crig::AnimKeyframe frame, String name)
{
	foreach (dot : frame.dots)
	{
		if (dot.joint_name == name) return dot;
	}
	return {};
}

// ---------------------------------------------------------------------------
// Checks.

<*
 The whole claim, in one check: an imported template played back through crig's
 posing puts the joints exactly where the source file had them.

 Sampled between the keys as well as on them. On a key it only shows the
 conversion arithmetic is right; between them it also shows the two agree about
 what happens in the gap, which is a separate thing and the one a resampling
 importer would get wrong.
*>
fn void the_conversion_reproduces_the_source() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimImportReport report;
	crig::AnimTemplate? imported = crig::import_gltf_animation(mem, path, {}, &report);
	if (catch imported)
	{
		test::@check(false, "the fixture animation imports at all");
		return;
	}
	crig::AnimTemplate anim = imported;
	defer anim.free(mem);
	test::@check(true, "the fixture animation imports at all");

	test::@check(anim.name == "bend", "the template keeps the animation's name");
	test::@check(report.joints == 3, "all three named joints come across");
	test::@check(report.unnamed_joints == 1, "and the unnamed node between them is left out rather than kept");
	test::@check(report.keyframes == 3, "and the source's three keys stay three keyframes");
	test::@check(report.scale_channels > 0, "the scale channel is reported rather than silently dropped");
	test::@check(!report.stepped && !report.cubic, "a linear source needs no approximating");
	test::@check(math::abs(anim.duration - 1.0f) < EXACT, "the clip is as long as the source");

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	float[5] times = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	float worst = 0.0f;
	foreach (time : times)
	{
		rig::Pose pose = anim.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer pose.free(mem);

		Vec3[] posed = posed_joints(&skeleton, pose);
		defer alloc::free(mem, posed);

		float gap = worst_gap(posed, fixture_joints(time));
		if (gap > worst) worst = gap;
	}

	io::printfn("  worst joint is %.7f from where the source file put it", worst);
	test::@check(worst < EXACT, "the template reproduces the source's own motion");
}

<*
 Asking for extra samples between the source's keys must not cost accuracy.

 Sampling on the keys alone never asks the reader to interpolate — the blend is
 always 0 or 1 — so a curve read with the wrong kind of blend would go unnoticed
 until a spline arrived and needed points in between. Forcing the subdivision
 here exercises that path on a clip whose right answer is known.
*>
fn void extra_samples_stay_exact() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimImportReport report;
	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path, { .subdivide = 4 }, &report)!!;
	defer anim.free(mem);

	test::@check(report.keyframes > 3, "asking for subdivision produces more keyframes than the source had");

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	float[4] times = { 0.125f, 0.375f, 0.625f, 0.875f };
	float worst = 0.0f;
	foreach (time : times)
	{
		rig::Pose pose = anim.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer pose.free(mem);

		Vec3[] posed = posed_joints(&skeleton, pose);
		defer alloc::free(mem, posed);

		float gap = worst_gap(posed, fixture_joints(time));
		if (gap > worst) worst = gap;
	}

	io::printfn("  subdivided into %d keyframes, worst joint is %.7f out", report.keyframes, worst);
	test::@check(worst < EXACT, "the extra samples land on the source's own curve");
}

<*
 The joint the source never moves must not move here either.

 Easy to pass by accident and easy to fail loudly: an off-by-one in the joint
 ordering, or a parent-relative rotation left in world terms, both show up as a
 hip that drifts while only the knee was asked to bend.
*>
fn void an_unanimated_joint_stays_put() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	rig::Pose pose = anim.pose(mem, &skeleton, JOINT_NAMES[..], 0.5f);
	defer pose.free(mem);

	Vec3[] posed = posed_joints(&skeleton, pose);
	defer alloc::free(mem, posed);

	// The hips are dipped by the source, so they should have moved; the knee
	// hangs off them and moves with them. Only the ankle is driven by a rotation.
	float hips_moved = (posed[HIPS] - skeleton.joints[HIPS]).length();
	float ankle_moved = (posed[ANKLE] - skeleton.joints[ANKLE]).length();

	test::@check(hips_moved > 0.05f, "the dip in the source moves the hips");
	test::@check(ankle_moved > 0.1f, "and the bend swings the ankle");
}

<*
 A source track at rest is retained as an explicit rest key.

 Everything below rests at an angle, so a conversion that forgot to cancel the
 rest pose must still contain identity values rather than the bone rotations
 themselves mistaken for motion. Keeping the entries is what prevents sparse
 sampling from holding the later bend backwards over the opening interval.
*>
fn void rest_converts_to_nothing() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	foreach (dot : anim.keyframes[0].dots)
	{
		test::@check(math::abs(dot.angle) < EXACT && dot.move.length() < EXACT,
			"the source rest key contains only explicit rest values");
	}
	test::@check(anim.keyframes[0].dots.len > 0,
		"animated source tracks retain an explicit opening rest key");

	crig::AnimKeyDot knee = dot_named(anim.keyframes[1], "knee");
	test::@check(knee.joint_name.len > 0, "the keyframe at the bend does name the knee");
	test::@check(math::abs(knee.angle - KNEE_SWING) < EXACT, "and turns it by the angle the source did");
	io::printfn("  the knee is imported as %.5f radians, authored as %.5f", knee.angle, KNEE_SWING);
}

<*
 The rest-pose problem, and the fix for it.

 A world-axis rotation is only meaningful next to the rig it was written
 against. The target here has its lower bone laid along the very axis the knee
 turns about, which is the worst case: turning a bone about its own length moves
 nothing at all. Played as stored, the ankle sits still. Carried onto the new
 bone, it sweeps the full arc.

 The axis is read out of the template rather than worked out again, because what
 is being built here is a target rig, not an expectation.
*>
fn void a_template_carries_onto_a_differently_posed_rig() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	Vec3 axis = dot_named(anim.keyframes[1], "knee").axis;

	Vec3[] joints = alloc::new_array(mem, Vec3, 3);
	int[] parents = alloc::new_array(mem, int, 3);
	joints[HIPS] = { 0, 1.0f, 0 };                        parents[HIPS] = -1;
	joints[KNEE] = { 0, 0.5f, 0 };                        parents[KNEE] = (int)HIPS;
	joints[ANKLE] = joints[KNEE] + axis * 0.4f;           parents[ANKLE] = (int)KNEE;
	rig::Skeleton target = { .joints = joints, .parents = parents };
	defer target.free(mem);

	// Measured from the knee, so the hips' dip — which is a translation and has
	// no axis to carry — does not count as the ankle moving.
	Vec3 rest_reach = target.joints[ANKLE] - target.joints[KNEE];

	crig::AnimTemplate stored = without_bones(path);
	defer stored.free(mem);

	rig::Pose plain = stored.pose(mem, &target, KNEE_ONLY[..], 0.5f);
	defer plain.free(mem);
	Vec3[] plain_posed = posed_joints(&target, plain);
	defer alloc::free(mem, plain_posed);
	float plain_swing = ((plain_posed[ANKLE] - plain_posed[KNEE]) - rest_reach).length();

	rig::Pose carried = anim.pose(mem, &target, KNEE_ONLY[..], 0.5f);
	defer carried.free(mem);
	Vec3[] carried_posed = posed_joints(&target, carried);
	defer alloc::free(mem, carried_posed);
	float carried_swing = ((carried_posed[ANKLE] - carried_posed[KNEE]) - rest_reach).length();

	// A bone of length L turned through an angle sweeps a chord of 2L sin(a/2).
	float expected = 2.0f * 0.4f * math::sin(KNEE_SWING * 0.5f);

	io::printfn("  the ankle swings %.5f as stored and %.5f carried across, against %.5f authored",
		plain_swing, carried_swing, expected);
	test::@check(plain_swing < 1.0e-5f, "played as stored, a bone turned about its own length does not move");
	test::@check(math::abs(carried_swing - expected) < EXACT, "carried onto the new bone it sweeps the full arc");
}

<*
 And on a rig that matches the source, carrying the axes across must change
 nothing whatsoever.

 The cheaper half of the same property, and the one that keeps the hand-written
 templates safe: a correction computed between two identical bones has to come
 out as the identity rather than as something small.
*>
fn void the_carry_is_nothing_on_a_matching_rig() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	crig::AnimTemplate stored = without_bones(path);
	defer stored.free(mem);

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	float worst = 0.0f;
	float[3] times = { 0.25f, 0.5f, 0.75f };
	foreach (time : times)
	{
		rig::Pose plain = stored.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer plain.free(mem);
		Vec3[] plain_posed = posed_joints(&skeleton, plain);
		defer alloc::free(mem, plain_posed);

		rig::Pose carried = anim.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer carried.free(mem);
		Vec3[] carried_posed = posed_joints(&skeleton, carried);
		defer alloc::free(mem, carried_posed);

		for (usz j = 0; j < 3; j++)
		{
			float gap = (plain_posed[j] - carried_posed[j]).length();
			if (gap > worst) worst = gap;
		}
	}

	io::printfn("  on the rig it came from, carrying the axes moves a joint by %.8f", worst);
	test::@check(worst < 1.0e-5f, "a template played on its own rig is untouched by the carry");
}

<*
 A joint whose bone the two rigs agree about lands exactly where the clip put
 it, however differently its parent's bone is aimed.

 The property that makes a carry compose down a chain, and the one it is easiest
 to write code that lacks. A template holds parent-relative rotations while the
 correction a joint gets is stated in world axes, so carrying an entry where it
 sits — conjugating a parent-relative rotation by its own joint's correction —
 leaves the parent's correction standing between the two, and every link picks up
 a spurious `carry(parent)^-1 * carry(joint)`. Those compound downward, and a
 pair of rigs needing almost no correction anywhere comes out worst of all,
 because there the spurious turn is the entire difference between them.

 The rig here moves the hips and nothing else, so the hips' bone is aimed
 somewhere new while the knee's and the ankle's are untouched. Their corrections
 are therefore the identity and their posed bones have to match the source's to
 the last digit; anything the hips' correction leaks is the whole of the gap.
*>
fn void a_carry_does_not_leak_down_the_chain() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	rig::Skeleton source = fixture_skeleton();
	defer source.free(mem);

	// The hips alone: moving anything below it would re-aim the knee's bone too,
	// and then no joint would be left whose correction is known to be nothing.
	rig::Skeleton target = fixture_skeleton();
	defer target.free(mem);
	target.joints[HIPS] = target.joints[HIPS] + (Vec3){ 0.4f, 0.0f, 0.35f };

	Vec3[] source_bones = source.bone_directions(mem);
	defer alloc::free(mem, source_bones);
	Vec3[] target_bones = target.bone_directions(mem);
	defer alloc::free(mem, target_bones);

	float aimed = math::acos(math::clamp(source_bones[HIPS].dot(target_bones[HIPS]), -1.0f, 1.0f));

	io::printfn("  the hips' bone is aimed %.1f degrees apart, the knee's %.8f",
		aimed * 180.0f / (float)math::PI, (source_bones[KNEE] - target_bones[KNEE]).length());
	test::@check(aimed > 0.3f, "the two rigs really do want different corrections at the hips");
	test::@check((source_bones[KNEE] - target_bones[KNEE]).length() < 1.0e-6f, "and the same one at the knee");

	float worst = 0.0f;
	float[3] times = { 0.25f, 0.5f, 0.75f };
	foreach (time : times)
	{
		rig::Pose here = anim.pose(mem, &source, JOINT_NAMES[..], time);
		defer here.free(mem);
		Vec3[] source_posed = posed_joints(&source, here);
		defer alloc::free(mem, source_posed);

		rig::Pose there = anim.pose(mem, &target, JOINT_NAMES[..], time);
		defer there.free(mem);
		Vec3[] target_posed = posed_joints(&target, there);
		defer alloc::free(mem, target_posed);

		// The shin as a vector: the knee's world turn applied to a rest segment
		// both rigs share, which is that turn read off the positions. Measured as
		// a segment rather than as two points because the hips moved, so where the
		// knee itself sits is expected to differ and says nothing about the carry.
		Vec3 shin = source_posed[ANKLE] - source_posed[KNEE];
		Vec3 carried = target_posed[ANKLE] - target_posed[KNEE];
		float gap = (shin - carried).length();
		if (gap > worst) worst = gap;
	}

	io::printfn("  the shin lands %.8f from where the clip put it", worst);
	test::@check(worst < EXACT, "a joint's own carry is all it gets, not its parent's as well");
}

<*
 Offsets are fractions of rig height, so the same clip dips a figure twice the
 size by twice as much.

 crig opens whatever .glb it is handed, at whatever scale it was exported at. An
 offset stored in the source's own units would be a dip of a few centimetres on
 everything, invisible on a large mesh and a collapse on a small one.
*>
fn void an_offset_scales_with_the_target() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	rig::Skeleton small = fixture_skeleton();
	defer small.free(mem);

	rig::Skeleton large = fixture_skeleton();
	defer large.free(mem);
	foreach (&joint : large.joints) *joint = *joint * 10.0f;

	rig::Pose small_pose = anim.pose(mem, &small, JOINT_NAMES[..], 0.5f);
	defer small_pose.free(mem);
	rig::Pose large_pose = anim.pose(mem, &large, JOINT_NAMES[..], 0.5f);
	defer large_pose.free(mem);

	Vec3[] small_posed = posed_joints(&small, small_pose);
	defer alloc::free(mem, small_posed);
	Vec3[] large_posed = posed_joints(&large, large_pose);
	defer alloc::free(mem, large_posed);

	Vec3 small_dip = small_posed[HIPS] - small.joints[HIPS];
	Vec3 large_dip = large_posed[HIPS] - large.joints[HIPS];

	float error = (large_dip - small_dip * 10.0f).length();
	io::printfn("  the dip is %.5f on the rig and %.5f on one ten times its size",
		small_dip.length(), large_dip.length());
	test::@check(small_dip.length() > 1.0e-3f, "the clip dips the small rig");
	test::@check(error < EXACT * 10.0f, "and dips a rig ten times the size by ten times as much");
}

<*
 A pivot past half a circle comes back as a pivot, not as its mirror.

 Every rotation has two quaternions and every axis-and-angle pair has a choice
 of sign. Below half a turn the choice never shows; past it the shorter reading
 is the one going the other way, and taking it without turning the axis round
 leaves a figure pivoting backwards — which looks deliberate rather than broken,
 and so would survive being watched.
*>
fn void a_pivot_past_half_a_circle_survives() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate spin = crig::import_gltf_animation(mem, path, { .name = "spin" })!!;
	defer spin.free(mem);

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	float[3] times = { 0.4f, 0.7f, 1.0f };
	float worst = 0.0f;
	foreach (time : times)
	{
		rig::Pose pose = spin.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer pose.free(mem);

		Vec3[] posed = posed_joints(&skeleton, pose);
		defer alloc::free(mem, posed);

		float gap = worst_gap(posed, fixture_joints(time, SPIN));
		if (gap > worst) worst = gap;
	}

	io::printfn("  pivoting %.2f radians, the worst joint is %.7f out", SPIN_TURN, worst);
	test::@check(worst < EXACT, "a pivot the long way round still lands where the source put it");

	// Turning the axis round and leaving the angle alone is a second, equally
	// wrong reading that lands in the same place, so the joints above cannot tell
	// the two apart. What only the shorter one gives is an angle under half a
	// circle — which is what lets the emit loop recognize a joint that hardly
	// turned, since a turn read the long way round is never near zero.
	crig::AnimKeyDot hips = dot_named(spin.keyframes[spin.keyframes.len - 1], "hips");
	float shortest = (float)math::TAU - SPIN_TURN;
	io::printfn("  and the pivot itself is written as %.5f radians", hips.angle);
	test::@check(math::abs(hips.angle - shortest) < EXACT, "and is written as the turn under half a circle");
}

<*
 A clip that walks forward has to come back, or it plays once and leaves.

 The travel is taken out in proportion to how far through the clip each sample
 is, which removes the drift and keeps whatever the root did around it.
*>
fn void root_travel_comes_off() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimImportReport report;
	crig::AnimTemplate walk = crig::import_gltf_animation(mem, path, { .name = "walk" }, &report)!!;
	defer walk.free(mem);

	test::@check(report.travel_removed, "a clip that travels is reported as having been brought back");
	io::printfn("  the source carried its root %.4f before it was taken off", report.root_travel.length());
	test::@check(report.root_travel.length() > 0.5f, "and the travel it reports is the step the source took");

	Vec3 first = walk.keyframes[0].offset_of("hips");
	Vec3 last = walk.keyframes[walk.keyframes.len - 1].offset_of("hips");
	test::@check((last - first).length() < EXACT, "the root ends the clip where it started it");

	crig::AnimTemplate kept = crig::import_gltf_animation(
		mem, path, { .name = "walk", .keep_root_travel = true })!!;
	defer kept.free(mem);

	Vec3 kept_first = kept.keyframes[0].offset_of("hips");
	Vec3 kept_last = kept.keyframes[kept.keyframes.len - 1].offset_of("hips");
	test::@check((kept_last - kept_first).length() > 0.1f, "and asking to keep the travel keeps it");
}

<*
 Naming an animation that is not there, or none at all, has to answer rather
 than guess.
*>
fn void a_missing_animation_is_refused() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate? missing = crig::import_gltf_animation(mem, path, { .name = "sprint" });
	test::@check(@ok(missing) == false, "asking for an animation the file does not have is refused");

	crig::AnimTemplate? past_the_end = crig::import_gltf_animation(mem, path, { .index = 7 });
	test::@check(@ok(past_the_end) == false, "and so is an index past the end");
}

<*
 A second, much smaller fixture: a rig lying flat, with nothing above anything
 else.

 Plenty of real rigs are like this — a pair of wheels on an axle is a whole
 animation — and height is only ever the unit an offset is measured in. A clip
 that turns things needs no unit; one that moves them cannot do without.
*>
fn void? write_flat_fixture(String path)
{
	float[24] numbers;
	usz at = 0;

	numbers[at++] = 0.0f;
	numbers[at++] = 0.5f;
	numbers[at++] = 1.0f;

	Quaternionf[3] roll = { quaternion::IDENTITY, turn({ 1, 0, 0 }, 1.2f), turn({ 1, 0, 0 }, 2.4f) };
	foreach (rotation : roll)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	Vec3[3] shift = { { 0, 0, 0 }, { 0.5f, 0, 0 }, { 1.0f, 0, 0 } };
	foreach (offset : shift)
	{
		numbers[at++] = offset.x;
		numbers[at++] = offset.y;
		numbers[at++] = offset.z;
	}

	char[] bytes = ((char*)&numbers)[:24 * 4];
	String encoded = base64::encode(mem, bytes);
	defer encoded.free(mem);

	String json = string::format(mem,
		`{
  "asset": { "version": "2.0" },
  "scenes": [ { "nodes": [0] } ],
  "scene": 0,
  "nodes": [
    { "name": "hub", "translation": [0,0,0], "children": [1] },
    { "name": "spoke", "translation": [1,0,0] }
  ],
  "skins": [ { "joints": [0, 1] } ],
  "buffers": [ { "byteLength": 96, "uri": "data:application/octet-stream;base64,%s" } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,  "byteLength": 12 },
    { "buffer": 0, "byteOffset": 12, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 60, "byteLength": 36 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0.0], "max": [1.0] },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC3" }
  ],
  "animations": [
    {
      "name": "roll",
      "samplers": [ { "input": 0, "output": 1, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 0, "path": "rotation" } } ]
    },
    {
      "name": "shift",
      "samplers": [ { "input": 0, "output": 2, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 0, "path": "translation" } } ]
    },
    {
      "name": "click",
      "samplers": [ { "input": 0, "output": 1, "interpolation": "STEP" } ],
      "channels": [ { "sampler": 0, "target": { "node": 0, "path": "rotation" } } ]
    }
  ]
}`, encoded);
	defer json.free(mem);

	return file::save(path, (char[])json);
}

<*
 A rig with no height carries a turn and refuses a slide.

 Refusing both would turn away a legitimate clip over a field it never uses;
 accepting both would divide by nothing and hand back offsets that are not
 numbers.
*>
fn void a_flat_rig_turns_but_does_not_slide() @test
{
	String path = FLAT_FIXTURE;
	if (catch write_flat_fixture(path))
	{
		test::@check(false, "the flat fixture could be written");
		return;
	}

	crig::AnimImportReport report;
	crig::AnimTemplate? rolled = crig::import_gltf_animation(mem, path, { .name = "roll" }, &report);
	if (catch rolled)
	{
		test::@check(false, "a flat rig can still carry a clip that only turns things");
		return;
	}
	crig::AnimTemplate roll = rolled;
	defer roll.free(mem);

	test::@check(true, "a flat rig can still carry a clip that only turns things");
	test::@check(report.height == 0.0f, "and the report says plainly that it has no height");

	bool still = true;
	foreach (frame : roll.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.move.length() != 0.0f) still = false;
		}
	}
	test::@check(still, "with every offset left at zero rather than divided by nothing");

	crig::AnimTemplate? slid = crig::import_gltf_animation(mem, path, { .name = "shift" });
	test::@check(@ok(slid) == false, "but a clip that moves it is refused, having no unit to measure by");
}

<*
 A STEP sampler becomes an authored HOLD segment, preserving the discontinuity
 without filling the clip with just-before-the-key approximation samples.
*>
fn void a_held_value_stays_held() @test
{
	String path = FLAT_FIXTURE;
	if (catch fault error = write_flat_fixture(path))
	{
		test::@check(false, "could not write %s (%s)", path, error);
		return;
	}

	crig::AnimImportReport report;
	crig::AnimTemplate click = crig::import_gltf_animation(mem, path, { .name = "click" }, &report)!!;
	defer click.free(mem);

	test::@check(report.stepped, "a stepped source is reported as one");
	test::eq(report.keyframes, (usz)3);
	test::@check(click.keyframes[0].dots[0].rotation_interpolation == crig::AnimInterpolation.HOLD,
		"the STEP sampler did not become an outgoing Hold segment");

	// The last keyframe before the source's key at 0.5, and the one on it.
	float held_angle = 0.0f;
	float stepped_angle = 0.0f;
	float held_time = 0.0f;
	foreach (frame : click.keyframes)
	{
		if (frame.time < 0.5f - 1.0e-4f && frame.time >= held_time)
		{
			held_time = frame.time;
			held_angle = dot_named(frame, "hub").angle;
		}
		if (math::abs(frame.time - 0.5f) < 1.0e-4f) stepped_angle = dot_named(frame, "hub").angle;
	}

	io::printfn("  at %.4f the hub still reads %.4f, and at 0.5000 it reads %.4f",
		held_time, held_angle, stepped_angle);
	test::@check(held_time == 0.0f, "the held curve gained approximation samples");
	test::@check(math::abs(held_angle) < EXACT, "and still carries the value from before the step");
	test::@check(math::abs(stepped_angle - 1.2f) < EXACT, "while the key itself carries the value after it");
}

<*
 Import from a real file and say what came out.

 The fixture is built to be checkable, which means it is also tidy in ways real
 exports are not: it always has a skin, every node is named, nothing is scaled.
 A file off disk is where the guesses get tested — the joint-finding without a
 skin, the odd node written as a matrix, the clip that turns things without ever
 moving them.
*>
fn void a_real_file_imports() @test
{
	String path = REAL_PACK;
	io::printfn("real file: %s", path);

	// Offered the biped plan, because the question a real file is being asked here
	// is whether it can be matched onto one — a run with no plans could only ever
	// report the names the file already had.
	crig::Preset plan = match_plan();
	crig::Preset[1] plans = { plan };

	crig::AnimImportReport report;
	crig::AnimTemplate? imported = crig::import_gltf_animation(
		mem, path, { .plans = plans[..] }, &report);
	if (catch err = imported)
	{
		io::printfn("  no animation could be taken from it: %s", err);
		return;
	}
	crig::AnimTemplate anim = imported;
	defer anim.free(mem);

	io::printfn("  \"%s\": %.3fs, %d joints over %d keyframes, rig height %.4f",
		anim.name, anim.duration, report.joints, report.keyframes, report.height);
	if (report.unnamed_joints > 0) io::printfn("  %d unnamed joints left out", report.unnamed_joints);
	if (report.scale_channels > 0) io::printfn("  %d scale channels dropped", report.scale_channels);
	if (report.stepped) io::printn("  stepped curves preserved as holds");
	if (report.cubic) io::printn("  spline curves sampled");
	if (report.scaled_rest) io::printn("  a joint rests scaled, so its axes are approximate");
	if (report.travel_removed) io::printfn("  %.4f of travel taken off the root", report.root_travel.length());

	// The first thing to look at when a downloaded clip greys out in the library:
	// unmatched, its joints keep names no crig rig has, and no amount of correct
	// conversion will make it move anything.
	if (report.plan_matched.len > 0)
	{
		io::printfn("  shaped like %s: %d dots filled, %d links folded in%s",
			report.plan_matched, report.matched_joints, report.folded_joints,
			report.folded_animated ? ", subdivided to keep the folds exact" : "");
	}
	else
	{
		io::printn("  no body plan matched — the joints keep the names the file gave them");
	}

	// Which is the only question that matters about a download, so it is asked
	// here rather than left to be noticed on screen.
	usz on_plan = 0;
	foreach (dot : anim.keyframes[0].dots)
	{
		foreach (want : match_plan_dots)
		{
			if (dot.joint_name == want.name) on_plan++;
		}
	}
	io::printfn("  %d of the biped plan's %d dots are named by its first keyframe",
		on_plan, match_plan_dots.len);

	test::@check(report.joints > 0, "the file yields at least one named joint");
	test::@check(anim.duration > 0.0f, "and a clip with some length to it");

	usz turning = 0;
	bool sane = true;
	foreach (frame : anim.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.angle != dot.angle || dot.move.x != dot.move.x) sane = false;
			if (math::abs(dot.angle) > 0.0f) turning++;
		}
	}
	test::@check(sane, "with no entry that came out as a NaN");
	io::printfn("  %d entries turn a joint", turning);
}

// ---------------------------------------------------------------------------
// Writing one back out.

// A template built here rather than imported, so the round trip below starts
// from something that was never in a file.
const crig::AnimKeyDot[] SENT_OUT = {
	{ .joint_name = "knee", .axis = { 1, 0, 0 }, .angle = 0.5f },
	{ .joint_name = "hips", .move = { 0, -0.05f, 0 } },
};

const crig::AnimKeyDot[] SENT_BACK = {
	{ .joint_name = "knee", .axis = { 0, 1, 0 }, .angle = -0.3f },
	{ .joint_name = "hips", .move = { 0.02f, 0, 0 } },
};

const crig::AnimKeyframe[] SENT_FRAMES = {
	{ .time = 0.00f, .dots = SENT_OUT[..] },
	{ .time = 0.50f, .dots = SENT_BACK[..] },
	{ .time = 1.00f, .dots = SENT_OUT[..] },
};

<*
 A template survives being written to a .glb and read back.

 The two conversions are separate code — one composes a world rotation out of a
 node chain, the other takes it apart again — so agreeing at every joint at
 every instant is a statement about both of them rather than about a shared
 helper being called twice.

 Run at four name lengths. The name goes in the JSON, so it moves the chunk's
 length, and one of any four consecutive lengths is not a multiple of four —
 which is the case the container has to be padded for and the only case where
 forgetting shows up at all.
*>
fn void a_template_survives_being_written_out() @test
{
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	String[4] names = { "clip", "clipp", "clippe", "clipped" };
	float worst = 0.0f;
	usz failures_here = 0;

	foreach (usz i, name : names)
	{
		String path = string::format(mem, "build/anim-export-%d.glb", i);
		defer path.free(mem);

		crig::AnimTemplate sent = {
			.name = name,
			.duration = 1.0f,
			.keyframes = SENT_FRAMES[..],
			.loop = true,
		};
		crig::AnimTemplate[1] library = { sent };

		if (catch crig::export_animations_glb(mem, path, &skeleton, JOINT_NAMES[..], library[..]))
		{
			failures_here++;
			continue;
		}
		if (!glb_is_well_formed(path)) failures_here++;

		crig::AnimTemplate? read_back = crig::import_gltf_animation(mem, path);
		if (catch read_back)
		{
			failures_here++;
			continue;
		}
		crig::AnimTemplate back = read_back;
		defer back.free(mem);

		if (back.name != name) failures_here++;

		for (usz step = 0; step <= 20; step++)
		{
			float time = (float)step / 20.0f;

			rig::Pose there = sent.pose(mem, &skeleton, JOINT_NAMES[..], time);
			defer there.free(mem);
			rig::Pose here = back.pose(mem, &skeleton, JOINT_NAMES[..], time);
			defer here.free(mem);

			Vec3[] sent_at = posed_joints(&skeleton, there);
			defer alloc::free(mem, sent_at);
			Vec3[] back_at = posed_joints(&skeleton, here);
			defer alloc::free(mem, back_at);

			for (usz j = 0; j < 3; j++)
			{
				float gap = (sent_at[j] - back_at[j]).length();
				if (gap > worst) worst = gap;
			}
		}
	}

	io::printfn("  written and read back at four name lengths, worst joint %.7f out", worst);
	test::@check(failures_here == 0, "a template writes out and reads back at any name length");
	test::@check(worst < EXACT, "and puts the rig exactly where it did before");
}

const crig::AnimKeyDot[] SPARSE_ROT_A = {
	{ .joint_name = "knee", .axis = { 1, 0, 0 }, .angle = 0.25f, .channels = ROTATION,
		.rotation_interpolation = crig::AnimInterpolation.HOLD },
};
const crig::AnimKeyDot[] SPARSE_MOVE = {
	{ .joint_name = "hips", .move = { 0.1f, 0, 0 }, .channels = TRANSLATION },
};
const crig::AnimKeyDot[] SPARSE_ROT_B = {
	{ .joint_name = "knee", .axis = { 1, 0, 0 }, .angle = -0.4f, .channels = ROTATION },
};
const crig::AnimKeyframe[] SPARSE_FRAMES = {
	{ .time = 0.0f, .dots = SPARSE_ROT_A[..] },
	{ .time = 0.5f, .dots = SPARSE_MOVE[..] },
	{ .time = 1.0f, .dots = SPARSE_ROT_B[..] },
};

fn void sparse_channels_survive_gltf_roundtrip() @test
{
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);
	crig::AnimTemplate sent = { .name = "Sparse", .duration = 1.25f,
		.keyframes = SPARSE_FRAMES[..], .loop = true };
	crig::AnimTemplate[1] clips = { sent };
	String path = "build/anim-sparse-roundtrip.glb";
	if (catch crig::export_animations_glb(mem, path, &skeleton, JOINT_NAMES[..], clips[..]))
	{
		test::@check(false, "sparse clip export failed");
		return;
	}
	crig::AnimPack? read = crig::read_pack(mem, path);
	if (catch read) { test::@check(false, "sparse pack re-import failed"); return; }
	crig::AnimPack pack = read;
	defer pack.free(mem);
	if (pack.clips.len == 0) { test::@check(false, "sparse pack had no clip"); return; }
	crig::AnimTemplate back = pack.clips[0];
	test::@check(back.keyframes[0].dots[0].rotation_interpolation == crig::AnimInterpolation.HOLD,
		"pack metadata lost the held outgoing segment");
	foreach (frame : back.keyframes)
	{
		bool knee = false;
		bool hips = false;
		foreach (dot : frame.dots)
		{
			if (dot.joint_name == "knee") knee = dot.channels == ROTATION;
			if (dot.joint_name == "hips") hips = dot.channels == TRANSLATION;
		}
		bool expected_knee = math::abs(frame.time) < 0.0001f || math::abs(frame.time - 1.0f) < 0.0001f;
		bool expected_hips = math::abs(frame.time - 0.5f) < 0.0001f;
		test::@check(knee == expected_knee && hips == expected_hips,
			"re-import changed the sparse key schedule at %.3f", frame.time);
	}
	for (usz step = 0; step <= 20; step++)
	{
		float time = sent.duration * (float)step / 20.0f;
		rig::Pose expected = sent.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer expected.free(mem);
		rig::Pose actual = back.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer actual.free(mem);
		float turn_gap = 1.0f - math::abs(expected.rotations[KNEE].v.dot(actual.rotations[KNEE].v));
		float move_gap = (expected.offsets[0] - actual.offsets[0]).length();
		if (turn_gap >= 0.0001f || move_gap >= 0.0001f)
		{
			io::printfn("sparse %.3f turn %.6f move %.6f", time, turn_gap, move_gap);
		}
		test::@check(turn_gap < 0.0001f && move_gap < 0.0001f,
			"sparse glTF replay changed at %.3f", time);
	}
}

<*
 A pack whose keys key every joint on both channels writes each such key as
 `"dots":"all"` against one list of the clip's joints, and reads back the same
 schedule. And a joint that holds one value the whole clip — the knee, turned
 and left there — is one key in the file, while the moving hips keep theirs.
*>
fn void a_whole_pose_key_writes_short_and_a_held_joint_one_key() @test
{
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);
	const usz KEYS = 4;
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, KEYS);
	for (usz k = 0; k < KEYS; k++)
	{
		float f = (float)k / (float)(KEYS - 1);
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 3);
		dots[0] = { .joint_name = "hips".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.5f * f, .move = { 0, k == 1 || k == 2 ? 0.05f : 0.0f, 0 } };
		dots[1] = { .joint_name = "knee".copy(mem), .axis = { 1, 0, 0 }, .angle = 0.3f };
		dots[2] = { .joint_name = "ankle".copy(mem), .axis = { 1, 0, 0 }, .angle = k % 2 == 0 ? 0.0f : 0.2f };
		frames[k] = { .time = f, .dots = dots };
	}
	crig::AnimTemplate sent = { .name = "Whole".copy(mem), .duration = 1.0f, .keyframes = frames, .owned = true };
	defer sent.free(mem);
	crig::AnimTemplate[1] clips = { sent };

	String text = crig::clip_extras_text(mem, clips[..]);
	defer if (text.len > 0) text.free(mem);
	test::@check(text.contains(`"dots":"all"`) && text.contains(`"keyed":[`), "the whole-pose keys were spelled out: %s", text);
	test::@check(!text.contains(`"joint":"knee"`), "a whole-pose key still lists its joints: %s", text);

	String elsewhere = crig::clip_extras_text(mem, clips[..], { "Whole" });
	defer if (elsewhere.len > 0) elsewhere.free(mem);
	test::@check(!elsewhere.contains(`"sparse"`) && elsewhere.contains(`"duration"`),
		"a clip scheduled in the sidecar still wrote its keys: %s", elsewhere);

	String path = "build/anim-whole-pose.glb";
	if (catch crig::export_animations_glb(mem, path, &skeleton, JOINT_NAMES[..], clips[..]))
	{
		test::@check(false, "whole-pose clip export failed");
		return;
	}

	gltf::GltfStream? opened = gltf::open(path, mem);
	if (catch opened) { test::@check(false, "could not open the written pack"); return; }
	gltf::GltfStream stream = opened;
	defer stream.close();
	gltf::Animation anim = stream.gltf.animations[0];
	usz held = 0;
	usz moving = 0;
	foreach (channel : anim.channels)
	{
		usz keys = (usz)stream.gltf.accessors[anim.samplers[(sz)channel.sampler].input].count;
		bool knee = channel.target.node == (uint)KNEE;
		if (knee && channel.target.path == gltf::AnimationProperty.ROTATION) test::@check(keys == 1, "the held knee wrote %d keys", keys);
		if (keys == 1) { held++; } else { moving++; }
	}
	test::@check(held >= 1 && moving >= 2, "%d held and %d moving channels", held, moving);

	crig::AnimPack? read = crig::read_pack(mem, path);
	if (catch read) { test::@check(false, "whole-pose pack re-import failed"); return; }
	crig::AnimPack pack = read;
	defer pack.free(mem);
	crig::AnimTemplate back = pack.clips[0];
	test::@check(back.keyframes.len == KEYS, "re-import has %d keys", back.keyframes.len);
	foreach (frame : back.keyframes)
	{
		test::@check(frame.dots.len == 3, "a key came back with %d joints", frame.dots.len);
		foreach (dot : frame.dots) test::@check(dot.channels == BOTH, "%s lost a channel", dot.joint_name);
	}
	for (usz step = 0; step <= 20; step++)
	{
		float time = (float)step / 20.0f;
		rig::Pose expected = sent.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer expected.free(mem);
		rig::Pose actual = back.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer actual.free(mem);
		for (usz j = 0; j < 3; j++)
		{
			float turn_gap = 1.0f - math::abs(expected.rotations[j].v.dot(actual.rotations[j].v));
			float move_gap = (expected.offsets[j] - actual.offsets[j]).length();
			test::@check(turn_gap < 0.0001f && move_gap < 0.0001f, "joint %d changed at %.3f: turn %f move %f", j, time, turn_gap, move_gap);
		}
	}
}

fn void malformed_sparse_pack_metadata_keeps_gltf_channels() @test
{
	crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 1);
	dots[0] = { .joint_name = "knee".copy(mem), .axis = { 1, 0, 0 },
		.angle = 0.4f, .channels = ROTATION };
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, 1);
	frames[0] = { .time = 0.0f, .dots = dots };
	crig::AnimTemplate[] clips = alloc::new_array(mem, crig::AnimTemplate, 1);
	clips[0] = { .name = "clip".copy(mem), .duration = 1.0f,
		.keyframes = frames, .owned = true };
	defer crig::free_animations(mem, clips);

	crig::apply_clip_extras(mem, clips,
		`{"clip":{"sparse":[{"time":-1,"dots":[{"joint":"missing","channels":"rotation"}]}]}}`);
	test::@check(clips[0].keyframes[0].dots.len == 1
		&& clips[0].keyframes[0].dots[0].joint_name == "knee"
		&& clips[0].keyframes[0].dots[0].channels == ROTATION,
		"invalid sparse metadata pruned ordinary glTF channels");
}

// A clip that slides a joint with a parent. `SENT_FRAMES` moves only "hips",
// which is the root, and a root's translation channel is the joint's own
// position — so every check above passes whether the writer subtracts the
// parent or not.
const crig::AnimKeyDot[] KNEE_SLID = {
	{ .joint_name = "knee", .move = { 0.15f, -0.08f, 0.06f } },
};

const crig::AnimKeyframe[] KNEE_SLIDE_FRAMES = {
	{ .time = 0.00f, .dots = {} },
	{ .time = 0.50f, .dots = KNEE_SLID[..] },
	{ .time = 1.00f, .dots = {} },
};

<*
 A joint with a parent lands where it was slid to, not where its parent is.

 A glTF node's translation is relative to its parent, and crig's offsets are not
 — so the writer subtracts the parent joint on the way out and the reader adds it
 back. Nothing else here catches that: every other fixture clip slides only the
 root, whose parent-relative translation and world position are the same vector,
 so a writer that skipped the subtraction entirely would round-trip perfectly.

 Only the ankle is checked as well as the knee, because the error compounds: a
 knee written in the wrong frame carries its whole subtree with it, and a check
 that stopped at the joint that moved would miss half of what went wrong.
*>
fn void a_slid_joint_keeps_its_parent_out_of_it() @test
{
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	String path = "build/anim-knee-slide.glb";
	crig::AnimTemplate sent = {
		.name = "Slide",
		.duration = 1.0f,
		.keyframes = KNEE_SLIDE_FRAMES[..],
		.loop = true,
	};
	crig::AnimTemplate[1] library = { sent };

	if (catch fault error = crig::export_animations_glb(mem, path, &skeleton, JOINT_NAMES[..], library[..]))
	{
		test::@check(false, "SKIPPED — the writer refused a clip that slides a knee (%s)", error);
		return;
	}

	crig::AnimTemplate? read_back = crig::import_gltf_animation(mem, path);
	if (catch read_back)
	{
		test::@check(false, "SKIPPED — the file it wrote could not be read back");
		return;
	}
	crig::AnimTemplate back = read_back;
	defer back.free(mem);

	// Mid-clip, where the slide is at full extent.
	rig::Pose there = sent.pose(mem, &skeleton, JOINT_NAMES[..], 0.5f);
	defer there.free(mem);
	rig::Pose here = back.pose(mem, &skeleton, JOINT_NAMES[..], 0.5f);
	defer here.free(mem);

	Vec3[] sent_at = posed_joints(&skeleton, there);
	defer alloc::free(mem, sent_at);
	Vec3[] back_at = posed_joints(&skeleton, here);
	defer alloc::free(mem, back_at);

	// The knee has to have gone somewhere, or the check below holds two rigs that
	// agree because neither of them moved.
	float travelled = (sent_at[KNEE] - skeleton.joints[KNEE]).length();
	test::@check(travelled > 0.1f, "the knee slides in the preview at all (%.4f)", travelled);

	float knee = (sent_at[KNEE] - back_at[KNEE]).length();
	float ankle = (sent_at[ANKLE] - back_at[ANKLE]).length();
	io::printfn("  knee %.7f out, ankle %.7f out", knee, ankle);

	test::@check(knee < EXACT, "the knee reads back where the preview slid it");
	test::@check(ankle < EXACT, "and the ankle it carries comes with it");

	(void)file::delete(path);
}

// ---------------------------------------------------------------------------
// Mesh, skin and clips in one file.

<*
 A box enclosing a skeleton, with room around it.

 A body for the rigged writer to skin: the weights it produces are irrelevant to
 every assertion below, but a mesh with no volume around the joints produces a
 degenerate binding and there is no reason to test the writer on one.
*>
fn rig::TriMesh box_around(rig::Skeleton* skeleton)
{
	Vec3 low = skeleton.joints[0];
	Vec3 high = skeleton.joints[0];
	foreach (joint : skeleton.joints)
	{
		low = { math::min(low.x, joint.x), math::min(low.y, joint.y), math::min(low.z, joint.z) };
		high = { math::max(high.x, joint.x), math::max(high.y, joint.y), math::max(high.z, joint.z) };
	}

	Vec3 pad = { 0.5f, 0.5f, 0.5f };
	low -= pad;
	high += pad;

	Vec3[] positions = alloc::new_array(mem, Vec3, 8);
	for (usz i = 0; i < 8; i++)
	{
		positions[i] = {
			(i & 1) != 0 ? high.x : low.x,
			(i & 2) != 0 ? high.y : low.y,
			(i & 4) != 0 ? high.z : low.z,
		};
	}

	uint[36] faces = {
		0, 2, 3,  0, 3, 1,
		4, 5, 7,  4, 7, 6,
		0, 1, 5,  0, 5, 4,
		2, 6, 7,  2, 7, 3,
		0, 4, 6,  0, 6, 2,
		1, 3, 7,  1, 7, 5,
	};
	uint[] indices = alloc::new_array(mem, uint, 36);
	foreach (usz i, index : faces) indices[i] = index;

	return { .positions = positions, .indices = indices };
}

<*
 A clip written into a rigged file plays back where it was written.

 The one check standing over the frame conversion in `export_rigged_animated_glb`.
 crig poses a joint as a rotation about its rest position in world axes, on nodes
 that carry no rotation; a rigged file writes bone-aligned nodes, because that is
 what imports into Blender as an armature rather than as a fan of bones from the
 origin. Every channel is converted between the two on the way out, and the only
 way to know the conversion is right is to read the file back and put the rig in
 the same place.

 It is also the check that the two halves agree with each other: the skeleton is
 read out of the same file, so a rest pose written one way and channels written
 another would show up here as a rig that starts wrong and stays wrong.

 *Re-introduce:* drop the parent's inverse from the rotation and every joint
 below the root lands somewhere else.
*>
fn void a_rigged_clip_plays_back_where_it_was_written() @test
{
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	rig::TriMesh body = box_around(&skeleton);
	defer body.free(mem);

	crig::AnimTemplate sent = {
		.name = "bend",
		.duration = 1.0f,
		.keyframes = SENT_FRAMES[..],
		.loop = true,
	};
	crig::AnimTemplate[1] library = { sent };

	String path = "build/anim-rigged.glb";
	if (catch fault error = crig::export_rigged_animated_glb(
		mem, path, body, &skeleton, JOINT_NAMES[..], {}, library[..], "body"))
	{
		test::@check(false, "SKIPPED — the rigged writer refused the fixture");
		io::printfn("  %s", error);
		return;
	}
	test::@check(glb_is_well_formed(path), "a rigged, animated glb is a well-formed container");

	crig::AnimPack? read_back = crig::read_pack(mem, path);
	if (catch read_back)
	{
		test::@check(false, "SKIPPED — the file it wrote could not be read as a pack");
		return;
	}
	crig::AnimPack pack = read_back;
	defer pack.free(mem);

	test::@check(pack.clips.len == 1, "the clip comes back");
	test::@check(pack.rest.len() == 3, "and so does a joint per dot");
	test::@check(pack.mesh.positions.len == 8, "and the body it was skinned to");
	if (pack.clips.len != 1 || pack.rest.len() != 3) return;

	// The rest skeleton first. Bone-aligned nodes have to compose back to the
	// same world positions, or every posed comparison below is measured from
	// somewhere else and agreeing would mean nothing.
	float rest_gap = 0.0f;
	foreach (usz j, joint : pack.rest.joints)
	{
		float gap = (joint - skeleton.joints[j]).length();
		if (gap > rest_gap) rest_gap = gap;
	}
	test::@check(rest_gap < EXACT, "the rig comes back standing where it was written");

	float worst = 0.0f;
	for (usz step = 0; step <= 20; step++)
	{
		float time = (float)step / 20.0f;

		rig::Pose there = sent.pose(mem, &skeleton, JOINT_NAMES[..], time);
		defer there.free(mem);
		rig::Pose here = pack.clips[0].pose(mem, &pack.rest, pack.joint_names, time);
		defer here.free(mem);

		Vec3[] sent_at = posed_joints(&skeleton, there);
		defer alloc::free(mem, sent_at);
		Vec3[] back_at = posed_joints(&pack.rest, here);
		defer alloc::free(mem, back_at);

		for (usz j = 0; j < 3; j++)
		{
			float gap = (sent_at[j] - back_at[j]).length();
			if (gap > worst) worst = gap;
		}
	}

	io::printfn("  posed through a rigged file, worst joint %.7f out", worst);
	test::@check(worst < EXACT, "and moves through the clip exactly as it did before");

	(void)file::delete(path);
}

<*
 A clip exported onto a rig it was not authored on holds the motion that rig was
 previewed with, not the motion the clip was written with.

 The half of carrying that lives outside the player. Exporting a downloaded clip
 on a user's own rig is the ordinary case — it is what the export dialog's clip
 list is for — and a writer that reads the keyframe entries raw writes the frame
 the clip came in rather than the frame the rig is in. The file then plays
 something the user never saw, which is worse than playing it wrong, because
 nothing on screen disagrees with it.

 The rig here is the fixture with its hips moved, the same displacement
 `check_a_carry_does_not_leak_down_the_chain` uses and for the same reason: it
 gives the source and the target genuinely different bones to carry between, so
 a writer that skips the carry cannot land on the right answer by accident.

 **Exact at the keys, and only there.** The preview slerps each joint's authored
 rotation and then composes the chain; the file holds the composed result and a
 glTF reader slerps that. The product of two slerps is not the slerp of the
 product — the same reason `sample_times` subdivides a folded joint — so the two
 meet at every key and bow apart in between, by more the deeper down the chain a
 joint sits. So the keys are held to `EXACT` and the space between them to a
 fraction of the rig, which is what separates that bow from a clip written in
 the wrong frame: the latter is wrong at the keys too.
*>
fn void an_exported_clip_holds_what_the_preview_showed() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	crig::AnimTemplate anim = crig::import_gltf_animation(mem, path)!!;
	defer anim.free(mem);

	rig::Skeleton target = fixture_skeleton();
	defer target.free(mem);
	target.joints[HIPS] = target.joints[HIPS] + (Vec3){ 0.4f, 0.0f, 0.35f };

	rig::TriMesh body = box_around(&target);
	defer body.free(mem);

	crig::AnimTemplate[1] library = { anim };
	String written = "build/anim-carried.glb";
	if (catch fault error = crig::export_rigged_animated_glb(
		mem, written, body, &target, JOINT_NAMES[..], {}, library[..], "body"))
	{
		test::@check(false, "SKIPPED — the rigged writer refused the carried clip");
		io::printfn("  %s", error);
		return;
	}

	crig::AnimPack? read_back = crig::read_pack(mem, written);
	if (catch read_back)
	{
		test::@check(false, "SKIPPED — the file it wrote could not be read as a pack");
		return;
	}
	crig::AnimPack pack = read_back;
	defer pack.free(mem);

	if (pack.clips.len != 1 || pack.rest.len() != 3)
	{
		test::@check(false, "SKIPPED — the clip and the rig did not both come back");
		return;
	}

	float at_keys = 0.0f;
	float between = 0.0f;

	// The clip's own keys, then a grid fine enough to fall between them.
	for (usz step = 0; step <= anim.keyframes.len + 20; step++)
	{
		bool on_key = step < anim.keyframes.len;
		float time = on_key
			? anim.keyframes[step].time
			: (float)(step - anim.keyframes.len) / 20.0f * anim.duration;

		// The preview: the clip carried onto the rig it is being exported on.
		rig::Pose shown = anim.pose(mem, &target, JOINT_NAMES[..], time);
		defer shown.free(mem);
		Vec3[] shown_at = posed_joints(&target, shown);
		defer alloc::free(mem, shown_at);

		// And the file, read back on its own rig, where there is nothing left to
		// carry — so this is what the bytes say and nothing else.
		rig::Pose stored = pack.clips[0].pose(mem, &pack.rest, pack.joint_names, time);
		defer stored.free(mem);
		Vec3[] stored_at = posed_joints(&pack.rest, stored);
		defer alloc::free(mem, stored_at);

		for (usz j = 0; j < 3; j++)
		{
			float gap = (shown_at[j] - stored_at[j]).length();
			if (on_key) { if (gap > at_keys) at_keys = gap; }
			else if (gap > between) between = gap;
		}
	}

	float height = target.height();
	io::printfn("  the exported file meets the preview to %.7f at its keys, %.5f (%.2f%% of the rig) between",
		at_keys, between, between / height * 100.0f);
	test::@check(at_keys < EXACT, "a carried clip is written in the frame it was previewed in");
	test::@check(between < height * 0.02f, "and between its keys it only bows, it does not diverge");

	(void)file::delete(written);
}

<*
 Every bone in a rigged file points along itself.

 The reason the rigged writer uses bone-aligned nodes at all: glTF puts no
 meaning on which local axis a joint's bone runs along, and what the tools agree
 on is Blender's, whose bone is the node's own -Z. A file that leaves the nodes
 unrotated is valid and imports as an armature fanning out from the origin —
 which `export_rigged_glb`'s doc records as exactly the defect it went to this
 convention to avoid, and which nothing else in the file would reveal.

 Composed down the chain rather than read off each node, because a node's
 rotation is expressed inside its parent's: the leaf here has an identity local
 rotation, since a leaf's extruded tail runs parallel to the bone arriving at it,
 and only the composition says where it actually points.
*>
fn void every_bone_carries_its_direction() @test
{
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	rig::TriMesh body = box_around(&skeleton);
	defer body.free(mem);

	crig::AnimTemplate sent = { .name = "bend", .duration = 1.0f, .keyframes = SENT_FRAMES[..] };
	crig::AnimTemplate[1] library = { sent };

	String path = "build/anim-rigged-leaf.glb";
	if (catch crig::export_rigged_animated_glb(
		mem, path, body, &skeleton, JOINT_NAMES[..], {}, library[..], "body"))
	{
		test::@check(false, "SKIPPED — the rigged writer refused the fixture");
		return;
	}

	gltf::GltfStream? opened = gltf::open(path, mem);
	if (catch opened)
	{
		test::@check(false, "SKIPPED — the file it wrote could not be opened");
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();

	Vec3[] tails = skeleton.tails(mem);
	defer alloc::free(mem, tails);

	usz aimed = 0;
	float worst = 0.0f;
	foreach (usz j, name : JOINT_NAMES)
	{
		Vec3 bone = (tails[j] - skeleton.joints[j]).normalize();

		foreach (node : stream.gltf.nodes)
		{
			if (node.name != name) continue;

			// Down the chain: a node's rotation is inside its parent's, and only
			// the product says which way the bone actually runs.
			Quaternionf world = node.rotation;
			for (gltf::Node* up = node.parent; up != null; up = up.parent)
			{
				world = up.rotation.mul(world);
			}

			float gap = (world.rotate_vec3({ 0, 0, -1 }) - bone).length();
			if (gap > worst) worst = gap;
			if (gap < EXACT) aimed++;
		}
	}

	io::printfn("  three bones aimed, worst %.7f off its own direction", worst);
	test::@check(aimed == JOINT_NAMES.len, "every joint node's local -Z runs along its bone");
	(void)file::delete(path);
}

// ---------------------------------------------------------------------------
// Packs.

// A quarter turn's worth of quaternion, about X and about Z, so the fixture's
// two clips are visibly different motions rather than two names for one.
const float PACK_SIN = 0.258819f; // sin(15 degrees)
const float PACK_COS = 0.965926f; // cos(15 degrees)

<*
 A pack as a .gltf: root extras, a two-joint skin, a tetrahedron body, two clips.

 Written by hand rather than through crig's writer, which does not exist yet at
 this point in the build — and which is the better fixture for a reader anyway,
 since a round trip through one author's writer cannot show that the reader
 speaks glTF rather than speaking that writer.

 The extras are deliberately untidy: a plan with a trailing space, a capitalised
 tag, and an empty entry left by a trailing comma. All three are things a person
 types, and all three have to come out clean.

 @param extras : `The root extras object, or "" to write a file that declares nothing.`
*>
fn void? write_pack_fixture(String path, String extras)
{
	float[51] numbers;
	usz at = 0;

	// 0: the three key times, shared by both clips.
	numbers[at++] = 0.0f;
	numbers[at++] = 0.5f;
	numbers[at++] = 1.0f;

	// 12: "walk" — the tip turning about X and back.
	float[12] walk = { 0, 0, 0, 1, PACK_SIN, 0, 0, PACK_COS, 0, 0, 0, 1 };
	foreach (v : walk) numbers[at++] = v;

	// 60: "swim" — the same joint, about Z instead.
	float[12] swim = { 0, 0, 0, 1, 0, 0, PACK_SIN, PACK_COS, 0, 0, 0, 1 };
	foreach (v : swim) numbers[at++] = v;

	// 108: the body. A tetrahedron, which is the cheapest shape with a bounding
	// box in three dimensions — a triangle would be flat on one axis and the
	// per-axis fit read off it later would divide by zero.
	float[12] positions = { -1, 0, -1, 1, 0, -1, 0, 0, 1, 0, 2, 0 };
	foreach (v : positions) numbers[at++] = v;

	// 156: normals, held straight up. Nothing here reads them; they are present
	// so the mesh arrives with `has_normals()` true, like a real export.
	for (usz i = 0; i < 4; i++)
	{
		numbers[at++] = 0.0f;
		numbers[at++] = 1.0f;
		numbers[at++] = 0.0f;
	}

	uint[12] indices = { 0, 1, 2, 0, 1, 3, 1, 2, 3, 2, 0, 3 };

	char[252] bytes;
	char* floats_at = (char*)&numbers;
	for (usz i = 0; i < 204; i++) bytes[i] = floats_at[i];
	char* indices_at = (char*)&indices;
	for (usz i = 0; i < 48; i++) bytes[204 + i] = indices_at[i];

	String encoded = base64::encode(mem, bytes[..]);
	defer encoded.free(mem);

	String json = string::format(mem,
		`{
  "asset": { "version": "2.0" },%s
  "scenes": [ { "nodes": [0, 2] } ],
  "scene": 0,
  "nodes": [
    { "name": "root", "translation": [0,0,0], "children": [1] },
    { "name": "tip", "translation": [0,1,0] },
    { "name": "body", "mesh": 0 }
  ],
  "skins": [ { "joints": [0, 1] } ],
  "meshes": [
    { "primitives": [ { "attributes": { "POSITION": 3, "NORMAL": 4 }, "indices": 5 } ] }
  ],
  "buffers": [ { "byteLength": 252, "uri": "data:application/octet-stream;base64,%s" } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,   "byteLength": 12 },
    { "buffer": 0, "byteOffset": 12,  "byteLength": 48 },
    { "buffer": 0, "byteOffset": 60,  "byteLength": 48 },
    { "buffer": 0, "byteOffset": 108, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 156, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 204, "byteLength": 48 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0.0], "max": [1.0] },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 3, "componentType": 5126, "count": 4, "type": "VEC3", "min": [-1.0,0.0,-1.0], "max": [1.0,2.0,1.0] },
    { "bufferView": 4, "componentType": 5126, "count": 4, "type": "VEC3" },
    { "bufferView": 5, "componentType": 5125, "count": 12, "type": "SCALAR" }
  ],
  "animations": [
    {
      "name": "Walk",
      "samplers": [ { "input": 0, "output": 1, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 1, "path": "rotation" } } ]
    },
    {
      "name": "Swim",
      "samplers": [ { "input": 0, "output": 2, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 1, "path": "rotation" } } ]
    }
  ]
}`,
		extras, encoded);
	defer json.free(mem);

	return file::save(path, (char[])json);
}

// The extras a well-formed pack declares, untidiness included.
const String PACK_EXTRAS =
	"\n  \"extras\": { \"name\": \"Test pack\", \"plan\": \"Biped \", \"tags\": \"Biped, swimming, \" },";

// The same without a name, so the pack is called after its file. What the
// library check needs, since two packs that name themselves the same thing
// would say nothing about the order they came back in.
const String PACK_EXTRAS_UNNAMED =
	"\n  \"extras\": { \"plan\": \"biped\", \"tags\": \"biped\" },";

<*
 A pack gives up its metadata, its clips, its joints and its body.

 Every one of those is a separate promise and the file makes all four at once,
 so they are asserted by value rather than by count: a reader that found the
 right *number* of tags and lowercased neither of them would pass a count.
*>
fn void a_pack_carries_its_tags() @test
{
	String path = "build/pack-tagged.gltf";
	if (catch write_pack_fixture(path, PACK_EXTRAS))
	{
		test::@check(false, "the pack fixture could be written");
		return;
	}

	crig::AnimPackReport report;
	crig::AnimPack? pack = crig::read_pack(mem, path, &report);
	if (catch pack)
	{
		test::@check(false, "a written pack reads back");
		return;
	}
	defer pack.free(mem);

	test::@check(pack.name == "Test pack", "the pack carries the name it declared");
	test::@check(pack.plan == "biped", "and its plan, trimmed and folded to lower case");
	test::@check(pack.tags.len == 2, "the tag list drops the empty entry a trailing comma leaves");
	test::@check(pack.has_tag("biped") && pack.has_tag("swimming"), "and keeps both real tags, lowercased");

	test::@check(pack.clips.len == 2, "both clips in the file are read");
	bool walk = false;
	bool swim = false;
	foreach (clip : pack.clips)
	{
		if (clip.name == "Walk") walk = true;
		if (clip.name == "Swim") swim = true;
	}
	test::@check(walk && swim, "and they come back under the names the file gave them");

	test::@check(pack.joint_names.len == 2, "the skin's joints become the pack's skeleton");
	test::@check(
		pack.joint_names.len == 2 && pack.joint_names[0] == "root" && pack.joint_names[1] == "tip",
		"parents before children, named as the nodes were"
	);
	test::@check(pack.rest.joints.len == 2 && pack.rest.parents[0] == -1 && pack.rest.parents[1] == 0,
		"and the hierarchy comes with them");

	test::@check(pack.mesh.positions.len == 4, "the body is read as an ordinary mesh");
	test::@check(pack.mesh.indices.len == 12, "with its triangles");
	test::@check(report.tagged && !report.mesh_missing, "and the report says what was found");
}

<*
 A file that declares nothing is still a pack.

 This is what every .glb written before packs existed looks like, and what a
 plain export out of a DCC tool looks like. Refusing it would strand the library
 that already ships.
*>
fn void a_file_without_metadata_is_still_clips() @test
{
	String path = "build/pack-untagged.gltf";
	if (catch write_pack_fixture(path, ""))
	{
		test::@check(false, "the untagged fixture could be written");
		return;
	}

	crig::AnimPackReport report;
	crig::AnimPack? pack = crig::read_pack(mem, path, &report);
	if (catch pack)
	{
		test::@check(false, "a file with no extras still reads as a pack");
		return;
	}
	defer pack.free(mem);

	test::@check(pack.plan.len == 0, "a pack that declares no plan has none");
	test::@check(pack.tags.len == 0, "and no tags");
	test::@check(!report.tagged, "which the report says rather than leaving to be guessed");
	test::@check(pack.name == "Pack-untagged", "the file stem stands in for the name it did not give");
	test::@check(pack.clips.len == 2, "and every clip is still there");
}

<*
 A folder of files becomes a library, in an order that does not vary.

 Sorting is not cosmetic: which pack claims a body-plan tag, what `--preset`
 resolves to and which clip the view opens on all read "the first", and a
 filesystem order makes all three depend on the machine. The fixture is written
 out of order for the same reason — on a filesystem that already lists
 alphabetically, a check on sorted input asserts nothing.
*>
fn void packs_come_back_in_name_order() @test
{
	String folder = "build/pack-library";
	if (catch path::mkdir(folder))
	{
		// Left over from a previous run, which is fine — the files below are
		// overwritten, and anything else fails two lines down.
	}

	// Zebra first, and the names come from the stems, so a reader that keeps
	// the order it was handed puts the zebra first too.
	if (catch write_pack_fixture("build/pack-library/zebra.gltf", PACK_EXTRAS_UNNAMED)) return;
	if (catch write_pack_fixture("build/pack-library/alpaca.gltf", PACK_EXTRAS_UNNAMED)) return;

	// The things a real folder also has in it.
	if (catch file::save("build/pack-library/notes.txt", (char[])"not a rig")) return;
	if (catch file::save("build/pack-library/broken.glb", (char[])"neither is this")) return;

	crig::AnimPack[] library = crig::scan_packs(mem, folder);
	defer crig::free_packs(mem, library);

	io::printfn("  %d packs read out of two glTF files, a text file and a broken one", library.len);
	test::@check(library.len == 2, "the readable packs are found and nothing else is");
	test::@check(library.len == 2 && library[0].name == "Alpaca", "and they come back in name order");
	test::@check(library.len == 2 && library[1].name == "Zebra", "whatever order the folder listed them in");
}

<*
 The pack reader and the clip importer agree on what a joint is.

 They are two walks over the same nodes — `read_rest_skeleton` was split out of
 the importer rather than shared with it, because hoisting the rest of what
 `import_animation` needs is a large change to the most delicate file here. The
 cost of not sharing is that the two can drift, and this is what would notice.
*>
fn void the_rest_skeleton_matches_the_importers() @test
{
	String path;
	if (!animated_fixture(&path)) return;

	gltf::GltfStream? stream = gltf::open(path, mem);
	if (catch stream)
	{
		test::@check(false, "the fixture opens");
		return;
	}
	defer stream.close();

	String[] names;
	rig::Skeleton? rest = crig::read_rest_skeleton(mem, &stream, &names);
	if (catch rest)
	{
		test::@check(false, "the rest skeleton reads");
		return;
	}
	defer rest.free(mem);
	defer
	{
		foreach (name : names) alloc::free(mem, name.ptr);
		alloc::free(mem, names);
	}

	crig::AnimTemplate? clip = crig::import_animation(mem, &stream, { .index = 0 });
	if (catch clip)
	{
		test::@check(false, "the clip converts");
		return;
	}
	defer clip.free(mem);

	// Every joint the importer names has to be one the skeleton reader found,
	// under the same name — that is the whole of what "agree" means here.
	bool matched = true;
	foreach (frame : clip.keyframes)
	{
		foreach (dot : frame.dots)
		{
			bool known = false;
			foreach (name : names)
			{
				if (name == dot.joint_name) known = true;
			}
			if (!known) matched = false;
		}
	}
	test::@check(matched, "every joint the importer names is one the skeleton reader found");
	test::@check(names.len > 0 && rest.joints.len == names.len, "and the skeleton is as long as its name list");
}

<*
 The pack both round-trip checks read: two clips, a skeleton and a 2 x 2 x 6 box.

 Written by whichever check runs first rather than left behind by one of them.
 `c3c test` runs checks in name order, and `the_position_bounds_are_per_axis`
 reads this file without writing it.

 Returns false having already failed the calling test.
*>
const String ROUND_TRIP_PACK = "build/pack-round-trip.glb";

fn bool round_trip_pack(String path)
{

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	crig::AnimTemplate[2] clips = {
		{ .name = "Walk", .duration = 1.0f, .keyframes = SENT_FRAMES[..], .loop = true },
		{ .name = "Swim", .duration = 1.0f, .keyframes = SENT_FRAMES[..], .loop = true },
	};

	// A box, so the bounds written per component are three different pairs — a
	// writer that collapsed them to one would still look right on a cube.
	Vec3[8] corners = {
		{ -1, 0, -3 }, { 1, 0, -3 }, { 1, 2, -3 }, { -1, 2, -3 },
		{ -1, 0, 3 },  { 1, 0, 3 },  { 1, 2, 3 },  { -1, 2, 3 },
	};
	uint[36] faces = {
		0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6,
		0, 4, 5, 0, 5, 1, 3, 2, 6, 3, 6, 7,
		0, 3, 7, 0, 7, 4, 1, 5, 6, 1, 6, 2,
	};
	// Every normal points the same way, which no box's own faces could average
	// to. A writer that dropped the NORMAL attribute would not fail quietly:
	// rig::from_gltf computes normals from the faces when a primitive has none,
	// so the mesh would come back with plausible corner normals and only a value
	// nothing could have computed tells the two apart.
	Vec3[8] sideways = {
		{ 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 },
		{ 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 },
	};
	rig::TriMesh body = { .positions = corners[..], .normals = sideways[..], .indices = faces[..] };

	String[2] tags = { "test", "swimming" };
	crig::AnimPackMeta meta = { .plan = "test", .name = `The "test" pack`, .tags = tags[..] };

	if (catch fault error = crig::export_pack_glb(mem, path, &skeleton, JOINT_NAMES[..], clips[..], body, meta))
	{
		test::@check(false, "could not write %s (%s)", path, error);
		return false;
	}

	test::@check(glb_is_well_formed(path), "%s is not a well-formed .glb", path);
	return true;
}

<*
 A pack written by crig reads back as the pack that went in.

 The other pack checks read a hand-written .gltf, which is what shows the reader
 speaks glTF. This one closes the other direction: the writer has to produce
 something this reader — and, through the container check, any reader — accepts.
 Between them a pack cannot be broken at one end and compensated for at the
 other.

 The body matters here more than anywhere else. It is the one part of a pack
 that goes through accessors the animation path never touches: element-wide
 bounds on POSITION, an index accessor, and the optional NORMAL attribute.
*>
fn void a_pack_survives_being_written_out() @test
{
	String path = ROUND_TRIP_PACK;
	if (!round_trip_pack(path)) return;


	crig::AnimPackReport report;
	crig::AnimPack? read = crig::read_pack(mem, path, &report);
	if (catch read)
	{
		test::@check(false, "and reads back as a pack");
		return;
	}
	defer read.free(mem);

	test::@check(read.plan == "test", "with the plan it was written with");
	// A quoted name is the reason the writer escapes at all: unescaped, the file
	// is not JSON and nothing above this line would have got here.
	test::@check(read.name == `The "test" pack`, "and a name that survives its own quotes");
	test::@check(read.tags.len == 2 && read.has_tag("test") && read.has_tag("swimming"), "and both tags");
	test::@check(read.clips.len == 2, "both clips come back");
	test::@check(read.joint_names.len == JOINT_NAMES.len, "the skeleton comes back whole");

	test::@check(read.mesh.positions.len == 8, "the body comes back with its vertices");
	test::@check(read.mesh.indices.len == 36, "and its triangles");

	bool normals_kept = read.mesh.normals.len == 8;
	foreach (normal : read.mesh.normals)
	{
		if (math::abs(normal.x - 1.0f) >= EXACT) normals_kept = false;
	}
	test::@check(normals_kept, "and the normals it was authored with, not ones computed from its faces");

	rig::Bounds box = read.mesh.bounds();
	Vec3 size = box.max - box.min;
	test::@check(
		math::abs(size.x - 2.0f) < EXACT && math::abs(size.y - 2.0f) < EXACT
			&& math::abs(size.z - 6.0f) < EXACT,
		"at the size it was written, on every axis"
	);
	test::@check(!report.mesh_missing, "and the report agrees there is a body");
}

<*
 The POSITION accessor's bounds, which nothing else here can see.

 glTF requires min and max on POSITION and requires them per component. Neither
 crig's reader nor any other cares — they read the buffer — so a writer that
 emitted one pair over the whole run would round-trip perfectly and hand every
 other tool a box six units wide on all three axes. The fixture is 2 x 2 x 6 on
 purpose: on a cube this check would pass either way.
*>
fn void the_position_bounds_are_per_axis() @test
{
	String path = ROUND_TRIP_PACK;
	if (!round_trip_pack(path)) return;

	gltf::GltfStream? stream = gltf::open(path, mem);
	if (catch stream)
	{
		test::@check(false, "the written pack opens for its accessors to be read");
		return;
	}
	defer stream.close();

	if (stream.gltf.meshes.len() == 0)
	{
		test::@check(false, "the written pack has a mesh to read bounds off");
		return;
	}

	long? position = stream.gltf.meshes[0].primitives[0].attributes.get("POSITION");
	if (catch position)
	{
		test::@check(false, "the body's primitive names a POSITION accessor");
		return;
	}

	gltf::Accessor accessor = stream.gltf.accessors[(sz)position];
	test::@check(
		math::abs(accessor.min.x + 1.0f) < EXACT && math::abs(accessor.min.y) < EXACT
			&& math::abs(accessor.min.z + 3.0f) < EXACT,
		"the POSITION accessor's min is the box's own corner, per axis"
	);
	test::@check(
		math::abs(accessor.max.x - 1.0f) < EXACT && math::abs(accessor.max.y - 2.0f) < EXACT
			&& math::abs(accessor.max.z - 3.0f) < EXACT,
		"and its max the opposite one, rather than one number for all three"
	);
}

<*
 The container itself, checked without the glTF reader.

 A .glb whose chunk lengths do not line up is one some readers accept and
 others reject, and the one that accepts it is the one this suite would use —
 so the header is read here by hand instead.
*>
fn bool glb_is_well_formed(String path)
{
	char[]? data = file::load(mem, path);
	if (catch data) return false;
	defer alloc::free(mem, data);

	if (data.len < 20) return false;
	if (read_u32(data, 0) != 0x46546C67) return false;
	if (read_u32(data, 4) != 2) return false;
	if (read_u32(data, 8) != (uint)data.len) return false;

	usz at = 12;
	while (at + 8 <= data.len)
	{
		uint length = read_u32(data, at);
		if (length % 4 != 0) return false;
		at += 8 + (usz)length;
	}
	return at == data.len;
}

fn uint read_u32(char[] data, usz at)
{
	return (uint)data[at]
		| ((uint)data[at + 1] << 8)
		| ((uint)data[at + 2] << 16)
		| ((uint)data[at + 3] << 24);
}

<*
 A folder of files becomes one library.

 This is how the app comes by its animations, and the two things it has to get
 right are both invisible when the folder holds a single well-formed file with a
 single clip in it: that a file carrying several clips gives up all of them, and
 that whatever else is sitting in the folder is left alone. Real folders have a
 README and a half-finished download in them.
*>
fn void a_folder_becomes_a_library() @test
{
	String folder = "build/anim-library";
	if (catch path::mkdir(folder))
	{
		// Already there from a previous run, which is fine — the files below are
		// overwritten. Anything else shows up as a failure two lines down.
	}

	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	crig::AnimTemplate[2] pair = {
		{ .name = "first", .duration = 1.0f, .keyframes = SENT_FRAMES[..], .loop = true },
		{ .name = "second", .duration = 1.0f, .keyframes = SENT_FRAMES[..], .loop = true },
	};
	crig::AnimTemplate[1] single = {
		{ .name = "third", .duration = 1.0f, .keyframes = SENT_FRAMES[..], .loop = true },
	};

	if (catch crig::export_animations_glb(mem, "build/anim-library/pair.glb", &skeleton, JOINT_NAMES[..], pair[..]))
	{
		test::@check(false, "the library fixture could be written");
		return;
	}
	if (catch crig::export_animations_glb(mem, "build/anim-library/one.glb", &skeleton, JOINT_NAMES[..], single[..]))
	{
		test::@check(false, "the library fixture could be written");
		return;
	}

	// The things a real folder also has in it.
	if (catch file::save("build/anim-library/notes.txt", (char[])"not a rig"))
	{
		test::@check(false, "the library fixture could be written");
		return;
	}
	if (catch file::save("build/anim-library/broken.glb", (char[])"neither is this"))
	{
		test::@check(false, "the library fixture could be written");
		return;
	}

	crig::AnimPack[] packs = crig::scan_packs(mem, folder);
	defer crig::free_packs(mem, packs);

	usz clips = 0;
	bool has_first = false;
	bool has_second = false;
	bool has_third = false;
	foreach (pack : packs) foreach (anim : pack.clips)
	{
		clips++;
		if (anim.name == "first") has_first = true;
		if (anim.name == "second") has_second = true;
		if (anim.name == "third") has_third = true;
	}

	io::printfn("  %d animations read out of two glTF files, a text file and a broken one", clips);
	test::@check(packs.len == 2, "the two glTF files are packs and nothing else is");
	test::@check(clips == 3, "every clip in the folder is found and nothing else is");
	test::@check(has_first && has_second, "a file carrying two clips gives up both of them");
	test::@check(has_third, "and a second file is read as well as the first");
}

// ---------------------------------------------------------------------------
// Matching a rig onto a body plan by shape.

// What the fold fixture turns, in radians. FOLD_A and FOLD_B are about
// different axes, because composing two rotations is only order-dependent when
// they disagree about which way to turn — folding in the wrong order down a
// chain that bends about one axis is invisible.
//
// Both spine links are animated, not just the folded one. The matcher keeps
// plan dots off joints the clip never turns, so with one live link and one
// dead one the dot would take the live link and the fold would land on the
// dead one — a fold that composes nothing, which is not the case under test.
// With both alive, whichever link the dot takes, an animated joint folds.
// FOLD_C shares FOLD_A's axis: two X turns compose into one X turn, which a
// single slerp reproduces exactly, so the between-keys check stays a check on
// the fold and not on an unrelated approximation.
const float FOLD_A = 0.5f;  // about X, on the joint that gets folded away
const float FOLD_B = -0.4f; // about Z, on the chest the fold composes toward
const float FOLD_C = 0.3f;  // about X, on the spine link the plan keeps

<*
 A biped body plan in a T-pose, in the frame `fit_preset` reads.

 crig's own, written out here rather than read from tools/body_plans.c3 which
 this target does not link. A T-pose on purpose: the fixture below stands in an
 A-pose, and the whole claim of core/joint_match.c3 is that the two still match.

 A plain global rather than a `const`: a const holding a slice is materialized
 where it is used, so `match_plan_dots[..]` taken inside a function and handed
 back would point at nothing. The same rule tools/body_plans.c3 states for the
 tables the packs are generated from.
*>
PresetDot[17] match_plan_dots = {
	{ .name = "hips",       .at = { 0.50, 0.52, 0.50 }, .parent = -1 },
	{ .name = "spine",      .at = { 0.50, 0.62, 0.50 }, .parent = 0 },
	{ .name = "chest",      .at = { 0.50, 0.74, 0.50 }, .parent = 1 },
	{ .name = "neck",       .at = { 0.50, 0.83, 0.50 }, .parent = 2 },
	{ .name = "head",       .at = { 0.50, 0.92, 0.50 }, .parent = 3 },
	{ .name = "shoulder_L", .at = { 0.58, 0.80, 0.50 }, .parent = 2 },
	{ .name = "elbow_L",    .at = { 0.72, 0.80, 0.50 }, .parent = 5 },
	{ .name = "wrist_L",    .at = { 0.86, 0.80, 0.50 }, .parent = 6 },
	{ .name = "shoulder_R", .at = { 0.42, 0.80, 0.50 }, .parent = 2 },
	{ .name = "elbow_R",    .at = { 0.28, 0.80, 0.50 }, .parent = 8 },
	{ .name = "wrist_R",    .at = { 0.14, 0.80, 0.50 }, .parent = 9 },
	{ .name = "thigh_L",    .at = { 0.55, 0.50, 0.50 }, .parent = 0 },
	{ .name = "knee_L",     .at = { 0.55, 0.27, 0.50 }, .parent = 11 },
	{ .name = "ankle_L",    .at = { 0.55, 0.04, 0.50 }, .parent = 12 },
	{ .name = "thigh_R",    .at = { 0.45, 0.50, 0.50 }, .parent = 0 },
	{ .name = "knee_R",     .at = { 0.45, 0.27, 0.50 }, .parent = 14 },
	{ .name = "ankle_R",    .at = { 0.45, 0.04, 0.50 }, .parent = 15 },
};

fn crig::Preset match_plan() => { .name = "Biped", .plan = "biped", .dots = match_plan_dots[..] };

<*
 A rig with the shape of a biped and the names of nothing at all.

 Every joint is called `n_` and a letter. That is the point: core/joint_match.c3
 claims to read no names, and a fixture named after the plan it is expected to
 match would let a name-reading matcher pass. Nothing here spells `spine`, and
 the check below still expects a joint to become one.

 What the plan has no dot for, and what therefore has to fold: a floor root above
 the hips, a second link in the spine and in the neck, a clavicle above each
 shoulder, a twist bone hanging off each forearm, and a toe past each ankle.
 Nine joints of the twenty-six.

 The figure stands in an **A-pose** — arms down and out at forty-five degrees —
 against a T-pose plan, which is the case a position-only matcher gets wrong and
 the reason `MATCH_POSITION_WEIGHT` is not larger than it is.

 @param extras : `The root extras object, or "" to write a file that declares nothing.`
*>
fn void? write_fold_fixture(String path, String extras = "")
{
	float[39] numbers;
	usz at = 0;

	numbers[at++] = 0.0f;
	numbers[at++] = 0.5f;
	numbers[at++] = 1.0f;

	// Out to the turn at the middle key and back, so a check between keys has a
	// slerp to reproduce and a check on the key has an exact value.
	Quaternionf[3] folded = { quaternion::IDENTITY, turn({ 1, 0, 0 }, FOLD_A), quaternion::IDENTITY };
	foreach (rotation : folded)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	Quaternionf[3] kept = { quaternion::IDENTITY, turn({ 0, 0, 1 }, FOLD_B), quaternion::IDENTITY };
	foreach (rotation : kept)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	Quaternionf[3] second = { quaternion::IDENTITY, turn({ 1, 0, 0 }, FOLD_C), quaternion::IDENTITY };
	foreach (rotation : second)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	char[] bytes = ((char*)&numbers)[:39 * 4];
	String encoded = base64::encode(mem, bytes);
	defer encoded.free(mem);

	String json = string::format(mem,
		`{
  "asset": { "version": "2.0" },%s
  "scenes": [ { "nodes": [0] } ],
  "scene": 0,
  "nodes": [
    { "name": "n_root",   "translation": [0,0,0],          "children": [1] },
    { "name": "n_pelvis", "translation": [0,0.52,0],       "children": [2,8,12] },
    { "name": "n_a",      "translation": [0,0.05,0],       "children": [3] },
    { "name": "n_b",      "translation": [0,0.07,0],       "children": [4] },
    { "name": "n_c",      "translation": [0,0.10,0],       "children": [5,16,21] },
    { "name": "n_d",      "translation": [0,0.06,0],       "children": [6] },
    { "name": "n_e",      "translation": [0,0.04,0],       "children": [7] },
    { "name": "n_f",      "translation": [0,0.08,0] },
    { "name": "n_g",      "translation": [0.07,-0.02,0],   "children": [9] },
    { "name": "n_h",      "translation": [0,-0.23,0],      "children": [10] },
    { "name": "n_i",      "translation": [0,-0.23,0],      "children": [11] },
    { "name": "n_j",      "translation": [0,-0.02,0.06] },
    { "name": "n_k",      "translation": [-0.07,-0.02,0],  "children": [13] },
    { "name": "n_l",      "translation": [0,-0.23,0],      "children": [14] },
    { "name": "n_m",      "translation": [0,-0.23,0],      "children": [15] },
    { "name": "n_n",      "translation": [0,-0.02,0.06] },
    { "name": "n_o",      "translation": [0.04,0.05,0],    "children": [17] },
    { "name": "n_p",      "translation": [0.05,0.01,0],    "children": [18] },
    { "name": "n_q",      "translation": [0.10,-0.10,0],   "children": [19,20] },
    { "name": "n_r",      "translation": [0.03,-0.03,0] },
    { "name": "n_s",      "translation": [0.10,-0.10,0] },
    { "name": "n_t",      "translation": [-0.04,0.05,0],   "children": [22] },
    { "name": "n_u",      "translation": [-0.05,0.01,0],   "children": [23] },
    { "name": "n_v",      "translation": [-0.10,-0.10,0],  "children": [24,25] },
    { "name": "n_w",      "translation": [-0.03,-0.03,0] },
    { "name": "n_x",      "translation": [-0.10,-0.10,0] }
  ],
  "skins": [ { "joints": [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25] } ],
  "buffers": [ { "byteLength": 156, "uri": "data:application/octet-stream;base64,%s" } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,  "byteLength": 12 },
    { "buffer": 0, "byteOffset": 12, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 60, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 108, "byteLength": 48 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0.0], "max": [1.0] },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 3, "componentType": 5126, "count": 3, "type": "VEC4" }
  ],
  "animations": [
    {
      "name": "Walk",
      "samplers": [
        { "input": 0, "output": 1, "interpolation": "LINEAR" },
        { "input": 0, "output": 2, "interpolation": "LINEAR" },
        { "input": 0, "output": 3, "interpolation": "LINEAR" }
      ],
      "channels": [
        { "sampler": 0, "target": { "node": 2, "path": "rotation" } },
        { "sampler": 1, "target": { "node": 4, "path": "rotation" } },
        { "sampler": 2, "target": { "node": 3, "path": "rotation" } }
      ]
    }
  ]
}`,
		extras, encoded);
	defer json.free(mem);

	return file::save(path, (char[])json);
}

// Where the fold fixture puts the joints below the fold at `time`, walked down
// from the file's own numbers. Deliberately not shared with the importer: an
// expectation computed by the code under test only proves that code is
// self-consistent.
//
// Returns chest, neck, head and the left shoulder, in that order.
fn Vec3[4] fold_expected(float time)
{
	Quaternionf folded = key_slerp(
		quaternion::IDENTITY, turn({ 1, 0, 0 }, FOLD_A), quaternion::IDENTITY, time);
	Quaternionf second = key_slerp(
		quaternion::IDENTITY, turn({ 1, 0, 0 }, FOLD_C), quaternion::IDENTITY, time);
	Quaternionf kept = key_slerp(
		quaternion::IDENTITY, turn({ 0, 0, 1 }, FOLD_B), quaternion::IDENTITY, time);

	// n_a turns, so everything above it swings about where n_a rests; n_b turns
	// too, so the link from n_b up to the chest carries both.
	Vec3 fold_at = { 0, 0.57f, 0 };
	Vec3 chest = fold_at
		+ folded.rotate_vec3({ 0, 0.07f, 0 })
		+ folded.mul(second).rotate_vec3({ 0, 0.10f, 0 });
	Quaternionf below = folded.mul(second).mul(kept);

	Vec3 neck = chest + below.rotate_vec3({ 0, 0.10f, 0 });
	Vec3 head = neck + below.rotate_vec3({ 0, 0.08f, 0 });
	Vec3 shoulder = chest + below.rotate_vec3({ 0.09f, 0.06f, 0 });

	return { chest, neck, head, shoulder };
}

// Where a named joint ended up, or a marker far from anything the fixture
// reaches so a missing name fails a position check rather than passing one.
fn Vec3 joint_named(String[] names, Vec3[] placed, String want)
{
	foreach (usz j, name : names)
	{
		if (name == want && j < placed.len) return placed[j];
	}
	return { 1.0e9f, 1.0e9f, 1.0e9f };
}

fn bool has_name(String[] names, String want)
{
	foreach (name : names)
	{
		if (name == want) return true;
	}
	return false;
}

<*
 A rig shaped like a body plan is carried onto it, whatever its joints are called.

 The headline claim, and the one a name table could never make: not one joint in
 the fixture is spelled anything like a body-plan dot, and all seventeen dots come
 back filled. The nine links the plan has no dot for — a floor root, two spare
 spine and neck segments, two clavicles, two twist bones and two toes — fold.
*>
fn void a_rig_is_matched_by_its_shape() @test
{
	String path = FOLD_FIXTURE;
	if (catch write_fold_fixture(path))
	{
		test::@check(false, "the fold fixture could be written");
		return;
	}

	crig::Preset plan = match_plan();
	crig::Preset[1] plans = { plan };

	crig::AnimImportReport report;
	crig::AnimTemplate walk = crig::import_gltf_animation(
		mem, path, { .plans = plans[..] }, &report)!!;
	defer walk.free(mem);

	test::@check(report.plan_matched == "Biped", "a rig shaped like the plan is matched onto it");
	test::@check(report.matched_joints == 17, "every one of the plan's dots gets a joint");
	test::@check(report.folded_joints == 9, "and the nine links it has no dot for fold, rather than being kept");

	gltf::GltfStream stream = gltf::open(path, mem)!!;
	String[] names;
	rig::Skeleton rest = crig::read_rest_skeleton(mem, &stream, &names, options: { .plans = plans[..] })!!;
	stream.close();
	defer
	{
		foreach (name : names) alloc::free(mem, name.ptr);
		alloc::free(mem, names);
		rest.free(mem);
	}

	test::@check(rest.len() == 17, "the skeleton is the plan's seventeen joints, not the file's twenty-six");

	bool named_on_plan = true;
	foreach (name : names)
	{
		if (name.len > 2 && name[:2] == "n_") named_on_plan = false;
	}
	test::@check(named_on_plan, "and comes back in the plan's words, not the file's");

	// Named individually rather than counted: seventeen joints with seventeen
	// names could still be seventeen wrong ones.
	String[6] expected = { "hips", "spine", "chest", "wrist_L", "ankle_R", "head" };
	bool all_there = true;
	foreach (want : expected)
	{
		if (!has_name(names, want)) all_there = false;
	}
	test::@check(all_there, "with the dots the plan actually names");
}

<*
 A joint the plan has no dot for folds into the one below it, carrying its turn.

 Renaming is the easy half. A fold that took the wrong joint's rotation, or took
 it in the wrong order, or lost it, still comes back with a `chest` entry and a
 plausible-looking template — so this checks where the joints below the fold end
 up, against the file's own numbers.
*>
fn void a_folded_joint_composes_into_its_child() @test
{
	String path = FOLD_FIXTURE;
	if (catch fault error = write_fold_fixture(path))
	{
		test::@check(false, "could not write %s (%s)", path, error);
		return;
	}

	crig::Preset plan = match_plan();
	crig::Preset[1] plans = { plan };

	crig::AnimImportReport report;
	crig::AnimTemplate walk = crig::import_gltf_animation(
		mem, path, { .plans = plans[..] }, &report)!!;
	defer walk.free(mem);

	test::@check(report.folded_animated, "a fold over an animated joint is reported as needing samples");

	gltf::GltfStream stream = gltf::open(path, mem)!!;
	String[] names;
	rig::Skeleton rest = crig::read_rest_skeleton(mem, &stream, &names, options: { .plans = plans[..] })!!;
	stream.close();
	defer
	{
		foreach (name : names) alloc::free(mem, name.ptr);
		alloc::free(mem, names);
		rest.free(mem);
	}

	// Deliberately off the sample grid. A fold that swallows an animated joint
	// costs the clip its exactness between keys, which `sample_times` subdivides
	// to win back — and a check landing only on those samples would be exact by
	// construction and would say nothing about how far it bows in between. The
	// source's own keys are at 0, 0.5 and 1 and the subdivision quarters those,
	// so none of these times is one the importer ever evaluated.
	float[5] times = { 0.06f, 0.19f, 0.3f, 0.55f, 0.71f };
	float worst = 0.0f;
	foreach (time : times)
	{
		rig::Pose pose = walk.pose(mem, &rest, names, time);
		defer pose.free(mem);

		Vec3[] placed = posed_joints(&rest, pose);
		defer alloc::free(mem, placed);

		Vec3[4] want = fold_expected(time);
		String[4] labels = { "chest", "neck", "head", "shoulder_L" };
		foreach (usz i, label : labels)
		{
			float gap = (joint_named(names, placed, label) - want[i]).length();
			if (gap > worst) worst = gap;
		}
	}

	// Not held to EXACT, unlike the conversion itself: composing two rotations
	// the source interpolates apart from each other is an approximation between
	// keys however finely it is sampled, so what is checked is that subdivision
	// keeps it small rather than that it is gone. As a fraction of the rig,
	// because that is the only scale a position error means anything against.
	float allowed = rest.height() * 2.0e-3f;
	io::printfn("  worst joint below the fold, off the sample grid: %.7f of %.7f allowed", worst, allowed);
	test::@check(worst < allowed, "and everything below the fold lands where the file puts it");
}

<*
 No emitted bone is a point.

 The defect that motivated matching by shape at all. A rig that stacks its root,
 its pelvis and its waist at one coordinate — which real ones do, because a pivot
 is not a segment — will hand a name table a zero-length bone, and a zero-length
 bone has no direction for the binder to measure weights along or for
 `AnimKeyDot.axis_for` to retarget onto. Arc length cannot make that mistake: a
 joint sitting on top of its parent is at fraction zero, and no plan dot is.
*>
fn void a_coincident_joint_is_not_taken_as_a_bone() @test
{
	String path = FOLD_FIXTURE;
	if (catch fault error = write_fold_fixture(path))
	{
		test::@check(false, "could not write %s (%s)", path, error);
		return;
	}

	crig::Preset plan = match_plan();
	crig::Preset[1] plans = { plan };

	gltf::GltfStream stream = gltf::open(path, mem)!!;
	String[] names;
	rig::Skeleton rest = crig::read_rest_skeleton(mem, &stream, &names, options: { .plans = plans[..] })!!;
	stream.close();
	defer
	{
		foreach (name : names) alloc::free(mem, name.ptr);
		alloc::free(mem, names);
		rest.free(mem);
	}

	float height = rest.height();
	float shortest = height;
	String pinched = "";
	foreach (usz j, parent : rest.parents)
	{
		if (parent < 0) continue;

		float span = (rest.joints[j] - rest.joints[(usz)parent]).length();
		if (span >= shortest) continue;
		shortest = span;
		pinched = names[j];
	}

	io::printfn("  shortest bone: %s at %.5f, %.2f%% of the rig", pinched, shortest, shortest / height * 100.0f);
	test::@check(shortest > height * 0.01f, "no bone comes back shorter than a hundredth of the rig");
}

<*
 A rig of the wrong shape is refused, and keeps its own names.

 Refusing is a result. A four-legged rig has its front legs where a biped has
 arms, and a matcher that took every rig it was offered would map them there and
 play a walk on a horse's shoulders. The fixture is the biped one with its arms
 taken off, so what is left cannot fill the plan.
*>
fn void a_rig_of_the_wrong_shape_is_refused() @test
{
	String path = ARMLESS_FIXTURE;
	// The same figure with no arms: six of the plan's seventeen dots have nothing
	// to match, which is below what `JointMatch.usable` will act on.
	if (catch write_armless_fixture(path))
	{
		test::@check(false, "the armless fixture could be written");
		return;
	}

	crig::Preset plan = match_plan();
	crig::Preset[1] plans = { plan };

	crig::AnimImportReport report;
	crig::AnimTemplate walk = crig::import_gltf_animation(
		mem, path, { .plans = plans[..] }, &report)!!;
	defer walk.free(mem);

	test::@check(report.plan_matched == "", "a rig that cannot fill the plan is not matched onto it");
	test::@check(report.folded_joints == 0, "and nothing is folded out of it");

	bool kept_own = false;
	foreach (frame : walk.keyframes)
	{
		foreach (dot : frame.dots)
		{
			if (dot.joint_name.len > 2 && dot.joint_name[:2] == "n_") kept_own = true;
		}
	}
	test::@check(kept_own, "its joints keep the names the file gave them");
}

// The fold fixture with both arms removed, which leaves a rig the biped plan
// cannot fill.
fn void? write_armless_fixture(String path)
{
	float[27] numbers;
	usz at = 0;
	numbers[at++] = 0.0f;
	numbers[at++] = 0.5f;
	numbers[at++] = 1.0f;

	Quaternionf[3] folded = { quaternion::IDENTITY, turn({ 1, 0, 0 }, FOLD_A), quaternion::IDENTITY };
	foreach (rotation : folded)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}
	Quaternionf[3] kept = { quaternion::IDENTITY, turn({ 0, 0, 1 }, FOLD_B), quaternion::IDENTITY };
	foreach (rotation : kept)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	char[] bytes = ((char*)&numbers)[:27 * 4];
	String encoded = base64::encode(mem, bytes);
	defer encoded.free(mem);

	String json = string::format(mem,
		`{
  "asset": { "version": "2.0" },
  "scenes": [ { "nodes": [0] } ],
  "scene": 0,
  "nodes": [
    { "name": "n_root",   "translation": [0,0,0],          "children": [1] },
    { "name": "n_pelvis", "translation": [0,0.52,0],       "children": [2,8,12] },
    { "name": "n_a",      "translation": [0,0.05,0],       "children": [3] },
    { "name": "n_b",      "translation": [0,0.07,0],       "children": [4] },
    { "name": "n_c",      "translation": [0,0.10,0],       "children": [5] },
    { "name": "n_d",      "translation": [0,0.06,0],       "children": [6] },
    { "name": "n_e",      "translation": [0,0.04,0],       "children": [7] },
    { "name": "n_f",      "translation": [0,0.08,0] },
    { "name": "n_g",      "translation": [0.07,-0.02,0],   "children": [9] },
    { "name": "n_h",      "translation": [0,-0.23,0],      "children": [10] },
    { "name": "n_i",      "translation": [0,-0.23,0],      "children": [11] },
    { "name": "n_j",      "translation": [0,-0.02,0.06] },
    { "name": "n_k",      "translation": [-0.07,-0.02,0],  "children": [13] },
    { "name": "n_l",      "translation": [0,-0.23,0],      "children": [14] },
    { "name": "n_m",      "translation": [0,-0.23,0],      "children": [15] },
    { "name": "n_n",      "translation": [0,-0.02,0.06] }
  ],
  "skins": [ { "joints": [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15] } ],
  "buffers": [ { "byteLength": 108, "uri": "data:application/octet-stream;base64,%s" } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0,  "byteLength": 12 },
    { "buffer": 0, "byteOffset": 12, "byteLength": 48 },
    { "buffer": 0, "byteOffset": 60, "byteLength": 48 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "SCALAR", "min": [0.0], "max": [1.0] },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC4" },
    { "bufferView": 2, "componentType": 5126, "count": 3, "type": "VEC4" }
  ],
  "animations": [
    {
      "name": "Walk",
      "samplers": [
        { "input": 0, "output": 1, "interpolation": "LINEAR" },
        { "input": 0, "output": 2, "interpolation": "LINEAR" }
      ],
      "channels": [
        { "sampler": 0, "target": { "node": 2, "path": "rotation" } },
        { "sampler": 1, "target": { "node": 4, "path": "rotation" } }
      ]
    }
  ]
}`,
		encoded);
	defer json.free(mem);

	return file::save(path, (char[])json);
}

<*
 A file that says nothing about itself adopts the plan it turned out to be shaped
 like, and a file that does say is taken at its word.

 The inference is why matching earns its keep at the pack level: a downloaded clip
 carries no crig metadata, and a pack with no plan is offered to every rig
 including the ones its joints mean nothing on.
*>
fn void a_pack_adopts_the_matched_plan() @test
{
	String path = FOLD_FIXTURE;
	if (catch write_fold_fixture(path))
	{
		test::@check(false, "the fold fixture could be written");
		return;
	}

	crig::Preset plan = match_plan();
	crig::Preset[1] plans = { plan };

	crig::AnimPackReport report;
	crig::AnimPack? pack = crig::read_pack(mem, path, &report, plans[..]);
	if (catch pack)
	{
		test::@check(false, "the fold fixture reads as a pack");
		return;
	}
	defer pack.free(mem);

	test::@check(report.plan_matched == "Biped", "the pack settles on one plan for the whole file");
	test::@check(pack.plan == "biped", "a file that declares no plan takes the tag of the one it fits");
	test::@check(report.plan_inferred, "and says so, rather than letting it pass for the file's own word");

	// The clips and the skeleton have to agree, which is what settling the plan
	// once buys. A clip naming a joint the skeleton does not have plays nothing.
	bool clips_agree = pack.clips.len > 0;
	foreach (clip : pack.clips)
	{
		foreach (frame : clip.keyframes)
		{
			foreach (dot : frame.dots)
			{
				if (!has_name(pack.joint_names, dot.joint_name)) clips_agree = false;
			}
		}
	}
	test::@check(clips_agree, "and every joint its clips name is one its skeleton has");

	String stated = "build/anim-import-fold-tagged.gltf";
	if (catch write_fold_fixture(stated, "\n  \"extras\": { \"plan\": \"quadruped\" },"))
	{
		test::@check(false, "the tagged fold fixture could be written");
		return;
	}

	crig::AnimPackReport told;
	crig::AnimPack? spoken = crig::read_pack(mem, stated, &told, plans[..]);
	if (catch spoken)
	{
		test::@check(false, "the tagged fold fixture reads as a pack");
		return;
	}
	defer spoken.free(mem);

	test::@check(spoken.plan == "quadruped", "a plan the file states outright beats the measurement");
	test::@check(!told.plan_inferred, "and is not reported as inferred");
}

<*
 A pack that declares its own plan is a reference, never something to be matched.

 crig's own packs are written in their plan's own words, and re-deriving those
 names from shape would be re-deriving them from a plan that came from them —
 so `scan_packs` reads the declaring files first and matches only the rest. This
 is the check that a library round trip leaves the shipped packs alone.
*>
fn void a_declared_pack_keeps_its_own_names() @test
{
	String folder = "build/anim-scan";
	if (catch path::mkdir((Path)folder))
	{
		// Already there from an earlier run, which is fine.
	}

	// A pack that says what it is, written the way make-anims writes one.
	rig::Skeleton skeleton = fixture_skeleton();
	defer skeleton.free(mem);

	crig::AnimTemplate[1] clips = {
		{ .name = "Sent", .duration = 1.0f, .keyframes = SENT_FRAMES[..], .loop = true },
	};
	rig::TriMesh body = box_body();
	defer body.free(mem);

	crig::AnimPackMeta meta = { .plan = "test", .name = "Declared", .tags = {} };
	if (catch crig::export_pack_glb(
		mem, "build/anim-scan/declared.glb", &skeleton, JOINT_NAMES[..], clips[..], body, meta))
	{
		test::@check(false, "the declared pack could be written");
		return;
	}

	crig::AnimPack[] library = crig::scan_packs(mem, folder);
	defer crig::free_packs(mem, library);

	bool found = false;
	foreach (&pack : library)
	{
		if (pack.plan != "test") continue;
		found = true;

		bool own_names = true;
		foreach (usz j, name : pack.joint_names)
		{
			if (j < JOINT_NAMES.len && name != JOINT_NAMES[j]) own_names = false;
		}
		test::@check(own_names, "a pack that declares its plan comes back with its own joint names");
	}
	test::@check(found, "and is in the library at all");
}

// A box, so a declared pack has a body and can serve as a body plan.
fn rig::TriMesh box_body()
{
	Vec3[] positions = alloc::new_array(mem, Vec3, 8);
	usz at = 0;
	for (int i = 0; i < 8; i++)
	{
		positions[at++] = {
			(i & 1) != 0 ? 0.4f : -0.4f,
			(i & 2) != 0 ? 1.0f : 0.0f,
			(i & 4) != 0 ? 0.3f : -0.3f,
		};
	}

	uint[36] faces = {
		0,1,2, 1,3,2, 4,6,5, 5,6,7, 0,2,4, 2,6,4,
		1,5,3, 3,5,7, 0,4,1, 1,4,5, 2,3,6, 3,7,6,
	};
	uint[] indices = alloc::new_array(mem, uint, 36);
	foreach (usz i, face : faces) indices[i] = face;

	return { .positions = positions, .indices = indices };
}

// ---------------------------------------------------------------------------

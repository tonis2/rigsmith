<*
 Clips from a coarse game rig that stands facing the other way.

 The rig here is a real one's skeleton, joint for joint: a 27-bone character
 from an old game, exported from Blender. It is everything the shape matcher's
 fixtures are not. It faces −Z with its left side on −X. It has one spine bone
 from the waist to the neck, no toes and no crown of the head. Its "chest" bone
 is really the left clavicle. Its legs hang off a pelvis bone that drops down
 the midline from the joint the body parts at. And a tail runs two body-depths
 behind it.

 Before, the file matched no body plan at all, because the plan asked for a
 joint per dot, fingers included. So its clips fell through to a raw shape
 guess against the open rig. That guess put the left arm on the right side,
 every leg joint one further down its chain, and the arms on the legs. The
 checks here hold each of those.
*>
module crig_tests::coarse_rig;

import crig;
import rig;
import gltf;
import std::core::test;
import std::encoding::base64;
import std::io::file;
import std::math;
import std::math::quaternion;
import std::collections::list;

const String COARSE_FIXTURE = "build/coarse-rig.gltf";

// How far the clip swings the left thigh about +X at its middle key. On a rig
// facing −Z, that carries the foot toward −Z, which is the figure's front.
const float STRIDE = 0.6f;

// How far the second clip spins the root about Y while the two bones stacked on
// it spin back. Short of half a turn, so the slerp has one way round.
const float SPIN = 2.97f;

fn void? write_coarse_fixture(String path)
{
	float[39] numbers;
	usz at = 0;
	numbers[at++] = 0.0f;
	numbers[at++] = 0.5f;
	numbers[at++] = 1.0f;
	Quaternionf[3] swing = {
		quaternion::IDENTITY,
		quaternion::from_axis_angle{float}({ 1, 0, 0 }, STRIDE),
		quaternion::IDENTITY,
	};
	foreach (rotation : swing)
	{
		numbers[at++] = rotation.v.x;
		numbers[at++] = rotation.v.y;
		numbers[at++] = rotation.v.z;
		numbers[at++] = rotation.v.w;
	}

	foreach (angle : (float[]){ SPIN, -SPIN })
	{
		for (usz k = 0; k < 3; k++)
		{
			Quaternionf spun = quaternion::from_axis_angle{float}({ 0, 1, 0 }, k == 1 ? angle : 0.0f);
			numbers[at++] = spun.v.x;
			numbers[at++] = spun.v.y;
			numbers[at++] = spun.v.z;
			numbers[at++] = spun.v.w;
		}
	}

	char[] bytes = ((char*)&numbers)[:39 * 4];
	String encoded = base64::encode(mem, bytes);
	defer encoded.free(mem);

	String json = string::format(mem,
		`{
  "asset": { "version": "2.0" },
  "scenes": [ { "nodes": [0] } ],
  "nodes": [
    { "name": "root", "translation": [0,2.4,0], "children": [1,14] },
    { "name": "spine", "translation": [0,0,0], "children": [2,7,9] },
    { "name": "chest", "translation": [0,0.844,0.103], "children": [3] },
    { "name": "L_upper_arm", "translation": [-0.475,-0.212,0.008], "children": [4] },
    { "name": "L_forearm", "translation": [-0.479,-0.48,0.048], "children": [5] },
    { "name": "L_hand", "translation": [-0.572,-0.572,-0.047], "children": [6] },
    { "name": "L_hand_end", "translation": [-0.065,-0.252,0] },
    { "name": "neck", "translation": [0,0.844,0.103], "children": [8] },
    { "name": "head", "translation": [0,0.249,-0.021] },
    { "name": "R_shoulder", "translation": [0,0.844,0.103], "children": [10] },
    { "name": "R_upper_arm", "translation": [0.475,-0.212,0.008], "children": [11] },
    { "name": "R_forearm", "translation": [0.479,-0.48,0.048], "children": [12] },
    { "name": "R_hand", "translation": [0.572,-0.572,-0.047], "children": [13] },
    { "name": "R_hand_end", "translation": [0.065,-0.252,0] },
    { "name": "hips", "translation": [0,0,0], "children": [15,19,23] },
    { "name": "L_hip", "translation": [0,-0.42,-0.001], "children": [16] },
    { "name": "L_thigh", "translation": [-0.25,0,0], "children": [17] },
    { "name": "L_shin", "translation": [0,-0.8,0], "children": [18] },
    { "name": "L_foot", "translation": [0,-0.742,0.108] },
    { "name": "R_hip", "translation": [0,-0.42,-0.001], "children": [20] },
    { "name": "R_thigh", "translation": [0.25,0,0], "children": [21] },
    { "name": "R_shin", "translation": [0.001,-0.8,-0.002], "children": [22] },
    { "name": "R_foot", "translation": [0.001,-0.743,0.105] },
    { "name": "tail_base", "translation": [0,-0.42,-0.001], "children": [24] },
    { "name": "tail_01", "translation": [0,0.19,0.317], "children": [25] },
    { "name": "tail_02", "translation": [0,-0.002,1.37], "children": [26] },
    { "name": "tail_03", "translation": [0,-0.001,0.81] }
  ],
  "skins": [ { "joints": [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26] } ],
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
      "name": "stride",
      "samplers": [ { "input": 0, "output": 1, "interpolation": "LINEAR" } ],
      "channels": [ { "sampler": 0, "target": { "node": 16, "path": "rotation" } } ]
    },
    {
      "name": "spin",
      "samplers": [
        { "input": 0, "output": 2, "interpolation": "LINEAR" },
        { "input": 0, "output": 3, "interpolation": "LINEAR" }
      ],
      "channels": [
        { "sampler": 0, "target": { "node": 0, "path": "rotation" } },
        { "sampler": 1, "target": { "node": 1, "path": "rotation" } },
        { "sampler": 1, "target": { "node": 14, "path": "rotation" } }
      ]
    }
  ]
}`,
		encoded);
	defer json.free(mem);

	return file::save(path, (char[])json);
}

// The shipped biped plan. It declares none of its joints optional, which is
// part of what is under test: its fingers have to be read off its shape.
fn crig::Preset biped_plan()
{
	crig::AnimPack human = crig::read_pack(mem, "assets/animations/humanoid.glb")!!;
	defer human.free(mem);
	return human.preset(mem);
}

// The source joint the plan's dot `want` was carried from, or "".
fn String source_of(gltf::GltfStream* stream, String[] names, usz[] nodes, String want)
{
	foreach (usz j, name : names)
	{
		if (name == want) return stream.gltf.nodes.get_ref((sz)nodes[j]).name;
	}
	return "";
}

fn void a_back_facing_rig_reads_as_facing_forward() @test
{
	write_coarse_fixture(COARSE_FIXTURE)!!;

	gltf::GltfStream coarse = gltf::open(COARSE_FIXTURE, mem)!!;
	defer coarse.close();
	test::@check(crig::faces_back(&coarse), "a rig keeping its left joints on -X faces -Z");

	gltf::GltfStream human = gltf::open("assets/animations/humanoid.glb", mem)!!;
	defer human.close();
	test::@check(!crig::faces_back(&human), "the shipped humanoid faces +Z and is left as it stands");

	// Faces −X, its sides named along Z: stood sideways, not turned round —
	// however far its hind legs sit out of line along X.
	gltf::GltfStream quadruped = gltf::open("assets/animations/quadruped.glb", mem)!!;
	defer quadruped.close();
	test::@check(!crig::faces_back(&quadruped), "the shipped quadruped faces -X and is left as it stands");
}

fn void a_coarse_rig_matches_the_biped_joint_for_joint() @test
{
	write_coarse_fixture(COARSE_FIXTURE)!!;
	crig::Preset plan = biped_plan();
	defer crig::free_preset(mem, plan);
	crig::Preset[1] plans = { plan };

	crig::AnimImportReport report;
	crig::AnimTemplate stride = crig::import_gltf_animation(mem, COARSE_FIXTURE, { .plans = plans[..] }, &report)!!;
	defer stride.free(mem);
	test::@check(report.plan_matched.len > 0, "the coarse rig matched the biped plan");

	gltf::GltfStream stream = gltf::open(COARSE_FIXTURE, mem)!!;
	defer stream.close();
	String[] names;
	usz[] nodes;
	rig::Skeleton rest = crig::read_rest_skeleton(mem, &stream, &names,
		options: { .plans = plans[..] }, joint_nodes: &nodes)!!;
	defer
	{
		foreach (name : names) alloc::free(mem, name.ptr);
		alloc::free(mem, names);
		alloc::free(mem, nodes);
		rest.free(mem);
	}

	// Sides by what the file calls them, not by where the file put them.
	test::eq(source_of(&stream, names, nodes, "thigh_L"), "L_thigh");
	test::eq(source_of(&stream, names, nodes, "thigh_R"), "R_thigh");
	// The legs start at the hip joint, not at the pelvis pivots above it.
	test::eq(source_of(&stream, names, nodes, "knee_L"), "L_shin");
	test::eq(source_of(&stream, names, nodes, "ankle_L"), "L_foot");
	// The arms are arms, one joint each, and the bare end marker folds.
	test::eq(source_of(&stream, names, nodes, "clavicle_L"), "chest");
	test::eq(source_of(&stream, names, nodes, "shoulder_L"), "L_upper_arm");
	test::eq(source_of(&stream, names, nodes, "elbow_L"), "L_forearm");
	test::eq(source_of(&stream, names, nodes, "wrist_L"), "L_hand");
	test::eq(source_of(&stream, names, nodes, "elbow_R"), "R_forearm");
	test::eq(source_of(&stream, names, nodes, "neck"), "neck");
	test::eq(source_of(&stream, names, nodes, "head"), "head");

	// And the figure is stood facing +Z, its left on +X.
	foreach (usz j, name : names)
	{
		if (name == "thigh_L") test::@check(rest.joints[j].x > 0.0f, "the left thigh is on +X after the turn");
	}
}

fn void a_stride_forward_stays_forward() @test
{
	write_coarse_fixture(COARSE_FIXTURE)!!;
	crig::Preset plan = biped_plan();
	defer crig::free_preset(mem, plan);
	crig::Preset[1] plans = { plan };

	crig::AnimTemplate stride = crig::import_gltf_animation(mem, COARSE_FIXTURE, { .plans = plans[..] })!!;
	defer stride.free(mem);

	gltf::GltfStream stream = gltf::open(COARSE_FIXTURE, mem)!!;
	defer stream.close();
	String[] names;
	rig::Skeleton rest = crig::read_rest_skeleton(mem, &stream, &names, options: { .plans = plans[..] })!!;
	defer
	{
		foreach (name : names) alloc::free(mem, name.ptr);
		alloc::free(mem, names);
		rest.free(mem);
	}

	rig::Pose pose = stride.pose(mem, &rest, names, 0.5f, false);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &rest, pose)!!;
	defer alloc::free(mem, palette);

	// The file swings its left foot toward its own front, which is −Z in the
	// file and +Z once it is stood the way crig reads a figure.
	bool found = false;
	foreach (usz j, name : names)
	{
		if (name != "ankle_L") continue;
		found = true;
		Vec3 moved = rest.joints[j].transform(palette[j]);
		test::@check(moved.z > rest.joints[j].z + 0.5f,
			"the stride carries the left foot forward: z %f from %f", moved.z, rest.joints[j].z);
	}
	test::@check(found, "the stride names the left ankle");
}

<*
 A root the clip spins while the bones stacked on it spin back is a body
 standing still.

 On the file's own rig that is exactly what it looks like: the root, the spine
 and the pelvis share one point, so nothing moves. Carried as written onto a
 rig whose spine and thighs sit off its hips, the hips would turn half round
 and throw the upper body below them. The hips' turn is read from where the
 legs went instead, and they went nowhere.
*>
fn void a_root_spin_its_bones_undo_leaves_the_body_still() @test
{
	write_coarse_fixture(COARSE_FIXTURE)!!;
	crig::Preset plan = biped_plan();
	defer crig::free_preset(mem, plan);
	crig::Preset[1] plans = { plan };

	crig::AnimTemplate spin = crig::import_gltf_animation(mem, COARSE_FIXTURE, { .plans = plans[..], .name = "spin" })!!;
	defer spin.free(mem);

	foreach (joint : (String[]){ "hips", "chest", "thigh_L", "thigh_R" })
	{
		crig::AnimKeyDot entry = spin.entry_at(joint, 0.5f);
		test::@check(entry.angle < 0.05f, "%s turns %f at the height of the spin", joint, entry.angle);
	}
}

fn void only_an_arm_held_at_another_height_takes_the_source_pose() @test
{
	// An A-pose arm against a T-pose one: taken.
	test::@check(crig::rest_pose_differs({ 0.707f, -0.707f, 0 }, { 1, 0, 0 }), "an A-pose upper arm");
	test::@check(crig::rest_pose_differs({ -0.707f, -0.707f, 0 }, { -1, 0.1f, 0 }), "and the right one");
	// A few degrees is two builders, not two poses.
	test::@check(!crig::rest_pose_differs({ 0.99f, -0.14f, 0 }, { 1, 0, 0 }), "an arm eight degrees lower");
	// A branching chest measured toward a clavicle on one rig and upward on the other.
	test::@check(!crig::rest_pose_differs({ 0, 1, 0 }, { -1, 0, 0.2f }), "a chest");
	// A clavicle drawn back and up on one rig: a difference in the rigs.
	test::@check(!crig::rest_pose_differs({ 0.91f, -0.41f, 0 }, { 0.3f, 0.5f, -0.8f }), "a clavicle");
	// Legs point down on both and are left to the carry.
	test::@check(!crig::rest_pose_differs({ 0, -1, 0 }, { 0.2f, -0.98f, 0 }), "a leg");
}

<*
 A clip keyed on a figure whose arms hang holds a T-posed figure's arms down.

 The clip keys the arm at rest, and "at rest" on the rig it was made on is
 forty-five degrees down; carried relative to the target's own rest it would
 hold the arm straight out.
*>
fn void an_arm_modelled_hanging_hangs_on_a_t_posed_rig() @test
{
	Vec3[5] at = { { 0, 1, 0 }, { 0, 1.5f, 0 }, { 0.2f, 1.5f, 0 }, { 0.5f, 1.5f, 0 }, { 0.8f, 1.5f, 0 } };
	int[5] parents = { -1, 0, 1, 2, 3 };
	rig::Skeleton skeleton = { .joints = at[..], .parents = parents[..] };
	String[5] names = { "hips", "chest", "shoulder_L", "elbow_L", "wrist_L" };

	crig::AnimKeyDot[3] dots = {
		{ .joint_name = "chest", .axis = { 0, 0, 1 }, .bone = { 0, 1, 0 }, .channels = ROTATION },
		{ .joint_name = "shoulder_L", .axis = { 0, 0, 1 }, .bone = { 0.707f, -0.707f, 0 }, .channels = ROTATION },
		{ .joint_name = "elbow_L", .axis = { 0, 0, 1 }, .bone = { 0.707f, -0.707f, 0 }, .channels = ROTATION },
	};
	crig::AnimKeyframe[2] keys = { { .time = 0.0f, .dots = dots[..] }, { .time = 1.0f, .dots = dots[..] } };
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..] };

	rig::Pose pose = clip.pose(mem, &skeleton, names[..], 0.5f, false);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &skeleton, pose)!!;
	defer alloc::free(mem, palette);

	Vec3 shoulder = at[2].transform(palette[2]);
	Vec3 elbow = at[3].transform(palette[3]);
	Vec3 wrist = at[4].transform(palette[4]);
	test::@check((shoulder - at[2]).length() < 1.0e-4f, "the chest stays upright, so the shoulder stays put");
	test::@check(math::abs(elbow.y - (1.5f - 0.3f * 0.707f)) < 0.01f, "the upper arm hangs at forty-five degrees: elbow y %f", elbow.y);
	test::@check(math::abs(wrist.y - (1.5f - 0.6f * 0.707f)) < 0.01f, "and the forearm with it: wrist y %f", wrist.y);
}

<*
 A tail the plan has no word for still reaches a rig that has one.

 The importer keeps the file's tail under the file's names instead of folding it
 away, and a rig's tail — unnamed, a joint shorter, hanging down and out to one
 side — takes it by hanging off the same joint and pointing into the same half
 of space.
*>
fn void a_tail_reaches_a_rig_with_a_tail() @test
{
	write_coarse_fixture(COARSE_FIXTURE)!!;
	crig::Preset plan = biped_plan();
	defer crig::free_preset(mem, plan);
	crig::Preset[1] plans = { plan };

	crig::AnimPack pack = crig::read_pack(mem, COARSE_FIXTURE, plans: plans[..])!!;
	defer pack.free(mem);

	usz tail_joints = 0;
	foreach (name : pack.joint_names) if (name.starts_with("tail")) tail_joints++;
	test::eq(tail_joints, (usz)4);

	// The pack's own body, and in place of its tail three unnamed joints curling
	// off the hips to one side.
	List{Vec3} at;
	List{int} parents;
	List{String} names;
	at.init(tmem);
	parents.init(tmem);
	names.init(tmem);
	usz hips = 0;
	foreach (usz i, name : pack.joint_names)
	{
		if (name.starts_with("tail")) continue;
		if (name == "hips") hips = (usz)at.len();
		at.push(pack.rest.joints[i]);
		// Tail joints come after the body in the pack, so body parents keep their index.
		parents.push(pack.rest.parents[i]);
		names.push(name);
	}
	usz first = (usz)at.len();
	Vec3 root = pack.rest.joints[hips];
	// Hanging down and out to the side the way a tail modelled at rest does,
	// eighty degrees from the file's, which it holds straight out behind.
	at.push(root + { 0.0f, -0.3f, -0.4f });
	at.push(root + { 0.2f, -0.6f, -0.9f });
	at.push(root + { 0.9f, -1.6f, -0.8f });
	parents.push((int)hips);
	parents.push((int)first);
	parents.push((int)first + 1);
	for (usz k = 0; k < 3; k++) names.push("");
	rig::Skeleton skeleton = { .joints = at.array_view(), .parents = parents.array_view() };

	crig::PackReach reach = crig::measure_reach(mem, &pack, &skeleton, names.array_view());
	defer reach.free(mem);
	test::@check(reach.usable, "the body still matches");
	test::eq(reach.names[first], "tail_base");
	test::@check(reach.names[first + 1].starts_with("tail_0"), "the middle of the tail is the tail: %s", reach.names[first + 1]);
	test::@check(reach.names[first + 2].starts_with("tail_0"), "and so is its tip: %s", reach.names[first + 2]);
	test::eq(reach.names[hips], "hips");
}

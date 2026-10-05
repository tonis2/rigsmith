<*
 Look-at targets in files: a baked export carries the aimed head, and the packed
 glb gets the aims written into keys with none left on the clip.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::aim_export`
*>
module crig_tests::aim_export;

import crig;
import rig;
import gltf_edit;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

Vec3[4] joints @local = { { 0, 1, 0 }, { 0, 1.3f, 0 }, { 0, 1.6f, 0 }, { 0, 1.8f, 0 } };
int[4] parents @local = { -1, 0, 1, 2 };
String[4] names @local = { "hips", "chest", "neck", "head" };
const Vec3 FORWARD = { 0, 0, 1 };

fn rig::Skeleton chain_rig() => { .joints = joints[..], .parents = parents[..] };

// The hips sway between two keys while the head looks from one place to another.
fn crig::AnimTemplate aimed_clip()
{
	crig::AnimKeyDot[] first = alloc::new_array(mem, crig::AnimKeyDot, 1);
	first[0] = { .joint_name = "hips".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.0f, .channels = ROTATION };
	crig::AnimKeyDot[] last = alloc::new_array(mem, crig::AnimKeyDot, 1);
	last[0] = { .joint_name = "hips".copy(mem), .axis = { 0, 1, 0 }, .angle = 0.5f, .channels = ROTATION };
	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, 2);
	keys[0] = { .time = 0.0f, .dots = first };
	keys[1] = { .time = 1.0f, .dots = last };
	crig::AnimTemplate clip = { .name = "look".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
	crig::AnimTemplate placed = crig::clip_with_aim_target(mem, clip,
		crig::aim_target_defaults(mem, "Target 1", { 0.6f, 0.9f, 0.7f }, 0.0f));
	clip.free(mem);
	crig::AnimAim aim = crig::aim_defaults(mem, "head", "Target 1", FORWARD);
	crig::AnimTemplate with = crig::clip_with_aim(mem, placed, aim);
	placed.free(mem);
	crig::AnimTemplate both = crig::clip_with_target_key(mem, with, "Target 1", { .time = 1.0f, .at = { -0.5f, 1.0f, 0.4f }, .interpolation = LINEAR });
	with.free(mem);
	return both;
}

// What the viewport shows at `time`: the clip's pose with the aims over it.
fn rig::Pose shown(rig::Skeleton* skeleton, crig::AnimTemplate clip, float time)
{
	rig::Pose pose = clip.pose(mem, skeleton, names[..], time, false, honor_solo: false);
	crig::aim_pose(mem, skeleton, names[..], clip.aims, clip.aim_targets, time, clip.duration, clip.loop, &pose, skeleton.height());
	return pose;
}

fn float closeness(Quaternionf a, Quaternionf b) => math::abs(a.v.dot(b.v));

fn void a_baked_export_carries_the_aimed_head() @test
{
	rig::Skeleton skeleton = chain_rig();
	crig::AnimTemplate clip = aimed_clip();
	defer clip.free(mem);
	crig::AnimTemplate[1] source = { clip };

	gltf_edit::ReskinClip[] written = crig::reskin_clips(mem, &skeleton, names[..], source[..]);
	defer crig::free_reskin_clips(mem, written);
	test::@check(written.len == 1, "the clip was not written");
	if (written.len != 1) return;
	test::@check(written[0].times.len > clip.keyframes.len, "an aimed clip was not baked denser than its keys");

	gltf_edit::ReskinCurve* head = null;
	foreach (&curve : written[0].curves) if (curve.joint == 3) head = curve;
	test::@check(head != null, "the head has no channel");
	if (!head) return;
	test::@check(head.turns.len == written[0].times.len, "the head is not sampled at every time");
	if (head.turns.len != written[0].times.len) return;
	foreach (usz k, time : written[0].times)
	{
		rig::Pose expected = shown(&skeleton, clip, time);
		defer expected.free(mem);
		test::@check(closeness(head.turns[k], expected.rotations[3]) > 0.99999f,
			"the baked head at %s differs from what the viewport shows", time);
	}

	// A muted target bakes the authored motion.
	clip.aim_targets[0].mute = true;
	gltf_edit::ReskinClip[] quiet = crig::reskin_clips(mem, &skeleton, names[..], source[..]);
	defer crig::free_reskin_clips(mem, quiet);
	foreach (curve : quiet[0].curves) test::@check(curve.joint != 3, "a muted aim still moved the head");
}

fn void the_packed_clip_has_its_aims_written_into_keys() @test
{
	rig::Skeleton skeleton = chain_rig();
	crig::AnimTemplate clip = aimed_clip();
	defer clip.free(mem);

	crig::AnimTemplate flat = crig::clip_aims_flattened(mem, clip, &skeleton, names[..]);
	defer flat.free(mem);
	test::@check(flat.aims.len == 0 && flat.aim_targets.len == 0, "the flattened clip kept its aims");
	test::@check(clip.aims.len == 1, "flattening took the aim off its source");
	test::@check(flat.keyframes.len > clip.keyframes.len, "no samples were added");

	float[4] probes = { 0.0f, 0.25f, 0.5f, 1.0f };
	foreach (time : probes)
	{
		rig::Pose expected = shown(&skeleton, clip, time);
		defer expected.free(mem);
		rig::Pose baked = flat.pose(mem, &skeleton, names[..], time, false, honor_solo: false);
		defer baked.free(mem);
		for (usz j = 0; j < 4; j++)
		{
			test::@check(closeness(baked.rotations[j], expected.rotations[j]) > 0.9999f,
				"joint %d at %s differs from the aimed clip", j, time);
		}
	}

	// The hips are not an aim's to key: only their own two keys.
	usz hip_keys;
	foreach (frame : flat.keyframes) foreach (dot : frame.dots) if (dot.joint_name == "hips") hip_keys++;
	test::@check(hip_keys == 2, "the hips gained keys (%d)", hip_keys);

	// Nothing to bake: a plain copy, with no aims either way.
	clip.aim_targets[0].mute = true;
	crig::AnimTemplate plain = crig::clip_aims_flattened(mem, clip, &skeleton, names[..]);
	defer plain.free(mem);
	test::@check(plain.aims.len == 0 && plain.keyframes.len == clip.keyframes.len, "a muted aim was baked");
}

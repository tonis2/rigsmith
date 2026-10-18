<*
 Taking joints out of a clip (anim/keying.c3 `clip_without_joints`,
 `clip_with_joints_layered`) and the evaluation they lean on: a full-strength
 override is its keys exactly, and a joint only a layer turns is carried from
 the bone that layer's keys record.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::joint_layers`
*>
module crig_tests::joint_layers;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

// root
//  |- a - b - c
//  `- d
Vec3[5] rig_joints @local = {
	{ 0, 1, 0 }, { 0, 0.8f, 0 }, { 0, 0.6f, 0 }, { 0, 0.4f, 0 }, { 0.3f, 0.9f, 0 },
};
int[5] rig_parents @local = { -1, 0, 1, 2, 0 };
String[5] rig_names @local = { "root", "a", "b", "c", "d" };

fn rig::Skeleton small_rig() @local => { .joints = rig_joints[..], .parents = rig_parents[..] };

const Vec3 X @local = { 1, 0, 0 };
const Vec3 Y @local = { 0, 1, 0 };
const Vec3 Z @local = { 0, 0, 1 };

fn AnimKeyDot dot_of(String joint, Vec3 axis, float angle, Vec3 bone = {}, Vec3 move = {},
	AnimInterpolation curve = INHERIT, AnimEase ease = {}) @local
{
	return {
		.joint_name = joint.copy(mem),
		.channels = move.length_sq() > 0.0f ? BOTH : ROTATION,
		.axis = axis,
		.angle = angle,
		.move = move,
		.bone = bone,
		.rotation_interpolation = curve,
		.rotation_ease = ease,
	};
}

fn AnimKeyframe frame_of(float time, AnimKeyDot[] dots) @local
{
	AnimKeyDot[] owned = alloc::new_array(mem, AnimKeyDot, (sz)dots.len);
	foreach (usz i, dot : dots) owned[i] = dot;
	return { .time = time, .dots = owned };
}

// Four joints keyed at three times with every kind of curve, an ease, a slide,
// and bones the rig's do not match, so the carry has work to do.
fn AnimTemplate busy_clip(bool loop, AnimBlend blend) @local
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 3);
	frames[0] = frame_of(0.0f, {
		dot_of("a", X, 0.2f, curve: AUTO),
		dot_of("b", Z, 0.3f, bone: X, move: { 0.01f, 0, 0 }),
		dot_of("c", Y, 0.1f, bone: X),
		dot_of("d", Z, 0.05f),
	});
	frames[1] = frame_of(0.4f, {
		dot_of("b", Z, -0.2f, bone: X, curve: HOLD),
		dot_of("c", Y, 0.4f, bone: X, ease: { 0.3f, 0.5f }),
	});
	frames[2] = frame_of(0.9f, {
		dot_of("a", X, -0.1f),
		dot_of("b", Z, 0.15f, bone: X, move: { -0.02f, 0.01f, 0 }),
		dot_of("c", Y, -0.3f, bone: X, curve: LINEAR),
		dot_of("d", Z, 0.2f),
	});
	AnimTemplate clip = { .name = "busy".copy(mem), .duration = 1.2f, .loop = loop, .blend = blend,
		.keyframes = frames, .owned = true };
	clip.compile_tracks(mem);
	return clip;
}

fn AnimLayer wave_over(String joint) @local
{
	AnimLayer layer = crig::anim_layer_defaults("sway".copy(mem));
	layer.kind = WAVE;
	layer.joint = joint.copy(mem);
	layer.amplitude = 0.3f;
	layer.cycles = 1.0f;
	layer.lag = 0.2f;
	return layer;
}

fn bool same_pose(rig::Pose* a, rig::Pose* b) @local
{
	foreach (usz j, turn : a.rotations)
	{
		if (turn.v != b.rotations[j].v || a.offsets[j] != b.offsets[j]) return false;
	}
	return true;
}

fn bool keys_joint(AnimTemplate* clip, String joint) @local
{
	foreach (&frame : clip.keyframes) foreach (dot : frame.dots) if (dot.joint_name == joint) return true;
	return false;
}

<*
 Moving joints into a layer leaves the pose bit-for-bit what it was, at every
 instant, looping or not, with a layer already lying over them.

 Re-introduce: blend a full-weight override with `slerp_short` instead of taking
 its keys outright, or drop the carry from the layer's recorded bone in
 `AnimTemplate.pose`, and the poses part.
*>
fn void moving_joints_to_an_override_layer_keeps_the_pose() @test
{
	rig::Skeleton skeleton = small_rig();
	String[2] joints = { "b", "c" };
	String[1] mask = { "b" };
	foreach (variant : (int[]) { 0, 1, 2 })
	{
		AnimTemplate clip = busy_clip(variant != 1, variant == 1 ? LINEAR : SMOOTH);
		defer clip.free(mem);
		if (variant == 2)
		{
			clip.layers = alloc::new_array(mem, AnimLayer, 1);
			clip.layers[0] = wave_over("a");
		}
		AnimTemplate moved = crig::clip_with_joints_layered(mem, clip, joints[..], mask[..], "tail motion")!!;
		defer moved.free(mem);
		moved.compile_tracks(mem);

		test::@check(!keys_joint(&moved, "b") && !keys_joint(&moved, "c"), "the base still keys the moved joints");
		test::@check(keys_joint(&moved, "a") && keys_joint(&moved, "d"), "the other joints lost their keys");
		test::eq(moved.layers.len, clip.layers.len + 1);
		AnimLayer* layer = &moved.layers[0];
		test::@check(layer.kind == KEYED && layer.mode == OVERRIDE && layer.weight == 1.0f, "the new layer is not a full override");
		test::@check(layer.mask.len == 1 && layer.mask[0] == "b", "the layer is not confined to the moved joints");
		test::eq(layer.keyframes.len, (sz)3);
		if (variant == 2) test::@check(moved.layers[1].kind == WAVE, "the layer already there is no longer on top");

		for (float t = 0.0f; t <= 2.5f; t += 0.05f)
		{
			rig::Pose before = clip.pose(mem, &skeleton, rig_names[..], t, false);
			defer before.free(mem);
			rig::Pose after = moved.pose(mem, &skeleton, rig_names[..], t, false);
			defer after.free(mem);
			test::@check(same_pose(&before, &after), "variant %d: the pose changed at %.2f s", variant, t);
		}
	}
}

<*
 The keys of the chosen joints go, keyframes left empty go with them, and a clip
 that would be left with nothing is refused rather than emptied.

 Re-introduce: keep empty keyframes, or let the last joint go, and the counts or
 the refusal fail.
*>
fn void stripping_joints_drops_empty_keyframes_and_refuses_an_empty_base() @test
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 3);
	frames[0] = frame_of(0.0f, { dot_of("a", X, 0.1f), dot_of("b", X, 0.2f) });
	frames[1] = frame_of(0.5f, { dot_of("b", X, 0.4f, curve: HOLD) });
	frames[2] = frame_of(1.0f, { dot_of("a", X, 0.3f), dot_of("b", X, 0.1f) });
	AnimTemplate clip = { .name = "pair".copy(mem), .duration = 1.0f, .blend = SMOOTH, .keyframes = frames, .owned = true };
	defer clip.free(mem);

	String[1] only_b = { "b" };
	AnimKeyframe[] moved;
	AnimTemplate stripped = crig::clip_without_joints(mem, clip, only_b[..], &moved)!!;
	defer
	{
		stripped.free(mem);
		foreach (&frame : moved) frame.free(mem);
		alloc::free(mem, moved);
	}
	test::eq(stripped.keyframes.len, (sz)2);
	test::@check(!keys_joint(&stripped, "b"), "b is still keyed");
	test::@check(stripped.keyframes[1].time == 1.0f, "the wrong keyframe was dropped");
	test::eq(moved.len, (sz)3);
	test::@check(moved[1].time == 0.5f && moved[1].dots[0].rotation_interpolation == HOLD, "the moved key lost its time or curve");
	// INHERIT is stated outright, so the keys read the same under any clip's blend.
	test::@check(moved[0].dots[0].rotation_interpolation == AUTO, "an inherited curve was not resolved");

	String[1] stranger = { "d" };
	test::@check(@catch(crig::clip_without_joints(mem, clip, stranger[..])) == crig::STRIP_NOTHING_KEYED,
		"a joint the clip never keys was not refused");
	String[2] both = { "a", "b" };
	test::@check(@catch(crig::clip_without_joints(mem, clip, both[..])) == crig::STRIP_NOTHING_LEFT,
		"emptying the clip was not refused");
}

<*
 A joint only a layer turns, keyed with no bone or with the rig's own, plays as
 written — the carry from a layer's bone changes nothing for layers made before
 it existed.

 Re-introduce: carry from a fixed direction instead of the recorded one, and the
 two poses part.
*>
fn void a_layer_bone_matching_the_rig_plays_as_written() @test
{
	rig::Skeleton skeleton = small_rig();
	Vec3[] bones = skeleton.bone_directions(mem);
	defer alloc::free(mem, bones);
	rig::Pose[2] poses;
	foreach (usz i, bone : (Vec3[]) { {}, bones[2] })
	{
		AnimKeyframe[] base = alloc::new_array(mem, AnimKeyframe, 1);
		base[0] = frame_of(0.0f, { dot_of("d", Z, 0.1f) });
		AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
		keys[0] = frame_of(0.0f, { dot_of("b", Z, 0.3f, bone: bone) });
		keys[1] = frame_of(1.0f, { dot_of("b", Z, -0.3f, bone: bone) });
		AnimLayer layer = crig::anim_layer_defaults("lift".copy(mem));
		layer.keyframes = keys;
		AnimTemplate clip = { .name = "lift".copy(mem), .duration = 1.0f, .keyframes = base, .owned = true };
		clip.layers = alloc::new_array(mem, AnimLayer, 1);
		clip.layers[0] = layer;
		poses[i] = clip.pose(mem, &skeleton, rig_names[..], 0.3f, false);
		clip.free(mem);
	}
	defer { poses[0].free(mem); poses[1].free(mem); }
	test::@check(same_pose(&poses[0], &poses[1]), "a layer keyed against the rig's own bone was carried");
}

fn AnimTemplate layered_take(float duration, float step) @local
{
	usz count = (usz)(duration / step) + 1;
	AnimKeyframe[] base = alloc::new_array(mem, AnimKeyframe, (sz)count);
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		float t = (float)i * step;
		base[i] = frame_of(t, { dot_of("a", X, 0.4f * math::sin(2.0f * (float)math::PI * t / 1.1f)) });
		keys[i] = frame_of(t, { dot_of("b", Z, 0.3f * math::sin(2.0f * (float)math::PI * t / 1.1f + 0.5f)) });
	}
	AnimLayer layer = crig::anim_layer_defaults("tail".copy(mem));
	layer.mode = OVERRIDE;
	layer.keyframes = keys;
	AnimTemplate take = { .name = "take".copy(mem), .duration = (float)(count - 1) * step, .keyframes = base, .owned = true };
	take.layers = alloc::new_array(mem, AnimLayer, 1);
	take.layers[0] = layer;
	take.compile_tracks(mem);
	return take;
}

fn bool keys_in_order(AnimKeyframe[] keys, float duration) @local
{
	float previous = -1.0f;
	foreach (frame : keys)
	{
		if (frame.time <= previous || frame.time > duration + 1.0e-4f) return false;
		previous = frame.time;
	}
	return true;
}

<*
 Trimming or cutting a clip trims its keyed layers with it: the layer is
 restated at the new edges, and nothing piles up at zero — a sidecar refuses two
 keys at one time, so a pile-up was a project that would not open.

 Re-introduce: shift layer keys with `max(0, t - start)` as `AnimLayer.copy` does,
 and the order check or the pose check fails.
*>
fn void trimming_a_clip_trims_its_keyed_layers() @test
{
	rig::Skeleton skeleton = small_rig();
	AnimTemplate take = layered_take(3.0f, 0.1f);
	defer take.free(mem);

	AnimTemplate part = crig::clip_cropped(mem, take, 1.25f, 2.35f);
	defer part.free(mem);
	part.compile_tracks(mem);
	test::@check(keys_in_order(part.layers[0].keyframes, part.duration), "the cropped layer's keys are out of order");
	foreach (t : (float[]) { 0.0f, 0.3f, 0.77f, 1.1f })
	{
		rig::Pose was = take.pose(mem, &skeleton, rig_names[..], 1.25f + t, false);
		defer was.free(mem);
		rig::Pose now = part.pose(mem, &skeleton, rig_names[..], t, false);
		defer now.free(mem);
		test::@check(1.0f - math::abs(was.rotations[2].v.dot(now.rotations[2].v)) < 1.0e-5f,
			"the layer's joint moved differently at %.2f s into the crop", t);
	}

	AnimTemplate shorter = crig::clip_range_cut(mem, take, 0.5f, 1.4f);
	defer shorter.free(mem);
	test::@check(keys_in_order(shorter.layers[0].keyframes, shorter.duration), "the cut layer's keys are out of order");
	test::@check(shorter.layers[0].keyframes[^1].time <= shorter.duration + 1.0e-4f, "the layer runs past the cut clip");
}

<*
 A cycle cut from a take takes its keyed layers along, cut at the same seam.

 Re-introduce: copy the layers into the cycle unchanged and the layer plays the
 take's opening instead of the cycle's stretch.
*>
fn void a_cycle_cut_from_a_take_cuts_its_keyed_layers() @test
{
	rig::Skeleton skeleton = small_rig();
	AnimTemplate take = layered_take(4.0f, 1.0f / 60.0f);
	defer take.free(mem);
	crig::CycleCut cut;
	AnimTemplate cycle = crig::clip_cycle(mem, take, 0.9f, 1.3f, 1.0f, 2.5f, 0.0f, "", "cycle", &cut)!!;
	defer cycle.free(mem);
	cycle.compile_tracks(mem);
	test::@check(keys_in_order(cycle.layers[0].keyframes, cycle.duration), "the cycle's layer keys are out of order");
	foreach (t : (float[]) { 0.1f, 0.4f, 0.7f })
	{
		rig::Pose was = take.pose(mem, &skeleton, rig_names[..], cut.start + t, false);
		defer was.free(mem);
		rig::Pose now = cycle.pose(mem, &skeleton, rig_names[..], t, false);
		defer now.free(mem);
		test::@check(1.0f - math::abs(was.rotations[2].v.dot(now.rotations[2].v)) < 1.0e-4f,
			"the layer's joint in the cycle does not follow the take at %.2f s", t);
	}
}

// A two-second clip whose only base key is on d, and a shared layer of b whose
// own second turns it 0 → 1 rad about Z, laid on the clip by `fit`.
fn AnimTemplate fitted_clip(AnimLayerFit fit, bool loop = false) @local
{
	AnimKeyframe[] base = alloc::new_array(mem, AnimKeyframe, 1);
	base[0] = frame_of(0.0f, { dot_of("d", Z, 0.1f) });
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
	keys[0] = frame_of(0.0f, { dot_of("b", Z, 0.0f, curve: LINEAR) });
	keys[1] = frame_of(1.0f, { dot_of("b", Z, 1.0f, curve: LINEAR) });
	AnimLayer layer = crig::anim_layer_defaults("swish".copy(mem));
	layer.mode = OVERRIDE;
	layer.keyframes = keys;
	layer.link = "link-7".copy(mem);
	layer.length = 1.0f;
	layer.fit = fit;
	AnimTemplate clip = { .name = "fitted".copy(mem), .duration = 2.0f, .loop = loop, .keyframes = base, .owned = true };
	clip.layers = alloc::new_array(mem, AnimLayer, 1);
	clip.layers[0] = layer;
	clip.compile_tracks(mem);
	return clip;
}

fn float b_turn(AnimTemplate* clip, float time) @local
{
	rig::Skeleton skeleton = small_rig();
	rig::Pose pose = clip.pose(mem, &skeleton, rig_names[..], time, false);
	defer pose.free(mem);
	Quaternionf q = pose.rotations[2];
	if (q.v.w < 0.0f) q = -q;
	return 2.0f * math::atan2(q.v.z, q.v.w);
}

<*
 A shared layer's own second laid on a two-second clip: stretched it plays at
 half speed, kept it plays its second and holds, repeated it plays twice.

 Re-introduce: sample a layer on its own clock in the clip's seconds, and every
 fit reads the same.
*>
fn void an_own_clock_layer_fits_by_stretch_keep_or_repeat() @test
{
	AnimTemplate stretched = fitted_clip(STRETCH);
	defer stretched.free(mem);
	AnimTemplate kept = fitted_clip(KEEP);
	defer kept.free(mem);
	AnimTemplate repeated = fitted_clip(REPEAT);
	defer repeated.free(mem);
	test::@check(math::abs(b_turn(&stretched, 1.0f) - 0.5f) < 1.0e-4f, "a stretch is not half way at 1 s");
	test::@check(math::abs(b_turn(&stretched, 1.5f) - 0.75f) < 1.0e-4f, "a stretch is not three quarters at 1.5 s");
	test::@check(math::abs(b_turn(&kept, 0.5f) - 0.5f) < 1.0e-4f, "a kept layer is not on its own seconds");
	test::@check(math::abs(b_turn(&kept, 1.5f) - 1.0f) < 1.0e-4f, "a kept layer does not hold its last pose");
	test::@check(math::abs(b_turn(&repeated, 1.25f) - 0.25f) < 1.0e-4f, "a repeat does not start over after its second");
}

<*
 What a fit lays on the clip is what a flattened file and an unlinked layer
 hold: the bake samples the fitted keys, and Unlink restates them in the clip's
 seconds, so neither changes the motion.

 Re-introduce: take a repeated layer's key times as they are when flattening, or
 unlink without laying the keys out, and the poses part.
*>
fn void flattening_or_unlinking_a_fitted_layer_keeps_the_motion() @test
{
	rig::Skeleton skeleton = small_rig();
	foreach (fit : (AnimLayerFit[]) { STRETCH, KEEP, REPEAT })
	{
		AnimTemplate clip = fitted_clip(fit, loop: true);
		defer clip.free(mem);
		AnimTemplate flat = crig::clip_flattened(mem, clip, &skeleton, rig_names[..]);
		defer flat.free(mem);
		flat.compile_tracks(mem);
		AnimTemplate plain = crig::clip_copy(mem, clip);
		defer plain.free(mem);
		AnimLayer unlinked = plain.layers[0].plain(mem, &plain);
		plain.layers[0].free(mem);
		plain.layers[0] = unlinked;
		test::@check(plain.layers[0].link.len == 0 && !plain.layers[0].own_clock(), "Unlink left the layer on its own clock");
		// Between the instants a repeat starts over, where either side is the value.
		for (float t = 0.0625f; t < 2.0f; t += 0.125f)
		{
			float want = b_turn(&clip, t);
			test::@check(math::abs(b_turn(&flat, t) - want) < 2.0e-3f, "%s: the flattened clip parts at %.3f s", fit.wire(), t);
			test::@check(math::abs(b_turn(&plain, t) - want) < 1.0e-3f, "%s: the unlinked layer parts at %.3f s", fit.wire(), t);
		}
	}
}

<*
 A shared layer's id, length and fit survive the project sidecar.

 Re-introduce: leave any of the three out of `append_layer_fields`, and it comes
 back unshared.
*>
fn void a_shared_layer_round_trips_through_the_sidecar() @test
{
	RigDocument doc = {};
	defer doc.free();
	AnimTemplate clip = fitted_clip(REPEAT);
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };
	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	AnimTemplate[] back = crig::parse_session_clips(mem, text)!!;
	defer crig::free_animations(mem, back);
	test::@check(back.len == 1 && back[0].layers.len == 1, "the clip or its layer did not come back");
	AnimLayer* layer = &back[0].layers[0];
	test::@check(layer.link == "link-7" && layer.length == 1.0f && layer.fit == REPEAT, "the layer came back unshared");
}

<*
 Mirroring a clip unlinks its shared layers: the mirrored motion is no longer
 the one the other clips share, and a mirror in place must not flip theirs.

 Re-introduce: mirror shared layers as they are, and the link survives.
*>
fn void mirroring_unlinks_a_shared_layer() @test
{
	AnimTemplate clip = fitted_clip(STRETCH);
	defer clip.free(mem);
	AnimTemplate flipped = crig::mirror_template(mem, clip, "flipped", 0.5f);
	defer flipped.free(mem);
	test::@check(flipped.layers.len == 1 && flipped.layers[0].link.len == 0 && flipped.layers[0].length == 0.0f,
		"the mirrored clip still shares the layer");
}

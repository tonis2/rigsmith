<*
 `clip_with_offset`: a turn added onto the keys picked, fading over the keys just
 outside them. Geometry-free: a clip of named entries and nothing else.
*>
module crig_tests::key_offset;

import crig;
import std::core::test;
import std::math;
import std::math::quaternion;

const float EPSILON = 1.0e-4f;

// Each key turns "hand" by its own time about Y and slides it by its time on X.
fn AnimTemplate offset_clip(float[] times, bool loop = false, bool with_arm = false)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, (sz)times.len);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, with_arm ? 2 : 1);
		dots[0] = {
			.joint_name = "hand".copy(mem),
			.axis = { 0, 1, 0 },
			.angle = times[i],
			.move = { times[i], 0, 0 },
		};
		if (with_arm)
		{
			dots[1] = {
				.joint_name = "arm".copy(mem),
				.axis = { 1, 0, 0 },
				.angle = 0.3f,
				.move = { 0, times[i], 0 },
			};
		}
		*key = { .time = times[i], .dots = dots };
	}
	return { .name = "offset".copy(mem), .duration = 1.0f, .loop = loop, .keyframes = keys, .owned = true };
}

fn AnimKeyDot hand_at(AnimTemplate* clip, float time, String joint = "hand")
{
	foreach (frame : clip.keyframes)
	{
		if (math::abs(frame.time - time) > EPSILON) continue;
		foreach (dot : frame.dots) if (dot.joint_name == joint) return dot;
	}
	return { .angle = -100.0f };
}

// How far apart two turns are, 0 when they are the same.
fn float apart(AnimKeyDot dot, float angle)
{
	Quaternionf got = quaternion::from_axis_angle{float}(dot.axis.normalize(), dot.angle);
	Quaternionf want = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, angle);
	return 1.0f - math::abs(got.v.dot(want.v));
}

fn KeyOffset[1] hand_turn(float angle)
{
	return { { .joint = "hand", .rotates = true, .turn = quaternion::from_axis_angle{float}((Vec3){ 0, 1, 0 }, angle) } };
}

fn void selected_keys_take_the_whole_turn_and_near_ones_a_share() @test
{
	AnimTemplate clip = offset_clip(((float[8]){ 0.0f, 0.2f, 0.25f, 0.3f, 0.35f, 0.4f, 0.6f, 1.0f })[..]);
	defer clip.free(mem);
	// The middle key steps and eases: an offset changes values, not curves.
	clip.keyframes[3].dots[0].rotation_interpolation = HOLD;
	clip.keyframes[3].dots[0].rotation_ease = { .start = 0.3f, .end = 0.6f };
	KeyOffset[1] offsets = hand_turn(0.5f);
	usz faded;
	AnimTemplate turned = crig::clip_with_offset(mem, clip, offsets[..], ((float[3]){ 0.25f, 0.3f, 0.35f })[..],
		crig::KEY_OFFSET_FADE, &faded);
	defer turned.free(mem);

	test::eq(turned.keyframes.len, clip.keyframes.len);
	foreach (time : (float[3]){ 0.25f, 0.3f, 0.35f })
	{
		test::@check(apart(hand_at(&turned, time), time + 0.5f) < 1.0e-6f, "the selected key at %f did not take the turn", time);
	}
	// 0.05 s from the selection, halfway through the fade: half the turn.
	test::@check(apart(hand_at(&turned, 0.2f), 0.2f + 0.25f) < 1.0e-6f, "the key just before the selection took no half share");
	test::@check(apart(hand_at(&turned, 0.4f), 0.4f + 0.25f) < 1.0e-6f, "the key just after the selection took no half share");
	test::eq(faded, (usz)2);
	foreach (time : (float[3]){ 0.0f, 0.6f, 1.0f })
	{
		AnimKeyDot before = hand_at(&clip, time);
		AnimKeyDot after = hand_at(&turned, time);
		test::@check(after.angle == before.angle && after.axis == before.axis, "the key at %f, past the fade, moved", time);
	}
	AnimKeyDot stepped = hand_at(&turned, 0.3f);
	test::@check(stepped.rotation_interpolation == HOLD && stepped.rotation_ease.same({ .start = 0.3f, .end = 0.6f }),
		"the offset reset a key's interpolation or ease");
	test::@check(hand_at(&turned, 0.3f).move == (Vec3){ 0.3f, 0, 0 }, "a turn changed the slide");
}

fn void a_selected_time_with_no_key_gains_one() @test
{
	AnimTemplate clip = offset_clip(((float[2]){ 0.0f, 1.0f })[..]);
	defer clip.free(mem);
	KeyOffset[1] offsets = hand_turn(0.5f);
	AnimTemplate turned = crig::clip_with_offset(mem, clip, offsets[..], ((float[2]){ 0.5f, 0.7f })[..]);
	defer turned.free(mem);

	test::eq(turned.keyframes.len, (sz)4);
	// Linear from 0 to 1 over the clip, so the clip played 0.5 and 0.7 there.
	test::@check(apart(hand_at(&turned, 0.5f), 1.0f) < 1.0e-5f, "the new key at 0.5 is not the played value turned");
	test::@check(apart(hand_at(&turned, 0.7f), 1.2f) < 1.0e-5f, "the new key at 0.7 is not the played value turned");
	test::@check(hand_at(&turned, 0.5f).channels == ROTATION, "a turn keyed the slide as well");
	test::@check(hand_at(&turned, 0.0f).angle == 0.0f && hand_at(&turned, 1.0f).angle == 1.0f, "the far keys moved");
}

fn void the_fade_wraps_round_a_loop() @test
{
	float[3] times = { 0.0f, 0.5f, 0.95f };
	KeyOffset[1] offsets = hand_turn(0.5f);

	AnimTemplate looped = offset_clip(times[..], true);
	defer looped.free(mem);
	AnimTemplate turned = crig::clip_with_offset(mem, looped, offsets[..], ((float[2]){ 0.0f, 0.5f })[..]);
	defer turned.free(mem);
	test::@check(apart(hand_at(&turned, 0.95f), 0.95f + 0.25f) < 1.0e-6f, "the last key of a loop took no share of the first key's turn");

	AnimTemplate once = offset_clip(times[..], false);
	defer once.free(mem);
	AnimTemplate held = crig::clip_with_offset(mem, once, offsets[..], ((float[2]){ 0.0f, 0.5f })[..]);
	defer held.free(mem);
	test::@check(hand_at(&held, 0.95f).angle == 0.95f, "a clip that does not loop faded across its end");
}

fn void a_turn_leaves_the_slide_and_other_joints_alone() @test
{
	AnimTemplate clip = offset_clip(((float[3]){ 0.0f, 0.5f, 1.0f })[..], false, true);
	defer clip.free(mem);
	KeyOffset[1] offsets = hand_turn(0.5f);
	AnimTemplate turned = crig::clip_with_offset(mem, clip, offsets[..], ((float[3]){ 0.0f, 0.5f, 1.0f })[..]);
	defer turned.free(mem);
	foreach (time : (float[3]){ 0.0f, 0.5f, 1.0f })
	{
		AnimKeyDot hand = hand_at(&turned, time);
		test::@check(hand.move == (Vec3){ time, 0, 0 } && hand.channels == BOTH, "the hand's slide changed at %f", time);
		AnimKeyDot arm = hand_at(&turned, time, "arm");
		AnimKeyDot was = hand_at(&clip, time, "arm");
		test::@check(arm.axis == was.axis && arm.angle == was.angle && arm.move == was.move,
			"the arm changed at %f", time);
	}
}

fn void a_slide_adds_to_the_keys_it_lands_on() @test
{
	AnimTemplate clip = offset_clip(((float[3]){ 0.0f, 0.5f, 1.0f })[..]);
	defer clip.free(mem);
	KeyOffset[1] offsets = { { .joint = "hand", .moves = true, .move = { 0, 0.2f, 0 } } };
	AnimTemplate slid = crig::clip_with_offset(mem, clip, offsets[..], ((float[2]){ 0.5f, 1.0f })[..]);
	defer slid.free(mem);
	test::@check((hand_at(&slid, 0.5f).move - (Vec3){ 0.5f, 0.2f, 0 }).length() < 1.0e-6f, "the slide did not add on");
	test::@check(hand_at(&slid, 0.5f).angle == 0.5f, "a slide turned the joint");
	test::@check(hand_at(&slid, 0.0f).move == (Vec3){ 0, 0, 0 }, "an unselected key slid");
}

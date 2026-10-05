module crig_tests::sparse_tracks;

import crig;
import std::core::test;
import std::math;
import std::math::quaternion;

fn crig::AnimKeyDot keyed(String joint, float angle, float move, crig::AnimChannels channels)
{
	return {
		.joint_name = joint,
		.channels = channels,
		.axis = { 0, 1, 0 },
		.angle = angle,
		.move = { move, 0, 0 },
	};
}

fn bool near(float a, float b) => math::abs(a - b) < 1.0e-4f;

fn void outgoing_interpolation_is_independent_per_sparse_channel() @test
{
	crig::AnimKeyDot[1] first = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.BOTH) };
	first[0].rotation_interpolation = crig::AnimInterpolation.HOLD;
	first[0].translation_interpolation = crig::AnimInterpolation.LINEAR;
	crig::AnimKeyDot[1] last = { keyed("hip", 1.0f, 1.0f, crig::AnimChannels.BOTH) };
	crig::AnimKeyframe[2] keys = {
		{ .time = 0.0f, .dots = first[..] },
		{ .time = 1.0f, .dots = last[..] },
	};
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..] };
	crig::AnimKeyDot middle = clip.entry_at("hip", 0.5f);
	test::@check(near(middle.angle, 0.0f), "held rotation moved before its next key: %s", middle.angle);
	test::@check(near(middle.move.x, 0.5f), "linear position was held with its sibling rotation: %s", middle.move.x);
	test::@check(near(clip.entry_at("hip", 1.0f).angle, 1.0f),
		"hold did not change exactly on the next key");
}

fn void explicit_linear_and_auto_override_the_legacy_clip_blend() @test
{
	crig::AnimKeyDot[1] first = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] last = { keyed("hip", 1.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[2] keys = {
		{ .time = 0.0f, .dots = first[..] },
		{ .time = 1.0f, .dots = last[..] },
	};
	crig::AnimTemplate smooth = { .duration = 1.0f, .keyframes = keys[..], .blend = crig::AnimBlend.SMOOTH };
	first[0].rotation_interpolation = crig::AnimInterpolation.LINEAR;
	test::@check(near(smooth.entry_at("hip", 0.25f).angle, 0.25f),
		"explicit Linear still used the clip's smooth curve");

	crig::AnimTemplate linear = { .duration = 1.0f, .keyframes = keys[..], .blend = crig::AnimBlend.LINEAR };
	first[0].rotation_interpolation = crig::AnimInterpolation.AUTO;
	float curved = linear.entry_at("hip", 0.25f).angle;
	first[0].rotation_interpolation = crig::AnimInterpolation.INHERIT;
	float inherited_smooth = smooth.entry_at("hip", 0.25f).angle;
	test::@check(near(curved, inherited_smooth),
		"explicit Auto did not match the legacy smooth curve: %s vs %s", curved, inherited_smooth);
	test::@check(math::abs(curved - 0.25f) > 0.001f,
		"explicit Auto still used the clip's linear curve: %s", curved);
}

fn void channels_sample_their_own_surrounding_keys() @test
{
	crig::AnimKeyDot[1] r0 = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] move = { keyed("hip", 0.0f, 0.25f, crig::AnimChannels.TRANSLATION) };
	crig::AnimKeyDot[1] r1 = { keyed("hip", 1.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[3] keys = {
		{ .time = 0.0f, .dots = r0[..] },
		{ .time = 0.25f, .dots = move[..] },
		{ .time = 1.0f, .dots = r1[..] },
	};
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..] };

	crig::AnimKeyDot halfway = clip.entry_at("hip", 0.5f);
	test::@check(near(halfway.angle, 0.5f), "rotation sampled adjacent whole frames: %s", halfway.angle);
	test::@check(near(halfway.move.x, 0.25f), "single translation key did not hold: %s", halfway.move.x);
	test::@check(halfway.channels == crig::AnimChannels.BOTH, "sample did not report both driven channels");
}

fn void sparse_nonloop_edges_hold_and_missing_channels_rest() @test
{
	crig::AnimKeyDot[1] a = { keyed("hip", 0.4f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] b = { keyed("hip", 0.8f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[2] keys = {
		{ .time = 0.25f, .dots = a[..] },
		{ .time = 0.75f, .dots = b[..] },
	};
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..] };
	test::@check(near(clip.entry_at("hip", -2.0f).angle, 0.4f), "before-first did not hold");
	test::@check(near(clip.entry_at("hip", 2.0f).angle, 0.8f), "after-last did not hold");
	crig::AnimKeyDot absent = clip.entry_at("knee", 0.5f);
	test::@check(near(absent.angle, 0.0f) && absent.move.length_sq() == 0.0f,
		"a track with no keys did not return rest");
}

fn void linear_sparse_tracks_wrap_and_compiled_indices_match() @test
{
	crig::AnimKeyDot[1] a = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] b = { keyed("hip", 1.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, 2);
	keys[0] = { .time = 0.25f, .dots = a[..] };
	keys[1] = { .time = 0.75f, .dots = b[..] };
	crig::AnimTemplate clip = {
		.name = "sparse".copy(mem),
		.duration = 1.0f,
		.keyframes = keys,
		.loop = true,
		.owned = true,
	};
	defer
	{
		// Static dot arrays are borrowed, so release only cache/key array/name.
		clip.keyframes[0].dots = {};
		clip.keyframes[1].dots = {};
		clip.free(mem);
	}

	float scanned = clip.entry_at("hip", 0.0f).angle;
	clip.compile_tracks(mem);
	float compiled = clip.entry_at("hip", 0.0f).angle;
	test::@check(near(scanned, 0.5f), "linear loop did not interpolate across its seam: %s", scanned);
	test::@check(near(compiled, scanned), "compiled track changed sampling: %s vs %s", compiled, scanned);
	test::@check(clip.tracks.len == 1 && clip.tracks[0].rotations.len == 2
		&& clip.tracks[0].translations.len == 0, "compiled channel indices have the wrong shape");
}

fn void a_distinct_duration_key_is_sampled_at_the_export_endpoint() @test
{
	crig::AnimKeyDot[1] a = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] b = { keyed("hip", 1.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[2] keys = {
		{ .time = 0.0f, .dots = a[..] },
		{ .time = 1.0f, .dots = b[..] },
	};
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..], .loop = true };
	test::@check(near(clip.entry_at("hip", 1.0f).angle, 1.0f),
		"the distinct duration key was replaced by the wrapped opening pose");
}

fn void smooth_sparse_rotation_is_continuous_across_the_loop() @test
{
	crig::AnimKeyDot[1] a = { keyed("hip", -0.6f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] b = { keyed("hip", 0.9f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] c = { keyed("hip", 0.2f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[3] keys = {
		{ .time = 0.15f, .dots = a[..] },
		{ .time = 0.50f, .dots = b[..] },
		{ .time = 0.80f, .dots = c[..] },
	};
	crig::AnimTemplate clip = {
		.duration = 1.0f,
		.keyframes = keys[..],
		.loop = true,
		.blend = crig::AnimBlend.SMOOTH,
	};
	crig::AnimKeyDot left = clip.entry_at("hip", 0.9999f);
	crig::AnimKeyDot right = clip.entry_at("hip", 0.0001f);
	Quaternionf ql = quaternion::from_axis_angle{float}(left.axis, left.angle);
	Quaternionf qr = quaternion::from_axis_angle{float}(right.axis, right.angle);
	test::@check(1.0f - math::abs(ql.v.dot(qr.v)) < 0.001f,
		"smooth quaternion jumped across the sparse loop seam");
}

fn void a_same_valued_duration_key_only_closes_a_zero_time_track() @test
{
	crig::AnimKeyDot[1] a = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] b = { keyed("hip", 1.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyDot[1] close = { keyed("hip", 0.0f, 0.0f, crig::AnimChannels.ROTATION) };
	crig::AnimKeyframe[3] keys = {
		{ .time = 0.2f, .dots = a[..] },
		{ .time = 0.6f, .dots = b[..] },
		{ .time = 1.0f, .dots = close[..] },
	};
	crig::AnimTemplate clip = { .duration = 1.0f, .keyframes = keys[..], .loop = true };
	test::@check(near(clip.entry_at("hip", 0.9f).angle, 0.25f),
		"a duration key was mistaken for a closing duplicate without a zero-time opening key");
}

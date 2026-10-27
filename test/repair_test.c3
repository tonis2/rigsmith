<*
 Repairing a generated take: smoothing its jitter out (`clip_smoothed`) and
 cutting a seamless cycle out of it (`clip_cycle`), on clips keyed every frame as
 a generated clip lands, and the MCP tools over them.

     `c3c test --test-noleak --test-filter crig_tests::repair`
*>
module crig_tests::repair;

import crig;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

const float RATE = 120.0f;

// A key every 1/120 s for `seconds`, each joint turning about X by `angle(joint, t)`.
fn crig::AnimTemplate dense_take(String name, float seconds, String[] joints, AngleFn angle, bool slides = false)
{
	usz keys = (usz)(seconds * RATE) + 1;
	crig::AnimKeyframe[] frames = alloc::new_array(mem, crig::AnimKeyframe, (sz)keys);
	for (usz k = 0; k < keys; k++)
	{
		float t = (float)k / RATE;
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, (sz)joints.len);
		foreach (usz j, joint : joints)
		{
			dots[j] = { .joint_name = joint.copy(mem), .axis = { 1, 0, 0 }, .angle = angle(j, t),
				.move = slides && j == 0 ? (Vec3){ 0.01f * t, 0.0f, 0.0f } : (Vec3){} };
		}
		frames[k] = { .time = t, .dots = dots };
	}
	crig::AnimTemplate clip = { .name = name.copy(mem), .duration = (float)(keys - 1) / RATE, .keyframes = frames, .owned = true };
	clip.compile_tracks(mem);
	return clip;
}

alias AngleFn = fn float(usz joint, float t);

// The angle a clip turns a joint by at `t`, read off its curve.
fn float angle_at(crig::AnimTemplate* clip, String joint, float t)
{
	Quaternionf q = clip.rotation_at(joint, t);
	if (q.v.w < 0.0f) q = -q;
	float s = (float)math::sqrt(q.v.x * q.v.x + q.v.y * q.v.y + q.v.z * q.v.z);
	return (q.v.x < 0.0f ? -1.0f : 1.0f) * 2.0f * (float)math::atan2(s, q.v.w);
}

fn float jittery(usz joint, float t)
{
	int k = (int)math::round(t * RATE);
	float jitter = k % 2 == 0 ? 0.04f : -0.04f;
	return 0.5f * (float)math::sin(t * (float)math::PI * 2.0f) + jitter;
}

<*
 A sine with a frame-to-frame tremble on top: smoothing takes the tremble out and
 keeps the sine, keys where they were. A foot held by its ground window keeps its
 tremble while held, so a plant is not dragged.
*>
fn void smoothing_takes_out_jitter_and_keeps_the_motion() @test
{
	io::printn("smooth_clip removes a frame-rate tremble and keeps the sine under it");
	String[2] joints = { "arm", "foot" };
	crig::AnimTemplate take = dense_take("tremble", 2.0f, joints[..], &jittery);
	defer take.free(mem);
	crig::AnimFoot[] feet = alloc::new_array(mem, crig::AnimFoot, 1);
	feet[0] = { .joint = "foot".copy(mem), .down = 0.0f, .up = 0.5f };
	take.ground = { .feet = feet };

	crig::AnimTemplate calm = crig::clip_smoothed(mem, take, {}, 0.1f, -1.0f, -1.0f, true);
	defer calm.free(mem);
	calm.compile_tracks(mem);
	test::@check(calm.keyframes.len == take.keyframes.len, "smoothing changed the keys");

	float worst_jitter = 0.0f;
	float worst_shape = 0.0f;
	for (usz k = 24; k + 24 < calm.keyframes.len; k++)
	{
		float t = calm.keyframes[k].time;
		float next = calm.keyframes[k + 1].time;
		worst_jitter = math::max(worst_jitter, math::abs(angle_at(&calm, "arm", t) - angle_at(&calm, "arm", next)));
		worst_shape = math::max(worst_shape, math::abs(angle_at(&calm, "arm", t) - 0.5f * (float)math::sin(t * (float)math::PI * 2.0f)));
	}
	test::@check(worst_jitter < 0.04f, "the tremble is still there: %.4f between keys", worst_jitter);
	test::@check(worst_shape < 0.03f, "the sine moved by %.4f", worst_shape);

	// Held by its ground window for the first half, the foot is left as it was.
	float held = math::abs(angle_at(&calm, "foot", 0.25f) - angle_at(&take, "foot", 0.25f));
	test::@check(held < 1e-4f, "a planted foot was smoothed (%.4f)", held);
	float freed = math::abs(angle_at(&calm, "foot", 1.5f) - angle_at(&take, "foot", 1.5f));
	test::@check(freed > 0.01f, "a swinging foot was not smoothed");
}

fn float striding(usz joint, float t)
{
	float period = 1.1f;
	float phase = t * (float)math::PI * 2.0f / period;
	int k = (int)math::round(t * RATE);
	float noise = 0.004f * (float)math::sin((float)k * 1.7f);
	return joint == 0 ? 0.6f * (float)math::sin(phase) + noise : 0.3f * (float)math::sin(2.0f * phase + 0.3f) + noise;
}

<*
 A four-second take of a 1.1-second stride, with a little noise: the cycle cut is
 one stride long, it loops back on itself without a jump in pose or in speed, and
 the root's drift is taken off.
*>
fn void a_cycle_is_cut_out_of_a_take() @test
{
	io::printn("make_loop finds a 1.1 s stride in a 4 s take and closes it");
	String[2] joints = { "hips", "leg" };
	crig::AnimTemplate take = dense_take("take", 4.0f, joints[..], &striding, slides: true);
	defer take.free(mem);

	crig::CycleCut cut;
	crig::AnimTemplate cycle = crig::clip_cycle(mem, take, 0.8f, 1.5f, 0.4f, 3.0f, 0.25f, "hips", "stride", &cut)!!;
	defer cycle.free(mem);
	cycle.compile_tracks(mem);

	test::@check(math::abs(cut.period - 1.1f) < 0.04f, "the cycle is %.3f s, not the stride's 1.1", cut.period);
	test::@check(cycle.loop && math::abs(cycle.duration - cut.period) < 1e-4f, "the cycle does not loop over its period");
	test::@check(cut.seam < 0.05f, "the seam's poses are %.4f rad apart", cut.seam);

	// Round the seam the angle runs on at the speed it had: the step either side
	// of the loop point is the step just inside it.
	float step = 1.0f / 60.0f;
	float p = cycle.duration;
	float before = angle_at(&cycle, "leg", p - step) - angle_at(&cycle, "leg", p - 2.0f * step);
	float across = angle_at(&cycle, "leg", step) - angle_at(&cycle, "leg", 0.0f);
	test::@check(math::abs(across - before) < 0.02f, "the speed jumps at the seam (%.4f against %.4f)", across, before);
	float jump = math::abs(angle_at(&cycle, "leg", 0.0f) - angle_at(&cycle, "leg", p - 1e-4f));
	test::@check(jump < 0.02f, "the pose jumps %.4f at the seam", jump);

	// The root's sideways drift is gone: it is centred over the cycle.
	float mean;
	for (usz k = 0; k < 60; k++) mean += cycle.translation_at("hips", p * (float)k / 60.0f).x;
	test::@check(math::abs(mean / 60.0f) < 1e-3f, "the hips drift %.4f to the side", mean / 60.0f);
}

// An idle that drifts: a slow sway on a lean that grows, so its end is far from its start.
fn float swaying(usz joint, float t)
{
	return 0.2f * t + 0.1f * (float)math::sin(t * 2.3f + (float)joint);
}

<*
 Make loop's Whole take: a four-second take that ends far from where it started
 loops over all of it but the crossfade. The middle is the take as it was, only
 moved up by the crossfade; the end blends into the start without a jump in pose
 or in speed; the root's drift is taken off.
*>
fn void a_whole_take_loops_keeping_all_but_the_crossfade() @test
{
	String[2] joints = { "hips", "arm" };
	crig::AnimTemplate take = dense_take("idle", 4.0f, joints[..], &swaying, slides: true);
	defer take.free(mem);

	crig::CycleCut cut;
	crig::AnimTemplate loop = crig::clip_whole_loop(mem, take, 0.4f, "hips", "idle", &cut)!!;
	defer loop.free(mem);
	loop.compile_tracks(mem);

	test::@check(loop.loop && math::abs(loop.duration - 3.6f) < 0.02f, "the loop is %.3f s, not the take less its crossfade", loop.duration);
	test::@check(math::abs(cut.start - 0.4f) < 0.02f && math::abs(cut.period - loop.duration) < 1e-4f,
		"the cut is from %.3f s for %.3f s", cut.start, cut.period);
	test::@check(cut.seam > 0.3f, "the seam's poses are %.4f rad apart before the blend; the take's end is far from its start", cut.seam);

	// Before the blend the loop is the take, a crossfade later.
	float moved = 0.0f;
	for (float t = 0.0f; t < 3.0f; t += 0.05f)
	{
		moved = math::max(moved, math::abs(angle_at(&loop, "arm", t) - angle_at(&take, "arm", t + cut.start)));
	}
	test::@check(moved < 0.01f, "the loop's middle is %.4f off the take", moved);

	float step = 1.0f / 60.0f;
	float p = loop.duration;
	float jump = math::abs(angle_at(&loop, "arm", 0.0f) - angle_at(&loop, "arm", p - 1e-4f));
	test::@check(jump < 0.02f, "the pose jumps %.4f at the seam", jump);
	float before = angle_at(&loop, "arm", p - step) - angle_at(&loop, "arm", p - 2.0f * step);
	float across = angle_at(&loop, "arm", step) - angle_at(&loop, "arm", 0.0f);
	test::@check(math::abs(across - before) < 0.01f, "the speed jumps at the seam (%.4f against %.4f)", across, before);

	float mean;
	for (usz k = 0; k < 60; k++) mean += loop.translation_at("hips", p * (float)k / 60.0f).x;
	test::@check(math::abs(mean / 60.0f) < 1e-3f, "the hips drift %.4f to the side", mean / 60.0f);
}

fn void a_take_too_short_for_the_cycle_is_refused() @test
{
	String[1] joints = { "leg" };
	crig::AnimTemplate take = dense_take("short", 0.5f, joints[..], &striding);
	defer take.free(mem);
	crig::CycleCut cut;
	crig::AnimTemplate? cycle = crig::clip_cycle(mem, take, 0.8f, 1.5f, 0.0f, 0.4f, 0.2f, "", "x", &cut);
	if (try cycle)
	{
		cycle.free(mem);
		test::@check(false, "a cycle longer than the take was cut");
	}
}

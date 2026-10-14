<*
 Which samples of a baked curve a written file keeps.

 A file's curve is played by a reader that slides between its keys, so a sample
 the straight line between its kept neighbours already reproduces is one the file
 can leave out. These pin down what goes and what has to stay: a still curve
 keeps one key, a straight run its ends, and a corner, a step or a wobble past
 the tolerance keeps the samples that make it.
*>
module crig_tests::curve_keys;

import crig;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::core::test;

const crig::CurveTolerance TOLERANCE = { .angle = 1.0e-5f, .move = 1.0e-5f };

fn Quaternionf about_x(float angle)
{
	return { .v = { math::sin(angle * 0.5f), 0.0f, 0.0f, math::cos(angle * 0.5f) } };
}

fn void check_keys(usz[] got, usz[] want, String what)
{
	bool same = got.len == want.len;
	for (usz i = 0; same && i < got.len; i++) same = got[i] == want[i];
	test::@check(same, "%s: kept %s, expected %s", what, got, want);
}

fn void a_still_curve_keeps_one_key_once_the_clip_moves() @test
{
	float[5] times = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	Quaternionf[5] turns;
	Vec3[5] slides;
	foreach (usz k, &turn : turns)
	{
		// Float noise far under the tolerance is still "still".
		*turn = about_x(0.3f + (k % 2 == 0 ? 0.0f : 2.0e-7f));
		slides[k] = { 0.1f, 0.2f, 0.3f };
	}

	usz[] held = crig::curve_keys(mem, times[..], turns[..], {}, TOLERANCE, may_hold: true);
	defer if (held.len > 0) alloc::free(mem, held);
	check_keys(held, (usz[]){ 0 }, "a still turn");
	usz[] slid = crig::curve_keys(mem, times[..], {}, slides[..], TOLERANCE, may_hold: true);
	defer if (slid.len > 0) alloc::free(mem, slid);
	check_keys(slid, (usz[]){ 0 }, "a still slide");

	// When nothing in the clip moves, the curve carries the clip's length instead.
	usz[] spanned = crig::curve_keys(mem, times[..], turns[..], {}, TOLERANCE, may_hold: false);
	defer if (spanned.len > 0) alloc::free(mem, spanned);
	check_keys(spanned, (usz[]){ 0, 4 }, "a still turn in a still clip");
}

fn void a_straight_run_keeps_its_ends() @test
{
	float[9] times;
	Quaternionf[9] turns;
	Vec3[9] slides;
	Quaternionf from = about_x(-0.6f);
	Quaternionf to = about_x(0.9f);
	foreach (usz k, &time : times)
	{
		// Uneven spacing: the line is in time, not in sample count.
		float f = (float)k / 8.0f;
		*time = f * f;
		turns[k] = from.slerp(to, *time);
		slides[k] = (Vec3){ 0.0f, 1.0f, 0.0f } + (Vec3){ 0.5f, -0.25f, 2.0f } * *time;
	}

	usz[] turned = crig::curve_keys(mem, times[..], turns[..], {}, TOLERANCE, may_hold: true);
	defer if (turned.len > 0) alloc::free(mem, turned);
	check_keys(turned, (usz[]){ 0, 8 }, "a slerped turn");
	usz[] slid = crig::curve_keys(mem, times[..], {}, slides[..], TOLERANCE, may_hold: true);
	defer if (slid.len > 0) alloc::free(mem, slid);
	check_keys(slid, (usz[]){ 0, 8 }, "a lerped slide");
}

fn void a_corner_and_a_step_keep_the_samples_that_make_them() @test
{
	// Out and back: the turnaround is a key the line from end to end misses.
	float[5] times = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	Vec3[5] corner = { { 0, 0, 0 }, { 0.5f, 0, 0 }, { 1, 0, 0 }, { 0.5f, 0, 0 }, { 0, 0, 0 } };
	usz[] cornered = crig::curve_keys(mem, times[..], {}, corner[..], TOLERANCE, may_hold: true);
	defer if (cornered.len > 0) alloc::free(mem, cornered);
	check_keys(cornered, (usz[]){ 0, 2, 4 }, "an out-and-back slide");

	// A held span baked as glTF writes one: the value up to the float before the
	// key, and the new value on it. Both sides stay; the flat stretches go.
	float edge = bitcast(bitcast(0.5f, uint) - 1, float);
	float[6] step_times = { 0.0f, 0.25f, edge, 0.5f, 0.75f, 1.0f };
	Vec3[6] step = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 } };
	usz[] stepped = crig::curve_keys(mem, step_times[..], {}, step[..], TOLERANCE, may_hold: true);
	defer if (stepped.len > 0) alloc::free(mem, stepped);
	check_keys(stepped, (usz[]){ 0, 2, 3, 5 }, "a held step");
}

fn void a_wobble_stays_only_past_the_tolerance() @test
{
	float[3] times = { 0.0f, 0.5f, 1.0f };
	Vec3[3] small = { { 0, 0, 0 }, { 0.5f, 0.5f * TOLERANCE.move, 0 }, { 1, 0, 0 } };
	usz[] dropped = crig::curve_keys(mem, times[..], {}, small[..], TOLERANCE, may_hold: true);
	defer if (dropped.len > 0) alloc::free(mem, dropped);
	check_keys(dropped, (usz[]){ 0, 2 }, "a wobble under the tolerance");

	Vec3[3] large = { { 0, 0, 0 }, { 0.5f, 3.0f * TOLERANCE.move, 0 }, { 1, 0, 0 } };
	usz[] kept = crig::curve_keys(mem, times[..], {}, large[..], TOLERANCE, may_hold: true);
	defer if (kept.len > 0) alloc::free(mem, kept);
	test::@check(kept.len == 0, "a wobble past the tolerance was dropped: kept %s", kept);

	// The same for a turn, a few times the tolerance off its slerp: well under
	// the twentieth of a degree a dot product's acos can resolve in float.
	Quaternionf[3] turns = { about_x(0.0f), about_x(0.2f + 4.0f * TOLERANCE.angle), about_x(0.4f) };
	usz[] turned = crig::curve_keys(mem, times[..], turns[..], {}, TOLERANCE, may_hold: true);
	defer if (turned.len > 0) alloc::free(mem, turned);
	test::@check(turned.len == 0, "a small turn off the slerp was dropped: kept %s", turned);
}

fn void turn_apart_resolves_small_turns() @test
{
	foreach (angle : (float[]){ 1.0e-5f, 1.0e-4f, 1.0e-3f, 0.5f })
	{
		float measured = crig::turn_apart(about_x(0.7f), about_x(0.7f + angle));
		test::@check(math::abs(measured - angle) < 0.05f * angle + 2.0e-6f,
			"a turn of %s measured %s", angle, measured);
	}
	// Either sign of the quaternion is the same turn.
	Quaternionf q = about_x(0.4f);
	Quaternionf flipped = { .v = -q.v };
	test::@check(crig::turn_apart(q, flipped) < 1.0e-6f, "a flipped quaternion read as a turn");
}

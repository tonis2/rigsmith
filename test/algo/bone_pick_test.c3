<* A click on a bone: where a ray enters the capsule round it, ends and all. *>
module crig_tests::bone_pick;

import crig;
import collision;
import std::core::test;
import std::math;

// A bone two long up the y axis, half a unit thick, seen from +z.
const Vec3 BONE_LOW @local = { 0, -1, 0 };
const Vec3 BONE_HIGH @local = { 0, 1, 0 };
const float BONE_RADIUS @local = 0.5f;

fn collision::Ray toward_minus_z(Vec3 from) @local => { .origin = from, .direction = { 0, 0, -1 } };

fn void a_ray_through_the_middle_enters_the_side() @test
{
	float? t = crig::ray_capsule_hit(toward_minus_z({ 0, 0, 5 }), BONE_LOW, BONE_HIGH, BONE_RADIUS);
	if (catch t)
	{
		test::@check(false, "the middle missed");
		return;
	}
	test::@check(math::is_approx(t, 4.5f, 1e-4f), "entered at %f", t);
}

fn void a_ray_beside_the_bone_misses() @test
{
	test::@check(!@ok(crig::ray_capsule_hit(toward_minus_z({ 0.6f, 0, 5 }), BONE_LOW, BONE_HIGH, BONE_RADIUS)), "beside it hit");
	test::@check(!@ok(crig::ray_capsule_hit(toward_minus_z({ 0, 1.6f, 5 }), BONE_LOW, BONE_HIGH, BONE_RADIUS)), "past its end hit");
	// Behind the origin is no hit.
	test::@check(!@ok(crig::ray_capsule_hit(toward_minus_z({ 0, 0, -5 }), BONE_LOW, BONE_HIGH, BONE_RADIUS)), "behind it hit");
}

fn void an_end_cap_is_a_ball() @test
{
	// Over the end, where only the cap's ball reaches: 0.3 up it is 0.4 deep.
	float? t = crig::ray_capsule_hit(toward_minus_z({ 0, 1.3f, 5 }), BONE_LOW, BONE_HIGH, BONE_RADIUS);
	if (catch t)
	{
		test::@check(false, "the cap missed");
		return;
	}
	test::@check(math::is_approx(t, 4.6f, 1e-4f), "entered the cap at %f", t);

	// Down the axis, through the top cap.
	float? down = crig::ray_capsule_hit({ .origin = { 0, 5, 0 }, .direction = { 0, -1, 0 } }, BONE_LOW, BONE_HIGH, BONE_RADIUS);
	test::@check(math::is_approx(down ?? -1.0f, 3.5f, 1e-4f), "down the axis entered at %f", down ?? -1.0f);

	// A lone joint is one ball.
	float? ball = crig::ray_capsule_hit(toward_minus_z({ 0, 0, 5 }), { 0, 0, 1 }, { 0, 0, 1 }, BONE_RADIUS);
	test::@check(math::is_approx(ball ?? -1.0f, 3.5f, 1e-4f), "the ball entered at %f", ball ?? -1.0f);

	// From inside it is hit at once.
	test::@check(math::is_approx(crig::ray_capsule_hit(toward_minus_z({ 0, 0.5f, 0.2f }), BONE_LOW, BONE_HIGH, BONE_RADIUS) ?? -1.0f, 0.0f, 1e-4f), "inside was not hit at 0");
}

fn void the_nearer_of_two_bones_is_hit_first() @test
{
	collision::Ray ray = toward_minus_z({ 0.2f, 0, 5 });
	float? front = crig::ray_capsule_hit(ray, { 0, -1, 2 }, { 0, 1, 2 }, BONE_RADIUS);
	float? back = crig::ray_capsule_hit(ray, BONE_LOW, BONE_HIGH, BONE_RADIUS);
	test::@check(@ok(front) && @ok(back), "the ray did not pass through both");
	test::@check((front ?? float::max) < (back ?? 0.0f), "the far bone is nearer, %f against %f", front ?? -1.0f, back ?? -1.0f);
	// Off-centre it enters short of the axis: sqrt(0.25 - 0.04) before it.
	test::@check(math::is_approx(front ?? -1.0f, 3.0f - math::sqrt(0.21f), 1e-4f), "the near bone entered at %f", front ?? -1.0f);
}

<*
 The lasso's point buffer must not live in temp memory.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::lasso_heap`
*>
module crig_tests::lasso_heap;

import crig;
import crig_tests::shared_app;
import std::core::test;
import std::math;

fn void a_lasso_point_taken_inside_a_pool_survives_the_pool() @test
{
	crig::AppState app = crig::new_app(shared_app::cube());
	defer app.free();

	// The first point of a stroke arrives from inside a scope that closes.
	@pool()
	{
		test::@check(app.lasso_moved({ 10.0f, 10.0f }), "the first point was not taken");
	};

	// The next scope hands the same temp memory out again and writes over it.
	@pool()
	{
		char[] scribble = alloc::new_array(tmem, char, 4096);
		foreach (&c : scribble) *c = 0x7f;
		test::@check(app.lasso_moved({ 400.0f, 300.0f }), "the second point was not taken");
	};

	test::@check(app.lasso_points.len() == 2, "both points are still held");
	test::@check(app.lasso_points[0].x == 10.0f && app.lasso_points[0].y == 10.0f, "the first point still reads back");
	test::@check(app.lasso_points[1].x == 400.0f && app.lasso_points[1].y == 300.0f, "the second point still reads back");
	test::@check(app.lasso_points.allocator.ptr == mem.ptr, "the points are on the heap, not in temp memory");
}

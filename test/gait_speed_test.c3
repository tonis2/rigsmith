// author_gait at a ground speed: the stride and duration chosen so the figure
// travels at the speed asked, and a warning when a figure that size would run.
module crig_tests::gait_speed;

import crig;
import crig_tests::mcp;
import std::collections::object;
import std::core::test;
import std::io;
import std::math;

fn void a_walk_at_a_speed_travels_at_it() @test
{
	io::printn("gait speed: a walk at a speed travels at it");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();

	Object* walk = f.call_checked("author_gait", `{"name":"Paced","gait":"walk","speed":1.2}`);
	if (!walk) return;
	defer walk.free();
	double speed = walk.get_float("ground_speed") ?? 0;
	test::@check(math::abs(speed - 1.2) < 1.0e-3, "the walk runs at %f, not 1.2", speed);
	double duration = walk.get_float("duration") ?? 0;
	test::@check(duration > 0.6 && duration < 1.6, "a 1.2 walk on human legs lasts %f s a cycle", duration);
	test::@check(crig::member(walk, "warning") == null, "a 1.2 walk on human legs warned of a run");

	Object* timed = f.call_checked("author_gait", `{"name":"Timed","gait":"walk","speed":1.0,"duration":1.25}`);
	if (!timed) return;
	defer timed.free();
	test::@check(math::abs((timed.get_float("duration") ?? 0) - 1.25) < 1.0e-4, "a given duration was not kept");
	test::@check(math::abs((timed.get_float("ground_speed") ?? 0) - 1.0) < 1.0e-3, "the timed walk does not run at 1.0");

	Object* fast = f.call_checked("author_gait", `{"name":"Scurry","gait":"walk","speed":3.5}`);
	if (!fast) return;
	defer fast.free();
	test::@check(crig::member(fast, "warning") != null, "a 3.5 walk on human legs did not warn that it is a run");
}

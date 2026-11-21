<*
 The cutscene problems list, and what an actor shows between strips.

     `c3c test --test-filter crig_tests::cutscene_problems`
*>
module crig_tests::cutscene_problems;

import crig;
import crig_tests::helpers;
import std::core::test;
import std::math;
import std::math::quaternion;

fn CutStrip move(int path, float start, float end, String clip = "") @local
{
	CutStrip s = crig::cut_strip(MOVE, start, end);
	s.path = path;
	if (clip.len > 0) s.clip = clip.copy(mem);
	return s;
}

fn CutStrip turn_to(float start, float end, String row) @local
{
	CutStrip s = crig::cut_strip(TURN, start, end);
	s.target_row = row.copy(mem);
	return s;
}

fn CutActor actor(String row, CutStrip[] strips) @local
{
	return {
		.row = row.copy(mem),
		.home_rotation = quaternion::IDENTITY,
		.strips = strips.len > 0 ? alloc::clone_slice(mem, strips) : {},
	};
}

// Two actors, a path of two points and one of a single point.
fn Cutscene troubled() @local
{
	Cutscene c = { .name = "Troubled".copy(mem), .duration = 5.0f, .fps = 30.0f };
	c.paths = alloc::new_array(mem, WalkPath, 2);
	c.paths[0] = { .name = "road".copy(mem), .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) };
	c.paths[1] = { .name = "stub".copy(mem), .points = alloc::clone_slice(mem, (Vec3[]){ { 1, 0, 0 } }) };
	c.actors = alloc::new_array(mem, CutActor, 3);
	c.actors[0] = actor("hero", { move(0, 0, 2, "walk"), helpers::play(2, 6, "wave"), turn_to(3, 4, "ghost"), move(1, 4, 4.5f), move(7, 4.5f, 5) });
	c.actors[1] = actor("guide", { helpers::play(0, 1, "idle"), turn_to(1, 2, "hero") });
	c.actors[2] = actor("stranger", { helpers::play(0, 1, "anything") });
	return c;
}

fn bool has(CutProblem[] problems, CutProblemKind kind, usz actor, int strip) @local
{
	foreach (p : problems) if (p.kind == kind && p.actor == actor && p.strip == strip) return true;
	return false;
}

fn void every_kind_of_problem_is_named() @test
{
	Cutscene c = troubled();
	defer c.free(mem);
	String[] hero_clips = { "walk", "idle" };
	String[] guide_clips = { "idle" };
	CutCast[] cast = { { .found = true, .clips = hero_clips }, { .found = true, .clips = guide_clips }, { .found = false } };
	CutProblem[] problems = crig::cutscene_problems(mem, &c, cast);
	defer if (problems.len > 0) free(problems);

	test::@check(has(problems, MISSING_CLIP, 0, 1), "wave is not in the hero's file");
	test::@check(!has(problems, MISSING_CLIP, 0, 0), "walk is in the hero's file");
	test::@check(has(problems, ENDS_LATE, 0, 1), "the wave ends at 6 s in a 5 s cutscene");
	test::@check(has(problems, NO_TARGET, 0, 2), "the hero turns toward an actor the cutscene lacks");
	test::@check(!has(problems, NO_TARGET, 1, 1), "the guide turns toward the hero, who is in it");
	test::@check(has(problems, NO_PATH, 0, 3), "a path of one point is no path");
	test::@check(has(problems, NO_PATH, 0, 4), "path 7 is not there");
	test::@check(!has(problems, NO_PATH, 0, 0), "the road has two points");
	test::@check(has(problems, NO_CHARACTER, 2, -1), "no character plays the stranger");
	test::@check(!has(problems, MISSING_CLIP, 2, 0), "a missing character's clips are not checked");
	test::eq(problems.len, 6);

	foreach (p : problems)
	{
		String text = crig::cut_problem_text(mem, &c, p);
		defer text.free(mem);
		test::@check(text.starts_with(c.actors[p.actor].row), "'%s' does not name its actor first", text);
	}
	String late = crig::cut_problem_text(mem, &c, { ENDS_LATE, 0, 1 });
	defer late.free(mem);
	test::@check(late.contains("6.00 s") && late.contains("5.00 s"), "'%s' does not give both times", late);
}

fn void between_strips_the_last_clip_is_held() @test
{
	Cutscene c = { .name = "Hold".copy(mem), .duration = 10.0f, .fps = 30.0f };
	defer c.free(mem);
	c.paths = alloc::new_array(mem, WalkPath, 1);
	c.paths[0] = { .name = "road".copy(mem), .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) };
	c.actors = alloc::new_array(mem, CutActor, 1);
	CutStrip walk = move(0, 2, 4, "walk");
	walk.speed = 1.5f;
	c.actors[0] = actor("hero", { walk, helpers::play(6, 7, "wave") });
	CutCurve[] curves = crig::cutscene_curves(mem, &c);
	defer crig::free_cut_curves(mem, curves);

	CutActorPose before = crig::cutscene_actor_shown(&c, curves, 0, 1.0f);
	test::@check(before.strip < 0, "before its first strip an actor plays nothing: it stands at rest");
	CutActorPose walking = crig::cutscene_actor_shown(&c, curves, 0, 3.0f);
	test::eq(walking.strip, 0);
	test::@check(math::abs(walking.clip_time - 1.5f) < 1e-5f, "a second into the walk at 1.5x is 1.5 s of the clip, not %f", walking.clip_time);
	CutActorPose between = crig::cutscene_actor_shown(&c, curves, 0, 5.0f);
	test::eq(between.strip, 0);
	test::@check(between.holding, "after the walk ends the actor holds it");
	test::@check(math::abs(between.clip_time - (3.0f - 1e-3f)) < 1e-4f, "the walk is held a hair before its end, not at %f", between.clip_time);
	test::@check(math::abs(between.position.z - 4.0f) < 1e-3f, "and where it ended, not at %f", between.position.z);
	CutActorPose waving = crig::cutscene_actor_shown(&c, curves, 0, 6.5f);
	test::eq(waving.strip, 1);
}

fn void a_clip_time_wraps_on_a_loop_and_holds_otherwise() @test
{
	test::@check(math::abs(crig::cut_clip_local(2.5f, 1.0f, true) - 0.5f) < 1e-6f, "a loop wraps by its own length");
	test::@check(math::abs(crig::cut_clip_local(2.0f, 1.0f, true)) < 1e-6f, "a whole cycle wraps to the start");
	test::@check(math::abs(crig::cut_clip_local(-0.25f, 1.0f, true) - 0.75f) < 1e-6f, "an offset before the start wraps too");
	test::@check(math::abs(crig::cut_clip_local(2.5f, 1.0f, false) - 1.0f) < 1e-6f, "a clip that does not loop holds its end");
	test::@check(math::abs(crig::cut_clip_local(-1.0f, 1.0f, false)) < 1e-6f, "and its start");
	test::eq(crig::cut_clip_local(1.0f, 0.0f, true), 0.0f);
}

fn void overlaps_a_turn_at_itself_and_a_strip_with_no_length_are_named() @test
{
	Cutscene c = { .name = "Clashes".copy(mem), .duration = 10.0f, .fps = 30.0f };
	defer c.free(mem);
	c.paths = alloc::new_array(mem, WalkPath, 1);
	c.paths[0] = { .name = "road".copy(mem), .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) };
	c.actors = alloc::new_array(mem, CutActor, 2);
	// Plays that cross, a walk whose clip crosses a play, a turn crossing a plain move,
	// strips that only touch, a turn at itself and a strip with no length.
	c.actors[0] = actor("hero", { helpers::play(0, 2, "idle"), helpers::play(1, 3, "idle"), move(0, 4, 5, "walk"), helpers::play(4.5f, 6, "idle"),
		move(0, 6, 7), turn_to(6.5f, 7.5f, "guide"), helpers::play(7, 8, "idle"), turn_to(8, 9, "hero"), helpers::play(9, 9, "idle") });
	c.actors[1] = actor("guide", { helpers::play(0, 1, "idle"), helpers::play(1, 2, "idle") });
	String[] clips = { "idle", "walk" };
	CutCast[] cast = { { .found = true, .clips = clips }, { .found = true, .clips = clips } };
	CutProblem[] problems = crig::cutscene_problems(mem, &c, cast);
	defer if (problems.len > 0) free(problems);

	test::@check(has(problems, OVERLAP, 0, 1), "two plays at once on the What lane");
	test::@check(!has(problems, OVERLAP, 0, 0), "an overlap is named once, on the later strip");
	test::@check(has(problems, OVERLAP, 0, 3), "a play over a walk's clip");
	test::@check(has(problems, OVERLAP, 0, 5), "a turn over a move, on the Where lane");
	test::@check(!has(problems, OVERLAP, 0, 6), "a play during a move with no clip is fine");
	test::@check(!has(problems, OVERLAP, 1, 1), "strips that only touch do not overlap");
	test::@check(has(problems, SELF_TARGET, 0, 7), "a turn toward the actor itself");
	test::@check(!has(problems, NO_TARGET, 0, 7), "which is not also a missing target");
	test::@check(has(problems, NO_LENGTH, 0, 8), "a strip that ends where it starts");
	test::eq(problems.len, 5);

	String clash = crig::cut_problem_text(mem, &c, { OVERLAP, 0, 5 });
	defer clash.free(mem);
	test::@check(clash.contains("turn at 6.50 s") && clash.contains("move at 6.00 s") && clash.contains("Where"), "'%s'", clash);
	String what = crig::cut_problem_text(mem, &c, { OVERLAP, 0, 3 });
	defer what.free(mem);
	test::@check(what.contains("What"), "'%s'", what);
	String self_turn = crig::cut_problem_text(mem, &c, { SELF_TARGET, 0, 7 });
	defer self_turn.free(mem);
	test::@check(self_turn.contains("itself"), "'%s'", self_turn);
	String empty = crig::cut_problem_text(mem, &c, { NO_LENGTH, 0, 8 });
	defer empty.free(mem);
	test::@check(empty.contains("no length"), "'%s'", empty);
}

fn void a_walk_clip_that_travels_has_no_speed_or_faces_aside_is_named() @test
{
	Cutscene c = { .name = "Walks".copy(mem), .duration = 10.0f, .fps = 30.0f };
	defer c.free(mem);
	c.paths = alloc::new_array(mem, WalkPath, 1);
	c.paths[0] = { .name = "road".copy(mem), .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) };
	CutStrip typed = move(0, 3, 4, "idle");
	typed.ground_speed = 1.5f;
	c.actors = alloc::new_array(mem, CutActor, 2);
	c.actors[0] = actor("hero", { move(0, 0, 1, "walk"), move(0, 1, 2, "stride"), move(0, 2, 3, "idle"), typed, move(0, 4, 5) });
	c.actors[1] = actor("guide", { move(0, 0, 1, "walk") });
	String[] clips = { "walk", "stride", "idle" };
	CutClipGround[] grounds = { { .speed = 1.2f }, { .speed = 1.0f, .travels = true }, {} };
	CutCast[] cast = {
		{ .found = true, .clips = clips, .measured = true, .grounds = grounds, .facing_known = true, .faces_front = true },
		{ .found = true, .clips = clips, .measured = true, .grounds = grounds, .facing_known = true, .faces_front = false },
	};
	CutProblem[] problems = crig::cutscene_problems(mem, &c, cast);
	defer if (problems.len > 0) free(problems);

	test::@check(!has(problems, CLIP_TRAVELS, 0, 0) && !has(problems, NO_GROUND_SPEED, 0, 0), "an in-place walk with its speed is fine");
	test::@check(has(problems, CLIP_TRAVELS, 0, 1), "a walk clip that still travels");
	test::@check(!has(problems, NO_GROUND_SPEED, 0, 1), "whose travel is its ground speed");
	test::@check(has(problems, NO_GROUND_SPEED, 0, 2), "a walk clip with no ground speed");
	test::@check(!has(problems, NO_GROUND_SPEED, 0, 3), "unless the move has one typed");
	test::@check(!has(problems, NO_GROUND_SPEED, 0, 4), "a move with no clip needs no ground speed");
	test::@check(has(problems, NOT_FRONT, 1, -1), "the guide's character faces aside");
	test::@check(!has(problems, NOT_FRONT, 0, -1), "the hero's faces +Z");
	test::eq(problems.len, 3);
	test::@check(math::abs(cast[0].move_ground_speed(&c.actors[0].strips[3]) - 1.5f) < 1e-6f, "the typed speed is the one used");
	test::@check(math::abs(cast[0].move_ground_speed(&c.actors[0].strips[0]) - 1.2f) < 1e-6f, "else the clip's");

	String travels = crig::cut_problem_text(mem, &c, { CLIP_TRAVELS, 0, 1 });
	defer travels.free(mem);
	test::@check(travels.contains("stride") && travels.contains("travels"), "'%s'", travels);
	String speed = crig::cut_problem_text(mem, &c, { NO_GROUND_SPEED, 0, 2 });
	defer speed.free(mem);
	test::@check(speed.contains("idle") && speed.contains("1 m/s"), "'%s'", speed);
	String aside = crig::cut_problem_text(mem, &c, { NOT_FRONT, 1, -1 });
	defer aside.free(mem);
	test::@check(aside.starts_with("guide") && aside.contains("+Z"), "'%s'", aside);

	// A cast that measured nothing says nothing of walks.
	CutCast[] plain = { { .found = true, .clips = clips }, { .found = true, .clips = clips } };
	CutProblem[] none = crig::cutscene_problems(mem, &c, plain);
	defer if (none.len > 0) free(none);
	test::eq(none.len, 0);
}

fn void a_walk_over_a_move_with_no_ground_speed_or_that_travels_is_named() @test
{
	Cutscene c = { .name = "Walks".copy(mem), .duration = 12.0f, .fps = 30.0f };
	defer c.free(mem);
	c.paths = alloc::new_array(mem, WalkPath, 1);
	c.paths[0] = { .name = "road".copy(mem), .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) };
	CutStrip typed = helpers::play(6, 8, "idle", true);
	typed.ground_speed = 1.5f;
	c.actors = alloc::new_array(mem, CutActor, 1);
	// Walks over moves, then a still clip played after the last move ends.
	c.actors[0] = actor("hero", { move(0, 0, 2), helpers::play(0, 2, "walk", true), move(0, 2, 4), helpers::play(2, 4, "idle", true),
		move(0, 4, 6), helpers::play(4, 6, "stride", true), move(0, 6, 8), typed, helpers::play(8, 9, "idle") });
	String[] clips = { "walk", "stride", "idle" };
	CutClipGround[] grounds = { { .speed = 1.2f }, { .speed = 1.0f, .travels = true }, {} };
	CutCast[] cast = { { .found = true, .clips = clips, .measured = true, .grounds = grounds, .facing_known = true, .faces_front = true } };
	CutProblem[] problems = crig::cutscene_problems(mem, &c, cast);
	defer if (problems.len > 0) free(problems);

	test::@check(!has(problems, CLIP_TRAVELS, 0, 1) && !has(problems, NO_GROUND_SPEED, 0, 1), "an in-place walk with its speed is fine");
	test::@check(has(problems, NO_GROUND_SPEED, 0, 3), "a walk whose clip has no ground speed");
	test::@check(has(problems, CLIP_TRAVELS, 0, 5) && !has(problems, NO_GROUND_SPEED, 0, 5), "a walk whose clip still travels");
	test::@check(!has(problems, NO_GROUND_SPEED, 0, 7), "unless the walk has one typed");
	test::@check(!has(problems, NO_GROUND_SPEED, 0, 8), "a play over no move needs no ground speed");
	test::eq(problems.len, 2);

	String speed = crig::cut_problem_text(mem, &c, { NO_GROUND_SPEED, 0, 3 });
	defer speed.free(mem);
	test::@check(speed.contains("walk at 2.00 s") && speed.contains("'idle'") && speed.contains("its own speed"), "'%s'", speed);
	String travels = crig::cut_problem_text(mem, &c, { CLIP_TRAVELS, 0, 5 });
	defer travels.free(mem);
	test::@check(travels.contains("walk at 4.00 s") && travels.contains("travels"), "'%s'", travels);
}

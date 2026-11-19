<*
 Walks: a path's samples dropped onto the ground, the dropped path's length, the
 rate a walk's clip plays at, and the travel a clip keeps when made in place.

     `c3c test --test-filter crig_tests::cutscene_walk`
*>
module crig_tests::cutscene_walk;

import crig;
import rig;
import std::core::test;
import std::math;

fn bool near(float a, float b, float eps = 1e-3f) @local => math::abs(a - b) <= eps;

// A stand-in for the level's colliders, asked as ground_below asks: a ray down from
// 0.5 m over the point. A ramp from x = 2 to 6 up to 1 m, then level; a hole at x 7..8.
fn float stand_in_height(float x) @local
{
	if (x < 2.0f) return 0.0f;
	if (x < 6.0f) return (x - 2.0f) * 0.25f;
	return 1.0f;
}

fn bool stand_in_ground(void* context, Vec3 at, float* height) @local
{
	if (at.x > 7.0f && at.x < 8.0f) return false;
	float h = stand_in_height(at.x);
	if (h > at.y + crig::GROUND_RAY_LIFT) return false;
	*height = h;
	return true;
}

// A hill between two knots: up 2 m over 2 m from x = 1, flat to x = 7, down again by x = 9.
fn bool hill_ground(void* context, Vec3 at, float* height) @local
{
	float h = 0.0f;
	if (at.x > 1.0f && at.x < 9.0f) h = math::min(math::min(at.x - 1.0f, 9.0f - at.x), 2.0f);
	if (h > at.y + crig::GROUND_RAY_LIFT) return false;
	*height = h;
	return true;
}

fn void samples_drop_onto_the_ground_and_keep_the_curve_where_there_is_none() @test
{
	Vec3[] knots = { { 0, 0, 0 }, { 5, 0.5f, 0 }, { 10, 1.0f, 0 } };
	WalkGround ground = { .probe = &stand_in_ground };
	WalkSamples dropped = crig::sample_walk_path(mem, knots, ground: ground);
	defer free(dropped.points);
	test::@check(dropped.points.len >= 2, "no samples");
	float widest;
	for (usz k = 0; k < dropped.points.len; k++)
	{
		Vec3 p = dropped.points[k];
		if (k > 0) widest = math::max(widest, (p - dropped.points[k - 1]).length());
		// A sample beside the hole lies on the line down into it.
		if (p.x > 6.74f && p.x < 8.26f) continue;
		test::@check(near(p.y, stand_in_height(p.x), 0.02f), "the sample at x %f stands at %f, not on the ground at %f", p.x, p.y, stand_in_height(p.x));
	}
	test::@check(widest <= crig::WALK_PATH_SPACING + 2e-3f, "samples %f apart", widest);
	test::@check(near(dropped.points[0].x, 0.0f) && near(dropped.points[^1].x, 10.0f), "the ends are the end knots");
	test::@check(near(dropped.length, crig::polyline_length(dropped.points), 1e-4f), "the length is the dropped line's: %f", dropped.length);

	// Over the hole the curve's own height is kept.
	WalkSamples curve = crig::sample_walk_path(mem, knots);
	defer free(curve.points);
	foreach (p : dropped.points)
	{
		if (p.x <= 7.3f || p.x >= 7.7f) continue;
		float want;
		float best = float::max;
		foreach (c : curve.points)
		{
			if (math::abs(c.x - p.x) < best) { best = math::abs(c.x - p.x); want = c.y; }
		}
		test::@check(near(p.y, want, 0.05f), "over the hole at x %f the sample is at %f, not the curve's %f", p.x, p.y, want);
	}
}

fn void a_rise_between_two_knots_is_found_from_above() @test
{
	// Both knots on the floor at either side; the hill is 2 m over the chord, more than a ray's lift.
	Vec3[] knots = { { 0, 0, 0 }, { 10, 0, 0 } };
	WalkSamples dropped = crig::sample_walk_path(mem, knots, ground: { .probe = &hill_ground });
	defer free(dropped.points);
	float top;
	foreach (p : dropped.points) top = math::max(top, p.y);
	test::@check(near(top, 2.0f, 1e-3f), "the walk goes over the hill's top, 2 m, not %f", top);
	// 1 m flat, up 2 m over 2 m, 4 m along the top, down again and 1 m flat.
	float want = 2.0f * math::sqrt(8.0f) + 6.0f;
	test::@check(near(dropped.length, want, 0.05f), "the dropped length is %f, not %f", dropped.length, want);
}

fn bool ramp_ground(void* context, Vec3 at, float* height) @local
{
	*height = at.x * 0.5f;
	return true;
}

fn void a_dropped_path_is_as_long_as_its_line_on_the_ground() @test
{
	// Two knots on a ramp: the walk is the ramp itself, longer than its run across the floor.
	Vec3[] knots = { { 0, 0, 0 }, { 4, 2, 0 } };
	WalkPath path = { .knots = alloc::clone_slice(mem, knots) };
	defer path.free(mem);
	path.resample(mem, { .probe = &ramp_ground });
	test::@check(near(path.length, math::sqrt(20.0f), 1e-3f), "the ramp is %f long, not %f", path.length, math::sqrt(20.0f));
	foreach (p : path.points) test::@check(near(p.y, p.x * 0.5f, 1e-4f), "a sample at x %f is off the ramp", p.x);
	// With no ground the samples keep the curve.
	path.resample(mem);
	test::@check(near(path.length, math::sqrt(20.0f), 1e-3f), "the line itself is %f long", path.length);
}

fn void a_walk_plays_at_the_rate_that_keeps_its_feet_on_the_ground() @test
{
	test::@check(near(crig::cut_walk_rate(8.0f, 4.0f, 1.0f), 2.0f), "8 m in 4 s on a 1 m/s walk plays it at 2x");
	test::@check(near(crig::cut_walk_rate(6.0f, 4.0f, 1.5f), 1.0f), "the walk's own pace plays it at 1x");
	test::@check(near(crig::cut_walk_rate(6.0f, 4.0f, 0.0f), 1.0f), "no ground speed leaves it at 1x");
	test::@check(near(crig::cut_walk_rate(6.0f, 0.0f, 1.0f), 1.0f), "nor does a strip with no length");
	test::@check(near(crig::cut_walk_seconds(9.0f, 1.5f), 6.0f), "9 m at 1.5 m/s takes 6 s");
	test::@check(near(crig::cut_walk_seconds(9.0f, 0.0f), 9.0f / crig::CUT_DEFAULT_GROUND_SPEED), "with no ground speed it is timed at 1 m/s");
	String[] named = { "Idle", "slow_Walk", "Run" };
	String[] several = { "wounded_walk", "Walk_fast", "walk", "Run" };
	String[] unnamed = { "Idle", "Run" };
	sz walk = crig::cut_walk_clip(named);
	sz plain = crig::cut_walk_clip(several);
	sz none = crig::cut_walk_clip(unnamed);
	test::@check(walk == 1, "the walk is clip %d", walk);
	test::@check(plain == 2, "a clip called walk wins, not clip %d", plain);
	test::@check(none == -1, "no clip is named like a walk, not %d", none);
	Vec3[] knots = { { 0, 0, 0 }, { 4, 0, 0 }, { 8, 0, 0 } };
	usz late = crig::walk_knot_span(knots, { 6, 0, 0.5f });
	usz early = crig::walk_knot_span(knots, { 1, 0, -0.5f });
	test::@check(late == 1 && early == 0, "the spans are %d and %d", late, early);
}

fn CutStrip walk_strip(CutStripKind kind, float start, float end, int path = -1, String clip = "") @local
{
	CutStrip s = crig::cut_strip(kind, start, end);
	s.path = path;
	if (clip.len > 0) s.clip = clip.copy(mem);
	return s;
}

fn void a_play_pairs_with_the_latest_move_running_when_it_starts() @test
{
	WalkPath[2] paths = {
		{ .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) },
		{ .points = alloc::clone_slice(mem, (Vec3[]){ { 1, 0, 0 } }) },
	};
	defer foreach (&p : paths) p.free(mem);
	CutStrip[] strips = {
		walk_strip(MOVE, 0, 4, 0),             // 0: the road
		walk_strip(PLAY, 0, 4, clip: "walk"),  // 1: over it from its start
		walk_strip(MOVE, 2, 6, 0),             // 2: begun later, so it wins from 2 s
		walk_strip(PLAY, 3, 5, clip: "walk"),  // 3: while both run
		walk_strip(PLAY, 6, 7, clip: "walk"),  // 4: just as the later move ends
		walk_strip(MOVE, 8, 10, 1),            // 5: a path of one point
		walk_strip(PLAY, 8, 9, clip: "walk"),  // 6: over it
		walk_strip(MOVE, 11, 13, 0),           // 7
		walk_strip(PLAY, 11, 13, clip: "wave"), // 8: a one-off over a move
		walk_strip(PLAY, 12, 13),              // 9: no clip
		walk_strip(MOVE, 14, 16, -1),          // 10: no path at all
		walk_strip(PLAY, 15, 16, clip: "walk"), // 11
	};
	strips[8].one_off = true;
	defer foreach (&s : strips) s.free(mem);

	test::eq(crig::cut_paired_move(strips, 1, paths[..]), 0);
	test::eq(crig::cut_paired_move(strips, 3, paths[..]), 2);
	test::@check(crig::cut_paired_move(strips, 4, paths[..]) == -1, "a play starting as the move ends pairs");
	test::@check(crig::cut_paired_move(strips, 6, paths[..]) == -1, "a move with no path of two points pairs");
	test::@check(crig::cut_paired_move(strips, 8, paths[..]) == -1, "a one-off pairs");
	test::@check(crig::cut_paired_move(strips, 9, paths[..]) == -1, "a play of no clip pairs");
	test::@check(crig::cut_paired_move(strips, 11, paths[..]) == -1, "a move with no path pairs");
	test::@check(crig::cut_paired_move(strips, 0, paths[..]) == -1, "a move pairs with itself");
	test::eq(crig::cut_move_at(strips, 2.5f, paths[..]), 2);
	test::eq(crig::cut_move_at(strips, 1.0f, paths[..]), 0);
	test::eq(crig::cut_move_at(strips, 7.0f, paths[..]), -1);
}

fn void a_play_spanning_its_move_is_tied_and_takes_its_new_times() @test
{
	WalkPath[1] paths = { { .points = alloc::clone_slice(mem, (Vec3[]){ { 0, 0, 0 }, { 0, 0, 4 } }) } };
	defer paths[0].free(mem);
	CutStrip[] strips = alloc::new_array(mem, CutStrip, 5);
	strips[0] = walk_strip(MOVE, 0, 4, 0);            // the road
	strips[1] = walk_strip(PLAY, 0, 4, clip: "walk"); // spans it: tied
	strips[2] = walk_strip(PLAY, 4, 6, clip: "rest"); // after it
	strips[3] = walk_strip(MOVE, 8, 12, 0);
	strips[4] = walk_strip(PLAY, 9, 12, clip: "walk"); // over only part of it
	foreach (usz k, &s : strips) s.id = (uint)k + 1;
	defer
	{
		foreach (&s : strips) s.free(mem);
		free(strips);
	}
	test::@check(crig::cut_play_tied(strips, 1, 0, paths[..]), "a play spanning its move is not tied");
	test::@check(!crig::cut_play_tied(strips, 4, 3, paths[..]), "a play over part of its move is tied");
	CutTie[] ties = crig::cut_ties(mem, strips, paths[..]);
	defer free(ties);
	test::@check(ties.len == 1 && ties[0].move == 1 && ties[0].play == 2, "%d ties", ties.len);

	// Nothing moved: nothing is carried.
	test::@check(!crig::cut_carry_ties(mem, &strips, ties), "an unmoved move carried its walk");

	// The road a second longer: the walk takes its times, and the rest after it gives way.
	strips[0].end = 5.0f;
	strips[3].end = 13.0f;
	test::@check(crig::cut_carry_ties(mem, &strips, ties), "nothing carried");
	test::@check(strips[1].start == 0.0f && strips[1].end == 5.0f, "the walk runs %f to %f", strips[1].start, strips[1].end);
	test::@check(near(strips[2].start, 5.0f) && near(strips[2].end, 6.0f), "the rest runs %f to %f", strips[2].start, strips[2].end);
	test::@check(strips[4].start == 9.0f && strips[4].end == 12.0f, "the partial walk moved to %f to %f", strips[4].start, strips[4].end);
}

// Hips over two legs and a head, five joints tall 1.7.
fn rig::Skeleton walker() @local
{
	Vec3[] joints = alloc::new_array(mem, Vec3, 5);
	int[] parents = alloc::new_array(mem, int, 5);
	joints[0] = { 0, 1.0f, 0 };
	joints[1] = { 0, 1.7f, 0 };
	joints[2] = { 0.15f, 0.0f, 0 };
	joints[3] = { -0.15f, 0.0f, 0 };
	joints[4] = { 0, 1.35f, 0 };
	parents[0] = -1;
	parents[1] = 4;
	parents[2] = 0;
	parents[3] = 0;
	parents[4] = 0;
	return { .joints = joints, .parents = parents };
}

// Hips carried 0.3 rig heights forward and 0.4 aside over a second, with a sway.
fn AnimTemplate travelling() @local
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 5);
	for (usz k = 0; k < 5; k++)
	{
		float f = (float)k / 4.0f;
		float sway = k % 2 == 1 ? 0.03f : 0.0f;
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = "hips".copy(mem), .axis = { 0, 1, 0 }, .move = { 0.4f * f + sway, 0, 0.3f * f }, .channels = TRANSLATION };
		frames[k] = { .time = f, .dots = dots };
	}
	return { .name = "walk".copy(mem), .duration = 1.0f, .keyframes = frames, .loop = true, .owned = true };
}

fn void made_in_place_a_walk_keeps_the_travel_it_took_off() @test
{
	rig::Skeleton skeleton = walker();
	defer skeleton.free(mem);
	String[] names = { "hips", "head", "foot_L", "foot_R", "spine" };
	AnimTemplate walk = travelling();
	defer walk.free(mem);

	AnimTravel still = crig::clip_travel(&skeleton, names, walk);
	test::@check(near(still.distance, 0.5f, 1e-3f), "the hips cross %f rig heights, not 0.5", still.distance);
	test::@check(near(still.speed, 0.5f, 1e-3f), "at %f rig heights a second, not 0.5", still.speed);

	AnimTemplate moved;
	RootMotionOutcome outcome = crig::clip_root_moved(mem, walk, &skeleton, names, { .mode = IN_PLACE }, &moved);
	test::@check(outcome == MOVED, "the walk was not made in place: %s", outcome);
	if (outcome != MOVED) return;
	defer moved.free(mem);
	test::@check(near(moved.travel.distance, 0.5f, 1e-3f) && near(moved.travel.speed, 0.5f, 1e-3f),
		"made in place it keeps a travel of %f at %f", moved.travel.distance, moved.travel.speed);
	AnimTravel left = crig::clip_travel(&skeleton, names, moved);
	test::@check(left.distance < 1e-3f, "in place it still travels %f", left.distance);

	// A retimed copy covers the same ground in twice the time.
	AnimTemplate slow = crig::clip_retimed(mem, moved, 2.0f);
	defer slow.free(mem);
	test::@check(near(slow.travel.distance, 0.5f, 1e-3f) && near(slow.travel.speed, 0.25f, 1e-3f), "retimed the travel is %f at %f",
		slow.travel.distance, slow.travel.speed);
}

fn void a_clip_keeps_its_travel_in_the_file() @test
{
	AnimTemplate walk = travelling();
	defer walk.free(mem);
	walk.travel = { 0.5f, 0.25f };
	AnimTemplate[1] written = { walk };
	String text = crig::clip_extras_text(mem, written[..]);
	defer text.free(mem);
	test::@check(text.contains(`"travel":{"distance":0.5,"speed":0.25}`), "the extras are %s", text);
	AnimTemplate[1] read = { { .name = "walk".copy(mem), .duration = 1.0f, .loop = true, .owned = true } };
	defer read[0].free(mem);
	crig::apply_clip_extras(mem, read[..], text);
	test::@check(near(read[0].travel.distance, 0.5f) && near(read[0].travel.speed, 0.25f), "read back as %f at %f",
		read[0].travel.distance, read[0].travel.speed);
	// A clip that never travelled says nothing.
	written[0].travel = {};
	String still = crig::clip_extras_text(mem, written[..]);
	defer still.free(mem);
	test::@check(!still.contains("travel"), "the extras are %s", still);
}

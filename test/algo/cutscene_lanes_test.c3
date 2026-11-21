<*
 A cutscene's lanes: which strips clash, how a placed strip settles the others,
 and where a dragged time snaps.

     `c3c test --test-filter crig_tests::cutscene_lanes`
*>
module crig_tests::cutscene_lanes;

import crig;
import std::core::test;
import std::math;

fn CutStrip play(float start, float end, String clip = "idle") @local
{
	CutStrip s = crig::cut_strip(PLAY, start, end);
	s.clip = clip.copy(mem);
	return s;
}

fn CutStrip move(float start, float end, String clip = "") @local
{
	CutStrip s = crig::cut_strip(MOVE, start, end);
	s.path = 0;
	if (clip.len > 0) s.clip = clip.copy(mem);
	return s;
}

fn CutStrip turn(float start, float end) @local => crig::cut_strip(TURN, start, end);

fn void free_strips(CutStrip[] strips) @local
{
	foreach (&s : strips) s.free(mem);
	if (strips.len > 0) free(strips);
}

fn void lanes_are_where_and_what() @test
{
	CutStrip walk = move(0, 1, "walk");
	defer walk.free(mem);
	CutStrip glide = move(0, 1);
	CutStrip wave = play(0, 1);
	defer wave.free(mem);
	CutStrip face = turn(0, 1);
	test::eq(crig::cut_lane_bits(&walk), 3);
	test::eq(crig::cut_lane_bits(&glide), 1);
	test::eq(crig::cut_lane_bits(&wave), 2);
	test::eq(crig::cut_lane_bits(&face), 1);
	test::@check(crig::cut_strips_overlap(&walk, &wave), "a walk's clip is on the What lane");
	test::@check(!crig::cut_strips_overlap(&glide, &wave), "a move with no clip leaves the What lane free");
	test::@check(crig::cut_strips_overlap(&glide, &face), "a move and a turn share the Where lane");
	CutStrip after = play(1, 2);
	defer after.free(mem);
	test::@check(!crig::cut_strips_overlap(&wave, &after), "strips that only touch do not overlap");
}

fn void the_strip_placed_wins_and_the_others_give_way() @test
{
	// On the What lane: one covered, one cut at its end, one cut at its front,
	// and one on the Where lane untouched.
	CutStrip[] strips = alloc::new_array(mem, CutStrip, 5);
	strips[0] = play(0, 2, "before");
	strips[1] = play(2.5f, 3, "covered");
	strips[2] = play(3.5f, 6, "after");
	strips[3] = turn(1, 5);
	strips[4] = play(1.5f, 4, "placed");
	strips[2].offset = 0.5f;
	strips[2].speed = 2.0f;
	usz at = crig::cut_settle_strips(mem, &strips, 4);
	defer free_strips(strips);
	test::eq(strips.len, 4);
	test::@check(strips[at].clip == "placed" && math::is_approx(strips[at].start, 1.5f, 1e-4f) && math::is_approx(strips[at].end, 4.0f, 1e-4f), "the placed strip keeps its span");
	test::@check(strips[0].clip == "before" && math::is_approx(strips[0].start, 0, 1e-4f) && math::is_approx(strips[0].end, 1.5f, 1e-4f), "the one before is cut at its end");
	test::@check(strips[1].clip == "after" && math::is_approx(strips[1].start, 4.0f, 1e-4f) && math::is_approx(strips[1].end, 6.0f, 1e-4f), "the one after is cut at its front");
	test::@check(math::is_approx(strips[1].offset, 0.5f + 0.5f * 2.0f, 1e-4f), "its clip plays on where it was: offset %f", strips[1].offset);
	test::@check(strips[2].kind == TURN && math::is_approx(strips[2].start, 1, 1e-4f) && math::is_approx(strips[2].end, 5, 1e-4f), "the turn on the other lane is untouched");
	test::eq(at, (usz)3);
}

fn void a_play_strip_landed_inside_is_split_and_a_move_is_not() @test
{
	CutStrip[] strips = alloc::new_array(mem, CutStrip, 2);
	strips[0] = play(0, 10, "idle");
	strips[1] = play(4, 5, "wave");
	usz at = crig::cut_settle_strips(mem, &strips, 1);
	defer free_strips(strips);
	test::eq(strips.len, 3);
	test::@check(strips[at].clip == "wave", "the wave is the winner");
	test::@check(math::is_approx(strips[0].end, 4, 1e-4f) && strips[0].clip == "idle", "the idle keeps its part before");
	test::@check(strips[2].clip == "idle" && math::is_approx(strips[2].start, 5, 1e-4f) && math::is_approx(strips[2].end, 10, 1e-4f), "and its part after, as a new strip");
	test::@check(math::is_approx(strips[2].offset, 5, 1e-4f), "which plays on where the idle was: offset %f", strips[2].offset);
	test::@check(strips[2].id == 0, "the new piece waits for an id of its own");

	CutStrip[] walk = alloc::new_array(mem, CutStrip, 2);
	walk[0] = move(0, 10, "walk");
	walk[1] = turn(4, 5);
	at = crig::cut_settle_strips(mem, &walk, 1);
	defer free_strips(walk);
	test::eq(walk.len, 2);
	test::@check(math::is_approx(walk[0].end, 4, 1e-4f), "a move a turn lands inside keeps only its part before, not %f", walk[0].end);
	test::eq(at, (usz)1);
}

fn void nothing_moves_without_a_clash_or_a_length() @test
{
	CutStrip[] strips = alloc::new_array(mem, CutStrip, 2);
	strips[0] = play(0, 2);
	strips[1] = play(1, 1);
	CutStrip* first = &strips[0];
	usz at = crig::cut_settle_strips(mem, &strips, 1);
	defer free_strips(strips);
	test::eq(at, (usz)1);
	test::@check(&strips[0] == first && math::is_approx(strips[0].end, 2, 1e-4f), "a strip with no length covers nothing");
}

fn void a_front_trim_keeps_the_clip_in_place_down_to_its_start() @test
{
	CutStrip s = play(1, 3);
	defer s.free(mem);
	s.speed = 1.5f;
	s.trim_front(2.0f);
	test::@check(math::is_approx(s.start, 2, 1e-4f) && math::is_approx(s.offset, 1.5f, 1e-4f), "1 s later at 1.5x is 1.5 s into the clip, not %f", s.offset);
	s.trim_front(0.0f);
	test::@check(math::is_approx(s.start, 0, 1e-4f) && math::is_approx(s.offset, 0, 1e-4f), "and never before its first frame: %f", s.offset);
	CutStrip face = turn(1, 2);
	face.trim_front(1.5f);
	test::@check(math::is_approx(face.offset, 0, 1e-4f), "a turn has no clip to keep");
}

fn void a_dragged_time_snaps_to_a_mark_near_it_else_to_a_frame() @test
{
	float[] marks = { 1.234f, 5.0f };
	test::@check(math::is_approx(crig::cut_snap_time(1.25f, 30.0f, marks, 0.05f), 1.234f, 1e-4f), "a mark within reach wins over a frame");
	test::@check(math::is_approx(crig::cut_snap_time(1.31f, 30.0f, marks, 0.05f), 39.0f / 30.0f, 1e-4f), "out of reach the frame wins");
	test::@check(math::is_approx(crig::cut_snap_time(1.31f, 0.0f, marks, -1.0f), 1.31f, 1e-4f), "free: no mark, no frame");
	test::@check(math::is_approx(crig::cut_snap_time(4.97f, 30.0f, marks, 0.05f), 5.0f, 1e-4f), "the nearer mark");
	// A span snaps by whichever end is nearer a mark.
	test::@check(math::is_approx(crig::cut_snap_span(3.02f, 2.0f, 30.0f, marks, 0.05f), 3.0f, 1e-4f), "its end on 5 s");
	test::@check(math::is_approx(crig::cut_snap_span(1.22f, 2.0f, 30.0f, marks, 0.05f), 1.234f, 1e-4f), "its start on the mark");
	test::@check(math::is_approx(crig::cut_snap_span(2.01f, 1.0f, 30.0f, marks, 0.05f), 2.0f, 1e-4f), "no mark near: its start on a frame");
}

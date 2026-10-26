<*
 The Curves clean-up tools: Fix flips, Smooth, Simplify, Flatten and Match loop
 seam. The transforms are checked on clips built here, then through the app for
 the selection rule and for each being one undo step.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::curve_cleanup`
*>
module crig_tests::curve_cleanup;

import crig;
import std::core::test;
import std::collections::list;
import std::math;
import std::math::vector;
import std::math::quaternion;

const float PI2 = 2.0f * (float)math::PI;

// Keys on "hip" every quarter second: a turn about Z of `angles[i]` as written
// (not normalized, so a key may be stored on the far side) and a slide along X.
fn AnimTemplate hip_run(float[] angles, float[] slides, AnimInterpolation curve = LINEAR, bool loop = false)
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, (sz)angles.len);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "hip".copy(mem),
			.axis = { 0, 0, 1 },
			.angle = angles[i],
			.move = { slides[i], 0, 0 },
			.rotation_interpolation = curve,
			.translation_interpolation = curve,
		};
		*key = { .time = (float)i * 0.25f, .dots = dots };
	}
	AnimTemplate clip = { .name = "run".copy(mem), .duration = (float)(angles.len - 1) * 0.25f,
		.keyframes = keys, .loop = loop, .owned = true };
	clip.compile_tracks(mem);
	return clip;
}

// Every key of `hip`'s channel as a pick, over the whole clip.
fn AnimChannelKey[] hip_picks(AnimTemplate* clip, AnimChannels channel)
{
	List{AnimChannelKey} picks;
	picks.init(tmem);
	foreach (frame : clip.keyframes) picks.push({ .time = frame.time, .joint = "hip", .channel = channel });
	return picks.to_array(tmem);
}

fn String op_name(CurveCleanup op)
{
	String[5] names = { "Fix flips", "Smooth", "Simplify", "Flatten", "Match loop seam" };
	return names[op.ordinal];
}

// Both channels' keys.
fn AnimChannelKey[] hip_all_picks(AnimTemplate* clip)
{
	List{AnimChannelKey} picks;
	picks.init(tmem);
	foreach (pick : hip_picks(clip, ROTATION)) picks.push(pick);
	foreach (pick : hip_picks(clip, TRANSLATION)) picks.push(pick);
	return picks.to_array(tmem);
}

fn bool near(float a, float b, float within = 1.0e-4f) => math::abs(a - b) <= within;

fn Quaternionf turn_at(AnimTemplate* clip, usz key) => clip.keyframes[key].rotation_of("hip");

fn bool same_orientation(Quaternionf a, Quaternionf b) => math::abs(a.v.dot(b.v)) > 1.0f - 1.0e-5f;

fn void fix_flips_puts_every_key_on_its_neighbours_side() @test
{
	// Keys 1 and 3 are written on the far side of the quaternion pair.
	float[5] angles = { 0.2f, 0.4f - PI2, 0.6f, 0.8f - PI2, 1.0f };
	float[5] slides = { 0, 0, 0, 0, 0 };
	AnimTemplate clip = hip_run(angles[..], slides[..]);
	defer clip.free(mem);
	test::@check(turn_at(&clip, 0).v.dot(turn_at(&clip, 1).v) < 0.0f, "the fixture has no flip to fix");

	usz changed;
	AnimTemplate fixed = crig::curves_euler_filtered(mem, clip, hip_picks(&clip, ROTATION), &changed);
	defer fixed.free(mem);
	test::@check(changed == 2, "fixed %d flips, wanted 2", changed);
	foreach (usz i, frame : fixed.keyframes)
	{
		test::@check(same_orientation(turn_at(&fixed, i), turn_at(&clip, i)), "key %d now holds another orientation", i);
		if (i > 0) test::@check(turn_at(&fixed, i - 1).v.dot(turn_at(&fixed, i).v) > 0.0f, "key %d still flips against the one before", i);
	}
	// The curve the sampler plays is unchanged too, between keys.
	for (int s = 0; s <= 16; s++)
	{
		float t = (float)s * 0.0625f;
		test::@check(same_orientation(fixed.rotation_at("hip", t), clip.rotation_at("hip", t)), "the pose at %f moved", t);
	}

	// Already continuous: nothing to do.
	usz again;
	AnimTemplate twice = crig::curves_euler_filtered(mem, fixed, hip_picks(&fixed, ROTATION), &again);
	defer twice.free(mem);
	test::@check(again == 0, "a second pass fixed %d keys", again);
}

fn void smooth_pulls_a_spike_down_and_leaves_the_ends() @test
{
	float[5] angles = { 0.0f, 0.0f, 0.8f, 0.0f, 0.0f };
	float[5] slides = { 0.1f, 0.1f, 0.5f, 0.1f, 0.1f };
	AnimTemplate clip = hip_run(angles[..], slides[..]);
	defer clip.free(mem);

	usz changed;
	AnimTemplate smooth = crig::curves_smoothed(mem, clip, hip_all_picks(&clip), &changed);
	defer smooth.free(mem);
	// Rotations and positions: three interior keys each.
	test::@check(changed == 6, "smoothed %d keys, wanted 6", changed);
	test::@check(near(smooth.keyframes[2].dots[0].angle, 0.4f, 1.0e-3f), "the spike reads %f", smooth.keyframes[2].dots[0].angle);
	test::@check(near(smooth.keyframes[1].dots[0].angle, 0.2f, 1.0e-3f) && near(smooth.keyframes[3].dots[0].angle, 0.2f, 1.0e-3f),
		"the neighbours read %f and %f", smooth.keyframes[1].dots[0].angle, smooth.keyframes[3].dots[0].angle);
	test::@check(near(smooth.keyframes[2].dots[0].move.x, 0.3f), "the slide spike reads %f", smooth.keyframes[2].dots[0].move.x);
	test::@check(smooth.keyframes[0].dots[0].angle == 0.0f && smooth.keyframes[4].dots[0].angle == 0.0f
		&& near(smooth.keyframes[0].dots[0].move.x, 0.1f) && near(smooth.keyframes[4].dots[0].move.x, 0.1f), "an end moved");

	// A range: only the interior of the picked run moves.
	AnimChannelKey[] some = { { .time = 0.25f, .joint = "hip", .channel = ROTATION },
		{ .time = 0.5f, .joint = "hip", .channel = ROTATION }, { .time = 0.75f, .joint = "hip", .channel = ROTATION } };
	AnimTemplate part = crig::curves_smoothed(mem, clip, some, &changed);
	defer part.free(mem);
	test::@check(changed == 1 && near(part.keyframes[2].dots[0].angle, 0.4f, 1.0e-3f)
		&& part.keyframes[1].dots[0].angle == 0.0f && part.keyframes[3].dots[0].angle == 0.0f
		&& near(part.keyframes[2].dots[0].move.x, 0.5f), "a range smoothed %d keys beyond its interior", changed);
}

fn void smooth_keeps_a_turn_through_the_far_side_of_the_pair() @test
{
	// The middle key is written as its negation: the same pose, and smoothing
	// must not drag it toward the long way round.
	float[3] angles = { 0.2f, 0.4f - PI2, 0.2f };
	float[3] slides = { 0, 0, 0 };
	AnimTemplate clip = hip_run(angles[..], slides[..]);
	defer clip.free(mem);
	usz changed;
	AnimTemplate smooth = crig::curves_smoothed(mem, clip, hip_picks(&clip, ROTATION), &changed);
	defer smooth.free(mem);
	Quaternionf want = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.3f);
	test::@check(same_orientation(turn_at(&smooth, 1), want), "the smoothed turn is not between its neighbours");
}

fn void simplify_drops_a_key_on_a_straight_run_and_keeps_a_needed_one() @test
{
	float[5] angles = { 0.0f, 0.1f, 0.2f, 0.3f, 1.0f };
	float[5] slides = { 0.0f, 0.1f, 0.2f, 0.3f, 1.0f };
	AnimTemplate clip = hip_run(angles[..], slides[..]);
	defer clip.free(mem);

	usz changed;
	AnimTemplate simple = crig::curves_simplified(mem, clip, hip_picks(&clip, ROTATION), &changed);
	defer simple.free(mem);
	// Keys 1 and 2 lie on the line from key 0 to key 3; key 3 is where it turns.
	test::@check(changed == 2, "removed %d keys, wanted 2", changed);
	test::@check(simple.channel_count("hip", true) == 3, "%d rotation keys left", simple.channel_count("hip", true));
	test::@check(simple.channel_count("hip", false) == 5, "the slide lost keys it was not asked about");
	simple.compile_tracks(mem);
	// The keys left are the first, the one where it turns, and the last.
	float[3] kept_at = { 0.0f, 0.75f, 1.0f };
	usz seen;
	foreach (frame : simple.keyframes)
	{
		AnimKeyDot dot;
		if (!frame.channel_dot("hip", true, &dot)) continue;
		test::@check(near(frame.time, kept_at[seen]), "rotation key %d is at %f", seen, frame.time);
		seen++;
	}
	// What is left plays the same.
	for (int s = 0; s <= 16; s++)
	{
		float t = (float)s * 0.0625f;
		test::@check(same_orientation(simple.rotation_at("hip", t), clip.rotation_at("hip", t)), "the pose at %f moved", t);
	}

	// Both channels: the keyframes left empty are dropped, the clip keeps its length.
	AnimTemplate bare = crig::curves_simplified(mem, clip, hip_all_picks(&clip), &changed);
	defer bare.free(mem);
	test::@check(changed == 4 && bare.keyframes.len == 3 && bare.duration == clip.duration,
		"%d removed, %d keyframes, %f long", changed, bare.keyframes.len, bare.duration);
}

fn void simplify_leaves_held_and_smooth_segments_alone() @test
{
	float[5] angles = { 0.0f, 0.1f, 0.2f, 0.3f, 0.4f };
	float[5] slides = { 0, 0, 0, 0, 0 };
	AnimInterpolation[2] curves = { HOLD, AUTO };
	foreach (curve : curves)
	{
		AnimTemplate clip = hip_run(angles[..], slides[..], curve);
		defer clip.free(mem);
		usz changed;
		AnimTemplate same = crig::curves_simplified(mem, clip, hip_picks(&clip, ROTATION), &changed);
		defer same.free(mem);
		test::@check(changed == 0 && same.keyframes.len == 5, "a %s run lost %d keys", curve.serialized(), changed);
	}
}

fn void flatten_sets_flat_tangents_on_the_picked_keys_only() @test
{
	float[3] angles = { 0.0f, 0.5f, 1.0f };
	float[3] slides = { 0, 0.5f, 1.0f };
	AnimTemplate clip = hip_run(angles[..], slides[..]);
	defer clip.free(mem);

	AnimChannelKey[] one = { { .time = 0.25f, .joint = "hip", .channel = ROTATION } };
	usz changed;
	AnimTemplate flat = crig::curves_flattened(mem, clip, one, &changed);
	defer flat.free(mem);
	test::@check(changed == 1, "flattened %d keys", changed);
	test::@check(flat.keyframes[1].dots[0].rotation_tangents.mode == FLAT, "the key is not flat");
	test::@check(flat.keyframes[1].dots[0].translation_tangents.mode == AUTO && flat.keyframes[0].dots[0].rotation_tangents.mode == AUTO
		&& flat.keyframes[2].dots[0].rotation_tangents.mode == AUTO, "an unpicked channel or key was flattened");
	test::@check(crig::effective_rotation_tangent(flat, 1, "hip", false).length() == 0.0f
		&& crig::effective_rotation_tangent(flat, 1, "hip", true).length() == 0.0f, "a flat key still has a slope");
	test::@check(near(flat.keyframes[1].dots[0].angle, 0.5f), "a value moved");

	// Already flat: nothing changes.
	AnimTemplate again = crig::curves_flattened(mem, flat, one, &changed);
	defer again.free(mem);
	test::@check(changed == 0, "a flat key was flattened again");
}

fn void the_loop_seam_takes_the_first_value_per_channel() @test
{
	float[4] angles = { 0.2f, 0.9f, 0.5f, 0.7f };
	float[4] slides = { 0.1f, 0.4f, 0.3f, 0.6f };
	AnimTemplate clip = hip_run(angles[..], slides[..], LINEAR, true);
	defer clip.free(mem);

	usz changed;
	AnimTemplate closed = crig::curves_loop_matched(mem, clip, hip_picks(&clip, ROTATION), &changed);
	defer closed.free(mem);
	test::@check(changed == 1, "matched %d channels", changed);
	test::@check(same_orientation(turn_at(&closed, 3), turn_at(&closed, 0)), "the last turn is not the first");
	test::@check(near(closed.keyframes[3].dots[0].move.x, 0.6f), "a channel that was not picked moved");
	test::@check(near(closed.keyframes[1].dots[0].angle, 0.9f) && near(closed.keyframes[2].dots[0].angle, 0.5f), "an inner key moved");

	AnimTemplate both = crig::curves_loop_matched(mem, closed, hip_picks(&closed, TRANSLATION), &changed);
	defer both.free(mem);
	test::@check(changed == 1 && near(both.keyframes[3].dots[0].move.x, 0.1f), "the slide seam is not closed");

	// The sampler now sees one value at both ends of the cycle.
	test::@check(same_orientation(both.rotation_at("hip", 0.0f), both.rotation_at("hip", both.duration)), "the seam still jumps");
	AnimTemplate settled = crig::curves_loop_matched(mem, both, hip_picks(&both, ROTATION), &changed);
	defer settled.free(mem);
	test::@check(changed == 0, "a closed seam was closed again");
}

// ---------------------------------------------------------------------------
// On the app

struct CleanupFixture
{
	AppState app;
	uint hip;
	AnimRef ref;
}

fn void CleanupFixture.open(&self, AnimTemplate clip)
{
	self.app = crig::new_app({});
	self.hip = self.app.doc.add_dot({ 0, 1, 0 }, "hip");
	self.app.doc.root_id = self.hip;
	self.ref = self.app.put_authored_clip(clip);
	(void)self.app.bind_ref(self.ref);
	self.app.undo_stack.commit();
	self.app.undo_stack.clear();
	self.app.editing = self.ref;
	self.app.select(self.hip);
}

fn void CleanupFixture.close(&self) => self.app.free();

fn AnimTemplate wobbly()
{
	// Flipped keys, a spike, a straight run and a differing end: every tool has work.
	float[6] angles = { 0.0f, 0.1f - PI2, 0.2f, 0.9f, 0.4f, 0.5f };
	float[6] slides = { 0.0f, 0.1f, 0.2f, 0.9f, 0.4f, 0.5f };
	return hip_run(angles[..], slides[..]);
}

fn void each_tool_is_one_undo_step() @test
{
	CurveCleanup[5] ops = { EULER_FILTER, SMOOTH, SIMPLIFY, FLATTEN, LOOP_SEAM };
	foreach (op : ops)
	{
		CleanupFixture f;
		f.open(wobbly());
		defer f.close();
		// Nothing picked: the selected joint's whole curves.
		sz history = f.app.undo_stack.cursor;
		bool done;
		switch (op)
		{
			case EULER_FILTER: done = f.app.euler_filter_selection(f.app.editing);
			case SMOOTH: done = f.app.smooth_selection(f.app.editing);
			case SIMPLIFY: done = f.app.simplify_selection(f.app.editing);
			case FLATTEN: done = f.app.flatten_selection(f.app.editing);
			case LOOP_SEAM: done = f.app.match_loop_seam_selection(f.app.editing);
		}
		test::@check(done, "%s was refused", op_name(op));
		test::@check(f.app.undo_stack.cursor == history + 1, "%s was %d undo steps", op_name(op), f.app.undo_stack.cursor - history);
		AnimTemplate* after = f.app.clip(f.app.editing);
		bool differs = after.keyframes.len != 6;
		foreach (usz i, frame : after.keyframes) if (i < 6 && frame.dots.len > 0)
		{
			AnimKeyDot was = wobbly_dot(i);
			differs = differs || was.angle != frame.dots[0].angle || was.move != frame.dots[0].move
				|| frame.dots[0].rotation_tangents.explicit() || frame.dots[0].translation_tangents.explicit();
		}
		test::@check(differs, "%s changed nothing", op_name(op));
		test::@check(f.app.undo(), "%s did not undo", op_name(op));
		AnimTemplate* back = f.app.clip(f.app.editing);
		bool restored = back.keyframes.len == 6;
		for (usz i = 0; restored && i < 6; i++)
		{
			AnimKeyDot was = wobbly_dot(i);
			restored = near(back.keyframes[i].dots[0].angle, was.angle) && back.keyframes[i].dots[0].move == was.move
				&& !back.keyframes[i].dots[0].rotation_tangents.explicit();
		}
		test::@check(restored, "undoing %s did not restore the clip", op_name(op));
	}
}

fn AnimKeyDot wobbly_dot(usz i)
{
	AnimTemplate clip = wobbly();
	defer clip.free(mem);
	AnimKeyDot dot = clip.keyframes[i].dots[0];
	dot.joint_name = {};
	return dot;
}

fn void a_tool_with_nothing_to_act_on_says_so_and_changes_nothing() @test
{
	CleanupFixture f;
	f.open(wobbly());
	defer f.close();
	f.app.select(0);
	sz history = f.app.undo_stack.cursor;
	test::@check(!f.app.flatten_selection(f.app.editing), "flattened with nothing selected");
	test::@check(f.app.undo_stack.cursor == history, "a refused tool left an undo step");

	// Pose edit pending: refused like the other clip rewrites.
	f.app.select(f.hip);
	f.app.pose_edit_pending = true;
	test::@check(!f.app.flatten_selection(f.app.editing) && f.app.undo_stack.cursor == history, "ran with a pose edit pending");
}

fn void picked_keys_decide_which_channels_a_tool_acts_on() @test
{
	// A channel key picked: only that channel's key.
	{
		CleanupFixture f;
		f.open(wobbly());
		defer f.close();
		test::@check(f.app.select_animation_channel_key(f.app.editing, 0.5f, "hip", ROTATION), "no key to pick");
		test::@check(f.app.flatten_selection(f.app.editing), "flatten refused");
		AnimTemplate* clip = f.app.clip(f.app.editing);
		foreach (usz i, frame : clip.keyframes)
		{
			bool rotation = frame.dots[0].rotation_tangents.mode == FLAT;
			test::@check(rotation == (i == 2), "rotation tangent at key %d: %s", i, rotation);
			test::@check(frame.dots[0].translation_tangents.mode == AUTO, "the slide at key %d was flattened", i);
		}
		test::@check(f.app.animation_channel_key_selected(f.app.editing, 0.5f, "hip", ROTATION), "the pick was dropped");
	}
	// A whole pose picked: every channel keyed in its column.
	{
		CleanupFixture f;
		f.open(wobbly());
		defer f.close();
		test::@check(f.app.select_animation_key(f.app.editing, 0.5f), "no key to pick");
		test::@check(f.app.flatten_selection(f.app.editing), "flatten refused");
		AnimKeyDot dot = f.app.clip(f.app.editing).keyframes[2].dots[0];
		test::@check(dot.rotation_tangents.mode == FLAT && dot.translation_tangents.mode == FLAT, "the column was not flattened");
		test::@check(f.app.clip(f.app.editing).keyframes[1].dots[0].rotation_tangents.mode == AUTO, "another column was flattened");
	}
}

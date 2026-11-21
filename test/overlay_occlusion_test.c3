<*
 The overlay's behind-the-mesh dimming is exact on a still view and throttled
 while a clip's clock runs, so a running animation stops casting a fresh ray
 through the deforming mesh for every dot and bone on every frame.

 These tests drive the throttle with `show_mesh` off: the exact test then always
 answers "not hidden", so any "hidden" that `overlay_occluded` returns can only
 have come from the memo. That isolates the scheduling from the geometry the
 posed cast would otherwise need.
*>
module crig_tests::overlay_occlusion;

import crig;
import std::core::test;
import std::math;

// A bone's memo key sits in a namespace the dot ids never reach, so a bone and a
// dot cannot land on the same memo slot and read each other's answer.
fn void bone_keys_stay_clear_of_the_dot_ids() @test
{
	test::@check(crig::overlay_bone_key(3, 9) >= 0x80000000u,
		"a bone key fell into the small-integer range dot ids live in");
	test::@check(crig::overlay_bone_key(0, 0) >= 0x80000000u,
		"the zero edge's key collided with dot id 0");
	test::@check(crig::overlay_bone_key(3, 9) == crig::overlay_bone_key(3, 9),
		"the bone key is not stable for one edge");
}

<*
 While a clip runs, an element outside the frame's refresh slice keeps its last
 answer even when the exact test would now disagree; the frame whose slice holds
 it recomputes and writes the memo back; the phase walks every slice and wraps;
 and a still view, or a clip parked mid-scrub, answers exactly every frame.
*>
fn void the_memo_is_trusted_only_off_phase_while_a_clip_runs() @test
{
	AppState app = crig::new_app({});
	defer app.free();

	app.show_mesh = false;      // the exact test now always says "not hidden"
	app.animating = true;
	app.anim_paused = false;

	uint key = 12;              // 12 % 4 == 0
	app.occlusion_memo.set(key, true);
	app.occlusion_phase = 1;
	test::@check(app.overlay_occluded(key, {}, { 1, 0, 0 }),
		"an off-phase frame recast instead of reusing the memo");

	app.occlusion_phase = 0;    // this frame's slice includes the key
	test::@check(!app.overlay_occluded(key, {}, { 1, 0, 0 }),
		"the on-phase frame did not recompute the exact answer");
	test::@check(!app.occlusion_memo.get(key)!!,
		"the recompute did not write its answer back to the memo");

	uint start = app.occlusion_phase;
	for (uint i = 0; i < crig::OCCLUSION_REFRESH_STRIDE; i++) app.advance_occlusion_phase();
	test::eq(app.occlusion_phase, start);
	app.advance_occlusion_phase();
	test::@check(app.occlusion_phase < crig::OCCLUSION_REFRESH_STRIDE,
		"the phase left the range of valid slices");

	uint still = 7;
	app.anim_paused = true;
	app.occlusion_memo.set(still, true);
	test::@check(!app.overlay_occluded(still, {}, { 1, 0, 0 }),
		"a parked clip trusted a stale memo instead of the exact test");
	app.animating = false;
	app.occlusion_memo.set(still, true);
	test::@check(!app.overlay_occluded(still, {}, { 1, 0, 0 }),
		"a still frame trusted a stale memo instead of the exact test");
}

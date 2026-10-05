module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::io;
import std::math;

fn AnimTemplate timed_clip()
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 3);
	foreach (usz i, &key : keys)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "hips".copy(mem),
			.axis = { 0, 1, 0 },
			.angle = (float)i,
			.move = { (float)i, 0, 0 },
			.channels = BOTH,
		};
		*key = { .time = (float)i, .dots = dots };
	}
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 1);
	feet[0] = { .joint = "foot".copy(mem), .down = 0.7f, .up = 0.15f };
	return {
		.name = "walk".copy(mem), .duration = 2.0f, .keyframes = keys,
		.loop = true, .ground = { .feet = feet, .floor = -1.0f, .floor_set = true }, .owned = true,
	};
}

fn void stretch_preserves_motion_phase_and_ground_contacts() @test
{
	io::printn("stretching changes speed without changing motion phase or contacts");
	AnimTemplate source = timed_clip();
	defer source.free(mem);
	AnimTemplate stretched = crig::clip_retimed(mem, source, 5.0f);
	defer stretched.free(mem);

	test::@check(math::abs(stretched.duration - 5.0f) < 1.0e-6f, "duration was not stretched");
	test::@check(math::abs(stretched.keyframes[1].time - 2.5f) < 1.0e-6f
		&& math::abs(stretched.keyframes[2].time - 5.0f) < 1.0e-6f, "key phases moved");
	AnimKeyDot before = source.entry_at("hips", 0.75f);
	AnimKeyDot after = stretched.entry_at("hips", 1.875f);
	test::@check(math::abs(before.angle - after.angle) < 1.0e-5f && before.move == after.move,
		"equal phases sample different motion");
	test::@check(stretched.ground.feet.len == 1
		&& stretched.ground.feet[0].down == source.ground.feet[0].down
		&& stretched.ground.feet[0].up == source.ground.feet[0].up,
		"normalized contact window changed");
	test::@check(source.duration == 2.0f && source.keyframes[1].time == 1.0f,
		"retiming mutated the source");
}

fn void invalid_durations_are_refused() @test
{
	io::printn("retiming refuses non-positive and non-finite durations");
	AnimTemplate source = timed_clip();
	defer source.free(mem);

	float infinity = 1.0f;
	infinity /= 0.0f;
	AnimTemplate zero = crig::clip_retimed(mem, source, 0.0f);
	defer zero.free(mem);
	AnimTemplate infinite = crig::clip_retimed(mem, source, infinity);
	defer infinite.free(mem);
	test::@check(zero.duration == source.duration && infinite.duration == source.duration,
		"an invalid duration changed the clip");

	AnimTemplate crowded = crig::clip_retimed(mem, source, 0.0005f);
	defer crowded.free(mem);
	test::@check(crowded.duration == source.duration,
		"stretching collapsed distinct saved poses onto one time");
}

fn void animation_stretch_dialog_scales_keys_and_undoes_once() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Stretch", 2.0f);
	f.app.editing = f.app.key_here(clip, 1.0f);
	f.app.edit_time = 1.5f;
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-retime")!!);
	f.ui.flush();
	Element* duration = f.ui.find_id("anim-retime-duration")!!;
	duration.widget_as(TextField).set_text(duration, "4");
	f.click(f.center_of("anim-retime-confirm")!!);
	f.ui.flush();
	AnimRef stretched = f.app.editing;
	test::@check(f.app.clip(stretched).duration == 4.0f
		&& f.app.clip(stretched).keyframes[1].time == 2.0f, "dialog did not scale saved poses");
	test::@check(math::abs(f.app.edit_time - 3.0f) < 1.0e-6f, "playhead lost its relative phase");
	test::@check(f.app.undo_stack.cursor == history + 1, "authored stretch was not one history record");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).duration == 2.0f
		&& f.app.clip(f.app.editing).keyframes[1].time == 1.0f, "stretch did not undo in one step");

	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-retime")!!);
	f.ui.flush();
	duration = f.ui.find_id("anim-retime-duration")!!;
	duration.widget_as(TextField).set_text(duration, "3");
	f.click(f.center_of("anim-retime-cancel")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).duration == 2.0f
		&& f.app.clip(f.app.editing).keyframes[1].time == 1.0f, "Cancel changed timing");
	f.app.pose_edit_pending = true;
	crig::anim_retime_clicked(f.ui);
	test::@check(!f.ui.find_id("anim-retime-dialog")!!.widget_as(Dialog).open
		&& f.app.clip(f.app.editing).duration == 2.0f, "unsaved pose did not block retiming");
	f.app.pose_edit_pending = false;

	// The ordinary duration field deliberately edits the endpoint only. Stretch
	// is explicit because silently changing every saved time is destructive.
	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-properties")!!);
	f.ui.flush();
	duration = f.ui.find_id("anim-new-duration")!!;
	duration.widget_as(TextField).set_text(duration, "3");
	Element* loop = f.ui.find_id("anim-properties-loop")!!;
	bool old_loop = loop.widget_as(Checkbox).checked;
	f.click(loop.absolute + loop.size * 0.5f);
	f.click(f.center_of("anim-create")!!);
	f.ui.flush();
	test::@check(f.app.clip(f.app.editing).duration == 3.0f
		&& f.app.clip(f.app.editing).keyframes[1].time == 1.0f
		&& f.app.clip(f.app.editing).loop != old_loop,
		"endpoint duration unexpectedly stretched saved poses");
	test::@check(f.app.undo() && f.app.clip(f.app.editing).duration == 2.0f
		&& f.app.clip(f.app.editing).loop == old_loop,
		"duration and authored loop did not undo together");
}

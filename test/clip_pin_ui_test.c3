<*
 Clip pins in the interface: the Joint panel's From / To / Blend fields and the
 dopesheet's pin lane (and dragging its bar's ends).
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;

fn void a_pin_shows_its_window_in_the_joint_panel_and_edits_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Dot* head;
	pose_head(&f, &head);
	f.app.select(head.id);
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	test::@check(!has_id(&f, crig::JOINT_PIN_FROM_ID), "window fields before there is a pin");

	test::@check(f.app.lock_position(head.id), "the pin would not set");
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(has_id(&f, crig::JOINT_PIN_FROM_ID) && has_id(&f, crig::JOINT_PIN_TO_ID)
		&& has_id(&f, crig::JOINT_PIN_BLEND_ID), "no From / To / Blend fields on a pinned joint");

	sz history = f.app.undo_stack.cursor;
	crig::joint_pin_from_committed(f.ui, 0.3f);
	test::@check(math::abs(f.app.clip(f.app.editing).pins[0].from - 0.3f) < 1.0e-5f, "From did not change the window");
	test::eq(f.app.undo_stack.cursor, history + 1);
	crig::joint_pin_to_committed(f.ui, 0.8f);
	crig::joint_pin_blend_committed(f.ui, 0.05f);
	crig::AnimPin pin = f.app.clip(f.app.editing).pins[0];
	test::@check(math::abs(pin.to - 0.8f) < 1.0e-5f && math::abs(pin.blend - 0.05f) < 1.0e-5f, "To / Blend did not take");
	test::eq(f.app.undo_stack.cursor, history + 3);

	// A To before From pulls From with it rather than leaving an inverted window.
	crig::joint_pin_to_committed(f.ui, 0.1f);
	pin = f.app.clip(f.app.editing).pins[0];
	test::@check(pin.from <= pin.to, "the window is inverted: %.2f..%.2f", pin.from, pin.to);
	f.app.undo();
	test::@check(math::abs(f.app.clip(f.app.editing).pins[0].to - 0.8f) < 1.0e-5f, "undo did not restore the window");
}

fn void a_pin_is_a_bar_in_a_dopesheet_lane_whose_ends_drag() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Pin", 2);
	f.app.editing = clip;
	f.app.stop_animation();
	Dot* head = f.app.dot_named("head");
	test::@check(head != null, "the biped has no head");
	f.app.select(head.id);
	f.app.stage = POSE_STAGE;
	f.app.edit_time = 0.0f;
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	usz lanes = f.ui.find(Timeline)!!.widget_as(Timeline).lanes.len;

	test::@check(f.app.set_clip_pin(head.id, true, false, 0.5f, 1.5f), "the pin would not set");
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	Timeline* sheet = f.ui.find(Timeline)!!.widget_as(Timeline);
	test::@check(sheet.lanes.len == lanes + 1, "no Pins lane (%d lanes, was %d)", sheet.lanes.len, lanes);
	if (sheet.lanes.len != lanes + 1) return;
	crig::TimelineLane lane = sheet.lanes[lanes];
	test::@check(lane.pin && lane.label == "head", "the lane is not the pin's");
	crig::TimelineBar found;
	bool has = false;
	foreach (bar : sheet.bars) if (bar.pin && bar.lane == lanes) { found = bar; has = true; }
	test::@check(has && found.from == 0.5f && found.to == 1.5f, "the bar is not the window");
	if (!has) return;

	// Dragging the right end back 0.25 s and the whole bar forward 0.1 s.
	sz history = f.app.undo_stack.cursor;
	crig::anim_pin_bar_edited(&f.app, f.app.clip(f.app.editing), found, TO, -0.25f);
	test::@check(math::abs(f.app.clip(f.app.editing).pins[0].to - 1.25f) < 1.0e-5f, "the end did not move");
	test::eq(f.app.undo_stack.cursor, history + 1);
	found.to = 1.25f;
	crig::anim_pin_bar_edited(&f.app, f.app.clip(f.app.editing), found, MOVE, 0.1f);
	crig::AnimPin pin = f.app.clip(f.app.editing).pins[0];
	test::@check(math::abs(pin.from - 0.6f) < 1.0e-5f && math::abs(pin.to - 1.35f) < 1.0e-5f,
		"the bar moved to %.2f..%.2f", pin.from, pin.to);
}

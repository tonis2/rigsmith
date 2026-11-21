<*
 The Attachment panel, raised from a joint's right-click menu: a type pick and a
 slider drag are one undo step each, and the grip is a pin of the open clip.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

fn uint fit_right_hand(Fixture* f) @local
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	Dot* wrist = f.app.dot_named("wrist_R");
	test::@check(wrist != null, "the biped has no wrist_R");
	return wrist.id;
}

// Right-click the hand, then Attachments….
fn void open_attachments(Fixture* f, uint hand) @local
{
	f.app.select(hand);
	f.app.refresh_ui();

	crig::open_viewport_context(f.ui, { 0, 0 });
	f.ui.flush();
	test::@check(has_id(f, "viewport-context-attachments"), "no Attachments… row for a joint");
	crig::scene_context_attachments(f.ui);
	frame(f);
	test::@check(f.app.attachment_dot == hand, "the panel is not on wrist_R");
	test::@check(has_id(f, crig::ATTACHMENT_KIND_ID), "Attachments… did not open the panel");
}

// One frame: the panel's update sees what changed, and the flush rebuilds it.
fn void frame(Fixture* f) @local => f.feed(f.ui.input.mouse);

fn Slider* slider_of(Fixture* f, String id) @local => f.ui.find_id(id)!!.widget_as(Slider);

// One drag: two moves, then the release.
fn void drag(Fixture* f, String id, float a, float b) @local
{
	Slider* slider = slider_of(f, id);
	slider.on_change(f.ui, a);
	slider.on_change(f.ui, b);
	slider.on_commit(f.ui, b);
	frame(f);
}

fn void the_attachment_panel_holds_and_places_a_prop() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	uint hand = fit_right_hand(&f);
	open_attachments(&f, hand);
	test::@check(!has_id(&f, crig::ATTACHMENT_OFFSET_X_ID), "offset sliders with nothing held");

	f.ui.find_id(crig::ATTACHMENT_KIND_ID)!!.widget_as(Segmented).on_change(f.ui, 1);
	frame(&f);
	HeldProp prop = f.app.doc.prop_of(hand);
	test::@check(prop.held() && prop.kind == SWORD, "Sword did not put a sword in the hand");

	float x = prop.offset.x;
	drag(&f, crig::ATTACHMENT_OFFSET_X_ID, x * 100.0f + 5.0f, x * 100.0f + 10.0f);
	test::@check(math::abs(f.app.doc.prop_of(hand).offset.x - (x + 0.1f)) < 1.0e-5f, "Offset X did not move the grip");
	test::@check(f.app.undo(), "nothing to undo");
	test::@check(math::abs(f.app.doc.prop_of(hand).offset.x - x) < 1.0e-6f, "one undo did not put the drag back");
	test::@check(f.app.doc.prop_of(hand).held(), "one undo took back more than the drag");

	// A turn drag stays where it was let go, through the rebuild after it.
	drag(&f, crig::ATTACHMENT_TURN_Y_ID, 20.0f, 40.0f);
	frame(&f);
	test::@check(math::abs(slider_of(&f, crig::ATTACHMENT_TURN_Y_ID).value - 40.0f) < 1.0e-3f, "Turn Y jumped after the rebuild");
	test::@check(math::abs(f.app.prop_angles(hand, f.app.attachment_angles).y - 40.0f) < 1.0e-3f, "the turn is not 40 degrees about Y");

	// Undone, the sliders read the old turn again, inside their range.
	test::@check(f.app.undo(), "nothing to undo after the turn");
	frame(&f);
	foreach (id : (String[]){ crig::ATTACHMENT_TURN_X_ID, crig::ATTACHMENT_TURN_Y_ID, crig::ATTACHMENT_TURN_Z_ID })
	{
		float value = slider_of(&f, id).value;
		test::@check(value >= -180.0f && value <= 180.0f, "%s reads %f, past the slider", id, value);
	}
	Vec3 shown = { slider_of(&f, crig::ATTACHMENT_TURN_X_ID).value, slider_of(&f, crig::ATTACHMENT_TURN_Y_ID).value,
		slider_of(&f, crig::ATTACHMENT_TURN_Z_ID).value };
	test::@check(math::abs(crig::quat_of_euler(shown).v.dot(f.app.doc.prop_of(hand).turn.v)) > 0.99999f,
		"the sliders don't read the turn the undo put back");

	// Another type keeps the placement; Reset puts it back where a new one sits.
	HeldProp turned = f.app.doc.prop_of(hand);
	f.ui.find_id(crig::ATTACHMENT_KIND_ID)!!.widget_as(Segmented).on_change(f.ui, 3);
	frame(&f);
	HeldProp staff = f.app.doc.prop_of(hand);
	test::@check(staff.kind == STAFF && staff.offset == turned.offset && staff.turn.v == turned.turn.v,
		"Staff did not keep the placement");
	crig::attachment_reset_pressed(f.ui);
	frame(&f);
	HeldProp reset = f.app.doc.prop_of(hand);
	test::@check(reset.kind == STAFF && reset.length == staff.length, "Reset changed the type or the length");
	test::@check(reset.offset == prop.offset && math::abs(reset.turn.v.dot(prop.turn.v)) > 0.99999f,
		"Reset did not put the staff where a new one sits");

	f.ui.find_id(crig::ATTACHMENT_KIND_ID)!!.widget_as(Segmented).on_change(f.ui, 0);
	frame(&f);
	test::@check(!f.app.doc.prop_of(hand).held(), "None did not take the sword away");
	test::@check(!has_id(&f, crig::ATTACHMENT_OFFSET_X_ID), "offset sliders after None");
}

fn void the_attachment_panel_grips_with_the_other_hand() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	uint hand = fit_right_hand(&f);
	AnimRef clip = f.app.new_clip("Swing", 1);
	f.app.editing = clip;
	f.app.stop_animation();
	test::@check(f.app.hold_prop(hand, SWORD), "the sword was not put in the hand");
	open_attachments(&f, hand);

	uint support = f.app.dot_named("wrist_L").id;
	test::@check(f.app.attachment_support == support, "the grip does not offer the twin first");
	test::@check(has_id(&f, crig::ATTACHMENT_GRIP_ID), "no Grip with a clip open");
	crig::attachment_grip_pressed(f.ui);
	frame(&f);
	test::@check(f.app.gripped_on(support) == hand, "Grip did not hold wrist_L on the sword hand");
	test::@check(has_id(&f, crig::ATTACHMENT_RELEASE_ID), "no Release once gripped");

	crig::attachment_release_pressed(f.ui);
	frame(&f);
	test::@check(f.app.gripped_on(support) == 0, "Release did not let go");

	// Its joint deleted, the panel closes itself.
	f.app.select(hand);
	(void)f.app.remove_selection();
	f.app.refresh_ui();
	frame(&f);
	test::@check(f.app.attachment_dot == 0, "the panel stayed up on a deleted joint");
	test::@check(!has_id(&f, crig::ATTACHMENT_KIND_ID), "the panel's controls outlived its joint");
}

// The lasso on Pose, where an animation is always on show.
module crig_tests::ui;

import crig;
import cui;
import std::core::test;
import std::math::vector;

<*
 On Pose the lasso opens, says so, and selects the posed joints it is drawn
 around; its next step pins vertices on the posed body, where it used to be
 refused with "finish animation editing first".
*>
fn void the_lasso_selects_and_pins_on_pose() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Pose", 2);
	f.app.editing = clip;
	f.app.stage = POSE_STAGE;
	(void)f.app.park_clip(clip, 0.0f);
	f.app.refresh_ui();
	f.feed(VIEWPORT_CENTER);
	test::@check(f.app.rig_locked(), "a parked clip should hold the rest rig");

	Element* cell = f.ui.find_id("tools")!!.children[0].children[4];
	f.click(cell.absolute + cell.size * 0.5f);
	test::@check(f.app.lassoing && f.app.lasso_job == crig::LassoJob.SELECT, "the lasso cell did not open the lasso on Pose");
	test::@check(f.app.notice().contains("Lasso select"), "opening the lasso said nothing: %s", f.app.notice());

	Vec2 c = VIEWPORT_CENTER;
	f.feed(c + (Vec2){ -300, -250 });
	f.feed(c + (Vec2){ -300, -250 }, left: true);
	f.feed(c + (Vec2){ 300, -250 }, left: true);
	f.feed(c + (Vec2){ 300, 250 }, left: true);
	f.feed(c + (Vec2){ -300, 250 }, left: true);
	f.feed(c + (Vec2){ -300, 250 });
	test::@check(f.app.selection_count() > 1, "a lasso around the posed body selected %d joints", f.app.selection_count());

	f.ui.flush();
	f.feed(VIEWPORT_CENTER);
	cell = f.ui.find_id("tools")!!.children[0].children[4];
	f.click(cell.absolute + cell.size * 0.5f);
	test::@check(f.app.lassoing && f.app.lasso_job == crig::LassoJob.PIN, "the lasso would not step onto pinning on Pose");
	test::@check(f.app.notice().contains("Lasso pin"), "the step onto pinning said nothing: %s", f.app.notice());

	// A loop around the posed body pins vertices to the selected joint.
	sz pins = f.app.doc.pins.len();
	f.feed(c + (Vec2){ -300, -250 });
	f.feed(c + (Vec2){ -300, -250 }, left: true);
	f.feed(c + (Vec2){ 300, -250 }, left: true);
	f.feed(c + (Vec2){ 300, 250 }, left: true);
	f.feed(c + (Vec2){ -300, 250 }, left: true);
	f.feed(c + (Vec2){ -300, 250 });
	test::@check(f.app.doc.pins.len() > pins, "a loop around the posed body pinned nothing: %s", f.app.notice());
	f.app.end_lasso();
}

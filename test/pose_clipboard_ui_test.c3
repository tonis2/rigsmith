<*
 The pose clipboard as the keys and buttons reach it.

 Two clipboards share Ctrl+C/V and are told apart by focus: the dopesheet
 consumes the chord for saved keys, the root answers it for the pose when
 nothing nearer claimed it. These checks drive both routes through the same
 input path a person does, and the key toolbar's pose buttons through their ids.
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;
import std::math::quaternion;

const String POSE_LEFT = "thigh_L";
const String POSE_RIGHT = "thigh_R";

// The left thigh turned about Z at 0 s, everything else at rest at 0 s and 2 s,
// parked at the start with the thigh selected and the Animations tab up. The
// tab click is what puts keyboard focus on the root: nothing nearer holds it,
// so a chord reaches the viewport's clipboard.
fn uint pose_clipboard_workspace(Fixture* f, Quaternionf turn)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	uint left;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == POSE_LEFT) left = dot.id;
	test::@check(left != 0, "the fitted plan has no %s", POSE_LEFT);
	AnimRef clip = f.app.new_clip("Posed", 2, from_rest: true);
	f.app.editing = clip;
	test::@check(f.app.pose_from_clip(clip, 0) && f.app.set_working_pose(left, turn, {}),
		"the thigh would not turn");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "the thigh would not key");
	f.app.editing = f.app.key_here(f.app.editing, 2);
	f.app.edit_time = 0;
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	f.app.select(left);
	f.app.undo_stack.clear();
	return left;
}

fn Vec3 pose_turn(Fixture* f, String joint, float time)
{
	AnimKeyDot dot = f.app.clip(f.app.editing).entry_at(joint, time);
	return dot.axis.normalize() * dot.angle;
}

fn Vec3 pose_turn_of(Quaternionf q)
{
	Vec3 axis;
	float angle;
	crig::axis_angle_of(q, &axis, &angle);
	return axis * angle;
}

fn void pose_clipboard_ui_viewport_chords_copy_paste_and_flip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.4f);
	pose_clipboard_workspace(&f, turn);

	f.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.C);
	test::eq(f.app.anim_pose_clipboard.dots.len, (sz)1);
	test::eq(f.app.anim_key_clipboard.keyframes.len, (sz)0);
	test::@check(f.app.anim_pose_clipboard.dots[0].joint_name == POSE_LEFT, "the chord copied the wrong joint");

	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.scrub_to(1), "the parked clip would not scrub");
	// Halfway between the turned key and the rest key: what undo has to restore.
	Vec3 between = pose_turn(&f, POSE_LEFT, 1);
	f.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.V);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check((pose_turn(&f, POSE_LEFT, 1) - pose_turn_of(turn)).length() < 1.0e-4f,
		"Ctrl+V did not key the copied turn at the playhead");
	test::@check(pose_turn(&f, POSE_RIGHT, 1).length() < 1.0e-6f, "a plain paste touched the other leg");

	// Shift on the same chord: the twin, reflected.
	Key[2] held = { Key.LEFT_CTRL, Key.LEFT_SHIFT };
	Key[3] all = { Key.LEFT_CTRL, Key.LEFT_SHIFT, Key.V };
	f.feed(VIEWPORT_CENTER, keys: held[..]);
	f.feed(VIEWPORT_CENTER, keys: all[..]);
	f.feed(VIEWPORT_CENTER, keys: held[..]);
	f.feed(VIEWPORT_CENTER);
	test::eq(f.app.undo_stack.cursor, history + 2);
	Vec3 want = pose_turn_of(turn);
	want = { want.x, -want.y, -want.z };
	test::@check((pose_turn(&f, POSE_RIGHT, 1) - want).length() < 1.0e-4f,
		"Ctrl+Shift+V did not put the reflection on the right leg");

	test::@check(f.app.undo() && pose_turn(&f, POSE_RIGHT, 1).length() < 1.0e-6f,
		"the mirrored paste did not undo as one edit");
	test::@check(f.app.undo() && (pose_turn(&f, POSE_LEFT, 1) - between).length() < 1.0e-6f,
		"the paste did not undo as one edit");
}

fn void pose_clipboard_ui_timeline_focus_keeps_the_key_clipboard() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.4f);
	pose_clipboard_workspace(&f, turn);

	f.chord(VIEWPORT_CENTER, Key.LEFT_CTRL, Key.C);
	test::eq(f.app.anim_pose_clipboard.dots.len, (sz)1);

	// Click a saved pose in the sheet: focus moves to the dopesheet, and the
	// same chord now copies keys — and leaves the pose in hand alone.
	Vec2 mark = multi_pose_point(&f, 0);
	f.click(mark);
	f.feed(mark, keys: { Key.LEFT_CTRL, Key.C });
	f.feed(mark);
	test::eq(f.app.anim_key_clipboard.keyframes.len, (sz)1);
	test::eq(f.app.anim_pose_clipboard.dots.len, (sz)1);
}

fn void pose_clipboard_ui_toolbar_buttons_copy_and_mirror() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.4f);
	pose_clipboard_workspace(&f, turn);

	f.open_pose_tab();
	f.click(f.center_of(crig::ANIM_COPY_POSE_ID)!!);
	test::eq(f.app.anim_pose_clipboard.dots.len, (sz)1);

	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_MIRROR_POSE_ID)!!);
	test::eq(f.app.undo_stack.cursor, history + 1);
	Vec3 want = pose_turn_of(turn);
	want = { want.x, -want.y, -want.z };
	test::@check((pose_turn(&f, POSE_RIGHT, 0) - want).length() < 1.0e-4f,
		"Mirror pose did not put the reflection on the right leg");
	test::@check((pose_turn(&f, POSE_LEFT, 0) - pose_turn_of(turn)).length() < 1.0e-4f,
		"Mirror pose with one side selected rewrote that side");

	// Paste mirrored at the far key, from the clipboard the first button filled.
	test::@check(f.app.scrub_to(2), "the parked clip would not scrub");
	f.click(f.center_of(crig::ANIM_PASTE_MIRRORED_ID)!!);
	test::eq(f.app.undo_stack.cursor, history + 2);
	test::@check((pose_turn(&f, POSE_RIGHT, 2) - want).length() < 1.0e-4f,
		"Paste mirrored did not land the reflection at 2 s");
	f.click(f.center_of(crig::ANIM_PASTE_POSE_ID)!!);
	test::eq(f.app.undo_stack.cursor, history + 3);
	test::@check((pose_turn(&f, POSE_LEFT, 2) - pose_turn_of(turn)).length() < 1.0e-4f,
		"Paste pose did not land the copied turn at 2 s");
}

<*
 Shift+M over the viewport mirrors the pose; plain M is the rest rig's mirror,
 and under a posed body it mirrors the rest rig rather than the pose.

 Two reflections across one plane, told apart by the shift rather than by
 which workspace is up — the state that decided it before is one nothing on
 screen names, so a person posing the left leg pressed M, got the rig's
 "nothing to mirror", and could not tell which of the two had run. The rig's
 mirror runs under a parked clip like every other rest edit now; the fixture's
 rig is already symmetric, so what it has to show is that the pose was left
 alone.
*>
fn void pose_clipboard_ui_shift_m_mirrors_the_pose_and_m_leaves_it() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.4f);
	pose_clipboard_workspace(&f, turn);

	sz history = f.app.undo_stack.cursor;
	sz dots = f.app.doc.dots.len();
	test::@check(f.app.rig_locked(), "the parked clip should lock the rest rig");

	// Plain M: the rig's mirror, which finds the other side already in place
	// and says so — and never reads as the pose's.
	f.tap(VIEWPORT_CENTER, Key.M);
	test::eq(f.app.undo_stack.cursor, history);
	test::eq(f.app.doc.dots.len(), dots);
	test::@check(f.notice_text().starts_with("already mirrored"), "M under a posed body reads \"%s\"", f.notice_text());
	test::@check(f.app.animating && f.app.anim_paused, "M took the clip down");
	test::@check(pose_turn(&f, POSE_RIGHT, 0).length() < 1.0e-6f, "M touched the pose");

	f.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.M);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(f.app.doc.dots.len(), dots);
	Vec3 want = pose_turn_of(turn);
	want = { want.x, -want.y, -want.z };
	test::@check((pose_turn(&f, POSE_RIGHT, 0) - want).length() < 1.0e-4f,
		"Shift+M did not put the reflection on the right leg");
	test::@check((pose_turn(&f, POSE_LEFT, 0) - pose_turn_of(turn)).length() < 1.0e-4f,
		"Shift+M with one side selected rewrote that side");
	test::@check(f.notice_text().starts_with("Mirrored the pose"), "the notice reads \"%s\"", f.notice_text());
	test::@check(f.app.undo() && pose_turn(&f, POSE_RIGHT, 0).length() < 1.0e-6f,
		"the mirrored pose did not undo as one edit");

	// Nothing selected: the whole pose, as the button does — not an unclaimed key.
	f.app.select(0);
	f.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.M);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check((pose_turn(&f, POSE_RIGHT, 0) - want).length() < 1.0e-4f
		&& pose_turn(&f, POSE_LEFT, 0).length() < 1.0e-6f,
		"a whole-pose mirror should trade the two sides");
	f.app.undo();
}

<*
 With no clip open M is the rig's mirror, and on a rig the plan placed square
 it says so rather than "nothing to mirror". Shift+M there has no pose to
 mirror and says that instead of touching the dots.
*>
fn void rig_mirror_on_a_square_rig_says_so() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	sz dots = f.app.doc.dots.len();
	uint left;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == POSE_LEFT) left = dot.id;
	f.app.select(left);
	test::@check(!f.app.animation_pose_ready(), "no clip is open, so M is the rig's mirror");
	sz history = f.app.undo_stack.cursor;
	f.tap(VIEWPORT_CENTER, Key.M);
	test::@check(f.notice_text().starts_with("already mirrored"), "the rig mirror reads \"%s\"", f.notice_text());
	test::eq(f.app.doc.dots.len(), dots);
	test::eq(f.app.undo_stack.cursor, history);

	f.chord(VIEWPORT_CENTER, Key.LEFT_SHIFT, Key.M);
	test::@check(f.notice_text().starts_with("pick an animation"), "Shift+M with no clip reads \"%s\"", f.notice_text());
	test::eq(f.app.doc.dots.len(), dots);
	test::eq(f.app.undo_stack.cursor, history);
}

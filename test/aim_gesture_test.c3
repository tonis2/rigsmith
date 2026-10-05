<*
 Pose gestures with look-at targets on: the IK and the turn solve in the aimed
 frame on screen, and what they write back is authored rotations only.

 A figure of hips and spine with two limbs off the spine: neck and head up, and
 shoulder, elbow and hand out to the side. The mesh is the shared cube and is
 never asserted on.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::aim_gesture`
*>
module crig_tests::aim_gesture;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

struct Figure
{
	crig::AppState app;
	uint hips;
	uint spine;
	uint neck;
	uint head;
	uint shoulder;
	uint elbow;
	uint hand;
}

fn bool Figure.open(&self)
{
	self.app = shared_app::open_cube();
	shared_app::attach_library(&self.app);

	self.hips = self.app.doc.add_dot({ 0, 1.0, 0 }, "hips");
	self.spine = self.app.doc.add_dot({ 0, 1.3, 0 }, "spine");
	self.neck = self.app.doc.add_dot({ 0, 1.6, 0 }, "neck");
	self.head = self.app.doc.add_dot({ 0, 1.7, 0 }, "head");
	self.shoulder = self.app.doc.add_dot({ 0.2, 1.5, 0 }, "shoulder_L");
	self.elbow = self.app.doc.add_dot({ 0.5, 1.5, 0 }, "elbow_L");
	self.hand = self.app.doc.add_dot({ 0.8, 1.5, 0 }, "hand_L");
	self.app.doc.connect(self.hips, self.spine);
	self.app.doc.connect(self.spine, self.neck);
	self.app.doc.connect(self.neck, self.head);
	self.app.doc.connect(self.spine, self.shoulder);
	self.app.doc.connect(self.shoulder, self.elbow);
	self.app.doc.connect(self.elbow, self.hand);
	self.app.doc.root_id = self.hips;

	crig::AnimRef clip = self.app.new_clip("look", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.5f;
	self.app.auto_key = false;
	return true;
}

fn void Figure.close(&self) => self.app.free();

fn float Figure.height(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	return view.skeleton.height();
}

fn Vec3 Figure.at(&self, uint id) => self.app.dot_position(*self.app.doc.find(id));

fn crig::AnimTemplate* Figure.clip(&self) => self.app.clip(self.app.editing);

// A spread-3 target for the head, dragged well to the side so the spine carries
// part of the turn. Returns where it was put, in model units.
fn Vec3 Figure.aim_head_aside(&self)
{
	crig::AppState* app = &self.app;
	if (!app.add_aim(self.head) || !app.set_aim_spread(self.head, 3)) return {};
	Vec3 start = app.posed_aims[0].at;
	if (!app.begin_aim_drag(0, true)) return {};
	Vec3 moved = start + (Vec3){ 0.7f, 0.1f, -0.2f };
	app.aim_target_toward(moved);
	app.end_drag();
	return moved;
}

// 1 - cos of the angle between where the aimed head faces on screen and the
// direction from the head to `target`; 0 when it faces it.
fn float Figure.facing_error(&self, Vec3 target)
{
	crig::AppState* app = &self.app;
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.draft_pose(mem, &view);
	defer pose.free(mem);
	crig::AnimTemplate* clip = self.clip();
	app.apply_clip_aims(&view, *clip, app.editing, app.edit_time, &pose);
	Vec3 position;
	Quaternionf world;
	usz joint = (usz)view.joint_of(self.head);
	if (!crig::aim_frame(&view, pose, joint, &position, &world)) return 1.0f;
	Vec3 facing = world.rotate_vec3(clip.aims[0].forward).normalize();
	return 1.0f - facing.dot((target - position).normalize());
}

// Whether the draft holds exactly the rotation and offset the joint had in `was`.
fn bool Figure.same_as(&self, uint id, crig::PosedJoint was)
{
	crig::PosedJoint now = self.app.working_pose(id);
	return now.rotation.v == was.rotation.v && now.offset == was.offset;
}

<*
 A G drag on the hand reaches the pointer with the head's spread-3 target on, and
 the spine, neck and head stay authored: only the arm is written.
*>
fn void a_hand_drag_reaches_the_pointer_and_leaves_the_aimed_joints_authored() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	Vec3 aim_at = fixture.aim_head_aside();
	test::@check(fixture.facing_error(aim_at) < 1.0e-3f, "the head does not face the target before the gesture");

	crig::PosedJoint spine = app.working_pose(fixture.spine);
	crig::PosedJoint neck = app.working_pose(fixture.neck);
	crig::PosedJoint head = app.working_pose(fixture.head);
	test::@check(spine.rotation.v == quaternion::IDENTITY{float}.v, "the aim leaked into the draft before the gesture");

	app.selected = fixture.hand;
	test::@check(app.begin_pose(true), "G did not begin on the hand");
	Vec3 from = fixture.at(fixture.hand);
	Vec3 target = from + (Vec3){ -0.15f, -0.25f, 0.2f };
	float gap;
	for (int k = 1; k <= 8; k++) gap = app.pose_toward(from + (target - from) * (k / 8.0f));
	float reach = math::abs(fixture.height()) * crig::IK_TOLERANCE;
	test::@check((fixture.at(fixture.hand) - target).length() <= reach * 2.0f,
		"the hand missed the pointer by %f (gap %f)", (fixture.at(fixture.hand) - target).length(), gap);

	test::@check(fixture.same_as(fixture.spine, spine), "the spine's draft changed");
	test::@check(fixture.same_as(fixture.neck, neck), "the neck's draft changed");
	test::@check(fixture.same_as(fixture.head, head), "the head's draft changed");
	crig::PosedJoint elbow = app.working_pose(fixture.elbow);
	crig::PosedJoint shoulder = app.working_pose(fixture.shoulder);
	test::@check(elbow.rotation.v != quaternion::IDENTITY{float}.v || shoulder.rotation.v != quaternion::IDENTITY{float}.v, "the arm was not turned");

	app.end_drag();
	test::@check(fixture.facing_error(aim_at) < 1.0e-3f, "the head lost the target after the gesture");
	test::@check(app.gesture_aim.joints.len == 0 && app.gesture_aimed.len == 0, "the gesture kept its aim record");
}

<*
 R on the aimed head: the head still faces the target afterwards, the swing being
 the aim's, and the user was told so.
*>
fn void turning_an_aimed_head_keeps_it_on_the_target() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	Vec3 aim_at = fixture.aim_head_aside();
	crig::PosedJoint spine = app.working_pose(fixture.spine);

	app.selected = fixture.head;
	test::@check(app.begin_turn(true), "R did not begin on the head");
	app.turn_joint({ 0, 1, 0 }, 0.6f);
	test::@check(fixture.facing_error(aim_at) < 1.0e-3f, "the head left the target mid-turn");
	test::@check(fixture.same_as(fixture.spine, spine), "turning the head wrote the spine");
	test::@check(!fixture.same_as(fixture.head, { .dot_id = fixture.head, .rotation = quaternion::IDENTITY{float} }), "the turn wrote nothing");
	app.turn_joint({ 0, 1, 0 }, 0.0f);
	app.end_drag();
	test::@check(fixture.facing_error(aim_at) < 1.0e-3f, "the head left the target after the turn");
	test::@check(app.gesture_aim.joints.len == 0, "the turn kept its aim record");
}

<*
 A rotation pin is refused on an aimed joint, a position pin is not, and adding a
 target drops a rotation pin the joint already had.
*>
fn void a_rotation_pin_is_refused_on_an_aimed_joint() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.set_anchor(fixture.neck, false, true);
	test::@check(app.locks_rotation(fixture.neck), "the neck's rotation pin was not set");
	test::@check(app.add_aim(fixture.head), "the target was not added");
	test::@check(app.add_aim(fixture.neck), "the neck's target was not added");
	test::@check(!app.locks_rotation(fixture.neck), "the target left a rotation pin on its joint");

	app.set_anchor(fixture.head, false, true);
	test::@check(!app.locks_rotation(fixture.head), "a rotation pin was set on the aimed head");
	test::@check(!app.toggle_rotation_anchor(fixture.head), "toggling reported a pin on the aimed head");
	app.set_anchor(fixture.head, true, true);
	test::@check(app.locks_position(fixture.head) && !app.locks_rotation(fixture.head), "the position half was not kept");
	test::@check(!app.is_anchored(fixture.hand), "an unrelated joint is anchored");
	app.set_anchor(fixture.hand, false, true);
	test::@check(app.locks_rotation(fixture.hand), "an unaimed joint refused its rotation pin");
}

<*
 Esc in the middle of a hand drag with targets on puts every joint of the draft
 back exactly, and leaves nothing pending.
*>
fn void escape_during_a_gesture_with_aims_leaves_the_draft_unchanged() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	Vec3 aim_at = fixture.aim_head_aside();

	uint[7] ids = { fixture.hips, fixture.spine, fixture.neck, fixture.head, fixture.shoulder, fixture.elbow, fixture.hand };
	crig::PosedJoint[7] before;
	foreach (i, id : ids) before[i] = app.working_pose(id);
	bool pending = app.pose_edit_pending;

	app.selected = fixture.hand;
	test::@check(app.begin_pose(true), "G did not begin on the hand");
	Vec3 from = fixture.at(fixture.hand);
	app.pose_toward(from + (Vec3){ -0.2f, -0.2f, 0.1f });
	app.pose_toward(from + (Vec3){ -0.25f, -0.3f, 0.1f });
	test::@check(app.cancel_drag(), "Esc did not cancel");

	foreach (i, id : ids) test::@check(fixture.same_as(id, before[i]), "Esc left joint %d changed", i);
	test::@check(app.pose_edit_pending == pending, "Esc changed the pending flag");
	test::@check(fixture.facing_error(aim_at) < 1.0e-3f, "the head lost the target after Esc");
	test::@check(app.gesture_aim.joints.len == 0, "Esc kept the aim record");
}

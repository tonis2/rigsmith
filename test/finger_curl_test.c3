<*
 Dragging a fingertip curls the finger: the bend is shared along its joints
 instead of all of it turning at the knuckle, and a limb's drag is as it was.

 A hip, a spine and an arm, whose hand forks into two three-joint fingers six
 centimetres long, pointing along +X. The mesh is the shared cube and is never asserted on.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::finger_curl`
*>
module crig_tests::finger_curl;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

struct Hand
{
	crig::AppState app;
	uint elbow;
	uint hand;
	uint[4] index;
}

fn bool Hand.open(&self)
{
	self.app = shared_app::open_cube();
	shared_app::attach_library(&self.app);

	uint hips = self.app.doc.add_dot({ 0, 1.0, 0 }, "hips");
	uint spine = self.app.doc.add_dot({ 0, 1.3, 0 }, "spine");
	uint shoulder = self.app.doc.add_dot({ 0.2, 1.5, 0 }, "shoulder_L");
	self.elbow = self.app.doc.add_dot({ 0.5, 1.5, 0 }, "elbow_L");
	self.hand = self.app.doc.add_dot({ 0.8, 1.5, 0 }, "hand_L");
	uint head = self.app.doc.add_dot({ 0, 1.8, 0 }, "head");
	self.app.doc.connect(hips, spine);
	self.app.doc.connect(spine, head);
	self.app.doc.connect(spine, shoulder);
	self.app.doc.connect(shoulder, self.elbow);
	self.app.doc.connect(self.elbow, self.hand);
	self.app.doc.root_id = hips;

	uint[4] middle;
	foreach (i, name : (String[4]){ "index_1_L", "index_2_L", "index_3_L", "index_4_L" })
	{
		self.index[i] = self.app.doc.add_dot({ 0.85f + 0.02f * (float)i, 1.5f, 0.01f }, name);
		self.app.doc.connect(i == 0 ? self.hand : self.index[i - 1], self.index[i]);
	}
	foreach (i, name : (String[4]){ "middle_1_L", "middle_2_L", "middle_3_L", "middle_4_L" })
	{
		middle[i] = self.app.doc.add_dot({ 0.85f + 0.02f * (float)i, 1.5f, -0.01f }, name);
		self.app.doc.connect(i == 0 ? self.hand : middle[i - 1], middle[i]);
	}

	crig::AnimRef clip = self.app.new_clip("curl", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.5f;
	self.app.auto_key = false;
	return true;
}

fn void Hand.close(&self) => self.app.free();

fn Vec3 Hand.at(&self, uint id) => self.app.dot_position(*self.app.doc.find(id));

// How far a joint's draft turn is from none, in radians.
fn float Hand.bend(&self, uint id)
{
	crig::PosedJoint pose = self.app.working_pose(id);
	return 2.0f * (float)math::acos((double)math::min(1.0f, math::abs(pose.rotation.v[3])));
}

<*
 Pulling the tip of a straight finger straight down: every joint along the finger
 bends, none takes less than a fifth of the total turn, and the tip comes down.
*>
fn void a_fingertip_drag_curls_every_joint() @test
{
	Hand hand;
	test::@check(hand.open(), "the fixture did not open");
	defer hand.close();
	crig::AppState* app = &hand.app;

	app.selected = hand.index[3];
	test::@check(app.begin_pose(true), "G did not begin on the fingertip");
	Vec3 from = hand.at(hand.index[3]);
	Vec3 target = from + (Vec3){ 0, -0.02f, 0 };
	for (int k = 1; k <= 8; k++) (void)app.pose_toward(from + (target - from) * (k / 8.0f));

	float[3] bends = { hand.bend(hand.index[0]), hand.bend(hand.index[1]), hand.bend(hand.index[2]) };
	float total = bends[0] + bends[1] + bends[2];
	test::@check(total > 0.2f, "the finger barely bent (%f rad)", (double)total);
	foreach (i, bend : bends)
	{
		test::@check(bend > total * 0.2f, "finger joint %d took only %f of %f rad", i, (double)bend, (double)total);
	}
	test::@check(from.y - hand.at(hand.index[3]).y > 0.012f, "the tip came down only %f", (double)(from.y - hand.at(hand.index[3]).y));
	app.end_drag();
}

<*
 The same drag on the hand, whose run is the whole arm, keeps its old
 behaviour: it reaches the pointer, the way a limb does.
*>
fn void a_hand_drag_still_reaches_the_pointer() @test
{
	Hand hand;
	test::@check(hand.open(), "the fixture did not open");
	defer hand.close();
	crig::AppState* app = &hand.app;

	app.selected = hand.hand;
	test::@check(app.begin_pose(true), "G did not begin on the hand");
	Vec3 from = hand.at(hand.hand);
	Vec3 target = from + (Vec3){ -0.1f, -0.2f, 0.1f };
	for (int k = 1; k <= 8; k++) (void)app.pose_toward(from + (target - from) * (k / 8.0f));
	test::@check((hand.at(hand.hand) - target).length() < 0.01f,
		"the hand missed the pointer by %f", (double)(hand.at(hand.hand) - target).length());
	app.end_drag();
}

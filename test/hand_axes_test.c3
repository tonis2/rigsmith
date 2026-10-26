<*
 A digit's limit axes come from its hand (`core/joint_limits.c3`
 `knuckle_line`, `along_the_knuckles`): X runs along the line across the
 knuckles, so X bends every finger and the thumb toward the palm however each
 one leans. Also Use bone axes (`limits_on_bone_axes`), which carries a table
 pinned to axes of its own onto them, and the pin an older session's finger
 tables get on load.

     `c3c test --test-filter crig_tests::hand_axes`
*>
module crig_tests::hand_axes;

import crig;
import rig;
import std::core::test;
import std::io;
import std::math;

const String HUMANOID = "assets/animations/humanoid.glb";

// Within this of the knuckle line, as a cosine: the hand rule's own keep of
// fifteen degrees, and a degree to spare.
const float ALONG_THE_HAND = 0.96f;

const String[5] DIGIT_NAMES = { "thumb", "index", "middle", "ring", "pinky" };

// Where each digit leaves the wrist, held out along +X with the palm down: the
// four knuckles in a line across Z, the thumb nearer the wrist and off the palm.
const Vec3[5] DIGIT_ROOTS = {
	{ 0.03f, -0.01f, 0.03f },
	{ 0.09f, 0.0f, 0.03f },
	{ 0.09f, 0.0f, 0.01f },
	{ 0.09f, 0.0f, -0.01f },
	{ 0.09f, 0.0f, -0.03f },
};

// Each digit's three bones, Zidane's: the index's first bone leans eighteen
// degrees forward, the ring's and pinky's droop past ten, the thumb splays.
const Vec3[15] DIGIT_BONES = {
	{ 0.76f, -0.41f, 0.51f }, { 0.82f, -0.49f, 0.30f }, { 0.80f, -0.50f, 0.34f },
	{ 0.95f, -0.05f, 0.31f }, { 0.97f, -0.22f, 0.10f }, { 0.97f, -0.19f, 0.15f },
	{ 0.98f, -0.15f, 0.14f }, { 0.98f, -0.19f, 0.04f }, { 0.99f, -0.13f, 0.0f },
	{ 0.98f, -0.17f, -0.02f }, { 0.96f, -0.26f, -0.06f }, { 0.98f, -0.19f, -0.03f },
	{ 0.95f, -0.32f, 0.01f }, { 0.94f, -0.32f, -0.10f }, { 0.96f, -0.24f, -0.12f },
};

struct Hand
{
	uint chest;
	uint wrist;
	uint[4][5] digits; // [digit][joint], joint 3 the tip
	Quaternionf turn;
	float side;
}

// Where an offset from the wrist lands: turned with the hand, then put on its side.
fn Vec3 Hand.place(&self, Vec3 wrist, Vec3 offset)
{
	Vec3 turned = self.turn.rotate_vec3(offset);
	return wrist + (Vec3){ turned.x * self.side, turned.y, turned.z };
}

// The line across the knuckles, as this hand holds it.
fn Vec3 Hand.across(&self)
{
	Vec3 turned = self.turn.rotate_vec3({ 0, 0, 1 });
	return { turned.x * self.side, turned.y, turned.z };
}

<*
 A body with one arm held out to `side` (+1 the left, on +X; -1 the right) and a
 Zidane-shaped hand on it, the whole arm turned by `turn` about the shoulder.
 Tall enough that a finger is a digit (`Skeleton.digits`).
*>
fn Hand add_hand(crig::RigDocument* doc, float side, Quaternionf turn, uint chest = 0)
{
	Hand hand = { .turn = turn, .side = side };
	String suffix = side > 0.0f ? "L" : "R";
	if (chest == 0)
	{
		uint hips = doc.add_dot({ 0, 0, 0 }, "hips");
		chest = doc.add_dot({ 0, 1.4f, 0 }, "chest");
		doc.connect(hips, chest);
	}
	hand.chest = chest;
	Vec3 shoulder = { 0.15f * side, 1.4f, 0 };
	uint upper = doc.add_dot(shoulder, side > 0.0f ? "shoulder_L" : "shoulder_R");
	doc.connect(chest, upper);
	uint elbow = doc.add_dot(hand.place(shoulder, { 0.25f, 0, 0 }), side > 0.0f ? "elbow_L" : "elbow_R");
	doc.connect(upper, elbow);
	Vec3 wrist = hand.place(shoulder, { 0.5f, 0, 0 });
	hand.wrist = doc.add_dot(wrist, side > 0.0f ? "wrist_L" : "wrist_R");
	doc.connect(elbow, hand.wrist);

	for (usz d = 0; d < 5; d++)
	{
		Vec3 at = DIGIT_ROOTS[d];
		uint above = hand.wrist;
		for (usz k = 0; k < 4; k++)
		{
			char[24] buffer;
			String name = string::bformat(buffer[..], "%s_%d_%s", DIGIT_NAMES[d], k + 1, suffix);
			uint joint = doc.add_dot(hand.place(shoulder, (Vec3){ 0.5f, 0, 0 } + at), name);
			doc.connect(above, joint);
			hand.digits[d][k] = joint;
			above = joint;
			if (k < 3) at += DIGIT_BONES[d * 3 + k].normalize() * (d == 0 ? 0.02f : 0.025f);
		}
	}
	return hand;
}

fn crig::JointLimitFrame frame_of(crig::RigDocument* doc, uint id)
{
	uint[] ids;
	rig::Skeleton skeleton = crig::build_skeleton(doc, mem, &ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, ids);
	}
	return crig::joint_limit_frame(&skeleton, ids, doc.rotation_limits_of(id));
}

// The knuckle line laid across a bone: the X the hand rule aims for.
fn Vec3 across_the_bone(crig::JointLimitFrame frame, Vec3 line)
{
	Vec3 y = frame.axis(Y);
	return (line - y * line.dot(y)).normalize();
}

<*
 Every digit joint's X lies along the hand's knuckle line, one sign for the
 whole hand, so X bends every finger and the thumb the same way.
*>
fn void check_hand_curls_about_x(crig::RigDocument* doc, Hand* hand, String shape)
{
	Vec3 line = hand.across();
	float sign = 0.0f;
	for (usz d = 0; d < 5; d++)
	{
		for (usz k = 0; k < 3; k++)
		{
			crig::JointLimitFrame frame = frame_of(doc, hand.digits[d][k]);
			test::@check(frame.usable(), "%s_%d has no frame", DIGIT_NAMES[d], k + 1);
			float along = frame.axis(X).dot(across_the_bone(frame, line));
			if (sign == 0.0f) sign = along < 0.0f ? -1.0f : 1.0f;
			test::@check(along * sign >= ALONG_THE_HAND,
				"%s: %s_%d's X is %s, %.1f degrees off its hand's knuckle line", shape,
				DIGIT_NAMES[d], k + 1, frame.axis(X),
				math::acos(math::min(math::abs(along), 1.0f)) * 180.0f / (float)math::PI);
		}
	}
}

<*
 A hand held out in a T-pose, its index leaning eighteen degrees forward and
 its ring and pinky drooping past the near-axis band: every finger and the
 thumb bend about X, the knuckle line.

 Re-introduce: return `frame_along(edge, direction_dot)` from
 `joint_limit_frame_by_index` without the hand step, and the index's first X
 is world Y — the finger that turned sideways on Zidane.
*>
fn void a_finger_leaning_off_the_world_axes_still_curls_about_x() @test
{
	io::printn("a finger leaning off the world axes still curls about X");
	crig::AppState app = crig::new_app({});
	defer app.free();
	Hand hand = add_hand(&app.doc, 1.0f, quaternion::IDENTITY);
	check_hand_curls_about_x(&app.doc, &hand, "T-pose");
}

<*
 The same hand on an arm turned forty degrees down and twenty forward, an
 A-pose, which no world axis lies along: one curl axis still.

 Re-introduce: drop the hand step as above, and the fingers split between the
 world axes they lean on least.
*>
fn void a_hand_turned_off_the_world_axes_keeps_one_curl_axis() @test
{
	io::printn("a hand turned off the world axes keeps one curl axis");
	crig::AppState app = crig::new_app({});
	defer app.free();
	Quaternionf down = quaternion::from_axis_angle{float}({ 0, 0, 1 }, -40.0f * (float)math::PI / 180.0f);
	Quaternionf forward = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -20.0f * (float)math::PI / 180.0f);
	Hand hand = add_hand(&app.doc, 1.0f, forward.mul(down).normalize());
	check_hand_curls_about_x(&app.doc, &hand, "A-pose");
}

<*
 Hands held out with the palms down, leaning forward and back by up to thirty
 degrees: on every one, the curl the body plan allows (negative X on the left,
 positive on the right) bends each finger toward the palm. A lean is no reason
 for the knuckle line to change sign — Steiner's hands lean ten degrees forward,
 a hair past the near-axis band, and every finger of the left bent backwards.

 Re-introduce: sign the knuckle line by `frame_along(hand)` alone in
 `knuckle_line`, and the left hand leaning twelve degrees forward curls up.
*>
fn void a_leaning_hand_still_curls_toward_its_palm() @test
{
	io::printn("a leaning hand still curls toward its palm");
	foreach (degrees : (float[]){ -30.0f, -12.0f, -5.0f, 5.0f, 12.0f, 30.0f })
	{
		crig::AppState app = crig::new_app({});
		defer app.free();
		Quaternionf lean = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -degrees * (float)math::PI / 180.0f);
		Hand left = add_hand(&app.doc, 1.0f, lean);
		Hand right = add_hand(&app.doc, -1.0f, lean, left.chest);
		foreach (hand : (Hand[]){ left, right })
		{
			for (usz d = 1; d < 5; d++)
			{
				for (usz k = 0; k < 3; k++)
				{
					// A turn of a about X takes the bone's Y toward Z * sin(a), so the
					// plan's curl moves the tip along Z * -side; the palm is below.
					crig::JointLimitFrame frame = frame_of(&app.doc, hand.digits[d][k]);
					float down = -frame.axis(Z).y * -hand.side;
					test::@check(down > 0.5f, "%s hand leaning %.0f degrees forward: %s_%d curls %s, not toward the palm",
						hand.side > 0.0f ? "the left" : "the right", degrees, DIGIT_NAMES[d], k + 1,
						frame.axis(Z) * -hand.side);
				}
			}
		}
	}
}

<*
 A finger the world axis already suits keeps it to the bit: the hand rolled six
 degrees about its own length moves the knuckle line, and the middle finger,
 held out along X, keeps the world-rolled frame it always had — so a table
 written on it, and the humanoid's, read as they did.

 Re-introduce: drop the `HAND_FRAME_KEEP` test from `along_the_knuckles`, and
 the middle finger rolls the six degrees with its hand.
*>
fn void a_finger_the_world_axis_already_suits_keeps_it_exactly() @test
{
	io::printn("a finger the world axis already suits keeps it exactly");
	crig::AppState app = crig::new_app({});
	defer app.free();
	Hand hand = add_hand(&app.doc, 1.0f,
		quaternion::from_axis_angle{float}({ 1, 0, 0 }, 6.0f * (float)math::PI / 180.0f));
	crig::JointLimitFrame frame = frame_of(&app.doc, hand.digits[2][0]);
	crig::JointLimitFrame world = crig::cardinal_limit_frame(frame);
	test::@check(math::abs(frame.rotation.v.dot(world.rotation.v)) > 0.99999f,
		"the middle finger's frame %s left the world-rolled one %s", frame.axis(X), world.axis(X));
	test::@check(math::abs(frame.axis(X).dot(across_the_bone(frame, hand.across()))) >= ALONG_THE_HAND,
		"the kept frame is not within the hand's keep of its knuckle line");
}

<*
 A left finger's table mirrors onto the right one as a derived table: the two
 hands' frames are reflections, so the curl the left allows the right allows
 reflected, and what the left holds back the right does too.

 A guard on the mirror's contract more than on one line: the mirror carries a
 derived table across only when the twin's derived frame is the source's
 reflected, up to a sign per axis (`reflection_signs_between`), and pins a
 reflected frame on the twin otherwise. The hand rule is all geometry, so a
 hand and its reflection roll alike, and the sign it gives the knuckle line
 is one the mirror reads off the frames; what this catches is a later rule
 that rolls one hand by something the other does not have.
*>
fn void the_left_hands_finger_limits_mirror_onto_the_right_as_derived() @test
{
	io::printn("the left hand's finger limits mirror onto the right as derived");
	crig::AppState app = crig::new_app({});
	defer app.free();
	crig::RigDocument* doc = &app.doc;
	Hand left = add_hand(doc, 1.0f, quaternion::IDENTITY);
	Hand right = add_hand(doc, -1.0f, quaternion::IDENTITY, left.chest);

	foreach (usz d, digit : DIGIT_NAMES)
	{
		uint source = left.digits[d][0];
		crig::JointRotationLimits limits = crig::unconstrained_rotation(source);
		limits.constrained = true;
		limits.axes[0] = { .allowed = true, .minimum = -1.5f, .maximum = 0.3f };
		limits.axes[1] = { .allowed = false };
		limits.axes[2] = { .allowed = true, .minimum = -0.2f, .maximum = 0.35f };
		test::@check(doc.set_rotation_limits(source, limits), "the %s table did not land", digit);

		uint[] ids;
		rig::Skeleton skeleton = crig::build_skeleton(doc, mem, &ids)!!;
		defer
		{
			skeleton.free(mem);
			alloc::free(mem, ids);
		}
		crig::JointRotationLimits mirrored;
		test::@check(crig::mirrored_rotation_limits(&skeleton, ids, limits, right.digits[d][0], 0, &mirrored),
			"the %s table did not mirror", digit);
		test::@check(!mirrored.has_saved_frame, "the right %s's table was pinned to a reflected frame", digit);

		crig::JointLimitFrame here = crig::joint_limit_frame(&skeleton, ids, limits);
		crig::JointLimitFrame there = crig::joint_limit_frame(&skeleton, ids, mirrored);
		Vec3[3] turns = { { -1.2f, 0, 0.3f }, { 0.25f, 0, -0.15f }, { 0.9f, 0, 0.5f } };
		foreach (angles : turns)
		{
			Quaternionf turn = crig::rotation_from_joint_angles(here, angles);
			Quaternionf held = crig::constrain_joint_rotation(here, limits, turn);
			Quaternionf reflected = crig::constrain_joint_rotation(there, mirrored, crig::reflected_rotation(turn));
			test::@check(math::abs(crig::reflected_rotation(held).v.dot(reflected.v)) > 0.9999f,
				"the right %s held %s where the left held its reflection", digit, angles);
		}
	}
}

// What a table lets a joint do, sampled: each turn clamped by `limits` on `frame`.
fn void check_same_clamps(crig::JointLimitFrame was, crig::JointRotationLimits before,
	crig::JointLimitFrame now, crig::JointRotationLimits after, String label)
{
	float[5] swings = { -1.4f, -0.4f, 0.0f, 0.3f, 1.1f };
	float[3] twists = { -0.3f, 0.0f, 0.45f };
	foreach (x : swings)
	{
		foreach (y : twists)
		{
			foreach (z : swings)
			{
				Quaternionf turn = crig::rotation_from_joint_angles(was, { x, y, z });
				Quaternionf a = crig::constrain_joint_rotation(was, before, turn);
				Quaternionf b = crig::constrain_joint_rotation(now, after, turn);
				test::@check(math::abs(a.v.dot(b.v)) > 0.9999f,
					"%s: (%.2f, %.2f, %.2f) clamps to another turn on the bone's axes", label, x, y, z);
			}
		}
	}
}

<*
 Use bone axes carries a table saved a quarter, a half and three quarters of a
 turn off its bone's axes onto them, and the joint allows exactly what it did;
 a roll past a quarter by ten degrees reads as the quarter. One step, which an
 undo takes back to the saved frame.

 Re-introduce: trade the rows the other way round in `limits_rolled_onto`
 (new X the old Z negated at a quarter turn), and the clamps disagree.
*>
fn void using_the_bones_axes_keeps_what_the_table_allows() @test
{
	io::printn("using the bone's axes keeps what the table allows");
	crig::AppState app = crig::new_app({});
	defer app.free();
	Hand hand = add_hand(&app.doc, 1.0f, quaternion::IDENTITY);
	uint joint = hand.digits[1][1];

	crig::JointRotationLimits table = crig::unconstrained_rotation(joint);
	table.constrained = true;
	table.axes[0] = { .allowed = true, .minimum = -1.2f, .maximum = 0.2f };
	table.axes[1] = { .allowed = false, .locked = 0.1f };
	table.axes[2] = { .allowed = true, .minimum = -0.3f, .maximum = 0.4f };
	crig::JointLimitFrame derived = frame_of(&app.doc, joint);

	JointAxisLimit[3] quarter;
	foreach (usz q, degrees : (float[]){ 90.0f, 180.0f, 270.0f, 100.0f })
	{
		crig::JointRotationLimits saved = table;
		saved.has_saved_frame = true;
		saved.saved_frame = derived.rotation.mul(quaternion::from_axis_angle{float}({ 0, 1, 0 },
			degrees * (float)math::PI / 180.0f)).normalize();
		test::@check(app.set_rotation_limits_recorded(joint, saved), "the saved table did not land");
		app.undo_stack.commit();
		crig::JointLimitFrame was = frame_of(&app.doc, joint);

		test::@check(app.use_bone_axes_recorded(joint), "Use bone axes did nothing at %.0f degrees", degrees);
		app.undo_stack.commit();
		crig::JointRotationLimits after = app.doc.rotation_limits_of(joint);
		test::@check(!after.has_saved_frame, "the frame stayed saved at %.0f degrees", degrees);
		crig::JointLimitFrame now = frame_of(&app.doc, joint);
		test::@check(math::abs(now.rotation.v.dot(derived.rotation.v)) > 0.99999f,
			"the table is not on the bone's axes at %.0f degrees", degrees);
		test::@check(after.axes[1].same(table.axes[1]), "the twist row moved at %.0f degrees", degrees);

		if (degrees == 90.0f) quarter = after.axes;
		if (degrees == 100.0f)
		{
			for (usz a = 0; a < 3; a++)
			{
				test::@check(after.axes[a].same(quarter[a]), "a roll of 100 degrees read as another than the quarter");
			}
		}
		else
		{
			char[24] buffer;
			check_same_clamps(was, saved, now, after, string::bformat(buffer[..], "%.0f degrees", degrees));
		}

		test::@check(app.undo(), "the move did not undo");
		test::@check(app.doc.rotation_limits_of(joint).has_saved_frame, "undo did not bring the saved frame back");
	}
	test::@check(!app.use_bone_axes_recorded(hand.digits[2][1]), "a joint with no table took the bone's axes");
}

<*
 A finger table read from a version 28 session is pinned to the world-rolled
 frame it was written against, where its hand now rolls it, and keeps its
 numbers; one the hand leaves alone, and the same table written today, stay
 derived.

 Re-introduce: drop `keep_cardinal_limit_frames` from `session_document`, and
 the index's table is read on its hand's axes — the curl it allowed moved to
 another row.
*>
fn void an_older_sessions_finger_tables_keep_their_axes() @test
{
	io::printn("an older session's finger tables keep their axes");
	crig::AppState app = crig::new_app({});
	defer app.free();
	crig::RigDocument* doc = &app.doc;
	Hand hand = add_hand(doc, 1.0f, quaternion::IDENTITY);
	uint index = hand.digits[1][0];
	uint middle = hand.digits[2][0];
	foreach (id : (uint[]){ index, middle })
	{
		crig::JointRotationLimits limits = crig::unconstrained_rotation(id);
		limits.constrained = true;
		limits.axes[0] = { .allowed = true, .minimum = -1.5f, .maximum = 0.25f };
		test::@check(doc.set_rotation_limits(id, limits), "the table did not land");
	}
	crig::JointLimitFrame now = frame_of(doc, index);
	Vec3 world = crig::cardinal_limit_frame(now).axis(X);
	test::@check(math::abs(now.axis(X).dot(world)) < 0.5f, "the index's hand and world axes agree; nothing to pin");

	String text = crig::session_text(mem, doc, "hand.glb", limits: true);
	defer text.free(mem);
	test::@check(text.contains(`"version": 33`), "the session is not version 33");
	crig::RigDocument? current = crig::parse_session(mem, text);
	if (catch current) { test::@check(false, "today's session did not read"); return; }
	crig::RigDocument today = current;
	defer today.free();
	test::@check(!today.rotation_limits_of(index).has_saved_frame, "a current table was pinned");

	String older = text.replace(mem, `"version": 33`, `"version": 28`);
	defer older.free(mem);
	crig::RigDocument? opened = crig::parse_session(mem, older);
	if (catch opened) { test::@check(false, "the version 28 session did not read"); return; }
	crig::RigDocument legacy = opened;
	defer legacy.free();
	crig::JointRotationLimits held = legacy.rotation_limits_of(index);
	test::@check(held.has_saved_frame, "the index's table was left to the hand rule");
	test::@check(frame_of(&legacy, index).axis(X).dot(world) > 0.9999f,
		"the index's table was pinned to %s, not the axes it was written on", frame_of(&legacy, index).axis(X));
	test::@check(held.axes[0].minimum == -1.5f, "the pinned table lost its numbers");
	test::@check(!legacy.rotation_limits_of(middle).has_saved_frame, "a table the hand rule did not move was pinned");
}

<*
 The shipped humanoid's thumbs open on their hand's axes, none pinned: every
 joint of a thumb, like every finger, bends about its hand's knuckle line laid
 across its bone, one sign for the hand — which its first joint, rolled by the
 world axis it leaned on least, did not.

 Re-introduce: restore the humanoid's thumb rows from before the hand rule,
 and thumb_1 opens pinned to the frame they were written on.
*>
fn void the_humanoids_thumbs_bend_about_their_hands_x() @test
{
	io::printn("the humanoid's thumbs bend about their hand's X");
	rig::TriMesh mesh = rig::load_gltf(mem, HUMANOID)!!;
	defer mesh.free(mem);
	crig::AppState app = crig::new_app(mesh, HUMANOID);
	defer app.free();
	app.adopt_source_rig();

	foreach (side : (String[]){ "L", "R" })
	{
		// The knuckle line by its definition: index to pinky, square to the way
		// the wrist points at the four knuckles.
		Vec3[4] knuckles;
		foreach (usz f, finger : (String[]){ "index", "middle", "ring", "pinky" })
		{
			char[24] buffer;
			knuckles[f] = app.dot_named(string::bformat(buffer[..], "%s_1_%s", finger, side)).position;
		}
		char[24] wrist_name;
		Vec3 wrist = app.dot_named(string::bformat(wrist_name[..], "wrist_%s", side)).position;
		Vec3 ahead = ((knuckles[0] + knuckles[1] + knuckles[2] + knuckles[3]) / 4.0f - wrist).normalize();
		Vec3 line = knuckles[0] - knuckles[3];
		line = (line - ahead * line.dot(ahead)).normalize();

		float sign = 0.0f;
		foreach (digit : (String[]){ "middle", "thumb" })
		{
			for (usz k = 0; k < 3; k++)
			{
				char[24] buffer;
				String name = string::bformat(buffer[..], "%s_%d_%s", digit, k + 1, side);
				crig::Dot* dot = app.dot_named(name);
				test::@check(dot != null, "the humanoid has no %s", name);
				if (!dot) return;
				crig::JointRotationLimits table = app.doc.rotation_limits_of(dot.id);
				test::@check(table.constrained, "%s carries no table", name);
				test::@check(!table.has_saved_frame, "%s opened pinned to a frame of its own", name);
				crig::JointLimitFrame frame = frame_of(&app.doc, dot.id);
				float along = frame.axis(X).dot(across_the_bone(frame, line));
				if (sign == 0.0f) sign = along < 0.0f ? -1.0f : 1.0f;
				test::@check(along * sign >= ALONG_THE_HAND, "%s's X is %s, %.1f degrees off its hand's knuckle line",
					name, frame.axis(X), math::acos(math::min(math::abs(along), 1.0f)) * 180.0f / (float)math::PI);
			}
		}
	}
}

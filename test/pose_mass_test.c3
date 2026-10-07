<*
 Posing the humanoid by its body parts' weights: a finger pulled at its knuckle
 turns the hand instead of dragging the arm, a finger pulled out straightens, a
 fingertip dragged out and back comes back as it was, and each joint's weight
 can be set, undone and saved.

 A disposable copy of the shipped humanoid (`library::ready`), so the masses are
 read off a real mesh and its skin.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::pose_mass`
*>
module crig_tests::pose_mass;

import crig;
import rig;
import crig_tests::library;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

struct Body
{
	rig::TriMesh mesh;
	crig::AppState app;
}

fn bool Body.open(&self)
{
	String path = string::tformat("%s/humanoid.glb", library::ready());
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	if (!self.app.import_rig_from_source()) return false;
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	if (!self.app.rebind_skin(&view)) return false;
	crig::AnimRef clip = self.app.new_clip("pose", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.0f;
	return true;
}

fn void Body.close(&self) => self.app.free();

fn uint Body.id(&self, String name)
{
	foreach (dot : self.app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	test::@check(false, "the humanoid has no joint called %s", name);
	return 0;
}

fn Vec3 Body.at(&self, String name) => self.app.dot_position(*self.app.doc.find(self.id(name)));

// Grab `name` with G and carry it by `by` in the ten steps a pointer takes.
fn void Body.pull(&self, String name, Vec3 by)
{
	self.app.select(self.id(name));
	test::@check(self.app.begin_pose(), "G did not begin on %s", name);
	Vec3 from = self.at(name);
	for (int k = 1; k <= 10; k++) self.app.pose_toward(from + by * (k / 10.0f));
}

// How far a joint is turned from rest in its working pose, in degrees.
fn float Body.bend(&self, String name)
{
	Quaternionf q = self.app.working_pose(self.id(name)).rotation;
	return 2.0f * (float)math::acos((double)math::min(math::abs(q.v[3]), 1.0f)) * (float)(180.0 / math::PI);
}

fn float Body.mass(&self, String name)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	float[] mass = alloc::new_array(tmem, float, (sz)view.len());
	test::@check(self.app.body_part_masses(&view, mass), "no masses off the skin");
	return mass[(usz)view.joint_of(self.id(name))];
}

fn void the_body_parts_weigh_by_their_size() @test
{
	Body body;
	test::@check(body.open(), "the humanoid did not open");
	defer body.close();
	io::printn("A thigh outweighs a forearm, a forearm a hand, a hand a fingertip");

	test::@check(body.mass("knee_L") > body.mass("wrist_L"), "the thigh (%.2f) is not heavier than the forearm (%.2f)",
		body.mass("knee_L"), body.mass("wrist_L"));
	test::@check(body.mass("wrist_L") > body.mass("index_2_L"), "the forearm (%.2f) is not heavier than the knuckle (%.2f)",
		body.mass("wrist_L"), body.mass("index_2_L"));
	test::@check(body.mass("index_4_L") < 1.1f, "a fingertip weighs %.2f", body.mass("index_4_L"));
}

<*
 The case that pulled the body along: a finger's first joint hangs off the hand,
 a fork, so it is solved with the whole body. The hand now turns at the wrist
 and the arm barely takes part; it used to slide the hand, carrying the wrist
 twice as far as the knuckle.
*>
fn void a_knuckle_pulled_turns_the_hand_not_the_arm() @test
{
	Body body;
	test::@check(body.open(), "the humanoid did not open");
	defer body.close();
	io::printn("Pulling index_1_L 3 cm turns the hand and leaves the chest");

	Vec3 chest = body.at("chest");
	Vec3 shoulder = body.at("shoulder_L");
	Vec3 wrist = body.at("wrist_L");
	Vec3 knuckle = body.at("index_1_L");
	body.pull("index_1_L", { 0, 0.03f, 0 });

	test::@check((body.at("index_1_L") - knuckle).length() > 0.027f, "the knuckle did not follow the pointer");
	test::@check((body.at("chest") - chest).length() < 0.002f, "the chest moved %.4f", (body.at("chest") - chest).length());
	test::@check((body.at("shoulder_L") - shoulder).length() < 0.005f, "the shoulder moved %.4f", (body.at("shoulder_L") - shoulder).length());
	test::@check((body.at("wrist_L") - wrist).length() < 0.015f, "the wrist moved %.4f for a 3 cm pull", (body.at("wrist_L") - wrist).length());
	test::@check(body.bend("wrist_L") > 5.0f, "the hand did not turn at the wrist");
}

<*
 A curled finger pulled back out past its reach lays out straight: the curl is
 for closing a finger, and does not bend one being opened back in.
*>
fn void a_curled_finger_pulled_out_straightens() @test
{
	Body body;
	test::@check(body.open(), "the humanoid did not open");
	defer body.close();
	io::printn("A curled index finger pulled outward straightens");

	body.pull("index_4_L", { 0, -0.04f, 0 });
	body.app.end_drag();

	// Out along the hand, well past where the finger reaches. The bend is read
	// once the second gesture has the keyed curl in its draft.
	Vec3 out = (body.at("index_1_L") - body.at("wrist_L")).normalize() * 0.15f + (Vec3){ 0, -0.02f, 0 };
	Vec3 tip = body.at("index_4_L");
	body.app.select(body.id("index_4_L"));
	test::@check(body.app.begin_pose(), "G did not begin on the tip");
	float curled = body.bend("index_1_L") + body.bend("index_2_L") + body.bend("index_3_L");
	test::@check(curled > 25.0f, "the finger did not curl (%.1f°)", curled);
	for (int k = 1; k <= 10; k++) body.app.pose_toward(tip + out * (k / 10.0f));
	// The knuckle points the finger at the pointer; the two joints past it lie flat.
	foreach (name : (String[2]){ "index_2_L", "index_3_L" })
	{
		test::@check(body.bend(name) < 1.0f, "%s is still bent %.1f° after the pull out", name, body.bend(name));
	}
}

<*
 A fingertip dragged out and back to where it was grabbed comes back as it was:
 every move solves from the gesture's start, so nothing a limit left on the way
 is kept.
*>
fn void a_fingertip_dragged_out_and_back_returns() @test
{
	Body body;
	test::@check(body.open(), "the humanoid did not open");
	defer body.close();
	io::printn("A fingertip dragged down and back ends where it began");

	String[3] run = { "index_1_L", "index_2_L", "index_3_L" };
	Quaternionf[3] start;
	foreach (i, name : run) start[i] = body.app.working_pose(body.id(name)).rotation;
	// Up, against the knuckle's limit, and back the way it came.
	Vec3 tip = body.at("index_4_L");
	Vec3 by = { 0, 0.04f, 0 };
	body.pull("index_4_L", by);
	for (int k = 9; k >= 0; k--) body.app.pose_toward(tip + by * (k / 10.0f));
	foreach (i, name : run)
	{
		Quaternionf now = body.app.working_pose(body.id(name)).rotation;
		test::@check(math::abs(math::abs(now.v.dot(start[i].v)) - 1.0f) < 1.0e-4f, "%s did not come back", name);
	}
}

<*
 A joint's weight is the user's to set: a heavier hand holds still while its
 knuckle is pulled, one undo takes the weight back, and the sidecar keeps it.
*>
fn void a_heavier_hand_holds_and_the_weight_is_kept() @test
{
	Body body;
	test::@check(body.open(), "the humanoid did not open");
	defer body.close();
	io::printn("A hand at five times its weight turns less under a pulled knuckle");

	float light = body.mass("wrist_L");
	body.app.select(body.id("wrist_L"));
	test::@check(body.app.set_selection_pose_weight(5.0f), "the weight did not land");
	test::@check(math::abs(body.mass("wrist_L") - light * 5.0f) < 1.0e-3f, "the mass did not scale");
	test::@check(!body.app.set_selection_pose_weight(5.0f), "setting the same weight was an edit");

	String text = crig::session_text(mem, &body.app.doc, "hero.glb");
	defer text.free(mem);
	test::@check(text.contains(`"pose_weight":5`), "the session did not write the weight");
	crig::RigDocument back = crig::parse_session(mem, text)!!;
	defer back.free();
	crig::Dot* kept = back.find(body.id("wrist_L"));
	test::@check(kept && kept.pose_weight == 5.0f, "the weight did not come back from the session");
	foreach (dot : back.dots.array_view())
	{
		if (dot.id != body.id("wrist_L")) test::@check(dot.pose_weight == 0.0f, "%s came back with a weight", dot.name);
	}

	test::@check(body.app.undo(), "the weight did not undo");
	test::@check(body.app.selected_pose_weight() == 1.0f, "undo left the weight at %.2f", body.app.selected_pose_weight());
}

fn void the_heavier_hand_moves_less() @test
{
	float[2] moved;
	foreach (i, weight : (float[2]){ 1.0f, 5.0f })
	{
		Body body;
		test::@check(body.open(), "the humanoid did not open");
		defer body.close();
		body.app.select(body.id("wrist_L"));
		(void)body.app.set_selection_pose_weight(weight);
		Vec3 wrist = body.at("wrist_L");
		body.pull("index_1_L", { 0, 0.05f, 0 });
		moved[i] = (body.at("wrist_L") - wrist).length();
	}
	io::printn("A heavier hand moves less under the same pull");
	test::@check(moved[1] < moved[0], "the heavy hand moved %.4f, the light one %.4f", moved[1], moved[0]);
}

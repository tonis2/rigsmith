<*
 Clip pins in the editor: while a clip is being edited its pins ARE the gesture
 pins. Toggling a pin writes the clip (one undo step), moving the playhead out of
 a pin's window drops it from `position_locks`, a grab inside the window holds the
 pinned joint, and Clear all removes the clip's pins. With no clip open the pins
 stay session-only.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::clip_pin_edit`
*>
module crig_tests::clip_pin_edit;

import crig;
import crig_tests::mcp;
import rig;
import std::collections::object;
import std::core::test;
import std::io;
import std::math;
import std::math::vector;

const String PERSON = "assets/animations/humanoid.glb";

struct Model
{
	rig::TriMesh mesh;
	crig::AppState app;
	float height;
}

// The humanoid with a one-second rest clip on show at 0 and the Pose stage set.
fn bool Model.open(&self, bool with_clip = true)
{
	self.mesh = rig::load_gltf(mem, PERSON)!!;
	self.app = crig::new_app(self.mesh, PERSON);
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "the humanoid must import its rig");
		return false;
	}
	crig::RigView view = self.app.open_rig(mem)!!;
	self.height = view.skeleton.height();
	view.free(mem);
	if (!with_clip) return true;

	self.app.editing = self.app.new_clip("Pose", 1.0f, from_rest: true);
	test::@check(self.app.editing.valid(), "no clip to pose");
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.edit_time = 0.0f;
	test::@check(self.app.enter_pose_stage(), "the Pose stage would not open");
	self.app.auto_key = true;
	return self.app.editing.valid();
}

fn void Model.close(&self)
{
	self.app.free();
	self.mesh.free(mem);
}

fn uint Model.id(&self, String name)
{
	crig::Dot* dot = self.app.dot_named(name);
	test::@check(dot != null, "no joint called %s", name);
	return dot ? dot.id : 0;
}

fn Vec3 Model.at(&self, String name) => self.app.dot_position(*self.app.doc.find(self.id(name)));

fn crig::AnimTemplate* Model.clip(&self) => self.app.clip(self.app.editing);

fn float Model.off(&self, String name, Vec3 was) => (self.at(name) - was).length() / self.height;

<*
 A joint's world rotation as the figure stands now: the draft's while a gesture holds
 one open, the clip's own key at the playhead once `end_drag` has keyed it.
*>
fn Quaternionf Model.world(&self, String name)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose;
	if (self.app.pose_edit_active)
	{
		pose = self.app.draft_pose(mem, &view);
	}
	else
	{
		crig::AnimTemplate* clip = self.app.clip(self.app.editing);
		String[] names = self.app.names_for(&view, self.app.editing);
		pose = clip.pose(mem, &view.skeleton, names, self.app.edit_time, false);
	}
	defer pose.free(mem);
	Quaternionf[] world = pose.world_rotations(mem, &view.skeleton)!!;
	defer alloc::free(mem, world);
	return world[(usz)view.joint_of(self.id(name))];
}

// How far a joint's world rotation is from `was`, in degrees.
fn float Model.turned(&self, String name, Quaternionf was)
{
	Quaternionf q = self.world(name).mul(was.invert()).normalize();
	float vector = math::sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2]);
	return 2.0f * (float)math::atan2(vector, math::abs(q.v[3])) * 57.29578f;
}

// How far a joint's up has leaned from where `was` had it, in degrees.
fn float Model.tilt(&self, String name, Quaternionf was)
{
	Vec3 before = was.rotate_vec3({ 0, 1, 0 });
	Vec3 after = self.world(name).rotate_vec3({ 0, 1, 0 });
	return (float)math::atan2(before.cross(after).length(), before.dot(after)) * 57.29578f;
}

fn void Model.pull(&self, String name, Vec3 by)
{
	self.app.select(self.id(name));
	test::@check(self.app.begin_pose(true), "the pose gesture on %s did not begin", name);
	Vec3 from = self.app.drag.from;
	for (int step = 1; step <= 8; step++) self.app.pose_toward(from + by * ((float)step / 8.0f));
	self.app.end_drag();
}

// ---------------------------------------------------------------------------

<*
 Pin position with a clip open: the clip gains a pin over the whole clip with a
 0.1 s blend, as one undo step, and undo and redo take both the pin and the
 gesture pin away and back.
*>
fn void toggling_a_pin_writes_the_clip_in_one_undo_step() @test
{
	Model m;
	if (!m.open()) return;
	defer m.close();
	crig::AppState* app = &m.app;
	uint ankle = m.id("ankle_L");
	Vec3 where = m.at("ankle_L");

	sz history = app.undo_stack.cursor;
	app.set_anchor(ankle, true, false);
	test::@check(m.clip().pins.len == 1, "the clip has %d pins", m.clip().pins.len);
	test::eq(app.undo_stack.cursor, history + 1);
	test::@check(app.locks_position(ankle) && !app.locks_rotation(ankle), "the gesture pin is not position alone");
	crig::AnimPin pin = m.clip().pins[0];
	test::@check(pin.joint == "ankle_L" && pin.position && !pin.rotation, "the clip pin is not the ankle's position");
	test::@check(pin.from == 0.0f && pin.to == 1.0f, "the window is %.2f..%.2f, not the whole clip", pin.from, pin.to);
	test::@check(math::abs(pin.blend - 0.1f) < 1.0e-6f, "the blend is %.3f", pin.blend);
	test::@check((pin.at * m.height - where).length() / m.height < 1.0e-3f, "the pin holds somewhere else than the joint");

	// The angle half joins the same pin, another step.
	app.set_anchor(ankle, true, true);
	test::@check(m.clip().pins.len == 1 && m.clip().pins[0].rotation, "the angle half did not join the pin");
	test::eq(app.undo_stack.cursor, history + 2);

	app.undo();
	test::@check(m.clip().pins.len == 1 && !m.clip().pins[0].rotation && !app.locks_rotation(ankle),
		"undo did not take the angle half back");
	app.undo();
	test::@check(m.clip().pins.len == 0 && !app.is_anchored(ankle), "undo left the pin or its gesture pin");
	app.redo();
	test::@check(m.clip().pins.len == 1 && app.locks_position(ankle), "redo did not bring both back");

	// Unpinning the last half removes the clip pin.
	app.set_anchor(ankle, false, false);
	test::@check(m.clip().pins.len == 0 && !app.is_anchored(ankle), "unpinning left a clip pin");
}

fn void pin_feet_pins_both_in_the_clip() @test
{
	Model m;
	if (!m.open()) return;
	defer m.close();
	test::@check(m.app.pin_feet(true) == 2, "both feet were not found");
	test::@check(m.clip().pins.len == 2 && m.app.position_locks.len == 2, "feet: %d clip pins, %d gesture pins",
		m.clip().pins.len, m.app.position_locks.len);
	test::@check(m.app.feet_pinned(), "the feet do not read as pinned");
	foreach (&pin : m.clip().pins) test::@check(pin.position && pin.rotation, "a foot pin lacks a half");
	m.app.pin_feet(false);
	test::@check(m.clip().pins.len == 0, "unpinning the feet left clip pins");
}

<*
 The gesture pins are the pins whose window covers the playhead: out of it the
 pin is dropped, back in it is restored, and the clip keeps it throughout.
*>
fn void the_gesture_pins_follow_the_playhead_through_the_window() @test
{
	Model m;
	if (!m.open()) return;
	defer m.close();
	crig::AppState* app = &m.app;
	uint ankle = m.id("ankle_L");
	test::@check(app.set_clip_pin(ankle, true, false, 0.5f, 1.0f), "the pin would not land");
	test::@check(m.clip().pins[0].from == 0.5f, "the window did not take");

	test::@check(app.park_clip(app.editing, 0.2f), "no park");
	test::@check(app.position_locks.len == 0, "a pin outside its window is a gesture pin");
	test::@check(m.clip().pins.len == 1, "the clip lost the pin");
	test::@check(app.park_clip(app.editing, 0.7f), "no park");
	test::@check(app.position_locks.len == 1 && app.locks_position(ankle), "inside the window the pin is not a gesture pin");
	test::@check(app.park_clip(app.editing, 0.2f), "no park");
	test::@check(app.position_locks.len == 0, "leaving the window did not drop it again");

	// A muted pin is no gesture pin either.
	test::@check(app.park_clip(app.editing, 0.7f), "no park");
	crig::AnimPin muted = m.clip().pins[0].copy(mem);
	muted.mute = true;
	app.land_clip(app.editing, crig::clip_with_pin(mem, *m.clip(), muted));
	test::@check(app.position_locks.len == 0, "a muted pin steers a gesture");
}

<*
 A grab inside the window holds the pinned ankle; a grab outside it does not. A
 grab of the pinned joint itself moves the clip pin to where it was put.
*>
fn void a_grab_inside_the_window_holds_the_pin_and_moving_the_pinned_joint_moves_it() @test
{
	Model m;
	if (!m.open()) return;
	defer m.close();
	crig::AppState* app = &m.app;
	uint ankle = m.id("ankle_L");
	test::@check(app.set_clip_pin(ankle, true, false, 0.0f, 0.5f), "the pin would not land");
	Vec3 held = m.at("ankle_L");
	Quaternionf foot = m.world("ankle_L");
	Quaternionf hips = m.world("hips");
	Quaternionf chest = m.world("chest");

	m.pull("wrist_L", { 0, 0.05f * m.height, 0 });
	float off = m.off("ankle_L", held);
	test::@check(off < 0.005f, "the pinned ankle moved %.4f heights in its window", off);
	// A hand pull the arm can answer leaves the pinned foot flat and the body upright.
	io::printfn("  pinned foot turned %.2f, hips tilt %.2f, chest tilt %.2f deg", m.turned("ankle_L", foot), m.tilt("hips", hips), m.tilt("chest", chest));
	test::@check(m.turned("ankle_L", foot) < 3.0f, "the pinned foot turned %.2f degrees", m.turned("ankle_L", foot));
	test::@check(m.tilt("hips", hips) < 10.0f && m.tilt("chest", chest) < 10.0f, "the body tilted: hips %.2f, chest %.2f degrees",
		m.tilt("hips", hips), m.tilt("chest", chest));
	test::@check(m.clip().pins.len == 1 && (m.clip().pins[0].at * m.height - held).length() / m.height < 0.005f,
		"pulling the spine moved the pin");

	// Outside the window nothing holds it: the pin is not a gesture pin there.
	app.undo_stack.clear();
	test::@check(app.park_clip(app.editing, 0.9f), "no park");
	test::@check(app.enter_pose_stage(), "no pose stage");
	test::@check(app.position_locks.len == 0, "the pin steers a gesture outside its window");
}

<*
 A grab of the pinned joint itself moves the clip pin to where it was put, and the
 pose shown agrees (the ankle stands on the new pin). The pin update is its own
 undo step; the pose key (Auto-key) is another.
*>
fn void moving_the_pinned_joint_moves_its_clip_pin() @test
{
	Model m;
	if (!m.open()) return;
	defer m.close();
	crig::AppState* app = &m.app;
	uint ankle = m.id("ankle_L");
	test::@check(app.set_clip_pin(ankle, true, false), "the pin would not land");
	// From a parked clip, as a scrub leaves it: the shown pose carries the pin, and
	// the grabbed joint's own pin must stand aside for the drag.
	test::@check(app.park_clip(app.editing, 0.25f), "no park");
	test::@check(app.enter_pose_stage(), "no pose stage");
	Vec3 before = m.at("ankle_L");
	m.pull("ankle_L", { 0.05f * m.height, 0, 0 });
	Vec3 after = m.at("ankle_L");
	test::@check((after - before).length() / m.height > 0.02f, "the pinned ankle did not move when grabbed");
	Vec3 pinned = m.clip().pins[0].at * m.height;
	test::@check((pinned - after).length() / m.height < 0.01f,
		"the clip pin is %.4f heights from where the ankle was put", (pinned - after).length() / m.height);
	test::@check(app.position_locks.len == 1
		&& (app.position_locks[0].target - pinned).length() / m.height < 1.0e-4f, "the gesture pin did not follow the clip pin");
	// The shown pose and the played pose agree on where the ankle is.
	test::@check(app.park_clip(app.editing, 0.5f), "no park");
	test::@check(m.off("ankle_L", pinned) < 0.01f, "the clip no longer holds the ankle at the new pin (%.4f)", m.off("ankle_L", pinned));
}

fn void clear_all_removes_the_clip_pins_in_one_step() @test
{
	Model m;
	if (!m.open()) return;
	defer m.close();
	crig::AppState* app = &m.app;
	app.pin_feet(true);
	sz history = app.undo_stack.cursor;
	app.clear_editor_pins();
	test::@check(m.clip().pins.len == 0 && app.position_locks.len == 0, "Clear all left pins");
	test::eq(app.undo_stack.cursor, history + 1);
	app.undo();
	test::@check(m.clip().pins.len == 2 && app.position_locks.len == 2, "undo did not bring the pins back");
}

fn void without_a_clip_pins_stay_session_only() @test
{
	Model m;
	if (!m.open(false)) return;
	defer m.close();
	crig::AppState* app = &m.app;
	test::@check(!app.clip_pins_drive(), "a clip is open");
	sz history = app.undo_stack.cursor;
	app.set_anchor(m.id("ankle_L"), true, true);
	test::@check(app.position_locks.len == 1 && app.locks_rotation(m.id("ankle_L")), "the session pin is not there");
	test::eq(app.undo_stack.cursor, history);
	app.sync_clip_pins();
	test::@check(app.position_locks.len == 1, "a sync wiped a session pin");
	app.clear_editor_pins();
	test::@check(app.position_locks.len == 0, "Clear all left a session pin");
}

// ---------------------------------------------------------------------------
// MCP

fn void set_pins_takes_a_window_and_get_pins_lists_the_clip_pins() @test
{
	mcp::Fixture f;
	if (!f.open_model(PERSON)) return;
	defer f.close();
	crig::AnimRef ref = f.app.new_clip("Pin", 1.0f, from_rest: true);
	f.app.stop_animation();
	f.app.editing = ref;

	Object*? set = f.call_tool("set_pins",
		`{"pins":[{"joint":"ankle_L","from":0.2,"to":0.8,"blend":0.05}],"clip":"Pin","time":0.5}`);
	if (catch set) { test::@check(false, "set_pins refused"); return; }
	defer set.free();
	crig::AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.pins.len == 1, "the clip has %d pins", clip.pins.len);
	if (clip.pins.len != 1) return;
	crig::AnimPin pin = clip.pins[0];
	test::@check(math::abs(pin.from - 0.2f) < 1.0e-5f && math::abs(pin.to - 0.8f) < 1.0e-5f
		&& math::abs(pin.blend - 0.05f) < 1.0e-5f, "the window is %.3f..%.3f blend %.3f", pin.from, pin.to, pin.blend);
	test::@check(set.get("pins")!!.get_len() == 1, "the pin is not a gesture pin inside its window");
	Object* clip_pins = set.get("clip_pins")!!;
	test::@check(clip_pins.get_len() == 1 && (clip_pins.get_at(0).get_float("from") ?? -1.0) > 0.19, "clip_pins does not list the window");

	// Off the window it is still the clip's, though no gesture pin.
	Object*? off = f.call_tool("get_pins", `{}`);
	if (catch off) { test::@check(false, "get_pins refused"); return; }
	defer off.free();
	f.app.park_clip(f.app.editing, 0.0f);
	Object*? listed = f.call_tool("get_pins", `{}`);
	if (catch listed) { test::@check(false, "get_pins refused"); return; }
	defer listed.free();
	test::@check(listed.get("pins")!!.get_len() == 0 && listed.get("clip_pins")!!.get_len() == 1,
		"at 0 s: %d gesture pins, %d clip pins", listed.get("pins")!!.get_len(), listed.get("clip_pins")!!.get_len());

	Object*? bad = f.call_tool("set_pins", `{"pins":[{"joint":"ankle_L","from":-1}]}`);
	bool refused = false;
	if (catch bad) refused = true;
	test::@check(refused, "a negative from was accepted");

	Object*? cleared = f.call_tool("set_pins", `{"clear":true}`);
	if (catch cleared) { test::@check(false, "clear refused"); return; }
	defer cleared.free();
	test::@check(f.app.clip(f.app.editing).pins.len == 0, "clear left the clip's pins");
}

<*
 Pins and the whole-body solve, on the real rigs.

 The dog (`quadruped.glb`, 36 joints, no limits) and the humanoid (limits) are
 posed the way the viewport poses them: a pin switched on, a joint selected,
 `begin_pose` and `pose_toward` for the drag, `end_drag` for the release, which
 keys the result when Auto-key is on. Nothing here reimplements a gesture — what
 is asserted is where the pinned joints and the grabbed one stand afterwards, read
 back off the screen with `dot_position`, and that the keyed clip shows the same.
*>
module crig_tests::pinning;

import crig;
import crig_tests::mcp;
import rig;
import std::io;
import std::math;
import std::math::vector;
import std::collections::object;
import std::encoding::json;
import std::core::test;

const String DOG = "assets/animations/quadruped.glb";
const String PERSON = "assets/animations/humanoid.glb";

struct Model
{
	rig::TriMesh mesh;
	crig::AppState app;
	float height;
}

<*
 Opens a model with its own rig, a clip on show and the Pose stage set.

 @param grounded : `Author a Walk with contact windows (a ground spec) rather than a bare rest clip.`
*>
fn bool Model.open(&self, String path, bool grounded)
{
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "%s must import its rig", path);
		return false;
	}
	crig::RigView view = self.app.open_rig(mem)!!;
	self.height = view.skeleton.height();
	view.free(mem);

	if (grounded)
	{
		Object*? args = json::parse(mem, `{"name":"PinWalk","duration":1.1,"gait":"walk"}`);
		if (catch args) return false;
		defer args.free();
		DString detail = dstring::new(mem);
		defer detail.free();
		String? text = crig::author_gait_json(&self.app, args, &detail);
		if (catch text)
		{
			test::@check(false, "the gait did not author: %s", detail.str_view());
			return false;
		}
		text.free(mem);
		self.app.editing = self.app.clip_named_in_authored("PinWalk");
	}
	else
	{
		self.app.editing = self.app.new_clip("Pose", 1.0f, from_rest: true);
	}
	test::@check(self.app.editing.valid(), "no clip to pose");
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.edit_time = 0.0f;
	// The header's Pose switch: the clip goes on show at its playhead.
	test::@check(self.app.enter_pose_stage(), "the Pose stage would not open");
	self.app.auto_key = true;
	return self.app.editing.valid();
}

<*
 Gives the clip on show a ground spec with both named joints planted for the whole
 cycle — a figure standing on them — and puts it back on show.
*>
fn void Model.stand_on(&self, String left, String right)
{
	crig::AnimTemplate* clip = self.app.clip(self.app.editing);
	clip.ground.free(mem);
	crig::AnimFoot[] feet = alloc::new_array(mem, crig::AnimFoot, 2);
	feet[0] = { .joint = left.copy(mem), .down = 0.0f, .up = 1.0f };
	feet[1] = { .joint = right.copy(mem), .down = 0.0f, .up = 1.0f };
	clip.ground = { .feet = feet };
	test::@check(self.app.park_clip(self.app.editing, 0.0f), "the standing clip would not park");
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

// A joint's position pinned, where it stands now.
fn void Model.pin(&self, String name) => self.app.set_anchor(self.id(name), true, false);

<*
 One viewport pull: press on `name`, drag it `by` in a few moves, let go.
*>
fn void Model.pull(&self, String name, Vec3 by, DragAxis lock = FREE)
{
	self.app.select(self.id(name));
	test::@check(self.app.begin_pose(true), "the pose gesture on %s did not begin", name);
	// The Move tool's arrow is the same gesture held to an axis.
	if (lock != DragAxis.FREE) test::@check(self.app.lock_drag(lock), "the axis lock did not take");
	Vec3 from = self.app.drag.from;
	for (int step = 1; step <= 8; step++)
	{
		self.app.pose_toward(from + by * ((float)step / 8.0f));
	}
	self.app.end_drag();
}

// How far the joint is from where `was` had it, in rig heights.
fn float Model.off(&self, String name, Vec3 was) => (self.at(name) - was).length() / self.height;

<*
 One viewport turn: R on `name`, the pointer sweeping `angle` about `axis` in a
 few moves, and let go.
*>
fn void Model.turn(&self, String name, Vec3 axis, float angle)
{
	self.app.select(self.id(name));
	test::@check(self.app.begin_turn(true), "the turn on %s did not begin", name);
	for (int step = 1; step <= 8; step++)
	{
		self.app.turn_joint(axis, angle * ((float)step / 8.0f));
	}
	self.app.end_drag();
}

// Every listed joint still within 0.5% of the rig's height of where it was.
fn void Model.check_held(&self, String[] names, Vec3[] was, String what)
{
	foreach (usz i, name : names)
	{
		float off = self.off(name, was[i]);
		test::@check(off < 0.005f, "%s: %s moved %.4f heights off its pin", what, name, off);
	}
}

// ---------------------------------------------------------------------------
// The dog: pelvis down with the hind paws pinned

fn void check_pulled_down(Model* m, bool balance, DragAxis lock) @local
{
	m.app.balance_off = !balance;
	Vec3 paw_l = m.at("hind_hoof_L");
	Vec3 paw_r = m.at("hind_hoof_R");
	m.pin("hind_hoof_L");
	m.pin("hind_hoof_R");
	Vec3 pelvis = m.at("pelvis");
	m.pull("pelvis", { 0, -0.2f, 0 }, lock);

	Vec3 after = m.at("pelvis");
	io::printfn("  balance=%s pelvis %.3f,%.3f,%.3f -> %.3f,%.3f,%.3f  paw_L off %.4f  paw_R off %.4f",
		balance, pelvis.x, pelvis.y, pelvis.z, after.x, after.y, after.z,
		m.off("hind_hoof_L", paw_l), m.off("hind_hoof_R", paw_r));
	test::@check(after.y <= pelvis.y + 1.0e-4f, "the pelvis went UP: %.3f -> %.3f", pelvis.y, after.y);
	test::@check(pelvis.y - after.y > 0.1f, "the pelvis only dropped %.3f of the 0.2 pulled", pelvis.y - after.y);
	m.check_held({ "hind_hoof_L", "hind_hoof_R" }, { paw_l, paw_r }, "pelvis down");
}

fn void the_dog_sits_on_pinned_hind_paws_at_rest() @test
{
	io::printn("dog, rest clip: pelvis down with both hind paws pinned");
	foreach (bool balance : { true, false })
	{
		Model m;
		if (!m.open(DOG, false)) return;
		defer m.close();
		check_pulled_down(&m, balance, FREE);
	}
}

fn void the_dog_sits_on_pinned_hind_paws_in_a_grounded_walk() @test
{
	io::printn("dog, grounded Walk: pelvis down with both hind paws pinned");
	foreach (bool balance : { true, false })
	{
		Model m;
		if (!m.open(DOG, true)) return;
		defer m.close();
		check_pulled_down(&m, balance, FREE);
	}
}

fn void the_move_tools_arrow_sits_the_dog_the_same_way() @test
{
	io::printn("dog, grounded Walk: the Move arrow held to Y");
	foreach (bool balance : { true, false })
	{
		Model m;
		if (!m.open(DOG, true)) return;
		defer m.close();
		check_pulled_down(&m, balance, Y);
	}
}

<*
 What is keyed is what was shown: the gesture with Auto-key off leaves a draft on
 screen, and keying it parks the clip's own sample — the two must agree, or the
 ground solve is undoing the pose on the way into the clip.
*>
fn void the_keyed_pose_is_the_shown_pose() @test
{
	io::printn("dog, grounded Walk: keying the sit shows the same body");
	Model m;
	if (!m.open(DOG, true)) return;
	defer m.close();
	m.app.auto_key = false;
	m.pin("hind_hoof_L");
	m.pin("hind_hoof_R");
	m.pull("pelvis", { 0, -0.2f, 0 });

	String[8] names = { "pelvis", "chest", "hind_hoof_L", "hind_hoof_R", "fore_hoof_L", "fore_hoof_R", "hind_knee_L", "fore_knee_R" };
	Vec3[8] shown;
	foreach (usz i, name : names) shown[i] = m.at(name);
	test::@check(m.app.key_pose_edit(ALL), "the pose did not key");
	foreach (usz i, name : names)
	{
		test::@check(m.off(name, shown[i]) < 0.002f, "%s shown at %.3f,%.3f,%.3f but keyed to %.3f,%.3f,%.3f", name,
			shown[i].x, shown[i].y, shown[i].z, m.at(name).x, m.at(name).y, m.at(name).z);
	}
}

fn void turning_the_dogs_pelvis_keeps_the_hind_paws_down() @test
{
	io::printn("dog, grounded Walk: turn the pelvis with both hind paws pinned");
	foreach (Vec3 axis : { (Vec3){ 0, 1, 0 }, (Vec3){ -1, 0, 0 } })
	{
		Model m;
		if (!m.open(DOG, true)) return;
		defer m.close();
		Vec3 paw_l = m.at("hind_hoof_L");
		Vec3 paw_r = m.at("hind_hoof_R");
		m.pin("hind_hoof_L");
		m.pin("hind_hoof_R");
		m.turn("pelvis", axis, 0.25f);
		m.check_held({ "hind_hoof_L", "hind_hoof_R" }, { paw_l, paw_r }, "pelvis turned");
	}
}

// ---------------------------------------------------------------------------
// The humanoid: limits, feet pinned position and angle

fn void the_humanoid_squats_on_pinned_feet() @test
{
	io::printn("humanoid: hips down with both feet pinned");
	foreach (bool grounded : { false, true })
	{
		Model m;
		if (!m.open(PERSON, false)) return;
		defer m.close();
		if (grounded) m.stand_on("toe_L", "toe_R");
		Vec3 foot_l = m.at("ankle_L");
		Vec3 foot_r = m.at("ankle_R");
		m.app.pin_feet(true);
		Vec3 hips = m.at("hips");
		// A grounded figure's feet are also planted on the floor, which is held at
		// the same time: a squat only as deep as the ankles can stay flat for.
		float drop = m.height * (grounded ? 0.05f : 0.15f);
		m.pull("hips", { 0, -drop, 0 });
		Vec3 after = m.at("hips");
		io::printfn("  grounded=%s hips %.3f -> %.3f (asked %.3f lower)", grounded, hips.y, after.y, drop);
		test::@check(after.y <= hips.y + 1.0e-4f, "the hips went UP: %.3f -> %.3f", hips.y, after.y);
		test::@check(hips.y - after.y > drop * 0.7f, "the hips only dropped %.3f of %.3f", hips.y - after.y, drop);
		m.check_held({ "ankle_L", "ankle_R" }, { foot_l, foot_r }, "squat");
	}
}

// The angle the leg is folded by at `knee`, in degrees: 0 for a straight leg.
fn float Model.fold(&self, String thigh, String knee, String ankle)
{
	Vec3 above = (self.at(knee) - self.at(thigh)).normalize();
	Vec3 below = (self.at(ankle) - self.at(knee)).normalize();
	return (float)math::acos(math::clamp(above.dot(below), -1.0f, 1.0f)) * 180.0f / (float)math::PI;
}

<*
 Both ankles pinned and the body pulled down by `spine`: the knees fold and both
 feet stay on their pins. The grab is what gives way, never a pin — and never
 just one leg of the two.
*>
fn void check_spine_pulled_down(bool grounded, Vec3 by_fraction, bool walking = false, float at = 0.0f) @local
{
	Model m;
	if (!m.open(PERSON, walking)) return;
	defer m.close();
	if (at > 0.0f) test::@check(m.app.park_clip(m.app.editing, at), "the clip would not park at %.2f", at);
	if (grounded && !walking) m.stand_on("toe_L", "toe_R");
	Vec3 foot_l = m.at("ankle_L");
	Vec3 foot_r = m.at("ankle_R");
	m.pin("ankle_L");
	m.pin("ankle_R");
	m.pull("spine", by_fraction * m.height);
	float fold_l = m.fold("thigh_L", "knee_L", "ankle_L");
	float fold_r = m.fold("thigh_R", "knee_R", "ankle_R");
	io::printfn("  grounded=%s ankle_L off %.4f ankle_R off %.4f knees %.1f %.1f", grounded,
		m.off("ankle_L", foot_l), m.off("ankle_R", foot_r), fold_l, fold_r);
	m.check_held({ "ankle_L", "ankle_R" }, { foot_l, foot_r }, "spine pulled down");
	test::@check(fold_l > 20.0f, "the left knee only folded %.1f degrees", fold_l);
	test::@check(fold_r > 20.0f, "the right knee only folded %.1f degrees", fold_r);
}

fn void pulling_the_spine_down_folds_both_knees_on_pinned_ankles() @test
{
	io::printn("humanoid: spine down with both ankles pinned");
	foreach (bool grounded : { false, true })
	{
		// The grounded body is also standing on its toes, so it sits only as deep as flat feet allow.
		check_spine_pulled_down(grounded, { 0, grounded ? -0.05f : -0.15f, 0 });
	}
}

fn void pulling_the_spine_down_in_a_grounded_walk_keeps_both_feet() @test
{
	io::printn("humanoid, grounded Walk: spine down with both ankles pinned");
	// Shallow: a planted toe under a pinned ankle holds only as deep as the ankle's own limits let the foot stay flat.
	foreach (float at : { 0.0f, 0.2f, 0.4f, 0.6f, 0.8f })
	{
		check_spine_pulled_down(true, { 0, -0.02f, 0 }, true, at);
	}
}

fn void pulling_the_spine_down_and_aside_keeps_both_feet() @test
{
	io::printn("humanoid: spine down and a little sideways with both ankles pinned");
	foreach (bool grounded : { false, true })
	{
		foreach (float side : { 0.03f, -0.03f })
		{
			check_spine_pulled_down(grounded, { side, grounded ? -0.05f : -0.15f, 0 });
		}
	}
}

<*
 Nothing pinned: G on `spine` still moves the body — the hips come with it and
 the whole figure follows the pointer, legs and all: near enough the spine's own
 move, the pelvis turning a little where the pull is sideways.
*>
fn void the_spine_moves_the_body_with_nothing_pinned() @test
{
	Model m;
	if (!m.open(PERSON, false)) return;
	defer m.close();
	Vec3 spine = m.at("spine");
	Vec3 hips = m.at("hips");
	Vec3 foot = m.at("ankle_L");
	Vec3 by = (Vec3){ 0.05f, -0.1f, 0.02f } * m.height;
	m.pull("spine", by);
	io::printfn("  spine off %.4f, hips off %.4f, ankle off %.4f", m.off("spine", spine + by), m.off("hips", hips + by), m.off("ankle_L", foot + by));
	test::@check(m.off("spine", spine + by) < 0.005f, "the spine missed the pointer by %.4f heights", m.off("spine", spine + by));
	test::@check(m.off("hips", hips + by) < 0.02f, "the hips did not carry the body");
	test::@check(m.off("ankle_L", foot + by) < 0.05f, "the legs did not come along");
}

<*
 Nothing pinned on a clip shown grounded: the feet it has planted hold, so pulling
 `spine` down folds the knees instead of the floor lifting the body straight back.
*>
fn void the_spine_sits_a_grounded_body_on_its_planted_feet() @test
{
	Model m;
	if (!m.open(PERSON, false)) return;
	defer m.close();
	m.stand_on("toe_L", "toe_R");
	Vec3 spine = m.at("spine");
	Vec3 toe_l = m.at("toe_L");
	Vec3 toe_r = m.at("toe_R");
	Vec3 by = { 0, -0.05f * m.height, 0 };
	m.pull("spine", by);
	float dropped = (spine.y - m.at("spine").y) / m.height;
	test::@check(dropped > 0.04f, "the spine came down only %.4f heights", dropped);
	m.check_held({ "toe_L", "toe_R" }, { toe_l, toe_r }, "grounded spine pull");
	float fold_l = m.fold("thigh_L", "knee_L", "ankle_L");
	float fold_r = m.fold("thigh_R", "knee_R", "ankle_R");
	test::@check(fold_l > 10.0f && fold_r > 10.0f, "the knees folded only %.1f and %.1f degrees", fold_l, fold_r);
}

<*
 A thigh hangs off the hips, with nothing above it but the fork: G on it moves the
 body, the hips carried with the thigh to the pointer.
*>
fn void the_thigh_moves_the_body() @test
{
	Model m;
	if (!m.open(PERSON, false)) return;
	defer m.close();
	Vec3 thigh = m.at("thigh_L");
	Vec3 hips = m.at("hips");
	Vec3 by = { 0.03f * m.height, -0.05f * m.height, 0.02f * m.height };
	m.pull("thigh_L", by);
	io::printfn("  thigh off %.4f, hips moved %.4f", m.off("thigh_L", thigh + by), m.off("hips", hips));
	test::@check(m.off("thigh_L", thigh + by) < 0.005f, "the thigh missed the pointer by %.4f heights", m.off("thigh_L", thigh + by));
	test::@check(m.off("hips", hips) > 0.03f, "the hips stayed where they were");
}

fn void turning_the_humanoids_hips_keeps_the_feet_down() @test
{
	io::printn("humanoid: turn the hips with both feet pinned");
	foreach (bool grounded : { false, true })
	{
		Model m;
		if (!m.open(PERSON, false)) return;
		defer m.close();
		if (grounded) m.stand_on("toe_L", "toe_R");
		Vec3 foot_l = m.at("ankle_L");
		Vec3 foot_r = m.at("ankle_R");
		m.app.pin_feet(true);
		m.turn("hips", { 0, 1, 0 }, 0.4f);
		m.check_held({ "ankle_L", "ankle_R" }, { foot_l, foot_r }, "hips turned");
	}
}

fn void a_pinned_hand_holds_while_the_chest_moves() @test
{
	io::printn("humanoid: one hand pinned, the chest pulled");
	foreach (bool grounded : { false, true })
	{
		Model m;
		if (!m.open(PERSON, false)) return;
		defer m.close();
		if (grounded) m.stand_on("toe_L", "toe_R");
		Vec3 hand = m.at("wrist_L");
		Vec3 chest = m.at("upper_spine");
		m.pin("wrist_L");
		m.pull("upper_spine", { 0, 0, m.height * 0.05f });
		io::printfn("  grounded=%s chest moved %.3f of %.3f", grounded, (m.at("upper_spine") - chest).length(), m.height * 0.05f);
		test::@check((m.at("upper_spine") - chest).length() > m.height * 0.02f, "the chest did not follow the pull");
		m.check_held({ "wrist_L" }, { hand }, "chest pulled");
	}
}

<*
 A squat deeper than the ankles can hold flat: the pins cannot all hold, and what
 they report has to be the miss on screen — the ground solve lifting the body off
 a foot that tilts is the pin missing, and saying 0 there was the lie.
*>
fn void a_pin_that_cannot_hold_reports_its_true_miss() @test
{
	io::printn("humanoid: a squat too deep for flat feet reports what is on screen");
	Model m;
	if (!m.open(PERSON, false)) return;
	defer m.close();
	m.stand_on("toe_L", "toe_R");
	Vec3 foot_l = m.at("ankle_L");
	m.app.pin_feet(true);
	m.pull("hips", { 0, -m.height * 0.25f, 0 });
	float actual = (m.at("ankle_L") - foot_l).length();
	float said = m.app.lock_position_residual(m.id("ankle_L"));
	io::printfn("  ankle_L is %.4f off its pin, the readout says %.4f", actual, said);
	test::@check(math::abs(actual - said) < m.height * 0.003f, "the readout says %.4f and the ankle is %.4f off", said, actual);
}

// ---------------------------------------------------------------------------
// The MCP tools: get_pins, set_pins, pose_joint

fn bool open_dog_tools(mcp::Fixture* f)
{
	if (!f.open_model(DOG)) return false;
	Object*? walk = f.call_tool("author_gait", `{"name":"PinWalk","duration":1.1,"gait":"walk"}`);
	if (catch walk)
	{
		test::@check(false, "the dog's gait did not author");
		f.close();
		return false;
	}
	walk.free();
	return true;
}

fn float number_of(Object* object, String key) => (float)(object.get_float(key) ?? -1.0);

<*
 The sit, asked over MCP: pin both hind paws, pull the pelvis down, and what comes
 back is the same body the window shows, keyed.
*>
fn void the_mcp_tools_sit_the_dog_on_its_pinned_paws() @test
{
	io::printn("set_pins and pose_joint sit the dog on its hind paws and key it");
	mcp::Fixture f;
	if (!open_dog_tools(&f)) return;
	defer f.close();

	Object*? set = f.call_tool("set_pins",
		`{"pins":[{"joint":"hind_hoof_L"},{"joint":"hind_hoof_R","position":true}],"clip":"PinWalk","time":0}`);
	if (catch set) { test::@check(false, "set_pins refused"); return; }
	defer set.free();
	test::@check(set.get("pins")!!.get_len() == 2, "two pins were not set");

	uint pelvis = f.app.dot_named("pelvis").id;
	uint paw = f.app.dot_named("hind_hoof_L").id;
	Vec3 pelvis_was = f.app.dot_position(*f.app.doc.find(pelvis));
	Vec3 paw_was = f.app.dot_position(*f.app.doc.find(paw));

	Object*? posed = f.call_tool("pose_joint", `{"joint":"pelvis","move":[0,-0.2,0]}`);
	if (catch posed) { test::@check(false, "pose_joint refused"); return; }
	defer posed.free();
	float miss = number_of(posed, "miss_fraction");
	test::@check(miss < 0.03f, "the pelvis missed its point by %.4f heights", miss);
	test::@check(posed.get_bool("keyed") ?? false, "the pose was not keyed");

	Vec3 pelvis_now = f.app.dot_position(*f.app.doc.find(pelvis));
	Vec3 paw_now = f.app.dot_position(*f.app.doc.find(paw));
	io::printfn("  pelvis %.3f -> %.3f, paw moved %.4f", pelvis_was.y, pelvis_now.y, (paw_now - paw_was).length());
	test::@check(pelvis_was.y - pelvis_now.y > 0.15f, "the pelvis only dropped %.3f", pelvis_was.y - pelvis_now.y);
	test::@check((paw_now - paw_was).length() < 0.003f, "the paw left its pin by %.4f", (paw_now - paw_was).length());

	Object* state = posed.get("state")!!;
	Object* pins = state.get("pins")!!;
	test::@check(pins.get_len() == 2, "the answer lists %d pins", pins.get_len());
	test::@check(number_of(pins.get_at(0), "residual") < 0.005f, "the pin reports a miss of %.4f", number_of(pins.get_at(0), "residual"));

	Object*? listed = f.call_tool("get_pins", `{}`);
	if (catch listed) { test::@check(false, "get_pins refused"); return; }
	defer listed.free();
	test::@check(listed.get("pins")!!.get_len() == 2, "get_pins lists %d", listed.get("pins")!!.get_len());
	test::@check(listed.get("pins")!!.get_at(0).get_bool("position") ?? false, "a pin holds no position");
}

fn void set_pins_refuses_what_it_cannot_pin() @test
{
	io::printn("set_pins and pose_joint refuse unknown joints and leave things as they were");
	mcp::Fixture f;
	if (!open_dog_tools(&f)) return;
	defer f.close();

	Object*? bad = f.call_tool("set_pins", `{"pins":[{"joint":"hind_hoof_L"},{"joint":"no_such_joint"}]}`);
	test::@check(@catch(bad), "a pin on a joint the rig lacks was accepted");
	test::@check(f.app.position_locks.len == 0, "a refused call changed the pins");

	Object*? pinned = f.call_tool("set_pins", `{"pins":[{"joint":"hind_hoof_L"}]}`);
	if (catch pinned) { test::@check(false, "set_pins refused"); return; }
	pinned.free();
	test::@check(f.app.position_locks.len == 1, "the pin was not set");
	Object*? cleared = f.call_tool("set_pins", `{"clear":true}`);
	if (catch cleared) { test::@check(false, "clear refused"); return; }
	cleared.free();
	test::@check(f.app.position_locks.len == 0, "clear left pins");

	Object*? nothing = f.call_tool("pose_joint", `{"joint":"pelvis"}`);
	test::@check(@catch(nothing), "pose_joint with nothing to do was accepted");
	Object*? nowhere = f.call_tool("pose_joint", `{"joint":"no_such_joint","move":[0,0.1,0]}`);
	test::@check(@catch(nowhere), "pose_joint on a joint the rig lacks was accepted");
}

fn void pose_joint_can_leave_the_pose_unkeyed_and_key_it_later() @test
{
	io::printn("pose_joint key:false leaves a pending pose that a bare key:true keys");
	mcp::Fixture f;
	if (!open_dog_tools(&f)) return;
	defer f.close();

	Object*? posed = f.call_tool("pose_joint", `{"joint":"hind_hoof_L","move":[0,0.05,0],"clip":"PinWalk","time":0,"key":false}`);
	if (catch posed) { test::@check(false, "pose_joint refused"); return; }
	test::@check(!(posed.get_bool("keyed") ?? true), "the pose was keyed though key was false");
	test::@check(f.app.pose_edit_pending, "no pose is pending");
	posed.free();

	Object*? keyed = f.call_tool("pose_joint", `{"key":true}`);
	if (catch keyed) { test::@check(false, "keying the pending pose refused"); return; }
	keyed.free();
	test::@check(!f.app.pose_edit_pending, "the pose is still pending");
}

fn void pose_joint_turns_a_joint() @test
{
	io::printn("pose_joint turn: the pelvis turned with pinned hind paws holds the paws");
	mcp::Fixture f;
	if (!open_dog_tools(&f)) return;
	defer f.close();
	Object*? set = f.call_tool("set_pins", `{"pins":[{"joint":"hind_hoof_L"},{"joint":"hind_hoof_R"}],"clip":"PinWalk","time":0}`);
	if (catch set) { test::@check(false, "set_pins refused"); return; }
	set.free();
	uint paw = f.app.dot_named("hind_hoof_L").id;
	Vec3 was = f.app.dot_position(*f.app.doc.find(paw));
	Object*? turned = f.call_tool("pose_joint", `{"joint":"pelvis","turn":{"axis":"y","angle":0.25}}`);
	if (catch turned) { test::@check(false, "the turn refused"); return; }
	turned.free();
	Vec3 now = f.app.dot_position(*f.app.doc.find(paw));
	test::@check((now - was).length() < 0.006f, "the paw moved %.4f", (now - was).length());
}

// ---------------------------------------------------------------------------
// A sit is a pitch: the rear goes down, the chest stays up, nothing bends sideways

fn Vec3 at_in(crig::AppState* app, String name) => app.dot_position(*app.doc.find(app.dot_named(name).id));

fn void dump_dog(crig::AppState* app, String tag) @local
{
	foreach (String n : (String[]){ "pelvis", "spine", "chest", "shoulder_L", "fore_knee_L", "fore_hoof_L", "fore_hoof_R", "hind_hoof_L" })
	{
		Vec3 p = at_in(app, n);
		io::printfn("  %s %-10s %.3f %.3f %.3f", tag, n, p.x, p.y, p.z);
	}
}

<*
 All four hooves pinned at rest and the pelvis pulled down: the crouch stays on the
 midline and every hoof holds. The quadruped faces −X, so its midline is z = 0;
 its legs stand mid-stride, so left and right are not mirrors of each other.
*>
fn void four_pinned_hooves_crouch_on_the_midline() @test
{
	io::printn("pose_joint: four pinned hooves, pelvis down, stays on the midline");
	mcp::Fixture f;
	if (!open_dog_tools(&f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	Object*? rest = f.call_tool("apply_clip", `{"name":"Stand","duration":1,"keyframes":[{"time":0,"joints":[]}]}`);
	if (catch rest) { test::@check(false, "the standing clip would not author"); return; }
	rest.free();
	Object*? again = f.call_tool("set_pins",
		`{"pins":[{"joint":"hind_hoof_L"},{"joint":"hind_hoof_R"},{"joint":"fore_hoof_L"},{"joint":"fore_hoof_R"}],"clip":"Stand","time":0}`);
	if (catch again) { test::@check(false, "set_pins refused"); return; }
	again.free();
	String[4] hooves = { "hind_hoof_L", "hind_hoof_R", "fore_hoof_L", "fore_hoof_R" };
	Vec3[4] hooves_was;
	foreach (i, n : hooves) hooves_was[i] = at_in(app, n);
	Vec3 pelvis_was = at_in(app, "pelvis");
	Object*? posed = f.call_tool("pose_joint", `{"joint":"pelvis","move":[0,-0.15,0]}`);
	if (catch posed) { test::@check(false, "pose_joint refused"); return; }
	posed.free();
	dump_dog(app, "crouch");
	test::@check(pelvis_was.y - at_in(app, "pelvis").y > 0.1f, "the pelvis only dropped %.3f", pelvis_was.y - at_in(app, "pelvis").y);
	foreach (String n : (String[]){ "spine", "chest", "pelvis" })
	{
		test::@check(math::abs(at_in(app, n).z) < 0.005f, "%s drifted sideways to z=%.4f", n, at_in(app, n).z);
	}
	foreach (i, n : hooves)
	{
		float off = (at_in(app, n) - hooves_was[i]).length();
		test::@check(off < 0.005f, "%s left its pin by %.4f", n, off);
	}
}


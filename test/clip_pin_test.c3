<*
 Clip pins: a joint held in place for a window of a clip, solved live like the
 look-at aims and baked into keys on export.

 The humanoid is opened as the editor opens it and given a clip whose two keys
 move the hips to different places, so a foot that is not pinned slides between
 them. What is asserted is where the ankle stands in the pose the player shows
 (`evaluated_clip_pose` with the live layers on), in the exported curves, and
 that the carriers (retime, crop, mirror, session) keep the pin.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::clip_pin`
*>
module crig_tests::clip_pin;

import crig;
import rig;
import gltf_edit;
import std::io;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

const String PERSON = "assets/animations/humanoid.glb";

struct Person
{
	rig::TriMesh mesh;
	crig::AppState app;
	crig::AnimRef ref;
	crig::RigView view;
	String[] names;
	float height;
	usz ankle;
	usz ankle_twin;
	Vec3 rest;
}

fn usz joint_named(String[] names, String name)
{
	foreach (usz i, held : names) if (held == name) return i;
	test::@check(false, "no joint called %s", name);
	return 0;
}

<*
 The humanoid with a one-second clip keyed so the hips are somewhere else at each
 end: low at the start, low and off to a side at the end.
*>
fn bool Person.open(&self)
{
	self.mesh = rig::load_gltf(mem, PERSON)!!;
	self.app = crig::new_app(self.mesh, PERSON);
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "the humanoid must import its rig");
		return false;
	}
	self.view = self.app.open_rig(mem)!!;
	self.height = self.view.skeleton.height();
	self.ref = self.app.new_clip("Pin", 1.0f, from_rest: true);
	self.names = self.app.names_for(&self.view, self.ref);
	self.ankle = joint_named(self.names, "ankle_L");
	self.ankle_twin = joint_named(self.names, "ankle_R");
	self.rest = self.view.skeleton.joints[self.ankle] / self.height;

	String root = self.names[0];
	Vec3[2] hips = { { 0.0f, -0.03f, 0.0f }, { 0.02f, -0.07f, 0.02f } };
	foreach (usz k, at : hips)
	{
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 1);
		dots[0] = { .joint_name = root.copy(mem), .channels = TRANSLATION, .move = at };
		self.ref = self.app.land_clip(self.ref,
			crig::clip_with_key(mem, *self.app.clip(self.ref), { .time = (float)k, .dots = dots }));
	}
	return self.ref.valid();
}

fn void Person.close(&self)
{
	self.view.free(mem);
	self.app.free();
	self.mesh.free(mem);
}

// The clip on show, with `pin` put on it.
fn void Person.pin(&self, crig::AnimPin pin)
{
	self.ref = self.app.land_clip(self.ref, crig::clip_with_pin(mem, *self.app.clip(self.ref), pin));
}

fn crig::AnimPin Person.hold_ankle(&self, float from, float to, float blend)
{
	crig::AnimPin pin = crig::pin_defaults(mem, "ankle_L", self.rest, from, to);
	pin.blend = blend;
	return pin;
}

// Where the left ankle stands in what the player shows at `time`.
fn Vec3 Person.ankle_at(&self, float time, bool pinned = true)
{
	crig::AnimTemplate clip = *self.app.clip(self.ref);
	if (!pinned) clip.pins = {};
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &self.view, clip, self.ref, time, false, true);
	defer pose.free(mem);
	return joint_position(&self.view.skeleton, pose, self.ankle);
}

fn Vec3 joint_position(rig::Skeleton* skeleton, rig::Pose pose, usz joint)
{
	Matrix4f[] palette = rig::joint_palette(mem, skeleton, pose)!!;
	defer alloc::free(mem, palette);
	return skeleton.joints[joint].transform(palette[joint]);
}

// How far the ankle is from the pinned place, in rig heights.
fn float Person.miss(&self, float time, bool pinned = true) => (self.ankle_at(time, pinned) - self.rest * self.height).length() / self.height;

fn float closeness(Quaternionf a, Quaternionf b) => math::abs(a.v.dot(b.v));

// ---------------------------------------------------------------------------

fn void a_pinned_ankle_stays_put_while_the_hips_move() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();

	// Without the pin the keys carry the foot away with the hips.
	test::@check(p.miss(1.0f, false) > 0.03f, "the keys do not move the foot (%.4f)", p.miss(1.0f, false));

	p.pin(p.hold_ankle(0.0f, 1.0f, 0.0f));
	test::@check(p.app.clip(p.ref).plays_pins(), "the pin does not play");
	float[5] times = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	foreach (time : times)
	{
		test::@check(p.miss(time) < 0.005f, "the ankle is %.4f heights off its pin at %s", p.miss(time), time);
	}

	// Muting gives the keys back exactly.
	p.app.clip(p.ref).pins[0].mute = true;
	test::@check(!p.app.clip(p.ref).plays_pins(), "a muted pin plays");
	test::@check(p.miss(1.0f) == p.miss(1.0f, false), "a muted pin changed the pose");
}

fn void a_pin_holds_inside_its_window_and_blends_at_the_edges() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	p.pin(p.hold_ankle(0.4f, 0.8f, 0.2f));

	// Outside: the keys, untouched.
	test::@check(p.miss(0.1f) == p.miss(0.1f, false), "the pin acted before its window");
	test::@check(p.miss(0.95f) == p.miss(0.95f, false), "the pin acted after its window");
	// Inside, past the ramp: held.
	test::@check(p.miss(0.6f) < 0.005f, "the ankle slid inside the window (%.4f)", p.miss(0.6f));
	// Halfway up the ramp: between the keys and the hold.
	float loose = p.miss(0.5f, false);
	float half = p.miss(0.5f);
	io::printfn("  mid-ramp: keys %.4f, blended %.4f", loose, half);
	test::@check(half < loose * 0.9f && half > 0.002f, "the ramp did not blend (%.4f of %.4f)", half, loose);
	// The ramp is monotone: nearer the hold the further it has come.
	test::@check(p.miss(0.45f) / p.miss(0.45f, false) > half / loose, "the ramp does not rise");
}

fn void a_pin_that_straddles_the_loop_point_holds_through_it() @test
{
	crig::AnimPin pin = { .joint = "x", .position = true, .from = 0.8f, .to = 1.3f };
	test::@check(pin.weight_at(1.0f, 1.0f, true) == 1.0f && pin.weight_at(0.2f, 1.0f, true) == 1.0f, "no weight across the loop point");
	test::@check(pin.weight_at(0.2f, 1.0f, false) == 0.0f, "weight across the end of a clip that does not loop");
	test::@check(pin.weight_at(0.5f, 1.0f, true) == 0.0f, "weight outside the window");
	pin.from = 0.0f;
	pin.to = 1.0f;
	pin.blend = 0.25f;
	test::@check(pin.weight_at(0.0f, 1.0f, false) == 0.0f && pin.weight_at(0.5f, 1.0f, false) == 1.0f, "the ends of a blend");
	test::@check(math::abs(pin.weight_at(0.125f, 1.0f, false) - 0.5f) < 1.0e-5f, "a smoothstep is half way at half");
}

// How far the left ankle's world orientation is from the rest pose's, in radians.
fn float Person.foot_tilt(&self, float time)
{
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &self.view, *self.app.clip(self.ref), self.ref, time, false, true);
	defer pose.free(mem);
	Quaternionf[] world = pose.world_rotations(mem, &self.view.skeleton)!!;
	defer alloc::free(mem, world);
	return 2.0f * (float)math::acos((double)math::min(1.0f, math::abs(world[self.ankle].v.w)));
}

<*
 The leg folds to keep the foot planted and the foot would fold with it; a
 rotation pin keeps it flat as far as the ankle's own limits let it.
*>
fn void a_rotation_pin_keeps_the_foot_flat() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	p.pin(p.hold_ankle(0.0f, 1.0f, 0.0f));
	float folded = p.foot_tilt(1.0f);

	crig::AnimPin pin = p.hold_ankle(0.0f, 1.0f, 0.0f);
	pin.rotation = true;
	pin.orient = quaternion::IDENTITY;
	p.pin(pin);
	float flat = p.foot_tilt(1.0f);
	io::printfn("  foot tilt: position only %.4f, with rotation %.4f", folded, flat);
	test::@check(folded > 0.1f, "the folded leg does not tilt the foot (%.4f)", folded);
	test::@check(flat < folded * 0.7f, "the rotation pin did not flatten the foot (%.4f of %.4f)", flat, folded);
	test::@check(p.miss(1.0f) < 0.005f, "holding the angle lost the position (%.4f)", p.miss(1.0f));
}

fn void mirroring_a_clip_swaps_the_pin_to_the_other_side() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	crig::AnimPin pin = crig::pin_defaults(mem, "ankle_L", { 0.1f, 0.05f, 0.02f }, 0.2f, 0.7f);
	pin.rotation = true;
	pin.orient = quaternion::from_axis_angle{float}((Vec3){ 0.3f, 0.5f, 0.8f }.normalize(), 0.6f);
	pin.blend = 0.1f;
	p.pin(pin);

	crig::AnimTemplate mirrored = crig::mirror_template(mem, *p.app.clip(p.ref), "Mirrored", 0.0f);
	defer mirrored.free(mem);
	test::@check(mirrored.pins.len == 1, "the mirrored clip has %d pins", mirrored.pins.len);
	if (mirrored.pins.len != 1) return;
	crig::AnimPin* got = &mirrored.pins[0];
	test::@check(got.joint == "ankle_R", "the pin is on %s", got.joint);
	test::@check(math::abs(got.at.x + 0.1f) < 1.0e-6f && got.at.y == 0.05f && got.at.z == 0.02f, "at was not reflected");
	test::@check(got.from == 0.2f && got.to == 0.7f && got.blend == 0.1f && got.position && got.rotation, "the window or flags changed");
	Quaternionf want = crig::reflected_rotation(pin.orient);
	test::@check(math::abs(got.orient.v.dot(want.v)) > 0.99999f, "the held orientation was not reflected");

	// Twice is the original.
	crig::AnimTemplate back = crig::mirror_template(mem, mirrored, "Back", 0.0f);
	defer back.free(mem);
	test::@check(back.pins[0].joint == "ankle_L" && math::abs(back.pins[0].at.x - 0.1f) < 1.0e-6f, "mirroring twice is not the identity");
}

fn void retime_crop_and_cut_carry_the_pin_window() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	p.pin(p.hold_ankle(0.5f, 1.0f, 0.2f));
	crig::AnimTemplate source = *p.app.clip(p.ref);

	crig::AnimTemplate slow = crig::clip_retimed(mem, source, 2.0f);
	defer slow.free(mem);
	test::@check(slow.pins.len == 1 && slow.pins[0].from == 1.0f && slow.pins[0].to == 2.0f && math::abs(slow.pins[0].blend - 0.4f) < 1.0e-6f,
		"a retime did not scale the window");

	crig::AnimTemplate cropped = crig::clip_cropped(mem, source, 0.25f, 0.75f);
	defer cropped.free(mem);
	test::@check(cropped.pins.len == 1 && cropped.pins[0].from == 0.25f && cropped.pins[0].to == 0.5f, "a crop did not shift and clip the window");

	// A crop that leaves the window behind drops the pin.
	crig::AnimTemplate early = crig::clip_cropped(mem, source, 0.0f, 0.4f);
	defer early.free(mem);
	test::@check(early.pins.len == 0, "a pin outside the crop was kept");

	crig::AnimTemplate cut = crig::clip_range_cut(mem, source, 0.1f, 0.3f);
	defer cut.free(mem);
	test::@check(cut.pins.len == 1 && math::abs(cut.pins[0].from - 0.3f) < 1.0e-6f && math::abs(cut.pins[0].to - 0.8f) < 1.0e-6f,
		"a cut did not move the window up");

	crig::AnimTemplate copy = crig::clip_copy(mem, source);
	defer copy.free(mem);
	test::@check(copy.pins.len == 1 && copy.pins[0].joint == "ankle_L", "a copy lost the pin");
	crig::AnimTemplate rewritten = crig::clip_without_pin(mem, source, "ankle_L");
	defer rewritten.free(mem);
	test::@check(rewritten.pins.len == 0 && source.pins.len == 1, "clip_without_pin changed its source or kept the pin");
}

fn void the_session_round_trips_pins_and_an_older_file_has_none() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();

	crig::AnimTemplate plain = crig::clip_copy(mem, *p.app.clip(p.ref));
	defer plain.free(mem);
	AnimTemplate[1] unpinned = { plain };
	String bare = crig::session_text(mem, &p.app.doc, "hero.glb", unpinned[..]);
	defer bare.free(mem);
	test::@check(!bare.contains(`"pins"`), "a clip with no pins wrote a pins member");

	crig::AnimPin pin = p.hold_ankle(0.1f, 0.9f, 0.15f);
	pin.rotation = true;
	pin.orient = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.4f);
	p.pin(pin);
	AnimTemplate[1] source = { *p.app.clip(p.ref) };
	String text = crig::session_text(mem, &p.app.doc, "hero.glb", source[..]);
	defer text.free(mem);
	test::@check(text.contains(`"version": 24`) && text.contains(`"pins"`), "the session did not write version 24 pins");

	AnimTemplate[]? read = crig::parse_session_clips(mem, text);
	if (catch fault error = read)
	{
		test::@check(false, "the pins did not read back: %s", error);
		return;
	}
	AnimTemplate[] back = read;
	defer crig::free_animations(mem, back);
	test::@check(back.len == 1 && back[0].pins.len == 1, "the clip came back without its pin");
	if (back.len == 1 && back[0].pins.len == 1)
	{
		crig::AnimPin got = back[0].pins[0];
		test::@check(got.joint == "ankle_L" && got.position && got.rotation && !got.mute, "joint or flags differ");
		test::@check(got.at == pin.at && got.from == 0.1f && got.to == 0.9f && got.blend == 0.15f, "at or window differ");
		test::@check(math::abs(got.orient.v.dot(pin.orient.v)) > 0.99999f, "orient differs");
	}

	// A version 23 file has no pins and reads as a clip with none.
	String old = bare.replace(mem, `"version": 24`, `"version": 23`);
	defer old.free(mem);
	AnimTemplate[]? older = crig::parse_session_clips(mem, old);
	if (catch fault error = older)
	{
		test::@check(false, "a version 23 session was refused: %s", error);
		return;
	}
	AnimTemplate[] clips = older;
	defer crig::free_animations(mem, clips);
	test::@check(clips.len == 1 && clips[0].pins.len == 0, "a version 23 clip came back with pins");
	crig::RigDocument? opened = crig::parse_session(mem, old);
	if (catch opened)
	{
		test::@check(false, "a version 23 session was refused");
		return;
	}
	crig::RigDocument doc = opened;
	doc.free();
}

fn void export_bakes_the_pin_into_keys_and_leaves_none() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	p.pin(p.hold_ankle(0.0f, 1.0f, 0.0f));
	crig::AnimTemplate clip = *p.app.clip(p.ref);
	rig::Skeleton* skeleton = &p.view.skeleton;

	// The packed clip: pins written into keys, none left.
	crig::AnimTemplate flat = crig::clip_aims_flattened(mem, clip, skeleton, p.names);
	defer flat.free(mem);
	test::@check(flat.pins.len == 0 && clip.pins.len == 1, "flattening left pins or took them off its source");
	test::@check(!flat.plays_live_layers(), "the flattened clip still plays live layers");
	float[5] times = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	foreach (time : times)
	{
		rig::Pose baked = flat.pose(mem, skeleton, p.names, time, false, honor_solo: false);
		defer baked.free(mem);
		float off = (joint_position(skeleton, baked, p.ankle) - p.rest * p.height).length() / p.height;
		test::@check(off < 0.005f, "the flattened ankle is %.4f heights off at %s", off, time);
	}

	// The written file's curves reproduce the held foot.
	crig::AnimTemplate[1] source = { clip };
	gltf_edit::ReskinClip[] written = crig::reskin_clips(mem, skeleton, p.names, source[..]);
	defer crig::free_reskin_clips(mem, written);
	test::@check(written.len == 1 && written[0].times.len > clip.keyframes.len, "a pinned clip was not baked denser than its keys");
	if (written.len != 1) return;
	usz knee = joint_named(p.names, "knee_L");
	usz thigh = joint_named(p.names, "thigh_L");
	foreach (usz limb : (usz[2]){ knee, thigh })
	{
		gltf_edit::ReskinCurve* curve = null;
		foreach (&held : written[0].curves) if (held.joint == limb) curve = held;
		test::@check(curve != null && curve.turns.len == written[0].times.len, "the pinned limb joint %d has no sampled channel", limb);
		if (!curve || curve.turns.len != written[0].times.len) continue;
		foreach (usz k, time : written[0].times)
		{
			rig::Pose want = clip.pose(mem, skeleton, p.names, time, false, honor_solo: false);
			defer want.free(mem);
			crig::pin_pose(mem, skeleton, p.names, clip.pins, time, clip.duration, clip.loop, &want, p.height);
			test::@check(closeness(curve.turns[k], want.rotations[limb]) > 0.9999f, "the exported joint %d differs from the held pose at %s", limb, time);
		}
	}

	// A muted pin bakes the authored motion: nothing to flatten.
	p.app.clip(p.ref).pins[0].mute = true;
	crig::AnimTemplate quiet = crig::clip_aims_flattened(mem, *p.app.clip(p.ref), skeleton, p.names);
	defer quiet.free(mem);
	test::@check(quiet.pins.len == 0 && quiet.keyframes.len == clip.keyframes.len, "a muted pin was baked");
}

<*
 Motion paths (anim/path.c3): the curve and its timing, the joint held on it
 live, the bake, the sidecar shape and the MCP tool.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::paths`
*>
module crig_tests::paths;

import crig;
import rig;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::math;
import std::math::vector;
import std::math::quaternion;

const String PERSON = "assets/animations/humanoid.glb";

fn AnimPath line_path(bool closed, Vec3[] at, bool sharp)
{
	AnimPath path = { .joint = "wrist_L".copy(mem), .closed = closed };
	path.points = alloc::new_array(mem, AnimPathPoint, (sz)at.len);
	foreach (usz i, point : at) path.points[i] = { .at = point, .sharp = sharp };
	return path;
}

fn void give_slices(AnimPath* path, float[] times, float[] us)
{
	path.slices = alloc::new_array(mem, AnimPathSlice, (sz)times.len);
	foreach (usz i, time : times) path.slices[i] = { .time = time, .u = us[i] };
}

fn bool near(Vec3 a, Vec3 b, float tolerance = 1.0e-3f) => (a - b).length() < tolerance;

<*
 Between two sharp points the curve is the straight line, and the joint moves
 along it at a steady speed between two slices.
*>
fn void a_straight_path_is_walked_at_a_steady_speed() @test
{
	Vec3[2] ends = { { 0, 0, 0 }, { 1, 0, 0 } };
	AnimPath path = line_path(false, ends[..], true);
	defer path.free(mem);
	float[2] times = { 0.0f, 1.0f };
	float[2] us = { 0.0f, 1.0f };
	give_slices(&path, times[..], us[..]);
	for (float t = 0.0f; t <= 1.0f; t += 0.125f)
	{
		Vec3 at = path.held_at(t, 1.0f, false);
		test::@check(near(at, { t, 0, 0 }), "at %ss the joint is at %s, not %s along", t, at, t);
	}
	// Past the last slice of an open path it waits there.
	test::@check(near(path.held_at(2.0f, 3.0f, false), { 1, 0, 0 }), "the joint left the end of the path");
}

<*
 A smooth curve runs through every one of its points, and the joint is at each
 at the time of the slice laid on it.
*>
fn void a_curve_runs_through_its_points() @test
{
	Vec3[4] at = { { 0, 0, 0 }, { 1, 1, 0 }, { 2, 0, 0 }, { 3, 1, 0 } };
	AnimPath path = line_path(false, at[..], false);
	defer path.free(mem);
	float[] lengths = path.length_table(mem);
	defer alloc::free(mem, lengths);
	float total = lengths[^1];
	foreach (usz i, point : at)
	{
		float u = lengths[i * crig::PATH_STEPS] / total;
		test::@check(near(path.at_fraction(u), point), "the curve misses point %d", i);
		test::@check(math::abs(path.nearest_fraction(point) - u) < 0.01f, "point %d is not found where it is", i);
	}
}

<*
 A closed path on a looping clip runs on from its last slice into its first,
 forward round the curve rather than back along it.
*>
fn void a_closed_path_runs_on_through_its_start() @test
{
	Vec3[4] square = { { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, 1 }, { 0, 0, 1 } };
	AnimPath path = line_path(true, square[..], true);
	defer path.free(mem);
	float[2] times = { 0.0f, 0.5f };
	float[2] us = { 0.0f, 0.5f };
	give_slices(&path, times[..], us[..]);
	test::@check(math::abs(path.fraction_at(0.75f, 1.0f, true) - 0.75f) < 1.0e-4f, "the loop did not run forward through the start");
	test::@check(near(path.held_at(0.75f, 1.0f, true), { 0, 0, 1 }), "three quarters round the square is not its last corner");
	test::@check(near(path.held_at(1.0f, 1.0f, true), { 0, 0, 0 }), "the loop does not close at its start");
}

struct Person
{
	rig::TriMesh mesh;
	crig::AppState app;
	crig::AnimRef ref;
	crig::RigView view;
	usz hand;
	float height;
}

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
	self.ref = self.app.new_clip("Reach", 1.0f, from_rest: true);
	self.app.editing = self.ref;
	foreach (usz i, name : self.view.names) if (name == "wrist_L") self.hand = i;
	return self.ref.valid();
}

fn void Person.close(&self)
{
	self.view.free(mem);
	self.app.free();
	self.mesh.free(mem);
}

fn Vec3 Person.hand_at(&self, float time, AnimTemplate clip)
{
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &self.view, clip, self.ref, time, false, true);
	defer pose.free(mem);
	Matrix4f[] palette = rig::joint_palette(mem, &self.view.skeleton, pose)!!;
	defer alloc::free(mem, palette);
	return self.view.skeleton.joints[self.hand].transform(palette[self.hand]);
}

// A small arc in front of the hand's rest place, out and back over the second.
fn AnimPath Person.arc(&self)
{
	Vec3 rest = self.view.skeleton.joints[self.hand] / self.height;
	Vec3[3] at = { rest + (Vec3){ 0, 0.02f, 0.04f }, rest + (Vec3){ 0, 0.05f, 0.07f }, rest + (Vec3){ 0, 0.08f, 0.04f } };
	AnimPath path = line_path(false, at[..], false);
	float[3] times = { 0.0f, 0.5f, 1.0f };
	float[3] us = { 0.0f, 0.5f, 1.0f };
	give_slices(&path, times[..], us[..]);
	return path;
}

<*
 The hand follows its path wherever the clip is shown: the arm bends to put it on
 the curve, at the point the slices say.
*>
fn void the_joint_follows_its_path_live() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	AnimPath arc = p.arc();
	defer arc.free(mem);
	test::@check(p.app.add_path(p.ref, arc.copy(mem)) == 0, "the path would not land");
	p.ref = p.app.editing;
	AnimTemplate* clip = p.app.clip(p.ref);
	test::@check(clip.plays_paths() && clip.plays_live_layers(), "the path does not play");
	for (float t = 0.0f; t <= 1.0f; t += 0.25f)
	{
		Vec3 want = arc.held_at(t, 1.0f, clip.loop) * p.height;
		float miss = (p.hand_at(t, *clip) - want).length() / p.height;
		test::@check(miss < 0.01f, "the hand is %.4f heights off its path at %ss", miss, t);
	}
	// Muted, the keys come back.
	AnimTemplate quiet = *clip;
	quiet.paths = {};
	test::@check((p.hand_at(0.5f, quiet) - arc.held_at(0.5f, 1.0f, false) * p.height).length() / p.height > 0.03f,
		"the hand is on its path without the path");
	test::@check(p.app.undo() && p.app.clip(p.ref).paths.len == 0, "one undo did not take the path off");
}

fn float turn_angle(Quaternionf a, Quaternionf b)
{
	float dot = math::min(math::abs(a.normalize().v.dot(b.normalize().v)), 1.0f);
	return 2.0f * math::acos(dot);
}

fn Quaternionf Person.hand_facing(&self, float time, AnimTemplate clip)
{
	rig::Pose pose = self.app.evaluated_clip_pose(mem, &self.view, clip, self.ref, time, false, true);
	defer pose.free(mem);
	Quaternionf[] world = pose.world_rotations(mem, &self.view.skeleton)!!;
	defer alloc::free(mem, world);
	return world[self.hand];
}

<*
 The curve's turn: none at its start, a quarter turn by the end of a quarter
 circle, and a closed curve, however it winds, comes round as it set off.
*>
fn void a_curve_turns_as_it_bends() @test
{
	Vec3[5] quarter;
	foreach (usz i, &at : quarter)
	{
		float a = (float)math::PI * 0.5f * (float)i / 4.0f;
		*at = { math::cos(a), math::sin(a), 0 };
	}
	AnimPath path = line_path(false, quarter[..], false);
	defer path.free(mem);
	test::@check(turn_angle(path.turn_at(0.0f), quaternion::IDENTITY) < 0.02f, "the curve has turned at its start");
	// As far as the curve's own ends point apart: a quarter turn less the bit its
	// end spans lean in by.
	Vec3 leaving = path.at_fraction(0.01f) - path.at_fraction(0.0f);
	Vec3 arriving = path.at_fraction(1.0f) - path.at_fraction(0.99f);
	float ends = math::acos(leaving.normalize().dot(arriving.normalize()));
	float angle = turn_angle(path.turn_at(1.0f), quaternion::IDENTITY);
	test::@check(ends > 1.0f && math::abs(angle - ends) < 0.05f, "the curve turned %s rad where its ends point %s apart", angle, ends);
	Vec3 carried = path.turn_at(1.0f).rotate_vec3(leaving.normalize());
	test::@check((carried - arriving.normalize()).length() < 0.05f, "the turn does not carry the start's direction onto the end's");

	// A closed curve that climbs and falls as it goes round: twisted along the
	// way, untwisted where it closes.
	Vec3[6] ring;
	foreach (usz i, &at : ring)
	{
		float a = (float)math::PI * 2.0f * (float)i / 6.0f;
		*at = { math::cos(a), 0.6f * math::sin(2.0f * a), math::sin(a) };
	}
	AnimPath closed = line_path(true, ring[..], false);
	defer closed.free(mem);
	test::@check(turn_angle(closed.turn_at(0.999f), closed.turn_at(0.0f)) < 0.05f, "the closed curve jumps where it closes");
	test::@check(turn_angle(closed.turn_at(0.5f), quaternion::IDENTITY) > 1.0f, "half way round the loop it has not turned");

	// Half way round a flat circle it faces back the way it set off.
	Vec3[8] circle;
	foreach (usz i, &at : circle)
	{
		float a = (float)math::PI * 2.0f * (float)i / 8.0f;
		*at = { math::cos(a), 0, math::sin(a) };
	}
	AnimPath round = line_path(true, circle[..], false);
	defer round.free(mem);
	float half = turn_angle(round.turn_at(0.5f), quaternion::IDENTITY);
	test::@check(math::abs(half - (float)math::PI) < 0.05f, "half way round a circle turned %s rad, not half a turn", half);
}

<*
 A path that follows turns the hand with the curve: it keeps the facing its keys
 give it, turned by the curve's turn, where without follow it rides the forearm.
 A gentle arc, so the turn stays inside what the wrist's limits allow.
*>
fn void a_following_path_turns_the_joint() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	AnimPath arc = p.arc();
	arc.points[1].at.z -= 0.02f;
	defer arc.free(mem);
	AnimPath following = arc.copy(mem);
	following.follow = true;
	test::@check(p.app.add_path(p.ref, following) == 0, "the path would not land");
	p.ref = p.app.editing;
	AnimTemplate* clip = p.app.clip(p.ref);
	AnimTemplate keyed = *clip;
	keyed.paths = {};
	for (float t = 0.0f; t <= 1.0f; t += 0.25f)
	{
		Quaternionf want = arc.turn_at(arc.fraction_at(t, 1.0f, clip.loop)).mul(p.hand_facing(t, keyed)).normalize();
		float miss = turn_angle(p.hand_facing(t, *clip), want);
		test::@check(miss < 0.02f, "at %ss the hand faces %s rad off the curve's turn", t, miss);
		float reach = (p.hand_at(t, *clip) - arc.held_at(t, 1.0f, clip.loop) * p.height).length() / p.height;
		test::@check(reach < 0.01f, "following, the hand is %.4f heights off its path at %ss", reach, t);
	}
	test::@check(turn_angle(p.hand_facing(0.75f, *clip), p.hand_facing(0.0f, *clip)) > 0.25f, "the hand did not turn with the arc");
}

<*
 Baked, the hand moves through the same places on plain keys, and the clip has no
 path left.
*>
fn void a_baked_path_plays_as_it_did_live() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	AnimPath arc = p.arc();
	defer arc.free(mem);
	p.app.add_path(p.ref, arc.copy(mem));
	p.ref = p.app.editing;
	Vec3[5] live;
	foreach (usz i, &at : live) *at = p.hand_at((float)i * 0.25f, *p.app.clip(p.ref));
	test::@check(p.app.bake_paths(p.ref)!!, "the bake did not land");
	p.ref = p.app.editing;
	AnimTemplate* baked = p.app.clip(p.ref);
	test::@check(baked.paths.len == 0, "the bake left the path on");
	foreach (usz i, at : live)
	{
		float miss = (p.hand_at((float)i * 0.25f, *baked) - at).length() / p.height;
		test::@check(miss < 0.005f, "the baked hand is %.4f heights from the live one at %ss", miss, (float)i * 0.25f);
	}
}

<*
 A path made from the joint's own motion leaves the motion as it was.
*>
fn void a_path_from_motion_keeps_the_motion() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	AnimPath arc = p.arc();
	p.app.add_path(p.ref, arc);
	p.ref = p.app.editing;
	// The moving hand, baked, as the motion to follow.
	p.app.bake_paths(p.ref)!!;
	p.ref = p.app.editing;
	Vec3 before = p.hand_at(0.4f, *p.app.clip(p.ref));
	AnimPath made = p.app.path_from_motion(p.ref, "wrist_L")!!;
	test::@check(made.points.len >= 8 && made.slices.len == made.points.len, "from motion made %d points", made.points.len);
	p.app.add_path(p.ref, made);
	p.ref = p.app.editing;
	float moved = (p.hand_at(0.4f, *p.app.clip(p.ref)) - before).length() / p.height;
	test::@check(moved < 0.01f, "following its own motion moved the hand %.4f heights", moved);
}

<*
 The path survives the JSON the sidecar and the wire share.
*>
fn void a_path_round_trips_through_its_json() @test
{
	Vec3[3] at = { { 0, 0, 0 }, { 0.5f, 0.25f, 0 }, { 1, 0, 0.125f } };
	AnimPath path = line_path(true, at[..], false);
	defer path.free(mem);
	path.points[1].sharp = true;
	path.from = 0.25f;
	path.to = 0.75f;
	path.blend = 0.125f;
	path.generated = true;
	path.follow = true;
	float[2] times = { 0.5f, 0.0f };
	float[2] us = { 0.75f, 0.25f };
	give_slices(&path, times[..], us[..]);
	path.slices[0].tag = UP;
	DString text = dstring::new(mem);
	defer text.free();
	text.append_char('{');
	crig::append_path_fields(&text, &path);
	text.append_char('}');
	Object* parsed = json::parse(mem, text.str_view())!!;
	defer parsed.free();
	AnimPath back;
	defer back.free(mem);
	test::@check(crig::read_path_fields(parsed, mem, &back, null), "the path did not read back: %s", text);
	test::@check(back.follow, "follow did not round trip: %s", text);
	test::@check(back.joint == "wrist_L" && back.closed && back.generated && back.points.len == 3 && back.points[1].sharp
		&& back.from == 0.25f && back.to == 0.75f && back.blend == 0.125f, "the path's fields did not round trip: %s", text);
	// Read back in time order.
	test::@check(back.slices.len == 2 && back.slices[0].time == 0.0f && back.slices[1].tag == UP, "the slices did not round trip: %s", text);
}

fn String call(crig::AppState* app, String text, bool* ok)
{
	Object* args = json::parse(mem, text)!!;
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? out = crig::set_path_json(app, args, &detail);
	if (catch out)
	{
		*ok = false;
		return detail.copy_str(mem);
	}
	*ok = true;
	return out;
}

fn void set_path_adds_bakes_and_refuses_a_stranger() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	bool ok;
	String added = call(&p.app, `{"op":"add","path":{"joint":"wrist_L","points":[{"at":[0.2,0.9,0.1]},{"at":[0.25,1.0,0.15]}],"slices":[{"time":0,"u":0},{"time":1,"u":1}]}}`, &ok);
	defer added.free(mem);
	test::@check(ok && added.contains(`"joint":"wrist_L"`), "add refused: %s", added);
	String stranger = call(&p.app, `{"op":"add","path":{"joint":"tentacle","points":[{"at":[0,1,0]}],"slices":[{"time":0,"u":0}]}}`, &ok);
	defer stranger.free(mem);
	test::@check(!ok && stranger.contains("tentacle"), "a joint the rig lacks was taken: %s", stranger);
	String baked = call(&p.app, `{"op":"bake"}`, &ok);
	defer baked.free(mem);
	test::@check(ok && p.app.clip(p.app.editing).paths.len == 0, "bake refused or left the path: %s", baked);
}

<*
 Baked, a following path keeps the hand's turn on plain keys.
*>
fn void a_baked_following_path_keeps_its_turn() @test
{
	Person p;
	if (!p.open()) return;
	defer p.close();
	AnimPath arc = p.arc();
	arc.points[1].at.z -= 0.02f;
	arc.follow = true;
	p.app.add_path(p.ref, arc);
	p.ref = p.app.editing;
	Quaternionf[4] live;
	foreach (usz i, &q : live) *q = p.hand_facing((float)i * 0.25f, *p.app.clip(p.ref));
	test::@check(p.app.bake_paths(p.ref)!!, "the bake did not land");
	p.ref = p.app.editing;
	foreach (usz i, q : live)
	{
		float miss = turn_angle(p.hand_facing((float)i * 0.25f, *p.app.clip(p.ref)), q);
		test::@check(miss < 0.03f, "the baked hand faces %s rad from the live one at %ss", miss, (float)i * 0.25f);
	}
}

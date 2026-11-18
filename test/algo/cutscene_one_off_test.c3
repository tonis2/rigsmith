<*
 One-off clips: carried from the rig they were made on into the level's joint
 frames, baked with only the joints they key, written as glTF animations on stub
 nodes the way three.c3's own fixture lays them out, read back, and named in the
 problems list.

     `c3c test --test-filter crig_tests::cutscene_one_off`
*>
module crig_tests::cutscene_one_off;

import crig;
import rig;
import gltf_edit;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::io::file;
import std::io::path;
import std::math;
import std::math::vector;
import std::math::quaternion;

const String FOLDER @local = "build/cutscene-one-off";

fn bool near(float a, float b, float eps = 1e-5f) @local => math::abs(a - b) <= eps;

fn Quaternionf yaw(float degrees) @local
{
	float half = degrees * (float)math::PI / 360.0f;
	return { .v = { 0.0f, math::sin(half), 0.0f, math::cos(half) } };
}

// A rig of three joints as a file holds it at rest: hips over the origin, a spine, an arm.
fn JointRest[] own_rig() @local
{
	JointRest[] rig = alloc::new_array(mem, JointRest, 3);
	rig[0] = { "hips", "", { 0.005f, 0.554f, 0.150f }, quaternion::IDENTITY, { 1, 1, 1 } };
	rig[1] = { "spine", "hips", { 0.0014f, 0.0555f, 0.0074f }, quaternion::IDENTITY, { 1, 1, 1 } };
	rig[2] = { "arm", "spine", { 0.1f, 0.0f, 0.0f }, quaternion::IDENTITY, { 1, 1, 1 } };
	return rig;
}

// The same rig as a level exported it: its origin at the hips, and a socket the own file lacks.
fn JointRest[] level_rig() @local
{
	JointRest[] rig = alloc::new_array(mem, JointRest, 4);
	rig[0] = { "hips", "", { 0.004f, -0.035f, 0.061f }, quaternion::IDENTITY, { 1, 1, 1 } };
	rig[1] = { "spine", "hips", { 0.0014f, 0.0555f, 0.0074f }, quaternion::IDENTITY, { 1, 1, 1 } };
	rig[2] = { "arm", "spine", { 0.1f, 0.0f, 0.0f }, quaternion::IDENTITY, { 1, 1, 1 } };
	rig[3] = { "socket", "arm", { 0.05f, 0.0f, 0.0f }, quaternion::IDENTITY, { 1, 1, 1 } };
	return rig;
}

fn CutChannel channel(String bone, CutChannelPath path, float[] times, float[] values) @local
{
	return { .bone = bone.copy(mem), .path = path, .times = alloc::clone_slice(mem, times),
		.values = alloc::clone_slice(mem, values) };
}

// ---------------------------------------------------------------------------
// Joint frames

fn void a_level_rig_with_its_origin_at_the_hips_takes_the_root_where_it_rests() @test
{
	JointRest[] own = own_rig();
	defer free(own);
	JointRest[] level = level_rig();
	defer free(level);
	RigMismatch m = crig::rigs_agree(own, level);
	test::@check(m.agrees(), "the rigs differ at '%s' (%s)", m.joint, m.kind);

	CutChannel[2] channels = {
		channel("hips", TRANSLATION, { 0.0f, 1.0f }, { 0.005f, 0.554f, 0.150f, 0.005f, 0.604f, 0.150f }),
		channel("arm", ROTATION, { 0.0f, 1.0f }, { 0, 0, 0, 1, 0, 0.7071068f, 0, 0.7071068f }),
	};
	defer foreach (&c : channels) c.free(mem);
	crig::carry_channels(channels[..], own, level);
	// At rest the hips rest where the level's do, and they rise by what the clip lifts them.
	float[6] hips = { 0.004f, -0.035f, 0.061f, 0.004f, 0.015f, 0.061f };
	foreach (usz i, v : hips) test::@check(near(channels[0].values[i], v), "hips value %d is %f, not %f", i, channels[0].values[i], v);
	float[8] arm = { 0, 0, 0, 1, 0, 0.7071068f, 0, 0.7071068f };
	foreach (usz i, v : arm) test::@check(near(channels[1].values[i], v), "a rotation was changed at %d", i);
}

fn void a_rig_that_differs_is_named_and_not_guessed() @test
{
	JointRest[] own = own_rig();
	defer free(own);
	JointRest[] level = level_rig();
	defer free(level);

	// A rest rotation a hair off is the same rig.
	level[0].rotation = yaw(0.2f);
	test::@check(crig::rigs_agree(own, level).agrees(), "a fifth of a degree counts as another rig");

	// Turned round, as a level exported with its hips rotated: refused, at the hips.
	level[0].rotation = yaw(171.0f);
	RigMismatch turned = crig::rigs_agree(own, level);
	test::@check(turned.kind == OTHER_TURN && turned.joint == "hips", "a turned hips is %s at '%s'", turned.kind, turned.joint);
	level[0].rotation = quaternion::IDENTITY;

	level[2].parent = "hips";
	RigMismatch moved = crig::rigs_agree(own, level);
	test::@check(moved.kind == OTHER_PARENT && moved.joint == "arm", "a re-hung arm is %s at '%s'", moved.kind, moved.joint);
	level[2].parent = "spine";

	level[1].scale = { 1.2f, 1.2f, 1.2f };
	test::@check(crig::rigs_agree(own, level).kind == OTHER_SCALE, "a scaled joint passed");
	level[1].scale = { 1, 1, 1 };

	level[2].name = "hand";
	RigMismatch missing = crig::rigs_agree(own, level);
	test::@check(missing.kind == MISSING_JOINT && missing.joint == "arm", "a joint the level lacks is %s at '%s'", missing.kind, missing.joint);
	String said = crig::rig_mismatch_text(mem, missing);
	defer said.free(mem);
	test::@check(said.contains("arm"), "'%s' does not name the joint", said);
}

fn float turn_between(Quaternionf a, Quaternionf b) @local
{
	float d = math::min(math::abs(a.v.dot(b.v)), 1.0f);
	return 2.0f * math::acos(d);
}

<*
 The same rig with other rest rotations, as a level's armature holds the character Rigsmith reads:
 each channel is carried into those frames so the joints turn and slide as they did in the first.
*>
fn void channels_carry_into_a_rig_resting_in_other_joint_frames() @test
{
	JointRest[] own = own_rig();
	defer free(own);
	JointRest[] level = level_rig();
	defer free(level);
	// The hips and the arm rest turned; the arm's offset is in the turned spine's frame.
	Quaternionf hips_rest = yaw(90.0f);
	Quaternionf arm_rest = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI * 0.5f);
	level[0].rotation = hips_rest;
	level[2].rotation = arm_rest;
	level[2].translation = hips_rest.invert().rotate_vec3(own[2].translation);
	test::@check(crig::rigs_agree(own, level).kind == OTHER_TURN, "turned rests pass as the same frames");
	test::@check(crig::rigs_agree(own, level, any_turn: true).agrees(), "the same rig in other frames is refused");

	Quaternionf bend = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.7f);
	CutChannel[2] channels = {
		channel("arm", ROTATION, { 0.0f, 1.0f }, { 0, 0, 0, 1, bend.v.x, bend.v.y, bend.v.z, bend.v.w }),
		channel("hips", TRANSLATION, { 0.0f, 1.0f }, { 0.005f, 0.554f, 0.150f, 0.005f, 0.454f, 0.250f }),
	};
	defer foreach (&c : channels) c.free(mem);
	crig::carry_channels(channels[..], own, level);
	// At rest the arm rests as the level's does; bent, it turns in the world as it did unturned.
	for (usz k = 0; k < 2; k++)
	{
		Quaternionf written = { .v = { channels[0].values[k * 4], channels[0].values[k * 4 + 1], channels[0].values[k * 4 + 2], channels[0].values[k * 4 + 3] } };
		Quaternionf world_delta = hips_rest.mul(written).mul(hips_rest.mul(arm_rest).invert()).normalize();
		Quaternionf made = k == 0 ? (Quaternionf)quaternion::IDENTITY : bend;
		test::@check(turn_between(world_delta, made) < 1e-4f, "key %d turns the arm %f rad off", k, turn_between(world_delta, made));
	}
	// The root has no parent joint: its slide keeps its offset from the rest, in the armature's frame.
	float[6] hips = { 0.004f, -0.035f, 0.061f, 0.004f, -0.135f, 0.161f };
	foreach (usz i, v : hips) test::@check(near(channels[1].values[i], v, 1e-4f), "hips value %d is %f, not %f", i, channels[1].values[i], v);
}

// ---------------------------------------------------------------------------
// The bake

fn void a_baked_one_off_has_channels_only_for_the_joints_it_keys() @test
{
	rig::Skeleton skeleton = {
		.joints = alloc::clone_slice(mem, (Vec3[]){ { 0, 1, 0 }, { 0, 1.2f, 0 }, { 0.3f, 1.4f, 0 } }),
		.parents = alloc::clone_slice(mem, (int[]){ -1, 0, 1 }),
	};
	defer skeleton.free(mem);
	String[3] names = { "hips", "spine", "arm" };
	// The arm raised a quarter turn over a second; nothing else keyed.
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 2);
	keys[0] = { .time = 0.0f, .dots = alloc::clone_slice(mem, (AnimKeyDot[]){ { .joint_name = "arm".copy(mem), .axis = { 0, 0, 1 } } }) };
	keys[1] = { .time = 1.0f, .dots = alloc::clone_slice(mem, (AnimKeyDot[]){ { .joint_name = "arm".copy(mem), .axis = { 0, 0, 1 },
		.angle = (float)math::PI / 2.0f } }) };
	AnimTemplate clip = { .name = "raise".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true };
	defer clip.free(mem);
	clip.compile_tracks(mem);
	CutAnimation baked = crig::bake_one_off(mem, &skeleton, names[..], &clip, 0, "raise");
	defer baked.free(mem);
	test::@check(baked.name == "raise" && baked.channels.len > 0, "nothing baked");
	foreach (&c : baked.channels) test::@check(c.bone == "arm", "a channel on '%s', which the clip does not key", c.bone);
	sz turn = -1;
	foreach (usz i, &c : baked.channels) if (c.path == ROTATION) turn = (sz)i;
	test::@check(turn >= 0, "the arm's turn was not written");
	if (turn < 0) return;
	CutChannel* r = &baked.channels[turn];
	test::@check(near(r.times[0], 0.0f) && near(r.times[^1], 1.0f), "the turn runs %f to %f", r.times[0], r.times[^1]);
	test::@check(near(r.values[^2], 0.7071068f, 1e-4f) && near(r.values[^1], 0.7071068f, 1e-4f), "it ends a quarter turn about z");
	foreach (&c : baked.channels)
	{
		if (c.path != TRANSLATION) continue;
		// The arm's own rest offset from the spine, as the file holds it.
		test::@check(near(c.values[0], 0.3f, 1e-4f) && near(c.values[1], 0.2f, 1e-4f), "the arm slides from its rest");
	}

	// Its rig at rest, as Rigsmith writes it, is the frames the bake is in.
	JointRest[] rests = crig::skeleton_rests(mem, &skeleton, names[..]);
	defer free(rests);
	test::@check(rests[0].parent == "" && rests[2].parent == "spine", "the parents are '%s' and '%s'", rests[0].parent, rests[2].parent);
	test::@check(near(rests[0].translation.y, 1.0f) && near(rests[2].translation.x, 0.3f), "the rest offsets");
}

// ---------------------------------------------------------------------------
// The file

// A cutscene of one actor playing its one-off `trip`, and the one-off baked.
fn Cutscene tripping(CutAnimation* out) @local
{
	Cutscene c = { .name = "Trip".copy(mem), .duration = 4.0f, .fps = 30.0f };
	CutStrip s = crig::cut_strip(PLAY, 1.0f, 2.0f);
	s.clip = "trip".copy(mem);
	s.one_off = true;
	s.animation = 0;
	c.actors = alloc::new_array(mem, CutActor, 1);
	c.actors[0] = { .row = "hero".copy(mem), .home_rotation = quaternion::IDENTITY, .no_level_node = true,
		.strips = alloc::clone_slice(mem, (CutStrip[]){ s }) };
	CutChannel[] channels = alloc::new_array(mem, CutChannel, 2);
	channels[0] = channel("arm", ROTATION, { 0.0f, 0.5f, 1.0f }, { 0, 0, 0, 1, 0, 0, 0.3826834f, 0.9238795f, 0, 0, 0.7071068f, 0.7071068f });
	channels[1] = channel("hips", TRANSLATION, { 0.0f, 1.0f }, { 0, 0.9f, 0, 0, 0.8f, 0.1f });
	*out = { .name = "trip".copy(mem), .actor = 0, .channels = channels };
	return c;
}

fn void check_same_animation(CutAnimation* want, CutAnimation* got, String label) @local
{
	test::@check(got.name == want.name && got.actor == want.actor, "%s: the animation is '%s' on actor %d", label, got.name, got.actor);
	test::@check(got.channels.len == want.channels.len, "%s: %d channels, not %d", label, got.channels.len, want.channels.len);
	if (got.channels.len != want.channels.len) return;
	foreach (usz k, &w : want.channels)
	{
		CutChannel* g = &got.channels[k];
		test::@check(g.bone == w.bone && g.path == w.path, "%s: channel %d is '%s' %s", label, k, g.bone, g.path);
		test::@check(g.times.len == w.times.len && g.values.len == w.values.len, "%s: channel %d has other keys", label, k);
		if (g.times.len != w.times.len || g.values.len != w.values.len) continue;
		foreach (usz i, t : w.times) test::@check(g.times[i] == t, "%s: key time %d moved", label, i);
		foreach (usz i, v : w.values) test::@check(g.values[i] == v, "%s: value %d moved", label, i);
	}
}

fn void a_one_off_is_written_on_stub_nodes_and_reads_back() @test
{
	(void)path::mkdir(FOLDER, true);
	CutAnimation want;
	Cutscene c = tripping(&want);
	defer c.free(mem);
	defer want.free(mem);
	foreach (target : (String[]){ FOLDER.tconcat("/trip.cutscene.glb"), FOLDER.tconcat("/trip.cutscene.gltf") })
	{
		(void)file::delete(target);
		DString why = dstring::new(mem);
		defer why.free();
		if (catch err = crig::write_cutscene_file(target, &c, &why, (CutAnimation[]){ want }))
		{
			test::@check(false, "%s was not written: %s %s", target, err, why.str_view());
			continue;
		}
		CutAnimation[] read;
		Cutscene back = crig::read_cutscene_file(mem, target, &why, &read)!!;
		defer back.free(mem);
		defer crig::free_cut_animations(mem, read);
		test::@check(back.actors[0].strips[0].animation == 0 && back.actors[0].strips[0].one_off && back.actors[0].strips[0].clip == "trip",
			"the strip plays animation %d", back.actors[0].strips[0].animation);
		test::@check(read.len == 1, "%d animations read back", read.len);
		if (read.len == 1) check_same_animation(&want, &read[0], target);

		// The layout three.c3's player binds: the actor's stub node, a child per bone named after it, LINEAR float samplers.
		gltf_edit::GlbParts parts = gltf_edit::split_glb(mem, target)!!;
		defer parts.free(mem);
		Object* doc = json::parse(mem, (String)parts.json)!!;
		defer doc.free();
		Object* actor = doc.get("extensions")!!.get("CUSTOM_cutscene")!!.get("actors")!!.get_at(0);
		long stub = actor.get_long("node")!!;
		Object* nodes = doc.get("nodes")!!;
		test::@check(stub == 0 && nodes.get_at(0).get_string("name")!! == "hero", "the actor's stub is node %d", stub);
		Object* children = nodes.get_at(0).get("children")!!;
		test::@check(children.get_len() == 2 && nodes.get_len() == 3, "the stub has %d bones under it", children.get_len());
		Object* animation = doc.get("animations")!!.get_at(0);
		test::@check(animation.get_string("name")!! == "trip", "the animation is named after its clip");
		Object* channels = animation.get("channels")!!;
		Object* samplers = animation.get("samplers")!!;
		test::@check(channels.get_len() == 2 && samplers.get_len() == 2, "%d channels", channels.get_len());
		for (usz k = 0; k < (usz)channels.get_len(); k++)
		{
			Object* target_of = channels.get_at((sz)k).get("target")!!;
			long node = target_of.get_long("node")!!;
			String bone = nodes.get_at((sz)node).get_string("name")!!;
			bool child = false;
			for (usz n = 0; n < (usz)children.get_len(); n++) child = child || children.get_long_at((sz)n)!! == node;
			test::@check(child && bone == want.channels[k].bone, "channel %d moves node %d '%s', not a bone under the actor", k, node, bone);
			String path_name = target_of.get_string("path")!!;
			test::@check(path_name == (want.channels[k].path == ROTATION ? "rotation" : "translation"), "channel %d's path is %s", k, path_name);
			Object* sampler = samplers.get_at((sz)channels.get_at((sz)k).get_long("sampler")!!);
			test::@check(sampler.get_string("interpolation") ?? "LINEAR" == "LINEAR", "a sampler not LINEAR");
			Object* input = doc.get("accessors")!!.get_at((sz)sampler.get_long("input")!!);
			test::@check(input.get_string("type")!! == "SCALAR" && input.get("min")!!.get_len() == 1 && input.get("max")!!.get_len() == 1,
				"an input accessor without its bounds");
			test::@check(input.get_long("componentType")!! == 5126, "times are not floats");
		}
		Object* buffer = doc.get("buffers")!!.get_at(0);
		if (target.ends_with(".glb"))
		{
			test::@check(member(buffer, "uri") == null && parts.rest.len > 8, "a .glb carries its buffer in its own chunk");
		}
		else
		{
			test::@check((buffer.get_string("uri") ?? "").starts_with("data:application/octet-stream;base64,"), "a .gltf embeds its buffer");
		}
	}
}

fn Object* member(Object* obj, String key) @local
{
	if (try found = obj.get(key)) return found;
	return null;
}

fn void the_engines_own_one_off_reads_the_same_way() @test
{
	CutAnimation[] read;
	Cutscene intro = crig::read_cutscene_file(mem, "assets/cutscenes/intro.cutscene.gltf", null, &read)!!;
	defer intro.free(mem);
	defer crig::free_cut_animations(mem, read);
	test::@check(read.len == 1, "%d animations in the engine's intro", read.len);
	if (read.len != 1) return;
	test::@check(read[0].name == "intro_trip" && read[0].actor == 0, "the intro's one-off is '%s' on actor %d", read[0].name, read[0].actor);
	test::@check(read[0].channels.len == 1 && read[0].channels[0].bone == "arm" && read[0].channels[0].path == TRANSLATION,
		"its one channel moves the arm");
	if (read[0].channels.len == 1)
	{
		test::@check(read[0].channels[0].times.len == 2 && near(read[0].channels[0].times[1], 0.33333334f), "two keys over a third of a second");
	}
	sz strip = -1;
	foreach (usz k, &s : intro.actors[0].strips) if (s.animation == 0) strip = (sz)k;
	test::@check(strip >= 0 && intro.actors[0].strips[strip].one_off && intro.actors[0].strips[strip].clip == "intro_trip", "the strip naming it");
}

fn void a_one_off_that_keys_nothing_or_plays_on_no_actor_is_refused() @test
{
	CutAnimation want;
	Cutscene c = tripping(&want);
	defer c.free(mem);
	defer want.free(mem);
	DString why = dstring::new(mem);
	defer why.free();
	CutAnimation empty = { .name = "trip", .actor = 0 };
	if (try text = crig::cutscene_gltf_text(mem, &c, &why, (CutAnimation[]){ empty }))
	{
		text.free(mem);
		test::@check(false, "a one-off with no channels was written");
	}
	test::@check(why.str_view().contains("keys nothing"), "the refusal is '%s'", why.str_view());

	// A strip naming a one-off the cutscene does not hand over.
	why.clear();
	if (try text = crig::cutscene_gltf_text(mem, &c, &why))
	{
		text.free(mem);
		test::@check(false, "a strip with no animation behind it was written");
	}
	test::@check(why.str_view().contains("'trip'"), "the refusal is '%s'", why.str_view());
}

// ---------------------------------------------------------------------------
// Problems

fn void the_problems_list_names_what_a_one_off_lacks() @test
{
	AnimKeyframe[] keys = alloc::new_array(mem, AnimKeyframe, 1);
	keys[0] = { .time = 0.0f };
	Cutscene c = { .name = "Act".copy(mem), .duration = 5.0f, .fps = 30.0f };
	defer c.free(mem);
	CutStrip gone = crig::cut_strip(PLAY, 0.0f, 1.0f);
	gone.clip = "vanished".copy(mem);
	gone.one_off = true;
	CutStrip plays = crig::cut_strip(PLAY, 1.0f, 2.0f);
	plays.clip = "bow".copy(mem);
	plays.one_off = true;
	c.actors = alloc::new_array(mem, CutActor, 1);
	c.actors[0] = { .row = "hero".copy(mem), .home_rotation = quaternion::IDENTITY, .strips = alloc::clone_slice(mem, (CutStrip[]){ gone, plays }) };
	c.one_offs = alloc::new_array(mem, CutOneOff, 2);
	c.one_offs[0] = { .row = "hero".copy(mem), .clip = { .name = "bow".copy(mem), .duration = 1.0f, .keyframes = keys, .owned = true } };
	c.one_offs[1] = { .row = "hero".copy(mem), .clip = crig::clip_copy(mem, c.one_offs[0].clip, "spare") };

	CutCast[1] cast = { { .found = true, .measured = true, .stands_in = true, .rig_read = true, .rig = { OTHER_TURN, "hips" } } };
	CutProblem[] problems = crig::cutscene_problems(mem, &c, cast[..]);
	defer free(problems);
	bool[6] named;
	foreach (p : problems)
	{
		String text = crig::cut_problem_text(mem, &c, p, cast[..]);
		defer text.free(mem);
		switch (p.kind)
		{
			case ONE_OFF_GONE: named[0] = text.contains("vanished");
			case ONE_OFF_EMPTY: named[1] = text.contains("bow") && text.contains("nothing");
			case ONE_OFF_UNUSED: named[2] = text.contains("spare");
			case ONE_OFF_OTHER_RIG: named[3] = text.contains("another rig") && text.contains("hips");
			case MISSING_CLIP: named[4] = true;
			default: break;
		}
	}
	test::@check(named[0], "a strip playing a one-off that is gone is not named");
	test::@check(named[1], "a one-off that keys nothing is not named");
	test::@check(named[2], "a one-off no strip plays is not named");
	test::@check(named[3], "a one-off made on another rig is not named with the joint");
	test::@check(!named[4], "a one-off strip was taken for a missing clip of the character");

	// The level's rig not read yet, and a level node gone.
	cast[0].rig_read = false;
	cast[0].node_gone = true;
	CutProblem[] again = crig::cutscene_problems(mem, &c, cast[..]);
	defer free(again);
	bool no_rig;
	bool node_gone;
	foreach (p : again)
	{
		no_rig = no_rig || p.kind == ONE_OFF_NO_RIG;
		node_gone = node_gone || p.kind == STAND_IN_GONE;
	}
	test::@check(no_rig && node_gone, "an unread level rig or a gone level node is not named");
}

// ---------------------------------------------------------------------------
// The cross-fade

fn void two_poses_mix_the_short_way_round_and_leave_an_unkeyed_joint_alone() @test
{
	rig::Pose from = rig::rest_pose(mem, 2);
	defer from.free(mem);
	rig::Pose into = rig::rest_pose(mem, 2);
	defer into.free(mem);
	into.rotations[0] = yaw(90.0f);
	into.rotations[1] = yaw(90.0f);
	into.offsets[0] = { 0.0f, 0.2f, 0.0f };
	from.offsets[0] = { 0.0f, -0.2f, 0.0f };

	rig::Pose half = into.copy(mem);
	defer half.free(mem);
	crig::blend_poses(&half, from, 0.5f, { true, false });
	Quaternionf q = half.rotations[0];
	test::@check(near(q.v.y, yaw(45.0f).v.y, 1e-4f) && near(q.v.w, yaw(45.0f).v.w, 1e-4f), "halfway is not 45 degrees");
	test::@check(near(half.offsets[0].y, 0.0f), "the offset is %f, not halfway", half.offsets[0].y);
	test::@check(half.rotations[1].v == from.rotations[1].v, "a joint the incoming clip does not key was mixed");

	rig::Pose start = into.copy(mem);
	defer start.free(mem);
	crig::blend_poses(&start, from, 0.0f);
	test::@check(start.rotations[0].v == from.rotations[0].v && near(start.offsets[0].y, -0.2f), "weight 0 is not the outgoing pose");
	rig::Pose end = into.copy(mem);
	defer end.free(mem);
	crig::blend_poses(&end, from, 1.0f);
	test::@check(near(end.rotations[0].v.y, into.rotations[0].v.y) && near(end.offsets[0].y, 0.2f), "weight 1 is not the incoming pose");

	// The other hemisphere of the same turn mixes the short way.
	rig::Pose flipped = rig::rest_pose(mem, 2);
	defer flipped.free(mem);
	flipped.rotations[0] = { .v = -yaw(20.0f).v };
	crig::blend_poses(&flipped, from, 0.5f);
	test::@check(math::abs(crig::cut_heading_of(flipped.rotations[0])) < 0.2, "a flipped quaternion went the long way");
}

fn void a_strip_fades_in_from_the_one_before_as_the_player_plays_it() @test
{
	Cutscene c = { .name = "Fade".copy(mem), .duration = 6.0f, .fps = 30.0f };
	defer c.free(mem);
	CutStrip wave = crig::cut_strip(PLAY, 0.0f, 1.0f);
	wave.clip = "wave".copy(mem);
	CutStrip bow = crig::cut_strip(PLAY, 2.0f, 3.0f);
	bow.clip = "bow".copy(mem);
	bow.fade = 0.5f;
	CutStrip wait = crig::cut_strip(PLAY, 3.0f, 4.0f);
	wait.clip = "idle".copy(mem);
	wait.fade = 0.4f;
	wait.loop = true;
	c.actors = alloc::new_array(mem, CutActor, 1);
	c.actors[0] = { .row = "hero".copy(mem), .home_rotation = quaternion::IDENTITY, .strips = alloc::clone_slice(mem, (CutStrip[]){ wave, bow, wait }) };
	CutCurve[] curves = crig::cutscene_curves(mem, &c);
	defer crig::free_cut_curves(mem, curves);

	// Into the bow from the wave held on its last frame since 1 s: a quarter in at 2.25 s.
	CutActorPose at = crig::cutscene_actor_shown(&c, curves, 0, 2.25f);
	CutFade fade = crig::cutscene_actor_fade(&c, curves, 0, 2.25f, at);
	test::@check(fade.strip == 0 && near(fade.clip_time, 1.0f) && near(fade.weight, 0.5f), "the fade is from %d at %f, %f in", fade.strip, fade.clip_time, fade.weight);
	CutActorPose later = crig::cutscene_actor_shown(&c, curves, 0, 2.6f);
	test::@check(crig::cutscene_actor_fade(&c, curves, 0, 2.6f, later).strip < 0, "the fade outlasts its length");

	// Out of the bow as it ends into the idle: it was still playing, so it plays on through the fade.
	CutActorPose next = crig::cutscene_actor_shown(&c, curves, 0, 3.2f);
	CutFade on = crig::cutscene_actor_fade(&c, curves, 0, 3.2f, next);
	test::@check(on.strip == 1 && near(on.weight, 0.5f), "the idle fades from %d, %f in", on.strip, on.weight);
	test::@check(on.clip_time > 1.0f, "the bow stopped at %f instead of playing on", on.clip_time);

	// No fade before the first strip has anything to fade from.
	CutActorPose first = crig::cutscene_actor_shown(&c, curves, 0, 0.1f);
	test::@check(crig::cutscene_actor_fade(&c, curves, 0, 0.1f, first).strip < 0, "the first strip fades from nothing");
}

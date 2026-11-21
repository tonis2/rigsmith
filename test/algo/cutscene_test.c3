<*
 Cutscenes: the model, the pose at a time and the CUSTOM_cutscene file. The pose
 checks are the numbers three.c3's cutscene_test.c3 asserts on its own files,
 copied into assets/cutscenes; there `walk` is 1 s long and `wave` 0.5 s.
*>
module crig_tests::cutscene;

import crig;
import gltf_edit;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::vector;
import std::math::quaternion;

const String FIXTURES @local = "assets/cutscenes/";
const String FOLDER @local = "build/cutscene-test";

fn double deg(double degrees) @local => degrees * math::PI / 180.0;

fn Quaternionf yaw_deg(double degrees) @local
{
	double half = deg(degrees) / 2.0;
	return { .v = { 0.0f, (float)math::sin(half), 0.0f, (float)math::cos(half) } };
}

// Whole degrees the rotation faces about +Y, 0 at +Z.
fn long facing(CutActorPose pose) @local
{
	return (long)math::round(crig::cut_heading_of(pose.rotation) * 180.0 / math::PI) + 0;
}

fn double round2(double value) @local => math::round(value * 100.0) / 100.0;

fn CutStrip strip(CutStripKind kind, float start, float end, String clip = "") @local
{
	CutStrip s = crig::cut_strip(kind, start, end);
	if (clip.len > 0) s.clip = clip.copy(mem);
	return s;
}

fn CutStrip move_on(int path, float start, float end, CutEase ease = LINEAR, bool turn = true) @local
{
	CutStrip s = crig::cut_strip(MOVE, start, end);
	s.path = path;
	s.ease = ease;
	s.turn = turn;
	return s;
}

fn CutStrip turn_to_point(float start, float end, Vec3 point, CutEase ease = LINEAR) @local
{
	CutStrip s = crig::cut_strip(TURN, start, end);
	s.target = point;
	s.ease = ease;
	return s;
}

fn CutStrip turn_to_actor(float start, float end, String row, CutEase ease = LINEAR) @local
{
	CutStrip s = crig::cut_strip(TURN, start, end);
	s.target_row = row.copy(mem);
	s.ease = ease;
	return s;
}

fn CutActor actor(String row, CutStrip[] strips, Quaternionf rotation = quaternion::IDENTITY, Vec3 home = {}) @local
{
	return {
		.row = row.copy(mem),
		.home = home,
		.home_rotation = rotation,
		.strips = strips.len > 0 ? alloc::clone_slice(mem, strips) : {},
	};
}

// A path whose points are given as they are, as three.c3's tests give a move's path.
fn WalkPath given_path(Vec3[] points) @local
{
	return { .name = "Given".copy(mem), .points = alloc::clone_slice(mem, points) };
}

fn WalkPath walked_path(String name, Vec3[] knots) @local
{
	WalkPath path = { .name = name.copy(mem), .knots = alloc::clone_slice(mem, knots) };
	path.resample(mem);
	return path;
}

fn Cutscene cutscene(CutActor[] actors, WalkPath[] paths = {}, float duration = 10.0f) @local
{
	return {
		.name = "test".copy(mem),
		.duration = duration,
		.fps = 24.0f,
		.actors = actors.len > 0 ? alloc::clone_slice(mem, actors) : {},
		.paths = paths.len > 0 ? alloc::clone_slice(mem, paths) : {},
	};
}

fn CutActorPose pose_of(Cutscene* scene, usz actor, float t) @local
{
	CutActorPose[] all = crig::cutscene_pose_at(mem, scene, t);
	defer free(all);
	return all[actor];
}

fn Cutscene read_fixture(String name) @local
{
	DString why = dstring::new(mem);
	defer why.free();
	Cutscene? read = crig::read_cutscene_file(mem, FIXTURES.tconcat(name), &why);
	if (catch err = read)
	{
		test::@check(false, "%s did not read: %s, %s", name, err, why);
		return {};
	}
	return read;
}

// The order the file keeps the strips in: by start, ties as given.
fn usz[] sorted_order(CutStrip[] strips) @local
{
	usz[] order = mem::new_array(usz, (sz)strips.len);
	for (usz i = 0; i < strips.len; i++)
	{
		usz k = i;
		while (k > 0 && strips[order[k - 1]].start > strips[i].start)
		{
			order[k] = order[k - 1];
			k--;
		}
		order[k] = i;
	}
	return order;
}

fn void check_same_strip(CutStrip* want, CutStrip* got, String where) @local
{
	test::@check(got.kind == want.kind, "%s: kind %s, not %s", where, got.kind, want.kind);
	test::@check(math::is_approx(got.start, want.start, 1e-4) && math::is_approx(got.end, want.end, 1e-4), "%s: %s..%s, not %s..%s",
		where, got.start, got.end, want.start, want.end);
	switch (want.kind)
	{
		case MOVE:
			test::@check(got.path == want.path && got.ease == want.ease && got.turn == want.turn,
				"%s: path %d %s turn %s", where, got.path, got.ease, got.turn);
		case TURN:
			test::@check(got.ease == want.ease && got.target_row == want.target_row, "%s: %s toward '%s'", where, got.ease, got.target_row);
			test::@check((got.target - want.target).length() < 1e-4f, "%s: faces %s, not %s", where, got.target, want.target);
			test::@check(got.clip.len == 0 && got.animation == -1, "%s: a turn reads back with a clip", where);
		case PLAY:
	}
	if (want.kind == TURN || want.clip.len == 0) return;
	test::@check(got.clip == want.clip && got.loop == want.loop && got.animation == want.animation,
		"%s: clip '%s' loop %s animation %d", where, got.clip, got.loop, got.animation);
	test::@check(math::is_approx(got.speed, want.speed, 1e-4) && math::is_approx(got.fade, want.fade, 1e-4) && math::is_approx(got.offset, want.offset, 1e-4),
		"%s: speed %s fade %s offset %s", where, got.speed, got.fade, got.offset);
}

// What the file keeps of `want`: everything but the knots, and the home of an actor the level places.
fn void check_same(Cutscene* want, Cutscene* got, String label) @local
{
	test::@check(got.name == want.name && math::is_approx(got.duration, want.duration, 1e-4) && math::is_approx(got.fps, want.fps, 1e-4),
		"%s: '%s' %s s at %s fps", label, got.name, got.duration, got.fps);
	test::@check(got.actors.len == want.actors.len, "%s: %d actors", label, got.actors.len);
	if (got.actors.len != want.actors.len) return;
	foreach (usz i, &a : want.actors)
	{
		CutActor* b = &got.actors[i];
		test::@check(b.row == a.row && b.uid == a.uid && b.no_level_node == a.no_level_node,
			"%s: actor %d is '%s' '%s' %s", label, i, b.row, b.uid, b.no_level_node);
		Vec3 home = a.no_level_node ? a.home : {};
		Quaternionf rotation = a.no_level_node ? a.home_rotation : quaternion::IDENTITY;
		test::@check((b.home - home).length() < 1e-4f, "%s: actor %d home %s", label, i, b.home);
		test::@check((b.home_rotation.v - rotation.v).length() < 1e-6f, "%s: actor %d rotation %s", label, i, b.home_rotation);
		test::@check(b.strips.len == a.strips.len, "%s: actor %d has %d strips", label, i, b.strips.len);
		if (b.strips.len != a.strips.len) continue;
		usz[] order = sorted_order(a.strips);
		defer free(order);
		foreach (usz k, at : order)
		{
			check_same_strip(&a.strips[at], &b.strips[k], string::tformat("%s: actors[%d].strips[%d]", label, i, k));
		}
	}
	test::@check(got.paths.len == want.paths.len, "%s: %d paths", label, got.paths.len);
	if (got.paths.len != want.paths.len) return;
	foreach (usz i, &a : want.paths)
	{
		WalkPath* b = &got.paths[i];
		test::@check(b.name == a.name && math::is_approx(b.length, a.length, 1e-4) && b.points.len == a.points.len && b.knots.len == 0,
			"%s: path %d '%s' %s m, %d points", label, i, b.name, b.length, b.points.len);
		if (b.points.len != a.points.len) continue;
		foreach (usz k, point : a.points)
		{
			test::@check((b.points[k] - point).length() < 1e-4f, "%s: path %d point %d is %s", label, i, k, b.points[k]);
		}
	}
}

// Every strip kind, an actor with no level node, a turn to an actor, and strips
// given out of order, two starting together.
fn Cutscene everything() @local
{
	WalkPath[2] paths = {
		walked_path("Walk Path", { { 0, 0, 0 }, { 3, 0.5f, 1 }, { 6, 0, 0 } }),
		walked_path("Back", { { 6, 0, 0 }, { 6, 0, -4 } }),
	};
	CutStrip wave = strip(PLAY, 6.5f, 8.0f, "wave");
	wave.fade = 0.25f;
	wave.offset = 0.125f;
	CutStrip walk = move_on(0, 0.0f, 3.0f);
	walk.clip = "walk".copy(mem);
	walk.speed = 1.3333f;
	CutStrip idle = strip(PLAY, 3.0f, 3.5f, "Idle.001");
	idle.loop = true;
	CutStrip[5] hero = { wave, walk, turn_to_actor(3.0f, 3.5f, "guard", OUT), move_on(1, 4.0f, 6.5f, IN, false), idle };
	CutStrip[2] guard = { strip(PLAY, 0.0f, 10.0f, "idle"), turn_to_point(1.0f, 2.0f, { 0, 0, 0 }, INOUT) };
	guard[0].loop = true;
	guard[0].speed = 0.5f;
	CutActor[2] actors = {
		actor("hero", hero[..], home: { 1, 0, -2 }),
		actor("guard", guard[..], yaw_deg(90), { 2, 0, 5 }),
	};
	actors[0].uid = "hero-1a2b3c4d".copy(mem);
	actors[1].no_level_node = true;
	Cutscene out = cutscene(actors[..], paths[..], 9.5f);
	out.name.free(mem);
	out.name = "trail head".copy(mem);
	return out;
}

fn void a_cutscene_written_reads_back_the_same() @test
{
	(void)path::mkdir(FOLDER, true);
	Cutscene made = everything();
	defer made.free(mem);
	String[2] files = { FOLDER.tconcat("/trail.cutscene.glb"), FOLDER.tconcat("/trail.cutscene.gltf") };
	foreach (name : files)
	{
		DString why = dstring::new(mem);
		defer why.free();
		crig::write_cutscene_file(name, &made, &why)!!;
		Cutscene read = crig::read_cutscene_file(mem, name, &why)!!;
		defer read.free(mem);
		check_same(&made, &read, name);
		// A cutscene written again from what was read is the same file.
		String again = crig::cutscene_gltf_text(mem, &read)!!;
		defer again.free(mem);
		String first = crig::cutscene_gltf_text(mem, &made)!!;
		defer first.free(mem);
		test::@check(again == first, "%s: written again it differs", name);
	}

	// Version 2, and no buffer without one-off clips: the .glb is one JSON chunk.
	String text = crig::cutscene_gltf_text(mem, &made)!!;
	defer text.free(mem);
	test::@check(text.contains(`"version":2`) && !text.contains("buffers") && !text.contains("animations"),
		"the payload is version 2 with no buffer: %s", text);
	test::@check(text.contains(`"nodes":[{"name":"hero","uid":"hero-1a2b3c4d"},{"name":"guard"}]`),
		"one stub node per actor, named after its row: %s", text);
	test::@check(text.contains(`"place":{"position":[2,0,5],`) && text.count(`"place"`) == 1,
		"only the actor with no level node has a place: %s", text);
	char[] glb = file::load(mem, files[0])!!;
	defer free(glb);
	uint total = (uint)glb[8] | (uint)glb[9] << 8 | (uint)glb[10] << 16 | (uint)glb[11] << 24;
	uint chunk = (uint)glb[12] | (uint)glb[13] << 8 | (uint)glb[14] << 16 | (uint)glb[15] << 24;
	test::@check((String)glb[:4] == "glTF" && (sz)total == glb.len && (sz)chunk + 20 == glb.len,
		"the .glb holds its JSON chunk and nothing after it (%d bytes, chunk %d)", glb.len, chunk);
}

fn void a_copy_owns_everything_it_holds() @test
{
	Cutscene made = everything();
	Cutscene copy = made.copy(mem);
	defer copy.free(mem);
	Cutscene again = everything();
	defer again.free(mem);
	made.free(mem);
	String a = crig::cutscene_gltf_text(mem, &copy)!!;
	defer a.free(mem);
	String b = crig::cutscene_gltf_text(mem, &again)!!;
	defer b.free(mem);
	test::@check(a == b, "the copy outlived its original unchanged");
	test::@check(copy.paths[0].knots.len == 3 && copy.actor_by_row("guard") == 1, "knots and rows are copied");
}

fn void only_the_paths_a_move_walks_are_written() @test
{
	WalkPath[3] paths = {
		given_path({ { 0, 0, 0 }, { 1, 0, 0 } }),
		given_path({ { 0, 0, 0 }, { 0, 0, 1 } }),
		given_path({ { 5, 0, 0 }, { 9, 0, 0 } }),
	};
	CutStrip[1] strips = { move_on(2, 0.0f, 1.0f) };
	CutActor[1] actors = { actor("hero", strips[..]) };
	Cutscene made = cutscene(actors[..], paths[..]);
	defer made.free(mem);
	String text = crig::cutscene_gltf_text(mem, &made)!!;
	defer text.free(mem);
	Cutscene read = crig::parse_cutscene_text(mem, text)!!;
	defer read.free(mem);
	test::@check(read.paths.len == 1 && read.actors[0].strips[0].path == 0 && read.paths[0].points[1].x == 9.0f,
		"the walked path alone, renumbered: %s", text);
}

// Why the writer refuses `scene`, or an empty fault when it writes it.
fn fault refusal(Cutscene* scene, DString* why) @local
{
	why.clear();
	String? text = crig::cutscene_gltf_text(mem, scene, why);
	if (try text)
	{
		text.free(mem);
		return {};
	}
	return @catch(text);
}

fn void what_the_game_would_refuse_is_not_written() @test
{
	DString why = dstring::new(mem);
	defer why.free();

	CutStrip[1] lost = { move_on(3, 0.0f, 1.0f) };
	CutActor[1] walker = { actor("hero", lost[..]) };
	Cutscene missing = cutscene(walker[..]);
	defer missing.free(mem);
	fault err = refusal(&missing, &why);
	test::@check(err == crig::CUTSCENE_MALFORMED && why.str_view().contains("actors[0].strips[0].path is 3"),
		"a move on a missing path: %s, %s", err, why);

	CutStrip[1] trip = { strip(PLAY, 5.0f, 5.5f, "trip") };
	trip[0].animation = 0;
	CutActor[1] tripper = { actor("hero", trip[..]) };
	Cutscene one_off = cutscene(tripper[..]);
	defer one_off.free(mem);
	err = refusal(&one_off, &why);
	test::@check(err == crig::CUTSCENE_MALFORMED && why.str_view().contains("'trip'"),
		"a one-off clip with no animation to write: %s, %s", err, why);

	CutStrip[1] lonely = { turn_to_actor(0.0f, 1.0f, "nobody") };
	CutActor[1] turner = { actor("hero", lonely[..]) };
	Cutscene nobody = cutscene(turner[..]);
	defer nobody.free(mem);
	err = refusal(&nobody, &why);
	test::@check(err == crig::CUTSCENE_MALFORMED && why.str_view().contains("actors[0].strips[0].actor is 'nobody'"),
		"a turn toward a missing actor: %s, %s", err, why);

	CutActor[2] twins = { actor("hero", {}), actor("hero", {}) };
	Cutscene doubled = cutscene(twins[..]);
	defer doubled.free(mem);
	err = refusal(&doubled, &why);
	test::@check(err == crig::CUTSCENE_MALFORMED && why.str_view().contains("are both 'hero'"), "two actors of one row: %s, %s", err, why);

	String name = crig::cutscene_file_name(mem, "trail head/2");
	defer name.free(mem);
	test::@check(name == "trail_head_2.cutscene.glb", "the file name is %s", name);
}

fn void the_engines_intro_file_poses_as_the_engine_does() @test
{
	Cutscene glb = read_fixture("intro.cutscene.glb");
	defer glb.free(mem);
	Cutscene intro = read_fixture("intro.cutscene.gltf");
	defer intro.free(mem);
	check_same(&glb, &intro, "the .gltf against the .glb");

	CutStrip[] strips = intro.actors[0].strips;
	test::@check(intro.duration == 10.0f && intro.actors[0].row == "hero" && intro.actors[0].uid == "hero-5fb42dc6",
		"the cutscene's own fields");
	test::@check(strips.len == 3 && strips[0].kind == MOVE && strips[1].kind == PLAY && strips[2].kind == PLAY, "move, play, play");
	test::@check(intro.paths[0].points.len == 25 && intro.paths[0].points[24] == (Vec3){ 6, 0, 0 }, "the path's 25 points");
	test::@check(strips[2].clip == "intro_trip" && strips[2].animation == 0, "the one-off keeps its animation index");

	// t, x, z, heading, the strip playing, its time with walk's 1 s loop wrapped.
	double[6][8] expected = {
		{ 0.0, 0.0, 0.0, 1.57, 0, 0.0 },
		{ 0.6, 1.2, 0.0, 1.57, 0, 0.8 },
		{ 1.2, 2.4, 0.0, 1.57, 0, 0.6 },
		{ 3.0, 6.0, 0.0, 1.57, 1, 0.0 },
		{ 3.25, 6.0, 0.0, 1.57, 1, 0.25 },
		{ 4.0, 6.0, 0.0, 1.57, 1, 0.5 },
		{ 5.0 + 1.0 / 6.0, 6.0, 0.0, 1.57, 2, 0.17 },
		{ 8.0, 6.0, 0.0, 1.57, 2, 0.33 },
	};
	foreach (row : expected)
	{
		CutActorPose pose = pose_of(&intro, 0, (float)row[0]);
		double time = pose.strip == 0 ? pose.clip_time % 1.0 : pose.clip_time;
		double heading = crig::cut_heading_of(pose.rotation);
		test::@check(round2(pose.position.x) == row[1] && round2(pose.position.z) == row[2] && round2(heading) == row[3],
			"at %s s it stands at %s facing %s", row[0], pose.position, heading);
		test::@check(pose.strip == (int)row[4] && math::is_approx(round2(time), row[5], 1e-9), "at %s s strip %d plays at %s", row[0], pose.strip, time);
	}
	test::@check(pose_of(&intro, 0, 4.0f).holding && !pose_of(&intro, 0, 3.25f).holding, "the wave holds after its end");
	test::@check(math::is_approx(pose_of(&intro, 0, 1.0f).fade, 0.2, 1e-4), "the walk fades in over 0.2 s");
}

fn void a_held_loop_stops_a_hair_before_its_end() @test
{
	Cutscene finer = read_fixture("finer.cutscene.glb");
	defer finer.free(mem);
	// t, the strip, its clip time: wave loops over 0.5 s, walk does not loop.
	double[3][4] expected = { { 1.25, 0, 0.25 }, { 2.5, 0, 0.999 }, { 3.25, 1, 0.5 }, { 4.0, 1, 0.75 } };
	foreach (row : expected)
	{
		CutActorPose pose = pose_of(&finer, 0, (float)row[0]);
		test::@check(pose.strip == (int)row[1] && math::is_approx(pose.clip_time, row[2], 1e-5), "at %s s strip %d at %s", row[0], pose.strip, pose.clip_time);
	}
	// The engine's test reads the held wave as 0.5: 0.999 wrapped by its 0.5 s.
	test::@check(round2(pose_of(&finer, 0, 2.5f).clip_time % 0.5) == 0.5, "the held loop shows its last frame");
}

fn void a_move_walks_by_time_and_keeps_the_lean() @test
{
	WalkPath[1] paths = { given_path({ { 0, 0, 0 }, { 4, 0, 0 } }) };
	CutStrip[1] once = { move_on(0, 0.0f, 2.0f) };
	CutActor[1] walker = { actor("hero", once[..]) };
	Cutscene walk = cutscene(walker[..], paths[..]);
	defer walk.free(mem);
	CutActorPose mid = pose_of(&walk, 0, 1.0f);
	test::@check(round2(mid.position.x) == 2.0 && round2(crig::cut_heading_of(mid.rotation)) == 1.57, "halfway, facing +X");
	test::@check(round2(pose_of(&walk, 0, 2.0f).position.x) == 4.0, "at the end of the path");

	// Turned 92° and leaning 13°, as a tilted armature stands: the moves keep the lean.
	WalkPath[2] legs = { given_path({ { 0, 0, 0 }, { 4, 0, 0 } }), given_path({ { 4, 0, 0 }, { 0, 0, 0 } }) };
	CutStrip[2] both = { move_on(0, 0.0f, 1.0f), move_on(1, 1.0f, 2.0f) };
	CutActor[1] leaner = { actor("hero", both[..], quat_from_euler_xyz(-1.845868, 1.427825, 2.019156)) };
	Cutscene lean = cutscene(leaner[..], legs[..]);
	defer lean.free(mem);
	double[2][2] expected = { { 0.5, 89 }, { 1.5, -91 } };
	foreach (row : expected)
	{
		Quaternionf q = pose_of(&lean, 0, (float)row[0]).rotation;
		double[<3>] up = rotate(q, { 0, 1, 0 });
		double[<3>] forward = rotate(q, { 0, 0, 1 });
		long tilt = (long)math::round(math::acos(math::min(1.0, up.y)) * 180.0 / math::PI);
		long heading = (long)math::round(math::atan2(forward.x, forward.z) * 180.0 / math::PI);
		test::@check(tilt == 13 && heading == (long)row[1], "at %s s it leans %d° heading %d°", row[0], tilt, heading);
	}
}

// three.c3's quatFromEulerXYZ, for the lean its test stands the actor with.
fn Quaternionf quat_from_euler_xyz(double ex, double ey, double ez) @local
{
	double c1 = math::cos(ex / 2);
	double c2 = math::cos(ey / 2);
	double c3 = math::cos(ez / 2);
	double s1 = math::sin(ex / 2);
	double s2 = math::sin(ey / 2);
	double s3 = math::sin(ez / 2);
	return { .v = {
		(float)(s1 * c2 * c3 + c1 * s2 * s3),
		(float)(c1 * s2 * c3 - s1 * c2 * s3),
		(float)(c1 * c2 * s3 + s1 * s2 * c3),
		(float)(c1 * c2 * c3 - s1 * s2 * s3),
	} };
}

fn double[<3>] rotate(Quaternionf q, double[<3>] v) @local
{
	double x = q.v.x;
	double y = q.v.y;
	double z = q.v.z;
	double w = q.v.w;
	double tx = 2 * (y * v.z - z * v.y);
	double ty = 2 * (z * v.x - x * v.z);
	double tz = 2 * (x * v.y - y * v.x);
	return { v.x + w * tx + y * tz - z * ty, v.y + w * ty + z * tx - x * tz, v.z + w * tz + x * ty - y * tx };
}

// A hand-written cutscene file around one CUSTOM_cutscene body, and what else the document holds.
fn String bad_cutscene(String body, String rest = "") @local
{
	return string::tformat(`{"asset":{"version":"2.0"},"nodes":[{"name":"hero"}],%s"extensions":{"CUSTOM_cutscene":%s}}`, rest, body);
}

fn fault read_refusal(String text, DString* why, char[] binary = {}) @local
{
	CutAnimation[] animations;
	Cutscene? read = crig::parse_cutscene_text(mem, text, why, &animations, binary);
	if (try read)
	{
		read.free(mem);
		foreach (&a : animations) a.free(mem);
		if (animations.len > 0) free(animations);
		return {};
	}
	return @catch(read);
}

fn void bad_files_are_refused_with_the_reason() @test
{
	String hero = `{"row":"hero","node":0,`;
	String[3][5] texts = {
		{ bad_cutscene(`{"version":3,"name":"bad","duration":1}`), "version",
			"CUSTOM_cutscene is version 3, and this reads versions 1 and 2" },
		{ bad_cutscene(string::tformat(`{"version":1,"name":"bad","duration":2,"actors":[%s"strips":[{"type":"move","start":0,"end":2,"path":3}]}],"paths":[{"name":"p","length":1,"points":[[0,0,0],[1,0,0]]}]}`, hero)),
			"shape", "actors[0].strips[0].path is 3, and the file has 1 path" },
		{ bad_cutscene(string::tformat(`{"version":1,"name":"bad","duration":1,"actors":[%s"strips":[{"type":"turn","start":0,"end":1,"point":[0,0,1]}]}]}`, hero)),
			"shape", "actors[0].strips[0].type 'turn' needs CUSTOM_cutscene version 2, and the file says version 1" },
		{ bad_cutscene(string::tformat(`{"version":1,"name":"bad","duration":1,"actors":[%s"place":{"position":[0,0,0],"rotation":[0,0,0,1]},"strips":[]}]}`, hero)),
			"shape", "actors[0].place needs CUSTOM_cutscene version 2, and the file says version 1" },
		{ bad_cutscene(string::tformat(`{"version":2,"name":"bad","duration":1,"actors":[%s"strips":[{"type":"turn","start":0,"end":1,"actor":"nobody"}]}]}`, hero)),
			"shape", "actors[0].strips[0].actor is 'nobody', and this cutscene has no actor of that row" },
	};
	foreach (i, row : texts)
	{
		DString why = dstring::new(mem);
		defer why.free();
		fault want = row[1] == "version" ? crig::CUTSCENE_UNKNOWN_VERSION : crig::CUTSCENE_MALFORMED;
		fault kind = read_refusal(row[0], &why);
		test::@check(kind == want && why.str_view().contains(row[2]), "case %d: %s, %s", i, kind, why);
	}

	String[3][2] files = {
		{ "nowhere.cutscene.glb", "is not there", "" },
		{ "../animations/quadruped.glb", "has no CUSTOM_cutscene extension", "" },
	};
	fault[2] wanted = { crig::CUTSCENE_UNREADABLE, crig::CUTSCENE_NOT_A_CUTSCENE };
	foreach (i, row : files)
	{
		DString why = dstring::new(mem);
		defer why.free();
		Cutscene? read = crig::read_cutscene_file(mem, FIXTURES.tconcat(row[0]), &why);
		if (try read)
		{
			read.free(mem);
			test::@check(false, "%s was read", row[0]);
			continue;
		}
		test::@check(@catch(read) == wanted[i] && why.str_view().contains(row[1]), "%s: %s, %s", row[0], @catch(read), why);
	}
}

fn void an_accessor_past_its_buffer_is_refused() @test
{
	char[32] binary;
	String body = `{"version":2,"name":"bad","duration":1,"actors":[{"row":"hero","node":0,"strips":[]}]}`;
	foreach (count : (String[]){ "-1", "4611686018427387904", "7" })
	{
		String rest = string::tformat(`"animations":[{"name":"a","channels":[{"sampler":0,"target":{"node":0,"path":"translation"}}],"samplers":[{"input":0,"output":1}]}],"accessors":[{"componentType":5126,"type":"SCALAR","bufferView":0,"byteOffset":8,"count":%s},{"componentType":5126,"type":"VEC3","bufferView":0,"count":1}],"bufferViews":[{"buffer":0,"byteLength":32}],`, count);
		DString why = dstring::new(mem);
		defer why.free();
		test::@check(read_refusal(bad_cutscene(body, rest), &why, &binary) == crig::CUTSCENE_MALFORMED, "a count of %s was read", count);
	}
}

fn void the_engines_turn_file_turns_to_a_point_and_to_an_actor() @test
{
	Cutscene turn = read_fixture("turn.cutscene.gltf");
	defer turn.free(mem);
	CutActorPose start = pose_of(&turn, 0, 0.0f);
	CutActorPose post = pose_of(&turn, 1, 0.0f);
	test::@check(start.position == (Vec3){ 3, 0, 2 } && facing(start) == 90 && post.position == (Vec3){ 8, 0, 2 },
		"both at their places, the hero facing +X: %s %d, %s", start.position, facing(start), post.position);
	test::@check(turn.actors[0].no_level_node && turn.actors[1].no_level_node, "both placed by the file");
	float[5] times = { 0, 1.5f, 2, 2.5f, 3 };
	long[5] expected = { 90, 45, 0, 45, 90 };
	foreach (i, t : times)
	{
		long got = facing(pose_of(&turn, 0, t));
		test::@check(got == expected[i], "at %s s it faces %d°, not %d°", t, got, expected[i]);
	}
}

fn void a_turn_ends_facing_its_target() @test
{
	CutStrip slide = strip(PLAY, 0.0f, 10.0f, "slide");
	slide.loop = true;
	CutStrip[2] strips = { slide, turn_to_point(1.0f, 3.0f, { 5, 0, 0 }, INOUT) };
	CutActor[1] actors = { actor("hero", strips[..]) };
	Cutscene scene = cutscene(actors[..]);
	defer scene.free(mem);
	float[5] times = { 0.5f, 1.5f, 2, 3, 4 };
	long[5] expected = { 0, 14, 45, 90, 90 };
	foreach (i, t : times)
	{
		long got = facing(pose_of(&scene, 0, t));
		test::@check(got == expected[i], "at %s s it faces %d°, not %d°", t, got, expected[i]);
	}
	CutActorPose mid = pose_of(&scene, 0, 2.0f);
	test::@check(mid.strip == 0 && mid.position == (Vec3){ 0, 0, 0 }, "the clip and the place are the turn's to leave alone");
}

fn void a_turn_goes_the_short_way_round() @test
{
	Vec3 point = { (float)math::sin(deg(-170)), 0, (float)math::cos(deg(-170)) };
	CutStrip[1] strips = { turn_to_point(0.0f, 1.0f, point) };
	CutActor[1] actors = { actor("hero", strips[..], yaw_deg(170)) };
	Cutscene scene = cutscene(actors[..]);
	defer scene.free(mem);
	float[4] times = { 0, 0.25f, 0.75f, 1 };
	long[4] expected = { 170, 175, -175, -170 };
	foreach (i, t : times)
	{
		long got = facing(pose_of(&scene, 0, t));
		test::@check(got == expected[i], "at %s s it faces %d°, not %d° (20° on, not 340° back)", t, got, expected[i]);
	}
}

fn void a_turn_starts_from_an_earlier_turning_move() @test
{
	WalkPath[1] paths = { given_path({ { 0, 0, 0 }, { 4, 0, 0 } }) };
	CutStrip[2] strips = { move_on(0, 0.0f, 1.0f), turn_to_point(1.0f, 2.0f, { 9, 0, -5 * (float)math::sqrt(3.0) }) };
	CutActor[1] actors = { actor("hero", strips[..]) };
	Cutscene scene = cutscene(actors[..], paths[..]);
	defer scene.free(mem);
	float[4] times = { 0.5f, 1, 1.5f, 2 };
	long[4] expected = { 90, 90, 120, 150 };
	foreach (i, t : times)
	{
		long got = facing(pose_of(&scene, 0, t));
		test::@check(got == expected[i], "at %s s it faces %d°, not %d°: from the walk's +X, not home's 0°", t, got, expected[i]);
	}
}

fn void a_turn_to_an_actor_faces_where_it_stood_as_the_turn_began() @test
{
	WalkPath[1] paths = { given_path({ { 0, 0, 5 }, { 10, 0, 5 } }) };
	CutStrip[1] hero = { turn_to_actor(1.0f, 2.0f, "post") };
	CutStrip[1] post = { move_on(0, 0.0f, 2.0f, LINEAR, false) };
	CutActor[2] actors = { actor("hero", hero[..]), actor("post", post[..]) };
	Cutscene scene = cutscene(actors[..], paths[..]);
	defer scene.free(mem);
	float[3] times = { 1, 2, 3 };
	long[3] expected = { 0, 45, 45 };
	foreach (i, t : times)
	{
		long got = facing(pose_of(&scene, 0, t));
		test::@check(got == expected[i], "at %s s it faces %d°, not %d°", t, got, expected[i]);
	}
	test::@check(round2(pose_of(&scene, 1, 2.0f).position.x) == 10.0, "the post walked on to x = 10");
}

fn void a_degenerate_target_keeps_the_heading() @test
{
	WalkPath[2] paths = { given_path({ { 0, 0, 0 }, { 4, 0, 0 } }), given_path({ { 4, 0, 0 }, { 4, 3, 0 } }) };
	CutStrip[5] strips = {
		move_on(0, 0.0f, 1.0f),
		turn_to_point(1.0f, 2.0f, { 4, 2, 0 }),        // straight above where it stands
		turn_to_actor(2.0f, 3.0f, "nobody"),           // an actor the cutscene lacks
		turn_to_actor(3.0f, 4.0f, "hero"),             // itself
		move_on(1, 4.0f, 5.0f),                        // straight up, with no heading of its own
	};
	CutActor[1] actors = { actor("hero", strips[..], yaw_deg(30)) };
	Cutscene scene = cutscene(actors[..], paths[..]);
	defer scene.free(mem);
	float[5] times = { 1.5f, 2.5f, 3.5f, 4.5f, 6 };
	foreach (t : times)
	{
		long got = facing(pose_of(&scene, 0, t));
		test::@check(got == 90, "at %s s it faces %d°, still the walk's 90°", t, got);
	}

	// A move with no heading of its own and nothing before it: the home rotation as it is.
	WalkPath[1] up = { given_path({ { 0, 0, 0 }, { 0, 3, 0 } }) };
	CutStrip[1] lift = { move_on(0, 0.0f, 1.0f) };
	CutActor[1] lifted = { actor("hero", lift[..], quat_from_euler_xyz(0.2, 0.5, 0.1)) };
	Cutscene rise = cutscene(lifted[..], up[..]);
	defer rise.free(mem);
	CutActorPose pose = pose_of(&rise, 0, 0.5f);
	test::@check(pose.rotation.v == lifted[0].home_rotation.v && round2(pose.position.y) == 1.5, "it rises as it stood");
}

fn void strips_that_start_together_keep_their_order() @test
{
	// Given out of order: sorted by start, the later of the two turns at 1 s wins.
	CutStrip[3] strips = {
		turn_to_point(2.0f, 3.0f, { -5, 0, 0 }),
		turn_to_point(1.0f, 1.5f, { 5, 0, 0 }),
		turn_to_point(1.0f, 1.5f, { 0, 0, -5 }),
	};
	CutActor[1] actors = { actor("hero", strips[..]) };
	Cutscene scene = cutscene(actors[..]);
	defer scene.free(mem);
	test::@check(math::abs(facing(pose_of(&scene, 0, 1.75f))) == 180, "the second 1 s turn, to -Z, is the one that holds");
	test::@check(facing(pose_of(&scene, 0, 3.0f)) == -90, "and the 2 s turn goes on from it to -X");
}

fn void a_walk_path_is_sampled_evenly_with_exact_ends() @test
{
	// A straight line through uneven knots: 10 m at exactly 0.25 m.
	Vec3[4] line = { { 0, 0, 0 }, { 1, 0, 0 }, { 3, 0, 0 }, { 10, 0, 0 } };
	WalkSamples straight = crig::sample_walk_path(mem, line[..]);
	defer free(straight.points);
	test::@check(math::is_approx(straight.length, 10.0, 1e-4) && straight.points.len == 41, "10 m in 41 points: %s m, %d", straight.length, straight.points.len);
	foreach (usz i, p : straight.points)
	{
		test::@check(math::is_approx(p.x, 0.25 * (double)i, 1e-4) && p.y == 0.0f && p.z == 0.0f, "point %d is %s", i, p);
	}
	test::@check(straight.points[0] == line[0] && straight.points[^1] == line[^1], "the ends are the end knots");

	// 10.1 m: a little under 0.25 m, and even.
	Vec3[2] longer = { { 0, 0, 0 }, { 0, 0, 10.1f } };
	WalkSamples under = crig::sample_walk_path(mem, longer[..]);
	defer free(under.points);
	test::@check(under.points.len == 42 && math::is_approx(under.points[1].z, 10.1 / 41.0, 1e-4), "42 points %s apart", under.points[1].z);

	// An L, with a height on its corner the curve carries.
	Vec3[3] ell = { { 0, 0, 0 }, { 4, 1, 0 }, { 4, 0, 3 } };
	WalkSamples bent = crig::sample_walk_path(mem, ell[..]);
	defer free(bent.points);
	test::@check(bent.points[0] == ell[0] && bent.points[^1] == ell[^1], "the L's ends are its end knots");
	double shortest = 1e9;
	double longest = 0;
	double chords = 0;
	for (usz i = 1; i < bent.points.len; i++)
	{
		double step = (bent.points[i] - bent.points[i - 1]).length();
		shortest = math::min(shortest, step);
		longest = math::max(longest, step);
		chords += step;
	}
	// Even along the curve; a chord across the bend is a little shorter than its arc.
	double step = bent.length / (double)(bent.points.len - 1);
	test::@check(step <= 0.25 && longest <= step + 1e-5 && shortest >= step * 0.99,
		"steps of %s m from %s to %s m", step, shortest, longest);
	// Its length is the curve's own, measured finely here, and at least the knots' polyline.
	Vec3[3] ell_points = ell;
	CutCurve curve = crig::cut_curve(mem, ell_points[..]);
	defer curve.free(mem);
	double measured = 0;
	double[<3>] last = curve.point(0.0);
	for (int i = 1; i <= 200000; i++)
	{
		double[<3>] here = curve.point((double)i / 200000.0);
		measured += (here - last).length();
		last = here;
	}
	double knots_polyline = math::sqrt(17.0) + math::sqrt(10.0);
	test::@check(math::is_approx(bent.length, measured, 1e-3) && bent.length >= knots_polyline && math::is_approx(chords, measured, 5e-3),
		"the L is %s m along the curve (measured %s, knots %s, chords %s)", bent.length, measured, knots_polyline, chords);
	test::@check((double)bent.points.len == math::ceil(bent.length / 0.25) + 1, "%d points for %s m", bent.points.len, bent.length);

	// Repeated knots are one knot, and one knot is no path.
	Vec3[3] doubled = { { 0, 0, 0 }, { 0, 0, 0 }, { 2, 0, 0 } };
	WalkSamples twice = crig::sample_walk_path(mem, doubled[..]);
	defer free(twice.points);
	test::@check(math::is_approx(twice.length, 2.0, 1e-4) && twice.points.len == 9, "a repeated knot adds nothing: %s m", twice.length);
	Vec3[1] alone = { { 1, 2, 3 } };
	WalkSamples single = crig::sample_walk_path(mem, alone[..]);
	defer free(single.points);
	test::@check(single.points.len == 1 && single.length == 0.0f, "one knot is a point and no length");
}

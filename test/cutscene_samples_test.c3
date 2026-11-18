<*
 Sample cutscene exports for the engine's player, written under
 build/cutscene_samples/ as .gltf and .glb: two actors with a place, one walking
 a path, turns toward an actor and toward a point, play strips; and the same with
 a one-off clip. The character is Rigsmith's own humanoid, under neutral rows.
 Beside each, `<sample>.poses.json`: Rigsmith's own poses of it, for three.c3's tests.

     `c3c test --test-filter crig_tests::cutscene_samples`
*>
module crig_tests::cutscene_samples;

import crig;
import crig_tests::mcp;
import std::collections::list;
import std::collections::object;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::sort;

const String MODEL @local = "assets/animations/humanoid.glb";
const String WORK @local = "build/cutscene-samples-work";
const String SAMPLES @local = "build/cutscene_samples";

// A copy of the humanoid in the work folder, so one file is one character and nothing is written beside assets/.
fn String model_copy(String name) @local
{
	(void)path::mkdir(WORK, true);
	String target = string::tformat("%s/%s.glb", WORK, name);
	char[] bytes = file::load(mem, MODEL)!!;
	defer free(bytes);
	(void)file::save(target, bytes);
	foreach (stale : (String[]){ ".rigsmith.json", "_copy.glb", "_copy.rigsmith.json" })
	{
		(void)file::delete(string::tformat("%s/%s%s", WORK, name, stale));
	}
	return target;
}

// The walk and the rest clips of the humanoid, on the focus.
fn bool import_clips(Fixture* f) @local
{
	foreach (pair : (String[2][]){ { "Walk_slow", "Walk" }, { "Idle", "Rest" } })
	{
		String? answer = f.call_tool_text("import_clip", string::tformat(`{"path":"%s","clip":"%s","name":"%s"}`, MODEL, pair[0], pair[1]));
		if (catch answer)
		{
			test::@check(false, "%s did not import", pair[0]);
			return false;
		}
		answer.free(mem);
	}
	return true;
}

fn CutStrip play(float start, float end, String clip, bool loop) @local
{
	CutStrip s = crig::cut_strip(PLAY, start, end);
	s.clip = clip.copy(mem);
	s.loop = loop;
	return s;
}

// Both samples' strips: the walker walks the road and turns to the watcher; the watcher rests, then turns to a point.
fn bool lay_out(crig::AppState* app) @local
{
	(void)app.add_cutscene("Sample");
	if (!app.set_cutscene_timing(0, 14.0f, 30.0f)) return false;
	(void)app.add_cut_path("Road");
	if (!app.add_cut_knot(0, { 0, 0, 0 }) || !app.add_cut_knot(0, { 0.5f, 0, 2 }) || !app.add_cut_knot(0, { 0, 0, 4 })) return false;
	app.show_cutscene_at(0.5f);
	sz walk = app.walk_cut_path(0, 0);
	if (walk < 0) return false;
	float arrived = app.cutscene().actors[0].strips[walk].end;
	CutStrip toward = crig::cut_strip(TURN, arrived, arrived + 0.8f);
	toward.target_row = "watcher".copy(mem);
	if (app.add_cut_strip(0, toward) < 0) return false;
	if (app.add_cut_strip(0, play(arrived, 14.0f, "Rest", true)) < 0) return false;
	if (app.add_cut_strip(1, play(0.0f, 3.0f, "Rest", true)) < 0) return false;
	CutStrip aside = crig::cut_strip(TURN, 3.0f, 4.0f);
	aside.target = { 1.5f, 0, 4 };
	if (app.add_cut_strip(1, aside) < 0) return false;
	return true;
}

fn void export_both(crig::AppState* app, String stem) @local
{
	(void)path::mkdir(SAMPLES, true);
	foreach (ext : (String[]){ ".cutscene.gltf", ".cutscene.glb" })
	{
		String target = string::tformat("%s/%s%s", SAMPLES, stem, ext);
		DString why = dstring::new(mem);
		defer why.free();
		test::@check(app.export_cutscene(target, &why), "%s was not written: %s", target, why.str_view());
		Cutscene back = crig::read_cutscene_file(mem, target)!!;
		defer back.free(mem);
		test::@check(back.actors.len == 2 && back.paths.len == 1, "%s reads back with %d actors", target, back.actors.len);
		foreach (&a : back.actors) test::@check(a.no_level_node, "%s: %s has no place", target, a.row);
	}
}

// A time as the file states it: rounded to 0.1 ms, as the writer rounds a strip's start and end.
fn float file_time(float t) @local => (float)(math::round((double)t * 10000.0) / 10000.0);

// The length of the clip a strip plays, as the preview wraps it, or -1 when the actor lacks it.
fn float strip_clip_length(crig::AppState* app, Cutscene* cutscene, usz actor, CutStrip* s) @local
{
	if (CutOneOff* one = cutscene.one_off_of(actor, s)) return one.clip.duration;
	sz who = app.actor_character(cutscene.actors[actor].row);
	if (who < 0 || s.one_off) return -1.0f;
	float length = -1.0f;
	app.@as_character((usz)who)
	{
		AnimRef ref = crig::NO_ANIM;
		if (AnimTemplate* clip = app.bound_clip_named(s.clip, &ref)) length = clip.duration;
	};
	return length;
}

// Every strip's start, end, quarters and middle, before the first and after the last, in order.
fn float[] pose_times(Allocator allocator, Cutscene* cutscene) @local
{
	List{float} times;
	times.init(mem);
	defer times.free();
	times.push(0.0f);
	times.push(0.25f);
	times.push(cutscene.duration);
	foreach (&actor : cutscene.actors)
	{
		float last = 0.0f;
		foreach (&s : actor.strips)
		{
			foreach (f : (float[]){ 0.0f, 0.25f, 0.5f, 0.75f, 1.0f }) times.push(file_time(s.start + (s.end - s.start) * f));
			last = math::max(last, s.end);
		}
		if (last + 1.0f < cutscene.duration) times.push(last + 1.0f);
	}
	float[] sorted = times.array_view();
	sort::quicksort(sorted);
	List{float} kept;
	kept.init(mem);
	defer kept.free();
	foreach (t : sorted)
	{
		if (t < 0.0f || t > cutscene.duration) continue;
		if (kept.len() == 0 || t - kept[kept.len() - 1] > 1e-5f) kept.push(t);
	}
	return kept.to_array(allocator);
}

<*
 Write `<stem>.poses.json` beside the sample: what `cutscene_actor_pose` gives every actor
 of the previewed cutscene at each of `pose_times`, and under `file` of the cutscene read back
 from the .gltf, which differs only by the writer's rounding; each clip's length; and the
 one-offs' keys as the export wrote them.
*>
fn void write_poses(crig::AppState* app, String stem) @local
{
	Cutscene* cutscene = app.cutscene();
	app.refresh_cut_homes(cutscene);
	DString out = dstring::new(mem);
	defer out.free();
	out.appendf(`{"sample":"%s","file":"%s.cutscene.gltf","duration":%s,"actors":[`, stem, stem, (JsonFloat)cutscene.duration)!!;
	foreach (usz k, &actor : cutscene.actors)
	{
		out.appendf(`%s{"row":"%s","home":%s,"home_rotation":%s,"clips":[`, k > 0 ? "," : "", actor.row,
			(JsonVec3)actor.home, (JsonQuat)actor.home_rotation)!!;
		usz listed;
		foreach (&s : actor.strips)
		{
			if (s.kind == TURN || s.clip.len == 0) continue;
			out.appendf(`%s{"name":"%s","length":%s,"one_off":%s}`, listed++ > 0 ? "," : "", s.clip,
				(JsonFloat)strip_clip_length(app, cutscene, k, s), s.one_off)!!;
		}
		out.append_string("]}");
	}

	// The one-offs as the .gltf holds them, so a check can pose the bone the file moves.
	out.append_string(`],"one_offs":[`);
	CutAnimation[] baked;
	defer crig::free_cut_animations(mem, baked);
	Cutscene back = crig::read_cutscene_file(mem, string::tformat("%s/%s.cutscene.gltf", SAMPLES, stem), animations: &baked)!!;
	defer back.free(mem);
	foreach (usz i, &a : baked)
	{
		out.appendf(`%s{"name":"%s","row":"%s","channels":[`, i > 0 ? "," : "", a.name,
			a.actor < back.actors.len ? back.actors[a.actor].row : "")!!;
		foreach (usz c, &channel : a.channels)
		{
			String kind = channel.path == TRANSLATION ? "translation" : channel.path == ROTATION ? "rotation" : "scale";
			out.appendf(`%s{"bone":"%s","path":"%s","times":[`, c > 0 ? "," : "", channel.bone, kind)!!;
			foreach (usz j, v : channel.times) out.appendf("%s%s", j > 0 ? "," : "", (JsonFloat)v)!!;
			out.append_string(`],"values":[`);
			foreach (usz j, v : channel.values) out.appendf("%s%s", j > 0 ? "," : "", (JsonFloat)v)!!;
			out.append_string("]}");
		}
		out.append_string("]}");
	}

	out.append_string(`],"poses":[`);
	float[] times = pose_times(mem, cutscene);
	defer free(times);
	@pool()
	{
		CutCurve[] curves = crig::cutscene_curves(tmem, cutscene);
		CutCurve[] filed_curves = crig::cutscene_curves(tmem, &back);
		foreach (usz i, t : times)
		{
			out.appendf("%s\n{\"time\":%s,\"actors\":[", i > 0 ? "," : "", (JsonFloat)t)!!;
			foreach (usz k, &actor : cutscene.actors)
			{
				CutActorPose pose = crig::cutscene_actor_pose(cutscene, curves, k, t);
				// The preview shows the same, as none of these times falls between strips.
				CutActorPose shown = crig::cutscene_actor_shown(cutscene, curves, k, t);
				test::@check(shown.strip == pose.strip && shown.clip_time == pose.clip_time,
					"%s: %s at %s s shows strip %d, not %d", stem, actor.row, t, shown.strip, pose.strip);
				out.appendf(`%s{"row":"%s","position":%s,"rotation":%s,"strip":%d`, k > 0 ? "," : "", actor.row,
					(JsonVec3)pose.position, (JsonQuat)pose.rotation, pose.strip)!!;
				if (pose.strip >= 0)
				{
					CutStrip* s = &actor.strips[pose.strip];
					String kind = s.kind == MOVE ? "move" : s.kind == PLAY ? "play" : "turn";
					float length = strip_clip_length(app, cutscene, k, s);
					out.appendf(`,"type":"%s","start":%s,"end":%s,"clip":"%s","loop":%s,"clip_time":%s,"holding":%s`, kind,
						(JsonFloat)s.start, (JsonFloat)s.end, s.clip, s.loop, (JsonFloat)pose.clip_time, pose.holding)!!;
					if (length >= 0.0f) out.appendf(`,"clip_local":%s`, (JsonFloat)crig::cut_clip_local(pose.clip_time, length, s.loop))!!;
				}
				CutActorPose filed = crig::cutscene_actor_pose(&back, filed_curves, k, t);
				out.appendf(`,"file":{"position":%s,"rotation":%s`, (JsonVec3)filed.position, (JsonQuat)filed.rotation)!!;
				if (filed.strip >= 0)
				{
					CutStrip* s = &back.actors[k].strips[filed.strip];
					float length = strip_clip_length(app, cutscene, k, s);
					out.appendf(`,"clip":"%s"`, s.clip)!!;
					if (length >= 0.0f) out.appendf(`,"clip_local":%s`, (JsonFloat)crig::cut_clip_local(filed.clip_time, length, s.loop))!!;
				}
				out.append_string("}}");
			}
			out.append_string("]}");
		}
	};
	out.append_string("]}\n");
	String target = string::tformat("%s/%s.poses.json", SAMPLES, stem);
	test::@check(@ok(file::save(target, out.str_view())), "%s was not written", target);
}

fn bool open_cast(Fixture* f) @local
{
	if (!f.open_model(model_copy("walker"))) return false;
	if (!import_clips(f)) return false;
	crig::AppState* app = &f.app;
	if (!app.make_actor(app.active, "walker")) return false;
	Vec3 aside = { 2.5f, 0, 3 };
	if (!app.add_actor_from_file(model_copy("watcher"), "watcher", &aside)) return false;
	return import_clips(f);
}

fn void the_samples_for_the_engines_player_are_written() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_cast(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(lay_out(app), "the strips would not lay out: %s", app.notice());
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	foreach (p : problems) test::@check(false, "a problem: %s", p);
	export_both(app, "walk_turn_play");
	write_poses(app, "walk_turn_play");

	// The same with a one-off: the watcher waves its arm at 1 s into it.
	sz watcher = app.actor_character("watcher");
	if (watcher >= 0) (void)app.focus_character((usz)watcher);
	app.show_cutscene_at(4.5f);
	sz k = app.new_cut_one_off(1, 2.0f);
	test::@check(k >= 0 && app.edit_cut_one_off(1, (usz)k), "the one-off would not open: %s", app.notice());
	Object*? posed = f.call_tool("pose_joint", `{"joint":"shoulder_L","turn":{"axis":[0,0,1],"angle":0.9},"time":1.0}`);
	if (catch posed)
	{
		posed = f.call_tool("pose_joint", `{"joint":"spine","turn":{"axis":[1,0,0],"angle":0.3},"time":1.0}`);
	}
	if (catch posed)
	{
		test::@check(false, "the one-off would not take a key: %s", app.notice());
		return;
	}
	posed.free();
	test::@check(app.back_to_cutscene(), "back");
	export_both(app, "with_one_off");
	write_poses(app, "with_one_off");
	Cutscene back = crig::read_cutscene_file(mem, SAMPLES +++ "/with_one_off.cutscene.gltf")!!;
	defer back.free(mem);
	bool plays;
	foreach (&a : back.actors) foreach (&s : a.strips) plays = plays || s.animation >= 0;
	test::@check(plays, "no strip plays the one-off");
}

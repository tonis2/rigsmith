<*
 Cutscenes in the app: the scene file keeps them, the list edits undo on their own
 history, the preview poses the actors and puts them back, and the MCP tools.

     `c3c test --test-filter crig_tests::cutscene_app`
*>
module crig_tests::cutscene_app;

import crig;
import crig_tests::mcp;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

const String MODEL @local = "assets/animations/humanoid.glb";
const String FOLDER @local = "build/cutscene-app";

fn bool near(float a, float b, float eps = 1e-3f) @local => math::abs(a - b) <= eps;

// A second copy of the model, since one file is one character.
fn String second_model() @local
{
	(void)path::mkdir(FOLDER, true);
	String target = FOLDER.tconcat("/second.glb");
	char[] bytes = file::load(mem, MODEL)!!;
	defer free(bytes);
	(void)file::save(target, bytes);
	return target;
}

fn CutStrip strip(CutStripKind kind, float start, float end, String clip = "", bool loop = false) @local
{
	CutStrip s = crig::cut_strip(kind, start, end);
	if (clip.len > 0) s.clip = clip.copy(mem);
	s.loop = loop;
	return s;
}

fn CutActor cut_actor(String row, CutStrip[] strips) @local
{
	return { .row = row.copy(mem), .home_rotation = quaternion::IDENTITY,
		.strips = strips.len > 0 ? alloc::clone_slice(mem, strips) : {} };
}

fn WalkPath walk_path(String name, Vec3[] knots) @local
{
	WalkPath out = { .name = name.copy(mem), .knots = alloc::clone_slice(mem, knots) };
	out.resample(mem);
	return out;
}

// ---------------------------------------------------------------------------
// The scene file

fn void a_scene_keeps_its_cutscenes_actors_and_knots() @test
{
	SceneFile scene = { .active = 1, .time = 0.5f };
	defer scene.free(mem);
	scene.characters = alloc::new_array(mem, SceneCharacter, 2);
	scene.characters[0] = { .model = "/nowhere/hero.glb".copy(mem), .transform = { .rotation = quaternion::IDENTITY },
		.row = "hero".copy(mem), .scale = 1.0f };
	scene.characters[1] = { .model = "/nowhere/guard.glb".copy(mem), .transform = { .location = { 2, 0, 1 }, .rotation = quaternion::IDENTITY },
		.row = "guard".copy(mem), .level_node = "guard_armature".copy(mem), .scale = 1.78f };
	scene.cutscenes = alloc::new_array(mem, Cutscene, 2);
	scene.cutscenes[0] = { .name = "Empty".copy(mem), .duration = 3.0f, .fps = 24.0f };
	Cutscene* walk = &scene.cutscenes[1];
	*walk = { .name = "Meeting".copy(mem), .duration = 12.0f, .fps = 30.0f };
	walk.paths = alloc::new_array(mem, WalkPath, 1);
	walk.paths[0] = walk_path("road", { { 0, 0, 0 }, { 1, 0.2f, 2 }, { 3, 0, 4 } });
	CutStrip go = strip(MOVE, 0, 4, "Walk", true);
	go.path = 0;
	go.speed = 1.25f;
	CutStrip face = crig::cut_strip(TURN, 4, 5);
	face.target_row = "guard".copy(mem);
	walk.actors = alloc::new_array(mem, CutActor, 2);
	walk.actors[0] = cut_actor("hero", { go, face, strip(PLAY, 5, 9, "Wave") });
	walk.actors[1] = cut_actor("guard", { strip(PLAY, 0, 12, "Idle", true) });
	scene.active_cutscene = 1;

	String text = crig::scene_file_text(mem, &scene, "/nowhere/meeting.rigsmith-scene.json");
	defer text.free(mem);
	SceneFile back = crig::parse_scene_file(mem, text, "/nowhere/meeting.rigsmith-scene.json")!!;
	defer back.free(mem);

	test::@check(back.characters[0].row == "hero", "back.characters[0].row is '%s'", back.characters[0].row);
	test::@check(back.characters[0].level_node == "", "back.characters[0].level_node is '%s'", back.characters[0].level_node);
	test::@check(near(back.characters[0].scale, 1.0f), "an own-sized actor reads as 1");
	test::@check(back.characters[1].row == "guard", "back.characters[1].row is '%s'", back.characters[1].row);
	test::@check(back.characters[1].level_node == "guard_armature", "back.characters[1].level_node is '%s'", back.characters[1].level_node);
	test::@check(near(back.characters[1].scale, 1.78f), "the scale is %f", back.characters[1].scale);
	test::@check(back.cutscenes.len == 2, "back.cutscenes.len is %s", back.cutscenes.len);
	test::@check(back.active_cutscene == 1, "back.active_cutscene is %s", back.active_cutscene);
	test::@check(back.cutscenes[0].name == "Empty", "back.cutscenes[0].name is '%s'", back.cutscenes[0].name);
	test::@check(near(back.cutscenes[0].fps, 24.0f), "the empty cutscene's rate");

	Cutscene* got = &back.cutscenes[1];
	test::@check(got.name == "Meeting", "got.name is '%s'", got.name);
	test::@check(near(got.duration, 12.0f), "duration");
	test::@check(got.paths.len == 1, "got.paths.len is %s", got.paths.len);
	test::@check(got.paths[0].knots.len == 3, "got.paths[0].knots.len is %s", got.paths[0].knots.len);
	foreach (usz k, knot : walk.paths[0].knots)
	{
		test::@check((got.paths[0].knots[k] - knot).length() < 1e-4f, "knot %d moved", k);
	}
	test::@check(got.paths[0].points.len >= 2, "the points are sampled again from the knots");
	test::@check((got.paths[0].points[^1] - walk.paths[0].knots[^1]).length() < 1e-4f, "the samples end on the last knot");
	test::@check(near(got.paths[0].length, walk.paths[0].length, 1e-3f), "length %f, not %f", got.paths[0].length, walk.paths[0].length);
	test::@check(got.actors.len == 2, "got.actors.len is %s", got.actors.len);
	CutActor* hero = &got.actors[0];
	test::@check(hero.strips.len == 3, "hero.strips.len is %s", hero.strips.len);
	test::@check(hero.strips[0].kind == MOVE && hero.strips[0].path == 0 && hero.strips[0].clip == "Walk", "the walk");
	test::@check(near(hero.strips[0].speed, 1.25f) && hero.strips[0].loop, "the walk's speed and loop");
	test::@check(hero.strips[1].kind == TURN && hero.strips[1].target_row == "guard", "the turn to the guard");
	test::@check(hero.strips[2].kind == PLAY && near(hero.strips[2].end, 9.0f), "the wave");
	test::@check(got.actors[1].strips[0].loop, "the guard's idle loops");

	// A scene with none of the keys is a scene with no cutscenes and no actors.
	String plain = `{"format":"rigsmith-scene","version":1,"characters":[{"model":"/nowhere/hero.glb"}]}`;
	SceneFile bare = crig::parse_scene_file(mem, plain, "/nowhere/plain.rigsmith-scene.json")!!;
	defer bare.free(mem);
	test::@check(bare.cutscenes.len == 0, "bare.cutscenes.len is %s", bare.cutscenes.len);
	test::@check(bare.characters[0].row == "", "bare.characters[0].row is '%s'", bare.characters[0].row);
	test::@check(near(bare.characters[0].scale, 1.0f), "no scale is the own size");
}

fn void a_scene_reading_keeps_what_the_file_refuses() @test
{
	String text = `{"name":"Loose","duration":4,"actors":[{"row":"hero","strips":[
		{"type":"move","start":0,"end":2,"path":5},
		{"type":"turn","start":2,"end":3,"actor":"ghost"}]}],"paths":[]}`;
	Object* raw = json::parse(mem, text)!!;
	defer raw.free();
	Cutscene loose = crig::cutscene_from_json(mem, raw)!!;
	defer loose.free(mem);
	test::@check(loose.actors[0].strips.len == 2, "loose.actors[0].strips.len is %s", loose.actors[0].strips.len);
	test::@check(loose.actors[0].strips[0].path == 5, "loose.actors[0].strips[0].path is %s", loose.actors[0].strips[0].path);
	test::@check(loose.actors[0].strips[1].target_row == "ghost", "loose.actors[0].strips[1].target_row is '%s'", loose.actors[0].strips[1].target_row);
	DString why = dstring::new(mem);
	defer why.free();
	if (try String written = crig::cutscene_gltf_text(mem, &loose, &why))
	{
		written.free(mem);
		test::@check(false, "a move with no path was written");
	}
	test::@check(why.str_view().contains("path"), "the refusal is '%s'", why.str_view());
}

// ---------------------------------------------------------------------------
// The app

<* The model with two of its clips authored on it, so they play by name; `model` is a copy of it to save into. *>
fn bool open_hero(Fixture* f, String model = MODEL) @local
{
	if (!f.open_model(model)) return false;
	foreach (pair : (String[2][]){ { "Walk_slow", "Walk" }, { "Idle", "Rest" } })
	{
		String args = string::tformat(`{"path":"%s","clip":"%s","name":"%s"}`, MODEL, pair[0], pair[1]);
		String? answer = f.call_tool_text("import_clip", args);
		if (catch answer)
		{
			test::@check(false, "%s did not import", pair[0]);
			return false;
		}
		answer.free(mem);
	}
	return true;
}

fn void list_edits_are_cutscene_steps_and_leave_the_rig_history_alone() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	sz rig_steps = app.undo_stack.edits.len();

	test::@check(app.make_actor(app.active), "the hero did not become an actor");
	test::@check(app.actor_row == "humanoid", "app.actor_row is '%s'", app.actor_row);
	usz made = app.add_cutscene();
	test::@check(made == 0, "made is %s", made);
	test::@check(app.cutscene().actors.len == 1, "app.cutscene().actors.len is %s", app.cutscene().actors.len);
	test::@check(app.cutscene().actors[0].row == "humanoid", "app.cutscene().actors[0].row is '%s'", app.cutscene().actors[0].row);
	test::@check(app.rename_cutscene(0, "Opening"), "rename");
	test::@check(!app.rename_cutscene(0, "  "), "an empty name is refused");
	test::@check(app.set_cutscene_timing(0, 6.0f, 24.0f), "timing");
	usz second = app.add_cutscene();
	test::@check(second == 1, "second is %s", second);
	test::@check(app.cutscene().name == "Cutscene", "app.cutscene().name is '%s'", app.cutscene().name);
	test::@check(app.delete_cutscene(1), "delete");
	test::@check(app.cutscenes.len() == 1, "app.cutscenes.len() is %s", app.cutscenes.len());
	test::eq(app.undo_stack.edits.len(), rig_steps);

	// Each one undoes alone, newest first, and redoes again.
	test::@check(app.undo_cutscene(), "undo delete");
	test::@check(app.cutscenes.len() == 2, "app.cutscenes.len() is %s", app.cutscenes.len());
	test::@check(app.undo_cutscene(), "undo add");
	test::@check(app.cutscenes.len() == 1, "app.cutscenes.len() is %s", app.cutscenes.len());
	test::@check(app.undo_cutscene(), "undo timing");
	test::@check(near(app.cutscene().duration, crig::CUT_NEW_DURATION) && near(app.cutscene().fps, 30.0f), "the timing is back");
	test::@check(app.undo_cutscene(), "undo rename");
	test::@check(app.cutscene().name == "Cutscene", "app.cutscene().name is '%s'", app.cutscene().name);
	test::@check(app.undo_cutscene(), "undo the first add");
	test::@check(app.cutscenes.len() == 0, "app.cutscenes.len() is %s", app.cutscenes.len());
	test::@check(app.undo_cutscene(), "undo the row");
	test::@check(app.actor_row == "", "app.actor_row is '%s'", app.actor_row);
	test::@check(!app.undo_cutscene(), "nothing more");
	for (int i = 0; i < 4; i++) test::@check(app.redo_cutscene(), "redo %d", i);
	test::@check(app.cutscene().name == "Opening", "app.cutscene().name is '%s'", app.cutscene().name);
	test::@check(near(app.cutscene().duration, 6.0f), "redo puts the timing back");
	test::@check(app.actor_row == "humanoid", "app.actor_row is '%s'", app.actor_row);
	test::eq(app.undo_stack.edits.len(), rig_steps);

	// Ctrl+Z takes back whichever came last: here the character's own move, then the rename.
	test::@check(app.rename_cutscene(0, "Later"), "rename again");
	ProjectTransform before = app.doc.model_transform;
	ProjectTransform after = before;
	after.location.x += 1.0f;
	test::@check(app.set_model_transform_recorded(before, after), "move the hero");
	app.undo_stack.commit();
	test::@check(app.undo_latest(), "undo latest");
	test::@check(near(app.doc.model_transform.location.x, before.location.x), "the move went first");
	test::@check(app.cutscene().name == "Later", "app.cutscene().name is '%s'", app.cutscene().name);
	test::@check(app.undo_latest(), "undo latest again");
	test::@check(app.cutscene().name == "Opening", "app.cutscene().name is '%s'", app.cutscene().name);
	test::@check(app.redo_latest(), "redo latest");
	test::@check(app.cutscene().name == "Later", "app.cutscene().name is '%s'", app.cutscene().name);
	test::@check(app.redo_latest(), "redo latest again");
	test::@check(near(app.doc.model_transform.location.x, after.location.x), "the move came back last");
}

fn void a_row_renamed_follows_into_every_cutscene() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "make the hero an actor");
	(void)app.add_cutscene();
	Cutscene* c = app.cutscene();
	CutStrip face = crig::cut_strip(TURN, 1, 2);
	face.target_row = "hero".copy(mem);
	Cutscene changed = c.copy(mem);
	changed.actors[0].free(mem);
	changed.actors[0] = cut_actor("hero", { face });
	app.replace_cutscene(0, changed);
	test::@check(app.make_actor(app.active, "lead"), "rename the row");
	test::@check(app.cutscene().actors[0].row == "lead", "app.cutscene().actors[0].row is '%s'", app.cutscene().actors[0].row);
	test::@check(app.cutscene().actors[0].strips[0].target_row == "lead", "app.cutscene().actors[0].strips[0].target_row is '%s'", app.cutscene().actors[0].strips[0].target_row);
	test::@check(app.undo_cutscene(), "undo the rename");
	test::@check(app.actor_row == "hero", "app.actor_row is '%s'", app.actor_row);
	test::@check(app.cutscene().actors[0].row == "hero", "app.cutscene().actors[0].row is '%s'", app.cutscene().actors[0].row);

	// A row another character has is refused.
	String extra = second_model();
	test::@check(app.add_actor_from_file(extra, "lead"), "a second actor from a file");
	test::@check(app.character_count() == 2, "app.character_count() is %s", app.character_count());
	test::@check(!app.make_actor(app.active, "hero"), "two characters cannot share a row");
	test::@check(app.actor_row == "lead", "app.actor_row is '%s'", app.actor_row);
	test::@check(app.cutscene().actors.len == 2, "app.cutscene().actors.len is %s", app.cutscene().actors.len);

	// Taking it out of the scene takes it out of every cutscene; the level copy it stood in for is free.
	app.set_level_node("guard_armature");
	test::@check(app.level_node_character("guard_armature") == (sz)app.active, "app.level_node_character('guard_armature') is %s", app.level_node_character("guard_armature"));
	test::@check(app.remove_actor(app.active), "remove the second actor");
	test::@check(app.character_count() == 1, "app.character_count() is %s", app.character_count());
	test::@check(app.level_node_character("guard_armature") == (sz)-1, "app.level_node_character('guard_armature') is %s", app.level_node_character("guard_armature"));
	test::@check(app.cutscene().actors.len == 1, "app.cutscene().actors.len is %s", app.cutscene().actors.len);
}

fn void the_preview_poses_the_actors_and_puts_them_back() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "hero");
	AnimRef walk_ref;
	AnimTemplate* walk = app.bound_clip_named("Walk", &walk_ref);
	AnimRef rest_ref;
	AnimTemplate* rest = app.bound_clip_named("Rest", &rest_ref);
	if (!walk || !rest)
	{
		test::@check(false, "the hero lacks its Walk or its Rest");
		return;
	}
	float walk_length = walk.duration;
	float rest_length = rest.duration;

	// What the hero shows on its own: the Rest clip parked at 0.3 s, standing at x = 1.
	app.doc.model_transform.location = { 1, 0, 0 };
	test::@check(app.park_clip(rest_ref, 0.3f), "park the hero's own clip");
	ProjectTransform home = app.doc.model_transform;

	// Rest, then a walk along a 4 m road, then a clip the hero lacks.
	float walk_from = 0.5f + rest_length * 2.0f + 0.5f;
	(void)app.add_cutscene();
	Cutscene c = app.cutscene().copy(mem);
	c.actors[0].free(mem);
	c.paths = alloc::new_array(mem, WalkPath, 1);
	c.paths[0] = walk_path("road", { { 1, 0, 0 }, { 1, 0, 4 } });
	CutStrip go = strip(MOVE, walk_from, walk_from + 2.0f, "Walk", true);
	go.path = 0;
	go.ease = LINEAR;
	c.actors[0] = cut_actor("hero", { strip(PLAY, 0.5f, 0.5f + rest_length * 2.0f, "Rest", false), go,
		strip(PLAY, walk_from + 3.0f, walk_from + 4.0f, "Missing") });
	c.duration = walk_from + 6.0f;
	app.replace_cutscene(0, c);

	test::@check(app.set_cutscene_preview(true), "preview on");
	app.show_cutscene_at(0.25f);
	test::@check(app.staged, "the hero stands where the cutscene has it");
	test::@check((app.staged_place.location - home.location).length() < 1e-4f, "before its first strip, at home");
	test::@check(!app.animating, "and at rest");

	// The Rest strip does not loop, so past the clip's own end it holds the end.
	app.show_cutscene_at(0.5f + rest_length * 1.5f);
	test::@check(app.animating && app.current_ref.same(rest_ref), "Rest plays");
	test::@check(near(app.anim_time, rest_length), "a clip that does not loop holds its end, not %f", app.anim_time);

	// Halfway along the walk, the walk wrapped by its own length.
	app.show_cutscene_at(walk_from + 1.0f);
	test::@check(app.current_ref.same(walk_ref), "the walk plays on the move");
	test::@check(near(app.staged_place.location.z, 2.0f, 2e-2f), "halfway along a 4 m road at 2 m, not %f", app.staged_place.location.z);
	float wrapped = 1.0f - math::floor(1.0f / walk_length) * walk_length;
	test::@check(near(app.anim_time, wrapped), "one second into the walk is %f, not %f", wrapped, app.anim_time);
	test::@check(math::abs(crig::cut_heading_of(app.staged_place.rotation)) < 1e-2, "walking along +Z faces +Z");

	// After the walk it stands where the road ends, holding the Rest it played before, as the game does.
	app.show_cutscene_at(walk_from + 2.5f);
	test::@check(near(app.staged_place.location.z, 4.0f, 1e-3f), "held at the road's end");
	test::@check(app.current_ref.same(rest_ref) && near(app.anim_time, rest_length), "the play strip before holds its end");
	app.show_cutscene_at(walk_from + 3.5f);
	test::@check(!app.animating, "a clip the hero lacks plays nothing");
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	test::@check(problems.len == 1, "problems.len is %s", problems.len);
	if (problems.len > 0) test::@check(problems[0].contains("Missing"), "'%s' names the missing clip", problems[0]);

	// Off: the hero's own clip at its own time, where it stood.
	test::@check(app.set_cutscene_preview(false), "preview off");
	test::@check(!app.staged, "no longer staged");
	test::@check(app.animating && app.current_ref.same(rest_ref) && near(app.anim_time, 0.3f, 1e-5f), "the hero's own clip and time are back");
	test::@check(app.doc.model_transform.same(home), "its place never moved");
	test::@check(app.anim_paused, "parked as it was");
}

// ---------------------------------------------------------------------------
// MCP

fn Object* call(Fixture* f, String tool, String args) @local
{
	Object*? got = f.call_tool(tool, args);
	if (catch got)
	{
		test::@check(false, "%s %s was refused", tool, args);
		return null;
	}
	return got;
}

fn void the_cutscene_tools_round_trip() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;

	Object* listed = call(f, "add_actor", `{"row":"hero"}`);
	if (!listed) return;
	defer listed.free();
	test::@check(listed.get("actors")!!.get_at(0).get_string("row")!! == "hero", "listed.get('actors')!!.get_at(0).get_string('row')!! is '%s'", listed.get("actors")!!.get_at(0).get_string("row")!!);

	Object* made = call(f, "set_cutscene", `{"new":true,"name":"Intro"}`);
	if (!made) return;
	defer made.free();
	test::@check(made.get("cutscene")!!.get_string("name")!! == "Intro", "made.get('cutscene')!!.get_string('name')!! is '%s'", made.get("cutscene")!!.get_string("name")!!);

	String shape = `{"cutscene":{"name":"Intro","duration":6,"fps":30,"actors":[{"row":"hero","strips":[
		{"type":"move","start":0,"end":2,"path":0,"clip":"Walk","ease":"linear"},
		{"type":"turn","start":2,"end":3,"point":[5,0,4]},
		{"type":"play","start":3,"end":7,"clip":"Wave"}]}],
		"paths":[{"name":"road","knots":[[0,0,0],[0,0,2],[1,0,4]]}]}}`;
	Object* set = call(f, "set_cutscene", shape);
	if (!set) return;
	defer set.free();
	Object* cut = set.get("cutscene")!!;
	Object* road = cut.get("paths")!!.get_at(0);
	test::@check(road.get("knots")!!.get_len() == 3, "road.get('knots')!!.get_len() is %s", road.get("knots")!!.get_len());
	test::@check(road.get("points")!!.get_len() >= 8, "the road is sampled every 0.25 m or less");
	Object* actor = cut.get("actors")!!.get_at(0);
	test::@check(actor.get_long("character")!! == 0, "actor.get_long('character')!! is %s", actor.get_long("character")!!);
	test::@check(actor.get_string("level_node")!! == "", "actor.get_string('level_node')!! is '%s'", actor.get_string("level_node")!!);
	Object* problems = set.get("problems")!!;
	test::@check(problems.get_len() == 2, "problems.get_len() is %s", problems.get_len());
	test::@check(problems.get_at(0).s.contains("Wave"), "the missing clip is named");
	test::@check(problems.get_at(1).s.contains("7.00 s"), "the late end is named");
	test::@check(app.cut_history.undo.len() == 3, "app.cut_history.undo.len() is %s", app.cut_history.undo.len());

	Object* poses = call(f, "set_cutscene_time", `{"preview":true,"t":1}`);
	if (!poses) return;
	defer poses.free();
	test::@check(poses.get_bool("preview")!!, "the preview is on");
	Object* hero = poses.get("actors")!!.get_at(0);
	test::@check(hero.get_string("clip")!! == "Walk", "hero.get_string('clip')!! is '%s'", hero.get_string("clip")!!);
	test::@check(hero.get_bool("clip_found")!!, "the hero has the Walk");
	test::@check(app.staged, "the hero is staged");

	Object* renamed = call(f, "add_actor", `{"row":"lead"}`);
	if (!renamed) return;
	defer renamed.free();
	test::@check(app.cutscene().actors[0].row == "lead", "app.cutscene().actors[0].row is '%s'", app.cutscene().actors[0].row);

	Object* stepped = call(f, "undo", `{"history":"cutscene"}`);
	if (!stepped) return;
	defer stepped.free();
	test::@check(stepped.get_long("stepped")!! == 1, "stepped.get_long('stepped')!! is %s", stepped.get_long("stepped")!!);
	test::@check(app.cutscene().actors[0].row == "hero", "app.cutscene().actors[0].row is '%s'", app.cutscene().actors[0].row);
	test::@check(app.actor_row == "hero", "app.actor_row is '%s'", app.actor_row);

	Object* picked = call(f, "select_cutscene", `{"name":"Intro"}`);
	if (!picked) return;
	defer picked.free();
	test::@check(picked.get_long("active")!! == 0, "picked.get_long('active')!! is %s", picked.get_long("active")!!);

	// The export refuses nothing here but a clip the game finds; it is written and reads back.
	(void)path::mkdir(FOLDER, true);
	String target = FOLDER.tconcat("/intro.cutscene.glb");
	(void)file::delete(target);
	Object* written = call(f, "export_cutscene", string::tformat(`{"path":"%s"}`, target));
	if (!written) return;
	defer written.free();
	Cutscene back = crig::read_cutscene_file(mem, target)!!;
	defer back.free(mem);
	test::@check(back.name == "Intro", "back.name is '%s'", back.name);
	test::@check(back.actors.len == 1, "back.actors.len is %s", back.actors.len);
	test::@check(back.actors[0].no_level_node, "an actor with no level node gets a place");
	test::@check(back.paths.len == 1, "back.paths.len is %s", back.paths.len);
	test::@check(back.paths[0].points.len >= 8, "the path's samples are written");
	test::@check(back.actors[0].strips[1].kind == CutStripKind.TURN, "the second strip is %s", back.actors[0].strips[1].kind);

	Object* off = call(f, "set_cutscene_time", `{"preview":false}`);
	if (!off) return;
	defer off.free();
	test::@check(!app.staged, "the preview put the hero back");

	// A level actor needs its own file, and says why.
	if (try taken = f.call_tool_text("add_actor", `{"level_node":"guard_armature"}`))
	{
		taken.free(mem);
		test::@check(false, "a level actor with no file was taken");
	}

	Object* gone = call(f, "set_cutscene", `{"delete":true}`);
	if (!gone) return;
	defer gone.free();
	test::@check(gone.get("cutscenes")!!.get_len() == 0, "gone.get('cutscenes')!!.get_len() is %s", gone.get("cutscenes")!!.get_len());
}

// ---------------------------------------------------------------------------
// Strips edited

fn usz cut_steps(crig::AppState* app) @local => (usz)app.cut_history.undo.len();

fn void strip_edits_settle_the_lanes_and_each_is_one_step() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "hero");
	(void)app.add_cutscene();
	Cutscene two = app.cutscene().copy(mem);
	CutActor[] actors = alloc::new_array(mem, CutActor, 2);
	actors[0] = two.actors[0];
	actors[1] = cut_actor("guide", {});
	free(two.actors);
	two.actors = actors;
	app.replace_cutscene(0, two);
	AnimRef ref;
	AnimTemplate* rest = app.bound_clip_named("Rest", &ref);
	if (!rest)
	{
		test::@check(false, "the hero lacks its Rest");
		return;
	}
	float rest_length = rest.duration;
	bool rest_loops = rest.loop;

	// A play at the playhead is one pass of the clip, and is picked.
	usz steps = cut_steps(app);
	app.show_cutscene_at(1.0f);
	sz played = app.add_cut_play(0, "Rest");
	test::@check(played == 0, "played is %s", played);
	CutStrip* rest_strip = &app.cutscene().actors[0].strips[0];
	test::@check(near(rest_strip.start, 1.0f) && near(rest_strip.end, 1.0f + rest_length), "the play runs %f to %f", rest_strip.start, rest_strip.end);
	test::@check(rest_strip.loop == rest_loops, "it loops as the clip does");
	test::@check(rest_strip.id != 0 && app.cut_selected == rest_strip.id, "the new strip is picked");
	test::eq(cut_steps(app), steps + 1);
	test::@check(app.add_cut_play(0, "Nothing") < 0, "a clip the character lacks is not added");
	test::eq(cut_steps(app), steps + 1);

	// A turn faces the other actor, on the Where lane beside the play.
	sz faced = app.add_cut_turn(0, "guide");
	CutStrip* face = &app.cutscene().actors[0].strips[faced];
	test::@check(face.kind == TURN && face.target_row == "guide" && near(face.end - face.start, crig::CUT_TURN_LENGTH), "the turn");
	test::eq(app.cutscene().actors[0].strips.len, 2);
	test::eq(cut_steps(app), steps + 2);

	// A card edit keeps the strip and its pick; undo takes it back, still picked.
	test::@check(app.select_cut_strip(0, 0), "pick the play");
	uint picked = app.cut_selected;
	CutStrip faster = app.cutscene().actors[0].strips[0].copy(mem);
	faster.speed = 2.0f;
	test::@check(app.set_cut_strip(0, 0, faster), "speed");
	test::@check(near(app.cutscene().actors[0].strips[0].speed, 2.0f), "the speed is set");
	test::@check(app.cut_selected == picked, "the pick survives the edit");
	test::eq(cut_steps(app), steps + 3);
	CutStrip same = app.cutscene().actors[0].strips[0].copy(mem);
	test::@check(app.set_cut_strip(0, 0, same), "the same again");
	test::eq(cut_steps(app), steps + 3);
	test::@check(app.undo_cutscene(), "undo the speed");
	test::@check(near(app.cutscene().actors[0].strips[0].speed, 1.0f) && app.cut_selected == picked, "the speed is back, still picked");
	test::@check(app.redo_cutscene(), "redo the speed");

	// A drag is one step; one put back with Esc is none.
	test::@check(app.begin_cut_gesture(), "begin a drag");
	test::@check(app.drag_cut_strip(0, 0, 2.0f, 2.0f + rest_length, false), "drag");
	test::@check(near(app.cutscene().actors[0].strips[0].start, 2.0f), "the strip follows the drag live");
	test::@check(app.drag_cut_strip(0, 0, 3.0f, 3.0f + rest_length, false), "drag on");
	test::@check(app.end_cut_gesture(0, 0), "land it");
	test::eq(cut_steps(app), steps + 4);
	test::@check(near(app.cutscene().actors[0].strips[0].start, 3.0f), "it landed where it was let go");
	test::@check(app.begin_cut_gesture(), "begin another");
	test::@check(app.drag_cut_strip(0, 0, 5.0f, 5.0f + rest_length, false), "drag");
	app.cancel_cut_gesture();
	test::@check(near(app.cutscene().actors[0].strips[0].start, 3.0f), "Esc puts it back");
	test::eq(cut_steps(app), steps + 4);
	test::@check(app.begin_cut_gesture(), "a press that does not move");
	test::@check(!app.end_cut_gesture(0, 0), "leaves no step");
	test::eq(cut_steps(app), steps + 4);
	test::@check(app.undo_cutscene(), "undo the drag");
	test::@check(near(app.cutscene().actors[0].strips[0].start, 1.0f), "the whole drag goes back at once");

	// A front resize keeps the clip where it was in time.
	test::@check(app.begin_cut_gesture(), "begin a resize");
	test::@check(app.drag_cut_strip(0, 0, 1.25f, 1.0f + rest_length, true), "resize the front");
	test::@check(app.end_cut_gesture(0, 0), "land it");
	test::@check(near(app.cutscene().actors[0].strips[0].offset, 0.5f), "a quarter second at 2x is half a second of the clip, not %f",
		app.cutscene().actors[0].strips[0].offset);

	// A turn dropped over the first lands; the one it covers goes.
	sz second = app.add_cut_turn(0, "guide");
	test::@check(second >= 0, "a second turn at the same playhead");
	test::eq(app.cutscene().actors[0].strips.len, 2);

	// A ground point picked lands a new turn facing it.
	app.show_cutscene_at(6.0f);
	app.cut_pick = NEW_TURN;
	app.cut_pick_actor = 0;
	test::@check(app.finish_cut_pick({ 1, 0, 2 }), "the pick lands a turn");
	CutStrip* pointed = app.cut_selected_strip();
	test::@check(pointed && pointed.kind == TURN && pointed.target_row == "" && near(pointed.target.z, 2.0f), "facing the point");
	test::@check(app.cut_pick == NONE, "the pick is over");

	// Deleting the picked strip drops the pick; undo brings the strip back.
	usz count = app.cutscene().actors[0].strips.len;
	usz actor;
	usz index;
	test::@check(app.cut_selection(&actor, &index), "a strip is picked");
	test::@check(app.delete_cut_strip(actor, index), "delete");
	test::@check(app.cutscene().actors[0].strips.len == count - 1, "a strip went");
	test::@check(app.cut_selected == 0, "the pick went with its strip");
	test::@check(app.undo_cutscene(), "undo the delete");
	test::@check(app.cutscene().actors[0].strips.len == count, "the strip came back");
}

// ---------------------------------------------------------------------------
// Walks

fn bool close_to(Vec3 a, Vec3 b, float eps = 1e-3f) @local => (a - b).length() <= eps;

fn void a_path_is_drawn_dragged_put_in_and_taken_out_each_one_step() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "hero");
	(void)app.add_cutscene();
	usz steps = cut_steps(app);

	// Draw: with no path picked a new one is added; each click on the ground is a knot.
	test::@check(app.begin_cut_path_drawing(), "drawing did not begin");
	test::@check(app.cut_pick == PATH_KNOT && app.cut_path_pick == 1, "drawing picks a new path");
	Vec3[4] clicked = { { 0, 0, 0 }, { 0, 0, 2 }, { 1, 0, 4 }, { 2, 0, 6 } };
	foreach (at : clicked) test::@check(app.finish_cut_pick(at), "a click did not add a knot");
	test::@check(app.cut_pick == PATH_KNOT, "drawing goes on until it is ended");
	app.cancel_cut_pick();
	WalkPath* path = app.cut_picked_path();
	test::@check(path && path.knots.len == 4, "the path has %d knots", path ? path.knots.len : 0);
	test::eq(cut_steps(app), steps + 5);
	float widest;
	for (usz k = 1; k < path.points.len; k++) widest = math::max(widest, (path.points[k] - path.points[k - 1]).length());
	test::@check(widest <= crig::WALK_PATH_SPACING + 1e-3f, "samples %f apart", widest);
	test::@check(near(path.length, crig::polyline_length(path.points), 1e-2f), "the length is its curve's, not %f", path.length);
	foreach (p : path.points) test::@check(math::abs(p.y) < 1e-4f, "with no level the walk lies on y = 0, not %f", p.y);
	float drawn = path.length;

	// A drag is one step, and the walk follows the knot.
	test::@check(app.begin_cut_knot_drag(0, 1), "the drag did not begin");
	test::@check(app.drag_cut_knot({ 0.5f, 0, 2 }), "drag");
	test::@check(app.drag_cut_knot({ 1.0f, 0, 2 }), "drag on");
	test::@check(close_to(app.cut_picked_path().knots[1], { 1.0f, 0, 2 }), "the knot follows the drag live");
	test::@check(app.end_cut_knot_drag(), "the drag did not land");
	test::eq(cut_steps(app), steps + 6);
	test::@check(!near(app.cut_picked_path().length, drawn, 1e-3f), "the path did not change length");
	test::@check(app.undo_cutscene(), "undo the drag");
	test::@check(close_to(app.cut_picked_path().knots[1], { 0, 0, 2 }), "one undo puts the knot back");
	test::@check(near(app.cut_picked_path().length, drawn, 1e-4f), "and the walk");
	test::@check(app.redo_cutscene(), "redo");
	test::@check(close_to(app.cut_picked_path().knots[1], { 1.0f, 0, 2 }), "redo moves it again");

	// Esc puts a dragged knot back and leaves no step; a press that does not move leaves none either.
	test::@check(app.begin_cut_knot_drag(0, 2), "another drag");
	test::@check(app.drag_cut_knot({ 3, 0, 4 }), "drag");
	app.cancel_cut_knot_drag();
	test::@check(close_to(app.cut_picked_path().knots[2], { 1, 0, 4 }), "Esc left the knot at %f", app.cut_picked_path().knots[2].x);
	test::@check(app.begin_cut_knot_drag(0, 2), "a press");
	test::@check(!app.end_cut_knot_drag(), "a drag that went nowhere left a step");
	test::eq(cut_steps(app), steps + 6);

	// Put in on the line between knots 1 and 2, then taken out.
	Vec3 between = { 1.0f, 0, 3.0f };
	test::@check(app.insert_cut_knot(0, between), "insert");
	test::@check(app.cut_picked_path().knots.len == 5 && close_to(app.cut_picked_path().knots[2], between), "the knot went in after knot 1");
	test::@check(app.cut_knot_pick == 3, "the new knot is picked");
	test::eq(cut_steps(app), steps + 7);
	test::@check(app.delete_cut_knot(0, 2), "delete");
	test::@check(app.cut_picked_path().knots.len == 4, "the knot went");
	test::eq(cut_steps(app), steps + 8);
	test::@check(app.undo_cutscene(), "undo the delete");
	test::@check(app.cut_picked_path().knots.len == 5, "undo brings it back");
	while (app.cut_picked_path().knots.len > 2) test::@check(app.delete_cut_knot(0, 0), "delete a knot");
	test::@check(!app.delete_cut_knot(0, 0), "a path keeps two knots");

	// Renamed and deleted, each one step; a move on it loses its path.
	test::@check(app.rename_cut_path(0, "Road"), "rename");
	test::@check(app.cut_picked_path().name == "Road", "the name");
	sz walked = app.walk_cut_path(0, 0);
	test::@check(walked >= 0, "Walk here added nothing");
	test::@check(app.delete_cut_path(0), "delete the path");
	test::@check(app.cutscene().paths.len == 0 && app.cut_path_pick == 0, "the path and its pick went");
	test::@check(app.cutscene().actors[0].strips[walked].path == -1, "the move lost its path");
	test::@check(app.undo_cutscene(), "undo the delete");
	test::@check(app.cutscene().paths.len == 1 && app.cutscene().actors[0].strips[walked].path == 0, "the path and the move's hold on it came back");
}

fn void walk_here_takes_the_ground_speed_and_a_resize_keeps_the_feet_on_the_ground() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "hero");
	(void)app.add_cutscene();
	test::@check(app.set_cutscene_timing(0, 60.0f, 30.0f), "a long cutscene");
	(void)app.add_cut_path("Road");
	test::@check(app.add_cut_knot(0, { 0, 0, 0 }) && app.add_cut_knot(0, { 0, 0, 6 }), "knots");
	float length = app.cut_picked_path().length;
	test::@check(near(length, 6.0f, 1e-3f), "a straight path of 6 m is %f", length);

	// Walk here: a clip named like a walk, along the path, its length the path's over the walk's ground speed.
	app.show_cutscene_at(1.0f);
	sz k = app.walk_cut_path(0, 0);
	test::@check(k >= 0, "Walk here added nothing");
	CutStrip* s = &app.cutscene().actors[0].strips[k];
	test::@check(s.kind == MOVE && s.clip.contains("Walk") && s.path == 0 && s.turn && s.loop, "the move is %s on path %d", s.clip, s.path);
	CutClipGround walk = app.cut_clip_ground(app.active, s.clip);
	test::@check(walk.speed > 0.1f && !walk.travels, "the hero's %s has a ground speed, not %f", s.clip, walk.speed);
	CutClipGround rest = app.cut_clip_ground(app.active, "Rest");
	test::@check(rest.speed < walk.speed * 0.25f, "its Rest stands still, not %f m/s", rest.speed);
	test::@check(near(s.start, 1.0f) && near(s.end - s.start, length / walk.speed, 1e-3f), "it lasts %f s, not %f", s.end - s.start, length / walk.speed);
	test::@check(near(s.speed, 1.0f, 1e-4f), "at its own pace it plays at %f", s.speed);
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	test::@check(problems.len == 0, "a walk with its ground speed has %d problems: %s", problems.len, problems.len > 0 ? problems[0] : "");

	// A drag on the end makes it twice as long: the clip plays at half speed.
	float start = s.start;
	float twice = start + (s.end - start) * 2.0f;
	test::@check(app.begin_cut_gesture(), "begin the resize");
	test::@check(app.drag_cut_strip(0, (usz)k, start, twice, false), "resize");
	test::@check(app.end_cut_gesture(0, (usz)k), "land it");
	s = &app.cutscene().actors[0].strips[k];
	test::@check(near(s.speed, 0.5f, 1e-3f), "twice as long plays at %f, not 0.5", s.speed);

	// A ground speed typed on the move: its clip's speed follows.
	CutStrip typed = s.copy(mem);
	typed.ground_speed = walk.speed * 0.5f;
	test::@check(app.set_cut_strip(0, (usz)k, typed), "type a ground speed");
	s = &app.cutscene().actors[0].strips[k];
	test::@check(near(s.speed, 1.0f, 1e-3f), "half the ground speed over twice the time plays at %f, not 1", s.speed);

	// A speed typed on its own is kept.
	CutStrip faster = s.copy(mem);
	faster.speed = 1.7f;
	test::@check(app.set_cut_strip(0, (usz)k, faster), "type a speed");
	test::@check(near(app.cutscene().actors[0].strips[k].speed, 1.7f), "the typed speed was overwritten");

	// Another path: the speed follows its length.
	(void)app.add_cut_path("Long");
	test::@check(app.add_cut_knot(1, { 2, 0, 0 }) && app.add_cut_knot(1, { 2, 0, 12 }), "a 12 m path");
	CutStrip moved = app.cutscene().actors[0].strips[k].copy(mem);
	moved.path = 1;
	test::@check(app.set_cut_strip(0, (usz)k, moved), "change the path");
	test::@check(near(app.cutscene().actors[0].strips[k].speed, 2.0f, 2e-3f), "twice the path plays at %f, not 2", app.cutscene().actors[0].strips[k].speed);

	// A walk clip with no ground speed is timed at 1 m/s and named.
	CutStrip resting = crig::cut_strip(MOVE, 20.0f, 21.0f);
	resting.clip = "Rest".copy(mem);
	resting.path = 0;
	(void)app.add_cut_strip(0, resting);
	String[] named = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, named);
	bool said;
	foreach (text : named) said = said || (text.contains("Rest") && text.contains("ground speed"));
	test::@check(said, "a move whose clip has no ground speed is not named");
}

fn void an_actor_standing_in_for_a_level_node_walks_lifted_paths() @test
{
	// A copy of the model, since saving the scene saves the characters beside their files.
	(void)path::mkdir(FOLDER, true);
	String hero_file = FOLDER.tconcat("/hero.glb");
	char[] bytes = file::load(mem, MODEL)!!;
	(void)file::save(hero_file, bytes);
	free(bytes);
	foreach (stale : (String[]){ "/hero.rigsmith.json", "/hero_copy.glb", "/hero_copy.rigsmith.json" }) (void)file::delete(FOLDER.tconcat(stale));
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f, hero_file)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "hero");
	// As a level node's stand-in whose origin is 1.05 m over its feet.
	app.set_level_node("hero_armature");
	app.stage_lift = 1.05f;
	usz hero = app.active;
	String extra = second_model();
	test::@check(app.add_actor_from_file(extra, "guide"), "a second actor");
	(void)app.focus_character(hero);
	(void)app.add_cutscene();
	(void)app.add_cut_path("Road");
	test::@check(app.add_cut_knot(0, { 0, 0, 0 }) && app.add_cut_knot(0, { 0, 0.5f, 4 }), "knots");
	test::@check(app.walk_cut_path(0, 0) >= 0 && app.walk_cut_path(1, 0) >= 0, "both walk the road");

	(void)path::mkdir(FOLDER, true);
	String target = FOLDER.tconcat("/lifted.cutscene.glb");
	(void)file::delete(target);
	test::@check(app.export_cutscene(target), "not exported");
	Cutscene back = crig::read_cutscene_file(mem, target)!!;
	defer back.free(mem);
	test::@check(back.paths.len == 2, "the road is written once per lift: %d paths", back.paths.len);
	if (back.paths.len != 2) return;
	int hero_path = back.actors[back.actor_by_row("hero")].strips[0].path;
	int guide_path = back.actors[back.actor_by_row("guide")].strips[0].path;
	test::@check(hero_path != guide_path, "the two walk the same written path");
	Vec3[] lifted = back.paths[hero_path].points;
	Vec3[] ground = back.paths[guide_path].points;
	test::@check(lifted.len == ground.len && lifted.len >= 2, "the lifted road has %d points, the other %d", lifted.len, ground.len);
	foreach (usz i, p : ground) test::@check(near(lifted[i].y - p.y, 1.05f, 2e-3f), "point %d is lifted by %f", i, lifted[i].y - p.y);
	test::@check(near(back.paths[hero_path].length, back.paths[guide_path].length, 1e-3f), "lifting keeps the length");
	test::@check(near(ground[0].y, 0.0f, 1e-3f) && near(ground[^1].y, 0.5f, 1e-3f), "the guide's road is where its feet go");

	// The scene file keeps the lift and a typed ground speed.
	app.cutscene().actors[0].strips[0].ground_speed = 1.25f;
	String scene = FOLDER.tconcat("/lifted.rigsmith-scene.json");
	test::@check(app.save_scene(scene), "the scene was not saved");
	SceneFile kept = crig::parse_scene_file(mem, (String)file::load_temp(scene)!!, scene)!!;
	defer kept.free(mem);
	bool lift_kept;
	foreach (c : kept.characters) lift_kept = lift_kept || (c.row == "hero" && near(c.lift, 1.05f));
	test::@check(lift_kept, "the scene lost the lift");
	test::@check(near(kept.cutscenes[0].actors[0].strips[0].ground_speed, 1.25f), "the scene lost the typed ground speed");
}

<*
 One-off acting in the app: a new one-off, edited with the character's own tools
 standing where the cutscene has it, undone step by step inside and as one step
 after, kept by the scene and never by the character's own files, exported with
 only the joints it keys, in the level armature's frames for a stand-in; and
 stand-ins reading their level node again as the level comes in.

     `c3c test --test-filter crig_tests::cutscene_one_off_app`
*>
module crig_tests::cutscene_one_off_app;

import crig;
import crig_tests::mcp;
import crig_tests::helpers;
import rig;
import std::collections::object;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

const String MODEL @local = "assets/animations/humanoid.glb";
const String FOLDER @local = "build/cutscene-one-off-app";

// A fresh copy of the model in `name`, its sidecars from an earlier run gone.
fn String fresh_model(String name) @local
{
	(void)path::mkdir(FOLDER, true);
	String target = string::tformat("%s/%s.glb", FOLDER, name);
	char[] bytes = file::load(mem, MODEL)!!;
	defer free(bytes);
	(void)file::save(target, bytes);
	foreach (stale : (String[]){ ".rigsmith.json", "_copy.glb", "_copy.rigsmith.json" })
	{
		(void)file::delete(string::tformat("%s/%s%s", FOLDER, name, stale));
	}
	return target;
}

// The hero with a Walk of its own, saved so its files are there to stay untouched.
fn bool open_hero(Fixture* f, String model) @local
{
	if (!f.open_model(model)) return false;
	String args = string::tformat(`{"path":"%s","clip":"Walk_slow","name":"Walk"}`, MODEL);
	String? answer = f.call_tool_text("import_clip", args);
	if (catch answer)
	{
		test::@check(false, "the walk did not import");
		return false;
	}
	answer.free(mem);
	f.app.save_session();
	return true;
}

fn bool posed(Fixture* f, String args) @local
{
	Object* answer = f.call_checked("pose_joint", args);
	if (!answer) return false;
	answer.free();
	return true;
}

fn char[] bytes_of(String file) @local => file::load(mem, file) ?? (char[]){};

fn usz keyed_dots(AnimTemplate* clip) @local
{
	usz count;
	foreach (&k : clip.keyframes) count += k.dots.len;
	return count;
}

fn void a_one_off_is_edited_with_the_own_tools_and_kept_by_the_cutscene() @test
{
	String model = fresh_model("hero");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f, model)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	String own_file = app.source_path.copy(mem);
	defer own_file.free(mem);
	String own_sidecar = crig::session_path(mem, own_file);
	defer own_sidecar.free(mem);
	char[] own_glb = bytes_of(own_file);
	defer free(own_glb);
	char[] own_json = bytes_of(own_sidecar);
	defer free(own_json);
	test::@check(own_glb.len > 0 && own_json.len > 0, "the hero's own files were not saved");
	usz own_clips = (usz)app.doc.animations.len();

	test::@check(app.make_actor(app.active, "hero"), "the hero is no actor");
	(void)app.add_cutscene();
	app.show_cutscene_at(1.0f);
	usz steps = helpers::cut_steps(app);

	// New one-off: an empty clip of the cutscene and a 2 s strip of it at the playhead, one step.
	sz k = app.new_cut_one_off(0);
	test::@check(k >= 0, "no strip was added");
	if (k < 0) return;
	Cutscene* c = app.cutscene();
	CutStrip* s = &c.actors[0].strips[k];
	test::@check(s.one_off && s.clip == "one_off" && math::is_approx(s.start, 1.0f, 1e-3f) && math::is_approx(s.end, 3.0f, 1e-3f), "the strip is %s %f-%f", s.clip, s.start, s.end);
	test::@check(c.one_offs.len == 1 && c.one_offs[0].row == "hero", "the one-off is not the hero's");
	test::eq(helpers::cut_steps(app), steps + 1);
	test::eq((usz)app.doc.animations.len(), own_clips);

	// Edit: the hero's own tools on the one-off alone, staged where the cutscene stands it.
	test::@check(app.edit_cut_one_off(0, (usz)k), "the one-off would not open");
	test::@check(app.one_off_open() && app.one_off_here(), "not editing the one-off");
	test::@check(app.doc.animations.len() == 1 && app.doc.animations[0].clip == "one_off", "the Animations list holds %d clips", app.doc.animations.len());
	test::@check(app.staged, "the hero is not standing where the cutscene has it");
	test::@check(app.undo_stack.edits.len() == 0, "the one-off starts with the character's history");

	// Two keys: the left arm raised by the end.
	test::@check(posed(f, `{"joint":"shoulder_L","turn":{"axis":"z","angle":0.6},"time":0}`), "the first key");
	test::@check(posed(f, `{"joint":"shoulder_L","turn":{"axis":"z","angle":1.4},"time":1.5}`), "the second key");
	(void)app.tick_one_off();
	CutOneOff* one = &app.cutscene().one_offs[0];
	test::@check(one.clip.keyframes.len >= 2 && keyed_dots(&one.clip) >= 2, "the cutscene's copy has %d keys", one.clip.keyframes.len);
	foreach (&key : one.clip.keyframes) foreach (dot : key.dots)
	{
		test::@check(dot.joint_name == "shoulder_L", "a key on %s, which was never posed", dot.joint_name);
	}
	test::@check(math::is_approx(app.cut_time, 1.0f + 1.5f, 1e-3f), "the others stand at %f, the cutscene time the playhead stands for", app.cut_time);
	test::eq(helpers::cut_steps(app), steps + 1);

	// Undo steps the one-off's own edits, and only them.
	usz keys = keyed_dots(&app.cutscene().one_offs[0].clip);
	test::@check(app.undo_latest(), "nothing to undo in the one-off");
	(void)app.tick_one_off();
	test::@check(keyed_dots(&app.cutscene().one_offs[0].clip) < keys, "undo did not take the last key back");
	test::eq(helpers::cut_steps(app), steps + 1);
	test::@check(app.redo_latest(), "redo");
	(void)app.tick_one_off();
	test::eq(keyed_dots(&app.cutscene().one_offs[0].clip), keys);

	// A scene saved meanwhile keeps the edit, and writes nothing of it into the hero's files.
	String scene = FOLDER.tconcat("/acting.rigsmith-scene.json");
	test::@check(app.save_scene(scene), "the scene was not saved");
	test::@check(app.one_off_open(), "saving ended the edit");
	char[] after_glb = bytes_of(own_file);
	defer free(after_glb);
	char[] after_json = bytes_of(own_sidecar);
	defer free(after_json);
	test::@check(after_glb == own_glb && after_json == own_json, "the scene save wrote the hero's own files");
	SceneFile kept = crig::read_scene_file(mem, scene)!!;
	defer kept.free(mem);
	test::@check(kept.cutscenes.len == 1 && kept.cutscenes[0].one_offs.len == 1, "the scene lost the one-off");
	if (kept.cutscenes.len == 1 && kept.cutscenes[0].one_offs.len == 1)
	{
		test::eq(keyed_dots(&kept.cutscenes[0].one_offs[0].clip), keys);
		test::@check(kept.cutscenes[0].actors[0].strips[0].one_off, "the scene lost which strip plays it");
	}

	// Back: one step of the cutscene history; the hero has its own clips and history again.
	test::@check(app.back_to_cutscene(), "back");
	test::@check(!app.one_off_open() && !app.staged, "still editing");
	test::eq((usz)app.doc.animations.len(), own_clips);
	foreach (bound : app.doc.animations) test::@check(bound.clip != "one_off", "the one-off was left among the hero's clips");
	test::eq(helpers::cut_steps(app), steps + 2);
	test::@check(math::is_approx(app.cut_time, 2.5f, 1e-3f), "the playhead came back at %f", app.cut_time);
	// Ctrl+Z takes the whole edit back at once, and redo brings it back.
	test::@check(app.undo_latest(), "undo the edit");
	test::eq(keyed_dots(&app.cutscene().one_offs[0].clip), (usz)0);
	test::@check(app.redo_latest(), "redo the edit");
	test::eq(keyed_dots(&app.cutscene().one_offs[0].clip), keys);

	// Exported: one animation, a channel only for the joint it keys.
	String target = FOLDER.tconcat("/acting.cutscene.glb");
	(void)file::delete(target);
	test::@check(app.export_cutscene(target), "not exported");
	test::@check(app.notice().contains("· 1 actor,"), "the notice reads '%s'", app.notice());
	CutAnimation[] read;
	Cutscene back = crig::read_cutscene_file(mem, target, null, &read)!!;
	defer back.free(mem);
	defer crig::free_cut_animations(mem, read);
	test::@check(read.len == 1 && back.actors[0].strips[0].animation == 0, "%d animations written", read.len);
	if (read.len == 1)
	{
		test::@check(read[0].name == "one_off" && read[0].channels.len > 0, "the animation is '%s'", read[0].name);
		foreach (&ch : read[0].channels) test::@check(ch.bone == "shoulder_L", "a channel on %s, which it does not key", ch.bone);
	}
	test::@check(back.actors[0].strips[0].end > back.actors[0].strips[0].start + 1.4f, "the strip did not follow its clip");

	// Deleting the last strip that plays it takes it away in the same step.
	usz before = helpers::cut_steps(app);
	test::@check(app.delete_cut_strip(0, 0), "delete the strip");
	test::@check(app.cutscene().one_offs.len == 0, "the one-off outlived its last strip");
	test::eq(helpers::cut_steps(app), before + 1);
	test::@check(app.undo_cutscene(), "undo the delete");
	test::@check(app.cutscene().one_offs.len == 1 && app.cutscene().actors[0].strips.len == 1, "the strip and its one-off came back");

	// Reopened, the scene has it, and the hero's files still have nothing of it.
	test::@check(app.open_scene(scene), "the scene would not reopen");
	test::@check(app.cutscene() && app.cutscene().one_offs.len == 1, "the reopened scene lost the one-off");
	test::eq(keyed_dots(&app.cutscene().one_offs[0].clip), keys);
	foreach (bound : app.doc.animations) test::@check(bound.clip != "one_off", "the reopened hero has the one-off as its own");
	char[] last_glb = bytes_of(own_file);
	defer free(last_glb);
	test::@check(last_glb == own_glb, "the hero's own file changed");
}

fn void a_hand_pinned_to_the_level_is_baked_into_the_one_off() @test
{
	String model = fresh_model("pinner");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f, model)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "the hero is no actor");
	(void)app.add_cutscene();
	sz k = app.new_cut_one_off(0);
	test::@check(k >= 0 && app.edit_cut_one_off(0, (usz)k), "the one-off would not open");

	// The left hand reaches a point of the level, drawn where the cutscene stands the hero, and is held there.
	Vec3 wrist = app.dot_position(*app.dot_named("wrist_L"));
	Vec3 world = app.placement().point(wrist * app.drawn_scale()) + (Vec3){ 0.0f, 0.25f, 0.1f };
	test::@check(posed(f, string::tformat(`{"joint":"wrist_L","world_target":[%f,%f,%f],"time":0}`, world.x, world.y, world.z)),
		"the hand would not reach the point");
	Object* pinned = f.call_checked("set_pins", `{"pins":[{"joint":"wrist_L"}]}`);
	if (pinned) pinned.free();
	test::@check(app.clip(app.editing).pins.len == 1, "the hand is not pinned");
	test::@check(app.back_to_cutscene(), "back");

	String target = FOLDER.tconcat("/pinned.cutscene.glb");
	(void)file::delete(target);
	test::@check(app.export_cutscene(target), "not exported");
	CutAnimation[] read;
	Cutscene back = crig::read_cutscene_file(mem, target, null, &read)!!;
	defer back.free(mem);
	defer crig::free_cut_animations(mem, read);
	test::@check(read.len == 1, "%d animations", read.len);
	if (read.len != 1) return;
	// The pin is in the keys: the arm's chain is written, and nothing below the hips.
	bool elbow;
	foreach (&ch : read[0].channels)
	{
		elbow = elbow || ch.bone == "elbow_L";
		test::@check(ch.bone != "thigh_L" && ch.bone != "knee_R" && ch.bone != "head", "a channel on %s", ch.bone);
	}
	test::@check(elbow, "the elbow the pin bends is not written");
}

// The hero's own rig at rest, as a level holds it, with what `change` does to it.
fn JointRest[] level_copy_of(crig::AppState* app, String joint, Vec3 shift, Quaternionf turn = quaternion::IDENTITY) @local
{
	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	JointRest[] rests = crig::skeleton_rests(mem, &view.skeleton, view.names);
	defer free(rests);
	foreach (&r : rests)
	{
		if (r.name != joint) continue;
		r.translation += shift;
		r.rotation = turn;
	}
	return crig::copy_joint_rests(mem, rests);
}

fn void a_stand_in_plays_its_one_off_in_the_level_armatures_frames() @test
{
	String model = fresh_model("standin");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f, model)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "the hero is no actor");
	app.set_level_node("hero_armature");
	(void)app.add_cutscene();
	sz k = app.new_cut_one_off(0);
	test::@check(k >= 0 && app.edit_cut_one_off(0, (usz)k), "the one-off would not open");
	test::@check(posed(f, `{"joint":"hips","move":[0,-0.1,0],"time":0.5}`), "the hips would not crouch");
	test::@check(app.back_to_cutscene(), "back");

	// No level in: its armature's frames are unknown, so the export says so.
	String target = FOLDER.tconcat("/standin.cutscene.glb");
	(void)file::delete(target);
	DString why = dstring::new(mem);
	defer why.free();
	test::@check(!app.export_cutscene(target, &why) && why.str_view().contains("open the level"), "the refusal is '%s'", why.str_view());

	// The level's armature has its origin at the hips: they rest near its local y 0.
	RigView view = app.open_rig(mem)!!;
	Vec3 own_hips = view.skeleton.joints[0];
	view.free(mem);
	Vec3 shift = { 0.004f, -0.035f, 0.061f } - own_hips;
	JointRest[] level = level_copy_of(app, "hips", shift);
	app.set_stage_rig(level);
	crig::free_joint_rests(mem, level);
	why.clear();
	test::@check(app.export_cutscene(target, &why), "not exported: %s", why.str_view());
	CutAnimation[] read;
	Cutscene back = crig::read_cutscene_file(mem, target, null, &read)!!;
	defer back.free(mem);
	defer crig::free_cut_animations(mem, read);
	test::@check(read.len == 1, "%d animations", read.len);
	if (read.len != 1) return;
	sz hips = -1;
	foreach (usz i, &ch : read[0].channels) if (ch.bone == "hips" && ch.path == TRANSLATION) hips = (sz)i;
	test::@check(hips >= 0, "the hips' slide is not written");
	if (hips < 0) return;
	CutChannel* h = &read[0].channels[hips];
	// The same clip baked on the hero's own rig: in the level's frames every key sits that much lower and back.
	RigView own_view = app.open_rig(mem)!!;
	defer own_view.free(mem);
	AnimTemplate clip = crig::clip_copy(mem, app.cutscene().one_offs[0].clip);
	defer clip.free(mem);
	clip.compile_tracks(mem);
	CutAnimation own = crig::bake_one_off(mem, &own_view.skeleton, own_view.names, &clip, 0, "own");
	defer own.free(mem);
	sz baked_hips = -1;
	foreach (usz i, &ch : own.channels) if (ch.bone == "hips" && ch.path == TRANSLATION) baked_hips = (sz)i;
	test::@check(baked_hips >= 0 && own.channels[baked_hips].values.len == h.values.len, "the own bake differs in its keys");
	if (baked_hips < 0 || own.channels[baked_hips].values.len != h.values.len) return;
	for (usz i = 0; i + 2 < h.values.len; i += 3)
	{
		Vec3 moved = (Vec3){ h.values[i], h.values[i + 1], h.values[i + 2] }
			- (Vec3){ own.channels[baked_hips].values[i], own.channels[baked_hips].values[i + 1], own.channels[baked_hips].values[i + 2] };
		test::@check((moved - shift).length() < 1e-4f, "key %d is moved by [%f, %f, %f], not by the rest's shift", i / 3, moved.x, moved.y, moved.z);
	}
	// The crouch itself survives: below the armature's rest height.
	test::@check(h.values[1] < -0.035f - 0.05f, "the crouch is lost: the hips at %f", h.values[1]);

	// A level rig whose hips rest turned another way is another rig: named, and refused.
	level = level_copy_of(app, "hips", shift, { .v = { 0.0f, 0.9969f, 0.0f, 0.0783f } });
	app.set_stage_rig(level);
	crig::free_joint_rests(mem, level);
	why.clear();
	test::@check(!app.export_cutscene(target, &why) && why.str_view().contains("another rig"), "the refusal is '%s'", why.str_view());
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	bool named;
	foreach (text : problems) named = named || (text.contains("another rig") && text.contains("hips"));
	test::@check(named, "the problems list does not name the other rig");
}

fn void a_stand_in_reads_its_level_node_again_when_the_level_comes_in() @test
{
	String model = fresh_model("restaged");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(model)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "the hero is no actor");
	app.set_level_node("hero_armature");
	rig::Bounds own = crig::placed_bounds(&app.geometry, {}, 1.0f);
	float tall = own.max.y - own.min.y;

	// The level re-exported: the node moved, turned, grew and has its origin higher over its feet.
	JointRest[1] rig = { { "hips", "", { 0, 0, 0 }, quaternion::IDENTITY, { 1, 1, 1 } } };
	Quaternionf turned = { .v = { 0.0f, 0.7071068f, 0.0f, 0.7071068f } };
	LevelCharacter[1] found = { { .name = "hero_armature", .position = { 2.0f, 1.05f, -3.0f }, .rotation = turned,
		.height = tall * 1.5f, .floor = 0.1f, .rig = rig[..] } };
	app.restage_actors(found[..]);
	test::@check(math::is_approx(app.stage_scale, 1.5f, 1e-3f) && math::is_approx(app.stage_lift, 0.95f, 1e-3f), "scale %f, lift %f", app.stage_scale, app.stage_lift);
	Vec3 at = app.doc.model_transform.location;
	test::@check(math::is_approx(at.x, 2.0f, 1e-3f) && math::is_approx(at.z, -3.0f, 1e-3f) && math::is_approx(at.y, 0.1f - own.min.y * 1.5f, 1e-3f), "it stands at [%f, %f, %f]", at.x, at.y, at.z);
	test::@check(app.doc.model_transform.orientation().v == turned.v, "it does not face the node's way");
	test::@check(app.stage_rig.len == 1 && app.stage_rig[0].name == "hips", "the level's rig was not read");
	test::@check(!app.stage_missing, "a node that is there is missing");

	// Gone from the level: it keeps what it had, and the problems list says so.
	(void)app.add_cutscene();
	app.restage_actors({});
	test::@check(app.stage_missing, "a gone node was not noticed");
	test::@check(math::is_approx(app.doc.model_transform.location.x, 2.0f, 1e-3f) && math::is_approx(app.stage_scale, 1.5f, 1e-3f), "it did not keep its place");
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	bool named;
	foreach (text : problems) named = named || text.contains("no longer in the level");
	test::@check(named, "the problems list does not say the node is gone");
}

fn void an_agent_makes_and_edits_a_one_off_over_the_wire() @test
{
	String model = fresh_model("agent");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f, model)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	Object* listed = f.call_checked("add_actor", `{"row":"hero"}`);
	if (!listed) return;
	listed.free();
	Object* made = f.call_checked("set_cutscene", `{"new":true,"name":"Act"}`);
	if (!made) return;
	made.free();

	// A one-off written whole: a key per bone in the session file's form, and a strip that plays it.
	String shape = `{"cutscene":{"name":"Act","duration":4,"fps":30,"actors":[{"row":"hero","strips":[
		{"type":"play","start":0.5,"end":1.5,"clip":"nod","one_off":true,"loop":false}]}],"paths":[],
		"one_offs":[{"row":"hero","clip":{"name":"nod","duration":1,"loop":false,"blend":"smooth","keys":[
			{"time":0,"dots":[{"joint":"head","axis":[1,0,0],"angle":0,"move":[0,0,0],"bone":[0,0,0],"channels":"rotation"}]},
			{"time":0.5,"dots":[{"joint":"head","axis":[1,0,0],"angle":0.4,"move":[0,0,0],"bone":[0,0,0],"channels":"rotation"}]}]}}]}}`;
	Object* set = f.call_checked("set_cutscene", shape);
	if (!set) return;
	defer set.free();
	Object* one_offs = set.get("cutscene")!!.get("one_offs")!!;
	test::@check(one_offs.get_len() == 1 && one_offs.get_at(0).get("clip")!!.get_string("name")!! == "nod", "the one-off did not go in");
	test::@check(set.get("cutscene")!!.get("actors")!!.get_at(0).get("strips")!!.get_at(0).get_bool("one_off")!!, "the strip lost its one-off");
	test::@check(set.get("problems")!!.get_len() == 0, "the one-off has %d problems", set.get("problems")!!.get_len());

	// Edited over the wire with the pose tools, then back as one cutscene step.
	usz steps = helpers::cut_steps(app);
	Object* opened = f.call_checked("set_cutscene_time", `{"one_off":{"actor":"hero","strip":0}}`);
	if (!opened) return;
	defer opened.free();
	test::@check(opened.get("one_off")!!.get_string("clip")!! == "nod", "the answer does not say what is edited");
	test::@check(posed(f, `{"joint":"shoulder_R","turn":{"axis":"z","angle":-0.8},"time":0.25}`), "pose the one-off");
	Object* report = f.call_checked("get_cutscene", `{}`);
	if (!report) return;
	defer report.free();
	Object* keys = report.get("cutscene")!!.get("one_offs")!!.get_at(0).get("clip")!!.get("keys")!!;
	bool shoulder;
	for (usz i = 0; i < (usz)keys.get_len(); i++)
	{
		Object* dots = keys.get_at((sz)i).get("dots")!!;
		for (usz d = 0; d < (usz)dots.get_len(); d++) shoulder = shoulder || dots.get_at((sz)d).get_string("joint")!! == "shoulder_R";
	}
	test::@check(shoulder, "get_cutscene does not show the edit being made");
	Object* closed = f.call_checked("set_cutscene_time", `{"one_off":false}`);
	if (!closed) return;
	defer closed.free();
	test::@check(!app.one_off_open() && helpers::cut_steps(app) == steps + 1, "back was %d steps", helpers::cut_steps(app) - steps);
}

fn void the_playing_preview_fades_into_a_one_off_from_the_walk_before_it() @test
{
	String model = fresh_model("fader");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_hero(f, model)) return;
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.make_actor(app.active, "hero"), "the hero is no actor");
	(void)app.add_cutscene();
	app.show_cutscene_at(0.0f);
	test::@check(app.add_cut_play(0, "Walk") >= 0, "no walk");
	app.show_cutscene_at(app.cutscene().actors[0].strips[0].end);
	sz k = app.new_cut_one_off(0);
	test::@check(k >= 0 && app.edit_cut_one_off(0, (usz)k), "the one-off would not open");
	test::@check(posed(f, `{"joint":"shoulder_L","turn":{"axis":"z","angle":1.0},"time":0}`), "pose the one-off");
	test::@check(app.back_to_cutscene(), "back");
	CutStrip edited = app.cutscene().actors[0].strips[k].copy(mem);
	edited.fade = 0.5f;
	float start = edited.start;
	test::@check(app.set_cut_strip(0, (usz)k, edited), "the fade");

	RigView view = app.open_rig(mem)!!;
	sz thigh = -1;
	foreach (usz j, name : view.names) if (name == "thigh_L") thigh = (sz)j;
	view.free(mem);
	if (thigh < 0) return;

	// Scrubbed it is a cut, as in the game: the thigh the one-off does not key is at rest.
	test::@check(app.set_cutscene_preview(true), "preview");
	app.show_cutscene_at(start + 0.2f);
	test::@check(math::abs(app.player_pose.rotations[thigh].v.w) > 0.9999f, "a scrubbed frame fades");
	// Playing, the thigh keeps the walk's last frame through the fade, and the clip the hero walked is it.
	app.cut_playing = true;
	app.show_cutscene_at(start + 0.2f);
	test::@check(app.cut_fading && app.cut_fade_weight > 0.3f && app.cut_fade_weight < 0.5f, "no fade at 0.2 s of 0.5 s");
	test::@check(math::abs(app.player_pose.rotations[thigh].v.w) < 0.9999f, "the thigh dropped to rest inside the fade");
	app.show_cutscene_at(start + 0.8f);
	test::@check(!app.cut_fading, "the fade outlived its half second");
	app.cut_playing = false;
}

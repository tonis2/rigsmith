<*
 Characters read straight from the level file by their armature: the reader, two
 taken from one file and where they stand, their clips, the problems list, the
 scene file, the read-only rule, and a one-off exported in the armature's own
 joint frames. The level is a small .gltf written here.

     `c3c test --test-filter crig_tests::level_actor`
*>
module crig_tests::level_actor;

import crig;
import crig_tests::mcp;
import crig_tests::helpers;
import gltf;
import rig;
import std::collections::object;
import std::core::test;
import std::encoding::base64;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

const String FOLDER @local = "build/level-actor";
const Quaternionf YAW_90 @local = { .v = { 0, 0.70710678f, 0, 0.70710678f } };
const Quaternionf ROLL_90 @local = { .v = { 0, 0, 0.70710678f, 0.70710678f } };

fn Quaternionf about(Vec3 axis, float degrees) @local
{
	return quaternion::from_axis_angle{float}(axis, degrees * (float)math::PI / 180.0f);
}

fn void put4(float[] f, usz* at, Quaternionf q) @local
{
	f[*at] = q.v.x;
	f[*at + 1] = q.v.y;
	f[*at + 2] = q.v.z;
	f[*at + 3] = q.v.w;
	*at += 4;
}

fn void put3(float[] f, usz* at, Vec3 v) @local
{
	f[*at] = v.x;
	f[*at + 1] = v.y;
	f[*at + 2] = v.z;
	*at += 3;
}

<*
 Two characters in one level: a hero turned a quarter round at 1.5 times its size, its origin at
 its hips and its hips resting turned; a guide as it is. Three clips: one each, and one for both.
 Written under `folder`; the caller owns the path.
*>
fn String write_level(String folder) @local
{
	(void)path::mkdir(folder, true);
	float[48] f;
	usz at;
	f[at++] = 0.0f;
	f[at++] = 1.0f;
	put4(&f, &at, ROLL_90);
	put4(&f, &at, ROLL_90.mul(about({ 1, 0, 0 }, 45.0f)).normalize());
	put3(&f, &at, { 0, 0, 0 });
	put3(&f, &at, { 0, -0.2f, 0 });
	put4(&f, &at, YAW_90);
	put4(&f, &at, YAW_90.mul(about({ 0, 1, 0 }, 30.0f)).normalize());
	put3(&f, &at, { 0, 0.7f, 0 });
	put3(&f, &at, { 0, 0.6f, 0 });
	put3(&f, &at, { -0.3f, -0.9f, 0 });
	put3(&f, &at, { 0.3f, -0.9f, 0 });
	put3(&f, &at, { 0, 0.6f, 0.1f });
	put3(&f, &at, { -0.25f, -0.9f, 0 });
	put3(&f, &at, { 0.25f, -0.9f, 0 });
	put3(&f, &at, { 0, 0.8f, 0.1f });
	char[] bytes = ((char*)&f)[:48 * 4];
	String encoded = base64::encode(mem, bytes);
	defer encoded.free(mem);
	String json = string::format(mem, `{
  "asset": { "version": "2.0" },
  "scene": 0,
  "scenes": [ { "nodes": [0, 1, 6] } ],
  "nodes": [
    { "name": "ground" },
    { "name": "hero_rig", "translation": [2, 1, -1], "rotation": [0, 0.70710678, 0, 0.70710678], "scale": [1.5, 1.5, 1.5], "children": [2, 5] },
    { "name": "hips", "rotation": [0, 0.70710678, 0, 0.70710678], "children": [3] },
    { "name": "spine", "translation": [0, 0.4, 0], "children": [4] },
    { "name": "arm", "translation": [0, 0.3, 0], "rotation": [0, 0, 0.70710678, 0.70710678] },
    { "name": "hero_body", "mesh": 0, "skin": 0 },
    { "name": "guide_rig", "translation": [-1, 0.9, 3], "children": [7, 9] },
    { "name": "root", "children": [8] },
    { "name": "head", "translation": [0, 0.7, 0] },
    { "name": "guide_body", "mesh": 1, "skin": 1 }
  ],
  "skins": [ { "joints": [2, 3, 4] }, { "joints": [7, 8] } ],
  "meshes": [
    { "name": "hero_body", "primitives": [ { "attributes": { "POSITION": 5 } } ] },
    { "name": "guide_body", "primitives": [ { "attributes": { "POSITION": 6 } } ] }
  ],
  "buffers": [ { "byteLength": 192, "uri": "data:application/octet-stream;base64,%s" } ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0, "byteLength": 8 },
    { "buffer": 0, "byteOffset": 8, "byteLength": 32 },
    { "buffer": 0, "byteOffset": 40, "byteLength": 24 },
    { "buffer": 0, "byteOffset": 64, "byteLength": 32 },
    { "buffer": 0, "byteOffset": 96, "byteLength": 24 },
    { "buffer": 0, "byteOffset": 120, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 156, "byteLength": 36 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 2, "type": "SCALAR", "min": [0], "max": [1] },
    { "bufferView": 1, "componentType": 5126, "count": 2, "type": "VEC4" },
    { "bufferView": 2, "componentType": 5126, "count": 2, "type": "VEC3" },
    { "bufferView": 3, "componentType": 5126, "count": 2, "type": "VEC4" },
    { "bufferView": 4, "componentType": 5126, "count": 2, "type": "VEC3" },
    { "bufferView": 5, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-0.3, -0.9, 0], "max": [0.3, 0.6, 0.1] },
    { "bufferView": 6, "componentType": 5126, "count": 3, "type": "VEC3", "min": [-0.25, -0.9, 0], "max": [0.25, 0.8, 0.1] }
  ],
  "animations": [
    { "name": "wave", "samplers": [ { "input": 0, "output": 1 } ], "channels": [ { "sampler": 0, "target": { "node": 4, "path": "rotation" } } ] },
    { "name": "crouch", "samplers": [ { "input": 0, "output": 2 } ], "channels": [ { "sampler": 0, "target": { "node": 7, "path": "translation" } } ] },
    { "name": "both", "samplers": [ { "input": 0, "output": 3 }, { "input": 0, "output": 4 } ],
      "channels": [ { "sampler": 0, "target": { "node": 2, "path": "rotation" } }, { "sampler": 1, "target": { "node": 8, "path": "translation" } } ] }
  ]
}`, encoded);
	defer json.free(mem);
	String target = string::format(mem, "%s/forest.gltf", folder);
	file::save(target, (char[])json)!!;
	return target;
}

// The files in a folder, one name per line, sorted as the folder lists them.
fn String folder_listing(String folder) @local
{
	DString out = dstring::new(mem);
	defer out.free();
	@pool()
	{
		PathList? listed = path::ls(tmem, (Path)folder);
		if (try listed) foreach (p : listed) out.appendf("%s\n", (String)p)!!;
	};
	return out.copy_str(mem);
}

fn bool has_clip(crig::AppState* app, String name) @local
{
	foreach (b : app.doc.animations) if (b.clip == name) return true;
	return false;
}

// ---------------------------------------------------------------------------
// The reader

fn void a_level_file_is_read_by_its_armature() @test
{
	String level = write_level(FOLDER);
	defer level.free(mem);
	gltf::GltfStream stream = gltf::open(level, mem)!!;
	defer stream.close();

	String[] armatures = crig::level_armatures(mem, &stream);
	defer if (armatures.len > 0) free(armatures);
	test::@check(armatures.len == 2 && armatures[0] == "hero_rig" && armatures[1] == "guide_rig", "%d rigged characters", armatures.len);

	LevelRig hero = crig::read_level_rig(mem, &stream, "hero_rig")!!;
	defer hero.free(mem);
	test::@check(helpers::near3(hero.position, { 2, 1, -1 }, 1e-3f) && math::is_approx(hero.scale.y, 1.5f, 1e-3f), "it stands at %s, scaled %f", hero.position, hero.scale.y);
	test::@check(helpers::turn_between(hero.rotation, YAW_90) < 1e-3f, "it faces the node's way");
	test::@check(math::is_approx(hero.bounds.min.y, -0.9f, 1e-3f) && math::is_approx(hero.bounds.max.y, 0.6f, 1e-3f), "its mesh rests from %f to %f", hero.bounds.min.y, hero.bounds.max.y);
	test::@check(hero.skeleton.len() == 3, "%d joints, not its own three", hero.skeleton.len());
	if (hero.skeleton.len() != 3) return;
	// In the armature's own space: unturned and unscaled by the level.
	Vec3[3] want = { { 0, 0, 0 }, { 0, 0.4f, 0 }, { 0, 0.7f, 0 } };
	String[3] names = { "hips", "spine", "arm" };
	foreach (usz j, w : want)
	{
		test::@check(hero.names[j] == names[j], "joint %d is %s", j, hero.names[j]);
		test::@check(helpers::near3(hero.skeleton.joints[j], w, 1e-3f), "%s rests at %s in the armature", names[j], hero.skeleton.joints[j]);
	}
	test::@check(hero.rest.len == 3 && hero.rest[0].name == "hips" && hero.rest[0].parent == "", "the skin's rest starts at the hips");
	test::@check(helpers::turn_between(hero.rest[0].rotation, YAW_90) < 1e-3f && math::is_approx(hero.rest[0].scale.y, 1.0f, 1e-3f), "the hips rest turned, in the armature's space");
	test::@check(hero.rest[2].parent == "spine" && helpers::turn_between(hero.rest[2].rotation, ROLL_90) < 1e-3f, "the arm rests on the spine, rolled");
	// The clips that drive its joints, by the file's own names.
	test::@check(hero.clips.len == 2 && hero.clips[0].name == "wave" && hero.clips[1].name == "both", "the hero's clips");

	LevelRig guide = crig::read_level_rig(mem, &stream, "guide_rig")!!;
	defer guide.free(mem);
	test::@check(guide.skeleton.len() == 2 && guide.clips.len == 2 && guide.clips[0].name == "crouch" && guide.clips[1].name == "both",
		"the guide has %d joints and %d clips", guide.skeleton.len(), guide.clips.len);

	test::@check(@catch(crig::read_level_rig(mem, &stream, "nobody")) == crig::LEVEL_RIG_NO_ARMATURE, "a node the level lacks");
	test::@check(@catch(crig::read_level_rig(mem, &stream, "ground")) == crig::LEVEL_RIG_NO_SKIN, "a node with no skinned mesh");
}

// ---------------------------------------------------------------------------
// The app

fn void two_characters_are_read_from_one_level_and_stand_where_it_puts_them() @test
{
	String level = write_level(FOLDER);
	defer level.free(mem);
	String before = folder_listing(FOLDER);
	defer before.free(mem);
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_level(level), "the level opens: %s", app.notice());
	test::@check(app.take_level_actor("hero_rig"), "the hero is not read: %s", app.notice());
	test::@check(app.take_level_actor("guide_rig", row: "guide"), "the guide is not read: %s", app.notice());
	test::eq((int)app.character_count(), 2);

	sz hero_at = app.level_node_character("hero_rig");
	sz guide_at = app.level_node_character("guide_rig");
	test::@check(hero_at >= 0 && guide_at >= 0 && hero_at != guide_at, "two characters, one each");
	if (hero_at < 0 || guide_at < 0) return;
	(void)app.focus_character((usz)hero_at);
	test::@check(app.level_read && app.source_path.len == 0 && app.actor_row == "hero_rig" && app.label() == "hero_rig",
		"the hero is read from the level, no file of its own, row %s", app.actor_row);
	test::@check(app.doc.dots.len() == 3, "%d joints", app.doc.dots.len());
	// Its feet on the model's floor: where the level puts the node, the origin 1.35 m below it.
	test::@check(math::is_approx(app.stage_scale, 1.5f, 1e-3f) && math::is_approx(app.stage_lift, 1.35f, 1e-3f), "scale %f, lift %f", app.stage_scale, app.stage_lift);
	test::@check(helpers::near3(app.doc.model_transform.location, { 2, -0.35f, -1 }, 1e-3f), "it stands at %s", app.doc.model_transform.location);
	test::@check(helpers::turn_between(app.doc.model_transform.orientation(), YAW_90) < 1e-3f, "it faces the node's way");
	crig::Dot* hips = crig::dot_named(&app.doc, "hips");
	test::@check(hips && helpers::near3(hips.position, { 0, 0.9f, 0 }, 1e-3f), "the hips rest 0.9 over the feet");
	test::@check(has_clip(&app, "wave") && has_clip(&app, "both") && !has_clip(&app, "crouch"), "the hero's clips are the level's for it");
	test::@check(app.level_joints.len == 3 && app.level_joints[0] >= 0 && app.level_joints[2] >= 0, "every skin joint follows a rig joint");

	(void)app.focus_character((usz)guide_at);
	test::@check(app.actor_row == "guide" && has_clip(&app, "crouch") && has_clip(&app, "both") && !has_clip(&app, "wave"),
		"the guide is read with its own row and clips");
	test::@check(math::is_approx(app.stage_lift, 0.9f, 1e-3f) && app.stage_scale == 0.0f, "the guide's lift %f, scale %f", app.stage_lift, app.stage_scale);

	// The same node twice, and one the level lacks, are refused.
	test::@check(!app.take_level_actor("hero_rig", row: "again"), "the hero was read twice");
	test::@check(!app.take_level_actor("nobody") && app.notice().contains("no rigged character"), "a node the level lacks: %s", app.notice());
	test::eq((int)app.character_count(), 2);

	// The level's clip plays on it.
	AnimRef ref;
	test::@check(app.bound_clip_named("crouch", &ref) != null && app.play_clip(ref), "the guide's level clip does not play");

	// Nothing was written beside the level.
	String after = folder_listing(FOLDER);
	defer after.free(mem);
	test::@check(after == before, "files appeared beside the level:\n%s", after);
}

fn void an_actor_read_from_the_level_is_read_only_but_its_one_offs_are_edited() @test
{
	String folder = FOLDER.tconcat("/read-only");
	String level = write_level(folder);
	defer level.free(mem);
	String before = folder_listing(folder);
	defer before.free(mem);
	Fixture* f = mem::new(Fixture);
	defer free(f);
	f.app = crig::new_app({}, "");
	f.tools = crig::new_tool_table(&f.app);
	f.server = crig::serve_table(&f.tools, &f.app);
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.open_level(level), "the level opens");
	String? added = f.call_tool_text("add_actor", `{"level_node":"hero_rig"}`);
	if (catch added)
	{
		test::@check(false, "add_actor with a level node alone was refused");
		return;
	}
	test::@check(added.contains(`"read_from":"level"`), "get_cutscenes does not say where it is read from: %s", added);
	added.free(mem);
	String scene = f.call_tool_text("get_scene", "{}")!!;
	defer scene.free(mem);
	test::@check(scene.contains(`"read_from":"level","level_node":"hero_rig"`), "get_scene does not say where it is read from: %s", scene);

	// A rig edit lands and is taken back, with a notice naming why.
	crig::Dot* arm = crig::dot_named(&app.doc, "arm");
	uint id = arm.id;
	Vec3 was = arm.position;
	arm.position = was + (Vec3){ 0.2f, 0, 0 };
	test::@check(app.move_recorded(id, was, arm.position), "the move was not recorded");
	app.undo_stack.commit();
	test::@check(app.refuse_level_edits(), "the edit was kept");
	test::@check(helpers::near3(app.doc.find(id).position, was, 1e-3f) && app.undo_stack.edits.len() == 0, "the arm is not back, or the history kept it");
	test::@check(app.notice().contains("read-only"), "the notice does not say why: %s", app.notice());

	// A tool keying its level clip is refused, and the clip is as the level has it.
	AnimRef ref;
	AnimTemplate* wave = app.bound_clip_named("wave", &ref);
	usz keys = wave ? wave.keyframes.len : 0;
	String? keyed = f.call_tool_text("pose_joint", `{"joint":"arm","turn":{"axis":[0,0,1],"angle":0.4},"clip":"wave","time":0.5}`);
	test::@check(!@ok(keyed), "a key on the level's clip was kept");
	if (try keyed) keyed.free(mem);
	wave = app.bound_clip_named("wave", &ref);
	test::@check(wave && wave.keyframes.len == keys && app.undo_stack.edits.len() == 0, "the level's clip changed");

	// Saving it is refused, and nothing is written beside the level.
	app.save_session();
	test::@check(app.notice().contains("never saved"), "the save said: %s", app.notice());

	// A one-off is edited on it all the same.
	(void)app.add_cutscene();
	sz k = app.new_cut_one_off(0);
	test::@check(k >= 0 && app.edit_cut_one_off(0, (usz)k), "the one-off would not open: %s", app.notice());
	Object*? posed = f.call_tool("pose_joint", `{"joint":"arm","turn":{"axis":[0,0,1],"angle":0.5},"time":0.5}`);
	if (catch posed)
	{
		test::@check(false, "a one-off key was refused: %s", app.notice());
		return;
	}
	posed.free();
	test::@check(!app.refuse_level_edits(), "a one-off's own edit was taken back");
	test::@check(app.back_to_cutscene(), "back");
	test::@check(crig::clip_moves_anything(&app.cutscene().one_offs[0].clip), "the one-off keys nothing");

	String after = folder_listing(folder);
	defer after.free(mem);
	test::@check(after == before, "files appeared beside the level:\n%s", after);
}

fn void a_level_actors_one_off_is_exported_in_its_armatures_own_frames() @test
{
	String folder = FOLDER.tconcat("/one-off");
	String level = write_level(folder);
	defer level.free(mem);
	Fixture* f = mem::new(Fixture);
	defer free(f);
	f.app = crig::new_app({}, "");
	f.tools = crig::new_tool_table(&f.app);
	f.server = crig::serve_table(&f.tools, &f.app);
	defer f.close();
	crig::AppState* app = &f.app;
	test::@check(app.open_level(level) && app.take_level_actor("hero_rig"), "the hero is not read: %s", app.notice());
	(void)app.add_cutscene();
	sz k = app.new_cut_one_off(0);
	test::@check(k >= 0 && app.edit_cut_one_off(0, (usz)k), "the one-off would not open");
	Object*? posed = f.call_tool("pose_joint", `{"joint":"arm","turn":{"axis":[1,0,0],"angle":0.6},"time":1.0}`);
	if (catch posed)
	{
		test::@check(false, "the arm would not turn: %s", app.notice());
		return;
	}
	posed.free();
	test::@check(app.back_to_cutscene(), "back");

	// No rig-mismatch refusal, and nothing in the problems list about the rig.
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	foreach (text : problems) test::@check(!text.contains("rig"), "a problem: %s", text);
	String target = string::tformat("%s/one-off.cutscene.glb", folder);
	(void)file::delete(target);
	DString why = dstring::new(mem);
	defer why.free();
	test::@check(app.export_cutscene(target, &why), "not exported: %s", why.str_view());
	CutAnimation[] read;
	Cutscene back = crig::read_cutscene_file(mem, target, null, &read)!!;
	defer back.free(mem);
	defer crig::free_cut_animations(mem, read);
	test::@check(read.len == 1, "%d animations", read.len);
	if (read.len != 1) return;

	// The same clip baked on Rigsmith's own frames, every joint unturned at rest.
	RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	AnimTemplate clip = crig::clip_copy(mem, app.cutscene().one_offs[0].clip);
	defer clip.free(mem);
	clip.compile_tracks(mem);
	CutAnimation own = crig::bake_one_off(mem, &view.skeleton, view.names, &clip, 0, "own");
	defer own.free(mem);
	sz arm = -1;
	sz own_arm = -1;
	foreach (usz i, &c : read[0].channels) if (c.bone == "arm" && c.path == ROTATION) arm = (sz)i;
	foreach (usz i, &c : own.channels) if (c.bone == "arm" && c.path == ROTATION) own_arm = (sz)i;
	test::@check(arm >= 0 && own_arm >= 0, "the arm's turn is not written");
	if (arm < 0 || own_arm < 0) return;
	CutChannel* level_arm = &read[0].channels[arm];
	CutChannel* own_channel = &own.channels[own_arm];
	test::@check(level_arm.values.len == own_channel.values.len && level_arm.values.len >= 8, "the keys differ");
	if (level_arm.values.len != own_channel.values.len) return;
	// In the level's frames the spine rests turned with the hips, the arm rolled on it: under
	// those rests the written turn moves the arm exactly as Rigsmith's moves it.
	Quaternionf spine_rest = YAW_90;
	Quaternionf arm_rest = YAW_90.mul(ROLL_90).normalize();
	float worst;
	for (usz i = 0; i + 3 < level_arm.values.len; i += 4)
	{
		Quaternionf written = { .v = { level_arm.values[i], level_arm.values[i + 1], level_arm.values[i + 2], level_arm.values[i + 3] } };
		Quaternionf made = { .v = { own_channel.values[i], own_channel.values[i + 1], own_channel.values[i + 2], own_channel.values[i + 3] } };
		Quaternionf moved = spine_rest.mul(written).mul(arm_rest.invert()).normalize();
		worst = math::max(worst, helpers::turn_between(moved, made));
	}
	test::@check(worst < 1e-3f, "the written turn moves the arm %f rad off Rigsmith's", worst);
	// And they are the level's frames, not Rigsmith's unturned ones written as they were.
	Quaternionf first = { .v = { level_arm.values[0], level_arm.values[1], level_arm.values[2], level_arm.values[3] } };
	Quaternionf raw = { .v = { own_channel.values[0], own_channel.values[1], own_channel.values[2], own_channel.values[3] } };
	test::@check(helpers::turn_between(first, raw) > 0.5f, "the arm's keys are written in Rigsmith's frames");
}

fn void a_strip_playing_a_clip_the_level_lacks_for_the_armature_is_named() @test
{
	String level = write_level(FOLDER);
	defer level.free(mem);
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_level(level) && app.take_level_actor("hero_rig", row: "hero"), "the hero is not read: %s", app.notice());
	(void)app.add_cutscene();
	CutStrip plays = crig::cut_strip(PLAY, 0.0f, 1.0f);
	plays.clip = "wave".copy(mem);
	test::@check(app.add_cut_strip(0, plays) >= 0, "the wave was not added");
	CutStrip lacks = crig::cut_strip(PLAY, 2.0f, 3.0f);
	lacks.clip = "crouch".copy(mem);
	test::@check(app.add_cut_strip(0, lacks) >= 0, "the crouch was not added");
	String[] problems = app.cutscene_problem_texts(mem);
	defer crig::free_names(mem, problems);
	bool named;
	foreach (text : problems)
	{
		test::@check(!text.contains("'wave'"), "the level's own clip is a problem: %s", text);
		named = named || (text.contains("'crouch'") && text.contains("the level has no clip of for hero_rig"));
	}
	test::@check(named, "the clip the level lacks for the hero is not named");
}

fn void an_actor_read_from_the_level_walks_with_its_feet_on_the_path_and_exports_lifted() @test
{
	String folder = FOLDER.tconcat("/walk");
	String level = write_level(folder);
	defer level.free(mem);
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_level(level) && app.take_level_actor("hero_rig", row: "hero"), "the hero is not read: %s", app.notice());
	(void)app.add_cutscene();
	(void)app.add_cut_path("Road");
	test::@check(app.add_cut_knot(0, { 2, 0, -1 }) && app.add_cut_knot(0, { 2, 0, 3 }), "knots");
	test::@check(app.walk_cut_path(0, 0) >= 0, "the hero does not walk the road");
	CutStrip* s = &app.cutscene().actors[0].strips[0];
	test::@check(app.set_cutscene_preview(true), "no preview");
	app.show_cutscene_at((s.start + s.end) * 0.5f);
	// Its origin is where its feet stand: on the road.
	test::@check(app.staged && math::is_approx(app.staged_place.location.y, 0.0f, 1e-3f) && math::is_approx(app.staged_place.location.z, 1.0f, 0.05f),
		"it stands at %s mid-walk", app.staged_place.location);
	app.leave_cutscene_preview();

	String target = string::tformat("%s/walk.cutscene.glb", folder);
	(void)file::delete(target);
	test::@check(app.export_cutscene(target), "not exported: %s", app.notice());
	Cutscene back = crig::read_cutscene_file(mem, target)!!;
	defer back.free(mem);
	test::@check(back.paths.len == 1 && back.paths[0].points.len >= 2, "the road is not written");
	if (back.paths.len != 1) return;
	foreach (p : back.paths[0].points) test::@check(math::is_approx(p.y, 1.35f, 1e-3f), "a point is lifted to %f, not by the node's 1.35", p.y);
	test::@check(!back.actors[0].no_level_node, "an actor of the level is written a place");
}

fn void a_scene_finds_an_actor_read_from_the_level_again_by_its_node() @test
{
	String folder = FOLDER.tconcat("/scene");
	String level = write_level(folder);
	defer level.free(mem);
	String saved = string::tformat("%s/forest.rigsmith-scene.json", folder);
	{
		crig::AppState app = crig::new_app({}, "");
		defer app.free();
		test::@check(app.open_level(level), "the level opens");
		test::@check(app.take_level_actor("hero_rig", row: "hero") && app.take_level_actor("guide_rig", row: "guide"), "not read: %s", app.notice());
		(void)app.add_cutscene();
		CutStrip plays = crig::cut_strip(PLAY, 0.0f, 1.0f);
		plays.clip = "wave".copy(mem);
		test::@check(app.add_cut_strip(0, plays) >= 0, "the wave was not added");
		test::@check(app.save_scene(saved), "the scene was not saved: %s", app.notice());
	}
	String text = (String)file::load(mem, saved)!!;
	defer text.free(mem);
	test::@check(!text.contains(`"model"`), "a character read from the level was written a model: %s", text);
	test::@check(text.contains(`"level_node":"hero_rig"`) && text.contains(`"level_node":"guide_rig"`), "the nodes are not kept: %s", text);

	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_scene(saved), "the scene does not open: %s", app.notice());
	test::eq((int)app.character_count(), 2);
	// Read again as the level comes in.
	app.level_came_in();
	sz hero = app.actor_character("hero");
	sz guide = app.actor_character("guide");
	test::@check(hero >= 0 && guide >= 0, "the actors are not found by their rows");
	if (hero < 0 || guide < 0) return;
	crig::Character* h = app.character((usz)hero);
	test::@check(h.level_read && h.level_node == "hero_rig" && h.doc.dots.len() == 3 && !h.stage_missing, "the hero is not read again");
	test::@check(helpers::near3(h.doc.model_transform.location, { 2, -0.35f, -1 }, 1e-3f) && math::is_approx(h.stage_lift, 1.35f, 1e-3f), "it does not stand where the level puts it");
	String[] problems = app.cutscene_problem_texts(mem);
	foreach (p : problems) test::@check(!p.contains("'wave'"), "a problem: %s", p);
	crig::free_names(mem, problems);

	// A node gone from the level is a problem line, and the actor keeps what it had.
	String renamed = text.replace(mem, `"level_node":"guide_rig"`, `"level_node":"gone_rig"`);
	defer renamed.free(mem);
	String gone = string::tformat("%s/gone.rigsmith-scene.json", folder);
	file::save(gone, (char[])renamed)!!;
	crig::AppState other = crig::new_app({}, "");
	defer other.free();
	test::@check(other.open_scene(gone), "the scene does not open: %s", other.notice());
	other.level_came_in();
	String[] said = other.cutscene_problem_texts(mem);
	defer crig::free_names(mem, said);
	bool named;
	foreach (p : said) named = named || (p.contains("guide") && p.contains("no longer in the level"));
	test::@check(named, "the gone node is not named");
}

<*
 Several characters loaded at once: the cast, the focus, and the shared clock.

 The humanoid and the quadruped are opened the way the editor opens them —
 through `load_mesh` and `add_character`, from the disposable fixture library —
 so each brings its own rig from its own file. What is asserted is that each
 keeps its own rig, history and clips across a switch, and that a character
 left at an instant stays there while another is edited.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::cast`
*>
module crig_tests::cast;

import crig;
import rig;
import gltf;
import crig_tests::library;
import std::io;
import std::core::test;
import std::math;
import std::encoding::json;
import std::collections::object;
import std::io::path;
import std::io::file;
import std::math::quaternion;

struct Scene
{
	crig::AppState app;
	String person;
	String animal;
}

fn void Scene.open(&self)
{
	String folder = library::ready();
	self.person = string::format(mem, "%s/humanoid.glb", folder);
	self.animal = string::format(mem, "%s/quadruped.glb", folder);
	self.app = crig::new_app({}, "");
	self.app.load_mesh(rig::load_gltf(mem, self.person)!!, self.person);
	self.app.add_character(rig::load_gltf(mem, self.animal)!!, self.animal);
}

fn void Scene.close(&self)
{
	self.app.free();
	alloc::free(mem, self.person.ptr);
	alloc::free(mem, self.animal.ptr);
}

fn usz dots_of(crig::Character* c) => (usz)c.doc.dots.len();

<*
 The fields read as the app's are the focus's, and an `AppState*` is a
 `Character*` — the two facts every line of `self.doc` relies on.
*>
fn void the_focus_is_the_app_s_own_fields() @test
{
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	app.doc.sym_x = 3.0f;
	crig::Character* c = &app;
	test::eq(c.doc.sym_x, 3.0f);
	test::eq(app.focus.doc.sym_x, 3.0f);
	test::eq((int)app.character_count(), 1);
	test::@check(app.character(0) == c, "with one character the focus is character 0");
}

fn void every_character_is_born_with_its_own_counters() @test
{
	crig::Character a = crig::new_character({}, "", {}, {}, {}, false);
	crig::Character b = crig::new_character({}, "", {}, {}, {}, false);
	defer { a.also_selected.free(); a.outliner_collapsed_joints.free(); a.drag_mates.free(); a.occlusion_memo.free(); }
	defer { b.also_selected.free(); b.outliner_collapsed_joints.free(); b.drag_mates.free(); b.occlusion_memo.free(); }
	test::@check(a.id != 0 && b.id != 0 && a.id != b.id, "ids %d and %d must be distinct and set", a.id, b.id);
	test::@check(crig::next_generation() != crig::next_generation(), "the counter must not repeat");
}

fn void switching_focus_keeps_each_rig() @test
{
	io::printn("two characters, each with its own rig, swapped back and forth");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	test::eq((int)app.character_count(), 2);
	test::eq((int)app.active, 1);
	test::eq(app.source_path, scene.animal);
	usz animal = dots_of(app);
	usz person = dots_of(app.character(0));
	test::@check(animal > 0 && person > 0, "both files carry a rig (%d, %d)", (int)person, (int)animal);
	test::@check(animal != person, "the two rigs differ, so a mix-up would show");

	test::@check(app.focus_character(0), "the person takes the focus");
	test::eq(app.source_path, scene.person);
	test::eq(dots_of(app), person);
	test::eq(dots_of(app.character(1)), animal);

	test::@check(app.focus_character(1), "and gives it back");
	test::eq(dots_of(app), animal);
	test::eq(app.character_from(scene.person), 0);
	test::eq(app.character_from(scene.animal), 1);
}

fn void a_new_character_stands_beside_the_others() @test
{
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	rig::Bounds animal = app.world_bounds();
	rig::Bounds person = app.character(0).world_bounds();
	test::@check(animal.min.x > person.max.x,
		"the newcomer starts at x %f, inside the first character's %f", animal.min.x, person.max.x);
}

fn void each_character_keeps_its_own_history() @test
{
	io::printn("an undo on one character leaves the other's edit alone");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	usz animal = dots_of(app);
	test::@check(app.place({ 0.0f, 0.1f, 0.0f }) != 0, "a dot goes on the animal");
	app.focus_character(0);
	usz person = dots_of(app);
	test::@check(app.place({ 0.0f, 1.0f, 0.0f }) != 0, "and one on the person");
	test::eq(dots_of(app), person + 1);

	test::@check(app.undo(), "the person's dot can be undone");
	test::eq(dots_of(app), person);
	test::eq(dots_of(app.character(1)), animal + 1);

	app.focus_character(1);
	test::@check(app.undo(), "and the animal's, on its own history");
	test::eq(dots_of(app), animal);
	test::eq(dots_of(app.character(0)), person);
}

fn bool authored_has(crig::AppState* app, String name)
{
	crig::AnimPack* pack = app.authored();
	if (!pack) return false;
	foreach (clip : pack.clips) if (clip.name == name) return true;
	return false;
}

fn void each_character_keeps_its_own_clips() @test
{
	io::printn("a clip authored on one character is not the other's");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	crig::AnimRef trot = app.new_clip("Trot", 1.0f, from_rest: true);
	test::@check(trot.valid(), "the animal gets a clip");
	app.focus_character(0);
	test::@check(!authored_has(app, "Trot"), "the person does not see the animal's clip");
	crig::AnimRef wave = app.new_clip("Wave", 1.0f, from_rest: true);
	test::@check(wave.valid(), "the person gets one of its own");

	app.focus_character(1);
	test::@check(authored_has(app, "Trot") && !authored_has(app, "Wave"), "the animal has only its own");
	crig::AnimTemplate* open = app.clip(app.editing);
	test::@check(open != null && open.name == "Trot", "and its timeline still opens its own clip");
	test::@check(app.unsaved(), "the animal's new clip is unsaved work");
	test::@check(app.any_character_unsaved(), "which the whole scene knows about");
}

fn void a_character_left_at_a_frame_stays_there() @test
{
	io::printn("scrub one character, edit the other: the first holds the frame");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	app.focus_character(0);
	crig::AnimRef wave = app.new_clip("Wave", 1.0f, from_rest: true);
	test::@check(wave.valid(), "the person has a clip to pose on");

	app.focus_character(1);
	crig::AnimRef trot = app.new_clip("Trot", 2.0f, from_rest: true);
	test::@check(app.park_clip(trot, 0.5f), "the animal parks at half a second");

	// The person takes the focus, and its timeline lands on the animal's instant.
	app.focus_character(0);
	test::eq(app.edit_time, 0.5f);

	app.sync_cast(0.0f);
	crig::Character* animal = app.character(1);
	test::@check(animal.animating && animal.anim_paused, "the animal is still parked");
	test::eq(animal.anim_time, 0.5f);
	test::@check(animal.posed_dots.len > 0, "and its pose is on screen");
}

fn void the_shared_clock_drives_every_character() @test
{
	io::printn("one character plays; the other follows at its own clip's time");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	crig::AnimRef trot = app.new_clip("Trot", 0.4f, from_rest: true);
	test::@check(trot.valid(), "the animal has a short looping clip");
	app.focus_character(0);
	crig::AnimRef wave = app.new_clip("Wave", 1.0f, from_rest: true);
	test::@check(app.start_animation_ref(wave), "the person plays");
	app.anim_paused = false;
	app.tick_animation(0.25f);
	app.sync_cast(0.25f);
	crig::Character* animal = app.character(1);
	test::@check(animal.animating && !animal.anim_paused, "the animal runs with it");
	test::eq(animal.anim_time, 0.25f);

	app.tick_animation(0.25f);
	app.sync_cast(0.25f);
	// 0.5 s into a 0.4 s loop.
	test::@check(math::abs(animal.anim_time - 0.1f) < 1e-4f, "the animal wraps its own loop, at %f", animal.anim_time);
}

fn void a_library_reread_keeps_a_waiting_character_s_clip() @test
{
	io::printn("the packs are re-read while a waiting character plays one of them");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	String folder = library::ready();
	app.load_packs(folder);
	int pack = app.loaded_pack_for(scene.animal);
	test::@check(pack >= 0, "the quadruped is a pack in the library");
	crig::AnimPack* held = &app.packs[(usz)pack];
	test::@check(held.clips.len > 0, "with clips");
	String name = held.clips[0].name.copy(mem);
	defer name.free(mem);
	test::@check(app.start_animation_ref({ pack, 0 }), "the animal plays one");

	app.focus_character(0);
	app.load_packs(folder);
	crig::Character* animal = app.character(1);
	app.focus_character(1);
	test::@check(app.animating, "the animal is still playing after the re-read");
	crig::AnimTemplate* playing = app.clip(app.current_ref);
	test::@check(playing != null && playing.name == name, "the same clip, found again by name");
	(void)animal;
}

fn void removing_a_character_frees_it() @test
{
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	(void)app.new_clip("Trot", 1.0f, from_rest: true);
	app.focus_character(0);
	usz person = dots_of(app);
	test::@check(app.remove_character(1), "the animal goes");
	test::eq((int)app.character_count(), 1);
	test::eq(app.source_path, scene.person);
	test::eq(dots_of(app), person);
	test::@check(!authored_has(app, "Trot"), "and takes its clip with it");
	test::@check(!app.remove_character(0), "the last character stays");
}

fn void removing_the_focus_moves_it_to_a_neighbour() @test
{
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	test::@check(app.remove_character(1), "the focus itself can go");
	test::eq((int)app.character_count(), 1);
	test::eq(app.source_path, scene.person);
}

const String MODEL_SHELF = "build/test-models";

fn crig::AssetLibrary[] shelf() @local
{
	static crig::AssetLibrary[1] held;
	held[0] = { .name = "Models", .path = MODEL_SHELF };
	return held[..];
}

fn usz kind_count(crig::AssetIndex index, crig::AssetKind kind) @local
{
	usz n;
	foreach (entry : index.entries) if (entry.kind == kind) n++;
	return n;
}

<*
 The browser's Models shelf: a rigged character exported by crig is a model to
 add, and a library pack's stand-in body is not.
*>
fn void a_rigged_model_is_on_the_models_shelf() @test
{
	io::printn("an exported character is a model; a pack's stand-in body is not");
	if (catch path::mkdir((Path)MODEL_SHELF)) {}
	String out = MODEL_SHELF +++ "/person.glb";

	{
		Scene scene;
		scene.open();
		defer scene.close();
		scene.app.focus_character(0);
		scene.app.export_rig(out);
	}

	crig::AssetIndex models = crig::scan_assets(mem, shelf());
	defer crig::free_assets(mem, models);
	test::eq((int)kind_count(models, MODEL), 1);
	foreach (entry : models.entries)
	{
		if (entry.kind != MODEL) continue;
		test::eq(entry.file, out);
		test::@check(entry.joints > 0 && entry.vertices > 0, "a rigged body with %d joints, %d verts", entry.joints, entry.vertices);
	}

	crig::AssetLibrary[1] packs = { { .name = "Packs", .path = library::ready() } };
	crig::AssetIndex library_index = crig::scan_assets(mem, packs[..]);
	defer crig::free_assets(mem, library_index);
	test::eq((int)kind_count(library_index, MODEL), 0);
}

fn void adding_a_model_twice_focuses_it_instead() @test
{
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	app.request_add_character(scene.person);
	app.service_pending_add();
	test::eq((int)app.character_count(), 2);
	test::eq((int)app.active, 0);
	test::eq(app.source_path, scene.person);
}

fn void adding_with_nothing_open_opens_it() @test
{
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	String person = string::format(mem, "%s/humanoid.glb", library::ready());
	defer person.free(mem);
	app.request_add_character(person);
	app.service_pending_add();
	test::eq((int)app.character_count(), 1);
	test::eq(app.source_path, person);
	test::@check(app.doc.dots.len() > 0, "the rig came with it");
}

// File › New scene: nobody on stage, no scene file, and an import after it is
// the first character again rather than one beside a ghost.
fn void a_new_scene_is_empty() @test
{
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;

	app.set_scene_path("build/somewhere.rigsmith-scene.json");
	(void)app.new_clip("Trot", 1.0f, from_rest: true);
	test::@check(app.new_scene(), "a new scene is made");
	test::eq((int)app.character_count(), 1);
	test::@check(!app.has_mesh(), "with no model in it");
	test::eq(app.source_path, "");
	test::eq(app.scene_path, "");
	test::@check(!authored_has(app, "Trot"), "and no clip left over");
	test::@check(!app.any_character_unsaved(), "and nothing to save");

	app.request_add_character(scene.animal);
	app.service_pending_add();
	test::eq((int)app.character_count(), 1);
	test::eq(app.source_path, scene.animal);
}

// ---------------------------------------------------------------------------
// Scenes on disk
// ---------------------------------------------------------------------------

const String SCENE_FOLDER = "build/test-scene";

fn void scene_text_reads_back_what_it_wrote() @test
{
	crig::SceneCharacter[2] cast = {
		{ .model = "build/test-scene/knight.glb", .transform = { .location = { 1.5f, 0.0f, -2.0f }, .rotation = quaternion::IDENTITY },
		  .clip_name = "Duel" },
		{ .model = "/elsewhere/horse.glb", .transform = { .rotation = quaternion::IDENTITY },
		  .clip_file = "/lib/quadruped.glb", .clip_name = "Trot", .hidden = true },
	};
	crig::SceneFile scene = { .characters = cast[..], .active = 1, .time = 1.25f };
	String text = crig::scene_file_text(mem, &scene, "build/test-scene/duel.rigsmith-scene.json");
	defer text.free(mem);
	test::@check(text.contains(`"model":"knight.glb"`), "a model beside the scene is written relative: %s", text);
	test::@check(text.contains(`"model":"/elsewhere/horse.glb"`), "one elsewhere stays absolute: %s", text);

	crig::SceneFile back = crig::parse_scene_file(mem, text, "build/test-scene/duel.rigsmith-scene.json")!!;
	defer back.free(mem);
	test::eq((int)back.characters.len, 2);
	test::eq((int)back.active, 1);
	test::eq(back.time, 1.25f);
	test::eq(back.characters[0].model, "build/test-scene/knight.glb");
	test::eq(back.characters[0].transform.location.x, 1.5f);
	test::eq(back.characters[0].clip_name, "Duel");
	test::eq(back.characters[0].clip_file, "");
	test::eq(back.characters[1].model, "/elsewhere/horse.glb");
	test::eq(back.characters[1].clip_file, "/lib/quadruped.glb");
	test::@check(back.characters[1].hidden && !back.characters[0].hidden, "hidden survives");
}

fn void a_scene_from_a_newer_version_is_refused() @test
{
	String text = `{"format":"rigsmith-scene","version":99,"characters":[{"model":"a.glb"}]}`;
	test::@check(@catch(crig::parse_scene_file(mem, text, "x.json")) == crig::SCENE_SHAPE, "version 99 must not read");
	String empty = `{"format":"rigsmith-scene","version":1,"characters":[]}`;
	test::@check(@catch(crig::parse_scene_file(mem, empty, "x.json")) == crig::SCENE_SHAPE, "a scene of nobody must not read");
	String other = `{"format":"something-else","version":1,"characters":[{"model":"a.glb"}]}`;
	test::@check(@catch(crig::parse_scene_file(mem, other, "x.json")) == crig::SCENE_SHAPE, "another format must not read");
}

fn String copy_into(String folder, String source, String name) @local
{
	String target = string::format(mem, "%s/%s", folder, name);
	char[] bytes = file::load(mem, source)!!;
	defer alloc::free(mem, bytes);
	file::save(target, bytes)!!;
	return target;
}

fn void a_saved_scene_opens_as_it_was_left() @test
{
	io::printn("save two characters as a scene, open it in a fresh app");
	if (catch path::mkdir((Path)SCENE_FOLDER)) {}
	String person = copy_into(SCENE_FOLDER, string::tformat("%s/humanoid.glb", library::ready()), "person.glb");
	String animal = copy_into(SCENE_FOLDER, string::tformat("%s/quadruped.glb", library::ready()), "animal.glb");
	defer { person.free(mem); animal.free(mem); }
	// A sidecar or copy left by an earlier run would be opened instead of the file.
	(void)file::delete(SCENE_FOLDER +++ "/person.rigsmith.json");
	(void)file::delete(SCENE_FOLDER +++ "/animal.rigsmith.json");
	(void)file::delete(SCENE_FOLDER +++ "/person_copy.glb");
	(void)file::delete(SCENE_FOLDER +++ "/animal_copy.glb");
	(void)file::delete(SCENE_FOLDER +++ "/person_copy.rigsmith.json");
	(void)file::delete(SCENE_FOLDER +++ "/animal_copy.rigsmith.json");

	String saved = SCENE_FOLDER +++ "/duel.rigsmith-scene.json";
	float placed;
	{
		crig::AppState app = crig::new_app({}, "");
		defer app.free();
		app.load_mesh(rig::load_gltf(mem, person)!!, person);
		app.add_character(rig::load_gltf(mem, animal)!!, animal);
		placed = app.doc.model_transform.location.x;
		test::@check(placed > 0.0f, "the animal was set beside the person");
		crig::AnimRef trot = app.new_clip("Trot", 2.0f, from_rest: true);
		test::@check(app.park_clip(trot, 0.75f), "the animal parks in its clip");
		test::@check(app.save_scene(SCENE_FOLDER +++ "/duel"), "the scene saves: %s", app.notice());
		test::@check(file::is_file(saved), "with the suffix added");
		test::@check(!app.any_character_unsaved(), "and every character is saved with it");
	}

	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_scene(saved), "the scene opens: %s", app.notice());
	test::eq((int)app.character_count(), 2);
	test::eq((int)app.active, 1);
	test::@check(app.source_path.ends_with("animal_copy.glb"), "the animal comes from where its save put it: %s", app.source_path);
	test::eq(app.doc.model_transform.location.x, placed);
	crig::AnimTemplate* open = app.clip(app.editing);
	test::@check(open != null && open.name == "Trot", "its clip is open again");
	test::eq(app.edit_time, 0.75f);
	test::@check(app.character(0).source_path.ends_with("person.glb") || app.character(0).source_path.ends_with("person_copy.glb"),
		"the person is the other one");
}

fn void a_scene_naming_a_missing_model_leaves_what_was_open() @test
{
	if (catch path::mkdir((Path)SCENE_FOLDER)) {}
	String broken = SCENE_FOLDER +++ "/broken.rigsmith-scene.json";
	file::save(broken, `{"format":"rigsmith-scene","version":1,"characters":[{"model":"nobody-here.glb"}]}`)!!;

	Scene scene;
	scene.open();
	defer scene.close();
	test::@check(!scene.app.open_scene(broken), "a missing model refuses the scene");
	test::eq((int)scene.app.character_count(), 2);
	test::eq(scene.app.source_path, scene.animal);
}

<*
 The cutscene as one file: both characters' meshes and skins, and one animation
 holding both of their channels on the scene's clock.
*>
fn void a_scene_exports_as_one_animated_file() @test
{
	io::printn("two characters, each playing a library clip, into one .glb");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;
	app.load_packs(library::ready());

	// Each plays a clip out of its own file, opened on its timeline.
	int animal_pack = app.loaded_pack_for(scene.animal);
	test::@check(animal_pack >= 0 && app.packs[(usz)animal_pack].clips.len > 0, "the quadruped has clips");
	app.editing = { animal_pack, 0 };
	app.focus_character(0);
	int person_pack = app.loaded_pack_for(scene.person);
	test::@check(person_pack >= 0 && app.packs[(usz)person_pack].clips.len > 0, "the humanoid has clips");
	app.editing = { person_pack, 0 };
	float longest = math::max(app.packs[(usz)animal_pack].clips[0].duration, app.packs[(usz)person_pack].clips[0].duration);

	String out = "build/test-scene-export.glb";
	test::@check(app.export_scene(out), "the scene exports: %s", app.notice());

	gltf::GltfStream stream = gltf::open(out, mem)!!;
	defer stream.close();
	test::eq((int)stream.gltf.skins.len(), 2);
	test::eq((int)stream.gltf.animations.len(), 1);

	// Every node named once: two `hips` would be one joint to a reader.
	foreach (usz i, a : stream.gltf.nodes)
	{
		for (usz j = 0; j < i; j++)
		{
			if (a.name.len > 0 && stream.gltf.nodes[(sz)j].name == a.name)
			{
				test::@check(false, "node %s is named twice", a.name);
				return;
			}
		}
	}

	// The one animation moves joints of both skins.
	gltf::Animation clip = stream.gltf.animations[0];
	bool[2] moved;
	foreach (channel : clip.channels)
	{
		foreach (usz s, skin : stream.gltf.skins)
		{
			foreach (joint : skin.joints) if (joint == channel.target.node) moved[s] = true;
		}
	}
	test::@check(moved[0] && moved[1], "the animation moves both characters (%s, %s)", moved[0], moved[1]);
	test::@check(math::abs(clip.max_time - longest) < 1e-3f, "it runs the longest clip's length: %f against %f", clip.max_time, longest);
}

// ---------------------------------------------------------------------------
// The cast over MCP
// ---------------------------------------------------------------------------

fn String? call(crig::ToolTable* tools, String name, String arguments, DString* detail) @local
{
	detail.clear();
	return tools.invoke(name, arguments, detail);
}

fn void get_scene_lists_every_character() @test
{
	Scene scene;
	scene.open();
	defer scene.close();
	crig::ToolTable tools = crig::new_tool_table(&scene.app);
	DString detail = dstring::new(mem);
	defer detail.free();

	String reply = call(&tools, "get_scene", "{}", &detail)!!;
	defer reply.free(mem);
	test::@check(reply.contains(`"characters":[`) && reply.contains(`"name":"humanoid"`) && reply.contains(`"name":"quadruped"`),
		"both characters are listed: %s", reply);
	test::@check(reply.contains(`"index":1,"name":"quadruped"`), "in cast order");
}

fn void a_call_naming_a_character_is_about_that_character() @test
{
	io::printn("get_skeleton {character: humanoid} answers the person's joints and focuses it");
	Scene scene;
	scene.open();
	defer scene.close();
	crig::AppState* app = &scene.app;
	crig::ToolTable tools = crig::new_tool_table(app);
	DString detail = dstring::new(mem);
	defer detail.free();

	usz person = dots_of(app.character(0));
	String reply = call(&tools, "get_scene", `{"character":"humanoid"}`, &detail)!!;
	reply.free(mem);
	test::eq((int)app.active, 0);
	test::eq(dots_of(app), person);

	String by_index = call(&tools, "get_scene", `{"character":1}`, &detail)!!;
	by_index.free(mem);
	test::eq((int)app.active, 1);

	test::@check(@catch(call(&tools, "get_scene", `{"character":"dragon"}`, &detail)) == crig::TOOL_REFUSED,
		"an unknown character is refused");
	test::@check(detail.str_view().contains("humanoid") && detail.str_view().contains("quadruped"),
		"and the refusal names who is loaded: %s", detail.str_view());
	test::eq((int)app.active, 1);

	// The wrapper the server is given routes the same way.
	crig::ToolDef* skeleton = tools.find("get_skeleton");
	Object* args = json::parse(mem, `{"character":0}`)!!;
	defer args.free();
	String wired = crig::routed_tool(args, skeleton, &detail)!!;
	wired.free(mem);
	test::eq((int)app.active, 0);
}

fn void add_character_over_mcp() @test
{
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	crig::ToolTable tools = crig::new_tool_table(&app);
	DString detail = dstring::new(mem);
	defer detail.free();
	String folder = library::ready();
	String person = string::tformat(`{"path":"%s/humanoid.glb"}`, folder);
	String animal = string::tformat(`{"path":"%s/quadruped.glb"}`, folder);

	String first = call(&tools, "add_character", person, &detail)!!;
	first.free(mem);
	String second = call(&tools, "add_character", animal, &detail)!!;
	defer second.free(mem);
	test::eq((int)app.character_count(), 2);
	test::@check(second.contains(`"name":"quadruped","model"`), "the answer is the cast: %s", second);

	String gone = call(&tools, "remove_character", `{"character":"quadruped"}`, &detail)!!;
	gone.free(mem);
	test::eq((int)app.character_count(), 1);
	test::@check(@catch(call(&tools, "remove_character", `{"character":0}`, &detail)) == crig::TOOL_REFUSED,
		"the last one stays");
}

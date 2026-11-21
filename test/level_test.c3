<*
 The level behind a scene: its colliders as the ground, and the scene file that
 remembers it. The collider scene is built here, with no device and no file.

     `c3c test --test-filter crig_tests::level`
*>
module crig_tests::level;

import crig;
import three;
import collision;
import crig_tests::library;
import crig_tests::mcp;
import crig_tests::helpers;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::math::quaternion;

// A box with its faces wound outward, as one mesh with a picking tree.
fn three::GpuMesh box_mesh(Vec3 low, Vec3 high)
{
	Vec3[8] corners;
	for (int i = 0; i < 8; i++)
	{
		corners[i] = { i & 1 ? high.x : low.x, i & 2 ? high.y : low.y, i & 4 ? high.z : low.z };
	}
	int[4][6] faces = { { 0, 2, 6, 4 }, { 1, 5, 7, 3 }, { 0, 4, 5, 1 }, { 2, 3, 7, 6 }, { 0, 1, 3, 2 }, { 4, 6, 7, 5 } };
	uint[36] indices;
	Vec3 middle = (low + high) * 0.5f;
	foreach (f, face : faces)
	{
		Vec3 a = corners[face[0]];
		Vec3 n = (corners[face[1]] - a).cross(corners[face[2]] - a);
		Vec3 centre = (a + corners[face[2]]) * 0.5f;
		bool outward = n.dot(centre - middle) > 0.0f;
		uint[6] quad = outward ? (uint[6]){ 0, 1, 2, 0, 2, 3 } : (uint[6]){ 0, 2, 1, 0, 3, 2 };
		foreach (k, corner : quad) indices[f * 6 + k] = (uint)face[corner];
	}
	three::GpuMesh mesh = { .texture = -1, .base_color = { 1, 1, 1, 1 }, .gltf_mesh = -1, .gltf_primitive = -1,
		.uploaded = true, .bounds = { low, high } };
	mesh.build_bvh(corners[..], indices[..]);
	return mesh;
}

struct Pieces
{
	three::Assets assets;
	three::Scene* scene;
	three::AssetId shapes;
	three::NodeId level;
}

// Ground, a stone, a branch overhead, a fern and a proxy shape in the level, and
// one of Rigsmith's own draws beside it.
fn void Pieces.open(&self)
{
	self.assets.init();
	three::Asset file = { .path = "test-level".copy(mem) };
	file.meshes.init(mem, 8);
	file.meshes.push(box_mesh({ -5, -0.1f, -5 }, { 5, 0, 5 }));        // 0 ground
	file.meshes.push(box_mesh({ 1.5f, 0, -0.5f }, { 2.5f, 0.3f, 0.5f })); // 1 stone
	file.meshes.push(box_mesh({ -1, 1.5f, -1 }, { 1, 1.7f, 1 }));      // 2 branch
	file.meshes.push(box_mesh({ -2.3f, 0, -0.3f }, { -1.7f, 0.4f, 0.3f })); // 3 fern
	file.meshes.push(box_mesh({ -4, 0, -4 }, { -3, 0.4f, -3 }));       // 4 crate's proxy
	file.meshes.push(box_mesh({ 2.8f, 0, 2.8f }, { 3.2f, 1.8f, 3.2f })); // 5 a character
	self.shapes = self.assets.claim_slot(file);

	self.scene = mem::new(three::Scene);
	self.scene.init();
	self.scene.attach_assets(&self.assets);
	self.level = self.scene.add_group(self.scene.root, "level");
	(void)self.scene.add_mesh(self.shapes, 0, self.level, "ground");
	(void)self.scene.add_mesh(self.shapes, 1, self.level, "stone");
	(void)self.scene.add_mesh(self.shapes, 2, self.level, "branch");
	three::NodeId fern = self.scene.add_mesh(self.shapes, 3, self.level, "fern");
	self.scene.set_collides(fern, false);
	three::NodeId crate = self.scene.add_mesh(self.shapes, 4, self.level, "crate.collider");
	self.scene.set_collision_only(crate, true);
	(void)self.scene.add_mesh(self.shapes, 5, self.scene.root, "crig:model");
}

fn void Pieces.close(&self)
{
	self.scene.free();
	mem::free(self.scene);
	self.assets.free(null);
}

fn crig::GroundHit Pieces.below(&self, Vec3 at) => crig::ground_below_in(self.scene, &self.assets, self.level, at);

<*
 A point's ground is the first collider under it, starting half a metre up: a
 stone within that reach is ground, a branch above it is not.
*>
fn void the_ground_is_the_first_collider_below() @test
{
	Pieces p;
	p.open();
	defer p.close();

	crig::GroundHit open = p.below({ 0, 0, 0 });
	test::@check(open.hit && helpers::near3(open.point, { 0, 0, 0 }, 1e-4f), "under the branch the ground is the ground: %s", open.point);
	test::@check(helpers::near3(open.normal, { 0, 1, 0 }, 1e-4f), "and faces up: %s", open.normal);
	test::eq(crig::level_name_in(p.scene, open.node), "ground");

	crig::GroundHit stone = p.below({ 2, 0, 0 });
	test::@check(stone.hit && helpers::near3(stone.point, { 2, 0.3f, 0 }, 1e-4f), "a stone within reach is stood on: %s", stone.point);

	crig::GroundHit sunk = p.below({ 0, -0.7f, 0 });
	test::@check(!sunk.hit, "nothing is below the ground's floor");

	crig::GroundHit off = p.below({ 8, 0, 8 });
	test::@check(!off.hit, "and off the level there is no ground");
}

<* What does not collide is never ground: a fern, and Rigsmith's own draws. A proxy shape is. *>
fn void only_colliders_are_ground() @test
{
	Pieces p;
	p.open();
	defer p.close();

	crig::GroundHit fern = p.below({ -2, 0.2f, 0 });
	test::@check(fern.hit && helpers::near3(fern.point, { -2, 0, 0 }, 1e-4f), "the fern is walked through: %s", fern.point);

	crig::GroundHit beside = p.below({ 3, 1.5f, 3 });
	test::@check(beside.hit && helpers::near3(beside.point, { 3, 0, 3 }, 1e-4f), "a character is not ground: %s", beside.point);

	crig::GroundHit crate = p.below({ -3.5f, 0.2f, -3.5f });
	test::@check(crate.hit && helpers::near3(crate.point, { -3.5f, 0.4f, -3.5f }, 1e-4f), "a collider's proxy shape is: %s", crate.point);
}

<* A view ray lands on the first collider it meets and is dropped onto the ground there. *>
fn void a_view_ray_lands_on_the_ground() @test
{
	Pieces p;
	p.open();
	defer p.close();

	Vec3 eye = { 0, 5, 5 };
	collision::Ray ray = { .origin = eye, .direction = ((Vec3){ 0, 0, 0 } - eye).normalize() };
	crig::GroundHit hit = crig::ground_along_in(p.scene, &p.assets, p.level, ray);
	test::@check(hit.hit && helpers::near3(hit.point, { 0, 0, 0 }, 1e-4f), "the ray lands where it points: %s", hit.point);

	// A ray that starts inside a collider passes out of it, as a camera inside a trunk's hull does.
	collision::Ray inside = { .origin = { -3.5f, 0.2f, -3.5f }, .direction = { 0, -1, 0 } };
	crig::GroundHit through = crig::first_collider_hit(p.scene, &p.assets, p.level, inside);
	test::@check(through.hit && helpers::near3(through.point, { -3.5f, 0, -3.5f }, 1e-4f), "the ray leaves the crate: %s", through.point);
	test::eq(crig::level_name_in(p.scene, through.node), "ground");

	collision::Ray up = { .origin = { 0, 0.5f, 0 }, .direction = { 0, 1, 0 } };
	crig::GroundHit branch = crig::first_collider_hit(p.scene, &p.assets, p.level, up);
	test::@check(branch.hit && helpers::near3(branch.normal, { 0, -1, 0 }, 1e-4f), "a normal faces the ray: %s", branch.normal);
}

// ---------------------------------------------------------------------------
// The scene file
// ---------------------------------------------------------------------------

const String LEVEL_FOLDER = "build/test-level-scene";

fn void a_scene_writes_its_level_beside_it() @test
{
	crig::SceneCharacter[1] cast = { { .model = "build/test-level-scene/knight.glb", .transform = { .rotation = quaternion::IDENTITY } } };
	String scene_path = LEVEL_FOLDER +++ "/duel.rigsmith-scene.json";

	crig::SceneFile inside = { .characters = cast[..], .level = "build/test-level-scene/levels/forest.glb" };
	String text = crig::scene_file_text(mem, &inside, scene_path);
	defer text.free(mem);
	test::@check(text.contains(`"level": "levels/forest.glb"`), "a level beside the scene is written relative: %s", text);
	crig::SceneFile back = crig::parse_scene_file(mem, text, scene_path)!!;
	defer back.free(mem);
	test::eq(back.level, "build/test-level-scene/levels/forest.glb");

	crig::SceneFile away = { .characters = cast[..], .level = "/somewhere/else/forest.glb" };
	String far = crig::scene_file_text(mem, &away, scene_path);
	defer far.free(mem);
	test::@check(far.contains(`"level": "/somewhere/else/forest.glb"`), "one elsewhere stays absolute: %s", far);

	crig::SceneFile none = { .characters = cast[..] };
	String bare = crig::scene_file_text(mem, &none, scene_path);
	defer bare.free(mem);
	test::@check(!bare.contains(`"level"`), "a scene with no level has no key: %s", bare);
	crig::SceneFile plain = crig::parse_scene_file(mem, bare, scene_path)!!;
	defer plain.free(mem);
	test::eq(plain.level, "");

	String wrong = `{"format":"rigsmith-scene","version":1,"level":3,"characters":[{"model":"a.glb"}]}`;
	test::@check(@catch(crig::parse_scene_file(mem, wrong, "x.json")) == crig::SCENE_SHAPE, "a level that is not a path does not read");
}

<* A saved scene opens with its level again; the level is not one of its characters. *>
fn void a_saved_scene_keeps_its_level() @test
{
	if (catch path::mkdir((Path)LEVEL_FOLDER)) {}
	String person = helpers::copy_into(LEVEL_FOLDER, string::tformat("%s/humanoid.glb", library::ready()), "person.glb");
	String backdrop = helpers::copy_into(LEVEL_FOLDER, "assets/animations/humanoid.glb", "backdrop.glb");
	defer { person.free(mem); backdrop.free(mem); }
	(void)file::delete(LEVEL_FOLDER +++ "/person.rigsmith.json");
	(void)file::delete(LEVEL_FOLDER +++ "/person_copy.glb");
	(void)file::delete(LEVEL_FOLDER +++ "/person_copy.rigsmith.json");
	String saved = LEVEL_FOLDER +++ "/forest.rigsmith-scene.json";
	{
		crig::AppState app = crig::new_app({}, "");
		defer app.free();
		app.load_mesh(rig::load_gltf(mem, person)!!, person);
		test::@check(app.open_level(backdrop), "the level opens: %s", app.notice());
		test::@check(app.has_level(), "and the scene has one");
		test::eq((int)app.character_count(), 1);
		test::@check(app.save_scene(saved), "the scene saves: %s", app.notice());
	}
	char[] text = file::load(mem, saved)!!;
	defer alloc::free(mem, text);
	test::@check(((String)text).contains(`"level": "backdrop.glb"`), "the level is written beside it: %s", (String)text);

	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_scene(saved), "the scene opens: %s", app.notice());
	test::@check(app.level_path.ends_with("backdrop.glb"), "with its level: %s", app.level_path);
	test::eq((int)app.character_count(), 1);
	test::@check(app.new_scene(), "a new scene is made");
	test::@check(!app.has_level(), "and it has no level");
}

<* A level that has gone is a notice: the characters open all the same. *>
fn void a_missing_level_still_opens_the_scene() @test
{
	if (catch path::mkdir((Path)LEVEL_FOLDER)) {}
	String person = helpers::copy_into(LEVEL_FOLDER, string::tformat("%s/humanoid.glb", library::ready()), "lonely.glb");
	defer person.free(mem);
	(void)file::delete(LEVEL_FOLDER +++ "/lonely.rigsmith.json");
	String scene = LEVEL_FOLDER +++ "/gone.rigsmith-scene.json";
	file::save(scene, `{"format":"rigsmith-scene","version":1,"level":"nowhere/forest.glb","characters":[{"model":"lonely.glb"}]}`)!!;

	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.open_scene(scene), "the scene opens without its level: %s", app.notice());
	test::@check(app.notice().contains("forest.glb is missing"), "and says the level is missing: %s", app.notice());
	test::@check(!app.has_level(), "with no level");
	test::eq((int)app.character_count(), 1);
}

// ---------------------------------------------------------------------------
// Import .glb: a level, a character or refused
// ---------------------------------------------------------------------------

const String IMPORT_FOLDER = "build/test-level-import";

// A level by the import rule, a collider on a node outside any rig; the caller owns the path.
fn String write_collider_level(String name) @local
{
	(void)path::mkdir(IMPORT_FOLDER, true);
	String target = string::format(mem, "%s/%s", IMPORT_FOLDER, name);
	file::save(target, `{"asset":{"version":"2.0"},"nodes":[{"name":"ground",
		"extensions":{"KHR_physics_rigid_bodies":{"collider":{"geometry":{"shape":0}}}}}]}`)!!;
	return target;
}

<* A level opens behind the scene, replacing the one open, and the notice says so. *>
fn void importing_a_level_opens_it() @test
{
	String forest = write_collider_level("forest.gltf");
	String cave = write_collider_level("cave.gltf");
	defer { forest.free(mem); cave.free(mem); }
	crig::AppState app = crig::new_app({}, "");
	defer app.free();

	test::@check(app.import_glb(forest), "the level is refused: %s", app.notice());
	test::@check(app.has_level() && app.level_path == forest, "it is the scene's level: %s", app.level_path);
	test::@check(app.pending_add.len == 0, "and not a character: %s", app.pending_add);
	test::@check(app.notice().contains("forest.gltf") && !app.notice().contains("replaces"), "the notice: %s", app.notice());

	test::@check(app.import_glb(cave) && app.level_path == cave, "a second level is refused: %s", app.notice());
	test::@check(app.notice().contains("cave.gltf") && app.notice().contains("replaces forest.gltf"),
		"and says what it replaced: %s", app.notice());
}

<* A model with one rig is added as a character, as Import always did. *>
fn void importing_a_character_adds_it() @test
{
	String person = string::format(mem, "%s/humanoid.glb", library::ready());
	defer person.free(mem);
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.import_glb(person), "the character is refused: %s", app.notice());
	test::@check(app.pending_add == person && !app.has_level(), "it waits to be added: %s", app.pending_add);
}

<* A cutscene file is refused: nothing is added and no level opens. *>
fn void importing_a_cutscene_is_refused() @test
{
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(!app.import_glb("assets/cutscenes/intro.cutscene.glb"), "the cutscene file was taken");
	test::@check(app.notice().contains("intro.cutscene.glb is a cutscene file"), "the notice: %s", app.notice());
	test::@check(app.pending_add.len == 0 && !app.has_level(), "and nothing came in");
}

<* A file that is not glTF goes the character's way, whose load says it would not open. *>
fn void importing_an_unreadable_file_says_why() @test
{
	crig::AppState app = crig::new_app({}, "");
	defer app.free();
	test::@check(app.import_glb("assets/cutscenes/intro.cutscene.bin"), "the file was refused before its load");
	test::@check(!app.has_level(), "it is not a level");
	app.service_pending_add();
	test::@check(app.notice().contains("could not open intro.cutscene"), "the notice: %s", app.notice());
}

<* MCP add_character refuses a level and a cutscene file; open_level still opens the level. *>
fn void add_character_refuses_a_level() @test
{
	(void)path::mkdir(IMPORT_FOLDER, true);
	String level = IMPORT_FOLDER +++ "/two_rigs.gltf";
	file::save(level, `{"asset":{"version":"2.0"},"nodes":[
		{"name":"hero_rig","children":[1,2]},{"name":"hips"},{"name":"hero_body","mesh":0,"skin":0},
		{"name":"guide_rig","children":[4,5]},{"name":"root"},{"name":"guide_body","mesh":0,"skin":1}],
		"skins":[{"joints":[1]},{"joints":[4]}],"meshes":[{"primitives":[]}]}`)!!;
	Fixture* f = mem::new(Fixture);
	defer free(f);
	f.app = crig::new_app({}, "");
	f.tools = crig::new_tool_table(&f.app);
	f.server = crig::serve_table(&f.tools, &f.app);
	defer f.close();

	String asked = string::tformat(`{"path":"%s"}`, level);
	test::@check(f.refuses_tool("add_character", asked, "two_rigs.gltf is a level",
		"(0 colliders outside a rig, 2 rigged armatures)", "open_level opens it"), "add_character took the level");
	test::@check(f.refuses_tool("add_character", `{"path":"assets/cutscenes/intro.cutscene.glb"}`, "is a cutscene file"),
		"add_character took the cutscene file");
	test::@check(f.app.pending_add.len == 0 && f.app.character_count() == 1 && !f.app.has_level(), "nothing came in");

	String? opened = f.call_tool_text("open_level", asked);
	if (try opened) opened.free(mem);
	test::@check(@ok(opened) && f.app.has_level(), "open_level does not open it");
}

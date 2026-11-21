<*
 The level: a whole scene file drawn behind the characters, read through three's
 own loader. Never selected, edited, saved or undone; its colliders are the ground.
 A level character an actor reads is drawn by the level itself, posed through
 `Scene.set_palette` from that actor's pose.
*>
module crig;

import three;
import collision;
import rig;
import std::math;
import std::math::matrix;
import std::time;
import std::collections::list;
import std::hash::fnv32a;

enum LevelPhase : char
{
	NONE,
	WAITING, // asked for; the next frame says so before the read stalls it
	READING, // three's load runs this frame
	PLACING, // nodes go in a slice per frame
	SHOWN,
}

// How long a frame may spend placing nodes before it draws.
const long LEVEL_SLICE_NS = 12_000_000;
const usz GROUND_RAY_HITS = 128;
// How far off a wall a view ray's hit is dropped from.
const float GROUND_STEP_OFF = 0.05f;
// How many faces a ray may pass out of before a collider is given up on.
const int GROUND_FACES_PASSED = 4;
// What the file's Watts mean to three's shading; the prelude's numbers.
const float LEVEL_SUN_FROM_WATTS = (float)(1.0 / math::PI);
const float LEVEL_LAMP_FROM_WATTS = (float)(1.0 / (4.0 * math::PI * math::PI));
// Where a lamp with no range stops: EEVEE's light threshold.
const float LEVEL_LIGHT_THRESHOLD = 0.01f;
const float[4] COLLIDER_MESH_INK = { 0.35f, 0.95f, 0.55f, 1.0f };
const float[4] COLLIDER_SHAPE_INK = { 1.0f, 0.62f, 0.25f, 1.0f };

<* What lies under a point: the first collider a ray meets, with its normal facing the ray. *>
struct GroundHit
{
	bool hit;
	Vec3 point;
	Vec3 normal;
	three::NodeId node;
}

<* How far the level has got, for the menus and the wire. *>
struct LevelReport
{
	LevelPhase phase;
	float progress;
	usz nodes;
	usz colliders;
	usz lights;
	long read_ms;
	long place_ms;
	bool boxed;
	collision::Aabb3 box;
}

<* A level character's copy posed by the actor read from it: its skinned nodes, and its skin at rest. *>
struct LevelDrive @local
{
	uint character; // the actor's character id
	List{three::NodeId} meshes;
	// Per skin joint: the joint at rest times its inverse bind, in the level's space, and its name (the level's).
	Matrix4f[] rest;
	String[] names;
}

fn void LevelDrive.free(&self)
{
	self.meshes.free();
	if (self.rest.len > 0) free(self.rest);
	if (self.names.len > 0) free(self.names);
	*self = {};
}

struct LevelStage @local
{
	String file; // owned
	LevelPhase phase;
	bool frame_wanted;
	three::AssetId asset;
	// A reference on mesh 0, so a sweep between the read and the first node keeps the file.
	bool holding;
	three::NodeId root;
	List{three::PlacedNode} placed;
	List{three::NodeId} created;
	usz cursor;
	Clock started;
	long read_ms;
	long place_ms;
	int shown_percent;
	usz colliders;
	usz lights;
	bool boxed;
	collision::Aabb3 box;
	bool lit;
	three::Lighting was_lighting;
	bool visible;
	bool out_of_renders;
	three::NodeId[2] lines;
	bool lines_built;
	uint lines_serial;
	// Which level characters are hidden for the actors standing in for them, by a hash of their names.
	uint hidden_key;
	bool hidden_applied;
	// The copies posed by actors read from the level.
	List{LevelDrive} drives;
}

// A zero NodeId names a node, so the empty level says NO_NODE outright.
const LevelStage NO_LEVEL @local = { .root = three::NO_NODE, .lines = { three::NO_NODE, three::NO_NODE }, .asset = three::NO_ASSET };

LevelStage level @local = NO_LEVEL;

// Whether a level is open or on its way.
fn bool level_busy() => level.phase == WAITING || level.phase == READING || level.phase == PLACING;
// Whether the level is in the scene, whole or still arriving.
fn bool level_in_view() => level.phase == PLACING || level.phase == SHOWN;
fn bool level_shown() => level.phase == SHOWN;

// Leave the level out of the frames drawn until called again with false.
fn void hide_level_for_render(bool hidden) => level.out_of_renders = hidden;

<*
 Ask for the level at `path`, replacing any open one. Read between frames by `service_level`.

 @param path : "A .glb or .gltf"
*>
fn void request_level(String path, bool frame)
{
	if (!hosted()) return;
	drop_level();
	level.file = path.copy(mem);
	level.phase = WAITING;
	level.frame_wanted = frame;
}

// Point the camera at the level once it is in.
fn void frame_level_when_in() => level.frame_wanted = true;

<* Take the level out of the scene, put the lights back and give its buffers back. *>
fn void drop_level()
{
	if (!hosted()) return;
	drop_collider_lines();
	release_drives(stage_scene() != null);
	level.drives.free();
	if (stage_scene() != null && level.root.is_set()) stage_scene().remove(level.root);
	if (level.holding) stage_pass().assets.release(level.asset, 0);
	if (level.lit)
	{
		three::MeshPass* pass = stage_pass();
		pass.note_lighting_change(level.was_lighting);
		pass.lighting = level.was_lighting;
		if (pass.scene != null) pass.scene.look.lighting = level.was_lighting;
	}
	level.placed.free();
	level.created.free();
	if (level.file.len > 0) level.file.free(mem);
	bool had = level.phase != NONE;
	bool out = level.out_of_renders;
	level = NO_LEVEL;
	level.out_of_renders = out;
	if (had) sweep_assets();
}

<* The level's progress so far. *>
fn LevelReport level_report()
{
	usz total = (usz)level.placed.len();
	float progress = 0.0f;
	switch (level.phase)
	{
		case NONE:
		case WAITING:
		case READING: progress = 0.0f;
		case PLACING: progress = total == 0 ? 0.0f : (float)level.cursor / (float)total;
		case SHOWN: progress = 1.0f;
	}
	return {
		.phase = level.phase,
		.progress = progress,
		.nodes = (usz)level.created.len(),
		.colliders = level.colliders,
		.lights = level.lights,
		.read_ms = level.read_ms,
		.place_ms = level.place_ms,
		.boxed = level.boxed,
		.box = level.box,
	};
}

<*
 One step of the level's load, between frames. True while there is more to do.

 @param [&inout] app
*>
fn bool service_level(AppState* app)
{
	if (!hosted() || stage_scene() == null) return level_busy();
	if (level.phase == WAITING)
	{
		app.@notice("Opening the level %s…", base_name(level.file));
		level.phase = READING;
	}
	else if (level.phase == READING)
	{
		read_level(app);
	}
	else if (level.phase == PLACING)
	{
		place_level_slice(app);
	}
	return level_busy();
}

fn void read_level(AppState* app) @local
{
	level.started = clock::now();
	three::Assets* assets = &stage_pass().assets;
	three::AssetId? loaded = assets.load(&stage_renderer().gpu, level.file);
	if (catch err = loaded)
	{
		app.@notice("could not open the level %s: %s", base_name(level.file), err);
		app.level_failed();
		drop_level();
		return;
	}
	level.asset = loaded;
	assets.retain(loaded, 0);
	level.holding = true;
	level.read_ms = (long)level.started.to_now() / 1_000_000;

	level.placed.init(mem, 256);
	level.created.init(mem, 256);
	// The file says what collides: `instantiate({ physics: true })`'s walk.
	assets.flatten(loaded, &level.placed, false, true);
	level.root = stage_scene().add_group(stage_scene().root, "crig:level");
	level.cursor = 0;
	level.shown_percent = -1;
	level.visible = true;
	level.started = clock::now();
	level.phase = PLACING;
}

fn void place_level_slice(AppState* app) @local
{
	Clock slice = clock::now();
	usz total = (usz)level.placed.len();
	while (level.cursor < total)
	{
		place_level_entry(level.cursor++);
		if ((long)slice.to_now() > LEVEL_SLICE_NS) break;
	}
	if (level.cursor < total)
	{
		int percent = (int)(100 * level.cursor / total);
		if (percent != level.shown_percent) app.@notice("Opening the level %s… %d%%", base_name(level.file), percent);
		level.shown_percent = percent;
		return;
	}
	finish_level(app);
}

// One entry of the walk as a node, the way `Scene.instantiate` makes it.
fn void place_level_entry(usz i) @local
{
	three::PlacedNode* entry = &level.placed[(sz)i];
	three::NodeId into = entry.parent < 0 ? level.root : level.created[entry.parent];
	if (!into.is_set()) into = level.root;
	three::NodeId id = entry.mesh < 0 ? stage_scene().add_group(into, entry.name)
		: stage_scene().add_mesh(level.asset, (uint)entry.mesh, into, entry.name);
	level.created.push(id);
	three::Node* node = stage_scene().node(id);
	if (node == null) return;
	node.position = entry.position;
	node.rotation = entry.rotation;
	node.scale = entry.scale;
	node.color = entry.color;
	node.collides = entry.collides;
	node.collision_only = entry.collision_only;
	stage_scene().set_skin(id, entry.skin);
	node.dirty = true;
}

fn void finish_level(AppState* app) @local
{
	level.place_ms = (long)level.started.to_now() / 1_000_000;
	stage_scene().start_player(level.asset, level.root, level.placed.array_view(), level.created.array_view());
	foreach (entry : level.placed)
	{
		if (entry.mesh >= 0 && entry.collides) level.colliders++;
	}
	stage_scene().update_world_matrices();
	level.box = stage_scene().subtree_bounds(&stage_pass().assets, level.root, &level.boxed);
	light_level();
	level.phase = SHOWN;
	if (level.frame_wanted) app.frame_level();
	app.level_came_in();
	app.@notice("opened the level %s · %d nodes, %d colliders, %d lights · %.1f s",
		base_name(level.file), level.created.len(), level.colliders, level.lights,
		(double)(level.read_ms + level.place_ms) / 1000.0);
	app.refresh_ui();
}

<*
 The file's lights in place of the stage's: the sun in slot zero, the lamps nearest
 the file's first camera after it. The same reading as the prelude's `_placeLights`.
*>
fn void light_level() @local
{
	three::MeshPass* pass = stage_pass();
	three::Asset* file = pass.assets.slot(level.asset);
	if (file == null || file.lights.len() == 0) return;

	level.was_lighting = pass.lighting;
	level.lit = true;
	three::Lighting lit = pass.lighting;
	sz sun = -1;
	foreach (i, &light : file.lights)
	{
		if (light.kind == 0) { sun = (sz)i; break; }
	}
	if (sun >= 0)
	{
		three::AssetLight* s = &file.lights[sun];
		// The file's direction is the way the light travels; three's points at it.
		lit.lights[0].direction = { -s.direction.x, -s.direction.y, -s.direction.z, 0 };
		lit.lights[0].color = { clamp_unit(s.color[0]), clamp_unit(s.color[1]), clamp_unit(s.color[2]),
			math::max(s.intensity * LEVEL_SUN_FROM_WATTS, 0.0f) };
	}

	Vec3 shot = file.cameras.len() > 0 ? file.cameras[0].position : (Vec3){ 0, 0, 0 };
	List{sz} near;
	near.init(mem, file.lights.len());
	defer near.free();
	foreach (i, &light : file.lights)
	{
		if ((sz)i == sun) continue;
		float d = (light.position - shot).length_sq();
		usz at = (usz)near.len();
		near.push(i);
		while (at > 0 && (file.lights[near[(sz)at - 1]].position - shot).length_sq() > d)
		{
			near[(sz)at] = near[(sz)at - 1];
			at--;
		}
		near[(sz)at] = i;
	}

	lit.count = 1;
	level.lights = sun >= 0 ? 1 : 0;
	foreach (i : near)
	{
		if (lit.count >= three::MAX_LIGHTS) break;
		three::Light light = level_light(&file.lights[i]);
		light.meta[0] = lit.next_light_id++;
		light.meta[1] = 0xffffffff;
		lit.lights[lit.count++] = light;
		level.lights++;
	}
	pass.note_lighting_change(lit);
	pass.lighting = lit;
	if (pass.scene != null) pass.scene.look.lighting = lit;
}

fn float clamp_unit(float v) @local => math::clamp(v, 0.0f, 1.0f);

// One lamp of the file as three's registry holds it.
fn three::Light level_light(three::AssetLight* from) @local
{
	bool area = from.kind >= 3;
	float power = area ? from.intensity : from.intensity * LEVEL_LAMP_FROM_WATTS;
	float range = from.range > 0.0f ? from.range : level_reach(from.position, math::sqrt(math::max(power, 0.0f) / LEVEL_LIGHT_THRESHOLD));
	three::Light light = {
		.direction = { from.position.x, from.position.y, from.position.z, range },
		.color = { clamp_unit(from.color[0]), clamp_unit(from.color[1]), clamp_unit(from.color[2]), math::max(power, 0.0f) },
	};
	if (area)
	{
		Vec3 right = from.right;
		Vec3 emitted = -(right.cross(from.up));
		if (emitted.dot(from.direction) < 0.0f) right = -right;
		float height = from.height > 0.0f ? from.height : from.width;
		light.meta[2] = from.area_shape >= 2 ? 3 : 2;
		light.area_right = { right.x, right.y, right.z, math::max(from.width, 0.0f) * 0.5f };
		light.area_up = { from.up.x, from.up.y, from.up.z, math::max(height, 0.0f) * 0.5f };
		return light;
	}
	if (from.kind == 2)
	{
		light.meta[2] = 4;
		light.area_right = { from.direction.x, from.direction.y, from.direction.z, math::cos(math::max(from.outer_cone, 0.0f)) };
		light.area_up = { 0, 0, 0, math::cos(math::max(from.inner_cone, 0.0f)) };
		return light;
	}
	light.meta[2] = 1;
	return light;
}

// A derived reach, no further than the far corner of the level.
fn float level_reach(Vec3 at, float derived) @local
{
	if (!level.boxed) return derived;
	collision::Aabb3 box = level.box;
	Vec3 far = { math::max(box.max.x - at.x, at.x - box.min.x), math::max(box.max.y - at.y, at.y - box.min.y),
		math::max(box.max.z - at.z, at.z - box.min.z) };
	return math::min(derived, far.length());
}

<*
 The level's bounds in the world, once it is whole.

 @param [&out] out
*>
fn bool level_bounds(rig::Bounds* out)
{
	if (level.phase != SHOWN || !level.boxed) return false;
	*out = { level.box.min, level.box.max };
	return true;
}

<*
 The shot the level was composed for: its first camera, as an orbit camera. False
 when the file has none.

 @param [&out] out
*>
fn bool level_shot(OrbitCamera* out)
{
	if (level.phase != SHOWN) return false;
	three::Asset* file = stage_pass().assets.slot(level.asset);
	if (file == null || file.cameras.len() == 0) return false;
	three::AssetCamera* shot = &file.cameras[0];
	float distance = shot.distance > 0.0f ? shot.distance : 10.0f;
	Vec3 boom = -shot.forward * distance;
	float flat = math::sqrt(boom.x * boom.x + boom.z * boom.z);
	out.target = shot.position + shot.forward * distance;
	out.distance = distance;
	out.yaw = (float)math::rad_to_deg(math::atan2(boom.x, boom.z));
	out.pitch = math::clamp((float)math::rad_to_deg(math::atan2(boom.y, flat)), -MAX_PITCH, MAX_PITCH);
	if (shot.yfov > 0.0f) out.fov = (float)math::rad_to_deg(shot.yfov);
	out.snapping = false;
	return true;
}

<* A far plane for an eye at `eye` that reaches the level's far corner, or `far` without a level. *>
fn float level_far_plane(Vec3 eye, float far)
{
	if (!level_in_view() || !level.boxed) return far;
	float reach;
	for (int corner = 0; corner < 8; corner++)
	{
		Vec3 at = {
			corner & 1 ? level.box.max.x : level.box.min.x,
			corner & 2 ? level.box.max.y : level.box.min.y,
			corner & 4 ? level.box.max.z : level.box.min.z,
		};
		reach = math::max(reach, (at - eye).length());
	}
	return math::max(far, reach * 1.05f);
}

<*
 The level's visibility and its collider lines, every frame. Called from `sync_scene`.

 @param [&inout] app
*>
fn void sync_level(AppState* app)
{
	if (!level.root.is_set()) return;
	bool shown = stage_pane_shown() && !level.out_of_renders;
	if (shown != level.visible)
	{
		stage_scene().set_visible(level.root, shown);
		level.visible = shown;
	}
	if (level.phase == SHOWN)
	{
		hide_taken_characters(app);
		drive_level_copies(app);
	}
	bool lines = app.show_colliders && level.phase == SHOWN;
	if (lines && !level.lines_built) build_collider_lines();
	foreach (node : level.lines)
	{
		if (node.is_set()) stage_scene().set_visible(node, lines && shown);
	}
}

<* The stage was replaced under the level: place it again in the new one. *>
fn void level_lost_stage()
{
	level.lines = { three::NO_NODE, three::NO_NODE };
	level.lines_built = false;
	level.root = three::NO_NODE;
	// Its nodes went with the old scene.
	release_drives(false);
	level.hidden_applied = false;
	if (stage_scene() == null || (level.phase != PLACING && level.phase != SHOWN)) return;
	level.created.clear();
	level.cursor = 0;
	level.colliders = 0;
	level.hidden_applied = false;
	level.phase = PLACING;
	level.root = stage_scene().add_group(stage_scene().root, "crig:level");
	level.visible = true;
	level.started = clock::now();
}

fn void drop_collider_lines() @local
{
	if (stage_scene() != null)
	{
		foreach (node : level.lines) if (node.is_set()) stage_scene().remove(node);
	}
	level.lines = { three::NO_NODE, three::NO_NODE };
	level.lines_built = false;
}

<* Every collider's rim and creases as lines in the world: drawn meshes in one ink, proxies in another. *>
fn void build_collider_lines() @local
{
	level.lines_built = true;
	stage_scene().update_world_matrices();
	three::Assets* assets = &stage_pass().assets;
	three::GeometryBuilder[2] shapes;
	foreach (&shape : shapes) shape.init();
	defer foreach (&shape : shapes) shape.free();

	foreach (id : level.created)
	{
		three::Node* node = stage_scene().node(id);
		if (node == null || !node.collides || node.mesh == three::NO_MESH) continue;
		three::GpuMesh* mesh = assets.mesh(node.asset, node.mesh);
		if (mesh == null || mesh.hull_positions.len == 0) continue;
		three::GeometryBuilder* into = &shapes[node.collision_only ? 1 : 0];
		@pool()
		{
			uint[] flat = alloc::new_array(tmem, uint, (sz)mesh.hull_triangles.len * 3);
			foreach (usz t, tri : mesh.hull_triangles)
			{
				flat[t * 3] = tri[0];
				flat[t * 3 + 1] = tri[1];
				flat[t * 3 + 2] = tri[2];
			}
			uint[] edges = outline_edges(tmem, mesh.hull_positions, flat);
			uint base = (uint)into.positions.len();
			foreach (at : mesh.hull_positions) into.positions.push(three::transform_point(node.world, at));
			foreach (v : edges) into.indices.push(base + v);
		};
	}

	foreach (k, &shape : shapes)
	{
		if (shape.indices.len() < 2) continue;
		level.lines_serial++;
		String key = string::tformat("crig:colliders:%d:%d", level.lines_serial, k);
		three::AssetId? made = stage_pass().assets.upload_built(&stage_renderer().gpu, key, key, shape, true);
		if (catch made) continue;
		three::NodeId node = stage_scene().add_mesh(made, 0, stage_scene().root, "crig:colliders");
		if (!node.is_set()) continue;
		stage_scene().set_material(node, three::LINE_MATERIAL);
		stage_scene().set_color(node, k == 0 ? COLLIDER_MESH_INK : COLLIDER_SHAPE_INK);
		level.lines[k] = node;
	}
	sweep_assets();
}

<*
 The first collider under `level` a ray meets from outside. Rigsmith's own draws
 and the level's drawings that do not collide are never hit.

 @param [&inout] scene
 @param [&inout] assets
*>
fn GroundHit first_collider_hit(three::Scene* scene, three::Assets* assets, three::NodeId level_root, collision::Ray ray)
{
	three::Hit[GROUND_RAY_HITS] hits;
	uint found = scene.raycast_all(assets, ray, 0.0f, hits[..]);
	three::IgnoreSet inside = { .count = 1 };
	inside.nodes[0] = level_root;
	GroundHit best;
	float nearest = float::max;
	for (uint i = 0; i < found; i++)
	{
		if (hits[i].distance >= nearest || !scene.ignored(hits[i].node, inside)) continue;
		three::Hit hit = hits[i];
		if (!front_face_hit(scene, assets, ray, &hit) || hit.distance >= nearest) continue;
		nearest = hit.distance;
		best = { .hit = true, .point = hit.point, .normal = hit.normal, .node = hit.node };
	}
	return best;
}

<*
 Move a hit on past the faces the ray leaves a collider through, to the first it
 enters by: a ray that starts inside a trunk's hull is not stopped by it.

 @param [&inout] scene
 @param [&inout] assets
 @param [&inout] hit
*>
fn bool front_face_hit(three::Scene* scene, three::Assets* assets, collision::Ray ray, three::Hit* hit) @local
{
	for (int k = 0; k < GROUND_FACES_PASSED; k++)
	{
		if (hit.normal.dot(ray.direction) <= 0.0f) return true;
		float step = 1.0e-3f;
		collision::Ray past = { .origin = hit.point + ray.direction * step, .direction = ray.direction };
		three::Hit next;
		if (!scene.ray_hits_node(assets, hit.node, past, float::max, &next)) return false;
		next.distance += hit.distance + step;
		*hit = next;
	}
	return false;
}

<*
 The ground under `at`: a ray straight down from GROUND_RAY_LIFT above it, against
 the colliders under `level_root` only.

 @param [&inout] scene
 @param [&inout] assets
*>
fn GroundHit ground_below_in(three::Scene* scene, three::Assets* assets, three::NodeId level_root, Vec3 at)
{
	collision::Ray ray = { .origin = at + (Vec3){ 0, GROUND_RAY_LIFT, 0 }, .direction = { 0, -1, 0 } };
	return first_collider_hit(scene, assets, level_root, ray);
}

<*
 The ground where a view ray lands: the first collider it meets, dropped onto the
 ground there as a path point would be.

 @param [&inout] scene
 @param [&inout] assets
*>
fn GroundHit ground_along_in(three::Scene* scene, three::Assets* assets, three::NodeId level_root, collision::Ray ray)
{
	GroundHit seen = first_collider_hit(scene, assets, level_root, ray);
	if (!seen.hit) return seen;
	// Dropped from just off the face, so a trunk's side drops to the ground beside it.
	GroundHit below = ground_below_in(scene, assets, level_root, seen.point + seen.normal * GROUND_STEP_OFF);
	return below.hit ? below : seen;
}

fn bool level_queryable() @local => level.phase == SHOWN && stage_scene() != null && level.root.is_set();

<* The ground under a point of the open level, or no hit without one. *>
fn GroundHit ground_below(Vec3 at)
{
	if (!level_queryable()) return {};
	// A hidden node is never hit, and a level out of view still has its ground.
	bool hidden = !level.visible;
	if (hidden) stage_scene().set_visible(level.root, true);
	defer if (hidden) stage_scene().set_visible(level.root, false);
	return ground_below_in(stage_scene(), &stage_pass().assets, level.root, at);
}

// The ground below a point as a walk's samples ask for it.
fn bool level_ground_height(void* context, Vec3 at, float* height) @local
{
	GroundHit hit = ground_below(at);
	if (hit.hit) *height = hit.point.y;
	return hit.hit;
}

<* The open level's ground for a walk's samples to drop onto; none without a level in. *>
fn WalkGround level_walk_ground() => level_queryable() ? (WalkGround){ .probe = &level_ground_height } : (WalkGround){};

<*
 What an upright capsule meets among the level's colliders as it goes from
 standing at `from` to standing at `to`: `height` tall and `radius` wide, its
 bottom `step` above the ground so the ground itself is stepped over. Nothing
 else in the scene counts.

 @require radius > 0.0f && height > step : "A capsule taller than its step"
*>
fn GroundHit level_capsule_hit(Vec3 from, Vec3 to, float radius, float height, float step)
{
	if (!level_queryable()) return {};
	bool hidden = !level.visible;
	if (hidden) stage_scene().set_visible(level.root, true);
	defer if (hidden) stage_scene().set_visible(level.root, false);
	three::Scene* scene = stage_scene();
	three::Assets* assets = &stage_pass().assets;
	float tall = height - step;
	float half = math::max(tall * 0.5f - radius, 0.0f);
	Vec3 up = { 0, step + tall * 0.5f, 0 };
	three::IgnoreSet inside = { .count = 1 };
	inside.nodes[0] = level.root;
	// What else the sweep meets first is left out and the sweep tried again.
	three::IgnoreSet skip;
	while (true)
	{
		three::SweepHit hit = scene.sweep_capsule(assets, from + up, to + up, radius, half, 0.0f, skip);
		if (!hit.hit) return {};
		if (scene.ignored(hit.node, inside)) return { .hit = true, .point = hit.point, .normal = hit.normal, .node = hit.node };
		if (skip.count >= three::MAX_IGNORED) return {};
		skip.nodes[skip.count++] = hit.node;
	}
}

<* The ground where a view ray lands in the open level, as a click on it would. *>
fn GroundHit ground_along(collision::Ray ray)
{
	if (!level_queryable()) return {};
	bool hidden = !level.visible;
	if (hidden) stage_scene().set_visible(level.root, true);
	defer if (hidden) stage_scene().set_visible(level.root, false);
	return ground_along_in(stage_scene(), &stage_pass().assets, level.root, ray);
}

<* The ground under a pixel of the first 3D view, in the window's device pixels as a full-size screenshot has them. *>
fn GroundHit ground_under_pixel(float x, float y)
{
	if (!level_queryable()) return {};
	three::MeshPass* pass = stage_pass();
	three::Renderer* renderer = stage_renderer();
	float window_w = (float)renderer.target.extent.width;
	float window_h = (float)renderer.target.extent.height;
	float width = window_w * pass.view_rect[2];
	float height = window_h * pass.view_rect[3];
	if (width < 1.0f || height < 1.0f) return {};
	return ground_along(three::screen_ray(&pass.camera, x - window_w * pass.view_rect[0], y - window_h * pass.view_rect[1],
		(uint)width, (uint)height));
}

<* The name of the node a hit landed on, borrowed from the scene. *>
fn String level_name_in(three::Scene* scene, three::NodeId node)
{
	if (scene == null) return "";
	three::Node* found = scene.node(node);
	return found == null ? "" : found.name;
}

fn String level_node_name(three::NodeId node) => level_name_in(stage_scene(), node);

<* A rigged character standing in the level: its armature node, where it stands, and how tall its copy is drawn. *>
struct LevelCharacter
{
	String name; // borrowed from the level
	Vec3 position;
	Quaternionf rotation;
	float height;
	float floor; // the height its feet stand at: its lowest point at rest
	usz entry;   // the armature's place in the level's walk
	// Its skin's joints at rest, names borrowed from the level; empty unless asked for (level_character_rig).
	JointRest[] rig;
}

<*
 The joints the skin of the level character whose armature is walk entry `entry` binds, at rest:
 each node's own transform, its parent named when that is one of the joints.

 @return "The caller frees the array; the names are the level's"
*>
fn JointRest[] level_character_rig(Allocator allocator, usz entry)
{
	if (level.phase != SHOWN) return {};
	three::Asset* file = stage_pass().assets.slot(level.asset);
	if (file == null) return {};
	int skin = -1;
	foreach (usz i, &e : level.placed)
	{
		if (e.skin >= 0 && level_skin_owner(i) == (sz)entry) skin = e.skin;
	}
	if (skin < 0 || (usz)skin >= (usz)file.skins.len()) return {};
	// The joints themselves are pruned from the walk, so they are read off the file's nodes.
	List{uint} joints = file.skins[skin].joints;
	JointRest[] out = alloc::new_array(allocator, JointRest, (sz)joints.len());
	usz kept;
	foreach (node : joints)
	{
		if (node >= file.nodes.len()) continue;
		three::AssetNode* n = &file.nodes[node];
		String parent = "";
		foreach (other : joints)
		{
			if (other >= file.nodes.len()) continue;
			foreach (child : file.nodes[other].children) if (child == node) parent = file.nodes[other].name;
		}
		out[kept++] = { .name = n.name, .parent = parent, .translation = n.position, .rotation = n.rotation, .scale = n.scale };
	}
	return out[:kept];
}

// An entry's place in the world, through its parents in the walk.
fn void level_entry_world(usz i, Vec3* at, Quaternionf* turn, Vec3* scale) @local
{
	three::PlacedNode* e = &level.placed[(sz)i];
	Vec3 p = e.position;
	Quaternionf r = e.rotation;
	Vec3 k = e.scale;
	int parent = e.parent;
	while (parent >= 0)
	{
		three::PlacedNode* up = &level.placed[parent];
		p = up.position + up.rotation.rotate_vec3(p * up.scale);
		r = up.rotation.mul(r);
		k = k * up.scale;
		parent = up.parent;
	}
	*at = p;
	*turn = r.normalize();
	*scale = k;
}

// The armature a skinned entry belongs with: its owner, or its owner's when it is a primitive of one.
fn sz level_skin_owner(usz i) @local
{
	three::PlacedNode* e = &level.placed[(sz)i];
	if (e.skin < 0) return -1;
	if (e.gltf_node >= 0) return e.owner;
	return e.parent >= 0 ? level.placed[e.parent].owner : -1;
}

<*
 The level's rigged characters, one per armature that a skinned mesh hangs off,
 in the order the file has them. Empty until the level is in.

 @return "The caller owns the array; the names are the level's"
*>
fn LevelCharacter[] level_characters(Allocator allocator)
{
	if (level.phase != SHOWN) return {};
	List{LevelCharacter} found;
	found.init(mem);
	defer found.free();
	three::Assets* assets = &stage_pass().assets;
	foreach (usz i, &entry : level.placed)
	{
		sz owner = level_skin_owner(i);
		if (owner < 0 || entry.mesh < 0) continue;
		three::GpuMesh* mesh = assets.mesh(level.asset, (uint)entry.mesh);
		float tall = mesh ? mesh.bounds.max.y - mesh.bounds.min.y : 0.0f;
		float low = mesh ? mesh.bounds.min.y : 0.0f;
		Vec3 position;
		Quaternionf rotation;
		Vec3 scale;
		level_entry_world((usz)owner, &position, &rotation, &scale);
		// A skin's rest mesh is in its armature's space, so the armature places and scales it.
		float floor = position.y + low * math::abs(scale.y);
		sz at = -1;
		foreach (usz k, &c : found) if (c.entry == (usz)owner) at = (sz)k;
		if (at < 0)
		{
			found.push({ .name = level.placed[owner].name, .entry = (usz)owner, .position = position, .rotation = rotation,
				.height = tall * math::abs(scale.y), .floor = floor });
			continue;
		}
		LevelCharacter* c = found.get_ref(at);
		c.height = math::max(c.height, tall * math::abs(scale.y));
		c.floor = math::min(c.floor, floor);
	}
	if (found.len() == 0) return {};
	return found.to_array(allocator);
}

<* The level character whose armature is called `name`. *>
fn bool level_character_named(String name, LevelCharacter* out)
{
	bool hit;
	@pool()
	{
		foreach (c : level_characters(tmem))
		{
			if (c.name != name) continue;
			*out = c;
			hit = true;
			break;
		}
	};
	return hit;
}

// Each level character a stand-in takes the place of is hidden; one read by an actor is posed by it; the rest are shown.
fn void hide_taken_characters(AppState* app) @local
{
	Fnv32a key;
	key.init();
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* actor = app.character(i);
		key.text(actor.level_node);
		key.mix(actor.id);
		key.mix(actor.level_read);
		key.mix(actor.hidden);
	}
	if (level.hidden_applied && (uint)key == level.hidden_key) return;
	level.hidden_key = (uint)key;
	level.hidden_applied = true;
	release_drives(true);
	@pool()
	{
		foreach (c : level_characters(tmem))
		{
			sz holder = app.level_node_character(c.name);
			Character* actor = holder >= 0 ? app.character((usz)holder) : null;
			bool read = actor && actor.level_read;
			bool shown = !actor || (read && !actor.hidden);
			foreach (usz i, &entry : level.placed)
			{
				bool part = i == c.entry || level_skin_owner(i) == (sz)c.entry;
				if (!part || i >= (usz)level.created.len()) continue;
				stage_scene().set_visible(level.created[(sz)i], shown);
			}
			if (read) add_drive(actor.id, c.entry);
		}
	};
}

// Every posed copy back at rest, and forgotten; `clear` while its nodes are still in the scene.
fn void release_drives(bool clear) @local
{
	foreach (&d : level.drives)
	{
		if (clear && stage_scene() != null)
		{
			foreach (node : d.meshes) stage_scene().clear_palette(node);
		}
		d.free();
	}
	if (level.drives.is_initialized()) level.drives.clear();
}

// The copy of the level character whose armature is walk entry `entry`, to be posed by character `id`.
fn void add_drive(uint id, usz entry) @local
{
	three::Asset* file = stage_pass().assets.slot(level.asset);
	if (file == null) return;
	LevelDrive d = { .character = id };
	d.meshes.init(mem);
	int skin = -1;
	foreach (usz i, &e : level.placed)
	{
		if (e.mesh < 0 || e.skin < 0 || level_skin_owner(i) != (sz)entry || i >= (usz)level.created.len()) continue;
		if (skin >= 0 && e.skin != skin) continue;
		skin = e.skin;
		d.meshes.push(level.created[(sz)i]);
	}
	if (skin < 0 || (usz)skin >= (usz)file.skins.len() || !file.skins[skin].loaded)
	{
		d.free();
		return;
	}
	three::AssetSkin* bound = &file.skins[skin];
	usz nodes = (usz)file.nodes.len();
	three::PosedNode[] posed = alloc::new_array(tmem, three::PosedNode, (sz)nodes);
	Matrix4f[] locals = alloc::new_array(tmem, Matrix4f, (sz)nodes);
	Matrix4f[] world = alloc::new_array(tmem, Matrix4f, (sz)nodes);
	foreach (usz i, &n : file.nodes) posed[i] = { n.position, n.rotation, n.scale };
	file.compose_posed(posed, locals, world);
	d.rest = alloc::new_array(mem, Matrix4f, (sz)bound.joints.len());
	d.names = alloc::new_array(mem, String, (sz)bound.joints.len());
	foreach (usz j, joint : bound.joints)
	{
		Matrix4f inverse = j < (usz)bound.inverse_bind.len() ? bound.inverse_bind[(sz)j] : matrix::IDENTITY4{float};
		d.rest[j] = joint < nodes ? world[joint].mul(inverse) : matrix::IDENTITY4{float};
		d.names[j] = joint < nodes ? file.nodes[joint].name : "";
	}
	if (!level.drives.is_initialized()) level.drives.init(mem);
	level.drives.push(d);
}

// A character's placement and size as one matrix.
fn Matrix4f placed_matrix(ProjectTransform place, float scale) @local
{
	return place.matrix().mul(matrix::IDENTITY4{float}.scale({ scale, scale, scale }));
}

<*
 Each copy an actor read from the level poses, posed as it is: the actor's own pose, carried from
 where it stood when read to where it is drawn now. A joint matrix is that move, the actor's own
 joint matrix, and the copy's joint at rest, so at rest where the level put it the copy is as drawn.
*>
fn void drive_level_copies(AppState* app) @local
{
	if (!level.drives.is_initialized()) return;
	foreach (&d : level.drives)
	{
		sz at = app.character_by_id(d.character);
		if (at < 0) continue;
		Character* c = app.character((usz)at);
		Matrix4f now = placed_matrix(c.placement(), c.drawn_scale());
		Matrix4f back = three::invert(placed_matrix(c.doc.model_transform, c.stage_scale > 0.0f ? c.stage_scale : 1.0f));
		bool posed = c.skinned() && c.pose_palette.len > 0;
		@pool()
		{
			Matrix4f[] palette = alloc::new_array(tmem, Matrix4f, (sz)d.rest.len);
			foreach (usz j, rest : d.rest)
			{
				Matrix4f own = matrix::IDENTITY4{float};
				// By the joint's name: the actor's rig was read from the same file, perhaps by another skin order.
				sz k = posed ? joint_rest_index(c.stage_rig, d.names[j]) : -1;
				int follows = k >= 0 && (usz)k < c.level_joints.len ? c.level_joints[k] : -1;
				if (follows >= 0 && (usz)follows < c.pose_palette.len) own = c.pose_palette[follows];
				palette[j] = now.mul(own).mul(back).mul(rest);
			}
			Matrix4f[] local = alloc::new_array(tmem, Matrix4f, (sz)d.rest.len);
			foreach (node : d.meshes)
			{
				three::Node* mesh = stage_scene().node(node);
				if (mesh == null) continue;
				// In the mesh node's own space, which its world goes on top of in the shader.
				Matrix4f to_mesh = three::invert(mesh.world);
				foreach (usz j, m : palette) local[j] = to_mesh.mul(m);
				(void)stage_scene().set_palette(node, local);
			}
		};
	}
}

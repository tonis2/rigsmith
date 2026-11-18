<*
 A cutscene's walks: its paths edited (added, renamed, deleted, drawn knot by knot,
 a knot dragged, put in or taken out), each sampled and dropped onto the level's
 ground; Walk here; and the rate a move's clip plays at so its feet keep to the
 ground. Each edit is one step of the cutscene history.
*>
module crig;

import collision;
import rig;
import std::collections::list;
import std::math;

const String CUT_PATH_NAME = "Path";
// A walk is checked for colliders with a capsule this far over the ground, so the ground is stepped over.
const float CUT_WALK_STEP = 0.35f;
// A capsule's radius, as a share of the actor's narrower width, within these bounds in metres.
const float CUT_WALK_RADIUS_LEAST = 0.1f;
const float CUT_WALK_RADIUS_MOST = 0.45f;
// A clip whose hips still cross more of the floor than this, in rig heights, travels.
const float CUT_CLIP_TRAVELS = 0.02f;
// The planted feet are read off this many instants of an in-place clip.
const usz CUT_SPEED_SAMPLES = 48;
// A character faces +Z when its facing is within 45 degrees of it.
const float CUT_FRONT_FACING = 0.7071f;

<* A clip's ground as measured on its character's rig, in model units a second. *>
struct CutClipMeasure
{
	uint character;
	uint revision;
	String clip; // owned
	CutClipGround ground;
}

<* A collider a walk passes through, at the actor's width and height. *>
struct CutWalkBlock
{
	usz actor;
	usz strip;
	String collider; // owned
	Vec3 at;
}

fn void AppState.free_cut_measures(&self)
{
	foreach (&m : self.cut_measures) if (m.clip.len > 0) alloc::free(mem, m.clip.ptr);
	self.cut_measures.free();
	foreach (&b : self.cut_blocks) if (b.collider.len > 0) alloc::free(mem, b.collider.ptr);
	self.cut_blocks.free();
	self.cut_blocks_key = 0;
}

// ---------------------------------------------------------------------------
// Paths on the ground

<* Sample the path's knots again, dropped onto the level's ground when one is in. *>
fn void AppState.ground_cut_path(&self, WalkPath* path)
{
	if (path.knots.len == 0) return;
	path.resample(mem, level_walk_ground());
}

<* Every path of every cutscene sampled and dropped again, as the ground is now. Not an edit. *>
fn void AppState.ground_all_cut_paths(&self)
{
	foreach (&c : self.cutscenes)
	{
		foreach (&p : c.paths) self.ground_cut_path(p);
	}
	self.cutscenes_changed();
}

<* The level is in: every stand-in reads its node again, and the paths drop onto its ground. *>
fn void AppState.level_came_in(&self)
{
	@pool()
	{
		LevelCharacter[] found = level_characters(tmem);
		foreach (&c : found) c.rig = level_character_rig(tmem, c.entry);
		self.restage_actors(found);
	};
	self.ground_all_cut_paths();
}

<*
 The ground where a view ray lands: the level's colliders, or the plane y = 0
 without a level.
*>
fn GroundHit cut_ground_along(collision::Ray ray)
{
	if (level_shown()) return ground_along(ray);
	if (level_busy() || math::abs(ray.direction.y) < 1e-6f) return {};
	float t = -ray.origin.y / ray.direction.y;
	if (t <= 0.0f) return {};
	return { .hit = true, .point = ray.origin + ray.direction * t, .normal = { 0, 1, 0 } };
}

// ---------------------------------------------------------------------------
// The picked path

<* The picked path of the active cutscene, or null. *>
fn WalkPath* AppState.cut_picked_path(&self)
{
	Cutscene* c = self.cutscene();
	if (!c || self.cut_path_pick == 0 || self.cut_path_pick > c.paths.len) return null;
	return &c.paths[self.cut_path_pick - 1];
}

<* Pick path `i` of the active cutscene, -1 for none. A choice, not an edit. *>
fn bool AppState.pick_cut_path(&self, sz i)
{
	Cutscene* c = self.cutscene();
	if (i >= 0 && (!c || (usz)i >= c.paths.len)) return false;
	if (self.cut_pick == PATH_KNOT) self.cancel_cut_pick();
	self.cut_path_pick = i < 0 ? 0 : (usz)i + 1;
	self.cut_knot_pick = 0;
	self.cut_revision = next_generation();
	return true;
}

// A pick on a path or knot that is gone is dropped.
fn void AppState.check_cut_path_pick(&self)
{
	WalkPath* path = self.cut_picked_path();
	if (!path)
	{
		self.cut_path_pick = 0;
		if (self.cut_pick == PATH_KNOT) self.cancel_cut_pick();
	}
	if (!path || self.cut_knot_pick > path.knots.len) self.cut_knot_pick = 0;
}

// ---------------------------------------------------------------------------
// The paths list, each one undo step

<*
 Add an empty path to the active cutscene and pick it. One undo step.

 @return "Its index, or -1 without a cutscene"
*>
fn sz AppState.add_cut_path(&self, String name = "")
{
	Cutscene* c = self.cutscene();
	if (!c) return -1;
	self.cut_checkpoint();
	c = self.cutscene();
	String base = name.trim().len > 0 ? name.trim() : CUT_PATH_NAME;
	String made = base.copy(mem);
	for (int n = 2; n < 1000; n++)
	{
		bool used;
		foreach (&p : c.paths) used = used || p.name == made;
		if (!used) break;
		made.free(mem);
		made = string::format(mem, "%s %d", base, n);
	}
	usz count = c.paths.len;
	WalkPath[] grown = alloc::new_array(mem, WalkPath, (sz)count + 1);
	foreach (usz k, p : c.paths) grown[k] = p;
	grown[count] = { .name = made };
	if (count > 0) alloc::free(mem, c.paths);
	c.paths = grown;
	self.cut_path_pick = count + 1;
	self.cut_knot_pick = 0;
	self.cutscenes_changed();
	return (sz)count;
}

<*
 Rename path `i` of the active cutscene. One undo step.

 @return "False for no such path or an empty name"
*>
fn bool AppState.rename_cut_path(&self, usz i, String name)
{
	Cutscene* c = self.cutscene();
	String trimmed = name.trim();
	if (!c || i >= c.paths.len || trimmed.len == 0) return false;
	if (c.paths[i].name == trimmed) return true;
	self.cut_checkpoint();
	WalkPath* path = &self.cutscene().paths[i];
	if (path.name.len > 0) alloc::free(mem, path.name.ptr);
	path.name = trimmed.copy(mem);
	self.cutscenes_changed();
	return true;
}

<*
 Delete path `i` of the active cutscene. A move that walked it has no path after,
 which the problems list names. One undo step.

 @return "False for no such path"
*>
fn bool AppState.delete_cut_path(&self, usz i)
{
	Cutscene* c = self.cutscene();
	if (!c || i >= c.paths.len) return false;
	self.cut_checkpoint();
	c = self.cutscene();
	c.paths[i].free(mem);
	for (usz k = i; k + 1 < c.paths.len; k++) c.paths[k] = c.paths[k + 1];
	c.paths = c.paths[:c.paths.len - 1];
	if (c.paths.len == 0)
	{
		alloc::free(mem, c.paths.ptr);
		c.paths = {};
	}
	foreach (&actor : c.actors)
	{
		foreach (&s : actor.strips)
		{
			if (s.kind != MOVE || s.path < 0) continue;
			if (s.path == (int)i)
			{
				s.path = -1;
			}
			else if (s.path > (int)i)
			{
				s.path--;
			}
		}
	}
	if (self.cut_path_pick == i + 1)
	{
		self.cut_path_pick = 0;
	}
	else if (self.cut_path_pick > i + 1)
	{
		self.cut_path_pick--;
	}
	self.cut_knot_pick = 0;
	self.cutscenes_changed();
	return true;
}

// ---------------------------------------------------------------------------
// Knots, each one undo step

// Path `path` after its knots changed: dropped again, and every move on it timed to it.
fn void AppState.cut_path_moved(&self, usz path)
{
	Cutscene* c = self.cutscene();
	if (!c || path >= c.paths.len) return;
	self.ground_cut_path(&c.paths[path]);
	foreach (usz a, &actor : c.actors)
	{
		foreach (&s : actor.strips)
		{
			if (s.kind == MOVE && s.path == (int)path) self.fit_walk_speed(a, s);
		}
	}
	self.cutscenes_changed();
}

fn bool AppState.cut_knot_exists(&self, usz path, usz knot)
{
	Cutscene* c = self.cutscene();
	return c && path < c.paths.len && knot < c.paths[path].knots.len;
}

// Path `path` with `at` put in its knots at `index`.
fn void AppState.put_cut_knot(&self, usz path, usz index, Vec3 at)
{
	WalkPath* p = &self.cutscene().paths[path];
	usz count = p.knots.len;
	Vec3[] grown = alloc::new_array(mem, Vec3, (sz)count + 1);
	usz write;
	for (usz k = 0; k <= count; k++)
	{
		if (k == index) grown[write++] = at;
		if (k < count) grown[write++] = p.knots[k];
	}
	if (count > 0) alloc::free(mem, p.knots);
	p.knots = grown;
	self.cut_path_pick = path + 1;
	self.cut_knot_pick = index + 1;
	self.cut_path_moved(path);
}

<*
 A knot at `at` on the end of path `path`, as a click while drawing puts one. One undo step.

 @return "False for no such path"
*>
fn bool AppState.add_cut_knot(&self, usz path, Vec3 at)
{
	Cutscene* c = self.cutscene();
	if (!c || path >= c.paths.len) return false;
	self.cut_checkpoint();
	self.put_cut_knot(path, self.cutscene().paths[path].knots.len, at);
	return true;
}

<*
 A knot at `at` put into path `path` where its curve passes nearest, picked. One undo step.

 @return "False for no such path, or one with under two knots"
*>
fn bool AppState.insert_cut_knot(&self, usz path, Vec3 at)
{
	Cutscene* c = self.cutscene();
	if (!c || path >= c.paths.len || c.paths[path].knots.len < 2) return false;
	usz span = walk_knot_span(c.paths[path].knots, at);
	self.cut_checkpoint();
	self.put_cut_knot(path, span + 1, at);
	return true;
}

<*
 Take knot `knot` out of path `path`; a path keeps two. One undo step.

 @return "False for no such knot, or with a notice for one of the last two"
*>
fn bool AppState.delete_cut_knot(&self, usz path, usz knot)
{
	if (!self.cut_knot_exists(path, knot)) return false;
	if (self.cutscene().paths[path].knots.len <= 2)
	{
		self.@notice("a path keeps two knots: delete the path instead");
		return false;
	}
	self.cut_checkpoint();
	WalkPath* p = &self.cutscene().paths[path];
	for (usz k = knot; k + 1 < p.knots.len; k++) p.knots[k] = p.knots[k + 1];
	p.knots = p.knots[:p.knots.len - 1];
	self.cut_knot_pick = 0;
	self.cut_path_moved(path);
	return true;
}

<* Begin dragging knot `knot` of path `path`: the cutscenes as they are now become its undo step, or are put back. *>
fn bool AppState.begin_cut_knot_drag(&self, usz path, usz knot)
{
	if (!self.cut_knot_exists(path, knot) || !self.begin_cut_gesture()) return false;
	self.cut_knot_dragging = true;
	self.cut_path_pick = path + 1;
	self.cut_knot_pick = knot + 1;
	return true;
}

<* During a knot drag, the knot is at `at`; the path drops onto the ground there at once. *>
fn bool AppState.drag_cut_knot(&self, Vec3 at)
{
	WalkPath* path = self.cut_picked_path();
	if (!self.cut_knot_dragging || !path || self.cut_knot_pick == 0 || self.cut_knot_pick > path.knots.len) return false;
	path.knots[self.cut_knot_pick - 1] = at;
	self.cut_path_moved(self.cut_path_pick - 1);
	return true;
}

<*
 Land the knot drag: one undo step when the knot moved.

 @return "Whether it was kept as a step"
*>
fn bool AppState.end_cut_knot_drag(&self)
{
	if (!self.cut_knot_dragging) return false;
	self.cut_knot_dragging = false;
	if (!self.cut_gesture_open) return false;
	CutSnapshot before = self.cut_gesture;
	self.cut_gesture = {};
	self.cut_gesture_open = false;
	WalkPath* now = self.cut_picked_path();
	bool changed = true;
	if (now && before.active < before.cutscenes.len && self.cut_path_pick <= before.cutscenes[before.active].paths.len)
	{
		WalkPath* was = &before.cutscenes[before.active].paths[self.cut_path_pick - 1];
		changed = was.knots.len != now.knots.len;
		foreach (usz k, knot : now.knots) changed = changed || (was.knots.len > k && (was.knots[k] - knot).length() > 0.0f);
	}
	if (!changed)
	{
		before.free();
		return false;
	}
	self.cut_record(before);
	return true;
}

<* Put the dragged knot back where it was, leaving no step. *>
fn void AppState.cancel_cut_knot_drag(&self)
{
	if (!self.cut_knot_dragging) return;
	self.cut_knot_dragging = false;
	usz path = self.cut_path_pick;
	usz knot = self.cut_knot_pick;
	self.cancel_cut_gesture();
	self.cut_path_pick = path;
	self.cut_knot_pick = knot;
	self.check_cut_path_pick();
}

<*
 Draw the picked path knot by knot: each click on the ground adds one (an undo
 step each); Esc, Enter or a right click ends it. A new path is added when none
 is picked.

 @return "False without a cutscene"
*>
fn bool AppState.begin_cut_path_drawing(&self)
{
	if (!self.cutscene()) return false;
	if (!self.cut_picked_path()) (void)self.add_cut_path();
	return self.begin_cut_pick(PATH_KNOT);
}

// ---------------------------------------------------------------------------
// Ground speed

<*
 How the character's clip `clip` walks, measured on its rig in model units a
 second: a clip that still travels by its hips' travel, one made in place by the
 travel it kept, else by the treadmill its planted feet run on.
*>
fn CutClipGround AppState.measure_clip_ground(&self, String clip)
{
	AnimRef ref;
	AnimTemplate* found = self.bound_clip_named(clip, &ref);
	if (!found) return {};
	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);
	String[] names = self.names_for(&view, ref);
	float height = view.skeleton.height();
	if (!(height > 0.0f)) return {};
	AnimTravel still = clip_travel(&view.skeleton, names, *found);
	if (still.distance > CUT_CLIP_TRAVELS) return { .speed = still.speed * height, .travels = true };
	if (found.travel.known()) return { .speed = found.travel.speed * height };
	bool owned;
	AnimGround contacts = clip_contacts(&view, names, found, &owned);
	defer if (owned) contacts.free(mem);
	ClipMetrics numbers = clip_metrics(mem, &view.skeleton, names, *found, CUT_SPEED_SAMPLES, null, {}, owned ? contacts : (AnimGround){});
	defer numbers.free(mem);
	float speed = numbers.ground_velocity.length();
	return { .speed = speed > height * 0.01f ? speed : 0.0f };
}

<* How character `character`'s clip `clip` walks as it is drawn in the scene, in m/s; measured once per edit of the character. *>
fn CutClipGround AppState.cut_clip_ground(&self, usz character, String clip)
{
	if (character >= self.character_count() || clip.len == 0) return {};
	Character* c = self.character(character);
	uint id = c.id;
	uint revision = c.undo_stack.revision;
	float scale = c.stage_scale > 0.0f ? c.stage_scale : 1.0f;
	if (!self.cut_measures.is_initialized()) self.cut_measures.init(mem);
	sz at = -1;
	foreach (usz i, &m : self.cut_measures)
	{
		if (m.character == id && m.clip == clip) at = (sz)i;
	}
	// Measuring stands in as the character, which must not happen under a gesture or a one-off edit.
	if (at >= 0 && (self.cut_measures[at].revision == revision || !self.cut_may_measure()))
	{
		CutClipGround kept = self.cut_measures[at].ground;
		kept.speed *= scale;
		return kept;
	}
	if (!self.cut_may_measure()) return {};
	CutClipGround ground;
	self.@as_character(character)
	{
		ground = self.measure_clip_ground(clip);
	};
	if (at >= 0)
	{
		self.cut_measures.get_ref(at).ground = ground;
		self.cut_measures.get_ref(at).revision = revision;
	}
	else
	{
		self.cut_measures.push({ .character = id, .revision = revision, .clip = clip.copy(mem), .ground = ground });
	}
	ground.speed *= scale;
	return ground;
}

<* Whether a clip may be measured now: no pose gesture or transform in flight, and no one-off being edited. *>
fn bool AppState.cut_may_measure(&self)
{
	return !self.one_off.open && self.drag.dot == 0 && !self.transform_transaction.active && !self.stroke_open;
}

<* The ground speed move `s` of actor `actor` walks at, in m/s: the one typed on it, else its clip's; 0 when not known. *>
fn float AppState.cut_ground_speed(&self, usz actor, CutStrip* s)
{
	if (s.ground_speed > 0.0f) return s.ground_speed;
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len || s.clip.len == 0) return 0.0f;
	sz holder = self.actor_character(c.actors[actor].row);
	if (holder < 0) return 0.0f;
	return self.cut_clip_ground((usz)holder, s.clip).speed;
}

<*
 Move `s` of actor `actor` plays its clip at the rate that keeps the feet on the
 ground: (path length ÷ strip length) ÷ ground speed. Left as it is when the
 ground speed is not known.
*>
fn void AppState.fit_walk_speed(&self, usz actor, CutStrip* s)
{
	Cutscene* c = self.cutscene();
	if (!c || s.kind != MOVE || s.clip.len == 0 || s.path < 0 || s.path >= c.paths.len) return;
	float ground = self.cut_ground_speed(actor, s);
	if (!(ground > 0.0f) || !(s.end > s.start)) return;
	s.speed = cut_walk_rate(c.paths[s.path].length, s.end - s.start, ground);
}

<*
 Walk here: a move along path `path` for `actor` at the playhead, turning along it,
 playing the actor's clip named like a walk if it has one, and lasting the path's
 length over that clip's ground speed (1 m/s when that is not known). One undo step.

 @return "Its index, or -1 for no such actor or a path with nothing to walk"
*>
fn sz AppState.walk_cut_path(&self, usz actor, usz path)
{
	(void)self.back_to_cutscene();
	Cutscene* c = self.cutscene();
	if (!c || actor >= c.actors.len || path >= c.paths.len || c.paths[path].points.len < 2) return -1;
	CutStrip s = cut_strip(MOVE, self.cut_time, self.cut_time);
	s.path = (int)path;
	s.ease = LINEAR;
	@pool()
	{
		CutCast[] cast = self.cut_cast(c, tmem);
		sz walk = cut_walk_clip(cast[actor].clips);
		if (walk >= 0) s.clip = cast[actor].clips[walk].copy(mem);
	};
	float ground = self.cut_ground_speed(actor, &s);
	float frame = c.fps > 0.0f ? 1.0f / c.fps : 0.01f;
	s.end = s.start + math::max(cut_walk_seconds(c.paths[path].length, ground), frame);
	s.speed = cut_walk_rate(c.paths[path].length, s.end - s.start, ground);
	return self.add_cut_strip(actor, s);
}

// ---------------------------------------------------------------------------
// What the walks pass through

<* How wide and tall character `character` is drawn: a capsule's radius and height, in metres. *>
fn bool AppState.actor_capsule(&self, usz character, float* radius, float* height)
{
	if (character >= self.character_count()) return false;
	Character* c = self.character(character);
	if (c.geometry.positions.len == 0 && !c.level_read) return false;
	rig::Bounds box = c.level_read ? c.stage_bounds : c.geometry.bounds();
	float scale = c.drawn_scale();
	Vec3 size = (box.max - box.min) * scale;
	*height = size.y;
	*radius = math::clamp(math::min(size.x, size.z) * 0.5f, CUT_WALK_RADIUS_LEAST, CUT_WALK_RADIUS_MOST);
	return *height > CUT_WALK_STEP + 2.0f * *radius;
}

// What the capsule check depends on, so a cutscene unchanged is not checked again.
fn uint AppState.walk_blocks_key(&self, Cutscene* cutscene)
{
	uint key = 2166136261u;
	key = (key ^ (level_shown() ? 1u : 2u)) * 16777619u;
	foreach (usz a, &actor : cutscene.actors)
	{
		sz holder = self.actor_character(actor.row);
		float radius;
		float height;
		if (holder < 0 || !self.actor_capsule((usz)holder, &radius, &height)) continue;
		key = (key ^ bitcast(radius, uint)) * 16777619u;
		key = (key ^ bitcast(height, uint)) * 16777619u;
		foreach (usz k, &s : actor.strips)
		{
			if (s.kind != MOVE || s.path < 0 || s.path >= cutscene.paths.len) continue;
			key = (key ^ (uint)(a * 7919 + k)) * 16777619u;
			foreach (p : cutscene.paths[s.path].points)
			{
				key = (key ^ bitcast(p.x, uint)) * 16777619u;
				key = (key ^ bitcast(p.y, uint)) * 16777619u;
				key = (key ^ bitcast(p.z, uint)) * 16777619u;
			}
		}
	}
	return key;
}

<*
 The colliders the active cutscene's walks pass through, at each actor's own width
 and height; the first one per move. Measured again only when a walk or the level changed.
*>
fn CutWalkBlock[] AppState.cut_walk_blocks(&self)
{
	Cutscene* cutscene = self.cutscene();
	if (!cutscene || !level_shown()) return {};
	uint key = self.walk_blocks_key(cutscene);
	if (self.cut_blocks.is_initialized() && key == self.cut_blocks_key) return self.cut_blocks.array_view();
	foreach (&b : self.cut_blocks) if (b.collider.len > 0) alloc::free(mem, b.collider.ptr);
	if (!self.cut_blocks.is_initialized()) self.cut_blocks.init(mem);
	self.cut_blocks.clear();
	self.cut_blocks_key = key;
	foreach (usz a, &actor : cutscene.actors)
	{
		sz holder = self.actor_character(actor.row);
		float radius;
		float height;
		if (holder < 0 || !self.actor_capsule((usz)holder, &radius, &height)) continue;
		foreach (usz k, &s : actor.strips)
		{
			if (s.kind != MOVE || s.path < 0 || s.path >= cutscene.paths.len) continue;
			Vec3[] points = cutscene.paths[s.path].points;
			for (usz i = 0; i + 1 < points.len; i++)
			{
				GroundHit hit = level_capsule_hit(points[i], points[i + 1], radius, height, CUT_WALK_STEP);
				if (!hit.hit) continue;
				String name = level_node_name(hit.node);
				self.cut_blocks.push({ .actor = a, .strip = k, .collider = name.len > 0 ? name.copy(mem) : "", .at = hit.point });
				break;
			}
		}
	}
	return self.cut_blocks.array_view();
}

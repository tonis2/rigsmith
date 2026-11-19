<* A cutscene as Rigsmith edits it: its actors, what each does when, and the paths they walk. *>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;

const float CUT_DEFAULT_FADE = 0.2f;
const float CUT_DEFAULT_FPS = 30.0f;

enum CutStripKind : char
{
	MOVE, // walks a path, maybe playing a clip of its own
	TURN, // turns on the spot to face a point or another actor
	PLAY, // plays a clip where the actor stands
}

// How a move covers its path, or a turn its angle, over the strip: u, u², 1-(1-u)², u²(3-2u).
enum CutEase : char
{
	LINEAR,
	IN,
	OUT,
	INOUT,
}

<* One strip on an actor's timeline; its strings are owned by the cutscene's allocator. *>
struct CutStrip
{
	CutStripKind kind;
	float start; // seconds; may be before the cutscene starts
	float end;
	// The clip a move or a play strip plays; empty plays none. A turn has none.
	String clip;
	bool loop;
	float speed;
	float fade;      // seconds to cross-fade in from what played before
	float offset;    // clip time the strip starts at
	// The clip is one of this cutscene's one-offs for the actor, not one of its character's.
	bool one_off;
	int animation;   // index of a one-off clip in the cutscene file, or -1
	// A move's path, by index into `Cutscene.paths`.
	int path;
	CutEase ease;    // a move's or a turn's
	bool turn;       // a move faces along its path
	// The typed ground speed in m/s of the clip it plays (a paired play's, or a move's own clip's); scene file only, 0 takes the clip's.
	float ground_speed;
	// A play's speed as typed: pairing with a move leaves it alone. Scene file only.
	bool speed_held;
	// What a turn faces: the actor whose row is `target_row`, else `target`.
	Vec3 target;
	String target_row;
	// The editor's handle on it, for the selection: never saved, 0 until the app numbers it.
	uint id;
}

<* A strip of `kind` with the defaults the format gives absent keys. *>
fn CutStrip cut_strip(CutStripKind kind, float start, float end)
{
	return {
		.kind = kind,
		.start = start,
		.end = end,
		.loop = kind == MOVE,
		.speed = 1.0f,
		.fade = CUT_DEFAULT_FADE,
		.animation = -1,
		.path = -1,
		.ease = INOUT,
		.turn = true,
	};
}

fn void CutStrip.free(&self, Allocator allocator)
{
	if (self.clip.len > 0) alloc::free(allocator, self.clip.ptr);
	if (self.target_row.len > 0) alloc::free(allocator, self.target_row.ptr);
	*self = {};
}

fn CutStrip CutStrip.copy(&self, Allocator allocator)
{
	CutStrip out = *self;
	out.clip = self.clip.len > 0 ? self.clip.copy(allocator) : "";
	out.target_row = self.target_row.len > 0 ? self.target_row.copy(allocator) : "";
	return out;
}

<* Whether two strips say the same thing, their ids aside. *>
fn bool CutStrip.same_as(&self, CutStrip* other)
{
	return self.kind == other.kind && self.start == other.start && self.end == other.end && self.clip == other.clip
		&& self.loop == other.loop && self.speed == other.speed && self.fade == other.fade && self.offset == other.offset
		&& self.one_off == other.one_off && self.animation == other.animation && self.path == other.path && self.ease == other.ease && self.turn == other.turn
		&& self.ground_speed == other.ground_speed && self.speed_held == other.speed_held && self.target.x == other.target.x && self.target.y == other.target.y && self.target.z == other.target.z
		&& self.target_row == other.target_row;
}

<* One actor, found by the game by `row`; `home` is the level node's place, or the one the export writes. *>
struct CutActor
{
	String row;
	String uid; // the object's glTF uid, or empty
	Vec3 home;
	Quaternionf home_rotation;
	bool no_level_node;
	CutStrip[] strips; // any order; the export sorts them by start
}

fn void CutActor.free(&self, Allocator allocator)
{
	if (self.row.len > 0) alloc::free(allocator, self.row.ptr);
	if (self.uid.len > 0) alloc::free(allocator, self.uid.ptr);
	foreach (&strip : self.strips) strip.free(allocator);
	if (self.strips.len > 0) alloc::free(allocator, self.strips);
	*self = {};
}

fn CutActor CutActor.copy(&self, Allocator allocator)
{
	CutActor out = *self;
	out.row = self.row.len > 0 ? self.row.copy(allocator) : "";
	out.uid = self.uid.len > 0 ? self.uid.copy(allocator) : "";
	out.strips = {};
	if (self.strips.len > 0)
	{
		out.strips = alloc::new_array(allocator, CutStrip, (sz)self.strips.len);
		foreach (usz i, &strip : self.strips) out.strips[i] = strip.copy(allocator);
	}
	return out;
}

<* A walk path: `knots` placed by hand stay in the scene file, `points` are the even samples a move follows. *>
struct WalkPath
{
	String name;
	Vec3[] knots;
	Vec3[] points;
	float length; // metres along the curve
}

fn void WalkPath.free(&self, Allocator allocator)
{
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	if (self.knots.len > 0) alloc::free(allocator, self.knots);
	if (self.points.len > 0) alloc::free(allocator, self.points);
	*self = {};
}

fn WalkPath WalkPath.copy(&self, Allocator allocator)
{
	WalkPath out = *self;
	out.name = self.name.len > 0 ? self.name.copy(allocator) : "";
	out.knots = self.knots.len > 0 ? alloc::clone_slice(allocator, self.knots) : {};
	out.points = self.points.len > 0 ? alloc::clone_slice(allocator, self.points) : {};
	return out;
}

<* Acting made for one cutscene alone: a clip of one actor, kept in the scene file and written into the cutscene file. *>
struct CutOneOff
{
	String row;        // the actor it plays on; owned
	AnimTemplate clip; // owned; its name is the clip name strips play it as
}

fn void CutOneOff.free(&self, Allocator allocator)
{
	if (self.row.len > 0) alloc::free(allocator, self.row.ptr);
	self.clip.free(allocator);
	*self = {};
}

fn CutOneOff CutOneOff.copy(&self, Allocator allocator)
{
	return { .row = self.row.len > 0 ? self.row.copy(allocator) : "", .clip = clip_copy(allocator, self.clip) };
}

<* One cutscene, everything in it owned by the allocator given to `free` and `copy`. *>
struct Cutscene
{
	String name;
	float duration; // seconds
	float fps;      // the authoring frame rate, for tools
	CutActor[] actors;
	WalkPath[] paths;
	CutOneOff[] one_offs;
}

fn void Cutscene.free(&self, Allocator allocator)
{
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	foreach (&actor : self.actors) actor.free(allocator);
	if (self.actors.len > 0) alloc::free(allocator, self.actors);
	foreach (&path : self.paths) path.free(allocator);
	if (self.paths.len > 0) alloc::free(allocator, self.paths);
	foreach (&one : self.one_offs) one.free(allocator);
	if (self.one_offs.len > 0) alloc::free(allocator, self.one_offs);
	*self = {};
}

<* A deep copy, as an undo snapshot takes one. *>
fn Cutscene Cutscene.copy(&self, Allocator allocator)
{
	Cutscene out = *self;
	out.name = self.name.len > 0 ? self.name.copy(allocator) : "";
	out.actors = {};
	out.paths = {};
	out.one_offs = {};
	if (self.actors.len > 0)
	{
		out.actors = alloc::new_array(allocator, CutActor, (sz)self.actors.len);
		foreach (usz i, &actor : self.actors) out.actors[i] = actor.copy(allocator);
	}
	if (self.paths.len > 0)
	{
		out.paths = alloc::new_array(allocator, WalkPath, (sz)self.paths.len);
		foreach (usz i, &path : self.paths) out.paths[i] = path.copy(allocator);
	}
	if (self.one_offs.len > 0)
	{
		out.one_offs = alloc::new_array(allocator, CutOneOff, (sz)self.one_offs.len);
		foreach (usz i, &one : self.one_offs) out.one_offs[i] = one.copy(allocator);
	}
	return out;
}

<* The one-off of actor `row` called `name`, or -1. *>
fn sz Cutscene.one_off_index(&self, String row, String name)
{
	foreach (usz i, &one : self.one_offs)
	{
		if (one.row == row && one.clip.name == name) return (sz)i;
	}
	return -1;
}

<* The one-off strip `s` of actor `actor` plays, or null for a strip that plays none or one that is gone. *>
fn CutOneOff* Cutscene.one_off_of(&self, usz actor, CutStrip* s)
{
	if (!s.one_off || actor >= self.actors.len) return null;
	sz at = self.one_off_index(self.actors[actor].row, s.clip);
	return at < 0 ? null : &self.one_offs[at];
}

<* How many strips of the actor whose row is `row` play its one-off `name`. *>
fn usz Cutscene.one_off_uses(&self, String row, String name)
{
	int actor = self.actor_by_row(row);
	if (actor < 0) return 0;
	usz count;
	foreach (&s : self.actors[actor].strips) if (s.one_off && s.clip == name) count++;
	return count;
}

<* Which part of a bone a one-off channel animates, as glTF names the paths. *>
enum CutChannelPath : char
{
	TRANSLATION,
	ROTATION,
	SCALE,
}

<* One baked channel of a one-off as the cutscene file holds it: absolute local values of one bone over time. *>
struct CutChannel
{
	String bone;    // owned
	CutChannelPath path;
	float[] times;  // owned, seconds from the clip's start
	float[] values; // owned; three a key, four (x, y, z, w) for a rotation
}

fn usz CutChannel.width(&self) => self.path == ROTATION ? 4 : 3;

fn void CutChannel.free(&self, Allocator allocator)
{
	if (self.bone.len > 0) alloc::free(allocator, self.bone.ptr);
	if (self.times.len > 0) alloc::free(allocator, self.times);
	if (self.values.len > 0) alloc::free(allocator, self.values);
	*self = {};
}

<* A one-off as written into the cutscene file: its name, the actor whose stub its channels hang under, and the channels. *>
struct CutAnimation
{
	String name; // owned
	usz actor;
	CutChannel[] channels; // owned
}

fn void CutAnimation.free(&self, Allocator allocator)
{
	if (self.name.len > 0) alloc::free(allocator, self.name.ptr);
	foreach (&c : self.channels) c.free(allocator);
	if (self.channels.len > 0) alloc::free(allocator, self.channels);
	*self = {};
}

fn void free_cut_animations(Allocator allocator, CutAnimation[] animations)
{
	foreach (&a : animations) a.free(allocator);
	if (animations.len > 0) alloc::free(allocator, animations);
}

<* How an actor is tied to the scene: the character with its row, or -1, and the level node it stands in for. *>
struct CutActorLink
{
	int character;
	String level_node; // borrowed
}

<* The index of the actor whose row is `row`, or -1. *>
fn int Cutscene.actor_by_row(&self, String row)
{
	foreach (usz i, &actor : self.actors)
	{
		if (actor.row == row) return (int)i;
	}
	return -1;
}

<* Where the strip whose id is `id` is: its actor, and its index there. *>
fn bool Cutscene.find_strip(&self, uint id, usz* actor, usz* strip)
{
	if (id == 0) return false;
	foreach (usz a, &who : self.actors)
	{
		foreach (usz k, &s : who.strips)
		{
			if (s.id != id) continue;
			*actor = a;
			*strip = k;
			return true;
		}
	}
	return false;
}

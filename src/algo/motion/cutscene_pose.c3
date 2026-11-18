<* A cutscene posed at one instant by three.c3's own rules (cutscene.js), so the preview is what the game shows. *>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::collections::list;

alias CutVec = double[<3>];
alias CutQuat = double[<4>]; // x, y, z, w

// Seconds before its end a held loop is posed at, as the player poses it.
const double CUT_HOLD_BEFORE = 1e-3;
// Arc-length samples per curve segment, as the player measures its curves.
const usz CUT_CURVE_DIVISIONS @local = 32;
// The longest step of the dense polyline a walk path is sampled from.
const double WALK_DENSE_STEP @local = 0.01;
const float WALK_PATH_SPACING = 0.25f;

<* three.c3's open centripetal `CatmullRomCurve3` with its arc-length table, in doubles so the numbers match. *>
struct CutCurve
{
	CutVec[] points;
	double[] lengths; // distance along the curve at each of `steps + 1` samples
	usz steps;
	double total;
}

<*
 The curve through `points`, measured.

 @param [in] points : "Two or more; fewer give an empty curve"
 @return "The caller owns it; see CutCurve.free"
*>
fn CutCurve cut_curve(Allocator allocator, Vec3[] points)
{
	if (points.len < 2) return {};
	CutCurve curve;
	curve.points = alloc::new_array(allocator, CutVec, (sz)points.len);
	foreach (i, p : points) curve.points[i] = { p.x, p.y, p.z };
	curve.steps = (points.len - 1) * CUT_CURVE_DIVISIONS;
	curve.lengths = alloc::new_array(allocator, double, (sz)curve.steps + 1);
	CutVec previous = curve.point(0.0);
	for (usz i = 1; i <= curve.steps; i++)
	{
		CutVec point = curve.point((double)i / (double)curve.steps);
		curve.total += (point - previous).length();
		curve.lengths[i] = curve.total;
		previous = point;
	}
	return curve;
}

fn void CutCurve.free(&self, Allocator allocator)
{
	if (self.points.len > 0) alloc::free(allocator, self.points);
	if (self.lengths.len > 0) alloc::free(allocator, self.lengths);
	*self = {};
}

fn bool CutCurve.is_empty(&self) => self.points.len < 2;

<*
 The point at curve parameter `t`, spread evenly over the segments, not the length.

 @require !self.is_empty() : "An empty curve has no points"
*>
fn CutVec CutCurve.point(&self, double t)
{
	usz segments = self.points.len - 1;
	double scaled = math::clamp(t, 0.0, 1.0) * (double)segments;
	usz index = math::min((usz)math::floor(scaled), segments - 1);
	return self.segment(index, scaled - (double)index);
}

<*
 The point `u` of the way along the curve by distance.

 @require !self.is_empty() : "An empty curve has no points"
*>
fn CutVec CutCurve.point_at(&self, double u)
{
	double want = math::clamp(u, 0.0, 1.0) * self.total;
	if (!(self.total > 0.0)) return self.point(0.0);
	usz low = 0;
	usz high = self.steps;
	while (low < high)
	{
		usz mid = (low + high) >> 1;
		if (self.lengths[mid] < want)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}
	usz index = math::max((usz)1, low);
	double before = self.lengths[index - 1];
	double after = self.lengths[index];
	double inner = after - before < 1e-12 ? 0.0 : (want - before) / (after - before);
	return self.point(((double)(index - 1) + inner) / (double)self.steps);
}

// A control point, the end ones repeated so an end segment has a neighbour.
fn CutVec CutCurve.control(&self, sz i)
{
	sz last = (sz)self.points.len - 1;
	return self.points[i < 0 ? 0 : (i > last ? last : i)];
}

// One segment by the Barry-Goldman pyramid, its knots spaced by the square root of the chord.
fn CutVec CutCurve.segment(&self, usz index, double local)
{
	CutVec p0 = self.control((sz)index - 1);
	CutVec p1 = self.control((sz)index);
	CutVec p2 = self.control((sz)index + 1);
	CutVec p3 = self.control((sz)index + 2);
	double t0 = 0.0;
	double t1 = t0 + math::max(1e-6, cut_span(p0, p1));
	double t2 = t1 + math::max(1e-6, cut_span(p1, p2));
	double t3 = t2 + math::max(1e-6, cut_span(p2, p3));
	double at = t1 + (t2 - t1) * local;
	CutVec a1 = cut_blend(p0, p1, t0, t1, at);
	CutVec a2 = cut_blend(p1, p2, t1, t2, at);
	CutVec a3 = cut_blend(p2, p3, t2, t3, at);
	CutVec b1 = cut_blend(a1, a2, t0, t2, at);
	CutVec b2 = cut_blend(a2, a3, t1, t3, at);
	return cut_blend(b1, b2, t1, t2, at);
}

fn double cut_span(CutVec a, CutVec b) @local => math::pow((b - a).length(), 0.5);

fn CutVec cut_blend(CutVec u, CutVec v, double tu, double tv, double at) @local
{
	if (tv - tu < 1e-12) return u;
	return (u * (tv - at) + v * (at - tu)) / (tv - tu);
}

fn double cut_ease(CutEase ease, double u)
{
	switch (ease)
	{
		case LINEAR: return u;
		case IN: return u * u;
		case OUT: return 1.0 - (1.0 - u) * (1.0 - u);
		case INOUT: return u * u * (3.0 - 2.0 * u);
	}
}

<* The heading about +Y the player reads off a rotation (YZX decomposition): 0 faces +Z, π/2 faces +X. *>
fn double cut_heading_of(Quaternionf rotation)
{
	double x = rotation.v.x;
	double y = rotation.v.y;
	double z = rotation.v.z;
	double w = rotation.v.w;
	return math::atan2(2.0 * (w * y - x * z), 1.0 - 2.0 * (y * y + z * z));
}

<* One actor at one instant. *>
struct CutActorPose
{
	Vec3 position;
	Quaternionf rotation;
	int strip;       // the strip whose clip plays, by index into the actor's strips, or -1
	float clip_time; // seconds into that clip, before a loop wraps it
	bool holding;    // a play strip past its end, held on the frame it ended on
	float fade;      // the playing strip's cross-fade in
}

<*
 One curve per path of `cutscene`, empty where a path has under two points.

 @param [in] cutscene
 @return "The caller owns them; see free_cut_curves"
*>
fn CutCurve[] cutscene_curves(Allocator allocator, Cutscene* cutscene)
{
	if (cutscene.paths.len == 0) return {};
	CutCurve[] curves = alloc::new_array(allocator, CutCurve, (sz)cutscene.paths.len);
	foreach (i, &path : cutscene.paths) curves[i] = cut_curve(allocator, path.points);
	return curves;
}

fn void free_cut_curves(Allocator allocator, CutCurve[] curves)
{
	foreach (&curve : curves) curve.free(allocator);
	if (curves.len > 0) alloc::free(allocator, curves);
}

<*
 Every actor's pose at `t` seconds, in actor order.

 @param [in] cutscene
 @return "The caller owns the array"
*>
fn CutActorPose[] cutscene_pose_at(Allocator allocator, Cutscene* cutscene, float t)
{
	if (cutscene.actors.len == 0) return {};
	CutActorPose[] out = alloc::new_array(allocator, CutActorPose, (sz)cutscene.actors.len);
	@pool()
	{
		CutCurve[] curves = cutscene_curves(tmem, cutscene);
		foreach (usz i, &pose : out) *pose = cutscene_actor_pose(cutscene, curves, i, t);
	};
	return out;
}

<*
 Where one actor stands, faces and plays at `t`, its strips taken as stably sorted by start as the player sorts them.

 @param [in] cutscene
 @param [in] curves : "From cutscene_curves"
 @require actor < cutscene.actors.len : "No such actor"
 @require curves.len == cutscene.paths.len : "One curve per path"
*>
fn CutActorPose cutscene_actor_pose(Cutscene* cutscene, CutCurve[] curves, usz actor, float t)
{
	CutActor* who = &cutscene.actors[actor];
	double at = (double)t;
	CutVec position = cut_position(who, curves, at, -1);
	CutActorPose pose = {
		.position = { (float)position.x, (float)position.y, (float)position.z },
		.rotation = who.home_rotation,
		.strip = -1,
	};
	double heading;
	if (cut_heading(cutscene, curves, actor, at, -1, &heading))
	{
		pose.rotation = cut_turned(who.home_rotation, heading);
	}

	// What it plays: the latest strip begun that has a clip, and for a move has not ended.
	CutStrip[] strips = who.strips;
	sz active = -1;
	foreach (usz j, &s : strips)
	{
		if (s.start > at || s.clip.len == 0 || s.kind == TURN) continue;
		if (s.kind == MOVE && at > s.end) continue;
		if (active < 0 || s.start >= strips[active].start) active = (sz)j;
	}
	if (active < 0) return pose;
	CutStrip* s = &strips[active];
	// A play strip holds the pose it ends on: a hair before its end for a loop, so
	// one that ends on a whole cycle keeps the cycle's last frame.
	bool holding = s.kind == PLAY && at >= s.end;
	double local = (double)s.offset + ((holding ? (double)s.end : at) - (double)s.start) * (double)s.speed;
	if (holding && s.loop && local > CUT_HOLD_BEFORE) local -= CUT_HOLD_BEFORE;
	pose.strip = (int)active;
	pose.clip_time = (float)local;
	pose.holding = holding;
	pose.fade = s.fade;
	return pose;
}

// Whether strip `a` comes before strip `b` once sorted by start, ties kept in order.
fn bool cut_before(CutStrip[] strips, usz a, usz b) @local
{
	return strips[a].start < strips[b].start || (strips[a].start == strips[b].start && a < b);
}

// Only a move with a path to follow moves anything; the export refuses the others.
fn bool cut_follows(CutStrip* s, CutCurve[] curves) @local
{
	return s.kind == MOVE && s.path >= 0 && s.path < curves.len && !curves[s.path].is_empty();
}

fn double cut_move_u(CutStrip* s, double t) @local
{
	double span = (double)s.end - (double)s.start;
	return cut_ease(s.ease, math::clamp((t - (double)s.start) / span, 0.0, 1.0));
}

// Where an actor stands at `t` by its strips before `limit` (all when -1): inside
// the latest move begun, or where that move ended, else at home.
fn CutVec cut_position(CutActor* actor, CutCurve[] curves, double t, sz limit) @local
{
	CutStrip[] strips = actor.strips;
	sz move = -1;
	foreach (usz j, &s : strips)
	{
		if (!cut_follows(s, curves) || s.start > t) continue;
		if (limit >= 0 && !cut_before(strips, j, (usz)limit)) continue;
		if (move < 0 || s.start >= strips[move].start) move = (sz)j;
	}
	if (move < 0) return { actor.home.x, actor.home.y, actor.home.z };
	CutStrip* s = &strips[move];
	return curves[s.path].point_at(cut_move_u(s, t));
}

// The heading at `t` by the strips before `limit` (all when -1), or false for the
// home rotation as it is. A turn starts from the heading the strips before it give.
fn bool cut_heading(Cutscene* cutscene, CutCurve[] curves, usz actor, double t, sz limit, double* heading) @local
{
	CutActor* who = &cutscene.actors[actor];
	CutStrip[] strips = who.strips;
	sz at = -1;
	foreach (usz j, &s : strips)
	{
		if (s.start > t) continue;
		if (s.kind != TURN && !(s.turn && cut_follows(s, curves))) continue;
		if (limit >= 0 && !cut_before(strips, j, (usz)limit)) continue;
		if (at < 0 || s.start >= strips[at].start) at = (sz)j;
	}
	if (at < 0) return false;
	CutStrip* s = &strips[at];
	if (s.kind == MOVE)
	{
		CutCurve* curve = &curves[s.path];
		double u = cut_move_u(s, t);
		CutVec a = curve.point_at(math::max(0.0, u - 1e-3));
		CutVec b = curve.point_at(math::min(1.0, u + 1e-3));
		if (cut_flat_distance(a, b) > 1e-6)
		{
			*heading = math::atan2(b.x - a.x, b.z - a.z);
			return true;
		}
		return cut_heading(cutscene, curves, actor, t, at, heading);
	}

	double from;
	if (!cut_heading(cutscene, curves, actor, (double)s.start, at, &from)) from = cut_heading_of(who.home_rotation);
	*heading = from;
	CutVec pos = cut_position(who, curves, (double)s.start, limit);
	CutVec target = { s.target.x, s.target.y, s.target.z };
	if (s.target_row.len > 0)
	{
		int other = cutscene.actor_by_row(s.target_row);
		if (other < 0) return true;
		target = cut_position(&cutscene.actors[other], curves, (double)s.start, -1);
	}
	if (cut_flat_distance(pos, target) <= 1e-6) return true;
	double span = (double)s.end - (double)s.start;
	double u = cut_ease(s.ease, math::clamp((t - (double)s.start) / span, 0.0, 1.0));
	*heading = from + cut_shortest(from, math::atan2(target.x - pos.x, target.z - pos.z)) * u;
	return true;
}

fn double cut_flat_distance(CutVec a, CutVec b) @local
{
	double dx = b.x - a.x;
	double dz = b.z - a.z;
	return math::sqrt(dx * dx + dz * dz);
}

// The signed turn from `from` to `to` the short way round, in (-π, π].
fn double cut_shortest(double from, double to) @local
{
	double d = (to - from) % (2.0 * math::PI);
	if (d > math::PI)
	{
		d -= 2.0 * math::PI;
	}
	else if (d <= -math::PI)
	{
		d += 2.0 * math::PI;
	}
	return d;
}

fn CutQuat cut_yaw(double yaw) @local => { 0.0, math::sin(yaw / 2.0), 0.0, math::cos(yaw / 2.0) };

fn CutQuat cut_quat_mul(CutQuat a, CutQuat b) @local
{
	return {
		a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
		a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
		a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
		a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
	};
}

// The home rotation turned to `heading`, keeping the lean it stands with.
fn Quaternionf cut_turned(Quaternionf home, double heading) @local
{
	CutQuat q = { home.v.x, home.v.y, home.v.z, home.v.w };
	CutQuat lean = cut_quat_mul(cut_yaw(-cut_heading_of(home)), q);
	CutQuat turned = cut_quat_mul(cut_yaw(heading), lean);
	return { .v = { (float)turned.x, (float)turned.y, (float)turned.z, (float)turned.w } };
}

<* Even samples along a walk path. *>
struct WalkSamples
{
	Vec3[] points;
	float length;
}

<*
 The player's kind of curve through `knots`, sampled every `spacing` or a little less as the addon samples a path,
 and dropped onto `ground` when one is given (see ground_walk_samples).

 @param [in] knots
 @require spacing > 0.0f : "Spacing must be positive"

 @return "Points owned by the caller, the end knots exact; under two distinct knots, those and no length"
*>
fn WalkSamples sample_walk_path(Allocator allocator, Vec3[] knots, float spacing = WALK_PATH_SPACING, WalkGround ground = {})
{
	WalkSamples curve = sample_walk_curve(allocator, knots, spacing);
	if (!ground.active() || curve.points.len < 2) return curve;
	defer alloc::free(allocator, curve.points);
	return ground_walk_samples(allocator, curve.points, ground, spacing);
}

fn WalkSamples sample_walk_curve(Allocator allocator, Vec3[] knots, float spacing) @local
{
	// Repeated knots would be zero-length segments.
	List{Vec3} distinct;
	distinct.init(mem);
	defer distinct.free();
	foreach (knot : knots)
	{
		if (distinct.len() == 0 || (knot - distinct[distinct.len() - 1]).length() > 1e-9f) distinct.push(knot);
	}
	if (distinct.len() == 0) return {};
	Vec3[] kept = distinct.array_view();
	if (kept.len < 2) return { .points = alloc::clone_slice(allocator, kept) };
	CutCurve curve = cut_curve(mem, kept);
	defer curve.free(mem);

	// A dense polyline on the curve, and the distance along it at each point.
	List{CutVec} dense;
	dense.init(mem);
	defer dense.free();
	List{double} along;
	along.init(mem);
	defer along.free();
	dense.push(curve.points[0]);
	along.push(0.0);
	for (usz i = 0; i + 1 < curve.points.len; i++)
	{
		double chord = (curve.points[i + 1] - curve.points[i]).length();
		usz steps = math::max(CUT_CURVE_DIVISIONS, (usz)math::ceil(chord / WALK_DENSE_STEP));
		for (usz k = 1; k <= steps; k++)
		{
			CutVec point = k == steps ? curve.points[i + 1] : curve.segment(i, (double)k / (double)steps);
			along.push(along[along.len() - 1] + (point - dense[dense.len() - 1]).length());
			dense.push(point);
		}
	}

	double total = along[along.len() - 1];
	usz count = math::max((usz)2, (usz)math::ceil(total / (double)spacing) + 1);
	Vec3[] points = alloc::new_array(allocator, Vec3, (sz)count);
	sz j = 0;
	for (usz k = 0; k < count; k++)
	{
		double want = total * (double)k / (double)(count - 1);
		while (j + 2 < along.len() && along[j + 1] < want) j++;
		double span = along[j + 1] - along[j];
		double f = span > 1e-12 ? math::clamp((want - along[j]) / span, 0.0, 1.0) : 0.0;
		CutVec p = dense[j] + (dense[j + 1] - dense[j]) * f;
		points[k] = { (float)p.x, (float)p.y, (float)p.z };
	}
	points[0] = kept[0];
	points[count - 1] = kept[^1];
	return { .points = points, .length = (float)total };
}

<* Sample the path's knots into its points and length, replacing those, dropped onto `ground` when one is given. *>
fn void WalkPath.resample(&self, Allocator allocator, WalkGround ground = {})
{
	WalkSamples samples = sample_walk_path(allocator, self.knots, ground: ground);
	if (self.points.len > 0) alloc::free(allocator, self.points);
	self.points = samples.points;
	self.length = samples.length;
}

<*
 What an actor shows at `t`: `cutscene_actor_pose`, and between strips the last
 frame of the clip that ended last, so a clip once played is held, never dropped to rest.

 @param [in] cutscene
 @param [in] curves : "From cutscene_curves"
 @require actor < cutscene.actors.len : "No such actor"
 @require curves.len == cutscene.paths.len : "One curve per path"
*>
fn CutActorPose cutscene_actor_shown(Cutscene* cutscene, CutCurve[] curves, usz actor, float t)
{
	CutActorPose pose = cutscene_actor_pose(cutscene, curves, actor, t);
	if (pose.strip >= 0) return pose;
	CutStrip[] strips = cutscene.actors[actor].strips;
	sz last = -1;
	foreach (usz j, &s : strips)
	{
		if (s.kind == TURN || s.clip.len == 0 || s.end > t) continue;
		if (last < 0 || s.end >= strips[last].end) last = (sz)j;
	}
	if (last < 0) return pose;
	CutStrip* s = &strips[last];
	double local = (double)s.offset + ((double)s.end - (double)s.start) * (double)s.speed;
	if (s.loop && local > CUT_HOLD_BEFORE) local -= CUT_HOLD_BEFORE;
	pose.strip = (int)last;
	pose.clip_time = (float)local;
	pose.holding = true;
	pose.fade = s.fade;
	return pose;
}

<*
 Clip time `t` on a clip `length` long: wrapped when the strip loops, else held at the ends.

 @require length >= 0.0f : "A clip has no negative length"
*>
fn float cut_clip_local(float t, float length, bool loop)
{
	if (!(length > 0.0f)) return 0.0f;
	if (!loop) return math::clamp(t, 0.0f, length);
	float wrapped = t - math::floor(t / length) * length;
	return wrapped >= length ? 0.0f : wrapped;
}

<* What an actor fades out of while a strip fades in: the strip it played before, that clip's time, and how far in the new one is. *>
struct CutFade
{
	int strip;       // the outgoing strip, or -1 for no fade
	float clip_time; // seconds into its clip, before a loop wraps it
	float weight;    // of the incoming strip: 0 at its start, 1 once its fade is done
}

<*
 The cross-fade three.c3's player makes as it plays into the strip `shown` is: from what played
 just before the strip began, which holds its frame if it was held then and plays on at its own
 speed if not, over the strip's `fade`. None once the fade is done, or with nothing before it.

 @param [in] cutscene
 @param [in] curves : "From cutscene_curves"
 @param shown : "cutscene_actor_shown at `t`"
 @require actor < cutscene.actors.len : "No such actor"
 @require curves.len == cutscene.paths.len : "One curve per path"
*>
fn CutFade cutscene_actor_fade(Cutscene* cutscene, CutCurve[] curves, usz actor, float t, CutActorPose shown)
{
	CutFade none = { .strip = -1, .weight = 1.0f };
	if (shown.strip < 0 || shown.holding) return none;
	CutStrip* s = &cutscene.actors[actor].strips[shown.strip];
	if (!(s.fade > 0.0f) || t >= s.start + s.fade || t < s.start) return none;
	// What played up to a hair before the strip began.
	float before = s.start - (float)CUT_HOLD_BEFORE;
	CutActorPose out = cutscene_actor_shown(cutscene, curves, actor, before);
	if (out.strip < 0 || out.strip == shown.strip) return none;
	CutStrip* o = &cutscene.actors[actor].strips[out.strip];
	float time = out.holding ? out.clip_time : out.clip_time + (t - before) * o.speed;
	return { .strip = out.strip, .clip_time = time, .weight = math::clamp((t - s.start) / s.fade, 0.0f, 1.0f) };
}

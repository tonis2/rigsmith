<* The pure half of src/app/painting.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::collections::list;

<*
 The brush's radius in screen pixels when it is first opened, and the range a
 scroll can take it through.

 The default is twice `PICK_RADIUS`, which is the size of a dot's hit circle —
 so the first stroke covers visibly more than a click would, which is what tells
 a user this is a brush and not a picker. The floor is a few pixels, below which
 a stroke lands on nothing and reads as a broken mode; the ceiling is a quarter
 of a window, past which the brush is a fill and the falloff view cannot show
 what changed.
*>
const float BRUSH_RADIUS_DEFAULT = 24.0;

const float BRUSH_RADIUS_MIN = 4.0;

const float BRUSH_RADIUS_MAX = 220.0;

// How much one scroll notch changes the radius, as a fraction of it. Relative
// rather than absolute so the small end is adjustable in single pixels while the
// large end still moves in one gesture.
const float BRUSH_RADIUS_STEP = 0.12;

<*
 The most one stroke can carry a vertex — the strip's Strength slider, as a
 fraction of the way to the target.

 **Full by default.** A drag at 1 puts the joint on, or takes it off, everywhere
 the core of the circle passes, which is what a hand sliding over a part
 expects; a lower setting is for blending, where a stroke carries only that much
 and the values in between are reached a pass at a time.

 **Not a flow rate.** A flow makes the result depend on how long the pointer
 lingered, so the same gesture twice gives two answers. This is spent once per
 stroke however slowly it is drawn — dwelling buys nothing — and it is *lifting
 the button and going again* that carries further. At a third, a centred pass
 lands on about a third, two on three fifths, and four on four fifths.
*>
const float BRUSH_STRENGTH_DEFAULT = 1.0;

const float BRUSH_STRENGTH_MIN = 0.05;

const float BRUSH_STRENGTH_MAX = 1.0;

<*
 How much of the radius paints at the full strength. The rest fades to nothing
 at the ring, so the circle on screen is what a stroke paints and its edge still
 leaves no step.
*>
const float BRUSH_CORE = 0.5;

<*
 How hard the brush hits at a point in its circle, 1 inside `BRUSH_CORE` and
 fading to 0 at the ring along `(1 - u²)²` — the curve `reach_bias` uses, smooth
 at both ends so a stroke leaves no visible step where the core or the circle
 stopped.

 @param closeness : `1 - d²/r²: 1 at the centre, 0 at the ring.`
*>
fn float brush_falloff(float closeness)
{
	float t = math::sqrt(math::clamp(1.0f - closeness, 0.0f, 1.0f));
	if (t <= BRUSH_CORE) return 1.0f;
	float u = (t - BRUSH_CORE) / (1.0f - BRUSH_CORE);
	float fade = 1.0f - u * u;
	return fade * fade;
}

<*
 What a share request did, counted by what it could not do.

 A brush can ignore this; an agent cannot. "340 vertices asked for, 12 of them
 off the limb" is the difference between an edit that worked and one that looked
 like it did — and the two refusals below are not user error, they are the rig
 saying something about itself.
*>
struct PaintResult
{
	usz changed;   // vertices whose weight actually moved
	usz blocked;   // off the joint's limb, where it held nothing: not given any of it
	usz emptied;   // left holding nothing: the joint was taken off and no other holds them
}

<*
 One place the brush lands: a vertex inside the circle, or a face's point
 nearest the centre. `shares` is how much of the pull each corner takes; a
 vertex is its own only corner.
*>
struct BrushTouch @private
{
	Vec3 point;
	float closeness; // 1 - d²/r² on screen: 1 at the centre, 0 at the ring
	uint[3] corners;
	float[3] shares;
}

<*
 The point of a screen triangle nearest `at`, and its barycentric weights: `at`
 itself when inside, otherwise the nearest point of the nearest edge. A triangle
 seen edge-on has no inside and is only its edges.
*>
fn Vec2 nearest_on_triangle(Vec2 at, Vec2[3] corner, float[3]* weight) @private
{
	Vec2 ab = corner[1] - corner[0];
	Vec2 ac = corner[2] - corner[0];
	float area = ab.x * ac.y - ab.y * ac.x;
	if (math::abs(area) > 1.0e-6f)
	{
		Vec2 b = corner[1] - at;
		Vec2 c = corner[2] - at;
		Vec2 a = corner[0] - at;
		float wa = (b.x * c.y - b.y * c.x) / area;
		float wb = (c.x * a.y - c.y * a.x) / area;
		float wc = 1.0f - wa - wb;
		if (wa >= 0.0f && wb >= 0.0f && wc >= 0.0f)
		{
			*weight = { wa, wb, wc };
			return at;
		}
	}

	Vec2 nearest = corner[0];
	float best = float::max;
	for (usz e = 0; e < 3; e++)
	{
		usz f = (e + 1) % 3;
		Vec2 edge = corner[f] - corner[e];
		Vec2 out = at - corner[e];
		float length = edge.x * edge.x + edge.y * edge.y;
		float t = length > 0.0f ? math::clamp((out.x * edge.x + out.y * edge.y) / length, 0.0f, 1.0f) : 0.0f;
		Vec2 on = corner[e] + edge * t;
		Vec2 gap = on - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span >= best) continue;
		best = span;
		nearest = on;
		*weight = { 0.0f, 0.0f, 0.0f };
		(*weight)[e] = 1.0f - t;
		(*weight)[f] = t;
	}
	return nearest;
}

<*
 A row's strongest joints, strongest first, as dot ids: those holding anything
 and at least `floor`, as many as `dots` has room for. Takes them out of `row`
 as it goes.

 @param shares : `Filled alongside; at least as long as dots.`
 @return `How many were written.`
*>
fn usz strongest_shares(float[] row, uint[] dot_ids, uint[] dots, float[] shares, float floor = AREA_LEAK_FLOOR)
{
	usz kept = 0;
	while (kept < dots.len)
	{
		sz strongest = -1;
		foreach (b, share : row)
		{
			if (share <= 0.0f || share < floor) continue;
			if (strongest < 0 || share > row[(usz)strongest]) strongest = (sz)b;
		}
		if (strongest < 0) break;
		dots[kept] = dot_ids[(usz)strongest];
		shares[kept] = row[(usz)strongest];
		row[(usz)strongest] = 0.0f;
		kept++;
	}
	return kept;
}

<*
 One row as shares of its vertex: `row` filled with `weights / sum(weights)`,
 or zeros for a row that holds nothing.
*>
fn void share_row(float[] weights, float[] row)
{
	float sum = 0.0f;
	foreach (weight : weights) sum += weight;
	foreach (b, weight : weights) row[b] = sum > 0.0f ? weight / sum : 0.0f;
}

// How far past the circle's own radius, in the model, a vertex may sit from the
// point under the cursor and still be the surface being painted.
const float BRUSH_DEPTH_SLACK = 1.25f;

<*
 Which vertices a correction should touch, said the way the survey says it.

 `owner` and the two bounds are the fields of a `BlendShare` row turned around:
 the survey reports "`knee` reaches 340 vertices owned by `hip`, mean 0.31, peak
 0.62", and this is that sentence with a target on the end. A caller reading the
 survey therefore already has the vocabulary to act on it, which is the whole
 reason the selector is shaped like the diagnosis rather than like a brush.

 Both bounds are on the *painted* share as it stands now, so a request narrows
 what is already there rather than what the binder alone would have said.
*>
struct PaintPick
{
	uint owner;     // the dot that must hold these vertices most; 0 for any
	float at_least; // the painted dot's current share, inclusive
	float at_most;
}

<*
 The joints whose part of the body `joint` may be painted onto: itself, its
 parent, the parent's other children, the joint the parent hangs from, and
 everything below it — and for a digit
 (`Skeleton.digits`) the whole hand: the joint the fingers hang from and every
 digit under it. The grandparent because a small parent (a collarbone, a fang's
 base) leaves the socket in the mesh of the joint above it.

 	`bool[] family = limb_family(mem, &view.skeleton, joint);`

 A vertex is on the joint's limb when these hold at least `LIMB_FLOOR` of its
 automatic row (`on_limb`). A finger's limb is its hand, a shin's its leg; the
 hips' is the whole body below them, which is what keeps a skirt the thighs hold
 paintable onto the hips. Everything below the joint, not only its children, so
 a With children part — a finger from its knuckle out, a whole arm — is the
 joint's limb by construction. The whole hand for a digit because a finger's
 parts are cut by the knuckle planes, not by the weights: a file can give a
 vertex the bands put on this finger wholly to the next finger's middle joint.

 The limit is on giving weight to a vertex the joint does not hold: taking a
 joint off is allowed anywhere, which is how a stroke that landed on the wrong
 limb is undone, and a vertex it already holds — a head piece's rim an earlier
 Apply gave the head — can be given more. It stops a stroke over a pose from
 painting the boot a hand hangs beside, and a part grown from the wrong place
 from handing it over on Apply. Not limited: a Whole piece or UV islands part,
 named from the menu (`area_names_pieces`), and Lasso pin — drawing around
 vertices is how any of them, a prop held at arm's length, is handed to a joint
 on purpose.

 The caller owns the result, one flag per joint.
*>
fn bool[] limb_family(Allocator allocator, rig::Skeleton* skeleton, usz joint)
{
	usz n = skeleton.len();
	bool[] family = alloc::new_array(allocator, bool, (sz)n);
	if (joint >= n) return family;
	int parent = skeleton.parents[joint];
	if (parent >= 0 && skeleton.parents[(usz)parent] >= 0) family[(usz)skeleton.parents[(usz)parent]] = true;
	for (usz j = 0; j < n; j++)
	{
		if (j == joint || (parent >= 0 && ((int)j == parent || skeleton.parents[j] == parent)))
		{
			family[j] = true;
			continue;
		}
		for (int up = skeleton.parents[j]; up >= 0; up = skeleton.parents[(usz)up])
		{
			if (up != (int)joint) continue;
			family[j] = true;
			break;
		}
	}

	bool[] digit = skeleton.digits(mem);
	defer alloc::free(mem, digit);
	if (!digit[joint]) return family;
	usz fork = joint;
	while (digit[fork] && skeleton.parents[fork] >= 0) fork = (usz)skeleton.parents[fork];
	family[fork] = true;
	for (usz j = 0; j < n; j++)
	{
		if (!digit[j]) continue;
		for (int up = skeleton.parents[j]; up >= 0; up = skeleton.parents[(usz)up])
		{
			if (up != (int)fork) continue;
			family[j] = true;
			break;
		}
	}
	return family;
}

<*
 Whether an automatic row is on the limb `family` names: the family holds at
 least `LIMB_FLOOR` of it. A row with no weight at all is on every limb, since
 nothing there says whose it is.
*>
fn bool on_limb(float[] automatic, bool[] family)
{
	float sum = 0.0f;
	float held = 0.0f;
	foreach (b, weight : automatic)
	{
		sum += weight;
		if (b < family.len && family[b]) held += weight;
	}
	return sum <= 0.0f || held >= LIMB_FLOOR * sum;
}

// What one brush dab did to a row.
enum BrushRow
{
	SAME,
	CHANGED,
	EMPTIED,
}

<*
 Move a joint's share of one weight row toward `share` by `pull`, the brush's way.

 Adding only raises the share, and scales the other joints down in proportion
 so the row sums to 1: at 1 the joint takes the vertex whole. Removing only
 lowers it, through the joint's own weight alone, so nobody else is raised; a
 joint alone on the vertex comes off it all the way.

 @param [inout] row : "One weight per joint"
 @param share : "The share to reach, 0 to 1"
 @param pull : "How far toward it, 0 to 1"
 @require joint < row.len : "Joint out of range"
*>
fn BrushRow brush_row(float[] row, usz joint, bool adds, float share, float pull)
{
	if (pull <= 0.0f) return SAME;
	float total = 0.0f;
	foreach (weight : row) total += weight;
	float own = row[joint];
	float others = math::max(total - own, 0.0f);
	float now = total > UNUSED_TOTAL ? own / total : 0.0f;

	if (adds)
	{
		// Nobody holds it, or the joint alone: any weight of it is the whole vertex.
		if (others <= UNUSED_TOTAL)
		{
			if (own > UNUSED_TOTAL) return SAME;
			row[..] = 0.0f;
			row[joint] = 1.0f;
			return CHANGED;
		}
		if (now >= share - UNUSED_TOTAL) return SAME;
		float want = pull >= 1.0f ? share : now + (share - now) * pull;
		if (math::abs(want - share) <= UNUSED_TOTAL) want = share;
		float scale = (1.0f - want) / others;
		foreach (usz b, &weight : row) *weight = b == joint ? want : *weight * scale;
		return CHANGED;
	}

	if (own <= 0.0f) return SAME;
	if (others <= UNUSED_TOTAL)
	{
		row[joint] = 0.0f;
		return EMPTIED;
	}
	float floor = 1.0f - share;
	if (now <= floor + UNUSED_TOTAL) return SAME;
	float want = pull >= 1.0f ? floor : now + (floor - now) * pull;
	row[joint] = want <= UNUSED_TOTAL ? 0.0f : others * want / (1.0f - want);
	return CHANGED;
}

// The colour of mesh the selected joint cannot be painted onto: darker than the
// falloff ramp's grey, so "none of this joint's" and "off its limb" read apart.
const Vec3 LIMB_OFF_GREY = { 0.12, 0.12, 0.13 };

fn uint off_limb_tint() => rgb(LIMB_OFF_GREY.x, LIMB_OFF_GREY.y, LIMB_OFF_GREY.z);

<*
 The vertices across the plane from `vertices`, aligned with them: the partner
 of each, or `count` (past the mesh) where it has none or sits on the plane — a
 vertex the joint and its twin would both claim is the joint's alone.
*>
fn uint[] mirrored_vertices(rig::TriMesh* geometry, Allocator allocator, rig::MirrorLookup* across, uint[] vertices)
{
	usz count = geometry.positions.len;
	uint[] partners = alloc::new_array(allocator, uint, (sz)vertices.len);
	foreach (i, v : vertices)
	{
		partners[i] = (uint)count;
		if ((usz)v >= count) continue;
		sz partner = across.twin_of(geometry.positions[v]);
		if (partner >= 0 && (uint)partner != v) partners[i] = (uint)partner;
	}
	return partners;
}

<*
 Keep only the surface under the cursor: the touches within the brush's radius,
 measured in the model, of the point under the centre — the closest touch to it
 on screen, the nearer one where two tie. A circle on the screen also covers
 whatever else shows through it — a hand held in front of the chest, fingers
 over a palm — and painting the chest must not paint those. A face is measured
 at its touch, so the corners of a big face under the cursor stay.

 @return `How many of the touches are left, packed to the front.`
*>
fn usz brush_surface(BrushTouch[] touches, Matrix4f view_projection, Vec2 viewport, Vec3 eye, float radius)
{
	usz kept = touches.len;
	if (kept < 2) return kept;
	usz middle = 0;
	float nearest = (touches[0].point - eye).length();
	for (usz i = 1; i < kept; i++)
	{
		float closeness = touches[i].closeness;
		if (closeness < touches[middle].closeness) continue;
		float gap = (touches[i].point - eye).length();
		if (closeness == touches[middle].closeness && gap >= nearest) continue;
		middle = i;
		nearest = gap;
	}
	Vec3 centre = touches[middle].point;

	// The brush's radius in model units at that depth: a short step across the
	// view, and how many pixels it covers.
	Vec3 look = centre - eye;
	float away = look.length();
	if (away <= 0.0f) return kept;
	look /= away;
	Vec3 up = math::abs(look.y) < 0.9f ? (Vec3){ 0.0f, 1.0f, 0.0f } : (Vec3){ 1.0f, 0.0f, 0.0f };
	Vec3 side = look.cross(up).normalize();
	float step = away * 0.01f;
	Vec2? from = project(view_projection, centre, viewport);
	Vec2? to = project(view_projection, centre + side * step, viewport);
	if (catch from, to) return kept;
	float pixels = (to - from).length();
	if (pixels <= 0.0f) return kept;
	float span = radius * step / pixels * BRUSH_DEPTH_SLACK;

	usz left = 0;
	for (usz i = 0; i < kept; i++)
	{
		if ((touches[i].point - centre).length() > span) continue;
		touches[left++] = touches[i];
	}
	return left;
}

<*
 The vertices matching a pick.

 	`uint[] found = app.pick_vertices(mem, knee, { .owner = hip, .at_least = 0.05f });`

 One bind, one pass. The shares are normalised exactly as `survey_weights` and
 the views normalise them, so a count here and a count there are the same number
 — a selector that measured differently from the diagnosis it is phrased in would
 be worse than no selector.

 The caller owns the result.

 @return `Vertex indices, ascending. Empty when nothing matches or there is no rig.`
*>
fn uint[] pick_vertices_in(Allocator allocator, RigView* view, float[] dense, usz count, usz mine, sz wanted_owner, PaintPick pick)
{
	usz bones = view.len();

	uint[] picked = alloc::new_array(allocator, uint, (sz)count);
	usz kept = 0;

	for (usz v = 0; v < count; v++)
	{
		usz at = v * bones;

		float sum;
		sz best = row_owner(dense[at:bones], &sum);
		if (sum <= 0.0f) continue;
		if (wanted_owner >= 0 && best != wanted_owner) continue;

		float share = dense[at + mine] / sum;
		if (share < pick.at_least || share > pick.at_most) continue;
		picked[kept++] = (uint)v;
	}

	if (kept == 0)
	{
		alloc::free(allocator, picked);
		return {};
	}
	return picked[:kept];
}

<*
 Whether a point can't be seen from `eye`, by whatever the mesh is cast against.
*>
alias HiddenTest = fn bool(void* ctx, Vec3 eye, Vec3 point);

<*
 The mesh as it stands on screen, for picking vertices by a shape drawn over it.
*>
struct ScreenProbe
{
	Vec3[] shown;        // each vertex where it is displayed
	uint[] indices;
	Matrix4f view_projection;
	Vec2 viewport;
	Vec3 eye;
	bool xray;           // reach through the mesh
	HiddenTest hidden;
	void* ctx;
}

// Whether the mesh hides this point; never under x-ray.
fn bool ScreenProbe.blocks(&self, Vec3 point) => !self.xray && self.hidden(self.ctx, self.eye, point);

<*
 The vertices a brush circle takes, each with its strength.

 @param vertices : `Receives the vertices; at least one slot per vertex.`
 @param strength : `Receives each one's strength; at least one slot per vertex.`
 @param gain : `The brush's own strength.`
 @return `How many were taken.`
*>
fn usz brush_vertices(ScreenProbe* probe, uint[] vertices, float[] strength, Vec2 at, float radius, float gain)
{
	usz count = probe.shown.len;
	float reach = radius * radius;
	Vec3[] place = alloc::new_array(mem, Vec3, (sz)count);
	defer alloc::free(mem, place);
	Vec2[] pixel = alloc::new_array(mem, Vec2, (sz)count);
	defer alloc::free(mem, pixel);
	// Per vertex: 0 off screen, 1 projected, 2 taken in the circle.
	char[] state = alloc::new_array(mem, char, (sz)count);
	defer alloc::free(mem, state);
	List{BrushTouch} touches;
	touches.init(mem);
	defer touches.free();

	for (usz v = 0; v < count; v++)
	{
		Vec3 position = probe.shown[v];
		Vec2? where = project(probe.view_projection, position, probe.viewport);
		if (catch where) continue;
		place[v] = position;
		pixel[v] = where;
		state[v] = 1;

		Vec2 gap = where - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span > reach) continue;
		if (probe.blocks(position)) continue;
		state[v] = 2;
		touches.push({ .point = position, .closeness = 1.0f - span / reach,
			.corners = { (uint)v, 0, 0 }, .shares = { 1.0f, 0.0f, 0.0f } });
	}

	uint[] indices = probe.indices;
	for (usz t = 0; t + 2 < indices.len; t += 3)
	{
		uint[3] corner = { indices[t], indices[t + 1], indices[t + 2] };
		if (corner[0] >= count || corner[1] >= count || corner[2] >= count) continue;
		if (state[corner[0]] == 0 || state[corner[1]] == 0 || state[corner[2]] == 0) continue;
		// Every corner already in: the face has nothing to add.
		if (state[corner[0]] == 2 && state[corner[1]] == 2 && state[corner[2]] == 2) continue;

		Vec2[3] seen = { pixel[corner[0]], pixel[corner[1]], pixel[corner[2]] };
		if (math::min(seen[0].x, seen[1].x, seen[2].x) > at.x + radius) continue;
		if (math::max(seen[0].x, seen[1].x, seen[2].x) < at.x - radius) continue;
		if (math::min(seen[0].y, seen[1].y, seen[2].y) > at.y + radius) continue;
		if (math::max(seen[0].y, seen[1].y, seen[2].y) < at.y - radius) continue;

		float[3] weight;
		Vec2 gap = nearest_on_triangle(at, seen, &weight) - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span > reach) continue;
		Vec3 point = place[corner[0]] * weight[0] + place[corner[1]] * weight[1] + place[corner[2]] * weight[2];
		if (probe.blocks(point)) continue;

		float most = math::max(weight[0], weight[1], weight[2]);
		if (most <= 0.0f) continue;
		touches.push({ .point = point, .closeness = 1.0f - span / reach, .corners = corner,
			.shares = { weight[0] / most, weight[1] / most, weight[2] / most } });
	}

	BrushTouch[] landed = touches.array_view();
	if (!probe.xray) landed = landed[:brush_surface(landed, probe.view_projection, probe.viewport, probe.eye, radius)];

	// Each vertex keeps the hardest of its touches. A vertex in the circle is
	// taken even where the rim gives it nothing; a corner only where its face does.
	strength[:count] = -1.0f;
	foreach (touch : landed)
	{
		float pull = brush_falloff(touch.closeness);
		for (usz k = 0; k < 3; k++)
		{
			float share = touch.shares[k];
			if (share <= 0.0f) continue;
			float given = pull * share;
			if (share < 1.0f && given <= 0.0f) continue;
			uint v = touch.corners[k];
			if (given > strength[v]) strength[v] = given;
		}
	}
	usz kept = 0;
	for (usz v = 0; v < count; v++)
	{
		if (strength[v] < 0.0f) continue;
		vertices[kept] = (uint)v;
		strength[kept] = strength[v] * gain;
		kept++;
	}
	return kept;
}

<*
 Which vertices project inside the polygon, hidden or not: what a front-faces pass
 drops here is what the walk in `lasso_region` has to be able to arrive at.

 @param polygon : `At least three points.`
 @param within : `Receives one flag per vertex; starts all false.`
 @return `How many are inside.`
*>
fn usz lasso_within(ScreenProbe* probe, Vec2[] polygon, bool[] within)
{
	usz count = probe.shown.len;
	Vec2 low = polygon[0];
	Vec2 high = polygon[0];
	foreach (point : polygon)
	{
		if (point.x < low.x) low.x = point.x;
		if (point.y < low.y) low.y = point.y;
		if (point.x > high.x) high.x = point.x;
		if (point.y > high.y) high.y = point.y;
	}

	// Membership first, and for every vertex rather than only the ones that
	// survive the visibility test: what a front-faces pass drops here is precisely
	// what the walk below has to be able to arrive at.
	usz enclosed = 0;
	for (usz v = 0; v < count; v++)
	{
		Vec2? where = project(probe.view_projection, probe.shown[v], probe.viewport);
		if (catch where) continue;

		if (where.x < low.x || where.x > high.x || where.y < low.y || where.y > high.y) continue;
		if (!inside_polygon(polygon, where)) continue;

		within[v] = true;
		enclosed++;
	}
	return enclosed;
}

<*
 The vertices of the lasso's region: under x-ray all of them; otherwise what can
 be seen and what is joined to that without leaving the outline.

 @param around : `The mesh's adjacency; may be null under x-ray.`
 @param within : `From lasso_within.`
 @param out : `Receives the vertices; at least one slot per vertex.`
 @return `How many there are.`
*>
fn usz lasso_region(ScreenProbe* probe, rig::MeshAdjacency* around, bool[] within, uint[] out)
{
	usz count = probe.shown.len;
	usz kept = 0;

	if (probe.xray)
	{
		for (usz v = 0; v < count; v++)
		{
			if (within[v]) out[kept++] = (uint)v;
		}
		return kept;
	}

	// A mesh with no edges to follow — a point cloud, or one whose triangles this
	// state has somehow not caught up with — has no neighbourhoods to grow
	// through. There is nothing to seed from and nowhere to go, so the region is
	// what can be seen of it, rather than the gesture being refused.
	if (!around.usable() || around.vertices() != count)
	{
		for (usz v = 0; v < count; v++)
		{
			if (!within[v]) continue;
			if (probe.blocks(probe.shown[v])) continue;
			out[kept++] = (uint)v;
		}
		return kept;
	}

	usz groups = around.classes();

	// `asked` ends the seeding pass meaning "this weld is inside the polygon":
	// every class with a member inside it is reached by the loop below, and
	// membership cannot differ between members — they are the same point, so they
	// are the same pixel.
	bool[] asked = alloc::new_array(mem, bool, (sz)groups);
	defer alloc::free(mem, asked);
	bool[] reached = alloc::new_array(mem, bool, (sz)groups);
	defer alloc::free(mem, reached);

	// A class is queued at most once, so the frontier can never outgrow the mesh
	// and the walk needs no buffer that grows.
	uint[] queue = alloc::new_array(mem, uint, (sz)groups);
	defer alloc::free(mem, queue);

	usz tail = 0;
	for (usz v = 0; v < count; v++)
	{
		if (!within[v]) continue;

		usz group = (usz)around.class_of[v];
		// One cast per weld rather than one per copy: the copies are the same
		// point, so they are the same ray and the same answer.
		if (asked[group]) continue;
		asked[group] = true;

		if (probe.blocks(probe.shown[v])) continue;
		reached[group] = true;
		queue[tail++] = (uint)group;
	}

	for (usz head = 0; head < tail; head++)
	{
		foreach (n : around.around((usz)queue[head]))
		{
			// The step that keeps the region inside its own outline: a neighbour
			// that projects outside the polygon is where this piece of the model
			// leaves what was drawn around, and nothing past it is in the region.
			if (!asked[n] || reached[n]) continue;
			reached[n] = true;
			queue[tail++] = n;
		}
	}

	for (usz v = 0; v < count; v++)
	{
		if (within[v] && reached[around.class_of[v]]) out[kept++] = (uint)v;
	}
	return kept;
}

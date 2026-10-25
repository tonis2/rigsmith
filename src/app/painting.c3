<*
 The weight brush and the weight request: hand edits to one joint's weights, as
 an operation rather than as storage.

 Both write through one primitive, `nudge_column`, into the joint's own column
 (`app/pinning.c3` keeps it), so a weight given or taken means the same thing
 whichever asked — and no other joint's weight moves to make room. A vertex a
 joint is taken off keeps whatever the others hold of it, which may be nothing.
*>
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
 Begin a stroke: forget how far each vertex has already been carried.

 **The radial falloff is the whole mechanism, and dwelling is not part of it.**
 What a vertex ends up at depends only on how close to the centre of the circle
 the stroke passed it, and on how many strokes have passed it — never on how long
 any of them lingered. Holding still changes nothing and neither does going back
 and forth; lifting the button and going again is what carries further.

 That is the difference between a brush you can predict and one you have to
 feel. The alternative — a flow that carries a vertex a fixed fraction per step
 — makes the result depend on how fast the hand moved and how long it lingered,
 so the same gesture twice gives two answers and neither is the one on screen
 until it is over.

 `stroke_seen` is how much pull each vertex has taken *this* stroke. Each step
 asks for the difference rather than the total, and the arithmetic composes
 exactly: pulling `a` then `b` toward a target lands at `1 − (1−a)(1−b)`, so to
 reach `f` having already applied `s` the next pull is `(f − s) / (1 − s)`.
 Re-passing at the same distance therefore asks for nothing at all.

 A new stroke starts the memory over, which is what lets a second pass push
 further than the first — the one place repetition should count, because it is
 the one the hand meant.
*>
fn void AppState.begin_stroke(&self)
{
	usz count = self.geometry.positions.len;
	if (self.stroke_seen.len != count)
	{
		if (self.stroke_seen.len > 0) alloc::free(mem, self.stroke_seen);
		self.stroke_seen = count > 0 ? alloc::new_array(mem, float, (sz)count) : (float[]){};
	}
	self.stroke_seen[..] = 0.0f;
	self.stroke_open = true;
	self.stroke_blocked = false;
	self.stroke_emptied = false;

	// One Mirror for every weight tool: with it on, the stroke paints the twin
	// across the plane as it paints the joint.
	self.drop_stroke_mirror();
	uint twin = self.area_mirrors() ? self.mirror_twin(self.selected) : 0;
	if (twin != 0 && count > 0)
	{
		self.stroke_twin = twin;
		self.stroke_mirror = self.mesh_mirror(mem);
	}
}

// Forgets the stroke's mirror. Safe with none.
fn void AppState.drop_stroke_mirror(&self)
{
	if (self.stroke_twin != 0) self.stroke_mirror.free(mem);
	self.stroke_twin = 0;
	self.stroke_mirror = {};
}

<*
 The vertices across the plane from `vertices`, aligned with them: the partner
 of each, or `count` (past the mesh) where it has none or sits on the plane — a
 vertex the joint and its twin would both claim is the joint's alone.
*>
fn uint[] AppState.mirrored_vertices(&self, Allocator allocator, rig::MirrorLookup* across, uint[] vertices)
{
	usz count = self.geometry.positions.len;
	uint[] partners = alloc::new_array(allocator, uint, (sz)vertices.len);
	foreach (i, v : vertices)
	{
		partners[i] = (uint)count;
		if ((usz)v >= count) continue;
		sz partner = across.twin_of(self.geometry.positions[v]);
		if (partner >= 0 && (uint)partner != v) partners[i] = (uint)partner;
	}
	return partners;
}

<*
 The button came up: settle what the stroke put off.

 Nothing about the paint — every dab committed itself as it was made. What is
 owed is the posed surface: `rebind_skin` keeps the accelerator standing while
 a stroke runs, since a stroke over a parked clip reskins on every move and the
 mirrored tree and its policy are the expensive half of a rebind. One rebuild
 here, and the overlay's occlusion, the collision tables and the brush's own
 visibility test are exact again before the next press. And a stroke that
 passed off the joint's limb, or left vertices no joint holds, says so here,
 once rather than on every move.

 Safe to call with no stroke open; the viewport calls it wherever its latch
 comes down, including when the mode closed under a held button.
*>
fn void AppState.end_stroke(&self)
{
	if (!self.stroke_open) return;
	self.stroke_open = false;
	self.drop_stroke_mirror();
	// The stroke's pins went on the ledger with the group left open; closing it
	// here makes the whole press-to-release one undo step.
	self.undo_stack.commit();
	if (self.stroke_blocked)
	{
		self.stroke_blocked = false;
		Dot* dot = self.doc.find(self.selected);
		self.@notice("%s is only painted on its own limb · Lasso pin (shift+T) hands other vertices over",
			dot && dot.name.len > 0 ? dot.name : "this joint");
	}
	if (self.stroke_emptied)
	{
		self.stroke_emptied = false;
		Dot* dot = self.doc.find(self.selected);
		String name = dot && dot.name.len > 0 ? dot.name : "this joint";
		self.@notice("%s was the only joint on some of these vertices · they are unused now, View › Unused weights shows them",
			name);
	}
	if (!self.surface_stale) return;
	self.skin_stale = true;
	self.refresh_pose_display();
}

// Releases the stroke memory. Safe on one that was never allocated.
fn void AppState.drop_stroke_memory(&self)
{
	if (self.stroke_seen.len > 0) alloc::free(mem, self.stroke_seen);
	self.stroke_seen = {};
}

<*
 Turn this step's radial falloff into the pull still owed, and remember it.

 	`strength[i] = app.stroke_pull(vertex, falloff);`

 See `begin_stroke` for why the difference rather than the total. Returns 0 for a
 vertex this stroke has already carried at least this far, which is what makes
 the brush idempotent under a hand that is not moving.
*>
fn float AppState.stroke_pull(&self, uint vertex, float falloff)
{
	if ((usz)vertex >= self.stroke_seen.len) return falloff;

	float seen = self.stroke_seen[vertex];
	if (falloff <= seen) return 0.0f;
	self.stroke_seen[vertex] = falloff;

	// Everything already given, and nothing left to give: the vertex is at the
	// target and the division below would be by zero.
	if (seen >= 1.0f) return 0.0f;
	// The core owes all of it, said exactly: the division rounds a hair under 1
	// and would leave a remainder on a vertex the stroke passed straight over.
	if (falloff >= 1.0f) return 1.0f;
	return (falloff - seen) / (1.0f - seen);
}

<*
 Open the weight brush on the selected dot (shift+W).

 The Area tool's sibling — see `AppState.brushing` — and it borrows the falloff
 view the same way and for the same reason: a correction made against the
 territory view is a correction made against a picture of a different question.
 Leaving hands the view back.

 It opens over a posed body too. Painting is how a joint
 that folds wrongly gets fixed, and the fold is only visible while the joint
 is bent — so the animation workspace, where every joint is bent, is where the
 brush is wanted most.

 @return `False when there is no dot to paint, which the caller says out loud.`
*>
fn bool AppState.begin_brush(&self)
{
	if (!self.doc.find(self.selected)) return false;

	// Over a parked clip or a pose draft as readily as over the rest mesh: the
	// stroke reads the posed vertices and casts against the posed surface — see
	// `brush_vertices` — and the mesh reskins as it is painted, which is the
	// whole reason to paint a pose rather than the rest. A *running* clip is
	// parked first, the same stop of the clock a scrub makes: a body walking
	// out from under the circle is not one anybody can aim at, and stopping
	// playback outright would put the mesh back at rest, which is the one thing
	// the user opening a brush over a pose did not ask for.
	if (self.animating && !self.anim_paused) self.pause_clip();

	// The Area tool goes: both claim a press on the mesh for the selected joint.
	// A part on show goes unapplied, and the picture goes back to the weights the
	// brush paints on — said, so the change is not read as the weights moving.
	bool unapplied = self.area_shaping();
	String name = self.area_joint_name();
	self.end_area();
	if (unapplied) self.@notice("the part was not applied — the brush paints %s's weights as they are", name);

	// And the lasso, for a sharper version of the same reason: both claim a
	// drag over the model — the lasso the plain one, the brush the one under
	// ctrl, which is the lasso's other direction — so with the two open a
	// press is a stroke and a region at once. Symmetric — `begin_lasso` closes
	// this one.
	self.end_lasso();
	self.end_sketch();

	self.brushing = true;
	self.brush_tint = self.tint_mode;
	self.show_tint(FALLOFF);
	return true;
}

<*
 Close the brush, handing the view back.

 No ledger work: every stroke committed itself on its release, so there is
 nothing outstanding when the mode closes and escape has
 nothing to take back. Escape here means "stop painting", and the way to undo a
 stroke is the way to undo anything.
*>
fn void AppState.end_brush(&self)
{
	if (!self.brushing) return;
	self.brushing = false;
	// Escape under a held button: the viewport's latch drops on the next move
	// without a release, so what that release would have settled is settled
	// here.
	self.end_stroke();

	// Only when the mode is still showing what it put up: a user who switched the
	// view while painting has said what they want more clearly than the view this mode
	// saved on the way in.
	if (self.tint_mode == FALLOFF) self.show_tint(self.brush_tint);
}

<*
 Set the brush radius, clamped to what a brush can usefully be.

 @return `True when it moved, so the caller knows to repaint.`
*>
fn bool AppState.set_brush_radius(&self, float pixels)
{
	float was = self.brush_radius;
	float want = pixels;
	want = math::clamp(want, BRUSH_RADIUS_MIN, BRUSH_RADIUS_MAX);
	self.brush_radius = want;
	return want != was;
}

<*
 Set the brush strength, clamped to what a stroke can usefully carry.

 @return `True when it moved, so the caller knows to repaint.`
*>
fn bool AppState.set_brush_strength(&self, float fraction)
{
	float was = self.brush_strength;
	float want = fraction;
	want = math::clamp(want, BRUSH_STRENGTH_MIN, BRUSH_STRENGTH_MAX);
	self.brush_strength = want;
	return want != was;
}

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
 Size the brush by a scroll.

 **Only while the sizing key is held**, which the caller decides — the wheel and
 the trackpad belong to the camera the rest of the time. Reach mode can claim
 them outright because its ring is the only thing it does; a brush has to be
 aimed, and aiming means turning the model, so a tool that ate the orbit for as
 long as it was open would be paintable from one angle only.

 @param notches : `Wheel notches; positive grows.`
 @return `True when the radius moved.`
*>
fn bool AppState.size_brush(&self, float notches)
{
	if (!self.brushing || notches == 0.0f) return false;
	return self.set_brush_radius(self.brush_radius * (1.0f + BRUSH_RADIUS_STEP * notches));
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
 The vertices under the brush, and how hard each one is hit.

 	`usz n = app.brush_vertices(verts, strength, vp, size, eye, at, radius);`

 **A brush is not a stencil.** The core of the circle carries a vertex as far as
 one stroke is allowed — `brush_strength` — and the rim fades to nothing, so
 clipping a vertex with the edge barely moves it — see `brush_falloff`.

 **Faces, not only vertices.** A face is coloured by its corners, so on a coarse
 mesh a circle inside one face covers no vertex and would paint nothing. Every
 face the circle covers passes the pull at its point nearest the centre on to its
 corners, the nearest corner all of it and the others by how near they are.

 **Front faces only, unless `xray`.** A brush that painted through a limb onto
 the one behind it would manufacture exactly the bleed crig exists to remove —
 the user would be correcting an arm and silently correcting the ribs under it.
 `Picker.hidden_surface` is the test for a point *on* the skin; `occluded` is
 built for dots inside the body and answers "visible" for every back-facing
 vertex on the model. X-ray takes everything in the circle, for the creases
 and inner shells the front never shows; the limb guard in `brush_share` still
 holds.

 **The positions on screen, posed or not.** Under a parked clip or a pose draft
 the vertices are read back skinned by the palette on screen and the visibility
 cast is made against that same posed surface, so the circle lands on the limb
 the user is looking at. At rest both are the picker's — see
 `AppState.shown_position` and `AppState.mesh_hidden_surface`, which choose.

 The visibility test is a raycast and the projection is a matrix multiply, so the
 circle test comes first and the expensive half only runs on what it lets through.

 @param vertices : `Filled with the vertices hit. Must be at least as long as the mesh.`
 @param strength : `Filled alongside: the brush strength in the core, fading to 0 at the rim. Same length rule.`
 @param view_projection : `From OrbitCamera.view_projection, for this viewport's aspect.`
 @param viewport : `Size of the region the camera renders into, in pixels.`
 @param eye : `Camera position in model space, for the visibility test.`
 @param at : `Where the brush is, in the same pixels project returns.`
 @param xray : `Take everything in the circle, hidden or not.`
 @return `How many were hit.`
*>
fn usz AppState.brush_vertices(&self, uint[] vertices, float[] strength, Matrix4f view_projection,
	Vec2 viewport, Vec3 eye, Vec2 at, float radius, bool xray = false)
{
	usz count = self.geometry.positions.len;
	if (count == 0 || radius <= 0.0f) return 0;
	if (vertices.len < count || strength.len < count) return 0;

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
		Vec3 position = self.shown_position(v);
		Vec2? where = project(view_projection, position, viewport);
		if (catch where) continue;
		place[v] = position;
		pixel[v] = where;
		state[v] = 1;

		Vec2 gap = where - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span > reach) continue;
		if (!xray && self.mesh_hidden_surface(eye, position)) continue;
		state[v] = 2;
		touches.push({ .point = position, .closeness = 1.0f - span / reach,
			.corners = { (uint)v, 0, 0 }, .shares = { 1.0f, 0.0f, 0.0f } });
	}

	uint[] indices = self.geometry.indices;
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
		if (!xray && self.mesh_hidden_surface(eye, point)) continue;

		float most = math::max(weight[0], weight[1], weight[2]);
		if (most <= 0.0f) continue;
		touches.push({ .point = point, .closeness = 1.0f - span / reach, .corners = corner,
			.shares = { weight[0] / most, weight[1] / most, weight[2] / most } });
	}

	BrushTouch[] landed = touches.array_view();
	if (!xray) landed = landed[:self.brush_surface(landed, view_projection, viewport, eye, radius)];

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
		strength[kept] = strength[v] * self.brush_strength;
		kept++;
	}
	return kept;
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
 Keep only the surface under the cursor: the touches within the brush's radius,
 measured in the model, of the point under the centre — the closest touch to it
 on screen, the nearer one where two tie. A circle on the screen also covers
 whatever else shows through it — a hand held in front of the chest, fingers
 over a palm — and painting the chest must not paint those. A face is measured
 at its touch, so the corners of a big face under the cursor stay.

 @return `How many of the touches are left, packed to the front.`
*>
fn usz AppState.brush_surface(&self, BrushTouch[] touches, Matrix4f view_projection,
	Vec2 viewport, Vec3 eye, float radius)
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
 The vertices matching a pick.

 	`uint[] found = app.pick_vertices(mem, knee, { .owner = hip, .at_least = 0.05f });`

 One bind, one pass. The shares are normalised exactly as `survey_weights` and
 the views normalise them, so a count here and a count there are the same number
 — a selector that measured differently from the diagnosis it is phrased in would
 be worse than no selector.

 The caller owns the result.

 @param dot_id : `The dot whose share the bounds are about.`
 @return `Vertex indices, ascending. Empty when nothing matches or there is no rig.`
*>
fn uint[] AppState.pick_vertices(&self, Allocator allocator, uint dot_id, PaintPick pick)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);

	sz found = view.joint_of(dot_id);
	usz bones = view.len();
	usz count = self.geometry.positions.len;
	if (found < 0 || bones == 0 || count == 0) return {};
	usz mine = (usz)found;

	// The owner as a joint index, so the argmax below compares numbers rather
	// than looking a dot id up per vertex.
	sz wanted_owner = pick.owner == 0 ? -1 : view.joint_of(pick.owner);
	if (pick.owner != 0 && wanted_owner < 0) return {};

	// Through the cache rather than the binder: this runs on every mouse move of a
	// brush stroke, and the base underneath it does not change while one is in
	// flight. The copy stays — the corrections have to be painted somewhere, and
	// that somewhere cannot be the cache.
	float[] dense = self.weights(mem, &view);
	defer alloc::free(mem, dense);
	if (dense.len < count * bones) return {};

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
 Say what share of these vertices a dot should hold, and state it.

 	`PaintResult did = app.paint_share(knee, vertices, 0.0f);`

 **The public verb** — what `paint_weights` says over MCP. Written the way the
 brush writes (`nudge_column`): the joint's own weight, in its own column, so a
 joint can be given a vertex the automatic weights gave it nothing on and no
 other joint's weight moves. What it comes to as a share of the vertex is that
 weight over the row's total.

 One undoable step.

 **Partly, when asked.** `strengths` moves each vertex a fraction of the way from
 where it is now toward the target rather than all of it — the same request
 applied softly twice lands further than once and never past the target. Empty
 means all the way, which is what a caller naming vertices outright wants.

 @param dot_id : `The dot whose weight is being set.`
 @param vertices : `Which vertices. Out-of-range entries are skipped.`
 @param weight : `0 to 1, clamped.`
 @param strengths : `Optional, one per vertex: how far toward the target to move, 0 to 1. Empty goes the whole way.`
*>
fn PaintResult AppState.paint_share(&self, uint dot_id, uint[] vertices, float weight, float[] strengths = {})
{
	PaintResult result;
	if (vertices.len == 0) return result;
	float[] pulls = alloc::new_array(mem, float, (sz)vertices.len);
	defer alloc::free(mem, pulls);
	foreach (i, &pull : pulls) *pull = i < strengths.len ? strengths[i] : 1.0f;
	return self.nudge_column(dot_id, vertices, math::clamp(weight, 0.0f, 1.0f), pulls, limb: false);
}


<*
 The joints whose part of the body `joint` may be painted onto: itself, its
 parent, the parent's other children, and everything below it — and for a digit
 (`Skeleton.digits`) the whole hand: the joint the fingers hang from and every
 digit under it.

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

<*
 One flag per vertex: whether `dot_id` may be given weight there by the brush or
 an Apply — its limb, over the automatic weights (`limb_family`). Empty when the
 joint is not in the rig or there is no bind to read.

 The caller owns the result.
*>
fn bool[] AppState.limb_mask(&self, Allocator allocator, RigView* view, uint dot_id)
{
	usz count = self.geometry.positions.len;
	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || bones == 0 || count == 0) return {};
	float[] base = self.base_bind_for(view);
	if (base.len < count * bones) return {};

	bool[] family = limb_family(mem, &view.skeleton, (usz)joint);
	defer alloc::free(mem, family);
	bool[] mask = alloc::new_array(allocator, bool, (sz)count);
	foreach (v, &on : mask) *on = on_limb(base[(usz)v * bones:bones], family);
	return mask;
}

// The colour of mesh the selected joint cannot be painted onto: darker than the
// falloff ramp's grey, so "none of this joint's" and "off its limb" read apart.
const Vec3 LIMB_OFF_GREY = { 0.12, 0.12, 0.13 };

fn uint off_limb_tint() => rgb(LIMB_OFF_GREY.x, LIMB_OFF_GREY.y, LIMB_OFF_GREY.z);

<*
 While the brush or the Area tool is open on the falloff view, the mesh off the
 selected joint's limb in `LIMB_OFF_GREY`: where a stroke or an Apply will not
 give it anything. A vertex there that the joint still holds keeps its colour —
 a stray hold is what has to stay in sight to be painted off.
*>
fn void AppState.overlay_limb_tints(&self, RigView* view, float[] painted)
{
	usz count = self.geometry.positions.len;
	if (!(self.brushing || self.areaing) || self.tint_mode != FALLOFF || self.tints.len != count) return;
	usz bones = view.len();
	sz joint = view.joint_of(self.selected);
	if (joint < 0 || painted.len < count * bones) return;

	bool[] limb = self.limb_mask(mem, view, self.selected);
	defer if (limb.len > 0) alloc::free(mem, limb);
	if (limb.len != count) return;
	uint off = off_limb_tint();
	for (usz v = 0; v < count; v++)
	{
		if (limb[v] || joint_share(painted[v * bones:bones], (usz)joint) >= AREA_LEAK_FLOOR) continue;
		self.tints[v] = off;
	}
}

<*
 One step of a brush stroke, on the joint's own column.

 	`app.brush_share(knee, under[:hit], 1.0f, pulls[:hit]);`

 `nudge_column` on the joint's limb, with the undo group left open so the
 press-to-release is one step (`end_stroke` closes it), and the refusals kept
 for `end_stroke` to say once rather than on every move.

 @param target : `1 puts the joint on, 0 takes it off.`
 @param strengths : `One per vertex: how far toward the target, 0 to 1.`
 @return `How many vertices changed.`
*>
fn usz AppState.brush_share(&self, uint dot_id, uint[] vertices, float target, float[] strengths)
{
	PaintResult did = self.nudge_column(dot_id, vertices, target, strengths, limb: true, commit: false);
	if (did.blocked > 0) self.stroke_blocked = true;
	if (did.emptied > 0) self.stroke_emptied = true;
	usz changed = did.changed;

	// With Mirror on, the same stroke across the plane on the twin.
	if (self.stroke_twin != 0 && dot_id == self.selected)
	{
		uint[] across = self.mirrored_vertices(mem, &self.stroke_mirror, vertices);
		defer alloc::free(mem, across);
		changed += self.nudge_column(self.stroke_twin, across, target, strengths, limb: true, commit: false).changed;
	}
	if (changed > 0 && self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 Move a joint's weight on each vertex toward a target, in its own column.

 	`PaintResult did = app.nudge_column(knee, vertices, 0.0f, pulls, limb: true);`

 **The one weight edit.** The brush and `paint_weights` both come through here,
 so a weight given or taken means the same thing whichever asked. Each vertex
 moves `pull` of the way from the joint's weight toward `target`, and that is
 all: the other joints on the vertex keep exactly what they hold, so raising a
 joint blends it with them and taking it off leaves the vertex to them — or to
 nobody, when nobody else holds it (`emptied`). The joint is held from the
 first change on (`replace_column`).

 **One refusal.** With `limb`, a vertex off the joint's limb (`limb_family`)
 that it holds nothing of is not given any — counted in `blocked`.

 @param target : `The weight to move toward, 0 to 1.`
 @param pulls : `One per vertex: how far toward the target, 0 to 1. A vertex without one is skipped.`
 @param limb : `Refuse to give the joint vertices off its limb.`
 @param commit : `Close the undo group — false for a stroke still in flight.`
*>
fn PaintResult AppState.nudge_column(&self, uint dot_id, uint[] vertices, float target, float[] pulls,
	bool limb, bool commit = true)
{
	PaintResult result;
	usz count = self.geometry.positions.len;
	if (vertices.len == 0 || count == 0 || !self.doc.find(dot_id)) return result;
	self.flush_edges();

	RigView? opened = self.open_rig(mem);
	if (catch opened) return result;
	RigView view = opened;
	defer view.free(mem);

	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || bones == 0) return result;

	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (painted.len < count * bones) return result;
	float[] automatic = limb ? self.weights(mem, &view, AUTOMATIC) : (float[]){};
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	bool[] family = limb_family(mem, &view.skeleton, (usz)joint);
	defer alloc::free(mem, family);

	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	for (usz v = 0; v < count; v++) column[v] = painted[v * bones + (usz)joint];

	foreach (i, v : vertices)
	{
		if ((usz)v >= count || i >= pulls.len) continue;
		float pull = math::clamp(pulls[i], 0.0f, 1.0f);
		if (pull <= 0.0f) continue;

		usz at = (usz)v * bones;
		float now = column[v];
		// A full pull lands on the target exactly, not on its rounding, and so does
		// a remainder too small to hold anything (`UNUSED_TOTAL`): left behind on a
		// vertex no other joint holds, it shows as the whole of it and is below
		// the step a later stroke would bother to take.
		float want = pull >= 1.0f ? target : math::clamp(now + (target - now) * pull, 0.0f, 1.0f);
		if (math::abs(want - target) <= UNUSED_TOTAL) want = target;
		if (want == now || (want != target && math::abs(want - now) < 1.0e-6f)) continue;
		if (limb && want > now && joint_share(painted[at:bones], (usz)joint) < AREA_LEAK_FLOOR
			&& automatic.len >= count * bones && !on_limb(automatic[at:bones], family))
		{
			result.blocked++;
			continue;
		}
		column[v] = want;

		float total = 0.0f;
		for (usz b = 0; b < bones; b++) total += (sz)b == joint ? want : painted[at + b];
		if (total <= UNUSED_TOTAL) result.emptied++;
	}

	result.changed = self.replace_column(&view, dot_id, column, commit);
	if (result.changed == 0) result.emptied = 0;
	return result;
}

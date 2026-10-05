<*
 Hand corrections to the bind, as an operation rather than as storage.

 `core/document.c3` holds one dab and the primitive that sets it; this is the
 layer above, where a set of dabs becomes one undoable stroke and the views are
 told to catch up. The split is the same one `core/editing.c3` describes for
 every other edit: the primitive does exactly what it says and records nothing,
 and what the user asked for is assembled here.

 **The brush states shares; the paint layer multiplies.** A brush stroke is
 written as pins (`brush_share`), so it can put a joint where the automatic
 weights gave it nothing. `PaintDab` is the older layer: a multiplier over
 whatever the binder produces, which cannot lift a zero. It stays for
 `paint_weights` over MCP and for sessions that carry it.
*>
module crig;

import rig;


import std::math;
import std::math::vector;

<*
 The highest share a vertex can be given, and why it is not 1.

 A share is relative: `w / sum(w)`. Scaling one column can drive its share as
 close to 1 as you like but never reach it, because the others are still there —
 exactly 1 would mean every other dot holds *nothing*, which is a statement about
 those dots rather than about this one, and painting it would silently rewrite
 their corrections too.

 So "full" stops here. Past `sparsify_weights` and the renormalisation that
 follows it, the difference between this and 1 is far below anything a deformation
 shows; what it buys is that the multiplier stays finite and the other dots keep
 whatever the user gave them.
*>
const float PAINT_SHARE_CEILING = 0.99f;

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
 The most one stroke can carry a vertex, at the very centre of the circle.

 **Under 1 on purpose, and this is not a flow rate.** A pull of 1 would take the
 middle of the circle all the way to the target on the first dab, which makes the
 brush a switch: one tap and the vertex is fully red, with every value in between
 reachable only by clipping it with the rim. Capping what a *stroke* can give
 turns "how much" into "how many passes", which is a thing a hand can aim.

 The distinction from a per-frame flow matters and is the whole reason the
 earlier attempt was wrong. A flow makes the result depend on how long the
 pointer lingered, so the same gesture twice gives two answers. This is spent
 once per stroke however slowly it is drawn — dwelling still buys nothing — and
 it is *lifting the button and going again* that carries further.

 At this rate a centred pass lands on about a third, two on three fifths, and
 four on four fifths: a handful of deliberate strokes from grey to orange, and no
 way to get there by accident.
*>
const float BRUSH_STRENGTH = 0.35;

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
}

<*
 The button came up: settle what the stroke put off.

 Nothing about the paint — every dab committed itself as it was made. What is
 owed is the posed surface: `rebind_skin` keeps the accelerator standing while
 a stroke runs, since a stroke over a parked clip reskins on every move and the
 mirrored tree and its policy are the expensive half of a rebind. One rebuild
 here, and the overlay's occlusion, the collision tables and the brush's own
 visibility test are exact again before the next press.

 Safe to call with no stroke open; the viewport calls it wherever its latch
 comes down, including when the mode closed under a held button.
*>
fn void AppState.end_stroke(&self)
{
	if (!self.stroke_open) return;
	self.stroke_open = false;
	// The stroke's pins went on the ledger with the group left open; closing it
	// here makes the whole press-to-release one undo step.
	self.undo_stack.commit();
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
	self.end_area();

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

	// Only when the mode is still showing what it put up: a user who reached for U
	// while painting has said what they want more clearly than the view this mode
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
 unreachable" is the difference between a correction that worked and one that
 looked like it did — and the two failures below are not user error, they are the
 rig saying something about itself.
*>
struct PaintResult
{
	usz changed;     // dabs that actually moved
	usz unreachable; // the binder gives this dot nothing here, so no multiplier reaches
	usz alone;       // nothing else holds this vertex, so there is no share to take

	<*
	 Requested vertices carrying a pin — where the correction was made and will
	 not be visible.

	 Not a failure and not counted as one: the dab is written and comes back the
	 moment the pin is lifted. But `pin_over` runs after `paint_over` and states
	 the share outright, so the deformation the caller is looking at does not
	 move, and "340 painted, 340 pinned" is the difference between a correction
	 that did nothing and one whose effect is simply somewhere else in the stack.
	*>
	usz pinned;
}

<*
 Write a set of dabs onto the document, saying what each one changed.

 	`usz changed = app.write_paint(dabs, changes);`

 The half of `paint_dabs` that touches the document and nothing else: no
 ledger entry, no commit, no view told. For a caller assembling a larger edit
 — a mirror, which crosses a dot's paint onto its twin inside the same undo
 step as the twin itself — which records the changes as a stroke of its own
 and commits when the whole edit is in.

 @param dabs : `What to set, borrowed for the call. A factor of 1 clears a dab.`
 @param changes : `Filled with both sides of each change, in order.`
 @require changes.len >= dabs.len : `Every dab may turn out to be a change.`
 @return `How many actually changed, which is how much of changes was written.`
*>
fn usz AppState.write_paint(&self, PaintDab[] dabs, PaintChange[] changes)
{
	usz changed = 0;
	foreach (dab : dabs)
	{
		// Negative is clamped by `set_paint`, so ask it what it would store rather
		// than comparing against what was asked for — otherwise a dab of -1 over a
		// vertex already at 0 would look like a change and record an identity one.
		float before = self.doc.paint_of(dab.vertex, dab.dot_id);
		if (!self.doc.set_paint(dab.vertex, dab.dot_id, dab.factor)) continue;

		changes[changed++] = {
			.vertex = dab.vertex,
			.dot_id = dab.dot_id,
			.before = before,
			.after = self.doc.paint_of(dab.vertex, dab.dot_id),
		};
	}
	return changed;
}

<*
 Lay a set of dabs onto the document as one undoable stroke.

 	`usz changed = app.paint_dabs(dabs);`

 One undo step however many vertices were touched, because a stroke is one action
 to the person who made it. The previous factor of each dab is read here rather
 than being asked of the caller — a brush knows where it went and what it wants,
 not what was already there.

 Dabs that change nothing are dropped rather than recorded, so a brush dragged
 back over mesh it has already painted to the same value leaves the history
 alone. A stroke where *every* dab is like that records nothing at all and
 returns 0, which is what makes it safe to call on every mouse move.

 Marks the *paint* stale rather than the rig, which is what gets the view back
 on the very next frame instead of once the hand stops — see `mark_paint_stale`.
 A posed body is reskinned before this returns, so the deformation the stroke
 was aimed at moves under the circle on the same frame as the colour.

 @param dabs : `What to set, borrowed for the call. A factor of 1 clears a dab.`
 @return `How many actually changed.`
*>
fn usz AppState.paint_dabs(&self, PaintDab[] dabs)
{
	if (dabs.len == 0) return 0;

	PaintChange[] changes = alloc::new_array(mem, PaintChange, (sz)dabs.len);
	defer alloc::free(mem, changes);

	usz changed = self.write_paint(dabs, changes);
	if (changed == 0) return 0;

	self.undo_stack.record_stroke(changes[:changed]);
	self.undo_stack.commit();
	self.mark_paint_stale();
	// A parked clip is not ticking and a pose draft never does, so nothing
	// would rebind the skin under the palette until the playhead moved: the
	// tints would follow the stroke and the body would not. Same door the
	// history steps use, and cheap for the same reason the tints are — the
	// base bind is cached, and a stroke keeps the surface over it standing.
	if (self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 The vertices under the brush, and how hard each one is hit.

 	`usz n = app.brush_vertices(verts, strength, vp, size, eye, at, radius);`

 **A brush is not a stencil.** Strongest at the centre and fading to nothing at
 the rim is what lets one tool make every value between 0 and 1 without a second
 control to set them with: clip a vertex with the edge and it barely moves, run
 the middle over it and it goes as far as one stroke is allowed to carry it —
 `BRUSH_STRENGTH`, which is well short of the whole way. `(1 - t²)²` is the same
 curve `reach_bias` uses, for the same reason: smooth at both ends, so a stroke
 leaves no visible step where the circle stopped.

 **Front faces only, always, and it is not a preference.** A brush that painted
 through a limb onto the one behind it would manufacture exactly the bleed crig
 exists to remove — the user would be correcting an arm and silently correcting
 the ribs under it. `Picker.hidden_surface` is the test for a point *on* the
 skin; `occluded` is built for dots inside the body and answers "visible" for
 every back-facing vertex on the model.

 **The positions on screen, posed or not.** Under a parked clip or a pose draft
 the vertices are read back skinned by the palette on screen and the visibility
 cast is made against that same posed surface, so the circle lands on the limb
 the user is looking at. At rest both are the picker's — see
 `AppState.shown_position` and `AppState.mesh_hidden_surface`, which choose.

 The visibility test is a raycast and the projection is a matrix multiply, so the
 circle test comes first and the expensive half only runs on what it lets through.

 @param vertices : `Filled with the vertices hit. Must be at least as long as the mesh.`
 @param strength : `Filled alongside, 1 at the centre to 0 at the rim. Same length rule.`
 @param view_projection : `From OrbitCamera.view_projection, for this viewport's aspect.`
 @param viewport : `Size of the region the camera renders into, in pixels.`
 @param eye : `Camera position in model space, for the visibility test.`
 @param at : `Where the brush is, in the same pixels project returns.`
 @return `How many were hit.`
*>
fn usz AppState.brush_vertices(&self, uint[] vertices, float[] strength, Matrix4f view_projection,
	Vec2 viewport, Vec3 eye, Vec2 at, float radius)
{
	usz count = self.geometry.positions.len;
	if (count == 0 || radius <= 0.0f) return 0;
	if (vertices.len < count || strength.len < count) return 0;

	usz kept = 0;
	float reach = radius * radius;

	for (usz v = 0; v < count; v++)
	{
		Vec3 position = self.shown_position(v);
		Vec2? where = project(view_projection, position, viewport);
		if (catch where) continue;

		Vec2 gap = where - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span > reach) continue;
		if (self.mesh_hidden_surface(eye, position)) continue;

		float fade = 1.0f - span / reach;
		vertices[kept] = (uint)v;
		strength[kept] = fade * fade * BRUSH_STRENGTH;
		kept++;
	}
	return self.brush_surface(vertices, strength, kept, view_projection, viewport, eye, radius);
}

// How far past the circle's own radius, in the model, a vertex may sit from the
// point under the cursor and still be the surface being painted.
const float BRUSH_DEPTH_SLACK = 1.25f;

<*
 Keep only the surface under the cursor: the vertices within the brush's radius,
 measured in the model, of the one nearest the centre. A circle on the screen
 also covers whatever else shows through it — a hand held in front of the
 chest, fingers over a palm — and painting the chest must not paint those.

 @return `How many of the first kept are left, packed to the front.`
*>
fn usz AppState.brush_surface(&self, uint[] vertices, float[] strength, usz kept, Matrix4f view_projection,
	Vec2 viewport, Vec3 eye, float radius)
{
	if (kept < 2) return kept;
	usz middle = 0;
	for (usz i = 1; i < kept; i++)
	{
		if (strength[i] > strength[middle]) middle = i;
	}
	Vec3 centre = self.shown_position(vertices[middle]);

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
		if ((self.shown_position(vertices[i]) - centre).length() > span) continue;
		vertices[left] = vertices[i];
		strength[left] = strength[i];
		left++;
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
	float[] dense = self.painted_bind(mem, &view);
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
 Say what share of these vertices a dot should hold, and solve for the paint that
 reaches it.

 	`PaintResult did = app.paint_share(knee, vertices, 0.0f);`

 **The public verb.** Everything under it is multipliers, which are unstateable —
 `1 / (d² + ε)` spans orders of magnitude, so "multiply by 0.03" means nothing
 without knowing the base. A *share* means the same thing to a person, to a test
 and to an agent, at every vertex, before and after `sparsify_weights`
 renormalises. So this is what a caller says, and the multiplier is worked out
 from whatever the binder currently produces.

 The arithmetic, per vertex: with `b` the binder's own weight for this dot, `R`
 the painted weights of every *other* dot, and `S` the share asked for, the
 correction that lands it is

 	`p = S·R / ((1 − S)·b)`

 from `S = pb / (pb + R)`. Note `R` is the *painted* total — a share is a
 statement about the rig as it now stands, so painting one dot down and then
 another up gives the second one the room the first gave up.

 **It stays a correction, not a value.** Move the dot afterwards and `b` changes
 underneath while `p` does not, so the share drifts. That is the whole bargain of
 §7's correction layer — the alternative is an auto-rig that stops helping the
 moment you touch it — and it is why "paint what you see" is a promise about the
 session rather than about the file.

 Two vertices cannot be served, and both are the rig talking rather than the
 caller being wrong. Where the binder gives this dot **nothing** — a vertex its
 geodesic flood never reached — no finite multiplier reaches any share at all;
 zero times anything is zero, and the dot needs moving or its reach widening.
 Where **nothing else** holds the vertex, there is no share to take: the dot
 already has all of it and the request has no meaning until a second dot is near.

 One undoable stroke, through `paint_dabs`, so all of the above is one Ctrl+Z.

 **Partly, when asked.** `strengths` moves each vertex a fraction of the way from
 where it is now toward the target rather than all of it, which is what makes a
 brush able to produce every value in between without a second control: the same
 request applied softly twice lands further than once and never past the target.
 Empty means all the way, which is what a caller naming vertices outright wants.

 @param dot_id : `The dot whose share is being set.`
 @param vertices : `Which vertices. Out-of-range entries are skipped.`
 @param share : `0 to 1. Clamped into [0, PAINT_SHARE_CEILING] — see there for why 1 is not reachable.`
 @param strengths : `Optional, one per vertex: how far toward the target to move, 0 to 1. Empty goes the whole way.`
*>
fn PaintResult AppState.paint_share(&self, uint dot_id, uint[] vertices, float share, float[] strengths = {})
{
	PaintResult result;
	if (vertices.len == 0 || !self.doc.find(dot_id)) return result;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return result;
	RigView view = opened;
	defer view.free(mem);

	sz found = view.joint_of(dot_id);
	usz bones = view.len();
	if (found < 0 || bones == 0) return result;
	usz mine = (usz)found;

	float wanted = share;
	wanted = math::clamp(wanted, 0.0f, PAINT_SHARE_CEILING);

	// The base underneath the corrections. `b` has to come from here rather than
	// from the painted bind, because a vertex already painted to zero has lost the
	// number this solves against — zero divided by zero is not the way back.
	//
	// Borrowed from the cache and never freed here — see `base_bind_for`. Nothing
	// below this line may reach `mark_rig_stale`, which would release the array
	// this is still reading: a stroke records its dabs through `paint_dabs`, which
	// marks the *paint* stale and leaves the base alone, and that is the only
	// write this makes.
	float[] base = self.base_bind_for(&view);

	usz count = self.geometry.positions.len;
	if (base.len < count * bones) return result;

	// Where each requested vertex sits in the working arrays, so the paint can be
	// scattered in one pass over the dabs instead of one search per bone.
	int[] slot = alloc::new_array(mem, int, (sz)count);
	defer alloc::free(mem, slot);
	slot[:count] = -1;

	usz asked = 0;
	foreach (v : vertices)
	{
		if ((usz)v >= count || slot[v] >= 0) continue;
		slot[v] = (int)asked++;
	}
	if (asked == 0) return result;

	// Counted here, while `slot` still names every requested vertex — the dab loop
	// below clears each entry as it takes it. One walk of the pin layer rather
	// than a lookup per vertex, and one flag per requested row so a vertex with
	// two pins on it is one answer rather than two.
	bool[] stated = alloc::new_array(mem, bool, (sz)asked);
	defer alloc::free(mem, stated);
	foreach (column : view.pins)
	{
		int row = slot[column.vertex];
		if (row < 0 || stated[row]) continue;
		stated[row] = true;
		result.pinned++;
	}

	// Current corrections for the requested vertices only, one row per vertex.
	float[] factors = alloc::new_array(mem, float, (sz)(asked * bones));
	defer alloc::free(mem, factors);
	factors[..] = 1.0f;

	foreach (column : view.paint)
	{
		int row = slot[column.vertex];
		if (row >= 0) factors[(usz)row * bones + column.joint] = column.factor;
	}

	PaintDab[] dabs = alloc::new_array(mem, PaintDab, (sz)asked);
	defer alloc::free(mem, dabs);

	usz ready = 0;
	foreach (usz i, v : vertices)
	{
		int row = slot[v];
		if (row < 0) continue;
		slot[v] = -1; // taken; a repeated vertex is one dab, not two

		usz at = (usz)v * bones;
		float held = base[at + mine];
		if (held <= 0.0f)
		{
			result.unreachable++;
			continue;
		}

		float rest = 0.0f;
		for (usz b = 0; b < bones; b++)
		{
			if (b == mine) continue;
			rest += base[at + b] * factors[(usz)row * bones + b];
		}

		if (rest <= 0.0f)
		{
			// Already the whole of this vertex. Asking for more is satisfied and
			// asking for less has nowhere to put what is given up.
			if (wanted < PAINT_SHARE_CEILING) result.alone++;
			continue;
		}

		// Where this vertex stands right now, so a partial request can move it
		// from there rather than from wherever the binder alone would have put it.
		float target = wanted;
		if (i < strengths.len)
		{
			float pull = strengths[i];
			if (pull <= 0.0f) continue;
			if (pull > 1.0f) pull = 1.0f;

			float carried = held * factors[(usz)row * bones + mine];
			float now = carried / (carried + rest);
			target = now + (wanted - now) * pull;
		}
		if (target > PAINT_SHARE_CEILING) target = PAINT_SHARE_CEILING;
		if (target < 0.0f) target = 0.0f;

		dabs[ready++] = {
			.vertex = v,
			.dot_id = dot_id,
			.factor = target * rest / ((1.0f - target) * held),
		};
	}

	result.changed = self.paint_dabs(dabs[:ready]);
	return result;
}

<*
 One step of a brush stroke, written as stated shares.

 	`app.brush_share(knee, under[:hit], 1.0f, pulls[:hit]);`

 Each vertex moves `pull` of the way from the joint's share as shown toward
 `target`; the other joints keep their proportions of what is left. The row is
 written as pins — the joint and the strongest few others — so the brush can
 raise a joint the automatic weights gave nothing, and speaks the same language
 as the Area tool. Where the joint held the whole row, what it gives up goes to
 the others by their automatic weights.

 The undo group is left open; `end_stroke` closes it, so a stroke is one step.

 @param target : `1 puts the joint on, 0 takes it off.`
 @param strengths : `One per vertex: how far toward the target, 0 to 1.`
 @return `How many pin entries changed.`
*>
fn usz AppState.brush_share(&self, uint dot_id, uint[] vertices, float target, float[] strengths)
{
	usz count = self.geometry.positions.len;
	if (vertices.len == 0 || count == 0 || !self.doc.find(dot_id)) return 0;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || bones == 0) return 0;

	float[] painted = self.painted_bind(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (painted.len < count * bones) return 0;
	float[] base = self.base_bind_for(&view);

	float[] row = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, row);
	uint[SKIN_INFLUENCES] dots;
	float[SKIN_INFLUENCES] shares;

	PinDraft draft;
	draft.init(count);
	defer draft.free();

	foreach (i, v : vertices)
	{
		if ((usz)v >= count || i >= strengths.len) continue;
		float pull = math::clamp(strengths[i], 0.0f, 1.0f);
		if (pull <= 0.0f) continue;

		usz at = (usz)v * bones;
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[at + b];
		float now = sum > 0.0f ? painted[at + (usz)joint] / sum : 0.0f;
		float want = now + (target - now) * pull;
		if (math::abs(want - now) < 1.0e-6f) continue;

		// The others' proportions: as shown, or where the joint held everything,
		// the automatic row's.
		float others = 0.0f;
		for (usz b = 0; b < bones; b++)
		{
			row[b] = (sz)b == joint || sum <= 0.0f ? 0.0f : painted[at + b] / sum;
			others += row[b];
		}
		if (others <= 1.0e-6f && base.len >= count * bones)
		{
			others = 0.0f;
			for (usz b = 0; b < bones; b++)
			{
				row[b] = (sz)b == joint ? 0.0f : base[at + b];
				others += row[b];
			}
		}
		if (others <= 1.0e-6f)
		{
			// Nothing else to hand a share to: the joint keeps the whole row.
			if (want < now) continue;
			want = 1.0f;
		}
		else
		{
			float scale = (1.0f - want) / others;
			for (usz b = 0; b < bones; b++) row[b] *= scale;
		}
		row[(usz)joint] = want;

		usz kept = top_row(row, view.dot_ids, joint, dots[..], shares[..]);
		draft.state(v, dots[:kept], shares[:kept]);
	}

	usz changed = self.lay_draft(&draft, commit: false);
	if (changed > 0 && self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 Take every correction off the rig, as one undoable step.

 The way out of a layer that has been painted into a corner. One stroke rather
 than one per dab, for the same reason painting is.

 @return `How many dabs were cleared.`
*>
fn usz AppState.clear_paint(&self)
{
	sz held = self.doc.paint.len();
	if (held == 0) return 0;

	// Copied out first: `paint_dabs` walks the same list this is emptying, and a
	// list being written while it is read is a different bug every time.
	PaintDab[] dabs = alloc::new_array(mem, PaintDab, held);
	defer alloc::free(mem, dabs);

	foreach (usz i, dab : self.doc.paint.array_view())
	{
		dabs[i] = { .vertex = dab.vertex, .dot_id = dab.dot_id, .factor = 1.0f };
	}
	return self.paint_dabs(dabs);
}

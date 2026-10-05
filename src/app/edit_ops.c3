<*
 Editing the rig by hand: what a click, a drag or a shortcut does to the dots.

 The operations proper — each one is a whole thing the user asked for, so each
 one ends in a single `commit` and is a single Ctrl+Z. What they are assembled
 from is `recorded.c3`, whose primitives record but never commit; the ledger
 underneath both is `core/editing.c3`.

 On `AppState` rather than on `RigDocument` because they move the selection as
 well as the document. Placing a dot selects it, deleting one clears it, and
 mirroring a selection replaces it with the twins — none of which the document
 knows about, and all of which the user would notice if it stopped happening.

 The mirror is the one non-obvious member. It is two passes over a plan rather
 than a dot-at-a-time walk, because a bone between two mirrored dots has to
 become a bone between their two twins, and neither twin exists while the first
 dot is being handled.
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;


import std::collections::list;

<*
 How far off the symmetry plane a dot has to be before it gets a mirror.

 Quoted in the mesh's bounds diagonal, like every other epsilon in crig. A dot
 on the spine is its own reflection, and duplicating it leaves two joints in the
 same place with a zero-length bone between them — which exports as a skeleton
 no one can pose. `mirror_selection` reads it twice: once to leave those dots
 alone, and once as how near an unnamed dot's reflection another dot has to sit
 before the two are taken for a pair.
*>
const float MIRROR_EPSILON = 0.01;

<*
 How square-on to the world X axis the rig's left-right axis has to sit before
 the mirror treats the plane as world-aligned. `cos(10°)`: a rig within ten
 degrees of facing straight ahead mirrors across a plane perpendicular to world
 X (which keeps depth and is bit-exact for a rig placed square), and one turned
 further than that — a character modelled facing a diagonal — mirrors across the
 tilted plane its own joints describe.
*>
const float MIRROR_SQUARE_COS = 0.985;

// Reflects a point across the plane through `point` with unit `normal`.
fn Vec3 reflect_across(Vec3 v, Vec3 point, Vec3 normal) @local
{
	return v - normal * (2.0f * (v - point).dot(normal));
}

<*
 The plane the mirror reflects across, read off the rig: a point and a unit
 normal.

 The normal is the body's **left-right axis**, averaged over every named pair's
 own left-to-right direction. A rig placed square about the world gives a normal
 along X and the plane is the familiar world-aligned one; a character modelled
 turned about the vertical — its shoulders and hips sitting at different depths —
 gives a tilted normal, and mirroring across it sends a twin around to the other
 side of the *body* rather than straight across world X, which for a turned rig
 is off to the side or out in front. The normal is only tilted once it is more
 than `MIRROR_SQUARE_COS` off world X, so a near-square rig stays exactly
 world-aligned and the pairs it squares up are not dragged by their own noise.

 The point comes from the centre joints — the ones with no side, which sit on
 the plane — or, with none, from the pair midpoints, or the stored `sym_x`. When
 the plane is world-aligned the point collapses to `{x,0,0}` and snaps to the
 stored `sym_x` when within `on_plane` of it, so a rig already mirrored reflects
 onto itself bit-for-bit and records nothing.

 @param on_plane : `The on-plane tolerance, in model units — how near the stored plane the centre line must be to keep it exactly.`
*>
fn void AppState.mirror_plane(&self, Vec3* point, Vec3* normal, float on_plane)
{
	MirrorSurvey survey = self.mirror_survey();
	Vec3 n = survey.normal();
	if (plane_is_square(n))
	{
		// World-aligned: a bare x, snapped to the stored plane when the centre
		// line all but agrees with it, so an already-square rig records nothing.
		float px = survey.centres > 0 ? survey.centre_point().x : self.doc.sym_x;
		if (math::abs(px - self.doc.sym_x) <= on_plane) px = self.doc.sym_x;
		*point = { px, 0, 0 };
		*normal = { 1, 0, 0 };
		return;
	}

	// Tilted: any point the plane passes through — the centre line, or the pairs'
	// own midline when the rig carries no centre joint.
	if (survey.centres > 0) { *point = survey.centre_point(); }
	else if (survey.pairs > 0) { *point = survey.midpoint(); }
	else { *point = { self.doc.sym_x, 0, 0 }; }
	*normal = n;
}

<*
 What the named joints say about where the body's middle is, read once for
 every plane question: the centre joints (no side, so on the plane), and each
 named pair's left-to-right direction and midpoint.

 `exclude` leaves joints out — a pair with either side in it counts for nothing.
*>
struct MirrorSurvey
{
	Vec3 axis;        // each pair's direction oriented to +x, summed (unit-weighted)
	Vec3 centre;      // centre-joint positions, summed
	Vec3 midpoints;   // pair midpoints, summed
	usz pairs;
	usz centres;
}

fn MirrorSurvey AppState.mirror_survey(&self, uint[] exclude = {})
{
	MirrorSurvey out;
	foreach (dot : self.doc.dots.array_view())
	{
		if (dot.name.len == 0 || array::contains(exclude, dot.id)) continue;

		String twin = mirror_name(mem, dot.name);
		defer if (twin.len > 0) alloc::free(mem, twin.ptr);

		if (twin.len == 0)
		{
			// A centre joint, on the plane.
			out.centre = out.centre + dot.position;
			out.centres++;
			continue;
		}

		// A side joint: fold its pair in once, from the lower-id member.
		Dot* other = self.dot_named(twin);
		if (other == null || other.id <= dot.id || array::contains(exclude, other.id)) continue;

		Vec3 span = dot.position - other.position;
		if (span.length() < 1.0e-6f) continue;
		// Unit-weighted, so a long limb and a short one count the same and one
		// crooked pair cannot swing the axis far.
		Vec3 dir = span.normalize();
		if (dir.x < 0.0f) dir = dir * -1.0f;  // orient every pair to the +x side
		out.axis = out.axis + dir;
		out.midpoints = out.midpoints + (dot.position + other.position) * 0.5f;
		out.pairs++;
	}
	return out;
}

// Divided rather than scaled by a reciprocal: a square rig's plane is compared
// against the stored `sym_x` bit for bit, and `x / n` is what that was written as.
fn Vec3 MirrorSurvey.centre_point(self) => self.centre / (float)self.centres;
fn Vec3 MirrorSurvey.midpoint(self) => self.midpoints * (1.0f / (float)self.pairs);

<*
 The plane's normal: the pairs' averaged left-right axis when the rig is turned
 more than `MIRROR_SQUARE_COS` off world X, and world X itself otherwise — so a
 near-square rig stays exactly world-aligned.
*>
fn Vec3 MirrorSurvey.normal(self)
{
	if (self.pairs == 0) return { 1, 0, 0 };
	Vec3 avg = self.axis.normalize();
	return math::abs(avg.x) < MIRROR_SQUARE_COS ? avg : { 1, 0, 0 };
}

fn bool plane_is_square(Vec3 n) @local
	=> math::abs(n.x) >= MIRROR_SQUARE_COS && math::abs(n.y) < 1.0e-6f && math::abs(n.z) < 1.0e-6f;

<*
 The mirror plane for BUILDING a new side, read off the rig's existing symmetric
 pairs rather than its centre joints.

 The difference from `mirror_plane`, and the reason both exist: this **trusts the
 pairs**. Creating the other side of a limb reflects across where the rig is
 already symmetric — the legs, a shoulder line — and a square pair's midpoint sits
 on that plane exactly, immune to an un-sided limb joint (a finger named `ring_f`,
 an `elbow` with no `_r`) that a centre-joint centroid folds in and drags off the
 midline. `mirror_plane` cannot trust the pairs, because its job is to square
 crooked ones up and a crooked pair's midpoint is not the plane; this one squares
 nothing, so the pairs it reads are its firmest evidence.

 `exclude` is the selection — the joints whose twin is being made or moved. A
 pair with either side in it is the one being built against, so it cannot be its
 own reference and is left out; the plane comes from the rest of the rig.

 Falls back to the centre joints, then the stored `sym_x`, when no pair is left
 to read — the same order `mirror_plane` ends on.
*>
fn void AppState.mirror_plane_for_new(&self, uint[] exclude, Vec3* point, Vec3* normal, float on_plane)
{
	MirrorSurvey survey = self.mirror_survey(exclude);
	Vec3 n = survey.normal();

	// The point: the pairs' own midline first — a square pair's midpoint is on the
	// plane and no un-sided joint can pull it off — then the centre joints, then the
	// stored plane.
	Vec3 base;
	if (survey.pairs > 0) { base = survey.midpoint(); }
	else if (survey.centres > 0) { base = survey.centre_point(); }
	else { base = { self.doc.sym_x, 0, 0 }; }

	if (plane_is_square(n))
	{
		float px = base.x;
		if (math::abs(px - self.doc.sym_x) <= on_plane) px = self.doc.sym_x;
		*point = { px, 0, 0 };
		*normal = { 1, 0, 0 };
		return;
	}
	*point = base;
	*normal = n;
}

<*
 Selects one dot and nothing else, dropping any wider selection.

 The one way selection is *replaced*, rather than an assignment at each site,
 because in the falloff view the selection is the joint being shown — changing
 it is a rig change as far as the tints are concerned, and scattering that
 knowledge across every place that selects is how a view stops updating. The
 rebind is armed for the next frame rather than debounced: a click is not a
 stream of edits, and waiting 150 ms to answer one reads as broken.

 A plain click goes through here, which is what makes clicking a dot mean "just
 this one" however many were selected before. `extend_selection` is the other
 door.
*>
fn void AppState.select(&self, uint id)
{
	self.selected = id;
	self.area_follow_selection();
	self.also_selected.clear();
	self.scene_selection = id == 0 ? NONE : JOINT;
	self.anchor_moved();
	if (!self.areaing && self.weights_card_open()) self.sync_weights_card();
}

<*
 Select a logical scene object rather than a joint.

 Object selection and joint selection are exclusive. Going through `select(0)`
 also drops the Area tool's pending part in the same way an empty
 viewport click does.
*>
fn void AppState.select_scene(&self, SceneSelection selection)
{
	if (selection == JOINT)
	{
		self.scene_selection = self.selected == 0 ? NONE : JOINT;
		return;
	}
	self.select(0);
	self.scene_selection = selection;
}

<*
 How much one press of the sharpness keys moves it.

 A ratio rather than an increment, because the thing being stepped is an
 exponent: going 1 → 1.25 changes a blend about as much as 3.2 → 4 does, while a
 fixed step of 0.25 would be a large move at the bottom of the range and an
 invisible one at the top. Seven presses cross the whole band, which is few
 enough to explore by holding the key and many enough to stop on the one that
 looks right.
*>
const float SHARPNESS_STEP = 1.25;

<*
 Sharpens or softens every transition band at once — the `]` and `[` keys.

 The other way to change a bind without moving a dot, beside reach and the
 brush, and the only one that acts on the whole model: what it fixes is a mesh
 built out of solid pieces, where the binder's gradients are broad everywhere
 and no amount of per-dot work is the answer. See `sharpen_weights` for what the
 number does.

 Stepped within [1, `SHARPNESS_MAX`] rather than the document's full band. Below
 1 is a blend *softer* than the binder's own, which nothing has yet wanted from
 the keyboard — the wire can still ask for it — and the floor is snapped to
 exactly unset so that stepping all the way back down leaves a document
 indistinguishable from one that never used the feature, key and all.

 One press is one Ctrl+Z, and it goes through `mark_rig_stale`: the sharpening
 is part of the base bind, so a paint-only invalidation would leave the cached
 base carrying the previous γ under every correction solved against it.

 @param sharper : `True narrows the bands, false widens them back toward the binder's own blend.`
*>
fn void AppState.step_sharpness(&self, bool sharper)
{
	float had = self.doc.sharpness > 0.0f ? self.doc.sharpness : 1.0f;
	float want = math::clamp(
		sharper ? had * SHARPNESS_STEP : had / SHARPNESS_STEP,
		1.0f, SHARPNESS_MAX);

	// The floor is the binder's own blend, which is stored as unset — so a model
	// softened all the way back writes no session key rather than one saying 1.
	if (want <= 1.0f) want = 0.0f;

	if (!self.set_sharpness_recorded(want))
	{
		if (sharper)
		{
			self.@notice("blends are already as sharp as they go (%.2f)", SHARPNESS_MAX);
		}
		else
		{
			self.@notice("blends are already the default (1.00)");
		}
		return;
	}

	self.undo_stack.commit();
	self.mark_rig_stale();

	if (want == 0.0f)
	{
		self.@notice("blend sharpness 1.00 — the default");
		return;
	}
	self.@notice("blend sharpness %.2f", want);
}

<*
 Arms the falloff rebind after the anchor changes.

 Split out of `select` because the anchor also moves without the selection
 being replaced — shift-clicking the anchor out of a group promotes another
 member — and the falloff view is a picture of whichever dot is the anchor.
*>
fn void AppState.anchor_moved(&self)
{
	if (self.tint_mode == FALLOFF)
	{
		self.weights_stale = true;
		self.weights_due = 0.0f;
	}
}

<*
 Whether this dot is selected — the anchor, or one of the others.

 Everything that *acts* on the selection wants `selected`; this is for painting
 and for counting, where every member is equal.
*>
fn bool AppState.is_selected(&self, uint id)
{
	if (id == 0) return false;
	if (id == self.selected) return true;
	foreach (other : self.also_selected.array_view())
	{
		if (other == id) return true;
	}
	return false;
}

<*
 How many dots are selected, anchor included.
*>
fn usz AppState.selection_count(&self)
{
	return self.selected == 0 ? 0 : 1 + (usz)self.also_selected.len();
}

<*
 Adds a dot to the selection, or takes it back out (shift-click).

 Taking the anchor out promotes another member rather than emptying the
 selection, so shift-clicking through a group never clears it by surprise.
 Removing the last dot does clear it, which is the only way that can happen.
*>
fn void AppState.extend_selection(&self, uint id)
{
	if (id == 0) return;
	if (self.selected == 0)
	{
		self.select(id);
		return;
	}
	self.scene_selection = JOINT;

	if (id == self.selected)
	{
		if (self.also_selected.len() == 0)
		{
			self.select(0);
			return;
		}
		self.selected = self.also_selected[0];
		self.also_selected.remove_at(0);
		self.anchor_moved();
		return;
	}

	foreach (sz i, other : self.also_selected.array_view())
	{
		if (other != id) continue;
		self.also_selected.remove_at(i);
		return;
	}
	self.also_selected.push(id);
}

<*
 Selects a joint and every joint below it in the hierarchy, the joint staying
 the anchor so the gizmo and the panel stay on it.

 @return `How many joints are selected afterwards, the joint included.`
*>
fn usz AppState.select_branch(&self, uint id)
{
	if (self.doc.find(id) == null) return 0;
	TransformTarget one = { .kind = JOINT_TARGETS, .active_joint = id, .joint_count = 1 };
	uint[] branch = self.rotation_branch(one);
	defer if (branch.len > 0) alloc::free(mem, branch.ptr);

	self.select(id);
	foreach (other : branch)
	{
		if (other != id) self.also_selected.push(other);
	}
	return self.selection_count();
}

<*
 Selects every dot in the document (Ctrl+A).

 The anchor stays where it was whenever it is still a dot, so this adds the rest
 of the document to the selection rather than moving what the pin and the
 falloff view are pointed at. With nothing selected the first dot in document
 order takes the role — an arbitrary choice, but the alternative is a select-all
 that leaves nothing to act through.

 An empty document selects nothing, which is what selecting all of nothing is.

 @return `How many dots are selected afterwards.`
*>
fn usz AppState.select_all(&self)
{
	uint anchor = self.doc.find(self.selected) != null ? self.selected : 0;

	self.also_selected.clear();
	foreach (dot : self.doc.dots.array_view())
	{
		if (anchor == 0)
		{
			anchor = dot.id;
			continue;
		}
		if (dot.id == anchor) continue;
		self.also_selected.push(dot.id);
	}

	if (anchor != self.selected)
	{
		self.selected = anchor;
		self.anchor_moved();
	}
	self.scene_selection = anchor == 0 ? NONE : JOINT;
	return self.selection_count();
}

<*
 Selects the dots inside a drawn region — the lasso's SELECT job, on release.

 `select_all` for a polygon instead of the whole document, and `Viewport.pick_dot`
 with a region instead of a radius: the dots are found in *screen* space, through
 `dot_position`, so what a region catches is what it was drawn around on the
 pixels the user was looking at. That is what lets this job run over a posed body
 and a playing clip where the pinning job cannot — a pin is measured against the
 rest mesh, a circle is measured against itself.

 **Nothing is recorded.** A selection is not a document edit — `select` and
 `extend_selection` reach no ledger — so there is nothing here for Ctrl+Z to take
 back, exactly as there is nothing after a click on a dot.

 The three readings, from the modifiers the press latched:

 - plain — the region *replaces* the selection, the way a click does. A region
   that caught nothing therefore empties it, which is what "replace with what I
   circled" means when nothing was circled.
 - `lasso_removes` (ctrl) — the caught dots come out and the rest stay.
 - `lasso_adds` (alt) — the caught dots go in on top of what was already there,
   so a selection can be built from several strokes.

 @param view_projection : `From OrbitCamera.view_projection, for this viewport's aspect.`
 @param viewport : `Size of the region the camera renders into, in pixels.`
 @return `How many dots the region caught, which is not the resulting selection size.`
*>
fn usz AppState.lasso_select_commit(&self, Matrix4f view_projection, Vec2 viewport)
{
	Vec2[] region = self.lasso_points.array_view();

	// Under three points there is no region — `inside_polygon` says so itself, and
	// answering here means a tap that never travelled does not read as "replace
	// the selection with nothing".
	if (region.len < 3) return 0;

	// Emptied before the walk rather than after it, so the caught dots are
	// appended to nothing and the anchor ends up being the first one the region
	// found rather than whichever dot happened to be selected before.
	if (!self.lasso_removes && !self.lasso_adds) self.select(0);

	usz caught = 0;
	foreach (dot : self.doc.dots.array_view())
	{
		Vec2? at = project(view_projection, self.dot_position(dot), viewport);
		// Behind the eye, or off the clip volume: not on screen, so not inside
		// anything drawn on it.
		if (catch at) continue;
		if (!inside_polygon(region, at)) continue;
		caught++;

		// Both directions go through `extend_selection`, guarded on what is
		// already in the selection. On its own it *toggles*, which is the right
		// reading for a shift-click on one dot and the wrong one for a region over
		// twenty: the ones already selected would come straight back out.
		bool held = self.is_selected(dot.id);
		if (self.lasso_removes)
		{
			if (held) self.extend_selection(dot.id);
		}
		else if (!held)
		{
			self.extend_selection(dot.id);
		}
	}
	return caught;
}

<*
 The whole selection as one array, anchor first.

 A snapshot, because every caller that wants all of them is about to change the
 document underneath it — deleting a dot rewrites the selection through
 `forget_stale_ids`, and a loop over the live list would walk off the end of it.

 The caller owns the array; it is empty when nothing is selected.
*>
fn uint[] AppState.selection_ids(&self, Allocator allocator)
{
	usz count = self.selection_count();
	if (count == 0) return {};

	uint[] ids = alloc::new_array(allocator, uint, (sz)count);
	ids[0] = self.selected;
	foreach (sz i, other : self.also_selected.array_view()) ids[(usz)i + 1] = other;
	return ids;
}

<*
 Places a dot, chaining it to the selection when auto-connect is on.

 Placing is one-sided. Building both halves at once was the older arrangement
 and it made every click a decision that could only be corrected by deleting
 and starting again — a twin landed wherever the reflection fell, and nothing
 afterwards knew the two belonged together. `mirror_selection` is the
 replacement: build one side, select it, mirror it, and the pairing is stated
 by the names rather than remembered from the moment of the click.

 @param position : `Model space, already snapped inside the mesh.`
 @return `The id of the placed dot.`
*>
fn uint AppState.place(&self, Vec3 position)
{
	uint anchor = self.selected;

	uint id = self.add_recorded(position);
	if (self.doc.auto_connect && anchor != 0) self.connect_recorded(anchor, id);

	self.undo_stack.commit();
	self.mark_rig_stale();
	self.select(id);
	return id;
}

<*
 Deletes a dot and everything hanging off it.

 The incident edges are recorded *before* the dot, so undo replays them after
 it: an edge naming a dot that is not back yet is one `connect` rejects, and the
 bones would be quietly lost.
*>
fn void AppState.remove(&self, uint id)
{
	if (!self.remove_recorded(id)) return;
	self.undo_stack.commit();
	self.mark_rig_stale();
	self.forget_stale_ids();
}

<*
 Takes one dot and its bones out, recording both and leaving the group open.

 The uncommitted half of `remove`, so a caller deleting several dots closes the
 group once and one Ctrl+Z brings all of them back. A caller using this owes
 the document a `commit`, a `mark_rig_stale` and a `forget_stale_ids` — the
 selection and the root may both name a dot that has just gone.

 @return `False when no dot has that id, in which case nothing was recorded.`
*>
fn bool AppState.remove_recorded(&self, uint id)
{
	Dot* dot = self.doc.find(id);
	if (!dot) return false;
	Vec3 position = dot.position;
	float reach = dot.reach;
	String dot_name = (String)@clone_slice((char[])dot.name);

	foreach (edge : self.doc.edges.array_view())
	{
		if (edge.a == id || edge.b == id)
		{
			self.undo_stack.record({ .kind = DELETE_EDGE, .id = edge.a, .other = edge.b });
		}
	}

	uint previous_root = self.doc.root_id;
	self.doc.remove_dot(id);
	self.undo_stack.record({
		.kind = DELETE_DOT,
		.id = id,
		.before = position,
		.other = previous_root,
		.name = dot_name,
		.reach_before = reach,
	});
	return true;
}

<*
 Deletes every selected dot as one edit.

 	`usz gone = app.remove_selection();`

 One commit for the whole group, so deleting five dots is one Ctrl+Z — the same
 bargain a body plan makes when it places seventeen. The ids are taken as a
 snapshot first, because each removal rewrites the selection underneath.

 @return `How many dots went, which is 0 when nothing was selected.`
*>
fn usz AppState.remove_selection(&self)
{
	uint[] ids = self.selection_ids(mem);
	defer if (ids.len > 0) alloc::free(mem, ids);
	if (ids.len == 0) return 0;

	usz gone = 0;
	foreach (id : ids)
	{
		if (self.remove_recorded(id)) gone++;
	}
	if (gone == 0) return 0;

	self.undo_stack.commit();
	self.mark_rig_stale();
	self.forget_stale_ids();
	return gone;
}

<*
 Lines the rest of the selection up with the anchor on one axis (Align X/Y/Z).

 	`usz moved = app.align_selection_to_anchor(0); // onto the anchor's X`

 Every other selected dot takes the anchor's coordinate on `component` and keeps
 its own on the other two, so a row of spine joints snaps onto the anchor's
 centreline without disturbing their heights. The anchor itself never moves — it
 is the thing being aligned to. One commit for the group, so a whole alignment is
 one Ctrl+Z, and a dot already on the line records nothing.

 The move is exact, not walked through the mesh like a drag: aligning is a
 deliberate "put these here", and clamping them back inside the body is the
 opposite of what makes a joint that was awkward to place by hand easy to place by
 button.

 @param component : `0 for X, 1 for Y, 2 for Z.`
 @return `How many dots moved; 0 when fewer than two are selected or none were off the line.`
*>
fn usz AppState.align_selection_to_anchor(&self, int component)
{
	if (component < 0 || component > 2) return 0;
	Dot* anchor = self.doc.find(self.selected);
	if (!anchor || self.also_selected.len() == 0) return 0;

	float target = anchor.position[component];
	usz moved = 0;
	foreach (id : self.also_selected.array_view())
	{
		Dot* dot = self.doc.find(id);
		if (!dot || dot.position[component] == target) continue;
		Vec3 to = dot.position;
		to[component] = target;
		if (self.move_recorded(id, dot.position, to)) moved++;
	}
	if (moved == 0) return 0;

	self.undo_stack.commit();
	self.mark_rig_stale();
	self.refresh_pose_display();
	return moved;
}

<*
 Drops the one selected joint onto the mesh's bounding-box centre.

 The button for the joint that is a nuisance to drag to the middle — a hip root, a
 spine base — where the centre is deep inside the body and the pointer has no
 surface there to aim at. One joint only: centring several would stack them all on
 the same point, which is never the move. Exact, like the axis aligns, and one
 Ctrl+Z.

 @return `False when the selection is not exactly one joint, the mesh is empty, or the joint is already at the centre.`
*>
fn bool AppState.center_selected_on_mesh(&self)
{
	if (self.selected == 0 || self.also_selected.len() != 0) return false;
	if (self.geometry.positions.len == 0) return false;
	Dot* dot = self.doc.find(self.selected);
	if (!dot) return false;

	Vec3 center = self.geometry.bounds().center();
	if (dot.position == center) return false;
	if (!self.move_recorded(self.selected, dot.position, center)) return false;

	self.undo_stack.commit();
	self.mark_rig_stale();
	self.refresh_pose_display();
	return true;
}

<*
 Rotates the whole skeleton around the model's centre as one undo step.
 The mesh stays fixed and saved limit frames turn with the joints.
*>
fn usz AppState.rotate_skeleton(&self, int axis, float radians)
{
	if (axis < 0 || axis > 2 || !math::is_finite(radians) || self.doc.dots.len() == 0) return 0;
	Vec3 pivot = self.geometry.positions.len > 0
		? self.geometry.bounds().center()
		: self.doc.dots[0].position;
	TransformTarget target = { .kind = SKELETON_TARGET, .joint_count = (usz)self.doc.dots.len() };
	if (!self.begin_transform_target(ROTATE_TRANSFORM, target, GLOBAL_SPACE, MEDIAN_PIVOT, &pivot)) return 0;
	Vec3 turn_axis = {};
	turn_axis[axis] = 1.0f;
	if (!self.update_transform_rotation_axis(turn_axis, radians))
	{
		(void)self.cancel_transform();
		return 0;
	}

	usz moved = 0;
	foreach (point : self.transform_transaction.points)
	{
		Dot* dot = self.doc.find(point.dot_id);
		if (dot && dot.position != point.position) moved++;
	}
	if (moved == 0)
	{
		(void)self.cancel_transform();
		return 0;
	}
	return self.commit_transform() ? moved : 0;
}

<*
 One source dot and the dot on the other side that answers to it.
*>
struct MirrorPair @local
{
	uint source;
	uint twin;     // 0 when no twin was found — the source is left alone and warned about
	Vec3 at;       // where the twin belongs
	bool squared;  // an existing twin that something had to be written to
	bool made;     // created here rather than moved into place — see mirror_create_selection
	bool name_sides; // a source with no side in its name: both get one by where they fall
}

alias MirrorPairList = List{MirrorPair};

<*
 Pair every selected dot with the dot on the other side of the plane.

 Planned whole before anything is written, because wiring the bones needs to
 know every twin — including the ones belonging to sources later in the list —
 and because a source that turns out to be an earlier source's twin has to drop
 out before it overwrites the dot that just claimed it; the earlier dot in order
 wins, so a select-all does not have the two halves fight over each other.

 A dot on the plane is its own reflection and is left out, counted in `no_side`
 with `create` for the caller to warn about. With `create`, a dot that has no twin
 and no side in its name is marked `name_sides`: it and its new twin are named by
 which side of the plane they fall on — see `side_names`.
*>
fn void AppState.plan_mirror(&self, MirrorPairList* plan, uint[] ids, Vec3 plane_point, Vec3 plane_normal,
	float on_plane, bool create, usz* no_side)
{
	foreach (id : ids)
	{
		Dot* dot = self.doc.find(id);
		if (!dot) continue;
		if (math::abs((dot.position - plane_point).dot(plane_normal)) <= on_plane)
		{
			if (create) (*no_side)++;
			continue;
		}

		bool claimed = false;
		foreach (planned : plan.array_view()) if (planned.twin == id) claimed = true;
		if (claimed) continue;

		Vec3 at = reflect_across(dot.position, plane_point, plane_normal);
		uint twin = self.twin_of(*dot, at, on_plane);

		// No twin to move and no side in the name to build one under: both sides
		// are named by where they fall before the twin is made.
		bool name_sides = false;
		if (create && twin == 0)
		{
			String want = dot.name.len > 0 ? mirror_name(mem, dot.name) : "";
			defer if (want.len > 0) alloc::free(mem, want.ptr);
			name_sides = want.len == 0;
		}

		plan.push({ .source = id, .twin = twin, .at = at, .name_sides = name_sides });
	}
}

<*
 Pull an existing twin into line and hand it the source's reach.

 Anything above float-reflection noise is a twin out of line. A rig fitted from a
 plan lands its twins a fraction of a micron apart where the arithmetic rounds
 differently on the two sides; pulling those records an edit and reads as "not
 yet mirrored" on a rig that plainly is, so the move is taken only past a hair of
 the figure's own size.

 The reach crosses whether or not the twin had to move. A pair can sit perfectly
 square about the plane and still have had one side reined in, and that is a
 difference no amount of moving carries across.

 @return `Whether anything was written to the twin.`
*>
fn bool AppState.square_twin(&self, MirrorPair* pair, float reach)
{
	Dot* twin = self.doc.find(pair.twin);
	if (!twin) return false;

	bool wrote = false;
	if ((twin.position - pair.at).length() > self.picker.scale * 1.0e-5f)
	{
		Vec3 from = twin.position;
		if (self.doc.move_dot(pair.twin, pair.at))
		{
			self.undo_stack.record({ .kind = MOVE_DOT, .id = pair.twin, .before = from, .after = pair.at });
			wrote = true;
		}
	}
	if (self.set_reach_recorded(pair.twin, reach)) wrote = true;
	return wrote;
}

<*
 Carry each source's limits and paint onto its twin, once every twin exists.

 The limits go on the twin's own bone: a joint's axes come off the bone below it,
 and the twin carries the source's table reflected. One build for every pair,
 which a table edit does not disturb. The paint needs one lookup over the mesh
 for every pair, built only when some source carries a correction — a rig with no
 paint on it should not pay for a sort of its vertices.

 A twin made by this mirror is new either way; an existing one written to here is
 marked `squared`.

 @return `Whether any paint or pins crossed.`
*>
fn bool AppState.mirror_crossings(&self, MirrorPair[] plan, float on_plane, Vec3 plane_point, Vec3 plane_normal)
{
	RigView? opened = self.open_rig(mem);
	if (try opened)
	{
		RigView view = opened;
		defer view.free(mem);
		foreach (&pair : plan)
		{
			if (pair.twin == 0) continue;
			if (self.mirror_limits_recorded(&view, pair.source, pair.twin, plan, on_plane, plane_point, plane_normal))
			{
				if (!pair.made) pair.squared = true;
			}
		}
	}

	bool paint_touched = false;
	if (self.doc.paint.len() > 0 || self.doc.pins.len() > 0)
	{
		rig::MirrorLookup across = rig::build_mirror_lookup(mem, self.geometry.positions,
			plane_point, plane_normal, on_plane);
		defer across.free(mem);
		foreach (&pair : plan)
		{
			if (pair.twin == 0) continue;
			if (self.mirror_paint_recorded(&across, pair.source, pair.twin))
			{
				if (!pair.made) pair.squared = true;
				paint_touched = true;
			}
		}
	}
	return paint_touched;
}

<*
 Reflects every selected dot across the symmetry plane, pulling the twin that
 already exists into line — and warning about a source that has none, never
 placing a joint.

 	`usz moved, unmatched; app.mirror_selection(&moved, null, &unmatched);`

 The repair a symmetry plane is for: select a side of a rig that already has
 both and this squares the other side up against it — which no amount of weight
 work can substitute for, since an arm 22% longer than its partner binds to 42%
 more of the mesh, and both numbers come straight from where the dots sit.

 **Mirror never creates a joint.** A source whose twin is not there is left
 alone and counted as unmatched, for the caller to warn about — it is not the
 place a second side is built, because a mirror that spawns dots turns a mistyped
 name or a half-named rig into a litter of stray joints. Build both sides, or
 name them, first; then Mirror lines them up.

 **The selection is the side that survives.** Every selected dot is a source and
 its twin is overwritten, so mirroring the wrong half moves the good one. A dot
 already claimed as some earlier source's twin is not itself used as a source,
 which is what keeps a select-all from having the two halves fight over each
 other; with both sides selected the earlier dot in document order wins.

 **A twin is found by name where there is one.** `thigh_L` looks for `thigh_R`
 however far it has drifted, which is the only way a snap can find a partner
 that is in the wrong place — that being the whole point. `mirror_name` reads
 the conventions a rig can arrive wearing rather than crig's own alone, because
 an imported figure is named after the pack it matched: a rig off a downloaded
 Mixamo pack spells its wrist `mixamorig:LeftHand`, and reading only `_L` would
 have made every joint on it look like a joint with no other side.

 A name that still names no side has no handle, and is matched by position
 instead — within the same tolerance a mirrored placement uses; a hand-placed
 pair that has drifted further than that has no twin found and is warned about
 rather than pulled. Naming the rig from a body plan is what makes the repair
 reliable.

 **A reach crosses with the dot.** Whatever limit a source carries, its existing
 twin is given the same one, overwriting its own the way its position is. A rig
 reined in down one side and mirrored is symmetric in what it binds as well as
 in where it sits, which is the only reading of symmetry that survives to the
 skin. A twin already square about the plane is still worth mirroring for this
 alone, so a call that moves nothing can still report dots pulled into line.

 **And so does the hand-painted weight.** Every dab and every pin the source
 carries is set on the twin at the mirror-image vertex — the one sitting at the
 vertex's reflection, within the same tolerance — and whatever the twin
 carried on vertices the source does not is taken off, the same overwrite its
 position and reach get. A correction painted down one side and mirrored is
 the same correction on both, which is the only reason to paint one side
 first. A vertex with no partner on the other side — an asymmetric patch, a
 seam split on one side only — is left as the twin had it, since the source
 says nothing about it; and the paint alone counts as pulling a twin into
 line, like the reach does. See `mirror_paint_recorded`.

 **So do the rotation limits, reflected.** A joint's table is a box in its own
 bone-local axes, and a mirror is not the identity on those: the knee flexes
 the same way on both legs, but a hip's twist and its abduction run the other
 way round. `mirrored_rotation_limits` reads the source's box against the
 twin's own frame — its primary child crossing as that child's twin — so a rig
 reined in down one side moves the same in a mirror as well as binding the
 same. On the reach's terms: a source with no limits clears its twin's, and a
 source whose axes cannot be derived — a fork that has not chosen its child —
 carries nothing, since a table with no axes has no reflection.

 Dots on the plane itself are left alone: they are their own reflection, and a
 spine has no other side to be placed on.

 The twin is put at the exact reflection and not snapped back inside the mesh,
 the same bargain a mirrored placement makes — a symmetric mesh needs no snap
 and an asymmetric one has no honest place to snap to.

 A twin already exactly where it belongs, reach and all, needs nothing and is
 counted apart: a selection whose other side is in place is not a selection
 with nothing off the plane, and the notice should not tell someone who just
 mirrored a rig to select something else.

 @param moved : `Receives how many existing twins were pulled into line, if given.`
 @param square : `Receives how many twins were already in place and left as they were, if given.`
 @param unmatched : `Receives how many selected sources had no twin to mirror onto, if given, so a notice can warn.`
 @param painted : `Receives whether any paint or pins crossed, if given, so a notice can say so.`
 @return `How many twins were pulled into line, which is 0 when nothing was selected, every twin was already in place, or no twin was found.`
*>
fn usz AppState.mirror_selection(&self, usz* moved = null, usz* square = null, usz* unmatched = null,
	bool* painted = null)
{
	if (square) *square = 0;
	if (unmatched) *unmatched = 0;
	if (painted) *painted = false;
	uint[] ids = self.selection_ids(mem);
	defer if (ids.len > 0) alloc::free(mem, ids);
	if (ids.len == 0) return 0;

	float on_plane = self.picker.scale * MIRROR_EPSILON;

	// The plane to reflect across, read off the rig — a point and a unit normal.
	// `doc.sym_x` is only the world-aligned fallback: the mesh's bounding-box
	// centre, which a lopsided mesh pulls off the midline, and whose plane faces
	// straight down world X whatever way the body is turned. `mirror_plane` reads
	// the real midline off the centre joints and the real left-right axis off the
	// pairs, so a twin lands where the *body*'s other side is — square across for
	// a forward-facing rig, around the back for a turned one. It stays bit-exact
	// world-aligned for a near-square rig, so one already mirrored records nothing.
	Vec3 plane_point;
	Vec3 plane_normal;
	self.mirror_plane(&plane_point, &plane_normal, on_plane);

	MirrorPairList plan;
	plan.init(mem);
	defer plan.free();
	self.plan_mirror(&plan, ids, plane_point, plane_normal, on_plane, false, null);

	// Whether a twin was moved or given a reach — the edits that move the skeleton
	// under the bind, as against a limit table, which only reads it.
	bool rig_touched = false;

	foreach (&pair : plan.array_view())
	{
		// No twin: the source is left exactly as it is and counted at the end for
		// the warning. Mirror moves an existing joint, it does not make one.
		if (pair.twin == 0) continue;

		Dot* dot = self.doc.find(pair.source);
		if (!dot) continue;
		if (self.square_twin(pair, dot.reach))
		{
			pair.squared = true;
			rig_touched = true;
		}
	}

	bool paint_touched = self.mirror_crossings(plan.array_view(), on_plane, plane_point, plane_normal);

	usz pulled = 0;
	usz already = 0;
	usz missing = 0;
	foreach (pair : plan.array_view())
	{
		if (pair.twin == 0) { missing++; continue; }
		if (pair.squared) { pulled++; } else { already++; }
	}

	if (square) *square = already;
	if (unmatched) *unmatched = missing;
	if (pulled == 0) return 0;

	self.undo_stack.commit();
	if (rig_touched) self.mark_rig_stale();
	// The lighter mark when only paint crossed: the bind underneath is the one
	// that was already there, and the view can have the result at once.
	if (paint_touched && !rig_touched) self.mark_paint_stale();
	if (moved) *moved = pulled;
	if (painted) *painted = paint_touched;
	return pulled;
}

<*
 Builds the other side of every selected dot — creating the twin where the rig
 has none yet, and moving one into line where it does.

 	`usz made, moved, skipped; app.mirror_create_selection(&made, &moved, null, &skipped);`

 The making counterpart to `mirror_selection`, and the deliberate act that one
 deliberately is not: where the M-key mirror lines an existing twin up and
 refuses to invent one, this is the operation that *does* invent it. A selected
 `elbow_R` with no `elbow_L` becomes an `elbow_L` at the reflected position,
 named by `mirror_name`, wired to the mirror of whatever the source was bonded
 to, and carrying the source's reach, rotation limits and hand paint across. It
 is reached from the viewport's context menu, so a joint it makes is one the user
 asked for by name rather than one a mistyped rig spawned behind their back.

 **A twin that already exists is moved, not duplicated.** `twin_of` finds it by
 name, so running this twice squares the side up the second time rather than
 leaving a second `elbow_L` beside the first — the same overwrite
 `mirror_selection` makes, reach and limits and paint included.

 **A joint with no side is named first.** A dot whose name carries no side — or
 no name at all — and no twin to move gets one by where it falls: `joint_7` on
 the left becomes `joint_7_L` and its new twin `joint_7_R` (`side_names`), in the
 same undo step. A dot on the plane is its own reflection and is skipped and
 counted for the caller to warn about.

 The plane, its tilt-awareness, the reflected placement, and the limit and paint
 crossing are all `mirror_selection`'s — see there. The one thing added is the
 creation: `add_recorded` at the reflection, its reach carried by
 `set_reach_recorded`, and the mirrored bones wired with `mirrored_end` once
 every twin exists. The whole group commits as one edit, so a mirror is one
 Ctrl+Z.

 @param made : `Receives how many twins were created, if given.`
 @param moved : `Receives how many existing twins were pulled into line, if given.`
 @param already : `Receives how many existing twins were already in place, if given.`
 @param skipped : `Receives how many selected dots sat on the centre line, if given.`
 @param painted : `Receives whether any paint or pins crossed, if given.`
 @param named : `Receives how many sources were given a side in their name, if given.`
 @return `How many dots were created or moved — 0 when nothing was.`
*>
fn usz AppState.mirror_create_selection(&self, usz* made = null, usz* moved = null, usz* already = null,
	usz* skipped = null, bool* painted = null, usz* named = null)
{
	if (named) *named = 0;
	if (made) *made = 0;
	if (moved) *moved = 0;
	if (already) *already = 0;
	if (skipped) *skipped = 0;
	if (painted) *painted = false;

	uint[] ids = self.selection_ids(mem);
	defer if (ids.len > 0) alloc::free(mem, ids);
	if (ids.len == 0) return 0;

	float on_plane = self.picker.scale * MIRROR_EPSILON;

	// Read off the rig's existing symmetric pairs, not its centre joints: building a
	// side reflects across where the rig is already symmetric, and a square pair
	// pins that plane exactly — where a centre-joint centroid is dragged off the
	// midline by any un-sided limb joint (a finger named `ring_f`, an `elbow` with
	// no `_r`). The selection is excluded so the pair being built against does not
	// define its own plane. See `mirror_plane_for_new`.
	Vec3 plane_point;
	Vec3 plane_normal;
	self.mirror_plane_for_new(ids, &plane_point, &plane_normal, on_plane);

	MirrorPairList plan;
	plan.init(mem);
	defer plan.free();
	usz no_side = 0;
	self.plan_mirror(&plan, ids, plane_point, plane_normal, on_plane, true, &no_side);

	// Whether a twin was created, moved or given a reach — the edits that move the
	// skeleton under the bind, as against a limit table, which only reads it.
	bool rig_touched = false;

	// Build or move each twin. Creation first, so every twin exists before the
	// bones below are wired to them.
	usz sided = 0;
	foreach (&pair : plan.array_view())
	{
		Dot* dot = self.doc.find(pair.source);
		if (!dot) continue;
		float reach = dot.reach;

		if (pair.twin == 0)
		{
			String name;
			if (pair.name_sides)
			{
				String own;
				self.side_names(pair.source, plane_point, plane_normal, &own, &name);
				defer alloc::free(mem, own.ptr);
				if (self.rename_recorded(pair.source, own)) sided++;
			}
			else
			{
				name = mirror_name(mem, dot.name);
			}
			defer if (name.len > 0) alloc::free(mem, name.ptr);

			pair.twin = self.add_recorded(pair.at, name);
			pair.made = true;
			rig_touched = true;

			// A separate edit rather than an argument to the add, because undo walks
			// the group backwards: this reverts first and the add deletes the dot
			// after it, which is also the order a redo needs.
			if (reach > 0.0f) self.set_reach_recorded(pair.twin, reach);
			continue;
		}

		if (self.square_twin(pair, reach)) pair.squared = true;
		if (pair.squared) rig_touched = true;
	}

	// The bones, once every twin exists: an edge between two sources becomes the
	// edge between their twins, and one reaching a dot that stays put — a spine,
	// anything off the selection — reaches that same dot from the other side. Every
	// incident edge is read before any is added, since connecting appends to the
	// same list this walks.
	List{uint} wire_a;
	wire_a.init(mem);
	defer wire_a.free();
	List{uint} wire_b;
	wire_b.init(mem);
	defer wire_b.free();
	foreach (pair : plan.array_view())
	{
		if (!pair.made) continue;
		foreach (edge : self.doc.edges.array_view())
		{
			uint other = edge.a == pair.source ? edge.b : (edge.b == pair.source ? edge.a : 0);
			if (other == 0) continue;

			uint end = self.mirrored_end(other, plan.array_view(), on_plane, plane_point, plane_normal);
			// `mirrored_end` hands back the far end itself when it has no twin. That
			// is right for a centre joint the two sides share — an arm rooted on the
			// spine reaches the same spine from the left — but for an off-plane
			// original it would sling a bone straight across the body from the new
			// joint back to the one it was copied from. Leave those off: the mirrored
			// chain wires to its own twins and to the midline, never back to the side
			// it mirrored.
			if (end == other)
			{
				Dot* far = self.doc.find(other);
				if (far == null) continue;
				if (math::abs((far.position - plane_point).dot(plane_normal)) > on_plane) continue;
			}
			wire_a.push(pair.twin);
			wire_b.push(end);
		}
	}
	foreach (i, from : wire_a.array_view()) self.connect_recorded(from, wire_b[i]);

	// The limits and paint, on each twin — the created ones included.
	bool paint_touched = self.mirror_crossings(plan.array_view(), on_plane, plane_point, plane_normal);

	usz created = 0;
	usz pulled = 0;
	usz settled = 0;
	foreach (pair : plan.array_view())
	{
		if (pair.made) { created++; }
		else if (pair.squared) { pulled++; }
		else if (pair.twin != 0) { settled++; }
	}

	if (already) *already = settled;
	if (skipped) *skipped = no_side;
	if (created + pulled == 0) return 0;

	self.undo_stack.commit();
	if (sided > 0) self.plan_targets_stale = true;
	if (named) *named = sided;
	if (rig_touched) self.mark_rig_stale();
	// The lighter mark when only paint crossed: the bind underneath is the one
	// that was already there, and the view can have the result at once.
	if (paint_touched && !rig_touched) self.mark_paint_stale();
	if (made) *made = created;
	if (moved) *moved = pulled;
	if (painted) *painted = paint_touched;
	return created + pulled;
}

<*
 Names for a joint with no side in its name and for the twin about to be built
 for it, by which side of the plane it falls on.

 	`joint_7` on the left → `joint_7_L`, twin `joint_7_R`; an unnamed joint → `joint_<id>_L`

 Which side is "left" and the letter case are read off the rig's own sided names
 (a rig spelled `hand_l` gets `_l`); with none, `fit_preset`'s `_L` on +X. A base
 whose names are taken gets a number (`joint_7_2_L`).

 @param source : `Receives the source's new name; the caller owns it.`
 @param twin : `Receives the twin's name; the caller owns it.`
*>
fn void AppState.side_names(&self, uint id, Vec3 plane_point, Vec3 plane_normal, String* source, String* twin)
{
	int votes = 0;
	bool lower = false;
	bool cased = false;
	foreach (dot : self.doc.dots.array_view())
	{
		char side = name_side(dot.name);
		if (side == 0) continue;
		if (!cased)
		{
			lower = side == 'l' || side == 'r';
			cased = true;
		}
		float s = (dot.position - plane_point).dot(plane_normal);
		if (s == 0.0f) continue;
		bool is_left = side == 'L' || side == 'l';
		votes += (s > 0.0f) == is_left ? 1 : -1;
	}
	bool left_positive = votes >= 0;

	Dot* dot = self.doc.find(id);
	float s = dot ? (dot.position - plane_point).dot(plane_normal) : 0.0f;
	bool on_left = (s > 0.0f) == left_positive;
	String own_letter = lower ? (on_left ? "l" : "r") : (on_left ? "L" : "R");
	String twin_letter = lower ? (on_left ? "r" : "l") : (on_left ? "R" : "L");

	String base = dot && dot.name.len > 0
		? (String)alloc::clone_slice(mem, (char[])dot.name)
		: string::format(mem, "joint_%d", id);
	defer alloc::free(mem, base.ptr);

	for (int n = 1;; n++)
	{
		String suffix = n == 1 ? "" : string::tformat("_%d", n);
		String a = string::format(mem, "%s%s_%s", base, suffix, own_letter);
		String b = string::format(mem, "%s%s_%s", base, suffix, twin_letter);
		if (self.dot_named(a) == null && self.dot_named(b) == null)
		{
			*source = a;
			*twin = b;
			return;
		}
		alloc::free(mem, a.ptr);
		alloc::free(mem, b.ptr);
	}
}

<*
 The rig's own left-right symmetry plane, read off its centre joints.

 	`if (app.symmetry_plane(&x)) { … }`

 The mesh's bounding-box centre is a poor guess at the midline — a tail, a wing
 or an off-centre export throws it off, and a hand-built rig on no mesh has none.
 The rig knows better: a centre joint, one whose name carries no side, sits on
 the midline whatever the mesh is shaped like, so the plane is the average of
 every centre joint's X.

 The limb **pairs** are deliberately left out. A pair's midpoint is the plane
 only when the pair is already square — and a crooked pair, whose midpoint sits
 off to one side, is exactly what Mirror is there to fix. Deriving the plane
 from the pairs would move it to meet the crookedness instead of squaring the
 crookedness up to the plane. The centre line, which no limb can shift, is the
 one signal that stays put.

 @param out : `Receives the plane's model-space X when one was found.`
 @return `False when the rig has no centre joint to read a plane from, out untouched.`
*>
fn bool AppState.symmetry_plane(&self, float* out)
{
	// The pairs the survey also reads are left out here — see above.
	MirrorSurvey survey = self.mirror_survey();
	if (survey.centres == 0) return false;
	*out = survey.centre_point().x;
	return true;
}

<*
 Cross one dot's paint and pins onto its twin, as the mirror's own strokes.

 	`if (app.mirror_paint_recorded(&across, thigh_L, thigh_R)) …`

 Two batches, one per layer, each recorded through the layer's own stroke
 record and left chained — the caller commits, so the paint undoes with the
 twin it was painted onto rather than as a step of its own. What the twin ends
 up carrying is exactly the source's layer reflected: a dab the source has
 lands on the twin at the mirror-image vertex, and a dab the twin had on a
 vertex whose partner the source leaves clean is cleared. Vertices with no
 partner are not touched either way.

 The clears are found by walking the twin's entries against the wanted set
 rather than by clearing everything and writing it back, so a twin already
 carrying the right paint records nothing — which is what lets the caller
 count it as already in place.

 @param across : `The mesh's mirror lookup, built for the document's plane.`
 @return `True when anything on either layer moved.`
*>
fn bool AppState.mirror_paint_recorded(&self, rig::MirrorLookup* across, uint source, uint twin)
{
	usz count = self.geometry.positions.len;
	if (count == 0 || source == twin) return false;

	// Which vertices the source's layer reaches on the twin, so the twin's own
	// entries can be told apart from the ones about to be written. One flag
	// per vertex rather than a search per entry.
	bool[] wanted = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, wanted);

	bool moved = false;

	// --- dabs ----------------------------------------------------------------
	{
		sz held = self.doc.paint.len();
		PaintDab[] batch = alloc::new_array(mem, PaintDab, held);
		defer alloc::free(mem, batch);
		usz asked = 0;

		foreach (dab : self.doc.paint.array_view())
		{
			if (dab.dot_id != source || (usz)dab.vertex >= count) continue;
			sz partner = across.twin_of(self.geometry.positions[dab.vertex]);
			if (partner < 0) continue;
			wanted[partner] = true;
			batch[asked++] = { .vertex = (uint)partner, .dot_id = twin, .factor = dab.factor };
		}
		foreach (dab : self.doc.paint.array_view())
		{
			if (dab.dot_id != twin || (usz)dab.vertex >= count || wanted[dab.vertex]) continue;
			if (across.twin_of(self.geometry.positions[dab.vertex]) < 0) continue;
			batch[asked++] = { .vertex = dab.vertex, .dot_id = twin, .factor = 1.0f };
		}

		if (asked > 0)
		{
			PaintChange[] changes = alloc::new_array(mem, PaintChange, (sz)asked);
			defer alloc::free(mem, changes);
			usz changed = self.write_paint(batch[:asked], changes);
			if (changed > 0)
			{
				self.undo_stack.record_stroke(changes[:changed]);
				moved = true;
			}
		}
	}

	// --- pins ----------------------------------------------------------------
	wanted[..] = false;
	{
		sz held = self.doc.pins.len();
		VertexPin[] batch = alloc::new_array(mem, VertexPin, held);
		defer alloc::free(mem, batch);
		usz asked = 0;

		foreach (pin : self.doc.pins.array_view())
		{
			if (pin.dot_id != source || (usz)pin.vertex >= count) continue;
			sz partner = across.twin_of(self.geometry.positions[pin.vertex]);
			if (partner < 0) continue;
			wanted[partner] = true;
			batch[asked++] = { .vertex = (uint)partner, .dot_id = twin, .share = pin.share };
		}
		foreach (pin : self.doc.pins.array_view())
		{
			if (pin.dot_id != twin || (usz)pin.vertex >= count || wanted[pin.vertex]) continue;
			if (across.twin_of(self.geometry.positions[pin.vertex]) < 0) continue;
			batch[asked++] = { .vertex = pin.vertex, .dot_id = twin, .share = 0.0f };
		}

		if (asked > 0)
		{
			PaintChange[] changes = alloc::new_array(mem, PaintChange, (sz)asked);
			defer alloc::free(mem, changes);
			usz changed = self.write_pins(batch[:asked], changes);
			if (changed > 0)
			{
				self.undo_stack.record_pin_stroke(changes[:changed]);
				moved = true;
			}
		}
	}

	return moved;
}

// The dot on the other side that already answers to this one, or 0 for none.
//
// By name first and at any distance, since a twin that has drifted is exactly
// what a snap is for. A name that names no side is no handle at all — whether it
// is empty or spelled some way `mirror_name` cannot read — and falls back to
// position, then only within the tolerance a mirrored placement would have used:
// a wider net would start claiming the neighbouring joint.
//
// The narrow net is also what keeps that fallback from crossing back over. The
// caller has already skipped every dot within `tolerance` of the plane, so the
// reflection sits further than `tolerance` from it on the far side and nothing
// on the source's own side can be within `tolerance` of the reflection.
fn uint AppState.twin_of(&self, Dot dot, Vec3 at, float tolerance)
{
	String want = dot.name.len > 0 ? mirror_name(mem, dot.name) : "";
	defer if (want.len > 0) alloc::free(mem, want.ptr);

	if (want.len > 0)
	{
		foreach (other : self.doc.dots.array_view())
		{
			if (other.id != dot.id && other.name == want) return other.id;
		}
		return 0;
	}

	uint nearest = 0;
	float best = tolerance;
	foreach (other : self.doc.dots.array_view())
	{
		if (other.id == dot.id) continue;
		float gap = (other.position - at).length();
		if (gap > best) continue;
		best = gap;
		nearest = other.id;
	}
	return nearest;
}

// The joint across the symmetry plane from this one, or 0 for a joint on the
// plane or one with no twin. By name first, then by position — `twin_of`'s rule.
fn uint AppState.mirror_twin(&self, uint id)
{
	Dot* dot = self.doc.find(id);
	if (!dot) return 0;

	float on_plane = self.picker.scale * MIRROR_EPSILON;
	Vec3 point;
	Vec3 normal;
	self.mirror_plane(&point, &normal, on_plane);
	if (math::abs((dot.position - point).dot(normal)) <= on_plane) return 0;

	uint twin = self.twin_of(*dot, reflect_across(dot.position, point, normal), on_plane);
	return twin == id ? 0 : twin;
}

// A vertex lookup across the same plane `mirror_twin` reflects joints across.
fn rig::MirrorLookup AppState.mesh_mirror(&self, Allocator allocator)
{
	float on_plane = self.picker.scale * MIRROR_EPSILON;
	Vec3 point;
	Vec3 normal;
	self.mirror_plane(&point, &normal, on_plane);
	return rig::build_mirror_lookup(allocator, self.geometry.positions, point, normal, on_plane);
}

// Which dot an edge's far end — or a limit table's primary child — becomes on
// the other side: its twin when the mirror made or moved one, and otherwise
// itself — a bone reaching the spine from the left reaches the same spine from
// the right.
fn uint AppState.mirrored_end(&self, uint other, MirrorPair[] plan, float on_plane, Vec3 plane_point, Vec3 plane_normal)
{
	foreach (pair : plan)
	{
		if (pair.source == other) return pair.twin;
	}

	Dot* dot = self.doc.find(other);
	if (!dot) return other;
	if (math::abs((dot.position - plane_point).dot(plane_normal)) <= on_plane) return other;

	Vec3 at = reflect_across(dot.position, plane_point, plane_normal);
	uint twin = self.twin_of(*dot, at, on_plane);
	return twin != 0 ? twin : other;
}

// Gives a twin its source's rotation limits, read for the other side, leaving
// the group open. On the reach's terms: what the mirror writes is the source's
// setup, absence included, so a source with no table clears the twin's. A
// source whose axes cannot be derived carries nothing — see
// `mirrored_rotation_limits` — and the twin keeps what it had.
//
// @return `True when the twin's limits changed.`
fn bool AppState.mirror_limits_recorded(&self, RigView* view, uint source, uint twin, MirrorPair[] plan, float on_plane, Vec3 plane_point, Vec3 plane_normal)
{
	JointRotationLimits held = self.doc.rotation_limits_of(source);
	if (held.same(unconstrained_rotation(source)))
	{
		return self.set_rotation_limits_recorded(twin, unconstrained_rotation(twin));
	}

	uint primary = held.primary_child != 0 ? self.mirrored_end(held.primary_child, plan, on_plane, plane_point, plane_normal) : 0;
	JointRotationLimits mirrored;
	if (!mirrored_rotation_limits(&view.skeleton, view.dot_ids, held, twin, primary, &mirrored)) return false;
	return self.set_rotation_limits_recorded(twin, mirrored);
}

<*
 Records the removal of every dot in the document, leaving the group open.

 Same contract as `remove_recorded`, which it is a loop over: the caller
 commits. It exists for `apply_preset`, where clearing the old rig and placing
 the new one have to land in the history as one thing.

 @return `How many dots went.`
*>
fn usz AppState.clear_rig_recorded(&self)
{
	usz gone = 0;
	while (self.doc.dots.len() > 0)
	{
		// Always the first, since removing it shifts the rest down. A dot that
		// refuses to go would loop forever, so a failure ends the sweep.
		if (!self.remove_recorded(self.doc.dots[0].id)) break;
		gone++;
	}
	return gone;
}

<*
 Records a completed rest move — the grabbed dot and every mate dragged with it —
 as one edit.

 Called on release, not per frame: the drag re-snaps the dots on every mouse
 move, and one undo entry per pixel of travel is not a history anyone can use. A
 dot that finished where it began records nothing, so a group nudged and put back
 leaves the ledger alone; a group that moved is a single Ctrl+Z, the shape
 `remove_selection` and `mirror_selection` already use.

 Reads the gesture off `self.drag` and `self.drag_mates` rather than taking an id:
 a lone drag has no mates and lands exactly as it did before, and a group needs
 every dot in the one commit.
*>
fn void AppState.finish_move(&self)
{
	bool moved = false;

	Dot* lead = self.doc.find(self.drag.dot);
	if (lead && (lead.position - self.drag.from).length() > 0.0f)
	{
		self.move_recorded(self.drag.dot, self.drag.from, lead.position);
		moved = true;
	}

	foreach (mate : self.drag_mates.array_view())
	{
		Dot* dot = self.doc.find(mate.dot);
		if (!dot || (dot.position - mate.from).length() <= 0.0f) continue;
		self.move_recorded(mate.dot, mate.from, dot.position);
		moved = true;
	}

	if (!moved) return;
	self.undo_stack.commit();
	self.mark_rig_stale();
}

<*
 Rename a dot, as one undoable edit.

 	`app.rename(id, "thigh_L");`

 A name is the only way a clip can reach a joint — templates key on names, not on
 ids — so this is what turns a hand-placed chain into one an animation can drive,
 and what corrects a plan that named a limb the wrong side round.

 The rig itself does not move, so nothing is rebound. What does change is which
 body-plan target the dot answers to and which clips light up in the library,
 both of which are re-derived from names.

 @return `False when no dot has that id, or when it already carries that name.`
*>
fn bool AppState.rename(&self, uint id, String name)
{
	if (!self.rename_recorded(id, name)) return false;
	self.undo_stack.commit();

	self.plan_targets_stale = true;
	self.refresh_ui();
	return true;
}

// ---------------------------------------------------------------------------
// A move, from the grab to the release.
//
// The verbs below are the whole vocabulary: the viewport starts and ends one,
// the shortcut layer locks and cancels it, and the HUD reads it. Nothing else
// writes `drag`, so "is a move in progress" has one answer.
//
// There are three ways in — `begin_drag` moves a dot, `begin_pose` and
// `begin_turn` move a joint — and one way out either side, `cancel_drag` and
// `end_drag`, each branching on the verb. The axis lock and the escape are
// therefore written once and mean the corresponding thing for all three.

<*
 Grabs a rest-rig dot. Every move starts free — the axis is a decision the user
 makes with the dot already in hand, not before reaching for it.

 Mouse placement and animation posing share the regular viewport. On the posing
 stage a bare dot drag poses the joint, and this rest-position edit is reached
 with Alt held — the viewport's MOVE handler makes that call and only then
 reaches here.

 **The posed display is kept.** A moving rig dot used to stop the clip and drop
 the mesh back to its rest shape, so editing a joint threw away the pose the user
 was looking at and left them to replay the clip to get it back. Now the parked
 clip (or the manual draft) stays up and is re-solved against the edited rig as
 the dot moves — see `refresh_pose_display`, which the drag path calls on every
 move — so the mesh keeps the pose while the skeleton under it is shaped. The
 rest dot still snaps against the rest mesh, which is the one surface a joint's
 own position is measured in; only the *picture* over it stays posed.
*>
fn void AppState.begin_drag(&self, uint id)
{
	Dot* dot = self.doc.find(id);
	if (!dot) return;
	// Held, always: a rest move is only ever started by a press on the dot, and
	// the release is what ends it.
	self.drag = {
		.dot = id,
		.from = dot.position,
		.axis = DragAxis.FREE,
		.verb = DragVerb.PLACE,
		.held = true,
	};

	// Every other selected dot rides along, so one Alt-drag moves the whole
	// selection as a rigid piece — the grabbed dot leads and these translate by
	// the same delta (see `follow_drag_mates`). Only when the grabbed dot is
	// itself part of the selection: an Alt-drag begun on a dot outside it moves
	// that one dot alone, the way grabbing an unselected object does elsewhere.
	// The press keeps a multi-selection alive exactly so this can find it.
	self.drag_mates.clear();
	if (self.is_selected(id) && self.selection_count() > 1)
	{
		if (self.selected != id)
		{
			Dot* anchor = self.doc.find(self.selected);
			if (anchor) self.drag_mates.push({ .dot = self.selected, .from = anchor.position });
		}
		foreach (mate : self.also_selected.array_view())
		{
			if (mate == id) continue;
			Dot* other = self.doc.find(mate);
			if (other) self.drag_mates.push({ .dot = mate, .from = other.position });
		}
	}
}

<*
 Carries the mates of a group rest move along with the grabbed dot.

 The grabbed dot has already been moved for this frame — snapped through the mesh,
 or slid along its axis lock — and every mate translates by the same delta from
 where it was grabbed. Placing each at `from + delta` rather than nudging it by
 the per-move step keeps the group rigid however the lead's own path curves along
 the body, and re-derives cleanly after an axis lock re-projects the lead.

 Clamped inside the voxel grid like any rest dot, so a mate driven against the
 body's edge stops there; the group is otherwise a rigid slab.

 No `mark_rig_stale` per move: like a single drag, the rig is marked once at the
 release (`finish_move`), and dropping the geodesic bind cache on every mouse move
 would recompute it sixty times a second. The posed display is kept current a
 cheaper way — `refresh_pose_display` on the same move rebuilds only the palette.
*>
fn void AppState.follow_drag_mates(&self)
{
	if (self.drag.dot == 0 || self.drag_mates.len() == 0) return;
	Dot* lead = self.doc.find(self.drag.dot);
	if (!lead) return;

	Vec3 delta = lead.position - self.drag.from;
	foreach (mate : self.drag_mates.array_view())
	{
		self.doc.move_dot(mate.dot, clamp_inside(&self.voxels.grid, mate.from, mate.from + delta));
	}
}

<*
 One mouse move of a rest drag has landed the grabbed dot where the pointer put
 it. Bring the rest of the selection along, then re-solve whatever posed display
 is up so a clip parked over the rig keeps its pose as the skeleton is shaped
 under it.

 `refresh_pose_display` is a no-op when nothing is posed, which is the ordinary
 rig-editing case, so this costs a rest drag nothing extra. When a clip is parked
 or a draft is open it rebuilds the palette from the rig as it stands this frame —
 a playback frame's worth of work, not the geodesic rebind, which waits for the
 release.
*>
fn void AppState.drag_moved(&self)
{
	self.follow_drag_mates();
	self.refresh_pose_display();
}

<*
 Locks the move in progress to an axis, plane or bone direction, or unlocks it
 if it was already locked to that one — the way out is the key that was the way
 in. X/Y/Z are world-space for placing and G, bone-local for R; Shift+axis names
 a world plane, and B names the bone-local +Y direction.

 A rest-rig dot is put on the constraint immediately rather than at the next
 mouse move, so pressing the key is visibly the thing that did it. That
 projection is what makes the lock retroactive: excluded motion snaps back to
 the gesture start and only the line or plane keeps what the drag gave it.

 @return `False when nothing is being dragged, so the key can mean what it usually means.`
*>
fn bool AppState.lock_drag(&self, DragAxis axis)
{
	if (self.drag.dot == 0) return false;

	// A target drag has no joint: it takes the world axes and planes, but has no
	// bone frame to offer.
	bool aiming = self.drag.verb == DragVerb.AIM;
	if (aiming && axis == DragAxis.BONE) return true;
	Dot* dot = aiming ? null : self.doc.find(self.drag.dot);
	if (!dot && !aiming) return false;

	DragAxis next = self.drag.axis == axis ? DragAxis.FREE : axis;
	// A rotation owns one axis, never a plane. Shift+X/Y/Z deliberately keeps
	// the corresponding local rotation axis rather than inventing a two-axis
	// rotation whose pointer sweep would not define an order for.
	if (self.drag.verb == DragVerb.TURN && next.is_plane()) return true;

	Vec3 direction;
	if (next.is_direction())
	{
		Vec3? resolved = self.drag_lock_direction(next);
		if (catch resolved)
		{
			self.@notice("this joint has no stable bone axis for that lock");
			return true;
		}
		direction = resolved;
	}

	self.drag.axis = next;
	self.drag.lock_direction = direction;

	// A turn reads the same three keys as the axis it spins about, not as a line
	// to travel along — the second reading of one key that Blender's `R` then `X`
	// also gives it. Reapply the complete sweep from the gesture snapshot now:
	// switching X to Z therefore cannot accumulate an X turn underneath the Z
	// one, and the visual change does not wait for another mouse move.
	if (self.drag.verb == DragVerb.TURN)
	{
		Vec3 about = next == DragAxis.FREE
			? self.model_direction((self.camera.eye() - self.camera.target).normalize())
			: direction;
		self.turn_joint(about, self.drag.turned);
		return true;
	}

	// A pose move re-solves on the next mouse move, which is where the ray is.
	// The retroactive part still holds: the joint is left where it is until then,
	// and the solve that follows aims at a point on the constraint line through
	// the grab, so the two free coordinates come back on their own.
	if (self.drag.verb == DragVerb.POSE || self.drag.verb == DragVerb.AIM) return true;

	if (next.is_direction())
	{
		Vec3 delta = dot.position - self.drag.from;
		Vec3 onto = self.drag.from + direction * delta.dot(direction);
		self.doc.move_dot(self.drag.dot, clamp_inside(&self.voxels.grid, self.drag.from, onto));
		self.mark_rig_stale();
	}
	else
	{
		int component = next.plane_normal_component();
		if (component >= 0)
		{
			Vec3 onto = dot.position;
			onto[component] = self.drag.from[component];
			self.doc.move_dot(self.drag.dot, clamp_inside(&self.voxels.grid, self.drag.from, onto));
			self.mark_rig_stale();
		}
	}
	// The mates ride the lock too: the lead has just re-projected onto the line or
	// plane, so the group re-forms around its new spot rather than waiting for the
	// next mouse move to catch them up — and the posed display re-solves with them.
	self.drag_moved();
	return true;
}

<*
 Abandons the move: the dot goes back where it was grabbed and nothing is
 recorded, so the history never learns it happened.

 Undo would also put it back, but only after the move has become an edit — and
 a user who has just dragged a dot into the wrong leg wants it back before
 that, not a step to take afterwards.
*>
fn bool AppState.cancel_drag(&self)
{
	if (self.drag.dot == 0) return false;

	if (self.drag.verb == DragVerb.AIM)
	{
		self.cancel_aim_drag();
		return true;
	}

	if (self.drag.verb == DragVerb.PLACE)
	{
		self.doc.move_dot(self.drag.dot, self.drag.from);
		// Every mate the group move carried goes back to where it was grabbed too,
		// so escape abandons the whole slab, not just the dot under the pointer.
		foreach (mate : self.drag_mates.array_view())
		{
			self.doc.move_dot(mate.dot, mate.from);
		}
		self.drag = {};
		self.drag_mates.clear();
		self.mark_rig_stale();
		self.refresh_pose_display();
		return true;
	}

	// A pose gesture may have turned a whole chain, so putting it back means
	// walking the transient draft rather than restoring one value. Escape never
	// lands a clip replacement, so history never learns this happened.
	for (usz i = 0; i < self.pose_before_count; i++)
	{
		PosedJoint was = self.pose_before[i];
		self.set_working_pose(was.dot_id, was.rotation, was.offset);
	}
	// The anchored limbs the re-solve bent are put back the same way: escape undoes
	// the whole sit, the feet included.
	for (usz i = 0; i < self.locked_before_count; i++)
	{
		PosedJoint was = self.locked_before[i];
		self.set_working_pose(was.dot_id, was.rotation, was.offset);
	}
	// And everything a whole-body solve moved — the spine, the root's slide.
	foreach (was : self.gesture_before) self.set_working_pose(was.dot_id, was.rotation, was.offset);
	self.drop_gesture_before();
	self.drop_gesture_aim();
	self.turn_aimed_dot = 0;
	self.pose_before_count = 0;
	self.locked_before_count = 0;
	self.pose_mate_count = 0;
	self.drag = {};
	// The palette, not the binder: a pose moves no rest position, so the weights
	// underneath are the ones they always were.
	self.refresh_posed();
	return true;
}

<*
 Ends the move, banking it as one edit. A move that finished where it started
 records nothing.

 For a pose that is one edit per joint the gesture actually moved, chained
 together and committed once — so a bent leg is one Ctrl+Z rather than three,
 the same shape `remove_selection` and `mirror_selection` already use.
*>
fn void AppState.end_drag(&self)
{
	if (self.drag.dot == 0) return;

	if (self.drag.verb == DragVerb.AIM)
	{
		self.end_aim_drag();
		return;
	}

	if (self.drag.verb == DragVerb.PLACE)
	{
		self.finish_move();
		self.drag = {};
		self.drag_mates.clear();
		self.refresh_pose_display();
		return;
	}

	// Compared against the snapshot rather than recorded blind: a solve reports
	// every joint in the chain whether or not it turned any of them, and a
	// gesture that changed nothing must leave the history alone.
	bool banked = false;
	for (usz i = 0; i < self.pose_before_count; i++)
	{
		PosedJoint was = self.pose_before[i];
		PosedJoint now = self.working_pose(was.dot_id);
		if (now.rotation.v == was.rotation.v && now.offset == was.offset) continue;
		banked = true;
	}
	// The pinned limbs count too: a slide that only the anchors resolved — the
	// grabbed root moved a hair and every visible change is in the folded knees —
	// is still a sit worth keying.
	for (usz i = 0; i < self.locked_before_count && !banked; i++)
	{
		PosedJoint was = self.locked_before[i];
		PosedJoint now = self.working_pose(was.dot_id);
		if (now.rotation.v == was.rotation.v && now.offset == was.offset) continue;
		banked = true;
	}

	foreach (was : self.gesture_before)
	{
		if (banked) break;
		PosedJoint now = self.working_pose(was.dot_id);
		if (now.rotation.v != was.rotation.v || now.offset != was.offset) banked = true;
	}
	self.drop_gesture_before();
	self.drop_gesture_aim();
	self.turn_aimed_dot = 0;

	// The grabbed joint's own anchor follows it to where it was placed, so the next
	// unrelated gesture holds it here rather than snapping it back to the old spot.
	uint moved = self.drag.dot;
	self.pose_before_count = 0;
	self.locked_before_count = 0;
	self.pose_mate_count = 0;
	self.drag = {};
	if (banked && self.is_anchored(moved)) self.refresh_lock_target(moved);
	if (banked)
	{
		self.pose_edit_pending = true;
		if (self.auto_key)
		{
			(void)self.key_pose_edit(CHANGED);
			// Keying parks the same pose it was found against, so the contact
			// ring stays; the stamp moved with the park and is caught up here.
			self.last_block.shown_at = self.pose_generation;
		}
		else
		{
			self.refresh_ui();
		}
	}
}

<*
 How far the move in progress has carried the dot, per axis. Zero when nothing
 is being dragged.
*>
fn Vec3 AppState.drag_delta(&self)
{
	if (self.drag.dot == 0) return {};
	if (self.drag.verb == DragVerb.AIM)
	{
		return self.drag.aim < self.posed_aims.len ? self.posed_aims[self.drag.aim].at - self.drag.from : (Vec3){};
	}
	Dot* dot = self.doc.find(self.drag.dot);
	if (!dot) return {};
	return dot.position - self.drag.from;
}

<*
 Moves the root. Export BFSes from it, so this decides which way every bone
 points and which joint the whole skeleton hangs from.
*>
fn void AppState.set_root(&self, uint id)
{
	if (!self.root_recorded(id)) return;
	self.undo_stack.commit();

	// The root is not just a label: export BFSes from it, so moving it re-parents
	// every joint and re-cuts every weight.
	self.mark_rig_stale();
}

<*
 One pin of a whole piece: the named piece of the mesh rides the selected dot,
 or stops riding it if it already does.

 The verb a Shells pane's Pin button called, kept with its notices now that the
 pane is out for now: the mechanism is the useful half, and whatever face comes
 back for it starts here. The MCP wire's attach goes to `attach_recorded`
 directly, since a batch of ops is one Ctrl+Z and says its own result.

 Pinning the same pairing twice releases it, the way a second C on a chain
 takes it apart — the alternative is a pin that can be moved but never taken
 out. A released shell goes back to whatever the binder decides
 for it, which for an unreachable one is rigid on the bone that carries it.

 @param shell : `A shell id, as listed by AppState.shell_rows; negative is ignored.`
*>
fn void AppState.pin_shell(&self, int shell)
{
	if (shell < 0) return;

	if (self.selected == 0)
	{
		self.@notice("select the joint it should ride first");
		return;
	}

	uint before = self.doc.attachment_of((uint)shell);
	uint after = before == self.selected ? 0 : self.selected;

	if (!self.attach_recorded((uint)shell, after)) return;

	self.undo_stack.commit();
	self.mark_rig_stale();

	usz vertices = self.shells.size(shell);
	if (after == 0)
	{
		self.@notice("released %d vertices — automatic weights decide again", vertices);
		return;
	}

	Dot* dot = self.doc.find(after);
	String name = dot != null && dot.name.len > 0 ? dot.name : "that joint";
	self.@notice("%d vertices ride %s", vertices, name);
}

<*
 Bonds the selected dots into a chain, or takes that chain apart when it is
 already whole.

 	`bool removed; usz bones = app.connect_selection(&removed);`

 The chain runs in selection order — the anchor first, then the others in the
 order they were shift-clicked. Nothing about a set of positions says which end
 of a limb is which, so the click order is what decides: shift-click hip, knee,
 ankle, press C, and the two bones come out the way a leg is built.

 **The toggle is over the whole run, not per link.** With every consecutive pair
 already bonded the run comes out; otherwise only the missing links go in.
 Toggling each pair on its own would make a second C on a chain that was just
 built delete some links and bridge others, which is no operation anybody wants
 and not one that is easy to undo by eye.

 One commit either way, so five dots bonded is one Ctrl+Z.

 @param removed : `Set to true when the run was taken apart rather than built.`
 @return `How many bones changed; 0 when fewer than two dots are selected.`
*>
fn usz AppState.connect_selection(&self, bool* removed = null)
{
	if (removed) *removed = false;

	uint[] ids = self.selection_ids(mem);
	defer if (ids.len > 0) alloc::free(mem, ids);
	if (ids.len < 2) return 0;

	bool whole = true;
	for (usz i = 1; i < ids.len; i++)
	{
		if (!self.doc.has_edge(ids[i - 1], ids[i]))
		{
			whole = false;
			break;
		}
	}

	usz changed = 0;
	for (usz i = 1; i < ids.len; i++)
	{
		uint a = ids[i - 1];
		uint b = ids[i];
		if (whole)
		{
			self.doc.disconnect(a, b);
			self.undo_stack.record({ .kind = DELETE_EDGE, .id = a, .other = b });
		}
		else
		{
			// Already-bonded links are stepped over rather than counted: a run
			// is built here whether it was half there or not at all.
			if (!self.doc.connect(a, b)) continue;
			self.undo_stack.record({ .kind = ADD_EDGE, .id = a, .other = b });
		}
		changed++;
	}
	if (changed == 0) return 0;

	self.undo_stack.commit();
	self.mark_rig_stale();
	if (removed) *removed = whole;
	return changed;
}

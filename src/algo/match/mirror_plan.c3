<* The pure half of src/app/edit_ops.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::quaternion;
import std::collections::list;
import std::sort;

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
fn Vec3 reflect_across(Vec3 v, Vec3 point, Vec3 normal)
{
	return v - normal * (2.0f * (v - point).dot(normal));
}

<*
 What the named joints say about where the body's middle is, read once for
 every plane question: the centre joints (no side, so on the plane), and each
 named pair's left-to-right direction and midpoint.

 `exclude` leaves joints out — a pair with either side in it counts for nothing.
*>
struct MirrorSurvey
{
	Vec3 axis; // each pair's direction oriented to +x, summed (unit-weighted)
	Vec3 centre; // centre-joint positions, summed
	Vec3 midpoints; // pair midpoints, summed
	usz pairs;
	usz centres;
	// Every centre joint's position: what `plane_point` takes the median of.
	// Temp-allocated.
	List{Vec3} on_plane;
}

// Divided rather than scaled by a reciprocal: a square rig's plane is compared
// against the stored `sym_x` bit for bit, and `x / n` is what that was written as.
fn Vec3 MirrorSurvey.centre_point(self) => self.centre / (float)self.centres;

fn Vec3 MirrorSurvey.midpoint(self) => self.midpoints * (1.0f / (float)self.pairs);

<*
 Where the centre line passes, robustly: the median, axis by axis, of the
 centre joints. A curled tail of side-less joints is outvoted by the spine
 rather than averaged in — the mean let a tail four joints long pull the plane
 4 cm off a body 1 m tall.

 The pairs stay out, as they always have: a crooked pair is what Mirror is
 there to fix, and on a rig with one centre joint and one pair its midpoint
 would be half the vote. With an even count the two middle values are averaged,
 so neither side of a split wins by its sign; two equal middles — an
 already-square spine — give that value back exactly, and the plane still
 compares bit for bit.
*>
fn Vec3 MirrorSurvey.plane_point(self)
{
	usz n = (usz)self.on_plane.len();
	if (n == 0) return { };
	float[] axis = alloc::new_array(tmem, float, (sz)n);
	Vec3 out;
	for (usz c = 0; c < 3; c++)
	{
		foreach (usz i, p : self.on_plane) axis[i] = p[c];
		sort::quicksort(axis);
		out[c] = n % 2 == 1 ? axis[n / 2] : (axis[n / 2 - 1] + axis[n / 2]) * 0.5f;
	}
	return out;
}

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

fn bool plane_is_square(
	Vec3 n
) => math::abs(n.x) >= MIRROR_SQUARE_COS && math::abs(n.y) < 1.0e-6f && math::abs(n.z) < 1.0e-6f;

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
 One source dot and the dot on the other side that answers to it.
*>
struct MirrorPair
{
	uint source;
	uint twin; // 0 when no twin was found — the source is left alone and warned about
	Vec3 at; // where the twin belongs
	bool squared; // an existing twin that something had to be written to
	bool made; // created here rather than moved into place — see mirror_create_selection
	bool name_sides; // a source with no side in its name: both get one by where they fall
}

alias MirrorPairList = List{MirrorPair};

fn MirrorSurvey mirror_survey(RigDocument* doc, uint[] exclude = { })
{
	MirrorSurvey out;
	out.on_plane.init(tmem);
	foreach (dot : doc.dots.array_view())
	{
		if (dot.name.len == 0 || array::contains(exclude, dot.id)) continue;

		String twin = mirror_name(mem, dot.name);
		defer if (twin.len > 0) alloc::free(mem, twin.ptr);

		if (twin.len == 0)
		{
			// A centre joint, on the plane.
			out.centre = out.centre + dot.position;
			out.centres++;
			out.on_plane.push(dot.position);
			continue;
		}

		// A side joint: fold its pair in once, from the lower-id member.
		Dot* other = dot_named(doc, twin);
		if (other == null || other.id <= dot.id || array::contains(exclude, other.id)) continue;

		Vec3 span = dot.position - other.position;
		if (span.length() < 1.0e-6f) continue;
		// Unit-weighted, so a long limb and a short one count the same and one
		// crooked pair cannot swing the axis far.
		Vec3 dir = span.normalize();
		if (dir.x < 0.0f) dir = dir * -1.0f; // orient every pair to the +x side
		out.axis = out.axis + dir;
		out.midpoints = out.midpoints + (dot.position + other.position) * 0.5f;
		out.pairs++;
	}
	return out;
}

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
fn void mirror_plane_for_new(RigDocument* doc, uint[] exclude, Vec3* point, Vec3* normal, float on_plane)
{
	MirrorSurvey survey = mirror_survey(doc, exclude);
	Vec3 n              = survey.normal();

	// The point: the pairs' own midline first — a square pair's midpoint is on the
	// plane and no un-sided joint can pull it off — then the centre joints, then the
	// stored plane.
	Vec3 base;
	if (survey.pairs > 0)
	{
		base = survey.midpoint();
	}
	else if (survey.centres > 0)
	{
		base = survey.centre_point();
	}
	else
	{
		base = { doc.sym_x, 0, 0 };
	}

	if (plane_is_square(n))
	{
		float px = base.x;
		if (math::abs(px - doc.sym_x) <= on_plane) px = doc.sym_x;
		*point = { px, 0, 0 };
		*normal = { 1, 0, 0 };
		return;
	}
	*point = base;
	*normal = n;
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
fn void side_names(RigDocument* doc, uint id, Vec3 plane_point, Vec3 plane_normal, String* source, String* twin)
{
	int votes  = 0;
	bool lower = false;
	bool cased = false;
	foreach (dot : doc.dots.array_view())
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

	Dot* dot           = doc.find(id);
	float s            = dot ? (dot.position - plane_point).dot(plane_normal) : 0.0f;
	bool on_left       = (s > 0.0f) == left_positive;
	String own_letter  = lower ? (on_left ? "l" : "r") : (on_left ? "L" : "R");
	String twin_letter = lower ? (on_left ? "r" : "l") : (on_left ? "R" : "L");

	String base = dot && dot.name.len > 0 ? (String)alloc::clone_slice(mem, (char[])dot.name)
		: string::format(mem, "joint_%d", id);
	defer alloc::free(mem, base.ptr);

	for (int n = 1;; n++)
	{
		String suffix = n == 1 ? "" : string::tformat("_%d", n);
		String a      = string::format(mem, "%s%s_%s", base, suffix, own_letter);
		String b      = string::format(mem, "%s%s_%s", base, suffix, twin_letter);
		if (dot_named(doc, a) == null && dot_named(doc, b) == null)
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
 the midline whatever the mesh is shaped like — mostly. A tail curling to one
 side is side-less joints that are not, so the plane is their median
 (`MirrorSurvey.plane_point`) rather than their average.

 The limb **pairs** are deliberately left out. A pair's midpoint is the plane
 only when the pair is already square — and a crooked pair, whose midpoint sits
 off to one side, is exactly what Mirror is there to fix. Deriving the plane
 from the pairs would move it to meet the crookedness instead of squaring the
 crookedness up to the plane.

 @param out : `Receives the plane's model-space X when one was found.`
 @return `False when the rig has no centre joint to read a plane from, out untouched.`
*>
fn bool symmetry_plane(RigDocument* doc, float* out)
{
	MirrorSurvey survey = mirror_survey(doc);
	if (survey.centres == 0) return false;
	*out = survey.plane_point().x;
	return true;
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
fn uint twin_of(RigDocument* doc, Dot dot, Vec3 at, float tolerance)
{
	String want = dot.name.len > 0 ? mirror_name(mem, dot.name) : "";
	defer if (want.len > 0) alloc::free(mem, want.ptr);

	if (want.len > 0)
	{
		foreach (other : doc.dots.array_view())
		{
			if (other.id != dot.id && other.name == want) return other.id;
		}
		return 0;
	}

	uint nearest = 0;
	float best   = tolerance;
	foreach (other : doc.dots.array_view())
	{
		if (other.id == dot.id) continue;
		float gap = (other.position - at).length();
		if (gap > best) continue;
		best = gap;
		nearest = other.id;
	}
	return nearest;
}

// Which dot an edge's far end — or a limit table's primary child — becomes on
// the other side: its twin when the mirror made or moved one, and otherwise
// itself — a bone reaching the spine from the left reaches the same spine from
// the right.
fn uint mirrored_end(RigDocument* doc, uint other, MirrorPair[] plan, float on_plane, Vec3 plane_point, Vec3 plane_normal)
{
	foreach (pair : plan)
	{
		if (pair.source == other) return pair.twin;
	}

	Dot* dot = doc.find(other);
	if (!dot) return other;
	if (math::abs((dot.position - plane_point).dot(plane_normal)) <= on_plane) return other;

	Vec3 at   = reflect_across(dot.position, plane_point, plane_normal);
	uint twin = twin_of(doc, *dot, at, on_plane);
	return twin != 0 ? twin : other;
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

 The point is the **median** of the centre joints — the ones with no side,
 which sit on the plane (`MirrorSurvey.plane_point`) — or, with none, the pair
 midpoints, or the stored `sym_x`. A median and not a mean, because a joint with
 no side is not always on the midline: a tail that curls to one side is four
 "centre" joints well off it, and averaged in they slid the whole plane over, so
 every twin landed a hand's width wrong — a pinky mirrored into the palm. When
 the plane is world-aligned the point collapses to `{x,0,0}` and snaps to the
 stored `sym_x` when within `on_plane` of it, so a rig already mirrored reflects
 onto itself bit-for-bit and records nothing.

 @param on_plane : `The on-plane tolerance, in model units — how near the stored plane the centre line must be to keep it exactly.`
*>
fn void mirror_plane(RigDocument* doc, Vec3* point, Vec3* normal, float on_plane)
{
	MirrorSurvey survey = mirror_survey(doc);
	Vec3 n              = survey.normal();
	if (plane_is_square(n))
	{
		// World-aligned: a bare x, snapped to the stored plane when the centre
		// line all but agrees with it, so an already-square rig records nothing.
		float px = survey.centres > 0 ? survey.plane_point().x : doc.sym_x;
		if (math::abs(px - doc.sym_x) <= on_plane) px = doc.sym_x;
		*point = { px, 0, 0 };
		*normal = { 1, 0, 0 };
		return;
	}

	// Tilted: any point the plane passes through — the centre line, or the pairs'
	// own midline when the rig carries no centre joint.
	if (survey.centres > 0)
	{
		*point = survey.plane_point();
	}
	else if (survey.pairs > 0)
	{
		*point = survey.midpoint();
	}
	else
	{
		*point = { doc.sym_x, 0, 0 };
	}
	*normal = n;
}

// The joint across the symmetry plane from this one, or 0 for a joint on the
// plane or one with no twin. By name first, then by position — `twin_of`'s rule.
fn uint mirror_twin(RigDocument* doc, Picker* picker, uint id)
{
	Dot* dot = doc.find(id);
	if (!dot) return 0;

	float on_plane = picker.scale * MIRROR_EPSILON;
	Vec3 point;
	Vec3 normal;
	mirror_plane(doc, &point, &normal, on_plane);
	if (math::abs((dot.position - point).dot(normal)) <= on_plane) return 0;

	uint twin = twin_of(doc, *dot, reflect_across(dot.position, point, normal), on_plane);
	return twin == id ? 0 : twin;
}

// A vertex lookup across the same plane `mirror_twin` reflects joints across.
fn rig::MirrorLookup mesh_mirror(RigDocument* doc, rig::TriMesh* geometry, Picker* picker, Allocator allocator)
{
	float on_plane = picker.scale * MIRROR_EPSILON;
	Vec3 point;
	Vec3 normal;
	mirror_plane(doc, &point, &normal, on_plane);
	return rig::build_mirror_lookup(allocator, geometry.positions, point, normal, on_plane);
}

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

<*
 Turning clicks into positions on the model.

 A joint belongs *inside* the body, not on its skin — a dot welded to the
 surface makes a bone that runs along the outside of a leg, and every weight
 derived from it is wrong on the far side. So a click does not stop at the
 first triangle: it goes in one side of the limb and out the other, and the dot
 lands halfway between. On anything roughly tubular that midpoint is the medial
 axis, which is where the bone actually is.

 **The model is not assumed to be one closed surface.** Most of what a
 generator emits is a heap of interpenetrating primitives — one shipped robot
 here is seventy separate pieces, seven of them making up a single hand — and
 the ray meets them front, front, back, back rather than front, back. So the
 walk counts how many solids it is inside rather than pairing each face with
 the next, and a run of material is where that count rises above zero and comes
 back down. See `Picker.snap_inside`.

 The BVH comes from `collision.c3l`. It is built once — the mesh never changes
 in M1 — and it borrows the mesh's own arrays rather than copying them, so the
 geometry has to outlive the `Picker`.
*>
module crig;

import rig;
import collision;
import std::math;


<*
 The *most* an open-mesh click steps in from the surface, as a fraction of the
 bounding-box diagonal. Large enough that the dot does not z-fight with the skin
 it came from; a ceiling rather than the answer, because the diagonal is a fact
 about the whole model and the surface being stepped into is a local one. See
 `Picker.step_inside`.
*>
const float OPEN_MESH_DEPTH = 0.02;

<*
 How far along the ray each cast starts past the last surface, as a fraction of
 the diagonal. Without it the next cast finds the same triangle again.
 `intersect_ray` has a fixed 1e-5 epsilon of its own, but that is absolute — a
 model measured in millimetres would sail straight through it — so the step
 scales with the mesh.
*>
const float SURFACE_EPSILON = 0.0001;

<*
 How many surfaces along one ray the walk will look at.

 A closed limb is two. The seven interpenetrating boxes an AI-generated hand is
 built from are fourteen, and a whole figure seen edge-on is more. Past this the
 walk stops and answers from the runs it already has, which are the near ones —
 the side of the body the pointer is on, and so the side being pointed at.
*>
const usz MAX_SURFACES = 32;

<*
 A run of solid material along the ray, as two distances from its origin.
*>
struct Span @local
{
	float enter;
	float exit;
}

faultdef NO_SURFACE;

struct Picker
{
	collision::TriBVHNode* bvh;

	<*
	 The bounding-box diagonal: the length unit the epsilons above are quoted
	 in. crig takes whatever the user drags in, so nothing here can be an
	 absolute distance.
	*>
	float scale;
}

// The index reinterpret below assumes collision's Triangle is three packed
// uints. It is a vector type, and vectors are allowed to carry padding — if
// one ever appears, indices would be read at the wrong stride and the BVH
// would silently describe a different mesh.
$assert collision::Triangle::size == uint::size * 3 : "collision::Triangle is no longer three packed uints";

<*
 A picker over `geometry`, or an empty one when there is no mesh to point at.

 An empty picker has a null `bvh`, and every cast below answers "missed" on
 one. That is the state crig runs in before a model is opened, and it has to be
 a legitimate state rather than a crash: `create_indexed_tri_bvh` carries
 `@require tri_count > 0`, so it cannot be asked about a mesh with no
 triangles at all.

 @param geometry : `Borrowed — the BVH points into its arrays for its whole lifetime.`
*>
fn Picker build_picker(rig::TriMesh geometry)
{
	// The scale falls back to 1 rather than 0: it divides and multiplies the
	// epsilons above, and a zero unit makes every tolerance meaningless rather
	// than merely unused.
	if (geometry.triangle_count() == 0) return { .scale = 1.0f };

	return {
		.bvh = collision::create_indexed_tri_bvh(
			geometry.positions.ptr,
			(collision::Triangle*)geometry.indices.ptr,
			(sz)geometry.triangle_count()),
		.scale = geometry.bounds().extent().length(),
	};
}

fn void Picker.free(&self)
{
	if (self.bvh)
	{
		// free_indexed frees the children and the shared index array but not
		// the node it is called on, which create_indexed_tri_bvh heap-allocated.
		self.bvh.free_indexed();
		mem::free(self.bvh);
	}
	*self = {};
}

<*
 Where a dot goes for a click along `ray`.

 The ray is walked surface by surface, counting how many solids it is inside: a
 front face is one more, a back face is one fewer, and a run of material goes
 from where the count first rises above zero to where it comes back down. The
 midpoint of a run is inside the body, and on anything roughly tubular it is the
 medial axis.

 **Counting rather than pairing each face with the next** is what reads a model
 built out of overlapping primitives as the solid it looks like. Two boxes that
 interpenetrate give front, front, back, back along the ray; pairing calls that
 second front face some unrelated part of the model and gives up on finding a
 midpoint at all. What a user sees when it gives up is the dot flicking somewhere
 else and back for one pixel of pointer travel, because a pixel either side of it
 the ray misses one box and the pairing succeeds again.

 `near` is what a *drag* passes and a fresh click does not, and it only ever
 pulls the answer *deeper* — never forward. The front-most run wins either way,
 because the thing under the cursor is the thing in front. The one case a hint
 changes is a joint that already sits inside a deeper run: when its own depth
 falls between that run's faces the dot keeps it, so a dot slid along the spine
 stays on the medial axis instead of re-deciding its depth from nothing on every
 mouse move. A hint that lies in a gap between limbs, in front of everything, or
 behind it all is inside no run and snaps to the front, so a drag never latches
 onto whatever solid happens to lie behind the joint. That is the whole of the
 continuity — no smoothing and no memory beyond the caller's own last answer —
 and a fresh placement is left exactly as it was.

 A ray that closes no run at all met an open surface: a plate, or a shell with no
 back. There is no midpoint to take, so the dot steps in from the entry face
 along its own normal instead — not the medial axis, but reliably inside the
 surface and stable as the user orbits, which a surface-welded dot is not.

 @param ray : `Origin and unit direction in model space.`
 @param near : `Where the dot already is, for a drag. Null for a fresh placement.`
 @return `The dot position, or NO_SURFACE if the ray missed the mesh entirely.`
 @return? NO_SURFACE : `There is no mesh at all — an empty picker misses everything.`
*>
fn Vec3? Picker.snap_inside(&self, collision::Ray ray, Vec3* near = null)
{
	if (!self.bvh) return NO_SURFACE~;

	float step = self.scale * SURFACE_EPSILON;

	// At most one run per pair of surfaces, since opening one costs a face and
	// closing it costs another.
	Span[MAX_SURFACES / 2] spans;
	usz found = 0;

	collision::HitInfo entry;
	int depth = 0;
	float opened = 0.0f;
	float second = 0.0f;
	float from = 0.0f;

	for (usz i = 0; i < MAX_SURFACES; i++)
	{
		collision::Ray onward = {
			.origin = ray.origin + ray.direction * from,
			.direction = ray.direction,
		};
		collision::HitInfo hit = self.bvh.ray_intersects(onward);
		if (!hit.collided) break;

		float at = from + hit.depth;
		if (i == 0) entry = hit;
		if (i == 1) second = at;

		// Normals come off the winding, so this reads "the ray leaves material
		// through this face" rather than making any claim about which way it faces.
		if (hit.normal.dot(ray.direction) > 0.0f)
		{
			if (depth > 0)
			{
				depth--;
				if (depth == 0 && found < spans.len) spans[found++] = { .enter = opened, .exit = at };
			}
			// Leaving material the walk never saw it enter. The entry face was
			// missed, which is what happens where a ray grazes a silhouette edge and
			// the triangle test decides on a float's last bit — so what is known is
			// that material ends here, and that the sliver it ends is thinner than
			// the miss. Recorded with no length rather than dropped: dropping it
			// sends the dot to whatever solid lies further back, which on a hand
			// built from overlapping boxes is a different finger.
			//
			// The count is not driven below zero either way, or a stray would
			// swallow the next real run.
			else if (found < spans.len)
			{
				spans[found++] = { .enter = at, .exit = at };
			}
		}
		else
		{
			if (depth == 0) opened = at;
			depth++;
		}

		from = at + step;
	}

	if (!entry.collided) return NO_SURFACE~;

	if (found > 0)
	{
		// The front-most run wins by default — the thing under the cursor is the
		// thing in front, and that is where a joint belongs. A drag passes the
		// joint's current position, and the *only* thing that overrides the front
		// is a joint that genuinely sits inside a deeper run: its own depth along
		// the ray falls between that run's two faces. Then it keeps that run, so a
		// dot slid along the spine stays on the medial axis instead of popping to
		// the belly skin. A joint in the gap between two limbs, in front of
		// everything, or behind it all is inside no run — so it snaps forward to
		// the front rather than latching onto whatever solid lies behind it, which
		// is the whole of what a user sees as the dot jumping to the back.
		Span chosen = spans[0];
		if (near)
		{
			float along = ray.direction.dot(*near - ray.origin);
			foreach (span : spans[:found])
			{
				if (along < span.enter || along > span.exit) continue;
				chosen = span;
				break;
			}
		}
		return ray.origin + ray.direction * ((chosen.enter + chosen.exit) * 0.5f);
	}

	// Triangle normals come off the winding and are not oriented against the
	// ray, so turn this one to face the eye before stepping the other way.
	Vec3 outward = entry.normal;
	if (outward.dot(ray.direction) > 0.0f) outward = -outward;

	Vec3 surface = ray.origin + ray.direction * entry.depth;
	return surface - outward * self.step_inside(ray, entry.depth, second, outward);
}

<*
 How far in from an open surface to put the dot.

 `OPEN_MESH_DEPTH` of the model's diagonal is the ceiling. What keeps it a
 ceiling rather than the answer is that the diagonal describes the whole model
 while the surface being stepped into is a local thing: on a metre-wide figure
 that ceiling is 2.7 cm, and a finger built out of two-centimetre boxes is
 thinner than the step — so the dot went in one side of it, out the other, and
 came to rest outside the mesh it was placed on.

 So it is also capped at half the material actually there: the gap to the next
 surface along the ray, turned across the ray, since the step travels along the
 normal and not along the view. Two surfaces need not be parallel, so at a
 glancing angle that still overestimates the thickness — which is why it is half
 the gap and not all of it.

 @param entry : `Ray distance to the surface being stepped into.`
 @param second : `Ray distance to the next surface, or 0 for a ray that meets no other.`
 @param outward : `The entry face's normal, already turned to face the eye.`
*>
fn float Picker.step_inside(&self, collision::Ray ray, float entry, float second, Vec3 outward)
{
	float ceiling = self.scale * OPEN_MESH_DEPTH;
	if (second <= entry) return ceiling;

	float across = (second - entry) * math::abs(outward.dot(ray.direction));
	return math::min(ceiling, across * 0.5f);
}

<*
 Whether the model's own surface stands between the eye and a point that is
 *on* that surface — a mesh vertex, rather than a dot.

 One cast, where `occluded` needs two, and the difference is the whole reason
 both exist. A dot lives *inside* the body by design, so the first hit is always
 the skin in front of it and proves nothing; what hides a dot is a *second*
 surface, meaning the ray left solid material before arriving. A vertex is on the
 skin, so the first hit either is that vertex — in sight — or is some nearer
 piece of the model standing in front of it. Asking `occluded` about a vertex
 gets "visible" for every back-facing one on the model, because the exit surface
 it looks for is the vertex itself.

 The brush's front-faces-only rule is this: a stroke that reached the far side
 would correct an arm and silently correct the ribs behind it, which is precisely
 the bleed crig exists to remove.

 @param point : `A point on the mesh's surface. For one inside the body, ask occluded instead.`
 @return `True when something nearer is in the way.`
*>
fn bool Picker.hidden_surface(&self, Vec3 eye, Vec3 point)
{
	if (!self.bvh) return false;

	Vec3 delta = point - eye;
	float distance = delta.length();
	if (distance <= self.scale * SURFACE_EPSILON) return false;

	collision::Ray ray = { .origin = eye, .direction = delta / distance };
	collision::HitInfo entry = self.bvh.ray_intersects(ray);

	// The epsilon is what keeps the vertex from hiding behind its own triangles:
	// the first hit on a visible vertex lands exactly on it, give or take the
	// float error in a ray that was aimed there.
	return entry.collided && entry.depth < distance - self.scale * SURFACE_EPSILON;
}

<*
 Whether the whole body sits between `eye` and `point` (B7).

 Two casts, the `snap_inside` pattern — dots live *inside* the mesh by design,
 so the first cast always hits something and one cast proves nothing. What
 says "hidden" is the ray having crossed back out of solid material before it
 reaches the point: an entry and a second surface between the eye and the dot
 means the body is in the way. A dot just under the visible skin, or deep in
 the middle of the body, has only the entry in front of it and counts as seen.

 The overlay dims occluded dots with this. **A point on the surface wants
 `hidden_surface` instead** — the second cast is what makes this one wrong for
 one, since the surface a vertex sits on is the very thing this looks for.
*>
fn bool Picker.occluded(&self, Vec3 eye, Vec3 point)
{
	// Nothing to hide behind: with no mesh every dot is in plain sight.
	if (!self.bvh) return false;

	Vec3 delta = point - eye;
	float distance = delta.length();
	if (distance <= self.scale * SURFACE_EPSILON) return false;

	collision::Ray ray = { .origin = eye, .direction = delta / distance };
	collision::HitInfo entry = self.bvh.ray_intersects(ray);
	if (!entry.collided || entry.depth >= distance - self.scale * SURFACE_EPSILON) return false;

	collision::Ray onward = {
		.origin = eye + ray.direction * (entry.depth + self.scale * SURFACE_EPSILON),
		.direction = ray.direction,
	};
	collision::HitInfo exit = self.bvh.ray_intersects(onward);
	if (!exit.collided) return false;

	// A second surface before the point — an exit, or another shell's entry —
	// means the ray was outside the body somewhere along the way.
	return entry.depth + self.scale * SURFACE_EPSILON + exit.depth < distance - self.scale * SURFACE_EPSILON;
}

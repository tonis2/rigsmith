<*
 How far apart two triangles are — the one narrow-phase question every stage
 of mesh collision asks.

 The rest-contact scan (C2) asks it of the rest pose to learn which contacts
 the model was authored with; swept blocking (C3) will ask it of a candidate
 pose against the clearance; the animation scan (C6) of every sampled frame.
 One answer, so the three cannot disagree about whether a pair is touching.

 Zero means the triangles cross. For two triangles that do not, the closest
 points lie on a vertex and the other's face, or on one edge of each, which is
 why the distance is the least of those fifteen feature pairs. A crossing is
 what that search cannot see — an edge that passes clean through a face has no
 nearest feature pair at zero — so it is tested first, edge against face, each
 way round. Coplanar overlap needs no separate case: two coplanar triangles
 that overlap either share a point of one's face with the other's vertex or
 have edges that cross, and both read as zero from the feature search.
*>
module crig;

import collision;
import std::math;

<*
 Below this the segment is parallel to the face, and the feature search is
 the one to answer. Relative to the triangle's own edge lengths rather than
 absolute, so a model in millimetres is not read as parallel everywhere.
*>
const float CROSSING_EPSILON @local = 1.0e-7f;

<*
 Where two triangles come closest, and how close that is.

 Zero `distance` is a crossing or a touch, and `on_a`/`on_b` are then the
 same point — where an edge passes through the other's face, or the touching
 feature. Otherwise they are the closest points, one on each triangle, so a
 contact can be drawn and its direction taken.
*>
struct TriangleGap
{
	float distance;
	Vec3 on_a;
	Vec3 on_b;
}

<*
 Whether the segment `p`→`q` passes through the face of `triangle`.

 Möller–Trumbore, with the ray parameter bounded to the segment. Endpoints
 exactly on the face count as crossing: a vertex resting on a face is a
 distance of zero however it is found, so answering true here only saves the
 feature search the work.

 @param at : `Receives the crossing point when there is one.`
*>
fn bool segment_crosses_triangle(Vec3 p, Vec3 q, collision::TriangleVerts triangle, Vec3* at = null)
{
	Vec3 direction = q - p;
	Vec3 edge1 = triangle[1] - triangle[0];
	Vec3 edge2 = triangle[2] - triangle[0];
	Vec3 h = direction.cross(edge2);
	float a = edge1.dot(h);
	float scale = edge1.length_sq() * edge2.length_sq() * direction.length_sq();
	if (a * a <= CROSSING_EPSILON * CROSSING_EPSILON * scale) return false;

	float f = 1.0f / a;
	Vec3 s = p - triangle[0];
	float u = f * s.dot(h);
	if (u < 0.0f || u > 1.0f) return false;

	Vec3 sq = s.cross(edge1);
	float v = f * direction.dot(sq);
	if (v < 0.0f || u + v > 1.0f) return false;

	float t = f * edge2.dot(sq);
	if (t < 0.0f || t > 1.0f) return false;
	if (at) *at = p + direction * t;
	return true;
}

<*
 Whether the two triangles cross — an edge of either passes through the face
 of the other. Coplanar overlap is not a crossing by this test; see the file
 comment for why the distance still reads zero for it.

 @param at : `Receives the first crossing point found, when there is one.`
*>
fn bool triangles_cross(collision::TriangleVerts a, collision::TriangleVerts b, Vec3* at = null)
{
	for (usz i = 0; i < 3; i++)
	{
		usz next = (i + 1) % 3;
		if (segment_crosses_triangle(a[i], a[next], b, at)) return true;
		if (segment_crosses_triangle(b[i], b[next], a, at)) return true;
	}
	return false;
}

<*
 Where two triangles come closest — zero apart when they cross or touch.

 Fifteen feature pairs after the crossing test: each vertex of one against the
 other's face, and every edge against every edge. Squared until the end, so
 the fifteen comparisons cost no roots.
*>
fn TriangleGap triangle_gap(collision::TriangleVerts a, collision::TriangleVerts b)
{
	Vec3 crossing;
	if (triangles_cross(a, b, &crossing)) return { .distance = 0.0f, .on_a = crossing, .on_b = crossing };

	TriangleGap gap = { .distance = float::max };
	for (usz i = 0; i < 3; i++)
	{
		Vec3 on_b = collision::closest_point_on_triangle(a[i], b[0], b[1], b[2]);
		float to_b = (a[i] - on_b).length_sq();
		if (to_b < gap.distance) gap = { .distance = to_b, .on_a = a[i], .on_b = on_b };
		Vec3 on_a = collision::closest_point_on_triangle(b[i], a[0], a[1], a[2]);
		float to_a = (b[i] - on_a).length_sq();
		if (to_a < gap.distance) gap = { .distance = to_a, .on_a = on_a, .on_b = b[i] };
	}
	for (usz i = 0; i < 3; i++)
	{
		usz i_next = (i + 1) % 3;
		for (usz j = 0; j < 3; j++)
		{
			usz j_next = (j + 1) % 3;
			Vec3 on_a;
			Vec3 on_b;
			collision::closest_points_segments(a[i], a[i_next], b[j], b[j_next], &on_a, &on_b);
			float between = (on_a - on_b).length_sq();
			if (between < gap.distance) gap = { .distance = between, .on_a = on_a, .on_b = on_b };
		}
	}
	gap.distance = math::sqrt(gap.distance);
	return gap;
}

<*
 The distance between two triangles, zero when they cross or touch.
*>
fn float triangle_distance(collision::TriangleVerts a, collision::TriangleVerts b) => triangle_gap(a, b).distance;

<*
 Whether two triangles are provably further apart than `clearance`, from
 their planes alone: if every corner of one lies on one side of the other's
 plane and further from it than the clearance, no point of the first is
 within the clearance of any point of the second. A dozen flops before the
 fifteen feature pairs, and the answer for most of what a broad phase hands
 a narrow phase.

 False is not a contact — a degenerate triangle, or corners straddling the
 plane, both fall through to the exact test. Never true when they are
 within the clearance.
*>
fn bool triangles_apart_by_plane(collision::TriangleVerts a, collision::TriangleVerts b, float clearance)
{
	return corners_beyond_plane(a, b, clearance) || corners_beyond_plane(b, a, clearance);
}

// Every corner of `b` on one side of `a`'s plane, more than `clearance` from it.
fn bool corners_beyond_plane(collision::TriangleVerts a, collision::TriangleVerts b, float clearance) @local
{
	Vec3 normal = (a[1] - a[0]).cross(a[2] - a[0]);
	float length = normal.length();
	if (length <= 0.0f) return false;
	normal = normal / length;
	float d0 = (b[0] - a[0]).dot(normal);
	float d1 = (b[1] - a[0]).dot(normal);
	float d2 = (b[2] - a[0]).dot(normal);
	if (d0 > clearance && d1 > clearance && d2 > clearance) return true;
	return d0 < -clearance && d1 < -clearance && d2 < -clearance;
}

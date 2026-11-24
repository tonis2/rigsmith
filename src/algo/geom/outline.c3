<* The edges of a triangle soup worth drawing as lines: its rim and its creases, not the seams between flat neighbours. *>
module crig;

import std::math;
import std::sort;
import std::collections::list;

// Two triangles meeting at more than this, in radians, draw the edge between them.
const float OUTLINE_CREASE = 0.35f;

struct OutlineVertex @local
{
	Vec3 at;
	uint index;
}

struct OutlineSide @local
{
	ulong edge;
	uint triangle;
}

fn int outline_by_position(OutlineVertex a, OutlineVertex b) @local
{
	for (usz k = 0; k < 3; k++)
	{
		if (a.at[k] != b.at[k]) return a.at[k] < b.at[k] ? -1 : 1;
	}
	return a.index < b.index ? -1 : (a.index > b.index ? 1 : 0);
}

fn bool outline_same(Vec3 a, Vec3 b) @local => a.x == b.x && a.y == b.y && a.z == b.z;

fn int outline_by_edge(OutlineSide a, OutlineSide b) @local
{
	if (a.edge != b.edge) return a.edge < b.edge ? -1 : 1;
	return a.triangle < b.triangle ? -1 : (a.triangle > b.triangle ? 1 : 0);
}

<*
 One index per place: for every vertex, the lowest vertex standing exactly where
 it does. A mesh split along its uv seams is one surface again through this.
 The caller owns the result.
*>
fn uint[] welded_vertices(Allocator allocator, Vec3[] positions)
{
	uint[] weld = alloc::new_array(allocator, uint, (sz)positions.len);
	if (positions.len == 0) return weld;
	OutlineVertex[] order = alloc::new_array(mem, OutlineVertex, (sz)positions.len);
	defer alloc::free(mem, order);
	foreach (usz i, at : positions) order[i] = { .at = at, .index = (uint)i };
	sort::quicksort(order, &outline_by_position);
	uint first = 0;
	foreach (usz i, v : order)
	{
		if (i == 0 || !outline_same(v.at, order[i - 1].at)) first = v.index;
		weld[v.index] = first;
	}
	return weld;
}

<*
 Every edge one triangle owns, and every edge whose two triangles meet at more
 than `crease`, as pairs of indices into `positions`. Vertices at one place are
 welded first, so an uv seam is no outline. The caller owns the result.

 @param [in] positions
 @param [in] triangles : "Three indices a triangle"
 @require triangles.len % 3 == 0 : "Whole triangles"
 @require crease >= 0.0f : "A crease is an angle"
*>
fn uint[] outline_edges(Allocator allocator, Vec3[] positions, uint[] triangles, float crease = OUTLINE_CREASE)
{
	usz count = triangles.len / 3;
	if (count == 0 || positions.len == 0) return {};

	uint[] weld = welded_vertices(mem, positions);
	defer alloc::free(mem, weld);

	Vec3[] normals = alloc::new_array(mem, Vec3, (sz)count);
	defer alloc::free(mem, normals);
	OutlineSide[] sides = alloc::new_array(mem, OutlineSide, (sz)count * 3);
	defer alloc::free(mem, sides);
	usz used = 0;
	for (usz t = 0; t < count; t++)
	{
		uint[3] corner;
		bool inside = true;
		for (usz k = 0; k < 3; k++)
		{
			uint v = triangles[t * 3 + k];
			if (v >= positions.len) inside = false;
			corner[k] = inside ? weld[v] : 0;
		}
		if (!inside) continue;
		Vec3 n = (positions[corner[1]] - positions[corner[0]]).cross(positions[corner[2]] - positions[corner[0]]);
		float length = n.length();
		normals[t] = length > 1.0e-20f ? n / length : (Vec3){ 0, 0, 0 };
		for (usz k = 0; k < 3; k++)
		{
			uint a = corner[k];
			uint b = corner[(k + 1) % 3];
			if (a == b) continue;
			ulong edge = a < b ? ((ulong)a << 32) | b : ((ulong)b << 32) | a;
			sides[used++] = { .edge = edge, .triangle = (uint)t };
		}
	}
	OutlineSide[] filled = sides[:used];
	sort::quicksort(filled, &outline_by_edge);

	float limit = math::cos(crease);
	List{uint} kept;
	kept.init(mem, 64);
	defer kept.free();
	usz at = 0;
	while (at < used)
	{
		usz run = 1;
		while (at + run < used && filled[at + run].edge == filled[at].edge) run++;
		bool drawn = run != 2;
		if (run == 2)
		{
			Vec3 p = normals[filled[at].triangle];
			Vec3 q = normals[filled[at + 1].triangle];
			// A sliver with no normal says nothing about the surface: drawn.
			drawn = p.length_sq() == 0.0f || q.length_sq() == 0.0f || p.dot(q) < limit;
		}
		if (drawn)
		{
			kept.push((uint)(filled[at].edge >> 32));
			kept.push((uint)(filled[at].edge & 0xFFFF_FFFF));
		}
		at += run;
	}
	if (kept.len() == 0) return {};
	uint[] out = alloc::new_array(allocator, uint, (sz)kept.len());
	out[..] = kept.array_view()[..];
	return out;
}

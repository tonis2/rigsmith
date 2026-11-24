<*
 Slices through a mesh: where a plane square to one axis cuts the surface, as
 the separate loops it cuts, each with its middle and its extent.

 	`MeshSection[] cuts = mesh_sections(mem, geometry, shells.of, 1, heights);`
 	`defer free_mesh_sections(mem, cuts);`

 What placing a joint from the mesh is measured with: across the arms, a slice
 cuts the upper arm as one loop, and its middle is where the bone runs; across
 the legs below a skirt, two loops beside the skirt's one. The narrowest slice
 between head and chest is the neck. Each loop is one piece of one shell, so a
 belt or a skirt is told apart from the body it hangs over.

 Vertices at one place are welded first, so a uv seam does not split a loop.
*>
module crig;

import rig;
import std::math;
import std::sort;
import std::collections::list;

<*
 One closed (or, on an open mesh, broken) run of the cut.
*>
struct SectionLoop
{
	Vec3 centre; // the middle of the run, by length
	Vec3 low;    // its extent, as a box
	Vec3 high;
	float length; // how long the run is
	int shell;    // the shell it cuts, -1 when the mesh has no shell ids
	bool closed;  // every cut edge meets two others: a loop round something solid
}

struct MeshSection
{
	float at;
	SectionLoop[] loops;
}

fn void free_mesh_sections(Allocator allocator, MeshSection[] sections)
{
	foreach (section : sections)
	{
		if (section.loops.len > 0) alloc::free(allocator, section.loops);
	}
	if (sections.len > 0) alloc::free(allocator, sections);
}

struct SectionCut @local
{
	ulong from; // the welded edges the segment runs between
	ulong to;
	Vec3 a;
	Vec3 b;
	int shell;
}

<*
 The mesh cut at each of `planes` square to `axis`, loops ordered along the next
 axis round (Y cuts by X, X cuts by Y, Z cuts by X). The caller owns the result.

 @param [in] shell_of : "A shell id per vertex, or empty"
 @param boxed : "Keep only cuts whose middle lies between low and high"
 @require axis < 3 : "An axis is 0, 1 or 2"
*>
fn MeshSection[] mesh_sections(Allocator allocator, rig::TriMesh mesh, int[] shell_of, usz axis, float[] planes,
	bool boxed = false, Vec3 low = {}, Vec3 high = {})
{
	Vec3 normal;
	normal[axis] = 1.0f;
	return mesh_sections_along(allocator, mesh, shell_of, normal, planes, axis == 0 ? 1 : 0, boxed, low, high);
}

<*
 The same cut for planes square to any direction: each plane is the points whose
 distance along `normal` is one of `planes`. Loops are ordered along `order_axis`.

 @require normal.length_sq() > 0.0f : "A direction to cut across"
*>
fn MeshSection[] mesh_sections_along(Allocator allocator, rig::TriMesh mesh, int[] shell_of, Vec3 normal, float[] planes,
	usz order_axis = 0, bool boxed = false, Vec3 low = {}, Vec3 high = {})
{
	normal = normal.normalize();
	if (planes.len == 0) return {};
	MeshSection[] out = alloc::new_array(allocator, MeshSection, (sz)planes.len);
	foreach (usz i, at : planes) out[i].at = at;
	if (mesh.positions.len == 0 || mesh.indices.len < 3) return out;

	uint[] weld = welded_vertices(mem, mesh.positions);
	defer alloc::free(mem, weld);

	List{SectionCut} cuts;
	cuts.init(mem, 256);
	defer cuts.free();
	foreach (usz i, at : planes)
	{
		cuts.clear();
		for (usz t = 0; t + 2 < mesh.indices.len; t += 3)
		{
			uint[3] corner = { mesh.indices[t], mesh.indices[t + 1], mesh.indices[t + 2] };
			if (corner[0] >= mesh.positions.len || corner[1] >= mesh.positions.len || corner[2] >= mesh.positions.len) continue;
			SectionCut cut;
			if (!cut_triangle(mesh.positions, weld, corner, normal, at, &cut)) continue;
			if (boxed)
			{
				Vec3 middle = (cut.a + cut.b) * 0.5f;
				if (middle.x < low.x || middle.y < low.y || middle.z < low.z
					|| middle.x > high.x || middle.y > high.y || middle.z > high.z) continue;
			}
			cut.shell = shell_of.len == mesh.positions.len ? shell_of[corner[0]] : -1;
			cuts.push(cut);
		}
		out[i].loops = section_loops(allocator, cuts.array_view(), order_axis);
	}
	return out;
}

// Where one triangle crosses the plane: the segment between the two edges that
// straddle it, keyed by those edges' welded ends. A corner on the plane counts
// as above it, so a cut never runs through a vertex twice.
fn bool cut_triangle(Vec3[] positions, uint[] weld, uint[3] corner, Vec3 normal, float at, SectionCut* cut) @local
{
	float[3] side;
	for (usz k = 0; k < 3; k++) side[k] = positions[corner[k]].dot(normal) - at;
	usz found = 0;
	for (usz k = 0; k < 3; k++)
	{
		usz n = (k + 1) % 3;
		bool below_k = side[k] < 0.0f;
		bool below_n = side[n] < 0.0f;
		if (below_k == below_n) continue;
		Vec3 p = positions[corner[k]];
		Vec3 q = positions[corner[n]];
		float f = side[k] / (side[k] - side[n]);
		Vec3 point = p + (q - p) * f;
		uint a = weld[corner[k]];
		uint b = weld[corner[n]];
		ulong edge = a < b ? ((ulong)a << 32) | b : ((ulong)b << 32) | a;
		if (found == 0)
		{
			cut.from = edge;
			cut.a = point;
		}
		else
		{
			cut.to = edge;
			cut.b = point;
		}
		found++;
	}
	return found == 2 && cut.from != cut.to;
}

fn Vec3 section_low(Vec3 a, Vec3 b) @local => { math::min(a.x, b.x), math::min(a.y, b.y), math::min(a.z, b.z) };
fn Vec3 section_high(Vec3 a, Vec3 b) @local => { math::max(a.x, b.x), math::max(a.y, b.y), math::max(a.z, b.z) };

fn int section_edge_order(ulong a, ulong b) @local => a < b ? -1 : (a > b ? 1 : 0);

fn usz section_find(usz[] parent, usz at) @local
{
	while (parent[at] != at)
	{
		parent[at] = parent[parent[at]];
		at = parent[at];
	}
	return at;
}

fn usz section_node(ulong[] keys, ulong key) @local
{
	usz low = 0;
	usz high = keys.len;
	while (low < high)
	{
		usz middle = (low + high) / 2;
		if (keys[middle] < key) { low = middle + 1; } else { high = middle; }
	}
	return low;
}

// The cuts joined into runs where they share an edge, one loop per run.
fn SectionLoop[] section_loops(Allocator allocator, SectionCut[] cuts, usz order_axis) @local
{
	if (cuts.len == 0) return {};

	ulong[] keys = alloc::new_array(mem, ulong, (sz)cuts.len * 2);
	defer alloc::free(mem, keys);
	foreach (usz c, cut : cuts)
	{
		keys[c * 2] = cut.from;
		keys[c * 2 + 1] = cut.to;
	}
	sort::quicksort(keys, &section_edge_order);
	usz unique = 0;
	foreach (usz k, key : keys)
	{
		if (k == 0 || key != keys[unique - 1]) keys[unique++] = key;
	}
	ulong[] nodes = keys[:unique];

	usz[] parent = alloc::new_array(mem, usz, (sz)unique);
	defer alloc::free(mem, parent);
	uint[] degree = alloc::new_array(mem, uint, (sz)unique);
	defer alloc::free(mem, degree);
	foreach (usz n, &p : parent) *p = n;
	foreach (cut : cuts)
	{
		usz a = section_node(nodes, cut.from);
		usz b = section_node(nodes, cut.to);
		degree[a]++;
		degree[b]++;
		usz ra = section_find(parent, a);
		usz rb = section_find(parent, b);
		if (ra != rb) parent[ra] = rb;
	}

	// One loop per root, numbered in the order the roots are met.
	sz[] loop_of = alloc::new_array(mem, sz, (sz)unique);
	defer alloc::free(mem, loop_of);
	foreach (&l : loop_of) *l = -1;
	usz loops = 0;
	for (usz n = 0; n < unique; n++)
	{
		usz root = section_find(parent, n);
		if (loop_of[root] < 0) loop_of[root] = (sz)loops++;
	}

	SectionLoop[] out = alloc::new_array(allocator, SectionLoop, (sz)loops);
	Vec3[] weighted = alloc::new_array(mem, Vec3, (sz)loops);
	defer alloc::free(mem, weighted);
	foreach (&loop : out)
	{
		loop.low = { math::FLOAT_MAX, math::FLOAT_MAX, math::FLOAT_MAX };
		loop.high = { -math::FLOAT_MAX, -math::FLOAT_MAX, -math::FLOAT_MAX };
		loop.shell = -1;
		loop.closed = true;
	}
	foreach (cut : cuts)
	{
		usz l = (usz)loop_of[section_find(parent, section_node(nodes, cut.from))];
		SectionLoop* loop = &out[l];
		float length = (cut.b - cut.a).length();
		loop.length += length;
		weighted[l] += (cut.a + cut.b) * (0.5f * length);
		loop.low = section_low(section_low(loop.low, cut.a), cut.b);
		loop.high = section_high(section_high(loop.high, cut.a), cut.b);
		if (loop.shell < 0) loop.shell = cut.shell;
	}
	for (usz n = 0; n < unique; n++)
	{
		if (degree[n] != 2) out[(usz)loop_of[section_find(parent, n)]].closed = false;
	}
	foreach (usz l, &loop : out)
	{
		loop.centre = loop.length > 0.0f ? weighted[l] / loop.length : (loop.low + loop.high) * 0.5f;
	}

	// Left to right (or bottom to top across X), so a reader can pair them.
	for (usz i = 1; i < out.len; i++)
	{
		SectionLoop held = out[i];
		usz j = i;
		while (j > 0 && out[j - 1].centre[order_axis] > held.centre[order_axis])
		{
			out[j] = out[j - 1];
			j--;
		}
		out[j] = held;
	}
	return out;
}

<*
 The middle of the limb a point sits in, across `direction`: the loop the plane
 through `at` square to `direction` cuts nearest to `at`, and its centre. What a
 joint placed along a finger is centred with.

 @param reach : "How far from at a loop may lie and still count"
 @return "Whether a loop was near enough; into is left alone when not"
*>
fn bool section_centre_near(rig::TriMesh mesh, int[] shell_of, Vec3 at, Vec3 direction, float reach, Vec3* into)
{
	if (direction.length_sq() <= 0.0f) return false;
	Vec3 normal = direction.normalize();
	float[1] plane = { at.dot(normal) };
	MeshSection[] cut = mesh_sections_along(mem, mesh, shell_of, normal, plane[..]);
	defer free_mesh_sections(mem, cut);
	if (cut.len == 0) return false;
	float best = reach;
	float smallest = math::FLOAT_MAX;
	bool found = false;
	foreach (loop : cut[0].loops)
	{
		// Distance to the loop's box, so a point inside a thick limb counts as on it;
		// of two that hold it, the smaller is the finger and the larger the hand.
		Vec3 nearest = section_high(loop.low, section_low(at, loop.high));
		float d = (nearest - at).length();
		if (d > best) continue;
		if (found && d == best && loop.length >= smallest) continue;
		best = d;
		smallest = loop.length;
		*into = loop.centre;
		found = true;
	}
	return found;
}

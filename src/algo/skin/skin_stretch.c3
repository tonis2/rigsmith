<*
 How far a clip stretches the skin: every edge of the mesh, posed by the
 binding at each sample, against its length at rest.

 	`SkinEdge[] edges = skin_edges(mem, geometry.positions, geometry.indices);`
 	`SkinStretchLog log = new_skin_stretch_log(mem, shells.count);`
 	`log.measure(edges, posed, shells.of, binding, sample);`

 What the joint numbers cannot see. A belt knot whose cords are split between a
 thigh and the hips reads as nothing in a clip's joint travel and stretches into
 a spike on every step; a skirt weighted half to each thigh splits down its
 middle. Both are edges that grow to several times their rest length while the
 surface either side of them keeps its own. A bent knee stretches the skin over
 it too, but by a fraction, so the tolerance sits well above that.

 Vertices at one place are welded first, so the seam between two uv islands is
 one edge and not two that never meet.
*>
module crig;

import gltf;
import rig;
import std::collections::list;
import std::collections::map;
import std::math;
import std::sort;

// An edge grown past this many times its rest length is a tear in the making.
// A walk's crotch and a raised arm's armpit stretch by up to about three and a
// half under linear blending, so it is the growth below that tells them apart.
const float SKIN_STRETCH_TOLERANCE = 3.0f;
// And by more than this fraction of the rig's height: a skirt splitting between
// the thighs opens by a tenth of the height, a walk's crotch by under three
// hundredths.
const float SKIN_STRETCH_GROWTH = 0.04f;
// A small piece riding the body (a knot, a buckle, a tusk) should not stretch at
// all, so for one the growth allowed is half that.
const float SKIN_STRETCH_GROWTH_PIECE = 0.02f;
// What counts as a small piece: a shell with at most this share of the vertices.
const float SKIN_SMALL_SHELL = 0.05f;

struct SkinEdge
{
	uint a;
	uint b;
	float rest;
}

fn int skin_edge_order(SkinEdge x, SkinEdge y) @local
{
	if (x.a != y.a) return x.a < y.a ? -1 : 1;
	return x.b < y.b ? -1 : (x.b > y.b ? 1 : 0);
}

<*
 Every edge of the mesh once, between welded vertices, with its rest length.
 Edges with no length are left out. The caller owns the result.
*>
fn SkinEdge[] skin_edges(Allocator allocator, Vec3[] positions, uint[] indices)
{
	if (positions.len == 0 || indices.len < 3) return {};
	uint[] weld = welded_vertices(mem, positions);
	defer alloc::free(mem, weld);
	SkinEdge[] all = alloc::new_array(mem, SkinEdge, (sz)indices.len);
	defer alloc::free(mem, all);
	usz count = 0;
	for (usz t = 0; t + 2 < indices.len; t += 3)
	{
		for (usz k = 0; k < 3; k++)
		{
			uint p = indices[t + k];
			uint q = indices[t + (k + 1) % 3];
			if (p >= positions.len || q >= positions.len) continue;
			uint a = weld[p];
			uint b = weld[q];
			if (a == b) continue;
			all[count++] = a < b ? (SkinEdge){ .a = a, .b = b } : (SkinEdge){ .a = b, .b = a };
		}
	}
	sort::quicksort(all[:count], &skin_edge_order);
	usz unique = 0;
	for (usz i = 0; i < count; i++)
	{
		if (unique > 0 && all[i].a == all[unique - 1].a && all[i].b == all[unique - 1].b) continue;
		float rest = (positions[all[i].b] - positions[all[i].a]).length();
		if (rest <= 0.0f) continue;
		all[unique] = all[i];
		all[unique].rest = rest;
		unique++;
	}
	SkinEdge[] out = alloc::new_array(allocator, SkinEdge, (sz)unique);
	out[..] = all[:unique];
	return out;
}

<*
 The mesh posed by a binding: every vertex through its joints' skinning matrices,
 weighted. `palette[j]` carries joint `j` from rest to posed.

 @require into.len == rest.len : "One posed vertex per rest one"
*>
fn void skinned_positions(Vec3[] rest, gltf::SkinBinding binding, Matrix4f[] palette, Vec3[] into)
{
	usz slots = binding.slots;
	foreach (usz v, p : rest)
	{
		if (slots == 0 || v >= binding.vertices)
		{
			into[v] = p;
			continue;
		}
		Vec3 sum;
		float total = 0.0f;
		for (usz s = 0; s < slots; s++)
		{
			float w = binding.weights[v * slots + s];
			if (w <= 0.0f) continue;
			usz j = binding.joints[v * slots + s];
			if (j >= palette.len) continue;
			sum += p.transform(palette[j]) * w;
			total += w;
		}
		into[v] = total > 0.0f ? sum / total : p;
	}
}

// The joint holding most of vertex `v`, or -1 for none.
fn int skin_main_joint(gltf::SkinBinding binding, usz v)
{
	if (binding.slots == 0 || v >= binding.vertices) return -1;
	float best = 0.0f;
	int joint = -1;
	for (usz s = 0; s < binding.slots; s++)
	{
		float w = binding.weights[v * binding.slots + s];
		if (w > best)
		{
			best = w;
			joint = binding.joints[v * binding.slots + s];
		}
	}
	return joint;
}

<*
 The worst stretch one shell took over a clip, and where.
*>
struct SkinStretch
{
	int shell;
	uint a;          // the edge's two vertices, welded
	uint b;
	float stretch;   // posed length over rest length
	float growth;    // posed length less rest length, model units
	usz sample;
	float phase;     // where in the clip, 0 to 1; the caller's to fill in
	int joint_a;     // the joint holding most of each end, -1 for none
	int joint_b;
	Vec3 at;         // the edge's middle at rest
	// Filled in by the caller for a fault: the joint holding most of the shell,
	// and how many vertices the shell has, which is what decides whether the
	// answer is to pin it to that joint.
	int owner;
	usz shell_vertices;
}

<*
 The worst stretch seen in each region: a shell, and the pair of joints its
 stretched edge runs between. Kept per pair rather than per shell, so a skirt
 splitting between the thighs and a knot pulled between a thigh and the hips are
 two rows on one body.
*>
struct SkinStretchLog
{
	List{SkinStretch} worst;
	HashMap{ulong, sz} row_of;
}

fn SkinStretchLog new_skin_stretch_log(Allocator allocator)
{
	SkinStretchLog log;
	log.worst.init(allocator, 64);
	log.row_of.init(allocator);
	return log;
}

fn void SkinStretchLog.free(&self)
{
	self.worst.free();
	self.row_of.free();
}

<*
 One posed instant measured: each edge's stretch, kept where it is its region's
 worst so far.

 @param [in] rest : "The rest positions the edges were measured on"
 @param [in] posed : "The same vertices posed"
 @param [in] shell_of : "A shell per vertex, or empty for one shell"
*>
fn void SkinStretchLog.measure(&self, SkinEdge[] edges, Vec3[] rest, Vec3[] posed, int[] shell_of,
	gltf::SkinBinding binding, usz sample)
{
	foreach (edge : edges)
	{
		float now = (posed[edge.b] - posed[edge.a]).length();
		float stretch = now / edge.rest;
		// Under the tolerance is no region's worst worth keeping.
		if (stretch <= SKIN_STRETCH_TOLERANCE) continue;
		int shell = shell_of.len > edge.a ? shell_of[edge.a] : 0;
		int ja = skin_main_joint(binding, edge.a);
		int jb = skin_main_joint(binding, edge.b);
		uint low = (uint)(math::min(ja, jb) + 1);
		uint high = (uint)(math::max(ja, jb) + 1);
		ulong key = ((ulong)(uint)shell << 32) | ((ulong)(low & 0xFFFF) << 16) | (ulong)(high & 0xFFFF);
		SkinStretch found = {
			.shell = shell,
			.a = edge.a,
			.b = edge.b,
			.stretch = stretch,
			.growth = now - edge.rest,
			.sample = sample,
			.joint_a = ja,
			.joint_b = jb,
			.at = (rest[edge.a] + rest[edge.b]) * 0.5f,
		};
		if (try row = self.row_of.get(key))
		{
			if (stretch > self.worst[row].stretch) self.worst[row] = found;
			continue;
		}
		self.row_of.set(key, self.worst.len());
		self.worst.push(found);
	}
}

<*
 Whether a region's worst stretch could be a fault on some shell: past the
 tolerance and grown past the smaller of the two growths. `faulty` decides.
*>
fn bool SkinStretch.candidate(self, float height)
{
	return self.stretch > SKIN_STRETCH_TOLERANCE && self.growth > SKIN_STRETCH_GROWTH_PIECE * height;
}

fn bool skin_small_piece(usz shell_vertices, usz vertices)
	=> shell_vertices > 0 && (float)shell_vertices <= (float)vertices * SKIN_SMALL_SHELL;

<*
 Whether a region's worst stretch is a fault: past the tolerance, and grown by
 enough of the rig's height to be seen — less for a small piece, which should
 not stretch at all. Needs `shell_vertices` filled in.
*>
fn bool SkinStretch.faulty(self, float height, usz vertices)
{
	if (!self.candidate(height)) return false;
	if (skin_small_piece(self.shell_vertices, vertices)) return true;
	return self.growth > SKIN_STRETCH_GROWTH * height;
}

<*
 The joint two joints both hang from, nearest them: what a rigid piece pulled
 between them should ride. A knot torn between a thigh and the hips rides the
 hips; a skirt front torn between the two thighs rides the hips too. One of them
 when the other hangs from it, the joint itself when the two are one, -1 when
 either is none.
*>
fn int skeleton_common_ancestor(rig::Skeleton* skeleton, int a, int b)
{
	usz count = skeleton.len();
	if (a < 0 || b < 0 || (usz)a >= count || (usz)b >= count) return -1;
	for (int x = a; x >= 0; x = skeleton.parents[(usz)x])
	{
		for (int y = b; y >= 0; y = skeleton.parents[(usz)y])
		{
			if (x == y) return x;
		}
	}
	return -1;
}

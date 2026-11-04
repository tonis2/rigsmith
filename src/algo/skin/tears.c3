<* The pure half of src/app/tears.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math::vector;
import std::collections::list;

// Two copies of one point whose rows a pose can pull apart.
struct TearLink
{
	uint a;
	uint b;
}

// How different two rows are as shares, 0 to 1. An unused row is all of it away from a used one.
fn float rows_apart(float[] a, float[] b)
{
	float total_a = 0.0f;
	float total_b = 0.0f;
	foreach (weight : a) total_a += weight;
	foreach (weight : b) total_b += weight;
	bool empty_a = total_a <= UNUSED_TOTAL;
	bool empty_b = total_b <= UNUSED_TOTAL;
	if (empty_a || empty_b) return empty_a == empty_b ? 0.0f : 1.0f;
	float sum = 0.0f;
	foreach (k, weight : a) sum += math::abs(weight / total_a - b[k] / total_b);
	return sum * 0.5f;
}

// Whether the automatic bind moves two vertices together.
fn bool joined_rows(float[] automatic, usz bones, usz a, usz b)
{
	return rows_apart(automatic[a * bones:bones], automatic[b * bones:bones]) <= JOIN_AUTO_DIFF;
}

// How squarely one layer has to face the other to count as lying over it.
const float COVER_COS = 0.2f;

<*
 Whether paint on vertex a carries to its layer partner b: when b lies under
 a's surface, or the two are the back-to-back sides of a thin piece. Never up
 onto a layer lying over a, nor sideways onto a piece beside it.
*>
fn bool carries_to(Vec3[] positions, Vec3[] normals, usz a, usz b)
{
	if (normals.len != positions.len) return false;
	Vec3 d = positions[b] - positions[a];
	float length = d.length();
	float normal_a = normals[a].length();
	float normal_b = normals[b].length();
	if (length <= 0.0f || normal_a <= 0.0f || normal_b <= 0.0f) return false;
	float b_ahead = normals[a].dot(d) / (length * normal_a);  // b in front of a's surface
	float a_ahead = -normals[b].dot(d) / (length * normal_b); // a in front of b's surface
	return b_ahead < -COVER_COS && (a_ahead > COVER_COS || a_ahead < -COVER_COS);
}

// A run of torn seam side by side on the mesh, for the readout and the red marks.
struct TearPatch
{
	TearLink[] links;             // owned
	uint[] vertices;              // owned: every vertex of the patch
	Vec3 centre;                  // at rest
	float pull;                   // the most a pose pulls a pair apart, over the height per radian
	uint[SKIN_INFLUENCES] joints; // the joints whose weights differ most across it
	usz joint_count;
}

fn void free_tears(Allocator allocator, TearPatch[] tears)
{
	foreach (tear : tears)
	{
		if (tear.links.len > 0) alloc::free(allocator, tear.links);
		if (tear.vertices.len > 0) alloc::free(allocator, tear.vertices);
	}
	if (tears.len > 0) alloc::free(allocator, tears);
}

// The length joined surfaces are measured in: the model's height, or its widest side when flat.
fn float join_scale(RigDocument* doc, rig::TriMesh* geometry)
{
	float height = model_height(doc, geometry);
	if (height > 0.0f || geometry.positions.len == 0) return height;
	rig::Bounds box = geometry.bounds();
	Vec3 size = box.max - box.min;
	return math::max(size.x, size.z);
}

<*
 Every tear in the bind as shown, the ones a pose pulls furthest first: copies
 of one point whose rows a pose can pull at least `TEAR_PULL` of the height
 apart.

 The caller owns the result and frees it with `free_tears`.
*>
fn TearPatch[] find_tear_patches(Allocator allocator, rig::TriMesh* geometry, rig::MeshAdjacency* around, RigView* view, float[] painted, float scale)
{
	usz count = geometry.positions.len;
	usz bones = view.len();

	float[] scratch = alloc::new_array(mem, float, (sz)(bones * 3));
	defer alloc::free(mem, scratch);
	float[] row_a = scratch[0:bones];
	float[] row_b = scratch[bones:bones];
	float[] limb = scratch[2 * bones:bones];

	List{TearLink} links;
	links.init(mem);
	defer links.free();
	List{float} pulls;
	pulls.init(mem);
	defer pulls.free();
	for (usz v = 0; v < count; v++)
	{
		usz first = (usz)around.first[around.class_of[v]];
		if (first == v) continue;
		share_row(painted[first * bones:bones], row_a);
		share_row(painted[v * bones:bones], row_b);
		float pull = pull_apart(&view.skeleton, row_a, row_b, geometry.positions[v], limb);
		if (pull <= TEAR_PULL * scale) continue;
		links.push({ (uint)first, (uint)v });
		pulls.push(pull);
	}
	if (links.len() == 0) return {};

	// Patches: the torn welds, joined by the mesh between them.
	usz classes = around.classes();
	bool[] torn = alloc::new_array(mem, bool, (sz)classes);
	defer alloc::free(mem, torn);
	foreach (link : links) torn[around.class_of[link.a]] = true;
	int[] patch_of = alloc::new_array(mem, int, (sz)classes);
	defer alloc::free(mem, patch_of);
	patch_of[..] = -1;
	List{uint} flood;
	flood.init(mem);
	defer flood.free();
	int patches = 0;
	for (usz c = 0; c < classes; c++)
	{
		if (!torn[c] || patch_of[c] >= 0) continue;
		flood.clear();
		flood.push((uint)c);
		patch_of[c] = patches;
		for (sz next = 0; next < flood.len(); next++)
		{
			foreach (n : around.around(flood[next]))
			{
				if (!torn[n] || patch_of[n] >= 0) continue;
				patch_of[n] = patches;
				flood.push(n);
			}
		}
		patches++;
	}

	TearPatch[] tears = alloc::new_array(allocator, TearPatch, (sz)patches);
	float[] differ = alloc::new_array(mem, float, (sz)(bones * (usz)patches));
	defer alloc::free(mem, differ);
	usz[] link_count = alloc::new_array(mem, usz, (sz)patches);
	defer alloc::free(mem, link_count);
	usz[] vertex_count = alloc::new_array(mem, usz, (sz)patches);
	defer alloc::free(mem, vertex_count);
	foreach (i, link : links)
	{
		usz k = (usz)patch_of[around.class_of[link.a]];
		link_count[k]++;
		tears[k].pull = math::max(tears[k].pull, pulls[i] / scale);
		share_row(painted[(usz)link.a * bones:bones], row_a);
		share_row(painted[(usz)link.b * bones:bones], row_b);
		for (usz j = 0; j < bones; j++) differ[k * bones + j] += math::abs(row_a[j] - row_b[j]);
	}
	for (usz v = 0; v < count; v++)
	{
		int k = patch_of[around.class_of[v]];
		if (k < 0) continue;
		vertex_count[(usz)k]++;
		tears[(usz)k].centre += geometry.positions[v];
	}
	float[SKIN_INFLUENCES] joint_shares;
	foreach (k, &tear : tears)
	{
		tear.links = alloc::new_array(allocator, TearLink, (sz)link_count[k]);
		tear.vertices = alloc::new_array(allocator, uint, (sz)vertex_count[k]);
		if (vertex_count[k] > 0) tear.centre /= (float)vertex_count[k];
		tear.joint_count = strongest_shares(differ[(usz)k * bones:bones], view.dot_ids, tear.joints[..], joint_shares[..], 0.0f);
		link_count[k] = 0;
		vertex_count[k] = 0;
	}
	foreach (link : links)
	{
		usz k = (usz)patch_of[around.class_of[link.a]];
		tears[k].links[link_count[k]++] = link;
	}
	for (usz v = 0; v < count; v++)
	{
		int k = patch_of[around.class_of[v]];
		if (k >= 0) tears[(usz)k].vertices[vertex_count[(usz)k]++] = (uint)v;
	}

	for (usz i = 0; i + 1 < tears.len; i++)
	{
		usz top = i;
		for (usz j = i + 1; j < tears.len; j++) if (tears[j].pull > tears[top].pull) top = j;
		if (top == i) continue;
		TearPatch swap = tears[i];
		tears[i] = tears[top];
		tears[top] = swap;
	}
	return tears;
}

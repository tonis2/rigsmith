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

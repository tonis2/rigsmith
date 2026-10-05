<*
 Which piece of the mesh each vertex belongs to.

 A "shell" is a connected component of the triangle graph: the body is one, and
 every sword, pauldron, buckle or eyeball modelled as its own closed surface is
 another. Nothing joins two shells, which is exactly why the distinction matters
 to a binder — a shell separated from the body by air cannot deform with it, and
 the geodesic distance the binder is built on cannot reach across the gap.

     `MeshShells shells = rig::build_shells(mem, geometry);`
     `defer shells.free(mem);`
     `float[] skin = rig::bind_geodesic(mem, &voxels, &shells, positions, ...);`

 Built once when the mesh loads and reused for every rebind, like `MeshVoxels`:
 it depends on the mesh and nothing else, so moving a dot does not touch it.
*>
module rig;



import std::math::vector;
import std::sort;

<*
 One shell id per vertex, and how many there are.

 Ids run from 0 and are handed out in vertex order — the first vertex of a shell
 names it — so the same mesh always numbers its shells the same way. That is
 what lets an attachment made in one session still name the same sword in the
 next one; it also means the numbering moves if the mesh is re-exported with its
 vertices in a different order, which is a file the session no longer describes
 anyway.

 A vertex no triangle references gets its own shell. It has no surface, so it is
 not a piece of anything, but giving it an id keeps `of` addressable by any
 vertex index rather than mostly addressable.
*>
struct MeshShells
{
	int[] of;   // shell id per vertex
	usz count;  // how many distinct shells
}

<*
 Whether there is more than one piece to tell apart.

 A single-shell mesh needs none of the machinery around this — every binder
 rule keyed on shells is a no-op — so callers test this rather than the count.
*>
fn bool MeshShells.split(self) => self.count > 1;

<*
 How many vertices a shell holds.

 Linear in the mesh. Called once per shell at bind time, not per vertex.
*>
fn usz MeshShells.size(self, int shell)
{
	usz total = 0;
	foreach (id : self.of)
	{
		if (id == shell) total++;
	}
	return total;
}

<*
 Split a mesh into its connected pieces.

 Union-find over the triangle edges, with path halving and union by size, so the
 whole pass is effectively linear in the index count.

 The caller owns the result.
*>
fn MeshShells build_shells(alloc::Allocator allocator, TriMesh geometry)
{
	usz count = geometry.positions.len;
	if (count == 0) return {};

	usz[] parent = alloc::new_array(allocator, usz, (sz)count);
	usz[] weight = alloc::new_array(allocator, usz, (sz)count);
	defer
	{
		alloc::free(allocator, parent);
		alloc::free(allocator, weight);
	}
	for (usz i = 0; i < count; i++)
	{
		parent[i] = i;
		weight[i] = 1;
	}

	for (usz t = 0; t + 2 < geometry.indices.len; t += 3)
	{
		usz a = (usz)geometry.indices[t];
		join(parent, weight, a, (usz)geometry.indices[t + 1]);
		join(parent, weight, a, (usz)geometry.indices[t + 2]);
	}

	// Then vertices that merely sit on each other. Two triangles that share an
	// edge in space frequently do not share its vertices in the index buffer:
	// every UV seam and every hard edge splits them, and a glTF exporter will
	// happily hand over a closed box whose six sides reference twenty-four
	// corners. Judged on indices alone that box is six pieces, and six pieces
	// nothing reaches are six props — so a seam would decide how the mesh binds.
	//
	// Exact equality is the right test and not a lax one: these are copies of
	// one number made by a tool, not two measurements of a point, and a
	// tolerance here would start welding the gaps this whole file exists to
	// respect.
	PlacedVertex[] order = alloc::new_array(allocator, PlacedVertex, (sz)count);
	defer alloc::free(allocator, order);
	foreach (usz i, position : geometry.positions) order[i] = { .at = position, .index = i };

	quicksort(order, &by_position);

	for (usz i = 1; i < count; i++)
	{
		if (by_position(order[i - 1], order[i]) != 0) continue;
		join(parent, weight, order[i - 1].index, order[i].index);
	}

	return numbered(allocator, parent);
}

<*
 Split a mesh into its UV islands: the pieces its texture layout cuts it into.

 The same pass as `build_shells` with one rule changed. Two vertices sitting on
 the same point are one only when they also share a texture coordinate, so a
 hard edge (same uv, another normal) stays closed while a UV seam (another uv)
 parts the surface. The head of a creature unwrapped on its own is then one
 island however smoothly it runs into the neck — what Blender's select-linked
 with a UV delimit picks.

 Every island lies inside one shell, so there are never fewer islands than
 shells; as many means the layout cuts nothing the pieces did not already.

 @param uvs : `One per vertex, TEXCOORD_0 read beside this same geometry.`
 @require uvs.len == geometry.positions.len
*>
fn MeshShells build_uv_islands(alloc::Allocator allocator, TriMesh geometry, Vec2[] uvs)
{
	usz count = geometry.positions.len;
	if (count == 0) return {};

	usz[] parent = alloc::new_array(allocator, usz, (sz)count);
	usz[] weight = alloc::new_array(allocator, usz, (sz)count);
	defer
	{
		alloc::free(allocator, parent);
		alloc::free(allocator, weight);
	}
	for (usz i = 0; i < count; i++)
	{
		parent[i] = i;
		weight[i] = 1;
	}

	for (usz t = 0; t + 2 < geometry.indices.len; t += 3)
	{
		usz a = (usz)geometry.indices[t];
		join(parent, weight, a, (usz)geometry.indices[t + 1]);
		join(parent, weight, a, (usz)geometry.indices[t + 2]);
	}

	PlacedVertex[] order = alloc::new_array(allocator, PlacedVertex, (sz)count);
	defer alloc::free(allocator, order);
	foreach (usz i, position : geometry.positions) order[i] = { .at = position, .index = i };
	quicksort(order, &by_position);

	// A run of copies of one point is a handful at most — the corners of a seam —
	// so comparing each copy with the ones before it costs nothing.
	usz run = 0;
	for (usz i = 1; i <= count; i++)
	{
		if (i < count && by_position(order[run], order[i]) == 0) continue;
		for (usz a = run; a < i; a++)
		{
			for (usz b = run; b < a; b++)
			{
				if (uvs[order[a].index] != uvs[order[b].index]) continue;
				join(parent, weight, order[a].index, order[b].index);
				break;
			}
		}
		run = i;
	}

	return numbered(allocator, parent);
}

// Ids in vertex order: a root gets the next id the first time it is seen, which
// is at its lowest-numbered member.
fn MeshShells numbered(alloc::Allocator allocator, usz[] parent) @local
{
	usz count = parent.len;
	int[] of = alloc::new_array(allocator, int, (sz)count);
	of[:count] = -1;

	usz next = 0;
	for (usz i = 0; i < count; i++)
	{
		usz root = representative(parent, i);
		if (of[root] < 0)
		{
			of[root] = (int)next;
			next++;
		}
		of[i] = of[root];
	}
	return { .of = of, .count = next };
}

fn void MeshShells.free(&self, alloc::Allocator allocator)
{
	if (self.of.len > 0) alloc::free(allocator, self.of);
	*self = {};
}

// A vertex and where it came from, so the sort below can be read back as a
// statement about indices.
//
// Module-wide rather than file-local because `adjacency.c3` welds by the same
// rule and for the same reason — a seam that split a shell would also split a
// neighbourhood — and two copies of a weld would be two chances to disagree
// about what "the same point" means.
struct PlacedVertex @private
{
	Vec3 at;
	usz index;
}

// Lexicographic by x, then y, then z. The order itself means nothing; what it
// buys is that equal positions end up adjacent, so one pass finds every
// duplicate without a hash table.
fn int by_position(PlacedVertex a, PlacedVertex b) @private
{
	if (a.at.x != b.at.x) return a.at.x < b.at.x ? -1 : 1;
	if (a.at.y != b.at.y) return a.at.y < b.at.y ? -1 : 1;
	if (a.at.z != b.at.z) return a.at.z < b.at.z ? -1 : 1;
	return 0;
}

// Path halving: every second link on the way up is rewired to its grandparent,
// which flattens the tree without the second pass a full compression needs.
fn usz representative(usz[] parent, usz a) @local
{
	while (parent[a] != a)
	{
		parent[a] = parent[parent[a]];
		a = parent[a];
	}
	return a;
}

// Union by size, so the shallower tree hangs off the deeper one and no chain
// of merges can walk the whole mesh.
fn void join(usz[] parent, usz[] weight, usz a, usz b) @local
{
	usz ra = representative(parent, a);
	usz rb = representative(parent, b);
	if (ra == rb) return;

	if (weight[ra] < weight[rb])
	{
		usz swap = ra;
		ra = rb;
		rb = swap;
	}
	parent[rb] = ra;
	weight[ra] += weight[rb];
}

<*
 Which points of the mesh touch which, for the ops that average over a
 neighbourhood.

 The binder has never needed this: a geodesic distance is measured through the
 voxel grid rather than along the edges, so nothing in `weights.c3` asks what a
 vertex's neighbours are. Smoothing does — a Laplacian pass *is* the mean of a
 neighbourhood — and until this existed crig had no way to name one.

     `MeshAdjacency around = rig::build_adjacency(mem, geometry);`
     `defer around.free(mem);`

 **The unit is a weld class, not a vertex.** A glTF exporter splits a vertex
 wherever the UVs or the normals do, so a closed box arrives with twenty-four
 corners for its eight, and neighbourhoods taken from the index buffer alone
 would stop dead at every seam — a smooth pass would then leave a visible ridge
 exactly where the model happens to have been unwrapped. So coincident positions
 are welded first, by the rule `build_shells` uses and with the same helpers, and
 what this hands back is adjacency *between welds*: `class_of` says which weld
 each vertex belongs to and the CSR is one row per weld.

 Between welds rather than per vertex because the per-vertex form is the same
 answer written out several times — every copy of a seam vertex would carry the
 union of every copy of every neighbour, which is quadratic in how badly the mesh
 was split and says nothing the class form does not. It also makes "welded copies
 smooth identically" true by construction rather than by arithmetic that happens
 to agree.

 Exact equality on positions, never a tolerance: these are copies of one number
 made by a tool, not two measurements of a point, and a tolerance would start
 welding the gaps between separate pieces — the same argument `build_shells`
 makes at greater length.
*>
module rig;



import std::math::vector;
import std::sort;

<*
 The neighbourhood of every weld class, as a CSR, plus the map from vertices
 into it.

 `class_of[v]` is the weld `v` belongs to; the neighbours of a weld `g` are
 `neighbours[offsets[g] .. offsets[g + 1]]` and are themselves weld ids. Read it
 through `around`, which does that arithmetic.

 A weld is never its own neighbour — a degenerate triangle with two corners at
 one point contributes no edge — and no pair is listed twice however many
 triangles share it, so a mean over `around` is a mean over distinct points.

 Depends on the mesh and nothing else, exactly like `MeshShells`: no edit to the
 rig can change it, and the only thing that invalidates it is a different model.
*>
struct MeshAdjacency
{
	uint[] class_of;   // weld class per vertex
	uint[] offsets;    // one per weld class, plus the tail
	uint[] neighbours; // weld classes, each listed once per neighbour
}

<*
 How many vertices this was built over.

 The check a lazy owner makes before reusing one: a mesh of a different length
 is a different mesh, whatever else is true of it.
*>
fn usz MeshAdjacency.vertices(self) => self.class_of.len;

// How many distinct points the mesh has, once its seams are welded shut.
fn usz MeshAdjacency.classes(self) => self.offsets.len > 0 ? self.offsets.len - 1 : 0;

<*
 Whether there is any neighbourhood here to average over.

 False for an empty mesh and for a point cloud with no triangles — both of which
 are legitimate inputs and neither of which can be smoothed. Callers test this
 rather than the lengths, the way they test `MeshShells.split`.
*>
fn bool MeshAdjacency.usable(self) => self.neighbours.len > 0;

<*
 The welds that touch this one.

 @param group : `A weld class id, as class_of reports it.`
 @require group + 1 < self.offsets.len : `Past the end of the CSR is not a weld this mesh has.`
 @return `The neighbouring weld ids, borrowed. Empty for a point no triangle references.`
*>
fn uint[] MeshAdjacency.around(self, usz group)
{
	usz from = (usz)self.offsets[group];
	return self.neighbours[from : (usz)self.offsets[group + 1] - from];
}

fn void MeshAdjacency.free(&self, alloc::Allocator allocator)
{
	if (self.class_of.len > 0) alloc::free(allocator, self.class_of);
	if (self.offsets.len > 0) alloc::free(allocator, self.offsets);
	if (self.neighbours.len > 0) alloc::free(allocator, self.neighbours);
	*self = {};
}

// One undirected link between two welds, low id first so the two triangles that
// share an edge produce the same pair and the sort can find them side by side.
struct ClassEdge @local
{
	uint low;
	uint high;
}

fn int by_class_pair(ClassEdge a, ClassEdge b) @local
{
	if (a.low != b.low) return a.low < b.low ? -1 : 1;
	if (a.high != b.high) return a.high < b.high ? -1 : 1;
	return 0;
}

// Records one triangle side, dropping the ones that go nowhere: a side whose
// ends welded together is a point, not a link, and would read back as a vertex
// being its own neighbour.
fn usz push_edge(ClassEdge[] edges, usz held, uint a, uint b) @local
{
	if (a == b) return held;
	edges[held] = a < b ? (ClassEdge){ .low = a, .high = b } : (ClassEdge){ .low = b, .high = a };
	return held + 1;
}

<*
 Build the neighbourhoods of a mesh.

 Three passes over the triangles and one sort of them: the vertices are sorted
 into weld classes (O(V log V), `build_shells`' pass verbatim), every triangle
 side becomes a class pair, those are sorted and made unique (O(E log E) over
 three sides per triangle), and then the ordinary CSR pair — count the degrees,
 prefix-sum them into `offsets`, walk the pairs again to fill. Memory is one
 pair per triangle side while it runs and O(V + E) once it returns.

 Sorted-order class ids, not vertex-order ones: nothing persists this — unlike a
 shell id, which an attachment has to still name in the next session — so the
 cheaper numbering is the right one.

 The caller owns the result.

 @param geometry : `Borrowed for the call. An empty mesh comes back empty rather than refused.`
*>
fn MeshAdjacency build_adjacency(alloc::Allocator allocator, TriMesh geometry)
{
	usz count = geometry.positions.len;
	if (count == 0) return {};

	uint[] class_of = alloc::new_array(allocator, uint, (sz)count);

	PlacedVertex[] order = alloc::new_array(allocator, PlacedVertex, (sz)count);
	defer alloc::free(allocator, order);
	foreach (usz i, position : geometry.positions) order[i] = { .at = position, .index = i };

	quicksort(order, &by_position);

	// Equal positions are adjacent after the sort, so a class ends exactly where
	// the comparator first disagrees.
	usz groups = 0;
	for (usz i = 0; i < count; i++)
	{
		if (i > 0 && by_position(order[i - 1], order[i]) != 0) groups++;
		class_of[order[i].index] = (uint)groups;
	}
	groups++;

	uint[] offsets = alloc::new_array(allocator, uint, (sz)groups + 1);

	usz sides = (geometry.indices.len / 3) * 3;
	if (sides == 0) return { .class_of = class_of, .offsets = offsets };

	ClassEdge[] edges = alloc::new_array(allocator, ClassEdge, (sz)sides);
	defer alloc::free(allocator, edges);

	usz held = 0;
	for (usz t = 0; t + 2 < geometry.indices.len; t += 3)
	{
		usz a = (usz)geometry.indices[t];
		usz b = (usz)geometry.indices[t + 1];
		usz c = (usz)geometry.indices[t + 2];

		// A mesh whose indices run off the end of its vertices is one `validate`
		// would refuse, and this is called on meshes nobody validated.
		if (a >= count || b >= count || c >= count) continue;

		held = push_edge(edges, held, class_of[a], class_of[b]);
		held = push_edge(edges, held, class_of[b], class_of[c]);
		held = push_edge(edges, held, class_of[c], class_of[a]);
	}

	if (held == 0) return { .class_of = class_of, .offsets = offsets };

	quicksort(edges[:held], &by_class_pair);

	// Unique in place. Every interior edge arrives twice — once per triangle —
	// and a weld can be reached by many, so without this a mean over a
	// neighbourhood would weight some of it double.
	usz unique = 0;
	ClassEdge last = {};
	for (usz i = 0; i < held; i++)
	{
		ClassEdge edge = edges[i];
		if (unique > 0 && edge.low == last.low && edge.high == last.high) continue;
		edges[unique++] = edge;
		last = edge;
	}

	// Counting pass, written one slot along so the prefix sum below turns the
	// degrees into starts without a second array.
	for (usz i = 0; i < unique; i++)
	{
		offsets[(usz)edges[i].low + 1]++;
		offsets[(usz)edges[i].high + 1]++;
	}
	for (usz g = 0; g < groups; g++) offsets[g + 1] += offsets[g];

	uint[] neighbours = alloc::new_array(allocator, uint, (sz)(unique * 2));

	// Fill pass. The cursor is a copy of the starts, since `offsets` has to still
	// say where each row began once the walk has moved past it.
	uint[] cursor = alloc::new_array(allocator, uint, (sz)groups);
	defer alloc::free(allocator, cursor);
	cursor[:groups] = offsets[:groups];

	for (usz i = 0; i < unique; i++)
	{
		neighbours[cursor[edges[i].low]++] = edges[i].high;
		neighbours[cursor[edges[i].high]++] = edges[i].low;
	}

	return { .class_of = class_of, .offsets = offsets, .neighbours = neighbours };
}

// ---------------------------------------------------------------------------
// The other side.

<*
 Which vertex sits at a point's reflection across the symmetry plane.

 	`MirrorLookup across = build_mirror_lookup(mem, mesh.positions, point, normal, tolerance);`
 	`sz twin = across.twin_of(mesh.positions[v]);`

 What a mirrored rig edit needs to carry per-vertex work — a dab, a pin —
 from one side of the mesh to the other: the same question `mirror_selection`
 asks of a *dot*, asked of the mesh under it. A vertex has a twin when some
 vertex sits within `tolerance` of its reflection, and the nearest such is it;
 a mesh modelled asymmetric there, or a seam split on one side only, has no
 answer, and a caller leaves that vertex alone.

 Sorted by x once so a query is a binary search into the slab around the
 reflection's x rather than a pass over the mesh — the only queries made are
 for vertices that carry something, so the sort is the whole cost on a mesh
 with a few hundred dabs.
*>
struct MirrorLookup
{
	PlacedVertex[] order; // ascending by x
	Vec3 point;  // a point on the symmetry plane
	Vec3 normal; // the plane's unit normal — the body's left-right axis
	float tolerance;
}

fn int by_x(PlacedVertex a, PlacedVertex b) @local
{
	if (a.at.x != b.at.x) return a.at.x < b.at.x ? -1 : 1;
	return 0;
}

<*
 @param point : `A point on the symmetry plane — for the mesh, a point on RigDocument's mirror plane.`
 @param normal : `The plane's unit normal, the body's left-right axis. {1,0,0} is the world-aligned plane.`
 @param tolerance : `How far from the exact reflection a vertex may sit and still be taken for the twin. Model units.`
*>
fn MirrorLookup build_mirror_lookup(alloc::Allocator allocator, Vec3[] positions, Vec3 point, Vec3 normal, float tolerance)
{
	PlacedVertex[] order = alloc::new_array(allocator, PlacedVertex, (sz)positions.len);
	foreach (usz i, position : positions) order[i] = { .at = position, .index = i };
	quicksort(order, &by_x);
	return { .order = order, .point = point, .normal = normal, .tolerance = tolerance > 0.0f ? tolerance : 0.0f };
}

fn void MirrorLookup.free(&self, alloc::Allocator allocator)
{
	if (self.order.len > 0) alloc::free(allocator, self.order);
	*self = {};
}

<*
 The vertex nearest `at`'s reflection, within the tolerance, or -1 for none.

 A point on the plane is its own reflection, so a vertex sitting there answers
 with itself — which is what a caller crossing paint wants: the twin dot holds
 the seam vertex the way the source does.
*>
fn sz MirrorLookup.twin_of(&self, Vec3 at)
{
	if (self.order.len == 0) return -1;

	// The reflection across the plane (point, normal); for a world-aligned
	// normal {1,0,0} this is the old {2*plane - x, y, z}. The vertices are
	// sorted by x, and a twin must sit within the tolerance of `want` in every
	// axis — x included — so the binary search into the x-slab still holds.
	Vec3 want = at - self.normal * (2.0f * (at - self.point).dot(self.normal));
	float tolerance = self.tolerance;

	// First vertex whose x could be within reach.
	usz low = 0;
	usz high = self.order.len;
	while (low < high)
	{
		usz mid = (low + high) / 2;
		if (self.order[mid].at.x < want.x - tolerance) { low = mid + 1; } else { high = mid; }
	}

	sz best = -1;
	float nearest = tolerance * tolerance;
	for (usz i = low; i < self.order.len && self.order[i].at.x <= want.x + tolerance; i++)
	{
		Vec3 gap = self.order[i].at - want;
		float span = gap.dot(gap);
		if (span > nearest) continue;
		nearest = span;
		best = (sz)self.order[i].index;
	}
	return best;
}

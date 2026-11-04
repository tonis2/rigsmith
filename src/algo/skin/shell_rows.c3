<* The pure half of src/app/shell_rows.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::sort;

<*
 One piece of the mesh: how big it is and where it sits.

 The bounds are the corners of the piece's own axis-aligned box, kept rather
 than reduced to a centre and a size because the viewport draws the box itself
 and `get_shells` reports the pair the caller wants — the two are the same
 measurement read two ways.
*>
struct ShellRow
{
	usz shell;
	usz vertices;
	Vec3 low;
	Vec3 high;
}

// Biggest first, and by shell id where two are the same size, so the same mesh
// always lists in the same order.
fn int by_vertices(ShellRow a, ShellRow b) @private
{
	if (a.vertices != b.vertices) return a.vertices > b.vertices ? -1 : 1;
	if (a.shell != b.shell) return a.shell < b.shell ? -1 : 1;
	return 0;
}

<*
 Every piece of the mesh, largest first.

 	`ShellRow[] rows = app.shell_rows(mem);`

 One pass over the vertices for the whole set — see this file's header for why
 that is the point rather than an optimisation. Empty when there are no pieces,
 or when `shells` was built from a mesh that has since been replaced: `of` is one
 entry per vertex, and a mismatch means indexing it would read past the end.

 The caller owns the returned array.
*>
fn ShellRow[] shell_rows(rig::TriMesh* geometry, rig::MeshShells* shells, Allocator allocator)
{
	usz count = shells.count;
	if (count == 0 || shells.of.len != geometry.positions.len) return {};

	ShellRow[] rows = alloc::new_array(allocator, ShellRow, (sz)count);
	for (usz s = 0; s < count; s++) rows[s] = { .shell = s, .vertices = 0 };

	foreach (usz v, position : geometry.positions)
	{
		int id = shells.of[v];
		if (id < 0 || (usz)id >= count) continue;

		ShellRow* row = &rows[(usz)id];
		if (row.vertices == 0)
		{
			row.low = position;
			row.high = position;
		}
		else
		{
			row.low = { math::min(row.low.x, position.x), math::min(row.low.y, position.y), math::min(row.low.z, position.z) };
			row.high = { math::max(row.high.x, position.x), math::max(row.high.y, position.y), math::max(row.high.z, position.z) };
		}
		row.vertices++;
	}

	sort::quicksort(rows, &by_vertices);
	return rows;
}

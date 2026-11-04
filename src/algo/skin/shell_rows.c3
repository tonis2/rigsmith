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

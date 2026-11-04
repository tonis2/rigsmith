<* The pure half of src/app/weights_legacy.c3: no state, undo or notices. *>
module crig;

import rig;
import std::sort;
import std::math;
import std::collections::list;

// The first version whose weights are per-joint columns — see `Dot.held`.
const uint HELD_SESSION = 32;

// How far a joint's automatic column may sit from the one an older session
// showed, as a share of a vertex, and still follow the automatic weights.
const float MIGRATE_SLACK = 1.0e-5;

// Vertex order, which is the grouping `pin_over` needs. Ties are left to the
// sort, since two pins on one vertex name different dots and the row rewrite
// treats them as a set.
fn int by_pinned_vertex(PinColumn a, PinColumn b)
{
	if (a.vertex < b.vertex) return -1;
	if (a.vertex > b.vertex) return 1;
	return 0;
}

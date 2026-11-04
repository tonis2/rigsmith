<* The pure half of src/app/pinning.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::vector;

<*
 A per-vertex chain over the pin layer: where to start walking, and what comes
 next.

 The answer to `set_pin` being a scan. `head[v]` is the newest pin on vertex
 `v` or -1, and `next[i]` is the pin before it on the same vertex — a
 singly-linked list per vertex, threaded through one array with no allocation
 per vertex that carries nothing.

 Built once per batch and read once per entry in it, which turns a region-sized
 write from O(region × layer) into O(region + layer). Both arrays index the
 document's pin list directly, so a batch that *appends* has to have said how
 many it might append when the index was built — see `pin_index`.
*>
struct PinIndex @private
{
	int[] head; // one per vertex slot
	int[] next; // one per pin, plus room for the appends a batch may make
}

<*
 How many vertex slots an index over these two has to cover.

 The mesh's own vertex count is not enough: `set_pin` validates against the rig
 and not against a mesh — `core/` has no mesh to validate against — so the layer
 loaded from a session may name vertices past the end of whatever model is open.
 Those entries are dropped at bind time by `pin_columns`, but they are still in
 the list this walks, and an index too short to hold one is a write out of
 bounds rather than a stale pin.
*>
fn usz pin_span(PinList* pins, VertexPin[] batch) @private
{
	usz span = 0;
	foreach (pin : pins.array_view())
	{
		if ((usz)pin.vertex + 1 > span) span = (usz)pin.vertex + 1;
	}
	foreach (entry : batch)
	{
		if ((usz)entry.vertex + 1 > span) span = (usz)entry.vertex + 1;
	}
	return span;
}

<*
 Threads the chain over the layer as it currently stands.

 @param span : `How many vertex slots to cover — pin_span over the same two lists.`
 @param appends : `How many entries the batch may push onto the layer, so their links have somewhere to live.`
*>
fn PinIndex pin_index(Allocator allocator, PinList* pins, usz span, usz appends) @private
{
	sz held = pins.len();
	PinIndex index = {
		.head = alloc::new_array(allocator, int, (sz)span),
		.next = alloc::new_array(allocator, int, held + (sz)appends),
	};

	index.head[:span] = -1;

	VertexPin[] held_pins = pins.array_view();
	for (sz i = 0; i < held; i++)
	{
		uint vertex = held_pins[i].vertex;
		index.next[i] = index.head[vertex];
		index.head[vertex] = (int)i;
	}
	return index;
}

fn void PinIndex.free(&self, Allocator allocator)
{
	if (self.head.len > 0) alloc::free(allocator, self.head);
	if (self.next.len > 0) alloc::free(allocator, self.next);
	*self = {};
}

<*
 How far the pointer has to travel before the stroke takes another point.

 A polygon with a vertex per mouse move would be thousands of points long on a
 slow drag and would cost `inside_polygon` — which is O(points) per mesh vertex
 — the whole gesture. A couple of pixels is under what a hand can aim anyway, so
 nothing about the region the user drew is lost.
*>
const float LASSO_STEP = 2.0;

<*
 Whether a point is inside a polygon: the even-odd crossing test.

 A ray is cast from the point along +x and the edges it crosses are counted;
 an odd count is inside. Which is what makes the test right for a *freehand*
 region — a hand drawing around a shoulder crosses its own path, and a winding
 rule would then read the overlap as doubly inside where this reads it as
 outside, so the same gesture would pin different vertices depending on how
 tidily it was drawn.

 The half-open comparison on `y` is what keeps a vertex of the polygon from
 being counted twice: an edge counts when the point's `y` is at or above one end
 and below the other, so two edges meeting at a point straddling the ray
 contribute exactly one crossing between them.

 @param points : `The polygon, in order and implicitly closed. Fewer than three is not a region.`
 @return `True when the point is inside.`
*>
fn bool inside_polygon(Vec2[] points, Vec2 p)
{
	if (points.len < 3) return false;

	bool inside = false;
	usz previous = points.len - 1;
	for (usz i = 0; i < points.len; i++)
	{
		Vec2 a = points[i];
		Vec2 b = points[previous];
		previous = i;

		if ((a.y > p.y) == (b.y > p.y)) continue;

		// Where the edge crosses the point's own row. The denominator cannot be
		// zero: the test above is only passed by an edge whose ends straddle `p.y`.
		float crossing = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y);
		if (p.x < crossing) inside = !inside;
	}
	return inside;
}

<*
 The strongest few shares of a row, renormalised to one.

 `SKIN_INFLUENCES` of them, the width the file keeps anyway. `keep` goes in first
 whatever its size, so a joint being raised from almost nothing is not dropped
 by the cut before it has anything.

 @param row : `One weight per joint, any scale.`
 @param keep : `A joint index to always keep while it carries anything, or -1.`
 @return `How many were written to out_dots and out_shares.`
*>
fn usz top_row(float[] row, uint[] dot_ids, sz keep, uint[] out_dots, float[] out_shares)
{
	usz room = math::min((usz)out_dots.len, (usz)SKIN_INFLUENCES);
	usz held = 0;
	if (keep >= 0 && row[(usz)keep] > 0.0f && room > 0)
	{
		out_dots[0] = dot_ids[(usz)keep];
		out_shares[0] = row[(usz)keep];
		held = 1;
	}
	usz floor = held;
	foreach (b, weight : row)
	{
		if (weight <= 0.0f || (sz)b == keep) continue;
		if (held < room)
		{
			out_dots[held] = dot_ids[b];
			out_shares[held] = weight;
			held++;
			continue;
		}
		usz weakest = floor;
		for (usz i = floor + 1; i < held; i++)
		{
			if (out_shares[i] < out_shares[weakest]) weakest = i;
		}
		if (weakest >= held || weight <= out_shares[weakest]) continue;
		out_dots[weakest] = dot_ids[b];
		out_shares[weakest] = weight;
	}

	float sum = 0.0f;
	for (usz i = 0; i < held; i++) sum += out_shares[i];
	if (sum <= 0.0f) return 0;
	for (usz i = 0; i < held; i++) out_shares[i] /= sum;
	return held;
}

// Whether a joint's weights are its own — see `Dot.held`.
fn bool weights_held(RigDocument* doc, uint dot_id)
{
	Dot* dot = doc.find(dot_id);
	return dot && dot.held;
}

// Whether any joint's weights are its own.
fn bool weights_edited(RigDocument* doc)
{
	foreach (dot : doc.dots.array_view()) if (dot.held) return true;
	return false;
}

<*
 What the document stores for a dot, one weight per vertex, held or not: what
 a write to its column is measured against.

 The caller owns the result, which is exactly as long as the mesh.
*>
fn float[] stored_column(RigDocument* doc, rig::TriMesh* geometry, Allocator allocator, uint dot_id)
{
	usz count = geometry.positions.len;
	float[] column = alloc::new_array(allocator, float, (sz)count);
	foreach (pin : doc.pins.array_view())
	{
		if (pin.dot_id == dot_id && (usz)pin.vertex < count) column[pin.vertex] = pin.share;
	}
	return column;
}

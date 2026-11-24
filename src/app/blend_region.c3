<*
 A region weighted as cloth, as one undo step: its top joint takes it whole at
 the top, the side joints come in toward the bottom and the sides
 (`algo/skin/blend_region.c3`), and every other joint is taken off it.

 	`BlendResult did = app.blend_region_recorded(skirt, hips, thighs, SKIRT_BLEND, {});`

 Each joint written is held, by the rule every hand edit follows (`replace_column`):
 its weights stay as written however the rig moves. The result says which joints
 that newly held, so a caller who moves a joint later knows which no longer follow.
*>
module crig;

import std::math;

const usz BLEND_HELD_MOST = 32;

struct BlendResult
{
	usz changed;               // vertices moved, over every column written
	usz written;               // columns written
	uint[BLEND_HELD_MOST] held; // joints held by this edit that were not before
	usz held_count;
	uint[BLEND_HELD_MOST] cleared; // joints taken off the region
	usz cleared_count;
}

<*
 Weight `vertices` as cloth hanging from `top`, with `sides` blended in.

 @param sides : "The joints at the region's sides; each vertex takes the one on its side of the mirror plane, or the nearest when there are more than two. Empty gives the region to top alone."
 @param keep : "Joints left as they are on the region"
*>
fn BlendResult AppState.blend_region_recorded(&self, uint[] vertices, uint top, uint[] sides, BlendShape shape, uint[] keep)
{
	BlendResult result;
	if (vertices.len == 0 || !self.doc.find(top)) return result;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return result;
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	usz count = self.geometry.positions.len;

	// Who holds the region now, before anything is written.
	float[] dense = self.weights(mem, &view);
	defer if (dense.len > 0) alloc::free(mem, dense);
	bool[] holds = alloc::new_array(mem, bool, (sz)bones);
	defer alloc::free(mem, holds);
	if (dense.len == count * bones)
	{
		foreach (v : vertices)
		{
			if (v >= count) continue;
			for (usz j = 0; j < bones; j++) if (dense[(usz)v * bones + j] > 1.0e-4f) holds[j] = true;
		}
	}

	// Each vertex's side joint: the one on its side of the plane, else the nearest.
	float[] share = sides.len > 0 ? blend_side_shares(mem, self.geometry.positions, vertices, self.doc.sym_x, shape) : (float[]){};
	defer if (share.len > 0) alloc::free(mem, share);
	uint[] side_of = alloc::new_array(mem, uint, (sz)vertices.len);
	defer alloc::free(mem, side_of);
	foreach (usz i, v : vertices) side_of[i] = sides.len > 0 ? nearest_side(self, sides, self.geometry.positions[v]) : 0;

	bool[] was_held = alloc::new_array(mem, bool, (sz)bones);
	defer alloc::free(mem, was_held);
	foreach (usz j, id : view.dot_ids) was_held[j] = self.weights_held(id);

	for (usz j = 0; j < bones; j++)
	{
		uint id = view.dot_ids[j];
		bool is_top = id == top;
		bool is_side = false;
		foreach (s : sides) if (s == id) is_side = true;
		bool kept = false;
		foreach (k : keep) if (k == id) kept = true;
		if (kept && !is_top && !is_side) continue;
		if (!is_top && !is_side && !holds[j]) continue;

		float[] column = self.column_of(mem, &view, id);
		defer if (column.len > 0) alloc::free(mem, column);
		if (column.len != count) continue;
		foreach (usz i, v : vertices)
		{
			if (v >= count) continue;
			float side = share.len > 0 ? share[i] : 0.0f;
			float weight = 0.0f;
			if (is_side && side_of[i] == id) weight = side;
			if (is_top) weight += 1.0f - (sides.len > 0 ? side : 0.0f);
			column[v] = weight;
		}
		usz moved = self.replace_column(&view, id, column, commit: false);
		if (moved == 0) continue;
		result.changed += moved;
		result.written++;
		if (!is_top && !is_side && result.cleared_count < BLEND_HELD_MOST) result.cleared[result.cleared_count++] = id;
		if (!was_held[j] && self.weights_held(id) && result.held_count < BLEND_HELD_MOST) result.held[result.held_count++] = id;
	}
	self.undo_stack.commit();
	return result;
}

// The side joint a vertex at `at` takes: with two, the one on its side of the
// mirror plane; otherwise the nearest.
fn uint nearest_side(AppState* app, uint[] sides, Vec3 at) @private
{
	if (sides.len == 2)
	{
		Dot* a = app.doc.find(sides[0]);
		Dot* b = app.doc.find(sides[1]);
		if (a && b && (a.position.x - app.doc.sym_x) * (b.position.x - app.doc.sym_x) < 0.0f)
		{
			bool on_a = (at.x - app.doc.sym_x) * (a.position.x - app.doc.sym_x) >= 0.0f;
			return on_a ? sides[0] : sides[1];
		}
	}
	uint best = sides[0];
	float nearest = math::FLOAT_MAX;
	foreach (id : sides)
	{
		Dot* dot = app.doc.find(id);
		if (!dot) continue;
		float d = (dot.position - at).length();
		if (d < nearest)
		{
			nearest = d;
			best = id;
		}
	}
	return best;
}

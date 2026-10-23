<*
 Weights from sessions before version 32, turned into held columns as they load.

 Up to version 31 the weights a rig showed were one automatic bind for every
 joint — every joint's grow and soft edge read into it — with whole rows of
 hand edits laid over it (`pin_over`), and before that multipliers (`paint`).
 From 32 each joint is either automatic, its column the binder's, or held, its
 column its own (`Dot.held`). `migrate_held_weights` rebuilds the old picture
 once and holds every joint whose column the new automatic weights would not
 reproduce, so a rig opens looking exactly as it was saved.
*>
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

<*
 Hold every joint whose weights an older session showed differently from the
 automatic weights now, with the column it showed, and let the rest follow the
 automatic weights. Not recorded: the load clears the history.

 Which joints that is can be more than the ones the user edited. A whole row an
 Apply or a lasso wrote took the neighbours off it too, a partial stroke
 rescaled them, and a grown joint moved its neighbours' edges — every one of
 those neighbours showed a column the automatic weights no longer give it, so
 it is held as well. That is the price of the rig looking as it did; Reset lets
 any of them go.

 @return `How many joints were held.`
*>
fn usz AppState.migrate_held_weights(&self)
{
	defer self.doc.paint.clear();
	usz count = self.geometry.positions.len;
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.doc.pins.clear();
		return 0;
	}
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	if (count == 0 || bones == 0)
	{
		self.doc.pins.clear();
		return 0;
	}

	float[] shown = self.legacy_weights(mem, &view);
	defer if (shown.len > 0) alloc::free(mem, shown);
	float[] automatic = self.base_bind_for(&view);
	if (shown.len != count * bones || automatic.len != shown.len)
	{
		self.doc.pins.clear();
		return 0;
	}

	bool[] hold = alloc::new_array(mem, bool, (sz)bones);
	defer alloc::free(mem, hold);
	usz[] table = joint_table(mem, view.dot_ids);
	defer alloc::free(mem, table);
	foreach (usz j, id : view.dot_ids)
	{
		Dot* dot = self.doc.find(id);
		if (dot && (dot.grow != 0.0f || dot.band > 0.0f)) hold[j] = true;
	}
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.dot_id < table.len && table[pin.dot_id] > 0) hold[table[pin.dot_id] - 1] = true;
	}
	for (usz j = 0; j < bones; j++)
	{
		if (hold[j]) continue;
		for (usz v = 0; v < count && !hold[j]; v++)
		{
			usz at = v * bones + j;
			if (math::abs(shown[at] - automatic[at]) > MIGRATE_SLACK) hold[j] = true;
		}
	}

	self.doc.pins.clear();
	usz held = 0;
	foreach (usz j, id : view.dot_ids)
	{
		self.doc.set_held(id, hold[j]);
		if (!hold[j]) continue;
		held++;
		for (usz v = 0; v < count; v++)
		{
			float weight = shown[v * bones + j];
			if (weight > 0.0f) self.doc.pins.push({ .vertex = (uint)v, .dot_id = id, .share = math::min(weight, 1.0f) });
		}
	}
	self.mark_paint_stale();
	return held;
}

<*
 The weights a session before version 32 showed, rows summing to one: the
 automatic bind with every joint's grow and soft edge on it, an older session's
 multipliers baked into rows, and every pin laid over the lot (`pin_over`).

 The caller owns the result; empty with nothing to bind.
*>
fn float[] AppState.legacy_weights(&self, Allocator allocator, RigView* view)
{
	usz count = self.geometry.positions.len;
	usz bones = view.len();
	float[] dense;
	if (self.doc.legacy_skin_from_file && self.imported_skin.present())
	{
		// The file's columns, as the base those sessions wore when they covered the
		// rig — chains isolated, as the binder isolates its own.
		dense = self.imported_dense(allocator, view);
		if (dense.len > 0) rig::isolate_chains(allocator, dense, view.skeleton.parents);
	}
	if (dense.len == 0)
	{
		int[] riders = self.shells.count > 0 ? alloc::new_array(mem, int, (sz)self.shells.count) : (int[]){};
		defer if (riders.len > 0) alloc::free(mem, riders);
		float[] distances = alloc::new_array(mem, float, (sz)(count * bones));
		defer alloc::free(mem, distances);
		dense = self.bind_binder(allocator, view, view.grows, view.bands, riders, {}, distances);
	}
	if (dense.len != count * bones) return dense;

	// Every pin the session carried, with the rows its multipliers made stated
	// as pins too — what loading an older session did before this one.
	List{PinColumn} pins;
	pins.init(mem);
	defer pins.free();
	usz[] table = joint_table(mem, view.dot_ids);
	defer alloc::free(mem, table);
	bool[] pinned = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, pinned);
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= count || (usz)pin.dot_id >= table.len || table[pin.dot_id] == 0) continue;
		pins.push({ .vertex = pin.vertex, .joint = table[pin.dot_id] - 1, .share = pin.share });
		pinned[pin.vertex] = true;
	}

	PaintColumn[] columns = self.paint_columns(mem, view.dot_ids);
	defer if (columns.len > 0) alloc::free(mem, columns.ptr);
	if (columns.len > 0)
	{
		float[] row = alloc::new_array(mem, float, (sz)bones);
		defer alloc::free(mem, row);
		bool[] baked = alloc::new_array(mem, bool, (sz)count);
		defer alloc::free(mem, baked);
		uint[SKIN_INFLUENCES] dots;
		float[SKIN_INFLUENCES] shares;
		foreach (column : columns)
		{
			uint v = column.vertex;
			if (pinned[v] || baked[v]) continue;
			baked[v] = true;
			row[..] = dense[(usz)v * bones:bones];
			foreach (other : columns) if (other.vertex == v) row[other.joint] *= other.factor;
			usz kept = top_row(row, view.dot_ids, -1, dots[..], shares[..]);
			for (usz i = 0; i < kept; i++)
			{
				pins.push({ .vertex = v, .joint = table[dots[i]] - 1, .share = shares[i] });
			}
		}
	}

	PinColumn[] grouped = pins.array_view();
	sort::quicksort(grouped, &by_pinned_vertex);
	pin_over(dense, bones, grouped);
	normalise_rows(dense, bones);
	return dense;
}

// Vertex order, which is the grouping `pin_over` needs. Ties are left to the
// sort, since two pins on one vertex name different dots and the row rewrite
// treats them as a set.
fn int by_pinned_vertex(PinColumn a, PinColumn b) @local
{
	if (a.vertex < b.vertex) return -1;
	if (a.vertex > b.vertex) return 1;
	return 0;
}

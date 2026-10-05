<*
 What the app knows about the mesh's separate pieces: one row per piece, and
 which bone the binder decided each of them rides.

 One answer for every reader. `get_shells` lists the pieces over the wire, and a
 Shells pane listed them on screen until it went for now (the mechanism is
 sound; a list of numbered pieces was not the face for it). A list built twice
 is a list that disagrees with itself the first time either side is changed —
 the ordering above all, since "the largest piece" is how a person finds the
 head — so whatever face comes back reads these rows too.

 **Never `MeshShells.size` per row.** That call walks every vertex of the mesh,
 so asking it once per piece is one walk per piece — hundreds of them on a
 panelled model, for an answer one walk already holds. `shell_rows` accumulates
 the count and the bounds of every piece in a single pass, which is also where
 the box the viewport highlights comes from.

 The riders half is the binder's own opinion: `rig::rigid_shells` decides which
 bone an unreachable piece must ride, and until now that decision was computed
 and thrown away inside the bind. `bind_dense` writes it into `shell_riders`,
 `mark_rig_stale` marks it stale, and nothing may read it while it is — joint
 indices are BFS output and shift on every edit to the rig, so a stale index
 names a different bone rather than no bone. `refresh_shell_riders` is how a
 reader that finds them stale gets fresh ones.
*>
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
fn ShellRow[] AppState.shell_rows(&self, Allocator allocator)
{
	usz count = self.shells.count;
	if (count == 0 || self.shells.of.len != self.geometry.positions.len) return {};

	ShellRow[] rows = alloc::new_array(allocator, ShellRow, (sz)count);
	for (usz s = 0; s < count; s++) rows[s] = { .shell = s, .vertices = 0 };

	foreach (usz v, position : self.geometry.positions)
	{
		int id = self.shells.of[v];
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

// ---------------------------------------------------------------------------
// What the pointer is over

// ---------------------------------------------------------------------------
// The binder's own choices

<*
 Sizes `shell_riders` to the piece count and blanks it, ready for a bind to
 write into.

 Called from both of `bind_dense`'s branches so the array is always the shape
 `rig::bind_geodesic` requires — it fills by shell id and skips anything past
 the end, so an array left at the previous mesh's length would silently answer
 for the wrong pieces.
*>
fn int[] AppState.blank_shell_riders(&self)
{
	usz count = self.shells.count;
	if (self.shell_riders.len != count)
	{
		self.drop_shell_riders();
		if (count > 0) self.shell_riders = alloc::new_array(mem, int, (sz)count);
	}
	self.shell_riders[..] = -1;
	return self.shell_riders;
}

// Releases the riders. Safe on an array that is already empty, which is what
// lets the mesh-replace paths stay unconditional.
fn void AppState.drop_shell_riders(&self)
{
	if (self.shell_riders.len > 0) alloc::free(mem, self.shell_riders);
	self.shell_riders = {};
	self.riders_stale = true;
}

<*
 Fills `shell_riders` from a bind of the rig as it stands now.

 	`app.refresh_shell_riders();`

 The cost of a full geodesic bind, so a per-frame caller belongs behind the
 same `WEIGHT_DEBOUNCE` every other rebind is behind — the Shells pane called
 it that way, once the rig had been still; `get_shells` calls it per request,
 which is a tool call and can afford one bind. A no-op when the riders are
 already fresh.

 `base_bind_for` rather than a bind of its own: the riders are a side effect of
 `bind_dense`, and going through the cache means a reader costs nothing extra
 on top of a preview that was going to bind anyway. A document with no rig, or
 a mesh with no vertices, never reaches the binder at all — so the flag is
 lowered here instead, or a per-frame reader would ask again on every frame for
 an answer that cannot come.
*>
fn void AppState.refresh_shell_riders(&self)
{
	if (!self.riders_stale) return;

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.blank_shell_riders();
		self.riders_stale = false;
		return;
	}
	RigView view = opened;
	defer view.free(mem);

	self.base_bind_for(&view);

	if (self.riders_stale)
	{
		self.blank_shell_riders();
		self.riders_stale = false;
	}
}

<*
 Which joint the binder gave this piece, or -1 for none and for an answer that
 can no longer be trusted.

 The staleness check is not a nicety. A rider is a joint *index*, the skeleton is
 built breadth-first from the root, and adding or removing a dot renumbers it —
 so an index read after an edit and before the next bind names some other bone
 with complete confidence.
*>
fn int AppState.shell_rider(&self, usz shell)
{
	if (self.riders_stale || shell >= self.shell_riders.len) return -1;
	return self.shell_riders[shell];
}

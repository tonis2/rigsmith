<*
 Which points of the mesh lie on another layer close by: a collar over the
 chest, a scarf over the neck, a pocket sewn on as its own piece.

 Two weld classes are layer partners when they sit within `gap` of each other
 in space but are much further apart over the surface (or on separate pieces).
 Points of one surface that are merely near each other are not partners.

 Mesh only, like `MeshAdjacency`: the rig decides later which partners move
 together (`joined_rows`).
*>
module rig;

import std::math::vector;
import std::sort;
import std::collections::list;

struct JoinedLayers
{
	uint[] offsets;  // one per weld class, plus the tail
	uint[] partners; // weld classes, each pair listed from both ends
}

fn usz JoinedLayers.classes(self) => self.offsets.len > 0 ? self.offsets.len - 1 : 0;

// The layer partners of one weld class, borrowed.
fn uint[] JoinedLayers.around(self, usz group)
{
	if (group + 1 >= self.offsets.len) return {};
	usz from = (usz)self.offsets[group];
	return self.partners[from : (usz)self.offsets[group + 1] - from];
}

fn void JoinedLayers.free(&self, alloc::Allocator allocator)
{
	if (self.offsets.len > 0) alloc::free(allocator, self.offsets);
	if (self.partners.len > 0) alloc::free(allocator, self.partners);
	*self = {};
}

struct LayerCell @local
{
	int x, y, z;
	uint group;
}

fn int by_cell(LayerCell a, LayerCell b) @local
{
	if (a.x != b.x) return a.x < b.x ? -1 : 1;
	if (a.y != b.y) return a.y < b.y ? -1 : 1;
	if (a.z != b.z) return a.z < b.z ? -1 : 1;
	return a.group < b.group ? -1 : (a.group > b.group ? 1 : 0);
}

// The first entry at or after this cell.
fn usz first_in_cell(LayerCell[] cells, int x, int y, int z) @local
{
	LayerCell probe = { x, y, z, 0 };
	usz low = 0;
	usz high = cells.len;
	while (low < high)
	{
		usz mid = (low + high) / 2;
		if (by_cell(cells[mid], probe) < 0)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}
	return low;
}

<*
 Find every layer partner of every weld class.

 @param around : `The mesh's welds and their neighbours.`
 @param gap : `How close in space two layers sit, in model units.`
 @param detour : `How many times their gap apart over the surface two points of one surface must be to count as layers.`
*>
fn JoinedLayers build_joined(alloc::Allocator allocator, TriMesh geometry, MeshAdjacency* around, float gap, float detour)
{
	usz classes = around.classes();
	if (classes == 0 || gap <= 0.0f || around.first.len != classes) return {};

	Vec3[] point = alloc::new_array(allocator, Vec3, (sz)classes);
	defer alloc::free(allocator, point);
	for (usz c = 0; c < classes; c++) point[c] = geometry.positions[around.first[c]];

	JoinedLayers joined;

	// A grid one gap wide: a partner is in the 27 cells around a point.
	LayerCell[] cells = alloc::new_array(allocator, LayerCell, (sz)classes);
	defer alloc::free(allocator, cells);
	for (usz c = 0; c < classes; c++)
	{
		Vec3 p = point[c] / gap;
		cells[c] = { (int)math::floor(p.x), (int)math::floor(p.y), (int)math::floor(p.z), (uint)c };
	}
	quicksort(cells, &by_cell);

	// Surface distance from the class being searched, stamped so it is never cleared.
	float[] distance = alloc::new_array(allocator, float, (sz)classes);
	defer alloc::free(allocator, distance);
	uint[] stamp = alloc::new_array(allocator, uint, (sz)classes);
	defer alloc::free(allocator, stamp);

	List{uint} near;
	near.init(allocator);
	defer near.free();
	List{uint} queue;
	queue.init(allocator);
	defer queue.free();
	List{uint} pairs; // low, high
	pairs.init(allocator);
	defer pairs.free();

	for (usz a = 0; a < classes; a++)
	{
		Vec3 at = point[a];
		Vec3 scaled = at / gap;
		int cx = (int)math::floor(scaled.x);
		int cy = (int)math::floor(scaled.y);
		int cz = (int)math::floor(scaled.z);

		// Classes above this one within the gap; each pair is decided once.
		near.clear();
		float farthest = 0.0f;
		for (int dx = -1; dx <= 1; dx++)
		{
			for (int dy = -1; dy <= 1; dy++)
			{
				for (int dz = -1; dz <= 1; dz++)
				{
					for (usz i = first_in_cell(cells, cx + dx, cy + dy, cz + dz); i < cells.len; i++)
					{
						LayerCell cell = cells[i];
						if (cell.x != cx + dx || cell.y != cy + dy || cell.z != cz + dz) break;
						if ((usz)cell.group <= a) continue;
						float apart = (point[cell.group] - at).length();
						if (apart >= gap) continue;
						near.push(cell.group);
						farthest = math::max(farthest, apart);
					}
				}
			}
		}
		if (near.len() == 0) continue;

		// How far over the surface, out to the furthest candidate's detour.
		float radius = farthest * detour;
		uint mark = (uint)a + 1;
		stamp[a] = mark;
		distance[a] = 0.0f;
		queue.clear();
		queue.push((uint)a);
		for (sz next = 0; next < queue.len(); next++)
		{
			uint from = queue[next];
			float here = distance[from];
			foreach (to : around.around(from))
			{
				float step = here + (point[to] - point[from]).length();
				if (step > radius) continue;
				if (stamp[to] == mark && distance[to] <= step) continue;
				stamp[to] = mark;
				distance[to] = step;
				queue.push(to);
			}
		}

		foreach (b : near)
		{
			float apart = (point[b] - at).length();
			if (stamp[b] == mark && distance[b] <= apart * detour) continue;
			pairs.push((uint)a);
			pairs.push(b);
		}
	}

	// Both ends of every pair, as a CSR.
	uint[] offsets = alloc::new_array(allocator, uint, (sz)classes + 1);
	joined.offsets = offsets;
	sz count = pairs.len() / 2;
	for (sz i = 0; i < count; i++)
	{
		offsets[(usz)pairs[2 * i] + 1]++;
		offsets[(usz)pairs[2 * i + 1] + 1]++;
	}
	for (usz c = 0; c < classes; c++) offsets[c + 1] += offsets[c];
	if (count == 0) return joined;

	uint[] partners = alloc::new_array(allocator, uint, (sz)(count * 2));
	uint[] cursor = alloc::new_array(allocator, uint, (sz)classes);
	defer alloc::free(allocator, cursor);
	cursor[..] = offsets[:classes];
	for (sz i = 0; i < count; i++)
	{
		uint low = pairs[2 * i];
		uint high = pairs[2 * i + 1];
		partners[cursor[low]++] = high;
		partners[cursor[high]++] = low;
	}
	joined.partners = partners;
	return joined;
}

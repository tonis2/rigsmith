<*
 Vertices picked by where they are rather than by number: a shell, a box, a
 height range, a side of the body. What a weight edit over "the skirt below the
 belt" or "the left half of the tunic" selects with, so no caller has to parse
 the model to find the numbers.

 Each part given narrows the region; none given is every vertex.
*>
module crig;

import std::math;

enum RegionSide : int
{
	ANY,
	LEFT,   // the figure's left: past the mirror plane toward +X
	RIGHT,  // toward -X
	MIDDLE, // on the mirror plane, within a two-hundredth of the body's width
}

const usz REGION_SHELLS_MOST = 16;

struct VertexRegion
{
	int[REGION_SHELLS_MOST] shells;
	usz shell_count;
	bool boxed;
	Vec3 low;
	Vec3 high;
	bool banded;
	float from; // a height range, model units along Y
	float to;
	RegionSide side;
	float plane; // where the mirror plane is, for a side
	float middle; // how near the plane is on it, for MIDDLE
}

fn bool VertexRegion.narrows(&self) => self.shell_count > 0 || self.boxed || self.banded || self.side != ANY;

<*
 Whether vertex `v`, at `at` and in shell `shell`, lies in the region.
*>
fn bool VertexRegion.holds(&self, Vec3 at, int shell)
{
	if (self.shell_count > 0)
	{
		bool listed = false;
		for (usz i = 0; i < self.shell_count; i++) if (self.shells[i] == shell) listed = true;
		if (!listed) return false;
	}
	if (self.boxed)
	{
		if (at.x < self.low.x || at.y < self.low.y || at.z < self.low.z) return false;
		if (at.x > self.high.x || at.y > self.high.y || at.z > self.high.z) return false;
	}
	if (self.banded && (at.y < math::min(self.from, self.to) || at.y > math::max(self.from, self.to))) return false;
	switch (self.side)
	{
		case ANY: return true;
		case LEFT: return at.x > self.plane;
		case RIGHT: return at.x < self.plane;
		case MIDDLE: return math::abs(at.x - self.plane) <= self.middle;
	}
}

<*
 Every vertex of `positions` the region holds, in order. The caller owns the result.

 @param [in] shell_of : "A shell per vertex, or empty when the mesh has none to tell apart"
*>
fn uint[] region_vertices(Allocator allocator, VertexRegion* region, Vec3[] positions, int[] shell_of)
{
	usz count = 0;
	foreach (usz v, at : positions)
	{
		if (region.holds(at, shell_of.len > v ? shell_of[v] : 0)) count++;
	}
	if (count == 0) return {};
	uint[] out = alloc::new_array(allocator, uint, (sz)count);
	usz written = 0;
	foreach (usz v, at : positions)
	{
		if (region.holds(at, shell_of.len > v ? shell_of[v] : 0)) out[written++] = (uint)v;
	}
	return out;
}

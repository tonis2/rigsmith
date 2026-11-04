<* The pure half of src/app/areas.c3: no state, undo or notices. *>
module crig;

import rig;
import gltf;
import std::sort;
import std::math;
import std::math::vector;
import std::collections::list;

enum AreaPart : char
{
	OWN,            // vertices whose strongest joint is this one; a finger joint's segment
	WITH_CHILDREN,  // strongest joint anywhere at or below this one; a finger from this knuckle out
	ISLANDS,        // the UV islands this joint holds most of
	PIECE,          // the separate mesh piece under the clicked vertex
	CUSTOM,         // grown or shrunk by hand
}

fn String AreaPart.label(self)
{
	switch (self)
	{
		case OWN: return "Own bone";
		case WITH_CHILDREN: return "With children";
		case ISLANDS: return "UV islands";
		case PIECE: return "Whole piece";
		case CUSTOM: return "Custom";
	}
}

// One Grow or Shrink, and one step of a grow or shrink drag, as a fraction of the
// joint's own bone.
const float AREA_STEP = 0.1;

enum IslandPick : char
{
	TOGGLE, // in when out, out when in
	ADD,
	REMOVE,
}

// Which weld classes a vertex mask touches.
fn bool[] classes_of(rig::MeshAdjacency* around, bool[] mask) @private
{
	bool[] cls = alloc::new_array(mem, bool, (sz)around.classes());
	foreach (v, on : mask)
	{
		if (on) cls[(usz)around.class_of[v]] = true;
	}
	return cls;
}

// Where each weld class sits: the rest position of its first vertex. The caller
// frees the result.
fn Vec3[] class_points(rig::MeshAdjacency* around, Vec3[] positions) @private
{
	Vec3[] points = alloc::new_array(mem, Vec3, (sz)around.classes());
	bool[] seen = alloc::new_array(mem, bool, (sz)points.len);
	defer alloc::free(mem, seen);
	foreach (v, cls : around.class_of)
	{
		if (seen[(usz)cls]) continue;
		seen[(usz)cls] = true;
		points[(usz)cls] = positions[v];
	}
	return points;
}

struct AreaReach @private
{
	float distance;
	uint cls;
}

// A binary min-heap on distance, for the walks below.
fn void reach_push(List{AreaReach}* heap, AreaReach item) @private
{
	heap.push(item);
	sz at = heap.len() - 1;
	while (at > 0)
	{
		sz up = (at - 1) / 2;
		if ((*heap)[up].distance <= (*heap)[at].distance) break;
		AreaReach held = (*heap)[up];
		(*heap)[up] = (*heap)[at];
		(*heap)[at] = held;
		at = up;
	}
}

fn AreaReach reach_pop(List{AreaReach}* heap) @private
{
	AreaReach top = (*heap)[0];
	AreaReach last = heap.pop()!!;
	sz count = heap.len();
	if (count == 0) return top;
	(*heap)[0] = last;
	sz at = 0;
	while (true)
	{
		sz least = at;
		sz left = at * 2 + 1;
		sz right = left + 1;
		if (left < count && (*heap)[left].distance < (*heap)[least].distance) least = left;
		if (right < count && (*heap)[right].distance < (*heap)[least].distance) least = right;
		if (least == at) break;
		AreaReach held = (*heap)[least];
		(*heap)[least] = (*heap)[at];
		(*heap)[at] = held;
		at = least;
	}
	return top;
}

<*
 How far over the surface each weld class is from the nearest source class,
 walking mesh edges. Sources are 0; anything past `limit` is left at
 `float::max`, so a walk only pays for the band it is asked about.

 The caller frees the result.
*>
fn float[] surface_distances(rig::MeshAdjacency* around, Vec3[] points, bool[] sources, float limit) @private
{
	float[] distance = alloc::new_array(mem, float, (sz)sources.len);
	distance[..] = float::max;
	List{AreaReach} heap;
	heap.init(mem);
	defer heap.free();
	foreach (g, on : sources)
	{
		if (!on) continue;
		distance[g] = 0.0f;
		reach_push(&heap, { 0.0f, (uint)g });
	}
	while (heap.len() > 0)
	{
		AreaReach next = reach_pop(&heap);
		if (next.distance > distance[next.cls]) continue;
		foreach (n : around.around(next.cls))
		{
			float through = next.distance + (points[n] - points[next.cls]).length();
			if (through > limit || through >= distance[n]) continue;
			distance[n] = through;
			reach_push(&heap, { through, n });
		}
	}
	return distance;
}

<*
 How far in from the part's edge each weld class sits, over the surface: the
 walk to the nearest class outside the part, or `float::max` beyond `limit` or
 with no outside to walk to — a separate piece taken whole is interior
 throughout. Outside classes are 0.

 The caller frees the result.
*>
fn float[] edge_depths(rig::MeshAdjacency* around, Vec3[] points, bool[] cls, float limit) @private
{
	bool[] outside = alloc::new_array(mem, bool, (sz)cls.len);
	defer alloc::free(mem, outside);
	foreach (g, on : cls) outside[g] = !on;
	return surface_distances(around, points, outside, limit);
}

// The share a part states at a depth in from its edge: 1 past the soft edge,
// falling toward 0 at the boundary.
fn float area_share(float depth, float soft) @private
{
	if (soft <= 0.0f || depth >= soft) return 1.0f;
	return depth / soft;
}

// A brightness offset per island, scattered so neighbours rarely match.
fn float island_shade(int island) @private
{
	uint mixed = (uint)island * 2654435761u;
	return ((float)((mixed >> 13) & 7u) / 7.0f - 0.5f) * 0.16f;
}

// The shell under the seed, or with none the shell holding most of `own`.
fn int piece_for(rig::TriMesh* geometry, rig::MeshShells* shells, bool[] own, sz seed)
{
	usz count = geometry.positions.len;
	if (shells.of.len != count) return -1;
	if (seed >= 0 && (usz)seed < count) return shells.of[(usz)seed];
	if (shells.count == 0) return -1;

	usz[] tally = alloc::new_array(mem, usz, (sz)shells.count);
	defer alloc::free(mem, tally);
	foreach (v, id : shells.of)
	{
		if (own[v] && id >= 0) tally[(usz)id]++;
	}
	int best = -1;
	usz most = 0;
	foreach (i, held : tally)
	{
		if (held <= most) continue;
		most = held;
		best = (int)i;
	}
	return best;
}

<*
 A joint's soft edge as a share of its bone: what it was given (`Dot.band`), or
 the model's default. The one number the automatic weights' band, the card's
 slider and an Apply's soft edge all read.
*>
fn float band_share(RigDocument* doc, uint dot_id)
{
	Dot* dot = doc.find(dot_id);
	return dot && dot.band > 0.0f ? dot.band : BAND_SHARE_DEFAULT;
}

// Whether the mesh has more than one piece for Whole piece to pick between.
fn bool area_has_pieces(rig::TriMesh* geometry, rig::MeshShells* shells) => shells.count > 1 && shells.of.len == geometry.positions.len;

// The joint's own bone, or a slice of the model when it has none, which is what
// the card's fractions are fractions of.
fn float area_scale(RigDocument* doc, rig::TriMesh* geometry, uint dot_id)
{
	float bone = own_bone_length(doc, dot_id);
	if (bone > 0.0f) return bone;
	rig::Bounds box = geometry.bounds();
	return (box.max - box.min).length() * 0.1f;
}

// One Grow or Shrink step for a joint, in model units: a tenth of its bone.
fn float grow_step(RigDocument* doc, rig::TriMesh* geometry, uint dot_id) => area_scale(doc, geometry, dot_id) * AREA_STEP;


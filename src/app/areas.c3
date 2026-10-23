<*
 Joint areas: "this joint moves exactly this part".

 The user picks a part of the mesh for the selected joint — its own bone's
 vertices, its whole subtree's, the UV islands it holds, a separate piece, or a
 hand-grown patch — and Apply makes that part the joint's column: the joint
 moves the part and nothing outside it. Grow, Shrink and Soft edge reshape the
 joint's own bone instead, from the automatic weights with only this joint's
 edge moved (`AppState.tool_bind_for`).

 **One joint, one column.** Every tool here writes the selected joint's column
 (and its twin's, mirroring) and no other, and holds the joint (`Dot.held`) —
 the other joints keep what they hold, so where they hold the part too the two
 blend, and a vertex nothing else holds that the joint lets go of is left to
 nobody. The card's preview draws the column Apply writes, so pressing Apply
 changes nothing on screen.

 **The soft edge runs inward.** The band of the part nearest its boundary
 fades from the joint toward nothing, and nothing outside the part is given to
 the joint, so a separate piece — a part with no boundary — stays rigid
 whatever the edge width.

 **Reset lets go.** The joint's stored column, grow and soft edge are dropped
 and it follows the automatic weights again (`release_recorded`); nothing a
 neighbour holds is touched.
*>
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

<*
 The vertices of one part of the mesh for a joint.

 	`bool[] mask = app.area_part_mask(mem, head, WITH_CHILDREN);`

 OWN and WITH_CHILDREN read the bind as the screen shows it — the strongest joint
 of each row — so an own part is exactly the vertices the territory view paints
 in this joint's colour.

 **A finger joint's parts are cut at its knuckles instead** (`rig::DigitBands`,
 at a blend of nothing): its own segment, or with children everything from its
 knuckle to the tip. The automatic weights still say which vertices are the
 hand's, but not which joint along the finger — so a pin or a stroke that handed
 part of one segment to the wrong joint cannot move the part, and Apply puts the
 segment right rather than locking in what was there. ISLANDS is every UV island this joint is the strongest
 joint of more vertices of than any other joint is — the head's unwrap for the
 head — or with none such the island holding most of its own part. PIECE is the
 shell of `seed`, or with no seed the shell holding most of the own part. CUSTOM has no rule of its own and answers empty.

 @return `One flag per vertex, owned by the caller; empty when the part holds nothing.`
*>
fn bool[] AppState.area_part_mask(&self, Allocator allocator, uint dot_id, AreaPart part, sz seed = -1)
{
	usz count = self.geometry.positions.len;
	if (count == 0 || part == CUSTOM) return {};

	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);

	sz found = view.joint_of(dot_id);
	usz bones = view.len();
	if (found < 0 || bones == 0) return {};

	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (painted.len < count * bones) return {};

	bool[] mine = alloc::new_array(mem, bool, (sz)bones);
	defer alloc::free(mem, mine);
	mine[(usz)found] = true;
	if (part == WITH_CHILDREN)
	{
		for (usz j = 0; j < bones; j++)
		{
			for (int up = view.skeleton.parents[j]; up >= 0; up = view.skeleton.parents[(usz)up])
			{
				if (up != (int)found) continue;
				mine[j] = true;
				break;
			}
		}
	}

	// A finger's part from the knuckle planes, over the automatic bind — which
	// moves no knuckle plane for a grow, so neither does this. A piece riding one
	// joint rigidly keeps its rider, as it does in the bind.
	rig::DigitBands bands = rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);
	bool banded = (usz)found < bands.digit.len && bands.digit[(usz)found];
	float[] base = banded ? self.base_bind_for(&view) : {};
	if (base.len < count * bones) banded = false;
	float[] row = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, row);

	bool[] mask = alloc::new_array(allocator, bool, (sz)count);
	usz caught = 0;
	for (usz v = 0; v < count; v++)
	{
		float[] read = painted[v * bones:bones];
		if (banded)
		{
			row[..] = base[v * bones:bones];
			if (!rig::rides_rigidly(self.shells.of, self.shell_riders, v)) bands.band_row(row, self.geometry.positions[v], 0.0f);
			read = row;
		}
		sz owner = row_owner(read);
		if (owner < 0 || !mine[(usz)owner]) continue;
		mask[v] = true;
		caught++;
	}

	if (part == ISLANDS)
	{
		bool[] owned = self.islands_owned(mem, painted, bones, found);
		defer if (owned.len > 0) alloc::free(mem, owned);
		rig::MeshShells* split = self.islands_for();
		caught = 0;
		foreach (v, &on : mask)
		{
			*on = owned.len > 0 && split.of.len == count && owned[(usz)split.of[v]];
			if (*on) caught++;
		}
	}

	if (part == PIECE)
	{
		int shell = self.piece_for(mask, seed);
		caught = 0;
		foreach (v, id : self.shells.of)
		{
			mask[v] = shell >= 0 && id == shell;
			if (mask[v]) caught++;
		}
	}

	if (caught == 0)
	{
		alloc::free(allocator, mask);
		return {};
	}
	return mask;
}

// The shell under the seed, or with none the shell holding most of `own`.
fn int AppState.piece_for(&self, bool[] own, sz seed)
{
	usz count = self.geometry.positions.len;
	if (self.shells.of.len != count) return -1;
	if (seed >= 0 && (usz)seed < count) return self.shells.of[(usz)seed];
	if (self.shells.count == 0) return -1;

	usz[] tally = alloc::new_array(mem, usz, (sz)self.shells.count);
	defer alloc::free(mem, tally);
	foreach (v, id : self.shells.of)
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
 The mesh's UV islands, read from the source file the first time they are asked
 for and kept until the geometry changes. Empty when the file carries no
 texture coordinates, cannot be read, or no longer lines up with the mesh.
*>
fn rig::MeshShells* AppState.islands_for(&self)
{
	if (self.uv_islands_read && self.uv_islands_geometry == self.geometry_generation) return &self.uv_islands;
	self.uv_islands.free(mem);
	self.uv_islands_read = true;
	self.uv_islands_geometry = self.geometry_generation;
	if (self.source_path.len == 0 || self.geometry.positions.len == 0) return &self.uv_islands;

	gltf::GltfStream? opened = gltf::open(self.source_path, mem);
	if (catch opened) return &self.uv_islands;
	gltf::GltfStream stream = opened;
	defer stream.close();
	if (catch stream.load_all_buffers()) return &self.uv_islands;
	rig::Surface? read = rig::read_surface(mem, &stream);
	if (catch read) return &self.uv_islands;
	rig::Surface surface = read;
	defer surface.free(mem);
	if (!surface.has_uvs || !surface.fits(&self.geometry)) return &self.uv_islands;

	self.uv_islands = rig::build_uv_islands(mem, self.geometry, surface.uvs);
	return &self.uv_islands;
}

<*
 Which UV islands a joint holds: one flag per island, set where the joint is the
 strongest joint of at least as many of the island's vertices as any other
 joint is. With no such island, the one holding most of its vertices.

 @return `Owned by the caller; empty when the mesh has no islands or the joint holds nothing.`
*>
fn bool[] AppState.islands_owned(&self, Allocator allocator, float[] painted, usz bones, sz joint)
{
	rig::MeshShells* split = self.islands_for();
	usz count = self.geometry.positions.len;
	if (split.count == 0 || split.of.len != count || painted.len < count * bones) return {};

	// Island and owner in one key, so one sort lines each island's owners up.
	ulong span = (ulong)bones + 1;
	ulong[] keys = alloc::new_array(mem, ulong, (sz)count);
	defer alloc::free(mem, keys);
	for (usz v = 0; v < count; v++)
	{
		sz owner = row_owner(painted[v * bones:bones]);
		keys[v] = (ulong)split.of[v] * span + (ulong)(owner + 1);
	}
	sort::quicksort(keys);

	usz[] held = alloc::new_array(mem, usz, (sz)split.count);
	usz[] rival = alloc::new_array(mem, usz, (sz)split.count);
	defer
	{
		alloc::free(mem, held);
		alloc::free(mem, rival);
	}
	usz run = 0;
	for (usz i = 1; i <= count; i++)
	{
		if (i < count && keys[i] == keys[run]) continue;
		usz island = (usz)(keys[run] / span);
		sz owner = (sz)(keys[run] % span) - 1;
		usz n = i - run;
		if (owner == joint)
		{
			held[island] = n;
		}
		else if (owner >= 0 && n > rival[island])
		{
			rival[island] = n;
		}
		run = i;
	}

	bool[] out = alloc::new_array(allocator, bool, (sz)split.count);
	bool some = false;
	usz best = 0;
	foreach (usz g, n : held)
	{
		out[g] = n > 0 && n >= rival[g];
		some = some || out[g];
		if (n > held[best]) best = g;
	}
	if (!some)
	{
		if (held[best] == 0)
		{
			alloc::free(allocator, out);
			return {};
		}
		out[best] = true;
	}
	return out;
}

// Whether the texture layout cuts the mesh finer than its pieces do, so that
// UV islands is a part of its own.
fn bool AppState.area_has_islands(&self)
{
	rig::MeshShells* split = self.islands_for();
	return split.of.len == self.geometry.positions.len && split.count > math::max(self.shells.count, (usz)1);
}

// How many UV islands the pending part takes in.
fn usz AppState.area_island_count(&self)
{
	rig::MeshShells* split = self.islands_for();
	if (split.of.len != self.area_mask.len || split.count == 0) return 0;
	bool[] seen = alloc::new_array(mem, bool, (sz)split.count);
	defer alloc::free(mem, seen);
	usz total = 0;
	foreach (v, on : self.area_mask)
	{
		if (!on || seen[(usz)split.of[v]]) continue;
		seen[(usz)split.of[v]] = true;
		total++;
	}
	return total;
}

enum IslandPick : char
{
	TOGGLE, // in when out, out when in
	ADD,
	REMOVE,
}

// The UV island under a vertex, or -1 when the mesh has no islands to pick.
fn int AppState.island_under(&self, sz vertex)
{
	rig::MeshShells* split = self.islands_for();
	usz count = self.geometry.positions.len;
	if (vertex < 0 || (usz)vertex >= count || split.of.len != count) return -1;
	return split.of[(usz)vertex];
}

<*
 Put the UV island under a vertex in the part, or take it out. The last island
 can go too: an empty part is how a hand-picked one starts (see
 `clear_area_islands`), and Apply refuses it.

 @return `True when the part changed.`
*>
fn bool AppState.pick_area_island(&self, sz vertex, IslandPick how = TOGGLE)
{
	int island = self.island_under(vertex);
	if (island < 0 || self.area_mask.len != self.geometry.positions.len) return false;
	bool take = how == ADD || (how == TOGGLE && !self.area_mask[(usz)vertex]);
	if (self.area_mask[(usz)vertex] == take) return false;
	return self.set_area_island(island, take);
}

fn bool AppState.toggle_area_island(&self, sz vertex) => self.pick_area_island(vertex, TOGGLE);

// Every vertex of one island in or out of the part, marked as hand-made.
fn bool AppState.set_area_island(&self, int island, bool take)
{
	rig::MeshShells* split = self.islands_for();
	if (island < 0 || split.of.len != self.area_mask.len) return false;
	bool changed = false;
	foreach (v, &on : self.area_mask)
	{
		if (split.of[v] != island || *on == take) continue;
		*on = take;
		changed = true;
	}
	if (!changed) return false;
	self.area_island_picked();
	return true;
}

// After a hand pick: the part is islands, made by hand, and the twin follows.
fn void AppState.area_island_picked(&self)
{
	self.area_part = CUSTOM;
	self.area_islands = true;
	self.refresh_area_twin();
	self.area_changed();
}

// The part with no islands in it, to pick them one by one from nothing.
fn bool AppState.clear_area_islands(&self)
{
	if (!self.areaing || !self.area_has_islands()) return false;
	usz count = self.geometry.positions.len;
	if (self.area_mask.len != count)
	{
		if (self.area_mask.len > 0) alloc::free(mem, self.area_mask);
		self.area_mask = alloc::new_array(mem, bool, (sz)count);
	}
	self.area_mask[..] = false;
	self.area_island_picked();
	return true;
}

// Every island the part leaves out, and none it holds: "all but the head".
fn bool AppState.invert_area_islands(&self)
{
	if (!self.areaing || !self.area_islands || self.area_mask.len != self.geometry.positions.len) return false;
	foreach (&on : self.area_mask) *on = !*on;
	self.area_island_picked();
	return true;
}

// Whether the pending part holds no vertex at all (a cleared island part).
fn bool AppState.area_empty(&self)
{
	foreach (on : self.area_mask) if (on) return false;
	return true;
}

<*
 Start painting islands in (`add`) or out at a vertex: the island under it
 first, then every island `island_paint_to` crosses.

 @return `False off the islands, so the press can fall through to the camera.`
*>
fn bool AppState.begin_island_paint(&self, sz vertex, bool add)
{
	if (!self.areaing || !self.area_islands) return false;
	self.area_follow_selection();
	if (!self.area_shaping()) return false;
	if (self.island_under(vertex) < 0 || self.area_mask.len != self.geometry.positions.len) return false;
	self.area_paint_adds = add;
	self.pick_area_island(vertex, add ? ADD : REMOVE);
	return true;
}

fn bool AppState.island_paint_to(&self, sz vertex)
{
	if (!self.areaing || !self.area_islands) return false;
	return self.pick_area_island(vertex, self.area_paint_adds ? ADD : REMOVE);
}

<*
 The island the pointer is over, for the picture to light. Moves the picture
 only when the island does, so a hover across one island costs nothing.
*>
fn void AppState.hover_area_island(&self, int island)
{
	if (!self.areaing || !self.area_islands) island = -1;
	if (island == self.area_hover_island) return;
	self.area_hover_island = island;
	self.area_changed();
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

// The joint's own bone, or a slice of the model when it has none, which is what
// the card's fractions are fractions of.
fn float AppState.area_scale(&self, uint dot_id)
{
	float bone = self.own_bone_length(dot_id);
	if (bone > 0.0f) return bone;
	rig::Bounds box = self.geometry.bounds();
	return (box.max - box.min).length() * 0.1f;
}

// The soft edge the card asks for, in model units.
fn float AppState.area_soft_distance(&self) => self.band_share(self.area_dot) * self.area_scale(self.area_dot);

<*
 A joint's soft edge as a share of its bone: what it was given (`Dot.band`), or
 the model's default. The one number the automatic weights' band, the card's
 slider and an Apply's soft edge all read.
*>
fn float AppState.band_share(&self, uint dot_id)
{
	Dot* dot = self.doc.find(dot_id);
	return dot && dot.band > 0.0f ? dot.band : BAND_SHARE_DEFAULT;
}

<*
 The same part on the twin joint across the symmetry plane.

 OWN and WITH_CHILDREN are asked of the twin by their own rule, which follows
 the twin's actual bind rather than a reflection that a slightly asymmetric mesh
 would miss. A piece takes the shell under the seed's reflection; a custom part
 reflects vertex by vertex, and a vertex with no reflection is left out.

 @return `One flag per vertex, owned by the caller; empty when there is nothing across.`
*>
fn bool[] AppState.area_twin_part(&self, Allocator allocator, uint twin, AreaPart part, bool[] mask, sz seed)
{
	usz count = self.geometry.positions.len;
	if (twin == 0 || mask.len != count) return {};
	if (part == OWN || part == WITH_CHILDREN || part == ISLANDS) return self.area_part_mask(allocator, twin, part);

	rig::MirrorLookup across = self.mesh_mirror(mem);
	defer across.free(mem);

	if (part == PIECE && seed >= 0 && (usz)seed < count)
	{
		sz other = across.twin_of(self.geometry.positions[(usz)seed]);
		if (other < 0) return {};
		return self.area_part_mask(allocator, twin, PIECE, other);
	}

	bool[] out = alloc::new_array(allocator, bool, (sz)count);
	usz caught = 0;
	foreach (v, on : mask)
	{
		if (!on) continue;
		sz other = across.twin_of(self.geometry.positions[v]);
		if (other < 0 || out[(usz)other]) continue;
		out[(usz)other] = true;
		caught++;
	}
	if (caught == 0)
	{
		alloc::free(allocator, out);
		return {};
	}
	// A reflection lands on one copy of a split point; the others go with it.
	rig::MeshAdjacency* around = self.adjacency_for();
	if (around.vertices() == count)
	{
		bool[] cls = classes_of(around, out);
		defer alloc::free(mem, cls);
		foreach (v, &on : out) *on = cls[(usz)around.class_of[v]];
	}
	// A part of whole islands stays whole islands across: a layout a little off
	// symmetric still takes the twin's island rather than most of it.
	rig::MeshShells* split = self.islands_for();
	if (self.area_islands && split.of.len == count)
	{
		bool[] taken = alloc::new_array(mem, bool, (sz)split.count);
		defer alloc::free(mem, taken);
		foreach (v, on : out) if (on) taken[(usz)split.of[v]] = true;
		foreach (v, &on : out) *on = taken[(usz)split.of[v]];
	}
	return out;
}

<*
 Make a joint move exactly these vertices, and optionally its twin the mirrored
 ones, as one undo step.

 	`usz held = app.apply_area(head, mask, soft: app.area_soft_distance());`

 The joint's column becomes the part: 1 inside, falling toward 0 within `soft`
 (model units, over the surface) of the edge, and nothing outside it
 (`area_column`). That column and the twin's are all it writes — the other
 joints keep exactly what they hold, inside the part as well as outside, so on a
 vertex another joint holds the two blend, and a vertex outside the part that
 only this joint held is left to nobody (unused). Both joints are held from here
 on.

 A part reaching off the joint's limb gives it nothing there (`limb_family`).
 Not a vertex the joint already holds — a rim an earlier Apply gave it stays its
 own on the next — and not a part of whole `pieces`, Whole piece or UV islands,
 which the menu named rather than a hand pressed out.

 @param twin_mask : `The twin's part, or empty for none.`
 @param pieces : `The parts are whole pieces of the mesh, applied whole off the limb too — see area_names_pieces.`
 @param refused : `Filled with how many vertices of the parts were off their joint's limb. Null to not ask.`
 @return `How many vertices the joint and its twin now hold; 0 when nothing changed.`
*>
fn usz AppState.apply_area(&self, uint dot_id, bool[] mask, float soft, uint twin = 0, bool[] twin_mask = {},
	bool pieces = false, usz* refused = null)
{
	if (refused) *refused = 0;
	self.flush_edges();
	usz count = self.geometry.positions.len;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);

	bool with_twin = twin != 0 && twin != dot_id && twin_mask.len == count && view.joint_of(twin) >= 0;
	uint[2] owners = { dot_id, twin };
	bool[][2] parts = { mask, twin_mask };
	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);

	usz held = 0;
	usz moved = 0;
	usz sides = with_twin ? 2 : 1;
	for (usz p = 0; p < sides; p++)
	{
		usz off = 0;
		usz caught = self.area_column(&view, painted, owners[p], parts[p], soft, pieces, column, &off);
		if (refused) *refused += off;
		if (caught == 0) continue;
		held += caught;
		moved += self.replace_column(&view, owners[p], column, commit: false);
	}
	if (moved == 0) return 0;
	self.undo_stack.commit();
	return held;
}

<*
 The column an Apply gives a joint: what `apply_area` writes, and what the
 Weights card draws while a part waits for it — one computation, so the picture
 is the weights Apply leaves.

 @param painted : `The weights as shown — AppState.weights of the same view.`
 @param column : `Filled, one weight per vertex: the part's ramp, 0 outside it.`
 @param pieces : `The part is whole pieces, not limited to the limb — see apply_area.`
 @param refused : `Filled with how many part vertices were off the joint's limb and left out. Null to not ask.`
 @return `How many vertices the joint would hold; 0 when there is nothing to state.`
*>
fn usz AppState.area_column(&self, RigView* view, float[] painted, uint dot_id, bool[] mask, float soft,
	bool pieces, float[] column, usz* refused = null)
{
	if (refused) *refused = 0;
	usz count = self.geometry.positions.len;
	if (count == 0 || mask.len != count || column.len != count) return 0;
	column[..] = 0.0f;

	rig::MeshAdjacency* around = self.adjacency_for();
	if (around.vertices() != count) return 0;

	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || bones == 0 || painted.len < count * bones) return 0;

	float[] automatic = self.weights(mem, view, AUTOMATIC);
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	if (automatic.len < count * bones) return 0;

	// The part as far as the joint's limb goes, with whatever the joint already
	// holds, and its soft edge measured from there — so a part reaching off the
	// limb fades out where it stops rather than ending in a step.
	bool[] family = limb_family(mem, &view.skeleton, (usz)joint);
	defer alloc::free(mem, family);
	bool[] part = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, part);
	foreach (v, on : mask)
	{
		if (!on) continue;
		usz at = (usz)v * bones;
		part[v] = pieces || on_limb(automatic[at:bones], family) || joint_share(painted[at:bones], (usz)joint) >= AREA_LEAK_FLOOR;
		if (!part[v] && refused) (*refused)++;
	}

	float limit = math::max(soft, 0.0f);
	Vec3[] points = class_points(around, self.geometry.positions);
	defer alloc::free(mem, points);
	bool[] cls = classes_of(around, part);
	defer alloc::free(mem, cls);
	float[] depth = edge_depths(around, points, cls, limit);
	defer alloc::free(mem, depth);

	usz held = 0;
	foreach (v, on : part)
	{
		if (!on) continue;
		held++;
		column[v] = area_share(depth[(usz)around.class_of[v]], limit);
	}
	return held;
}

<*
 Open the Area tool on the selected joint. It borrows the falloff view, the
 way the brush does, and paints the pending part over it.

 @return `False with nothing selected, which the caller says out loud.`
*>
fn bool AppState.begin_area(&self)
{
	if (!self.has_mesh() || !self.doc.find(self.selected)) return false;
	if (self.areaing) return true;

	self.end_brush();
	self.end_lasso();
	self.end_sketch();

	self.areaing = true;
	self.area_dot = self.selected;
	self.drop_area_part();
	self.area_tint = self.tint_mode;
	self.show_tint(FALLOFF);
	return true;
}

<*
 Close the Area tool. A part still pending is dropped, not applied: Apply is the
 one door that writes.
*>
fn void AppState.end_area(&self)
{
	if (!self.areaing) return;
	self.areaing = false;
	self.area_by_card = false;
	self.end_grow_drag();
	self.drop_area_part();
	if (self.tint_mode == FALLOFF) self.show_tint(self.area_tint);
}

// Forget the pending part, keeping the tool open.
fn void AppState.drop_area_part(&self)
{
	if (self.area_mask.len > 0) alloc::free(mem, self.area_mask);
	if (self.area_twin_mask.len > 0) alloc::free(mem, self.area_twin_mask);
	self.area_mask = {};
	self.area_twin_mask = {};
	self.area_twin = 0;
	self.area_seed = -1;
	self.area_part = OWN;
	self.area_origin = OWN;
	self.area_islands = false;
	self.area_hover_island = -1;
	self.area_changed();
}

// The picture has to catch up with the part; the bind underneath did not move.
// A part pending is a part on show: the mesh shows what Apply would leave.
fn void AppState.area_changed(&self)
{
	self.area_generation++;
	self.area_preview = self.area_mask.len > 0;
	if (!self.tinting()) return;
	self.weights_stale = true;
	self.weights_due = 0.0f;
}

// Follow the selection: a part picked for one joint means nothing for another.
fn void AppState.area_follow_selection(&self)
{
	if (!self.areaing || self.selected == self.area_dot) return;
	self.end_grow_drag();
	self.drop_area_part();
	self.area_dot = self.selected;
}

// Whether the sidebar is showing the Weights card.
fn bool AppState.weights_card_open(&self) => self.show_joint_panel && self.joint_panel_tab == JointPanelTab.WEIGHTS;

<*
 Keep the Area tool in step with the Weights card: showing the card on a joint
 opens the tool on the joint's own bone — live, so Grow, Shrink and the soft edge
 change the joint as they are pressed and there is nothing waiting for Apply;
 hiding it closes the tool again if the card was what opened it. Called
 wherever the card is shown or hidden.
*>
fn void AppState.sync_weights_card(&self)
{
	if (self.weights_card_open())
	{
		// The brush, opened from the card, has the mesh; the Area tool waits.
		if (self.brushing) return;
		if (!self.has_mesh() || !self.doc.find(self.selected)) return;
		if (!self.areaing)
		{
			if (!self.begin_area()) return;
			self.area_by_card = true;
		}
		self.area_follow_selection();
		return;
	}
	if (self.areaing && self.area_by_card) self.end_area();
}

// Close the brush and give the Weights card its Area tool back. The strokes are
// already on the mesh; nothing is pending.
fn void AppState.leave_brush(&self)
{
	self.end_brush();
	self.sync_weights_card();
}

// Whether the mesh has more than one piece for Whole piece to pick between.
fn bool AppState.area_has_pieces(&self) => self.shells.count > 1 && self.shells.of.len == self.geometry.positions.len;

fn bool AppState.area_pending(&self) => self.area_mask.len > 0;

fn usz AppState.area_held(&self)
{
	usz held = 0;
	foreach (on : self.area_mask) if (on) held++;
	foreach (on : self.area_twin_mask) if (on) held++;
	return held;
}

// Whether the twin gets the mirrored part too.
fn bool AppState.area_mirrors(&self) => !self.area_solo;

<*
 Whether the part on show names whole pieces of the mesh — Whole piece, or UV
 islands — which Apply hands over whole, off the joint's limb too
 (`limb_family`): the menu chose them by name, where a grown part or a stroke
 went wherever the pointer was.
*>
fn bool AppState.area_names_pieces(&self) => self.area_islands || self.area_part == PIECE;

// Re-read the twin's part from the joint's, after the joint's changed.
fn void AppState.refresh_area_twin(&self)
{
	if (self.area_twin_mask.len > 0) alloc::free(mem, self.area_twin_mask);
	self.area_twin_mask = {};
	self.area_twin = 0;
	if (!self.area_mirrors() || self.area_mask.len == 0) return;
	uint twin = self.mirror_twin(self.area_dot);
	if (twin == 0) return;
	self.area_twin_mask = self.area_twin_part(mem, twin, self.area_part, self.area_mask, self.area_seed);
	if (self.area_twin_mask.len > 0) self.area_twin = twin;
}

<*
 Pick a part for the selected joint: the card's Part menu, Own bone to UV islands.

 @param seed : `The vertex it was picked at, or -1 to keep the last one.`
 @return `False when that level holds nothing, which is said on the result line.`
*>
fn bool AppState.set_area_part(&self, AreaPart part, sz seed = -1)
{
	if (!self.areaing && !self.begin_area()) return false;
	self.area_follow_selection();
	if (seed >= 0) self.area_seed = seed;

	// The joint's own bone is live — Grow, Shrink and the soft edge change it
	// directly — so choosing it puts away whatever part was waiting for Apply.
	if (part == OWN || part == CUSTOM)
	{
		self.drop_area_part();
		return true;
	}
	if (part == PIECE && !self.area_has_pieces())
	{
		// One piece is the whole model: picking it would hand the joint everything.
		self.@notice("the mesh is one piece, so Whole piece would be all of it — grow or shrink the joint instead");
		return false;
	}
	if (part == ISLANDS && !self.area_has_islands())
	{
		self.@notice("this model has no UV layout that splits the mesh into islands");
		return false;
	}

	bool[] mask = self.area_part_mask(mem, self.area_dot, part, self.area_seed);
	if (self.area_mask.len > 0) alloc::free(mem, self.area_mask);
	self.area_mask = mask;
	self.area_part = part;
	if (part == OWN || part == WITH_CHILDREN || part == ISLANDS) self.area_origin = part;
	self.area_islands = part == ISLANDS;
	self.refresh_area_twin();
	self.area_changed();

	if (mask.len == 0)
	{
		self.@notice("%s holds none of the mesh as %s", self.area_joint_name(), part.label());
		return false;
	}
	return true;
}

<*
 Whether a part is waiting for Apply — With children or UV islands, chosen in
 the Part menu. The joint's own bone never waits: it is changed live.
*>
fn bool AppState.area_shaping(&self) => self.areaing && self.area_pending();

<*
 A click on the mesh in the Area tool. Only UV islands on show take one: it adds
 the island under it, or takes it out (`how` picks which). Any other click picks
 no part and steps nowhere — the Part menu is where a part is chosen, and a
 click that walked Own bone → With children turned every click meant for the
 view into a different part, the moment after an Apply included.

 @return `Whether the part changed.`
*>
fn bool AppState.area_click(&self, sz vertex, IslandPick how = TOGGLE)
{
	if (!self.areaing || vertex < 0) return false;
	self.area_follow_selection();
	if (!self.area_shaping() || !self.area_islands) return false;
	return self.pick_area_island(vertex, how);
}

// One Grow or Shrink step for a joint, in model units: a tenth of its bone.
fn float AppState.grow_step(&self, uint dot_id) => self.area_scale(dot_id) * AREA_STEP;

<*
 Push the selected joint's region out by whole steps, or pull it in — the card's
 Grow and Shrink, and the twin with it while Mirror is on.

 The joint's column is rewritten from the automatic weights with its edge moved
 that far (`Dot.grow`, `shape_edges`), so the mesh shows the result as the
 button is pressed and there is nothing to Apply. Only this joint's column (and
 the twin's) changes: the neighbours keep what they hold, so the grown edge
 blends over them rather than taking their vertices. One undo step per press.

 @return `Whether anything changed.`
*>
fn bool AppState.grow_joint(&self, int steps)
{
	Dot* dot = self.doc.find(self.selected);
	if (!dot || steps == 0) return false;
	uint id = dot.id;
	bool wrote = self.set_grow_recorded(id, dot.grow + (float)steps * self.grow_step(id));
	uint twin = self.area_mirrors() ? self.mirror_twin(id) : 0;
	Dot* other = twin != 0 ? self.doc.find(twin) : null;
	if (other && self.set_grow_recorded(twin, other.grow + (float)steps * self.grow_step(twin))) wrote = true;
	if (!wrote) return false;
	uint[2] dots = { id, other ? twin : 0 };
	self.shape_edges(dots[..]);
	self.undo_stack.commit();
	return true;
}

<*
 Write each joint's column from the automatic weights with its own grow and
 soft edge on it (`tool_bind_for`): what Grow, Shrink and Soft edge leave.
 Leaves the group open for the caller.

 @param dots : `The joint and its twin, or 0s for none.`
 @return `How many vertices changed.`
*>
fn usz AppState.shape_edges(&self, uint[] dots)
{
	self.edge_pending = false;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	usz count = self.geometry.positions.len;
	usz bones = view.len();
	float[] shaped = self.tool_bind_for(&view, dots);
	if (shaped.len < count * bones) return 0;
	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	usz moved = 0;
	foreach (id : dots)
	{
		sz joint = view.joint_of(id);
		if (joint < 0) continue;
		for (usz v = 0; v < count; v++) column[v] = shaped[v * bones + (usz)joint];
		moved += self.replace_column(&view, id, column, commit: false);
	}
	return moved;
}

<*
 A grow drag or a soft-edge slider changed an edge: rewrite the columns once
 the hand is still (`tick_edges`) rather than binding on every mouse move.
*>
fn void AppState.edges_moved(&self, uint dot_id, uint twin)
{
	self.edge_dots = { dot_id, twin };
	self.edge_pending = true;
	self.edge_due = WEIGHT_DEBOUNCE;
}

// Rewrite the columns an edge drag is waiting on, now. Safe with none pending.
fn void AppState.flush_edges(&self)
{
	if (self.edge_pending) self.shape_edges(self.edge_dots[..]);
}

<*
 The edge drag's debounce, one frame's worth — `tick_weights`' sibling, and run
 whether or not a weight view is up, since what it writes is the weights.
*>
fn void AppState.tick_edges(&self, float dt)
{
	if (!self.edge_pending) return;
	self.edge_due -= dt;
	if (self.edge_due > 0.0f) return;
	self.flush_edges();
}

<*
 Start a grow or shrink drag on the mesh (shift-drag grows, ctrl-drag shrinks):
 the same edge as the card's buttons, a step per stretch of the drag, and one
 undo step for the whole drag. Remembers where the joint and its twin started
 so dragging back takes steps off again.
*>
fn bool AppState.begin_grow_drag(&self)
{
	if (!self.areaing || self.area_shaping()) return false;
	self.area_follow_selection();
	Dot* dot = self.doc.find(self.area_dot);
	if (!dot) return false;
	self.grow_drag = true;
	self.grow_drag_from = dot.grow;
	uint twin = self.area_mirrors() ? self.mirror_twin(dot.id) : 0;
	Dot* other = twin != 0 ? self.doc.find(twin) : null;
	self.grow_drag_twin = other ? twin : 0;
	self.grow_drag_twin_from = other ? other.grow : 0.0f;
	return true;
}

// The drag's travel as steps from where it started.
fn bool AppState.grow_drag_to(&self, int steps)
{
	if (!self.grow_drag) return false;
	bool wrote = self.set_grow_recorded(self.area_dot, self.grow_drag_from + (float)steps * self.grow_step(self.area_dot));
	if (self.grow_drag_twin != 0
		&& self.set_grow_recorded(self.grow_drag_twin,
			self.grow_drag_twin_from + (float)steps * self.grow_step(self.grow_drag_twin))) wrote = true;
	if (wrote) self.edges_moved(self.area_dot, self.grow_drag_twin);
	return wrote;
}

// The button came up: the columns catch up and the drag is one undo step. Safe
// with no drag open.
fn void AppState.end_grow_drag(&self)
{
	if (!self.grow_drag) return;
	self.grow_drag = false;
	self.flush_edges();
	self.undo_stack.commit();
}

<*
 Set how far the selected joint blends with its neighbours — the card's Soft
 edge — and the twin's with it while Mirror is on. Leaves the group open so a
 slider drag is one undo step; `commit_soft_edge`, on the release, writes the
 columns and closes it.

 @param share : `A share of the joint's bone.`
*>
fn bool AppState.soften_joint(&self, float share)
{
	Dot* dot = self.doc.find(self.selected);
	if (!dot) return false;
	uint id = dot.id;
	bool wrote = self.set_band_recorded(id, share);
	uint twin = self.area_mirrors() ? self.mirror_twin(id) : 0;
	if (twin != 0 && !self.doc.find(twin)) twin = 0;
	if (twin != 0 && self.set_band_recorded(twin, share)) wrote = true;
	if (wrote) self.edges_moved(id, twin);
	return wrote;
}

// The soft-edge slider came up: the columns catch up, one undo step.
fn void AppState.commit_soft_edge(&self)
{
	self.flush_edges();
	self.undo_stack.commit();
}

fn String AppState.area_joint_name(&self)
{
	Dot* dot = self.doc.find(self.area_dot != 0 ? self.area_dot : self.selected);
	return dot && dot.name.len > 0 ? dot.name : "this joint";
}

<*
 Apply the pending part (Enter, or the card's Apply), then drop it.

 @return `How many vertices the joint and its twin now hold; 0 when nothing was written.`
*>
fn usz AppState.commit_area(&self)
{
	// Apply while painting means done: the brush wrote each stroke as it went.
	if (self.brushing)
	{
		self.leave_brush();
		self.@notice("%s keeps what you painted — brush strokes apply as you paint", self.area_joint_name());
		return 0;
	}
	if (!self.areaing || self.area_mask.len == 0)
	{
		self.@notice("%s's own bone is live — Grow, Shrink and Soft edge change it as you press them; With children and UV islands are what Apply writes",
			self.area_joint_name());
		return 0;
	}
	if (self.area_empty())
	{
		self.@notice("pick at least one island first — click the mesh");
		return 0;
	}
	if (!self.doc.find(self.area_dot)) return 0;

	usz refused = 0;
	usz held = self.apply_area(self.area_dot, self.area_mask, self.area_soft_distance(), self.area_twin, self.area_twin_mask,
		self.area_names_pieces(), &refused);
	String name = self.area_joint_name();
	// What a part off the joint's limb left out (`limb_family`), and the way to hand it over anyway.
	String past = refused > 0 ? string::tformat(" · %d past its limb left alone, Lasso pin (shift+T) hands them over", refused) : "";
	if (held == 0 && refused > 0)
	{
		self.@notice("that part is off %s's limb · Lasso pin (shift+T) hands vertices over", name);
	}
	else if (held == 0)
	{
		self.@notice("%s already moves exactly that part", name);
	}
	else if (self.area_twin != 0)
	{
		Dot* twin = self.doc.find(self.area_twin);
		self.@notice("%s and %s now move %d vertices%s", name,
			twin && twin.name.len > 0 ? twin.name : "its twin", held, past);
	}
	else
	{
		self.@notice("%s now moves %d vertices%s", name, held, past);
	}
	self.drop_area_part();
	return held;
}

<*
 Reset to automatic for the selected joint (and its twin when mirroring): its
 stored weights, grow and soft edge are let go, and it follows the automatic
 weights again (`release_recorded`), while nothing a neighbour holds is touched.
 One undo step.

 @return `How many joints were let go.`
*>
fn usz AppState.reset_joint_area(&self)
{
	uint id = self.selected;
	if (!self.doc.find(id))
	{
		self.@notice("select a joint first");
		return 0;
	}
	uint twin = self.area_mirrors() ? self.mirror_twin(id) : 0;
	if (self.areaing)
	{
		self.end_grow_drag();
		self.drop_area_part();
	}

	usz released = self.release_recorded(id) ? 1 : 0;
	if (twin != 0 && self.release_recorded(twin)) released++;
	self.undo_stack.commit();

	Dot* dot = self.doc.find(id);
	String name = dot.name.len > 0 ? dot.name : "this joint";
	if (released == 0)
	{
		self.@notice("%s already uses automatic weights", name);
	}
	else
	{
		self.@notice("%s follows the automatic weights again", name);
	}
	return released;
}

<*
 The vertex under a pixel, front surfaces only: the nearest projected vertex
 within `radius` that nothing nearer hides. Posed or at rest, whichever is on
 screen — see `shown_position`.

 @return `The vertex, or -1 for none.`
*>
fn sz AppState.vertex_under(&self, Matrix4f view_projection, Vec2 viewport, Vec3 eye, Vec2 at, float radius)
{
	usz count = self.geometry.positions.len;
	if (count == 0) return -1;

	float reach = radius * radius;
	List{uint} near;
	near.init(mem);
	defer near.free();
	List{float} gaps;
	gaps.init(mem);
	defer gaps.free();

	for (usz v = 0; v < count; v++)
	{
		Vec2? where = project(view_projection, self.shown_position(v), viewport);
		if (catch where) continue;
		Vec2 gap = where - at;
		float span = gap.x * gap.x + gap.y * gap.y;
		if (span > reach) continue;
		near.push((uint)v);
		gaps.push(span);
	}

	// Nearest first, and only as many visibility casts as it takes.
	for (usz tried = 0; tried < 48; tried++)
	{
		sz best = -1;
		for (sz i = 0; i < near.len(); i++)
		{
			if (gaps[i] < 0.0f) continue;
			if (best < 0 || gaps[i] < gaps[best]) best = i;
		}
		if (best < 0) return -1;
		uint v = near[best];
		if (!self.mesh_hidden_surface(eye, self.shown_position(v))) return (sz)v;
		gaps[best] = -1.0f;
	}
	return -1;
}

// A brightness offset per island, scattered so neighbours rarely match.
fn float island_shade(int island) @private
{
	uint mixed = (uint)island * 2654435761u;
	return ((float)((mixed >> 13) & 7u) / 7.0f - 0.5f) * 0.16f;
}

<*
 Draw the part waiting for Apply as the weights Apply would leave: each row it
 states, read the way the bind reads it once laid, on the scale the view is
 already drawn on — the joint's share on the falloff ramp, or the strongest
 joint on the territory map. Every other vertex keeps the weights it has.

 The column is `area_column`, the one Apply writes, swapped into each row in
 place of the joint's (and the twin's) as the funnel would. So pressing Apply
 changes nothing on screen, and the brush then shows what the card showed.

 Only once the part has been shaped by hand (`area_preview`). The part the card
 picks for itself, so its buttons have something to act on, leaves the weights
 on show as they are — the card and the brush draw the same numbers until the
 user asks to see a part.

 Picking UV islands, the islands outside the part keep a grey of their own so
 the seams show, and the one under the pointer is lit.

 @param painted : `The bind the view was drawn from — AppState.weights of the same view.`
*>
fn void AppState.overlay_area_tints(&self, RigView* view, float[] painted)
{
	usz count = self.geometry.positions.len;
	if (!self.areaing || !self.area_preview || self.tints.len != count || self.area_mask.len != count) return;
	if (self.tint_mode == OFF || self.area_dot != self.selected) return;

	usz bones = view.len();
	sz joint = view.joint_of(self.area_dot);
	if (joint < 0 || bones == 0) return;

	float[] shown = alloc::new_array(mem, float, (sz)painted.len);
	defer alloc::free(mem, shown);
	shown[..] = painted[..];
	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	bool[] touched = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, touched);

	uint[2] owners = { self.area_dot, self.area_twin };
	bool[][2] parts = { self.area_mask, self.area_twin_mask };
	usz held = 0;
	foreach (p, owner : owners)
	{
		sz side = view.joint_of(owner);
		if (side < 0 || parts[p].len != count || (p > 0 && owner == self.area_dot)) continue;
		held += self.area_column(view, painted, owner, parts[p], self.area_soft_distance(), self.area_names_pieces(), column);
		for (usz v = 0; v < count; v++)
		{
			if (column[v] == shown[v * bones + (usz)side]) continue;
			shown[v * bones + (usz)side] = column[v];
			touched[v] = true;
		}
	}
	if (held == 0) return;

	bool falloff = self.tint_mode == FALLOFF;
	for (usz v = 0; v < count; v++)
	{
		if (!touched[v]) continue;
		float[] row = shown[v * bones:bones];
		self.tints[v] = falloff ? share_tint(joint_share(row, (usz)joint)) : joint_tint(strongest_joint(row));
	}

	rig::MeshShells* split = self.islands_for();
	if (!self.area_islands || split.of.len != count) return;
	for (usz v = 0; v < count; v++)
	{
		int island = split.of[v];
		if (island >= 0 && island == self.area_hover_island)
		{
			// Orange for an island a click would add, red for one it would take out.
			self.tints[v] = self.area_mask[v] ? rgb(0.85f, 0.25f, 0.2f) : rgb(1.0f, 0.75f, 0.4f);
		}
		else if (falloff && !self.area_mask[v] && island >= 0)
		{
			// Neighbouring islands differ in brightness, so the seams show.
			float grey = WEIGHT_GREY.x + island_shade(island);
			self.tints[v] = rgb(grey, grey, grey);
		}
	}
}

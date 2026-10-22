<*
 Joint areas: "this joint moves exactly this part".

 The user picks a part of the mesh for the selected joint — its own bone's
 vertices, its whole subtree's, the UV islands it holds, a separate piece, or a
 hand-grown patch — and
 Apply makes that part follow the joint and nothing outside it. The automatic
 binder stays the starting point; a part is written over it as absolute
 `VertexPin` shares, so undo, sessions and export already carry it.

 **The soft edge runs inward.** The band of the part nearest its boundary
 blend from the joint down toward the neighbours — the other joints share the
 rest as they hold it now, earlier Applies included — and nothing outside the part
 is given to the joint. The card's preview, which draws the rows Apply lays as
 the weights they become, is then a true picture of everything the joint will
 move, and a separate piece — a part with no boundary — stays rigid whatever the
 edge width. Outside the part the joint's automatic share is handed
 to the other joints on those rows, which is what "exactly" costs: without it a
 vertex just outside the edge could hold more of the joint than the edge itself.

 **Reset takes back one joint's work.** Every row an Apply writes is marked as
 that joint's (`VertexPin.by`), and Reset to automatic rebuilds exactly those
 rows and no others — a finger reset leaves the fingers corrected before it as
 they were. In a hand those rows go back to the knuckle bands at the blend asked
 for now (see `reset_area`).
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

	// A finger's part from the knuckle planes, over the bind with no paint or pins
	// on it. A piece riding one joint rigidly keeps its rider, as it does in the bind.
	rig::DigitBands bands = rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);
	bands.grow = view.grows;
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

 Inside the part the joint's pin is 1; within `soft` (model units, over the
 surface) of the edge it falls toward 0, and what is left goes to the other
 joints in the proportions they hold the vertex now — see `others_of`. That is
 what keeps a neighbour's work: a joint an earlier Apply took off these vertices
 stays off them, where handing the rest to the automatic weights brought it back
 (a finger corrected, the next finger applied, and the first one reaching across
 again). Each part row is stated whole, so every other pin on it goes. Outside, a row
 where the joint (or the twin) still holds at least `AREA_LEAK_FLOOR` is
 restated without it — from the row as shown, or where the two held all of it
 but a sliver, from the surface around it: a mirrored Apply that took a thigh
 off the tail root once handed it to the hundredth of a knee left there.

 Every row it states is the joint's work (`VertexPin.by`), the twin's part the
 twin's, which is what `reset_area` takes back.

 A part reaching off the joint's limb gives it nothing there (`limb_family`):
 those vertices are left as they are, as if the part stopped short. Not a
 vertex the joint already holds — a rim an earlier Apply gave it stays its own
 on the next — and not a part of whole `pieces`, Whole piece or UV islands, which the menu
 named rather than a hand pressed out.

 @param twin_mask : `The twin's part, or empty for none.`
 @param pieces : `The parts are whole pieces of the mesh, applied whole off the limb too — see area_names_pieces.`
 @param refused : `Filled with how many vertices of the parts were off their joint's limb. Null to not ask.`
 @return `How many vertices the joint and its twin now hold; 0 when nothing changed.`
*>
fn usz AppState.apply_area(&self, uint dot_id, bool[] mask, float soft, uint twin = 0, bool[] twin_mask = {},
	bool pieces = false, usz* refused = null)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);

	PinDraft draft;
	defer draft.free();
	usz held = self.area_rows(&draft, &view, painted, dot_id, mask, soft, twin, twin_mask, pieces, refused);
	if (held == 0 || self.lay_draft(&draft) == 0) return 0;
	if (self.skinned()) self.refresh_pose_display();
	return held;
}

<*
 The rows an Apply states, drafted and not laid: what `apply_area` writes, and
 what the Weights card draws while a part waits for it — one computation, so
 the picture is the weights Apply leaves.

 @param draft : `Filled; the caller frees it, whatever this returns.`
 @param painted : `The bind as shown — AppState.weights of the same view.`
 @param pieces : `The parts are whole pieces, not limited to the limb — see apply_area.`
 @param refused : `Filled with how many part vertices were off their joint's limb and left out. Null to not ask.`
 @return `How many vertices the joint and its twin would hold; 0 when there is nothing to state.`
*>
fn usz AppState.area_rows(&self, PinDraft* draft, RigView* view, float[] painted, uint dot_id, bool[] mask, float soft,
	uint twin = 0, bool[] twin_mask = {}, bool pieces = false, usz* refused = null)
{
	if (refused) *refused = 0;
	usz count = self.geometry.positions.len;
	if (count == 0 || mask.len != count || !self.doc.find(dot_id)) return 0;

	rig::MeshAdjacency* around = self.adjacency_for();
	if (around.vertices() != count) return 0;

	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || bones == 0) return 0;

	bool with_twin = twin != 0 && twin != dot_id && twin_mask.len == count && view.joint_of(twin) >= 0;
	sz twin_joint = with_twin ? view.joint_of(twin) : -1;

	if (painted.len < count * bones) return 0;

	float[] automatic = self.weights(mem, view, AUTOMATIC);
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	if (automatic.len < count * bones) return 0;
	Handoff handoff = self.handoff_for(view);
	defer handoff.free();

	draft.init(count);

	float limit = math::max(soft, 0.0f);
	usz held = 0;
	Vec3[] points = class_points(around, self.geometry.positions);
	defer alloc::free(mem, points);

	float[] row = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, row);
	uint[SKIN_INFLUENCES] keep_dots;
	float[SKIN_INFLUENCES] keep_shares;

	// The pins already on each vertex, so a soft edge stated again lands on the
	// shares it already has rather than on their rounding.
	PinIndex stated = pin_index(mem, &self.doc.pins, math::max(pin_span(&self.doc.pins, {}), count), 0);
	defer stated.free(mem);

	uint[2] owners = { dot_id, twin };
	bool[][2] parts = { mask, twin_mask };
	usz sides = with_twin ? 2 : 1;
	for (usz p = 0; p < sides; p++)
	{
		// The part as far as its joint's limb goes — the twin's against the twin,
		// and with whatever the joint already holds — and its soft edge measured
		// from there, so a part reaching off the limb fades out where it stops
		// rather than ending in a step.
		usz side = (usz)(p == 0 ? joint : twin_joint);
		bool[] family = limb_family(mem, &view.skeleton, side);
		defer alloc::free(mem, family);
		bool[] part = alloc::new_array(mem, bool, (sz)count);
		defer alloc::free(mem, part);
		foreach (v, on : parts[p])
		{
			if (!on) continue;
			usz at = (usz)v * bones;
			part[v] = pieces || on_limb(automatic[at:bones], family) || joint_share(painted[at:bones], side) >= AREA_LEAK_FLOOR;
			if (!part[v] && refused) (*refused)++;
		}
		bool[] cls = classes_of(around, part);
		defer alloc::free(mem, cls);
		float[] depth = edge_depths(around, points, cls, limit);
		defer alloc::free(mem, depth);

		uint[1] dots = { owners[p] };
		foreach (v, on : part)
		{
			if (!on || draft.claimed((uint)v)) continue;
			held++;
			float share = area_share(depth[(usz)around.class_of[v]], limit);
			if (share >= 1.0f)
			{
				float[1] whole = { 1.0f };
				draft.state((uint)v, dots[..], whole[..], owners[p]);
				continue;
			}
			// The soft edge: the rest of the vertex goes to the other joints as they
			// hold it now, so a joint an earlier Apply took off it stays off.
			self.others_of(painted, view, &handoff, (uint)v, joint, twin_joint, row);
			usz kept = band_row(row, view.dot_ids, owners[p], share, keep_dots[..], keep_shares[..]);
			self.keep_stated(&stated, (uint)v, keep_dots[:kept], keep_shares[:kept]);
			draft.state((uint)v, keep_dots[:kept], keep_shares[:kept], owners[p]);
		}
	}

	// Outside every part: take the joints off the rows they still reach.
	for (usz v = 0; v < count; v++)
	{
		if (draft.claimed((uint)v)) continue;
		usz at = v * bones;
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[at + b];
		if (sum <= 0.0f) continue;

		bool leaks = painted[at + (usz)joint] / sum >= AREA_LEAK_FLOOR;
		if (twin_joint >= 0 && painted[at + (usz)twin_joint] / sum >= AREA_LEAK_FLOOR) leaks = true;
		if (!leaks) continue;

		float left = self.others_of(painted, view, &handoff, (uint)v, joint, twin_joint, row);
		usz kept = left > 0.0f ? top_row(row, view.dot_ids, -1, keep_dots[..], keep_shares[..]) : 0;
		// The row is the work of whichever of the two it was taken off more of.
		uint by = twin_joint >= 0 && painted[at + (usz)twin_joint] > painted[at + (usz)joint] ? twin : dot_id;
		draft.state((uint)v, keep_dots[:kept], keep_shares[:kept], by);
	}
	return held;
}

<*
 What the field needs to re-derive a row: the bands the automatic weights end
 at, and the bind's softness. Built once per operation — see
 `AppState.handoff_for` — because both cost a pass over the rig or the mesh and
 a stroke asks for a row per vertex under the circle.
*>
struct Handoff
{
	float[] bands;
	float eps;
}

fn Handoff AppState.handoff_for(&self, RigView* view)
{
	return { .bands = self.bind_bands(mem, view), .eps = self.bind_eps() };
}

fn void Handoff.free(&self)
{
	if (self.bands.len > 0) alloc::free(mem, self.bands);
	*self = {};
}

<*
 Where a vertex goes when a joint (and its twin) are taken off it: the
 automatic row the distance field gives it with those joints left out.

 The binder's own rules re-run over the one row — the falloff from each joint's
 distance, the chain isolation, the model's sharpness and the window — so the
 joints that come back are the ones that would own the vertex had the removed
 joint never been placed: the next joint down a leg, never a hip that held two
 percent of a boot. That is the answer the user means by "take this joint off",
 and the same one whichever tool asked.

 A rig wearing its file's weights has no field of crig's; there the automatic
 row without the two is the answer.

 @param row : `Filled, one weight per joint, unnormalised.`
 @return `What the row adds up to; 0 when the field gives the vertex to nobody else.`
*>
fn float AppState.field_row(&self, RigView* view, Handoff* handoff, uint vertex, sz joint, sz twin_joint, float[] row)
{
	usz bones = view.len();
	usz count = self.geometry.positions.len;
	usz at = (usz)vertex * bones;
	row[:bones] = 0.0f;
	if ((usz)vertex >= count) return 0.0f;

	if (self.field_distances.len != count * bones)
	{
		float[] base = self.base_bind_for(view);
		if (base.len < count * bones) return 0.0f;
		float left = 0.0f;
		for (usz b = 0; b < bones; b++)
		{
			if ((sz)b == joint || (sz)b == twin_joint) continue;
			row[b] = base[at + b];
			left += row[b];
		}
		return left;
	}

	float[] near = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, near);
	near[..] = self.field_distances[at:bones];
	if (joint >= 0) near[(usz)joint] = rig::NO_DISTANCE;
	if (twin_joint >= 0) near[(usz)twin_joint] = rig::NO_DISTANCE;
	for (usz b = 0; b < bones; b++)
	{
		if (near[b] >= rig::NO_DISTANCE) continue;
		float reach = b < view.reaches.len ? view.reaches[b] : 0.0f;
		row[b] = rig::field_score(near[b], reach, handoff.eps);
	}
	rig::isolate_chains(mem, row[:bones], view.skeleton.parents);
	sharpen_weights(row[:bones], self.doc.sharpness);
	rig::window_bind(row[:bones], near, bones, handoff.bands);

	float left = 0.0f;
	foreach (weight : row[:bones]) left += weight;
	return left;
}

<*
 The rest of a row once a joint (and its twin) are taken off it: who the freed
 share goes to.

 The other joints as shown — earlier Applies and brush strokes included, so a
 joint an earlier edit took off stays off — when together they hold a real
 share of the vertex (`SHOWN_FLOOR`). **Below that they say nothing** about
 where the vertex belongs: a few percent is the falloff's tail, and scaled up it
 would hand the vertex to it — a knee taken off a shin went wholly to the two
 percent of hip on it. Then the field decides (`field_row`).

 @param row : `Filled, one weight per joint.`
 @return `What the rest adds up to; 0 when nothing else can hold the vertex.`
*>
fn float AppState.others_of(&self, float[] painted, RigView* view, Handoff* handoff, uint vertex, sz joint,
	sz twin_joint, float[] row)
{
	usz bones = view.len();
	float shown = shown_others(painted, (usz)vertex * bones, bones, joint, twin_joint, row);
	if (shown >= SHOWN_FLOOR) return shown;
	return self.field_row(view, handoff, vertex, joint, twin_joint, row);
}

// A row as shown without the joint and its twin, as shares of the vertex.
fn float shown_others(float[] painted, usz at, usz bones, sz joint, sz twin_joint, float[] row) @private
{
	float sum = 0.0f;
	for (usz b = 0; b < bones; b++) sum += painted[at + b];
	float left = 0.0f;
	for (usz b = 0; b < bones; b++)
	{
		row[b] = ((sz)b == joint || (sz)b == twin_joint || sum <= 0.0f) ? 0.0f : painted[at + b] / sum;
		left += row[b];
	}
	return left;
}

<*
 A soft-edge row: the joint at `share`, and the strongest others of `row`
 sharing the rest in their proportions. The joint's own share stays exactly
 `share`, whatever the cut to `SKIN_INFLUENCES` leaves of the others.

 @param out_dots : `SKIN_INFLUENCES long.`
 @return `How many were written; 1 when nothing else holds the vertex.`
*>
fn usz band_row(float[] row, uint[] dot_ids, uint dot_id, float share, uint[] out_dots, float[] out_shares) @private
{
	out_dots[0] = dot_id;
	out_shares[0] = share;
	usz others = top_row(row, dot_ids, -1, out_dots[1..], out_shares[1..]);
	for (usz i = 1; i <= others; i++) out_shares[i] *= 1.0f - share;
	return others + 1;
}

<*
 Where the pins on a vertex already state this row, give or take a rounding,
 take their shares over. Stating the row again then changes nothing, so applying
 the same part twice records nothing and the card can say so.
*>
fn void AppState.keep_stated(&self, PinIndex* index, uint v, uint[] dots, float[] shares)
{
	if ((usz)v >= index.head.len) return;
	usz held = 0;
	for (int walk = index.head[v]; walk >= 0; walk = index.next[walk])
	{
		VertexPin pin = self.doc.pins[(sz)walk];
		usz i = 0;
		while (i < dots.len && dots[i] != pin.dot_id) i++;
		if (i == dots.len || math::abs(shares[i] - pin.share) > 1.0e-3f) return;
		held++;
	}
	if (held != dots.len) return;
	for (int walk = index.head[v]; walk >= 0; walk = index.next[walk])
	{
		VertexPin pin = self.doc.pins[(sz)walk];
		foreach (i, dot : dots) if (dot == pin.dot_id) shares[i] = pin.share;
	}
}

<*
 Take back a joint's own work, as one undo step: every row its Apply or its
 brush wrote (`VertexPin.by`, and the twin's), and no other.

 On those rows the joint goes back to its automatic share, and the others keep
 what they hold:

 - A row that states other joints — its soft edge, the rows its Apply took it
   off, a partial stroke — keeps them as stated, and the joint comes back
   beside them at its automatic share scaled the way the row holds them against
   theirs (`held_against_automatic`), which is the row as it was before the
   joint's Apply. A joint the row leaves out stays out: an earlier Apply took it
   off, and resetting this joint is not resetting that one. Not where the joint
   held all of the automatic row but a sliver: those others came from the
   surface around (`others_of`), and the row goes back as a whole one does.
 - A row it holds whole — its part's interior, a full stroke — says nothing
   about the others, so they are read off the rows around it: a joint the
   joint's own rows bordering it leave out, though the automatic weights would
   have kept it, was taken off before this joint's Apply, and stays off.

 With nothing taken off that is exactly the automatic row, and a row that comes
 out as the automatic row is cleared rather than stated — so a fresh Apply and a
 Reset leave no pin behind. A row that cannot be cleared names the strongest
 joint it leaves out as its author: those rows are that joint's leak, as they
 were before this joint's Apply wrote over them, and resetting that joint later
 finds them.

 **In a hand the row goes back whole.** Resetting the wrist or a finger joint —
 any joint the knuckle bands shape (`rig::DigitBands.shapes`) — clears each row
 of its work that a finger joint holds a share of (`fingers_hold`) to the
 automatic row, others and all. There the automatic weights are the bands at
 the knuckle blend the model asks for now, while the others the row states are
 the bind as it stood when the joint wrote it: a blend since changed, or weights
 from before the bands, which kept the hand broken through any number of resets.
 A finger applied before this one can come back across their shared knuckle, by
 as much as the knuckle blend gives it — the blend, which the Knuckle blend
 setting narrows to a hard switch. On a file's own weights (`skin_from_file`)
 nothing is banded, and the rows are taken back as below.

 Rows another joint wrote are never touched, which is the whole promise:
 resetting a finger leaves the finger beside it and the one before it exactly as
 they were painted. A row from before authors were kept (version 26) is read as
 the work of its strongest joint — see `row_author`.

 @return `How many pin entries changed.`
*>
fn usz AppState.reset_area(&self, uint dot_id, uint twin = 0)
{
	usz count = self.geometry.positions.len;
	if (count == 0 || !self.doc.find(dot_id) || self.doc.pins.len() == 0) return 0;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || bones == 0) return 0;
	sz twin_joint = twin != 0 && twin != dot_id ? view.joint_of(twin) : -1;
	if (twin_joint < 0) twin = 0;

	float[] automatic = self.weights(mem, &view, AUTOMATIC);
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	if (automatic.len < count * bones) return 0;

	// Each vertex's row, gathered.
	int[] start = alloc::new_array(mem, int, (sz)count + 1);
	defer alloc::free(mem, start);
	foreach (pin : self.doc.pins.array_view()) if ((usz)pin.vertex < count) start[pin.vertex + 1]++;
	for (usz v = 0; v < count; v++) start[v + 1] += start[v];
	if (start[count] == 0) return 0;
	VertexPin[] rows = alloc::new_array(mem, VertexPin, (sz)start[count]);
	defer alloc::free(mem, rows);
	int[] fill = alloc::new_array(mem, int, (sz)count);
	defer alloc::free(mem, fill);
	fill[..] = start[:count];
	foreach (pin : self.doc.pins.array_view()) if ((usz)pin.vertex < count) rows[fill[pin.vertex]++] = pin;

	// Which rows are the joint's work, and which of those it holds whole.
	bool[] ours = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, ours);
	bool[] whole = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, whole);
	for (usz v = 0; v < count; v++)
	{
		VertexPin[] row = rows[start[v]:start[v + 1] - start[v]];
		if (row.len == 0) continue;
		uint author = row_author(row);
		if (author != dot_id && (twin == 0 || author != twin)) continue;
		ours[v] = true;
		whole[v] = true;
		foreach (pin : row) if (pin.dot_id != dot_id && (twin == 0 || pin.dot_id != twin)) whole[v] = false;
	}

	// A hand joint's rows a finger holds go back to the automatic row whole, and
	// are no evidence of what was taken off the others. Only on the binder's own
	// weights: a file's fingers are not banded, and the guarantee stays there.
	bool[] outright = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, outright);
	rig::DigitBands bands = self.doc.skin_from_file ? (rig::DigitBands){} : rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);
	if (bands.shapes((usz)joint) || (twin_joint >= 0 && bands.shapes((usz)twin_joint)))
	{
		for (usz v = 0; v < count; v++)
		{
			if (!ours[v]) continue;
			if (!fingers_hold(&bands, &view, automatic[v * bones:bones], rows[start[v]:start[v + 1] - start[v]])) continue;
			outright[v] = true;
			ours[v] = false;
			whole[v] = false;
		}
	}

	bool[] taken = alloc::new_array(mem, bool, (sz)bones);
	defer alloc::free(mem, taken);
	self.taken_off_around(&view, automatic, rows, start, ours, whole, joint, twin_joint, taken);

	float[] row_w = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, row_w);
	uint[SKIN_INFLUENCES] new_dots;
	float[SKIN_INFLUENCES] new_shares;
	uint[SKIN_INFLUENCES] auto_dots;
	float[SKIN_INFLUENCES] auto_shares;

	PinIndex stated = pin_index(mem, &self.doc.pins, math::max(pin_span(&self.doc.pins, {}), count), 0);
	defer stated.free(mem);

	PinDraft draft;
	draft.init(count);
	defer draft.free();
	for (usz v = 0; v < count; v++)
	{
		VertexPin[] row = rows[start[v]:start[v + 1] - start[v]];
		if (row.len == 0) continue;
		if (outright[v])
		{
			draft.state((uint)v, {}, {});
			continue;
		}
		usz at = v * bones;
		float total = 0.0f;
		for (usz b = 0; b < bones; b++) total += automatic[at + b];
		if (total <= 0.0f) continue;

		if (!ours[v])
		{
			// A row from before authors were kept that is exactly the automatic
			// row without the joint: its own Apply took it off over automatic
			// weights, and the row goes, which puts it back.
			if (row_by(row) != 0) continue;
			bool held = false;
			foreach (pin : row) if (pin.dot_id == dot_id || (twin != 0 && pin.dot_id == twin)) held = true;
			if (held) continue;
			bool reaches = automatic[at + (usz)joint] / total >= AREA_LEAK_FLOOR
				|| (twin_joint >= 0 && automatic[at + (usz)twin_joint] / total >= AREA_LEAK_FLOOR);
			if (!reaches) continue;
			for (usz b = 0; b < bones; b++)
			{
				row_w[b] = ((sz)b == joint || (sz)b == twin_joint) ? 0.0f : automatic[at + b];
			}
			usz wanted = top_row(row_w, view.dot_ids, -1, new_dots[..], new_shares[..]);
			if (wanted == row.len && row_matches(row, new_dots[:wanted], new_shares[:wanted])) draft.state((uint)v, {}, {});
			continue;
		}

		// Where the two held all of the automatic row but a sliver, the others the
		// row states came from the surface around it (`others_of`) and say nothing
		// of what it was: it goes back like a whole one.
		float rest = 0.0f;
		for (usz b = 0; b < bones; b++) if ((sz)b != joint && (sz)b != twin_joint) rest += automatic[at + b];

		row_w[..] = 0.0f;
		if (whole[v] || rest < AREA_LEAK_FLOOR * total)
		{
			// The automatic row, less the joints taken off around it.
			float kept_weight = 0.0f;
			for (usz b = 0; b < bones; b++)
			{
				bool own = (sz)b == joint || (sz)b == twin_joint;
				row_w[b] = taken[b] && !own ? 0.0f : automatic[at + b];
				kept_weight += row_w[b];
			}
			if (kept_weight <= 0.0f) row_w[..] = automatic[at:bones];
		}
		else
		{
			// The stated others as they are, and the joint beside them at its
			// automatic weight, scaled the way the row holds the others against
			// theirs; `top_row` normalises.
			float scale = held_against_automatic(row, automatic[at:bones], total, &view, dot_id, twin);
			row_w[(usz)joint] = automatic[at + (usz)joint] / total * scale;
			if (twin_joint >= 0) row_w[(usz)twin_joint] = automatic[at + (usz)twin_joint] / total * scale;
			foreach (pin : row)
			{
				if (pin.dot_id == dot_id || (twin != 0 && pin.dot_id == twin)) continue;
				sz b = view.joint_of(pin.dot_id);
				if (b >= 0) row_w[(usz)b] += pin.share;
			}
		}

		sz keep = twin_joint >= 0 && row_w[(usz)twin_joint] > row_w[(usz)joint] ? twin_joint : joint;
		usz kept = top_row(row_w, view.dot_ids, keep, new_dots[..], new_shares[..]);
		usz auto_kept = top_row(automatic[at:bones], view.dot_ids, keep, auto_dots[..], auto_shares[..]);
		if (same_row(new_dots[:kept], new_shares[:kept], auto_dots[:auto_kept], auto_shares[:auto_kept]))
		{
			draft.state((uint)v, {}, {});
			continue;
		}
		uint by = strongest_left_out(new_dots[:kept], auto_dots[:auto_kept], auto_shares[:auto_kept], dot_id, twin);
		self.keep_stated(&stated, (uint)v, new_dots[:kept], new_shares[:kept]);
		draft.state((uint)v, new_dots[:kept], new_shares[:kept], by);
	}
	usz changed = self.lay_draft(&draft);
	if (changed > 0 && self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 The joints taken off the vertices around a joint's whole rows, before its
 Apply wrote over them: the evidence `reset_area` reads for what a whole row
 held, since the row itself no longer says.

 Read off the joint's own rows that border one of its whole rows — its soft
 edge, the rows it took itself off — whose others are the row as it stood when
 the joint wrote it. A joint is taken off there if it has no pin on the row,
 holds at least `AREA_LEAK_FLOOR` of the automatic row, and is strong enough
 that the cut to `SKIN_INFLUENCES` would have kept it: absent for that reason,
 it was left out by somebody's edit rather than by the cut. Rows other joints
 wrote are not evidence; with none, nothing is taken off and the whole rows go
 back to automatic.

 @param taken : `Set per joint.`
*>
fn void AppState.taken_off_around(&self, RigView* view, float[] automatic, VertexPin[] rows, int[] start,
	bool[] ours, bool[] whole, sz joint, sz twin_joint, bool[] taken)
{
	usz count = ours.len;
	usz bones = view.len();
	rig::MeshAdjacency* around = self.adjacency_for();
	if (around.vertices() != count || !around.usable()) return;

	// One vertex per weld class, to read a neighbouring class's row from.
	int[] first = alloc::new_array(mem, int, (sz)around.classes());
	defer alloc::free(mem, first);
	first[..] = -1;
	for (usz v = 0; v < count; v++) if (first[around.class_of[v]] < 0) first[around.class_of[v]] = (int)v;

	bool[] judged = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, judged);
	bool[] chosen = alloc::new_array(mem, bool, (sz)bones);
	defer alloc::free(mem, chosen);
	for (usz v = 0; v < count; v++)
	{
		if (!whole[v]) continue;
		foreach (cls : around.around(around.class_of[v]))
		{
			int u = first[cls];
			if (u < 0 || judged[u] || !ours[u] || whole[u]) continue;
			judged[u] = true;

			VertexPin[] row = rows[start[u]:start[u + 1] - start[u]];
			usz at = (usz)u * bones;
			float total = 0.0f;
			for (usz b = 0; b < bones; b++) total += automatic[at + b];
			if (total <= 0.0f) continue;

			// The room the row had for others once the joint took its place.
			usz mine = 0;
			foreach (pin : row)
			{
				sz b = view.joint_of(pin.dot_id);
				if (b >= 0 && (b == joint || b == twin_joint)) mine++;
			}
			usz room = SKIN_INFLUENCES - math::min(mine, (usz)SKIN_INFLUENCES);
			chosen[..] = false;
			for (usz k = 0; k < room; k++)
			{
				sz best = -1;
				for (usz b = 0; b < bones; b++)
				{
					if ((sz)b == joint || (sz)b == twin_joint || chosen[b] || automatic[at + b] <= 0.0f) continue;
					if (best < 0 || automatic[at + b] > automatic[at + (usz)best]) best = (sz)b;
				}
				if (best < 0) break;
				chosen[(usz)best] = true;
				if (automatic[at + (usz)best] / total < AREA_LEAK_FLOOR) continue;
				bool stated = false;
				foreach (pin : row) if (pin.dot_id == view.dot_ids[(usz)best]) stated = true;
				if (!stated) taken[(usz)best] = true;
			}
		}
	}
}

<*
 Whether the finger joints together hold at least `rig::DIGIT_GATE_LOW` of a
 vertex, in its automatic row or as stated on its pins: a row of the hand, as
 much as the knuckle bands reach it — see `reset_area`.
*>
fn bool fingers_hold(rig::DigitBands* bands, RigView* view, float[] automatic, VertexPin[] row) @private
{
	float total = 0.0f;
	float held = 0.0f;
	foreach (usz b, weight : automatic)
	{
		total += weight;
		if (b < bands.digit.len && bands.digit[b]) held += weight;
	}
	if (total > 0.0f && held / total >= rig::DIGIT_GATE_LOW) return true;
	float stated = 0.0f;
	foreach (pin : row)
	{
		sz b = view.joint_of(pin.dot_id);
		if (b >= 0 && (usz)b < bands.digit.len && bands.digit[(usz)b]) stated += pin.share;
	}
	return stated >= rig::DIGIT_GATE_LOW;
}

<*
 How a row holds the joints stated on it against their automatic shares, as the
 one ratio most of them agree on: what `reset_area` scales a joint's automatic
 share by to put it back beside them.

 A row the joint took itself off was some other row first — automatic, or a
 neighbour's soft edge — minus the joint and renormalised. In either, the others
 hold the automatic proportions among themselves, all but the part's owner, whose
 share its Apply stated. So the ratio the others share is the one the joint had
 too, and putting it back at that ratio gives the row back as it was:

 - Three or more others: the median, which the owner cannot move.
 - Two: the lower, since which is the owner cannot be told — at worst the joint
   comes back short, and never takes more from a neighbour than it held.
 - One: its own.

 Only joints holding at least `AREA_LEAK_FLOOR` of the automatic row are read;
 the ratio of a share of a millionth is rounding. With none, 1: the joint at its
 automatic share beside the row as it is.
*>
fn float held_against_automatic(VertexPin[] row, float[] automatic, float total, RigView* view, uint dot_id, uint twin) @private
{
	float[16] ratios;
	usz n = 0;
	foreach (pin : row)
	{
		if (n == ratios.len || pin.dot_id == dot_id || (twin != 0 && pin.dot_id == twin)) continue;
		sz b = view.joint_of(pin.dot_id);
		if (b < 0) continue;
		float share = automatic[(usz)b] / total;
		if (share < AREA_LEAK_FLOOR) continue;
		ratios[n++] = pin.share / share;
	}
	if (n == 0) return 1.0f;
	for (usz i = 1; i < n; i++)
	{
		for (usz j = i; j > 0 && ratios[j] < ratios[j - 1]; j--)
		{
			float swap = ratios[j];
			ratios[j] = ratios[j - 1];
			ratios[j - 1] = swap;
		}
	}
	if (n <= 2) return ratios[0];
	return n % 2 == 1 ? ratios[n / 2] : 0.5f * (ratios[n / 2 - 1] + ratios[n / 2]);
}

<*
 The author for a row Reset has to state rather than clear: the strongest joint
 the automatic row would have kept that the row leaves out — the joint whose
 leak it is — or 0 when it leaves none out.
*>
fn uint strongest_left_out(uint[] dots, uint[] auto_dots, float[] auto_shares, uint dot_id, uint twin) @private
{
	uint by = 0;
	float strongest = 0.0f;
	foreach (i, dot : auto_dots)
	{
		if (dot == dot_id || (twin != 0 && dot == twin) || auto_shares[i] < AREA_LEAK_FLOOR) continue;
		bool kept = false;
		foreach (other : dots) if (other == dot) kept = true;
		if (kept || auto_shares[i] <= strongest) continue;
		strongest = auto_shares[i];
		by = dot;
	}
	return by;
}

// Whether two cut rows name the same dots at the same shares, give or take a rounding.
fn bool same_row(uint[] dots, float[] shares, uint[] other_dots, float[] other_shares) @private
{
	if (dots.len != other_dots.len) return false;
	foreach (i, dot : dots)
	{
		bool found = false;
		foreach (j, other : other_dots)
		{
			if (other != dot) continue;
			found = math::abs(shares[i] - other_shares[j]) <= 1.0e-3f;
			break;
		}
		if (!found) return false;
	}
	return true;
}

// Whether a vertex's pins state exactly this row, give or take a rounding.
fn bool row_matches(VertexPin[] pins, uint[] dots, float[] shares) @private
{
	foreach (pin : pins)
	{
		bool found = false;
		foreach (i, dot : dots)
		{
			if (dot != pin.dot_id) continue;
			found = math::abs(shares[i] - pin.share) <= 1.0e-3f;
			break;
		}
		if (!found) return false;
	}
	return true;
}

// ---------------------------------------------------------------------------
// The Area tool (W)

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
	if (self.tint_mode == OFF) return;
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

<*
 Whether the joint's edge cannot be moved, said out loud when so: a rig wearing
 its file's own weights has no automatic edge of crig's for a grow or a soft
 edge to move, and a button that did nothing would be the one thing worse than
 a refusal.
*>
fn bool AppState.refuses_edge(&self)
{
	if (!self.doc.skin_from_file) return false;
	self.@notice("this rig wears the model's own weights · Grow, Shrink and Soft edge shape crig's automatic ones — untick Rig › Use the model's own weights first");
	return true;
}

// One Grow or Shrink step for a joint, in model units: a tenth of its bone.
fn float AppState.grow_step(&self, uint dot_id) => self.area_scale(dot_id) * AREA_STEP;

<*
 Push the selected joint's region out by whole steps, or pull it in — the card's
 Grow and Shrink, and the twin with it while Mirror is on.

 **Live, not a part.** The joint's edge moves through the same distances the
 automatic weights are made from (`Dot.grow`), so the mesh shows the result as
 the button is pressed, there is nothing to Apply, a dot moved afterwards
 carries the grown edge with it, and Reset is the same edge put back. One undo
 step per press.

 @return `Whether anything changed.`
*>
fn bool AppState.grow_joint(&self, int steps)
{
	Dot* dot = self.doc.find(self.selected);
	if (!dot || steps == 0 || self.refuses_edge()) return false;
	bool wrote = self.set_grow_recorded(dot.id, dot.grow + (float)steps * self.grow_step(dot.id));
	uint twin = self.area_mirrors() ? self.mirror_twin(dot.id) : 0;
	Dot* other = twin != 0 ? self.doc.find(twin) : null;
	if (other && self.set_grow_recorded(twin, other.grow + (float)steps * self.grow_step(twin))) wrote = true;
	if (!wrote) return false;
	self.undo_stack.commit();
	self.mark_rig_stale();
	return true;
}

<*
 Start a grow or shrink drag on the mesh (shift-drag grows, ctrl-drag shrinks):
 the same live edge as the card's buttons, a step per stretch of the drag, and
 one undo step for the whole drag. Remembers where the joint and its twin
 started so dragging back takes steps off again.
*>
fn bool AppState.begin_grow_drag(&self)
{
	if (!self.areaing || self.area_shaping()) return false;
	self.area_follow_selection();
	Dot* dot = self.doc.find(self.area_dot);
	if (!dot || self.refuses_edge()) return false;
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
	if (wrote) self.mark_rig_stale();
	return wrote;
}

// The button came up: the drag is one undo step. Safe with no drag open.
fn void AppState.end_grow_drag(&self)
{
	if (!self.grow_drag) return;
	self.grow_drag = false;
	self.undo_stack.commit();
}

<*
 Set how far the selected joint blends with its neighbours — the card's Soft
 edge — and the twin's with it while Mirror is on. Leaves the group open so a
 slider drag is one undo step; the slider's release commits.

 @param share : `A share of the joint's bone.`
*>
fn bool AppState.soften_joint(&self, float share)
{
	Dot* dot = self.doc.find(self.selected);
	if (!dot || self.refuses_edge()) return false;
	bool wrote = self.set_band_recorded(dot.id, share);
	uint twin = self.area_mirrors() ? self.mirror_twin(dot.id) : 0;
	if (twin != 0 && self.doc.find(twin) && self.set_band_recorded(twin, share)) wrote = true;
	if (wrote) self.mark_rig_stale();
	return wrote;
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
 edge goes back where the automatic weights put it — no grow, the model's soft
 edge — and its own Applies and strokes are taken back, while nothing a
 neighbour wrote is touched (`reset_area`). One undo step.
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

	// The edge first, inside the same group the pins close.
	bool edged = false;
	if (self.set_grow_recorded(id, 0.0f)) edged = true;
	if (self.set_band_recorded(id, 0.0f)) edged = true;
	if (twin != 0 && self.doc.find(twin))
	{
		if (self.set_grow_recorded(twin, 0.0f)) edged = true;
		if (self.set_band_recorded(twin, 0.0f)) edged = true;
	}
	if (edged) self.mark_rig_stale();
	usz cleared = self.reset_area(id, twin);
	self.undo_stack.commit();

	Dot* dot = self.doc.find(id);
	String name = dot.name.len > 0 ? dot.name : "this joint";
	if (cleared == 0 && !edged)
	{
		self.@notice("%s already uses automatic weights", name);
	}
	else
	{
		self.@notice("%s back to automatic weights", name);
	}
	return cleared + (edged ? (usz)1 : (usz)0);
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

 The rows are `area_rows`, the ones Apply lays, each put through `pin_over` from
 the automatic row with its own pins and no others, which is what `lay_draft`
 leaves on a vertex. So pressing Apply changes nothing on screen, and the brush
 then shows what the card showed.

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

	PinDraft draft;
	defer draft.free();
	usz held = self.area_rows(&draft, view, painted, self.area_dot, self.area_mask, self.area_soft_distance(),
		self.area_twin, self.area_twin_mask, self.area_names_pieces());
	if (held == 0) return;

	float[] automatic = self.weights(mem, view, AUTOMATIC);
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	if (automatic.len < count * bones) return;

	bool falloff = self.tint_mode == FALLOFF;
	PinColumn[SKIN_INFLUENCES] stated;
	for (usz v = 0; v < count; v++)
	{
		if (!draft.claimed((uint)v)) continue;
		float[] row = automatic[v * bones:bones];
		usz from = (usz)draft.first[v];
		usz kept = 0;
		for (usz i = from; i < from + (usz)draft.held[v] && kept < stated.len; i++)
		{
			VertexPin pin = draft.pins[(sz)i];
			sz column = view.joint_of(pin.dot_id);
			if (column >= 0) stated[kept++] = { .vertex = 0, .joint = (usz)column, .share = pin.share };
		}
		pin_over(row, bones, stated[:kept]);
		uint tint = falloff ? share_tint(joint_share(row, (usz)joint)) : joint_tint(strongest_joint(row));
		// A row Apply will state takes the hand-edit cast it will have once written.
		self.tints[v] = draft.held[v] > 0 ? edited_cast(tint) : tint;
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

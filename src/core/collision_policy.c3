<*
 Which broad-phase pairs a self-collision check is allowed to take seriously
 (C2).

 `DeformedCollisionSurface.broad_phase_pairs_for_joints` answers every pair of
 triangles a joint edit can bring within bounds of each other, and it answers
 honestly: the two halves of one quad, the inside of a bending elbow, thighs
 that were modelled touching. A check that stopped a pose on any of those
 would stop every pose. So the raw pairs come through here first, and each is
 given one of six readings, in the order the questions are cheap to ask:

 - **shared topology** — the triangles share a vertex. Distance zero in every
   pose, by construction; never a contact. A vertex the exporter split along
   a UV or normal seam still counts as one: given the mesh's weld classes,
   the test is on positions rather than on the index buffer, so a seam does
   not read as a row of contacts.
 - **neighboring regions** — both lie in one skin region, in regions one
   bone apart, or in regions two bones apart along one line of descent. A
   region is what one joint moves nearly rigidly, so a fold inside it is a
   weighting artefact, and the crease where a child's region meets its
   parent's is exactly what bending is. A grandparent's is the same crease
   put one bone further out by a short bone between: the upper arm folding
   into the armpit under a clavicle, the chin onto the chest under a neck,
   the foot onto the thigh — read as contacts, the first of those stopped a
   hand a foot short of the belly, since the arm cannot come across the
   body without its inside meeting the chest. Joint limits own how far a
   crease may close; collision does not second-guess them. Siblings and
   cousins are not neighbors — two thighs under one hip, a hand and the
   other arm, are the case the check exists for.
 - **shared influence** — some joint weights a corner of each, by at least
   `FOLD_WEIGHT`. Regions say which joint moves a triangle most; the weights
   say which joints move it at all, and where two triangles answer with a
   joint in common they are one patch of skin deforming together: the crotch,
   where both thighs and the hips blend; the base of the neck, where the neck
   and the shoulders do; the web between two fingers. Whatever happens
   between them when that joint bends is what the weights were painted to
   do, and a real rig's short bones put such patches two and three regions
   apart, where the rule above cannot see them. The mid-thigh against the
   other thigh, the palm against the chest, share no joint and stay
   candidates.
 - **excluded regions** — the document names the pair of joints in
   `collision_exclusions`. The escape hatch for what no rule can know: a cape
   meant to hang through the arm it is skinned beside.
 - **rest contact** — the pair was already within clearance as the mesh was
   authored. Modelled contacts are intentional, and an intentional contact
   that stopped the first pose would make the check unusable on any model
   with its arms at its sides.
 - **candidate** — none of the above. The narrow phase decides.

 The accelerator stays free of all of this on purpose: it can be tested for
 finding every pair, and this file for keeping the right ones, without either
 check having to know the other's answer. `build_collision_policy` is the one
 pass that costs anything, since it measures every rest pair exactly; it
 belongs with the skin rebind, not with a frame.
*>
module crig;

import collision;
import gltf;
import std::collections::list;
import std::sort;
import std::math;

<*
 One broad-phase pair's reading. Ordered as the rules are asked, so a count
 per class says which rule did the work.
*>
enum CollisionPairClass : char
{
	CANDIDATE,
	SHARED_TOPOLOGY,
	NEIGHBORING_REGIONS,
	SHARED_INFLUENCE,
	EXCLUDED_REGIONS,
	REST_CONTACT,
}

<*
 The least weight that makes a joint one of a vertex's influences for the
 shared-influence reading. A binder's long tail — a few percent of some
 far joint left on a vertex — moves it too little to fold the skin, and
 counting it would tie patches together that never deform as one.
*>
const float FOLD_WEIGHT = 0.05f;

<*
 What one filter pass kept and why it dropped the rest — the numbers the
 status line and the Advanced section will show, and the ones a test can
 assert on without reading the pairs back.
*>
struct CollisionPairCounts
{
	usz candidates;
	usz shared_topology;
	usz neighboring_regions;
	usz shared_influence;
	usz excluded_regions;
	usz rest_contacts;
}

fn usz CollisionPairCounts.total(self) => self.candidates + self.shared_topology
	+ self.neighboring_regions + self.shared_influence + self.excluded_regions + self.rest_contacts;

<*
 The exclusion rules for one skin binding.

 `parents` and `dot_ids` are copied in the binding's joint order, because a
 `RigView` lives for one operation and this lives for as long as the surface
 does. `excluded` is a joints-by-joints table rather than the document's list
 so that a pair costs one load to classify, and `adopt_exclusions` rebuilds it
 whenever the document's list changes without touching the rest contacts,
 which do not depend on it.

 `rest_contacts` is sorted by `(a, b)` with `a < b`, the order the accelerator
 hands pairs out in, so membership is a binary search.

 `welds` is the mesh's weld class per vertex when the caller had one, and
 empty otherwise, in which case shared topology is read off the index buffer
 alone — right for a welded mesh and merely slower to build for a split one,
 since every seam pair then has to be measured and stored as a rest contact.

 `influences` is each triangle's joints — every joint weighting one of its
 corners by `FOLD_WEIGHT` or more, `influence_slots` entries per triangle
 padded with `uint::max` — read off the binding when the caller gave one, so
 that the shared-influence reading costs a few compares rather than a walk
 of the weights. Empty when it did not, and then no pair reads as one patch.
*>
struct CollisionPolicy
{
	uint joints;
	float clearance;
	int[] parents;
	uint[] dot_ids;
	uint[] welds;
	uint[] influences;
	usz influence_slots;
	bool[] excluded;
	DeformedTrianglePair[] rest_contacts;
	// The region pairs the broad phase is asked to keep: neither neighbors
	// nor excluded. The two static readings that are questions about regions
	// rather than triangles, answered once per pair of regions so the
	// accelerator can drop whole subtrees on them; see `may_meet`.
	bool[] meets;
	bool ready;
}

fn int by_pair(DeformedTrianglePair x, DeformedTrianglePair y) @local
{
	if (x.a != y.a) return x.a < y.a ? -1 : 1;
	if (x.b != y.b) return x.b < y.b ? -1 : 1;
	return 0;
}

<*
 Build the policy for `surface`, measuring every rest-pose pair once.

 @param surface : `The built accelerator for the binding; borrowed only while building.`
 @param parents : `The skeleton's parent per joint, in the binding's joint order.`
 @param dot_ids : `The dot each joint was built from, in the same order.`
 @param clearance : `Model units. What counts as touching, both here and at narrow phase.`
 @param doc : `Whose exclusions to adopt; null adopts none.`
 @param welds : `The mesh's weld class per vertex, as rig::build_adjacency computes it; empty reads topology off the indices.`
 @param skin : `The binding the surface was built over, for the shared-influence reading; an empty one reads no pair as one patch.`
*>
fn CollisionPolicy build_collision_policy(
	DeformedCollisionSurface* surface,
	int[] parents,
	uint[] dot_ids,
	float clearance,
	RigDocument* doc = null,
	uint[] welds = {},
	gltf::SkinBinding skin = {})
{
	if (!surface.root || surface.joints == 0 || parents.len < (usz)surface.joints
		|| dot_ids.len < (usz)surface.joints)
	{
		return {};
	}
	usz joints = (usz)surface.joints;
	CollisionPolicy out = {
		.joints = surface.joints,
		.clearance = math::max(clearance, 0.0f),
		.parents = alloc::new_array(mem, int, (sz)joints),
		.dot_ids = alloc::new_array(mem, uint, (sz)joints),
		.excluded = alloc::new_array(mem, bool, (sz)(joints * joints)),
		.meets = alloc::new_array(mem, bool, (sz)(joints * joints)),
		.ready = true,
	};
	for (usz joint = 0; joint < joints; joint++)
	{
		out.parents[joint] = parents[joint];
		out.dot_ids[joint] = dot_ids[joint];
	}
	out.tabulate_meets();
	// A weld table for some other mesh is worse than none: it would read two
	// unrelated triangles as one surface. Only one that covers every vertex here
	// is adopted.
	if (welds.len >= surface.vertices)
	{
		out.welds = alloc::new_array(mem, uint, (sz)surface.vertices);
		out.welds[:surface.vertices] = welds[:surface.vertices];
	}
	if (doc) out.adopt_exclusions(doc);
	if (skin.vertices >= surface.vertices && skin.slots > 0) out.read_influences(surface, skin);

	// The broad phase over the rest mesh, then the exact distance for what is
	// left after the static rules — a pair those already answer would never
	// be asked about the rest table, so storing it would only cost the
	// search.
	DeformedTrianglePair[] near = surface.rest_pairs(mem, out.clearance);
	defer if (near.len > 0) alloc::free(mem, near);
	List{DeformedTrianglePair} contacts;
	contacts.init(mem);
	defer contacts.free();
	foreach (pair : near)
	{
		if (out.regions_neighbor(surface.region_for_triangle(pair.a), surface.region_for_triangle(pair.b))) continue;
		if (out.shares_influence(pair)) continue;
		if (out.welds.len > 0 && out.shares_topology(surface, pair)) continue;
		float gap = triangle_distance(surface.rest_triangle(pair.a), surface.rest_triangle(pair.b));
		if (gap <= out.clearance) contacts.push(pair);
	}
	if (contacts.len() > 0)
	{
		out.rest_contacts = contacts.to_array(mem);
		sort::quicksort(out.rest_contacts, &by_pair);
	}
	return out;
}

fn void CollisionPolicy.free(&self)
{
	if (self.parents.len > 0) alloc::free(mem, self.parents);
	if (self.dot_ids.len > 0) alloc::free(mem, self.dot_ids);
	if (self.welds.len > 0) alloc::free(mem, self.welds);
	if (self.influences.len > 0) alloc::free(mem, self.influences);
	if (self.excluded.len > 0) alloc::free(mem, self.excluded);
	if (self.meets.len > 0) alloc::free(mem, self.meets);
	if (self.rest_contacts.len > 0) alloc::free(mem, self.rest_contacts);
	*self = {};
}

<*
 The table the broad phase prunes by: true where two regions are neither
 neighbors nor excluded, so a pair of their triangles is worth measuring.
 Rebuilt with the exclusions, which are the only part of it that changes.
*>
fn void CollisionPolicy.tabulate_meets(&self)
{
	usz joints = (usz)self.joints;
	for (usz a = 0; a < joints; a++)
	{
		for (usz b = 0; b < joints; b++)
		{
			self.meets[a * joints + b] = !self.regions_neighbor((uint)a, (uint)b) && !self.regions_excluded((uint)a, (uint)b);
		}
	}
}

// The table for the accelerator, or nothing when no policy is up.
fn bool[] CollisionPolicy.may_meet(&self) => self.ready ? self.meets : (bool[]){};

<*
 Rebuild the excluded-pair table from the document's list.

 Cheap — the table is joints squared — and independent of the rest contacts,
 so an exclusion edit refreshes this and nothing else. An entry naming a dot
 that is not in the binding is skipped rather than refused: the document keeps
 it for undo, and there is no region for it to exclude.
*>
fn void CollisionPolicy.adopt_exclusions(&self, RigDocument* doc)
{
	if (!self.ready) return;
	self.excluded[..] = false;
	usz joints = (usz)self.joints;
	foreach (entry : doc.collision_exclusions.array_view())
	{
		usz a = self.joint_of(entry.a);
		usz b = self.joint_of(entry.b);
		if (a >= joints || b >= joints || a == b) continue;
		self.excluded[a * joints + b] = true;
		self.excluded[b * joints + a] = true;
	}
	self.tabulate_meets();
}

<*
 The joint built from `dot_id`, or `joints` when no joint was.
*>
fn usz CollisionPolicy.joint_of(&self, uint dot_id)
{
	if (dot_id == 0) return (usz)self.joints;
	foreach (usz joint, id : self.dot_ids)
	{
		if (id == dot_id) return joint;
	}
	return (usz)self.joints;
}

<*
 Whether the two triangles share a vertex — by weld class when the policy has
 the mesh's welds, so a seam the exporter split reads as the one surface it
 models; by index otherwise.
*>
fn bool CollisionPolicy.shares_topology(&self, DeformedCollisionSurface* surface, DeformedTrianglePair pair)
{
	if (self.welds.len == 0) return surface.triangles_share_vertex(pair.a, pair.b);
	uint[3] a = surface.triangle_corners(pair.a);
	uint[3] b = surface.triangle_corners(pair.b);
	foreach (av : a)
	{
		if ((usz)av >= self.welds.len) continue;
		foreach (bv : b)
		{
			if ((usz)bv < self.welds.len && self.welds[av] == self.welds[bv]) return true;
		}
	}
	return false;
}

<*
 Each triangle's influences off the binding — the joints weighting any of
 its corners by `FOLD_WEIGHT` or more, each once, in `influence_slots` per
 triangle.
*>
fn void CollisionPolicy.read_influences(&self, DeformedCollisionSurface* surface, gltf::SkinBinding skin)
{
	usz slots = 3 * (usz)skin.slots;
	self.influence_slots = slots;
	self.influences = alloc::new_array(mem, uint, (sz)(surface.triangles * slots));
	self.influences[..] = uint::max;
	for (usz triangle = 0; triangle < surface.triangles; triangle++)
	{
		uint[] into = self.influences[triangle * slots : slots];
		usz filled = 0;
		foreach (corner : surface.triangle_corners((uint)triangle))
		{
			if ((usz)corner >= skin.vertices) continue;
			usz base = (usz)corner * (usz)skin.slots;
			for (usz slot = 0; slot < (usz)skin.slots; slot++)
			{
				if (skin.weights[base + slot] < FOLD_WEIGHT) continue;
				uint joint = (uint)skin.joints[base + slot];
				if (joint >= self.joints) continue;
				bool seen = false;
				for (usz i = 0; i < filled; i++) if (into[i] == joint) seen = true;
				if (!seen && filled < slots) into[filled++] = joint;
			}
		}
	}
}

<*
 Whether some joint weights a corner of both triangles — the shared-influence
 reading. Nothing does when the policy was built without a binding.
*>
fn bool CollisionPolicy.shares_influence(&self, DeformedTrianglePair pair)
{
	usz slots = self.influence_slots;
	if (slots == 0) return false;
	usz a = (usz)pair.a * slots;
	usz b = (usz)pair.b * slots;
	if (a + slots > self.influences.len || b + slots > self.influences.len) return false;
	uint[] first = self.influences[a : slots];
	uint[] second = self.influences[b : slots];
	foreach (joint : first)
	{
		if (joint == uint::max) break;
		foreach (other : second)
		{
			if (other == uint::max) break;
			if (other == joint) return true;
		}
	}
	return false;
}

<*
 Whether two skin regions are one region, one bone apart, or two apart along
 one line of descent — never across a fork.

 A region outside the binding — `uint::max`, the accelerator's answer for a
 triangle no joint weights — neighbors nothing.
*>
fn bool CollisionPolicy.regions_neighbor(&self, uint a, uint b)
{
	if (a >= self.joints || b >= self.joints) return false;
	if (a == b) return true;
	int above_a = self.parents[a];
	int above_b = self.parents[b];
	if (above_a == (int)b || above_b == (int)a) return true;
	// Two apart along one line of descent — a grandparent, not a sibling.
	if (above_a >= 0 && self.parents[(usz)above_a] == (int)b) return true;
	if (above_b >= 0 && self.parents[(usz)above_b] == (int)a) return true;
	return false;
}

fn bool CollisionPolicy.regions_excluded(&self, uint a, uint b)
{
	if (a >= self.joints || b >= self.joints) return false;
	return self.excluded[(usz)a * (usz)self.joints + (usz)b];
}

fn bool CollisionPolicy.rest_contact(&self, DeformedTrianglePair pair)
{
	if (pair.a > pair.b) pair = { .a = pair.b, .b = pair.a };
	usz low = 0;
	usz high = self.rest_contacts.len;
	while (low < high)
	{
		usz middle = low + (high - low) / 2;
		int order = by_pair(self.rest_contacts[middle], pair);
		if (order == 0) return true;
		if (order < 0)
		{
			low = middle + 1;
		}
		else
		{
			high = middle;
		}
	}
	return false;
}

<*
 One pair's reading. The rules are asked in the order the file comment lists
 them, so a pair that several would drop is charged to the cheapest.
*>
fn CollisionPairClass CollisionPolicy.classify(&self, DeformedCollisionSurface* surface, DeformedTrianglePair pair)
{
	if (self.shares_topology(surface, pair)) return SHARED_TOPOLOGY;
	uint region_a = surface.region_for_triangle(pair.a);
	uint region_b = surface.region_for_triangle(pair.b);
	if (self.regions_neighbor(region_a, region_b)) return NEIGHBORING_REGIONS;
	if (self.shares_influence(pair)) return SHARED_INFLUENCE;
	if (self.regions_excluded(region_a, region_b)) return EXCLUDED_REGIONS;
	if (self.rest_contact(pair)) return REST_CONTACT;
	return CANDIDATE;
}

<*
 The pairs of `raw` the narrow phase may test, in the order they arrived.

 @param raw : `What the accelerator's broad phase returned; read only.`
 @param counts : `Filled with the pass's tally when given, including what was dropped and why.`
 @return `Owned by the caller through the allocator; empty when nothing survives.`
*>
fn DeformedTrianglePair[] CollisionPolicy.filter(
	&self,
	Allocator allocator,
	DeformedCollisionSurface* surface,
	DeformedTrianglePair[] raw,
	CollisionPairCounts* counts = null)
{
	CollisionPairCounts tally;
	List{DeformedTrianglePair} kept;
	kept.init(allocator);
	defer kept.free();
	foreach (pair : raw)
	{
		switch (self.classify(surface, pair))
		{
			case CANDIDATE:
				tally.candidates++;
				kept.push(pair);
			case SHARED_TOPOLOGY: tally.shared_topology++;
			case NEIGHBORING_REGIONS: tally.neighboring_regions++;
			case SHARED_INFLUENCE: tally.shared_influence++;
			case EXCLUDED_REGIONS: tally.excluded_regions++;
			case REST_CONTACT: tally.rest_contacts++;
		}
	}
	if (counts) *counts = tally;
	return kept.len() > 0 ? kept.to_array(allocator) : (DeformedTrianglePair[]){};
}

<* The pure half of src/app/weights.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math::vector;
import std::collections::list;

<*
 How long the rig has to sit still before the weights are rebound.

 Long enough that a drag does not rebind on every mouse move, short enough that
 letting go of a dot and looking at the result feels like one action rather than
 two.
*>
const float WEIGHT_DEBOUNCE = 0.15;

// One step of FNV-1a over a whole word, for `bind_key`.
fn void mix_key(ulong* hash, ulong value) @private
{
	*hash = (*hash ^ value) * 0x0000_0100_0000_01b3;
}

<*
 Which of the two binds a reader is asking for.

 There are exactly two, and every weight tool asks for one of them by name
 rather than assembling its own from the layers underneath. Before there was a
 name for each, five callers each built "the automatic weights" their own way —
 some with the hand edits on, some without — and two tools asked the same
 question got two answers.
*>
enum WeightLayer
{
	AUTOMATIC, // every joint as the binder places it now: what an unheld joint follows and Reset goes back to
	EDITED,    // held joints' own columns as stored, the rest automatic: what the views draw, the skin rides and the file holds
}

<*
 One joint's share of the mesh, the number behind the TERRITORY view.

 `name` is borrowed from the document and dies with the next edit that renames
 or removes the dot. Copy it if it has to outlive the survey.
*>
struct JointStake
{
	uint dot;
	String name;
	usz owns;    // vertices this joint holds more strongly than any other
	usz reaches; // those, plus every other it holds at least SHOWN_FLOOR of
}

<*
 How far one joint reaches into another's, which is what a tear is made of.

 A vertex counted here is owned by `dot` and pulled on by the joint being
 surveyed, so the two disagree about where it goes. Where that straddles a
 boundary the mesh has — an arm meeting a torso — it is the smear.
*>
struct BlendShare
{
	uint dot;     // the joint that owns these vertices
	String name;  // borrowed, like JointStake.name
	usz vertices;
	float mean;   // the surveyed joint's mean share of them
	float peak;
}

<*
 What the weight views show, as numbers rather than colours.

 `stakes` is one entry per joint in BFS order — the order `get_skeleton`
 reports. `shared` is empty unless a dot was surveyed.
*>
struct WeightSurvey
{
	usz vertices;
	usz unclaimed;
	usz unused;  // vertices no joint holds — see UNUSED_TOTAL
	JointStake[] stakes;
	BlendShare[] shared;
}

fn void WeightSurvey.free(&self, Allocator allocator)
{
	if (self.stakes.len > 0) alloc::free(allocator, self.stakes);
	if (self.shared.len > 0) alloc::free(allocator, self.shared);
	*self = {};
}

<*
 The joint holding the most of one vertex's weight row, or -1 when nothing in
 the row is above zero. Ties go to the lower index. `sum` gets the row's total
 and `held` how many joints carry a share, for the callers that normalise.
*>
fn sz row_owner(float[] row, float* sum = null, usz* held = null)
{
	float total = 0.0f;
	float strongest = 0.0f;
	usz carrying = 0;
	sz best = -1;
	foreach (b, weight : row)
	{
		total += weight;
		if (weight <= 0.0f) continue;
		carrying++;
		if (weight > strongest)
		{
			strongest = weight;
			best = (sz)b;
		}
	}
	if (sum) *sum = total;
	if (held) *held = carrying;
	return best;
}

// How far from the rest of a joint's weight, as a fraction of the model's
// height, an island of it has to sit to be a stray rather than its own blend.
const float STRAY_GAP = 0.1f;

// How far a pose has to be able to pull an island off the mesh around it, as a
// fraction of the model's height, for it to be a stray — see `pull_apart`.
const float STRAY_PULL = 0.05f;

// The colour the Unused overlay marks a vertex no joint holds in — Blender's
// "missing" colour, which no territory hue, the falloff ramp nor stray red is.
const Vec3 UNUSED_MAGENTA = { 1.0, 0.0, 1.0 };

// The colour a stray is marked in while the Weights card lists it.
const Vec3 STRAY_RED = { 0.95, 0.1, 0.2 };

<*
 How far a pose can pull a point held by `row` away from the same point held
 by `other`: per joint, what its whole limb holds of the one less the other,
 times the point's distance from the joint — what turning that joint alone
 moves the two apart by, per radian. The most of any joint.

 @param limb : `Scratch, one per joint.`
*>
fn float pull_apart(rig::Skeleton* skeleton, float[] row, float[] other, Vec3 point, float[] limb)
{
	limb[..] = 0.0f;
	foreach (k, weight : row)
	{
		float apart = weight - other[k];
		if (apart == 0.0f) continue;
		for (int j = (int)k; j >= 0; j = skeleton.parents[(usz)j]) limb[(usz)j] += apart;
	}
	float most = 0.0f;
	foreach (j, apart : limb) most = math::max(most, math::abs(apart) * (point - skeleton.joints[j]).length());
	return most;
}

<*
 A patch of mesh a joint holds that is cut off from the rest of what it holds,
 and far from it — three vertices of a tail root given wholly to a knee, which
 the knee pulls out of the body as a spike. See `stray_islands`.
*>
struct StrayIsland
{
	uint dot;
	uint[] vertices;              // owned
	Vec3 centre;                  // at rest
	float peak;                   // the joint's largest share in it
	float gap;                    // nearest rest distance to the joint's own region, over the model's height
	float pull;                   // how far a pose can pull it off the mesh around it, over the model's height
	uint[SKIN_INFLUENCES] around; // the joints holding the mesh around it, strongest first
	usz around_count;
}

fn void free_strays(Allocator allocator, StrayIsland[] strays)
{
	foreach (stray : strays) if (stray.vertices.len > 0) alloc::free(allocator, stray.vertices);
	if (strays.len > 0) alloc::free(allocator, strays);
}

<*
 A fingerprint of everything the base bind is made from: the joints, their
 tree, their reaches, which shells ride which joint, the model's sharpness and
 knuckle blend, and the mesh itself. Not
 the grows or soft edges, which the live bind does not read — see
 `tool_bind_for`.

 What makes the cache trustworthy rather than merely fast. `mark_rig_stale`
 drops it on every recorded edit, but a cache that is only as fresh as the last
 caller remembered to make it hands back the bind of a rig nobody has any more —
 a dot moved by a path that forgot, and every view, the skin and the file all
 describe the old one. Checked on every read; the cost is a pass over the
 joints, against a bind that costs a pass over the mesh through the voxel grid.
*>
fn ulong bind_key(RigDocument* doc, rig::TriMesh* geometry, RigView* view)
{
	ulong hash = 0xcbf2_9ce4_8422_2325;
	mix_key(&hash, (ulong)(uptr)geometry.positions.ptr);
	mix_key(&hash, (ulong)geometry.positions.len);
	mix_key(&hash, (ulong)bitcast(doc.sharpness, uint));
	mix_key(&hash, (ulong)bitcast(doc.knuckle_blend, uint));
	foreach (b, joint : view.skeleton.joints)
	{
		mix_key(&hash, (ulong)bitcast(joint.x, uint));
		mix_key(&hash, (ulong)bitcast(joint.y, uint));
		mix_key(&hash, (ulong)bitcast(joint.z, uint));
		mix_key(&hash, (ulong)(uint)view.skeleton.parents[b]);
		mix_key(&hash, (ulong)view.dot_ids[b]);
	}
	foreach (reach : view.reaches) mix_key(&hash, (ulong)bitcast(reach, uint));
	foreach (rides : view.attachments) mix_key(&hash, (ulong)(uint)rides);
	return hash;
}

<*
 Every stray in the bind as shown, the ones a pose pulls furthest first.

 Per joint, the mesh it holds at least `STRAY_SHARE` of, split into connected
 islands over the welded surface and the layers lying on it (`joined_layers`).
 The largest is its region; a smaller island
 is a stray when the mesh around it is someone else's — not a whole piece of
 its own — it sits at least `STRAY_GAP` of the model's height from the region
 at rest, and a pose can pull it at least `STRAY_PULL` off the mesh around it
 (`pull_apart`). A joint's blend into its neighbours stays beside its region,
 and a blotch the mesh around moves with is no spike, so what this finds is
 what a pose pulls out of the body.

 The caller owns the result and frees it with `free_strays`.
*>
fn StrayIsland[] find_stray_islands(Allocator allocator, rig::TriMesh* geometry, rig::MeshAdjacency* around, rig::JoinedLayers* layers, RigView* view, float[] painted, float height)
{
	usz count = geometry.positions.len;
	usz bones = view.len();

	// One row per weld, as shares, and where it is at rest.
	usz classes = around.classes();
	float[] share = alloc::new_array(mem, float, (sz)(classes * bones));
	defer alloc::free(mem, share);
	Vec3[] point = alloc::new_array(mem, Vec3, (sz)classes);
	defer alloc::free(mem, point);
	for (usz c = 0; c < classes; c++)
	{
		usz v = (usz)around.first[c];
		point[c] = geometry.positions[v];
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[v * bones + b];
		if (sum <= 0.0f) continue;
		for (usz b = 0; b < bones; b++) share[c * bones + b] = painted[v * bones + b] / sum;
	}

	int[] island = alloc::new_array(mem, int, (sz)classes);
	defer alloc::free(mem, island);
	float[] fill = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, fill);
	float[] beside = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, beside);
	float[] limb = alloc::new_array(mem, float, (sz)bones);
	defer alloc::free(mem, limb);
	List{uint} flood;
	flood.init(mem);
	defer flood.free();
	List{uint} region;
	region.init(mem);
	defer region.free();
	List{StrayIsland} found;
	found.init(mem);
	defer found.free();
	float[SKIN_INFLUENCES] beside_shares;

	for (usz b = 0; b < bones; b++)
	{
		// The joint's islands, and which is the largest.
		island[..] = -1;
		int islands = 0;
		int largest = -1;
		usz largest_size = 0;
		for (usz c = 0; c < classes; c++)
		{
			if (island[c] >= 0 || share[c * bones + b] < STRAY_SHARE) continue;
			flood.clear();
			flood.push((uint)c);
			island[c] = islands;
			for (sz next = 0; next < flood.len(); next++)
			{
				foreach (n : around.around(flood[next]))
				{
					if (island[n] >= 0 || share[(usz)n * bones + b] < STRAY_SHARE) continue;
					island[n] = islands;
					flood.push(n);
				}
				// Layers lying on each other touch, so weight carried across them is one piece.
				foreach (n : layers.around(flood[next]))
				{
					if (island[n] >= 0 || share[(usz)n * bones + b] < STRAY_SHARE) continue;
					island[n] = islands;
					flood.push(n);
				}
			}
			if ((usz)flood.len() > largest_size)
			{
				largest_size = (usz)flood.len();
				largest = islands;
			}
			islands++;
		}
		if (islands < 2) continue;

		region.clear();
		for (usz c = 0; c < classes; c++) if (island[c] == largest) region.push((uint)c);

		for (int k = 0; k < islands; k++)
		{
			if (k == largest) continue;
			bool bordered = false;
			float nearest = float::max;
			float peak = 0.0f;
			Vec3 middle = {};
			usz members = 0;
			fill[..] = 0.0f;
			for (usz c = 0; c < classes; c++)
			{
				if (island[c] != k) continue;
				members++;
				middle += point[c];
				peak = math::max(peak, share[c * bones + b]);
				foreach (n : around.around(c))
				{
					if (island[n] == k) continue;
					if (share[(usz)n * bones + b] < AREA_LEAK_FLOOR) bordered = true;
					for (usz j = 0; j < bones; j++) fill[j] += share[(usz)n * bones + j];
				}
				foreach (r : region) nearest = math::min(nearest, (point[r] - point[c]).length());
			}
			if (!bordered || nearest < STRAY_GAP * height) continue;

			// The mesh around it, as one row: what the island moves with once fixed.
			float total = 0.0f;
			foreach (weight : fill) total += weight;
			if (total <= 0.0f) continue;
			foreach (&weight : fill) *weight /= total;
			float pull = 0.0f;
			for (usz c = 0; c < classes; c++)
			{
				if (island[c] == k) pull = math::max(pull, pull_apart(&view.skeleton, share[c * bones:bones], fill, point[c], limb));
			}
			if (pull < STRAY_PULL * height) continue;

			StrayIsland stray = { .dot = view.dot_ids[b], .centre = middle / (float)members, .peak = peak,
				.gap = nearest / height, .pull = pull / height };
			beside[..] = fill[..];
			beside[b] = 0.0f;
			stray.around_count = strongest_shares(beside, view.dot_ids, stray.around[..], beside_shares[..], 0.0f);
			usz held = 0;
			for (usz v = 0; v < count; v++) if (island[around.class_of[v]] == k) held++;
			stray.vertices = alloc::new_array(allocator, uint, (sz)held);
			held = 0;
			for (usz v = 0; v < count; v++) if (island[around.class_of[v]] == k) stray.vertices[held++] = (uint)v;
			found.push(stray);
		}
	}

	StrayIsland[] strays = alloc::new_array(allocator, StrayIsland, found.len());
	foreach (i, stray : found) strays[i] = stray;
	for (usz i = 0; i + 1 < strays.len; i++)
	{
		usz top = i;
		for (usz j = i + 1; j < strays.len; j++) if (strays[j].pull > strays[top].pull) top = j;
		if (top == i) continue;
		StrayIsland swap = strays[i];
		strays[i] = strays[top];
		strays[top] = swap;
	}
	return strays;
}

<*
 Read the bind as numbers: who owns what, who reaches into whose, what nothing
 owns.

 The same dense matrix `rebind_tints` paints from, and deliberately so — an
 answer that disagreed with the picture on screen would be worse than no answer.
 It follows that this reports the binder's raw weights and not the file's:
 `sparsify_weights` keeps only a vertex's four strongest afterwards, so `owns`
 is what TERRITORY draws either way, while a `reaches` entry ranking fifth or
 lower on its vertex is one the export will drop.

 Rebinds from scratch on every call — the cost of `rebind_tints`, without its
 debounce — so this is a diagnostic to ask a question with, not something to
 call per frame.

 The caller owns the result and frees it with `WeightSurvey.free`.

*>
fn WeightSurvey survey_of(Allocator allocator, rig::MeshShells* shells, RigView* view, float[] dense, float[] nearest, int[] riders, usz vertices, sz focus)
{
	usz bones = view.len();

	usz unused = 0;
	JointStake[] stakes = alloc::new_array(allocator, JointStake, (sz)bones);
	for (usz j = 0; j < bones; j++)
	{
		stakes[j] = { .dot = view.dot_ids[j], .name = view.names[j] };
	}

	// Per owning joint, what the surveyed one still holds of its vertices.
	usz[] taken = alloc::new_array(mem, usz, (sz)bones);
	float[] taken_sum = alloc::new_array(mem, float, (sz)bones);
	float[] taken_peak = alloc::new_array(mem, float, (sz)bones);

	defer {
		alloc::free(mem, taken);
		alloc::free(mem, taken_sum);
		alloc::free(mem, taken_peak);
	}

	for (usz v = 0; v < vertices; v++)
	{
		usz base = v * bones;

		// Shares, not raw weights: the raw output spans orders of magnitude and a
		// floor over it would mean something different at every vertex. This is the
		// normalisation `falloff_tints` paints and `sparsify_weights` writes.
		float sum;
		sz owner = row_owner(dense[base:bones], &sum);
		if (sum <= UNUSED_TOTAL) unused++;
		if (sum <= 0.0f || owner < 0) continue;
		usz best = (usz)owner;
		stakes[best].owns++;

		// The owner always reaches what it owns. On a rig with enough joints the
		// strongest share of an evenly-spread vertex can sit under the floor, and a
		// dot reported as owning mass it does not reach describes nothing.
		for (usz b = 0; b < bones; b++)
		{
			if (b == best || dense[base + b] / sum >= SHOWN_FLOOR) stakes[b].reaches++;
		}

		if (focus < 0 || (usz)focus == best) continue;

		float share = dense[base + (usz)focus] / sum;
		if (share < SHOWN_FLOOR) continue;
		taken[best]++;
		taken_sum[best] += share;
		if (share > taken_peak[best]) taken_peak[best] = share;
	}

	bool[] stray = unclaimed_mask(mem, nearest, vertices, shells, riders, view.pins);
	defer alloc::free(mem, stray);
	usz unclaimed = 0;
	foreach (flag : stray)
	{
		if (flag) unclaimed++;
	}

	usz neighbours = 0;
	for (usz b = 0; b < bones; b++)
	{
		if (taken[b] > 0) neighbours++;
	}

	BlendShare[] shared = neighbours > 0
		? alloc::new_array(allocator, BlendShare, (sz)neighbours)
		: (BlendShare[]){};
	usz at = 0;
	for (usz b = 0; b < bones; b++)
	{
		if (taken[b] == 0) continue;
		shared[at++] = {
			.dot = stakes[b].dot,
			.name = stakes[b].name,
			.vertices = taken[b],
			.mean = taken_sum[b] / (float)taken[b],
			.peak = taken_peak[b],
		};
	}

	// Worst first, so a caller reading only the head of the list reads the
	// boundary most likely to tear. Selection sort over one entry per joint.
	for (usz i = 0; i + 1 < shared.len; i++)
	{
		usz top = i;
		for (usz j = i + 1; j < shared.len; j++)
		{
			if (shared[j].vertices > shared[top].vertices) top = j;
		}
		if (top != i)
		{
			BlendShare swap = shared[i];
			shared[i] = shared[top];
			shared[top] = swap;
		}
	}

	return {
		.vertices = vertices,
		.unclaimed = unclaimed,
		.unused = unused,
		.stakes = stakes,
		.shared = shared,
	};
}

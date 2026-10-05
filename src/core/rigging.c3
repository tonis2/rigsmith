<*
 The document read as a rig: a skeleton, and the colours the weight preview
 paints with.

 This is the seam between the two halves of crig. Everything below `core/` works
 in dots and edges — an undirected graph the user edits in any order — and
 everything in `module rig` works in joints and parents, an ordered tree where a
 parent is always a lower index than its children. `build_skeleton` is the one
 place that conversion happens, so the direction of every bone in an exported
 file traces back to a single BFS.

 Nothing here is stored. The skeleton is derived on demand from the document,
 which is what makes the document the only thing that can be wrong: there is no
 second copy to drift out of agreement with the dots on screen.
*>
module crig;

import rig;


import std::io::file;
import std::math;

<*
 Raised by `build_skeleton` when the document has no dots — nothing to derive a
 skeleton from, which is a state the user can be in and not an error in the
 sense the rig code means it.
*>
faultdef NO_DOTS;

<*
 The document as a `rig::Skeleton`: joints in BFS order from the root, each
 holding the index of the joint it was reached from.

 BFS, not DFS, and from the root the user set rather than from dot zero. Two
 things follow from that and both matter downstream:

     parents precede children    which every ancestor walk assumes, and the
                                 glTF writer assumes when it emits nodes
     a fork's first child is     which is what `Skeleton.tails` aims a bone at,
     the one reached first        so bones point down the chain being walked

 Dots the root cannot reach are appended as further roots rather than dropped.
 A disconnected dot is a rig with two armatures in it, which is odd but is what
 the user built; silently discarding placed work is worse, and the export
 overlay is where that should be surfaced instead.

 Ids are resolved to positions by a linear scan of the dot list, the same lookup
 `RigDocument.find` does. Edges are resolved once up front rather than per
 visit — that is the difference between this being linear-ish and being cubic,
 and it costs six lines.

 The caller owns the returned skeleton and frees it with `Skeleton.free`.

 @param dot_ids_out : `When set, receives one dot id per joint, in joint order.`
 @return? NO_DOTS : `The document is empty.`
*>
fn rig::Skeleton? build_skeleton(RigDocument* doc, Allocator allocator, uint[]* dot_ids_out = null)
{
	usz count = (usz)doc.dots.len();
	if (count == 0) return NO_DOTS~;

	Dot[] dots = doc.dots.array_view();

	Vec3[] joints = alloc::new_array(allocator, Vec3, (sz)count);
	int[] parents = alloc::new_array(allocator, int, (sz)count);

	// Joint indices are BFS output — they shift the moment a dot is added,
	// deleted or re-rooted — so a caller that needs to talk about *dots* (the
	// falloff view's selection is one) takes the map out of the same build
	// that produced the order. Same allocator, same ownership as the skeleton.
	uint[] dot_ids;
	if (dot_ids_out)
	{
		dot_ids = alloc::new_array(allocator, uint, (sz)count);
		*dot_ids_out = dot_ids;
	}

	// Joint index per dot, -1 until visited — the visited set and the id→joint
	// map in one array, because both are answered at the same moment.
	int[] joint_of = alloc::new_array(allocator, int, (sz)count);
	defer alloc::free(allocator, joint_of);
	joint_of[:count] = -1;

	// Every edge, once, as a pair of slots in `dots`. An edge naming a missing
	// dot cannot happen — `connect` rejects those and `remove_dot` drops them —
	// but a slot of `count` reads as "no such dot" if one ever does.
	usz links = (usz)doc.edges.len();
	usz[] link_a = alloc::new_array(allocator, usz, (sz)links);
	usz[] link_b = alloc::new_array(allocator, usz, (sz)links);
	defer
	{
		alloc::free(allocator, link_a);
		alloc::free(allocator, link_b);
	}
	foreach (usz i, edge : doc.edges.array_view())
	{
		link_a[i] = dot_slot(dots, edge.a);
		link_b[i] = dot_slot(dots, edge.b);
	}

	// Slots waiting to have their neighbours walked. One entry per dot at most,
	// so an array with a head beats a list that would have to grow.
	usz[] queue = alloc::new_array(allocator, usz, (sz)count);
	defer alloc::free(allocator, queue);
	usz head = 0;
	usz tail = 0;

	// The user's root becomes joint 0. `root_id` naming nothing should not
	// happen — `remove_dot` re-homes it — but a rootless document must still
	// export rather than fault, so the first dot stands in.
	usz first = dot_slot(dots, doc.root_id);
	if (first >= count) first = 0;

	usz emitted = 0;
	usz scan = 0;

	while (emitted < count)
	{
		usz seed = first;
		if (joint_of[seed] >= 0)
		{
			while (scan < count && joint_of[scan] >= 0) scan++;
			if (scan >= count) break; // unreachable: emitted < count means one is left
			seed = scan;
		}

		joint_of[seed] = (int)emitted;
		joints[emitted] = dots[seed].position;
		parents[emitted] = -1;
		if (dot_ids_out) dot_ids[emitted] = dots[seed].id;
		emitted++;
		queue[tail++] = seed;

		while (head < tail)
		{
			usz slot = queue[head++];
			int parent = joint_of[slot];

			for (usz e = 0; e < links; e++)
			{
				usz other = count;
				if (link_a[e] == slot)
				{
					other = link_b[e];
				}
				else if (link_b[e] == slot)
				{
					other = link_a[e];
				}
				if (other >= count || joint_of[other] >= 0) continue;

				joint_of[other] = (int)emitted;
				joints[emitted] = dots[other].position;
				parents[emitted] = parent;
				if (dot_ids_out) dot_ids[emitted] = dots[other].id;
				emitted++;
				queue[tail++] = other;
			}
		}
	}

	return { .joints = joints, .parents = parents };
}

<*
 Where a dot id sits in the dot list, or `dots.len` for no such dot.
*>
fn usz dot_slot(Dot[] dots, uint id) @private
{
	if (id == 0) return dots.len;
	foreach (usz i, dot : dots) if (dot.id == id) return i;
	return dots.len;
}

// ---------------------------------------------------------------------------
// The weight preview.

<*
 The hand corrections, multiplied into a bind that is already in joint order.

 	`paint_over(dense, bones, view.paint);`

 **Between the binder and the prune**, always — after the weights exist and
 before `sparsify_weights` picks the four a vertex keeps. A correction that
 pushes a joint out of the top four should take it out of the file too, and one
 that pulls a joint in should put it there; doing it after the prune could only
 rescale influences the prune had already chosen.

 Every caller that binds has to call this, or the views disagree with the file —
 which is the one defect `vertex_tints` exists to prevent. Empty paint is the
 ordinary case and costs a single branch.

 @param dense : `vertices x bones, as the binder returns it. Modified in place.`
 @param bones : `The row stride: the joint count of the build the columns were resolved against.`
*>
fn void paint_over(float[] dense, usz bones, PaintColumn[] paint)
{
	foreach (column : paint)
	{
		usz at = (usz)column.vertex * bones + column.joint;
		if (at < dense.len) dense[at] *= column.factor;
	}
}

<*
 The stated shares, written over a bind that is already in joint order.

 	`pin_over(dense, bones, view.pins);`

 **After the paint, before the prune, always** — the last word on a row, which
 is the whole point of the layer: the binder, the sharpness and the corrections
 have each had their say by the time this runs, and a pin is the user saying
 something none of them can be argued into. Applying it earlier would let
 `paint_over` scale a stated share back into a suggestion.

 Per pinned vertex, one row rewrite. Shares are clamped to 0..1 and, when they
 sum past 1, scaled down together so they sum to exactly 1 — two dots both
 promised the whole of a vertex is a request that has to be *shared* rather than
 refused, and scaling keeps their ratio. The un-pinned columns are then scaled
 so their part of the row sums to what is left, `1 − P`, which is what makes a
 partial pin mean "this much of it, and the rest goes on as before, pro rata".
 Where the un-pinned part sums to nothing there is no ratio to keep and those
 columns stay zero; downstream normalisation then hands the whole vertex to the
 pins, which is the only reading available.

 A single share of 1 therefore lands the row `rigid_shells` writes exactly —
 every column zero and one column 1 — so pinning a region by hand and having the
 binder pin the piece by itself produce the same weights, not merely similar
 ones.

 **Mixing shares into a score row is safe** because the rows are unnormalised
 throughout and every consumer divides by the row's own sum. What this writes
 is therefore a row whose sum is 1 where a neighbouring row's is 1e4, and both
 read the same after normalisation.

 @param dense : `vertices x bones, as the binder returns it. Modified in place.`
 @param bones : `The row stride: the joint count of the build the columns were resolved against.`
 @param pins : `Grouped by vertex — every pin on one vertex contiguous, which is what AppState.pin_columns guarantees. Ungrouped input would rewrite a row twice and rescale the first rewrite.`
*>
fn void pin_over(float[] dense, usz bones, PinColumn[] pins)
{
	if (bones == 0 || pins.len == 0) return;

	usz at = 0;
	while (at < pins.len)
	{
		uint vertex = pins[at].vertex;
		usz end = at;
		while (end < pins.len && pins[end].vertex == vertex) end++;

		usz row = (usz)vertex * bones;
		if (row + bones > dense.len)
		{
			at = end;
			continue;
		}

		float claimed = 0.0f;
		for (usz i = at; i < end; i++) claimed += pin_share(pins[i]);

		// Over-promised shares keep their ratio to each other and lose their
		// absolute size, which is the only division of a vertex that respects both
		// requests.
		float squeeze = claimed > 1.0f ? 1.0f / claimed : 1.0f;
		if (claimed > 1.0f) claimed = 1.0f;

		// What the row holds outside the pinned columns, which is what the rest of
		// the vertex is shared out in proportion to.
		float rest = 0.0f;
		for (usz b = 0; b < bones; b++) rest += dense[row + b];
		for (usz i = at; i < end; i++)
		{
			if (pins[i].joint < bones) rest -= dense[row + pins[i].joint];
		}
		if (rest < 0.0f) rest = 0.0f; // the subtraction is float arithmetic

		// The whole row, pinned columns included — they are overwritten below, and
		// scaling them first is cheaper than testing each column for membership of
		// a list that is almost always one long.
		float keep = rest > 0.0f ? (1.0f - claimed) / rest : 0.0f;
		for (usz b = 0; b < bones; b++) dense[row + b] *= keep;

		for (usz i = at; i < end; i++)
		{
			if (pins[i].joint >= bones) continue;
			dense[row + pins[i].joint] = pin_share(pins[i]) * squeeze;
		}

		at = end;
	}
}

// One pin's share as the arithmetic above may use it. Clamped here rather than
// at the setter alone, because a column can also be built by a caller that did
// not come through `RigDocument.set_pin` — and a share outside 0..1 would leave
// the row summing to something other than one.
fn float pin_share(PinColumn pin) @local
{
	if (pin.share < 0.0f) return 0.0f;
	if (pin.share > 1.0f) return 1.0f;
	return pin.share;
}

<*
 Narrows every transition band the binder made, by raising each weight to a
 power.

 	`sharpen_weights(bound, doc.sharpness);`

 **Element-wise, and no renormalisation here.** The binder's rows are
 unnormalised scores — `reach_bias / (d² + eps)` — and every consumer divides by
 the row's own sum before it reads a share. Raising the scores to γ and raising
 the shares to γ therefore give the same shares back: the sum of the powered
 weights that a normalising sharpen would divide by is exactly the sum the
 consumer already computes. So one `pow` per cell is the whole operation, and
 dividing here would only turn scores into shares for callers that do not want
 them.

 What it buys is the hard-surface case. A geodesic bind over a model assembled
 from solid pieces puts broad gradients where an artist would paint a narrow
 seam; γ above 1 pushes the dominant joint's share toward 1 and everything else
 toward 0, so the band shrinks without any joint changing hands — the argmax of
 a row is invariant under a monotone power, which is why the territory map keeps
 its boundaries and only the mush around them goes away.

 A row that is already rigid — one 1 and the rest 0 — comes back unchanged at
 any γ: both 1 and 0 are their own powers. That is what keeps a pinned shell
 pinned however sharp the rest of the model is asked to be.

 **Zero is unset, not "flatten everything".** A document that has never been
 asked for a sharpness carries a zero-initialised field, and 0 would otherwise
 raise every weight to the power of nothing and hand the mesh to whichever joint
 the tie-break picked. So `gamma <= 0` is read as "no sharpening" here rather
 than at each of the two call sites.

 The cost is one `pow` per vertex per bone — tens of milliseconds on a dense
 mesh, the same order as the bind it follows. It rides the debounced rebind path
 and the cached base bind, so it is paid once per rig edit rather than per frame.

 @param dense : `vertices x bones, as the binder returns it. Modified in place.`
 @param gamma : `The power. 1 is the binder's own blend, above it is sharper, and anything at or below 0 is unset and does nothing.`
*>
fn void sharpen_weights(float[] dense, float gamma)
{
	if (gamma <= 0.0f || gamma == 1.0f) return;
	foreach (&weight : dense)
	{
		// Zero and one are their own powers, and skipping them costs a comparison
		// against a libm call on the two values a bind is mostly made of.
		if (*weight > 0.0f && *weight != 1.0f) *weight = math::pow(*weight, gamma);
	}
}

<*
 Turns of the hue wheel between one joint's colour and the next.

 The golden ratio, so no small number of joints ever lands on a repeat and,
 more usefully, consecutive joints are far apart on the wheel. Consecutive is
 exactly what adjacent means here — BFS emits a chain in order — so stepping the
 hue by a little would give a leg five shades of the same green and no visible
 boundary between the joints it is meant to separate.
*>
const float TINT_HUE_STEP = 0.618034;

// Full value, held-back saturation: these multiply into the lambert shade, and
// a fully saturated red over a dark side of the model goes black rather than
// dark red.
const float TINT_SATURATION = 0.72;

<*
 One packed colour per vertex: the joint that holds that vertex most.

 Argmax rather than a blend of the four influences that survive to a file. A
 blend is prettier and says less — the question the preview answers is "which
 dot owns this piece of the mesh", and the thing worth seeing is where the
 boundary between two of them falls. Blending puts a smooth ramp exactly where
 the boundary is.

 It draws the same weights the exporter writes, from the same binder, so a leg
 that bleeds into its neighbour on screen bleeds in the file too. That is the
 whole point of previewing it: the preview is the diagnostic for the binder,
 not a decoration.

 Colours are packed r|g<<8|b<<16|a<<24 and unpacked with the same shifts in
 `mesh.shady`, so no byte order is assumed on either side.

 The caller owns the returned array. It is exactly as long as `positions`.

 @param voxels : `The mesh's interior; null measures straight lines instead.`
 @param shells : `The mesh's separate pieces; null leaves loose ones to the ordinary rules.`
 @param attachments : `One joint index per shell, -1 to decide automatically.`
 @param reaches : `One per joint, in model units, 0 for no limit. Empty leaves every dot unlimited.`
*>
fn uint[] vertex_tints(
	Allocator allocator,
	Vec3[] positions,
	rig::Skeleton* skeleton,
	rig::MeshVoxels* voxels = null,
	rig::MeshShells* shells = null,
	int[] attachments = {},
	float[] reaches = {},
	PaintColumn[] paint = {},
	float[] bound = {})
{
	uint[] tints = alloc::new_array(allocator, uint, (sz)positions.len);

	usz bones = skeleton.joints.len;
	if (bones == 0)
	{
		tints[..] = 0;
		return tints;
	}

	bool given = bound.len == positions.len * bones;
	float[] dense = given ? bound : rig::bind_geodesic(
		allocator, voxels, positions, skeleton.joints, skeleton.parents,
		shells, attachments, reaches: reaches);
	defer if (!given) alloc::free(allocator, dense);
	if (!given) paint_over(dense, bones, paint);

	for (usz v = 0; v < positions.len; v++)
	{
		usz base = v * bones;
		usz best = 0;
		float strongest = dense[base];
		for (usz b = 1; b < bones; b++)
		{
			if (dense[base + b] > strongest)
			{
				strongest = dense[base + b];
				best = b;
			}
		}
		tints[v] = joint_tint(best);
	}

	return tints;
}

<*
 One packed colour per vertex: a single joint's weight on one ramp — grey 0,
 orange 1 (`share_tint`, B7's falloff view).

 The territory map (`vertex_tints`) reports *which* joint wins a vertex and
 says nothing about magnitude; this is the opposite half — one joint at a
 time, and nothing but magnitude. One scale rather than per-joint colours is
 what makes high and low unambiguous: on the territory map a colour only means
 "this dot", here grey always means "not this dot's".

 The weight shown is the joint's normalised share of the vertex — what
 `sparsify_weights` would compute for that influence — because that is the
 number the exported file is actually made of. The binder's raw output spans
 orders of magnitude and a ramp over it would paint almost everything at one
 end.

 The caller owns the returned array. It is exactly as long as `positions`.

 @param voxels : `The mesh's interior; null measures straight lines instead.`
 @param shells : `The mesh's separate pieces; null leaves loose ones to the ordinary rules.`
 @param attachments : `One joint index per shell, -1 to decide automatically.`
 @param reaches : `One per joint, in model units, 0 for no limit. Empty leaves every dot unlimited.`
 @param floor : `The share at which a vertex counts towards held — see BLEND_FLOOR, which is what the app passes.`
 @param held : `Filled with how many vertices the joint holds at least floor of. Null to not ask. Free beside the ramp it is counted from: the same pass produces both, so asking costs a comparison per vertex and nothing else.`
*>
fn uint[] falloff_tints(
	Allocator allocator,
	Vec3[] positions,
	rig::Skeleton* skeleton,
	usz joint,
	rig::MeshVoxels* voxels = null,
	rig::MeshShells* shells = null,
	int[] attachments = {},
	float[] reaches = {},
	float floor = 0.0f,
	usz* held = null,
	PaintColumn[] paint = {},
	float[] bound = {})
{
	uint[] tints = alloc::new_array(allocator, uint, (sz)positions.len);
	if (held) *held = 0;

	usz bones = skeleton.joints.len;
	if (bones == 0 || joint >= bones)
	{
		tints[..] = 0;
		return tints;
	}

	bool given = bound.len == positions.len * bones;
	float[] dense = given ? bound : rig::bind_geodesic(
		allocator, voxels, positions, skeleton.joints, skeleton.parents,
		shells, attachments, reaches: reaches);
	defer if (!given) alloc::free(allocator, dense);
	if (!given) paint_over(dense, bones, paint);

	for (usz v = 0; v < positions.len; v++)
	{
		usz base = v * bones;
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += dense[base + b];

		float share = sum > 0.0f ? dense[base + joint] / sum : 0.0f;
		tints[v] = weight_ramp(share);
		if (held && share >= floor) (*held)++;
	}

	return tints;
}

<*
 How far out from any bone a vertex may sit before it counts as unclaimed, as
 a fraction of the worst-served vertex's distance. The same cut the offline
 diagnostic (`unclaimed_regions` in test/export_test.c3) reports on.
*>
const float UNCLAIMED_CUT = 0.70;

<*
 Which vertices sit too far from every bone to count as claimed.

 The mass no dot owns — the territory map's opposite question, and the one that
 says where to click next. It reaches the outside as the `unclaimed` count on
 every `get_weights` answer, which is its only consumer: a number rather than a
 picture, so that the person driving crig over MCP can ask where the rig still
 has holes without needing anything painted on the screen.

 Distance rather than weight share, because every vertex has *some* strongest
 joint after normalisation — the tie-break-by-index at the export (see the
 plan's §8) is exactly the failure this test exists to catch, and weight cannot
 see it: distance to a bone clamps to the segment, so a vertex behind a joint is
 equidistant from all of that joint's children and the argmax looks decided
 where nothing is. Geodesic weights do not remove that — a path through the body
 clamps the same way — which is why this outlives M3.

 With a grid the distance recovered is the one measured through the body, so
 mass on the far side of a gap reads as far away even when a straight line
 through the air would have called it close.

 Distance comes from the binder rather than from the weights it produced. It
 used to be recovered by inverting `1/(d² + ε)`, which stopped being possible the
 moment a dot could be given a reach: the weight is then `s/(d² + ε)` with the
 window `s` closing towards the edge of the reach, so the inversion reports a
 vertex just inside a reach as further away than one outside every reach — and
 since the cut is relative, those false readings would set it and hide the
 genuinely stranded mass. `bind_geodesic` fills `nearest` with the distance it
 actually measured, straight lines or paths through the body.

 The cut is relative: `UNCLAIMED_CUT` of the worst-served vertex in this mesh,
 which is why a rig that covers everything badly still reports its worst rather
 than reporting nothing.

 A shell the binder pinned rigidly is never unclaimed. It rides one joint by
 fiat, whatever its distance to anything — `riders` is the only record of which
 shells that happened to.

 **A pinned vertex is never unclaimed either**, and it is the same fiat one step
 finer: the user has said which dot holds it, so how far the nearest bone
 happens to be is no longer a question about whether anything owns it. Without
 this, lassoing a floating piece onto a dot would leave it still counted as
 stranded — the one place the answer is certainly wrong.

 @param nearest : `Squared distance to the closest bone per vertex, as bind_geodesic fills it.`
 @param riders : `One entry per shell from the same bind; >= 0 marks a pinned shell. Empty leaves every vertex judged on its distance.`
 @param pins : `The stated shares for this build. Every vertex named by one is claimed, whatever its distance.`
 @require nearest.len >= vertices : `The distances must cover every vertex.`
 @return `One flag per vertex, true where nothing owns it. The caller owns the array.`
*>
fn bool[] unclaimed_mask(
	Allocator allocator,
	float[] nearest,
	usz vertices,
	rig::MeshShells* shells = null,
	int[] riders = {},
	PinColumn[] pins = {})
{
	bool[] stray = alloc::new_array(allocator, bool, (sz)vertices);
	if (vertices == 0) return stray;

	float worst = 0.0f;
	for (usz v = 0; v < vertices; v++)
	{
		float d2 = nearest[v];
		if (d2 > worst) worst = d2;
	}

	// Compared as distances rather than as their squares, so the cut keeps
	// meaning the fraction of the worst distance it has always meant.
	float cut = math::sqrt(worst) * UNCLAIMED_CUT;
	for (usz v = 0; v < vertices; v++)
	{
		bool pinned = riders.len > 0
			&& shells != null
			&& shells.of[v] >= 0
			&& (usz)shells.of[v] < riders.len
			&& riders[shells.of[v]] >= 0;
		stray[v] = !pinned && math::sqrt(nearest[v]) >= cut;
	}

	// After the distance pass rather than inside it: the pins are sparse and a
	// membership test per vertex would be a scan of the layer per vertex, where
	// this is one walk of the layer whatever the mesh's size.
	foreach (pin : pins)
	{
		if ((usz)pin.vertex < vertices) stray[pin.vertex] = false;
	}

	return stray;
}

// The two ends of every one-joint weight view: grey where the joint holds
// nothing, orange where it holds all of it. The Weights card's part, the brush
// and the falloff view all read on this one scale.
const Vec3 WEIGHT_GREY = { 0.23, 0.23, 0.23 };
const Vec3 WEIGHT_ORANGE = { 1.0, 0.55, 0.12 };

<*
 A joint's share of a vertex as a colour, grey at 0 to orange at 1, packed
 RGBA8 opaque.
*>
fn uint share_tint(float share)
{
	float t = math::clamp(share, 0.0f, 1.0f);
	Vec3 c = WEIGHT_GREY + (WEIGHT_ORANGE - WEIGHT_GREY) * t;
	return rgb(c.x, c.y, c.z);
}

fn uint weight_ramp(float share) @private => share_tint(share);

<*
 Linear RGB to packed RGBA8, opaque — the scalar half of `pack_rgb`.
*>
fn uint rgb(float red, float green, float blue) @private
{
	return channel(red) | (channel(green) << 8) | (channel(blue) << 16) | 0xFF00_0000u;
}

<*
 The colour standing for one joint, packed RGBA8.

 A pure function of the index, so the same joint keeps its colour across a
 recompute and the preview does not reshuffle every time a dot moves — as long
 as the joint order holds, which is what BFS from a fixed root gives.
*>
fn uint joint_tint(usz index)
{
	float hue = (float)index * TINT_HUE_STEP;
	return pack_rgb(hue - math::floor(hue), TINT_SATURATION, 1.0f);
}

<*
 HSV to packed RGBA8, opaque.
*>
fn uint pack_rgb(float hue, float saturation, float value) @private
{
	float sector = hue * 6.0f;
	int face = (int)sector;
	float rise = sector - (float)face;

	float down = value * (1.0f - saturation);
	float falling = value * (1.0f - saturation * rise);
	float rising = value * (1.0f - saturation * (1.0f - rise));

	float red, green, blue;
	switch (face % 6)
	{
		case 0: red = value;   green = rising;  blue = down;    break;
		case 1: red = falling; green = value;   blue = down;    break;
		case 2: red = down;    green = value;   blue = rising;  break;
		case 3: red = down;    green = falling; blue = value;   break;
		case 4: red = rising;  green = down;    blue = value;   break;
		default: red = value;  green = down;    blue = falling; break;
	}

	return channel(red) | (channel(green) << 8) | (channel(blue) << 16) | 0xFF00_0000u;
}

fn uint channel(float value) @private => (uint)math::clamp(value * 255.0f + 0.5f, 0.0f, 255.0f);

// ---------------------------------------------------------------------------
// Export.

<*
 Where the rigged copy of a mesh goes: beside the original, with `_rigged`
 before the extension.

 Beside rather than in the working directory, because crig is started with a
 path and the answer belongs where the question came from. The stem is cut at
 the last dot of the *last path segment*, so a directory with a dot in its name
 does not swallow the file name.

 The caller owns the returned string.
*>
fn String rigged_path(Allocator allocator, String source)
{
	return string::format(allocator, "%s_rigged.glb", source[:path_stem(source)]);
}

<*
 Where a model crig has been asked to save goes when the model itself is not
 crig's to overwrite: beside it, with `_copy` before the extension.

 	`bandicoot.glb  ->  bandicoot_copy.glb`

 The extension is kept rather than forced to `.glb`, because the copy starts life
 as a byte copy of the original and has to still be the kind of file it was.

 The caller owns the returned string.
*>
fn String copy_path(Allocator allocator, String source)
{
	usz cut = path_stem(source);
	return string::format(allocator, "%s_copy%s", source[:cut], source[cut..]);
}

<*
 Duplicate a file, whole.

 	`if (!copy_file(original, beside)) { … }`

 Read in one call and written in one, because the caller is about to edit the
 result in place: a partial copy of a `.glb` is not a short model, it is a file
 whose chunk headers describe bytes that are not there.

 @return `False when either half failed. Whatever was written is the caller's to remove.`
*>
fn bool copy_file(String from, String to)
{
	char[]? bytes = file::load(mem, from);
	if (catch bytes) return false;
	defer alloc::free(mem, bytes);

	if (catch file::save(to, bytes)) return false;
	return true;
}

// Where a path's extension begins, or its end when it has none. Cut at the last
// dot of the *last segment*, so a directory with a dot in its name does not
// swallow the file name.
fn usz path_stem(String path) @private
{
	for (usz i = path.len; i > 0; i--)
	{
		char c = path[i - 1];
		if (c == '/' || c == '\\') break;
		if (c == '.') return i - 1;
	}
	return path.len;
}

<*
 The last segment of a path — what to name a file in a message the user reads.
*>
fn String base_name(String path)
{
	for (usz i = path.len; i > 0; i--)
	{
		if (path[i - 1] == '/' || path[i - 1] == '\\') return path[i..];
	}
	return path;
}

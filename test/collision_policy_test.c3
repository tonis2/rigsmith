<*
 C2: which broad-phase pairs the self-collision check is allowed to keep.

 The accelerator's own checks (`deformed_collision_test.c3`) stop at raw
 pairs. These take the raw pairs and prove each reading independently: shared
 topology, one region or one bone apart, one patch under a shared joint, a
 contact modelled into the rest pose, an authored exclusion — and that what
 is left is exactly the pairs a pose brought together that nothing explains
 away.
*>
module crig_tests::collision_policy;

import crig;
import rig;
import gltf;
import collision;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::matrix;

fn bool near(float a, float b) => math::abs(a - b) < 1.0e-5f;

const uint[36] BOX_FACES @local = {
	4, 5, 6, 4, 6, 7,
	0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5,
	0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2,
	0, 1, 5, 0, 5, 4,
};

fn void corners(Vec3[] into, Vec3 low, Vec3 high) @local
{
	into[0] = { low.x, low.y, low.z };
	into[1] = { high.x, low.y, low.z };
	into[2] = { high.x, high.y, low.z };
	into[3] = { low.x, high.y, low.z };
	into[4] = { low.x, low.y, high.z };
	into[5] = { high.x, low.y, high.z };
	into[6] = { high.x, high.y, high.z };
	into[7] = { low.x, high.y, high.z };
}

const float CLEARANCE @local = 0.2f;

<*
 Four boxes on two limbs under one hub, each box rigid to one joint:

     H (joint 4, no skin) ─┬─ B (joint 1) ── A (joint 0)
                           └─ C (joint 2) ── D (joint 3)

     A at x [-2.5, -1.5]                  B at x [-1.4, -0.4], 0.1 from A, 0.4 lower
     C above A, 0.1 up                    D at x [1.5, 2.5], far from all

 So at rest A–B are within clearance and one bone apart, A–C are within
 clearance three bones apart across the hub — the modelled contact — B–C are
 apart, and D touches nothing until a palette moves it. The hub is what
 keeps the two limbs from being a line: two regions on one line of descent
 are neighbors up to two bones apart, and the pairs the checks want blocked
 have to be cousins.
*>
struct ChainFixture
{
	Vec3[32] positions;
	uint[144] indices;
	ushort[32] joints;
	float[32] weights;
	int[5] parents;
	uint[5] dot_ids;
	rig::TriMesh mesh;
	gltf::SkinBinding binding;
	crig::Picker picker;
	crig::DeformedCollisionSurface surface;
	crig::RigDocument doc;
	crig::CollisionPolicy policy;
}

fn void ChainFixture.init(&self)
{
	corners(self.positions[0:8], { -2.5, -0.5, -0.5 }, { -1.5, 0.5, 0.5 });
	corners(self.positions[8:8], { -1.4, -0.9, -0.5 }, { -0.4, 0.1, 0.5 });
	corners(self.positions[16:8], { -2.5, 0.6, -0.5 }, { -1.5, 1.6, 0.5 });
	corners(self.positions[24:8], { 1.5, -0.5, -0.5 }, { 2.5, 0.5, 0.5 });
	for (usz box = 0; box < 4; box++)
	{
		foreach (usz i, corner : BOX_FACES) self.indices[box * 36 + i] = corner + (uint)(box * 8);
		for (usz vertex = 0; vertex < 8; vertex++)
		{
			self.joints[box * 8 + vertex] = (ushort)box;
			self.weights[box * 8 + vertex] = 1.0f;
		}
	}
	self.parents = { 1, 4, 4, 2, -1 };
	self.mesh = { .positions = self.positions[..], .indices = self.indices[..] };
	self.binding = {
		.joints = self.joints[..],
		.weights = self.weights[..],
		.slots = 1,
		.vertices = 32,
	};
	self.picker = crig::build_picker(self.mesh);
	self.surface = crig::build_deformed_collision_surface(&self.picker, self.binding, 5);

	self.doc.dots.init(mem);
	self.doc.edges.init(mem);
	self.doc.collision_exclusions.init(mem);
	for (usz joint = 0; joint < 5; joint++) self.dot_ids[joint] = self.doc.add_dot({ 0, (float)joint, 0 });
	foreach (usz joint, int parent : self.parents)
	{
		if (parent >= 0) self.doc.connect(self.dot_ids[(usz)parent], self.dot_ids[joint]);
	}
	self.policy = crig::build_collision_policy(&self.surface, self.parents[..], self.dot_ids[..], CLEARANCE, &self.doc);
}

fn void ChainFixture.free(&self)
{
	self.policy.free();
	self.doc.free();
	self.surface.free();
	self.picker.free();
}

// Every raw pair the accelerator reports for `moving`, kept until `free`.
fn crig::DeformedTrianglePair[] ChainFixture.raw(&self, uint[] moving)
{
	return self.surface.broad_phase_pairs_for_joints(mem, moving, CLEARANCE);
}

fn bool pair_regions(crig::DeformedCollisionSurface* surface, crig::DeformedTrianglePair pair, uint one, uint other) @local
{
	uint a = surface.region_for_triangle(pair.a);
	uint b = surface.region_for_triangle(pair.b);
	return (a == one && b == other) || (a == other && b == one);
}

// ---------------------------------------------------------------------------
// The narrow-phase primitive

fn void triangle_distance_reads_every_feature_pair_and_zero_for_a_crossing() @test
{
	collision::TriangleVerts flat = { { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 } };

	collision::TriangleVerts lifted = { { 0, 0, 0.5f }, { 1, 0, 0.5f }, { 0, 1, 0.5f } };
	test::@check(near(crig::triangle_distance(flat, lifted), 0.5f),
		"parallel copies half a unit apart read %.4f", crig::triangle_distance(flat, lifted));

	// A vertex over the face's interior: the nearest feature is vertex–face.
	collision::TriangleVerts hovering = { { 0.2f, 0.2f, 0.3f }, { 2, 2, 1 }, { 2, -1, 1 } };
	test::@check(near(crig::triangle_distance(flat, hovering), 0.3f),
		"a vertex 0.3 over the face read %.4f", crig::triangle_distance(flat, hovering));
	test::@check(near(crig::triangle_distance(hovering, flat), 0.3f), "the distance is not symmetric");

	// An edge running level over the face: edge–edge where it crosses the rim.
	collision::TriangleVerts spanning = { { 0.5f, -1, 0.25f }, { 0.5f, 2, 0.25f }, { 0.5f, 2, 3 } };
	test::@check(near(crig::triangle_distance(flat, spanning), 0.25f),
		"an edge a quarter over the face read %.4f", crig::triangle_distance(flat, spanning));

	// An edge straight through the face, with no vertex of either near the other.
	collision::TriangleVerts piercing = { { 0.2f, 0.2f, -1 }, { 0.2f, 0.2f, 1 }, { 3, 3, 1 } };
	test::@check(crig::triangles_cross(flat, piercing), "an edge through the face was not a crossing");
	test::@check(crig::triangle_distance(flat, piercing) == 0.0f, "a crossing did not read as zero");
	test::@check(crig::triangle_distance(piercing, flat) == 0.0f, "a crossing found one way round was missed the other");

	// Coplanar: overlapping reads zero from the feature search alone, apart is apart.
	collision::TriangleVerts overlapping = { { 0.1f, 0.1f, 0 }, { 2, 0.1f, 0 }, { 0.1f, 2, 0 } };
	test::@check(!crig::triangles_cross(flat, overlapping), "coplanar overlap was reported as an edge crossing");
	test::@check(near(crig::triangle_distance(flat, overlapping), 0.0f),
		"coplanar overlap read %.6f, not zero", crig::triangle_distance(flat, overlapping));
	collision::TriangleVerts beside = { { 2, 0, 0 }, { 3, 0, 0 }, { 2, 1, 0 } };
	test::@check(near(crig::triangle_distance(flat, beside), 1.0f),
		"coplanar triangles a unit apart read %.4f", crig::triangle_distance(flat, beside));

	// Touching at a vertex is a distance of zero, however it is found.
	collision::TriangleVerts touching = { { 1, 0, 0 }, { 2, 0, 1 }, { 2, 1, 1 } };
	test::@check(crig::triangle_distance(flat, touching) == 0.0f, "a shared corner did not read as zero");
}

// ---------------------------------------------------------------------------
// The four readings

fn void the_rest_pose_yields_no_candidates_and_names_its_modelled_contacts() @test
{
	ChainFixture fixture;
	fixture.init();
	defer fixture.free();
	crig::DeformedCollisionSurface* surface = &fixture.surface;
	crig::CollisionPolicy* policy = &fixture.policy;

	test::@check(policy.ready, "the policy did not build");
	test::eq(policy.joints, (uint)5);
	test::@check(policy.rest_contacts.len > 0, "the box modelled 0.1 above A was not found as a rest contact");
	foreach (pair : policy.rest_contacts)
	{
		test::@check(pair.a < pair.b, "a rest contact is stored the wrong way round: %d, %d", pair.a, pair.b);
		test::@check(pair_regions(surface, pair, 0, 2),
			"a rest contact between regions %d and %d; only A–C touch at rest across the hub",
			surface.region_for_triangle(pair.a), surface.region_for_triangle(pair.b));
		test::@check(policy.rest_contact(pair) && policy.rest_contact({ .a = pair.b, .b = pair.a }),
			"a stored rest contact was not found, or not found reversed");
	}
	// Sorted, so the search above can be a binary one.
	for (usz i = 1; i < policy.rest_contacts.len; i++)
	{
		crig::DeformedTrianglePair before = policy.rest_contacts[i - 1];
		crig::DeformedTrianglePair after = policy.rest_contacts[i];
		test::@check(before.a < after.a || (before.a == after.a && before.b < after.b), "rest contacts are not sorted");
	}

	Matrix4f[5] palette = { matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4 };
	surface.refit_all(fixture.binding, palette[..], 1);

	// Everything A touches at rest is explained: its own faces, the box one
	// bone over, and the box modelled against it. What the policy leaves for
	// the narrow phase is the broad phase's own looseness — pairs whose boxes
	// meet while the triangles stand well apart — and every one of those is
	// beyond the clearance, so no rest pose reads as a collision.
	uint[1] moving = { 0 };
	crig::DeformedTrianglePair[] raw = fixture.raw(moving[..]);
	defer if (raw.len > 0) alloc::free(mem, raw);
	crig::CollisionPairCounts counts;
	crig::DeformedTrianglePair[] kept = policy.filter(mem, surface, raw, &counts);
	defer if (kept.len > 0) alloc::free(mem, kept);
	test::eq((usz)kept.len, counts.candidates);
	test::eq(counts.excluded_regions, (usz)0);
	test::@check(counts.shared_topology > 0, "a box's own adjacent faces were not read as shared topology");
	test::@check(counts.neighboring_regions > 0, "the box one bone over was not read as a neighboring region");
	test::@check(counts.rest_contacts > 0, "the box modelled against A was not read as a rest contact");
	test::eq(counts.total(), (usz)raw.len);
	foreach (pair : kept)
	{
		float gap = crig::triangle_distance(surface.rest_triangle(pair.a), surface.rest_triangle(pair.b));
		test::@check(gap > CLEARANCE, "candidate %d–%d is %.3f apart at rest, within the clearance", pair.a, pair.b, gap);
		test::@check(pair_regions(surface, pair, 0, 2), "a candidate at rest between regions %d and %d",
			surface.region_for_triangle(pair.a), surface.region_for_triangle(pair.b));
	}

	usz contacts;
	foreach (pair : raw)
	{
		crig::CollisionPairClass reading = policy.classify(surface, pair);
		bool shares = surface.triangles_share_vertex(pair.a, pair.b);
		test::@check(shares == (reading == SHARED_TOPOLOGY),
			"pair %d–%d shares a vertex: %s, but reads %s", pair.a, pair.b, shares, reading);
		if (pair_regions(surface, pair, 0, 1) || pair_regions(surface, pair, 0, 0))
		{
			test::@check(reading == SHARED_TOPOLOGY || reading == NEIGHBORING_REGIONS,
				"a pair within A, or between A and B, reads %s", reading);
		}
		if (!pair_regions(surface, pair, 0, 2)) continue;
		float gap = crig::triangle_distance(surface.rest_triangle(pair.a), surface.rest_triangle(pair.b));
		if (gap <= CLEARANCE) contacts++;
		test::@check((gap <= CLEARANCE) == (reading == REST_CONTACT),
			"an A–C pair %.3f apart at rest reads %s", gap, reading);
	}
	test::@check(contacts > 0 && contacts == counts.rest_contacts,
		"%d A–C pairs within clearance at rest, %d read as rest contacts", contacts, counts.rest_contacts);
}

fn void regions_neighbor_one_bone_apart_and_no_further() @test
{
	ChainFixture fixture;
	fixture.init();
	defer fixture.free();
	crig::CollisionPolicy* policy = &fixture.policy;

	test::@check(policy.regions_neighbor(0, 0), "a region is not its own neighbor");
	test::@check(policy.regions_neighbor(0, 1) && policy.regions_neighbor(1, 0), "parent and child are not neighbors");
	test::@check(policy.regions_neighbor(2, 3), "a limb's two bones are not neighbors");
	// Two apart along one line — a grandparent — is the crease a short bone
	// puts one region further out: the upper arm under a clavicle against
	// the chest, the chin on it under a neck.
	test::@check(policy.regions_neighbor(0, 4) && policy.regions_neighbor(4, 0), "grandparent and grandchild are not neighbors");
	test::@check(policy.regions_neighbor(3, 4), "the other limb's grandchild is not the hub's neighbor");
	// Two apart across a fork is not: siblings, and cousins further out, are
	// what the check exists for — two thighs under one hip.
	test::@check(!policy.regions_neighbor(1, 2) && !policy.regions_neighbor(2, 1), "siblings were read as neighbors");
	test::@check(!policy.regions_neighbor(0, 2), "a region and its parent's sibling were read as neighbors");
	test::@check(!policy.regions_neighbor(1, 3) && !policy.regions_neighbor(0, 3), "cousins were read as neighbors");
	test::@check(!policy.regions_neighbor(0, uint::max) && !policy.regions_neighbor(uint::max, uint::max),
		"an unweighted triangle's non-region neighbors something");
	test::@check(!policy.regions_neighbor(5, 0), "a region past the binding neighbors something");
}

<*
 The shared-influence reading: D blended a little onto A's joint is one
 patch with A whatever the regions say, and a tail of weight below
 `FOLD_WEIGHT` is not enough to make it one.
*>
fn void a_pair_one_joint_weights_on_both_sides_is_one_patch() @test
{
	ChainFixture fixture;
	fixture.init();
	defer fixture.free();

	// Two influences per vertex: every box its own joint, and D's corners a
	// share of A's joint 0 as well.
	float[2] shares = { 0.3f, 0.02f };
	foreach (share : shares)
	{
		ushort[64] joints;
		float[64] weights;
		for (usz vertex = 0; vertex < 32; vertex++)
		{
			joints[vertex * 2] = (ushort)(vertex / 8);
			weights[vertex * 2] = vertex >= 24 ? 1.0f - share : 1.0f;
			joints[vertex * 2 + 1] = 0;
			weights[vertex * 2 + 1] = vertex >= 24 ? share : 0.0f;
		}
		gltf::SkinBinding blended = { .joints = joints[..], .weights = weights[..], .slots = 2, .vertices = 32 };
		crig::DeformedCollisionSurface surface = crig::build_deformed_collision_surface(&fixture.picker, blended, 5);
		defer surface.free();
		crig::CollisionPolicy policy = crig::build_collision_policy(&surface, fixture.parents[..], fixture.dot_ids[..],
			CLEARANCE, &fixture.doc, {}, blended);
		defer policy.free();
		test::@check(policy.ready && policy.influence_slots == 6, "the policy did not read the binding's influences");

		// D onto A, through the share that joint 3 has of it.
		Matrix4f[5] palette = { matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4 };
		surface.refit_all(blended, palette[..], 1);
		palette[3].m[12] = -4.0f / (1.0f - share);
		uint[1] moving = { 3 };
		surface.refit_joints(moving[..], blended, palette[..], 2);
		crig::DeformedTrianglePair[] raw = surface.broad_phase_pairs_for_joints(mem, moving[..], CLEARANCE);
		defer if (raw.len > 0) alloc::free(mem, raw);
		crig::CollisionPairCounts counts;
		crig::DeformedTrianglePair[] kept = policy.filter(mem, &surface, raw, &counts);
		defer if (kept.len > 0) alloc::free(mem, kept);

		usz onto_a;
		usz beside_b;
		foreach (pair : raw)
		{
			bool with_a = pair_regions(&surface, pair, 0, 3);
			if (with_a) onto_a++;
			if (pair_regions(&surface, pair, 1, 3)) beside_b++;
			crig::CollisionPairClass reading = policy.classify(&surface, pair);
			if (with_a && share >= crig::FOLD_WEIGHT)
			{
				test::@check(reading == SHARED_INFLUENCE, "D blended %.2f onto A's joint reads %s against A", share, reading);
			}
			else if (with_a)
			{
				test::@check(reading == CANDIDATE, "a %.2f tail of A's joint on D reads %s against A", share, reading);
			}
			else if (pair_regions(&surface, pair, 1, 3))
			{
				test::@check(reading == CANDIDATE, "D against B, which shares no joint with it, reads %s", reading);
			}
		}
		test::@check(onto_a > 0 && beside_b > 0, "%d raw pairs onto A and %d beside B; wanted both", onto_a, beside_b);
		if (share >= crig::FOLD_WEIGHT)
		{
			test::eq(counts.shared_influence, onto_a);
			test::eq(counts.candidates, beside_b);
		}
		else
		{
			test::eq(counts.shared_influence, (usz)0);
			test::eq(counts.candidates, onto_a + beside_b);
		}
		test::eq(counts.total(), (usz)raw.len);
	}

	// Built without a binding, the reading never fires.
	test::eq(fixture.policy.influence_slots, (usz)0);
	test::@check(!fixture.policy.shares_influence({ .a = 0, .b = 1 }), "a policy with no binding read a pair as one patch");
}

fn void a_moved_region_meeting_a_distant_one_is_a_candidate_until_excluded() @test
{
	ChainFixture fixture;
	fixture.init();
	defer fixture.free();
	crig::DeformedCollisionSurface* surface = &fixture.surface;
	crig::CollisionPolicy* policy = &fixture.policy;

	// D lands exactly on A: four bones from it across the hub, never near it
	// at rest. There it is within clearance of B (three bones off) and, on
	// the way, of C (its parent).
	Matrix4f[5] palette = { matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4 };
	surface.refit_all(fixture.binding, palette[..], 1);
	palette[3].m[12] = -4.0f;
	uint[1] moving = { 3 };
	surface.refit_joints(moving[..], fixture.binding, palette[..], 2);

	crig::DeformedTrianglePair[] raw = fixture.raw(moving[..]);
	defer if (raw.len > 0) alloc::free(mem, raw);
	crig::CollisionPairCounts counts;
	crig::DeformedTrianglePair[] kept = policy.filter(mem, surface, raw, &counts);
	defer if (kept.len > 0) alloc::free(mem, kept);

	test::@check(kept.len > 0, "a box moved onto a distant one produced no candidate");
	test::eq((usz)kept.len, counts.candidates);
	test::@check(counts.neighboring_regions > 0, "D against its parent C was not read as neighboring");
	test::eq(counts.rest_contacts, (usz)0);
	test::eq(counts.excluded_regions, (usz)0);
	usz onto_a;
	usz beside_b;
	foreach (pair : kept)
	{
		if (pair_regions(surface, pair, 0, 3)) onto_a++;
		if (pair_regions(surface, pair, 1, 3)) beside_b++;
		test::@check(pair_regions(surface, pair, 0, 3) || pair_regions(surface, pair, 1, 3),
			"a candidate between regions %d and %d", surface.region_for_triangle(pair.a), surface.region_for_triangle(pair.b));
	}
	test::@check(onto_a > 0 && beside_b > 0, "%d candidates onto A and %d beside B; wanted both", onto_a, beside_b);

	// The authored escape hatch: A and D are told to ignore each other, and
	// only they are.
	test::@check(fixture.doc.add_exclusion(fixture.dot_ids[0], fixture.dot_ids[3]), "the exclusion was refused");
	policy.adopt_exclusions(&fixture.doc);
	test::@check(policy.regions_excluded(0, 3) && policy.regions_excluded(3, 0), "the exclusion did not reach the table both ways");
	test::@check(!policy.regions_excluded(1, 3), "an exclusion spilled onto another pair");

	crig::CollisionPairCounts after;
	crig::DeformedTrianglePair[] remaining = policy.filter(mem, surface, raw, &after);
	defer if (remaining.len > 0) alloc::free(mem, remaining);
	test::eq(after.excluded_regions, onto_a);
	test::eq(after.candidates, beside_b);
	test::eq((usz)remaining.len, beside_b);
	foreach (pair : remaining)
	{
		test::@check(pair_regions(surface, pair, 1, 3), "an excluded A–D pair survived the filter");
	}
	// The rest table is untouched by an exclusion edit: the cheap rebuild is
	// the whole of what one costs.
	test::@check(policy.rest_contacts.len > 0, "adopting an exclusion lost the rest contacts");

	// Given the policy's table, the accelerator leaves the neighboring and
	// the excluded pairs out itself — D against its parent C, D against A —
	// and hands the filter exactly the D–B candidates it would have kept.
	test::eq((usz)policy.may_meet().len, (usz)25);
	test::@check(!policy.may_meet()[3 * 5 + 2] && !policy.may_meet()[0 * 5 + 3] && policy.may_meet()[1 * 5 + 3],
		"the table does not say what the readings say");
	crig::DeformedTrianglePair[] pruned = surface.broad_phase_pairs_for_joints(mem, moving[..], CLEARANCE, {}, {}, policy.may_meet());
	defer if (pruned.len > 0) alloc::free(mem, pruned);
	crig::CollisionPairCounts through;
	crig::DeformedTrianglePair[] still = policy.filter(mem, surface, pruned, &through);
	defer if (still.len > 0) alloc::free(mem, still);
	test::@check(pruned.len < raw.len, "the table pruned nothing: %d pairs either way", raw.len);
	test::eq(through.neighboring_regions, (usz)0);
	test::eq(through.excluded_regions, (usz)0);
	test::eq(through.candidates, beside_b);
	test::eq((usz)still.len, beside_b);
	// A table for some other rig is not read.
	bool[4] wrong_size;
	crig::DeformedTrianglePair[] unpruned = surface.broad_phase_pairs_for_joints(mem, moving[..], CLEARANCE, {}, {}, wrong_size[..]);
	defer if (unpruned.len > 0) alloc::free(mem, unpruned);
	test::eq((usz)unpruned.len, (usz)raw.len);

	// Taking it back puts the pairs back under the check.
	test::@check(fixture.doc.remove_exclusion(fixture.dot_ids[3], fixture.dot_ids[0]), "the exclusion could not be removed reversed");
	policy.adopt_exclusions(&fixture.doc);
	test::@check(!policy.regions_excluded(0, 3), "a removed exclusion is still in the table");

	// One naming a dot that is not in the binding is kept by the document and
	// ignored by the policy, not refused.
	uint stray = fixture.doc.add_dot({ 9, 9, 9 });
	test::@check(fixture.doc.add_exclusion(stray, fixture.dot_ids[0]), "an exclusion on an unbound dot was refused");
	policy.adopt_exclusions(&fixture.doc);
	for (uint joint = 0; joint < 4; joint++)
	{
		test::@check(!policy.regions_excluded(0, joint), "an exclusion on an unbound dot excluded region %d", joint);
	}
}

<*
 A box whose every face carries its own four corners, the way an exporter
 splits a vertex along a normal seam, with alternate faces on joints two
 bones apart. On the index buffer no two faces share a vertex, so every
 crease between regions 0 and 2 is a contact at distance zero; with the
 mesh's welds it is the one surface it models.
*>
fn void a_split_seam_reads_as_shared_topology_given_the_welds() @test
{
	Vec3[8] shared;
	corners(shared[..], { -0.5, -0.5, -0.5 }, { 0.5, 0.5, 0.5 });
	Vec3[24] positions;
	uint[36] indices;
	ushort[24] joints;
	float[24] weights;
	for (usz face = 0; face < 6; face++)
	{
		// The face's two triangles name four unique corners of the shared box.
		uint[6] quad = BOX_FACES[face * 6 : 6];
		uint[4] used;
		usz unique;
		foreach (corner : quad)
		{
			bool seen;
			for (usz i = 0; i < unique; i++) if (used[i] == corner) seen = true;
			if (!seen) used[unique++] = corner;
		}
		for (usz i = 0; i < 4; i++)
		{
			positions[face * 4 + i] = shared[used[i]];
			joints[face * 4 + i] = face % 2 == 0 ? 0 : 2;
			weights[face * 4 + i] = 1.0f;
		}
		foreach (usz k, corner : quad)
		{
			usz local = 0;
			for (usz i = 0; i < 4; i++) if (used[i] == corner) local = i;
			indices[face * 6 + k] = (uint)(face * 4 + local);
		}
	}
	rig::TriMesh mesh = { .positions = positions[..], .indices = indices[..] };
	gltf::SkinBinding binding = { .joints = joints[..], .weights = weights[..], .slots = 1, .vertices = 24 };
	crig::Picker picker = crig::build_picker(mesh);
	defer picker.free();
	crig::DeformedCollisionSurface surface = crig::build_deformed_collision_surface(&picker, binding, 3);
	defer surface.free();
	int[3] parents = { 1, -1, 1 };
	uint[3] dot_ids = { 1, 2, 3 };

	// Two faces meeting at an edge, on the two non-neighboring regions — joints
	// 0 and 2 are siblings under 1: the first triangle of face 0 (joint 0)
	// and the first of face 3 (joint 2).
	crig::DeformedTrianglePair crease = { .a = 0, .b = 6 };
	test::@check(surface.region_for_triangle(0) == 0 && surface.region_for_triangle(6) == 2,
		"the faces did not land on the regions the check wants: %d and %d",
		surface.region_for_triangle(0), surface.region_for_triangle(6));
	test::@check(!surface.triangles_share_vertex(0, 6), "the split faces share an index after all");
	test::@check(near(crig::triangle_distance(surface.rest_triangle(0), surface.rest_triangle(6)), 0.0f),
		"the crease is not at distance zero");

	crig::CollisionPolicy by_index = crig::build_collision_policy(&surface, parents[..], dot_ids[..], CLEARANCE);
	defer by_index.free();
	test::@check(by_index.rest_contacts.len > 0, "without welds the creases were not stored as rest contacts");
	test::@check(by_index.classify(&surface, crease) == REST_CONTACT,
		"without welds the crease reads %s", by_index.classify(&surface, crease));

	rig::MeshAdjacency welded = rig::build_adjacency(mem, mesh);
	defer welded.free(mem);
	test::eq(welded.classes(), (usz)8);
	crig::CollisionPolicy by_weld = crig::build_collision_policy(
		&surface, parents[..], dot_ids[..], CLEARANCE, welds: welded.class_of);
	defer by_weld.free();
	test::eq((usz)by_weld.rest_contacts.len, (usz)0);
	test::@check(by_weld.classify(&surface, crease) == SHARED_TOPOLOGY,
		"with welds the crease reads %s", by_weld.classify(&surface, crease));
	// Opposite faces share no corner under either reading.
	crig::DeformedTrianglePair opposite = { .a = 0, .b = 2 };
	test::@check(!by_weld.shares_topology(&surface, opposite), "welding joined opposite faces");

	// A weld table that does not cover the mesh is ignored rather than trusted.
	uint[4] short_welds = { 0, 0, 0, 0 };
	crig::CollisionPolicy unfit = crig::build_collision_policy(
		&surface, parents[..], dot_ids[..], CLEARANCE, welds: short_welds[..]);
	defer unfit.free();
	test::eq((usz)unfit.welds.len, (usz)0);
}

<*
 Given the binding, the broad phase leaves out pairs a move carries as one
 rigid piece: every box here is rigid to its joint, so moving everything
 yields nothing to test, and moving A alone drops A's own faces against each
 other while keeping A against the boxes that stay put.
*>
fn void the_broad_phase_drops_pairs_the_move_carries_rigidly_when_given_the_binding() @test
{
	ChainFixture fixture;
	fixture.init();
	defer fixture.free();
	crig::DeformedCollisionSurface* surface = &fixture.surface;
	Matrix4f[5] palette = { matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4 };
	surface.refit_all(fixture.binding, palette[..], 1);

	uint[4] all = { 0, 1, 2, 3 };
	crig::DeformedTrianglePair[] every = surface.broad_phase_pairs_for_joints(mem, all[..], CLEARANCE);
	defer if (every.len > 0) alloc::free(mem, every);
	test::@check(every.len > 0, "the raw broad phase found nothing at all");
	crig::DeformedTrianglePair[] none = surface.broad_phase_pairs_for_joints(mem, all[..], CLEARANCE, fixture.binding);
	defer if (none.len > 0) alloc::free(mem, none);
	test::eq((usz)none.len, (usz)0);

	uint[1] only_a = { 0 };
	crig::DeformedTrianglePair[] raw = surface.broad_phase_pairs_for_joints(mem, only_a[..], CLEARANCE);
	defer if (raw.len > 0) alloc::free(mem, raw);
	crig::DeformedTrianglePair[] carried = surface.broad_phase_pairs_for_joints(mem, only_a[..], CLEARANCE, fixture.binding);
	defer if (carried.len > 0) alloc::free(mem, carried);
	usz within_a;
	usz against_others;
	foreach (pair : raw)
	{
		if (pair_regions(surface, pair, 0, 0)) { within_a++; } else { against_others++; }
	}
	test::@check(within_a > 0 && against_others > 0, "the raw query lacks one of the two kinds: %d within A, %d against others", within_a, against_others);
	test::eq((usz)carried.len, against_others);
	foreach (pair : carried)
	{
		test::@check(!pair_regions(surface, pair, 0, 0), "a pair within A survived with the binding given");
	}

	// A binding for some other mesh is not trusted: every pair comes back.
	gltf::SkinBinding stranger = { .joints = fixture.binding.joints[:8], .weights = fixture.binding.weights[:8], .slots = 1, .vertices = 8 };
	crig::DeformedTrianglePair[] again = surface.broad_phase_pairs_for_joints(mem, only_a[..], CLEARANCE, stranger);
	defer if (again.len > 0) alloc::free(mem, again);
	test::eq((usz)again.len, (usz)raw.len);
}

// ---------------------------------------------------------------------------
// The document, the session and the history

fn void exclusions_are_unordered_pairs_the_document_validates() @test
{
	crig::RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.collision_exclusions.init(mem);
	defer doc.free();
	uint a = doc.add_dot({ 0, 0, 0 }, "a");
	uint b = doc.add_dot({ 0, 1, 0 }, "b");
	uint c = doc.add_dot({ 0, 2, 0 }, "c");

	test::@check(!doc.add_exclusion(a, a), "a dot was excluded against itself");
	test::@check(!doc.add_exclusion(a, 0) && !doc.add_exclusion(0, a), "the null id was accepted");
	test::@check(!doc.add_exclusion(a, 99), "a missing dot was accepted");
	test::@check(doc.add_exclusion(a, b), "a valid pair was refused");
	test::@check(!doc.add_exclusion(b, a), "the same pair reversed was added twice");
	test::@check(doc.has_exclusion(a, b) && doc.has_exclusion(b, a), "the pair is not found both ways round");
	test::@check(!doc.has_exclusion(a, c), "an unrelated pair was found");
	test::eq(doc.collision_exclusions.len(), (sz)1);

	// A deleted dot's exclusion waits for undo rather than going with the dot,
	// unlike an edge; the session writer is where it is dropped.
	doc.remove_dot(b);
	test::eq(doc.collision_exclusions.len(), (sz)1);
	test::@check(!doc.add_exclusion(a, b), "an exclusion naming a deleted dot was accepted");
	test::@check(doc.remove_exclusion(b, a), "the waiting entry could not be removed reversed");
	test::@check(!doc.remove_exclusion(a, b), "removing an absent pair reported a change");
}

fn void exclusions_round_trip_through_the_session_and_stale_ones_are_dropped() @test
{
	crig::RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.collision_exclusions.init(mem);
	defer doc.free();
	uint a = doc.add_dot({ 0, 0, 0 }, "a");
	uint b = doc.add_dot({ 0, 1, 0 }, "b");
	uint c = doc.add_dot({ 0, 2, 0 }, "c");
	doc.connect(a, b);
	doc.connect(b, c);
	test::@check(doc.add_exclusion(a, c) && doc.add_exclusion(b, c), "the source exclusions were refused");
	doc.remove_dot(b);

	String text = crig::session_text(mem, &doc, "excluded.glb");
	defer text.free(mem);
	test::@check(text.contains(`"version": 23`) && text.contains(`"collision_exclusions"`),
		"the session did not identify or write the new data");

	crig::RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session carrying exclusions did not parse");
		return;
	}
	crig::RigDocument back = parsed;
	defer back.free();
	test::eq(back.collision_exclusions.len(), (sz)1);
	test::@check(back.has_exclusion(c, a), "the live exclusion did not come back");
	test::@check(!back.has_exclusion(b, c), "an exclusion on a deleted dot was written out");

	// Nothing to say: the key is absent rather than an empty list.
	crig::RigDocument plain;
	plain.dots.init(mem);
	plain.edges.init(mem);
	plain.collision_exclusions.init(mem);
	defer plain.free();
	plain.add_dot({ 0, 0, 0 });
	String bare = crig::session_text(mem, &plain, "plain.glb");
	defer bare.free(mem);
	test::@check(!bare.contains(`collision_exclusions`), "an unexcluded rig wrote the key anyway");

	// Older sessions have none and open as before.
	String older = `{"version":13,"dots":[{"id":1,"position":[0,0,0]}],"edges":[]}`;
	crig::RigDocument? legacy = crig::parse_session(mem, older);
	if (catch legacy)
	{
		test::@check(false, "a session from before exclusions no longer opens");
		return;
	}
	crig::RigDocument old = legacy;
	defer old.free();
	test::eq(old.collision_exclusions.len(), (sz)0);
}

fn void malformed_exclusion_sessions_are_refused() @test
{
	String[3] bad = {
		// Naming a dot that is not there.
		`{"version":14,"dots":[{"id":1,"position":[0,0,0]},{"id":2,"position":[0,1,0]}],"edges":[],"collision_exclusions":[[1,3]]}`,
		// One dot against itself.
		`{"version":14,"dots":[{"id":1,"position":[0,0,0]},{"id":2,"position":[0,1,0]}],"edges":[],"collision_exclusions":[[2,2]]}`,
		// The same pair twice, once reversed.
		`{"version":14,"dots":[{"id":1,"position":[0,0,0]},{"id":2,"position":[0,1,0]}],"edges":[],"collision_exclusions":[[1,2],[2,1]]}`,
	};
	foreach (usz i, text : bad)
	{
		crig::RigDocument? parsed = crig::parse_session(mem, text);
		if (try crig::RigDocument accepted = parsed)
		{
			accepted.free();
			test::@check(false, "malformed exclusion session %d was accepted", i);
		}
	}
	String shapeless = `{"version":14,"dots":[{"id":1,"position":[0,0,0]}],"edges":[],"collision_exclusions":[[1]]}`;
	crig::RigDocument? parsed = crig::parse_session(mem, shapeless);
	if (try crig::RigDocument accepted = parsed)
	{
		accepted.free();
		test::@check(false, "a one-element exclusion pair was accepted");
	}
}

fn void an_exclusion_edit_is_one_undo_step_and_reaches_the_live_policy() @test
{
	crig::AppState app = shared_app::open();
	defer app.free();
	test::@check(app.apply_plan_named("biped"), "could not fit the rig");
	app.undo_stack.clear();

	// Off, a rebind builds no policy at all; on, it builds one with the skin.
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	test::@check(app.rebind_skin(&view), "the cube would not bind");
	test::@check(!app.collision_policy.ready, "a policy was built with the system switched off");
	app.set_self_collision(true);
	test::@check(app.collision_policy.ready, "switching the system on did not build a collision policy");
	app.skin_stale = true;
	test::@check(app.rebind_skin(&view), "the cube would not bind again");
	test::@check(app.collision_policy.ready, "binding the skin did not build a collision policy");
	test::eq(app.collision_policy.joints, (uint)view.len());
	test::@check(app.collision_policy.clearance > 0.0f
		&& near(app.collision_policy.clearance, app.picker.scale * crig::COLLISION_CLEARANCE),
		"the clearance is not scaled from the mesh");

	uint first = view.dot_ids[0];
	uint second = view.dot_ids[view.len() - 1];
	usz first_joint = app.collision_policy.joint_of(first);
	usz second_joint = app.collision_policy.joint_of(second);
	test::@check(first_joint == 0 && second_joint == view.len() - 1, "the policy's dot order is not the binding's");

	sz history = app.undo_stack.cursor;
	test::@check(app.set_collision_exclusion(first, second, true), "the exclusion was refused");
	test::eq(app.undo_stack.cursor, history + 1);
	test::@check(app.doc.has_exclusion(second, first), "the document did not take the exclusion");
	test::@check(app.collision_policy.regions_excluded((uint)first_joint, (uint)second_joint),
		"the live policy did not adopt the exclusion without a rebind");
	test::@check(!app.skin_stale, "an exclusion edit marked the rig stale, which rebinds the whole skin for nothing");
	test::@check(!app.set_collision_exclusion(second, first, true), "excluding the same pair again reported a change");
	test::eq(app.undo_stack.cursor, history + 1);

	// History steps rebind, and the rebuilt policy reads the document.
	test::@check(app.undo(), "the exclusion would not undo");
	test::@check(!app.doc.has_exclusion(first, second), "undo left the exclusion in the document");
	test::@check(app.rebind_skin(&view) && !app.collision_policy.regions_excluded((uint)first_joint, (uint)second_joint),
		"the policy rebuilt after undo still excludes the pair");
	test::@check(app.redo(), "the exclusion would not redo");
	test::@check(app.rebind_skin(&view) && app.collision_policy.regions_excluded((uint)first_joint, (uint)second_joint),
		"the policy rebuilt after redo lost the pair");

	// The candidate door answers, and answers empty, for a rig that has not
	// been asked to refit anything yet.
	crig::CollisionPairCounts counts = { .candidates = 7 };
	uint[1] moving = { 0 };
	crig::DeformedTrianglePair[] none = app.collision_candidates(mem, moving[..], &counts);
	test::eq((usz)none.len, (usz)0);
	test::eq(counts.total(), (usz)0);
}

<*
 The preset fit (M2), offline.

     `c3c test --trust=full --test-filter crig_tests::preset`

 Two halves, and they check different things. The **shape** of a fit is checked
 against boxes built in code — that a body plan comes out as a connected tree
 with its parents before its children, that mirrored dots land as reflections of
 each other, that nothing escapes the mesh's bounds. Those are claims about the
 expansion and the mapping, and a real animal would only make them harder to
 read.

 The **facing** is the half that cannot be checked that way, because it is a
 measurement rather than a calculation: the preset is placed both ways round and
 the cheaper fit wins. So it is checked on a fixture built to have an answer —
 a body with a thin bar sticking out one end, which is the only feature of a
 quadruped that is not roughly front-to-back symmetric.

 The last check runs all three plans over a real model from the repo. Which way
 that fit comes out and how many dots the grid had to rescue are properties of
 the model, so what is asserted there is only what holds for any of them.

 No GPU and no window.
*>
module crig_tests::preset;

import crig;
import make_anims;
import rig;
import collision;
import std::core::test;
import std::io;
import std::time;
import std::math;
import std::math::vector;
import std::collections::list;



// The body plans crig's own packs are generated from — tools/body_plans.c3.
//
// They are not runtime data any more: the app reads a plan out of whichever
// pack the user picked. They are still the right fixture for `fit_preset`,
// which is what this file is about, because they are the shape a real plan has.
fn crig::Preset quadruped() => { .name = "Quadruped", .dots = make_anims::quadruped_dots[..] };
fn crig::Preset biped() => { .name = "Biped", .dots = make_anims::biped_dots[..] };
fn crig::Preset bird() => { .name = "Bird", .dots = make_anims::bird_dots[..] };

alias Vec3List = List{Vec3};
alias UintList = List{uint};

// ---------------------------------------------------------------------------
// Fixtures. A box is closed with eight vertices and twelve triangles, which is
// all the parity voxelizer needs — subdivision buys nothing when every face is
// flat.

fn void push_box(Vec3List* positions, UintList* indices, Vec3 low, Vec3 high)
{
	uint first = (uint)positions.len();

	positions.push({ low.x, low.y, low.z });
	positions.push({ high.x, low.y, low.z });
	positions.push({ high.x, high.y, low.z });
	positions.push({ low.x, high.y, low.z });
	positions.push({ low.x, low.y, high.z });
	positions.push({ high.x, low.y, high.z });
	positions.push({ high.x, high.y, high.z });
	positions.push({ low.x, high.y, high.z });

	uint[36] faces = {
		0, 2, 1, 0, 3, 2,   // -Z
		4, 5, 6, 4, 6, 7,   // +Z
		0, 1, 5, 0, 5, 4,   // -Y
		3, 7, 6, 3, 6, 2,   // +Y
		0, 4, 7, 0, 7, 3,   // -X
		1, 2, 6, 1, 6, 5,   // +X
	};
	foreach (face : faces) indices.push(first + face);
}

<*
 A body, with an optional thin bar out one end.

 The bar is the tail: the one part of a quadruped that is neither symmetric
 front-to-back nor thick enough to be found by accident, which makes it the
 whole signal the facing test has to work with.

 @param tail_sign : `0 for a bare body, +1 for a bar at high Z, -1 at low Z.`
*>
fn rig::TriMesh body_mesh(Allocator allocator, float tail_sign = 0.0f)
{
	Vec3List positions;
	UintList indices;
	positions.init(allocator);
	indices.init(allocator);

	// `to_array` copies, so the builders are scratch and have to go back — the
	// mesh handed out below does not point into them.
	defer
	{
		positions.free();
		indices.free();
	}

	push_box(&positions, &indices, { -0.30, -0.50, -0.60 }, { 0.30, 0.50, 0.60 });

	if (tail_sign != 0.0f)
	{
		float near = tail_sign > 0.0f ? 0.55f : -0.95f;
		float far = tail_sign > 0.0f ? 0.95f : -0.55f;
		push_box(&positions, &indices, { -0.05, -0.10, near }, { 0.05, 0.10, far });
	}

	return { .positions = positions.to_array(allocator), .indices = indices.to_array(allocator) };
}

<*
 A body in two pieces, with a gap down the middle wider than a dot may reach.

 Whatever the preset puts between them has nowhere to go, which is the one way
 a fitted dot is allowed to stay where the table put it.
*>
fn rig::TriMesh split_mesh(Allocator allocator)
{
	Vec3List positions;
	UintList indices;
	positions.init(allocator);
	indices.init(allocator);

	// `to_array` copies, so the builders are scratch and have to go back — the
	// mesh handed out below does not point into them.
	defer
	{
		positions.free();
		indices.free();
	}

	// The gap has to beat PRESET_REACH, which is quoted in cells: two units of
	// bounds across 48 cells makes a cell 0.042, so eight of them reach 0.33 and
	// a 1.3-wide hole leaves the dots in the middle of it with nowhere to go.
	push_box(&positions, &indices, { -0.30, -0.50, -1.00 }, { 0.30, 0.50, -0.65 });
	push_box(&positions, &indices, { -0.30, -0.50, 0.65 }, { 0.30, 0.50, 1.00 });

	return { .positions = positions.to_array(allocator), .indices = indices.to_array(allocator) };
}

// ---------------------------------------------------------------------------

<*
 What a fitted preset looks like, as numbers a check can be written against.
*>
struct FitReport
{
	usz dots;
	usz bones;
	usz stranded;
	usz outside_bounds;
	bool reversed;
	bool ordered;    // every parent comes before its child
	bool one_root;   // exactly one dot has no parent
	bool connected;  // following parents from every dot reaches that root
}

fn FitReport measure(crig::Preset preset, rig::TriMesh geometry, rig::MeshVoxels* voxels)
{
	rig::Bounds box = geometry.bounds();

	bool reversed = false;
	crig::FittedDot[] fitted = crig::fit_preset(mem, preset, box, voxels, &reversed);
	defer crig::free_fitted(mem, fitted);

	FitReport report = { .dots = fitted.len, .reversed = reversed, .ordered = true, .connected = true };
	usz roots = 0;

	// A little slack on the bounds: a dot is snapped to a cell *centre*, and the
	// outermost cell centre inside a body sits half a cell in from its surface,
	// so this can only fail outward — which is the direction that would mean the
	// mapping is wrong rather than merely quantized.
	Vec3 slack = box.extent() * 0.001f;

	foreach (usz i, dot : fitted)
	{
		if (dot.parent >= 0) { report.bones++; } else { roots++; }
		if (!dot.landed) report.stranded++;
		if (dot.parent >= (int)i) report.ordered = false;

		for (usz axis = 0; axis < 3; axis++)
		{
			if (dot.position[axis] < box.min[axis] - slack[axis] ||
				dot.position[axis] > box.max[axis] + slack[axis]) report.outside_bounds++;
		}

		// Walk to the root, with the step count as the cycle guard: `ordered`
		// already rules one out, but this check has to hold up on its own.
		int at = (int)i;
		usz steps = 0;
		while (at >= 0 && steps <= fitted.len)
		{
			at = fitted[(usz)at].parent;
			steps++;
		}
		if (at != -1) report.connected = false;
	}

	report.one_root = roots == 1;
	return report;
}

// ---------------------------------------------------------------------------
// A pack's own skeleton, read as a body plan
// ---------------------------------------------------------------------------

<*
 A body from -2..2 across, 0..8 up, -1..1 along, with joints at a quarter, a
 half and three quarters of it.

 The numbers are worked out here rather than compared against whatever the code
 produced: joints at known fractions of a known box have known answers, and a
 derivation that returned *something* for each of them would pass a check that
 only counted.

 What the fixture is built to catch is the normalization reading the wrong box.
 The joints span a fraction of the body on every axis, and they span a
 *different* fraction on each — so a derivation measuring against the skeleton's
 own extent would put the outermost joints at 0 and 1 on all three, and one that
 mixed up two axes would still be wrong.

 The pack borrows the arrays passed in, so they have to outlive it.
*>
fn crig::AnimPack fixture_pack(Vec3[2]* corners, uint[3]* face, Vec3[3]* joints, int[3]* parents, String[3]* names)
{
	*corners = { { -2, 0, -1 }, { 2, 8, 1 } };
	*face = { 0, 1, 0 };
	*joints = { { -1, 2, -0.5 }, { 0, 4, 0 }, { 1, 6, 0.5 } };
	*parents = { -1, 0, 1 };
	*names = { "root", "middle", "tip" };

	crig::AnimPack pack = {
		.name = "Fixture",
		.plan = "fixture",
		.mesh = { .positions = (*corners)[..], .indices = (*face)[..] },
	};
	pack.rest = { .joints = (*joints)[..], .parents = (*parents)[..] };
	pack.joint_names = (*names)[..];
	return pack;
}

// A pack carrying both a plan tag and a body is one; a pack carrying only clips
// is not, which is what keeps `plan_pack` from answering with the wrong file.
fn void a_pack_with_a_plan_and_a_body_can_be_one() @test
{
	Vec3[2] corners;
	uint[3] face;
	Vec3[3] joints;
	int[3] parents;
	String[3] names;
	crig::AnimPack pack = fixture_pack(&corners, &face, &joints, &parents, &names);

	test::@check(pack.is_body_plan(), "a pack with a plan tag and a body is not read as one");
}

// Each dot is its joint's fraction of the body's box, per axis — carrying the
// joint's own name and its parent, which the file already had in order.
fn void a_derived_dot_is_its_joints_fraction_of_the_box() @test
{
	Vec3[2] corners;
	uint[3] face;
	Vec3[3] joints;
	int[3] parents;
	String[3] names;
	crig::AnimPack pack = fixture_pack(&corners, &face, &joints, &parents, &names);

	Preset plan = pack.preset(mem);
	defer crig::free_preset(mem, plan);

	test::@check(plan.dots.len == 3, "%d dots came back for three joints", plan.dots.len);
	if (plan.dots.len != 3) return;

	float[3] across = { 0.25, 0.5, 0.75 };
	float[3] up = { 0.25, 0.5, 0.75 };
	float[3] along = { 0.25, 0.5, 0.75 };

	foreach (usz i, dot : plan.dots)
	{
		test::@check(math::abs(dot.at.x - across[i]) <= 1.0e-6f,
			"dot %d sits at %.6f across, not %.6f", i, dot.at.x, across[i]);
		test::@check(math::abs(dot.at.y - up[i]) <= 1.0e-6f,
			"dot %d sits at %.6f up, not %.6f", i, dot.at.y, up[i]);
		test::@check(math::abs(dot.at.z - along[i]) <= 1.0e-6f,
			"dot %d sits at %.6f along, not %.6f", i, dot.at.z, along[i]);
		test::@check(dot.name == names[i], "dot %d is called %s, not %s", i, dot.name, names[i]);
		test::@check(dot.parent == parents[i], "dot %d hangs off %d, not %d", i, dot.parent, parents[i]);
	}
}

<*
 A derived plan never mirrors.

 `_L` and `_R` are separate joints in a pack already, so the expansion that
 turns one table row into two would run over names that have been through it
 once — and `wrist_L_L` is a joint no clip will ever name.
*>
fn void a_derived_plan_never_mirrors() @test
{
	Vec3[2] corners = { { -1, 0, -1 }, { 1, 2, 1 } };
	uint[3] face = { 0, 1, 0 };
	Vec3[3] joints = { { 0, 1, 0 }, { -0.5, 1, 0 }, { 0.5, 1, 0 } };
	int[3] parents = { -1, 0, 0 };
	String[3] names = { "spine", "wrist_L", "wrist_R" };

	crig::AnimPack pack = {
		.name = "Sided",
		.plan = "sided",
		.mesh = { .positions = corners[..], .indices = face[..] },
	};
	pack.rest = { .joints = joints[..], .parents = parents[..] };
	pack.joint_names = names[..];

	Preset plan = pack.preset(mem);
	defer crig::free_preset(mem, plan);

	test::@check(plan.dots.len == 3, "three sided joints expanded to %d dots", plan.dots.len);

	foreach (dot : plan.dots)
	{
		test::@check(!dot.mirror, "%s came back asking to be mirrored again", dot.name);
		test::@check(dot.name.len < 4 || dot.name[^4..] != "_L_R",
			"%s went through the _L/_R expansion twice", dot.name);
	}
}

// ---------------------------------------------------------------------------
// Reading a side out of a name
// ---------------------------------------------------------------------------

struct SideCase
{
	String name;
	String want;   // "" for a name that names no side
	String about;
}

<*
 The conventions a rig can arrive wearing, and the ones that must not be read as
 sides at all.

 This is not a formatting nicety. A rig is named after whichever body plan it
 matched, and a plan's words are its pack file's own joint names — so anything
 fitted against a downloaded Mixamo pack is spelled `mixamorig:LeftHand` and
 nothing crig writes is in it. Read only `_L`/`_R` and every joint on such a rig
 looks like a joint with no other side, which is what made Mirror lay a second
 skeleton on top of the one already there instead of squaring the two halves up.

 The refusals matter as much as the matches: a marker read out of the middle of
 a word would pair two joints that have nothing to do with each other, and a
 mirror that moves the wrong dot is worse than one that places a spare.
*>
fn void a_side_is_read_from_every_convention_a_rig_arrives_in() @test
{
	SideCase[] cases = {
		{ "thigh_L", "thigh_R", "crig's own suffix, which fit_preset writes" },
		{ "thigh_R", "thigh_L", "and back the other way" },
		{ "upperarm_l", "upperarm_r", "Unreal's lowercase suffix" },
		{ "hand.L", "hand.R", "Blender's separator" },
		{ "L_Upperarm", "R_Upperarm", "the letter on the front instead" },
		{ "Bip01_L_Finger0", "Bip01_R_Finger0", "and in the middle, which 3ds Max writes" },
		{ "leg_joint_R_1", "leg_joint_L_1", "a marker between two words, with a numbered joint after it" },
		{ "mixamorig:LeftHandThumb1", "mixamorig:RightHandThumb1", "Mixamo, camel-cased" },
		{ "mixamorig:RightToe_End", "mixamorig:LeftToe_End", "and a marker that is not at either end" },
		{ "upperarm_left", "upperarm_right", "the word spelled out, lowercase" },
		{ "LEFT_FOOT", "RIGHT_FOOT", "and shouted" },
		{ "armLeft", "armRight", "camel-cased onto a lowercase stem" },
		{ "spine", "", "a joint on the midline names no side" },
		{ "", "", "and neither does a dot with no name at all" },
		{ "Cleft", "", "a marker has to be a word, not a run of letters inside one" },
		{ "Rightful", "", "at the end of it as well as the start" },
		{ "brightness", "", "and buried in the middle" },
		{ "arm", "", "the r of a word is not a side" },
		{ "bone_L1", "", "and neither is a letter a digit carries on from" },
	};

	foreach (probe : cases)
	{
		String got = crig::mirror_name(mem, probe.name);
		defer if (got.len > 0) alloc::free(mem, got.ptr);

		test::@check(got == probe.want,
			"%s: \"%s\" mirrored to \"%s\", wanted \"%s\"", probe.about, probe.name, got, probe.want);
	}
}

<*
 And the reading is its own inverse wherever it reads anything.

 A twin is looked up by the name this returns, so a convention that mirrors one
 way and not back would find the partner from the left and lose it from the
 right — a Mirror that behaves differently depending on which half you selected.
*>
fn void mirroring_a_name_twice_gives_the_name_back() @test
{
	String[] named = {
		"thigh_L", "hand.R", "upperarm_l", "R_Upperarm", "Bip01_L_Finger0",
		"mixamorig:LeftHandThumb1", "upperarm_right", "LEFT_FOOT", "armLeft",
	};

	foreach (name : named)
	{
		String once = crig::mirror_name(mem, name);
		defer if (once.len > 0) alloc::free(mem, once.ptr);
		test::@check(once.len > 0, "%s came back with no side at all", name);
		if (once.len == 0) continue;

		String twice = crig::mirror_name(mem, once);
		defer if (twice.len > 0) alloc::free(mem, twice.ptr);

		test::@check(twice == name, "%s -> %s -> %s", name, once, twice);
	}
}

// ---------------------------------------------------------------------------
// The shape of a fit: a tree, mirrored in pairs, inside the mesh
// ---------------------------------------------------------------------------

// The quadruped expands to a connected tree of the right size, entirely inside
// the body it was fitted to.
fn void the_quadruped_expands_to_a_connected_tree() @test
{
	rig::TriMesh geometry = body_mesh(mem);
	defer geometry.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);
	test::@check(voxels.usable(), "the solid fixture has no inside");

	FitReport report = measure(quadruped(), geometry, &voxels);

	// Seven dots on the midline and six mirrored pairs.
	test::@check(report.dots == 19, "the quadruped expanded to %d dots, not 19", report.dots);
	test::@check(report.bones == 18, "%d bones for 19 dots — every dot but the root carries one", report.bones);
	test::@check(report.ordered, "a dot's parent comes after it");
	test::@check(report.one_root, "the fit came back with more or fewer than one root");
	test::@check(report.connected, "a dot is unreachable from the root");
	test::@check(report.outside_bounds == 0, "%d dots escaped the mesh's bounds", report.outside_bounds);
	test::@check(report.stranded == 0, "%d dots found no body in a solid one", report.stranded);
}

<*
 A mirrored dot is the reflection of its partner through the body's midline.

 Or the two sides drift apart and `sym_x` means something different to the
 preset than to the mirror key. Walked against the table rather than found by
 name: a twin always sits immediately after its primary, and that ordering is
 what `fit_preset` remaps the parent indices against, so it is the thing worth
 asserting.
*>
fn void mirrored_pairs_straddle_the_midline() @test
{
	rig::TriMesh geometry = body_mesh(mem);
	defer geometry.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);

	rig::Bounds box = geometry.bounds();
	crig::FittedDot[] fitted = crig::fit_preset(mem, quadruped(), box, &voxels);
	defer crig::free_fitted(mem, fitted);

	float midline = box.center().x;
	float allowed = box.extent().x * 0.02f;
	usz pairs = 0;

	usz at = 0;
	foreach (dot : make_anims::quadruped_dots)
	{
		if (!dot.mirror) { at++; continue; }
		pairs++;

		Vec3 left = fitted[at].position;
		Vec3 right = fitted[at + 1].position;
		at += 2;

		float offset = math::abs((left.x - midline) + (right.x - midline));
		float drift = math::max(math::abs(left.y - right.y), math::abs(left.z - right.z));
		test::@check(math::max(offset, drift) < allowed,
			"%s and its twin sit %.4f off the midline and %.4f apart, over the %.4f allowed",
			dot.name, offset, drift, allowed);
	}

	test::@check(pairs == 6, "%d pairs came back mirrored, not 6", pairs);
}

<*
 A limb bones to its own side, not across the body.

 Two chains down the sides, not a ladder across the middle. A mirrored dot has
 to bone to the parent on *its own* side wherever that parent has a side — get
 the remap wrong and every limb bone crosses the body, which is a rig that still
 exports and deforms nothing like an animal.
*>
fn void a_limb_bones_to_its_own_side() @test
{
	rig::TriMesh geometry = body_mesh(mem);
	defer geometry.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);

	rig::Bounds box = geometry.bounds();
	crig::FittedDot[] fitted = crig::fit_preset(mem, quadruped(), box, &voxels);
	defer crig::free_fitted(mem, fitted);

	float midline = box.center().x;

	// Dots this close to the midline have no side to be on, so a bone touching
	// one says nothing either way.
	float aside = box.extent().x * 0.05f;

	foreach (dot : fitted)
	{
		if (dot.parent < 0) continue;
		float child = dot.position.x - midline;
		float parent = fitted[(usz)dot.parent].position.x - midline;

		if (math::abs(child) < aside || math::abs(parent) < aside) continue;
		test::@check(child * parent >= 0.0f, "%s sits at %.4f across and bones to a parent at %.4f",
			dot.name, child, parent);
	}
}

<*
 With no grid the table is taken at its word.

 The fallback that lets a preset be offered for a mesh with no inside at all —
 open, flat, or a single triangle. It has to place dots rather than refuse, for
 the same reason the geodesic binder falls back to straight lines: an editor
 that declines to help on an awkward mesh is one the user cannot use on the
 mesh they actually have.
*>
fn void with_no_grid_the_table_is_taken_at_its_word() @test
{
	rig::TriMesh geometry = body_mesh(mem);
	defer geometry.free(mem);

	rig::Bounds box = geometry.bounds();
	crig::FittedDot[] fitted = crig::fit_preset(mem, quadruped(), box, null);
	defer crig::free_fitted(mem, fitted);

	test::@check(fitted.len == 19, "%d dots came back with no grid, not 19", fitted.len);

	// Every one exactly where the table put it — no snapping, and no facing test
	// either, since there is nothing to measure against.
	crig::PresetFit plain = { .box = box, .reversed = false };

	usz at = 0;
	foreach (dot : make_anims::quadruped_dots)
	{
		test::@check((fitted[at].position - plain.place(dot.at)).length() == 0.0f,
			"%s was moved off the table's own position with no grid to snap to", dot.name);
		test::@check(fitted[at].landed, "%s reports as stranded with no grid to strand it", dot.name);
		at++;

		if (!dot.mirror) continue;
		test::@check((fitted[at].position - plain.place(crig::mirror_at(dot.at))).length() == 0.0f,
			"%s's twin was moved off the table's own position", dot.name);
		test::@check(fitted[at].landed, "%s's twin reports as stranded", dot.name);
		at++;
	}
}

// A dot with nothing within reach stays put and says so — rather than being
// dropped, which would leave a hole in the chain the user cannot see.
fn void a_dot_with_nothing_in_reach_says_so() @test
{
	rig::TriMesh geometry = split_mesh(mem);
	defer geometry.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);
	test::@check(voxels.usable(), "the split fixture has no inside");

	FitReport report = measure(quadruped(), geometry, &voxels);

	test::@check(report.dots == 19, "%d dots survived the gap, not 19", report.dots);
	test::@check(report.stranded > 0, "no dot over the gap was reported as stranded");
	test::@check(report.connected, "the chain broke where a dot found nothing");
}

// ---------------------------------------------------------------------------
// Facing: which end the head goes at
// ---------------------------------------------------------------------------

// A bare box is symmetric front-to-back, so the fit ties and the table's own
// orientation stands.
fn void a_symmetric_body_keeps_the_tables_orientation() @test
{
	rig::TriMesh bare = body_mesh(mem);
	defer bare.free(mem);
	rig::MeshVoxels voxels = rig::build_voxels(mem, bare);
	defer voxels.free(mem);

	test::@check(!measure(quadruped(), bare, &voxels).reversed,
		"a symmetric body turned the preset around, so the tie is being broken by noise");
}

<*
 A tail decides which end the head goes at.

 The preset's tail dots are the ones with somewhere to be, and they should find
 the bar wherever it is: at low Z the table already agrees, and at high Z the
 whole preset has to turn around.
*>
fn void a_tail_decides_which_way_the_body_faces() @test
{
	rig::TriMesh behind = body_mesh(mem, -1.0f);
	defer behind.free(mem);
	rig::MeshVoxels behind_voxels = rig::build_voxels(mem, behind);
	defer behind_voxels.free(mem);

	test::@check(!measure(quadruped(), behind, &behind_voxels).reversed,
		"a tail at low Z moved the head away from high Z");

	rig::TriMesh ahead = body_mesh(mem, 1.0f);
	defer ahead.free(mem);
	rig::MeshVoxels ahead_voxels = rig::build_voxels(mem, ahead);
	defer ahead_voxels.free(mem);

	test::@check(measure(quadruped(), ahead, &ahead_voxels).reversed,
		"a tail at high Z left the preset facing the way the table wrote it");
}

// ---------------------------------------------------------------------------
// A real model
// ---------------------------------------------------------------------------

<*
 A real model from the repo, for the check that wants a real vertex count.

 Relative, so the run has to start from the crig directory.
*>
const String REAL_MESH = "assets/animations/humanoid.glb";

<*
 All three plans fit a real mesh without coming apart.

 Which way the fit comes out and how many dots the grid had to rescue are
 properties of the model rather than of the fit, so neither is asserted — what
 is, is that every plan still returns a connected tree of the right size with
 nothing outside the body. A plan that quietly dropped or duplicated dots on
 real input would pass every fixture check above.
*>
fn void every_plan_fits_a_real_mesh() @test
{
	rig::TriMesh? loaded = rig::load_gltf(mem, REAL_MESH);
	if (catch fault error = loaded)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", REAL_MESH, error);
		return;
	}
	rig::TriMesh geometry = loaded;
	defer geometry.free(mem);

	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);

	crig::Preset[3] presets = { quadruped(), biped(), bird() };
	foreach (preset : presets)
	{
		FitReport report = measure(preset, geometry, &voxels);

		test::@check(report.dots == expanded_size(preset), "%s expanded to %d dots on a real mesh, not %d",
			preset.name, report.dots, expanded_size(preset));
		test::@check(report.bones == report.dots - 1, "%s came back with %d bones for %d dots",
			preset.name, report.bones, report.dots);
		test::@check(report.ordered, "%s put a dot's parent after it", preset.name);
		test::@check(report.one_root, "%s came back with more or fewer than one root", preset.name);
		test::@check(report.connected, "%s left a dot unreachable from the root", preset.name);
		test::@check(report.outside_bounds == 0, "%s put %d dots outside the mesh's bounds",
			preset.name, report.outside_bounds);
	}
}

// How many dots a plan's table places: mirrored rows counting twice, optional
// rows not at all. `fit_preset` leaves the optional ones out — they are names for
// the matcher and there is nothing in a mesh that says where to put them.
fn usz expanded_size(crig::Preset preset)
{
	usz total = 0;
	foreach (dot : preset.dots)
	{
		if (dot.optional) continue;
		total += dot.mirror ? 2 : 1;
	}
	return total;
}

<*
 A fit with its fingers placed keeps every dot on a point of its own.

 A finger is thinner than a voxel, so its table position is usually outside the
 mesh and gets pulled in. Pulled onto the nearest cell's centre, a whole hand's
 worth of joints landed on the same few points and had to be picked apart one
 at a time before any of them could be dragged into place.
*>
fn void fitted_fingers_do_not_share_a_point() @test
{
	rig::TriMesh? loaded = rig::load_gltf(mem, REAL_MESH);
	if (catch fault error = loaded)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", REAL_MESH, error);
		return;
	}
	rig::TriMesh geometry = loaded;
	defer geometry.free(mem);
	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);

	rig::Bounds box = geometry.bounds();
	crig::FittedDot[] fitted = crig::fit_preset(mem, biped(), box, &voxels, place_optional: true);
	defer crig::free_fitted(mem, fitted);

	float apart = (box.max - box.min).length() * 1.0e-4f;
	usz stacked = 0;
	foreach (usz i, a : fitted)
	{
		for (usz j = i + 1; j < fitted.len; j++)
		{
			if ((a.position - fitted[j].position).length() > apart) continue;
			if (stacked++ == 0) io::printfn("%s and %s share a point", a.name, fitted[j].name);
		}
	}
	test::@check(stacked == 0, "%d pairs of fitted dots landed on the same point", stacked);
}

<*
 A fit keeps the table's spacing between the dots it snaps.

 Not sharing a point was not enough: a snap could still fold one finger onto its
 neighbour a few millimetres away, pull a tip back past its knuckle or tuck the
 pinky into the palm, and the fingers came out mixed. Every pair of dots ends at
 least half as far apart as the table has them — the table placement is the fit
 with no grid to snap to.
*>
fn void fitted_dots_keep_the_tables_spacing() @test
{
	rig::TriMesh? loaded = rig::load_gltf(mem, REAL_MESH);
	if (catch fault error = loaded)
	{
		test::@check(false, "could not load %s (%s) — run from the crig directory", REAL_MESH, error);
		return;
	}
	rig::TriMesh geometry = loaded;
	defer geometry.free(mem);
	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);

	rig::Bounds box = geometry.bounds();
	bool reversed;
	crig::FittedDot[] fitted = crig::fit_preset(mem, biped(), box, &voxels, &reversed, place_optional: true);
	defer crig::free_fitted(mem, fitted);
	test::@check(!reversed, "the humanoid faces +Z, so the table fit below lines up with this one");
	crig::FittedDot[] table = crig::fit_preset(mem, biped(), box, null, place_optional: true);
	defer crig::free_fitted(mem, table);

	usz folded = 0;
	foreach (usz i, a : fitted)
	{
		for (usz j = i + 1; j < fitted.len; j++)
		{
			float wanted = (table[i].position - table[j].position).length();
			float got = (a.position - fitted[j].position).length();
			if (got >= wanted * 0.5f) continue;
			if (folded++ == 0) io::printfn("%s and %s are %f apart, the table has %f", a.name, fitted[j].name, got, wanted);
		}
	}
	test::@check(folded == 0, "%d pairs of fitted dots were snapped together", folded);
}

// Two points outside the mesh whose nearest solid cell is the same one are
// pulled into it, not onto one spot in it.
fn void two_points_near_one_cell_stay_apart() @test
{
	rig::TriMesh geometry = body_mesh(mem);
	defer geometry.free(mem);
	rig::MeshVoxels voxels = rig::build_voxels(mem, geometry);
	defer voxels.free(mem);
	test::@check(voxels.usable(), "the body fixture has no inside");

	rig::Bounds box = geometry.bounds();
	float cell = voxels.grid.cell;
	Vec3 mid = (box.min + box.max) * 0.5f;
	Vec3 a = { mid.x, box.max.y + cell * 0.6f, mid.z };
	Vec3 b = a + (Vec3){ cell * 0.3f, 0, 0 };

	bool landed_a;
	bool landed_b;
	Vec3 in_a = crig::snapped_inside(&voxels.grid, a, &landed_a);
	Vec3 in_b = crig::snapped_inside(&voxels.grid, b, &landed_b);
	test::@check(landed_a && landed_b, "a point just above the body found nothing in reach");
	test::@check(voxels.grid.inside(in_a) && voxels.grid.inside(in_b), "a snapped point is not inside");
	test::@check((in_a - in_b).length() > cell * 0.1f, "two points a third of a cell apart snapped together");
}

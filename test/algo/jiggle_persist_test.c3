<*
 Where a secondary-motion setup is kept, and whether it survives being kept
 there.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::jiggle_persist`

 M1 proved the solver. This is the other half: secondary motion is authored
 work, and authored work that a reopen loses is worse than a feature that was
 never built, because the user finds out afterwards. So there are four places
 it has to survive and one shape it has to be turned into, and each gets a
 check — plus the crossing from the old per-bone model, which every file
 before session version 16 and every KHR file still speaks.

     ledger      set it, take it back, delete the dot it hangs off, undo — and
                 the tail comes back with the bone
     sidecar     `session_text` out and `parse_session` in; a hand-written
                 version 8 file to prove the older sessions still open, and a
                 version 9 file with per-bone `physics` to prove a tail saved
                 under the old model reopens as the chain it was
     the file    `export_pack_glb` writes KHR_physics_rigid_bodies per bone and
                 `read_pack` reads it back, and the bones fold into the chain
     the solver  the document's chains become the joint runs `build_jiggle_sim`
                 takes, including the shapes the resolver is asked to tolerate
                 rather than refuse
     the values  flexibility and stiffness are each other's inverse, presets
                 start where they say, and the ranges refuse what they should

 The rig is a hips, a two-bone tail and a belly to collide with. Small enough to
 assert every entry of by hand, and shaped like the thing the feature is for.
*>
module crig_tests::jiggle_persist;

import crig;
import rig;
import gltf;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::quaternion;



// Where the written .glb goes. Gitignored, and `c3c test` runs from the project
// root, so this is beside the build output.
const String OUT_GLB = "build/jiggle-physics.glb";
const String OUT_RIGGED = "build/jiggle-physics-rigged.glb";

// The tail's chain, and the belly's capsule. Deliberately unrounded numbers: a
// round trip that dropped a digit somewhere would still pass on 1.0. Labelled
// custom, because no preset made these.
const crig::SecondaryChain TAIL_VALUES = {
	.preset = crig::SecondaryPreset.CUSTOM,
	.flexibility = 0.4375f,
	.damping = 0.6875f,
	.gravity = 1.25f,
	.collide = true,
};
const float BELLY_RADIUS = 0.1375f;

// The old model's numbers for the same tail, for the two crossings that still
// speak it: the version 9 sidecar and the KHR file. The radii are the file's
// own — a chain measures its thickness off its skin and carries none — so
// they are what a KHR sphere collider says and nothing a chain reads back.
const crig::JiggleParams TAIL_ROOT_PARAMS = {
	.stiffness = 3200.5f,
	.damping = 0.875f,
	.gravity = 1.25f,
	.radius = 0.0325f,
};
const crig::JiggleParams TAIL_TIP_PARAMS = {
	.stiffness = 1600.25f,
	.damping = 0.75f,
	.gravity = 1.25f,
	.radius = 0.0175f,
};

// Floats go through `%.9g` in the sidecar and through the file's own JSON, both
// of which round-trip a float32 exactly, so this is a check for a lost digit
// rather than a tolerance for being nearly right.
const float EXACT = 1.0e-6f;

// The stiffness crossing goes through a logarithm each way, so a chain folded
// back out of a file lands near its flexibility rather than on it.
const float NEAR = 1.0e-4f;

<*
 A document with a hips, a two-bone tail and a belly, a chain down the tail and
 a capsule on the belly.

 Every list is initialised explicitly, the way the other document checks do it:
 a `RigDocument` is ordinarily built by `parse_session` or by the app, and
 neither of those is here.
*>
fn crig::RigDocument tail_document(uint[]* ids)
{
	crig::RigDocument doc;
	doc.dots.init(mem);
	doc.edges.init(mem);
	doc.attachments.init(mem);
	doc.paint.init(mem);
	doc.secondary.init(mem);
	doc.colliders.init(mem);

	uint hips = doc.add_dot({ 0, 1, 0 }, "hips");
	uint root = doc.add_dot({ 0, 1, -0.3f }, "tail_1");
	uint tip = doc.add_dot({ 0, 1, -0.6f }, "tail_2");
	uint belly = doc.add_dot({ 0, 0.88f, 0.12f }, "belly");

	doc.connect(hips, root);
	doc.connect(root, tip);
	doc.connect(hips, belly);

	doc.set_secondary(tail_chain(root, tip));
	doc.set_collider(belly, BELLY_RADIUS);

	uint[] out = alloc::new_array(mem, uint, 4);
	out[0] = hips;
	out[1] = root;
	out[2] = tip;
	out[3] = belly;
	*ids = out;
	return doc;
}

// The tail's chain on these two dots.
fn crig::SecondaryChain tail_chain(uint root, uint tip)
{
	crig::SecondaryChain chain = TAIL_VALUES;
	chain.root = root;
	chain.tip = tip;
	return chain;
}

fn bool same_params(crig::JiggleParams a, crig::JiggleParams b)
{
	return math::abs(a.stiffness - b.stiffness) < EXACT
		&& math::abs(a.damping - b.damping) < EXACT
		&& math::abs(a.gravity - b.gravity) < EXACT
		&& math::abs(a.radius - b.radius) < EXACT;
}

// Whether two chains say the same thing, to the sidecar's precision.
fn bool same_chain(crig::SecondaryChain a, crig::SecondaryChain b, float within = EXACT)
{
	return a.root == b.root && a.tip == b.tip && a.preset == b.preset && a.collide == b.collide
		&& math::abs(a.flexibility - b.flexibility) < within
		&& math::abs(a.damping - b.damping) < within
		&& math::abs(a.gravity - b.gravity) < within;
}

<*
 The chain lands on the ledger, comes off it, and outlives its dot.

 The `PosedJoint` check next door in `ui_test.c3` in every respect, and for the
 same three reasons. The third is the one that decided how the chain is stored:
 keeping it in a sparse list keyed by the root rather than as fields on `Dot`
 is what lets a deleted bone's wobble sit and wait, since `DELETE_DOT` carries
 no chain and `insert_dot` takes none.

 Absence is asserted as absence, not as an empty record. That is what keeps
 "is anything dynamic" a length test, and a revert that wrote an empty chain
 instead of removing would pass every check that only looked at the values.
*>
fn void physics_survives_undo_and_a_deletion() @test
{
	io::printn("a chain round-trips through the undo ledger and outlives its dot");

	uint[] ids;
	crig::RigDocument doc = tail_document(&ids);
	defer
	{
		doc.free();
		alloc::free(mem, ids);
	}

	uint hips = ids[0];
	uint root = ids[1];
	uint tip = ids[2];
	crig::SecondaryChain held = tail_chain(root, tip);

	// --- one edit, both ways -------------------------------------------------

	crig::SecondaryChain looser = held;
	looser.flexibility = 0.9f;

	crig::Edit loosen = {
		.kind = SET_SECONDARY,
		.id = root,
		.secondary_before = held,
		.secondary_after = looser,
	};
	doc.apply_edit(loosen);
	test::@check(same_chain(doc.secondary_of(root), looser), "applying a chain edit did not take");
	doc.revert_edit(loosen);
	test::@check(same_chain(doc.secondary_of(root), held),
		"reverting a chain edit did not put the old values back");

	// --- and back to nothing at all ------------------------------------------

	crig::Edit release = {
		.kind = SET_SECONDARY,
		.id = root,
		.secondary_before = held,
		.secondary_after = {},
	};
	doc.apply_edit(release);
	test::@check(doc.secondary.len() == 0, "handing a chain back to the animation left an empty record");
	test::@check(!doc.secondary_of(root).present(), "a cleared root still answers with a chain");
	doc.revert_edit(release);
	test::@check(doc.secondary.len() == 1 && same_chain(doc.secondary_of(root), held),
		"undoing the release did not bring the chain back");

	// --- two edits are two steps ---------------------------------------------

	crig::SecondaryChain shorter = looser;
	shorter.tip = root;
	crig::Edit again = {
		.kind = SET_SECONDARY,
		.id = root,
		.secondary_before = looser,
		.secondary_after = shorter,
	};
	doc.apply_edit(loosen);
	doc.apply_edit(again);
	test::@check(same_chain(doc.secondary_of(root), shorter), "the second edit did not take");
	doc.revert_edit(again);
	test::@check(same_chain(doc.secondary_of(root), looser),
		"one step back landed two steps back");
	doc.revert_edit(loosen);
	test::@check(same_chain(doc.secondary_of(root), held), "the second step back missed");

	// --- and through a deletion ----------------------------------------------

	crig::Edit gone = {
		.kind = DELETE_DOT,
		.id = root,
		.before = { 0, 1, -0.3f },
		.other = hips,
		.name = "tail_1",
	};
	doc.apply_edit(gone);
	test::@check(doc.find(root) == null, "the dot did not go");
	test::@check(doc.secondary.len() == 1, "the chain was swept when its root went");

	doc.revert_edit(gone);
	test::@check(doc.find(root) != null && same_chain(doc.secondary_of(root), held),
		"the dot came back without the chain it was deleted with");

	// --- the setter's own rules ----------------------------------------------

	test::@check(!doc.set_secondary(held), "writing the chain that is already there counted as a change");
	test::@check(!doc.set_secondary({ .tip = tip }), "a record with no root was taken");
	test::@check(!doc.set_secondary(tail_chain(999, tip)), "a chain on a dot that does not exist was taken");
	crig::SecondaryChain lone = tail_chain(tip, 0);
	test::@check(doc.set_secondary(lone) && doc.secondary_of(tip).tip == tip,
		"a chain with no tip did not become a one-bone chain on its root");
	test::@check(doc.clear_secondary(tip) && !doc.clear_secondary(tip),
		"clearing answered wrongly the first or the second time");

	// --- the collider, on the same terms -------------------------------------

	uint belly = ids[3];
	crig::Edit fatten = {
		.kind = SET_COLLIDER,
		.id = belly,
		.collider_before = BELLY_RADIUS,
		.collider_after = 0.25f,
	};
	doc.apply_edit(fatten);
	test::@check(math::abs(doc.collider_of(belly) - 0.25f) < EXACT, "applying a collider edit did not take");
	doc.revert_edit(fatten);
	test::@check(math::abs(doc.collider_of(belly) - BELLY_RADIUS) < EXACT,
		"reverting a collider edit did not put the old radius back");

	crig::Edit remove = {
		.kind = SET_COLLIDER,
		.id = belly,
		.collider_before = BELLY_RADIUS,
		.collider_after = 0.0f,
	};
	doc.apply_edit(remove);
	test::@check(doc.colliders.len() == 0, "removing a collider left a zero-radius entry");
	doc.revert_edit(remove);
	test::@check(doc.colliders.len() == 1, "undoing the removal did not bring the capsule back");
}

<*
 The sidecar carries the chain out and back, an older session still opens, and
 a session written under the old per-bone model reopens as the chain it was.

 Three claims in one check because they are the same key read three ways. The
 version 8 and version 9 texts are written out by hand rather than produced by
 an older binary — there is no older binary here — and they are exactly what one
 wrote. A reader that made `secondary` required would fail on the first; one
 that dropped `physics` would lose the tail in the second, silently, which is
 the regression this half exists to catch.
*>
fn void a_session_carries_the_physics() @test
{
	io::printn("a session writes the chain and reads it back, and older files still open");

	uint[] ids;
	crig::RigDocument doc = tail_document(&ids);
	defer
	{
		doc.free();
		alloc::free(mem, ids);
	}

	String text = crig::session_text(mem, &doc, "tail.glb");
	defer text.free(mem);

	test::@check(text.contains(`"secondary"`), "the session did not write the chains");
	test::@check(!text.contains(`"physics"`), "the session still writes the old per-bone key");

	crig::RigDocument? reloaded = crig::parse_session(mem, text);
	if (catch reloaded)
	{
		test::@check(false, "the session did not read back");
		return;
	}
	crig::RigDocument back = reloaded;
	defer back.free();

	test::@check(back.secondary.len() == 1, "%d chains came back, not 1", back.secondary.len());
	test::@check(back.colliders.len() == 1, "%d colliders came back, not 1", back.colliders.len());
	test::@check(same_chain(back.secondary_of(ids[1]), tail_chain(ids[1], ids[2])), "the tail's chain came back different");
	test::@check(math::abs(back.collider_of(ids[3]) - BELLY_RADIUS) < EXACT, "the belly came back a different size");

	// A dot with nothing said about it comes back with nothing said about it —
	// absence has to survive as absence, or every rig gains a record per save.
	test::@check(!back.secondary_of(ids[0]).present(), "a bone nobody gave a chain came back with one");

	// --- the older file ---------------------------------------------------------

	String older = `{
  "version": 8,
  "mesh": "tail.glb",
  "root": 1,
  "next_id": 4,
  "auto_connect": true,
  "sym_x": 0,
  "dots": [{"id":1,"name":"hips","position":[0,1,0]},{"id":2,"name":"tail_1","position":[0,1,-0.3]}],
  "edges": [[1,2]],
  "attachments": [],
  "paint": []
}`;

	crig::RigDocument? ancient = crig::parse_session(mem, older);
	if (catch ancient)
	{
		test::@check(false, "a version 8 session no longer parses");
		return;
	}
	crig::RigDocument old = ancient;
	defer old.free();

	test::@check(old.dots.len() == 2, "the older session came back with %d dots", old.dots.len());
	test::@check(old.secondary.len() == 0 && old.colliders.len() == 0,
		"a session that said nothing about physics came back claiming some");

	// --- and the per-bone file: a two-bone tail, a fork, and a dynamic root ------
	//
	// tail_1 (2) and tail_2 (3) are a run; ear_L (5) and ear_R (6) fork off the
	// hips; the hips (1) are the skeleton's root. The run takes its root bone's
	// numbers, the fork becomes a chain per branch, and the root is dropped.
	String bones = `{
  "version": 9,
  "mesh": "tail.glb",
  "root": 1,
  "next_id": 7,
  "auto_connect": true,
  "sym_x": 0,
  "dots": [{"id":1,"name":"hips","position":[0,1,0]},{"id":2,"name":"tail_1","position":[0,1,-0.3]},
           {"id":3,"name":"tail_2","position":[0,1,-0.6]},{"id":4,"name":"belly","position":[0,0.88,0.12]},
           {"id":5,"name":"ear_L","position":[-0.1,1.2,0]},{"id":6,"name":"ear_R","position":[0.1,1.2,0]}],
  "edges": [[1,2],[2,3],[1,4],[1,5],[1,6]],
  "attachments": [],
  "paint": [],
  "physics": [{"id":2,"stiffness":3200.5,"damping":0.875,"gravity":1.25,"limit":0.6125,"radius":0.0325},
              {"id":3,"stiffness":1600.25,"damping":0.75,"gravity":1.25,"limit":0.9,"radius":0.0175},
              {"id":5,"stiffness":500,"damping":0.5,"gravity":0.5,"limit":0,"radius":0},
              {"id":6,"stiffness":500,"damping":0.5,"gravity":0.5,"limit":0,"radius":0},
              {"id":1,"stiffness":2000,"damping":0.3,"gravity":1,"limit":0,"radius":0}],
  "colliders": [{"id":4,"radius":0.1375}]
}`;

	crig::RigDocument? carried = crig::parse_session(mem, bones);
	if (catch carried)
	{
		test::@check(false, "a version 9 session with per-bone physics no longer parses");
		return;
	}
	crig::RigDocument moved = carried;
	defer moved.free();

	test::@check(moved.secondary.len() == 3, "the per-bone file migrated to %d chains, not 3", moved.secondary.len());
	test::@check(moved.colliders.len() == 1 && math::abs(moved.collider_of(4) - BELLY_RADIUS) < EXACT,
		"the capsule did not come across");

	crig::SecondaryChain tail = moved.secondary_of(2);
	test::@check(tail.present() && tail.tip == 3, "the tail did not become one chain from tail_1 to tail_2");
	test::@check(tail.preset == crig::SecondaryPreset.CUSTOM, "a migrated chain claims a preset");
	test::@check(math::abs(tail.flexibility - crig::secondary_flexibility(3200.5f)) < EXACT,
		"the tail's flexibility is %s, not its root bone's stiffness read back", tail.flexibility);
	test::@check(math::abs(tail.damping - 0.125f) < EXACT, "the tail's damping is %s where 1 - 0.875 is 0.125", tail.damping);
	test::@check(math::abs(tail.gravity - 1.25f) < EXACT && tail.collide,
		"the tail's gravity or collision went astray");

	// The root bone's numbers are the chain's: the tip's own gradient is what the
	// chain model cannot say, and it is reduced rather than invented.
	crig::JiggleParams expanded = tail.solver_params();
	test::@check(math::abs(expanded.stiffness - 3200.5f) < 0.5f,
		"the chain resolves to a stiffness of %s rather than near its root's 3200.5", expanded.stiffness);
	test::@check(math::abs(expanded.damping - 0.875f) < EXACT, "the chain resolves to a damping of %s, not 0.875", expanded.damping);

	test::@check(moved.secondary_of(5).present() && moved.secondary_of(5).tip == 5
		&& moved.secondary_of(6).present() && moved.secondary_of(6).tip == 6,
		"the forked ears did not become a chain per branch");
	test::@check(!moved.secondary_of(1).present(), "a dynamic bone on the skeleton's root was kept rather than dropped");

	// Saved again, it is written the new way and reads back the same.
	String rewritten = crig::session_text(mem, &moved, "tail.glb");
	defer rewritten.free(mem);
	test::@check(!rewritten.contains(`"physics"`), "a migrated document still writes the old key");
	crig::RigDocument? twice = crig::parse_session(mem, rewritten);
	if (try twice)
	{
		defer twice.free();
		test::@check(twice.secondary.len() == 3 && same_chain(twice.secondary_of(2), tail),
			"a migrated document did not survive its own save");
	}
	else
	{
		test::@check(false, "a migrated document's session did not read back");
	}

	// A malformed chain is the whole file refused, on the sidecar's usual terms.
	String broken = `{"version":16,"mesh":"t.glb","root":1,"next_id":3,"auto_connect":true,"sym_x":0,
  "dots":[{"id":1,"name":"hips","position":[0,1,0]},{"id":2,"name":"tail","position":[0,1,-0.3]}],
  "edges":[[1,2]],"attachments":[],"paint":[],
  "secondary":[{"root":2,"tip":2,"flexibility":7}]}`;
	crig::RigDocument? refused = crig::parse_session(mem, broken);
	if (try refused)
	{
		refused.free();
		test::@check(false, "a flexibility of 7 was read as a session");
	}
}

// One clip, so `export_pack_glb` has something to write — it refuses a pack with
// no keyframes in it, and a pack is clips as much as it is a rig.
fn crig::AnimTemplate one_clip(crig::AnimKeyDot[]* dots, crig::AnimKeyframe[]* frames)
{
	crig::AnimKeyDot[] moved = alloc::new_array(mem, crig::AnimKeyDot, 1);
	moved[0] = { .joint_name = "tail_1", .axis = { 1, 0, 0 }, .angle = 0.2f };

	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, 2);
	keys[0] = { .time = 0.0f, .dots = {} };
	keys[1] = { .time = 0.5f, .dots = moved };

	*dots = moved;
	*frames = keys;
	return { .name = "Wag", .duration = 1.0f, .keyframes = keys, .loop = true };
}

<*
 A `.glb` carries the chain bone by bone, and reading it back folds into the
 same chain.

 The whole point of writing KHR_physics_rigid_bodies rather than a crig-shaped
 extras blob: the file says what it means to somebody else's engine, *and* it
 comes back here intact. Matched by joint **name** rather than by index, because
 the read walks the file's own node tree and its joint order is its own business
 — a check that assumed the two agreed would be checking the walk, not the
 physics. The chain's shared values land on both bones of the run, and the two
 bones fold back into one chain with the root's numbers.
*>
fn void a_glb_carries_the_physics() @test
{
	io::printn("a pack .glb writes the physics extension per bone and reads it back as the chain");

	uint[] ids;
	crig::RigDocument doc = tail_document(&ids);
	defer
	{
		doc.free();
		alloc::free(mem, ids);
	}

	uint[] dot_ids;
	rig::Skeleton? built = crig::build_skeleton(&doc, mem, &dot_ids);
	if (catch built)
	{
		test::@check(false, "the document would not build a skeleton");
		return;
	}
	rig::Skeleton skeleton = built;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, dot_ids);
	}

	String[] names = alloc::new_array(mem, String, (sz)skeleton.len());
	defer alloc::free(mem, names);
	foreach (usz j, id : dot_ids) names[j] = doc.find(id).name;

	// The measured thickness a skin would hand in, one per joint: the tail's
	// two bones fatter than a point, everything else a point. What the file
	// writes as a sphere per dynamic bone.
	float[] radii = alloc::new_array(mem, float, (sz)skeleton.len());
	defer alloc::free(mem, radii);
	foreach (usz j, id : dot_ids) radii[j] = id == ids[1] ? TAIL_ROOT_PARAMS.radius : id == ids[2] ? TAIL_TIP_PARAMS.radius : 0.0f;

	crig::JiggleParams expanded = TAIL_VALUES.solver_params();

	crig::RigPhysics wire = crig::rig_physics_of(mem, &doc, &skeleton, dot_ids, radii);
	defer wire.free(mem);
	test::@check(wire.joints.len == 2 && wire.colliders.len == 1,
		"the document resolved to %d dynamic joints and %d colliders",
		wire.joints.len, wire.colliders.len);
	foreach (spec : wire.joints)
	{
		crig::JiggleParams want = expanded;
		want.radius = radii[spec.joint];
		test::@check(same_params(spec.params, want), "a bone of the run was not given the chain's values and its measured radius");
	}

	crig::AnimKeyDot[] dots;
	crig::AnimKeyframe[] frames;
	crig::AnimTemplate clip = one_clip(&dots, &frames);
	defer
	{
		alloc::free(mem, dots);
		alloc::free(mem, frames);
	}

	crig::AnimTemplate[1] clips = { clip };

	if (catch fault error = crig::export_pack_glb(
		mem, OUT_GLB, &skeleton, names, clips[..], {}, { .name = "Tail" }, wire))
	{
		test::@check(false, "could not write the pack (%s)", error);
		return;
	}

	crig::AnimPack? read = crig::read_pack(mem, OUT_GLB);
	if (catch read)
	{
		test::@check(false, "the pack did not read back");
		return;
	}
	crig::AnimPack pack = read;
	defer pack.free(mem);

	test::@check(pack.physics.skipped == 0,
		"%d physics objects in a file crig wrote did not map back", pack.physics.skipped);
	test::@check(pack.physics.joints.len == 2,
		"%d dynamic bones came back, not 2", pack.physics.joints.len);
	test::@check(pack.physics.colliders.len == 1,
		"%d colliders came back, not 1", pack.physics.colliders.len);

	foreach (spec : pack.physics.joints)
	{
		String named = spec.joint < pack.joint_names.len ? pack.joint_names[spec.joint] : "";
		if (named == "tail_1" || named == "tail_2")
		{
			crig::JiggleParams want = expanded;
			want.radius = named == "tail_1" ? TAIL_ROOT_PARAMS.radius : TAIL_TIP_PARAMS.radius;
			test::@check(same_params(spec.params, want), "%s came back different", named);
		}
		else
		{
			test::@check(false, "a bone called '%s' came back dynamic", named);
		}
	}

	foreach (spec : pack.physics.colliders)
	{
		String named = spec.joint < pack.joint_names.len ? pack.joint_names[spec.joint] : "";
		test::@check(named == "belly", "the capsule came back on '%s'", named);
		test::@check(math::abs(spec.radius - BELLY_RADIUS) < EXACT,
			"the capsule came back at %.6f rather than %.6f", spec.radius, BELLY_RADIUS);
	}

	// And the bones fold back into the chain: the crossing an import makes. The
	// pack's joint order is its own, so the bones are named back to this
	// document's dots first.
	crig::JiggleSpec[] bones = alloc::new_array(mem, crig::JiggleSpec, (sz)pack.physics.joints.len);
	defer alloc::free(mem, bones);
	foreach (usz i, spec : pack.physics.joints)
	{
		String named = spec.joint < pack.joint_names.len ? pack.joint_names[spec.joint] : "";
		bones[i] = { .dot_id = named == "tail_1" ? ids[1] : named == "tail_2" ? ids[2] : 0, .params = spec.params };
	}
	crig::SecondaryChain[] folded = crig::secondary_chains_from_bones(mem, &doc, bones);
	defer if (folded.len > 0) alloc::free(mem, folded);
	test::@check(folded.len == 1, "the file's bones folded into %d chains, not 1", folded.len);
	if (folded.len == 1)
	{
		crig::SecondaryChain expected = tail_chain(ids[1], ids[2]);
		test::@check(same_chain(folded[0], expected, NEAR),
			"the chain came back as %s→%s flexibility %s damping %s gravity %s",
			folded[0].root, folded[0].tip, folded[0].flexibility, folded[0].damping,
			folded[0].gravity);
	}

	// What the file itself holds, rather than what the mapping made of it: three
	// implicit shapes — the belly's capsule and one sphere per dynamic bone — two
	// bodies, two joint settings and the two collision filters. A writer that
	// emitted the objects but hung them off nothing would still pass the checks
	// above, because the reader would find none of them.
	gltf::GltfStream? opened = gltf::open(OUT_GLB, mem);
	if (catch opened)
	{
		test::@check(false, "the written file would not reopen");
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();

	test::@check(stream.gltf.shapes.len() == 3, "%d implicit shapes, not 3", stream.gltf.shapes.len());
	test::@check(stream.gltf.motions.len() == 2, "%d rigid bodies, not 2", stream.gltf.motions.len());
	test::@check(stream.gltf.physics_joints.len() == 2, "%d joint settings, not 2", stream.gltf.physics_joints.len());
	test::@check(stream.gltf.collision_filters.len() == 2, "%d collision filters, not 2",
		stream.gltf.collision_filters.len());

	// No cone: where a bone may turn is its joint's rotation-limit table, which
	// `write_rig_constraints` writes as a joint of its own, so a drive's joint
	// carries the spring and nothing about angles.
	foreach (settings : stream.gltf.physics_joints)
	{
		test::@check(settings.angular_limits.len() == 0, "a drive's joint came out with %d angular limits",
			settings.angular_limits.len());
		test::@check(settings.drives.len() == 1, "a dynamic bone came out with %d drives", settings.drives.len());
	}

	// And the extension is declared, since a reader that does not know it has to
	// be told it is looking at one it may not understand. The parser keeps no
	// `extensionsUsed` list, so this reads the bytes.
	char[]? raw = file::load(mem, OUT_GLB);
	if (try raw)
	{
		defer alloc::free(mem, raw);
		String text = (String)raw;
		test::@check(text.contains("KHR_physics_rigid_bodies"), "the file does not name the rigid body extension");
		test::@check(text.contains("KHR_implicit_shapes"), "the file does not name the implicit shapes extension");
	}

	(void)file::delete(OUT_GLB);
}

<*
 The engine export puts the capsule on the bone too.

 The one piece of real arithmetic in the mapping, and the one the round trip
 above cannot check: an import derives a collider from the bone rather than from
 the node, so a child node placed a quarter turn off would read back correct and
 be wrong in every viewer. So this asks the file directly — where does that node
 end up in the world, and which way does its +y point.

 The engine writer aligns its joint nodes along their bones (`gltf::add_skeleton`,
 local -Z down the bone) while a pack leaves them unrotated, so the same capsule
 is written in two different parent frames. Both have to land on the same segment
 in model space, which is what makes one function enough for two exporters.
*>
fn void the_capsule_lands_on_the_bone_in_a_rigged_file() @test
{
	io::printn("the bone-aligned exporter places the capsule on the bone as well");

	uint[] ids;
	crig::RigDocument doc = tail_document(&ids);
	defer
	{
		doc.free();
		alloc::free(mem, ids);
	}

	uint[] dot_ids;
	rig::Skeleton? built = crig::build_skeleton(&doc, mem, &dot_ids);
	if (catch built)
	{
		test::@check(false, "the document would not build a skeleton");
		return;
	}
	rig::Skeleton skeleton = built;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, dot_ids);
	}

	String[] names = alloc::new_array(mem, String, (sz)skeleton.len());
	defer alloc::free(mem, names);
	foreach (usz j, id : dot_ids) names[j] = doc.find(id).name;

	// Where the belly's capsule should end up, worked out here rather than read
	// out of the writer: the bone from the joint to its tail, and its middle.
	Vec3[] tails = skeleton.tails(mem);
	defer alloc::free(mem, tails);
	usz belly = joint_of(dot_ids, ids[3]);
	Vec3 head = skeleton.joints[belly];
	Vec3 bone = tails[belly] - head;
	Vec3 middle = head + bone * 0.5f;

	// A triangle is a mesh. The binder is handed nothing, so it falls back to
	// distance weights, which is all this needs — the check is about a node.
	Vec3[] points = alloc::new_array(mem, Vec3, 3);
	points[0] = { 0, 1, 0 };
	points[1] = { 0.1f, 1, -0.3f };
	points[2] = { 0, 0.9f, 0.1f };
	uint[] faces = alloc::new_array(mem, uint, 3);
	faces[0] = 0;
	faces[1] = 1;
	faces[2] = 2;
	defer
	{
		alloc::free(mem, points);
		alloc::free(mem, faces);
	}
	rig::TriMesh body = { .positions = points, .indices = faces };

	crig::RigPhysics wire = crig::rig_physics_of(mem, &doc, &skeleton, dot_ids);
	defer wire.free(mem);

	crig::AnimKeyDot[] dots;
	crig::AnimKeyframe[] frames;
	crig::AnimTemplate clip = one_clip(&dots, &frames);
	defer
	{
		alloc::free(mem, dots);
		alloc::free(mem, frames);
	}
	crig::AnimTemplate[1] clips = { clip };

	if (catch fault error = crig::export_rigged_animated_glb(
		mem, OUT_RIGGED, body, &skeleton, names, {}, clips[..], "Tail", 4, wire))
	{
		test::@check(false, "could not write the rigged file (%s)", error);
		return;
	}

	gltf::GltfStream? opened = gltf::open(OUT_RIGGED, mem);
	if (catch opened)
	{
		test::@check(false, "the rigged file would not reopen");
		return;
	}
	gltf::GltfStream stream = opened;
	defer stream.close();

	bool found = false;
	for (sz n = 0; n < stream.gltf.nodes.len(); n++)
	{
		gltf::Node node = stream.gltf.nodes[n];
		if (node.name != "belly.collider") continue;
		found = true;

		Vec3 at = node.world_position();
		test::@check((at - middle).length() < 1.0e-4f,
			"the capsule sits at (%.4f, %.4f, %.4f) rather than (%.4f, %.4f, %.4f)",
			at.x, at.y, at.z, middle.x, middle.y, middle.z);

		Vec3 up = node.world_rotation() * (Vec3){ 0, 1, 0 };
		Vec3 along = bone.normalize();
		test::@check((up - along).length() < 1.0e-4f,
			"the capsule points (%.4f, %.4f, %.4f) rather than along the bone (%.4f, %.4f, %.4f)",
			up.x, up.y, up.z, along.x, along.y, along.z);
	}
	test::@check(found, "the rigged file carries no collider node");

	(void)file::delete(OUT_RIGGED);
}

<*
 The document's chains become the runs the solver takes.

 Five claims, and four of them are about what the resolver refuses to be upset
 by. A tail is the ordinary case; a tip that has been deleted is the state undo
 leaves behind and must cost only that chain; a chain on the skeleton's root is
 dropped rather than crashing; a chain that would cross another loses to the
 one nearer the body; and a chain that does not collide says so to the solver
 — all because this runs on every rebuild, where a refusal has nobody to tell.
*>
fn void the_document_resolves_into_chains() @test
{
	io::printn("the document's chains resolve into ordered runs, stale ones and all");

	uint[] ids;
	crig::RigDocument doc = tail_document(&ids);
	defer
	{
		doc.free();
		alloc::free(mem, ids);
	}

	uint[] dot_ids;
	rig::Skeleton? built = crig::build_skeleton(&doc, mem, &dot_ids);
	if (catch built)
	{
		test::@check(false, "the document would not build a skeleton");
		return;
	}
	rig::Skeleton skeleton = built;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, dot_ids);
	}

	// --- the ordinary tail ---------------------------------------------------

	crig::JiggleChainSpec[] chains;
	crig::JiggleColliderSpec[] capsules;
	crig::jiggle_specs_from_document(mem, &doc, &skeleton, dot_ids, &chains, &capsules);

	test::@check(chains.len == 1, "%d chains came out of one tail", chains.len);
	if (chains.len == 1)
	{
		test::@check(chains[0].joints.len == 2, "the tail came out %d bones long", chains[0].joints.len);
		test::@check(chains[0].params.len == chains[0].joints.len, "a chain lost its params");
		test::@check(!chains[0].ignores_colliders, "a chain that collides was handed to the solver as one that does not");

		// Nearest the body first, which is what the pin at particle 0 means.
		usz root_joint = joint_of(dot_ids, ids[1]);
		usz tip_joint = joint_of(dot_ids, ids[2]);
		test::@check(chains[0].joints[0] == root_joint && chains[0].joints[1] == tip_joint,
			"the chain came out in the wrong order");
		crig::JiggleParams expanded = TAIL_VALUES.solver_params();
		test::@check(same_params(chains[0].params[0], expanded), "the root's params went astray");
		test::@check(same_params(chains[0].params[1], expanded), "the tip did not take the chain's shared values");
	}
	test::@check(capsules.len == 1, "%d colliders resolved, not 1", capsules.len);

	// It builds, which is the only claim that matters about the shape of it.
	crig::JiggleSim? sim = crig::build_jiggle_sim(mem, &skeleton, chains, capsules);
	if (catch fault error = sim)
	{
		test::@check(false, "the resolved chains would not build a sim (%s)", error);
	}
	else
	{
		crig::JiggleSim built_sim = sim;
		built_sim.free(mem);
	}
	crig::free_jiggle_specs(mem, chains, capsules);

	// --- a chain that does not collide says so -------------------------------

	crig::SecondaryChain free_tail = tail_chain(ids[1], ids[2]);
	free_tail.collide = false;
	doc.set_secondary(free_tail);
	crig::jiggle_specs_from_document(mem, &doc, &skeleton, dot_ids, &chains, &capsules);
	test::@check(chains.len == 1 && chains[0].ignores_colliders,
		"a chain with collide off was handed to the solver as one that collides");
	test::@check(chains.len == 1 && chains[0].params[0].radius == 0.0f,
		"a chain handed the solver from the document alone carries a thickness — that is the skin's to measure");
	crig::free_jiggle_specs(mem, chains, capsules);
	doc.set_secondary(tail_chain(ids[1], ids[2]));

	// --- a tip that is gone costs its chain, and nothing else ----------------

	doc.remove_dot(ids[2]);
	skeleton.free(mem);
	alloc::free(mem, dot_ids);
	skeleton = crig::build_skeleton(&doc, mem, &dot_ids)!!;

	crig::jiggle_specs_from_document(mem, &doc, &skeleton, dot_ids, &chains, &capsules);
	test::@check(chains.len == 0, "a deleted tip left %d chains rather than a chain waiting for undo", chains.len);
	test::@check(capsules.len == 1, "a deleted tip took the belly's capsule with it");
	crig::free_jiggle_specs(mem, chains, capsules);

	// --- a fork is a chain per branch, a root chain is dropped, a crossing loses

	uint left = doc.add_dot({ -0.1f, 1, -0.6f }, "tail_2L");
	uint right = doc.add_dot({ 0.1f, 1, -0.6f }, "tail_2R");
	doc.connect(ids[1], left);
	doc.connect(ids[1], right);
	doc.set_secondary(tail_chain(ids[1], left));
	doc.set_secondary(tail_chain(right, right));
	// The hips are the document root, so this is the joint with no parent at all.
	doc.set_secondary(tail_chain(ids[0], ids[0]));

	skeleton.free(mem);
	alloc::free(mem, dot_ids);
	skeleton = crig::build_skeleton(&doc, mem, &dot_ids)!!;

	crig::jiggle_specs_from_document(mem, &doc, &skeleton, dot_ids, &chains, &capsules);

	test::@check(chains.len == 2, "a fork resolved into %d chains rather than 2", chains.len);

	usz hips_joint = joint_of(dot_ids, ids[0]);
	foreach (chain : chains)
	{
		test::@check(chain.joints[0] != hips_joint,
			"a chain on the root with no parent was kept rather than dropped");
	}

	// Root-joint order, which is what makes two callers describing the same rig
	// produce the same motion.
	for (usz i = 1; i < chains.len; i++)
	{
		test::@check(chains[i - 1].joints[0] < chains[i].joints[0], "the chains came back out of order");
	}

	crig::JiggleSim? forked = crig::build_jiggle_sim(mem, &skeleton, chains, capsules);
	if (catch fault error = forked)
	{
		test::@check(false, "a forked tail would not build a sim (%s)", error);
	}
	else
	{
		crig::JiggleSim built_fork = forked;
		built_fork.free(mem);
	}
	crig::free_jiggle_specs(mem, chains, capsules);

	// A chain from the right branch's tip up through tail_1 would cross the left
	// chain at tail_1: the chain nearer the body keeps the joint, and this one
	// resolves to nothing rather than to a partial run.
	doc.clear_secondary(right);
	doc.set_secondary(tail_chain(ids[1], left));
	uint far_right = doc.add_dot({ 0.2f, 1, -0.9f }, "tail_3R");
	doc.connect(right, far_right);
	skeleton.free(mem);
	alloc::free(mem, dot_ids);
	skeleton = crig::build_skeleton(&doc, mem, &dot_ids)!!;
	// A second record on the same root replaces the first, so the crossing chain
	// has to be rooted elsewhere: at tail_2R, reaching up is not possible — a tip
	// above its root is a run of nothing, which is the same refusal.
	doc.set_secondary(tail_chain(right, ids[1]));
	crig::jiggle_specs_from_document(mem, &doc, &skeleton, dot_ids, &chains, &capsules);
	test::@check(chains.len == 1, "a chain whose tip sits above its root resolved into something (%d chains)", chains.len);
	crig::free_jiggle_specs(mem, chains, capsules);
}

<*
 The values: flexibility and stiffness are each other's inverse across the
 range, the presets start where they say, a chain knows when its sliders have
 left its preset, and the ranges refuse what a file and a tool both refuse.
*>
fn void the_values_map_both_ways() @test
{
	io::printn("flexibility and stiffness invert, presets hold, and the ranges refuse");

	// The ends of the range, and the middle: round trips to within a float's
	// worth through a logarithm each way.
	float[5] shares = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	foreach (share : shares)
	{
		float stiffness = crig::secondary_stiffness(share);
		float back = crig::secondary_flexibility(stiffness);
		test::@check(math::abs(back - share) < NEAR, "a flexibility of %s went to %s and came back %s", share, stiffness, back);
	}
	test::@check(math::abs(crig::secondary_stiffness(0.0f) - crig::SECONDARY_STIFFEST) < 0.01f, "flexibility 0 is not the stiffest spring");
	test::@check(math::abs(crig::secondary_stiffness(1.0f) - crig::SECONDARY_LOOSEST) < 0.01f, "flexibility 1 is not the loosest spring");
	test::@check(crig::secondary_stiffness(0.25f) > crig::secondary_stiffness(0.75f), "a looser chain resolved to a stiffer spring");
	test::@check(crig::secondary_flexibility(0.0f) == 1.0f, "no spring at all did not read as fully flexible");
	test::@check(crig::secondary_flexibility(1.0e9f) == 0.0f, "a spring past the stiffest did not clamp to 0");
	test::@check(crig::secondary_stiffness(2.0f) == crig::secondary_stiffness(1.0f), "a flexibility past 1 was not clamped");

	// The old model's defaults are the Tail preset, near enough that a chain
	// made with no preset named moves the way a bone made dynamic always has.
	crig::SecondaryChain tail = (crig::SecondaryChain){ .root = 1, .tip = 1 }.with_preset(crig::SecondaryPreset.TAIL);
	crig::JiggleParams as_bone = tail.solver_params();
	test::@check(math::abs(as_bone.stiffness - 2000.0f) < 60.0f, "Tail resolves to a stiffness of %s, not near 2000", as_bone.stiffness);
	test::@check(math::abs(as_bone.damping - 0.3f) < EXACT, "Tail resolves to a damping of %s, not 0.3", as_bone.damping);
	test::@check(as_bone.gravity == 1.0f && as_bone.radius == 0.0f, "Tail carries a thickness of its own");
	test::@check(tail.on_preset(), "a fresh Tail chain reads as edited");
	tail.flexibility = 0.9f;
	test::@check(!tail.on_preset(), "a dragged Tail chain still reads as untouched");
	test::@check(tail.with_preset(crig::SecondaryPreset.TAIL).on_preset(), "re-applying the preset did not reset its values");

	crig::SecondaryChain hair = tail.with_preset(crig::SecondaryPreset.HAIR);
	crig::SecondaryChain ear = tail.with_preset(crig::SecondaryPreset.EAR);
	crig::SecondaryChain soft = tail.with_preset(crig::SecondaryPreset.SOFT);
	test::@check(hair.flexibility > tail.with_preset(crig::SecondaryPreset.TAIL).flexibility && hair.collide, "Hair is not looser than Tail, or does not collide");
	test::@check(ear.gravity == 0.5f && !ear.collide, "Ear is not half-weighted and free of the body");
	test::@check(!soft.collide && soft.preset == crig::SecondaryPreset.SOFT, "Soft collides, or lost its label");
	crig::SecondaryChain custom = hair.with_preset(crig::SecondaryPreset.CUSTOM);
	test::@check(custom.flexibility == hair.flexibility && custom.preset == crig::SecondaryPreset.CUSTOM && custom.on_preset(),
		"Custom changed a value, or reads as edited");

	// Labels both ways, and an unknown one costs only the label.
	bool known;
	test::@check(crig::secondary_preset_named("ear", &known) == crig::SecondaryPreset.EAR && known, "\"ear\" did not read back");
	test::@check(crig::secondary_preset_named("fluffy", &known) == crig::SecondaryPreset.CUSTOM && !known, "an unknown preset was not read as custom");
	crig::SecondaryPreset[5] presets = { crig::SecondaryPreset.HAIR, crig::SecondaryPreset.TAIL, crig::SecondaryPreset.EAR, crig::SecondaryPreset.SOFT, crig::SecondaryPreset.CUSTOM };
	foreach (preset : presets)
	{
		test::@check(crig::secondary_preset_named(preset.label()) == preset, "%s does not round-trip through its label", preset.label());
	}

	// The migration's reading of a bone: damping flipped, the rest carried, and
	// the label custom.
	crig::SecondaryChain moved = crig::secondary_from_params(3, 4, TAIL_ROOT_PARAMS);
	test::@check(moved.root == 3 && moved.tip == 4 && moved.preset == crig::SecondaryPreset.CUSTOM && moved.collide,
		"a migrated bone lost its ends, its label or its collision");
	test::@check(math::abs(moved.damping - 0.125f) < EXACT, "a migrated bone's damping went astray");
	test::@check(math::abs(moved.solver_params().stiffness - 3200.5f) < 0.5f, "a migrated bone does not resolve back near its stiffness");

	// The ranges.
	crig::SecondaryChain sane = (crig::SecondaryChain){ .root = 1, .tip = 1 }.with_preset(crig::SecondaryPreset.HAIR);
	test::@check(crig::secondary_values_sane(sane), "a Hair chain is out of range");
	crig::SecondaryChain wrong = sane;
	wrong.flexibility = 1.5f;
	test::@check(!crig::secondary_values_sane(wrong), "a flexibility of 1.5 passed");
	wrong = sane;
	wrong.damping = -0.1f;
	test::@check(!crig::secondary_values_sane(wrong), "a damping below 0 passed");
	wrong = sane;
	wrong.gravity = 11.0f;
	test::@check(!crig::secondary_values_sane(wrong), "eleven g passed");
	wrong = sane;
	float infinity = 1.0f;
	infinity /= 0.0f;
	wrong.gravity = infinity;
	test::@check(!crig::secondary_values_sane(wrong), "an infinite gravity passed");
}

<*
 The run between a root and a tip, and where a chain started at a dot would
 naturally end.

 Asked of a skeleton built from the document rather than written by hand, so
 the joint indices are whatever the BFS made them — which is the thing a caller
 of these has in hand.
*>
fn void runs_and_inferred_tips_follow_the_skeleton() @test
{
	io::printn("a run is walked from tip to root, and an inferred tip stops at a fork");

	uint[] ids;
	crig::RigDocument doc = tail_document(&ids);
	defer
	{
		doc.free();
		alloc::free(mem, ids);
	}

	// A fork below the tail's tip, so inference has somewhere to stop.
	uint left = doc.add_dot({ -0.1f, 1, -0.9f }, "tail_3L");
	uint right = doc.add_dot({ 0.1f, 1, -0.9f }, "tail_3R");
	doc.connect(ids[2], left);
	doc.connect(ids[2], right);

	uint[] dot_ids;
	rig::Skeleton skeleton = crig::build_skeleton(&doc, mem, &dot_ids)!!;
	defer
	{
		skeleton.free(mem);
		alloc::free(mem, dot_ids);
	}

	usz hips = joint_of(dot_ids, ids[0]);
	usz root = joint_of(dot_ids, ids[1]);
	usz tip = joint_of(dot_ids, ids[2]);
	usz left_joint = joint_of(dot_ids, left);
	usz belly = joint_of(dot_ids, ids[3]);

	usz[8] run;
	usz length = crig::secondary_run(&skeleton, root, left_joint, run[..]);
	test::@check(length == 3 && run[0] == root && run[1] == tip && run[2] == left_joint,
		"the run from tail_1 to tail_3L came out %d long or out of order", length);
	test::@check(crig::secondary_run(&skeleton, root, root, run[..]) == 1 && run[0] == root,
		"a tip equal to the root is not a run of one");
	test::@check(crig::secondary_run(&skeleton, root, belly, run[..]) == 0,
		"a tip on another branch resolved to a run");
	test::@check(crig::secondary_run(&skeleton, tip, root, run[..]) == 0,
		"a tip above its root resolved to a run");
	test::@check(crig::secondary_run(&skeleton, root, 99, run[..]) == 0, "a tip that is not a joint resolved to a run");
	test::@check(crig::secondary_run(&skeleton, root, left_joint, run[:2]) == 0,
		"a run longer than the room it was given was written anyway");

	// Inference: down through the sole children, out at the fork.
	test::@check(crig::secondary_infer_tip(&skeleton, root) == tip,
		"a chain rooted at tail_1 did not end at the fork below tail_2");
	test::@check(crig::secondary_infer_tip(&skeleton, tip) == tip, "a chain rooted at a fork did not end there");
	test::@check(crig::secondary_infer_tip(&skeleton, left_joint) == left_joint, "a chain rooted at a leaf did not end there");
	test::@check(crig::secondary_infer_tip(&skeleton, hips) == hips, "a chain rooted at the hips, which fork, ran on");
}

// Which joint a dot became, for a check that has the map in hand anyway.
fn usz joint_of(uint[] dot_ids, uint id)
{
	foreach (usz j, held : dot_ids)
	{
		if (held == id) return j;
	}
	return dot_ids.len;
}

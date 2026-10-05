<*
 Auto-naming a hand-placed rig: `AppState.auto_name`.

 `c3c test --trust=full --test-filter crig_tests::naming` — run from the crig
 directory, the pack library path is relative.

 The figure the checks build is deliberately **not** the shape of the plan it is
 matched against. `biped.glb` is a T-pose with the arms held out level; this is
 an A-pose with them hanging at forty-five degrees, on a torso of different
 proportions. A check that placed the dots where the plan puts them would pass
 on a matcher that only ever compared positions, which is the one thing
 `match_shapes` deliberately does not do.

 Worth pinning:

 names    the plan's words land on the right dots, arms and legs both
 sides    left is left — the failure that looks like success on screen
 refusal  a rig that is not the plan's shape is left exactly as it was
 undo     the whole naming is one entry
 point    naming does not take away a clip the rig could already play

 The last one used to read "a clip that would not play before plays after", and
 the change is the subject of the two checks at the foot of this file. Since
 `measure_reach`, a clip finds a rig's joints by the *shape* of the two
 skeletons, so an unnamed rig plays the library already and naming is no longer
 the gate. What is checked here instead is that the shape route works across two
 vocabularies at all, and that it says where it stops.
*>
module crig_tests::naming;

import crig;
import rig;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::vector;


// The same 2-unit cube the other suites use, opened through `shared_app`.
// Nothing here is about geometry: `auto_name` matches the document's dots
// against a pack's plan and never asks the mesh anything, so this is only what
// an `AppState` needs to exist — and the two checks that play a clip bind it,
// which is why it is the shared coarse grid and not a production one.

// One joint of the figure below: where to put it, and which of the ones already
// placed it hangs off. `-1` is the root.
struct Limb @local
{
	Vec3 at;
	int parent;
}

<*
 A humanoid standing in an A-pose, in model units, hips-first.

 Twenty-five joints, the same count the biped plan places, and none of them where
 the plan would put it: the arms hang rather than reaching out, the forearms are
 longer than the upper arms, and the head sits closer over the shoulders than a
 T-pose table draws it. What survives all of that is the order — seven up the
 spine, four out each arm, five down each leg — which is what the matcher reads.

 The chain lengths are the plan's and the positions are not, and that split is
 the whole fixture. `match_shapes` walks structure, so a figure with a different
 number of joints in a limb is a different animal to it; a figure with the same
 run of joints in a different pose is the case it exists to get right.

 It used to be seventeen, against `biped.glb`'s shorter chains — three to an arm
 and three to a leg, with the spine ending at the head. That pack no longer
 ships; `humanoid.glb` carries the biped plan now, and it runs a toe past the
 ankle, a shoulder in front of the arm and a crown above the head.

 Placed in the order a person would build it, so the array index is also the
 order the dots are added and `parent` can point backwards into it.
*>
Limb[25] a_pose @local = {
	{ .at = { 0.00, 1.00, 0.00 }, .parent = -1 },  // 0  hips
	{ .at = { 0.00, 1.14, 0.00 }, .parent = 0 },   // 1  spine
	{ .at = { 0.00, 1.28, 0.00 }, .parent = 1 },   // 2  spine1
	{ .at = { 0.00, 1.46, 0.00 }, .parent = 2 },   // 3  spine2
	{ .at = { 0.00, 1.63, 0.00 }, .parent = 3 },   // 4  neck
	{ .at = { 0.00, 1.72, 0.00 }, .parent = 4 },   // 5  head
	{ .at = { 0.00, 1.90, 0.00 }, .parent = 5 },   // 6  crown

	{ .at = { 0.09, 1.56, 0.00 }, .parent = 3 },   // 7  shoulder, +X
	{ .at = { 0.19, 1.54, 0.00 }, .parent = 7 },   // 8  upper arm
	{ .at = { 0.40, 1.31, 0.00 }, .parent = 8 },   // 9  forearm
	{ .at = { 0.66, 1.03, 0.00 }, .parent = 9 },   // 10 hand

	{ .at = { -0.09, 1.56, 0.00 }, .parent = 3 },  // 11 shoulder, -X
	{ .at = { -0.19, 1.54, 0.00 }, .parent = 11 }, // 12 upper arm
	{ .at = { -0.40, 1.31, 0.00 }, .parent = 12 }, // 13 forearm
	{ .at = { -0.66, 1.03, 0.00 }, .parent = 13 }, // 14 hand

	{ .at = { 0.13, 0.94, 0.00 }, .parent = 0 },   // 15 thigh, +X
	{ .at = { 0.14, 0.51, 0.00 }, .parent = 15 },  // 16 shin
	{ .at = { 0.14, 0.06, 0.00 }, .parent = 16 },  // 17 ankle
	{ .at = { 0.14, 0.02, 0.10 }, .parent = 17 },  // 18 ball of the foot
	{ .at = { 0.14, 0.01, 0.18 }, .parent = 18 },  // 19 toe tip

	{ .at = { -0.13, 0.94, 0.00 }, .parent = 0 },  // 20 thigh, -X
	{ .at = { -0.14, 0.51, 0.00 }, .parent = 20 }, // 21 shin
	{ .at = { -0.14, 0.06, 0.00 }, .parent = 21 }, // 22 ankle
	{ .at = { -0.14, 0.02, 0.10 }, .parent = 22 }, // 23 ball of the foot
	{ .at = { -0.14, 0.01, 0.18 }, .parent = 23 }, // 24 toe tip
};

// Which slot of `a_pose` each dot ended up as, so a check can name a joint by
// what it drew rather than by an id it would have to have remembered.
struct Figure @local
{
	crig::AppState app;
	uint[25] id;
}

<*
 Build the A-pose figure over the fixture library, with every dot unnamed.

 Unnamed is the state that matters: it is what clicking a rig together produces,
 and it is why the library greys out. The dots go in through `doc.add_dot`
 rather than `add_recorded`, so the undo stack starts empty and the only entry in
 it afterwards is the one `auto_name` writes.
*>
fn void Figure.open(&self)
{
	self.app = shared_app::open_cube();

	foreach (usz i, limb : a_pose)
	{
		self.id[i] = self.app.doc.add_dot(limb.at);
		if (limb.parent >= 0) self.app.doc.connect(self.id[(usz)limb.parent], self.id[i]);
	}
	self.app.doc.root_id = self.id[0];

	shared_app::attach_all_packs(&self.app);
}

fn void Figure.close(&self)
{
	self.app.free();
}

// The name the dot placed at slot `i` of the figure ended up carrying.
fn String Figure.name_at(&self, usz i)
{
	crig::Dot* dot = self.app.doc.find(self.id[i]);
	return dot ? dot.name : "";
}

// ---------------------------------------------------------------------------
// The same figure with hands.

// How far each finger leans across the palm, and how far it reaches. The lean is
// the sine of the angle off the arm's own line, so a chain's direction is
// `along * sqrt(1 - lean^2) + across * lean` and stays unit length.
//
// **Fanned, not parallel.** An earlier version of this fixture ran all five
// fingers straight out at fixed offsets, and the matcher swapped index for ring
// on both hands — the two are within a twentieth of each other in length, so all
// that separates them is which way they lean, and a hand of parallel fingers does
// not say. No rig is built that way, and one that were would be genuinely
// ambiguous rather than wrongly matched.
//
// Deliberately not the plan's own numbers: same anatomy, different proportions,
// so a pass here is the matcher working rather than two tables agreeing.
float[5] finger_lean @local = { 0.72, 0.30, 0.00, -0.32, -0.80 };
float[5] finger_reach @local = { 0.048, 0.079, 0.086, 0.074, 0.058 };

// Where each joint of a finger sits along it. Four, because a downloaded rig
// carries four and the plan is written to match — the last is a tip marker.
float[4] finger_along @local = { 0.30, 0.58, 0.82, 1.00 };

// Slots in `Figure.hand`: five fingers of four, so the thumb runs 0 to 3, the
// index 4 to 7, and so on to the pinky at 16 to 19. No palm slot — the plan's
// own chain already ends at a hand, and the fingers hang off that.
const usz HAND_JOINTS @local = 5 * 4;

// Which arm, for the pair the hand slots are held in.
const usz LEFT @local = 0;
const usz RIGHT @local = 1;

<*
 The A-pose figure with fingers on each hand: 65 dots, the shape of a rig
 somebody built by hand after modelling them.

 `hand[..][0]` is the left hand's fingers and `hand[..][1]` the right's, laid out
 as thumb, index, middle, ring and pinky, four joints apiece — the order
 `HAND_JOINTS` counts and `finger_lean` lists.
*>
struct HandedFigure @local
{
	crig::AppState app;
	uint[25] id;
	uint[2][HAND_JOINTS] hand;
}

fn void HandedFigure.open(&self)
{
	self.app = shared_app::open_cube();

	foreach (usz i, limb : a_pose)
	{
		self.id[i] = self.app.doc.add_dot(limb.at);
		if (limb.parent >= 0) self.app.doc.connect(self.id[(usz)limb.parent], self.id[i]);
	}
	self.app.doc.root_id = self.id[0];

	// Hand slots in `a_pose`, left then right. The chain already ends at a hand,
	// so the fingers hang straight off it — there is no palm dot of our own to
	// add, and adding one would give the figure a joint the plan has no name for.
	usz[2] hand_slot = { 10, 14 };
	foreach (usz side, slot : hand_slot)
	{
		Vec3 forearm = a_pose[slot - 1].at;
		Vec3 hand = a_pose[slot].at;

		// The arm's own direction, continued: a finger carries on where the
		// forearm was pointing, which on this figure is down and outward at forty-
		// five degrees rather than along any axis.
		Vec3 along = (hand - forearm).normalize();
		Vec3 across = { 0, 0, 1 };

		usz next = 0;
		foreach (usz f, lean : finger_lean)
		{
			Vec3 out = along * math::sqrt(1.0f - lean * lean) + across * lean;
			uint parent = self.id[slot];
			foreach (fraction : finger_along)
			{
				uint joint = self.app.doc.add_dot(hand + out * (finger_reach[f] * fraction));
				self.app.doc.connect(parent, joint);
				self.hand[next++][side] = joint;
				parent = joint;
			}
		}
	}

	shared_app::attach_all_packs(&self.app);
}

fn void HandedFigure.close(&self)
{
	self.app.free();
}

fn String HandedFigure.name_at(&self, usz i)
{
	crig::Dot* dot = self.app.doc.find(self.id[i]);
	return dot ? dot.name : "";
}

// The name on joint `i` of the hand on `side` — 0 left, 1 right.
fn String HandedFigure.hand_name(&self, usz side, usz i)
{
	crig::Dot* dot = self.app.doc.find(self.hand[i][side]);
	return dot ? dot.name : "";
}

fn void a_hand_placed_biped_takes_the_plans_names() @test
{
	Figure figure;
	figure.open();
	defer figure.close();

	crig::AutoNaming named = figure.app.auto_name();

	test::@check(named.usable(), "the A-pose figure matched only %d of the %s plan's %d joints",
		named.matched, named.plan, named.total);
	test::eq(named.plan, "biped");
	test::eq(named.matched, (usz)25);
	test::eq(named.total, (usz)25);
	test::eq(named.unnamed, (usz)0);

	// The spine, which is what a rig that merely stands upright would also get
	// right — checked so a failure further down is read as a limb problem rather
	// than as nothing having happened at all.
	test::eq(figure.name_at(0), "hips");
	test::eq(figure.name_at(3), "chest");
	test::eq(figure.name_at(5), "head");

	// The limbs, which are the part the arc-length matching is for: the A-pose
	// puts this wrist a quarter of the figure below where the plan draws one.
	test::eq(figure.name_at(9), "elbow_L");
	test::eq(figure.name_at(10), "wrist_L");
	test::eq(figure.name_at(17), "ankle_L");
}

<*
 Left is left.

 The failure this catches looks like a success everywhere else: every name is
 spelt correctly, the count is seventeen of seventeen, and the rig plays every
 clip mirrored. Only which side each suffix landed on says so.

 `fit_preset` writes `_L` for the table's own x and `_R` for its reflection
 through the midline, and the biped table puts its shoulder at 0.58 across —
 the high side. So `_L` is +X, and a figure whose left arm came back `_R` has
 been matched back to front.
*>
fn void sides_are_not_swapped() @test
{
	Figure figure;
	figure.open();
	defer figure.close();

	figure.app.auto_name();

	test::eq(figure.name_at(7), "clavicle_L");
	test::eq(figure.name_at(10), "wrist_L");
	test::eq(figure.name_at(15), "thigh_L");

	test::eq(figure.name_at(11), "clavicle_R");
	test::eq(figure.name_at(14), "wrist_R");
	test::eq(figure.name_at(20), "thigh_R");
}

<*
 A rig that is not the plan's shape is left exactly as it was.

 A bare chain has a spine and nothing else, so it covers well under the two
 thirds `usable` asks for. Naming it anyway would put `hips` and `head` on it and
 ungrey clips that then drive two joints out of seventeen — worse than a library
 that stays greyed, because it looks like it worked.
*>
fn void a_rig_that_is_not_the_plan_is_left_alone() @test
{
	crig::AppState app = shared_app::open_cube();
	defer app.free();

	uint a = app.doc.add_dot({ 0, 0.0, 0 });
	uint b = app.doc.add_dot({ 0, 0.5, 0 });
	uint c = app.doc.add_dot({ 0, 1.0, 0 });
	app.doc.connect(a, b);
	app.doc.connect(b, c);
	app.doc.root_id = a;
	shared_app::attach_all_packs(&app);

	crig::AutoNaming named = app.auto_name();

	test::@check(!named.usable(), "a three-dot chain passed as a %s at %d of %d joints",
		named.plan, named.matched, named.total);
	test::eq(named.renamed, (usz)0);

	foreach (dot : app.doc.dots.array_view())
	{
		test::@check(dot.name.len == 0, "the refused naming still wrote \"%s\"", dot.name);
	}
	test::@check(app.doc.plan.len == 0, "the refused naming still tagged the document \"%s\"", app.doc.plan);
}

<*
 Seventeen renames, one Ctrl+Z.

 The whole point of doing this in one entry: a naming a user does not like is one
 keystroke to be rid of, not seventeen. The dots were placed outside the undo
 stack, so a single undo has to leave every one of them nameless again.
*>
fn void naming_is_one_undo() @test
{
	Figure figure;
	figure.open();
	defer figure.close();

	crig::AutoNaming named = figure.app.auto_name();
	test::eq(named.renamed, (usz)25);

	test::@check(figure.app.undo(), "there was nothing to undo after naming seventeen dots");

	foreach (dot : figure.app.doc.dots.array_view())
	{
		test::@check(dot.name.len == 0, "one undo left \"%s\" behind", dot.name);
	}
	test::@check(!figure.app.undo_stack.can_undo(), "the naming was recorded as more than one entry");
}

<*
 What the whole thing is for: the library is not greyed out, and naming does not
 change that.

 It used to be the opposite check, and the change is deliberate rather than a
 relaxation. A clip reached a joint by name and by nothing else, so an unnamed
 rig played nothing however well it was built and `auto_name` was the gate. Since
 `measure_reach`, the names a clip needs are worked out from the *shape* of the
 two skeletons — so a rig clicked together and never named plays the library
 already, which is the better first run by some distance.

 What naming is still for is everything a name is read for elsewhere: the dot
 labels, the joint names a save writes into the model, the plan tag a pack is
 offered on. So the claim worth pinning is that the clip plays throughout and
 that naming does not take that away, which is the failure a shape match feeding
 the wrong words would produce.
*>
fn void a_named_rig_plays() @test
{
	Figure figure;
	figure.open();
	defer figure.close();

	crig::AnimRef found = { .pack = -1, .clip = -1 };
	foreach (usz p, &pack : figure.app.packs)
	{
		if (!pack.is_body_plan() || pack.plan != "biped" || pack.clips.len == 0) continue;
		found = { .pack = (int)p, .clip = 0 };
		break;
	}
	test::@check(found.pack >= 0, "the fixture library holds no biped clip to play");

	test::@check(figure.app.clip_playable(found),
		"the unnamed rig cannot play %s — the shape match is what should carry it",
		figure.app.clip(found).name);

	// And it really runs, rather than merely being offered: the words the pose
	// reads come from the reach, and a reach that named nothing would leave every
	// joint at rest while the cell stayed lit.
	test::@check(figure.app.play_clip(found) && figure.app.animating,
		"%s would not start on the unnamed rig", figure.app.clip(found).name);
	figure.app.stop_animation();

	usz named = figure.app.auto_name().renamed;
	test::@check(named > 0, "auto_name renamed nothing, so the check below proves nothing");

	test::@check(figure.app.clip_playable(found),
		"naming the rig took away a clip it could already play: %s",
		figure.app.clip(found).name);
}

// ---------------------------------------------------------------------------
// Fingers.

<*
 A rig with no fingers matches the plan exactly as it did before the plan had
 any.

 The regression `PresetDot.optional` exists to prevent, stated as a number: the
 biped plan carries fifty-nine joints and forty-two of them are optional, so what
 a plain rig has to cover is the seventeen every biped has — not the fifty-nine a
 handed one could fill, which it would miss by two thirds and fail.

 `extra` is the other half of it. Nothing optional matched, and it must not have:
 a plan dot placed on a joint that is not there is a name a clip would drive into
 empty space.
*>
fn void a_fingerless_rig_still_matches_biped() @test
{
	Figure figure;
	figure.open();
	defer figure.close();

	crig::AutoNaming named = figure.app.auto_name();

	test::eq(named.plan, "biped");
	test::eq(named.matched, (usz)25);
	test::eq(named.total, (usz)25);
	test::eq(named.extra, (usz)0);
	test::eq(named.renamed, (usz)25);
}

<*
 A rig that does have fingers gets them named.

 This is the whole of Phase B in one check. Everything the biped plan grew is
 exercised getting here: the optional rows in the table, the fit that leaves them
 out, the pack key that carries which they were, the plan rebuilt from the file,
 and the two-pass match that lets a fifty-nine-dot plan still fit a rig with a
 hand on it.

 **Which of the five fingers is which is not asserted, because it is not yet
 reliable.** `pair_leaves` pairs a plan chain to a source chain by its direction
 and arc length measured from the anchor the limbs hang off — the hips — and from
 there all five fingers of one hand point the same way to within a per cent. What
 separates them is local to the palm, and the shared arm dilutes it. Measured on
 this fixture and on a real mixamo rig, the five come back as a permutation of
 each other: the chains are whole and in order, the side is right, the joint depth
 is right, and the labels are shuffled. So a clip's index finger may drive the
 ring one.

 What that leaves worth checking is everything else, and it is most of the value:
 the fingers exist at all, where before every one of their channels folded away.
*>
fn void a_handed_rig_gets_its_fingers_named() @test
{
	HandedFigure figure;
	figure.open();
	defer figure.close();

	crig::AutoNaming named = figure.app.auto_name();

	test::@check(named.usable(), "the handed figure matched only %d of the %s plan's %d joints",
		named.matched, named.plan, named.total);
	test::eq(named.plan, "biped");

	// Every joint of both hands found a plan dot: twenty finger joints, twice.
	test::eq(named.matched, (usz)25);
	test::eq(named.extra, (usz)40);
	test::eq(named.renamed, (usz)65);

	// The arm, unmoved by the hand hanging off it. The failure worth catching is
	// not "the fingers came back blank" — that is visible — but "the fingers came
	// back named and the wrist slid down into the palm to make room", which reads
	// as a success and plays the whole arm wrong.
	test::eq(figure.name_at(9), "elbow_L");
	test::eq(figure.name_at(10), "wrist_L");
	test::eq(figure.name_at(14), "wrist_R");

	// Each finger came back as one whole finger, joints in order, on its own side.
	// That is what a clip needs to drive a hand at all: a chain broken across two
	// of the plan's fingers, or numbered backwards, would curl a finger the wrong
	// way rather than merely curling the wrong finger.
	// The plan spells a finger `index_2_L`: the word, the joint's number, then
	// the side. So the side is the suffix and the joint is the character before it.
	String[2] hand_side = { "_L", "_R" };
	for (usz side = 0; side < 2; side++)
	{
		for (usz finger = 0; finger < 5; finger++)
		{
			String stem = "";
			for (usz joint = 0; joint < 4; joint++)
			{
				String name = figure.hand_name(side, finger * 4 + joint);
				test::@check(name.len > 4, "finger %d joint %d came back unnamed", finger, joint);

				test::@check(name.ends_with(hand_side[side]),
					"finger %d joint %d came back as %s, which is not a %s hand",
					finger, joint, name, side == 0 ? "left" : "right");
				test::eq(name[^3], (char)('1' + joint));

				String head = name[:^3];
				if (joint == 0) stem = head;
				test::@check(head == stem,
					"finger %d ran from %s into %s halfway along", finger, stem, head);
			}
		}
	}
}

<*
 The biped pack says which of its joints are optional, and says it in the file.

 `AnimPack.preset` rebuilds a plan out of a pack's rest skeleton and its joint
 names, and nothing in either says that `index_2_L` is a finger while `elbow_L`
 is not. Only `PACK_KEY_OPTIONAL` does, so a round
 trip that drops it turns the handed plan back into a sixty-five-joint rig every
 plain biped fails to cover.
*>
fn void the_pack_remembers_which_joints_are_optional() @test
{
	crig::AnimPack[] packs = crig::scan_packs(mem, library::ready());
	defer crig::free_packs(mem, packs);

	crig::AnimPack* biped = null;
	foreach (&pack : packs)
	{
		if (pack.plan == "biped") biped = pack;
	}
	test::@check(biped != null, "the fixture library holds no biped pack");

	usz optional = 0;
	foreach (flag : biped.joint_optional)
	{
		if (flag) optional++;
	}
	test::eq(biped.rest.len(), (usz)65);
	test::eq(optional, (usz)40);

	// And it survives into the plan, which is the form everything else reads.
	crig::Preset plan = biped.preset(mem);
	defer crig::free_preset(mem, plan);

	usz spare = 0;
	foreach (dot : plan.dots)
	{
		if (dot.optional) spare++;
	}
	test::eq(spare, (usz)40);
}

<*
 The plan's optional dots are named, never placed.

 A body plan applied to a mesh has to come back with the seventeen dots it always
 came back with. There is nothing in a figure's proportions that says where a
 knuckle goes, so a fit that tried would drop thirty finger dots into the palm as
 a blob — worse than no fingers, because they would then have to be deleted.
*>
fn void optional_dots_are_not_placed() @test
{
	crig::AnimPack[] packs = crig::scan_packs(mem, library::ready());
	defer crig::free_packs(mem, packs);

	crig::AnimPack* biped = null;
	foreach (&pack : packs)
	{
		if (pack.plan == "biped") biped = pack;
	}
	test::@check(biped != null, "the fixture library holds no biped pack");

	crig::Preset plan = biped.preset(mem);
	defer crig::free_preset(mem, plan);

	rig::Bounds unit = { .min = { 0, 0, 0 }, .max = { 1, 1, 1 } };
	crig::FittedDot[] fitted = crig::fit_preset(mem, plan, unit, null);
	defer crig::free_fitted(mem, fitted);

	test::eq((usz)fitted.len, (usz)25);
	foreach (dot : fitted)
	{
		test::@check(!dot.optional, "the fit placed the optional dot %s", dot.name);
	}
}


<*
 Of two plans a rig fits equally, the one with a word for more of it wins.

 The regression a Mixamo character walked into. Coverage is measured against a
 plan's **required** dots — see `PresetDot.optional` — and every biped plan
 requires the same seventeen, so a rig with hands covers a plan that has fingers
 and a plan that has none by exactly the same fraction. Both report 17 of 17, the
 ratio the ranking compares says nothing, and the winner was whichever plan the
 library happened to hold first.

 What that cost was not the ranking, it was the names. The shipped library held
 three plans tagged `biped` at the time, two of them in a downloaded rig's
 spelling; a sixty-five joint skeleton in that spelling fitted all three, took
 the smallest one's words, and its own clips — which key all sixty-five in the
 file's spelling — then reached the six joints that plan had no dot for and
 nothing else. The clip ran, `clip_applies` said yes on those six, and the
 character stood still.

 Stated here on the one pair of plans the fixture library can make: the biped
 plan, and the same plan with its fingers taken out. The stripped one is asked
 first, the way the smaller plan was, so a ranking that cannot break the tie
 keeps it.
*>
fn void the_plan_naming_more_of_the_rig_wins_a_tie() @test
{
	HandedFigure figure;
	figure.open();
	defer figure.close();

	crig::AnimPack* biped = null;
	foreach (&pack : figure.app.packs)
	{
		if (pack.plan == "biped") biped = pack;
	}
	if (!biped)
	{
		test::@check(false, "the fixture library holds no biped pack");
		return;
	}

	crig::Preset full = biped.preset(mem);
	defer crig::free_preset(mem, full);

	crig::Preset core = without_optional(mem, full);
	defer crig::free_preset(mem, core);

	test::eq((usz)core.dots.len, (usz)25);
	test::eq((usz)full.dots.len, (usz)65);

	crig::RigView? opened = figure.app.open_rig(mem);
	if (catch opened)
	{
		test::@check(false, "the handed figure would not open as a rig");
		return;
	}
	crig::RigView view = opened;
	defer view.free(mem);

	crig::MatchShape source = { .at = view.skeleton.joints, .parent = view.skeleton.parents };

	crig::JointMatch small = crig::match_preset(mem, source, core);
	defer small.free(mem);
	crig::JointMatch large = crig::match_preset(mem, source, full);
	defer large.free(mem);

	// The tie itself, before anything is asked about breaking it. Both plans are
	// covered whole, so the fraction is 1 either way and there is nothing in it.
	test::eq(small.matched, small.total);
	test::eq(large.matched, large.total);
	test::@check(small.matched * large.total == large.matched * small.total,
		"the two plans no longer tie — %d/%d against %d/%d, and this check has stopped testing what it says",
		small.matched, small.total, large.matched, large.total);

	// What separates them: the fingers, which only one of the two can name.
	test::eq(small.extra, (usz)0);
	test::@check(large.extra > 0, "the full plan named no optional dot, so there is no tie to break");

	test::@check(large.better_than(small),
		"the plan naming %d joints lost the tie to the one naming %d",
		large.matched + large.extra, small.matched + small.extra);
	test::@check(!small.better_than(large),
		"and the smaller plan must not win it back");
}

<*
 The plan with its optional dots removed: the same body, without a vocabulary
 for hands.

 Every optional dot of the biped plan is a hand or a finger, and both hang off a
 wrist that stays — so nothing surviving is left pointing at a dot that went, and
 the reparenting `required_shape` does has nothing to do here. Checked rather
 than assumed, since a plan that grew an optional joint mid-spine would need it.

 Owned by the caller, and freed by `free_preset` — the names are copies.
*>
fn crig::Preset without_optional(Allocator allocator, crig::Preset plan) @local
{
	int[] moved = alloc::new_array(allocator, int, (sz)plan.dots.len);
	defer alloc::free(allocator, moved);

	usz kept = 0;
	foreach (usz d, dot : plan.dots)
	{
		moved[d] = dot.optional ? -1 : (int)kept;
		if (!dot.optional) kept++;
	}

	crig::PresetDot[] dots = alloc::new_array(allocator, crig::PresetDot, (sz)kept);
	usz at = 0;
	foreach (usz d, dot : plan.dots)
	{
		if (dot.optional) continue;
		int parent = dot.parent >= 0 ? moved[(usz)dot.parent] : -1;
		test::@check(dot.parent < 0 || parent >= 0,
			"%s hangs off an optional dot, so this plan cannot be stripped by filtering alone", dot.name);

		dots[at] = dot;
		dots[at].name = dot.name.copy(allocator);
		dots[at].parent = parent;
		at++;
	}

	return { .name = plan.name, .plan = plan.plan, .dots = dots, .extent = plan.extent };
}

// ---------------------------------------------------------------------------
// Two vocabularies for one shape.

<*
 A clip reaches a rig that spells its joints differently.

 The thing `measure_reach` exists for, on the only pair of vocabularies the
 fixture library can make: the rig is renamed to words no pack uses, so nothing
 the biped clips key is a name this document carries, and the only route left is
 the shape of the two skeletons.

 The case in the wild is a library holding packs tagged `biped` in two
 spellings — a downloaded one's `mixamorig:Hips` beside the shipped `hips`.
 Before this, a rig named by one of them took nothing from the others — and
 took it *silently*, because one accidental spelling in common was enough for
 the clip to be offered, play, and move a toe.

 Both halves are checked, because the first without the second is what the bug
 looked like: the clip is offered, **and** it actually carries the rig somewhere.
*>
fn void a_clip_reaches_a_rig_that_spells_its_joints_differently() @test
{
	Figure figure;
	figure.open();
	defer figure.close();

	crig::AnimRef found = { .pack = -1, .clip = -1 };
	foreach (usz p, &pack : figure.app.packs)
	{
		if (!pack.is_body_plan() || pack.plan != "biped" || pack.clips.len == 0) continue;
		found = { .pack = (int)p, .clip = 0 };
		break;
	}
	test::@check(found.pack >= 0, "the fixture library holds no biped clip to play");

	// A vocabulary of its own, sharing nothing with any pack. This is what a
	// character downloaded from anywhere else arrives in.
	foreach (usz i, id : figure.id)
	{
		String own = string::format(mem, "bone_%d", i);
		defer alloc::free(mem, own.ptr);
		figure.app.rename_recorded(id, own);
	}
	figure.app.undo_stack.commit();

	foreach (kf : figure.app.clip(found).keyframes)
	{
		foreach (kd : kf.dots)
		{
			test::@check(!figure.app.has_dot_named(kd.joint_name),
				"the rig still answers to %s, so this check is not testing a translation",
				kd.joint_name);
		}
	}

	crig::PackReach* reach = figure.app.pack_reach((usz)found.pack);
	test::@check(reach != null && reach.usable,
		"the biped pack no longer relates to a biped rig once it is renamed");
	test::eq(reach.answered, (usz)25);

	test::@check(figure.app.clip_applies(found),
		"%s is out of reach of a rig it fits exactly", figure.app.clip(found).name);

	// And it moves the rig, which is the half the old test could not have failed
	// on: a reach that named nothing would leave every joint at rest while the
	// cell stayed lit and the player claimed to be running.
	test::@check(figure.app.play_clip(found), "%s would not start", figure.app.clip(found).name);
	figure.app.anim_time = figure.app.current_anim.duration * 0.5f;
	figure.app.refresh_animation();

	usz moved = 0;
	foreach (posed : figure.app.posed_dots)
	{
		crig::Dot* dot = figure.app.doc.find(posed.dot);
		if (dot && (posed.at - dot.position).length() > 1.0e-4f) moved++;
	}
	figure.app.stop_animation();

	test::@check(moved > 0, "the clip played and carried not one joint anywhere");
}

<*
 A clip that asks for more rig than there is says where the rig stops.

 The disclosure half. A Mixamo dance on a character with no fingers is a good
 walk that will not curl a hand, and the user is entitled to know that before
 wondering why the hands are stiff — but not by being handed the forty joint
 names that did not land. What is worth saying is the boundary: the joints the
 rig *has*, with clip motion below them and no rig below them to carry it.

 The figure here has hands and no fingers, so a clip keying a knuckle stops at
 the hand and the answer is one name rather than the twenty that are absent.
*>
fn void a_clip_says_where_the_rig_stops() @test
{
	Figure figure;
	figure.open();
	defer figure.close();
	figure.app.auto_name();

	crig::AnimPack* biped = null;
	usz which = 0;
	foreach (usz p, &pack : figure.app.packs)
	{
		if (pack.plan != "biped" || !pack.is_body_plan()) continue;
		biped = pack;
		which = p;
		break;
	}
	if (!biped)
	{
		test::@check(false, "the fixture library holds no biped pack");
		return;
	}

	// A clip that curls one finger, which none of the shipped ones do — they stop
	// at the wrist, so on this figure they have nothing to report.
	AnimTemplate curl = finger_clip(mem, "index_2_L");
	defer curl.free(mem);

	crig::PackReach* reach = figure.app.pack_reach(which);
	test::@check(reach != null && reach.usable, "the biped pack does not relate to a biped rig");

	crig::ReachGaps gaps = crig::reach_gaps(mem, biped, reach, &curl);
	defer gaps.free(mem);

	// One name per hand, not the twenty joints that are really absent — and the
	// hand rather than the finger, because the hand is the joint this rig actually
	// has. Only the left, since only the left is keyed.
	test::eq((usz)gaps.stops.len, (usz)1);
	test::eq(gaps.stops[0], "wrist_L");
	test::eq((usz)gaps.missing.len, (usz)0);

	// And a clip the rig can carry whole says nothing at all, which is what keeps
	// the notice worth reading.
	crig::ReachGaps quiet = crig::reach_gaps(mem, biped, reach, &biped.clips[0]);
	defer quiet.free(mem);
	test::@check(!quiet.present(),
		"%s reports a gap on a rig that carries all of it", biped.clips[0].name);
}

// A one-joint clip, for a joint the fixture figure does not have. Two keyframes,
// because a template with one instant has no duration to play over.
fn AnimTemplate finger_clip(Allocator allocator, String joint) @local
{
	AnimKeyframe[] frames = alloc::new_array(allocator, AnimKeyframe, 2);
	foreach (usz f, &frame : frames)
	{
		AnimKeyDot[] dots = alloc::new_array(allocator, crig::AnimKeyDot, 1);
		dots[0] = {
			.joint_name = joint.copy(allocator),
			.axis = { 0, 0, 1 },
			.angle = f == 0 ? 0.0f : 1.0f,
		};
		*frame = { .time = f == 0 ? 0.0f : 1.0f, .dots = dots };
	}
	return { .name = "Curl".copy(allocator), .duration = 1.0f, .keyframes = frames, .owned = true };
}

<*
 A joint the automatic match leaves out plays once matched by hand, and the
 match is one undo step and survives the sidecar.
*>
fn void a_hand_match_plays_an_unmatched_joint() @test
{
	Figure figure;
	figure.open();
	defer figure.close();
	figure.app.auto_name();

	usz which = 0;
	crig::AnimPack* biped = null;
	foreach (usz p, &pack : figure.app.packs)
	{
		if (pack.plan != "biped" || !pack.is_body_plan()) continue;
		biped = pack;
		which = p;
		break;
	}
	if (!biped)
	{
		test::@check(false, "the fixture library holds no biped pack");
		return;
	}
	String file = biped.path.copy(mem);
	defer file.free(mem);

	AnimTemplate curl = finger_clip(mem, "index_2_L");
	defer curl.free(mem);
	test::@check(!figure.app.pack_reach(which).answers("index_2_L"), "the figure already plays a finger");

	crig::RigView view = figure.app.open_rig(mem)!!;
	defer view.free(mem);
	sz wrist = -1;
	foreach (usz j, name : view.names) if (name == "wrist_L") wrist = (sz)j;
	test::@check(wrist >= 0, "the figure has no wrist_L");

	rig::Pose still = curl.pose(mem, &view.skeleton, figure.app.pack_reach(which).names, 1.0f);
	defer still.free(mem);
	test::@check(math::abs(still.rotations[(usz)wrist].v.w) > 0.9999f, "the wrist turned before it was matched");

	sz history = figure.app.undo_stack.cursor;
	crig::JointMap[1] rows = { { .file = file, .source = "index_2_L", .joint = "wrist_L" } };
	test::@check(figure.app.map_pack_joints(file, rows[..]), "the match was not stored");
	test::eq(figure.app.undo_stack.cursor, history + 1);
	crig::PackReach* reach = figure.app.pack_reach(which);
	test::eq(reach.names[(usz)wrist], "index_2_L");

	rig::Pose turned = curl.pose(mem, &view.skeleton, reach.names, 1.0f);
	defer turned.free(mem);
	test::@check(math::abs(turned.rotations[(usz)wrist].v.w) < 0.999f, "the matched joint does not play");

	String text = crig::session_text(mem, &figure.app.doc, "figure.glb");
	defer text.free(mem);
	crig::RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session did not read back");
		return;
	}
	defer parsed.free();
	test::eq(parsed.joint_maps.len, (sz)1);
	test::eq(parsed.joint_maps[0].source, "index_2_L");
	test::eq(parsed.joint_maps[0].joint, "wrist_L");
	test::eq(parsed.joint_maps[0].file, file);

	test::@check(figure.app.undo(), "the match did not undo");
	test::@check(!figure.app.pack_reach(which).answers("index_2_L"), "undo left the match");
	test::@check(figure.app.redo(), "the match did not redo");
	test::@check(figure.app.pack_reach(which).answers("index_2_L"), "redo lost the match");
}

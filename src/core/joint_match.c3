<*
 Matching a source rig onto a body plan by the shape of the two skeletons.

 A downloaded clip names its joints whatever its authoring tool felt like —
 `mixamorig:LeftUpLeg`, `upperarm_l`, `L_Upperarm` — and a crig rig names its
 dots `shoulder_L`. Nothing in either name tells you they are the same joint, and
 a table of translations only ever covers rigs someone has already met. This
 matches on what every rig has and no rig can spell wrong: where its joints are
 and which hangs off which.

 	`JointMatch found = crig::match_shapes(mem, source, plan);`
 	`defer alloc::free(mem, found.dot);`

 **Nothing here reads a name.** Both sides arrive as a `MatchShape` — positions,
 parents, and at most a measurement of how far the file's clips ever turn each
 joint — so a name cannot leak into the decision even by accident.

 **What makes it work is arc length.** Rest poses disagree: a downloaded figure
 stands in an A-pose with its arms at 45 degrees while a body plan is written as
 a T-pose, so the source's wrist normalizes to (0.88, 0.535) where the plan puts
 one at (0.86, 0.80) — the same lateral position, a quarter of the figure apart
 vertically. But a wrist is at the far end of the arm in both, and *how far along
 its chain* a joint sits does not change when the chain swings. Position is kept
 as a second opinion, because arc length alone cannot tell a foot from the toe
 in front of it; see `MATCH_POSITION_WEIGHT`.

 **A source joint the plan has no dot for is not matched, and folds.** That is
 not this file's business — `anim/import.c3` unmarks it before `collect_joints`
 runs, so its children reparent onto the nearest survivor and its rotation
 composes into them rather than being lost. Twist bones, clavicles, extra spine
 segments and toes all leave by that door.
*>
module crig;

import std::sort;
import rig;
import std::math;
import std::math::vector;
import std::collections::list;



alias MatchUszList = List{usz};

<*
 How much a joint's position counts against how far along its chain it sits.

 Small, and deliberately so. Arc length decides; position is a tiebreak for a run
 whose proportions genuinely cannot separate two candidates, and it has to stay
 quiet because the case this file exists for is the case where position is
 *wrong*: a source standing in an A-pose puts its wrist a quarter of the figure
 below where a T-pose plan puts one, so any weight that lets position speak up
 will put the wrist on the forearm.

 Measured on the fixture in test/anim_import_test.c3, which is a full biped with
 the stubs a real rig carries: anything from zero to a half maps all seventeen
 dots correctly, and at one the right arm slides a joint down its own chain.
 A quarter sits in the middle of what works, and is the first number to revisit
 when a rig maps somewhere surprising.
*>
const float MATCH_POSITION_WEIGHT = 0.25f;

<*
 How well two chains must point the same way before they are worth costing.

 A dot product of unit directions from the anchor, so 0.35 is about seventy
 degrees. Loose on purpose: an arm that hangs and an arm held out differ by more
 than a rig ever differs in any other way, and a tight threshold would refuse the
 case this file exists for. It is a gate and not a score — what actually decides
 a pairing is laying the chain out and pricing it, and this only keeps an arm
 from being priced against a leg at all.
*>
const float MATCH_MIN_AGREEMENT = 0.35f;

// An axis narrower than this has nothing to normalize against.
const float MATCH_FLAT @local = 1.0e-6f;

// How far off the midline a limb has to lean before which side it is on counts
// as a fact about it rather than as noise. A fraction of the normalized rig,
// whose longest axis is one.
//
// Four hundredths sits in a real gap. On the rigs measured, a head and a neck
// lean under one hundredth off the midline and the nearest thing to them that
// is not on it — a thigh — leans six, so anything from two to five would do.
// Higher would call a leg central and stop telling the two apart.
const float MATCH_SIDE_MIN @local = 0.04f;

// The least of a source run a plan's chain may be laid along. A tenth: a limb
// stopping short of a toe or a finger keeps most of its chain, and nothing that
// keeps under a tenth of one is the same limb.
const float MATCH_MIN_RUN @local = 0.1f;

// Below this, a joint counts as one the file's clips never turn. Radians, just
// under three degrees: helper bones exported flat — twist stubs, end markers,
// clavicles a tool keyed but never moved — measure exactly zero, while the
// quietest joint that is actually animated on the packs measured turns fourteen
// degrees. Anything between noise and that gap would do.
const float MATCH_STILL_MIN @local = 0.05f;

// What it costs a dot to sit on a joint the clips never turn, when the dots on
// either side of it need that joint to move. Only dots *inside* a chain pay it:
// a chain's terminal dot may land on a still joint legitimately — plenty of
// rigs key their hands flat and the wrist is still the wrist — but a shoulder
// or an elbow that never turns is a helper wearing a limb's proportions.
// Measured on a rig whose arm hangs in an A-pose: the clavicle sits at the
// same fraction of the chest-to-hand arc as a plan's shoulder, within four
// hundredths, so arc length alone resolves the two by coin toss — one side of
// the same figure matched the shoulder and the other the clavicle. A quarter
// is decisive over gaps that small and far too small to overturn a fit that is
// right for structural reasons.
const float MATCH_STILL_PENALTY @local = 0.25f;

// What a run pays for swallowing a junction and carrying on past it. A joint
// that fans out into three or more chains is a hub — a hand into its fingers,
// hips into legs and spine — and a run that crosses one without giving it a
// dot has almost always slid off the limb's end into its decoration: laid
// along a real arm, a plan's arm fits chest-to-fingerbase a few hundredths
// better than chest-to-hand, because human forearms are long and finger bases
// are close to where a stubby plan expects a wrist. Two-child forks stay free;
// a bone with a twist stub beside it is a fork, and limbs cross those
// routinely. A hub a dot actually lands on is free too — a plan that knows
// about the junction is allowed to pass it.
const float MATCH_HUB_CROSS @local = 0.2f;

// What a plan dot costs to leave unplaced, because the source has no joint for
// it. A coarse rig is an ordinary thing to be handed: a game skeleton with one
// spine bone, no toes and no crown of the head drives a plan that has three,
// two and one of them, and demanding a joint per dot refuses the whole limb —
// measured on such a rig, the arm could not be laid out at all, and the legs
// took the arms instead. Priced like a poor arc-length fit, so a dot is only
// left out when every place it could go is worse than that, and the dot is
// then simply not driven: the joint it names holds its rest under whatever its
// parent does.
const float MATCH_SKIP_PENALTY @local = 0.3f;

// What a dot that leans off the midline pays for landing on a joint on it: a
// thigh on a pelvis pivot. The same fact `same_side` gates the leaves on, asked
// of every joint along a chain — measured on a rig whose legs hang off a pelvis
// bone on the midline, without it the plan's thigh took the pelvis and every leg
// joint below slid one down its chain. One way only, and priced rather than
// refused: a plan's clavicle starts on the midline and a rig's often a little
// off it, and that is the same joint.
const float MATCH_MIDLINE_PENALTY @local = 0.3f;

// What a plan dot whose hand was set aside pays for landing on a source joint
// with nothing below it. With its optional fingers taken out, the plan's wrist
// is the end of its chain — but it stands for a wrist with a hand beyond it,
// and a source arm that ends in a bare end-marker past its hand has that hand
// right there: the marker is the hand's reach, the part a finger would be. Arc
// length alone reads the wrist onto the marker and the elbow onto the hand as
// readily as the right way round — measured on such a rig, within three
// thousandths — so this tips it. Small, because a source arm that genuinely
// stops at its wrist has nothing else for the wrist to take.
const float MATCH_TRIMMED_LEAF @local = 0.1f;

// How far below a dot its fan of chains may reach, as a fraction of the figure,
// for it to be read as a hand — see `inferred_hands`. A finger reaches about a
// twentieth of a humanoid's height and a leg nearly a half; a sixth sits far
// from both.
const float MATCH_HAND_REACH @local = 0.16f;

<*
 Where each side's limbs hang off, in its own normalized box — the anchors.

 Two things are measured from it. Its x is the midline `MATCH_MIDLINE_PENALTY`
 reads a joint's lean against. And a joint's position is compared with a dot's
 as an offset from its own anchor rather than as a place in its box: a box is
 stretched by whatever the rig carries beyond the figure, and a tail that runs
 two body-depths behind a character pushes every joint of the body to the far
 side of its box — measured on such a rig, turning the file round moved the
 tail to the other side and changed which joint every leg dot took.
*>
struct MatchFrame @local
{
	Vec3 plan;
	Vec3 source;

	// Plan dots that end their chain only because the dots below them were set
	// aside as optional, and source joints with no children. See
	// `MATCH_TRIMMED_LEAF`. Either may be empty.
	bool[] trimmed;
	bool[] leaf;
}

// Stands in for "no assignment reaches here" in the alignment below. Any value
// larger than a real cost does; a real cost is bounded by the run length plus
// MATCH_POSITION_WEIGHT times the diagonal of a unit box.
const float MATCH_UNREACHED @local = 1.0e30f;

<*
 What the matcher is allowed to know about a skeleton: where each joint is,
 which joint it hangs off, and — when the caller has clips to measure — how far
 those clips ever turn it.

 `parent` indexes back into `at`, -1 for a root, and must be lower than the
 joint's own index — the parents-before-children order `collect_joints` and
 `PresetDot.parent` both already guarantee.

 `moved` is one angle per joint in radians, or empty for a side with nothing to
 measure — a plan, or a file with no animations. It separates what proportions
 cannot: a clavicle keyed flat sits at the same fraction of an arm as a
 shoulder, and only the fact that it never turns says which is which.
*>
struct MatchShape
{
	Vec3[] at;
	int[] parent;
	float[] moved;

	// Plan side only: which dots a rig does not have to have — see
	// `PresetDot.optional`. Empty means every dot is required, which is what a
	// source rig always passes and what a plan without fingers passes too.
	//
	// It changes nothing about the matching. All it decides is what `total` counts,
	// and so what `usable` measures coverage against: a biped that stops at the
	// wrist has to cover the seventeen joints every biped has, not the forty-nine
	// a rig with fingers could fill.
	bool[] optional;

	// Plan side only: which dots had optional dots hanging off them that were
	// taken out for a pass over the required ones — see `required_shape` and
	// `MATCH_TRIMMED_LEAF`. Empty for every shape but that one.
	bool[] trimmed;
}

<*
 Which plan dot each source joint drives.

 `dot` is one entry per source joint: an index into the plan, or -1 for a joint
 the plan has no dot for, which is the instruction to fold. `matched` against
 `total` is how much of the plan was covered, and is the number worth showing a
 user — a rig that filled four dots out of seventeen matched nothing useful, and
 no single entry says so.

 **Both counts are over the plan's required dots only.** `extra` is the optional
 ones that also matched — fingers, on a rig that has them — and is deliberately
 not folded into either: a plan is covered or it is not, and a hand is a bonus on
 top of a cover rather than part of one. So `matched + extra` is how many plan
 dots the rig actually filled, and is the count to show beside a naming; `matched`
 and `total` are the pair to show beside a confidence.

 `node` is filled in only by a caller that collected the source joints out of a
 glTF node table and needs to write a per-joint answer back per node; the matcher
 itself neither sets nor reads it. `plan` likewise records which of several plans
 this was, for a caller comparing them.
*>
struct JointMatch
{
	int[] dot;
	usz[] node;
	usz plan;
	usz matched;
	usz extra;
	usz total;
}

<*
 Whether this match covered enough of the plan to act on.

 Two thirds. A body plan whose spine matched and whose limbs did not is not a rig
 of that shape; it is a rig that happened to stand upright, and naming its joints
 after a plan it does not have would grey out fewer clips while playing them
 wrong — which is worse than leaving the file's own names on and greying them all.
*>
fn bool JointMatch.usable(&self) => self.total > 0 && self.matched * 3 >= self.total * 2;

<*
 Whether this match covers more of its plan than another does.

 A fraction, not a count: two plans of different sizes are being compared, and
 the one with more dots would otherwise win by having more to match.

 **A tie is broken by how much of the rig got a name.** Coverage is measured
 against a plan's *required* dots, and every biped plan requires the same
 seventeen — so a skeleton with hands covers all of them under every one of
 them, the fraction says 1.0 across the board, and the winner is whichever plan
 happened to be looked at first. `matched + extra` is what the rig actually
 filled, fingers included, so the plan with a word for more of this skeleton
 wins. That is also the plan whose clips will reach more of it: a Mixamo
 character used to import under the smallest plan that fitted, leaving its own
 clips keying sixty-five joint names the rig no longer had.
*>
fn bool JointMatch.better_than(&self, JointMatch other)
{
	if (other.total == 0) return self.total > 0;
	if (self.total == 0) return false;

	usz mine = self.matched * other.total;
	usz theirs = other.matched * self.total;
	if (mine != theirs) return mine > theirs;

	return self.matched + self.extra > other.matched + other.extra;
}

<*
 Release a match. Safe on one that was never filled in.
*>
fn void JointMatch.free(&self, Allocator allocator)
{
	if (self.dot.len > 0) alloc::free(allocator, self.dot);
	if (self.node.len > 0) alloc::free(allocator, self.node);
	*self = {};
}

<*
 A body plan as something the matcher can read: its dots' normalized positions
 and its parent links, and not one of its names.

 Mirrored rows are **not** expanded — a plan reaching the matcher is expected to
 have `_L` and `_R` already separate, which is what `AnimPack.preset` produces
 and what every plan the app actually holds is. A table with `mirror` still set
 would match only half a body.

 The caller owns the result; release it with `free_preset_shape`.
*>
fn MatchShape preset_shape(Allocator allocator, Preset plan)
{
	Vec3 aspect = plan_aspect(plan);
	MatchShape shape = {
		.at = alloc::new_array(allocator, Vec3, (sz)plan.dots.len),
		.parent = alloc::new_array(allocator, int, (sz)plan.dots.len),
		.optional = alloc::new_array(allocator, bool, (sz)plan.dots.len),
	};
	foreach (usz i, dot : plan.dots)
	{
		shape.at[i] = { dot.at.x * aspect.x, dot.at.y * aspect.y, dot.at.z * aspect.z };
		shape.parent[i] = dot.parent;
		shape.optional[i] = dot.optional;
	}
	return shape;
}

// What each axis of a plan's fractions has to be multiplied by to be a shape
// again — `Preset.extent`, or all ones for a table that carries none.
//
// Absolute size does not matter: `normalized` divides by the longest side, so
// only the ratios between the three survive. What this restores is those ratios.
fn Vec3 plan_aspect(Preset plan) @local
{
	Vec3 extent = plan.extent;
	if (extent.x <= MATCH_FLAT || extent.y <= MATCH_FLAT || extent.z <= MATCH_FLAT)
	{
		return { 1, 1, 1 };
	}
	return extent;
}

fn void free_preset_shape(Allocator allocator, MatchShape shape)
{
	if (shape.at.len > 0) alloc::free(allocator, shape.at);
	if (shape.parent.len > 0) alloc::free(allocator, shape.parent);
	if (shape.moved.len > 0) alloc::free(allocator, shape.moved);
	if (shape.optional.len > 0) alloc::free(allocator, shape.optional);
	if (shape.trimmed.len > 0) alloc::free(allocator, shape.trimmed);
}

<*
 Match a source rig onto a body plan — the call to make when the plan may carry
 optional dots.

 	`JointMatch found = crig::match_preset(mem, source, plan);`
 	`defer found.free(mem);`

 **Matched twice, once with the optional dots and once without, and the better
 answer kept.** Leaving them out of the *count* is not enough to make them
 optional: a plan whose arms run to fingertips has eight-dot arm chains, and laid
 along a three-joint source arm most of those dots go unplaced — including the
 wrist. Measured on the seventeen-joint fixture in test/naming_test.c3, the
 handed biped plan lost enough of its own limbs that way to score below the bird.

 Better means more of the plan's required dots covered; a tie goes to whichever
 also explains more optional ones. So a rig with no fingers matches exactly the
 plan it would have matched before the fingers were written, and a rig with them
 matches the same seventeen joints and its hands as well.

 `dot` indexes the full plan either way, so the caller reads one set of names and
 does not have to know which pass won.

 @param plan : `Mirrored rows already expanded — the same requirement preset_shape has.`
*>
fn JointMatch match_preset(Allocator allocator, MatchShape source, Preset plan)
{
	// A plan that does not say which of its dots are optional has its hands read
	// off its shape instead — see `inferred_hands`.
	PresetDot[] inferred = inferred_hands(allocator, plan);
	defer if (inferred.len > 0) alloc::free(allocator, inferred);
	if (inferred.len > 0) plan.dots = inferred;

	MatchShape full = preset_shape(allocator, plan);
	JointMatch whole = match_shapes(allocator, source, full);
	free_preset_shape(allocator, full);

	usz spare = 0;
	foreach (dot : plan.dots)
	{
		if (dot.optional) spare++;
	}
	if (spare == 0) return whole;

	usz[] back;
	MatchShape core = required_shape(allocator, plan, &back);
	JointMatch plain = match_shapes(allocator, source, core);
	free_preset_shape(allocator, core);

	// Back into the caller's index space before either answer is compared, so the
	// winner is a plan index whichever pass produced it.
	foreach (usz j, int d : plain.dot)
	{
		if (d >= 0) plain.dot[j] = (int)back[(usz)d];
	}
	alloc::free(allocator, back);

	// A tie goes to the pass without the optional dots unless the full one
	// actually placed some of them. A full pass that found no finger at all laid
	// its arms toward fingertips the source does not have, which bends where
	// along the arm every dot falls — measured on a rig whose arm ends in a bare
	// marker past the hand, it put the elbow on the hand. The plain pass asked
	// the question that rig can answer.
	if (plain.matched > whole.matched || (plain.matched == whole.matched && whole.extra == 0))
	{
		whole.free(allocator);
		return plain;
	}
	plain.free(allocator);
	return whole;
}

<*
 The plan's dots with its hands marked optional, for a plan that marks nothing
 optional itself; empty when it marks something, or has no hand to find.

 A pack says which of its joints a rig may go without (`PACK_KEY_OPTIONAL`),
 and a pack that forgets to say requires every one of them: a sixty-five joint
 humanoid then asks a source to cover sixty-five joints, fingers and all, and
 no rig without fingers can reach two thirds of that — measured on a 27-bone
 game rig with a perfectly good body, the plan could not be matched at all and
 every clip fell through to a raw shape guess that crossed the limbs.

 So when nothing is declared, a hand is read off the plan's shape: a dot with
 three or more chains hanging off it, every one of them unbranched and short —
 under `MATCH_HAND_REACH` of the figure. Fingers are that, and toes are; a
 pelvis with its legs is not, because a leg is long, and a chest is not,
 because an arm branches again at the hand. Everything below such a dot is
 optional, the dot itself is not: a biped still has to have its wrists.

 The caller owns the returned array; its names are borrowed from the plan.
*>
fn PresetDot[] inferred_hands(Allocator allocator, Preset plan) @local
{
	usz count = plan.dots.len;
	foreach (dot : plan.dots)
	{
		if (dot.optional) return {};
	}
	if (count == 0) return {};

	Vec3 aspect = plan_aspect(plan);
	float figure = aspect.max();
	Vec3[] at = alloc::new_array(allocator, Vec3, (sz)count);
	usz[] kids = alloc::new_array(allocator, usz, (sz)count);
	float[] reach = alloc::new_array(allocator, float, (sz)count);
	bool[] branched = alloc::new_array(allocator, bool, (sz)count);
	bool[] hand = alloc::new_array(allocator, bool, (sz)count);
	defer
	{
		alloc::free(allocator, at);
		alloc::free(allocator, kids);
		alloc::free(allocator, reach);
		alloc::free(allocator, branched);
		alloc::free(allocator, hand);
	}

	foreach (usz i, dot : plan.dots)
	{
		at[i] = { dot.at.x * aspect.x, dot.at.y * aspect.y, dot.at.z * aspect.z };
		if (dot.parent >= 0 && (usz)dot.parent < count) kids[(usz)dot.parent]++;
	}

	// Children follow their parents, so one backward pass sees every child before
	// its parent: how far each dot's subtree reaches below it, and whether it
	// forks anywhere on the way.
	for (usz i = count; i > 0; i--)
	{
		usz d = i - 1;
		if (kids[d] > 1) branched[d] = true;
		int up = plan.dots[d].parent;
		if (up < 0 || (usz)up >= count) continue;
		float here = reach[d] + (at[d] - at[(usz)up]).length();
		reach[(usz)up] = math::max(reach[(usz)up], here);
		if (branched[d]) branched[(usz)up] = true;
	}

	bool found = false;
	for (usz d = 0; d < count; d++)
	{
		if (kids[d] < 3 || reach[d] >= figure * MATCH_HAND_REACH) continue;
		bool fans = true;
		foreach (usz c, dot : plan.dots)
		{
			if (dot.parent == (int)d && branched[c]) fans = false;
		}
		if (!fans) continue;
		hand[d] = true;
		found = true;
	}
	if (!found) return {};

	PresetDot[] out = alloc::new_array(allocator, PresetDot, (sz)count);
	out[:count] = plan.dots[:count];
	bool[] below = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, below);
	foreach (usz i, dot : plan.dots)
	{
		if (dot.parent < 0 || (usz)dot.parent >= count) continue;
		below[i] = hand[(usz)dot.parent] || below[(usz)dot.parent];
		out[i].optional = below[i];
	}
	return out;
}

// The plan with its optional dots taken out: their children reparent onto the
// nearest ancestor that stayed, the same way `anim/import.c3` folds a source
// joint the plan has no dot for.
//
// `back` comes back mapping each surviving dot to its index in the full plan,
// and belongs to the caller.
fn MatchShape required_shape(Allocator allocator, Preset plan, usz[]* back) @local
{
	usz count = 0;
	foreach (dot : plan.dots)
	{
		if (!dot.optional) count++;
	}

	MatchShape shape = {
		.at = alloc::new_array(allocator, Vec3, (sz)count),
		.parent = alloc::new_array(allocator, int, (sz)count),
		.trimmed = alloc::new_array(allocator, bool, (sz)count),
	};
	usz[] full = alloc::new_array(allocator, usz, (sz)count);

	// Full index -> the reduced dot that stands in for it: itself when it stayed,
	// its nearest surviving ancestor when it did not. Parents precede children, so
	// one forward pass fills it.
	int[] stands_for = alloc::new_array(allocator, int, (sz)plan.dots.len);
	defer alloc::free(allocator, stands_for);

	Vec3 aspect = plan_aspect(plan);

	usz next = 0;
	foreach (usz i, dot : plan.dots)
	{
		int up = dot.parent >= 0 ? stands_for[(usz)dot.parent] : -1;
		if (dot.optional)
		{
			stands_for[i] = up;
			if (up >= 0) shape.trimmed[(usz)up] = true;
			continue;
		}
		stands_for[i] = (int)next;
		shape.at[next] = { dot.at.x * aspect.x, dot.at.y * aspect.y, dot.at.z * aspect.z };
		shape.parent[next] = up;
		full[next] = i;
		next++;
	}

	*back = full;
	return shape;
}

<*
 Match a source rig onto a body plan.

 	`JointMatch found = crig::match_shapes(mem, source, plan);`
 	`defer alloc::free(mem, found.dot);`

 Both shapes are normalized to their own joints' bounding box first, so the two
 are compared as proportions of themselves and neither scale nor units enter.
 Then, in order: find the joint each side's limbs hang off, pair up the chains
 that reach the extremities, and fill in each chain by how far along it every
 joint sits.

 The caller owns `dot`. A shape with no joints, or a plan with none, comes back
 matched to nothing rather than failing — an empty answer is what an unmatched
 file gets and the caller already has to handle it.
*>
fn JointMatch match_shapes(Allocator allocator, MatchShape source, MatchShape plan)
{
	usz joints = source.at.len;
	JointMatch found = {
		.dot = alloc::new_array(allocator, int, (sz)joints),
		.total = plan.at.len,
	};
	found.dot[:joints] = -1;

	if (joints == 0 || plan.at.len == 0) return found;

	Vec3[] source_at = normalized(allocator, source);
	Vec3[] plan_at = normalized(allocator, plan);
	defer
	{
		alloc::free(allocator, source_at);
		alloc::free(allocator, plan_at);
	}

	// Which source joints are hubs — three or more children — computed once so
	// every run can pay MATCH_HUB_CROSS for crossing one it did not match.
	bool[] hub = alloc::new_array(allocator, bool, (sz)joints);
	bool[] leaf = alloc::new_array(allocator, bool, (sz)joints);
	defer alloc::free(allocator, leaf);
	{
		usz[] kids = alloc::new_array(allocator, usz, (sz)joints);
		defer alloc::free(allocator, kids);
		for (usz j = 0; j < joints; j++)
		{
			int up = source.parent[j];
			if (up >= 0) kids[(usz)up]++;
		}
		for (usz j = 0; j < joints; j++)
		{
			hub[j] = kids[j] >= 3;
			leaf[j] = kids[j] == 0;
		}
	}
	defer alloc::free(allocator, hub);

	// Where the limbs hang off. Everything above it — an armature node, a floor
	// root, a pelvis pivot — is a single-child run carrying no shape, and is
	// skipped by both sides alike.
	usz source_anchor = anchor_of(source);
	usz plan_anchor = anchor_of(plan);

	usz[] source_leaves = leaves_below(allocator, source, source_anchor);
	usz[] plan_leaves = leaves_below(allocator, plan, plan_anchor);
	defer
	{
		alloc::free(allocator, source_leaves);
		alloc::free(allocator, plan_leaves);
	}
	if (source_leaves.len == 0 || plan_leaves.len == 0) return found;

	// plan dot -> source joint, and the anchors as the one pairing taken as read.
	int[] taken = alloc::new_array(allocator, int, (sz)plan.at.len);
	defer alloc::free(allocator, taken);
	taken[:plan.at.len] = -1;

	taken[plan_anchor] = (int)source_anchor;
	found.dot[source_anchor] = (int)plan_anchor;
	found.matched = 1;

	MatchFrame midline = {
		.plan = plan_at[plan_anchor],
		.source = source_at[source_anchor],
		.trimmed = plan.trimmed,
		.leaf = leaf,
	};

	usz[] pairing = pair_leaves(
		allocator, source, plan, source_at, plan_at,
		source_anchor, plan_anchor, source_leaves, plan_leaves, hub, midline);
	defer alloc::free(allocator, pairing);

	// **Every plan dot that several limbs hang off is fixed first, where those
	// limbs part company on the source.** A branch point is not free to be
	// wherever one chain through it would like: the plan's `chest` carries a head
	// and two arms, so its source joint has to be one every one of those three
	// can still be reached from. Left to a single chain, the first one processed
	// puts it wherever suits that chain alone — measured on a real rig, the left
	// arm took a clavicle for the chest, which then lay on no path to the head or
	// to the other arm and cost both of them their match entirely.
	fix_branches(plan, source, plan_leaves, source_leaves, pairing, plan_anchor, taken, &found);

	// Then the chains, longest first, so the deepest structure is settled before a
	// shorter chain that shares its start gets to fill anything in.
	usz[] order = by_depth(allocator, plan, plan_anchor, plan_leaves);
	defer alloc::free(allocator, order);

	foreach (usz which : order)
	{
		if (pairing[which] == MATCH_NO_LEAF) continue;

		usz[] plan_path = path_between(allocator, plan, plan_anchor, plan_leaves[which]);
		usz[] source_path = path_between(allocator, source, source_anchor, source_leaves[pairing[which]]);
		defer
		{
			alloc::free(allocator, plan_path);
			alloc::free(allocator, source_path);
		}

		assign_along(
			allocator, source_at, plan_at, source_anchor, plan_anchor,
			source_path, plan_path, taken, &found, source.moved, hub, midline);
	}

	tally(plan, &found);
	return found;
}

// The final counts, read off the finished assignment rather than accumulated
// during it.
//
// The passes above raise `matched` as they place dots, which is the natural way
// to write them and the wrong number to end on: what a rig has to cover is the
// plan's *required* dots, and which those are is a property of the plan, not of
// the order the chains happened to be filled in. Counting once at the end is
// also the only version that cannot drift when a pass is added.
fn void tally(MatchShape plan, JointMatch* found) @local
{
	found.matched = 0;
	found.extra = 0;
	found.total = 0;

	for (usz d = 0; d < plan.at.len; d++)
	{
		if (d >= plan.optional.len || !plan.optional[d]) found.total++;
	}

	foreach (int d : found.dot)
	{
		if (d < 0) continue;
		if ((usz)d < plan.optional.len && plan.optional[(usz)d])
		{
			found.extra++;
			continue;
		}
		found.matched++;
	}
}

// No source leaf was good enough for this plan leaf.
const usz MATCH_NO_LEAF @local = (usz)-1;

// ---------------------------------------------------------------------------
// The shape of a skeleton.

// Every joint as a fraction of its own skeleton's longest side, measured from
// the corner of the box the joints occupy.
//
// **One scale for all three axes, not one per axis.** Per-axis would put both
// rigs in a unit cube and look tidier, and it is wrong: a biped is a hand's
// breadth deep and a whole body tall, so dividing depth by its own extent
// multiplies it by ten and a toe six centimetres in front of an ankle lands a
// full unit away. Measured on the test fixture, that made the last link of the
// leg longer than the rest of the leg put together and dragged every dot on it
// down one joint. One scale keeps a direction a direction.
//
// Against the joints rather than against a mesh, because a plan and a source rig
// have to be the same measurement of themselves and only one of them has a mesh.
// A rig with no extent at all comes back at the origin, which costs the same
// against every candidate and so decides nothing.
fn Vec3[] normalized(Allocator allocator, MatchShape shape) @local
{
	Vec3[] out = alloc::new_array(allocator, Vec3, (sz)shape.at.len);
	if (shape.at.len == 0) return out;

	Vec3 low = shape.at[0];
	Vec3 high = shape.at[0];
	foreach (at : shape.at)
	{
		low = { math::min(low.x, at.x), math::min(low.y, at.y), math::min(low.z, at.z) };
		high = { math::max(high.x, at.x), math::max(high.y, at.y), math::max(high.z, at.z) };
	}

	Vec3 extent = high - low;
	float scale = extent.max();
	if (scale <= MATCH_FLAT) return out;

	foreach (usz j, at : shape.at) out[j] = (at - low) / scale;
	return out;
}

// The joint the limbs hang off: the first one, walking down from the root, that
// does not have exactly one child.
//
// A rig's root is often not its hips. `Root -> Hip -> {Pelvis, Waist}` and
// `Armature -> Root -> Hips` both put bookkeeping above the figure, and a single
// child carries no shape to match — a run of them is one bone however many nodes
// it is spelled with. The first branch is where a body starts being a body.
fn usz anchor_of(MatchShape shape) @local
{
	usz at = 0;
	for (usz j = 0; j < shape.at.len; j++)
	{
		if (shape.parent[j] < 0)
		{
			at = j;
			break;
		}
	}

	// Bounded by the joint count rather than looping until it finds a branch: a
	// shape whose parents do not strictly decrease is malformed, and a malformed
	// shape should come back with a poor match rather than never come back.
	for (usz step = 0; step < shape.at.len; step++)
	{
		usz only = 0;
		usz children = 0;
		for (usz j = 0; j < shape.at.len; j++)
		{
			if (shape.parent[j] != (int)at) continue;
			only = j;
			children++;
		}
		if (children != 1) return at;
		at = only;
	}
	return at;
}

// Every joint below `anchor` with no children of its own.
fn usz[] leaves_below(Allocator allocator, MatchShape shape, usz anchor) @local
{
	MatchUszList found;
	found.init(allocator);

	for (usz j = 0; j < shape.at.len; j++)
	{
		if (j == anchor || !descends_from(shape, j, anchor)) continue;

		bool leaf = true;
		for (usz k = 0; k < shape.at.len; k++)
		{
			if (shape.parent[k] == (int)j) leaf = false;
		}
		if (leaf) found.push(j);
	}

	usz[] out = found.to_array(allocator);
	found.free();
	return out;
}

fn bool descends_from(MatchShape shape, usz j, usz anchor) @local
{
	int at = (int)j;
	while (at >= 0)
	{
		if (at == (int)anchor) return true;
		at = shape.parent[at];
	}
	return false;
}

// The joints from `anchor` down to `leaf`, anchor excluded, leaf last.
fn usz[] path_between(Allocator allocator, MatchShape shape, usz anchor, usz leaf) @local
{
	usz depth = 0;
	int at = (int)leaf;
	while (at >= 0 && at != (int)anchor)
	{
		depth++;
		at = shape.parent[at];
	}

	usz[] out = alloc::new_array(allocator, usz, (sz)depth);
	at = (int)leaf;
	for (usz back = depth; back > 0; back--)
	{
		out[back - 1] = (usz)at;
		at = shape.parent[at];
	}
	return out;
}

// How many joints lie between the anchor and each leaf, deepest leaf first.
fn usz[] by_depth(Allocator allocator, MatchShape shape, usz anchor, usz[] leaves) @local
{
	usz[] order = alloc::new_array(allocator, usz, (sz)leaves.len);
	usz[] depth = alloc::new_array(allocator, usz, (sz)leaves.len);
	defer alloc::free(allocator, depth);

	foreach (usz i, leaf : leaves)
	{
		order[i] = i;
		usz steps = 0;
		int at = (int)leaf;
		while (at >= 0 && at != (int)anchor)
		{
			steps++;
			at = shape.parent[at];
		}
		depth[i] = steps;
	}

	// Insertion sort: a rig has a handful of leaves, and a stable order matters
	// more than the sort does.
	sort::insertionsort(order, &deeper_first, depth);
	return order;
}

// ---------------------------------------------------------------------------
// Pairing the chains.

// Which source leaf each plan leaf reaches the same way.
//
// Scored on the direction from the anchor and on how far out the leaf sits, both
// in each rig's own normalized box, and settled by repeatedly taking the best
// remaining pair rather than by walking the plan's leaves in order — a greedy
// pass in list order lets whichever leaf happens to be first claim a chain a
// later one wanted more.
fn usz[] pair_leaves(
	Allocator allocator,
	MatchShape source,
	MatchShape plan,
	Vec3[] source_at,
	Vec3[] plan_at,
	usz source_anchor,
	usz plan_anchor,
	usz[] source_leaves,
	usz[] plan_leaves,
	bool[] hub,
	MatchFrame midline) @local
{
	usz[] pairing = alloc::new_array(allocator, usz, (sz)plan_leaves.len);
	pairing[:plan_leaves.len] = MATCH_NO_LEAF;

	bool[] used = alloc::new_array(allocator, bool, (sz)source_leaves.len);
	float[] source_run = alloc::new_array(allocator, float, (sz)source_leaves.len);
	float[] plan_run = alloc::new_array(allocator, float, (sz)plan_leaves.len);
	defer
	{
		alloc::free(allocator, used);
		alloc::free(allocator, source_run);
		alloc::free(allocator, plan_run);
	}

	// **Scored by laying the chain out, not by where its tip happens to point.**
	// A rig is full of stubs that point where a limb points — a twist bone runs
	// most of the way down the calf it belongs to, and a plan's leg reaches for
	// it as readily as for the foot. Direction and reach cannot separate those:
	// measured on a real 41-joint rig, they put the ankle on a calf twist. What
	// does separate them is trying it — a leg laid along a calf-and-twist costs
	// more than the same leg laid along a calf-and-foot, because the proportions
	// are wrong all the way down. Direction stays on as a gate, so an arm is
	// never even costed against a leg.
	// How far along its own chain each leaf sits, so a limb can be told from the
	// stub beside it. Both signals are needed and neither is enough: laying the
	// chain out catches a stub whose proportions are wrong, and reach catches one
	// whose proportions happen to fit because it is simply a shorter copy of the
	// same shape — which is exactly what a forearm twist is.
	float source_reach = reaches(source, source_at, source_anchor, source_leaves, source_run);
	float plan_reach = reaches(plan, plan_at, plan_anchor, plan_leaves, plan_run);

	while (true)
	{
		float best = MATCH_UNREACHED;
		usz best_dot = MATCH_NO_LEAF;
		usz best_joint = MATCH_NO_LEAF;

		foreach (usz p, plan_leaf : plan_leaves)
		{
			if (pairing[p] != MATCH_NO_LEAF) continue;

			Vec3 plan_arm = plan_at[plan_leaf] - plan_at[plan_anchor];
			float plan_out = plan_reach > MATCH_FLAT ? plan_run[p] / plan_reach : 0.0f;

			usz[] dots = path_between(allocator, plan, plan_anchor, plan_leaf);
			defer alloc::free(allocator, dots);

			foreach (usz s, source_leaf : source_leaves)
			{
				if (used[s]) continue;

				Vec3 source_arm = source_at[source_leaf] - source_at[source_anchor];
				if (!same_side(plan_arm, source_arm)) continue;
				if (agreement(plan_arm, source_arm) < MATCH_MIN_AGREEMENT) continue;

				// Every pair of leaves is priced, each with a path and a table of its
				// own, so the scratch goes to the temp arena and is dropped per pair
				// rather than heap-allocated and freed a few hundred times a match.
				float cost;
				@pool()
				{
					usz[] joints = path_between(tmem, source, source_anchor, source_leaf);
					cost = alignment_cost(
						tmem, source_at, plan_at,
						plan_at[plan_anchor], source_at[source_anchor], dots, joints, {},
						source.moved, hub, true, midline);
				};
				if (cost >= MATCH_UNREACHED) continue;

				float source_out = source_reach > MATCH_FLAT ? source_run[s] / source_reach : 0.0f;
				cost += math::abs(plan_out - source_out);
				if (cost >= best) continue;

				best = cost;
				best_dot = p;
				best_joint = s;
			}
		}

		if (best_dot == MATCH_NO_LEAF) break;
		pairing[best_dot] = best_joint;
		used[best_joint] = true;
	}

	return pairing;
}

// How far along its own chain each leaf sits, and the longest of them.
fn float reaches(MatchShape shape, Vec3[] at, usz anchor, usz[] leaves, float[] out) @local
{
	float longest = 0.0f;
	foreach (usz i, leaf : leaves)
	{
		float run = 0.0f;
		int walk = (int)leaf;
		while (walk >= 0 && walk != (int)anchor)
		{
			int up = shape.parent[walk];
			if (up < 0) break;
			run += (at[walk] - at[(usz)up]).length();
			walk = up;
		}

		out[i] = run;
		if (run > longest) longest = run;
	}
	return longest;
}

// How nearly two offsets point the same way. Zero for a zero-length offset,
// which has no direction to agree about.
fn float agreement(Vec3 a, Vec3 b) @local
{
	float left = a.length();
	float right = b.length();
	if (left < MATCH_FLAT || right < MATCH_FLAT) return 0.0f;
	return (a / left).dot(b / right);
}

// Whether two offsets from the anchor lie on the same side of the body, counting
// the midline as a side of its own. X is lateral everywhere in crig —
// `mirror_at` reflects x and nothing else — so this is the sign of x, and it is
// a hard gate rather than part of the score.
//
// It has to be a gate twice over. Nothing else can tell a left limb from a right
// one: the two point within four degrees of each other and lay out along their
// chains identically, so a matcher scoring only shape takes whichever it reaches
// first and hands back a rig with its legs swapped, which plays every clip
// mirrored. And nothing else keeps a limb *on* the midline from taking one off
// it: measured on a real rig, the plan's neck and head — which lean nowhere, so
// they agree tolerably with anything — took an upper-arm twist that happened to
// lay out more cheaply, which cost the right arm its match as well.
fn bool same_side(Vec3 a, Vec3 b) @local
{
	bool a_central = math::abs(a.x) < MATCH_SIDE_MIN;
	bool b_central = math::abs(b.x) < MATCH_SIDE_MIN;

	if (a_central != b_central) return false;
	if (a_central) return true;
	return (a.x < 0.0f) == (b.x < 0.0f);
}

// ---------------------------------------------------------------------------
// Pinning the branch points.

// Fix each plan dot that more than one limb hangs off to the source joint where
// the chains matched to those limbs diverge.
//
// The lowest common ancestor is exactly the right answer and not an
// approximation: whatever joint drives the plan's chest has to lie on the source
// path to the head *and* on the path to each hand, and the deepest joint that
// does is where the three part company.
fn void fix_branches(
	MatchShape plan,
	MatchShape source,
	usz[] plan_leaves,
	usz[] source_leaves,
	usz[] pairing,
	usz plan_anchor,
	int[] taken,
	JointMatch* found) @local
{
	for (usz d = 0; d < plan.at.len; d++)
	{
		if (d == plan_anchor || taken[d] >= 0) continue;

		usz children = 0;
		for (usz k = 0; k < plan.at.len; k++)
		{
			if (plan.parent[k] == (int)d) children++;
		}
		if (children < 2) continue;

		usz meeting = MATCH_NO_LEAF;
		foreach (usz p, plan_leaf : plan_leaves)
		{
			if (pairing[p] == MATCH_NO_LEAF || !descends_from(plan, plan_leaf, d)) continue;

			usz source_leaf = source_leaves[pairing[p]];
			meeting = meeting == MATCH_NO_LEAF
				? source_leaf
				: common_ancestor(source, meeting, source_leaf);
		}

		// Nothing below it matched, or its limbs meet no lower than the anchor —
		// which is already spoken for, and would put two plan dots on one joint.
		if (meeting == MATCH_NO_LEAF || found.dot[meeting] >= 0) continue;

		taken[d] = (int)meeting;
		found.dot[meeting] = (int)d;
		found.matched++;
	}
}

// The deepest joint both of these hang off.
//
// Walks the higher index up: a parent always sits at a lower index than its
// child, which `MatchShape` requires, so stepping whichever is deeper converges
// without needing either one's depth measured.
fn usz common_ancestor(MatchShape shape, usz a, usz b) @local
{
	while (a != b)
	{
		if (a > b)
		{
			int up = shape.parent[a];
			if (up < 0) return b;
			a = (usz)up;
			continue;
		}

		int up = shape.parent[b];
		if (up < 0) return a;
		b = (usz)up;
	}
	return a;
}

// ---------------------------------------------------------------------------
// Filling in a chain.

// Assign the plan dots on one chain to the source joints on the one it was
// paired with.
//
// The chain is cut at whatever is already settled: an earlier, deeper chain has
// usually placed the shared part — a wrist chain and a head chain share a spine
// — and re-deciding it here would let the two disagree. What is left is a run of
// unplaced plan dots between a fixed start and the leaf, filled in against the
// matching run of source joints by `align_run`.
fn void assign_along(
	Allocator allocator,
	Vec3[] source_at,
	Vec3[] plan_at,
	usz source_anchor,
	usz plan_anchor,
	usz[] source_path,
	usz[] plan_path,
	int[] taken,
	JointMatch* found,
	float[] moved,
	bool[] hub,
	MatchFrame midline) @local
{
	usz plan_from = 0;
	usz start_joint = source_anchor;

	while (plan_from < plan_path.len)
	{
		// A dot that is already settled — the anchor, a pinned branch point, or
		// something an earlier chain through here placed — moves the run's start
		// and is not filled in again.
		if (taken[plan_path[plan_from]] >= 0)
		{
			start_joint = (usz)taken[plan_path[plan_from]];
			plan_from++;
			continue;
		}

		usz run_end = plan_from;
		while (run_end < plan_path.len && taken[plan_path[run_end]] < 0) run_end++;

		usz source_from = start_joint == source_anchor
			? 0
			: after_joint(source_path, start_joint);

		// The run stops where the next settled dot's joint begins, so two runs
		// either side of a pinned branch point cannot both claim the same joints.
		usz source_to = run_end < plan_path.len
			? at_joint(source_path, (usz)taken[plan_path[run_end]])
			: source_path.len;

		if (source_from < source_to && source_to <= source_path.len)
		{
			align_run(
				allocator, source_at, plan_at, start_joint,
				plan_path, plan_from, plan_anchor,
				plan_path[plan_from : run_end - plan_from],
				source_path[source_from : source_to - source_from],
				taken, found, moved, hub,
				// Only a run that ends at the chain's own leaf has a terminal
				// dot; one cut short by a pinned dot is interior throughout.
				run_end == plan_path.len, midline);
		}
		plan_from = run_end;
	}
}

// Where a joint sits on a path, and one past it. Both answer the path's length
// when it is not on the path at all, which leaves the run empty rather than
// letting it run over something that belongs to another chain.
fn usz at_joint(usz[] path, usz joint) @local
{
	usz i = 0;
	while (i < path.len && path[i] != joint) i++;
	return i;
}

fn usz after_joint(usz[] path, usz joint) @local
{
	usz i = at_joint(path, joint);
	return i < path.len ? i + 1 : path.len;
}

<*
 Place a run of plan dots along a run of source joints, keeping their order.

 No joint gets two dots, and a dot never takes a joint above the one its
 predecessor took — a rig cannot have its elbow above its shoulder however the
 numbers come out. That ordering constraint is what makes this a small dynamic
 program rather than a nearest-neighbour sweep, and it is also what makes the
 answer sane when the source has joints the plan does not: the ones left over
 are the folds. A dot the source has no joint for is left unplaced at
 `MATCH_SKIP_PENALTY`, which is how a coarse rig still covers the plan.

 Cost is agreement in how far along the run a joint sits, plus
 `MATCH_POSITION_WEIGHT` times how far apart the two actually are.
*>
fn void align_run(
	Allocator allocator,
	Vec3[] source_at,
	Vec3[] plan_at,
	usz start_joint,
	usz[] plan_path,
	usz plan_from,
	usz plan_anchor,
	usz[] dots,
	usz[] joints,
	int[] taken,
	JointMatch* found,
	float[] moved,
	bool[] hub,
	bool open_ended,
	MatchFrame midline) @local
{
	usz m = dots.len;
	if (m == 0 || joints.len == 0) return;

	usz start_plan = plan_from > 0 ? plan_path[plan_from - 1] : plan_anchor;

	int[] placed = alloc::new_array(allocator, int, (sz)m);
	defer alloc::free(allocator, placed);

	float cost = alignment_cost(
		allocator, source_at, plan_at,
		plan_at[start_plan], source_at[start_joint], dots, joints, placed,
		moved, hub, open_ended, midline);
	if (cost >= MATCH_UNREACHED) return;

	for (usz i = 0; i < m; i++)
	{
		if (placed[i] < 0) continue;
		usz dot = dots[i];
		usz joint = joints[(usz)placed[i]];

		taken[dot] = (int)joint;
		found.dot[joint] = (int)dot;
		found.matched++;
	}
}

<*
 What it costs to lay a run of plan dots along a run of source joints, and — if
 `placed` has room — which joint each dot took, -1 for a dot left unplaced.

 **Where the source run ends is part of the question.** A plan's leg stops at the
 ankle and a source's carries on into a toe; a plan's arm stops at the wrist and
 a source's may carry on into fingers or a twist. Taking the source's own leaf as
 the plan's leaf would place the last dot one joint past where it belongs and
 drag the rest of the chain with it, so every ending is tried and the run is
 measured as a fraction of *that* ending. What is left past the winner folds,
 which is exactly what a toe should do.

 **So is where the plan's run ends.** The same thing the other way round: a
 source leg that stops at the ankle has nothing for a plan's toe, and measuring
 the ankle as a fraction of a leg that runs on to the toe tip would push it
 down onto the source's last joint whatever that is. So every plan ending is
 tried as well, the dots past it left unplaced at `MATCH_SKIP_PENALTY` each.

 An assignment pays `MATCH_STILL_PENALTY` for each interior dot it puts on a
 joint the clips never turn, and `MATCH_HUB_CROSS` for each hub it walks past
 without giving it a dot — see the two constants for why either one, priced on
 proportions alone, wins coin tosses it should lose.

 @param placed : `Receives one source-joint index per plan dot, -1 for one left unplaced; pass an empty slice to only price the fit.`
 @param moved : `Radians each source joint ever turns, indexed like source_at; empty charges no still penalty.`
 @param hub : `Which source joints have three or more children, indexed like source_at; empty charges no crossing penalty.`
 @param open_ended : `True when the last dot is its chain's leaf, which may sit on a still joint free of charge.`
 @param midline : `Each side's anchor, which positions are measured from.`
 @return `The cost, or MATCH_UNREACHED when the run cannot be laid out at all.`
*>
fn float alignment_cost(
	Allocator allocator,
	Vec3[] source_at,
	Vec3[] plan_at,
	Vec3 plan_start,
	Vec3 source_start,
	usz[] dots,
	usz[] joints,
	int[] placed,
	float[] moved,
	bool[] hub,
	bool open_ended,
	MatchFrame midline) @local
{
	usz m = dots.len;
	usz n = joints.len;
	if (m == 0 || n == 0) return MATCH_UNREACHED;

	float[] plan_run = alloc::new_array(allocator, float, (sz)m);
	float[] plan_along = alloc::new_array(allocator, float, (sz)m);
	float[] source_along = alloc::new_array(allocator, float, (sz)n);
	float[] best = alloc::new_array(allocator, float, (sz)((m + 1) * m * n));
	int[] came_from = alloc::new_array(allocator, int, (sz)((m + 1) * m * n));
	int[] trial = alloc::new_array(allocator, int, (sz)m);
	defer
	{
		alloc::free(allocator, plan_run);
		alloc::free(allocator, plan_along);
		alloc::free(allocator, source_along);
		alloc::free(allocator, best);
		alloc::free(allocator, came_from);
		alloc::free(allocator, trial);
	}

	running_length(plan_at, plan_start, dots, plan_run);
	running_length(source_at, source_start, joints, source_along);

	float[] shifted = alloc::new_array(allocator, float, (sz)n);
	defer alloc::free(allocator, shifted);

	// **And so is where the source run begins, for a limb.** A plan's leg starts
	// at a thigh beside its hips; a source's may reach it through pelvis pivots
	// stacked down the midline first — the file measured drops its hip joints
	// two fifths of a leg below the joint its legs hang off. Measured from that
	// joint, every leg joint sits a third of the way further down its chain than
	// the plan's does, and the thigh slides off onto the knee. So when the
	// plan's first dot leans off the midline, the source joints on the midline
	// before it may be folded away and the run measured from the last of them.
	// Only those: a joint off the midline is already part of the limb.
	bool plan_leans = math::abs(plan_at[dots[0]].x - midline.plan.x) >= MATCH_SIDE_MIN;

	float lowest = MATCH_UNREACHED;
	for (usz first = 0; first < n; first++)
	{
		if (first > 0 && (!plan_leans
			|| math::abs(source_at[joints[first - 1]].x - midline.source.x) >= MATCH_SIDE_MIN)) break;

		float base = first > 0 ? source_along[first - 1] : 0.0f;
		usz left = n - first;
		for (usz j = 0; j < left; j++) shifted[j] = source_along[first + j] - base;
		usz[] run = joints[first:left];

		// A truncation keeping almost none of the run is not a shorter chain, it
		// is a different one, and it has to be refused rather than scored.
		// Refused *relative to the run*, not against a fixed epsilon: rigs
		// routinely stack a pivot on top of its parent — the file measured has
		// its root, its pelvis and its waist at one coordinate — and stopping the
		// run there leaves a source length of five hundred-thousandths, which is
		// far above any absolute floor and still satisfies arc length perfectly,
		// because whatever the run ends on sits at fraction one by construction.
		// That is how a spine came to be a zero-length bone on top of the hips.
		float shortest = shifted[left - 1] * MATCH_MIN_RUN;

		// Exactly as many dots go unplaced as the run is short of joints — never
		// more, so a source that has a joint for every dot places every dot the
		// way it always did, and the skip is only ever the answer to a joint
		// that is not there. Which dots those are is the cost's to decide: off
		// the end, like a toe, or from the middle, like a second spine segment.
		usz short_by = m > left ? m - left : 0;

		for (usz kept = m; kept > 0 && m - kept <= short_by; kept--)
		{
			float plan_total = plan_run[kept - 1];
			if (plan_total <= MATCH_FLAT) continue;
			for (usz i = 0; i < kept; i++) plan_along[i] = plan_run[i] / plan_total;
			usz inside = short_by - (m - kept);
			if (inside >= kept) continue;
			float dropped = (float)(m - kept) * MATCH_SKIP_PENALTY;

			for (usz end = 0; end < left; end++)
			{
				float total = shifted[end];
				if (total <= MATCH_FLAT || total < shortest) continue;

				float cost = align_prefix(
					source_at, plan_at, dots[:kept], run, plan_along, shifted, total, end + 1, inside,
					best, came_from, trial, moved, open_ended, midline);
				if (cost >= MATCH_UNREACHED) continue;
				cost += dropped;

				// Each hub above the last dot that no dot landed on: the run
				// swallowed a junction and kept going, which is how a wrist ends
				// up on a finger.
				if (hub.len > 0)
				{
					for (usz k = 0; k < first + (usz)trial[kept - 1]; k++)
					{
						if (!hub[joints[k]]) continue;
						bool landed = false;
						for (usz i = 0; i < kept; i++)
						{
							if (trial[i] >= 0 && first + (usz)trial[i] == k) { landed = true; break; }
						}
						if (!landed) cost += MATCH_HUB_CROSS;
					}
				}
				if (cost >= lowest) continue;

				lowest = cost;
				if (placed.len >= m)
				{
					for (usz i = 0; i < m; i++)
					{
						placed[i] = i < kept && trial[i] >= 0 ? (int)(first + (usz)trial[i]) : -1;
					}
				}
			}
		}
	}
	return lowest;
}

// One ordered assignment of the plan dots onto the first `count` source joints,
// passing over exactly `skips` of them, and what it costs. `placed` comes back
// holding the joint each dot took, -1 for one passed over; the last dot is always
// placed, since it is where the run was measured to.
//
// Cost is agreement in how far along the run a joint sits, plus
// `MATCH_POSITION_WEIGHT` times how far apart the two actually are, plus
// `MATCH_SKIP_PENALTY` for each dot passed over. The ordering constraint — a dot
// never takes a joint above the one its predecessor took — is what makes this a
// small dynamic program rather than a nearest-neighbour sweep, and it is also
// what keeps an elbow from landing above its shoulder.
//
// `best[(s * m + i) * n + j]` is the cheapest way to place dot `i` on joint `j`
// with `s` of the dots before it passed over and the rest placed higher up;
// `came_from` holds the index of the state it continued from, -1 for a dot with
// every dot above it passed over. Both need room for `(skips + 1) * m * n`.
fn float align_prefix(
	Vec3[] source_at,
	Vec3[] plan_at,
	usz[] dots,
	usz[] joints,
	float[] plan_along,
	float[] source_along,
	float total,
	usz count,
	usz skips,
	float[] best,
	int[] came_from,
	int[] placed,
	float[] moved,
	bool open_ended,
	MatchFrame midline) @local
{
	usz m = dots.len;
	usz n = joints.len;
	if (m == 0 || count == 0 || skips >= m) return MATCH_UNREACHED;

	for (usz i = 0; i < m; i++)
	{
		for (usz j = 0; j < count; j++)
		{
			Vec3 plan_off = plan_at[dots[i]] - midline.plan;
			Vec3 source_off = source_at[joints[j]] - midline.source;
			float here = math::abs(plan_along[i] - source_along[j] / total)
				+ MATCH_POSITION_WEIGHT * (plan_off - source_off).length();

			// An interior dot on a joint the clips never turn is a helper wearing
			// a limb's proportions. The chain's own leaf is exempt: a hand keyed
			// flat is still the wrist.
			if (moved.len > 0 && !(open_ended && i == m - 1) && moved[joints[j]] < MATCH_STILL_MIN)
			{
				here += MATCH_STILL_PENALTY;
			}

			bool plan_central = math::abs(plan_off.x) < MATCH_SIDE_MIN;
			bool source_central = math::abs(source_off.x) < MATCH_SIDE_MIN;
			if (!plan_central && source_central) here += MATCH_MIDLINE_PENALTY;

			if (dots[i] < midline.trimmed.len && midline.trimmed[dots[i]]
				&& joints[j] < midline.leaf.len && midline.leaf[joints[j]])
			{
				here += MATCH_TRIMMED_LEAF;
			}

			for (usz s = 0; s <= skips; s++)
			{
				usz state = (s * m + i) * n + j;

				// Every dot above this one passed over, or the cheapest placed one
				// higher up the source with the dots between them passed over.
				float carried = s == i ? (float)i * MATCH_SKIP_PENALTY : MATCH_UNREACHED;
				int from = -1;
				for (usz earlier = 0; earlier < i; earlier++)
				{
					usz passed = i - earlier - 1;
					if (passed > s) continue;
					usz before = s - passed;
					for (usz k = 0; k < j; k++)
					{
						float through = best[(before * m + earlier) * n + k];
						if (through >= MATCH_UNREACHED) continue;
						through += (float)passed * MATCH_SKIP_PENALTY;
						if (through >= carried) continue;
						carried = through;
						from = (int)((before * m + earlier) * n + k);
					}
				}

				best[state] = carried >= MATCH_UNREACHED ? MATCH_UNREACHED : carried + here;
				came_from[state] = from;
			}
		}
	}

	float lowest = MATCH_UNREACHED;
	int last = -1;
	for (usz j = 0; j < count; j++)
	{
		usz state = (skips * m + (m - 1)) * n + j;
		if (best[state] >= lowest) continue;
		lowest = best[state];
		last = (int)state;
	}
	if (last < 0) return MATCH_UNREACHED;

	placed[:m] = -1;
	int at = last;
	while (at >= 0)
	{
		usz dot = ((usz)at / n) % m;
		placed[dot] = (int)((usz)at % n);
		at = came_from[(usz)at];
	}
	return lowest;
}

// The distance from `start` along a run to each of its entries.
fn void running_length(Vec3[] at, Vec3 start, usz[] run, float[] out) @local
{
	Vec3 previous = start;
	float total = 0.0f;

	foreach (usz i, entry : run)
	{
		total += (at[entry] - previous).length();
		previous = at[entry];
		out[i] = total;
	}
}

fn int deeper_first(usz a, usz b, usz[] depth) @local => depth[a] > depth[b] ? -1 : (depth[a] < depth[b] ? 1 : 0);

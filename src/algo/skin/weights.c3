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
 some with the paint multipliers on, some without — and two tools asked the same
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

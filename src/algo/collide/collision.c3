<* The pure half of src/app/collision.c3: no state, undo or notices. *>
module crig;

import rig;
import collision;
import std::math;
import std::math::quaternion;
import std::collections::list;
import std::time;

<*
 What counts as touching, as a fraction of the picker's bounds diagonal.

 A small visible clearance rather than exact contact, scaled from the mesh so
 a model in millimetres and one in metres are held off by the same visible
 gap: half a percent of the diagonal is about a centimetre on a standing
 human. The Advanced section will let a rig override it; until then this is
 the one number.
*>
const float COLLISION_CLEARANCE = 0.005f;

<*
 How finely a blocked move is bisected between the last clear rotation and
 the request. Eight halvings put the joint within 1/256 of the requested
 sweep from the surface — a third of a degree on a quarter turn — for eight
 regional refits. Three is what a mesh over budget gets: an eighth of the
 sweep, coarse but still a stop rather than a pass.

 That is the most a search costs, not what every search costs: the halvings
 stop once the interval left is under `COLLISION_SEARCH_RESOLUTION`. A
 pointer moves a joint a degree or two between frames, and bisecting that
 to the full depth would put the joint within a thousandth of a degree of
 the surface — six tests to learn nothing the clearance does not already
 hide. A quarter of a degree is a few millimetres at a limb's length, under
 the clearance on any figure, and three halvings of a pointer step reach it.
*>
const usz COLLISION_SEARCH_STEPS = 8;

const usz COLLISION_SEARCH_STEPS_REDUCED = 3;

const float COLLISION_SEARCH_RESOLUTION = (float)(0.25 * math::PI / 180);

<*
 Seconds one checked write may take before the check is cut back. Only a
 blocked write costs more than one test — a clear one is a refit and a
 measurement — so this is the frame a hand pressed against the body may
 take, not the frame a free one does: a tenth of a second is a stutter
 while pushing, where the joint is visibly stopped anyway, and a mesh that
 needs longer than that for its bisection is what the reduced check is
 for. A single test over this is a mesh the check cannot follow at all.
*>
const float COLLISION_TIME_BUDGET = 0.1f;

<*
 How far inside the clearance a gesture's start has to be before the
 gesture is left unchecked. A blocked gesture leaves its joint just clear
 of the surface, and the pose the next one begins from is that one keyed
 and sampled back — the same rotation to within rounding, which is enough
 to put a gap that was a hair over the clearance a hair under it. Read at
 face value that would suspend every second gesture against the body, and
 the joint would pass through on the one that pushes. So a start counts
 as in contact only when it is well inside: a crossing, or a pose that
 came from a clip or an unchecked gesture with the skin actually folded.
*>
const float COLLISION_SUSPEND_FRACTION = 0.5f;

<*
 How much of the check a mesh is getting. `REDUCED` bisects coarsely and
 skips the careful IK pass; `PAUSED` checks nothing until the control is
 toggled or the skin rebound.
*>
enum CollisionMode : char
{
	FULL,
	REDUCED,
	PAUSED,
}

fn String CollisionMode.label(self)
{
	switch (self)
	{
		case FULL: return "full";
		case REDUCED: return "reduced";
		case PAUSED: return "paused";
	}
}

// The most anyone may ask for: past twelve halvings a float cannot tell the
// candidates apart.
const usz MAX_COLLISION_SEARCH_STEPS = 12;

<*
 One contact the narrow phase found: which pair, where, and how close.
*>
struct CollisionContact
{
	bool hit;
	DeformedTrianglePair pair;
	TriangleGap gap;
}

<*
 What one blocked write met — the readout's, the tests' and C5's account of
 the check.
*>
struct CollisionBlock
{
	// A check ran: blocking is on, a policy is built, and the gesture did not
	// begin in contact.
	bool tested;
	// The request was cut short. `fraction` says how much of it was accepted;
	// zero is a joint that stayed where it was.
	bool blocked;
	float fraction;
	// Narrow-phase passes this write cost.
	usz tests;
	// The nearest contact that stopped it, for drawing.
	CollisionContact contact;
	// A pull: how far the grabbed joint still is from the target once the
	// solve stopped, and whether that is more than the solver's tolerance —
	// the target is out of reach, the mesh in the way or not.
	float residual;
	bool unreached;
	// What the write cost, and what the last narrow phase sorted its pairs
	// into — the diagnostics the Advanced section shows.
	float seconds;
	CollisionPairCounts counts;
	// The mode the write ran under.
	CollisionMode mode;
	// The pose stamp the contact was drawn against: the ring shows while the
	// displayed pose is still this one, and goes with the first scrub, step of
	// history or new gesture that replaces it.
	uint shown_at;
}

<*
 The joints `joint` carries, in the skeleton's order — itself and every
 descendant. What a turn moves, and so what a refit and a broad phase are
 asked about.

 The caller owns the result.
*>
fn uint[] subtree_joints(Allocator allocator, rig::Skeleton* skeleton, usz joint)
{
	usz count = skeleton.len();
	if (joint >= count) return {};
	// One sweep: joints are ordered parents-before-children, so a parent's
	// answer is known by the time its child asks.
	bool[] inside = mem::new_array(bool, (sz)count);
	defer mem::free(inside);
	List{uint} moving;
	moving.init(allocator);
	defer moving.free();
	for (usz j = joint; j < count; j++)
	{
		int parent = skeleton.parents[j];
		inside[j] = j == joint || (parent >= 0 && (usz)parent < j && inside[(usz)parent]);
		if (inside[j]) moving.push((uint)j);
	}
	return moving.to_array(allocator);
}

<*
 Bisect between `low`, a fraction already tested clear, and 1, which is not.
 The body tries the pose at `middle` and writes whether it was clear into
 `*settled`, and the contact it met into `*contact`; the nearest contact that
 stopped the search is kept on the report.

 @return `The largest fraction found clear.`
*>
macro float @bisect_clear(CollisionBlock* report, CollisionContact* contact, float low, usz steps, bool* settled; @probe(float middle))
{
	float high = 1.0f;
	for (usz step = 0; step < steps; step++)
	{
		float middle = (low + high) * 0.5f;
		report.tests++;
		@probe(middle);
		if (*settled)
		{
			low = middle;
		}
		else
		{
			high = middle;
			if (!report.contact.hit || contact.gap.distance < report.contact.gap.distance) report.contact = *contact;
		}
	}
	return low;
}

<*
 How far the tip of a chain has to be able to move for the chain not to
 count as pinned, in clearances. A solve toward a target inside the body
 answers with a pose far inside it, and the smallest fraction of that the
 depth would resolve moves the tip a fraction of a millimetre: clear more
 often than not, and then the whole search runs to land it there. A tip
 that cannot advance half a clearance is at the surface already, which is
 what pinned means, and half a clearance is under what the eye can see.
*>
const float PINNED_TIP_TRAVEL = 0.5f;

<*
 The joints on either side of a contact, by the dot names the rig gives
 them — "LeftHand" and "Spine1" — or "" for a triangle no joint weights.
*>
fn String contact_region_name(RigDocument* doc, CollisionPolicy* collision_policy, DeformedCollisionSurface* deformed_surface, uint triangle)
{
	uint region = deformed_surface.region_for_triangle(triangle);
	usz joint = (usz)region;
	if (joint >= collision_policy.dot_ids.len) return "";
	Dot* dot = doc.find(collision_policy.dot_ids[joint]);
	return dot ? dot.name : "";
}

// The clearance this rig measures against, as a fraction of the diagonal.
fn float collision_clearance_fraction(RigDocument* doc) => doc.collision_clearance > 0.0f
	? doc.collision_clearance
	: COLLISION_CLEARANCE;

fn float collision_clearance(RigDocument* doc, Picker* picker) => picker.scale * collision_clearance_fraction(doc);


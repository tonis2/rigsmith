<* The pure half of src/app/pose_mode.c3: no state, undo or notices. *>
module crig;

import rig;
import std::time;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::collections::list;
import collision::ik;

<*
 The longest run of joints one gesture may turn, and the snapshot that holds
 them.

 A bound rather than a guess: `Skeleton.ancestor_run` walks unbranched ancestors,
 and no rig anybody places by hand has sixteen joints in a row with nothing
 hanging off any of them. The snapshot is one longer because the joint being
 grabbed is in it too — it is not turned, but it may be slid, and either way
 escape has to put it back.
*>
const usz IK_MAX_CHAIN = 16;

const usz POSE_SNAPSHOT = IK_MAX_CHAIN + 1;

// How many other selected joints one G carries along; see `gather_pose_mates`.
const usz POSE_MATES = 16;

struct PoseMate
{
	uint dot;
	Vec3 from; // where it stood when the grab began
}

<*
 One joint in the transient animation draft, keyed by the document dot id so a
 freshly built `RigView` can map it back to the clip's joint order.

 This is editor working memory only. Saved poses live exclusively as animation
 keyframes; the rig document stores no current pose.
*>
struct PosedJoint
{
	uint dot_id;
	Quaternionf rotation;
	Vec3 offset;
}

<*
 The grabbed joint and the unbranched run of joints above it, in this rig's joint
 order: what a finger curls along, what a selected mate is carried by, and what
 the MCP's target solve bends. A body gesture moves far more than this
 (`pose_body`).

 Short-lived, like the `RigView` it was read out of — joint indices are that
 build's BFS output and mean nothing after the next dot edit. What outlives the
 gesture is written back by dot id.
*>
struct PoseChain
{
	usz effector;               // the grabbed joint; it is aimed, never turned
	usz count;                  // how many ancestors turn, nearest first
	usz[IK_MAX_CHAIN] joints;
}

<*
 How close a solve has to get before it stops early, as a fraction of the rig's
 height.

 Against the rig rather than in model units, the same rule every other epsilon
 in crig follows: a model authored in centimetres and one in metres are the same
 figure, and a fixed distance would be a different demand on each.
*>
const float IK_TOLERANCE = 0.002;

const uint POSE_IK_PASSES = 12;

<*
 A chain no longer than this share of the figure's height is a digit — a finger,
 a toe, a tail tip — and curls rather than reaches.

 Measured by length, not by name: an arm's run is a third of the height and a
 leg's more than half, a finger's is under five percent. The line is drawn at
 a tenth, which a hand's longest finger clears three times over and no limb comes
 near. The binder's digits (`rig::DIGIT_CHAIN_SHARE`) are drawn at the same line.
*>
const float CURL_CHAIN_SHARE = 0.1f;

// A curl is reached by smaller steps, so it spends more of them.
const uint CURL_PASS_FACTOR = 4;

const float POSE_IK_MAX_STEP = 0.5;

// Whether any joint of `chain`'s ancestor run is already claimed — the conflict
// test that stands a lower-priority anchor down.
fn bool run_wants_claimed(PoseChain chain, uint[] claimed)
{
	for (usz t = 0; t < chain.count; t++)
	{
		if (array::contains(claimed, (uint)chain.joints[t])) return true;
	}
	return false;
}

// Add `joint` to the claim buffer if it is new and there is room, returning the
// count after. A silent stop past the buffer's length under-claims rather than
// overrunning, which can only miss a conflict on a rig pinned past `LOCK_SNAPSHOT`.
fn usz claim_joint(uint[] buf, usz count, uint joint)
{
	if (array::contains(buf[:count], joint)) return count;
	if (count >= buf.len) return count;
	buf[count] = joint;
	return count + 1;
}

<*
 How near to straight, or to the root-effector line, a pole may be before it
 names no bend to aim.

 A pole is defined only when the limb is meaningfully bent and the pole sits
 meaningfully off the line from the chain root to the effector. Both are read as
 a sine — a perpendicular offset over the arm it turns on — so the one threshold
 serves a fingertip and a leg alike and does not drift as a rig is scaled up or
 down, the rule every epsilon in crig follows (see `IK_TOLERANCE`). About a
 degree of bend, or of lean off the line.
*>
const float POLE_MIN_SINE = 0.02;

<*
 What `aim_chain_pole` made of a pole, so a caller can report it honestly.

 A pole is a hint, not a demand, and several honest shapes of limb leave it with
 nothing to do: a limb with one bend has no elbow or knee to point, a straight
 limb has no bend off the line to swing, a folded limb whose effector has come
 back onto its root has no line to swing about, and a pole on that line itself
 names no side. Each leaves the pose untouched. AIMED_TO_LIMIT is a real aim the
 root pivot's own limits cut short — the bend went as far toward the pole as the
 joint allows, and the effector may have drifted the residual reports.
*>
enum PoleAim
{
	AIMED,
	AIMED_TO_LIMIT,
	NO_BEND,
	COINCIDENT,
	STRAIGHT,
	POLE_ON_LINE,
}

<*
 The skeleton joint represented by one point in an anchor-first pose chain.

 `ancestor_run` stores the pivots nearest-first, while CCD stores the same
 points anchor-first and appends the effector. Keeping that reversal in one
 helper prevents the solver and its world-rotation update from disagreeing
 about which joint a point belongs to.
*>
fn usz pose_chain_joint(PoseChain chain, usz point) @private
{
	return point < chain.count
		? chain.joints[chain.count - 1 - point]
		: chain.effector;
}

<*
 Where a digit's tip can go when it curls towards `target`, along the line from
 the chain's anchor to `target`.

 The pointer asks for a direction from the knuckle as much as a place. A finger
 that follows it curls — every joint bends by the same turn, the way a finger
 closes — and a curl is shorter than the straight finger it started as. So the
 target's distance is cut to the chord that curl has, when it is further than
 that: the solve then aims at a place the curled finger reaches rather than at
 one only the straight finger comes near. A target already inside the curl's
 chord is left where it is.

 With `n` bones turning at `n` joints, bone `j` has turned `j` times the one
 step by the time it is reached, and the chord points along their average, which
 is `(n + 1) / 2` steps, so for a chord turned by `angle` the step is
 `2 * angle / (n + 1)`.

 @param points : `Anchor first and tip last, as the solver reads them.`
*>
fn Vec3 curl_target(Vec3[] points, Vec3 target)
{
	usz bones = points.len - 1;
	Vec3 chord = points[bones] - points[0];
	Vec3 want = target - points[0];
	float straight = chord.length();
	float distance = want.length();
	if (bones < 2 || straight <= 0.0f || distance <= 0.0f) return target;

	float cosine = math::clamp(chord.dot(want) / (straight * distance), -1.0f, 1.0f);
	float angle = (float)math::acos((double)cosine);
	float step = 2.0f * angle / (float)(bones + 1);

	float along = 0.0f;
	float across = 0.0f;
	for (usz j = 1; j <= bones; j++)
	{
		float length = (points[j] - points[j - 1]).length();
		along += length * (float)math::cos((double)(step * (float)j));
		across += length * (float)math::sin((double)(step * (float)j));
	}
	float reach = math::sqrt(along * along + across * across);
	if (distance <= reach) return target;
	return points[0] + want * (reach / distance);
}

// The length of the polyline through `points`.
fn float chain_length(Vec3[] points)
{
	float total = 0.0f;
	for (usz i = 1; i < points.len; i++) total += (points[i] - points[i - 1]).length();
	return total;
}

// What a grabbed joint keeps of its angle while it is posed.
enum PoseHold : char
{
	FOLLOW, // a limb's joint: its angle to its parent, so a forearm turns with the upper arm
	FOOT,   // a foot: its world angle, so it stays flat as it stood
	TRUNK,  // the root and the spine: their world angle, Alt or not
}

// Whether the grab holds its world rotation, with Alt (`flip`) swapping a limb's.
fn bool PoseHold.keeps_world(self, bool flip) => self == TRUNK || (self == FOOT) != flip;

// How far above the joint a gait plants a foot by its ankle may still stand, as a
// share of the figure's height: a man's ankle over the ball of his foot, not his knee.
const float POSE_FOOT_SHARE @local = 0.12f;

// The tree root above `joint`. Joints are ordered parents first, so the climb ends.
fn usz tree_root_of(rig::Skeleton* skeleton, usz joint)
{
	usz walk = joint;
	while (skeleton.parents[walk] >= 0) walk = (usz)skeleton.parents[walk];
	return walk;
}

// Whether `a` is `b` or one of its ancestors. Joints are ordered parents first.
fn bool at_or_above(rig::Skeleton* skeleton, usz a, usz b)
{
	for (int walk = (int)b; walk >= 0; walk = skeleton.parents[(usz)walk])
	{
		if ((usz)walk == a) return true;
	}
	return false;
}

// Whether `joint` is at or below a joint the gesture holds.
fn bool under_the_gesture(rig::Skeleton* skeleton, PointGoal[] gesture, usz joint)
{
	foreach (goal : gesture) if (at_or_above(skeleton, goal.joint, joint)) return true;
	return false;
}

// Which goal holds `joint`, or -1.
fn sz body_goal_of(PointGoal[] goals, usz joint)
{
	foreach (usz g, goal : goals) if (goal.joint == joint) return (sz)g;
	return -1;
}

<*
 Whether `joint` is on the same limb as a hold that already says where it is: it
 hangs below one, or one hangs below it.

 A hold that is a position and a hard angle fixes everything below it — a toe
 under a foot pinned flat — and a second one there would only fight it. A position
 alone fixes the point and leaves the part free to turn (softly held, not fixed),
 so the toe below it still needs its own hold, or the foot could roll off it. A
 joint above a held position is on the limb either way.
*>
fn bool rides_a_pin(rig::Skeleton* skeleton, PointGoal[] goals, usz joint)
{
	foreach (goal : goals)
	{
		if (!goal.position || goal.soft) continue;
		if (at_or_above(skeleton, joint, goal.joint)) return true;
		bool angle_held = goal.rotation && goal.turn_weight <= 0.0f;
		if (angle_held && at_or_above(skeleton, goal.joint, joint)) return true;
	}
	return false;
}

// Contacts a ground spec can name for one gesture; a spec longer than this is cut.
const usz GROUND_CONTACT_MAX = 16;

<*
 Whether a grab on this chain's joint curls it as a digit instead of moving the
 body: a run at least one joint long that, with everything hanging below the
 grabbed joint, is no longer end to end than `CURL_CHAIN_SHARE` of the figure's
 height — a finger, a toe's tip. Its knuckle is the fork it hangs from, and a
 finger closing does not lean the body. A short run with the chest and the arms
 below it is no digit.
*>
fn bool digit_chain(RigView* view, PoseChain chain)
{
	if (chain.count == 0) return false;
	rig::Skeleton* skeleton = &view.skeleton;
	float length = 0.0f;
	usz below = chain.effector;
	foreach (above : chain.joints[:chain.count])
	{
		length += (skeleton.joints[below] - skeleton.joints[above]).length();
		below = above;
	}
	// And the longest way down from the grabbed joint. Parents come first, so one
	// pass backwards sees every child before its parent.
	usz n = skeleton.len();
	float[] reach = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, reach);
	for (usz i = n; i > chain.effector + 1; i--)
	{
		usz j = i - 1;
		int parent = skeleton.parents[j];
		if (parent < (int)chain.effector) continue;
		float down = reach[j] + (skeleton.joints[j] - skeleton.joints[(usz)parent]).length();
		reach[(usz)parent] = math::max(reach[(usz)parent], down);
	}
	return length + reach[chain.effector] <= skeleton.height() * CURL_CHAIN_SHARE;
}

<*
 Whether `target` asks a digit to open: the pointer is nearer, in angle about
 the anchor, to where the chain points when straight than the tip is now.

 Straight is the rest chord carried by the anchor's parent, so it is the finger
 laid out from the knuckle however the hand is turned. A finger at rest is
 already straight, and a pointer anywhere off that line closes it.

 @param points : `Anchor first and tip last, as the solver reads them.`
*>
fn bool digit_opening(RigView* view, PoseChain chain, Quaternionf[] world, Vec3[] points, Vec3 target)
{
	usz anchor = pose_chain_joint(chain, 0);
	usz effector = pose_chain_joint(chain, points.len - 1);
	int parent = view.skeleton.parents[anchor];
	Vec3 rest = view.skeleton.joints[effector] - view.skeleton.joints[anchor];
	Vec3 straight = parent >= 0 ? world[(usz)parent].rotate_vec3(rest) : rest;
	Vec3 chord = points[points.len - 1] - points[0];
	Vec3 want = target - points[0];
	if (straight.length() <= 0.0f || chord.length() <= 0.0f || want.length() <= 0.0f) return false;
	straight = straight.normalize();
	float now = chord.normalize().dot(straight);
	float asked = want.normalize().dot(straight);
	// A hair of slack so a pointer held still is not read as opening by noise.
	return asked > now + 1.0e-4f;
}

<*
 Writes `rotation` to `pivot` and carries the chain below it by the world
 step that actually results. Positions and orientations below the pivot must
 see the same permitted step: updating only the pose would make the rest of
 the solve continue against forbidden geometry.
*>
fn void carry_pivot(
	RigView* view,
	PoseChain chain,
	rig::Pose* pose,
	Vec3[] points,
	Quaternionf[] world,
	usz pivot,
	Quaternionf rotation) @private
{
	usz tip = chain.count;
	usz joint = pose_chain_joint(chain, pivot);
	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0
		? world[(usz)parent]
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf before_world = world[joint];
	Quaternionf after_world = parent_world.mul(rotation).normalize();
	Quaternionf actual = after_world.mul(before_world.invert()).normalize();
	pose.rotations[joint] = rotation;

	for (usz point = pivot + 1; point <= tip; point++)
	{
		points[point] = points[pivot] + actual.rotate_vec3(points[point] - points[pivot]);
	}
	for (usz point = pivot; point <= tip; point++)
	{
		usz carried = pose_chain_joint(chain, point);
		world[carried] = actual.mul(world[carried]).normalize();
	}
}

<*
 Each joint's `PoseHold`: the trunk by the same reading `pose_body` gives the
 solve, the feet by the one a gait finds them by (`gait_find_feet`). That is the
 joint the floor meets — the ball of a foot with toes — so the leg's joints just
 above it, near the floor still, are the foot too: the ankle a hand grabs. A
 wrist is a limb joint like any other, so a dragged hand turns with its forearm.
*>
fn PoseHold[] pose_holds(Allocator allocator, RigView* view, float height)
{
	usz n = view.skeleton.len();
	PoseHold[] holds = alloc::new_array(allocator, PoseHold, (sz)n);
	bool[] trunk = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, trunk);
	float[] inv_mass = alloc::new_array(mem, float, (sz)n);
	defer alloc::free(mem, inv_mass);
	point_pose_masses(&view.skeleton, height, inv_mass, trunk, fork_carry: false);
	usz[GAIT_FEET_MAX] feet;
	usz count = gait_find_feet(&view.skeleton, view.names, feet[..]);
	foreach (foot : feet[:count])
	{
		GaitLeg leg;
		if (!gait_leg_of(&view.skeleton, foot, &leg)) continue;
		float floor = view.skeleton.joints[foot].y;
		// Never the leg's top two: the hip and the knee bend the leg, not the foot.
		for (usz i = leg.bones; i >= 2; i--)
		{
			usz j = leg.joints[i];
			if (view.skeleton.joints[j].y - floor > POSE_FOOT_SHARE * height) break;
			holds[j] = FOOT;
		}
	}
	foreach (j, is_trunk : trunk) if (is_trunk) holds[j] = TRUNK;
	return holds;
}

<*
 The run above a dot: the joint, and the ancestors `ancestor_run` walks up to the
 first fork — the limb as the rig's own shape draws it.
*>
fn PoseChain pose_chain(RigView* view, uint dot)
{
	PoseChain chain;
	sz joint = view.joint_of(dot);
	if (joint < 0) return chain;
	chain.effector = (usz)joint;
	chain.count = view.skeleton.ancestor_run((usz)joint, chain.joints[..]);
	return chain;
}

<*
 Turn a joint so its world orientation matches `held`, whatever its parents are
 now doing.

 A joint's world rotation is its parent's composed with its own, so holding the
 world at `held` means setting the local to `parent_world^-1 * held` — the same
 change of frame `pose_toward`'s pivot step runs, at one joint and with no target
 but the orientation itself. Constrained through the joint's limits when it has
 them, so a held foot never lands out of range; free otherwise, since most feet
 are. Nothing below is written — the subtree follows through `joint_palette`.
*>
fn void hold_world_rotation(RigDocument* doc, RigView* view, rig::Pose* pose, uint dot_id, Quaternionf held)
{
	sz found = view.joint_of(dot_id);
	if (found < 0) return;
	usz joint = (usz)found;

	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
	Quaternionf local = parent_world.invert().mul(held).normalize();

	JointRotationLimits limits = doc.rotation_limits_of(dot_id);
	if (limits.constrained)
	{
		JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		if (frame.usable()) local = constrain_joint_rotation(frame, limits, local);
	}
	pose.rotations[joint] = local;
}

<*
 Where the chain's joints stand for `pose`, anchor first and effector last —
 the points the solver turns, and what it reads back after a cut pass.
*>
fn void chain_points(RigView* view, PoseChain chain, rig::Pose pose, Vec3 ground_shift, Vec3[] points)
{
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	for (usz t = 0; t < chain.count; t++)
	{
		usz j = chain.joints[chain.count - 1 - t];
		points[t] = view.skeleton.joints[j].transform(palette[j]) + ground_shift;
	}
	points[chain.count] = view.skeleton.joints[chain.effector].transform(palette[chain.effector]) + ground_shift;
}

<*
 Twist a limb's bend so its elbow or knee points toward `pole`.

 	`PoleAim done = app.aim_chain_pole(&view, &pose, chain, pole);`

 Which way a two-bone limb bends is free once it has reached its target: every
 turn of the limb about the line from its root to the effector reaches the same
 point, and only swings the elbow or knee round that line. This is the pole
 vector a game rig gives — it turns the chain's root pivot about that line until
 the first bend lies in the plane the pole names. The effector is *on* the line,
 so it does not move; only the bend swings. One turn, not a search: the reach it
 follows (`solve_limited_pose_chain`) owns the iteration budget; this is a single
 shortest arc, so the same request gives the same bend every time.

 Run after the reach, on the pose it left. Constrained through the root pivot's
 own limits, so the twist never lands it out of range; when a limit clamps it
 short the effector can drift, and the answer is `AIMED_TO_LIMIT` so the caller
 says so alongside the residual.

 The `PoleAim` says what happened. Every degeneracy is measured relative to the
 arm it turns on (`POLE_MIN_SINE`), never an absolute distance, so the reading
 holds at any scale of rig: a chain with one bend or none is `NO_BEND`, a folded
 chain whose effector has met its root is `COINCIDENT`, a straight limb is
 `STRAIGHT`, and a pole on the root-effector line is `POLE_ON_LINE`. Only `AIMED`
 and `AIMED_TO_LIMIT` write into `pose`; the subtree follows through
 `joint_palette`.
*>
fn PoleAim aim_chain_pole(RigDocument* doc, RigView* view, rig::Pose* pose, PoseChain chain, Vec3 pole)
{
	if (chain.count < 2) return NO_BEND;

	Vec3[IK_MAX_CHAIN + 1] points;
	chain_points(view, chain, *pose, {}, points[:chain.count + 1]);
	Vec3 root = points[0];
	Vec3 mid = points[1];
	Vec3 tip = points[chain.count];

	// The upper bone is the scale every test below reads against: a perpendicular
	// offset shorter than `POLE_MIN_SINE` of it is no bend, or a pole with no side,
	// whether the rig is a centimetre or a kilometre.
	float arm = (mid - root).length();
	if (arm <= 0.0f) return STRAIGHT;
	float floor = arm * POLE_MIN_SINE;

	Vec3 axis = tip - root;
	if (axis.length() <= floor) return COINCIDENT;
	Vec3 line = axis.normalize();

	// Each joint's offset from the root, with the part along the line removed: the
	// bend as it stands, and the side the pole names. Either being small against
	// its own arm means there is no plane to turn — a straight limb, or a pole on
	// the line.
	Vec3 have = mid - root;
	have = have - line * have.dot(line);
	if (have.length() <= floor) return STRAIGHT;
	Vec3 want = pole - root;
	float reach = (pole - root).length();
	want = want - line * want.dot(line);
	if (want.length() <= reach * POLE_MIN_SINE) return POLE_ON_LINE;

	// The turn about the line that carries the bend onto the pole's side — both
	// perpendicular to the line, so the shortest arc between them is about it.
	Quaternionf turn = ik::shortest_arc(have, want);

	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return NO_BEND;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);

	usz joint = pose_chain_joint(chain, 0);
	int parent = view.skeleton.parents[joint];
	Quaternionf parent_world = parent >= 0
		? world[(usz)parent]
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf candidate = parent_world.invert().mul(turn).mul(world[joint]).normalize();

	JointRotationLimits limits = doc.rotation_limits_of(view.dot_ids[joint]);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	Quaternionf constrained = constrain_joint_rotation(frame, limits, candidate);
	pose.rotations[joint] = constrained;

	// The turn survived its limits when the constrained rotation still matches the
	// one the pole wanted, up to sign (the quaternion double cover). Short of that,
	// a limit cut it and the effector may have drifted.
	return math::abs(constrained.v.dot(candidate.v)) > 0.9999999f ? AIMED : AIMED_TO_LIMIT;
}

<*
 What a grab on `dot` keeps of its angle by the rig's shape alone, before its
 Keep angle cell or Alt. `FOLLOW` for a dot that is no joint of the rig.
*>
fn PoseHold pose_hold(RigDocument* doc, rig::TriMesh* geometry, rig::MeshShells* shells, uint dot)
{
	RigView? opened = open_rig(doc, geometry, shells, mem);
	if (catch opened) return FOLLOW;
	RigView view = opened;
	defer view.free(mem);
	sz joint = view.joint_of(dot);
	if (joint < 0) return FOLLOW;
	PoseHold[] holds = pose_holds(mem, &view, view.skeleton.height());
	defer alloc::free(mem, holds);
	return holds[(usz)joint];
}

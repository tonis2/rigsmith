<*
 The body solver: one damped least-squares solve that poses the whole body.

 	`float miss = body_solve(&skeleton, &pose, joints, goals, &settings);`

 The joints in play, the goals and the settings go in (`PointJoint`, `PointGoal`
 and `PointPoseSettings`, in `point_pose.c3`); the pose is solved in place, and
 each goal's residual and the largest position miss come out.

 **Why a solve.** Every demand on the body — the grab, the pins, the floor, the
 balance, and the wish to stay as it was — is a number that grows with how far the
 pose is from it, and the answer is the pose that makes their weighted sum least.
 That is a function of the inputs alone: nothing is kept from the last mouse move,
 and nothing is chosen between. A pull against a limit or a pin has no pass that
 speaks last; it is one more term in the sum.

 **What is solved.** Small turns of joints, so every pose the solve passes through
 is a real one — bones their own length, forward kinematics doing the carrying:

   the root       its move (three) and its turn (three, about the world's axes)
   a joint        one unknown per axis its limits *allow*, the angle itself on that
                  axis of its limit frame (x and z the swing across the bone, y the
                  twist about it, see `joint_angles_from_rotation`), so a knee hinge
                  has one unknown and cannot roll, a shoulder has three, and a joint
                  without limits turns about the parent's three axes

 A joint is solved when it lies above a goal or a floored joint, when it holds a
 world rotation, or — with the balance on and something stood on — when it is part
 of the trunk. Every other joint keeps its rotation and rides what carries it, and
 a frozen (aimed) joint is fixed.

 **What it asks of them.** Residuals, each squared and weighted:

   the grab        its joint's distance from the pointer, weight 1
   a pin           the same, weight `POINT_POSE_PIN`; so heavy that the grab gives
                   way to it, not the other way round
   an angle        the turn from the held world rotation, as an arc of
                   `POINT_POSE_TURN_LENGTH` of the height: hard (`turn_weight` of
                   zero) is as heavy as a pin, soft is the weight it names — the
                   grab's hold on its part, a pin's hold on its foot
   the floor       how far a floored joint is under it, which is nothing above it
   the balance     how far the centre of mass stands outside the outline of what
                   the body stands on, which is nothing inside it
   stiffness       every part of the body pulled back toward where it stood when
                   the gesture began, by its mass; and every unknown a little toward
                   the angle it began with

 Stiffness is what makes the body a puppet. It is far smaller than the grab, so it
 does not decide whether the pointer is reached, only which joints do the
 reaching. Its main part is a displacement: each part of the body, taken at the
 middle of its joint and its children (a tip at the joint itself), is held where it
 stood, by its mass, in the frame the root carries — so the whole body going along
 costs nothing, and a part left behind costs its mass times the square of how far.
 A turn then costs the mass it swings times its lever squared: a light forearm
 answers a pull before a heavy pelvis does, and a thigh stays unless it must. It is
 summed from the parts under each joint (`part_rows`), not a row for each part.

 What a displacement cannot see is asked in angle (`joint_rows`), and is small:

   a limb joint   a floor in proportion to its table mass: all that is asked of a
                  twist about a bone, and what keeps a knee from folding the other
                  way on a long pull. It is a twentieth of that for the joint a
                  grab is on and the one it hangs from — a pull on a knuckle is the
                  wrist's to answer, and the arm swings only for the rest
   a trunk joint  much stiffer, a spine of several joints as stiff as one, and
                  stiffest against leaning to the side and twisting: it pitches to
                  sit and to reach and does not wander; a body in the air, held by
                  nothing, lets it go
   the root       its turn drawn back hard, so a pull on the waist drops the body
                  instead of tipping it; its slide by a Huber cost, quadratic up to a
                  hair's breadth and linear past it, so a pull the limbs can answer
                  does not move the body and one they cannot is followed

 That is what the displacement alone could not do; each constant says which test needs it.

 **How it is solved.** Levenberg–Marquardt. The derivatives are analytic
 (`axis × (point − pivot)` for a point, the axis itself for an angle; for a limited
 joint the axes are those `limit_angle_axes` gives, the swing-twist angles' own, so
 the model and the limits agree at every angle), the normal equations are solved by a small dense Cholesky, and a step is
 taken only when it makes the sum smaller — else the damping grows and the step
 shortens. Every step is capped, and a limited joint's angles are held in their
 ranges, so the solve never leaves the allowed region and a joint that meets its
 limit slides along it: the joints above it turn instead. An unknown on its limit
 and pushed further out is held for that step, as an active set would; so is a
 floored joint a step would carry through the floor.

 **Continuity.** The grab is carried from where its joint stands to the pointer in
 a few sub-steps of the same solve, and pins are on from the first, so a far pull
 is a short walk and a small pull a small move. An early sub-step stops once the
 model promises less than a ten-thousandth of its cost more
 (`BODY_SOLVE_EARLY_SAVING`), the last at a millionth: one left unsettled hands the
 next a pose between two answers, and the body twitches as it chooses. A straight
 leg is singular — no first-order bend direction — so a one-sided hinge that stands
 closed is started bent a little the way it opens (`POINT_POSE_SEED`), the joint
 above it turning to keep what hangs below in place; so is a joint a grab is pulled
 straight along (`seed_straight_pulls`). That is only where the solve starts: the
 pull back toward where it began straightens a limb that is not squeezed.

 **Exactness.** The pins come out within a hair of their points. A short closing
 polish — limited CCD over each pinned limb, the root slid by what remains, and
 the hard angles set again — takes up the rest, so a pin is held exactly or
 reported as missed. A pin whose point is out of its limb's reach at the start
 stands down and does not drag the body after it.

 **The balance** stands the centre of mass over what the body stands on, and is
 careful what that is. A pinned ankle is one point, and two make a line a body can
 only balance on by standing exactly over it; but a foot has a sole, so the toes
 below a pinned ankle, the ankle above a planted toe, a heel behind an ankle whose
 angle is held hard (`POINT_POSE_HEEL`), and a margin round it all
 (`POINT_POSE_SOLE`) are what the body is asked to stand over. And a figure that
 stands off its feet to begin with — one foot pinned, the weight between the two —
 is not thrown onto them at the first touch of the pointer: where its centre stood as
 the solve began is on the outline, and it is only kept from going further out.

 Pure: it reads the skeleton and writes only the pose handed to it.
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;

// A pin's say in where its joint goes, against a grab's `POINT_POSE_GRAB` of 1.
const float POINT_POSE_PIN = 1.0e3;

// The arc an angle is weighed over, as a share of the height: one radian of miss
// counts as this much of a position miss.
const float POINT_POSE_TURN_LENGTH = 0.1;

// How readily a part of the body is moved from where the gesture found it, against a
// grab's 1, per unit of its mass: the part's mass, at the middle of its joint and its
// children, held where it stood — measured in the frame the root carries, so the whole
// body going along is no displacement, a part left behind is. A turn then costs the
// mass it swings times its lever squared, and a light part answers a pull before a
// heavy one. Trades the body's say against the grab's: three times as much and the
// body hangs back from the pointer (`locks::a_chair_sit_holds_the_feet_and_undoes_in_one_step`,
// `locks::sitting_back_leans_the_body_over_the_feet`,
// `ui::posing_bends_the_limb_and_barely_moves_the_fork`); a third as much and the arm
// swings with nothing to say otherwise (`pose_mass::a_knuckle_pulled_turns_the_hand_not_the_arm`).
const float POINT_POSE_STIFFNESS = 1e-3;

// The least a part weighs, in the table's units, where the table says only "a limb":
// a table mass is one more than the part's own (`BodySolve.mass`), and the rig's
// shape alone says a hand and a fingertip are both 1. Keeps the part in the stiffness
// at a hundredth of a trunk joint, so a hand moves with its arm and not the other way.
// No test moves at a third of it or three times it.
const float POINT_POSE_LIGHT = 1e-2;

// How hard a limb joint's own turn is drawn back toward its angle at the start, per
// unit of its table mass: all that is asked of a turn that moves no part — a twist
// about a bone — and what keeps a knee from folding the other way on a long pull.
// Against `POINT_POSE_STIFFNESS` it is the larger for a joint near the end of a limb.
// Trades a limb's smoothness against its readiness to turn: at half of it a straight
// leg's first bend jumps (`puppet::pin_angle_feet_stay_flat_past_the_ankle_limit`,
// `puppet::there_and_back_returns_exactly`, `puppet::a_grounded_figure_sits_on_flat_feet`);
// at five times it the trunk and the hand stop answering (`body_solve::a_free_hand_reaches_and_the_trunk_stays`,
// `pinning::four_pinned_hooves_crouch_on_the_midline`, `pose_mass::the_heavier_hand_moves_less`).
const float POINT_POSE_LIMB_TURN = 2e-3;

// What share of that floor a limb joint keeps while a grab works on it directly: the
// joint the grabbed point is on, and the one that point hangs from. A pull on a
// knuckle is first the wrist's to answer and the finger's to hold its facing, and the
// arm swings only for what they cannot do; at the full floor a light hand turns less
// than the heavy arm swings, which is the wrong way round
// (`pose_mass::a_knuckle_pulled_turns_the_hand_not_the_arm` fails above about 0.15). No
// test fails with none of the floor left; a twentieth keeps a twist about the bone drawn back.
const float POINT_POSE_PIVOT_EASE = 0.05;

// The same for a trunk joint (the spine, a torso with nothing on it), per unit of its
// table mass, and how many times stiffer it is against a lean to the side and a twist
// than a pitch. A figure on its feet pitches at the waist to sit and reach and stays
// upright otherwise; without these a waist pulled down folds the spine rather than
// dropping the hips (`locks::pulling_the_waist_sits_a_t_pose_down`), and the dog's chest
// wanders off the midline (`pinning::four_pinned_hooves_crouch_on_the_midline`).
const float POINT_POSE_TRUNK_TURN = 0.023;
const float POINT_POSE_TRUNK_STRAIGHT = 8.0;

// A trunk joint's stiffness while nothing is planted below the root: a body in the air
// is not holding itself up, so its trunk answers a pull like any limb
// (`collision_block::a_pull_stops_at_the_mesh_...`).
const float POINT_POSE_TRUNK_FLOATING = 1.0e-2;

// How hard the root's own turn is drawn back toward the angle it began with, per unit
// of its table mass: the pelvis does not tip to take a pull the legs and the spine can
// take (`puppet::spine_down_sits_on_position_pinned_ankles`, `locks::...hips_drop...`).
const float POINT_POSE_ROOT_TURN = 0.66;

// The root's slide, and how it is paid for. It costs as much as a grab until it has
// gone `POINT_POSE_SLIDE_WIDTH` of the height, and grows only linearly past that: the
// body does not move for a pull a limb can answer, then follows a pull it must answer
// to within the width. Of the order of `IK_TOLERANCE`, which it must stay under
// (`collision_block::a_pull_stops_at_the_mesh_...`), and wide enough that the first
// small pulls of a straight leg are not all taken up at once
// (`puppet::pin_angle_feet_stay_flat_past_the_ankle_limit`).
const float POINT_POSE_SLIDE = 1.0;
const float POINT_POSE_SLIDE_WIDTH = 1.2e-3;

// How many times dearer the root's slide is while a body in the air is still being
// carried to the pointer: the limbs and the trunk reach first, and the root follows in
// the last sub-step with what is left (`collision_block::a_pull_that_begins_in_contact_...`).
const float POINT_POSE_FLOATING_SLIDE = 1.0e3;

// How far behind a pinned ankle the heel runs, as a share of the foot's length from the
// ankle to its toes: the sole is longer than the joints that name it.
const float POINT_POSE_HEEL = 0.3;

// The balance's say, against a grab's 1: how hard the centre of mass is drawn back
// when it has gone past the margin below.
const float POINT_POSE_BALANCE_PULL = 1.0;

// How far past the feet's outline, as a share of the height, the centre of mass may
// stand before the balance minds: the sole is wider and longer than the joints that
// name it.
const float POINT_POSE_SOLE = 0.01;

// The weight of the hold a grab keeps on its own part's world rotation, and of
// the soft hold a position pin keeps on its part's: the part goes where it is
// pulled and stays as it faces. A pin's is the heavier — the foot stays flat
// while the pull is still being answered.
const float POINT_POSE_GRAB_HOLD = 5.0;
const float POINT_POSE_PIN_SOFT_TURN = 30.0;

// Sub-steps the grab is carried over, from where its joint stands to the pointer.
const int POINT_POSE_RAMP = 3;
int diag_ramp;
double diag_cost;
double diag_cost_polished;
double[8] diag_terms;
int diag_iters;
int diag_rejects;
int diag_accepts;
bool diag_trace;
double diag_floor = -1.0;
int diag_iterations;
double diag_saving = -1.0;
double diag_early = -1.0;
usz diag_pull_joint;
int diag_pull_axis;
double diag_pull_value;
double diag_pull_weight;
int diag_early_iterations;
DString diag_log;


// Trial steps the last sub-step may take, and the most an earlier one takes before
// going on: the early ones only point the way, so they stop at a share of their
// cost (`BODY_SOLVE_EARLY_SAVING`) the model says is left to gain.
const int BODY_SOLVE_ITERATIONS = 40;
const int BODY_SOLVE_EARLY_ITERATIONS = 15;
const double BODY_SOLVE_EARLY_SAVING = 1.0e-4;

// The share of the cost the model must still promise for the last sub-step to go
// on, and the least worth promising: float forward kinematics is exact to about
// this.
const double BODY_SOLVE_SAVING = 1.0e-6;
const double BODY_SOLVE_NOISE = 1.0e-13;

// The largest turn a step may make of any joint, in radians, and the farthest it
// may slide the root, as a share of the height.
const float POINT_POSE_MAX_STEP = 0.25;
const float POINT_POSE_MAX_SLIDE = 0.05;

// The damping each sub-step starts from, and the least it is eased to, as a share
// of each unknown's own curvature.
const double BODY_SOLVE_DAMPING = 1.0e-3;
const double BODY_SOLVE_DAMPING_FLOOR = 1.0e-4;

// How far a one-sided hinge that is closed, or bent the wrong way, is started bent
// the way it opens, in radians: far enough that the pull has something to push on.
const float POINT_POSE_SEED = 0.25;

// How near its limit an angle must be, in radians, to count as standing on it.
const float BODY_SOLVE_ON_LIMIT = 1.0e-5;

// How near the floor, as a share of the height, a floored joint has to be to rest on it.
const float BODY_SOLVE_RESTING = 1.0e-3;

// ---------------------------------------------------------------------------
// The working state

// One unknown: a small turn of a joint, or a slide of the root.
struct BodySolveUnknown @local
{
	usz joint;
	bool slide;              // the root's move along `axis` (model space), not a turn
	Vec3 axis;               // a turn's axis: in the parent's frame for a joint, the world's for the root
	float stiff;             // the weight of its pull back toward where it began
	float scale;             // its pull's residual per unit: the turn's arc, or one over the height
	int limit;               // the limit axis it turns about, or -1 when unlimited
}

// A pose being tried: local rotations, and the points and world rotations they carry.
struct BodySolveState @local
{
	Quaternionf[] local;
	Quaternionf[] world;
	Vec3[] x;
	Vec3[] rest;             // offset from the parent, in the parent's frame; a root's is its position
	Vec3[] angles;           // a limited joint's limit angles, which its local rotation is rebuilt from
}

fn BodySolveState body_solve_state(usz n) @local
{
	return {
		.local = alloc::new_array(tmem, Quaternionf, (sz)n),
		.world = alloc::new_array(tmem, Quaternionf, (sz)n),
		.x = alloc::new_array(tmem, Vec3, (sz)n),
		.rest = alloc::new_array(tmem, Vec3, (sz)n),
		.angles = alloc::new_array(tmem, Vec3, (sz)n),
	};
}

<*
 Every joint placed from the rotations and the root alone: the walk
 `joint_palette` does, parents first.
*>
fn void BodySolveState.walk(&self, rig::Skeleton* skeleton)
{
	foreach (usz j, parent : skeleton.parents)
	{
		if (parent < 0)
		{
			self.x[j] = self.rest[j];
			self.world[j] = self.local[j];
			continue;
		}
		usz p = (usz)parent;
		self.x[j] = self.x[p] + self.world[p].rotate_vec3(self.rest[j]);
		self.world[j] = self.world[p].mul(self.local[j]).normalize();
	}
}

fn void BodySolveState.copy_from(&self, BodySolveState* other)
{
	self.local[..] = other.local[..];
	self.world[..] = other.world[..];
	self.x[..] = other.x[..];
	self.rest[..] = other.rest[..];
	self.angles[..] = other.angles[..];
}

<*
 The turn that is `q`, as axis times angle and the short way round: the log of a
 unit quaternion, near zero when `q` is near the identity.
*>
fn Vec3 body_solve_log(Quaternionf q) @local
{
	Vec3 v = { q.v.x, q.v.y, q.v.z };
	float w = q.v.w;
	if (w < 0.0f)
	{
		w = -w;
		v = -v;
	}
	float s = v.length();
	if (s < 1.0e-9f) return v * 2.0f;
	return v * (2.0f * (float)math::atan2(s, w) / s);
}

// A unit rotation as a matrix, by rows.
fn Vec3[3] body_solve_matrix(Quaternionf q) @local
{
	float x = q.v.x;
	float y = q.v.y;
	float z = q.v.z;
	float w = q.v.w;
	return {
		{ 1.0f - 2.0f * (y * y + z * z), 2.0f * (x * y - w * z), 2.0f * (x * z + w * y) },
		{ 2.0f * (x * y + w * z), 1.0f - 2.0f * (x * x + z * z), 2.0f * (y * z - w * x) },
		{ 2.0f * (x * z - w * y), 2.0f * (y * z + w * x), 1.0f - 2.0f * (x * x + y * y) },
	};
}

// The rotation turning by `spin` radians about its own axis.
fn Quaternionf body_solve_turn(Vec3 spin) @local
{
	float angle = spin.length();
	if (angle < 1.0e-12f) return quaternion::IDENTITY;
	return quaternion::from_axis_angle{float}(spin / angle, angle);
}

<*
 The axes, in the parent's frame, that the three limit angles of a joint turn it
 about when each is raised alone: how `rotation_from_joint_angles` composes them.

 It builds basis · (exp((x, 0, z)) · Ry(y)) · basis⁻¹, a swing S with rotation
 vector s = (x, 0, z) after a twist about Y. With the increment of the whole
 rotation on the left (dR = [ω]× R), as the solve carries it:

   y   turns the twist under the swing, so ω = S · Ŷ
   x   exp(s + δ) = exp(J δ) · exp(s), J the left Jacobian of the rotation vector,
   z   so ω = J · X̂ and J · Ẑ; the twist under it rides along unchanged

 J = I + ((1 − cos θ)/θ²) [s]× + ((θ − sin θ)/θ³) [s]×², θ = |s|: the identity at
 θ = 0, and without a singularity short of a full turn. Each ω is then carried out
 of the frame by `basis`. A change to the composition has to change this too;
 `limit_axes_follow_the_angles` in test/body_solve_test.c3 checks the two against
 each other.
*>
fn Vec3[3] limit_angle_axes(Quaternionf basis, Vec3 angles)
{
	Vec3 s = { angles.x, 0.0f, angles.z };
	double theta = (double)s.length();
	// The coefficients of [s]× and [s]×², in double: both are a small difference of
	// large numbers once θ is small, and by a milliradian the series is exact.
	double c1 = 0.5;
	double c2 = 1.0 / 6.0;
	if (theta > 1.0e-3)
	{
		c1 = (1.0 - math::cos(theta)) / (theta * theta);
		c2 = (theta - math::sin(theta)) / (theta * theta * theta);
	}
	Vec3[2] columns = { { 1, 0, 0 }, { 0, 0, 1 } };
	Vec3[2] swept;
	foreach (i, e : columns)
	{
		Vec3 a = s.cross(e);
		Vec3 b = s.cross(a);
		swept[i] = e + a * (float)c1 + b * (float)c2;
	}
	Quaternionf swing = body_solve_turn(s);
	return {
		basis.rotate_vec3(swept[0]),
		basis.rotate_vec3(swing.rotate_vec3({ 0, 1, 0 })),
		basis.rotate_vec3(swept[1]),
	};
}

<*
 Solve (`a`) x = `b` for a symmetric positive-definite `a`, n by n and row
 major: `b` is replaced by x, and the lower triangle of `a` by its Cholesky
 factor.

 @return `False when the matrix is not positive definite.`
*>
fn bool body_solve_cholesky(double[] matrix, double[] b, usz n) @local
{
	double* a = matrix.ptr;
	double* x = b.ptr;
	for (usz j = 0; j < n; j++)
	{
		double* row_j = a + j * n;
		double d = row_j[j];
		for (usz k = 0; k < j; k++) d -= row_j[k] * row_j[k];
		if (!(d > 1.0e-30)) return false;
		double l = math::sqrt(d);
		row_j[j] = l;
		for (usz i = j + 1; i < n; i++)
		{
			double* row_i = a + i * n;
			double s = row_i[j];
			for (usz k = 0; k < j; k++) s -= row_i[k] * row_j[k];
			row_i[j] = s / l;
		}
	}
	for (usz i = 0; i < n; i++)
	{
		double* row_i = a + i * n;
		double s = x[i];
		for (usz k = 0; k < i; k++) s -= row_i[k] * x[k];
		x[i] = s / row_i[i];
	}
	for (usz r = n; r > 0; r--)
	{
		usz i = r - 1;
		double s = x[i];
		for (usz k = i + 1; k < n; k++) s -= a[k * n + i] * x[k];
		x[i] = s / a[i * n + i];
	}
	return true;
}

// The sums over the parts under a joint that the stiffness is written in: with them
// the whole body's part-by-part cost is a matrix of the unknowns, not a row each.
struct BodySolveMoment @local
{
	double w;                // Σ w
	double[3] c;             // Σ w c
	double[3] r;             // Σ w r
	double[3] x;             // Σ w (c × r)
	double[6] q;             // Σ w c cᵀ: xx yy zz xy xz yz
}

fn void BodySolveMoment.add(&self, BodySolveMoment* other)
{
	self.w += other.w;
	for (usz i = 0; i < 3; i++)
	{
		self.c[i] += other.c[i];
		self.r[i] += other.r[i];
		self.x[i] += other.x[i];
	}
	for (usz i = 0; i < 6; i++) self.q[i] += other.q[i];
}

struct BodySolve @local
{
	rig::Skeleton* skeleton;
	PointJoint[] joints;
	PointGoal[] goals;
	PointPoseSettings* settings;
	usz n;
	float h;
	Vec3 up;
	float pin;                    // a pin's weight this sub-step
	bool active;                  // anything to solve at all
	bool balance_on;
	sz[] slot;                    // per joint: its PointJoint, or -1 when not in play
	usz[] children;               // per joint: how many joints hang from it
	usz[] root_of;
	float[] table;                // per joint: its mass in the table `PointJoint.inv_mass` gives
	float[] mass;                 // per joint: what the stiffness holds in place — the table's less one, at the least `POINT_POSE_LIGHT`
	bool grounded;                // something hard is planted below the root: the figure stands on it
	float slide_boost;            // how many times dearer the root's slide is for now (`POINT_POSE_FLOATING_SLIDE` early on)
	bool[] reached;               // per joint: it is moved by some unknown, its own turn or one above it
	bool[] weighed;               // per joint: it is in play and reached, so its mass is in the stiffness
	BodySolveMoment[] moments;    // per joint: the sums over the parts at and under it
	sz[] carrier;                 // per joint: the solved joint it rides rigidly on if nothing is solved at or under it, else -1
	Vec3[] carried_at;            // and where it sits in that joint's frame
	bool[] carries;               // per joint: something rides on it
	Vec3[3][] turn_of;            // per joint that carries: its world rotation as a matrix, rows, for the placing in hand
	Vec3[] centre;                // per joint: where its part's mass stands in the state being read
	Vec3[] centre_sum;            // scratch for it: the sum of its children's points
	Vec3[] anchor_centre;         // and where it stood in the anchor pose
	bool[] framed;                // its turn is solved, or would be but for freezing; a root: anything below it is held
	bool[] turns;                 // a non-root joint with unknowns
	usz[] first;                  // per joint: its first unknown
	usz[] count;                  // and how many
	BodySolveUnknown[] unknowns;
	usz nu;
	usz[] order;                  // the joints a pose has to be placed for, parents first: what the residuals read
	usz order_count;
	bool[] live;                  // per goal: on a joint in play
	bool[] use_pos;               // per goal: its position counts
	bool[] use_rot;               // and its angle
	bool[] ramped;                // a soft position, carried to its target over the sub-steps
	Vec3[] from;                  // per goal: where its joint stood
	Vec3[] aim;                   // per goal: where its position is asked for, this sub-step
	sz[] pin_of;                  // per joint: a hard position standing on it, or -1
	sz[] rot_of;                  // per joint: a goal holding its world rotation, or -1
	BodySolveState cur;
	BodySolveState trial;
	BodySolveState began;         // the pose handed in
	Quaternionf[] anchor;         // per joint: what the stiffness pulls back toward
	Vec3[] anchor_angles;         // and the same as limit angles, for a limited joint
	Quaternionf[] basis;          // per limited joint: its limit frame
	// The normal equations.
	double[] mat;
	double[] work;
	double[] grad;
	double[] delta;
	double extra;                 // what the floor rows added for a step would cost now, which the cost does not count
	bool[] resting;               // per PointJoint: a floored joint whose floor row is in the equations for this state
	bool[] fixed;                 // per unknown: against its limit and pushed on, dropped from the step
	int[] bound;                  // per unknown: 1 on its upper limit, -1 on its lower, else 0
	Vec3[] axes;                  // per unknown: its turn's axis in the world
	usz[] jc;                     // one residual's derivatives: the unknowns it depends on
	Vec3[] jv;                    // and by how much
	// The balance.
	float[] balance_mass;
	float balance_total;
	Vec3[POINT_POSE_SUPPORTS] stands;
	usz stand_count;
	float[] sub_mass;
	Vec3[] sub_moment;
}

fn PointJoint* BodySolve.joint_of(&self, usz j) => &self.joints[(usz)self.slot[j]];

// `local` put inside joint `j`'s limits, when it has any.
fn Quaternionf BodySolve.limited(&self, usz j, Quaternionf local)
{
	PointJoint* pj = self.joint_of(j);
	return pj.limited() ? constrain_joint_rotation(pj.frame, pj.limits, local) : local.normalize();
}

fn void BodySolve.open(&self, rig::Skeleton* skeleton, rig::Pose* pose, PointJoint[] joints, PointGoal[] goals,
	PointPoseSettings* settings)
{
	usz n = skeleton.len();
	self.skeleton = skeleton;
	self.joints = joints;
	self.goals = goals;
	self.settings = settings;
	self.n = n;
	self.h = settings.height > 0.0f ? settings.height : 1.0f;
	self.up = settings.up.length_sq() > 1.0e-12f ? settings.up.normalize() : (Vec3){ 0, 1, 0 };
	self.slot = alloc::new_array(tmem, sz, (sz)n);
	self.children = alloc::new_array(tmem, usz, (sz)n);
	self.root_of = alloc::new_array(tmem, usz, (sz)n);
	self.table = alloc::new_array(tmem, float, (sz)n);
	self.mass = alloc::new_array(tmem, float, (sz)n);
	self.slide_boost = 1.0f;
	self.reached = alloc::new_array(tmem, bool, (sz)n);
	self.weighed = alloc::new_array(tmem, bool, (sz)n);
	self.moments = alloc::new_array(tmem, BodySolveMoment, (sz)n);
	self.carrier = alloc::new_array(tmem, sz, (sz)n);
	self.carried_at = alloc::new_array(tmem, Vec3, (sz)n);
	self.carries = alloc::new_array(tmem, bool, (sz)n);
	self.turn_of = alloc::new_array(tmem, Vec3[3], (sz)n);
	self.centre = alloc::new_array(tmem, Vec3, (sz)n);
	self.centre_sum = alloc::new_array(tmem, Vec3, (sz)n);
	self.anchor_centre = alloc::new_array(tmem, Vec3, (sz)n);
	self.framed = alloc::new_array(tmem, bool, (sz)n);
	self.turns = alloc::new_array(tmem, bool, (sz)n);
	self.first = alloc::new_array(tmem, usz, (sz)n);
	self.count = alloc::new_array(tmem, usz, (sz)n);
	self.unknowns = alloc::new_array(tmem, BodySolveUnknown, (sz)(n * 3 + 6));
	self.order = alloc::new_array(tmem, usz, (sz)n);
	self.live = alloc::new_array(tmem, bool, (sz)goals.len);
	self.use_pos = alloc::new_array(tmem, bool, (sz)goals.len);
	self.use_rot = alloc::new_array(tmem, bool, (sz)goals.len);
	self.ramped = alloc::new_array(tmem, bool, (sz)goals.len);
	self.from = alloc::new_array(tmem, Vec3, (sz)goals.len);
	self.aim = alloc::new_array(tmem, Vec3, (sz)goals.len);
	self.pin_of = alloc::new_array(tmem, sz, (sz)n);
	self.rot_of = alloc::new_array(tmem, sz, (sz)n);
	self.anchor = alloc::new_array(tmem, Quaternionf, (sz)n);
	self.anchor_angles = alloc::new_array(tmem, Vec3, (sz)n);
	self.basis = alloc::new_array(tmem, Quaternionf, (sz)n);
	self.balance_mass = alloc::new_array(tmem, float, (sz)n);
	self.sub_mass = alloc::new_array(tmem, float, (sz)n);
	self.sub_moment = alloc::new_array(tmem, Vec3, (sz)n);
	self.cur = body_solve_state(n);
	self.trial = body_solve_state(n);
	self.began = body_solve_state(n);

	for (usz j = 0; j < n; j++)
	{
		self.slot[j] = -1;
		self.pin_of[j] = -1;
		self.rot_of[j] = -1;
	}
	foreach (usz i, pj : joints) if (pj.joint < n) self.slot[pj.joint] = (sz)i;

	// Where everything stands: the walk `joint_palette` does.
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		self.cur.local[j] = pose.rotations[j];
		if (parent < 0)
		{
			self.root_of[j] = j;
			self.cur.rest[j] = skeleton.joints[j] + pose.offsets[j];
		}
		else
		{
			self.root_of[j] = self.root_of[(usz)parent];
			self.cur.rest[j] = skeleton.joints[j] - skeleton.joints[(usz)parent] + pose.offsets[j];
			self.children[(usz)parent]++;
		}
	}
	self.cur.walk(skeleton);
	self.began.copy_from(&self.cur);
	bool posture = settings.posture.len == n;
	for (usz j = 0; j < n; j++) self.anchor[j] = posture ? settings.posture[j] : pose.rotations[j];
	for (usz j = 0; j < n; j++)
	{
		if (self.slot[j] < 0) continue;
		float inv = self.joint_of(j).inv_mass;
		self.table[j] = inv > 1.0e-4f ? 1.0f / inv : 1.0e4f;
		self.mass[j] = math::max(self.table[j] - 1.0f, POINT_POSE_LIGHT);
	}

	// The goals, each on a joint in play. A hard position out of its limb's reach
	// when the solve begins cannot be held by anything the limb does: it stands
	// down and reports its miss rather than dragging the body after it.
	foreach (usz g, &goal : goals)
	{
		goal.residual = 0.0f;
		goal.turn_residual = 0.0f;
		goal.stood_down = false;
		if (goal.joint >= n || self.slot[goal.joint] < 0) continue;
		self.live[g] = true;
		if (goal.position)
		{
			if (goal.soft || self.in_reach(goal.joint, goal.target))
			{
				self.use_pos[g] = true;
				self.ramped[g] = goal.soft;
				if (!goal.soft) self.pin_of[goal.joint] = (sz)g;
			}
			else
			{
				goal.stood_down = true;
			}
		}
		self.use_rot[g] = goal.rotation;
		if (goal.rotation) self.rot_of[goal.joint] = (sz)g;
		self.from[g] = self.cur.x[goal.joint];
		self.aim[g] = goal.target;
	}

	self.grounded = self.stands_on_something();
	// The joints a grab works on directly: the one it grabs and the one it hangs from.
	bool[] pivots = alloc::new_array(tmem, bool, (sz)n);
	foreach (usz g, goal : goals)
	{
		if (!self.live[g] || !self.use_pos[g] || !goal.soft) continue;
		pivots[goal.joint] = true;
		int parent = skeleton.parents[goal.joint];
		if (parent >= 0) pivots[(usz)parent] = true;
	}
	// Framed: every joint in play above a goal or a floored joint, and the joints
	// that hold a world rotation themselves.
	foreach (usz g, goal : goals)
	{
		if (!self.live[g] || !(self.use_pos[g] || self.use_rot[g])) continue;
		self.frame_above(goal.joint);
		if (self.use_rot[g]) self.framed[goal.joint] = true;
	}
	if (settings.has_floor)
	{
		foreach (pj : joints) if (pj.floored && pj.joint < n) self.frame_above(pj.joint);
	}
	// The balance leans the trunk, whatever else is held.
	if (settings.balance && self.stands_on_something())
	{
		for (usz j = 0; j < n; j++)
		{
			if (self.slot[j] < 0 || !self.joint_of(j).trunk || !self.framed[self.root_of[j]]) continue;
			if (self.children[j] > 0) self.framed[j] = true;
		}
	}

	// A spine of three joints bends three times as easily as a spine of one that bends as far
	// (a rod does not get softer for being cut in pieces), so each takes its share of the
	// stiffness: as many times the stiffness as there are trunk joints to turn.
	float trunk_joints = 0.0f;
	for (usz j = 0; j < n; j++)
	{
		if (self.slot[j] >= 0 && self.framed[j] && skeleton.parents[j] >= 0 && self.joint_of(j).trunk && !self.joint_of(j).frozen) trunk_joints += 1.0f;
	}
	// The unknowns, each with what it costs to move them from where they began. The root
	// slides by a Huber cost; its turn and a trunk joint's are drawn back hard; a limb's
	// are drawn back a little, for what the parts' stiffness cannot see.
	for (usz j = 0; j < n; j++)
	{
		if (self.slot[j] < 0 || !self.framed[j]) continue;
		PointJoint* pj = self.joint_of(j);
		self.first[j] = self.nu;
		if (skeleton.parents[j] < 0)
		{
			for (usz a = 0; a < 3; a++)
			{
				self.unknowns[self.nu++] = { .joint = j, .slide = true, .axis = AXIS_DIRECTION[a],
					.stiff = POINT_POSE_SLIDE, .scale = 1.0f / self.h, .limit = -1 };
			}
			if (!pj.frozen)
			{
				for (usz a = 0; a < 3; a++)
				{
					self.unknowns[self.nu++] = { .joint = j, .axis = AXIS_DIRECTION[a],
						.stiff = POINT_POSE_ROOT_TURN * self.table[j], .scale = POINT_POSE_TURN_LENGTH, .limit = -1 };
				}
			}
		}
		else if (!pj.frozen)
		{
			bool limited = pj.limited();
			Quaternionf frame = limited ? pj.frame.rotation.normalize() : (Quaternionf)quaternion::IDENTITY;
			Vec3 pitch = pj.trunk && !limited ? self.pitch_axis(j) : (Vec3){};
			for (usz a = 0; a < 3; a++)
			{
				if (limited && !pj.limits.axes[a].allowed) continue;
				float stiff = POINT_POSE_LIMB_TURN * self.table[j] * (pivots[j] ? POINT_POSE_PIVOT_EASE : 1.0f);
				if (pj.trunk)
				{
					// A trunk joint pitches freely and is stiff against leaning to the side and twisting.
					float straight = 1.0f;
					if (limited && a != 0) straight = POINT_POSE_TRUNK_STRAIGHT;
					if (!limited && pitch.length_sq() > 0.5f)
					{
						float about = frame.rotate_vec3(AXIS_DIRECTION[a]).dot(pitch);
						straight = 1.0f + (POINT_POSE_TRUNK_STRAIGHT - 1.0f) * (1.0f - about * about);
					}
					stiff = POINT_POSE_TRUNK_TURN * self.table[j] * straight * math::max(trunk_joints, 1.0f) * (self.grounded ? 1.0f : POINT_POSE_TRUNK_FLOATING);
				}
				self.unknowns[self.nu++] = { .joint = j, .axis = frame.rotate_vec3(AXIS_DIRECTION[a]),
					.stiff = stiff, .scale = POINT_POSE_TURN_LENGTH, .limit = limited ? (int)a : -1 };
			}
		}
		self.count[j] = self.nu - self.first[j];
		self.turns[j] = skeleton.parents[j] >= 0 && self.count[j] > 0;
	}
	self.active = self.nu > 0;
	if (!self.active) return;
	for (usz j = 0; j < n; j++)
	{
		if (!self.turns[j] || !self.joint_of(j).limited()) continue;
		PointJoint* pj = self.joint_of(j);
		self.basis[j] = pj.frame.rotation.normalize();
		self.cur.angles[j] = joint_angles_from_rotation(pj.frame, self.cur.local[j]);
		self.anchor_angles[j] = joint_angles_from_rotation(pj.frame, self.anchor[j]);
	}
	self.began.copy_from(&self.cur);
	// A joint with nothing solved at or under it rides rigidly on the nearest joint above
	// that is solved, so placing it takes one turn of that joint's frame, not a walk.
	bool[] below = alloc::new_array(tmem, bool, (sz)n);
	for (usz j = n; j > 0; j--)
	{
		int parent = skeleton.parents[j - 1];
		if (parent >= 0 && (self.count[j - 1] > 0 || below[j - 1])) below[(usz)parent] = true;
	}
	for (usz j = 0; j < n; j++)
	{
		self.carrier[j] = -1;
		int parent = skeleton.parents[j];
		if (parent < 0 || self.count[j] > 0 || below[j]) continue;
		int base = self.count[(usz)parent] > 0 ? parent : -1;
		for (int walk = parent; base < 0 && walk >= 0; walk = skeleton.parents[(usz)walk])
		{
			if (self.count[(usz)walk] > 0) base = walk;
		}
		if (base < 0) continue;
		self.carrier[j] = base;
		self.carries[(usz)base] = true;
		self.carried_at[j] = self.cur.world[(usz)base].invert().rotate_vec3(self.cur.x[j] - self.cur.x[(usz)base]);
	}
	// The parts the unknowns move: every joint at or below a solved one, and all of them
	// under a root that slides. Their masses are what the stiffness weighs.
	for (usz j = 0; j < n; j++)
	{
		int parent = skeleton.parents[j];
		self.reached[j] = self.count[j] > 0 || (parent >= 0 && self.reached[(usz)parent]);
		self.weighed[j] = self.reached[j] && self.slot[j] >= 0;
	}
	// And where each stood in the pose the gesture began from, the root where it was handed in.
	BodySolveState at_anchor = body_solve_state(n);
	at_anchor.rest[..] = self.began.rest[..];
	at_anchor.local[..] = self.anchor[..];
	at_anchor.walk(skeleton);
	self.centres(&at_anchor, self.anchor_centre);
	usz nu = self.nu;
	self.mat = alloc::new_array(tmem, double, (sz)(nu * nu));
	self.work = alloc::new_array(tmem, double, (sz)(nu * nu));
	self.grad = alloc::new_array(tmem, double, (sz)nu);
	self.delta = alloc::new_array(tmem, double, (sz)nu);
	self.fixed = alloc::new_array(tmem, bool, (sz)nu);
	self.resting = alloc::new_array(tmem, bool, (sz)joints.len);
	self.bound = alloc::new_array(tmem, int, (sz)nu);
	self.axes = alloc::new_array(tmem, Vec3, (sz)nu);
	self.jc = alloc::new_array(tmem, usz, (sz)nu);
	self.jv = alloc::new_array(tmem, Vec3, (sz)nu);
	self.open_balance();
	self.find_order();
}

<*
 The joints a placement has to reach: everything a residual or a derivative reads,
 which is each goal's and each floored joint's chain up to the root, and every joint
 an unknown moves, whose part the stiffness and the balance weigh. The rest ride, and
 are placed once at the end.
*>
fn void BodySolve.find_order(&self)
{
	bool[] needed = alloc::new_array(tmem, bool, (sz)self.n);
	foreach (usz g, goal : self.goals)
	{
		if (self.live[g]) self.need_chain(needed, goal.joint);
	}
	if (self.settings.has_floor)
	{
		foreach (pj : self.joints) if (pj.floored && pj.joint < self.n) self.need_chain(needed, pj.joint);
	}
	for (usz j = 0; j < self.n; j++)
	{
		if (self.reached[j]) self.need_chain(needed, j);
	}
	foreach (usz j, flag : needed) if (flag) self.order[self.order_count++] = j;
}

fn void BodySolve.need_chain(&self, bool[] needed, usz joint)
{
	for (int walk = (int)joint; walk >= 0 && !needed[(usz)walk]; walk = self.skeleton.parents[(usz)walk]) needed[(usz)walk] = true;
}

// `s` placed for the joints the solve reads.
fn void BodySolve.place(&self, BodySolveState* s)
{
	for (usz i = 0; i < self.order_count; i++)
	{
		usz j = self.order[i];
		int parent = self.skeleton.parents[j];
		if (parent < 0)
		{
			s.x[j] = s.rest[j];
			s.world[j] = s.local[j];
			if (self.carries[j]) self.turn_of[j] = body_solve_matrix(s.world[j]);
			continue;
		}
		sz base = self.carrier[j];
		if (base >= 0)
		{
			Vec3[3]* turn = &self.turn_of[(usz)base];
			Vec3 at = self.carried_at[j];
			s.x[j] = s.x[(usz)base] + (Vec3){ (*turn)[0].dot(at), (*turn)[1].dot(at), (*turn)[2].dot(at) };
			continue;
		}
		usz p = (usz)parent;
		s.x[j] = s.x[p] + s.world[p].rotate_vec3(s.rest[j]);
		s.world[j] = s.world[p].mul(s.local[j]).normalize();
		if (self.carries[j]) self.turn_of[j] = body_solve_matrix(s.world[j]);
	}
}

<*
 Which way joint `j`'s range opens, if it is a one-sided hinge: +1 or -1; 0 if it
 is not. A one-sided hinge is limited with exactly one allowed axis, whose range
 is more than four times `POINT_POSE_BEND` wide and ends within 1e-3 of zero.
*>
fn float BodySolve.one_sided_hinge(&self, usz j, int* axis = null)
{
	PointJoint* pj = self.joint_of(j);
	if (!pj.limited()) return 0.0f;
	int found = -1;
	usz allowed = 0;
	foreach (usz a, row : pj.limits.axes)
	{
		if (!row.allowed) continue;
		allowed++;
		found = (int)a;
	}
	if (allowed != 1) return 0.0f;
	JointAxisLimit row = pj.limits.axes[found];
	if (row.maximum - row.minimum < POINT_POSE_BEND * 4.0f) return 0.0f;
	if (axis) *axis = found;
	if (math::abs(row.minimum) < 1.0e-3f) return 1.0f;
	if (math::abs(row.maximum) < 1.0e-3f) return -1.0f;
	return 0.0f;
}

// Mark the joints in play above `j`, up to the root, as framed.
fn void BodySolve.frame_above(&self, usz j)
{
	if (self.slot[j] < 0) return;
	if (self.skeleton.parents[j] < 0) self.framed[j] = true;
	for (int walk = self.skeleton.parents[j]; walk >= 0 && self.slot[(usz)walk] >= 0; walk = self.skeleton.parents[(usz)walk])
	{
		self.framed[(usz)walk] = true;
	}
}

<*
 Whether `target` is within reach of the limb `joint` ends: no further from the
 nearest fork or root above it than the bones between them are long.
*>
fn bool BodySolve.in_reach(&self, usz joint, Vec3 target)
{
	float reach = 0.0f;
	usz walk = joint;
	while (true)
	{
		int parent = self.skeleton.parents[walk];
		if (parent < 0 || self.slot[(usz)parent] < 0) break;
		reach += self.cur.rest[walk].length();
		walk = (usz)parent;
		if (self.children[walk] != 1) break;
	}
	if (walk == joint) return true;
	return (target - self.cur.x[walk]).length() <= reach + self.h * 1.0e-3f;
}

<*
 Whether any hard position is planted below the root of its tree — the only
 thing a balance can stand on.
*>
fn bool BodySolve.stands_on_something(&self)
{
	foreach (usz g, goal : self.goals)
	{
		if (!self.live[g] || !self.use_pos[g] || goal.soft) continue;
		if (goal.target.dot(self.up) < self.cur.x[self.root_of[goal.joint]].dot(self.up)) return true;
	}
	return false;
}

<*
 The masses the balance weighs, the outline it stands on, and whether it is on:
 the weights `point_balance_weights` gives, the legs — every joint between the root and a
 hard position planted below it — scaled to their share of the whole.

 **The outline is the feet's, not their pins'.** A pinned ankle is one point, and
 two of them make a line a body can only balance on by standing exactly over it, so
 a hip drop would be bent back and forth to keep the centre on that line. But a
 foot stands on its sole. Where a pinned or planted joint carries a short branch of
 its own — a foot or a hoof and its toes, shorter than `POINT_POSE_LIMB_SHARE` of
 the height — the tips of it are points of the outline too, carried to the pin as
 the foot is (as it stands when the solve begins); and a planted toe adds the joint
 a short bone above it, where the heel is. Two feet are a quadrilateral. The points
 the pins themselves name come first, so a rig with many of them keeps those.

 The last point is where the centre of mass stands as the solve begins, so that a
 pose handed in off its feet is not pulled onto them by the first demand.
*>
fn void BodySolve.open_balance(&self)
{
	if (!self.settings.balance) return;
	bool[] leg = alloc::new_array(tmem, bool, (sz)self.n);
	foreach (usz g, goal : self.goals)
	{
		if (!self.live[g] || !self.use_pos[g] || goal.soft) continue;
		usz root = self.root_of[goal.joint];
		if (goal.target.dot(self.up) >= self.cur.x[root].dot(self.up)) continue;
		for (usz walk = goal.joint; walk != root; walk = (usz)self.skeleton.parents[walk]) leg[walk] = true;
		self.add_stand(goal.target);
	}
	// How far each joint's longest branch runs below it.
	float[] reach = alloc::new_array(tmem, float, (sz)self.n);
	for (usz j = self.n; j > 0; j--)
	{
		int parent = self.skeleton.parents[j - 1];
		if (parent < 0) continue;
		float branch = (self.skeleton.joints[j - 1] - self.skeleton.joints[(usz)parent]).length() + reach[j - 1];
		reach[(usz)parent] = math::max(reach[(usz)parent], branch);
	}
	foreach (usz g, goal : self.goals)
	{
		if (!self.live[g] || !self.use_pos[g] || goal.soft) continue;
		usz root = self.root_of[goal.joint];
		if (goal.target.dot(self.up) >= self.cur.x[root].dot(self.up)) continue;
		// A planted toe stands on its foot, so the joint a short bone above it — the
		// ankle, where the heel is — is a point of the outline as well.
		int above = self.skeleton.parents[goal.joint];
		if (above >= 0 && (usz)above != root && reach[(usz)above] < self.h * POINT_POSE_LIMB_SHARE)
		{
			self.add_stand(self.cur.x[(usz)above] + (goal.target - self.cur.x[goal.joint]));
		}
		if (reach[goal.joint] >= self.h * POINT_POSE_LIMB_SHARE) continue;
		for (usz j = goal.joint + 1; j < self.n; j++)
		{
			if (self.children[j] > 0) continue;
			// Below the pin: climbing from `j` meets it.
			usz walk = j;
			while (walk != goal.joint && self.skeleton.parents[walk] >= 0) walk = (usz)self.skeleton.parents[walk];
			if (walk == goal.joint)
			{
				Vec3 tip = self.cur.x[j] + (goal.target - self.cur.x[goal.joint]);
				self.add_stand(tip);
				// A foot pinned flat stands on its whole sole: the heel runs behind the ankle by a
				// share of the foot's length. One pinned by its ankle alone is as large as its joints.
				if (goal.rotation && goal.turn_weight <= 0.0f) self.add_stand(goal.target - (tip - goal.target) * POINT_POSE_HEEL);
			}
		}
	}
	bool[] in_play = alloc::new_array(tmem, bool, (sz)self.n);
	foreach (usz j, slot : self.slot) in_play[j] = slot >= 0;
	self.balance_total = point_balance_weights(self.skeleton, in_play, leg, self.balance_mass);
	self.balance_on = self.balance_total > 0.0f && self.stand_count > 0;
	if (!self.balance_on) return;
	// Where the centre of mass stands as the solve begins is on the outline whatever
	// the feet say: a pose handed in off balance is not pushed onto its feet at the
	// first touch of the pointer — that would be a jump, and the same for every
	// pointer position — it is only kept from going further out.
	Vec3 sum = {};
	for (usz j = 0; j < self.n; j++) sum = sum + self.cur.x[j] * self.balance_mass[j];
	self.add_stand(sum / self.balance_total);
}

<*
 Where each part's mass stands in `s`, into `out`: the middle of its joint and its
 children's mean, or the joint itself at a tip. This is where the stiffness holds a
 joint's mass, and it moves by `axis × (centre − pivot)` for a turn at or above the joint.
*>
fn void BodySolve.centres(&self, BodySolveState* s, Vec3[] out)
{
	self.centre_sum[..] = {};
	for (usz j = 0; j < self.n; j++)
	{
		int parent = self.skeleton.parents[j];
		if (parent >= 0) self.centre_sum[(usz)parent] = self.centre_sum[(usz)parent] + s.x[j];
	}
	for (usz j = 0; j < self.n; j++)
	{
		out[j] = self.children[j] == 0 ? s.x[j] : (s.x[j] + self.centre_sum[j] / (float)self.children[j]) * 0.5f;
	}
}

<*
 The axis, in joint `j`'s parent's frame, that a trunk joint pitches about — across
 `up`, and across the bone it carries — or zero where there is none to name (a joint
 that carries several bones, or a bone standing along `up`). A trunk joint with no
 limits to say which of its axes lean to the side and which pitch is told by this.
*>
fn Vec3 BodySolve.pitch_axis(&self, usz j)
{
	if (self.children[j] != 1) return {};
	usz child = j + 1;
	while (child < self.n && self.skeleton.parents[child] != (int)j) child++;
	if (child >= self.n) return {};
	Vec3 bone = self.cur.x[child] - self.cur.x[j];
	Vec3 across = self.up.cross(bone);
	if (across.length() < bone.length() * 0.3f) return {};
	int parent = self.skeleton.parents[j];
	Quaternionf above = parent >= 0 ? self.cur.world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
	return above.invert().rotate_vec3(across.normalize());
}

// A point of the support outline, unless there is no room or it is already one.
fn void BodySolve.add_stand(&self, Vec3 point)
{
	Vec3 flat = point_flat(self.up, point);
	for (usz i = 0; i < self.stand_count; i++)
	{
		if ((self.stands[i] - flat).length() < self.h * 1.0e-4f) return;
	}
	if (self.stand_count < POINT_POSE_SUPPORTS) self.stands[self.stand_count++] = flat;
}

// How far, across `up`, the centre of mass of `s` stands outside what the body stands on.
fn Vec3 BodySolve.balance_error(&self, BodySolveState* s)
{
	Vec3 sum = {};
	for (usz j = 0; j < self.n; j++) sum = sum + s.x[j] * self.balance_mass[j];
	Vec3 centre = point_flat(self.up, sum / self.balance_total);
	Vec3 miss = point_support_miss(self.stands[:self.stand_count], centre, self.up);
	// The sole is wider than the bones that name it: a margin round the outline.
	float away = miss.length();
	float sole = self.h * POINT_POSE_SOLE;
	if (away <= sole) return {};
	return miss * ((away - sole) / away);
}

// ---------------------------------------------------------------------------
// The residuals and their derivatives

<*
 The derivatives of one residual by the unknowns it depends on, left in `jc` and
 `jv`: those of every joint from `joint` up to the root.

 A point `p` of `joint` moves by `axis × (p − pivot)` for a turn of an ancestor
 about the world `axis` through its own point, and by the slide itself for the
 root's; `joint`'s own turn does not move it. An angle turns by the axis, and
 not at all by a slide. Everything is multiplied by `scale`.

 @return `How many unknowns there are.`
*>
fn usz BodySolve.jacobian(&self, BodySolveState* s, usz joint, Vec3 p, bool rotation, float scale, bool own = false)
{
	usz found = 0;
	for (int a = (int)joint; a >= 0; a = self.skeleton.parents[(usz)a])
	{
		usz first = self.first[(usz)a];
		for (usz c = first; c < first + self.count[(usz)a]; c++)
		{
			BodySolveUnknown* u = &self.unknowns[c];
			Vec3 v;
			if (u.slide)
			{
				if (rotation) continue;
				v = u.axis * scale;
			}
			else if (rotation)
			{
				v = self.axes[c] * scale;
			}
			else
			{
				if ((usz)a == joint && !own) continue;
				v = self.axes[c].cross(p - s.x[(usz)a]) * scale;
			}
			self.jc[found] = c;
			self.jv[found] = v;
			found++;
		}
	}
	return found;
}

// Add one residual `r`, of weight `w` and the derivatives left in `jc`/`jv`, to the normal equations.
fn void BodySolve.rows(&self, Vec3 r, double w, usz found)
{
	usz nu = self.nu;
	double* mat = self.mat.ptr;
	double* grad = self.grad.ptr;
	for (usz a = 0; a < found; a++)
	{
		usz ca = self.jc[a];
		Vec3 va = self.jv[a];
		grad[ca] += w * (double)va.dot(r);
		for (usz b = 0; b <= a; b++)
		{
			usz cb = self.jc[b];
			double d = w * (double)va.dot(self.jv[b]);
			mat[ca * nu + cb] += d;
			if (a != b) mat[cb * nu + ca] += d;
		}
	}
}

<*
 The floor row of the floored joint `i` of the joints in play, `under` heights
 below the floor (or on it, when zero), added to the equations.
*>
fn void BodySolve.floor_row(&self, BodySolveState* s, usz i, float under, bool counted)
{
	usz j = self.joints[i].joint;
	self.resting[i] = true;
	usz found = self.jacobian(s, j, s.x[j], false, 1.0f / self.h);
	for (usz k = 0; k < found; k++) self.jv[k] = self.up * -self.up.dot(self.jv[k]);
	self.rows(self.up * under, self.pin, found);
	if (!counted) self.extra += (double)self.pin * (double)(under * under);
}

<*
 Hold the floored joints a step would carry through the floor.

 The floor is a row only while a joint is below it, so a step is blind to the
 floor until it has gone through. Here the step is read first, joint by joint, for
 the floored joints it would put below the floor as far as it will be taken. One
 resting on the floor gets its row, held there, and the step is solved again. One
 above it is only not let through: the step is shortened to the point it reaches
 the floor, and the joint rests there for the next. A joint the step lifts or
 leaves alone gets nothing, so a foot is free to leave the floor.

 @param scale : `The share of the step that will be taken; shortened here.`
 @return `True when a row was added, so the step has to be solved again.`
*>
fn bool BodySolve.block_floor(&self, double* scale)
{
	if (!self.settings.has_floor) return false;
	bool added = false;
	foreach (usz i, pj : self.joints)
	{
		if (!pj.floored || pj.joint >= self.n || self.resting[i]) continue;
		usz j = pj.joint;
		float margin = self.cur.x[j].dot(self.up) - self.settings.floor;
		usz found = self.jacobian(&self.cur, j, self.cur.x[j], false, 1.0f);
		double rise = 0.0;
		for (usz k = 0; k < found; k++) rise += (double)self.up.dot(self.jv[k]) * self.delta[self.jc[k]];
		if ((double)margin + rise * *scale >= -1.0e-9) continue;
		if (margin <= self.h * BODY_SOLVE_RESTING)
		{
			self.floor_row(&self.cur, i, -margin / self.h, false);
			added = true;
		}
		else
		{
			*scale = math::min(*scale, (double)margin / -rise);
		}
	}
	return added;
}

<*
 The weighted sum of squares of everything asked of `s`, and — when `derive` — the
 normal equations at it in `mat` and `grad`.
*>
fn double BodySolve.evaluate(&self, BodySolveState* s, bool derive)
{
	double cost = 0.0;
	float h = self.h;
	if (derive)
	{
		self.mat[..] = 0.0;
		self.grad[..] = 0.0;
		for (usz j = 0; j < self.n; j++)
		{
			if (self.count[j] == 0) continue;
			int parent = self.skeleton.parents[j];
			if (parent < 0)
			{
				for (usz c = self.first[j]; c < self.first[j] + self.count[j]; c++) self.axes[c] = self.unknowns[c].axis;
				continue;
			}
			Quaternionf above = s.world[(usz)parent];
			if (self.joint_of(j).limited())
			{
				Vec3[3] tangent = limit_angle_axes(self.basis[j], s.angles[j]);
				for (usz c = self.first[j]; c < self.first[j] + self.count[j]; c++)
				{
					self.axes[c] = above.rotate_vec3(tangent[(usz)self.unknowns[c].limit]);
				}
			}
			else
			{
				for (usz c = self.first[j]; c < self.first[j] + self.count[j]; c++)
				{
					self.axes[c] = above.rotate_vec3(self.unknowns[c].axis);
				}
			}
		}
	}

	foreach (usz g, &goal : self.goals)
	{
		if (!self.live[g]) continue;
		usz j = goal.joint;
		if (self.use_pos[g])
		{
			Vec3 r = (s.x[j] - self.aim[g]) / h;
			double w = goal.soft ? POINT_POSE_GRAB : self.pin;
			cost += w * (double)r.dot(r);
			if (derive) self.rows(r, w, self.jacobian(s, j, s.x[j], false, 1.0f / h));
		}
		if (self.use_rot[g])
		{
			Vec3 r = body_solve_log(s.world[j].mul(goal.orient.invert()).normalize()) * POINT_POSE_TURN_LENGTH;
			double w = goal.turn_weight > 0.0f ? goal.turn_weight : self.pin;
			cost += w * (double)r.dot(r);
			if (derive) self.rows(r, w, self.jacobian(s, j, {}, true, POINT_POSE_TURN_LENGTH));
		}
	}

	if (diag_pull_weight > 0.0)
	{
		usz j = diag_pull_joint;
		double r = ((double)s.angles[j][diag_pull_axis] - diag_pull_value) * (double)POINT_POSE_TURN_LENGTH;
		cost += diag_pull_weight * r * r;
		if (derive)
		{
			for (usz c = self.first[j]; c < self.first[j] + self.count[j]; c++)
			{
				if (self.unknowns[c].limit != diag_pull_axis) continue;
				self.mat[c * self.nu + c] += diag_pull_weight * (double)POINT_POSE_TURN_LENGTH * (double)POINT_POSE_TURN_LENGTH;
				self.grad[c] += diag_pull_weight * (double)POINT_POSE_TURN_LENGTH * r;
			}
		}
	}
	if (derive)
	{
		self.resting[..] = false;
		self.extra = 0.0;
	}
	if (self.settings.has_floor)
	{
		foreach (usz i, pj : self.joints)
		{
			if (!pj.floored || pj.joint >= self.n) continue;
			usz j = pj.joint;
			float under = (self.settings.floor - s.x[j].dot(self.up)) / h;
			if (under <= 0.0f) continue;
			cost += (double)self.pin * (double)(under * under);
			if (!derive) continue;
			self.floor_row(s, i, under, true);
		}
	}

	if (self.balance_on)
	{
		Vec3 miss = self.balance_error(s);
		if (miss.length_sq() > 0.0f)
		{
			Vec3 r = miss / h;
			cost += (double)POINT_POSE_BALANCE_PULL * (double)r.dot(r);
			if (derive)
			{
				// The centre of mass moves by the sum of what each joint below the pivot
				// carries; the support point is held where it is for the step.
				for (usz j = self.n; j > 0; j--)
				{
					usz k = j - 1;
					self.sub_mass[k] += self.balance_mass[k];
					self.sub_moment[k] = self.sub_moment[k] + s.x[k] * self.balance_mass[k];
					int parent = self.skeleton.parents[k];
					if (parent >= 0)
					{
						self.sub_mass[(usz)parent] += self.sub_mass[k];
						self.sub_moment[(usz)parent] = self.sub_moment[(usz)parent] + self.sub_moment[k];
					}
				}
				for (usz c = 0; c < self.nu; c++)
				{
					BodySolveUnknown* u = &self.unknowns[c];
					Vec3 moved;
					if (u.slide)
					{
						moved = u.axis * (self.sub_mass[u.joint] / self.balance_total);
					}
					else
					{
						moved = self.axes[c].cross(self.sub_moment[u.joint] - s.x[u.joint] * self.sub_mass[u.joint]) / self.balance_total;
					}
					self.jc[c] = c;
					self.jv[c] = -point_flat(self.up, moved) / h;
				}
				self.sub_mass[..] = 0.0f;
				self.sub_moment[..] = {};
				self.rows(r, POINT_POSE_BALANCE_PULL, self.nu);
			}
		}
	}

	cost += self.part_rows(s, derive);
	cost += self.joint_rows(s, derive);
	return cost;
}

<*
 Every part of the body drawn back to where it stood when the gesture began, by its
 mass: the part's mass at the middle of its joint and its children (`centres`), taken
 in the frame the root carries — the root's slide moves every part with it and
 costs them nothing here.

 A part moves by `axis × (centre − pivot)` for a turn at or above its joint, so the
 normal equations of all of them together need only the sums of `w`, `w c`, `w c cᵀ`,
 `w r` and `w c × r` over the parts under each joint, not a row for each part: a
 pair of turns on one chain meet in the parts under the lower of the two.

 @return `The cost of it.`
*>
fn double BodySolve.part_rows(&self, BodySolveState* s, bool derive)
{
	float h = self.h;
	double inv_h2 = 1.0 / ((double)h * (double)h);
	self.centres(s, self.centre);
	double cost = 0.0;
	if (derive) self.moments[..] = {};
	for (usz k = 0; k < self.n; k++)
	{
		if (!self.weighed[k]) continue;
		usz root = self.root_of[k];
		Vec3 c = self.centre[k];
		Vec3 r = c - (s.rest[root] - self.began.rest[root]) - self.anchor_centre[k];
		double w = (double)POINT_POSE_STIFFNESS * (double)self.mass[k];
		cost += w * (double)r.dot(r) * inv_h2;
		if (!derive) continue;
		BodySolveMoment* m = &self.moments[k];
		Vec3 spin = c.cross(r);
		m.w = w;
		for (usz i = 0; i < 3; i++)
		{
			m.c[i] = w * (double)c[i];
			m.r[i] = w * (double)r[i];
			m.x[i] = w * (double)spin[i];
		}
		m.q = { w * (double)(c.x * c.x), w * (double)(c.y * c.y), w * (double)(c.z * c.z),
			w * (double)(c.x * c.y), w * (double)(c.x * c.z), w * (double)(c.y * c.z) };
	}
	if (!derive) return cost;
	for (usz j = self.n; j > 0; j--)
	{
		int parent = self.skeleton.parents[j - 1];
		if (parent >= 0) self.moments[(usz)parent].add(&self.moments[j - 1]);
	}

	usz nu = self.nu;
	for (usz cv = 0; cv < nu; cv++)
	{
		BodySolveUnknown* uv = &self.unknowns[cv];
		if (uv.slide) continue;
		usz jv = uv.joint;
		BodySolveMoment* m = &self.moments[jv];
		if (m.w == 0.0) continue;
		Vec3 av = self.axes[cv];
		Vec3 xv = s.x[jv];
		Vec3 sum_r = { (float)m.r[0], (float)m.r[1], (float)m.r[2] };
		Vec3 sum_x = { (float)m.x[0], (float)m.x[1], (float)m.x[2] };
		self.grad[cv] += (double)av.dot(sum_x - xv.cross(sum_r)) * inv_h2;
		double[3] sum_c = m.c;
		for (int ja = (int)jv; ja >= 0; ja = self.skeleton.parents[(usz)ja])
		{
			usz first = self.first[(usz)ja];
			for (usz cu = first; cu < first + self.count[(usz)ja]; cu++)
			{
				if ((usz)ja == jv && cu > cv) continue;
				BodySolveUnknown* uu = &self.unknowns[cu];
				if (uu.slide) continue;
				Vec3 au = self.axes[cu];
				Vec3 xu = s.x[uu.joint];
				// (au × (c − xu)) · (av × (c − xv)), summed over the parts under jv.
				double trace = m.q[0] + m.q[1] + m.q[2];
				double c_xu = sum_c[0] * (double)xu.x + sum_c[1] * (double)xu.y + sum_c[2] * (double)xu.z;
				double c_xv = sum_c[0] * (double)xv.x + sum_c[1] * (double)xv.y + sum_c[2] * (double)xv.z;
				double both = trace - c_xu - c_xv + m.w * (double)xu.dot(xv);
				double qa_x = m.q[0] * (double)av.x + m.q[3] * (double)av.y + m.q[4] * (double)av.z;
				double qa_y = m.q[3] * (double)av.x + m.q[1] * (double)av.y + m.q[5] * (double)av.z;
				double qa_z = m.q[4] * (double)av.x + m.q[5] * (double)av.y + m.q[2] * (double)av.z;
				double cross = (double)au.x * qa_x + (double)au.y * qa_y + (double)au.z * qa_z;
				double au_c = (double)au.x * sum_c[0] + (double)au.y * sum_c[1] + (double)au.z * sum_c[2];
				double av_c = (double)av.x * sum_c[0] + (double)av.y * sum_c[1] + (double)av.z * sum_c[2];
				double au_xv = (double)au.dot(xv);
				double av_xu = (double)av.dot(xu);
				cross = cross - au_c * av_xu - au_xv * av_c + m.w * au_xv * av_xu;
				double d = ((double)au.dot(av) * both - cross) * inv_h2;
				self.mat[cu * nu + cv] += d;
				if (cu != cv) self.mat[cv * nu + cu] += d;
			}
		}
	}
	return cost;
}

<*
 Every unknown drawn back toward where it began: a turn by its angle, the root's
 slide by a Huber cost — quadratic up to `POINT_POSE_SLIDE_WIDTH` of the height and
 only linear past it, so a pull the limbs can answer does not move the body, and a
 pull they cannot is followed to within the width.

 @return `The cost of it.`
*>
fn double BodySolve.joint_rows(&self, BodySolveState* s, bool derive)
{
	double cost = 0.0;
	float h = self.h;
	for (usz j = 0; j < self.n; j++)
	{
		usz cnt = self.count[j];
		if (cnt == 0) continue;
		bool by_angle = self.skeleton.parents[j] >= 0 && self.joint_of(j).limited();
		Vec3 turned = {};
		if (by_angle)
		{
			turned = s.angles[j] - self.anchor_angles[j];
			for (usz a = 0; a < 3; a++) turned[a] -= 2.0f * (float)math::PI * (float)math::round(turned[a] / (2.0f * (float)math::PI));
		}
		else
		{
			turned = body_solve_log(s.local[j].mul(self.anchor[j].invert()).normalize());
		}
		Vec3 slid = (s.rest[j] - self.began.rest[j]) / h;
		for (usz c = self.first[j]; c < self.first[j] + cnt; c++)
		{
			BodySolveUnknown* u = &self.unknowns[c];
			float r = u.slide ? slid.dot(u.axis) : (by_angle ? turned[(usz)u.limit] : turned.dot(u.axis)) * u.scale;
			float width = u.slide ? POINT_POSE_SLIDE_WIDTH : 1.0e9f;
			float stiff = u.slide ? u.stiff * self.slide_boost : u.stiff;
			float size = math::abs(r);
			float pull = size <= width ? 1.0f : width / size;
			cost += (double)stiff * (double)(size <= width ? r * r : width * (2.0f * size - width));
			if (!derive) continue;
			self.mat[c * self.nu + c] += (double)(stiff * pull) * (double)(u.scale * u.scale);
			self.grad[c] += (double)(stiff * pull) * (double)(u.scale * r);
		}
	}
	return cost;
}

// ---------------------------------------------------------------------------
// The solve

<*
 Mark the unknowns pressed against a limit and pushed on by the gradient: a step
 may not carry them out, and the projection would only undo it, so they are held
 for this step and the rest solved without them.
*>
fn void BodySolve.hold_at_limits(&self, BodySolveState* s)
{
	self.fixed[..] = false;
	self.bound[..] = 0;
	for (usz j = 0; j < self.n; j++)
	{
		if (!self.turns[j]) continue;
		PointJoint* pj = self.joint_of(j);
		if (!pj.limited()) continue;
		for (usz c = self.first[j]; c < self.first[j] + self.count[j]; c++)
		{
			int a = self.unknowns[c].limit;
			JointAxisLimit row = pj.limits.axes[a];
			if (s.angles[j][a] >= row.maximum - BODY_SOLVE_ON_LIMIT) self.bound[c] = 1;
			if (s.angles[j][a] <= row.minimum + BODY_SOLVE_ON_LIMIT) self.bound[c] = -1;
			double down = -self.grad[c];
			if ((self.bound[c] > 0 && down > 0.0) || (self.bound[c] < 0 && down < 0.0)) self.fixed[c] = true;
		}
	}
}

<*
 The step `delta` of damped Gauss–Newton at the equations in `mat` and `grad`:
 each unknown's own curvature, times `lambda`, added to its diagonal.

 @return `False when the damped equations are not positive definite.`
*>
fn bool BodySolve.solve_step(&self, double lambda)
{
	// A step that pushes an unknown on its limit further out is solved again with
	// that unknown held: the projection would only cancel it.
	for (int round = 0; round < 4; round++)
	{
		if (!self.factor(lambda)) return false;
		bool again = false;
		for (usz c = 0; c < self.nu; c++)
		{
			if (self.fixed[c] || self.bound[c] == 0) continue;
			if ((self.bound[c] > 0 && self.delta[c] > 0.0) || (self.bound[c] < 0 && self.delta[c] < 0.0))
			{
				self.fixed[c] = true;
				again = true;
			}
		}
		if (!again) return true;
	}
	return true;
}

fn bool BodySolve.factor(&self, double lambda)
{
	usz nu = self.nu;
	double* work = self.work.ptr;
	double* mat = self.mat.ptr;
	work[:nu * nu] = mat[:nu * nu];
	for (usz i = 0; i < nu; i++)
	{
		self.delta[i] = -self.grad[i];
		work[i * nu + i] += lambda * mat[i * nu + i] + 1.0e-12;
	}
	for (usz i = 0; i < nu; i++)
	{
		if (!self.fixed[i]) continue;
		for (usz k = 0; k < nu; k++)
		{
			work[i * nu + k] = 0.0;
			work[k * nu + i] = 0.0;
		}
		work[i * nu + i] = 1.0;
		self.delta[i] = 0.0;
	}
	return body_solve_cholesky(self.work, self.delta, nu);
}

<*
 `from` carried by the step, times `scale`, into `to`: each solved joint turned
 by its unknowns and put back inside its limits, the root slid and turned, and the
 whole placed again.
*>
fn void BodySolve.advance(&self, BodySolveState* from, BodySolveState* to, double scale)
{
	to.local[..] = from.local[..];
	to.rest[..] = from.rest[..];
	to.angles[..] = from.angles[..];
	for (usz j = 0; j < self.n; j++)
	{
		usz cnt = self.count[j];
		if (cnt == 0) continue;
		usz first = self.first[j];
		if (self.skeleton.parents[j] < 0)
		{
			to.rest[j] = from.rest[j] + (Vec3){ (float)(self.delta[first] * scale), (float)(self.delta[first + 1] * scale),
				(float)(self.delta[first + 2] * scale) };
			if (cnt > 3)
			{
				Vec3 spin = { (float)(self.delta[first + 3] * scale), (float)(self.delta[first + 4] * scale), (float)(self.delta[first + 5] * scale) };
				if (spin.length_sq() > 0.0f) to.local[j] = self.limited(j, body_solve_turn(spin).mul(from.local[j]).normalize());
			}
			continue;
		}
		PointJoint* pj = self.joint_of(j);
		if (pj.limited())
		{
			// The limit angles raised by the step and held in their ranges, the rotation
			// rebuilt from them: a locked axis takes its value. Where that took anything
			// back, the rotation goes through the limits proper, which own what the nearest
			// allowed rotation is; elsewhere they would only give it back.
			Vec3 angles = from.angles[j];
			bool moved = false;
			for (usz c = first; c < first + cnt; c++)
			{
				angles[(usz)self.unknowns[c].limit] += (float)(self.delta[c] * scale);
				if (self.delta[c] != 0.0) moved = true;
			}
			if (!moved) continue;
			bool held = false;
			for (usz a = 0; a < 3; a++)
			{
				float inside = pj.limits.axes[a].clamp(angles[a]);
				if (inside != angles[a]) held = true;
				angles[a] = inside;
			}
			to.angles[j] = angles;
			to.local[j] = rotation_from_joint_angles(pj.frame, angles);
			if (held)
			{
				to.local[j] = constrain_joint_rotation(pj.frame, pj.limits, to.local[j]);
				to.angles[j] = joint_angles_from_rotation(pj.frame, to.local[j]);
			}
			continue;
		}
		Vec3 spin = {};
		for (usz c = first; c < first + cnt; c++) spin = spin + self.unknowns[c].axis * (float)(self.delta[c] * scale);
		if (spin.length_sq() > 0.0f) to.local[j] = body_solve_turn(spin).mul(from.local[j]).normalize();
	}
	self.place(to);
}

<*
 Minimise the cost from `cur`, by up to `iterations` trial steps. A step is
 taken when it lowers the cost, and the damping eased; otherwise the damping is
 raised and the step tried again, shorter. Stops when a step saves less than
 `saving` of the cost, or moves nothing, or when a step that failed was one the
 model itself said was worth next to nothing: damping harder would only carry
 a needlessly large `lambda` into the sub-step after.
*>
fn void BodySolve.minimise(&self, int iterations, double saving, double* lambda)
{
	double cost = 0.0;
	bool fresh = false;
	double raise = 2.0;
	float tiny_turn = 1.0e-7f;
	float tiny_slide = self.h * 1.0e-8f;
	for (int t = 0; t < iterations; t++)
	{
		if (!fresh)
		{
			cost = self.evaluate(&self.cur, true);
			self.hold_at_limits(&self.cur);
			fresh = true;
		}
		bool solved = true;
		double scale = 1.0;
		double biggest_turn = 0.0;
		double biggest_slide = 0.0;
		for (int round = 0; round < 3 && solved; round++)
		{
			solved = self.solve_step(*lambda);
			if (!solved) break;
			// The step, shortened to the cap if any one unknown asks for more.
			scale = 1.0;
			biggest_turn = 0.0;
			biggest_slide = 0.0;
			for (usz c = 0; c < self.nu; c++)
			{
				double d = math::abs(self.delta[c]);
				if (self.unknowns[c].slide) { biggest_slide = math::max(biggest_slide, d); }
				else { biggest_turn = math::max(biggest_turn, d); }
			}
			double slide_cap = (double)self.h * (double)POINT_POSE_MAX_SLIDE;
			if (biggest_turn > POINT_POSE_MAX_STEP) scale = (double)POINT_POSE_MAX_STEP / biggest_turn;
			if (biggest_slide > slide_cap) scale = math::min(scale, slide_cap / biggest_slide);
			if (!self.block_floor(&scale)) break;
		}
		if (!solved)
		{
			*lambda *= 10.0;
			continue;
		}
		// What the quadratic model of the cost says the step saves.
		double predicted = 0.0;
		for (usz i = 0; i < self.nu; i++)
		{
			double row = 0.0;
			for (usz k = 0; k < self.nu; k++) row += self.mat[i * self.nu + k] * self.delta[k];
			predicted += scale * self.delta[i] * (-2.0 * self.grad[i] - scale * row);
		}
		predicted -= self.extra;
		self.advance(&self.cur, &self.trial, scale);
		double after = self.evaluate(&self.trial, false);
		double ratio = predicted > 0.0 ? (cost - after) / predicted : -1.0;
		if (diag_trace)
		{
			usz nf = 0;
			for (usz c = 0; c < self.nu; c++) if (self.fixed[c]) nf++;
			double step_norm = 0.0;
			for (usz c = 0; c < self.nu; c++) step_norm += self.delta[c] * self.delta[c] * scale * scale;
			Vec3 wx = self.trial.angles[24] * 57.29578f;
			Vec3 ey = self.trial.angles[21] * 57.29578f;
			Vec3 cz = self.trial.angles[11] * 57.29578f;
			Vec3 sh = self.trial.angles[16] * 57.29578f;
			diag_log.appendf("    it %d cost %.6e -> %.6e ratio %.3f lam %.1e sc %.2f |st| %.2e fx %d | trial: wristX %.1f elbowY %.1f clavXYZ %.1f %.1f %.1f shoulder %.1f %.1f %.1f\n", t, cost, after, ratio, *lambda, scale, math::sqrt(step_norm), (int)nf, wx.x, ey.y, cz.x, cz.y, cz.z, sh.x, sh.y, sh.z);
		}
		diag_iters++;
		if (!(after < cost)) diag_rejects++;
		if (after < cost)
		{
			diag_accepts++;
			BodySolveState held = self.cur;
			self.cur = self.trial;
			self.trial = held;
			fresh = false;
			bool settled = biggest_turn * scale < tiny_turn && biggest_slide * scale < tiny_slide;
			bool saved_little = predicted <= saving * cost + BODY_SOLVE_NOISE;
			double ease = 1.0 - math::pow(2.0 * ratio - 1.0, 3.0);
			*lambda = math::max(*lambda * math::clamp(ease, 1.0 / 3.0, 8.0), diag_floor > 0.0 ? diag_floor : BODY_SOLVE_DAMPING_FLOOR);
			raise = 2.0;
			if (settled || saved_little) break;
		}
		else
		{
			// A step the model itself says is worth nothing is not one to damp harder
			// and try again: this is as far as the cost goes.
			if (predicted <= saving * cost + BODY_SOLVE_NOISE) break;
			*lambda *= raise;
			raise *= 2.0;
			if (*lambda > 1.0e9) break;
		}
	}
}

<*
 Start each one-sided hinge that sits closed bent a little the way it opens.

 A hinge — a knee, an elbow — whose range ends at zero and runs one way is
 closed at that end; a straight limb has no first-order bend direction, so the
 solve could never tell the bones to fold, and one modelled bent backward would
 fold into its limit. So where the limb's bones stand less than
 `POINT_POSE_BEND` bent the way the hinge opens, the hinge is turned to make it
 so. This is where the solve starts, not what it is drawn back toward: an
 unsqueezed limb straightens again.
*>
fn void BodySolve.seed_bends(&self)
{
	for (usz j = 0; j < self.n; j++)
	{
		if (!self.turns[j] || self.children[j] != 1) continue;
		PointJoint* pj = self.joint_of(j);
		int axis = -1;
		float opens = self.one_sided_hinge(j, &axis);
		if (opens == 0.0f) continue;
		JointAxisLimit row = pj.limits.axes[axis];
		if (self.cur.angles[j][axis] * opens >= 1.0e-3f) continue;

		usz parent = (usz)self.skeleton.parents[j];
		usz child = j + 1;
		while (child < self.n && self.skeleton.parents[child] != (int)j) child++;
		if (child >= self.n) continue;
		Vec3 upper = self.cur.x[j] - self.cur.x[parent];
		Vec3 lower = self.cur.x[child] - self.cur.x[j];
		Vec3 about = pj.frame.rotation.normalize().rotate_vec3(AXIS_DIRECTION[axis]);
		Vec3 hinge = self.cur.world[parent].rotate_vec3(about);
		float bend = (float)math::atan2(hinge.dot(upper.cross(lower)), upper.dot(lower));
		if (bend * opens >= POINT_POSE_BEND) continue;
		float turn = opens * POINT_POSE_SEED - bend;
		Vec3 angles = self.cur.angles[j];
		angles[(usz)axis] = math::clamp(angles[(usz)axis] + turn, row.minimum, row.maximum);
		Vec3 ankle = self.cur.x[child];
		self.cur.angles[j] = angles;
		self.cur.local[j] = rotation_from_joint_angles(pj.frame, angles);
		self.cur.walk(self.skeleton);
		// And the joint above turned to put what hangs below the hinge back where it
		// was, as far as it goes: the bend is the limb's, not a pin torn loose.
		if (self.turns[parent])
		{
			Quaternionf back = bone_carry(self.cur.x[child] - self.cur.x[parent], ankle - self.cur.x[parent]);
			self.cur.local[parent] = self.limited(parent, self.above(&self.cur, parent).invert().mul(back).mul(self.cur.world[parent]).normalize());
			if (self.joint_of(parent).limited()) self.cur.angles[parent] = joint_angles_from_rotation(self.joint_of(parent).frame, self.cur.local[parent]);
			self.cur.walk(self.skeleton);
		}
	}
	self.seed_straight_pulls();
	// A bend turns the shin and so tilts what hangs below it: every held world rotation
	// is put back, so a seed costs the holds nothing and is not undone for them.
	for (usz j = 0; j < self.n; j++)
	{
		if (!self.turns[j] || self.rot_of[j] < 0) continue;
		self.cur.walk(self.skeleton);
		self.cur.local[j] = self.limited(j, self.above(&self.cur, j).invert().mul(self.goals[(usz)self.rot_of[j]].orient).normalize());
		if (self.joint_of(j).limited()) self.cur.angles[j] = joint_angles_from_rotation(self.joint_of(j).frame, self.cur.local[j]);
	}
	self.cur.walk(self.skeleton);
}

<*
 Start a joint bent a little where a pull runs straight along its limb.

 A grab pulled along the line from a joint to the joint it carries asks that joint for
 nothing at first order: turning it moves the grab across the pull, never along it, so
 the answer slides the whole body instead of folding the limb, though folding is far
 the cheaper. A joint that is free to turn and stands collinear with such a pull is
 bent toward the side the pull has to spare, or — where it has none — toward a fixed
 side, by as much as the pull is long next to the limb (`POINT_POSE_SEED` at most).
 Only where it starts: the pull back toward where it began straightens it again if the
 limb is not squeezed.
*>
fn void BodySolve.seed_straight_pulls(&self)
{
	foreach (usz g, &goal : self.goals)
	{
		if (!self.live[g] || !self.ramped[g]) continue;
		Vec3 pull = goal.target - self.from[g];
		float pull_length = pull.length();
		if (pull_length < self.h * 1.0e-3f) continue;
		for (int walk = self.skeleton.parents[goal.joint]; walk >= 0; walk = self.skeleton.parents[(usz)walk])
		{
			usz j = (usz)walk;
			if (!self.turns[j]) continue;
			PointJoint* pj = self.joint_of(j);
			if (pj.limited() && self.one_sided_hinge(j) != 0.0f) continue;
			Vec3 lever = self.from[g] - self.cur.x[j];
			float lever_length = lever.length();
			if (lever_length < self.h * 1.0e-3f) continue;
			Vec3 across = lever.cross(pull);
			if (across.length() > 0.05f * lever_length * pull_length) continue;
			// The side the pull has to spare, else a fixed one.
			Vec3 side = pull - lever * (pull.dot(lever) / (lever_length * lever_length));
			if (side.length() < 1.0e-3f * pull_length) side = math::abs(lever.x) < 0.9f * lever_length ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 0, 1 };
			Vec3 axis = lever.cross(side).normalize();
			float bend = math::min(POINT_POSE_SEED, (float)math::sqrt(pull_length / lever_length));
			// Along the axis the joint's own limits leave it, as nearly as they can.
			Vec3 turn_axis = axis;
			Quaternionf by = body_solve_turn(turn_axis * bend);
			self.cur.local[j] = self.limited(j, self.above(&self.cur, j).invert().mul(by).mul(self.cur.world[j]).normalize());
			if (pj.limited()) self.cur.angles[j] = joint_angles_from_rotation(pj.frame, self.cur.local[j]);
			self.cur.walk(self.skeleton);
			break;
		}
	}
}

<*
 The whole solve: the hinges and the straight pulls seeded, then the cost minimised
 with the grab carried to the pointer in `POINT_POSE_RAMP` sub-steps — one when there
 is no grab to carry.

 Each sub-step is minimised to rest (`BODY_SOLVE_EARLY_SAVING`) before the next, not
 left half-done: the last one starts from where the one before it came to, and a
 body that is free to settle into either of two folds of a limb settles into the same
 one for neighbouring pointer positions only if the walk to it was the same walk.
 While a body in the air is carried the root's slide is made dear
 (`POINT_POSE_FLOATING_SLIDE`) until the last sub-step, so the limbs and the trunk
 reach first and the root takes up what they could not.
*>
fn void BodySolve.run(&self)
{
	int per = self.settings.iterations > 0 ? self.settings.iterations : BODY_SOLVE_ITERATIONS;
	if (diag_iterations > 0) per = diag_iterations;
	self.seed_bends();
	bool carried = false;
	foreach (usz g, used : self.ramped) if (used && self.use_pos[g]) carried = true;
	int ramp = carried ? POINT_POSE_RAMP : 1;
	if (carried && diag_ramp > 0) ramp = diag_ramp;
	double lambda = BODY_SOLVE_DAMPING;
	self.pin = POINT_POSE_PIN;
	for (int sub = 1; sub <= ramp; sub++)
	{
		float along = (float)sub / (float)ramp;
		if (diag_trace) diag_log.appendf("  substep %d/%d\n", sub, ramp);
		foreach (usz g, &goal : self.goals)
		{
			if (self.ramped[g]) self.aim[g] = self.from[g] + (goal.target - self.from[g]) * along;
		}
		lambda = BODY_SOLVE_DAMPING;
		self.slide_boost = !self.grounded && sub < ramp ? POINT_POSE_FLOATING_SLIDE : 1.0f;
		bool last = sub == ramp;
		self.minimise(last ? per : math::min(per, diag_early_iterations > 0 ? diag_early_iterations : BODY_SOLVE_EARLY_ITERATIONS), last ? (diag_saving > 0.0 ? diag_saving : BODY_SOLVE_SAVING) : (diag_early > 0.0 ? diag_early : BODY_SOLVE_EARLY_SAVING), &lambda);
	}
	diag_cost = self.evaluate(&self.cur, false);
	diag_terms[..] = 0.0;
	foreach (usz g, &goal : self.goals)
	{
		if (!self.live[g]) continue;
		usz j = goal.joint;
		if (self.use_pos[g])
		{
			Vec3 r = (self.cur.x[j] - self.aim[g]) / self.h;
			diag_terms[goal.soft ? 0 : 2] += (goal.soft ? 1.0 : (double)self.pin) * (double)r.dot(r);
		}
		if (self.use_rot[g])
		{
			Vec3 r = body_solve_log(self.cur.world[j].mul(goal.orient.invert()).normalize()) * POINT_POSE_TURN_LENGTH;
			double w = goal.turn_weight > 0.0f ? goal.turn_weight : self.pin;
			diag_terms[goal.soft ? 1 : 3] += w * (double)r.dot(r);
		}
	}
	diag_terms[4] = self.part_rows(&self.cur, false);
	diag_terms[5] = self.joint_rows(&self.cur, false);
}

// ---------------------------------------------------------------------------
// The closing polish

fn Quaternionf BodySolve.above(&self, BodySolveState* s, usz j)
{
	int parent = self.skeleton.parents[j];
	return parent >= 0 ? s.world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
}

// Whether joint `j` has a turn of its own to polish with.
fn bool BodySolve.can_turn(&self, usz j) => self.turns[j] || (self.skeleton.parents[j] < 0 && self.count[j] > 3);

// Whether joint `j` holds a world rotation hard.
fn bool BodySolve.holds_hard(&self, usz j) => self.rot_of[j] >= 0 && self.goals[(usz)self.rot_of[j]].turn_weight <= 0.0f;

<*
 Each pin brought the last of the way onto its point by its own limb: a few
 passes of limited CCD over the joints between the pin and the fork its limb
 hangs from, nearest first. The solve leaves a pin a hair short where it
 compromised with a grab or a limit, and a pin is held exactly or not at all.
*>
fn void BodySolve.polish_limbs(&self, BodySolveState* s, float close, int passes = 8)
{
	for (usz g = 0; g < self.n; g++)
	{
		if (self.pin_of[g] < 0) continue;
		Vec3 target = self.goals[(usz)self.pin_of[g]].target;
		for (int pass = 0; pass < passes; pass++)
		{
			self.place(s);
			if ((s.x[g] - target).length() <= close) break;
			for (usz pivot = g;;)
			{
				int parent = self.skeleton.parents[pivot];
				if (parent < 0 || !self.framed[(usz)parent] || self.pin_of[(usz)parent] >= 0) break;
				pivot = (usz)parent;
				if (self.can_turn(pivot) && !self.holds_hard(pivot))
				{
					Quaternionf turn = bone_carry(s.x[g] - s.x[pivot], target - s.x[pivot]);
					s.local[pivot] = self.limited(pivot, self.above(s, pivot).invert().mul(turn).mul(s.world[pivot]).normalize());
					if (self.joint_of(pivot).limited()) s.angles[pivot] = joint_angles_from_rotation(self.joint_of(pivot).frame, s.local[pivot]);
					self.place(s);
				}
				// Up to and including the joint the fork carries: the fork itself turns
				// the other limbs too.
				int grand = self.skeleton.parents[pivot];
				if (grand < 0 || self.children[(usz)grand] != 1) break;
			}
		}
	}
	self.place(s);
}

<*
 Pins their limbs could not reach: the root slid by their average miss, so the
 next polish starts from a body they can reach.

 @return `True when the root moved.`
*>
fn bool BodySolve.shift_root_to_pins(&self, float close)
{
	BodySolveState* s = &self.cur;
	Vec3 sum = {};
	usz missing = 0;
	usz root = self.n;
	for (usz g = 0; g < self.n; g++)
	{
		if (self.pin_of[g] < 0) continue;
		Vec3 miss = self.goals[(usz)self.pin_of[g]].target - s.x[g];
		if (miss.length() <= close * 10.0f) continue;
		sum = sum + miss;
		missing++;
		root = self.root_of[g];
	}
	if (missing == 0 || root >= self.n || self.count[root] == 0) return false;
	// A root held by a pin of its own is put on it, the others coming after.
	if (self.pin_of[root] >= 0)
	{
		sum = self.goals[(usz)self.pin_of[root]].target - s.x[root];
		missing = 1;
	}
	s.rest[root] = s.rest[root] + sum / (float)missing;
	self.place(s);
	return true;
}

<*
 The pins put exactly on their points, then the hard angles set again under the
 limbs the polish moved.
*>
fn void BodySolve.polish(&self)
{
	float close = self.h * 1.0e-5f;
	for (int round = 0; round < POINT_POSE_POLISH_ROUNDS; round++)
	{
		(void)self.shift_root_to_pins(close);
		self.polish_limbs(&self.cur, close);
		// Pins that hang from each other, a shoulder from a chest, shift one another
		// by a hair as each is closed: go round again until none is off.
		if (self.worst_pin_miss() <= close * 10.0f) break;
	}
	BodySolveState* s = &self.cur;
	for (usz j = 0; j < self.n; j++)
	{
		if (!self.holds_hard(j) || !self.can_turn(j)) continue;
		self.place(s);
		s.local[j] = self.limited(j, self.above(s, j).invert().mul(self.goals[(usz)self.rot_of[j]].orient).normalize());
	}
	s.walk(self.skeleton);
}

// How far the farthest pin standing is from its point.
fn float BodySolve.worst_pin_miss(&self)
{
	float worst = 0.0f;
	for (usz g = 0; g < self.n; g++)
	{
		if (self.pin_of[g] < 0) continue;
		worst = math::max(worst, (self.cur.x[g] - self.goals[(usz)self.pin_of[g]].target).length());
	}
	return worst;
}

<*
 Write what the solve turned, and the root's slide, into `pose`. A joint it did
 not turn keeps its rotation bit for bit.
*>
fn void BodySolve.save(&self, rig::Pose* pose)
{
	for (usz j = 0; j < self.n; j++)
	{
		if (self.turns[j])
		{
			pose.rotations[j] = self.cur.local[j];
			continue;
		}
		if (self.skeleton.parents[j] >= 0 || self.count[j] == 0) continue;
		if (self.count[j] > 3) pose.rotations[j] = self.cur.local[j];
		Vec3 moved = self.cur.rest[j] - self.began.rest[j];
		if (moved.length_sq() > 0.0f) pose.offsets[j] = pose.offsets[j] + moved;
	}
}

<*
 Solve `pose` in place so the joints in play meet `goals`.

 `settings.posture`, when it has an entry per joint, is the pose the stiffness
 pulls back toward; otherwise the pose handed in is.

 @return `The largest miss of any position goal still standing, in model units; each goal's own is in its residual.`
*>
fn float body_solve(rig::Skeleton* skeleton, rig::Pose* pose, PointJoint[] joints, PointGoal[] goals,
	PointPoseSettings* settings)
{
	usz n = skeleton.len();
	if (n == 0 || pose.rotations.len != n || pose.offsets.len != n) return 0.0f;
	@pool()
	{
		BodySolve s;
		s.open(skeleton, pose, joints, goals, settings);
		if (s.active)
		{
			s.run();
			s.polish();
			diag_cost_polished = s.evaluate(&s.cur, false);
			s.save(pose);
		}
		settings.balance_miss = s.balance_on ? s.balance_error(&s.cur).length() : 0.0f;
	};
	return point_pose_measure(skeleton, pose, goals);
}

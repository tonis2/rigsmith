<*
 Whole-body IK: one solve that moves the root and bends every joint between the
 grabbed joint and the pinned ones together, inside their limits.

 	`body_ik(&skeleton, &pose, joints, goals, &settings);`

 **Why one solve and not a chain plus fix-ups.** Posing used to turn the grabbed
 joint's own run and then bend each pinned leg back afterwards. That can only
 ever move what the grab already moved: pull a figure down by the waist and the
 spine bends, the hips stay where they are, and the pinned feet have nothing to
 give way to. Solving everything at once lets the pins *pull the body* — the root
 slides down, the thighs and knees fold, and the feet stay on the floor — because
 every degree of freedom answers every goal at the same time.

 **The method** is damped least squares over a small Jacobian. Every allowed limit
 axis of every joint in play is one column, the root's translation is three more,
 and every goal is three rows: where the goal joint is, against where it should
 be. Each iteration takes the step that best reduces the weighted error for the
 least weighted motion,

     d = W⁻¹ Jᵀ (J W⁻¹ Jᵀ + λ² I)⁻¹ e

 with pins weighted far above the grab (so the grab is what gives way when both
 cannot hold) and each column weighted by the joint's stiffness (so a waist pull
 drops the hips and folds the legs before it bends the back). The step is taken
 about the joint's carried limit axes and clamped back into its limits, so a
 hinge knee only ever bends one way.

 **Straight limbs.** A leg held perfectly straight has no first-order way to get
 shorter, which is exactly the T-pose — and a knee modelled slightly hyper-
 extended is worse, since folding it the right way first makes the leg longer.
 A joint marked `bend_hint` with a one-sided range is kept a few degrees past
 straight on the side the range opens, measured from the joints themselves
 (`body_unfold`), so the limb always has a direction to fold and it is the one
 its limits allow.

 **Balance.** With `settings.balance` the solve has one more goal: the body's
 centre of mass, seen from above, over `settings.support` — the midpoint of the
 planted feet. It weighs less than the grab, and the root may *tilt* as well as
 slide for it, so as the hips go back the upper body leans forward over the feet
 the way a person's does rather than sitting back into thin air. Mass is spread
 over the joints by bone length, which is rough but puts it where the body is.

 Pure: it reads the skeleton and writes only the pose handed to it.
*>
module crig;

import rig;
import std::math;
import std::math::matrix;
import std::math::quaternion;

// Goals and columns one solve holds. A figure pinned by the feet and the hands
// with one grab is five goals; the columns cover every joint on those paths.
const usz BODY_IK_MAX_GOALS = 9;
const usz BODY_IK_MAX_DOF = 96;
// Every goal's three rows, and three more for the centre of mass.
const usz BODY_IK_ROWS = (BODY_IK_MAX_GOALS + 1) * 3;

// The balance goal's weight in the cost a step is judged by, against the grab's 1.
const float BODY_IK_BALANCE_WEIGHT = 0.5;

// The furthest the balance tilts the root from where the gesture found it, in
// radians (about 55 degrees) — a deep squat's lean, and a stop for a figure whose
// weight cannot be brought over its feet at all.
const float BODY_IK_MAX_LEAN = 0.96;

// The legs' share of the body's mass; the rest is the trunk, head and arms.
// Roughly a person's (two legs are about a third), and what makes the lean come
// out right whatever the bone count — a hand's many finger bones would otherwise
// outweigh the chest.
const float BODY_IK_LEG_MASS = 0.32;

// Iterations per solve. Warm-started from the last mouse move's answer, so a
// frame only has to follow the pointer's step, not solve from scratch.
const int BODY_IK_ITERATIONS = 64;

// Damping, as a share of the figure's height: large enough that a nearly
// straight limb does not take a wild step, small enough to converge in a frame.
const float BODY_IK_DAMPING = 0.02;

// The furthest a goal is chased in one iteration, as a share of the height, and
// the largest turn one column takes. Both keep an iteration in the region where
// the linearisation is honest.
const float BODY_IK_MAX_REACH = 0.1;
const float BODY_IK_MAX_TURN = 0.25;

// How far a `bend_hint` joint is started into a one-sided range, in radians
// (about three degrees).
const float BODY_IK_PREFERRED_BEND = 0.05;

// Extra iterations for the posture phase, after the goals are reached.
const int BODY_IK_POSTURE_ITERATIONS = 40;

// A goal nearer than this share of the height counts as reached.
const float BODY_IK_TOLERANCE = 0.001;

<*
 One joint whose rotation the solve may change.

 Constrained joints with a usable frame turn about their allowed limit axes and
 are clamped back into range; any other joint turns freely about the world axes.
*>
struct BodyJoint
{
	usz joint;
	JointLimitFrame frame;
	JointRotationLimits limits;
	float stiffness;  // column weight: 1 is ordinary, higher turns less
	bool bend_hint;   // keep a one-sided hinge past straight — see `body_unfold`
	usz child;        // for a bend hint: the next joint down the limb it bends
}

struct BodyGoal
{
	usz joint;
	Vec3 target;      // model space
	float weight;     // 1 for the grab, far higher for a pin
	float residual;   // out: how far it ended from the target
	bool stands;      // a planted foot: the limb above it is a leg, for the balance
}

struct BodyIkSettings
{
	usz root;
	bool moves_root;       // the root's translation is three more columns
	float root_stiffness;
	float height;
	int iterations;
	bool balance;          // hold the centre of mass over `support`, tilting the root for it
	Vec3 support;          // model space; only its horizontal part is read
	float balance_weight;
	float tilt_stiffness;  // the root's tilt columns, used only with `balance`
	Quaternionf tilt_from; // the root's rotation when the gesture began; the lean is measured from it
	Vec3 up;               // unit; zero means +Y
	float balance_miss;    // out: how far the centre of mass ended from over `support`
	bool pitch;            // the root may turn for the goals themselves — see `flex_axis`
	Vec3 flex_axis;        // unit; the axis the body folds about (zero: every axis costs alike)
	float lateral_cost;    // how many times dearer a turn about any other axis is than about `flex_axis`
	Quaternionf[] posture; // per skeleton joint, the local rotations the gesture began with; empty for none
	float posture_pull;    // how much of each joint's drift from `posture` is undone per iteration, 0 to 1
}

fn bool BodyJoint.limited(&self) => self.limits.constrained && self.frame.usable();

<*
 What a turn about `axis` costs, against one about the flex axis: 1 for that axis
 (or when none is set), `lateral_cost` for any other. The way a body that folds in
 one plane — a dog's trunk and legs — is kept from reaching a target by bending
 sideways or twisting when it can fold instead.
*>
fn float body_axis_cost(BodyIkSettings* settings, Vec3 axis) @local
{
	if (settings.flex_axis.length_sq() < 0.5f || settings.lateral_cost <= 1.0f) return 1.0f;
	return math::abs(axis.dot(settings.flex_axis)) > 0.7f ? 1.0f : settings.lateral_cost;
}

// Whether `ancestor` is strictly above `joint`. Joints are ordered parents
// first, so the climb ends.
fn bool body_above(rig::Skeleton* skeleton, usz ancestor, usz joint)
{
	int walk = skeleton.parents[joint];
	while (walk >= 0)
	{
		if ((usz)walk == ancestor) return true;
		walk = skeleton.parents[(usz)walk];
	}
	return false;
}

<*
 Keep every `bend_hint` hinge a little past *straight*, on the side its range
 opens toward — measured from where the joints actually are, not from the rest
 angle.

 The rest angle is not straight. A model is often built with its knee a few
 degrees hyper-extended — Zidane's thigh runs down and back, his shin down and
 forward — so a knee at 0 of its 0..150 range is already bent the wrong way, and
 folding it the right way first *lengthens* the leg until it passes straight.
 The solve, asked to lower the hips, then sees only the shorter leg on the wrong
 side, which the limit refuses, and stalls. So the bend is read off the parent,
 the joint and `child`: the signed angle between the upper and lower bone about
 the hinge axis, which is 0 when they are in line. Anything short of
 `BODY_IK_PREFERRED_BEND` past that on the open side is turned there.

 Only one-sided allowed axes count, and only joints with a parent and a child.
*>
fn void body_unfold(rig::Skeleton* skeleton, rig::Pose* pose, BodyJoint[] joints)
{
	foreach (&j : joints)
	{
		if (!j.bend_hint || !j.limited() || j.child >= skeleton.len()) continue;
		int parent = skeleton.parents[j.joint];
		if (parent < 0) continue;
		foreach (usz k, axis : j.limits.axes)
		{
			if (!axis.allowed || axis.maximum - axis.minimum < BODY_IK_PREFERRED_BEND * 4.0f) continue;
			float opens;
			if (math::abs(axis.minimum) < 1.0e-3f) { opens = 1.0f; }
			else if (math::abs(axis.maximum) < 1.0e-3f) { opens = -1.0f; }
			else { continue; }

			Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
			if (catch built) return;
			Matrix4f[] palette = built;
			defer alloc::free(mem, palette);
			Quaternionf[]? spun = pose.world_rotations(mem, skeleton);
			if (catch spun) return;
			Quaternionf[] world = spun;
			defer alloc::free(mem, world);

			Vec3 hinge = carried_joint_limit_frame(j.frame, skeleton, world, j.joint).rotate_vec3(AXIS_DIRECTION[k]);
			Vec3 at = skeleton.joints[j.joint].transform(palette[j.joint]);
			Vec3 upper = at - skeleton.joints[(usz)parent].transform(palette[(usz)parent]);
			Vec3 lower = skeleton.joints[j.child].transform(palette[j.child]) - at;
			upper = upper - hinge * upper.dot(hinge);
			lower = lower - hinge * lower.dot(hinge);
			if (upper.length_sq() < 1.0e-12f || lower.length_sq() < 1.0e-12f) continue;
			// A turn of the joint by +t about the hinge turns the lower bone by +t, so
			// this angle moves one for one with the axis's own.
			float bend = (float)math::atan2(hinge.dot(upper.cross(lower)), upper.dot(lower));
			float short_by = BODY_IK_PREFERRED_BEND - bend * opens;
			if (short_by <= 0.0f) continue;

			Vec3 angles = joint_angles_from_rotation(j.frame, pose.rotations[j.joint]);
			angles[k] += short_by * opens;
			pose.rotations[j.joint] = constrain_joint_rotation(j.frame, j.limits,
				rotation_from_joint_angles(j.frame, angles));
		}
	}
}

<*
 Solve `pose` in place toward every goal, moving only `joints` and, when
 `settings.moves_root`, the root's translation.

 @return `The largest remaining weighted miss, in model units (each goal's own miss is left in its residual).`
*>
fn float body_ik(rig::Skeleton* skeleton, rig::Pose* pose, BodyJoint[] joints, BodyGoal[] goals,
	BodyIkSettings* settings)
{
	float h = settings.height > 0.0f ? settings.height : 1.0f;
	usz goal_count = math::min((usz)goals.len, BODY_IK_MAX_GOALS);
	BodyBalance balance = body_balance_open(skeleton, settings, goals[:goal_count]);
	defer balance.free();
	float reach = h * BODY_IK_MAX_REACH;
	float lambda = h * BODY_IK_DAMPING;
	float tolerance = h * BODY_IK_TOLERANCE;
	int iterations = settings.iterations > 0 ? settings.iterations : BODY_IK_ITERATIONS;

	// Columns: each joint's axes, then the root's translation.
	usz[BODY_IK_MAX_DOF] col_joint;   // index into `joints`, or joints.len for the root
	Vec3[BODY_IK_MAX_DOF] col_axis;
	float[BODY_IK_MAX_DOF] col_inverse_stiffness;
	float[BODY_IK_MAX_DOF][BODY_IK_ROWS] jac;
	float[BODY_IK_ROWS] error;
	float[BODY_IK_ROWS][BODY_IK_ROWS] system;
	float[BODY_IK_ROWS][BODY_IK_ROWS] goal_system;
	float[BODY_IK_ROWS] y;
	float[BODY_IK_ROWS] u;
	float[BODY_IK_MAX_DOF] primary_inverse;
	float[BODY_IK_MAX_DOF][3] pulled;
	float[BODY_IK_MAX_DOF] step;
	Vec3[BODY_IK_MAX_GOALS] reached;
	Quaternionf[BODY_IK_MAX_DOF] kept_rotation;
	Vec3 kept_offset;

	Quaternionf kept_tilt;
	// How much closer the last kept step brought the balance.
	float balance_gain = 1.0e30f;
	float cost = body_cost(skeleton, pose, goals[:goal_count], reached[..], &balance);
	if (cost < 0.0f) return 0.0f;
	// The posture is a last phase, run once the goals have been reached as far as
	// they will be: drawing joints back while the goals are still being chased
	// only makes the chase stall.
	bool posture_on = settings.posture.len == skeleton.len() && settings.posture_pull > 0.0f;
	bool relaxing = false;
	int relax_left = BODY_IK_POSTURE_ITERATIONS;
	for (int iteration = 0; iteration < iterations + (posture_on ? BODY_IK_POSTURE_ITERATIONS : 0); iteration++)
	{
		float worst = 0.0f;
		for (usz g = 0; g < goal_count; g++) worst = math::max(worst, goals[g].residual);
		// The balance is a preference, not a demand: once the goals hold, it runs
		// until it is met or stops getting closer.
		bool settled = !balance.on || balance.miss <= tolerance
			|| balance_gain < tolerance * 0.01f || lambda > h;
		if ((worst <= tolerance && settled) || iteration >= iterations)
		{
			if (!posture_on || relax_left <= 0) break;
			relaxing = true;
			relax_left--;
		}
		float balance_before = balance.miss;

		Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
		if (catch built) break;
		Matrix4f[] palette = built;
		defer alloc::free(mem, palette);
		Quaternionf[]? spun = pose.world_rotations(mem, skeleton);
		if (catch spun) break;
		Quaternionf[] world = spun;
		defer alloc::free(mem, world);

		// Each goal's miss, chased at most `reach` in one step.
		for (usz g = 0; g < goal_count; g++)
		{
			Vec3 miss = goals[g].target - reached[g];
			float length = miss.length();
			if (length > reach) miss = miss * (reach / length);
			for (usz c = 0; c < 3; c++) error[g * 3 + c] = miss[c] * goals[g].weight;
		}
		usz mass_row = goal_count * 3;
		if (balance.on)
		{
			balance.gather(skeleton, palette);
			Vec3 miss = balance.flat(settings.support - balance.centre);
			float length = miss.length();
			if (length > reach) miss = miss * (reach / length);
			for (usz c = 0; c < 3; c++) error[mass_row + c] = miss[c] * balance.weight;
		}

		// The columns, rebuilt every iteration since the carried axes turn with the
		// parents above them.
		usz cols = 0;
		foreach (usz ji, &j : joints)
		{
			Vec3 pivot = skeleton.joints[j.joint].transform(palette[j.joint]);
			Quaternionf carried = j.limited()
				? carried_joint_limit_frame(j.frame, skeleton, world, j.joint)
				: (Quaternionf)quaternion::IDENTITY;
			for (usz k = 0; k < 3 && cols < BODY_IK_MAX_DOF; k++)
			{
				if (j.limited() && !j.limits.axes[k].allowed) continue;
				Vec3 axis = carried.rotate_vec3(AXIS_DIRECTION[k]);
				col_joint[cols] = ji;
				col_axis[cols] = axis;
				col_inverse_stiffness[cols] = 1.0f / math::max(j.stiffness * body_axis_cost(settings, axis), 1.0e-3f);
				for (usz g = 0; g < goal_count; g++)
				{
					Vec3 d = body_above(skeleton, j.joint, goals[g].joint)
						? axis.cross(reached[g] - pivot) * goals[g].weight
						: (Vec3){};
					for (usz c = 0; c < 3; c++) jac[g * 3 + c][cols] = d[c];
				}
				if (balance.on)
				{
					Vec3 d = balance.flat(balance.turned_by(j.joint, axis, pivot)) * balance.weight;
					for (usz c = 0; c < 3; c++) jac[mass_row + c][cols] = d[c];
				}
				cols++;
			}
		}
		usz root_col = cols;
		if (settings.moves_root)
		{
			for (usz k = 0; k < 3 && cols < BODY_IK_MAX_DOF; k++)
			{
				col_joint[cols] = joints.len;
				col_axis[cols] = AXIS_DIRECTION[k];
				col_inverse_stiffness[cols] = 1.0f / math::max(settings.root_stiffness, 1.0e-3f);
				for (usz g = 0; g < goal_count; g++)
				{
					bool under = goals[g].joint == settings.root
						|| body_above(skeleton, settings.root, goals[g].joint);
					// Scaled by the height, so a unit of translation weighs the same as a
					// radian of turn at the far end of a limb, whatever the model's units.
					for (usz c = 0; c < 3; c++)
					{
						jac[g * 3 + c][cols] = under && c == k ? h * goals[g].weight : 0.0f;
					}
				}
				if (balance.on)
				{
					Vec3 d = balance.flat(AXIS_DIRECTION[k]) * (h * balance.weight);
					for (usz c = 0; c < 3; c++) jac[mass_row + c][cols] = d[c];
				}
				cols++;
			}
		}
		// The root's tilt, for the lean: a turn about the root carries everything
		// hanging from it, the pinned legs included, which then fold to hold.
		usz tilt_col = cols;
		bool tilts = balance.on || settings.pitch;
		if (tilts)
		{
			Vec3 pivot = skeleton.joints[settings.root].transform(palette[settings.root]);
			for (usz k = 0; k < 3 && cols < BODY_IK_MAX_DOF; k++)
			{
				Vec3 axis = AXIS_DIRECTION[k];
				// A body that folds in one plane turns its root about that plane's axis only.
				if (settings.pitch && body_axis_cost(settings, axis) > 1.0f) continue;
				col_joint[cols] = joints.len + 1;
				col_axis[cols] = axis;
				// Turned for the goals, the root folds about the flex axis by preference;
				// turned for the balance alone it is kept stiff and out of the goal step.
				float tilt_stiffness = settings.pitch ? body_axis_cost(settings, axis) : settings.tilt_stiffness;
				col_inverse_stiffness[cols] = 1.0f / math::max(tilt_stiffness, 1.0e-3f);
				for (usz g = 0; g < goal_count; g++)
				{
					Vec3 d = body_above(skeleton, settings.root, goals[g].joint)
						? axis.cross(reached[g] - pivot) * goals[g].weight
						: (Vec3){};
					for (usz c = 0; c < 3; c++) jac[g * 3 + c][cols] = d[c];
				}
				Vec3 d = balance.on ? balance.flat(balance.turned_by(settings.root, axis, pivot)) * balance.weight : (Vec3){};
				for (usz c = 0; c < 3; c++) jac[mass_row + c][cols] = d[c];
				cols++;
			}
		}
		if (cols == 0) break;

		// The goals first: d₁ = W⁻¹ Jᵀ (J W⁻¹ Jᵀ + λ² I)⁻¹ e. The tilt is kept out of
		// it — bowing at the hips reaches a waist target as well as sitting does,
		// and that is not what the pull asked for.
		usz goal_rows = goal_count * 3;
		for (usz c = 0; c < cols; c++) primary_inverse[c] = c >= tilt_col && !settings.pitch ? 0.0f : col_inverse_stiffness[c];
		body_normal_system(&jac, primary_inverse[..], goal_rows, cols, lambda, &system);
		for (usz r = 0; r < goal_rows; r++) y[r] = error[r];
		if (!body_solve_linear(&system, &y, goal_rows)) break;
		for (usz c = 0; c < cols; c++)
		{
			float sum = 0.0f;
			for (usz r = 0; r < goal_rows; r++) sum += jac[r][c] * y[r];
			step[c] = sum * primary_inverse[c];
		}

		// Then the posture: every joint drawn back toward the rotation it began the
		// gesture with, again only in what leaves the goals where they are. Without
		// it the goals' null space is free, and a solve that wanders through many
		// small moves ends with a joint swung a radian one way and its child a
		// radian back — a pose that reaches the pins and looks broken.
		if (relaxing)
		{
			float[BODY_IK_MAX_DOF] drawn;
			for (usz c = 0; c < root_col; c++)
			{
				BodyJoint* j = &joints[col_joint[c]];
				int parent = skeleton.parents[j.joint];
				Quaternionf above = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
				Quaternionf drift = above.mul(pose.rotations[j.joint]).mul(settings.posture[j.joint].invert()).mul(above.invert()).normalize();
				if (drift.v.w < 0.0f) drift.v = -drift.v;
				Vec3 part = { drift.v.x, drift.v.y, drift.v.z };
				float sine = part.length();
				float angle = 2.0f * math::atan2(sine, drift.v.w);
				drawn[c] = sine < 1.0e-9f ? 0.0f : -settings.posture_pull * angle * part.dot(col_axis[c]) / sine;
			}
			for (usz c = root_col; c < cols; c++) drawn[c] = 0.0f;
			body_normal_system(&jac, primary_inverse[..], goal_rows, cols, lambda, &goal_system);
			for (usz r = 0; r < goal_rows; r++)
			{
				float sum = 0.0f;
				for (usz c = 0; c < cols; c++) sum += jac[r][c] * drawn[c];
				u[r] = sum;
			}
			if (goal_rows == 0 || body_solve_linear(&goal_system, &u, goal_rows))
			{
				for (usz c = 0; c < cols; c++)
				{
					float sum = 0.0f;
					for (usz r = 0; r < goal_rows; r++) sum += jac[r][c] * u[r];
					step[c] += drawn[c] - primary_inverse[c] * sum;
				}
			}
		}

		// Then the balance, only in what leaves the goals where they are: each of
		// its rows' pull B = W⁻¹ J₂ᵀ, projected by N = I − W⁻¹ J₁ᵀ S⁻¹ J₁ with
		// S = J₁ W⁻¹ J₁ᵀ + λ² I, and d₂ = N B (J₂ N B + λ² I)⁻¹ (e₂ − J₂ d₁).
		if (balance.on)
		{
			body_normal_system(&jac, col_inverse_stiffness[..], goal_rows, cols, lambda, &goal_system);
			for (usz k = 0; k < 3; k++)
			{
				for (usz c = 0; c < cols; c++) pulled[k][c] = col_inverse_stiffness[c] * jac[mass_row + k][c];
				for (usz r = 0; r < goal_rows; r++)
				{
					float sum = 0.0f;
					for (usz c = 0; c < cols; c++) sum += jac[r][c] * pulled[k][c];
					u[r] = sum;
				}
				system = goal_system;
				if (goal_rows > 0 && !body_solve_linear(&system, &u, goal_rows)) break;
				for (usz c = 0; c < cols; c++)
				{
					float sum = 0.0f;
					for (usz r = 0; r < goal_rows; r++) sum += jac[r][c] * u[r];
					pulled[k][c] -= col_inverse_stiffness[c] * sum;
				}
			}
			for (usz a = 0; a < 3; a++)
			{
				for (usz k = 0; k < 3; k++)
				{
					float sum = 0.0f;
					for (usz c = 0; c < cols; c++) sum += jac[mass_row + a][c] * pulled[k][c];
					system[a][k] = sum + (a == k ? lambda * lambda : 0.0f);
				}
				float left = error[mass_row + a];
				for (usz c = 0; c < cols; c++) left -= jac[mass_row + a][c] * step[c];
				y[a] = left;
			}
			if (body_solve_linear(&system, &y, 3))
			{
				for (usz c = 0; c < cols; c++)
				{
					step[c] += pulled[0][c] * y[0] + pulled[1][c] * y[1] + pulled[2][c] * y[2];
				}
			}
		}

		// Scaled down whole (not per column, which would bend its direction) when
		// any turn in it is past the largest one step may take.
		float largest = 0.0f;
		for (usz c = 0; c < cols; c++)
		{
			if (c < root_col || c >= tilt_col) largest = math::max(largest, math::abs(step[c]));
		}
		float scale = largest > BODY_IK_MAX_TURN ? BODY_IK_MAX_TURN / largest : 1.0f;

		// Try the step; keep it only if the weighted miss went down. Otherwise put
		// the pose back and damp harder — Levenberg–Marquardt's rule, which is what
		// keeps a nearly straight limb from overshooting back and forth.
		foreach (usz ji, j : joints) kept_rotation[ji] = pose.rotations[j.joint];
		kept_offset = pose.offsets[settings.root];
		kept_tilt = pose.rotations[settings.root];
		usz c = 0;
		while (c < root_col)
		{
			usz ji = col_joint[c];
			BodyJoint* j = &joints[ji];
			Quaternionf turn = quaternion::IDENTITY;
			while (c < root_col && col_joint[c] == ji)
			{
				turn = quaternion::from_axis_angle{float}(col_axis[c], step[c] * scale).mul(turn);
				c++;
			}
			int parent = skeleton.parents[j.joint];
			Quaternionf above = parent >= 0 ? world[(usz)parent] : (Quaternionf)quaternion::IDENTITY;
			Quaternionf local = above.invert().mul(turn).mul(above).mul(pose.rotations[j.joint]).normalize();
			if (j.limited()) local = constrain_joint_rotation(j.frame, j.limits, local);
			pose.rotations[j.joint] = local;
		}
		if (settings.moves_root)
		{
			Vec3 slide = {};
			for (usz k = 0; k < 3 && root_col + k < tilt_col; k++) slide[k] = step[root_col + k] * scale * h;
			pose.offsets[settings.root] = pose.offsets[settings.root] + slide;
		}
		if (tilt_col < cols)
		{
			// The root has no parent, so its rotation is already a world one.
			Quaternionf tilt = quaternion::IDENTITY;
			for (usz k = tilt_col; k < cols; k++)
			{
				tilt = quaternion::from_axis_angle{float}(col_axis[k], step[k] * scale).mul(tilt);
			}
			Quaternionf tilted = tilt.mul(pose.rotations[settings.root]).normalize();
			pose.rotations[settings.root] = body_limit_lean(tilted, settings.tilt_from);
		}

		body_unfold(skeleton, pose, joints);
		float tried = body_cost(skeleton, pose, goals[:goal_count], reached[..], &balance);
		// In the posture phase a step is kept if it leaves the goals no worse.
		float allowed = relaxing ? cost * 1.001f + tolerance * tolerance * 0.01f : cost;
		if (tried >= 0.0f && (relaxing ? tried <= allowed : tried < cost))
		{
			cost = tried;
			balance_gain = balance_before - balance.miss;
			lambda = math::max(lambda * 0.5f, h * BODY_IK_DAMPING * 0.25f);
			continue;
		}
		foreach (usz ji, j : joints) pose.rotations[j.joint] = kept_rotation[ji];
		pose.offsets[settings.root] = kept_offset;
		pose.rotations[settings.root] = kept_tilt;
		cost = body_cost(skeleton, pose, goals[:goal_count], reached[..], &balance);
		lambda *= 4.0f;
	}

	settings.balance_miss = balance.on ? balance.miss : 0.0f;
	float worst = 0.0f;
	for (usz g = 0; g < goal_count; g++) worst = math::max(worst, goals[g].residual);
	return worst;
}

<*
 The weighted squared miss of every goal, and where each goal joint stands —
 each goal's own distance left in its residual. -1 when the pose cannot be read.
*>
fn float body_cost(rig::Skeleton* skeleton, rig::Pose* pose, BodyGoal[] goals, Vec3[] reached,
	BodyBalance* balance) @local
{
	Matrix4f[]? built = rig::joint_palette(mem, skeleton, *pose);
	if (catch built) return -1.0f;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);
	float cost = 0.0f;
	if (balance.on)
	{
		balance.gather(skeleton, palette);
		Vec3 miss = balance.flat(balance.support - balance.centre);
		balance.miss = miss.length();
		cost += miss.length_sq() * balance.weight * balance.weight;
	}
	foreach (usz g, &goal : goals)
	{
		reached[g] = skeleton.joints[goal.joint].transform(palette[goal.joint]);
		Vec3 miss = goal.target - reached[g];
		goal.residual = miss.length();
		cost += miss.length_sq() * goal.weight * goal.weight;
	}
	return cost;
}

// S = J W⁻¹ Jᵀ + λ² I over the first `rows` rows.
fn void body_normal_system(float[BODY_IK_MAX_DOF][BODY_IK_ROWS]* jac, float[] inverse, usz rows, usz cols,
	float lambda, float[BODY_IK_ROWS][BODY_IK_ROWS]* out) @local
{
	for (usz r = 0; r < rows; r++)
	{
		for (usz s = r; s < rows; s++)
		{
			float sum = 0.0f;
			for (usz c = 0; c < cols; c++) sum += (*jac)[r][c] * inverse[c] * (*jac)[s][c];
			(*out)[r][s] = sum + (r == s ? lambda * lambda : 0.0f);
			(*out)[s][r] = (*out)[r][s];
		}
	}
}

<*
 Solve the small dense system in place by Gaussian elimination with partial
 pivoting; `y` receives the answer.

 @return `False when the system is singular — damping keeps that from happening in practice.`
*>
fn bool body_solve_linear(float[BODY_IK_ROWS][BODY_IK_ROWS]* a, float[BODY_IK_ROWS]* y, usz n) @local
{
	for (usz col = 0; col < n; col++)
	{
		usz pivot = col;
		for (usz r = col + 1; r < n; r++)
		{
			if (math::abs((*a)[r][col]) > math::abs((*a)[pivot][col])) pivot = r;
		}
		if (math::abs((*a)[pivot][col]) < 1.0e-20f) return false;
		if (pivot != col)
		{
			for (usz k = 0; k < n; k++)
			{
				float t = (*a)[col][k];
				(*a)[col][k] = (*a)[pivot][k];
				(*a)[pivot][k] = t;
			}
			float t = (*y)[col];
			(*y)[col] = (*y)[pivot];
			(*y)[pivot] = t;
		}
		for (usz r = col + 1; r < n; r++)
		{
			float f = (*a)[r][col] / (*a)[col][col];
			if (f == 0.0f) continue;
			for (usz k = col; k < n; k++) (*a)[r][k] -= f * (*a)[col][k];
			(*y)[r] -= f * (*y)[col];
		}
	}
	for (usz i = n; i > 0; i--)
	{
		usz r = i - 1;
		float sum = (*y)[r];
		for (usz k = r + 1; k < n; k++) sum -= (*a)[r][k] * (*y)[k];
		(*y)[r] = sum / (*a)[r][r];
	}
	return true;
}

<*
 The centre of mass the balance goal holds, over the root's own tree.

 Each joint carries half of every bone it touches, by rest length. `gather`
 reads it off a palette along with each joint's share of what hangs below it,
 which is what a turn at that joint moves.
*>
struct BodyBalance
{
	bool on;
	float weight;
	Vec3 support;
	Vec3 up;
	Vec3 sideways;     // unit, or zero: a direction the balance ignores — see `flat`
	float total;
	float[] mass;      // per joint; 0 outside the root's tree
	float[] below;     // mass strictly below each joint
	Vec3[] moment;     // mass-weighted position strictly below each joint
	Vec3 centre;
	float miss;
}

fn BodyBalance body_balance_open(rig::Skeleton* skeleton, BodyIkSettings* settings, BodyGoal[] goals) @local
{
	BodyBalance b = { .on = settings.balance, .support = settings.support };
	if (!b.on) return b;
	b.weight = settings.balance_weight > 0.0f ? settings.balance_weight : BODY_IK_BALANCE_WEIGHT;
	// A body that folds in one plane (`pitch`) balances fore and aft only: weight
	// over an uneven set of planted feet is not a reason to lean it sideways.
	if (settings.pitch) b.sideways = settings.flex_axis;
	b.up = settings.up.length_sq() > 1.0e-12f ? settings.up.normalize() : (Vec3){ 0, 1, 0 };
	usz n = skeleton.len();
	b.mass = alloc::new_array(mem, float, (sz)n);
	b.below = alloc::new_array(mem, float, (sz)n);
	b.moment = alloc::new_array(mem, Vec3, (sz)n);
	// Each bone's length, at its far joint; then the legs — every bone on the way
	// from the root down to a planted foot, and below it — scaled to their share.
	bool[] leg = alloc::new_array(tmem, bool, (sz)n);
	float legs = 0.0f;
	float rest = 0.0f;
	for (usz i = 0; i < n; i++)
	{
		int parent = skeleton.parents[i];
		if (parent < 0 || !body_above(skeleton, settings.root, i)) continue;
		b.mass[i] = (skeleton.joints[i] - skeleton.joints[(usz)parent]).length();
		foreach (goal : goals)
		{
			if (!goal.stands) continue;
			if (goal.joint == i || body_above(skeleton, i, goal.joint) || body_above(skeleton, goal.joint, i))
			{
				leg[i] = true;
				break;
			}
		}
		if (leg[i]) { legs += b.mass[i]; } else { rest += b.mass[i]; }
	}
	if (legs > 0.0f && rest > 0.0f)
	{
		for (usz i = 0; i < n; i++)
		{
			b.mass[i] *= leg[i] ? BODY_IK_LEG_MASS / legs : (1.0f - BODY_IK_LEG_MASS) / rest;
		}
	}
	foreach (m : b.mass) b.total += m;
	if (b.total <= 0.0f) b.on = false;
	return b;
}

<*
 `tilted`, turned back toward `from` until it is no more than `BODY_IK_MAX_LEAN`
 away from it.
*>
fn Quaternionf body_limit_lean(Quaternionf tilted, Quaternionf from) @local
{
	Quaternionf delta = tilted.mul(from.invert()).normalize();
	if (delta.v.w < 0.0f) delta.v = -delta.v;
	float[<3>] axis = { delta.v.x, delta.v.y, delta.v.z };
	float sine = math::sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z);
	float angle = 2.0f * math::atan2(sine, delta.v.w);
	if (angle <= BODY_IK_MAX_LEAN || sine < 1.0e-9f) return tilted;
	Vec3 unit = { axis.x / sine, axis.y / sine, axis.z / sine };
	return quaternion::from_axis_angle{float}(unit, BODY_IK_MAX_LEAN).mul(from).normalize();
}

fn void BodyBalance.free(&self)
{
	if (self.mass.len > 0) alloc::free(mem, self.mass);
	if (self.below.len > 0) alloc::free(mem, self.below);
	if (self.moment.len > 0) alloc::free(mem, self.moment);
}

// Only the horizontal part: standing over the feet says nothing about height.
fn Vec3 BodyBalance.flat(&self, Vec3 v)
{
	Vec3 level = v - self.up * v.dot(self.up);
	return level - self.sideways * level.dot(self.sideways);
}

fn void BodyBalance.gather(&self, rig::Skeleton* skeleton, Matrix4f[] palette)
{
	usz n = skeleton.len();
	Vec3 sum = {};
	for (usz i = 0; i < n; i++)
	{
		self.below[i] = 0.0f;
		self.moment[i] = {};
	}
	// Children come after their parents, so walking back sums each subtree.
	for (usz i = n; i > 0; i--)
	{
		usz j = i - 1;
		Vec3 at = skeleton.joints[j].transform(palette[j]);
		sum = sum + at * self.mass[j];
		int parent = skeleton.parents[j];
		if (parent < 0) continue;
		self.below[(usz)parent] += self.below[j] + self.mass[j];
		self.moment[(usz)parent] = self.moment[(usz)parent] + self.moment[j] + at * self.mass[j];
	}
	self.centre = sum / self.total;
}

// How the centre of mass moves for a unit turn of `joint` about `axis` at `pivot`.
fn Vec3 BodyBalance.turned_by(&self, usz joint, Vec3 axis, Vec3 pivot)
{
	return axis.cross(self.moment[joint] - pivot * self.below[joint]) / self.total;
}

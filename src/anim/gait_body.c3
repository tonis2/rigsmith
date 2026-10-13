<*
 The rest of a walking body: what a two-legged gait does above its legs.

 A cycle that keys only the legs walks like a pair of legs carrying a statue.
 What reads as walking is the whole body answering the legs: the pelvis drops
 into each footfall and turns with the leg that swings forward, the chest turns
 against it, the arms swing opposite the legs, and the head rides all of it
 level. None of that is decoration — take it out and a viewer sees a broken
 walk before they can say why.

 Everything here is a function of the cycle's phase, read from the left foot's
 footfall, so the cycle still closes on itself. Amplitudes scale with the stride
 against the gait's default, so a long stride swings harder.

 **The legs are solved inside the turned pelvis.** Turning the pelvis carries the
 hips with it, so a foot target stays where it is in the world only if it is
 carried back into the pelvis's frame before the leg is solved — which is what
 `GaitBody.into_pelvis` does, and why the pelvis turn is computed here first.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

const usz GAIT_SPINE_MAX = 8;

// One side's arm: the joints from the collarbone out, -1 for one the rig lacks.
struct GaitArm
{
	float side;   // +1 left, -1 right
	sz clavicle;
	sz shoulder;
	sz elbow;
	sz wrist;
}

<*
 What a biped carries above its legs, found on the rig, and how far each part
 moves. `active` is false for anything that is not an upright figure on two
 legs with a head — a quadruped's back is a different question.
*>
struct GaitBody
{
	bool active;
	usz pelvis;                        // the joint both legs fork from
	Vec3 pivot;                        // where it rests
	Vec3 up;
	Vec3 forward;
	Vec3 left;
	usz[GAIT_SPINE_MAX] spine;         // pelvis (excluded) up to the chest, in order
	usz spine_count;
	sz neck;
	sz head;
	GaitArm[2] arms;
	usz arm_count;
	float left_strike;                 // the phase the left foot lands at
	// Radians, except bob (model units).
	float yaw;
	float roll;
	float chest;
	float swing;
	float elbow;
	float elbow_swing;
	float bob;
	float abduct;
}

// Default reach of each part, per gait, for a stride at the gait's own default.
// A walk turns the pelvis about four degrees each way and swings the arm about
// seventeen; a run bends the elbows near a right angle and swings them harder.
fn void gait_body_amounts(GaitBody* body, GaitKind kind, float scale, float height) @local
{
	bool runs = kind != WALK;
	body.yaw = (runs ? 0.10f : 0.07f) * scale;
	body.roll = runs ? 0.035f : 0.05f;
	body.chest = (runs ? 0.14f : 0.09f) * scale;
	body.swing = (runs ? 0.55f : 0.30f) * scale;
	body.elbow = runs ? 1.25f : 0.22f;
	body.elbow_swing = runs ? 0.25f : 0.35f;
	body.bob = (runs ? 0.02f : 0.012f) * height * scale;
	body.abduct = 0.14f;
}

<*
 Find the body above a biped's two legs.

 The pelvis is the joint both legs fork from; the spine is the run from it up to
 the neck (or the head); an arm is a joint named for a shoulder or an upper arm
 on each side, its elbow and wrist the limb's continuing children.

 @param legs : `The two legs' root joints (thighs).`
 @param left_strike : `Where in the cycle the left foot lands.`
*>
fn GaitBody gait_body_of(
	rig::Skeleton* skeleton,
	String[] names,
	usz[2] legs,
	float left_strike,
	GaitKind kind,
	float scale)
{
	GaitBody body;
	usz count = skeleton.len();
	if (names.len < count || legs[0] >= count || legs[1] >= count) return body;
	int pelvis = skeleton.parents[legs[0]];
	if (pelvis < 0 || pelvis != skeleton.parents[legs[1]]) return body;
	if (!rig_upright(skeleton, names)) return body;
	Vec3 forward;
	if (!rig_facing(skeleton, names, &forward)) return body;

	body.pelvis = (usz)pelvis;
	body.pivot = skeleton.joints[(usz)pelvis];
	body.up = { 0, 1, 0 };
	body.forward = forward;
	body.left = body.up.cross(forward).normalize();
	body.left_strike = left_strike;
	body.neck = -1;
	body.head = -1;

	foreach (usz j, name : names)
	{
		if (j >= count) break;
		if (body.head < 0 && name == "head") body.head = (sz)j;
	}
	if (body.head < 0) return body;

	// The spine: up from the head to the pelvis, then read the other way.
	usz[GAIT_SPINE_MAX + 2] path;
	usz steps = 0;
	sz walk = skeleton.parents[(usz)body.head];
	while (walk >= 0 && (usz)walk != body.pelvis && steps < path.len)
	{
		path[steps++] = (usz)walk;
		walk = skeleton.parents[(usz)walk];
	}
	if (walk < 0 || (usz)walk != body.pelvis || steps == 0) return body;
	for (usz i = 0; i < steps; i++)
	{
		usz j = path[steps - 1 - i];
		if (name_has(names[j], "neck")) { body.neck = (sz)j; break; }
		if (body.spine_count < GAIT_SPINE_MAX) body.spine[body.spine_count++] = j;
	}
	if (body.spine_count == 0) return body;

	foreach (usz j, name : names)
	{
		if (j >= count || body.arm_count >= 2) break;
		bool upper = name_has(name, "shoulder") || name_has(name, "upper_arm") || name_has(name, "upperarm");
		float side = side_sign(name);
		if (!upper || side == 0.0f) continue;
		GaitArm arm = { .side = side, .clavicle = -1, .shoulder = (sz)j, .elbow = -1, .wrist = -1 };
		arm.elbow = longest_child(skeleton, j);
		if (arm.elbow < 0) continue;
		arm.wrist = longest_child(skeleton, (usz)arm.elbow);
		if (arm.wrist < 0) continue;
		sz parent = skeleton.parents[j];
		bool on_spine = false;
		for (usz s = 0; s < body.spine_count; s++) if (parent >= 0 && (usz)parent == body.spine[s]) on_spine = true;
		if (parent >= 0 && !on_spine) arm.clavicle = parent;
		body.arms[body.arm_count++] = arm;
	}

	gait_body_amounts(&body, kind, scale, skeleton.height());
	body.active = true;
	return body;
}

// The cycle angle, zero where the left foot lands.
fn float GaitBody.angle(&self, float phase) => 2.0f * (float)math::PI * (phase - self.left_strike);

<*
 The pelvis at `phase`: its world turn, and how much further down than the
 gait's drop it sits — lowest as each foot lands, back up by mid-stance.
*>
fn Quaternionf GaitBody.pelvis_turn(&self, float phase, float* extra_drop)
{
	float a = self.angle(phase);
	*extra_drop = self.bob * 0.5f * (1.0f + math::cos(2.0f * a));
	// Positive about left × forward brings the left hip forward; positive about
	// forward lifts the left side. The left hip leads as the left foot lands, and
	// the left side rides high while the left leg carries the body.
	Quaternionf yaw = quaternion::from_axis_angle{float}(self.left.cross(self.forward).normalize(), self.yaw * math::cos(a));
	Quaternionf roll = quaternion::from_axis_angle{float}(self.forward, self.roll * math::sin(a));
	return yaw.mul(roll).normalize();
}

<*
 A foot target carried into the turned pelvis's frame: where it has to be among
 the rest-pose joints for the turned pelvis to put it at `target`.
*>
fn Vec3 GaitBody.into_pelvis(&self, Quaternionf turn, Vec3 target)
{
	return self.pivot + turn.invert().rotate_vec3(target - self.pivot);
}

<*
 How many dots `gait_body_dots` writes: one per spine joint, the neck and head,
 and per arm its collarbone, shoulder, elbow and wrist. The pelvis is keyed by
 the caller, with the root's drop when it is the root.
*>
fn usz GaitBody.dot_count(&self)
{
	if (!self.active) return 0;
	usz n = self.spine_count;
	if (self.neck >= 0) n++;
	if (self.head >= 0) n++;
	for (usz i = 0; i < self.arm_count; i++)
	{
		GaitArm arm = self.arms[i];
		n += 3;
		if (arm.clavicle >= 0) n++;
	}
	return n;
}

<*
 Key everything above the pelvis at `phase`, given the pelvis's world turn.

 Turns are built in the world and handed back parent-relative: the chest turned
 against the pelvis and shared out along the spine, the head held level and
 facing forward, the neck between. Each arm hangs from the turned chest, lowered
 from wherever it rests (a T-pose's arms come down to the sides) and swung
 forward with the opposite leg, its elbow bent a little more as it comes forward.

 @return `How many dots were written to the front of into.`
*>
fn usz gait_body_dots(
	Allocator allocator,
	GaitBody* body,
	rig::Skeleton* skeleton,
	String[] names,
	float phase,
	Quaternionf pelvis,
	AnimKeyDot[] into)
{
	if (!body.active) return 0;
	usz made = 0;
	float a = body.angle(phase);
	Vec3 turn_axis = body.left.cross(body.forward).normalize();

	// The chest turns against the pelvis, and stays all but level.
	Quaternionf chest = quaternion::from_axis_angle{float}(turn_axis, -body.chest * math::cos(a));
	Quaternionf parent_world = pelvis;
	for (usz s = 0; s < body.spine_count; s++)
	{
		float share = (float)(s + 1) / (float)body.spine_count;
		Quaternionf world = slerp_short(pelvis, chest, share);
		into[made++] = turn_dot(allocator, names[body.spine[s]], parent_world, world);
		parent_world = world;
	}
	Quaternionf chest_world = parent_world;
	// The head looks where the figure is going, whatever the chest is doing.
	Quaternionf head = quaternion::IDENTITY;
	if (body.neck >= 0)
	{
		Quaternionf neck = slerp_short(chest_world, head, 0.5f);
		into[made++] = turn_dot(allocator, names[(usz)body.neck], parent_world, neck);
		parent_world = neck;
	}
	if (body.head >= 0)
	{
		into[made++] = turn_dot(allocator, names[(usz)body.head], parent_world, head);
	}

	for (usz i = 0; i < body.arm_count; i++)
	{
		GaitArm arm = body.arms[i];
		Quaternionf above = chest_world;
		if (arm.clavicle >= 0)
		{
			// The collarbone rides the chest.
			into[made++] = turn_dot(allocator, names[(usz)arm.clavicle], chest_world, chest_world);
		}

		// Forward with the opposite leg: the left arm leads as the right foot lands.
		float swing = -arm.side * body.swing * math::cos(a);
		Vec3 out_side = body.left * arm.side;
		Vec3 hang = (-body.up * math::cos(body.abduct) + out_side * math::sin(body.abduct)).normalize();
		Vec3 toward = quaternion::from_axis_angle{float}(hang.cross(body.forward).normalize(), swing).rotate_vec3(hang);

		Vec3 upper_rest = skeleton.joints[(usz)arm.elbow] - skeleton.joints[(usz)arm.shoulder];
		Quaternionf shoulder = bone_carry(above.rotate_vec3(upper_rest), toward).mul(above).normalize();
		into[made++] = turn_dot(allocator, names[(usz)arm.shoulder], above, shoulder);

		// The elbow bends forward, more as the arm swings forward.
		float forwardness = body.swing > 0.0f ? math::max(swing / body.swing, 0.0f) : 0.0f;
		float bend = body.elbow + body.elbow_swing * forwardness;
		Vec3 fore = quaternion::from_axis_angle{float}(toward.cross(body.forward).normalize(), bend).rotate_vec3(toward);
		Vec3 lower_rest = skeleton.joints[(usz)arm.wrist] - skeleton.joints[(usz)arm.elbow];
		Quaternionf elbow = bone_carry(shoulder.rotate_vec3(lower_rest), fore).mul(shoulder).normalize();
		into[made++] = turn_dot(allocator, names[(usz)arm.elbow], shoulder, elbow);
		// The hand rides the forearm.
		into[made++] = turn_dot(allocator, names[(usz)arm.wrist], elbow, elbow);
	}
	return made;
}

// A rotation key for `joint` that takes it from its parent's world turn to `world`.
fn AnimKeyDot turn_dot(Allocator allocator, String joint, Quaternionf parent, Quaternionf world) @local
{
	AnimKeyDot dot = { .joint_name = joint.copy(allocator), .channels = AnimChannels.ROTATION };
	axis_angle_of(parent.invert().mul(world).normalize(), &dot.axis, &dot.angle);
	return dot;
}

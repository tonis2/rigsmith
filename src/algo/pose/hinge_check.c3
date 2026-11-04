<*
 Whether a rig's knees and elbows are allowed to fold the way bodies fold.

 A limit table that lets a knee bend only backward is not visible on the rig at
 rest, and it is not visible in a clip's keys either: the keys bend the knee the
 natural way and playback quietly clamps every one of them straight, or snaps
 the leg to the far end of the table. What reaches the screen is a figure
 walking stiff-legged with its knees flicking backward on a few frames, and
 nothing anywhere names the table as the cause. That is what an older limit
 transfer left on fitted rigs, and what `AppState.reapply_plan_limits` mends.

 So this reads the table the way the body would test it: turn the lower bone
 one radian toward its natural fold — a shin backward, a forearm forward — and
 see how far past the table that lands, then the same radian the other way.
 A hinge that refuses the natural fold and accepts the opposite one is
 inverted; one that refuses both is blocked. A toe is tested both ways, a
 little, since it bends up and down: refusing both, it is blocked.

 `mended_hinge` puts such a table right from its own rows, which is what both
 faults found so far have been: a transfer that read a knee's row the wrong way
 round, and a toe table written against a frame rolled a quarter turn.

 Which way is "backward" is read off the rig, not assumed: the feet point
 forward, and failing feet, the left side lies to the figure's left.
*>
module crig;

import rig;
import std::math;
import std::math::vector;
import std::math::quaternion;

enum HingeFault : int
{
	INVERTED, // folds only the wrong way
	BLOCKED,  // folds neither way
}

struct HingeIssue
{
	HingeFault kind;
	String joint;      // borrowed from the names handed in
	usz index;         // joint index
	float refused;     // radians of a one-radian natural fold the table removes
	float allowed_back; // radians of a one-radian unnatural fold the table removes
}

// How much of a one-radian fold a table may take away before the hinge is called
// unable to make it. A table that fits its joint takes none of it away.
const float HINGE_REFUSAL = 0.35f;
// The other way, a table that lets the same radian through but for this much is
// one that folds backward rather than one that is merely stiff.
const float HINGE_WRONG_WAY_FREEDOM = 0.3f;
// As many hinges as one rig is asked about. Spiders have more knees than this.
const usz HINGE_MOST = 16;

<*
 The knees and elbows whose limit tables refuse their natural fold.

 @param into : `Filled from the front; its length caps how many are reported.`
 @return `How many were written.`
*>
fn usz hinge_issues(
	RigDocument* doc,
	rig::Skeleton* skeleton,
	String[] names,
	uint[] dot_ids,
	HingeIssue[] into)
{
	usz joints = skeleton.len();
	if (joints == 0 || dot_ids.len < joints || names.len < joints || into.len == 0) return 0;

	Vec3 forward;
	if (!rig_facing(skeleton, names, &forward)) return 0;
	bool upright = rig_upright(skeleton, names);

	usz count = 0;
	for (usz j = 0; j < joints && count < into.len; j++)
	{
		HingeShape shape;
		if (!hinge_shape(skeleton, names, j, forward, upright, &shape)) continue;

		JointRotationLimits limits = doc.rotation_limits_of(dot_ids[j]);
		if (!limits.constrained) continue;
		JointLimitFrame frame = joint_limit_frame(skeleton, dot_ids, limits);
		if (!frame.usable()) continue;

		HingeIssue found;
		if (!hinge_fault(frame, limits, shape, &found)) continue;
		found.joint = names[j];
		found.index = j;
		into[count++] = found;
	}
	return count;
}

<*
 A table for the joint of `issue` that lets it fold the way it should, put
 together from the rows it already has: the row carrying the fold read the other
 way round (a transfer that turned the figure the wrong way), the two swing rows
 traded (a table written against a frame rolled a quarter turn from the one it
 is read in, as tables from before the frame rule changed were), or both.

 Whichever candidate refuses the natural fold least wins, and only if it lets the
 joint fold: a table that is simply too tight has nothing in it to recover.

 @return `False when no rearrangement of the joint's own rows mends it.`
*>
fn bool mended_hinge(
	RigDocument* doc,
	rig::Skeleton* skeleton,
	String[] names,
	uint[] dot_ids,
	HingeIssue issue,
	JointRotationLimits* out)
{
	usz j = issue.index;
	if (j >= skeleton.len() || j >= dot_ids.len) return false;
	Vec3 forward;
	if (!rig_facing(skeleton, names, &forward)) return false;
	HingeShape shape;
	if (!hinge_shape(skeleton, names, j, forward, rig_upright(skeleton, names), &shape)) return false;

	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[j]);
	JointLimitFrame frame = joint_limit_frame(skeleton, dot_ids, limits);
	if (!limits.constrained || !frame.usable()) return false;

	// The swing rows are X and Z; Y is the twist about the bone, which no fold uses.
	// Each rearrangement is tried in the frame the table is pinned to and in the
	// frame the bone itself derives, since a pinned frame can be rolled off the
	// rows it was meant for.
	JointRotationLimits[6] arranged;
	arranged[0] = limits;
	arranged[1] = limits;
	arranged[1].axes[0] = row_reversed(limits.axes[0]);
	arranged[2] = limits;
	arranged[2].axes[2] = row_reversed(limits.axes[2]);
	arranged[3] = limits;
	arranged[3].axes[0] = limits.axes[2];
	arranged[3].axes[2] = limits.axes[0];
	arranged[4] = arranged[3];
	arranged[4].axes[0] = row_reversed(arranged[3].axes[0]);
	arranged[5] = arranged[3];
	arranged[5].axes[2] = row_reversed(arranged[3].axes[2]);
	// A pinned frame carried back onto the bone it has drifted off, as a third reading.
	JointRotationLimits carried = carried_limit_frame(doc, skeleton, dot_ids, j);
	JointRotationLimits[18] candidates;
	for (usz i = 0; i < 6; i++)
	{
		candidates[i] = arranged[i];
		candidates[6 + i] = arranged[i];
		candidates[6 + i].has_saved_frame = false;
		candidates[12 + i] = arranged[i];
		candidates[12 + i].saved_frame = carried.saved_frame;
	}

	float best = shape_refusal(frame, limits, shape);
	bool found = false;
	foreach (candidate : candidates)
	{
		JointLimitFrame read = joint_limit_frame(skeleton, dot_ids, candidate);
		if (!read.usable()) continue;
		float score = shape_refusal(read, candidate, shape);
		HingeIssue still;
		if (score + 0.05f < best && !hinge_fault(read, candidate, shape, &still))
		{
			best = score;
			*out = candidate;
			found = true;
		}
	}
	return found;
}

<*
 Which way a joint folds, read off the rig: the axis a natural fold turns its
 bone about, how far a test fold goes, and whether it folds both ways.

 A knee sends its shin backward and an upright figure's elbow sends its forearm
 forward, one way only; its thigh swings its knee forward. A toe bends up and down about the line across the foot;
 a toe that can do neither is a toe nailed to the foot.
*>
struct HingeShape @local
{
	Vec3 axis;
	float test;
	bool both;
}

fn bool hinge_shape(rig::Skeleton* skeleton, String[] names, usz j, Vec3 forward, bool upright, HingeShape* out) @local
{
	String name = names[j];
	bool knee = name_has(name, "knee") || name_has(name, "shin") || name_has(name, "calf");
	// A quadruped's foreleg folds the other way round at the joint called the
	// elbow, so only an upright figure's elbows are held to a human's.
	bool elbow = upright && (name_has(name, "elbow") || name_has(name, "forearm"));
	bool toe = name_has(name, "toe") && !name_has(name, "tip");
	// A thigh is a ball, not a hinge, but every leg swings forward from the hip:
	// a table that will not let it is one read in the wrong frame.
	bool thigh = upright && (name_has(name, "thigh") || name_has(name, "upper_leg") || name_has(name, "upperleg"));
	if (!knee && !elbow && !toe && !thigh) return false;

	sz child = longest_child(skeleton, j);
	if (child < 0) return false;
	Vec3 bone = skeleton.joints[(usz)child] - skeleton.joints[j];
	if (bone.length() <= 1.0e-6f) return false;
	Vec3 along = bone.normalize();

	// The way the far end goes when the joint folds, square to the bone.
	Vec3 fold = toe ? (Vec3){ 0, -1, 0 } : (knee ? -forward : forward);
	// A toe bends a little either way; a thigh swings a radian forward for any
	// step up or run, short of folding to the chest.
	float test = toe ? 0.4f : 1.0f;
	fold = fold - along * along.dot(fold);
	if (fold.length() <= 0.2f) return false;
	*out = {
		.axis = along.cross(fold.normalize()).normalize(),
		.test = test,
		.both = toe,
	};
	return true;
}

// Whether `limits` refuse the fold `shape` describes, and how, into `out`.
fn bool hinge_fault(JointLimitFrame frame, JointRotationLimits limits, HingeShape shape, HingeIssue* out) @local
{
	float refused = fold_refused(frame, limits, shape.axis, shape.test);
	float back = fold_refused(frame, limits, shape.axis, -shape.test);
	if (shape.both)
	{
		// A toe bends up and down about the line across the foot. Read by its rows
		// rather than by a test turn: a table pinned to a frame that sits off the
		// bone turns any test bend partly into twist, which a toe locks. The swing
		// row lying along the bend's axis is the one that has to move; a table that
		// locks it and frees the other has its rows on the wrong axes.
		usz pitch = math::abs(shape.axis.dot(frame.axis(X))) >= math::abs(shape.axis.dot(frame.axis(Z))) ? 0 : 2;
		usz yaw = 2 - pitch;
		if (row_freedom(limits.axes[pitch]) >= TOE_FREEDOM || row_freedom(limits.axes[yaw]) < TOE_FREEDOM) return false;
		*out = { .kind = BLOCKED, .refused = math::min(refused, back), .allowed_back = back };
		return true;
	}
	if (refused <= HINGE_REFUSAL) return false;
	*out = {
		.kind = back <= HINGE_WRONG_WAY_FREEDOM ? INVERTED : BLOCKED,
		.refused = refused,
		.allowed_back = back,
	};
	return true;
}

// How much of the test folds the table takes away, the natural ones counted. A
// toe's is how little its bending row allows, read as `hinge_fault` reads it.
fn float shape_refusal(JointLimitFrame frame, JointRotationLimits limits, HingeShape shape) @local
{
	if (!shape.both) return fold_refused(frame, limits, shape.axis, shape.test);
	usz pitch = math::abs(shape.axis.dot(frame.axis(X))) >= math::abs(shape.axis.dot(frame.axis(Z))) ? 0 : 2;
	return math::max(TOE_FREEDOM - row_freedom(limits.axes[pitch]), 0.0f);
}

// The radians a row lets its axis travel: none for a locked one.
fn float row_freedom(JointAxisLimit row) @local => row.allowed ? row.maximum - row.minimum : 0.0f;

// How far a toe's bending row has to let it travel to be a toe that bends.
const float TOE_FREEDOM = 0.3f;

// A limit row read the other way round: what it allowed one way it now allows the other.
fn JointAxisLimit row_reversed(JointAxisLimit row) @local
{
	return { .allowed = row.allowed, .minimum = -row.maximum, .maximum = -row.minimum, .locked = -row.locked };
}

// How far a turn of `angle` about `axis` lands from where the table puts it.
fn float fold_refused(JointLimitFrame frame, JointRotationLimits limits, Vec3 axis, float angle) @local
{
	Quaternionf turn = quaternion::from_axis_angle{float}(axis, angle);
	Quaternionf held = constrain_joint_rotation(frame, limits, turn);
	float dot = math::abs(held.v.x * turn.v.x + held.v.y * turn.v.y + held.v.z * turn.v.z + held.v.w * turn.v.w);
	return 2.0f * math::acos(math::min(dot, 1.0f));
}

<*
 A limit table pinned to a frame that no longer runs along its bone.

 A saved frame is the bone-local axes a table was written against, kept so a
 later topology change cannot roll them. But its Y is the bone, and when the
 joint below is moved the bone turns and the saved frame does not: a knee's
 frame left forty degrees off the shin reads a clean bend as part bend, part
 twist and part sideways swing, the last two locked, and holds the bend back by
 up to a radian. Nothing on screen says the table is the cause.
*>
struct StaleFrame
{
	String joint;  // borrowed from the names handed in
	usz index;
	float drift;   // radians the saved frame's bone axis stands off the bone
}

// How far a saved frame's Y may stand off its bone before the table is read as
// written for a bone that has since moved: twenty degrees. A frame an author
// adjusted on purpose leans off its bone too, by a few degrees of roll and tilt;
// one a moved joint left behind is off by however far the joint went.
const float LIMIT_FRAME_DRIFT = 0.35f;
const usz STALE_FRAME_MOST = 64;

<*
 The joints whose saved limit frame has drifted off their bone.

 @return `How many were written to the front of into.`
*>
fn usz stale_limit_frames(
	RigDocument* doc,
	rig::Skeleton* skeleton,
	String[] names,
	uint[] dot_ids,
	StaleFrame[] into)
{
	usz joints = skeleton.len();
	if (dot_ids.len < joints || names.len < joints) return 0;
	usz count = 0;
	for (usz j = 0; j < joints && count < into.len; j++)
	{
		float drift = limit_frame_drift(doc, skeleton, dot_ids, j);
		if (drift <= LIMIT_FRAME_DRIFT) continue;
		into[count++] = { .joint = names[j], .index = j, .drift = drift };
	}
	return count;
}

// The angle between a joint's saved frame's bone axis and its bone, or 0 when it
// has no saved frame or no bone to measure against.
fn float limit_frame_drift(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz j) @local
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[j]);
	if (!limits.constrained || !limits.has_saved_frame) return 0.0f;
	JointLimitFrame saved = joint_limit_frame(skeleton, dot_ids, limits);
	JointRotationLimits loose = limits;
	loose.has_saved_frame = false;
	JointLimitFrame derived = joint_limit_frame(skeleton, dot_ids, loose);
	if (!saved.usable() || !derived.usable()) return 0.0f;
	float dot = math::clamp(saved.axis(Y).dot(derived.axis(Y)), -1.0f, 1.0f);
	return math::acos(dot);
}

<*
 Joint `j`'s table with its saved frame carried onto the bone as it now runs:
 turned by the smallest rotation that lays the frame's Y along the bone, so the
 rows keep the meaning they were written with — the roll about the bone stays
 as the author pinned it.
*>
fn JointRotationLimits carried_limit_frame(RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, usz j)
{
	JointRotationLimits limits = doc.rotation_limits_of(dot_ids[j]);
	JointLimitFrame saved = joint_limit_frame(skeleton, dot_ids, limits);
	JointRotationLimits loose = limits;
	loose.has_saved_frame = false;
	JointLimitFrame derived = joint_limit_frame(skeleton, dot_ids, loose);
	if (!saved.usable() || !derived.usable()) return limits;
	limits.saved_frame = bone_carry(saved.axis(Y), derived.axis(Y)).mul(saved.rotation).normalize();
	return limits;
}

<*
 The horizontal way the figure faces: where its toes point from its ankles,
 else square to the line from its right side to its left.
*>
fn bool rig_facing(rig::Skeleton* skeleton, String[] names, Vec3* out)
{
	Vec3 toes = { 0, 0, 0 };
	Vec3 left = { 0, 0, 0 };
	foreach (usz j, at : skeleton.joints)
	{
		if (j >= names.len) break;
		String name = names[j];
		sz parent = skeleton.parents[j];
		if (parent >= 0 && name_has(name, "toe") && !name_has(name, "tip")
			&& (name_has(names[(usz)parent], "ankle") || name_has(names[(usz)parent], "foot")))
		{
			Vec3 step = at - skeleton.joints[(usz)parent];
			toes += (Vec3){ step.x, 0, step.z };
		}
		float side = side_sign(name);
		left += (Vec3){ side * at.x, 0, side * at.z };
	}
	if (toes.length() > 1.0e-5f)
	{
		*out = toes.normalize();
		return true;
	}
	// Facing is the left side turned a quarter about up: +X left faces +Z.
	if (left.length() <= 1.0e-5f) return false;
	Vec3 l = left.normalize();
	*out = { -l.z, 0, l.x };
	return true;
}

// Whether the figure stands up — its head well above its hips — rather than
// going on all fours, which decides whose elbows these are.
fn bool rig_upright(rig::Skeleton* skeleton, String[] names)
{
	float height = skeleton.height();
	if (height <= 0.0f) return false;
	sz hips = -1;
	sz head = -1;
	foreach (usz j, name : names)
	{
		if (j >= skeleton.len()) break;
		if (hips < 0 && (name == "hips" || name == "pelvis")) hips = (sz)j;
		if (head < 0 && name == "head") head = (sz)j;
	}
	if (hips < 0 || head < 0) return false;
	return skeleton.joints[(usz)head].y - skeleton.joints[(usz)hips].y > 0.2f * height;
}

// +1 for a joint on the left, -1 on the right, 0 on the midline.
fn float side_sign(String name)
{
	if (name.ends_with("_L") || name.ends_with("_l") || name.ends_with(".L") || name.ends_with("Left")) return 1.0f;
	if (name.ends_with("_R") || name.ends_with("_r") || name.ends_with(".R") || name.ends_with("Right")) return -1.0f;
	return 0.0f;
}

fn bool name_has(String name, String part)
{
	if (name.len < part.len) return false;
	for (usz i = 0; i + part.len <= name.len; i++)
	{
		bool same = true;
		for (usz k = 0; k < part.len; k++)
		{
			char a = name[i + k];
			if (a >= 'A' && a <= 'Z') a += 32;
			if (a != part[k]) { same = false; break; }
		}
		if (same) return true;
	}
	return false;
}

// The child the limb continues through: the farthest one, which is the next bone
// of the chain rather than a twist helper sitting on the joint.
fn sz longest_child(rig::Skeleton* skeleton, usz joint)
{
	sz best = -1;
	float reach = 0.0f;
	foreach (usz c, parent : skeleton.parents)
	{
		if (parent != (int)joint) continue;
		float length = (skeleton.joints[c] - skeleton.joints[joint]).length();
		if (best < 0 || length > reach)
		{
			best = (sz)c;
			reach = length;
		}
	}
	return best;
}

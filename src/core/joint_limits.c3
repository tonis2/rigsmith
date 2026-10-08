<*
 Per-joint rotation-limit data and the bone-local frame that gives X/Y/Z a
 meaning.

 A pose is still stored as a quaternion. These three axes are an editing frame,
 not glTF's quaternion components and not a second pose representation. The
 frame is expressed in model space at rest; a posing caller carries it by the
 parent's world rotation before decomposing or constraining a local turn.

 The three angles are a swing and a twist, not Euler angles: X and Z are the swing
 across the bone (where the bone points) and Y is the twist about it. See
 `joint_angles_from_rotation`.

 Limits are sparse and dot-keyed in `RigDocument`. An absent entry means the
 joint is entirely free, whatever angle it is turned to. Once limits are active,
 each axis either moves inside its range or stays at its locked value. Keeping
 that distinction explicit avoids pretending that an active table is the same
 thing as unconstrained quaternion motion.
*>
module crig;

import rig;
import std::math;

enum JointRotationAxis
{
	X,
	Y,
	Z,
}

fn usz JointRotationAxis.component(self) => (usz)self;

fn String JointRotationAxis.label(self)
{
	switch (self)
	{
		case X: return "X";
		case Y: return "Y";
		case Z: return "Z";
	}
}

<*
 One row of the future Rotation limits table.

 `allowed` is deliberately not named `locked`: checked UI says what the joint
 may do. When it is false, `locked` is the one angle the axis keeps. All angles
 are radians internally; the inspector will present degrees.
*>
struct JointAxisLimit
{
	bool allowed;
	float minimum;
	float maximum;
	float locked;
}

fn bool JointAxisLimit.same(self, JointAxisLimit other) => self.allowed == other.allowed
	&& self.minimum == other.minimum && self.maximum == other.maximum
	&& self.locked == other.locked;

fn bool JointAxisLimit.valid(self) => math::is_finite(self.minimum)
	&& math::is_finite(self.maximum) && math::is_finite(self.locked)
	&& self.minimum <= self.maximum;

<*
 Everything authored for one joint's rotation constraints.

 `constrained` is separate from the axis values. Without it, all quaternion
 motion is free and a rotation is handed back as given, not rebuilt from its
 angles.

 A fork cannot infer which child defines the bone. `primary_child` records that
 choice by dot id. `saved_frame`, when present, is an explicit rest/model-space
 frame and wins over topology; it is what a later frame-edit gizmo will write.
*>
struct JointRotationLimits
{
	uint dot_id;
	JointAxisLimit[3] axes;
	bool constrained;
	uint primary_child;
	Quaternionf saved_frame;
	bool has_saved_frame;
}

<*
 The value returned for a joint with no stored settings.

 The axis rows are useful defaults for a panel, but `constrained` stays false:
 no decomposition or clamp is allowed to change a quaternion until the user
 actually enables limits.
*>
fn JointRotationLimits unconstrained_rotation(uint dot_id)
{
	JointRotationLimits out = {
		.dot_id = dot_id,
		.constrained = false,
		.saved_frame = quaternion::IDENTITY,
	};
	foreach (&axis : out.axes)
	{
		*axis = {
			.allowed = true,
			.minimum = -(float)math::PI,
			.maximum = (float)math::PI,
			.locked = 0.0f,
		};
	}
	return out;
}

fn bool JointRotationLimits.same(self, JointRotationLimits other)
{
	if (self.dot_id != other.dot_id || self.constrained != other.constrained
		|| self.primary_child != other.primary_child
		|| self.has_saved_frame != other.has_saved_frame) return false;
	if (self.has_saved_frame && self.saved_frame.v != other.saved_frame.v) return false;
	for (usz i = 0; i < 3; i++) if (!self.axes[i].same(other.axes[i])) return false;
	return true;
}

fn bool JointRotationLimits.valid(self)
{
	foreach (axis : self.axes) if (!axis.valid()) return false;
	if (!self.has_saved_frame) return true;

	float[<4>] q = self.saved_frame.v;
	if (!math::is_finite(q.x) || !math::is_finite(q.y)
		|| !math::is_finite(q.z) || !math::is_finite(q.w)) return false;
	return q.dot(q) > 1.0e-12f;
}

<*
 This joint's stored settings, or the explicitly unconstrained value.
*>
fn JointRotationLimits RigDocument.rotation_limits_of(&self, uint dot_id)
{
	foreach (limits : self.rotation_limits.array_view())
	{
		if (limits.dot_id == dot_id) return limits;
	}
	return unconstrained_rotation(dot_id);
}

<*
 Store or replace one joint's settings.

 A completely reset value is stored as absence. Edited axis values, a frame or
 a primary-child choice may remain while limits are inactive, so switching the
 table off and back on does not erase the numbers the user chose. Saved
 quaternions are normalized at the boundary so every reader receives an
 orthonormal basis.

 @return `True when the document changed. Invalid data and exact no-ops return false.`
*>
fn bool RigDocument.set_rotation_limits(&self, uint dot_id, JointRotationLimits limits)
{
	if (dot_id == 0 || !self.find(dot_id)) return false;
	limits.dot_id = dot_id;
	if (!limits.valid()) return false;
	if (limits.primary_child == dot_id) return false;
	if (limits.primary_child != 0 && !self.find(limits.primary_child)) return false;
	if (limits.has_saved_frame) limits.saved_frame = limits.saved_frame.normalize();

	JointRotationLimits reset = unconstrained_rotation(dot_id);
	bool default_axes = true;
	for (usz i = 0; i < 3; i++)
	{
		if (!limits.axes[i].same(reset.axes[i])) { default_axes = false; break; }
	}
	bool empty = !limits.constrained && default_axes
		&& limits.primary_child == 0 && !limits.has_saved_frame;
	foreach (sz i, held : self.rotation_limits.array_view())
	{
		if (held.dot_id != dot_id) continue;
		if (empty)
		{
			self.rotation_limits.remove_at(i);
			return true;
		}
		if (held.same(limits)) return false;
		*self.rotation_limits.get_ref(i) = limits;
		return true;
	}

	if (empty) return false;
	self.rotation_limits.push(limits);
	return true;
}

<*
 Why a bone-local frame could not be produced.

 `NEEDS_PRIMARY_CHILD` is a useful, fixable state rather than an arbitrary
 answer: averaging a shoulder's spine and arm children would make its axes move
 when an unrelated branch is edited.
*>
enum JointLimitFrameStatus
{
	READY,
	JOINT_NOT_FOUND,
	NEEDS_PRIMARY_CHILD,
	PRIMARY_CHILD_INVALID,
	ZERO_LENGTH,
	NO_DIRECTION,
	INVALID_SAVED_FRAME,
}

struct JointLimitFrame
{
	JointLimitFrameStatus status;
	Quaternionf rotation;
	uint direction_dot;
}

fn bool JointLimitFrame.usable(self) => self.status == READY;

<*
 A short user-facing reason for a frame that cannot currently be edited.
*>
fn String JointLimitFrameStatus.reason(self)
{
	switch (self)
	{
		case READY: return "";
		case JOINT_NOT_FOUND: return "the joint is no longer in this rig";
		case NEEDS_PRIMARY_CHILD: return "this joint branches; choose which child defines its bone-local axes";
		case PRIMARY_CHILD_INVALID: return "the saved primary child is not a child of this joint";
		case ZERO_LENGTH: return "the selected bone has zero length and cannot define stable axes";
		case NO_DIRECTION: return "this isolated joint has no bone direction to define local axes";
		case INVALID_SAVED_FRAME: return "the saved local-axis frame is invalid";
	}
}

fn Vec3 JointLimitFrame.axis(self, JointRotationAxis axis)
{
	switch (axis)
	{
		case X: return self.rotation.rotate_vec3({ 1, 0, 0 });
		case Y: return self.rotation.rotate_vec3({ 0, 1, 0 });
		case Z: return self.rotation.rotate_vec3({ 0, 0, 1 });
	}
}

<*
 Carry a rest/model-space limit frame into the pose without letting the selected
 joint rotate its own boundary away.

 `Pose.world_rotations` contains the composed pose turn at every joint. The
 selected joint's limit belongs immediately below its parent, so only that
 parent's composed turn carries the frame. A root has no parent and therefore
 keeps the rest frame. Gizmo drawing and locked R gestures use this same helper;
 numeric decomposition stays parent-relative and needs no carried copy.
*>
fn Quaternionf carried_joint_limit_frame(
	JointLimitFrame frame,
	rig::Skeleton* skeleton,
	Quaternionf[] world_rotations,
	usz joint)
{
	if (!frame.usable() || joint >= skeleton.len()) return quaternion::IDENTITY;
	int parent = skeleton.parents[joint];
	Quaternionf above = parent >= 0 && (usz)parent < world_rotations.len
		? world_rotations[(usz)parent]
		: (Quaternionf)quaternion::IDENTITY;
	return above.mul(frame.rotation).normalize();
}

// When M.w and M.y are both under this, the swing is a half turn and has no twist to
// read: the twist is taken as nothing and the swing as the whole rotation.
const float SWING_TWIST_EDGE = 1.0e-6f;

// Wrap an angle into [-pi, pi).
fn float wrap_angle(float angle) @private
{
	float turns = (float)math::floor(angle / (float)math::TAU + 0.5f);
	return angle - turns * (float)math::TAU;
}

// The distance round the circle between two angles, in [0, pi].
fn float angle_gap(float a, float b) @private => math::abs(wrap_angle(a - b));

// The turn whose rotation vector is (x, 0, z): about that direction, by that length.
fn Quaternionf swing_from_vector(float x, float z) @private
{
	float angle = (float)math::sqrt(x * x + z * z);
	if (angle < 1.0e-8f) return { x * 0.5f, 0.0f, z * 0.5f, 1.0f };
	float k = (float)math::sin(angle * 0.5f) / angle;
	return { x * k, 0.0f, z * k, (float)math::cos(angle * 0.5f) };
}

<*
 Where `angle` lands in a row's range, for a row that is allowed.

 An angle inside [minimum, maximum] stays as it is. One outside goes to whichever
 end is nearer round the circle, measured as the angular distance mod 2*pi, so a
 knee that can bend 0..150 degrees and is asked for -170 lands at 150, the short
 way round, and not at 0. A range that spans a whole turn takes everything.
*>
fn float clamp_on_circle(float angle, float minimum, float maximum) @private
{
	if (angle >= minimum && angle <= maximum) return angle;
	float span = maximum - minimum;
	if (span >= (float)math::TAU) return angle;
	// How far round from the minimum, in [0, 2*pi): inside the range if no more than span.
	float along = angle - minimum;
	along -= (float)math::TAU * (float)math::floor(along / (float)math::TAU);
	if (along <= span) return angle;
	return along - span <= (float)math::TAU - along ? maximum : minimum;
}

<*
 The angle this row holds `angle` to: its range, the nearer end round the circle
 for an angle past it, or `locked` when the axis is not allowed.
*>
fn float JointAxisLimit.clamp(self, float angle)
	=> self.allowed ? clamp_on_circle(angle, self.minimum, self.maximum) : self.locked;

<*
 How far `angle` is past this row, round the circle: what `clamp` would move it by.
*>
fn float JointAxisLimit.overshoot(self, float angle) => angle_gap(angle, self.clamp(angle));

<*
 A pose rotation expressed as three angles in this joint's bone-local frame: a
 swing across the bone and a twist about it.

 `rig::Pose` stores a joint rotation in its parent's coordinate system. The
 frame quaternion carries bone-local axes into that same rest/model space, so
 changing basis is the conjugation `M = F^-1 * R * F`. M is then split as
 `M = S * T`, the twist T applied first and the swing S after it:

   T   a turn about the frame's Y, the rest bone: the twist, y
   S   a turn about an axis across the bone, X-Z plane: the swing

 The fields are x and z, the swing's rotation vector (its axis times its angle)
 on the frame's X and Z, and y, the twist angle. So x and z say where the bone
 points, and y says how it is rolled about itself. With the twist applied first
 the swing alone decides where the bone points, whatever the twist.

 Why this and not three Euler angles. A Z-Y-X reading puts the twist in the middle
 angle, which flips past a quarter turn, has no answer at a quarter turn (the
 shoulder's own limit), forgets the wrap round the circle, and, once a thigh is
 flexed about 90 degrees, reads sideways swing on the twist row and twist on the
 sideways one. Here nothing flips at any angle: the one place the reading has no
 answer is a swing of a half turn, outside any real limit. A turn about one axis
 alone reads as that angle on that axis, as it always did.

 The twist is the (w, y) part of M, normalised: for M = S * T with S across the
 bone, M.w = S.w * T.w and M.y = S.w * T.y, so the swing's own scale drops out.
 M is taken with w >= 0, so the twist angle 2 * atan2(T.y, T.w) is in (-pi, pi].
 The swing is then M * T^-1, which has no Y part. When M.w and M.y are both about
 zero the swing is a half turn and the twist is taken as nothing.

 The frame is deliberately *not* carried by the parent's current pose here.
 Parent motion carries both the joint and these axes together, and therefore
 cancels out of a parent-relative numeric value. Gizmos draw the carried frame;
 the inspector edits this local one.
*>
fn Vec3 joint_angles_from_rotation(JointLimitFrame frame, Quaternionf rotation)
{
	if (!frame.usable()) return {};
	Quaternionf basis = frame.rotation.normalize();
	Quaternionf local = basis.invert().mul(rotation.normalize()).mul(basis).normalize();
	if (local.v.w < 0.0f) local = { -local.v.x, -local.v.y, -local.v.z, -local.v.w };

	Quaternionf twist = quaternion::IDENTITY;
	float reach = (float)math::sqrt(local.v.w * local.v.w + local.v.y * local.v.y);
	if (reach > SWING_TWIST_EDGE) twist = { 0.0f, local.v.y / reach, 0.0f, local.v.w / reach };
	Quaternionf swing = local.mul(twist.invert());

	float across = (float)math::sqrt(swing.v.x * swing.v.x + swing.v.z * swing.v.z);
	float scale = across < 1.0e-8f
		? 2.0f / math::max(swing.v.w, 1.0e-8f)
		: 2.0f * (float)math::atan2(across, swing.v.w) / across;

	float y = 2.0f * (float)math::atan2(twist.v.y, twist.v.w);
	if (y <= -(float)math::PI) y += (float)math::TAU;
	return { swing.v.x * scale, y, swing.v.z * scale };
}

<*
 Build the parent-relative quaternion represented by the inspector's bone-local
 X/Y/Z fields: the swing with rotation vector (x, 0, z) after the twist about Y
 by y, carried back out of the frame. It is the exact inverse of
 `joint_angles_from_rotation` for a swing under a half turn and a twist in
 (-pi, pi].
*>
fn Quaternionf rotation_from_joint_angles(JointLimitFrame frame, Vec3 angles)
{
	if (!frame.usable()) return quaternion::IDENTITY;
	Quaternionf basis = frame.rotation.normalize();
	Quaternionf twist = { 0.0f, (float)math::sin(angles.y * 0.5f), 0.0f, (float)math::cos(angles.y * 0.5f) };
	Quaternionf local = swing_from_vector(angles.x, angles.z).mul(twist);
	return basis.mul(local).mul(basis.invert()).normalize();
}

<*
 Apply one joint's simple axis table to a parent-relative pose rotation.

 This is the shared boundary for numeric posing and direct FK turns. An absent
 table is genuinely free and returns the quaternion unchanged; a disabled axis
 takes its explicit locked value, while an allowed one is clamped to its range.
 The rotation is read as swing and twist (`joint_angles_from_rotation`) and each
 row is clamped as one component of that reading, so the allowed region is a box
 in swing-twist space, and a corner pose stays allowed. An angle past its range
 goes to the nearer end round the circle, so nothing snaps the long way.
 Playback, IK and export call this same operation in the later enforcement
 slices rather than learning a second interpretation of the table.
*>
fn Quaternionf constrain_joint_rotation(
	JointLimitFrame frame,
	JointRotationLimits limits,
	Quaternionf rotation)
{
	if (!limits.constrained || !frame.usable()) return rotation.normalize();
	Vec3 angles = joint_angles_from_rotation(frame, rotation);
	foreach (usz i, axis : limits.axes) angles[i] = axis.clamp(angles[i]);
	return rotation_from_joint_angles(frame, angles);
}

<*
 Apply every active document limit to an evaluated pose, in place.

 This is the common stateless evaluator used after a clip has been sampled or
 blended. It changes only the temporary pose handed to it: the document's limit
 rows and the animation keys they constrain are both borrowed and untouched.
 Rotations in `rig::Pose` are parent-relative, which is also the space
 `constrain_joint_rotation` reads; a parent's permitted turn will carry its
 descendants later when the palette is composed, without being folded into
 their local rotations here.

 Rows whose bone-local frame cannot currently be derived are left unchanged.
 That is the same refusal direct FK and IK make, and avoids inventing axes for a
 branch whose primary child has not been chosen.

 Short arrays are tolerated and only their shared prefix is evaluated. Ordinary
 callers pass the three arrays from one `RigView`, where their lengths agree;
 prefix handling keeps a stale or partially-pruned diagnostic view safe.

 @param dot_ids : `The dot each skeleton joint was built from, in joint order.`
 @param pose : `A sampled pose. Offsets are deliberately preserved verbatim.`
*>
fn void constrain_pose_to_joint_limits(
	RigDocument* doc,
	rig::Skeleton* skeleton,
	uint[] dot_ids,
	rig::Pose* pose)
{
	usz count = skeleton.len();
	if (dot_ids.len < count) count = dot_ids.len;
	if (pose.rotations.len < count) count = pose.rotations.len;

	for (usz joint = 0; joint < count; joint++)
	{
		JointRotationLimits limits = doc.rotation_limits_of(dot_ids[joint]);
		if (!limits.constrained) continue;

		JointLimitFrame frame = joint_limit_frame(skeleton, dot_ids, limits);
		if (!frame.usable()) continue;
		pose.rotations[joint] = constrain_joint_rotation(frame, limits,
			pose.rotations[joint]);
	}
}

const float LIMIT_FRAME_EDGE_SQ = 1.0e-12f;

<*
 How far a bone may lean off the world axis it runs along and still count as
 running along it: about ten degrees, as the sine of the lean on each of the
 other two axes.
*>
const float LIMIT_FRAME_NEAR_AXIS = 0.17f;

<*
 The world axis a frame's X is projected from, before session 23.

 The cardinal the bone leans on least. Kept for `legacy_limit_frame`, which old
 sessions' tables were written against; on a bone that runs nearly along a world
 axis the two leftover leans are both slight, and which is slighter is a degree
 of placement — a finger whose knuckle sat a hair forward had its X sideways
 while the finger beside it had its X across the palm.
*>
fn Vec3 legacy_frame_seed(Vec3 y) @private
{
	Vec3 seed = { 1, 0, 0 };
	float least = math::abs(y.x);
	if (math::abs(y.y) < least) { seed = { 0, 1, 0 }; least = math::abs(y.y); }
	if (math::abs(y.z) < least) seed = { 0, 0, 1 };
	return seed;
}

<*
 The world axis a frame's X is projected from.

 A bone within `LIMIT_FRAME_NEAR_AXIS` of a world axis takes a fixed one, so the
 axes of a straight chain do not depend on which way it leans by a degree:
 along world X (an arm or finger held out) its X comes from world Z, so X bends
 it up and down; along Y or Z (a spine, a leg, a foot) from world X, so X bends
 it forward and back. Every segment of a limb lying along one axis shares its
 axes that way. Any other bone keeps the cardinal it leans on least.
*>
fn Vec3 frame_seed(Vec3 y) @private
{
	float ax = math::abs(y.x);
	float ay = math::abs(y.y);
	float az = math::abs(y.z);
	if (ay < LIMIT_FRAME_NEAR_AXIS && az < LIMIT_FRAME_NEAR_AXIS) return { 0, 0, 1 };
	if (ax < LIMIT_FRAME_NEAR_AXIS && (ay < LIMIT_FRAME_NEAR_AXIS || az < LIMIT_FRAME_NEAR_AXIS)) return { 1, 0, 0 };
	return legacy_frame_seed(y);
}

fn JointLimitFrame frame_from_seed(Vec3 y, Vec3 seed, uint direction_dot) @private
{
	Vec3 x = (seed - y * seed.dot(y)).normalize();
	Vec3 z = x.cross(y).normalize();
	return {
		.status = READY,
		.rotation = rig::quat_from_basis(x, y, z).normalize(),
		.direction_dot = direction_dot,
	};
}

<*
 A right-handed frame whose local +Y is the bone direction.

 +Y follows Blender's familiar bone-axis convention. This is an editor frame;
 the glTF writer's -Z bone-node convention is converted at export and must not
 leak into the labels a user edits. Roll is deterministic: project the world
 cardinal `frame_seed` picks onto the bone's perpendicular plane.
*>
fn JointLimitFrame frame_along(Vec3 direction, uint direction_dot = 0) @private
{
	float length_sq = direction.length_sq();
	if (!math::is_finite(length_sq) || length_sq <= LIMIT_FRAME_EDGE_SQ)
	{
		return { .status = ZERO_LENGTH, .rotation = quaternion::IDENTITY };
	}
	Vec3 y = direction * (1.0f / math::sqrt(length_sq));
	return frame_from_seed(y, frame_seed(y), direction_dot);
}

<*
 The frame a derived one was before session 23: the same bone, rolled the way
 `legacy_frame_seed` rolled it. What an older session's table was written
 against, so loading one can pin it where it was.
*>
fn JointLimitFrame legacy_limit_frame(JointLimitFrame derived)
{
	if (!derived.usable()) return derived;
	Vec3 y = derived.axis(Y);
	return frame_from_seed(y, legacy_frame_seed(y), derived.direction_dot);
}

<*
 Derive the same rest/model-space bone frame when the caller already speaks in
 skeleton joint indices.

 This is the reusable side of `joint_limit_frame`: editor data identifies a
 primary child by stable dot id, while a pack and its KHR writer identify it by
 the joint order stored in the file. Keeping the topology rule here means the
 viewport, template transfer and physical attachment frames cannot choose
 different axes for the same bone.

 `primary_child < 0` selects the automatic rule. `direction_ids` is optional;
 the editor supplies dot ids so `direction_dot` can drive its child picker,
 while file boundaries leave it empty because a glTF node has no dot id.
*>
fn JointLimitFrame joint_limit_frame_by_index(
	rig::Skeleton* skeleton,
	usz joint,
	int primary_child = -1,
	uint[] direction_ids = {})
{
	usz count = skeleton.len();
	if (joint >= count)
	{
		return { .status = JOINT_NOT_FOUND, .rotation = quaternion::IDENTITY };
	}

	usz children = 0;
	usz only_child = count;
	usz chosen = count;
	bool saw_selected_zero_child = false;
	for (usz i = 0; i < count; i++)
	{
		if (skeleton.parents[i] != (int)joint) continue;
		Vec3 edge = skeleton.joints[i] - skeleton.joints[joint];
		if (edge.length_sq() <= LIMIT_FRAME_EDGE_SQ)
		{
			if (primary_child < 0 || primary_child == (int)i)
			{
				saw_selected_zero_child = true;
			}
			continue;
		}
		children++;
		only_child = i;
		if (primary_child == (int)i) chosen = i;
	}

	usz direction = count;
	if (primary_child >= 0)
	{
		if (chosen >= count)
		{
			return { .status = saw_selected_zero_child ? ZERO_LENGTH : PRIMARY_CHILD_INVALID,
				.rotation = quaternion::IDENTITY };
		}
		direction = chosen;
	}
	else
	{
		if (children > 1)
		{
			return { .status = NEEDS_PRIMARY_CHILD, .rotation = quaternion::IDENTITY };
		}
		if (children == 1)
		{
			direction = only_child;
		}
		else
		{
			int parent = skeleton.parents[joint];
			if (parent >= 0 && (usz)parent < count)
			{
				direction = (usz)parent;
			}
			else
			{
				return {
					.status = saw_selected_zero_child ? ZERO_LENGTH : NO_DIRECTION,
					.rotation = quaternion::IDENTITY,
				};
			}
		}
	}

	uint direction_dot = direction < direction_ids.len ? direction_ids[direction] : 0;
	Vec3 edge = direction == (usz)skeleton.parents[joint]
		? skeleton.joints[joint] - skeleton.joints[direction]
		: skeleton.joints[direction] - skeleton.joints[joint];
	return frame_along(edge, direction_dot);
}

<*
 Derive one joint's rest/model-space bone-local frame.

 The skeleton and dot ids must come from the same `build_skeleton` call. Zero
 length children are ignored when a real child exists; if none can define the
 direction, a leaf falls back to parent -> joint. A true fork refuses to guess
 unless `primary_child` names one of its direct non-zero children.

 The returned frame is stable rest data. To display it over a pose or constrain
 a local rotation, carry it by the selected joint's *parent* world rotation. A
 gizmo that intentionally follows the current bone may additionally apply the
 joint turn, but doing that for the limit itself would let the boundary rotate
 away from the motion it is meant to stop.
*>
fn JointLimitFrame joint_limit_frame(
	rig::Skeleton* skeleton,
	uint[] dot_ids,
	JointRotationLimits limits)
{
	usz count = skeleton.len();
	if (dot_ids.len < count || limits.dot_id == 0)
	{
		return { .status = JOINT_NOT_FOUND, .rotation = quaternion::IDENTITY };
	}

	usz joint = count;
	foreach (usz i, id : dot_ids) if (i < count && id == limits.dot_id) { joint = i; break; }
	if (joint >= count)
	{
		return { .status = JOINT_NOT_FOUND, .rotation = quaternion::IDENTITY };
	}

	if (limits.has_saved_frame)
	{
		if (!limits.valid())
		{
			return { .status = INVALID_SAVED_FRAME, .rotation = quaternion::IDENTITY };
		}
		return { .status = READY, .rotation = limits.saved_frame.normalize() };
	}

	int primary = -1;
	if (limits.primary_child != 0)
	{
		// Use an out-of-range value when the dot no longer exists. The shared
		// topology helper then returns PRIMARY_CHILD_INVALID rather than treating
		// it as automatic selection.
		primary = (int)count;
		foreach (usz i, id : dot_ids)
		{
			if (i >= count) break;
			if (id == limits.primary_child) { primary = (int)i; break; }
		}
	}
	return joint_limit_frame_by_index(skeleton, joint, primary, dot_ids);
}

// ---------------------------------------------------------------------------
// The other side of the symmetry plane

<*
 How nearly a twin's derived axes have to be the source's reflected before a
 limit table is read across them as they are, rather than pinned to a frame
 reflected outright. Five degrees: a pair the mirror just squared up is exact,
 and a parent sitting a hair off the plane skews the bones below it by less.
*>
const float MIRROR_FRAME_ALIGNMENT = 0.996f;

<*
 A rotation's reflection in the symmetry plane.

 The rule `AnimKeyDot.reflected` states for a keyed turn, in quaternion form: a
 turn about an axis is a turn the other way about the reflected axis, and an
 axis is a pseudo-vector, so the component along the plane's normal stays and
 the two in the plane flip. Only the normal matters — X, as it is everywhere in
 crig — so there is no plane position to pass.
*>
fn Quaternionf reflected_rotation(Quaternionf q) => { .v = { q.v.x, -q.v.y, -q.v.z, q.v.w } };

<*
 A bone-local frame's reflection, kept right-handed.

 Reflect the three axes and the frame is left-handed, so one of them has to be
 turned about, and `signs` says which: +1 for an axis that is the reflection of
 the source's, -1 for its opposite. Y is the bone and always reflects; of X and
 Z exactly one is turned about. `natural_reflection_signs` is the choice made
 when nothing on the other side decides it, `reflection_signs_between` reads
 the choice a frame that already exists there made.

 @require signs.y > 0 && signs.x * signs.z < 0 : `Y is the bone, and of X and Z one turns about.`
*>
fn Quaternionf reflected_limit_frame(Quaternionf frame, Vec3 signs)
{
	Vec3 x = frame.rotate_vec3({ 1, 0, 0 });
	Vec3 y = frame.rotate_vec3({ 0, 1, 0 });
	Vec3 z = frame.rotate_vec3({ 0, 0, 1 });
	return rig::quat_from_basis(
		{ -x.x * signs.x, x.y * signs.x, x.z * signs.x },
		{ -y.x, y.y, y.z },
		{ -z.x * signs.z, z.y * signs.z, z.z * signs.z }).normalize();
}

<*
 The signs a frame's reflection takes when nothing on the other side says
 otherwise: of X and Z, the one nearer the plane's normal keeps pointing the
 way it does — reflected, it would turn about — and the other reflects.

 This is the choice the automatic frame rule makes on a mirrored bone, so a
 frame that agrees with the automatic one on this side reflects to the
 automatic one on the other, and a table pinned to the reflection reads the
 same as one the twin's own bone would have carried.
*>
fn Vec3 natural_reflection_signs(Quaternionf frame)
{
	Vec3 x = frame.rotate_vec3({ 1, 0, 0 });
	Vec3 z = frame.rotate_vec3({ 0, 0, 1 });
	return math::abs(x.x) >= math::abs(z.x) ? (Vec3){ -1, 1, 1 } : (Vec3){ 1, 1, -1 };
}

<*
 The signs `reflected_limit_frame` would need to turn `source` into `twin`.

 +1 per axis of the twin's that is the reflection of the source's, -1 for its
 opposite. False when the twin's frame is not the source's reflected up to
 that — a twin whose bone runs another way — in which case nothing a per-axis
 table says about one carries to the other.
*>
fn bool reflection_signs_between(Quaternionf source, Quaternionf twin, Vec3* signs)
{
	Vec3[3] axes = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
	foreach (usz i, axis : axes)
	{
		Vec3 from = source.rotate_vec3(axis);
		Vec3 to = twin.rotate_vec3(axis);
		float along = to.dot({ -from.x, from.y, from.z });
		if (math::abs(along) < MIRROR_FRAME_ALIGNMENT) return false;
		(*signs)[i] = along < 0.0f ? -1.0f : 1.0f;
	}
	return true;
}

<*
 The table a joint's twin across the symmetry plane needs to move the way the
 joint does in a mirror.

 	`JointRotationLimits mirrored;`
 	`if (mirrored_rotation_limits(&skeleton, dot_ids, held, twin, twin_primary, &mirrored)) ...`

 A limit is a box in the joint's own axes, and a reflection is not the identity
 on those axes: a knee flexes about the same X on both legs, but a hip's twist
 and its abduction reverse. So the table is not copied but read against the
 twin's bone-local frame, and it stays a box only because that frame is the
 source's reflected with each axis possibly turned about — which is exactly
 what the automatic rule gives mirrored bones. A turn about the source's axis
 by θ is a turn about the twin's by -sθ, s the sign of that axis, and each
 range follows.

 The twin's axes are its own where its bone can carry them: the source's
 primary child crosses as `twin_primary`, and a saved frame crosses as the
 same adjustment off the twin's derived frame — what a pack does with one.
 Where the twin's derived frame is missing or is no reflection of the source's
 — a twin that branches where its source does not, or is wired to other bones
 — the source's frame is reflected outright and saved on the twin, so the
 numbers mean the same there even though its own bone does not define them.

 @param twin_primary : `The twin of the source's primary child, or 0 when it names none.`
 @return `False when the source's own frame cannot be derived: a table with no axes has no reflection.`
*>
fn bool mirrored_rotation_limits(
	rig::Skeleton* skeleton,
	uint[] dot_ids,
	JointRotationLimits source,
	uint twin,
	uint twin_primary,
	JointRotationLimits* out)
{
	JointLimitFrame frame = joint_limit_frame(skeleton, dot_ids, source);
	if (!frame.usable()) return false;

	JointRotationLimits mirrored = source;
	mirrored.dot_id = twin;
	mirrored.primary_child = twin_primary;
	mirrored.has_saved_frame = false;
	mirrored.saved_frame = quaternion::IDENTITY;

	// What the two bones say on their own, which is what a table is written
	// against when neither side is pinned.
	JointRotationLimits base = source;
	base.has_saved_frame = false;
	base.saved_frame = quaternion::IDENTITY;
	JointLimitFrame derived = joint_limit_frame(skeleton, dot_ids, base);
	JointLimitFrame twin_derived = joint_limit_frame(skeleton, dot_ids, mirrored);

	Vec3 signs;
	bool own = derived.usable() && twin_derived.usable()
		&& reflection_signs_between(derived.rotation, twin_derived.rotation, &signs);
	if (!own) signs = natural_reflection_signs(frame.rotation);
	if (!own || source.has_saved_frame)
	{
		mirrored.has_saved_frame = true;
		mirrored.saved_frame = reflected_limit_frame(frame.rotation, signs);
	}

	foreach (usz i, &axis : mirrored.axes)
	{
		if (signs[i] < 0.0f) continue;
		*axis = {
			.allowed = axis.allowed,
			.minimum = -axis.maximum,
			.maximum = -axis.minimum,
			.locked = -axis.locked,
		};
	}
	*out = mirrored;
	return true;
}

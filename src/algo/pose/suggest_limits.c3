<*
 Joint limits read off a rig with no body plan: hinge or cone from the rest
 bend, ranges from where each limb sits in its chain, then narrowed by the mesh
 and shared across matching limbs (`AppState.suggest_limits` does the mesh and
 the clips).
*>
module crig;

import rig;
import std::math;
import std::math::quaternion;
import std::sort;

enum LimitShape
{
	SKIP,
	HINGE,
	CONE,
	TIP,
}

const float SUGGEST_DEGREE = (float)math::PI / 180.0f;
// A bend below this at rest reads as straight: a cone, not a hinge.
const float SUGGEST_HINGE_BEND = 8.0f * SUGGEST_DEGREE;
const float SUGGEST_HINGE_FOLD = 120.0f * SUGGEST_DEGREE;
const float SUGGEST_HINGE_OPEN_PAST = 10.0f * SUGGEST_DEGREE;
const float SUGGEST_HINGE_SIDE = 10.0f * SUGGEST_DEGREE;
const float SUGGEST_HINGE_TWIST = 15.0f * SUGGEST_DEGREE;
const float SUGGEST_BASE_SWING = 60.0f * SUGGEST_DEGREE;
const float SUGGEST_BASE_TWIST = 45.0f * SUGGEST_DEGREE;
const float SUGGEST_MID_SWING = 30.0f * SUGGEST_DEGREE;
const float SUGGEST_TWIST = 30.0f * SUGGEST_DEGREE;
const float SUGGEST_TIP_SWING = 20.0f * SUGGEST_DEGREE;
// How far past a clip's extreme a widened row reaches.
const float SUGGEST_CLIP_MARGIN = 0.1f;

// The four ways a joint is swept and its reach kept: +X, -X, +Z, -Z.
enum SwingWay
{
	X_UP,
	X_DOWN,
	Z_UP,
	Z_DOWN,
}

fn Vec3 SwingWay.angles(self, float angle)
{
	switch (self)
	{
		case X_UP: return { angle, 0, 0 };
		case X_DOWN: return { -angle, 0, 0 };
		case Z_UP: return { 0, 0, angle };
		case Z_DOWN: return { 0, 0, -angle };
	}
}

struct SuggestedJoint
{
	LimitShape shape;
	// Hangs from a fork or the root: where a limb meets the body.
	bool base;
	// The rest angle between the bone in and the bone out; hinges only.
	float bend;
	// Model space at rest; turning positively about it closes the bend.
	Vec3 fold_axis;
	usz child;
	// Same place in the same kind of limb: index along it, its length, children, shape.
	ulong group;
	// How far it may turn each `SwingWay`.
	float[4] reach;
	// Which ways the mesh stopped it.
	bool[4] met;
}

<*
 The children of `joint` with a bone of their own, and the last of them.
*>
fn usz bone_children(rig::Skeleton* skeleton, usz joint, usz* last = null)
{
	usz count = 0;
	foreach (usz i, int parent : skeleton.parents)
	{
		if (parent != (int)joint) continue;
		if ((skeleton.joints[i] - skeleton.joints[joint]).length_sq() <= LIMIT_FRAME_EDGE_SQ) continue;
		count++;
		if (last) *last = i;
	}
	return count;
}

// Where a limb starts: the joint hangs from the root or a fork.
fn bool starts_limb(rig::Skeleton* skeleton, usz joint) @local
{
	int parent = skeleton.parents[joint];
	if (parent < 0) return false;
	return skeleton.parents[(usz)parent] < 0 || bone_children(skeleton, (usz)parent) > 1;
}

<*
 Read each joint's shape, default reach and group off the rest pose.

 @param [&in] skeleton : "The rig at rest"
 @param [out] out : "One per joint"
 @require out.len == skeleton.len() : "One entry per joint"
*>
fn void read_limit_shapes(rig::Skeleton* skeleton, SuggestedJoint[] out)
{
	usz count = skeleton.len();
	for (usz j = 0; j < count; j++)
	{
		SuggestedJoint* s = &out[j];
		*s = {};
		int parent = skeleton.parents[j];
		if (parent < 0) continue;
		usz child;
		usz kids = bone_children(skeleton, j, &child);
		s.base = starts_limb(skeleton, j);
		s.child = child;

		Vec3 into = skeleton.joints[j] - skeleton.joints[(usz)parent];
		if (kids == 0)
		{
			s.shape = TIP;
		}
		else if (kids > 1 || s.base || into.length_sq() <= LIMIT_FRAME_EDGE_SQ)
		{
			s.shape = CONE;
		}
		else
		{
			Vec3 out_bone = (skeleton.joints[child] - skeleton.joints[j]).normalize();
			Vec3 in_bone = into.normalize();
			Vec3 across = in_bone.cross(out_bone);
			s.bend = (float)math::atan2(across.length(), in_bone.dot(out_bone));
			s.shape = s.bend > SUGGEST_HINGE_BEND ? HINGE : CONE;
			if (s.shape == HINGE) s.fold_axis = across.normalize();
		}

		switch (s.shape)
		{
			case HINGE:
				s.reach = { SUGGEST_HINGE_FOLD, s.bend + SUGGEST_HINGE_OPEN_PAST, SUGGEST_HINGE_SIDE, SUGGEST_HINGE_SIDE };
			case CONE:
				float swing = s.base ? SUGGEST_BASE_SWING : SUGGEST_MID_SWING;
				s.reach = { swing, swing, swing, swing };
			case TIP:
				s.reach = { SUGGEST_TIP_SWING, SUGGEST_TIP_SWING, SUGGEST_TIP_SWING, SUGGEST_TIP_SWING };
			case SKIP:
				break;
		}
		s.group = limb_group(skeleton, j, kids, s.shape);
	}
}

// Index along the limb, the limb's length, children and shape, packed.
fn ulong limb_group(rig::Skeleton* skeleton, usz joint, usz kids, LimitShape shape) @local
{
	usz count = skeleton.len();
	usz start = joint;
	usz index = 0;
	while (!starts_limb(skeleton, start) && index < count)
	{
		start = (usz)skeleton.parents[start];
		index++;
	}
	usz length = 1;
	usz at = start;
	usz next;
	while (bone_children(skeleton, at, &next) == 1 && length < count)
	{
		at = next;
		length++;
	}
	return (ulong)shape.ordinal | (ulong)math::min(kids, (usz)255) << 8
		| (ulong)math::min(index, (usz)0xFFFF) << 16 | (ulong)math::min(length, (usz)0xFFFF) << 32;
}

<*
 The frame a suggestion is read in: a hinge's rolled so X is its fold axis, any
 other the bone's own.
*>
fn JointLimitFrame suggested_frame(rig::Skeleton* skeleton, uint[] dot_ids, usz joint, SuggestedJoint s)
{
	JointRotationLimits table = suggested_table(skeleton, dot_ids, joint, s);
	return joint_limit_frame(skeleton, dot_ids, table);
}

<*
 The table a suggestion writes.

 @require joint < skeleton.len() && joint < dot_ids.len : "Joint out of range"
*>
fn JointRotationLimits suggested_table(rig::Skeleton* skeleton, uint[] dot_ids, usz joint, SuggestedJoint s)
{
	JointRotationLimits table = unconstrained_rotation(dot_ids[joint]);
	if (s.shape == SKIP) return table;
	table.constrained = true;
	table.axes[0] = { .allowed = true, .minimum = -s.reach[1], .maximum = s.reach[0] };
	table.axes[2] = { .allowed = true, .minimum = -s.reach[3], .maximum = s.reach[2] };
	float twist;
	switch (s.shape)
	{
		case HINGE: twist = SUGGEST_HINGE_TWIST;
		case CONE: twist = s.base ? SUGGEST_BASE_TWIST : SUGGEST_TWIST;
		case TIP: twist = SUGGEST_TWIST;
		case SKIP: twist = 0.0f;
	}
	table.axes[1] = { .allowed = true, .minimum = -twist, .maximum = twist };
	if (s.shape == HINGE)
	{
		Vec3 y = (skeleton.joints[s.child] - skeleton.joints[joint]).normalize();
		Vec3 x = (s.fold_axis - y * s.fold_axis.dot(y)).normalize();
		Vec3 z = x.cross(y).normalize();
		table.saved_frame = rig::quat_from_basis(x, y, z).normalize();
		table.has_saved_frame = true;
	}
	return table;
}

<*
 Give every joint of a group the median reach of the group, so matching limbs
 match.

 A cone takes each axis symmetric first, since its frame need not be mirrored
 between a left limb and its right twin.
*>
fn void share_in_groups(SuggestedJoint[] joints)
{
	foreach (&s : joints)
	{
		if (s.shape != CONE && s.shape != TIP) continue;
		float x = (s.reach[0] + s.reach[1]) * 0.5f;
		float z = (s.reach[2] + s.reach[3]) * 0.5f;
		s.reach = { x, x, z, z };
	}
	usz count = joints.len;
	bool[] done = mem::new_array(bool, (sz)count);
	defer mem::free(done);
	float[] values = mem::new_array(float, (sz)count);
	defer mem::free(values);
	usz[] members = mem::new_array(usz, (sz)count);
	defer mem::free(members);
	for (usz j = 0; j < count; j++)
	{
		if (done[j] || joints[j].shape == SKIP) continue;
		usz n = 0;
		for (usz k = j; k < count; k++)
		{
			if (joints[k].shape == SKIP || joints[k].group != joints[j].group) continue;
			done[k] = true;
			members[n++] = k;
		}
		if (n < 2) continue;
		for (usz way = 0; way < 4; way++)
		{
			for (usz i = 0; i < n; i++) values[i] = joints[members[i]].reach[way];
			sort::quicksort(values[:n]);
			float median = n % 2 == 1 ? values[n / 2] : (values[n / 2 - 1] + values[n / 2]) * 0.5f;
			bool met = false;
			for (usz i = 0; i < n; i++) met = met || joints[members[i]].met[way];
			for (usz i = 0; i < n; i++)
			{
				joints[members[i]].reach[way] = median;
				joints[members[i]].met[way] = met;
			}
		}
	}
}

<*
 Widen a table's rows to the angles a clip reaches, plus a margin.

 @return "Whether any row grew"
*>
fn bool widen_to_clip(JointRotationLimits* table, Vec3 low, Vec3 high)
{
	bool grew = false;
	for (usz i = 0; i < 3; i++)
	{
		JointAxisLimit* row = &table.axes[i];
		if (high[i] > row.maximum)
		{
			row.maximum = math::min(high[i] * (1.0f + SUGGEST_CLIP_MARGIN), (float)math::PI);
			grew = true;
		}
		if (low[i] < row.minimum)
		{
			row.minimum = math::max(low[i] * (1.0f + SUGGEST_CLIP_MARGIN), -(float)math::PI);
			grew = true;
		}
	}
	return grew;
}

<* The pure half of src/app/plans.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

// Whether `dot` is one an `only` mask lets through: every dot when it is empty.
fn bool dot_in(uint[] only, uint dot)
{
	if (only.len == 0) return true;
	foreach (id : only) if (id == dot) return true;
	return false;
}

<*
 The plan's dots as a skeleton, in the space the pack measured them in.
*>
fn rig::Skeleton preset_skeleton(Allocator allocator, Preset preset)
{
	rig::Skeleton out = {
		.joints = alloc::new_array(allocator, Vec3, (sz)preset.dots.len),
		.parents = alloc::new_array(allocator, int, (sz)preset.dots.len),
	};
	bool measured = preset.extent.length_sq() > 0.0f;
	foreach (usz i, dot : preset.dots)
	{
		out.joints[i] = measured ? dot.at * preset.extent : dot.at;
		out.parents[i] = dot.parent;
	}
	return out;
}

fn JointAxisLimit turned_about(JointAxisLimit row) => {
	.allowed = row.allowed,
	.minimum = -row.maximum,
	.maximum = -row.minimum,
	.locked = -row.locked,
};

fn uint fitted_dot_id(String name, FittedDot[] fitted, uint[] ids)
{
	if (name.len == 0) return 0;
	foreach (usz i, dot : fitted)
	{
		if (dot.name == name) return ids[i];
	}
	return 0;
}

// The unique fitted dot carrying `name`. Constraint transfer must not choose a
// first match when a malformed plan repeats a name: that would be an arbitrary
// anatomical edit. Physics predates this stricter boundary and keeps its own
// first-match helper above for compatibility.
fn uint unique_fitted_dot_id(String name, FittedDot[] fitted, uint[] ids)
{
	if (name.len == 0) return 0;
	uint found = 0;
	foreach (usz i, dot : fitted)
	{
		if (dot.name != name) continue;
		if (found != 0 || i >= ids.len) return 0;
		found = ids[i];
	}
	return found;
}

<*
 How far a dot may sit from its plan target before the offset is worth drawing,
 as a fraction of the mesh's diagonal.

 Below this the ring would overlap the dot it points at and the line joining
 them would have no direction to show: framed, the diagonal spans most of the
 viewport, so a hundredth of it is about the radius a dot is drawn at. A dot the
 fit already placed correctly must not grow decoration.
*>
const float PLAN_OFFSET_MIN = 0.01;

fn JointAxisLimit carried_axis(Vec3 axis, Vec3 xs, Vec3 zs, JointAxisLimit x_row, JointAxisLimit z_row) @local
{
	float along_x = axis.dot(xs);
	float along_z = axis.dot(zs);
	bool from_x = math::abs(along_x) >= math::abs(along_z);
	JointAxisLimit row = from_x ? x_row : z_row;
	// An axis that points the other way turns the row about.
	return (from_x ? along_x : along_z) < 0.0f ? turned_about(row) : row;
}

<*
 A source row read against the target's derived frame.

 Each target swing axis takes the row of the source axis it lies along, with
 the sign of that alignment. A reversed fit is the source turned half way round
 about Y, so the source axes are turned with it before they are compared — a
 turn carries a rotation as it is, where a reflection would turn every row about.
 The twist axis is the bone on both sides.
*>
fn JointAxisLimit[3] carried_axes(JointAxisLimit[3] axes, Quaternionf from, Quaternionf to, bool reversed)
{
	Vec3 xs = from.rotate_vec3({ 1, 0, 0 });
	Vec3 zs = from.rotate_vec3({ 0, 0, 1 });
	if (reversed)
	{
		xs = { -xs.x, xs.y, -xs.z };
		zs = { -zs.x, zs.y, -zs.z };
	}
	JointAxisLimit[3] out;
	out[0] = carried_axis(to.rotate_vec3({ 1, 0, 0 }), xs, zs, axes[0], axes[2]);
	out[1] = axes[1];
	out[2] = carried_axis(to.rotate_vec3({ 0, 0, 1 }), xs, zs, axes[0], axes[2]);
	return out;
}

<*
 Which way the rig faces at rest, along the floor: where its toes point from
 their ankles, or its left side turned a quarter (see `rig_facing`). What the
 viewport's facing arrow draws and what a re-fit the other way round turns from.

 @return `False for a rig with nothing named to read it from.`
*>
fn bool rest_facing(RigDocument* doc, Vec3* out)
{
	if (doc.dots.len() < 2) return false;
	@pool()
	{
		uint[] dot_ids;
		rig::Skeleton? built = build_skeleton(doc, tmem, &dot_ids);
		if (catch built) return false;
		rig::Skeleton skeleton = built;
		return rig_facing(&skeleton, joint_names(doc, tmem, dot_ids), out);
	};
}

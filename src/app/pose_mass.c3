<*
 How heavy each body part is to a pose drag, read off the mesh.

 	`float[] mass = ...; bool ok = app.body_part_masses(&view, mass);`

 A joint's body part is the stretch of the rest mesh it carries most of: every
 vertex whose largest skin weight is that joint's. The part's bounding box is
 its size, and its size is its weight, so a fingertip weighs next to nothing, a
 hand more, a thigh a lot and the pelvis most — and `point_pose` lets the light
 parts answer a pull before the heavy ones are asked. A finger pulled then bends
 at its knuckles instead of dragging the hand, the arm and the chest along.

 Read off the skin rather than the rig's shape, which is what
 `point_pose_masses` falls back to without one: a rig's shape says a hand and a
 fingertip are both "limb", and only the mesh knows one is ten times the other.
 Each joint's own `Dot.pose_weight` then scales what the mesh says.

 The volumes are cached per skin (`skin_generation`), since binding is what can
 change them; the pose weights are applied fresh on every call.
*>
module crig;

import rig;
import std::math;

// The heaviest body part's mass, the lightest's being 1. The solve's inertia is
// the mass less one (`PointSolve.inertia`), so the band is what separates a part
// that goes where it is pulled from one that barely stirs: a fingertip next to
// a pelvis is about a thousandth of its volume, and lands near 1.
const float PART_MASS_MAX = 16.0;

// The least a part's box is taken to hold, as a share of its bone's length
// cubed: a joint the skin hardly reaches — a fingertip's last joint, a twist bone
// sharing its limb — still weighs what a sliver of its bone would.
const float PART_MASS_FLOOR = 0.05;

<*
 Each joint's mass to the pose solver, one per skeleton joint of `view`.

 @param mass : `One per joint of the view; filled when the answer is true.`
 @return `False when there is no skin for the rig as it stands — no mesh, a skin bound to another build, a stale one — and the caller should fall back to the rig's shape.`
*>
fn bool AppState.body_part_masses(&self, RigView* view, float[] mass)
{
	usz n = view.len();
	if (n == 0 || mass.len < n) return false;
	if (!self.part_volumes_current(view)) return false;

	float largest = 0.0f;
	foreach (v : self.part_volume[:n]) largest = math::max(largest, v);
	if (largest <= 0.0f) return false;
	for (usz j = 0; j < n; j++)
	{
		int parent = view.skeleton.parents[j];
		float share = (parent >= 0 ? self.part_volume[(usz)parent] : self.part_volume[j]) / largest;
		float own = 1.0f + share * (PART_MASS_MAX - 1.0f);
		if (Dot* dot = self.doc.find(view.dot_ids[j])) own *= dot.pose_weight_factor();
		mass[j] = own;
	}
	return true;
}

<*
 Whether `part_volume` holds this rig's parts, rebuilding it when the skin has
 moved on since it was measured.
*>
fn bool AppState.part_volumes_current(&self, RigView* view)
{
	usz n = view.len();
	usz vertices = self.geometry.positions.len;
	if (self.skin_stale || self.skin.slots == 0 || self.skin.vertices != vertices || vertices == 0) return false;
	if (self.skin_joints != (uint)n) return false;
	if (self.part_volume.len == n && self.part_volume_skin == self.skin_generation) return true;

	if (self.part_volume.len > 0) alloc::free(mem, self.part_volume);
	self.part_volume = alloc::new_array(mem, float, (sz)n);
	self.part_volume_skin = self.skin_generation;

	Vec3[] low = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, low);
	Vec3[] high = alloc::new_array(mem, Vec3, (sz)n);
	defer alloc::free(mem, high);
	bool[] seen = alloc::new_array(mem, bool, (sz)n);
	defer alloc::free(mem, seen);

	usz slots = (usz)self.skin.slots;
	for (usz v = 0; v < vertices; v++)
	{
		usz base = v * slots;
		usz owner = n;
		float best = 0.0f;
		for (usz s = 0; s < slots; s++)
		{
			float w = self.skin.weights[base + s];
			if (w <= best) continue;
			best = w;
			owner = (usz)self.skin.joints[base + s];
		}
		if (owner >= n) continue;
		Vec3 at = self.geometry.positions[v];
		if (!seen[owner])
		{
			seen[owner] = true;
			low[owner] = at;
			high[owner] = at;
			continue;
		}
		low[owner] = { math::min(low[owner].x, at.x), math::min(low[owner].y, at.y), math::min(low[owner].z, at.z) };
		high[owner] = { math::max(high[owner].x, at.x), math::max(high[owner].y, at.y), math::max(high[owner].z, at.z) };
	}

	rig::Skeleton* skeleton = &view.skeleton;
	for (usz j = 0; j < n; j++)
	{
		// The bone the part hangs on: to the first child, or from the parent at a tip.
		float bone = 0.0f;
		for (usz c = j + 1; c < n; c++)
		{
			if (skeleton.parents[c] != (int)j) continue;
			bone = (skeleton.joints[c] - skeleton.joints[j]).length();
			break;
		}
		int parent = skeleton.parents[j];
		if (bone <= 0.0f && parent >= 0) bone = (skeleton.joints[j] - skeleton.joints[(usz)parent]).length();

		float volume = 0.0f;
		if (seen[j])
		{
			Vec3 size = high[j] - low[j];
			volume = size.x * size.y * size.z;
		}
		self.part_volume[j] = math::max(volume, bone * bone * bone * PART_MASS_FLOOR);
	}
	return true;
}

// Let the measured parts go; the next drag measures them again.
fn void Character.drop_part_volumes(&self)
{
	if (self.part_volume.len > 0) alloc::free(mem, self.part_volume);
	self.part_volume = {};
	self.part_volume_skin = 0;
}

<*
 The selected joint's pose weight, as the Weight slider shows it: 1 for the
 mesh's own.
*>
fn float AppState.selected_pose_weight(&self)
{
	Dot* dot = self.doc.find(self.selected);
	return dot ? dot.pose_weight_factor() : 1.0f;
}

<*
 Set every selected joint's pose weight, as one undo step.

 @param weight : `A multiplier; 1 puts the joints back on the mesh's own weight.`
 @return `True when any joint's weight changed.`
*>
fn bool AppState.set_selection_pose_weight(&self, float weight)
{
	bool changed = false;
	if (self.selected != 0) changed = self.set_pose_weight_recorded(self.selected, weight);
	foreach (id : self.also_selected.array_view())
	{
		if (id != self.selected && self.set_pose_weight_recorded(id, weight)) changed = true;
	}
	if (!changed) return false;
	self.undo_stack.commit();
	return true;
}

<*
 A word on how the selected joint's body part weighs against the body's
 heaviest, for the line under the slider. Borrowed or temporary; empty when
 there is no joint.
*>
fn String AppState.pose_weight_note(&self)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened) return "";
	RigView view = opened;
	defer view.free(mem);
	sz joint = view.joint_of(self.selected);
	if (joint < 0) return "";
	float[] mass = alloc::new_array(tmem, float, (sz)view.len());
	if (!self.body_part_masses(&view, mass)) return "Weighed by the rig's shape until the mesh is bound";
	float share = mass[(usz)joint] / PART_MASS_MAX;
	if (share < 0.05f) return "Light · moves before the body does";
	if (share < 0.3f) return "Medium · brings the limb above along";
	return "Heavy · holds the body where it is";
}

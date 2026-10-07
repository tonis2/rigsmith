module crig;

import rig;
import std::math;
import std::math::matrix;
import std::math::quaternion;

enum TransformTargetKind : int
{
	NO_TRANSFORM_TARGET,
	MODEL_TARGET,
	MESH_TARGET,
	SKELETON_TARGET,
	JOINT_TARGETS,
}

struct TransformTarget
{
	TransformTargetKind kind;
	uint active_joint;
	usz joint_count;
}

enum TransformSpace : int
{
	GLOBAL_SPACE,
	LOCAL_SPACE,
}

enum TransformPivot : int
{
	MEDIAN_PIVOT,
	ACTIVE_PIVOT,
}

enum TransformOperation : int
{
	MOVE_TRANSFORM,
	ROTATE_TRANSFORM,
}

struct TransformPoint
{
	uint dot_id;
	Vec3 position;
}

struct TransformLimit
{
	JointRotationLimits limits;
}

struct TransformTransaction
{
	bool active;
	TransformOperation operation;
	TransformTarget target;
	TransformSpace space;
	TransformPivot pivot_mode;
	Vec3 pivot;
	Quaternionf basis;
	ProjectTransform model_before;
	TransformPoint[] points;
	TransformLimit[] limits;
}

fn Matrix4f ProjectTransform.matrix(self)
{
	return matrix::IDENTITY4{float}.translate(self.location).mul(self.orientation().to_matrix());
}

fn Matrix4f Character.model_view_projection(&self, OrbitCamera* camera, float aspect)
{
	return camera.view_projection(aspect).mul(self.doc.model_transform.matrix());
}

fn Vec3 Character.model_eye(&self, OrbitCamera* camera)
{
	return self.doc.model_transform.inverse_point(camera.eye());
}

fn Vec3 Character.model_direction(&self, Vec3 world_direction)
{
	return self.doc.model_transform.inverse_direction(world_direction);
}

fn TransformTarget AppState.transform_target(&self)
{
	if (self.selected != 0)
	{
		return {
			.kind = JOINT_TARGETS,
			.active_joint = self.selected,
			.joint_count = self.selection_count(),
		};
	}

	switch (self.scene_selection)
	{
		case MODEL: return { .kind = MODEL_TARGET };
		case MESH: return { .kind = MESH_TARGET };
		case SKELETON: return { .kind = SKELETON_TARGET, .joint_count = (usz)self.doc.dots.len() };
		case JOINT:
			return self.selected == 0 ? (TransformTarget){} : (TransformTarget){
				.kind = JOINT_TARGETS,
				.active_joint = self.selected,
				.joint_count = self.selection_count(),
			};
		case NONE:
		case SCENE:
			return {};
	}
}

fn bool TransformTarget.supported(self)
{
	return self.kind == MODEL_TARGET || self.kind == SKELETON_TARGET || self.kind == JOINT_TARGETS;
}

fn bool finite_vec3(Vec3 value) @local
{
	return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn bool selected_for_transform(AppState* app, TransformTarget target, uint dot_id) @local
{
	if (target.kind == SKELETON_TARGET) return true;
	if (target.kind != JOINT_TARGETS) return false;
	return app.is_selected(dot_id);
}

fn uint[] AppState.rotation_branch(&self, TransformTarget target)
{
	if (target.kind != JOINT_TARGETS || target.joint_count != 1 || target.active_joint == 0) return {};

	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);

	sz active = view.joint_of(target.active_joint);
	if (active < 0) return {};
	uint[] ids = alloc::new_array(mem, uint, view.dot_ids.len);
	usz count = 0;
	foreach (usz joint, id : view.dot_ids)
	{
		for (int at = (int)joint; at >= 0; at = view.skeleton.parents[(usz)at])
		{
			if (at != (int)active) continue;
			ids[count++] = id;
			break;
		}
	}
	return ids[:count];
}

fn bool transform_includes(AppState* app, TransformTarget target, uint dot_id, uint[] branch) @local
{
	return branch.len > 0 ? array::contains(branch, dot_id) : selected_for_transform(app, target, dot_id);
}

fn Quaternionf AppState.transform_basis(&self, TransformTarget target, TransformSpace space)
{
	if (space != LOCAL_SPACE || target.kind != JOINT_TARGETS || target.active_joint == 0)
	{
		return quaternion::IDENTITY;
	}

	RigView? opened = self.open_rig(mem);
	if (catch opened) return quaternion::IDENTITY;
	RigView view = opened;
	defer view.free(mem);

	sz joint = view.joint_of(target.active_joint);
	if (joint < 0) return quaternion::IDENTITY;
	JointRotationLimits limits = self.doc.rotation_limits_of(target.active_joint);
	JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	return frame.usable() ? frame.rotation.normalize() : (Quaternionf)quaternion::IDENTITY;
}

fn Vec3 AppState.model_local_center(&self)
{
	if (self.geometry.positions.len > 0) return self.geometry.bounds().center();
	if (self.doc.dots.len() == 0) return {};
	Vec3 total = {};
	foreach (dot : self.doc.dots.array_view()) total = total + dot.position;
	return total * (1.0f / (float)self.doc.dots.len());
}

fn Vec3 AppState.transform_target_pivot(&self, TransformTarget target, TransformPivot mode)
{
	if (target.kind == MODEL_TARGET)
	{
		return self.doc.model_transform.point(self.model_local_center());
	}
	if (mode == ACTIVE_PIVOT && target.active_joint != 0)
	{
		Dot* active = self.doc.find(target.active_joint);
		if (active) return active.position;
	}

	Vec3 total;
	usz count = 0;
	foreach (dot : self.doc.dots.array_view())
	{
		if (!selected_for_transform(self, target, dot.id)) continue;
		total = total + dot.position;
		count++;
	}
	return count > 0 ? total * (1.0f / (float)count) : (Vec3){};
}

fn bool AppState.begin_transform(&self, TransformOperation operation)
{
	TransformTarget target = self.transform_target();
	return self.begin_transform_target(operation, target, self.transform_space, self.transform_pivot);
}

fn bool AppState.begin_transform_target(
	&self,
	TransformOperation operation,
	TransformTarget target,
	TransformSpace space = GLOBAL_SPACE,
	TransformPivot pivot_mode = MEDIAN_PIVOT,
	Vec3* explicit_pivot = null)
{
	if (self.transform_transaction.active || !target.supported()) return false;
	if (target.kind == MODEL_TARGET
		&& self.geometry.positions.len == 0 && self.doc.dots.len() == 0) return false;
	if (target.kind == SKELETON_TARGET && self.doc.dots.len() == 0) return false;
	if (target.kind == JOINT_TARGETS && (target.active_joint == 0 || target.joint_count == 0)) return false;
	uint[] rotation_branch = operation == ROTATE_TRANSFORM ? self.rotation_branch(target) : (uint[]){};
	defer if (rotation_branch.len > 0) alloc::free(mem, rotation_branch.ptr);

	usz point_count = target.kind == MODEL_TARGET
		? 0
		: (target.kind == SKELETON_TARGET
			? (usz)self.doc.dots.len()
			: (rotation_branch.len > 0 ? rotation_branch.len : target.joint_count));
	TransformPoint[] points = alloc::new_array(mem, TransformPoint, (sz)point_count);
	usz kept = 0;
	foreach (dot : self.doc.dots.array_view())
	{
		if (!transform_includes(self, target, dot.id, rotation_branch)) continue;
		if (kept >= points.len) break;
		points[kept++] = { .dot_id = dot.id, .position = dot.position };
	}
	if (target.kind != MODEL_TARGET && kept == 0)
	{
		if (points.len > 0) alloc::free(mem, points);
		return false;
	}
	points = points[:kept];

	// Only a turn carries the saved limit frames along; a move leaves them be.
	usz limit_count = 0;
	if (operation == ROTATE_TRANSFORM)
	{
		foreach (limits : self.doc.rotation_limits.array_view())
		{
			if (limits.has_saved_frame
				&& transform_includes(self, target, limits.dot_id, rotation_branch)) limit_count++;
		}
	}
	TransformLimit[] limit_snapshots = alloc::new_array(mem, TransformLimit, (sz)limit_count);
	usz limit_at = 0;
	foreach (limits : self.doc.rotation_limits.array_view())
	{
		if (limit_at >= limit_snapshots.len) break;
		if (!limits.has_saved_frame
			|| !transform_includes(self, target, limits.dot_id, rotation_branch)) continue;
		limit_snapshots[limit_at++] = { .limits = limits };
	}

	Quaternionf basis = self.transform_basis(target, space);
	Vec3 pivot = explicit_pivot
		? *explicit_pivot
		: self.transform_target_pivot(target, pivot_mode);
	self.transform_transaction = {
		.active = true,
		.operation = operation,
		.target = target,
		.space = space,
		.pivot_mode = pivot_mode,
		.pivot = pivot,
		.basis = basis,
		.model_before = self.doc.model_transform,
		.points = points,
		.limits = limit_snapshots,
	};
	return true;
}

fn void AppState.restore_transform_start(&self)
{
	TransformTransaction* transaction = &self.transform_transaction;
	if (transaction.target.kind == MODEL_TARGET)
	{
		self.doc.model_transform = transaction.model_before;
		return;
	}
	foreach (point : transaction.points)
	{
		Dot* dot = self.doc.find(point.dot_id);
		if (dot) dot.position = point.position;
	}
	foreach (snapshot : transaction.limits)
	{
		(void)self.doc.set_rotation_limits(snapshot.limits.dot_id, snapshot.limits);
	}
}

fn Vec3 transaction_vector(TransformTransaction* transaction, Vec3 local) @local
{
	return transaction.space == LOCAL_SPACE ? transaction.basis.rotate_vec3(local) : local;
}

fn Quaternionf transaction_rotation(TransformTransaction* transaction, Quaternionf local) @local
{
	Quaternionf delta = local.normalize();
	if (transaction.space != LOCAL_SPACE) return delta;
	Quaternionf basis = transaction.basis.normalize();
	return basis.mul(delta).mul(basis.invert()).normalize();
}

fn bool AppState.update_transform_translation(&self, Vec3 delta)
{
	TransformTransaction* transaction = &self.transform_transaction;
	if (!transaction.active || transaction.operation != MOVE_TRANSFORM || !finite_vec3(delta)) return false;
	if (transaction.target.kind == MODEL_TARGET)
	{
		Vec3 moved = transaction.space == LOCAL_SPACE
			? transaction.model_before.direction(delta)
			: delta;
		self.doc.model_transform = transaction.model_before;
		self.doc.model_transform.location = transaction.model_before.location + moved;
		return true;
	}
	Vec3 moved = transaction_vector(transaction, delta);
	foreach (point : transaction.points)
	{
		Dot* dot = self.doc.find(point.dot_id);
		if (dot) dot.position = point.position + moved;
	}
	self.mark_rig_stale();
	self.refresh_pose_display();
	return true;
}

fn bool AppState.update_transform_rotation(&self, Quaternionf delta)
{
	TransformTransaction* transaction = &self.transform_transaction;
	if (!transaction.active || transaction.operation != ROTATE_TRANSFORM) return false;
	float[<4>] value = delta.v;
	if (!math::is_finite(value.x) || !math::is_finite(value.y)
		|| !math::is_finite(value.z) || !math::is_finite(value.w)
		|| value.dot(value) <= 1.0e-12f) return false;

	Quaternionf turn = transaction_rotation(transaction, delta);
	if (transaction.target.kind == MODEL_TARGET)
	{
		ProjectTransform before = transaction.model_before;
		Quaternionf world_turn = transaction.space == LOCAL_SPACE
			? before.orientation().mul(delta.normalize()).mul(before.orientation().invert()).normalize()
			: delta.normalize();
		self.doc.model_transform = before;
		self.doc.model_transform.rotation = transaction.space == LOCAL_SPACE
			? before.orientation().mul(delta.normalize()).normalize()
			: world_turn.mul(before.orientation()).normalize();
		self.doc.model_transform.location = transaction.pivot
			+ world_turn.rotate_vec3(before.location - transaction.pivot);
		return true;
	}
	foreach (point : transaction.points)
	{
		Dot* dot = self.doc.find(point.dot_id);
		if (dot)
		{
			dot.position = transaction.pivot + turn.rotate_vec3(point.position - transaction.pivot);
		}
	}
	foreach (snapshot : transaction.limits)
	{
		JointRotationLimits rotated = snapshot.limits;
		rotated.saved_frame = turn.mul(snapshot.limits.saved_frame).normalize();
		(void)self.doc.set_rotation_limits(rotated.dot_id, rotated);
	}
	self.mark_rig_stale();
	self.refresh_pose_display();
	return true;
}

fn bool AppState.update_transform_rotation_axis(&self, Vec3 axis, float radians)
{
	if (!finite_vec3(axis) || !math::is_finite(radians) || axis.length_sq() <= 1.0e-12f) return false;
	return self.update_transform_rotation(
		quaternion::from_axis_angle{float}(axis.normalize(), radians));
}

fn bool AppState.commit_transform(&self)
{
	TransformTransaction* transaction = &self.transform_transaction;
	if (!transaction.active) return false;

	bool changed = false;
	if (transaction.target.kind == MODEL_TARGET)
	{
		ProjectTransform after = self.doc.model_transform;
		changed = self.set_model_transform_recorded(transaction.model_before, after);
		if (changed) self.undo_stack.commit();
		self.discard_transform_transaction();
		return changed;
	}
	foreach (point : transaction.points)
	{
		Dot* dot = self.doc.find(point.dot_id);
		if (!dot || dot.position == point.position) continue;
		Vec3 to = dot.position;
		if (self.move_recorded(point.dot_id, point.position, to)) changed = true;
	}
	foreach (snapshot : transaction.limits)
	{
		JointRotationLimits after = self.doc.rotation_limits_of(snapshot.limits.dot_id);
		if (snapshot.limits.same(after)) continue;
		self.undo_stack.record_rotation_limits(snapshot.limits, after);
		changed = true;
	}
	if (changed) self.undo_stack.commit();

	self.discard_transform_transaction();
	if (changed)
	{
		self.mark_rig_stale();
		self.refresh_pose_display();
	}
	return changed;
}

fn bool AppState.cancel_transform(&self)
{
	if (!self.transform_transaction.active) return false;
	self.restore_transform_start();
	self.discard_transform_transaction();
	self.mark_rig_stale();
	self.refresh_pose_display();
	return true;
}

fn void AppState.discard_transform_transaction(&self)
{
	TransformTransaction* transaction = &self.transform_transaction;
	if (transaction.points.len > 0) alloc::free(mem, transaction.points);
	if (transaction.limits.len > 0) alloc::free(mem, transaction.limits);
	*transaction = {};
}

enum MoveByResult : int
{
	MOVED,
	UNCHANGED,
	LOCKED,
	REFUSED,
}

<*
 Move the current transform target — model, whole skeleton, or joints — by an
 exact offset along the world axes, as one undo step. The numeric twin of a G
 drag, through the same transaction.
*>
fn MoveByResult AppState.move_selection_by(&self, Vec3 offset)
{
	TransformTarget target = self.transform_target();
	if (!target.supported() || !finite_vec3(offset)) return REFUSED;
	if (target.kind != MODEL_TARGET && self.rig_locked()) return LOCKED;
	if (offset == (Vec3){}) return UNCHANGED;
	if (!self.begin_transform_target(MOVE_TRANSFORM, target, GLOBAL_SPACE, MEDIAN_PIVOT)) return REFUSED;
	if (!self.update_transform_translation(offset))
	{
		(void)self.cancel_transform();
		return REFUSED;
	}
	return self.commit_transform() ? MOVED : UNCHANGED;
}

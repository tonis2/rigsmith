<* The pure half of src/app/transform.c3: no state, undo or notices. *>
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
	// The whole model, uniformly, about its origin: `scale_model_by` on release.
	SCALE_TRANSFORM,
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
	// What a SCALE_TRANSFORM has reached, as a factor of the size it began at.
	float scale;
	TransformPoint[] points;
	TransformLimit[] limits;
}

fn Matrix4f ProjectTransform.matrix(self)
{
	return matrix::IDENTITY4{float}.translate(self.location).mul(self.orientation().to_matrix());
}

fn bool TransformTarget.supported(self)
{
	return self.kind == MODEL_TARGET || self.kind == SKELETON_TARGET || self.kind == JOINT_TARGETS;
}

fn bool finite_vec3(Vec3 value)
{
	return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn Vec3 transaction_vector(TransformTransaction* transaction, Vec3 local)
{
	return transaction.space == LOCAL_SPACE ? transaction.basis.rotate_vec3(local) : local;
}

fn Quaternionf transaction_rotation(TransformTransaction* transaction, Quaternionf local)
{
	Quaternionf delta = local.normalize();
	if (transaction.space != LOCAL_SPACE) return delta;
	Quaternionf basis = transaction.basis.normalize();
	return basis.mul(delta).mul(basis.invert()).normalize();
}

enum MoveByResult : int
{
	MOVED,
	UNCHANGED,
	LOCKED,
	REFUSED,
}

fn Vec3 model_direction(RigDocument* doc, Vec3 world_direction)
{
	return doc.model_transform.inverse_direction(world_direction);
}

fn Vec3 model_local_center(RigDocument* doc, rig::TriMesh* geometry)
{
	if (geometry.positions.len > 0) return geometry.bounds().center();
	if (doc.dots.len() == 0) return {};
	Vec3 total = {};
	foreach (dot : doc.dots.array_view()) total = total + dot.position;
	return total * (1.0f / (float)doc.dots.len());
}

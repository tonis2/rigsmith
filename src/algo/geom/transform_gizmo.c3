<* The pure half of src/ui/transform_gizmo.c3: no state, undo or notices. *>
module crig;

import collision;
import std::math;
import std::math::quaternion;

enum TransformTool : int
{
	SELECT_TOOL,
	MOVE_TOOL,
	ROTATE_TOOL,
	// Always the whole model, whatever is selected: there is one size a
	// character is, and a joint has none of its own.
	SCALE_TOOL,
}

enum TransformGizmoPart : int
{
	NO_GIZMO_PART,
	GIZMO_X,
	GIZMO_Y,
	GIZMO_Z,
	GIZMO_XY,
	GIZMO_YZ,
	GIZMO_XZ,
	GIZMO_FREE,
}

const float TRANSFORM_AXIS_LENGTH = 46.0f;

const float TRANSFORM_RING_RADIUS = 40.0f;

const float TRANSFORM_HIT_WIDTH = 7.0f;

// Where a keyboard G/R pretends the pointer started when it was on the pivot:
// a rotation needs an arm to measure the angle from.
const float TRANSFORM_KEY_ANCHOR = 48.0f;

const float TRANSFORM_PLANE_NEAR = 17.0f;

const float TRANSFORM_PLANE_FAR = 26.0f;

const float TRANSFORM_PLANE_HIT = 7.0f;

const float TRANSFORM_LINE_WIDTH = 2.0f;

const float TRANSFORM_ACTIVE_WIDTH = 3.25f;

const float TRANSFORM_ARROW = 7.0f;

const usz TRANSFORM_RING_STEPS = 48;

struct TransformGizmoFrame
{
	TransformTarget target;
	TransformSpace space;
	TransformOperation operation;
	Vec3 pivot;
	Vec2 projected_pivot;
	Vec3[3] axes;
	Vec2[3] screen_axes;
	bool[3] visible_axes;
	float radius;
	Matrix4f projection;
	Vec2 size;
}

fn String transform_target_label(TransformTransaction* transaction) @private
{
	switch (transaction.target.kind)
	{
		case MODEL_TARGET: return "Model";
		case SKELETON_TARGET: return "Skeleton";
		case JOINT_TARGETS:
			if (transaction.target.joint_count > 1) return "Joints";
			return transaction.operation == ROTATE_TRANSFORM && transaction.points.len > 1
				? "Joint branch" : "Joint";
		case MESH_TARGET: return "Mesh";
		case NO_TRANSFORM_TARGET: return "Selection";
	}
}

fn Vec3 interaction_axis(TransformTransaction* transaction, int component) @private
{
	Vec3 axis = AXIS_DIRECTION[component];
	if (transaction.space != LOCAL_SPACE) return axis;
	if (transaction.target.kind == MODEL_TARGET)
	{
		return transaction.model_before.direction(axis).normalize();
	}
	return transaction.basis.rotate_vec3(axis).normalize();
}

fn Vec3 edit_delta_to_input(TransformTransaction* transaction, Vec3 delta) @private
{
	if (transaction.space != LOCAL_SPACE) return delta;
	if (transaction.target.kind == MODEL_TARGET)
	{
		return transaction.model_before.inverse_direction(delta);
	}
	return transaction.basis.invert().rotate_vec3(delta);
}

fn Vec3 edit_axis_to_input(TransformTransaction* transaction, Vec3 axis) @private
{
	Vec3 input = edit_delta_to_input(transaction, axis);
	return input.length_sq() > 1.0e-12f ? input.normalize() : input;
}

fn DragAxis gizmo_axis(TransformGizmoPart part) @private
{
	switch (part)
	{
		case GIZMO_X: return DragAxis.X;
		case GIZMO_Y: return DragAxis.Y;
		case GIZMO_Z: return DragAxis.Z;
		case GIZMO_XY: return DragAxis.XY;
		case GIZMO_YZ: return DragAxis.YZ;
		case GIZMO_XZ: return DragAxis.XZ;
		default: return DragAxis.FREE; // GIZMO_FREE included
	}
}

fn float point_segment_distance(Vec2 point, Vec2 a, Vec2 b) @private
{
	Vec2 line = b - a;
	float length_sq = line.length_sq();
	if (length_sq <= 1.0e-8f) return (point - a).length();
	float at = math::clamp((point - a).dot(line) / length_sq, 0.0f, 1.0f);
	return (point - (a + line * at)).length();
}

fn Vec2 plane_handle_center(TransformGizmoFrame* frame, int first, int second) @private
{
	return frame.projected_pivot
		+ frame.screen_axes[first] * ((TRANSFORM_PLANE_NEAR + TRANSFORM_PLANE_FAR) * 0.5f)
		+ frame.screen_axes[second] * ((TRANSFORM_PLANE_NEAR + TRANSFORM_PLANE_FAR) * 0.5f);
}

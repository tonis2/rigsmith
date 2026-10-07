module crig;

import collision;
import cui;
import std::io;
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

struct TransformInteraction
{
	bool active;
	bool held;
	Viewport* viewport;
	TransformOperation operation;
	DragAxis axis;
	OrbitCamera camera;
	Vec2 viewport_origin;
	Vec2 viewport_size;
	Vec2 anchor;
	Vec2 pointer;
	Vec3 raw_translation;
	Vec3 applied_translation;
	// Ctrl held on the last pointer move: the joints slide on the view plane
	// rather than into the mesh under the pointer.
	bool free_move;
	float raw_angle;
	float applied_angle;
	// A scale's factor from the pointer's distance to the pivot, against the
	// distance it started at.
	float raw_scale;
	float applied_scale;
	float last_pointer_angle;
	bool angle_ready;
	char[32] numeric_storage;
	usz numeric_length;
	char[192] status_storage;
	usz status_length;
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
// The middle of the move gizmo belongs to the joint under it, not to an arrow:
// the arrows start this far out and nothing inside it locks an axis. A press on
// the joint drags it freely onto the model; on a Skeleton or Model it is a free
// move in the view plane. One pick radius plus a little, so the dot's own grab
// area is never shadowed by an arrow.
const float TRANSFORM_FREE_RADIUS = PICK_RADIUS + 2.0f;
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

// The rest rig is not edited on Pose, nor while a clip shows or a pose is pending.
fn bool transform_target_locked(AppState* app, TransformTarget target) @private
{
	return target.kind != MODEL_TARGET && (app.rig_locked() || app.stage == POSE_STAGE);
}

fn bool transform_tool_claims_pointer(AppState* app) @private
{
	return !app.lassoing && !app.brushing && !app.areaing && !app.sketching;
}

<*
 Whether the Move and Rotate tools pose the selected joint rather than edit the
 rest skeleton: on Pose, with an animation to key into and one joint selected.

 An arrow is then G locked to that axis and a ring is R locked to it, so a pose
 can be built with the tools as well as the keys. The hips carry the whole body
 with them, which is how a clip jumps.
*>
fn bool transform_tool_poses(AppState* app) @private
{
	if (app.transform_tool == SELECT_TOOL || app.transform_tool == SCALE_TOOL
		|| app.transform_interaction.active) return false;
	if (app.selected == 0 || app.selection_count() != 1) return false;
	return app.animation_pose_ready();
}

// The axis a pose gesture begun from the gizmo is held to, for lighting it.
fn DragAxis transform_active_axis(AppState* app) @private
{
	if (app.transform_interaction.active) return app.transform_interaction.axis;
	if (app.drag.dot != 0 && app.drag.dot == app.selected) return app.drag.axis;
	return DragAxis.FREE;
}

<*
 What the selected persistent tool can do with the selection it has now.

 This stays visible in the hint bar after the click notice expires. In
 particular, a playing clip locks joint and skeleton rest edits; previously the
 gizmo simply disappeared in that state, leaving only a lit toolbar cell and no
 explanation of how to get a usable whole-character transform.
*>
fn String transform_tool_hint(AppState* app)
{
	if (app.transform_tool == SELECT_TOOL || app.transform_interaction.active) return "";
	if (app.transform_tool == SCALE_TOOL)
	{
		if (!app.has_mesh() && app.doc.dots.len() == 0) return "Scale tool · open a model to scale";
		return app.pose_edit_active
			? "Scale tool · key or discard the pose before resizing the model"
			: "Scale tool · drag the ring to resize the whole model and its rig · type a factor · Enter or release confirms, Esc cancels";
	}

	TransformTarget target = app.transform_target();
	String verb = app.transform_tool == MOVE_TOOL ? "Move" : "Rotate";
	if (transform_tool_poses(app))
	{
		return verb == "Move"
			? "Move tool · posing · drag an arrow to move the joint along it · the hips carry the whole body, for a jump"
			: "Rotate tool · posing · drag a colored ring to turn the joint about its own axis";
	}
	if (!target.supported())
	{
		return target.kind == MESH_TARGET
			? "The mesh can't move on its own · select Model in Scene to move mesh and rig together"
			: "Select Model, Skeleton, or a joint in Scene to use the transform tool";
	}
	if (transform_target_locked(app, target))
	{
		if (app.stage == POSE_STAGE && !app.rig_locked())
		{
			return "Pose · select one joint to pose it with the tool · switch to Joints to edit the rig";
		}
		return app.animating
			? "An animation is showing · switch to Pose to move a joint in it (the hips carry the whole body) · Model moves the character in the scene, not in the clip"
			: "Key or discard the pose before editing the rest skeleton";
	}

	if (target.kind == MODEL_TARGET)
	{
		return verb == "Move"
			? "Move tool · the whole model · drag a colored arrow or plane, or the middle, to move it · click a joint to move that instead"
			: "Rotate tool · the whole model · drag a colored ring to turn it · click a joint to turn that instead";
	}
	return verb == "Move"
		? "Move tool · drag a joint to place it on the model · drag a colored arrow or plane to slide along it"
		: "Rotate tool · drag a colored ring in the 3D view";
}

fn String transform_numeric_text(TransformInteraction* interaction) @private
{
	return (String)interaction.numeric_storage[:interaction.numeric_length];
}

fn float? transform_numeric_value(TransformInteraction* interaction) @private
{
	if (interaction.numeric_length == 0) return NO_TRANSFORM_NUMBER~;
	return transform_numeric_text(interaction).to_float();
}

faultdef NO_TRANSFORM_NUMBER;

fn String transform_axis_label(TransformInteraction* interaction) @private
{
	if (interaction.operation == SCALE_TRANSFORM) return "Uniform";
	if (interaction.axis != DragAxis.FREE) return interaction.axis.label();
	return interaction.operation == ROTATE_TRANSFORM ? "View" : "Free";
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

fn void AppState.refresh_transform_status(&self)
{
	TransformInteraction* interaction = &self.transform_interaction;
	if (!interaction.active)
	{
		interaction.status_length = 0;
		return;
	}

	if (interaction.operation == SCALE_TRANSFORM)
	{
		float now = self.model_height() * interaction.applied_scale;
		char[]? said = io::bprintf(interaction.status_storage[..],
			"Scale Model · ×%.3g · %.3g tall     type a factor     Enter / click · confirm     Esc / right-click · cancel",
			interaction.applied_scale, now);
		interaction.status_length = 0;
		if (try char[] line = said) interaction.status_length = line.len;
		return;
	}
	String operation = interaction.operation == MOVE_TRANSFORM ? "Move" : "Rotate";
	String target = transform_target_label(&self.transform_transaction);
	String space = self.transform_transaction.space == LOCAL_SPACE ? "Local" : "Global";
	float value;
	if (interaction.operation == ROTATE_TRANSFORM)
	{
		value = math::rad_to_deg(interaction.applied_angle);
	}
	else if (interaction.axis.is_direction())
	{
		int component = interaction.axis.component();
		value = component >= 0
			? interaction.applied_translation.dot(interaction_axis(&self.transform_transaction, component))
			: interaction.applied_translation.length();
	}
	else
	{
		value = interaction.applied_translation.length();
	}
	char[]? written = io::bprintf(interaction.status_storage[..],
		"%s %s · %s · %s · %.3g%s     Enter / click · confirm     Esc / right-click · cancel",
		operation, target, transform_axis_label(interaction), space, value,
		interaction.operation == MOVE_TRANSFORM ? " m" : "°");
	if (try char[] line = written)
	{
		interaction.status_length = line.len;
	}
	else
	{
		interaction.status_length = 0;
	}
}

fn String AppState.transform_status(&self)
{
	return (String)self.transform_interaction.status_storage[:self.transform_interaction.status_length];
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

fn collision::Ray? interaction_ray(AppState* app, Vec2 pixel) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	Vec3 direction = interaction.camera.ray_direction(pixel, interaction.viewport_size)!;
	if (app.transform_transaction.target.kind == MODEL_TARGET)
	{
		return { .origin = interaction.camera.eye(), .direction = direction };
	}
	return {
		.origin = app.transform_transaction.model_before.inverse_point(interaction.camera.eye()),
		.direction = app.transform_transaction.model_before.inverse_direction(direction).normalize(),
	};
}

fn Vec3? ray_plane(collision::Ray ray, Vec3 point, Vec3 normal) @private
{
	float divisor = ray.direction.dot(normal);
	if (math::abs(divisor) <= 1.0e-6f) return TRANSFORM_PLANE_EDGE_ON~;
	float distance = (point - ray.origin).dot(normal) / divisor;
	return ray.origin + ray.direction * distance;
}

faultdef TRANSFORM_PLANE_EDGE_ON;

fn Vec3 interaction_view_axis(AppState* app) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	Vec3 toward_eye = (interaction.camera.eye() - interaction.camera.target).normalize();
	return app.transform_transaction.target.kind == MODEL_TARGET
		? toward_eye
		: app.transform_transaction.model_before.inverse_direction(toward_eye).normalize();
}

fn Vec3 interaction_plane_normal(AppState* app, DragAxis axis) @private
{
	if (axis == DragAxis.FREE) return interaction_view_axis(app);
	int component = axis.plane_normal_component();
	return component >= 0
		? interaction_axis(&app.transform_transaction, component)
		: interaction_view_axis(app);
}

fn Vec3 pointer_translation(AppState* app, Vec2 pointer) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	TransformTransaction* transaction = &app.transform_transaction;
	collision::Ray? current = interaction_ray(app, pointer);
	collision::Ray? anchored = interaction_ray(app, interaction.anchor);
	if (catch current) return interaction.raw_translation;
	if (catch anchored) return interaction.raw_translation;

	if (interaction.axis.is_direction())
	{
		int component = interaction.axis.component();
		if (component < 0) return interaction.raw_translation;
		Vec3 axis = interaction_axis(transaction, component);
		Vec3? now = slide_along_direction(transaction.pivot, axis, current);
		Vec3? start = slide_along_direction(transaction.pivot, axis, anchored);
		if (catch now) return interaction.raw_translation;
		if (catch start) return interaction.raw_translation;
		return now - start;
	}

	Vec3 normal = interaction_plane_normal(app, interaction.axis);
	Vec3? now = ray_plane(current, transaction.pivot, normal);
	Vec3? start = ray_plane(anchored, transaction.pivot, normal);
	if (catch now) return interaction.raw_translation;
	if (catch start) return interaction.raw_translation;
	return now - start;
}

<*
 A free move of joints carried into the mesh under the pointer.

 The view-plane move keeps the joint at the depth it started at, which looks
 right from where it was made and is nowhere near the body from the side. Here
 the moved joint picks its depth the way a dragged dot does: the middle of the
 material along the eye ray through it, holding to the piece it is already in.
 The rest of the selection follows by the same amount. Off the mesh, or with
 Ctrl held, the plane move stands.
*>
fn Vec3 snapped_translation(AppState* app, Vec3 planar) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	TransformTransaction* transaction = &app.transform_transaction;
	if (interaction.free_move || interaction.axis != DragAxis.FREE) return planar;
	if (transaction.target.kind != JOINT_TARGETS || transaction.points.len == 0) return planar;

	// One joint moves itself; a group moves its pivot.
	Vec3 start = transaction.points.len == 1 ? transaction.points[0].position : transaction.pivot;
	Vec3 eye = transaction.model_before.inverse_point(interaction.camera.eye());
	Vec3 toward = start + planar - eye;
	if (toward.length_sq() <= 1.0e-12f) return planar;

	Vec3 near = start + interaction.raw_translation;
	Vec3? snapped = app.picker.snap_inside({ .origin = eye, .direction = toward.normalize() }, &near);
	if (catch snapped) return planar;
	return snapped - start;
}

fn Vec3 numeric_translation(AppState* app, float value) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	TransformTransaction* transaction = &app.transform_transaction;
	if (interaction.axis.is_direction())
	{
		int component = interaction.axis.component();
		return component >= 0 ? interaction_axis(transaction, component) * value : (Vec3){};
	}

	Vec3 direction = interaction.raw_translation;
	if (direction.length_sq() <= 1.0e-12f)
	{
		if (interaction.axis.is_plane())
		{
			int normal = interaction.axis.plane_normal_component();
			for (int component = 0; component < 3; component++)
			{
				if (component != normal)
				{
					direction = interaction_axis(transaction, component);
					break;
				}
			}
		}
		else
		{
			Vec3 forward = interaction_view_axis(app);
			Vec3 up = transaction.target.kind == MODEL_TARGET
				? (Vec3){ 0, 1, 0 }
				: transaction.model_before.inverse_direction({ 0, 1, 0 });
			direction = up.cross(forward);
			if (direction.length_sq() <= 1.0e-12f) direction = interaction_axis(transaction, 0);
		}
	}
	return direction.normalize() * value;
}

fn void AppState.apply_transform_interaction(&self)
{
	TransformInteraction* interaction = &self.transform_interaction;
	if (!interaction.active) return;

	float? numeric = transform_numeric_value(interaction);
	if (interaction.operation == SCALE_TRANSFORM)
	{
		float factor = interaction.raw_scale;
		if (try float entered = numeric) factor = entered;
		if (factor <= 0.0f) factor = interaction.applied_scale > 0.0f ? interaction.applied_scale : 1.0f;
		factor = math::clamp(factor, SCALE_MODEL_MIN, SCALE_MODEL_MAX);
		interaction.applied_scale = factor;
		(void)self.update_transform_scale(factor);
	}
	else if (interaction.operation == MOVE_TRANSFORM)
	{
		Vec3 delta = interaction.raw_translation;
		if (try float entered = numeric) delta = numeric_translation(self, entered);
		interaction.applied_translation = delta;
		(void)self.update_transform_translation(edit_delta_to_input(&self.transform_transaction, delta));
	}
	else
	{
		float angle = interaction.raw_angle;
		if (try float entered = numeric) angle = math::deg_to_rad(entered);
		Vec3 axis;
		if (interaction.axis.is_direction())
		{
			int component = interaction.axis.component();
			axis = component >= 0
				? interaction_axis(&self.transform_transaction, component)
				: interaction_view_axis(self);
		}
		else
		{
			axis = interaction_view_axis(self);
		}
		interaction.applied_angle = angle;
		(void)self.update_transform_rotation_axis(
			edit_axis_to_input(&self.transform_transaction, axis), angle);
	}
	self.refresh_transform_status();
	self.refresh_ui();
}

fn Matrix4f interaction_projection(AppState* app) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	float aspect = interaction.viewport_size.y > 0.0f
		? interaction.viewport_size.x / interaction.viewport_size.y : 1.0f;
	Matrix4f projection = interaction.camera.view_projection(aspect);
	return app.transform_transaction.target.kind == MODEL_TARGET
		? projection
		: projection.mul(app.transform_transaction.model_before.matrix());
}

fn Vec2 interaction_projected_pivot(AppState* app) @private
{
	Vec2? projected = project(interaction_projection(app), app.transform_transaction.pivot,
		app.transform_interaction.viewport_size);
	if (try Vec2 at = projected) return at;
	return app.transform_interaction.viewport_size * 0.5f;
}

fn bool Viewport.begin_transform_interaction(
	&self,
	Element* elem,
	TransformOperation operation,
	DragAxis axis,
	bool held,
	Vec2 pointer)
{
	AppState* app = elem.inherit(AppState)!!;
	TransformTarget target = operation == SCALE_TRANSFORM
		? (TransformTarget){ .kind = MODEL_TARGET }
		: app.transform_target();
	if (operation == SCALE_TRANSFORM && app.pose_edit_active)
	{
		app.@notice("key or discard the pose before resizing the model");
		app.refresh_ui();
		return false;
	}
	if (!target.supported())
	{
		app.@notice(target.kind == MESH_TARGET
			? "mesh-only transforms need a geometry rebuild and are not available yet"
			: "select the model, skeleton, or one or more joints to transform");
		app.refresh_ui();
		return false;
	}
	if (transform_target_locked(app, target))
	{
		app.@notice(app.stage == POSE_STAGE
			? "Pose poses joints · switch to Joints to edit the rest skeleton"
			: "finish animation posing before editing the rest skeleton");
		app.refresh_ui();
		return false;
	}

	app.end_brush();
	app.end_lasso();
	app.end_area();
	if (!app.begin_transform_target(operation, target, app.transform_space, app.transform_pivot))
	{
		app.@notice("that selection cannot be transformed");
		app.refresh_ui();
		return false;
	}
	if (operation == ROTATE_TRANSFORM && target.kind == JOINT_TARGETS
		&& app.transform_transaction.points.len < 2)
	{
		app.discard_transform_transaction();
		app.@notice("this joint has no child branch to rotate — select its parent, Skeleton, or Model");
		app.refresh_ui();
		return false;
	}

	self.activate_camera(elem);
	app.transform_interaction = {
		.active = true,
		.held = held,
		.viewport = self,
		.operation = operation,
		.axis = axis,
		.camera = *self.view_camera(elem),
		.viewport_origin = elem.absolute,
		.viewport_size = elem.size,
		.anchor = pointer,
		.pointer = pointer,
	};

	// A pointer off the viewport gives the drag a starting point beside the pivot.
	// So does one on the pivot for a turn, which needs an arm to read an angle off;
	// a move starts from the pointer itself, or its first motion would jump.
	Vec2 pivot = interaction_projected_pivot(app);
	if (pointer.x < 0.0f || pointer.y < 0.0f
		|| pointer.x > elem.size.x || pointer.y > elem.size.y
		|| (operation != MOVE_TRANSFORM && (pointer - pivot).length() < 8.0f))
	{
		app.transform_interaction.anchor = pivot + (Vec2){ TRANSFORM_KEY_ANCHOR, 0 };
		app.transform_interaction.pointer = app.transform_interaction.anchor;
	}
	if (operation == SCALE_TRANSFORM)
	{
		app.transform_interaction.raw_scale = 1.0f;
		app.transform_interaction.applied_scale = 1.0f;
		(void)app.update_transform_scale(1.0f);
	}
	if (operation == ROTATE_TRANSFORM)
	{
		Vec2 arm = app.transform_interaction.anchor - pivot;
		app.transform_interaction.last_pointer_angle = (float)math::atan2(arm.y, arm.x);
		app.transform_interaction.angle_ready = true;
	}
	app.refresh_transform_status();
	app.refresh_ui();
	return true;
}

fn Element* active_transform_viewport(Ui* ui, AppState* app)
{
	for (Element* at = ui.hovered; at != null; at = at.parent)
	{
		if (at.is_widget(Viewport)) return at;
	}

	Element* found = null;
	ui.@each(Viewport; viewport)
	{
		if (!found && viewport.widget_as(Viewport) == app.active_viewport) found = viewport;
	};
	if (found) return found;
	if (try Element* first = ui.find(Viewport)) return first;
	return null;
}

fn bool begin_keyboard_transform(Ui* ui, TransformOperation operation)
{
	AppState* app = ui.inherit(AppState)!!;
	Element* viewport = active_transform_viewport(ui, app);
	if (!viewport) return false;
	Viewport* widget = viewport.widget_as(Viewport);
	Vec2 pointer = ui.input.mouse - viewport.absolute;
	return widget.begin_transform_interaction(viewport, operation, DragAxis.FREE, false, pointer);
}

fn void AppState.update_transform_pointer(&self, Vec2 absolute)
{
	TransformInteraction* interaction = &self.transform_interaction;
	if (!interaction.active) return;
	Vec2 pointer = absolute - interaction.viewport_origin;
	interaction.pointer = pointer;

	if (interaction.operation == MOVE_TRANSFORM)
	{
		interaction.raw_translation = snapped_translation(self, pointer_translation(self, pointer));
	}
	else if (interaction.operation == SCALE_TRANSFORM)
	{
		// Blender's rule: as far from the pivot as the pointer is, against where
		// it was pressed — out to grow, in to shrink, past the pivot never.
		Vec2 pivot = interaction_projected_pivot(self);
		float start = (interaction.anchor - pivot).length();
		if (start >= 1.0f) interaction.raw_scale = (pointer - pivot).length() / start;
	}
	else
	{
		Vec2 pivot = interaction_projected_pivot(self);
		Vec2 arm = pointer - pivot;
		if (arm.length() >= 8.0f)
		{
			float now = (float)math::atan2(arm.y, arm.x);
			if (interaction.angle_ready)
			{
				interaction.raw_angle -= wrapped_to_pi(now - interaction.last_pointer_angle);
			}
			interaction.last_pointer_angle = now;
			interaction.angle_ready = true;
		}
	}
	self.apply_transform_interaction();
}

fn void AppState.set_transform_constraint(&self, DragAxis axis)
{
	TransformInteraction* interaction = &self.transform_interaction;
	if (!interaction.active) return;
	if (interaction.operation == SCALE_TRANSFORM) return;
	if (interaction.operation == ROTATE_TRANSFORM && axis.is_plane()) return;
	interaction.axis = interaction.axis == axis ? DragAxis.FREE : axis;
	if (interaction.operation == MOVE_TRANSFORM)
	{
		interaction.raw_translation = pointer_translation(self, interaction.pointer);
	}
	self.apply_transform_interaction();
}

fn int transform_digit(Key key) @private
{
	switch (key)
	{
		case Key.KEY_0:
		case Key.NUM_0: return 0;
		case Key.KEY_1:
		case Key.NUM_1: return 1;
		case Key.KEY_2:
		case Key.NUM_2: return 2;
		case Key.KEY_3:
		case Key.NUM_3: return 3;
		case Key.KEY_4:
		case Key.NUM_4: return 4;
		case Key.KEY_5:
		case Key.NUM_5: return 5;
		case Key.KEY_6:
		case Key.NUM_6: return 6;
		case Key.KEY_7:
		case Key.NUM_7: return 7;
		case Key.KEY_8:
		case Key.NUM_8: return 8;
		case Key.KEY_9:
		case Key.NUM_9: return 9;
		default: return -1;
	}
}

fn bool AppState.transform_numeric_key(&self, Key key)
{
	TransformInteraction* interaction = &self.transform_interaction;
	if (!interaction.active) return false;
	int digit = transform_digit(key);
	if (digit >= 0)
	{
		if (interaction.numeric_length < interaction.numeric_storage.len)
		{
			interaction.numeric_storage[interaction.numeric_length++] = (char)('0' + digit);
		}
		self.apply_transform_interaction();
		return true;
	}

	if (key == Key.PERIOD || key == Key.KP_DECIMAL)
	{
		bool found = false;
		foreach (char c : interaction.numeric_storage[:interaction.numeric_length])
		{
			if (c == '.') { found = true; break; }
		}
		if (!found && interaction.numeric_length + 1 < interaction.numeric_storage.len)
		{
			if (interaction.numeric_length == 0) interaction.numeric_storage[interaction.numeric_length++] = '0';
			interaction.numeric_storage[interaction.numeric_length++] = '.';
		}
		self.apply_transform_interaction();
		return true;
	}

	if (key == Key.MINUS || key == Key.KP_SUBTRACT)
	{
		if (interaction.numeric_length > 0 && interaction.numeric_storage[0] == '-')
		{
			for (usz i = 1; i < interaction.numeric_length; i++)
			{
				interaction.numeric_storage[i - 1] = interaction.numeric_storage[i];
			}
			interaction.numeric_length--;
		}
		else if (interaction.numeric_length < interaction.numeric_storage.len)
		{
			for (usz i = interaction.numeric_length; i > 0; i--)
			{
				interaction.numeric_storage[i] = interaction.numeric_storage[i - 1];
			}
			interaction.numeric_storage[0] = '-';
			interaction.numeric_length++;
		}
		self.apply_transform_interaction();
		return true;
	}

	if (key == Key.BACKSPACE)
	{
		if (interaction.numeric_length > 0) interaction.numeric_length--;
		self.apply_transform_interaction();
		return true;
	}
	return false;
}

fn bool AppState.finish_transform_interaction(&self, bool commit)
{
	if (!self.transform_interaction.active) return false;
	bool changed = commit ? self.commit_transform() : self.cancel_transform();
	self.transform_interaction = {};
	self.refresh_ui();
	return changed;
}

fn bool handle_transform_key(AppState* app, Key key, bool shift)
{
	if (!app.transform_interaction.active) return false;
	if (app.transform_numeric_key(key)) return true;
	switch (key)
	{
		case Key.X:
			app.set_transform_constraint(shift && app.transform_interaction.operation == MOVE_TRANSFORM
				? DragAxis.YZ : DragAxis.X);
		case Key.Y:
			app.set_transform_constraint(shift && app.transform_interaction.operation == MOVE_TRANSFORM
				? DragAxis.XZ : DragAxis.Y);
		case Key.Z:
			app.set_transform_constraint(shift && app.transform_interaction.operation == MOVE_TRANSFORM
				? DragAxis.XY : DragAxis.Z);
		case Key.RETURN:
		case Key.KP_RETURN:
			(void)app.finish_transform_interaction(true);
		case Key.ESCAPE:
			(void)app.finish_transform_interaction(false);
		case Key.G:
		case Key.R:
			return true;
		default:
			return false;
	}
	return true;
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

fn TransformGizmoFrame? Viewport.transform_gizmo_frame(&self, Element* elem)
{
	AppState* app = elem.inherit(AppState)!!;
	TransformInteraction* interaction = &app.transform_interaction;
	bool active = interaction.active && interaction.viewport == self;
	if (interaction.active && !active) return NO_TRANSFORM_GIZMO~;
	// G and R from the keyboard draw nothing: the pointer is the handle, and X/Y/Z
	// hold it to an axis. Only a drag begun on the tool's handles keeps them up.
	if (active && !interaction.held) return NO_TRANSFORM_GIZMO~;
	if (!active && (!transform_tool_claims_pointer(app) || app.transform_tool == SELECT_TOOL))
	{
		return NO_TRANSFORM_GIZMO~;
	}

	bool scaling = active ? interaction.operation == SCALE_TRANSFORM : app.transform_tool == SCALE_TOOL;
	if (scaling && !active && (app.pose_edit_active || (!app.has_mesh() && app.doc.dots.len() == 0)))
	{
		return NO_TRANSFORM_GIZMO~;
	}
	TransformTarget target = active
		? app.transform_transaction.target
		: (scaling ? (TransformTarget){ .kind = MODEL_TARGET } : app.transform_target());
	bool posing = transform_tool_poses(app);
	if (!target.supported() || (!active && !posing && transform_target_locked(app, target))) return NO_TRANSFORM_GIZMO~;
	TransformSpace space = active ? app.transform_transaction.space : app.transform_space;
	TransformOperation operation = active
		? interaction.operation
		: tool_operation(app.transform_tool);
	OrbitCamera camera = active ? interaction.camera : *self.view_camera(elem);
	ProjectTransform model = active ? app.transform_transaction.model_before : app.doc.model_transform;
	Quaternionf basis = quaternion::IDENTITY;
	if (posing)
	{
		// What the pose gesture locks to: G's world axes, R's joint axes.
		if (operation == ROTATE_TRANSFORM)
		{
			if (try Quaternionf axes = app.joint_axes(app.selected, posed: true)) basis = axes;
		}
	}
	else if (space == LOCAL_SPACE)
	{
		basis = target.kind == MODEL_TARGET
			? model.orientation()
			: app.transform_basis(target, space);
	}
	Vec3 pivot;
	if (posing)
	{
		Dot* dot = app.doc.find(app.selected);
		if (!dot) return NO_TRANSFORM_GIZMO~;
		pivot = app.dot_position(*dot);
	}
	else
	{
		pivot = active
			? app.transform_transaction.pivot + (operation == MOVE_TRANSFORM ? interaction.applied_translation : (Vec3){})
			: (scaling ? app.doc.model_transform.location : app.transform_target_pivot(target, app.transform_pivot));
	}
	float aspect = elem.size.y > 0.0f ? elem.size.x / elem.size.y : 1.0f;
	Matrix4f projection = camera.view_projection(aspect);
	if (target.kind != MODEL_TARGET) projection = projection.mul(model.matrix());
	Vec2? projected = project(projection, pivot, elem.size);
	if (catch projected) return NO_TRANSFORM_GIZMO~;

	Vec3 eye = target.kind == MODEL_TARGET ? camera.eye() : model.inverse_point(camera.eye());
	Vec3 forward = target.kind == MODEL_TARGET
		? (camera.target - camera.eye()).normalize()
		: model.inverse_direction((camera.target - camera.eye()).normalize());
	float depth = math::abs((pivot - eye).dot(forward));
	if (depth <= 1.0e-5f || elem.size.y <= 0.0f) return NO_TRANSFORM_GIZMO~;
	float per_pixel = 2.0f * depth * math::tan(math::deg_to_rad(camera.fov) * 0.5f) / elem.size.y;
	float radius = per_pixel * TRANSFORM_RING_RADIUS;

	TransformGizmoFrame frame = {
		.target = target,
		.space = space,
		.operation = operation,
		.pivot = pivot,
		.projected_pivot = projected,
		.radius = radius,
		.projection = projection,
		.size = elem.size,
	};
	for (int component = 0; component < 3; component++)
	{
		Vec3 axis = space == LOCAL_SPACE ? basis.rotate_vec3(AXIS_DIRECTION[component]) : AXIS_DIRECTION[component];
		frame.axes[component] = axis.normalize();
		Vec2? edge = project(projection, pivot + frame.axes[component] * radius, elem.size);
		if (catch edge) continue;
		Vec2 screen = edge - projected;
		if (screen.length() < 2.0f) continue;
		frame.screen_axes[component] = screen.normalize();
		frame.visible_axes[component] = true;
	}
	return frame;
}

faultdef NO_TRANSFORM_GIZMO;

<*
 What a press on the tool's gizmo starts, for the tool that is up.
*>
fn TransformOperation tool_operation(TransformTool tool)
{
	switch (tool)
	{
		case MOVE_TOOL: return MOVE_TRANSFORM;
		case SCALE_TOOL: return SCALE_TRANSFORM;
		default: return ROTATE_TRANSFORM;
	}
}

<*
 How far out the scale ring is drawn: the ring itself while nothing is dragged,
 and the pointer's distance once something is, so it follows the hand.
*>
fn float scale_ring_radius(AppState* app, TransformGizmoFrame* frame) @private
{
	TransformInteraction* interaction = &app.transform_interaction;
	if (!interaction.active || interaction.operation != SCALE_TRANSFORM) return TRANSFORM_RING_RADIUS;
	return math::max((interaction.pointer - frame.projected_pivot).length(), 4.0f);
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

fn TransformGizmoPart Viewport.hit_transform_gizmo(&self, Element* elem, Vec2 pointer)
{
	TransformGizmoFrame? built = self.transform_gizmo_frame(elem);
	if (catch built) return NO_GIZMO_PART;
	TransformGizmoFrame frame = built;

	if (frame.operation == SCALE_TRANSFORM)
	{
		// The ring, or anywhere inside it: there is no axis to choose.
		float out = (pointer - frame.projected_pivot).length();
		return out <= TRANSFORM_RING_RADIUS + TRANSFORM_HIT_WIDTH ? GIZMO_FREE : NO_GIZMO_PART;
	}

	if (frame.operation == MOVE_TRANSFORM)
	{
		int[2][3] planes = { { 0, 1 }, { 1, 2 }, { 0, 2 } };
		TransformGizmoPart[3] parts = { GIZMO_XY, GIZMO_YZ, GIZMO_XZ };
		foreach (usz i, pair : planes)
		{
			if (!frame.visible_axes[pair[0]] || !frame.visible_axes[pair[1]]) continue;
			if ((pointer - plane_handle_center(&frame, pair[0], pair[1])).length() <= TRANSFORM_PLANE_HIT)
			{
				return parts[i];
			}
		}
		// Every arrow meets at the pivot, so near it the nearest arrow is a coin
		// toss — the press that meant "grab this joint" used to lock whichever
		// axis came first. The middle is the free handle instead.
		if ((pointer - frame.projected_pivot).length() <= TRANSFORM_FREE_RADIUS) return GIZMO_FREE;
		float nearest = TRANSFORM_HIT_WIDTH;
		TransformGizmoPart found = NO_GIZMO_PART;
		for (int component = 0; component < 3; component++)
		{
			if (!frame.visible_axes[component]) continue;
			Vec2 start = frame.projected_pivot + frame.screen_axes[component] * TRANSFORM_FREE_RADIUS;
			Vec2 end = frame.projected_pivot + frame.screen_axes[component] * TRANSFORM_AXIS_LENGTH;
			float distance = point_segment_distance(pointer, start, end);
			if (distance <= nearest)
			{
				nearest = distance;
				found = (TransformGizmoPart)(component + 1);
			}
		}
		return found;
	}

	float nearest = TRANSFORM_HIT_WIDTH;
	TransformGizmoPart found = NO_GIZMO_PART;
	for (int component = 0; component < 3; component++)
	{
		int first = (component + 1) % 3;
		int second = (component + 2) % 3;
		Vec2 previous;
		bool had_previous = false;
		for (usz step = 0; step <= TRANSFORM_RING_STEPS; step++)
		{
			float angle = (float)math::TAU * (float)step / (float)TRANSFORM_RING_STEPS;
			Vec3 point = frame.pivot + (frame.axes[first] * math::cos(angle)
				+ frame.axes[second] * math::sin(angle)) * frame.radius;
			Vec2? projected = project(frame.projection, point, frame.size);
			if (catch projected) { had_previous = false; continue; }
			if (had_previous)
			{
				float distance = point_segment_distance(pointer, previous, projected);
				if (distance <= nearest)
				{
					nearest = distance;
					found = (TransformGizmoPart)(component + 1);
				}
			}
			previous = projected;
			had_previous = true;
		}
	}
	return found;
}

fn Color transform_axis_color(int component) @private
{
	return ((DragAxis)(component + 1)).color();
}

fn bool transform_axis_active(AppState* app, int component) @private
{
	DragAxis axis = transform_active_axis(app);
	return axis.is_direction() && axis.component() == component;
}

fn void paint_plane_handle(Painter* painter, TransformGizmoFrame* frame,
	int first, int second, Color color, bool active) @private
{
	if (!frame.visible_axes[first] || !frame.visible_axes[second]) return;
	Vec2 a0 = frame.screen_axes[first] * TRANSFORM_PLANE_NEAR;
	Vec2 a1 = frame.screen_axes[first] * TRANSFORM_PLANE_FAR;
	Vec2 b0 = frame.screen_axes[second] * TRANSFORM_PLANE_NEAR;
	Vec2 b1 = frame.screen_axes[second] * TRANSFORM_PLANE_FAR;
	Vec2 p0 = frame.projected_pivot + a0 + b0;
	Vec2 p1 = frame.projected_pivot + a1 + b0;
	Vec2 p2 = frame.projected_pivot + a1 + b1;
	Vec2 p3 = frame.projected_pivot + a0 + b1;
	float width = active ? TRANSFORM_ACTIVE_WIDTH : TRANSFORM_LINE_WIDTH;
	painter.line(p0, p1, width, color);
	painter.line(p1, p2, width, color);
	painter.line(p2, p3, width, color);
	painter.line(p3, p0, width, color);
}

fn void Viewport.paint_transform_gizmo(&self, Element* elem, Painter* painter)
{
	AppState* app = elem.inherit(AppState)!!;
	TransformGizmoFrame? built = self.transform_gizmo_frame(elem);
	if (catch built) return;
	TransformGizmoFrame frame = built;
	DragAxis active_axis = transform_active_axis(app);

	if (frame.operation == SCALE_TRANSFORM)
	{
		// One ring, in no axis's colour, with a square handle on each diagonal —
		// the resize handles of a box, which is what this does to the model.
		bool dragging = app.transform_interaction.active;
		float radius = scale_ring_radius(app, &frame);
		Color ink = TEXT.dim(dragging ? 0.95f : 0.7f);
		float width = dragging ? TRANSFORM_ACTIVE_WIDTH : TRANSFORM_LINE_WIDTH;
		painter.circle(frame.projected_pivot, radius, { .border_color = ink, .border_width = width });
		float corner = radius * 0.7071f;
		float half = 3.5f;
		Vec2[4] at = { { corner, corner }, { -corner, corner }, { corner, -corner }, { -corner, -corner } };
		foreach (offset : at)
		{
			Vec2 c = frame.projected_pivot + offset;
			painter.line(c + (Vec2){ -half, -half }, c + (Vec2){ half, -half }, width, ink);
			painter.line(c + (Vec2){ half, -half }, c + (Vec2){ half, half }, width, ink);
			painter.line(c + (Vec2){ half, half }, c + (Vec2){ -half, half }, width, ink);
			painter.line(c + (Vec2){ -half, half }, c + (Vec2){ -half, -half }, width, ink);
		}
		painter.circle(frame.projected_pivot, 3.0f, { .color = TEXT });
		return;
	}

	if (frame.operation == MOVE_TRANSFORM)
	{
		paint_plane_handle(painter, &frame, 0, 1, AXIS_Z.dim(0.72f), active_axis == DragAxis.XY);
		paint_plane_handle(painter, &frame, 1, 2, AXIS_X.dim(0.72f), active_axis == DragAxis.YZ);
		paint_plane_handle(painter, &frame, 0, 2, AXIS_Y.dim(0.72f), active_axis == DragAxis.XZ);
		for (int component = 0; component < 3; component++)
		{
			if (!frame.visible_axes[component]) continue;
			Vec2 direction = frame.screen_axes[component];
			Vec2 end = frame.projected_pivot + direction * TRANSFORM_AXIS_LENGTH;
			Vec2 side = { -direction.y, direction.x };
			Color color = transform_axis_color(component);
			float width = transform_axis_active(app, component) ? TRANSFORM_ACTIVE_WIDTH : TRANSFORM_LINE_WIDTH;
			painter.line(frame.projected_pivot + direction * TRANSFORM_FREE_RADIUS, end, width, color);
			painter.line(end, end - direction * TRANSFORM_ARROW + side * (TRANSFORM_ARROW * 0.55f), width, color);
			painter.line(end, end - direction * TRANSFORM_ARROW - side * (TRANSFORM_ARROW * 0.55f), width, color);
		}
	}
	else
	{
		for (int component = 0; component < 3; component++)
		{
			int first = (component + 1) % 3;
			int second = (component + 2) % 3;
			Color color = transform_axis_color(component);
			float width = transform_axis_active(app, component) ? TRANSFORM_ACTIVE_WIDTH : TRANSFORM_LINE_WIDTH;
			Vec2 previous;
			bool had_previous = false;
			for (usz step = 0; step <= TRANSFORM_RING_STEPS; step++)
			{
				float angle = (float)math::TAU * (float)step / (float)TRANSFORM_RING_STEPS;
				Vec3 point = frame.pivot + (frame.axes[first] * math::cos(angle)
					+ frame.axes[second] * math::sin(angle)) * frame.radius;
				Vec2? projected = project(frame.projection, point, frame.size);
				if (catch projected) { had_previous = false; continue; }
				if (had_previous) painter.line(previous, projected, width, color);
				previous = projected;
				had_previous = true;
			}
		}
	}
	// The free handle: grab inside this ring to move without an axis.
	if (frame.operation == MOVE_TRANSFORM)
	{
		bool free = (app.transform_interaction.active || app.drag.dot != 0) && active_axis == DragAxis.FREE;
		painter.circle(frame.projected_pivot, TRANSFORM_FREE_RADIUS, {
			.border_color = TEXT.dim(free ? 0.9f : 0.45f),
			.border_width = free ? TRANSFORM_ACTIVE_WIDTH * 0.5f : 1.0f,
		});
	}
	painter.circle(frame.projected_pivot, 3.0f, { .color = TEXT });
}

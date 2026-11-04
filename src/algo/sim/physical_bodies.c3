<*
 Target-derived rigid bodies for reusable anatomical constraints.

 Joint limits transfer between rigs as angles and frame intent; collision
 geometry does not. This file is the target-side boundary: take the actual
 binding that will be exported, collect each constrained body's weighted
 surface region, reduce it to a bounded support cloud and write a small convex
 hull in the joint's local rest frame.

 The hull meshes are glTF mesh resources referenced by
 `KHR_physics_rigid_bodies.geometry.mesh`. They are deliberately not scene
 nodes, so collision bytes do not become visible duplicate geometry. A runtime
 may still rebuild its preferred convex representation from those vertices.
*>
module crig;

import rig;
import gltf;
import collision;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::core::string;
import std::collections::list;

faultdef PHYSICAL_BODY_INSUFFICIENT_GEOMETRY;

// A four-influence skin always has one share of at least 0.25. Taking nearby
// 0.20 shares too leaves overlap across a bending seam, while rejecting the
// tiny long-distance weights that would pull a hand hull across the torso.
const float PHYSICAL_BODY_WEIGHT_FLOOR = 0.20f;

// Six cardinal supports plus this deterministic spherical set bound each hull
// to at most 54 source points. A convex polytope over that many points is small
// enough to export per finger segment without growing a character by megabytes.
const usz PHYSICAL_BODY_SUPPORT_DIRECTIONS = 48;
const usz PHYSICAL_BODY_MAX_VERTICES = PHYSICAL_BODY_SUPPORT_DIRECTIONS + 6;

// glTF units are metres. Density near water gives human-scale models useful
// kilogram masses, while a minimum keeps a valid fingertip from becoming a
// numerically weightless body.
const float PHYSICAL_BODY_DENSITY = 1000.0f;
const float PHYSICAL_BODY_MIN_MASS = 0.001f;

// Weighted regions meet at the rendered surface but a reduced support cloud is
// inscribed in it. One millimetre on a two-metre rig, or one percent of this
// body's own extent, restores a small conservative margin.
const float PHYSICAL_BODY_RIG_MARGIN = 0.0005f;
const float PHYSICAL_BODY_LOCAL_MARGIN = 0.01f;

alias PhysicalVec3List = List{Vec3};
alias PhysicalUszList = List{usz};

<*
 One generated body. Positions are already in the owning joint node's local
 rest frame, and indices are a closed outward-facing triangle hull.
*>
struct TargetPhysicalBody
{
	usz joint;
	Vec3[] positions;
	uint[] indices;
	float volume;
	float mass;
	bool branch;
	bool terminal;
}

fn void TargetPhysicalBody.free(&self, Allocator allocator)
{
	if (self.positions.len > 0) alloc::free(allocator, self.positions);
	if (self.indices.len > 0) alloc::free(allocator, self.indices);
	*self = {};
}

<*
 The complete result and its honest omissions.

 `requested` counts distinct parent/child bodies used by exact constraint rows.
 `skipped` counts requested bodies whose weighted points enclosed no useful
 volume. Branch and terminal bones obey the same rule: use only their own
 weighted region and omit it when that region is insufficient. Neither borrows
 a child's vertices nor invents an extrapolated capsule.
*>
struct TargetPhysicalBodies
{
	TargetPhysicalBody[] bodies;
	usz requested;
	usz skipped;
	usz source_points;
	usz hull_vertices;
	usz hull_triangles;
	usz payload_bytes;
}

fn bool TargetPhysicalBodies.complete(&self) => self.skipped == 0;

fn void TargetPhysicalBodies.free(&self, Allocator allocator)
{
	foreach (&body : self.bodies) body.free(allocator);
	if (self.bodies.len > 0) alloc::free(allocator, self.bodies);
	*self = {};
}

<*
 What was attached to a glTF builder. Kept separate from the owned hull set so
 normal export can free all temporary geometry before reporting a few numbers.
*>
struct PhysicalBodyWriteReport
{
	usz requested;
	usz written;
	usz skipped;
	usz preserved_jiggle;
	usz hull_vertices;
	usz hull_triangles;
	usz payload_bytes;
}

fn bool PhysicalBodyWriteReport.complete(self)
	=> self.skipped == 0 && self.preserved_jiggle == 0;

fn bool constraint_body_row_usable(rig::Skeleton* skeleton, usz joint,
	JointConstraint constrained) @private
{
	if (constrained.status != EXACT) return false;
	if (joint >= skeleton.len()) return false;
	int parent = skeleton.parents[joint];
	if (parent < 0 || (usz)parent >= skeleton.len()) return false;
	if (!constraint_axes_valid(constrained)) return false;
	if (constrained.frame_intent.has_adjustment()
		&& !constraint_quaternion_valid(constrained.frame_adjustment)) return false;
	return joint_limit_frame_by_index(skeleton, joint,
		constrained.primary_child).usable();
}

fn bool[] requested_physical_bodies(
	Allocator allocator,
	rig::Skeleton* skeleton,
	ConstraintRig constraints,
	usz* count) @private
{
	usz joints = skeleton.len();
	bool[] requested = alloc::new_array(allocator, bool, (sz)joints);
	usz rows = constraints.joints.len < joints ? constraints.joints.len : joints;
	for (usz joint = 0; joint < rows; joint++)
	{
		JointConstraint constrained = constraints.joints[joint];
		if (!constraint_body_row_usable(skeleton, joint, constrained)) continue;

		usz parent = (usz)skeleton.parents[joint];
		if (!requested[parent]) { requested[parent] = true; (*count)++; }
		if (!requested[joint]) { requested[joint] = true; (*count)++; }
	}
	return requested;
}

fn bool physical_joint_is_branch(rig::Skeleton* skeleton, usz joint) @private
{
	usz children = 0;
	foreach (parent : skeleton.parents)
	{
		if (parent == (int)joint && ++children > 1) return true;
	}
	return false;
}

fn bool physical_joint_is_terminal(rig::Skeleton* skeleton, usz joint) @private
{
	foreach (parent : skeleton.parents) if (parent == (int)joint) return false;
	return true;
}

fn bool binding_vertex_belongs(gltf::SkinBinding binding, usz vertex,
	usz joint) @private
{
	usz slots = (usz)binding.slots;
	usz base = vertex * slots;
	for (usz slot = 0; slot < slots; slot++)
	{
		if (binding.weights[base + slot] < PHYSICAL_BODY_WEIGHT_FLOOR) continue;
		if ((usz)binding.joints[base + slot] == joint) return true;
	}
	return false;
}

fn void add_support_direction(
	Vec3[] points,
	Vec3 direction,
	PhysicalUszList* chosen,
	PhysicalVec3List* support) @private
{
	if (points.len == 0 || direction.length_sq() == 0.0f) return;
	usz best = 0;
	float farthest = points[0].dot(direction);
	for (usz point = 1; point < points.len; point++)
	{
		float distance = points[point].dot(direction);
		if (distance <= farthest) continue;
		best = point;
		farthest = distance;
	}
	foreach (held : *chosen) if (held == best) return;
	chosen.push(best);
	support.push(points[best]);
}

<*
 Reduce an arbitrary weighted region to deterministic extremal samples.

 The directions are evaluated in the joint's local frame, so rotating the same
 target rig in model space does not change which detail its body keeps. Cardinal
 directions protect thin fingers and flat palms; the spherical directions keep
 diagonals on less regular forms.
*>
fn Vec3[] physical_support_cloud(Allocator allocator, Vec3[] points) @private
{
	if (points.len <= PHYSICAL_BODY_MAX_VERTICES)
	{
		Vec3[] copied = alloc::new_array(allocator, Vec3, (sz)points.len);
		foreach (usz i, point : points) copied[i] = point;
		return copied;
	}

	PhysicalUszList chosen;
	PhysicalVec3List support;
	chosen.init(allocator, (sz)PHYSICAL_BODY_MAX_VERTICES);
	support.init(allocator, (sz)PHYSICAL_BODY_MAX_VERTICES);
	defer
	{
		chosen.free();
		support.free();
	}

	Vec3[6] cardinal = {
		{ 1, 0, 0 }, { -1, 0, 0 },
		{ 0, 1, 0 }, { 0, -1, 0 },
		{ 0, 0, 1 }, { 0, 0, -1 },
	};
	foreach (direction : cardinal) add_support_direction(points, direction,
		&chosen, &support);

	const float GOLDEN_ANGLE = 2.39996323f;
	for (usz i = 0; i < PHYSICAL_BODY_SUPPORT_DIRECTIONS; i++)
	{
		float z = 1.0f - 2.0f * ((float)i + 0.5f)
			/ (float)PHYSICAL_BODY_SUPPORT_DIRECTIONS;
		float radius = math::sqrt(math::max(0.0f, 1.0f - z * z));
		float angle = GOLDEN_ANGLE * (float)i;
		Vec3 direction = {
			radius * math::cos(angle),
			radius * math::sin(angle),
			z,
		};
		add_support_direction(points, direction, &chosen, &support);
	}

	return support.to_array(allocator);
}

fn float physical_hull_extent(collision::Mesh* hull) @private
{
	if (hull.vertices.len() == 0) return 0.0f;
	Vec3 low = hull.vertices[0];
	Vec3 high = low;
	foreach (point : hull.vertices)
	{
		for (usz axis = 0; axis < 3; axis++)
		{
			low[axis] = math::min(low[axis], point[axis]);
			high[axis] = math::max(high[axis], point[axis]);
		}
	}
	return (high - low).length();
}

fn collision::Mesh physical_hull_with_margin(
	Allocator allocator,
	Vec3[] support,
	float rig_scale) @private
{
	collision::Mesh initial = collision::quickhull(support, allocator);
	if (initial.triangles.len() == 0) return initial;

	Vec3 center = {};
	foreach (point : initial.vertices) center += point;
	center /= (float)initial.vertices.len();
	float margin = math::max(rig_scale * PHYSICAL_BODY_RIG_MARGIN,
		physical_hull_extent(&initial) * PHYSICAL_BODY_LOCAL_MARGIN);
	if (margin <= 0.0f) return initial;

	Vec3[] expanded = alloc::new_array(allocator, Vec3,
		initial.vertices.len());
	defer alloc::free(allocator, expanded);
	foreach (usz i, point : initial.vertices)
	{
		Vec3 away = point - center;
		expanded[i] = away.length_sq() > 1.0e-18f
			? point + away.normalize() * margin
			: point;
	}
	initial.free();
	return collision::quickhull(expanded, allocator);
}

fn TargetPhysicalBody? build_target_physical_body(
	Allocator allocator,
	rig::TriMesh mesh,
	rig::Skeleton* skeleton,
	gltf::SkinBinding binding,
	usz joint,
	Quaternionf[] rest,
	usz* source_points) @private
{
	PhysicalVec3List cloud;
	cloud.init(allocator);
	defer cloud.free();

	Quaternionf world = joint < rest.len
		? rest[joint].normalize()
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf into_joint = world.conjugate();
	foreach (usz vertex, position : mesh.positions)
	{
		if (!binding_vertex_belongs(binding, vertex, joint)) continue;
		cloud.push(into_joint * (position - skeleton.joints[joint]));
	}
	*source_points += (usz)cloud.len();
	if (cloud.len() < 4) return PHYSICAL_BODY_INSUFFICIENT_GEOMETRY~;

	Vec3[] support = physical_support_cloud(allocator, cloud.array_view());
	defer if (support.len > 0) alloc::free(allocator, support);
	if (support.len < 4) return PHYSICAL_BODY_INSUFFICIENT_GEOMETRY~;

	float rig_scale = skeleton.height();
	if (rig_scale <= 0.0f) rig_scale = mesh.bounds().extent().length();
	if (rig_scale <= 0.0f) rig_scale = 1.0f;
	collision::Mesh hull = physical_hull_with_margin(allocator, support, rig_scale);
	defer hull.free();
	if (hull.vertices.len() < 4 || hull.triangles.len() < 4)
	{
		return PHYSICAL_BODY_INSUFFICIENT_GEOMETRY~;
	}

	float volume = (float)hull.get_volume();
	float volume_floor = rig_scale * rig_scale * rig_scale * 1.0e-12f;
	if (!math::is_finite(volume) || volume <= volume_floor)
	{
		return PHYSICAL_BODY_INSUFFICIENT_GEOMETRY~;
	}

	Vec3[] positions = alloc::new_array(allocator, Vec3,
		(sz)hull.vertices.len());
	foreach (usz i, point : hull.vertices) positions[i] = point;
	uint[] indices = alloc::new_array(allocator, uint,
		(sz)(hull.triangles.len() * 3));
	foreach (usz i, triangle : hull.triangles)
	{
		indices[i * 3] = triangle[0];
		indices[i * 3 + 1] = triangle[1];
		indices[i * 3 + 2] = triangle[2];
	}

	return {
		.joint = joint,
		.positions = positions,
		.indices = indices,
		.volume = volume,
		.mass = math::max(PHYSICAL_BODY_MIN_MASS,
			volume * PHYSICAL_BODY_DENSITY),
		.branch = physical_joint_is_branch(skeleton, joint),
		.terminal = physical_joint_is_terminal(skeleton, joint),
	};
}

<*
 Build every target body an exact anatomical constraint needs.

 The binding is the sparsified binding written to the GLB, not a second bind.
 That keeps collision ownership aligned with what actually deforms the mesh.
*>
fn TargetPhysicalBodies target_physical_bodies(
	Allocator allocator,
	rig::TriMesh mesh,
	rig::Skeleton* skeleton,
	gltf::SkinBinding binding,
	ConstraintRig constraints,
	Quaternionf[] rest = {})
{
	TargetPhysicalBodies out = {};
	usz joints = skeleton.len();
	if (joints == 0 || mesh.positions.len == 0
		|| binding.vertices != mesh.positions.len || binding.slots == 0) return out;

	bool[] requested = requested_physical_bodies(allocator, skeleton, constraints,
		&out.requested);
	defer if (requested.len > 0) alloc::free(allocator, requested);
	if (out.requested == 0) return out;

	TargetPhysicalBody[] bodies = alloc::new_array(allocator,
		TargetPhysicalBody, (sz)out.requested);
	usz kept = 0;
	for (usz joint = 0; joint < joints; joint++)
	{
		if (!requested[joint]) continue;
		TargetPhysicalBody? built = build_target_physical_body(allocator, mesh,
			skeleton, binding, joint, rest, &out.source_points);
		if (try built)
		{
			bodies[kept++] = built;
			out.hull_vertices += built.positions.len;
			out.hull_triangles += built.indices.len / 3;
			// add_indices uses 16-bit values for these deliberately bounded hulls.
			out.payload_bytes += built.positions.len * Vec3::size
				+ built.indices.len * ushort::size;
		}
		else
		{
			out.skipped++;
		}
	}

	if (kept > 0)
	{
		out.bodies = bodies[:kept];
	}
	else
	{
		alloc::free(allocator, bodies);
	}
	return out;
}

fn bool target_body_exists(TargetPhysicalBodies* bodies, usz joint) @private
{
	foreach (body : bodies.bodies) if (body.joint == joint) return true;
	return false;
}

// A node can hold only one collider. Preserve an existing secondary-motion
// body instead of replacing its authored sphere, damping and gravity with a
// generated anatomical hull. The chain-level replacement work can later merge
// those two roles deliberately; P5 must not destroy the older one by accident.
fn bool jiggle_body_exists(RigPhysics physics, usz joint) @private
{
	foreach (spec : physics.joints)
	{
		if (spec.joint == joint && !spec.params.inert()) return true;
	}
	return false;
}

<*
 Add generated hull meshes, colliders and masses to existing skeleton nodes.

 A body whose parent body was omitted becomes kinematic, anchoring that physical
 component rather than leaving a disconnected dynamic island to fall away.
 Every other generated body is dynamic. Constraint attachment nodes are added
 afterwards by `write_rig_constraints`, whose default `enableCollision=false`
 is the adjacent-body collision rule.

 A legacy jiggle body already occupying a requested node is preserved and
 counted separately. glTF nodes accept one collider, so overwriting it would
 silently change existing secondary motion. Its attachment constraints are
 still written and it remains a valid body in the graph.
*>
fn PhysicalBodyWriteReport write_target_physical_bodies(
	Allocator allocator,
	gltf::GltfBuilder* builder,
	rig::TriMesh mesh,
	rig::Skeleton* skeleton,
	String[] names,
	gltf::SkinBinding binding,
	ConstraintRig constraints,
	uint[] joint_nodes = {},
	Quaternionf[] rest = {},
	RigPhysics existing_physics = {})
{
	TargetPhysicalBodies bodies = target_physical_bodies(allocator, mesh,
		skeleton, binding, constraints, rest);
	defer bodies.free(allocator);

	PhysicalBodyWriteReport report = {
		.requested = bodies.requested,
		.skipped = bodies.skipped,
	};

	foreach (body : bodies.bodies)
	{
		if (jiggle_body_exists(existing_physics, body.joint))
		{
			report.preserved_jiggle++;
			continue;
		}

		String label = string::format(allocator, "%s.physics-hull",
			body.joint < names.len && names[body.joint].len > 0
				? names[body.joint]
				: "joint");
		uint hull = builder.add_mesh(label);
		label.free(allocator);
		gltf::WriteAttribute[1] attributes = {
			{ .name = "POSITION",
				.accessor = builder.add_positions(body.positions) },
		};
		builder.add_primitive(hull, attributes[..],
			indices: (int)builder.add_indices(body.indices));

		uint node = body.joint < joint_nodes.len
			? joint_nodes[body.joint]
			: (uint)body.joint;
		builder.add_collider(node, {
			.convex_hull = true,
			.shape = -1,
			.node = -1,
			.mesh = (int)hull,
			.material = -1,
			.collision_filter = -1,
			.base_node = -1,
		});

		int parent = skeleton.parents[body.joint];
		bool anchored = parent < 0
			|| !target_body_exists(&bodies, (usz)parent);
		builder.add_motion(node, {
			.is_kinematic = anchored,
			.mass = body.mass,
			.gravity_factor = 1.0f,
			.linear_dampening = 0.0f,
			.angular_dampening = 0.0f,
		});

		report.written++;
		report.hull_vertices += body.positions.len;
		report.hull_triangles += body.indices.len / 3;
		report.payload_bytes += body.positions.len * Vec3::size
			+ body.indices.len * ushort::size;
	}
	return report;
}

<*
 Reusable anatomical limits as `KHR_physics_rigid_bodies` joints.

 This writer is deliberately separate from `physics_gltf.c3`. The latter turns
 selected bones into dynamic secondary motion; this file writes the stateless
 parent/child constraints a fitted rig is expected to retain. Target-derived
 collision bodies are added separately by `physical_bodies.c3`, keeping reusable
 constraint intent independent from fitted target geometry.

 A KHR joint lives on an attachment node parented to one body and names another
 attachment node parented to the other. Both attachments are placed at the
 child skeleton joint with the same world rotation. That shared frame is what
 makes axis 0/1/2 mean crig's bone-local X/Y/Z instead of either body's origin
 or node convention.
*>
module crig;

import rig;
import gltf;
import gltf_edit;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::core::string;
import std::collections::list;
import std::collections::object;
import std::encoding::json;

<*
 What the KHR writer could state exactly.

 `skipped` includes stale source rows, explicitly unsupported rows, root joints
 with no adjacent parent body and malformed rows. Export keeps going so one bad
 fork cannot discard every reviewed knee or finger limit.
*>
struct ConstraintWriteReport
{
	usz written;
	usz skipped;
}

fn bool ConstraintWriteReport.complete(self) => self.skipped == 0;

<*
 Add every exact parent/child constraint to a builder whose skeleton nodes
 already exist.

 One three-axis zero-range linear limit keeps the attachments coincident. The
 angular limits are intentionally three separate one-axis rows: KHR reads a
 multi-axis angular row as a cone, which is not crig's independent X/Y/Z table.
 A disabled crig axis is a zero-width angular range at its authored locked
 value, not necessarily at zero.

 `rest` contains each joint node's model-space rest rotation. Empty means the
 unrotated-node convention used by animation packs; `gltf::bone_rotations` is
 what the rigged exporter supplies. Attachment transforms are converted through
 those rotations so both file conventions produce the same model-space pivot.

 This function does not invent mass or collision geometry. P5 puts
 target-derived bodies on the attachment parents before this is called; keeping
 body generation separate is what prevents a reusable template from exporting
 source-sized shapes onto a differently proportioned target.
*>
fn ConstraintWriteReport write_rig_constraints(
	Allocator allocator,
	gltf::GltfBuilder* builder,
	rig::Skeleton* skeleton,
	String[] names,
	ConstraintRig constraints,
	uint[] joint_nodes = {},
	Quaternionf[] rest = {})
{
	ConstraintWriteReport report = { .skipped = constraints.skipped };
	usz joints = skeleton.len();
	usz rows = constraints.joints.len < joints ? constraints.joints.len : joints;
	DString provenance = dstring::new(allocator);
	defer provenance.free();
	provenance.append_char('[');
	usz provenance_rows = 0;

	for (usz joint = 0; joint < rows; joint++)
	{
		JointConstraint constrained = constraints.joints[joint];
		if (constrained.status == FREE) continue;
		if (constrained.status != EXACT)
		{
			report.skipped++;
			continue;
		}

		int parent = skeleton.parents[joint];
		Quaternionf world_frame;
		if (parent < 0 || (usz)parent >= joints
			|| !constraint_world_frame(skeleton, joint, constrained, &world_frame))
		{
			report.skipped++;
			continue;
		}

		gltf::PhysicsJoint settings;
		settings.angular_limits.init(allocator);
		settings.linear_limits.init(allocator);
		settings.drives.init(allocator);
		defer settings.free();

		settings.linear_limits.push({
			.axes = { 1, 1, 1 },
			.min = 0.0f,
			.max = 0.0f,
		});
		foreach (usz axis, limit : constrained.axes)
		{
			Vec3 mask = {};
			mask[axis] = 1.0f;
			settings.angular_limits.push({
				.axes = mask,
				.min = limit.allowed ? limit.minimum : limit.locked,
				.max = limit.allowed ? limit.maximum : limit.locked,
			});
		}
		uint settings_index = builder.add_physics_joint_settings(settings);

		Vec3 pivot = skeleton.joints[joint];
		usz parent_joint = (usz)parent;
		Quaternionf parent_world = parent_joint < rest.len
			? rest[parent_joint].normalize()
			: (Quaternionf)quaternion::IDENTITY;
		Quaternionf child_world = joint < rest.len
			? rest[joint].normalize()
			: (Quaternionf)quaternion::IDENTITY;

		Quaternionf from_parent = parent_world.invert();
		Quaternionf from_child = child_world.invert();
		String parent_label = constraint_node_name(allocator, names, joint, "parent");
		String child_label = constraint_node_name(allocator, names, joint, "child");
		uint parent_attachment = builder.add_node(parent_label,
			translation: from_parent * (pivot - skeleton.joints[parent_joint]),
			rotation: from_parent.mul(world_frame).normalize());
		uint child_attachment = builder.add_node(child_label,
			translation: from_child * (pivot - skeleton.joints[joint]),
			rotation: from_child.mul(world_frame).normalize());
		parent_label.free(allocator);
		child_label.free(allocator);

		uint parent_node = parent_joint < joint_nodes.len
			? joint_nodes[parent_joint]
			: (uint)parent_joint;
		uint child_node = joint < joint_nodes.len ? joint_nodes[joint] : (uint)joint;
		builder.add_child(parent_node, parent_attachment);
		builder.add_child(child_node, child_attachment);
		builder.add_node_joint(child_attachment, parent_attachment, settings_index);
		append_constraint_provenance(&provenance, &provenance_rows, constrained,
			child_node, constrained.primary_child >= 0
				? (int)constraint_joint_node(joint_nodes, (usz)constrained.primary_child)
				: -1);
		report.written++;
	}

	// A short dense table cannot make the missing rows meaningful. It is not a
	// normal `constraint_rig_of` result, but counting it makes hand-built/imported
	// data fail visibly instead of looking complete.
	if (constraints.joints.len > 0 && constraints.joints.len < joints)
	{
		report.skipped += joints - constraints.joints.len;
	}

	// Foreign graphs cannot drive crig's editor, but a pack save can still carry
	// them forward without turning cones into hinges or discarding drives.
	foreach (usz foreign_index, foreign : constraints.foreign)
	{
		if (!write_foreign_constraint(allocator, builder, skeleton, names, foreign,
			joint_nodes, rest, foreign_index))
		{
			report.skipped++;
			continue;
		}
		report.written++;
	}

	if (provenance_rows > 0)
	{
		provenance.append_char(']');
		builder.set_extra(PACK_KEY_CONSTRAINT_FRAMES, provenance.str_view());
	}
	return report;
}

fn uint constraint_joint_node(uint[] joint_nodes, usz joint) @local
	=> joint < joint_nodes.len ? joint_nodes[joint] : (uint)joint;

<*
 The rest/model-space frame a row's KHR attachments are written in: the joint's
 derived bone frame, turned by the row's adjustment when it carries one.

 Shared by the two writers — the exporter's, over a builder, and the in-place
 save's, over the file's own text — so a limit reads back the same from a file
 whichever wrote it.

 @return `False for a row that cannot be written: invalid axes, an adjustment that is no rotation, or a bone the frame rule cannot derive.`
*>
fn bool constraint_world_frame(
	rig::Skeleton* skeleton,
	usz joint,
	JointConstraint constrained,
	Quaternionf* out)
{
	if (!constraint_axes_valid(constrained)) return false;
	JointLimitFrame frame = joint_limit_frame_by_index(skeleton, joint, constrained.primary_child);
	if (!frame.usable()) return false;
	Quaternionf world_frame = frame.rotation;
	if (constrained.frame_intent.has_adjustment())
	{
		if (!constraint_quaternion_valid(constrained.frame_adjustment)) return false;
		world_frame = world_frame.mul(constrained.frame_adjustment).normalize();
	}
	*out = world_frame;
	return true;
}

<*
 The intent's spelling in a file's `constraintFrames` provenance.
*>
fn String constraint_intent_name(ConstraintFrameIntent intent)
{
	switch (intent)
	{
		case AUTOMATIC: return "automatic";
		case PRIMARY_CHILD: return "primary_child";
		case ADJUSTED_AUTOMATIC: return "adjusted_automatic";
		case ADJUSTED_PRIMARY_CHILD: return "adjusted_primary_child";
	}
}

<*
 The KHR rows above are the interoperable constraint. This compact root extra
 preserves only editor information KHR cannot state: parked ranges on a locked
 axis and the child/adjustment used to rebuild a fork's frame on another rig.
 Every field is checked against the KHR graph on read, so stale metadata never
 overrides what the physical file actually says.
*>
fn void append_constraint_provenance(
	DString* out,
	usz* written,
	JointConstraint constrained,
	uint joint_node,
	int primary_node) @local
{
	if ((*written)++ > 0) out.append_char(',');
	gltf_edit::ReskinLimitAxis[3] axes;
	foreach (usz axis, limit : constrained.axes)
	{
		axes[axis] = { limit.allowed, limit.minimum, limit.maximum, limit.locked };
	}
	gltf_edit::write_constraint_provenance(out, joint_node, constraint_intent_name(constrained.frame_intent),
		primary_node, constrained.frame_adjustment, axes);
}

fn bool write_foreign_constraint(
	Allocator allocator,
	gltf::GltfBuilder* builder,
	rig::Skeleton* skeleton,
	String[] names,
	ForeignConstraint foreign,
	uint[] joint_nodes,
	Quaternionf[] rest,
	usz ordinal) @local
{
	usz joints = skeleton.len();
	if (foreign.attachment_joint >= joints || foreign.connected_joint >= joints) return false;
	if (!constraint_quaternion_valid(foreign.attachment_rotation)
		|| !constraint_quaternion_valid(foreign.connected_rotation)) return false;

	gltf::PhysicsJoint settings;
	settings.angular_limits.init(allocator);
	settings.linear_limits.init(allocator);
	settings.drives.init(allocator);
	defer settings.free();
	foreach (limit : foreign.angular_limits) settings.angular_limits.push(limit);
	foreach (limit : foreign.linear_limits) settings.linear_limits.push(limit);
	foreach (drive : foreign.drives) settings.drives.push(drive);
	uint settings_index = builder.add_physics_joint_settings(settings);

	usz a_joint = foreign.attachment_joint;
	usz b_joint = foreign.connected_joint;
	Quaternionf a_world = a_joint < rest.len ? rest[a_joint].normalize()
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf b_world = b_joint < rest.len ? rest[b_joint].normalize()
		: (Quaternionf)quaternion::IDENTITY;
	Quaternionf from_a = a_world.invert();
	Quaternionf from_b = b_world.invert();
	String a_label = constraint_foreign_node_name(allocator, names, a_joint, ordinal, "attachment");
	String b_label = constraint_foreign_node_name(allocator, names, a_joint, ordinal, "connected");
	uint attachment = builder.add_node(a_label,
		translation: from_a * (foreign.attachment_position - skeleton.joints[a_joint]),
		rotation: from_a.mul(foreign.attachment_rotation).normalize());
	uint connected = builder.add_node(b_label,
		translation: from_b * (foreign.connected_position - skeleton.joints[b_joint]),
		rotation: from_b.mul(foreign.connected_rotation).normalize());
	a_label.free(allocator);
	b_label.free(allocator);

	builder.add_child(constraint_joint_node(joint_nodes, a_joint), attachment);
	builder.add_child(constraint_joint_node(joint_nodes, b_joint), connected);
	builder.add_node_joint(attachment, connected, settings_index, foreign.enable_collision);
	return true;
}

fn String constraint_foreign_node_name(
	Allocator allocator,
	String[] names,
	usz joint,
	usz ordinal,
	String side) @local
{
	String label = joint < names.len && names[joint].len > 0 ? names[joint] : "joint";
	return string::format(allocator, "%s.constraint.foreign.%d.%s", label, ordinal, side);
}

fn bool constraint_axes_valid(JointConstraint constrained) @private
{
	foreach (axis : constrained.axes) if (!axis.valid()) return false;
	return true;
}

fn bool constraint_quaternion_valid(Quaternionf rotation) @private
{
	float[<4>] q = rotation.v;
	return math::is_finite(q.x) && math::is_finite(q.y)
		&& math::is_finite(q.z) && math::is_finite(q.w)
		&& q.dot(q) > 1.0e-12f;
}

fn String constraint_node_name(
	Allocator allocator,
	String[] names,
	usz joint,
	String side) @local
{
	String label = joint < names.len && names[joint].len > 0 ? names[joint] : "joint";
	return string::format(allocator, "%s.constraint.%s", label, side);
}

<*
 What the KHR reader found. Counts are per joint graph rather than per row: one
 cone with a drive is one foreign graph and increments both feature counters.
 `skipped` is reserved for a joint whose endpoints cannot be associated with
 this skeleton at all, so it could not even be retained for pass-through.
*>
struct ConstraintReadReport
{
	usz exact;
	usz foreign;
	usz cones;
	usz drives;
	usz graphs;
	usz skipped;
}

struct ReadConstraintCandidate @local
{
	ForeignConstraint foreign;
	JointAxisLimit[3] axes;
	int child_joint;
	bool canonical;
}

<*
 Read anatomical KHR joints whose two attachment nodes sit immediately below
 skeleton joints. Dynamic joints on bone nodes remain the responsibility of
 `read_rig_physics` and are ignored here.

 A graph enters the editable dense table only when it is exactly crig's shape:
 coincident frames on an adjacent parent/child pair, one zero-range XYZ linear
 weld, three independent scalar angular rows, no drive and collision disabled.
 Everything else that still names two skeleton endpoints is copied into
 `foreign` so a same-pack save can reproduce it unchanged. No cone is split and
 no drive is discarded merely to make the data look editable.
*>
fn ConstraintRig read_rig_constraints(
	Allocator allocator,
	gltf::GltfStream* stream,
	rig::Skeleton* skeleton,
	usz[] joint_nodes,
	ConstraintReadReport* report = null)
{
	ConstraintRig out = {};
	ConstraintReadReport tally = {};
	usz nodes = (usz)stream.gltf.nodes.len();
	usz joints = skeleton.len();
	if (nodes == 0 || joints == 0 || joint_nodes.len == 0)
	{
		if (report) *report = tally;
		return out;
	}

	int[] joint_of = alloc::new_array(allocator, int, (sz)nodes);
	defer alloc::free(allocator, joint_of);
	joint_of[:nodes] = -1;
	foreach (usz joint, node : joint_nodes)
	{
		if (node < nodes && joint_of[node] < 0) joint_of[node] = (int)joint;
	}

	ReadConstraintCandidate[] candidates = alloc::new_array(allocator,
		ReadConstraintCandidate, (sz)nodes);
	usz candidate_count = 0;
	for (usz n = 0; n < nodes; n++)
	{
		gltf::Node* node = stream.gltf.nodes.get_ref((sz)n);
		if (node.joint < 0) continue;

		// A motion-bearing skeleton node is the existing secondary-motion wire.
		// Its cone and spring are intentionally not anatomical editor limits.
		if (node.motion >= 0 && joint_of[n] >= 0) continue;
		if (node.joint >= (int)stream.gltf.physics_joints.len()
			|| node.connected_node < 0 || (usz)node.connected_node >= nodes)
		{
			tally.skipped++;
			tally.graphs++;
			continue;
		}

		gltf::Node* connected = stream.gltf.nodes.get_ref((sz)node.connected_node);
		int attachment_joint = node.parent != null && (usz)node.parent.index < nodes
			? joint_of[node.parent.index] : -1;
		int connected_joint = connected.parent != null && (usz)connected.parent.index < nodes
			? joint_of[connected.parent.index] : -1;
		bool attachment_nodes = joint_of[n] < 0
			&& joint_of[(usz)node.connected_node] < 0;
		if (!attachment_nodes || attachment_joint < 0 || connected_joint < 0)
		{
			tally.skipped++;
			tally.graphs++;
			continue;
		}

		ReadConstraintCandidate* candidate = &candidates[candidate_count++];
		ForeignConstraint* foreign = &candidate.foreign;
		foreign.attachment_joint = (usz)attachment_joint;
		foreign.connected_joint = (usz)connected_joint;
		foreign.attachment_position = node.world_position();
		foreign.attachment_rotation = node.world_rotation().normalize();
		foreign.connected_position = connected.world_position();
		foreign.connected_rotation = connected.world_rotation().normalize();
		foreign.enable_collision = node.enable_collision;

		gltf::PhysicsJoint settings = stream.gltf.physics_joints[(uint)node.joint];
		foreign.angular_limits = copy_constraint_limits(allocator, settings.angular_limits);
		foreign.linear_limits = copy_constraint_limits(allocator, settings.linear_limits);
		foreign.drives = copy_constraint_drives(allocator, settings.drives);
		foreign.driven = settings.drives.len() > 0;
		foreign.cone = constraint_has_cone(settings);

		int child = -1;
		int parent = -1;
		if (skeleton.parents[(usz)attachment_joint] == connected_joint)
		{
			child = attachment_joint;
			parent = connected_joint;
		}
		else if (skeleton.parents[(usz)connected_joint] == attachment_joint)
		{
			child = connected_joint;
			parent = attachment_joint;
		}
		candidate.child_joint = child;

		foreign.graph = child < 0
			|| !constraint_vec_near(foreign.attachment_position,
				foreign.connected_position, 1.0e-4f)
			|| !constraint_quaternion_near(foreign.attachment_rotation,
				foreign.connected_rotation, 1.0e-5f)
			|| !constraint_unit_scale(node.world_scale())
			|| !constraint_unit_scale(connected.world_scale());
		if (child >= 0)
		{
			foreign.graph = foreign.graph
				|| !constraint_vec_near(foreign.attachment_position,
					skeleton.joints[(usz)child], 1.0e-4f)
				|| parent != skeleton.parents[(usz)child];
		}

		bool scalar = read_scalar_constraint_axes(settings, &candidate.axes);
		foreign.limit_layout = !scalar || !constraint_linear_weld(settings)
			|| node.enable_collision;
		candidate.canonical = !foreign.graph && !foreign.cone
			&& !foreign.driven && !foreign.limit_layout;
	}

	if (candidate_count == 0)
	{
		alloc::free(allocator, candidates);
		out.skipped = tally.skipped;
		if (report) *report = tally;
		return out;
	}

	int[] uses = alloc::new_array(allocator, int, (sz)joints);
	defer alloc::free(allocator, uses);
	foreach (candidate : candidates[:candidate_count])
	{
		if (candidate.child_joint >= 0) uses[(usz)candidate.child_joint]++;
	}

	out.joints = alloc::new_array(allocator, JointConstraint, (sz)joints);
	foreach (&joint : out.joints) *joint = free_joint_constraint();
	ForeignConstraint[] foreign = alloc::new_array(allocator, ForeignConstraint,
		(sz)candidate_count);
	usz foreign_count = 0;
	// Parsed once for the whole rig rather than once per joint: it holds every
	// joint's entry, and re-reading it per joint made a rig's load quadratic.
	Object* provenance = parse_constraint_provenance(stream.gltf.extras.get(PACK_KEY_CONSTRAINT_FRAMES) ?? "");
	defer if (provenance) provenance.free();

	foreach (&candidate : candidates[:candidate_count])
	{
		bool exact = candidate.canonical && candidate.child_joint >= 0
			&& uses[(usz)candidate.child_joint] == 1;
		JointConstraint carried = free_joint_constraint();
		if (exact)
		{
			carried.status = EXACT;
			carried.axes = candidate.axes;
			uint source_node = (uint)joint_nodes[(usz)candidate.child_joint];
			exact = read_constraint_provenance(provenance, source_node,
				(usz)candidate.child_joint, joint_of, skeleton,
				candidate.foreign.attachment_rotation, candidate.axes, &carried)
				|| infer_constraint_frame(skeleton, (usz)candidate.child_joint,
					candidate.foreign.attachment_rotation, &carried);
		}

		if (exact)
		{
			out.joints[(usz)candidate.child_joint] = carried;
			candidate.foreign.free(allocator);
			tally.exact++;
			continue;
		}

		if (candidate.child_joint >= 0 && uses[(usz)candidate.child_joint] > 1)
		{
			candidate.foreign.graph = true;
		}
		else if (candidate.canonical)
		{
			// The physical graph was canonical, but its frame could not be rebuilt
			// against this skeleton without guessing (normally an untagged fork).
			candidate.foreign.graph = true;
		}
		foreign[foreign_count++] = candidate.foreign;
		candidate.foreign = {};
		tally.foreign++;
		if (foreign[foreign_count - 1].cone) tally.cones++;
		if (foreign[foreign_count - 1].driven) tally.drives++;
		if (foreign[foreign_count - 1].graph) tally.graphs++;
	}

	alloc::free(allocator, candidates);
	if (foreign_count > 0)
	{
		out.foreign = foreign[:foreign_count];
	}
	else
	{
		alloc::free(allocator, foreign);
	}
	out.skipped = tally.skipped;
	if (report) *report = tally;
	return out;
}

fn gltf::Limit[] copy_constraint_limits(Allocator allocator, List{gltf::Limit} source) @local
{
	if (source.len() == 0) return {};
	gltf::Limit[] out = alloc::new_array(allocator, gltf::Limit, source.len());
	foreach (usz i, value : source) out[i] = value;
	return out;
}

fn gltf::Drive[] copy_constraint_drives(Allocator allocator, List{gltf::Drive} source) @local
{
	if (source.len() == 0) return {};
	gltf::Drive[] out = alloc::new_array(allocator, gltf::Drive, source.len());
	foreach (usz i, value : source) out[i] = value;
	return out;
}

fn bool constraint_number(float value) @local => math::is_finite(value);
fn bool constraint_near(float a, float b, float epsilon = 1.0e-6f) @local
	=> math::abs(a - b) <= epsilon;

fn bool constraint_vec_near(Vec3 a, Vec3 b, float epsilon) @local
	=> (a - b).length_sq() <= epsilon * epsilon;

fn bool constraint_quaternion_near(Quaternionf a, Quaternionf b, float epsilon) @local
{
	float[<4>] av = a.normalize().v;
	float[<4>] bv = b.normalize().v;
	float same = (av - bv).dot(av - bv);
	float opposite = (av + bv).dot(av + bv);
	return math::min(same, opposite) <= epsilon * epsilon;
}

fn bool constraint_unit_scale(Vec3 scale) @local
	=> constraint_near(scale.x, 1.0f, 1.0e-5f)
	&& constraint_near(scale.y, 1.0f, 1.0e-5f)
	&& constraint_near(scale.z, 1.0f, 1.0e-5f);

fn int constraint_scalar_axis(Vec3 axes) @local
{
	int found = -1;
	for (usz axis = 0; axis < 3; axis++)
	{
		float value = axes[axis];
		if (constraint_near(value, 0.0f)) continue;
		if (!constraint_near(value, 1.0f) || found >= 0) return -1;
		found = (int)axis;
	}
	return found;
}

fn bool constraint_has_cone(gltf::PhysicsJoint settings) @local
{
	foreach (limit : settings.angular_limits)
	{
		usz axes = 0;
		for (usz axis = 0; axis < 3; axis++) if (!constraint_near(limit.axes[axis], 0.0f)) axes++;
		if (axes > 1) return true;
	}
	return false;
}

fn bool constraint_limit_numbers(gltf::Limit limit) @local
	=> constraint_number(limit.axes.x) && constraint_number(limit.axes.y)
	&& constraint_number(limit.axes.z) && constraint_number(limit.min)
	&& constraint_number(limit.max) && constraint_number(limit.stiffness)
	&& constraint_number(limit.damping) && limit.min <= limit.max;

fn bool constraint_linear_weld(gltf::PhysicsJoint settings) @local
{
	if (settings.linear_limits.len() != 1) return false;
	gltf::Limit limit = settings.linear_limits[0];
	return constraint_limit_numbers(limit)
		&& constraint_near(limit.axes.x, 1.0f)
		&& constraint_near(limit.axes.y, 1.0f)
		&& constraint_near(limit.axes.z, 1.0f)
		&& constraint_near(limit.min, 0.0f)
		&& constraint_near(limit.max, 0.0f)
		&& constraint_near(limit.stiffness, 0.0f)
		&& constraint_near(limit.damping, 0.0f);
}

fn bool read_scalar_constraint_axes(
	gltf::PhysicsJoint settings,
	JointAxisLimit[3]* axes_out) @local
{
	JointRotationLimits defaults = unconstrained_rotation(0);
	*axes_out = defaults.axes;
	if (settings.angular_limits.len() != 3) return false;
	bool[3] seen;
	foreach (limit : settings.angular_limits)
	{
		if (!constraint_limit_numbers(limit)
			|| !constraint_near(limit.stiffness, 0.0f)
			|| !constraint_near(limit.damping, 0.0f)) return false;
		int axis = constraint_scalar_axis(limit.axes);
		if (axis < 0 || seen[(usz)axis]) return false;
		seen[(usz)axis] = true;
		JointAxisLimit* carried = &(*axes_out)[(usz)axis];
		if (constraint_near(limit.min, limit.max))
		{
			carried.allowed = false;
			carried.locked = limit.min;
		}
		else
		{
			carried.allowed = true;
			carried.minimum = limit.min;
			carried.maximum = limit.max;
			carried.locked = 0.0f;
		}
	}
	return seen[0] && seen[1] && seen[2];
}

fn bool parse_constraint_intent(String name, ConstraintFrameIntent* out) @local
{
	switch (name)
	{
		case "automatic": *out = AUTOMATIC;
		case "primary_child": *out = PRIMARY_CHILD;
		case "adjusted_automatic": *out = ADJUSTED_AUTOMATIC;
		case "adjusted_primary_child": *out = ADJUSTED_PRIMARY_CHILD;
		default: return false;
	}
	return true;
}

<*
 The constraint-frame provenance array, or null when there is none or it is not
 an array. The caller frees it.
*>
fn Object* parse_constraint_provenance(String source) @local
{
	if (source.len == 0) return null;
	Object*? parsed = json::parse(mem, source);
	if (catch parsed) return null;
	if (!parsed.is_array())
	{
		parsed.free();
		return null;
	}
	return parsed;
}

fn bool read_constraint_provenance(
	Object* root,
	uint source_node,
	usz joint,
	int[] joint_of,
	rig::Skeleton* skeleton,
	Quaternionf world_frame,
	JointAxisLimit[3] khr_axes,
	JointConstraint* out) @local
{
	if (!root) return false;

	for (sz i = 0; i < root.get_len(); i++)
	{
		Object* entry = root.get_at(i);
		if ((entry.get_int("joint") ?? -1) != (int)source_node) continue;

		ConstraintFrameIntent intent;
		if (!parse_constraint_intent(entry.get_string("intent") ?? "", &intent)) return false;
		int primary_node = entry.get_int("primary") ?? -1;
		int primary = primary_node >= 0 && (usz)primary_node < joint_of.len
			? joint_of[(usz)primary_node] : -1;
		if (intent.uses_primary_child()
			&& (primary < 0 || skeleton.parents[(usz)primary] != (int)joint)) return false;
		if (!intent.uses_primary_child() && primary_node >= 0) return false;

		Quaternionf adjustment = quaternion::IDENTITY;
		Object* values = entry.get("adjustment") ?? null;
		if (!values || !values.is_array() || values.get_len() != 4) return false;
		for (sz q = 0; q < 4; q++)
		{
			Object* value = values.get_at(q);
			if (!value.is_int() && !value.is_float()) return false;
			adjustment.v[q] = (float)gltf::@num(value);
		}
		if (!constraint_quaternion_valid(adjustment)) return false;
		adjustment = adjustment.normalize();
		if (!intent.has_adjustment()
			&& !constraint_quaternion_near(adjustment, quaternion::IDENTITY, 1.0e-5f)) return false;

		Object* axes = entry.get("axes") ?? null;
		if (!axes || !axes.is_array() || axes.get_len() != 3) return false;
		JointAxisLimit[3] restored;
		for (sz axis = 0; axis < 3; axis++)
		{
			Object* saved = axes.get_at(axis);
			bool? allowed = saved.get_bool("allowed");
			double? minimum = saved.get_float("min");
			double? maximum = saved.get_float("max");
			double? locked = saved.get_float("locked");
			if (catch allowed) return false;
			if (catch minimum) return false;
			if (catch maximum) return false;
			if (catch locked) return false;
			restored[(usz)axis] = {
				.allowed = allowed,
				.minimum = (float)minimum,
				.maximum = (float)maximum,
				.locked = (float)locked,
			};
			if (!restored[(usz)axis].valid()) return false;
			float restored_min = allowed ? (float)minimum : (float)locked;
			float restored_max = allowed ? (float)maximum : (float)locked;
			float khr_min = khr_axes[(usz)axis].allowed
				? khr_axes[(usz)axis].minimum : khr_axes[(usz)axis].locked;
			float khr_max = khr_axes[(usz)axis].allowed
				? khr_axes[(usz)axis].maximum : khr_axes[(usz)axis].locked;
			if (!constraint_near(restored_min, khr_min)
				|| !constraint_near(restored_max, khr_max)) return false;
		}

		JointLimitFrame base = joint_limit_frame_by_index(skeleton, joint,
			intent.uses_primary_child() ? primary : -1);
		if (!base.usable()) return false;
		Quaternionf expected = intent.has_adjustment()
			? base.rotation.mul(adjustment).normalize() : base.rotation;
		if (!constraint_quaternion_near(expected, world_frame, 1.0e-5f)) return false;

		out.status = EXACT;
		out.axes = restored;
		out.frame_intent = intent;
		out.primary_child = intent.uses_primary_child() ? primary : -1;
		out.frame_adjustment = intent.has_adjustment()
			? adjustment : (Quaternionf)quaternion::IDENTITY;
		out.frame_status = READY;
		return true;
	}
	return false;
}

fn bool infer_constraint_frame(
	rig::Skeleton* skeleton,
	usz joint,
	Quaternionf world_frame,
	JointConstraint* out) @local
{
	// A fork's frame is read as the child it matches, never as an adjustment of
	// whichever child this rig's shape would follow on its own.
	JointLimitFrame automatic = joint_limit_frame_by_index(skeleton, joint);
	if (automatic.usable() && !limit_frame_forks(skeleton, joint))
	{
		Quaternionf adjustment = automatic.rotation.invert().mul(world_frame).normalize();
		out.status = EXACT;
		out.primary_child = -1;
		out.frame_status = READY;
		if (constraint_quaternion_near(adjustment, quaternion::IDENTITY, 1.0e-5f))
		{
			out.frame_intent = AUTOMATIC;
			out.frame_adjustment = quaternion::IDENTITY;
		}
		else
		{
			out.frame_intent = ADJUSTED_AUTOMATIC;
			out.frame_adjustment = adjustment;
		}
		return true;
	}

	// At a fork, an unadjusted foreign frame is still unambiguous when it equals
	// exactly one child-derived frame. An adjusted fork needs crig provenance;
	// choosing the nearest child would change intent on a differently shaped rig.
	int selected = -1;
	for (usz child = 0; child < skeleton.len(); child++)
	{
		if (skeleton.parents[child] != (int)joint) continue;
		JointLimitFrame frame = joint_limit_frame_by_index(skeleton, joint, (int)child);
		if (!frame.usable() || !constraint_quaternion_near(frame.rotation, world_frame, 1.0e-5f)) continue;
		if (selected >= 0) return false;
		selected = (int)child;
	}
	if (selected < 0) return false;
	out.status = EXACT;
	out.frame_intent = PRIMARY_CHILD;
	out.primary_child = selected;
	out.frame_adjustment = quaternion::IDENTITY;
	out.frame_status = READY;
	return true;
}

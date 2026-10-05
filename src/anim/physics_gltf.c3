<*
 Jiggle physics as a `.glb` says it: KHR_physics_rigid_bodies over
 KHR_implicit_shapes.

 The document keeps secondary motion as dot-keyed chains, because a dot is the
 only thing about a rig that survives an edit. A file has no dots — it has nodes
 — and the extension has no chains — it has a body per bone — so this is the
 crossing, and it is the *canonical* one: the sidecar `.rigsmith.json` mirror in
 `core/session.c3` exists only because a mesh that cannot hold a document has
 nowhere else to put work in progress, while this is what another engine reads.
 A chain is expanded to its bones on the way out and a run of bones is folded
 back into a chain on the way in (`secondary_chains_from_bones`).

 	`RigPhysics wire = rig_physics_of(mem, &app.doc, &view.skeleton, view.dot_ids);`
 	`defer wire.free(mem);`
 	`write_rig_physics(mem, &builder, &view.skeleton, view.names, wire);`

 **In joint order, both directions.** The document resolves its dot ids to joints
 on the way out and the import resolves joints back to dots on the way in, which
 leaves everything here speaking one language — the same bargain `RigView`
 strikes, and for the same reason: a joint index is meaningful only for the build
 that produced it, so the conversion happens once at each end rather than
 wherever it is needed.

 **What the extension is asked to say.** A dynamic bone is a rigid body on the
 joint's own node — a `motion` with the bone's gravity multiplier and damping —
 jointed to its parent's node by a `physicsJoint` whose angular `drive` is the
 spring toward the animated pose. Where the bone may turn is not said here: the
 joint's rotation-limit table is written by `write_rig_constraints` as a joint of
 its own on the same nodes, and read back by the constraint reader. A collider
 is a capsule spanning the bone, and a capsule shape is `+y` in
 KHR_implicit_shapes while a joint node is either unrotated (a pack) or aligned
 along its bone (an engine export), so the capsule hangs off a **child node** of
 its own whose transform is computed per parent frame. One shape, two exporters,
 no second convention.

 **The mapping is a projection and is exact only one way.** crig's solver is a
 particle chain and the extension describes a rigid-body world; every file crig
 writes reads back as the rig that wrote it, and a foreign file is read for the
 parts that map — motions on joints, capsules under them, spheres on them — with
 everything else counted in `RigPhysics.skipped` rather than guessed at.
*>
module crig;

import rig;
import gltf;
import std::math;
import std::math::vector;
import std::math::quaternion;
import std::core::string;


import std::collections::list;

<*
 The two collision systems crig declares.

 A dynamic bone must not collide with the rest of its own chain — a tail whose
 links push each other apart is a tail that explodes — and it must collide with
 the body capsules, which is the whole point of authoring one. Two systems say
 exactly that and nothing else, and they are named rather than numbered so a file
 opened in somebody else's tool reads as something instead of as a bitmask.
*>
const String JIGGLE_SYSTEM_BODY = "crig-body";
const String JIGGLE_SYSTEM_JIGGLE = "crig-jiggle";

<*
 One dynamic bone, keyed by joint index rather than by dot id.

 `JiggleSpec` with the crossing already made: the per-bone form the extension
 speaks, which a chain is expanded into on the way out and folded back from on
 the way in. Nothing in a file has ever heard of a dot, and a writer that took
 dot ids plus the map every time would be doing the resolve once per entry
 instead of once.
*>
struct JiggleJoint
{
	usz joint;
	JiggleParams params;
}

<*
 A rig's physics in joint order: what goes into a file and what comes back out
 of one.

 `colliders` is `JiggleColliderSpec`, the same joint-plus-radius pair
 `build_jiggle_sim` takes, so the read side of a `.glb` and the sim builder speak
 the same type and nothing has to translate between them.

 `skipped` is only ever filled by the read: how many physics objects in the file
 described something crig has no place for — a box collider, a body on a node
 that is not a bone. Worth counting rather than hiding, because a foreign file
 that comes back with half its setup is a different claim from one that comes
 back whole.
*>
struct RigPhysics
{
	JiggleJoint[] joints;
	JiggleColliderSpec[] colliders;
	usz skipped;
}

<*
 Whether there is anything here to write or to apply.
*>
fn bool RigPhysics.present(&self) => self.joints.len > 0 || self.colliders.len > 0;

fn void RigPhysics.free(&self, Allocator allocator)
{
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.colliders.len > 0) alloc::free(allocator, self.colliders);
	*self = {};
}

<*
 The document's chains expanded to the per-bone form a file carries, in one
 build's joint order.

 	`RigPhysics wire = rig_physics_of(mem, &app.doc, &view.skeleton, view.dot_ids);`
 	`defer wire.free(mem);`

 KHR states a dynamic bone as a body, a joint and a drive — one of each per
 bone — so a chain's shared behaviour is written onto every bone of its run,
 through the same `jiggle_specs_from_document` the solver reads. That is
 deliberate: the file carries exactly what the viewport simulated, and a chain
 that does not resolve (a tip no longer under its root, a root on the
 skeleton's root) is written nowhere rather than guessed at.

 A bone's own radius — the sphere collider a runtime holds it off the body
 with — is not the document's to say: a chain is as fat as its skin, measured
 by `joint_thickness`. The caller that has a skin hands the measurement in as
 `radii`, one per joint; without one a bone is written as a point, and a chain
 that does not collide is written as points whatever was measured, which is
 the nearest thing the extension has to "passes through the body".

 The caller owns the result; free it with `RigPhysics.free`.

 @param dot_ids : `The dot each joint was built from — RigView.dot_ids.`
 @param radii : `Each joint's measured thickness, in joint order, or empty for none.`
*>
fn RigPhysics rig_physics_of(Allocator allocator, RigDocument* doc, rig::Skeleton* skeleton, uint[] dot_ids, float[] radii = {})
{
	RigPhysics out = {};

	JiggleChainSpec[] chains;
	JiggleColliderSpec[] colliders;
	jiggle_specs_from_document(allocator, doc, skeleton, dot_ids, &chains, &colliders);
	defer free_jiggle_specs(allocator, chains, colliders);

	usz bones = 0;
	foreach (chain : chains) bones += chain.joints.len;
	if (bones > 0)
	{
		out.joints = alloc::new_array(allocator, JiggleJoint, (sz)bones);
		usz at = 0;
		foreach (chain : chains)
		{
			foreach (usz i, joint : chain.joints)
			{
				JiggleParams params = chain.params[i];
				if (!chain.ignores_colliders && joint < radii.len) params.radius = math::max(radii[joint], 0.0f);
				out.joints[at++] = { .joint = joint, .params = params };
			}
		}
	}

	if (colliders.len > 0)
	{
		out.colliders = alloc::new_array(allocator, JiggleColliderSpec, (sz)colliders.len);
		foreach (usz i, collider : colliders) out.colliders[i] = collider;
	}

	return out;
}

<*
 Put a rig's physics into a builder that already holds its joint nodes.

 	`write_rig_physics(mem, &builder, &skeleton, names, wire);`

 Called after the joints exist and before the file is saved. Every node this adds
 is a *child* of a joint node, so joint 0..n-1 keep the node indices the skin and
 the animation channels were written against — which is what lets this be a late
 addition to two exporters that were already finished.

 Nothing is written for a rig with no physics, down to the `extensionsUsed` entry:
 the builder names an extension only when something in the document uses it, so an
 ordinary pack is byte-for-byte what it was before this existed.

 **A dynamic joint with no parent joint is skipped.** The extension states a
 dynamic bone as a joint between two bodies, and a root has no second body to name
 — the same case `jiggle_specs_from_document` drops from its chains and M5's
 validation refuses to create. The document keeps the entry; the file does not
 carry it.

 @param names : `One per joint, used to name the collider child nodes. Short or empty falls back to a plain label.`
 @param joint_nodes : `Which node each joint became. Short or empty means node j is joint j, which is the pack convention.`
 @param rest : `Each joint node's world rotation. Empty is the unrotated frame export_pack_glb writes; gltf::bone_rotations is what the engine export passes.`
*>
fn void write_rig_physics(
	Allocator allocator,
	gltf::GltfBuilder* builder,
	rig::Skeleton* skeleton,
	String[] names,
	RigPhysics physics,
	uint[] joint_nodes = {},
	Quaternionf[] rest = {})
{
	if (!physics.present()) return;

	usz joints = skeleton.len();
	if (joints == 0) return;

	Vec3[] tails = skeleton.tails(allocator);
	defer alloc::free(allocator, tails);

	// Both filters are registered once and shared by every collider that wants
	// them, which is what the index in a `Collider` is for. Registering one per
	// bone would say the same thing n times and make two files of the same rig
	// differ in how many.
	int body_filter = -1;
	int jiggle_filter = -1;

	foreach (spec : physics.colliders)
	{
		if (spec.joint >= joints || spec.radius <= 0.0f) continue;

		Vec3 bone = tails[spec.joint] - skeleton.joints[spec.joint];
		float length = bone.length();
		// A joint whose tail sits on top of it has no segment to sweep. Writing a
		// zero-height capsule would be writing a sphere with extra words in it.
		if (length < JIGGLE_WIRE_EPSILON) continue;

		if (body_filter < 0) body_filter = (int)add_jiggle_filter(builder, false);

		uint shape = builder.add_shape({
			.type = gltf::ShapeType.CAPSULE,
			.height = length,
			.radius_bottom = spec.radius,
			.radius_top = spec.radius,
		});

		Quaternionf frame = spec.joint < rest.len ? rest[spec.joint] : quaternion::IDENTITY;
		Quaternionf into_node = frame.conjugate();

		// The capsule is +y and centred on its own origin, so the child node turns
		// +y onto the bone and sits at the bone's middle — both stated in the joint
		// node's frame, which is the whole reason a child node is used rather than
		// the joint node itself.
		String label = jiggle_node_name(allocator, names, spec.joint);
		uint node = builder.add_node(
			label,
			translation: into_node * (bone * 0.5f),
			rotation: into_node.mul(bone_carry({ 0, 1, 0 }, bone)));
		alloc::free(allocator, label.ptr);

		builder.add_collider(node, {
			.shape = (int)shape,
			.node = -1,
			.material = -1,
			.collision_filter = body_filter,
			.mesh = -1,
			.base_node = -1,
		});
		builder.add_child(joint_node_of(joint_nodes, spec.joint), node);
	}

	foreach (spec : physics.joints)
	{
		if (spec.joint >= joints || spec.params.inert()) continue;

		int parent = skeleton.parents[spec.joint];
		if (parent < 0 || (usz)parent >= joints) continue;

		uint node = joint_node_of(joint_nodes, spec.joint);

		// Mass, gravity factor and both damping factors are written whatever they
		// are: the parser defaults them to 1 and 0.9, so a bone that really is
		// undamped has to say so out loud or read back as something else. Mass is 1
		// because nothing in crig's solver has a mass — the particles are all unit
		// inverse mass — and 0 would read as a body no force can move.
		builder.add_motion(node, {
			.mass = 1.0f,
			.gravity_factor = spec.params.gravity,
			.linear_dampening = spec.params.damping,
			.angular_dampening = spec.params.damping,
		});

		if (spec.params.radius > 0.0f)
		{
			if (jiggle_filter < 0) jiggle_filter = (int)add_jiggle_filter(builder, true);

			uint shape = builder.add_shape({
				.type = gltf::ShapeType.SPHERE,
				.radius = spec.params.radius,
			});
			builder.add_collider(node, {
				.shape = (int)shape,
				.node = -1,
				.material = -1,
				.collision_filter = jiggle_filter,
				.mesh = -1,
				.base_node = -1,
			});
		}

		gltf::PhysicsJoint settings;
		settings.angular_limits.init(allocator);
		settings.linear_limits.init(allocator);
		settings.drives.init(allocator);
		defer settings.free();

		// No angular limit here: where a dynamic bone may turn is its joint's
		// rotation-limit table, which `write_rig_constraints` writes as its own
		// three-axis joint on the same pair of nodes.
		if (spec.params.stiffness > 0.0f)
		{
			// A force drive rather than an acceleration one: the stiffness is a
			// spring rate and the mass above is 1, so the two readings coincide and
			// the force form is the one every engine implements.
			settings.drives.push({
				.type = gltf::DriveType.ANGULAR,
				.drive = gltf::DriveMode.FORCE,
				.stiffness = spec.params.stiffness,
				.damping = spec.params.damping,
			});
		}

		// The joint hangs on the child and names the parent, which is the direction
		// the extension writes it in — once, rather than from both ends.
		builder.add_node_joint(node, joint_node_of(joint_nodes, (usz)parent),
			builder.add_physics_joint_settings(settings));
	}
}

<*
 Read a file's physics back as joints, radii and a count of what did not map.

 	`RigPhysics wire = read_rig_physics(mem, &stream, joint_nodes);`
 	`defer wire.free(mem);`

 The inverse of `write_rig_physics` for a file crig wrote, and a best effort for
 one it did not. Three shapes are recognised and everything else is counted:

 - a **motion on a joint node** is a dynamic bone. Its gravity factor and linear
   damping are read straight back; its stiffness and its cone come from the
   `physicsJoint` the node names, when it names one, so a foreign body with no
   joint arrives as a bone that falls and swings but is sprung toward nothing.
 - a **sphere collider on that same node** is the bone's own particle radius.
 - a **capsule collider on a child of a joint node** is that joint's collider
   capsule. The child's transform is not read back at all: it is derived from the
   bone, so believing the file's copy of it over the bone would let the two
   disagree.

 A joint the file names twice keeps the first reading, which is the only one that
 can be defended without deciding which of two bodies on one bone is meant.

 The caller owns the result; free it with `RigPhysics.free`.

 @param joint_nodes : `The source node per joint, as read_rest_skeleton fills it. Empty reads nothing, since without it there is no way to tell a bone from a prop.`
*>
fn RigPhysics read_rig_physics(Allocator allocator, gltf::GltfStream* stream, usz[] joint_nodes)
{
	RigPhysics out = {};

	usz nodes = (usz)stream.gltf.nodes.len();
	usz joints = joint_nodes.len;
	if (nodes == 0 || joints == 0) return out;

	// Which joint each node is, or -1 for a node that is not a bone of this
	// skeleton. The reverse of what the caller was given, built once because every
	// collider below asks it about its own node and about its parent's.
	int[] joint_of = alloc::new_array(allocator, int, (sz)nodes);
	defer alloc::free(allocator, joint_of);
	joint_of[:nodes] = -1;
	foreach (usz j, node : joint_nodes)
	{
		if (node < nodes && joint_of[node] < 0) joint_of[node] = (int)j;
	}

	// P5 anatomical bodies also carry `motion`, but they are not dynamic-bone
	// authoring records. Recognise them through both their explicit convex mesh
	// collider and the attachment graph: an
	// anatomical joint lives on a non-bone pivot whose parent is one body and
	// names another non-bone pivot whose parent is the adjacent body. The legacy
	// jiggle joint lives directly on the bone node and has an implicit sphere, so
	// the two remain distinct without editor metadata in the file. Requiring the
	// hull is important when P5 preserved a legacy body on a constrained bone.
	bool[] anatomical_body = alloc::new_array(allocator, bool, (sz)nodes);
	defer alloc::free(allocator, anatomical_body);
	for (usz n = 0; n < nodes; n++)
	{
		gltf::Node* pivot = stream.gltf.nodes.get_ref((sz)n);
		if (pivot.joint < 0 || joint_of[n] >= 0 || pivot.parent == null) continue;
		if (pivot.connected_node < 0 || (usz)pivot.connected_node >= nodes) continue;
		gltf::Node* other = stream.gltf.nodes.get_ref((sz)pivot.connected_node);
		if (other.parent == null || joint_of[(usz)pivot.parent.index] < 0
			|| joint_of[(usz)other.parent.index] < 0) continue;
		usz attachment_body = (usz)pivot.parent.index;
		usz connected_body = (usz)other.parent.index;
		gltf::Node* attachment = stream.gltf.nodes.get_ref((sz)attachment_body);
		gltf::Node* connected = stream.gltf.nodes.get_ref((sz)connected_body);
		if (attachment.collider >= 0
			&& attachment.collider < (int)stream.gltf.colliders.len())
		{
			gltf::Collider collider = stream.gltf.colliders[(uint)attachment.collider];
			anatomical_body[attachment_body] = collider.convex_hull
				&& collider.has_mesh();
		}
		if (connected.collider >= 0
			&& connected.collider < (int)stream.gltf.colliders.len())
		{
			gltf::Collider collider = stream.gltf.colliders[(uint)connected.collider];
			anatomical_body[connected_body] = collider.convex_hull
				&& collider.has_mesh();
		}
	}

	JiggleJoint[] dynamic = alloc::new_array(allocator, JiggleJoint, (sz)joints);
	JiggleColliderSpec[] capsules = alloc::new_array(allocator, JiggleColliderSpec, (sz)joints);
	usz dynamic_count = 0;
	usz capsule_count = 0;

	// One slot per joint, so a second body on a bone is dropped rather than
	// appended: the sim would have no reading for two.
	float[] sphere = alloc::new_array(allocator, float, (sz)joints);
	defer alloc::free(allocator, sphere);
	bool[] has_capsule = alloc::new_array(allocator, bool, (sz)joints);
	defer alloc::free(allocator, has_capsule);

	// --- the colliders, before the bodies that read their radii ---------------

	for (usz n = 0; n < nodes; n++)
	{
		gltf::Node* node = stream.gltf.nodes.get_ref((sz)n);
		if (node.collider < 0) continue;
		if (anatomical_body[n]) continue;

		gltf::Collider collider = stream.gltf.colliders[(uint)node.collider];
		if (!collider.has_shape() || collider.shape >= (int)stream.gltf.shapes.len())
		{
			out.skipped++;
			continue;
		}

		gltf::Shape shape = stream.gltf.shapes[(uint)collider.shape];
		int owner = joint_of[n];
		int carrier = node.parent != null && (usz)node.parent.index < nodes
			? joint_of[node.parent.index]
			: -1;

		switch (shape.type)
		{
			case SPHERE:
				// On the bone itself: the particle's own radius. Anywhere else it is
				// somebody's prop and crig has no place for it.
				if (owner < 0) { out.skipped++; break; }
				if (sphere[(usz)owner] > 0.0f) { out.skipped++; break; }
				sphere[(usz)owner] = shape.radius;
			case CAPSULE:
				// Under the bone: the capsule this bone sweeps. On the bone itself is
				// somebody else's convention, and reading it as ours would put a
				// collider a quarter turn off the limb it belongs to.
				if (carrier < 0 || has_capsule[(usz)carrier]) { out.skipped++; break; }
				has_capsule[(usz)carrier] = true;
				capsules[capsule_count++] = {
					.joint = (usz)carrier,
					.radius = math::max(shape.radius_bottom, shape.radius_top),
				};
			default:
				out.skipped++;
		}
	}

	// --- the bodies -----------------------------------------------------------

	for (usz n = 0; n < nodes; n++)
	{
		gltf::Node* node = stream.gltf.nodes.get_ref((sz)n);
		if (node.motion < 0) continue;
		if (anatomical_body[n]) continue;

		int owner = joint_of[n];
		if (owner < 0)
		{
			out.skipped++;
			continue;
		}

		gltf::Motion motion = stream.gltf.motions[(uint)node.motion];
		JiggleParams params = {
			.gravity = motion.gravity_factor,
			.damping = motion.linear_dampening,
			.radius = sphere[(usz)owner],
		};

		if (node.joint >= 0 && node.joint < (int)stream.gltf.physics_joints.len())
		{
			gltf::PhysicsJoint settings = stream.gltf.physics_joints[(uint)node.joint];

			// An angular limit on the drive's joint is not read: crig's chains
			// swing where the joint's own rotation-limit table says, which the
			// constraint reader takes from its own three-axis joint, and a
			// foreign cone is that reader's to report.
			foreach (drive : settings.drives)
			{
				if (drive.type != gltf::DriveType.ANGULAR) continue;
				params.stiffness = drive.stiffness;
				// The damping the drive states wins over the body's, when it has one.
				// They are the same number in every file crig writes; in one it did
				// not, the drive is the more specific statement of the two.
				if (drive.damping != 0.0f) params.damping = drive.damping;
				break;
			}
		}

		if (params.inert()) continue;
		dynamic[dynamic_count++] = { .joint = (usz)owner, .params = params };
	}

	if (dynamic_count > 0)
	{
		out.joints = dynamic[:dynamic_count];
	}
	else
	{
		alloc::free(allocator, dynamic);
	}

	if (capsule_count > 0)
	{
		out.colliders = capsules[:capsule_count];
	}
	else
	{
		alloc::free(allocator, capsules);
	}

	return out;
}

// A bone shorter than this has no direction worth writing a capsule along.
const float JIGGLE_WIRE_EPSILON @local = 1.0e-6f;

// Which node a joint became, with the pack convention — node j is joint j — as
// the answer when nothing says otherwise.
fn uint joint_node_of(uint[] joint_nodes, usz joint) @local
	=> joint < joint_nodes.len ? joint_nodes[joint] : (uint)joint;

// One of the two collision filters, registered on first use. The jiggle system
// excludes itself so a chain's own links cannot push each other apart, and names
// the body system so the thing it is authored to hit is the thing it hits.
fn uint add_jiggle_filter(gltf::GltfBuilder* builder, bool jiggle) @local
{
	gltf::CollisionFilter filter;
	filter.systems.init(mem);
	filter.colliding_with.init(mem);
	filter.not_colliding.init(mem);
	defer filter.free();

	if (jiggle)
	{
		filter.systems.push(JIGGLE_SYSTEM_JIGGLE);
		filter.not_colliding.push(JIGGLE_SYSTEM_JIGGLE);
		filter.colliding_with.push(JIGGLE_SYSTEM_BODY);
	}
	else
	{
		filter.systems.push(JIGGLE_SYSTEM_BODY);
		filter.colliding_with.push(JIGGLE_SYSTEM_JIGGLE);
	}

	return builder.add_collision_filter(filter);
}

// What a collider's child node is called: the bone's own name with a suffix, so
// a file opened somewhere else says which limb the capsule belongs to. A rig
// whose joints are unnamed still gets nodes that can be told apart.
fn String jiggle_node_name(Allocator allocator, String[] names, usz joint) @local
{
	String label = joint < names.len && names[joint].len > 0 ? names[joint] : "joint";
	return string::format(allocator, "%s.collider", label);
}

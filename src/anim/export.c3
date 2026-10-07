<*
 Writing AnimTemplates back out as a .glb.

 The inverse of anim/import.c3, and the reason templates can be data at all:
 a walk lives in a file, gets read in at startup, and can be written back out
 again without passing through anything that rounds it.

 	`crig::export_animations_glb(mem, "walks.glb", &skeleton, names, templates)!;`

 The glTF itself is assembled by `gltf::GltfBuilder`, so nothing here knows how a
 bufferView is numbered or where a chunk boundary falls. What is left is the part
 that is about rigs: which joints a template actually moves, and in what frame.

 **The frame is crig's own.** Every node is written with an identity rotation and
 a translation to where its joint rests, which is exactly the frame `rig/pose.c3`
 poses in — so a template's rotation *is* the node's local rotation and its
 offset *is* part of the node's local translation, with no conversion in
 between. Reading the result back gives the template that went in, which is the
 property the round-trip check leans on.

 That is not how a DCC tool writes a skeleton; those align each bone's local
 axes along the bone. Both are valid glTF and both import correctly — the
 importer cancels the rest orientation either way — but this one is the shape
 that costs nothing to write and nothing to read.

 **A body is optional.** `export_animations_glb` writes none: a template library
 is a skeleton and some curves, and most viewers will show an empty scene, which
 is worth knowing before opening one to check it. `export_pack_glb` takes one,
 because a pack is meant to be looked at — see anim/pack.c3. Neither writes
 a skin: crig binds any mesh to any skeleton itself, so there is nothing to
 agree with anyone about.
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

<*
 Raised when the skeleton has no joints, or fewer names than joints.
*>
faultdef ANIM_EXPORT_SHAPE_MISMATCH;

<*
 Raised when a joint has no name. A template is looked up by name, so a rig
 written out with anonymous joints could never be matched to one.
*>
faultdef ANIM_EXPORT_UNNAMED_JOINT;

<*
 Raised when there is nothing to write — no templates, or none with keyframes.
*>
faultdef ANIM_EXPORT_EMPTY;

// Below this a rotation is no rotation and an offset is no offset, so the
// channel carrying it is not written at all. Matches the importer's own
// threshold, so a template survives a round trip without gaining or losing
// entries.
const float ANIM_EXPORT_EPSILON @local = 1.0e-6f;

<*
 Write a skeleton and some templates as a .glb.

 The templates are written against `skeleton`, which has to be the rig they were
 authored on: the offsets are fractions of its height and the rotations are
 about axes through its joints. Handing this a different rig would write a file
 that plays a different animation.

 @param names : `One name per joint, in joint order; none may be empty.`
 @return? ANIM_EXPORT_SHAPE_MISMATCH : `The skeleton is empty or has more joints than names.`
 @return? ANIM_EXPORT_UNNAMED_JOINT : `A joint has no name to key a template on.`
 @return? ANIM_EXPORT_EMPTY : `No template has any keyframes.`
*>
fn void? export_animations_glb(
	Allocator allocator,
	String path,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate[] templates)
{
	return export_pack_glb(allocator, path, skeleton, names, templates, {}, {});
}

<*
 Write a whole pack: a skeleton, its clips, a body to show them on, and what the
 pack says about itself.

 	`crig::export_pack_glb(mem, "biped.glb", &skeleton, names, clips, body,`
 	`	{ .plan = "biped", .name = "Biped", .tags = tags })!;`

 **The body carries no skin.** crig binds any mesh to any skeleton itself, so a
 pack does not have to agree with anyone about joint indices or inverse binds,
 and a reader that wanted them could not trust ours anyway. The `skins` entry
 stays, because it is how a reader knows which nodes are bones — without it the
 joints have to be guessed from what an animation happens to move, which is a
 strictly worse answer and a different one per clip.

 The metadata goes in the file's root `extras`, which is where `read_pack` looks
 for it. Values are strings because that is all a glTF reader keeps.

 Faults from `gltf` propagate: `WRITE_FAILED` when the path cannot be written.

 **A pack may carry a body and no clips at all**, and that is a body plan rather
 than a degenerate file: `read_pack` already accepts one — it refuses only a file
 with neither clips nor joints — and `AnimPack.is_body_plan` asks for a plan tag
 and a body and says nothing about clips. What this refuses is a file holding
 *neither*: a skeleton alone can be neither played nor fitted, so writing one is
 always a mistake rather than sometimes a plan.

 @param mesh : `The body, in the same space as the skeleton's joints. Empty writes no mesh, and then at least one template must carry keyframes.`
 @param meta : `What the pack says about itself. All fields optional; an empty one writes no extras.`
 @param physics : `Which bones the simulation owns and what they collide with, in joint order. Empty writes no physics extension at all — see anim/physics_gltf.c3.`
 @param constraints : `Reusable anatomical limits in joint order. Exact parent/child rows are written as KHR attachment frames independently of jiggle physics.`
 @param skin : `Optional [vertices, joints] target weights used only to derive physical hull regions. Empty or mismatched uses the pack body's geometric bind.`
 @param physical_report : `Filled with generated/skipped hull counts and their raw binary payload when given.`
 @return? ANIM_EXPORT_SHAPE_MISMATCH : `The skeleton is empty or has more joints than names.`
 @return? ANIM_EXPORT_UNNAMED_JOINT : `A joint has no name to key a template on.`
 @return? ANIM_EXPORT_EMPTY : `No template has any keyframes and there is no body either, so the file would hold nothing to play and nothing to fit.`
*>
fn void? export_pack_glb(
	Allocator allocator,
	String path,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate[] templates,
	rig::TriMesh mesh,
	AnimPackMeta meta,
	RigPhysics physics = {},
	ConstraintRig constraints = {},
	float[] skin = {},
	PhysicalBodyWriteReport* physical_report = null)
{
	usz joints = skeleton.len();
	if (joints == 0 || names.len < joints) return ANIM_EXPORT_SHAPE_MISMATCH~;
	foreach (name : names)
	{
		if (name.len == 0) return ANIM_EXPORT_UNNAMED_JOINT~;
	}

	// This writer keeps the authored keys, and layers and aims are not keys:
	// written raw, such a clip would lose them without a word. A clip with any
	// unmuted layer or aim is baked first (solo ignored), so the file carries the
	// flattened motion; the project sidecar keeps the live aims.
	AnimTemplate[] authored = templates;
	AnimTemplate[] flattened = {};
	bool[] made = {};
	bool layered = false;
	foreach (&template : authored) if (template.plays_layers(false) || template.plays_live_layers()) layered = true;
	if (layered)
	{
		flattened = alloc::new_array(allocator, AnimTemplate, (sz)authored.len);
		made = alloc::new_array(allocator, bool, (sz)authored.len);
		foreach (usz i, &template : authored)
		{
			flattened[i] = *template;
			if (template.plays_layers(false))
			{
				flattened[i] = clip_flattened(allocator, *template, skeleton, names);
				made[i] = true;
			}
			if (flattened[i].plays_live_layers())
			{
				AnimTemplate next = clip_aims_flattened(allocator, flattened[i], skeleton, names, constraints);
				if (made[i]) flattened[i].free(allocator);
				flattened[i] = next;
				made[i] = true;
			}
		}
		templates = flattened;
	}
	defer if (layered)
	{
		foreach (usz i, &template : flattened) if (made[i]) template.free(allocator);
		alloc::free(allocator, flattened);
		alloc::free(allocator, made);
	};

	usz clips = 0;
	foreach (template : templates)
	{
		if (template.keyframes.len > 0) clips++;
	}

	// Both halves, because either one alone is a file worth having: clips with no
	// body is a clip pack, and a body with no clips is a body plan. Neither is the
	// only combination that cannot be read as anything — see the note above.
	bool carries_body = mesh.positions.len > 0 && mesh.indices.len > 0;
	if (clips == 0 && !carries_body) return ANIM_EXPORT_EMPTY~;

	gltf::GltfBuilder builder = gltf::builder(allocator);
	defer builder.free();
	builder.generator = "rigsmith";

	write_pack_extras(allocator, &builder, meta);

	String clip_settings = clip_extras_text(allocator, templates);
	// Guarded: a pack whose clips all say nothing gets "" back, which is a literal
	// and not this allocator's to release.
	defer if (clip_settings.len > 0) clip_settings.free(allocator);
	if (clip_settings.len > 0) builder.set_extra(PACK_KEY_CLIPS, clip_settings);
	write_joint_nodes(&builder, skeleton, names);

	// The joints are nodes 0..joints-1, so a channel can name one by its index
	// and the skin can list them as a run.
	uint[] joint_nodes = alloc::new_array(allocator, uint, (sz)joints);
	defer alloc::free(allocator, joint_nodes);
	for (usz j = 0; j < joints; j++) joint_nodes[j] = (uint)j;
	builder.add_skin("rig", joint_nodes);

	// After the skin, so the run above is still 0..joints-1: legacy collider
	// capsules and constraint frames add child nodes past the end of it.
	write_rig_physics(allocator, &builder, skeleton, names, physics);

	foreach (template : templates)
	{
		if (template.keyframes.len == 0) continue;
		write_animation(allocator, &builder, skeleton, names, template);
	}

	if (carries_body)
	{
		gltf::WriteAttribute[2] attributes;
		usz attribute_count = 1;
		attributes[0] = { .name = "POSITION", .accessor = builder.add_positions(mesh.positions) };
		if (mesh.has_normals())
		{
			attributes[1] = { .name = "NORMAL", .accessor = builder.add_vec3(mesh.normals) };
			attribute_count = 2;
		}

		uint body = builder.add_mesh("body");
		builder.add_primitive(body, attributes[0:attribute_count],
			indices: (int)builder.add_indices(mesh.indices));

		// The body hangs off the scene beside the skeleton rather than under it:
		// a node inside the joint hierarchy would be moved by its parent, and
		// this one is posed by the skin instead. It carries no transform, so the
		// vertices land exactly where they were authored — which is what lets a
		// reader take the mesh and the joints as one space.
		builder.add_root(builder.add_node("body", mesh: (int)body));
	}

	// Physical bodies are generated only from this pack's own target mesh. Their
	// hull meshes are resources referenced from the skeleton nodes and never
	// visual scene nodes, so `from_gltf` above continues to read only `body`.
	PhysicalBodyWriteReport generated = {};
	if (carries_body && constraints.present())
	{
		bool predicted = skin.len == mesh.positions.len * joints && joints > 0;
		float[] weights = predicted
			? skin
			: rig::bind_geometric(allocator, mesh.positions, skeleton.joints,
				skeleton.parents);
		defer if (!predicted) alloc::free(allocator, weights);
		gltf::SkinBinding binding = gltf::sparsify_weights(allocator, weights,
			mesh.positions.len, joints, 4)!;
		defer binding.free(allocator);
		generated = write_target_physical_bodies(allocator, &builder, mesh,
			skeleton, names, binding, constraints, existing_physics: physics);
	}
	if (physical_report) *physical_report = generated;

	// Attachment frames come last so every exact row names body nodes which
	// already hold their target-derived collider and mass where geometry allowed.
	(void)write_rig_constraints(allocator, &builder, skeleton, names, constraints);

	return builder.save_glb(path);
}

<*
 Write a rigged, animated .glb: the mesh, its skin, the skeleton and the clips.

 	`crig::export_rigged_animated_glb(mem, "goat.glb", mesh, &skeleton, names, skin, clips)!;`

 What a game engine or a DCC tool is given: one file it can import and press
 play on. `export_rigged_glb` writes the first half of it and `export_pack_glb`
 the second, and neither can be extended into this — they disagree about the
 frame the joint nodes are written in, and only one of the two frames survives
 having a skin attached to it.

 **The nodes are bone-aligned**, the convention `gltf::add_skeleton` writes and
 Blender expects: a joint's local -Z runs along its bone. crig poses in a
 different frame — every node unrotated, so a template's rotation *is* the
 node's local rotation, which is what anim/export.c3's own note describes —
 so every channel written here is converted on the way out. The alternative,
 writing crig's frame and animating it directly, is valid glTF and imports as an
 armature whose leaf bones fan out from the origin, which is the defect
 `export_rigged_glb` went to this convention to avoid.

 A clip that names no joint of this skeleton writes no channels and still gets an
 animation, so a file always holds as many clips as it was given.

 @param mesh : `The body in the skeleton's own space.`
 @param skeleton : `Joints in model space, ordered parents-before-children.`
 @param names : `One per joint, in joint order — a clip addresses joints by name.`
 @param skin : `[vertices, joints] weights. Short or mismatched falls back to distance weights.`
 @param templates : `Written against this skeleton; one glTF animation each.`
 @param name : `The mesh node's name, and the skin's.`
 @param influences : `How many joints a vertex may ride in the file; 1 writes a rigid bind with no blending.`
 @param physics : `Which bones the simulation owns and what they collide with, in joint order. Empty writes no physics extension at all — see anim/physics_gltf.c3.`
 @param constraints : `Reusable anatomical limits in joint order. Exact parent/child rows become coincident KHR attachment frames.`
 @param physical_report : `Filled with generated/skipped target hull counts and their raw binary payload when given.`
 @return? ANIM_EXPORT_SHAPE_MISMATCH : `The skeleton is empty, or there are fewer names than joints.`
 @return? ANIM_EXPORT_UNNAMED_JOINT : `A joint has no name, so no clip could ever address it.`
 @return? gltf::WRITE_FAILED : `The file could not be opened, written or flushed.`
*>
fn void? export_rigged_animated_glb(
	Allocator allocator,
	String path,
	rig::TriMesh mesh,
	rig::Skeleton* skeleton,
	String[] names,
	float[] skin,
	AnimTemplate[] templates,
	String name = "Mesh",
	uint influences = 4,
	RigPhysics physics = {},
	ConstraintRig constraints = {},
	PhysicalBodyWriteReport* physical_report = null,
	ProjectTransform model_transform = {},
	ExportMotion motion = {},
	ExportMotionReport* motion_report = null)
{
	usz joints = skeleton.len();
	if (joints == 0 || names.len < joints) return ANIM_EXPORT_SHAPE_MISMATCH~;
	foreach (usz j, joint_name : names[:joints])
	{
		if (joint_name.len == 0) return ANIM_EXPORT_UNNAMED_JOINT~;
	}

	// --- the skeleton, as the file describes it -----------------------------

	Vec3[] tails = skeleton.tails(allocator);
	defer alloc::free(allocator, tails);

	gltf::Bone[] bones = alloc::new_array(allocator, gltf::Bone, (sz)joints);
	defer alloc::free(allocator, bones);
	for (usz j = 0; j < joints; j++)
	{
		bones[j] = {
			.name = names[j],
			.parent = skeleton.parents[j],
			.position = skeleton.joints[j],
			.direction = tails[j] - skeleton.joints[j],
		};
	}

	// The frame those nodes are written in, taken from the library that writes
	// them rather than recomputed here — the -Z convention is one decision and
	// two copies of it would drift.
	Quaternionf[] rest = gltf::bone_rotations(allocator, bones);
	defer alloc::free(allocator, rest);

	// --- the mesh and its skin ----------------------------------------------

	bool predicted = skin.len == mesh.positions.len * joints && joints > 0;
	float[] weights = predicted
		? skin
		: rig::bind_geometric(allocator, mesh.positions, skeleton.joints, skeleton.parents);
	defer if (!predicted) alloc::free(allocator, weights);

	gltf::SkinBinding binding = gltf::sparsify_weights(allocator, weights, mesh.positions.len, joints, influences)!;
	defer binding.free(allocator);

	gltf::GltfBuilder builder = gltf::builder(allocator);
	defer builder.free();
	builder.generator = "rigsmith";

	AttributeList attributes;
	attributes.init(allocator);
	defer attributes.free();

	attributes.push({ .name = "POSITION", .accessor = builder.add_positions(mesh.positions) });
	if (mesh.has_normals())
	{
		attributes.push({ .name = "NORMAL", .accessor = builder.add_vec3(mesh.normals) });
	}
	builder.add_skin_binding(binding, &attributes);

	uint body = builder.add_mesh(name);
	builder.add_primitive(body, attributes.array_view(),
		indices: mesh.indices.len > 0 ? (int)builder.add_indices(mesh.indices) : -1);

	List{uint} joint_nodes;
	joint_nodes.init(allocator);
	defer joint_nodes.free();

	List{uint} roots;
	roots.init(allocator);
	defer roots.free();

	uint inverse_bind = builder.add_skeleton(bones, &joint_nodes, &roots);

	// glTF names a skeleton root only when there is a single common one — a rig
	// with two armatures in it, which crig allows, has none to name.
	int common = roots.len() == 1 ? (int)roots.get(0) : -1;
	uint skin_index = builder.add_skin(name, joint_nodes.array_view(),
		inverse_bind: (int)inverse_bind, skeleton: common);

	// A skinned mesh ignores its own node transform in glTF — it is posed by its
	// joints. A project placement therefore parents both the mesh and every
	// skeleton root under one node, preserving their bind-space relationship.
	uint body_node = builder.add_node(name, mesh: (int)body, skin: (int)skin_index);
	if (model_transform.is_identity())
	{
		builder.add_root(body_node);
		foreach (root : roots) builder.add_root(root);
	}
	else
	{
		uint placed = builder.add_node("crig:model_transform",
			translation: model_transform.location,
			rotation: model_transform.orientation());
		builder.add_child(placed, body_node);
		foreach (root : roots) builder.add_child(placed, root);
		builder.add_root(placed);
	}

	// The joint nodes here are bone-aligned rather than unrotated, so the capsule
	// child nodes are placed in that frame instead — one call, two conventions.
	write_rig_physics(allocator, &builder, skeleton, names, physics,
		joint_nodes.array_view(), rest);
	PhysicalBodyWriteReport generated = {};
	if (constraints.present())
	{
		generated = write_target_physical_bodies(allocator, &builder, mesh,
			skeleton, names, binding, constraints, joint_nodes.array_view(), rest,
			physics);
	}
	if (physical_report) *physical_report = generated;
	(void)write_rig_constraints(allocator, &builder, skeleton, names, constraints,
		joint_nodes.array_view(), rest);

	// --- the clips ----------------------------------------------------------

	foreach (template : templates)
	{
		if (template.keyframes.len == 0) continue;
		// Baked: this file is for a reader that has neither the curve nor the solve.
		write_animation(allocator, &builder, skeleton, names, template,
			rest, joint_nodes.array_view(), baked: true, constraints: constraints,
			motion: motion, report: motion_report);
	}

	return builder.save_glb(path);
}

<*
 The pose the template puts `skeleton` in at each of `times`.

 What `write_animation` keys its channels off, rather than reading the entries
 out of the keyframes directly. A template is not necessarily in the frame of the
 rig being written — a clip imported from one figure and exported on another is
 the ordinary case — and `AnimTemplate.pose` is where being carried onto a rig's
 own bones happens. Reading the entries raw would write a file that plays
 differently from the preview it was exported out of.

 The caller owns the poses; free them with `free_poses`.

 Constraints are evaluated before grounding, matching the viewport: limiting a
 leg can change the sole height which the ground pass then has to correct.

 @param grounded : `Whether the ground solve runs. False when the authored keys are being kept; see bake_times.`
 @param constraints : `Exact reusable limits to bake. Empty keeps the sampled pose unchanged.`
*>
fn rig::Pose[] poses_at_times(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	float[] times,
	bool grounded,
	ConstraintRig constraints = {}) @local
{
	rig::Pose[] posed = alloc::new_array(allocator, rig::Pose, (sz)times.len);
	foreach (usz k, time : times)
	{
		posed[k] = template.pose(allocator, skeleton, names, time, false, honor_solo: false);
		if (constraints.constrains_pose())
		{
			constrain_pose_to_constraint_rig(skeleton, constraints, &posed[k]);
		}
		if (grounded)
		{
			ground_pose(allocator, skeleton, names, template.ground, &posed[k],
				template.phase_at(time));
		}
		aim_export_pose(allocator, skeleton, names, template, time, constraints, &posed[k]);
	}
	return posed;
}

// How many samples each span between keyframes is cut into when a clip has to
// be baked. Four puts an eight-key cycle at a little over forty samples a
// second, which is above what a cubic needs to be indistinguishable and below
// what makes the file worth thinking about.
const usz ANIM_BAKE_STEPS @local = 4;
// An eased span bends its timing hardest at the flattened ends, which four
// straight pieces cut visibly short; this many keeps it within the replay
// tolerance an Auto curve is held to.
const usz ANIM_EASE_BAKE_STEPS @local = 16;

<*
 The times to sample a template at, and whether the ground solve should run
 while doing it.

 Two answers, and which one is wanted depends on who is reading the file:

 - **A crig pack keeps the authored keys.** Its clips are read back into
   templates that smooth and solve for themselves, so writing the solved result
   would bake one rig's leg proportions into the library permanently — the exact
   artefact `anim/ground.c3` exists to stop producing. Keyframe times, ground
   solve off.
 - **A file for somebody else's engine has to be baked.** glTF can say neither
   "Catmull-Rom with tangents that wrap through the loop point" nor "put the
   feet on the floor of whatever rig this lands on", so a smooth or grounded
   clip is written as a denser run of ordinary samples instead. The cost is file
   size; the alternative is a file that plays differently from the preview it
   came out of.

 A clip that is neither smooth nor grounded bakes to its own keyframes either
 way, so nothing already in the library grows.

 The caller owns the returned times.
*>
fn float[] bake_times(
	Allocator allocator,
	AnimTemplate template,
	bool bake,
	bool force_dense = false) @local
{
	float[] times = bake_key_times(allocator, template, bake, force_dense || template.plays_live_layers());
	// A target moves the head between the body's keys, so its key times are
	// samples too.
	if (bake) times = aim_sample_times(allocator, &template, times);
	if (bake) times = pin_sample_times(allocator, &template, times);
	// A layer adds motion between the base keys — a wave has none of its own —
	// so a baked clip also samples where the layers need it.
	if (bake) times = layer_sample_times(allocator, &template, times);
	return times;
}

fn float[] bake_key_times(
	Allocator allocator,
	AnimTemplate template,
	bool bake,
	bool force_dense = false) @local
{
	usz keys = template.keyframes.len;
	if (!bake || keys == 0)
	{
		float[] times = alloc::new_array(allocator, float, (sz)keys);
		foreach (usz k, frame : template.keyframes) times[k] = frame.time;
		return times;
	}
	bool wraps = keys > 0 && template.loop
		&& template.duration > template.keyframes[keys - 1].time + ANIM_EXPORT_EPSILON;
	bool leading_gap = template.keyframes[0].time > ANIM_EXPORT_EPSILON;
	bool trailing_gap = template.duration
		> template.keyframes[keys - 1].time + ANIM_EXPORT_EPSILON;
	bool auto_curve = template.uses_interpolation(AUTO);
	bool hold_curve = template.uses_interpolation(HOLD);
	bool eased = template.uses_easing();
	if (!auto_curve && !hold_curve && !eased && !template.ground.solves() && !force_dense)
	{
		usz leading = leading_gap ? 1 : 0;
		usz trailing = trailing_gap ? 1 : 0;
		float[] times = alloc::new_array(allocator, float, (sz)(leading + keys + trailing));
		usz at = 0;
		if (leading > 0) times[at++] = 0.0f;
		foreach (frame : template.keyframes) times[at++] = frame.time;
		if (trailing > 0) times[at] = template.duration;
		return times;
	}

	// A looping clip whose last key stops short of the duration comes back round
	// to the first over what is left, and that span is part of the cycle — so it
	// is sampled like any other and closed with the duration itself.
	usz spans = keys - 1 + (wraps || (!template.loop && trailing_gap) ? (usz)1 : (usz)0);
	usz steps = auto_curve || template.ground.solves() || force_dense ? ANIM_BAKE_STEPS : 1;
	if (eased) steps = ANIM_EASE_BAKE_STEPS;
	usz leading = leading_gap ? steps : 0;
	usz edges;
	if (hold_curve) for (usz s = 0; s < spans; s++)
	{
		float from = template.keyframes[s].time;
		float to = s + 1 < keys ? template.keyframes[s + 1].time : template.duration;
		if (anim_time_before(to) > from) edges++;
	}

	float[] times = alloc::new_array(allocator, float, (sz)(leading + spans * steps + edges + 1));
	usz at = leading;
	for (usz i = 0; i < leading; i++)
	{
		times[i] = template.keyframes[0].time * (float)i / (float)steps;
	}
	for (usz s = 0; s < spans; s++)
	{
		float from = template.keyframes[s].time;
		float to = s + 1 < keys ? template.keyframes[s + 1].time : template.duration;
		for (usz i = 0; i < steps; i++)
		{
			times[at++] = from + (to - from) * (float)i / (float)steps;
		}
		// glTF applies one interpolation mode to an entire sampler, while crig can
		// mix modes per outgoing segment. A sample on the adjacent float before a
		// key makes a baked LINEAR curve hold at every representable time before
		// the key and change on the key itself.
		float edge = anim_time_before(to);
		if (hold_curve && edge > from) times[at++] = edge;
	}
	times[at] = wraps || trailing_gap ? template.duration : template.keyframes[keys - 1].time;
	return times;
}

// A constraint turns a smooth input curve into a piecewise curve with a corner
// wherever an axis meets a limit. Four seed samples per authored span keep the
// ordinary case compact; recursive midpoint checks add detail only beside such
// corners. The cap is a corrupt/pathological-curve guard, not a target sample
// rate — normal clamped rotations add only a handful of samples per boundary.
const usz ANIM_CONSTRAINT_BAKE_DEPTH @local = 12;
const usz ANIM_CONSTRAINT_BAKE_SAMPLES @local = 65536;
const float ANIM_CONSTRAINT_ROTATION_ERROR @local = 1.0e-6f;
const float ANIM_CONSTRAINT_TRANSLATION_ERROR @local = 1.0e-5f;
// The width, in seconds, below which a span is never subdivided again. This is
// what makes re-baking idempotent, and idempotence is what keeps an in-place
// save from growing the file. `constrained_midpoint_misses` is an OR over every
// limited joint against a rotation tolerance of 1e-7 (~0.05 degrees each), so on
// a whole rig some joint almost always still "misses" a span's midpoint — which,
// without a floor, means a save re-subdivides the clip it just read from the
// file and writes back a denser one, every time, without end. Seeded from that
// denser clip the next save densifies again: a real 51-joint rig went 5.8MB to
// 24MB in a single 100-second save, and the next would have been worse — the
// "freeze". A corner localized to a millisecond is localized finely enough:
// that is sixteen samples inside a single 60fps frame, below anything visible,
// and a span already this narrow gets no new sample, so baking a baked clip
// reproduces it. The 12-deep / 65536-sample caps remain as pathology guards.
const float ANIM_CONSTRAINT_BAKE_MIN_SPAN @local = 1.0e-3f;

fn rig::Pose evaluated_export_pose(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	float time,
	bool grounded,
	ConstraintRig constraints) @local
{
	rig::Pose pose = template.pose(allocator, skeleton, names, time, false, honor_solo: false);
	constrain_pose_to_constraint_rig(skeleton, constraints, &pose);
	if (grounded)
	{
		ground_pose(allocator, skeleton, names, template.ground, &pose,
			template.phase_at(time));
	}
	aim_export_pose(allocator, skeleton, names, template, time, constraints, &pose);
	return pose;
}

// The clip's aims laid over an exported pose, after constraints and grounding as
// in the viewport, held inside the constraint table when there is one.
fn void aim_export_pose(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	float time,
	ConstraintRig constraints,
	rig::Pose* pose) @local
{
	if (!template.plays_live_layers()) return;
	ConstraintRig held = constraints;
	ConstraintAimContext ctx = { .skeleton = skeleton, .constraints = &held };
	// Pins before aims, the viewport's order.
	pin_pose(allocator, skeleton, names, template.pins, time, template.duration, template.loop,
		pose, skeleton.height(), constraints.constrains_pose() ? &constraint_rig_aim_clamp : null, &ctx);
	if (!template.plays_aims()) return;
	aim_pose(allocator, skeleton, names, template.aims, template.aim_targets, time, template.duration, template.loop,
		pose, skeleton.height(), constraints.constrains_pose() ? &constraint_rig_aim_clamp : null, &ctx);
}

// Whether linear glTF interpolation between the two exported endpoint poses
// misses the constrained viewport at their midpoint.
fn bool constrained_midpoint_misses(
	rig::Skeleton* skeleton,
	ConstraintRig constraints,
	rig::Pose* from,
	rig::Pose* middle,
	rig::Pose* to,
	bool grounded) @local
{
	usz joints = skeleton.len();
	if (constraints.joints.len < joints) joints = constraints.joints.len;
	if (from.rotations.len < joints) joints = from.rotations.len;
	if (middle.rotations.len < joints) joints = middle.rotations.len;
	if (to.rotations.len < joints) joints = to.rotations.len;

	for (usz joint = 0; joint < joints; joint++)
	{
		if (constraints.joints[joint].status != EXACT) continue;
		Quaternionf predicted = from.rotations[joint]
			.slerp(to.rotations[joint], 0.5f).normalize();
		float error = 1.0f - math::abs(predicted.v.dot(middle.rotations[joint].v));
		if (error > ANIM_CONSTRAINT_ROTATION_ERROR) return true;
	}

	// Constraints do not alter translations directly. They can alter the root
	// lift made by grounding, so only grounded exports need this second check.
	if (!grounded) return false;
	usz offsets = skeleton.len();
	if (from.offsets.len < offsets) offsets = from.offsets.len;
	if (middle.offsets.len < offsets) offsets = middle.offsets.len;
	if (to.offsets.len < offsets) offsets = to.offsets.len;
	float scale = math::max(skeleton.height(), 1.0f);
	float tolerance = scale * ANIM_CONSTRAINT_TRANSLATION_ERROR;
	float tolerance_sq = tolerance * tolerance;
	for (usz joint = 0; joint < offsets; joint++)
	{
		Vec3 predicted = (from.offsets[joint] + to.offsets[joint]) * 0.5f;
		if ((predicted - middle.offsets[joint]).length_sq() > tolerance_sq) return true;
	}
	return false;
}

fn void append_constraint_bake_span(
	Allocator allocator,
	List{float}* times,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	ConstraintRig constraints,
	float from_time,
	rig::Pose* from,
	float to_time,
	rig::Pose* to,
	usz depth) @local
{
	if (depth >= ANIM_CONSTRAINT_BAKE_DEPTH
		|| (usz)times.len() >= ANIM_CONSTRAINT_BAKE_SAMPLES)
	{
		times.push(to_time);
		return;
	}

	// The width floor: a span this narrow already localizes any corner it holds
	// finely enough, and refusing to split it is what makes a re-bake idempotent
	// — see ANIM_CONSTRAINT_BAKE_MIN_SPAN. Without it, a save densifies the clip
	// it read from the file and the file grows on every save.
	if (to_time - from_time <= ANIM_CONSTRAINT_BAKE_MIN_SPAN)
	{
		times.push(to_time);
		return;
	}

	float middle_time = from_time + (to_time - from_time) * 0.5f;
	// Adjacent floats are used to preserve HOLD discontinuities. There is no
	// representable time between them, hence no midpoint worth refining.
	if (!(middle_time > from_time) || !(middle_time < to_time))
	{
		times.push(to_time);
		return;
	}

	rig::Pose middle = evaluated_export_pose(allocator, skeleton, names, template,
		middle_time, true, constraints);
	defer middle.free(allocator);
	if (!constrained_midpoint_misses(skeleton, constraints, from, &middle, to,
		template.ground.solves()))
	{
		times.push(to_time);
		return;
	}

	append_constraint_bake_span(allocator, times, skeleton, names, template,
		constraints, from_time, from, middle_time, &middle, depth + 1);
	append_constraint_bake_span(allocator, times, skeleton, names, template,
		constraints, middle_time, &middle, to_time, to, depth + 1);
}

fn float[] refine_constraint_bake_times(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	ConstraintRig constraints,
	float[] seed) @local
{
	if (seed.len == 0) return {};

	List{float} refined;
	refined.init(allocator);
	defer refined.free();
	refined.push(seed[0]);

	for (usz span = 0; span + 1 < seed.len; span++)
	{
		float from_time = seed[span];
		float to_time = seed[span + 1];
		rig::Pose from = evaluated_export_pose(allocator, skeleton, names, template,
			from_time, true, constraints);
		rig::Pose to = evaluated_export_pose(allocator, skeleton, names, template,
			to_time, true, constraints);
		append_constraint_bake_span(allocator, &refined, skeleton, names, template,
			constraints, from_time, &from, to_time, &to, 0);
		from.free(allocator);
		to.free(allocator);
	}
	return refined.to_array(allocator);
}

fn float[] export_bake_times(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	bool baked,
	ConstraintRig constraints,
	bool force_dense = false) @local
{
	bool constrained = baked && constraints.constrains_pose();
	// The seed is deliberately sparse on the constrained path: the adaptive
	// `refine_constraint_bake_times` below places a sample only where the
	// constrained curve actually bends. Re-baking must be idempotent, or an
	// in-place save densifies the clip it just read from the file and the file
	// grows without end — a rig's limits are file metadata read back on every
	// save, so nothing stops it. A single limited joint converges under the
	// rotation tolerance on its own, but the check is an OR over every limited
	// joint, so on a whole rig some joint almost always still misses and the
	// spans subdivide forever; ANIM_CONSTRAINT_BAKE_MIN_SPAN is the width floor
	// that makes the refine converge and reproduce an already-refined clip. Auto
	// and ground clips still densify once through bake_times' own checks; that
	// densification is not written back as auto or ground, so it cannot repeat.
	float[] seed = bake_times(allocator, template, baked, force_dense);
	if (!constrained) return seed;

	// Collapse runs finer than the width floor before refining. A pure-linear clip
	// samples between its own keys, so keys closer than the floor carry no detail
	// the bake keeps — and a clip an earlier over-refinement collapsed to
	// microsecond spacing (a corner chased toward the sample cap) would otherwise
	// re-cost its whole sample count on every save, both in time and in file size.
	// Only the pure-linear seed is safe to thin: an auto or ground seed is
	// deliberately dense across each span for a curve the floor does not describe,
	// and its samples are left alone.
	bool plain_linear = !template.plays_layers(false) && !template.plays_live_layers() && !template.uses_interpolation(AUTO)
		&& !template.uses_interpolation(HOLD) && !template.uses_easing()
		&& !template.ground.solves();
	if (plain_linear) seed = decimate_below_floor(seed, ANIM_CONSTRAINT_BAKE_MIN_SPAN);

	float[] refined = refine_constraint_bake_times(allocator, skeleton, names,
		template, constraints, seed);
	alloc::free(allocator, seed);
	return refined;
}

// Drop samples closer together than `floor`, keeping the first and last so the
// clip's length is untouched. Compacts the array in place and returns the live
// prefix, which aliases the input's buffer — the caller still owns and frees it.
// A clip already spaced above the floor keeps every sample.
fn float[] decimate_below_floor(float[] seed, float floor) @local
{
	if (seed.len <= 2) return seed;
	usz n = 1; // seed[0] is always kept
	for (usz i = 1; i + 1 < seed.len; i++)
	{
		if (seed[i] - seed[n - 1] < floor) continue;
		seed[n++] = seed[i];
	}
	// The final time defines the sampler's length and is always kept. If it crowds
	// the last survivor, it takes that slot rather than adding a sub-floor span.
	float end = seed[seed.len - 1];
	if (n > 1 && end - seed[n - 1] < floor) { seed[n - 1] = end; }
	else { seed[n++] = end; }
	return seed[:n];
}

// The preceding positive float. Animation times are non-negative, so their
// IEEE-754 ordering is the same as their unsigned bit ordering.
fn float anim_time_before(float time) @local
{
	if (!(time > 0.0f)) return time;
	uint bits = bitcast(time, uint);
	return bitcast(bits - 1, float);
}

fn void free_poses(Allocator allocator, rig::Pose[] posed) @local
{
	foreach (&pose : posed) pose.free(allocator);
	if (posed.len > 0) alloc::free(allocator, posed);
}

alias AttributeList = List{gltf::WriteAttribute};

// One node per joint: named, translated to where the joint rests relative to
// its parent, and left unrotated. See the note at the top about why the
// rotation is identity.
//
// Two passes, because add_child takes indices and every node has to exist
// before anyone can be named as a child. A joint with no parent is a scene root
// — that is also what makes a body-less pack a document with content in it.
fn void write_joint_nodes(gltf::GltfBuilder* builder, rig::Skeleton* skeleton, String[] names) @local
{
	usz joints = skeleton.len();

	for (usz j = 0; j < joints; j++)
	{
		builder.add_node(names[j], translation: rest_offset(skeleton, j));
	}

	for (usz j = 0; j < joints; j++)
	{
		int parent = skeleton.parents[j];
		if (parent >= 0 && (usz)parent < joints)
		{
			builder.add_child((uint)parent, (uint)j);
			continue;
		}
		builder.add_root((uint)j);
	}
}

// Where a joint rests relative to its parent, which is what a node's
// translation holds — and, for a rootless joint, where it rests outright.
fn Vec3 rest_offset(rig::Skeleton* skeleton, usz joint) @local
{
	int parent = skeleton.parents[joint];
	if (parent < 0 || (usz)parent >= skeleton.len()) return skeleton.joints[joint];
	return skeleton.joints[joint] - skeleton.joints[(usz)parent];
}

<*
 What the clips say about themselves that glTF has no channel for: the blend
 mode, the ground spec and a cycle's trailing span, as one JSON object under
 `PACK_KEY_CLIPS`.

 Written only for the clips that have something to say, and not at all when none
 of them does — a linear ungrounded pack is the ordinary case and should not
 grow a key for it. The animation channels are the clip; this is the part a
 reader has to be told rather than shown.

 **The duration is written whenever the last key stops short of it.** A glTF
 sampler's length is the time of its last sample, so a cycle whose closing span
 is the wrap back to key 0 — the eight-key form, where the ninth key would only
 restate the first — loses that span on the way in and comes back a keyframe
 short. The reader then times the contact windows and the wrap tangent against a
 cycle that is not the authored one.

 **The key schedule is left to whoever already holds it.** A model saved beside
 its `<stem>.rigsmith.json` keeps every authored clip's keys there in full, so a
 copy in the model's extras is only weight — for a walk optimized to whole
 keys, hundreds of kilobytes of it. Those clips are named in `scheduled_elsewhere`
 and get the settings without the `sparse` member. A library pack has no sidecar
 and passes nothing, so its clips keep their schedule.

 A key that keys every joint the clip keys, both channels and nothing else said,
 is written `"dots":"all"` rather than as the list — see `apply_clip_extras`.

 @param scheduled_elsewhere : `Clips, by name, whose key schedule lives in a sidecar and is left out here.`
*>
fn String clip_extras_text(Allocator allocator, AnimTemplate[] templates, String[] scheduled_elsewhere = {})
{
	DString out = dstring::new(allocator);
	defer out.free();

	usz written = 0;
	foreach (template : templates)
	{
		usz keys = template.keyframes.len;
		if (keys == 0) continue;


		out.append_char(written == 0 ? '{' : ',');
		out.append_char('"');
		json_escape_into(&out, template.name);
		out.append_string(`":{`);

		// A layered clip's file channels are the flattened stack, not its base keys:
		// the base's blend and key schedule describe neither, and a reader applying
		// them would filter the baked layers back out. Its layers live in the
		// project sidecar; the file only says how long it is, whether it loops and
		// where it stands.
		bool flattened = template.plays_layers(false);

		usz fields = 0;
		out.appendf(`"duration":%s,"loop":%s`, (JsonFloat)template.duration, template.loop)!!;
		fields = 2;
		if (template.blend == SMOOTH && !flattened)
		{
			out.append_string(`,"blend":"smooth"`);
			fields++;
		}
		if (template.ground.solves())
		{
			if (fields++ > 0) out.append_char(',');
			out.append_string(`"ground":{`);
			if (template.ground.floor_set) out.appendf(`"floor":%s,`, (JsonFloat)template.ground.floor);
			out.append_string(`"feet":[`);
			foreach (usz f, foot : template.ground.feet)
			{
				if (f > 0) out.append_char(',');
				out.append_string(`{"joint":"`);
				json_escape_into(&out, foot.joint);
				out.appendf(`","down":%s,"up":%s`, (JsonFloat)foot.down, (JsonFloat)foot.up);
				out.append_string(foot.off_floor ? `,"off_floor":true}` : "}");
			}
			out.append_string("]}");
		}
		// glTF's shared sample times cannot say which per-joint values were authored
		// keys. Keep that schedule for every pack clip, including plain LINEAR ones.
		bool elsewhere = false;
		foreach (name : scheduled_elsewhere) if (name == template.name) elsewhere = true;
		if (template.keyframes.len > 0 && !flattened && !elsewhere)
		{
			if (fields++ > 0) out.append_char(',');
			// The joints `"dots":"all"` stands for, named once for the clip.
			List{String} keyed = keyed_joints(template);
			bool shorthand = false;
			foreach (key : template.keyframes) if (keys_every_joint_plainly(key, (usz)keyed.len())) shorthand = true;
			if (shorthand)
			{
				out.append_string(`"keyed":[`);
				foreach (usz n, name : keyed)
				{
					if (n > 0) out.append_char(',');
					out.append_char('"');
					json_escape_into(&out, name);
					out.append_char('"');
				}
				out.append_string("],");
			}
			usz joints = shorthand ? (usz)keyed.len() : 0;
			out.append_string(`"sparse":[`);
			usz scheduled = 0;
			foreach (usz k, key : template.keyframes)
			{
				if (key.dots.len == 0) continue;
				if (scheduled++ > 0) out.append_char(',');
				if (keys_every_joint_plainly(key, joints))
				{
					out.appendf(`{"time":%s,"dots":"all"}`, (JsonFloat)key.time)!!;
					continue;
				}
				out.appendf(`{"time":%s,"dots":[`, (JsonFloat)key.time)!!;
				foreach (usz d, dot : key.dots)
				{
					if (d > 0) out.append_char(',');
					out.append_string(`{"joint":"`);
					json_escape_into(&out, dot.joint_name);
					out.appendf(`","channels":"%s"`, dot.channels == ROTATION
						? "rotation" : (dot.channels == TRANSLATION ? "translation" : "both"))!!;
					if (dot.rotation_interpolation != INHERIT)
					{
						out.appendf(`,"rotation_interpolation":"%s"`, dot.rotation_interpolation.serialized())!!;
					}
					if (dot.translation_interpolation != INHERIT)
					{
						out.appendf(`,"translation_interpolation":"%s"`, dot.translation_interpolation.serialized())!!;
					}
					if (dot.keys_rotation()) append_ease_field(&out, "rotation_ease", dot.rotation_ease);
					if (dot.keys_translation()) append_ease_field(&out, "translation_ease", dot.translation_ease);
					out.append_char('}');
				}
				out.append_string("]}");
			}
			out.append_char(']');
		}

		out.append_char('}');
		written++;
	}
	if (written == 0) return "";

	out.append_char('}');
	return out.copy_str(allocator);
}

// The distinct joints the clip keys anywhere, in the order they are first keyed.
// Temp-allocated.
fn List{String} keyed_joints(AnimTemplate template) @local
{
	List{String} seen;
	seen.init(tmem);
	foreach (key : template.keyframes)
	{
		foreach (dot : key.dots)
		{
			bool known = false;
			foreach (name : seen) if (name == dot.joint_name) { known = true; break; }
			if (!known) seen.push(dot.joint_name);
		}
	}
	return seen;
}

// Whether `key` keys all `joints` of its clip, each once, on both channels, with
// no interpolation or ease of its own: the key `"dots":"all"` stands for.
fn bool keys_every_joint_plainly(AnimKeyframe key, usz joints) @local
{
	if (joints == 0 || key.dots.len != joints) return false;
	foreach (usz d, dot : key.dots)
	{
		if (dot.channels != BOTH) return false;
		if (dot.rotation_interpolation != INHERIT || dot.translation_interpolation != INHERIT) return false;
		if (!dot.rotation_ease.none() || !dot.translation_ease.none()) return false;
		for (usz e = 0; e < d; e++) if (key.dots[e].joint_name == dot.joint_name) return false;
	}
	return true;
}

// The pack's own `extras`, or nothing when it has nothing to say. A file with
// no extras is still a pack — see anim/pack.c3 — so an empty meta is not
// an error, it is the untagged case.
fn void write_pack_extras(Allocator allocator, gltf::GltfBuilder* builder, AnimPackMeta meta) @local
{
	bool declared = meta.plan.len > 0 || meta.name.len > 0 || meta.tags.len > 0
		|| meta.version > 0 || meta.optional.len > 0;
	if (!declared) return;

	if (meta.name.len > 0) builder.set_extra(PACK_KEY_NAME, meta.name);
	if (meta.plan.len > 0) builder.set_extra(PACK_KEY_PLAN, meta.plan);

	DString scratch = dstring::new(allocator);
	defer scratch.free();

	if (meta.tags.len > 0)
	{
		// One comma-separated string, because a glTF reader keeps only string
		// values out of extras and an array would be dropped on the way back in.
		foreach (i, tag : meta.tags)
		{
			if (i > 0) scratch.append_string(", ");
			scratch.append_string(tag);
		}
		builder.set_extra(PACK_KEY_TAGS, scratch.str_view());
		scratch.clear();
	}

	if (meta.optional.len > 0)
	{
		// One string, comma-separated, for the same reason the tags are. Unlike
		// them these are matched back exactly rather than folded — see
		// `mark_optional` — so what goes in is the joint name and nothing else.
		foreach (i, joint : meta.optional)
		{
			if (i > 0) scratch.append_char(',');
			scratch.append_string(joint);
		}
		builder.set_extra(PACK_KEY_OPTIONAL, scratch.str_view());
		scratch.clear();
	}

	scratch.appendf("%d", meta.version > 0 ? meta.version : PACK_VERSION)!!;
	builder.set_extra(PACK_KEY_VERSION, scratch.str_view());
}

<*
 One glTF animation per template: a shared run of key times, then a rotation
 channel per joint that turns and a translation channel per joint that moves.

 A joint that does neither gets no channel at all rather than a run of
 identities. Its node already holds the rest transform those channels would
 repeat, and it is what the importer makes of a missing channel on the way back
 in, so the two agree about what an untouched joint looks like.

 **The two node frames are one formula.** crig poses a joint as a rotation `q`
 about its own rest position in world axes, and writes a pack whose nodes carry
 no rotation at all. A bone-aligned node instead rests at `rest[j]`, so the same
 pose becomes its local rotation

 	`conj(rest[parent]) * q * rest[j]`

 and the same slide becomes its local translation

 	`conj(rest[parent]) * (joint - parent_joint + offset)`

 with the parent's rotation taken as identity for a root. Both fall out of
 requiring the posed world transform to deform the skin identically in either
 frame, and both reduce at rest — `q` identity, no offset — to exactly what
 `gltf::add_skeleton` wrote into the node. Set every `rest[j]` to the identity
 and they reduce further, to `q` and `joint - parent_joint + offset`: the
 unrotated frame is the aligned one with nothing to rotate into. That is why
 `rest` being absent is all the switch this needs.

 @param names : `One per joint, in joint order — the template addresses joints by name.`
 @param rest : `A bone-aligned node's rest rotation per joint. Empty writes crig's own unrotated frame.`
 @param joint_nodes : `Which glTF node each joint became. Short or empty means node j is joint j.`
 @param baked : `Whether to resample the curve and run the ground solve. See bake_times for which reader wants which.`
 @param constraints : `Exact limits to evaluate into ordinary channels on a baked game export. Empty on a reusable pack keeps its authored curve.`
 @param into : `An animation already begun to add these channels to, or -1 for one of its own named after the clip.`
 @param timing : `A scene's clock to key on instead of the clip's own: see SceneTiming.`
*>
fn void write_animation(
	Allocator allocator,
	gltf::GltfBuilder* builder,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	Quaternionf[] rest = {},
	uint[] joint_nodes = {},
	bool baked = false,
	ConstraintRig constraints = {},
	ExportMotion motion = {},
	ExportMotionReport* report = null,
	int into = -1,
	SceneTiming timing = {}) @local
{
	usz joints = skeleton.len();
	bool aligned = rest.len >= joints;
	if (!baked || timing.active) motion = {};

	float[] times = timing.active
		? timing.grid(allocator)
		: export_bake_times(allocator, skeleton, names, template, baked, constraints, motion.dense());
	defer alloc::free(allocator, times);

	// On a scene's clock the file is keyed at the scene's instants and the clip is
	// sampled at where it stands at each: wrapped when it loops, held at its ends
	// when it does not.
	float[] sampled = times;
	if (timing.active)
	{
		sampled = alloc::new_array(allocator, float, (sz)times.len);
		foreach (usz k, t : times) sampled[k] = timing.local(template, t);
	}
	defer if (timing.active) alloc::free(allocator, sampled);

	// The ground solve runs on exactly the files that are baked. A pack keeps the
	// authored keys because it is read back into a template that solves for
	// itself, and solving on the way out would bake this rig's leg proportions
	// into the library; a file for someone else's engine has neither the solver
	// nor the curve, so both have to be resolved here.
	rig::Pose[] posed = poses_at_times(allocator, skeleton, names, template, sampled,
		baked, constraints);
	defer free_poses(allocator, posed);
	usz baked_keys = times.len;
	if (!timing.active)
	{
		shape_export_samples(allocator, skeleton, names, template, constraints, baked,
			motion, &times, &posed, report);
	}
	usz keys = times.len;
	usz channels = 0;

	// One input accessor for the whole clip: every joint is keyed at the same
	// times, so every sampler below shares this one.
	uint input = builder.add_times(times);
	uint clip = into >= 0 ? (uint)into : builder.add_animation(template.name);

	// A channel that holds one value the whole clip is written as that value at
	// the first time, against a one-key input every such channel shares: a walk's
	// still bones are most of its channels, and repeating each value at every
	// sample was most of the file. A reader holds a one-key sampler at its value
	// (glTF's clamp, and `sample_at`'s). Only when something in the clip moves —
	// the moving channels are what carry its length, which a clip made of nothing
	// but held channels would otherwise lose.
	bool moves = false;
	for (usz j = 0; j < joints && !moves; j++)
	{
		for (usz k = 1; k < keys; k++)
		{
			if (!same_turn(posed[k].rotations[j], posed[0].rotations[j])
				|| (posed[k].offsets[j] - posed[0].offsets[j]).length() > ANIM_EXPORT_EPSILON)
			{
				moves = true;
				break;
			}
		}
	}
	uint held_input;
	bool held_input_written = false;

	Quaternionf[] turns = alloc::new_array(allocator, Quaternionf, (sz)keys);
	Vec3[] slides = alloc::new_array(allocator, Vec3, (sz)keys);
	defer
	{
		alloc::free(allocator, turns);
		alloc::free(allocator, slides);
	}

	const Quaternionf UNROTATED = { 0, 0, 0, 1 };

	for (usz j = 0; j < joints; j++)
	{
		int parent = skeleton.parents[j];
		bool rooted = parent < 0 || (usz)parent >= joints;

		// A root expresses itself in the scene, which has no rotation of its own.
		Quaternionf into_parent = aligned && !rooted ? rest[(usz)parent].conjugate() : UNROTATED;
		Quaternionf frame = aligned ? rest[j] : UNROTATED;
		Vec3 local = rest_offset(skeleton, j);

		bool turning = false;
		bool sliding = false;
		foreach (keyframe : template.keyframes)
		{
			foreach (dot : keyframe.dots)
			{
				if (dot.joint_name != names[j]) continue;
				if (dot.keys_rotation()) turning = true;
				if (dot.keys_translation()) sliding = true;
			}
		}

		for (usz k = 0; k < keys; k++)
		{
			Quaternionf turn = posed[k].rotations[j];
			if (math::abs(math::abs(turn.v.w) - 1.0f) > ANIM_EXPORT_EPSILON) turning = true;
			turns[k] = into_parent * turn * frame;

			Vec3 move = posed[k].offsets[j];
			if (move.length() > ANIM_EXPORT_EPSILON) sliding = true;
			slides[k] = into_parent * (local + move);
		}

		uint node = j < joint_nodes.len ? joint_nodes[j] : (uint)j;
		if (turning) channels++;
		if (sliding) channels++;
		bool turn_held = moves;
		bool slide_held = moves;
		for (usz k = 1; k < keys; k++)
		{
			if (!same_turn(turns[k], turns[0])) turn_held = false;
			if ((slides[k] - slides[0]).length() > ANIM_EXPORT_EPSILON) slide_held = false;
		}
		if ((turning && turn_held) || (sliding && slide_held))
		{
			if (!held_input_written) held_input = builder.add_times(times[:1]);
			held_input_written = true;
		}
		if (turning)
		{
			uint sampler = turn_held
				? builder.add_sampler(clip, held_input, builder.add_rotations(turns[:1]))
				: builder.add_sampler(clip, input, builder.add_rotations(turns));
			builder.add_channel(clip, sampler, node, gltf::AnimationProperty.ROTATION);
		}
		if (sliding)
		{
			uint sampler = slide_held
				? builder.add_sampler(clip, held_input, builder.add_vectors(slides[:1]))
				: builder.add_sampler(clip, input, builder.add_vectors(slides));
			builder.add_channel(clip, sampler, node, gltf::AnimationProperty.TRANSLATION);
		}
	}
	if (report) report.count(baked_keys, keys, channels);
}

<*
 A scene's clock, for keying every character of a cutscene on one timeline.

 Every character's clip is sampled at the same instants, from 0 to the scene's
 length, so the channels of two characters line up key for key in the one
 animation they share — whatever each clip's own length.
*>
struct SceneTiming
{
	bool active;
	float duration;
	float fps;
}

// The instants a scene is keyed at, both ends included. The caller owns them.
fn float[] SceneTiming.grid(self, Allocator allocator)
{
	float fps = self.fps > 0.0f ? self.fps : 30.0f;
	usz steps = math::max((usz)math::ceil(self.duration * fps), (usz)1);
	float[] times = alloc::new_array(allocator, float, (sz)steps + 1);
	foreach (usz k, &t : times) *t = math::min((float)k / fps, self.duration);
	return times;
}

// Where in its own clip a character stands at scene time `t`.
fn float SceneTiming.local(self, AnimTemplate template, float t)
{
	if (template.duration <= 0.0f || t <= 0.0f) return 0.0f;
	if (template.loop) return t - math::floor(t / template.duration) * template.duration;
	return math::min(t, template.duration);
}

<*
 One character of a combined scene export: its body, its skeleton and the clip
 it plays. Everything is borrowed for the call.
*>
struct SceneExportCharacter
{
	rig::TriMesh mesh;
	rig::Skeleton* skeleton;
	String[] names;
	// [vertices, joints] weights; short or mismatched falls back to distance weights.
	float[] skin;
	// What its nodes are prefixed with, unique within the file.
	String name;
	ProjectTransform transform;
	AnimTemplate clip;
	bool animated;
}

<*
 Write several rigged characters into one .glb, with one animation that moves
 them all together — what a cutscene is handed to an engine as.

 	`crig::export_scene_glb(mem, "duel.glb", cast, "Duel", 4.0f)!;`

 Each character is written the way `export_rigged_animated_glb` writes one —
 bone-aligned joints, its own mesh and skin — under a node of its own name that
 carries where it stands. Every node it owns is prefixed `name:`, so two
 characters with a `hips` each are two different nodes a reader can tell apart,
 and the one animation holds every character's channels, keyed on the scene's
 clock rather than on any one clip's.

 Physics and joint limits are left out: they are per-character data a scene file
 has no place for yet, and each character's own export still carries them.

 @param animation : `The shared animation's name.`
 @param duration : `The scene's length in seconds; every clip is sampled across it.`
 @return? ANIM_EXPORT_SHAPE_MISMATCH : `A character's skeleton is empty, or it has fewer names than joints.`
 @return? ANIM_EXPORT_UNNAMED_JOINT : `A joint has no name, so no clip could ever address it.`
 @return? gltf::WRITE_FAILED : `The file could not be opened, written or flushed.`
*>
fn void? export_scene_glb(
	Allocator allocator,
	String path,
	SceneExportCharacter[] cast,
	String animation,
	float duration,
	float fps = 30.0f)
{
	foreach (c : cast)
	{
		usz joints = c.skeleton.len();
		if (joints == 0 || c.names.len < joints) return ANIM_EXPORT_SHAPE_MISMATCH~;
		foreach (joint_name : c.names[:joints]) if (joint_name.len == 0) return ANIM_EXPORT_UNNAMED_JOINT~;
	}

	gltf::GltfBuilder builder = gltf::builder(allocator);
	defer builder.free();
	builder.generator = "rigsmith";

	List{uint}[] nodes = alloc::new_array(allocator, List{uint}, (sz)cast.len);
	Quaternionf[][] rests = alloc::new_array(allocator, Quaternionf[], (sz)cast.len);
	defer
	{
		foreach (&list : nodes) list.free();
		foreach (rest : rests) if (rest.len > 0) alloc::free(allocator, rest);
		alloc::free(allocator, nodes);
		alloc::free(allocator, rests);
	}

	foreach (usz i, c : cast)
	{
		usz joints = c.skeleton.len();
		Vec3[] tails = c.skeleton.tails(allocator);
		defer alloc::free(allocator, tails);
		String[] prefixed = alloc::new_array(allocator, String, (sz)joints);
		defer
		{
			foreach (s : prefixed) s.free(allocator);
			alloc::free(allocator, prefixed);
		}
		gltf::Bone[] bones = alloc::new_array(allocator, gltf::Bone, (sz)joints);
		defer alloc::free(allocator, bones);
		for (usz j = 0; j < joints; j++)
		{
			prefixed[j] = string::format(allocator, "%s:%s", c.name, c.names[j]);
			bones[j] = {
				.name = prefixed[j],
				.parent = c.skeleton.parents[j],
				.position = c.skeleton.joints[j],
				.direction = tails[j] - c.skeleton.joints[j],
			};
		}
		rests[i] = gltf::bone_rotations(allocator, bones);

		bool predicted = c.skin.len == c.mesh.positions.len * joints;
		float[] weights = predicted
			? c.skin
			: rig::bind_geometric(allocator, c.mesh.positions, c.skeleton.joints, c.skeleton.parents);
		defer if (!predicted) alloc::free(allocator, weights);
		gltf::SkinBinding binding = gltf::sparsify_weights(allocator, weights, c.mesh.positions.len, joints, 4)!;
		defer binding.free(allocator);

		AttributeList attributes;
		attributes.init(allocator);
		defer attributes.free();
		attributes.push({ .name = "POSITION", .accessor = builder.add_positions(c.mesh.positions) });
		if (c.mesh.has_normals()) attributes.push({ .name = "NORMAL", .accessor = builder.add_vec3(c.mesh.normals) });
		builder.add_skin_binding(binding, &attributes);
		uint body = builder.add_mesh(c.name);
		builder.add_primitive(body, attributes.array_view(),
			indices: c.mesh.indices.len > 0 ? (int)builder.add_indices(c.mesh.indices) : -1);

		nodes[i].init(allocator);
		List{uint} roots;
		roots.init(allocator);
		defer roots.free();
		uint inverse_bind = builder.add_skeleton(bones, &nodes[i], &roots);
		int common = roots.len() == 1 ? (int)roots.get(0) : -1;
		uint skin_index = builder.add_skin(c.name, nodes[i].array_view(),
			inverse_bind: (int)inverse_bind, skeleton: common);

		// One node per character carrying where it stands, holding its body and its
		// skeleton — a skinned mesh ignores its own transform, so the placement has
		// to sit above both, as `export_rigged_animated_glb` places one model.
		String body_name = string::format(allocator, "%s:body", c.name);
		defer body_name.free(allocator);
		uint body_node = builder.add_node(body_name, mesh: (int)body, skin: (int)skin_index);
		uint placed = builder.add_node(c.name,
			translation: c.transform.location,
			rotation: c.transform.orientation());
		builder.add_child(placed, body_node);
		foreach (root : roots) builder.add_child(placed, root);
		builder.add_root(placed);
	}

	uint shared = builder.add_animation(animation);
	SceneTiming timing = { .active = true, .duration = duration, .fps = fps };
	foreach (usz i, c : cast)
	{
		if (!c.animated || c.clip.keyframes.len == 0) continue;
		write_animation(allocator, &builder, c.skeleton, c.names, c.clip,
			rests[i], nodes[i].array_view(), baked: true, into: (int)shared, timing: timing);
	}
	return builder.save_glb(path);
}

// Whether two rotations are the same turn, either sign of the quaternion. By
// component rather than by their dot product, which near 1 cannot tell apart
// turns a tenth of a degree apart.
fn bool same_turn(Quaternionf a, Quaternionf b) @local
{
	float dot = a.v.x * b.v.x + a.v.y * b.v.y + a.v.z * b.v.z + a.v.w * b.v.w;
	float sign = dot < 0.0f ? -1.0f : 1.0f;
	return math::abs(a.v.x - sign * b.v.x) <= ANIM_EXPORT_EPSILON
		&& math::abs(a.v.y - sign * b.v.y) <= ANIM_EXPORT_EPSILON
		&& math::abs(a.v.z - sign * b.v.z) <= ANIM_EXPORT_EPSILON
		&& math::abs(a.v.w - sign * b.v.w) <= ANIM_EXPORT_EPSILON;
}

<*
 Templates as curves against a re-rooted skeleton, for `gltf_edit::reskin_glb`.

 	`gltf_edit::ReskinClip[] clips = crig::reskin_clips(mem, &view.skeleton, view.names, pack.clips);`
 	`defer crig::free_reskin_clips(mem, clips);`

 The same conversion `write_animation` makes, through the same `bake_times` and
 `poses_at_times`, because a clip written *into* a model has to play the way the
 same clip exported *beside* it plays and two formulas that agree today are still
 two formulas.

 **Baked**, for the reason `bake_times` gives: a model rewritten in place is a
 file for somebody else's engine, and Blender has neither crig's curve nor its
 ground solve, so both are resolved here into ordinary samples.

 The frame is crig's own unrotated one — which is exactly what `reskin_glb`
 writes, every joint node a pure translation with no rotation of its own. That is
 what makes this so much shorter than `write_animation`: with no bone-aligned
 rest to compose through, a joint's local rotation *is* the pose's rotation and
 its local translation is the rest offset plus whatever the pose slid it by.

 A joint that neither turns nor slides across the whole clip gets neither curve,
 which is what a reader makes of a missing channel — so the file says "untouched"
 the same way it would have.

 The caller owns the result; release it with `free_reskin_clips`.

 @param names : `One per joint, in joint order — a template addresses joints by name.`
 @param constraints : `Exact target limits to evaluate before the ordinary reskin curves are built.`
 @return `One entry per template that had anything to say. A template naming no joint of this skeleton is dropped rather than written as a clip that moves nothing.`
*>
fn gltf_edit::ReskinClip[] reskin_clips(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate[] templates,
	ConstraintRig constraints = {},
	ExportMotion motion = {},
	ExportMotionReport* report = null)
{
	if (templates.len == 0 || skeleton.len() == 0) return {};

	List{gltf_edit::ReskinClip} out;
	out.init(allocator);
	defer out.free();

	usz joints = skeleton.len();

	foreach (template : templates)
	{
		float[] times = export_bake_times(allocator, skeleton, names, template, true,
			constraints, motion.dense());
		bool kept = false;
		defer if (!kept) alloc::free(allocator, times);
		if (times.len == 0) continue;

		rig::Pose[] posed = poses_at_times(allocator, skeleton, names, template,
			times, true, constraints);
		defer free_poses(allocator, posed);
		usz baked_keys = times.len;
		shape_export_samples(allocator, skeleton, names, template, constraints, true,
			motion, &times, &posed, report);

		List{gltf_edit::ReskinCurve} curves;
		curves.init(allocator);

		for (usz j = 0; j < joints; j++)
		{
			bool turning = false;
			bool sliding = false;
			foreach (keyframe : template.keyframes) foreach (dot : keyframe.dots)
			{
				if (dot.joint_name != names[j]) continue;
				if (dot.keys_rotation()) turning = true;
				if (dot.keys_translation()) sliding = true;
			}
			for (usz k = 0; k < times.len; k++)
			{
				Quaternionf turn = posed[k].rotations[j];
				if (math::abs(math::abs(turn.v.w) - 1.0f) > ANIM_EXPORT_EPSILON) turning = true;
				if (posed[k].offsets[j].length() > ANIM_EXPORT_EPSILON) sliding = true;
			}
			if (!turning && !sliding) continue;

			Quaternionf[] turns = {};
			Vec3[] slides = {};
			Vec3 local = rest_offset(skeleton, j);

			if (turning) turns = alloc::new_array(allocator, Quaternionf, (sz)times.len);
			if (sliding) slides = alloc::new_array(allocator, Vec3, (sz)times.len);

			for (usz k = 0; k < times.len; k++)
			{
				if (turning) turns[k] = posed[k].rotations[j];
				if (sliding) slides[k] = local + posed[k].offsets[j];
			}

			curves.push({ .joint = j, .turns = turns, .slides = slides });
		}

		if (curves.len() == 0)
		{
			curves.free();
			continue;
		}
		if (report)
		{
			usz channels = 0;
			foreach (curve : curves.array_view())
			{
				if (curve.turns.len > 0) channels++;
				if (curve.slides.len > 0) channels++;
			}
			report.count(baked_keys, times.len, channels);
		}

		out.push({
			.name = template.name.copy(allocator),
			.times = times,
			.curves = curves.to_array(allocator),
		});
		curves.free();
		kept = true;
	}

	return out.to_array(allocator);
}

<*
 Release what `reskin_clips` built.
*>
fn void free_reskin_clips(Allocator allocator, gltf_edit::ReskinClip[] clips)
{
	foreach (clip : clips)
	{
		foreach (curve : clip.curves)
		{
			if (curve.turns.len > 0) alloc::free(allocator, curve.turns);
			if (curve.slides.len > 0) alloc::free(allocator, curve.slides);
		}
		if (clip.curves.len > 0) alloc::free(allocator, clip.curves);
		if (clip.times.len > 0) alloc::free(allocator, clip.times);
		if (clip.name.len > 0) alloc::free(allocator, clip.name.ptr);
	}
	if (clips.len > 0) alloc::free(allocator, clips);
}

// ---------------------------------------------------------------------------
// Export-time shaping: root motion and key reduction, applied to the baked
// samples of a game export. The project clip is never changed; a pack keeps its
// authored keys and gets neither.

<*
 What an export does to its baked motion. The zero value writes the viewport's
 motion as it is, sample for sample.
*>
struct ExportMotion
{
	RootMotionPolicy root;
	KeyReduction reduce;
}

fn bool ExportMotion.active(self) => self.root.active() || self.reduce != OFF;

// Turning is baked densely, since a turn about a moving pivot is no straight line.
fn bool ExportMotion.dense(self) => self.root.active() && self.root.turning;

struct ExportMotionReport
{
	usz keys_before; // per-channel samples the full bake had
	usz keys_after;  // and how many were written
	usz moved;       // clips whose travel was moved
	usz no_travel;
	usz no_root;     // clips left as authored: the rig has no root joint
}

fn void ExportMotionReport.count(&self, usz before, usz after, usz channels)
{
	self.keys_before += before * channels;
	self.keys_after += after * channels;
}

fn void shape_export_samples(
	Allocator allocator,
	rig::Skeleton* skeleton,
	String[] names,
	AnimTemplate template,
	ConstraintRig constraints,
	bool grounded,
	ExportMotion motion,
	float[]* times,
	rig::Pose[]* posed,
	ExportMotionReport* report) @local
{
	if (motion.root.active())
	{
		RootMotionOutcome outcome = root_motion_in_samples(allocator, skeleton, names, template,
			*times, *posed, grounded, constraints, motion.root);
		if (report)
		{
			switch (outcome)
			{
				case MOVED: report.moved++;
				case NO_ROOT_JOINT: report.no_root++;
				default: report.no_travel++;
			}
		}
	}
	if (motion.reduce == OFF || times.len <= 2) return;

	bool[] protect = protected_samples(allocator, template, *times);
	defer alloc::free(allocator, protect);
	usz[] kept = reduce_samples(allocator, skeleton, *times, *posed, protect,
		motion.reduce.tolerance(skeleton.height()));
	defer alloc::free(allocator, kept);
	if (kept.len == times.len) return;

	float[] fewer_times = alloc::new_array(allocator, float, (sz)kept.len);
	rig::Pose[] fewer = alloc::new_array(allocator, rig::Pose, (sz)kept.len);
	usz next = 0;
	foreach (usz k, &pose : *posed)
	{
		if (next < kept.len && kept[next] == k)
		{
			fewer_times[next] = (*times)[k];
			fewer[next] = *pose;
			next++;
			continue;
		}
		pose.free(allocator);
	}
	alloc::free(allocator, *times);
	alloc::free(allocator, *posed);
	*times = fewer_times;
	*posed = fewer;
}

<*
 Apply root motion to a baked run of export samples.

 The travel is measured on the same evaluated poses the samples are, at the
 clip's start and last key, so what is written is the viewport's motion with
 the travel moved and nothing else.
*>
fn RootMotionOutcome root_motion_in_samples(Allocator allocator, rig::Skeleton* skeleton,
	String[] names, AnimTemplate template, float[] times, rig::Pose[] posed, bool grounded,
	ConstraintRig constraints, RootMotionPolicy policy)
{
	if (!policy.active()) return NO_TRAVEL;
	MotionRoots roots = motion_roots(skeleton, names);
	if (roots.hips < 0) return NO_KEYS;
	if (policy.mode == ON_ROOT && roots.root < 0) return NO_ROOT_JOINT;
	float until = travel_until(template);
	if (until <= 0.0f) return NO_KEYS;

	float[2] ends = { 0.0f, until };
	rig::Pose[] edge = poses_at_times(allocator, skeleton, names, template, ends[..], grounded, constraints);
	defer free_poses(allocator, edge);
	RootTravel travel = measure_root_travel(skeleton, roots, &edge[0], &edge[1], until, policy);
	if (!travel.moves(skeleton.height(), policy.mode)) return NO_TRAVEL;
	foreach (usz k, t : times) move_root_in_pose(skeleton, &posed[k], roots, policy.mode, travel, t);
	return MOVED;
}

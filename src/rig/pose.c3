<*
 Posing a skeleton and deforming the mesh with it.

 A skeleton alone says where the bones are; a pose says where they have moved
 to. Together with a skin binding they produce the thing a rig is actually for —
 the mesh bending when a joint turns.

 This is the diagnostic half of rigging. The tint views answer "which joint owns
 this vertex", which is a picture of the weight matrix; posing answers "and what
 happens when that joint moves", which is the question the weights exist to
 answer and the only one a viewer can judge. A leg that drags its neighbour with
 it is obvious in motion and nearly invisible in a colour map.

 **Frames.** A joint's rest frame here is a pure translation to its position, so
 a pose rotation turns its subtree about that position, around world axes. That
 is "rotate the thigh at the hip" and it needs no convention beyond the joint
 positions themselves. Note this is *not* the frame the glTF exporter writes:
 `add_skeleton` aligns each bone's local axes along the bone, so the same visible
 motion is a different quaternion there. The deformation is identical either way
 — at rest every joint's transform cancels its own inverse bind — but a pose
 exported as an animation channel has to be carried into the bone frame first.
*>
module rig;

import gltf;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;



<*
 Raised when a pose does not carry exactly one rotation per joint.
*>
faultdef POSE_SIZE_MISMATCH;

<*
 Raised when a vertex leans on a joint the palette does not have — a binding and
 a skeleton from different rigs.
*>
faultdef PALETTE_INDEX_OUT_OF_RANGE;

<*
 One local rotation and one local offset per joint, in joint order. Identity
 rotations and zero offsets are the rest pose, so a fresh pose leaves the mesh
 exactly where it was modelled.

 Local, meaning relative to the parent: a rotation on a hip carries the knee and
 the foot with it, which is what makes a chain worth having, and an offset does
 the same — it moves the joint and everything hanging off it, leaving the bones
 below their own length.

 **Offsets tear where rotations do not.** A rotation pivots a joint about its
 own position, so the vertices a neighbouring joint also claims stay put and the
 seam between them stretches rather than splitting. An offset moves the joint
 away from its neighbour outright, and every vertex shared between the two is
 pulled apart in proportion. That is why the root carries them and the limbs
 mostly do not: sliding the root is the whole figure moving, with no neighbour
 to tear away from. Anything below it is a judgement about how much the skin can
 take.
*>
struct Pose
{
	Quaternionf[] rotations;
	Vec3[] offsets;
}

<*
 A pose that changes nothing, sized for `joints`.

 The caller owns the returned arrays.
*>
fn Pose rest_pose(Allocator allocator, usz joints)
{
	Pose pose = {
		.rotations = alloc::new_array(allocator, Quaternionf, (sz)joints),
		.offsets = alloc::new_array(allocator, Vec3, (sz)joints),
	};
	foreach (&rotation : pose.rotations) *rotation = quaternion::IDENTITY;
	foreach (&offset : pose.offsets) *offset = { 0, 0, 0 };
	return pose;
}

fn void Pose.free(&self, Allocator allocator)
{
	if (self.rotations.len > 0) alloc::free(allocator, self.rotations);
	if (self.offsets.len > 0) alloc::free(allocator, self.offsets);
	self.rotations = {};
	self.offsets = {};
}

<*
 The same pose in memory the caller owns.
*>
fn Pose Pose.copy(self, Allocator allocator)
{
	Pose out = {
		.rotations = alloc::new_array(allocator, Quaternionf, (sz)self.rotations.len),
		.offsets = alloc::new_array(allocator, Vec3, (sz)self.offsets.len),
	};
	foreach (usz i, rotation : self.rotations) out.rotations[i] = rotation;
	foreach (usz i, offset : self.offsets) out.offsets[i] = offset;
	return out;
}

<*
 A pose `t` of the way from `a` to `b` — one crossfade frame.

 Rotations slerp and offsets lerp, which is the only combination that keeps bone
 lengths: interpolating the rotations component-wise would shorten a limb as it
 swung, and interpolating world positions would break the chain outright.

 **Blend before grounding, not after.** Two poses that each have a foot on the
 floor blend to one that mostly does not — the feet are at different places and
 the average of two contacts is a hover. Sample both clips ungrounded, blend
 here, and call `ground_pose` once on the result.

 Exact at the ends: `t <= 0` is `a` and `t >= 1` is `b`, copied rather than
 computed. A fade that has not started must show the clip it has not left, and
 slerp with a renormalize answers a hair off that.

 The caller owns the returned pose.

 @param t : `How far along, clamped. 0 is all a, 1 is all b.`
 @return? POSE_SIZE_MISMATCH : `The two poses are not the same length.`
*>
fn Pose? blend_poses(Allocator allocator, Pose a, Pose b, float t)
{
	usz count = a.rotations.len;
	if (a.offsets.len != count || b.rotations.len != count || b.offsets.len != count)
	{
		return POSE_SIZE_MISMATCH~;
	}

	if (t <= 0.0f) return a.copy(allocator);
	if (t >= 1.0f) return b.copy(allocator);

	Pose out = {
		.rotations = alloc::new_array(allocator, Quaternionf, (sz)count),
		.offsets = alloc::new_array(allocator, Vec3, (sz)count),
	};

	foreach (usz i, rotation : a.rotations)
	{
		Quaternionf to = b.rotations[i];
		// A quaternion and its negation are the same rotation, so a pair written
		// on opposite hemispheres slerps the long way round — three-quarters of a
		// turn to reach a pose a quarter turn away, which reads as the character
		// snapping through itself. The same alignment `AnimSpan.turn` does to its
		// control points, for the same reason.
		if (rotation.v.dot(to.v) < 0.0f) to = -to;

		out.rotations[i] = rotation.slerp(to, t).normalize();
		out.offsets[i] = a.offsets[i] + (b.offsets[i] - a.offsets[i]) * t;
	}

	return out;
}

<*
 Turn one joint by `angle` radians about `axis`, replacing whatever it held.

 Out-of-range indices are ignored rather than raised: callers hand this a joint
 index derived from a selection, and a selection can outlive the joint it named.
*>
fn void Pose.turn(&self, usz joint, Vec3 axis, float angle)
{
	if (joint >= self.rotations.len) return;
	self.rotations[joint] = quaternion::from_axis_angle{float}(axis.normalize(), angle);
}

<*
 Slide one joint by `offset`, replacing whatever it held.

 In the parent's posed frame, so a joint offset along a limb that has been
 rotated follows the limb. On a root — which has no parent — that is world axes,
 and sliding the root is how a figure rises, falls or travels.

 Out-of-range indices are ignored, for the same reason `turn` ignores them.
*>
fn void Pose.move(&self, usz joint, Vec3 offset)
{
	if (joint >= self.offsets.len) return;
	self.offsets[joint] = offset;
}

<*
 The matrix per joint that takes a rest-pose vertex to where the pose puts it.

 Each joint's world transform is its parent's, then the offset from the parent
 plus whatever the pose slides it by, then its own rotation; the palette entry
 is that composed with the inverse of the joint's rest transform, so a vertex is
 carried into the joint's frame, moved with it, and put back. At rest the two
 cancel exactly and every entry is the identity — which is the cheapest possible
 check that the frames agree.

 The pose offset folds into the same translation as the rest offset because the
 two are consecutive translations in the same frame, and translations add.

 One pass suffices because joints are ordered parents-before-children, the same
 invariant the glTF writer relies on.

 The caller owns the returned array.

 @param pose : `One rotation and one offset per joint, as rest_pose builds.`
 @return? POSE_SIZE_MISMATCH : `The pose and the skeleton disagree on joint count.`
*>
fn Matrix4f[]? joint_palette(Allocator allocator, Skeleton* skeleton, Pose pose)
{
	usz count = skeleton.len();
	if (pose.rotations.len != count || pose.offsets.len != count) return POSE_SIZE_MISMATCH~;

	Matrix4f[] palette = alloc::new_array(allocator, Matrix4f, (sz)count);

	foreach (usz i, joint : skeleton.joints)
	{
		int parent = skeleton.parents[i];
		Matrix4f base = parent >= 0 ? palette[(usz)parent] : matrix::IDENTITY4;
		Vec3 head = parent >= 0 ? skeleton.joints[(usz)parent] : (Vec3){ 0, 0, 0 };

		Matrix4f placed = base.translate(joint - head + pose.offsets[i]);
		Matrix4f rotation = pose.rotations[i].to_matrix();
		palette[i] = placed.mul(rotation);
	}

	// World transforms so far — fold in the rest inverse now that no child needs
	// to read its parent's world transform any more. A second pass rather than a
	// second array, since the two differ by one translation.
	foreach (usz i, joint : skeleton.joints)
	{
		palette[i] = palette[i].translate(-joint);
	}

	return palette;
}

<*
 Each joint's rotation in world terms — the chain of local rotations composed
 from the root down.

 	`Quaternionf[] world = pose.world_rotations(mem, &skeleton)!;`

 `joint_palette`'s answer already carries this in its rotation block, and this is
 the exact and cheaper route to the same thing: quaternion products rather than
 4x4 matrices and a decomposition back out, on the same
 parents-before-children invariant the palette walks.

 What wants it is a caller editing a pose from outside. A turn described in world
 terms — carry this joint until it points there — is a *local* rotation only
 after the parent's own world rotation has been divided out of it, and this is
 the rotation to divide by. Translations contribute none of it, which is why the
 rest offsets and the pose offsets do not appear here at all.

 The caller owns the returned array.

 @return? POSE_SIZE_MISMATCH : `The pose and the skeleton disagree on joint count.`
*>
fn Quaternionf[]? Pose.world_rotations(&self, Allocator allocator, Skeleton* skeleton)
{
	usz count = skeleton.len();
	if (self.rotations.len != count) return POSE_SIZE_MISMATCH~;

	Quaternionf[] world = alloc::new_array(allocator, Quaternionf, (sz)count);

	foreach (usz i, int parent : skeleton.parents)
	{
		Quaternionf above = parent >= 0 ? world[(usz)parent] : quaternion::IDENTITY;
		world[i] = above.mul(self.rotations[i]);
	}

	return world;
}

<*
 The rotation a matrix applies, read off its three axis columns. A palette entry
 is a rigid transform, so its columns are already orthonormal; the result is
 normalised against float drift all the same.
*>
fn Quaternionf quat_from_matrix(Matrix4f m)
{
	return quat_from_basis(
		{ m.m00, m.m10, m.m20 },
		{ m.m01, m.m11, m.m21 },
		{ m.m02, m.m12, m.m22 }).normalize();
}

<*
 The quaternion for a rotation given as its three transformed axes.

 Shepperd's method: which of the four expressions is used is decided by the
 largest diagonal term, which is what keeps the divisor away from zero. The plain
 trace formula loses all its precision on a half-turn, and a bone pointing
 backwards is one.

 Takes the *columns*, which is how both callers have the rotation to hand — the
 glTF importer as the normalised axes of a node matrix, and the MCP pose reader
 as the rotation block of a palette entry. A palette entry carries no scale
 (`joint_palette` composes rotations and translations only), so its columns are
 already the orthonormal basis this wants; anything decomposed out of a file has
 to be normalised first.

 @param x : `Where the rotation sends the x axis — the matrix's first column.`
 @param y : `The second column.`
 @param z : `The third column.`
*>
fn Quaternionf quat_from_basis(Vec3 x, Vec3 y, Vec3 z)
{
	// Named as row-then-column, so they read transposed against the vectors they
	// are taken from.
	float m00 = x.x;
	float m10 = x.y;
	float m20 = x.z;
	float m01 = y.x;
	float m11 = y.y;
	float m21 = y.z;
	float m02 = z.x;
	float m12 = z.y;
	float m22 = z.z;

	float trace = m00 + m11 + m22;

	if (trace > 0.0f)
	{
		float s = math::sqrt(trace + 1.0f) * 2.0f;
		return { .v = { (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25f * s } };
	}
	if (m00 > m11 && m00 > m22)
	{
		float s = math::sqrt(1.0f + m00 - m11 - m22) * 2.0f;
		return { .v = { 0.25f * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s } };
	}
	if (m11 > m22)
	{
		float s = math::sqrt(1.0f + m11 - m00 - m22) * 2.0f;
		return { .v = { (m01 + m10) / s, 0.25f * s, (m12 + m21) / s, (m02 - m20) / s } };
	}

	float s = math::sqrt(1.0f + m22 - m00 - m11) * 2.0f;
	return { .v = { (m02 + m20) / s, (m12 + m21) / s, 0.25f * s, (m10 - m01) / s } };
}

<*
 Linear blend skinning: each vertex is moved by every joint that claims it and
 lands at the weighted average.

 The CPU twin of what the vertex shader does, and the reason it exists is that
 it can be asserted without a window — a rig that deforms correctly here deforms
 correctly on screen, and a rig that tears here tears there.

 `out` may alias nothing: rest positions are read for every influence, so
 writing into the array being read would skin a vertex with its own result.

 @param out : `Receives one position per vertex; as long as the rest positions.`
 @param binding : `Per-vertex influences, from bind_skin or sparsify_weights.`
 @return? SKIN_SHAPE_MISMATCH : `out, rest and the binding do not agree on vertex count.`
 @return? PALETTE_INDEX_OUT_OF_RANGE : `An influence names a joint the palette lacks.`
*>
fn void? skin_positions(Vec3[] out, Vec3[] rest, gltf::SkinBinding binding, Matrix4f[] palette)
{
	if (out.len != rest.len || binding.vertices != rest.len) return SKIN_SHAPE_MISMATCH~;

	usz slots = (usz)binding.slots;

	foreach (usz v, position : rest)
	{
		Vec3 sum = { 0, 0, 0 };
		usz base = v * slots;

		for (usz s = 0; s < slots; s++)
		{
			float weight = binding.weights[base + s];
			// Empty slots are stored as weight zero, and past the first one the
			// rest of the row is empty too — but skipping rather than breaking
			// costs nothing and survives a binding that packs them differently.
			if (weight == 0.0f) continue;

			usz joint = (usz)binding.joints[base + s];
			if (joint >= palette.len) return PALETTE_INDEX_OUT_OF_RANGE~;

			Matrix4f transform = palette[joint];
			sum += position.transform(transform) * weight;
		}

		out[v] = sum;
	}
}

<*
 Weight a mesh to a skeleton and reduce it to what skinning can use, in one
 call: the dense matrix straight into its four strongest influences per vertex.

 The pair is always wanted together — the dense matrix is an intermediate nobody
 keeps — so one name for it saves every caller from spelling out both.

 Not what the editor binds through. It keeps the dense matrix a moment longer
 than this does, to prune the joints no vertex ended up riding and to substitute
 a binding read out of the file, so its two callers meet in
 `AppState.bind_dense` instead. This is for a caller that wants the binder's
 answer and nothing else — a check, or a tool with no document behind it.

 **Every input the binder reads has to arrive here**, `reaches` included. A caller
 that drops one binds a different skin from one that passes it, and the two are
 hard to tell apart on screen: a reach-limited joint gives up its far vertices to
 whoever is next nearest, which reads as a slightly different falloff rather than
 as anything wrong, until the file is opened somewhere else and the mesh moves.

 The caller owns the returned binding.

 @param voxels : `Built from this same mesh; null measures straight lines instead.`
 @param shells : `Built from this same mesh; null leaves loose pieces to the ordinary rules.`
 @param attachments : `One joint index per shell, -1 to decide automatically.`
 @param reaches : `One per joint, in model units, 0 for no limit. Empty leaves every dot unlimited.`
 @return? gltf::WEIGHT_SIZE_MISMATCH : `The mesh and skeleton produced a matrix of the wrong shape.`
*>
fn gltf::SkinBinding? bind_skin(
	Allocator allocator,
	Vec3[] positions,
	Skeleton* skeleton,
	MeshVoxels* voxels = null,
	MeshShells* shells = null,
	int[] attachments = {},
	uint influences = 4,
	float[] reaches = {})
{
	float[] dense = bind_geodesic(
		allocator, voxels, positions, skeleton.joints, skeleton.parents, shells, attachments,
		reaches: reaches);
	defer alloc::free(allocator, dense);

	return gltf::sparsify_weights(allocator, dense, positions.len, skeleton.len(), influences);
}

<*
 Which vertices of a file are which rows of a weight matrix.

 The third walk of the same scene. `gltf_source.c3` flattens it into one triangle
 soup, `gltf_skin.c3` reads its weights back in that order, and this one records
 where each primitive's vertices landed so that weights can be written back into
 the file the soup came from.

 	`MeshParts parts = rig::mesh_parts(mem, &stream)!;`
 	`defer parts.free(mem);`

 **The walk has to be the same walk.** All three read the nodes from
 `scene_mesh_nodes`, so the order cannot differ; the per-primitive skip rules are
 still written twice. What catches a drift there is `MeshParts.vertices`: a
 caller compares it against the mesh it is holding and refuses on a mismatch,
 so a walk that stops agreeing shows up as a save that declines rather than as
 weights on the wrong vertices.

 The `world` matrix per part is the other half of the answer. `append_node` bakes
 an unskinned node's world transform into the positions it emits, so a rig
 measured against those positions is measured in world space — while the file's
 own vertex data is in the node's local space, which is what a skin deforms. The
 two agree exactly when the transform is the identity, and glTF ignores a skinned
 node's transform outright, which is why an already-skinned model always agrees.
 A caller that wants to write a skin into a model that has none has to check.
*>
module rig;

import gltf;
import std::collections::list;


import std::math::matrix;
import std::math::vector;

<*
 One primitive of the scene, and the run of vertices it contributed.
*>
struct MeshPart
{
	uint node;
	uint mesh;
	uint primitive;
	usz base;
	usz count;

	// The transform `from_gltf` baked into this part's positions: the node's own
	// world matrix, or the identity where the node is skinned.
	Matrix4f world;

	bool skinned;
}

<*
 Every primitive the flattener takes in, in the order it takes them.
*>
struct MeshParts
{
	MeshPart[] parts;
	usz vertices;

	// The skin the scene's meshes are deformed by, or -1 where none is.
	int skin;
}

fn void MeshParts.free(&self, Allocator allocator)
{
	if (self.parts.len > 0) alloc::free(allocator, self.parts);
	*self = {};
}

<*
 Whether every part's positions are already in the space a skin would deform.

 True when nothing was baked in — either because the node is skinned, so glTF
 ignores its transform and `from_gltf` used the identity, or because its
 transform *is* the identity and there was nothing to bake.

 The question a caller has to ask before putting a skin onto a model that has
 none: attaching one makes the renderer start ignoring the node transform, and a
 model whose vertices were placed by that transform would move the moment it
 became a skinned one.
*>
fn bool MeshParts.upright(&self)
{
	Matrix4f identity = matrix::IDENTITY4{float};
	foreach (part : self.parts)
	{
		if (part.skinned) continue;
		// Exactly, and not within a tolerance: an exporter either wrote a transform
		// or it did not, and "nearly the identity" is a model that would move by
		// nearly nothing — which is still a model that moved.
		for (usz i = 0; i < 16; i++)
		{
			if (part.world.m[i] != identity.m[i]) return false;
		}
	}
	return true;
}

<*
 The one transform that placed every part, for a model that is not yet skinned.

 `upright` answers whether attaching a skin would move the mesh; this answers by
 *what*, for the case that can be undone — a single node transform above the
 skinnable mesh, which is what a character exported with a rotation or an offset
 on its object arrives as. Folded into the new skin's bind matrix that transform
 is reproduced exactly at rest, so the mesh stays where the node put it once a
 renderer starts ignoring the node (see `gltf_edit::Reskin.bind`). Parts placed
 by *different* transforms have no one matrix to fold, so this reports none and
 the caller sends them to Export.

 Skinned parts are skipped, as in `upright`: glTF already ignores their node's
 transform, so `from_gltf` baked nothing into them and there is nothing to undo.

 @param out : `The shared world transform, set only when this returns true.`
 @return `False when the unskinned parts do not agree on one transform.`
*>
fn bool MeshParts.shared_placement(&self, Matrix4f* out)
{
	bool have = false;
	Matrix4f common = matrix::IDENTITY4;
	foreach (part : self.parts)
	{
		if (part.skinned) continue;
		if (!have) { common = part.world; have = true; continue; }
		for (usz i = 0; i < 16; i++)
		{
			if (part.world.m[i] != common.m[i]) return false;
		}
	}
	*out = common;
	return true;
}

<*
 Walk an open stream and record where each primitive's vertices land.

 Its buffers need not be loaded — nothing here reads one. Only the accessors'
 counts are wanted, and those are in the JSON.

 @param scene : `Scene to walk, or -1 for the first one.`
 @return? NO_TRIANGLES : `Nothing in the scene is a triangle mesh.`
 @return? SCENE_NOT_FOUND : `scene names a scene the file does not have.`
 @return? SKIN_AMBIGUOUS : `The scene skins its vertices against more than one skin.`
*>
fn MeshParts? mesh_parts(Allocator allocator, gltf::GltfStream* stream, int scene = -1)
{
	if (stream.gltf.scenes.len() == 0) return NO_TRIANGLES~;

	sz scene_index = scene < 0 ? 0 : (sz)scene;
	if (scene_index >= stream.gltf.scenes.len()) return SCENE_NOT_FOUND~;

	List{MeshPart} found;
	found.init(allocator);
	// Freed whichever way this returns: `to_array` copies into a tight array
	// rather than handing over the list's own storage.
	defer found.free();

	MeshParts out = { .skin = -1 };
	uint[] nodes = scene_mesh_nodes(allocator, stream, scene_index);
	defer if (nodes.len > 0) alloc::free(allocator, nodes);
	foreach (node : nodes)
	{
		append_part(stream, node, &found, &out)!;
	}

	if (found.len() == 0) return NO_TRIANGLES~;

	out.parts = found.to_array(allocator);
	return out;
}

// `append_node` with the vertices counted instead of copied, for one node of
// `scene_mesh_nodes` — the same skip rules, so the runs this hands out are the
// ones that one produces.
fn void? append_part(
	gltf::GltfStream* stream,
	uint node_index,
	List{MeshPart}* found,
	MeshParts* out) @local
{
	gltf::Node node = stream.gltf.nodes[node_index];

	if (node.has_skin())
	{
		if (out.skin >= 0 && out.skin != node.skin) return SKIN_AMBIGUOUS~;
		out.skin = node.skin;
	}

	// The identity for a skinned node, where `append_primitive` uses the skin's
	// bind matrix. Deliberate, and it costs nothing: `upright` is the only
	// reader of this field and it skips skinned parts, since the question it
	// asks — would attaching a skin move these vertices — is already answered
	// for a part that has one. Reading the bind matrix would mean reading a
	// buffer, and this walk promises not to.
	Matrix4f world = node.has_skin() ? matrix::IDENTITY4 : node.global_matrix();

	gltf::Mesh mesh = stream.gltf.meshes[(usz)node.mesh];
	foreach (usz p, primitive : mesh.primitives)
	{
		usz count = part_vertices(stream, primitive);
		if (count == 0) continue;

		found.push({
			.node = node_index,
			.mesh = (uint)node.mesh,
			.primitive = (uint)p,
			.base = out.vertices,
			.count = count,
			.world = world,
			.skinned = node.has_skin(),
		});
		out.vertices += count;
	}
}

// What `append_primitive` would emit for this primitive, and zero for one it
// skips. The two skip rules are the same two: not triangles, or no positions.
fn usz part_vertices(gltf::GltfStream* stream, gltf::Primitive primitive) @private
{
	if (try sz mode = primitive.attributes.get("mode"))
	{
		if (mode != GLTF_MODE_TRIANGLES) return 0;
	}

	sz? position_attribute = primitive.attributes.get("POSITION");
	if (catch position_attribute) return 0;

	return (usz)stream.gltf.accessors[position_attribute].count;
}

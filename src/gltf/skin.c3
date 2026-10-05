<*
 Reading back the skin a .glb already carries.

 The counterpart to `gltf_source.c3`, which flattens a scene into one triangle
 soup and throws the rest away. A mesh rigged in another tool arrives with its
 weights already painted, and repainting them from scratch is not a neutral act:
 the geodesic binder is good, but it is not the person who spent an afternoon
 fixing the shoulder. So the file's own `JOINTS_n` / `WEIGHTS_n` are read here
 and used as they stand.

 **The vertex order has to be the flattener's order**, because that is the only
 order the positions exist in once `from_gltf` has run — one array with every
 primitive of every mesh node concatenated. Both read their nodes from
 `scene_mesh_nodes`, so the order is shared; the per-primitive skip rules are
 still written in each, and the compiler does not check they agree. What
 catches a drift is `SourceSkin.vertices`: a caller compares it against the mesh
 it means to bind and refuses on a mismatch, so a walk that stops agreeing shows
 up as an import that declines rather than as weights on the wrong vertices.
*>
module rig;

import gltf;


import std::math::matrix;
import std::math::vector;

<*
 Raised when the file has no skin to read, or names one it does not hold.
*>
faultdef SKIN_ABSENT;

<*
 Raised when the scene skins its vertices against more than one skin.

 The flattener produces a single vertex array, and a single array of weights over
 it can only be indexed by one joint list. Two skins would need two, and which
 one a given vertex belongs to is exactly the information the flattening threw
 away.
*>
faultdef SKIN_AMBIGUOUS;

<*
 Raised when the walk reached a vertex no joint claims.

 A file that mixes a skinned character with an unskinned prop produces this: the
 prop's vertices come back weightless, and linear blend skinning sends a
 weightless vertex to the origin. Refused rather than patched, because the patch
 would be a second binder running on part of the mesh, and a mesh bound two ways
 is the thing this whole module exists to avoid.
*>
faultdef SKIN_INCOMPLETE;

<*
 The weights a file carries, over the vertices `from_gltf` produces.

 Dense, in the same shape `bind_geodesic` returns — one row per vertex, one
 column per joint — so the two are interchangeable everywhere downstream.

 The columns are the *file's* joint order, which is nothing to do with any order
 crig builds. `nodes` is what makes them addressable: column `c` weights the node
 `nodes[c]`, and a caller that read the skeleton out of the same file matches
 the two through that node index.
*>
struct SourceSkin
{
	float[] weights;
	uint[] nodes;
	usz vertices;
	usz columns;
}

fn void SourceSkin.free(&self, Allocator allocator)
{
	if (self.weights.len > 0) alloc::free(allocator, self.weights);
	if (self.nodes.len > 0) alloc::free(allocator, self.nodes);
	*self = {};
}

// How many influence sets glTF allows a primitive to carry. Four is the
// spec's own limit on the attribute suffix, and a file that uses all of them
// weights a vertex by sixteen joints.
const usz SKIN_ATTRIBUTE_SETS @local = 4;

const String[SKIN_ATTRIBUTE_SETS] JOINT_ATTRIBUTES @local = {
	"JOINTS_0", "JOINTS_1", "JOINTS_2", "JOINTS_3"
};
const String[SKIN_ATTRIBUTE_SETS] WEIGHT_ATTRIBUTES @local = {
	"WEIGHTS_0", "WEIGHTS_1", "WEIGHTS_2", "WEIGHTS_3"
};

// The state one walk of the scene carries. `out` null makes it a counting pass:
// the dense matrix cannot be allocated until the vertex total is known, and
// counting with the same code that fills is what keeps the two passes from
// disagreeing about which primitives are in.
struct SkinWalk @local
{
	usz vertices;
	int skin; // -1 until a skinned node names one
	SourceSkin* out;
}

<*
 Read an already-open stream's skin. Its buffers must be loaded.

 Two walks of the same scene: the first counts the vertices the flattener would
 emit, the second fills the matrix now that there is one to fill. Nothing but the
 node list is allocated by the first, so a file with no skin costs a tree walk
 and no more.

 @param scene : `Scene to walk, or -1 for the first one.`
 @return? SKIN_ABSENT : `The file carries no skin, or nothing in this scene is skinned.`
 @return? SKIN_AMBIGUOUS : `The scene skins vertices against more than one skin.`
 @return? SKIN_INCOMPLETE : `Some vertex is claimed by no joint at all.`
 @return? SCENE_NOT_FOUND : `scene names a scene the file does not have.`
*>
fn SourceSkin? skin_from_gltf(Allocator allocator, gltf::GltfStream* stream, int scene = -1)
{
	if (stream.gltf.scenes.len() == 0) return SKIN_ABSENT~;
	if (stream.gltf.skins.len() == 0) return SKIN_ABSENT~;

	sz scene_index = scene < 0 ? 0 : (sz)scene;
	if (scene_index >= stream.gltf.scenes.len()) return SCENE_NOT_FOUND~;

	uint[] nodes = scene_mesh_nodes(allocator, stream, scene_index);
	defer if (nodes.len > 0) alloc::free(allocator, nodes);

	SkinWalk counting = { .skin = -1 };
	foreach (node : nodes) walk_skin(stream, node, &counting)!;
	if (counting.skin < 0 || counting.vertices == 0) return SKIN_ABSENT~;

	gltf::Skin skin = stream.gltf.skins[(sz)counting.skin];
	usz columns = (usz)skin.joints.len();
	if (columns == 0) return SKIN_ABSENT~;

	SourceSkin out = {
		.weights = alloc::new_array(allocator, float, (sz)(counting.vertices * columns)),
		.nodes = alloc::new_array(allocator, uint, (sz)columns),
		.vertices = counting.vertices,
		.columns = columns,
	};
	defer catch out.free(allocator);

	for (usz c = 0; c < columns; c++) out.nodes[c] = skin.joints[(sz)c];

	SkinWalk filling = { .skin = counting.skin, .out = &out };
	foreach (node : nodes) walk_skin(stream, node, &filling)!;

	// Cheaper than it looks beside the read that just happened, and it is the
	// check that turns "some vertices ride nothing" from a mesh that collapses
	// into the origin at frame one into a refusal the caller can report.
	for (usz v = 0; v < out.vertices; v++)
	{
		float sum = 0.0f;
		usz base = v * columns;
		for (usz c = 0; c < columns; c++) sum += out.weights[base + c];
		if (sum <= 0.0f) return SKIN_INCOMPLETE~;
	}

	return out;
}

<*
 Where a skin's own bind pose puts its vertices.

 	`Matrix4f bind = rig::skin_bind_matrix(&stream, node.skin);`

 glTF places a skinned vertex by its joints and not by the node its mesh hangs
 under, which is why `from_gltf` ignores that node's transform. But *ignoring* it
 is only half the rule. The full one is the skinning sum, and at rest — where
 every joint sits at its bind transform — it collapses to a single matrix:

 	`v_world = Σ w · G(joint) · inverse_bind[joint] · v = B · v`

 That `B` is what this returns, and applying it is what makes the flattened mesh
 land in the same space as the skeleton `read_rest_skeleton` reads out of the
 same file. crig never runs the skinning over the rest mesh — the POSITION data
 *is* the geometry — so a `B` that is not the identity has to be applied here or
 it is lost.

 For anything crig writes, and for a Blender or Mixamo export, `B` is the
 identity and this changes nothing: the joints already sit at the scene root, so
 the inverse bind matrices undo their globals exactly. It is files that carry a
 conversion above the joints — COLLADA2GLTF puts its `Z_UP` node there — whose
 `B` is that conversion. Without it the mesh arrives lying on its back while the
 skeleton from the same file stands up.

 Read off joint zero. The spec does not oblige the other joints to agree, but one
 that carries a bind shape carries the same one on every joint — it was a single
 matrix in COLLADA before it was folded into each of these — and a file where
 they genuinely disagree has no one rest pose to load, only a mesh already
 deformed.

 @param skin : `Index into the file's skins. Out of range yields the identity.`
 @require stream != null
 @return `The bind transform, or the identity for a skin that states none.`
*>
fn Matrix4f skin_bind_matrix(gltf::GltfStream* stream, int skin)
{
	if (skin < 0 || (sz)skin >= stream.gltf.skins.len()) return matrix::IDENTITY4;

	gltf::Skin bound = stream.gltf.skins[(sz)skin];
	if (bound.joints.len() == 0) return matrix::IDENTITY4;

	// The accessor has to be recognised rather than trusted. `inverseBindAccessor`
	// is a plain uint, so a skin that states no matrices — which is legal, and
	// which is what crig's own writer emits — leaves it at zero, and accessor zero
	// is a real accessor holding somebody's positions. What a bind matrix array
	// looks like is a MAT4 with a row per joint, and nothing else in a glTF does.
	if ((sz)bound.inverseBindAccessor >= stream.gltf.accessors.len()) return matrix::IDENTITY4;
	gltf::Accessor bind = stream.gltf.accessors[(sz)bound.inverseBindAccessor];
	if (bind.type != gltf::AccessorType.MAT4) return matrix::IDENTITY4;
	if ((sz)bind.count < bound.joints.len()) return matrix::IDENTITY4;

	// Read straight through, no transpose: glTF writes a matrix column-major and
	// `Matrix4f.m` is stored column-major, which is why `Node.from_json` copies a
	// node's own matrix across element by element and leaves it at that.
	gltf::Node joint = stream.gltf.nodes[(sz)bound.joints[0]];
	Matrix4f inverse_bind = stream.@cast_buffer(bind, 0, Matrix4f);
	return joint.global_matrix().mul(inverse_bind);
}

// `append_node` with the weights read instead of the positions, for one node of
// `scene_mesh_nodes` — the same skip rules, so the vertex indices this produces
// are the ones that one hands out. See the module note on what catches a drift.
fn void? walk_skin(gltf::GltfStream* stream, uint node_index, SkinWalk* walk) @local
{
	gltf::Node node = stream.gltf.nodes[node_index];

	if (node.has_skin())
	{
		if (walk.skin >= 0 && walk.skin != node.skin) return SKIN_AMBIGUOUS~;
		walk.skin = node.skin;
	}

	gltf::Mesh mesh = stream.gltf.meshes[(usz)node.mesh];
	foreach (primitive : mesh.primitives)
	{
		walk_primitive(stream, primitive, node.has_skin(), walk)!;
	}
}

fn void? walk_primitive(
	gltf::GltfStream* stream,
	gltf::Primitive primitive,
	bool skinned,
	SkinWalk* walk) @local
{
	if (try sz mode = primitive.attributes.get("mode"))
	{
		if (mode != GLTF_MODE_TRIANGLES) return;
	}

	sz? position_attribute = primitive.attributes.get("POSITION");
	if (catch position_attribute) return;

	gltf::Accessor position_accessor = stream.gltf.accessors[position_attribute];
	usz vertex_count = (usz)position_accessor.count;
	if (vertex_count == 0) return;

	usz base = walk.vertices;
	walk.vertices += vertex_count;
	if (!walk.out) return;

	// An unskinned primitive in a skinned scene contributes nothing, and its
	// rows stay zero — which the sum check at the end of `skin_from_gltf` turns
	// into a refusal rather than a silently collapsed prop.
	if (!skinned) return;

	usz columns = walk.out.columns;

	for (usz set = 0; set < SKIN_ATTRIBUTE_SETS; set++)
	{
		sz? joint_attribute = primitive.attributes.get(JOINT_ATTRIBUTES[set]);
		sz? weight_attribute = primitive.attributes.get(WEIGHT_ATTRIBUTES[set]);
		// Both or neither: a set with one half missing describes influences with
		// no strength, or strengths belonging to nobody.
		if (catch joint_attribute) break;
		if (catch weight_attribute) break;

		gltf::Accessor joints = stream.gltf.accessors[joint_attribute];
		gltf::Accessor weights = stream.gltf.accessors[weight_attribute];

		usz available = (usz)joints.count < (usz)weights.count
			? (usz)joints.count
			: (usz)weights.count;
		if (available > vertex_count) available = vertex_count;

		for (usz i = 0; i < available; i++)
		{
			uint[<4>] slot_joints = read_joint_slots(stream, joints, (sz)i)!;
			float[<4>] slot_weights = read_weight_slots(stream, weights, (sz)i)!;

			usz row = (base + i) * columns;
			for (usz s = 0; s < 4; s++)
			{
				if (slot_weights[s] == 0.0f) continue;
				usz column = (usz)slot_joints[s];
				if (column >= columns) return SKIN_INDEX_OUT_OF_RANGE~;
				// Added rather than assigned: nothing stops a file naming the
				// same joint in two slots of the same vertex, and the sum of the
				// two is what it meant.
				walk.out.weights[row + column] += slot_weights[s];
			}
		}
	}
}

<*
 Raised when a vertex names a joint the skin's joint list does not hold.
*>
faultdef SKIN_INDEX_OUT_OF_RANGE;

// glTF stores joint indices as unsigned bytes or unsigned shorts, never wider:
// a skin is capped at 65535 joints by the format itself.
fn uint[<4>]? read_joint_slots(gltf::GltfStream* stream, gltf::Accessor accessor, sz i) @local
{
	switch (accessor.data_type)
	{
		case gltf::DataType.CHAR:
			char[<4>] narrow = stream.@cast_buffer(accessor, i, char[<4>]);
			return { narrow[0], narrow[1], narrow[2], narrow[3] };
		case gltf::DataType.USHORT:
			ushort[<4>] wide = stream.@cast_buffer(accessor, i, ushort[<4>]);
			return { wide[0], wide[1], wide[2], wide[3] };
		default:
			return UNSUPPORTED_INDEX_TYPE~;
	}
}

// Floats, or integers normalized onto 0..1 — the two compressed forms the spec
// allows for weights, and the reason a file half the size deforms the same.
fn float[<4>]? read_weight_slots(gltf::GltfStream* stream, gltf::Accessor accessor, sz i) @local
{
	switch (accessor.data_type)
	{
		case gltf::DataType.FLOAT:
			return stream.@cast_buffer(accessor, i, float[<4>]);
		case gltf::DataType.CHAR:
			char[<4>] narrow = stream.@cast_buffer(accessor, i, char[<4>]);
			return (float[<4>]){ narrow[0], narrow[1], narrow[2], narrow[3] } / 255.0f;
		case gltf::DataType.USHORT:
			ushort[<4>] wide = stream.@cast_buffer(accessor, i, ushort[<4>]);
			return (float[<4>]){ wide[0], wide[1], wide[2], wide[3] } / 65535.0f;
		default:
			return UNSUPPORTED_INDEX_TYPE~;
	}
}

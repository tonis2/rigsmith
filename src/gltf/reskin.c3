<*
 Putting a new skeleton and a new skin into a model that already exists.

 The writers next door build a `.glb` from nothing: give them a mesh and a
 skeleton and they produce a file. That is the wrong shape for a rigging tool,
 because the model somebody brought in is not only a mesh — it has materials,
 textures, UVs, morph targets, extensions, and an author who would like all of
 it back. Rebuilding the file from a `TriMesh` returns a grey triangle soup.

 So this edits instead. Before appending the inverse bind matrices and the
 per-vertex `JOINTS_0` / `WEIGHTS_0`, an ordinary single-buffer GLB is compacted:
 accessors and buffer views no longer reachable after this rewrite are removed,
 live views are packed, and their standard glTF references are renumbered. Files
 with extensions or container shapes whose references cannot be classified keep
 the conservative append-only behaviour.

 	`gltf_edit::reskin_glb(mem, "character.glb", input)!;`

 **Joint nodes are reused by name.** A file whose skin already names `hips` gets
 its own `hips` node rewritten rather than a second one added beside it, so an
 animation channel that targets that node still targets that bone. Joint nodes
 the new rig has no use for are detached from the scene — their objects stay in
 `nodes`, because removing one would renumber every index in the file, but
 nothing reaches them.

 **The skeleton is re-rooted at the scene.** Whatever the joints hung under
 before — Blender writes an `Armature` empty and puts them inside it — the new
 root becomes a root of the scene, and every joint below it carries a pure
 translation. A joint's world transform is then its position and nothing else,
 so a caller who measured its positions in the mesh's own space gets them back
 unchanged. It also means a reused node keeps its identity and loses its old
 transform, which is the point — the rig moved, and the file is being told where
 it moved to.

 That makes the inverse bind matrices `translate(-position)` composed with
 `Reskin.bind` — and for the ordinary file, where `bind` is the identity,
 `translate(-position)` and nothing more. The exception is a file that placed its
 mesh through the skin rather than through a node, which is what an up-axis
 conversion above the joints amounts to: its vertices are not in the space its
 joints are measured in, the old bind matrices were what bridged the two, and the
 new ones have to bridge it the same way or the model lands back where it started
 out lying.

 **A reused node's object is rewritten whole**, so anything else on it — extras,
 a camera, its old rotation — goes. Nodes carrying a mesh are never reused for
 exactly this reason; a bone that is also a mesh parent gets a new node instead.

 **The animations are replaced by `Reskin.clips`**, and a caller that hands over
 none is saying the file should carry none. That looks destructive beside the
 rest of this and it is the only honest option: re-rooting the skeleton
 invalidates every channel that named a joint, whether the joint's node was
 detached — leaving the channel driving nothing — or reused, leaving it driving a
 node whose rest rotation is gone. Keeping them writes a file that claims an
 animation it cannot play. See `ReskinClip`.

 What this does not do: it does not touch positions, normals, UVs, materials,
 images or morph targets, and it does not renumber anything. A file that goes
 through it and comes back out is the same model with a different rig on it.

 Lives in crig rather than in `gltf.c3l` for the reason `patch.c3` gives: this is
 not a glTF feature, it is one tool's edit, and the library has no business
 carrying it. It still borrows the library for the parts that *are* general — the
 top-four weight selection is `gltf::sparsify_weights`, which the exporter next
 door uses too, and the two would have to agree even if this file copied it.
*>
module gltf_edit;

import gltf;
import std::collections::list;



import std::io::file;
import std::math::matrix;
import std::math::quaternion;
import std::math::vector;

<*
 Raised when the input does not describe a rig: no joints, no primitives, a
 weight matrix that is not `vertices * joints`, or a parent index naming nothing.
*>
faultdef RESKIN_SHAPE;

<*
 Raised when the file cannot take a skin written this way — a `.gltf` whose
 buffer lives in a separate `.bin`, or a `.glb` whose binary chunk is missing.

 Both are real files and neither is wrong; they just cannot be grown in place by
 something that only knows how to append to a chunk it can see.
*>
faultdef RESKIN_NO_BINARY;

<*
 One joint of the new skeleton.

 Positions are in the space the mesh's own vertex data is written in — *not*
 world space, unless the two happen to agree. For a model whose mesh is already
 skinned they do agree, because a skinned mesh node's transform is ignored and
 its vertices are already in the skin's space. For one that is not, the caller
 has to say so; see the module note.
*>
struct ReskinJoint
{
	String name;
	int parent; // -1 for the root
	Vec3 position;
}

<*
 One primitive of the model, and which rows of the weight matrix are its
 vertices.

 The rows have to be laid out in the order the caller's own flattener walks the
 scene, because that is the only order in which a single matrix over "the mesh"
 means anything. `base` and `count` are where this primitive's vertices sit in
 it.
*>
struct ReskinPart
{
	uint node;      // the node carrying the mesh; this is what gains the skin
	uint mesh;      // index into `meshes`
	uint primitive; // index into that mesh's primitives
	usz base;       // first row of `weights` belonging to this primitive
	usz count;      // how many rows
}

<*
 One joint's curve inside a re-authored clip.

 Both arrays are one entry per key time of the clip they belong to, or empty for
 a joint that does not do that thing — an arm that turns and never slides gets a
 rotation curve and no translation one, which is also what a reader makes of a
 missing channel, so the two agree about a joint left alone.

 The values are **local to the joint's node** as `reskin_glb` writes that node:
 re-rooted, resting on a pure translation and carrying no rotation of its own.
*>
struct ReskinCurve
{
	usz joint; // index into `Reskin.joints`
	Quaternionf[] turns;
	Vec3[] slides;
}

<*
 One animation, re-authored against the skeleton this reskin is writing.

 A clip is keyed against a hierarchy, and rewriting the skeleton throws that
 hierarchy away — the old joint nodes come off the scene, and the ones reused
 lose the rest rotation the clip's locals were composed against. So a clip that
 is to survive a reskin has to be *re-authored*, not repointed, which is what
 this carries: sampled key times, and per joint the values that reproduce the
 pose in the new frame.

 Every key time is shared by every curve in the clip, which is the shape glTF's
 samplers want and what lets one input accessor serve all of them.
*>
struct ReskinClip
{
	String name;
	float[] times;
	ReskinCurve[] curves;
}

<*
 Whether this clip is worth writing: keys to sample at, and something that moves
 at one of them.

 The three passes over the clips — laying out the bytes, writing them, and
 writing the JSON that names them — all skip on this one answer, so a clip that
 is in one pass is in all three. It also keeps an empty `animations` array out of
 the file, which glTF does not allow.
*>
fn bool ReskinClip.writable(&self)
{
	if (self.times.len == 0) return false;
	foreach (curve : self.curves)
	{
		if (curve.turns.len > 0 || curve.slides.len > 0) return true;
	}
	return false;
}

<*
 One axis of a joint's rotation limit, as the editor holds it: a range while
 `allowed`, else held at `locked`. Radians.
*>
struct ReskinLimitAxis
{
	bool allowed;
	float minimum;
	float maximum;
	float locked;
}

<*
 One joint's editor provenance, as the root `extras` row that sits beside its
 KHR physics joint: what the KHR rows cannot state — parked ranges on a locked
 axis, and the child and adjustment a fork's frame was built from.

 The one writer of this row. The pack exporter (`anim/constraint_gltf.c3`) and
 a save in place both call it, so the two files read the same.
*>
fn void write_constraint_provenance(DString* out, uint joint_node, String intent, int primary_node,
	Quaternionf adjustment, ReskinLimitAxis[3] axes)
{
	out.appendf(`{"joint":%d,"intent":"%s","primary":%d,"adjustment":%s,"axes":[`,
		joint_node, intent, primary_node,
		(JsonQuat)adjustment)!!;
	foreach (usz axis, held : axes)
	{
		if (axis > 0) out.append_char(',');
		out.appendf(`{"allowed":%s,"min":%s,"max":%s,"locked":%s}`,
			held.allowed, (JsonFloat)held.minimum, (JsonFloat)held.maximum, (JsonFloat)held.locked)!!;
	}
	out.append_string("]}");
}

<*
 One joint's rotation limit, to be written as the `KHR_physics_rigid_bodies`
 joint the exporter writes — two attachment nodes under the joint and its
 parent, coincident, sharing the frame, one zero-range linear weld and three
 one-axis angular rows — with the editor's provenance beside it in the root
 `extras`. See anim/constraint_gltf.c3, whose writer this mirrors row for row.

 `frame` is in the joints' own space, like `ReskinJoint.position`. `intent`,
 `primary` and `adjustment` are the provenance and nothing else reads them.
*>
struct ReskinConstraint
{
	usz joint;                 // index into `Reskin.joints`; a root joint is skipped
	Quaternionf frame;         // the bone-local frame both attachments are written in
	ReskinLimitAxis[3] axes;
	String intent;             // spelled as anim/constraint_gltf.c3 spells it
	int primary;               // index into `Reskin.joints`, or -1
	Quaternionf adjustment;
}

<*
 Everything one reskin needs.
*>
struct Reskin
{
	ReskinJoint[] joints;
	ReskinPart[] parts;

	// `vertices * joints.len`, vertex-major, unnormalised — the shape a binder
	// hands back. Reduced to four influences and renormalised on the way in.
	float[] weights;
	usz vertices;

	// The skin to rewrite, or -1 to add one. A file with no skin gets `skins`
	// created; a file with one keeps its index, so anything else pointing at it
	// keeps working.
	int skin;

	<*
	 What the file's own bind pose does to its vertices, which the new one has to
	 keep doing.

	 The positions in the file are not touched by a reskin, and they are not
	 necessarily the positions the caller has. A file whose joints hang under an
	 up-axis conversion holds its mesh in the space *below* that conversion, and
	 the skin is what lifts it out — so a rig written with an identity bind over
	 those same vertices puts the model back on its back.

	 `rig::skin_bind_matrix` is where this comes from, and it is the identity for
	 every file whose joints already sit at the scene root. **There is no safe
	 default**: a zeroed matrix collapses the model onto the origin, so a caller
	 that means "nothing to undo" has to say `matrix::IDENTITY4` and a singular one
	 is refused as `RESKIN_SHAPE` rather than written.
	*>
	Matrix4f bind;

	<*
	 The animations the rewritten file is to carry, which **replace** whatever it
	 had.

	 Replace rather than keep, because a reskin invalidates every channel that
	 named a joint: the old joint nodes are detached from the scene, so a channel
	 on one drives nothing, and a node reused as a joint has lost the rest rotation
	 its old locals were composed against, so a channel on that drives it wrongly.
	 A file left holding those is a file that claims an animation it does not have,
	 which is worse than one that admits to none — and it is what a model saved out
	 of crig used to look like in Blender: a character standing still with two foot
	 joints thrashing.

	 Empty therefore *clears* the file's animations. A caller with clips to keep
	 re-authors them against the skeleton it is writing — `crig::reskin_clips` is
	 that conversion — and a caller with none is saying there are none to keep.

	 A channel on something that was never a joint, a camera or a prop, is
	 collateral: it is dropped with the rest. Nothing crig writes has one.
	*>
	ReskinClip[] clips;

	<*
	 The joints' rotation limits, which the rewritten file is to carry the way
	 an exported one does — as `KHR_physics_rigid_bodies` joints a library read
	 adopts when this rig is fitted onto another model.

	 Like the clips, these **replace** whatever the file had: the writer owns
	 that extension in the file. Joint nodes are rewritten without the bodies
	 an export hung on them, every other node loses its entry, the root list of
	 joint settings is rewritten and the extension is declared or undeclared to
	 match. Attachment nodes are reused by name, so a save over a file that
	 already carries the limits neither grows it nor renumbers it.
	*>
	ReskinConstraint[] constraints;

	// Kept per vertex. glTF's own limit for one attribute set is four, and
	// nothing here writes a second set.
	uint influences;

	// The body-plan tag the model carries in `extras.plan`, so a save in place
	// stays the same plan an export writes and a re-save neither adds nor drops
	// it. Empty removes the tag; a plain word, no escaping needed.
	String plan;

	<*
	 New vertex positions for the parts, in the caller's space and in the same
	 rows as `weights` — or empty, the ordinary case, which leaves the file's
	 positions exactly as they are.

	 What a model scaled in crig needs: the vertices have to move with the rig, or
	 the skeleton written above would stand a different size from the mesh it
	 binds. They go in through `bind`'s inverse, since the caller's space is what
	 the file's positions become under that bind. Normals are not rewritten: the
	 one change this exists for is a uniform scale, which leaves them alone.
	*>
	Vec3[] positions;
}

// The extension the limits are written as, and the one the compaction knows.
const String RESKIN_PHYSICS_EXTENSION @local = "KHR_physics_rigid_bodies";

// A joint index is a ubyte while it fits in one, which halves the attribute on
// every rig anyone builds by hand.
const usz RESKIN_NARROW_JOINTS @local = 256;

const uint COMPONENT_UBYTE  @local = 5121;
const uint COMPONENT_USHORT @local = 5123;
const uint COMPONENT_FLOAT  @local = 5126;

<*
 Write a skeleton and a skin into a model, in place.

 	`gltf_edit::reskin_glb(mem, "character.glb", input)!;`

 The file is read whole, rebuilt in memory and written back over itself, so a
 failure part-way through leaves the original where it was.

 @param path : `The .glb to rewrite.`
 @return? RESKIN_SHAPE : `The input does not describe a rig.`
 @return? RESKIN_NO_BINARY : `The file has no binary chunk to grow.`
*>
fn void? reskin_glb(Allocator allocator, String path, Reskin input)
{
	usz bones = input.joints.len;
	if (bones == 0 || input.parts.len == 0 || input.vertices == 0) return RESKIN_SHAPE~;
	if (input.weights.len != input.vertices * bones) return RESKIN_SHAPE~;

	// A caller that left `bind` at its zero value gets a refusal rather than a
	// model folded onto the origin, which is the one mistake this input makes
	// easy to make and impossible to see afterwards.
	if (input.bind.determinant() == 0.0f) return RESKIN_SHAPE~;

	int root = -1;
	foreach (usz j, joint : input.joints)
	{
		if (joint.parent >= (int)bones || joint.parent == (int)j) return RESKIN_SHAPE~;
		if (joint.parent < 0)
		{
			// One root, because the skeleton is re-rooted at the scene and a second
			// root would be a second armature with no rule for which one the skin's
			// `skeleton` names.
			if (root >= 0) return RESKIN_SHAPE~;
			root = (int)j;
		}
	}
	if (root < 0) return RESKIN_SHAPE~;

	foreach (part : input.parts)
	{
		if (part.base + part.count > input.vertices) return RESKIN_SHAPE~;
	}
	if (input.positions.len > 0 && input.positions.len != input.vertices) return RESKIN_SHAPE~;

	// A curve is one value per key time of its clip, and it drives a joint this
	// skeleton has. Checked rather than clamped: either is a caller that built the
	// clip against a different rig, and writing what it asked for would put a
	// sampler over the end of its own accessor.
	foreach (clip : input.clips)
	{
		foreach (curve : clip.curves)
		{
			if (curve.joint >= bones) return RESKIN_SHAPE~;
			if (curve.turns.len > 0 && curve.turns.len != clip.times.len) return RESKIN_SHAPE~;
			if (curve.slides.len > 0 && curve.slides.len != clip.times.len) return RESKIN_SHAPE~;
		}
	}

	GlbParts parts = split_glb(allocator, path)!;
	defer parts.free(allocator);
	if (!parts.binary) return RESKIN_NO_BINARY~;

	BinChunk bin = split_bin(parts.rest)!;

	// --- the bytes ---------------------------------------------------------

	gltf::SkinBinding binding = gltf::sparsify_weights(
		allocator, input.weights, input.vertices, bones,
		input.influences == 0 ? 4 : input.influences)!;
	defer binding.free(allocator);

	bool wide = bones >= RESKIN_NARROW_JOINTS;
	usz joint_stride = wide ? 8 : 4;

	usz ibm_len = bones * 64;
	usz joints_len = input.vertices * joint_stride;
	usz weights_len = input.vertices * 16;

	// Each view starts on a four-byte boundary. glTF requires an accessor's
	// effective offset to be a multiple of its component size, and the largest
	// component here is four bytes.
	usz positions_len = input.positions.len * 12;

	usz ibm_at = 0;
	usz joints_at = align4(ibm_at + ibm_len);
	usz weights_at = align4(joints_at + joints_len);
	usz positions_at = align4(weights_at + weights_len);
	usz anim_at = align4(positions_at + positions_len);

	AnimBlock[] blocks = plan_anim_blocks(allocator, input.clips, anim_at);
	defer if (blocks.len > 0) alloc::free(allocator, blocks);

	usz added_len = blocks.len > 0
		? blocks[^1].at + blocks[^1].len()
		: positions_at + positions_len;

	// The new positions in the file's own space: the caller's, taken back through
	// the bind the loader will apply to them again.
	Vec3[] file_positions;
	defer if (file_positions.len > 0) alloc::free(allocator, file_positions);
	if (input.positions.len > 0)
	{
		Matrix4f unbind = input.bind.inverse() ?? matrix::IDENTITY4;
		file_positions = alloc::new_array(allocator, Vec3, (sz)input.positions.len);
		foreach (usz v, p : input.positions) file_positions[v] = (unbind * (Vec4){ p.x, p.y, p.z, 1 }).xyz;
	}

	char[] added = alloc::new_array(allocator, char, (sz)added_len);
	defer alloc::free(allocator, added);

	// The inverse bind matrix of a joint whose world transform is a translation is
	// the opposite translation, then whatever the file's own bind was doing to its
	// vertices — the skinning sum has to land them where they already were, and
	// the positions themselves are not being rewritten.
	//
	// Straight out of `m` and into the buffer: glTF stores a matrix column-major
	// and so does `Matrix4f`, which is why the translation lands in the last four
	// floats rather than every fourth one.
	foreach (usz j, joint : input.joints)
	{
		Matrix4f shift = matrix::IDENTITY4;
		shift.m03 = -joint.position.x;
		shift.m13 = -joint.position.y;
		shift.m23 = -joint.position.z;
		Matrix4f inverse_bind = shift.mul(input.bind);

		usz at = ibm_at + j * 64;
		for (usz i = 0; i < 16; i++) blob_f32(added, at + i * 4, inverse_bind.m[i]);
	}

	for (usz v = 0; v < input.vertices; v++)
	{
		usz from = v * binding.slots;
		usz to = joints_at + v * joint_stride;
		for (usz s = 0; s < 4; s++)
		{
			ushort held = binding.joints[from + s];
			if (wide) { blob_u16(added, to + s * 2, held); } else { added[to + s] = (char)held; }
			blob_f32(added, weights_at + v * 16 + s * 4, binding.weights[from + s]);
		}
	}

	foreach (usz v, p : file_positions)
	{
		usz at = positions_at + v * 12;
		blob_f32(added, at, p.x);
		blob_f32(added, at + 4, p.y);
		blob_f32(added, at + 8, p.z);
	}

	write_anim_bytes(added, input.clips, blocks);

	// Where the new bytes land in the buffer. The chunk's own length rather than
	// the buffer's declared one: the two differ by up to three bytes of pad, and
	// starting past the pad is what keeps every offset already in the file valid.
	usz buffer_at = align4(bin.payload.len);
	usz buffer_len = buffer_at + added_len;

	// --- the document ------------------------------------------------------

	String text = ((String)parts.json).copy(allocator);
	defer alloc::free(allocator, text.ptr);

	// Once the semantic roots are replaced, mark and pack everything still live
	// before choosing the offsets for this write. Unknown extension
	// objects make accessor/view indices opaque; in that case this deliberately
	// does nothing and keeps the old append-only behaviour.
	char[] packed = {};
	String compacted = bin.tail.len == 0
		? compact_replaced_payload(allocator, text, input, bin.payload, &packed)!
		: text;
	if (compacted.ptr != text.ptr)
	{
		alloc::free(allocator, text.ptr);
		text = compacted;
		bin.payload = packed;
	}
	defer if (packed.len > 0) alloc::free(allocator, packed);

	// Recompute against the compacted payload. This is what makes a second save
	// byte-for-byte stable in size instead of appending another skin block.
	buffer_at = align4(bin.payload.len);
	buffer_len = buffer_at + added_len;

	Rewrite plan = plan_rewrite(allocator, text, input, root)!;
	defer plan.free(allocator);

	String edited = write_document(allocator, text, input, plan, {
		.root = root,
		.buffer_at = buffer_at,
		.buffer_len = buffer_len,
		.ibm_at = ibm_at,
		.ibm_len = ibm_len,
		.joints_at = joints_at,
		.joints_len = joints_len,
		.weights_at = weights_at,
		.weights_len = weights_len,
		.positions_at = positions_at,
		.positions = file_positions,
		.joint_stride = joint_stride,
		.wide = wide,
		.blocks = blocks,
	})!;

	// --- back into the container -------------------------------------------

	// New, rather than grown in place, because `bin.payload` and `bin.tail` are
	// slices of the run this replaces. Zeroed on allocation, which is what fills
	// the pad between the old buffer's end and the four-byte boundary the new
	// views start on.
	usz payload_len = align4(buffer_len);
	char[] grown = alloc::new_array(allocator, char, (sz)(8 + payload_len + bin.tail.len));

	write_u32(grown, 0, (uint)payload_len);
	write_u32(grown, 4, GLB_CHUNK_BIN);
	grown[8 : bin.payload.len] = bin.payload[..];
	grown[8 + buffer_at : added_len] = added[..];
	if (bin.tail.len > 0) grown[8 + payload_len : bin.tail.len] = bin.tail[..];

	// Handed over, not aliased: `parts.free` is what releases both from here on,
	// which is the rule `GlbParts.free` states.
	alloc::free(allocator, parts.json);
	parts.json = (char[])edited;
	alloc::free(allocator, parts.rest);
	parts.rest = grown;

	return write_glb(path, parts);
}

fn usz align4(usz at) @local => (at + 3) & ~(usz)3;

// Remove unreachable accessors and views, remap standard references, and pack
// live view ranges. The returned string aliases `text` on conservative fallback.
fn String? compact_replaced_payload(Allocator allocator, String text, Reskin input, char[] payload, char[]* packed_out) @local
{
	// An extension may reference any accessor or view, so a file carrying one
	// keeps the append-only behaviour — except the ones known to name none, like
	// crig's own physics or a material's. Without this a rig exported with its
	// limits grew by a whole skin on every save, and so did any model whose
	// materials use an extension (a Tripo export: 0.7MB grew to 16MB).
	if (try sz unused = text.index_of(`"extensions"`))
	{
		if (!only_index_free_extensions(allocator, text)!) return text;
	}
	// An escaped object key cannot be classified without decoding it. Fall back
	// rather than risk treating an escaped `extensions` as ordinary metadata.
	if (try sz unused = text.index_of(`\u`)) return text;

	JsonStep[1] accessor_path = { { .key = "accessors" } };
	JsonStep[1] view_path = { { .key = "bufferViews" } };
	String accessor_text = read_gltf_member(text, accessor_path[..]);
	String view_text = read_gltf_member(text, view_path[..]);
	if (accessor_text.len == 0 || view_text.len == 0) return text;
	JsonStep[1] buffers_path = { { .key = "buffers" } };
	String buffers_text = read_gltf_member(text, buffers_path[..]);
	if (buffers_text.len == 0) return text;
	String[] buffers = json_array_items(allocator, buffers_text)!;
	defer alloc::free(allocator, buffers);
	if (buffers.len != 1 || read_gltf_member(buffers[0], (JsonStep[]){ { .key = "uri" } }).len > 0) return text;

	String[] accessors = json_array_items(allocator, accessor_text)!;
	defer alloc::free(allocator, accessors);
	String[] views = json_array_items(allocator, view_text)!;
	defer alloc::free(allocator, views);
	bool[] live_accessors = alloc::new_array(allocator, bool, (sz)accessors.len);
	defer alloc::free(allocator, live_accessors);

	// Mesh indices and attributes, except the exact attributes this call replaces.
	JsonStep[1] meshes_path = { { .key = "meshes" } };
	mark_mesh_accessors(allocator, read_gltf_member(text, meshes_path[..]), input, live_accessors)!;

	// Every other skin survives. The selected skin's IBM is replaced below.
	JsonStep[1] skins_path = { { .key = "skins" } };
	String skins_text = read_gltf_member(text, skins_path[..]);
	if (skins_text.len > 0)
	{
		String[] skins = json_array_items(allocator, skins_text)!;
		defer alloc::free(allocator, skins);
		foreach (usz i, skin : skins)
		{
			if ((int)i == input.skin) continue;
			mark_member_index(skin, "inverseBindMatrices", live_accessors);
		}
	}

	// Indices and arbitrary named attributes can occur at the top of primitives;
	// animations are intentionally omitted because this operation replaces them.
	bool[] live_views = alloc::new_array(allocator, bool, (sz)views.len);
	defer alloc::free(allocator, live_views);
	for (usz i = 0; i < accessors.len; i++) if (live_accessors[i])
	{
		mark_member_index(accessors[i], "bufferView", live_views);
		JsonStep[2] sparse_indices = { { .key = "sparse" }, { .key = "indices" } };
		JsonStep[2] sparse_values = { { .key = "sparse" }, { .key = "values" } };
		mark_member_index(read_gltf_member(accessors[i], sparse_indices[..]), "bufferView", live_views);
		mark_member_index(read_gltf_member(accessors[i], sparse_values[..]), "bufferView", live_views);
	}
	JsonStep[1] images_path = { { .key = "images" } };
	String images_text = read_gltf_member(text, images_path[..]);
	if (images_text.len > 0)
	{
		String[] images = json_array_items(allocator, images_text)!;
		defer alloc::free(allocator, images);
		foreach (image : images) mark_member_index(image, "bufferView", live_views);
	}
	usz[] accessor_map = alloc::new_array(allocator, usz, (sz)accessors.len);
	defer alloc::free(allocator, accessor_map);
	usz[] view_map = alloc::new_array(allocator, usz, (sz)views.len);
	defer alloc::free(allocator, view_map);
	usz accessor_count = 0;
	foreach (usz i, live : live_accessors) if (live) accessor_map[i] = accessor_count++;
	usz view_count = 0;
	foreach (usz i, live : live_views) if (live) view_map[i] = view_count++;

	usz packed_len = 0;
	usz[] offsets = alloc::new_array(allocator, usz, (sz)views.len);
	defer alloc::free(allocator, offsets);
	foreach (usz i, view : views)
	{
		JsonStep[1] buffer_path = { { .key = "buffer" } };
		JsonStep[1] offset_path = { { .key = "byteOffset" } };
		JsonStep[1] length_path = { { .key = "byteLength" } };
		String raw_buffer = read_gltf_member(view, buffer_path[..]);
		if (raw_buffer.len > 0 && parse_uint(raw_buffer)! != 0) return text;
		String raw_offset = read_gltf_member(view, offset_path[..]);
		String raw_length = read_gltf_member(view, length_path[..]);
		usz offset = raw_offset.len > 0 ? (usz)parse_uint(raw_offset)! : 0;
		usz length = raw_length.len > 0 ? (usz)parse_uint(raw_length)! : 0;
		if (offset > payload.len || length > payload.len - offset) return text;
		if (live_views[i]) { packed_len = align4(packed_len); offsets[i] = packed_len; packed_len += length; }
	}
	if (packed_len == payload.len) return text;

	char[] packed = alloc::new_array(allocator, char, (sz)packed_len);
	String working = text.copy(allocator);
	bool kept = false;
	defer if (!kept) { alloc::free(allocator, packed); alloc::free(allocator, working.ptr); }

	DString rewritten = dstring::new(allocator);
	defer rewritten.free();
	rewritten.append_char('[');
	bool first_view = true;
	foreach (usz i, view : views)
	{
		if (!live_views[i]) continue;
		if (!first_view) rewritten.append_char(',');
		first_view = false;
		JsonStep[1] offset_path = { { .key = "byteOffset" } };
		JsonStep[1] length_path = { { .key = "byteLength" } };
		String raw_offset = read_gltf_member(view, offset_path[..]);
		String raw_length = read_gltf_member(view, length_path[..]);
		usz old = raw_offset.len > 0 ? (usz)parse_uint(raw_offset)! : 0;
		usz length = (usz)parse_uint(raw_length)!;
		packed[offsets[i] : length] = payload[old : length];
		String owned = view.copy(allocator);
		defer alloc::free(allocator, owned.ptr);
		owned = set_number(allocator, owned, offset_path[..], offsets[i])!;
		rewritten.append_string(owned);
	}
	rewritten.append_char(']');
	working = replace_raw(allocator, working, "bufferViews", rewritten.str_view())!;

	// Retained accessors keep all author metadata, with only their buffer-view
	// references changed. Sparse accessors have two additional view references.
	rewritten.clear(); rewritten.append_char('[');
	bool first_accessor = true;
	foreach (usz i, accessor : accessors)
	{
		if (!live_accessors[i]) continue;
		String owned = accessor.copy(allocator);
		defer alloc::free(allocator, owned.ptr);
		owned = remap_member_owned(allocator, owned, (JsonStep[]){ { .key = "bufferView" } }, view_map, live_views)!;
		owned = remap_member_owned(allocator, owned, (JsonStep[]){ { .key = "sparse" }, { .key = "indices" }, { .key = "bufferView" } }, view_map, live_views)!;
		owned = remap_member_owned(allocator, owned, (JsonStep[]){ { .key = "sparse" }, { .key = "values" }, { .key = "bufferView" } }, view_map, live_views)!;
		if (!first_accessor) rewritten.append_char(',');
		first_accessor = false;
		rewritten.append_string(owned);
	}
	rewritten.append_char(']');
	working = replace_raw(allocator, working, "accessors", rewritten.str_view())!;
	String rooted = remap_root_references(allocator, working, input, accessor_map, live_accessors, view_map, live_views)!;
	alloc::free(allocator, working.ptr);
	working = rooted;
	*packed_out = packed;
	kept = true;
	return working;
}

// Extensions whose objects never name an accessor, a buffer view or a buffer —
// materials, texture sources (which name images, and images are walked), lights,
// and crig's own physics, whose references are meshes and nodes. A file using
// only these still has every accessor and view reference in a standard place.
// Anything else (Draco, meshopt, GPU instancing, an unknown vendor's) may hide one,
// so the file keeps the append-only behaviour.
const String[] INDEX_FREE_EXTENSIONS = {
	"KHR_physics_rigid_bodies", "KHR_implicit_shapes", "KHR_texture_transform",
	"KHR_lights_punctual", "KHR_mesh_quantization", "KHR_texture_basisu",
	"EXT_texture_webp", "EXT_texture_avif", "FB_ngon_encoding",
};

fn bool index_free_extension(String quoted) @local
{
	if (quoted.len < 2 || quoted[0] != '"' || quoted[^1] != '"') return false;
	String name = quoted[1 .. ^2];
	if (name.starts_with("KHR_materials_")) return true;
	foreach (known : INDEX_FREE_EXTENSIONS) if (name == known) return true;
	return false;
}

// Whether every extension the file declares is one `index_free_extension` knows.
// glTF requires every extension in use to be listed in `extensionsUsed`, so the
// list is what decides; a file that declares none and still carries an
// `extensions` object is malformed and is left alone.
fn bool? only_index_free_extensions(Allocator allocator, String text) @local
{
	JsonStep[1] used_path = { { .key = "extensionsUsed" } };
	String used_text = read_gltf_member(text, used_path[..]);
	if (used_text.len == 0) return false;
	String[] used = json_array_items(allocator, used_text)!;
	defer alloc::free(allocator, used);
	if (used.len == 0) return false;
	foreach (name : used) if (!index_free_extension(name)) return false;

	JsonStep[1] required_path = { { .key = "extensionsRequired" } };
	String required_text = read_gltf_member(text, required_path[..]);
	if (required_text.len == 0) return true;
	String[] required = json_array_items(allocator, required_text)!;
	defer alloc::free(allocator, required);
	foreach (name : required) if (!index_free_extension(name)) return false;
	return true;
}

// Remap a numeric member when it exists. `object` is owned and remains owned by
// the caller; this mirrors set_number's ownership convention.
fn String? remap_member_owned(Allocator allocator, String object, JsonStep[] path, usz[] map, bool[] live) @local
{
	String raw = read_gltf_member(object, path);
	if (raw.len == 0) return object;
	usz old = (usz)parse_uint(raw)!;
	if (old >= live.len || !live[old]) return GLTF_PATCH_MALFORMED~;
	return set_number(allocator, object, path, map[old]);
}

// An attribute object is the one standard glTF reference map whose keys are
// open-ended. Preserve every key byte-for-byte and replace only its integer.
fn String? remap_attribute_object(Allocator allocator, String object, usz[] map, bool[] live) @local
{
	DString out = dstring::new(allocator);
	defer out.free();
	usz copied = 0;
	usz at = 1;
	while (at < object.len && object[at] != '}')
	{
		while (at < object.len && (object[at] == ' ' || object[at] == '\n' || object[at] == '\r' || object[at] == '\t' || object[at] == ',')) at++;
		if (at < object.len && object[at] == '}') break;
		if (at >= object.len || object[at] != '"') return GLTF_PATCH_MALFORMED~;
		at++;
		while (at < object.len && object[at] != '"') { if (object[at] == '\\') at++; at++; }
		if (at >= object.len) return GLTF_PATCH_MALFORMED~;
		at++;
		while (at < object.len && object[at] != ':') at++;
		if (at >= object.len) return GLTF_PATCH_MALFORMED~;
		at++;
		while (at < object.len && (object[at] == ' ' || object[at] == '\n' || object[at] == '\r' || object[at] == '\t')) at++;
		usz start = at;
		while (at < object.len && object[at] >= '0' && object[at] <= '9') at++;
		if (at == start) return GLTF_PATCH_MALFORMED~;
		usz old = (usz)parse_uint(object[start:at - start])!;
		if (old >= live.len) return GLTF_PATCH_MALFORMED~;
		out.append_string(object[copied:start - copied]);
		// The selected primitives' JOINTS_0/WEIGHTS_0 are deliberately dead and
		// write_document replaces these temporary zeroes immediately afterwards.
		out.appendf("%d", live[old] ? map[old] : 0);
		copied = at;
	}
	out.append_string(object[copied..]);
	return out.copy_str(allocator);
}

fn String? remap_root_references(Allocator allocator, String text, Reskin input,
	usz[] accessor_map, bool[] live_accessors, usz[] view_map, bool[] live_views) @local
{
	String working = text.copy(allocator);
	bool kept = false;
	defer if (!kept) alloc::free(allocator, working.ptr);
	JsonStep[1] meshes_path = { { .key = "meshes" } };
	String raw_meshes = read_gltf_member(working, meshes_path[..]);
	String[] meshes = json_array_items(allocator, raw_meshes)!;
	defer alloc::free(allocator, meshes);
	DString outer = dstring::new(allocator); defer outer.free(); outer.append_char('[');
	foreach (usz m, mesh : meshes)
	{
		String owned_mesh = mesh.copy(allocator);
		defer alloc::free(allocator, owned_mesh.ptr);
		JsonStep[1] primitives_path = { { .key = "primitives" } };
		String[] primitives = json_array_items(allocator, read_gltf_member(mesh, primitives_path[..]))!;
		defer alloc::free(allocator, primitives);
		DString list = dstring::new(allocator);
		defer list.free();
		list.append_char('[');
		foreach (usz p, primitive : primitives)
		{
			String owned = primitive.copy(allocator);
			defer alloc::free(allocator, owned.ptr);
			owned = remap_member_owned(allocator, owned, (JsonStep[]){ { .key = "indices" } }, accessor_map, live_accessors)!;
			String attrs = read_gltf_member(owned, (JsonStep[]){ { .key = "attributes" } });
			if (attrs.len > 0)
			{
				String remapped = remap_attribute_object(allocator, attrs, accessor_map, live_accessors)!;
				defer alloc::free(allocator, remapped.ptr);
				String next = patch_raw(allocator, owned, (JsonStep[]){ { .key = "attributes" } }, remapped)!;
				alloc::free(allocator, owned.ptr); owned = next;
			}
			String targets_raw = read_gltf_member(owned, (JsonStep[]){ { .key = "targets" } });
			if (targets_raw.len > 0)
			{
				String[] targets = json_array_items(allocator, targets_raw)!;
				defer alloc::free(allocator, targets);
				DString target_list = dstring::new(allocator);
				defer target_list.free();
				target_list.append_char('[');
				foreach (usz t, target : targets)
				{
					if (t > 0) target_list.append_char(',');
					String remapped = remap_attribute_object(allocator, target, accessor_map, live_accessors)!;
					defer alloc::free(allocator, remapped.ptr);
					target_list.append_string(remapped);
				}
				target_list.append_char(']');
				String next = patch_raw(allocator, owned, (JsonStep[]){ { .key = "targets" } }, target_list.str_view())!;
				alloc::free(allocator, owned.ptr); owned = next;
			}
			if (p > 0) list.append_char(','); list.append_string(owned);
		}
		list.append_char(']');
		String next_mesh = patch_raw(allocator, owned_mesh, primitives_path[..], list.str_view())!;
		alloc::free(allocator, owned_mesh.ptr); owned_mesh = next_mesh;
		if (m > 0) outer.append_char(','); outer.append_string(owned_mesh);
	}
	outer.append_char(']'); working = replace_raw(allocator, working, "meshes", outer.str_view())!;

	// Non-selected skins and embedded images are the remaining standard roots.
	foreach (key : (String[]){ "skins", "images" })
	{
		JsonStep[1] root_path = { { .key = key } };
		String raw = read_gltf_member(working, root_path[..]);
		if (raw.len == 0) continue;
		String[] items = json_array_items(allocator, raw)!;
		defer alloc::free(allocator, items);
		DString list = dstring::new(allocator);
		defer list.free();
		list.append_char('[');
		foreach (usz i, item : items)
		{
			String owned = item.copy(allocator);
			defer alloc::free(allocator, owned.ptr);
			if (key == "skins" && (int)i != input.skin) owned = remap_member_owned(allocator, owned, (JsonStep[]){ { .key = "inverseBindMatrices" } }, accessor_map, live_accessors)!;
			if (key == "images") owned = remap_member_owned(allocator, owned, (JsonStep[]){ { .key = "bufferView" } }, view_map, live_views)!;
			if (i > 0) list.append_char(','); list.append_string(owned);
		}
		list.append_char(']'); working = replace_raw(allocator, working, key, list.str_view())!;
	}
	kept = true;
	return working;
}

fn void mark_member_index(String object, String key, bool[] live) @local
{
	if (object.len == 0) return;
	JsonStep[1] path = { { .key = key } };
	String raw = read_gltf_member(object, path[..]);
	if (raw.len == 0) return;
	if (try uint value = parse_uint(raw)) if ((usz)value < live.len) live[value] = true;
}

fn void? mark_attribute_object(Allocator allocator, String object, bool[] live) @local
{
	if (object.len == 0) return;
	// Attribute keys are arbitrary and may themselves contain punctuation. Walk
	// quoted keys (including escapes), then the integer value after their colon.
	usz at = 1;
	while (at < object.len && object[at] != '}')
	{
		while (at < object.len && (object[at] == ' ' || object[at] == '\n' || object[at] == '\r' || object[at] == '\t' || object[at] == ',')) at++;
		if (at < object.len && object[at] == '}') break;
		if (at >= object.len || object[at] != '"') return GLTF_PATCH_MALFORMED~;
		at++;
		while (at < object.len && object[at] != '"') { if (object[at] == '\\') at++; at++; }
		if (at >= object.len) return GLTF_PATCH_MALFORMED~;
		at++;
		while (at < object.len && (object[at] == ' ' || object[at] == '\n' || object[at] == '\r' || object[at] == '\t')) at++;
		if (at >= object.len || object[at] != ':') return GLTF_PATCH_MALFORMED~;
		at++;
		while (at < object.len && (object[at] == ' ' || object[at] == '\n' || object[at] == '\r' || object[at] == '\t')) at++;
		usz end = at;
		while (end < object.len && object[end] >= '0' && object[end] <= '9') end++;
		if (end == at) return GLTF_PATCH_MALFORMED~;
		uint value = parse_uint(object[at:end - at])!;
		if ((usz)value < live.len) live[value] = true;
		at = end;
	}
}

fn void? mark_mesh_accessors(Allocator allocator, String meshes_text, Reskin input, bool[] live) @local
{
	if (meshes_text.len == 0) return;
	String[] meshes = json_array_items(allocator, meshes_text)!;
	defer alloc::free(allocator, meshes);
	foreach (usz m, mesh : meshes)
	{
		JsonStep[1] primitives_path = { { .key = "primitives" } };
		String raw = read_gltf_member(mesh, primitives_path[..]);
		if (raw.len == 0) continue;
		String[] primitives = json_array_items(allocator, raw)!;
		defer alloc::free(allocator, primitives);
		foreach (usz p, primitive : primitives)
		{
			mark_member_index(primitive, "indices", live);
			JsonStep[1] attributes_path = { { .key = "attributes" } };
			String attributes = read_gltf_member(primitive, attributes_path[..]);
			bool replaced = false;
			foreach (part : input.parts) if ((usz)part.mesh == m && (usz)part.primitive == p) { replaced = true; break; }
			if (replaced)
			{
				// Mark every attribute except the ones being replaced: the two skin
				// attributes always, and POSITION when the positions are rewritten too.
				JsonEdit[3] drops = {
					{ .path = (JsonStep[]){ { .key = "JOINTS_0" } }, .value = "" },
					{ .path = (JsonStep[]){ { .key = "WEIGHTS_0" } }, .value = "" },
					{ .path = (JsonStep[]){ { .key = "POSITION" } }, .value = "" },
				};
				String scrubbed = patch_gltf_text(allocator, attributes, drops[:(usz)(input.positions.len > 0 ? 3 : 2)])!;
				defer alloc::free(allocator, scrubbed.ptr);
				mark_attribute_object(allocator, scrubbed, live)!;
			}
			else { mark_attribute_object(allocator, attributes, live)!; }
			JsonStep[1] targets_path = { { .key = "targets" } };
			String targets_text = read_gltf_member(primitive, targets_path[..]);
			if (targets_text.len > 0)
			{
				String[] targets = json_array_items(allocator, targets_text)!;
				defer alloc::free(allocator, targets);
				foreach (target : targets) mark_attribute_object(allocator, target, live)!;
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The re-authored clips

<*
 One appended run of animation bytes, and the accessor that will name it.

 Laid out once and walked twice — by the pass that writes the floats and by the
 pass that writes the accessors — because the two have to agree about every
 offset and a second copy of the arithmetic is a second chance to be wrong. The
 order is fixed: per clip its key times, then per curve its rotations and then
 its translations, skipping the ones that are empty.

 `components` is what makes it an accessor: 1 is the SCALAR run of times, 4 a
 VEC4 of quaternions, 3 a VEC3 of translations.
*>
struct AnimBlock @local
{
	usz at;
	usz count;
	usz components;

	// The span of the key times, for the SCALAR block that holds them. glTF
	// requires `min` and `max` on a sampler's input accessor and on nothing else
	// here, so these are filled for that block alone and read for that one alone.
	float low;
	float high;
}

fn usz AnimBlock.len(&self) => self.count * self.components * 4;

// Every block of every clip, in the one order both passes walk. `base` is where
// the animation bytes start inside the appended block; every run is a multiple
// of four bytes long, so a four-aligned base keeps all of them aligned.
fn AnimBlock[] plan_anim_blocks(Allocator allocator, ReskinClip[] clips, usz base) @local
{
	usz total = 0;
	foreach (clip : clips)
	{
		if (!clip.writable()) continue;
		total++;
		foreach (curve : clip.curves)
		{
			if (curve.turns.len > 0) total++;
			if (curve.slides.len > 0) total++;
		}
	}

	AnimBlock[] blocks = alloc::new_array(allocator, AnimBlock, (sz)total);
	usz at = base;
	usz written = 0;

	foreach (clip : clips)
	{
		if (!clip.writable()) continue;

		float low = clip.times[0];
		float high = clip.times[0];
		foreach (time : clip.times)
		{
			if (time < low) low = time;
			if (time > high) high = time;
		}

		blocks[written] = {
			.at = at, .count = clip.times.len, .components = 1,
			.low = low, .high = high,
		};
		at += blocks[written++].len();

		foreach (curve : clip.curves)
		{
			if (curve.turns.len > 0)
			{
				blocks[written] = { .at = at, .count = curve.turns.len, .components = 4 };
				at += blocks[written++].len();
			}
			if (curve.slides.len > 0)
			{
				blocks[written] = { .at = at, .count = curve.slides.len, .components = 3 };
				at += blocks[written++].len();
			}
		}
	}

	return blocks;
}

// The floats themselves, into the runs `plan_anim_blocks` set aside. Walks the
// clips in exactly the order that did.
fn void write_anim_bytes(char[] added, ReskinClip[] clips, AnimBlock[] blocks) @local
{
	usz block = 0;
	foreach (clip : clips)
	{
		if (!clip.writable()) continue;

		usz at = blocks[block++].at;
		foreach (usz k, time : clip.times) blob_f32(added, at + k * 4, time);

		foreach (curve : clip.curves)
		{
			if (curve.turns.len > 0)
			{
				usz to = blocks[block++].at;
				foreach (usz k, turn : curve.turns)
				{
					// glTF wants a quaternion as xyzw, which is the order `Quaternionf.v`
					// already holds them in.
					for (usz c = 0; c < 4; c++) blob_f32(added, to + k * 16 + c * 4, turn.v[c]);
				}
			}
			if (curve.slides.len > 0)
			{
				usz to = blocks[block++].at;
				foreach (usz k, slide : curve.slides)
				{
					for (usz c = 0; c < 3; c++) blob_f32(added, to + k * 12 + c * 4, slide[c]);
				}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The container's binary chunk

struct BinChunk @local
{
	char[] payload;
	char[] tail; // whatever chunks follow, copied through
}

// `rest` as `split_glb` hands it over: the BIN chunk's header, its payload, and
// any later chunk. A file whose second chunk is not BIN has nowhere to put the
// new bytes.
fn BinChunk? split_bin(char[] rest) @local
{
	if (rest.len < 8) return RESKIN_NO_BINARY~;
	usz length = (usz)read_u32(rest, 0);
	if (read_u32(rest, 4) != GLB_CHUNK_BIN) return RESKIN_NO_BINARY~;
	if (8 + length > rest.len) return RESKIN_NO_BINARY~;

	return {
		.payload = rest[8 : length],
		.tail = 8 + length < rest.len ? rest[8 + length..] : (char[]){},
	};
}

fn void blob_f32(char[] out, usz at, float value) @local => write_u32(out, at, bitcast(value, uint));
fn void blob_u16(char[] out, usz at, ushort value) @local => bitorder::write(value, out[at:2], UShortLE);

// ---------------------------------------------------------------------------
// Which node each joint becomes
//
// Worked out before a single byte is written, because every index that goes
// into the document depends on it and an index that changed halfway through
// would be an index pointing at the wrong bone.

struct Rewrite @local
{
	// Every node the file already has, as the text it is written as. Borrowed
	// from the document, so this dies with it.
	String[] items;

	// Per joint: the existing node it takes over, or -1 for one being added.
	int[] reuse;

	// Per joint: the node index it ends up at, reused or added.
	uint[] node_of;

	// Per existing node: whether the new skeleton reaches it. Both the reused
	// ones and the ones being retired, because both have to stop being anybody
	// else's child — a retired joint stays in `nodes` and must not stay in the
	// scene, and a reused one is being re-rooted.
	bool[] detach;

	// Per constraint: the two attachment nodes it is written on, reused by name
	// or added, and whether it is written at all (a root joint's is not).
	uint[] attach_parent;
	uint[] attach_child;
	bool[] attached;

	usz added;
}

fn void Rewrite.free(&self, Allocator allocator)
{
	if (self.items.len > 0) alloc::free(allocator, self.items);
	if (self.reuse.len > 0) alloc::free(allocator, self.reuse);
	if (self.node_of.len > 0) alloc::free(allocator, self.node_of);
	if (self.detach.len > 0) alloc::free(allocator, self.detach);
	if (self.attach_parent.len > 0) alloc::free(allocator, self.attach_parent);
	if (self.attach_child.len > 0) alloc::free(allocator, self.attach_child);
	if (self.attached.len > 0) alloc::free(allocator, self.attached);
	*self = {};
}

fn Rewrite? plan_rewrite(Allocator allocator, String text, Reskin input, int root) @local
{
	JsonStep[1] nodes_path = { { .key = "nodes" } };
	String nodes_text = read_gltf_member(text, nodes_path[..]);

	Rewrite plan;
	plan.items = nodes_text.len > 0 ? json_array_items(allocator, nodes_text)! : (String[]){};
	bool kept = false;
	defer if (!kept) plan.free(allocator);

	usz existing = plan.items.len;
	plan.reuse = alloc::new_array(allocator, int, (sz)input.joints.len);
	plan.node_of = alloc::new_array(allocator, uint, (sz)input.joints.len);
	plan.detach = alloc::new_array(allocator, bool, (sz)existing);

	// The nodes the file already calls bones. Only these are candidates for
	// reuse: a node with a matching name that was never a joint is somebody
	// else's — a mesh called `head`, a locator, an empty — and taking it over
	// would move whatever hangs off it.
	bool[] was_joint = alloc::new_array(allocator, bool, (sz)existing);
	defer alloc::free(allocator, was_joint);

	if (input.skin >= 0)
	{
		JsonStep[3] joints_path = { { .key = "skins" }, { .at = (usz)input.skin }, { .key = "joints" } };
		String joints_text = read_gltf_member(text, joints_path[..]);
		if (joints_text.len > 0)
		{
			String[] listed = json_array_items(allocator, joints_text)!;
			defer alloc::free(allocator, listed);
			foreach (entry : listed)
			{
				if (try uint node = parse_uint(entry))
				{
					if ((usz)node < existing) was_joint[node] = true;
				}
			}
		}
	}

	bool[] taken = alloc::new_array(allocator, bool, (sz)existing);
	defer alloc::free(allocator, taken);

	foreach (usz j, joint : input.joints)
	{
		plan.reuse[j] = -1;
		if (joint.name.len == 0) continue;

		String wanted = quoted(allocator, joint.name);
		defer alloc::free(allocator, wanted.ptr);

		for (usz i = 0; i < existing; i++)
		{
			if (!was_joint[i] || taken[i]) continue;

			// Compared as the escaped text rather than as the decoded name, so
			// nothing here has to unescape — and a name that round-trips through
			// crig unchanged writes byte-identical text.
			JsonStep[1] name_path = { { .key = "name" } };
			if (read_gltf_member(plan.items[i], name_path[..]) != wanted) continue;

			// A node carrying geometry is not available however it is named. It is
			// somebody's mesh, and rewriting its object would take the mesh with it.
			JsonStep[1] mesh_path = { { .key = "mesh" } };
			JsonStep[1] camera_path = { { .key = "camera" } };
			if (read_gltf_member(plan.items[i], mesh_path[..]).len > 0) continue;
			if (read_gltf_member(plan.items[i], camera_path[..]).len > 0) continue;

			plan.reuse[j] = (int)i;
			taken[i] = true;
			break;
		}
	}

	usz next = existing;
	for (usz j = 0; j < input.joints.len; j++)
	{
		if (plan.reuse[j] >= 0)
		{
			plan.node_of[j] = (uint)plan.reuse[j];
			plan.detach[plan.reuse[j]] = true;
			continue;
		}
		plan.node_of[j] = (uint)next++;
	}

	// The attachment nodes the limits are written on: the ones a previous save
	// or export left under the same names, else new ones. A node of that name
	// that was a joint or carries geometry is somebody else's, like above.
	plan.attach_parent = alloc::new_array(allocator, uint, (sz)input.constraints.len);
	plan.attach_child = alloc::new_array(allocator, uint, (sz)input.constraints.len);
	plan.attached = alloc::new_array(allocator, bool, (sz)input.constraints.len);
	foreach (usz c, constraint : input.constraints)
	{
		if (constraint.joint >= input.joints.len) return RESKIN_SHAPE~;
		if (input.joints[constraint.joint].parent < 0) continue;
		plan.attached[c] = true;
		String[2] ends = { "parent", "child" };
		foreach (usz e, end : ends)
		{
			String label = string::format(allocator, "%s.constraint.%s", input.joints[constraint.joint].name, end);
			defer alloc::free(allocator, label.ptr);
			String wanted = quoted(allocator, label);
			defer alloc::free(allocator, wanted.ptr);

			uint at = (uint)next;
			for (usz i = 0; i < existing; i++)
			{
				if (was_joint[i] || taken[i]) continue;
				JsonStep[1] name_path = { { .key = "name" } };
				if (read_gltf_member(plan.items[i], name_path[..]) != wanted) continue;
				JsonStep[1] mesh_path = { { .key = "mesh" } };
				JsonStep[1] camera_path = { { .key = "camera" } };
				if (read_gltf_member(plan.items[i], mesh_path[..]).len > 0) continue;
				if (read_gltf_member(plan.items[i], camera_path[..]).len > 0) continue;
				at = (uint)i;
				taken[i] = true;
				// Rewritten whole below, and no longer anybody's child but its joint's.
				plan.detach[i] = true;
				break;
			}
			if (at == (uint)next) next++;
			if (e == 0) { plan.attach_parent[c] = at; } else { plan.attach_child[c] = at; }
		}
	}
	plan.added = next - existing;

	// Every node the old skin called a joint, whether or not it is being reused.
	for (usz i = 0; i < existing; i++)
	{
		if (was_joint[i]) plan.detach[i] = true;
	}

	// A part's node must not be one of them, or the skin would hang off a bone.
	foreach (part : input.parts)
	{
		if ((usz)part.node < existing && plan.detach[part.node]) return RESKIN_SHAPE~;
	}

	(void)root;
	kept = true;
	return plan;
}

// A non-negative integer written as JSON, or nothing. Deliberately strict:
// anything that is not digits is a node list this cannot safely rewrite.
fn uint? parse_uint(String text) @local
{
	String trimmed = text.trim();
	if (trimmed.len == 0) return GLTF_PATCH_MALFORMED~;

	uint value = 0;
	foreach (c : trimmed)
	{
		if (c < '0' || c > '9') return GLTF_PATCH_MALFORMED~;
		value = value * 10 + (uint)(c - '0');
	}
	return value;
}

// ---------------------------------------------------------------------------
// The document
//
// Where every new index lands. Worked out in `reskin_glb` and passed down whole
// rather than recomputed, because half of them are offsets into a buffer that
// has already been laid out and the other half count arrays that are about to
// grow.

struct Layout @local
{
	int root;
	usz buffer_at;
	usz buffer_len;
	usz ibm_at;
	usz ibm_len;
	usz joints_at;
	usz joints_len;
	usz weights_at;
	usz weights_len;
	// The rewritten positions, in the file's space, or empty to keep the file's.
	// Borrowed for the length of the write, like the blocks below.
	usz positions_at;
	Vec3[] positions;
	usz joint_stride;
	bool wide;

	// The animation runs, already placed — see `plan_anim_blocks`. Borrowed for
	// the length of the write.
	AnimBlock[] blocks;
}

<*
 Every edit the reskin makes to the JSON, applied in order.

 The arrays are read out whole, rebuilt as text and written back in one splice
 each — rather than one edit per element — because a document is copied on every
 edit and `nodes` on a real character is sixty entries.
*>
fn String? write_document(Allocator allocator, String text, Reskin input, Rewrite plan, Layout at) @local
{
	usz existing = plan.items.len;
	usz nodes_total = existing + plan.added;

	// Where the appended accessors and views land: after whatever is there.
	usz view_base = array_len(text, "bufferViews");
	usz accessor_base = array_len(text, "accessors");
	usz skin_count = array_len(text, "skins");
	usz skin_index = input.skin >= 0 ? (usz)input.skin : skin_count;

	// Every step below hands `working` on and frees what it grew from, so the only
	// release left is the one for a step that faults partway through.
	String working = text.copy(allocator);
	bool kept = false;
	defer if (!kept) alloc::free(allocator, working.ptr);

	// --- nodes -------------------------------------------------------------

	DString out = dstring::new(allocator);
	defer out.free();

	out.append_char('[');
	for (usz i = 0; i < nodes_total; i++)
	{
		if (i > 0) out.append_char(',');

		sz joint = joint_at_node(plan, (uint)i);
		if (joint >= 0)
		{
			write_joint_node(&out, input, plan, (usz)joint);
			continue;
		}

		sz constraint = attachment_at_node(plan, (uint)i);
		if (constraint >= 0)
		{
			write_attachment_node(&out, input, plan, (usz)constraint, plan.attach_child[(usz)constraint] == (uint)i);
			continue;
		}

		// Somebody else's node, kept as it was written — except that it must stop
		// claiming any joint as a child, and it loses any physics entry, since the
		// root list those index is rewritten below. The skeleton is re-rooted at
		// the scene, so a parent that used to hold the armature holds nothing now.
		String pruned = without_children(allocator, plan.items[i], plan.detach)!;
		defer if (pruned.ptr != plan.items[i].ptr) alloc::free(allocator, pruned.ptr);
		String stripped = without_physics(allocator, pruned)!;
		defer if (stripped.ptr != pruned.ptr) alloc::free(allocator, stripped.ptr);
		out.append_string(stripped);
	}
	out.append_char(']');

	working = replace_raw(allocator, working, "nodes", out.str_view())!;

	// --- the limits, as the exporter writes them -----------------------------

	write_constraint_roots(allocator, &working, input, plan)!;

	// --- the scenes the skeleton hangs in ----------------------------------

	usz scenes = array_len(working, "scenes");
	for (usz s = 0; s < scenes; s++)
	{
		JsonStep[3] where = { { .key = "scenes" }, { .at = s }, { .key = "nodes" } };
		String listed = read_gltf_member(working, where[..]);
		if (listed.len == 0) continue;

		DString roots = dstring::new(allocator);
		defer roots.free();

		roots.append_char('[');
		usz written = 0;

		String[] items = json_array_items(allocator, listed)!;
		defer alloc::free(allocator, items);
		foreach (entry : items)
		{
			if (try uint node = parse_uint(entry))
			{
				if ((usz)node < existing && plan.detach[node]) continue;
			}
			if (written++ > 0) roots.append_char(',');
			roots.append_string(entry);
		}

		// The new root joins the first scene only. A skeleton listed in two scenes
		// is a skeleton drawn twice.
		if (s == 0)
		{
			if (written++ > 0) roots.append_char(',');
			roots.appendf("%d", plan.node_of[(usz)at.root])!;
		}
		roots.append_char(']');

		String grown = patch_raw(allocator, working, where[..], roots.str_view())!;
		alloc::free(allocator, working.ptr);
		working = grown;
	}

	// --- buffer views ------------------------------------------------------

	DString views = dstring::new(allocator);
	defer views.free();

	views.append_char('[');
	append_existing(&views, allocator, working, "bufferViews")!;
	views.appendf(`{"buffer":0,"byteOffset":%d,"byteLength":%d}`,
		at.buffer_at + at.ibm_at, at.ibm_len)!;
	// The two vertex attributes declare their target, which the inverse bind
	// matrices must not: they are read by the loader, never bound as an array.
	views.appendf(`,{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":%d}`,
		at.buffer_at + at.joints_at, at.joints_len, gltf::ARRAY_BUFFER_TARGET)!;
	views.appendf(`,{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":%d}`,
		at.buffer_at + at.weights_at, at.weights_len, gltf::ARRAY_BUFFER_TARGET)!;
	bool moved = at.positions.len > 0;
	if (moved)
	{
		views.appendf(`,{"buffer":0,"byteOffset":%d,"byteLength":%d,"target":%d}`,
			at.buffer_at + at.positions_at, at.positions.len * 12, gltf::ARRAY_BUFFER_TARGET)!;
	}
	usz anim_view = view_base + (usz)(moved ? 4 : 3);

	// Animation data declares no target either: a sampler reads it, nothing binds
	// it as a vertex array.
	foreach (block : at.blocks)
	{
		views.appendf(`,{"buffer":0,"byteOffset":%d,"byteLength":%d}`,
			at.buffer_at + block.at, block.len())!;
	}
	views.append_char(']');

	working = replace_raw(allocator, working, "bufferViews", views.str_view())!;

	// --- accessors ---------------------------------------------------------

	DString reads = dstring::new(allocator);
	defer reads.free();

	reads.append_char('[');
	append_existing(&reads, allocator, working, "accessors")!;
	reads.appendf(`{"bufferView":%d,"componentType":%d,"count":%d,"type":"MAT4"}`,
		view_base, COMPONENT_FLOAT, input.joints.len)!;

	foreach (part : input.parts)
	{
		reads.appendf(`,{"bufferView":%d,"byteOffset":%d,"componentType":%d,"count":%d,"type":"VEC4"}`,
			view_base + 1, part.base * at.joint_stride,
			at.wide ? COMPONENT_USHORT : COMPONENT_UBYTE, part.count)!;
		reads.appendf(`,{"bufferView":%d,"byteOffset":%d,"componentType":%d,"count":%d,"type":"VEC4"}`,
			view_base + 2, part.base * 16, COMPONENT_FLOAT, part.count)!;
		if (!moved) continue;

		// glTF requires a POSITION accessor to state its bounds, and a reader culls
		// by them — so they are the part's own, measured from what is written.
		Vec3 low = at.positions[part.base];
		Vec3 high = low;
		foreach (p : at.positions[part.base:part.count])
		{
			low = { math::min(low.x, p.x), math::min(low.y, p.y), math::min(low.z, p.z) };
			high = { math::max(high.x, p.x), math::max(high.y, p.y), math::max(high.z, p.z) };
		}
		reads.appendf(`,{"bufferView":%d,"byteOffset":%d,"componentType":%d,"count":%d,"type":"VEC3","min":%s,"max":%s}`,
			view_base + 3, part.base * 12, COMPONENT_FLOAT, part.count, (JsonVec3)low, (JsonVec3)high)!;
	}
	usz per_part = (usz)(moved ? 3 : 2);

	foreach (usz b, block : at.blocks)
	{
		// A sampler's input has to state its span or a reader cannot tell how long
		// the clip runs without walking every key. The outputs state nothing.
		if (block.components == 1)
		{
			reads.appendf(`,{"bufferView":%d,"componentType":%d,"count":%d,"type":"SCALAR","min":[%f],"max":[%f]}`,
				anim_view + b, COMPONENT_FLOAT, block.count, block.low, block.high)!;
			continue;
		}
		reads.appendf(`,{"bufferView":%d,"componentType":%d,"count":%d,"type":"VEC%d"}`,
			anim_view + b, COMPONENT_FLOAT, block.count, block.components)!;
	}
	reads.append_char(']');

	working = replace_raw(allocator, working, "accessors", reads.str_view())!;

	// --- the skin ----------------------------------------------------------

	DString skin = dstring::new(allocator);
	defer skin.free();

	skin.appendf(`{"inverseBindMatrices":%d,"skeleton":%d,"joints":[`,
		accessor_base, plan.node_of[(usz)at.root])!;
	foreach (usz j, node : plan.node_of)
	{
		if (j > 0) skin.append_char(',');
		skin.appendf("%d", node)!;
	}
	skin.append_string("]}");

	if (skin_index < skin_count)
	{
		JsonStep[2] where = { { .key = "skins" }, { .at = skin_index } };
		String grown = patch_raw_value(allocator, working, where[..], skin.str_view())!;
		alloc::free(allocator, working.ptr);
		working = grown;
	}
	else
	{
		DString skins = dstring::new(allocator);
		defer skins.free();
		skins.append_char('[');
		append_existing(&skins, allocator, working, "skins")!;
		skins.append_string(skin.str_view());
		skins.append_char(']');
		working = replace_raw(allocator, working, "skins", skins.str_view())!;
	}

	// --- the clips ---------------------------------------------------------

	// Where the animation accessors start: after the inverse bind matrices and the
	// two (or three, with positions) per part that precede them in the array built above.
	usz anim_accessor = accessor_base + 1 + input.parts.len * per_part;

	if (at.blocks.len == 0)
	{
		// Removed rather than written empty. glTF has no empty arrays, and a file
		// with no animations is one with no `animations` member — which is also
		// what this file will be if the caller kept none of the old ones.
		JsonStep[1] clips_path = { { .key = "animations" } };
		JsonEdit[1] drop = { { .path = clips_path[..], .value = "" } };

		String grown = patch_gltf_text(allocator, working, drop[..])!;
		alloc::free(allocator, working.ptr);
		working = grown;
	}
	else
	{
		DString clips = dstring::new(allocator);
		defer clips.free();

		DString samplers = dstring::new(allocator);
		defer samplers.free();
		DString channels = dstring::new(allocator);
		defer channels.free();

		clips.append_char('[');
		usz block = 0;
		usz written_clips = 0;

		foreach (clip : input.clips)
		{
			if (!clip.writable()) continue;

			// The whole clip keys at the same times, so one input accessor serves
			// every sampler below it. It is the block this clip opened with.
			usz shared = anim_accessor + block++;

			samplers.clear();
			channels.clear();
			samplers.append_char('[');
			channels.append_char('[');

			usz count = 0;
			foreach (curve : clip.curves)
			{
				usz node = (usz)plan.node_of[curve.joint];

				if (curve.turns.len > 0)
				{
					if (count > 0) { samplers.append_char(','); channels.append_char(','); }
					samplers.appendf(`{"input":%d,"output":%d,"interpolation":"LINEAR"}`,
						shared, anim_accessor + block++)!;
					channels.appendf(`{"sampler":%d,"target":{"node":%d,"path":"rotation"}}`,
						count++, node)!;
				}
				if (curve.slides.len > 0)
				{
					if (count > 0) { samplers.append_char(','); channels.append_char(','); }
					samplers.appendf(`{"input":%d,"output":%d,"interpolation":"LINEAR"}`,
						shared, anim_accessor + block++)!;
					channels.appendf(`{"sampler":%d,"target":{"node":%d,"path":"translation"}}`,
						count++, node)!;
				}
			}
			samplers.append_char(']');
			channels.append_char(']');

			if (written_clips++ > 0) clips.append_char(',');
			clips.append_string(`{"name":`);
			escape_json_string(&clips, clip.name);
			clips.appendf(`,"samplers":%s,"channels":%s}`,
				samplers.str_view(), channels.str_view())!;
		}
		clips.append_char(']');

		working = replace_raw(allocator, working, "animations", clips.str_view())!;
	}

	// --- what reads the new bytes ------------------------------------------

	foreach (usz p, part : input.parts)
	{
		JsonStep[6] joints_path = {
			{ .key = "meshes" }, { .at = (usz)part.mesh },
			{ .key = "primitives" }, { .at = (usz)part.primitive },
			{ .key = "attributes" }, { .key = "JOINTS_0" },
		};
		JsonStep[6] weights_path = {
			{ .key = "meshes" }, { .at = (usz)part.mesh },
			{ .key = "primitives" }, { .at = (usz)part.primitive },
			{ .key = "attributes" }, { .key = "WEIGHTS_0" },
		};
		JsonStep[3] skin_path = { { .key = "nodes" }, { .at = (usz)part.node }, { .key = "skin" } };

		working = set_number(allocator, working, joints_path[..], accessor_base + 1 + p * per_part)!;
		working = set_number(allocator, working, weights_path[..], accessor_base + 2 + p * per_part)!;
		if (moved)
		{
			JsonStep[6] position_path = {
				{ .key = "meshes" }, { .at = (usz)part.mesh },
				{ .key = "primitives" }, { .at = (usz)part.primitive },
				{ .key = "attributes" }, { .key = "POSITION" },
			};
			working = set_number(allocator, working, position_path[..], accessor_base + 3 + p * per_part)!;
		}
		working = set_number(allocator, working, skin_path[..], skin_index)!;
	}

	// Last, because everything above measured against the buffer as it was.
	JsonStep[3] length_path = { { .key = "buffers" }, { .at = 0 }, { .key = "byteLength" } };
	working = set_number(allocator, working, length_path[..], at.buffer_len)!;

	kept = true;
	return working;
}

// One joint node: a name, where it sits inside its parent, and what hangs off
// it — the joints below, and the attachment nodes of the limits written on it
// and on those joints. Nothing else — see the module note on why the transform
// is a translation.
fn void write_joint_node(DString* out, Reskin input, Rewrite plan, usz joint) @local
{
	ReskinJoint bone = input.joints[joint];

	out.append_string(`{"name":`);
	escape_json_string(out, bone.name);

	Vec3 local = bone.parent >= 0
		? bone.position - input.joints[(usz)bone.parent].position
		: bone.position;

	out.appendf(`,"translation":%s`, (JsonVec3)local);

	usz children = 0;
	foreach (usz other, child : input.joints)
	{
		if (child.parent != (int)joint) continue;
		out.append_string(children++ == 0 ? `,"children":[` : ",");
		out.appendf("%d", plan.node_of[other])!!;
	}
	foreach (usz c, constraint : input.constraints)
	{
		if (!plan.attached[c]) continue;
		if ((usz)input.joints[constraint.joint].parent == joint)
		{
			out.append_string(children++ == 0 ? `,"children":[` : ",");
			out.appendf("%d", plan.attach_parent[c])!!;
		}
		if (constraint.joint == joint)
		{
			out.append_string(children++ == 0 ? `,"children":[` : ",");
			out.appendf("%d", plan.attach_child[c])!!;
		}
	}
	if (children > 0) out.append_char(']');

	out.append_char('}');
}

// One attachment node of a limit: at the joint, turned to the limit's frame,
// under the joint (the child end) or under its parent (the parent end). The
// child end carries the KHR joint, naming the parent end and the settings row
// the constraint is written as — the ordinal of the limit among those written.
fn void write_attachment_node(DString* out, Reskin input, Rewrite plan, usz constraint, bool child_end) @local
{
	ReskinConstraint limit = input.constraints[constraint];
	ReskinJoint bone = input.joints[limit.joint];

	out.append_string(`{"name":`);
	String label = string::format(tmem, "%s.constraint.%s", bone.name, child_end ? "child" : "parent");
	escape_json_string(out, label);

	// Joint nodes carry pure translations, so an attachment's local offset is
	// the pivot's distance from the node it hangs under: nothing for the child
	// end, one bone for the parent end.
	if (!child_end)
	{
		out.appendf(`,"translation":%s`, (JsonVec3)(bone.position - input.joints[(usz)bone.parent].position));
	}
	out.appendf(`,"rotation":%s`, (JsonQuat)limit.frame.normalize());

	if (child_end)
	{
		usz row = 0;
		for (usz c = 0; c < constraint; c++) if (plan.attached[c]) row++;
		out.appendf(`,"extensions":{"%s":{"joint":{"connectedNode":%d,"joint":%d}}}`,
			RESKIN_PHYSICS_EXTENSION, plan.attach_parent[constraint], row)!!;
	}
	out.append_char('}');
}

// Which constraint this node is an attachment of, or -1 for a node that is none.
fn sz attachment_at_node(Rewrite plan, uint node) @local
{
	foreach (usz c, held : plan.attached)
	{
		if (!held) continue;
		if (plan.attach_parent[c] == node || plan.attach_child[c] == node) return (sz)c;
	}
	return -1;
}

// A kept node's text without its physics entry, or the text unchanged when it
// has none. An `extensions` object emptied by the cut goes with it, since glTF
// allows no empty one. The result is the caller's to free only when it is not
// the input — compared by pointer at the call site, like `without_children`.
fn String? without_physics(Allocator allocator, String node) @local
{
	JsonStep[1] extensions_path = { { .key = "extensions" } };
	if (read_gltf_member(node, extensions_path[..]).len == 0) return node;
	JsonStep[2] physics_path = { { .key = "extensions" }, { .key = RESKIN_PHYSICS_EXTENSION } };
	if (read_gltf_member(node, physics_path[..]).len == 0) return node;

	JsonEdit[1] cut = { { .path = physics_path[..], .value = "" } };
	String stripped = patch_gltf_text(allocator, node, cut[..])!;
	if (!json_object_empty(read_gltf_member(stripped, extensions_path[..]))) return stripped;
	defer alloc::free(allocator, stripped.ptr);
	JsonEdit[1] drop = { { .path = extensions_path[..], .value = "" } };
	return patch_gltf_text(allocator, stripped, drop[..]);
}

// Whether an object's raw text holds no member.
fn bool json_object_empty(String raw) @local
{
	foreach (char c : raw)
	{
		if (c == '{' || c == '}' || c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
		return false;
	}
	return raw.len > 0;
}

<*
 The root half of the limits: the list of joint settings every attachment
 indexes, the extension declared or undeclared to match, and the editor's
 provenance in `extras`. All three are owned outright — rewritten when limits
 are written, removed when none are — because the attachments indexing the
 old list are gone with the old nodes.
*>
fn void? write_constraint_roots(Allocator allocator, String* working, Reskin input, Rewrite plan) @local
{
	usz written = 0;
	foreach (held : plan.attached) if (held) written++;

	JsonStep[2] physics_path = { { .key = "extensions" }, { .key = RESKIN_PHYSICS_EXTENSION } };
	JsonStep[2] frames_path = { { .key = "extras" }, { .key = "constraintFrames" } };

	if (written > 0)
	{
		// The settings rows, in the order the attachments count them: one
		// zero-range weld over the three linear axes, then one row per angular
		// axis — a locked axis is a zero-width range at its held value, as
		// anim/constraint_gltf.c3 writes it, so the two files read the same.
		DString rows = dstring::new(allocator);
		defer rows.free();
		DString provenance = dstring::new(allocator);
		defer provenance.free();
		rows.append_string(`{"physicsJoints":[`);
		provenance.append_char('[');
		usz row = 0;
		foreach (usz c, limit : input.constraints)
		{
			if (!plan.attached[c]) continue;
			if (row > 0) { rows.append_char(','); provenance.append_char(','); }
			row++;
			rows.append_string(`{"limits":[{"linearAxes":[0,1,2],"min":0,"max":0}`);
			foreach (usz axis, held : limit.axes)
			{
				rows.appendf(`,{"angularAxes":[%d],"min":%s,"max":%s}`, axis,
					(JsonFloat)(held.allowed ? held.minimum : held.locked),
					(JsonFloat)(held.allowed ? held.maximum : held.locked))!;
			}
			rows.append_string("]}");

			write_constraint_provenance(&provenance, plan.node_of[limit.joint], limit.intent,
				limit.primary >= 0 && (usz)limit.primary < plan.node_of.len ? (int)plan.node_of[(usz)limit.primary] : -1,
				limit.adjustment, limit.axes);
		}
		rows.append_string("]}");
		provenance.append_char(']');

		swap_in(allocator, working, patch_raw(allocator, *working, physics_path[..], rows.str_view())!);
		JsonEdit[1] frames = { { .path = frames_path[..], .value = provenance.str_view() } };
		swap_in(allocator, working, patch_gltf_text(allocator, *working, frames[..])!);
	}
	else
	{
		without_root_member(allocator, working, physics_path[..])!;
		without_root_member(allocator, working, frames_path[..])!;
	}

	// The plan tag, kept the way an export writes it so a model saved in place
	// reads back as the same body plan. Removed when the rig declares none, so a
	// re-save is idempotent either way.
	JsonStep[2] plan_path = { { .key = "extras" }, { .key = "plan" } };
	if (input.plan.len > 0)
	{
		JsonEdit[1] tag = { { .path = plan_path[..], .value = input.plan } };
		swap_in(allocator, working, patch_gltf_text(allocator, *working, tag[..])!);
	}
	else
	{
		without_root_member(allocator, working, plan_path[..])!;
	}

	with_extension_declared(allocator, working, "extensionsUsed", written > 0)!;
	with_extension_declared(allocator, working, "extensionsRequired", false)!;
}

// The document replaced by the text an edit grew from it, the old one released.
// Every edit here is a step of a caller that frees whatever `working` holds
// when a later step faults, so the swap has to be whole: a step that faults
// leaves the document it was given.
fn void swap_in(Allocator allocator, String* working, String grown) @local
{
	alloc::free(allocator, working.ptr);
	*working = grown;
}

// A nested root member removed, and its parent object with it when that leaves
// it empty. Nothing is written into a file that never had the parent — a plain
// removal would write the parent in empty on its way to the member.
fn void? without_root_member(Allocator allocator, String* working, JsonStep[] path) @local
{
	if (read_gltf_member(*working, path[:1]).len == 0) return;
	if (read_gltf_member(*working, path).len == 0) return;
	JsonEdit[1] cut = { { .path = path, .value = "" } };
	swap_in(allocator, working, patch_gltf_text(allocator, *working, cut[..])!);
	if (!json_object_empty(read_gltf_member(*working, path[:1]))) return;
	JsonEdit[1] drop = { { .path = path[:1], .value = "" } };
	swap_in(allocator, working, patch_gltf_text(allocator, *working, drop[..])!);
}

// The physics extension listed under `key` when `wanted`, and not listed
// otherwise; a list emptied by that is removed, since glTF allows no empty one.
fn void? with_extension_declared(Allocator allocator, String* working, String key, bool wanted) @local
{
	JsonStep[1] path = { { .key = key } };
	String listed = read_gltf_member(*working, path[..]);
	String extension = quoted(allocator, RESKIN_PHYSICS_EXTENSION);
	defer alloc::free(allocator, extension.ptr);

	DString kept = dstring::new(allocator);
	defer kept.free();
	kept.append_char('[');
	usz count = 0;
	bool present = false;
	if (listed.len > 0)
	{
		String[] items = json_array_items(allocator, listed)!;
		defer alloc::free(allocator, items);
		foreach (item : items)
		{
			if (item == extension) { present = true; continue; }
			if (count++ > 0) kept.append_char(',');
			kept.append_string(item);
		}
	}
	if (present == wanted) return;
	if (wanted)
	{
		if (count++ > 0) kept.append_char(',');
		kept.append_string(extension);
	}
	kept.append_char(']');

	if (count == 0)
	{
		JsonEdit[1] drop = { { .path = path[..], .value = "" } };
		swap_in(allocator, working, patch_gltf_text(allocator, *working, drop[..])!);
		return;
	}
	swap_in(allocator, working, patch_raw(allocator, *working, path[..], kept.str_view())!);
}

// Which joint this node index belongs to, or -1 for a node that is not one.
fn sz joint_at_node(Rewrite plan, uint node) @local
{
	foreach (usz j, held : plan.node_of)
	{
		if (held == node) return (sz)j;
	}
	return -1;
}

// A node's text with the detached indices taken out of its `children`, or the
// text unchanged when it names none of them. The result is the caller's to free
// only when it is not the input — compared by pointer at the call site.
fn String? without_children(Allocator allocator, String node, bool[] detach) @local
{
	JsonStep[1] where = { { .key = "children" } };
	String listed = read_gltf_member(node, where[..]);
	if (listed.len == 0) return node;

	String[] items = json_array_items(allocator, listed)!;
	defer alloc::free(allocator, items);

	DString kept = dstring::new(allocator);
	defer kept.free();

	kept.append_char('[');
	usz written = 0;
	bool dropped = false;
	foreach (entry : items)
	{
		if (try uint index = parse_uint(entry))
		{
			if ((usz)index < detach.len && detach[index]) { dropped = true; continue; }
		}
		if (written++ > 0) kept.append_char(',');
		kept.append_string(entry);
	}
	kept.append_char(']');

	if (!dropped) return node;

	// glTF says `children` holds at least one node, so a list emptied by the
	// prune has to go rather than be written as `[]`.
	if (written == 0)
	{
		JsonEdit[1] cut = { { .path = where[..], .value = "" } };
		return patch_gltf_text(allocator, node, cut[..]);
	}
	return patch_raw(allocator, node, where[..], kept.str_view());
}

// ---------------------------------------------------------------------------
// Small wrappers, so the edits above read as what they are

fn usz array_len(String text, String key) @local
{
	JsonStep[1] where = { { .key = key } };
	String listed = read_gltf_member(text, where[..]);
	if (listed.len == 0) return 0;

	String[]? items = json_array_items(mem, listed);
	if (catch items) return 0;
	defer alloc::free(mem, items);
	return items.len;
}

// The elements a root array already holds, written into a list being built, with
// a trailing comma when there were any. Absent and empty both write nothing,
// which is what makes an array this file never had come out as just the new
// entries.
fn void? append_existing(DString* out, Allocator allocator, String text, String key) @local
{
	JsonStep[1] where = { { .key = key } };
	String listed = read_gltf_member(text, where[..]);
	if (listed.len == 0) return;

	String[] items = json_array_items(allocator, listed)!;
	defer alloc::free(allocator, items);
	if (items.len == 0) return;

	foreach (entry : items)
	{
		out.append_string(entry);
		out.append_char(',');
	}
}

// Set a root member to raw text, releasing the document it grew from. The shape
// every array rewrite above takes, and worth a name because forgetting the free
// leaks a copy of the whole document each time.
fn String? replace_raw(Allocator allocator, String text, String key, String raw) @local
{
	JsonStep[1] where = { { .key = key } };
	String grown = patch_raw(allocator, text, where[..], raw)!;
	alloc::free(allocator, text.ptr);
	return grown;
}

fn String? set_number(Allocator allocator, String text, JsonStep[] path, usz value) @local
{
	String written = string::format(allocator, "%d", value);
	defer alloc::free(allocator, written.ptr);

	String grown = patch_raw(allocator, text, path, written)!;
	alloc::free(allocator, text.ptr);
	return grown;
}

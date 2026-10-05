<*
 Does a model with no rig get one, and does the file come back holding it?

     `c3c test --trust=full --test-filter a_model_with_no_rig_gets_one`

 The claim being checked is the one somebody makes when they open an unrigged
 model in crig, place dots and save: **the file I get back is rigged**. A skin
 that was not there is added, every bone is appended as a joint node, and the
 mesh node gains a `skin` member it never had.

 **Nothing below reads the file through `rig::skin_from_gltf` or
 `read_rest_skeleton`**, which are the two readers the import is built on. They
 are re-implemented here, short and against the spec: node transforms composed
 down the hierarchy for the joints, `JOINTS_0` / `WEIGHTS_0` walked per primitive
 for the weights. A reader checked against itself agrees with itself.

 ## What used to be here

 Fourteen checks that opened `assets/animations/CesiumMan.glb` — Khronos' glTF
 sample asset, out of COLLADA2GLTF with nineteen joints, a clip, a texture and a
 Z-up conversion at the root — and asserted that a rig which *arrives* in a file
 survives being edited and written back out. They were chosen against a
 third-party file on purpose: a fixture crig built would be written by the same
 writer whose conventions were under test.

 That file was removed from the repository, and they went with it. The coverage
 they carried is gone rather than moved: importing an existing rig, playing a
 file's own clip, exporting the weights it came with, and the round trip through
 all three. Anything replacing them needs a skinned, animated model to read, and
 the two the library now ships carry no rig at all.

 The mesh below is built in the check rather than staged, for the reason the
 deleted ones were not: a two-triangle model makes the one thing that matters
 easy to see, and nothing about it has to be true of a real character.
*>
module crig_tests::gltf_import;

import crig;
import rig;
import gltf;
import gltf_edit;
import crig_tests::library;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::vector;
import std::math::matrix;
import std::math::quaternion;

// Positions are copied, not computed — they should agree to the last bit a
// float32 can carry through a matrix compose. This leaves room for that compose
// and for nothing else.
const float EXACT_POSITION = 1.0e-6f;

// ---------------------------------------------------------------------------
// A reader that knows nothing about crig
// ---------------------------------------------------------------------------

faultdef IMPORT_NO_SKIN, IMPORT_UNSUPPORTED;

<*
 One joint of a file: where it rests in world space, and what it is called.
*>
struct FileJoint
{
	String name;
	Vec3 at;
}

<*
 The file's skin, as a reader with no crig in it sees it.

 `weights[v * joints.len + j]` is how much joint `j` holds of vertex `v`, over
 the vertices in the order the primitives appear — the same order crig's
 flattener concatenates them in, and the only order the positions exist in once
 it has run.
*>
struct FileSkin
{
	FileJoint[] joints;
	float[] weights;
	usz vertices;
}

fn void FileSkin.free(&self, Allocator allocator)
{
	foreach (joint : self.joints)
	{
		if (joint.name.len > 0) alloc::free(allocator, joint.name.ptr);
	}
	if (self.joints.len > 0) alloc::free(allocator, self.joints);
	if (self.weights.len > 0) alloc::free(allocator, self.weights);
	*self = {};
}

<*
 Which joint of this file goes by that name, or -1.
*>
fn sz FileSkin.index_of(&self, String name)
{
	foreach (usz j, joint : self.joints)
	{
		if (joint.name == name) return (sz)j;
	}
	return -1;
}

// A node's own transform as the file states it, composed the way the spec says:
// translation, then rotation, then scale, applied right to left.
//
// A node may state that transform either way — as a matrix outright, or as the
// triple — and the spec allows only one of the two at a time, so a file that
// gives a matrix has nothing in the triple to compose. `Node.from_json` leaves
// the matrix as the identity when the file omits it, which is what makes that
// the question to ask.
//
// This reader had only the triple for as long as it was pointed at a file that
// used only the triple. The first exporter that reached for a matrix — for the
// Z-up conversion at the root, which is where one usually turns up — put this
// reader's idea of the skeleton a metre and a half from the file's.
fn Matrix4f local_matrix(gltf::Node* node) @local
{
	if (!is_identity(node.matrix)) return node.matrix;

	Matrix4f out = matrix::IDENTITY4;
	out = out.translate(node.translation);
	out = out.mul(node.rotation.to_matrix());

	Vec3 scale = node.scale;
	Matrix4f scaling = matrix::IDENTITY4;
	scaling.m00 = scale.x;
	scaling.m11 = scale.y;
	scaling.m22 = scale.z;
	return out.mul(scaling);
}

// Whether a node's matrix is the one `Node.from_json` leaves behind for a file
// that stated none. Exact comparison on purpose: this is asking what the parser
// wrote, not whether some computed matrix came out near enough to identity.
fn bool is_identity(Matrix4f m) @local
{
	Matrix4f identity = matrix::IDENTITY4;
	for (usz i = 0; i < 16; i++)
	{
		if (m.m[i] != identity.m[i]) return false;
	}
	return true;
}

<*
 Read a file's skin: its joints where they rest, and its per-vertex weights.

 The joints come from the skin's own joint list, which is the file saying which
 nodes are bones. Their rest positions are the node hierarchy composed from the
 roots down — not read off any single node, since a bone's translation is stated
 relative to its parent.

 The caller owns everything.

 @return? IMPORT_NO_SKIN : `The file carries no skin, or an empty one.`
 @return? IMPORT_UNSUPPORTED : `Its joint or weight components are a type this reader does not decode.`
*>
fn FileSkin? read_file_skin(Allocator allocator, String path)
{
	gltf::GltfStream stream = gltf::open(path, allocator)!;
	defer stream.close();
	stream.load_all_buffers()!;

	if (stream.gltf.skins.len() == 0) return IMPORT_NO_SKIN~;
	gltf::Skin skin = stream.gltf.skins[0];

	usz joints = (usz)skin.joints.len();
	if (joints == 0) return IMPORT_NO_SKIN~;

	usz nodes = (usz)stream.gltf.nodes.len();
	Matrix4f[] world = alloc::new_array(allocator, Matrix4f, (sz)nodes);
	defer alloc::free(allocator, world);

	// Parents before children, which the `parent` back-pointer gives directly:
	// walking up to a root and back down needs no ordering assumption about the
	// node array itself.
	for (usz i = 0; i < nodes; i++)
	{
		world[i] = compose_to_root(&stream, (uint)i);
	}

	FileSkin out = {
		.joints = alloc::new_array(allocator, FileJoint, (sz)joints),
		.vertices = 0,
	};
	defer catch out.free(allocator);

	for (usz j = 0; j < joints; j++)
	{
		uint node = skin.joints[(sz)j];
		float[<4>] origin = world[node].apply({ 0, 0, 0, 1 });
		out.joints[j] = {
			.name = stream.gltf.nodes[node].name.copy(allocator),
			.at = { origin.x, origin.y, origin.z },
		};
	}

	// Two passes over the primitives for the same reason the reader under test
	// takes two: the matrix cannot be sized until the vertices have been counted.
	usz vertices = 0;
	foreach (root : stream.gltf.scenes[0].nodes)
	{
		count_vertices(&stream, root, &vertices);
	}
	if (vertices == 0) return IMPORT_NO_SKIN~;

	out.vertices = vertices;
	out.weights = alloc::new_array(allocator, float, (sz)(vertices * joints));

	usz filled = 0;
	foreach (root : stream.gltf.scenes[0].nodes)
	{
		fill_weights(&stream, root, &out, &filled)!;
	}

	return out;
}

fn Matrix4f compose_to_root(gltf::GltfStream* stream, uint index) @local
{
	Matrix4f out = matrix::IDENTITY4;
	gltf::Node* node = stream.gltf.nodes.get_ref((sz)index);
	while (node != null)
	{
		out = local_matrix(node).mul(out);
		node = node.parent;
	}
	return out;
}

fn void count_vertices(gltf::GltfStream* stream, uint index, usz* total) @local
{
	gltf::Node node = stream.gltf.nodes[index];
	if (node.has_mesh())
	{
		foreach (primitive : stream.gltf.meshes[(usz)node.mesh].primitives)
		{
			*total += primitive_vertices(stream, primitive);
		}
	}
	foreach (child : node.children) count_vertices(stream, child, total);
}

fn usz primitive_vertices(gltf::GltfStream* stream, gltf::Primitive primitive) @local
{
	if (try sz mode = primitive.attributes.get("mode"))
	{
		if (mode != 4) return 0;
	}
	sz? position = primitive.attributes.get("POSITION");
	if (catch position) return 0;
	return (usz)stream.gltf.accessors[position].count;
}

fn void? fill_weights(gltf::GltfStream* stream, uint index, FileSkin* out, usz* base) @local
{
	gltf::Node node = stream.gltf.nodes[index];

	if (node.has_mesh())
	{
		foreach (primitive : stream.gltf.meshes[(usz)node.mesh].primitives)
		{
			usz count = primitive_vertices(stream, primitive);
			if (count == 0) continue;

			if (node.has_skin())
			{
				read_primitive_weights(stream, primitive, *base, count, out)!;
			}
			*base += count;
		}
	}

	foreach (child : node.children) fill_weights(stream, child, out, base)!;
}

// JOINTS_0 / WEIGHTS_0 only. Every file this checks against writes one influence
// set, and a second one appearing would show up as rows that do not sum to one
// rather than being read wrong.
fn void? read_primitive_weights(
	gltf::GltfStream* stream,
	gltf::Primitive primitive,
	usz base,
	usz count,
	FileSkin* out) @local
{
	sz? joint_attribute = primitive.attributes.get("JOINTS_0");
	sz? weight_attribute = primitive.attributes.get("WEIGHTS_0");
	if (catch joint_attribute) return;
	if (catch weight_attribute) return;

	gltf::Accessor joints = stream.gltf.accessors[joint_attribute];
	gltf::Accessor weights = stream.gltf.accessors[weight_attribute];
	if (weights.data_type != gltf::DataType.FLOAT) return IMPORT_UNSUPPORTED~;

	usz columns = out.joints.len;

	for (usz i = 0; i < count && i < (usz)joints.count; i++)
	{
		float[<4>] strength = stream.@cast_buffer(weights, (sz)i, float[<4>]);

		uint[<4>] rides;
		switch (joints.data_type)
		{
			case gltf::DataType.CHAR:
				char[<4>] narrow = stream.@cast_buffer(joints, (sz)i, char[<4>]);
				rides = { narrow[0], narrow[1], narrow[2], narrow[3] };
			case gltf::DataType.USHORT:
				ushort[<4>] wide = stream.@cast_buffer(joints, (sz)i, ushort[<4>]);
				rides = { wide[0], wide[1], wide[2], wide[3] };
			default:
				return IMPORT_UNSUPPORTED~;
		}

		for (usz s = 0; s < 4; s++)
		{
			if (strength[s] == 0.0f) continue;
			usz column = (usz)rides[s];
			if (column >= columns) return IMPORT_UNSUPPORTED~;
			out.weights[(base + i) * columns + column] += strength[s];
		}
	}
}

fn void normalize_rows(FileSkin* skin) @local
{
	usz columns = skin.joints.len;
	for (usz v = 0; v < skin.vertices; v++)
	{
		usz base = v * columns;
		float sum = 0.0f;
		for (usz c = 0; c < columns; c++) sum += skin.weights[base + c];
		if (sum <= 0.0f || sum == 1.0f) continue;
		float scale = 1.0f / sum;
		for (usz c = 0; c < columns; c++) skin.weights[base + c] *= scale;
	}
}

// ---------------------------------------------------------------------------
// The document the import produces
// ---------------------------------------------------------------------------

<*
 A model that arrives with no rig at all comes back with one.

 The ordinary job, and a different path through the writer from the one above:
 there is no skin to rewrite so one is added, no joint node to reuse so every
 bone is appended, and the mesh node gains a `skin` member it never had. None of
 that is exercised by re-rigging a Blender character, which is why it is a check
 of its own.

 The mesh is built here rather than staged, because every `.glb` in `assets` is
 already rigged — and a two-triangle model makes the one thing that matters easy
 to see: after the save, the file's skin has to hold both bones and every vertex
 has to ride one.
*>
fn void a_model_with_no_rig_gets_one() @test
{
	if (file::is_file(BARE_COPY)) (void)file::delete(BARE_COPY);
	if (file::is_file(BARE_COPY_SESSION)) (void)file::delete(BARE_COPY_SESSION);
	if (!write_bare_mesh(BARE))
	{
		test::@check(false, "SKIPPED — could not write %s", BARE);
		return;
	}
	defer (void)file::delete(BARE);
	defer if (file::is_file(BARE_SESSION)) (void)file::delete(BARE_SESSION);

	rig::TriMesh? loaded = rig::load_gltf(mem, BARE);
	if (catch loaded)
	{
		test::@check(false, "the bare mesh did not read back");
		return;
	}

	crig::AppState app = crig::new_app(loaded);
	app.load_mesh(loaded, BARE);

	test::@check(app.doc.dots.len() == 0, "a mesh with no skin opens with no rig");

	// Two dots along the strip, chained, so the skeleton has a root and one bone.
	uint low = app.doc.add_dot({ 0, 0.25f, 0 }, "low");
	uint high = app.doc.add_dot({ 0, 0.75f, 0 }, "high");
	app.doc.connect(low, high);
	app.doc.root_id = low;

	app.save_session();
	String landed = app.source_path.copy(mem);
	defer landed.free(mem);
	app.free();
	defer if (file::is_file(BARE_COPY)) (void)file::delete(BARE_COPY);
	defer if (file::is_file(BARE_COPY_SESSION)) (void)file::delete(BARE_COPY_SESSION);

	test::@check(!file::is_file(BARE_SESSION), "saving wrote into a model, not beside one");
	test::@check(landed == BARE_COPY, "and into the copy — %s", landed);

	// --- the file now has a skin -------------------------------------------

	FileSkin? read = read_file_skin(mem, landed);
	if (catch read)
	{
		test::@check(false, "the model came back with no skin — a rig was never written");
		return;
	}
	FileSkin written = read;
	defer written.free(mem);

	test::@check(written.joints.len == 2, "the new skin holds both bones — %d", written.joints.len);

	sz low_at = written.index_of("low");
	sz high_at = written.index_of("high");
	if (low_at < 0 || high_at < 0)
	{
		test::@check(false, "the bones are not in the file's skin by name");
		return;
	}
	test::@check((written.joints[low_at].at - (Vec3){ 0, 0.25f, 0 }).length() < EXACT_POSITION
		&& (written.joints[high_at].at - (Vec3){ 0, 0.75f, 0 }).length() < EXACT_POSITION,
		"and rest where the dots were put — %s and %s",
		written.joints[low_at].at, written.joints[high_at].at);

	normalize_rows(&written);
	usz starved = 0;
	for (usz v = 0; v < written.vertices; v++)
	{
		float sum = written.weights[v * 2] + written.weights[v * 2 + 1];
		if (sum < 0.5f) starved++;
	}
	test::@check(written.vertices > 0 && starved == 0,
		"%d of %d vertices ride nothing", starved, written.vertices);

	// --- and reopens as the rig that was saved -----------------------------

	rig::TriMesh? again = rig::load_gltf(mem, landed);
	if (catch again)
	{
		test::@check(false, "the model stopped reading after the rig went in");
		return;
	}
	crig::AppState second = crig::new_app(again);
	second.load_mesh(again, landed);
	defer second.free();

	test::@check(second.doc.dots.len() == 2 && second.dot_named("high") != null,
		"the rig came back — %d dots", second.doc.dots.len());
}

const String BARE = "build/gltf-import-bare.glb";
const String BARE_SESSION = "build/gltf-import-bare.rigsmith.json";
const String BARE_COPY = "build/gltf-import-bare_copy.glb";
const String BARE_COPY_SESSION = "build/gltf-import-bare_copy.rigsmith.json";

// A model with a mesh and nothing else: two triangles, one node, one scene. No
// skin, no joints, no materials — the state every mesh is in before crig sees it.
fn bool write_bare_mesh(String path) @local
{
	gltf::GltfBuilder builder = gltf::builder(mem);
	defer builder.free();

	Vec3[4] corners = {
		{ -0.5f, 0, 0 }, { 0.5f, 0, 0 }, { 0.5f, 1.0f, 0 }, { -0.5f, 1.0f, 0 },
	};
	uint[6] faces = { 0, 1, 2, 0, 2, 3 };

	uint positions = builder.add_positions(corners[..]);
	uint indices = builder.add_indices(faces[..]);

	uint mesh = builder.add_mesh("Bare");
	gltf::WriteAttribute[1] attributes = { { .name = "POSITION", .accessor = positions } };
	builder.add_primitive(mesh, attributes[..], indices: (int)indices);

	// At the origin with no rotation and no scale: a node transform would put the
	// mesh somewhere a skin cannot follow it, which `MeshParts.upright` refuses —
	// and refusing is a different check from this one.
	uint node = builder.add_node("Bare", mesh: (int)mesh);
	builder.add_root(node);

	if (catch builder.save_glb(path)) return false;
	return true;
}

<*
 What a glTF's surface looks like, beside the triangle soup crig edits.

 `from_gltf` throws away everything but positions, normals and triangles,
 because the rigger wants one surface and nothing else. The Textured viewport
 wants the rest back: each vertex's TEXCOORD_0, and which material each run of
 triangles is painted with. This is the fourth walk of the same scene, in the
 same order as the other three (`scene_mesh_nodes` and the same skip rules), so
 its vertex and index numbering are the merged mesh's.

 	`rig::Surface surface = rig::read_surface(mem, &stream)!;`
 	`defer surface.free(mem);`

 Nothing here decodes an image. A run names its material by index; the caller
 resolves that against the same open stream, which is where the pictures are.
*>
module rig;

import gltf;
import std::collections::list;
import std::math::vector;

<*
 One primitive's triangles: where its indices sit in the merged index list and
 the glTF material they are painted with, or -1 for none.
*>
struct SurfaceRun
{
	usz index_start;
	usz index_count;
	int material;
}

struct Surface
{
	// One per merged vertex; zero for a primitive that had none.
	Vec2[] uvs;
	SurfaceRun[] runs;
	// What the walk came to, so a caller can tell the merged mesh it holds is
	// still the one this was read beside.
	usz vertices;
	usz indices;
	// Whether any primitive carried TEXCOORD_0 — without it no picture can land.
	bool has_uvs;
}

fn void Surface.free(&self, Allocator allocator)
{
	if (self.uvs.len > 0) alloc::free(allocator, self.uvs);
	if (self.runs.len > 0) alloc::free(allocator, self.runs);
	*self = {};
}

<*
 Whether this surface lines up with a merged mesh vertex for vertex and index
 for index. A body built in crig, or a mesh edited since, does not — and then
 there is nothing to paint it with.
*>
fn bool Surface.fits(&self, TriMesh* mesh)
{
	return self.runs.len > 0
		&& self.vertices == mesh.positions.len
		&& self.uvs.len == mesh.positions.len
		&& self.indices == mesh.indices.len;
}

<*
 Read the uvs and material runs of an open stream whose buffers are loaded.

 @param scene : `Scene to walk, or -1 for the first one.`
 @return? NO_TRIANGLES : `Nothing in the scene is a triangle mesh.`
 @return? SCENE_NOT_FOUND : `scene names a scene the file does not have.`
*>
fn Surface? read_surface(Allocator allocator, gltf::GltfStream* stream, int scene = -1)
{
	if (stream.gltf.scenes.len() == 0) return NO_TRIANGLES~;
	sz scene_index = scene < 0 ? 0 : (sz)scene;
	if (scene_index >= stream.gltf.scenes.len()) return SCENE_NOT_FOUND~;

	List{Vec2} uvs;
	List{SurfaceRun} runs;
	uvs.init(allocator);
	runs.init(allocator);
	defer
	{
		uvs.free();
		runs.free();
	}

	Surface out;
	uint[] nodes = scene_mesh_nodes(allocator, stream, scene_index);
	defer if (nodes.len > 0) alloc::free(allocator, nodes);
	foreach (node_index : nodes)
	{
		gltf::Node node = stream.gltf.nodes[node_index];
		gltf::Mesh mesh = stream.gltf.meshes[(usz)node.mesh];
		foreach (primitive : mesh.primitives)
		{
			usz count = part_vertices(stream, primitive);
			if (count == 0) continue;

			usz before = (usz)uvs.len();
			stream.@each_texcoord(primitive, 0 ; Vec2 uv, sz i)
			{
				if (i < (sz)count) uvs.push(uv);
			};
			if ((usz)uvs.len() > before) out.has_uvs = true;
			while ((usz)uvs.len() < before + count) uvs.push({ 0, 0 });

			// The same count `append_primitive` pushes: whole triangles only.
			usz index_count;
			if (try sz index_attribute = primitive.attributes.get("indices"))
			{
				usz given = (usz)stream.gltf.accessors[index_attribute].count;
				index_count = given - given % 3;
			}
			else
			{
				index_count = count - count % 3;
			}

			int material = -1;
			if (try sz named = primitive.attributes.get("material"))
			{
				if (named >= 0 && named < stream.gltf.materials.len()) material = (int)named;
			}
			runs.push({ .index_start = out.indices, .index_count = index_count, .material = material });

			out.vertices += count;
			out.indices += index_count;
		}
	}

	if (runs.len() == 0) return NO_TRIANGLES~;
	out.uvs = uvs.to_array(allocator);
	out.runs = runs.to_array(allocator);
	return out;
}

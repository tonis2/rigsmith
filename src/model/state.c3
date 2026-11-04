<* The pure half of src/app/state.c3: no state, undo or notices. *>
module crig;

import rig;
import gltf;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::collections::list;
import std::collections::map;

<*
 The mesh's own edges, built if they are not already in hand.

 	`rig::MeshAdjacency* around = app.adjacency_for();`

 **Lazy, because the binder never wants it.** The binder measures distance
 through the voxel grid rather than along the edges, so only the area tools,
 posing and collision ask — building this beside the shells would make every
 model load pay for a sort a session that does none of those never reads.

 Rebuilt when the vertex count no longer matches the mesh, which is the one way
 the mesh can change under it without going through `load_mesh` or
 `replace_geometry`; both of those free it outright, so this is a guard rather
 than the mechanism. A mesh of the same length is a mesh this still describes.

 **Borrowed.** What comes back points into the AppState and lives until the mesh
 is replaced. A caller may read it and must not free it.

 @return `The adjacency, empty and unusable for a mesh with no triangles.`
*>
fn rig::MeshAdjacency* adjacency_for(rig::TriMesh* geometry, rig::MeshAdjacency* adjacency)
{
	if (adjacency.vertices() != geometry.positions.len)
	{
		adjacency.free(mem);
		(*adjacency) = rig::build_adjacency(mem, (*geometry));
	}
	return adjacency;
}

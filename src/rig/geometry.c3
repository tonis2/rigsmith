// Vendored from SkinTokens (llm-runner/dependencies/skintokens.c3l/geometry.c3),
// module renamed skintokens -> rig, and trimmed to what crig uses: the encoder's
// normalisation and its faults are gone. The formatting is upstream's — four-space
// indents and braces on the same line, against crig's tabs and Allman elsewhere.
<*
 Triangle meshes: a triangle soup, the invariants everything downstream assumes
 of it, and its bounding box.
*>
module rig;



import std::math;
import std::math::vector;

faultdef
    EMPTY_MESH,
    NOT_TRIANGULATED,
    NORMAL_COUNT_MISMATCH,
    INDEX_OUT_OF_RANGE;

<*
 A triangle soup: three indices per triangle, all pointing into `positions`.

 `normals` is either empty or exactly as long as `positions`. When it is empty
 sampling falls back to face normals, which is correct but faceted — the encoder
 sees a flat-shaded version of the surface.
*>
struct TriMesh {
    Vec3[] positions;
    Vec3[] normals;
    uint[] indices;
}

fn usz TriMesh.triangle_count(self) => self.indices.len / 3;

fn bool TriMesh.has_normals(self) => self.normals.len > 0 && self.normals.len == self.positions.len;

fn void TriMesh.free(&self, Allocator allocator) {
    if (self.positions.len > 0) alloc::free(allocator, self.positions);
    if (self.normals.len > 0) alloc::free(allocator, self.normals);
    if (self.indices.len > 0) alloc::free(allocator, self.indices);
    *self = {};
}

<*
 Check the invariants everything downstream assumes.

 Called when a mesh is read from a file (`gltf/source.c3`), so a bad one is
 refused where it came in.

 @return? EMPTY_MESH : `No vertices or no triangles.`
 @return? NOT_TRIANGULATED : `The index count is not a multiple of three.`
 @return? NORMAL_COUNT_MISMATCH : `Some but not all vertices carry a normal.`
 @return? INDEX_OUT_OF_RANGE : `An index names a vertex that does not exist.`
*>
fn void? TriMesh.validate(self) {
    if (self.positions.len == 0 || self.indices.len == 0) return EMPTY_MESH~;
    if (self.indices.len % 3 != 0) return NOT_TRIANGULATED~;
    if (self.normals.len != 0 && self.normals.len != self.positions.len) return NORMAL_COUNT_MISMATCH~;

    foreach (index : self.indices) {
        if ((usz)index >= self.positions.len) return INDEX_OUT_OF_RANGE~;
    }
}

struct Bounds {
    Vec3 min;
    Vec3 max;
}

fn Vec3 Bounds.center(self) => (self.min + self.max) * 0.5f;
fn Vec3 Bounds.extent(self) => self.max - self.min;

fn Bounds TriMesh.bounds(self) {
    if (self.positions.len == 0) return {};

    Bounds box = { .min = self.positions[0], .max = self.positions[0] };
    foreach (position : self.positions) {
        for (usz axis = 0; axis < 3; axis++) {
            if (position[axis] < box.min[axis]) box.min[axis] = position[axis];
            if (position[axis] > box.max[axis]) box.max[axis] = position[axis];
        }
    }
    return box;
}



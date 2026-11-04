<* The pure half of src/app/import_rig.c3: no state, undo or notices. *>
module crig;

import rig;
import gltf;
import std::math;
import std::math::vector;

<*
 A binding read out of the mesh's own file, in the file's joint order.

 Dense, the shape `bind_geodesic` returns: one row per vertex, one column per
 joint. `names` is what the columns are addressed by — see the module note on why
 that is a name and not an index.

 Owned by the state that holds it. Empty `weights` means nothing was imported,
 which is the state every hand-built rig is in.
*>
struct ImportedSkin
{
	float[] weights;
	String[] names;
	usz vertices;
	usz columns;

	// The dot each column became, so a rename keeps the column. Empty until the
	// columns are matched to dots, and then the join is by name.
	uint[] dot_ids;
}

fn void ImportedSkin.free(&self, Allocator allocator)
{
	foreach (name : self.names)
	{
		if (name.len > 0) alloc::free(allocator, name.ptr);
	}
	if (self.names.len > 0) alloc::free(allocator, self.names);
	if (self.dot_ids.len > 0) alloc::free(allocator, self.dot_ids);
	if (self.weights.len > 0) alloc::free(allocator, self.weights);
	*self = {};
}

fn bool ImportedSkin.present(&self) => self.weights.len > 0 && self.columns > 0;

<*
 Tie each column to the dot of the same name, so later renames keep it.

 All or nothing, like the cover itself: a column whose name matches no dot, or
 more than one, leaves the join by name.
*>
fn void ImportedSkin.bind_to_dots(&self, RigDocument* doc)
{
	if (self.dot_ids.len > 0) alloc::free(mem, self.dot_ids);
	self.dot_ids = {};
	if (!self.present()) return;

	uint[] ids = alloc::new_array(mem, uint, (sz)self.columns);
	foreach (usz c, name : self.names)
	{
		usz found = 0;
		foreach (dot : doc.dots.array_view())
		{
			if (name.len == 0 || dot.name != name) continue;
			ids[c] = dot.id;
			found++;
		}
		if (found != 1)
		{
			alloc::free(mem, ids);
			return;
		}
	}
	self.dot_ids = ids;
}

// Whether any of a clip's channels drives one of the imported joints. The test
// for auto-binding a file's own clip: the clip reaches this rig iff a channel
// targets a source node that just became a bone. Node indices, not names, so it
// is exact and reads no buffers — a clip built for a second skeleton or a prop
// in the same file misses every joint and is left unbound.
fn bool clip_drives_joints(gltf::Animation anim, usz[] joint_nodes)
{
	foreach (channel : anim.channels)
	{
		foreach (node : joint_nodes)
		{
			if ((usz)channel.target.node == node) return true;
		}
	}
	return false;
}

<*
 How many joints a vertex may ride, in the preview and in every file crig
 writes.

 Named here beside `bind_base` because the two have to agree: the preview
 sparsifies the dense matrix itself, the exporter sparsifies it again on the way
 into the file, and a preview keeping four influences where the file keeps two
 shows a shoulder that does not exist anywhere else. Four is glTF's own
 `JOINTS_0` width and what every engine handles without a second attribute set.
*>
const uint SKIN_INFLUENCES = 4;

// The softness a bind takes as a share of the model's longest side, and the one
// it falls back to with no size to take a share of — `bind_geodesic`'s own.
const float BIND_SOFTNESS_SHARE = 1.0e-3;

const float BIND_SOFTNESS_DEFAULT = 1.0e-4;

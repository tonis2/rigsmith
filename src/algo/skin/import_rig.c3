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

<*
 How soft the binder's falloff is at a bone, for this model: `eps` in
 `reach_bias / (d² + eps)`, as a share of the model's size.

 A fixed softness is a fixed length, and the one `bind_geodesic` defaults to is
 a centimetre on a figure in metres — as thick as a finger. Inside that radius
 every bone looks equally near, so a finger's vertices went to all three of its
 joints and the palm alike. A thousandth of the model's longest side keeps the
 falloff a falloff down to the smallest bone anyone places, and makes the bind
 the same whatever units the model was saved in. On the body nothing changes:
 a vertex there sits centimetres from its bone, far outside either softness.

 The longest side of the mesh rather than the rig's height, which is zero for a
 rig laid flat; a mesh with no size keeps the binder's default.
*>
fn float bind_eps(rig::TriMesh* geometry)
{
	Vec3[] positions = geometry.positions;
	if (positions.len == 0) return BIND_SOFTNESS_DEFAULT;
	Vec3 low = positions[0];
	Vec3 high = low;
	foreach (p : positions)
	{
		low = { math::min(low.x, p.x), math::min(low.y, p.y), math::min(low.z, p.z) };
		high = { math::max(high.x, p.x), math::max(high.y, p.y), math::max(high.z, p.z) };
	}
	Vec3 extent = high - low;
	float size = math::max(extent.x, math::max(extent.y, extent.z));
	if (!(size > 0.0f)) return BIND_SOFTNESS_DEFAULT;
	float soft = BIND_SOFTNESS_SHARE * size;
	return soft * soft;
}

<*
 How far behind a vertex's owner each joint may sit and still blend with it, in
 model units — the bands `rig::window_bind` ends the automatic weights at.

 A share of the joint's own bone — its Soft edge (`Dot.band`), or the model's
 default (`BAND_SHARE_DEFAULT`) — measured along the
 segment the binder scores it against, so a finger blends over a finger's
 length and a thigh over a thigh's. Never narrower than a hundredth of the
 model, or a joint with no bone to speak of would hold only what it sits on.

 The caller owns the result.
*>
fn float[] bind_bands(rig::TriMesh* geometry, Allocator allocator, RigView* view, float[] shares = {})
{
	usz bones = view.len();
	float[] bands = alloc::new_array(allocator, float, (sz)bones);
	if (bones == 0) return bands;
	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);
	float floor = math::sqrt(bind_eps(geometry)) * 10.0f;
	foreach (b, joint : view.skeleton.joints)
	{
		float bone = (tails[b] - joint).length();
		float share = b < shares.len && shares[b] > 0.0f ? shares[b] : BAND_SHARE_DEFAULT;
		bands[b] = math::max(share * bone, floor);
	}
	return bands;
}

<*
 What the binder's answer goes through before anything reads it: the model's
 sharpness, then the fingers re-blended along their knuckles at the model's
 knuckle blend (`rig::band_digits`).

 Called on the binder's answer only, in `bind_base`, so the views, the file and
 the guide describe one bind.

 The bands come after the sharpness, not before: a power applied on top would
 narrow every knuckle ramp again, so the blend the slider names would depend on
 a second setting. After it, the knuckle blend is the hand's own sharpness and
 the model's still governs the wrist, the forearm and everything else.

 @param riders : `The joint each shell rides rigidly, from this same bind — a piece bound rigidly is left whole.`
 @param grows : `One per joint or empty: how far a grown finger's knuckle planes move.`
*>
fn void shape_bind(RigDocument* doc, rig::TriMesh* geometry, rig::MeshShells* shells, float[] dense, RigView* view, int[] riders, float[] grows = {})
{
	normalise_loud_rows(dense, view.len());
	sharpen_weights(dense, doc.sharpness);
	rig::band_digits(mem, dense, geometry.positions, &view.skeleton,
		doc.knuckle_blend_fraction(), shells.of, riders, grows);
}

<*
 The dot going by this name, or null.

 By name because that is what a file addresses joints by: a clip names a joint,
 and so does a glTF node. The first match wins; two dots sharing a name is a rig
 the exporter would already have refused to write clips for.
*>
fn Dot* dot_named(RigDocument* doc, String name)
{
	if (name.len == 0) return null;
	foreach (&dot : doc.dots.array_view())
	{
		if (dot.name == name) return dot;
	}
	return null;
}

<*
 The binder's answer for a rig, shaped and windowed: the steps every bind of
 crig's own goes through, whoever keeps the result.

 Touches nothing on the app, so the live bind (`bind_base`) and a joint's tool
 bind (`tool_bind_for`) can share it — the live one passes the app's distance
 arrays to keep, a tool bind its own.

 @param grows : `One per joint or empty — see Dot.grow.`
 @param bands : `One per joint or empty — see Dot.band.`
 @param riders : `Filled with the joint each shell rides; one per shell, or empty.`
 @param nearest : `Filled, one per vertex, or empty.`
 @param distances : `Filled, vertices x joints; the window reads it.`
*>
fn float[] bind_binder(RigDocument* doc, rig::TriMesh* geometry, rig::MeshShells* shells, rig::MeshVoxels* voxels, Allocator allocator, RigView* view, float[] grows, float[] bands, int[] riders, float[] nearest, float[] distances)
{
	float[] bound = rig::bind_geodesic(allocator, voxels, geometry.positions,
		view.skeleton.joints, view.skeleton.parents, shells,
		view.attachments, riders, reaches: view.reaches, nearest: nearest, eps: bind_eps(geometry),
		grow: grows, distances: distances);

	// The binder's own branch only. Imported columns are what an artist painted
	// somewhere else, and sharpening or re-blending those would be crig overruling
	// a bind it did not make — the one thing the import exists to preserve.
	shape_bind(doc, geometry, shells, bound, view, riders, grows);

	// Last, every joint's weight ends a band behind the vertex's owner — see
	// `rig::window_bind` — so the automatic weights stop where the joint stops
	// mattering instead of fading over the whole body. After the shaping, so the
	// knuckle bands split a hand the binder measured whole: cut first, a palm
	// vertex's thin finger shares fall under the bands' trust gate and come out
	// half banded.
	float[] widths = bind_bands(geometry, mem, view, bands);
	defer alloc::free(mem, widths);
	rig::window_bind(bound, distances, view.len(), widths);
	return bound;
}

<*
 Whether the knuckle blend reaches the joint `dot_id`: a digit, or the fork a
 digit chain hangs from — the joints whose weights `rig::band_digits` decides.
*>
fn bool knuckle_blend_applies(RigDocument* doc, rig::TriMesh* geometry, rig::MeshShells* shells, uint dot_id)
{
	RigView? opened = open_rig(doc, geometry, shells, mem);
	if (catch opened) return false;
	RigView view = opened;
	defer view.free(mem);
	sz joint = view.joint_of(dot_id);
	if (joint < 0) return false;
	rig::DigitBands bands = rig::digit_bands(mem, &view.skeleton);
	defer bands.free(mem);
	return bands.shapes((usz)joint);
}

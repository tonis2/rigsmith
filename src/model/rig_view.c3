<* The pure half of src/app/rig_view.c3: no state, undo or notices. *>
module crig;

import rig;
import std::sort;
import gltf;
import std::math;
import std::math::matrix;
import std::math::quaternion;
import std::collections::list;
import std::collections::map;
import std::core::string;

<*
 One skeleton and the four arrays that share its joint order.

 `attachments` and `reaches` are allowed to be empty, which is not the same as
 being absent: `bind_geodesic` reads a short array as "decide the rest
 automatically" and "unlimited from here on", so an empty one costs nothing and
 says what a full one of defaults would have said.
*>
struct RigView
{
	rig::Skeleton skeleton;

	// The dot each joint was built from, in joint order.
	uint[] dot_ids;

	// That dot's name, or "" for an unnamed one — borrowed from the document, so
	// the next rename or delete invalidates them. Blank rather than skipped, so
	// the array keeps lining up with the skeleton; a caller that cannot use a
	// blank has to say so itself.
	String[] names;

	// One joint per *shell*, not per joint: -1 leaves the binder to decide.
	int[] attachments;

	// One per joint, in model units; 0 is unlimited.
	float[] reaches;

	// One per joint: how far its region was last pushed past its automatic edge,
	// in model units (`Dot.grow`), and how far it blends, as a share of its bone
	// (`Dot.band`, 0 the default). Empty when no dot has one. Records of how a
	// held joint was shaped — the automatic weights read neither.
	float[] grows;
	float[] bands;

	// One per joint: whether its weights are its own (`Dot.held`). Empty when no
	// joint's are, which is every rig nobody has edited a weight on.
	bool[] held;

	<*
	 The held joints' stored weights, with their dot ids already turned into
	 joint indices for this build. Empty when no joint is held.

	 Only held joints' entries: together they are each one's whole column, which
	 `AppState.weights` writes over the binder's. An entry whose dot is no longer
	 in the rig is dropped, exactly as a dab is — the document keeps it so undo
	 can bring it back with the dot, and there is no column to write while the
	 dot is gone.
	*>
	PinColumn[] pins;
}

<*
 One slot per dot id up to the largest in `dot_ids`: the joint it became, plus
 one, or 0 for none — so a pass over a long sparse list resolves each entry in
 one read rather than a search of the joints.

 The caller owns the result.
*>
fn usz[] joint_table(Allocator allocator, uint[] dot_ids)
{
	uint top = 0;
	foreach (id : dot_ids) if (id > top) top = id;
	usz[] table = alloc::new_array(allocator, usz, (sz)top + 1);
	foreach (usz j, id : dot_ids) table[id] = j + 1;
	return table;
}

<*
 Releases the view. The strings in `names` are the document's and are left alone.

 @param allocator : `The one open_rig was given.`
*>
fn void RigView.free(&self, Allocator allocator)
{
	self.skeleton.free(allocator);
	if (self.dot_ids.len > 0) alloc::free(allocator, self.dot_ids);
	if (self.names.len > 0) alloc::free(allocator, self.names.ptr);
	if (self.attachments.len > 0) alloc::free(allocator, self.attachments);
	if (self.reaches.len > 0) alloc::free(allocator, self.reaches);
	if (self.grows.len > 0) alloc::free(allocator, self.grows);
	if (self.bands.len > 0) alloc::free(allocator, self.bands);
	if (self.held.len > 0) alloc::free(allocator, self.held);
	if (self.pins.len > 0) alloc::free(allocator, self.pins.ptr);
	*self = {};
}

fn usz RigView.len(&self) => self.skeleton.len();

// Whether joint `j` is held — see `Dot.held`.
fn bool RigView.holds(&self, usz j) => j < self.held.len && self.held[j];

// Whether every joint is held, so nothing of the binder's is on show.
fn bool RigView.all_held(&self)
{
	if (self.held.len != self.len() || self.held.len == 0) return false;
	foreach (on : self.held) if (!on) return false;
	return true;
}

<*
 Which joint a dot became.

 @param id : `The dot asked about. Zero is the document's "no dot" and finds nothing.`
 @return `The joint index, or -1 for a dot this rig does not hold.`
*>
fn sz RigView.joint_of(&self, uint id)
{
	if (id == 0) return -1;
	return array::index_of(self.dot_ids, id) ?? -1;
}

<*
 The multipliers an older session carried, with their dot ids resolved against
 this build's joint order — read once, by `legacy_weights`, which bakes them
 into the weights an older session showed. Empty when there are none, which is every session written
 since version 31.
*>
fn PaintColumn[] paint_columns(RigDocument* doc, rig::TriMesh* geometry, Allocator allocator, uint[] dot_ids)
{
	sz dabs = doc.paint.len();
	if (dabs == 0) return {};

	PaintColumn[] columns = alloc::new_array(allocator, PaintColumn, dabs);
	usz kept = 0;
	foreach (dab : doc.paint.array_view())
	{
		if ((usz)dab.vertex >= geometry.positions.len) continue;
		foreach (usz j, id : dot_ids)
		{
			if (id != dab.dot_id) continue;
			columns[kept++] = { .vertex = dab.vertex, .joint = j, .factor = dab.factor };
			break;
		}
	}

	if (kept == 0)
	{
		alloc::free(allocator, columns);
		return {};
	}
	return columns[:kept];
}

<*
 Which joints are held (`Dot.held`): one flag per joint, empty when none is.
*>
fn bool[] held_joints(RigDocument* doc, Allocator allocator, uint[] dot_ids)
{
	bool holding = false;
	foreach (dot : doc.dots.array_view()) if (dot.held) holding = true;
	if (!holding) return {};
	bool[] held = alloc::new_array(allocator, bool, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = doc.find(id);
		held[j] = dot && dot.held;
	}
	return held;
}

<*
 The held joints' stored weights with their dot ids resolved against this
 build's joint order.

 `paint_columns` for the other layer — one pass over a sparse list, dropping an
 entry whose dot is gone or not held and a vertex past the end of the mesh. A
 full column per held joint is a long list, so each entry is resolved through
 one table read (`joint_table`) rather than a search of the joints.

 Empty when no joint is held, which is the ordinary case and costs no
 allocation.
*>
fn PinColumn[] pin_columns(RigDocument* doc, rig::TriMesh* geometry, Allocator allocator, uint[] dot_ids)
{
	sz stored = doc.pins.len();
	if (stored == 0) return {};

	usz[] table = joint_table(mem, dot_ids);
	defer alloc::free(mem, table);
	bool[] held = alloc::new_array(mem, bool, (sz)table.len);
	defer alloc::free(mem, held);
	usz holding = 0;
	foreach (dot : doc.dots.array_view())
	{
		if (!dot.held || (usz)dot.id >= table.len) continue;
		held[dot.id] = true;
		holding++;
	}
	if (holding == 0) return {};

	PinColumn[] columns = alloc::new_array(allocator, PinColumn, stored);
	usz kept = 0;
	foreach (pin : doc.pins.array_view())
	{
		if ((usz)pin.vertex >= geometry.positions.len) continue;
		if ((usz)pin.dot_id >= table.len || !held[pin.dot_id] || table[pin.dot_id] == 0) continue;
		columns[kept++] = { .vertex = pin.vertex, .joint = table[pin.dot_id] - 1, .share = pin.share };
	}

	if (kept == 0)
	{
		alloc::free(allocator, columns);
		return {};
	}
	return columns[:kept];
}

<*
 The document's attachments as the binder takes them: one joint index per shell,
 -1 where the binder is left to decide for itself.

 An attachment whose dot has since been deleted resolves to nothing and its shell
 falls back to the automatic rule, which is the right reading of a pin hanging
 off a hole.

 Empty when there is nothing to say — `bind_geodesic` reads a short array as
 "decide the rest automatically".
*>
fn int[] attachment_joints(RigDocument* doc, rig::MeshShells* shells, Allocator allocator, uint[] dot_ids)
{
	if (shells.count == 0 || doc.attachments.len() == 0) return {};

	int[] joints = alloc::new_array(allocator, int, (sz)shells.count);
	joints[:shells.count] = -1;

	foreach (entry : doc.attachments.array_view())
	{
		if ((usz)entry.shell >= shells.count) continue;

		joints[entry.shell] = -1;
		foreach (usz j, id : dot_ids)
		{
			if (id != entry.dot_id) continue;
			joints[entry.shell] = (int)j;
			break;
		}
	}
	return joints;
}

// One name per joint, borrowed from the document. See `RigView.names` for what
// a blank one means and how long these live.
fn String[] joint_names(RigDocument* doc, Allocator allocator, uint[] dot_ids)
{
	String[] names = alloc::new_array(allocator, String, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = doc.find(id);
		names[j] = dot ? dot.name : "";
	}
	return names;
}

<*
 The document's grows as the binder takes them: one distance per joint, empty
 when no dot is grown — see `Dot.grow`.
*>
fn float[] grow_joints(RigDocument* doc, Allocator allocator, uint[] dot_ids)
{
	bool grown = false;
	foreach (dot : doc.dots.array_view()) if (dot.grow != 0.0f) grown = true;
	if (!grown) return {};
	float[] grows = alloc::new_array(allocator, float, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = doc.find(id);
		grows[j] = dot ? dot.grow : 0.0f;
	}
	return grows;
}

<*
 The document's soft edges: one share of its bone per joint, 0 for the model's
 default, empty when no dot has one — see `Dot.band`.
*>
fn float[] band_joints(RigDocument* doc, Allocator allocator, uint[] dot_ids)
{
	bool softened = false;
	foreach (dot : doc.dots.array_view()) if (dot.band > 0.0f) softened = true;
	if (!softened) return {};
	float[] bands = alloc::new_array(allocator, float, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = doc.find(id);
		bands[j] = dot ? dot.band : 0.0f;
	}
	return bands;
}

// Named for what it holds rather than for its element type: `rig` exports a
// `UintList` of its own, and an unqualified name that resolves to either is a
// name worth not having.
alias DotIdList = List{uint};

const String GENERATED_NAME_PREFIX = "Generated";

<*
 The document's reaches as the binder takes them: one distance per joint.

 Empty when no dot has a reach — `bind_geodesic` reads a short array as
 "unlimited from here on", so an empty one costs nothing and says the same
 thing, and a rig that never sets a reach binds exactly as it always did.

 **A mixed rig has no unlimited dots.** Once any dot is limited, one that is not
 gets `default_reach` rather than zero, because zero is not neutral here.
 `reach_bias` scores an unlimited bone 1 at every distance while a sized one
 falls off from its own radius, so on a rig where most dots are sized and a few
 are not, the few outrank the many *everywhere* — and being far from the mesh
 they hold stops costing them anything. A self-rigged squirrel with reaches on
 seventeen dots and none on its two hind feet gave those two feet a third of the
 body, head included, and skewed the torso whenever a hind leg bent. Partial
 reaches were strictly worse than none, which is not a thing a user can be
 expected to guess.

 `default_reach` is the same figure the viewport already draws as an unlimited
 dot's ghost ring, so this makes the binder agree with what was on screen rather
 than inventing a size. A dot it cannot size — no bones, no geometry — comes back
 zero and stays genuinely unlimited; there is nothing better to say about it.
*>
fn float[] reach_joints(RigDocument* doc, rig::TriMesh* geometry, Allocator allocator, uint[] dot_ids)
{
	bool any_limited = false;
	foreach (dot : doc.dots.array_view())
	{
		if (dot.reach <= 0.0f) continue;
		any_limited = true;
		break;
	}
	if (!any_limited) return {};

	float[] reaches = alloc::new_array(allocator, float, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = doc.find(id);
		if (!dot) { reaches[j] = 0.0f; continue; }
		reaches[j] = dot.reach > 0.0f ? dot.reach : default_reach(doc, geometry, id);
	}
	return reaches;
}

<*
 Build the skeleton and everything keyed to its joint order, in one call.

 	`RigView? opened = app.open_rig(mem);`
 	`if (catch opened) return;`
 	`RigView view = opened;`
 	`defer view.free(mem);`

 All five fields, always — the cost is a handful of linear scans over the dots,
 which is nothing beside the bind that follows, and a view that could be *partly*
 filled would put the caller back to tracking which parts are trustworthy.

 @return? NO_DOTS : `The document is empty, so there is no rig to view.`
*>
fn RigView? open_rig(RigDocument* doc, rig::TriMesh* geometry, rig::MeshShells* shells, Allocator allocator)
{
	uint[] dot_ids;
	rig::Skeleton skeleton = build_skeleton(doc, allocator, &dot_ids)!;

	return {
		.skeleton = skeleton,
		.dot_ids = dot_ids,
		.names = joint_names(doc, allocator, dot_ids),
		.attachments = attachment_joints(doc, shells, allocator, dot_ids),
		.reaches = reach_joints(doc, geometry, allocator, dot_ids),
		.grows = grow_joints(doc, allocator, dot_ids),
		.bands = band_joints(doc, allocator, dot_ids),
		.held = held_joints(doc, allocator, dot_ids),
		.pins = pin_columns(doc, geometry, allocator, dot_ids),
	};
}

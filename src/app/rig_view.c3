<*
 The document as a skeleton, plus everything that is indexed by its joint order.

 `build_skeleton` walks the dots breadth-first from the root, which means a
 joint's *index* is an artefact of that one walk: add a dot, delete one, or move
 the root and every index shifts. The document, meanwhile, holds everything by
 dot **id** — attachments, reaches, names. So every caller that binds or writes
 has to build the map between the two and use it before anything moves, and
 mixing a joint order from one build with a lookup from another is silent: the
 arrays are the right length and the weights land on the wrong bones.

 That rule used to be written nine times, once per caller, as a comment. Here it
 is the type: `open_rig` produces all five together or none of them, and
 nothing hands out a `dot_ids` that its skeleton did not come with.

 **Nothing here is a snapshot of the *document*.** Edit a dot and the view is
 stale like any other derived thing; it lives for the length of one operation.
*>
module crig;

import rig;
import std::sort;



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
fn RigView? AppState.open_rig(&self, Allocator allocator)
{
	uint[] dot_ids;
	rig::Skeleton skeleton = build_skeleton(&self.doc, allocator, &dot_ids)!;

	return {
		.skeleton = skeleton,
		.dot_ids = dot_ids,
		.names = self.joint_names(allocator, dot_ids),
		.attachments = self.attachment_joints(allocator, dot_ids),
		.reaches = self.reach_joints(allocator, dot_ids),
		.grows = self.grow_joints(allocator, dot_ids),
		.bands = self.band_joints(allocator, dot_ids),
		.held = self.held_joints(allocator, dot_ids),
		.pins = self.pin_columns(allocator, dot_ids),
	};
}

<*
 Whether the cached playback rig still describes the document.

 Only the player uses the cache, and only while a clip runs. It is thrown away
 the moment anything could have changed what `open_rig` reads: a committed edit
 moves the undo revision, a geometry mark moves `rig_generation`, and a gesture
 in flight (a joint drag, a paint stroke, a pose edit) writes the document
 without a revision until it is released — so those are checked directly. The
 view's names are borrowed from the document, so this is also what keeps a
 renamed or deleted joint from being read through a stale borrow.
*>
fn bool AppState.playback_rig_fresh(&self)
{
	return self.playback_rig_built
		&& self.drag.dot == 0
		&& !self.stroke_open
		&& !self.pose_edit_active
		&& self.playback_rig_revision == self.undo_stack.revision
		&& self.playback_rig_generation == self.rig_generation;
}

// Adopt a freshly built view as the playback cache, releasing the previous one
// and stamping the revision and generation it was built against.
fn void AppState.keep_playback_rig(&self, RigView view)
{
	if (self.playback_rig_built) self.playback_rig.free(mem);
	self.playback_rig = view;
	self.playback_rig_built = true;
	self.playback_rig_revision = self.undo_stack.revision;
	self.playback_rig_generation = self.rig_generation;
}

// Release the cached playback rig. Called when playback stops and at teardown;
// the next play rebuilds it.
fn void AppState.drop_playback_rig(&self)
{
	if (self.playback_rig_built) self.playback_rig.free(mem);
	self.playback_rig = {};
	self.playback_rig_built = false;
}

<*
 The multipliers an older session carried, with their dot ids resolved against
 this build's joint order — read once, by `legacy_weights`, which bakes them
 into the weights an older session showed. Empty when there are none, which is every session written
 since version 31.
*>
fn PaintColumn[] AppState.paint_columns(&self, Allocator allocator, uint[] dot_ids)
{
	sz dabs = self.doc.paint.len();
	if (dabs == 0) return {};

	PaintColumn[] columns = alloc::new_array(allocator, PaintColumn, dabs);
	usz kept = 0;
	foreach (dab : self.doc.paint.array_view())
	{
		if ((usz)dab.vertex >= self.geometry.positions.len) continue;
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
fn bool[] AppState.held_joints(&self, Allocator allocator, uint[] dot_ids)
{
	bool holding = false;
	foreach (dot : self.doc.dots.array_view()) if (dot.held) holding = true;
	if (!holding) return {};
	bool[] held = alloc::new_array(allocator, bool, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = self.doc.find(id);
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
fn PinColumn[] AppState.pin_columns(&self, Allocator allocator, uint[] dot_ids)
{
	sz stored = self.doc.pins.len();
	if (stored == 0) return {};

	usz[] table = joint_table(mem, dot_ids);
	defer alloc::free(mem, table);
	bool[] held = alloc::new_array(mem, bool, (sz)table.len);
	defer alloc::free(mem, held);
	usz holding = 0;
	foreach (dot : self.doc.dots.array_view())
	{
		if (!dot.held || (usz)dot.id >= table.len) continue;
		held[dot.id] = true;
		holding++;
	}
	if (holding == 0) return {};

	PinColumn[] columns = alloc::new_array(allocator, PinColumn, stored);
	usz kept = 0;
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= self.geometry.positions.len) continue;
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
fn int[] AppState.attachment_joints(&self, Allocator allocator, uint[] dot_ids)
{
	if (self.shells.count == 0 || self.doc.attachments.len() == 0) return {};

	int[] joints = alloc::new_array(allocator, int, (sz)self.shells.count);
	joints[:self.shells.count] = -1;

	foreach (entry : self.doc.attachments.array_view())
	{
		if ((usz)entry.shell >= self.shells.count) continue;

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
fn String[] AppState.joint_names(&self, Allocator allocator, uint[] dot_ids)
{
	String[] names = alloc::new_array(allocator, String, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = self.doc.find(id);
		names[j] = dot ? dot.name : "";
	}
	return names;
}

<*
 The document's grows as the binder takes them: one distance per joint, empty
 when no dot is grown — see `Dot.grow`.
*>
fn float[] AppState.grow_joints(&self, Allocator allocator, uint[] dot_ids)
{
	bool grown = false;
	foreach (dot : self.doc.dots.array_view()) if (dot.grow != 0.0f) grown = true;
	if (!grown) return {};
	float[] grows = alloc::new_array(allocator, float, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = self.doc.find(id);
		grows[j] = dot ? dot.grow : 0.0f;
	}
	return grows;
}

<*
 The document's soft edges: one share of its bone per joint, 0 for the model's
 default, empty when no dot has one — see `Dot.band`.
*>
fn float[] AppState.band_joints(&self, Allocator allocator, uint[] dot_ids)
{
	bool softened = false;
	foreach (dot : self.doc.dots.array_view()) if (dot.band > 0.0f) softened = true;
	if (!softened) return {};
	float[] bands = alloc::new_array(allocator, float, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = self.doc.find(id);
		bands[j] = dot ? dot.band : 0.0f;
	}
	return bands;
}

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
fn float[] AppState.reach_joints(&self, Allocator allocator, uint[] dot_ids)
{
	bool any_limited = false;
	foreach (dot : self.doc.dots.array_view())
	{
		if (dot.reach <= 0.0f) continue;
		any_limited = true;
		break;
	}
	if (!any_limited) return {};

	float[] reaches = alloc::new_array(allocator, float, (sz)dot_ids.len);
	foreach (usz j, id : dot_ids)
	{
		Dot* dot = self.doc.find(id);
		if (!dot) { reaches[j] = 0.0f; continue; }
		reaches[j] = dot.reach > 0.0f ? dot.reach : self.default_reach(id);
	}
	return reaches;
}

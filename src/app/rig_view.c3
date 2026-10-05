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

	<*
	 The hand corrections, with their dot ids already turned into joint indices
	 for this build. Empty when nothing is painted.

	 Resolved here rather than at the multiply because that is this type's whole
	 job — the document keys paint by dot id, a bind is indexed by joint, and
	 doing the lookup once per bind instead of once per dab is also the only
	 version that does not go quadratic on a big stroke.

	 A dab whose dot is no longer in the rig is dropped rather than carried: the
	 document keeps it so undo can bring it back with the dot, but there is no
	 column to multiply while the dot is gone.
	*>
	PaintColumn[] paint;

	<*
	 The stated shares, with their dot ids already turned into joint indices for
	 this build and **grouped by vertex**. Empty when nothing is pinned.

	 Resolved here for the reason `paint` is, and grouped besides: `pin_over`
	 rewrites a whole row around every pin on it at once, so the pins on one
	 vertex have to arrive together. The document stores them in the order they
	 were made, which interleaves vertices as soon as a second lasso crosses the
	 first — see `pin_columns`, where the grouping is done.

	 A pin whose dot is no longer in the rig is dropped, exactly as a dab is: the
	 document keeps it so undo can bring it back with the dot, and there is no
	 column to write while the dot is gone.
	*>
	PinColumn[] pins;
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
		.paint = self.paint_columns(allocator, dot_ids),
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
 The document's paint with its dot ids resolved against this build's joint order.

 One pass over the dabs and one over the joints per dab — but the dabs are sparse
 and the joints are a handful, so this is nothing beside the bind that follows.
 What it buys is that the multiply itself is a straight walk with no lookups.

 Empty when nothing is painted, which is the ordinary case and costs no
 allocation.
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

// Vertex order, which is the grouping `pin_over` needs. Ties are left to the
// sort, since two pins on one vertex name different dots and the row rewrite
// treats them as a set.
fn int by_pinned_vertex(PinColumn a, PinColumn b) @local
{
	if (a.vertex < b.vertex) return -1;
	if (a.vertex > b.vertex) return 1;
	return 0;
}

<*
 The document's pins with their dot ids resolved against this build's joint
 order, grouped by vertex.

 `paint_columns` for the other layer — same one pass over a sparse list, same
 drop of a stale dot and of a vertex past the end of the mesh — plus the sort
 that puts every pin on a vertex beside its siblings. Sorted rather than
 gathered through a per-vertex index because the layer is sparse and the mesh is
 not: a chain index costs one entry per *vertex*, and this costs one comparison
 per pin.

 Empty when nothing is pinned, which is the ordinary case and costs no
 allocation.
*>
fn PinColumn[] AppState.pin_columns(&self, Allocator allocator, uint[] dot_ids)
{
	sz held = self.doc.pins.len();
	if (held == 0) return {};

	PinColumn[] columns = alloc::new_array(allocator, PinColumn, held);
	usz kept = 0;
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= self.geometry.positions.len) continue;
		foreach (usz j, id : dot_ids)
		{
			if (id != pin.dot_id) continue;
			columns[kept++] = { .vertex = pin.vertex, .joint = j, .share = pin.share };
			break;
		}
	}

	if (kept == 0)
	{
		alloc::free(allocator, columns);
		return {};
	}

	sort::quicksort(columns[:kept], &by_pinned_vertex);
	return columns[:kept];
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
	if (self.paint.len > 0) alloc::free(allocator, self.paint.ptr);
	if (self.pins.len > 0) alloc::free(allocator, self.pins.ptr);
	*self = {};
}

fn usz RigView.len(&self) => self.skeleton.len();

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

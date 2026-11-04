<* The pure half of src/app/rig_view.c3: no state, undo or notices. *>
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

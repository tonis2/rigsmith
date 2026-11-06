<*
 Joined surfaces: copies of one point (a seam split for UVs or hard edges) and
 layers lying close over each other that the automatic weights move together.

 Every column write keeps them together (`join_column`). Fix weights repairs
 the seams older edits split, which a pose opens as holes.
*>
module crig;

import rig;
import std::math::vector;
import std::collections::list;

fn float AppState.join_scale(&self) => join_scale(&self.doc, &self.geometry);

// The mesh's layer partners at `JOIN_GAP`, built on first ask. Borrowed.
fn rig::JoinedLayers* AppState.joined_layers(&self)
{
	rig::MeshAdjacency* around = self.adjacency_for();
	float gap = JOIN_GAP * self.join_scale();
	if (self.joined.classes() != around.classes() || self.joined_gap != gap)
	{
		self.joined.free(mem);
		self.joined = rig::build_joined(mem, self.geometry, around, gap, JOIN_DETOUR);
		self.joined_gap = gap;
	}
	return &self.joined;
}

<*
 Keep joined surfaces together in one joint's column before it is written.
 Every copy of a point takes the copy that moved most, and a layer under a
 moved one (`carries_to`) the write left alone takes what it moved to. Only
 this column changes.

 @param column : `The column about to be written; changed in place.`
 @param shown : `The joint's column as it is now.`
*>
fn void AppState.join_column(&self, RigView* view, float[] column, float[] shown)
{
	usz count = column.len;
	rig::MeshAdjacency* around = self.adjacency_for();
	if (count == 0 || shown.len != count || around.vertices() != count) return;
	usz classes = around.classes();

	// Per weld class: how far its furthest-moved copy moved (-1 untouched), and to what.
	float[] moved = alloc::new_array(mem, float, (sz)classes);
	defer alloc::free(mem, moved);
	float[] value = alloc::new_array(mem, float, (sz)classes);
	defer alloc::free(mem, value);
	moved[..] = -1.0f;
	bool touched = false;
	foreach (v, weight : column)
	{
		if (weight == shown[v]) continue;
		uint c = around.class_of[v];
		float step = math::abs(weight - shown[v]);
		if (step <= moved[c]) continue;
		moved[c] = step;
		value[c] = weight;
		touched = true;
	}
	if (!touched) return;

	rig::JoinedLayers* layers = self.joined_layers();
	usz bones = view.len();
	float[] automatic = self.base_bind_for(view);
	if (layers.classes() == classes && automatic.len == count * bones)
	{
		// One hop: what a layer is carried is never carried on.
		float[] carried = alloc::new_array(mem, float, (sz)classes);
		defer alloc::free(mem, carried);
		float[] carry = alloc::new_array(mem, float, (sz)classes);
		defer alloc::free(mem, carry);
		carried[..] = -1.0f;
		for (usz c = 0; c < classes; c++)
		{
			if (moved[c] < 0.0f) continue;
			foreach (p : layers.around(c))
			{
				if (moved[p] >= 0.0f || moved[c] <= carried[p]) continue;
				usz from = (usz)around.first[c];
				usz to = (usz)around.first[p];
				if (!joined_rows(automatic, bones, from, to)) continue;
				if (!carries_to(self.geometry.positions, self.geometry.normals, from, to)) continue;
				carried[p] = moved[c];
				carry[p] = value[c];
			}
		}
		for (usz c = 0; c < classes; c++)
		{
			if (carried[c] < 0.0f) continue;
			moved[c] = carried[c];
			value[c] = carry[c];
		}
	}

	foreach (v, &weight : column)
	{
		uint c = around.class_of[v];
		if (moved[c] >= 0.0f) *weight = value[c];
	}
}

fn TearPatch[] AppState.tear_patches(&self, Allocator allocator)
{
	usz count = self.geometry.positions.len;
	rig::MeshAdjacency* around = self.adjacency_for();
	float scale = self.join_scale();
	if (count == 0 || around.vertices() != count || scale <= 0.0f) return {};

	RigView? opened = self.open_rig(mem);
	if (catch opened) return {};
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	if (bones == 0 || painted.len < count * bones) return {};
	return find_tear_patches(allocator, &self.geometry, around, &view, painted, scale);
}

<*
 Close tears, as one undo step: every copy of a torn point takes the row of the
 copy the edits moved furthest from the automatic weights, so what was painted
 stays. An unused row is never the one taken.

 @param commit : `Close the undo group — false when another fix joins this step.`
 @return `How many vertices changed.`
*>
fn usz AppState.fix_tears(&self, TearPatch[] tears, bool commit = true)
{
	usz count = self.geometry.positions.len;
	rig::MeshAdjacency* around = self.adjacency_for();
	if (tears.len == 0 || count == 0 || around.vertices() != count) return 0;
	self.flush_edges();

	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);
	float[] automatic = self.weights(mem, &view, AUTOMATIC);
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	if (bones == 0 || painted.len < count * bones || automatic.len < count * bones) return 0;

	// Per torn weld: the copy whose used row is furthest from its automatic one.
	usz classes = around.classes();
	bool[] torn = alloc::new_array(mem, bool, (sz)classes);
	defer alloc::free(mem, torn);
	foreach (tear : tears)
	{
		foreach (link : tear.links) if ((usz)link.a < count) torn[around.class_of[link.a]] = true;
	}
	sz[] source = alloc::new_array(mem, sz, (sz)classes);
	defer alloc::free(mem, source);
	float[] score = alloc::new_array(mem, float, (sz)classes);
	defer alloc::free(mem, score);
	source[..] = -1;
	for (usz v = 0; v < count; v++)
	{
		uint c = around.class_of[v];
		if (!torn[c]) continue;
		float total = 0.0f;
		foreach (weight : painted[v * bones:bones]) total += weight;
		if (total <= UNUSED_TOTAL) continue;
		float away = rows_apart(painted[v * bones:bones], automatic[v * bones:bones]);
		if (source[c] >= 0 && away <= score[c]) continue;
		source[c] = (sz)v;
		score[c] = away;
	}

	float[] target = alloc::new_array(mem, float, (sz)(count * bones));
	defer alloc::free(mem, target);
	target[..] = painted[:count * bones];
	usz changed = 0;
	for (usz v = 0; v < count; v++)
	{
		sz from = source[around.class_of[v]];
		if (from < 0 || (usz)from == v) continue;
		bool differs = false;
		for (usz j = 0; j < bones; j++)
		{
			float weight = painted[(usz)from * bones + j];
			if (target[v * bones + j] != weight) differs = true;
			target[v * bones + j] = weight;
		}
		if (differs) changed++;
	}
	if (changed == 0) return 0;

	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	usz written = 0;
	for (usz j = 0; j < bones; j++)
	{
		bool differs = false;
		for (usz v = 0; v < count; v++)
		{
			column[v] = target[v * bones + j];
			if (column[v] != painted[v * bones + j]) differs = true;
		}
		if (differs) written += self.replace_column(&view, view.dot_ids[j], column, commit: false);
	}
	if (written == 0) return 0;
	if (commit) self.undo_stack.commit();
	return changed;
}

<*
 Survey the bind for tears and keep what it found for the Weights card, which
 lists them and marks them red until the next edit.

 @return `How many tears there are.`
*>
fn usz AppState.find_tears(&self)
{
	self.drop_tears();
	self.tears = self.tear_patches(mem);
	self.tears_checked = true;
	self.tears_revision = self.undo_stack.revision;
	self.tears_generation = next_generation();
	if (self.tinting())
	{
		self.weights_stale = true;
		self.weights_due = 0.0f;
	}
	return self.tears.len;
}

fn void AppState.drop_tears(&self)
{
	free_tears(mem, self.tears);
	self.tears = {};
	self.tears_checked = false;
}

// Whether the last survey still describes the bind: nothing has been edited since.
fn bool AppState.tears_current(&self) => self.tears_checked && self.tears_revision == self.undo_stack.revision;

// While the Weights card lists tears, mark their vertices red on whichever view is up.
fn void AppState.overlay_tear_tints(&self)
{
	usz count = self.geometry.positions.len;
	if (!self.tears_current() || self.tints.len != count) return;
	uint red = rgb(STRAY_RED.x, STRAY_RED.y, STRAY_RED.z);
	foreach (tear : self.tears)
	{
		foreach (v : tear.vertices) if ((usz)v < count) self.tints[v] = red;
	}
}

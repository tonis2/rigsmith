<*
 Joined surfaces: copies of one point (a seam split for UVs or hard edges) and
 layers lying close over each other that the automatic weights move together.

 Every column write keeps them together (`join_column`). Find / Fix tears
 repair the seams older edits split, which a pose opens as holes.
*>
module crig;

import rig;
import std::math::vector;
import std::collections::list;

// Two copies of one point whose rows a pose can pull apart.
struct TearLink
{
	uint a;
	uint b;
}

// A run of torn seam side by side on the mesh, for the readout and the red marks.
struct TearPatch
{
	TearLink[] links;             // owned
	uint[] vertices;              // owned: every vertex of the patch
	Vec3 centre;                  // at rest
	float pull;                   // the most a pose pulls a pair apart, over the height per radian
	uint[SKIN_INFLUENCES] joints; // the joints whose weights differ most across it
	usz joint_count;
}

fn void free_tears(Allocator allocator, TearPatch[] tears)
{
	foreach (tear : tears)
	{
		if (tear.links.len > 0) alloc::free(allocator, tear.links);
		if (tear.vertices.len > 0) alloc::free(allocator, tear.vertices);
	}
	if (tears.len > 0) alloc::free(allocator, tears);
}

// The length joined surfaces are measured in: the model's height, or its widest side when flat.
fn float AppState.join_scale(&self)
{
	float height = self.model_height();
	if (height > 0.0f || self.geometry.positions.len == 0) return height;
	rig::Bounds box = self.geometry.bounds();
	Vec3 size = box.max - box.min;
	return math::max(size.x, size.z);
}

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

// How different two rows are as shares, 0 to 1. An unused row is all of it away from a used one.
fn float rows_apart(float[] a, float[] b)
{
	float total_a = 0.0f;
	float total_b = 0.0f;
	foreach (weight : a) total_a += weight;
	foreach (weight : b) total_b += weight;
	bool empty_a = total_a <= UNUSED_TOTAL;
	bool empty_b = total_b <= UNUSED_TOTAL;
	if (empty_a || empty_b) return empty_a == empty_b ? 0.0f : 1.0f;
	float sum = 0.0f;
	foreach (k, weight : a) sum += math::abs(weight / total_a - b[k] / total_b);
	return sum * 0.5f;
}

// Whether the automatic bind moves two vertices together.
fn bool joined_rows(float[] automatic, usz bones, usz a, usz b)
{
	return rows_apart(automatic[a * bones:bones], automatic[b * bones:bones]) <= JOIN_AUTO_DIFF;
}

// How squarely one layer has to face the other to count as lying over it.
const float COVER_COS = 0.2f;

<*
 Whether paint on vertex a carries to its layer partner b: when b lies under
 a's surface, or the two are the back-to-back sides of a thin piece. Never up
 onto a layer lying over a, nor sideways onto a piece beside it.
*>
fn bool carries_to(Vec3[] positions, Vec3[] normals, usz a, usz b)
{
	if (normals.len != positions.len) return false;
	Vec3 d = positions[b] - positions[a];
	float length = d.length();
	float normal_a = normals[a].length();
	float normal_b = normals[b].length();
	if (length <= 0.0f || normal_a <= 0.0f || normal_b <= 0.0f) return false;
	float b_ahead = normals[a].dot(d) / (length * normal_a);  // b in front of a's surface
	float a_ahead = -normals[b].dot(d) / (length * normal_b); // a in front of b's surface
	return b_ahead < -COVER_COS && (a_ahead > COVER_COS || a_ahead < -COVER_COS);
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

<*
 Every tear in the bind as shown, the ones a pose pulls furthest first: copies
 of one point whose rows a pose can pull at least `TEAR_PULL` of the height
 apart.

 The caller owns the result and frees it with `free_tears`.
*>
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

	float[] scratch = alloc::new_array(mem, float, (sz)(bones * 3));
	defer alloc::free(mem, scratch);
	float[] row_a = scratch[0:bones];
	float[] row_b = scratch[bones:bones];
	float[] limb = scratch[2 * bones:bones];

	List{TearLink} links;
	links.init(mem);
	defer links.free();
	List{float} pulls;
	pulls.init(mem);
	defer pulls.free();
	for (usz v = 0; v < count; v++)
	{
		usz first = (usz)around.first[around.class_of[v]];
		if (first == v) continue;
		share_row(painted[first * bones:bones], row_a);
		share_row(painted[v * bones:bones], row_b);
		float pull = pull_apart(&view.skeleton, row_a, row_b, self.geometry.positions[v], limb);
		if (pull <= TEAR_PULL * scale) continue;
		links.push({ (uint)first, (uint)v });
		pulls.push(pull);
	}
	if (links.len() == 0) return {};

	// Patches: the torn welds, joined by the mesh between them.
	usz classes = around.classes();
	bool[] torn = alloc::new_array(mem, bool, (sz)classes);
	defer alloc::free(mem, torn);
	foreach (link : links) torn[around.class_of[link.a]] = true;
	int[] patch_of = alloc::new_array(mem, int, (sz)classes);
	defer alloc::free(mem, patch_of);
	patch_of[..] = -1;
	List{uint} flood;
	flood.init(mem);
	defer flood.free();
	int patches = 0;
	for (usz c = 0; c < classes; c++)
	{
		if (!torn[c] || patch_of[c] >= 0) continue;
		flood.clear();
		flood.push((uint)c);
		patch_of[c] = patches;
		for (sz next = 0; next < flood.len(); next++)
		{
			foreach (n : around.around(flood[next]))
			{
				if (!torn[n] || patch_of[n] >= 0) continue;
				patch_of[n] = patches;
				flood.push(n);
			}
		}
		patches++;
	}

	TearPatch[] tears = alloc::new_array(allocator, TearPatch, (sz)patches);
	float[] differ = alloc::new_array(mem, float, (sz)(bones * (usz)patches));
	defer alloc::free(mem, differ);
	usz[] link_count = alloc::new_array(mem, usz, (sz)patches);
	defer alloc::free(mem, link_count);
	usz[] vertex_count = alloc::new_array(mem, usz, (sz)patches);
	defer alloc::free(mem, vertex_count);
	foreach (i, link : links)
	{
		usz k = (usz)patch_of[around.class_of[link.a]];
		link_count[k]++;
		tears[k].pull = math::max(tears[k].pull, pulls[i] / scale);
		share_row(painted[(usz)link.a * bones:bones], row_a);
		share_row(painted[(usz)link.b * bones:bones], row_b);
		for (usz j = 0; j < bones; j++) differ[k * bones + j] += math::abs(row_a[j] - row_b[j]);
	}
	for (usz v = 0; v < count; v++)
	{
		int k = patch_of[around.class_of[v]];
		if (k < 0) continue;
		vertex_count[(usz)k]++;
		tears[(usz)k].centre += self.geometry.positions[v];
	}
	float[SKIN_INFLUENCES] joint_shares;
	foreach (k, &tear : tears)
	{
		tear.links = alloc::new_array(allocator, TearLink, (sz)link_count[k]);
		tear.vertices = alloc::new_array(allocator, uint, (sz)vertex_count[k]);
		if (vertex_count[k] > 0) tear.centre /= (float)vertex_count[k];
		tear.joint_count = strongest_shares(differ[(usz)k * bones:bones], view.dot_ids, tear.joints[..], joint_shares[..], 0.0f);
		link_count[k] = 0;
		vertex_count[k] = 0;
	}
	foreach (link : links)
	{
		usz k = (usz)patch_of[around.class_of[link.a]];
		tears[k].links[link_count[k]++] = link;
	}
	for (usz v = 0; v < count; v++)
	{
		int k = patch_of[around.class_of[v]];
		if (k >= 0) tears[(usz)k].vertices[vertex_count[(usz)k]++] = (uint)v;
	}

	for (usz i = 0; i + 1 < tears.len; i++)
	{
		usz top = i;
		for (usz j = i + 1; j < tears.len; j++) if (tears[j].pull > tears[top].pull) top = j;
		if (top == i) continue;
		TearPatch swap = tears[i];
		tears[i] = tears[top];
		tears[top] = swap;
	}
	return tears;
}

<*
 Close tears, as one undo step: every copy of a torn point takes the row of the
 copy the edits moved furthest from the automatic weights, so what was painted
 stays. An unused row is never the one taken.

 @return `How many vertices changed.`
*>
fn usz AppState.fix_tears(&self, TearPatch[] tears)
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
	self.undo_stack.commit();
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

<*
 Fix every tear the last survey found (`fix_tears`), then survey again so the
 card says what is left.

 @return `How many vertices changed.`
*>
fn usz AppState.fix_found_tears(&self)
{
	if (!self.tears_current() || self.tears.len == 0)
	{
		self.@notice("find tears first");
		return 0;
	}
	usz found = self.tears.len;
	usz fixed = self.fix_tears(self.tears);
	usz left = self.find_tears();
	if (fixed == 0)
	{
		self.@notice("nothing to change");
	}
	else if (left == 0)
	{
		self.@notice("closed %d %s (%d vertices)", found, found == 1 ? "tear" : "tears", fixed);
	}
	else
	{
		self.@notice("closed %d vertices · %d %s left", fixed, left, left == 1 ? "tear" : "tears");
	}
	return fixed;
}

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

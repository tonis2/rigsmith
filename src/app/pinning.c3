<*
 The pin layer as an operation, and the lasso that draws one.

 `core/document.c3` holds one pin and the primitive that sets it; this is the
 layer above, where a region of the mesh becomes one undoable gesture and the
 views are told to catch up.

 **The one hand-edit layer.** The lasso, the brush, the Area tool's Apply, Grow,
 the stray fixer and MCP all write one joint's column (`replace_column`), which
 holds the joint (`Dot.held`): from then on its weights are what was written and
 nothing the rig does around it changes them. No edit touches another joint's
 column — see the section on one joint's column below.

 **Everything here is bulk.** `set_pin` and `pin_of` are scans of the layer, so
 a twenty-thousand-vertex lasso through them is quadratic in the region. The
 commit and the undo replay both build one per-vertex chain index and apply in a
 single pass; nothing in this file, and nothing that will be built on it, may
 call the per-entry primitives in a loop.
*>
module crig;

import rig;


import std::math;
import std::math::vector;

<*
 A per-vertex chain over the pin layer: where to start walking, and what comes
 next.

 The answer to `set_pin` being a scan. `head[v]` is the newest pin on vertex
 `v` or -1, and `next[i]` is the pin before it on the same vertex — a
 singly-linked list per vertex, threaded through one array with no allocation
 per vertex that carries nothing.

 Built once per batch and read once per entry in it, which turns a region-sized
 write from O(region × layer) into O(region + layer). Both arrays index the
 document's pin list directly, so a batch that *appends* has to have said how
 many it might append when the index was built — see `pin_index`.
*>
struct PinIndex @private
{
	int[] head; // one per vertex slot
	int[] next; // one per pin, plus room for the appends a batch may make
}

<*
 How many vertex slots an index over these two has to cover.

 The mesh's own vertex count is not enough: `set_pin` validates against the rig
 and not against a mesh — `core/` has no mesh to validate against — so the layer
 loaded from a session may name vertices past the end of whatever model is open.
 Those entries are dropped at bind time by `pin_columns`, but they are still in
 the list this walks, and an index too short to hold one is a write out of
 bounds rather than a stale pin.
*>
fn usz pin_span(PinList* pins, VertexPin[] batch) @private
{
	usz span = 0;
	foreach (pin : pins.array_view())
	{
		if ((usz)pin.vertex + 1 > span) span = (usz)pin.vertex + 1;
	}
	foreach (entry : batch)
	{
		if ((usz)entry.vertex + 1 > span) span = (usz)entry.vertex + 1;
	}
	return span;
}

<*
 Threads the chain over the layer as it currently stands.

 @param span : `How many vertex slots to cover — pin_span over the same two lists.`
 @param appends : `How many entries the batch may push onto the layer, so their links have somewhere to live.`
*>
fn PinIndex pin_index(Allocator allocator, PinList* pins, usz span, usz appends) @private
{
	sz held = pins.len();
	PinIndex index = {
		.head = alloc::new_array(allocator, int, (sz)span),
		.next = alloc::new_array(allocator, int, held + (sz)appends),
	};

	index.head[:span] = -1;

	VertexPin[] held_pins = pins.array_view();
	for (sz i = 0; i < held; i++)
	{
		uint vertex = held_pins[i].vertex;
		index.next[i] = index.head[vertex];
		index.head[vertex] = (int)i;
	}
	return index;
}

fn void PinIndex.free(&self, Allocator allocator)
{
	if (self.head.len > 0) alloc::free(allocator, self.head);
	if (self.next.len > 0) alloc::free(allocator, self.next);
	*self = {};
}

<*
 Writes a batch of pins onto the document in one pass, and says what moved.

 The engine under `pin_dabs` and under the undo replay, which want the same
 write and disagree only about the ledger: a commit records both sides of every
 change, a replay is *made* of them and records nothing.

 Removals are marked rather than spliced out as they are found, and swept in one
 stable compaction at the end. Removing in place would be O(layer) per removal —
 a lasso that unpins twenty thousand vertices is exactly the case — and it would
 also invalidate the index mid-walk, since every entry after the hole shifts
 down by one.

 An entry naming a dot the rig no longer has is skipped, the `set_pin` rule, and
 the check is remembered between entries because a batch is usually one dot's.

 @param batch : `What to set, borrowed for the call. A share of 0 removes.`
 @param changes : `Filled with both sides of each change; pass an empty slice to record nothing.`
 @require changes.len == 0 || changes.len >= batch.len : `Every entry may turn out to be a change, and a short buffer would lose the last of them.`
 @return `How many entries actually moved.`
*>
fn usz AppState.write_pins(&self, VertexPin[] batch, PaintChange[] changes)
{
	if (batch.len == 0) return 0;

	usz span = pin_span(&self.doc.pins, batch);
	if (span == 0) return 0;

	PinIndex index = pin_index(mem, &self.doc.pins, span, batch.len);
	defer index.free(mem);

	// One flag per entry the layer can hold by the end of this call, which is what
	// it holds now plus one per entry of the batch.
	bool[] buried = alloc::new_array(mem, bool, self.doc.pins.len() + (sz)batch.len);
	defer alloc::free(mem, buried);

	usz changed = 0;
	usz removals = 0;

	uint asked = 0;
	bool asked_lives = false;

	foreach (entry : batch)
	{
		if (entry.dot_id == 0) continue;
		if (entry.dot_id != asked)
		{
			asked = entry.dot_id;
			asked_lives = self.doc.find(entry.dot_id) != null;
		}
		if (!asked_lives) continue;

		float want = entry.share;
		want = math::clamp(want, 0.0f, 1.0f);

		sz at = -1;
		for (int walk = index.head[entry.vertex]; walk >= 0; walk = index.next[walk])
		{
			if (self.doc.pins[(sz)walk].dot_id != entry.dot_id) continue;
			at = (sz)walk;
			break;
		}

		// A buried entry reads as absent, so a batch that removes a pin and then
		// puts one back on the same vertex leaves one live entry rather than two.
		bool live = at >= 0 && !buried[at];
		float before = live ? self.doc.pins[at].share : 0.0f;
		if (before == want) continue;

		if (want == 0.0f)
		{
			// `before != want` with a want of zero means there is a live entry.
			buried[at] = true;
			removals++;
		}
		else if (at >= 0)
		{
			if (buried[at])
			{
				buried[at] = false;
				removals--;
			}
			self.doc.pins.get_ref(at).share = want;
		}
		else
		{
			sz slot = self.doc.pins.len();
			self.doc.pins.push({ .vertex = entry.vertex, .dot_id = entry.dot_id, .share = want });
			index.next[slot] = index.head[entry.vertex];
			index.head[entry.vertex] = (int)slot;
		}

		if (changes.len > 0)
		{
			changes[changed] = {
				.vertex = entry.vertex,
				.dot_id = entry.dot_id,
				.before = before,
				.after = want,
			};
		}
		changed++;
	}

	if (removals > 0)
	{
		sz total = self.doc.pins.len();
		sz kept = 0;
		for (sz i = 0; i < total; i++)
		{
			if (buried[i]) continue;
			if (kept != i) *self.doc.pins.get_ref(kept) = self.doc.pins[i];
			kept++;
		}
		while (self.doc.pins.len() > kept) self.doc.pins.pop()!!;
	}

	return changed;
}

<*
 Lay a set of pins onto the document as one undoable gesture.

 	`usz changed = app.pin_dabs(batch);`

 One undo step however many vertices were caught, because a region is one action
 to the person who drew it. The previous share of each is read here rather than
 being asked of the caller — a lasso knows where it went and what it wants, not
 what was already there.

 Entries that change nothing are dropped rather than recorded, and a batch where
 *every* entry is like that records nothing at all and returns 0 — the
 stroke rule, and what makes a second lasso over the same region cost
 nothing on the ledger.

 Marks the *paint* stale rather than the rig. A pin changes no dot, so the base
 bind underneath is still the one that was there, and marking the rig stale would
 both throw away a cache nothing invalidated and free an array `paint_share` may
 be holding — see `base_bind_for`.

 @param batch : `What to set, borrowed for the call. A share of 0 clears a pin.`
 @return `How many actually changed.`
*>
fn usz AppState.pin_dabs(&self, VertexPin[] batch, bool commit = true)
{
	if (batch.len == 0) return 0;

	PaintChange[] changes = alloc::new_array(mem, PaintChange, (sz)batch.len);
	defer alloc::free(mem, changes);

	usz changed = self.write_pins(batch, changes);
	if (changed == 0) return 0;

	self.undo_stack.record_pin_stroke(changes[:changed]);
	// A brush stroke leaves the group open and closes it on release, so the whole
	// press-to-release is one undo step however many moves it took.
	if (commit) self.undo_stack.commit();
	self.mark_paint_stale();
	// Under a parked clip or a pose draft nothing else rebinds the skin, so the
	// posed body would keep the old weights until the playhead moved — the same
	// door a brush stroke takes.
	if (self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 The strongest few shares of a row, renormalised to one.

 `SKIN_INFLUENCES` of them, the width the file keeps anyway. `keep` goes in first
 whatever its size, so a joint being raised from almost nothing is not dropped
 by the cut before it has anything.

 @param row : `One weight per joint, any scale.`
 @param keep : `A joint index to always keep while it carries anything, or -1.`
 @return `How many were written to out_dots and out_shares.`
*>
fn usz top_row(float[] row, uint[] dot_ids, sz keep, uint[] out_dots, float[] out_shares)
{
	usz room = math::min((usz)out_dots.len, (usz)SKIN_INFLUENCES);
	usz held = 0;
	if (keep >= 0 && row[(usz)keep] > 0.0f && room > 0)
	{
		out_dots[0] = dot_ids[(usz)keep];
		out_shares[0] = row[(usz)keep];
		held = 1;
	}
	usz floor = held;
	foreach (b, weight : row)
	{
		if (weight <= 0.0f || (sz)b == keep) continue;
		if (held < room)
		{
			out_dots[held] = dot_ids[b];
			out_shares[held] = weight;
			held++;
			continue;
		}
		usz weakest = floor;
		for (usz i = floor + 1; i < held; i++)
		{
			if (out_shares[i] < out_shares[weakest]) weakest = i;
		}
		if (weakest >= held || weight <= out_shares[weakest]) continue;
		out_dots[weakest] = dot_ids[b];
		out_shares[weakest] = weight;
	}

	float sum = 0.0f;
	for (usz i = 0; i < held; i++) sum += out_shares[i];
	if (sum <= 0.0f) return 0;
	for (usz i = 0; i < held; i++) out_shares[i] /= sum;
	return held;
}

// ---------------------------------------------------------------------------
// One joint's column
//
// Every hand edit is an edit to one joint's column and to nothing else. The
// first one holds the joint (`Dot.held`), starting from the column it had on
// screen, so nothing jumps; from then on its weights are what was written, and
// no edit to another joint, no dot moved and no rebind changes them. Nothing
// here rescales a neighbour to make room, and nothing hands a vertex a joint was
// taken off to anybody — a vertex left holding nothing is unused, and the Unused
// overlay shows it.

// Whether a joint's weights are its own — see `Dot.held`.
fn bool AppState.weights_held(&self, uint dot_id)
{
	Dot* dot = self.doc.find(dot_id);
	return dot && dot.held;
}

// Whether any joint's weights are its own.
fn bool AppState.weights_edited(&self)
{
	foreach (dot : self.doc.dots.array_view()) if (dot.held) return true;
	return false;
}

<*
 What the document stores for a dot, one weight per vertex, held or not: what
 a write to its column is measured against.

 The caller owns the result, which is exactly as long as the mesh.
*>
fn float[] AppState.stored_column(&self, Allocator allocator, uint dot_id)
{
	usz count = self.geometry.positions.len;
	float[] column = alloc::new_array(allocator, float, (sz)count);
	foreach (pin : self.doc.pins.array_view())
	{
		if (pin.dot_id == dot_id && (usz)pin.vertex < count) column[pin.vertex] = pin.share;
	}
	return column;
}

<*
 One joint's weight on every vertex, as the views show it: what it stores when
 held, the binder's column when not.

 	`float[] knee_weights = app.column_of(mem, &view, knee);`

 Read from the document as it is now rather than from `view.pins`, so a caller
 that has just held the joint reads the column it now has.

 The caller owns the result; empty when the dot is not in the view or there is
 no bind.
*>
fn float[] AppState.column_of(&self, Allocator allocator, RigView* view, uint dot_id)
{
	usz count = self.geometry.positions.len;
	usz bones = view.len();
	sz joint = view.joint_of(dot_id);
	if (joint < 0 || count == 0) return {};
	if (self.weights_held(dot_id)) return self.stored_column(allocator, dot_id);

	float[] base = self.base_bind_for(view);
	if (base.len < count * bones) return {};
	float[] column = alloc::new_array(allocator, float, (sz)count);
	for (usz v = 0; v < count; v++) column[v] = base[v * bones + (usz)joint];
	return column;
}

<*
 Write one joint's whole column, holding the joint if it was not: the one
 primitive every hand edit ends in.

 	`usz moved = app.replace_column(&view, knee, column);`

 Diffed against what is on screen, so a column that says what the joint
 already shows writes nothing and holds nothing — an Apply repeated, a lasso
 over vertices already full. Otherwise one stroke on the ledger, after the
 hold, so Ctrl+Z puts the joint back exactly as it was, automatic included.

 No other column is read or written: a vertex taken off this joint keeps
 whatever the others hold of it, and holds nothing if they hold nothing.

 The view's `held` and `pins` are stale afterwards; reopen the rig to read the
 weights again.

 @param column : `One weight per vertex, 0 to 1; clamped.`
 @param commit : `Close the undo group — false for a stroke still in flight, or a twin to follow.`
 @return `How many vertices changed; 0 when the column was already the joint's.`
*>
fn usz AppState.replace_column(&self, RigView* view, uint dot_id, float[] column, bool commit = true)
{
	usz count = self.geometry.positions.len;
	if (column.len != count || !self.doc.find(dot_id)) return 0;
	// An edge drag still waiting on its debounce lands first, so it cannot land
	// later over this.
	self.flush_edges();
	float[] shown = self.column_of(mem, view, dot_id);
	defer if (shown.len > 0) alloc::free(mem, shown);
	if (shown.len != count) return 0;

	usz moved = 0;
	foreach (v, &weight : column)
	{
		*weight = math::clamp(*weight, 0.0f, 1.0f);
		if (*weight != shown[v]) moved++;
	}
	if (moved == 0) return 0;
	self.store_column(dot_id, column, commit);
	return moved;
}

<*
 Hold a joint with exactly this column stored, whatever is on screen: the half
 of `replace_column` after its diff, and what adopting the file's weights uses,
 where a column the binder happens to agree with must still be held.

 @param column : `One weight per vertex, already 0 to 1.`
 @return `Whether anything changed: the flag, or a stored weight.`
*>
fn bool AppState.store_column(&self, uint dot_id, float[] column, bool commit = true)
{
	float[] stored = self.stored_column(mem, dot_id);
	defer alloc::free(mem, stored);
	if (stored.len != column.len) return false;
	bool held_now = self.set_held_recorded(dot_id, true);

	usz differs = 0;
	foreach (v, weight : column) if (weight != stored[v]) differs++;
	VertexPin[] batch = alloc::new_array(mem, VertexPin, (sz)differs);
	defer alloc::free(mem, batch);
	usz at = 0;
	foreach (v, weight : column)
	{
		if (weight != stored[v]) batch[at++] = { .vertex = (uint)v, .dot_id = dot_id, .share = weight };
	}
	if (self.pin_dabs(batch[:at], commit) > 0) return true;
	if (!held_now) return false;
	// Holding alone changed what is on screen: the stored column was already
	// this one, left from before the joint was let go.
	if (commit) self.undo_stack.commit();
	self.mark_paint_stale();
	if (self.skinned()) self.refresh_pose_display();
	return true;
}

<*
 Set a joint's weight on some vertices and leave everything else as it is: the
 lasso's verb, and `pin_weights`'.

 	`usz did = app.set_weight_vertices(caught, app.selected, 1.0f);`

 One joint's column, so drawing around vertices another joint holds gives this
 one its weight there beside the other's — the two blend — and a weight of 0
 takes this joint off and leaves the vertex to whoever else holds it.

 @param vertices : `Which vertices. Out-of-range entries and repeats are skipped.`
 @param weight : `0 to 1.`
 @param commit : `Close the undo group.`
 @return `How many vertices changed.`
*>
fn usz AppState.set_weight_vertices(&self, uint[] vertices, uint dot_id, float weight, bool commit = true)
{
	if (vertices.len == 0 || !self.doc.find(dot_id)) return 0;
	self.flush_edges();
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0;
	RigView view = opened;
	defer view.free(mem);

	float[] column = self.column_of(mem, &view, dot_id);
	defer if (column.len > 0) alloc::free(mem, column);
	if (column.len == 0) return 0;
	foreach (v : vertices) if ((usz)v < column.len) column[v] = weight;
	return self.replace_column(&view, dot_id, column, commit);
}

<*
 Let go of a joint's weights: no grow, the model's soft edge, nothing stored,
 and the joint follows the automatic weights again — Reset. Leaves the group
 open for the caller.

 @return `Whether anything changed.`
*>
fn bool AppState.release_recorded(&self, uint dot_id)
{
	self.flush_edges();
	Dot* dot = self.doc.find(dot_id);
	if (!dot) return false;
	bool changed = self.set_grow_recorded(dot_id, 0.0f);
	if (self.set_band_recorded(dot_id, 0.0f)) changed = true;

	usz stored = 0;
	foreach (pin : self.doc.pins.array_view()) if (pin.dot_id == dot_id) stored++;
	if (stored > 0)
	{
		VertexPin[] batch = alloc::new_array(mem, VertexPin, (sz)stored);
		defer alloc::free(mem, batch);
		usz at = 0;
		foreach (pin : self.doc.pins.array_view())
		{
			if (pin.dot_id == dot_id) batch[at++] = { .vertex = pin.vertex, .dot_id = dot_id, .share = 0.0f };
		}
		if (self.pin_dabs(batch[:at], commit: false) > 0) changed = true;
	}
	if (self.set_held_recorded(dot_id, false)) changed = true;
	if (changed) self.mark_paint_stale();
	if (changed && self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 Let go of every joint's weights, as one undoable step: the whole rig back on
 the automatic weights.

 @return `How many joints were let go.`
*>
fn usz AppState.release_all_recorded(&self)
{
	usz count = (usz)self.doc.dots.len();
	if (count == 0) return 0;
	uint[] ids = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, ids);
	foreach (i, dot : self.doc.dots.array_view()) ids[i] = dot.id;
	usz released = 0;
	foreach (id : ids) if (self.release_recorded(id)) released++;
	if (released > 0) self.undo_stack.commit();
	return released;
}

<*
 The lasso's region across the plane, set on the selected joint's twin while
 Mirror is on: the one Mirror every weight tool reads. Leaves the group open
 for the caller, so the region and its mirror are one undo step.

 @return `How many vertices changed on the twin's side.`
*>
fn usz AppState.lasso_mirror(&self, uint[] caught, float weight)
{
	uint twin = self.area_mirrors() ? self.mirror_twin(self.selected) : 0;
	if (twin == 0 || caught.len == 0) return 0;
	rig::MirrorLookup across = self.mesh_mirror(mem);
	defer across.free(mem);
	uint[] partners = self.mirrored_vertices(mem, &across, caught);
	defer alloc::free(mem, partners);
	usz count = self.geometry.positions.len;
	usz kept = 0;
	foreach (partner : partners) if ((usz)partner < count) partners[kept++] = partner;
	return self.set_weight_vertices(partners[:kept], twin, weight, commit: false);
}

// ---------------------------------------------------------------------------
// Cleaning up: harden and smooth
//
// Two verbs over the whole mesh rather than two more things to draw with: both
// compute whole rows and write them a joint's column at a time
// (`write_columns`), so every joint they touch is held. The only tools that
// write more than one joint, because what they state is a row.
//
// Both read the weights as the user currently sees them, so running either
// twice is running it on its own output, and that is the intended way to use
// them.

<*
 How much of a vertex one dot has to hold before Harden calls it rigid.

 Four fifths is already effectively rigid: the other joints between them move
 that vertex by a fifth of whatever they do, which on a hinge is a rounding of
 the silhouette rather than a bend. What hardening buys is the fifth going away
 — the vertex stops being dragged a little by a limb it has nothing to do with,
 and the file writes it as one influence instead of four.

 Lower would start flattening genuine blends, which is the other op's job and
 not this one's. Higher would leave the near-rigid vertices this exists to
 collect.
*>
const float HARDEN_SHARE = 0.8;

<*
 How many Laplacian iterations Smooth boundaries runs.

 Three is visible without erasing the band. One pass moves a boundary vertex
 halfway to its neighbours' mean and is hard to see; enough of them and the two
 sides meet in the middle everywhere, which is the mush the whole feature exists
 to remove. Three widens a hard step into a readable ramp and leaves the sides
 where they were.

 It is also a *per run* number rather than the total: the op is idempotent in the
 sense that matters — running it again smooths further from where it left off —
 so a user who wants more asks again and can stop when it looks right.
*>
const usz SMOOTH_PASSES = 3;

<*
 Whether there is a bind for the cleanup ops to work on, and the reason there is
 not.

 One refusal shared by both, since both want the same three things and refuse on
 them identically. The rest-mesh clause is the lasso's, for the lasso's reason:
 these read the bind, and the bind is against the rest mesh — an op run over a
 pose would bake shares nobody was looking at.

 @return `True when the caller may go on. Says why on the result line otherwise.`
*>
fn bool AppState.weights_ready(&self)
{
	if (!self.has_mesh())
	{
		self.@notice("open a model first — there are no weights to clean up");
		return false;
	}
	if (self.doc.dots.len() == 0)
	{
		self.@notice("place some joints first — there are no weights to clean up");
		return false;
	}
	if (self.rig_locked())
	{
		self.@notice("weight cleanup works on the rest mesh — finish animation editing first");
		return false;
	}
	return true;
}

<*
 Hand every nearly-rigid vertex outright to the dot that already holds it.

 	`usz did = app.harden_weights();`

 The whole mesh at once, which is why it is a menu item rather than a brush: the
 vertices this is about are scattered — the middle of a forearm, the crown of a
 head, everything far enough from a joint that one bone was always going to win
 it — and picking them out by hand is work with no judgement in it.

 A vertex qualifies when one joint holds at least `HARDEN_SHARE` of it *and* the
 row has more than one joint in it. The second half is what keeps the op from
 recording anything on a rig that is already the way it wants: a vertex pinned
 rigid by a lasso, and a piece the binder froze onto a bone, both arrive here as
 a single-influence row and are left alone.

 **The result is held, so it is baked** — every joint it touches keeps the
 column it was given (`Dot.held`). Move a dot afterwards and the hardened
 vertices stay where they were told, which is the point of hardening and the
 price of it. One Ctrl+Z takes the whole pass back.

 @return `How many vertices were hardened; 0 when there was nothing to do.`
*>
fn usz AppState.harden_weights(&self)
{
	if (!self.weights_ready()) return 0;
	self.flush_edges();

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("nothing to make rigid — this model has no rig on it");
		return 0;
	}
	RigView view = opened;
	defer view.free(mem);

	usz bones = view.len();

	// The bind as the screen has it: base, sharpness, corrections and the pins
	// already stated. An owned copy — `base_bind_for` hands out the cache itself,
	// and this is about to write pins that mark it stale.
	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);

	if (bones == 0 || painted.len == 0)
	{
		self.@notice("nothing to make rigid — this mesh is not bound to this rig");
		return 0;
	}

	usz count = self.geometry.positions.len;

	// The dot each vertex is to be handed to, or 0 for one this leaves alone.
	// A flag per vertex rather than a list, because the rival sweep below asks
	// the question the other way round — of a pin, whether its vertex is in.
	uint[] pick = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, pick);

	usz singles = 0;
	for (usz v = 0; v < count; v++)
	{
		usz base = v * bones;

		float sum;
		usz held;
		sz best = row_owner(painted[base:bones], &sum, &held);

		// One joint is already what this would write; none has no dominant to
		// measure, and a row of zeros is a vertex nothing reaches — which is the
		// unclaimed count's problem, not this one's.
		if (held < 2) continue;
		if (painted[base + (usz)best] / sum < HARDEN_SHARE) continue;

		pick[v] = view.dot_ids[(usz)best];
		singles++;
	}

	if (singles == 0)
	{
		self.@notice("nothing to make rigid — no vertex is close enough to rigid already");
		return 0;
	}

	// The owner to one and every other joint off, which is the one place a
	// tool writes more than the joint it was asked about: making a vertex rigid
	// is a statement about the whole row. Each joint touched is held.
	float[] rows_after = alloc::new_array(mem, float, (sz)painted.len);
	defer alloc::free(mem, rows_after);
	rows_after[..] = painted[..];
	for (usz v = 0; v < count; v++)
	{
		if (pick[v] == 0) continue;
		usz base = v * bones;
		for (usz b = 0; b < bones; b++) rows_after[base + b] = view.dot_ids[b] == pick[v] ? 1.0f : 0.0f;
	}

	usz joints = self.write_columns(&view, painted, rows_after);
	if (joints == 0)
	{
		self.@notice("nothing to make rigid — every vertex already says what this would");
		return 0;
	}

	self.@notice("made %d vertices rigid · %d %s now keep their weights as written", singles, joints,
		joints == 1 ? "joint" : "joints");
	return singles;
}

<*
 Write every column `next` differs from `painted` in, as one undo step: the
 whole-model cleanups' way of stating many rows at once, a joint at a time.
 Every joint written is held.

 @param painted : `The weights as shown — AppState.weights of the same view.`
 @param rewritten : `The same shape, with the rows to change rewritten.`
 @return `How many joints were written; the group is committed when any were.`
*>
fn usz AppState.write_columns(&self, RigView* view, float[] painted, float[] rewritten)
{
	usz count = self.geometry.positions.len;
	usz bones = view.len();
	if (painted.len != count * bones || rewritten.len != painted.len) return 0;
	float[] column = alloc::new_array(mem, float, (sz)count);
	defer alloc::free(mem, column);
	usz joints = 0;
	for (usz b = 0; b < bones; b++)
	{
		bool differs = false;
		for (usz v = 0; v < count; v++)
		{
			column[v] = rewritten[v * bones + b];
			if (column[v] != painted[v * bones + b]) differs = true;
		}
		if (differs && self.replace_column(view, view.dot_ids[b], column, commit: false) > 0) joints++;
	}
	if (joints > 0) self.undo_stack.commit();
	return joints;
}

<*
 Soften the seams where two dots meet, and write the result down.

 	`usz did = app.smooth_boundaries();`

 The band is found rather than drawn: a point whose strongest joint differs from
 some neighbour's is on a boundary, and one ring out from those is how wide a
 transition has room to be. `SMOOTH_PASSES` Laplacian iterations then run over
 that band and nothing else — each pass replaces a band point's shares with the
 mean of its neighbours', and a neighbour outside the band contributes the shares
 it already had and does not move. That is what anchors the two sides: without
 fixed edges the whole mesh would drift towards one flat average.

 Neighbourhoods come from `AppState.adjacency_for`, which welds coincident
 positions first — so a UV seam running down the middle of a shoulder smooths
 across rather than leaving a ridge along it. The pass is over welds for the same
 reason: every copy of a split point gets one answer, by construction.

 **This bakes the band.** Every joint it touches is held, so it no longer
 tracks the rig — move a dot afterwards and the smoothed vertices say what they
 were told. That is the trade the op is: a
 computed blend that drifted with every rebind would be a different answer every
 time, and nothing would be gained by computing it. Running it again smooths
 further, from where the last run left off; one Ctrl+Z takes a whole pass back.

 @return `How many vertices were rewritten; 0 when no two dots meet on this mesh.`
*>
fn usz AppState.smooth_boundaries(&self)
{
	if (!self.weights_ready()) return 0;
	self.flush_edges();

	rig::MeshAdjacency* around = self.adjacency_for();
	if (!around.usable())
	{
		self.@notice("nothing to smooth — this mesh has no triangles to follow");
		return 0;
	}

	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		self.@notice("nothing to smooth — this model has no rig on it");
		return 0;
	}
	RigView view = opened;
	defer view.free(mem);

	usz bones = view.len();
	float[] painted = self.weights(mem, &view);
	defer if (painted.len > 0) alloc::free(mem, painted);

	if (bones == 0 || painted.len == 0)
	{
		self.@notice("nothing to smooth — this mesh is not bound to this rig");
		return 0;
	}

	usz count = self.geometry.positions.len;
	usz groups = around.classes();
	usz influences = (usz)SKIN_INFLUENCES;

	// Shares per weld, the mean over the vertices welded into it. Each row is
	// normalised before it is added rather than after the sum, because the binder
	// hands back scores spanning orders of magnitude — a plain sum would let the
	// loudest copy of a seam point speak for the rest.
	float[] rows = alloc::new_array(mem, float, (sz)(groups * bones));
	defer alloc::free(mem, rows);

	usz[] members = alloc::new_array(mem, usz, (sz)groups);
	defer alloc::free(mem, members);

	for (usz v = 0; v < count; v++)
	{
		usz base = v * bones;
		float sum = 0.0f;
		for (usz b = 0; b < bones; b++) sum += painted[base + b];
		if (sum <= 0.0f) continue;

		usz group = (usz)around.class_of[v];
		usz into = group * bones;
		for (usz b = 0; b < bones; b++) rows[into + b] += painted[base + b] / sum;
		members[group]++;
	}
	for (usz g = 0; g < groups; g++)
	{
		if (members[g] < 2) continue;
		usz into = g * bones;
		float scale = 1.0f / (float)members[g];
		for (usz b = 0; b < bones; b++) rows[into + b] *= scale;
	}

	// Whose joint each weld belongs to, or -1 for one nothing reaches — which is
	// not on a boundary between two dots however close it sits to one.
	int[] top = alloc::new_array(mem, int, (sz)groups);
	defer alloc::free(mem, top);
	for (usz g = 0; g < groups; g++)
	{
		top[g] = (int)row_owner(rows[g * bones:bones]);
	}

	bool[] band = alloc::new_array(mem, bool, (sz)groups);
	defer alloc::free(mem, band);
	for (usz g = 0; g < groups; g++)
	{
		if (top[g] < 0) continue;
		foreach (n : around.around(g))
		{
			if (top[n] < 0 || top[n] == top[g]) continue;
			band[g] = true;
			break;
		}
	}

	// One ring out, so the ramp has somewhere to land: the seam itself is two
	// points wide, and a blend written across two points is still a step.
	bool[] wide = alloc::new_array(mem, bool, (sz)groups);
	defer alloc::free(mem, wide);
	for (usz g = 0; g < groups; g++)
	{
		if (!band[g]) continue;
		wide[g] = true;
		foreach (n : around.around(g)) wide[n] = true;
	}

	// Where each band weld's row lives in the double buffer, -1 for one that is
	// not in the band at all. The buffer holds the band and nothing else: the
	// mesh outside it does not move, and a copy of the whole matrix per pass
	// would be the expensive half of the op.
	sz[] slot = alloc::new_array(mem, sz, (sz)groups);
	defer alloc::free(mem, slot);

	usz banded = 0;
	for (usz g = 0; g < groups; g++)
	{
		slot[g] = -1;
		if (!wide[g] || top[g] < 0) continue;
		slot[g] = (sz)banded++;
	}

	if (banded == 0)
	{
		self.@notice("nothing to smooth — no two joints meet anywhere on this mesh");
		return 0;
	}

	float[] next = alloc::new_array(mem, float, (sz)(banded * bones));
	defer alloc::free(mem, next);

	for (usz pass = 0; pass < SMOOTH_PASSES; pass++)
	{
		for (usz g = 0; g < groups; g++)
		{
			sz into = slot[g];
			if (into < 0) continue;

			uint[] ring = around.around(g);
			usz base = (usz)into * bones;

			// A weld with no neighbours cannot be on a boundary, so this is only
			// reachable through the dilation; it keeps what it had.
			if (ring.len == 0)
			{
				for (usz b = 0; b < bones; b++) next[base + b] = rows[g * bones + b];
				continue;
			}

			for (usz b = 0; b < bones; b++) next[base + b] = 0.0f;
			foreach (n : ring)
			{
				usz from = (usz)n * bones;
				for (usz b = 0; b < bones; b++) next[base + b] += rows[from + b];
			}
			float scale = 1.0f / (float)ring.len;
			for (usz b = 0; b < bones; b++) next[base + b] *= scale;
		}

		// Written back only now, so every row in a pass read the same generation.
		// In place would let a weld already visited feed the one beside it, which
		// makes the result depend on the order the welds happen to be numbered in.
		for (usz g = 0; g < groups; g++)
		{
			sz into = slot[g];
			if (into < 0) continue;
			usz base = (usz)into * bones;
			usz onto = g * bones;
			for (usz b = 0; b < bones; b++) rows[onto + b] = next[base + b];
		}
	}

	// The strongest few per band weld, renormalised. Four because that is what a
	// glTF row holds — see `SKIN_INFLUENCES` — so keeping more here would be
	// stating shares the export is about to drop, and a preview that disagreed
	// with the file is the defect that constant exists to prevent.
	uint[] dots = alloc::new_array(mem, uint, (sz)(banded * influences));
	defer alloc::free(mem, dots);
	float[] shares = alloc::new_array(mem, float, (sz)(banded * influences));
	defer alloc::free(mem, shares);
	usz[] kept = alloc::new_array(mem, usz, (sz)banded);
	defer alloc::free(mem, kept);

	for (usz g = 0; g < groups; g++)
	{
		sz into = slot[g];
		if (into < 0) continue;

		usz base = g * bones;
		usz at = (usz)into * influences;
		usz held = 0;

		for (usz b = 0; b < bones; b++)
		{
			float share = rows[base + b];
			if (share <= 0.0f) continue;

			if (held < influences)
			{
				dots[at + held] = view.dot_ids[b];
				shares[at + held] = share;
				held++;
				continue;
			}

			usz weakest = 0;
			for (usz i = 1; i < influences; i++)
			{
				if (shares[at + i] < shares[at + weakest]) weakest = i;
			}
			if (share <= shares[at + weakest]) continue;
			dots[at + weakest] = view.dot_ids[b];
			shares[at + weakest] = share;
		}

		// To one, so the stored numbers are honest about what the vertex will do.
		// `pin_over` would scale a group that overpromised anyway, but then the
		// session would hold shares nothing ever meant.
		float sum = 0.0f;
		for (usz i = 0; i < held; i++) sum += shares[at + i];
		if (sum > 0.0f)
		{
			for (usz i = 0; i < held; i++) shares[at + i] /= sum;
		}
		kept[into] = held;
	}

	// Each band vertex's row becomes its weld's kept shares, every joint left
	// out of them off it — a statement about the whole row, like Make rigid's,
	// and every joint it touches is held.
	float[] rows_after = alloc::new_array(mem, float, (sz)painted.len);
	defer alloc::free(mem, rows_after);
	rows_after[..] = painted[..];
	usz touched = 0;
	for (usz v = 0; v < count; v++)
	{
		sz into = slot[(usz)around.class_of[v]];
		if (into < 0) continue;
		touched++;
		usz base = v * bones;
		for (usz b = 0; b < bones; b++) rows_after[base + b] = 0.0f;
		usz from = (usz)into * influences;
		for (usz i = 0; i < kept[into]; i++)
		{
			sz joint = view.joint_of(dots[from + i]);
			if (joint >= 0) rows_after[base + (usz)joint] = shares[from + i];
		}
	}

	usz joints = self.write_columns(&view, painted, rows_after);
	if (joints == 0)
	{
		self.@notice("nothing to smooth — the weights already say what this would");
		return 0;
	}

	self.@notice("smoothed %d boundary vertices · %d %s now keep their weights as written", touched, joints,
		joints == 1 ? "joint" : "joints");
	return touched;
}

// ---------------------------------------------------------------------------
// The lasso

<*
 How far the pointer has to travel before the stroke takes another point.

 A polygon with a vertex per mouse move would be thousands of points long on a
 slow drag and would cost `inside_polygon` — which is O(points) per mesh vertex
 — the whole gesture. A couple of pixels is under what a hand can aim anyway, so
 nothing about the region the user drew is lost.
*>
const float LASSO_STEP = 2.0;

<*
 Open the lasso, on one job or the other (T, or shift+T straight to pinning).

 **PIN** is `pin_shell`'s sibling one level finer: that one hands a whole
 *piece* of the mesh to the selected dot, this hands whichever *vertices* the
 user draws around. The pair is why that half kept the plain letter's shift —
 the coarser half had the letter, then a Shells pane's row, and is the wire's
 alone now that the pane is out.

 It is refused without a selection, since there is nothing to hand the region to,
 and refused while the rig is locked for the reason `begin_brush` gives: the bind
 is against the rest mesh and so is the BVH the visibility test marches, so a
 region drawn over a posed or playing body would catch vertices other than the
 ones under it. Correcting that would be a skinning pass per gather.

 **SELECT** asks for neither. It reads the same projected circles a click reads —
 `Viewport.pick_dot`'s own loop with a polygon in place of a radius — so it means
 what it appears to mean over a posed body, over a playing clip, and with nothing
 selected yet. What it does need is circles to draw around: a hidden rig has
 none, and a document with no dots has none either.

 The other two modes go, and they close this one on the way in — three tools
 that all claim a plain drag over the model, so any two of them open at once is
 one gesture with two meanings. Reopening on the *other* job is not a reopen:
 the outline in flight is dropped either way, since a region half drawn under one
 job says nothing about the other.

 @param job : `Which half opens. The refusals differ; the gesture does not.`
 @return `False when the job's own requirements are not met, which the caller says out loud.`
*>
fn bool AppState.begin_lasso(&self, LassoJob job)
{
	switch (job)
	{
		case PIN:
			// Not refused on a locked rig: the region is gathered against the body on
			// screen (`lasso_vertices`), posed or not, as the brush's circle is.
			if (!self.doc.find(self.selected)) return false;
		case SELECT:
			if (!self.show_rig) return false;
			if (self.doc.dots.len() == 0) return false;
	}

	self.end_brush();
	self.end_area();
	self.end_sketch();

	self.lassoing = true;
	self.lasso_job = job;
	self.lasso_active = false;
	self.drop_lasso_stroke();
	// Pinning edits the selected joint's weights, so it shows them, the way the
	// brush and the Area tool do; selecting joints leaves the view alone.
	self.lasso_tint = self.tint_mode;
	if (job == PIN) self.show_tint(FALLOFF);
	return true;
}

<*
 The lasso's own key, one press further along: closed opens it selecting,
 selecting switches to pinning, pinning switches back.

 A cycle rather than a toggle because the two jobs are one tool. `esc` is still
 the way *out* — the reading it has for every mode in crig — so this key never
 has to mean both "next job" and "close", and the hint bar can name one job's
 successor at a time instead of describing a three-way.

 A refused step leaves the tool exactly where it was rather than closing it: what
 the user asked for was the other job, and answering "no" by taking away the one
 they already had would be answering a different question.

 @return `False when the step was refused — only ever the step onto pinning, and only for the reasons begin_lasso gives.`
*>
fn bool AppState.advance_lasso(&self)
{
	if (!self.lassoing) return self.begin_lasso(SELECT);
	if (self.lasso_job == LassoJob.PIN) return self.begin_lasso(SELECT);
	return self.begin_lasso(PIN);
}

<*
 Close the lasso.

 No ledger work, the same as `end_brush`: a gesture commits on its own release,
 so nothing is outstanding when the mode closes. A gesture still in flight is
 dropped rather than committed — escape mid-drag means the region was drawn
 wrong, and there is no reading of half a polygon.
*>
fn void AppState.end_lasso(&self)
{
	if (!self.lassoing) return;
	bool pinning = self.lasso_job == PIN;
	self.lassoing = false;
	self.lasso_active = false;
	self.drop_lasso_stroke();
	if (pinning && self.tint_mode == FALLOFF) self.show_tint(self.lasso_tint);
}

// Close the lasso and give the Weights card its Area tool back, as `leave_brush`
// does for the brush.
fn void AppState.leave_lasso(&self)
{
	self.end_lasso();
	self.sync_weights_card();
}

// The polygon in flight, forgotten. The buffer's own storage stays, since the
// next gesture wants it back — see `drop_lasso_memory` for the release.
fn void AppState.drop_lasso_stroke(&self)
{
	self.lasso_points.clear();
}

// Releases the point buffer. Safe on one that was never used.
fn void AppState.drop_lasso_memory(&self)
{
	self.lasso_points.free();
	self.lasso_points = {};
}

<*
 Adds a point to the stroke in flight, if the pointer has gone far enough.

 	`if (app.lasso_moved(at)) elem.request_paint();`

 @return `True when the point was taken, so the caller knows there is something new to draw.`
*>
fn bool AppState.lasso_moved(&self, Vec2 at)
{
	sz held = self.lasso_points.len();
	if (held > 0 && (self.lasso_points[held - 1] - at).length() < LASSO_STEP) return false;

	// A zeroed List grows from tmem, and `drop_lasso_memory` leaves it zeroed, so
	// each stroke's first point gives it `mem`.
	if (!self.lasso_points.is_initialized()) self.lasso_points.init(mem);
	self.lasso_points.push(at);
	return true;
}

<*
 Whether a point is inside a polygon: the even-odd crossing test.

 A ray is cast from the point along +x and the edges it crosses are counted;
 an odd count is inside. Which is what makes the test right for a *freehand*
 region — a hand drawing around a shoulder crosses its own path, and a winding
 rule would then read the overlap as doubly inside where this reads it as
 outside, so the same gesture would pin different vertices depending on how
 tidily it was drawn.

 The half-open comparison on `y` is what keeps a vertex of the polygon from
 being counted twice: an edge counts when the point's `y` is at or above one end
 and below the other, so two edges meeting at a point straddling the ray
 contribute exactly one crossing between them.

 @param points : `The polygon, in order and implicitly closed. Fewer than three is not a region.`
 @return `True when the point is inside.`
*>
fn bool inside_polygon(Vec2[] points, Vec2 p)
{
	if (points.len < 3) return false;

	bool inside = false;
	usz previous = points.len - 1;
	for (usz i = 0; i < points.len; i++)
	{
		Vec2 a = points[i];
		Vec2 b = points[previous];
		previous = i;

		if ((a.y > p.y) == (b.y > p.y)) continue;

		// Where the edge crosses the point's own row. The denominator cannot be
		// zero: the test above is only passed by an edge whose ends straddle `p.y`.
		float crossing = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y);
		if (p.x < crossing) inside = !inside;
	}
	return inside;
}

<*
 The vertices inside a drawn region.

 	`usz n = app.lasso_vertices(caught, vp, size, eye, polygon, xray);`

 `brush_vertices` for a polygon instead of a circle, and ordered by cost for the
 same reason: the projection is a matrix multiply and the visibility test is a
 raycast, so the box around the polygon rejects most of the mesh before either
 one runs, and the crossing test rejects the rest of what the box let through.

 **What can be seen, plus everything joined to it without leaving the outline.**
 Front faces alone is the brush's rule and it is the wrong one for a region: a
 lasso around a leg would take the front of it and leave the back still holding
 whatever bone it had, with nothing on screen to say half the limb had been
 missed. So the visible vertices inside the polygon are *seeds*, and the region
 grows from them along the mesh's own edges — into vertices that are themselves
 inside the polygon, and no further.

 That restriction is the whole of what tells the back of the lassoed leg from the
 far leg standing behind it. The back of the near leg reaches its own front around
 the silhouette without ever stepping outside the loop, so it joins. The far leg
 is either a piece of its own, with no edge into the near one to follow, or it is
 reachable only up through the hip — whose vertices project outside the loop, so
 the walk stops there. Neither answer depends on the model being built out of
 separate pieces, which is why the same rule serves a one-skin body and a pile of
 parts.

 What the default still leaves out is a part with no route to daylight: an eyeball
 inside a head is inside the polygon and joined to nothing visible, so nothing
 seeds it. `xray` is for exactly that — every vertex inside the polygon, no
 visibility test and no walk — and it is a held key rather than a setting so it is
 never on by accident.

 The walk is over weld classes rather than vertices, `AppState.adjacency_for`'s
 own unit: an exporter splits a vertex wherever the normals or the UVs do, and a
 region that stopped at every split would leave holes down the middle of whatever
 was drawn around. Coincident copies share a position, so they share a pixel and a
 verdict by construction, and the visibility raycast is one per class rather than
 one per copy.

 **The body on screen**: each vertex where it is drawn (`shown_position`) and
 the visibility cast against that same body (`mesh_hidden_surface`), so under a
 parked clip or a pose draft the loop catches what it was drawn around, exactly
 as the brush does. The walk is over the mesh's edges, which a pose does not
 change.

 @param out : `Filled with the vertices caught, in mesh order. Must be at least as long as the mesh.`
 @param view_projection : `From OrbitCamera.view_projection, for this viewport's aspect.`
 @param viewport : `Size of the region the camera renders into, in pixels.`
 @param eye : `Camera position in model space, for the visibility test.`
 @param polygon : `The drawn region, in the same pixels project returns.`
 @param xray : `True to take everything inside the region, seen or not, joined or not.`
 @return `How many were caught.`
*>
fn usz AppState.lasso_vertices(&self, uint[] out, Matrix4f view_projection,
	Vec2 viewport, Vec3 eye, Vec2[] polygon, bool xray)
{
	usz count = self.geometry.positions.len;
	if (count == 0 || polygon.len < 3 || out.len < count) return 0;

	Vec2 low = polygon[0];
	Vec2 high = polygon[0];
	foreach (point : polygon)
	{
		if (point.x < low.x) low.x = point.x;
		if (point.y < low.y) low.y = point.y;
		if (point.x > high.x) high.x = point.x;
		if (point.y > high.y) high.y = point.y;
	}

	// Membership first, and for every vertex rather than only the ones that
	// survive the visibility test: what a front-faces pass drops here is precisely
	// what the walk below has to be able to arrive at.
	bool[] within = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, within);

	usz enclosed = 0;
	for (usz v = 0; v < count; v++)
	{
		Vec2? where = project(view_projection, self.shown_position(v), viewport);
		if (catch where) continue;

		if (where.x < low.x || where.x > high.x || where.y < low.y || where.y > high.y) continue;
		if (!inside_polygon(polygon, where)) continue;

		within[v] = true;
		enclosed++;
	}

	// Nothing to cast at, and nothing to walk from. Out before the adjacency is
	// asked for, so a region drawn over the background never pays to build it.
	if (enclosed == 0) return 0;

	usz kept = 0;

	if (xray)
	{
		for (usz v = 0; v < count; v++)
		{
			if (within[v]) out[kept++] = (uint)v;
		}
		return kept;
	}

	rig::MeshAdjacency* around = self.adjacency_for();

	// A mesh with no edges to follow — a point cloud, or one whose triangles this
	// state has somehow not caught up with — has no neighbourhoods to grow
	// through. There is nothing to seed from and nowhere to go, so the region is
	// what can be seen of it, rather than the gesture being refused.
	if (!around.usable() || around.vertices() != count)
	{
		for (usz v = 0; v < count; v++)
		{
			if (!within[v]) continue;
			if (self.mesh_hidden_surface(eye, self.shown_position(v))) continue;
			out[kept++] = (uint)v;
		}
		return kept;
	}

	usz groups = around.classes();

	// `asked` ends the seeding pass meaning "this weld is inside the polygon":
	// every class with a member inside it is reached by the loop below, and
	// membership cannot differ between members — they are the same point, so they
	// are the same pixel.
	bool[] asked = alloc::new_array(mem, bool, (sz)groups);
	defer alloc::free(mem, asked);
	bool[] reached = alloc::new_array(mem, bool, (sz)groups);
	defer alloc::free(mem, reached);

	// A class is queued at most once, so the frontier can never outgrow the mesh
	// and the walk needs no buffer that grows.
	uint[] queue = alloc::new_array(mem, uint, (sz)groups);
	defer alloc::free(mem, queue);

	usz tail = 0;
	for (usz v = 0; v < count; v++)
	{
		if (!within[v]) continue;

		usz group = (usz)around.class_of[v];
		// One cast per weld rather than one per copy: the copies are the same
		// point, so they are the same ray and the same answer.
		if (asked[group]) continue;
		asked[group] = true;

		if (self.mesh_hidden_surface(eye, self.shown_position(v))) continue;
		reached[group] = true;
		queue[tail++] = (uint)group;
	}

	for (usz head = 0; head < tail; head++)
	{
		foreach (n : around.around((usz)queue[head]))
		{
			// The step that keeps the region inside its own outline: a neighbour
			// that projects outside the polygon is where this piece of the model
			// leaves what was drawn around, and nothing past it is in the region.
			if (!asked[n] || reached[n]) continue;
			reached[n] = true;
			queue[tail++] = n;
		}
	}

	for (usz v = 0; v < count; v++)
	{
		if (within[v] && reached[around.class_of[v]]) out[kept++] = (uint)v;
	}
	return kept;
}

<*
 Close the region and hand what it caught to the selected dot.

 	`app.lasso_commit(vp, elem.size, app.camera.eye());`

 The whole gesture is one entry on the ledger, unlike a brush stroke, which
 commits per mouse move: a stroke is a stream the hand is still adding to and a
 region is not finished until it is closed, so there is nothing meaningful to
 commit half way.

 The camera is passed in rather than read off the app because the pixels the
 polygon was drawn in belong to one pane — the viewport knows its own aspect and
 its own size, and two panes see the same camera at two of them. It also leaves
 this callable with no window at all, which is what makes the region arithmetic
 assertable.

 Says what it did either way. A region that caught nothing is the common first
 mistake — drawn over the background, or over the far side of the model — and
 silence there reads as a broken mode.
*>
fn void AppState.lasso_commit(&self, Matrix4f view_projection, Vec2 viewport, Vec3 eye)
{
	bool removing = self.lasso_removes;
	Vec2[] polygon = self.lasso_points.array_view();
	usz count = self.geometry.positions.len;

	Dot* dot = self.doc.find(self.selected);

	if (self.lassoing && dot != null && polygon.len >= 3 && count > 0)
	{
		uint[] caught = alloc::new_array(mem, uint, (sz)count);
		defer alloc::free(mem, caught);

		usz found = self.lasso_vertices(caught, view_projection, viewport, eye, polygon, self.lasso_xray);
		if (found == 0)
		{
			self.@notice("the lasso caught nothing — draw around the model, or hold alt to reach through it");
		}
		else if (!removing)
		{
			self.set_weight_vertices(caught[:found], self.selected, 1.0f, commit: false);
			self.lasso_mirror(caught[:found], 1.0f);
			self.undo_stack.commit();

			// What the region now says, not what changed: drawing over vertices
			// already this dot's writes nothing and has still said the true thing
			// about them, and "0 vertices" would read as a failure.
			String name = dot.name.len > 0 ? dot.name : "that joint";
			self.@notice("%s holds %d vertices fully · other joints keep theirs", name, found);
		}
		else
		{
			// Removal is the other way round: what was taken is the only number
			// there is to report, since the region caught mesh the joint never
			// held as readily as mesh it did.
			usz did = self.set_weight_vertices(caught[:found], self.selected, 0.0f, commit: false);
			did += self.lasso_mirror(caught[:found], 0.0f);
			self.undo_stack.commit();
			String name = dot.name.len > 0 ? dot.name : "that joint";
			if (did > 0)
			{
				self.@notice("took %s off %d vertices", name, did);
			}
			else
			{
				self.@notice("%s holds nothing in that region", name);
			}
		}
	}

	self.lasso_points.clear();
	self.lasso_active = false;
}

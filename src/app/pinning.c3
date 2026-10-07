<*
 The pin layer as an operation, and the lasso that draws one.

 `core/document.c3` holds one pin and the primitive that sets it; this is the
 layer above, where a region of the mesh becomes one undoable gesture and the
 views are told to catch up. The same split `app/painting.c3` describes for the
 other correction layer, and this file is deliberately its mirror — a reader who
 knows one should be able to guess the other.

 **What a pin is, against what a stroke is.** A `PaintDab` multiplies whatever
 the binder currently says, so it cannot lift a weight the binder left at zero:
 no finite multiplier reaches a share from nothing. That is precisely the defect
 a region tool is reached for — "the wrong bone got none of this" — so a lasso
 writes `VertexPin`s, which state the share outright and are written over the
 corrections rather than under them. The price is stated in `VertexPin`: a pin
 is absolute and does not move when the dot does.

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
		float before = at >= 0 && !buried[at] ? self.doc.pins[at].share : 0.0f;
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
 `paint_dabs` rule, and what makes a second lasso over the same region cost
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
	// door `paint_dabs` takes.
	if (self.skinned()) self.refresh_pose_display();
	return changed;
}

<*
 Whole rows to state outright, gathered before any of it is written.

 	`PinDraft draft; draft.init(count); defer draft.free();`
 	`draft.state(v, dots, shares); app.lay_draft(&draft);`

 A claimed vertex says exactly what its row lists and nothing else: every other
 pin already on it is cleared when the draft is laid, which is the `exclusive`
 rule for a row rather than for one dot. An empty row claims the vertex and
 states nothing, handing it back to the automatic weights.
*>
struct PinDraft
{
	int[] first;  // per vertex: where its pins start in `pins`, -1 when untouched
	char[] held;  // per vertex: how many pins its row states
	PinList pins;
}

fn void PinDraft.init(&self, usz count)
{
	self.first = alloc::new_array(mem, int, (sz)count);
	self.first[..] = -1;
	self.held = alloc::new_array(mem, char, (sz)count);
	self.pins.init(mem);
}

fn void PinDraft.free(&self)
{
	if (self.first.len > 0) alloc::free(mem, self.first);
	if (self.held.len > 0) alloc::free(mem, self.held);
	self.pins.free();
	*self = {};
}

fn bool PinDraft.claimed(&self, uint v) => (usz)v < self.first.len && self.first[v] >= 0;

<*
 State one vertex's row. A vertex already claimed keeps its first row.

 @param dots : `The dots the row names.`
 @param shares : `One per dot. A share of 0 or less is left out.`
*>
fn void PinDraft.state(&self, uint v, uint[] dots, float[] shares)
{
	if ((usz)v >= self.first.len || self.claimed(v)) return;
	self.first[v] = (int)self.pins.len();
	foreach (i, dot : dots)
	{
		if (shares[i] <= 0.0f) continue;
		self.pins.push({ .vertex = v, .dot_id = dot, .share = math::min(shares[i], 1.0f) });
		self.held[v]++;
	}
}

<*
 Write a draft onto the pin layer: its rows, and a clear for every other pin on
 a claimed vertex.

 @param commit : `False leaves the undo group open, for a stroke that closes it on release.`
 @return `How many entries changed.`
*>
fn usz AppState.lay_draft(&self, PinDraft* draft, bool commit = true)
{
	usz rivals = 0;
	foreach (pin : self.doc.pins.array_view())
	{
		if (draft.claimed(pin.vertex) && !draft.restates(pin)) rivals++;
	}

	sz stated = draft.pins.len();
	if (stated == 0 && rivals == 0) return 0;

	VertexPin[] batch = alloc::new_array(mem, VertexPin, stated + (sz)rivals);
	defer alloc::free(mem, batch);

	usz at = 0;
	foreach (pin : draft.pins.array_view()) batch[at++] = pin;
	foreach (pin : self.doc.pins.array_view())
	{
		if (!draft.claimed(pin.vertex) || draft.restates(pin)) continue;
		batch[at++] = { .vertex = pin.vertex, .dot_id = pin.dot_id, .share = 0.0f };
	}
	return self.pin_dabs(batch[:at], commit);
}

// Whether the draft's row for this pin's vertex names the pin's dot.
fn bool PinDraft.restates(&self, VertexPin pin)
{
	usz from = (usz)self.first[pin.vertex];
	for (usz i = from; i < from + (usz)self.held[pin.vertex]; i++)
	{
		if (self.pins[(sz)i].dot_id == pin.dot_id) return true;
	}
	return false;
}

<*
 The strongest few shares of a row, renormalised to one: what a stated row keeps.

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

<*
 Hand a set of vertices to a dot, and take them off every other dot.

 	`usz did = app.pin_vertices(caught, app.selected, 1.0f);`

 The verb the lasso and `pin_weights` both speak, and the one place the batch a
 region implies is assembled. What `exclusive` adds is the second half of what
 "these belong to this dot" means: without it, pinning a region that was already
 pinned elsewhere would leave two dots each stating a share of it, and
 `pin_over` would divide the vertex between them rather than hand it over.

 **A share of 0 clears**, and with `exclusive` it clears the region outright —
 every dot's pins on those vertices, not only the named one's. That is the
 ctrl-lasso, and it is why the eraser needs no separate entry point. A dot id of
 0 says the same thing without naming any dot at all; with any other share it is
 refused, since a pin has to name what it hands the vertex to.

 One `pin_dabs`, so the whole region is one Ctrl+Z.

 @param vertices : `Which vertices. Repeats are one pin, not two.`
 @param dot_id : `The dot they should ride. 0 is only meaningful with a share of 0, where it means every dot.`
 @param share : `0 to 1. 0 removes.`
 @param exclusive : `Also clear every other dot's pins on those vertices.`
 @return `How many entries changed.`
*>
fn usz AppState.pin_vertices(&self, uint[] vertices, uint dot_id, float share, bool exclusive = true)
{
	if (vertices.len == 0) return 0;
	if (dot_id == 0 && share != 0.0f) return 0;

	usz span = 0;
	foreach (v : vertices)
	{
		if ((usz)v + 1 > span) span = (usz)v + 1;
	}
	if (span == 0) return 0;

	// Membership as a flag per vertex rather than a search per pin, which is also
	// how the repeats are folded out: a lasso gathers each vertex once, but a
	// caller naming them by hand need not have.
	bool[] wanted = alloc::new_array(mem, bool, (sz)span);
	defer alloc::free(mem, wanted);

	usz singles = 0;
	foreach (v : vertices)
	{
		if (wanted[v]) continue;
		wanted[v] = true;
		singles++;
	}

	usz rivals = 0;
	if (exclusive)
	{
		foreach (pin : self.doc.pins.array_view())
		{
			if ((usz)pin.vertex >= span || !wanted[pin.vertex]) continue;
			if (pin.dot_id == dot_id) continue;
			rivals++;
		}
	}

	usz room = (dot_id != 0 ? singles : 0) + rivals;
	if (room == 0) return 0;

	VertexPin[] batch = alloc::new_array(mem, VertexPin, (sz)room);
	defer alloc::free(mem, batch);

	usz at = 0;
	if (dot_id != 0)
	{
		for (usz v = 0; v < span; v++)
		{
			if (wanted[v]) batch[at++] = { .vertex = (uint)v, .dot_id = dot_id, .share = share };
		}
	}
	if (rivals > 0)
	{
		foreach (pin : self.doc.pins.array_view())
		{
			if ((usz)pin.vertex >= span || !wanted[pin.vertex]) continue;
			if (pin.dot_id == dot_id) continue;
			batch[at++] = { .vertex = pin.vertex, .dot_id = pin.dot_id, .share = 0.0f };
		}
	}

	return self.pin_dabs(batch[:at]);
}

<*
 Take every pin off the rig, as one undoable step.

 `clear_paint` for the other layer, and the way out of a region handed to the
 wrong dot. One gesture rather than one per vertex, for the reason pinning is.

 @return `How many pins were cleared.`
*>
fn usz AppState.clear_pins(&self)
{
	sz held = self.doc.pins.len();
	if (held == 0) return 0;

	// Copied out first: `pin_dabs` writes the same list this is emptying, and a
	// list being written while it is read is a different bug every time.
	VertexPin[] batch = alloc::new_array(mem, VertexPin, held);
	defer alloc::free(mem, batch);

	foreach (usz i, pin : self.doc.pins.array_view())
	{
		batch[i] = { .vertex = pin.vertex, .dot_id = pin.dot_id, .share = 0.0f };
	}
	return self.pin_dabs(batch);
}

// ---------------------------------------------------------------------------
// Cleaning up: harden and smooth
//
// Two verbs over the whole mesh rather than two more things to draw with, which
// is what the layer under them makes possible: both of them compute a share per
// vertex and then *state* it, and stating a share is the one thing a pin can do
// and a dab cannot.
//
// Both read the bind as the user currently sees it — binder, sharpness, paint
// and the pins already there — so running either twice is running it on its own
// output, and that is the intended way to use them.

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

 **The result is pinned, so it is baked** — see `VertexPin`. Move the dot
 afterwards and the hardened vertices stay where they were told, which is the
 point of hardening and the price of it. One Ctrl+Z takes the whole pass back.

 @return `How many vertices were hardened; 0 when there was nothing to do.`
*>
fn usz AppState.harden_weights(&self)
{
	if (!self.weights_ready()) return 0;

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
	float[] painted = self.painted_bind(mem, &view);
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

	// Exclusive, the `pin_vertices` rule: a vertex being handed to one dot has to
	// come off every other, or `pin_over` divides it between the two.
	usz rivals = 0;
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= count) continue;
		if (pick[pin.vertex] == 0 || pin.dot_id == pick[pin.vertex]) continue;
		rivals++;
	}

	VertexPin[] batch = alloc::new_array(mem, VertexPin, (sz)(singles + rivals));
	defer alloc::free(mem, batch);

	usz at = 0;
	for (usz v = 0; v < count; v++)
	{
		if (pick[v] == 0) continue;
		batch[at++] = { .vertex = (uint)v, .dot_id = pick[v], .share = 1.0f };
	}
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= count) continue;
		if (pick[pin.vertex] == 0 || pin.dot_id == pick[pin.vertex]) continue;
		batch[at++] = { .vertex = pin.vertex, .dot_id = pin.dot_id, .share = 0.0f };
	}

	// One `pin_dabs`, so the whole mesh is one Ctrl+Z.
	if (self.pin_dabs(batch[:at]) == 0)
	{
		self.@notice("nothing to make rigid — every vertex already says what this would");
		return 0;
	}

	self.@notice("made %d vertices rigid", singles);
	return singles;
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

 **This bakes the band.** The result is written as fractional pins, so it no
 longer tracks the rig — move a dot afterwards and the smoothed vertices say what
 they were told, exactly as `VertexPin` warns. That is the trade the op is: a
 computed blend that drifted with every rebind would be a different answer every
 time, and nothing would be gained by computing it. Running it again smooths
 further, from where the last run left off; one Ctrl+Z takes a whole pass back.

 @return `How many vertices were rewritten; 0 when no two dots meet on this mesh.`
*>
fn usz AppState.smooth_boundaries(&self)
{
	if (!self.weights_ready()) return 0;

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
	float[] painted = self.painted_bind(mem, &view);
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

	usz touched = 0;
	usz singles = 0;
	for (usz v = 0; v < count; v++)
	{
		sz into = slot[(usz)around.class_of[v]];
		if (into < 0) continue;
		touched++;
		singles += kept[into];
	}

	// Exclusive, for `harden_weights`' reason: a dot that held part of a band
	// vertex and is not in its new top four has to lose it outright.
	usz rivals = 0;
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= count) continue;
		sz into = slot[(usz)around.class_of[pin.vertex]];
		if (into < 0 || named_by(dots, shares, (usz)into * influences, kept[into], pin.dot_id)) continue;
		rivals++;
	}

	VertexPin[] batch = alloc::new_array(mem, VertexPin, (sz)(singles + rivals));
	defer alloc::free(mem, batch);

	usz at = 0;
	for (usz v = 0; v < count; v++)
	{
		sz into = slot[(usz)around.class_of[v]];
		if (into < 0) continue;

		usz from = (usz)into * influences;
		for (usz i = 0; i < kept[into]; i++)
		{
			if (shares[from + i] <= 0.0f) continue;
			batch[at++] = { .vertex = (uint)v, .dot_id = dots[from + i], .share = shares[from + i] };
		}
	}
	foreach (pin : self.doc.pins.array_view())
	{
		if ((usz)pin.vertex >= count) continue;
		sz into = slot[(usz)around.class_of[pin.vertex]];
		if (into < 0 || named_by(dots, shares, (usz)into * influences, kept[into], pin.dot_id)) continue;
		batch[at++] = { .vertex = pin.vertex, .dot_id = pin.dot_id, .share = 0.0f };
	}

	if (self.pin_dabs(batch[:at]) == 0)
	{
		self.@notice("nothing to smooth — the weights already say what this would");
		return 0;
	}

	self.@notice("smoothed %d boundary vertices", touched);
	return touched;
}

// Whether one of a band weld's kept influences is this dot, which is what makes
// an existing pin on it a rival rather than one of the shares about to be
// written over it.
fn bool named_by(uint[] dots, float[] shares, usz at, usz held, uint dot_id) @private
{
	for (usz i = 0; i < held; i++)
	{
		if (dots[at + i] == dot_id && shares[at + i] > 0.0f) return true;
	}
	return false;
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
	self.lassoing = false;
	self.lasso_active = false;
	self.drop_lasso_stroke();
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
			self.pin_vertices(caught[:found], self.selected, 1.0f);

			// What the region now says, not what changed: drawing over vertices
			// already this dot's writes nothing and has still said the true thing
			// about them, and "pinned 0 vertices" would read as a failure.
			String name = dot.name.len > 0 ? dot.name : "that joint";
			self.@notice("pinned %d vertices to %s", found, name);
		}
		else
		{
			// Removal is the other way round: what was taken is the only number
			// there is to report, since the region caught mesh that was never
			// pinned as readily as mesh that was.
			usz did = self.pin_vertices(caught[:found], self.selected, 0.0f);
			if (did > 0)
			{
				self.@notice("unpinned %d vertices", did);
			}
			else
			{
				self.@notice("nothing in that region was pinned");
			}
		}
	}

	self.lasso_points.clear();
	self.lasso_active = false;
}

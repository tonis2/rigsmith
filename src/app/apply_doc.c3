<*
 A whole document, applied as an ordinary edit.

*>
module crig;

import std::math;

faultdef DOCUMENT_PAINT_CROSSED, DOCUMENT_PINS_CROSSED;

<*
 What an apply did, by kind.

 Counted rather than described because the caller is JavaScript and the useful
 answer there is "did my edit land" — a script that moves one dot and is told
 `moved: 0` has found a bug in itself, and one told `moved: 1` needs nothing
 further. The full description is the document, which the script already has.
*>
struct DocumentDiff
{
	uint added;
	uint removed;
	uint moved;
	uint renamed;
	uint reached;
	uint connected;
	uint disconnected;
	uint rooted;
	uint attached;
	uint physicked;
	uint collided;
	uint sharpened;
	uint transformed;
	uint settings;
}

fn uint DocumentDiff.total(self)
{
	return self.added + self.removed + self.moved + self.renamed + self.reached
		+ self.connected + self.disconnected + self.rooted + self.attached
		+ self.physicked + self.collided + self.sharpened
		+ self.transformed + self.settings;
}

<*
 Applies `want` to the live document as one undoable edit.

 ## The order is the whole correctness argument

	1. **Adds first.** An edge or attachment naming a dot that is not
    there yet is refused by the document, so every dot `want` holds has to exist
    before anything that references one is replayed.
 2. **Dot properties**, for the dots both documents hold.
 3. **Edges**, removals and additions. Removals here rather than as a side
    effect of a dot deletion below: `remove_dot` drops the edges it touched
    silently, and the ledger needs a `DELETE_EDGE` for each of them or undo puts
    the dot back with no edges on it. `app/edit_ops.c3`'s delete does the same
    thing in the same order and for the same reason.
 4. **The sparse layers**, for dots `want` still holds.
 5. **Removals**, after everything that could have named the dots going.
 6. **The root**, last of the recorded work: a removal that took the root moves
    it, so asking for the root before that would be asking about a document that
    is one step from existing.
 7. **The settings the ledger does not carry**, then `commit`.

 @param want : `The document to move to. Borrowed; nothing here keeps a pointer into it.`
 @return `What changed, by kind.`
 @return? DOCUMENT_PAINT_CROSSED : `The paint layer differs. It is vertex-keyed and does not cross — see the file header.`
 @return? DOCUMENT_PINS_CROSSED : `The pin layer differs, on the paint's terms exactly.`
*>
fn DocumentDiff? AppState.apply_document(&self, RigDocument* want)
{
	if (!same_paint(&self.doc, want)) return DOCUMENT_PAINT_CROSSED~;
	if (!same_pins(&self.doc, want)) return DOCUMENT_PINS_CROSSED~;

	DocumentDiff diff;

	// 1. Dots `want` has and the document does not.
	//
	// `insert_dot` rather than `add_dot`: the id is JavaScript's, and every
	// reference it holds — an edge, an attachment, its own next edit — names it.
	// A fresh id here would silently renumber the document underneath the script
	// that built it. `insert_dot` also carries `next_id` up past a restored id,
	// so the counter cannot fall behind and hand the same one out twice.
	foreach (dot : want.dots.array_view())
	{
		if (self.doc.find(dot.id)) continue;

		self.doc.insert_dot(dot.id, dot.position, dot.name);
		self.undo_stack.record({
			.kind = ADD_DOT,
			.id = dot.id,
			.after = dot.position,
			.name = (String)@clone_slice((char[])dot.name),
		});
		diff.added++;

		// Recorded separately rather than folded into the add, because
		// `ADD_DOT`'s replay is `insert_dot(id, position, name)` and drops the
		// reach — see `RigDocument.apply_edit`. A redo that quietly unset a
		// reach would be a slow leak of authored work.
		if (dot.reach > 0.0f && self.set_reach_recorded(dot.id, dot.reach)) diff.reached++;
		if (dot.pose_weight > 0.0f) (void)self.set_pose_weight_recorded(dot.id, dot.pose_weight);
	}

	// 2. The dots both hold.
	foreach (dot : want.dots.array_view())
	{
		Dot* had = self.doc.find(dot.id);
		if (!had) continue;

		// `move_recorded` is the one primitive with no equality guard of its own:
		// `move_dot` answers true for any dot that exists, moved or not, so
		// calling it unguarded would record a `MOVE_DOT` per dot per apply and
		// fill the ledger with edits that undo to themselves.
		if (had.position != dot.position && self.move_recorded(dot.id, had.position, dot.position))
		{
			diff.moved++;
		}
		if (self.rename_recorded(dot.id, dot.name)) diff.renamed++;
		if (self.set_reach_recorded(dot.id, dot.reach)) diff.reached++;
		(void)self.set_pose_weight_recorded(dot.id, dot.pose_weight);
	}

	// 3. Edges. Removals collected before any are dropped — `disconnect` shifts
	// the list, and a walk that mutated it would step over an entry.
	Edge[] going = collect_lost_edges(&self.doc, want);
	foreach (edge : going)
	{
		if (self.disconnect_recorded(edge.a, edge.b)) diff.disconnected++;
	}
	foreach (edge : want.edges.array_view())
	{
		if (self.doc.has_edge(edge.a, edge.b)) continue;
		// Asked of the document rather than of the ledger. `connect_recorded`
		// answers nothing and records only what the document accepted, and
		// counting stack entries instead would be wrong in one real case:
		// `record` drops the redo tail before it pushes, so the first record of
		// an apply that follows an undo can leave the list *shorter* than it
		// found it.
		self.connect_recorded(edge.a, edge.b);
		if (self.doc.has_edge(edge.a, edge.b)) diff.connected++;
	}

	// 4. The sparse layers, keyed by dot id.
	//
	// Only for dots `want` holds. An entry left behind by a dot that is going is
	// deliberately not cleared: `remove_dot` leaves them so that undoing the
	// deletion brings the dot back with its attachment still on it,
	// and the session writer is what finally drops them.
	foreach (chain : want.secondary.array_view())
	{
		if (self.set_secondary_recorded(chain)) diff.physicked++;
	}
	foreach (entry : want.colliders.array_view())
	{
		if (self.set_collider_recorded(entry.dot_id, entry.radius)) diff.collided++;
	}

	// Attachments both ways: a shell `want` names rides that dot, and a shell it
	// has stopped naming goes back to the binder. Zero is the document's own
	// spelling of "the binder decides", which is why the unpin is the same call.
	foreach (entry : want.attachments.array_view())
	{
		if (self.attach_recorded(entry.shell, entry.dot_id)) diff.attached++;
	}
	uint[] unpin = collect_lost_shells(&self.doc, want);
	foreach (shell : unpin)
	{
		if (self.attach_recorded(shell, 0)) diff.attached++;
	}

	if (self.set_sharpness_recorded(want.sharpness)) diff.sharpened++;
	if (!self.doc.model_transform.same(want.model_transform)
		&& self.set_model_transform_recorded(self.doc.model_transform, want.model_transform)) diff.transformed++;

	// 5. Removals, last of the dot work.
	uint[] doomed = collect_lost_dots(&self.doc, want);
	foreach (id : doomed)
	{
		Dot* dot = self.doc.find(id);
		if (!dot) continue;

		Vec3 position = dot.position;
		float reach = dot.reach;
		float pose_weight = dot.pose_weight;
		String dot_name = (String)@clone_slice((char[])dot.name);
		uint previous_root = self.doc.root_id;

		self.doc.remove_dot(id);
		self.undo_stack.record({
			.kind = DELETE_DOT,
			.id = id,
			.before = position,
			.other = previous_root,
			.name = dot_name,
			.reach_before = reach,
			.pose_weight_before = pose_weight,
		});
		diff.removed++;
	}

	// 6. The root, after the removals that may have moved it.
	if (self.root_recorded(want.root_id)) diff.rooted++;

	// 7. What the ledger does not carry.
	//
	// `plan`, `animations` and `auto_connect` are documented on the struct as
	// outside the undo stack — they are choices about the project rather than
	// edits to the rig. `sym_x` is the symmetry plane and `skin_from_file` is a
	// record of where the weights came from; neither is an `EditKind` either.
	// They are applied rather than recorded, which means an undo after this does
	// not take them back — the same as it does not for the panels that set them.
	if (self.doc.auto_connect != want.auto_connect)
	{
		self.doc.auto_connect = want.auto_connect;
		diff.settings++;
	}
	if (self.doc.sym_x != want.sym_x)
	{
		self.doc.sym_x = want.sym_x;
		diff.settings++;
	}
	if (self.doc.skin_from_file != want.skin_from_file)
	{
		self.doc.skin_from_file = want.skin_from_file;
		diff.settings++;
	}
	if (self.doc.plan != want.plan)
	{
		self.doc.set_plan(want.plan);
		diff.settings++;
	}
	if (!same_animations(&self.doc, want))
	{
		self.doc.free_animations();
		foreach (bound : want.animations.array_view())
		{
			self.doc.bind_clip(bound.file, bound.clip);
		}
		diff.settings++;
	}

	// A counter JavaScript raised without adding a dot — it minted an id and
	// dropped it, or built a document from nothing. Carried up and never down:
	// down is how an id already in use gets handed out a second time.
	if (want.next_id > self.doc.next_id) self.doc.next_id = want.next_id;

	self.undo_stack.commit();

	// A removal can take the dot the selection named, exactly as the delete
	// operation can, and the never-reused id scheme is what makes that safe to
	// discover here rather than guard against above.
	self.forget_stale_ids();

	if (diff.total() > 0)
	{
		self.mark_rig_stale();
		self.refresh_ui();
	}
	return diff;
}

// ---------------------------------------------------------------------------
// The three "in one and not the other" walks.
//
// Each collects into temporary memory before anything is dropped, because all
// three removals shift the list they walk — `remove_at` moves everything after
// the hole down, and a forward walk would step over whatever filled it.

fn Edge[] collect_lost_edges(RigDocument* have, RigDocument* want) @local
{
	Edge[] out = mem::temp_array(Edge, have.edges.len());
	usz found = 0;
	foreach (edge : have.edges.array_view())
	{
		if (!want.has_edge(edge.a, edge.b)) out[found++] = edge;
	}
	return out[:found];
}

fn uint[] collect_lost_dots(RigDocument* have, RigDocument* want) @local
{
	uint[] out = mem::temp_array(uint, have.dots.len());
	usz found = 0;
	foreach (dot : have.dots.array_view())
	{
		if (!want.find(dot.id)) out[found++] = dot.id;
	}
	return out[:found];
}

fn uint[] collect_lost_shells(RigDocument* have, RigDocument* want) @local
{
	uint[] out = mem::temp_array(uint, have.attachments.len());
	usz found = 0;
	foreach (entry : have.attachments.array_view())
	{
		if (want.attachment_of(entry.shell) == 0) out[found++] = entry.shell;
	}
	return out[:found];
}

// ---------------------------------------------------------------------------
// The layers that do not cross.

fn bool same_paint(RigDocument* have, RigDocument* want) @local
{
	if (have.paint.len() != want.paint.len()) return false;
	foreach (sz i, dab : have.paint.array_view())
	{
		PaintDab other = want.paint[i];
		if (dab.vertex != other.vertex || dab.dot_id != other.dot_id || dab.factor != other.factor)
		{
			return false;
		}
	}
	return true;
}

fn bool same_pins(RigDocument* have, RigDocument* want) @local
{
	if (have.pins.len() != want.pins.len()) return false;
	foreach (sz i, pin : have.pins.array_view())
	{
		VertexPin other = want.pins[i];
		if (pin.vertex != other.vertex || pin.dot_id != other.dot_id || pin.share != other.share)
		{
			return false;
		}
	}
	return true;
}

fn bool same_animations(RigDocument* have, RigDocument* want) @local
{
	if (have.animations.len() != want.animations.len()) return false;
	foreach (sz i, bound : have.animations.array_view())
	{
		BoundClip other = want.animations[i];
		if (bound.file != other.file || bound.clip != other.clip) return false;
	}
	return true;
}

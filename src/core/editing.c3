<*
 The record of every change made to the rig, and its undo.

 `core/document.c3` holds the primitives — add a dot, connect two, delete one.
 They do exactly what they say and record nothing. This file is the ledger over
 them: one `Edit` per primitive, a linear history with a cursor, and the pair
 of functions that replays an edit forwards or takes it back off again.

 What the user actually *asked* for is a layer above this one and lives in
 `app/`, because it moves the selection as well as the document. It is
 usually several primitives at once: a mirrored placement with auto-connect on
 is two dots and two bones, and one Ctrl+Z has to take all four back.

 Grouping is why `record` and `commit` are separate. `record` always marks an
 edit chained, and `commit` clears the flag on the last of the group, so the
 group boundary is wherever the operation finished rather than something each
 call site has to count. Every operation in `app/` ends with one commit, and so
 does every tool in `mcp/` that writes — there the operation is the tool call,
 which is why `edit_rig` closes a batch of ops and `apply_clip` closes one clip.

 The stack stores the edits, not snapshots of the document: a rig is small, but
 a snapshot cannot tell you *what* changed, and B7's session file wants the same
 vocabulary the edits already speak.
*>
module crig;

import std::collections::list;



alias EditList = List{Edit};

<*
 `REPLACE_CLIP`'s payload: one slot per edit, holding whichever side of the swap
 is not in the authored pack at the moment. `Edit.id` is the index into it.

 A clip is far too big to sit inline in an `Edit` — the rest of the struct is
 Vec3s and ids — and there is no `AnimTemplate` deep-copy in the tree to make a
 snapshot with. So the template *moves* here instead, and moves back out on the
 way past. See `record_clip_swap`.
*>
alias ClipStore = List{AnimTemplate};

<*
 `REBIND_CLIP`'s payload: one bound row on both sides of an edit.

 `browse` marks a binding the user added or took off by hand (the asset
 browser's + and the pane's Un-bind): replaying it leaves the clip being edited
 alone unless that clip is the one going away. `moves` is a reorder: `before`
 is the row that moved from `index` to `to`, and `after` is empty.
*>
struct BindingSwap
{
	uint index;
	BoundClip before;
	BoundClip after;
	bool browse;
	bool moves;
	uint to;
}
alias BindingStore = List{BindingSwap};

<*
 `PAINT_STROKE`'s payload: the dabs a stroke changed, both sides of each.

 A range rather than a slot, because a stroke is one undo step over thousands of
 vertices — `Edit.id` is where it starts and `Edit.other` is how many. Same stack
 discipline as `clips`, a different element, which is the whole reason the store
 is per-type rather than one tagged list: a change is 16 bytes against an
 `AnimTemplate`'s ~72, and a shared slot would cost a stroke four times its data
 to buy a homogeneity nothing reads.
*>
alias StrokeStore = List{PaintChange};

<*
 `PIN_STROKE`'s payload: the pins a gesture changed, both sides of each.

 Exactly `StrokeStore`'s element, because the shape of the question is the same
 one: a vertex, a dot, and a number either side. What the number *means* differs
 — `before` and `after` read as shares here, where a `PaintChange` in the store
 above reads as multipliers — and that is the whole of the difference, since
 neither store is ever read without knowing which edit named it.

 **A store of its own rather than a second range in that one**, and the reason
 is the invariant rather than the element: each store is stack-shaped, so
 `drop_last`'s "the edit being dropped owns the top of the store" precondition
 has to hold per kind. Interleaving pins and dabs in one list would break it the
 first time a stroke was recorded between two lasso commits.
*>
alias PinStore = List{PaintChange};

<*
 A rotation-limit edit's two complete sides.

	The table is large enough that carrying it inline would enlarge every dot and
	paint edit in the history. Kept in a payload store instead, on the
 same stack discipline as clips and strokes; `Edit.id` names one slot.
*>
struct RotationLimitSwap
{
	JointRotationLimits before;
	JointRotationLimits after;
}
alias RotationLimitStore = List{RotationLimitSwap};

// `SET_JOINT_MAPS`' payload: the whole hand-made joint mapping either side.
struct JointMapSwap
{
	JointMap[] before;
	JointMap[] after;
}
alias JointMapStore = List{JointMapSwap};

// `SET_POSES`' payload: the whole pose library either side.
struct PoseSwap
{
	SavedPose[] before;
	SavedPose[] after;
}
alias PoseStore = List{PoseSwap};

<*
 A linear history with a cursor, and the payloads its edits are too small to
 carry.

 `cursor` is how many edits are currently applied; `edits[cursor..]` are undone
 and still redoable. Recording anything new discards that tail — the timeline
 forked, and the branch not taken cannot be re-entered.

 **The payload stores are stack-shaped, for the same reason `edits` is.** Slots
 are handed out only while recording, in `record` order, so the edits a `record`
 discards are always a suffix of `edits` and their slots always a suffix of the
 store. Truncation from the end is therefore exact and holes never appear —
 which is what buys this a plain `pop` instead of a free list, a compaction pass,
 or indices that have to be rewritten when something in the middle goes.
 `drop_last` refuses on that invariant rather than trusting it.
*>
struct UndoStack
{
	EditList edits;
	sz cursor;

	<*
	 Bumped by every recorded edit, every step of history and every clear.

	 What a reader outside crig watches to know its copy of the document has gone
	 stale. `assets/js/document.js` holds a document across frames — a panel has
	 to, since it renders from one — and without this a panel would apply an edit
	 computed against a document the user had since dragged, silently taking
	 their drag back.

	 On the stack rather than on `AppState` because `record` is the one funnel
	 every recorded document mutation passes through, and a counter anywhere else
	 would be a second thing to remember to bump.

	 **Not `rig_generation`.** That one moves when the rig's *geometry* does, so a
	 rename or a constraint edit can leave it standing still — exactly the kind of
	 change a panel showing names needs to hear about.

	 **An uncommitted gesture does not move it.** A drag writes the document
	 directly and records only at the release, so a panel reading mid-drag sees
	 the revision it last saw. That is the right answer — there is no edit yet to
	 be stale against — but it is worth knowing before trusting this to drive a
	 live readout.
	*>
	uint revision;
	ClipStore clips;
	BindingStore bindings;
	StrokeStore strokes;
	PinStore pins;
	RotationLimitStore rotation_limits;
	JointMapStore joint_maps;
	PoseStore poses;
}

fn void UndoStack.free(&self)
{
	self.clear();
	self.edits.free();
	self.clips.free();
	self.bindings.free();
	self.strokes.free();
	self.pins.free();
	self.rotation_limits.free();
	self.joint_maps.free();
	self.poses.free();
	*self = { };
}

<*
 Throws the history away, keeping the stack usable.

 What `free` does minus releasing the lists' own storage, for a document that is
 being replaced rather than a state that is going: the names an `ADD_DOT` or a
 `DELETE_DOT` carries belong to the stack — `record` frees them off the tail it
 discards — so clearing the list without them leaks one string per named dot,
 and one whole clip per `REPLACE_CLIP`.

 Backwards, because `drop_last` pops the payload stores from the end.
*>
fn void UndoStack.clear(&self)
{
	// A cleared stack is a different document — a session loaded, a wholesale
	// replacement — and that is the largest change there is, not the absence of
	// one. See `UndoStack.revision`.
	self.revision = next_generation();

	while (self.edits.len() > 0)
	{
		drop_last(self, self.edits.pop()!!);
	}
	self.cursor = 0;
}

<*
 Everything the edit on top of the stack owns, released — its strings and its
 payload slot.

 One place rather than the three that ask, so a new kind that carries something
 cannot be taught to two of them and leak through the third — see
 `EditKind.carries_names`.

 **Only ever the top.** Payload slots are handed out in `record` order, so the
 edits being discarded always own the last slots; that is what lets a store be
 truncated rather than compacted. Dropping any other one would pop somebody
 else's template and free it, which surfaces later as a double free a long way
 from here — hence a precondition rather than a comment.

 @require edit.kind != REPLACE_CLIP || (sz)edit.id + 1 == stack.clips.len() : `Payload slots are handed out in record order, so only the newest edit owns the top of the store.`
 @require edit.kind != PAINT_STROKE || (sz)(edit.id + edit.other) == stack.strokes.len() : `A stroke's range is the top of the store, for the same reason a clip's slot is.`
 @require edit.kind != PIN_STROKE || (sz)(edit.id + edit.other) == stack.pins.len() : `A pin gesture's range is the top of its own store, on the same terms as a stroke's.`
 @require edit.kind != SET_ROTATION_LIMITS || (sz)edit.id + 1 == stack.rotation_limits.len() : `A limit edit's pair is the top of its own store, on the same terms as a clip.`
*>
fn void drop_last(UndoStack* stack, Edit edit) @local
{
	if (edit.kind.carries_names())
	{
		if (edit.name.len > 0) alloc::free(mem, edit.name.ptr);
		if (edit.prior_name.len > 0) alloc::free(mem, edit.prior_name.ptr);
	}

	switch (edit.kind)
	{
		case REPLACE_CLIP:
			// The only payload that owns anything of its own. A stroke's changes are
			// plain numbers, so truncating the store is the whole of releasing them.
			AnimTemplate parked = stack.clips.pop()!!;
			parked.free(mem);
		case REBIND_CLIP:
			BindingSwap swap = stack.bindings.pop()!!;
			if (swap.before.file.len > 0) alloc::free(mem, swap.before.file.ptr);
			if (swap.before.clip.len > 0) alloc::free(mem, swap.before.clip.ptr);
			if (swap.after.file.len > 0) alloc::free(mem, swap.after.file.ptr);
			if (swap.after.clip.len > 0) alloc::free(mem, swap.after.clip.ptr);
		case PAINT_STROKE:
			for (uint i = 0; i < edit.other; i++) stack.strokes.pop()!!;
		case PIN_STROKE:
			for (uint i = 0; i < edit.other; i++) stack.pins.pop()!!;
		case SET_ROTATION_LIMITS:
			stack.rotation_limits.pop()!!;
		case SET_JOINT_MAPS:
			JointMapSwap swap = stack.joint_maps.pop()!!;
			free_joint_maps(mem, swap.before);
			free_joint_maps(mem, swap.after);
		case SET_POSES:
			PoseSwap swap = stack.poses.pop()!!;
			free_saved_poses(mem, swap.before);
			free_saved_poses(mem, swap.after);
		default:
			break;
	}
}

<*
 Gives every store the heap before the first push.

 A `List` nobody initialised takes `tmem` on its first grow, and the temp
 allocator is recycled whenever the pool it was grown in closes. The undo stack
 outlives every pool, and an MCP call runs in one of its own, so an edit first
 recorded from a script left its history in memory that was handed out again:
 a clip swap read back as garbage and `record_clip_swap` aborted inside the
 temp allocator. The lists an app already gave an allocator are left alone.
*>
fn void UndoStack.use_heap(&self)
{
	if (!self.edits.is_initialized()) self.edits.init(mem);
	if (!self.clips.is_initialized()) self.clips.init(mem);
	if (!self.bindings.is_initialized()) self.bindings.init(mem);
	if (!self.strokes.is_initialized()) self.strokes.init(mem);
	if (!self.pins.is_initialized()) self.pins.init(mem);
	if (!self.rotation_limits.is_initialized()) self.rotation_limits.init(mem);
	if (!self.joint_maps.is_initialized()) self.joint_maps.init(mem);
	if (!self.poses.is_initialized()) self.poses.init(mem);
}

// The redo tail, discarded. Extracted because `record` and `record_clip_swap`
// both have to do it, and the second one has to do it *before* it takes a slot.
// Every record path starts here, so it is also where the stores get the heap.
fn void drop_redo_tail(UndoStack* stack) @local
{
	stack.use_heap();
	while (stack.edits.len() > stack.cursor)
	{
		drop_last(stack, stack.edits.pop()!!);
	}
}

fn bool UndoStack.can_undo(&self) => self.cursor > 0;
fn bool UndoStack.can_redo(&self) => self.cursor < self.edits.len();

<*
 Appends an edit that has already been applied to the document.

 Chained by default; `commit` closes the group. An operation that records and
 forgets to commit merges into whatever the user does next, which is why every
 operation in `app/` ends with one.
*>
fn void UndoStack.record(&self, Edit edit)
{
	drop_redo_tail(self);
	edit.chained = true;
	self.edits.push(edit);
	self.cursor = self.edits.len();
	self.revision = next_generation();
}

<*
 Records a clip swap, taking the displaced template with it.

 	`app.undo_stack.record_clip_swap(name.copy(mem), was);`

 The tail is discarded **before** the payload is pushed, not after: `record`
 discards the redo tail, and that tail's slots sit above this one — pushing first
 would put this template exactly where the discard is about to truncate.

 @param name : `The clip's name, owned from here — the stack frees it.`
 @param parked : `The side of the swap that is not in the pack. Owned from here; an empty one is "there was no clip of this name", which is what a fresh write parks.`
*>
fn void UndoStack.record_clip_swap(&self, String name, AnimTemplate parked)
{
	drop_redo_tail(self);
	uint at = (uint)self.clips.len();
	self.clips.push(parked);
	self.record({ .kind = REPLACE_CLIP, .id = at, .name = name });
}

fn void UndoStack.record_binding_swap(&self, uint index, BoundClip before, BoundClip after, bool browse = false)
{
	drop_redo_tail(self);
	uint at = (uint)self.bindings.len();
	self.bindings.push({ .index = index, .before = before, .after = after, .browse = browse });
	self.record({ .kind = REBIND_CLIP, .id = at });
}

<*
 Records a bound row moving from `from` to `to`.

 @param moved : `The row that moved, owned from here — the stack frees it.`
*>
fn void UndoStack.record_binding_move(&self, uint from, uint to, BoundClip moved)
{
	drop_redo_tail(self);
	uint at = (uint)self.bindings.len();
	self.bindings.push({ .index = from, .before = moved, .moves = true, .to = to });
	self.record({ .kind = REBIND_CLIP, .id = at });
}

<*
 Records one joint's complete rotation-limit state on both sides of an edit.

 `after` is the value read back from the document after its setter normalized
 it, rather than necessarily the caller's raw value.
*>
fn void UndoStack.record_rotation_limits(&self, JointRotationLimits before, JointRotationLimits after)
{
	drop_redo_tail(self);
	uint at = (uint)self.rotation_limits.len();
	self.rotation_limits.push({ .before = before, .after = after });
	self.record({ .kind = SET_ROTATION_LIMITS, .id = at });
}

<*
 Records a stroke: every dab it changed, both sides of each, as one step.

 	`app.undo_stack.record_stroke(changes);`

 One edit however many vertices the brush touched — a stroke is one action to the
 person who made it, and an edit per vertex would make Ctrl+Z useless exactly
 where it is most wanted. The tail goes first for the reason `record_clip_swap`
 gives.

 A stroke that changed nothing records nothing, so a brush dragged over mesh it
 has already painted to the same value leaves the history alone.

 @param changes : `Borrowed for the call — the values are copied into the store.`
*>
fn void UndoStack.record_stroke(&self, PaintChange[] changes)
{
	if (changes.len == 0) return;

	drop_redo_tail(self);
	uint at = (uint)self.strokes.len();
	foreach (change : changes) self.strokes.push(change);
	self.record({ .kind = PAINT_STROKE, .id = at, .other = (uint)changes.len });
}

<*
 Records a pin gesture: every vertex it handed over or took back, as one step.

 	`app.undo_stack.record_pin_stroke(changes);`

 `record_stroke` for the other layer, and the same bargain — one edit however
 many vertices a lasso caught, since the region is what the person drew. A
 gesture that changed nothing records nothing, so a lasso drawn over mesh
 already pinned the same way leaves the history alone.

 The two differ in when they are called rather than in what they do: a brush
 commits per mouse move, because a stroke is a stream the hand is still adding
 to, while a lasso commits once on release because a region is not finished
 until it is closed.

 @param changes : `Borrowed for the call — the values are copied into the store. Both sides read as shares here, not as multipliers.`
*>
fn void UndoStack.record_pin_stroke(&self, PaintChange[] changes)
{
	if (changes.len == 0) return;

	drop_redo_tail(self);
	uint at = (uint)self.pins.len();
	foreach (change : changes) self.pins.push(change);
	self.record({ .kind = PIN_STROKE, .id = at, .other = (uint)changes.len });
}

<*
 Records the joint mapping on both sides of an edit. Both are owned from here.
*>
fn void UndoStack.record_joint_maps(&self, JointMap[] before, JointMap[] after)
{
	drop_redo_tail(self);
	if (!self.joint_maps.is_initialized()) self.joint_maps.init(mem);
	uint at = (uint)self.joint_maps.len();
	self.joint_maps.push({ .before = before, .after = after });
	self.record({ .kind = SET_JOINT_MAPS, .id = at });
}

<*
 Records the pose library on both sides of an edit. Both are owned from here.
*>
fn void UndoStack.record_poses(&self, SavedPose[] before, SavedPose[] after)
{
	drop_redo_tail(self);
	if (!self.poses.is_initialized()) self.poses.init(mem);
	uint at = (uint)self.poses.len();
	self.poses.push({ .before = before, .after = after });
	self.record({ .kind = SET_POSES, .id = at });
}

fn void UndoStack.commit(&self)
{
	if (self.edits.len() == 0) return;
	self.edits.get_ref(self.edits.len() - 1).chained = false;
}

// ---------------------------------------------------------------------------
// One edit, both directions.
//
// Methods on RigDocument but living here rather than next door in
// `core/document.c3`: an edit is a replay of the primitives, so this is the only
// pair of functions that knows the whole EditKind mapping, and keeping them
// adjacent is what makes it obvious when a new kind gets handled in one and not
// the other.

<*
 Replays an edit onto the document — the forward direction, used by redo.

 @require !edit.kind.carries_payload() : `A kind whose payload lives on the undo stack replays through AppState.apply_one, in app/history.c3 — the document cannot see the stack.`
*>
fn void RigDocument.apply_edit(&self, Edit edit)
{
	switch (edit.kind)
	{
		case ADD_DOT: self.insert_dot(edit.id, edit.after, edit.name);
		case DELETE_DOT: self.remove_dot(edit.id);
		case MOVE_DOT: self.move_dot(edit.id, edit.after);
		case RENAME_DOT: self.rename_dot(edit.id, edit.name);
		case SET_REACH: self.set_reach(edit.id, edit.reach_after);
		case SET_POSE_WEIGHT: self.set_pose_weight(edit.id, edit.pose_weight_after);
		case SET_SHARPNESS: self.set_sharpness(edit.sharp_after);
		case ADD_EDGE: self.connect(edit.id, edit.other);
		case DELETE_EDGE: self.disconnect(edit.id, edit.other);
		case SET_ROOT: self.root_id = edit.id;
		case ATTACH_SHELL: self.attach_shell(edit.shell, edit.id);
		case SET_SECONDARY: self.assign_secondary(edit.id, edit.secondary_after);
		case SET_COLLIDER: self.set_collider(edit.id, edit.collider_after);
		case ADD_EXCLUSION: self.add_exclusion(edit.id, edit.other);
		case DELETE_EXCLUSION: self.remove_exclusion(edit.id, edit.other);
		case SET_SYM_X: self.set_sym_x(edit.sym_after);
		case SET_MODEL_TRANSFORM: self.model_transform = edit.transform_after;
		case SCALE_MODEL:
		case SET_ROTATION_LIMITS:
		case SET_JOINT_MAPS:
		case SET_POSES:
		case REPLACE_CLIP:
		case REBIND_CLIP:
		case PAINT_STROKE:
		case PIN_STROKE:
			unreachable(PAYLOAD_IS_THE_APPS);
	}
}

<*
 Takes an edit back off the document — the mirror of `apply_edit`, used by undo.

 @require !edit.kind.carries_payload() : `A kind whose payload lives on the undo stack reverts through AppState.revert_one, in app/history.c3 — the document cannot see the stack.`
*>
fn void RigDocument.revert_edit(&self, Edit edit)
{
	switch (edit.kind)
	{
		case ADD_DOT:
			self.remove_dot(edit.id);
		case DELETE_DOT:
			self.insert_dot(edit.id, edit.before, edit.name, edit.reach_before, edit.pose_weight_before);
			// `remove_dot` hands the root to whatever was left, so putting the
			// dot back is not enough to put the root back. Restored from the
			// edit rather than re-derived, because the guess it made on the way
			// out is not invertible.
			self.root_id = edit.other;
		case MOVE_DOT:
			self.move_dot(edit.id, edit.before);
		case RENAME_DOT:
			self.rename_dot(edit.id, edit.prior_name);
		case SET_REACH:
			self.set_reach(edit.id, edit.reach_before);
		case SET_POSE_WEIGHT:
			self.set_pose_weight(edit.id, edit.pose_weight_before);
		case SET_SHARPNESS:
			// Zero is a real previous value here — it is the unset state, read as
			// the binder's own blend — and `set_sharpness` stores it as such, so
			// taking back the first sharpening leaves the document as it found it.
			self.set_sharpness(edit.sharp_before);
		case ADD_EDGE:
			self.disconnect(edit.id, edit.other);
		case DELETE_EDGE:
			self.connect(edit.id, edit.other);
		case SET_ROOT:
			self.root_id = edit.other;
		case ATTACH_SHELL:
			// Zero is a real previous value here — it is what "the binder was
			// deciding" is stored as — and `attach_shell` reads it as "unpin",
			// which is exactly the undo of a first attachment.
			self.attach_shell(edit.shell, edit.other);
		case SET_SECONDARY:
			// The zero record is a real previous value — no chain on this root —
			// and `assign_secondary` reads it as a clear, so taking back the first
			// chain on a root removes its entry rather than writing an empty one.
			self.assign_secondary(edit.id, edit.secondary_before);
		case SET_COLLIDER:
			self.set_collider(edit.id, edit.collider_before);
		case ADD_EXCLUSION:
			self.remove_exclusion(edit.id, edit.other);
		case DELETE_EXCLUSION:
			self.add_exclusion(edit.id, edit.other);
		case SET_SYM_X:
			self.set_sym_x(edit.sym_before);
		case SET_MODEL_TRANSFORM:
			self.model_transform = edit.transform_before;
		case SCALE_MODEL:
		case SET_ROTATION_LIMITS:
		case SET_JOINT_MAPS:
		case SET_POSES:
		case REPLACE_CLIP:
		case REBIND_CLIP:
		case PAINT_STROKE:
		case PIN_STROKE:
			unreachable(PAYLOAD_IS_THE_APPS);
	}
}

// Both switches above answer `REPLACE_CLIP` with this. Reaching either one means
// an edit was replayed against a receiver that never owned it — the document has
// no clips, so there is nothing here that could be right to do.
const String PAYLOAD_IS_THE_APPS @local =
	"an edit carrying a payload store applies at the app level, in AppState.apply_one — see app/history.c3";

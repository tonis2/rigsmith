<*
 Which of the library's clips belong to this character.

 	`app.bind_ref(ref);`
 	`AnimRef ref = app.resolve_bound(i);`

 The document stores a binding as **a file path and a clip name** (`BoundClip`,
 core/document.c3) because that is what survives: an `AnimRef` is a pair of
 positions into `AppState.packs`, and `load_packs` re-reads the whole library, so
 a reference written to a session would come back pointing at whatever landed in
 that slot. This file is the other half — turning those two strings back into a
 reference the player and the writer can use, and doing it lazily, because the
 file a binding names may not have been read yet.

 **Resolution is by path, then by basename.** `pack_for_file` keys on the path
 string, so a project opened from a different checkout — or a library folder that
 moved — would find nothing under the recorded path while the very same file sits
 one directory over. Falling back to the basename across the configured libraries
 turns "all your animations are gone" into "found it anyway", which is worth the
 small chance of matching a different file of the same name: the clip name still
 has to match inside it.

 **What will not resolve is kept.** An entry whose file is gone stays in the list
 and comes back `NO_ANIM`, so the panel can draw it as missing. Dropping it would
 destroy the only record that the user ever chose it, and it would do so silently
 at load time — the worst moment and the quietest.
*>
module crig;



import std::io;
import std::math;

<*
 Resolve a bound entry to a live reference, reading its file if that is what it
 takes.

 	`AnimRef ref = app.resolve_bound(i);`

 Not cached on the entry. `pack_for_file` already caches at the level that
 matters — the file is read once and kept in `packs` — and an `AnimRef` cached
 here would be exactly the stale index the file format avoids storing. What this
 costs on a resolved library is a path compare and a name compare per call.

 **Reallocates `packs` when it reads**, through `pack_for_file`, so every
 `AnimPack*` taken before this call is dangling after it — the `adopt_pack`
 warning, which applies to every caller of this.

 @return `NO_ANIM when the file will not open, or holds no clip of that name.`
*>
fn AnimRef AppState.resolve_bound(&self, sz index)
{
	if (index < 0 || index >= self.doc.animations.len()) return NO_ANIM;
	BoundClip bound = self.doc.animations[index];

	// Empty file means project-owned. Project load restores these templates from
	// the session sidecar before bindings are resolved; no library file is needed.
	if (bound.file.len == 0) return self.clip_named_in_authored(bound.clip);

	int pack = self.pack_for_file(bound.file);
	if (pack < 0) pack = self.pack_for_basename(base_name(bound.file));
	if (pack < 0) return NO_ANIM;

	return self.clip_named_in(pack, bound.clip);
}

fn AnimRef AppState.resolve_clip_identity(&self, String file, String clip)
{
	if (clip.len == 0) return NO_ANIM;
	if (file.len == 0) return self.clip_named_in_authored(clip);
	int pack = self.pack_for_file(file);
	if (pack < 0) pack = self.pack_for_basename(base_name(file));
	return pack < 0 ? NO_ANIM : self.clip_named_in(pack, clip);
}

<*
 The pack read from a file whose *name* matches, wherever it now lives.

 The fallback half of `resolve_bound`, and deliberately only reached when the
 recorded path missed. Walks the asset index rather than the loaded packs,
 because the whole point is to find a file nothing has read yet.

 @return `Its index among the loaded packs, or -1.`
*>
fn int AppState.pack_for_basename(&self, String name)
{
	if (name.len == 0) return -1;

	foreach (&entry : self.assets.entries)
	{
		if (base_name(entry.file) != name) continue;
		int pack = self.pack_for_file(entry.file);
		if (pack >= 0) return pack;
	}
	return -1;
}

<*
 The clip of this name inside one pack.

 By name only — unlike `ref_for_asset`, which falls back to the entry's position
 among the file's glTF animations. There is no position to fall back to here: a
 binding records a name because a name is what a person chose, and guessing a
 different clip because the file was re-authored would play the wrong animation
 rather than admit it lost one.
*>
fn AnimRef AppState.clip_named_in(&self, int pack, String name)
{
	AnimPack* held = self.pack((usz)pack);
	if (!held) return NO_ANIM;

	foreach (usz i, clip : held.clips)
	{
		if (clip.name == name) return { pack, (int)i };
	}
	return NO_ANIM;
}

<*
 The clip of this name in the authored pack, if there is one.
*>
fn AnimRef AppState.clip_named_in_authored(&self, String name)
{
	if (self.authored_pack < 0) return NO_ANIM;
	return self.clip_named_in(self.authored_pack, name);
}

<*
 Where a live reference came from, as the pair a binding stores.

 The inverse of `resolve_bound`, and what `bind_ref` is built out of. The file is
 borrowed from the pack, so it lives exactly as long as the library does — every
 caller copies it or hands it straight to `bind_clip`, which does.

 @return `False when the reference names no clip.`
*>
fn bool AppState.binding_of(&self, AnimRef ref, String* file, String* clip)
{
	AnimTemplate* template = self.clip(ref);
	AnimPack* pack = template ? self.pack((usz)ref.pack) : null;
	if (!pack) return false;

	// The authored pack has no file, and says so with an empty path rather than
	// with the path of whatever it might one day be saved into.
	*file = ref.pack == self.authored_pack ? "" : pack.path;
	*clip = template.name;
	return true;
}

<*
 Bind the clip a live reference names.

 	`if (app.bind_ref(ref)) app.refresh_ui();`

 @return `False when the reference names no clip, or that clip is already bound.`
*>
fn bool AppState.bind_ref(&self, AnimRef ref)
{
	String file;
	String clip;
	if (!self.binding_of(ref, &file, &clip)) return false;
	return self.doc.bind_clip(file, clip);
}

<*
 Bind a clip by file path and name, recording the binding in the open undo group.

 `bind_ref` and `doc.bind_clip` do not touch the undo stack, so a binding they add
 outlives an undo of the edit around it. This records the swap the way
 `author_clip` does, for a caller — the importer — that wants the binding to
 belong to a larger transaction and come back with one Ctrl+Z. The caller owns the
 group and commits it.

 @return `False for a nameless clip, or one already bound; nothing is added twice.`
*>
fn bool AppState.bind_clip_recorded(&self, String file, String name)
{
	if (name.len == 0) return false;
	if (self.doc.bound_index(file, name) >= 0) return false;

	uint at = (uint)self.doc.animations.len();
	BoundClip parked = self.doc.swap_bound(at, owned_binding(file, name));
	self.undo_stack.record_binding_swap(at, parked, owned_binding(file, name));
	return true;
}

<*
 Bind the clip a live reference names, as one undo step of its own.

 	`if (app.bind_ref_recorded(ref)) app.refresh_ui();`

 What the asset browser's + does. `bind_ref` stays the unrecorded door for
 callers that set up a document rather than edit one.

 @return `False when the reference names no clip, or that clip is already bound.`
*>
fn bool AppState.bind_ref_recorded(&self, AnimRef ref)
{
	String file;
	String clip;
	if (!self.binding_of(ref, &file, &clip)) return false;
	if (clip.len == 0 || self.doc.bound_index(file, clip) >= 0) return false;

	uint at = (uint)self.doc.animations.len();
	BoundClip parked = self.doc.swap_bound(at, owned_binding(file, clip));
	self.undo_stack.record_binding_swap(at, parked, owned_binding(file, clip), browse: true);
	self.undo_stack.commit();
	self.refresh_bound_rows();
	return true;
}

<*
 Take the bound row at `row` off the character, as one undo step.

 The binding moves to the undo stack rather than being freed, so Ctrl+Z puts
 it back at the same place in the list. The clip being edited is let go when it
 is the one unbound.

 @return `False when there is no such row.`
*>
fn bool AppState.unbind_recorded(&self, sz row)
{
	if (row < 0 || row >= self.doc.animations.len()) return false;
	AnimRef going = self.resolve_bound(row);
	BoundClip removed = self.doc.swap_bound((uint)row, {});
	self.undo_stack.record_binding_swap((uint)row, removed, {}, browse: true);
	self.undo_stack.commit();
	self.let_go_of_clip(going);
	self.refresh_bound_rows();
	return true;
}

<*
 Move a bound row to another position, as one undo step.

 @return `False for a move that goes nowhere or out of the list.`
*>
fn bool AppState.reorder_bound_recorded(&self, sz from, sz to)
{
	if (!self.doc.reorder_bound(from, to)) return false;
	BoundClip moved = self.doc.animations[to];
	self.undo_stack.record_binding_move((uint)from, (uint)to, owned_binding(moved.file, moved.clip));
	self.undo_stack.commit();
	self.refresh_bound_rows();
	return true;
}

<*
 Stop editing and playing a clip that is no longer on the character.

 Nothing happens when `ref` is not the clip being edited.
*>
fn void AppState.let_go_of_clip(&self, AnimRef ref)
{
	if (!ref.valid() || !ref.same(self.editing)) return;
	self.stop_animation();
	self.clear_animation_key_selection();
	self.editing = NO_ANIM;
	self.edit_time = 0;
}

<*
 Rebuild the bound list's rows, and every pane drawing them, at once.

 Immediately rather than on the next build: a row's label borrows the binding's
 clip name, which an unbind or an undo may have just released.
*>
fn void AppState.refresh_bound_rows(&self)
{
	self.refresh_anim_rows();
	if (self.ui) refresh_animations_view(self.ui);
}

// Exchange one binding with an owned parked value. An empty parked binding is
// absence, which makes appending a newly-authored clip self-inverse for undo.
fn BoundClip RigDocument.swap_bound(&self, uint index, BoundClip incoming)
{
	if ((sz)index < self.animations.len())
	{
		BoundClip outgoing = self.animations[(usz)index];
		if (incoming.clip.len > 0) { *self.animations.get_ref((sz)index) = incoming; }
		else { self.animations.remove_at((sz)index); }
		return outgoing;
	}
	if ((sz)index == self.animations.len() && incoming.clip.len > 0)
	{
		self.animations.push(incoming);
	}
	return {};
}

fn void RigDocument.insert_owned_bound(&self, sz index, BoundClip incoming)
{
	sz at = math::clamp(index, 0, self.animations.len());
	self.animations.insert_at(at, incoming);
}

fn BoundClip owned_binding(String file, String clip) @private
{
	return {
		.file = file.len > 0 ? file.copy(mem) : "",
		.clip = clip.copy(mem),
	};
}

<*
 Whether an index entry names a clip this character has bound.

 	`if (app.is_bound_entry(entry)) …`

 Asked once per visible animation cell per paint, so it reads the two strings a
 binding stores and compares them — **no file is opened and no pack is loaded**.
 That is the whole reason a binding is a path and a name rather than a reference:
 the grid can say what is bound without reading the library it is listing.

 The comparison is the index's spelling against the document's, and those agree
 because `bind_clip` is given the pack's own clip name and `ref_for_asset` finds
 a clip by that same name. A file re-authored under crig's feet — the clip
 renamed inside it — would show its mark go out, which is the truthful answer:
 the binding no longer names anything in that file.
*>
fn bool AppState.is_bound_entry(&self, AssetEntry* entry)
{
	// A model's mark says it is already in the scene.
	if (entry && entry.kind == AssetKind.MODEL) return self.character_from(entry.file) >= 0;
	if (!entry || entry.kind != AssetKind.ANIMATION) return false;
	return self.doc.bound_index(entry.file, entry.name) >= 0;
}

<*
 Bind or unbind the animation a visible row names, reading its file if binding
 needs the pack to name the clip.

 **This is where a library file gets read now.** It used to be the export panel's
 tick — "ticking is what loads" — which was the right mechanic in the wrong
 place: the choice of what a character has belongs in the browser, so the read
 that backs it does too.

 Unbinding does not read anything. The pair to remove is already in the document,
 so a clip whose file has since gone missing can still be taken off the list —
 which is exactly when a user most wants to.

 @return `True when the document changed.`
*>
fn bool AppState.toggle_bound_row(&self, usz row)
{
	AssetEntry* entry = self.visible_asset(row);
	// A model's + brings it into the scene, or makes it the one being edited when
	// it is in already.
	if (entry && entry.kind == AssetKind.MODEL)
	{
		self.request_add_character(entry.file);
		return true;
	}
	if (!entry || entry.kind != AssetKind.ANIMATION) return false;

	sz at = self.doc.bound_index(entry.file, entry.name);
	if (at >= 0)
	{
		// Copied: resolving the row may read a pack, which moves the entry.
		String named = entry.name.copy(mem);
		defer named.free(mem);
		self.unbind_recorded(at);
		self.@notice("removed %s from the character · Ctrl+Z puts it back", named);
		return true;
	}

	// Binding goes through the pack so the name stored is the pack's own, which is
	// what `resolve_bound` will look for — and the two have to be the same string,
	// which is what the guard below is about.
	int pack = self.pack_for_file(entry.file);
	if (pack < 0)
	{
		self.@notice("could not read %s", base_name(entry.file));
		return false;
	}

	// Re-taken after `pack_for_file`, which reallocates the pack array and with it
	// every entry pointer the index handed out.
	entry = self.visible_asset(row);
	if (!entry) return false;

	// **By name, and only by name.** `ref_for_asset` will hand back a clip by its
	// position in the file when the name missed — one clip failing to convert shifts
	// every clip after it — which is a fair guess for greying a cell and the wrong
	// one for binding it. `resolve_bound` looks a binding up by name and nothing
	// else, deliberately, so a binding stored under a name this index does not carry
	// is one the grid can never draw its mark for and the pane can never resolve.
	// Refusing it in words beats putting an animation on the character that the user
	// did not point at.
	AnimRef ref = self.ref_for_asset(pack, entry);
	AnimTemplate* named = self.clip(ref);
	if (!named || named.name != entry.name)
	{
		self.@notice("%s holds no clip called %s", base_name(entry.file), entry.name);
		return false;
	}

	// Unreachable while that guard holds: the row said this clip was not bound, and
	// the name it would be bound under is the one just compared. Said out loud
	// rather than returned in silence — a `+` that does nothing and explains nothing
	// is what made a name mismatch read as broken binding for as long as it did.
	if (!self.bind_ref_recorded(ref))
	{
		self.@notice("%s could not be added", entry.name);
		return false;
	}

	usz total;
	usz found;
	self.bound_counts(&total, &found);
	self.@notice("added %s · %d animation%s on this character",
		entry.name, total, total == 1 ? "" : "s");
	return true;
}

<*
 How many bound clips there are, and how many of them can be found.

 What the export panel says in one line instead of a picker, and what the
 Animations panel counts in its header. Resolving every entry, so this is the
 expensive one — it is asked when a panel is built and not while it paints.
*>
fn void AppState.bound_counts(&self, usz* total, usz* found)
{
	*total = (usz)self.doc.animations.len();
	*found = 0;
	for (sz i = 0; i < self.doc.animations.len(); i++)
	{
		if (self.resolve_bound(i).valid()) (*found)++;
	}
}

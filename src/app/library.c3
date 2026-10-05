<*
 The packs held in memory: read off disk, added to, and written back.

 A pack is a body plan and its clips (`anim/pack.c3`); the folders they are
 read from are the configured libraries (`core/config.c3`). `scan_libraries` is
 what startup and the settings dialog call — the index in full, the packs only
 where one declares a plan, because a folder from another tool costs one open
 per file and a plan is what everything else measures against.

 **The authored pack is project-owned.** Its clips are persisted in the session
 sidecar rather than read from a library glTF. A library re-read therefore lifts
 the pack out and restores it afterwards; otherwise reloading configured assets
 would discard project work.

 `save_authored_pack` publishes a copy into a reusable library file, merging
 with clips already there. It deliberately keeps the project-owned originals:
 publishing is not a move, and their empty-file bindings remain stable.

 What the browser *shows* is `assets.c3`, which indexes every file in every
 library without loading any of them.
*>
module crig;

import rig;
import gltf;
import std::math;

struct LibraryRefs
{
	String edit_file;
	String edit_name;
	String play_file;
	String play_name;
	bool playing;
	bool paused;
	float edit_time;
	float play_time;
}

fn LibraryRefs AppState.remember_library_refs(&self)
{
	LibraryRefs out = {
		.playing = self.animating,
		.paused = self.anim_paused,
		.edit_time = self.edit_time,
		.play_time = self.anim_time,
	};
	String file;
	String name;
	if (self.binding_of(self.editing, &file, &name))
	{
		out.edit_file = file.len > 0 ? file.copy(mem) : "";
		out.edit_name = name.copy(mem);
	}
	if (self.binding_of(self.current_ref, &file, &name))
	{
		out.play_file = file.len > 0 ? file.copy(mem) : "";
		out.play_name = name.copy(mem);
	}
	return out;
}

fn void LibraryRefs.free(&self)
{
	if (self.edit_file.len > 0) alloc::free(mem, self.edit_file.ptr);
	if (self.edit_name.len > 0) alloc::free(mem, self.edit_name.ptr);
	if (self.play_file.len > 0) alloc::free(mem, self.play_file.ptr);
	if (self.play_name.len > 0) alloc::free(mem, self.play_name.ptr);
	*self = {};
}

fn void AppState.restore_library_refs(&self, LibraryRefs* refs)
{
	// Numeric pack/clip positions can be reused by a reload for different keys.
	self.clear_animation_key_selection();
	self.editing = self.resolve_clip_identity(refs.edit_file, refs.edit_name);
	if (self.editing.valid())
	{
		AnimTemplate* clip = self.clip(self.editing);
		self.edit_time = clip ? math::clamp(refs.edit_time, 0.0f, clip.duration) : 0.0f;
		self.refresh_timeline_tracks(self.editing);
	}
	else
	{
		self.refresh_timeline_tracks(NO_ANIM);
	}
	if (!refs.playing) return;
	AnimRef playing = self.resolve_clip_identity(refs.play_file, refs.play_name);
	if (!playing.valid() || !self.start_animation_ref(playing)) return;
	self.anim_time = math::clamp(refs.play_time, 0.0f, self.current_anim.duration);
	self.anim_paused = refs.paused;
	if (playing.same(self.editing)) self.edit_time = self.anim_time;
	self.refresh_animation();
}



<*
 Lift the authored pack out of the library so a re-read cannot take it with it.

 Nothing on disk backs the authored pack, so freeing the library would throw
 away work no file can give back. Zeroing the slot it came from leaves `owned`
 false, which is what makes `free_packs` walk past it.

 **The caller owes `restore_authored` on every path out.** Between the two calls
 the app holds a pack nothing else knows about, and dropping it on the floor
 leaks every clip in it.

 @return `The pack, or a zero-valued one when there was nothing authored.`
*>
fn AnimPack AppState.take_authored(&self)
{
	AnimPack authored = {};
	AnimPack* held = self.authored();
	if (held)
	{
		authored = *held;
		*held = {};
	}
	self.authored_pack = -1;
	return authored;
}

<*
 Put the authored pack back at the end of the freshly read library.

 Its index moves, which is safe only because the callers stopped playback before
 taking it out — that dropped the one reference the app holds across a call. An
 empty pack is freed rather than adopted, so a library re-read with nothing
 authored comes back with no phantom card in it.

 @param authored : `What take_authored returned. Owned from here.`
*>
fn void AppState.restore_authored(&self, AnimPack authored)
{
	if (authored.clips.len > 0)
	{
		self.authored_pack = (int)self.adopt_pack(authored);
		return;
	}
	authored.free(mem);
}

// Install the authored sidecar payload after a project load. Ownership of the
// array and every template in it passes to the app.
fn void AppState.replace_authored_clips(&self, AnimTemplate[] clips)
{
	AnimPack* old = self.authored();
	if (clips.len == 0)
	{
		if (old)
		{
			old.free(mem);
			*old = {};
			self.authored_pack = -1;
		}
		return;
	}
	AnimPack replacement = {
		.name = AUTHORED_PACK_NAME.copy(mem),
		.version = PACK_VERSION,
		.clips = clips,
		.owned = true,
	};
	if (old)
	{
		old.free(mem);
		*old = replacement;
		return;
	}
	self.authored_pack = (int)self.adopt_pack(replacement);
}

<*
 Name the folder an authored pack is written to and re-read from.

 Copied rather than borrowed: a caller is free to hand this a path it built and
 freed, and the folder has to still be nameable long afterwards.

 **Copied before the old one is released, not after.** `save_authored_pack`
 re-reads by passing `library_path` straight back in, so freeing first hands the
 allocator a block it is free to return again — leaving the copy reading the
 string it is writing.

 @param directory : `Where to write. Empty clears the path, which disables saving.`
*>
fn void AppState.set_library_path(&self, String directory)
{
	String kept = directory.len > 0 ? directory.copy(mem) : "";
	if (self.library_path.len > 0) alloc::free(mem, self.library_path.ptr);
	self.library_path = kept;
}

// Clips across the whole library, which is what both readers report.
fn usz AppState.clip_total(&self)
{
	usz clips = 0;
	foreach (pack : self.packs) clips += pack.clips.len;
	return clips;
}

<*
 Read the animation library off disk, replacing whatever was held.

 One folder, every pack in it, whether or not it declares a body plan —
 `scan_libraries` is the configured-libraries reader and the one startup calls.
 A missing folder is an empty library rather than an error: crig is usable
 without animations, and someone running it from another directory should get a
 working editor and a short menu, not a failure.

 @return `How many clips were found, across every pack.`
*>
fn usz AppState.load_packs(&self, String directory)
{
	LibraryRefs refs = self.remember_library_refs();
	defer refs.free();
	self.stop_animation();
	AnimPack authored = self.take_authored();

	// The warning at the top of `save_authored_pack`, enforced one line above the
	// free it warns about: every AnimPack*, AnimTemplate* and AnimRef taken
	// before this is dangling after it.

	self.free_pack_reaches();
	self.reach_stale = true;
	self.drop_packs();
	AnimPack[] scanned = scan_packs(mem, directory);
	foreach (pack : scanned) self.adopt_pack(pack);
	if (scanned.len > 0) alloc::free(mem, scanned);
	self.expanded_pack = 0;

	self.set_library_path(directory);
	self.restore_authored(authored);
	self.restore_library_refs(&refs);

	// The library is where body plans come from, so plan targets fitted before
	// this ran were fitted against nothing. Startup does exactly that: a session
	// is loaded — plan tag and all — before the packs are read.
	self.plan_targets_stale = true;

	return self.clip_total();
}

<*
 Read every configured library: the index in full, the packs only in part.

 The two readings the browser needs, and they cost very different things. The
 **index** is every item in every file, from the JSON chunk alone — one
 `gltf::open` per file, whatever the file weighs. The **packs** are whole files
 loaded, and only the ones that declare a body plan are read here, because those
 are what everything else measures against: a preset to fit, a plan to name a
 rig's joints in, the clips the export dialog lists. Everything else in a library
 waits for `pack_for_file`.

 That is the difference between a library of three files and a library of three
 hundred. A folder from another tool costs one open per file at startup and
 nothing more until something in it is clicked.

 Replaces whatever was held, so this is also the reload. Called at startup and
 whenever the configured libraries change.

 @return `How many clips were found, across every pack read.`
*>
fn usz AppState.scan_libraries(&self)
{
	LibraryRefs refs = self.remember_library_refs();
	defer refs.free();
	self.stop_animation();
	AnimPack authored = self.take_authored();


	self.free_pack_reaches();
	self.reach_stale = true;
	self.drop_packs();

	AssetLibrary[] libraries = self.config.libraries.array_view();

	// The index first, and the declaring files taken out of it. The other order —
	// which is the order this ran in — probed every file for a plan tag and then
	// opened every file again to index it, and an open is about seventy
	// milliseconds whatever the file weighs. Reading the tag off the index costs
	// nothing, because the index already read it.
	self.rescan_assets();

	foreach (usz i, library : libraries)
	{
		String[] declaring = self.declaring_files(mem, (int)i);
		defer if (declaring.len > 0) alloc::free(mem, declaring);

		AnimPack[] declared = read_declared_packs(mem, declaring);
		// Adopted one at a time rather than concatenated: `adopt_pack` is the one
		// place the array grows, and a second way of growing it is a second place to
		// get the authored pack's index wrong.
		foreach (pack : declared) self.adopt_pack(pack);
		if (declared.len > 0) alloc::free(mem, declared);
	}
	self.expanded_pack = 0;

	// The first library is where an authored pack is written, and so where it is
	// re-read from.
	self.set_library_path(libraries.len > 0 ? libraries[0].path : "");
	self.restore_authored(authored);
	self.restore_library_refs(&refs);

	self.rebuild_reference_plans();

	// The export panel's rows borrow their names and paths from the index that
	// was just freed. Nothing reads them while the panel is shut — and opening it
	// rebuilds them — but a slice of dangling pointers left lying on the state is
	// a trap for whatever reads it next.

	// The library is where body plans come from, so plan targets fitted before this
	// ran were fitted against nothing. Startup does exactly that: a session is
	// loaded — plan tag and all — before the libraries are read.
	self.plan_targets_stale = true;

	return self.clip_total();
}

<*
 The distinct files in one library that the index says declare a body plan.

 What `declares_plan` used to answer with an open per file. Every entry out of
 one file carries that file's plan, so the list is deduplicated — a pack with a
 skin, four clips and a body appears five times in the index and once here.

 The paths are **borrowed** from the index, which outlives the read they are
 handed to; the caller owns only the array.
*>
fn String[] AppState.declaring_files(&self, Allocator allocator, int library)
{
	StringList out;
	out.init(allocator);

	foreach (&entry : self.assets.entries)
	{
		if (entry.library != library || entry.plan.len == 0) continue;

		// Scanned back over what has been collected rather than kept in a set: the
		// files declaring a plan are a handful even in a large library, and this
		// keeps them in the index's own order with nothing to free.
		bool seen = false;
		foreach (already : out.array_view())
		{
			if (already == entry.file) { seen = true; break; }
		}
		if (!seen) out.push(entry.file);
	}

	String[] files = out.to_array(allocator);
	out.free();
	return files;
}

<*
 Whether the index says this file names its own body plan.

 The same question `declares_plan` opens a file to answer, asked of the index
 instead — which read the tag when it read everything else about the file.

 A file the index does not hold reads as undeclared: it is either not in a
 configured library or it holds nothing indexable, and neither is a file whose
 joints are already named in a plan's words.
*>
fn bool AppState.file_declares_plan(&self, String file)
{
	foreach (&entry : self.assets.entries)
	{
		if (entry.file == file) return entry.plan.len > 0;
	}
	return false;
}

<*
 Read one already-loaded pack again, into the slot it is already in.

 What a file changing under the library costs, when the change is to that file
 alone. **In place is the whole point**: a pack's position in `packs` is what
 every `AnimRef` names it by — a tick in the export panel, the clip that is
 playing, the pack the library card has open — so a reload that appended or
 removed would silently re-point all of them.

 Playback stops only if it was this pack that was playing. `start_animation`
 takes a copy of the template whose keyframes still point into the pack's own
 memory, so the clip has to be let go before the pack is freed; a clip out of
 some other pack is untouched by any of this.

 @param file : `The path of the pack to re-read. Must not be the loaded pack's own path string, which this frees.`
 @return `False when no pack came from that file, or the file no longer reads.`
*>
fn bool AppState.reload_pack(&self, String file)
{
	int which = self.loaded_pack_for(file);
	if (which < 0) return false;

	bool affected = self.editing.pack == which || self.current_ref.pack == which;
	LibraryRefs refs = affected ? self.remember_library_refs() : (LibraryRefs){};
	defer refs.free();

	// A file that names its own body plan has its joints already named in that
	// plan's words and needs no matching — which is the rule the declared pass
	// follows, kept the same here so that reloading a pack produces the pack a
	// scan would have. It is also the difference between reading one file and
	// shape-matching its skeleton against every plan in the library: sixteen
	// seconds against a tenth of one, on a shelf where two hundred files declare
	// a plan.
	AnimPack? fresh = self.file_declares_plan(file)
		? read_pack(mem, file)
		: read_pack(mem, file, plans: self.reference_plans);
	if (catch fresh) return false;

	if (self.animating && self.current_ref.pack == which) self.stop_animation();
	self.packs[(usz)which].free(mem);
	self.packs[(usz)which] = fresh;

	// The array is the same length, so nothing else would notice: this pack's
	// skeleton and names have been replaced under a reach measured against the old
	// ones. See `AppState.pack_reach`.
	self.reach_stale = true;

	// What the pack says it is may have changed, and the reference plans are made
	// of exactly that. Derived from the packs in memory, so this costs no reading.
	self.rebuild_reference_plans();
	self.plan_targets_stale = true;
	if (affected) self.restore_library_refs(&refs);
	return true;
}

// The library card's name for the pack agent-written clips go into.
const String AUTHORED_PACK_NAME = "Authored";

<*
 Take a pack into the library, at the end.

 Ownership passes: the pack is freed with the rest of the library, so what it
 points at has to be allocated from `mem` with `owned` set.

 Reallocates the pack array, so every `AnimPack*` taken before this call is
 dangling after it — including one being iterated over. Clips are not moved: a
 pack's `clips` is its own allocation, so `AnimTemplate*` and `AnimRef` both
 survive.

 @return `Its index.`
*>
fn usz AppState.adopt_pack(&self, AnimPack pack)
{
	// A zeroed List grows from tmem, so it is given `mem` on the first pack.
	if (!self.packs.is_initialized()) self.packs.init(mem);
	self.packs.push(pack);

	// One more pack to measure against the rig — see `AppState.pack_reach`.
	self.reach_stale = true;
	return (usz)self.packs.len() - 1;
}

// Free every pack and empty the list.
fn void AppState.drop_packs(&self)
{
	foreach (&pack : self.packs) pack.free(mem);
	self.packs.free();
}

<*
 The pack authored clips live in, or null when nothing has written one yet.
*>
fn AnimPack* AppState.authored(&self)
{
	return self.authored_pack < 0 ? null : self.pack((usz)self.authored_pack);
}

<*
 The authored pack, created on the spot if this is the first write. Never null.

 Carries no plan tag, so its clips are offered to every rig rather than to one
 body plan — see `pack_matches`. A clip written here was written against the rig
 on screen, which is the only rig it claims to fit.

 Reallocates the pack array on the call that creates it; see `adopt_pack`.
*>
fn AnimPack* AppState.ensure_authored(&self)
{
	AnimPack* existing = self.authored();
	if (existing) return existing;

	self.authored_pack = (int)self.adopt_pack({
		.name = AUTHORED_PACK_NAME.copy(mem),
		.version = PACK_VERSION,
		.owned = true,
	});
	return &self.packs[(usz)self.authored_pack];
}

<*
 Exchange the authored pack's clip of this name for the one given, handing back
 whatever was there.

 	`AnimTemplate was = app.swap_authored_clip("Walk", built);`

 The whole of a clip write in one function, and deliberately **self-inverse**:
 putting back what came out undoes the call exactly, so a history step does not
 need a forward version and a backward one that have to be kept in step. An
 **empty template is "no clip of this name"** on either side — putting one in
 removes the clip, and taking one out of a pack that does not have it gives one
 back. So a delete is this with an empty going in, and a first write is this with
 an empty coming back.

 **Ownership passes both ways, and nothing is copied.** The template handed in
 must be allocated from `mem` with `owned` set; the caller owns whatever comes
 back and is the one that frees it. At every instant a template is owned by
 exactly one of the pack and its caller, which is the property that lets the undo
 stack park one indefinitely without the pack ever freeing it underneath.

 When the clip being displaced is the one playing, the player is stopped first
 and restarted where it left off. That is not a nicety: `current_anim` is a copy
 pointing into the keyframes about to leave the pack, so leaving the player alone
 would run it over memory the caller is free to release the moment this returns.

 @param name : `The clip to exchange. Borrowed for the call only.`
 @param clip : `What to put there; an empty template removes the clip instead.`
 @param landed : `Where the clip put in ended up, if given. Left NO_ANIM by a removal.`
 @return `What was there, or an empty template when nothing was. The caller's to free.`
*>
fn AnimTemplate AppState.swap_authored_clip(&self, String name, AnimTemplate clip, AnimRef* landed = null)
{
	bool putting = clip.name.len > 0;
	self.authored_dirty = true;

	AnimPack* pack = self.authored();
	// Nothing to take out and nothing a removal could be recorded in. Creating the
	// pack here would leave an empty one behind for a call that did nothing.
	if (!pack && !putting) return {};
	if (!pack) pack = self.ensure_authored();

	int at = -1;
	foreach (usz i, held : pack.clips)
	{
		if (held.name == name)
		{
			at = (int)i;
			break;
		}
	}

	if (at < 0)
	{
		if (!putting) return {};
		if (landed) *landed = { self.authored_pack, (int)pack.clips.len };
		self.append_authored(pack, clip);
		return {};
	}

	AnimRef ref = { self.authored_pack, at };
	bool watched = self.animating && self.current_ref.same(ref);
	bool paused = self.anim_paused;
	float resume = self.anim_time;
	if (watched) self.stop_animation();

	AnimTemplate had = pack.clips[(usz)at];
	if (putting)
	{
		pack.clips[(usz)at] = clip;
		if (landed) *landed = ref;
	}
	else
	{
		self.remove_authored(pack, (usz)at);
	}

	// Only when there is still a clip there to play. A removal leaves the player
	// stopped, which is the whole point of having stopped it.
	if (watched && putting && self.start_animation_ref(ref))
	{
		self.anim_time = math::clamp(resume, 0.0f, clip.duration);
		self.anim_paused = paused;
		if (self.current_ref.same(self.editing)) self.edit_time = self.anim_time;
		self.refresh_animation();
	}
	return had;
}

// Grow the pack by one and put the clip on the end. Nothing else moves, so no
// `AnimRef` into this pack goes stale.
fn void AppState.append_authored(&self, AnimPack* pack, AnimTemplate clip)
{
	usz count = pack.clips.len;
	AnimTemplate[] grown = alloc::new_array(mem, AnimTemplate, (sz)(count + 1));
	foreach (i, held : pack.clips) grown[i] = held;
	grown[count] = clip;
	if (count > 0) alloc::free(mem, pack.clips);
	pack.clips = grown;
}

<*
 Take the slot out of the pack and close the gap. The template itself is the
 caller's problem — this only unhooks it.

 Every `AnimRef` into this pack past the gap shifts down by one. The player's is
 the one crig holds across the call, so it is the one fixed here; refs into other
 packs are untouched, since the pack's own index does not move.
*>
fn void AppState.remove_authored(&self, AnimPack* pack, usz at)
{
	usz count = pack.clips.len;
	AnimTemplate[] left = count > 1 ? alloc::new_array(mem, AnimTemplate, (sz)(count - 1)) : (AnimTemplate[]){};
	usz kept = 0;
	foreach (usz i, held : pack.clips)
	{
		if (i == at) continue;
		left[kept++] = held;
	}
	alloc::free(mem, pack.clips);
	pack.clips = left;

	if (self.current_ref.pack == self.authored_pack && self.current_ref.clip > (int)at)
	{
		self.current_ref.clip--;
	}
	if (self.editing.pack == self.authored_pack)
	{
		if (self.editing.clip == (int)at) { self.editing = NO_ANIM; }
		else if (self.editing.clip > (int)at) self.editing.clip--;
	}
}

<*
 Put a clip into the authored pack, replacing any clip of the same name.

 	`AnimRef ref = app.put_authored_clip(template);`

 Ownership passes: the template must be allocated from `mem` with `owned` set.
 A replaced clip is **not** freed — it goes to the undo stack, which frees it
 when the history that could bring it back is discarded.

 Records unconditionally, and there is deliberately no non-recording twin: a
 second way into the pack would be a second way for the stack's parked template
 to stop being what is really there. The caller closes the group — see
 `tool_apply_clip`.

 @param replaced : `Set to whether a clip of this name was already there, if given.`
 @return `Where the clip landed, or NO_ANIM for an empty template, which writes nothing.`
*>
fn AnimRef AppState.put_authored_clip(&self, AnimTemplate clip, bool* replaced = null)
{
	// Taken before the swap, while the template is still the caller's. After it
	// the same bytes are the pack's, which is just as alive but no longer ours to
	// reason about.
	String name = clip.name;
	if (name.len == 0)
	{
		if (replaced) *replaced = false;
		return NO_ANIM;
	}

	AnimRef landed = NO_ANIM;
	clip.compile_tracks(mem);
	AnimTemplate had = self.swap_authored_clip(name, clip, &landed);
	// Clip replacement can also come from MCP/import, not only land_clip.
	// Group edits restore their transformed selection after landing; other
	// replacements must not leave selected times pointing at unrelated poses.
	self.clear_animation_key_selection();
	if (replaced) *replaced = had.name.len > 0;
	self.undo_stack.record_clip_swap(name.copy(mem), had);
	return landed;
}

<*
 Author a clip into the pack *and* bind it as an editable timeline clip.

 `put_authored_clip` alone is enough to *play* a clip, not to edit or pause one.
 A clip written to the pack but never bound into the document is invisible to
 the timeline: it is absent from the clip chooser and the Animations list,
 cannot be selected, and the transport's Play/Pause keeps controlling whichever
 clip *is* loaded there — so pausing a played-but-unbound clip snaps the mesh
 back to the loaded one. That is the trap every MCP-authored clip fell into.

 So this pairs the pack write with the binding half of `land_clip` and makes the
 result the editing clip, exactly as the timeline's own New clip does: the clip
 lands in `doc.animations`, shows up in the chooser, and `current_ref` (set by a
 later `play`) can match `editing`, which is what the transport's pause branch
 tests. The pack swap and the binding are one undo step.

 @param replaced : `Set to whether a clip of this name was already in the pack.`
 @return `The clip's authored ref, or NO_ANIM for a nameless clip.`
*>
fn AnimRef AppState.author_clip(&self, AnimTemplate clip, bool* replaced = null)
{
	String named = clip.name.copy(mem);
	defer named.free(mem);

	AnimRef landed = self.put_authored_clip(clip, replaced);
	if (!landed.valid()) return NO_ANIM;

	// Only when it is not already a timeline clip: re-authoring one that is
	// already bound must not add a second row for it.
	if (self.doc.bound_index("", named) < 0)
	{
		uint at = (uint)self.doc.animations.len();
		BoundClip parked = self.doc.swap_bound(at, owned_binding("", named));
		self.undo_stack.record_binding_swap(at, parked, owned_binding("", named));
	}
	self.undo_stack.commit();
	self.editing = landed;
	return landed;
}

<*
 Take a clip out of the authored pack.

 	`if (app.delete_authored_clip("Probe")) { … }`

 Only the authored pack, and deliberately: every other pack is a file, and
 removing a clip from one would mean rewriting it — a different operation, with a
 different failure mode, that a caller has to ask for by name. The authored pack
 is in memory and holds exactly what this session put there, which is also where
 the scratch clips accumulate that `save_pack` would otherwise ship.

 The removed clip goes to the undo stack rather than being freed, so undo puts
 back the clip itself and not a reconstruction of it. The caller closes the
 group — see `tool_delete_clip`.

 @return `False when there is no authored pack or no clip of that name.`
*>
fn bool AppState.delete_authored_clip(&self, String name)
{
	AnimTemplate had = self.swap_authored_clip(name, {});
	if (had.name.len == 0) return false;
	// Removal shifts numeric clip references, including selections in other clips.
	self.clear_animation_key_selection();
	self.undo_stack.record_clip_swap(name.copy(mem), had);
	// A deleted project clip must not leave a missing binding behind. Keep the
	// removal in the same transaction so undo restores both clip and membership.
	sz row = self.doc.bound_index("", name);
	if (row >= 0)
	{
		BoundClip removed = self.doc.swap_bound((uint)row, {});
		self.undo_stack.record_binding_swap((uint)row, removed, {});
	}

	// A card open on the authored pack is showing a row that has gone, and the
	// selection below it has shifted; both are the library card's to redraw.
	self.refresh_ui();
	return true;
}

<*
 The authored clips a sidecar keeps: the ones the character still holds.

 	`AnimTemplate[] kept = app.kept_authored_clips(mem);`

 The Animations pane lists only bound clips, so an authored clip with no row is
 one nobody can see, play or delete — un-bound, or deleted from the asset
 browser by a build that only un-bound it. Writing it anyway carried its keys
 (megabytes for a generated clip) into every save forever. In memory it stays,
 so Ctrl+Z on the un-bind still has its clip this session.

 The array is the caller's; the templates in it are the pack's, borrowed.
*>
fn AnimTemplate[] AppState.kept_authored_clips(&self, Allocator allocator)
{
	AnimPack* pack = self.authored();
	if (!pack) return {};
	AnimTemplateList out;
	out.init(allocator);
	defer out.free();
	foreach (clip : pack.clips)
	{
		if (self.doc.bound_index("", clip.name) >= 0) out.push(clip);
	}
	return out.len() > 0 ? out.to_array(allocator) : (AnimTemplate[]){};
}

<*
 What body a saved pack carries.

 A pack with none plays but can never be fitted as a body plan: `AnimPack.preset`
 normalises each joint into the body mesh's own bounding box, and with no body
 there is no box to measure against. That is the whole of what the offline pack
 builder could do and the wire could not, until this.

 NONE writes none, which is what every save did before this existed. It does not
 carry across the body of a pack being written over, tempting as that is: the
 skeleton in the file is the rig that is loaded now, and a body kept from an
 earlier save was shaped around whatever rig was loaded then. A pack whose body
 and skeleton disagree normalises its joints against the wrong box, which is a
 worse failure than having no body at all because it still looks like a plan.
*>
enum PackBody
{
	NONE,
	DUMMY,
	MESH,
}

faultdef PACK_NOTHING_TO_SAVE, PACK_RIG_UNNAMED, PACK_NO_LIBRARY;
// Declared here rather than borrowed from the MCP surface: `survey_weights` is
// AppState's, and every target that builds src/app/ has to be able to name what it
// returns whether or not it builds a socket.
faultdef WEIGHTS_NO_RIG, WEIGHTS_NO_SUCH_DOT;

<*
 Publish the authored clips into an animation library pack, then read that disk
 pack back while retaining the project-owned authored copies.

 	`int saved = app.save_authored_pack("walk_set.glb", "Walk set", "biped")!;`

 The authored and published packs may contain the same names without ambiguity:
 every live reference is pack-qualified. Reading back verifies and exposes the
 disk pack; editing and playback remain on the authored project copy.

 Every `AnimPack*`, `AnimTemplate*` and `AnimRef` taken before this call is
 dangling after it: the whole library is freed and re-read.

 **Saving into a pack that already exists adds to it.** The file is rewritten
 from its own clips plus the authored ones, which replace any of the same name —
 the rule `put_authored_clip` follows one level down. Writing only the authored
 clips would mean a second save silently discarding everything the first one
 saved, and there is no undo behind this. Its plan, tags and optional joints are
 carried across for the same reason, so a re-save cannot quietly untag a pack or
 start placing its fingers onto every model. A body is *not*:
 `body` decides what this file carries, and it defaults to none — so a pack that
 has one must not be saved over without asking for one. See `PackBody`, and
 `AnimPack.is_body_plan`, which the caller is expected to check.

 **A body with no clips is a body plan, and is written.** Fitting a plan onto a
 fresh model reads the pack's skeleton and its body and never looks at its clips,
 so a rig placed by hand on a model is already the whole of one — requiring a
 clip first would mean authoring an animation for a figure nobody has animated
 yet, purely to get the plan written. What is still refused is a save that would
 hold neither: no authored clip and no body.

 @param file : `The file name to write inside the library folder, with its extension.`
 @param display : `The pack's name in the library. Empty falls back to the file stem.`
 @param plan : `Body-plan tag, or empty for a pack offered to every rig.`
 @param tags : `Written as the pack's tags. Pass an existing pack's own to keep them.`
 @param body : `Which body the file carries. NONE keeps whatever the pack being written over had; see PackBody.`
 @param optional : `Joint names a plan fitted from this pack may leave unplaced — the fingers, and anything else no mesh's proportions say the position of. Borrowed; only read. Empty marks none, which means every joint is placed on every model the plan is fitted to.`
 @require self.library_path.len != 0 : "Pack has no library"
 @return `The saved pack's index in the reloaded library, or -1 when the file could not be read back.`
 @return? PACK_NOTHING_TO_SAVE : `No clip has been authored and no body was asked for, so the file would hold nothing to play and nothing to fit.`
 @return? PACK_RIG_UNNAMED : `The rig is empty, or a dot has no name — a pack addresses joints by name and could carry none for it.`
 @return? PACK_NO_LIBRARY : `The library has never been read, so there is no folder to write into.`
*>
fn int? AppState.save_authored_pack(&self, String file, String display, String plan, String[] tags = {}, PackBody body = NONE,
	String[] optional = {})
{
	// Null when nothing has ever been authored, which is the ordinary state of a
	// rig placed by hand — and a perfectly good pack when a body is going with it.
	AnimPack* pack = self.authored();
	AnimTemplate[] fresh_clips = pack ? pack.clips : (AnimTemplate[]){};
	if (fresh_clips.len == 0 && body == NONE) return PACK_NOTHING_TO_SAVE~;

	RigView? opened = self.open_rig(mem);
	if (catch opened) return PACK_RIG_UNNAMED~;
	RigView view = opened;
	defer view.free(mem);

	// Every joint must be named, unlike everywhere else the names are read: a
	// clip addresses joints by name, so a blank one is a bone no clip in this pack
	// could ever reach.
	foreach (name : view.names)
	{
		if (name.len == 0) return PACK_RIG_UNNAMED~;
	}

	String path = string::format(mem, "%s/%s", self.library_path, file);
	defer alloc::free(mem, path.ptr);

	// What the file will hold: whatever the pack of that name already holds, then
	// the authored clips, which stand in for any of the same name. Borrowed on
	// both sides — the writer only reads them, and the library still owns them.
	AnimPack* standing = null;
	foreach (&held : self.packs)
	{
		if (held.path == path) standing = held;
	}

	usz room = fresh_clips.len + (standing ? standing.clips.len : 0);
	// `new_array` of nothing is a valid empty slice, which is what a body-only
	// save writes — the writer takes no clips and the file carries none.
	AnimTemplate[] writing = alloc::new_array(mem, AnimTemplate, (sz)room);
	defer alloc::free(mem, writing);

	usz held_count = 0;
	if (standing)
	{
		foreach (kept : standing.clips)
		{
			bool superseded = false;
			foreach (fresh : fresh_clips)
			{
				if (fresh.name == kept.name) superseded = true;
			}
			if (!superseded) writing[held_count++] = kept;
		}
	}
	foreach (fresh : fresh_clips) writing[held_count++] = fresh;

	// A generated stand-in is this call's to make and to release; the loaded mesh
	// and a standing pack's own are borrowed, and the writer only reads them.
	rig::TriMesh generated = {};
	defer generated.free(mem);
	if (body == DUMMY) generated = dummy_body(mem, &view.skeleton, {});

	rig::TriMesh carried = {};
	switch (body)
	{
		// Explicit rather than left empty: an empty case falls through to the next.
		case NONE: carried = {};
		case DUMMY: carried = generated;
		case MESH: carried = self.geometry;
	}

	// The rig's jiggle setup rides with it, resolved against this build's joint
	// order — a pack is the rig as much as it is the clips, and a tail that stops
	// wobbling when its pack is reopened is work silently lost.
	float[] radii = self.jiggle_radii(&view);
	defer if (radii.len > 0) alloc::free(mem, radii);
	RigPhysics physics = rig_physics_of(mem, &self.doc, &view.skeleton, view.dot_ids, radii);
	defer physics.free(mem);
	ConstraintRig constraints = constraint_rig_of(mem, &self.doc, &view.skeleton, view.dot_ids);
	defer constraints.free(mem);
	// Only the loaded target mesh has authored weights to preserve. A generated
	// diagram body gets a fresh geometric bind against its own vertices inside
	// the writer, and a body-less pack has no hulls to generate.
	float[] physical_skin = {};
	if (body == MESH && constraints.present())
	{
		physical_skin = self.bind_dense(mem, &view);
	}
	defer if (physical_skin.len > 0) alloc::free(mem, physical_skin);

	export_pack_glb(mem, path, &view.skeleton, view.names, writing[:held_count], carried, {
		.plan = plan,
		.name = display,
		.tags = tags,
		.optional = optional,
	}, physics, constraints, physical_skin)!;

	// Publishing writes a library copy; it does not spend the project-owned
	// authored clips. `load_packs` carries them across the re-read, keeping empty-
	// file bindings and editing references resolvable. The disk pack may contain
	// clips with the same names, but references remain pack-qualified.
	self.load_packs(self.library_path);

	int saved = -1;
	foreach (usz i, read : self.packs)
	{
		if (read.path == path) saved = (int)i;
	}
	if (saved < 0) return -1;

	self.expanded_pack = saved;

	return saved;
}

<*
 The pack at `index`, or null when there is none.
*>
fn AnimPack* AppState.pack(&self, usz index)
{
	if ((sz)index >= self.packs.len()) return null;
	return &self.packs[(sz)index];
}

<*
 The pack the library is showing, or null when there are none.
*>
fn AnimPack* AppState.active_pack(&self) => self.expanded_pack < 0 ? null : self.pack((usz)self.expanded_pack);

<*
 How many clips the shown pack holds. Zero when there is no pack at all, which
 is the empty library the view has to draw something for.
*>
fn usz AppState.pack_clip_count(&self)
{
	AnimPack* pack = self.active_pack();
	return pack ? pack.clips.len : 0;
}

<*
 The clip a reference names, or null when it names nothing.

 Borrowed from the library, which owns it — a copy taken out of here is a copy
 that does not own what it points at, the same bargain `current_anim` makes.
*>
fn AnimTemplate* AppState.clip(&self, AnimRef ref)
{
	if (ref.pack < 0 || ref.pack >= self.packs.len()) return null;
	AnimPack* pack = &self.packs[(usz)ref.pack];
	if (ref.clip < 0 || (usz)ref.clip >= pack.clips.len) return null;
	return &pack.clips[(usz)ref.clip];
}

<*
 Read a deferred clip's curves the first time it is actually sampled.

 A pack loaded to bind a clip stubs all of them — name and length only — and
 leaves the retarget, the costly part, for here. This turns the stub into the
 real template in place, so every `clip(ref)` handed out afterwards is complete.
 The pack kept the parsed file open exactly so this does not re-open it.

 Called at the seams a clip becomes something to sample — play, timeline edit,
 export, the MCP pose tools — and a no-op for a clip already read or a pack that
 was loaded eagerly. Returns false only when the source cannot be read, which a
 lazily-stubbed pack answers the same way an eager one would have at load.
*>
fn bool AppState.ensure_clip_imported(&self, AnimRef ref)
{
	if (ref.pack < 0 || ref.pack >= self.packs.len()) return false;
	AnimPack* pack = &self.packs[(usz)ref.pack];
	if (ref.clip < 0 || (usz)ref.clip >= pack.clips.len) return false;
	AnimTemplate* stub = &pack.clips[(usz)ref.clip];
	if (!stub.lazy) return true;
	if (!pack.stream_held) return false;

	Preset[] matched = (pack.plan_match >= 0 && (usz)pack.plan_match < self.reference_plans.len)
		? self.reference_plans[(usz)pack.plan_match : 1]
		: (Preset[]){};
	AnimImportOptions naming = {
		.plans = matched,
		.keep_source_names = pack.plan_match < 0,
		.index = stub.source,
	};
	AnimTemplate? one = import_animation(mem, &pack.stream, naming);
	if (catch one) return false;
	// The pack's `extras.clips` settings — blend, loop, ground, the authored key
	// schedule — were applied to the stub at read time, and the stub is about to go.
	// Put them on the real template too, or a deferred clip comes back linear,
	// looping and ungrounded.
	if (pack.version <= PACK_VERSION)
	{
		if (try String settings = pack.stream.gltf.extras.get(PACK_KEY_CLIPS))
		{
			AnimTemplate[1] only = { one };
			apply_clip_extras(mem, only[..], settings);
			one = only[0];
		}
	}
	one.compile_tracks(mem);
	// The stub owned only its name; free it and put the real template in its slot,
	// keeping the address `clip(ref)` already handed out valid.
	stub.free(mem);
	*stub = one;
	return true;
}

<*
 Whether this pack's clips are meant for this rig.

 Two levels, and each answers what it can see. This one is about the pack: a rig
 that declares a body plan is offered the packs declaring the same one, and
 nothing else. `clip_flags` is the level below, about a single clip, and it is
 the whole answer for a rig that declares nothing.

 An untagged pack matches everything, which is what keeps every .glb written
 before packs existed playable. A rig that declares nothing is offered
 everything, and sorted out one clip at a time by the names it has in common.
*>
fn bool AppState.pack_matches(&self, usz index)
{
	AnimPack* pack = self.pack(index);
	if (!pack) return false;
	if (pack.plan.len == 0 || self.doc.plan.len == 0) return true;
	return self.doc.plan == pack.plan;
}

<*
 Whether any dot in the document carries this name.
*>
fn bool AppState.has_dot_named(&self, String name)
{
	foreach (dot : self.doc.dots.array_view())
	{
		if (dot.name == name) return true;
	}
	return false;
}

<*
 What this pack's clips can reach on the open rig, derived if it has not been or
 has gone stale.

 	`PackReach* reach = app.pack_reach((usz)ref.pack);`

 The one door to `measure_reach`, and the reason there is a door: the shape match
 behind it costs a few milliseconds per pack, `clip_applies` is asked once per
 visible cell per frame, and a rig edit is the only thing that can change the
 answer. So the whole library is measured in one pass — seven milliseconds
 against the shipped folder — and held until `reach_stale` says otherwise.

 Borrowed, and only until the next rig edit. Null when there is no such pack.
*>
fn PackReach* AppState.pack_reach(&self, usz index)
{
	if ((sz)index >= self.packs.len()) return null;

	// The length check is not belt and braces over the flag: `adopt_pack` appends
	// and `load_packs` replaces, and neither is a rig edit.
	if (self.reach_stale || self.pack_reaches.len != self.packs.len()) self.rebuild_pack_reaches();
	if (index >= self.pack_reaches.len) return null;
	return &self.pack_reaches[index];
}

<*
 Measure every pack against the open rig at once.

 One `open_rig` for the whole library rather than one per pack, which is most of
 what this costs: building the skeleton walks the document, and the packs are all
 being asked about the same one.
*>
fn void AppState.rebuild_pack_reaches(&self)
{
	self.free_pack_reaches();
	self.reach_stale = false;
	if (self.packs.len() == 0) return;

	self.pack_reaches = alloc::new_array(mem, PackReach, (sz)self.packs.len());

	RigView? opened = self.open_rig(mem);
	// An empty document has no rig to measure against, and that is an ordinary
	// state rather than a failure — every entry stays unusable, and `clip_playable`
	// has its own answer for a library offered to a document with no dots.
	if (catch opened) return;
	RigView view = opened;
	defer view.free(mem);

	foreach (usz i, &pack : self.packs)
	{
		self.pack_reaches[i] = measure_reach(mem, pack, &view.skeleton, view.names);
		apply_joint_maps(mem, &self.pack_reaches[i], pack, view.names, self.doc.joint_maps);
	}
}

fn void AppState.free_pack_reaches(&self)
{
	foreach (&reach : self.pack_reaches) reach.free(mem);
	if (self.pack_reaches.len > 0) alloc::free(mem, self.pack_reaches);
	self.pack_reaches = {};
}

<*
 Whether this clip would move the rig as it stands: the pack is one this rig can
 take, its skeleton is one this rig relates to, and the clip keys something the
 rig answers to.

 Three levels now, and all of them have to hold. `pack_matches` is the tag; the
 reach is the shape; the loop below is the clip.

 **The shape level used to be missing, and its absence was silent.** The test was
 one joint name in common, so a Mixamo dance keying sixty-five joints on a rig
 that happened to share six of the spellings read as playable, ran, and moved a
 toe. `JointMatch.usable` — two thirds of the pack's required joints — is the
 line between a clip that will be partial and a clip that is for another animal,
 and how partial it will be is `reach_gaps`, said in a notice rather than hidden
 in a greyed cell.

 A clip that fails this is not necessarily out of reach: see `play_clip`, which
 fits a rig out of the pack when there is none.
*>
fn bool AppState.clip_applies(&self, AnimRef ref)
{
	AnimTemplate* anim = self.clip(ref);
	if (!anim) return false;
	if (!self.pack_matches((usz)ref.pack)) return false;

	PackReach* reach = self.pack_reach((usz)ref.pack);
	if (!reach || !reach.usable) return false;

	// A deferred stub has no keyframes to test yet. Offer it — the same answer a
	// clip in a not-yet-loaded pack gets — and let playback settle whether it fits
	// once it is read, rather than reading the whole file here in the grid's paint.
	if (anim.lazy) return true;

	foreach (kf : anim.keyframes)
	{
		foreach (kd : kf.dots)
		{
			if (reach.answers(kd.joint_name)) return true;
		}
	}
	return false;
}

<*
 Whether clicking this clip would do anything — what the library greys on.

 Either it plays on the rig as it stands, or the document is empty and the pack
 carries a body plan to fit one from. Everything else is a cell worth greying
 out rather than one that plays and appears to do nothing.
*>
fn bool AppState.clip_playable(&self, AnimRef ref)
{
	if (self.clip_applies(ref)) return true;
	if (self.doc.dots.len() > 0) return false;

	AnimPack* pack = self.clip(ref) ? self.pack((usz)ref.pack) : null;
	return pack != null && pack.is_body_plan();
}

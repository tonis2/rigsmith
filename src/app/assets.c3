<*
 The asset browser's model: everything in every library, narrowed to what is on
 screen.

 The index is `core/assets.c3` — one `gltf::open` per file, reading the JSON
 chunk and nothing else, so a library of three hundred files costs three hundred
 header reads and no geometry. This file is the state over it: which kinds are
 collapsed in the sidebar, which category and search the grid is filtered to,
 and which rows survive that filter.

 **Indexing is not loading.** A cell in the grid is a row of the index; clicking
 one is what makes `pack_for_file` read the whole file. That is the difference
 between a browser that opens instantly and one that reads the library twice at
 startup, and it is why `ref_for_asset` exists — to turn a row back into
 something `library.c3` can resolve to a real clip.

 Three things are replaced as one by `rescan_assets`: the index, the sidebar's
 categories and the chooser's library labels. A sidebar offering a category the
 index no longer holds is a row that selects nothing.

 The widgets that draw all this are `ui/asset_browser.c3`.
*>
module crig;

import gltf_edit;
import cui;
import cui::widgets;



<*
 Rebuild the index, the sidebar and the chooser's options together.

 The three are one reading of the libraries and are replaced as one: a sidebar
 offering a category the index no longer holds is a row that selects nothing.
*>
fn void AppState.rescan_assets(&self)
{
	free_assets(mem, self.assets);
	self.free_library_labels();

	self.assets = scan_assets(mem, self.config.libraries.array_view());
	// The scan wiped the loaded model's "Current file" entries with the rest; put
	// them back before the categories and the grid are rebuilt below.
	self.assets.set_current_model(mem, self.source_path);
	self.refresh_categories();
	self.selected_asset = -1;

	// "All libraries" first, so the chooser's index is one past the position in the
	// configured list and the entry at 0 is the filter that names none of them.
	AssetLibrary[] libraries = self.config.libraries.array_view();
	String[] labels = alloc::new_array(mem, String, (sz)libraries.len + 1);
	labels[0] = ALL_LIBRARIES_LABEL.copy(mem);
	foreach (usz i, library : libraries)
	{
		labels[i + 1] = library.name.len > 0 ? library.name.copy(mem) : UNNAMED_LIBRARY_LABEL.copy(mem);
	}
	self.library_labels = labels;

	self.refresh_visible_assets();
}

<*
 Rebuild the sidebar's categories from the index and what is closed.

 Split out of `rescan_assets` because closing a category changes which rows there
 are without changing what is in the libraries, and rereading every file to
 answer a disclosure triangle would stall the frame on the click.

 The array is owned; the labels in it are borrowed from `assets` and from string
 literals, so the old array is freed but nothing in it is.
*>
fn void AppState.refresh_categories(&self)
{
	self.mark_current_entries();
	if (self.asset_categories.len > 0) alloc::free(mem, self.asset_categories);
	self.asset_categories = self.assets.categories(mem, self.collapsed_kinds[..]);
}

<*
 Mark every index entry that came from the loaded model's own file.

 What the "Current file" group reads. Kept here rather than on the entries as they
 are read, because which file is current changes without the index changing — a
 model opened, a save that retargets it aside — and this runs from
 `refresh_categories`, which follows every scan, retag, reindex and delete. A model
 that is itself a library file has its own rows marked, which is why
 `set_current_model` need not inject a second copy for it.
*>
fn void AppState.mark_current_entries(&self)
{
	foreach (&entry : self.assets.entries)
	{
		entry.current = self.source_path.len > 0 && entry.file == self.source_path;
	}
}

<*
 Refresh the "Current file" group after the loaded model or its clips change.

 The model's own animations become a browser group even when it was opened from
 outside every configured library: `set_current_model` reads them straight from the
 file as sentinel entries, or leaves a library model its own rows (which
 `mark_current_entries` then marks). Call on open, import, save and delete.

 Every position into the index moves, since it re-sorts around the model's clips —
 so the selected cell and any open settings panel are reset, as `retag_asset` and
 `reindex_saved_model` reset them.
*>
fn void AppState.reindex_current_model(&self)
{
	self.assets.set_current_model(mem, self.source_path);
	self.refresh_categories();
	self.refresh_visible_assets();
	self.selected_asset = -1;
	self.settings_asset = -1;
	self.refresh_asset_sidebar();
}

<*
 Whether the sidebar is hiding this kind's body plans.

 @param kind : `The kind asked about.`
 @return `True when the kind is closed.`
*>
fn bool AppState.kind_collapsed(&self, AssetKind kind)
{
	return self.collapsed_kinds[kind.ordinal];
}

<*
 Open or close one kind in the sidebar.

 Rebuilds the categories but not the tree drawing them, which borrows an array
 this replaces — the caller owes `refresh_asset_sidebar` before the next paint.

 @param kind : `The kind whose plan rows are being shown or hidden.`
 @param collapsed : `True to hide them.`
*>
fn void AppState.set_kind_collapsed(&self, AssetKind kind, bool collapsed)
{
	if (self.collapsed_kinds[kind.ordinal] == collapsed) return;
	self.collapsed_kinds[kind.ordinal] = collapsed;

	// The row that is about to disappear cannot stay the one narrowing the grid:
	// closing "Animations" while "biped" under it is chosen would leave the grid
	// showing biped clips with no row saying why. Widen to the kind, which is the
	// row that stays and the one that then lights up.
	if (collapsed && !self.asset_filter.any_plan
		&& !self.asset_filter.any_kind && self.asset_filter.kind == kind)
	{
		AssetFilter widened = self.asset_filter;
		widened.any_plan = true;
		widened.plan = "";
		self.set_asset_filter(widened);
	}

	self.refresh_categories();
}

<*
 Redraw the browser's sidebar after the set of rows in it has changed.

 Not part of `refresh_ui`, and not a repaint. The `Tree` borrows
 `category_rows`, and the only thing that fills that array is the pane's own
 build — so a sidebar told to paint after the categories moved draws from an
 array that has been freed, and one told nothing draws the rows it had. Closing
 a category needs the build, which means asking the enclosing `AreaPane`: a Tree
 paints rather than builds, so it cannot be rebuilt on its own.

 Only panes actually showing the browser are asked, and this runs on a click
 rather than on every frame — `refresh_ui` is on the drag path and must not be
 throwing subtrees away.
*>
fn void AppState.refresh_asset_sidebar(&self)
{
	if (!self.ui) return;

	self.ui.@walk(; elem)
	{
		if (elem.has_id(ASSETS_TREE_ID))
		{
			for (Element* p = elem.parent; p != null; p = p.parent)
			{
				if (p.is_widget(AreaPane))
				{
					p.request_build();
					break;
				}
			}
		}
	};
}

// The chooser's first option: no library filter at all.
const String ALL_LIBRARIES_LABEL = "All libraries";

// What a library configured without a name is offered as. A blank row in a
// dropdown is a row nobody can tell from the one above it.
const String UNNAMED_LIBRARY_LABEL = "(unnamed)";

fn void AppState.free_library_labels(&self)
{
	foreach (label : self.library_labels) alloc::free(mem, label.ptr);
	if (self.library_labels.len > 0) alloc::free(mem, self.library_labels);
	self.library_labels = {};
}

<*
 Narrow the browser, if this is not already what it is showing.

 The comparison is the point: a build that recomputed the visible set every frame
 would hand the grid a new array of cells each time, and the cell under the
 pointer would lose its hover between the move and the click.

 @return `Whether anything changed, which is whether the grid has to be rebuilt.`
*>
fn bool AppState.set_asset_filter(&self, AssetFilter filter)
{
	if (self.asset_filter.same(filter)) return false;

	// The search text is borrowed from a field that is rebuilt with its dialog, so
	// the filter keeps its own copy rather than a pointer into a widget.
	String search = filter.search.trim().len > 0 ? filter.search.trim().copy(mem) : "";
	if (self.asset_filter.search.len > 0) alloc::free(mem, self.asset_filter.search.ptr);

	self.asset_filter = filter;
	self.asset_filter.search = search;
	self.refresh_visible_assets();
	return true;
}

// Reapply the current filter to the current index. Called when either changes.
fn void AppState.refresh_visible_assets(&self)
{
	if (self.visible_assets.len > 0) alloc::free(mem, self.visible_assets);
	self.visible_assets = self.assets.matching(mem, self.asset_filter);
}

<*
 The entry a position in `visible_assets` stands for, or null when out of range.

 The bounds check is not defensive dressing: a widget holds a row number across
 frames, and a rescan under it can leave that row past the end.
*>
fn AssetEntry* AppState.visible_asset(&self, usz row)
{
	if (row >= self.visible_assets.len) return null;
	usz which = self.visible_assets[row];
	if (which >= self.assets.entries.len) return null;
	return &self.assets.entries[which];
}

<*
 The entry the settings panel is open on, or null when it is not open.

 Bounds-checked against the index rather than trusted, for `visible_asset`'s
 reason: the panel holds a position across frames, and a rescan under it can
 leave that position past the end.
*>
fn AssetEntry* AppState.settings_entry(&self)
{
	if (self.settings_asset < 0) return null;
	if ((usz)self.settings_asset >= self.assets.entries.len) return null;
	return &self.assets.entries[(usz)self.settings_asset];
}

<*
 Rename an indexed item, and say what its file is for.

 The name is the item's own — the glTF animation's or skin's — and goes into the
 file beside it. The plan and the tags are the **file's**, in its root `extras`,
 because that is the only place glTF has for them: every item out of one file
 shares them, and the panel that calls this says so.

 Written where the file lies, through `gltf_edit::patch_gltf`, so nothing but the values
 named here changes and the binary chunk is not touched at all. An empty string
 removes its key rather than writing a blank one, so clearing a plan leaves a
 file that reads as untagged.

 **One file is re-read afterwards, not the library.** A rescan would reopen
 every .glb in every library at about seventy milliseconds apiece — fourteen
 seconds on a shelf of two hundred, to rename one clip. So the index replaces
 that file's entries alone and a pack already read from it is re-read into the
 slot it already occupies, which is what keeps every `AnimRef` pointing where it
 pointed.

 What that costs the caller: **every position into the index moves**, because
 the entries are re-sorted around the new name. The selected cell and the open
 settings panel are both reset here, and an `AssetEntry*` taken before this call
 is dangling after it.

 @param which : `A position in the whole index, not in the visible list.`
 @param name : `The item's own name. Empty removes it, and the browser falls back to the file stem.`
 @param plan : `The body-plan tag the whole file declares. Empty untags it.`
 @param tags : `Comma-separated, as typed; the readers split and fold them.`
 @return `Whether the file was written.`
*>
fn bool AppState.retag_asset(&self, usz which, String name, String plan, String tags)
{
	if (which >= self.assets.entries.len) return false;
	AssetEntry* entry = &self.assets.entries[which];

	// Copied before the re-read frees the index this points into — and `file` is
	// also what that re-read is keyed on, so it must not be the string being freed.
	String file = entry.file.copy(mem);
	defer alloc::free(mem, file.ptr);
	usz index = entry.index;
	int library = entry.library;
	String collection = entry.kind.gltf_collection();

	gltf_edit::JsonStep[2] plan_path = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = PACK_KEY_PLAN } };
	gltf_edit::JsonStep[2] tags_path = { { .key = gltf_edit::GLTF_EXTRAS }, { .key = PACK_KEY_TAGS } };
	gltf_edit::JsonStep[3] name_path = { { .key = collection }, { .at = index }, { .key = "name" } };

	gltf_edit::JsonEdit[3] edits = {
		{ .path = plan_path[..], .value = plan.trim() },
		{ .path = tags_path[..], .value = tags.trim() },
		{ .path = name_path[..], .value = name.trim() },
	};

	// A file that animates its nodes without binding a mesh has no item to
	// rename — the cell's name is the file stem. Its tags still go in.
	usz count = collection.len > 0 ? 3 : 2;

	if (catch fault error = gltf_edit::patch_gltf(mem, file, edits[:count]))
	{
		self.@notice("could not write %s: %s", file, error);
		return false;
	}

	self.assets.replace_file(mem, file, library);
	self.refresh_categories();
	self.refresh_visible_assets();

	// Both are positions into the index, and the index has just been re-sorted
	// around a name that changed.
	self.selected_asset = -1;
	self.settings_asset = -1;

	// A pack already read from that file is still holding the old name and the old
	// tags. Nothing else in the library changed, so nothing else is re-read.
	if (!self.reload_pack(file) && self.file_declares_plan(file))
	{
		// Nothing was loaded from it because it declared nothing when the library
		// was read, and it declares something now — so this is the file the
		// declared pass would have read whole. Read it the same way that pass does,
		// with no plans, since it names its own; otherwise the plan just typed in
		// would not be a plan the library offers until crig was restarted.
		AnimPack? fresh = read_pack(mem, file);
		if (try fresh)
		{
			self.adopt_pack(fresh);
			self.rebuild_reference_plans();
			self.plan_targets_stale = true;
		}
	}

	// The export panel's rows borrow from the entries that were just freed.

	// A tag changed is a sidebar row gained or lost, and the Tree borrows an array
	// `refresh_categories` has just replaced — so the pane owes a build before its
	// next paint, which nothing else here would ask for.
	self.refresh_asset_sidebar();
	self.@notice("%s written", file);
	return true;
}

<*
 Delete an animation from the loaded model on disk.

 Un-binds the clip and re-saves the model: since Save writes only the bound clips,
 dropping the binding drops the clip, and `reskin_glb` compacts the file it leaves.
 For an ANIMATION entry of the current model only — a library file is not this
 model's to rewrite, so the caller gates the action and this refuses anything else.

 Goes through `save_session`, the same path Ctrl+S takes, so owns-path, copy-aside,
 the sidecar write and the reindex all behave exactly as an ordinary save. A model
 that cannot take a skin in place (no mesh, a `.gltf` with an external `.bin`)
 leaves the clip in the file and `save_session` says so — the caller gates the
 button on `has_mesh`.

 @param which : `A position in the whole index, not the visible list.`
 @return `Whether this was a current-model animation it acted on.`
*>
fn bool AppState.delete_model_animation(&self, usz which)
{
	if (self.source_path.len == 0) return false;
	if (which >= self.assets.entries.len) return false;
	AssetEntry* entry = &self.assets.entries[which];
	if (entry.kind != AssetKind.ANIMATION || entry.file != self.source_path) return false;

	// Copied before the save moves the index this points into.
	String name = entry.name.copy(mem);
	defer name.free(mem);

	// Un-bind it if the character holds it — as a file binding, or as an authored
	// clip under the empty file. A clip in the file but never bound needs no un-bind;
	// the save drops it either way. Mirrors `anim_unbind_clicked`'s care for the clip
	// that happens to be the one open in the editor.
	sz at = self.doc.bound_index(self.source_path, name);
	if (at < 0) at = self.doc.bound_index("", name);
	bool editing = at >= 0 && self.resolve_bound(at).same(self.editing);
	if (editing)
	{
		self.stop_animation();
		self.clear_animation_key_selection();
		self.editing = NO_ANIM;
		self.edit_time = 0;
	}
	if (at >= 0) self.doc.unbind_at(at);

	// A clip authored here (generated, keyed) lives in the project's authored pack
	// as well as in the file, and the sidecar writes that pack whole — so un-binding
	// alone kept its keys, megabytes of them, beside a model that no longer has it.
	// Delete means gone: take it out of the pack too, one undo step.
	if (self.delete_authored_clip(name)) self.undo_stack.commit();

	// Rewrites the model without the clip; `save_session` reindexes the group.
	self.save_session();
	return true;
}

<*
 Re-read a just-saved model in the asset index, so an animation Save baked into it
 shows in the browser without a restart.

 	`self.reindex_saved_model(target);`

 Only a file under a configured library is in the browser at all, so only one
 there is re-read — and targeted with `replace_file` rather than a full
 `rescan_assets`, which reopens every file in every library and is the price the
 index exists to avoid. The match is by the spelling `read_library` gives what it
 finds, `"<library>/<name>"`, the same exact-string match `loaded_pack_for` uses;
 a model opened from outside every library is not in the browser and needs no
 refresh. Safe to call on every save: a file that matches no library does nothing.
*>
fn void AppState.reindex_saved_model(&self, String path)
{
	if (path.len == 0) return;
	String base = base_name(path);

	foreach (usz i, library : self.config.libraries.array_view())
	{
		if (library.path.len == 0) continue;
		String candidate = string::format(mem, "%s/%s", library.path, base);
		defer alloc::free(mem, candidate.ptr);
		if (candidate != path) continue;

		// The index holds this file under exactly `candidate`, so replace_file finds
		// the rows it had and reads the new ones in their place.
		self.assets.replace_file(mem, candidate, (int)i);
		self.refresh_categories();
		self.refresh_visible_assets();
		// Positions into the index moved when it re-sorted around the new clips.
		self.selected_asset = -1;
		self.settings_asset = -1;
		self.refresh_asset_sidebar();
		return;
	}
}

<*
 The glTF array an item of this kind lives in, or "" for a kind that is not one
 of them.

 What `gltf_edit::patch_gltf` needs to reach an item's own `name`. `JOINTS` is the empty
 one: it stands for a file that animates its nodes without binding a mesh to
 them, so there is no array entry holding the name a cell shows.
*>
fn String AssetKind.gltf_collection(self)
{
	switch (self)
	{
		case SKIN: return "skins";
		case ANIMATION: return "animations";
		case JOINTS: return "";
	}
}

<*
 The body plans a lazily-read file is matched against, taken from the packs that
 declared one.

 Derived here rather than at each read: it is the whole point of reading the
 declaring files eagerly. A file from another tool has its joints named in a
 plan's words only if there is a plan in hand to name them from.
*>
fn void AppState.rebuild_reference_plans(&self)
{
	self.free_reference_plans();

	PresetList references;
	references.init(mem);
	foreach (&pack : self.packs)
	{
		if (pack.is_body_plan()) references.push(pack.preset(mem));
	}
	self.reference_plans = references.to_array(mem);
	references.free();
}

fn void AppState.free_reference_plans(&self)
{
	foreach (plan : self.reference_plans) free_preset(mem, plan);
	if (self.reference_plans.len > 0) alloc::free(mem, self.reference_plans);
	self.reference_plans = {};
}

<*
 The pack already read from this file, or -1.

 The question `pack_for_file` asks first, and the one anything drawing a cell
 asks *instead* — working out whether a clip is playable means having the pack,
 and reading a file to decide how to paint it would load the whole library the
 first time the browser was scrolled.
*>
fn int AppState.loaded_pack_for(&self, String file)
{
	foreach (usz i, &pack : self.packs)
	{
		if (pack.path.len > 0 && pack.path == file) return (int)i;
	}
	return -1;
}

<*
 The pack for this file, reading it if it has not been read yet.

 The one door from an index entry to a loaded pack. A file read here is matched
 against `reference_plans`, so its joints come back named in the same words as
 one read by the declared pass — a clip named on one plan in one code path and on
 another elsewhere is the retargeting bug that reads as a limb bending backwards.

 Reallocates the pack array when it reads, so every `AnimPack*` taken before this
 call is dangling after it — the `adopt_pack` warning, which applies to every
 caller of this.

 @return `Its index, or -1 when the file will not open or holds nothing usable.`
*>
fn int AppState.pack_for_file(&self, String file)
{
	int already = self.loaded_pack_for(file);
	if (already >= 0) return already;

	// Clips deferred: this is the bind-and-play path, where the file is opened to
	// use one clip, not to convert all of them. Each is read on first sample — see
	// `ensure_clip_imported` — which is what keeps binding a clip out of an 8 MB
	// pack from retargeting its forty-odd siblings.
	AnimPack? read = read_pack(mem, file, plans: self.reference_plans, defer_clips: true);
	if (catch read) return -1;
	return (int)self.adopt_pack(read);
}

<*
 The clip in this pack that an index entry names.

 By name first. An entry's `index` is its position among the file's *glTF*
 animations and a pack's `clips` holds only the ones that converted, so the two
 agree until one clip is skipped and then never again.

 @return `A reference, or NO_ANIM when the pack holds no such clip.`
*>
fn AnimRef AppState.ref_for_asset(&self, int pack, AssetEntry* entry)
{
	AnimPack* held = self.pack((usz)pack);
	if (!held) return NO_ANIM;

	foreach (usz i, clip : held.clips)
	{
		if (clip.name == entry.name) return { pack, (int)i };
	}
	// Nothing of that name: the clip was renamed on the way in — retargeting names
	// joints, not clips, but an importer is free to — so fall back to the position
	// it would have had if nothing was skipped.
	if (entry.index < held.clips.len) return { pack, (int)entry.index };
	return NO_ANIM;
}

<*
 How a cell is drawn: greyed, lit as playing, or neither.

 Answered without reading the file wherever it can be. A clip in a pack that has
 not been loaded is neither playing — nothing unloaded can be — nor known to be
 unplayable, and is offered rather than greyed: whether it fits this rig is
 settled when the Animations pane is asked to play it, and greying it on a guess
 would hide clips that work.

 The lit state is a **report**, not a control. Nothing in the grid starts or stops
 playback any more (`activate_asset`), so a cell painted as playing is saying
 which of the library's clips is the one running — it is not an offer to stop it.

 @param row : `A position in the visible list; out of range greys.`
*>
fn MenuItemFlags AppState.asset_flags(&self, usz row)
{
	AssetEntry* entry = self.visible_asset(row);
	if (!entry) return { .disabled = true };

	// A rig is fitted to the model's own box, so there is nothing to fit one to
	// until a model is open.
	if (entry.kind != AssetKind.ANIMATION) return { .disabled = self.geometry.positions.len == 0 };

	int pack = self.loaded_pack_for(entry.file);
	if (pack < 0) return { };
	return clip_flags(self, self.ref_for_asset(pack, entry));
}

<*
 Do what clicking this cell means.

 A skin or a skeleton goes through the confirm rather than straight to the fit: it
 replaces every dot in the document, and it sits one cell away from things that
 do nothing at all.

 **A clip does nothing but come to the front.** It used to play, and the playing
 one stopped, which put the only way to start an animation in the pane that lists
 the library rather than in the pane that lists the character's own clips. That
 split is now the one the Animations pane's own comment describes: the grid is
 where a clip is *added to* a character — the + on the cell — and the Animations
 pane is where it is played, stopped, renamed and taken off. So the body of a clip
 cell moves the selection and stops there, and nothing is read off disk to do it.

 Every kind the index holds can be acted on — the two that could not are no
 longer indexed, see `AssetKind` — so what greys a cell here is the document
 rather than the item: no model to fit a rig to, or a clip that does not fit the
 rig standing in one. For a clip that greying is now a warning rather than a
 disabled control: it says this clip will not play on the rig you have, which is
 worth knowing *before* binding it, and the + keeps working either way.

 Reads the file if it has not been read, which reallocates the pack array — see
 `pack_for_file`.

 @param row : `A position in the visible list; out of range does nothing.`
 @return `Whether anything happened.`
*>
fn bool AppState.activate_asset(&self, usz row)
{
	AssetEntry* entry = self.visible_asset(row);
	if (!entry) return false;
	if (self.asset_flags(row).disabled) return false;

	usz which = self.visible_assets[row];

	if (entry.kind == AssetKind.ANIMATION)
	{
		if (self.selected_asset == (int)which) return false;
		self.selected_asset = (int)which;
		return true;
	}

	// Held before the pack array moves under it: `pack_for_file` reallocates, and
	// `entry` points into the index rather than into the packs, but the file name
	// is read again after the call.
	String file = entry.file;

	int pack = self.pack_for_file(file);
	if (pack < 0)
	{
		self.@notice("%s could not be read", file);
		return false;
	}
	self.selected_asset = (int)which;

	request_pack_rig(self.ui, pack);
	return true;
}

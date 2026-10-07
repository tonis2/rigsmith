<*
 The asset index: what the configured libraries hold, read from JSON alone.

 A library is a folder of glTF files, and a file is not the unit a person browses
 by — one `.glb` may carry a skin, half a dozen animations and a body mesh, and
 the thing they want is one of those, not the file around it. So the index is a
 flat list of **items**: one entry per skin, per skeleton, per animation, each
 naming the file it came from and its position inside it.

 **Nothing here loads a buffer.** `gltf::open` parses the JSON chunk and stops,
 and every number a browser cell shows is in that chunk — a skin's joint list and
 an animation's time range, from its input accessor's min/max. One open and one
 close per file, whatever the file weighs. That is what makes it affordable to
 index a folder of hundreds, and it is the whole reason this exists beside
 `scan_packs`, which reads everything and is now kept for the files that declare
 a body plan.

 What the index cannot know is the other half of that bargain. A body plan is
 read here only when the file **declares** one; inferring it from the shape of
 the skeleton is `match_stream`, which needs the rest pose and therefore the
 buffers. So a file from another tool is indexed as untagged and stays that way
 until it is loaded. Filling that in wants a cache keyed by path and mtime, which
 is not here yet.

 Lives in `core/` with no cui: the scan, the filter and the categories are all
 assertable with no window.
*>
module crig;

import gltf;
import std::collections::list;
import std::collections::map;


import std::io::path;
import std::sort;

<*
 Which of the things a glTF file can hold an entry stands for.

 **Only the kinds the browser can act on.** A file also holds materials, and they
 were indexed here once: cells that could be looked at and not clicked, under a
 heading a person had to learn was dead. Meshes were the same until a scene could
 hold more than one character; now a model is a thing to add to it, so it is a
 kind again — one entry per file that draws a body, not one per mesh, since a
 character is what the click brings in.

 First, so the shelf of things to add sits above the things to put on them.
*>
enum AssetKind : char
{
	MODEL,
	SKIN,
	JOINTS,
	ANIMATION,
}

<*
 What a kind is called in the sidebar and in a cell.

 Plural, because it heads a group — "Animations" over a column of them, which is
 the only place these are used.

 **Named for what clicking one does, not for what glTF calls it.** `SKIN` and
 `JOINTS` are the enum's names because they are the two shapes a rig arrives in
 inside a file, and they are the wrong words over a column somebody is choosing
 from: "Skins" reads as textures to anyone who has not read the glTF spec, and
 the thing a cell actually does is fit a skeleton to the open mesh. So the
 headings say that. The enum keeps the file's vocabulary; the sidebar keeps the
 user's.
*>
fn String AssetKind.label(self)
{
	switch (self)
	{
		case MODEL: return "Models";
		case SKIN: return "Body plans";
		case JOINTS: return "Skeletons";
		case ANIMATION: return "Animations";
	}
}

<*
 One thing a library file holds.

 Every string is owned by the index and dies with `free_assets`. `plan` is the
 empty string for an untagged asset, which is the common case for anything crig
 did not write.

 `index` is a position inside the file's own array for that kind — its skins, its
 animations — so it stays meaningful across a reload in a way a pointer would
 not. What it is *not* is an index into `AppState.packs`: a pack is the loaded
 form and may not exist yet. `pack_for_file` is the bridge.
*>
struct AssetEntry
{
	AssetKind kind;
	String name;
	String file;
	usz index;
	String plan;
	int library;

	// What the file says its contents are about, as the one comma-separated line
	// `extras` holds it in. Kept unsplit: the search folds both sides anyway, and
	// the panel that edits tags wants the line back exactly as it was typed. A
	// property of the file rather than of the item, so every entry out of one
	// file carries the same one.
	String tags;

	uint joints;    // SKIN, JOINTS; a MODEL's own skin, 0 for an unrigged body
	float duration; // ANIMATION, in seconds
	uint vertices;  // MODEL

	// Whether this entry came from the loaded model's own file. Set by the app, not
	// read from disk — see `AppState.mark_current_entries`, refreshed after every
	// scan — and read by the "Current file" group. An entry the current model shares
	// with a library carries it too, which is what keeps that group from injecting a
	// duplicate for a model that is already on a shelf.
	bool current;
}

<*
 Everything found across every configured library, in one flat list.

 Sorted by kind, then by name, then by file — so two runs over one folder agree
 with each other, and so a grid drawn from it groups without having to sort
 again. The order is the browser's order.
*>
struct AssetIndex
{
	AssetEntry[] entries;
}

alias AssetEntryList = List{AssetEntry};
alias AssetCategoryList = List{AssetCategory};
alias NodeSet = HashMap{uint, bool};

<*
 One row of the category sidebar, derived from what the scan actually found.

 Nothing is authored and nothing is kept in sync: a library holding no birds has
 no bird row. `depth` is what the tree indents by — 0 for "All", 1 for a kind, 2
 for a body plan under that kind.

 `label` is borrowed. It is either a literal, or an entry's own `plan` string,
 which lives as long as the index does.
*>
struct AssetCategory
{
	String label;
	usz depth;
	bool any_kind;
	AssetKind kind;
	bool any_plan;
	String plan;
	usz count;

	// The "Current file" row: an ANIMATION sub-row that narrows to the loaded
	// model's own clips. Distinct from the plain Animations row, which differs from
	// it only here — see `selected_category`.
	bool current_file;
}

<*
 Which entries the browser is showing.

 A struct rather than a handful of arguments because it is held on the AppState
 between frames and compared against the last one — the grid rebuilds when it
 changes and not otherwise.

 `library` is an index into the configured list, or negative for all of them.
 `search` is borrowed from whatever holds the text; it is read, never stored.
*>
struct AssetFilter
{
	bool any_kind;
	AssetKind kind;
	bool any_plan;
	String plan;
	int library;
	String search;

	// Keep only the loaded model's own animations — the "Current file" narrowing.
	// Combines with the kind above (which the category sets to ANIMATION).
	bool current_file;
}

// Everything, which is what the browser opens on.
const AssetFilter ALL_ASSETS = { .any_kind = true, .any_plan = true, .library = -1 };

<*
 Whether two filters would select the same entries.

 Asked before recomputing what the grid shows, so a frame that changed nothing
 about the filter does not rebuild the cells under the pointer — which would drop
 the hover.

 `search` is compared by content, so a field reporting the same text from a new
 allocation is the same filter.
*>
fn bool AssetFilter.same(self, AssetFilter other)
{
	if (self.any_kind != other.any_kind) return false;
	if (!self.any_kind && self.kind != other.kind) return false;
	if (self.any_plan != other.any_plan) return false;
	if (!self.any_plan && self.plan != other.plan) return false;
	if (self.current_file != other.current_file) return false;
	return self.library == other.library && self.search == other.search;
}

<*
 Read every library, one `gltf::open` per file and no buffers at all.

 A missing folder is an empty library rather than an error, and a file that will
 not open — or that carries nothing this knows how to name — is skipped. One bad
 download must not cost the user the rest of the shelf. The same bargain
 `scan_packs` makes, for the same reason.

 The caller owns the result; free it with `free_assets`.

 @param libraries : `The configured folders, each scanned one level deep.`
 @return `Every item found, sorted by kind then name then file.`
*>
fn AssetIndex scan_assets(Allocator allocator, AssetLibrary[] libraries)
{
	AssetEntryList found;
	found.init(allocator);

	foreach (usz which, library : libraries)
	{
		read_library(allocator, &found, library, (int)which);
	}

	AssetIndex index = { .entries = found.to_array(allocator) };
	found.free();

	sort::quicksort(index.entries, &by_asset);
	return index;
}

// One library folder. Split out so `scan_assets` reads as the loop it is, and so
// the early returns for a folder that is not there stay local to one file.
fn void read_library(Allocator allocator, AssetEntryList* found, AssetLibrary library, int which) @local
{
	if (library.path.len == 0) return;

	String[] files = gltf_files_in(allocator, library.path);
	defer free_paths(allocator, files);
	foreach (file : files) read_file(allocator, found, file, which);
}

<*
 Everything one file holds, appended to `found`.

 The stream is opened and closed inside this call and every string taken out of
 it is copied first — `gltf::open` parses into structures `close` releases, so a
 borrowed name would dangle the moment the next file is read.
*>
fn void read_file(Allocator allocator, AssetEntryList* found, String file, int library) @local
{
	gltf::GltfStream? opened = gltf::open(file, allocator);
	if (catch opened) return;

	gltf::GltfStream stream = opened;
	defer stream.close();

	String stem = stem_of(allocator, file);
	defer alloc::free(allocator, stem.ptr);

	// A file declaring a version this reader does not speak is indexed for what it
	// holds and not for what it claims about itself — the same rule `read_pack`
	// applies, so the two cannot disagree about which files are tagged.
	bool too_new = false;
	if (try String declared = stream.gltf.extras.get(PACK_KEY_VERSION))
	{
		uint? spoken = declared.to_uint();
		if (try spoken && spoken > PACK_VERSION) too_new = true;
	}

	String plan = "";
	String tags = "";
	if (!too_new)
	{
		if (try String declared = stream.gltf.extras.get(PACK_KEY_PLAN))
		{
			if (declared.trim().len > 0) plan = trimmed_lower(allocator, declared);
		}
		if (try String listed = stream.gltf.extras.get(PACK_KEY_TAGS))
		{
			if (listed.trim().len > 0) tags = listed.trim().copy(allocator);
		}
	}
	defer if (plan.len > 0) alloc::free(allocator, plan.ptr);
	defer if (tags.len > 0) alloc::free(allocator, tags.ptr);

	// The body, once per file. A library pack draws one too — a stand-in, so its
	// clips have something to play on — and that one is not a character. It is
	// told apart by shape, the one thing a copy of the file cannot inherit wrong:
	// the pack writer hangs its body beside the skeleton unskinned, and a
	// character's body is the thing its skin binds.
	bool draws;
	bool skinned;
	uint vertices;
	foreach (node : stream.gltf.nodes)
	{
		if (node.mesh < 0 || node.mesh >= stream.gltf.meshes.len()) continue;
		draws = true;
		if (node.skin >= 0) skinned = true;
		foreach (primitive : stream.gltf.meshes[node.mesh].primitives)
		{
			sz? at = primitive.attributes.get("POSITION");
			if (try at && at < stream.gltf.accessors.len()) vertices += stream.gltf.accessors[at].count;
		}
	}
	bool stand_in = stream.gltf.skins.len() > 0 && !skinned;
	if (draws && !stand_in)
	{
		found.push({
			.kind = MODEL,
			.name = stem.copy(allocator),
			.file = file.copy(allocator),
			.index = 0,
			.plan = plan.len > 0 ? plan.copy(allocator) : "",
			.tags = tags.len > 0 ? tags.copy(allocator) : "",
			.library = library,
			.joints = stream.gltf.skins.len() > 0 ? (uint)stream.gltf.skins[0].joints.len() : 0,
			.vertices = vertices,
		});
	}

	foreach (usz i, skin : stream.gltf.skins)
	{
		found.push({
			.kind = SKIN,
			.name = asset_name(allocator, skin.name, stem, i),
			.file = file.copy(allocator),
			.index = i,
			.plan = plan.len > 0 ? plan.copy(allocator) : "",
			.tags = tags.len > 0 ? tags.copy(allocator) : "",
			.library = library,
			.joints = (uint)skin.joints.len(),
		});
	}

	// Only when the file names no skin — a file that has one has already said which
	// nodes are its joints, and standing for the same skeleton twice would put two
	// rows in the browser for one rig.
	//
	// What this covers is a file that animates its nodes without binding a mesh to
	// them. glTF allows it and crig can use it: the clips address named joints,
	// which is all a template needs. Nothing crig writes takes that shape, so this
	// is the path for files from elsewhere.
	if (stream.gltf.skins.len() == 0)
	{
		uint joints = animated_joint_count(allocator, &stream);
		if (joints > 0)
		{
			found.push({
				.kind = JOINTS,
				.name = stem.copy(allocator),
				.file = file.copy(allocator),
				.index = 0,
				.plan = plan.len > 0 ? plan.copy(allocator) : "",
				.tags = tags.len > 0 ? tags.copy(allocator) : "",
				.library = library,
				.joints = joints,
			});
		}
	}

	foreach (usz i, animation : stream.gltf.animations)
	{
		found.push({
			.kind = ANIMATION,
			.name = asset_name(allocator, animation.name, stem, i),
			.file = file.copy(allocator),
			.index = i,
			.plan = plan.len > 0 ? plan.copy(allocator) : "",
			.tags = tags.len > 0 ? tags.copy(allocator) : "",
			.library = library,
			.duration = animation.duration(),
		});
	}

	// The file's materials are deliberately not entries, and its meshes are one
	// MODEL entry above rather than one each. See the note on `AssetKind`.
}

// The `library` an entry carries when it is the loaded model's own, indexed so the
// "Current file" group can list a model opened from outside every configured
// library. Negative like "all", so the library `Select` filter never hides it, and
// distinct from -1 so `set_current_model` can find and drop its own past entries.
const int CURRENT_MODEL_LIBRARY = -2;

<*
 The loaded model's own animations, as entries — the reader behind the "Current
 file" group for a model that lives outside every library and so is in no scan.

 Animations only: the group is scoped to them, and a model's own skin is not a body
 plan on offer. Named exactly as `read_file` names a library's clips (`asset_name`,
 which shares `unnamed_asset_name` with the importer), so a binding stored against a
 clip resolves and a delete can match it by name.
*>
fn void read_current_animations(Allocator allocator, AssetEntryList* found, String file) @local
{
	gltf::GltfStream? opened = gltf::open(file, allocator);
	if (catch opened) return;
	gltf::GltfStream stream = opened;
	defer stream.close();

	String stem = stem_of(allocator, file);
	defer alloc::free(allocator, stem.ptr);

	foreach (usz i, animation : stream.gltf.animations)
	{
		found.push({
			.kind = ANIMATION,
			.name = asset_name(allocator, animation.name, stem, i),
			.file = file.copy(allocator),
			.index = i,
			.plan = "",
			.tags = "",
			.library = CURRENT_MODEL_LIBRARY,
			.duration = animation.duration(),
		});
	}
}

<*
 Put the loaded model's own animations into the index as the "Current file" group.

 Drops whatever sentinel entries a previous current model left, then — unless the
 file is already indexed under a real library, in which case its own rows serve and
 `mark_current_entries` marks them — reads the model's animations in as sentinel
 entries. Re-sorts, because new rows change where entries belong. `""` only clears
 the previous model's rows, for a session with nothing open.

 @param file : `The loaded model's path, or "" to only clear a previous current model.`
*>
fn void AssetIndex.set_current_model(&self, Allocator allocator, String file)
{
	AssetEntryList kept;
	kept.init(allocator);

	bool already_indexed = false;
	foreach (&entry : self.entries)
	{
		if (entry.library == CURRENT_MODEL_LIBRARY)
		{
			free_entry(allocator, entry);
			continue;
		}
		if (file.len > 0 && entry.file == file) already_indexed = true;
		kept.push(*entry);
	}

	if (file.len > 0 && !already_indexed)
	{
		read_current_animations(allocator, &kept, file);
	}

	if (self.entries.len > 0) alloc::free(allocator, self.entries);
	self.entries = kept.to_array(allocator);
	kept.free();

	sort::quicksort(self.entries, &by_asset);
}

<*
 How many distinct nodes a file's animations move.

 The joint count for a file with no skin: crig's writer puts one channel per bone
 per property, so counting channels would report a rig three times its size.
 Distinct `target.node` is the skeleton the clips address.

 Node indices rather than names because a channel names a node by index and
 nothing else, and the set is thrown away here anyway.
*>
fn uint animated_joint_count(Allocator allocator, gltf::GltfStream* stream) @local
{
	NodeSet seen;
	seen.init(allocator);
	defer seen.free();

	foreach (animation : stream.gltf.animations)
	{
		foreach (channel : animation.channels) seen.set(channel.target.node, true);
	}
	return (uint)seen.len();
}

<*
 What a cell calls this item.

 Its own name when it has one. glTF does not require one, and an unnamed item
 still has to be told apart from its siblings, so the fallback carries the file
 it came from and its position in it — "biped 2" rather than a second blank cell.

 The caller owns the result.
*>
fn String asset_name(Allocator allocator, String given, String stem, usz index) @local
{
	if (given.trim().len > 0) return given.trim().copy(allocator);
	return unnamed_asset_name(allocator, stem, index);
}

<*
 What an item with no name of its own is called: the file's stem and its position
 in the file.

 Shared with the animation importer, and the sharing is the whole point. A
 binding is a file path plus a clip *name* (`app/bound.c3`), and the browser's
 mark asks whether the name in this index is in the document — so the index and
 the pack have to invent the **same** name for a clip the glTF left unnamed, or a
 clip binds under one name and is looked for under another.

 Not hypothetical: it is what `CesiumMan.glb` did. Its one animation has no name,
 the index called it "CesiumMan 0", the importer called every unnamed clip
 "Imported animation", and so the + bound the clip and the mark never lit.

 The caller owns the result.
*>
fn String unnamed_asset_name(Allocator allocator, String stem, usz index)
{
	return string::format(allocator, "%s %d", stem, index);
}

// Kind first so the grid groups, then name so a group reads alphabetically, then
// file so two items of one name in two files hold a stable order between runs.
fn int by_asset(AssetEntry a, AssetEntry b) @local
{
	if (a.kind != b.kind) return a.kind < b.kind ? -1 : 1;
	int named = a.name.compare_to(b.name);
	if (named != 0) return named;
	return a.file.compare_to(b.file);
}

<*
 Re-read one file and put what it holds back into the index, in place of what it
 held before.

 The cheap answer to "this file changed". A full `scan_assets` reopens every
 .glb in every library, and one open costs about seventy milliseconds — nearly
 all of it inside the standard JSON reader, which the glTF library parses the
 whole document through. On two hundred files that is fourteen seconds, which is
 not a price to pay for renaming one clip.

 Entries from other files are moved across rather than rebuilt, so they keep the
 strings they already own; only the ones being replaced are freed. The result is
 re-sorted, because a rename changes where an entry belongs and several things
 downstream read the order.

 **Every position into the index moves.** A caller holding one — a selected
 cell, an open settings panel — owes itself a reset.

 @param file : `The path to re-read. Must not be a string owned by the index, which this frees.`
 @param library : `Which configured library it came from, for the entries it produces.`
*>
fn void AssetIndex.replace_file(&self, Allocator allocator, String file, int library)
{
	AssetEntryList kept;
	kept.init(allocator);

	foreach (&entry : self.entries)
	{
		if (entry.file != file)
		{
			kept.push(*entry);
			continue;
		}
		free_entry(allocator, entry);
	}

	read_file(allocator, &kept, file, library);

	if (self.entries.len > 0) alloc::free(allocator, self.entries);
	self.entries = kept.to_array(allocator);
	kept.free();

	sort::quicksort(self.entries, &by_asset);
}

fn void free_entry(Allocator allocator, AssetEntry* entry) @local
{
	if (entry.name.len > 0) alloc::free(allocator, entry.name.ptr);
	if (entry.file.len > 0) alloc::free(allocator, entry.file.ptr);
	if (entry.plan.len > 0) alloc::free(allocator, entry.plan.ptr);
	if (entry.tags.len > 0) alloc::free(allocator, entry.tags.ptr);
}

<*
 Release an index and every string in it.

 Safe on a zero index, which is what an `AppState` built by a check holds.
*>
fn void free_assets(Allocator allocator, AssetIndex index)
{
	foreach (&entry : index.entries) free_entry(allocator, entry);
	if (index.entries.len > 0) alloc::free(allocator, index.entries);
}

<*
 Whether one entry passes a filter.

 The search is matched against the name, against the file's own stem, and
 against the file's tags — so typing "biped" finds the clips inside `biped.glb`
 even though none of them is called that, and typing "swimming" finds whatever
 was tagged that way whatever the clips are called. All three are things a
 person types into a search box expecting the same box to answer.

 The tag line is matched whole rather than word by word, so a needle spanning a
 comma matches. That is the same looseness a substring match over a name already
 has, and a search box is where it belongs.

 The **stem**, not the path. A library's own folders are in every path under it,
 so matching the whole thing makes any letter of the directory name match every
 asset in it — a search for "b" over a library under `build/` returns the library.
*>
fn bool AssetEntry.matches(&self, AssetFilter filter)
{
	if (!filter.any_kind && self.kind != filter.kind) return false;
	if (!filter.any_plan && self.plan != filter.plan) return false;
	if (filter.library >= 0 && self.library != filter.library) return false;
	if (filter.current_file && !self.current) return false;
	if (filter.search.trim().len == 0) return true;

	String needle = filter.search.trim();
	return contains_fold(self.name, needle)
		|| contains_fold(file_stem(self.file), needle)
		|| contains_fold(self.tags, needle);
}

<*
 The file's name without its directory or its extension, as a view into `path`.

 Borrowed, not copied: the search box calls this once per asset per keystroke,
 and nothing it returns outlives the comparison. `stem_of` is the copying form,
 and takes its answer from here.

 A name that is nothing but an extension — ".gitignore" — keeps the dot and the
 rest of it, because the alternative is an empty stem for a file that plainly has
 a name.
*>
fn String file_stem(String path)
{
	usz start = 0;
	for (usz i = 0; i < path.len; i++)
	{
		if (path[i] == '/' || path[i] == '\\') start = i + 1;
	}

	usz end = path.len;
	for (usz i = path.len; i > start; i--)
	{
		if (path[i - 1] == '.')
		{
			end = i - 1;
			break;
		}
	}
	if (end <= start) end = path.len;

	return path[start:end - start];
}

<*
 The positions of every entry passing the filter, in index order.

 Positions rather than copies, so the grid can hold the result across frames
 while the entries themselves stay owned by the index.

 The caller owns the returned array; free it with the same allocator. An empty
 result is a zero-length slice, not a fault — a search matching nothing is an
 ordinary answer.
*>
fn usz[] AssetIndex.matching(&self, Allocator allocator, AssetFilter filter)
{
	List{usz} out;
	out.init(allocator);
	foreach (usz i, &entry : self.entries)
	{
		if (entry.matches(filter)) out.push(i);
	}
	usz[] found = out.to_array(allocator);
	out.free();
	return found;
}

<*
 Whether `needle` appears in `haystack`, ignoring case.

 Folded per byte rather than by copying both sides lower: this runs once per
 entry per keystroke, and the alternative allocates twice as many strings as
 there are assets every time a character is typed.
*>
fn bool contains_fold(String haystack, String needle) @local
{
	if (needle.len == 0) return true;
	if (needle.len > haystack.len) return false;

	for (usz start = 0; start + needle.len <= haystack.len; start++)
	{
		bool same = true;
		for (usz i = 0; i < needle.len; i++)
		{
			if (haystack[start + i].to_lower() != needle[i].to_lower())
			{
				same = false;
				break;
			}
		}
		if (same) return true;
	}
	return false;
}

<*
 The sidebar, derived from what the scan found.

 "All", then a row per kind present, then a row per body plan under that kind —
 the plans an untagged asset does not have being gathered under one "Untagged"
 row at the end of its kind. A library holding nothing but biped clips gets three
 rows, not a tree of empty categories.

 Counts are on every row, because the number beside a category is what says
 whether it is worth opening.

 Every `label` is borrowed: either a literal or an entry's own `plan`, both of
 which outlive the returned array as long as the index does. The caller owns the
 array itself.

 @param collapsed : `One flag per AssetKind, by ordinal — either AssetKind::len of them or none at all. A flagged kind keeps its own row and contributes none of its plan rows; an empty slice reads as everything open.`
 @return `The rows to draw, in sidebar order.`
*>
fn AssetCategory[] AssetIndex.categories(&self, Allocator allocator, bool[] collapsed = {})
{
	AssetCategoryList out;
	out.init(allocator);

	out.push({
		.label = "All",
		.depth = 0,
		.any_kind = true,
		.any_plan = true,
		.count = self.entries.len,
	});

	// In enum order rather than the order found, so the sidebar does not reshuffle
	// when a library gains its first animation. Straight off the enum, so a kind
	// added to it appears here without anything being kept in step by hand.
	foreach (kind : AssetKind::values)
	{
		usz held = 0;
		foreach (&entry : self.entries)
		{
			if (entry.kind == kind) held++;
		}
		if (held == 0) continue;

		out.push({
			.label = kind.label(),
			.depth = 1,
			.kind = kind,
			.any_plan = true,
			.count = held,
		});

		// A closed kind is a row that is still there and still narrows the grid; it
		// is only the plans under it that go. Left out here rather than hidden by
		// the sidebar, so that a row's position in this array is a row's position
		// on screen — which is the whole of what a click on one reports.
		if (collapsed.len == AssetKind::len && collapsed[kind.ordinal]) continue;

		// The loaded model's own clips, first under Animations, so a model opened from
		// anywhere — not only a library folder — has a row that lists just its clips
		// to inspect or delete. Rides the same collapse as the plan rows below it. The
		// `current` flag is the app's; see `AppState.mark_current_entries`.
		if (kind == AssetKind.ANIMATION)
		{
			usz current = 0;
			foreach (&entry : self.entries)
			{
				if (entry.kind == AssetKind.ANIMATION && entry.current) current++;
			}
			if (current > 0)
			{
				out.push({
					.label = "Current file",
					.depth = 2,
					.kind = ANIMATION,
					.any_plan = true,
					.count = current,
					.current_file = true,
				});
			}
		}

		self.push_plans(&out, kind);
	}

	AssetCategory[] rows = out.to_array(allocator);
	out.free();
	return rows;
}

// The body-plan rows under one kind, each named once however many assets carry
// it, with the untagged ones gathered last.
fn void AssetIndex.push_plans(&self, AssetCategoryList* out, AssetKind kind)
{
	usz untagged = 0;
	foreach (usz i, &entry : self.entries)
	{
		if (entry.kind != kind) continue;
		if (entry.plan.len == 0)
		{
			untagged++;
			continue;
		}

		// The first entry carrying this plan is the one that emits its row. Scanning
		// back rather than keeping a set: the plans under one kind are a handful,
		// and this keeps the rows in the entries' own order with nothing to free.
		bool seen = false;
		for (usz j = 0; j < i; j++)
		{
			if (self.entries[j].kind == kind && self.entries[j].plan == entry.plan)
			{
				seen = true;
				break;
			}
		}
		if (seen) continue;

		usz held = 0;
		foreach (&other : self.entries)
		{
			if (other.kind == kind && other.plan == entry.plan) held++;
		}
		out.push({
			.label = entry.plan,
			.depth = 2,
			.kind = kind,
			.plan = entry.plan,
			.count = held,
		});
	}

	if (untagged == 0) return;
	out.push({
		.label = "Untagged",
		.depth = 2,
		.kind = kind,
		.plan = "",
		.count = untagged,
	});
}

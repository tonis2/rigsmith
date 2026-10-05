<*
 The asset index: what a scan finds in a library, and what the filter and the
 sidebar make of it.

 Read against `crig_tests::library`, the three generated body-plan packs, for the
 reason that file gives — the shipped folder is whatever the person working on
 crig dropped into it, and a check that describes it describes nothing.

 What those three carry, and what these checks lean on: each declares a body plan
 (`biped`, `bird`, `quadruped`), each binds a skin named "rig", each holds clips
 addressing that skin's joints, and each carries a dummy body mesh. So a scan
 finds skins, animations and meshes, and no bare `JOINTS` — that case is for a
 file that animates its nodes without binding a mesh to them, which is not a
 shape crig writes.

 No window and no GPU: `core/` imports no cui, and this is the check that says
 so.
*>
module crig_tests::assets;

import crig;
import gltf_edit;
import crig_tests::library;

import std::core::test;
import std::io;
import std::io::file;
import std::io::path;

// The library under test, as the one-entry list a config would hold.
fn crig::AssetLibrary[] one_library(String path) @local
{
	static crig::AssetLibrary[1] held;
	held[0] = { .name = "Checks", .path = path };
	return held[..];
}

// How many entries of a kind a scan found.
fn usz count_of(crig::AssetIndex index, crig::AssetKind kind) @local
{
	usz held = 0;
	foreach (&entry : index.entries)
	{
		if (entry.kind == kind) held++;
	}
	return held;
}

<*
 A scan finds the items inside the files, not the files.

 The point of the index: three packs come back as a skeleton each plus every clip
 in them, so a browser can offer one clip rather than a card that has to be
 opened.
*>
fn void a_scan_finds_items_rather_than_files() @test
{
	io::printn("a library scan lists what is inside the files");

	crig::AssetIndex index = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, index);

	test::@check(index.entries.len > 2,
		"two packs came back as %d entries, which is a list of files rather than of assets",
		index.entries.len);

	test::eq((int)count_of(index, crig::AssetKind.SKIN), 2);
	test::@check(count_of(index, crig::AssetKind.ANIMATION) > 0, "the clips were not indexed");

	// Every pack here carries a dummy body, and none of them may come back as an
	// entry: a mesh is not a thing the browser can open, so it is not indexed at
	// all — see the note on `AssetKind`. Counted rather than named, so a kind
	// added back and emitted shows up here as entries nothing accounts for.
	usz accounted = count_of(index, crig::AssetKind.SKIN)
		+ count_of(index, crig::AssetKind.JOINTS)
		+ count_of(index, crig::AssetKind.ANIMATION);
	test::@check(accounted == index.entries.len,
		"%d of %d entries are neither a body plan, a skeleton nor a clip",
		(int)(index.entries.len - accounted), (int)index.entries.len);

	// Every file here binds a skin, so none of them may also produce the bare
	// skeleton entry. One rig standing as two rows in the browser is the failure
	// this guards.
	test::eq((int)count_of(index, crig::AssetKind.JOINTS), 0);
}

<*
 Every entry says where it came from, what it belongs to, and enough to fill a
 cell.

 A joint count of zero would draw a cell reading "0 joints"; a duration of zero
 would say a clip is instantaneous. Both are what an entry left unfilled looks
 like, so both are worth a check.
*>
fn void entries_carry_what_a_cell_shows() @test
{
	io::printn("an entry carries its file, its plan and its numbers");

	crig::AssetIndex index = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, index);

	bool saw_rig = false;
	bool saw_clip = false;
	foreach (&entry : index.entries)
	{
		test::@check(entry.name.len > 0, "an entry came back unnamed");
		test::@check(entry.file.len > 0, "an entry does not say which file it is in");
		test::@check(entry.library == 0, "an entry was attributed to library %d, and only one was scanned",
			entry.library);

		switch (entry.kind)
		{
			case SKIN:
				saw_rig = true;
				test::@check(entry.joints > 1, "a skeleton came back with %d joints", entry.joints);
				// All three declare one, so an empty plan here is the extras read
				// failing rather than an untagged file.
				test::@check(entry.plan.len > 0, "%s lost its body-plan tag", entry.name);
			case ANIMATION:
				saw_clip = true;
				test::@check(entry.duration > 0.0f,
					"clip %s came back %.3f seconds long", entry.name, entry.duration);
			default:
				break;
		}
	}

	test::@check(saw_rig && saw_clip, "the scan found neither a skeleton nor a clip to check");
}

<*
 A folder that is not there is an empty library, and so is a config naming none.

 crig has to start with a library path a user has since deleted, or renamed, or
 typed wrong. Faulting there would be refusing to open the application over a
 setting.
*>
fn void a_missing_library_is_empty_rather_than_a_fault() @test
{
	io::printn("a library folder that is not there reads as empty");

	crig::AssetIndex missing = crig::scan_assets(mem, one_library("build/no-such-library"));
	defer crig::free_assets(mem, missing);
	test::eq((int)missing.entries.len, 0);

	crig::AssetIndex none = crig::scan_assets(mem, (crig::AssetLibrary[]){});
	defer crig::free_assets(mem, none);
	test::eq((int)none.entries.len, 0);
}

<*
 The filter narrows by kind, by plan and by typed text, and the three compose.
*>
fn void the_filter_narrows_by_kind_plan_and_search() @test
{
	io::printn("the filter narrows by kind, plan and search");

	crig::AssetIndex index = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, index);

	usz[] everything = index.matching(mem, crig::ALL_ASSETS);
	defer alloc::free(mem, everything);
	test::eq((int)everything.len, (int)index.entries.len);

	crig::AssetFilter clips = { .kind = crig::AssetKind.ANIMATION, .any_plan = true, .library = -1 };
	usz[] animations = index.matching(mem, clips);
	defer alloc::free(mem, animations);
	test::eq((int)animations.len, (int)count_of(index, crig::AssetKind.ANIMATION));
	test::@check(animations.len < everything.len, "narrowing to one kind kept everything");

	crig::AssetFilter biped = { .kind = crig::AssetKind.SKIN, .plan = "biped", .library = -1 };
	usz[] rigs = index.matching(mem, biped);
	defer alloc::free(mem, rigs);
	test::eq((int)rigs.len, 1);
	test::@check(index.entries[rigs[0]].plan == "biped");

	// Against the file's stem, not only the item's own name: the clip inside
	// quadruped.glb is called "Idle", and someone typing "quadruped" means it.
	crig::AssetFilter by_file = { .any_kind = true, .any_plan = true, .library = -1, .search = "QUADRUPED" };
	usz[] animals = index.matching(mem, by_file);
	defer alloc::free(mem, animals);
	test::@check(animals.len > 0, "searching a file's name found nothing in it");
	foreach (which : animals)
	{
		String file = index.entries[which].file;
		test::@check(file.len >= 13 && file[^13..] == "quadruped.glb",
			"%s matched a search for quadruped and came out of %s", index.entries[which].name, file);
	}

	// A search matching nothing is an empty list, not a fault and not everything.
	crig::AssetFilter nothing = { .any_kind = true, .any_plan = true, .library = -1, .search = "zzzz" };
	usz[] empty = index.matching(mem, nothing);
	defer alloc::free(mem, empty);
	test::eq((int)empty.len, 0);
}

<*
 A library filter keeps the libraries apart when one folder is listed twice.

 Two entries over one folder is the shape that catches a filter comparing paths
 rather than positions: everything is found twice, and each copy has to answer to
 its own library and not to both.
*>
fn void the_library_filter_tells_two_libraries_apart() @test
{
	io::printn("assets answer to the library they were found in");

	String path = library::ready();
	crig::AssetLibrary[2] both = {
		{ .name = "First", .path = path },
		{ .name = "Second", .path = path },
	};

	crig::AssetIndex index = crig::scan_assets(mem, both[..]);
	defer crig::free_assets(mem, index);

	crig::AssetFilter first = { .any_kind = true, .any_plan = true, .library = 0 };
	crig::AssetFilter second = { .any_kind = true, .any_plan = true, .library = 1 };

	usz[] mine = index.matching(mem, first);
	defer alloc::free(mem, mine);
	usz[] theirs = index.matching(mem, second);
	defer alloc::free(mem, theirs);

	test::@check(mine.len > 0, "the first library came back empty");
	test::eq((int)mine.len, (int)theirs.len);
	test::eq((int)(mine.len + theirs.len), (int)index.entries.len);
}

<*
 The sidebar is derived from what was found, not authored.

 Which is the property that matters: a category nobody has assets for must not
 appear, and every row's count has to be the number the filter behind it returns
 — a sidebar saying "4" over a grid of three is worse than no count at all.
*>
fn void categories_are_derived_from_what_was_found() @test
{
	io::printn("the sidebar rows come from the scan");

	crig::AssetIndex index = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, index);

	crig::AssetCategory[] rows = index.categories(mem);
	defer alloc::free(mem, rows);

	test::@check(rows.len > 1, "the sidebar came back with nothing but its head");
	test::@check(rows[0].label == "All" && rows[0].any_kind, "the first row is not All");
	test::eq((int)rows[0].count, (int)index.entries.len);

	bool saw_joints = false;
	bool saw_plan = false;
	foreach (row : rows)
	{
		if (row.depth == 1 && row.kind == crig::AssetKind.JOINTS) saw_joints = true;
		if (row.depth == 2 && row.plan == "biped") saw_plan = true;

		// Every row's count is what the filter behind that row actually returns.
		crig::AssetFilter behind = {
			.any_kind = row.any_kind,
			.kind = row.kind,
			.any_plan = row.any_plan,
			.plan = row.plan,
			.library = -1,
		};
		usz[] under = index.matching(mem, behind);
		defer alloc::free(mem, under);
		test::@check(under.len == row.count,
			"the row for %s counts %d and its filter returns %d",
			row.label, row.count, under.len);
	}

	// Every file here binds a skin, so nothing produced a bare skeleton entry and
	// no Joints row may be offered over a category holding none.
	test::@check(!saw_joints, "a Joints row was offered over a library holding none");
	test::@check(saw_plan, "the body-plan rows are missing from the sidebar");
}

<*
 No heading stands over a kind that cannot be opened.

 A sidebar row is an offer: it says there is something of this sort here and
 clicking it narrows to them. "Meshes" and "Materials" were both offers crig
 could not honour — a mesh cell was drawn greyed for ever and a material cell was
 never drawn at all — and both are gone from `AssetKind` rather than hidden by
 the sidebar, so there is nothing left to accidentally list.

 Checked on the labels the sidebar actually draws rather than on the enum, since
 a heading is what the user reads and `label()` is the only thing that decides
 it.
*>
fn void no_heading_stands_over_a_dead_kind() @test
{
	io::printn("every category heading is one the browser can open");

	crig::AssetIndex index = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, index);

	crig::AssetCategory[] rows = index.categories(mem);
	defer alloc::free(mem, rows);

	usz headings = 0;
	foreach (row : rows)
	{
		if (row.depth != 1) continue;
		headings++;

		test::@check(row.label != "Meshes" && row.label != "Materials",
			"the sidebar offers a %s row, which nothing can be done with", row.label);
		test::@check(
			row.label == "Body plans" || row.label == "Skeletons" || row.label == "Animations",
			"%s heads a kind the browser has no reading for", row.label);
	}

	test::@check(headings > 0, "the sidebar came back with no kind headings at all");
}

<*
 Two scans of one folder agree with each other.

 The order is the browser's order, and several things downstream read "the first"
 of something. An order that varies by machine makes all of them vary by machine
 — the reason `scan_packs` sorts, and the same reason here.
*>
fn void two_scans_of_one_folder_agree() @test
{
	io::printn("a scan is in a settled order");

	crig::AssetIndex first = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, first);
	crig::AssetIndex second = crig::scan_assets(mem, one_library(library::ready()));
	defer crig::free_assets(mem, second);

	test::eq((int)first.entries.len, (int)second.entries.len);
	foreach (usz i, &entry : first.entries)
	{
		test::@check(entry.kind == second.entries[i].kind && entry.name == second.entries[i].name,
			"entry %d came back as %s and then as %s", i, entry.name, second.entries[i].name);
	}

	// Kind-major, so a grid drawn straight from the list groups without sorting.
	foreach (usz i, &entry : first.entries)
	{
		if (i == 0) continue;
		test::@check(first.entries[i - 1].kind <= entry.kind, "the list is not grouped by kind");
	}
}

// ---------------------------------------------------------------------------
// Editing what a file says about itself

<*
 A library of one file, freshly copied, for the checks that write to it.

 A folder of its own, because these overwrite what they open and the shared
 fixture library is read by every other check in this suite. Copied on every
 call rather than only when missing — a run that left a renamed file behind
 would pass the second time for the wrong reason.

 @return `The folder, or "" when the copy failed.`
*>
fn String scratch_library() @local
{
	const String FOLDER = "build/retag-library";
	if (catch path::mkdir((Path)FOLDER))
	{
		// Already there, which is the ordinary case after the first check.
	}

	String source = string::format(mem, "%s/humanoid.glb", library::ready());
	defer alloc::free(mem, source.ptr);

	char[]? bytes = file::load(mem, source);
	if (catch bytes) return "";
	defer alloc::free(mem, bytes);

	String destination = string::format(mem, "%s/tagme.glb", FOLDER);
	defer alloc::free(mem, destination.ptr);
	if (catch file::save(destination, bytes)) return "";

	return FOLDER;
}

<*
 A name and a tag typed into the settings panel come back out of the next scan.

 The whole of what the panel is for, end to end: the item is renamed in the
 file, the file is tagged, and the search box finds it by the tag. The last of
 those is the one that would silently not work — a tag written into a file that
 the index did not read would look like a tag that had not been saved.

 The entry count is checked as well. A patch that broke the JSON would leave a
 file that no longer opens, and an index that came back with three entries
 instead of eleven reads as a search that matched nothing rather than as a file
 that was destroyed.
*>
fn void tagging_a_file_makes_it_findable() @test
{
	io::printn("a name and a tag written into a file survive the next scan");

	String folder = scratch_library();
	if (folder.len == 0)
	{
		test::@check(false, "SKIPPED — the scratch library could not be built");
		return;
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	app.config.libraries.init(mem);
	app.config.add_library(folder, "Retag");
	app.scan_libraries();

	usz before = app.assets.entries.len;
	test::@check(before > 0, "the scratch library indexed nothing");

	usz which = app.assets.entries.len;
	foreach (usz i, &entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && which == app.assets.entries.len) which = i;
	}
	if (which == app.assets.entries.len)
	{
		test::@check(false, "SKIPPED — the scratch library holds no animation to rename");
		return;
	}

	test::@check(app.retag_asset(which, "Renamed Walk", "biped", "swimming, slow"),
		"the file could not be written");

	test::eq((usz)app.assets.entries.len, before);

	crig::AssetEntry* renamed = null;
	foreach (usz i, &entry : app.assets.entries)
	{
		if (entry.name == "Renamed Walk") renamed = &app.assets.entries[i];
	}
	if (!renamed)
	{
		test::@check(false, "no entry came back under the new name");
		return;
	}
	test::eq(renamed.plan, "biped");
	test::eq(renamed.tags, "swimming, slow");

	// The tag is on the file, so every entry out of it carries it — including the
	// skin and the body, which were not the cell the gear was clicked on.
	usz tagged = 0;
	foreach (&entry : app.assets.entries)
	{
		if (entry.tags == "swimming, slow") tagged++;
	}
	test::@check(tagged == before, "%d of %d entries carry the file's tag", tagged, before);

	// And the search box finds it by a word that appears in no name and no path.
	crig::AssetFilter by_tag = { .any_kind = true, .any_plan = true, .library = -1, .search = "swimming" };
	app.set_asset_filter(by_tag);
	test::@check(app.visible_assets.len == before, "searching the tag found %d of %d",
		app.visible_assets.len, before);
}

<*
 Clearing a tag untags the file rather than tagging it with nothing.

 The sidebar groups by plan and gathers everything untagged under one row, so a
 file left carrying `"plan": ""` would sit in a category of its own named after
 the empty string. Written as a separate check because removing a key and
 writing one are different branches of the patcher.
*>
fn void clearing_a_plan_untags_the_file() @test
{
	io::printn("clearing the plan puts the file back under Untagged");

	String folder = scratch_library();
	if (folder.len == 0)
	{
		test::@check(false, "SKIPPED — the scratch library could not be built");
		return;
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	app.config.libraries.init(mem);
	app.config.add_library(folder, "Retag");
	app.scan_libraries();

	usz which = app.assets.entries.len;
	foreach (usz i, &entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.SKIN && which == app.assets.entries.len) which = i;
	}
	if (which == app.assets.entries.len)
	{
		test::@check(false, "SKIPPED — the scratch library holds no skin");
		return;
	}

	// The copy is a generated pack, so it starts out tagged — the check would
	// pass trivially against a file that never had a plan.
	test::eq(app.assets.entries[which].plan, "biped");

	String kept = app.assets.entries[which].name.copy(mem);
	defer alloc::free(mem, kept.ptr);

	test::@check(app.retag_asset(which, kept, "", ""), "the file could not be written");

	foreach (&entry : app.assets.entries)
	{
		test::eq(entry.plan, "");
		test::eq(entry.tags, "");
	}
}

<*
 Tagging a file the library never loaded makes it a pack the library holds.

 The gap a targeted re-read opens and has to close by hand. `scan_libraries`
 reads whole only the files that declare a body plan, so an untagged one is
 indexed and left alone — and after it is tagged there is nothing in memory to
 reload. Without this the plan just typed in would not be a plan crig offers
 until it was restarted, which reads as the tag not having saved.
*>
fn void tagging_an_unloaded_file_loads_it() @test
{
	io::printn("giving a file a plan puts it in the library");

	String folder = scratch_library();
	if (folder.len == 0)
	{
		test::@check(false, "SKIPPED — the scratch library could not be built");
		return;
	}

	String file = string::format(mem, "%s/tagme.glb", folder);
	defer alloc::free(mem, file.ptr);

	// Untagged on disk before the library is read, so the declared pass skips it.
	gltf_edit::JsonStep[2] plan_path = { { .key = "extras" }, { .key = "plan" } };
	gltf_edit::JsonEdit[1] clear = { { .path = plan_path[..], .value = "" } };
	if (catch gltf_edit::patch_gltf(mem, file, clear[..]))
	{
		test::@check(false, "SKIPPED — the scratch file could not be untagged");
		return;
	}

	crig::AppState app = crig::new_app({});
	defer app.free();
	app.config.libraries.init(mem);
	app.config.add_library(folder, "Retag");
	app.scan_libraries();

	test::@check(app.loaded_pack_for(file) < 0,
		"the untagged file was loaded anyway, so this check proves nothing");

	usz which = app.assets.entries.len;
	foreach (usz i, &entry : app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.SKIN && which == app.assets.entries.len) which = i;
	}
	if (which == app.assets.entries.len)
	{
		test::@check(false, "SKIPPED — the scratch library holds no skin");
		return;
	}

	String kept = app.assets.entries[which].name.copy(mem);
	defer alloc::free(mem, kept.ptr);
	test::@check(app.retag_asset(which, kept, "testplan", ""), "the file could not be written");

	test::@check(app.loaded_pack_for(file) >= 0, "tagging it did not read it");
	test::@check(app.plan_pack("testplan") >= 0, "and it is not offered as a body plan");
}

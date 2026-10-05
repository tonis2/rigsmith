<*
 The config file: the round trip, and everything it promises not to do.

 Half of these are about refusing to refuse. `core/config.c3` says a missing
 file, a malformed one and a version from the future all read as "no setting",
 and that is a promise nothing else in crig makes — the session file breaks the
 other way on purpose. A regression there would not look like a crash; crig
 would simply stop opening, or open with someone's settings quietly discarded,
 so each of those cases is spelled out here.

 Every check points `RIGSMITH_CONFIG_DIR` at a folder under `build`, which is what
 keeps a test run out of the config directory of whoever is running it. That is
 also the whole reason the variable exists — faking the path any other way would
 leave `load_config` untested on the path the app actually takes.
*>
module crig_tests::config;

import crig;
import std::core::test;


import std::io;
import std::io::file;
import std::io::path;
import std::math;
import std::os::env;

// Under `build`, which is not tracked, so a run leaves nothing to commit.
const String CONFIG_DIR = "build/test-config";

<*
 Point the config machinery at an empty folder of this check's own, and hand
 back the file path inside it.

 A folder per check, named after it: `c3c test` runs checks in one process, and
 two of them sharing a directory would make each one's result depend on which
 ran first — which is exactly the failure `c3c test`'s alphabetical ordering
 makes hardest to reproduce.

 The caller owns the returned string.
*>
fn String fresh(String name)
{
	if (catch path::mkdir((Path)CONFIG_DIR, recursive: true))
	{
		// Already there, which is the ordinary case after the first check.
	}

	String directory = string::format(mem, "%s/%s", CONFIG_DIR, name);
	defer alloc::free(mem, directory.ptr);
	if (catch path::mkdir((Path)directory, recursive: true))
	{
		// As above.
	}

	String file_path = string::format(mem, "%s/%s", directory, crig::CONFIG_FILE);
	(void)file::delete(file_path);

	env::set_var(crig::CONFIG_DIR_VAR, directory);
	return file_path;
}

// What a check leaves behind, so the next one starts from a known place.
fn void done(String file_path)
{
	alloc::free(mem, file_path.ptr);
	env::set_var(crig::CONFIG_DIR_VAR, "");
}

<*
 A first run: no file, and every setting at what crig would have used anyway.

 The port matters most. A default of 0 would read as "serve nothing", so a
 config that had never been written would silently turn the MCP server off —
 which is the shape of bug this check exists for.
*>
fn void a_first_run_has_defaults() @test
{
	String file_path = fresh("first-run");
	defer done(file_path);
	io::printn("nothing on disk:");

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	test::@check(config.recent.len() == 0, "nothing has been opened yet");
	test::@check(config.browse_directory.len == 0, "and the chooser has nowhere to start from");
	test::@check(config.mcp_port == crig::MCP_PORT, "the server is on its usual port, not off");
	test::@check(config.ui_scale == crig::DEFAULT_UI_SCALE,
		"the interface is at the size the display asks for (%.2f)", config.ui_scale);
	test::@check(config.rig_overlay_strength == crig::DEFAULT_RIG_OVERLAY_STRENGTH,
		"the rig overlay starts restrained (%.2f)", config.rig_overlay_strength);
	test::@check(!config.self_collision, "the self-collision system is on without being asked for");
	test::@check(!config.show_ghosts && config.ghost_past == crig::DEFAULT_GHOST_SIDE
		&& config.ghost_future == crig::DEFAULT_GHOST_SIDE && config.ghost_step == 1
		&& config.ghost_opacity == crig::DEFAULT_GHOST_OPACITY && config.ghost_spread == crig::DEFAULT_GHOST_SPREAD
		&& config.ghost_direction == 0, "ghosts start off with their usual settings");
	test::@check(config.directory.len > 0, "and the config knows where it would save");
}

<*
 What is written comes back.

 Asserted through `load_config` rather than by reading the file: the file's text
 is not the promise, what the next run sees is.
*>
fn void settings_survive_a_restart() @test
{
	String file_path = fresh("round-trip");
	defer done(file_path);
	io::printn("saved, then read back:");

	crig::CrigConfig written = crig::load_config();
	written.remember_recent("assets/animations/humanoid.glb");
	written.set_browse_directory("/tmp/models");
	written.mcp_port = 9001;
	written.ui_scale = 1.25;
	written.rig_overlay_strength = 0.45f;
	written.self_collision = true;
	written.hide_guide = true;
	written.tutorial_seen = true;
	written.viewport_shading = crig::ShadingMode.TEXTURED;
	written.show_ghosts = true;
	written.ghost_past = 7;
	written.ghost_future = 5;
	written.ghost_step = 4;
	written.ghost_opacity = 0.6f;
	written.ghost_spread = 0.3f;
	written.ghost_direction = 2;
	written.show_motion_path = true;
	written.anim_layers_ratio = 0.4f;
	written.joint_panel_tab = 3;
	written.folded_sections = 0b101000;
	written.save();
	written.free();

	test::@check(file::is_file(file_path), "saving writes the file");

	crig::CrigConfig read = crig::load_config();
	defer read.free();

	test::@check(read.recent.len() == 1, "the project comes back (%d entries)", read.recent.len());
	test::@check(read.browse_directory == "/tmp/models", "so does the chooser's directory");
	test::@check(read.mcp_port == 9001, "and the port");
	// A float through JSON and back, which is the one field here that does not
	// round-trip exactly by construction — hence the tolerance rather than `==`.
	test::@check(math::abs(read.ui_scale - 1.25f) < 0.001f,
		"and the interface size (%.3f)", read.ui_scale);
	test::@check(math::abs(read.rig_overlay_strength - 0.45f) < 0.001f,
		"and the rig overlay strength (%.3f)", read.rig_overlay_strength);
	test::@check(read.self_collision, "and the self-collision switch");
	test::@check(read.hide_guide, "and the hidden workflow guide");
	test::@check(read.tutorial_seen, "and the answered welcome");
	test::@check(read.viewport_shading == crig::ShadingMode.TEXTURED, "and the viewport shading");
	test::@check(read.show_ghosts && read.ghost_past == 7 && read.ghost_future == 5 && read.ghost_step == 4,
		"and the ghost counts and spacing (%d, %d, every %d)", read.ghost_past, read.ghost_future, read.ghost_step);
	test::@check(math::abs(read.ghost_opacity - 0.6f) < 0.001f, "and the ghost opacity (%.3f)", read.ghost_opacity);
	test::@check(math::abs(read.ghost_spread - 0.3f) < 0.001f && read.ghost_direction == 2,
		"and the ghost spread and direction (%.3f, %d)", read.ghost_spread, read.ghost_direction);
	test::@check(read.show_motion_path, "and the motion path");
	test::@check(math::abs(read.anim_layers_ratio - 0.4f) < 0.001f, "and the dock's divider (%.3f)", read.anim_layers_ratio);
	test::@check(read.joint_panel_tab == 3, "and the N-panel's open tab");
	test::@check(read.folded_sections == 0b101000, "and its folded sections");
}

<*
 A divider ratio the dock cannot draw reads as never dragged, and a first run has
 none: the dock then takes its default share.
*>
fn void an_impossible_dock_ratio_reads_as_the_default() @test
{
	String file_path = fresh("silly-ratio");
	defer done(file_path);

	crig::CrigConfig first = crig::load_config();
	test::@check(first.anim_layers_ratio == 0.0f && first.joint_panel_tab == 0 && first.folded_sections == 0,
		"a first run remembers nothing about the layout");
	first.free();

	if (catch file::save(file_path, `{ "version": 1, "anim_layers_ratio": 0.95, "joint_panel_tab": 40 }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}
	crig::CrigConfig config = crig::load_config();
	defer config.free();
	test::@check(config.anim_layers_ratio == 0.0f, "a ratio of 0.95 was adopted (%.2f)", config.anim_layers_ratio);
	test::@check(config.joint_panel_tab == 0, "a tab 40 was adopted");
}

<*
 A config from before ghosts were frames: `ghost_keys` is read as that many ghosts
 each side, the new keys win over it, and numbers out of range read as defaults.
*>
fn void the_retired_ghost_key_count_still_reads() @test
{
	String file_path = fresh("old-ghost-keys");
	defer done(file_path);

	if (catch file::save(file_path, `{ "version": 1, "show_ghosts": true, "ghost_keys": 2 }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}
	crig::CrigConfig old = crig::load_config();
	test::@check(old.show_ghosts && old.ghost_past == 2 && old.ghost_future == 2,
		"ghost_keys 2 did not become 2 each side (%d, %d)", old.ghost_past, old.ghost_future);
	test::@check(old.ghost_step == 1 && old.ghost_opacity == crig::DEFAULT_GHOST_OPACITY
		&& old.ghost_spread == crig::DEFAULT_GHOST_SPREAD && old.ghost_direction == 0, "and the rest stays default");
	old.save();
	old.free();

	crig::CrigConfig again = crig::load_config();
	test::@check(again.ghost_past == 2 && again.ghost_future == 2, "the migrated counts did not survive a save");
	again.free();

	if (catch file::save(file_path, `{ "version": 1, "ghost_keys": 2, "ghost_past": 9, "ghost_future": 0, "ghost_step": 3 }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}
	crig::CrigConfig both = crig::load_config();
	test::@check(both.ghost_past == 9 && both.ghost_future == 0 && both.ghost_step == 3,
		"the new keys did not win (%d, %d, %d)", both.ghost_past, both.ghost_future, both.ghost_step);
	both.free();

	if (catch file::save(file_path, `{ "version": 1, "ghost_past": 99, "ghost_future": -1, "ghost_step": 0, "ghost_opacity": 4, "ghost_spread": 3, "ghost_direction": 9 }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}
	crig::CrigConfig silly = crig::load_config();
	test::@check(silly.ghost_past == crig::DEFAULT_GHOST_SIDE && silly.ghost_future == crig::DEFAULT_GHOST_SIDE
		&& silly.ghost_step == 1 && silly.ghost_opacity == crig::DEFAULT_GHOST_OPACITY
		&& silly.ghost_spread == crig::DEFAULT_GHOST_SPREAD && silly.ghost_direction == 0,
		"impossible ghost settings were adopted");
	silly.free();
}

<*
 The switch is a bool or nothing: a hand-written 1 or "yes" is not read as
 on, the rule every field follows, and the system stays off.
*>
fn void the_self_collision_switch_reads_only_a_bool() @test
{
	String file_path = fresh("self-collision");
	defer done(file_path);

	String[3] refused = {
		`{ "version": 1, "self_collision": 1 }`,
		`{ "version": 1, "self_collision": "yes" }`,
		`{ "version": 1, "self_collision": null }`,
	};
	foreach (text : refused)
	{
		if (catch file::save(file_path, text[..])) continue;
		crig::CrigConfig config = crig::load_config();
		test::@check(!config.self_collision, "%s switched the system on", text);
		config.free();
	}
	if (catch file::save(file_path, `{ "version": 1, "self_collision": true }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}
	crig::CrigConfig on = crig::load_config();
	defer on.free();
	test::@check(on.self_collision, "true did not switch the system on");
}

<*
 A scale the file has no business holding reads as no setting at all.

 The clamp lives everywhere the program itself writes this, so the only way an
 absurd one arrives is a hand-edited file — and there the honest answer is the
 default rather than the nearest legal value: a 12 in the file is a typo, and 3
 is not what whoever typed it meant either. A zero matters most of the three,
 since it is the one that would lay the whole interface out in an infinite space
 and leave a window with nothing in it.
*>
fn void an_impossible_ui_scale_reads_as_the_default() @test
{
	String file_path = fresh("silly-scale");
	defer done(file_path);
	io::printn("a config asking for scales that are not scales:");

	String[3] refused = {
		`{ "version": 1, "ui_scale": 0 }`,
		`{ "version": 1, "ui_scale": -2 }`,
		`{ "version": 1, "ui_scale": 12.5 }`,
	};

	foreach (text : refused)
	{
		if (catch file::save(file_path, text[..]))
		{
			test::@check(false, "SKIPPED — could not write the fixture");
			return;
		}

		crig::CrigConfig config = crig::load_config();
		defer config.free();
		test::@check(config.ui_scale == crig::DEFAULT_UI_SCALE,
			"%s is not adopted (%.2f)", text, config.ui_scale);
	}

	// And the other half of the promise: one inside the range is taken, written
	// as a bare integer, which is what a person editing the file by hand types.
	if (catch file::save(file_path, `{ "version": 1, "ui_scale": 2 }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}

	crig::CrigConfig config = crig::load_config();
	defer config.free();
	test::@check(config.ui_scale == 2.0f, "an integer 2 is 2× (%.2f)", config.ui_scale);
}

fn void rig_overlay_strength_accepts_its_floor_and_refuses_outside_values() @test
{
	String file_path = fresh("rig-overlay-strength");
	defer done(file_path);

	if (catch file::save(file_path, `{ "version": 1, "rig_overlay_strength": 0.1 }`[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}
	crig::CrigConfig at_floor = crig::load_config();
	test::@check(math::abs(at_floor.rig_overlay_strength - crig::MIN_RIG_OVERLAY_STRENGTH) < 0.001f,
		"the slider floor survives JSON (%.3f)", at_floor.rig_overlay_strength);
	at_floor.free();

	String[3] refused = {
		`{ "version": 1, "rig_overlay_strength": 0 }`,
		`{ "version": 1, "rig_overlay_strength": -1 }`,
		`{ "version": 1, "rig_overlay_strength": 2 }`,
	};
	foreach (text : refused)
	{
		if (catch file::save(file_path, text[..])) continue;
		crig::CrigConfig config = crig::load_config();
		test::@check(config.rig_overlay_strength == crig::DEFAULT_RIG_OVERLAY_STRENGTH,
			"%s falls back to the restrained default (%.2f)", text, config.rig_overlay_strength);
		config.free();
	}
}

<*
 A recent path is stored absolute, whatever it was given as.

 The list outlives the working directory that produced it: crig started from
 somewhere else would otherwise resolve `assets/animations/humanoid.glb` against
 the wrong folder and offer a project that is not the one that was saved.
*>
fn void a_recent_project_is_stored_absolute() @test
{
	String file_path = fresh("absolute");
	defer done(file_path);
	io::printn("a relative path, remembered:");

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	config.remember_recent("assets/animations/humanoid.glb");
	test::@check(config.recent.len() == 1, "it was taken");
	if (config.recent.len() == 0) return;

	String held = config.recent[0];
	test::@check(held.len > 0 && held[0] == '/', "and stored from the root, not as given (%s)", held);
	test::@check(held.ends_with("assets/animations/humanoid.glb"), "still naming the same file (%s)", held);
}

<*
 The list is newest first, holds no path twice, and stops at MAX_RECENT.

 Re-opening a project is the common case, and the wrong answer to it is two
 entries for one file — which then costs a slot that a project the user has not
 seen in a while was using.
*>
fn void the_recent_list_is_newest_first_and_bounded() @test
{
	String file_path = fresh("ordering");
	defer done(file_path);
	io::printn("more projects than the list holds:");

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	// One more than fits, so the oldest has to fall off.
	String[6] opened = { "/a.glb", "/b.glb", "/c.glb", "/d.glb", "/e.glb", "/f.glb" };
	foreach (each : opened) config.remember_recent(each);

	test::@check(config.recent.len() == (sz)crig::MAX_RECENT,
		"the list stops at %d (%d entries)", crig::MAX_RECENT, config.recent.len());
	test::@check(config.recent[0] == "/f.glb", "newest first (%s)", config.recent[0]);
	test::@check(!config.holds_recent("/a.glb"), "and the oldest fell off the end");

	// The one already in the list, opened again: it moves rather than repeats.
	config.remember_recent("/c.glb");
	test::@check(config.recent[0] == "/c.glb", "re-opening puts it back on top (%s)", config.recent[0]);
	test::@check(config.recent.len() == (sz)crig::MAX_RECENT,
		"without growing the list (%d entries)", config.recent.len());

	usz seen = 0;
	foreach (held : config.recent.array_view())
	{
		if (held == "/c.glb") seen++;
	}
	test::@check(seen == 1, "and without appearing twice (%d times)", seen);
}

<*
 A path with a quote or a backslash in it survives the file.

 Written raw, one of those ends the JSON string early and the rest of the file
 stops parsing — which does not fail loudly, because a config that will not
 parse is defaults. Every setting would silently reset on the run after the one
 that opened such a file.
*>
fn void an_awkward_path_survives_the_file() @test
{
	String file_path = fresh("escaping");
	defer done(file_path);
	io::printn(`a path holding a " and a \:`);

	String awkward = `/tmp/a "quoted"\folder/goat.glb`;

	crig::CrigConfig written = crig::load_config();
	written.remember_recent(awkward);
	written.set_browse_directory(awkward);
	written.save();
	written.free();

	crig::CrigConfig read = crig::load_config();
	defer read.free();

	test::@check(read.recent.len() == 1, "the entry came back (%d entries)", read.recent.len());
	test::@check(read.browse_directory == awkward, "unmangled (%s)", read.browse_directory);
}

<*
 A file that is not a config reads as no config, and takes nothing with it.

 The half that matters is the second one: crig has to start. A reader that
 faulted here would turn a stray file in the config directory into an
 application that cannot be opened.
*>
fn void nonsense_reads_as_defaults() @test
{
	String file_path = fresh("nonsense");
	defer done(file_path);
	io::printn("a file that is not JSON:");

	if (catch file::save(file_path, "this is not a config{{{"[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	test::@check(config.recent.len() == 0, "nothing was adopted");
	test::@check(config.mcp_port == crig::MCP_PORT, "and the port is the default, not zero");
}

<*
 A config from a later crig still starts this one.

 The version is recorded, not enforced — unlike the session file, where it is
 the thing that says "this is ours". Here it would only ever be a reason to
 throw away settings that are still perfectly readable, and a key this crig does
 not know is simply not one of the keys it asks for.
*>
fn void a_newer_config_still_loads() @test
{
	String file_path = fresh("from-the-future");
	defer done(file_path);
	io::printn("a config written by a later crig:");

	String later = `{ "version": 99, "recent": ["/kept.glb"], "mcp_port": 9100,
		"something_added_later": { "nested": true } }`;
	if (catch file::save(file_path, later[..]))
	{
		test::@check(false, "SKIPPED — could not write the fixture");
		return;
	}

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	test::@check(config.recent.len() == 1, "the keys it does know are read (%d entries)", config.recent.len());
	test::@check(config.mcp_port == 9100, "including the port (%d)", config.mcp_port);
}

<*
 A config nobody loaded writes nothing.

 This is what lets an `AppState` carry one in a check that never asked for a
 config: `directory` is empty on a zero-initialised struct, and `save` is then
 a no-op rather than a write into the config of whoever is running the checks.
*>
fn void an_unbacked_config_saves_nothing() @test
{
	String file_path = fresh("unbacked");
	defer done(file_path);
	io::printn("a config with no file behind it:");

	crig::CrigConfig loose = { };
	loose.recent.init(mem);
	defer loose.free();

	loose.remember_recent("/somewhere.glb");
	test::@check(loose.recent.len() == 1, "it still keeps the entry in memory");
	test::@check(!file::is_file(file_path), "but writes nothing to disk");
}

<*
 A config that has never heard of asset libraries gets the one crig had before
 the setting existed.

 The compatibility that makes adding the key safe. crig read a single hard-coded
 folder; an install written by that version says nothing about libraries, and has
 to come up reading exactly the folder it always did rather than nothing at all —
 a browser that came up empty after an upgrade reads as the upgrade breaking it.
*>
fn void a_config_with_no_libraries_gets_the_built_in_one() @test
{
	String file_path = fresh("no-libraries");
	defer done(file_path);
	io::printn("a config predating the setting:");

	// A file that parses and carries every other key, but not this one — which is
	// what an older crig wrote.
	String older = `{"version":1,"recent":[],"browse_directory":"","mcp_port":8808}`;
	if (catch file::save(file_path, older)) 
	{
		test::@check(false, "SKIPPED — could not write the config");
		return;
	}

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	test::@check(config.libraries.len() == 1, "one library, not %d", config.libraries.len());
	test::@check(config.libraries[0].path == crig::DEFAULT_LIBRARY_PATH,
		"and it is the folder crig always read, not '%s'", config.libraries[0].path);

	// A first run, with no file at all, has to answer the same way — otherwise the
	// two paths into an unconfigured crig come up with different libraries.
	(void)file::delete(file_path);
	crig::CrigConfig fresh_run = crig::load_config();
	defer fresh_run.free();
	test::@check(fresh_run.libraries.len() == 1, "and a first run agrees with it");
	test::@check(fresh_run.libraries[0].path == crig::DEFAULT_LIBRARY_PATH);
}

<*
 Libraries survive a restart, in order, and an empty list stays empty.

 The empty case is the one worth writing down: an absent key means "never
 configured" and takes the default, but a list emptied on purpose has to stay
 empty. A browser that quietly put a folder back is one the user cannot turn off.
*>
fn void asset_libraries_survive_a_restart() @test
{
	String file_path = fresh("libraries");
	defer done(file_path);
	io::printn("libraries across a restart:");

	{
		crig::CrigConfig config = crig::load_config();
		defer config.free();

		// The built-in one is already there, so these make three in a known order.
		test::@check(config.add_library("/home/me/rigs", "My rigs"), "a new folder is added");
		test::@check(config.add_library("/home/me/clips"), "and another");
		test::@check(!config.add_library("/home/me/rigs", "Again"),
			"a path already listed is not added twice");
	}

	crig::CrigConfig back = crig::load_config();
	defer back.free();

	test::@check(back.libraries.len() == 3, "three libraries came back, not %d", back.libraries.len());
	test::@check(back.libraries[1].name == "My rigs" && back.libraries[1].path == "/home/me/rigs",
		"in the order they were added, names and all");
	// Named after its folder when it was added without one, which is what the file
	// chooser can offer — it hands back a path and nothing else.
	test::@check(back.libraries[2].name == "clips", "a folder added unnamed is called '%s'", back.libraries[2].name);

	// Emptied on purpose stays emptied.
	while (back.libraries.len() > 0) back.remove_library(0);
	crig::CrigConfig emptied = crig::load_config();
	defer emptied.free();
	test::@check(emptied.libraries.len() == 0,
		"a list emptied on purpose comes back empty, not refilled with the default");
}

<*
 A malformed library entry is skipped, and the good ones around it are kept.

 The rule every key here follows: this is a file a person can edit, so half an
 entry is treated as absent rather than adopted. Losing the whole list to one bad
 line would be the config refusing, which nothing here does.
*>
fn void a_malformed_library_is_skipped() @test
{
	String file_path = fresh("bad-library");
	defer done(file_path);
	io::printn("a library list with rubbish in it:");

	// One whole entry, then every way of being half an entry, then another whole
	// one — so a reader that gave up at the first bad row would lose "/b" and be
	// caught by the count below.
	String mixed = `{"version":1,"asset_libraries":[{"name":"Good","path":"/a"},{"name":"No path"},{"path":"/no-name-either"},"not an object",{"name":"Also good","path":"/b"}]}`;
	if (catch file::save(file_path, mixed))
	{
		test::@check(false, "SKIPPED — could not write the config");
		return;
	}

	crig::CrigConfig config = crig::load_config();
	defer config.free();

	test::@check(config.libraries.len() == 2,
		"the two whole entries were kept and nothing else, got %d", config.libraries.len());
	test::@check(config.libraries[0].path == "/a" && config.libraries[1].path == "/b",
		"and they are the two that named both a name and a path");
}

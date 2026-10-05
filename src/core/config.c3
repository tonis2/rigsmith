<*
 The config file: what crig remembers between runs.

 `<config dir>/crig/config.json`, where the directory is the platform's own —
 `~/Library/Application Support` on macOS, `$XDG_CONFIG_HOME` or `~/.config`
 elsewhere — or whatever `RIGSMITH_CONFIG_DIR` names. One object:

     { "version": 1,
       "recent": ["/Users/me/models/goat.glb", ...],
       "browse_directory": "/Users/me/models",
       "asset_libraries": [{ "name": "Built-in", "path": "assets/animations" }, ...],
       "mcp_port": 8808,
       "ui_scale": 1.0,
       "self_collision": false,
       "hide_guide": false,
       "tutorial_seen": false,
       "hide_floor": false,
       "viewport_shading": 0,
       "show_ghosts": false,
       "ghost_keys": 1,
       "show_motion_path": false,
       "anim_layers_ratio": 0.25,
       "joint_panel_tab": 0,
       "folded_sections": 0,
       "motion_generator": { "text_model": "/models/Llama-3-Kimodo-Q8_0.gguf", ... } }

 **Nothing here refuses.** A session that will not parse is rejected, because
 rigging the wrong model is worse than rigging none — but a config that did the
 same would stop crig opening at all over a key it did not recognise. So a
 missing file, a malformed one, an unreadable directory, a version from the
 future and a key that means nothing here all read as "no setting", and every
 field falls back to what a first run would have used. It follows that a config
 written by a later crig still starts an earlier one, which is the property that
 makes it safe to add keys.

 Saving is best-effort for the same reason: a read-only config directory is not
 grounds for refusing to open a model.

 What is *not* here is anything about the document. A dot, a bone or a body plan
 belongs to a rig and travels with it in the session file beside the mesh; this
 holds only what is true of the application whatever it has open.

 Lives in `core/` with no cui, so the round trip is assertable with no window.
*>
module crig;

import std::collections::list;
import std::collections::object;


import std::encoding::json;
import std::io;
import std::io::file;
import std::io::path;
import std::os::env;

// Bumped when a key's *meaning* changes. Adding one does not need it: an older
// crig ignores what it does not know, and a newer one falls back when a key is
// absent, so both directions already work.
const uint CONFIG_VERSION = 1;

// The Animations dock's Layers column: the share of the dock's width it takes
// by default, and the range the divider keeps it within.
const float DEFAULT_LAYERS_RATIO = 0.25f;
const float MIN_LAYERS_RATIO = 0.12f;
const float MAX_LAYERS_RATIO = 0.6f;

<*
 How many projects the recent list holds.

 Five because that is what fits the panel without scrolling and what a person
 can pick from at a glance. Past it the list stops being a shortcut and becomes
 a second file browser, which crig already has.
*>
const usz MAX_RECENT = 5;

// Under the platform's config directory, so crig's file sits beside every other
// application's rather than loose in the home directory.
const String CONFIG_FOLDER = "rigsmith";
const String CONFIG_FILE = "config.json";

// Names the directory the config is read from and written to, overriding the
// platform's. Set by anything that must not touch the real one — the checks in
// `crig_tests::config` are the reason it exists.
const String CONFIG_DIR_VAR = "RIGSMITH_CONFIG_DIR";

<*
 The library crig opens with when the config says nothing about libraries.

 The folder the shipped body plans are written into, resolved against the working
 directory like the font — so crig still has to be run from its own directory to
 see them. A first run and an install that predates the setting both come up with
 exactly this one entry, which is the library crig had before it had a list.
*>
const String DEFAULT_LIBRARY_NAME = "Built-in";
const String DEFAULT_LIBRARY_PATH = "assets/animations";

<*
 The port crig serves MCP on when nothing says otherwise.

 Fixed rather than negotiated, because the other end of the wire is a client
 configuration file — `{"type": "http", "url": "http://127.0.0.1:8808/mcp"}` —
 written before crig starts and with no way to ask. `--mcp-port` and the
 `mcp_port` key both move it, and then that URL has to move with them.

 Here rather than beside the server for a build reason as much as a tidiness
 one: `make-anims` compiles `src/core/**` without `src/mcp/**`, so a default
 this file reads has to live in a file that target sees.
*>
const int MCP_PORT = 8808;

<*
 How much bigger or smaller than the display asks for the interface is drawn.

 A *multiplier on the display's own density*, not the density itself — see
 `ui/ui_scale.c3`, which is where the two are put together. 1.0 therefore means
 "whatever this screen says a point is", which is right on every machine and is
 why it is the default; the setting exists for the two cases the screen is wrong
 about, a dense laptop panel read at arm's length and a 4K television read from a
 sofa.

 The ends are a taste judgement rather than a technical limit: below a half the
 glyphs stop resolving and above three a menu bar is taller than a dialog. The
 engine clamps the *product* to its own range on top of this.

 Here rather than beside the widgets for the reason every other constant in this
 file is: `make-anims` compiles `src/core/**` without `src/ui/**`, and a default
 this file reads has to live where that target can see it.
*>
const float DEFAULT_UI_SCALE = 1.0;
const float MIN_UI_SCALE = 0.5;
const float MAX_UI_SCALE = 3.0;

// The rig remains depth-faded at every strength; this only scales the
// unselected overlay. A non-zero floor keeps every visible control legible and
// clickable, while View > Skeleton remains the explicit clean-mesh switch.
const float DEFAULT_RIG_OVERLAY_STRENGTH = 1.0;
const float MIN_RIG_OVERLAY_STRENGTH = 0.1;
const float MAX_RIG_OVERLAY_STRENGTH = 1.0;

<*
 A folder of assets, under the name the browser shows it by.

 The name is the user's to pick and is not required to be unique or to resemble
 the path — it is a label, not a key. What identifies a library is its position
 in `CrigConfig.libraries`, which is why an `AssetEntry` carries that index and
 not a name.

 Both strings are owned by the `CrigConfig` holding them.
*>
struct AssetLibrary
{
	String name;
	String path;
}

alias AssetLibraries = List{AssetLibrary};

<*
 The Kimodo weights text-to-motion runs: the pipeline itself is llm.c3l's
 `kimodo` plugin, linked into crig, so what a user supplies is only the weights
 (File › Settings › AI). See `app/generate.c3`, which is the only reader.

 Every path is taken as written and none is checked here — a missing file is a
 setting that says so when it is used, not a config that fails to load.
 `output` defaults to `generated` in crig's config directory and has no field
 in Settings. Owned; empty means unset.
*>
struct MotionGenerator
{
	String text_model; // Llama-3-Kimodo-*.gguf
	String tokenizer;  // Kimodo's tokenizer.gguf, when it is not beside the text model
	String model;      // the motion checkpoint: kimodo-*.gguf, or NVIDIA's release folder (or its model.safetensors)
	String output;     // the folder generated clips are written to
}
alias RecentPaths = List{String};

<*
 Everything crig carries from one run to the next.

 Read with `load_config`, which never fails, and written with `save`, which
 never reports failing. Both are cheap enough to call on any change worth
 keeping — the file is a few hundred bytes.
*>
struct CrigConfig
{
	<*
	 The projects most recently opened or saved, newest first.

	 Absolute, so an entry still names the same file when crig is started from
	 another directory; at most `MAX_RECENT`, and never the same path twice.
	 Owned by this struct.

	 A path here is a *mesh*, not a session — the session lives beside the mesh
	 and is found from it, so the mesh is the one name that opens a project.
	*>
	RecentPaths recent;

	// Where the file chooser last was, so the next opening starts there rather
	// than in the working directory. Owned; empty until a directory is visited.
	String browse_directory;

	<*
	 The folders the asset browser reads, in the order they are listed. Owned.

	 Never empty after `load_config`: a config that names none is given the
	 built-in one, because a browser with no libraries at all cannot be told from
	 a broken build. A user who wants none removes the entry and gets an empty
	 browser, which is a different thing and is honoured.
	*>
	AssetLibraries libraries;

	// The port the MCP server binds; 0 serves nothing, which is what turning the
	// server off means here — there is no separate switch, and a port nothing
	// listens on is indistinguishable from one that was never asked for.
	//
	// Defaults to `MCP_PORT`, which is a fact about this file rather than about
	// the server: the server binds whatever it is handed, and this is what a run
	// that was told nothing hands it.
	int mcp_port;

	<*
	 How big the interface is drawn, as a multiple of what the display asks for.

	 `DEFAULT_UI_SCALE` when nothing says otherwise, and never outside
	 `MIN_UI_SCALE`..`MAX_UI_SCALE` — a hand-edited 0 or a negative would
	 otherwise be a window with no interface in it at all, which is not a setting
	 anybody can undo from inside the program.
	*>
	float ui_scale;

	// Visibility of unselected joints and bones. Selected controls are always
	// full strength so reducing clutter never hides the thing being edited.
	float rig_overlay_strength;

	<*
	 Whether posing is checked against the mesh at all — the self-collision
	 system of `app/collision.c3`, whole: the policy over the skin, the blocked
	 turns and pulls, and every control and readout of it.

	 Off unless asked for. It stops a hand at the body, which is what it is
	 for, and on a rig it reads wrongly it stops a hand short of it, which is
	 what it must not do to someone who never asked; until it is trusted on
	 rigs its authors have not seen, a person turns it on rather than off.
	 With it off the per-rig *Prevent intersections* control is not shown
	 and means nothing, whatever the session holds.
	*>
	bool self_collision;

	// The workflow guide bar across the 3D view's header (View > Workflow guide).
	// Shown unless hidden, so a zero-initialised config shows it.
	bool hide_guide;

	// The welcome dialog has been answered (Start or Skip), so the first-run
	// offer does not come back. False in a zero-initialised config.
	bool tutorial_seen;

	// The floor grid under the model (View > Floor). Shown unless hidden, like
	// the guide.
	bool hide_floor;

	// How the 3D view draws the model: Solid, Textured or Wireframe. Solid is
	// zero, so a config without the key keeps the grey model crig always drew.
	ShadingMode viewport_shading;

	// The animation aids in the transport row: previous/next-key ghost skeletons
	// (`ghost_keys` each side, 0 read as 1) and the selected joint's motion path.
	bool show_ghosts;
	int ghost_keys;
	bool show_motion_path;

	// The Animations dock's divider: the share of its width the Layers column takes
	// (0 = never dragged, read as `DEFAULT_LAYERS_RATIO`).
	float anim_layers_ratio;

	// Which tab of the N-panel was open (a `JointPanelTab` ordinal) and which of its
	// Disclosure sections, and the layer form's, were folded (`FoldedSection` bits).
	int joint_panel_tab;
	uint folded_sections;

	// Text-to-motion; unset until the config names a runner.
	MotionGenerator motion_generator;

	<*
	 Where `save` writes, without the file name. Owned.

	 Empty means this config is backed by no file and `save` does nothing. That
	 is what a zero-initialised one is, so an `AppState` built in a check cannot
	 write into the config of whoever is running the checks — only `load_config`
	 fills it in.
	*>
	String directory;
}

<*
 The directory crig's config lives in, or the empty string when there is none to
 be had — no `RIGSMITH_CONFIG_DIR`, no `HOME`, nothing to guess from.

 Does not create it; `save` does that, and only when it has something to write.

 The caller owns the returned string.
*>
fn String config_home(Allocator allocator)
{
	if (try String named = env::get_var(allocator, CONFIG_DIR_VAR))
	{
		if (named.len > 0) return named;
		alloc::free(allocator, named.ptr);
	}

	Path? platform = env::get_config_dir(allocator);
	if (catch platform) return "";
	defer platform.free(allocator);

	return string::format(allocator, "%s/%s", (String)platform, CONFIG_FOLDER);
}

<*
 Read the config, or hand back the defaults.

 Never fails and never faults: see this file's header. A first run, an empty
 file and a file full of nonsense are all the same answer, because none of them
 is a reason to do anything other than start.

 The caller owns the result and frees it with `CrigConfig.free`.
*>
fn CrigConfig load_config()
{
	CrigConfig config = {
		.mcp_port = MCP_PORT,
		.ui_scale = DEFAULT_UI_SCALE,
		.rig_overlay_strength = DEFAULT_RIG_OVERLAY_STRENGTH,
		.directory = config_home(mem),
	};
	config.recent.init(mem);
	config.libraries.init(mem);

	// Every way of ending up with nothing parsed — no config directory, no file, a
	// file that is not JSON — has to leave the same libraries behind as a file
	// that parsed and named none, which is why each of these exits through
	// `default_libraries` rather than straight out.
	if (config.directory.len == 0)
	{
		config.default_libraries();
		return config;
	}

	String path = string::format(mem, "%s/%s", config.directory, CONFIG_FILE);
	defer alloc::free(mem, path.ptr);

	char[]? content = file::load(mem, path);
	if (catch content)
	{
		config.default_libraries();
		return config;
	}
	defer alloc::free(mem, content);

	Object*? parsed = json::parse(mem, (String)content);
	if (catch parsed)
	{
		config.default_libraries();
		return config;
	}
	defer parsed.free();

	config.adopt(parsed);
	return config;
}

<*
 The library list a config with nothing to say about libraries comes up with.

 Only when the list is empty, so this cannot double an entry `adopt_libraries`
 already took — and so an explicitly empty list, once adopted, is not refilled by
 a later call.
*>
fn void CrigConfig.default_libraries(&self)
{
	if (self.libraries.len() > 0) return;
	self.libraries.push({ DEFAULT_LIBRARY_NAME.copy(mem), DEFAULT_LIBRARY_PATH.copy(mem) });
}

<*
 Take from a parsed config whatever it says, leaving the rest at its default.

 Every field is optional and every field is checked, because this is reading a
 file a person can edit: a port outside the range a port has, or a recent entry
 that is not a string, is treated as absent rather than adopted.
*>
fn void CrigConfig.adopt(&self, Object* parsed)
{
	if (try String directory = parsed.get_string("browse_directory"))
	{
		if (directory.len > 0) self.browse_directory = directory.copy(mem);
	}

	if (try int port = parsed.get_int("mcp_port"))
	{
		// 0 is meaningful — it is the off switch — so the range starts there.
		if (port >= 0 && port <= 65535) self.mcp_port = port;
	}

	// `get_float` takes a JSON integer as well as a real, so a hand-written
	// `"ui_scale": 2` is the setting it looks like rather than a type mismatch.
	// Out of range reads as absent, the rule every field here follows — the
	// clamp is not applied silently, because a 12 in the file is a typo and 3 is
	// not what the person meant either.
	if (try double wanted = parsed.get_float("ui_scale"))
	{
		if (wanted >= (double)MIN_UI_SCALE && wanted <= (double)MAX_UI_SCALE) self.ui_scale = (float)wanted;
	}

	if (try double wanted = parsed.get_float("rig_overlay_strength"))
	{
		float strength = (float)wanted;
		if (strength >= MIN_RIG_OVERLAY_STRENGTH
			&& strength <= MAX_RIG_OVERLAY_STRENGTH)
		{
			self.rig_overlay_strength = strength;
		}
	}

	// A bool or nothing: a hand-written 1 is not read as on, on the rule
	// every field here follows.
	if (try bool wanted = parsed.get_bool("self_collision")) self.self_collision = wanted;
	if (try bool wanted = parsed.get_bool("hide_guide")) self.hide_guide = wanted;
	if (try bool wanted = parsed.get_bool("tutorial_seen")) self.tutorial_seen = wanted;
	if (try bool wanted = parsed.get_bool("hide_floor")) self.hide_floor = wanted;
	if (try double wanted = parsed.get_float("viewport_shading"))
	{
		if (wanted >= 0 && wanted <= ShadingMode.WIREFRAME.ordinal) self.viewport_shading = (ShadingMode)(int)wanted;
	}
	if (try bool wanted = parsed.get_bool("show_ghosts")) self.show_ghosts = wanted;
	if (try bool wanted = parsed.get_bool("show_motion_path")) self.show_motion_path = wanted;
	if (try double wanted = parsed.get_float("ghost_keys"))
	{
		if (wanted >= 1 && wanted <= MAX_GHOST_KEYS) self.ghost_keys = (int)wanted;
	}
	// A ratio outside what the divider can reach reads as absent, like ui_scale.
	if (try double wanted = parsed.get_float("anim_layers_ratio"))
	{
		if (wanted >= MIN_LAYERS_RATIO && wanted <= MAX_LAYERS_RATIO) self.anim_layers_ratio = (float)wanted;
	}
	if (try double wanted = parsed.get_float("joint_panel_tab"))
	{
		if (wanted >= 0 && wanted <= 15) self.joint_panel_tab = (int)wanted;
	}
	if (try double wanted = parsed.get_float("folded_sections"))
	{
		if (wanted >= 0 && wanted < 4294967296.0) self.folded_sections = (uint)wanted;
	}

	self.adopt_libraries(parsed);
	self.adopt_motion_generator(parsed);

	Object*? listed = parsed.get("recent");
	if (catch listed) return;

	// `is_indexable`, not `is_array`: an empty JSON list parses as the empty
	// object and answers false to `is_array`, so a config saved with nothing in
	// its recent list would look malformed.
	if (listed.is_null() || !listed.is_indexable()) return;

	for (sz i = 0; i < listed.get_len() && self.recent.len() < (sz)MAX_RECENT; i++)
	{
		String? entry = listed.get_string_at(i);
		if (catch entry) continue;
		if (entry.len == 0) continue;
		if (self.holds_recent(entry)) continue;
		self.recent.push(entry.copy(mem));
	}
}

<*
 Take the library list, or fall back to the built-in one.

 The absent key and the empty list are deliberately different answers. No key at
 all is a config that predates the setting — or a first run — and gets the
 library crig has always had. A key holding nothing is someone who removed every
 entry, and is left with nothing, because a browser that quietly re-adds a folder
 the user deleted is a browser they cannot turn off.

 An entry missing either string is skipped rather than half-adopted: a library
 with no path names nothing, and one with no name has nothing for the browser's
 dropdown to say.
*>
fn void CrigConfig.adopt_libraries(&self, Object* parsed)
{
	Object*? listed = parsed.get("asset_libraries");
	if (catch listed)
	{
		self.libraries.push({ DEFAULT_LIBRARY_NAME.copy(mem), DEFAULT_LIBRARY_PATH.copy(mem) });
		return;
	}

	// `is_indexable` for the reason `adopt` gives about the recent list: an empty
	// JSON list comes back as the empty object, which is not an array.
	if (listed.is_null() || !listed.is_indexable()) return;

	for (sz i = 0; i < listed.get_len(); i++)
	{
		Object*? entry = listed.get_at(i);
		if (catch entry) continue;

		// Asked before anything is read off it: `get_string` requires a keyable
		// object, so a bare string or number in the list is not a missing field —
		// it is a contract violation that takes the process down. A hand-edited
		// config is exactly where one turns up.
		if (!entry.is_keyable()) continue;

		String? name = entry.get_string("name");
		String? library_path = entry.get_string("path");
		if (catch name) continue;
		if (catch library_path) continue;
		if (library_path.len == 0) continue;

		self.libraries.push({ name.copy(mem), library_path.copy(mem) });
	}
}

<*
 Take the motion generator's paths, each only when it is a non-empty string.
*>
fn void CrigConfig.adopt_motion_generator(&self, Object* parsed)
{
	Object*? found = parsed.get("motion_generator");
	if (catch found) return;
	if (!found.is_keyable()) return;

	foreach (key : (String[]){ "text_model", "tokenizer", "model", "output" })
	{
		String? value = found.get_string(key);
		if (catch value) continue;
		if (value.len > 0) *self.motion_generator.path_of(key) = value.copy(mem);
	}
}

<*
 The generator's path named by its config key, or null for a key it does not
 have. The one list of keys the settings panel and the reader share.
*>
fn String* MotionGenerator.path_of(&self, String key)
{
	switch (key)
	{
		case "text_model": return &self.text_model;
		case "tokenizer": return &self.tokenizer;
		case "model": return &self.model;
		case "output": return &self.output;
		default: return null;
	}
}

<*
 Set one of the generator's paths and write the config out. Surrounding space is
 dropped; empty unsets it.

 @return `False for a key the generator does not have.`
*>
fn bool CrigConfig.set_motion_path(&self, String key, String value)
{
	String* held = self.motion_generator.path_of(key);
	if (!held) return false;
	value = value.trim();
	if (*held == value) return true;
	if (held.len > 0) alloc::free(mem, held.ptr);
	*held = value.len > 0 ? value.copy(mem) : "";
	self.save();
	return true;
}

<*
 Add a library and write the config out.

 Named after its folder when no name is given, which is what the file chooser can
 offer — it hands back a path and nothing else. A path already listed is left
 alone rather than added twice, so a folder picked again is not two libraries
 holding the same assets.

 @param library_path : `The folder; ignored when empty.`
 @param name : `The label to list it under; the folder's own last component when empty.`
 @return `Whether the list changed — false means the path was already there.`
*>
fn bool CrigConfig.add_library(&self, String library_path, String name = "")
{
	if (library_path.len == 0) return false;
	foreach (held : self.libraries.array_view())
	{
		if (held.path == library_path) return false;
	}

	String label = name.len > 0 ? name : last_component(library_path);
	self.libraries.push({ label.copy(mem), library_path.copy(mem) });
	self.save();
	return true;
}

<*
 Drop the library at this position and write the config out.

 @param index : `Which library; out of range is a no-op, not a fault.`
 @return `Whether anything was removed.`
*>
fn bool CrigConfig.remove_library(&self, sz index)
{
	if (index < 0 || index >= self.libraries.len()) return false;

	AssetLibrary dropped = self.libraries[index];
	if (dropped.name.len > 0) alloc::free(mem, dropped.name.ptr);
	if (dropped.path.len > 0) alloc::free(mem, dropped.path.ptr);
	self.libraries.remove_at(index);

	self.save();
	return true;
}

<*
 The last component of a path, as a label for a folder that came without one.

 Trailing separators are stepped over, so "/home/me/rigs/" is named "rigs" like
 "/home/me/rigs" is. A path that is nothing but separators has no component to
 take, and comes back whole.

 Borrowed from `library_path` — copy it if it must outlive that.
*>
fn String last_component(String library_path) @private
{
	usz end = library_path.len;
	while (end > 0 && library_path[end - 1] == '/') end--;
	if (end == 0) return library_path;

	usz start = end;
	while (start > 0 && library_path[start - 1] != '/') start--;
	return library_path[start:end - start];
}

// Whether the list already names this exact path.
fn bool CrigConfig.holds_recent(&self, String path)
{
	foreach (held : self.recent.array_view())
	{
		if (held == path) return true;
	}
	return false;
}

<*
 Put a project at the top of the recent list and write the config out.

 Absolute before it is stored: a relative path names a different file the moment
 crig is started from somewhere else, and the list outlives the working
 directory that produced it. An entry already in the list moves to the top
 rather than appearing twice, and the oldest falls off the end past `MAX_RECENT`.

 Saves, so a run that ends badly still leaves the list as it was — which is the
 one setting here that would be missed.

 @param mesh_path : `The model that was opened or saved; ignored when empty.`
*>
fn void CrigConfig.remember_recent(&self, String mesh_path)
{
	if (mesh_path.len == 0) return;

	String stored;
	if (try Path full = mesh_path.to_absolute_path(mem))
	{
		stored = ((String)full).copy(mem);
		full.free(mem);
	}
	else
	{
		// Nothing to resolve against — no working directory, or a path the
		// platform will not answer for. Stored as given, which is worth more
		// than dropping the entry.
		stored = mesh_path.copy(mem);
	}

	foreach (sz i, held : self.recent.array_view())
	{
		if (held != stored) continue;
		alloc::free(mem, held.ptr);
		self.recent.remove_at(i);
		break;
	}

	self.recent.insert_at(0, stored);
	while (self.recent.len() > (sz)MAX_RECENT)
	{
		String dropped = self.recent.pop()!!;
		alloc::free(mem, dropped.ptr);
	}

	self.save();
}

<*
 Remember where the file chooser is. Does not save — the browser reports this on
 every step into a folder, and a file write per double-click is not worth it.
 `save` is called when the run ends and by `remember_recent`.
*>
fn void CrigConfig.set_browse_directory(&self, String directory)
{
	if (self.browse_directory.len > 0) alloc::free(mem, self.browse_directory.ptr);
	self.browse_directory = directory.len > 0 ? directory.copy(mem) : "";
}

<*
 The config as the file holds it, which is not quite as `CrigConfig` holds it.

 Two differences, both deliberate. The lists are slices, because a `List` is not
 something the marshaller will write — and slices borrowed from the config cost
 nothing, since marshalling only reads. And `directory` is absent: it is where
 the file was found, not a setting in it, and a config that recorded its own
 location would be wrong the moment it was copied anywhere.

 Member order here is key order in the file.

 Borrows every string from the `CrigConfig` it was built from, so it must not
 outlive it.
*>
struct ConfigFile @private
{
	uint version;
	String[] recent;
	String browse_directory;
	AssetLibrary[] asset_libraries;
	int mcp_port;
	float ui_scale;
	float rig_overlay_strength;
	bool self_collision;
	bool hide_guide;
	bool tutorial_seen;
	bool hide_floor;
	int viewport_shading;
	bool show_ghosts;
	int ghost_keys;
	bool show_motion_path;
	float anim_layers_ratio;
	int joint_panel_tab;
	uint folded_sections;
	MotionGenerator motion_generator;
}

<*
 Write the config out, creating its directory if that is what is missing.

 Reports nothing. A config that cannot be written is a setting that will not be
 there next time, which is a smaller problem than any way of complaining about
 it would be — and there is nothing the person at the screen could do about it
 mid-edit anyway.

 Does nothing when `directory` is empty, which is what makes a config nobody
 loaded harmless to hold.
*>
fn void CrigConfig.save(&self)
{
	if (self.directory.len == 0) return;

	if (catch path::mkdir((Path)self.directory, recursive: true))
	{
		// Already there, or cannot be made. The write below answers which, and
		// the answer is not acted on either way.
	}

	// Every member is a key, so the two lists are written whether or not they
	// hold anything: a list emptied on purpose comes out as a present key
	// holding nothing rather than an absent one — which is what
	// `adopt_libraries` reads as "no libraries" instead of "never configured".
	ConfigFile written = {
		.version = CONFIG_VERSION,
		.recent = self.recent.array_view(),
		.browse_directory = self.browse_directory,
		.asset_libraries = self.libraries.array_view(),
		.mcp_port = self.mcp_port,
		.ui_scale = self.ui_scale,
		.rig_overlay_strength = self.rig_overlay_strength,
		.self_collision = self.self_collision,
		.hide_guide = self.hide_guide,
		.tutorial_seen = self.tutorial_seen,
		.hide_floor = self.hide_floor,
		.viewport_shading = self.viewport_shading.ordinal,
		.show_ghosts = self.show_ghosts,
		.ghost_keys = self.ghost_keys,
		.show_motion_path = self.show_motion_path,
		.anim_layers_ratio = self.anim_layers_ratio,
		.joint_panel_tab = self.joint_panel_tab,
		.folded_sections = self.folded_sections,
		.motion_generator = self.motion_generator,
	};

	// `marshal_try` rather than `marshal`, which aborts on a number JSON cannot
	// hold. The one float here is clamped to a small range by everything that
	// writes it, so there is no such number — but a config taking the process
	// down is the one thing this file does not do.
	String? text = json::marshal_try(mem, written, JsonIndent.SPACE_2);
	if (catch text) return;
	defer alloc::free(mem, text.ptr);

	String path = string::format(mem, "%s/%s", self.directory, CONFIG_FILE);
	defer alloc::free(mem, path.ptr);

	File? out = file::open(path, "w");
	if (catch out) return;
	defer (void)out.close();
	(void)out.write(text);
}

fn void CrigConfig.free(&self)
{
	foreach (held : self.recent.array_view()) alloc::free(mem, held.ptr);
	self.recent.free();
	foreach (library : self.libraries.array_view())
	{
		if (library.name.len > 0) alloc::free(mem, library.name.ptr);
		if (library.path.len > 0) alloc::free(mem, library.path.ptr);
	}
	self.libraries.free();
	if (self.browse_directory.len > 0) alloc::free(mem, self.browse_directory.ptr);
	MotionGenerator* g = &self.motion_generator;
	foreach (held : (String[]){ g.text_model, g.tokenizer, g.model, g.output })
	{
		if (held.len > 0) alloc::free(mem, held.ptr);
	}
	if (self.directory.len > 0) alloc::free(mem, self.directory.ptr);
	*self = { };
}

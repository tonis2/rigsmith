<*
 Where the shipped assets are: the font, the built-in library, the tutorial model,
 and the user's own copy of the library that a packaged build makes.

 Every one of them is spelled relative — `assets/DejaVuSans.ttf` — and a checkout
 runs from its own directory, so the working directory finds them. A packaged
 build does not: an AppImage, a macOS .app or an unzipped Windows folder is
 started by a launcher from whatever directory it likes, so the assets are found
 beside the executable instead, and `main` says where before anything reads one.

 `bundle_root` is that directory — the one *holding* `assets/` — or empty, which
 means the working directory, and is what a checkout and every test run with.

 Here rather than in main because the config reads it, and `make-anims` compiles
 `src/core/**` without main.
*>
module crig;

import std::io;
import std::io::file;
import std::io::path;

String bundle_root;

<*
 The built-in library's copy in the user's Documents — `~/Documents/Rigsmith/animations`
 — or empty. Only a packaged build makes one: there the shipped folder is inside
 an .app the Finder hides, or an AppImage mount that moves every run, and neither
 is somewhere a person can drop a file or find one again. A checkout leaves this
 empty and keeps reading `assets/animations` in place.
*>
String user_library;

const String USER_FOLDER @private = "Rigsmith";

// What a directory has to hold to be the bundle: the font, which every run reads.
const String BUNDLE_MARKER @private = "assets/DejaVuSans.ttf";

<*
 A shipped asset's path: `relative` itself from a checkout, or under the bundle.

 @return `The path, in the temporary allocator when it was rewritten.`
*>
fn String bundled(String relative)
{
	if (bundle_root.len == 0) return relative;
	return string::tformat("%s/%s", bundle_root, relative);
}

<*
 Pick `bundle_root` from candidate directories: the first that holds the font,
 unless the working directory already does. Keeps a copy.
*>
fn void choose_bundle_root(String[] candidates)
{
	if (file::is_file(BUNDLE_MARKER)) return;
	foreach (candidate : candidates)
	{
		if (!file::is_file(string::tformat("%s/%s", candidate, BUNDLE_MARKER))) continue;
		bundle_root = candidate.copy(mem);
		return;
	}
}

<*
 Copy the shipped animations into `user_library`, and point it there.

 Only the files that are not there already: a newer release brings its new body
 plans along, and a file the user changed is never written over. Anything that
 fails — no Documents folder, nowhere writable — leaves `user_library` empty, and
 the library is read from the bundle as before.
*>
fn void install_user_library() => @pool()
{
	if (bundle_root.len == 0) return;
	String shipped = bundled(DEFAULT_LIBRARY_PATH);
	if (!file::is_dir(shipped)) return;

	Path? documents = path::documents_directory(tmem);
	if (catch documents) return;
	String target = string::tformat("%s/%s/animations", (String)documents, USER_FOLDER);
	if (catch path::mkdir(target, true)) return;
	if (!file::is_dir(target)) return;

	Path? from_dir = path::new(tmem, shipped);
	if (catch from_dir) return;
	PathList? found = path::ls(tmem, from_dir, no_dirs: true, mask: "*.glb");
	if (catch found) return;

	foreach (name : found)
	{
		String to = string::tformat("%s/%s", target, (String)name);
		if (file::exists(to)) continue;
		if (!copy_file(string::tformat("%s/%s", shipped, (String)name), to))
		{
			io::eprintfn("rigsmith: could not copy %s into %s", (String)name, target);
		}
	}
	user_library = target.copy(mem);
}

<*
 The built-in library as the config holds it in memory: the user's copy when
 there is one, else under the bundle when there is one. Owned.
*>
fn String default_library_path()
{
	if (user_library.len > 0) return user_library.copy(mem);
	return bundled(DEFAULT_LIBRARY_PATH).copy(mem);
}

<*
 What a library path is written to the config file as. The built-in library is
 written in its relative spelling, so a config never remembers the folder one
 particular AppImage happened to be mounted at.
*>
fn String stored_library_path(String library_path)
{
	if (user_library.len > 0 && library_path == user_library) return DEFAULT_LIBRARY_PATH;
	if (bundle_root.len > 0 && library_path == bundled(DEFAULT_LIBRARY_PATH)) return DEFAULT_LIBRARY_PATH;
	return library_path;
}

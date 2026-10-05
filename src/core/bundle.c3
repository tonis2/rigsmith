<*
 Where the shipped assets are: the font, the built-in library, the tutorial model.

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

import std::io::file;

String bundle_root;

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
 The built-in library as the config holds it in memory: under the bundle when
 there is one. Owned.
*>
fn String default_library_path() => bundled(DEFAULT_LIBRARY_PATH).copy(mem);

<*
 What a library path is written to the config file as. The built-in library is
 written in its relative spelling, so a config never remembers the folder one
 particular AppImage happened to be mounted at.
*>
fn String stored_library_path(String library_path)
{
	if (bundle_root.len > 0 && library_path == bundled(DEFAULT_LIBRARY_PATH)) return DEFAULT_LIBRARY_PATH;
	return library_path;
}

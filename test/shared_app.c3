<*
 Process-wide immutable setup for editor checks.

 The UI and animation suites open the same cube and the same disposable asset
 library hundreds of times.  Rebuilding their BVH/voxel/shell measurements and
 reopening every glTF file in every check tests startup repeatedly rather than
 the interaction named by the check.

 This follows three's `test/shared_device.c3` ownership rule: process-lived
 data is created on the real heap captured before the runner installs a test's
 tracking allocator.  Every borrower still gets a fresh `AppState`; only
 immutable geometry measurements and pack payloads are shared.  Asset entries
 and the pack array itself are copied because library reload and authored clip
 creation replace those collections.

 The three halves are brought up independently — geometry, library, glyphs —
 so a suite that only binds the cube never reads a glTF file or a font.
*>
module crig_tests::shared_app;

import crig;
import rig;
import cui;
import font;
import crig_tests::library;
import std::math;

alias HeapAlloc = std::core::mem::alloc::Allocator;

HeapAlloc real_heap;
fn void capture_heap() @init { real_heap = mem; }

Vec3[8] cube_positions @local = {
	{ -1, -1, -1 }, { 1, -1, -1 }, { 1, 1, -1 }, { -1, 1, -1 },
	{ -1, -1,  1 }, { 1, -1,  1 }, { 1, 1,  1 }, { -1, 1,  1 },
};

uint[36] cube_indices @local = {
	4, 5, 6, 4, 6, 7, 0, 3, 2, 0, 2, 1,
	1, 2, 6, 1, 6, 5, 0, 4, 7, 0, 7, 3,
	3, 7, 6, 3, 6, 2, 0, 1, 5, 0, 5, 4,
};

fn rig::TriMesh cube() => { .positions = cube_positions[..], .indices = cube_indices[..] };

<*
 Cells along the shared cube's side.

 Intentionally far below `rig::VOXEL_RESOLUTION`: the suites over this cube
 exercise editor lifecycle, tool dispatch and paint arithmetic, not geodesic
 accuracy — and the cube is convex, so a path through it *is* the straight line
 whatever the grid.  At 48 one bind floods 110k cells and costs most of a
 second; at 12 it is under ten milliseconds.  It is still a real solid grid, so
 snapping, fitting and binding take their production paths.
*>
const uint CUBE_RESOLUTION = 12;

struct Setup
{
	crig::AppGeometryCache geometry;
	bool geometry_ready;

	crig::AppState library;
	bool library_ready;

	// Every pack in the folder read in full, as `load_packs` reads it — the
	// library the MCP and naming fixtures check against.
	crig::AppState all_packs;
	bool all_packs_ready;

	// A Ui kept only for its baked glyphs; see `load_font`.
	Ui* glyphs;
}

Setup setup;

// Run `body` with the process heap installed, so what it allocates outlives
// the check that happened to be first.
macro void @on_real_heap(; @body())
{
	HeapAlloc tracked = mem;
	mem = real_heap;
	defer mem = tracked;
	@body();
}

fn void ensure_geometry() @private
{
	if (setup.geometry_ready) return;
	@on_real_heap()
	{
		setup.geometry = crig::build_app_geometry_cache(cube(), resolution: CUBE_RESOLUTION);
		setup.geometry_ready = true;
	};
}

fn void ensure_library() @private
{
	if (setup.library_ready) return;
	@on_real_heap()
	{
		setup.library = crig::new_app({});
		setup.library.config.libraries.init(mem);
		setup.library.config.add_library(library::ready(), "Checks");
		setup.library.scan_libraries();
		setup.library_ready = true;
	};
}

fn void ensure_all_packs() @private
{
	if (setup.all_packs_ready) return;
	@on_real_heap()
	{
		setup.all_packs = crig::new_app({});
		setup.all_packs.load_packs(library::ready());
		setup.all_packs_ready = true;
	};
}

<*
 What `app.load_packs(library::ready())` leaves on a fresh state, without
 reading the folder again: every pack, borrowed like `attach_library`'s.
 Reading them took most of a second, once per check.
*>
fn void attach_all_packs(crig::AppState* app)
{
	ensure_all_packs();
	foreach (pack : setup.all_packs.packs)
	{
		crig::AnimPack borrowed = pack;
		borrowed.owned = false;
		app.adopt_pack(borrowed);
	}
	app.expanded_pack = 0;
	app.set_library_path(library::ready());
	app.plan_targets_stale = true;
}

<*
 A fresh editor over the shared cube and library.

 The returned state owns every mutable collection it can replace.  Its pack
 entries have `owned = false`, so their payload stays in the process setup;
 adding an authored pack grows a test-owned outer array and remains isolated.
*>
fn crig::AppState open()
{
	crig::AppState app = open_cube();
	attach_library(&app);
	return app;
}

<*
 A fresh editor over the shared cube and nothing else — no library, no packs.

 For the suites whose fixture is a cube with a few dots on it: the weight
 survey, the tool table, naming.  Their cube used to be measured at production
 resolution in every check, which made each bind the slowest thing in the
 process by two orders of magnitude while measuring nothing the check asked
 about.  `AppState.free` detaches the borrowed measurements without releasing
 them; a check that loads or generates a different mesh drops the borrow and
 owns what it builds, the way the app does.
*>
fn crig::AppState open_cube()
{
	ensure_geometry();
	return crig::new_app_from_cache(&setup.geometry);
}

<*
 Give any fresh state a snapshot of the shared fixture library without reading
 its glTF files again.  Used by UI checks that deliberately open an empty or a
 custom mesh rather than the shared cube.
*>
fn void attach_library(crig::AppState* app)
{
	ensure_library();

	app.config.libraries.init(mem);
	app.config.add_library(library::ready(), "Checks");

	foreach (pack : setup.library.packs)
	{
		// The payload belongs to `setup`; freeing the app's packs skips the
		// shared internals.
		crig::AnimPack borrowed = pack;
		borrowed.owned = false;
		app.adopt_pack(borrowed);
	}

	app.assets = copy_assets(setup.library.assets);
	app.expanded_pack = 0;
	app.reach_stale = true;
	app.plan_targets_stale = true;
	app.set_library_path(library::ready());
	app.rebuild_reference_plans();
	app.refresh_categories();
	app.refresh_visible_assets();

	crig::AssetLibrary[] libraries = app.config.libraries.array_view();
	String[] labels = alloc::new_array(mem, String, (sz)libraries.len + 1);
	labels[0] = crig::ALL_LIBRARIES_LABEL.copy(mem);
	foreach (usz i, held : libraries) labels[i + 1] = held.name.copy(mem);
	app.library_labels = labels;
}

fn crig::AssetIndex copy_assets(crig::AssetIndex source) @private
{
	crig::AssetEntry[] entries = alloc::new_array(mem, crig::AssetEntry, (sz)source.entries.len);
	foreach (usz i, entry : source.entries)
	{
		entries[i] = entry;
		entries[i].name = entry.name.copy(mem);
		entries[i].file = entry.file.copy(mem);
		entries[i].plan = entry.plan.len > 0 ? entry.plan.copy(mem) : "";
		entries[i].tags = entry.tags.len > 0 ? entry.tags.copy(mem) : "";
	}
	return { .entries = entries };
}

// ---------------------------------------------------------------------------
// Glyphs

<*
 Every character the interface is likely to paint, baked ahead.

 Printable ASCII, and the handful of others crig's labels use.  Anything not
 here still bakes lazily on first paint, exactly as before; this only decides
 what is paid for once rather than per check.
*>
const String PREBAKED @local = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~—·…×−°²→γε▸§";

fn void ensure_glyphs() @private
{
	if (setup.glyphs) return;
	@on_real_heap()
	{
		Ui* ui = cui::new_ui({ crig::WIN_W, crig::WIN_H });
		if (try ui.load_font(crig::FONT_PATH))
		{
			Char32[] runes = PREBAKED.to_utf32(mem)!!;
			defer alloc::free(mem, runes);
			font::Font f = ui.text.fonts[0];
			foreach (rune : runes) ui.text.glyph(0, f.glyph_index(rune));
			setup.glyphs = ui;
		}
		else
		{
			// Nothing to warm; every fixture reports the missing font itself.
			ui.free();
		}
	};
}

<*
 Load crig's font into `ui` with its glyphs already baked.

 A fresh `Ui` bakes each glyph it paints into its own SDF atlas the first time
 it is flushed.  That is the right design for the app, which does it once, and
 the wrong cost for a fixture built per check: some thirty milliseconds — two
 thirds of the UI suite's whole running time — spent redrawing the same
 alphabet.  The bake depends on the font alone, so the process does it once and
 every fixture starts from a copy of the atlas and the slot table.

 Same font, same id, same bake size, so the copied slots describe the copied
 pixels exactly; the shelf cursor comes along so a glyph baked later packs
 below what was copied rather than over it.  `dirty` is left set, as it would
 be after a bake, so a backend that ever looked would upload the atlas.
*>
fn void? load_font(Ui* ui)
{
	ui.load_font(crig::FONT_PATH)!;
	ensure_glyphs();
	if (!setup.glyphs) return;

	TextSystem* from = &setup.glyphs.text;
	TextSystem* to = &ui.text;
	from.glyphs.@each(; ulong key, GlyphSlot slot)
	{
		to.glyphs.set(key, slot);
	};
	mem::copy(to.atlas.ptr, from.atlas.ptr, from.atlas.len);
	to.shelf_x = from.shelf_x;
	to.shelf_y = from.shelf_y;
	to.shelf_height = from.shelf_height;
	to.dirty = true;
}

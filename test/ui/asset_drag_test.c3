<*
 The Assets pane's group under Animations is the focused character's own: named
 after him and listing the clips he binds, following binds, undo and focus. A clip
 cell dragged onto the Layers sheet lays it there, through refreshes; Esc lets go.

     `c3c test --test-filter asset_drag`
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::io::file;
import std::io::path;
import std::math;

// One indexed clip, by the strings that find it again after a re-sort.
struct AssetDragClip @local
{
	String name;
	String file;
}

fn void AssetDragClip.free(&self)
{
	self.name.free(mem);
	self.file.free(mem);
}

// The focus's group row, or past the end when there is none.
fn usz asset_drag_group(Fixture* f) @local
{
	foreach (usz i, category : f.app.asset_categories) if (category.current_file) return i;
	return f.app.asset_categories.len;
}

// How many indexed clips the focus binds.
fn usz asset_drag_bound(Fixture* f) @local
{
	usz bound;
	foreach (&entry : f.app.assets.entries)
	{
		if (entry.kind == crig::AssetKind.ANIMATION && f.app.is_bound_entry(entry)) bound++;
	}
	return bound;
}

// The `n`th library clip in the index, copied.
fn AssetDragClip asset_drag_clip(Fixture* f, usz n) @local
{
	usz seen;
	foreach (entry : f.app.assets.entries)
	{
		if (entry.kind != crig::AssetKind.ANIMATION || entry.library < 0) continue;
		if (seen++ == n) return { entry.name.copy(mem), entry.file.copy(mem) };
	}
	return { "".copy(mem), "".copy(mem) };
}

// The visible row showing `clip`, or past the end.
fn usz asset_drag_row(Fixture* f, AssetDragClip clip) @local
{
	foreach (usz row, which : f.app.visible_assets)
	{
		crig::AssetEntry* e = &f.app.assets.entries[which];
		if (e.kind == crig::AssetKind.ANIMATION && e.name == clip.name && e.file == clip.file) return row;
	}
	return f.app.visible_assets.len;
}

// Whether the group lists exactly these clips, under `label`.
fn bool asset_drag_lists(Fixture* f, String label, AssetDragClip[] clips) @local
{
	usz group = asset_drag_group(f);
	if (group >= f.app.asset_categories.len) return clips.len == 0;
	crig::AssetCategory row = f.app.asset_categories[group];
	if (row.label != label || row.count != clips.len) return false;
	usz listed;
	foreach (&entry : f.app.assets.entries)
	{
		if (entry.kind != crig::AssetKind.ANIMATION || !entry.current) continue;
		listed++;
		bool named;
		foreach (clip : clips) named = named || (entry.name == clip.name && entry.file == clip.file);
		if (!named) return false;
	}
	return listed == clips.len;
}

// Bind or unbind a clip the way the + does, with the refresh its click makes.
fn void asset_drag_toggle(Fixture* f, AssetDragClip clip) @local
{
	f.app.set_asset_filter(crig::ALL_ASSETS);
	usz row = asset_drag_row(f, clip);
	test::@check(row < f.app.visible_assets.len, "%s is not listed", clip.name);
	test::@check(f.app.toggle_bound_row(row), "the + on %s did nothing", clip.name);
	f.app.refresh_ui();
}

fn void asset_drag_the_group_is_the_focus_and_his_clips() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ASSETS));
	f.ui.flush();
	Element* tree = f.ui.find_id(crig::ASSETS_TREE_ID)!!;
	f.click(category_center(tree, category_row(&f, crig::AssetKind.ANIMATION)));
	test::@check(asset_drag_group(&f) == f.app.asset_categories.len, "a character binding nothing has a group");

	AssetDragClip[2] clips = { asset_drag_clip(&f, 0), asset_drag_clip(&f, 1) };
	defer foreach (&clip : clips) clip.free();
	test::@check(clips[1].name.len > 0, "the library has fewer than two clips");

	// The + on two cells: both join the group, named after him, without a rescan.
	foreach (clip : clips)
	{
		test::@check(f.bind_click(asset_drag_row(&f, clip)), "no cell for %s", clip.name);
		f.ui.flush();
		test::@check(!f.app.piece_drag.active, "the + on %s started a drag", clip.name);
	}
	usz group = asset_drag_group(&f);
	test::@check(asset_drag_lists(&f, f.app.label(), clips[..]), "the group does not list the two bound clips");
	test::eq(f.app.asset_categories[group].count, asset_drag_bound(&f));
	TreeRow[] rows = sidebar_rows(&f);
	test::@check(group < rows.len && rows[group].label == f.app.label() && rows[group].trailing == "2",
		"the sidebar does not show the group");

	// Narrowed to it, the grid is his clips; the + on one there takes it off.
	f.click(category_center(f.ui.find_id(crig::ASSETS_TREE_ID)!!, group));
	test::eq(count_cells(&f), (usz)2);
	test::@check(f.bind_click(asset_drag_row(&f, clips[0])), "no cell for %s in the group", clips[0].name);
	f.ui.flush();
	test::@check(asset_drag_lists(&f, f.app.label(), clips[1:1]), "the unbound clip stayed in the group");
	test::@check(f.app.asset_filter.current_file, "the unbind left the group");
	test::eq(count_cells(&f), (usz)1);

	// Undo binds it back, and the group follows.
	test::@check(f.app.undo(), "the unbind did not undo");
	f.app.refresh_ui();
	f.ui.flush();
	test::@check(asset_drag_lists(&f, f.app.label(), clips[..]), "the undo did not bring the clip back to the group");
	test::eq(count_cells(&f), (usz)2);

	// Nothing changed: the pane is not rebuilt.
	Element* pane;
	for (Element* p = f.ui.find_id(crig::ASSETS_TREE_ID)!!.parent; p && !pane; p = p.parent)
	{
		if (p.is_widget(AreaPane)) pane = p;
	}
	test::@check(pane != null, "the sidebar is in no pane");
	f.app.refresh_ui();
	test::@check(!pane.dirty.build, "a refresh that changed nothing rebuilt the Assets pane");
}

fn void asset_drag_the_group_follows_the_focus() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.reset();
	AssetDragClip[2] clips = { asset_drag_clip(&f, 0), asset_drag_clip(&f, 1) };
	defer foreach (&clip : clips) clip.free();
	test::@check(clips[1].name.len > 0, "the library has fewer than two clips");

	usz cube = f.app.active;
	asset_drag_toggle(&f, clips[0]);
	test::@check(asset_drag_lists(&f, "Untitled", clips[:1]), "the cube's group does not list its clip");

	// One read from the level, with no mesh: his row names the group.
	usz guide = f.app.add_character({}, "");
	f.app.level_read = true;
	test::@check(f.app.make_actor(guide, "guide"), "the bare rig is no actor");
	f.app.refresh_ui();
	test::eq(f.app.asset_group_label, "guide");
	test::@check(asset_drag_lists(&f, "guide", {}), "the guide shows the cube's clips");
	asset_drag_toggle(&f, clips[1]);
	test::@check(asset_drag_lists(&f, "guide", clips[1:1]), "the guide's group does not list his clip");

	test::@check(f.app.focus_character(cube), "the cube did not take the focus");
	test::@check(asset_drag_lists(&f, "Untitled", clips[:1]), "focusing the cube did not relist the group");
	test::@check(f.app.focus_character(guide), "the guide did not take the focus");
	test::@check(asset_drag_lists(&f, "guide", clips[1:1]), "focusing the guide did not relist the group");
}

fn void asset_drag_the_focus_row_in_the_scene_pane_targets_his_actor() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	usz hero = f.app.active;
	test::@check(f.app.make_actor(hero, "hero"), "the cube is no actor");
	usz guide = f.app.add_character({}, "");
	f.app.level_read = true;
	test::@check(f.app.make_actor(guide, "guide"), "the bare rig is no actor");
	(void)f.app.add_cutscene();
	// The hero's lane was pressed last, though the guide is the focus.
	f.app.cut_lane_actor = 1;

	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_SCENE));
	Element* tree = f.ui.find_id(crig::SCENE_OUTLINER_ID)!!.children[0];
	// Scene, the hero's row, then the focus's own, named by his actor row as he has no file.
	TreeRow[] rows = tree.widget_as(Tree).rows;
	test::@check(rows.len > 2 && rows[2].label == "guide", "the guide's row is not named for him");
	f.click(category_center(tree, 2));
	test::@check(f.app.active == guide && f.app.cut_lane_actor == 2 && f.app.cut_target_actor() == 1,
		"the row left the focus %d and the lane %d", f.app.active, f.app.cut_lane_actor);
}

fn void asset_drag_an_actor_from_a_file_becomes_the_target() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.make_actor(f.app.active, "hero"), "the cube is no actor");
	(void)f.app.add_cutscene();
	// The hero's lane was pressed last.
	f.app.cut_lane_actor = 1;
	test::eq(f.app.cut_target_actor(), 0);

	(void)path::mkdir("build/asset-drag", true);
	String extra = "build/asset-drag/newcomer.glb";
	char[] bytes = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer free(bytes);
	file::save(extra, bytes)!!;
	defer (void)file::delete(extra);
	test::@check(f.app.add_actor_from_file(extra, "newcomer"), "no actor from the file");
	test::@check(f.app.cut_lane_actor == 2 && f.app.cut_target_actor() == 1,
		"the newcomer left the lane %d", f.app.cut_lane_actor);
}

// The biped with a keyed clip open on the Layers sheet, the Assets pane beside the
// model showing `kind`.
fn void asset_drag_open(Fixture* f, crig::AssetKind kind = ANIMATION) @local
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Layered", 4);
	clip = f.app.key_here(clip, 1);
	f.app.editing = f.app.key_here(clip, 2);
	f.app.show_edited();
	crig::show_pane_view(f.ui, crig::ANIMATION_VIEW, SplitAxis.VERTICAL, 0.5f);
	f.ui.flush();
	f.feed(f.ui.input.mouse);
	click_segment(f, crig::ANIM_SHEET_MODE_ID, 2);
	crig::show_pane_view(f.ui, crig::LIBRARY_VIEW, SplitAxis.HORIZONTAL, 0.5f);
	crig::AssetFilter only = crig::ALL_ASSETS;
	only.any_kind = false;
	only.kind = kind;
	(void)f.app.set_asset_filter(only);
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	test::@check(f.app.anim_show_layers && f.in_tree(crig::ANIM_LAYER_SHEET_ID), "the Layers sheet is not up");
	f.app.undo_stack.commit();
}

// Whether a press at the middle of `cell` reaches it.
fn bool asset_drag_reaches(Fixture* f, Element* cell) @local
{
	for (Element* e = f.ui.hit_test(centre_of(cell)); e; e = e.parent)
	{
		if (e == cell) return true;
	}
	return false;
}

// A library cell of `kind` that is not greyed and that a press reaches, or null.
fn Element* asset_drag_cell(Fixture* f, crig::AssetKind kind) @local
{
	Element* found = null;
	f.ui.@each(crig::AssetCell; cell)
	{
		usz row = cell.widget_as(crig::AssetCell).row;
		crig::AssetEntry* e = f.app.visible_asset(row);
		if (!found && e && e.kind == kind && e.library >= 0 && !f.app.asset_flags(row).disabled
			&& asset_drag_reaches(f, cell)) found = cell;
	};
	return found;
}

// The clip a cell shows, copied.
fn AssetDragClip asset_drag_clip_of(Fixture* f, Element* cell) @local
{
	crig::AssetEntry* e = f.app.visible_asset(cell.widget_as(crig::AssetCell).row);
	return { e.name.copy(mem), e.file.copy(mem) };
}

// Press `cell`'s body and move past the slop, the button held.
fn void asset_drag_lift(Fixture* f, Element* cell) @local
{
	Vec2 from = centre_of(cell);
	f.feed(from);
	f.feed(from, left: true);
	f.feed(from + (Vec2){ crig::PIECE_DRAG_SLOP * 3.0f, 0 }, left: true);
}

fn void asset_drag_a_clip_dropped_on_the_layers_sheet_lays_one_layer() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	asset_drag_open(&f);
	Element* cell = asset_drag_cell(&f, ANIMATION);
	test::@check(cell != null, "no library clip in reach");
	AssetDragClip clip = asset_drag_clip_of(&f, cell);
	defer clip.free();
	usz which = f.app.visible_assets[cell.widget_as(crig::AssetCell).row];
	test::@check(f.app.selected_asset != (int)which, "the cell was picked before the press");
	sz history = f.app.undo_stack.cursor;

	asset_drag_lift(&f, cell);
	test::eq(f.app.selected_asset, (int)which);
	test::@check(f.app.piece_drag.active && f.app.piece_drag.from_asset, "the press and move started no drag");
	test::eq(f.app.piece_drag.label, clip.name);

	// What a bind, a focus or a reindex asks for mid-drag.
	f.app.refresh_ui();
	f.app.refresh_asset_sidebar();
	f.ui.flush();
	test::@check(f.app.piece_drag.active && f.app.piece_drag.from_asset, "a refresh ended the drag");

	Vec2 to = sheet_ui_point(&f, 1.0f, 0);
	f.feed(to, left: true);
	f.feed(to);
	f.ui.flush();
	AnimTemplate* edited = f.app.clip(f.app.editing);
	test::eq(edited.layers.len, (sz)1);
	test::@check(edited.layers[0].name == clip.name && edited.layers[0].source.len == 0,
		"the layer is %s, from %s, not a copy of %s", edited.layers[0].name, edited.layers[0].source, clip.name);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(!f.app.piece_drag.active && !f.app.asset_build_owed, "the drag or its held build outlived the drop");
	test::@check(asset_drag_cell(&f, ANIMATION) != null, "the Assets pane was not rebuilt after the drop");
}

fn void asset_drag_esc_lets_go_with_nothing_laid() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	asset_drag_open(&f);
	Element* cell = asset_drag_cell(&f, ANIMATION);
	test::@check(cell != null, "no library clip in reach");
	sz history = f.app.undo_stack.cursor;

	asset_drag_lift(&f, cell);
	test::@check(f.app.asset_dragging(), "the press and move started no drag");
	Key[1] esc = { Key.ESCAPE };
	Vec2 to = sheet_ui_point(&f, 1.0f, 0);
	f.feed(to, left: true, keys: esc[..]);
	test::@check(!f.app.piece_drag.active, "Esc did not end the drag");
	f.feed(to, left: true);
	f.feed(to);
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)0);
	test::eq(f.app.undo_stack.cursor, history);
	test::@check(!f.app.piece_drag.active, "the release started the drag again");
}

// A model row at the front of the index, where its kind sorts: the check library holds none.
fn void asset_drag_add_model(Fixture* f) @local
{
	crig::AssetEntry[] was = f.app.assets.entries;
	crig::AssetEntry[] grown = alloc::new_array(mem, crig::AssetEntry, was.len + 1);
	grown[0] = { .kind = MODEL, .name = "stand".copy(mem), .file = "build/asset-drag/stand.glb".copy(mem), .vertices = 8 };
	grown[1..] = was[..];
	if (was.len > 0) alloc::free(mem, was);
	f.app.assets.entries = grown;
	f.app.refresh_categories();
	f.app.refresh_visible_assets();
}

fn void asset_drag_a_model_cell_does_not_drag() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	asset_drag_add_model(&f);
	asset_drag_open(&f, MODEL);
	Element* cell = asset_drag_cell(&f, MODEL);
	test::@check(cell != null, "no model in reach");

	asset_drag_lift(&f, cell);
	test::@check(!f.app.piece_drag.active, "a model cell started a drag");
	Vec2 to = sheet_ui_point(&f, 1.0f, 0);
	f.feed(to, left: true);
	test::@check(!f.app.piece_drag.active, "a model cell started a drag");
	f.feed(to);
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)0);
}

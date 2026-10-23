<*
 The Layers sheet (ui/layer_sheet.c3): the sheet's third mode, a clip's layers as
 strips on tracks, and the Pieces bin beside it. A strip dragged, trimmed or put
 on another track lands once, as one undo step; a piece clicked or dragged in
 from the bin is laid where it was put.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::sheet_ui`
*>
module crig_tests::ui;

import crig;
import rig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// The biped with a four-second clip and a second, "Swing", to lay into it, open
// on the Layers sheet.
fn void sheet_ui_open(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef swing = f.app.new_clip("Swing", 1);
	swing = f.app.key_here(swing, 0.5f);
	AnimRef clip = f.app.new_clip("Layered", 4);
	clip = f.app.key_here(clip, 1);
	f.app.editing = f.app.key_here(clip, 2);
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	click_segment(f, crig::ANIM_SHEET_MODE_ID, 2);
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(f.app.anim_show_layers, "the Layers segment did not switch the sheet");
	f.app.undo_stack.commit();
}

fn Element* sheet_ui_sheet(Fixture* f) => f.ui.find_id(crig::ANIM_LAYER_SHEET_ID)!!;

// Where a time on a lane is on screen.
fn Vec2 sheet_ui_point(Fixture* f, float at, usz lane)
{
	Element* elem = sheet_ui_sheet(f);
	crig::LayerSheet* sheet = elem.widget_as(crig::LayerSheet);
	AnimTemplate* clip = f.app.clip(f.app.editing);
	return elem.absolute + (Vec2){ sheet.x_of(elem, &f.app, clip, at), sheet.lane_top(lane) + crig::LAYER_SHEET_LANE_H * 0.5f };
}

// The middle of the bin row whose label is `label`.
fn Vec2 sheet_ui_bin_row(Fixture* f, String label)
{
	Element* elem = f.ui.find_id(crig::ANIM_PIECE_BIN_ID)!!;
	crig::PieceBin* bin = elem.widget_as(crig::PieceBin);
	foreach (usz i, &entry : bin.entries)
	{
		if (entry.header || entry.label != label) continue;
		return elem.absolute + (Vec2){ elem.size.x * 0.5f, crig::PIECE_ROW_H * ((float)i + 1.5f) - bin.scroll };
	}
	test::@check(false, "the bin has no row %s", label);
	return {};
}

fn AnimLayer* sheet_ui_layer(Fixture* f, usz at) => &f.app.clip(f.app.editing).layers[at];

fn void sheet_ui_the_third_mode_shows_strips_and_the_bin() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	sheet_ui_open(&f);
	test::@check(f.app.anim_show_layers && f.in_tree(crig::ANIM_LAYER_SHEET_ID) && f.in_tree(crig::ANIM_PIECE_BIN_ID),
		"Layers did not replace the sheet with strips and the bin");
	test::@check(!f.in_tree(crig::ANIM_LAYER_TREE_ID), "the Layers column still lists the layers beside the strips");
	crig::PieceBin* bin = f.ui.find_id(crig::ANIM_PIECE_BIN_ID)!!.widget_as(crig::PieceBin);
	bool swing;
	foreach (&entry : bin.entries) if (entry.label == "Swing" && entry.piece.kind == CLIP) swing = true;
	test::@check(swing, "the bin does not offer the character's other animation");
	click_segment(&f, crig::ANIM_SHEET_MODE_ID, 0);
	test::@check(!f.app.anim_show_layers && f.in_tree(crig::ANIM_LAYER_TREE_ID), "Keys did not bring the list back");
}

fn void sheet_ui_a_clicked_piece_lands_at_the_playhead() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	sheet_ui_open(&f);
	f.app.edit_time = 1.0f;
	sz history = f.app.undo_stack.cursor;
	f.click(sheet_ui_bin_row(&f, "Wave"));
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)1);
	AnimLayer* wave = sheet_ui_layer(&f, 0);
	test::@check(wave.kind == WAVE && wave.start == 1.0f && wave.end == 4.0f, "the wave is not laid from the playhead: %s..%s", wave.start, wave.end);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(f.app.active_layer_of(f.app.editing), (sz)0);
}

fn void sheet_ui_an_animation_dragged_in_is_linked_where_it_was_dropped() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	sheet_ui_open(&f);
	// The new-track row is lane 0 while the clip has no tracks.
	Vec2 to = sheet_ui_point(&f, 2.0f, 0);
	f.drag(sheet_ui_bin_row(&f, "Swing"), to);
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).layers.len, (sz)1);
	AnimLayer* piece = sheet_ui_layer(&f, 0);
	test::@check(piece.source == "Swing" && math::abs(piece.offset - 2.0f) < 0.05f,
		"the drop did not lay Swing, linked, at 2s: %s at %s", piece.source, piece.offset);
	test::@check(!f.app.piece_drag.active, "the drag outlived the drop");
}

fn void sheet_ui_a_strip_moves_trims_and_changes_track_one_step_each() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	sheet_ui_open(&f);
	crig::Piece swing = { .kind = CLIP, .clip = f.app.clip_named_in_authored("Swing") };
	test::@check(f.app.place_piece(f.app.editing, swing, 1.0f, 0) >= 0, "the piece would not lay");
	f.ui.flush();
	sz history = f.app.undo_stack.cursor;

	// Lanes: new track, track 1, Base. The strip is 1..2 on lane 1.
	f.drag(sheet_ui_point(&f, 1.5f, 1), sheet_ui_point(&f, 2.5f, 1));
	f.ui.flush();
	AnimLayer* piece = sheet_ui_layer(&f, 0);
	test::@check(math::abs(piece.start - 2.0f) < 0.05f && math::abs(piece.offset - 2.0f) < 0.05f,
		"the drag did not move the strip a second later: %s", piece.start);
	test::eq(f.app.undo_stack.cursor, history + 1);

	f.drag(sheet_ui_point(&f, piece.end, 1), sheet_ui_point(&f, 3.5f, 1));
	f.ui.flush();
	piece = sheet_ui_layer(&f, 0);
	test::@check(math::abs(piece.end - 3.5f) < 0.05f && math::abs(piece.start - 2.0f) < 0.05f, "the end did not trim to 3.5s: %s", piece.end);
	test::eq(f.app.undo_stack.cursor, history + 2);

	// A wave on a track of its own above it, then the piece dragged onto the
	// new-track row over both.
	crig::Piece wave = { .kind = WAVE };
	test::@check(f.app.place_piece(f.app.editing, wave, 0.0f, 9) >= 0, "the wave would not lay");
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).track_count(), (uint)2);
	// Lanes now: new track, track 2 (the wave), track 1 (the piece), Base.
	f.drag(sheet_ui_point(&f, 2.5f, 2), sheet_ui_point(&f, 2.5f, 0));
	f.ui.flush();
	// The track it left is empty and closes up: still two, the piece now on top.
	test::eq(f.app.clip(f.app.editing).track_count(), (uint)2);
	bool on_top;
	foreach (&layer : f.app.clip(f.app.editing).layers) if (layer.source == "Swing" && layer.track == 1) on_top = true;
	test::@check(on_top, "the strip did not go onto a new track at the top");
	test::@check(f.app.undo() && sheet_ui_layer(&f, 0).source == "Swing", "one undo did not take the track change back");
}

fn void sheet_ui_the_base_row_picks_the_clips_own_keys() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	sheet_ui_open(&f);
	f.click(sheet_ui_bin_row(&f, "Noise"));
	f.ui.flush();
	test::eq(f.app.active_layer_of(f.app.editing), (sz)0);
	// Lanes: new track, the noise, Base.
	f.click(sheet_ui_point(&f, 3.0f, 2));
	f.ui.flush();
	test::eq(f.app.active_layer_of(f.app.editing), (sz)-1);
	f.click(sheet_ui_point(&f, 3.0f, 1));
	f.ui.flush();
	test::eq(f.app.active_layer_of(f.app.editing), (sz)0);
}

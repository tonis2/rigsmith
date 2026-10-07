<*
 The Sketch tool's UI (ui/tool_column.c3, ui/sketch_toolbar.c3): the tool
 column's cell opens it with no key involved, the strip across the top picks a
 colour or the eraser, and the eraser takes off the marks a drag passes.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::ui::sketch`
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

const usz SKETCH_CELL = 5;

fn Vec2 sketch_strip_cell(Fixture* f, crig::SketchCell cell)
{
	Element* strip = f.ui.find_id("sketch-toolbar")!!;
	return strip.absolute + (Vec2){ crig::sketch_cell_x((usz)cell) + crig::TINT_CELL_W * 0.5f, crig::TINT_CELL_H * 0.5f };
}

fn void the_sketch_cell_opens_the_tool_and_its_strip() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();

	test::@check(crig::tool_cells[SKETCH_CELL].glyph == crig::ToolGlyph.SKETCH_GLYPH, "the last tool cell is not Sketch");
	Vec2 cell = tip_centre(tip_cell(&f, SKETCH_CELL));
	f.click(cell);
	f.ui.flush();
	test::@check(f.app.sketching, "the Sketch cell did not open the tool");
	test::@check(f.ui.find_id("sketch-toolbar")!!.size.x > 0, "the colour strip did not show");

	f.click(cell);
	test::@check(!f.app.sketching, "clicking the lit Sketch cell did not put the tool away");
}

fn void the_strip_picks_a_colour_or_the_eraser() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.click(tip_centre(tip_cell(&f, SKETCH_CELL)));
	f.ui.flush();

	f.click(sketch_strip_cell(&f, crig::SketchCell.GREEN));
	test::@check(f.app.sketch_ink == crig::SketchInk.GREEN && !f.app.sketch_erasing, "green was not picked");
	f.click(sketch_strip_cell(&f, crig::SketchCell.ERASER));
	test::@check(f.app.sketch_erasing, "the eraser was not picked");
	f.click(sketch_strip_cell(&f, crig::SketchCell.BLUE));
	test::@check(f.app.sketch_ink == crig::SketchInk.BLUE && !f.app.sketch_erasing, "a colour did not put the eraser down");
}

fn void the_eraser_takes_off_the_marks_it_crosses() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	f.click(tip_centre(tip_cell(&f, SKETCH_CELL)));

	Vec2 c = VIEWPORT_CENTER;
	f.drag(c + (Vec2){ -60, -40 }, c + (Vec2){ 60, -40 });
	f.drag(c + (Vec2){ -60, 40 }, c + (Vec2){ 60, 40 });
	test::@check(f.app.annotations.len() == 2, "two strokes made %d marks", f.app.annotations.len());
	uint bottom = f.app.annotations[1].id;

	f.app.sketch_erasing = true;
	// Down across the top mark only.
	f.drag(c + (Vec2){ 0, -70 }, c + (Vec2){ 0, -10 });
	test::@check(f.app.annotations.len() == 1, "the eraser left %d marks, not 1", f.app.annotations.len());
	test::@check(f.app.annotations[0].id == bottom, "the eraser took the mark it did not cross");
}

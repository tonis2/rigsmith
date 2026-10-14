// The Weights card and the brush draw one joint's weights from the same numbers:
// the card shows the weights as they are until a part is shaped, and a shaped
// part as the weights Apply leaves — so neither switching to the brush nor
// pressing Apply changes what the mesh shows. On the shipped humanoid.
module crig_tests::weights_card;

import crig;
import rig;
import std::core::test;
import std::io;
import std::io::file;
import std::math;

const String CARD_COPY = "build/weights-card-humanoid.glb";

fn void open_card_fixture(crig::AppState* app, rig::TriMesh* mesh)
{
	char[] original = file::load(mem, "assets/animations/humanoid.glb")!!;
	defer alloc::free(mem, original);
	file::save(CARD_COPY, original)!!;
	*mesh = rig::load_gltf(mem, CARD_COPY)!!;
	*app = crig::new_app(*mesh, CARD_COPY);
	test::@check(app.import_rig_from_source(), "the humanoid rig must import");
}

fn void close_card_fixture(crig::AppState* app, rig::TriMesh* mesh)
{
	app.free();
	mesh.free(mem);
	(void)file::delete(CARD_COPY);
	String sidecar = crig::session_path(mem, CARD_COPY);
	defer sidecar.free(mem);
	(void)file::delete(sidecar);
}

fn uint card_dot(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

// The finger beside the one under test already corrected, so the rows the card
// draws hold pins as well as the binder's weights; then the Weights card on the
// second joint.
fn uint open_card_on_a_finger(crig::AppState* app)
{
	uint first = card_dot(app, "index_1_L");
	bool[] part = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, part);
	test::@check(app.apply_area(first, part, app.area_scale(first) * 0.25f) > 0, "the first finger's part wrote nothing");

	uint finger = card_dot(app, "index_2_L");
	app.select(finger);
	app.show_joint_panel = true;
	app.joint_panel_tab = WEIGHTS;
	app.sync_weights_card();
	test::@check(app.areaing && app.area_pending(), "the card picked no part for its buttons");
	return finger;
}

fn uint[] drawn(crig::AppState* app)
{
	app.rebind_tints();
	return alloc::clone_slice(mem, app.tints);
}

// How many vertices two pictures colour differently, by more than `slack` in a channel.
fn usz drawn_apart(uint[] a, uint[] b, uint slack = 0)
{
	if (a.len != b.len) return (usz)math::max(a.len, b.len);
	usz apart = 0;
	foreach (i, tint : a)
	{
		for (uint shift = 0; shift < 24; shift += 8)
		{
			int gap = (int)((tint >> shift) & 0xFF) - (int)((b[i] >> shift) & 0xFF);
			if (math::abs(gap) <= (int)slack) continue;
			apart++;
			break;
		}
	}
	return apart;
}

<*
 Opening the card on a joint draws its weights, exactly the picture the brush
 paints on. It used to draw the part it picked for its buttons instead — orange
 inside, grey outside — so the joint looked recalculated between the two.

 *Re-introduce:* draw the picked part from the moment the card opens, and the
 card and the brush colour hundreds of vertices differently.
*>
fn void the_card_and_the_brush_draw_the_same_weights() @test
{
	io::printn("the Weights card and the brush draw the same weights");
	crig::AppState app;
	rig::TriMesh mesh;
	open_card_fixture(&app, &mesh);
	defer close_card_fixture(&app, &mesh);
	open_card_on_a_finger(&app);

	uint[] card = drawn(&app);
	defer alloc::free(mem, card);
	test::@check(app.tints.len == app.geometry.positions.len, "the card drew no weights");

	test::@check(app.begin_brush(), "the brush would not open");
	uint[] brush = drawn(&app);
	defer alloc::free(mem, brush);
	usz apart = drawn_apart(card, brush);
	test::@check(apart == 0, "the card and the brush colour %d vertices differently", apart);

	app.leave_brush();
	uint[] back = drawn(&app);
	defer alloc::free(mem, back);
	apart = drawn_apart(card, back);
	test::@check(apart == 0, "back on the card, %d vertices changed colour", apart);
}

<*
 A part grown on the card shows the weights Apply leaves, so pressing Apply — on
 the falloff ramp or the territory map — changes nothing on screen, and the
 brush then paints on what the card showed.

 *Re-introduce:* draw the part as a highlight of its own (a share of 0.2 to 1
 inside, grey outside), and the picture changes on Apply.
*>
fn void a_grown_part_shows_what_apply_leaves() @test
{
	io::printn("a grown part shows what Apply leaves, on either view");
	crig::TintMode[2] modes = { FALLOFF, TERRITORY };
	foreach (mode : modes)
	{
		crig::AppState app;
		rig::TriMesh mesh;
		open_card_fixture(&app, &mesh);
		defer close_card_fixture(&app, &mesh);
		open_card_on_a_finger(&app);
		if (mode != app.tint_mode) app.show_tint(mode);

		uint[] before = drawn(&app);
		defer alloc::free(mem, before);
		test::@check(app.resize_area(1), "the part would not grow");
		uint[] preview = drawn(&app);
		defer alloc::free(mem, preview);
		test::@check(drawn_apart(before, preview) > 0, "growing the part changed nothing on the %s view", mode);

		test::@check(app.commit_area() > 0, "Apply wrote nothing");
		uint[] applied = drawn(&app);
		defer alloc::free(mem, applied);
		usz apart = drawn_apart(preview, applied);
		test::@check(apart == 0, "Apply recoloured %d vertices on the %s view", apart, mode);

		if (mode != FALLOFF) continue;
		test::@check(app.begin_brush(), "the brush would not open");
		uint[] brush = drawn(&app);
		defer alloc::free(mem, brush);
		apart = drawn_apart(applied, brush);
		test::@check(apart == 0, "the brush colours %d vertices differently from the applied part", apart);
	}
}

<*
 The part the card picks for itself is not on show until the card is asked for
 it, and a click on the mesh never picks or steps a part: the first click used to
 show the joint's own part and the next to step it to With children, so a click
 meant for the view — after an Apply, say — changed the Part menu. The Part
 menu, growing, shrinking or the soft edge show it, and opening the brush over a
 part on show says the part was not applied.

 *Re-introduce:* let a click on the mesh pick the own part and step it after,
 and the click shows a part and the next one moves to With children.
*>
fn void the_cards_own_pick_waits_for_the_card() @test
{
	io::printn("the card's own pick waits for the card, and a click on the mesh picks nothing");
	crig::AppState app;
	rig::TriMesh mesh;
	open_card_fixture(&app, &mesh);
	defer close_card_fixture(&app, &mesh);
	uint finger = open_card_on_a_finger(&app);
	test::@check(!app.area_preview, "the card's own pick went on show by itself");

	sz inside = -1;
	foreach (v, on : app.area_mask) if (on) { inside = (sz)v; break; }
	test::@check(inside >= 0, "the own part holds no vertex");
	test::@check(!app.area_click(inside), "a click on the mesh changed the part");
	test::@check(app.area_part == OWN && !app.area_preview, "the click showed %s", app.area_part.label());

	// The Part menu shows it, and a click after changes nothing.
	test::@check(app.set_area_part(OWN) && app.area_preview, "choosing Own bone did not show the part");
	test::@check(!app.area_click(inside), "a click on a part on show changed it");
	test::@check(app.area_part == OWN && app.area_origin == OWN, "the click stepped the part to %s", app.area_part.label());

	// Picked again by selecting the joint afresh: quiet once more.
	app.select(0);
	app.select(finger);
	test::@check(app.area_pending() && !app.area_preview, "the new pick went on show by itself");
	test::@check(app.resize_area(-1), "the part would not shrink");
	test::@check(app.area_preview, "shrinking did not show the part");

	app.notice_length = 0;
	test::@check(app.begin_brush(), "the brush would not open");
	test::@check(app.notice_length > 0 && app.notice().contains("not applied"),
		"opening the brush over the part said nothing of it");
}

<*
 Apply ends the editing: the brush closes, no part is left, and the mesh is
 left alone — a click picks nothing and a shift- or ctrl-drag grows or shrinks
 nothing — until a part is chosen in the Part menu again. Clicks and drags after
 an Apply used to pick a part, step it to With children, or grow a region from
 the point pressed, which read as the brush still painting.

 *Re-introduce:* let the mesh's gestures act with no part on show, and the
 first click after the Apply picks one.
*>
fn void after_apply_the_mesh_is_left_alone() @test
{
	io::printn("after Apply the mesh is left alone until a part is chosen again");
	crig::AppState app;
	rig::TriMesh mesh;
	open_card_fixture(&app, &mesh);
	defer close_card_fixture(&app, &mesh);
	uint finger = open_card_on_a_finger(&app);
	sz inside = -1;
	foreach (v, on : app.area_mask) if (on) { inside = (sz)v; break; }
	test::@check(inside >= 0, "the own part holds no vertex");

	crig::AreaPart[2] ends = { OWN, WITH_CHILDREN };
	foreach (round, end : ends)
	{
		if (round == 0)
		{
			// A stroke with the brush, then Apply.
			test::@check(app.begin_brush(), "the brush would not open");
			crig::VertexPin[1] stroke = { { .vertex = (uint)inside, .dot_id = finger, .share = 0.6f } };
			test::@check(app.pin_dabs(stroke[..]) > 0, "the stroke did not land");
		}
		else
		{
			// A part from the Part menu, then Apply.
			test::@check(app.set_area_part(end), "the finger has no %s part", end.label());
		}
		app.commit_area();
		test::@check(!app.brushing, "Apply left the brush open");
		test::@check(app.areaing && !app.area_pending(), "Apply left a part behind");

		sz pins = app.doc.pins.len();
		sz cursor = app.undo_stack.cursor;
		test::@check(!app.area_click(inside), "a click after Apply changed the part");
		test::@check(!app.area_click(inside), "a second click after Apply changed the part");
		test::@check(!app.begin_area_resize(inside, true), "a shift-drag after Apply started growing a part");
		test::@check(!app.begin_area_resize(inside, false), "a ctrl-drag after Apply started shrinking a part");
		test::@check(!app.area_pending() && app.area_origin == OWN, "the mesh's gestures left a part after Apply");
		test::eq(app.doc.pins.len(), pins);
		test::eq(app.undo_stack.cursor, cursor);
	}
}

<*
 A finger joint's own part is its segment, cut at the knuckles, whatever the pins
 say: a vertex in the middle of one segment pinned wholly to the next joint stays
 in its own segment's part, so Apply puts it back rather than locking the pin in.

 *Re-introduce:* read a finger's own part off the painted bind's strongest joint,
 and the pinned vertex moves to the next joint's part.
*>
fn void a_fingers_own_part_is_its_band_whatever_the_pins_say() @test
{
	io::printn("a finger's own part is its segment, whatever the pins say");
	crig::AppState app;
	rig::TriMesh mesh;
	open_card_fixture(&app, &mesh);
	defer close_card_fixture(&app, &mesh);

	uint first = card_dot(&app, "index_1_L");
	uint second = card_dot(&app, "index_2_L");
	bool[] own = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, own);
	sz inside = -1;
	foreach (v, on : own) if (on) { inside = (sz)v; break; }
	test::@check(inside >= 0, "index_1_L has no own part");

	crig::VertexPin[1] wrong = { { .vertex = (uint)inside, .dot_id = second, .share = 1.0f } };
	test::@check(app.pin_dabs(wrong[..]) > 0, "the pin did not land");

	bool[] after = app.area_part_mask(mem, first, OWN);
	defer alloc::free(mem, after);
	bool[] next = app.area_part_mask(mem, second, OWN);
	defer alloc::free(mem, next);
	test::@check(after.len > 0 && after[(usz)inside], "the pin moved the vertex out of index_1_L's part");
	test::@check(next.len == 0 || !next[(usz)inside], "the pin moved the vertex into index_2_L's part");
}

<*
 A finger's parts tile it: the own parts of its four joints share no vertex, and
 a joint's part with children is exactly its own part and those of the joints
 beyond it.

 *Re-introduce:* cut the own part and the part with children by different rules,
 and the two disagree at a knuckle.
*>
fn void a_fingers_parts_tile_it() @test
{
	io::printn("a finger's parts tile it, knuckle to knuckle");
	crig::AppState app;
	rig::TriMesh mesh;
	open_card_fixture(&app, &mesh);
	defer close_card_fixture(&app, &mesh);

	String[4] names = { "index_1_L", "index_2_L", "index_3_L", "index_4_L" };
	usz count = app.geometry.positions.len;
	bool[][4] own;
	foreach (i, name : names) own[i] = app.area_part_mask(mem, card_dot(&app, name), OWN);
	defer foreach (part : own) if (part.len > 0) alloc::free(mem, part);
	bool[] beyond = app.area_part_mask(mem, card_dot(&app, "index_2_L"), WITH_CHILDREN);
	defer if (beyond.len > 0) alloc::free(mem, beyond);

	foreach (i, part : own) test::@check(part.len == count, "%s has no own part", names[i]);
	test::@check(beyond.len == count, "index_2_L has no part with children");
	usz overlaps = 0;
	usz differ = 0;
	for (usz v = 0; v < count; v++)
	{
		usz holding = 0;
		foreach (part : own) if (part.len == count && part[v]) holding++;
		if (holding > 1) overlaps++;
		bool beyond_here = (own[1].len == count && own[1][v]) || (own[2].len == count && own[2][v]) || (own[3].len == count && own[3][v]);
		if (beyond.len == count && beyond[v] != beyond_here) differ++;
	}
	test::@check(overlaps == 0, "%d vertices are in two of the finger's own parts", overlaps);
	test::@check(differ == 0, "index_2_L's part with children differs from its parts beyond it at %d vertices", differ);
}

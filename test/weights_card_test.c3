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
 The part the card picks for itself is not on show until it is asked for: the
 first click shows the joint's own part, where it used to step straight past it
 to the joint's children, which were never on screen to step from. Moving the
 soft edge, growing, or shrinking shows it too, and opening the brush over a part
 on show says the part was not applied.
*>
fn void the_cards_own_pick_waits_to_be_shown() @test
{
	io::printn("the card's own pick is shown by the first click, not stepped past");
	crig::AppState app;
	rig::TriMesh mesh;
	open_card_fixture(&app, &mesh);
	defer close_card_fixture(&app, &mesh);
	uint finger = open_card_on_a_finger(&app);
	test::@check(!app.area_preview, "the card's own pick went on show by itself");

	sz inside = -1;
	foreach (v, on : app.area_mask) if (on) { inside = (sz)v; break; }
	test::@check(inside >= 0, "the own part holds no vertex");
	test::@check(app.area_click(inside), "the click picked nothing");
	test::@check(app.area_part == OWN, "the first click stepped to %s", app.area_part.label());
	test::@check(app.area_preview, "the click did not show the part");

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

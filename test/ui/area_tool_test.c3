module crig_tests::ui;
import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// ---------------------------------------------------------------------------
// The Area tool and the Weights card

<*
 A mesh vertex nothing hides, on the top (y > 0) or bottom half of the cube, in
 window pixels — somewhere a click in the Area tool lands on the mesh.
*>
fn Vec2? Fixture.visible_vertex(&self, bool top)
{
	Matrix4f vp = self.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y);
	Vec3 eye = self.app.camera.eye();
	Vec2 best;
	float nearest = -1.0f;
	foreach (position : self.app.geometry.positions)
	{
		if ((position.y > 0.0f) != top) continue;
		if (self.app.picker.hidden_surface(eye, position)) continue;
		Vec2? at = crig::project(vp, position, VIEWPORT);
		if (catch at) continue;
		// Nearest the middle, clear of the tool column and the sidebar.
		float gap = (at + VIEWPORT_ORIGIN - VIEWPORT_CENTER).length();
		if (nearest >= 0.0f && gap >= nearest) continue;
		nearest = gap;
		best = at + VIEWPORT_ORIGIN;
	}
	if (nearest < 0.0f) return crig::BEHIND_CAMERA~;
	return best;
}

<*
 The Area tool from the viewport: W opens it on the selected joint, live — a
 shift-drag on the mesh grows the joint itself as one undo step, with nothing
 waiting for Apply — the Part menu picks a part to apply and a click on the mesh
 never does, a wheel notch zooms and leaves the part alone, and Enter applies a
 chosen part as one undo step, without ever placing a joint.
*>
fn void the_area_tool_grows_live_and_applies_a_chosen_part() @test
{
	io::printn("the Area tool grows the joint live, and picks a part from the menu to apply");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	uint chest = fixture.two_dots();
	fixture.app.undo_stack.clear();

	// W shows the Weights card on the joint itself: nothing waits for Apply.
	fixture.feed_key(Key.W);
	test::@check(fixture.app.areaing && fixture.app.weights_card_open(), "W did not open the Weights card");
	test::@check(!fixture.app.area_pending(), "the card opened with a part waiting");

	Vec2? top = fixture.visible_vertex(true);
	if (catch top)
	{
		test::@check(false, "no visible vertex on the top of the cube to click");
		return;
	}
	fixture.click(top);
	test::eq(fixture.doc().dots.len(), (sz)2);
	test::@check(!fixture.app.area_pending(), "a click on the mesh picked a part");

	// A shift-drag on the mesh grows the chest, live, as one undo step.
	Key[1] shift = { Key.LEFT_SHIFT };
	Vec2 below = top + (Vec2){ 0.0f, crig::AREA_RING_PIXELS * 2.5f };
	fixture.feed(top, keys: shift[..]);
	fixture.feed(top, left: true, keys: shift[..]);
	fixture.feed(below, left: true, keys: shift[..]);
	fixture.feed(below, keys: shift[..]);
	fixture.feed(below);
	test::@check(fixture.doc().find(chest).grow > 0.0f, "a shift-drag did not grow the chest");
	test::@check(!fixture.app.area_pending(), "the grow left a part waiting");
	test::@check(fixture.app.weights_held(chest) && fixture.doc().pins.len() > 0, "the grow did not write the chest's weights");
	test::@check(fixture.app.undo(), "the grow left nothing to undo");
	test::@check(fixture.doc().find(chest).grow == 0.0f && fixture.doc().pins.len() == 0 && !fixture.app.weights_held(chest),
		"the drag was more than one undo step");

	// The menu picks a part; a click after it leaves the part as it is.
	fixture.click(fixture.center_of(crig::WEIGHTS_PART_ID)!!);
	fixture.click(fixture.center_of("With children")!!);
	test::@check(fixture.app.area_pending() && fixture.app.area_part == crig::AreaPart.WITH_CHILDREN,
		"the Part menu did not pick the chest with its children: %s", fixture.notice_text());
	usz held = fixture.app.area_held();
	fixture.click(top);
	test::@check(fixture.app.area_part == crig::AreaPart.WITH_CHILDREN && fixture.app.area_held() == held,
		"a click on the mesh stepped the part to %s", fixture.app.area_part.label());

	// The wheel is the camera's, part picked or not.
	float distance = fixture.app.camera.distance;
	fixture.scroll(top, { 0.0, 1.0 }, precise: false);
	test::@check(fixture.app.camera.distance < distance, "a wheel notch over a picked part did not zoom");
	test::@check(fixture.app.area_part == crig::AreaPart.WITH_CHILDREN && fixture.app.area_held() == held,
		"a wheel notch changed the part to %s", fixture.app.area_part.label());
	fixture.scroll(top, { 0.0, -1.0 }, precise: false);
	test::@check(!fixture.app.set_area_part(PIECE), "a one-piece mesh let Whole piece take all of it");
	test::@check(fixture.app.area_part == crig::AreaPart.WITH_CHILDREN, "refusing Whole piece dropped the part");

	fixture.feed_key(Key.RETURN);
	test::@check(!fixture.app.area_pending(), "enter left the part pending");
	test::@check(fixture.doc().pins.len() > 0, "enter wrote no pins");
	bool mine = false;
	foreach (pin : fixture.doc().pins.array_view()) if (pin.dot_id == chest) mine = true;
	test::@check(mine, "the pins were not the chest's");
	test::@check(fixture.app.undo(), "the apply left nothing to undo");
	test::eq(fixture.doc().pins.len(), (sz)0);
	test::@check(held > 0, "the chest owned nothing to begin with");
}

<*
 The Weights card: a tab beside Joint and Align whose buttons do everything the
 tool's gestures do — grow, soft edge, mirror, apply and reset — with no key held.
*>
fn void the_weights_card_drives_the_area_tool() @test
{
	io::printn("the Weights card grows, softens, applies and resets a part by buttons");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	uint chest = fixture.two_dots();
	fixture.app.undo_stack.clear();
	fixture.feed(VIEWPORT_CENTER);

	Vec2? tab = fixture.center_of(crig::JOINT_TAB_WEIGHTS_ID);
	if (catch tab)
	{
		test::@check(false, "the Weights tab is not on the rail");
		return;
	}
	fixture.click(tab);
	test::@check(fixture.app.joint_panel_tab == crig::JointPanelTab.WEIGHTS, "the tab did not select Weights");
	test::@check(fixture.in_tree(crig::WEIGHTS_SECTION_ID), "the Weights card was not built");
	test::@check(fixture.in_tree(crig::WEIGHTS_PART_ID) && fixture.in_tree(crig::WEIGHTS_SOFT_ID)
		&& fixture.in_tree(crig::WEIGHTS_MIRROR_ID) && fixture.in_tree(crig::WEIGHTS_RESET_ID),
		"the card is missing a control");

	// Showing the card on a joint opens the tool on its own bone, live: nothing
	// waits for Apply, and Grow moves the joint's edge as it is pressed.
	test::@check(fixture.app.areaing && !fixture.app.area_pending(),
		"the card opened with a part waiting: %s", fixture.notice_text());
	test::eq(fixture.doc().pins.len(), (sz)0);
	fixture.feed(VIEWPORT_CENTER);

	fixture.click(fixture.center_of(crig::WEIGHTS_GROW_ID)!!);
	crig::Dot* grown_dot = fixture.doc().find(chest);
	test::@check(grown_dot != null && grown_dot.grow > 0.0f, "Grow did not push the chest's edge out");
	test::@check(!fixture.app.area_pending(), "Grow left a part waiting");
	test::@check(fixture.app.weights_held(chest), "Grow did not write the chest's weights");
	test::@check(fixture.app.undo() && fixture.doc().find(chest).grow == 0.0f && !fixture.app.weights_held(chest),
		"one undo did not take the Grow back");
	fixture.app.set_area_part(WITH_CHILDREN);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	// Clear and Invert belong to a part of UV islands only.
	test::@check(!fixture.in_tree(crig::WEIGHTS_CLEAR_ID) && !fixture.in_tree(crig::WEIGHTS_INVERT_ID),
		"Clear and Invert showed on a part that is not UV islands");
	fixture.app.area_islands = true;
	fixture.app.area_changed();
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.in_tree(crig::WEIGHTS_CLEAR_ID) && fixture.in_tree(crig::WEIGHTS_INVERT_ID),
		"Clear and Invert are missing on a UV islands part");
	usz grown = fixture.app.area_held();
	fixture.click(fixture.center_of(crig::WEIGHTS_INVERT_ID)!!);
	test::eq(fixture.app.area_held(), fixture.app.geometry.positions.len - grown);
	fixture.click(fixture.center_of(crig::WEIGHTS_INVERT_ID)!!);
	test::eq(fixture.app.area_held(), grown);
	fixture.app.area_islands = false;
	fixture.app.area_changed();
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);

	// The soft edge slider, pressed near the right end of its track.
	Element* slider = fixture.ui.find_id(crig::WEIGHTS_SOFT_ID)!!;
	SliderStyle style = slider.widget_as(Slider).style.resolved();
	Vec2 near_max = slider.absolute + (Vec2){ slider.size.x - style.value_width - style.gap - 2.0f, slider.size.y * 0.5f };
	fixture.click(near_max);
	test::@check(fixture.app.band_share(chest) >= crig::BAND_SHARE_MAX * 0.9f, "the slider left the soft edge at %f",
		fixture.app.band_share(chest));

	fixture.click(fixture.center_of(crig::WEIGHTS_MIRROR_ID)!!);
	test::@check(!fixture.app.area_mirrors(), "the mirror box did not untick");

	fixture.click(fixture.center_of(crig::WEIGHTS_APPLY_ID)!!);
	test::@check(fixture.doc().pins.len() > 0, "Apply wrote no pins");
	bool mine = false;
	foreach (pin : fixture.doc().pins.array_view()) if (pin.dot_id == chest) mine = true;
	test::@check(mine, "Apply did not pin the chest");

	fixture.click(fixture.center_of(crig::WEIGHTS_RESET_ID)!!);
	test::eq(fixture.doc().pins.len(), (sz)0);
	// The paint follows at once: nothing waits, the chest is on its automatic edge.
	test::@check(!fixture.app.area_pending(), "reset left a part waiting");
	test::@check(fixture.app.undo(), "reset left nothing to undo");
	test::@check(fixture.doc().pins.len() > 0, "undoing the reset did not bring the part back");
	fixture.app.redo();
	fixture.feed(VIEWPORT_CENTER);

	// A grown joint: Reset puts its edge back and lets it go, as one step.
	fixture.click(fixture.center_of(crig::WEIGHTS_GROW_ID)!!);
	test::@check(fixture.doc().find(chest).grow > 0.0f, "Grow did not grow the chest");
	fixture.click(fixture.center_of(crig::WEIGHTS_RESET_ID)!!);
	test::@check(fixture.doc().find(chest).grow == 0.0f && fixture.doc().find(chest).band == 0.0f,
		"reset kept the grown edge");
	test::@check(fixture.notice_text().contains("follows the automatic weights again"), "reset said: %s", fixture.notice_text());
	test::@check(fixture.app.undo() && fixture.doc().find(chest).grow > 0.0f, "one undo did not bring the grow back");
	fixture.app.redo();

	// Leaving the card closes the tool it opened.
	fixture.click(fixture.center_of(crig::JOINT_TAB_JOINT_ID)!!);
	test::@check(!fixture.app.areaing, "the Area tool stayed open after the Weights card was left");
}

<*
 Paint, press Apply, and the painting is over: clicks on the mesh change no
 weights and pick no part, and the Part menu stays where it was. A part chosen
 in the menu is the one the mesh then shapes, and a click on it does not step it
 to another. Clicks after Apply used to pick the own part and then With
 children, which read as the brush never having closed.

 *Re-introduce:* let a click on the mesh pick and step the part again, and the
 Part menu moves under the clicks after Apply.
*>
fn void after_apply_the_mesh_takes_no_edits() @test
{
	io::printn("after Apply, clicks and drags on the mesh change no weights and no part");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();
	uint chest = fixture.two_dots();
	fixture.app.camera.snapping = false;
	fixture.app.camera.yaw = 0.0f;
	fixture.app.camera.pitch = 0.0f;

	// A corner of the fixture cube, the mesh's only vertices: found by projecting
	// a dot put there and taken away again.
	uint probe = fixture.doc().add_dot({ -1, 1, 1 }, "probe");
	fixture.app.refresh_ui();
	Vec2? found = fixture.pixel_of(probe);
	fixture.doc().remove_dot(probe);
	fixture.app.select(chest);
	fixture.app.refresh_ui();
	if (catch found)
	{
		test::@check(false, "the cube's corner does not project into the viewport");
		return;
	}
	Vec2 corner = found;
	fixture.feed(VIEWPORT_CENTER);

	fixture.click(fixture.center_of(crig::JOINT_TAB_WEIGHTS_ID)!!);
	fixture.click(fixture.center_of(crig::WEIGHTS_BRUSH_ID)!!);
	test::@check(fixture.app.brushing, "Paint brush did not open the brush");
	fixture.drag(corner, { corner.x + 4, corner.y });
	test::@check(fixture.doc().pins.len() > 0, "the stroke painted nothing");

	fixture.click(fixture.center_of(crig::WEIGHTS_APPLY_ID)!!);
	test::@check(!fixture.app.brushing, "Apply left the brush open");
	test::@check(fixture.app.areaing && !fixture.app.area_pending(), "Apply left a part picked");

	Select* menu = fixture.ui.find_id(crig::WEIGHTS_PART_ID)!!.widget_as(Select);
	usz shown = menu.selected;
	crig::VertexPin[] pins = alloc::clone_slice(mem, fixture.doc().pins.array_view());
	defer alloc::free(mem, pins);
	sz cursor = fixture.app.undo_stack.cursor;
	for (int round = 0; round < 2; round++)
	{
		fixture.click(corner);
		fixture.feed(VIEWPORT_CENTER);
	}
	test::@check(!fixture.app.brushing && !fixture.app.area_pending(),
		"the mesh's gestures after Apply left %s", fixture.app.brushing ? "the brush open" : "a part picked");
	test::eq(fixture.app.undo_stack.cursor, cursor);
	test::eq(fixture.doc().pins.len(), (sz)pins.len);
	foreach (i, pin : fixture.doc().pins.array_view())
	{
		test::@check(pin.vertex == pins[i].vertex && pin.dot_id == pins[i].dot_id && pin.share == pins[i].share,
			"the weights on vertex %d changed after Apply", pin.vertex);
	}
	menu = fixture.ui.find_id(crig::WEIGHTS_PART_ID)!!.widget_as(Select);
	test::@check(menu.selected == shown, "the Part menu moved to %s under the clicks", crig::weights_part_labels[menu.selected]);

	// With children from the menu, then a click on the mesh: it stays.
	fixture.click(fixture.center_of(crig::WEIGHTS_PART_ID)!!);
	fixture.click(fixture.center_of("With children")!!);
	test::@check(fixture.app.area_part == crig::AreaPart.WITH_CHILDREN && fixture.app.area_shaping(),
		"the Part menu did not show With children");
	fixture.click(corner);
	test::@check(fixture.app.area_part == crig::AreaPart.WITH_CHILDREN, "a click on the mesh stepped the part to %s",
		fixture.app.area_part.label());
}

<*
 The Weights card on a finger joint carries the model's knuckle blend. A drag
 writes through as it goes and the release closes one undo step — and the card,
 which rebuilds whenever the document moves, leaves the slider being held alone,
 so the drag reaches where the pointer let go.

 *Re-introduce:* drop the dragging guard from `JointPanel.update`, and the first
 step rebuilds the card under the pointer: the drag stops at the press.
*>
fn void the_knuckle_blend_slider_is_one_undo_step() @test
{
	io::printn("the knuckle blend slider writes through a drag and undoes in one step");

	Fixture fixture;
	if (catch fault error = fixture.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer fixture.close();

	// A wrist with two two-joint fingers, short next to the rig's height.
	uint base = fixture.doc().add_dot({ 0, -0.5f, 0 }, "base");
	uint wrist = fixture.doc().add_dot({ 0, 0.4f, 0 }, "wrist");
	uint a1 = fixture.doc().add_dot({ 0.02f, 0.42f, 0 }, "a1");
	uint a2 = fixture.doc().add_dot({ 0.04f, 0.44f, 0 }, "a2");
	uint b1 = fixture.doc().add_dot({ -0.02f, 0.42f, 0 }, "b1");
	uint b2 = fixture.doc().add_dot({ -0.04f, 0.44f, 0 }, "b2");
	fixture.doc().connect(base, wrist);
	fixture.doc().connect(wrist, a1);
	fixture.doc().connect(a1, a2);
	fixture.doc().connect(wrist, b1);
	fixture.doc().connect(b1, b2);
	fixture.app.mark_rig_stale();
	fixture.app.select(a1);
	fixture.app.undo_stack.clear();
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.app.knuckle_blend_applies(a1) && fixture.app.knuckle_blend_applies(wrist)
		&& !fixture.app.knuckle_blend_applies(base), "the blend is offered on the wrong joints");

	fixture.click(fixture.center_of(crig::JOINT_TAB_WEIGHTS_ID)!!);
	Element*? found = fixture.ui.find_id(crig::WEIGHTS_KNUCKLE_ID);
	if (catch found)
	{
		test::@check(false, "the Weights card on a finger has no knuckle blend slider");
		return;
	}
	Element* slider = found;

	fixture.feed(slider_pixel(slider, 0.25));
	fixture.feed(slider_pixel(slider, 0.25), left: true);
	float mid_drag = fixture.doc().knuckle_blend_fraction();
	fixture.feed(slider_pixel(slider, 0.75), left: true);
	fixture.feed(slider_pixel(slider, 0.75));
	fixture.ui.flush();

	test::@check(math::abs(mid_drag - 0.25f) < 0.03f, "the press wrote %f where a quarter along is 0.25", mid_drag);
	float landed = fixture.doc().knuckle_blend_fraction();
	test::@check(math::abs(landed - 0.75f) < 0.03f, "the drag left the blend at %f where three quarters along is 0.75", landed);

	test::@check(fixture.app.undo(), "the drag left nothing to undo");
	test::@check(fixture.doc().knuckle_blend == 0.0f,
		"one undo left the blend stored as %f rather than unset — the drag was more than one step", fixture.doc().knuckle_blend);

	// Not on a joint the blend does not reach.
	fixture.app.select(base);
	fixture.app.refresh_ui();
	fixture.feed(VIEWPORT_CENTER);
	test::@check(!fixture.in_tree(crig::WEIGHTS_KNUCKLE_ID), "the knuckle blend showed on a joint it does not reach");
}

// How many unique vertices carry a pin.
// How many corners on the cube's far face (z = -1, vertices 0 to 3) carry a pin.
// Whether each vertex's weights differ from the automatic ones: what the hand
// edits changed. Not the pins themselves — an edited joint stores its whole
// column, so every vertex it holds has one.
fn bool[] edited_mask(Fixture* fixture)
{
	usz count = fixture.app.geometry.positions.len;
	bool[] edited = alloc::new_array(mem, bool, (sz)count);
	crig::RigView? opened = fixture.app.open_rig(mem);
	if (catch opened) return edited;
	crig::RigView view = opened;
	defer view.free(mem);
	usz bones = view.len();
	float[] shown = fixture.app.weights(mem, &view);
	defer if (shown.len > 0) alloc::free(mem, shown);
	float[] automatic = fixture.app.weights(mem, &view, AUTOMATIC);
	defer if (automatic.len > 0) alloc::free(mem, automatic);
	if (shown.len != count * bones || automatic.len != shown.len) return edited;
	foreach (usz i, w : shown) if (w != automatic[i]) edited[i / bones] = true;
	return edited;
}

// Whether any vertex holds more of `dot` than the automatic weights give it.
fn bool raised(Fixture* fixture, uint dot)
{
	crig::RigView view = fixture.app.open_rig(mem)!!;
	defer view.free(mem);
	sz joint = view.joint_of(dot);
	if (joint < 0) return false;
	usz bones = view.len();
	float[] shown = fixture.app.weights(mem, &view);
	defer alloc::free(mem, shown);
	float[] automatic = fixture.app.weights(mem, &view, AUTOMATIC);
	defer alloc::free(mem, automatic);
	for (usz v = 0; v < fixture.app.geometry.positions.len; v++)
	{
		if (shown[v * bones + (usz)joint] > automatic[v * bones + (usz)joint]) return true;
	}
	return false;
}

// How many of the cube's far corners (vertices 0 to 3) a hand edit changed.
fn usz far_side_pinned(Fixture* fixture)
{
	bool[] edited = edited_mask(fixture);
	defer alloc::free(mem, edited);
	usz far = 0;
	foreach (v, on : edited) if (on && v < 4) far++;
	return far;
}

// How many vertices a hand edit changed.
fn usz pinned_vertices(Fixture* fixture)
{
	bool[] edited = edited_mask(fixture);
	defer alloc::free(mem, edited);
	usz changed = 0;
	foreach (on : edited) if (on) changed++;
	return changed;
}

fn void the_n_panel_starts_closed() @test
{
	crig::AppState app = crig::new_app({});
	defer app.free();
	test::@check(!app.show_joint_panel, "a fresh app opens with the N-panel closed");
}

<*
 Fix weights checks the model in one click. On a clean cube it says so, with or
 without a joint picked; with one copy of a corner given to the chest past the
 guard it closes the tear and says the same.

 Re-introduce: in `AppState.fix_weights`, skip the surveys after the fixes, and
 the card goes back to its hint instead of saying nothing is left.
*>
fn void the_card_fixes_weights_in_one_click() @test
{
	// The cube with corner 0 stored twice: its first triangle uses the copy, 8.
	rig::TriMesh shared = cube();
	Vec3[] positions = alloc::new_array(mem, Vec3, shared.positions.len + 1);
	defer alloc::free(mem, positions);
	positions[:shared.positions.len] = shared.positions[..];
	positions[shared.positions.len] = shared.positions[0];
	uint[] indices = alloc::new_array(mem, uint, shared.indices.len);
	defer alloc::free(mem, indices);
	indices[..] = shared.indices[..];
	for (usz t = 0; t < indices.len; t += 3)
	{
		if (indices[t] != 0 && indices[t + 1] != 0 && indices[t + 2] != 0) continue;
		for (usz k = t; k < t + 3; k++) if (indices[k] == 0) indices[k] = (uint)shared.positions.len;
		break;
	}

	Fixture harness;
	if (catch fault error = harness.open({ .positions = positions, .indices = indices }))
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Weights card fixes weights in one click");
	fixture.reset();
	uint chest = fixture.two_dots();
	fixture.click(fixture.center_of(crig::JOINT_TAB_WEIGHTS_ID)!!);
	test::@check(fixture.app.weights_card_open(), "the Weights tab did not open the card");
	test::@check(!fixture.in_tree(crig::WEIGHTS_CLEAN_ID), "the card spoke before looking");

	uint picked = fixture.app.selected;
	fixture.app.selected = 0;
	fixture.feed(VIEWPORT_CENTER);
	test::@check(fixture.in_tree(crig::WEIGHTS_FIX_ID), "the card hid the fix with no joint picked");
	fixture.click(fixture.center_of(crig::WEIGHTS_FIX_ID)!!);
	String said = fixture.ui.find_id(crig::WEIGHTS_CLEAN_ID)!!.widget_as(Label).text;
	test::@check(said.starts_with("No strays or tears"), "a clean cube reads \"%s\"", said);
	fixture.app.selected = picked;
	fixture.feed(VIEWPORT_CENTER);

	// One copy given to the chest and the other taken off it, past the guard.
	crig::RigView view = fixture.app.open_rig(mem)!!;
	float[] column = fixture.app.column_of(mem, &view, chest);
	view.free(mem);
	defer alloc::free(mem, column);
	column[0] = 1.0f;
	column[shared.positions.len] = 0.0f;
	fixture.app.store_column(chest, column);
	fixture.feed(VIEWPORT_CENTER);
	test::@check(!fixture.in_tree(crig::WEIGHTS_CLEAN_ID), "the card still reads clean after an edit");

	fixture.click(fixture.center_of(crig::WEIGHTS_FIX_ID)!!);
	said = fixture.ui.find_id(crig::WEIGHTS_CLEAN_ID)!!.widget_as(Label).text;
	test::@check(said.starts_with("No strays or tears"), "after the fix the card reads \"%s\"", said);
	test::@check(fixture.app.tears_current() && fixture.app.tears.len == 0, "the tear is still there");
	test::@check(!fixture.in_tree(crig::WEIGHTS_TEARS_ID), "the card still lists a tear");
}

<*
 What a click could not fix stays on the card by name. The cube is too small to
 hold a stray of its own, so one is listed by hand; weights_test fixes real ones.

 Re-introduce: in `JointPanel.build_weights_tab`, show the clean line whenever
 the surveys are current, and the leftover is hidden.
*>
fn void the_card_names_what_it_could_not_fix() @test
{
	Fixture harness;
	if (catch fault error = harness.open())
	{
		test::@check(false, "could not build the interface (%s) — run from the crig directory", error);
		return;
	}
	defer harness.close();
	Fixture* fixture = &harness;
	io::printn("the Weights card names what it could not fix");
	fixture.reset();
	uint chest = fixture.two_dots();
	fixture.click(fixture.center_of(crig::JOINT_TAB_WEIGHTS_ID)!!);
	fixture.click(fixture.center_of(crig::WEIGHTS_FIX_ID)!!);
	test::@check(fixture.in_tree(crig::WEIGHTS_CLEAN_ID), "a clean cube has no clean line");

	fixture.app.drop_strays();
	fixture.app.strays = alloc::new_array(mem, crig::StrayIsland, 1);
	fixture.app.strays[0] = { .dot = chest, .vertices = alloc::new_array(mem, uint, 1) };
	fixture.app.strays_checked = true;
	fixture.app.strays_revision = fixture.app.undo_stack.revision;
	fixture.app.strays_generation++;
	fixture.feed(VIEWPORT_CENTER);
	String said = fixture.ui.find_id(crig::WEIGHTS_STRAYS_ID)!!.widget_as(Label).text;
	test::@check(said.starts_with("chest 1 vertex"), "the listed stray reads \"%s\"", said);
	test::@check(!fixture.in_tree(crig::WEIGHTS_CLEAN_ID), "the card reads clean over a stray");
}

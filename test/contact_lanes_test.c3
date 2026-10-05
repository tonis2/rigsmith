<*
 Contact lanes: a clip's ground windows shown, edited and persisted, and Plant
 feet writing the windows it used.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::io::file;
import std::math;

// A biped with the swaying clip (feet resting, hips sliding) being edited, and
// the name of a joint the clip plants.
fn String contact_workspace(Fixture* f)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	f.app.editing = f.app.author_clip(swaying_clip(0.06f));
	test::@check(f.app.editing.valid(), "the swaying clip did not land");
	f.app.show_edited();
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	String[] names = f.app.names_for(&view, f.app.editing);
	AnimGround derived = crig::derived_contacts(&view.skeleton, names, *f.app.clip(f.app.editing));
	defer derived.free(mem);
	test::@check(derived.feet.len >= 2, "the biped's feet were not found (%d)", derived.feet.len);
	if (derived.feet.len == 0) return "";
	return derived.feet[0].joint.tcopy();
}

fn AnimGround contact_ground(Fixture* f) => f.app.clip(f.app.editing).ground;

fn bool near_phase(float a, float b) => math::abs(a - b) < 1e-4f;

fn String joint_containing(Fixture* f, String part)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	foreach (name : f.app.names_for(&view, f.app.editing))
	{
		if (name.to_lower_tcopy().contains(part)) return name.tcopy();
	}
	return "";
}

fn void contact_windows_edit_in_one_undo_step_each() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String foot = contact_workspace(&f);
	AnimRef ref = f.app.editing;

	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.add_contact_window(ref, foot, 0.1f, 0.3f), "the window was not added");
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimGround ground = contact_ground(&f);
	test::eq(ground.feet.len, (sz)1);
	test::@check(near_phase(ground.feet[0].down, 0.1f) && near_phase(ground.feet[0].up, 0.4f), "the window is not 0.1–0.4");
	test::@check(!ground.feet[0].off_floor, "a foot was taken for an off-floor contact");

	// A second window on the same foot may not overlap the first.
	history = f.app.undo_stack.cursor;
	test::@check(!f.app.add_contact_window(f.app.editing, foot, 0.3f, 0.2f), "an overlapping window was added");
	test::eq(f.app.undo_stack.cursor, history);
	// Across the seam of a looping clip it wraps.
	test::@check(f.app.add_contact_window(f.app.editing, foot, 0.8f, 0.25f), "a wrapping window was refused");
	ground = contact_ground(&f);
	test::eq(ground.feet.len, (sz)2);
	test::@check(near_phase(ground.feet[1].down, 0.8f) && near_phase(ground.feet[1].up, 0.05f), "the wrap is not 0.8–0.05");
	test::eq(crig::contact_lane_count(ground), (usz)1);

	// Moving and resizing.
	history = f.app.undo_stack.cursor;
	test::@check(f.app.set_contact_window(f.app.editing, 0, 0.15f, 0.4f), "the window did not move");
	test::eq(f.app.undo_stack.cursor, history + 1);
	ground = contact_ground(&f);
	test::@check(near_phase(ground.feet[0].down, 0.15f) && near_phase(ground.feet[0].up, 0.55f), "the move landed wrong");
	test::@check(!f.app.set_contact_window(f.app.editing, 0, 0.5f, 0.35f), "a move onto the other window was allowed");

	// Delete one, then undo and redo it.
	test::@check(f.app.delete_contact_window(f.app.editing, 1), "the window was not deleted");
	test::eq(contact_ground(&f).feet.len, (sz)1);
	test::@check(f.app.undo(), "delete did not undo");
	test::eq(contact_ground(&f).feet.len, (sz)2);
	test::@check(f.app.redo(), "delete did not redo");
	test::eq(contact_ground(&f).feet.len, (sz)1);

	// Removing the lane leaves no ground spec.
	test::@check(f.app.remove_contact_lane(f.app.editing, foot), "the lane was not removed");
	test::@check(!contact_ground(&f).solves(), "the lane is still there");
	test::@check(f.app.undo(), "remove lane did not undo");
	test::eq(contact_ground(&f).feet.len, (sz)1);
}

// A hand is held but never put on the floor: its window leaves the root alone.
fn void a_hand_contact_is_held_off_the_floor() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	contact_workspace(&f);
	String hand = joint_containing(&f, "wrist");
	test::@check(hand.len > 0, "the biped has no hand: %s", joint_names_text(&f));
	if (hand.len == 0) return;
	test::@check(f.app.add_contact_window(f.app.editing, hand, 0.0f, 0.5f), "the hand window was not added");
	AnimTemplate* clip = f.app.clip(f.app.editing);
	test::@check(clip.ground.feet[0].off_floor, "a hand was taken for a floor contact");

	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	String[] names = f.app.names_for(&view, f.app.editing);
	rig::Pose grounded = clip.pose(mem, &view.skeleton, names, 0.25f);
	defer grounded.free(mem);
	rig::Pose raw = clip.pose(mem, &view.skeleton, names, 0.25f, grounded: false);
	defer raw.free(mem);
	foreach (usz j, offset : raw.offsets)
	{
		test::@check((offset - grounded.offsets[j]).length() < 1e-6f, "the hand contact moved the figure");
	}
}

// Windows and the off-floor flag survive the sidecar and a pack .glb; a trim
// keeps them.
fn void contact_windows_persist_and_survive_a_trim() @test
{
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, 2);
	foreach (usz i, &frame : frames)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 1);
		dots[0] = { .joint_name = "hip".copy(mem), .channels = ROTATION, .axis = { 0, 1, 0 }, .angle = (float)i * 0.3f };
		*frame = { .time = (float)i, .dots = dots };
	}
	AnimFoot[] feet = alloc::new_array(mem, AnimFoot, 2);
	feet[0] = { .joint = "hip".copy(mem), .down = 0.7f, .up = 0.2f };
	feet[1] = { .joint = "hip".copy(mem), .down = 0.3f, .up = 0.5f, .off_floor = true };
	AnimTemplate clip = { .name = "Lanes".copy(mem), .duration = 1.0f, .loop = true, .keyframes = frames,
		.ground = { .feet = feet }, .owned = true };
	defer clip.free(mem);
	AnimTemplate[1] source = { clip };

	RigDocument doc = {};
	defer doc.free();
	String text = crig::session_text(mem, &doc, "hero.glb", source[..]);
	defer text.free(mem);
	AnimTemplate[] back = crig::parse_session_clips(mem, text)!!;
	defer crig::free_animations(mem, back);
	test::@check(back.len == 1 && back[0].ground.feet.len == 2, "the sidecar lost a window");
	test::@check(near_phase(back[0].ground.feet[0].down, 0.7f) && near_phase(back[0].ground.feet[0].up, 0.2f)
		&& !back[0].ground.feet[0].off_floor && back[0].ground.feet[1].off_floor, "the sidecar changed a window");

	Vec3[1] joints = { { 0, 1, 0 } };
	int[1] parents = { -1 };
	rig::Skeleton skeleton = { .joints = joints[..], .parents = parents[..] };
	String[1] names = { "hip" };
	String path = "build/contact-lanes-pack.glb";
	defer (void)file::delete(path);
	crig::export_animations_glb(mem, path, &skeleton, names[..], source[..])!!;
	AnimPack pack = crig::read_pack(mem, path)!!;
	defer pack.free(mem);
	test::@check(pack.clips.len == 1 && pack.clips[0].ground.feet.len == 2
		&& !pack.clips[0].ground.feet[0].off_floor && pack.clips[0].ground.feet[1].off_floor
		&& near_phase(pack.clips[0].ground.feet[1].down, 0.3f), "the pack changed a window");

	// Trimming to the first half keeps the wrapping window's tail and the hold.
	AnimTemplate trimmed = crig::clip_cropped(mem, clip, 0.0f, 0.5f);
	defer trimmed.free(mem);
	test::@check(trimmed.ground.feet.len == 2, "the trim dropped a window (%d)", trimmed.ground.feet.len);
	if (trimmed.ground.feet.len == 2)
	{
		test::@check(near_phase(trimmed.ground.feet[0].down, 0.0f) && near_phase(trimmed.ground.feet[0].up, 0.4f),
			"the trimmed window is %f–%f", trimmed.ground.feet[0].down, trimmed.ground.feet[0].up);
		test::@check(trimmed.ground.feet[1].off_floor, "the trim lost the hold");
	}
}

// Plant feet writes the windows it read off the motion into the clip, and a
// second plant uses the lanes as edited.
fn void plant_feet_writes_its_windows_and_replants_from_the_lanes() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	contact_workspace(&f);
	test::@check(!contact_ground(&f).solves(), "the clip starts with contacts");

	crig::PlantOutcome outcome;
	test::@check(f.app.plant_feet(f.app.editing, &outcome), "Plant feet did nothing");
	outcome.free();
	AnimGround ground = contact_ground(&f);
	test::@check(ground.feet.len >= 2, "Plant feet wrote %d windows", ground.feet.len);
	if (ground.feet.len == 0) return;

	test::@check(f.app.set_contact_window(f.app.editing, 0, 0.2f, 0.3f), "the lane did not change");
	test::@check(f.app.plant_feet(f.app.editing, &outcome), "the re-plant did nothing");
	defer outcome.free();
	test::@check(outcome.foot_count >= 1 && near_phase(outcome.feet[0].down, 0.2f) && near_phase(outcome.feet[0].up, 0.5f),
		"the re-plant did not use the edited lane");
	test::@check(contact_ground(&f).feet.len == ground.feet.len, "the re-plant changed the lanes");
}

fn Timeline* contact_sheet(Fixture* f, Element** elem)
{
	*elem = f.ui.find(Timeline)!!;
	return (*elem).widget_as(Timeline);
}

fn Vec2 contact_point(Element* elem, Timeline* sheet, usz lane, float at)
{
	return elem.absolute + (Vec2){ sheet.x_of(elem, at), sheet.lane_y(lane) };
}

// The sheet: + Contact adds a lane under Poses for the selected foot; its bar's
// end and body drag, an empty lane drag adds, right-click deletes. One undo each.
fn void contact_lanes_show_and_edit_on_the_sheet() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	String foot = contact_workspace(&f);
	f.app.anim_snap_off = true;
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	Element* elem;
	Timeline* sheet = contact_sheet(&f, &elem);
	test::eq(sheet.lanes.len, (sz)1);

	// + Contact with the foot selected, from the playhead at 0.
	Dot* dot = f.app.dot_named(foot);
	test::@check(dot != null, "no dot for %s", foot);
	if (!dot) return;
	f.app.selected = dot.id;
	f.app.edit_time = 0;
	sz history = f.app.undo_stack.cursor;
	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_ADD_CONTACT_ID);
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	sheet = contact_sheet(&f, &elem);
	test::eq(sheet.lanes.len, (sz)2);
	test::@check(sheet.lanes[1].contact && sheet.lanes[1].joint == foot, "the contact lane is not under Poses");
	test::eq(sheet.bars.len, (sz)1);
	test::@check(near_phase(contact_ground(&f).feet[0].down, 0.0f) && near_phase(contact_ground(&f).feet[0].up, 0.25f),
		"+ Contact did not plant a quarter from the playhead");

	// Drag the bar's end from 0.25 s to 0.4 s.
	history = f.app.undo_stack.cursor;
	f.drag(contact_point(elem, sheet, 1, 0.25f) - (Vec2){ 1, 0 }, contact_point(elem, sheet, 1, 0.4f));
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimFoot window = contact_ground(&f).feet[0];
	test::@check(math::abs(window.down) < 0.01f && math::abs(window.up - 0.4f) < 0.02f,
		"the end drag gave %f–%f", window.down, window.up);

	// Drag the whole bar later by 0.2 s.
	sheet = contact_sheet(&f, &elem);
	history = f.app.undo_stack.cursor;
	f.drag(contact_point(elem, sheet, 1, 0.2f), contact_point(elem, sheet, 1, 0.4f));
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	window = contact_ground(&f).feet[0];
	test::@check(math::abs(window.down - 0.2f) < 0.02f && math::abs(window.up - 0.6f) < 0.02f,
		"the move gave %f–%f", window.down, window.up);

	// Drag on the empty part of the lane to add a second window.
	sheet = contact_sheet(&f, &elem);
	history = f.app.undo_stack.cursor;
	f.drag(contact_point(elem, sheet, 1, 0.7f), contact_point(elem, sheet, 1, 0.9f));
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(contact_ground(&f).feet.len, (sz)2);

	// Right-click the new bar and delete it.
	sheet = contact_sheet(&f, &elem);
	f.right_click(contact_point(elem, sheet, 1, 0.8f));
	f.ui.flush();
	test::@check(f.in_tree(crig::ANIM_CONTACT_DELETE_ID), "the bar menu has no Delete");
	history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_CONTACT_DELETE_ID)!!);
	f.ui.flush();
	f.feed({ 0, 0 });
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(contact_ground(&f).feet.len, (sz)1);

	// Curves mode leaves the lanes alone and hides + Contact; Keys brings both back.
	crig::anim_sheet_mode_chosen(f.ui, 1);
	f.ui.flush();
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	test::@check(f.app.anim_show_curves, "Curves did not open");
	f.open_menu(crig::ANIM_TOOLS_BUTTON_ID);
	test::@check(f.ui.find_id(crig::ANIM_ADD_CONTACT_ID)!!.widget_as(PopupMenuItem).item.disabled,
		"Add contact is offered in Curves");
	f.close_menu();
	crig::anim_sheet_mode_chosen(f.ui, 0);
	f.ui.flush();
	f.feed({ 0, 0 });
	f.feed({ 0, 0 });
	sheet = contact_sheet(&f, &elem);
	test::eq(sheet.lanes.len, (sz)2);
}

fn String joint_names_text(Fixture* f)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	DString text;
	text.tinit();
	foreach (name : f.app.names_for(&view, f.app.editing)) { text.append(name); text.append(' '); }
	return text.str_view();
}

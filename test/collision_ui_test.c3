<*
 The collision check as the pane shows it (C5): the one control, the status
 line that speaks only when the check is off or cut back, the Advanced
 dialog behind More…, and what the session keeps of it.
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;

// A biped on the cube with a clip open in the Animations tab — the state in
// which the posing row, and so the control, is built.
fn void collision_workspace(Fixture* f)
{
	f.app.set_self_collision(true);
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Posed", 2, from_rest: true);
	f.app.editing = clip;
	f.app.edit_time = 0;
	f.app.show_edited();
	f.click(tab_center(f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	f.app.undo_stack.clear();
}

// The HUD's modes line as the 3D view would paint it — off `hud_lines`
// directly, since the Animations tab has replaced the view in this fixture.
fn bool hud_modes_say(Fixture* f, String needle)
{
	crig::HudSnapshot shown = {
		.allow_intersections = f.app.doc.allow_intersections,
		.collision_mode = f.app.collision_mode,
	};
	char[512] scratch;
	crig::HudLine[crig::HUD_MAX_LINES] lines;
	usz count = crig::hud_lines(&f.app, shown, scratch[..], lines[..]);
	foreach (line : lines[:count]) if (line.text.contains(needle)) return true;
	return false;
}

<*
 The whole system is behind a switch in Settings, off until asked for: with
 it off the posing row has no control, More… has no Collision…, the modes
 line says nothing, no policy is built, and a pull goes through the body as
 it always did. The Settings checkbox turns it on at once — the policy
 comes up and the control appears — and off again.
*>
fn void the_system_is_off_until_settings_switches_it_on() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(!f.app.config.self_collision, "the system is on without being asked for");
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Posed", 2, from_rest: true);
	f.app.editing = clip;
	f.app.edit_time = 0;
	f.app.show_edited();
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();

	f.open_menu(crig::ANIM_TOOLS_BUTTON_ID);
	test::@check(f.in_tree(crig::ANIM_CHECK_ID) && !f.in_tree(crig::ANIM_PREVENT_ID),
		"the per-rig control is shown with the system off");
	f.close_menu();
	test::@check(!f.in_tree(crig::ANIM_COLLISION_STATUS_ID), "the status line is shown with the system off");
	test::@check(!crig::collision_status_shown(&f.app), "the status line would be shown with the system off");
	test::@check(!hud_modes_say(&f, "collision") && !hud_modes_say(&f, "intersections"),
		"the modes line speaks of the check with the system off");
	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	test::@check(!f.in_tree("anim-collision"), "the clip menu offers Collision… with the system off");
	f.feed_key(ESCAPE);
	f.ui.flush();

	// A pose write is not checked: no policy, nothing tested.
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	test::@check(f.app.rebind_skin(&view), "the cube would not bind");
	test::@check(!f.app.collision_policy.ready, "a policy was built with the system off");
	test::@check(!f.app.collision_blocking_active(), "the check is active with the system off");
	f.app.select(view.dot_ids[view.len() - 1]);
	test::@check(f.app.begin_turn(), "R did not begin");
	f.app.turn_joint({ 0, 0, 1 }, 1.0f);
	test::@check(!f.app.last_block.tested, "a turn was tested with the system off");
	f.app.cancel_drag();

	// Settings switches it on: the policy is built over the bound skin and
	// the control appears.
	crig::open_settings_dialog(f.ui);
	f.ui.flush();
	Element* box = f.ui.find_id(crig::SETTINGS_COLLISION_ID)!!;
	test::@check(!box.widget_as(Checkbox).checked, "the Settings box opens checked");
	f.click(f.center_of(crig::SETTINGS_COLLISION_ID)!!);
	f.ui.flush();
	test::@check(f.app.config.self_collision, "the click did not switch the system on");
	test::@check(f.app.collision_policy.ready, "switching on did not build the policy");
	test::@check(f.app.collision_blocking_active(), "the check is not active with the system on");
	f.feed_key(Key.ESCAPE);
	f.ui.flush();
	f.open_menu(crig::ANIM_TOOLS_BUTTON_ID);
	test::@check(f.in_tree(crig::ANIM_PREVENT_ID), "the per-rig control did not appear");
	f.close_menu();

	// And off again: the policy goes with it, and the pane follows the
	// switch on its own.
	f.app.set_self_collision(false);
	f.feed(VIEWPORT_CENTER);
	f.feed(VIEWPORT_CENTER);
	test::@check(!f.app.collision_policy.ready && !f.app.collision_blocking_active(), "switching off left the policy up");
	f.open_menu(crig::ANIM_TOOLS_BUTTON_ID);
	test::@check(!f.in_tree(crig::ANIM_PREVENT_ID), "the per-rig control did not go");
	f.close_menu();
}

fn void prevent_intersections_is_one_checkbox_that_the_session_keeps() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	collision_workspace(&f);

	test::@check(!f.app.doc.allow_intersections, "a fresh rig does not block");
	f.open_menu(crig::ANIM_TOOLS_BUTTON_ID);
	test::@check(f.ui.find_id(crig::ANIM_PREVENT_ID)!!.widget_as(PopupMenuItem).item.checked,
		"the control does not read as on");
	f.close_menu();

	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_PREVENT_ID);
	test::@check(f.app.doc.allow_intersections, "the click did not turn the check off");
	test::@check(!f.app.collision_blocking_active(), "the check is still active with the control off");
	test::@check(hud_modes_say(&f, "intersections allowed"), "the modes line does not admit the check is off");
	String allowed = crig::collision_status_text(&f.app);
	defer allowed.free(mem);
	test::@check(allowed.starts_with("Intersections allowed"), "the status line does not say so");

	String text = crig::session_text(mem, &f.app.doc, "posed.glb");
	defer text.free(mem);
	test::@check(text.contains(`"version": 25`) && text.contains(`"allow_intersections": true`),
		"the session did not keep the setting");
	crig::RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session with the setting did not parse");
		return;
	}
	crig::RigDocument back = parsed;
	defer back.free();
	test::@check(back.allow_intersections, "the setting did not come back");

	f.pick_menu_item(crig::ANIM_TOOLS_BUTTON_ID, crig::ANIM_PREVENT_ID);
	test::@check(!f.app.doc.allow_intersections, "the second click did not turn the check back on");
	String plain = crig::session_text(mem, &f.app.doc, "posed.glb");
	defer plain.free(mem);
	test::@check(!plain.contains("allow_intersections"), "the default is written out");
}

fn void the_status_line_speaks_only_when_the_check_is_not_simply_on() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	collision_workspace(&f);
	test::@check(f.app.collision_policy.ready, "the workspace has no policy to report");

	// A working check says nothing: no text, and no line in the pane.
	String rest = crig::collision_status_text(&f.app);
	test::@check(rest.len == 0, "at rest the line reads \"%s\"", rest);
	f.feed(VIEWPORT_CENTER);
	f.feed(VIEWPORT_CENTER);
	if (try Element* line = f.ui.find_id(crig::ANIM_COLLISION_STATUS_ID))
	{
		test::@check(false, "the pane shows a status line with nothing to say");
	}

	// A stop says nothing either — the joint standing at the body is the
	// whole announcement — and nothing is drawn for it unless asked.
	f.app.last_block = {
		.tested = true, .blocked = true, .tests = 9, .seconds = 0.012f,
		.contact = { .hit = true, .pair = { .a = 0, .b = 1 } },
		.shown_at = f.app.pose_generation,
	};
	String stopped = crig::collision_status_text(&f.app);
	test::@check(stopped.len == 0, "a blocked gesture reads \"%s\"", stopped);
	test::@check(!f.app.show_collision_contacts, "contacts are drawn by default");

	// Paused: says so, with the cost and how to retry — and the line appears.
	f.app.collision_mode = PAUSED;
	String paused = crig::collision_status_text(&f.app);
	defer paused.free(mem);
	test::@check(paused.starts_with("Live blocking paused") && paused.contains("Prevent intersections"),
		"paused reads \"%s\"", paused);
	test::@check(hud_modes_say(&f, "collision check paused"), "the modes line does not say paused");
	// Two frames: the pane notices the mode and rebuilds, then the line's own
	// update runs. Looked up after, since a rebuild replaces it.
	f.feed(VIEWPORT_CENTER);
	f.feed(VIEWPORT_CENTER);
	Element* status = f.ui.find_id(crig::ANIM_COLLISION_STATUS_ID)!!;
	test::@check(status.widget_as(LiveLabel).shown == paused, "the pane's line reads \"%s\", not the status text",
		status.widget_as(LiveLabel).shown);

	// Reduced likewise.
	f.app.collision_mode = REDUCED;
	String reduced = crig::collision_status_text(&f.app);
	defer reduced.free(mem);
	test::@check(reduced.starts_with("Live blocking reduced") && reduced.contains("Prevent intersections"),
		"reduced reads \"%s\"", reduced);
	test::@check(hud_modes_say(&f, "collision check reduced"), "the modes line does not say reduced");

	// Back in full, the line goes.
	f.app.collision_mode = FULL;
	f.feed(VIEWPORT_CENTER);
	f.feed(VIEWPORT_CENTER);
	if (try Element* line = f.ui.find_id(crig::ANIM_COLLISION_STATUS_ID))
	{
		test::@check(false, "the status line stayed after the check came back in full");
	}
	test::@check(!hud_modes_say(&f, "collision"), "the modes line still mentions the check");
}

fn void the_collision_dialog_sets_the_numbers_and_keeps_the_excluded_pairs() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	collision_workspace(&f);

	f.click(f.center_of("anim-more")!!);
	f.ui.flush();
	f.click(f.center_of("anim-collision")!!);
	f.ui.flush();
	Element* dialog = f.ui.find_id(crig::COLLISION_DIALOG_ID)!!;
	test::@check(dialog.widget_as(Dialog).open, "Collision… did not open the dialog");
	test::@check(!f.ui.find_id(crig::ANIM_CLIP_MENU_ID)!!.widget_as(Dialog).open, "the clip menu stayed open under it");

	// The fields open on what stands.
	test::eq(f.ui.find_id(crig::COLLISION_CLEARANCE_ID)!!.widget_as(TextField).value(), "0.5");
	test::eq(f.ui.find_id(crig::COLLISION_STEPS_ID)!!.widget_as(TextField).value(), "8");
	test::eq(f.ui.find_id(crig::COLLISION_BUDGET_ID)!!.widget_as(TextField).value(), "100");
	test::@check(!f.ui.find_id(crig::COLLISION_SHOW_CONTACTS_ID)!!.widget_as(Checkbox).checked, "the contact switch opens on");

	Element* clearance = f.ui.find_id(crig::COLLISION_CLEARANCE_ID)!!;
	clearance.widget_as(TextField).set_text(clearance, "1.5");
	Element* steps = f.ui.find_id(crig::COLLISION_STEPS_ID)!!;
	steps.widget_as(TextField).set_text(steps, "4");
	Element* budget = f.ui.find_id(crig::COLLISION_BUDGET_ID)!!;
	budget.widget_as(TextField).set_text(budget, "20");
	usz contacts_before = f.app.collision_policy.rest_contacts.len;
	f.click(f.center_of(crig::COLLISION_APPLY_ID)!!);
	f.ui.flush();
	test::@check(math::abs(f.app.doc.collision_clearance - 0.015f) < 1.0e-6f, "the clearance did not land: %.4f", f.app.doc.collision_clearance);
	test::@check(math::abs(f.app.collision_clearance() - f.app.picker.scale * 0.015f) < 1.0e-6f, "the model-space clearance did not follow");
	test::eq(f.app.collision_search_steps_setting(), (usz)4);
	test::@check(math::abs(f.app.collision_budget - 0.02f) < 1.0e-6f, "the budget did not land: %.4f", f.app.collision_budget);
	test::@check(f.app.collision_policy.ready && f.app.collision_policy.rest_contacts.len >= contacts_before,
		"a wider clearance found fewer rest contacts, or lost the policy");
	// The dialog rebuilt on the new numbers.
	test::eq(f.ui.find_id(crig::COLLISION_CLEARANCE_ID)!!.widget_as(TextField).value(), "1.5");

	// The session keeps the clearance and reads it back.
	String text = crig::session_text(mem, &f.app.doc, "posed.glb");
	defer text.free(mem);
	test::@check(text.contains(`"collision_clearance": 0.01`), "the session did not keep the clearance");
	crig::RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session with a clearance did not parse");
		return;
	}
	crig::RigDocument back = parsed;
	defer back.free();
	test::@check(math::abs(back.collision_clearance - 0.015f) < 1.0e-6f, "the clearance did not come back");

	// A clearance no rig can mean is refused with the reason.
	clearance = f.ui.find_id(crig::COLLISION_CLEARANCE_ID)!!;
	clearance.widget_as(TextField).set_text(clearance, "50");
	f.click(f.center_of(crig::COLLISION_APPLY_ID)!!);
	f.ui.flush();
	test::@check(f.notice_text().contains("at most"), "a clearance of half the model was accepted, or refused without saying why: %s", f.notice_text());
	test::@check(math::abs(f.app.doc.collision_clearance - 0.015f) < 1.0e-6f, "a refused clearance changed the rig");

	// Excluding needs exactly two joints selected, and lists the pair with a
	// way to take it back.
	f.click(f.center_of(crig::COLLISION_EXCLUDE_ID)!!);
	f.ui.flush();
	test::@check(f.notice_text().contains("two joints"), "excluding with nothing selected did not ask for two: %s", f.notice_text());
	uint first = f.app.doc.dots[0].id;
	uint second = f.app.doc.dots[1].id;
	f.app.select(first);
	f.app.extend_selection(second);
	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::COLLISION_EXCLUDE_ID)!!);
	f.ui.flush();
	test::@check(f.app.doc.has_exclusion(first, second), "the selected pair was not excluded");
	test::eq(f.app.undo_stack.cursor, history + 1);
	Element*? row = f.ui.find(crig::CollisionExclusionRemove);
	if (catch row)
	{
		test::@check(false, "the excluded pair is not listed with a Remove");
		return;
	}
	f.click(row.absolute + row.size * 0.5f);
	f.ui.flush();
	test::@check(!f.app.doc.has_exclusion(first, second), "Remove did not take the pair back");
	test::eq(f.app.undo_stack.cursor, history + 2);
	if (try Element* left = f.ui.find(crig::CollisionExclusionRemove))
	{
		test::@check(false, "a removed pair is still listed");
	}

	// The contact drawing is a switch here and nowhere else.
	f.click(f.center_of(crig::COLLISION_SHOW_CONTACTS_ID)!!);
	f.ui.flush();
	test::@check(f.app.show_collision_contacts, "the switch did not turn contact drawing on");
	f.click(f.center_of(crig::COLLISION_SHOW_CONTACTS_ID)!!);
	f.ui.flush();
	test::@check(!f.app.show_collision_contacts, "the switch did not turn it back off");

	// Reset puts every number back, and Done closes.
	f.click(f.center_of(crig::COLLISION_RESET_ID)!!);
	f.ui.flush();
	test::@check(f.app.doc.collision_clearance == 0.0f && f.app.collision_search_steps_override == 0 && f.app.collision_budget == 0.0f,
		"reset left a number set");
	test::eq(f.ui.find_id(crig::COLLISION_CLEARANCE_ID)!!.widget_as(TextField).value(), "0.5");
	f.click(f.center_of(crig::COLLISION_DONE_ID)!!);
	f.ui.flush();
	test::@check(!f.ui.find_id(crig::COLLISION_DIALOG_ID)!!.widget_as(Dialog).open, "Done left the dialog open");
}

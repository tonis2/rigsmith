<*
 Look-at targets in the interface: the context menu rows and the handle's pick.
*>
module crig_tests::ui;
import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;

fn bool has_id(Fixture* f, String id)
{
	if (catch f.ui.find_id(id)) return false;
	return true;
}

fn void pose_head(Fixture* f, Dot** head_out)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Look", 1);
	f.app.editing = clip;
	f.app.stop_animation();
	f.app.stage = POSE_STAGE;
	*head_out = f.app.dot_named("head");
	test::@check(*head_out != null, "the biped has no head");
}

<*
 Joints selected: add, lock to the target and unlock rows follow what exists.
*>
fn void the_context_menu_offers_look_at_rows() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Dot* head;
	pose_head(&f, &head);
	f.app.select(head.id);
	f.app.refresh_ui();

	crig::open_viewport_context(f.ui, { 0, 0 });
	f.ui.flush();
	test::@check(has_id(&f, "viewport-context-add-aim"), "no Add look-at target row");
	test::@check(!has_id(&f, "viewport-context-lock-aim"), "a Lock row before there is a target");
	test::@check(!has_id(&f, "viewport-context-unlock-aim"), "an Unlock row before there is a lock");

	crig::scene_context_add_aim(f.ui);
	test::@check(f.app.aim_index(head.id) >= 0, "the row did not lock the selection to a new target");
	test::@check(f.app.clip(f.app.editing).aim_targets.len == 1, "no target");
	crig::open_viewport_context(f.ui, { 0, 0 });
	f.ui.flush();
	test::@check(has_id(&f, "viewport-context-lock-aim"), "no Lock to row for the only target");
	test::@check(has_id(&f, "viewport-context-unlock-aim"), "no Unlock row");
	test::@check(!has_id(&f, "viewport-context-mute-target"), "target rows without the ring");

	crig::scene_context_unlock_aim(f.ui);
	test::@check(f.app.aim_index(head.id) < 0, "Unlock did not unlock");
	test::@check(f.app.clip(f.app.editing).aim_targets.len == 1, "Unlock removed the target");
	crig::scene_context_lock_aim(f.ui);
	test::@check(f.app.aim_index(head.id) >= 0, "Lock to did not lock");
}

<*
 Nothing selected while posing: only Add. Opened from a ring: the target's rows.
 A stale selected target offers none.
*>
fn void the_context_menu_has_target_rows_from_a_ring() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Dot* head;
	pose_head(&f, &head);
	f.app.select(0);
	f.app.refresh_ui();

	crig::open_viewport_context(f.ui, { 0, 0 });
	f.ui.flush();
	test::@check(has_id(&f, "viewport-context-add-aim"), "no Add row with nothing selected");
	test::@check(!has_id(&f, "viewport-context-lock-aim"), "Lock row with nothing selected");

	crig::scene_context_add_aim(f.ui);
	test::@check(f.app.clip(f.app.editing).aim_targets.len == 1, "no target added");
	String name = f.app.clip(f.app.editing).aim_targets[0].name;
	f.app.select_aim_target(name);

	crig::open_viewport_context(f.ui, { 0, 0 }, true);
	f.ui.flush();
	test::@check(has_id(&f, "viewport-context-mute-target"), "no Mute target row");
	test::@check(has_id(&f, "viewport-context-delete-target"), "no Delete target row");
	test::@check(!has_id(&f, "viewport-context-lock-aim"), "Lock selected joints without a selection");

	f.app.select(head.id);
	f.app.select_aim_target(f.app.clip(f.app.editing).aim_targets[0].name);
	crig::open_viewport_context(f.ui, { 0, 0 }, true);
	f.ui.flush();
	test::@check(has_id(&f, "viewport-context-lock-aim"), "no Lock selected joints row");
	crig::scene_context_lock_aim(f.ui);
	test::@check(f.app.aim_index(head.id) >= 0, "the row did not lock");

	crig::open_viewport_context(f.ui, { 0, 0 }, true);
	crig::scene_context_mute_target(f.ui);
	test::@check(f.app.clip(f.app.editing).aim_targets[0].mute, "Mute target did nothing");
	crig::open_viewport_context(f.ui, { 0, 0 }, true);
	crig::scene_context_delete_target(f.ui);
	test::@check(f.app.clip(f.app.editing).aim_targets.len == 0, "Delete target did nothing");

	// A stale selection (the target is gone) shows no target rows.
	f.app.select_aim_target("Gone");
	crig::open_viewport_context(f.ui, { 0, 0 }, true);
	f.ui.flush();
	test::@check(!has_id(&f, "viewport-context-mute-target"), "target rows for a stale target");
	test::@check(!has_id(&f, "viewport-context-delete-target"), "delete row for a stale target");
}

<*
 A handle is picked before the joint under it, and only while the rig is posed.
*>
fn void a_look_at_handle_is_picked_before_a_joint() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Look", 1);
	f.app.editing = clip;
	f.app.stop_animation();
	f.app.stage = POSE_STAGE;
	Dot* head = f.app.dot_named("head");
	test::@check(head != null, "the biped has no head");
	f.app.select(head.id);
	test::@check(f.app.add_aim_target(), "the target was not added");
	f.app.refresh_ui();
	f.ui.flush();

	Viewport* view = f.viewport.widget_as(Viewport);
	test::@check(f.app.posed_aims.len == 1, "no handle");
	Vec2? local = crig::project(f.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y), f.app.posed_aims[0].at, VIEWPORT);
	if (catch local)
	{
		test::@check(false, "SKIPPED: the handle is off screen");
		return;
	}
	test::@check(view.pick_aim(f.viewport, local) == 0, "the pick at the ring missed it");
	test::@check(view.pick_aim(f.viewport, local + (Vec2){ 200, 200 }) < 0, "a pick far from it found it");

	// Put the head's own circle under the ring: the ring still wins the pick.
	f.app.posed_aims[0].at = f.app.dot_position(*head);
	Vec2? over = crig::project(f.app.camera.view_projection(VIEWPORT.x / VIEWPORT.y), f.app.dot_position(*head), VIEWPORT);
	if (try over)
	{
		test::@check(view.pick_dot(f.viewport, over) == head.id, "the head is not under the pointer");
		test::@check(view.pick_aim(f.viewport, over) == 0, "the joint beat the handle");
	}

	f.app.stage = JOINTS_STAGE;
	test::@check(view.pick_aim(f.viewport, over!!) < 0, "handles are pickable while the rig is edited");
}

fn Vec2 centre_of(Element* elem) => elem.absolute + (Vec2){ elem.size.x * 0.5f, elem.size.y * 0.5f };

<*
 The joint card's Look at section: a hint without targets, a picker with them
 that locks and unlocks, and the lock's own controls once locked.
*>
fn void the_joint_card_has_a_look_at_section() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Dot* head;
	pose_head(&f, &head);
	f.app.select(head.id);
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();

	test::@check(!has_id(&f, crig::JOINT_AIM_TARGET_ID), "a picker before there is a target");
	test::@check(!has_id(&f, crig::JOINT_AIM_SPREAD_ID), "a spread stepper before there is a target");

	test::@check(f.app.add_aim_target(), "the target was not added");
	f.app.unlock_joint(head.id);
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(has_id(&f, crig::JOINT_AIM_TARGET_ID), "no target picker");
	test::@check(!has_id(&f, crig::JOINT_AIM_SPREAD_ID), "spread stepper while unlocked");

	crig::joint_aim_target_chosen(f.ui, 1);
	test::@check(f.app.aim_index(head.id) >= 0, "picking the target did not lock");
	f.ui.flush();
	f.feed({ 0, 0 });
	f.ui.flush();
	test::@check(has_id(&f, crig::JOINT_AIM_SPREAD_ID), "no spread stepper");
	test::@check(has_id(&f, crig::JOINT_AIM_INFLUENCE_ID), "no influence slider");
	test::@check(has_id(&f, crig::JOINT_AIM_MUTE_ID), "no Mute toggle");
	test::@check(has_id(&f, crig::JOINT_AIM_UNLOCK_ID), "no Unlock button");

	f.click(centre_of(f.ui.find_id(crig::JOINT_AIM_UNLOCK_ID)!!));
	f.ui.flush();
	test::@check(f.app.aim_index(head.id) < 0, "Unlock did not unlock");

	crig::joint_aim_target_chosen(f.ui, 1);
	crig::joint_aim_target_chosen(f.ui, 0);
	test::@check(f.app.aim_index(head.id) < 0, "None did not unlock");
}

<*
 A target is a lane under Poses with a mark per key; a selected key deletes as
 one undo step, and the lane goes with the last key.
*>
fn void a_target_shows_as_a_look_at_lane_and_deletes_by_key() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	AnimRef clip = f.app.new_clip("Look", 2);
	f.app.editing = clip;
	f.app.stop_animation();
	Dot* head = f.app.dot_named("head");
	test::@check(head != null, "the biped has no head");
	f.app.select(head.id);
	f.app.stage = POSE_STAGE;
	f.app.edit_time = 0.0f;
	f.click(tab_center(&f, f.ui.find(AreaTabStrip)!!, TAB_ANIMATIONS));
	f.ui.flush();
	Timeline* before = f.ui.find(Timeline)!!.widget_as(Timeline);
	usz lanes = before.lanes.len;

	test::@check(f.app.add_aim_target(), "the target was not added");
	f.app.edit_time = 1.0f;
	AnimTemplate* held = f.app.clip(f.app.editing);
	f.app.land_clip(f.app.editing, crig::clip_with_target_key(mem, *held, f.app.clip(f.app.editing).aim_targets[0].name,
		{ .time = 1.0f, .at = { 0.2f, 0.9f, 0.5f }, .interpolation = LINEAR }));
	f.app.refresh_ui();
	f.ui.flush();
	f.feed({ 0, 0 });

	Element* elem = f.ui.find(Timeline)!!;
	Timeline* sheet = elem.widget_as(Timeline);
	test::@check(sheet.lanes.len == lanes + 1, "no Look at lane (%d lanes, was %d)", sheet.lanes.len, lanes);
	if (sheet.lanes.len != lanes + 1) return;
	crig::TimelineLane lane = sheet.lanes[lanes];
	test::@check(lane.aim && lane.trailing == "Look at" && lane.joint == f.app.clip(f.app.editing).aim_targets[0].name,
		"the lane is not the aim's");
	usz marks;
	foreach (mark : sheet.marks) if (mark.aim && mark.lane == lanes) marks++;
	test::@check(marks == 2, "the lane has %d marks, not 2", marks);

	// Selecting a key and deleting it is one undo step.
	String joint = f.app.clip(f.app.editing).aim_targets[0].name;
	test::@check(f.app.select_animation_aim_key(f.app.editing, joint, 1.0f), "the key would not select");
	test::@check(f.app.animation_aim_key_selected(f.app.editing, joint, 1.0f), "the key is not selected");
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.delete_selected_animation_keys(f.app.editing), "the delete did nothing");
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(f.app.clip(f.app.editing).aims.len == 1 && f.app.clip(f.app.editing).aim_targets[0].keys.len == 1,
		"the key was not removed");
	test::@check(f.app.animation_aim_key_selection_count(f.app.editing) == 0, "the selection survived the delete");
	f.app.undo();
	test::@check(f.app.clip(f.app.editing).aim_targets[0].keys.len == 2, "undo did not bring the key back");
}

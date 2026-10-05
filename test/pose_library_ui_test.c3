<*
 The pose library in the N-panel's Pose tab: opening the tab, Save pose with
 its pre-filled name, Apply, Apply mirrored, Rename and Delete through their ids.
*>
module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import std::core::test;
import std::math;
import std::math::quaternion;

fn void pose_library_ui_saves_applies_renames_and_deletes() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.4f);
	pose_clipboard_workspace(&f, turn);
	f.app.auto_key = true;

	test::@check(!pose_panel_has(&f, crig::ANIM_POSE_NAME_ID), "the pose library is up before the Pose tab is opened");
	f.open_pose_tab();
	test::@check(f.app.joint_panel_tab == crig::JointPanelTab.POSE, "the Pose tab did not open");
	test::@check(pose_panel_has(&f, crig::ANIM_POSE_NAME_ID), "the Pose tab has no pose library");
	test::eq(field_value(&f, crig::ANIM_POSE_NAME_ID), "Pose 1");

	sz history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_POSE_SAVE_ID)!!);
	f.ui.flush();
	test::eq(f.app.doc.poses.len, (sz)1);
	test::eq(f.app.doc.poses[0].name, "Pose 1");
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::eq(field_value(&f, crig::ANIM_POSE_NAME_ID), "Pose 2");
	test::@check(pose_panel_has(&f, crig::ANIM_POSE_LIST_ID), "the saved pose is not listed");

	// Straighten the leg at the far key, then apply there: keyed by Auto-key,
	// one undo step.
	test::@check(f.app.pose_from_clip(f.app.editing, 2) && f.app.set_working_pose(f.app.selected, quaternion::IDENTITY, {}),
		"the leg would not straighten at 2 s");
	f.app.edit_time = 2;
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "the straight leg would not key");
	test::@check(f.app.scrub_to(2), "the parked clip would not scrub");
	f.ui.flush();
	history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_POSE_APPLY_ID)!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check((pose_turn(&f, POSE_LEFT, 2) - pose_turn_of(turn)).length() < 1.0e-4f,
		"Apply did not key the saved turn at 2 s");

	f.click(f.center_of(crig::ANIM_POSE_APPLY_MIRRORED_ID)!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history + 2);
	Vec3 want = pose_turn_of(turn);
	want = { want.x, -want.y, -want.z };
	test::@check((pose_turn(&f, POSE_RIGHT, 2) - want).length() < 1.0e-4f,
		"Apply mirrored did not put the reflection on the right leg");
	test::@check(f.app.undo() && pose_turn(&f, POSE_RIGHT, 2).length() < 1.0e-6f,
		"the mirrored apply did not undo as one step");
	f.ui.flush();

	// Selected joints only, with nothing selected, is refused.
	f.click(f.center_of(crig::ANIM_POSE_SELECTED_ONLY_ID)!!);
	f.ui.flush();
	test::@check(f.app.pose_library_selected_only, "the checkbox did not turn on Selected joints only");
	f.app.select(0);
	f.ui.flush();
	history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_POSE_APPLY_ID)!!);
	f.ui.flush();
	test::eq(f.app.undo_stack.cursor, history);

	// Rename: the field takes the pose's name, selected, and the button renames.
	f.click(f.center_of(crig::ANIM_POSE_RENAME_ID)!!);
	f.ui.flush();
	test::@check(f.app.pose_library_renaming, "Rename… did not start renaming");
	test::eq(field_value(&f, crig::ANIM_POSE_NAME_ID), "Pose 1");
	f.type_into(f.ui.find_id(crig::ANIM_POSE_NAME_ID)!!, "Stride");
	f.click(f.center_of(crig::ANIM_POSE_SAVE_ID)!!);
	f.ui.flush();
	test::eq(f.app.doc.poses[0].name, "Stride");
	test::@check(!f.app.pose_library_renaming, "renaming did not finish");

	history = f.app.undo_stack.cursor;
	f.click(f.center_of(crig::ANIM_POSE_DELETE_ID)!!);
	f.ui.flush();
	test::eq(f.app.doc.poses.len, (sz)0);
	test::eq(f.app.undo_stack.cursor, history + 1);
	test::@check(!pose_panel_has(&f, crig::ANIM_POSE_LIST_ID), "a deleted pose is still listed");
	test::@check(f.app.undo() && f.app.doc.poses.len == 1, "the delete did not undo");
}

fn bool pose_panel_has(Fixture* f, String id)
{
	if (try f.ui.find_id(id)) return true;
	return false;
}

fn String field_value(Fixture* f, String id)
{
	if (try Element* field = f.ui.find_id(id)) return field.widget_as(TextField).value();
	return "";
}

<*
 The pose library: named poses kept in the project, applied whole, mirrored or
 to the selected joints, through Auto-key or the pending draft.

     `c3c test --trust=full --test-filter crig_tests::pose_library`

 Built on the pose clipboard's biped fixture: the left thigh turned to `first`
 at 0 s and `second` at 0.5 s, the left thigh selected.
*>
module crig_tests::pose_library;

import crig;
import rig;
import crig_tests::pose_clipboard;
import std::core::test;
import std::math;
import std::math::quaternion;

const String LEFT = "thigh_L";
const String RIGHT = "thigh_R";
const String HIPS = "hips";

fn Vec3 turn(AnimKeyDot dot) => pose_clipboard::turn_of(dot);
fn Vec3 turn_q(Quaternionf q) => pose_clipboard::turn_of_quaternion(q);
fn bool same(Vec3 a, Vec3 b) => pose_clipboard::same_turn(a, b);

fn void a_saved_pose_applies_at_another_time_as_one_undo() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	f.app.auto_key = true;

	sz cursor = f.app.undo_stack.cursor;
	test::eq(f.app.save_named_pose(""), (sz)0);
	test::eq(f.app.undo_stack.cursor, cursor + 1);
	test::eq(f.app.doc.poses.len, (sz)1);
	test::eq(f.app.doc.poses[0].name, "Pose 1");
	test::eq(f.app.doc.poses[0].dots.len, (sz)1);
	test::eq(f.app.doc.poses[0].dots[0].joint_name, LEFT);

	test::@check(f.app.undo() && f.app.doc.poses.len == 0, "saving the pose did not undo");
	test::@check(f.app.redo() && f.app.doc.poses.len == 1, "saving the pose did not redo");

	f.app.stop_animation();
	f.app.edit_time = 0.5f;
	Vec3 hips_before = turn(f.entry(HIPS, 0.5f));
	cursor = f.app.undo_stack.cursor;
	test::eq(f.app.apply_saved_pose(0), (usz)1);
	test::eq(f.app.undo_stack.cursor, cursor + 1);
	test::@check(!f.app.pose_edit_pending, "Auto-key left the applied pose pending");
	test::@check(same(turn(f.entry(LEFT, 0.5f)), turn_q(f.first)), "the applied leg does not hold the saved turn");
	test::@check(same(turn(f.entry(HIPS, 0.5f)), hips_before), "applying one leg rewrote the hips");

	test::@check(f.app.undo(), "the apply would not undo");
	test::@check(same(turn(f.entry(LEFT, 0.5f)), turn_q(f.second)), "undo did not restore the previous key");
	test::eq(f.app.doc.poses.len, (sz)1);
}

fn void a_saved_pose_applies_mirrored_onto_the_twin() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	f.app.auto_key = true;

	test::eq(f.app.save_named_pose("Stride"), (sz)0);
	f.app.stop_animation();
	f.app.edit_time = 0.5f;
	Vec3 left_before = turn(f.entry(LEFT, 0.5f));
	test::eq(f.app.apply_saved_pose(0, mirrored: true), (usz)1);
	Vec3 want = turn_q(f.first);
	want = { want.x, -want.y, -want.z };
	Vec3 got = turn(f.entry(RIGHT, 0.5f));
	test::@check(same(got, want), "the right leg turns (%.3f, %.3f, %.3f); the reflection asks for (%.3f, %.3f, %.3f)",
		got.x, got.y, got.z, want.x, want.y, want.z);
	test::@check(same(turn(f.entry(LEFT, 0.5f)), left_before), "a mirrored apply rewrote the left leg");
}

fn void selected_only_applies_part_of_a_whole_pose() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	f.app.auto_key = true;

	// The whole pose at 0 s: every named joint.
	f.app.select(0);
	test::@check(f.app.save_named_pose("Whole") == 0, "the whole pose did not save");
	test::@check(f.app.doc.poses[0].dots.len > 2, "the whole pose holds %d joints", f.app.doc.poses[0].dots.len);

	// Lean the hips at 0.5 s so a whole apply would visibly undo it.
	Quaternionf lean = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.3f);
	test::@check(f.app.pose_from_clip(f.clip, 0.5f) && f.app.set_working_pose(f.hips, lean, {}), "the hips would not lean");
	f.app.edit_time = 0.5f;
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "the lean would not key");
	f.app.stop_animation();
	f.app.edit_time = 0.5f;

	f.app.select(0);
	test::eq(f.app.apply_saved_pose(0, selected_only: true), (usz)0);

	f.app.select(f.left);
	test::eq(f.app.apply_saved_pose(0, selected_only: true), (usz)1);
	test::@check(same(turn(f.entry(LEFT, 0.5f)), turn_q(f.first)), "the selected leg did not take the pose");
	test::@check(same(turn(f.entry(HIPS, 0.5f)), turn_q(lean)), "selected-only rewrote the unselected hips");

	f.app.stop_animation();
	f.app.edit_time = 0.5f;
	test::@check(f.app.apply_saved_pose(0) > 2, "the whole pose did not apply");
	test::@check(same(turn(f.entry(HIPS, 0.5f)), (Vec3){}), "the whole apply left the hips leaning");
}

fn void without_auto_key_an_applied_pose_waits_as_a_draft() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	f.app.auto_key = false;

	test::eq(f.app.save_named_pose("Kick"), (sz)0);
	f.app.stop_animation();
	f.app.edit_time = 0.5f;
	sz cursor = f.app.undo_stack.cursor;
	test::eq(f.app.apply_saved_pose(0), (usz)1);
	test::eq(f.app.undo_stack.cursor, cursor);
	test::@check(f.app.pose_edit_active && f.app.pose_edit_pending, "the applied pose is not pending");
	test::@check(same(turn_q(f.app.working_pose(f.left).rotation), turn_q(f.first)), "the draft does not show the pose");
	test::@check(same(turn(f.entry(LEFT, 0.5f)), turn_q(f.second)), "the clip was keyed without Auto-key");

	test::@check(f.app.key_pose_edit(CHANGED), "the pending pose would not key");
	test::@check(same(turn(f.entry(LEFT, 0.5f)), turn_q(f.first)), "Key pose did not keep the applied pose");
}

fn void renaming_and_deleting_poses_undo() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }

	test::eq(f.app.save_named_pose(""), (sz)0);
	test::eq(f.app.save_named_pose(""), (sz)1);
	test::eq(f.app.doc.poses[1].name, "Pose 2");
	// The same name replaces rather than adding a second.
	test::eq(f.app.save_named_pose("Pose 2"), (sz)1);
	test::eq(f.app.doc.poses.len, (sz)2);

	test::@check(!f.app.rename_saved_pose(0, "Pose 2"), "renamed onto a name in use");
	test::@check(!f.app.rename_saved_pose(0, "  "), "renamed to nothing");
	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.rename_saved_pose(0, "Contact"), "the rename was refused");
	test::eq(f.app.undo_stack.cursor, cursor + 1);
	test::eq(f.app.doc.poses[0].name, "Contact");
	test::@check(f.app.undo() && f.app.doc.poses[0].name == "Pose 1", "the rename did not undo");
	test::@check(f.app.redo() && f.app.doc.poses[0].name == "Contact", "the rename did not redo");

	test::@check(f.app.delete_saved_pose(0), "the delete was refused");
	test::eq(f.app.doc.poses.len, (sz)1);
	test::eq(f.app.doc.poses[0].name, "Pose 2");
	test::@check(f.app.undo() && f.app.doc.poses.len == 2 && f.app.doc.poses[0].name == "Contact",
		"the delete did not undo");
}

fn void poses_survive_the_session_file() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }

	test::eq(f.app.save_named_pose("Stride \"L\""), (sz)0);
	f.app.select(0);
	test::eq(f.app.save_named_pose("Whole"), (sz)1);

	String text = crig::session_text(mem, &f.app.doc, "figure.glb");
	defer text.free(mem);
	crig::RigDocument? parsed = crig::parse_session(mem, text);
	if (catch parsed)
	{
		test::@check(false, "the session did not read back");
		return;
	}
	defer parsed.free();
	test::eq(parsed.poses.len, (sz)2);
	test::eq(parsed.poses[0].name, "Stride \"L\"");
	test::eq(parsed.poses[0].dots.len, (sz)1);
	test::eq(parsed.poses[0].dots[0].joint_name, LEFT);
	test::@check(same(turn(parsed.poses[0].dots[0]), turn_q(f.first)), "the saved turn did not read back");
	test::eq(parsed.poses[1].dots.len, f.app.doc.poses[1].dots.len);

	// A pose carries to another clip on the same rig.
	f.app.auto_key = true;
	AnimRef other = f.app.new_clip("other", 1.0f, from_rest: true);
	f.app.editing = other;
	f.app.edit_time = 0.0f;
	test::eq(f.app.apply_saved_pose(0), (usz)1);
	test::@check(same(turn(f.app.clip(f.app.editing).entry_at(LEFT, 0.0f)), turn_q(f.first)),
		"the pose did not land in the other clip");
}

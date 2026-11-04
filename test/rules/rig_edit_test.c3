<*
 Every rig edit leaves the same things out of date. See rules/editing.md.
*>
module crig_tests::rig_edit;

import crig;
import crig_tests::mcp;
import rig;
import std::core::test;
import std::math;

fn void every_rig_edit_refreshes_the_same_way() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	f.open();
	defer f.close();

	f.app.plan_targets_stale = false;
	uint id = f.app.place({ 0.2f, 0.5f, 0 });
	test::@check(f.app.plan_targets_stale, "placing a dot didn't mark the plan's targets");

	f.app.plan_targets_stale = false;
	f.app.remove(id);
	test::@check(f.app.plan_targets_stale, "removing a dot didn't mark the plan's targets");

	f.app.plan_targets_stale = false;
	String? answer = f.call_tool_text("edit_rig", `{"ops":[{"op":"place","position":[0.2,0.5,0]}]}`);
	test::@check(@ok(answer), "edit_rig refused");
	if (try answer) answer.free(mem);
	test::@check(f.app.plan_targets_stale, "edit_rig didn't mark the plan's targets");
}

// A clip follows a joint's new name, or it stops moving that joint.
fn void renaming_a_joint_keeps_its_keys() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	String? made = f.call_tool_text("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Base"}`);
	if (try made) made.free(mem);
	AnimRef ref = f.app.clip_named_in_authored("Base");
	RigView view = f.app.open_rig(mem)!!;
	rig::Pose before = f.app.evaluated_clip_pose(mem, &view, *f.app.clip(ref), ref, 1.0f);
	defer before.free(mem);
	view.free(mem);

	String? named = f.call_tool_text("edit_rig", `{"ops":[{"op":"name","joint":"knee_L","name":"shin_L"}]}`);
	if (try named) named.free(mem);
	RigView after_view = f.app.open_rig(mem)!!;
	defer after_view.free(mem);
	rig::Pose after = f.app.evaluated_clip_pose(mem, &after_view, *f.app.clip(ref), ref, 1.0f);
	defer after.free(mem);
	usz moved;
	foreach (j, turn : before.rotations) if (math::abs(turn.v.dot(after.rotations[j].v)) < 0.9999f) moved++;
	test::@check(moved == 0, "%s joints moved after a rename", moved);
}

<*
 Every rig edit leaves the same things out of date. See rules/editing.md.
*>
module crig_tests::rig_edit;

import crig;
import crig_tests::mcp;
import std::core::test;

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

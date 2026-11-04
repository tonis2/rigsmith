<*
 What counts as a foot doesn't depend on how a rig spells it. See rules/posing.md.
*>
module crig_tests::feet;

import crig;
import crig_tests::mcp;
import std::core::test;

fn void pin_feet_finds_feet_under_any_name() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	String? named = f.call_tool_text("edit_rig", `{"ops":[{"op":"name","joint":"ankle_L","name":"armature:LeftFoot"},{"op":"name","joint":"ankle_R","name":"armature:RightFoot"}]}`);
	test::@check(@ok(named), "the feet were renamed");
	if (try named) named.free(mem);
	String? landed = f.call_tool_text("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Base"}`);
	test::@check(@ok(landed), "the clip imported");
	if (try landed) landed.free(mem);

	String? pinned = f.call_tool_text("pin_feet", `{"clip":"Base"}`);
	test::@check(@ok(pinned), "pin_feet refused a rig whose feet aren't called ankle");
	if (try pinned) pinned.free(mem);
}

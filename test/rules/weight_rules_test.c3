<*
 What every weight tool promises. See rules/weights.md.
*>
module crig_tests::weight_rules;

import crig;
import crig_tests::mcp;
import rig;
import std::core::test;

struct WeightEdit @local
{
	String tool;
	String args;
}

const WeightEdit[*] EDITS @local = {
	{ "paint_weights", `{"dot":"knee_L","weight":0.1,"vertices":[0,1,2,3,4,5,6,7]}` },
	{ "paint_weights", `{"dot":"knee_L","weight":0,"vertices":[0,1,2,3,4,5,6,7]}` },
	{ "pin_weights", `{"dot":"knee_L","vertices":[0,1,2,3]}` },
	{ "pin_weights", `{"dot":"knee_L","weight":0.5,"at_least":0.05}` },
	{ "edit_rig", `{"ops":[{"op":"grow","joint":"knee_L","grow":0.05}]}` },
	{ "edit_rig", `{"ops":[{"op":"grow","joint":"knee_L","soft":0.8}]}` },
};

fn void an_edit_to_one_joint_never_changes_another() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	sz mine = view.joint_of(f.app.dot_named("knee_L").id);
	test::@check(mine >= 0, "the rig has knee_L");

	foreach (edit : EDITS)
	{
		float[] before = f.app.weights(mem, &view);
		defer alloc::free(mem, before);
		String? answer = f.call_tool_text(edit.tool, edit.args);
		test::@check(@ok(answer), "%s refused %s", edit.tool, edit.args);
		if (try answer) answer.free(mem);

		RigView now = f.app.open_rig(mem)!!;
		defer now.free(mem);
		float[] after = f.app.weights(mem, &now);
		defer alloc::free(mem, after);
		usz moved = 0;
		foreach (usz i, weight : before)
		{
			if (weight == after[i]) continue;
			if (i % bones == (usz)mine) continue;
			moved++;
		}
		test::@check(moved == 0, "%s %s moved %s weights of other joints", edit.tool, edit.args, moved);
	}
}

fn void copies_of_a_point_keep_one_weight() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();

	// A point stored twice: the first weld with two copies.
	rig::MeshAdjacency* around = f.app.adjacency_for();
	usz a;
	usz b;
	bool found;
	for (usz v = 0; v < around.vertices() && !found; v++)
	{
		usz first = (usz)around.first[around.class_of[v]];
		if (first == v) continue;
		a = first;
		b = v;
		found = true;
	}
	test::@check(found, "the humanoid has a seam");

	String args = string::tformat(`{"dot":"knee_L","weight":0.37,"vertices":[%s]}`, a);
	String? answer = f.call_tool_text("paint_weights", args);
	test::@check(@ok(answer), "paint_weights refused");
	if (try answer) answer.free(mem);

	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	usz bones = view.len();
	usz mine = (usz)view.joint_of(f.app.dot_named("knee_L").id);
	float[] after = f.app.weights(mem, &view);
	defer alloc::free(mem, after);
	test::eq(after[a * bones + mine], after[b * bones + mine]);
}

// Weight modes never overlap: whichever opens closes the others.
fn void one_weight_mode_at_a_time() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	f.app.selected = f.app.dot_named("knee_L").id;

	test::@check(f.app.begin_brush(), "the brush opened");
	test::@check(f.app.weight_tool() == WeightTool.BRUSH, "the brush is open");
	test::@check(f.app.begin_lasso(PIN), "the lasso opened");
	test::@check(f.app.weight_tool() == WeightTool.LASSO, "the lasso took over");
	test::@check(!f.app.brushing, "the brush closed");
	test::@check(f.app.begin_brush(), "the brush opened again");
	test::@check(!f.app.lassoing, "the lasso closed");
}

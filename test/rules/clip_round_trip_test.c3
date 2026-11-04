<*
 What get_clip writes, apply_clip reads back whole. See rules/clips.md.
*>
module crig_tests::clip_round_trip;

import crig;
import crig_tests::mcp;
import std::core::test;

// get_clip's answer, renamed and applied as a new clip.
fn AnimTemplate* round_tripped(Fixture* f, String clip, String name) @local
{
	String text = f.call_tool_text("get_clip", string::tformat(`{"clip":"%s"}`, clip))!!;
	defer text.free(mem);
	String again = text.treplace(string::tformat(`"name":"%s"`, clip), string::tformat(`"name":"%s"`, name));
	String? answer = f.call_tool_text("apply_clip", again);
	test::@check(@ok(answer), "apply_clip refused its own get_clip");
	if (try answer) answer.free(mem);
	return f.app.clip(f.app.clip_named_in_authored(name));
}

fn void a_clip_round_trips_whole() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	String? made = f.call_tool_text("author_gait", `{"name":"Stride","duration":1.1,"gait":"walk"}`);
	test::@check(@ok(made), "the gait was authored");
	if (try made) made.free(mem);

	AnimTemplate* clip = f.app.clip(f.app.clip_named_in_authored("Stride"));
	clip.keyframes[0].dots[0].rotation_tangents = { .mode = FLAT };
	clip.ground.floor = 0.25f;
	clip.ground.floor_set = true;

	AnimTemplate* back = round_tripped(f, "Stride", "Back");
	test::@check(back != null, "the copy landed");
	test::@check(back.gait.set, "the gait was lost");
	test::@check(back.keyframes[0].dots[0].rotation_tangents.mode == FLAT, "the tangent was lost");
	test::@check(back.ground.floor_set, "the floor was lost");
}

// A floor with no feet is still a stated height.
fn void a_floor_alone_round_trips() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	String? made = f.call_tool_text("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Base"}`);
	test::@check(@ok(made), "the clip imported");
	if (try made) made.free(mem);
	AnimTemplate* clip = f.app.clip(f.app.clip_named_in_authored("Base"));
	clip.ground = { .floor = 0.25f, .floor_set = true };

	AnimTemplate* back = round_tripped(f, "Base", "Back");
	test::@check(back != null && back.ground.floor_set, "the floor was lost");
}

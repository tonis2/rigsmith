<*
 Where a time lands in a clip, whichever door asks. See rules/posing.md.
*>
module crig_tests::clip_time;

import crig;
import crig_tests::mcp;
import rig;
import std::core::test;
import std::math;

struct TimeCase @local
{
	bool loop;
	float time;
	float local;
	float phase;
}

const TimeCase[*] CASES @local = {
	{ false, -1.0f, 0.0f, 0.0f }, // before a one-shot: its first frame
	{ false, 0.5f, 0.5f, 0.25f },
	{ false, 2.0f, 2.0f, 1.0f },  // the end of a one-shot is its end, not its start
	{ false, 3.0f, 2.0f, 1.0f },  // past it: held
	{ true, 0.5f, 0.5f, 0.25f },
	{ true, 3.0f, 1.0f, 0.5f },   // past a loop: round again
	{ true, 4.0f, 0.0f, 0.0f },
};

fn void a_time_lands_in_the_clip_by_one_rule() @test
{
	foreach (one : CASES)
	{
		AnimTemplate clip = { .duration = 2.0f, .loop = one.loop };
		test::@check(math::abs(clip.local_time(one.time) - one.local) < 1e-6f, "loop %s at %s", one.loop, one.time);
		if (one.time >= 0.0f) test::@check(math::abs(clip.phase_at(one.time) - one.phase) < 1e-6f, "phase, loop %s at %s", one.loop, one.time);
	}
	AnimTemplate empty = { .duration = 0.0f, .loop = true };
	test::eq(empty.local_time(3.0f), 0.0f);
}

// A render past the end of a one-shot shows its last frame, as the player does.
fn void a_render_past_a_one_shot_holds_its_last_frame() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model("assets/animations/humanoid.glb")) return;
	defer f.close();
	String? landed = f.call_tool_text("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Base"}`);
	if (catch landed)
	{
		test::@check(false, "the clip did not import");
		return;
	}
	landed.free(mem);

	AnimRef ref = f.app.clip_named_in_authored("Base");
	AnimTemplate* clip = f.app.clip(ref);
	test::@check(clip != null && !clip.loop, "the clip is a one-shot");
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);

	PoseShoot shoot = { .clip = "Base", .clip_start = clip.duration, .clip_speed = 1.0f, .travel = true };
	rig::Pose at_end = crig::exam_pose(&f.app, &view, &shoot, ref, 0.0f);
	defer at_end.free(mem);
	rig::Pose past = crig::exam_pose(&f.app, &view, &shoot, ref, 0.5f);
	defer past.free(mem);
	foreach (j, turn : at_end.rotations)
	{
		test::@check(math::abs(turn.v.dot(past.rotations[j].v)) > 0.9999f, "joint %s moved past the end", j);
	}
}

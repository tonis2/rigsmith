<*
 Every reader of a pose sees the same pose. See rules/posing.md.
*>
module crig_tests::pose_readers;

import crig;
import crig_tests::mcp;
import rig;
import std::core::test;
import std::math;

const float AT @local = 0.4f;

fn bool made(Fixture* f, String tool, String args) @local
{
	String? answer = f.call_tool_text(tool, args);
	if (catch answer)
	{
		test::@check(false, "%s refused", tool);
		return false;
	}
	answer.free(mem);
	return true;
}

// A walk with a pinned foot and a head looking at something, so every stage acts.
fn bool open_held_walk(Fixture* f) @local
{
	if (!f.open_model("assets/animations/humanoid.glb")) return false;
	return made(f, "import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Base"}`)
		&& made(f, "set_pins", `{"clip":"Base","pins":[{"joint":"ankle_L","from":0.2,"to":0.8}]}`)
		&& made(f, "set_aim_target", `{"clip":"Base","name":"Look","at":[0.6,1.5,1]}`)
		&& made(f, "set_aim", `{"clip":"Base","joint":"head","target":"Look"}`);
}

fn void same_pose(rig::Pose a, rig::Pose b, String reader) @local
{
	foreach (j, turn : a.rotations)
	{
		test::@check(math::abs(turn.v.dot(b.rotations[j].v)) > 0.99999f, "%s turns joint %s differently", reader, j);
		test::@check((a.offsets[j] - b.offsets[j]).length() < 1e-4f, "%s moves joint %s differently", reader, j);
	}
}

fn void every_reader_sees_the_pose_that_plays() @test
{
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_held_walk(f))
	{
		f.close();
		return;
	}
	defer f.close();

	AnimRef ref = f.app.clip_named_in_authored("Base");
	AnimTemplate* clip = f.app.clip(ref);
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose played = f.app.evaluated_clip_pose(mem, &view, *clip, ref, AT, aimed: true);
	defer played.free(mem);

	PoseShoot shoot = { .clip = "Base", .clip_start = AT, .clip_speed = 1.0f, .travel = true };
	rig::Pose render = crig::exam_pose(&f.app, &view, &shoot, ref, 0.0f);
	defer render.free(mem);
	same_pose(played, render, "a render");

	ConstraintRig table = crig::constraint_rig_of(mem, &f.app.doc, &view.skeleton, view.dot_ids);
	defer table.free(mem);
	rig::Pose measured = crig::played_pose(mem, &view.skeleton, view.names, *clip, AT, table);
	defer measured.free(mem);
	same_pose(played, measured, "a measurement");
}

// How a fitted or placed rig sits on its mesh, said in the answers: a plan's fit,
// joints off the mesh as rig issues, what a snap moved and the limit tables a move
// left pointing off their bones.
module crig_tests::fit_report;

import crig;
import crig_tests::helpers;
import crig_tests::mcp;
import crig_tests::shared_app;
import std::collections::object;
import std::core::test;
import std::io;
import std::math::vector;

const String HUMANOID = "assets/animations/humanoid.glb";

fn bool open_humanoid(Fixture* f)
{
	if (!f.open_model(HUMANOID)) return false;
	shared_app::attach_all_packs(&f.app);
	return true;
}

fn String issue_kinds(Object* scene, String joint)
{
	Object* rig = crig::member(scene, "rig");
	Object* issues = crig::member(rig, "rig_issues");
	if (!issues) return "";
	for (usz i = 0; i < (usz)issues.get_len(); i++)
	{
		Object* issue = issues.get_at((sz)i);
		if ((issue.get_string("joint") ?? "") == joint) return (issue.get_string("kind") ?? "").tcopy();
	}
	return "";
}

<*
 A plan fitted to a body it suits says it fits, and which way it faces.
*>
fn void a_plan_that_fits_says_so() @test
{
	io::printn("fit report: apply_plan says how the plan fits");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_humanoid(f)) return;
	defer f.close();

	Object* fitted = f.call_checked("apply_plan", `{"plan":"biped"}`);
	if (!fitted) return;
	defer fitted.free();
	Object* fit = crig::member(fitted, "fit");
	test::@check(fit != null, "apply_plan answered without a fit");
	if (!fit) return;
	test::@check((fit.get_string("verdict") ?? "") == "fits", "the biped on the humanoid reads %s", fit.get_string("verdict") ?? "");
	test::@check((fit.get_string("facing") ?? "") == "+z", "the fit faces %s", fit.get_string("facing") ?? "");
	Object* outside = crig::member(fit, "outside_mesh");
	test::@check(outside != null && outside.get_len() == 0, "the fit left joints off the mesh");
}

<*
 A joint put off the mesh on purpose (snap off) is a rig issue until it is back.
*>
fn void a_joint_off_the_mesh_is_a_rig_issue() @test
{
	io::printn("fit report: a joint off the mesh is a rig issue");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_humanoid(f)) return;
	defer f.close();

	Object* before = f.call_checked("get_scene", "{}");
	if (!before) return;
	defer before.free();
	test::@check(issue_kinds(before, "wrist_L") == "", "the wrist was an issue before it moved");

	Object* moved = f.call_checked("edit_rig", `{"ops":[{"op":"move","joint":"wrist_L","position":[5,5,5]}],"snap":false}`);
	if (!moved) return;
	moved.free();
	Object* after = f.call_checked("get_scene", "{}");
	if (!after) return;
	defer after.free();
	test::@check(issue_kinds(after, "wrist_L") == "outside_mesh", "a wrist off the mesh is not an outside_mesh issue");
}

<*
 A move whose point the snap pulled in says where the dot went; a batch of
 moves that turned bones off their tables' frames says plan_limits is owed.
*>
fn void a_move_says_what_the_snap_did_and_what_limits_it_left() @test
{
	io::printn("fit report: edit_rig names snapped joints and stale limits");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_humanoid(f)) return;
	defer f.close();

	crig::Dot* wrist = f.app.dot_named("wrist_L");
	test::@check(wrist != null, "the humanoid has no wrist_L");
	if (!wrist) return;
	float height = f.app.model_height();
	Vec3 outside = wrist.position + (Vec3){ 0, height * 0.05f, 0 };
	String args = string::tformat(`{"ops":[{"op":"move","joint":"wrist_L","position":[%f,%f,%f]}]}`,
		outside.x, outside.y, outside.z);
	Object* snapped = f.call_checked("edit_rig", args);
	if (!snapped) return;
	defer snapped.free();
	Object* notes = crig::member(snapped, "snapped");
	test::@check(notes != null && notes.get_len() == 1, "the snap that moved the wrist went unsaid");
	if (notes && notes.get_len() == 1)
	{
		Object* note = notes.get_at(0);
		test::@check((note.get_string("joint") ?? "") == "wrist_L", "the snap names %s", note.get_string("joint") ?? "");
		test::@check((note.get_float("moved") ?? 0) > 0, "the snap says it moved nothing");
	}

	// The knee carried far forward turns the thigh off its table's frame, once
	// that table is pinned to a frame of its own.
	crig::Dot* knee = f.app.dot_named("knee_L");
	crig::Dot* thigh = f.app.dot_named("thigh_L");
	if (!knee || !thigh) return;
	crig::JointRotationLimits limits = f.app.doc.rotation_limits_of(thigh.id);
	limits.constrained = true;
	limits.has_saved_frame = true;
	limits.saved_frame = helpers::frame_of(&f.app.doc, thigh.id).rotation;
	test::@check(f.app.doc.set_rotation_limits(thigh.id, limits), "the thigh's table would not take a frame");
	Vec3 forward = knee.position + (Vec3){ 0, 0, height * 0.25f };
	String bend = string::tformat(`{"ops":[{"op":"move","joint":"knee_L","position":[%f,%f,%f]}],"snap":false}`,
		forward.x, forward.y, forward.z);
	Object* bent = f.call_checked("edit_rig", bend);
	if (!bent) return;
	defer bent.free();
	Object* stale = crig::member(bent, "limits_stale");
	test::@check(stale != null && stale.get_len() > 0, "a move that turned the thigh off its frame did not say plan_limits is owed");
}

<*
 A chain from the elbow to the wrist lays three new dots, each hung off the one
 before, the last exactly at the tip and the others in the forearm's middle.
*>
fn void a_chain_lays_a_run_of_dots_down_the_limb() @test
{
	io::printn("fit report: edit_rig chain lays a run of centred dots");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_humanoid(f)) return;
	defer f.close();
	crig::Dot* elbow = f.app.dot_named("elbow_L");
	crig::Dot* wrist = f.app.dot_named("wrist_L");
	if (!elbow || !wrist) return;
	Vec3 from = elbow.position;
	Vec3 tip = wrist.position + (Vec3){ 0, 0.01f, 0.01f };
	sz before = f.app.doc.dots.len();
	String args = string::tformat(`{"ops":[{"op":"chain","base":"elbow_L","tip":[%f,%f,%f],"names":["fore_a","fore_b","fore_c"]}]}`,
		tip.x, tip.y, tip.z);
	Object* laid = f.call_checked("edit_rig", args);
	if (!laid) return;
	defer laid.free();
	test::@check(f.app.doc.dots.len() == before + 3, "the chain laid %d dots, not 3", f.app.doc.dots.len() - before);
	crig::Dot* a = f.app.dot_named("fore_a");
	crig::Dot* c = f.app.dot_named("fore_c");
	test::@check(a != null && c != null, "the chain's dots are not named");
	if (!a || !c) return;
	test::@check((c.position - tip).length() < 1.0e-5f, "the tip moved off where it was asked for");
	// Centred, the first dot is near the line from the elbow to the wrist.
	Vec3 line = (wrist.position - from).normalize();
	Vec3 off = (a.position - from) - line * (a.position - from).dot(line);
	test::@check(off.length() < (wrist.position - from).length() * 0.25f, "the first dot is %f off the forearm's line", off.length());
	test::@check(f.app.doc.has_edge(elbow.id, a.id) || f.app.doc.has_edge(a.id, elbow.id), "the chain does not hang off the elbow");
}

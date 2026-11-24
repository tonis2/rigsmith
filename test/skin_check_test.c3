// The skin as a clip plays: measure_clip measures every edge of the mesh posed by
// the weights, and a region torn between joints that move apart is a fault.
module crig_tests::skin_check;

import crig;
import crig_tests::mcp;
import std::collections::object;
import std::core::test;
import std::io;
import std::math;

const String HUMANOID = "assets/animations/humanoid.glb";

fn bool open_walking(Fixture* f)
{
	if (!f.open_model(HUMANOID)) return false;
	Object* walk = f.call_checked("import_clip", `{"path":"assets/animations/humanoid.glb","clip":"Walk_slow","name":"Walk"}`);
	if (!walk) return false;
	walk.free();
	return true;
}

fn usz skin_issues(Object* measured)
{
	Object* issues = crig::member(measured, "issues");
	usz count = 0;
	if (!issues) return 0;
	for (usz i = 0; i < (usz)issues.get_len(); i++)
	{
		if ((issues.get_at((sz)i).get_string("kind") ?? "") == "skin_stretch") count++;
	}
	return count;
}

<*
 The humanoid's own walk on its own weights stretches nothing past tolerance,
 and the answer says the skin was measured.
*>
fn void a_clean_walk_stretches_no_skin() @test
{
	io::printn("skin check: a clean walk stretches no skin");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_walking(f)) return;
	defer f.close();

	Object* measured = f.call_checked("measure_clip", `{"clip":"Walk"}`);
	if (!measured) return;
	defer measured.free();
	Object* skin = crig::member(measured, "skin");
	test::@check(skin != null && (skin.get_bool("measured") ?? false), "measure_clip did not measure the skin");
	test::@check(skin_issues(measured) == 0, "a clean walk reads %d skin faults", skin_issues(measured));
}

<*
 A patch of the left knee given to the right knee is torn across the legs on
 every step: a skin_stretch fault naming both knees, the verdict needs_work, and
 a fix to paint the region back.
*>
fn void skin_torn_between_two_legs_is_a_fault() @test
{
	io::printn("skin check: skin torn between the knees is a fault");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!open_walking(f)) return;
	defer f.close();

	crig::Dot* knee = f.app.dot_named("knee_L");
	test::@check(knee != null, "the humanoid has no knee_L");
	if (!knee) return;
	float height = f.app.model_height();
	DString vertices = dstring::new(mem);
	defer vertices.free();
	usz taken = 0;
	foreach (usz v, p : f.app.geometry.positions)
	{
		if ((p - knee.position).length() > height * 0.04f) continue;
		if (taken > 0) vertices.append_char(',');
		vertices.appendf("%d", v);
		taken++;
	}
	test::@check(taken > 4, "only %d vertices near the left knee", taken);
	String args = string::tformat(`{"dot":"knee_R","weight":1,"vertices":[%s]}`, vertices.str_view());
	Object* painted = f.call_checked("paint_weights", args);
	if (!painted) return;
	painted.free();

	Object* measured = f.call_checked("measure_clip", `{"clip":"Walk"}`);
	if (!measured) return;
	defer measured.free();
	test::@check(skin_issues(measured) > 0, "skin torn across the legs read as no fault");
	test::@check((measured.get_string("verdict") ?? "") == "needs_work", "a torn skin left the walk %s", measured.get_string("verdict") ?? "");
	Object* faults = crig::member(crig::member(measured, "skin"), "faults");
	bool knees = false;
	if (faults)
	{
		for (usz i = 0; i < (usz)faults.get_len(); i++)
		{
			Object* between = crig::member(faults.get_at((sz)i), "between");
			if (!between || between.get_len() != 2) continue;
			String a = between.get_string_at(0) ?? "";
			String b = between.get_string_at(1) ?? "";
			if ((a == "knee_R" || b == "knee_R") && a != b) knees = true;
		}
	}
	test::@check(knees, "no skin fault runs to the right knee");
	Object* fixes = crig::member(measured, "fixes");
	bool offered = false;
	if (fixes)
	{
		for (usz i = 0; i < (usz)fixes.get_len(); i++)
		{
			if ((fixes.get_at((sz)i).get_string("issue") ?? "") == "skin_stretch") offered = true;
		}
	}
	test::@check(offered, "no fix offered for the torn skin");
}

<*
 A small piece split between two joints far apart is a loose_shell rig issue
 with attach as its fix, and the fix clears it.
*>
fn void a_small_piece_split_between_joints_is_a_rig_issue() @test
{
	io::printn("skin check: a split small piece is a loose_shell rig issue");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	// The smallest piece the mesh has, and half its vertices given to a knee.
	crig::ShellRow[] rows = f.app.shell_rows(mem);
	defer if (rows.len > 0) alloc::free(mem, rows);
	test::@check(rows.len > 1, "the humanoid has one piece");
	if (rows.len < 2) return;
	crig::ShellRow piece = rows[^1];
	DString vertices = dstring::new(mem);
	defer vertices.free();
	usz taken = 0;
	usz seen = 0;
	foreach (usz v, shell : f.app.shells.of)
	{
		if (shell != (int)piece.shell) continue;
		if (seen++ % 2 != 0) continue;
		if (taken > 0) vertices.append_char(',');
		vertices.appendf("%d", v);
		taken++;
	}
	Object* painted = f.call_checked("paint_weights", string::tformat(`{"dot":"knee_L","weight":1,"vertices":[%s]}`, vertices.str_view()));
	if (!painted) return;
	painted.free();

	Object* scene = f.call_checked("get_scene", "{}");
	if (!scene) return;
	defer scene.free();
	Object* issues = crig::member(crig::member(scene, "rig"), "rig_issues");
	Object* loose = null;
	if (issues)
	{
		for (usz i = 0; i < (usz)issues.get_len(); i++)
		{
			Object* issue = issues.get_at((sz)i);
			if ((issue.get_string("kind") ?? "") == "loose_shell" && (issue.get_int("shell") ?? -1) == (int)piece.shell) loose = issue;
		}
	}
	test::@check(loose != null, "the split piece %d is not a loose_shell issue", piece.shell);
	if (!loose) return;
	Object* ops = crig::member(crig::member(crig::member(loose, "fix"), "args"), "ops");
	test::@check(ops != null && ops.get_len() == 1, "the loose piece's fix is not one edit_rig op");
	if (!ops || ops.get_len() != 1) return;
	Object* op = ops.get_at(0);
	test::@check((op.get_string("op") ?? "") == "attach", "the fix is %s, not attach", op.get_string("op") ?? "");
	String fix = string::tformat(`{"ops":[{"op":"attach","shell":%d,"joint":"%s"}]}`,
		op.get_int("shell") ?? -1, op.get_string("joint") ?? "");
	Object* fixed = f.call_checked("edit_rig", fix);
	if (!fixed) return;
	fixed.free();
	Object* after = f.call_checked("get_scene", "{}");
	if (!after) return;
	defer after.free();
	Object* left = crig::member(crig::member(after, "rig"), "rig_issues");
	bool still = false;
	if (left)
	{
		for (usz i = 0; i < (usz)left.get_len(); i++)
		{
			Object* issue = left.get_at((sz)i);
			if ((issue.get_string("kind") ?? "") == "loose_shell" && (issue.get_int("shell") ?? -1) == (int)piece.shell) still = true;
		}
	}
	test::@check(!still, "the attach fix left the piece loose");
}

<*
 An attach over a piece that held joints still hold part of says so, with a fix
 per joint; once those are painted off, attaching again says nothing.
*>
fn void an_attach_says_which_held_joints_still_hold_the_piece() @test
{
	io::printn("skin check: an attach names the held joints left on the piece");
	Fixture* f = mem::new(Fixture);
	defer free(f);
	if (!f.open_model(HUMANOID)) return;
	defer f.close();

	// The humanoid brings its own weights, so every joint holding a piece is held.
	crig::ShellRow[] rows = f.app.shell_rows(mem);
	defer if (rows.len > 0) alloc::free(mem, rows);
	if (rows.len < 2) return;
	usz shell = rows[^1].shell;
	Object* attached = f.call_checked("edit_rig", string::tformat(`{"ops":[{"op":"attach","shell":%d,"joint":"head_top"}]}`, shell));
	if (!attached) return;
	defer attached.free();
	Object* held = crig::member(attached, "attach_held");
	test::@check(held != null && held.get_len() > 0, "the attach did not name the held joints still on the piece");
	if (!held) return;
	for (usz i = 0; i < (usz)held.get_len(); i++)
	{
		String joint = held.get_at((sz)i).get_string("joint") ?? "";
		Object* off = f.call_checked("paint_weights", string::tformat(`{"dot":"%s","weight":0,"shell":%d}`, joint, shell));
		if (off) off.free();
	}
	Object* again = f.call_checked("edit_rig", string::tformat(`{"ops":[{"op":"attach","shell":%d,"joint":"head_top"}]}`, shell));
	if (!again) return;
	defer again.free();
	test::@check(crig::member(again, "attach_held") == null, "the attach still names held joints after they were painted off");
}

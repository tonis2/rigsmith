<*
 Re-applying a body plan's limits mends a rig whose tables were carried over
 inverted — what an older transfer left on fitted rigs, where every natural knee
 bend read as past its limit and pins and IK folded the leg the wrong way.

     `c3c test --test-noleak --test-filter crig_tests::ui::re_applying`
*>
module crig_tests::ui;

import crig;
import std::collections::object;
import std::core::test;
import std::encoding::json;
import std::io;

fn void re_applying_plan_limits_mends_an_inverted_knee() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	io::printn("an inverted knee table is put back by re-applying the plan's limits");
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");

	uint knee = 0;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == "knee_L") knee = dot.id;
	test::@check(knee != 0, "the biped has no knee_L");
	if (knee == 0) return;
	crig::JointRotationLimits fitted = f.app.doc.rotation_limits_of(knee);
	test::@check(fitted.constrained && fitted.axes[0].maximum > 1.0f, "the fitted knee does not fold forward");

	crig::JointRotationLimits inverted = fitted;
	inverted.axes[0] = { .allowed = true, .minimum = -fitted.axes[0].maximum, .maximum = -fitted.axes[0].minimum };
	test::@check(f.app.set_rotation_limits_recorded(knee, inverted), "the inverted table did not land");
	f.app.undo_stack.commit();

	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.reapply_plan_limits() > 0, "nothing was re-applied");
	crig::JointRotationLimits mended = f.app.doc.rotation_limits_of(knee);
	test::@check(mended.axes[0].minimum == fitted.axes[0].minimum && mended.axes[0].maximum == fitted.axes[0].maximum,
		"the knee is [%f, %f], not the plan's [%f, %f]",
		mended.axes[0].minimum, mended.axes[0].maximum, fitted.axes[0].minimum, fitted.axes[0].maximum);
	test::@check(f.app.undo_stack.cursor > cursor, "the re-apply was not recorded");
	test::@check(f.app.undo(), "the re-apply did not undo");
	test::@check(f.app.doc.rotation_limits_of(knee).axes[0].maximum == inverted.axes[0].maximum, "undo did not restore the old table");
}

// How many hinges of the fixture's rig refuse their fold, as get_scene reports them.
fn usz refused_hinges(Fixture* f, crig::HingeIssue[] into)
{
	crig::RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	return crig::hinge_issues(&f.app.doc, &view.skeleton, view.names, view.dot_ids, into);
}

<*
 A knee whose table folds it backward is a fault of the rig, named before any
 clip is measured — and put right from its own rows, with no plan to read from.
*>
fn void an_inverted_knee_is_named_and_mended_from_its_own_rows() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	io::printn("an inverted knee is a rig issue, and its own rows mend it");
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");

	crig::HingeIssue[16] found;
	usz count = refused_hinges(&f, found[..]);
	test::@check(count == 0, "a fitted biped refuses %d hinges, the first %s", count, count > 0 ? found[0].joint : "");

	uint knee = 0;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == "knee_L") knee = dot.id;
	if (knee == 0) { test::@check(false, "the biped has no knee_L"); return; }
	crig::JointRotationLimits fitted = f.app.doc.rotation_limits_of(knee);
	crig::JointRotationLimits inverted = fitted;
	inverted.axes[0] = { .allowed = true, .minimum = -fitted.axes[0].maximum, .maximum = -fitted.axes[0].minimum };
	test::@check(f.app.doc.set_rotation_limits(knee, inverted), "the inverted table did not land");

	count = refused_hinges(&f, found[..]);
	test::@check(count == 1, "the inverted knee is %d issues", count);
	if (count != 1) return;
	test::@check(found[0].joint == "knee_L" && found[0].kind == INVERTED, "%s is reported, not the inverted knee_L", found[0].joint);

	String scene = crig::scene_json(&f.app);
	defer scene.free(mem);
	test::@check(scene.contains(`"kind":"limits_inverted","joint":"knee_L"`), "get_scene does not name it");

	// With no plan to read limits from, the joint's own rows put it right.
	test::@check(f.app.mend_hinge_limits() == 1, "the knee was not mended");
	crig::JointRotationLimits mended = f.app.doc.rotation_limits_of(knee);
	test::@check(mended.axes[0].minimum == fitted.axes[0].minimum && mended.axes[0].maximum == fitted.axes[0].maximum,
		"the knee is [%f, %f], not [%f, %f]", mended.axes[0].minimum, mended.axes[0].maximum,
		fitted.axes[0].minimum, fitted.axes[0].maximum);
	test::@check(refused_hinges(&f, found[..]) == 0, "the mended rig still refuses a hinge");
}

<*
 A toe table read a quarter turn round — it may turn sideways and not bend — is
 blocked, and trading its swing rows mends it.
*>
fn void a_toe_that_cannot_bend_is_mended_by_trading_its_rows() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	io::printn("a toe whose rows are traded is put back");
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");

	uint toe = 0;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == "toe_L") toe = dot.id;
	if (toe == 0) { test::@check(false, "the biped has no toe_L"); return; }
	crig::JointRotationLimits fitted = f.app.doc.rotation_limits_of(toe);
	if (!fitted.constrained) { test::@check(false, "the biped's toe has no limits"); return; }
	crig::JointRotationLimits traded = fitted;
	traded.axes[0] = fitted.axes[2];
	traded.axes[2] = fitted.axes[0];
	test::@check(f.app.doc.set_rotation_limits(toe, traded), "the traded table did not land");

	crig::HingeIssue[16] found;
	usz count = refused_hinges(&f, found[..]);
	test::@check(count == 1 && found[0].joint == "toe_L" && found[0].kind == BLOCKED, "the traded toe is not reported blocked");
	test::@check(f.app.mend_hinge_limits() == 1, "the toe was not mended");
	test::@check(refused_hinges(&f, found[..]) == 0, "the mended toe still cannot bend");
}

fn uint named_dot(Fixture* f, String name)
{
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name == name) return dot.id;
	return 0;
}

fn bool rig_edit(Fixture* f, String text)
{
	Object*? args = json::parse(mem, text);
	if (catch args) return false;
	defer args.free();
	DString detail = dstring::new(mem);
	defer detail.free();
	String? out = crig::edit_rig(&f.app, args, &detail);
	if (catch out)
	{
		test::@check(false, "edit_rig refused: %s", detail.str_view());
		return false;
	}
	out.free(mem);
	return true;
}

<*
 plan_limits with joints re-plans only those tables: a limit taken off the neck
 on purpose stays off, where plan_limits over the whole rig puts it back.

 Re-introduce: ignore the op's `joints` (call `reapply_plan_limits` with no
 mask), and the neck's table comes back.
*>
fn void plan_limits_with_joints_leaves_the_rest_of_the_rig_alone() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	io::printn("plan_limits joints re-plans only the joints named");
	test::@check(f.app.apply_plan_named("biped"), "could not fit rig");
	uint neck = named_dot(&f, "neck");
	uint knee = named_dot(&f, "knee_L");
	test::@check(neck != 0 && knee != 0, "the biped has no neck or knee_L");
	if (neck == 0 || knee == 0) return;
	test::@check(f.app.doc.rotation_limits_of(neck).constrained, "the fitted neck has no limits to take off");

	if (!rig_edit(&f, `{"ops":[{"op":"limits","joint":"neck","reset":true},{"op":"limits","joint":"knee_L","reset":true}]}`)) return;
	test::@check(!f.app.doc.rotation_limits_of(neck).constrained, "the neck's limits did not come off");

	if (!rig_edit(&f, `{"ops":[{"op":"plan_limits","joints":["knee_L"]}]}`)) return;
	test::@check(f.app.doc.rotation_limits_of(knee).constrained, "the named knee was not re-planned");
	test::@check(!f.app.doc.rotation_limits_of(neck).constrained, "plan_limits put back a limit it was not asked about");

	if (!rig_edit(&f, `{"ops":[{"op":"plan_limits"}]}`)) return;
	test::@check(f.app.doc.rotation_limits_of(neck).constrained, "plan_limits over the whole rig should re-plan the neck");
}

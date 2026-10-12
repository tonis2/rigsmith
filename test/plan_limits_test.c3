<*
 Re-applying a body plan's limits mends a rig whose tables were carried over
 inverted — what an older transfer left on fitted rigs, where every natural knee
 bend read as past its limit and pins and IK folded the leg the wrong way.

     `c3c test --test-noleak --test-filter crig_tests::ui::re_applying`
*>
module crig_tests::ui;

import crig;
import std::core::test;
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

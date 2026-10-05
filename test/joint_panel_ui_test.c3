module crig_tests::ui;

import crig;
import cui;
import cui::widgets;
import rig;
import std::core::test;
import std::math;

struct JointPanelRig
{
	uint root;
	uint joint;
	uint tip;
}

fn JointPanelRig joint_panel_rig(Fixture* f)
{
	JointPanelRig out;
	out.root = f.app.doc.add_dot({ 0, -0.5f, 0 }, "root");
	out.joint = f.app.doc.add_dot({ 0, 0, 0 }, "knee");
	out.tip = f.app.doc.add_dot({ 0.4f, 0.5f, 0.2f }, "foot");
	f.app.doc.connect(out.root, out.joint);
	f.app.doc.connect(out.joint, out.tip);
	f.app.mark_rig_stale();
	return out;
}

fn void submit_joint_field(Fixture* f, String id, String value)
{
	Element* field = f.ui.find_id(id)!!;
	field.widget_as(TextField).set_text(field, value);
	field.request_focus();
	f.feed_key(Key.RETURN);
	f.ui.flush();
}

fn crig::JointLimitFrame panel_frame(Fixture* f, uint id)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	return crig::joint_limit_frame(&view.skeleton, view.dot_ids,
		f.app.doc.rotation_limits_of(id));
}

fn void selected_joint_panel_edits_pose_and_limits_as_separate_undo_steps() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	JointPanelRig made = joint_panel_rig(&f);

	test::@check(!f.in_tree(crig::JOINT_ROTATION_X_ID),
		"rotation fields appeared without a selected joint");
	f.app.select(made.joint);
	f.feed({ 0, 0 });
	test::@check(!f.in_tree(crig::JOINT_ROTATION_X_ID)
		&& f.in_tree(crig::JOINT_LIMITS_ACTIVE_ID),
		"rest-rig selection exposed pose fields or hid joint limits");

	// Limits are a separate rig edit. Turning them on reveals only the small
	// per-axis table; changing a row never touches pose data.
	f.click(f.center_of(crig::JOINT_LIMITS_ACTIVE_ID)!!);
	f.ui.flush();
	test::@check(f.app.doc.rotation_limits_of(made.joint).constrained,
		"Limit rotation did not enable the table");
	test::@check(f.in_tree(crig::JOINT_LIMIT_X_MIN_ID)
		&& f.in_tree(crig::JOINT_LIMIT_X_MAX_ID), "enabled limits did not reveal ranges");
	submit_joint_field(&f, crig::JOINT_LIMIT_X_MIN_ID, "-5");
	submit_joint_field(&f, crig::JOINT_LIMIT_X_MAX_ID, "145");
	f.click(f.center_of(crig::JOINT_LIMIT_Y_ALLOW_ID)!!);
	f.ui.flush();
	test::@check(!f.in_tree(crig::JOINT_LIMIT_Y_MIN_ID) && !f.in_tree(crig::JOINT_LIMIT_Y_MAX_ID),
		"a locked Y still showed editable range fields");

	// A locked axis reads "Locked" in both value cells with no field to type — its
	// held angle is not authored on the card. Set a non-rest hold on the document
	// directly, so the numeric-pose check below still proves the pose path honors it.
	crig::JointRotationLimits held = f.app.doc.rotation_limits_of(made.joint);
	held.axes[1].locked = 3.0f * (float)math::PI / 180.0f;
	test::@check(f.app.set_rotation_limits_recorded(made.joint, held), "could not set the locked Y angle");
	f.app.undo_stack.commit();
	f.app.refresh_ui();
	f.feed({ 0, 0 });

	crig::JointRotationLimits limits = f.app.doc.rotation_limits_of(made.joint);
	test::@check(math::abs(limits.axes[0].minimum * 180.0f / (float)math::PI + 5.0f) < 0.01f
		&& math::abs(limits.axes[0].maximum * 180.0f / (float)math::PI - 145.0f) < 0.01f,
		"the X range did not retain the entered degrees");
	test::@check(!limits.axes[1].allowed
		&& math::abs(limits.axes[1].locked * 180.0f / (float)math::PI - 3.0f) < 0.01f,
		"the locked Y value did not retain the entered degrees");
	test::@check(!f.app.pose_edit_active, "editing rig limits also opened an animation draft");

	// Pose fields appear only once an animation is selected, and only for the
	// axes the joint may turn about: locked Y has no field, since its one angle
	// is the table's. The numeric path still consumes the table — posing X
	// leaves Y at its locked 3 degrees.
	AnimRef clip = f.app.new_clip("Limited numeric", 2.0f, from_rest: true);
	f.app.edit_time = 1.0f;
	test::@check(f.app.park_clip(clip, f.app.edit_time), "the animation would not park");
	f.app.refresh_ui();
	f.feed({ 0, 0 });
	test::@check(f.in_tree(crig::JOINT_ROTATION_X_ID) && f.in_tree(crig::JOINT_ROTATION_Z_ID),
		"selecting an animation did not reveal the pose fields");
	test::@check(!f.in_tree(crig::JOINT_ROTATION_Y_ID),
		"a locked axis was offered a pose field");
	submit_joint_field(&f, crig::JOINT_ROTATION_X_ID, "40");
	crig::JointLimitFrame frame = panel_frame(&f, made.joint);
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose sampled = f.app.evaluated_clip_pose(mem, &view, *f.app.clip(f.app.editing),
		f.app.editing, f.app.edit_time, false);
	defer sampled.free(mem);
	sz joint = view.joint_of(made.joint);
	Vec3 shown = crig::joint_angles_from_rotation(frame, sampled.rotations[(usz)joint]);
	test::@check(math::abs(shown.x * 180.0f / (float)math::PI - 40.0f) < 0.01f,
		"the typed X did not land (%.3f degrees)", shown.x * 180.0f / (float)math::PI);
	test::@check(math::abs(shown.y * 180.0f / (float)math::PI - 3.0f) < 0.01f,
		"numeric posing crossed a locked axis (%.3f degrees)",
		shown.y * 180.0f / (float)math::PI);
}

fn void joint_panel_numeric_rotation_follows_auto_key() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	JointPanelRig made = joint_panel_rig(&f);
	AnimRef clip = f.app.new_clip("Numeric", 2.0f);
	f.app.editing = clip;
	f.app.edit_time = 1.0f;
	test::@check(f.app.park_clip(clip, 1.0f), "the clip could not be parked for editing");
	f.app.stop_animation();
	f.app.select(made.joint);
	f.feed({ 0, 0 });

	sz keys = f.app.clip(clip).keyframes.len;
	submit_joint_field(&f, crig::JOINT_ROTATION_Z_ID, "30");
	test::eq(f.app.clip(f.app.editing).keyframes.len, keys + 1);
	test::@check(!f.app.pose_edit_pending && !f.app.pose_edit_active,
		"default Auto-key left a numeric pose as an unsaved draft");

	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose sampled = f.app.clip(f.app.editing).pose(mem, &view.skeleton,
		f.app.names_for(&view, f.app.editing), 1.0f, false);
	defer sampled.free(mem);
	sz joint = view.joint_of(made.joint);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton,
		view.dot_ids, f.app.doc.rotation_limits_of(made.joint));
	Vec3 shown = crig::joint_angles_from_rotation(frame, sampled.rotations[(usz)joint]);
	test::@check(math::abs(shown.z * 180.0f / (float)math::PI - 30.0f) < 0.01f,
		"the keyed numeric rotation sampled as %.3f degrees",
		shown.z * 180.0f / (float)math::PI);

	keys = f.app.clip(f.app.editing).keyframes.len;
	f.click(f.center_of(crig::JOINT_LIMITS_ACTIVE_ID)!!);
	f.ui.flush();
	test::eq(f.app.clip(f.app.editing).keyframes.len, keys);
}

fn void branching_joint_panel_asks_which_child_defines_its_axes() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	JointPanelRig made = joint_panel_rig(&f);
	uint branch = f.app.doc.add_dot({ -0.5f, 0.4f, 0 }, "other child");
	f.app.doc.connect(made.joint, branch);
	f.app.mark_rig_stale();
	f.app.select(made.joint);
	f.feed({ 0, 0 });

	test::@check(f.in_tree(crig::JOINT_PRIMARY_CHILD_ID),
		"a branch did not offer a bone-axis child choice");
	test::@check(!f.in_tree(crig::JOINT_ROTATION_X_ID),
		"a branch invented local axes before a child was chosen");
}

<*
 The Joint card's dials turn the selected joint one bone-local axis at a time,
 and nothing is drawn around the joint to do it.

 These are the rings that used to sit on the model, moved to the card so a
 wrist or a head is not hidden under its own control while it turns. The rules
 are the rings': a locked axis has no control at all, an allowed span clamps,
 one drag is one pose edit, and Escape mid-drag puts the joint back. What is
 new is that the card must hold still for the drag — a rebuild would take the
 pressed dial, and the pointer with it — while the degree field under the dial
 keeps up by hand.
*>
fn void the_joint_card_dials_turn_the_selected_joint_one_axis_at_a_time() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	JointPanelRig made = joint_panel_rig(&f);

	crig::JointRotationLimits limits = crig::unconstrained_rotation(made.joint);
	limits.constrained = true;
	limits.axes[0] = { .allowed = true, .minimum = -0.5f, .maximum = 0.5f };
	limits.axes[1].allowed = false;
	limits.axes[2].allowed = false;
	test::@check(f.app.doc.set_rotation_limits(made.joint, limits),
		"the test limit table was refused");
	AnimRef clip = f.app.new_clip("Dials", 2.0f, from_rest: true);
	f.app.edit_time = 1.0f;
	test::@check(f.app.park_clip(clip, f.app.edit_time), "the animation would not park");
	f.app.stop_animation();
	f.app.select(made.joint);
	f.feed({ 0, 0 });

	Element*? found = f.ui.find_id(crig::JOINT_DIALS_ID);
	if (catch found)
	{
		test::@check(false, "selecting a joint on a parked animation did not put the dials on its card");
		return;
	}
	Element* dials = found;

	// Locked Y and Z have no dial and no field: one column, and it is X.
	crig::JointDials* widget = dials.widget_as(crig::JointDials);
	test::@check(widget.count == 1 && widget.axes[0] == crig::JointRotationAxis.X,
		"the card built %d dials for a joint with one allowed axis", widget.count);
	test::@check(f.in_tree(crig::JOINT_ROTATION_X_ID) && !f.in_tree(crig::JOINT_ROTATION_Y_ID)
		&& !f.in_tree(crig::JOINT_ROTATION_Z_ID),
		"locked axes kept their degree fields");
	Vec2 off_end = dials.absolute + crig::dial_centre(dials, 1);
	f.feed(off_end);
	f.feed(off_end, left: true);
	test::@check(f.app.drag.dot == 0, "pressing where a locked axis's dial would be began a turn");
	f.feed(off_end);

	// The X dial: grab the bead at zero, sweep it 0.3 rad, and the joint follows.
	Vec2 x_centre = crig::dial_centre(dials, 0);
	Vec2 press = dials.absolute + crig::dial_point(x_centre, 0.0f);
	f.feed(press);
	f.feed(press, left: true);
	test::@check(f.app.pose_edit_active && f.app.drag.dot == made.joint
		&& f.app.drag.verb == crig::DragVerb.TURN && f.app.drag.held && f.app.drag.dial,
		"pressing the X dial did not begin a held dial turn");
	test::@check(f.app.drag.anchor.y < 0.0f,
		"a dial turn anchored the viewport's sweep (%s)", f.app.drag.anchor);

	float turn = 0.3f;
	Vec2 moved = dials.absolute + crig::dial_point(x_centre, turn);
	sz history = f.app.undo_stack.cursor;
	f.feed(moved, left: true);
	// Still the same dial under the hand: the card did not rebuild.
	Element* still = f.ui.find_id(crig::JOINT_DIALS_ID)!!;
	test::@check(still == dials && still.widget_as(crig::JointDials).held == 1,
		"the card rebuilt under the dial drag and let go of the dial");
	test::@check(f.app.drag.dot == made.joint, "the first move ended the dial turn");

	crig::JointLimitFrame frame = panel_frame(&f, made.joint);
	Vec3 live = crig::joint_angles_from_rotation(frame, f.app.working_pose(made.joint).rotation);
	test::@check(math::abs(live.x - turn) < 0.02f && math::abs(live.y) < 1.0e-4f && math::abs(live.z) < 1.0e-4f,
		"the X dial turned the joint to (%.3f, %.3f, %.3f), not %.3f about X alone",
		live.x, live.y, live.z, turn);
	Element* x_field = f.ui.find_id(crig::JOINT_ROTATION_X_ID)!!;
	test::@check(x_field.widget_as(TextField).value() == "17.2",
		"the X field did not keep up with the dial (%s)", x_field.widget_as(TextField).value());

	f.feed(moved);
	test::@check(f.app.drag.dot == 0 && f.app.undo_stack.cursor == history + 1,
		"one dial drag did not finish as one pose edit (drag %d, history %d -> %d)",
		f.app.drag.dot, history, f.app.undo_stack.cursor);
	{
		RigView view = f.app.open_rig(mem)!!;
		defer view.free(mem);
		rig::Pose sampled = f.app.clip(f.app.editing).pose(mem, &view.skeleton,
			f.app.names_for(&view, f.app.editing), f.app.edit_time, false);
		defer sampled.free(mem);
		sz joint = view.joint_of(made.joint);
		Vec3 keyed = crig::joint_angles_from_rotation(frame, sampled.rotations[(usz)joint]);
		test::@check(math::abs(keyed.x - turn) < 0.02f,
			"the dial's turn was keyed as %.3f, not %.3f", keyed.x, turn);
	}

	// Past the limit the bead stops at the mark: a sweep to 1.2 rad lands on 0.5.
	f.feed({ 0, 0 });
	dials = f.ui.find_id(crig::JOINT_DIALS_ID)!!;
	press = dials.absolute + crig::dial_point(x_centre, turn);
	f.feed(press);
	f.feed(press, left: true);
	test::@check(f.app.drag.dial, "the second dial press did not begin a turn");
	f.feed(dials.absolute + crig::dial_point(x_centre, 0.8f), left: true);
	f.feed(dials.absolute + crig::dial_point(x_centre, 1.2f), left: true);
	live = crig::joint_angles_from_rotation(frame, f.app.working_pose(made.joint).rotation);
	test::@check(math::abs(live.x - 0.5f) < 0.02f,
		"sweeping past the X limit reached %.3f rather than stopping at 0.5", live.x);
	f.feed(dials.absolute + crig::dial_point(x_centre, 1.2f));
	test::@check(f.app.drag.dot == 0, "releasing the second dial drag left it active");

	// Escape mid-drag cancels: the joint goes back to where the press found it
	// and nothing is recorded.
	f.feed({ 0, 0 });
	dials = f.ui.find_id(crig::JOINT_DIALS_ID)!!;
	history = f.app.undo_stack.cursor;
	press = dials.absolute + crig::dial_point(x_centre, 0.5f);
	f.feed(press);
	f.feed(press, left: true);
	test::@check(f.app.drag.dial, "the third dial press did not begin a turn");
	f.feed(dials.absolute + crig::dial_point(x_centre, 0.2f), left: true);
	Key[1] escape = { Key.ESCAPE };
	f.feed(dials.absolute + crig::dial_point(x_centre, 0.2f), left: true, keys: escape[..]);
	test::@check(f.app.drag.dot == 0, "Escape did not cancel the dial turn");
	f.feed(dials.absolute + crig::dial_point(x_centre, 0.1f), left: true);
	f.feed(dials.absolute + crig::dial_point(x_centre, 0.1f));
	live = crig::joint_angles_from_rotation(frame, f.app.working_pose(made.joint).rotation);
	test::@check(math::abs(live.x - 0.5f) < 0.02f && f.app.undo_stack.cursor == history,
		"a cancelled dial drag left the joint at %.3f (history %d -> %d)",
		live.x, history, f.app.undo_stack.cursor);

	// Lock the last axis and the pose row has nothing to offer: no dials, no
	// fields, and the limits table is where the joint's angles now live.
	f.click(f.center_of(crig::JOINT_LIMIT_X_ALLOW_ID)!!);
	f.ui.flush();
	test::@check(!f.app.doc.rotation_limits_of(made.joint).axes[0].allowed, "the X row did not lock");
	test::@check(!f.in_tree(crig::JOINT_DIALS_ID) && !f.in_tree(crig::JOINT_ROTATION_X_ID),
		"a joint with every axis locked still offered dials or fields");
	test::@check(f.in_tree(crig::JOINT_LIMIT_X_ALLOW_ID), "and lost the table that holds its angles");
}

fn void temporary_plane_and_bone_shortcuts_do_not_author_joint_limits() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	JointPanelRig made = joint_panel_rig(&f);
	f.app.select(made.joint);
	f.app.begin_drag(made.joint);

	f.chord(f.viewport.absolute + f.viewport.size * 0.5f, Key.LEFT_SHIFT, Key.X);
	test::@check(f.app.drag.axis == crig::DragAxis.YZ,
		"Shift+X did not select the YZ movement plane");
	f.tap(f.viewport.absolute + f.viewport.size * 0.5f, Key.B);
	test::@check(f.app.drag.axis == crig::DragAxis.BONE
		&& f.app.drag.lock_direction.length_sq() > 0.99f,
		"B did not select a stable bone-direction lock");
	test::@check(!f.app.doc.rotation_limits_of(made.joint).constrained
		&& f.app.doc.rotation_limits.len() == 0,
		"a temporary gesture lock authored a persistent joint limit");
	f.app.cancel_drag();
}

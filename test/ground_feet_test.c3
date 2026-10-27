<*
 Contacts on a generated-looking walk: the feet sink through the floor as keyed,
 and one Add contact or a Find contacts has to put them on it without the body
 bouncing. Add contact plants the step the playhead is in, on the foot's top
 joint; Find contacts plants every step of every foot; and with one foot
 declared the other is still kept out of the floor.
*>
module crig_tests::ui;
import crig;
import rig;
import std::core::test;
import std::math;

// A biped stepping in place: each thigh swings forward for half the cycle while
// the other leg stands, and the hips are keyed low enough to bury the feet.
fn AnimTemplate stepping_clip(bool generated = false)
{
	const usz KEYS = 8;
	float[KEYS] swing = { 0.0f, 0.0f, 0.0f, 0.0f, 0.3f, 0.6f, 0.3f, 0.0f };
	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, KEYS);
	foreach (usz i, &frame : frames)
	{
		float left = swing[i];
		float right = swing[(i + KEYS / 2) % KEYS];
		// Each ankle turned back by its thigh's swing, so the foot lifts level.
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, 5);
		// Generated: the hips bob with the keys, and each swing points its toes down
		// through the floor instead of lifting the foot level.
		float bob = generated ? 0.02f * math::cos((float)i / (float)KEYS * 4.0f * (float)math::PI) : 0.0f;
		float toes = generated ? 0.0f : -1.0f;
		dots[0] = { .joint_name = "hips".copy(mem), .channels = TRANSLATION, .move = { 0, -0.05f + bob, 0 } };
		dots[1] = { .joint_name = "thigh_L".copy(mem), .channels = ROTATION, .axis = { 1, 0, 0 }, .angle = left };
		dots[2] = { .joint_name = "ankle_L".copy(mem), .channels = ROTATION, .axis = { 1, 0, 0 }, .angle = toes * left };
		dots[3] = { .joint_name = "thigh_R".copy(mem), .channels = ROTATION, .axis = { 1, 0, 0 }, .angle = right };
		dots[4] = { .joint_name = "ankle_R".copy(mem), .channels = ROTATION, .axis = { 1, 0, 0 }, .angle = toes * right };
		*frame = { .time = (float)i / (float)KEYS, .dots = dots };
	}
	return { .name = "Steps".copy(mem), .duration = 1.0f, .loop = true, .keyframes = frames, .owned = true };
}

fn void stepping_workspace(Fixture* f, bool generated = false)
{
	test::@check(f.app.apply_plan_named("biped"), "could not fit a rig");
	test::@check(f.app.has_dot_named("thigh_L") && f.app.has_dot_named("toe_L"), "the biped has no thigh_L or toe_L");
	f.app.editing = f.app.author_clip(stepping_clip(generated));
	test::@check(f.app.editing.valid(), "the stepping clip did not land");
	f.app.show_edited();
}

// The name of the top of the foot `joint` is part of, on this rig.
fn String foot_top_name(Fixture* f, String joint)
{
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	String[] names = f.app.names_for(&view, f.app.editing);
	GroundFloor level = crig::floor_of_solve(&view.skeleton, {}, 0.0f, false);
	foreach (usz j, name : names)
	{
		if (name == joint) return names[level.foot_of(&view.skeleton, j)].tcopy();
	}
	return "";
}

// The windows of `joint` that hold `phase`.
fn usz windows_holding(AnimGround ground, String joint, float phase)
{
	usz count = 0;
	foreach (foot : ground.feet) if (foot.joint == joint && foot.planted(phase)) count++;
	return count;
}

fn void add_contact_plants_the_step_under_the_playhead() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	stepping_workspace(&f);
	AnimRef ref = f.app.editing;
	String ankle = foot_top_name(&f, "toe_L");
	test::@check(ankle.len > 0 && ankle != "toe_L", "toe_L has no foot above it (%s)", ankle);

	f.app.selected = f.app.dot_named("toe_L").id;
	f.app.edit_time = 0.25f;
	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.add_contact_for_selected(ref), "Add contact refused");
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimGround ground = f.app.clip(ref).ground;
	test::eq(ground.feet.len, (sz)1);
	if (ground.feet.len != 1) return;
	AnimFoot window = ground.feet[0];
	test::@check(window.joint == ankle, "the contact went on %s, not the foot's top %s", window.joint, ankle);
	test::@check(window.planted(0.25f) && window.planted(0.1f) && window.planted(0.4f),
		"the window %f–%f does not cover the standing half", window.down, window.up);
	test::@check(!window.planted(0.7f), "the window %f–%f runs into the swing", window.down, window.up);

	// It is the step the motion shows, not a quarter from the playhead.
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	String[1] asked = { ankle };
	AnimGround runs = f.app.contact_runs(ref, &view, asked[..]);
	defer runs.free(mem);
	bool same = false;
	foreach (run : runs.feet)
	{
		if (math::abs(run.down - window.down) < 1e-4f && math::abs(run.up - window.up) < 1e-4f) same = true;
	}
	test::@check(same, "the window %f–%f is not one of the foot's steps", window.down, window.up);
}

fn void find_contacts_plants_every_step_of_both_feet() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	stepping_workspace(&f);
	AnimRef ref = f.app.editing;
	String left = foot_top_name(&f, "toe_L");
	String right = foot_top_name(&f, "toe_R");

	sz history = f.app.undo_stack.cursor;
	test::@check(f.app.find_contacts(ref), "Find contacts refused");
	test::eq(f.app.undo_stack.cursor, history + 1);
	AnimGround ground = f.app.clip(ref).ground;
	test::eq(crig::contact_lane_count(ground), (usz)2);
	test::@check(windows_holding(ground, left, 0.25f) == 1 && windows_holding(ground, left, 0.7f) == 0,
		"the left foot's windows do not follow its steps");
	test::@check(windows_holding(ground, right, 0.7f) == 1 && windows_holding(ground, right, 0.2f) == 0,
		"the right foot's windows do not follow its steps");
	test::@check(f.app.undo(), "Find contacts did not undo");
	test::@check(!f.app.clip(ref).ground.solves(), "the undo left contacts behind");
}

<*
 The bounce a single Add contact left: one foot declared, the hips keyed low. The
 body holds one height through the cycle, and no joint of either foot goes below
 where it stood at rest.
*>
fn void one_contact_keeps_the_body_level_and_both_feet_out_of_the_floor() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	stepping_workspace(&f);
	AnimRef ref = f.app.editing;
	f.app.selected = f.app.dot_named("toe_L").id;
	f.app.edit_time = 0.25f;
	test::@check(f.app.add_contact_for_selected(ref), "Add contact refused");

	float bob;
	float sunk;
	measure_grounded(&f, &bob, &sunk);
	test::@check(bob < 0.01f, "the body bounced %.4f heights", bob);
	test::@check(sunk < 1.0e-3f, "a foot went %.4f heights through the floor", sunk);
}

<*
 A generated walk: the keys bob the hips, and each swing points its toes down
 through the floor. Find contacts still reads each stance, and the floor solve
 turns the toes up rather than lifting the body a hop a step.
*>
fn void a_generated_walk_with_toes_through_the_floor_does_not_hop() @test
{
	Fixture f;
	f.open()!!;
	defer f.close();
	stepping_workspace(&f, generated: true);
	AnimRef ref = f.app.editing;
	test::@check(f.app.find_contacts(ref), "Find contacts refused");
	AnimGround ground = f.app.clip(ref).ground;
	String left = foot_top_name(&f, "toe_L");
	String right = foot_top_name(&f, "toe_R");
	test::@check(windows_holding(ground, left, 0.25f) == 1 && windows_holding(ground, left, 0.7f) == 0,
		"the left foot's windows do not follow its steps");
	test::@check(windows_holding(ground, right, 0.7f) == 1 && windows_holding(ground, right, 0.2f) == 0,
		"the right foot's windows do not follow its steps");
	float bob;
	float sunk;
	measure_grounded(&f, &bob, &sunk);
	test::@check(bob < 0.01f, "the body hopped %.4f heights", bob);
	test::@check(sunk < 1.0e-3f, "a foot went %.4f heights through the floor", sunk);
}

<*
 The edited clip as it plays, over a cycle: how far the root's height ranges and
 the deepest any joint of a foot goes below where it stood at rest, as fractions
 of the rig's height.
*>
fn void measure_grounded(Fixture* f, float* bob, float* sunk)
{
	AnimRef ref = f.app.editing;
	RigView view = f.app.open_rig(mem)!!;
	defer view.free(mem);
	float height = view.skeleton.height();
	GroundFloor level = crig::floor_of_solve(&view.skeleton, {}, 0.0f, false);
	usz root = 0;
	while (view.skeleton.parents[root] >= 0) root = (usz)view.skeleton.parents[root];
	AnimTemplate clip = *f.app.clip(ref);
	float low = 1.0e30f;
	float high = -1.0e30f;
	float deepest = 0.0f;
	for (usz s = 0; s < 48; s++)
	{
		rig::Pose pose = f.app.evaluated_clip_pose(mem, &view, clip, ref, (float)s / 48.0f);
		defer pose.free(mem);
		low = math::min(low, pose.offsets[root].y);
		high = math::max(high, pose.offsets[root].y);
		Matrix4f[] palette = rig::joint_palette(mem, &view.skeleton, pose)!!;
		defer alloc::free(mem, palette);
		for (usz j = 0; j < view.skeleton.len(); j++)
		{
			if (!level.rests_low(&view.skeleton, j)) continue;
			deepest = math::max(deepest, view.skeleton.joints[j].y - view.skeleton.joints[j].transform(palette[j]).y);
		}
	}
	*bob = (high - low) / height;
	*sunk = deepest / height;
}


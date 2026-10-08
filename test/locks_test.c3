<*
 Position locks: the anchor that lets a figure sit.

 A rig shaped like a person from the waist down — hips forking to a spine and two
 legs — is enough to show the whole feature: lock the feet, pull the hips or the
 spine down, and the legs fold to keep the feet where they were pinned. The mesh
 is the shared cube and is never asserted on; every position read is
 `dot_position`, the posed point the overlay and the solver share.
*>
module crig_tests::locks;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

struct Sitter
{
	crig::AppState app;
	uint hips;
	uint spine;
	uint upper_spine;
	uint thigh_l;
	uint knee_l;
	uint ankle_l;
	uint thigh_r;
	uint knee_r;
	uint ankle_r;
}

<*
 hips (root — forks to spine and the two legs)
   spine → upper_spine
   thigh_L → knee_L → ankle_L
   thigh_R → knee_R → ankle_R

 The fork at the hips is the point: an ankle's limb is knee and thigh hanging
 there, the spine rides the hips (a pull on it carries the body), and
 `upper_spine` is the waist a user grabs to sit the figure down.

 The legs are **perfectly straight**, the T-pose, and the knees are hinges — one
 axis, 0..150 degrees, the way a preset fits them. A straight limb pulled along
 its own length is the case the whole-body solve has to fold; the knee's one-way
 range is what says which way.
*>
fn bool Sitter.open(&self, float knee_z = 0.0f)
{
	self.app = shared_app::open_cube();
	shared_app::attach_library(&self.app);

	self.hips = self.app.doc.add_dot({ 0, 1.0, 0 }, "hips");
	self.spine = self.app.doc.add_dot({ 0, 1.2, 0 }, "spine");
	self.upper_spine = self.app.doc.add_dot({ 0, 1.4, 0 }, "upper_spine");
	self.thigh_l = self.app.doc.add_dot({ 0.15, 1.0, 0 }, "thigh_L");
	self.knee_l = self.app.doc.add_dot({ 0.15, 0.5, knee_z }, "knee_L");
	self.ankle_l = self.app.doc.add_dot({ 0.15, 0.0, 0 }, "ankle_L");
	self.thigh_r = self.app.doc.add_dot({ -0.15, 1.0, 0 }, "thigh_R");
	self.knee_r = self.app.doc.add_dot({ -0.15, 0.5, knee_z }, "knee_R");
	self.ankle_r = self.app.doc.add_dot({ -0.15, 0.0, 0 }, "ankle_R");

	self.app.doc.connect(self.hips, self.spine);
	self.app.doc.connect(self.spine, self.upper_spine);
	self.app.doc.connect(self.hips, self.thigh_l);
	self.app.doc.connect(self.thigh_l, self.knee_l);
	self.app.doc.connect(self.knee_l, self.ankle_l);
	self.app.doc.connect(self.hips, self.thigh_r);
	self.app.doc.connect(self.thigh_r, self.knee_r);
	self.app.doc.connect(self.knee_r, self.ankle_r);
	self.app.doc.root_id = self.hips;

	// A hinge knee: bone-local +Y runs down the shin, so the frame's X is world X
	// and a positive X turn swings the shin back — the one way a knee bends.
	foreach (knee : (uint[2]){ self.knee_l, self.knee_r })
	{
		crig::JointRotationLimits hinge = crig::unconstrained_rotation(knee);
		hinge.constrained = true;
		hinge.axes[0] = { .allowed = true, .minimum = 0.0f, .maximum = 2.618f };
		hinge.axes[1] = { .allowed = false, .minimum = -(float)math::PI, .maximum = (float)math::PI };
		hinge.axes[2] = { .allowed = false, .minimum = -(float)math::PI, .maximum = (float)math::PI };
		if (!self.app.doc.set_rotation_limits(knee, hinge)) return false;
	}

	crig::AnimRef clip = self.app.new_clip("sit", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.0f;
	return true;
}

fn void Sitter.close(&self) => self.app.free();

// Where a joint stands on screen right now — the posed point, the feature's own
// unit of "where the foot is".
fn Vec3 Sitter.at(&self, uint id) => self.app.dot_position(*self.app.doc.find(id));

// How far a rotation is from rest, 0 for identity and rising with the bend. The
// identity quaternion is {0,0,0,1}, so the scalar w alone measures it: a unit
// quaternion has |w| = cos(half-angle), 1 at rest and falling as the joint turns.
fn float bend_of(Quaternionf q) @local => 1.0f - math::abs(q.v.w);

// The angle of a rotation, in degrees, 0 to 180.
fn float angle_of(Quaternionf q) @local
{
	q = q.normalize();
	float vector = math::sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2]);
	return 2.0f * (float)math::atan2(vector, math::abs(q.v[3])) * 57.29578f;
}

// How far a rotation's up has leaned from where `was` had it, in degrees.
fn float tilt_of(Quaternionf was, Quaternionf now) @local
{
	Vec3 before = was.rotate_vec3({ 0, 1, 0 });
	Vec3 after = now.rotate_vec3({ 0, 1, 0 });
	return (float)math::atan2(before.cross(after).length(), before.dot(after)) * 57.29578f;
}

// The thresholds `puppet_test` judges a sit by: the hips (and the trunk, where it is
// asked) lean less than `UPRIGHT` degrees, a pinned foot turns less than `FOOT_FLAT`.
const float UPRIGHT = 10.0f;
const float FOOT_FLAT = 3.0f;

<*
 How the figure stood as a gesture began, for the sit to be judged against: the
 world rotations of the hips, the waist and the feet. Read while the gesture is open,
 which is when `dot_world_rotation` has a draft to read.
*>
struct Stance
{
	Quaternionf hips;
	Quaternionf waist;
	Quaternionf foot_l;
	Quaternionf foot_r;
}

fn Stance Sitter.stance(&self) => {
	.hips = self.app.dot_world_rotation(self.hips),
	.waist = self.app.dot_world_rotation(self.upper_spine),
	.foot_l = self.app.dot_world_rotation(self.ankle_l),
	.foot_r = self.app.dot_world_rotation(self.ankle_r),
};

<*
 The sit upright and the feet flat: neither foot turned `FOOT_FLAT` degrees since
 `was`, the hips leaned less than `UPRIGHT`, and — when `waist` — the waist too. (A
 pull on the hips with Balance on leans the waist over the feet: that is its job, and it
 is not asked to stay up.)
*>
fn void Sitter.check_stance(&self, Stance* was, bool waist, String what)
{
	crig::AppState* app = &self.app;
	float foot_l = angle_of(app.dot_world_rotation(self.ankle_l).mul(was.foot_l.invert()));
	float foot_r = angle_of(app.dot_world_rotation(self.ankle_r).mul(was.foot_r.invert()));
	float hips = tilt_of(was.hips, app.dot_world_rotation(self.hips));
	float trunk = tilt_of(was.waist, app.dot_world_rotation(self.upper_spine));
	test::@check(foot_l < FOOT_FLAT && foot_r < FOOT_FLAT, "%s: a foot turned %.2f / %.2f degrees", what, foot_l, foot_r);
	test::@check(hips < UPRIGHT, "%s: the hips tilted %.2f degrees", what, hips);
	test::@check(!waist || trunk < UPRIGHT, "%s: the waist tilted %.2f degrees", what, trunk);
}

<*
 The sit: lock the feet, pull the hips down, the knees fold and the feet stay.
*>
fn void anchored_feet_hold_while_the_hips_drop() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3 foot_l = fixture.at(fixture.ankle_l);
	Vec3 foot_r = fixture.at(fixture.ankle_r);
	test::@check(app.lock_position(fixture.ankle_l), "the left foot did not lock");
	test::@check(app.lock_position(fixture.ankle_r), "the right foot did not lock");
	test::@check(app.is_anchored(fixture.ankle_l) && app.is_anchored(fixture.ankle_r),
		"the feet report unlocked");

	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin on the hips");
	Vec3 hips_from = fixture.at(fixture.hips);
	Stance stance = fixture.stance();
	app.pose_toward(hips_from - (Vec3){ 0, 0.5, 0 });

	// The feet stayed. Without the anchors they would have fallen the whole 0.5.
	float moved_l = (fixture.at(fixture.ankle_l) - foot_l).length();
	float moved_r = (fixture.at(fixture.ankle_r) - foot_r).length();
	test::@check(moved_l < 0.03f, "the left foot moved %.3f from where it was pinned", moved_l);
	test::@check(moved_r < 0.03f, "the right foot moved %.3f from where it was pinned", moved_r);

	// The hips did drop.
	test::@check(math::abs(fixture.at(fixture.hips).y - (hips_from.y - 0.5f)) < 0.02f,
		"the hips landed at y=%.3f, not %.3f", fixture.at(fixture.hips).y, hips_from.y - 0.5f);

	// And the knees folded to keep the feet in place, the pelvis level and the feet flat.
	test::@check(bend_of(app.working_pose(fixture.knee_l).rotation) > 1.0e-3f, "the left knee did not bend");
	test::@check(bend_of(app.working_pose(fixture.knee_r).rotation) > 1.0e-3f, "the right knee did not bend");
	fixture.check_stance(&stance, false, "hips drop");
}

<*
 A pin is a hard stop: pulling the hips up past what the legs can reach lifts
 them only until a leg is straight, and the feet stay on the floor — the body
 cannot be torn off its pins.
*>
fn void anchored_feet_stop_a_pull_past_the_legs_reach() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3 foot_l = fixture.at(fixture.ankle_l);
	Vec3 foot_r = fixture.at(fixture.ankle_r);
	test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");

	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin on the hips");
	Vec3 hips_from = fixture.at(fixture.hips);
	for (int k = 1; k <= 10; k++) app.pose_toward(hips_from + (Vec3){ 0, 0.05f * k, 0 });

	float moved_l = (fixture.at(fixture.ankle_l) - foot_l).length();
	float moved_r = (fixture.at(fixture.ankle_r) - foot_r).length();
	test::@check(moved_l < 0.03f, "the left foot was pulled %.3f off its pin", moved_l);
	test::@check(moved_r < 0.03f, "the right foot was pulled %.3f off its pin", moved_r);
	// The legs are barely bent, so the hips rise only the little the knees can
	// straighten — nowhere near the half unit asked for.
	float rose = fixture.at(fixture.hips).y - hips_from.y;
	test::@check(rose < 0.05f, "the hips rose %.3f, past the legs' reach", rose);

	// And back down within reach, the hips follow the pointer again — moved the way
	// a pointer moves, a step at a time.
	Vec3 stopped = fixture.at(fixture.hips);
	for (int k = 1; k <= 10; k++)
	{
		app.pose_toward(stopped + (hips_from - (Vec3){ 0, 0.2f, 0 } - stopped) * (k / 10.0f));
	}
	float off = (fixture.at(fixture.hips) - (hips_from - (Vec3){ 0, 0.2f, 0 })).length();
	test::@check(off < 0.02f, "after a stop the hips did not follow back down; %.3f off", off);
	test::@check((fixture.at(fixture.ankle_l) - foot_l).length() < 0.03f, "the foot slipped on the way down");
}

<*
 The user's literal gesture: grab the spine, which a fork above it would refuse —
 but with a foot anchored the root carries it, and the feet still hold.
*>
fn void grabbing_the_spine_carries_the_body_and_holds_the_feet() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3 foot_l = fixture.at(fixture.ankle_l);
	test::@check(app.lock_position(fixture.ankle_l), "the left foot did not lock");
	test::@check(app.lock_position(fixture.ankle_r), "the right foot did not lock");

	Stance stance;
	Vec3 spine_from = fixture.at(fixture.spine);
	Vec3 target = spine_from - (Vec3){ 0, 0.5, 0 };
	pull_in_steps(&fixture, fixture.spine, target - spine_from, &stance);

	// The spine reached the pointer, carried there by the root sliding under it.
	float off = (fixture.at(fixture.spine) - target).length();
	test::@check(off < 0.02f, "the spine did not follow the drag; %.3f off the target", off);
	// And the feet held.
	float moved_l = (fixture.at(fixture.ankle_l) - foot_l).length();
	test::@check(moved_l < 0.03f, "the foot moved %.3f under a spine grab", moved_l);
	// The body came down level and upright, the feet flat.
	fixture.check_stance(&stance, true, "spine grab");
}

<*
 Without an anchor the spine still moves, and the body with it: the hips follow
 it and the unpinned legs ride along — near enough the spine's own move, the
 pelvis turning a little where the pull is sideways.
*>
fn void the_spine_carries_the_body_without_an_anchor() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.select(fixture.spine);
	test::@check(app.begin_pose(), "G on the spine was refused with no foot anchored");
	Vec3 spine_from = fixture.at(fixture.spine);
	Vec3 hips_from = fixture.at(fixture.hips);
	Vec3 foot_from = fixture.at(fixture.ankle_l);
	Vec3 by = { 0.1f, -0.2f, 0 };
	for (int k = 1; k <= 10; k++) app.pose_toward(spine_from + by * (k / 10.0f));
	float off = (fixture.at(fixture.spine) - (spine_from + by)).length();
	test::@check(off < 0.02f, "the spine did not follow the drag; %.3f off the target", off);
	float hips = (fixture.at(fixture.hips) - (hips_from + by)).length();
	test::@check(hips < 0.05f, "the hips did not come with the spine; %.3f off its move", hips);
	float carried = (fixture.at(fixture.ankle_l) - (foot_from + by)).length();
	test::@check(carried < 0.1f, "the unpinned foot did not ride along; %.3f off", carried);
}

<*
 Escape undoes the whole sit — the folded legs the anchors bent, not only the
 grabbed hips.
*>
fn void escape_puts_the_folded_legs_back() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.lock_position(fixture.ankle_l);
	app.lock_position(fixture.ankle_r);
	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin");
	Vec3 hips_from = fixture.at(fixture.hips);
	app.pose_toward(hips_from - (Vec3){ 0, 0.35, 0 });
	test::@check(bend_of(app.working_pose(fixture.knee_l).rotation) > 1.0e-3f,
		"the knee did not bend to set up the check");

	test::@check(app.cancel_drag(), "escape did not cancel the pose");
	test::@check(bend_of(app.working_pose(fixture.knee_l).rotation) < 1.0e-4f, "the near knee did not return to rest");
	test::@check(bend_of(app.working_pose(fixture.knee_r).rotation) < 1.0e-4f, "the far knee did not return to rest");
	test::@check((fixture.at(fixture.hips) - hips_from).length() < 1.0e-4f, "the hips did not return to rest");
}

<*
 The state the checkbox and L both drive: an idempotent toggle over a list that
 never holds two of one dot, and a clear that empties it.
*>
fn void the_anchor_toggles_and_clears() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	test::@check(app.toggle_position_anchor(fixture.ankle_l), "toggle did not anchor");
	test::@check(app.is_anchored(fixture.ankle_l), "the anchor did not take");
	// Locking again re-captures rather than duplicating.
	test::@check(app.lock_position(fixture.ankle_l), "re-lock refused");
	test::@check(app.position_locks.len == 1, "a re-lock left %d anchors, not one", (int)app.position_locks.len);

	test::@check(!app.toggle_position_anchor(fixture.ankle_l), "toggle did not release");
	test::@check(!app.is_anchored(fixture.ankle_l), "the anchor did not clear");

	app.lock_position(fixture.ankle_l);
	app.lock_position(fixture.ankle_r);
	app.clear_position_locks();
	test::@check(!app.is_anchored(fixture.ankle_l) && !app.is_anchored(fixture.ankle_r), "clear left an anchor");
	test::@check(app.position_locks.len == 0, "clear left %d anchors", (int)app.position_locks.len);
}

// How far two orientations differ, 0 when equal.
fn float orient_gap(Quaternionf a, Quaternionf b) @local => 1.0f - math::abs(a.v.dot(b.v));

<*
 The two padlocks are independent: each half toggles on its own, both can be on
 at once, and dropping one leaves the other — a rotation-only anchor still counts
 as anchored, and only when both halves are off does the entry go.
*>
fn void the_two_anchor_halves_are_independent() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	test::@check(app.toggle_position_anchor(fixture.ankle_l), "position toggle did not anchor");
	test::@check(app.locks_position(fixture.ankle_l) && !app.locks_rotation(fixture.ankle_l),
		"position toggle also turned rotation on");

	test::@check(app.toggle_rotation_anchor(fixture.ankle_l), "rotation toggle did not anchor");
	test::@check(app.locks_position(fixture.ankle_l) && app.locks_rotation(fixture.ankle_l),
		"both halves are not on together");
	test::@check(app.position_locks.len == 1, "the two halves split into %d entries", (int)app.position_locks.len);

	test::@check(!app.toggle_position_anchor(fixture.ankle_l), "position toggle did not release");
	test::@check(app.is_anchored(fixture.ankle_l) && app.locks_rotation(fixture.ankle_l)
		&& !app.locks_position(fixture.ankle_l), "releasing position took the rotation half with it");

	test::@check(!app.toggle_rotation_anchor(fixture.ankle_l), "rotation toggle did not release");
	test::@check(!app.is_anchored(fixture.ankle_l), "both halves off left the anchor standing");
}

<*
 A rotation anchor holds the foot's orientation flat while its leg folds, and a
 position-only anchor keeps it too — softly (`POINT_POSE_PIN_SOFT_TURN`), where the
 rotation anchor holds it hard. The sitter's ankles have no limits to give way
 against, so both feet stay flat; the difference between the two is what happens
 past an ankle's reach, which the humanoid's own checks measure (`puppet_test`).
*>
fn void a_rotation_anchor_holds_the_foot_flat() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	// Left foot pinned position and rotation; right foot position only.
	app.lock_position(fixture.ankle_l);
	app.lock_rotation(fixture.ankle_l);
	app.lock_position(fixture.ankle_r);
	test::@check(app.locks_rotation(fixture.ankle_l), "the rotation half did not take");
	test::@check(!app.locks_rotation(fixture.ankle_r), "the right foot took a rotation anchor it was not given");

	Quaternionf held = app.dot_world_rotation(fixture.ankle_l);

	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin");
	Vec3 hips_from = fixture.at(fixture.hips);
	app.pose_toward(hips_from - (Vec3){ 0, 0.5, 0 });

	// The rotation-anchored foot kept its orientation, and so did the position-only
	// one: its angle is held softly, and nothing here asks it to give.
	float held_gap = orient_gap(app.dot_world_rotation(fixture.ankle_l), held);
	float free_gap = orient_gap(app.dot_world_rotation(fixture.ankle_r), held);
	test::@check(held_gap < 0.01f, "the rotation-anchored foot tilted by %.3f", held_gap);
	test::@check(free_gap < 0.01f, "the position-only foot did not keep its angle (free %.3f vs held %.3f)", free_gap, held_gap);
}

<*
 Every anchor that held reports a residual near zero — K2's read-back: both feet
 hold, and the rotation-anchored foot's angular miss is small too.
*>
fn void anchors_report_that_they_held() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.lock_position(fixture.ankle_l);
	app.lock_rotation(fixture.ankle_l);
	app.lock_position(fixture.ankle_r);

	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin on the hips");
	Vec3 hips_from = fixture.at(fixture.hips);
	app.pose_toward(hips_from - (Vec3){ 0, 0.35, 0 });

	test::@check(app.lock_position_residual(fixture.ankle_l) < 0.03f,
		"the left foot reports %.3f off its pin", app.lock_position_residual(fixture.ankle_l));
	test::@check(app.lock_position_residual(fixture.ankle_r) < 0.03f,
		"the right foot reports %.3f off its pin", app.lock_position_residual(fixture.ankle_r));
	test::@check(app.lock_rotation_residual(fixture.ankle_l) < 0.1f,
		"the left foot's tilt reports %.3f rad off held", app.lock_rotation_residual(fixture.ankle_l));
}

<*
 An anchor out of the limb's reach reports its miss honestly rather than reading
 as held — and, already missing when the gesture began, it does not freeze the
 pull the way a pin the pull would tear loose does.
*>
fn void an_unreachable_anchor_reports_the_gap() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.lock_position(fixture.ankle_l);
	// Held a leg and a half below the floor: nothing the leg does can reach it.
	// The pin is the clip's while a clip is edited, so it is moved there and the
	// gesture pins follow (`sync_clip_pins`).
	crig::RigView view = app.open_rig(mem)!!;
	float height = view.skeleton.height();
	view.free(mem);
	app.clip(app.editing).pins[0].at.y -= 1.5f / height;
	app.sync_clip_pins();

	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin on the hips");
	Vec3 hips_from = fixture.at(fixture.hips);
	app.pose_toward(hips_from + (Vec3){ 0, 0.3, 0 });
	test::@check(math::abs(fixture.at(fixture.hips).y - (hips_from.y + 0.3f)) < 0.02f,
		"a pin out of reach from the start froze the pull");

	test::@check(app.lock_position_residual(fixture.ankle_l) > 0.2f,
		"an unreachable pin read only %.3f off, not the large miss it is",
		app.lock_position_residual(fixture.ankle_l));
}

// Pins the knee and the ankle of one leg in the given order, optionally moves the
// knee's pin `knee_drop` below where the knee stands, and sits the figure.
fn void sit_on_knee_and_ankle(Sitter* fixture, bool ankle_first, float knee_drop) @local
{
	crig::AppState* app = &fixture.app;
	if (ankle_first)
	{
		app.lock_position(fixture.ankle_l);
		app.lock_position(fixture.knee_l);
	}
	else
	{
		app.lock_position(fixture.knee_l);
		app.lock_position(fixture.ankle_l);
	}
	if (knee_drop != 0.0f)
	{
		crig::RigView view = app.open_rig(mem)!!;
		float height = view.skeleton.height();
		view.free(mem);
		foreach (&pin : app.clip(app.editing).pins)
		{
			if (pin.joint == "knee_L") pin.at.y -= knee_drop / height;
		}
		app.sync_clip_pins();
	}
	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin on the hips");
	Vec3 hips_from = fixture.at(fixture.hips);
	for (int k = 1; k <= 10; k++) app.pose_toward(hips_from - (Vec3){ 0, 0.035f * k, 0 });
}

<*
 Two pins on one leg — the knee and the ankle — that agree with each other both
 hold: nothing stands down for the other. Pulled where they cannot both be met
 the body stops, and neither is torn off.
*>
fn void consistent_pins_on_one_leg_both_hold() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	Vec3 knee = fixture.at(fixture.knee_l);
	Vec3 ankle = fixture.at(fixture.ankle_l);
	sit_on_knee_and_ankle(&fixture, true, 0.0f);
	test::@check((fixture.at(fixture.knee_l) - knee).length() < 0.014f, "the knee left its pin by %.3f", (fixture.at(fixture.knee_l) - knee).length());
	test::@check((fixture.at(fixture.ankle_l) - ankle).length() < 0.014f, "the ankle left its pin by %.3f", (fixture.at(fixture.ankle_l) - ankle).length());
	test::@check(app.lock_position_residual(fixture.knee_l) < 0.014f && app.lock_position_residual(fixture.ankle_l) < 0.014f,
		"the readout says the pins missed (%.3f, %.3f)", app.lock_position_residual(fixture.knee_l), app.lock_position_residual(fixture.ankle_l));
}

<*
 Two pins on one leg that cannot both hold — the knee's set below where the shin
 lets it reach from the ankle — report what each misses by, honestly and whatever
 order they were set in: the same miss either way, and on screen what the readout
 says.
*>
fn void inconsistent_pins_report_their_miss_in_either_order() @test
{
	float[2] misses;
	foreach (usz run, bool ankle_first : (bool[2]){ true, false })
	{
		Sitter fixture;
		test::@check(fixture.open(), "the fixture did not open");
		defer fixture.close();
		crig::AppState* app = &fixture.app;
		sit_on_knee_and_ankle(&fixture, ankle_first, 0.2f);
		float knee = app.lock_position_residual(fixture.knee_l);
		float ankle = app.lock_position_residual(fixture.ankle_l);
		sz k = app.lock_index(fixture.knee_l);
		float shown = (fixture.at(fixture.knee_l) - app.position_locks[(usz)k].target).length();
		test::@check(knee + ankle > 0.1f, "two pins 0.2 apart from agreeing report only %.3f and %.3f", knee, ankle);
		test::@check(math::abs(knee - shown) < 0.003f, "the knee reads %.3f off and is %.3f off", knee, shown);
		misses[run] = knee + ankle;
	}
	test::@check(math::abs(misses[0] - misses[1]) < 0.01f, "the order the pins were set in changed the miss: %.3f against %.3f", misses[0], misses[1]);
}

<*
 A padlock press acts on the whole selection: with two feet selected, one press
 anchors both, not just the primary. The other half is left as each dot had it, so
 a foot already position-anchored keeps that when the pair is rotation-anchored.
*>
fn void a_padlock_press_anchors_every_selected_joint() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	// The left foot is already position-anchored on its own, to prove the press
	// leaves the untouched half alone.
	app.lock_position(fixture.ankle_l);

	app.select(fixture.ankle_l);
	app.extend_selection(fixture.ankle_r);
	test::@check(app.selected == fixture.ankle_l && app.also_selected.len() == 1,
		"the two-foot selection did not form");

	// Rotation-anchor the selection: the card's press with the primary reading off.
	usz acted = app.set_selection_anchor_half(rotation: true, on: true);
	test::@check(acted == 2, "the press acted on %d joints, not both", (int)acted);
	test::@check(app.locks_rotation(fixture.ankle_l) && app.locks_rotation(fixture.ankle_r),
		"only the primary foot took the rotation anchor");
	// The position half each foot had is untouched: the left keeps its lock, the
	// right never gained one.
	test::@check(app.locks_position(fixture.ankle_l), "the rotation press dropped the left foot's position anchor");
	test::@check(!app.locks_position(fixture.ankle_r), "the rotation press also position-anchored the right foot");

	// And a second press releases the rotation half on both together.
	usz released = app.set_selection_anchor_half(rotation: true, on: false);
	test::@check(released == 2, "the release acted on %d joints, not both", (int)released);
	test::@check(!app.locks_rotation(fixture.ankle_l) && !app.locks_rotation(fixture.ankle_r),
		"a foot kept its rotation anchor after the release");
}

<*
 A pinned trunk joint holds the body: nothing below the root can bend the spine
 back into place, so with the spine pinned a hips pull goes nowhere — and says
 why, rather than silently refusing.
*>
fn void a_pinned_spine_holds_the_body_and_says_so() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");
	test::@check(app.lock_position(fixture.spine), "the spine did not lock");

	app.select(fixture.hips);
	test::@check(app.begin_pose(), "G did not begin on the hips");
	Vec3 hips_from = fixture.at(fixture.hips);
	app.pose_toward(hips_from - (Vec3){ 0, 0.3, 0 });

	test::@check((fixture.at(fixture.hips) - hips_from).length() < 0.02f,
		"a pinned spine let the hips move %.3f", (fixture.at(fixture.hips) - hips_from).length());
	test::@check(app.notice().contains("pinned joints hold"), "no notice said the pins held: '%s'", app.notice());
}

// Pull `grabbed` from where it stands by `by`, in the ten steps a pointer would
// take, as one gesture left open.
// `stance`, when given, is filled with how the figure stood as the gesture began.
fn void pull_in_steps(Sitter* fixture, uint grabbed, Vec3 by, Stance* stance = null) @local
{
	crig::AppState* app = &fixture.app;
	app.select(grabbed);
	test::@check(app.begin_pose(), "G did not begin on the grabbed joint");
	if (stance) *stance = fixture.stance();
	Vec3 from = fixture.at(grabbed);
	for (int k = 1; k <= 10; k++) app.pose_toward(from + by * (k / 10.0f));
}

<*
 The user's gesture, on a T-pose: both feet pinned, the waist (`upper_spine`)
 pulled down. The whole body comes down — the hips drop, not just the spine
 bending — the knees fold *forward* inside their hinge range, and the feet stay
 on their pins.
*>
fn void pulling_the_waist_sits_a_t_pose_down() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3 foot_l = fixture.at(fixture.ankle_l);
	Vec3 foot_r = fixture.at(fixture.ankle_r);
	Vec3 hips_from = fixture.at(fixture.hips);
	test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");

	Stance stance;
	pull_in_steps(&fixture, fixture.upper_spine, { 0, -0.5f, 0 }, &stance);

	float dropped = hips_from.y - fixture.at(fixture.hips).y;
	test::@check(dropped > 0.45f, "the hips dropped only %.3f — the waist pull did not lower the body", dropped);
	// Level, upright and flat-footed all the way down.
	fixture.check_stance(&stance, true, "waist sit");
	float slip_l = (fixture.at(fixture.ankle_l) - foot_l).length();
	float slip_r = (fixture.at(fixture.ankle_r) - foot_r).length();
	test::@check(slip_l < 0.014f && slip_r < 0.014f, "the feet slipped %.3f / %.3f off their pins", slip_l, slip_r);

	// Forward: the knee ends ahead of the line from hip to ankle (+Z is forward).
	test::@check(fixture.at(fixture.knee_l).z > 0.05f && fixture.at(fixture.knee_r).z > 0.05f,
		"the knees did not bend forward (z %.3f, %.3f)", fixture.at(fixture.knee_l).z, fixture.at(fixture.knee_r).z);

	// And inside the hinge: X in 0..150 degrees, the other two axes held at zero.
	foreach (knee : (uint[2]){ fixture.knee_l, fixture.knee_r })
	{
		crig::RigView view = app.open_rig(mem)!!;
		defer view.free(mem);
		crig::JointRotationLimits limits = app.doc.rotation_limits_of(knee);
		crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		Vec3 angles = crig::joint_angles_from_rotation(frame, app.working_pose(knee).rotation);
		test::@check(angles.x >= -1.0e-3f && angles.x <= 2.619f, "a knee bent %.3f rad, outside its hinge", angles.x);
		test::@check(math::abs(angles.y) < 1.0e-3f && math::abs(angles.z) < 1.0e-3f,
			"a knee turned off its hinge axis (%.3f, %.3f)", angles.y, angles.z);
	}
}

<*
 Down and back is a sit onto a chair: the hips travel behind the feet, the feet
 hold, and one release banks the whole pose as one undo step.
*>
fn void a_chair_sit_holds_the_feet_and_undoes_in_one_step() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3 foot_l = fixture.at(fixture.ankle_l);
	Vec3 hips_from = fixture.at(fixture.hips);
	test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");

	Stance stance;
	pull_in_steps(&fixture, fixture.hips, { 0, -0.3f, -0.2f }, &stance);
	test::@check((fixture.at(fixture.hips) - (hips_from + (Vec3){ 0, -0.3f, -0.2f })).length() < 0.03f,
		"the hips did not reach the chair");
	test::@check((fixture.at(fixture.ankle_l) - foot_l).length() < 0.014f, "the foot slipped");
	// The waist is left to lean over the feet (the next test); the pelvis and the feet are not.
	fixture.check_stance(&stance, false, "chair sit");

	app.auto_key = true;
	app.end_drag();
	test::@check(app.undo(), "the sit did not undo");
	test::@check((fixture.at(fixture.hips) - hips_from).length() < 1.0e-3f, "one undo did not stand the figure back up");
}

<*
 A turn of the hips with the feet pinned: the pelvis tilts and the legs follow it
 so the feet stay where they were.
*>
fn void turning_the_hips_keeps_the_pinned_feet_down() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	// Sit a little first, so the legs have bend to share.
	test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");
	pull_in_steps(&fixture, fixture.hips, { 0, -0.2f, 0 });
	app.end_drag();
	Vec3 foot_l = fixture.at(fixture.ankle_l);
	Vec3 foot_r = fixture.at(fixture.ankle_r);

	app.select(fixture.hips);
	test::@check(app.begin_turn(), "R did not begin on the hips");
	for (int k = 1; k <= 10; k++) app.turn_joint({ 0, 0, 1 }, 0.02f * k);

	test::@check(bend_of(app.working_pose(fixture.hips).rotation) > 1.0e-4f, "the hips did not turn");
	float slip_l = (fixture.at(fixture.ankle_l) - foot_l).length();
	float slip_r = (fixture.at(fixture.ankle_r) - foot_r).length();
	test::@check(slip_l < 0.014f && slip_r < 0.014f, "the feet slipped %.3f / %.3f under a hips turn", slip_l, slip_r);
}

// How far the spine leans forward of the hips (+Z), as a share of its length.
fn float lean_of(Sitter* fixture) @local
{
	Vec3 spine = fixture.at(fixture.upper_spine) - fixture.at(fixture.hips);
	return spine.z / spine.length();
}

<*
 A person sitting back on planted feet leans forward to keep their weight over
 them. Pulling the hips down and back leans the spine forward while the hips
 still go where they were pulled; with Balance off the spine stays upright.
*>
fn void sitting_back_leans_the_body_over_the_feet() @test
{
	float[2] leans;
	foreach (usz run, off : (bool[2]){ false, true })
	{
		Sitter fixture;
		test::@check(fixture.open(), "the fixture did not open");
		defer fixture.close();
		crig::AppState* app = &fixture.app;
		app.balance_off = off;

		Vec3 foot_l = fixture.at(fixture.ankle_l);
		Vec3 hips_from = fixture.at(fixture.hips);
		test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");
		Stance stance;
		pull_in_steps(&fixture, fixture.hips, { 0, -0.3f, -0.15f }, &stance);
		fixture.check_stance(&stance, false, off ? "sitting back, balance off" : "sitting back, balance on");

		float off_target = (fixture.at(fixture.hips) - (hips_from + (Vec3){ 0, -0.3f, -0.15f })).length();
		test::@check(off_target < 0.02f, "the hips missed the pull by %.3f (balance %s)", off_target, off ? "off" : "on");
		test::@check((fixture.at(fixture.ankle_l) - foot_l).length() < 0.014f, "the foot slipped");
		leans[run] = lean_of(&fixture);
	}
	test::@check(leans[0] > 0.2f, "sitting back leaned the spine only %.3f forward", leans[0]);
	test::@check(math::abs(leans[1]) < 0.05f, "with Balance off the spine still leaned %.3f", leans[1]);
}

<*
 A rest pose whose knees are modelled slightly hyper-extended — behind the line
 from hip to ankle, the way Zidane's are. The hinge's 0 is that rest angle, so
 folding the knee the way its range opens first *lengthens* the leg; a solve that
 only saw "shorter" bent it further back, which the limit refuses, and stalled.
 The waist pull still has to sit the figure down.
*>
fn void a_hyper_extended_rest_knee_still_sits() @test
{
	Sitter fixture;
	test::@check(fixture.open(knee_z: -0.04f), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3 foot_l = fixture.at(fixture.ankle_l);
	Vec3 hips_from = fixture.at(fixture.hips);
	test::@check(app.lock_position(fixture.ankle_l) && app.lock_position(fixture.ankle_r), "the feet did not lock");

	Stance stance;
	pull_in_steps(&fixture, fixture.upper_spine, { 0, -0.45f, 0 }, &stance);

	float dropped = hips_from.y - fixture.at(fixture.hips).y;
	test::@check(dropped > 0.4f, "the hips dropped only %.3f from a hyper-extended rest", dropped);
	test::@check((fixture.at(fixture.ankle_l) - foot_l).length() < 0.014f, "the foot slipped");
	test::@check(fixture.at(fixture.knee_l).z > 0.05f, "the knee did not come forward (z %.3f)", fixture.at(fixture.knee_l).z);
	fixture.check_stance(&stance, true, "hyper-extended sit");
}

<*
 Pin feet pins both ankles, position and angle, where they stand, and a second
 press lets them go.
*>
fn void pin_feet_pins_both_ankles_and_lets_them_go() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	test::@check(!app.feet_pinned(), "the feet read pinned before anything was pinned");
	test::@check(app.pin_feet(true) == 2, "Pin feet did not find both ankles");
	test::@check(app.feet_pinned(), "the feet do not read pinned");
	foreach (foot : (uint[2]){ fixture.ankle_l, fixture.ankle_r })
	{
		test::@check(app.locks_position(foot) && app.locks_rotation(foot), "a foot missed a half of its pin");
	}
	app.pin_feet(false);
	test::@check(!app.is_anchored(fixture.ankle_l) && !app.is_anchored(fixture.ankle_r), "unpinning left a foot pinned");
}

<*
 A padlock press over a selection that swept up the hips pins the feet and leaves
 the hips free — pinning a trunk joint pins the whole body, which is never what
 pinning the feet with the rest selected meant.
*>
fn void a_selection_pin_leaves_trunk_joints_free() @test
{
	Sitter fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.select(fixture.ankle_l);
	app.extend_selection(fixture.ankle_r);
	app.extend_selection(fixture.hips);
	usz skipped;
	usz acted = app.set_selection_anchor_half(rotation: false, on: true, skipped: &skipped);
	test::@check(acted == 2 && skipped == 1, "pinned %d and skipped %d, not 2 and 1", (int)acted, (int)skipped);
	test::@check(app.locks_position(fixture.ankle_l) && app.locks_position(fixture.ankle_r), "a foot was not pinned");
	test::@check(!app.is_anchored(fixture.hips), "the hips were pinned with the feet");

	// Asked for by name, alone, the hips are still pinned.
	app.select(fixture.hips);
	test::@check(app.set_selection_anchor_half(rotation: false, on: true) == 1 && app.locks_position(fixture.hips),
		"a lone hips pin was refused");
}

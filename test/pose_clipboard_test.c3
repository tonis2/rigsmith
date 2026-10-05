<*
 The viewport's pose clipboard: copy, paste, paste mirrored and mirror in place.

     `c3c test --trust=full --test-filter crig_tests::pose_clipboard`

 The biped workflow fixture again — a Mixamo-named rig fitted to the shared
 cube, and a two-key clip on it — so twins are found by the same names a real
 figure carries. Each check is about the contract in `app/pose_clipboard.c3`:
 the selection scopes the copy, a paste lands the copied joints and nothing
 else as one undo entry, a flip lands on the twin with the three sign rules
 applied, and the two clipboards never disturb each other.
*>
module crig_tests::pose_clipboard;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

const String LEFT = "thigh_L";
const String RIGHT = "thigh_R";
const String HIPS = "hips";

struct Figure
{
	crig::AppState app;
	AnimRef clip;
	uint left;
	uint right;
	uint hips;
	Quaternionf first;
	Quaternionf second;
}

fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

<*
 A biped with LeftUpLeg turned to `first` at 0 s and `second` at 0.5 s, every
 other joint keyed at rest at both, stopped and with the left leg selected.
*>
fn bool Figure.open(&self)
{
	self.app = shared_app::open();
	if (!self.app.apply_plan_named("biped")) return false;
	self.left = dot_named(&self.app, LEFT);
	self.right = dot_named(&self.app, RIGHT);
	self.hips = dot_named(&self.app, HIPS);
	if (self.left == 0 || self.right == 0 || self.hips == 0) return false;

	// About Z rather than X: reflecting an X turn is the same turn, and a check
	// that cannot tell a flip from a copy is not a check of the flip.
	self.first = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.4f);
	self.second = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), -0.15f);
	self.clip = self.app.new_clip("pose", 1.0f, from_rest: true);
	if (!self.clip.valid()) return false;
	self.app.editing = self.clip;
	if (!self.key_left(0.0f, self.first)) return false;
	if (!self.key_left(0.5f, self.second)) return false;

	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = self.clip;
	self.app.edit_time = 0.0f;
	self.app.select(self.left);
	return true;
}

fn bool Figure.key_left(&self, float time, Quaternionf turn, Vec3 offset = {})
{
	if (!self.app.pose_from_clip(self.app.editing, time)) return false;
	self.app.edit_time = time;
	if (!self.app.set_working_pose(self.left, turn, offset)) return false;
	self.app.pose_edit_pending = true;
	if (!self.app.key_pose_edit()) return false;
	self.clip = self.app.editing;
	return true;
}

fn void Figure.close(&self) => self.app.free();

// The stored entry, read skeleton-free so the check sees what was written and
// not what carrying it onto the rig makes of it.
fn AnimKeyDot Figure.entry(&self, String joint, float time)
{
	return self.app.clip(self.app.editing).entry_at(joint, time);
}

fn Vec3 turn_of(AnimKeyDot dot) => dot.axis.normalize() * dot.angle;

fn Vec3 turn_of_quaternion(Quaternionf q)
{
	Vec3 axis;
	float angle;
	crig::axis_angle_of(q, &axis, &angle);
	return axis * angle;
}

fn bool same_turn(Vec3 a, Vec3 b) => (a - b).length() < 1.0e-4f;

fn bool has_key_at(crig::AppState* app, float time)
{
	foreach (frame : app.clip(app.editing).keyframes)
	{
		if (math::abs(frame.time - time) < 1.0e-4f) return true;
	}
	return false;
}

fn void a_selected_pose_pastes_the_same_joints_as_one_undo() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("copy at 0 s, paste at 0.5 s: the left leg alone, one undo entry");

	test::@check(f.app.copy_pose() == 1, "one selected joint did not copy as one entry");
	test::@check(f.app.anim_pose_clipboard.dots[0].joint_name == LEFT,
		"the clipboard carries %s rather than the selected leg", f.app.anim_pose_clipboard.dots[0].joint_name);

	Vec3 hips_before = turn_of(f.entry(HIPS, 0.5f));
	f.app.edit_time = 0.5f;
	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.paste_pose(), "the paste was refused");
	test::@check(f.app.undo_stack.cursor == cursor + 1, "one paste was not one history entry");
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.5f)), turn_of_quaternion(f.first)),
		"the pasted leg does not hold the copied turn");
	test::@check(same_turn(turn_of(f.entry(HIPS, 0.5f)), hips_before),
		"pasting one leg rewrote the hips");
	test::@check(f.app.animating && f.app.anim_paused,
		"the pasted frame was not parked for viewing");

	test::@check(f.app.undo(), "the paste would not undo");
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.5f)), turn_of_quaternion(f.second)),
		"undo did not restore the previous key");
	test::@check(f.app.redo() && same_turn(turn_of(f.entry(LEFT, 0.5f)), turn_of_quaternion(f.first)),
		"redo did not restore the paste");
}

fn void a_paste_between_keys_makes_a_key_for_the_copied_joints_only() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("pasting at 0.25 s, where no key is, keys the copied joint alone");

	test::@check(f.app.copy_pose() == 1, "copy failed");
	f.app.edit_time = 0.25f;
	test::@check(!has_key_at(&f.app, 0.25f), "the fixture already keys 0.25 s");
	test::@check(f.app.paste_pose(), "the paste was refused");
	test::@check(has_key_at(&f.app, 0.25f), "no key was made at the playhead");
	AnimKeyframe made;
	foreach (frame : f.app.clip(f.app.editing).keyframes) if (math::abs(frame.time - 0.25f) < 1.0e-4f) made = frame;
	test::@check(made.dots.len == 1 && made.dots[0].joint_name == LEFT,
		"the new key names %d joints; the copied one alone was wanted", made.dots.len);
	test::@check(made.dots[0].channels == BOTH, "a pose entry keys both channels");
}

fn void nothing_selected_copies_the_whole_pose() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("an empty selection copies every named joint");

	f.app.select(0);
	usz named;
	foreach (dot : f.app.doc.dots.array_view()) if (dot.name.len > 0) named++;
	test::@check(f.app.copy_pose() == named, "%d joints copied of %d named",
		f.app.anim_pose_clipboard.dots.len, named);
}

fn void a_mirrored_paste_lands_on_the_twin_reflected() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("Ctrl+Shift+V puts the left leg's turn on the right leg, reflected");

	// A slide as well, since the reflection treats the two differently.
	float height = 0.0f;
	{
		RigView view = f.app.open_rig(mem)!!;
		defer view.free(mem);
		height = view.skeleton.height();
	}
	test::@check(f.key_left(0.0f, f.first, { 0.1f * height, 0.05f * height, 0.0f }),
		"the fixture could not key a slide");
	f.app.stop_animation();
	f.app.edit_time = 0.0f;
	test::@check(f.app.copy_pose() == 1, "copy failed");

	Vec3 left_before = turn_of(f.entry(LEFT, 0.5f));
	f.app.edit_time = 0.5f;
	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.paste_pose(flipped: true), "the mirrored paste was refused");
	test::@check(f.app.undo_stack.cursor == cursor + 1, "one mirrored paste was not one history entry");

	AnimKeyDot right = f.entry(RIGHT, 0.5f);
	Vec3 want = turn_of_quaternion(f.first);
	want = { want.x, -want.y, -want.z };
	test::@check(same_turn(turn_of(right), want),
		"the right leg turns (%.3f, %.3f, %.3f); the reflection asks for (%.3f, %.3f, %.3f)",
		turn_of(right).x, turn_of(right).y, turn_of(right).z, want.x, want.y, want.z);
	test::@check(math::abs(right.move.x + 0.1f) < 1.0e-4f && math::abs(right.move.y - 0.05f) < 1.0e-4f,
		"the slide came through as (%.3f, %.3f, %.3f); x alone should flip", right.move.x, right.move.y, right.move.z);
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.5f)), left_before),
		"a mirrored paste of the left leg rewrote the left leg");
}

fn void a_centre_joint_is_reflected_in_place() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("the hips have no twin, so a mirrored paste reflects them where they are");

	Quaternionf lean = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.3f);
	test::@check(f.app.pose_from_clip(f.clip, 0.0f) && f.app.set_working_pose(f.hips, lean, {}),
		"the hips would not lean");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "the lean would not key");
	f.app.stop_animation();
	f.app.edit_time = 0.0f;
	f.app.select(f.hips);
	test::@check(f.app.copy_pose() == 1, "copy failed");
	f.app.edit_time = 0.5f;
	test::@check(f.app.paste_pose(flipped: true), "the mirrored paste was refused");
	Vec3 want = turn_of_quaternion(lean);
	want = { want.x, -want.y, -want.z };
	test::@check(same_turn(turn_of(f.entry(HIPS, 0.5f)), want),
		"the hips did not lean the other way");
}

fn void mirroring_both_sides_swaps_them_as_one_edit() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("Mirror pose with both legs selected trades their turns");

	Quaternionf right_turn = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), -0.1f);
	test::@check(f.app.pose_from_clip(f.clip, 0.0f) && f.app.set_working_pose(f.right, right_turn, {}),
		"the right leg would not turn");
	f.app.pose_edit_pending = true;
	test::@check(f.app.key_pose_edit(), "the right leg would not key");
	f.app.stop_animation();
	f.app.edit_time = 0.0f;
	f.app.select(f.left);
	f.app.extend_selection(f.right);

	sz cursor = f.app.undo_stack.cursor;
	test::@check(f.app.mirror_pose(), "the mirror was refused");
	test::@check(f.app.undo_stack.cursor == cursor + 1, "one mirror was not one history entry");
	Vec3 want_left = turn_of_quaternion(right_turn);
	want_left = { want_left.x, -want_left.y, -want_left.z };
	Vec3 want_right = turn_of_quaternion(f.first);
	want_right = { want_right.x, -want_right.y, -want_right.z };
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.0f)), want_left), "the left leg did not take the right's reflection");
	test::@check(same_turn(turn_of(f.entry(RIGHT, 0.0f)), want_right), "the right leg did not take the left's reflection");
	test::@check(f.app.anim_pose_clipboard.dots.len == 0, "mirroring in place wrote the clipboard");

	test::@check(f.app.undo() && same_turn(turn_of(f.entry(LEFT, 0.0f)), turn_of_quaternion(f.first))
		&& same_turn(turn_of(f.entry(RIGHT, 0.0f)), turn_of_quaternion(right_turn)),
		"one undo did not put both legs back");
}

fn void mirroring_one_side_writes_only_its_twin() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("Mirror pose with the left leg selected writes the right and leaves the left");

	test::@check(f.app.mirror_pose(), "the mirror was refused");
	Vec3 want = turn_of_quaternion(f.first);
	want = { want.x, -want.y, -want.z };
	test::@check(same_turn(turn_of(f.entry(RIGHT, 0.0f)), want), "the right leg did not take the reflection");
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.0f)), turn_of_quaternion(f.first)), "the left leg was rewritten");
}

fn void pasting_into_a_draft_keeps_its_other_pending_changes() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("a paste over an open draft keys the pasted joints and leaves the rest pending");

	test::@check(f.app.copy_pose() == 1, "copy failed");
	f.app.edit_time = 0.5f;
	test::@check(f.app.pose_from_clip(f.clip, 0.5f), "the draft would not open");
	Quaternionf lean = quaternion::from_axis_angle{float}(((Vec3){ 0, 0, 1 }), 0.3f);
	test::@check(f.app.set_working_pose(f.hips, lean, {}), "the hips would not lean");
	f.app.pose_edit_pending = true;

	test::@check(f.app.paste_pose(), "the paste was refused over a draft");
	test::@check(f.app.pose_edit_active, "the paste closed the draft");
	test::@check(f.app.pose_edit_pending, "the pending hips lean was forgotten");
	test::@check(same_turn(turn_of_quaternion(f.app.working_pose(f.hips).rotation), turn_of_quaternion(lean)),
		"the draft's hips lean was overwritten");
	test::@check(same_turn(turn_of_quaternion(f.app.working_pose(f.left).rotation), turn_of_quaternion(f.first)),
		"the draft does not show the pasted leg");
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.5f)), turn_of_quaternion(f.first)),
		"the clip did not take the pasted leg");
	test::@check(same_turn(turn_of(f.entry(HIPS, 0.5f)), (Vec3){}),
		"the pending hips lean was keyed by the paste");

	// The rest of the draft still keys as it would have.
	test::@check(f.app.key_pose_edit(), "the draft would not key afterwards");
	test::@check(same_turn(turn_of(f.entry(HIPS, 0.5f)), turn_of_quaternion(lean)),
		"Save pose lost the lean that was pending across the paste");
}

fn void the_two_clipboards_do_not_disturb_each_other() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("copying saved keys keeps the pose in hand, and the other way round");

	test::@check(f.app.copy_pose() == 1, "copy failed");
	test::@check(f.app.copy_animation_key(f.clip, 0.5f), "the key copy failed");
	test::@check(f.app.anim_pose_clipboard.dots.len == 1, "copying a key emptied the pose clipboard");
	test::@check(f.app.anim_key_clipboard.keyframes.len == 1, "the key clipboard is empty");
	f.app.select(0);
	test::@check(f.app.copy_pose() > 1, "the whole-pose copy failed");
	test::@check(f.app.anim_key_clipboard.keyframes.len == 1, "copying a pose emptied the key clipboard");
}

fn void a_pose_crosses_into_another_clip() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("a pose copied from one clip pastes into another on the same rig");

	test::@check(f.app.copy_pose() == 1, "copy failed");
	AnimRef target = f.app.new_clip("target", 1.0f, from_rest: true);
	f.app.editing = target;
	f.app.edit_time = 0.0f;
	test::@check(f.app.paste_pose(), "the paste into the other clip was refused");
	test::@check(same_turn(turn_of(f.entry(LEFT, 0.0f)), turn_of_quaternion(f.first)),
		"the target clip did not take the pasted leg");
	test::@check(same_turn(turn_of(f.entry(RIGHT, 0.0f)), (Vec3){}),
		"the target's other leg left rest");
}

fn void an_empty_clipboard_and_a_missing_clip_are_refused_without_history() @test
{
	Figure f;
	bool opened = f.open();
	defer f.close();
	if (!opened) { test::@check(false, "could not build the biped fixture"); return; }
	io::printn("nothing in hand pastes nothing and records nothing");

	sz cursor = f.app.undo_stack.cursor;
	test::@check(!f.app.paste_pose(), "an empty clipboard pasted");
	test::@check(!f.app.paste_pose(flipped: true), "an empty clipboard pasted mirrored");
	test::@check(f.app.undo_stack.cursor == cursor, "a refused paste created history");

	test::@check(f.app.copy_pose() == 1, "copy failed");
	f.app.editing = crig::NO_ANIM;
	test::@check(!f.app.paste_pose() && !f.app.mirror_pose() && f.app.copy_pose() == 0,
		"an operation ran with no clip to edit");
	test::@check(f.app.undo_stack.cursor == cursor, "a refused operation created history");
}

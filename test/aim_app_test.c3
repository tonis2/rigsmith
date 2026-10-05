<*
 Look-at targets as the viewport authors them: adding one, dragging its handle,
 Esc, and keying a target that moved with nothing else changed.

 A figure of hips, spine, neck and head standing straight up; the mesh is the
 shared cube and is never asserted on. Where the head faces is read off the
 pose the app shows (`aim_frame`), the same one the overlay draws.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::aim_app`
*>
module crig_tests::aim_app;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

struct Figure
{
	crig::AppState app;
	uint hips;
	uint spine;
	uint neck;
	uint head;
}

fn bool Figure.open(&self)
{
	self.app = shared_app::open_cube();
	shared_app::attach_library(&self.app);

	self.hips = self.app.doc.add_dot({ 0, 1.0, 0 }, "hips");
	self.spine = self.app.doc.add_dot({ 0, 1.3, 0 }, "spine");
	self.neck = self.app.doc.add_dot({ 0, 1.6, 0 }, "neck");
	self.head = self.app.doc.add_dot({ 0, 1.7, 0 }, "head");
	self.app.doc.connect(self.hips, self.spine);
	self.app.doc.connect(self.spine, self.neck);
	self.app.doc.connect(self.neck, self.head);
	self.app.doc.root_id = self.hips;

	crig::AnimRef clip = self.app.new_clip("look", 1.0f, from_rest: true);
	if (!clip.valid()) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.editing = clip;
	self.app.edit_time = 0.5f;
	return true;
}

fn void Figure.close(&self) => self.app.free();

fn float Figure.height(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	return view.skeleton.height();
}

fn Vec3 Figure.at(&self, uint id) => self.app.dot_position(*self.app.doc.find(id));

fn crig::AnimTemplate* Figure.clip(&self) => self.app.clip(self.app.editing);

// 1 - cos of the angle between where the aimed head's axis points on screen and
// the direction from the head to `target` (model units); 0 when it faces it.
fn float Figure.facing_error(&self, Vec3 target)
{
	crig::AppState* app = &self.app;
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.draft_pose(mem, &view);
	defer pose.free(mem);
	crig::AnimTemplate* clip = self.clip();
	app.apply_clip_aims(&view, *clip, app.editing, app.edit_time, &pose);
	Vec3 position;
	Quaternionf world;
	usz joint = (usz)view.joint_of(self.head);
	if (!crig::aim_frame(&view, pose, joint, &position, &world)) return 1.0f;
	Vec3 facing = world.rotate_vec3(clip.aims[0].forward).normalize();
	return 1.0f - facing.dot((target - position).normalize());
}

<*
 Adding a target turns nothing, keys itself at the edit time, and one undo takes
 it off again.
*>
fn void adding_a_target_changes_no_joint_and_undoes() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	Vec3[4] before = { fixture.at(fixture.hips), fixture.at(fixture.spine), fixture.at(fixture.neck), fixture.at(fixture.head) };
	test::@check(app.aim_index(fixture.head) < 0, "the head started with a target");
	test::@check(app.add_aim(fixture.head), "the target was not added");
	test::@check(app.aim_index(fixture.head) == 0, "the clip does not hold the target");
	test::@check(fixture.clip().aim_targets[0].keys.len == 1 && fixture.clip().aim_targets[0].keys[0].time == 0.5f,
		"the target was not keyed at the edit time");
	test::@check(app.posed_aims.len == 1 && app.posed_aim_links.len == 1 && app.posed_aim_links[0].dot == fixture.head, "no handle or link is shown for it");
	Vec3[4] after = { fixture.at(fixture.hips), fixture.at(fixture.spine), fixture.at(fixture.neck), fixture.at(fixture.head) };
	foreach (i, held : before) test::@check((held - after[i]).length() < 1.0e-4f, "adding the target moved joint %d", i);
	Vec3 handle = app.posed_aims[0].at;
	Vec3 out = handle - fixture.at(fixture.head);
	float height = fixture.height();
	test::@check(math::abs(out.length() - 0.6f * height) < 0.01f && out.z > 0.0f,
		"the target is not 0.6 rig heights in front of the head: %s", out);

	test::@check(!app.add_aim(fixture.head), "a second target was added to the same joint");
	test::@check(app.undo(), "adding the target did not undo");
	test::@check(fixture.clip().aims.len == 0, "undo left the target on the clip");
}

<*
 A held drag moves the target, and the release keys it as one undo step with
 Auto-key on. The head ends up facing where the handle was left.
*>
fn void dragging_the_handle_keys_one_step_and_turns_the_head() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.add_aim(fixture.head), "the target was not added");
	app.auto_key = true;
	sz steps = app.undo_stack.cursor;
	Vec3 start = app.posed_aims[0].at;

	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	test::@check(app.drag.dot == crig::AIM_DRAG_DOT && app.drag.verb == crig::DragVerb.AIM, "the drag does not carry the sentinel");
	Vec3 moved = start + (Vec3){ 0.6f, 0.0f, -0.4f };
	app.aim_target_toward(moved);
	test::@check(app.aim_draft.len == 1, "no draft while dragging");
	test::@check(fixture.facing_error(moved) < 1.0e-3f, "the head does not face the target mid-drag");
	app.end_drag();

	test::@check(app.drag.dot == 0 && app.aim_draft.len == 0, "the drag left a draft behind");
	test::@check(fixture.clip().aim_targets[0].keys.len == 1, "keying at the same time made %d keys", fixture.clip().aim_targets[0].keys.len);
	Vec3 keyed = fixture.clip().aim_targets[0].keys[0].at * fixture.height();
	test::@check((keyed - moved).length() < 1.0e-3f, "the key does not hold the dragged position");
	test::@check(app.undo_stack.cursor == steps + 1, "the drag was %d undo steps", app.undo_stack.cursor - steps);
	test::@check(fixture.facing_error(moved) < 1.0e-3f, "the head does not face the keyed target");

	test::@check(app.undo(), "the drag did not undo");
	Vec3 back = fixture.clip().aim_targets[0].keys[0].at * fixture.height();
	test::@check((back - start).length() < 1.0e-3f, "undo did not put the target back");
}

<*
 Escape mid-drag puts the target back and leaves the history, and the pending
 flag, alone.
*>
fn void escape_puts_the_target_back() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.add_aim(fixture.head), "the target was not added");
	sz steps = app.undo_stack.cursor;
	Vec3 start = app.posed_aims[0].at;

	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	app.aim_target_toward(start + (Vec3){ 0.5f, 0.3f, 0.0f });
	test::@check((app.posed_aims[0].at - start).length() > 0.1f, "the handle did not follow the drag");
	test::@check(app.cancel_drag(), "Esc did not cancel");

	test::@check(app.drag.dot == 0 && app.aim_draft.len == 0, "Esc left a draft");
	test::@check((app.posed_aims[0].at - start).length() < 1.0e-4f, "Esc did not put the target back");
	test::@check(app.undo_stack.cursor == steps && !app.pose_edit_pending, "Esc touched the history or the pending pose");
}

<*
 With Auto-key off the move waits as a pending edit; Key pose with only the
 target changed lands the clip, one undo step, and Revert throws it away.
*>
fn void a_moved_target_alone_keys_and_reverts() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.add_aim(fixture.head), "the target was not added");
	app.auto_key = false;
	Vec3 start = app.posed_aims[0].at;
	float height = fixture.height();

	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	app.aim_target_toward(start + (Vec3){ -0.5f, 0.2f, 0.0f });
	app.end_drag();
	test::@check(app.pose_edit_pending && app.aim_draft.len == 1, "the move is not pending");
	test::@check(app.pose_edit_differs(app.editing, app.edit_time), "a pending target does not count as a change");

	// Revert first: the target goes back to the clip's.
	test::@check(app.discard_pose_edit(), "nothing to discard");
	test::@check(app.aim_draft.len == 0, "the discard kept the draft");
	test::@check((fixture.clip().aim_targets[0].keys[0].at * height - start).length() < 1.0e-3f, "the discard changed the clip");

	test::@check(app.prepare_animation_pose(), "the pose did not open again");
	test::@check(app.begin_aim_drag(0, true), "the second drag did not begin");
	Vec3 moved = start + (Vec3){ -0.5f, 0.2f, 0.0f };
	app.aim_target_toward(moved);
	app.end_drag();
	sz steps = app.undo_stack.cursor;
	test::@check(app.key_pose_edit(CHANGED), "a moved target alone did not key");
	test::@check(app.undo_stack.cursor == steps + 1, "keying was not one undo step");
	test::@check((fixture.clip().aim_targets[0].keys[0].at * height - moved).length() < 1.0e-3f, "the key does not hold the moved target");
	test::@check(app.aim_draft.len == 0, "the draft survived keying");
}

<*
 Remove, mute, spread and influence each land as one undo step.
*>
fn void the_target_ops_land_one_step_each() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	test::@check(app.add_aim(fixture.head), "the target was not added");

	sz steps = app.undo_stack.cursor;
	test::@check(app.set_aim_muted(fixture.head, true) && fixture.clip().aims[0].mute, "mute did not land");
	test::@check(app.set_aim_spread(fixture.head, 2) && fixture.clip().aims[0].spread == 2, "spread did not land");
	test::@check(app.set_aim_influence(fixture.head, 0.5f) && fixture.clip().aims[0].influence == 0.5f, "influence did not land");
	test::@check(!app.set_aim_spread(fixture.head, 9), "a spread of 9 was accepted");
	test::@check(app.undo_stack.cursor == steps + 3, "the ops were not one step each");
	test::@check(app.remove_aim(fixture.head) && fixture.clip().aims.len == 0, "remove did not land");
	test::@check(app.posed_aims.len == 0, "the handle outlived the target");
	test::@check(app.undo() && fixture.clip().aims.len == 1, "remove did not undo");
}

// The aimed, grounded pose's world rotation of a joint, as the overlay shows it.
fn Quaternionf Figure.world_of(&self, uint id)
{
	crig::AppState* app = &self.app;
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.draft_pose(mem, &view);
	defer pose.free(mem);
	crig::AnimTemplate* clip = self.clip();
	app.apply_clip_aims(&view, *clip, app.editing, app.edit_time, &pose);
	Vec3 position;
	Quaternionf world;
	crig::aim_frame(&view, pose, (usz)view.joint_of(id), &position, &world);
	return world;
}

// 1 - cos of the angle between where the lock on `id` faces and `target` (model units).
fn float Figure.lock_error(&self, uint id, Vec3 target)
{
	crig::AppState* app = &self.app;
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.draft_pose(mem, &view);
	defer pose.free(mem);
	crig::AnimTemplate* clip = self.clip();
	app.apply_clip_aims(&view, *clip, app.editing, app.edit_time, &pose);
	Vec3 position;
	Quaternionf world;
	if (!crig::aim_frame(&view, pose, (usz)view.joint_of(id), &position, &world)) return 1.0f;
	sz lock = app.aim_index(id);
	if (lock < 0) return 1.0f;
	Vec3 facing = world.rotate_vec3(clip.aims[(usz)lock].forward).normalize();
	return 1.0f - facing.dot((target - position).normalize());
}

fn void Figure.select_chain(&self)
{
	self.app.select(self.head);
	self.app.extend_selection(self.neck);
	self.app.extend_selection(self.spine);
}

<*
 One target with three joints locked to it: locking is one undo step and moves
 nothing; dragging the target turns all three onto it, parents first.
*>
fn void one_target_moves_three_locked_joints_as_one_step() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	app.auto_key = true;
	Quaternionf[3] before = { fixture.world_of(fixture.spine), fixture.world_of(fixture.neck), fixture.world_of(fixture.head) };
	Vec3[3] where = { fixture.at(fixture.spine), fixture.at(fixture.neck), fixture.at(fixture.head) };

	fixture.select_chain();
	sz steps = app.undo_stack.cursor;
	test::@check(app.add_aim_target(), "the target was not added");
	test::@check(app.undo_stack.cursor == steps + 1, "adding and locking was %d undo steps", app.undo_stack.cursor - steps);
	test::@check(fixture.clip().aim_targets.len == 1 && fixture.clip().aims.len == 3, "the clip does not hold a target and three locks");
	test::@check(app.posed_aims.len == 1 && app.posed_aim_links.len == 3, "the overlay does not show one ring and three links");
	test::@check(app.aim_target_selected == "Target 1", "the new target was not selected");

	// Locking captured each joint's facing, so nothing turned.
	Quaternionf[3] after = { fixture.world_of(fixture.spine), fixture.world_of(fixture.neck), fixture.world_of(fixture.head) };
	foreach (i, held : before) test::@check(math::abs(held.v.dot(after[i].v)) > 0.99999f, "locking turned joint %d", i);
	Vec3[3] now = { fixture.at(fixture.spine), fixture.at(fixture.neck), fixture.at(fixture.head) };
	foreach (i, held : where) test::@check((held - now[i]).length() < 1.0e-4f, "locking moved joint %d", i);

	Vec3 start = app.posed_aims[0].at;
	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	Vec3 moved = start + (Vec3){ 0.7f, 0.2f, -0.3f };
	app.aim_target_toward(moved);
	foreach (id : (uint[3]){ fixture.spine, fixture.neck, fixture.head })
	{
		test::@check(fixture.lock_error(id, moved) < 1.0e-3f, "joint %d does not face the dragged target", id);
	}
	app.end_drag();
	test::@check(app.undo_stack.cursor == steps + 2, "the drag was not one more undo step");
	foreach (id : (uint[3]){ fixture.spine, fixture.neck, fixture.head })
	{
		test::@check(fixture.lock_error(id, moved) < 1.0e-3f, "joint %d does not face the keyed target", id);
	}
	test::@check(app.undo() && app.undo(), "the steps did not undo");
	test::@check(fixture.clip().aims.len == 0 && fixture.clip().aim_targets.len == 0, "undo left locks or a target behind");
}

<*
 A chain locked together lands every joint on the target: the child aims after
 its parent has turned.
*>
fn void a_chain_locked_together_lands_each_joint_on_the_target() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	fixture.select_chain();
	test::@check(app.add_aim_target(), "the target was not added");
	Vec3 far = { -0.8f, 1.0f, 0.9f };
	app.auto_key = false;
	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	app.aim_target_toward(far);
	app.end_drag();
	foreach (id : (uint[3]){ fixture.spine, fixture.neck, fixture.head })
	{
		test::@check(fixture.lock_error(id, far) < 1.0e-3f, "joint %d is off the target", id);
	}
}

<*
 The smart spread: a joint locked alone spreads over 3, several locked at once
 over 1 each.
*>
fn void smart_spread_follows_the_count() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;

	app.select(fixture.head);
	test::@check(app.add_aim_target(), "the target was not added for one joint");
	test::@check(fixture.clip().aims.len == 1 && fixture.clip().aims[0].spread == 3, "one joint did not get spread 3");

	app.select(fixture.neck);
	app.extend_selection(fixture.spine);
	test::@check(app.lock_selection_to("Target 1"), "the lock did not land");
	test::@check(fixture.clip().aims.len == 3, "the locks are %d", fixture.clip().aims.len);
	sz neck = app.aim_index(fixture.neck);
	sz spine = app.aim_index(fixture.spine);
	test::@check(neck >= 0 && spine >= 0 && fixture.clip().aims[(usz)neck].spread == 1 && fixture.clip().aims[(usz)spine].spread == 1,
		"two joints did not get spread 1");

	app.select(fixture.hips);
	test::@check(app.lock_selection_to("Target 1"), "the lone lock did not land");
	sz hips = app.aim_index(fixture.hips);
	test::@check(hips >= 0 && fixture.clip().aims[(usz)hips].spread == 3, "a lone lock did not get spread 3");
}

<*
 A joint locked to another target is re-pointed with its settings and nothing
 turns; unlocking takes the locks off and keeps the targets.
*>
fn void re_pointing_keeps_settings_and_unlock_keeps_the_target() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	app.select(fixture.head);
	test::@check(app.add_aim_target(), "the first target was not added");
	test::@check(app.set_aim_spread(fixture.head, 2) && app.set_aim_influence(fixture.head, 0.5f), "the settings did not land");
	app.select(fixture.neck);
	test::@check(app.add_aim_target(), "the second target was not added");
	test::@check(fixture.clip().aim_targets.len == 2 && app.aim_target_selected == "Target 2", "the second target is not there");

	Quaternionf was = fixture.world_of(fixture.head);
	app.select(fixture.head);
	test::@check(app.lock_selection_to("Target 2"), "the re-point did not land");
	sz head = app.aim_index(fixture.head);
	test::@check(head >= 0 && fixture.clip().aims[(usz)head].target == "Target 2", "the head was not re-pointed");
	test::@check(fixture.clip().aims[(usz)head].spread == 2 && fixture.clip().aims[(usz)head].influence == 0.5f,
		"the re-point lost the settings");
	test::@check(math::abs(was.v.dot(fixture.world_of(fixture.head).v)) > 0.99999f, "the re-point turned the head");

	app.select(fixture.head);
	app.extend_selection(fixture.neck);
	sz steps = app.undo_stack.cursor;
	test::@check(app.unlock_selection(), "unlock did not land");
	test::@check(app.undo_stack.cursor == steps + 1, "unlock was not one step");
	test::@check(fixture.clip().aims.len == 0 && fixture.clip().aim_targets.len == 2, "unlock dropped a target or left a lock");
	test::@check(!app.unlock_joint(fixture.head), "unlocking an unlocked joint was accepted");
}

<*
 Removing a target takes its locks with it, forgets its selection and its
 draft, and undoes as one step; muting a target is one step too.
*>
fn void removing_a_target_drops_its_locks_and_selection() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	fixture.select_chain();
	test::@check(app.add_aim_target(), "the target was not added");
	sz steps = app.undo_stack.cursor;
	test::@check(app.set_target_muted("Target 1", true) && fixture.clip().aim_targets[0].mute, "mute did not land");
	test::@check(app.posed_aims[0].muted && app.posed_aim_links[0].muted, "the overlay does not show it muted");
	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	app.aim_target_toward(app.posed_aims[0].at + (Vec3){ 0.1f, 0.0f, 0.0f });
	app.end_drag();
	test::@check(app.remove_aim_target("Target 1"), "remove did not land");
	test::@check(fixture.clip().aims.len == 0 && fixture.clip().aim_targets.len == 0, "the target or its locks survived");
	test::@check(app.aim_target_selected.len == 0 && app.aim_draft.len == 0, "the selection or draft survived");
	test::@check(app.posed_aims.len == 0 && app.posed_aim_links.len == 0, "the handles outlived the target");
	test::@check(app.undo(), "remove did not undo");
	test::@check(fixture.clip().aims.len == 3 && fixture.clip().aim_targets.len == 1, "undo did not bring them back");
	test::@check(!app.remove_aim_target("Nope"), "a missing target was removed");
}

<*
 A target with no joint locked to it is still a thing: it is placed in front of
 the rig, dragged, and Esc puts it back.
*>
fn void a_lockless_target_drags_and_escapes() @test
{
	Figure fixture;
	test::@check(fixture.open(), "the fixture did not open");
	defer fixture.close();
	crig::AppState* app = &fixture.app;
	app.select(0);
	test::@check(app.add_aim_target(), "the target was not added with nothing selected");
	test::@check(fixture.clip().aims.len == 0 && fixture.clip().aim_targets.len == 1, "the clip does not hold a lone target");
	test::@check(app.posed_aims.len == 1 && app.posed_aim_links.len == 0, "no lone ring is shown");
	float height = fixture.height();
	test::@check(math::abs(app.posed_aims[0].at.z - 0.6f * height) < 0.01f, "the target is not in front of the rig: %s", app.posed_aims[0].at);

	sz steps = app.undo_stack.cursor;
	Vec3 start = app.posed_aims[0].at;
	test::@check(app.begin_aim_drag(0, true), "the drag did not begin");
	test::@check(app.drag.dot == crig::AIM_DRAG_DOT, "the drag does not carry the sentinel");
	app.aim_target_toward(start + (Vec3){ 0.4f, 0.1f, 0.0f });
	test::@check((app.posed_aims[0].at - start).length() > 0.1f, "the ring did not follow");
	test::@check(app.lock_drag(crig::DragAxis.X), "an axis key was refused");
	test::@check(app.cancel_drag(), "Esc did not cancel");
	test::@check(app.drag.dot == 0 && app.aim_draft.len == 0, "Esc left a drag or draft");
	test::@check((app.posed_aims[0].at - start).length() < 1.0e-4f, "Esc did not put the ring back");
	test::@check(app.undo_stack.cursor == steps, "Esc touched the history");
}

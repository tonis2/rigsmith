<*
 Ghosts follow a pose edit on both sides of the playhead (`app/onion.c3`).

     `c3c test --trust=full --test-filter crig_tests::onion_pose_edit`
*>
module crig_tests::onion_pose_edit;

import crig;
import rig;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;

struct Fig
{
	crig::AppState app;
	uint thigh;
	uint knee;
}

fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

fn bool Fig.key(&self, float time, float angle)
{
	if (!self.app.pose_from_clip(self.app.editing, time)) return false;
	self.app.edit_time = time;
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), angle);
	if (!self.app.set_working_pose(self.thigh, turn, {})) return false;
	self.app.pose_edit_pending = true;
	return self.app.key_pose_edit();
}

// A clip keyed at `times` (angles 0.3, -0.4, 0.8 ...), parked at `playhead`.
fn bool Fig.open(&self, float[] times, float playhead)
{
	self.app = shared_app::open();
	if (!self.app.apply_plan_named("biped")) return false;
	self.thigh = dot_named(&self.app, "thigh_L");
	if (self.thigh == 0) return false;
	foreach (dot : self.app.doc.dots.array_view())
	{
		if (dot.id != self.thigh && self.app.parent_dot(dot.id) == self.thigh) { self.knee = dot.id; break; }
	}
	if (self.knee == 0) return false;
	AnimRef clip = self.app.new_clip("edit", 1.0f, from_rest: true, loop: false);
	if (!clip.valid()) return false;
	self.app.editing = clip;
	float[3] angles = { 0.3f, -0.4f, 0.8f };
	foreach (usz i, t : times)
	{
		if (!self.key(t, angles[i % 3])) return false;
	}
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.anim_fps = 30;
	self.app.config.show_ghosts = true;
	self.app.config.ghost_past = 3;
	self.app.config.ghost_future = 3;
	self.app.config.ghost_step = 3;
	self.app.auto_key = true;
	self.app.stage = POSE_STAGE;
	self.app.select(self.knee);
	return self.app.park_clip(self.app.editing, playhead);
}

fn void Fig.close(&self) => self.app.free();

// Copies of the ghost palettes now.
fn Matrix4f[][] snapshot(crig::AppState* app)
{
	GhostPose[] ghosts = app.ghost_poses();
	Matrix4f[][] out = alloc::new_array(mem, Matrix4f[], ghosts.len);
	foreach (usz i, ghost : ghosts)
	{
		out[i] = alloc::new_array(mem, Matrix4f, ghost.palette.len);
		foreach (usz j, m : ghost.palette) out[i][j] = m;
	}
	return out;
}

fn void release(Matrix4f[][] s)
{
	foreach (p : s) alloc::free(mem, p);
	alloc::free(mem, s);
}

fn bool differs(Matrix4f[] a, Matrix4f[] b)
{
	if (a.len != b.len) return true;
	foreach (usz i, m : a)
	{
		for (usz k = 0; k < 16; k++)
		{
			if (math::abs(m.m[k] - b[i].m[k]) > 1e-5f) return true;
		}
	}
	return false;
}

struct Moved
{
	bool past;
	bool future;
	usz past_count;
	usz future_count;
}

fn Moved moved_between(crig::AppState* app, Matrix4f[][] before, Matrix4f[][] after)
{
	GhostPose[] ghosts = app.ghost_poses();
	Moved m;
	if (before.len != after.len) { m.past = m.future = true; return m; }
	foreach (usz i, ghost : ghosts)
	{
		if (ghost.before) { m.past_count++; } else { m.future_count++; }
		if (!differs(before[i], after[i])) continue;
		if (ghost.before) { m.past = true; } else { m.future = true; }
	}
	return m;
}

// Drags the selected thigh like the viewport does.
fn bool drag_thigh(crig::AppState* app, bool frames = false, bool release = true)
{
	if (!app.begin_pose()) return false;
	for (int i = 1; i <= 4; i++)
	{
		(void)app.pose_toward(app.drag.from + (Vec3){ 0.0f, 0.0f, 0.05f * (float)i });
		if (frames) (void)app.ghost_poses();
	}
	if (release) app.end_drag();
	return true;
}

fn bool same_snapshot(Matrix4f[][] a, Matrix4f[][] b)
{
	if (a.len != b.len) return false;
	foreach (usz i, p : a) { if (differs(p, b[i])) return false; }
	return true;
}

// The ghosts now, against a cache thrown away and sampled again.
fn bool ghosts_are_fresh(crig::AppState* app)
{
	Matrix4f[][] held = snapshot(app);
	defer release(held);
	app.drop_ghosts();
	Matrix4f[][] fresh = snapshot(app);
	defer release(fresh);
	return same_snapshot(held, fresh);
}

// A release with Auto-key on moves every ghost the new key reaches, on both sides.
fn void an_auto_keyed_drag_moves_both_sides_of_the_playhead() @test
{
	float[2] ends = { 0.0f, 1.0f };
	Fig f;
	test::@check(f.open(ends[..], 0.5f), "could not build the figure");
	defer f.close();
	Matrix4f[][] before = snapshot(&f.app);
	defer release(before);
	test::@check(drag_thigh(&f.app, true), "the drag did not begin");
	Matrix4f[][] after = snapshot(&f.app);
	defer release(after);
	Moved m = moved_between(&f.app, before, after);
	test::@check(m.past && m.future, "a key between two others left a side of ghosts alone: past %s future %s", m.past, m.future);
	test::@check(ghosts_are_fresh(&f.app), "the ghosts are not what the clip now plays");
}

// An unkeyed edit shows in the ghosts as the key it would become, on both sides,
// and keying it afterwards changes nothing about them.
fn void a_pending_edit_is_in_the_ghosts_before_it_is_keyed() @test
{
	float[2] ends = { 0.0f, 1.0f };
	Fig f;
	test::@check(f.open(ends[..], 0.5f), "could not build the figure");
	defer f.close();
	f.app.auto_key = false;
	Matrix4f[][] before = snapshot(&f.app);
	defer release(before);
	usz keys = f.app.clip(f.app.editing).keyframes.len;
	sz cursor = f.app.undo_stack.cursor;
	test::@check(drag_thigh(&f.app, true), "the drag did not begin");
	test::@check(f.app.pose_edit_pending, "the edit is not pending");
	Matrix4f[][] drafted = snapshot(&f.app);
	defer release(drafted);
	Moved m = moved_between(&f.app, before, drafted);
	test::@check(m.past && m.future, "the ghosts ignore the unkeyed edit: past %s future %s", m.past, m.future);
	// Nothing was written to get them.
	test::@check(f.app.clip(f.app.editing).keyframes.len == keys, "the ghosts wrote a key");
	test::@check(f.app.undo_stack.cursor == cursor, "the ghosts touched the undo stack");

	test::@check(f.app.key_pose_edit(CHANGED), "could not key the edit");
	Matrix4f[][] keyed = snapshot(&f.app);
	defer release(keyed);
	test::@check(same_snapshot(drafted, keyed), "keying the edit moved the ghosts it had already drawn");
	test::@check(ghosts_are_fresh(&f.app), "the keyed ghosts are not what the clip plays");

	// Reverting puts them back.
	test::@check(f.app.undo(), "could not undo the key");
	Matrix4f[][] undone = snapshot(&f.app);
	defer release(undone);
	test::@check(same_snapshot(before, undone), "the ghosts did not return after the key was undone");
}

fn void ghosts_hold_through_a_drag_follow_its_release_and_a_revert() @test
{
	float[2] ends = { 0.0f, 1.0f };
	Fig f;
	test::@check(f.open(ends[..], 0.5f), "could not build the figure");
	defer f.close();
	Matrix4f[][] before = snapshot(&f.app);
	defer release(before);
	uint builds = f.app.ghosts.builds;
	// Held: the ghosts stay as they were, so the drag costs no re-sampling.
	test::@check(f.app.begin_pose(), "the drag did not begin");
	for (int i = 1; i <= 12; i++)
	{
		(void)f.app.pose_toward(f.app.drag.from + (Vec3){ 0.0f, 0.0f, 0.02f * (float)i });
		(void)f.app.ghost_poses();
	}
	test::@check(f.app.drag.dot != 0, "the drag ended on its own");
	test::@check(f.app.ghosts.builds == builds, "the ghosts were re-sampled during the drag: %d", f.app.ghosts.builds - builds);
	f.app.auto_key = false;
	f.app.end_drag();
	Matrix4f[][] released = snapshot(&f.app);
	defer release(released);
	test::@check(!same_snapshot(before, released), "the released drag left the ghosts alone");

	// Throwing the edit away puts the saved clip back on the ghosts.
	test::@check(f.app.discard_pose_edit(), "there was no edit to throw away");
	Matrix4f[][] reverted = snapshot(&f.app);
	defer release(reverted);
	test::@check(same_snapshot(before, reverted), "the ghosts still show the reverted edit");
}

// Which sides move for a drag, with Auto-key on and off, is the same: both when
// the neighbouring keys are far, only the side whose segment the new key lands in
// when the other side's ghosts lie past a neighbouring key.
fn void only_ghosts_the_new_key_reaches_move_whatever_auto_key_says() @test
{
	float[5] keys = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	float[3] playheads = { 0.4f, 0.6f, 0.25f };
	bool[3] want_past = { true, false, true };
	bool[3] want_future = { false, true, true };
	bool[2] modes = { true, false };
	foreach (auto_key : modes)
	{
		foreach (usz n, p : playheads)
		{
			Fig f;
			test::@check(f.open(keys[..], p), "could not build the figure");
			f.app.auto_key = auto_key;
			Matrix4f[][] before = snapshot(&f.app);
			test::@check(drag_thigh(&f.app, true), "the drag did not begin");
			Matrix4f[][] after = snapshot(&f.app);
			Moved m = moved_between(&f.app, before, after);
			test::@check(m.past == want_past[n] && m.future == want_future[n],
				"auto-key %s, playhead %f: past %s future %s", auto_key, p, m.past, m.future);
			test::@check(ghosts_are_fresh(&f.app), "stale ghosts, auto-key %s, playhead %f", auto_key, p);
			release(before); release(after);
			f.close();
		}
	}
}

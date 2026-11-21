<*
 Ghost poses and the selected joint's motion path (`app/onion.c3`).

     `c3c test --trust=full --test-filter crig_tests::onion`

 A biped with the left thigh keyed at 0, 0.5 and 1 s. A ghost must be the pose
 the rig shows parked on its key, and a path sample the joint's position parked
 at that time; both caches hold until the clip, the rig or the question moves.
*>
module crig_tests::onion;

import crig;
import rig;
import crig_tests::shared_app;
import crig_tests::helpers;
import std::core::test;
import std::math;
import std::math::quaternion;

struct Figure
{
	crig::AppState app;
	uint left;
	uint knee;
}

// A joint whose parent is `id`: the next one down the leg.
fn uint child_of(crig::AppState* app, uint id)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.id != id && app.parent_dot(dot.id) == id) return dot.id;
	}
	return 0;
}

fn bool Figure.open(&self)
{
	self.app = shared_app::open();
	if (!self.app.apply_plan_named("biped")) return false;
	self.left = helpers::dot_named(&self.app, "thigh_L");
	if (self.left == 0) return false;
	self.knee = child_of(&self.app, self.left);
	if (self.knee == 0) return false;
	AnimRef clip = self.app.new_clip("onion", 1.0f, from_rest: true, loop: false);
	if (!clip.valid()) return false;
	self.app.editing = clip;
	if (!self.key_left(0.0f, 0.5f)) return false;
	if (!self.key_left(0.5f, -0.4f)) return false;
	if (!self.key_left(1.0f, 0.9f)) return false;
	self.app.stop_animation();
	self.app.undo_stack.clear();
	return self.app.park_clip(self.app.editing, 0.75f);
}

fn bool Figure.key_left(&self, float time, float angle)
{
	if (!self.app.pose_from_clip(self.app.editing, time)) return false;
	self.app.edit_time = time;
	Quaternionf turn = quaternion::from_axis_angle{float}(((Vec3){ 1, 0, 0 }), angle);
	if (!self.app.set_working_pose(self.left, turn, {})) return false;
	self.app.pose_edit_pending = true;
	return self.app.key_pose_edit();
}

fn void Figure.close(&self) => self.app.free();

// Where the rig shows `id` parked at `time`.
fn Vec3 parked_at(crig::AppState* app, float time, uint id)
{
	(void)app.scrub_to(time);
	return app.dot_position(*app.doc.find(id));
}

fn Vec3 ghost_joint(GhostPose ghost, uint id)
{
	foreach (posed : ghost.dots)
	{
		if (posed.dot == id) return posed.at;
	}
	return { 1e30f, 1e30f, 1e30f };
}

// Times of the ghosts for a clip of `duration` seconds at 10 fps.
fn usz times_for(float duration, bool loop, float playhead, int past, int future, int step,
	float[] times, bool[] before, int[] steps)
{
	return crig::ghost_times(duration, loop, playhead, 10, past, future, step, times, before, steps);
}

<*
 Ghost times: every n frames either side of the playhead, nearest first, nothing
 off the end of a clip that does not loop, round the ends of one that does, and
 never more than `MAX_GHOSTS` however many are asked for.
*>
fn void ghost_times_are_spaced_wrapped_and_capped() @test
{
	float[crig::MAX_GHOSTS] times;
	bool[crig::MAX_GHOSTS] before;
	int[crig::MAX_GHOSTS] steps;

	// One frame apart: 0.4, 0.3, 0.2 behind 0.5 and 0.6, 0.7, 0.8 ahead, nearest first.
	usz count = times_for(1.0f, false, 0.5f, 3, 3, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)6);
	float[6] want = { 0.4f, 0.3f, 0.2f, 0.6f, 0.7f, 0.8f };
	foreach (usz i, t : want)
	{
		test::@check(math::is_approx(times[i], t, 1e-4f), "ghost %d is at %f, not %f", i, times[i], t);
		test::@check(before[i] == (i < 3), "ghost %d is on the wrong side", i);
		test::eq(steps[i], (int)(i % 3) + 1);
	}

	// Every second frame: twice as far apart, and what falls off the clip is skipped.
	count = times_for(1.0f, false, 0.5f, 3, 3, 2, times[..], before[..], steps[..]);
	test::eq(count, (usz)4);
	test::@check(math::is_approx(times[0], 0.3f, 1e-4f) && math::is_approx(times[1], 0.1f, 1e-4f), "past ghosts at two frames are not 0.3 and 0.1");
	test::@check(math::is_approx(times[2], 0.7f, 1e-4f) && math::is_approx(times[3], 0.9f, 1e-4f), "future ghosts at two frames are not 0.7 and 0.9");

	// Nothing past the end of a clip that does not loop, and a side can be none.
	count = times_for(1.0f, false, 0.95f, 2, 3, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)2);
	test::@check(before[0] && before[1], "a ghost ahead of the end of the clip was drawn");
	count = times_for(1.0f, false, 0.5f, 0, 2, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)2);
	test::@check(!before[0] && !before[1], "Past 0 still drew a ghost behind");
	test::eq(times_for(1.0f, false, 0.5f, 0, 0, 1, times[..], before[..], steps[..]), (usz)0);
	test::eq(times_for(0.0f, false, 0.0f, 3, 3, 1, times[..], before[..], steps[..]), (usz)0);

	// Round a looping clip: 0.9 + 0.2 and 0.9 + 0.3 come round to 0.1 and 0.2.
	count = times_for(1.0f, true, 0.9f, 0, 3, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)3);
	test::@check(math::is_approx(times[0], 1.0f, 1e-4f) && math::is_approx(times[1], 0.1f, 1e-4f) && math::is_approx(times[2], 0.2f, 1e-4f),
		"the future ghosts did not wrap: %f %f %f", times[0], times[1], times[2]);
	// The same in front of the first frame.
	count = times_for(1.0f, true, 0.1f, 3, 0, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)3);
	test::@check(math::is_approx(times[0], 0.0f, 1e-4f) && math::is_approx(times[1], 0.9f, 1e-4f) && math::is_approx(times[2], 0.8f, 1e-4f),
		"the past ghosts did not wrap: %f %f %f", times[0], times[1], times[2]);

	// More ghosts than the clip has frames: none lands on the playhead or on another.
	count = times_for(1.0f, true, 0.5f, 30, 30, 1, times[..], before[..], steps[..]);
	test::@check(count > 0 && count <= (usz)crig::MAX_GHOSTS, "a long wrap drew %d ghosts", count);
	for (usz i = 0; i < count; i++)
	{
		test::@check(!math::is_approx(times[i], 0.5f, 1e-4f), "a ghost sits on the playhead");
		for (usz j = i + 1; j < count; j++) test::@check(!math::is_approx(times[i], times[j], 1e-4f), "two ghosts share a time");
	}

	// Capped: the arrays are MAX_GHOSTS long, and the cap splits evenly.
	float[crig::MAX_GHOSTS] fades;
	count = crig::ghost_times(100.0f, false, 50.0f, 10, 30, 30, 1, times[..], before[..], steps[..], fades[..]);
	test::eq(count, (usz)crig::MAX_GHOSTS);
	count = crig::ghost_times(100.0f, false, 50.0f, 10, 30, 10, 1, times[..], before[..], steps[..], fades[..]);
	test::eq(count, (usz)40);

	int past, future;
	crig::ghost_counts(30, 30, &past, &future);
	test::@check(past + future == crig::MAX_GHOSTS && past == future, "the cap does not split evenly: %d %d", past, future);
	crig::ghost_counts(30, 10, &past, &future);
	test::@check(past == 30 && future == 10, "a request under the cap was trimmed");
}

fn void ghosts_are_the_parked_poses_at_their_frames() @test
{
	Figure f;
	test::@check(f.open(), "could not build the figure");
	defer f.close();
	f.app.anim_fps = 30;
	f.app.config.ghost_past = 2;
	f.app.config.ghost_future = 2;
	f.app.config.ghost_step = 3;
	f.app.config.ghost_opacity = 0.0f;

	test::eq(f.app.ghost_poses().len, (sz)0);
	f.app.config.show_ghosts = true;
	// 0.75 s, three frames at 30 fps is 0.1 s: 0.65 and 0.55 behind, 0.85 and 0.95 ahead.
	GhostPose[] ghosts = f.app.ghost_poses();
	test::eq(ghosts.len, (sz)4);
	float[4] want = { 0.65f, 0.55f, 0.85f, 0.95f };
	foreach (usz i, t : want)
	{
		test::@check(math::is_approx(ghosts[i].time, t, 1e-4f), "ghost %d is at %f, not %f", i, ghosts[i].time, t);
		test::@check(ghosts[i].before == (i < 2), "ghost %d is on the wrong side", i);
	}
	test::@check(ghosts[0].fade > ghosts[1].fade && ghosts[2].fade > ghosts[3].fade, "ghosts do not fade outwards");
	test::@check(math::is_approx(ghosts[0].fade, 1.0f, 1e-4f) && math::is_approx(ghosts[2].fade, 1.0f, 1e-4f), "the nearest ghosts are not full strength");
	test::@check(math::is_approx(f.app.ghost_strength(), crig::DEFAULT_GHOST_OPACITY, 1e-4f), "an unset opacity is not the default");
	f.app.config.ghost_opacity = 0.6f;
	test::@check(math::is_approx(f.app.ghost_strength(), 0.6f, 1e-4f), "the opacity is not read");

	// What the mesh needs: a palette per ghost, one matrix per joint.
	foreach (ghost : ghosts) test::eq(ghost.palette.len, (sz)f.app.doc.dots.len());

	sz count = f.app.doc.dots.len();
	Vec3[] seen = alloc::new_array(mem, Vec3, count * 4);
	defer alloc::free(mem, seen);
	foreach (usz g, ghost : ghosts)
	{
		foreach (usz i, dot : f.app.doc.dots.array_view()) seen[g * (usz)count + i] = ghost_joint(ghost, dot.id);
	}
	test::@check(!helpers::near3(ghost_joint(ghosts[0], f.knee), ghost_joint(ghosts[3], f.knee), 1e-4f), "the first and last ghost do not differ at the knee");
	foreach (usz g, t : want)
	{
		foreach (usz i, dot : f.app.doc.dots.array_view())
		{
			test::@check(helpers::near3(seen[g * (usz)count + i], parked_at(&f.app, t, dot.id), 1e-4f),
				"ghost %d is not the pose parked at %f (%s)", g, t, dot.name);
		}
	}

	// Running: no ghosts.
	f.app.resume_clip();
	test::eq(f.app.ghost_poses().len, (sz)0);
}

fn void the_ghost_cache_holds_and_follows_settings_edits_and_undo() @test
{
	Figure f;
	test::@check(f.open(), "could not build the figure");
	defer f.close();
	f.app.anim_fps = 30;
	f.app.config.show_ghosts = true;
	f.app.config.ghost_past = 3;
	f.app.config.ghost_future = 3;
	f.app.config.ghost_step = 1;

	Vec3 before = ghost_joint(f.app.ghost_poses()[0], f.knee);
	uint builds = f.app.ghosts.builds;
	(void)f.app.ghost_poses();
	test::eq(f.app.ghosts.builds, builds);

	// The playhead moving, or a setting, is a new set of times.
	(void)f.app.scrub_to(0.6f);
	(void)f.app.ghost_poses();
	test::eq(f.app.ghosts.builds, builds + 1);
	(void)f.app.ghost_poses();
	test::eq(f.app.ghosts.builds, builds + 1);
	f.app.config.ghost_step = 2;
	test::eq(f.app.ghost_poses().len, (sz)6);
	test::eq(f.app.ghosts.builds, builds + 2);
	f.app.config.ghost_step = 1;
	f.app.config.ghost_future = 0;
	test::eq(f.app.ghost_poses().len, (sz)3);
	f.app.config.ghost_future = 3;

	// Rekeying the 0.5 s pose is an edit: the ghost between 0.5 and 1 follows it.
	(void)f.app.scrub_to(0.75f);
	before = ghost_joint(f.app.ghost_poses()[0], f.knee);
	test::@check(f.key_left(0.5f, 0.2f), "could not rekey 0.5 s");
	test::@check(f.app.park_clip(f.app.editing, 0.75f), "could not park again");
	Vec3 edited = ghost_joint(f.app.ghost_poses()[0], f.knee);
	test::@check(!helpers::near3(edited, before, 1e-4f), "the ghost did not follow the edit");
	test::@check(helpers::near3(edited, parked_at(&f.app, f.app.ghost_poses()[0].time, f.knee), 1e-4f), "the edited ghost is not the parked pose");

	(void)f.app.scrub_to(0.75f);
	test::@check(f.app.undo(), "could not undo the rekey");
	Vec3 undone = ghost_joint(f.app.ghost_poses()[0], f.knee);
	test::@check(helpers::near3(undone, before, 1e-4f), "the ghost did not follow the undo");
}

fn void the_motion_path_samples_the_selected_joint() @test
{
	Figure f;
	test::@check(f.open(), "could not build the figure");
	defer f.close();
	f.app.anim_fps = 30;
	f.app.select(f.knee);

	test::@check(f.app.selected_motion_path() == null, "the path draws while switched off");
	f.app.config.show_motion_path = true;
	MotionPath* path = f.app.selected_motion_path();
	test::@check(path != null, "no path for the selected knee");
	test::eq(path.points.len, (sz)31);
	test::eq(path.key_times.len, (sz)3);
	test::@check(path.key_times[0] == 0.0f && path.key_times[1] == 0.5f && path.key_times[2] == 1.0f, "key dots are not at the key times");

	Vec3[31] points;
	foreach (usz i, p : path.points) points[i] = p;
	Vec3[3] keys = { path.key_points[0], path.key_points[1], path.key_points[2] };
	float[3] key_times = { 0.0f, 0.5f, 1.0f };
	usz[4] probes = { 0, 7, 15, 30 };
	foreach (i : probes)
	{
		test::@check(helpers::near3(points[i], parked_at(&f.app, (float)i / 30.0f, f.knee), 1e-4f), "path sample %d is not the parked knee", i);
	}
	foreach (usz k, t : key_times)
	{
		test::@check(helpers::near3(keys[k], parked_at(&f.app, t, f.knee), 1e-4f), "key dot %d is not the knee at its key", k);
		test::@check(helpers::near3(keys[k], points[(usz)(t * 30.0f + 0.5f)], 1e-4f), "key dot %d is off the path", k);
	}

	// Held while nothing moves, rebuilt for another joint, a new fps and an undo.
	path = f.app.selected_motion_path();
	uint builds = path.builds;
	(void)f.app.scrub_to(0.3f);
	test::eq(f.app.selected_motion_path().builds, builds);
	f.app.select(f.left);
	test::eq(f.app.selected_motion_path().builds, builds + 1);
	f.app.select(f.knee);
	f.app.anim_fps = 60;
	test::eq(f.app.selected_motion_path().points.len, (sz)61);
	test::eq(f.app.selected_motion_path().builds, builds + 2);
	test::@check(f.key_left(0.5f, 0.2f), "could not rekey 0.5 s");
	test::@check(f.app.park_clip(f.app.editing, 0.3f), "could not park again");
	Vec3 edited = f.app.selected_motion_path().key_points[1];
	test::@check(!helpers::near3(edited, keys[1], 1e-4f), "the path did not follow the edit");
	test::@check(f.app.undo(), "could not undo");
	test::@check(helpers::near3(f.app.selected_motion_path().key_points[1], keys[1], 1e-4f), "the path did not follow the undo");
}

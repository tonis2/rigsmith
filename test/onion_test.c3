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
import std::core::test;
import std::math;
import std::math::quaternion;

struct Figure
{
	crig::AppState app;
	uint left;
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
	self.left = dot_named(&self.app, "thigh_L");
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

fn bool near(Vec3 a, Vec3 b) => (a - b).length() < 1e-4f;

fn Vec3 ghost_joint(GhostPose ghost, uint id)
{
	foreach (posed : ghost.dots)
	{
		if (posed.dot == id) return posed.at;
	}
	return { 1e30f, 1e30f, 1e30f };
}

fn bool nearly(float a, float b) => math::abs(a - b) < 1e-4f;

// Times of the ghosts for a clip of `duration` seconds at 10 fps.
fn usz times_for(float duration, bool loop, float playhead, int past, int future, int step,
	float[] times, bool[] before, int[] steps)
{
	return crig::ghost_times(duration, loop, playhead, 10, past, future, step, times, before, steps);
}

fn void ghosts_are_spaced_every_n_frames_either_side_of_the_playhead() @test
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
		test::@check(nearly(times[i], t), "ghost %d is at %f, not %f", i, times[i], t);
		test::@check(before[i] == (i < 3), "ghost %d is on the wrong side", i);
		test::eq(steps[i], (int)(i % 3) + 1);
	}

	// Every second frame: twice as far apart, and what falls off the clip is skipped.
	count = times_for(1.0f, false, 0.5f, 3, 3, 2, times[..], before[..], steps[..]);
	test::eq(count, (usz)4);
	test::@check(nearly(times[0], 0.3f) && nearly(times[1], 0.1f), "past ghosts at two frames are not 0.3 and 0.1");
	test::@check(nearly(times[2], 0.7f) && nearly(times[3], 0.9f), "future ghosts at two frames are not 0.7 and 0.9");

	// Nothing past the end of a clip that does not loop, and a side can be none.
	count = times_for(1.0f, false, 0.95f, 2, 3, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)2);
	test::@check(before[0] && before[1], "a ghost ahead of the end of the clip was drawn");
	count = times_for(1.0f, false, 0.5f, 0, 2, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)2);
	test::@check(!before[0] && !before[1], "Past 0 still drew a ghost behind");
	test::eq(times_for(1.0f, false, 0.5f, 0, 0, 1, times[..], before[..], steps[..]), (usz)0);
	test::eq(times_for(0.0f, false, 0.0f, 3, 3, 1, times[..], before[..], steps[..]), (usz)0);
}

fn void ghosts_wrap_round_a_looping_clip() @test
{
	float[crig::MAX_GHOSTS] times;
	bool[crig::MAX_GHOSTS] before;
	int[crig::MAX_GHOSTS] steps;

	// 0.9 + 0.2 and 0.9 + 0.3 come round to 0.1 and 0.2.
	usz count = times_for(1.0f, true, 0.9f, 0, 3, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)3);
	test::@check(nearly(times[0], 1.0f) && nearly(times[1], 0.1f) && nearly(times[2], 0.2f),
		"the future ghosts did not wrap: %f %f %f", times[0], times[1], times[2]);
	// The same in front of the first frame.
	count = times_for(1.0f, true, 0.1f, 3, 0, 1, times[..], before[..], steps[..]);
	test::eq(count, (usz)3);
	test::@check(nearly(times[0], 0.0f) && nearly(times[1], 0.9f) && nearly(times[2], 0.8f),
		"the past ghosts did not wrap: %f %f %f", times[0], times[1], times[2]);

	// More ghosts than the clip has frames: none lands on the playhead or on another.
	count = times_for(1.0f, true, 0.5f, 30, 30, 1, times[..], before[..], steps[..]);
	test::@check(count > 0 && count <= (usz)crig::MAX_GHOSTS, "a long wrap drew %d ghosts", count);
	for (usz i = 0; i < count; i++)
	{
		test::@check(!nearly(times[i], 0.5f), "a ghost sits on the playhead");
		for (usz j = i + 1; j < count; j++) test::@check(!nearly(times[i], times[j]), "two ghosts share a time");
	}
}

fn void ghosts_are_capped() @test
{
	float[crig::MAX_GHOSTS] times;
	bool[crig::MAX_GHOSTS] before;
	int[crig::MAX_GHOSTS] steps;
	float[crig::MAX_GHOSTS] fades;
	usz count = crig::ghost_times(100.0f, false, 50.0f, 10, 30, 30, 1, times[..], before[..], steps[..], fades[..]);
	test::eq(count, (usz)crig::MAX_GHOSTS);
	count = crig::ghost_times(100.0f, false, 50.0f, 10, 30, 10, 1, times[..], before[..], steps[..], fades[..]);
	test::eq(count, (usz)40);

	int past, future;
	crig::ghost_counts(30, 30, &past, &future);
	test::@check(past + future == crig::MAX_GHOSTS && past == future, "the cap does not split evenly: %d %d", past, future);
	crig::ghost_counts(30, 10, &past, &future);
	test::@check(past == 30 && future == 10, "a request under the cap was trimmed");
}

fn void ghosts_fade_with_distance() @test
{
	test::@check(nearly(crig::ghost_fade(1, 5), 1.0f), "the nearest ghost is not full strength");
	test::@check(nearly(crig::ghost_fade(5, 5), crig::GHOST_FAR_FADE), "the farthest ghost is not at the floor");
	for (int k = 1; k < 5; k++) test::@check(crig::ghost_fade(k, 5) > crig::ghost_fade(k + 1, 5), "ghost %d is not stronger than %d", k, k + 1);
	test::@check(nearly(crig::ghost_fade(1, 1), 1.0f), "a lone ghost is faded");
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
		test::@check(nearly(ghosts[i].time, t), "ghost %d is at %f, not %f", i, ghosts[i].time, t);
		test::@check(ghosts[i].before == (i < 2), "ghost %d is on the wrong side", i);
	}
	test::@check(ghosts[0].fade > ghosts[1].fade && ghosts[2].fade > ghosts[3].fade, "ghosts do not fade outwards");
	test::@check(nearly(ghosts[0].fade, 1.0f) && nearly(ghosts[2].fade, 1.0f), "the nearest ghosts are not full strength");
	test::@check(nearly(f.app.ghost_strength(), crig::DEFAULT_GHOST_OPACITY), "an unset opacity is not the default");
	f.app.config.ghost_opacity = 0.6f;
	test::@check(nearly(f.app.ghost_strength(), 0.6f), "the opacity is not read");

	// What the mesh needs: a palette per ghost, one matrix per joint.
	foreach (ghost : ghosts) test::eq(ghost.palette.len, (sz)f.app.doc.dots.len());

	sz count = f.app.doc.dots.len();
	Vec3[] seen = alloc::new_array(mem, Vec3, count * 4);
	defer alloc::free(mem, seen);
	foreach (usz g, ghost : ghosts)
	{
		foreach (usz i, dot : f.app.doc.dots.array_view()) seen[g * (usz)count + i] = ghost_joint(ghost, dot.id);
	}
	test::@check(!near(ghost_joint(ghosts[0], f.knee), ghost_joint(ghosts[3], f.knee)), "the first and last ghost do not differ at the knee");
	foreach (usz g, t : want)
	{
		foreach (usz i, dot : f.app.doc.dots.array_view())
		{
			test::@check(near(seen[g * (usz)count + i], parked_at(&f.app, t, dot.id)),
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
	test::@check(!near(edited, before), "the ghost did not follow the edit");
	test::@check(near(edited, parked_at(&f.app, f.app.ghost_poses()[0].time, f.knee)), "the edited ghost is not the parked pose");

	(void)f.app.scrub_to(0.75f);
	test::@check(f.app.undo(), "could not undo the rekey");
	Vec3 undone = ghost_joint(f.app.ghost_poses()[0], f.knee);
	test::@check(near(undone, before), "the ghost did not follow the undo");
}

fn void ghosts_are_spread_along_the_chosen_direction_by_their_index() @test
{
	// Past goes back, future goes forward, magnitude is index * spread * height.
	Vec3 f1 = crig::ghost_offset(false, 1, 0.1f, 2.0f, 0);
	Vec3 f3 = crig::ghost_offset(false, 3, 0.1f, 2.0f, 0);
	Vec3 p2 = crig::ghost_offset(true, 2, 0.1f, 2.0f, 0);
	test::@check(near(f1, { 0, 0, 0.2f }) && near(f3, { 0, 0, 0.6f }) && near(p2, { 0, 0, -0.4f }),
		"forward offsets are not index * 0.1 * 2 along +Z");
	test::@check(near(crig::ghost_offset(false, 2, 0.1f, 2.0f, 1), { 0.4f, 0, 0 }), "sideways is not +X");
	test::@check(near(crig::ghost_offset(true, 1, 0.1f, 2.0f, 2), { 0, -0.2f, 0 }), "up is not +Y");
	// Scales with the rig, and zero is none.
	test::@check(near(crig::ghost_offset(false, 1, 0.1f, 4.0f, 0), { 0, 0, 0.4f }), "the offset did not scale with the height");
	test::@check(near(crig::ghost_offset(false, 5, 0.0f, 2.0f, 0), { 0, 0, 0 }), "spread 0 still moved a ghost");

	Figure f;
	test::@check(f.open(), "could not build the figure");
	defer f.close();
	f.app.anim_fps = 30;
	f.app.config.show_ghosts = true;
	f.app.config.ghost_past = 3;
	f.app.config.ghost_future = 3;
	f.app.config.ghost_spread = 0.2f;
	f.app.config.ghost_direction = 0;
	float height = f.app.model_height();
	test::@check(height > 0.1f, "the figure has no height");
	GhostPose[] ghosts = f.app.ghost_poses();
	test::eq(ghosts.len, (sz)6);
	foreach (&ghost : ghosts)
	{
		float want = (ghost.before ? -(float)ghost.step : (float)ghost.step) * 0.2f * height;
		Vec3 got = f.app.ghost_offset_of(ghost);
		test::@check(near(got, { 0, 0, want }), "ghost %d at step %d is offset %f, not %f", ghost.step, ghost.before, got.z, want);
	}
	// Ordering: further past is further back, further future further forward.
	test::@check(f.app.ghost_offset_of(&ghosts[2]).z < f.app.ghost_offset_of(&ghosts[0]).z, "the oldest ghost is not furthest back");
	test::@check(f.app.ghost_offset_of(&ghosts[5]).z > f.app.ghost_offset_of(&ghosts[3]).z, "the furthest ghost is not furthest forward");
	// The spread does not change the sampled poses.
	uint builds = f.app.ghosts.builds;
	f.app.config.ghost_spread = 0.4f;
	f.app.config.ghost_direction = 1;
	ghosts = f.app.ghost_poses();
	test::eq(f.app.ghosts.builds, builds);
	test::@check(near(f.app.ghost_offset_of(&ghosts[3]), { 0.4f * height, 0, 0 }), "the new spread and direction were not read");
	f.app.config.ghost_spread = 0.0f;
	test::@check(near(f.app.ghost_offset_of(&ghosts[3]), { 0, 0, 0 }), "spread 0 still offsets");
	// An out-of-range config reads as the default.
	f.app.config.ghost_spread = 9.0f;
	f.app.config.ghost_direction = 7;
	test::@check(f.app.ghost_spread() == crig::DEFAULT_GHOST_SPREAD && f.app.ghost_direction() == 0, "bad values were not defaulted");
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
		test::@check(near(points[i], parked_at(&f.app, (float)i / 30.0f, f.knee)), "path sample %d is not the parked knee", i);
	}
	foreach (usz k, t : key_times)
	{
		test::@check(near(keys[k], parked_at(&f.app, t, f.knee)), "key dot %d is not the knee at its key", k);
		test::@check(near(keys[k], points[(usz)(t * 30.0f + 0.5f)]), "key dot %d is off the path", k);
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
	test::@check(!near(edited, keys[1]), "the path did not follow the edit");
	test::@check(f.app.undo(), "could not undo");
	test::@check(near(f.app.selected_motion_path().key_points[1], keys[1]), "the path did not follow the undo");
}

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

fn void ghosts_are_the_parked_poses_at_the_neighbouring_keys() @test
{
	Figure f;
	test::@check(f.open(), "could not build the figure");
	defer f.close();

	test::eq(f.app.ghost_poses().len, (sz)0);
	f.app.config.show_ghosts = true;
	GhostPose[] ghosts = f.app.ghost_poses();
	test::eq(ghosts.len, (sz)2);
	test::@check(ghosts[0].before && ghosts[0].time == 0.5f && ghosts[0].step == 1, "previous ghost is not the 0.5 s key");
	test::@check(!ghosts[1].before && ghosts[1].time == 1.0f && ghosts[1].step == 1, "next ghost is not the 1 s key");

	sz count = f.app.doc.dots.len();
	Vec3[] behind = alloc::new_array(mem, Vec3, count);
	defer alloc::free(mem, behind);
	Vec3[] ahead = alloc::new_array(mem, Vec3, count);
	defer alloc::free(mem, ahead);
	foreach (usz i, dot : f.app.doc.dots.array_view())
	{
		behind[i] = ghost_joint(ghosts[0], dot.id);
		ahead[i] = ghost_joint(ghosts[1], dot.id);
	}
	test::@check(!near(ghost_joint(ghosts[0], f.knee), ghost_joint(ghosts[1], f.knee)),
		"the two ghosts do not differ at the knee");

	foreach (usz i, dot : f.app.doc.dots.array_view())
	{
		test::@check(near(behind[i], parked_at(&f.app, 0.5f, dot.id)), "ghost behind is not the pose parked at 0.5 s (%s)", dot.name);
		test::@check(near(ahead[i], parked_at(&f.app, 1.0f, dot.id)), "ghost ahead is not the pose parked at 1 s (%s)", dot.name);
	}

	// Two keys each side: the playhead at 0.75 has 0.5 and 0 behind, 1 ahead.
	(void)f.app.scrub_to(0.75f);
	f.app.config.ghost_keys = 2;
	ghosts = f.app.ghost_poses();
	test::eq(ghosts.len, (sz)3);
	test::@check(ghosts[1].before && ghosts[1].time == 0.0f && ghosts[1].step == 2, "second ghost back is not the 0 s key");

	// On a key: that key is the rig itself and has no ghost.
	f.app.config.ghost_keys = 1;
	(void)f.app.scrub_to(0.5f);
	ghosts = f.app.ghost_poses();
	test::eq(ghosts.len, (sz)2);
	test::@check(ghosts[0].time == 0.0f && ghosts[1].time == 1.0f, "the ghosts around a key are not its neighbours");

	// Running: no ghosts.
	f.app.resume_clip();
	test::eq(f.app.ghost_poses().len, (sz)0);
}

fn void the_ghost_cache_holds_and_follows_edits_and_undo() @test
{
	Figure f;
	test::@check(f.open(), "could not build the figure");
	defer f.close();
	f.app.config.show_ghosts = true;

	Vec3 before = ghost_joint(f.app.ghost_poses()[0], f.knee);
	uint builds = f.app.ghosts.builds;
	(void)f.app.ghost_poses();
	(void)f.app.scrub_to(0.6f);
	(void)f.app.ghost_poses();
	test::eq(f.app.ghosts.builds, builds);

	// Crossing a key changes which keys are the neighbours.
	(void)f.app.scrub_to(0.25f);
	(void)f.app.ghost_poses();
	test::eq(f.app.ghosts.builds, builds + 1);

	// Rekeying the 0.5 s pose is an edit: the next ghost follows it.
	(void)f.app.scrub_to(0.75f);
	test::@check(f.key_left(0.5f, 0.2f), "could not rekey 0.5 s");
	test::@check(f.app.park_clip(f.app.editing, 0.75f), "could not park again");
	Vec3 edited = ghost_joint(f.app.ghost_poses()[0], f.knee);
	test::@check(!near(edited, before), "the ghost did not follow the edit");
	test::@check(near(edited, parked_at(&f.app, 0.5f, f.knee)), "the edited ghost is not the parked pose");

	(void)f.app.scrub_to(0.75f);
	test::@check(f.app.undo(), "could not undo the rekey");
	Vec3 undone = ghost_joint(f.app.ghost_poses()[0], f.knee);
	test::@check(near(undone, before), "the ghost did not follow the undo");
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

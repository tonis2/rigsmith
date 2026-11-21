<*
 The editor's half of the shared test helpers: what needs an `AppState`. The
 rest of the module is `test/algo/helpers.c3`.
*>
module crig_tests::helpers;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::quaternion;

// ---------------------------------------------------------------------------
// Rigs

fn uint dot_named(crig::AppState* app, String name)
{
	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name == name) return dot.id;
	}
	return 0;
}

// One joint, "hip", for the key-editing checks: no mesh, no rig file.
struct HipFixture
{
	crig::AppState app;
}

fn void HipFixture.open(&self)
{
	self.app = crig::new_app({});
	self.app.doc.root_id = self.app.doc.add_dot({}, "hip");
}

// Bound up front, so the edit under test records only its own clip swap.
fn crig::AnimRef HipFixture.add(&self, String name, float duration, float[] times, crig::AnimChannels[] channels)
{
	crig::AnimRef ref = self.app.put_authored_clip(hip_clip(name, duration, times, channels));
	(void)self.app.bind_ref(ref);
	self.app.undo_stack.commit();
	self.app.undo_stack.clear();
	self.app.editing = ref;
	return ref;
}

fn void HipFixture.close(&self) => self.app.free();

// One "hip" key per time, turned and moved by that time.
fn crig::AnimTemplate hip_clip(String name, float duration, float[] times, crig::AnimChannels[] channels)
{
	crig::AnimKeyframe[] keys = alloc::new_array(mem, crig::AnimKeyframe, (sz)times.len);
	foreach (usz i, &key : keys)
	{
		crig::AnimKeyDot[] dots = alloc::new_array(mem, crig::AnimKeyDot, 1);
		dots[0] = {
			.joint_name = "hip".copy(mem),
			.axis = { 0, 1, 0 },
			.angle = times[i],
			.move = { times[i], 0, 0 },
			.channels = channels[i],
		};
		*key = { .time = times[i], .dots = dots };
	}
	return { .name = name.copy(mem), .duration = duration, .keyframes = keys, .owned = true };
}

// The key at `time`, or -1.
fn sz frame_at(crig::AnimTemplate* clip, float time)
{
	foreach (usz i, frame : clip.keyframes)
	{
		if (math::abs(frame.time - time) < 1.0e-5f) return (sz)i;
	}
	return -1;
}

// ---------------------------------------------------------------------------
// The editor

// The whole matrix as the views show it, unnormalised; `bones` weights to a vertex.
fn float[] shown_weights(crig::AppState* app, usz* bones)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	*bones = view.len();
	return app.weights(mem, &view);
}

// The joint index the rig gives `dot`.
fn usz joint_index(crig::AppState* app, uint dot)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return (usz)view.joint_of(dot);
}

// Steps on the cutscene's own undo history.
fn usz cut_steps(crig::AppState* app) => (usz)app.cut_history.undo.len();

fn float rig_height(crig::AppState* app)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	return view.skeleton.height();
}

// A joint's world rotation now: the draft's while a gesture holds one open,
// else the clip's key at the playhead.
fn Quaternionf world_rotation(crig::AppState* app, uint id)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose;
	if (app.pose_edit_active)
	{
		pose = app.draft_pose(mem, &view);
	}
	else
	{
		crig::AnimTemplate* clip = app.clip(app.editing);
		String[] names = app.names_for(&view, app.editing);
		pose = clip.pose(mem, &view.skeleton, names, app.edit_time, false);
	}
	defer pose.free(mem);
	Quaternionf[] world = pose.world_rotations(mem, &view.skeleton)!!;
	defer alloc::free(mem, world);
	return world[(usz)view.joint_of(id)];
}

// Plants both named joints for the whole clip on show, and puts it back on show.
fn void stand_on(crig::AppState* app, String left, String right)
{
	crig::AnimTemplate* clip = app.clip(app.editing);
	clip.ground.free(mem);
	crig::AnimFoot[] feet = alloc::new_array(mem, crig::AnimFoot, 2);
	feet[0] = { .joint = left.copy(mem), .down = 0.0f, .up = 1.0f };
	feet[1] = { .joint = right.copy(mem), .down = 0.0f, .up = 1.0f };
	clip.ground = { .feet = feet };
	test::@check(app.park_clip(app.editing, 0.0f), "the standing clip would not park");
}

// One viewport turn: R on joint `id`, the pointer sweeping `angle` about `axis`
// in eight moves, and let go.
fn void turn_gesture(crig::AppState* app, uint id, String name, Vec3 axis, float angle)
{
	app.select(id);
	test::@check(app.begin_turn(true), "the turn on %s did not begin", name);
	for (int step = 1; step <= 8; step++)
	{
		app.turn_joint(axis, angle * ((float)step / 8.0f));
	}
	app.end_drag();
}

// 1 - cos of the angle between where the aimed head faces on screen and the
// direction to `target`: 0 when it faces it.
fn float facing_error(crig::AppState* app, uint head, Vec3 target)
{
	crig::RigView view = app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = app.draft_pose(mem, &view);
	defer pose.free(mem);
	crig::AnimTemplate* clip = app.clip(app.editing);
	app.apply_clip_aims(&view, *clip, app.editing, app.edit_time, &pose);
	Vec3 position;
	Quaternionf world;
	usz joint = (usz)view.joint_of(head);
	if (!crig::aim_frame(&view, pose, joint, &position, &world)) return 1.0f;
	Vec3 facing = world.rotate_vec3(clip.aims[0].forward).normalize();
	return 1.0f - facing.dot((target - position).normalize());
}

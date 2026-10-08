<*
 The puppet contract, measured: grab a part and it goes there, pinned parts stay
 put, the rest follows, and nothing twitches, flips or leaves its limits.

 These are the yardstick for the body solver, not a regression net: most of them
 miss on the solver as it stands, and that is the point. Each test runs its whole
 gesture, takes every measurement, and only then reports all its misses at once —
 a test does not stop at its first miss, so one run shows how far each number is
 from the contract. Nothing is loosened to make a number pass.

 The people are a disposable copy of the shipped humanoid and dog
 (`library::ready`), posed the way the viewport poses them: a pin switched on,
 a joint selected, `begin_pose(held)` and `pose_toward` for the drag, which is
 read back with the gesture still open (`dot_position`, the draft's rotations),
 and `end_drag` for the release where the keyed pose is what is measured.

 Every test prints its numbers, and appends them to the file named by the
 `PUPPET_LOG` environment variable when there is one — the runner may hide stdout.

     `PUPPET_LOG=/tmp/puppet.txt c3c test --trust=full --test-noleak --test-filter crig_tests::puppet`
*>
module crig_tests::puppet;

import crig;
import rig;
import crig_tests::library;
import std::collections::list;
import std::core::test;
import std::io;
import std::io::file;
import std::math;
import std::math::quaternion;
import std::os::env;

const String PERSON = "humanoid.glb";
const String DOG = "quadruped.glb";

// Radians to degrees.
const float DEGREES = 57.29578f;

// A joint is inside its limits when clamping its rotation moves it by less than this.
const float INSIDE_DEGREES = 0.5f;

// A pin holds when the pinned part is within this share of the rig's height of it.
const float HELD = 0.005f;

// The smoothness checks (`Verdict.smooth`): the most a joint moves in one pointer move,
// in pointer steps; the most it turns, in degrees; how many equal sub-steps the worst
// moves are solved again in; and the share of a step any one sub-step may carry.
const float SMOOTH_MOVE = 4.0f;
const float SMOOTH_TURN = 10.0f;
const int REFINE_STEPS = 8;
const float SMOOTH_SHARE = 0.5f;

// ---------------------------------------------------------------------------
// The log

fn void log_line(String line)
{
	String? path = env::tget_var("PUPPET_LOG");
	if (catch path) return;
	File? out = file::open(path, "a");
	if (catch out) return;
	(void)io::fprintn(&out, line);
	(void)out.close();
}

// A line of the report: on the screen, and in the log when there is one.
fn void note(String format, args...)
{
	String line = string::tformat(format, ...args);
	io::printn(line);
	log_line(line);
}

// ---------------------------------------------------------------------------
// The verdict: every assertion of a test, counted rather than stopping at the first

struct Verdict
{
	String name;
	DString missed;
	usz checks;
	usz misses;
}

fn Verdict verdict(String name)
{
	note("%s", name);
	return { .name = name, .missed = dstring::new(mem) };
}

fn void Verdict.expect(&self, bool ok, String format, args...)
{
	self.checks++;
	if (ok) return;
	self.misses++;
	String line = string::tformat(format, ...args);
	self.missed.appendf("\n  - %s", line);
	log_line(string::tformat("  MISS  %s", line));
}

// The test's one failure, once everything has been measured and the figure freed.
fn void Verdict.finish(&self)
{
	String text = self.missed.copy_str(tmem);
	usz checks = self.checks;
	usz misses = self.misses;
	self.missed.free();
	note("  -> %d of %d assertions missed", misses, checks);
	test::@check(misses == 0, "%d of %d puppet assertions missed:%s", misses, checks, text);
}

fn void Verdict.held(&self, String what, float off)
{
	self.expect(off < HELD, "%s moved %.4f heights off its pin (limit %.3f)", what, off, HELD);
}

// ---------------------------------------------------------------------------
// Quaternion helpers

// The angle of a rotation, in degrees, 0 to 180. Read off the vector part so a
// tiny turn keeps its precision.
fn float angle_of(Quaternionf q)
{
	q = q.normalize();
	float vector = math::sqrt(q.v[0] * q.v[0] + q.v[1] * q.v[1] + q.v[2] * q.v[2]);
	return 2.0f * (float)math::atan2(vector, math::abs(q.v[3])) * DEGREES;
}

// The largest component difference between two rotations, whichever sign of the
// pair is nearer: q and -q are the same turn.
fn float component_gap(Quaternionf a, Quaternionf b)
{
	float same;
	float opposite;
	for (usz i = 0; i < 4; i++)
	{
		same = math::max(same, math::abs(a.v[i] - b.v[i]));
		opposite = math::max(opposite, math::abs(a.v[i] + b.v[i]));
	}
	return math::min(same, opposite);
}

// The angle between two directions, in degrees.
fn float angle_between(Vec3 a, Vec3 b)
{
	float cross = a.cross(b).length();
	return (float)math::atan2(cross, a.dot(b)) * DEGREES;
}

// ---------------------------------------------------------------------------
// One reading of the whole figure

<*
 Every joint at one moment, in joint order: where it shows, the turn the draft
 gives it in its parent, the turn that makes in the world, and its offset.
*>
struct Frame
{
	Vec3[] position;
	Quaternionf[] local;
	Quaternionf[] world;
	Vec3[] offset;
}

fn void Frame.free(&self)
{
	alloc::free(mem, self.position);
	alloc::free(mem, self.local);
	alloc::free(mem, self.world);
	alloc::free(mem, self.offset);
	*self = {};
}

// ---------------------------------------------------------------------------
// The fixture

struct Model
{
	rig::TriMesh mesh;
	crig::AppState app;
	bool opened;
	float height;
	// The joints, in the rig's order.
	String[] names;
	uint[] ids;
	// Each joint's rest bone direction: toward its tail, in its parent's frame
	// (every rest rotation here is the identity).
	Vec3[] bone;
}

<*
 Opens a model from the disposable library with its own rig, a clip on show and
 the Pose stage set, the way `pinning_test` does.
*>
fn bool Model.open(&self, String file)
{
	String path = string::tformat("%s/%s", library::ready(), file);
	self.mesh = rig::load_gltf(mem, path)!!;
	self.app = crig::new_app(self.mesh, path);
	self.opened = true;
	if (!self.app.import_rig_from_source())
	{
		test::@check(false, "%s must import its rig", path);
		return false;
	}
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	self.height = view.skeleton.height();
	sz count = (sz)view.len();
	self.names = alloc::new_array(mem, String, count);
	self.ids = alloc::new_array(mem, uint, count);
	foreach (usz j, id : view.dot_ids)
	{
		self.ids[j] = id;
		self.names[j] = view.names[j].copy(mem);
	}
	self.bone = view.skeleton.bone_directions(mem);

	self.app.editing = self.app.new_clip("Pose", 1.0f, from_rest: true);
	test::@check(self.app.editing.valid(), "no clip to pose");
	self.app.stop_animation();
	self.app.undo_stack.clear();
	self.app.edit_time = 0.0f;
	// The header's Pose switch: the clip goes on show at its playhead.
	test::@check(self.app.enter_pose_stage(), "the Pose stage would not open");
	self.app.auto_key = true;
	return self.app.editing.valid();
}

<*
 Gives the clip on show a ground spec with both named joints planted for the whole
 cycle — a figure standing on them — and puts it back on show.
*>
fn void Model.stand_on(&self, String left, String right)
{
	crig::AnimTemplate* clip = self.app.clip(self.app.editing);
	clip.ground.free(mem);
	crig::AnimFoot[] feet = alloc::new_array(mem, crig::AnimFoot, 2);
	feet[0] = { .joint = left.copy(mem), .down = 0.0f, .up = 1.0f };
	feet[1] = { .joint = right.copy(mem), .down = 0.0f, .up = 1.0f };
	clip.ground = { .feet = feet };
	test::@check(self.app.park_clip(self.app.editing, 0.0f), "the standing clip would not park");
}

fn void Model.close(&self)
{
	if (!self.opened) return;
	foreach (name : self.names) alloc::free(mem, name.ptr);
	if (self.names.len > 0) alloc::free(mem, self.names);
	if (self.ids.len > 0) alloc::free(mem, self.ids);
	if (self.bone.len > 0) alloc::free(mem, self.bone);
	self.app.free();
	self.mesh.free(mem);
	self.opened = false;
}

// The joint's index in the rig's order.
fn usz Model.joint(&self, String name)
{
	foreach (usz j, have : self.names)
	{
		if (have == name) return j;
	}
	test::@check(false, "no joint called %s", name);
	return 0;
}

fn uint Model.id(&self, String name) => self.ids[self.joint(name)];

fn Vec3 Model.at(&self, String name) => self.app.dot_position(*self.app.doc.find(self.id(name)));

// A joint's position pinned where it stands now, its angle left free.
fn void Model.pin_position(&self, String name) => self.app.set_anchor(self.id(name), true, false);

<*
 The turns the figure has now, per joint: the draft's while a gesture holds one open,
 and the clip's own keys at the playhead once it has been released and keyed (which
 closes the draft). Raw keys either way — not run through the limits' clamp or the
 floor, which would hide exactly what the solver wrote.
*>
fn rig::Pose Model.pose(&self, crig::RigView* view)
{
	if (self.app.pose_edit_active) return self.app.draft_pose(mem, view);
	crig::AnimTemplate* clip = self.app.clip(self.app.editing);
	String[] names = self.app.names_for(view, self.app.editing);
	return clip.pose(mem, &view.skeleton, names, self.app.edit_time, false);
}

// Every joint as it stands now: the shown positions, the turns of `pose`.
fn Frame Model.frame(&self)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.pose(&view);
	defer pose.free(mem);
	sz count = (sz)view.len();
	Frame frame = {
		.position = alloc::new_array(mem, Vec3, count),
		.local = alloc::new_array(mem, Quaternionf, count),
		.world = pose.world_rotations(mem, &view.skeleton)!!,
		.offset = alloc::new_array(mem, Vec3, count),
	};
	for (sz j = 0; j < count; j++)
	{
		frame.position[j] = self.app.dot_position(*self.app.doc.find(view.dot_ids[j]));
		frame.local[j] = pose.rotations[j];
		frame.offset[j] = pose.offsets[j];
	}
	return frame;
}

// ---------------------------------------------------------------------------
// The measures

// How far the joint is from where `start` had it, in rig heights.
fn float Model.off(&self, String name, Frame* start, Frame* now)
{
	usz j = self.joint(name);
	return (now.position[j] - start.position[j]).length() / self.height;
}

<*
 How far the joint's world "up" has swung from where it was, in degrees: a lean
 forward, back or sideways. A turn about the vertical (a yaw) is not a tilt.
*>
fn float Model.tilt(&self, String name, Frame* start, Frame* now)
{
	usz j = self.joint(name);
	Vec3 up = { 0, 1, 0 };
	return angle_between(start.world[j].rotate_vec3(up), now.world[j].rotate_vec3(up));
}

<*
 The roll of the joint about its own bone, in degrees: the part of the turn it
 has made since `start` (in its parent's frame) that spins about the rest bone
 direction, by swing-twist — the bone-axis share of the quaternion's vector part.
*>
fn float Model.twist(&self, String name, Frame* start, Frame* now)
{
	usz j = self.joint(name);
	Vec3 axis = self.bone[j];
	if (axis.length_sq() < 1.0e-12f) return 0.0f;
	Quaternionf turn = now.local[j].mul(start.local[j].invert()).normalize();
	float sign = turn.v[3] < 0.0f ? -1.0f : 1.0f;
	float along = sign * (turn.v[0] * axis.x + turn.v[1] * axis.y + turn.v[2] * axis.z);
	return math::abs(2.0f * (float)math::atan2(along, sign * turn.v[3])) * DEGREES;
}

// The whole turn the joint has made in the world since `start`, in degrees.
fn float Model.turned(&self, String name, Frame* start, Frame* now)
{
	usz j = self.joint(name);
	return angle_of(now.world[j].mul(start.world[j].invert()));
}

// The angle a leg is folded by at `knee`, in degrees: 0 for a straight leg.
fn float Model.fold(&self, String thigh, String knee, String ankle, Frame* now)
{
	Vec3 above = (now.position[self.joint(knee)] - now.position[self.joint(thigh)]).normalize();
	Vec3 below = (now.position[self.joint(ankle)] - now.position[self.joint(knee)]).normalize();
	return (float)math::acos(math::clamp(above.dot(below), -1.0f, 1.0f)) * DEGREES;
}

<*
 How far in front (+Z) of the hip-to-ankle line the knee stands, in rig heights:
 negative when it has gone behind. The humanoid faces +Z.
*>
fn float Model.forward(&self, String thigh, String knee, String ankle, Frame* now)
{
	Vec3 hip = now.position[self.joint(thigh)];
	Vec3 foot = now.position[self.joint(ankle)];
	Vec3 bend = now.position[self.joint(knee)];
	Vec3 line = foot - hip;
	float along = math::clamp((bend - hip).dot(line) / math::max(line.length_sq(), 1.0e-9f), 0.0f, 1.0f);
	return (bend - (hip + line * along)).z / self.height;
}

<*
 The worst a joint is outside its limits, in degrees: the angle the limits' own
 clamp moves its rotation by. Always asks `constrain_joint_rotation` — never
 reads the angles itself — so it keeps measuring the same thing whatever the
 limits are made of.

 @param worst_at : `Receives the name of the joint furthest out.`
*>
fn float Model.limit_excess(&self, String* worst_at)
{
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	rig::Pose pose = self.pose(&view);
	defer pose.free(mem);
	float worst;
	*worst_at = "none";
	foreach (usz j, id : view.dot_ids)
	{
		crig::JointRotationLimits limits = self.app.doc.rotation_limits_of(id);
		if (!limits.constrained) continue;
		crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, limits);
		if (!frame.usable()) continue;
		Quaternionf asked = pose.rotations[j].normalize();
		float excess = angle_of(asked.mul(crig::constrain_joint_rotation(frame, limits, asked).invert()));
		if (excess > worst)
		{
			worst = excess;
			*worst_at = self.names[j];
		}
	}
	return worst;
}

// A joint's turn as the limits' own X, Y and Z, in degrees. For the log only.
fn Vec3 Model.angles(&self, String name, Frame* now)
{
	usz j = self.joint(name);
	crig::RigView view = self.app.open_rig(mem)!!;
	defer view.free(mem);
	crig::JointRotationLimits limits = self.app.doc.rotation_limits_of(self.ids[j]);
	crig::JointLimitFrame frame = crig::joint_limit_frame(&view.skeleton, view.dot_ids, limits);
	return crig::joint_angles_from_rotation(frame, now.local[j]) * DEGREES;
}

// How many joints have a different turn from `start`, by more than a hundredth of a degree.
fn usz Model.stirred(&self, Frame* start, Frame* now)
{
	usz count;
	foreach (usz j, turn : now.local)
	{
		if (angle_of(turn.mul(start.local[j].invert())) > 0.01f) count++;
	}
	return count;
}

// ---------------------------------------------------------------------------
// A drag, sampled

<*
 The worst single-step change over a sweep: the biggest jump of any joint's
 position (in rig heights) and of any joint's local turn (in degrees), between
 two consecutive pointer moves. `asked` is how far the pointer itself moved in
 one step, in rig heights.

 The worst move and the worst turn are then refined (`Sweep.refine`): the same step
 solved again in `REFINE_STEPS` equal sub-steps, and `move_sub` / `turn_sub` are the
 most that joint moved (or turned) in any one of them.
*>
struct Jumps
{
	float move;
	String move_at;
	usz move_joint;
	int move_step;
	float turn;
	String turn_at;
	usz turn_joint;
	int turn_step;
	float asked;
	// The most the solver said it left short of the pointer, in rig heights.
	float gap;
	// The refinement of the worst move and of the worst turn.
	float move_sub;
	float turn_sub;
	bool refined;
}

<*
 One open pose gesture, driven in pointer steps and sampled after each: `to` carries
 the pointer to an offset from where it began, `finish` lets go. The gesture is held
 open between the two so the pose can be read while it is in flight.

 `path` is where the pointer stood after every move, the first entry being where it
 began, so a step can be solved again in finer steps between its two ends.
*>
struct Sweep
{
	Model* model;
	Vec3 from;
	Vec3 at;
	int steps;
	// Pointer moves made so far, over every leg.
	int count;
	Frame last;
	Jumps jumps;
	List{Vec3} path;
}

<*
 Press on `name` the way the viewport does (held: no pointer anchoring) and take
 the starting reading.

 @param steps : `Pointer moves per leg of the sweep.`
*>
fn Sweep Model.grab(&self, String name, int steps = 40)
{
	self.app.select(self.id(name));
	test::@check(self.app.begin_pose(true), "the pose gesture on %s did not begin", name);
	Sweep s = { .model = self, .from = self.app.drag.from, .steps = steps, .last = self.frame() };
	s.path.init(mem);
	s.path.push(s.from);
	return s;
}

// Carry the pointer, in `steps` equal moves, to `offset` from where the press began.
fn void Sweep.to(&self, Vec3 offset)
{
	Model* m = self.model;
	Vec3 begin = self.at;
	float leg = (offset - begin).length() / (float)self.steps / m.height;
	self.jumps.asked = math::max(self.jumps.asked, leg);
	for (int step = 1; step <= self.steps; step++)
	{
		Vec3 target = self.from + begin + (offset - begin) * ((float)step / (float)self.steps);
		self.path.push(target);
		float gap = m.app.pose_toward(target);
		self.jumps.gap = math::max(self.jumps.gap, gap / m.height);

		Frame now = m.frame();
		foreach (usz j, position : now.position)
		{
			float move = (position - self.last.position[j]).length() / m.height;
			if (move > self.jumps.move)
			{
				self.jumps.move = move;
				self.jumps.move_at = m.names[j];
				self.jumps.move_joint = j;
				self.jumps.move_step = self.count + step;
			}
			float turn = angle_of(now.local[j].mul(self.last.local[j].invert()));
			if (turn > self.jumps.turn)
			{
				self.jumps.turn = turn;
				self.jumps.turn_at = m.names[j];
				self.jumps.turn_joint = j;
				self.jumps.turn_step = self.count + step;
			}
		}
		self.last.free();
		self.last = now;
	}
	self.at = offset;
	self.count += self.steps;
}

<*
 Solve pointer move `step` again in `REFINE_STEPS` equal sub-steps between its two
 ends, and say the most `joint` moved (in rig heights) or turned (in degrees) in any
 one of them. `pose_toward` solves from the gesture's start, so a pose at a pointer
 position between two moves is the pose a finer sweep would have had there.
*>
fn float Sweep.refine(&self, int step, usz joint, bool turn)
{
	Model* m = self.model;
	Vec3 a = self.path[(usz)step - 1];
	Vec3 b = self.path[(usz)step];
	(void)m.app.pose_toward(a);
	Frame before = m.frame();
	float most;
	for (int sub = 1; sub <= REFINE_STEPS; sub++)
	{
		(void)m.app.pose_toward(a + (b - a) * ((float)sub / (float)REFINE_STEPS));
		Frame now = m.frame();
		float change = turn ? angle_of(now.local[joint].mul(before.local[joint].invert()))
			: (now.position[joint] - before.position[joint]).length() / m.height;
		most = math::max(most, change);
		before.free();
		before = now;
	}
	before.free();
	return most;
}

// Put the pointer back where the sweep left it, so the release banks the pose the sweep ended on.
fn void Sweep.settle(&self)
{
	if (self.path.len() == 0) return;
	(void)self.model.app.pose_toward(self.path[self.path.len() - 1]);
}

// Let go (the release banks the pose, and keys it with Auto-key on).
fn void Sweep.finish(&self)
{
	self.model.app.end_drag();
	self.last.free();
	self.path.free();
}

<*
 One viewport turn: R on `name`, the pointer sweeping `angle` about `axis` in a
 few moves, and let go.
*>
fn void Model.turn(&self, String name, Vec3 axis, float angle)
{
	self.app.select(self.id(name));
	test::@check(self.app.begin_turn(true), "the turn on %s did not begin", name);
	for (int step = 1; step <= 8; step++)
	{
		self.app.turn_joint(axis, angle * ((float)step / 8.0f));
	}
	self.app.end_drag();
}

// ---------------------------------------------------------------------------
// The humanoid, read as a figure on its feet

<*
 How the humanoid stands after a gesture, against how it stood before it. Every
 field is measured whether or not the test asserts it, so the log shows the same
 columns for every test.
*>
struct Posture
{
	// Feet and toes, in rig heights off where they were.
	float ankle_l;
	float ankle_r;
	float toe_l;
	float toe_r;
	// The feet's whole turn in the world, degrees.
	float foot_l;
	float foot_r;
	// Leans, degrees.
	float hips_tilt;
	float chest_tilt;
	// Rolls about the bone, degrees.
	float spine_twist;
	float upper_spine_twist;
	float chest_twist;
	// The legs.
	float fold_l;
	float fold_r;
	float forward_l;
	float forward_r;
	// How far the hips and the spine came down, in rig heights.
	float hips_drop;
	float spine_drop;
	// The limits.
	float excess;
	String excess_at;
	Vec3 spine_angles;
	usz stirred;
}

fn Posture Model.posture(&self, Frame* start, Frame* now)
{
	Posture p = {
		.ankle_l = self.off("ankle_L", start, now),
		.ankle_r = self.off("ankle_R", start, now),
		.toe_l = self.off("toe_L", start, now),
		.toe_r = self.off("toe_R", start, now),
		.foot_l = self.turned("ankle_L", start, now),
		.foot_r = self.turned("ankle_R", start, now),
		.hips_tilt = self.tilt("hips", start, now),
		.chest_tilt = self.tilt("chest", start, now),
		.spine_twist = self.twist("spine", start, now),
		.upper_spine_twist = self.twist("upper_spine", start, now),
		.chest_twist = self.twist("chest", start, now),
		.fold_l = self.fold("thigh_L", "knee_L", "ankle_L", now),
		.fold_r = self.fold("thigh_R", "knee_R", "ankle_R", now),
		.forward_l = self.forward("thigh_L", "knee_L", "ankle_L", now),
		.forward_r = self.forward("thigh_R", "knee_R", "ankle_R", now),
		.hips_drop = (start.position[self.joint("hips")].y - now.position[self.joint("hips")].y) / self.height,
		.spine_drop = (start.position[self.joint("spine")].y - now.position[self.joint("spine")].y) / self.height,
		.spine_angles = self.angles("spine", now),
		.stirred = self.stirred(start, now),
	};
	p.excess = self.limit_excess(&p.excess_at);
	return p;
}

fn void Posture.print(&self)
{
	note("  ankles off pin  L %.4f  R %.4f   toes off  L %.4f  R %.4f   (heights)", self.ankle_l, self.ankle_r, self.toe_l, self.toe_r);
	note("  feet turned     L %.2f  R %.2f  (deg)", self.foot_l, self.foot_r);
	note("  tilt            hips %.2f  chest %.2f  (deg)", self.hips_tilt, self.chest_tilt);
	note("  twist           spine %.2f  upper_spine %.2f  chest %.2f  (deg)", self.spine_twist, self.upper_spine_twist, self.chest_twist);
	note("  knees           fold L %.1f  R %.1f (deg)   forward of the hip-ankle line L %.3f  R %.3f (heights)",
		self.fold_l, self.fold_r, self.forward_l, self.forward_r);
	note("  dropped         hips %.3f  spine %.3f  (heights)", self.hips_drop, self.spine_drop);
	note("  limits          worst %.2f deg outside, at %s   spine X %.1f Y %.1f Z %.1f (deg)",
		self.excess, self.excess_at, self.spine_angles.x, self.spine_angles.y, self.spine_angles.z);
	note("  joints stirred  %d", (int)self.stirred);
}

fn void Jumps.print(&self)
{
	note("  per-step jump   position %.4f heights at %s on move %d (pointer step %.4f, %.1fx)   turn %.2f deg at %s on move %d   solver gap up to %.4f",
		self.move, self.move_at, self.move_step, self.asked, self.move / math::max(self.asked, 1.0e-9f), self.turn, self.turn_at, self.turn_step, self.gap);
	if (!self.refined) return;
	note("  refined x%d     the worst move's largest sub-step %.4f heights (%.0f%% of the step)   the worst turn's largest sub-step %.2f deg (%.0f%% of the step)",
		REFINE_STEPS, self.move_sub, 100.0f * self.move_sub / math::max(self.move, 1.0e-9f), self.turn_sub, 100.0f * self.turn_sub / math::max(self.turn, 1.0e-9f));
}

// The feet stay flat, and the body upright: the checks every sit shares.
fn void Verdict.flat_feet(&self, Posture* p, float feet_limit)
{
	self.expect(p.foot_l < feet_limit, "the left foot turned %.2f degrees (limit %.1f)", p.foot_l, feet_limit);
	self.expect(p.foot_r < feet_limit, "the right foot turned %.2f degrees (limit %.1f)", p.foot_r, feet_limit);
}

fn void Verdict.upright(&self, Posture* p, float chest_limit)
{
	self.expect(p.hips_tilt < 10.0f, "the hips tilted %.2f degrees (limit 10)", p.hips_tilt);
	self.expect(p.chest_tilt < chest_limit, "the chest tilted %.2f degrees (limit %.0f)", p.chest_tilt, chest_limit);
}

fn void Verdict.knees_forward(&self, Posture* p)
{
	self.expect(p.fold_l > 60.0f, "the left knee folded only %.1f degrees (need over 60)", p.fold_l);
	self.expect(p.fold_r > 60.0f, "the right knee folded only %.1f degrees (need over 60)", p.fold_r);
	self.expect(p.forward_l > 0.01f, "the left knee is %.3f heights in front of the hip-ankle line (it must be forward)", p.forward_l);
	self.expect(p.forward_r > 0.01f, "the right knee is %.3f heights in front of the hip-ankle line (it must be forward)", p.forward_r);
}

fn void Verdict.inside_limits(&self, Posture* p)
{
	self.expect(p.excess < INSIDE_DEGREES, "%s is %.2f degrees outside its limits (limit %.1f)", p.excess_at, p.excess, INSIDE_DEGREES);
}

<*
 No discontinuity and no explosion over a sweep, three ways:

   a. no joint moves more than `SMOOTH_MOVE` times the pointer's own step in one move.
      A pull on a straight knee is a square-root response (the knee moves
      cot(bend / 2) times the drop), so it is a lever, not a jump, and the factor
      allows it;
   b. no joint turns more than `SMOOTH_TURN` degrees in one move;
   c. the move with the worst joint movement, and the move with the worst turn, solved
      again in `REFINE_STEPS` equal sub-steps, spread over them: no sub-step carries more
      than `SMOOTH_SHARE` of the whole step's move or turn (plus a hair). A jump puts
      nearly all of a step in one sub-step; a smooth response spreads it, and the first
      sub-step of a square-root onset carries about a third.

 The refinement is made with the gesture still open, and ends by putting the pointer
 back at the sweep's last position so the release banks the same pose.
*>
fn void Verdict.smooth(&self, Sweep* s)
{
	Jumps* jumps = &s.jumps;
	if (jumps.move_step > 0)
	{
		jumps.move_sub = s.refine(jumps.move_step, jumps.move_joint, false);
		jumps.turn_sub = s.refine(jumps.turn_step, jumps.turn_joint, true);
		jumps.refined = true;
		s.settle();
	}
	jumps.print();
	self.expect(jumps.move <= SMOOTH_MOVE * jumps.asked, "%s moved %.4f heights in one step, over %.0f times the pointer's %.4f",
		jumps.move_at, jumps.move, SMOOTH_MOVE, jumps.asked);
	self.expect(jumps.turn <= SMOOTH_TURN, "%s turned %.2f degrees in one step (limit %.0f)", jumps.turn_at, jumps.turn, SMOOTH_TURN);
	if (!jumps.refined) return;
	self.expect(jumps.move_sub <= SMOOTH_SHARE * jumps.move + 1.0e-4f,
		"%s moved %.4f of its %.4f heights in one eighth of the step (limit %.0f%% and a hair): a jump, not a response",
		jumps.move_at, jumps.move_sub, jumps.move, 100.0f * SMOOTH_SHARE);
	self.expect(jumps.turn_sub <= SMOOTH_SHARE * jumps.turn + 0.05f,
		"%s turned %.2f of its %.2f degrees in one eighth of the step (limit %.0f%% and 0.05 degrees): a jump, not a response",
		jumps.turn_at, jumps.turn_sub, jumps.turn, 100.0f * SMOOTH_SHARE);
}

fn void Verdict.moved(&self, Posture* p)
{
	self.expect(p.stirred > 0, "no joint turned: the pose did not read back, so the other numbers mean nothing");
}

// ---------------------------------------------------------------------------
// 1. The user's case

<*
 The figure sits: both ankles pinned by position alone, `spine` pulled straight
 down 0.18 of the height in 40 steps. The body should drop onto bent knees with
 the pelvis level, the torso upright and untwisted, the feet flat on their pins
 and every joint inside its limits, with no joint jumping from one step to the next.
*>
fn void sit_on_position_pinned_ankles(Model* m, Verdict* v)
{
	float h = m.height;
	Frame start = m.frame();
	defer start.free();
	m.pin_position("ankle_L");
	m.pin_position("ankle_R");

	Sweep s = m.grab("spine");
	s.to({ 0, -0.18f * h, 0 });
	Frame now = m.frame();
	defer now.free();
	Posture p = m.posture(&start, &now);
	p.print();
	v.smooth(&s);
	s.finish();

	v.moved(&p);
	v.held("ankle_L", p.ankle_l);
	v.held("ankle_R", p.ankle_r);
	v.flat_feet(&p, 3.0f);
	v.upright(&p, 10.0f);
	v.expect(p.spine_twist < 5.0f, "the spine twisted %.2f degrees about its bone (limit 5)", p.spine_twist);
	v.knees_forward(&p);
	v.inside_limits(&p);
}

fn void spine_down_sits_on_position_pinned_ankles() @test
{
	Verdict v = verdict("humanoid: spine down 0.18h with both ankles pinned by position");
	Model m;
	if (m.open(PERSON)) sit_on_position_pinned_ankles(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 2. Pin angle as well

<*
 Both feet pinned in position *and* angle, and the spine pulled further down
 (0.25 of the height): past what the ankles can stay flat for. The hard angle wins
 — the feet stay flat, the body stops or goes back rather than tipping them — and
 the grab may fall short of the pointer.
*>
fn void sit_on_fully_pinned_feet(Model* m, Verdict* v)
{
	float h = m.height;
	Frame start = m.frame();
	defer start.free();
	test::@check(m.app.pin_feet(true) == 2, "both feet should pin");

	Sweep s = m.grab("spine");
	s.to({ 0, -0.25f * h, 0 });
	Frame now = m.frame();
	defer now.free();
	Posture p = m.posture(&start, &now);
	p.print();
	v.smooth(&s);
	s.finish();

	v.moved(&p);
	v.held("ankle_L", p.ankle_l);
	v.held("ankle_R", p.ankle_r);
	v.flat_feet(&p, 1.0f);
	v.upright(&p, 10.0f);
	v.inside_limits(&p);
}

fn void pin_angle_feet_stay_flat_past_the_ankle_limit() @test
{
	Verdict v = verdict("humanoid: spine down 0.25h with both feet pinned, position and angle");
	Model m;
	if (m.open(PERSON)) sit_on_fully_pinned_feet(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 3. Grounded

<*
 The same sit on a figure that is also standing on its toes (planted on the
 floor for the whole clip), shallower — 0.12 of the height — because the planted
 toes hold as well. Ankles and toes stay, the feet stay flat, the body stays upright.
*>
fn void sit_grounded(Model* m, Verdict* v)
{
	float h = m.height;
	m.stand_on("toe_L", "toe_R");
	Frame start = m.frame();
	defer start.free();
	m.pin_position("ankle_L");
	m.pin_position("ankle_R");

	Sweep s = m.grab("spine");
	s.to({ 0, -0.12f * h, 0 });
	Frame now = m.frame();
	defer now.free();
	Posture p = m.posture(&start, &now);
	p.print();
	v.smooth(&s);
	s.finish();

	v.moved(&p);
	v.held("ankle_L", p.ankle_l);
	v.held("ankle_R", p.ankle_r);
	v.held("toe_L", p.toe_l);
	v.held("toe_R", p.toe_r);
	v.flat_feet(&p, 3.0f);
	v.upright(&p, 10.0f);
}

fn void a_grounded_figure_sits_on_flat_feet() @test
{
	Verdict v = verdict("humanoid, toes planted: spine down 0.12h with both ankles pinned by position");
	Model m;
	if (m.open(PERSON)) sit_grounded(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 4. Down and back

<*
 Down and back, a sit onto a chair: the spine goes down 0.15 of the height and
 0.08 behind. The hips travel behind the feet, which hold and stay flat, and the
 chest may lean forward a little (up to 20 degrees) but not back.
*>
fn void chair_sit(Model* m, Verdict* v)
{
	float h = m.height;
	Frame start = m.frame();
	defer start.free();
	m.pin_position("ankle_L");
	m.pin_position("ankle_R");

	Sweep s = m.grab("spine");
	s.to({ 0, -0.15f * h, -0.08f * h });
	Frame now = m.frame();
	defer now.free();
	Posture p = m.posture(&start, &now);
	p.print();
	v.smooth(&s);
	s.finish();

	v.moved(&p);
	v.held("ankle_L", p.ankle_l);
	v.held("ankle_R", p.ankle_r);
	v.flat_feet(&p, 3.0f);
	v.expect(p.chest_tilt < 20.0f, "the chest tilted %.2f degrees (limit 20)", p.chest_tilt);
	v.knees_forward(&p);
	v.inside_limits(&p);
}

fn void down_and_back_is_a_chair_sit() @test
{
	Verdict v = verdict("humanoid: spine down 0.15h and back 0.08h with both ankles pinned by position");
	Model m;
	if (m.open(PERSON)) chair_sit(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 5. The dog

<*
 The dog's pelvis down 0.2 model units with both hind hooves pinned by position:
 the hooves hold, the pelvis really drops, and the sweep never jumps. The dog has
 no limits, so the limits check is the same call over nothing.
*>
fn void dog_sits(Model* m, Verdict* v)
{
	Frame start = m.frame();
	defer start.free();
	m.pin_position("hind_hoof_L");
	m.pin_position("hind_hoof_R");

	Sweep s = m.grab("pelvis");
	s.to({ 0, -0.2f, 0 });
	Frame now = m.frame();
	defer now.free();

	float hoof_l = m.off("hind_hoof_L", &start, &now);
	float hoof_r = m.off("hind_hoof_R", &start, &now);
	float dropped = start.position[m.joint("pelvis")].y - now.position[m.joint("pelvis")].y;
	float tilt = m.tilt("pelvis", &start, &now);
	String worst_at;
	float excess = m.limit_excess(&worst_at);
	note("  rig height %.3f   hooves off pin  L %.4f  R %.4f (heights)   pelvis dropped %.3f of 0.2 (model units)   pelvis tilt %.2f deg",
		m.height, hoof_l, hoof_r, dropped, tilt);
	note("  limits          worst %.2f deg outside, at %s   joints stirred %d", excess, worst_at, (int)m.stirred(&start, &now));
	v.smooth(&s);
	s.finish();

	v.expect(m.stirred(&start, &now) > 0, "no joint turned: the pose did not read back");
	v.held("hind_hoof_L", hoof_l);
	v.held("hind_hoof_R", hoof_r);
	v.expect(dropped > 0.1f, "the pelvis dropped only %.3f of the 0.2 pulled (need over 0.1)", dropped);
	v.expect(excess < INSIDE_DEGREES, "%s is %.2f degrees outside its limits (limit %.1f)", worst_at, excess, INSIDE_DEGREES);
}

fn void the_dog_sits_on_pinned_hind_hooves() @test
{
	Verdict v = verdict("dog: pelvis down 0.2 with both hind hooves pinned by position");
	Model m;
	if (m.open(DOG)) dog_sits(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 6. A free hand

<*
 Nothing pinned, `wrist_L` pulled 0.08 of the height to somewhere in reach: the
 arm does it alone — the hips do not move and the chest does not lean. Then pulled
 0.5 of the height further, past what the arm can reach: now the body follows, the
 hips move well over 0.1 of the height, and the wrist still gets to the pointer.

 The first pull goes forward and a little toward the shoulder, so it is within
 reach whichever way the arm hangs at rest; the second carries straight on forward.
*>
fn void a_free_hand(Model* m, Verdict* v)
{
	float h = m.height;
	Frame start = m.frame();
	defer start.free();
	Vec3 wrist = start.position[m.joint("wrist_L")];
	Vec3 shoulder = start.position[m.joint("shoulder_L")];
	Vec3 toward = (shoulder - wrist).normalize();
	Vec3 forward = { 0, 0, 1 };
	Vec3 near = (forward * 0.8f + toward * 0.6f).normalize() * (0.08f * h);
	Vec3 far = near + forward * (0.5f * h);
	note("  arm length %.3f heights   first pull to %.3f,%.3f,%.3f heights, then to %.3f,%.3f,%.3f",
		(shoulder - wrist).length() / h, near.x / h, near.y / h, near.z / h, far.x / h, far.y / h, far.z / h);

	Sweep s = m.grab("wrist_L");
	s.to(near);
	Frame mid = m.frame();
	defer mid.free();
	s.to(far);
	Frame end = m.frame();
	defer end.free();

	float hips_near = m.off("hips", &start, &mid);
	float chest_near = m.tilt("chest", &start, &mid);
	float wrist_near = (mid.position[m.joint("wrist_L")] - (wrist + near)).length() / h;
	float hips_far = m.off("hips", &start, &end);
	float wrist_far = (end.position[m.joint("wrist_L")] - (wrist + far)).length() / h;
	note("  within reach    hips moved %.4f heights  chest tilt %.2f deg  wrist missed the pointer by %.4f heights", hips_near, chest_near, wrist_near);
	note("  past reach      hips moved %.4f heights  wrist missed the pointer by %.4f heights", hips_far, wrist_far);
	v.smooth(&s);
	s.finish();

	v.expect(m.stirred(&start, &mid) > 0, "no joint turned: the pose did not read back");
	v.expect(hips_near < 0.005f, "the hips moved %.4f heights for a pull the arm could do alone (limit 0.005)", hips_near);
	v.expect(chest_near < 3.0f, "the chest tilted %.2f degrees for a pull the arm could do alone (limit 3)", chest_near);
	v.expect(hips_far > 0.1f, "the hips moved only %.4f heights when the hand was pulled past reach (need over 0.1)", hips_far);
	v.expect(wrist_far < 0.02f, "the wrist missed the pointer by %.4f heights after the body followed (limit 0.02)", wrist_far);
}

fn void a_free_hand_moves_the_arm_first() @test
{
	Verdict v = verdict("humanoid, nothing pinned: wrist_L pulled 0.08h within reach, then 0.5h further");
	Model m;
	if (m.open(PERSON)) a_free_hand(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 7. There and back

<*
 Dragging away and back returns exactly: the spine goes down 0.15 of the height and
 back to where it began in one gesture, with both ankles pinned. Every joint's local
 turn is then the one it began with to within 1e-4 (the larger quaternion component
 difference, taking the nearer sign), and every offset within 1e-4 of the height.
*>
fn void there_and_back(Model* m, Verdict* v)
{
	float h = m.height;
	Frame start = m.frame();
	defer start.free();
	m.pin_position("ankle_L");
	m.pin_position("ankle_R");

	Sweep s = m.grab("spine");
	s.to({ 0, -0.15f * h, 0 });
	Frame low = m.frame();
	defer low.free();
	s.to({});
	Frame back = m.frame();
	defer back.free();
	v.smooth(&s);
	s.finish();

	float turn_gap;
	String turn_at = "none";
	float offset_gap;
	String offset_at = "none";
	float place_gap;
	String place_at = "none";
	foreach (usz j, name : m.names)
	{
		float turn = component_gap(back.local[j], start.local[j]);
		if (turn > turn_gap) { turn_gap = turn; turn_at = name; }
		float offset = (back.offset[j] - start.offset[j]).length() / h;
		if (offset > offset_gap) { offset_gap = offset; offset_at = name; }
		float place = (back.position[j] - start.position[j]).length() / h;
		if (place > place_gap) { place_gap = place; place_at = name; }
	}
	note("  at the bottom   spine dropped %.3f heights, joints stirred %d", (start.position[m.joint("spine")].y - low.position[m.joint("spine")].y) / h, (int)m.stirred(&start, &low));
	note("  back at A       worst local turn gap %.6f at %s   worst offset gap %.6f heights at %s   worst position gap %.6f heights at %s",
		turn_gap, turn_at, offset_gap, offset_at, place_gap, place_at);

	v.expect(m.stirred(&start, &low) > 0, "no joint turned on the way down: the pose did not read back");
	v.expect(turn_gap < 1.0e-4f, "%s came back %.6f off its starting turn (limit 1e-4)", turn_at, turn_gap);
	v.expect(offset_gap < 1.0e-4f, "%s came back %.6f heights off its starting offset (limit 1e-4)", offset_at, offset_gap);
}

fn void there_and_back_returns_exactly() @test
{
	Verdict v = verdict("humanoid: spine down 0.15h and back in one gesture with both ankles pinned");
	Model m;
	if (m.open(PERSON)) there_and_back(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 8. Turning the hips

<*
 R on the hips, 0.3 radians about the world's vertical, with both ankles pinned by
 position: the legs twist to take it, and the feet stay where they are, flat, with
 every joint inside its limits.
*>
fn void turn_the_hips(Model* m, Verdict* v)
{
	Frame start = m.frame();
	defer start.free();
	m.pin_position("ankle_L");
	m.pin_position("ankle_R");

	m.turn("hips", { 0, 1, 0 }, 0.3f);
	Frame now = m.frame();
	defer now.free();
	Posture p = m.posture(&start, &now);
	float hips = m.turned("hips", &start, &now);

	p.print();
	note("  the hips turned %.2f deg of the 17.19 asked", hips);
	v.expect(hips > 1.0f, "the hips turned only %.2f degrees: the turn did not read back, so the other numbers mean nothing", hips);
	v.held("ankle_L", p.ankle_l);
	v.held("ankle_R", p.ankle_r);
	v.flat_feet(&p, 3.0f);
	v.inside_limits(&p);
}

fn void turning_the_hips_keeps_flat_pinned_feet() @test
{
	Verdict v = verdict("humanoid: R turn of the hips 0.3 rad about Y with both ankles pinned by position");
	Model m;
	if (m.open(PERSON)) turn_the_hips(&m, &v);
	m.close();
	v.finish();
}

// ---------------------------------------------------------------------------
// 9. Mirror

<*
 The test 1 sit, released and keyed, then mirrored with Shift+M, which calls
 `mirror_pose`. Nothing is selected, so it is the whole pose that is reflected, as
 the key does with no selection. A sit is its own mirror image: afterwards both
 knees still fold, the ankles are still on their pins, and every joint is inside
 its limits.
*>
fn void mirror_a_sit(Model* m, Verdict* v)
{
	float h = m.height;
	Frame start = m.frame();
	defer start.free();
	m.pin_position("ankle_L");
	m.pin_position("ankle_R");

	Sweep s = m.grab("spine");
	s.to({ 0, -0.18f * h, 0 });
	v.smooth(&s);
	s.finish();
	Frame sat = m.frame();
	defer sat.free();
	Posture before = m.posture(&start, &sat);

	m.app.select(0);
	bool mirrored = m.app.mirror_pose();
	Frame now = m.frame();
	defer now.free();
	Posture after = m.posture(&start, &now);
	float moved;
	foreach (usz j, position : now.position) moved = math::max(moved, (position - sat.position[j]).length() / h);

	note("  before the mirror");
	before.print();
	note("  after the mirror (mirror_pose returned %s)", mirrored);
	after.print();
	note("  the mirror moved a joint by up to %.4f heights", moved);
	v.expect(mirrored, "the mirror was refused");
	v.moved(&before);
	v.expect(after.fold_l > 60.0f, "the left knee folded only %.1f degrees after the mirror (need over 60)", after.fold_l);
	v.expect(after.fold_r > 60.0f, "the right knee folded only %.1f degrees after the mirror (need over 60)", after.fold_r);
	v.held("ankle_L", after.ankle_l);
	v.held("ankle_R", after.ankle_r);
	v.inside_limits(&after);
}

fn void a_mirrored_sit_is_a_sit() @test
{
	Verdict v = verdict("humanoid: the sit, then Shift+M (mirror_pose) over the whole pose");
	Model m;
	if (m.open(PERSON)) mirror_a_sit(&m, &v);
	m.close();
	v.finish();
}

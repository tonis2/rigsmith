<*
 Suggest limits: the rest bend's tables (`read_limit_shapes`), narrowed where
 the mesh stops a joint against its parent, shared across matching limbs and
 widened to what the rig's clips use, as one undo step.
*>
module crig;

import rig;
import collision;
import std::math;
import std::math::quaternion;
import std::collections::list;
import std::collections::set;
import std::time;

// The sweep's step, and how often the last step is halved.
const float SUGGEST_SWEEP_STEP = 10.0f * SUGGEST_DEGREE;
const usz SUGGEST_SWEEP_HALVINGS = 3;
// The crease round the pivot touches at every angle; this many thicknesses of it don't count.
const float SUGGEST_PIVOT_THICKNESSES = 1.5f;
const double SUGGEST_SWEEP_SECONDS = 3.0;
const float SUGGEST_CLIP_FPS = 30.0f;
const usz SUGGEST_CLIP_MOST_FRAMES = 900;

struct LimitSuggestion
{
	usz written;
	usz hinges;
	usz cones;
	// Joints the mesh stopped one way or more.
	usz from_mesh;
	usz from_clips;
	// Joints the time budget left on their defaults.
	usz unswept;
}

<*
 Suggest a limit table for each joint, as one undo step.

 @param only : "When not empty, the dots to write, overwriting their tables; empty fills every joint that has none"
 @param commit : "Close the undo group"
 @return "What was written"
*>
fn LimitSuggestion AppState.suggest_limits(&self, uint[] only = {}, bool commit = true)
{
	LimitSuggestion report;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return report;
	RigView view = opened;
	defer view.free(mem);
	usz count = view.len();
	if (count == 0) return report;

	SuggestedJoint[] joints = alloc::new_array(mem, SuggestedJoint, (sz)count);
	defer alloc::free(mem, joints);
	read_limit_shapes(&view.skeleton, joints);
	bool bound = self.rebind_skin(&view) && self.skin_joints == (uint)count;

	bool[] writes = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, writes);
	for (usz j = 0; j < count; j++)
	{
		if (joints[j].shape == SKIP) continue;
		// A turn that carries the whole skin is the root's in all but name.
		if (bound)
		{
			uint[] moving = subtree_joints(mem, &view.skeleton, j);
			bool whole = self.moves_whole_skin(moving);
			if (moving.len > 0) alloc::free(mem, moving);
			if (whole) { joints[j].shape = SKIP; continue; }
		}
		uint id = view.dot_ids[j];
		writes[j] = only.len > 0 ? dot_in(only, id) : self.doc.rotation_limits_of(id).same(unconstrained_rotation(id));
	}

	// The whole group is swept, so a joint written alone still takes its group's median.
	bool[] swept = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, swept);
	for (usz j = 0; j < count; j++)
	{
		if (!writes[j]) continue;
		for (usz k = 0; k < count; k++)
		{
			if (joints[k].shape != SKIP && joints[k].group == joints[j].group) swept[k] = true;
		}
	}
	if (bound)
	{
		self.sweep_limits(&view, joints, swept, &report);
	}
	else
	{
		foreach (usz j, s : swept) if (s && writes[j]) report.unswept++;
	}
	share_in_groups(joints);

	JointRotationLimits[] tables = alloc::new_array(mem, JointRotationLimits, (sz)count);
	defer alloc::free(mem, tables);
	for (usz j = 0; j < count; j++)
	{
		if (!writes[j]) continue;
		tables[j] = suggested_table(&view.skeleton, view.dot_ids, j, joints[j]);
		bool met = false;
		foreach (m : joints[j].met) met = met || m;
		if (met) report.from_mesh++;
	}
	report.from_clips = self.widen_limits_to_clips(&view, tables, writes);

	sz before = self.undo_stack.edits.len();
	List{uint} written;
	written.init(mem);
	defer written.free();
	for (usz j = 0; j < count; j++)
	{
		if (!writes[j]) continue;
		if (!self.set_rotation_limits_recorded(view.dot_ids[j], tables[j])) continue;
		written.push(view.dot_ids[j]);
		if (joints[j].shape == HINGE) { report.hinges++; } else { report.cones++; }
	}
	report.written = (usz)written.len();
	if (report.written > 0) self.mend_hinge_limits(only: written.array_view());
	if (commit && self.undo_stack.edits.len() != before) self.undo_stack.commit();
	if (report.written > 0) self.mark_rig_stale();
	return report;
}

<*
 Narrow the reach of every swept joint to where its subtree's mesh first meets
 its parent's, starting from rest, within the time budget. The surface is put
 back at the draft pose afterwards.
*>
fn void AppState.sweep_limits(&self, RigView* view, SuggestedJoint[] joints, bool[] swept, LimitSuggestion* report)
{
	usz count = view.len();
	rig::Pose rest = rig::rest_pose(mem, count);
	defer rest.free(mem);
	Matrix4f[]? at_rest = rig::joint_palette(mem, &view.skeleton, rest);
	if (catch at_rest) return;
	self.deformed_surface.refit_all(self.skin, at_rest, self.next_pose_generation());
	alloc::free(mem, at_rest);
	defer
	{
		rig::Pose draft = self.draft_pose(mem, view);
		Matrix4f[] palette;
		if (self.refit_collision_surface(view, draft, {}, &palette) != 0) alloc::free(mem, palette);
		draft.free(mem);
	}

	Vec3[] tails = view.skeleton.tails(mem);
	defer alloc::free(mem, tails);
	bool[] may_meet = alloc::new_array(mem, bool, (sz)(count * count));
	defer alloc::free(mem, may_meet);
	Clock clock = clock::now();
	for (usz j = 0; j < count; j++)
	{
		if (!swept[j] || joints[j].shape == SKIP) continue;
		if (clock.to_now().to_sec() > SUGGEST_SWEEP_SECONDS)
		{
			report.unswept++;
			continue;
		}
		self.sweep_joint(view, j, &joints[j], tails, may_meet, &rest);
	}
}

fn void AppState.sweep_joint(&self, RigView* view, usz j, SuggestedJoint* s, Vec3[] tails, bool[] may_meet, rig::Pose* rest)
{
	usz count = view.len();
	usz parent = (usz)view.skeleton.parents[j];
	uint[] moving = subtree_joints(mem, &view.skeleton, j);
	defer if (moving.len > 0) alloc::free(mem, moving);
	if (moving.len == 0) return;

	may_meet[..] = false;
	foreach (m : moving)
	{
		may_meet[(usz)m * count + parent] = true;
		may_meet[parent * count + (usz)m] = true;
	}
	SweepTest test = {
		.view = view,
		.joint = j,
		.parent = parent,
		.moving = moving,
		.may_meet = may_meet,
		.frame = suggested_frame(&view.skeleton, view.dot_ids, j, *s),
		.pose = rest,
		.pivot = view.skeleton.joints[j],
		.clearance = self.collision_clearance(),
	};
	if (!test.frame.usable()) return;
	float thick = math::max(
		self.deformed_surface.joint_thickness((uint)j, view.skeleton.joints[j], tails[j]),
		self.deformed_surface.joint_thickness((uint)parent, view.skeleton.joints[parent], tails[parent]));
	test.radius_sq = (thick * SUGGEST_PIVOT_THICKNESSES) * (thick * SUGGEST_PIVOT_THICKNESSES);
	test.resting.init(mem);
	defer test.resting.free();
	defer
	{
		// Back at rest for the next joint's parent.
		rest.rotations[j] = quaternion::IDENTITY;
		(void)self.sweep_touches(&test, X_UP, 0.0f, false);
	}

	// What already touches at rest is how the model was made, not a stop.
	(void)self.sweep_touches(&test, X_UP, 0.0f, true);
	foreach (usz way, &reach : s.reach)
	{
		float limit = *reach;
		if (limit <= 0.0f) continue;
		SwingWay going = (SwingWay)way;
		float clear = 0.0f;
		float hit = -1.0f;
		for (float angle = SUGGEST_SWEEP_STEP; ; angle += SUGGEST_SWEEP_STEP)
		{
			float at = math::min(angle, limit);
			if (self.sweep_touches(&test, going, at, false)) { hit = at; break; }
			clear = at;
			if (at >= limit) break;
		}
		if (hit < 0.0f) continue;
		for (usz i = 0; i < SUGGEST_SWEEP_HALVINGS; i++)
		{
			float middle = (clear + hit) * 0.5f;
			if (self.sweep_touches(&test, going, middle, false)) { hit = middle; } else { clear = middle; }
		}
		*reach = clear;
		s.met[way] = true;
	}
}

struct SweepTest @private
{
	RigView* view;
	usz joint;
	usz parent;
	uint[] moving;
	bool[] may_meet;
	JointLimitFrame frame;
	rig::Pose* pose;
	Vec3 pivot;
	float radius_sq;
	float clearance;
	// Pairs touching at rest, as `a << 32 | b`.
	HashSet{ulong} resting;
}

<*
 Turn the joint `angle` along `way` from rest and say whether its subtree's
 skin meets its parent's away from the pivot; `record` keeps every touching
 pair as resting rather than stopping at the first.
*>
fn bool AppState.sweep_touches(&self, SweepTest* test, SwingWay way, float angle, bool record)
{
	test.pose.rotations[test.joint] = rotation_from_joint_angles(test.frame, way.angles(angle));
	Matrix4f[]? posed = rig::joint_palette(mem, &test.view.skeleton, *test.pose);
	if (catch posed) return false;
	defer alloc::free(mem, posed);
	uint generation = self.next_pose_generation();
	self.deformed_surface.refit_joints(test.moving, self.skin, posed, generation);

	DeformedTrianglePair[] pairs = self.deformed_surface.broad_phase_pairs_for_joints(
		mem, test.moving, test.clearance, self.skin, {}, test.may_meet);
	defer if (pairs.len > 0) alloc::free(mem, pairs);
	bool touched = false;
	foreach (pair : pairs)
	{
		if (!self.sweep_pair_counts(test, pair)) continue;
		ulong key = (ulong)pair.a << 32 | (ulong)pair.b;
		if (!record && test.resting.contains(key)) continue;
		collision::TriangleVerts one = self.deformed_surface.deformed_triangle(pair.a, self.skin, posed, generation);
		collision::TriangleVerts other = self.deformed_surface.deformed_triangle(pair.b, self.skin, posed, generation);
		if (triangles_apart_by_plane(one, other, test.clearance)) continue;
		if (triangle_gap(one, other).distance > test.clearance) continue;
		if (!record) return true;
		test.resting.add(key);
		touched = true;
	}
	return touched;
}

// One triangle on the turned side, the other the parent's, neither in the crease.
fn bool AppState.sweep_pair_counts(&self, SweepTest* test, DeformedTrianglePair pair)
{
	uint ra = self.deformed_surface.region_for_triangle(pair.a);
	uint rb = self.deformed_surface.region_for_triangle(pair.b);
	bool a_turns = is_moving(test.moving, ra);
	bool b_turns = is_moving(test.moving, rb);
	if (!(a_turns && (usz)rb == test.parent) && !(b_turns && (usz)ra == test.parent)) return false;
	foreach (triangle : (uint[2]){ pair.a, pair.b })
	{
		foreach (corner : self.deformed_surface.rest_triangle(triangle))
		{
			if ((corner - test.pivot).length_sq() < test.radius_sq) return false;
		}
	}
	return true;
}

fn bool is_moving(uint[] moving, uint region) @local
{
	foreach (m : moving) if (m == region) return true;
	return false;
}

<*
 Widen each written table to the angles the rig's bound clips turn it to.

 @return "How many joints a clip widened"
*>
fn usz AppState.widen_limits_to_clips(&self, RigView* view, JointRotationLimits[] tables, bool[] writes)
{
	usz count = view.len();
	JointLimitFrame[] frames = alloc::new_array(mem, JointLimitFrame, (sz)count);
	defer alloc::free(mem, frames);
	Vec3[] low = alloc::new_array(mem, Vec3, (sz)count);
	defer alloc::free(mem, low);
	Vec3[] high = alloc::new_array(mem, Vec3, (sz)count);
	defer alloc::free(mem, high);
	for (usz j = 0; j < count; j++)
	{
		if (writes[j]) frames[j] = joint_limit_frame(&view.skeleton, view.dot_ids, tables[j]);
	}

	for (sz i = 0; i < self.doc.animations.len(); i++)
	{
		AnimRef ref = self.resolve_bound(i);
		if (!ref.valid() || !self.ensure_clip_imported(ref) || !self.clip_applies(ref)) continue;
		AnimTemplate* clip = self.clip(ref);
		if (!clip) continue;
		PoseStages stages = self.stages_for(view, ref);
		usz frames_in = (usz)math::clamp((int)math::ceil(clip.duration * SUGGEST_CLIP_FPS), 1, (int)SUGGEST_CLIP_MOST_FRAMES);
		for (usz f = 0; f <= frames_in; f++)
		{
			@pool()
			{
				rig::Pose pose = stages.sample(tmem, *clip, clip.duration * (float)f / (float)frames_in);
				for (usz j = 0; j < count && j < pose.rotations.len; j++)
				{
					if (!writes[j] || !frames[j].usable()) continue;
					Vec3 angles = joint_angles_from_rotation(frames[j], pose.rotations[j]);
					for (usz a = 0; a < 3; a++)
					{
						low[j][a] = math::min(low[j][a], angles[a]);
						high[j][a] = math::max(high[j][a], angles[a]);
					}
				}
			};
		}
	}

	usz widened = 0;
	for (usz j = 0; j < count; j++)
	{
		if (writes[j] && frames[j].usable() && widen_to_clip(&tables[j], low[j], high[j])) widened++;
	}
	return widened;
}

// The notice a run leaves, for the menu and the joint card alike.
fn void AppState.say_limit_suggestion(&self, LimitSuggestion done)
{
	if (done.written == 0)
	{
		self.@notice("no joint took a suggested limit · the root and joints that already have one are left alone");
		return;
	}
	self.@notice("suggested limits on %d joints (%d hinges, %d cones) · the mesh stopped %d, clips widened %d%s · Ctrl+Z undoes",
		(int)done.written, (int)done.hinges, (int)done.cones, (int)done.from_mesh, (int)done.from_clips,
		done.unswept > 0 ? string::tformat(" · %d kept defaults, out of time", (int)done.unswept) : "");
}

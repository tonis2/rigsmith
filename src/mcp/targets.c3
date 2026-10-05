<*
 solve_targets: place a hand or a foot at a point, and answer with the pose that
 does it.

 The recommendation this answers (animation_plan.md, MCP1) is that authoring a
 clip should not mean guessing shoulder and elbow quaternions until the hand lands
 where it was wanted. crig already has the solver for it — the limit-aware CCD loop
 `solve_limited_pose_chain`, the one `resolve_position_locks` bends a pinned foot
 back to the floor with — so this exposes it: give it a joint and a point, and it
 turns that joint's own run of ancestors (wrist through elbow through shoulder,
 ankle through knee through thigh) until the joint reaches the point, honouring the
 joint limits every step. An optional orientation holds the effector flat once it
 is placed — a palm down, a foot on the floor.

 ## It answers, it does not write

 What comes back is the solved pose as a **keyframe in exactly the shape apply_clip
 takes**, plus a residual per target saying how close each one got. Baking it to
 ordinary, editable keys is one more call — `apply_clip` with that keyframe — the
 same read-then-write round trip `get_clip` and `apply_clip` already are. Keeping
 the solve and the write apart is what lets a caller look at the residuals, nudge a
 target and solve again before committing anything to a clip, and it is what lets
 this be a pure function of the rig and the request: no clip touched, no undo step
 spent, the same answer every time.

 ## Poles, and what is still not here

 Elbow/knee **pole** control — which way a two-bone limb bends — is a per-target
 `pole` point: after the reach, the limb is turned about the line from its root to
 the effector until the bend lies in the plane the pole names, honouring the root
 pivot's limits, and leaving the effector where the reach put it (it is on that
 line). What is still a later increment is a *coupled* position-and-orientation
 solve: orientation here is a hold applied after the reach, which is right for a
 flat foot and enough for a palm, not for a wrist that must both reach and twist
 against its limits at once.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::matrix;
import std::math::quaternion;

faultdef TARGETS_INVALID;

// The most effectors one call places. A seconds-per-call limit like render's — each
// is a full CCD solve — and past the count of limbs a figure has anyway.
const usz TARGETS_MOST @local = 16;

const String SOLVE_TARGETS_SCHEMA = `{"type":"object","properties":{
	"targets":{"type":"array","description":"The hands and feet to place, each reached independently. Left and right limbs do not share joints, so they do not interfere; two targets on one limb would, and the later one wins.","items":{"type":"object","properties":{
		"joint":{"type":"string","description":"The end-effector dot to place — a hand or a foot. Its unbranched run of ancestors (wrist->elbow->shoulder, ankle->knee->thigh) is what bends to reach the target. A joint with no such run — a root, or one whose parent forks like the hips — cannot be placed this way and comes back reached:false."},
		"position":{"type":"array","items":{},"description":"[x,y,z] in model space, the same unnormalised space get_skeleton and get_pose report: +Y up, the model facing +Z. Where the joint should end up. With bake, a path instead: [{\"time\": seconds, \"position\": [x,y,z]}, ...] in time order, the point the joint is to be at over the clip — held before the first key and after the last, or carried round to the first key when the clip loops."},
		"relative_to":{"type":"string","description":"Read position as an offset from this joint's place in the starting pose rather than as an absolute point — \"hands ahead of the knees\" is relative_to a knee with a +Z offset. The offset is measured against the starting pose, before anything is solved."},
		"pole":{"type":"array","items":{"type":"number"},"description":"[x,y,z] in model space the elbow or knee should point toward — the pole vector. Which way a two-bone limb bends is otherwise free, so this settles it: point the knee ahead and the elbow back. Applied after the reach and honouring the joint's limits, so the effector does not move (it is on the root-to-effector line the bend turns about) unless a limit clamps the twist short. Ignored for a limb with only one bend, a target the limb reaches straight, or a pole on the root-to-effector line itself — the result's pole_aimed and pole_note report which."},
		"pole_relative_to":{"type":"string","description":"Read pole as an offset from this joint's place in the starting pose, the way relative_to does for position — a knee pole a little ahead of the hip is pole_relative_to the hip with a +Z offset."},
		"orientation":{"type":"object","description":"Hold the effector at this world orientation once it is placed — a palm down, a foot flat — whatever the limb above it is doing. A quaternion against the model's own axes; omit to leave the effector however the reach left it. get_pose reports a joint's world rotation in this same [x,y,z,w] form to copy from.","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"w":{"type":"number"}},"required":["x","y","z","w"]}
	},"required":["joint","position"]}},
	"from":{"type":"object","description":"The pose to solve from. Omit for the rest pose; give a clip and a time to refine a pose that clip already holds.","properties":{
		"clip":{"type":"string","description":"A clip whose pose at t is the starting point."},
		"t":{"type":"number","description":"Seconds into that clip. Default 0."}
	}},
	"time":{"type":"number","description":"The time in seconds to stamp on the returned keyframe. Default 0. It changes nothing about the solve — only where apply_clip would write the result."},
	"bake":{"type":"object","description":"Solve over time instead of once, and write the result as a clip: at each sample instant every target is solved from the previous instant's pose (the starting pose for the first), so a foot that follows a path does not jump between solutions, and the keys land in the authored pack as one undo step. Targets' positions may then be paths. Nothing is returned as a keyframe; the answer says where the clip landed and how closely each target followed its path.","properties":{
		"clip":{"type":"string","description":"The clip's name in the authored pack; a clip of that name is replaced."},
		"duration":{"type":"number","description":"Seconds. Default the last time any path reaches, else 1."},
		"loop":{"type":"boolean","description":"Whether the clip loops. Default false. A looping clip keys no closing frame, and its paths are carried round from the last key to the first.","default":false},
		"samples":{"type":"number","description":"Keys per clip (intervals, for one that does not loop). Default 30 a second, at least 8, at most 600."},
		"path":{"type":"string","enum":["linear","smooth"],"description":"How a path passes between its keys: straight lines, or a smooth curve through every key. Default linear."}
	},"required":["clip"]}
},"required":["targets"]}`;

// One target, read against the starting pose, then solved into the shared pose.
struct TargetSpec @local
{
	String name;
	uint dot_id;
	Vec3 target;
	Quaternionf orient;
	bool has_orient;
	Vec3 pole;
	bool has_pole;
	bool poled;   // set true when the pole actually turned the bend
	PoleAim pole_result;   // why, when it did not
	bool has_run;
	usz effector;
	float[] path_times;   // bake only: the keyed path, in time order; empty for a fixed point
	Vec3[] path_points;
	float worst_gap;      // bake only: the farthest the joint fell from its point at any instant
}

<*
 solve_targets: reach each effector to its point, then answer with the keyframe.

 @param detail : `Filled with what was wrong, when a target or the request is refused.`
 @return? TARGETS_INVALID : `The reason is in detail.`
*>
fn String? solve_targets_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `solve_targets takes an object: {"targets": [{"joint": name, "position": [x,y,z], "orientation": {"x","y","z","w"}}], "from": {"clip": name, "t": seconds}, "time": seconds}`)) return TARGETS_INVALID~;

	Object* list = member(args, "targets");
	if (list == null || !list.is_array() || list.get_len() == 0)
	{
		detail.append_string(`solve_targets needs "targets": a non-empty array of {"joint": a hand or a foot, "position": [x,y,z] in model space}.`);
		return TARGETS_INVALID~;
	}
	if ((usz)list.get_len() > TARGETS_MOST)
	{
		detail.appendf(`"targets" has %d entries and %d is the most one call places.`, list.get_len(), TARGETS_MOST);
		return TARGETS_INVALID~;
	}
	usz count = (usz)list.get_len();
	Object* bake = member(args, "bake");
	bool baking = bake != null;
	if (baking && !bake.is_keyable())
	{
		detail.append_string(`"bake" must be an object: {"clip": name, "duration": seconds, "loop": bool, "samples": n}`);
		return TARGETS_INVALID~;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(`this document has no dots, so there is no rig to place a joint on. apply_plan fits one; get_scene reports what is loaded.`);
		return TARGETS_INVALID~;
	}
	RigView view = opened;
	defer view.free(mem);

	usz joints = view.skeleton.len();
	float height = view.skeleton.height();
	float tolerance = height > 0.0f ? height * IK_TOLERANCE : 0.0f;

	// The starting pose: rest, or a clip sampled ungrounded at t — ungrounded so the
	// root is not shifted under the reach, which would move a target given relative
	// to a foot.
	rig::Pose pose;
	Object* from = member(args, "from");
	if (from != null && from.is_keyable() && member(from, "clip") != null)
	{
		String? clip_name = from.get_string("clip");
		if (catch clip_name)
		{
			detail.append_string(`"from".clip must be a clip name. get_scene lists every pack and clip.`);
			return TARGETS_INVALID~;
		}
		AnimRef ref = resolve_named(app, clip_name, detail)!;
		double t = from.get_float("t") ?? 0.0;
		pose = app.clip(ref).pose(mem, &view.skeleton, view.names, (float)t, false);
	}
	else
	{
		pose = rig::rest_pose(mem, joints);
	}
	defer pose.free(mem);

	// The starting positions, read once before anything is solved so every relative
	// target and the changed-joint diff below read the same starting frame.
	Matrix4f[]? start_built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch start_built)
	{
		detail.append_string(`the starting pose could not be built.`);
		return TARGETS_INVALID~;
	}
	Matrix4f[] start_pal = start_built;
	defer alloc::free(mem, start_pal);

	Quaternionf[] before = alloc::new_array(mem, Quaternionf, (sz)joints);
	defer alloc::free(mem, before);
	before[:joints] = pose.rotations[:joints];

	// Pass A — read every target against the starting pose.
	TargetSpec[TARGETS_MOST] specs;
	defer
	{
		for (usz i = 0; i < count; i++)
		{
			if (specs[i].path_times.len > 0) alloc::free(mem, specs[i].path_times);
			if (specs[i].path_points.len > 0) alloc::free(mem, specs[i].path_points);
		}
	}
	for (usz i = 0; i < count; i++)
	{
		Object* entry = list.get_at((sz)i);
		if (!entry.is_keyable())
		{
			detail.appendf(`targets[%d] must be an object with a "joint" and a "position".`, i);
			return TARGETS_INVALID~;
		}

		String? given = entry.get_string("joint");
		if (catch given)
		{
			detail.appendf(`targets[%d] needs "joint": the hand or foot to place.`, i);
			return TARGETS_INVALID~;
		}
		String jname = given;
		if (!app.has_dot_named(jname))
		{
			detail.appendf(`targets[%d].joint is "%s", which is not a dot on this rig. get_skeleton lists every joint by name.`, i, jname);
			return TARGETS_INVALID~;
		}

		Vec3 position = {};
		Object* placed = member(entry, "position");
		float[] path_times;
		Vec3[] path_points;
		bool keyed = placed != null && placed.is_array() && placed.get_len() > 0 && placed.get_at(0).is_keyable();
		if (keyed)
		{
			if (!baking)
			{
				detail.appendf(`targets[%d].position is a path, which needs "bake" to say what clip to write. Without it, give one [x,y,z].`, i);
				return TARGETS_INVALID~;
			}
			if (!parse_path(placed, i, &path_times, &path_points, detail)) return TARGETS_INVALID~;
			position = path_points[0];
			specs[i].path_times = path_times;
			specs[i].path_points = path_points;
		}
		else if (!as_vec3(placed, &position))
		{
			detail.appendf(`targets[%d].position must be [x,y,z] in model space.`, i);
			return TARGETS_INVALID~;
		}

		Vec3 target = position;
		if (try rel = entry.get_string("relative_to"))
		{
			if (!app.has_dot_named(rel))
			{
				detail.appendf(`targets[%d].relative_to is "%s", which is not a dot on this rig. get_skeleton lists every joint by name.`, i, rel);
				return TARGETS_INVALID~;
			}
			sz rj = view.joint_of(app.dot_named(rel).id);
			if (rj >= 0)
			{
				Vec3 base = view.skeleton.joints[(usz)rj].transform(start_pal[(usz)rj]);
				target = target + base;
				foreach (&point : path_points) *point = *point + base;
			}
		}

		Vec3 pole = {};
		bool has_pole = false;
		Object* pole_at = member(entry, "pole");
		if (pole_at != null)
		{
			if (!as_vec3(pole_at, &pole))
			{
				detail.appendf(`targets[%d].pole must be [x,y,z] in model space — the point the elbow or knee should point toward.`, i);
				return TARGETS_INVALID~;
			}
			has_pole = true;
			if (try prel = entry.get_string("pole_relative_to"))
			{
				if (!app.has_dot_named(prel))
				{
					detail.appendf(`targets[%d].pole_relative_to is "%s", which is not a dot on this rig. get_skeleton lists every joint by name.`, i, prel);
					return TARGETS_INVALID~;
				}
				sz pj = view.joint_of(app.dot_named(prel).id);
				if (pj >= 0) pole = pole + view.skeleton.joints[(usz)pj].transform(start_pal[(usz)pj]);
			}
		}

		Quaternionf orient = quaternion::IDENTITY;
		bool has_orient = false;
		Object* orientation = member(entry, "orientation");
		if (orientation != null)
		{
			if (!as_quat(orientation, &orient))
			{
				detail.appendf(`targets[%d].orientation must be a quaternion {"x","y","z","w"} against the model's own axes.`, i);
				return TARGETS_INVALID~;
			}
			orient = orient.normalize();
			has_orient = true;
		}

		specs[i] = {
			.name = jname,
			.dot_id = app.dot_named(jname).id,
			.target = target,
			.orient = orient,
			.has_orient = has_orient,
			.pole = pole,
			.has_pole = has_pole,
			.path_times = path_times,
			.path_points = path_points,
		};
	}

	if (baking) return bake_targets(app, &view, &pose, specs[:count], bake, tolerance, detail);

	// Pass B — solve each effector's limited chain, then hold its orientation. Limits
	// honoured, collision left to the interactive gesture (report: false), so this is
	// a pure, repeatable function of the rig and the request.
	for (usz i = 0; i < count; i++) solve_target(app, &view, &pose, &specs[i], tolerance);

	// Pass C — read where everything ended up, and the keyframe that put it there.
	Matrix4f[]? final_built = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch final_built)
	{
		detail.append_string(`the solved pose could not be built.`);
		return TARGETS_INVALID~;
	}
	Matrix4f[] final_pal = final_built;
	defer alloc::free(mem, final_pal);

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"targets":[`);
	bool all_reached = true;
	for (usz i = 0; i < count; i++)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		json_escape_into(&out, specs[i].name);
		out.append_string(`","target":`);
		append_vec3(&out, specs[i].target);
		if (!specs[i].has_run)
		{
			out.append_string(`,"reached":false,"note":"this joint has no unbranched run of ancestors to bend — a root, or a joint whose parent forks like the hips. Place a hand or a foot instead."}`);
			all_reached = false;
			continue;
		}
		Vec3 at = view.skeleton.joints[specs[i].effector].transform(final_pal[specs[i].effector]);
		float gap = (specs[i].target - at).length();
		float residual = height > 0.0f ? gap / height : gap;
		bool reached = tolerance > 0.0f ? gap <= tolerance : gap < 1.0e-6f;
		if (!reached) all_reached = false;
		out.append_string(`,"position":`);
		append_vec3(&out, at);
		out.appendf(`,"residual":%.6g,"reached":%s`, residual, reached ? "true" : "false");
		if (specs[i].has_pole)
		{
			out.appendf(`,"pole_aimed":%s`, specs[i].poled ? "true" : "false");
			String note = pole_note(specs[i].pole_result);
			if (note.len > 0)
			{
				out.append_string(`,"pole_note":"`);
				out.append_string(note);
				out.append_string(`"`);
			}
		}
		out.append_char('}');
	}
	out.append_char(']');

	// The keyframe: every joint the reach turned, only the named ones, in exactly the
	// shape apply_clip takes. An unnamed dot is one no clip can address, so a turn on
	// it has nowhere to be written and is left out.
	double stamp = args.get_float("time") ?? 0.0;
	out.appendf(`,"keyframe":{"time":%s,"joints":[`, (JsonFloat)stamp);
	bool first = true;
	for (usz j = 0; j < joints; j++)
	{
		if (view.names[j].len == 0) continue;
		// Same rotation up to sign is no change; the double cover is why it is the
		// absolute dot against one, not the dot.
		if (math::abs(before[j].v.dot(pose.rotations[j].v)) > 0.9999999f) continue;
		if (!first) out.append_char(',');
		first = false;
		Quaternionf r = pose.rotations[j];
		out.append_string(`{"name":"`);
		json_escape_into(&out, view.names[j]);
		out.appendf(`","rotation":{"x":%s,"y":%s,"z":%s,"w":%s}}`, (JsonFloat)r.v.x, (JsonFloat)r.v.y, (JsonFloat)r.v.z, (JsonFloat)r.v.w);
	}
	out.append_string(`]},"reached":`);
	out.append_string(all_reached ? "true" : "false");
	out.append_string(`,"apply":"apply_clip with a name and keyframes:[this keyframe] bakes it to ordinary, editable keys"}`);
	return out.copy_str(mem);
}

// Why a pole did not turn the bend, or an empty string when it did (or was
// clamped, which `pole_aimed` already carries). The words a caller reads to know
// its pole was ignored rather than obeyed.
fn String pole_note(PoleAim result) @local
{
	switch (result)
	{
		case AIMED: return "";
		case AIMED_TO_LIMIT:
			return "aimed as far as the root joint's rotation limits allow, which may leave the bend short of the pole";
		case NO_BEND:
			return "this limb has fewer than two bends, so it has no elbow or knee to aim — the pole was ignored";
		case COINCIDENT:
			return "the effector has folded back onto the chain root, leaving no line to swing the bend about — the pole was ignored";
		case STRAIGHT:
			return "the limb reaches the target straight, so its bend already lies on the root-to-effector line — the pole was ignored";
		case POLE_ON_LINE:
			return "the pole lies on the line from the chain root to the effector, so it names no side to bend toward — the pole was ignored";
	}
}

// A keyed path: [{"time": seconds, "position": [x,y,z]}, ...], in time order.
fn bool parse_path(Object* keys, usz target, float[]* times, Vec3[]* points, DString* detail) @local
{
	usz n = (usz)keys.get_len();
	float[] when = alloc::new_array(mem, float, (sz)n);
	Vec3[] where = alloc::new_array(mem, Vec3, (sz)n);
	for (usz i = 0; i < n; i++)
	{
		Object* key = keys.get_at((sz)i);
		double time = key.is_keyable() ? (key.get_float("time") ?? -1.0) : -1.0;
		if (!key.is_keyable() || time < 0.0 || !as_vec3(member(key, "position"), &where[i]))
		{
			detail.appendf(`targets[%d].position[%d] must be {"time": seconds, "position": [x,y,z]} — every key of a path is one.`, target, i);
			alloc::free(mem, when);
			alloc::free(mem, where);
			return false;
		}
		when[i] = (float)time;
		if (i > 0 && when[i] < when[i - 1])
		{
			detail.appendf(`targets[%d].position[%d] is at %.9g, before the key ahead of it. Path keys go in time order.`, target, i, time);
			alloc::free(mem, when);
			alloc::free(mem, where);
			return false;
		}
	}
	*times = when;
	*points = where;
	return true;
}

// Key `i` of a path, which for a looping one runs round: the keys repeat a
// duration apart, so a neighbour of the last is the first of the next lap.
fn Vec3 path_key(TargetSpec* spec, usz keys, float duration, bool loop, sz i, float* time) @local
{
	if (!loop)
	{
		sz at = math::clamp(i, (sz)0, (sz)keys - 1);
		*time = spec.path_times[(usz)at];
		return spec.path_points[(usz)at];
	}
	sz n = (sz)keys;
	sz at = ((i % n) + n) % n;
	*time = spec.path_times[(usz)at] + (float)((i - at) / n) * duration;
	return spec.path_points[(usz)at];
}

<*
 Where a keyed path has the joint at `time`.

 A path holds its first point before its first key and its last after its last, or
 — when the clip loops — runs round from the last key to the first of the next lap,
 so a cycle that restates its opening point at the duration closes without a
 kink. Linear goes straight between keys; smooth is a Catmull-Rom curve through
 every one of them.
*>
fn Vec3 path_at(TargetSpec* spec, float time, float duration, bool loop, bool smooth) @local
{
	usz n = spec.path_times.len;
	if (n == 0) return spec.target;
	if (n == 1) return spec.path_points[0];

	// A closing key that restates the opening point at the duration is the loop
	// point itself, not a second key there.
	usz keys = n;
	if (loop && spec.path_times[n - 1] >= spec.path_times[0] + duration - 1.0e-5f) keys = n - 1;
	if (keys < 2) return spec.path_points[0];

	float t = time;
	float from;
	float to;
	path_key(spec, keys, duration, loop, 0, &from);
	if (loop)
	{
		if (t < from) t += duration;
		while (t >= from + duration) t -= duration;
	}
	else
	{
		float last;
		path_key(spec, keys, duration, loop, (sz)keys - 1, &last);
		if (t <= from) return spec.path_points[0];
		if (t >= last) return spec.path_points[keys - 1];
	}

	sz seg = 0;
	sz segments = loop ? (sz)keys : (sz)keys - 1;
	for (sz i = 0; i < segments; i++)
	{
		path_key(spec, keys, duration, loop, i + 1, &to);
		if (t < to || i == segments - 1)
		{
			seg = i;
			break;
		}
	}
	float t0;
	float t1;
	Vec3 p1 = path_key(spec, keys, duration, loop, seg, &t0);
	Vec3 p2 = path_key(spec, keys, duration, loop, seg + 1, &t1);
	float s = t1 - t0 > 1.0e-9f ? math::clamp((t - t0) / (t1 - t0), 0.0f, 1.0f) : 0.0f;
	if (!smooth) return p1 + (p2 - p1) * s;

	float ignored;
	Vec3 p0 = path_key(spec, keys, duration, loop, seg - 1, &ignored);
	Vec3 p3 = path_key(spec, keys, duration, loop, seg + 2, &ignored);
	return 0.5f * ((p1 * 2.0f) + (p2 - p0) * s
		+ (p0 * 2.0f - p1 * 5.0f + p2 * 4.0f - p3) * (s * s)
		+ (p1 * 3.0f - p0 - p2 * 3.0f + p3) * (s * s * s));
}

<*
 Give a three-bone limb its leg rule before the general solve runs.

 A limb of three bones whose last is short against the two above it — a dog's
 hind leg, a hock and a metatarsal; a person's leg with the foot counted — is
 solved by `solve_leg`: the two long bones reach, and the short distal one holds
 the tilt it had while the reach allows, tilting only as far as it needs to.
 A plain CCD turn spreads the reach over every joint of the chain, and so swings
 the paw or the foot about when only the knee ought to work. Anything else — an
 arm, where the last bone is as long as the one above it — is left to CCD alone.

 The seeded turns are held inside the joints' limits, and the limited solve runs
 after as it always did, so a limit that stops the analytic answer is still
 honoured and a target the analytic answer only nearly reached is finished.
*>
fn void seed_leg(AppState* app, RigView* view, rig::Pose* pose, PoseChain chain, Vec3 target) @local
{
	usz[4] joints = { chain.joints[2], chain.joints[1], chain.joints[0], chain.effector };
	Quaternionf[]? read = pose.world_rotations(mem, &view.skeleton);
	if (catch read) return;
	Quaternionf[] world = read;
	defer alloc::free(mem, world);
	Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, *pose);
	if (catch built) return;
	Matrix4f[] palette = built;
	defer alloc::free(mem, palette);

	LegChain leg = { .bones = 3 };
	for (usz i = 0; i < 4; i++)
	{
		leg.at[i] = view.skeleton.joints[joints[i]].transform(palette[joints[i]]);
		leg.turn[i] = world[joints[i]];
	}
	int above = view.skeleton.parents[joints[0]];
	leg.parent = above >= 0 ? world[(usz)above] : (Quaternionf)quaternion::IDENTITY;

	float l0 = (leg.at[1] - leg.at[0]).length();
	float l1 = (leg.at[2] - leg.at[1]).length();
	float l2 = (leg.at[3] - leg.at[2]).length();
	if (!(l2 <= 0.65f * l1 && l2 <= l0)) return;

	LegSolve solved = solve_leg(&leg, target, 0.0f);
	for (usz i = 0; i < 3; i++)
	{
		Quaternionf local = solved.local[i];
		uint dot = view.dot_ids[joints[i]];
		JointRotationLimits limits = app.doc.rotation_limits_of(dot);
		if (limits.constrained)
		{
			JointLimitFrame frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
			if (frame.usable()) local = constrain_joint_rotation(frame, limits, local);
		}
		pose.rotations[joints[i]] = local;
	}
}

<*
 One target solved into the shared pose: the reach, then the pole, then the
 orientation hold. Limits honoured, collision left to the interactive gesture
 (report: false), so this is a pure, repeatable function of the rig and the
 request.
*>
fn void solve_target(AppState* app, RigView* view, rig::Pose* pose, TargetSpec* spec, float tolerance) @local
{
	PoseChain chain = app.pose_chain(view, spec.dot_id);
	spec.effector = chain.effector;
	spec.has_run = chain.count > 0;
	if (chain.count > 0)
	{
		if (chain.count == 3) seed_leg(app, view, pose, chain, spec.target);
		Vec3[IK_MAX_CHAIN + 1] points;
		app.chain_points(view, chain, *pose, {}, points[:chain.count + 1]);
		(void)app.solve_limited_pose_chain(view, chain, pose,
			points[:chain.count + 1], spec.target, tolerance, {}, false);
	}
	// The pole after the reach — it turns the bend about the root-to-effector line
	// the reach settled, leaving the effector where the reach put it — and the
	// orientation hold last, since it reads the frame the pole leaves.
	if (spec.has_pole)
	{
		spec.pole_result = chain.count >= 2
			? app.aim_chain_pole(view, pose, chain, spec.pole)
			: PoleAim.NO_BEND;
		spec.poled = spec.pole_result == AIMED || spec.pole_result == AIMED_TO_LIMIT;
	}
	if (spec.has_orient) app.hold_world_rotation(view, pose, spec.dot_id, spec.orient);
}

<*
 solve_targets with "bake": the targets solved at every instant of a clip, written
 as its keys.

 Each instant starts from the pose the last left, so a foot following a path stays
 in one solution instead of hopping between the ones that reach each point; a
 looping clip is run round once unrecorded first, so its opening key is the pose
 its closing one flows into. A key is written on every joint the solve ever turned,
 at every instant, so the track a caller reads back is dense rather than sparse.
*>
fn String? bake_targets(AppState* app, RigView* view, rig::Pose* start, TargetSpec[] specs,
	Object* bake, float tolerance, DString* detail) @local
{
	String clip_name;
	if (!required_string(bake, "clip", &clip_name, detail, `bake needs "clip": the name to write the clip under.`)) return TARGETS_INVALID~;

	float last;
	foreach (&spec : specs)
	{
		if (spec.path_times.len > 0) last = math::max(last, spec.path_times[spec.path_times.len - 1]);
	}
	double duration = bake.get_float("duration") ?? (last > 0.0f ? (double)last : 1.0);
	if (!(duration > 0.0) || duration > 600.0)
	{
		detail.appendf(`bake.duration is %.9g. It is seconds, more than zero.`, duration);
		return TARGETS_INVALID~;
	}
	bool loop = bake.get_bool("loop") ?? false;
	double wanted = bake.get_float("samples") ?? math::clamp(math::round(duration * 30.0), 8.0, 600.0);
	if (wanted < 2 || wanted > 600)
	{
		detail.appendf(`bake.samples is %.9g. It is a whole number from 2 to 600.`, wanted);
		return TARGETS_INVALID~;
	}
	usz samples = (usz)wanted;
	bool smooth;
	if (try mode = bake.get_string("path"))
	{
		if (mode == "smooth")
		{
			smooth = true;
		}
		else if (mode != "linear")
		{
			detail.appendf(`bake.path is "%s". It is "linear" or "smooth".`, mode);
			return TARGETS_INVALID~;
		}
	}

	usz joints = view.skeleton.len();
	float height = view.skeleton.height();
	usz keys = loop ? samples : samples + 1;

	rig::Pose pose = start.copy(mem);
	defer pose.free(mem);
	Quaternionf[] kept = alloc::new_array(mem, Quaternionf, (sz)(keys * joints));
	defer alloc::free(mem, kept);

	// One lap unrecorded when it loops; then the recorded one.
	usz laps = loop ? 2 : 1;
	for (usz lap = 0; lap < laps; lap++)
	{
		bool recording = lap == laps - 1;
		for (usz k = 0; k < keys; k++)
		{
			float time = (float)duration * (float)k / (float)samples;
			foreach (&spec : specs)
			{
				if (spec.path_times.len > 0) spec.target = path_at(spec, time, (float)duration, loop, smooth);
				solve_target(app, view, &pose, spec, tolerance);
			}
			if (!recording) continue;
			kept[k * joints:joints] = pose.rotations[:joints];

			Matrix4f[]? built = rig::joint_palette(mem, &view.skeleton, pose);
			if (catch built) continue;
			Matrix4f[] palette = built;
			defer alloc::free(mem, palette);
			foreach (&spec : specs)
			{
				if (!spec.has_run) continue;
				Vec3 at = view.skeleton.joints[spec.effector].transform(palette[spec.effector]);
				spec.worst_gap = math::max(spec.worst_gap, (spec.target - at).length());
			}
		}
	}

	// The joints the solve ever turned away from where the pose started.
	bool[] turned = alloc::new_array(mem, bool, (sz)joints);
	defer alloc::free(mem, turned);
	usz changed;
	for (usz j = 0; j < joints; j++)
	{
		if (view.names[j].len == 0) continue;
		for (usz k = 0; k < keys && !turned[j]; k++)
		{
			if (math::abs(start.rotations[j].v.dot(kept[k * joints + j].v)) <= 0.9999999f) turned[j] = true;
		}
		if (turned[j]) changed++;
	}
	if (changed == 0)
	{
		detail.append_string(`no joint moved: every target is already where its path puts it, or has no run of joints to bend. Nothing was written.`);
		return TARGETS_INVALID~;
	}

	AnimKeyframe[] frames = alloc::new_array(mem, AnimKeyframe, (sz)keys);
	for (usz k = 0; k < keys; k++)
	{
		AnimKeyDot[] dots = alloc::new_array(mem, AnimKeyDot, (sz)changed);
		usz d;
		for (usz j = 0; j < joints; j++)
		{
			if (!turned[j]) continue;
			AnimKeyDot dot = { .joint_name = view.names[j].copy(mem), .channels = AnimChannels.ROTATION };
			axis_angle_of(kept[k * joints + j], &dot.axis, &dot.angle);
			dots[d++] = dot;
		}
		frames[k] = { .time = (float)duration * (float)k / (float)samples, .dots = dots };
	}
	AnimTemplate clip = {
		.name = clip_name.copy(mem),
		.duration = (float)duration,
		.keyframes = frames,
		.loop = loop,
		.blend = LINEAR,
		.owned = true,
	};
	bool replaced;
	AnimRef landed = app.author_clip(clip, &replaced);
	app.refresh_ui();

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"baked":{"clip":"`);
	json_escape_into(&out, clip_name);
	out.appendf(`","duration":%s,"loop":%s,"keys":%d,"joints_keyed":%d},"targets":[`,
		(JsonFloat)duration, loop ? "true" : "false", keys, changed);
	bool all_reached = true;
	foreach (i, &spec : specs)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		json_escape_into(&out, spec.name);
		out.append_char('"');
		if (!spec.has_run)
		{
			out.append_string(`,"reached":false,"note":"this joint has no unbranched run of ancestors to bend — a root, or a joint whose parent forks like the hips."}`);
			all_reached = false;
			continue;
		}
		bool reached = tolerance > 0.0f ? spec.worst_gap <= tolerance : spec.worst_gap < 1.0e-6f;
		if (!reached) all_reached = false;
		out.appendf(`,"worst_residual":%.6g,"reached":%s}`, height > 0.0f ? spec.worst_gap / height : spec.worst_gap, reached ? "true" : "false");
	}
	String applied = applied_json(app, landed, replaced);
	defer applied.free(mem);
	out.append_string(`],"reached":`);
	out.append_string(all_reached ? "true" : "false");
	out.append_string(`,"landed":`);
	out.append_string(applied);
	out.append_char('}');
	return out.copy_str(mem);
}

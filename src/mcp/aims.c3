<*
 The look-at tools: `get_aims` reads a clip's targets and locks, `set_aim_target`
 creates, keys, mutes or removes a target, and `set_aim` locks a joint to one.

 A look-at target is a named point in space; a lock turns a joint, usually the
 head or a finger, toward it (see anim/aim.c3). Any number of joints may lock to
 one target. The turn is laid over the finished pose when the clip is shown or
 played and never written into its keys, so removing or muting a lock or a target
 gives the authored motion back exactly.

 - A target is `at`, `[x, y, z]` in model space as a **fraction of the rig's
   height**, the way a key's `move` is, so one clip aims the same way on a rig
   exported in metres or in centimetres.
 - `set_aim_target` with a missing or new `name` creates a target (it needs
   `at`); on an existing one `at` keys a position at `time`.
 - `set_aim` on a joint with no lock creates one. The aim axis is captured the
   "stays put" way: the direction from the joint to the target on the clip's own
   (aimed) pose at `time`, in the joint's frame, so locking turns nothing.
 - Every call is one `land_clip`, one undo step, and a library clip is forked
   into the authored pack as any edit is.
 - Targets and locks live in the project sidecar only (save_project).
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::vector;
import std::math::quaternion;

faultdef AIM_REFUSED;

const String GET_AIMS_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip whose look-at targets and locks to read."}
},"required":["clip"]}`;

const String SET_AIM_TARGET_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip to put the target on."},
	"name":{"type":"string","description":"The target's name. Missing or new creates a target (default name: the lowest unused \"Target N\")."},
	"at":{"type":"array","items":{"type":"number"},"description":"[x,y,z] where the target is, in model space as a fraction of the rig's height. Needed to create a target; on an existing one it keys the position at time."},
	"time":{"type":"number","description":"Seconds the position is keyed at, default 0. Between keys the target blends linearly."},
	"interpolation":{"type":"string","description":"How the segment leaving this key reads: \"linear\" (default) or \"hold\"."},
	"mute":{"type":"boolean","description":"Silences the target and every lock on it; the authored motion plays unchanged."},
	"remove":{"type":"boolean","description":"Delete the named target and every lock on it, and ignore every other field."}
},"required":["clip"]}`;

const String SET_AIM_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip to put the lock on."},
	"joint":{"type":"string","description":"The joint that looks, by the name get_skeleton reports. Usually the head."},
	"target":{"type":"string","description":"The name of the target it locks to, from get_aims or set_aim_target. Needed unless removing."},
	"time":{"type":"number","description":"Seconds at which the aim axis is captured on a new lock, default 0."},
	"spread":{"type":"integer","description":"How many joints share the turn: the locked joint and spread-1 parents, 1 to 4. Default 3."},
	"weights":{"type":"array","items":{"type":"number"},"description":"Each joint's share, the locked joint first, up to 4 numbers of 0 or more. Default [0.5,0.3,0.2]."},
	"influence":{"type":"number","description":"0 to 1, how much of the turn is taken. Default 1."},
	"mute":{"type":"boolean","description":"Silences the lock; the authored motion plays unchanged."},
	"remove":{"type":"boolean","description":"Delete the joint's lock and ignore every other field."}
},"required":["clip","joint"]}`;

// `"targets":[...],"locks":[...]`, with no braces round them.
fn void append_aim_lists_json(DString* out, AnimAim[] aims, AnimAimTarget[] targets) @local
{
	out.append_string(`"targets":[`);
	foreach (usz i, &target : targets)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"name":`);
		append_json_string(out, target.name);
		out.appendf(`,"mute":%s,"keys":[`, target.mute ? "true" : "false")!!;
		foreach (usz k, key : target.keys)
		{
			if (k > 0) out.append_char(',');
			out.appendf(`{"time":%s,"at":`, (JsonFloat)key.time)!!;
			append_vec3(out, key.at);
			out.appendf(`,"interpolation":"%s"}`, key.interpolation == HOLD ? "hold" : "linear")!!;
		}
		out.append_string("]}");
	}
	out.append_string(`],"locks":[`);
	foreach (usz i, &aim : aims)
	{
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":`);
		append_json_string(out, aim.joint);
		out.append_string(`,"target":`);
		append_json_string(out, aim.target);
		out.append_string(`,"forward":`);
		append_vec3(out, aim.forward);
		out.appendf(`,"spread":%d,"weights":[%s,%s,%s,%s],"influence":%s,"mute":%s}`,
			aim.spread, (JsonFloat)aim.weights[0], (JsonFloat)aim.weights[1],
			(JsonFloat)aim.weights[2], (JsonFloat)aim.weights[3],
			(JsonFloat)aim.influence, aim.mute ? "true" : "false")!!;
	}
	out.append_char(']');
}

<*
 A clip's targets and locks as one JSON object: `{"targets":[...],"locks":[...]}`.
*>
fn void append_aims_json(DString* out, AnimAim[] aims, AnimAimTarget[] targets)
{
	out.append_char('{');
	append_aim_lists_json(out, aims, targets);
	out.append_char('}');
}

fn String aims_answer(AppState* app, AnimRef ref, String op) @local
{
	AnimTemplate* clip = app.clip(ref);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, clip.name);
	if (op.len > 0) out.appendf(`,"op":"%s"`, op)!!;
	out.append_char(',');
	append_aim_lists_json(&out, clip.aims, clip.aim_targets);
	out.append_char('}');
	return out.copy_str(mem);
}

<*
 get_aims: a clip's look-at targets and the locks on them.

 @return? AIM_REFUSED : `The reason is in detail.`
*>
fn String? get_aims_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `get_aims takes an object: {"clip": name}`)) return AIM_REFUSED~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `get_aims needs "clip": the clip to read. get_scene lists every pack and clip.`)) return AIM_REFUSED~;
	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref) || app.clip(ref) == null)
	{
		detail.append_string(`this clip could not be read.`);
		return AIM_REFUSED~;
	}
	return aims_answer(app, ref, "");
}

// A finite number field; the reason in detail.
fn bool aim_number(Object* args, String key, double* into, DString* detail) @local
{
	double? given = args.get_float(key);
	if (catch given)
	{
		detail.appendf(`"%s" must be a number`, key);
		return false;
	}
	if (!math::is_finite(given))
	{
		detail.appendf(`"%s" must be finite`, key);
		return false;
	}
	*into = given;
	return true;
}

<*
 The aim axis that makes a new lock turn nothing: the direction to the target
 read in the joint's own frame on the clip's aimed pose at `time`, or +Z when the
 target is on the joint.
*>
fn Vec3 aim_forward_at(AppState* app, RigView* view, AnimTemplate clip, AnimRef ref, float time,
	usz joint, Vec3 at)
{
	rig::Pose pose = app.evaluated_clip_pose(mem, view, clip, ref, time, true, true);
	defer pose.free(mem);
	Vec3 position;
	Quaternionf world;
	if (!aim_frame(view, pose, joint, &position, &world)) return { 0, 0, 1 };
	return aim_forward_for(position, world, view.skeleton.height(), at);
}

// `time`, a non-negative number of seconds, default 0; the reason in detail.
fn bool aim_time_arg(Object* args, double* time, DString* detail) @local
{
	*time = 0.0;
	if (member(args, "time") != null && !aim_number(args, "time", time, detail)) return false;
	if (*time < 0.0)
	{
		detail.appendf(`"time" is %.9g; a key sits at 0 or later`, *time);
		return false;
	}
	return true;
}

<*
 set_aim_target: create, key, mute or remove one look-at target.

 One undo step: the whole clip is swapped.

 @return? AIM_REFUSED : `The reason is in detail.`
*>
fn String? set_aim_target_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `set_aim_target takes an object: {"clip": name, "name": name, "at": [x,y,z], ...}`)) return AIM_REFUSED~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `set_aim_target needs "clip": the clip to put the target on. get_scene lists every pack and clip.`)) return AIM_REFUSED~;
	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string(`this clip could not be read back to edit.`);
		return AIM_REFUSED~;
	}
	AnimTemplate* src = app.clip(ref);
	if (src == null || src.keyframes.len == 0)
	{
		detail.append_string(`this clip has no keys to aim over.`);
		return AIM_REFUSED~;
	}

	String name;
	bool named = member(args, "name") != null;
	if (named)
	{
		String? given = args.get_string("name");
		if (catch given)
		{
			detail.append_string(`"name" must be a string`);
			return AIM_REFUSED~;
		}
		name = given;
		if (name.len == 0)
		{
			detail.append_string(`"name" must not be empty`);
			return AIM_REFUSED~;
		}
	}
	sz at = named ? aim_target_index_of(src.aim_targets, name) : -1;

	if (args.get_bool("remove") ?? false)
	{
		if (at < 0)
		{
			detail.appendf(`this clip has no target named "%s"`, named ? name : "");
			return AIM_REFUSED~;
		}
		AnimRef landed = app.land_clip(ref, clip_without_aim_target(mem, *src, name));
		if (!landed.valid())
		{
			detail.append_string(`the clip could not be landed.`);
			return AIM_REFUSED~;
		}
		return aims_answer(app, landed, "remove");
	}

	Vec3 target;
	bool has_target = member(args, "at") != null;
	if (has_target && !as_vec3(member(args, "at"), &target))
	{
		detail.append_string(`"at" must be [x, y, z], three numbers`);
		return AIM_REFUSED~;
	}
	if (has_target && !(math::is_finite(target.x) && math::is_finite(target.y) && math::is_finite(target.z)))
	{
		detail.append_string(`"at" must be finite`);
		return AIM_REFUSED~;
	}
	double time;
	if (!aim_time_arg(args, &time, detail)) return AIM_REFUSED~;
	AnimInterpolation interpolation = LINEAR;
	if (member(args, "interpolation") != null)
	{
		String? given = args.get_string("interpolation");
		if (catch given)
		{
			detail.append_string(`"interpolation" is "linear" or "hold"`);
			return AIM_REFUSED~;
		}
		if (given == "hold")
		{
			interpolation = HOLD;
		}
		else if (given != "linear")
		{
			detail.appendf(`"interpolation" is "%s". It is "linear" or "hold".`, given);
			return AIM_REFUSED~;
		}
	}
	bool has_mute = member(args, "mute") != null;
	bool mute = args.get_bool("mute") ?? false;

	AnimTemplate built;
	if (at < 0)
	{
		if (!has_target)
		{
			detail.append_string(`a new target needs "at": [x,y,z]`);
			return AIM_REFUSED~;
		}
		String made = named ? name : next_target_name(mem, src.aim_targets);
		AnimAimTarget fresh = aim_target_defaults(mem, made, target, (float)time);
		if (!named) alloc::free(mem, made.ptr);
		fresh.keys[0].interpolation = interpolation;
		fresh.mute = mute;
		built = clip_with_aim_target(mem, *src, fresh);
	}
	else
	{
		AnimAimTarget held = src.aim_targets[(usz)at].copy(mem);
		if (has_mute) held.mute = mute;
		built = clip_with_aim_target(mem, *src, held);
		if (has_target)
		{
			AnimTemplate keyed = clip_with_target_key(mem, built, name,
				{ .time = (float)time, .at = target, .interpolation = interpolation });
			built.free(mem);
			built = keyed;
		}
	}

	AnimRef landed = app.land_clip(ref, built);
	if (!landed.valid())
	{
		detail.append_string(`the clip could not be landed.`);
		return AIM_REFUSED~;
	}
	return aims_answer(app, landed, at < 0 ? "add" : "update");
}

<*
 set_aim: lock a joint to a target, retune the lock, or remove it.

 One undo step: the whole clip is swapped.

 @return? AIM_REFUSED : `The reason is in detail.`
*>
fn String? set_aim_json(AppState* app, Object* args, DString* detail)
{
	if (!takes_object(args, detail, `set_aim takes an object: {"clip": name, "joint": name, "target": name, ...}`)) return AIM_REFUSED~;
	String clip_name;
	if (!required_string(args, "clip", &clip_name, detail, `set_aim needs "clip": the clip to put the lock on. get_scene lists every pack and clip.`)) return AIM_REFUSED~;
	String joint_name;
	if (!required_string(args, "joint", &joint_name, detail, `set_aim needs "joint": the joint that looks, by the name get_skeleton reports.`)) return AIM_REFUSED~;
	if (!app.has_dot_named(joint_name))
	{
		detail.appendf(`"joint" is "%s", which is not a dot on this rig`, joint_name);
		append_addressable(detail, app, joint_name);
		return AIM_REFUSED~;
	}

	AnimRef ref = resolve_named(app, clip_name, detail)!;
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string(`this clip could not be read back to edit.`);
		return AIM_REFUSED~;
	}
	AnimTemplate* src = app.clip(ref);
	if (src == null || src.keyframes.len == 0)
	{
		detail.append_string(`this clip has no keys to aim over.`);
		return AIM_REFUSED~;
	}

	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(`there is no rig to aim on.`);
		return AIM_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	// The joint as this clip names it, and as the skeleton indexes it.
	String[] names = app.names_for(&view, ref);
	sz joint = -1;
	foreach (usz j, name : view.names) if (name == joint_name) { joint = (sz)j; break; }
	if (joint < 0 || (usz)joint >= names.len)
	{
		detail.appendf(`"%s" is not a joint of the rig the clip is played on`, joint_name);
		return AIM_REFUSED~;
	}
	String vocabulary = names[(usz)joint];

	sz at = aim_index_of(src.aims, vocabulary);
	if (args.get_bool("remove") ?? false)
	{
		if (at < 0)
		{
			detail.appendf(`"%s" has no look-at lock on this clip`, joint_name);
			return AIM_REFUSED~;
		}
		AnimRef landed = app.land_clip(ref, clip_without_aim(mem, *src, vocabulary));
		if (!landed.valid())
		{
			detail.append_string(`the clip could not be landed.`);
			return AIM_REFUSED~;
		}
		return aims_answer(app, landed, "remove");
	}

	// Every field is read and checked before anything is built, so a refusal
	// touches nothing.
	String target_name;
	bool has_name = member(args, "target") != null;
	if (has_name)
	{
		String? given = args.get_string("target");
		if (catch given)
		{
			detail.append_string(`"target" must be a string, the name of a target`);
			return AIM_REFUSED~;
		}
		target_name = given;
	}
	else if (at >= 0)
	{
		target_name = src.aims[(usz)at].target;
	}
	else
	{
		detail.appendf(`"%s" has no look-at lock yet; give "target": the name of a target (set_aim_target makes one)`, joint_name);
		return AIM_REFUSED~;
	}
	sz target_at = aim_target_index_of(src.aim_targets, target_name);
	if (target_at < 0)
	{
		detail.appendf(`this clip has no target named "%s"; set_aim_target creates one`, target_name);
		return AIM_REFUSED~;
	}
	double time;
	if (!aim_time_arg(args, &time, detail)) return AIM_REFUSED~;
	double spread = 0.0;
	bool has_spread = member(args, "spread") != null;
	if (has_spread)
	{
		if (!aim_number(args, "spread", &spread, detail)) return AIM_REFUSED~;
		if (spread < 1.0 || spread > (double)AIM_MAX_SPREAD || spread != math::floor(spread))
		{
			detail.appendf(`"spread" is %.9g. It is a whole number from 1 to %d.`, spread, AIM_MAX_SPREAD);
			return AIM_REFUSED~;
		}
	}
	float[AIM_MAX_SPREAD] weights;
	Object* weight_list = member(args, "weights");
	if (weight_list != null)
	{
		if (!weight_list.is_array() || weight_list.get_len() < 1 || weight_list.get_len() > (sz)AIM_MAX_SPREAD)
		{
			detail.appendf(`"weights" is an array of 1 to %d numbers, the aimed joint first`, AIM_MAX_SPREAD);
			return AIM_REFUSED~;
		}
		for (sz w = 0; w < weight_list.get_len(); w++)
		{
			double? given = weight_list.get_float_at(w);
			if (catch given)
			{
				detail.append_string(`"weights" holds numbers of 0 or more`);
				return AIM_REFUSED~;
			}
			if (!math::is_finite(given) || given < 0.0)
			{
				detail.append_string(`"weights" holds numbers of 0 or more`);
				return AIM_REFUSED~;
			}
			weights[(usz)w] = (float)given;
		}
	}
	double influence = 1.0;
	bool has_influence = member(args, "influence") != null;
	if (has_influence)
	{
		if (!aim_number(args, "influence", &influence, detail)) return AIM_REFUSED~;
		if (influence < 0.0 || influence > 1.0)
		{
			detail.appendf(`"influence" is %.9g. It is 0 to 1.`, influence);
			return AIM_REFUSED~;
		}
	}
	bool has_mute = member(args, "mute") != null;
	bool mute = args.get_bool("mute") ?? false;

	AnimTemplate built;
	bool recapture = at < 0 || src.aims[(usz)at].target != target_name;
	AnimAim aim;
	if (recapture)
	{
		Vec3 where = src.aim_targets[(usz)target_at].target_at((float)time, src.duration, src.loop);
		Vec3 forward = aim_forward_at(app, &view, *src, ref, (float)time, (usz)joint, where);
		aim = aim_defaults(mem, vocabulary, target_name, forward);
		if (at >= 0)
		{
			// Re-pointed: the lock keeps its settings, only the target and axis change.
			AnimAim held = src.aims[(usz)at];
			aim.spread = held.spread;
			aim.weights = held.weights;
			aim.influence = held.influence;
			aim.mute = held.mute;
		}
	}
	else
	{
		aim = src.aims[(usz)at].copy(mem);
	}
	if (has_spread) aim.spread = (usz)spread;
	if (weight_list != null) aim.weights = weights;
	if (has_influence) aim.influence = (float)influence;
	if (has_mute) aim.mute = mute;
	built = clip_with_aim(mem, *src, aim);

	AnimRef landed = app.land_clip(ref, built);
	if (!landed.valid())
	{
		detail.append_string(`the clip could not be landed.`);
		return AIM_REFUSED~;
	}
	return aims_answer(app, landed, at < 0 ? "add" : "update");
}

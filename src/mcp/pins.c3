<*
 Pins and posing over MCP: `get_pins`, `set_pins` and `pose_joint`.

 A pin (the Joint panel's "Pin position" and "Pin angle", the code's "anchor" or
 "position lock" — see `app/locks.c3`) holds a joint where it stands while another
 is dragged, through the whole-body solve `pose_body` runs. Until these tools it
 was reachable only with a mouse: a script could author keys but could not say
 "sit the dog down on its hind paws", which is the gesture the pins exist for.

 - `get_pins` reads the set: each pin's joint, which halves are on, the point and
   how far the last gesture left it from it. With a clip open the pins are the
   clip's (`app/clip_pins.c3`): `pins` are the ones whose window covers the
   playhead, `clip_pins` all of them with their `from`/`to`/`blend`.
 - `set_pins` changes the set, each pin captured where its joint stands on screen.
 - `pose_joint` is the viewport drag, made by a caller: it selects the joint and
   runs **the same `begin_pose` / `pose_toward` / `end_drag` (or `begin_turn` /
   `turn_joint`) calls the mouse does**, on the Pose stage, so the pins, balance,
   joint limits and the clip's ground solve all act as they do for a person — and
   with Auto-key it lands the result as a key the way releasing the mouse does.
   There is no second solver here to disagree with the first.
*>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::vector;

faultdef PINS_REFUSED;

// How many pointer moves a posed move or turn is broken into. One jump from the
// start to the end is not what a hand does, and the solve is warm-started from
// the previous move, so it reaches far-off targets the way a drag does.
const usz POSE_JOINT_STEPS = 12;

const String GET_PINS_SCHEMA = `{"type":"object","properties":{}}`;

const String SET_PINS_SCHEMA = `{"type":"object","properties":{
	"pins":{"type":"array","description":"Pins to add or change. With a clip open they are the clip's pins: they hold during playback and export for their from..to window, and one call is one undo step per pin. Each holds the joint where it stands on screen right now, and a pin already holding that half keeps the point it has. A joint left out keeps whatever it had.","items":{"type":"object","properties":{
		"joint":{"type":"string","description":"The joint's name."},
		"position":{"type":"boolean","description":"Hold its world position (the Joint panel's Pin position). Default true unless rotation is given alone."},
		"rotation":{"type":"boolean","description":"Hold its world orientation (Pin angle), so a foot stays flat. Default false."},
		"from":{"type":"number","description":"With a clip open: seconds into the clip where the pin starts holding. Default: the pin's own, or 0 for a new pin."},
		"to":{"type":"number","description":"With a clip open: seconds where it stops holding. Default: the pin's own, or the clip's end for a new pin."},
		"blend":{"type":"number","description":"With a clip open: seconds the pin eases in and out at the window ends (0 is a hard edge). Default: the pin's own, or 0.1 for a new pin."}
	},"required":["joint"]}},
	"clear":{"type":"boolean","description":"Drop every pin first (the clip's pins when a clip is open). With no pins, this just clears."},
	"balance":{"type":"boolean","description":"Whether the body leans to keep its centre of mass over the pinned feet (the Balance toggle). Left as it is when omitted."},
	"clip":{"type":"string","description":"Put this clip on show first, so pins are captured from its pose. Default: the clip open in the timeline."},
	"time":{"type":"number","description":"Seconds into the clip to put on show. Default: the playhead."}
}}`;

const String POSE_JOINT_SCHEMA = `{"type":"object","properties":{
	"joint":{"type":"string","description":"The joint to pose."},
	"move":{"type":"array","items":{"type":"number"},"description":"[x,y,z] to move the joint by, in model units along the model's world axes: the drag of a joint by that much."},
	"target":{"type":"array","items":{"type":"number"},"description":"[x,y,z] model-space point to drag the joint to. Use move or target, not both."},
	"turn":{"type":"object","description":"Turn the joint in place. Applied after a move or target when both are given.","properties":{
		"axis":{"description":"World axis: [x,y,z], or \"x\", \"y\", \"z\".","anyOf":[{"type":"array","items":{"type":"number"}},{"type":"string"}]},
		"angle":{"type":"number","description":"Radians, anticlockwise about the axis seen from its tip."}
	},"required":["axis","angle"]},
	"clip":{"type":"string","description":"The clip to pose. Default: the clip open in the timeline."},
	"time":{"type":"number","description":"Seconds into the clip to pose. Default: the playhead."},
	"key":{"type":"boolean","description":"Key the result the way releasing the mouse does with Auto-key on (default true). False leaves the pose shown and unkeyed; a later call with key true and nothing to do but the key keys it."}
}}`;

// ---------------------------------------------------------------------------
// get_pins

fn String? tool_get_pins(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	DString out = dstring::new(mem);
	defer out.free();
	append_pin_state(app, &out);
	return out.copy_str(mem);
}

<*
 The pin set and where the pose stands, as a JSON object: the list, the Balance
 switch, and which clip and time the pins were read against.

 `residual` is how far the joint is from its point in model units on the body as
 it is shown — after the clip's ground solve — `residual_fraction` the same as a
 share of rig height, and `turn_residual` the angle in radians a held orientation
 missed by. A pin that could not hold — out of its limb's reach, or against
 another pin — is one whose residual is not zero.
*>
fn void append_pin_state(AppState* app, DString* out)
{
	float height = 0.0f;
	RigView? opened = app.open_rig(mem);
	if (try view = opened)
	{
		height = view.skeleton.height();
		view.free(mem);
	}

	out.append_string(`{"pins":[`);
	foreach (usz i, lock : app.position_locks)
	{
		Dot* dot = app.doc.find(lock.dot_id);
		if (i > 0) out.append_char(',');
		out.append_string(`{"joint":"`);
		append_bone_name(out, lock.dot_id, dot ? dot.name : "");
		out.appendf(`","position":%s,"rotation":%s`, lock.position, lock.rotation);
		if (lock.position)
		{
			out.append_string(`,"target":`);
			append_vec3(out, lock.target);
			out.appendf(`,"residual":%.6g,"residual_fraction":%.6g`, lock.residual, height > 0.0f ? lock.residual / height : 0.0f);
		}
		if (lock.rotation) out.appendf(`,"turn_residual":%.6g`, lock.turn_residual);
		out.append_char('}');
	}
	out.appendf(`],"balance":%s,"pose_unkeyed":%s`, !app.balance_off, app.pose_edit_pending);
	AnimTemplate* clip = app.editing.valid() ? app.clip(app.editing) : null;
	if (clip)
	{
		out.append_string(`,"clip_pins":[`);
		foreach (usz i, &pin : clip.pins)
		{
			if (i > 0) out.append_char(',');
			out.append_string(`{"joint":`);
			append_json_string(out, pin.joint);
			out.appendf(`,"position":%s,"rotation":%s,"from":%.6g,"to":%.6g,"blend":%.6g,"mute":%s,"at":`,
				pin.position, pin.rotation, pin.from, pin.to, pin.blend, pin.mute);
			append_vec3(out, pin.at);
			out.append_char('}');
		}
		out.append_char(']');
		out.append_string(`,"clip":`);
		append_json_string(out, clip.name);
		out.appendf(`,"time":%.6g`, app.edit_time);
	}
	out.append_char('}');
}

// ---------------------------------------------------------------------------
// set_pins

fn String? tool_set_pins(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `set_pins takes an object: {"pins": [{"joint": name, "position": bool, "rotation": bool}], "clear": bool}`)) return PINS_REFUSED~;

	Object* list = member(args, "pins");
	bool clear = args.get_bool("clear") ?? false;
	if (list != null && !list.is_array())
	{
		detail.append_string(`"pins" must be an array of {"joint": name, "position": bool, "rotation": bool}.`);
		return PINS_REFUSED~;
	}

	// Checked before anything changes, so a call that names a joint the rig does
	// not have leaves the set as it was.
	sz count = list ? list.get_len() : 0;
	for (sz i = 0; i < count; i++)
	{
		Object* entry = list.get_at(i);
		String joint;
		if (!takes_object(entry, detail, `each pin is an object: {"joint": name, "position": bool, "rotation": bool}`)
			|| !required_string(entry, "joint", &joint, detail, `each pin needs "joint": the name of a joint. get_skeleton lists them.`))
		{
			return PINS_REFUSED~;
		}
		foreach (key : (String[3]){ "from", "to", "blend" })
		{
			Object* given = member(entry, key);
			if (given != null && ((!given.is_float() && !given.is_int()) || (entry.get_float(key) ?? 0.0) < 0.0))
			{
				detail.appendf(`pins[%d]: "%s" must be a number of seconds, 0 or more.`, i, key);
				return PINS_REFUSED~;
			}
		}
		if (app.dot_named(joint) == null)
		{
			detail.appendf(`pins[%d]: no joint is called "%s". get_skeleton lists them.`, i, joint);
			return PINS_REFUSED~;
		}
	}
	if (!clear && count == 0 && member(args, "balance") == null)
	{
		detail.append_string(`set_pins needs "pins", "clear" or "balance". get_pins reads the set.`);
		return PINS_REFUSED~;
	}

	// Pins capture where the joint stands on screen, so the pose they are read
	// against has to be the one about to be posed.
	if (!put_on_show(app, args, detail, false)) return PINS_REFUSED~;

	if (clear) app.clear_editor_pins();
	for (sz i = 0; i < count; i++)
	{
		Object* entry = list.get_at(i);
		Dot* dot = app.dot_named(entry.get_string("joint")!!);
		bool rotation_given = member(entry, "rotation") != null;
		bool position_given = member(entry, "position") != null;
		// A half not mentioned stays as the joint has it. A joint with neither
		// mentioned holds its position, which is what "pin" means to everyone who
		// has used the panel; a rotation given alone is a rotation pin alone.
		bool want_rotation = rotation_given ? (entry.get_bool("rotation") ?? false) : app.locks_rotation(dot.id);
		bool want_position = position_given ? (entry.get_bool("position") ?? true)
			: (rotation_given ? app.locks_position(dot.id) : true);
		if (app.clip_pins_drive())
		{
			// The clip's pin, window and all, in one landing.
			float from = member(entry, "from") != null ? (float)entry.get_float("from")!! : -1.0f;
			float to = member(entry, "to") != null ? (float)entry.get_float("to")!! : -1.0f;
			float blend = member(entry, "blend") != null ? (float)entry.get_float("blend")!! : -1.0f;
			(void)app.set_clip_pin(dot.id, want_position, want_rotation, from, to, blend);
		}
		else
		{
			app.set_anchor(dot.id, want_position, want_rotation);
		}
	}
	if (member(args, "balance") != null) app.balance_off = !(args.get_bool("balance") ?? true);

	app.refresh_ui();
	DString out = dstring::new(mem);
	defer out.free();
	append_pin_state(app, &out);
	return out.copy_str(mem);
}

// ---------------------------------------------------------------------------
// pose_joint

<*
 Puts the clip to pose on screen, on the Pose stage, the way choosing it and
 scrubbing to a time would.

 Whatever is already being posed stays when neither `clip` nor `time` is given.
 Moving to another clip or time drops an unkeyed pose the way scrubbing does.

 @param needs_clip : `Refuse when there is no clip to pose (pose_joint) rather than leave the rest pose showing (set_pins).`
*>
fn bool put_on_show(AppState* app, Object* args, DString* detail, bool needs_clip)
{
	if (app.drag.dot != 0)
	{
		detail.append_string(`a drag is in progress in the window. Let go of it first.`);
		return false;
	}

	Object* named = member(args, "clip");
	Object* timed = member(args, "time");
	if (named != null && !named.is_string())
	{
		detail.append_string(`"clip" must be a clip's name. get_scene lists them.`);
		return false;
	}
	if (timed != null && !timed.is_float() && !timed.is_int())
	{
		detail.append_string(`"time" must be a number of seconds.`);
		return false;
	}

	AnimRef ref = app.editing;
	if (named != null)
	{
		AnimRef? found = resolve_named(app, named.s, detail);
		if (catch found) return false;
		ref = found;
	}
	AnimTemplate* clip = ref.valid() ? app.clip(ref) : null;
	if (clip == null)
	{
		if (needs_clip)
		{
			detail.append_string(`no clip is open to pose. Give "clip": a clip's name (apply_clip or new animations make one) — a pose is keyed into a clip.`);
			return false;
		}
		return true;
	}

	bool same = ref.same(app.editing);
	float time = timed != null ? (float)args.get_float("time")!! : (same ? app.edit_time : 0.0f);
	time = math::clamp(time, 0.0f, clip.duration);

	// Already up: the draft, with whatever it holds, is what the next gesture builds on.
	if (app.pose_edit_active && same && time == app.edit_time) return true;
	if (app.pose_edit_active) (void)app.prepare_timeline_navigation();
	app.editing = ref;
	if (!app.park_clip(ref, time))
	{
		detail.append_string(`that clip would not show on this rig. get_scene says which clips fit it.`);
		return false;
	}
	app.edit_time = time;
	app.stage = POSE_STAGE;
	return true;
}

// The axis a turn is about: [x,y,z], or "x", "y", "z". False for anything else.
fn bool as_turn_axis(Object* obj, Vec3* into)
{
	if (obj != null && obj.is_string())
	{
		if (obj.s == "x") { *into = { 1, 0, 0 }; return true; }
		if (obj.s == "y") { *into = { 0, 1, 0 }; return true; }
		if (obj.s == "z") { *into = { 0, 0, 1 }; return true; }
		return false;
	}
	Vec3 axis;
	if (!as_vec3(obj, &axis) || axis.length_sq() < 1.0e-12f) return false;
	*into = axis.normalize();
	return true;
}

fn String? tool_pose_joint(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `pose_joint takes an object: {"joint": name, "move": [x,y,z] | "target": [x,y,z], "turn": {"axis":..., "angle": radians}, "clip": name, "time": seconds, "key": bool}`)) return PINS_REFUSED~;

	bool key = args.get_bool("key") ?? true;
	Object* move = member(args, "move");
	Object* target = member(args, "target");
	Object* turn = member(args, "turn");
	Vec3 delta;
	Vec3 goal;
	Vec3 axis;
	float angle = 0.0f;
	if (move != null && target != null)
	{
		detail.append_string(`give "move" or "target", not both.`);
		return PINS_REFUSED~;
	}
	if (move != null && !as_vec3(move, &delta))
	{
		detail.append_string(`"move" must be [x,y,z], model units along the world axes.`);
		return PINS_REFUSED~;
	}
	if (target != null && !as_vec3(target, &goal))
	{
		detail.append_string(`"target" must be [x,y,z], a model-space point.`);
		return PINS_REFUSED~;
	}
	if (turn != null)
	{
		Object* turned = member(turn, "angle");
		if (!turn.is_keyable() || turned == null || (!turned.is_float() && !turned.is_int()))
		{
			detail.append_string(`"turn" must be {"axis": [x,y,z] or "x"|"y"|"z", "angle": radians}.`);
			return PINS_REFUSED~;
		}
		if (!as_turn_axis(member(turn, "axis"), &axis))
		{
			detail.append_string(`"turn.axis" must be [x,y,z] (not zero) or "x", "y", "z".`);
			return PINS_REFUSED~;
		}
		angle = (float)turn.get_float("angle")!!;
	}

	bool gestures = move != null || target != null || turn != null;
	if (!put_on_show(app, args, detail, true)) return PINS_REFUSED~;

	// Nothing to do but the key: the pose an earlier key:false left showing.
	if (!gestures)
	{
		if (!key || !app.pose_edit_pending)
		{
			detail.append_string(`give "move", "target" or "turn" to pose a joint. (With key true and nothing else, a pending unkeyed pose is keyed.)`);
			return PINS_REFUSED~;
		}
		if (!app.key_pose_edit(CHANGED))
		{
			detail.append_string(`the pending pose would not key.`);
			return PINS_REFUSED~;
		}
		return pose_joint_answer(app, null, {}, false);
	}

	String joint;
	if (!required_string(args, "joint", &joint, detail, `pose_joint needs "joint": the name of the joint to pose. get_skeleton lists them.`)) return PINS_REFUSED~;
	Dot* dot = app.dot_named(joint);
	if (dot == null)
	{
		detail.appendf(`no joint is called "%s". get_skeleton lists them.`, joint);
		return PINS_REFUSED~;
	}
	uint id = dot.id;

	// Released the way a mouse release is, which keys when Auto-key is on: the
	// caller's `key` decides that for this one gesture, and the switch goes back.
	bool auto_key = app.auto_key;
	defer app.auto_key = auto_key;
	app.auto_key = key;

	Vec3 asked = {};
	bool asked_position = false;
	if (move != null || target != null)
	{
		app.select(id);
		if (!app.begin_pose(true))
		{
			detail.appendf(`the pose gesture on "%s" would not begin: %s`, joint, app.notice());
			return PINS_REFUSED~;
		}
		Vec3 from = app.drag.from;
		asked = move != null ? from + delta : goal;
		asked_position = true;
		for (usz step = 1; step <= POSE_JOINT_STEPS; step++)
		{
			app.pose_toward(from + (asked - from) * ((float)step / (float)POSE_JOINT_STEPS));
		}
		app.end_drag();
	}
	if (turn != null)
	{
		app.select(id);
		if (!app.begin_turn(true))
		{
			detail.appendf(`"%s" would not turn.`, joint);
			return PINS_REFUSED~;
		}
		for (usz step = 1; step <= POSE_JOINT_STEPS; step++)
		{
			app.turn_joint(axis, angle * ((float)step / (float)POSE_JOINT_STEPS));
		}
		app.end_drag();
	}
	app.refresh_ui();
	return pose_joint_answer(app, dot, asked, asked_position);
}

<*
 The answer: where the joint ended against where it was asked to go, whether the
 pose was keyed, and the pin readouts the gesture left.

 @param dot : `The posed joint; null when the call only keyed a pending pose.`
 @param asked_position : `Whether a position was asked for — a turn alone has no miss to report.`
*>
fn String pose_joint_answer(AppState* app, Dot* dot, Vec3 asked, bool asked_position) @local
{
	DString out = dstring::new(mem);
	defer out.free();
	out.append_char('{');
	if (dot)
	{
		Vec3 at = app.dot_position(*dot);
		float height = 0.0f;
		RigView? opened = app.open_rig(mem);
		if (try view = opened)
		{
			height = view.skeleton.height();
			view.free(mem);
		}
		out.append_string(`"joint":`);
		append_json_string(&out, dot.name);
		out.append_string(`,"at":`);
		append_vec3(&out, at);
		if (asked_position)
		{
			float miss = (at - asked).length();
			out.append_string(`,"asked":`);
			append_vec3(&out, asked);
			out.appendf(`,"miss":%.6g,"miss_fraction":%.6g,`, miss, height > 0.0f ? miss / height : 0.0f);
		}
		else
		{
			out.append_char(',');
		}
	}
	out.appendf(`"keyed":%s,"state":`, !app.pose_edit_pending);
	append_pin_state(app, &out);
	out.append_char('}');
	return out.copy_str(mem);
}

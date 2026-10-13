<*
 Whole-clip rewrites over MCP: `trim_clip`, `retime_clip`, `optimize_clip`,
 `remove_movement`, `close_loop`, `smooth_clip` and `make_loop`.

 The first five are what the Animations pane's ⋯ and Clip tools menus do, and
 run the same rewriters (`clip_cropped`, `clip_range_cut`, `clip_retimed`,
 `optimize_clip_keys`, `move_clip_travel`, `clip_seam_closed`); until these an
 agent repairing a generated clip could see what was wrong and had no way to
 cut it. The last two are the repairs a generated clip needs most and no menu
 had: a filter for jitter (`clip_smoothed`) and a cycle cut out of a take
 (`clip_cycle`).

 Each lands as one undo step in the authored pack — a library clip becomes the
 project's copy first, as every edit does — becomes the clip being edited, and
 answers with measure_clip's numbers for it, so what the rewrite did to the feet
 and the seam is known at once.
*>
module crig;

import std::collections::object;
import std::math;

faultdef REWRITE_REFUSED;

const String TRIM_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"keep":{"type":"array","items":{"type":"number"},"description":"[start, end] seconds to keep; everything outside goes and the clip starts at start."},
	"cut":{"type":"array","items":{"type":"number"},"description":"[start, end] seconds to remove; what follows moves up to start. Give keep or cut, not both."}
}}`;

const String RETIME_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"duration":{"type":"number","description":"The new length in seconds; every key, contact window and pin is stretched to it."}
},"required":["duration"]}`;

const String OPTIMIZE_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"strength":{"type":"string","enum":["light","strong"],"description":"light keeps the motion within a quarter of a degree, strong within a degree. Default light."}
}}`;

const String REMOVE_MOVEMENT_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"mode":{"type":"string","enum":["in_place","on_root"],"description":"in_place stops the figure travelling; on_root moves the travel from the hips onto a root joint below them. Default in_place."},
	"translation":{"type":"boolean","description":"Hold the hips over where they start at every moment. Default true."},
	"rotation":{"type":"boolean","description":"Take out the net turn about the vertical too. Default true."},
	"vertical":{"type":"boolean","description":"Move height changes with the travel as well, not only the ground plane. Default false."}
}}`;

const String CLOSE_LOOP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The looping clip, or \"Pack/Clip\". Default: the clip open in the timeline."}
}}`;

const String SMOOTH_CLIP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"window":{"type":"number","description":"Seconds the filter averages over: about the length of the shortest wobble to take out. 0.1 takes out jitter and keeps a step's shape; 0.25 softens the motion itself. Default 0.1."},
	"joints":{"type":"array","items":{"type":"string"},"description":"Only these joints. Default: every joint the clip keys."},
	"range":{"type":"array","items":{"type":"number"},"description":"[start, end] seconds to smooth; outside it the clip is untouched and the filter eases in and out at the edges. Default: the whole clip."},
	"hold_contacts":{"type":"boolean","description":"Leave a joint alone while its ground window or pin holds it, so a planted foot is not dragged by the average of its swing. Default true."}
}}`;

const String MAKE_LOOP_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The take to cut the cycle from, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"name":{"type":"string","description":"The new clip's name. Default: the take's name with \" loop\"."},
	"period":{"type":"array","items":{"type":"number"},"description":"[shortest, longest] seconds one cycle may last. A walk's cycle is two steps, about 0.9 to 1.3 s; a run's 0.6 to 0.9 s. Default: a fifth of the take to half of it."},
	"from":{"type":"array","items":{"type":"number"},"description":"[earliest, latest] seconds the cycle may start in. Default: leave out the first and last tenth of the take, where a generated motion starts and stops."},
	"crossfade":{"type":"number","description":"Seconds before the seam blended into the motion that led into the start, so the seam matches in speed as well as pose. Default a quarter of the period."}
}}`;

const String REMOVE_KEYS_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"The clip, or \"Pack/Clip\". Default: the clip open in the timeline."},
	"keys":{"type":"array","items":{"type":"integer"},"description":"Keyframe indices to remove, counted from 0 in the order get_clip lists them — the key a measure_clip pop names."},
	"partial":{"type":"boolean","description":"Remove every keyframe that keys fewer joints than the clip's fullest one: the leftover correction keys a dense clip should not have. Give this or keys."}
}}`;

<*
 The clip a rewrite acts on: `clip` when given, else the one being edited — read
 in, and not while a pose is being edited, which a rewrite would throw away.
*>
fn AnimRef? rewrite_target(AppState* app, Object* args, DString* detail) @local
{
	if (app.pose_edit_pending)
	{
		detail.append_string("a pose is being edited and not keyed yet; key it or cancel it first.");
		return REWRITE_REFUSED~;
	}
	AnimRef ref = app.editing;
	Object* named = args != null ? member(args, "clip") : null;
	if (named != null)
	{
		if (!named.is_string())
		{
			detail.append_string(`"clip" must be a clip's name, or "Pack/Clip".`);
			return REWRITE_REFUSED~;
		}
		ref = resolve_named(app, named.s, detail)!;
	}
	if (!ref.valid() || !app.clip(ref))
	{
		detail.append_string(`no clip is open. Give "clip": the clip to rewrite.`);
		return REWRITE_REFUSED~;
	}
	if (!app.ensure_clip_imported(ref))
	{
		detail.append_string("that clip cannot be read.");
		return REWRITE_REFUSED~;
	}
	return ref;
}

// A [start, end] pair of seconds, or false with the reason.
fn bool seconds_pair(Object* args, String key, float* start, float* end, DString* detail) @local
{
	Object* pair = member(args, key);
	if (pair == null || !pair.is_array() || pair.get_len() != 2)
	{
		detail.appendf(`"%s" must be [start, end] in seconds.`, key);
		return false;
	}
	double? from = pair.get_float_at(0);
	double? to = pair.get_float_at(1);
	if (catch from) { detail.appendf(`"%s" must be [start, end] in seconds.`, key); return false; }
	if (catch to) { detail.appendf(`"%s" must be [start, end] in seconds.`, key); return false; }
	*start = (float)from;
	*end = (float)to;
	if (!(*start >= 0.0f) || !(*end > *start))
	{
		detail.appendf(`"%s" is [%.4g, %.4g]: start must be 0 or more and end after it.`, key, *start, *end);
		return false;
	}
	return true;
}

<*
 Land a rewritten clip on `ref` as the clip being edited, and answer with what it
 now is: its name, length and keys, and measure_clip's numbers.

 @param built : `Taken over.`
*>
fn String? landed_rewrite_json(AppState* app, AnimRef ref, AnimTemplate built, String done, DString* detail) @local
{
	app.clear_animation_key_selection();
	AnimRef landed = app.land_clip(ref, built);
	if (!landed.valid())
	{
		detail.append_string("the rewritten clip would not land.");
		return REWRITE_REFUSED~;
	}
	app.editing = landed;
	app.edit_time = math::min(app.edit_time, app.clip(landed).duration);
	app.refresh_ui();
	return rewrite_answer(app, landed, done, detail);
}

// The answer every rewrite gives: the clip as it now is, and its measurements.
fn String? rewrite_answer(AppState* app, AnimRef ref, String done, DString* detail) @local
{
	AnimTemplate* clip = app.clip(ref);
	String metrics = metrics_json(app, clip.name, 0, detail)!;
	defer metrics.free(mem);
	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`{"clip":`);
	append_json_string(&out, clip.name);
	out.appendf(`,"done":"%s","duration":%s,"loop":%s,"keyframes":%d,"channel_keys":%d,"metrics":%s}`,
		done, (JsonFloat)clip.duration, clip.loop, clip.keyframes.len, channel_keys(*clip), metrics)!!;
	return out.copy_str(mem);
}

// ---------------------------------------------------------------------------

fn String? tool_trim_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `trim_clip takes {"clip": name, "keep": [start, end]} or {"cut": [start, end]}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	AnimTemplate* clip = app.clip(ref);
	bool keeping = member(args, "keep") != null;
	bool cutting = member(args, "cut") != null;
	if (keeping == cutting)
	{
		detail.append_string(`give "keep": [start, end] to keep a range, or "cut": [start, end] to remove one — one of them.`);
		return REWRITE_REFUSED~;
	}
	float start;
	float end;
	if (!seconds_pair(args, keeping ? "keep" : "cut", &start, &end, detail)) return REWRITE_REFUSED~;
	end = math::min(end, clip.duration);
	if (end - start < ANIM_SAME_TIME * 2.0f)
	{
		detail.appendf(`the range ends before it starts inside a clip %.4g seconds long.`, clip.duration);
		return REWRITE_REFUSED~;
	}
	if (cutting && clip.duration - (end - start) < ANIM_SAME_TIME * 2.0f)
	{
		detail.append_string("cutting the whole clip leaves nothing to play; delete_clip deletes it.");
		return REWRITE_REFUSED~;
	}
	AnimTemplate built = keeping ? clip_cropped(mem, *clip, start, end) : clip_range_cut(mem, *clip, start, end);
	if (built.keyframes.len == 0)
	{
		built.free(mem);
		detail.append_string("that range keeps no key.");
		return REWRITE_REFUSED~;
	}
	return landed_rewrite_json(app, ref, built, keeping ? "kept" : "cut", detail);
}

fn String? tool_retime_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `retime_clip takes {"clip": name, "duration": seconds}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	double? asked = args.get_float("duration");
	if (catch asked)
	{
		detail.append_string(`retime_clip needs "duration": the new length in seconds.`);
		return REWRITE_REFUSED~;
	}
	float duration = (float)asked;
	if (!(duration > 0.0f && duration <= 3600.0f))
	{
		detail.append_string(`"duration" must be more than 0 and at most 3600 seconds.`);
		return REWRITE_REFUSED~;
	}
	AnimTemplate built = clip_retimed(mem, *app.clip(ref), duration);
	if (math::abs(built.duration - duration) >= 1.0e-6f)
	{
		built.free(mem);
		detail.append_string("that length would put two keys too close together.");
		return REWRITE_REFUSED~;
	}
	return landed_rewrite_json(app, ref, built, "retimed", detail);
}

fn String? tool_optimize_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `optimize_clip takes {"clip": name, "strength": "light" | "strong"}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	KeyReduction level = LIGHT;
	if (try String strength = args.get_string("strength"))
	{
		switch (strength)
		{
			case "light": level = LIGHT;
			case "strong": level = STRONG;
			default:
				detail.appendf(`"strength" is "%s"; it is "light" or "strong".`, strength);
				return REWRITE_REFUSED~;
		}
	}
	app.clear_animation_key_selection();
	if (!app.optimize_clip_keys(ref, level))
	{
		// Nothing to lose is an answer, not a refusal.
		return rewrite_answer(app, ref, "unchanged", detail);
	}
	app.refresh_ui();
	return rewrite_answer(app, app.editing, "optimized", detail);
}

fn String? tool_remove_movement(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `remove_movement takes {"clip": name, "mode": "in_place" | "on_root"}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	RootMotionPolicy policy = { .mode = IN_PLACE };
	if (try String mode = args.get_string("mode"))
	{
		switch (mode)
		{
			case "in_place": policy.mode = IN_PLACE;
			case "on_root": policy.mode = ON_ROOT;
			default:
				detail.appendf(`"mode" is "%s"; it is "in_place" or "on_root".`, mode);
				return REWRITE_REFUSED~;
		}
	}
	policy.pinned = args.get_bool("translation") ?? true;
	policy.turning = args.get_bool("rotation") ?? true;
	policy.vertical = args.get_bool("vertical") ?? false;
	if (!policy.pinned && !policy.turning)
	{
		detail.append_string(`"translation" and "rotation" are both false, which removes nothing.`);
		return REWRITE_REFUSED~;
	}
	policy.turn_only = !policy.pinned;
	app.clear_animation_key_selection();
	if (!app.move_clip_travel(ref, policy)) return rewrite_answer(app, ref, "unchanged", detail);
	app.refresh_ui();
	return rewrite_answer(app, app.editing, "moved", detail);
}

fn String? tool_close_loop(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (args != null && !takes_object(args, detail, `close_loop takes {"clip": name}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	AnimTemplate* clip = app.clip(ref);
	if (!clip.loop)
	{
		detail.appendf(`%s does not loop, so it has no seam to close. make_loop cuts a cycle out of a take.`, clip.name);
		return REWRITE_REFUSED~;
	}
	return landed_rewrite_json(app, ref, clip_seam_closed(mem, *clip), "closed", detail);
}

<*
 remove_keys: keyframes gone by index, or every partial one — `clip_without_keys`.
 A clip left with no keys is refused: that is delete_clip.
*>
fn String? tool_remove_keys(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (!takes_object(args, detail, `remove_keys takes {"clip": name, "keys": [indices]} or {"clip": name, "partial": true}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	AnimTemplate* clip = app.clip(ref);
	usz count = clip.keyframes.len;

	Object* listed = member(args, "keys");
	bool partial = args.get_bool("partial") ?? false;
	if ((listed != null) == partial)
	{
		detail.append_string(`give "keys": [indices] to remove those keyframes, or "partial": true to remove every keyframe that keys fewer joints than the fullest — one of them.`);
		return REWRITE_REFUSED~;
	}

	bool[] drop = alloc::new_array(mem, bool, (sz)count);
	defer alloc::free(mem, drop);
	usz dropping = 0;
	if (partial)
	{
		usz fullest = 0;
		foreach (frame : clip.keyframes) if (frame.dots.len > fullest) fullest = frame.dots.len;
		foreach (usz i, frame : clip.keyframes)
		{
			if (frame.dots.len >= fullest) continue;
			drop[i] = true;
			dropping++;
		}
	}
	else
	{
		if (!listed.is_array())
		{
			detail.append_string(`"keys" must be an array of keyframe indices, counted from 0.`);
			return REWRITE_REFUSED~;
		}
		for (sz i = 0; i < listed.get_len(); i++)
		{
			double? at = listed.get_float_at((usz)i);
			if (catch at)
			{
				detail.append_string(`"keys" must hold whole numbers: keyframe indices, counted from 0.`);
				return REWRITE_REFUSED~;
			}
			if (at < 0 || at >= (double)count || at != math::floor(at))
			{
				detail.appendf(`key %.9g is not one of %s's keyframes, which run 0 to %d.`, at, clip.name, (sz)count - 1);
				return REWRITE_REFUSED~;
			}
			if (!drop[(usz)at]) dropping++;
			drop[(usz)at] = true;
		}
	}
	if (dropping == 0)
	{
		detail.appendf(`every keyframe of %s keys the same joints, so none is partial.`, clip.name);
		return REWRITE_REFUSED~;
	}
	if (dropping >= count)
	{
		detail.append_string("that would remove every keyframe. delete_clip removes a clip.");
		return REWRITE_REFUSED~;
	}
	return landed_rewrite_json(app, ref, clip_without_keys(mem, *clip, drop), "keys removed", detail);
}

fn String? tool_smooth_clip(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (args != null && !takes_object(args, detail, `smooth_clip takes {"clip": name, "window": seconds, "joints": [names], "range": [start, end]}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	AnimTemplate* clip = app.clip(ref);

	float window = (float)(args.get_float("window") ?? 0.1);
	if (!(window > 0.0f && window <= clip.duration))
	{
		detail.appendf(`"window" must be more than 0 and no longer than the clip (%.4g s).`, clip.duration);
		return REWRITE_REFUSED~;
	}
	StringList joints;
	joints.init(tmem);
	Object* listed = member(args, "joints");
	if (listed != null)
	{
		if (!listed.is_array())
		{
			detail.append_string(`"joints" must be a list of joint names.`);
			return REWRITE_REFUSED~;
		}
		for (sz i = 0; i < listed.get_len(); i++)
		{
			Object* one = listed.get_at(i);
			if (!one.is_string())
			{
				detail.appendf(`joints[%d] must be a joint's name.`, i);
				return REWRITE_REFUSED~;
			}
			joints.push(one.s);
		}
	}
	float start = -1.0f;
	float end = -1.0f;
	if (member(args, "range") != null && !seconds_pair(args, "range", &start, &end, detail)) return REWRITE_REFUSED~;
	bool hold = args.get_bool("hold_contacts") ?? true;

	AnimRef landed = app.smooth_clip(ref, joints.array_view(), window, start, end, hold);
	if (!landed.valid())
	{
		detail.append_string("the smoothed clip would not land.");
		return REWRITE_REFUSED~;
	}
	return rewrite_answer(app, landed, "smoothed", detail);
}

fn String? tool_make_loop(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;
	if (args != null && !takes_object(args, detail, `make_loop takes {"clip": name, "name": new name, "period": [shortest, longest]}`)) return REWRITE_REFUSED~;
	AnimRef ref = rewrite_target(app, args, detail)!;
	AnimTemplate* take = app.clip(ref);
	float length = take.duration;
	// Copied: landing the cycle grows the authored pack the take may be in.
	String take_name = take.name.tcopy();

	float period_min;
	float period_max;
	float from_min;
	float from_max;
	cycle_defaults(length, &period_min, &period_max, &from_min, &from_max);
	if (member(args, "period") != null && !seconds_pair(args, "period", &period_min, &period_max, detail)) return REWRITE_REFUSED~;
	if (member(args, "from") != null && !seconds_pair(args, "from", &from_min, &from_max, detail)) return REWRITE_REFUSED~;
	float crossfade = (float)(args.get_float("crossfade") ?? (double)(period_min * 0.25f));
	if (!(crossfade >= 0.0f))
	{
		detail.append_string(`"crossfade" must be 0 or more seconds.`);
		return REWRITE_REFUSED~;
	}
	if (from_min + period_min > length)
	{
		detail.appendf(`a cycle of at least %.4g s starting at %.4g s does not fit in a take %.4g s long.`, period_min, from_min, length);
		return REWRITE_REFUSED~;
	}

	CycleCut cut;
	AnimRef landed = app.cut_cycle(ref, period_min, period_max, from_min, from_max, crossfade,
		args.get_string("name") ?? "", &cut, detail);
	if (!landed.valid()) return REWRITE_REFUSED~;

	String answer = rewrite_answer(app, landed, "looped", detail)!;
	defer answer.free(mem);
	DString out = dstring::new(mem);
	defer out.free();
	// The cut first, so a caller reads where the cycle came from before its numbers.
	out.appendf(`{"cut":{"from":%s,"period":%s,"seam_angle":%s,"source":`, (JsonFloat)cut.start, (JsonFloat)cut.period, (JsonFloat)cut.seam)!!;
	append_json_string(&out, take_name);
	out.appendf(`},"cycle":%s}`, answer)!!;
	return out.copy_str(mem);
}

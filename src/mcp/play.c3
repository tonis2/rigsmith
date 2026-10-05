<*
 play and stop: the clip the person at the screen is watching.

 The player is for them and for nobody else, which is the whole of why these two
 are their own file rather than part of the reads. Checking what a clip does is
 `get_pose` and `measure_clip`, and neither needs anything started — so a caller
 that reaches for `play` to find out what a clip looks like has reached for the
 wrong tool, and the payloads here say what the *user* can now see.

 Both ask the interface to redraw before answering: the socket is pumped between
 frames, and a loop that sleeps when idle has nothing else to tell it the document
 moved.
*>
module crig;

import std::collections::object;

faultdef PLAY_REFUSED;

<*
 play: start a clip in the player the user is watching.

 `AppState.play_clip` is the same entry point clicking the clip in the library
 uses, fit and all, so a clip started from here and one started by hand are the
 same clip running.

 Argument checking is here rather than in a parser of its own: three optional
 fields against a template that is already in the library is not the wire
 format `apply_clip` needs clip.c3 for.
*>
fn String? tool_play(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	if (!takes_object(args, detail, `play takes an object: {"clip": name, "t": seconds from the clip's start, "loop": bool}. get_scene lists every pack and clip.`)) return PLAY_REFUSED~;

	String given;
	if (!required_string(args, "clip", &given, detail, `play needs "clip": the name of a clip in the library. get_scene lists every pack and clip.`)) return PLAY_REFUSED~;

	AnimRef ref = resolve_named(app, given, detail)!;
	AnimTemplate* template = app.clip(ref);

	double length = (double)template.duration;
	if (length <= 0)
	{
		detail.appendf(`"%s" has no length, so there is no instant of it to show.`, template.name);
		return PLAY_REFUSED~;
	}

	// Read before the time is checked: whether a time past the end wraps or is
	// refused is what this run will do, not what the stored clip says.
	bool looping = template.loop;
	if (try want = args.get_bool("loop")) looping = want;

	double t = 0;
	if (try given_t = args.get_float("t")) t = given_t;
	if (t < 0)
	{
		detail.appendf(`"t" is %.9g. Time runs forward from 0, the start of the clip.`, t);
		return PLAY_REFUSED~;
	}
	if (t > length)
	{
		if (!looping)
		{
			detail.appendf(`"t" is %.9g, past the end of "%s", which is %.9g long and does not loop. Pass "loop": true to wrap instead.`, t, template.name, length);
			return PLAY_REFUSED~;
		}
		while (t >= length) t -= length;
	}

	// Read here and applied after the start, like `loop`: everything above this
	// point can still refuse, and a refusal has to leave the player exactly as it
	// was. Stated per run rather than remembered, so omitting it means the
	// documented default rather than whatever the last call happened to leave
	// behind.
	bool physics = true;
	if (try want = args.get_bool("sim")) physics = want;

	bool had_rig = app.doc.dots.len() > 0;
	if (!app.play_clip(ref))
	{
		explain_refusal(detail, app, ref);
		return PLAY_REFUSED~;
	}

	// After the start, which zeroes the clock and takes its own copy of the
	// template. The override lands on that copy, so the clip in the library
	// keeps the loop flag it was written with.
	app.current_anim.loop = looping;

	// The start has already drawn a frame, and that frame is the keyed pose
	// whichever way this lands: a run begins with the sim reset, and a reset sim
	// primes onto the animation exactly rather than deviating from it. So the
	// flag is free to arrive one frame late, and arriving here is what keeps a
	// refusal above from having touched it.
	if (physics != app.sim_enabled)
	{
		app.sim_enabled = physics;
		app.jiggle_reset();
	}

	if (t > 0)
	{
		app.anim_time = (float)t;
		// A seek is a cut: the dynamic bones settled against the instant the start
		// put them at, and carrying that onto another one is a spring being
		// released rather than a tail swinging. See `app/sim.c3`.
		app.jiggle_reset();
		app.refresh_animation();
	}

	app.refresh_ui();
	return playing_json(app, !had_rig && app.doc.dots.len() > 0);
}

<*
 What `play` answers with: the player as the window is now showing it.

 Duration and loop are read off the running copy rather than the library, so
 they describe this run — a clip played with `loop` overridden reports the
 override, which is what the caller asked for and what it will see.

 @param fitted : `Whether starting the clip placed the rig as well — play_clip fits a body plan's own rig into an empty document, and a caller that asked to watch an animation should be told its document gained a skeleton.`
*>
fn String playing_json(AppState* app, bool fitted)
{
	DString out = dstring::new(mem);
	defer out.free();

	AnimTemplate* clip = app.clip(app.current_ref);
	AnimPack* pack = app.pack((usz)app.current_ref.pack);

	out.append_string(`{"playing":`);
	out.append_string(app.animating ? "true" : "false");
	out.append_string(`,"clip":`);
	append_quoted_or_null(&out, clip ? clip.name : "");
	out.append_string(`,"pack":`);
	append_quoted_or_null(&out, pack ? pack.name : "");
	out.appendf(`,"time":%s,"duration":%s,"loop":`, (JsonFloat)app.anim_time, (JsonFloat)app.current_anim.duration);
	out.append_string(app.current_anim.loop ? "true" : "false");
	out.append_string(`,"fitted":`);
	out.append_string(fitted ? "true" : "false");
	out.append_char('}');

	return out.copy_str(mem);
}

<*
 stop: end playback and put the mesh back at rest.

 Not an error when nothing is playing. A caller that has lost track of the
 player should be able to say "stop" and know where it stands, which is what
 the answer's `stopped` is for.
*>
fn String? tool_stop(Object* args, void* user_data, DString* detail) @private
{
	AppState* app = (AppState*)user_data;

	// Read before the stop: `stop_animation` drops the running copy, and the
	// name goes with it.
	String stopped = app.animating ? app.current_anim.name : "";
	app.stop_animation();
	app.refresh_ui();
	return stopped_json(stopped);
}

<*
 What `stop` answers with: nothing is playing, and here is what was.

 @param stopped : `The clip that was running, or empty for none — read before the player was cleared, since stopping drops the running copy.`
*>
fn String stopped_json(String stopped)
{
	DString out = dstring::new(mem);
	defer out.free();

	out.append_string(`{"playing":false,"stopped":`);
	append_quoted_or_null(&out, stopped);
	out.append_char('}');

	return out.copy_str(mem);
}

// A JSON string, or null for the empty one: an answer that has no clip to name
// says so with null rather than with "".
fn void append_quoted_or_null(DString* out, String value) @local
{
	if (value.len == 0)
	{
		out.append_string("null");
		return;
	}
	out.append_char('"');
	json_escape_into(out, value);
	out.append_char('"');
}

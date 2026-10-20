<*
 render and set_camera: a clip photographed at instants the user is not looking
 at, and the camera they are.

 `screenshot` answers "what is on the screen". This answers "what does this clip
 look like at these four moments, from the left" — which is a different question,
 and the one an agent correcting a walk actually has. The difference is worth two
 tools rather than one argument because of what it costs: this moves the player
 and the camera and puts both back, so the person watching sees a flicker and
 nothing else, while `screenshot` disturbs nothing at all.

 **The contact sheet is the point.** A cycle is not legible one frame at a time —
 a foot that skates and a foot that plants look identical in a still, and the
 whole reason for tiling four instants into one picture is that the eye reads the
 difference between them instantly. Composed here, in-process, because the
 alternative is handing a caller four base64 blobs and asking it to own an image
 library. The instants are seconds, or the clip's own keys — what an agent that
 just wrote five keys wants to see is those five poses, without working out
 when each one fell.

 `measure_clip` remains the better instrument for anything with a number attached
 to it: `foot_slide` and `floor_penetration` are exactly the faults a picture
 hides. Use this for what a picture is good at — a limb bending the wrong way, a
 mesh tearing, a rig facing backwards.
*>
module crig;

import image;
import image::png;
import cui;
import three;
import rig;
import std::collections::object;



import std::encoding::base64;
import std::io;
import std::io::file;
import std::io::path;
import std::math;

faultdef RENDER_REFUSED, CAMERA_REFUSED;

<*
 The most instants one call will photograph.

 Each one is a whole frame drawn, read back off the GPU and decoded, so this is a
 seconds-per-call limit rather than a memory one — and a sheet of more than
 sixteen tiles is past the point where any of them can be read anyway.
*>
const usz RENDER_MOST_FRAMES @local = 16;

// The longest edge the sheet is allowed to have. The same budget one screenshot
// gets, for the same reason: a client resamples anything larger down to about
// this before a model sees it.
const uint RENDER_MAX_EDGE @local = 1568;

// Never below this, however many tiles are asked for: a 40-pixel figure answers
// no question, and a caller that wanted sixteen of those wanted four.
const uint RENDER_MIN_TILE @local = 96;

const String SHEET_FILE @local = "rigsmith-mcp-render.png";

const String RENDER_SCHEMA = `{"type":"object","properties":{
	"clip":{"type":"string","description":"Clip to photograph, or \"Pack/Clip\". Omit to photograph whatever is on screen now, which is what the camera and crop arguments are still worth."},
	"times":{"type":"array","items":{"type":"number"},"description":"Seconds from the clip's start, one tile each, in the order given. Omit for a single frame at t. A cycle reads best as four to nine instants spread over its duration."},
	"t":{"type":"number","description":"A single instant, when times is not given. Default 0."},
	"keys":{"description":"The clip's own keyframes instead of times: true for every key, or an array of key numbers, counted from 0 in time order, for some of them. Each tile is labelled with its key number and time. Layers, aims and pins adjust a clip without adding keys, so they are not counted. Give this or times, not both.","anyOf":[{"type":"boolean"},{"type":"array","items":{"type":"integer"}}]},
	"view":{"type":"string","enum":["Front","Back","Left","Right","Top","Bottom"],"description":"Look down an axis. What makes two renders comparable — a limb swinging in depth is invisible from the front and obvious from the left. The camera is put back afterwards."},
	"camera":{"type":"object","description":"The camera by hand, for an angle none of the six named views gives. Applied after view, so either may be used alone.","properties":{
		"yaw":{"type":"number","description":"Degrees about +Y. 0 puts the eye on +Z, which is in front of the model."},
		"pitch":{"type":"number","description":"Degrees above the horizon, clamped to ±89."},
		"distance":{"type":"number","description":"Eye to target, in model units."},
		"target":{"type":"array","items":{"type":"number"},"description":"[x,y,z] the camera looks at, in model space."}
	}},
	"frame":{"type":"boolean","description":"Back off until the whole model is in view before anything else, then put the camera back afterwards like every other argument here. What to ask for when nothing has aimed the camera yet — after build_body it is still wherever the last document left it, and the first render without this is a close-up of a ribcage."},
	"path":{"type":"string","description":"Also write the PNG here. A run_script call gets the sheet back as base64 text, which cannot be looked at; a file can be opened as an image."},
	"crop":{"type":"string","enum":["viewport","window"],"description":"viewport, the default, keeps only the part of the window the model is drawn in — the panels are noise in a picture about motion. window keeps the whole thing, which is what to ask for when the question is about the interface."},
	"cols":{"type":"number","description":"Tiles per row. Default is roughly square."},
	"overlays":{"type":"boolean","description":"false draws the model alone: no interface, tool column, view gizmo, HUD text or rig overlay, each tile square at the sheet's budget, the floor kept. What to ask for when the picture is to be compared with another — a reference video, a previous take. Default true: the viewport as the person sees it."},
	"square":{"type":"boolean","description":"Crop each tile to a square at the centre of the viewport, where frame and the named views put the model, so a wide pane does not leave it small in the middle of empty floor. Implied by overlays false."}
}}`;

const String SET_CAMERA_SCHEMA = `{"type":"object","properties":{
	"view":{"type":"string","enum":["Front","Back","Left","Right","Top","Bottom"],"description":"Look down an axis, as the view gizmo's balls do."},
	"camera":{"type":"object","description":"The camera by hand. Applied after view, so either may be used alone.","properties":{
		"yaw":{"type":"number","description":"Degrees about +Y. 0 puts the eye on +Z."},
		"pitch":{"type":"number","description":"Degrees above the horizon, clamped to ±89."},
		"distance":{"type":"number","description":"Eye to target, in model units."},
		"target":{"type":"array","items":{"type":"number"},"description":"[x,y,z] the camera looks at, in model space."}
	}},
	"frame":{"type":"boolean","description":"Centre on the character being edited, wherever it stands in the scene, and back off until all of it is in frame; then apply anything above. What to ask for when the camera has been left somewhere unhelpful, or a screenshot comes back as empty floor."}
}}`;

<*
 render: one or more instants of a clip, tiled into a single PNG.

 The player and the camera are both put back before this returns, on every path
 including the failing ones — a tool that photographs a moment must not leave the
 user parked in it.

 @param detail : `Filled with what was refused and what would have been taken instead.`
 @return? RENDER_REFUSED : `The reason is in detail.`
*>
fn String? render_content(AppState* app, Object* args, DString* detail)
{
	if (args != null && !args.is_keyable())
	{
		detail.append_string(`render takes an object: {"clip": name, "times": [seconds], "view": "Left", "crop": "viewport", "cols": n}`);
		return RENDER_REFUSED~;
	}

	if (!app.screenshot)
	{
		detail.append_string("no window to photograph — this crig is running headless, or its surface refused the transfer a frame is read back through. get_pose and measure_clip answer without one.");
		return RENDER_REFUSED~;
	}

	// Resolved before anything is disturbed, so a misspelled clip name costs the
	// user nothing at all.
	AnimRef ref = NO_ANIM;
	float[RENDER_MOST_FRAMES] times;
	// Which key each tile is, when they were asked for by key; empty otherwise.
	usz[RENDER_MOST_FRAMES] keys;
	usz frames = 1;
	bool by_key = false;

	if (member(args, "clip") != null)
	{
		String? given = args.get_string("clip");
		if (catch given)
		{
			detail.append_string(`render's "clip" must be a string: a clip name, or "Pack/Clip". Omit it to photograph what is on screen.`);
			return RENDER_REFUSED~;
		}
		ref = resolve_named(app, given, detail)!;

		AnimTemplate* template = app.clip(ref);
		if (!app.clip_applies(ref))
		{
			detail.appendf(`"%s" names no joint this rig has, so there is nothing of it to photograph. It turns: `, template.name);
			append_clip_joints(detail, template);
			detail.append_string(". apply_plan fits a rig a pack's clips can drive; get_skeleton lists the names this one carries.");
			return RENDER_REFUSED~;
		}

		if (member(args, "keys") != null)
		{
			if (!read_keys(app, ref, args, times[..], keys[..], &frames, detail)) return RENDER_REFUSED~;
			by_key = true;
		}
		else if (!read_times(args, template.duration, times[..], &frames, detail))
		{
			return RENDER_REFUSED~;
		}
	}
	else if (member(args, "keys") != null)
	{
		detail.append_string(`"keys" are a clip's keyframes, and no "clip" was named. get_scene lists the clips there are.`);
		return RENDER_REFUSED~;
	}

	// Left at zero when the caller says nothing, and worked out from the first
	// tile's shape once there is one — see `sheet_columns`. A count guessed from
	// the frame count alone lays four wide tiles in a row and answers with a
	// picture ten times wider than it is tall.
	usz columns = 0;
	if (member(args, "cols") != null)
	{
		double? given = args.get_float("cols");
		if (catch given)
		{
			detail.append_string(`"cols" must be a number: how many tiles go in a row`);
			return RENDER_REFUSED~;
		}
		if (given < 1 || given > (double)RENDER_MOST_FRAMES)
		{
			detail.appendf(`"cols" is %.9g. It is a whole number from 1 to %d.`, given, RENDER_MOST_FRAMES);
			return RENDER_REFUSED~;
		}
		columns = (usz)given;
		if (columns > frames) columns = frames;
	}

	bool whole_window = false;
	if (member(args, "crop") != null)
	{
		String? given = args.get_string("crop");
		if (catch given)
		{
			detail.append_string(`"crop" must be the string "viewport" or "window"`);
			return RENDER_REFUSED~;
		}
		switch (given)
		{
			// Spelled out rather than left empty: an empty case falls through.
			case "viewport": whole_window = false;
			case "window": whole_window = true;
			default:
				detail.appendf(
					`"crop" is "%s". It is "viewport" — only the part of the window the model is drawn in, the default — or "window", the whole interface.`,
					given);
				return RENDER_REFUSED~;
		}
	}

	bool overlays = true;
	if (member(args, "overlays") != null)
	{
		bool? given = args.get_bool("overlays");
		if (catch given)
		{
			detail.append_string(`"overlays" must be true or false: false draws the model alone, with no interface over it.`);
			return RENDER_REFUSED~;
		}
		overlays = given;
	}
	bool square = false;
	if (member(args, "square") != null)
	{
		bool? given = args.get_bool("square");
		if (catch given)
		{
			detail.append_string(`"square" must be true or false: whether each tile is cropped square about the viewport's centre.`);
			return RENDER_REFUSED~;
		}
		square = given;
	}
	if (!overlays && (!hosted() || stage_renderer() == null))
	{
		detail.append_string(`"overlays": false draws the scene without the interface, which needs the window's renderer; this crig has none. Leave it out for the viewport as it is.`);
		return RENDER_REFUSED~;
	}

	// Everything below moves something the user can see. From here on every path
	// out goes through the restore.
	bool was_animating = app.animating;
	AnimRef was_ref = app.current_ref;
	float was_time = app.anim_time;
	bool was_looping = app.current_anim.loop;
	OrbitCamera was_camera = app.camera;

	defer
	{
		app.camera = was_camera;
		restore_playback(app, was_animating, was_ref, was_time, was_looping);
		app.refresh_ui();
	}

	if (!apply_framing(app, args, detail)) return RENDER_REFUSED~;
	if (!apply_camera(app, args, detail)) return RENDER_REFUSED~;

	Vec4 window = { 0, 0, 1, 1 };
	Vec4 crop = whole_window ? window : app.viewport_share;
	// A viewport that has never painted leaves this zero, which would crop to
	// nothing. The whole window is the honest answer then, not an empty picture.
	if (crop.z - crop.x < 0.01f || crop.w - crop.y < 0.01f) crop = window;

	image::Image sheet = {};
	defer sheet.free();

	uint tile_width = 0;
	uint tile_height = 0;

	// The model alone: the renderer's target made one square tile, the interface
	// left out of each capture, and the target put back however this returns.
	uint clean_size = 0;
	three::Renderer* renderer = overlays ? null : stage_renderer();
	uint was_width = renderer ? renderer.target.extent.width : 0;
	uint was_height = renderer ? renderer.target.extent.height : 0;
	defer if (renderer) (void)renderer.resize_target(was_width, was_height);
	if (renderer)
	{
		if (columns == 0) columns = sheet_columns(frames, 1, 1);
		usz rows = (frames + columns - 1) / columns;
		clean_size = math::min(RENDER_MAX_EDGE / (uint)columns, RENDER_MAX_EDGE / (uint)rows);
		clean_size = math::clamp(clean_size, RENDER_MIN_TILE, RENDER_CLEAN_MOST);
		// The whole target is the picture; nothing is cropped from it.
		crop = window;
		if (catch renderer.resize_target(clean_size, clean_size))
		{
			detail.appendf("a %d-pixel target could not be made for a frame without the interface.", clean_size);
			return RENDER_REFUSED~;
		}
	}

	for (usz f = 0; f < frames; f++)
	{
		if (ref.valid() && !show_at(app, ref, times[f]))
		{
			detail.appendf(`"%s" would not start: %s`, app.clip(ref).name, app.notice());
			return RENDER_REFUSED~;
		}

		image::Image? grabbed = renderer ? clean_frame(app, detail) : one_frame(app, crop, detail);
		if (catch grabbed) return RENDER_REFUSED~;
		image::Image tile = grabbed;
		if (square && !renderer && tile.width != tile.height)
		{
			image::Image centred = centre_square(&tile);
			tile.free();
			tile = centred;
		}
		defer tile.free();

		// The first tile decides the sheet's shape: every frame comes off the same
		// swapchain, so measuring one measures all of them, and the sheet cannot be
		// allocated before its tile size is known.
		if (f == 0)
		{
			if (columns == 0) columns = sheet_columns(frames, tile.width, tile.height);
			usz rows = (frames + columns - 1) / columns;
			tile_size(tile.width, tile.height, columns, rows, &tile_width, &tile_height);
			sheet = blank_like(&tile, tile_width * (uint)columns, tile_height * (uint)rows);
		}

		image::Image scaled = tile.resize(tile_width, tile_height, mem);
		defer scaled.free();
		uint left = tile_width * (uint)(f % columns);
		uint top = tile_height * (uint)(f / columns);
		blit(&sheet, &scaled, left, top);
		if (ref.valid()) label_tile(&sheet, left, top, tile_width, tile_height, by_key, keys[f], times[f]);
	}

	return sheet_content(app, &sheet, ref, times[:frames], by_key ? keys[:frames] : (usz[]){}, columns, crop, args, detail);
}

<*
 set_camera: aim the viewport, for the person in front of it.

 The counterpart `show_weights` is to `get_weights`: this one changes what
 somebody is looking at and answers nothing a caller could not have worked out.
 `render`'s own camera arguments are the other half — that one aims a camera at a
 picture and puts it back.
*>
fn String? set_camera_json(AppState* app, Object* args, DString* detail)
{
	if (args != null && !args.is_keyable())
	{
		detail.append_string(`set_camera takes an object: {"view": "Left", "camera": {"yaw": degrees, "pitch": degrees, "distance": units, "target": [x,y,z]}, "frame": bool}`);
		return CAMERA_REFUSED~;
	}

	if (!apply_framing(app, args, detail)) return CAMERA_REFUSED~;
	if (!apply_camera(app, args, detail)) return CAMERA_REFUSED~;

	app.refresh_ui();
	return camera_json(app);
}

// ---------------------------------------------------------------------------

<*
 `frame`, applied before anything else aims the camera.

 Before, so an explicit distance or target overrides it rather than being
 overridden by it: "back off until it all fits, then look from the left" is the
 useful order and the other one is never asked for.

 It earns its place on `render` as much as on `set_camera`, even though that one
 leaves the camera where it puts it and this one puts it back. The camera a fresh
 document starts with was framed for whatever was loaded before — after
 `build_body` there was no previous model at all — so a caller that has only ever
 spoken over the wire has no way to have aimed it, and its first contact sheet
 comes back a close-up of a ribcage. Nothing about that reads as a camera problem
 in the picture.

 @return `False when something was refused, with the reason in detail.`
*>
fn bool apply_framing(AppState* app, Object* args, DString* detail) @local
{
	if (args == null || member(args, "frame") == null) return true;

	bool? wanted = args.get_bool("frame");
	if (catch wanted)
	{
		detail.append_string(`"frame" must be true or false: whether to back the camera off until the whole model is in view first.`);
		return false;
	}
	if (!wanted) return true;

	if (!app.has_mesh())
	{
		detail.append_string(`"frame" backs the camera off until the model is all in view, and nothing is loaded.`);
		return false;
	}
	// World bounds, not the mesh's own: the camera looks at the world, and a
	// character placed away from the origin — set down beside another, or moved
	// with the Model gizmo — is drawn where its placement puts it.
	app.camera = framed(app.world_bounds(), app.camera.fov);
	return true;
}

<*
 `view` and `camera`, folded onto the live camera.

 Both are optional and both may be given: `view` turns the eye onto an axis and
 `camera` adjusts whatever it likes afterwards, which is how "from the left, but
 backed off" is said.

 The named view is written straight onto the angles rather than through
 `snap_to`, which eases over a quarter second — right for a person clicking a
 gizmo, and wrong for a frame that is about to be grabbed this instant.

 @return `False when something was refused, with the reason in detail.`
*>
fn bool apply_camera(AppState* app, Object* args, DString* detail) @local
{
	if (args == null) return true;

	if (member(args, "view") != null)
	{
		String? given = args.get_string("view");
		if (catch given)
		{
			detail.append_string(`"view" must be a string: Front, Back, Left, Right, Top or Bottom`);
			return false;
		}

		bool found = false;
		foreach (axis : ViewAxis::values)
		{
			// Case-insensitive: "left" is what a caller writes and "Left" is what the
			// gizmo prints, and refusing over that would be a turn spent on nothing.
			if (axis.view_name.compare_to_ignore_case(given) != 0) continue;
			app.camera.snapping = false;
			app.camera.yaw = axis.yaw;
			app.camera.pitch = axis.pitch;
			found = true;
		}
		if (!found)
		{
			detail.appendf(`"view" is "%s". It is one of Front, Back, Left, Right, Top or Bottom — the six the view gizmo offers.`, given);
			return false;
		}
	}

	Object* camera = member(args, "camera");
	if (camera == null) return true;
	if (!camera.is_keyable())
	{
		detail.append_string(`"camera" must be an object: {"yaw": degrees, "pitch": degrees, "distance": units, "target": [x,y,z]}`);
		return false;
	}

	if (member(camera, "yaw") != null)
	{
		double? given = camera.get_float("yaw");
		if (catch given)
		{
			detail.append_string(`"camera".yaw must be a number: degrees about +Y, 0 putting the eye on +Z`);
			return false;
		}
		app.camera.snapping = false;
		app.camera.yaw = (float)given;
	}

	if (member(camera, "pitch") != null)
	{
		double? given = camera.get_float("pitch");
		if (catch given)
		{
			detail.append_string(`"camera".pitch must be a number: degrees above the horizon`);
			return false;
		}
		// Clamped rather than refused: straight up is a singularity for a Y-up
		// orbit, and a caller asking for 90 means "from above", which 89 is.
		app.camera.snapping = false;
		app.camera.pitch = math::clamp((float)given, -MAX_PITCH, MAX_PITCH);
	}

	if (member(camera, "distance") != null)
	{
		double? given = camera.get_float("distance");
		if (catch given)
		{
			detail.append_string(`"camera".distance must be a number: eye to target, in model units`);
			return false;
		}
		if (given <= 0)
		{
			detail.appendf(`"camera".distance is %.9g. The eye cannot be at the point it is looking at.`, given);
			return false;
		}
		app.camera.distance = math::clamp((float)given, app.camera.min_distance, app.camera.max_distance);
	}

	Object* target = member(camera, "target");
	if (target != null)
	{
		Vec3 at;
		if (!as_vec3(target, &at))
		{
			detail.append_string(`"camera".target must be [x,y,z] in model space`);
			return false;
		}
		// Model space, like every other point on the wire, carried through the
		// character's placement onto the world the camera orbits in.
		app.camera.target = app.doc.model_transform.point(at);
	}
	return true;
}

<*
 The instants to photograph, out of `times` or `t`.

 @param into : `Filled with up to RENDER_MOST_FRAMES entries.`
 @param count : `Set to how many were written.`
 @return `False when something was refused, with the reason in detail.`
*>
fn bool read_times(Object* args, float duration, float[] into, usz* count, DString* detail) @local
{
	Object* times = member(args, "times");
	if (times == null)
	{
		double t = 0;
		if (try given = args.get_float("t")) t = given;
		if (t < 0 || t > (double)duration)
		{
			detail.appendf(`"t" is %.9g, and the clip runs from 0 to %.9g.`, t, duration);
			return false;
		}
		into[0] = (float)t;
		*count = 1;
		return true;
	}

	if (!times.is_array() || times.get_len() == 0)
	{
		detail.append_string(`"times" must be a non-empty array of seconds from the clip's start`);
		return false;
	}
	if ((usz)times.get_len() > RENDER_MOST_FRAMES)
	{
		detail.appendf(
			`"times" has %d entries and %d is the most one call photographs — each is a whole frame drawn and read back, and a sheet of more than that has no tile big enough to read.`,
			times.get_len(), RENDER_MOST_FRAMES);
		return false;
	}

	for (usz i = 0; i < (usz)times.get_len(); i++)
	{
		// Anything that is not a number reads as -1, which the range below
		// refuses by naming it — one sentence for both mistakes.
		double t = times.get_float_at((sz)i) ?? -1.0;
		if (t < 0 || t > (double)duration)
		{
			detail.appendf(`times[%d] is %.9g, and the clip runs from 0 to %.9g.`, i, t, duration);
			return false;
		}
		into[i] = (float)t;
	}
	*count = (usz)times.get_len();
	return true;
}

<*
 The instants to photograph, out of `keys`: the clip's own key times, all of
 them or the ones numbered.

 Numbered over the distinct times rather than the stored keyframes, so a pose
 keyed in two passes at the same instant is one key here as it is on the
 timeline.

 @param into : `Filled with up to RENDER_MOST_FRAMES times.`
 @param keys : `Filled with each time's key number, in the same order.`
 @param count : `Set to how many were written.`
 @return `False when something was refused, with the reason in detail.`
*>
fn bool read_keys(AppState* app, AnimRef ref, Object* args, float[] into, usz[] keys, usz* count, DString* detail) @local
{
	if (member(args, "times") != null || member(args, "t") != null)
	{
		detail.append_string(`"keys" and "times" (or "t") both say which instants to photograph. Give one of them.`);
		return false;
	}
	// A pack read lazily knows its clips' names and lengths and none of their
	// keys until one is asked for.
	if (!app.ensure_clip_imported(ref))
	{
		detail.appendf(`"%s"'s keys could not be read out of its pack: %s`, app.clip(ref).name, app.notice());
		return false;
	}

	AnimTemplate* clip = app.clip(ref);
	float[] all = distinct_key_times(clip);
	defer if (all.len > 0) alloc::free(mem, all.ptr);

	if (all.len == 0)
	{
		detail.appendf(`"%s" has no keys to photograph. "times" photographs it at any instant.`, clip.name);
		return false;
	}

	Object* given = member(args, "keys");
	if (given.is_bool())
	{
		if (!given.b)
		{
			detail.append_string(`"keys" is true, for every key, or an array of key numbers. Leave it out to choose instants with "times".`);
			return false;
		}
		if (all.len > RENDER_MOST_FRAMES)
		{
			detail.appendf(`"%s" has %d keys and %d is the most one call photographs. Choose some with "keys": [numbers], counted from 0; `,
				clip.name, all.len, RENDER_MOST_FRAMES);
			append_key_times(detail, all);
			return false;
		}
		foreach (i, t : all)
		{
			into[i] = t;
			keys[i] = (usz)i;
		}
		*count = all.len;
		return true;
	}

	if (!given.is_array() || given.get_len() == 0)
	{
		detail.append_string(`"keys" must be true, for every key, or a non-empty array of key numbers counted from 0`);
		return false;
	}
	if ((usz)given.get_len() > RENDER_MOST_FRAMES)
	{
		detail.appendf(`"keys" has %d entries and %d is the most one call photographs.`, given.get_len(), RENDER_MOST_FRAMES);
		return false;
	}

	for (usz i = 0; i < (usz)given.get_len(); i++)
	{
		// Anything that is not a whole number reads as -1, which the range below
		// refuses by naming it, as read_times does.
		double n = given.get_float_at((sz)i) ?? -1.0;
		if (n != math::floor(n)) n = -1.0;
		if (n < 0 || n >= (double)all.len)
		{
			detail.appendf(`keys[%d] is %.9g, and "%s" has %d key(s), numbered from 0: `, i, n, clip.name, all.len);
			append_key_times(detail, all);
			return false;
		}
		into[i] = all[(usz)n];
		keys[i] = (usz)n;
	}
	*count = (usz)given.get_len();
	return true;
}

// "key 0 at 0 s, key 1 at 0.5 s.", so a refusal can be answered without a
// second call to find out what there is.
fn void append_key_times(DString* detail, float[] times) @local
{
	foreach (i, t : times)
	{
		detail.appendf(i > 0 ? `, key %d at %.4g s` : `key %d at %.4g s`, i, t);
	}
	detail.append_char('.');
}

<*
 A tile's label, in its top-left corner: the key number and time, or the time.

 Sized from the tile's shorter side, which keeps the longest label a sheet can
 carry ("k15 10.00s") inside the tile it names at every scale.
*>
fn void label_tile(image::Image* sheet, uint left, uint top, uint width, uint height, bool by_key, usz key, float t) @local
{
	uint scale = math::max(1u, math::min(width, height) / 60);
	String text = by_key ? string::format(mem, "k%d %.2fs", key, t) : string::format(mem, "%.2fs", t);
	defer text.free(mem);
	draw_label(sheet, left, top, scale, text);
}

// Put the clip on screen at `t`. `AppState.park_clip` is the whole of it — the
// timeline's scrub needed exactly this and the two now share it, which is what
// keeps a photographed frame and a scrubbed one the same picture — and, like the
// scrub, it asks for the repaint too. The mesh follows the palette on its own,
// but the rig overlay is a painted layer: without this the grab caught the new
// body under the previous frame's bones, so every tile after the first drew
// the skeleton one time behind (a jump's apex showed its crouch).
fn bool show_at(AppState* app, AnimRef ref, float t) @local
{
	if (!app.park_clip(ref, t)) return false;
	app.refresh_ui();
	return true;
}

// What was playing before the render, back where it was. A run started by
// anything a user can reach carries a ref, so this restores it; one started
// without a ref stops, which is the honest answer for a clip nothing can name.
fn void restore_playback(AppState* app, bool animating, AnimRef ref, float time, bool looping) @local
{
	if (!animating || !ref.valid())
	{
		app.stop_animation();
		return;
	}
	if (!app.start_animation_ref(ref))
	{
		app.stop_animation();
		return;
	}
	app.current_anim.loop = looping;
	app.anim_time = time;
	app.refresh_animation();
}

// The largest tile a frame without the interface is drawn at, whatever the
// sheet's budget would allow: past it a tile costs bytes and shows nothing new.
const uint RENDER_CLEAN_MOST @local = 1024;

<*
 One frame of the scene as it stands, with nothing over it: the active camera on
 the whole (square) target, and the interface — tool column, gizmo, HUD, rig
 overlay — left out of the capture, as `render_poses` draws. The caller owns the
 result and has sized the target.
*>
fn image::Image? clean_frame(AppState* app, DString* detail) @local
{
	sync_scene(app);
	three::MeshPass* pass = stage_pass();
	three::SceneView[] none = { };
	pass.set_extra_views(none);
	pass.follow = {};
	pass.camera = pose_scene_camera(&app.camera);
	pass.view_rect = { 0, 0, 1, 1 };

	three::Renderer* renderer = stage_renderer();
	cui::Ui* ui = renderer.ui.ui;
	renderer.ui.ui = null;
	defer renderer.ui.ui = ui;
	image::Image? captured = renderer.capture();
	if (catch captured)
	{
		detail.append_string("no frame was drawn without the interface: the renderer refused the read back.");
		return SCREENSHOT_FAILED~;
	}
	return captured;
}

// The largest square at the centre of `tile`, as its own image.
fn image::Image centre_square(image::Image* tile) @local
{
	float side = (float)math::min(tile.width, tile.height);
	float left = ((float)tile.width - side) * 0.5f / (float)tile.width;
	float top = ((float)tile.height - side) * 0.5f / (float)tile.height;
	return cropped(tile, { left, top, left + side / (float)tile.width, top + side / (float)tile.height });
}

// One frame off the window, cropped to `share`. The caller owns the result.
fn image::Image? one_frame(AppState* app, Vec4 share, DString* detail) @local
{
	String shot_path = temp_sheet_path();
	defer shot_path.free(mem);
	// Registered before the grab, for the reason `screenshot_content` gives: a
	// frame that failed halfway still leaves a file.
	defer (void)file::delete(shot_path);

	if (!app.grab_screenshot(shot_path))
	{
		detail.append_string("no frame was drawn — the window is closing, or the surface refused the transfer a frame is read back through");
		return SCREENSHOT_FAILED~;
	}

	image::Image? grabbed = png::load_file(shot_path, mem);
	if (catch error = grabbed)
	{
		detail.appendf("a frame was written but could not be read back: %s", error);
		return SCREENSHOT_UNREADABLE~;
	}
	image::Image whole = grabbed;
	if (share.x <= 0 && share.y <= 0 && share.z >= 1 && share.w >= 1) return whole;

	defer whole.free();
	return cropped(&whole, share);
}

// The sub-rectangle `share` names, as its own image. Rows are contiguous runs of
// the source, so this is one memcpy per row and no arithmetic per pixel.
fn image::Image cropped(image::Image* whole, Vec4 share) @local
{
	usz bytes = (usz)whole.bytes_per_pixel();

	uint left = (uint)math::clamp(share.x * (float)whole.width, 0.0f, (float)whole.width - 1);
	uint top = (uint)math::clamp(share.y * (float)whole.height, 0.0f, (float)whole.height - 1);
	uint right = (uint)math::clamp(share.z * (float)whole.width, (float)left + 1, (float)whole.width);
	uint bottom = (uint)math::clamp(share.w * (float)whole.height, (float)top + 1, (float)whole.height);

	uint width = right - left;
	uint height = bottom - top;

	image::Image out = {
		.width = width,
		.height = height,
		.bit_depth = whole.bit_depth,
		.format = whole.format,
		.pixels = alloc::new_array(mem, char, (sz)((usz)width * (usz)height * bytes)),
		.allocator = mem,
	};

	for (uint row = 0; row < height; row++)
	{
		usz from = ((usz)(top + row) * (usz)whole.width + (usz)left) * bytes;
		usz to = (usz)row * (usz)width * bytes;
		out.pixels[to:(usz)width * bytes] = whole.pixels[from:(usz)width * bytes];
	}
	return out;
}

// An empty sheet in the tiles' own format, so `blit` is a row copy and nothing
// has to convert.
fn image::Image blank_like(image::Image* tile, uint width, uint height) @local
{
	usz bytes = (usz)tile.bytes_per_pixel();
	char[] pixels = alloc::new_array(mem, char, (sz)((usz)width * (usz)height * bytes));
	return {
		.width = width,
		.height = height,
		.bit_depth = tile.bit_depth,
		.format = tile.format,
		.pixels = pixels,
		.allocator = mem,
	};
}

fn void blit(image::Image* sheet, image::Image* tile, uint x, uint y) @local
{
	usz bytes = (usz)sheet.bytes_per_pixel();
	for (uint row = 0; row < tile.height; row++)
	{
		if (y + row >= sheet.height) return;
		usz from = (usz)row * (usz)tile.width * bytes;
		usz to = ((usz)(y + row) * (usz)sheet.width + (usz)x) * bytes;
		usz run = (usz)tile.width * bytes;
		if (x + tile.width > sheet.width) run = (usz)(sheet.width - x) * bytes;
		sheet.pixels[to:run] = tile.pixels[from:run];
	}
}

<*
 How many tiles go in a row, when the caller did not say.

 Square-ish *sheets*, not square grids: a viewport is whatever shape the
 workspace left it, and four wide tiles in a row make a picture ten times wider
 than it is tall, which is illegible however many pixels it is given. Solving
 `columns · width ≈ rows · height` with `rows = frames / columns` gives
 `columns = √(frames · height / width)`.
*>
fn usz sheet_columns(usz frames, uint width, uint height) @local
{
	if (frames <= 1 || width == 0) return 1;
	double square = math::sqrt((double)frames * (double)height / (double)width);
	usz columns = (usz)math::max(1.0, math::round(square));
	return columns > frames ? frames : columns;
}

<*
 How big one tile is, so that the whole sheet fits the budget.

 Both directions are checked because a wide grid and a tall one run out of room
 on different edges, and a tile taken only from the width would make a
 one-column sheet of nine frames far taller than anything a client keeps.
*>
fn void tile_size(uint width, uint height, usz columns, usz rows, uint* out_width, uint* out_height) @local
{
	uint by_width = RENDER_MAX_EDGE / (uint)columns;
	uint by_height = (uint)((double)(RENDER_MAX_EDGE / (uint)rows) * (double)width / (double)height);

	uint tile = math::min(math::min(by_width, by_height), width);
	// The floor never reaches past the source: enlarging a tile past the pixels
	// that were drawn buys bytes and no detail, which is the same trade
	// `screenshot_content` refuses when it only ever scales down.
	if (tile < RENDER_MIN_TILE) tile = math::min(RENDER_MIN_TILE, width);

	*out_width = tile;
	// Rounded up, so neither side can land on zero however thin the window is.
	*out_height = (uint)math::max(1.0, math::ceil((double)tile * (double)height / (double)width));
}

// The sheet as MCP content: the picture, then a line saying what is in each tile
// and in what order. The tiles carry their own labels (see `label_tile`); the
// list is here too because a caller reading tiles left to right wants the
// numbers exactly, and a 3x5 font rounds the time to two places.
fn String? sheet_content(
	AppState* app,
	image::Image* sheet,
	AnimRef ref,
	float[] times,
	usz[] keys,
	usz columns,
	Vec4 crop,
	Object* args,
	DString* detail) @local
{
	char[]? encoded = png::save_bytes(sheet, mem);
	if (catch error = encoded)
	{
		detail.appendf("the sheet could not be encoded: %s", error);
		return SCREENSHOT_UNREADABLE~;
	}
	char[] bytes = encoded;
	defer alloc::free(mem, bytes);

	String saved = "";
	if (member(args, "path") != null)
	{
		String? wanted = args.get_string("path");
		if (catch wanted)
		{
			detail.append_string(`render's "path" must be a string: where to write the PNG.`);
			return RENDER_REFUSED~;
		}
		if (catch file::save(wanted, (char[])bytes))
		{
			detail.appendf("could not write %s", wanted);
			return RENDER_REFUSED~;
		}
		saved = wanted;
	}

	String data = base64::encode(mem, bytes);
	defer data.free(mem);

	DString out = dstring::new(mem);
	defer out.free();
	out.append_string(`[{"type":"image","mimeType":"image/png","data":"`);
	// No escaping: base64's alphabet is letters, digits, + / and =, none of
	// which JSON quotes.
	out.append_string(data);
	out.appendf(`"},{"type":"text","text":"%d x %d pixels`, sheet.width, sheet.height);

	if (ref.valid())
	{
		AnimTemplate* template = app.clip(ref);
		out.appendf(`, %d tile(s) of \"%s\" across %d column(s), left to right and top to bottom, at `,
			times.len, template.name, columns);
		if (keys.len > 0)
		{
			out.append_string("keys");
			foreach (i, key : keys) out.appendf(i > 0 ? `, %d` : ` %d`, key);
			out.append_string(" (t =");
		}
		else
		{
			out.append_string("t =");
		}
		foreach (i, t : times)
		{
			out.appendf(i > 0 ? `, %.4g` : ` %.4g`, t);
		}
		out.append_string(keys.len > 0 ? " seconds)" : " seconds");
		out.append_string(", each labelled in its top-left corner");
	}
	else
	{
		out.append_string(", one frame of what is on screen");
	}

	if (crop.x > 0 || crop.y > 0 || crop.z < 1 || crop.w < 1)
	{
		out.append_string(", cropped to the viewport");
	}
	if (saved.len > 0) out.appendf(`. Written to %s`, saved);
	out.append_string(`. The player and the camera are back where they were."}]`);
	return out.copy_str(mem);
}

fn String camera_json(AppState* app) @local
{
	DString out = dstring::new(mem);
	defer out.free();

	out.appendf(`{"view":"%s","yaw":%s,"pitch":%s,"distance":%s,"target":`,
		app.camera.view_name(), (JsonFloat)app.camera.yaw, (JsonFloat)app.camera.pitch, (JsonFloat)app.camera.distance);
	// Read back in the model space `target` is given in, so an answer can be
	// handed straight back as an argument.
	append_vec3(&out, app.doc.model_transform.inverse_point(app.camera.target));
	out.append_string(`,"eye":`);
	append_vec3(&out, app.doc.model_transform.inverse_point(app.camera.eye()));
	out.append_char('}');

	return out.copy_str(mem);
}

// The temporary file's full path, allocated from `mem`. A name of its own rather
// than `screenshot`'s, so a render and a screenshot in flight together cannot
// read each other's frame.
fn String temp_sheet_path() @local
{
	Path? directory = path::temp_directory(mem);
	if (catch directory) return SHEET_FILE.copy(mem);
	defer directory.free(mem);
	return string::format(mem, "%s/%s", (String)directory, SHEET_FILE);
}

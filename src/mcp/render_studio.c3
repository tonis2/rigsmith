<*
 render_studio: the character in a two-camera studio, the picture a video
 model animates into a clip that a joint finder reads well (llm-runner's
 creature plugin), as anymove films its creatures.

 One picture, `width` x `height`: on the left the character from in front and
 off its left side, `left_yaw` degrees round (45, a three-quarter view; 0 is
 straight on), and from its right side on the right, its head toward the
 right edge, the same moment in both. A three-quarter view keeps both legs in
 sight in a stride, where a front view hides one behind the other. Both
 cameras are level and (all but) orthographic and share one scale and one
 floor row, so a joint sits on the same row in both halves and the pair pins
 it in 3D. Behind it a plain grey
 wall, a lighter floor band below the floor row, and a dark divider between
 the halves.

 A video model animates this picture from a prompt (the answer carries one to
 start from: the action is the caller's to write). The finder is trained on
 render_poses pictures from the same cameras, so the clip's frames look like
 what it learnt, and the fit knows the cameras instead of searching for them.

 Beside reference.png goes studio.json, the layout: the picture's size, the
 floor row, each view's columns and how a point p of the model lands in it —
 across, the view's left edge plus half its width plus (p - origin)·right
 times pixels_per_unit; down, the floor row minus (p - origin)·up times
 pixels_per_unit — and the shown pose's joints as the cameras saw them.

 The cameras stand STUDIO_DISTANCE rig sizes away, zoomed in to the scale: the
 renderer has no orthographic projection, and from that far the perspective
 moves a point by a fraction of a pixel (the answer says how much). The light
 is the studio's own, high and between the two cameras, so both views are
 lit; studio.json records it.
 The floor row is under the posed mesh's lowest point, with a soft shadow on
 the band under what touches it.

 The pose is the rest pose, or `clip` at `time` (a library clip, played as the
 player plays it, on the spot): a walk's first frame is a better start for a
 video than arms held out. The document is never written; the palette, the
 floor setting and the target size are put back before the call answers.
*>
module crig;

import image;
import image::png;
import rig;
import three;
import std::collections::object;
import std::encoding::json;
import std::io::file;
import std::io::path;
import std::math;
import std::time;

faultdef RENDER_STUDIO_REFUSED;

const String RENDER_STUDIO_SCHEMA = `{"type":"object","properties":{
	"out":{"type":"string","description":"The folder reference.png, studio.json and prompt.txt go in; made when missing."},
	"width":{"type":"integer","description":"The picture's width in pixels, both views together. Default 1280."},
	"height":{"type":"integer","description":"The picture's height in pixels. Default 720."},
	"ground_row":{"type":"integer","description":"The floor's row, from the top. Default seven eighths of the height (630 of 720)."},
	"fill":{"type":"number","description":"The share of the floor row's height the character stands. Default 0.8."},
	"left_yaw":{"type":"number","description":"The left camera, degrees round from the character's face toward its left side: 45 (default) a front-left three-quarter view, 0 straight on. The right camera is at its right side."},
	"front_width":{"type":"integer","description":"The left view's width in pixels; by default the two views are as wide as the character is across each, side by side."},
	"clip":{"type":"string","description":"A clip to take the pose from, by name as get_scene lists it; the rest pose without."},
	"time":{"type":"number","description":"The clip's moment in seconds. Default 0."},
	"layout":{"type":"string","description":"An earlier studio.json to draw with: its size, scale, views and floor kept instead of fitted to this pose, so a clip's frames share one set of cameras (a studio exam). The size options are ignored then."}
},"required":["out"]}`;

<*
 The layout an earlier studio.json at `path` describes, for a rig facing world
 yaw `facing` placed by `model`.
*>
fn StudioLayout? studio_layout_from(String path, float facing, ProjectTransform model)
{
	@pool()
	{
		Object* json = json::parse(tmem, (String)file::load_temp(path)!)!;
		Object* views = json.get("views")!;
		if (!views.is_array() || views.get_len() != 2) return RENDER_STUDIO_REFUSED~;
		StudioLayout layout = {
			.width = (uint)json.get_int("width")!,
			.height = (uint)json.get_int("height")!,
			.ground_row = (uint)json.get_int("ground_row")!,
			.units_per_pixel = (float)json.get_float("units_per_pixel")!,
			.facing = facing,
		};
		if (layout.units_per_pixel <= 0) return RENDER_STUDIO_REFUSED~;
		for (usz v = 0; v < 2; v++)
		{
			Object* view = views.get_at((sz)v);
			float yaw = (float)view.get_float("yaw")!;
			layout.views[v] = { .name = v == 1 ? "side" : yaw == 0 ? "front" : "three_quarter", .x = (uint)view.get_int("x")!,
				.width = (uint)view.get_int("width")!, .yaw = v == 1 ? -90 : yaw };
		}
		// The origin is the floor point both views are centred on, in model space.
		Object* origin = views.get_at(0).get("origin")!;
		if (!origin.is_array() || origin.get_len() != 3) return RENDER_STUDIO_REFUSED~;
		layout.centre = model.point({ (float)origin.get_float_at(0)!, (float)origin.get_float_at(1)!, (float)origin.get_float_at(2)! });
		layout.ground = layout.centre.y;
		return layout;
	};
}

<*
 The studio's light: `base` with its sun high and between the two cameras, so
 both views are lit, and the shadowed side lifted more than the scene's default.
*>
fn three::Lighting StudioLayout.lighting(&self, three::Lighting* base)
{
	three::Lighting lit = *base;
	// Surface to light, as three takes it: toward both eyes (OrbitCamera.eye's).
	Vec3 between;
	foreach (view : self.views)
	{
		float a = math::deg_to_rad(self.facing + view.yaw);
		between += (Vec3){ (float)math::sin(a), 0, (float)math::cos(a) };
	}
	between = between.length() > 1.0e-4f ? between.normalize() : studio_right(self.facing + 90.0f);
	Vec3 sun = (between * 0.85f + (Vec3){ 0, 1.2f, 0 }).normalize();
	lit.lights[0].direction = { sun.x, sun.y, sun.z, base.lights[0].direction[3] };
	lit.lights[0].color = { 1, 1, 1, 1 };
	lit.ambient = STUDIO_AMBIENT;
	lit.world = { STUDIO_FILL, STUDIO_FILL, STUDIO_FILL, 0 };
	return lit;
}

// ============================================================================
// Arguments
// ============================================================================

// A number under `key`, `fallback` when it is missing, refused outside [least, most].
fn bool studio_number(Object* args, String key, double fallback, double least, double most, double* into, DString* detail) @local
{
	*into = fallback;
	if (member(args, key) == null) return true;
	double? given = args.get_float(key);
	if (catch given)
	{
		detail.appendf(`render_studio's "%s" must be a number`, key);
		return false;
	}
	if (given < least || given > most)
	{
		detail.appendf(`render_studio's "%s" is %s; it is from %s to %s.`, key, (JsonFloat)given, (JsonFloat)least, (JsonFloat)most);
		return false;
	}
	*into = given;
	return true;
}

fn bool read_studio_ask(Object* args, StudioAsk* ask, DString* detail) @local
{
	if (!takes_object(args, detail, `render_studio takes an object: {"out": folder, "clip": name, "time": seconds, ...}`)) return false;
	if (!required_string(args, "out", &ask.out, detail, `render_studio needs "out": the folder to write the picture in.`)) return false;
	double v;
	if (!studio_number(args, "width", 1280, 256, 3840, &v, detail)) return false;
	ask.width = (uint)v;
	if (!studio_number(args, "height", 720, 256, 2160, &v, detail)) return false;
	ask.height = (uint)v;
	if (ask.width % 2 != 0 || ask.height % 2 != 0)
	{
		detail.appendf("render_studio's picture is %d x %d; both sides are even, as video encoders want them.", ask.width, ask.height);
		return false;
	}
	if (!studio_number(args, "ground_row", math::round((double)ask.height * 0.875), (double)ask.height * 0.5, (double)ask.height - 1, &v, detail)) return false;
	ask.ground_row = (uint)v;
	if (!studio_number(args, "fill", 0.8, 0.2, 0.95, &v, detail)) return false;
	ask.fill = (float)v;
	if (!studio_number(args, "left_yaw", 45, 0, 60, &v, detail)) return false;
	ask.left_yaw = (float)v;
	if (!studio_number(args, "front_width", 0, 0, (double)ask.width - 64, &v, detail)) return false;
	ask.front_width = (uint)v;
	if (ask.front_width > 0 && ask.front_width < 64)
	{
		detail.appendf(`render_studio's "front_width" is %d; a view is at least 64 pixels wide.`, ask.front_width);
		return false;
	}
	ask.clip = "";
	if (member(args, "clip") != null)
	{
		if (!required_string(args, "clip", &ask.clip, detail, `render_studio's "clip" is a clip's name, as get_scene lists it`)) return false;
	}
	if (!studio_number(args, "time", 0, 0, 1.0e6, &v, detail)) return false;
	ask.time = (float)v;
	ask.layout = "";
	if (member(args, "layout") != null)
	{
		if (!required_string(args, "layout", &ask.layout, detail, `render_studio's "layout" is the path of an earlier studio.json`)) return false;
	}
	return true;
}

// ============================================================================
// The tool
// ============================================================================

fn String? tool_render_studio(Object* args, void* user_data, DString* detail) @private
{
	StudioAsk ask;
	if (!read_studio_ask(args, &ask, detail)) return RENDER_STUDIO_REFUSED~;
	return ((AppState*)user_data).render_studio_picture(&ask, detail);
}

<*
 The studio picture `given` asks for, drawn and written (reference.png,
 studio.json, prompt.txt), as render_studio draws it: its answer, or a fault
 with why in `detail`.
*>
fn String? AppState.render_studio_picture(&self, StudioAsk* given, DString* detail)
{
	AppState* app = self;
	StudioAsk ask = *given;
	if (!hosted() || stage_renderer() == null)
	{
		detail.append_string("there is no renderer: this Rigsmith is running headless.");
		return RENDER_STUDIO_REFUSED~;
	}
	if (app.doc.dots.len() == 0 || !app.has_mesh())
	{
		detail.append_string("there is nothing to photograph: render_studio needs a rigged mesh.");
		return RENDER_STUDIO_REFUSED~;
	}
	RigView? opened = app.open_rig(mem);
	if (catch opened)
	{
		detail.append_string("the rig could not be read.");
		return RENDER_STUDIO_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);
	if (!app.rebind_skin(&view))
	{
		detail.append_string("the mesh could not be skinned to the rig.");
		return RENDER_STUDIO_REFUSED~;
	}
	if (catch path::mkdir(ask.out, true))
	{
		// Already there, or it cannot be made: the first write says which.
	}
	if (!file::is_dir(ask.out))
	{
		detail.appendf(`"%s" is not a folder and could not be made.`, ask.out);
		return RENDER_STUDIO_REFUSED~;
	}

	// The pose: the rest pose, or the clip's moment on the spot.
	rig::Pose pose;
	if (ask.dots.len > 0)
	{
		AnimKeyframe[1] keys = { { .dots = ask.dots } };
		AnimTemplate held = { .keyframes = keys[..] };
		pose = held.pose(mem, &view.skeleton, view.names, 0, false);
		constrain_pose_to_joint_limits(&app.doc, &view.skeleton, view.dot_ids, &pose);
		foreach (usz j, parent : view.skeleton.parents)
		{
			if (parent >= 0 || j >= pose.offsets.len) continue;
			pose.offsets[j].x = 0;
			pose.offsets[j].z = 0;
		}
	}
	else if (ask.clip.len > 0)
	{
		AnimRef? named = resolve_named(app, ask.clip, detail);
		if (catch named) return RENDER_STUDIO_REFUSED~;
		app.ensure_clip_imported(named);
		AnimTemplate* clip = app.clip(named);
		if (clip == null || clip.keyframes.len == 0)
		{
			detail.appendf(`clip "%s" has no keys to play.`, ask.clip);
			return RENDER_STUDIO_REFUSED~;
		}
		float time = ask.time;
		if (clip.duration > 0.0f) time -= clip.duration * (float)math::floor(time / clip.duration);
		pose = app.evaluated_clip_pose(mem, &view, *clip, named, time);
		foreach (usz j, parent : view.skeleton.parents)
		{
			if (parent >= 0 || j >= pose.offsets.len) continue;
			pose.offsets[j].x = 0;
			pose.offsets[j].z = 0;
		}
	}
	else
	{
		pose = rig::rest_pose(mem, view.skeleton.len());
	}
	defer pose.free(mem);
	Matrix4f[]? palette = rig::joint_palette(mem, &view.skeleton, pose);
	if (catch palette)
	{
		detail.append_string("the pose did not fit the rig.");
		return RENDER_STUDIO_REFUSED~;
	}
	defer alloc::free(mem, palette);
	Vec3[] at = posed_joints(&view, palette);
	defer alloc::free(mem, at);
	Vec3[] world = alloc::new_array(mem, Vec3, (sz)at.len);
	defer alloc::free(mem, world);
	foreach (usz j, p : at) world[j] = app.doc.model_transform.point(p);

	rig::Bounds bounds = app.world_bounds();
	float height = math::max(bounds.max.y - bounds.min.y, 1.0e-4f);
	float radius = math::max((bounds.max - bounds.min).length() * 0.5f, 1.0e-4f);
	// The floor under the posed mesh: a clip's stride is not the rest pose's,
	// and a toe the player leaves below its floor would sink under the band.
	Vec3[] skinned = alloc::new_array(mem, Vec3, (sz)app.geometry.positions.len);
	defer alloc::free(mem, skinned);
	if (catch rig::skin_positions(skinned, app.geometry.positions, app.skin, palette))
	{
		detail.append_string("the mesh could not be posed.");
		return RENDER_STUDIO_REFUSED~;
	}
	float ground = 1.0e30f;
	foreach (p : skinned) ground = math::min(ground, app.doc.model_transform.point(p).y);
	Vec3 origin = app.doc.model_transform.point({ 0, 0, 0 });
	Vec3 ahead = app.doc.model_transform.point({ 0, 0, 1 }) - origin;
	float facing = math::rad_to_deg((float)math::atan2(ahead.x, ahead.z));
	StudioLayout layout;
	if (ask.layout.len > 0)
	{
		StudioLayout? kept = studio_layout_from(ask.layout, facing, app.doc.model_transform);
		if (catch kept)
		{
			detail.appendf(`"%s" is not a studio.json render_studio wrote.`, ask.layout);
			return RENDER_STUDIO_REFUSED~;
		}
		layout = kept;
		ask.left_yaw = layout.views[0].yaw;
	}
	else
	{
		layout = studio_layout(world, height, ground, facing, &ask);
	}

	// Everything below changes what the window shows; every way out puts it back.
	three::Renderer* renderer = stage_renderer();
	uint was_width = renderer.target.extent.width;
	uint was_height = renderer.target.extent.height;
	bool was_editing = app.pose_edit_active;
	bool was_floorless = app.config.hide_floor;
	three::MeshPass* pass = stage_pass();
	three::Lighting was_lighting = pass.lighting;
	three::Lighting lit = layout.lighting(&was_lighting);
	pass.note_lighting_change(lit);
	pass.lighting = lit;
	app.pose_edit_active = true;
	app.config.hide_floor = true;
	defer
	{
		pass.note_lighting_change(was_lighting);
		pass.lighting = was_lighting;
		app.pose_edit_active = was_editing;
		app.config.hide_floor = was_floorless;
		(void)renderer.resize_target(was_width, was_height);
		app.next_pose_generation();
		app.refresh_ui();
	}

	Clock started = clock::now();
	char[] rgb = alloc::new_array(mem, char, (sz)((usz)layout.width * layout.height * 3));
	defer alloc::free(mem, rgb);
	float[][2] seen;
	float worst = 0.0f;
	defer foreach (s : seen) if (s.len > 0) alloc::free(mem, s);
	for (usz v = 0; v < 2; v++)
	{
		StudioView half = layout.views[v];
		if (catch renderer.resize_target(half.width, layout.height))
		{
			detail.appendf("a %d x %d target could not be made.", half.width, layout.height);
			return RENDER_STUDIO_REFUSED~;
		}
		OrbitCamera camera = layout.camera(v, radius);
		float[] sum = alloc::new_array(mem, float, (sz)((usz)half.width * layout.height * 4));
		defer alloc::free(mem, sum);
		if (catch err = add_matted(app, &view, pose, &camera, sum))
		{
			detail.appendf("the %s view could not be drawn: %s", half.name, err);
			return RENDER_STUDIO_REFUSED~;
		}
		layout.composite(v, sum, rgb);
		layout.shadow(v, sum, rgb);

		// Each joint as the camera put it, against where an orthographic one would.
		Matrix4f projection = app.model_view_projection(&camera, (float)half.width / (float)layout.height);
		seen[v] = alloc::new_array(mem, float, (sz)(at.len * 2));
		foreach (usz j, p : at)
		{
			float[<2>] shown = layout.projected(v, projection, p);
			seen[v][j * 2] = shown.x;
			seen[v][j * 2 + 1] = shown.y;
			worst = math::max(worst, (shown - layout.pixel(v, world[j])).length());
		}
	}
	layout.divide(rgb);

	String picture_path = string::tformat("%s/reference.png", ask.out);
	image::Image picture = { .width = layout.width, .height = layout.height, .bit_depth = 8, .format = image::PixelFormat.RGB, .pixels = rgb, .allocator = mem };
	if (catch png::save_file(&picture, picture_path))
	{
		detail.appendf("could not write %s", picture_path);
		return RENDER_STUDIO_REFUSED~;
	}

	// The layout, in model space: where a point of the model lands in each view.
	DString out = dstring::new(mem);
	defer out.free();
	Vec3 middle = app.doc.model_transform.inverse_point(layout.centre);
	Vec3 up = app.doc.model_transform.inverse_direction({ 0, 1, 0 });
	out.appendf(`{"version":1,"width":%d,"height":%d,"ground_row":%d,"pixels_per_unit":%s,"units_per_pixel":%s,`,
		layout.width, layout.height, layout.ground_row, (JsonFloat)(1.0f / layout.units_per_pixel), (JsonFloat)layout.units_per_pixel);
	out.appendf(`"wall":[%d,%d,%d],"floor":[%d,%d,%d],"divider":[%d,%d,%d],"divider_width":%d,"views":[`,
		STUDIO_WALL[0], STUDIO_WALL[1], STUDIO_WALL[2], STUDIO_FLOOR[0], STUDIO_FLOOR[1], STUDIO_FLOOR[2],
		STUDIO_DIVIDER[0], STUDIO_DIVIDER[1], STUDIO_DIVIDER[2], STUDIO_DIVIDER_WIDTH);
	for (usz v = 0; v < 2; v++)
	{
		StudioView half = layout.views[v];
		Vec3 right = app.doc.model_transform.inverse_direction(studio_right(layout.facing + half.yaw));
		if (v > 0) out.append_char(',');
		out.appendf(`{"name":"%s","x":%d,"width":%d,"yaw":%s,"origin":[%s,%s,%s],"right":[%s,%s,%s],"up":[%s,%s,%s]}`,
			half.name, half.x, half.width, (JsonFloat)half.yaw,
			(JsonFloat)middle.x, (JsonFloat)middle.y, (JsonFloat)middle.z,
			(JsonFloat)right.x, (JsonFloat)right.y, (JsonFloat)right.z, (JsonFloat)up.x, (JsonFloat)up.y, (JsonFloat)up.z);
	}
	Vec3 sun = app.doc.model_transform.inverse_direction({ lit.lights[0].direction[0], lit.lights[0].direction[1], lit.lights[0].direction[2] });
	out.appendf(`],"light":{"direction":[%s,%s,%s],"ambient":%s,"fill":%s},"clip":"`,
		(JsonFloat)sun.x, (JsonFloat)sun.y, (JsonFloat)sun.z, (JsonFloat)STUDIO_AMBIENT, (JsonFloat)STUDIO_FILL);
	json_escape_into(&out, ask.clip);
	out.appendf(`","time":%s,"joints":[`, (JsonFloat)ask.time);
	foreach (usz j, name : view.names)
	{
		if (j > 0) out.append_char(',');
		out.append_char('"');
		json_escape_into(&out, name);
		out.append_char('"');
	}
	out.append_string(`],"pixels":[`);
	for (usz v = 0; v < 2; v++)
	{
		if (v > 0) out.append_char(',');
		out.append_char('[');
		for (usz j = 0; j < at.len; j++)
		{
			if (j > 0) out.append_char(',');
			out.appendf("[%s,%s]", (JsonFloat)seen[v][j * 2], (JsonFloat)seen[v][j * 2 + 1]);
		}
		out.append_char(']');
	}
	out.append_string("]}");
	String layout_path = string::tformat("%s/studio.json", ask.out);
	if (catch file::save(layout_path, (char[])out.str_view()))
	{
		detail.appendf("could not write %s", layout_path);
		return RENDER_STUDIO_REFUSED~;
	}
	String prompt_path = string::tformat("%s/prompt.txt", ask.out);
	String prompt = studio_prompt(ask.left_yaw);
	if (catch file::save(prompt_path, (char[])prompt))
	{
		detail.appendf("could not write %s", prompt_path);
		return RENDER_STUDIO_REFUSED~;
	}

	double took = (double)(long)started.to_now() / 1.0e9;
	DString answer = dstring::new(mem);
	defer answer.free();
	answer.append_string(`{"reference":"`);
	json_escape_into(&answer, picture_path);
	answer.append_string(`","layout":"`);
	json_escape_into(&answer, layout_path);
	answer.appendf(`","views":[{"name":"%s","yaw":%s,"x":0,"width":%d},{"name":"%s","yaw":%s,"x":%d,"width":%d}],"units_per_pixel":%s,"ortho_error_px":%s,"prompt":"`,
		layout.views[0].name, (JsonFloat)layout.views[0].yaw, layout.views[0].width, layout.views[1].name, (JsonFloat)layout.views[1].yaw,
		layout.views[1].x, layout.views[1].width, (JsonFloat)layout.units_per_pixel, (JsonFloat)worst);
	json_escape_into(&answer, prompt);
	answer.appendf(`","seconds":%s}`, (JsonFloat)took);
	return answer.copy_str(mem);
}

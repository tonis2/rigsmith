<*
 render_studio: the character in a two-camera studio, the picture a video
 model animates into a clip that a joint finder reads well (llm-runner's
 creature plugin), as anymove films its creatures.

 One picture, `width` x `height`: the character from the front on the left,
 facing the viewer, and from its right side on the right, its head toward the
 right edge, the same moment in both. Both cameras are level and (all but)
 orthographic and share one scale and one floor row, so a joint sits on the
 same row in both halves and the pair pins it in 3D. Behind it a plain grey
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
 is the studio's own, high and between the two cameras, so the face and the
 right flank are both lit; studio.json records it for the training pictures.
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
import std::io::file;
import std::io::path;
import std::math;
import std::time;

faultdef RENDER_STUDIO_REFUSED;

// How far the cameras stand, in rig sizes (the rest mesh's bounding radius).
const float STUDIO_DISTANCE = 1000.0f;
const char[3] STUDIO_WALL = { 128, 130, 134 };
const char[3] STUDIO_FLOOR = { 152, 154, 158 };
const char[3] STUDIO_DIVIDER = { 34, 34, 38 };
const uint STUDIO_DIVIDER_WIDTH = 4;
// The studio light's shadowed side and the world's even fill.
const float STUDIO_AMBIENT = 0.4f;
const float STUDIO_FILL = 0.08f;
// The contact shadow under the feet: how dark at most, how many rows down it
// fades over, and how far it spreads past the soles to either side.
const float STUDIO_SHADOW_DEPTH = 0.45f;
const usz STUDIO_SHADOW_ROWS = 18;
const usz STUDIO_SHADOW_SPREAD = 10;

const String RENDER_STUDIO_SCHEMA = `{"type":"object","properties":{
	"out":{"type":"string","description":"The folder reference.png, studio.json and prompt.txt go in; made when missing."},
	"width":{"type":"integer","description":"The picture's width in pixels, both views together. Default 1280."},
	"height":{"type":"integer","description":"The picture's height in pixels. Default 720."},
	"ground_row":{"type":"integer","description":"The floor's row, from the top. Default seven eighths of the height (630 of 720)."},
	"fill":{"type":"number","description":"The share of the floor row's height the character stands. Default 0.8."},
	"front_width":{"type":"integer","description":"The front view's width in pixels; by default the two views are as wide as the character is across each, side by side."},
	"clip":{"type":"string","description":"A clip to take the pose from, by name as get_scene lists it; the rest pose without."},
	"time":{"type":"number","description":"The clip's moment in seconds. Default 0."}
},"required":["out"]}`;

// One half of the picture: its columns and its camera's yaw against the way
// the rig faces (0 at its face, -90 at its right side).
struct StudioView
{
	String name;
	uint x;
	uint width;
	float yaw;
}

struct StudioLayout
{
	uint width;
	uint height;
	uint ground_row;
	// World units a pixel spans, in both views.
	float units_per_pixel;
	// The floor's height, and the point on it both views are centred on.
	float ground;
	Vec3 centre;
	// The world yaw the rig faces (its +Z), in degrees.
	float facing;
	StudioView[2] views;
}

// What a call was asked for.
struct StudioAsk
{
	String out;
	uint width;
	uint height;
	uint ground_row;
	float fill;
	// 0 to split the picture by what each view has to show.
	uint front_width;
	String clip;
	float time;
}

// Right across the picture for a camera at `yaw` degrees (OrbitCamera's: 0 puts
// the eye on +Z), in the world.
fn Vec3 studio_right(float yaw)
{
	float a = math::deg_to_rad(yaw);
	return { (float)math::cos(a), 0, -(float)math::sin(a) };
}

<*
 The layout for a figure `height` tall standing on `ground`, facing world yaw
 `facing`, whose joints are `at` (world): its height fills `fill` of the floor
 row; each view is as wide as the figure is across it, with room for the body
 round the joints and, from the side, for a stride; the scale is coarsened when
 the two would not fit side by side.
*>
fn StudioLayout studio_layout(Vec3[] at, float height, float ground, float facing, StudioAsk* ask)
{
	StudioLayout layout = { .width = ask.width, .height = ask.height, .ground_row = ask.ground_row, .ground = ground, .facing = facing };
	layout.views[0] = { .name = "front", .yaw = 0 };
	layout.views[1] = { .name = "side", .yaw = -90 };
	height = math::max(height, 1.0e-4f);
	float[2] least = { 1.0e30f, 1.0e30f };
	float[2] most = { -1.0e30f, -1.0e30f };
	for (usz v = 0; v < 2; v++)
	{
		Vec3 right = studio_right(facing + layout.views[v].yaw);
		foreach (p : at)
		{
			least[v] = math::min(least[v], right.dot(p));
			most[v] = math::max(most[v], right.dot(p));
		}
		if (most[v] < least[v]) least[v] = most[v] = 0;
	}
	// The two rights are level and square to each other: the point on the floor
	// that is the middle of the joints along both.
	layout.centre = studio_right(facing) * ((least[0] + most[0]) * 0.5f)
		+ studio_right(facing - 90.0f) * ((least[1] + most[1]) * 0.5f);
	layout.centre.y = ground;

	float per_pixel = height / (ask.fill * (float)ask.ground_row);
	float body = 0.15f * height;
	float front = (most[0] - least[0] + 2.0f * body) * 1.1f / per_pixel;
	float side = (math::max(most[1] - least[1], 0.5f * height) + 2.0f * body) * 1.1f / per_pixel;
	float total = (float)ask.width;
	uint split = ask.front_width;
	if (split == 0)
	{
		float share = math::clamp(front / (front + side), 0.25f, 0.75f);
		split = (uint)math::round(total * share * 0.5f) * 2;
	}
	// Coarser wherever a view is narrower than its side of the figure needs.
	per_pixel *= math::max(1.0f, math::max(front / (float)split, side / (total - (float)split)));
	layout.units_per_pixel = per_pixel;
	layout.views[0].x = 0;
	layout.views[0].width = split;
	layout.views[1].x = split;
	layout.views[1].width = ask.width - split;
	return layout;
}

// Where world point `p` lands in view `v`, as an orthographic camera puts it:
// pixels across the whole picture and down from its top.
fn float[<2>] StudioLayout.pixel(&self, usz v, Vec3 p)
{
	StudioView view = self.views[v];
	float across = (p - self.centre).dot(studio_right(self.facing + view.yaw));
	return {
		(float)view.x + (float)view.width * 0.5f + across / self.units_per_pixel,
		(float)self.ground_row - (p.y - self.ground) / self.units_per_pixel,
	};
}

<*
 View `v`'s camera: level, `STUDIO_DISTANCE` times `radius` away, zoomed so a
 pixel spans the layout's units where the figure stands, aimed so the centre
 lands mid-view and the floor on its row.
*>
fn OrbitCamera StudioLayout.camera(&self, usz v, float radius)
{
	radius = math::max(radius, 1.0e-4f);
	float distance = radius * STUDIO_DISTANCE;
	float half = (float)self.height * 0.5f * self.units_per_pixel;
	OrbitCamera camera = {
		.target = self.centre + (Vec3){ 0, ((float)self.ground_row - (float)self.height * 0.5f) * self.units_per_pixel, 0 },
		.yaw = self.facing + self.views[v].yaw,
		.pitch = 0,
		.fov = 2.0f * math::rad_to_deg((float)math::atan(half / distance)),
		.distance = distance,
	};
	// Close round the figure: depth keeps its precision, and the shadow map
	// fits the figure rather than a long empty frustum.
	camera.near_plane = distance - 4.0f * radius;
	camera.far_plane = distance + 4.0f * radius;
	camera.min_distance = camera.near_plane;
	camera.max_distance = camera.far_plane;
	return camera;
}

// Where `projection` puts model point `p` in view `v`, across the whole picture.
fn float[<2>] StudioLayout.projected(&self, usz v, Matrix4f projection, Vec3 p)
{
	StudioView view = self.views[v];
	Vec4 clip = projection.apply({ p.x, p.y, p.z, 1.0f });
	float w = math::abs(clip.w) < 1.0e-9f ? 1.0e-9f : clip.w;
	return {
		(float)view.x + (clip.x / w * 0.5f + 0.5f) * (float)view.width,
		(clip.y / w * 0.5f + 0.5f) * (float)self.height,
	};
}

<*
 View `v`'s matted frame (premultiplied, four floats a pixel, its own width)
 laid over the wall and the floor band into `rgb`, the whole picture.
*>
fn void StudioLayout.composite(&self, usz v, float[] sum, char[] rgb)
{
	StudioView view = self.views[v];
	for (usz y = 0; y < self.height; y++)
	{
		char[3] back = y >= self.ground_row ? STUDIO_FLOOR : STUDIO_WALL;
		for (usz x = 0; x < view.width; x++)
		{
			usz i = (y * view.width + x) * 4;
			usz o = (y * self.width + view.x + x) * 3;
			float through = 1.0f - math::clamp(sum[i + 3] / 255.0f, 0.0f, 1.0f);
			for (usz c = 0; c < 3; c++) rgb[o + c] = (char)math::clamp(sum[i + c] + through * (float)back[c] + 0.5f, 0.0f, 255.0f);
		}
	}
}

<*
 A soft shadow on the floor band under whatever of view `v` touches the floor
 row (`sum` as `composite` takes it): without one, a figure standing on a
 floor seen edge on looks as if it hovers over it. Darkest at the floor row
 under the soles, fading over STUDIO_SHADOW_ROWS rows down and spread
 STUDIO_SHADOW_SPREAD pixels to either side.
*>
fn void StudioLayout.shadow(&self, usz v, float[] sum, char[] rgb)
{
	StudioView view = self.views[v];
	usz w = view.width;
	float[] touch = alloc::new_array(tmem, float, (sz)w);
	float[] spread = alloc::new_array(tmem, float, (sz)w);
	// How much of each column's figure reaches the last rows above the floor.
	for (usz x = 0; x < w; x++)
	{
		for (usz y = self.ground_row > 3 ? (usz)self.ground_row - 3 : 0; y < self.ground_row; y++)
		{
			touch[x] = math::max(touch[x], math::clamp(sum[(y * w + x) * 4 + 3] / 255.0f, 0.0f, 1.0f));
		}
	}
	// Spread sideways, twice over a box, to soften its ends.
	for (int pass = 0; pass < 2; pass++)
	{
		for (usz x = 0; x < w; x++)
		{
			float total = 0.0f;
			usz from = x > STUDIO_SHADOW_SPREAD ? x - STUDIO_SHADOW_SPREAD : 0;
			usz to = math::min(x + STUDIO_SHADOW_SPREAD + 1, w);
			for (usz k = from; k < to; k++) total += touch[k];
			spread[x] = total / (float)(2 * STUDIO_SHADOW_SPREAD + 1);
		}
		foreach (usz x, value : spread) touch[x] = math::min(1.0f, value * 1.6f);
	}
	for (usz r = 0; r < STUDIO_SHADOW_ROWS && self.ground_row + r < self.height; r++)
	{
		float fade = 1.0f - (float)r / (float)STUDIO_SHADOW_ROWS;
		usz y = self.ground_row + r;
		for (usz x = 0; x < w; x++)
		{
			float keep = 1.0f - STUDIO_SHADOW_DEPTH * touch[x] * fade * fade;
			if (sum[(y * w + x) * 4 + 3] > 1.0f) continue;
			usz o = (y * self.width + view.x + x) * 3;
			for (usz c = 0; c < 3; c++) rgb[o + c] = (char)math::clamp((float)rgb[o + c] * keep + 0.5f, 0.0f, 255.0f);
		}
	}
}

// The dark line where the views meet.
fn void StudioLayout.divide(&self, char[] rgb)
{
	uint split = self.views[1].x;
	uint from = split > STUDIO_DIVIDER_WIDTH / 2 ? split - STUDIO_DIVIDER_WIDTH / 2 : 0;
	uint to = math::min(split + STUDIO_DIVIDER_WIDTH / 2, self.width);
	for (usz y = 0; y < self.height; y++)
	{
		for (usz x = from; x < to; x++)
		{
			for (usz c = 0; c < 3; c++) rgb[(y * self.width + x) * 3 + c] = STUDIO_DIVIDER[c];
		}
	}
}

<*
 The studio's light: `base` with its sun high and between the two cameras, in
 front of the figure and off its right side, so the face and the right flank
 are both lit, and the shadowed side lifted more than the scene's default.
*>
fn three::Lighting StudioLayout.lighting(&self, three::Lighting* base)
{
	three::Lighting lit = *base;
	Vec3 ahead = studio_right(self.facing + 90.0f);
	Vec3 right_side = -studio_right(self.facing);
	Vec3 sun = (ahead * 0.6f + right_side * 0.6f + (Vec3){ 0, 1.2f, 0 }).normalize();
	lit.lights[0].direction = { sun.x, sun.y, sun.z, base.lights[0].direction[3] };
	lit.lights[0].color = { 1, 1, 1, 1 };
	lit.ambient = STUDIO_AMBIENT;
	lit.world = { STUDIO_FILL, STUDIO_FILL, STUDIO_FILL, 0 };
	return lit;
}

// The prompt a video model is given with the picture; the action is the caller's.
const String STUDIO_PROMPT = `Animate the exact character shown twice in this split-screen image. Left: a front camera, the character faces the viewer. Right: a side camera on its right side, the character faces right. Both are locked-off cameras filming the same character at the same moment, so every movement happens in both views at exactly the same time, frame for frame. Keep the character exactly as it is: the same model, colours and proportions, nothing added or lost. Action: <describe the movement here>. It stays on the spot, centred in both views, and does not travel. One continuous shot at natural speed, no slow motion. The cameras never move, cut, pan or zoom; the plain grey background, the lighter floor band and the dark vertical divider stay fixed.`;

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

// What a call with nothing but `out` asks for.
fn StudioAsk studio_ask_defaults(String out)
{
	return { .out = out, .width = 1280, .height = 720, .ground_row = 630, .fill = 0.8f };
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
	if (ask.clip.len > 0)
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
	StudioLayout layout = studio_layout(world, height, ground, facing, &ask);

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
	if (catch file::save(prompt_path, (char[])STUDIO_PROMPT))
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
	answer.appendf(`","views":[{"name":"front","x":0,"width":%d},{"name":"side","x":%d,"width":%d}],"units_per_pixel":%s,"ortho_error_px":%s,"prompt":"`,
		layout.views[0].width, layout.views[1].x, layout.views[1].width, (JsonFloat)layout.units_per_pixel, (JsonFloat)worst);
	json_escape_into(&answer, STUDIO_PROMPT);
	answer.appendf(`","seconds":%s}`, (JsonFloat)took);
	return answer.copy_str(mem);
}

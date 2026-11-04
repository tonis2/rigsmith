<* The pure half of src/mcp/render_studio.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::object;
import std::encoding::json;
import std::math;
import std::time;

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

// One half of the picture: its columns and its camera's yaw against the way
// the rig faces (0 at its face, 90 at its left side, -90 at its right).
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
	// The left camera's yaw (the right one is at -90).
	float left_yaw;
	// 0 to split the picture by what each view has to show.
	uint front_width;
	String clip;
	float time;
	// An earlier studio.json whose cameras are kept; "" to fit the pose.
	String layout;
	// A saved pose to draw instead (borrowed); a clip is not read then.
	AnimKeyDot[] dots;
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
	layout.views[0] = { .name = ask.left_yaw == 0 ? "front" : "three_quarter", .yaw = ask.left_yaw };
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
	// The point on the floor that is the middle of the joints along both rights
	// (level, at least 30 degrees apart): c = a r0 + b r1 with c·r0 = m0, c·r1 = m1.
	Vec3 r0 = studio_right(facing + layout.views[0].yaw);
	Vec3 r1 = studio_right(facing + layout.views[1].yaw);
	float m0 = (least[0] + most[0]) * 0.5f;
	float m1 = (least[1] + most[1]) * 0.5f;
	float k = r0.dot(r1);
	float d = math::max(1.0f - k * k, 0.25f);
	layout.centre = r0 * ((m0 - k * m1) / d) + r1 * ((m1 - k * m0) / d);
	layout.centre.y = ground;

	// Room for a stride, as much of it as a view sees across.
	float per_pixel = height / (ask.fill * (float)ask.ground_row);
	float body = 0.15f * height;
	float[2] need;
	for (usz v = 0; v < 2; v++)
	{
		float stride = 0.5f * height * math::abs((float)math::sin(math::deg_to_rad(layout.views[v].yaw)));
		need[v] = (math::max(most[v] - least[v], stride) + 2.0f * body) * 1.1f / per_pixel;
	}
	float front = need[0];
	float side = need[1];
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

// The prompt a video model is given with the picture; the action, first, is the caller's.
const String STUDIO_PROMPT = `Action: <describe the movement here>.

Animate the exact character shown twice in this split-screen image doing the action above. <the views> Both are locked-off cameras filming the same character at the same moment, so every movement happens in both views at exactly the same time, frame for frame. Keep the character exactly as it is: the same model, colours and proportions, nothing added or lost. It stays on the spot, centred in both views, and does not travel; its whole body, feet included, stays inside each view.

Film it with a fast shutter: every frame is sharp and crisp, with no motion blur, smearing or ghosting, even on fast-moving hands and feet. Each arm and leg keeps its full shape in every frame and stays clearly separate from the others. Everything in focus, even light, no flicker. One continuous shot at natural speed, no slow motion. The cameras never move, cut, pan or zoom; the plain grey background, the lighter floor band and the dark vertical divider stay fixed.`;

// The views as the prompts say them, for a left camera at `left_yaw`.
fn String studio_views_text(float left_yaw)
{
	String left = left_yaw == 0
		? "Left: a front camera, the character faces the viewer."
		: "Left: a three-quarter camera in front of the character and off its left side, the character faces toward the viewer and the left of the picture, both legs in sight.";
	return string::tformat("%s Right: a side camera on its right side, the character faces right.", left);
}

// The video prompt for a left camera at `left_yaw`, the action still to fill.
fn String studio_prompt(float left_yaw) => STUDIO_PROMPT.treplace("<the views>", studio_views_text(left_yaw));

// What a call with nothing but `out` asks for.
fn StudioAsk studio_ask_defaults(String out)
{
	return { .out = out, .width = 1280, .height = 720, .ground_row = 630, .fill = 0.8f, .left_yaw = 45 };
}

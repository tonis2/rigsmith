<*
 The picked walk path's knots in the 3D view, while the dock shows the cutscene: squares
 on the ground. Drag one along the ground; click the path's line to put a knot
 there; Delete takes the picked knot; Esc puts a dragged one back. The line
 itself is engine/cutscene_paths.c3's.
*>
module crig;

import collision;
import cui;
import std::math;

const float CUT_KNOT_SIZE = 9.0;
const Color CUT_KNOT_INK = { 0.98, 0.82, 0.30, 1.0 };

<* A press on a knot, waiting to see whether it is a click or a drag. *>
struct CutKnotPress
{
	bool pending;
	usz knot;
	Vec2 at;
}

fn bool cut_knots_shown(AppState* app) => app.cutscene_in_dock() && app.cut_picked_path() != null;

fn Matrix4f Viewport.world_view_projection(&self, Element* elem) => self.view_camera(elem).view_projection(elem.size.x / elem.size.y);

<* The world ray through `pixel` of this pane. *>
fn collision::Ray? Viewport.world_ray(&self, Element* elem, Vec2 pixel)
{
	OrbitCamera* camera = self.view_camera(elem);
	Vec3 direction = camera.ray_direction(pixel, elem.size)!;
	return { .origin = camera.eye(), .direction = direction.normalize() };
}

<* The picked path's knot under `pixel`, one-based; 0 for none. *>
fn usz Viewport.cut_knot_at(&self, Element* elem, AppState* app, Vec2 pixel)
{
	WalkPath* path = app.cut_picked_path();
	if (!path) return 0;
	Matrix4f view_projection = self.world_view_projection(elem);
	float best = PICK_RADIUS;
	usz found;
	foreach (usz k, knot : path.knots)
	{
		Vec2? at = project(view_projection, knot, elem.size);
		if (catch at) continue;
		float d = (at - pixel).length();
		if (d > best) continue;
		best = d;
		found = k + 1;
	}
	return found;
}

<* Whether `pixel` is on the picked path's line on screen, and the ground point of it there. *>
fn bool Viewport.cut_line_at(&self, Element* elem, AppState* app, Vec2 pixel, Vec3* out)
{
	WalkPath* path = app.cut_picked_path();
	if (!path || path.points.len < 2) return false;
	Matrix4f view_projection = self.world_view_projection(elem);
	float best = PICK_RADIUS * 0.75f;
	bool found;
	for (usz k = 0; k + 1 < path.points.len; k++)
	{
		Vec2[2]? ends = project_segment(view_projection, path.points[k], path.points[k + 1], elem.size);
		if (catch ends) continue;
		Vec2 step = ends[1] - ends[0];
		float span = step.dot(step);
		float u = span > 1e-6f ? math::clamp((pixel - ends[0]).dot(step) / span, 0.0f, 1.0f) : 0.0f;
		float d = (ends[0] + step * u - pixel).length();
		if (d > best) continue;
		best = d;
		*out = path.points[k] + (path.points[k + 1] - path.points[k]) * u;
		found = true;
	}
	return found;
}

<*
 A press the picked path takes: on a knot, it is picked and may be dragged; on
 its line, a knot is put in there.

 @return "Whether the press was the path's"
*>
fn bool Viewport.press_cut_knots(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (!cut_knots_shown(app)) return false;
	usz knot = self.cut_knot_at(elem, app, pixel);
	if (knot > 0)
	{
		app.cut_knot_pick = knot;
		self.cut_knot_press = { .pending = true, .knot = knot - 1, .at = pixel };
		refresh_animations_view(elem.ui);
		app.refresh_ui();
		elem.request_paint();
		return true;
	}
	Vec3 at;
	if (!self.cut_line_at(elem, app, pixel, &at)) return false;
	if (app.insert_cut_knot(app.cut_path_pick - 1, at)) app.@notice("a knot put in · drag it along the ground · Delete takes it out");
	refresh_animations_view(elem.ui);
	app.refresh_ui();
	elem.request_paint();
	return true;
}

<* The pointer moved: a held knot past CLICK_SLOP starts its drag, and a dragged one follows the ground under the pointer. *>
fn bool Viewport.move_cut_knots(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (self.cut_knot_press.pending)
	{
		if ((pixel - self.cut_knot_press.at).length() <= CLICK_SLOP) return true;
		self.cut_knot_press.pending = false;
		WalkPath* path = app.cut_picked_path();
		if (!path || !app.begin_cut_knot_drag(app.cut_path_pick - 1, self.cut_knot_press.knot)) return true;
	}
	if (!app.cut_knot_dragging) return false;
	collision::Ray? ray = self.world_ray(elem, pixel);
	if (catch ray) return true;
	GroundHit hit = cut_ground_along(ray);
	if (hit.hit && app.drag_cut_knot(hit.point)) app.refresh_ui();
	elem.request_paint();
	return true;
}

<* The button let go: a click picked its knot on the press, and a drag lands as one undo step. *>
fn bool Viewport.release_cut_knots(&self, Element* elem, AppState* app)
{
	if (self.cut_knot_press.pending)
	{
		self.cut_knot_press = {};
		return true;
	}
	if (!app.cut_knot_dragging) return false;
	(void)app.end_cut_knot_drag();
	refresh_animations_view(elem.ui);
	app.refresh_ui();
	elem.request_paint();
	return true;
}

fn void Viewport.paint_cut_knots(&self, Element* elem, Painter* painter, AppState* app)
{
	if (!cut_knots_shown(app)) return;
	WalkPath* path = app.cut_picked_path();
	Matrix4f view_projection = self.world_view_projection(elem);
	float r = CUT_KNOT_SIZE * 0.5f;
	foreach (usz k, knot : path.knots)
	{
		Vec2? at = project(view_projection, knot, elem.size);
		if (catch at) continue;
		bool picked = app.cut_knot_pick == k + 1;
		painter.rect(at - (Vec2){ r, r }, { CUT_KNOT_SIZE, CUT_KNOT_SIZE }, {
			.color = picked ? CUT_KNOT_INK : (Color){ 0, 0, 0, 0.45f },
			.border_color = picked ? AIM_SELECTED : CUT_KNOT_INK, .border_width = 1.5f });
	}
}

<*
 Motion paths in the viewport: drawn over the posed rig, grabbed and dragged.

 Every path of the clip being edited is drawn as its curve; the selected one
 also shows its points (squares, filled when sharp) and its slices (rings on the
 curve, each with the frame it is reached on — a foot's DOWN and UP slices in the
 contact colour), and a dot where the joint is at the playhead.

 - Drag a **point** to reshape the curve; X/Y/Z lock the drag as for a joint.
 - Drag a **slice** to slide it along the curve: the joint is somewhere else at
   that frame. Its time is moved on the sheet.
 - **Click a curve** to select its path; **Shift-click** it to put a point there,
   **Ctrl-click** it to slice it at the playhead.
 - While **drawing** (the Path toolbar's Draw), each click adds a point at the
   depth of the joint the path is for; Enter finishes and Esc gives up.

 Picks are screen distances to the projected handles, as for joints and look-at
 targets; paths sit over the joints, so a handle on a dot is the handle.
*>
module crig;

import collision;
import cui;
import std::math;
import std::math::vector;

const Color PATH_CURVE = { 0.98, 0.62, 0.30, 0.55 };
const Color PATH_CURVE_SELECTED = { 1.00, 0.70, 0.35, 0.95 };
const Color PATH_POINT_INK = { 1.00, 0.85, 0.60, 1.00 };
const Color PATH_SLICE_INK = { 0.95, 0.95, 0.98, 0.95 };
const float PATH_CURVE_WIDTH = 2.0;
const float PATH_POINT_SIZE = 7.0;
const float PATH_SLICE_RADIUS = 4.5;
// Steps a span is drawn in.
const usz PATH_DRAW_STEPS = 12;

enum PathPick : char
{
	NONE,
	POINT,
	SLICE,
	CURVE,
}

<*
 Where `pixel` lies along path `index` on screen: the fraction, 0..1 by length,
 of the drawn curve's sample nearest the pixel. `found` is that sample's distance
 in pixels, or -1 when nothing of the curve is on screen.
*>
fn float Viewport.path_fraction_at(&self, Element* elem, AppState* app, usz index, Vec2 pixel, sz* found)
{
	*found = -1;
	AnimPath[] paths = app.shown_paths();
	if (index >= paths.len || paths[index].points.len < 2) return 0.0f;
	AnimPath* path = &paths[index];
	Matrix4f view_projection = app.model_view_projection(self.view_camera(elem), elem.size.x / elem.size.y);
	float[] lengths = path.length_table(tmem);
	float total = lengths[^1];
	if (!(total > 1.0e-9f)) return 0.0f;
	float best = 1.0e30f;
	float u = 0.0f;
	usz samples = lengths.len * 3;
	for (usz i = 0; i < samples; i++)
	{
		float f = (float)i / (float)(samples - 1);
		Vec2? at = project(view_projection, path.at_fraction(f, lengths) * app.path_height, elem.size);
		if (catch at) continue;
		float d = (at - pixel).length();
		if (d < best) { best = d; u = f; }
	}
	if (best < 1.0e29f) *found = (sz)best;
	return path.closed && u >= 1.0f ? 0.0f : u;
}

<*
 What of the paths is under `pixel`: a point or slice of the selected path (the
 nearest within `PICK_RADIUS`), else the curve of any path near it.
*>
fn PathPick Viewport.pick_path(&self, Element* elem, AppState* app, Vec2 pixel, usz* path_out, usz* handle_out)
{
	if (!app.paths_shown()) return NONE;
	AnimPath[] paths = app.shown_paths();
	Matrix4f view_projection = app.model_view_projection(self.view_camera(elem), elem.size.x / elem.size.y);
	float height = app.path_height;
	if (app.path_selected >= 0 && (usz)app.path_selected < paths.len)
	{
		AnimPath* path = &paths[(usz)app.path_selected];
		float best = PICK_RADIUS;
		PathPick kind = NONE;
		float[] lengths = path.points.len >= 2 ? path.length_table(tmem) : {};
		foreach (usz i, slice : path.slices)
		{
			Vec2? at = project(view_projection, path.at_fraction(slice.u, lengths) * height, elem.size);
			if (catch at) continue;
			float d = (at - pixel).length();
			if (d <= best) { best = d; kind = SLICE; *handle_out = i; }
		}
		foreach (usz i, point : path.points)
		{
			Vec2? at = project(view_projection, point.at * height, elem.size);
			if (catch at) continue;
			float d = (at - pixel).length();
			// A point under a slice is the point: slices can be found along the curve.
			if (d <= best || (kind == SLICE && d <= PICK_RADIUS * 0.6f)) { best = d; kind = POINT; *handle_out = i; }
		}
		if (kind != NONE)
		{
			*path_out = (usz)app.path_selected;
			return kind;
		}
	}
	// A curve is picked only with the Path tool on, so posing near a path still
	// picks the joints under it.
	if (!app.path_tool) return NONE;
	foreach (usz i, &path : paths)
	{
		sz distance;
		(void)self.path_fraction_at(elem, app, i, pixel, &distance);
		if (distance >= 0 && (float)distance <= PICK_RADIUS * 0.75f)
		{
			*path_out = i;
			return CURVE;
		}
	}
	return NONE;
}

fn void Viewport.paint_paths(&self, Element* elem, Painter* painter, Matrix4f view_projection, AppState* app)
{
	if (!app.paths_shown()) return;
	AnimPath[] paths = app.shown_paths();
	float height = app.path_height;
	AnimTemplate* clip = app.clip(app.editing);
	float duration = clip ? clip.duration : 0.0f;
	bool loop = clip ? clip.loop : false;
	foreach (usz p, &path : paths)
	{
		bool selected = app.path_selected == (sz)p;
		Color ink = selected ? PATH_CURVE_SELECTED : PATH_CURVE;
		if (path.mute) ink = ink.dim(0.4f);
		// The curve, through the length table's steps.
		if (path.points.len >= 2)
		{
			usz spans = path.span_count();
			Vec3 last = path.points[0].at * height;
			for (usz k = 0; k < spans; k++)
			{
				for (usz step = 1; step <= PATH_DRAW_STEPS; step++)
				{
					Vec3 at = path.on_span(k, (float)step / (float)PATH_DRAW_STEPS) * height;
					if (try ends = project_segment(view_projection, last, at, elem.size))
					{
						painter.line(ends[0], ends[1], selected ? PATH_CURVE_WIDTH + 0.5f : PATH_CURVE_WIDTH, ink);
					}
					last = at;
				}
			}
		}
		if (!selected) continue;
		foreach (usz i, point : path.points)
		{
			Vec2? at = project(view_projection, point.at * height, elem.size);
			if (catch at) continue;
			float r = PATH_POINT_SIZE * 0.5f;
			bool picked = app.path_point_selected == (sz)i
				|| (app.drag.verb == DragVerb.PATH && !app.drag.path_slice && app.drag.path == p && app.drag.path_handle == i);
			painter.rect(at - (Vec2){ r, r }, { PATH_POINT_SIZE, PATH_POINT_SIZE }, {
				.color = point.sharp || picked ? PATH_POINT_INK : (Color){ 0, 0, 0, 0.35f },
				.border_color = picked ? AIM_SELECTED : PATH_POINT_INK, .border_width = 1.5f });
		}
		if (path.points.len < 2) continue;
		float[] lengths = path.length_table(tmem);
		foreach (usz i, slice : path.slices)
		{
			Vec2? at = project(view_projection, path.at_fraction(slice.u, lengths) * height, elem.size);
			if (catch at) continue;
			bool picked = app.path_slice_selected == (sz)i
				|| (app.drag.verb == DragVerb.PATH && app.drag.path_slice && app.drag.path == p && app.drag.path_handle == i);
			Color ring = slice.tag != NONE ? CONTACT_RING : PATH_SLICE_INK;
			if (picked) ring = AIM_SELECTED;
			painter.circle(at, PATH_SLICE_RADIUS, { .border_color = ring, .border_width = 2.0f });
			int frame = (int)math::round(slice.time * (float)math::max(app.anim_fps, 1));
			String label = slice.tag == DOWN ? string::tformat("%d ▼", frame)
				: slice.tag == UP ? string::tformat("%d ▲", frame) : string::tformat("%d", frame);
			painter.text(at + (Vec2){ PATH_SLICE_RADIUS + 3.0f, -6.0f }, label, { .size = 11, .color = ring });
		}
		// Where the joint is on its path at the playhead.
		if (path.slices.len > 0 && duration > 0.0f)
		{
			Vec2? head = project(view_projection, path.held_at(app.onion_playhead(), duration, loop) * height, elem.size);
			if (try head) painter.circle(head, 3.0f, { .color = PATH_CURVE_SELECTED });
		}
	}
}

<*
 A press the paths take, on the Pose stage: while drawing, a point; on a handle,
 the start of a drag (`maybe_path`); on a curve, a selection, a new point
 (Shift) or a slice at the playhead (Ctrl).

 @return `Whether the press was the paths'.`
*>
fn bool Viewport.press_paths(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (app.path_drawing)
	{
		Vec3? at = self.drawing_point(elem, app, pixel);
		if (try at) app.add_drawn_point(at);
		elem.request_paint();
		return true;
	}
	usz path;
	usz handle;
	PathPick picked = self.pick_path(elem, app, pixel, &path, &handle);
	switch (picked)
	{
		case POINT:
		case SLICE:
			app.path_selected = (sz)path;
			app.path_point_selected = picked == POINT ? (sz)handle : -1;
			app.path_slice_selected = picked == SLICE ? (sz)handle : -1;
			self.maybe_path = { .pending = true, .path = path, .handle = handle, .slice = picked == SLICE };
			self.press_at = pixel;
			app.refresh_ui();
			elem.request_paint();
			return true;
		case CURVE:
			bool shift = elem.ui.input.shift_down();
			bool ctrl = elem.ui.input.ctrl_down();
			app.path_selected = (sz)path;
			app.path_point_selected = -1;
			app.path_slice_selected = -1;
			if (shift || ctrl)
			{
				sz distance;
				float u = self.path_fraction_at(elem, app, path, pixel, &distance);
				if (shift) (void)app.insert_path_point(path, u);
				if (ctrl && !shift) (void)app.add_path_slice(path, u, app.edit_time);
			}
			app.refresh_ui();
			elem.request_paint();
			return true;
		default:
			return false;
	}
}

<*
 Where a click while drawing puts a point: on the plane facing the eye through
 the path's last point, or through the joint it is for when it has none yet.
*>
fn Vec3? Viewport.drawing_point(&self, Element* elem, AppState* app, Vec2 pixel)
{
	collision::Ray ray = self.ray(elem, pixel)!;
	AnimPath[] paths = app.shown_paths();
	if (paths.len == 0) return NOT_FOUND~;
	AnimPath* path = &paths[^1];
	Vec3 anchor;
	if (path.points.len > 0)
	{
		anchor = path.points[^1].at * app.path_height;
	}
	else
	{
		Dot* found = null;
		foreach (&dot : app.doc.dots.array_view()) if (dot.name == path.joint) { found = dot; break; }
		if (!found) return NOT_FOUND~;
		anchor = app.dot_position(*found);
	}
	return ray.origin + ray.direction * (anchor - ray.origin).dot(ray.direction);
}

<*
 A held press on a handle that has travelled past `CLICK_SLOP`: the drag starts,
 from where the handle was grabbed.
*>
fn bool Viewport.move_paths(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (!self.maybe_path.pending) return false;
	if ((pixel - self.press_at).length() <= CLICK_SLOP) return true;
	PathPress press = self.maybe_path;
	self.maybe_path = {};
	if (app.begin_path_drag(press.path, press.handle, press.slice, true) && !press.slice)
	{
		if (try Vec3 at = self.pose_pointer(elem, app, self.press_at)) app.drag.grab = at - app.drag.from;
	}
	if (app.drag.dot != 0) self.drag_dot(elem, pixel);
	app.refresh_ui();
	elem.request_paint();
	return true;
}

struct PathPress
{
	bool pending;
	usz path;
	usz handle;
	bool slice;
}

<*
 The other loaded characters in the viewport: their skeletons drawn faintly
 under the one being edited, and a click on one of them making it the one.

 Nothing here edits a waiting character. Its joints are drawn so it can be read
 against — the pose being copied, the partner in a cutscene — and picked so it
 can be switched to; the moment it is clicked it becomes the focus and every
 tool works on it the ordinary way.
*>
module crig;

import cui;
import cui::widgets;
import rig;
import std::math;

// How strongly a waiting character's skeleton is drawn: present enough to copy a
// pose from, faint enough that its joints are never mistaken for the focus's.
const float CAST_OVERLAY_OPACITY = 0.35f;

<*
 Each waiting, visible character's bones and joints, at its own pose and in its
 own place. Under the focus's overlay, like the ghosts.
*>
fn void Viewport.paint_cast(&self, Element* elem, Painter* painter, OrbitCamera* camera)
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.character_count() < 2) return;
	float aspect = elem.size.x / elem.size.y;

	for (usz i = 0; i < app.character_count(); i++)
	{
		if (i == app.active) continue;
		Character* c = app.character(i);
		if (c.hidden || c.doc.dots.len() == 0) continue;
		Matrix4f view_projection = c.model_view_projection(camera, aspect);

		foreach (edge : c.doc.edges.array_view())
		{
			Dot* a = c.doc.find(edge.a);
			Dot* b = c.doc.find(edge.b);
			if (!a || !b) continue;
			Vec2? from = project(view_projection, c.dot_position(*a), elem.size);
			Vec2? to = project(view_projection, c.dot_position(*b), elem.size);
			if (catch from) continue;
			if (catch to) continue;
			painter.line(from, to, BONE_WIDTH * 0.5f, rig_overlay_ink(BONE, CAST_OVERLAY_OPACITY));
		}
		foreach (dot : c.doc.dots.array_view())
		{
			Vec2? at = project(view_projection, c.dot_position(dot), elem.size);
			if (catch at) continue;
			painter.circle(at, DOT_RADIUS * 0.5f, {
				.color = rig_overlay_ink(DOT, CAST_OVERLAY_OPACITY),
				.border_width = DOT_BORDER * 0.5f,
				.border_color = rig_overlay_ink(DOT_OUTLINE, CAST_OVERLAY_OPACITY),
			});
		}
	}
}

<*
 Make the character under a pixel the focus: one of its joints, or else its body
 where that body is nearer than the focus's own.

 Asked only once the focus's own joints have missed, so a joint of the character
 being edited always wins a click that lands on both.

 @param pixel : `Viewport-local pixels.`
 @return `Whether the click was about another character, and the focus moved to it.`
*>
fn bool Viewport.pick_cast(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.character_count() < 2) return false;
	OrbitCamera* camera = self.view_camera(elem);
	float aspect = elem.size.x / elem.size.y;

	// A joint first: it is what a click on the skeleton is aimed at.
	if (app.show_rig)
	{
		sz best = -1;
		uint best_dot;
		float best_distance = PICK_RADIUS;
		for (usz i = 0; i < app.character_count(); i++)
		{
			if (i == app.active) continue;
			Character* c = app.character(i);
			if (c.hidden) continue;
			Matrix4f view_projection = c.model_view_projection(camera, aspect);
			foreach (dot : c.doc.dots.array_view())
			{
				Vec2? at = project(view_projection, c.dot_position(dot), elem.size);
				if (catch at) continue;
				float distance = (at - pixel).length();
				if (distance <= best_distance)
				{
					best_distance = distance;
					best = (sz)i;
					best_dot = dot.id;
				}
			}
		}
		if (best >= 0)
		{
			app.focus_character((usz)best);
			app.select(best_dot);
			return true;
		}
	}

	// Then a body, the nearest along the ray; the focus's own keeps the click.
	sz chosen = self.character_at(elem, pixel);
	if (chosen < 0 || (usz)chosen == app.active) return false;
	app.focus_character((usz)chosen);
	return true;
}

<*
 The nearest visible character under a pixel, the focus included, or -1. One with
 no mesh is its bones; in a cutscene every actor's bones count, and outside one the
 focus is its mesh alone, so a click beside its joints still places one.

 @param pixel : `Viewport-local pixels.`
*>
fn sz Viewport.character_at(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	OrbitCamera* camera = self.view_camera(elem);
	Vec3? direction = camera.ray_direction(pixel, elem.size);
	if (catch direction) return -1;
	bool cutscene = app.cutscene_in_dock();
	sz chosen = -1;
	float nearest = float::max;
	for (usz i = 0; i < app.character_count(); i++)
	{
		Character* c = app.character(i);
		if (c.hidden) continue;
		bool bones = cutscene || (i != app.active && !c.has_mesh());
		// World distances, so characters of different sizes compare.
		float? hit = c.body_hit(camera, direction, bones);
		if (catch hit) continue;
		if (hit < nearest)
		{
			nearest = hit;
			chosen = (sz)i;
		}
	}
	return chosen;
}

<*
 Sketching: the person draws on the viewport to show the agent what is wrong.

 	`app.begin_sketch();`  then drag over the model; each stroke is one mark.

 The tool has no keys: it is the tool column's Sketch cell, and the strip across
 the top of the viewport picks the ink or the eraser.

 A mark keeps what makes it readable later: its points as fractions of the
 viewport (so it survives a resize), the camera it was drawn from, the clip and
 time on screen, and the joints the stroke passes near — "the left knee at
 0.4 s" rather than only pixels. The colour carries the meaning: red is wrong,
 green is keep, blue is a note. The marks are painted over the viewport, so a
 screenshot shows them, and `get_annotations` reads them as data.

 Marks live in the session; saving them with the project is a later step.
*>
module crig;

import std::collections::list;
import std::math;

enum SketchInk : int
{
	RED,
	GREEN,
	BLUE,
}

fn String SketchInk.label(self)
{
	switch (self)
	{
		case RED: return "red";
		case GREEN: return "green";
		case BLUE: return "blue";
	}
}

// How close, in pixels, a joint's dot has to be to a stroke for it to count as
// under the mark.
const float SKETCH_NEAR = 28.0f;
const usz SKETCH_JOINTS_MOST = 8;
// How close, in pixels, the eraser has to pass to a mark to take it off.
const float SKETCH_ERASE_NEAR = 10.0f;

struct Annotation
{
	uint id;
	SketchInk ink;
	// Fractions of the viewport, 0 to 1 from the top left.
	Vec2[] points;
	// The clip and moment on screen, empty when none was.
	String clip;
	float time;
	// The camera it was drawn from.
	Vec3 target;
	float distance;
	float yaw;
	float pitch;
	// Named joints the stroke passes near, nearest first.
	String[] joints;
}

alias AnnotationList = List{Annotation};

fn void Annotation.free(&self)
{
	if (self.points.len > 0) alloc::free(mem, self.points);
	self.clip.free(mem);
	foreach (joint : self.joints) joint.free(mem);
	if (self.joints.len > 0) alloc::free(mem, self.joints);
	*self = {};
}

fn void AppState.free_annotations(&self)
{
	foreach (&mark : self.annotations.array_view()) mark.free();
	self.annotations.free();
	self.sketch_points.free();
}

fn void AppState.begin_sketch(&self)
{
	self.end_brush();
	self.end_lasso();
	self.end_area();
	self.sketching = true;
	self.sketch_active = false;
	self.sketch_points.clear();
}

fn void AppState.end_sketch(&self)
{
	self.sketching = false;
	self.sketch_active = false;
	self.sketch_points.clear();
}

fn void AppState.pick_sketch_ink(&self, SketchInk ink)
{
	self.sketch_ink = ink;
	self.sketch_erasing = false;
}

fn bool AppState.sketch_moved(&self, Vec2 at)
{
	sz held = self.sketch_points.len();
	if (held > 0 && (self.sketch_points[held - 1] - at).length() < LASSO_STEP) return false;
	// A zeroed List would grow from temp memory; see undo_heap_test.c3.
	if (!self.sketch_points.is_initialized()) self.sketch_points.init(mem);
	self.sketch_points.push(at);
	return true;
}

<*
 Turn the stroke in flight into a mark.

 @param viewport : `Size of the region the stroke was drawn in, in pixels.`
 @return `The mark's id, or 0 when the stroke was too short to be one.`
*>
fn uint AppState.sketch_commit(&self, Matrix4f view_projection, Vec2 viewport, OrbitCamera* camera)
{
	Vec2[] stroke = self.sketch_points.array_view();
	if (stroke.len < 2 || viewport.x <= 0 || viewport.y <= 0)
	{
		self.sketch_points.clear();
		return 0;
	}

	Annotation mark = {
		.id = ++self.annotation_serial,
		.ink = self.sketch_ink,
		.points = alloc::new_array(mem, Vec2, (sz)stroke.len),
		.target = camera.target,
		.distance = camera.distance,
		.yaw = camera.yaw,
		.pitch = camera.pitch,
	};
	foreach (i, point : stroke) mark.points[i] = { point.x / viewport.x, point.y / viewport.y };
	if (AnimTemplate* clip = self.clip(self.editing))
	{
		mark.clip = clip.name.copy(mem);
		mark.time = self.edit_time;
	}

	// Joints near the stroke, closest first.
	String[SKETCH_JOINTS_MOST] names;
	float[SKETCH_JOINTS_MOST] gaps;
	usz found;
	foreach (dot : self.doc.dots.array_view())
	{
		if (dot.name.len == 0) continue;
		Vec2? at = project(view_projection, self.dot_position(dot), viewport);
		if (catch at) continue;
		float gap = 1.0e30f;
		foreach (point : stroke) gap = math::min(gap, (point - at).length());
		if (gap > SKETCH_NEAR) continue;
		usz slot = found;
		while (slot > 0 && gaps[slot - 1] > gap) slot--;
		if (slot >= SKETCH_JOINTS_MOST) continue;
		usz last = math::min(found, SKETCH_JOINTS_MOST - 1);
		for (usz k = last; k > slot; k--)
		{
			names[k] = names[k - 1];
			gaps[k] = gaps[k - 1];
		}
		names[slot] = dot.name;
		gaps[slot] = gap;
		found = math::min(found + 1, SKETCH_JOINTS_MOST);
	}
	if (found > 0)
	{
		mark.joints = alloc::new_array(mem, String, (sz)found);
		foreach (i, name : names[:found]) mark.joints[i] = name.copy(mem);
	}

	if (!self.annotations.is_initialized()) self.annotations.init(mem);
	self.annotations.push(mark);
	self.sketch_points.clear();
	return mark.id;
}

<*
 The eraser moved from `from` to `to`: every mark whose stroke comes within
 SKETCH_ERASE_NEAR of that path goes. The path, not only its ends, so a fast
 drag cannot jump over a mark. Marks are stored as fractions of the viewport,
 so they are measured in the pixels of the one they are erased from.

 @param viewport : `Size of the viewport the eraser is over, in pixels.`
 @return `How many marks went.`
*>
fn usz AppState.erase_annotations_along(&self, Vec2 from, Vec2 to, Vec2 viewport)
{
	usz steps = (usz)((to - from).length() / (SKETCH_ERASE_NEAR * 0.5f)) + 1;
	usz gone;
	for (sz i = self.annotations.len() - 1; i >= 0; i--)
	{
		Annotation* mark = &self.annotations[i];
		bool near;
		for (usz s = 0; s <= steps && !near; s++)
		{
			Vec2 at = from + (to - from) * ((float)s / (float)steps);
			for (usz k = 0; k < mark.points.len && !near; k++)
			{
				Vec2 a = mark.points[k] * viewport;
				Vec2 b = k + 1 < mark.points.len ? mark.points[k + 1] * viewport : a;
				near = point_segment_distance(at, a, b) <= SKETCH_ERASE_NEAR;
			}
		}
		if (!near) continue;
		mark.free();
		self.annotations.remove_at(i);
		gone++;
	}
	return gone;
}

fn bool AppState.delete_annotation(&self, uint id)
{
	foreach (i, &mark : self.annotations.array_view())
	{
		if (mark.id != id) continue;
		mark.free();
		self.annotations.remove_at(i);
		return true;
	}
	return false;
}

fn usz AppState.clear_annotations(&self)
{
	usz count = (usz)self.annotations.len();
	foreach (&mark : self.annotations.array_view()) mark.free();
	self.annotations.clear();
	return count;
}

fn bool AppState.delete_last_annotation(&self)
{
	usz count = (usz)self.annotations.len();
	if (count == 0) return false;
	return self.delete_annotation(self.annotations[(sz)count - 1].id);
}

<*
 The viewport camera.

 An eye on a sphere around a target: yaw and pitch place it, distance is the
 zoom, and panning moves the target. That is the right model for inspecting one
 object — whatever the user does, the thing being rigged stays in frame, which a
 free-fly camera cannot promise. B4 raycasts through this camera to place dots,
 so it is also the thing that has to agree with the mouse.

 Angles are degrees, matching `cui::camera`; radians appear only where the math
 needs them.
*>
module crig;

import std::math;
import rig;

<*
 Straight up is a singularity for a Y-up orbit: the view axis becomes parallel
 to the up vector and `look_at`'s cross product collapses to zero.
*>
const float MAX_PITCH = 89.0;

const float ORBIT_DEGREES_PER_PIXEL = 0.35;

// Multiplicative, so one notch is the same visual step whether the camera is
// close in on a hoof or backed off the whole animal.
//
// Calibrated so about ten notches halve the distance. A step big enough to
// cross the model in three or four notches is the wrong trade for this tool:
// dots are placed by eye at the scale of a knuckle, and the framing that shows
// one has to be arrived at rather than jumped over. `FINE_ZOOM_RATIO` is the
// step below this, for when even that overshoots.
const float DOLLY_PER_NOTCH = 0.93;

// How long an axis snap takes. Long enough to read as a turn rather than a cut
// — which is the whole point, since a cut leaves the user re-finding which way
// the model is now facing — and short enough not to be a wait.
const float SNAP_SECONDS = 0.25;

struct OrbitCamera
{
	Vec3 target;
	float distance;
	float yaw;          // degrees about +Y; 0 puts the eye on +Z
	float pitch;        // degrees above the horizon, clamped to ±MAX_PITCH
	float fov;          // vertical field of view, degrees
	float near_plane;
	float far_plane;
	float min_distance;
	float max_distance;

	// Axis snap, in flight. Angles are absolute rather than deltas so the eased
	// value is computed from the endpoints every frame — accumulating a
	// per-frame step would drift and never land exactly on the axis.
	bool snapping;
	float snap_elapsed;
	float snap_from_yaw, snap_from_pitch;
	float snap_to_yaw, snap_to_pitch;
}

<*
 Aim at a mesh and back off until all of it is in frame.

 The clip planes come from the same radius rather than being constants. A fixed
 0.1/500 pair z-fights on a 0.8-unit goat and clips a 200-unit scan, and crig
 takes whatever the user drags in.

 @param box : `Bounds of the mesh to frame.`
 @param fov : `Vertical field of view, degrees.`
*>
fn OrbitCamera framed(rig::Bounds box, float fov = 45.0)
{
	Vec3 center = box.center();
	float radius = box.extent().length() * 0.5f;
	if (radius <= 0.0f) radius = 1.0f;

	// Fit the bounding sphere vertically, with a margin so the model does not
	// touch the window edge.
	float distance = radius / math::tan(math::deg_to_rad(fov) * 0.5f) * 1.15f;

	return {
		.target = center,
		.distance = distance,
		// A three-quarter view. Face-on hides the depth the user is about to
		// place dots in, and a side view hides the limbs on the far side.
		.yaw = 40.0,
		.pitch = 18.0,
		.fov = fov,
		.near_plane = radius * 0.01f,
		.far_plane = distance + radius * 100.0f,
		.min_distance = radius * 0.05f,
		.max_distance = radius * 40.0f,
	};
}

fn Vec3 OrbitCamera.eye(&self)
{
	float yaw = math::deg_to_rad(self.yaw);
	float pitch = math::deg_to_rad(self.pitch);
	float horizontal = math::cos(pitch);

	return self.target + (Vec3){
		horizontal * math::sin(yaw),
		math::sin(pitch),
		horizontal * math::cos(yaw),
	} * self.distance;
}

fn Matrix4f OrbitCamera.view(&self)
{
	return matrix::look_at{float}(self.eye(), self.target, { 0.0, 1.0, 0.0 });
}

<*
 `std::math::matrix` builds a right-handed, [0,1]-depth projection with +Y up —
 glm's convention. Vulkan's NDC has +Y down, and cui binds a positive-height
 viewport rather than the negative-height trick, so the projection has to flip Y
 or the model renders upside down under an interface that is the right way up.

 cui itself needs no flip because its canvas coordinates are already Y-down, so
 this belongs here rather than in `cui::camera`.
*>
fn Matrix4f OrbitCamera.projection(&self, float aspect)
{
	Matrix4f projection = matrix::perspective{float}(
		math::deg_to_rad(self.fov), aspect, self.near_plane, self.far_plane);
	projection.m11 = -projection.m11;
	return projection;
}

fn Matrix4f OrbitCamera.view_projection(&self, float aspect)
{
	Matrix4f projection = self.projection(aspect);
	Matrix4f view = self.view();
	return projection * view;
}

<*
 Turntable orbit. The model follows the cursor, so the camera goes the other
 way: dragging right spins the near side of the model right, which means the eye
 swings left.

 @param pixels : `Mouse movement this frame, UI pixels (y down).`
*>
fn void OrbitCamera.orbit(&self, Vec2 pixels)
{
	// A drag is the user taking the camera back. Letting the snap finish
	// underneath them would fight the mouse for the rest of its quarter second.
	self.snapping = false;

	self.yaw -= pixels.x * ORBIT_DEGREES_PER_PIXEL;
	self.pitch += pixels.y * ORBIT_DEGREES_PER_PIXEL;
	self.pitch = math::clamp(self.pitch, -MAX_PITCH, MAX_PITCH);
}

<*
 Slide the target across the view plane, so the model keeps pace with the cursor.

 @param pixels : `Mouse movement this frame, UI pixels (y down).`
 @param viewport_height : `Height of the region the camera renders into, in the same units as pixels.`
*>
fn void OrbitCamera.pan(&self, Vec2 pixels, float viewport_height)
{
	if (viewport_height <= 0.0f) return;

	// World units per pixel at the target's depth. Without the distance term a
	// pan tuned while zoomed out throws the model off screen while zoomed in.
	float units_per_pixel =
		2.0f * self.distance * math::tan(math::deg_to_rad(self.fov) * 0.5f) / viewport_height;

	Vec3 forward = (self.target - self.eye()).normalize();
	Vec3 right = forward.cross({ 0.0, 1.0, 0.0 }).normalize();
	Vec3 up = right.cross(forward);

	self.target = self.target
		- right * (pixels.x * units_per_pixel)
		+ up * (pixels.y * units_per_pixel);
}

<*
 @param notches : `Wheel delta; positive moves closer.`
*>
fn void OrbitCamera.dolly(&self, float notches)
{
	self.distance = math::clamp(
		self.distance * math::pow(DOLLY_PER_NOTCH, notches),
		self.min_distance,
		self.max_distance);
}

// ---------------------------------------------------------------------------
// Orthogonal views
//
// The six directions the view gizmo offers and the numpad shortcuts reach. This
// lives on the camera rather than inside the gizmo widget so both paths run the
// identical operation, and so the angles are testable with no window.

<*
 One of the six axis-aligned viewing directions, as the eye's offset from the
 target.

 `label` is what the gizmo prints on the ball, and it is empty on the negative
 half — which is also what makes those balls draw hollow. The two are the same
 decision ("is this the named end of the axis"), so they are one field.

 Top and bottom stop at `MAX_PITCH` rather than a true 90°: straight up
 collapses `look_at`'s cross product, and the yaw an orbit would continue from
 there is undefined. One degree off vertical is invisible; the singularity is
 not.

 The yaw for top and bottom is fixed at 0 rather than kept from wherever the
 camera was. Keeping it would turn less, but then "top" is not one view — the
 same ball clicked from two orbits would give two different pictures, and a
 canonical view you can get back to is the entire point of the control.
*>
enum ViewAxis : (Vec3 direction, String label, String view_name, float yaw, float pitch)
{
	POS_X { { 1.0, 0.0, 0.0 },  "X", "Right",  90.0,  0.0 },
	POS_Y { { 0.0, 1.0, 0.0 },  "Y", "Top",    0.0,   MAX_PITCH },
	POS_Z { { 0.0, 0.0, 1.0 },  "Z", "Front",  0.0,   0.0 },
	NEG_X { { -1.0, 0.0, 0.0 }, "", "Left",   -90.0,  0.0 },
	NEG_Y { { 0.0, -1.0, 0.0 }, "", "Bottom",  0.0,  -MAX_PITCH },
	NEG_Z { { 0.0, 0.0, -1.0 }, "", "Back",    180.0, 0.0 },
}

<*
 Start easing the camera around to look down `axis`.

 Only yaw and pitch move: distance and target are the user's framing, and a
 snap that also re-framed would undo every pan and zoom they had made.
*>
fn void OrbitCamera.snap_to(&self, ViewAxis axis)
{
	self.snapping = true;
	self.snap_elapsed = 0.0f;
	self.snap_from_yaw = self.yaw;
	self.snap_from_pitch = self.pitch;
	self.snap_to_pitch = axis.pitch;

	// The short way round. Yaw is an angle, so 350° and -10° are the same
	// camera, but interpolating from 350 to 0 the long way spins the model
	// almost the whole way about — visibly wrong, and for a quarter of a second
	// the user cannot tell what happened. Fold the difference into (-180, 180]
	// and add it to where we actually are, so the target may be 710° or -370°
	// and the eased path is still the short arc.
	float turn = axis.yaw - self.yaw;
	turn -= 360.0f * math::floor(turn / 360.0f + 0.5f);
	self.snap_to_yaw = self.yaw + turn;
}

<*
 Advance a running snap. Ticked from `AppRoot.update`, which cui calls every
 frame with the frame's dt.

 @param dt : `Seconds since the last frame.`
 @return `True if the camera moved, i.e. the view needs repainting.`
*>
fn bool OrbitCamera.advance(&self, float dt)
{
	if (!self.snapping) return false;

	self.snap_elapsed += dt;
	float t = SNAP_SECONDS > 0.0f ? self.snap_elapsed / SNAP_SECONDS : 1.0f;
	if (t >= 1.0f)
	{
		t = 1.0f;
		self.snapping = false;
	}

	// Smoothstep: zero velocity at both ends, so the turn starts and stops
	// without the jerk a linear ramp gives at this duration.
	float eased = t * t * (3.0f - 2.0f * t);
	self.yaw = self.snap_from_yaw + (self.snap_to_yaw - self.snap_from_yaw) * eased;
	self.pitch = self.snap_from_pitch + (self.snap_to_pitch - self.snap_from_pitch) * eased;
	return true;
}

<*
 The name of the axis view the camera is looking down — "Front", "Top" and so
 on — or "User" once an orbit has taken it off every axis. What a status
 overlay prints, the way Blender's viewport corner does.

 A snap in flight reports its destination rather than the angles mid-turn: the
 user just asked for that view by name, and a quarter second of "User" while
 the ease runs would look like the key not working.

 @return `A static name; never allocated.`
*>
fn String OrbitCamera.view_name(&self)
{
	float yaw = self.snapping ? self.snap_to_yaw : self.yaw;
	float pitch = self.snapping ? self.snap_to_pitch : self.pitch;

	foreach (axis : ViewAxis::values)
	{
		// Same (-180, 180] fold as snap_to: yaw is an angle, and a camera parked
		// at 360° is looking down the 0° axis.
		float turn = axis.yaw - yaw;
		turn -= 360.0f * math::floor(turn / 360.0f + 0.5f);
		if (math::abs(turn) < 0.5f && math::abs(axis.pitch - pitch) < 0.5f) return axis.view_name;
	}
	return "User";
}

<*
 A world direction rotated into view space.

 Not `project()`, on purpose: the gizmo's balls have no world position, only a
 direction, so there is no w to divide by and nothing to put behind the camera.
 This is the view rotation alone — the upper 3×3 of `view()`, whose rows are the
 camera's right, up and backward vectors.

 Because it skips `projection()` it also skips the Vulkan Y flip that lives
 there, so a caller drawing into cui's Y-down canvas has to negate y itself.
 That is one negation per path rather than one overall, which is the only way
 the two paths can each be checked on their own.

 @param world : `A direction in model space; need not be normalized.`
 @return `View space: +x right, +y up, +z toward the viewer.`
*>
fn Vec3 OrbitCamera.view_direction(&self, Vec3 world)
{
	Matrix4f view = self.view();
	return {
		view.m00 * world.x + view.m01 * world.y + view.m02 * world.z,
		view.m10 * world.x + view.m11 * world.y + view.m12 * world.z,
		view.m20 * world.x + view.m21 * world.y + view.m22 * world.z,
	};
}

// ---------------------------------------------------------------------------
// Screen <-> world
//
// The overlay projects joints down to pixels and picking turns a pixel back
// into a ray, and the two have to be exact inverses: a disagreement of a few
// pixels means a dot lands somewhere other than where it was clicked, and the
// user has no way to tell which half is lying. Both go through
// `view_projection`, so there is one convention rather than two.
//
// `viewport` is the region the mesh renders into — not the window. The control
// panel takes a slice off the right, and a projection that forgets it puts
// every dot progressively further off as x grows.

faultdef BEHIND_CAMERA, DEGENERATE_VIEW;

<*
 Where a world point lands on screen.

 Takes the matrix rather than the camera because every caller projects a whole
 rig against one camera — the overlay does each dot and each edge endpoint per
 paint, and rebuilding `view_projection` inside the loop would be the only
 place the two directions could drift apart.

 @param view_projection : `From OrbitCamera.view_projection, built for this viewport's aspect.`
 @param world : `The point, in model space.`
 @param viewport : `Size of the region the camera renders into, in pixels.`
 @return `Pixels from the viewport's top-left, y down.`
*>
fn Vec2? project(Matrix4f view_projection, Vec3 world, Vec2 viewport)
{
	Vec4 clip = view_projection.apply({ world[0], world[1], world[2], 1.0 });

	// w is how far the point sits in front of the eye, so this rejects
	// everything at or behind the eye plane. Those points have no image, and
	// dividing by a negative w would mirror them onto the visible half of the
	// screen — a joint behind the camera drawn as if it were in front.
	if (clip.w <= 0.0f) return BEHIND_CAMERA~;

	// No y flip: `projection` already negated m11 for Vulkan, so NDC +y points
	// down, and cui's canvas origin is the top-left. Flipping here would undo
	// the one in the matrix and leave the overlay mirrored against the mesh it
	// is drawn over.
	return to_pixels(clip, viewport);
}

<*
 How far in front of the eye a clipped end is left, as a share of the depth of
 the end that was visible.

 The line wants to run to the eye plane, and a point exactly on it has no image
 at all — `x / w` with `w` at zero. Stopping a little short gives a finite pixel,
 and tying that little to the visible end's own depth is what keeps it finite by
 a known factor: fifty times further out than the part being looked at, which is
 far off screen for any viewport and nowhere near the range where a coordinate
 stops being a number.
*>
const float NEAR_SLIVER = 0.02;

<*
 Where a world-space segment lands on screen, with any part behind the eye cut
 off rather than the whole line thrown away.

 	`if (try Vec2[2] line = project_segment(view_projection, a, b, size))`

 **Projecting the two ends separately is not enough**, and the failure is the
 kind that looks like a missing feature rather than a bug: a guide drawn a body's
 length either way from a joint has one end behind the eye the moment the camera
 comes in close, `project` rightly refuses that end, and the caller — having
 nothing to draw a line between — draws nothing. The line does cross the whole
 screen; it is only its far end that is behind you.

 Clipping happens in clip space, before the divide, because the projection is
 linear in the point: a point partway along the segment in world space is the
 same point partway along it in clip space, so one lerp of two `Vec4`s does what
 walking the world-space segment would.

 @return `Both ends in pixels from the viewport's top-left, y down.`
 @return? BEHIND_CAMERA : `The whole segment is at or behind the eye plane, and has no image.`
*>
fn Vec2[2]? project_segment(Matrix4f view_projection, Vec3 from, Vec3 to, Vec2 viewport)
{
	Vec4 near = view_projection.apply({ from[0], from[1], from[2], 1.0 });
	Vec4 far = view_projection.apply({ to[0], to[1], to[2], 1.0 });

	if (near.w <= 0.0f && far.w <= 0.0f) return BEHIND_CAMERA~;

	// One end at a time, and never both: the test above has already established
	// that at least one of them is in front.
	if (near.w <= 0.0f) near = pulled_in_front(near, far);
	if (far.w <= 0.0f) far = pulled_in_front(far, near);

	return (Vec2[2]){ to_pixels(near, viewport), to_pixels(far, viewport) };
}

// The point along `behind` -> `ahead` that sits a sliver in front of the eye.
// Solving for the depth wanted rather than for the crossing itself keeps the
// answer away from the zero that has no image — see `NEAR_SLIVER`.
fn Vec4 pulled_in_front(Vec4 behind, Vec4 ahead) @local
{
	float wanted = ahead.w * NEAR_SLIVER;
	float span = ahead.w - behind.w;
	float t = span != 0.0f ? (wanted - behind.w) / span : 1.0f;
	return behind + (ahead - behind) * math::clamp(t, 0.0f, 1.0f);
}

// The divide and the viewport map, shared so `project` and `project_segment`
// cannot disagree about where a clip-space point lands.
fn Vec2 to_pixels(Vec4 clip, Vec2 viewport) @local
{
	Vec2 ndc = { clip.x / clip.w, clip.y / clip.w };
	return { (ndc.x * 0.5f + 0.5f) * viewport.x, (ndc.y * 0.5f + 0.5f) * viewport.y };
}

<*
 The world-space direction the given pixel looks along, from `eye()`.

 The pixel is unprojected on the near plane rather than the far one. Both give
 the same line in exact arithmetic, but a fixed error in NDC z is worth far
 fewer world units close in, and the eye is already known exactly — so the near
 point is the better second point to aim through.

 @param pixel : `Pixels from the viewport's top-left, y down.`
 @param viewport : `Size of the region the camera renders into, in pixels.`
 @return `A unit vector; combine with eye() to get the ray.`
*>
fn Vec3? OrbitCamera.ray_direction(&self, Vec2 pixel, Vec2 viewport)
{
	Matrix4f view_projection = self.view_projection(viewport.x / viewport.y);
	Matrix4f to_world = view_projection.inverse()!;

	Vec2 ndc = {
		pixel.x / viewport.x * 2.0f - 1.0f,
		pixel.y / viewport.y * 2.0f - 1.0f,
	};

	Vec4 near = to_world.apply({ ndc.x, ndc.y, 0.0, 1.0 });
	if (near.w == 0.0f) return DEGENERATE_VIEW~;

	Vec3 direction = (Vec3){ near.x / near.w, near.y / near.w, near.z / near.w } - self.eye();
	float length = direction.length();
	if (length <= 0.0f) return DEGENERATE_VIEW~;
	return direction * (1.0f / length);
}

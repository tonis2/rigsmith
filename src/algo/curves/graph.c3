<* The pure half of src/app/graph.c3: no state, undo or notices. *>
module crig;

import std::math;
import std::math::vector;
import std::math::quaternion;
import std::sort;
import std::collections::list;

// Evenly spaced samples per curve over the whole clip, plus one at every key.
const usz GRAPH_SAMPLES = 240;

struct GraphCurve
{
	String joint; // owned
	bool rotation;
	int axis; // 0 = X, 1 = Y, 2 = Z
	bool primary; // the joint selected last; others are drawn fainter
	Vec2[] samples; // owned; (seconds, real value)
	// The curve's display range when the graph is `mixed`: shown = (real - mid) / half,
	// so it spans -1..1. Zero `half` is the identity.
	float mid;
	float half;
}

// A curve's value as the plot draws it, and back.
fn float GraphCurve.shown(self, float real) => self.half > 0.0f ? (real - self.mid) / self.half : real;

fn float GraphCurve.real(self, float shown) => self.half > 0.0f ? shown * self.half + self.mid : shown;

// One rotation or position channel of a selected joint that has keys, whether
// or not its curves are drawn: a row of the channel list.
struct GraphChannel
{
	String joint; // owned
	uint id; // the joint's dot
	bool rotation;
	bool primary;
}

// One curve that is hidden: an axis of a joint's rotation or position.
struct GraphSlot
{
	uint joint;
	bool rotation;
	int axis;
}

// What a click on the channel list names: `joint` 0 is every joint, `kind` -1 both
// channels (0 rotation, 1 position), `axis` -1 all three.
struct GraphPick
{
	uint joint;
	int kind;
	int axis;
}

enum GraphPickMode : int
{
	SOLO, // only what is named is drawn
	ADD, // what is named is drawn too
	TOGGLE, // what is named is hidden if all of it is drawn, else drawn
}

// The part of a joint's rows that folds: the joint, its rotation, its position.
struct GraphFold
{
	uint joint;
	int part; // 0 joint, 1 rotation, 2 position
}

fn bool GraphPick.covers(&self, uint joint, bool rotation, int axis)
{
	return (self.joint == 0 || self.joint == joint)
		&& (self.kind < 0 || (self.kind == 0) == rotation)
		&& (self.axis < 0 || self.axis == axis);
}

struct GraphKey
{
	usz curve;
	float time;
	float value;
	Vec3 shown; // the key's three displayed components, which an edit keeps
	bool selected;
}

struct GraphHandle
{
	usz key; // the `GraphKey` it hangs off: names the curve, joint and time
	bool incoming; // the end of the segment before the key, else the one after
	float length; // seconds from the key: a third of its segment, fixed
	Vec2 at; // (seconds, real value)
}

struct Graph
{
	GraphCurve[] curves; // the drawn ones only
	GraphKey[] keys;
	GraphHandle[] handles;
	GraphChannel[] channels; // every channel of the selected joints, drawn or not
	float unit; // model units per stored move (rig height)
	// Rotation and position curves are both drawn: each one is shown normalised.
	bool mixed;
	// A generator layer is active: it holds no keys, so there is nothing to draw
	// or drag. The sheet says "procedural layer — edit its parameters".
	bool procedural;
}

fn void Graph.free(&self)
{
	foreach (curve : self.curves)
	{
		curve.joint.free(mem);
		if (curve.samples.len > 0) alloc::free(mem, curve.samples);
	}
	foreach (channel : self.channels) channel.joint.free(mem);
	if (self.curves.len > 0) alloc::free(mem, self.curves);
	if (self.keys.len > 0) alloc::free(mem, self.keys);
	if (self.handles.len > 0) alloc::free(mem, self.handles);
	if (self.channels.len > 0) alloc::free(mem, self.channels);
	*self = {};
}

fn float wrap_near(float angle, float near) @local
{
	float turn = 2.0f * (float)math::PI;
	return angle + turn * math::round((near - angle) / turn);
}

<*
 A turn as XYZ Euler degrees (R = Rz · Ry · Rx), the solution nearest `near`.
*>
fn Vec3 euler_of(Quaternionf q, Vec3 near)
{
	Vec3 c0 = q.rotate_vec3({ 1, 0, 0 });
	Vec3 c1 = q.rotate_vec3({ 0, 1, 0 });
	Vec3 c2 = q.rotate_vec3({ 0, 0, 1 });
	Vec3 n = near * (float)(math::PI / 180.0);
	float sy = math::clamp(-c0.z, -1.0f, 1.0f);
	Vec3 best;
	if (math::abs(sy) > 0.99999f)
	{
		float y = sy > 0 ? (float)math::PI * 0.5f : -(float)math::PI * 0.5f;
		float x = n.x;
		float z = sy > 0 ? x - math::atan2(c1.x, c1.y) : math::atan2(-c1.x, c1.y) - x;
		best = { x, wrap_near(y, n.y), wrap_near(z, n.z) };
	}
	else
	{
		float y = math::asin(sy);
		float x = math::atan2(c1.z, c2.z);
		float z = math::atan2(c0.y, c0.x);
		Vec3 a = { wrap_near(x, n.x), wrap_near(y, n.y), wrap_near(z, n.z) };
		float pi = (float)math::PI;
		Vec3 b = { wrap_near(x + pi, n.x), wrap_near(pi - y, n.y), wrap_near(z + pi, n.z) };
		best = (a - n).length_sq() <= (b - n).length_sq() ? a : b;
	}
	return best * (float)(180.0 / math::PI);
}

fn Quaternionf quat_of_euler(Vec3 degrees)
{
	Vec3 r = degrees * (float)(math::PI / 180.0);
	Quaternionf qx = quaternion::from_axis_angle{float}({ 1, 0, 0 }, r.x);
	Quaternionf qy = quaternion::from_axis_angle{float}({ 0, 1, 0 }, r.y);
	Quaternionf qz = quaternion::from_axis_angle{float}({ 0, 0, 1 }, r.z);
	return qz.mul(qy).mul(qx).normalize();
}

// The channel's value at `time`, in display units, nearest `near`.
fn Vec3 graph_value(AnimTemplate* clip, String joint, bool rotation, float time, Vec3 near,
	float unit, bool eased = true)
{
	if (rotation) return euler_of(clip.rotation_at(joint, time, eased: eased), near);
	return clip.translation_at(joint, time, eased: eased) * unit;
}

fn int by_float(float a, float b) => a < b ? -1 : (a > b ? 1 : 0);

// The entry keying this joint's channel in `frame`, or null.
fn AnimKeyDot* channel_entry(AnimKeyframe* frame, String joint, bool rotation) @private
{
	foreach (&dot : frame.dots)
	{
		if (dot.joint_name != joint) continue;
		if (rotation ? dot.keys_rotation() : dot.keys_translation()) return dot;
	}
	return null;
}

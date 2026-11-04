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

alias GraphAxisHidden = fn bool(void* ctx, uint id, bool rotation, int axis);
alias GraphKeySelected = fn bool(void* ctx, float at, String name, AnimChannels channel);

<*
 What a plot draws: the joints, and how to ask which axes and keys are on.
*>
struct GraphAsk
{
	AnimTemplate* clip;
	String[] names;
	uint[] ids;           // per name
	String primary;
	GraphAxisHidden axis_hidden;
	GraphKeySelected key_selected;
	void* ctx;
}

<*
 The curves, keys and handles of the asked joints.

 @param [&inout] graph : `Has its unit set; receives the rest.`
*>
fn void graph_fill(Graph* graph, GraphAsk* ask)
{
	AnimTemplate* clip = ask.clip;
	String primary = ask.primary;

	List{GraphChannel} channels;
	channels.init(mem);
	defer channels.free();
	List{GraphCurve} curves;
	curves.init(mem);
	defer curves.free();
	List{GraphKey} keys;
	keys.init(mem);
	defer keys.free();
	List{GraphHandle} handles;
	handles.init(mem);
	defer handles.free();

	foreach (usz n, name : ask.names)
	for (int pass = 0; pass < 2; pass++)
	{
		bool rotation = pass == 0;
		if (clip.channel_count(name, rotation) == 0) continue;
		uint id = ask.ids[n];
		channels.push({ .joint = name.copy(mem), .id = id, .rotation = rotation, .primary = name == primary });
		bool[3] drawn;
		bool some;
		for (int axis = 0; axis < 3; axis++)
		{
			drawn[axis] = !ask.axis_hidden(ask.ctx, id, rotation, axis);
			some = some || drawn[axis];
		}
		if (!some) continue;

		// The channel's keys, in time order.
		List{float} key_times;
		key_times.init(mem);
		defer key_times.free();
		List{usz} key_frames; // the clip's keyframe of each
		key_frames.init(mem);
		defer key_frames.free();
		foreach (usz f, frame : clip.keyframes)
		{
			AnimKeyDot ignored;
			if (!frame.channel_dot(name, rotation, &ignored)) continue;
			key_times.push(frame.time);
			key_frames.push(f);
		}
		List{float} times;
		times.init(mem);
		defer times.free();
		for (usz i = 0; i <= GRAPH_SAMPLES; i++) times.push(clip.duration * (float)i / (float)GRAPH_SAMPLES);
		foreach (at : key_times.array_view()) times.push(at);
		float[] sorted = times.array_view();
		sort::quicksort(sorted, &by_float);

		// Sampled once per time, unwrapped along the way, shared by the three axes.
		Vec3[] values = alloc::new_array(mem, Vec3, (sz)sorted.len);
		defer alloc::free(mem, values);
		Vec3 near;
		foreach (usz i, at : sorted)
		{
			values[i] = graph_value(clip, name, rotation, at, near, graph.unit);
			near = values[i];
		}

		usz[3] curve_of;
		for (int axis = 0; axis < 3; axis++)
		{
			if (!drawn[axis]) continue;
			Vec2[] samples = alloc::new_array(mem, Vec2, (sz)sorted.len);
			foreach (usz i, at : sorted) samples[i] = { at, values[i][axis] };
			curve_of[axis] = (usz)curves.len();
			curves.push({ .joint = name.copy(mem), .rotation = rotation, .axis = axis,
				.primary = name == primary, .samples = samples });
		}

		AnimChannels channel = rotation ? ROTATION : TRANSLATION;
		foreach (usz k, at : key_times.array_view())
		{
			Vec3 shown;
			foreach (usz i, t : sorted) if (t == at) { shown = values[i]; break; }
			bool selected = ask.key_selected(ask.ctx, at, name, channel);
			usz[3] key_of;
			for (int axis = 0; axis < 3; axis++)
			{
				if (!drawn[axis]) continue;
				key_of[axis] = (usz)keys.len();
				keys.push({ .curve = curve_of[axis], .time = at, .value = shown[axis],
					.shown = shown, .selected = selected });
			}

			// Handles on this key's own ends: the tangent leaving it and the one
			// arriving at it, each a third of its segment away.
			if (!selected) continue;
			for (int side = 0; side < 2; side++)
			{
				bool incoming = side == 1;
				if (incoming ? k == 0 : (sz)k + 1 >= key_times.len()) continue;
				// The segment belongs to the key it leaves from.
				usz owner = incoming ? key_frames[(sz)k - 1] : key_frames[(sz)k];
				float span = incoming ? at - key_times[(sz)k - 1] : key_times[(sz)k + 1] - at;
				if (!(span > 0.0f)) continue;
				AnimKeyDot dot;
				if (!clip.keyframes[owner].channel_dot(name, rotation, &dot)) continue;
				AnimInterpolation curve = dot.interpolation(rotation, clip.blend);
				if (curve == HOLD || curve == LINEAR) continue;
				Vec3 rate = effective_tangent(*clip, key_frames[(sz)k], name, rotation, incoming);
				// Per second, in the units the curve is drawn in.
				Vec3 slope = rotation ? euler_rate_of_angular_rate(shown, rate) : rate * graph.unit;
				float length = span / 3.0f;
				for (int axis = 0; axis < 3; axis++)
				{
					if (!drawn[axis]) continue;
					float run = incoming ? -length : length;
					handles.push({ .key = key_of[axis], .incoming = incoming, .length = length,
						.at = { at + run, shown[axis] + slope[axis] * run } });
				}
			}
		}
	}
	graph.curves = curves.to_array(mem);
	graph.keys = keys.to_array(mem);
	graph.handles = handles.to_array(mem);
	graph.channels = channels.to_array(mem);

	// Two kinds in one plot: each curve fills -1..1 by its own range.
	bool has_rotation;
	bool has_position;
	foreach (curve : graph.curves)
	{
		has_rotation = has_rotation || curve.rotation;
		has_position = has_position || !curve.rotation;
	}
	graph.mixed = has_rotation && has_position;
	if (graph.mixed)
	{
		foreach (&curve : graph.curves)
		{
			float low = curve.samples[0].y;
			float high = low;
			foreach (p : curve.samples) { low = math::min(low, p.y); high = math::max(high, p.y); }
			curve.mid = (low + high) * 0.5f;
			curve.half = math::max((high - low) * 0.5f, curve.rotation ? 0.5f : 5.0e-5f * graph.unit);
		}
	}
}

<* Walks: a path's samples dropped onto the ground, and a move's clip played at the rate that keeps its feet on it. *>
module crig;

import std::math;

// The ground speed a walk is timed at when its clip says nothing, in m/s.
const float CUT_DEFAULT_GROUND_SPEED = 1.0f;
// How finely a curve span is searched for the place nearest a click.
const usz WALK_SPAN_SEARCH @local = 24;

<* The ground under a point: true with its height there, false where there is none. *>
alias WalkGroundFn = fn bool(void* context, Vec3 at, float* height);

<* What a walk's samples are dropped onto; with no function they keep the curve's height. *>
struct WalkGround
{
	WalkGroundFn probe;
	void* context;
}

fn bool WalkGround.active(self) => self.probe != null;

fn bool WalkGround.under(self, Vec3 at, float* height) => self.probe != null && self.probe(self.context, at, height);

<* How long a line through `points` is. *>
fn float polyline_length(Vec3[] points)
{
	float total = 0.0f;
	for (usz k = 1; k < points.len; k++) total += (points[k] - points[k - 1]).length();
	return total;
}

<*
 Samples of a curve dropped onto `ground`, then spaced evenly again along the
 dropped line, every `spacing` or a little less, the ends kept. Where the ground
 has nothing a sample keeps the curve's height. Each drop starts from the height
 the ground had at the sample before, so a rise between two knots is still found
 from above.

 @param [in] curve : "Samples along the curve, in order"
 @require spacing > 0.0f : "Spacing must be positive"

 @return "Points owned by the caller, and the dropped line's length"
*>
fn WalkSamples ground_walk_samples(Allocator allocator, Vec3[] curve, WalkGround ground, float spacing = WALK_PATH_SPACING)
{
	if (curve.len < 2 || !ground.active())
	{
		return { .points = curve.len > 0 ? alloc::clone_slice(allocator, curve) : {}, .length = polyline_length(curve) };
	}
	WalkSamples out;
	@pool()
	{
		Vec3[] dropped = alloc::clone_slice(tmem, curve);
		float lift = 0.0f;
		foreach (&p : dropped)
		{
			float height;
			bool hit = ground.under({ p.x, p.y + lift, p.z }, &height);
			if (!hit && lift != 0.0f) hit = ground.under(*p, &height);
			lift = hit ? height - p.y : 0.0f;
			if (hit) p.y = height;
		}

		float[] along = alloc::new_array(tmem, float, (sz)dropped.len);
		for (usz k = 1; k < dropped.len; k++) along[k] = along[k - 1] + (dropped[k] - dropped[k - 1]).length();
		float total = along[^1];
		usz count = math::max((usz)2, (usz)math::ceil(total / spacing) + 1);
		Vec3[] points = alloc::new_array(allocator, Vec3, (sz)count);
		usz j = 0;
		for (usz k = 0; k < count; k++)
		{
			float want = total * (float)k / (float)(count - 1);
			while (j + 2 < dropped.len && along[j + 1] < want) j++;
			float span = along[j + 1] - along[j];
			float f = span > 1e-9f ? math::clamp((want - along[j]) / span, 0.0f, 1.0f) : 0.0f;
			points[k] = dropped[j] + (dropped[j + 1] - dropped[j]) * f;
		}
		points[0] = dropped[0];
		points[^1] = dropped[^1];
		out = { .points = points, .length = polyline_length(points) };
	};
	return out;
}

<*
 The playback rate that keeps a walk's feet on the ground it covers: its speed
 along the path over the clip's ground speed. 1 when either is not known.
*>
fn float cut_walk_rate(float length, float seconds, float ground_speed)
{
	if (!(ground_speed > 1e-6f) || !(seconds > 1e-6f) || !(length > 0.0f)) return 1.0f;
	return (length / seconds) / ground_speed;
}

<* How long a walk of `length` metres takes at `ground_speed`, at CUT_DEFAULT_GROUND_SPEED when that is not known. *>
fn float cut_walk_seconds(float length, float ground_speed)
{
	float speed = ground_speed > 1e-6f ? ground_speed : CUT_DEFAULT_GROUND_SPEED;
	return math::max(length, 0.0f) / speed;
}

<* The clip named most like a walk: "walk" itself, else one starting with it, else one holding it; -1 for none. *>
fn sz cut_walk_clip(String[] clips)
{
	sz best = -1;
	int best_rank;
	foreach (usz i, clip : clips)
	{
		for (usz k = 0; k + 4 <= clip.len; k++)
		{
			String part = clip[k:4];
			if ((part[0] | 0x20) != 'w' || (part[1] | 0x20) != 'a' || (part[2] | 0x20) != 'l' || (part[3] | 0x20) != 'k') continue;
			int rank = clip.len == 4 ? 3 : (k == 0 ? 2 : 1);
			if (rank > best_rank)
			{
				best = (sz)i;
				best_rank = rank;
			}
			break;
		}
	}
	return best;
}

<*
 Which span of the curve through `knots` passes nearest `at` across the floor:
 a knot put at `at` goes after knot `return`.

 @param [in] knots
 @require knots.len >= 2 : "A curve has two knots or more"
*>
fn usz walk_knot_span(Vec3[] knots, Vec3 at)
{
	usz best_span = 0;
	@pool()
	{
		CutCurve curve = cut_curve(tmem, knots);
		double best = double::max;
		for (usz span = 0; span + 1 < knots.len; span++)
		{
			for (usz step = 0; step <= WALK_SPAN_SEARCH; step++)
			{
				CutVec p = curve.segment(span, (double)step / (double)WALK_SPAN_SEARCH);
				double dx = p.x - at.x;
				double dz = p.z - at.z;
				double d = dx * dx + dz * dz;
				if (d >= best) continue;
				best = d;
				best_span = span;
			}
		}
	};
	return best_span;
}

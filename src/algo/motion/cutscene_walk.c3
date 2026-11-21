<* Walks: a path's samples dropped onto the ground, the move a play walks with and follows, and the rate that keeps its feet on the path. *>
module crig;

import std::collections::list;
import std::math;

// The ground speed a walk is timed at when its clip says nothing, in m/s.
const float CUT_DEFAULT_GROUND_SPEED = 1.0f;
// The least ground speed, in m/s, a play's clip needs for its speed to follow the move it plays over.
const float CUT_PAIR_GROUND_MIN = 0.1f;
// How finely a curve span is searched for the place nearest a click.
const usz WALK_SPAN_SEARCH @local = 24;

<* The ground under a point: true with its height there, false where there is none. *>
alias WalkGroundFn = fn bool(void* context, Vec3 at, float* height);

// A ground ray starts this far above the point, so a branch overhead is not hit.
const float GROUND_RAY_LIFT = 0.5f;

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

<*
 The move an actor walks at `t`, as the pose rule follows it: the latest begun
 with a path of two points or more that runs then; -1 for none.

 @param [in] strips : "One actor's strips"
 @param [in] paths : "The cutscene's paths"
*>
fn sz cut_move_at(CutStrip[] strips, float t, WalkPath[] paths)
{
	sz best = -1;
	foreach (usz j, &m : strips)
	{
		if (m.kind != MOVE || m.path < 0 || m.path >= paths.len || paths[m.path].points.len < 2) continue;
		if (m.start > t + CUT_SAME_TIME || t >= m.end - CUT_SAME_TIME) continue;
		if (best < 0 || m.start >= strips[best].start) best = (sz)j;
	}
	return best;
}

<*
 The move play strip `play` walks with: the one running when it starts (cut_move_at),
 or -1. Only a play of a clip pairs; a one-off has no ground speed, so it never does.

 @param [in] strips : "One actor's strips"
 @param [in] paths : "The cutscene's paths"
 @require play < strips.len : "No such strip"
*>
fn sz cut_paired_move(CutStrip[] strips, usz play, WalkPath[] paths)
{
	CutStrip* p = &strips[play];
	if (p.kind != PLAY || p.clip.len == 0 || p.one_off || p.animation >= 0) return -1;
	return cut_move_at(strips, p.start, paths);
}

<* A play tied to its move: paired with it and spanning it, so it takes the move's new times. *>
struct CutTie
{
	uint move;   // strip ids
	uint play;
	float start; // the move's span when the tie was read
	float end;
}

<*
 Whether play `play` is tied to move `move`: paired with it (cut_paired_move), and
 starting and ending as it does, within CUT_SAME_TIME.

 @param [in] strips : "One actor's strips"
 @param [in] paths : "The cutscene's paths"
 @require play < strips.len && move < strips.len : "No such strip"
*>
fn bool cut_play_tied(CutStrip[] strips, usz play, usz move, WalkPath[] paths)
{
	if (cut_paired_move(strips, play, paths) != (sz)move) return false;
	return math::abs(strips[play].start - strips[move].start) <= CUT_SAME_TIME
		&& math::abs(strips[play].end - strips[move].end) <= CUT_SAME_TIME;
}

<*
 The ties among one actor's strips, by strip id; a strip with no id has none.

 @param [in] strips : "One actor's strips"
 @param [in] paths : "The cutscene's paths"
 @return "Owned by allocator; empty for none"
*>
fn CutTie[] cut_ties(Allocator allocator, CutStrip[] strips, WalkPath[] paths)
{
	List{CutTie} found;
	found.init(mem);
	defer found.free();
	foreach (usz k, &p : strips)
	{
		if (p.kind != PLAY || p.id == 0) continue;
		sz move = cut_paired_move(strips, k, paths);
		if (move < 0 || strips[move].id == 0 || !cut_play_tied(strips, k, (usz)move, paths)) continue;
		found.push({ .move = strips[move].id, .play = p.id, .start = strips[move].start, .end = strips[move].end });
	}
	return found.len() > 0 ? found.to_array(allocator) : {};
}

fn sz cut_strip_with_id(CutStrip[] strips, uint id) @local
{
	foreach (usz k, &s : strips) if (s.id == id) return (sz)k;
	return -1;
}

<*
 After an edit, each play of `ties` (read before it) whose move now runs at other
 times takes the move's start and end; its offset stays, so its cycle starts where
 the move does. The lanes then settle around it. A tie whose move or play went is
 dropped.

 @param [&inout] strips : "One actor's strips, owned by allocator; replaced when settling drops or splits one"
 @return "Whether a play was carried"
*>
fn bool cut_carry_ties(Allocator allocator, CutStrip[]* strips, CutTie[] ties)
{
	bool carried;
	foreach (tie : ties)
	{
		sz move = cut_strip_with_id(*strips, tie.move);
		sz play = cut_strip_with_id(*strips, tie.play);
		if (move < 0 || play < 0) continue;
		CutStrip* m = &(*strips)[move];
		if (m.start == tie.start && m.end == tie.end) continue;
		CutStrip* p = &(*strips)[play];
		p.start = m.start;
		p.end = m.end;
		carried = true;
		(void)cut_settle_strips(allocator, strips, (usz)play);
	}
	return carried;
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

<* The lanes a cutscene strip takes, when two strips clash on one, and where a dragged time snaps. *>
module crig;

import std::collections::list;
import std::math;

// Times closer than this are one instant: strips that only touch do not overlap.
const float CUT_SAME_TIME = 1e-4f;

enum CutLane : char
{
	WHERE, // moves and turns
	WHAT,  // clips: play strips, and a move's clip
}

<* Which lanes a strip covers: a move with a clip both, else its own. *>
fn void cut_strip_lanes(CutStrip* s, CutLane* first, CutLane* last)
{
	switch (s.kind)
	{
		case MOVE:
			*first = WHERE;
			*last = s.clip.len > 0 ? WHAT : WHERE;
		case TURN:
			*first = WHERE;
			*last = WHERE;
		case PLAY:
			*first = WHAT;
			*last = WHAT;
	}
}

<* The lanes a strip covers as bits: 1 Where, 2 What. *>
fn char cut_lane_bits(CutStrip* s)
{
	CutLane first;
	CutLane last;
	cut_strip_lanes(s, &first, &last);
	char bits;
	for (char lane = first.ordinal; lane <= last.ordinal; lane++) bits |= (char)(1 << lane);
	return bits;
}

<* Whether two strips share a lane and their times cross; ends that only touch do not. *>
fn bool cut_strips_overlap(CutStrip* a, CutStrip* b)
{
	if ((cut_lane_bits(a) & cut_lane_bits(b)) == 0) return false;
	return a.start < b.end - CUT_SAME_TIME && b.start < a.end - CUT_SAME_TIME;
}

<* Move the start to `start` with the clip staying where it was in time: the offset follows, never below 0. *>
fn void CutStrip.trim_front(&self, float start)
{
	if (self.clip.len > 0) self.offset = math::max(self.offset + (start - self.start) * self.speed, 0.0f);
	self.start = start;
}

<*
 Settle one actor's lanes around strip `winner`, just placed or edited. It keeps
 its span, and each other strip sharing a lane with it gives way: one it covers
 goes, one it overlaps at an end is cut back to it (a front cut keeps the clip
 where it was in time), and one it lands inside keeps its part before it; a play
 strip also keeps its part after, as a new strip at the end of the list. Strips
 that clash with each other but not with the winner are left alone.

 @param [&inout] strips : "One actor's strips, owned by allocator; replaced when one goes or is split"
 @require winner < strips.len : "No such strip"

 @return "The winner's index afterwards"
*>
fn usz cut_settle_strips(Allocator allocator, CutStrip[]* strips, usz winner)
{
	CutStrip w = (*strips)[winner];
	if (w.end - w.start <= CUT_SAME_TIME) return winner;
	bool clashes;
	foreach (usz i, &s : *strips) clashes = clashes || (i != winner && cut_strips_overlap(&w, s));
	if (!clashes) return winner;

	List{CutStrip} kept;
	kept.init(mem);
	defer kept.free();
	List{CutStrip} tails;
	tails.init(mem);
	defer tails.free();
	usz at;
	foreach (usz i, s : *strips)
	{
		if (i == winner)
		{
			at = (usz)kept.len();
			kept.push(s);
			continue;
		}
		if (!cut_strips_overlap(&w, &s))
		{
			kept.push(s);
			continue;
		}
		bool before = s.start < w.start - CUT_SAME_TIME;
		bool after = s.end > w.end + CUT_SAME_TIME;
		if (!before && !after)
		{
			s.free(allocator);
			continue;
		}
		if (before && after && s.kind == PLAY)
		{
			CutStrip tail = s.copy(allocator);
			tail.id = 0;
			tail.trim_front(w.end);
			tails.push(tail);
		}
		if (before)
		{
			s.end = w.start;
		}
		else
		{
			s.trim_front(w.end);
		}
		kept.push(s);
	}
	foreach (tail : tails) kept.push(tail);
	alloc::free(allocator, *strips);
	*strips = kept.len() > 0 ? alloc::clone_slice(allocator, kept.array_view()) : {};
	return at;
}

<*
 `t` snapped to the nearest of `marks` within `reach` seconds, else to the nearest frame at `fps`; left as it is when fps is 0.
*>
fn float cut_snap_time(float t, float fps, float[] marks, float reach)
{
	float best = reach;
	float snapped = t;
	bool found;
	foreach (mark : marks)
	{
		float gap = math::abs(mark - t);
		if (gap > best) continue;
		best = gap;
		snapped = mark;
		found = true;
	}
	if (found) return snapped;
	return fps > 0.0f ? math::round(t * fps) / fps : t;
}

<*
 Where a span `length` long that would start at `start` snaps: whichever of its
 ends is nearer a mark within `reach`, else its start to a frame at `fps`.

 @return "The snapped start"
*>
fn float cut_snap_span(float start, float length, float fps, float[] marks, float reach)
{
	float best = reach;
	float snapped = start;
	bool found;
	foreach (mark : marks)
	{
		float gap = math::abs(mark - start);
		if (gap <= best)
		{
			best = gap;
			snapped = mark;
			found = true;
		}
		gap = math::abs(mark - (start + length));
		if (gap <= best)
		{
			best = gap;
			snapped = mark - length;
			found = true;
		}
	}
	if (found) return snapped;
	return fps > 0.0f ? math::round(start * fps) / fps : start;
}

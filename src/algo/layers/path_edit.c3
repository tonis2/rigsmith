<* The pure half of src/app/path_edit.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

// How many points a path made from motion gets per second, and the most it gets.
const float PATH_FROM_MOTION_RATE = 8.0f;

const usz PATH_FROM_MOTION_MOST = 48;

// The point of a generated foot path that is the top of its swing: the middle of
// the points after the two stance ends.
const usz GAIT_APEX_POINT = 2 + GAIT_SWING_POINTS / 2;

fn bool paths_same(AnimPath* a, AnimPath* b)
{
	if (a.points.len != b.points.len || a.slices.len != b.slices.len || a.closed != b.closed) return false;
	foreach (usz i, point : a.points) if (point.at != b.points[i].at || point.sharp != b.points[i].sharp) return false;
	foreach (usz i, slice : a.slices) if (slice.u != b.slices[i].u || slice.time != b.slices[i].time) return false;
	return true;
}

<* The pure half of src/ui/path_overlay.c3: no state, undo or notices. *>
module crig;

import collision;
import std::math;
import std::math::vector;

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

struct PathPress
{
	bool pending;
	usz path;
	usz handle;
	bool slice;
}

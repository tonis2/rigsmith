<* The pure half of src/app/scale_model.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

enum ScaleModelResult : int
{
	SCALED,
	UNCHANGED,
	LOCKED,
	REFUSED,
}

// Below this a factor is a typo or a collapse, above it the same the other way.
// A thousandfold covers millimetres to metres, which is the widest honest change.
const float SCALE_MODEL_MIN = 0.001f;

const float SCALE_MODEL_MAX = 1000.0f;

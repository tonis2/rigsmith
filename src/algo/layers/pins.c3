<* The pure half of src/mcp/pins.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::object;
import std::math;
import std::math::vector;

// How many pointer moves a posed move or turn is broken into. One jump from the
// start to the end is not what a hand does, and a grab carried a short way at a
// time reaches far-off targets the way a drag does. Each move solves from the
// pose the gesture began with, so the last one alone decides where the body ends.
const usz POSE_JOINT_STEPS = 12;

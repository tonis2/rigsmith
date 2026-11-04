<* The pure half of src/mcp/rig.c3: no state, undo or notices. *>
module crig;

import rig;
import std::collections::list;
import std::collections::object;
import std::math;
import std::math::quaternion;

// Every `op` edit_rig answers to, for the refusals that list them. Keep it in
// step with the schema's enum and the switch in `apply_op`.
const String RIG_OPS = "place, move, name, name_all, remove, connect, disconnect, root, reach, sharpness, knuckle_blend, attach, detach, limits, exclude, include, symmetry, plan_limits";

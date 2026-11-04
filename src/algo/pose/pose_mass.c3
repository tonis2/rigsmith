<* The pure half of src/app/pose_mass.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

// The heaviest body part's mass, the lightest's being 1. The solve's inertia is
// the mass less one (`BodySolve.mass`), so the band is what separates a part
// that goes where it is pulled from one that barely stirs: a fingertip next to
// a pelvis is about a thousandth of its volume, and lands near 1.
const float PART_MASS_MAX = 16.0;

// The least a part's box is taken to hold, as a share of its bone's length
// cubed: a joint the skin hardly reaches — a fingertip's last joint, a twist bone
// sharing its limb — still weighs what a sliver of its bone would.
const float PART_MASS_FLOOR = 0.05;

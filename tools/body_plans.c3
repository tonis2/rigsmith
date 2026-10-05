<*
 The body plans crig's own packs are generated from.

 Authoring data. The app does not read these — it reads a plan out of whichever
 pack the user picked, because the file carrying a walk is the only thing that
 knows which joints that walk needs. These are here so the packs in the box can
 be regenerated from something a person can edit, and so a new body plan is a
 table plus a run of `make-anims` rather than a modelling session.

 The frame is `fit_preset`'s: 0 to 1 per axis, x across, y up, z head-ward, and
 a `mirror` row emits `<name>_L` then `<name>_R`. See core/presets.c3.
*>
module make_anims;

import crig;

<*
 A four-legged animal standing: spine, tail, and two pairs of legs.

 Fitted against a standing pose, which is what an animal scan or an asset-store
 model almost always is. A grazing head or a folded leg still lands inside the
 body — the mesh is what the dots are snapped to — but lands in the wrong place
 along it, and is a drag rather than a re-rig.
*>
PresetDot[13] quadruped_dots = {
	{ .name = "pelvis",     .at = { 0.50, 0.60, 0.30 }, .parent = -1 },
	{ .name = "spine",      .at = { 0.50, 0.64, 0.45 }, .parent = 0 },
	{ .name = "chest",      .at = { 0.50, 0.64, 0.62 }, .parent = 1 },
	{ .name = "neck",       .at = { 0.50, 0.70, 0.76 }, .parent = 2 },
	{ .name = "head",       .at = { 0.50, 0.78, 0.88 }, .parent = 3 },
	{ .name = "tail_base",  .at = { 0.50, 0.58, 0.22 }, .parent = 0 },
	{ .name = "tail_tip",   .at = { 0.50, 0.46, 0.07 }, .parent = 5 },
	{ .name = "shoulder",   .at = { 0.38, 0.55, 0.62 }, .parent = 2, .mirror = true },
	{ .name = "fore_knee",  .at = { 0.37, 0.28, 0.62 }, .parent = 7, .mirror = true },
	{ .name = "fore_hoof",  .at = { 0.37, 0.04, 0.62 }, .parent = 8, .mirror = true },
	{ .name = "hip",        .at = { 0.38, 0.55, 0.32 }, .parent = 0, .mirror = true },
	{ .name = "hind_knee",  .at = { 0.37, 0.28, 0.30 }, .parent = 10, .mirror = true },
	{ .name = "hind_hoof",  .at = { 0.37, 0.04, 0.30 }, .parent = 11, .mirror = true },
};

<*
 A humanoid in a T-pose: spine, arms out level, legs down.

 T-pose rather than A-pose on purpose. With the arms held out, the bounding box
 *is* the arm span, so a wrist at 0.86 across is a wrist on nearly every model
 that holds still — the normalization does the work that would otherwise be
 guesswork. An A-pose model puts the arm dots out in the air beside the ribs and
 the grid pulls them onto the torso, which reads immediately as wrong.

 Every dot the fit places sits at mid-depth, so this preset has no front-to-back
 asymmetry and the facing test is a formality that costs a few microseconds and
 cannot be wrong. The fingers spread across depth, and do not change that: they
 are optional, and `preset_reversed` measures the fit, which never places one.
*>
PresetDot[32] biped_dots = {
	{ .name = "hips",       .at = { 0.50, 0.52, 0.50 }, .parent = -1 },
	{ .name = "spine",      .at = { 0.50, 0.62, 0.50 }, .parent = 0 },
	{ .name = "chest",      .at = { 0.50, 0.74, 0.50 }, .parent = 1 },
	{ .name = "neck",       .at = { 0.50, 0.83, 0.50 }, .parent = 2 },
	{ .name = "head",       .at = { 0.50, 0.92, 0.50 }, .parent = 3 },
	{ .name = "shoulder",   .at = { 0.58, 0.80, 0.50 }, .parent = 2, .mirror = true },
	{ .name = "elbow",      .at = { 0.72, 0.80, 0.50 }, .parent = 5, .mirror = true },
	{ .name = "wrist",      .at = { 0.86, 0.80, 0.50 }, .parent = 6, .mirror = true },
	{ .name = "thigh",      .at = { 0.55, 0.50, 0.50 }, .parent = 0, .mirror = true },
	{ .name = "knee",       .at = { 0.55, 0.27, 0.50 }, .parent = 8, .mirror = true },
	{ .name = "ankle",      .at = { 0.55, 0.04, 0.50 }, .parent = 9, .mirror = true },

	// The hand, and five fingers of four joints each. All optional: see
	// `PresetDot.optional`. They are vocabulary, not shape — a biped without them
	// is still a biped, and there is nothing in a mesh's proportions that says
	// where a knuckle goes, so `fit_preset` never places any of these.
	//
	// **Four joints a finger, not three**, and the fourth is a tip marker that no
	// clip turns. Downloaded rigs are written that way — mixamo's are
	// `Index1..Index4` — and a three-dot plan chain laid along a four-joint source
	// run lands on the last three of it: the knuckle rotation, which is the largest
	// of the four, would go to the fold and the plan's fingertip would sit on a
	// marker that never moves. The still-joint penalty does not save it, because a
	// chain's *terminal* dot is allowed to land on a joint that holds still.
	//
	// Spread across the palm at the wrist's own height and running outward, at the
	// lengths a hand actually has: middle longest, then index and ring, then the
	// pinky, and the thumb shortest of all and set off across the palm rather than
	// along it. The order matters more than the numbers — chains are paired by how
	// far each reaches from the joint they share, so a thumb written as long as a
	// middle finger is a thumb that gets matched as one.
	{ .name = "hand",     .at = { 0.90, 0.80, 0.50 }, .parent = 7, .mirror = true, .optional = true },

	{ .name = "thumb_1",  .at = { 0.911, 0.798, 0.515 }, .parent = 11, .mirror = true, .optional = true },
	{ .name = "thumb_2",  .at = { 0.921, 0.797, 0.527 }, .parent = 12, .mirror = true, .optional = true },
	{ .name = "thumb_3",  .at = { 0.929, 0.795, 0.538 }, .parent = 13, .mirror = true, .optional = true },
	{ .name = "thumb_4",  .at = { 0.935, 0.794, 0.545 }, .parent = 14, .mirror = true, .optional = true },

	{ .name = "index_1",  .at = { 0.928, 0.800, 0.510 }, .parent = 11, .mirror = true, .optional = true },
	{ .name = "index_2",  .at = { 0.951, 0.800, 0.518 }, .parent = 16, .mirror = true, .optional = true },
	{ .name = "index_3",  .at = { 0.971, 0.800, 0.525 }, .parent = 17, .mirror = true, .optional = true },
	{ .name = "index_4",  .at = { 0.985, 0.800, 0.530 }, .parent = 18, .mirror = true, .optional = true },

	{ .name = "middle_1", .at = { 0.933, 0.800, 0.500 }, .parent = 11, .mirror = true, .optional = true },
	{ .name = "middle_2", .at = { 0.960, 0.800, 0.500 }, .parent = 20, .mirror = true, .optional = true },
	{ .name = "middle_3", .at = { 0.984, 0.800, 0.500 }, .parent = 21, .mirror = true, .optional = true },
	{ .name = "middle_4", .at = { 1.000, 0.800, 0.500 }, .parent = 22, .mirror = true, .optional = true },

	{ .name = "ring_1",   .at = { 0.927, 0.800, 0.490 }, .parent = 11, .mirror = true, .optional = true },
	{ .name = "ring_2",   .at = { 0.948, 0.800, 0.482 }, .parent = 24, .mirror = true, .optional = true },
	{ .name = "ring_3",   .at = { 0.968, 0.800, 0.475 }, .parent = 25, .mirror = true, .optional = true },
	{ .name = "ring_4",   .at = { 0.981, 0.800, 0.470 }, .parent = 26, .mirror = true, .optional = true },

	{ .name = "pinky_1",  .at = { 0.911, 0.800, 0.480 }, .parent = 11, .mirror = true, .optional = true },
	{ .name = "pinky_2",  .at = { 0.919, 0.800, 0.464 }, .parent = 28, .mirror = true, .optional = true },
	{ .name = "pinky_3",  .at = { 0.927, 0.800, 0.450 }, .parent = 29, .mirror = true, .optional = true },
	{ .name = "pinky_4",  .at = { 0.932, 0.800, 0.440 }, .parent = 30, .mirror = true, .optional = true },
};

<*
 A standing bird: body, neck up and forward, two legs, two wings.

 Wings are one bone each rather than the three a flying rig wants. A folded wing
 is a flat sheet against the body and its joints are not separable from the
 outside — the extra dots would land wherever the grid put them, which is worse
 than the user placing two.
*>
PresetDot[11] bird_dots = {
	{ .name = "pelvis",     .at = { 0.50, 0.52, 0.42 }, .parent = -1 },
	{ .name = "spine",      .at = { 0.50, 0.57, 0.56 }, .parent = 0 },
	{ .name = "chest",      .at = { 0.50, 0.58, 0.68 }, .parent = 1 },
	{ .name = "neck",       .at = { 0.50, 0.72, 0.78 }, .parent = 2 },
	{ .name = "head",       .at = { 0.50, 0.87, 0.86 }, .parent = 3 },
	{ .name = "tail",       .at = { 0.50, 0.56, 0.18 }, .parent = 0 },
	{ .name = "thigh",      .at = { 0.42, 0.45, 0.45 }, .parent = 0, .mirror = true },
	{ .name = "knee",       .at = { 0.42, 0.25, 0.45 }, .parent = 6, .mirror = true },
	{ .name = "foot",       .at = { 0.42, 0.04, 0.48 }, .parent = 7, .mirror = true },
	{ .name = "wing_root",  .at = { 0.37, 0.61, 0.58 }, .parent = 1, .mirror = true },
	{ .name = "wing_tip",   .at = { 0.24, 0.56, 0.46 }, .parent = 9, .mirror = true },
};

// No `const Preset` wrappers: a const holding a slice cannot be stored and read
// back later (see make_anims.c3), and these are handed to a spec that outlives
// the expression. The tables are sliced at the point of use instead.

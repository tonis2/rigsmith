<*
 A humanoid body plan: a full figure, in the words the biped plan uses.

 The other three plans in this folder are diagrams — seventeen joints, enough
 to say where a body bends. This one is a figure: three spine bones, a clavicle
 before each shoulder, a toe on each foot, five fingers of four joints on each
 hand, sixty-five joints in all. The words are the biped plan's own where the
 two share a joint — `thigh_L`, `elbow_R`, `chest` — and the rest are spelt the
 same way: `clavicle_L`, `upper_spine`, `toe_tip_R`, `index_2_L`. So a rig
 fitted from this figure and one fitted from the biped diagram are named alike,
 and the rotation-limit defaults, the mirror and the clip player read both by
 the same rules.

 Nothing here spells a joint the way any download does. A clip from an asset
 site or a motion-capture service names its joints however its exporter felt
 like, and crig carries those across by matching the two skeletons' *shapes*
 (`core/joint_match.c3`, `anim/retarget.c3`), which is what lets the names here
 be plain words rather than an interoperability contract.

 **Why this exists as a table rather than as a file.** A rigged humanoid is the
 easiest thing in the world to download and the hardest to ship: every one of
 them arrives under a licence that permits using the character and forbids
 passing it on, which is exactly what putting one in `assets/` does. So the
 figure crig opens with is built here, out of numbers, and owes nothing to
 anybody — the proportions, the mesh, the names and the clips are all this
 repository's own.

 **The proportions.** Written as fractions of the figure's own height, from the
 canon a life-drawing class teaches: the crotch at just over half the height, the
 knee at 0.28, the shoulder at 0.79, the chin at 0.87, and an arm span equal to
 the height — which is what puts the fingertips at 0.5 either side of the midline
 and makes the box below square. A head is one eighth of the whole. These are
 averages of a species, not a measurement of a character.

 T-pose, for the reason `biped_dots` gives: with the arms held out the bounding
 box *is* the arm span, so the fractions across mean something on any model that
 holds still. It is also what every clip library binds against.

 The frame is `fit_preset`'s: 0 to 1 per axis, x across, y up, z head-ward, with
 x = 0.5 the midline. Unlike the other tables here, no row is marked `mirror` —
 that flag emits `<name>_L` and `<name>_R` from one row, and the two sides of a
 figure this detailed are easier to check written out. Both are.
*>
module make_anims;

import crig;

<*
 Sixty-five joints: spine and head, two legs to the toe, two arms, and a hand of
 five fingers on each.

 Every finger joint is `optional`, for the reason `biped_dots` sets out at
 length — a figure without fingers is still a humanoid, and nothing in a mesh's
 proportions says where a knuckle goes. `plan_skeleton` places them anyway,
 because a pack has to carry the whole vocabulary for a clip to be able to reach
 it; `fit_preset` will not place one onto a user's model.

 Four joints a finger, the fourth a tip marker no clip turns — the shape every
 hand-rigged figure has, which is what lets a downloaded one match this by
 shape, joint for joint.
*>
PresetDot[65] humanoid_dots = {
	// The spine, neck and skull. `head_top` is the crown — a marker at the top
	// of the head rather than a bone, which is why it is the tallest joint here
	// and carries nothing below it.
	{ .name = "hips",        .at = { 0.5000, 0.5474, 0.5000 }, .parent = -1 },
	{ .name = "spine",       .at = { 0.5000, 0.5911, 0.5019 }, .parent =  0 },
	{ .name = "upper_spine", .at = { 0.5000, 0.6435, 0.5049 }, .parent =  1 },
	{ .name = "chest",       .at = { 0.5000, 0.6958, 0.5029 }, .parent =  2 },
	{ .name = "neck",        .at = { 0.5000, 0.8025, 0.4942 }, .parent =  3 },
	{ .name = "head",        .at = { 0.5000, 0.8540, 0.4981 }, .parent =  4 },
	{ .name = "head_top",    .at = { 0.5000, 0.9820, 0.5116 }, .parent =  5 },

	// Left leg. The foot sits back of the ankle's depth and the toe well forward
	// of it, so a foot is a shape with a direction rather than a spike straight
	// down — which is what lets a walk's toe-off read as one.
	{ .name = "thigh_L",     .at = { 0.5466, 0.5193, 0.5000 }, .parent =  0 },
	{ .name = "knee_L",      .at = { 0.5485, 0.2836, 0.5078 }, .parent =  7 },
	{ .name = "ankle_L",     .at = { 0.5504, 0.0489, 0.4903 }, .parent =  8 },
	{ .name = "toe_L",       .at = { 0.5504, 0.0159, 0.5543 }, .parent =  9 },
	{ .name = "toe_tip_L",   .at = { 0.5504, 0.0120, 0.5970 }, .parent = 10 },

	// Left arm. The clavicle hangs off `chest` rather than off the neck, which
	// is what lets a shrug move the shoulder without moving the head.
	{ .name = "clavicle_L",  .at = { 0.5252, 0.7783, 0.4884 }, .parent =  3 },
	{ .name = "shoulder_L",  .at = { 0.5815, 0.7764, 0.4864 }, .parent = 12 },
	{ .name = "elbow_L",     .at = { 0.7309, 0.7764, 0.4903 }, .parent = 13 },
	{ .name = "wrist_L",     .at = { 0.8802, 0.7764, 0.4922 }, .parent = 14 },

	// Left hand. The four fingers run outward along x at the wrist's own height
	// and spread across depth — index forward, pinky back — while the thumb is
	// set off the front of the palm and is the shortest of the five. The order of
	// the lengths matters more than the lengths: chains are paired by how far each
	// reaches from the joint they share, so a thumb written as long as a middle
	// finger is a thumb that gets matched as one.
	{ .name = "thumb_1_L",   .at = { 0.8958, 0.7725, 0.5136 }, .parent = 15, .optional = true },
	{ .name = "thumb_2_L",   .at = { 0.9171, 0.7696, 0.5291 }, .parent = 16, .optional = true },
	{ .name = "thumb_3_L",   .at = { 0.9355, 0.7676, 0.5388 }, .parent = 17, .optional = true },
	{ .name = "thumb_4_L",   .at = { 0.9491, 0.7657, 0.5456 }, .parent = 18, .optional = true },

	{ .name = "index_1_L",   .at = { 0.9287, 0.7773, 0.5116 }, .parent = 15, .optional = true },
	{ .name = "index_2_L",   .at = { 0.9481, 0.7773, 0.5126 }, .parent = 20, .optional = true },
	{ .name = "index_3_L",   .at = { 0.9637, 0.7773, 0.5136 }, .parent = 21, .optional = true },
	{ .name = "index_4_L",   .at = { 0.9763, 0.7773, 0.5136 }, .parent = 22, .optional = true },

	{ .name = "middle_1_L",  .at = { 0.9307, 0.7764, 0.4981 }, .parent = 15, .optional = true },
	{ .name = "middle_2_L",  .at = { 0.9510, 0.7764, 0.4981 }, .parent = 24, .optional = true },
	{ .name = "middle_3_L",  .at = { 0.9666, 0.7764, 0.4981 }, .parent = 25, .optional = true },
	{ .name = "middle_4_L",  .at = { 0.9801, 0.7764, 0.4981 }, .parent = 26, .optional = true },

	{ .name = "ring_1_L",    .at = { 0.9278, 0.7754, 0.4854 }, .parent = 15, .optional = true },
	{ .name = "ring_2_L",    .at = { 0.9462, 0.7754, 0.4845 }, .parent = 28, .optional = true },
	{ .name = "ring_3_L",    .at = { 0.9607, 0.7754, 0.4835 }, .parent = 29, .optional = true },
	{ .name = "ring_4_L",    .at = { 0.9724, 0.7754, 0.4835 }, .parent = 30, .optional = true },

	{ .name = "pinky_1_L",   .at = { 0.9229, 0.7744, 0.4738 }, .parent = 15, .optional = true },
	{ .name = "pinky_2_L",   .at = { 0.9384, 0.7744, 0.4719 }, .parent = 32, .optional = true },
	{ .name = "pinky_3_L",   .at = { 0.9491, 0.7744, 0.4709 }, .parent = 33, .optional = true },
	{ .name = "pinky_4_L",   .at = { 0.9588, 0.7744, 0.4709 }, .parent = 34, .optional = true },

	// Right leg, arm and hand: the left rows reflected through x = 0.5, in the
	// same order, so the two sides can be read against each other line for line.
	{ .name = "thigh_R",     .at = { 0.4534, 0.5193, 0.5000 }, .parent =  0 },
	{ .name = "knee_R",      .at = { 0.4515, 0.2836, 0.5078 }, .parent = 36 },
	{ .name = "ankle_R",     .at = { 0.4496, 0.0489, 0.4903 }, .parent = 37 },
	{ .name = "toe_R",       .at = { 0.4496, 0.0159, 0.5543 }, .parent = 38 },
	{ .name = "toe_tip_R",   .at = { 0.4496, 0.0120, 0.5970 }, .parent = 39 },

	{ .name = "clavicle_R",  .at = { 0.4748, 0.7783, 0.4884 }, .parent =  3 },
	{ .name = "shoulder_R",  .at = { 0.4185, 0.7764, 0.4864 }, .parent = 41 },
	{ .name = "elbow_R",     .at = { 0.2691, 0.7764, 0.4903 }, .parent = 42 },
	{ .name = "wrist_R",     .at = { 0.1198, 0.7764, 0.4922 }, .parent = 43 },

	{ .name = "thumb_1_R",   .at = { 0.1042, 0.7725, 0.5136 }, .parent = 44, .optional = true },
	{ .name = "thumb_2_R",   .at = { 0.0829, 0.7696, 0.5291 }, .parent = 45, .optional = true },
	{ .name = "thumb_3_R",   .at = { 0.0645, 0.7676, 0.5388 }, .parent = 46, .optional = true },
	{ .name = "thumb_4_R",   .at = { 0.0509, 0.7657, 0.5456 }, .parent = 47, .optional = true },

	{ .name = "index_1_R",   .at = { 0.0713, 0.7773, 0.5116 }, .parent = 44, .optional = true },
	{ .name = "index_2_R",   .at = { 0.0519, 0.7773, 0.5126 }, .parent = 49, .optional = true },
	{ .name = "index_3_R",   .at = { 0.0363, 0.7773, 0.5136 }, .parent = 50, .optional = true },
	{ .name = "index_4_R",   .at = { 0.0237, 0.7773, 0.5136 }, .parent = 51, .optional = true },

	{ .name = "middle_1_R",  .at = { 0.0693, 0.7764, 0.4981 }, .parent = 44, .optional = true },
	{ .name = "middle_2_R",  .at = { 0.0489, 0.7764, 0.4981 }, .parent = 53, .optional = true },
	{ .name = "middle_3_R",  .at = { 0.0334, 0.7764, 0.4981 }, .parent = 54, .optional = true },
	{ .name = "middle_4_R",  .at = { 0.0199, 0.7764, 0.4981 }, .parent = 55, .optional = true },

	{ .name = "ring_1_R",    .at = { 0.0722, 0.7754, 0.4854 }, .parent = 44, .optional = true },
	{ .name = "ring_2_R",    .at = { 0.0538, 0.7754, 0.4845 }, .parent = 57, .optional = true },
	{ .name = "ring_3_R",    .at = { 0.0393, 0.7754, 0.4835 }, .parent = 58, .optional = true },
	{ .name = "ring_4_R",    .at = { 0.0276, 0.7754, 0.4835 }, .parent = 59, .optional = true },

	{ .name = "pinky_1_R",   .at = { 0.0771, 0.7744, 0.4738 }, .parent = 44, .optional = true },
	{ .name = "pinky_2_R",   .at = { 0.0616, 0.7744, 0.4719 }, .parent = 61, .optional = true },
	{ .name = "pinky_3_R",   .at = { 0.0509, 0.7744, 0.4709 }, .parent = 62, .optional = true },
	{ .name = "pinky_4_R",   .at = { 0.0412, 0.7744, 0.4709 }, .parent = 63, .optional = true },
};

<*
 How thick the body is at each joint, in the row order of `humanoid_dots`.

 A bone is drawn as a taper from its parent's radius to its own, so a number here
 is read twice: once as the far end of the bone above and once as the near end of
 every bone below. That is why the chest is the widest entry and the neck one of
 the narrowest — the taper between them is the shoulders.
*>
float[65] humanoid_radii = {
	0.084, 0.080, 0.090, 0.092, 0.036, 0.036, 0.014,

	0.058, 0.042, 0.034, 0.032, 0.024,
	0.046, 0.038, 0.030, 0.024,
	0.011, 0.010, 0.009, 0.007,
	0.010, 0.009, 0.008, 0.006,
	0.010, 0.009, 0.008, 0.006,
	0.009, 0.008, 0.007, 0.006,
	0.009, 0.007, 0.006, 0.005,

	0.058, 0.042, 0.034, 0.032, 0.024,
	0.046, 0.038, 0.030, 0.024,
	0.011, 0.010, 0.009, 0.007,
	0.010, 0.009, 0.008, 0.006,
	0.010, 0.009, 0.008, 0.006,
	0.009, 0.008, 0.007, 0.006,
	0.009, 0.007, 0.006, 0.005,
};

<*
 A ball at the joint itself, in the same row order. Zero for a joint that gets
 none, which is most of them.

 What turns a stack of tapered tubes into something that reads as a body. Two
 tubes meeting at an elbow leave a visible pinch on the outside of the bend and a
 gap on the inside the moment the joint turns; a ball wide enough to swallow both
 ends hides the seam from every angle and keeps hiding it while the arm moves.
 The head is the same trick used for its own sake: the skull is a ball, and the
 taper up to `head_top` is the crown sitting on it.

 Each is a shade wider than the widest bone meeting it and no more. A ball much
 wider than that stops hiding a seam and starts being a bead, and a row of beads
 down the spine is what the first draft of this looked like — which is why the
 three spine joints have none at all and the torso's shape is carried entirely by
 the taper between them.

 The fingers get none. They are too small for a seam to show at any size the
 figure is looked at, and forty more spheres is forty times the triangles for it.
*>
float[65] humanoid_balls = {
	0.086, 0.000, 0.000, 0.000, 0.062, 0.000, 0.068,

	0.060, 0.046, 0.038, 0.034, 0.000,
	0.056, 0.048, 0.034, 0.030,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,

	0.060, 0.046, 0.038, 0.034, 0.000,
	0.056, 0.048, 0.034, 0.030,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
	0.000, 0.000, 0.000, 0.000,
};

<*
 Where the skull's ball sits along the bone that carries it.

 One entry out of sixty-five is anything but zero. A ball at a joint is right
 everywhere a joint is a hinge and the mass is a sleeve around it — every elbow,
 knee, hip and shoulder here — and wrong for the head, which is a mass hanging
 *between* the joint at the base of the skull and the marker at the crown. Put
 the ball at either end and the figure gets a face on its collarbone or a balloon
 above its scalp; put it just under halfway up and the crown lands where a crown
 goes, the chin clears the shoulders, and the thin bones underneath become a
 visible neck rather than being swallowed.

 Seven entries rather than sixty-five: `dummy_body` reads zero past the end of
 this one, unlike `radii`, where running off the end repeats the last value and
 would give every finger an ankle's thickness.
*>
float[7] humanoid_ball_back = {
	0.000, 0.000, 0.000, 0.000, 0.420, 0.000, 0.380,
};

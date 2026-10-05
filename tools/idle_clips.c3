<*
 An idle for each body plan, so every pack ships with something to play.

 A pack with no clips in it is legal to read and useless to look at: the card
 opens on an empty row and there is nothing to check the rig against. These are
 the smallest honest thing to put there — a breath, a tail, a pair of wings —
 rather than a placeholder that plays nothing.

 Written against the tables in body_plans.c3, so the joint names are the ones
 `fit_preset` emits for that plan. A name no rig carries is a joint left at
 rest, which is what makes an idle survive being played on a rig missing half of
 it.
*>
module make_anims;

import crig;

// A breath is a few hundredths of a radian. Anything more reads as a stretch,
// and the point of an idle is that the figure is standing still.
const float BREATHE = 0.035f;
const float TAIL_SWAY = 0.11f;
const float WING_LIFT = 0.09f;

// ---------------------------------------------------------------------------
// Biped: the chest lifts and the head settles back.

const crig::AnimKeyDot[] BIPED_IDLE_IN = {
	{ .joint_name = "chest", .axis = { 1, 0, 0 }, .angle = -BREATHE },
	{ .joint_name = "neck",  .axis = { 1, 0, 0 }, .angle =  BREATHE },
	{ .joint_name = "head",  .axis = { 1, 0, 0 }, .angle = -BREATHE * 0.5f },
};

const crig::AnimKeyDot[] BIPED_IDLE_OUT = {
	{ .joint_name = "chest", .axis = { 1, 0, 0 }, .angle =  BREATHE * 0.4f },
	{ .joint_name = "neck",  .axis = { 1, 0, 0 }, .angle = -BREATHE * 0.3f },
	{ .joint_name = "head" },
};

const crig::AnimKeyframe[] BIPED_IDLE_FRAMES = {
	{ .time = 0.0f, .dots = BIPED_IDLE_OUT[..] },
	{ .time = 1.6f, .dots = BIPED_IDLE_IN[..] },
	{ .time = 3.2f, .dots = BIPED_IDLE_OUT[..] },
};

const crig::AnimTemplate BIPED_IDLE = {
	.name = "Idle",
	.duration = 3.2f,
	.keyframes = BIPED_IDLE_FRAMES[..],
	.loop = true,
};

// ---------------------------------------------------------------------------
// Quadruped: the same breath, plus the tail, which is the part of a standing
// animal that is never actually still.

const crig::AnimKeyDot[] QUAD_IDLE_LEFT = {
	{ .joint_name = "chest",     .axis = { 1, 0, 0 }, .angle = -BREATHE },
	{ .joint_name = "neck",      .axis = { 1, 0, 0 }, .angle =  BREATHE },
	{ .joint_name = "tail_base", .axis = { 0, 1, 0 }, .angle =  TAIL_SWAY },
	{ .joint_name = "tail_tip",  .axis = { 0, 1, 0 }, .angle =  TAIL_SWAY },
};

const crig::AnimKeyDot[] QUAD_IDLE_RIGHT = {
	{ .joint_name = "chest",     .axis = { 1, 0, 0 }, .angle =  BREATHE * 0.4f },
	{ .joint_name = "neck",      .axis = { 1, 0, 0 }, .angle = -BREATHE * 0.3f },
	{ .joint_name = "tail_base", .axis = { 0, 1, 0 }, .angle = -TAIL_SWAY },
	{ .joint_name = "tail_tip",  .axis = { 0, 1, 0 }, .angle = -TAIL_SWAY },
};

const crig::AnimKeyframe[] QUAD_IDLE_FRAMES = {
	{ .time = 0.0f, .dots = QUAD_IDLE_RIGHT[..] },
	{ .time = 1.4f, .dots = QUAD_IDLE_LEFT[..] },
	{ .time = 2.8f, .dots = QUAD_IDLE_RIGHT[..] },
};

const crig::AnimTemplate QUADRUPED_IDLE = {
	.name = "Idle",
	.duration = 2.8f,
	.keyframes = QUAD_IDLE_FRAMES[..],
	.loop = true,
};

// ---------------------------------------------------------------------------
// Bird: the wings, because a bird's wings are one bone each here and a lift
// that reads at all has to be most of what the clip does.

const crig::AnimKeyDot[] BIRD_IDLE_UP = {
	{ .joint_name = "wing_root_L", .axis = { 0, 0, 1 }, .angle =  WING_LIFT },
	{ .joint_name = "wing_root_R", .axis = { 0, 0, 1 }, .angle = -WING_LIFT },
	{ .joint_name = "wing_tip_L",  .axis = { 0, 0, 1 }, .angle =  WING_LIFT * 1.5f },
	{ .joint_name = "wing_tip_R",  .axis = { 0, 0, 1 }, .angle = -WING_LIFT * 1.5f },
	{ .joint_name = "neck",        .axis = { 1, 0, 0 }, .angle =  BREATHE },
	{ .joint_name = "tail" },
};

const crig::AnimKeyDot[] BIRD_IDLE_DOWN = {
	{ .joint_name = "wing_root_L", .axis = { 0, 0, 1 }, .angle = -WING_LIFT * 0.3f },
	{ .joint_name = "wing_root_R", .axis = { 0, 0, 1 }, .angle =  WING_LIFT * 0.3f },
	{ .joint_name = "wing_tip_L" },
	{ .joint_name = "wing_tip_R" },
	{ .joint_name = "neck" },
	{ .joint_name = "tail",        .axis = { 1, 0, 0 }, .angle =  BREATHE * 2.0f },
};

const crig::AnimKeyframe[] BIRD_IDLE_FRAMES = {
	{ .time = 0.0f, .dots = BIRD_IDLE_DOWN[..] },
	{ .time = 1.0f, .dots = BIRD_IDLE_UP[..] },
	{ .time = 2.0f, .dots = BIRD_IDLE_DOWN[..] },
};

const crig::AnimTemplate BIRD_IDLE = {
	.name = "Idle",
	.duration = 2.0f,
	.keyframes = BIRD_IDLE_FRAMES[..],
	.loop = true,
};

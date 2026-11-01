<*
 The SVG icons the tree rows, strips and lock toggles draw (assets/icons).
 The card and tool icons live on their enums instead.
*>
module crig;

import cui;
import std::math;

// Tree icons were drawn for a 14 px slot; their viewBox is 18 so strokes fit.
const float TREE_ICON_VIEW_SCALE = 18.0 / 14.0;

const String ICON_SCENE = $embed("../../assets/icons/tree/scene.svg");
const String ICON_MODEL = $embed("../../assets/icons/tree/model.svg");
const String ICON_MESH = $embed("../../assets/icons/tree/mesh.svg");
const String ICON_SKELETON = $embed("../../assets/icons/tree/skeleton.svg");
const String ICON_EYE = $embed("../../assets/icons/tree/eye.svg");
const String ICON_EYE_SHUT = $embed("../../assets/icons/tree/eye_shut.svg");
const String ICON_KEYED = $embed("../../assets/icons/tree/keyed.svg");
const String ICON_WAVE = $embed("../../assets/icons/tree/wave.svg");
const String ICON_NOISE = $embed("../../assets/icons/tree/noise.svg");
const String ICON_PULSE = $embed("../../assets/icons/tree/pulse.svg");
const String ICON_BASE = $embed("../../assets/icons/tree/base.svg");
const String ICON_SOLO = $embed("../../assets/icons/tree/solo.svg");
const String ICON_SOLO_OFF = $embed("../../assets/icons/tree/solo_off.svg");
const String ICON_CHIP = $embed("../../assets/icons/tree/chip.svg");

// Strip cells: the viewBox is the 28 x 22 cell.
const float STRIP_ICON_VIEW = 28.0;
const String ICON_WIREFRAME = $embed("../../assets/icons/strip/wireframe.svg");
const String ICON_SOLID = $embed("../../assets/icons/strip/solid.svg");
const String ICON_TEXTURED = $embed("../../assets/icons/strip/textured.svg");
const String ICON_TEXTURED_SHADE = $embed("../../assets/icons/strip/textured_shade.svg");
const String ICON_TEXTURED_LIGHT = $embed("../../assets/icons/strip/textured_light.svg");
const String ICON_TERRITORY = $embed("../../assets/icons/strip/territory.svg");
const String ICON_FALLOFF = $embed("../../assets/icons/strip/falloff.svg");
const String ICON_FALLOFF_INNER = $embed("../../assets/icons/strip/falloff_inner.svg");
const String ICON_FALLOFF_OUTER = $embed("../../assets/icons/strip/falloff_outer.svg");
const String ICON_UNUSED = $embed("../../assets/icons/strip/unused.svg");
const String ICON_DISC = $embed("../../assets/icons/strip/disc.svg");
const String ICON_ERASER = $embed("../../assets/icons/strip/eraser.svg");
const String ICON_UNDO = $embed("../../assets/icons/strip/undo.svg");
const String ICON_CLEAR = $embed("../../assets/icons/strip/clear.svg");
const String ICON_DONE = $embed("../../assets/icons/strip/done.svg");

// The padlock's viewBox is centred on the middle of the body's top edge.
const float LOCK_ICON_VIEW = 20.0;
const String ICON_LOCKED = $embed("../../assets/icons/lock/locked.svg");
const String ICON_UNLOCKED = $embed("../../assets/icons/lock/unlocked.svg");

<*
 A tree row's icon in its slot, at the scale the slot was drawn for.
*>
fn void paint_tree_icon(Painter* painter, Vec2 at, float size, String svg, Color ink)
{
	painter.icon(at, size * TREE_ICON_VIEW_SCALE, svg, ink);
}

const String ICON_GEAR = $embed("../../assets/icons/misc/gear.svg");

// The Joint panel's tab glyphs: viewBox centred 17 px down the tab.
const float JOINT_TAB_ICON_VIEW = 30.0;
const float JOINT_TAB_ICON_Y = 17.0;
const String ICON_TAB_JOINT = $embed("../../assets/icons/joint/joint.svg");
const String ICON_TAB_ALIGN = $embed("../../assets/icons/joint/align.svg");
const String ICON_TAB_WEIGHTS = $embed("../../assets/icons/joint/weights.svg");
const String ICON_TAB_POSE = $embed("../../assets/icons/joint/pose.svg");

<*
 The interaction path, with no window and no GPU.

 `c3c test --trust=full --test-filter crig_tests::ui`

 This is the gap B4 fell into. Building passed, the validation layers passed,
 the picking math passed and a screenshot looked right — while the viewport was
 receiving no mouse events whatsoever, because the control panel's element had
 been laid out over the entire window and won every hit test. Nothing that skips
 `Ui.process_input` can see that. So this pushes synthetic `InputFrame`s at the
 real `build_ui` tree and asserts the document changed.

 The three properties worth pinning, in the order they broke:

 places      a press and release on the model adds a dot, at the pixel it
 was clicked
 opaque      the same gesture on the menu bar adds nothing and does not
 move the camera
 see-through the same gesture on the HUD block, which is painted over the
 viewport, reaches the viewport anyway

 The mesh is a unit cube built here rather than a file on disk: the test is
 about dispatch, and a fixture that depends on someone's Downloads folder is
 one that stops being run.
*>
module crig_tests::ui;

import crig;
import libc;
import cui;
import cui::widgets;
import c3w;
import rig;
import gltf;
import collision;
import crig_tests::library;
import crig_tests::shared_app;
import std::core::test;
import std::io;
import std::math;

// The pane's tab strip, and the 3D view's own header below it: the single
// starting pane stacks both between the window menu bar and the viewport, so
// the viewport starts below all three.
const float TAB_H      = crig::AREA_STYLE.tab_height;
const float VIEW_BAR_H = crig::VIEW_BAR_H;

// Everything above the model, in one number: the window bar, the tab strip and
// the 3D view's header.
const float CHROME_H = crig::BAR_H + TAB_H + VIEW_BAR_H;

// The region the mesh renders into: the window minus that chrome. The
// projection works in viewport-LOCAL pixels; gestures arrive in WINDOW pixels,
// and since the bars pushed the viewport down the two now differ by
// VIEWPORT_ORIGIN — `pixel_of` folds the conversion in, and every constant
// below is a window coordinate a gesture can be aimed at.
const Vec2 VIEWPORT        = { crig::WIN_W, crig::WIN_H - CHROME_H };
const Vec2 VIEWPORT_ORIGIN = { 0.0, CHROME_H };

// Joints in the shipped quadruped pack (assets/animations/quadruped.glb): pelvis,
// spine, chest, neck, head, a two-joint tail and four three-joint legs.
const sz QUADRUPED_PACK_DOTS = 19;

const Vec2 VIEWPORT_CENTER = {
	crig::WIN_W * 0.5,
	CHROME_H + (crig::WIN_H - CHROME_H) * 0.5,
};

<*
 The fitted plan's own words, and how many dots it places.

 `apply_plan_named("biped")` fits whichever shipped pack carries that tag, and
 that is `humanoid.glb` — sixty-five joints under the names a downloaded clip
 uses, forty of them marked optional, so a fit places the twenty-five that are
 not. The checks below name joints to pose, to key and to count, and naming them
 here is what keeps a change of shipped plan one edit instead of twenty.

 It used to be `biped.glb`, whose plan spelled these `thigh_L`, `knee_L` and
 `ankle_L` and placed seventeen. That file no longer ships.
*>
const String PLAN_HIPS    = "hips";
const String PLAN_THIGH_L = "thigh_L";
const String PLAN_KNEE_L  = "knee_L";
const String PLAN_ANKLE_L = "ankle_L";
const String PLAN_THIGH_R = "thigh_R";
const String PLAN_KNEE_R  = "knee_R";
const String PLAN_ANKLE_R = "ankle_R";
const usz PLAN_DOTS = 25;

// A point on the window bar clear of every title, and a drag that starts there.
const Vec2 BAR_POINT = { crig::WIN_W * 0.5, crig::BAR_H * 0.5 };

// And one on the tab strip clear of the tabs.
const Vec2 STRIP_POINT = { crig::WIN_W * 0.5, crig::BAR_H + TAB_H * 0.5 };

// One on the 3D view's header, clear of both its titles and the tint strip.
const Vec2 VIEW_BAR_POINT = { crig::WIN_W * 0.5, crig::BAR_H + TAB_H + VIEW_BAR_H * 0.5 };

// Same tolerance as pick-test: a round trip through two float32 matrices.
const float PIXEL_TOLERANCE = 0.05;

const float DT = 0.016;

// Longer than CLICK_SLOP, so it reads as an orbit rather than a click.
const float DRAG_PIXELS = 40.0;

// Three well-separated points on the cube, for building a chain. Far enough
// apart that a click meant to place never lands within PICK_RADIUS of a dot
// already there, and well inside the silhouette at the framed distance.
const Vec2 SPOT_A = { VIEWPORT_CENTER[0] - 80.0, VIEWPORT_CENTER[1] - 60.0 };
const Vec2 SPOT_B = VIEWPORT_CENTER;
const Vec2 SPOT_C = { VIEWPORT_CENTER[0] + 80.0, VIEWPORT_CENTER[1] + 60.0 };

// Off to one side, so the point it snaps to is comfortably clear of the
// symmetry plane and definitely earns a mirror.
const Vec2 SPOT_LEFT = { VIEWPORT_CENTER[0] - 100.0, VIEWPORT_CENTER[1] };

// The shared fixture's 2-unit outward-wound cube.  Its immutable picker,
// voxels and shell table are built once for the whole test process.
fn rig::TriMesh cube() => shared_app::cube();

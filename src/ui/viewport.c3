<*
 The 3D view as a cui widget: the dot overlay, and every input the model
 responds to.

 Being a widget rather than a raw-input reader is what settles 2D-vs-3D
 arbitration. cui hit-tests in reverse paint order and the menu bar is painted
 after this, so a click on it never reaches the model — no coordinate test to
 keep in sync with the layout. Consuming a press also captures the pointer, so
 a drag that started on the goat keeps orbiting when it crosses the bar, which
 is what dragging should do and what B3 had to hand-roll.

 Keys are not handled here: the global shortcuts live on `AppRoot`, the tree's
 root, so they keep working whatever was clicked last — see ui_tree.c3.

 The overlay is 2D, not a second 3D pass: joints project to pixels each paint
 and draw as flat circles on top of everything. Always-on-top is what a rigging
 tool wants — a joint buried in the chest still has to be clickable — and it
 makes hit-testing a screen-space distance check rather than a ray cast.

 The one ambiguity is the left button, which both places dots and orbits. It is
 resolved the way AccuRig resolves it: a press that travels more than a few
 pixels was an orbit, and a press that comes back up where it went down was a
 click. Nothing is placed until release, so the two never fight.
*>
module crig;

import cui;
import cui::widgets;
import collision;
import rig;
import std::math;

// How far a left press may travel and still count as a click rather than an
// orbit. Small enough that a deliberate drag never places a dot, large enough
// to absorb the hand movement in a normal click.
const float CLICK_SLOP = 4.0;

// Screen-space grab radius for a dot, in pixels.
const float PICK_RADIUS = 12.0;

// Degrees of orbit per point of trackpad swipe, as a fraction of the drag rate.
// Below 1 because a scroll gesture is accelerated: a brisk two-finger flick
// reports several times the distance the fingers actually travelled, and at the
// drag rate that spins the model most of the way round.
const float TRACKPAD_ORBIT_RATIO = 0.5;

// Dolly notches per point of trackpad swipe. A wheel notch is one unit and a
// gesture is tens of points, so the same number means very different things
// coming from the two and they cannot share a scale. At this rate a swipe of
// about 190 points halves the distance to the model.
const float TRACKPAD_NOTCHES_PER_POINT = 0.05;

// What ctrl makes of a wheel notch: a quarter of one, so the camera creeps in
// on a knuckle instead of stepping past it. A whole notch is already the
// smallest a wheel can send — the detent is the resolution of the device — so
// the only way to go finer is to mean less by one.
//
// The wheel's modifier alone. On a trackpad ctrl is what tells a zoom from an
// orbit, and spending it twice there would leave that device no coarse zoom at
// all.
const float FINE_ZOOM_RATIO = 0.25;

const float DOT_RADIUS = 5.0;

// The brush circle: the tool itself, so it has to be findable while the pointer
// is moving.
const float BRUSH_RING_WIDTH = 1.5;
const float BRUSH_RING_DIM = 0.8;

const float DOT_BORDER = 1.5;
const float BONE_WIDTH = 3.0;

// Thinner than a bone: the move guides are scaffolding over the rig, not part
// of it.
const float GUIDE_WIDTH = 1.5;


// How far outside a dot the root's ring sits.
const float ROOT_RING_GAP = 4.0;

// The anchor ring, inside the root ring so a foot can wear both and the name-gap
// that clears the root ring clears this too.
const float LOCK_RING_GAP = 2.5;
const float LOCK_RING_WIDTH = 2.0;

// Gap between a dot and the name under it, in pixels. Clear of the root ring,
// which is the widest a dot can wear, so a name never sits inside one.
const float LABEL_GAP = DOT_RADIUS + ROOT_RING_GAP + 3.0;

// The plan's target for the selected dot: a hollow circle the size of a dot, so
// the offset reads as the distance between two things of the same kind, and the
// thin line joining it to the dot it belongs to.
const float TARGET_RADIUS = DOT_RADIUS;
const float TARGET_WIDTH = 1.5;
const float TARGET_LINE_WIDTH = 1.0;

// A look-at target's handle: a ring a little bigger than a dot with a triangle
// inside it, on a dashed line back to the joint that looks.
const float AIM_RADIUS = DOT_RADIUS + 3.0;
const float AIM_WIDTH = 1.5;
const float AIM_MUTED_DIM = 0.4;

// The ring on a contact that stopped a turn: a size up from a dot, so it
// reads as a place on the skin rather than as another joint.
const float CONTACT_RADIUS = DOT_RADIUS * 1.6;
const float CONTACT_WIDTH = 2.0;

struct Viewport (Widget)
{
	Vec2 size; // zero on an axis = fill the available space
	OrbitCamera camera;
	bool camera_ready;
	uint camera_reset_generation;

	// Camera state, latched on press. cui captures the pointer for the
	// duration, so this only has to record what the press decided, not
	// re-derive it. A dot being moved is `app.drag` instead of a field here:
	// the axis keys that steer it land on the tree's root, not on this widget.
	bool orbiting;
	bool panning;
	bool maybe_place; // a left press that has not yet travelled far enough to be a drag
	usz maybe_drag_aim; // 1 + the handle index of the target ring pressed; a drag past CLICK_SLOP moves the target
	uint maybe_drag_dot; // selected on press; becomes a pose (or Alt rest) drag past CLICK_SLOP
	bool maybe_rest_drag; // pressed with the Move tool: the drag moves the rest position, no Alt needed
	Vec2 press_at;

	// A grow (shift) or shrink (ctrl) drag in the Area tool: where it began and
	// how many rings it has moved the part so far.
	bool area_now;
	bool area_grows;
	Vec2 area_from;
	int area_rings;
	bool area_painting; // the area drag paints whole UV islands in or out
	Vec2 island_probe_at;

	<*
	 Whether a brush stroke is in flight, and which way it is painting.

	 Latched on the press: the modifiers are read once, at the start, so a shift pressed or released mid-stroke does
	 not turn a stroke that was adding into one that is taking away halfway
	 along — and a ctrl let go does not hand the rest of the stroke to the orbit.
	*>
	bool brushing_now;
	bool brush_adds;

	<*
	 Whether a lasso is being drawn in this pane.

	 The brush's latch, with the same job and one difference: it is also what says
	 the polygon on `AppState` belongs to *this* viewport. The points are pixels,
	 and two panes see the same app — so the pane that took the press is the pane
	 that draws the outline and the pane that closes it.

	 Which way the region acts and whether it reaches through the model are
	 latched on `AppState` beside the points, since `lasso_commit` is what reads
	 them and it is callable with no widget at all.
	*>
	bool lasso_now;
	bool sketch_now;

	<*
	 The brush-size gesture: whether it is running, where it began, and the radius
	 it began at.

	 Held-key rather than a mode of its own, and anchored rather than absolute:
	 the radius moves with how far the pointer has travelled sideways *since the
	 key went down*, so it starts exactly where it was instead of jumping to
	 wherever the cursor happens to be. Blender puts the cursor on the rim at that
	 moment; nothing here can move the cursor, so the anchor does the same job
	 from the other end.
	*>
	bool sizing_brush;
	Vec2 brush_anchor;
	float brush_from;

	// Where the pointer last was in this pane, for the turn ring to be drawn at.
	// On the widget rather than on the AppState because it is pixels, and pixels
	// belong to one pane — two panes see the same gesture and only the one the
	// pointer is over has anywhere to draw it. Nothing outlives a rebuild here:
	// the ring reappears on the next mouse move, which is the only time it can
	// be wrong and also the next thing that happens.
	Vec2 pointer;

	// The auto-connect preview: where a click would place the next joint, probed
	// on hover (only after the pointer travels CHAIN_PROBE_STEP) so it costs one
	// snap per few pixels.
	bool chain_valid;
	Vec3 chain_to;
	Vec2 chain_probe_at;
}

// Pixels the pointer travels before the preview bone's end is probed again.
const float CHAIN_PROBE_STEP = 3.0;
const float CHAIN_DASH = 6.0;
const float CHAIN_GAP = 4.0;
const float CHAIN_WIDTH = 1.5;

<*
 Declares the crosshair for the whole view.

 From mount rather than on_hover because hover fires on the deepest element
 only, and the gizmo, the toggles and the HUD sit on top of this one: a shape
 asked for on the way in would never be asked for at all when the pointer
 entered the view over an overlay. Resolution walks up from the hovered element,
 so declaring it once here answers for everything drawn inside.

 No layout to put it in either — the `size` field fills the pane and the
 annotations are laid out loosely on top of it, which is what cui does for a
 widget with no layout of its own.
*>
fn void Viewport.mount(&self, Element* elem) @dynamic
{
	elem.set_cursor(Cursor.CROSSHAIR);
	AppState* app = elem.inherit(AppState)!!;
	self.camera = app.camera;
	self.camera_ready = true;
	self.camera_reset_generation = app.camera_reset_generation;
	if (app.active_viewport == null) app.active_viewport = self;
}

// Leaving the view, or moving onto one of its overlays, drops the preview: a
// click there does not place a joint.
fn void Viewport.on_hover(&self, Element* elem, bool entered) @dynamic
{
	if (entered) return;
	AppState* hovered = elem.inherit(AppState)!!;
	hovered.aim_ring_hover = false;
	if (hovered.area_hover_island >= 0)
	{
		hovered.hover_area_island(-1);
		elem.request_paint();
	}
	if (!self.chain_valid) return;
	self.chain_valid = false;
	AppState* app = elem.inherit(AppState)!!;
	app.chain_preview = 0;
	elem.request_paint();
}

fn void Viewport.unmount(&self, Element* elem) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.transform_interaction.active && app.transform_interaction.viewport == self)
	{
		(void)app.finish_transform_interaction(false);
	}
	if (app.active_viewport != self) return;
	self.camera = app.camera;
	self.camera_reset_generation = app.camera_reset_generation;
	app.active_viewport = null;
}

fn OrbitCamera* Viewport.view_camera(&self, Element* elem)
{
	AppState* app = elem.inherit(AppState)!!;
	if (!self.camera_ready || self.camera_reset_generation != app.camera_reset_generation)
	{
		self.camera = app.camera;
		self.camera_ready = true;
		self.camera_reset_generation = app.camera_reset_generation;
	}
	return app.active_viewport == self ? &app.camera : &self.camera;
}

fn void Viewport.activate_camera(&self, Element* elem)
{
	AppState* app = elem.inherit(AppState)!!;
	if (self.camera_reset_generation != app.camera_reset_generation)
	{
		self.camera = app.camera;
		self.camera_ready = true;
		self.camera_reset_generation = app.camera_reset_generation;
	}
	if (app.active_viewport == self) return;
	if (app.active_viewport != null)
	{
		app.active_viewport.camera = app.camera;
		app.active_viewport.camera_ready = true;
		app.active_viewport.camera_reset_generation = app.camera_reset_generation;
	}
	if (self.camera_ready)
	{
		app.camera = self.camera;
	}
	else
	{
		self.camera = app.camera;
		self.camera_ready = true;
		self.camera_reset_generation = app.camera_reset_generation;
	}
	app.active_viewport = self;
	elem.ui.invalidate(OrbitCamera);
}


// The prompt's own type size, a step up from the HUD's: it is the only thing on
// screen when it shows, and it is an instruction rather than a readout.
const float PROMPT_TEXT_SIZE = 15.0;

const String PROMPT_NO_MESH @private = "no model loaded · File > Open model  (Ctrl+O)";
const String PROMPT_NO_RIG @private = "no skeleton · Rig > Apply body plan";

<*
 What the prompt has to say about the document as it stands, or the empty string
 when it has nothing to say.

 Two states, and they are the same kind of statement: something is missing, and
 here is the verb that ends it. The second one is the reason this became a
 function — a mesh with no skin used to leave the viewport looking finished, with
 the only route to a rig being a cell in a pane the user might not have open. A
 line that stays on screen is the right shape for that, where `@notice` is not:
 notices age out in eight seconds, and "your mesh has no skeleton" is true until
 it is acted on.
*>
fn String prompt_text(AppState* app) @private
{
	if (!app.has_mesh()) return PROMPT_NO_MESH;
	if (app.doc.dots.len() == 0) return PROMPT_NO_RIG;
	return "";
}

<*
 The line an incomplete 3D view shows: what is missing, and how to fix it.

 crig opens without a model, and an empty viewport is indistinguishable from one
 whose mesh failed to load or whose camera is pointing the wrong way. This says
 which it is, and names the command that ends it — the whole of what an empty
 state owes the user. A mesh with no rig is the same situation one step along.

 Transparent to the pointer, like the HUD: a click through it still reaches the
 model, which matters the moment one is loaded and the prompt goes away.
*>
struct OpenPrompt (Widget)
{
	// Measured by the last layout, so paint does not measure the same string
	// twice. The prompt is centred by its parent `Anchored`, which needs the
	// size layout returns.
	Vec2 measured;

	// What the last layout decided, kept as its own flag rather than read back
	// off `measured`: a font that has not finished loading measures to zero, and
	// inferring "hidden" from that would ask for a relayout on every frame for
	// as long as it lasted — which on an ON_DEMAND loop is a spin, not a stall.
	bool shown;
}

fn void OpenPrompt.mount(&self, Element* elem) @dynamic
{
	elem.ignores_pointer = true;
}

fn Vec2 OpenPrompt.layout(&self, Element* elem, Constraints constraints) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	// Zero-sized when there is nothing to say, which is what takes it out of the
	// picture without a second widget to switch between: `Anchored` centres a
	// zero-sized child harmlessly and paint below draws nothing.
	String line = prompt_text(app);
	self.shown = line.len > 0;
	self.measured = self.shown
		? elem.ui.text.measure(0, line, PROMPT_TEXT_SIZE)
		: (Vec2){ 0, 0 };
	return constraints.constrain(self.measured);
}

fn void OpenPrompt.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	String line = prompt_text(app);
	if (line.len == 0) return;

	painter.text({ 0, 0 }, line, { .size = PROMPT_TEXT_SIZE, .color = TEXT_DIM });
}

// Repaint and relayout when what there is to say changes — the prompt's size is
// what centres it, so a stale layout leaves it hanging off centre by half its
// own width rather than merely painting the wrong line. Compared against
// `shown` rather than against the text so that switching between the two
// sentences relayouts too: they are different widths.
fn void OpenPrompt.update(&self, Element* elem, float dt) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	String line = prompt_text(app);
	if (self.shown != (line.len > 0) || (self.shown && elem.ui.text.measure(0, line, PROMPT_TEXT_SIZE) != self.measured))
	{
		elem.request_layout();
	}
}

<*
 Draw the rig over the mesh.

 `elem.size` is the projection's viewport, and it is also the region three
 renders the model into — same aspect, same origin, because `sync_views`
 pushes this element's own rect — so a dot painted here lands exactly on the
 geometry it was snapped to.

 Every position read here comes from `AppState.dot_position` rather than from
 the dot itself, which is what makes the rig travel with the body while a clip
 plays. At rest the two are the same value.
*>
fn void Viewport.paint(&self, Element* elem, Painter* painter) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;

	// Before every early return below, because it is the one thing here that is
	// true whether or not there is a rig to draw: where in the window the model
	// is being shown. `render` crops to it, and stores it as a share of the
	// window rather than as pixels so that neither of them has to know the
	// display's scale — a screenshot is device pixels and this is UI points.
	if (app.active_viewport == self && elem.ui && elem.ui.size.x > 0 && elem.ui.size.y > 0)
	{
		app.viewport_share = {
			elem.absolute.x / elem.ui.size.x,
			elem.absolute.y / elem.ui.size.y,
			(elem.absolute.x + elem.size.x) / elem.ui.size.x,
			(elem.absolute.y + elem.size.y) / elem.ui.size.y,
		};
	}

	// Before the rig check, unlike everything else here: the brush paints the
	// mesh, so hiding the rig is a reasonable thing to do while using it — and a
	// brush with no circle is a mode with no size, which reads as broken.
	if (app.brushing)
	{
		// The colour says which way the next press would paint: the latched
		// direction during a stroke, and between strokes the one the keys held
		// right now would start — so ctrl going down turns the ring before the
		// button does, and the ring is how the two directions are told apart.
		Input* input = &elem.ui.input;
		bool ctrl = input.ctrl_down();
		bool shift = input.shift_down();
		bool adds = self.brushing_now ? self.brush_adds : (ctrl ? !shift : !app.brush_removes);
		painter.circle(self.sizing_brush ? self.brush_anchor : self.pointer, app.brush_radius, {
			.border_width = BRUSH_RING_WIDTH,
			.border_color = adds
				? BRUSH_ADDING.dim(BRUSH_RING_DIM)
				: BRUSH_TAKING.dim(BRUSH_RING_DIM),
		});
	}

	// Beside the brush ring and above the rig gate for the same reason: the
	// region is drawn over the *mesh*, and hiding the skeleton is a reasonable
	// thing to do while aiming one. Only in the pane that took the press — the
	// points are this pane's pixels and mean nothing in the one next door.
	if (self.lasso_now) self.paint_lasso(painter, app);
	self.paint_annotations(painter, app, elem.size);

	// The global watch schedules paints for the active camera; the value itself is
	// pane-local so split views may be aimed independently.
	(void)elem.watch(OrbitCamera)!!;
	OrbitCamera* camera = self.view_camera(elem);
	Matrix4f view_projection = app.model_view_projection(camera, elem.size.x / elem.size.y);

	// The whole overlay, not the dots alone: with the rig hidden the bones, the
	// names and the plan's ring go with it, and nothing here is clickable either
	// — see `pick_dot`.
	if (!app.show_rig)
	{
		self.paint_transform_gizmo(elem, painter);
		return;
	}

	RigDocument* doc = &app.doc;
	if (doc.dots.len() == 0)
	{
		self.paint_transform_gizmo(elem, painter);
		return;
	}
	Vec3 forward = app.model_direction((camera.target - camera.eye()).normalize());
	Vec3 model_eye = app.model_eye(camera);
	float near_depth = app.dot_position(doc.dots.array_view()[0]).dot(forward);
	float far_depth = near_depth;
	foreach (dot : doc.dots.array_view())
	{
		float depth = app.dot_position(dot).dot(forward);
		near_depth = math::min(near_depth, depth);
		far_depth = math::max(far_depth, depth);
	}
	float overlay_strength = effective_rig_overlay_strength(app);

	// Under the live rig: the ghosts are context, not something to aim at.
	self.paint_ghosts(elem, painter, view_projection, app);

	// Bones first, so a dot always sits on top of the lines meeting at it.
	foreach (edge : doc.edges.array_view())
	{
		Dot* a = doc.find(edge.a);
		Dot* b = doc.find(edge.b);
		if (!a || !b) continue;

		Vec2? from = project(view_projection, app.dot_position(*a), elem.size);
		Vec2? to = project(view_projection, app.dot_position(*b), elem.size);
		if (catch from) continue;
		if (catch to) continue;

		// Both ends, not either: the bone *into* a chain's first joint is the
		// animation's — what the solver owns is the segment leaving it — so a
		// tinted edge means "the physics moves this line", which is exactly the
		// run between consecutive dynamic joints.
		bool simulated = app.show_physics && app.is_dynamic(edge.a) && app.is_dynamic(edge.b);
		Vec3 midpoint = (app.dot_position(*a) + app.dot_position(*b)) * 0.5f;
		bool hidden = app.overlay_occluded(overlay_bone_key(edge.a, edge.b), model_eye, midpoint);
		bool selected = app.is_selected(a.id) && app.is_selected(b.id);
		float opacity = rig_overlay_opacity(midpoint.dot(forward), near_depth, far_depth, hidden, selected, overlay_strength);
		painter.line(from, to, selected ? BONE_WIDTH : BONE_WIDTH * 0.65f,
			rig_overlay_ink(simulated ? PHYSICS_BONE : BONE, opacity));
	}

	// Between the bones and the dots, like the guides: a capsule is drawn around
	// a limb that is already there, and it must not sit over the dots whose
	// positions are what a rigger is actually aiming at.
	if (app.show_physics) self.paint_colliders(elem, painter, view_projection, camera);

	self.paint_chain_preview(elem, painter, view_projection, app);
	self.paint_motion_path(elem, painter, view_projection, app);

	// Between the bones and the dots: a guide is worth more than a bone it
	// crosses and less than the dot it is about.
	self.paint_move_guides(elem, painter, view_projection);
	self.paint_plan_target(elem, painter, view_projection);
	self.paint_aim_targets(elem, painter, view_projection);
	self.paint_contact(elem, painter, view_projection);

	foreach (dot : doc.dots.array_view())
	{
		Vec3 position = app.dot_position(dot);
		Vec2? at = project(view_projection, position, elem.size);
		if (catch at) continue;

		// Every member of the selection takes the selected fill; only the anchor
		// takes the extra pixel. The two states are different things and both
		// have to be readable at once — the fill answers "does X take this one",
		// the size answers "is this the dot attach and the falloff view are
		// about, and the head of the chain C would bond".
		bool selected = app.is_selected(dot.id);
		bool anchor = dot.id == app.selected;
		bool root = dot.id == doc.root_id;

		bool occluded = app.overlay_occluded(dot.id, model_eye, position);
		float opacity = rig_overlay_opacity(position.dot(forward), near_depth, far_depth, occluded, selected, overlay_strength);
		float radius = selected ? DOT_RADIUS : DOT_RADIUS * 0.65f;

		if (root)
		{
			// A ring rather than a different fill: the root can also be
			// selected, and two states have to be readable at once.
			painter.circle(at, radius + ROOT_RING_GAP, {
				.border_width = DOT_BORDER,
				.border_color = rig_overlay_ink(DOT_ROOT, opacity),
			});
		}

		// A ring too, and for the root ring's reason: a dynamic joint is usually
		// also selected while it is being tuned, and the fill is already saying
		// that. Inside the root's ring so a dot can wear both.
		//
		// On the joint rather than only on the bones leaving it, because the first
		// joint of a chain has no tinted bone to its parent — its own segment is
		// simulated, the one arriving at it is not — and without this it would be
		// the one dynamic bone in a tail that looked like it was not.
		if (app.show_physics && app.is_dynamic(dot.id))
		{
			painter.circle(at, radius + PHYSICS_RING_GAP, {
				.border_width = PHYSICS_RING_WIDTH,
				.border_color = rig_overlay_ink(PHYSICS_BONE, opacity),
			});
		}

		// An anchored joint wears a ring the way the root does, and for the same
		// reason: it is usually the selected joint too, and the fill already says
		// that — the ring is the second state, "held in place while others move".
		if (app.is_anchored(dot.id))
		{
			painter.circle(at, radius + LOCK_RING_GAP, {
				.border_width = LOCK_RING_WIDTH,
				.border_color = rig_overlay_ink(DOT_LOCKED, opacity),
			});
		}

		Color fill = selected ? DOT_SELECTED : DOT;
		Color outline = DOT_OUTLINE;
		painter.circle(at, anchor ? radius + 1.0f : radius, {
			.color = rig_overlay_ink(fill, opacity),
			.border_width = DOT_BORDER,
			.border_color = rig_overlay_ink(outline, opacity),
		});
	}

	// Last, so a name is never buried under a dot. Names are wider than dots and
	// the rig is dense around the chest and the hips, so with the toggle on some
	// of them will overlap something whatever order they are drawn in — but a
	// name half under a circle is unreadable, where two names side by side are
	// merely crowded.
	self.paint_joint_names(elem, painter, view_projection, camera);
	self.paint_transform_gizmo(elem, painter);
}

const float GHOST_BONE_WIDTH = 2.0;
const float GHOST_DOT_RADIUS = 2.5;
const float PATH_WIDTH = 1.5;
const float PATH_KEY_RADIUS = 3.0;
const float PATH_HEAD_RADIUS = 5.5;

fn Vec3? ghost_at(GhostPose* ghost, uint dot) @private
{
	foreach (posed : ghost.dots)
	{
		if (posed.dot == dot) return posed.at;
	}
	return NOT_FOUND~;
}

<*
 The keys either side of the playhead as faint skeletons, cool behind and warm
 ahead, fainter with each key further out. No occlusion test: flat and cheap.
*>
fn void Viewport.paint_ghosts(&self, Element* elem, Painter* painter, Matrix4f view_projection, AppState* app)
{
	GhostPose[] ghosts = app.ghost_poses();
	RigDocument* doc = &app.doc;
	foreach (&ghost : ghosts)
	{
		Color base = ghost.before ? ONION_BEFORE : ONION_AFTER;
		Color ink = rig_overlay_ink(base, 1.0f / (float)ghost.step);
		foreach (edge : doc.edges.array_view())
		{
			Vec3? a = ghost_at(ghost, edge.a);
			Vec3? b = ghost_at(ghost, edge.b);
			if (catch a) continue;
			if (catch b) continue;
			Vec2? from = project(view_projection, a, elem.size);
			Vec2? to = project(view_projection, b, elem.size);
			if (catch from) continue;
			if (catch to) continue;
			painter.line(from, to, GHOST_BONE_WIDTH, ink);
		}
		foreach (posed : ghost.dots)
		{
			Vec2? at = project(view_projection, posed.at, elem.size);
			if (catch at) continue;
			painter.circle(at, GHOST_DOT_RADIUS, { .color = ink });
		}
	}
}

<*
 The selected joint's path through the clip: a polyline at the display fps, a
 dot at each key, and a ring where the playhead is on it.
*>
fn void Viewport.paint_motion_path(&self, Element* elem, Painter* painter, Matrix4f view_projection, AppState* app)
{
	MotionPath* path = app.selected_motion_path();
	if (!path) return;
	Vec2? last = NOT_FOUND~;
	foreach (point : path.points)
	{
		Vec2? at = project(view_projection, point, elem.size);
		if (try at)
		{
			if (try from = last) painter.line(from, at, PATH_WIDTH, MOTION_PATH);
		}
		last = at;
	}
	foreach (point : path.key_points)
	{
		Vec2? at = project(view_projection, point, elem.size);
		if (catch at) continue;
		painter.circle(at, PATH_KEY_RADIUS, { .color = MOTION_KEY, .border_width = 1.0f, .border_color = DOT_OUTLINE });
	}
	Vec2? head = project(view_projection, path.at(app.onion_playhead()), elem.size);
	if (try head)
	{
		painter.circle(head, PATH_HEAD_RADIUS, { .border_width = 1.5f, .border_color = MOTION_PATH });
	}
}

<*
 Whether a click on the mesh right now would place a joint chained to the
 selected one: auto-connect on, a joint selected, placing allowed, and no tool
 or gesture that takes the click for something else.
*>
fn bool chaining_ready(AppState* app)
{
	return app.doc.auto_connect && app.selected != 0 && app.doc.find(app.selected) != null
		&& placement_refused(app).len == 0
		&& !app.brushing && !app.lassoing && !app.areaing
		&& app.transform_tool == SELECT_TOOL && !app.transform_interaction.active
		&& app.drag.dot == 0;
}

<*
 Re-probes where a click would place the next joint, on a hover move. The same
 snap the click uses, so the preview ends exactly where the joint would land.
*>
fn void Viewport.probe_chain(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (!chaining_ready(app) || self.maybe_drag_dot != 0)
	{
		if (self.chain_valid)
		{
			self.chain_valid = false;
			app.chain_preview = 0;
			elem.request_paint();
		}
		return;
	}
	if (self.chain_valid && app.chain_preview == app.selected
		&& (pixel - self.chain_probe_at).length() < CHAIN_PROBE_STEP) return;
	self.chain_probe_at = pixel;

	Vec3? at = self.snap(elem, pixel);
	bool was = self.chain_valid;
	if (try at)
	{
		self.chain_valid = true;
		self.chain_to = at;
		app.chain_preview = app.selected;
	}
	else
	{
		self.chain_valid = false;
		app.chain_preview = 0;
	}
	if (was || self.chain_valid) elem.request_paint();
}

<*
 Re-reads the UV island under the pointer while the Area tool picks islands, so
 the picture can light the one a click would add or take out.
*>
fn void Viewport.probe_island(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (!app.areaing || !app.area_islands)
	{
		if (app.area_hover_island >= 0) app.hover_area_island(-1);
		return;
	}
	if ((pixel - self.island_probe_at).length() < CHAIN_PROBE_STEP) return;
	self.island_probe_at = pixel;
	int was = app.area_hover_island;
	app.hover_area_island(app.island_under(self.vertex_at(elem, pixel)));
	if (app.area_hover_island != was) elem.request_paint();
}

<*
 A dashed line between two pixels, the dash and the gap the chain preview draws.
*>
fn void paint_dashed(Painter* painter, Vec2 from, Vec2 to, float width, Color ink)
{
	Vec2 span = to - from;
	float length = span.length();
	if (length <= 0.5f) return;
	Vec2 dir = span / length;
	for (float t = 0.0f; t < length; t += CHAIN_DASH + CHAIN_GAP)
	{
		float end = math::min(t + CHAIN_DASH, length);
		painter.line(from + dir * t, from + dir * end, width, ink);
	}
}

<*
 The dashed bone from the selected joint to where a click would place the next
 one, while auto-connect would bond them.
*>
fn void Viewport.paint_chain_preview(&self, Element* elem, Painter* painter, Matrix4f view_projection,
	AppState* app)
{
	if (!self.chain_valid || app.chain_preview != app.selected || !chaining_ready(app)) return;
	Dot* from_dot = app.doc.find(app.selected);
	if (!from_dot) return;

	Vec2? from = project(view_projection, app.dot_position(*from_dot), elem.size);
	Vec2? to = project(view_projection, self.chain_to, elem.size);
	if (catch from) return;
	if (catch to) return;

	Color ink = BONE.dim(0.9f);
	paint_dashed(painter, from, to, CHAIN_WIDTH, ink);
	painter.circle(to, DOT_RADIUS * 0.65f, { .border_width = DOT_BORDER, .border_color = ink });
}

<*
 The region being drawn, as an outline.

 Outline and not a fill: `Painter` draws rects, circles, lines and text, and a
 filled polygon is a triangulation and a shader — which is a renderer change for
 a hint that lasts as long as a drag. The line back to the start is what makes
 the shape read as an area anyway, and it is dimmed because it is the one part
 of the boundary the hand did not draw.

 The points are this pane's own pixels, which is the same space `painter.line`
 takes and the same one `project` answers in — so nothing is converted here.

 The colour says which of the two jobs the region is about to be handed to, and
 which way round: one tool drawing one outline in one colour would leave the only
 difference between pinning a shoulder and selecting the joints in it on a bar at
 the bottom of the screen, while the hand is watching the outline.
*>
fn void Viewport.paint_annotations(&self, Painter* painter, AppState* app, Vec2 size)
{
	if (!app.hide_annotations)
	{
		foreach (mark : app.annotations.array_view())
		{
			Color ink = sketch_ink_color(mark.ink);
			foreach (i, point : mark.points)
			{
				if (i == 0) continue;
				painter.line({ mark.points[i - 1].x * size.x, mark.points[i - 1].y * size.y },
					{ point.x * size.x, point.y * size.y }, SKETCH_WIDTH, ink);
			}
		}
	}
	if (self.sketch_now && !app.sketch_erasing)
	{
		Vec2[] live = app.sketch_points.array_view();
		Color ink = sketch_ink_color(app.sketch_ink);
		for (usz i = 1; i < live.len; i++) painter.line(live[i - 1], live[i], SKETCH_WIDTH, ink);
	}
}

fn Color sketch_ink_color(SketchInk ink)
{
	switch (ink)
	{
		case RED: return SKETCH_RED;
		case GREEN: return SKETCH_GREEN;
		case BLUE: return SKETCH_BLUE;
	}
}

fn void Viewport.paint_lasso(&self, Painter* painter, AppState* app)
{
	Vec2[] points = app.lasso_points.array_view();
	if (points.len < 2) return;

	Color ink = LASSO_SELECTING;
	if (app.lasso_removes)
	{
		ink = LASSO_CLEARING;
	}
	else if (app.lasso_job == LassoJob.PIN)
	{
		ink = LASSO_PINNING;
	}
	for (usz i = 1; i < points.len; i++)
	{
		painter.line(points[i - 1], points[i], LASSO_WIDTH, ink);
	}
	painter.line(points[points.len - 1], points[0], LASSO_WIDTH, ink.dim(LASSO_CLOSE_DIM));
}


<*
 How thick each collider capsule is, drawn where it sits.

 A circle at the dot rather than the swept capsule down the whole bone. The
 radius is the number a user is checking — a capsule too thin lets a tail through
 the body and one too fat holds it off in mid-air — and the bone it is swept
 along is already on screen as the line leaving this dot. Drawing the sleeve
 itself would mean deciding which child the bone points at, and the rule for that
 lives in `Skeleton.tails`, where it is chosen by which child continues
 straightest; a second copy of it here is a second answer waiting to disagree
 with the solver's.

 Struck along the camera's right: it is the one direction that stays unforeshortened whatever the orbit is doing, so the
 circle reports a distance in the model rather than a number that shrinks as the
 view turns.
*>
fn void Viewport.paint_colliders(&self, Element* elem, Painter* painter,
	Matrix4f view_projection, OrbitCamera* camera)
{
	AppState* app = elem.inherit(AppState)!!;
	if (app.doc.colliders.len() == 0) return;

	Vec3 right = camera_right(app, camera);

	foreach (entry : app.doc.colliders.array_view())
	{
		if (entry.radius <= 0.0f) continue;

		Dot* dot = app.doc.find(entry.dot_id);
		if (!dot) continue;

		Vec3 position = app.dot_position(*dot);
		Vec2? at = project(view_projection, position, elem.size);
		if (catch at) continue;

		Vec2? edge = project(view_projection, position + right * entry.radius, elem.size);
		if (catch edge) continue;

		painter.circle(at, (edge - at).length(), {
			.border_width = PHYSICS_CAPSULE_WIDTH,
			.border_color = PHYSICS_CAPSULE,
		});
	}
}

<*
 The name of each dot, printed under it.

 What the toggle controls is the *rest* of them: the selected dot's name is
 drawn whether it is on or off, because that is the one name a user is always
 asking for and turning a view on to read it is a step for nothing.

 Occlusion is tested here rather than carried over from the dot loop. It costs a
 second ray through the mesh per named dot, which buys a loop that can be read
 on its own and only runs when there is something to print — with the toggle off
 that is one dot, not seventeen.
*>
fn void Viewport.paint_joint_names(&self, Element* elem, Painter* painter,
	Matrix4f view_projection, OrbitCamera* camera)
{
	AppState* app = elem.inherit(AppState)!!;

	foreach (dot : app.doc.dots.array_view())
	{
		if (dot.name.len == 0) continue;

		bool selected = dot.id == app.selected;
		if (!selected && !app.show_joint_names) continue;

		Vec3 position = app.dot_position(dot);
		Vec2? at = project(view_projection, position, elem.size);
		if (catch at) continue;

		bool occluded = app.overlay_occluded(dot.id, app.model_eye(camera), position);

		Color ink = selected ? LABEL : LABEL_DIM;
		if (!selected)
		{
			float opacity = effective_rig_overlay_strength(app) * (occluded ? 0.35f : 1.0f);
			ink = rig_overlay_ink(ink, opacity);
		}

		// Centred under the dot, which is why the run is measured first: printed
		// from the dot's own x, a long name would hang off to one side and read
		// as belonging to whatever it drifted over.
		Vec2 size = elem.ui.text.measure(0, dot.name, LABEL_SIZE);
		painter.text({ at.x - size.x * 0.5f, at.y + LABEL_GAP }, dot.name,
			{ .size = LABEL_SIZE, .color = ink });
	}
}

<*
 Where the body plan wants the selected dot: a hollow ring at the target, and a
 line from the dot to it.

 This is the answer to "is this dot in the right place", and it is a picture
 rather than a number because the number alone does not say which way to drag.
 A plan is fitted to the mesh's bounding box and then snapped to the nearest
 solid cell, and both steps can be wrong in ways only the offset shows — a dot
 pulled into the wrong limb, or a plan fitted to a pose it does not describe.

 Behind N, with the joint names, because a plan is a guess and this is the view
 that shows the guesses. A plan is fitted to a bounding box, so on a body the
 preset does not describe — anything that is not a bare humanoid — most of its
 targets are somewhere the dot has no business being, and a ring painted on
 every selection would be a standing instruction to drag the rig wrong.

 Nothing is drawn when the dot is already where the plan wants it either; that
 threshold is `AppState.selected_plan_target`.

 Nothing is drawn while a clip is playing. A plan places its dots on the
 body as it was modelled, so the offset is a question about the rest rig, and a
 line drawn from a dot mid-stride to a target standing still measures two
 different moments against each other.

 Drawn under the dots on purpose: the ring marks a place the rig is not, and it
 must not cover the dot it is about.
*>
fn void Viewport.paint_plan_target(&self, Element* elem, Painter* painter, Matrix4f view_projection)
{
	AppState* app = elem.inherit(AppState)!!;
	// A plan target says where a body plan wants this joint, which is a statement
	// about the rest rig — meaningless drawn against a body that has been carried
	// somewhere else, by a clip or by hand.
	if (app.rig_locked() || !app.show_joint_names) return;

	Vec3? target = app.selected_plan_target();
	if (catch target) return;

	Dot* dot = app.doc.find(app.selected);
	if (!dot) return;

	Vec2? to = project(view_projection, target, elem.size);
	if (catch to) return;

	if (try Vec2 from = project(view_projection, dot.position, elem.size))
	{
		painter.line(from, to, TARGET_LINE_WIDTH, TARGET_LINE);
	}

	painter.circle(to, TARGET_RADIUS, {
		.border_width = TARGET_WIDTH,
		.border_color = TARGET_RING,
	});
}

<*
 Whether the look-at handles are on screen: with the rig, and not while the rig
 itself is being edited, where nothing is posed and a target means nothing.
*>
fn bool aim_handles_shown(AppState* app)
{
	return app.show_rig && app.stage != JOINTS_STAGE && app.posed_aims.len > 0;
}

<*
 Each look-at target: a dashed line from the joint that looks, a ring at the
 target and a triangle in it. Lit while its joint is selected, dim while muted.
 Drawn under the dots like the plan's target, and not clickable by anything but
 `pick_aim`.
*>
fn void Viewport.paint_aim_targets(&self, Element* elem, Painter* painter, Matrix4f view_projection)
{
	AppState* app = elem.inherit(AppState)!!;
	if (!aim_handles_shown(app)) return;

	foreach (usz i, handle : app.posed_aims)
	{
		Vec2? to = project(view_projection, handle.at, elem.size);
		if (catch to) continue;

		bool chosen = app.aim_target_selected == handle.target;
		bool lit = chosen || (app.drag.verb == DragVerb.AIM && app.drag.aim == i);
		Color ring = lit ? AIM_SELECTED : AIM_RING;
		Color line = lit ? AIM_SELECTED.dim(0.6f) : AIM_LINE;
		if (handle.muted)
		{
			ring = ring.dim(AIM_MUTED_DIM);
			line = line.dim(AIM_MUTED_DIM);
		}

		foreach (link : app.posed_aim_links)
		{
			if (link.handle != i) continue;
			Color dashed = link.muted && !handle.muted ? line.dim(AIM_MUTED_DIM) : line;
			if (try Vec2 from = project(view_projection, link.joint_at, elem.size))
			{
				paint_dashed(painter, from, to, TARGET_LINE_WIDTH, dashed);
			}
		}
		painter.circle(to, AIM_RADIUS, { .border_width = AIM_WIDTH, .border_color = ring });

		// The triangle, pointing up, a little under the middle so it reads as centred.
		float r = AIM_RADIUS * 0.5f;
		Vec2 top = { to.x, to.y - r };
		Vec2 left = { to.x - r * 0.9f, to.y + r * 0.6f };
		Vec2 right = { to.x + r * 0.9f, to.y + r * 0.6f };
		painter.line(top, left, AIM_WIDTH, ring);
		painter.line(left, right, AIM_WIDTH, ring);
		painter.line(right, top, AIM_WIDTH, ring);
	}
}

<*
 Where the mesh stopped a turn or a pull, when the Advanced dialog asked to
 see it: a ring on each side of the contact and the gap between them, for
 as long as the pose it was found against is the one on screen — through
 the release and the key it lands, until a scrub, a step of history or the
 next gesture replaces the pose. Off by default: a joint that stops at the
 body is the whole of what the check ordinarily shows.
*>
fn void Viewport.paint_contact(&self, Element* elem, Painter* painter, Matrix4f view_projection)
{
	AppState* app = elem.inherit(AppState)!!;
	if (!app.config.self_collision || !app.show_collision_contacts) return;
	CollisionBlock block = app.last_block;
	if (!block.blocked || !block.contact.hit || block.shown_at != app.pose_generation) return;

	Vec2? on_a = project(view_projection, block.contact.gap.on_a, elem.size);
	Vec2? on_b = project(view_projection, block.contact.gap.on_b, elem.size);
	if (catch on_a) return;
	if (try Vec2 other = on_b)
	{
		painter.line(on_a, other, CONTACT_WIDTH, CONTACT_RING);
		painter.circle(other, CONTACT_RADIUS * 0.6f, {
			.border_width = CONTACT_WIDTH,
			.border_color = CONTACT_RING,
		});
	}
	painter.circle(on_a, CONTACT_RADIUS, {
		.border_width = CONTACT_WIDTH,
		.border_color = CONTACT_RING,
	});
}


<*
 Draws what a move in progress is doing: where the dot was grabbed, how far it
 has come, and the line or plane it is confined to.

 The picture is the point of the feature. A dot under the pointer tells you
 nothing about which way it is travelling in a view that is not axis-aligned,
 and the two coordinates a free drag changes are not the two the user thinks
 they are changing. The ghost and the trail answer that without a lock; the
 constraint line, in the same colour the corner gizmo uses for that axis,
 answers it with one.
*>
fn void Viewport.paint_move_guides(&self, Element* elem, Painter* painter, Matrix4f view_projection)
{
	AppState* app = elem.inherit(AppState)!!;

	DragState drag = app.drag;
	if (drag.dot == 0) return;

	Dot* dot = drag.verb == DragVerb.AIM ? null : app.doc.find(drag.dot);
	if (!dot && drag.verb != DragVerb.AIM) return;

	// Where the thing being dragged is *now*. For a rest move that is the dot's
	// own position; for a pose it is wherever the solve has carried the joint,
	// which is what `dot_position` answers and what is drawn on screen.
	Vec3 at = drag.from;
	if (dot) at = drag.verb == DragVerb.PLACE ? dot.position : app.dot_position(*dot);
	// A target drag moves the target, not the joint: the ghost trails from where
	// the target was grabbed to where it is now.
	if (drag.verb == DragVerb.AIM)
	{
		at = drag.aim < app.posed_aims.len ? app.posed_aims[drag.aim].at : drag.from;
	}

	// A turn reads the three keys as the axis it spins about rather than a line
	// to travel along, so there is no constraint line to draw — the guide for it
	// is the ring below.
	if (drag.axis.is_direction() && drag.verb != DragVerb.TURN)
	{
		// A body length either way, so the line reads as a direction through
		// the model rather than a segment between two arbitrary points.
		//
		// Through `project_segment` and not two `project` calls, which is the
		// whole reason the line used to vanish: a body length either way from a
		// joint puts one end behind the eye as soon as the camera comes in — which
		// is exactly when a lock is being used — and a caller that needs both ends
		// to project draws nothing at the moment it is most wanted.
		Vec3 reach = drag.lock_direction * app.picker.scale;
		if (try Vec2[2] line = project_segment(view_projection, drag.from - reach, drag.from + reach, elem.size))
		{
			painter.line(line[0], line[1], GUIDE_WIDTH, drag.axis.color().dim(GUIDE_DIM));
		}
	}
	else if (drag.axis.is_plane() && drag.verb != DragVerb.TURN)
	{
		// Two crossed directions say "this plane" without laying an opaque quad
		// over the mesh being posed. Each keeps its ordinary world-axis colour.
		int normal = drag.axis.plane_normal_component();
		for (int axis = 0; axis < 3; axis++)
		{
			if (axis == normal) continue;
			Vec3 reach = AXIS_DIRECTION[axis] * app.picker.scale;
			if (try Vec2[2] line = project_segment(view_projection,
				drag.from - reach, drag.from + reach, elem.size))
			{
				painter.line(line[0], line[1], GUIDE_WIDTH,
					((DragAxis)(axis + 1)).color().dim(GUIDE_DIM));
			}
		}
	}

	if (try Vec2 start = project(view_projection, drag.from, elem.size))
	{
		if (try Vec2 now = project(view_projection, at, elem.size))
		{
			painter.line(start, now, GUIDE_WIDTH, GHOST);
		}

		// Hollow, so it reads as the space the dot left rather than a second dot.
		painter.circle(start, DOT_RADIUS, { .border_width = DOT_BORDER, .border_color = GHOST });

		// A turn moves nothing, so the trail above is a point and says nothing.
		// Keep only a spoke from the pivot to the pointer as feedback for the
		// angular sweep — and nothing at all around the joint: the rings that
		// used to sit here hid exactly the hand or head being turned, which is
		// why the axes live on the Joint card's dials now. A dial's turn never
		// anchors, so it draws no spoke either.
		if (drag.verb == DragVerb.TURN && drag.anchor.y >= 0.0f)
		{
			Color spoke = drag.axis == DragAxis.FREE ? GHOST : drag.axis.color().dim(GUIDE_DIM);
			painter.line(start, self.pointer, GUIDE_WIDTH, spoke);
		}
	}
}

<*
 Why a click on the model cannot become a dot right now, or an empty string
 when it can.

 Every answer is said out loud rather than swallowed. Clicking the body is what
 places dots every other moment, so a click that quietly does nothing reads as a
 broken pointer rather than as a mode.

 No mesh is the flattest of the three: a dot goes *inside* a model, and there is
 no inside to put one in. Hiding the rig is the next: a dot placed into a hidden
 overlay is one the user cannot see, select or undo by eye. A running clip is the
 subtle one — the ray still finds the body it was modelled in, so the dot would
 land correctly in a pose nobody is looking at, which on screen is simply the
 wrong place.
*>
fn String placement_refused(AppState* app) @private
{
	if (!app.has_mesh()) return "no model loaded — File > Open model opens one";
	if (!app.show_rig) return "the rig is hidden — View > Skeleton brings it back";
	if (app.animating) return "stop the clip to place joints: the body on screen is posed";
	if (app.pose_edit_active) return "save or discard the animation pose before editing the rig";
	return "";
}

fn bool Viewport.on_mouse(&self, Element* elem, MouseEvent event) @dynamic
{
	AppState* app = elem.inherit(AppState)!!;
	Input* input = &elem.ui.input;

	switch (event.kind)
	{
		case PRESS:
			self.activate_camera(elem);
			// A header's click-catcher only blankets its own pane, so a dropdown
			// left open in the pane next door never hears about this press. It is
			// never this pane's own dropdown being closed here: while that one is
			// open its catcher is over the model and the viewport gets nothing.
			close_menus(elem.ui);

			if (app.transform_interaction.active)
			{
				if (event.button == LEFT)
				{
					(void)app.finish_transform_interaction(true);
					elem.request_paint();
					return true;
				}
				if (event.button == RIGHT)
				{
					(void)app.finish_transform_interaction(false);
					elem.request_paint();
					return true;
				}
			}

			switch (event.button)
			{
				case LEFT:
					if (app.transform_tool != SELECT_TOOL && transform_tool_claims_pointer(app))
					{
						TransformGizmoPart part = self.hit_transform_gizmo(elem, event.pos);
						// The middle over a joint is that joint's own drag below, which
						// lands it on the model; over nothing it is a free move.
						if (part == GIZMO_FREE && self.pick_dot(elem, event.pos) != 0) part = NO_GIZMO_PART;
						if (part != NO_GIZMO_PART && transform_tool_poses(app))
						{
							// Posing: the arrow is G held to its axis, the ring R held to its
							// own, and the release ends it like a joint drag. The joint moves
							// by what the pointer moves from here, not to the pointer.
							DragAxis axis = gizmo_axis(part);
							if (app.transform_tool == MOVE_TOOL)
							{
								if (app.begin_pose(true))
								{
									if (axis != DragAxis.FREE) (void)app.lock_drag(axis);
									if (try Vec3 at = self.pose_pointer(elem, app, event.pos)) app.drag.grab = at - app.drag.from;
								}
							}
							else
							{
								(void)app.begin_turn(true, axis.is_plane() ? DragAxis.FREE : axis);
							}
							app.refresh_ui();
							elem.request_paint();
							return true;
						}
						if (part != NO_GIZMO_PART)
						{
							TransformOperation operation = app.transform_tool == MOVE_TOOL
								? MOVE_TRANSFORM : ROTATE_TRANSFORM;
							(void)self.begin_transform_interaction(
								elem, operation, gizmo_axis(part), true, event.pos);
							return true;
						}
					}

					// A gesture begun on a key is holding no button, so it has been
					// following the pointer on hover and there is nothing to let go
					// of — a *click* is what confirms it. Tested before the pick, so
					// a confirming click that happens to land on a dot confirms the
					// gesture rather than selecting a different joint.
					if (app.drag.dot != 0 && !app.drag.held)
					{
						app.end_drag();
						app.refresh_ui();
						elem.request_paint();
						return true;
					}

					// A look-at target's handle is over the joints: its ring can sit on
					// one, and the ring is what was aimed at.
					sz aimed = (app.sketching || app.brushing || app.lassoing || app.areaing || input.shift_down())
						? -1 : self.pick_aim(elem, event.pos);
					if (aimed >= 0)
					{
						app.select_aim_target(app.posed_aims[(usz)aimed].target);
						self.maybe_drag_aim = (usz)aimed + 1;
						self.press_at = event.pos;
						app.refresh_ui();
						elem.request_paint();
						return true;
					}

					uint hit = self.pick_dot(elem, event.pos);

					// Shift picks out a *set* to act on rather than one dot to
					// work with, so it selects and stops there — no drag, no pin.
					// Deleting and bonding are what a set is for, and a
					// shift-click that also started a drag would move a dot every
					// time one was added to the group.
					bool extend = input.shift_down();
					if (extend && hit != 0)
					{
						app.extend_selection(hit);
						app.refresh_ui();
						elem.request_paint();
						return true;
					}

					// The brush selects only for a reason of its own: it paints the
					// *selected* dot, so switching which one has to stay possible
					// without leaving the mode — and a press that both dragged a dot
					// and painted around it would do two things at once, neither of
					// them asked for. The lasso is the same sentence with a region in
					// place of a circle.
					if (app.sketching && !input.shift_down())
					{
						self.sketch_now = true;
						app.sketch_active = true;
						app.sketch_points.clear();
						app.sketch_moved(event.pos);
						if (app.sketch_erasing && app.erase_annotations_along(event.pos, event.pos, elem.size) > 0) app.refresh_ui();
						self.maybe_place = false;
						self.orbiting = false;
						self.panning = false;
						elem.request_paint();
						return true;
					}

					if ((app.brushing || app.lassoing || app.areaing) && hit != 0)
					{
						app.select(hit);
						app.refresh_ui();
						elem.request_paint();
						return true;
					}

					if (hit != 0)
					{
						if (app.transform_tool != SELECT_TOOL)
						{
							if (!(app.selection_count() > 1 && app.is_selected(hit))) app.select(hit);
							// The Move tool edits the rest skeleton, so a plain drag on a
							// joint moves its rest position — Alt's job under the Select tool.
							// While posing it poses the joint instead, as the Select tool's
							// drag does.
							if (app.transform_tool == MOVE_TOOL)
							{
								self.maybe_drag_dot = hit;
								self.maybe_rest_drag = !transform_tool_poses(app);
								self.press_at = event.pos;
							}
							app.refresh_ui();
							elem.request_paint();
							return true;
						}

						// A press selects immediately, but it commits to no gesture yet.
						// Waiting for CLICK_SLOP is what lets a plain click choose another
						// posed joint without stopping the animation that put it there.
						// Once the pointer genuinely drags, the MOVE handler decides: a
						// bare drag poses this joint (as G does), and only Alt makes it
						// edit the rest dot.
						//
						// A press on a dot already inside a multi-selection keeps the
						// whole group, so an Alt-drag can move it as one piece — pressing
						// any other dot selects just that dot, the way it always has. A
						// plain click that never becomes a drag collapses the group back
						// to the clicked dot at RELEASE, so keeping it here costs nothing.
						if (!(app.selection_count() > 1 && app.is_selected(hit))) app.select(hit);
						self.maybe_drag_dot = hit;
						self.press_at = event.pos;
						app.refresh_ui();
						elem.request_paint();
						return true;
					}

					if (app.transform_tool != SELECT_TOOL)
					{
						self.press_at = event.pos;
						self.maybe_place = false;
						bool shift = input.shift_down();
						self.orbiting = !shift;
						self.panning = shift;
						return true;
					}

					// The Area tool: shift-drag on the mesh grows the part from the
					// point pressed, ctrl-drag shrinks it. Off the mesh, or ctrl with
					// nothing picked, the press falls through to the camera.
					// Picking islands, the same drags paint whole islands in and
					// out instead, and the press alone is a shift- or ctrl-click.
					if (app.areaing && (input.shift_down() || input.ctrl_down()))
					{
						bool grow = input.shift_down();
						sz vertex = self.vertex_at(elem, event.pos);
						bool painting = app.area_islands && app.area_pending();
						if (vertex >= 0 && (painting ? app.begin_island_paint(vertex, grow) : app.begin_area_resize(vertex, grow)))
						{
							self.area_now = true;
							self.area_painting = painting;
							self.area_grows = grow;
							self.area_from = event.pos;
							self.area_rings = 0;
							self.maybe_place = false;
							self.orbiting = false;
							self.panning = false;
							app.refresh_ui();
							elem.request_paint();
							return true;
						}
					}

					// Off the dots. Whether this is a click on the model or an
					// orbit is not knowable yet — record where it started and
					// let MOVE or RELEASE decide. What the click would *do* is
					// the mode's business, not this decision's.
					self.press_at = event.pos;
					self.maybe_place = true;

					bool shift = input.shift_down();

					// The brush: a plain drag on the mesh paints the way the options
					// strip says (Add / Remove); a plain drag off the mesh still
					// orbits, so the model can be turned to reach the next part.
					// Ctrl-drag adds and ctrl+shift-drag removes whatever the strip
					// says, and shift alone is still pan. One press is one stroke and
					// one undo entry.
					bool ctrl = input.ctrl_down();
					if (app.brushing && (ctrl || !shift) && !input.key_down(Key.F))
					{
						self.brushing_now = true;
						self.brush_adds = ctrl ? !shift : !app.brush_removes;
						app.begin_stroke();
						usz under = self.paint_at(elem, event.pos);
						if (under > 0 || ctrl)
						{
							self.maybe_place = false;
							self.orbiting = false;
							self.panning = false;
							return true;
						}
						self.brushing_now = false;
						app.end_stroke();
					}

					// The lasso takes the plain drag outright, one slot below the
					// brush because the two never open together. Ctrl is the
					// other direction here, whichever job is running.
					// Alt is the one modifier that means something different on
					// each: reaching through the model while pinning, adding to
					// the selection while selecting. All three are read live off
					// `Input` and latched now, so letting go of one half way does
					// not turn a region that was unpinning into one that pins —
					// `brush_adds`' rule.
					if (app.lassoing && !shift)
					{
						bool alt = input.alt_down();
						self.lasso_now = true;
						app.lasso_removes = input.ctrl_down();
						app.lasso_xray = app.lasso_job == LassoJob.PIN && alt;
						app.lasso_adds = app.lasso_job == LassoJob.SELECT && alt;
						app.lasso_active = true;
						app.drop_lasso_stroke();
						app.lasso_moved(event.pos);
						self.maybe_place = false;
						self.orbiting = false;
						self.panning = false;
						elem.request_paint();
						return true;
					}

					self.orbiting = !shift;
					self.panning = shift;
					return true;
				case MIDDLE:
					self.panning = true;
					return true;
				case RIGHT:
					// A context menu on the joints: Mirror and Delete. Only a
					// right-press *on* a dot raises it — a press on empty space is
					// left to fall through to the pane's own split/merge menu, so this
					// never eats the layout gesture. A dot not already in the selection
					// is selected first, so right-clicking a joint acts on it; a press
					// inside an existing multi-selection leaves the group whole, so the
					// menu can mirror or delete all of it at once.
					sz aimed_here = self.pick_aim(elem, event.pos);
					if (aimed_here >= 0)
					{
						// A ring: select the target and open its rows.
						app.select_aim_target(app.posed_aims[(usz)aimed_here].target);
						app.refresh_ui();
						elem.request_paint();
						open_viewport_context(elem.ui, elem.absolute + event.pos, true);
						return true;
					}
					uint picked = self.pick_dot(elem, event.pos);
					if (picked == 0) return false;
					if (!app.is_selected(picked))
					{
						app.select(picked);
						app.refresh_ui();
					}
					open_viewport_context(elem.ui, elem.absolute + event.pos);
					elem.request_paint();
					return true;
				default:
					return false;
			}
		case MOVE:
			// Recorded before anything is decided, so the turn ring has a radius
			// to draw at on the very frame the sweep begins.
			self.pointer = event.pos;

			if (app.transform_interaction.active)
			{
				app.transform_interaction.free_move = elem.ui.input.ctrl_down();
				app.update_transform_pointer(event.absolute);
				return true;
			}

			if (self.brushing_now)
			{
				// The latch cannot outlive the mode: closing the brush with the button still down would
				// leave a stroke running over a mesh nobody is painting.
				if (!app.brushing)
				{
					self.brushing_now = false;
				}
				else
				{
					(void)self.paint_at(elem, event.pos);
					return true;
				}
			}

			if (self.sketch_now)
			{
				if (!app.sketching || !app.sketch_active)
				{
					self.sketch_now = false;
					app.sketch_active = false;
				}
				else
				{
					// The eraser takes off what it passes rather than drawing.
					// The eraser keeps its path in the same list and takes off what the
					// last step of it crossed.
					Vec2 was = app.sketch_points.len() > 0 ? app.sketch_points[app.sketch_points.len() - 1] : event.pos;
					if (app.sketch_moved(event.pos) && app.sketch_erasing
						&& app.erase_annotations_along(was, event.pos, elem.size) > 0) app.refresh_ui();
					elem.request_paint();
					return true;
				}
			}

			if (self.lasso_now)
			{
				// The latch cannot outlive the mode: closing the lasso with the button still down would
				// leave a polygon growing that nothing is going to close. Nor the
				// gesture — escape cancels the region without waiting for the
				// button, and the outline must not start growing again from
				// wherever the pointer happens to be next.
				if (!app.lassoing || !app.lasso_active)
				{
					self.lasso_now = false;
					app.lasso_active = false;
				}
				else
				{
					// Thinned by distance rather than taken per move — see
					// `LASSO_STEP`. The repaint is asked for either way, since the
					// segment under the pointer is redrawn to it.
					app.lasso_moved(event.pos);
					elem.request_paint();
					return true;
				}
			}

			if (self.area_now)
			{
				if (!app.areaing)
				{
					self.area_now = false;
				}
				else if (self.area_painting)
				{
					sz vertex = self.vertex_at(elem, event.pos);
					if (vertex >= 0 && app.island_paint_to(vertex)) app.refresh_ui();
					elem.request_paint();
					return true;
				}
				else
				{
					// Rings from the distance travelled, re-derived from the part the
					// drag began with, so dragging back undoes rings as it goes.
					int rings = (int)((event.pos - self.area_from).length() / AREA_RING_PIXELS);
					if (!self.area_grows) rings = -rings;
					if (rings != self.area_rings)
					{
						self.area_rings = rings;
						app.area_resize_to(rings);
						app.refresh_ui();
					}
					elem.request_paint();
					return true;
				}
			}

			if (self.maybe_drag_aim != 0)
			{
				if ((event.pos - self.press_at).length() <= CLICK_SLOP) return true;
				usz handle = self.maybe_drag_aim - 1;
				self.maybe_drag_aim = 0;
				if (app.begin_aim_drag(handle, true))
				{
					// The press was on the ring, not at its centre: the target moves by
					// what the pointer moves from here, rather than jumping to it.
					if (try Vec3 at = self.pose_pointer(elem, app, self.press_at)) app.drag.grab = at - app.drag.from;
				}
				if (app.drag.dot != 0) self.drag_dot(elem, event.pos);
				app.refresh_ui();
				elem.request_paint();
				return true;
			}

			if (self.maybe_drag_dot != 0)
			{
				if ((event.pos - self.press_at).length() <= CLICK_SLOP) return true;
				uint id = self.maybe_drag_dot;
				bool rest = self.maybe_rest_drag;
				self.maybe_drag_dot = 0;
				self.maybe_rest_drag = false;
				// The header's Joints | Pose switch says what a bare drag does. On
				// Joints it moves the joint on the model. On Pose it poses the joint,
				// exactly as G does, and never falls through to a rest-rig move that
				// would land a rig edit in the history — Alt is the deliberate "move
				// the joint instead" there, as is the Move tool's own drag.
				bool alt = input.alt_down();
				if (alt || rest || app.stage == JOINTS_STAGE)
				{
					app.begin_drag(id);
				}
				else if (app.animation_pose_ready())
				{
					(void)app.begin_pose(true);
				}
				else
				{
					// On Pose with nothing that can be posed right now: say why, and
					// how to move the joint instead, rather than moving it silently.
					app.@notice(app.animating && !app.anim_paused
						? "pause the animation to pose · switch to Joints to move the joint"
						: "choose an animation to pose · switch to Joints to move the joint");
					app.refresh_ui();
					elem.request_paint();
					return true;
				}
				if (app.drag.dot != 0) self.drag_dot(elem, event.pos);
				app.refresh_ui();
				elem.request_paint();
				return true;
			}

			if (app.drag.dot != 0)
			{
				self.drag_dot(elem, event.pos);
				return true;
			}

			// A press that travels was an orbit all along, so nothing gets
			// placed when it comes back up.
			if (self.maybe_place && (event.pos - self.press_at).length() > CLICK_SLOP)
			{
				self.maybe_place = false;
			}

			// The brush circle is drawn where the pointer is, so a pointer that
			// moved *is* something to redraw — and a hover move otherwise falls
			// out below unconsumed, asking for no frame at all. That is what left
			// the circle sitting still until some other event forced a paint.
			if (app.brushing) elem.request_paint();

			// Sizing, while the key is down. Sideways travel from where the key
			// went down: right grows, left shrinks, and letting go leaves it there.
			if (app.brushing && input.key_down(Key.F))
			{
				if (!self.sizing_brush)
				{
					self.sizing_brush = true;
					self.brush_anchor = event.pos;
					self.brush_from = app.brush_radius;
				}
				app.set_brush_radius(self.brush_from + (event.pos.x - self.brush_anchor.x));
				return true;
			}
			self.sizing_brush = false;

			if (!self.orbiting && !self.panning)
			{
				self.probe_chain(elem, app, event.pos);
				self.probe_island(elem, app, event.pos);
				app.aim_ring_hover = self.pick_aim(elem, event.pos) >= 0;
				return false;
			}

			if (self.orbiting) app.camera.orbit(input.mouse_delta);
			if (self.panning) app.camera.pan(input.mouse_delta, elem.size.y);
			elem.ui.invalidate(OrbitCamera);
			return true;
		case RELEASE:
			switch (event.button)
			{
				case LEFT:
					if (app.transform_interaction.active && app.transform_interaction.held)
					{
						(void)app.finish_transform_interaction(true);
						elem.request_paint();
						return true;
					}
					if (self.brushing_now)
					{
						// The stroke committed itself as it went — `paint_dabs`
						// closes each group — so there is nothing to record here.
						// What ends is the gesture, and with it the one thing a
						// stroke over a posed body defers: the surface rebuild.
						self.brushing_now = false;
						app.end_stroke();
					}
					else if (self.sketch_now)
					{
						self.sketch_now = false;
						app.sketch_active = false;
						if (!app.sketch_erasing)
						{
							OrbitCamera* camera = self.view_camera(elem);
							Matrix4f vp = app.model_view_projection(camera, elem.size.x / elem.size.y);
							app.sketch_commit(vp, elem.size, camera);
						}
						app.refresh_ui();
						elem.request_paint();
					}
					else if (self.lasso_now)
					{
						// Where the brush has already committed and this has not:
						// a lasso is one *region*, not a stream the hand is still
						// adding to, and half a polygon says nothing about which
						// vertices are inside it. So the whole gesture lands here,
						// as one entry on the ledger — or, selecting, as no entry
						// at all, a selection being nothing the ledger holds.
						//
						// The one branch where the two jobs part company. Pinning
						// needs the eye as well, for the visibility test it marches
						// through the mesh; selecting needs only the pixels, since
						// the circles it catches are drawn on them.
						self.lasso_now = false;
						OrbitCamera* camera = self.view_camera(elem);
						Matrix4f vp = app.model_view_projection(camera, elem.size.x / elem.size.y);
						if (app.lasso_job == LassoJob.PIN)
						{
							app.lasso_commit(vp, elem.size, app.model_eye(camera));
						}
						else
						{
							app.lasso_select_commit(vp, elem.size);
						}
						app.refresh_ui();
					}
					else if (self.area_now)
					{
						// Nothing is written until Apply; the grown part stays pending.
						self.area_now = false;
						self.area_painting = false;
						app.drop_area_base();
						app.refresh_ui();
					}
					else if (self.maybe_drag_aim != 0)
					{
						// A click on a handle: it selected the target on the press, and that is all.
						self.maybe_drag_aim = 0;
						app.refresh_ui();
						elem.request_paint();
					}
					else if (self.maybe_drag_dot != 0)
					{
						// A click, not a drag: without enough travel there is
						// deliberately no rest edit and no animation display to stop.
						//
						// If a multi-selection was kept alive on press so it could be
						// dragged as a group, a plain click on one of its dots means
						// "just this one" after all — collapse to it now that no drag
						// followed. A single selection is already exactly that, so this
						// only fires when a group was held open for a drag that never came.
						if (app.selection_count() > 1) app.select(self.maybe_drag_dot);
						self.maybe_drag_dot = 0;
						self.maybe_rest_drag = false;
						app.refresh_ui();
						elem.request_paint();
					}
					else if (app.drag.dot != 0 && app.drag.held)
					{
						// One edit for the whole drag. The thing being moved has
						// been re-solved on every mouse move to get here; recording
						// each step would bury the history in noise.
						//
						// Held gestures only. One begun on a key never took a
						// button, so a release arriving from some unrelated press
						// must not end it — the click above is its ending.
						app.end_drag();
					}
					else if (self.maybe_place && app.areaing)
					{
						// A click in the Area tool picks a part rather than placing
						// a joint.
						sz vertex = self.vertex_at(elem, self.press_at);
						if (vertex < 0)
						{
							app.@notice("click on the mesh to pick a part");
						}
						else if (app.selected == 0)
						{
							app.@notice("select a joint first");
						}
						else
						{
							app.area_click(vertex);
						}
						app.refresh_ui();
					}
					else if (self.maybe_place)
					{
						// Acted on at the press position, not the release one:
						// under CLICK_SLOP they are the same point to the eye,
						// and the press is where the user was actually aiming.
						String refused = placement_refused(app);
						if (refused.len > 0)
						{
							app.@notice("%s", refused);
							app.refresh_ui();
						}
						else
						{
							self.place_dot(elem, self.press_at);
						}
					}
					self.maybe_place = false;
					self.orbiting = false;
					self.panning = false;
					elem.request_paint();
					return true;
				case MIDDLE:
					self.panning = false;
					return true;
				default:
					return false;
			}
		case SCROLL:
			self.activate_camera(elem);
			return self.scroll_camera(elem, event, input);
		default:
			return false;
	}
}

<*
 The camera's own right in model space: the one direction that stays
 unforeshortened whatever the orbit is doing.
*>
fn Vec3 camera_right(AppState* app, OrbitCamera* camera)
{
	Vec3 forward = (camera.target - camera.eye()).normalize();
	return app.model_direction(forward.cross({ 0, 1, 0 }).normalize());
}

<*
 One step of a brush stroke: everything under the circle, painted.

 Called on the press and on every mouse move until the button goes, so a stroke
 is many of these. Each one is cheap to *ask* for and does nothing when the
 circle covers nothing already at a different share — `paint_dabs` drops dabs
 that change nothing, which is what keeps a slow drag over painted mesh from
 filling the ledger with steps that undo to themselves.

 The target is 0 or 1 rather than a settable value: the brush takes a joint off
 the mesh or puts it on, as stated shares — see `AppState.brush_share` — and
 anything between is what `paint_weights` is for, where a number can be typed.

 The stroke paints against the body on screen — the rest mesh, or the posed
 one under a parked clip or a pose draft — see `AppState.brush_vertices`.

 @return `How many vertices were under the circle; 0 off the mesh.`
*>
fn usz Viewport.paint_at(&self, Element* elem, Vec2 at)
{
	AppState* app = elem.inherit(AppState)!!;
	if (!app.brushing || app.selected == 0) return 0;

	if (elem.size.x <= 0.0f || elem.size.y <= 0.0f) return 0;

	usz vertices = app.geometry.positions.len;
	if (vertices == 0) return 0;

	uint[] under = alloc::new_array(mem, uint, (sz)vertices);
	defer alloc::free(mem, under);
	float[] strength = alloc::new_array(mem, float, (sz)vertices);
	defer alloc::free(mem, strength);

	// `event.pos` is already this element's own pixels — the same ones `pick_dot`
	// compares projected dots against — so there is no origin to subtract.
	OrbitCamera* camera = self.view_camera(elem);
	Matrix4f vp = app.model_view_projection(camera, elem.size.x / elem.size.y);
	usz hit = app.brush_vertices(under, strength, vp, elem.size, app.model_eye(camera), at, app.brush_radius);
	if (hit == 0) return 0;

	// Not the falloff itself but the part of it this stroke has not already
	// given — see `begin_stroke`. A hand that stops moving asks for nothing.
	for (usz i = 0; i < hit; i++) strength[i] = app.stroke_pull(under[i], strength[i]);

	app.brush_share(app.selected, under[:hit], self.brush_adds ? 1.0f : 0.0f, strength[:hit]);
	elem.request_paint();
	return hit;
}

// Pixels of drag per ring a grow or shrink drag moves the part.
const float AREA_RING_PIXELS = 14.0;

// How far from the pointer the Area tool looks for a vertex to pick, in pixels.
const float AREA_PICK_RADIUS = 40.0;

<*
 The vertex under a pixel, front surfaces only, or -1 — what the Area tool picks
 a part at.
*>
fn sz Viewport.vertex_at(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	if (elem.size.x <= 0.0f || elem.size.y <= 0.0f) return -1;
	OrbitCamera* camera = self.view_camera(elem);
	Matrix4f vp = app.model_view_projection(camera, elem.size.x / elem.size.y);
	return app.vertex_under(vp, elem.size, app.model_eye(camera), pixel, AREA_PICK_RADIUS);
}

<*
 A wheel notch zooms, and ctrl makes it a quarter of one. A trackpad swipe
 orbits, and takes ctrl to zoom and shift to pan.

 `scroll_precise` is what tells the two apart, and it is the device saying so
 rather than us guessing: a trackpad reports points and a wheel reports notches,
 an order of magnitude apart, and a threshold picked between them would sit in
 the middle of both spreads.

 Which is also why ctrl means two different things on the two devices. A wheel
 has no way to send half a notch, so its fine step has to be a modifier; a
 trackpad's gesture is already continuous and spends ctrl on choosing zoom over
 orbit, which is the ambiguity a wheel does not have.

 The Area tool takes a wheel notch while a part is picked, to step it along the
 part ladder; the trackpad swipe stays the camera's.

 The trackpad half is unreachable from a machine whose backend cannot report
 precision — X11, win32 — where every scroll is a wheel, and both of the wheel's
 steps are there.
*>
fn bool Viewport.scroll_camera(&self, Element* elem, MouseEvent event, Input* input)
{
	AppState* app = elem.inherit(AppState)!!;

	bool ctrl = input.ctrl_down();
	bool shift = input.shift_down();

	// A grow or shrink drag owns the viewport until it is let go: its rings are
	// measured in pixels from where it began.
	if (self.area_now) return true;

	// A stroke owns the viewport the same way: the brush is measured in pixels, so a wheel that dollied mid-stroke would
	// change how much mesh the circle covers between one mouse move and the next.
	if (self.brushing_now) return true;

	// And a region does, for the same reason one step harder: the polygon is in
	// pixels, so a wheel that dollied mid-gesture would leave the half already
	// drawn describing a different part of the model from the half still to come.
	if (self.lasso_now || self.sketch_now) return true;

	// The brush sizes itself only while its key is held. The rest of the time the
	// wheel and the swipe are the camera's, because painting means turning the
	// model to reach the next part of it — a brush that ate the orbit for as long
	// as it was open would be usable from one angle only.
	bool sizing = app.brushing && input.key_down(Key.F);
	if (sizing)
	{
		app.size_brush(event.scroll_precise ? event.scroll * TRACKPAD_NOTCHES_PER_POINT : event.scroll);
		elem.request_paint();
		return true;
	}

	// A wheel notch steps a picked part along the ladder: own bone, with
	// children, whole piece. Only while a ladder part is picked, so the wheel is
	// the camera's the rest of the time.
	if (!event.scroll_precise && event.scroll != 0.0f && app.areaing && app.area_pending()
		&& app.area_part != CUSTOM)
	{
		app.step_area(event.scroll > 0.0f ? 1 : -1);
		app.refresh_ui();
		elem.request_paint();
		return true;
	}

	if (!event.scroll_precise)
	{
		app.camera.dolly(ctrl ? event.scroll * FINE_ZOOM_RATIO : event.scroll);
		elem.ui.invalidate(OrbitCamera);
		return true;
	}

	// Straight onto the axes a drag uses: both deltas follow the fingers and
	// both are y-down, so a swipe is a drag that happens to arrive as a scroll.
	// cui's Scroll widget pins the vertical sign — it subtracts `scroll` from an
	// offset measured downward, so a positive scroll is a swipe *down* — and the
	// horizontal half is symmetric, positive to the right.
	//
	// Which way that ends up turning the model follows the system's natural-
	// scrolling setting, because the platform has already applied it to these
	// deltas by the time they arrive. That is the right way round: the gesture
	// should agree with every other gesture on the machine, not with a
	// convention crig made up.
	Vec2 swipe = { event.scroll_x, event.scroll };

	if (ctrl)
	{
		// Vertical only. A zoom has one degree of freedom, and folding the
		// horizontal drift of a two-finger swipe into it would make the amount
		// you zoomed depend on how straight you swiped.
		app.camera.dolly(swipe.y * TRACKPAD_NOTCHES_PER_POINT);
	}
	else if (shift)
	{
		app.camera.pan(swipe, elem.size.y);
	}
	else
	{
		app.camera.orbit(swipe * TRACKPAD_ORBIT_RATIO);
	}

	elem.ui.invalidate(OrbitCamera);
	return true;
}

<*
 The dot nearest the pointer, if one is within reach.

 Screen space rather than a ray cast: dots draw at a fixed pixel radius however
 far away they are, so the thing the user is aiming at is the circle, and the
 grab radius should be quoted in the same units it is drawn in.

 Which means it has to aim at the same circles `paint` drew — hence
 `dot_position` here as well, so a click during playback lands on the dot the
 user can see rather than on the rest pose behind it. A hidden rig has no
 circles at all and answers nothing.

 @param pixel : `Viewport-local pixels.`
 @return `The dot's id, or 0 if nothing is close enough.`
*>
fn uint Viewport.pick_dot(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	if (!app.show_rig) return 0;

	OrbitCamera* camera = self.view_camera(elem);
	Matrix4f view_projection = app.model_view_projection(camera, elem.size.x / elem.size.y);

	uint best = 0;
	float best_distance = PICK_RADIUS;

	foreach (dot : app.doc.dots.array_view())
	{
		Vec2? at = project(view_projection, app.dot_position(dot), elem.size);
		if (catch at) continue;

		float distance = (at - pixel).length();
		// <= so that on a tie the later dot wins, matching paint order: the one
		// drawn on top is the one that gets grabbed.
		if (distance <= best_distance)
		{
			best_distance = distance;
			best = dot.id;
		}
	}
	return best;
}

<*
 The look-at handle under a pixel: the nearest ring within the grab radius.
 Asked before `pick_dot`, since a ring can sit over a joint and is what the
 pointer is after. Hidden handles answer nothing, as hidden dots do.

 @param pixel : `Viewport-local pixels.`
 @return `The handle index in posed_aims, or -1.`
*>
fn sz Viewport.pick_aim(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	if (!aim_handles_shown(app)) return -1;

	OrbitCamera* camera = self.view_camera(elem);
	Matrix4f view_projection = app.model_view_projection(camera, elem.size.x / elem.size.y);

	sz best = -1;
	float best_distance = PICK_RADIUS;
	foreach (usz i, handle : app.posed_aims)
	{
		Vec2? at = project(view_projection, handle.at, elem.size);
		if (catch at) continue;
		float distance = (at - pixel).length();
		if (distance <= best_distance)
		{
			best_distance = distance;
			best = (sz)i;
		}
	}
	return best;
}

<*
 Where the model is under a pixel.

 @param pixel : `Viewport-local pixels.`
 @return `A position inside the mesh, or a fault if the ray missed it.`
*>
fn Vec3? Viewport.snap(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	return app.picker.snap_inside(self.ray(elem, pixel)!);
}

<*
 The ray from the eye through a pixel — what both the free drag and the axis
 lock ask the pointer, before they disagree about what to do with the answer.
*>
fn collision::Ray? Viewport.ray(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;
	OrbitCamera* camera = self.view_camera(elem);
	Vec3 direction = camera.ray_direction(pixel, elem.size)!;
	return {
		.origin = app.model_eye(camera),
		.direction = app.model_direction(direction).normalize(),
	};
}

fn void Viewport.place_dot(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;

	Vec3? position = self.snap(elem, pixel);
	// Clicking past the model is how you deselect, not an error worth reporting.
	if (catch position) return;

	app.place(position);
	app.refresh_ui();
	elem.request_paint();
}

<*
 Move the held dot to follow the pointer.

 Re-snapping through the mesh on every step is what makes this feel like
 sliding a joint along the inside of the body rather than dragging a decal
 across the screen — the dot stays on the medial axis the whole way.

 The pick is given the dot's current position, which is what makes the re-snap
 a *move* rather than a fresh placement: where the ray passes through more than
 one piece of the model, the piece the dot is already in wins. Without it the
 depth is re-chosen from nothing sixty times a second, and on a model built from
 overlapping parts the answer changes between neighbouring pixels.

 Off the model there is nothing to snap to, so the dot holds its distance from
 the eye and tracks the view plane instead. Holding the distance rather than
 re-deriving one is what stops it lurching toward the camera the instant the
 ray stops hitting anything, and it slides straight back onto the surface when
 the pointer returns.

 Under an axis lock none of that applies: the line decides two coordinates, so
 there is no ray to intersect and the mesh is consulted only to say how far
 along the dot may go. See `core/dragging.c3`.
*>
fn void Viewport.drag_dot(&self, Element* elem, Vec2 pixel)
{
	AppState* app = elem.inherit(AppState)!!;

	// A target drag has no dot; everything else needs the one it moves.
	Dot* dot = app.drag.verb == DragVerb.AIM ? null : app.doc.find(app.drag.dot);
	if (!dot && app.drag.verb != DragVerb.AIM)
	{
		app.drag = {};
		app.drag_mates.clear();
		return;
	}

	if (app.drag.verb != DragVerb.PLACE)
	{
		self.drag_pose(elem, app, pixel);
		return;
	}

	collision::Ray? ray = self.ray(elem, pixel);
	if (catch ray) return;

	if (app.drag.axis.is_direction())
	{
		Vec3? along = slide_along_direction(app.drag.from, app.drag.lock_direction, ray);
		// An axis pointing at the eye is one nothing can be dragged along, so
		// the dot holds still until the view or the lock changes.
		if (catch along) return;

		dot.position = clamp_inside(&app.voxels.grid, app.drag.from, along);
		app.drag_moved();
		elem.request_paint();
		return;
	}
	if (app.drag.axis.is_plane())
	{
		Vec3? in_plane = slide_in_plane(app.drag.from, app.drag.axis, ray);
		if (catch in_plane) return;
		dot.position = clamp_inside(&app.voxels.grid, app.drag.from, in_plane);
		app.drag_moved();
		elem.request_paint();
		return;
	}

	// Where the dot already is, so the pick keeps to the limb it is in rather
	// than re-deciding its depth from nothing on every mouse move.
	Vec3 held = dot.position;

	// Ctrl lets go of the mesh: the dot slides on the view plane through where
	// it is, for when the pick reads the body wrong.
	if (elem.ui.input.ctrl_down())
	{
		Vec3 facing = (ray.origin - held).normalize();
		float divisor = ray.direction.dot(facing);
		if (math::abs(divisor) > 1.0e-6f)
		{
			dot.position = ray.origin + ray.direction * ((held - ray.origin).dot(facing) / divisor);
			app.drag_moved();
			elem.request_paint();
		}
		return;
	}

	Vec3? snapped = app.picker.snap_inside(ray, &held);
	if (try snapped)
	{
		dot.position = snapped;
	}
	else
	{
		Vec3 eye = ray.origin;
		dot.position = eye + ray.direction * (dot.position - eye).length();
	}
	app.drag_moved();
	elem.request_paint();
}

<*
 One mouse move of a pose gesture: the joint follows the pointer, or turns under
 it.

 **The mesh is not consulted at all, unlike a dot drag.** `Picker.snap_inside`
 casts against the body *at rest*, and during animation posing that body has been
 deformed by the skinning pass — so a ray that found solid material would be
 describing a shape nobody is looking at. The pointer decides two coordinates and the depth
 latched at the grab decides the third, which is the same fallback a free dot
 drag already degrades to when it misses the model.

 No `clamp_inside` either: the voxel clamp keeps a *dot* inside the body, and a
 posed joint is allowed to leave the rest body because the body comes with it.
*>
fn void Viewport.drag_pose(&self, Element* elem, AppState* app, Vec2 pixel)
{
	if (app.drag.verb == DragVerb.TURN)
	{
		self.turn_pose(elem, app, pixel);
		return;
	}

	Vec3? target = self.pose_pointer(elem, app, pixel);
	// An axis pointing at the eye is one nothing can be dragged along, so the
	// joint holds still until the view or the lock changes.
	if (catch target) return;

	if (app.drag.verb == DragVerb.AIM)
	{
		app.aim_target_toward(target - app.drag.grab);
		elem.request_paint();
		return;
	}
	app.pose_toward(target - app.drag.grab);
	elem.request_paint();
}

<*
 Where the pointer at `pixel` asks a pose gesture's joint to go: on the locked
 line or plane through where the joint was grabbed, or at the grab's depth.
*>
fn Vec3? Viewport.pose_pointer(&self, Element* elem, AppState* app, Vec2 pixel)
{
	collision::Ray ray = self.ray(elem, pixel)!;
	if (app.drag.axis.is_direction()) return slide_along_direction(app.drag.from, app.drag.lock_direction, ray);
	if (app.drag.axis.is_plane()) return slide_in_plane(app.drag.from, app.drag.axis, ray);
	return ray.origin + ray.direction * app.drag.depth;
}

<*
 One mouse move of a turn: the pointer sweeps around the joint and the joint
 turns with it.

 The *delta* is unwrapped rather than the absolute angle, which is what lets a
 full revolution be a full revolution instead of snapping back at half a turn.
 The first move only anchors — there is no previous position to measure from, and
 the key that began the gesture arrived at the tree's root with no pointer.
*>
fn void Viewport.turn_pose(&self, Element* elem, AppState* app, Vec2 pixel)
{
	OrbitCamera* camera = self.view_camera(elem);
	Matrix4f view_projection = app.model_view_projection(camera, elem.size.x / elem.size.y);
	Vec2? projected = project(view_projection, app.drag.from, elem.size);
	// Behind the camera, where there is no pivot on screen to sweep around.
	if (catch projected) return;

	Vec2 arm = pixel - projected;
	// Too close to the pivot for the angle to mean anything: a pixel of pointer
	// movement there is most of a revolution.
	if (arm.length() < TURN_MIN_RADIUS) return;

	float now = (float)math::atan2(arm.y, arm.x);

	if (app.drag.anchor.y < 0.0f)
	{
		app.drag.anchor = { now, 0 };
		return;
	}

	float step = wrapped_to_pi(now - app.drag.anchor.x);
	app.drag.anchor = { now, 0 };
	// Screen y runs downward, so a sweep that looks anticlockwise on screen is a
	// clockwise turn in the y-up world the rig lives in. Negating here is what
	// makes dragging the way the limb should go send it that way.
	app.drag.turned -= step;

	Vec3 axis = app.drag.axis == DragAxis.FREE
		? app.model_direction((camera.eye() - camera.target).normalize())
		: app.drag.lock_direction;

	app.turn_joint(axis, app.drag.turned);
	elem.request_paint();
}

// Below this many pixels from the pivot the pointer's angle is noise: one pixel
// of movement is most of a turn, and the joint would spin on a twitch.
const float TURN_MIN_RADIUS = 12.0;

// An angle folded into (-pi, pi]. What makes a sweep across the far side of the
// pivot read as a small step rather than as most of a revolution backwards.
fn float wrapped_to_pi(float angle) @private
{
	while (angle > (float)math::PI) angle -= (float)math::TAU;
	while (angle <= -(float)math::PI) angle += (float)math::TAU;
	return angle;
}

<*
 Moving a dot under a temporary constraint: axis, plane or bone direction, and
 the clamp that keeps the result inside the model.

 An ordinary drag has no axis. The pointer casts a ray, `Picker.snap_inside`
 returns the midpoint of the body it passes through, and the *mesh* decides the
 third coordinate — so depth drifts as the dot slides along a limb, and changes
 outright where the pointer carries it off one piece of the body onto another.
 The pick is given the dot's own position and so keeps to the piece it is in
 while it can, but the piece is still the mesh's decision and not the user's.
 That is the right default for placing a joint and the wrong one for repairing a
 placed one, where the question is usually "this is a centimetre too far
 forward" and the answer has to change one number.

 A directional lock answers that with a line through the grab; a plane lock
 fixes one coordinate instead. Bone uses the selected joint's deterministic
 local +Y rather than a world cardinal. Snapping to the mesh then means
 something different — the constraint already chose the target — and becomes
 the clamp below: travel as far along the segment as the solid material the dot
 is already in reaches, and no further.

 Kept apart from the widget because none of it needs a window: the whole
 constraint is a line, a ray and a grid.
*>
module crig;

import rig;
import collision;
import std::math;

<*
 The temporary constraint on a move, or FREE for the ordinary drag.
*>
enum DragAxis
{
	FREE,
	X,
	Y,
	Z,
	XY,
	YZ,
	XZ,
	BONE,
}

<*
 Which coordinate the lock pins the move to, or -1 when there is no lock.
*>
fn int DragAxis.component(self)
{
	switch (self)
	{
		case X: return 0;
		case Y: return 1;
		case Z: return 2;
		default: return -1;
	}
}

<*
 The world-axis component a plane excludes, or -1 when this is not a plane.

 Plane names say what may move: XY holds Z, YZ holds X, and XZ holds Y. Keeping
 that mapping here lets input, projection and the HUD share one spelling.
*>
fn int DragAxis.plane_normal_component(self)
{
	switch (self)
	{
		case XY: return 2;
		case YZ: return 0;
		case XZ: return 1;
		default: return -1;
	}
}

fn bool DragAxis.is_plane(self) => self.plane_normal_component() >= 0;

fn bool DragAxis.is_direction(self) => self.component() >= 0 || self == BONE;

<*
 The axis letter, for the readout.
*>
fn String DragAxis.label(self)
{
	switch (self)
	{
		case X: return "X";
		case Y: return "Y";
		case Z: return "Z";
		case XY: return "XY";
		case YZ: return "YZ";
		case XZ: return "XZ";
		case BONE: return "bone";
		default: return "";
	}
}

// Indexed by `DragAxis.component`, so the unit direction and the coordinate
// being written can never disagree about which axis is which.
const Vec3[3] AXIS_DIRECTION = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };

<*
 What a gesture in progress is doing to the rig.

 PLACE edits the rest rig: the dot itself moves and the document records where it
 went. The other two edit the *pose* — the dot stays where it was placed and the
 joint it became is carried somewhere else — which is why they are reachable only
 during animation posing, and why a posed display refuses a PLACE.

 AIM moves a look-at target (`aim_edit.c3`) rather than any joint: `dot` is the
 joint that looks, `from` is where the target was grabbed, in model units, and
 nothing of the rig is touched until the target is keyed.

 One field rather than a second struct beside `DragState`, because five readers
 already ask "is a move in progress" by testing `drag.dot`, and a parallel state
 would give that question two answers. What they each mean by it stays true; the
 verb only says which kind.
*>
enum DragVerb
{
	PLACE,
	POSE,
	TURN,
	AIM,
}

<*
 A move in progress.

 Lives on the AppState rather than on the viewport widget because the keys that
 drive it arrive at the tree's root — a press captures the pointer but focus is
 a separate thing, and the shortcut layer is where X and ESC are read. One copy
 of the state also means a headless test can assert what a gesture did to it.
*>
struct DragState
{
	uint dot;      // the dot being moved, 0 when none is; AIM_DRAG_DOT while a look-at target is dragged
	usz aim;       // AIM: the target's handle, an index into `posed_aims`
	<*
	 Where the gesture began.

	 PLACE: the dot's rest position — the undo entry's "before", and the
	 constraint line's origin. AIM: the target's position. POSE and TURN: the joint's *posed* world position,
	 which is the line's origin for one and the pivot for the other. Both are
	 "where the thing being dragged was when it was grabbed"; what differs is
	 whether the rig or the pose is what put it there.
	*>
	Vec3 from;
	DragAxis axis;
	// Unit world direction for a directional lock. X/Y/Z are filled from the
	// world basis for placement/G, from the carried bone-local frame for R, and
	// BONE always comes from that carried frame. Latched when the lock changes so
	// one gesture cannot drift as its own pose changes the frame it started in.
	Vec3 lock_direction;
	DragVerb verb;

	<*
	 POSE: how far the joint was from the eye when it was grabbed, held for the
	 whole gesture.

	 Latched rather than re-derived per move. A solve pushes the joint toward
	 wherever the target is, so a depth read back off the joint each frame would
	 follow its own output — the joint would walk toward or away from the camera
	 for as long as the button was held.
	*>
	float depth;

	<*
	 POSE: how far from the joint the pointer met the gesture's line or plane when
	 it was pressed, taken off every target after. Zero for a press on the joint
	 itself; a press on a Move tool arrow lands along the arrow, and without this
	 the joint would jump out to the pointer instead of moving by what it moves.
	*>
	Vec3 grab;

	<*
	 TURN: the pixel the sweep was last measured at, and how far it has come.

	 Radians, unwrapped, so a full revolution is a full revolution rather than a
	 value that snaps at half a turn.

	 `TURN_UNANCHORED` until the first mouse move: the key that begins a turn
	 arrives at the tree's root, which has no pointer, and the pixels this is
	 measured in belong to whichever pane the pointer is over. `anchor.x` then
	 holds an atan2 angle and may legitimately be negative; `anchor.y < 0` is the
	 sentinel flag.
	*>
	Vec2 anchor;
	float turned;

	<*
	 Whether a button is being held for this gesture.

	 Held means the release ends it, which is every PLACE move and a turn begun by
	 pressing a revealed rotation ring. Not held means it began on a key with nothing down —
	 then the pointer is being followed on hover, and it is a *click* that confirms
	 it, because there is no button to let go of.

	 Both ways into rotation exist on purpose: R sweeps the pointer around the
	 joint on screen, and the Joint card's dials are the held route for one axis.
	*>
	bool held;

	<*
	 TURN: the sweep is being read off a dial on the Joint card rather than
	 around the joint on screen.

	 The dial keeps its own anchor, so `anchor` stays `TURN_UNANCHORED` for the
	 whole gesture and the viewport draws no spoke; and the card holds its
	 subtree still until the release, because rebuilding it would take the
	 pressed dial — and the pointer capture with it — out from under the hand.
	*>
	bool dial;
}

<*
 A dot dragged alongside the grabbed one in a group rest move.

 When more than one dot is selected, an Alt-drag moves the whole set: the grabbed
 dot is the `DragState.dot` that snaps through the mesh and takes an axis lock, and
 each other selected dot is a mate that only translates by the same delta. `from`
 is the mate's position at the grab, held for the gesture so every mouse move
 places it at `from + delta` rather than accumulating per-move error — the same
 reason `DragState.from` is latched. A mate carries no depth or lock of its own
 because it never leads; it follows the one dot that does.
*>
struct DragMate
{
	uint dot;
	Vec3 from;
}

<*
 An anchor no pointer can be at, meaning "the first mouse move sets this".

 The second component is the flag. The first becomes an atan2 angle after
 anchoring and therefore spans negative as well as positive values; using it as
 the flag made every turn begun on the upper half of a ring anchor twice.
*>
const Vec2 TURN_UNANCHORED = { -1, -1 };

faultdef AXIS_EDGE_ON;

<*
 How nearly parallel to the view ray an axis may be and still be draggable.

 Below this the line projects to less than a few pixels on screen and the
 closest-approach distance swings wildly for a pointer movement of one pixel,
 which reads as the dot flying off. Blender's answer to an axis pointing at the
 eye is the same one: nothing moves.
*>
const float AXIS_EDGE_ON_LIMIT = 0.02;

<*
 Where the pointer puts a point that may only travel along one axis.

 Closest approach between the constraint line and the pointer's ray — the
 standard reading of "drag along an axis": the dot follows the pointer as
 closely as a point on that line can, whatever the view.

 @param from : `The grab position; the constraint line passes through it.`
 @param ray : `Origin and unit direction, from the camera through the pointer.`
 @return `The point on the line, or AXIS_EDGE_ON when the axis points at the eye.`
*>
fn Vec3? slide_along_direction(Vec3 from, Vec3 direction, collision::Ray ray)
{
	if (direction.length_sq() <= 1.0e-12f) return AXIS_EDGE_ON~;
	direction = direction.normalize();
	Vec3 offset = from - ray.origin;

	// Both directions are unit, so the usual line-line denominator 1 - (u·v)^2
	// is also the squared sine of the angle between them: it goes to zero
	// exactly when the axis is edge-on to the view.
	float alignment = direction.dot(ray.direction);
	float denominator = 1.0f - alignment * alignment;
	if (denominator < AXIS_EDGE_ON_LIMIT) return AXIS_EDGE_ON~;

	float travel = (alignment * ray.direction.dot(offset) - direction.dot(offset)) / denominator;
	return from + direction * travel;
}

<*
 Intersect a pointer ray with the world plane through `from` named by the lock.

 A nearly edge-on plane cannot turn a pixel into a stable point, so it refuses
 on the same threshold as an axis aimed into the camera. XY/YZ/XZ describe the
 coordinates that may change; the remaining coordinate stays at the gesture's
 starting value.
*>
fn Vec3? slide_in_plane(Vec3 from, DragAxis plane, collision::Ray ray)
{
	int component = plane.plane_normal_component();
	if (component < 0) return from;
	Vec3 normal = AXIS_DIRECTION[component];
	float denominator = normal.dot(ray.direction);
	if (math::abs(denominator) < AXIS_EDGE_ON_LIMIT) return AXIS_EDGE_ON~;
	float travel = normal.dot(from - ray.origin) / denominator;
	return ray.origin + ray.direction * travel;
}

<*
 The far end of the walk from `from` toward `to` that is still in the same
 solid span.

 Stopping at the first cell that is not inside is what makes this the *span*
 rather than the whole line: a knee dragged down its own thigh stops at the
 hoof instead of leaping the gap to the far leg, which is exactly the move an
 unconstrained drag makes and the one the lock exists to prevent.

 Everything degenerate falls through to `to` rather than refusing: no grid, a
 mesh too open to voxelize, or a dot that was already outside solid material
 when it was grabbed. A dot that cannot be dragged at all is worse than one
 dragged somewhere thin.

 @param grid : `The model's solid voxelization, built once at load.`
*>
fn Vec3 clamp_inside(collision::VoxelGrid* grid, Vec3 from, Vec3 to)
{
	if (!grid.usable() || !grid.inside(from)) return to;

	Vec3 delta = to - from;
	float distance = delta.length();
	if (distance <= 0.0f) return from;

	// Half a cell, so a limb one cell across is sampled rather than stepped
	// over — the stride is what decides how thin a neck the clamp can see.
	float stride = grid.cell * 0.5f;
	if (stride <= 0.0f) return to;

	Vec3 direction = delta / distance;
	Vec3 furthest = from;
	for (float travelled = stride; travelled < distance; travelled += stride)
	{
		Vec3 at = from + direction * travelled;
		if (!grid.inside(at)) return furthest;
		furthest = at;
	}
	return grid.inside(to) ? to : furthest;
}

<* The pure half of src/app/turn_model.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::quaternion;

enum TurnModelResult : int
{
	TURNED,
	UNCHANGED,
	LOCKED,
	REFUSED,
}

<*
 Which way a model faces, as the feet read it, and how many quarter turns about
 +Y (counter-clockwise from above) bring it round to face +Z.
*>
enum MeshFacing : int (String label, int to_front)
{
	UNDECIDED { "", 0 },
	PLUS_Z { "+z", 0 },
	MINUS_Z { "-z", 2 },
	PLUS_X { "+x", 3 },
	MINUS_X { "-x", 1 },
}

<*
 The facing a label names: "+x", "-x", "+z" or "-z", upper case too.

 @return `UNDECIDED for anything else.`
*>
fn MeshFacing mesh_facing_named(String label)
{
	String lower = label.to_lower_tcopy();
	foreach (facing : MeshFacing::values)
	{
		if (facing != UNDECIDED && facing.label == lower) return facing;
	}
	if (lower == "x") return PLUS_X;
	if (lower == "z") return PLUS_Z;
	return UNDECIDED;
}

<*
 Quarter turns folded into 0..3, so -1 and 3 are the same turn.
*>
fn int quarter_turns(int quarters) => ((quarters % 4) + 4) % 4;

<*
 A vector turned by whole quarter turns about +Y, counter-clockwise from above.

 Exact: a quarter turn only swaps and negates components, so a turn and its
 inverse give back the same bits, which is what lets undo replay it rather than
 keep a copy of every vertex.
*>
fn Vec3 quarter_turned(Vec3 v, int quarters)
{
	switch (quarter_turns(quarters))
	{
		case 1: return { v.z, v.y, -v.x };
		case 2: return { -v.x, v.y, -v.z };
		case 3: return { -v.z, v.y, v.x };
		default: return v;
	}
}

<*
 The same turn as a rotation, for orientations: `turn.mul(q)` is `q` turned.
*>
fn Quaternionf quarter_turn(int quarters)
{
	return quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)quarter_turns(quarters) * (float)math::PI * 0.5f);
}

<*
 One key turned with the model: its axis and its bone are world directions, and
 its move is in its parent's frame, which turns with the parent.
*>
fn void AnimKeyDot.turn(&self, int quarters)
{
	self.axis = quarter_turned(self.axis, quarters);
	self.move = quarter_turned(self.move, quarters);
	self.bone = quarter_turned(self.bone, quarters);
	self.rotation_tangents.incoming = quarter_turned(self.rotation_tangents.incoming, quarters);
	self.rotation_tangents.outgoing = quarter_turned(self.rotation_tangents.outgoing, quarters);
	self.translation_tangents.incoming = quarter_turned(self.translation_tangents.incoming, quarters);
	self.translation_tangents.outgoing = quarter_turned(self.translation_tangents.outgoing, quarters);
}

fn void turn_keyframes(AnimKeyframe[] frames, int quarters)
{
	foreach (frame : frames)
	{
		foreach (&dot : frame.dots) dot.turn(quarters);
	}
}

<*
 A clip turned with the model it plays on, so it plays the same motion turned.

 Everything stated in model space turns: the keys, the layers' keys and the
 axes their generators turn about (a joint's rest frame is the model's), the
 aims' axes and targets, the pins and the paths. Time, angles, the floor and
 every length stay as they are. The compiled tracks are left for the next
 compile, since they hold the keys' old values.
*>
fn void AnimTemplate.turn(&self, int quarters)
{
	if (quarter_turns(quarters) == 0) return;
	Quaternionf turn = quarter_turn(quarters);

	turn_keyframes(self.keyframes, quarters);
	foreach (&layer : self.layers)
	{
		turn_keyframes(layer.keyframes, quarters);
		layer.axis = quarter_turned(layer.axis, quarters);
	}
	foreach (&aim : self.aims) aim.forward = quarter_turned(aim.forward, quarters);
	foreach (&target : self.aim_targets)
	{
		foreach (&key : target.keys) key.at = quarter_turned(key.at, quarters);
	}
	foreach (&pin : self.pins)
	{
		pin.at = quarter_turned(pin.at, quarters);
		pin.travel = quarter_turned(pin.travel, quarters);
		// A pin holding no rotation may hold a zero quaternion, which has no turn.
		if (pin.orient.length_sq() > 0.0f) pin.orient = turn.mul(pin.orient).normalize();
		if (pin.turn.length_sq() > 0.0f) pin.turn = turn.mul(pin.turn).mul(turn.invert()).normalize();
	}
	foreach (&path : self.paths)
	{
		foreach (&point : path.points) point.at = quarter_turned(point.at, quarters);
	}
	self.tracks_compiled = false;
}

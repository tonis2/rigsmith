<* The pure half of src/app/key_spread.c3: no state, undo or notices. *>
module crig;

import std::math;
import rig;
import std::collections::list;
import std::sort;

<*
 Where a keyed pose edit goes; see the file's header.
*>
enum KeyReach
{
	FRAME,
	SELECTED_KEYS,
	WHOLE_CLIP,
}

<*
 Each joint's change from `baseline` to `current`, as offsets to lay onto keys.

 @param [&inout] out : `Receives one offset per joint that changed.`
 @param height : `The rig's height; moves are stored as fractions of it.`
 @param may_turn : `Per joint, whether its rotation counts.`
 @param may_move : `Per joint, whether its translation counts.`
 @param [&inout] turns : `Set when any joint turned.`
 @param [&inout] moves : `Set when any joint moved.`
*>
fn void key_offsets_of(List{KeyOffset}* out, String[] names, rig::Pose baseline, rig::Pose current, float height,
	bool[] may_turn, bool[] may_move, bool* turns, bool* moves)
{
	foreach (usz j, rotation : current.rotations)
	{
		if (j >= baseline.rotations.len || j >= names.len || j >= may_turn.len) break;
		if (names[j].len == 0) continue;
		bool turned = may_turn[j] && 1.0f - math::abs(rotation.v.dot(baseline.rotations[j].v)) > 1.0e-7f;
		bool moved = may_move[j] && (current.offsets[j] - baseline.offsets[j]).length_sq() > 1.0e-12f;
		if (!turned && !moved) continue;
		out.push({
			.joint = names[j],
			.rotates = turned,
			.turn = baseline.rotations[j].invert().mul(rotation).normalize(),
			.moves = moved,
			.move = height > 0.0f ? (current.offsets[j] - baseline.offsets[j]) / height : (Vec3){},
		});
		*turns |= turned;
		*moves |= moved;
	}
}

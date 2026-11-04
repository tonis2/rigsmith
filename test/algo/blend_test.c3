<*
 Blending between two clips: the arithmetic the crossfade is made of.

     `c3c test --trust=full --test-filter crig_tests::blend`

 `blend_poses` slerps, and slerp between two quaternions written on opposite
 hemispheres takes the long way round unless one of them is flipped first —
 which shows up as the character spinning through itself mid-crossfade and
 nowhere else.

 The endpoint checks are the load-bearing ones: a fade at 0 must be *exactly*
 the pose it has not left, not nearly, or every crossfade would put a visible
 step at the moment it starts.

 This file used to also cover `Placement`, the Play view's character transform.
 That went with the view — see `plugin_plan.md`, "What gets deleted".
*>
module crig_tests::blend;

import crig;
import rig;
import std::core::test;
import std::math;
import std::math::vector;
import std::math::quaternion;

const float CLOSE = 1.0e-5f;

fn bool near(float a, float b) @local => math::abs(a - b) < CLOSE;

fn bool near_vec(Vec3 a, Vec3 b) @local
{
	return near(a[0], b[0]) && near(a[1], b[1]) && near(a[2], b[2]);
}


// Two poses a known distance apart: `a` at rest, `b` with joint 1 turned a half
// turn about +Y and the root slid aside.
fn void two_poses(Allocator allocator, rig::Pose* a, rig::Pose* b) @local
{
	*a = rig::rest_pose(allocator, 3);
	*b = rig::rest_pose(allocator, 3);
	b.turn(1, { 0.0, 1.0, 0.0 }, (float)math::PI / 2.0f);
	b.move(0, { 0.0, 2.0, 0.0 });
}

<*
 A blend at either end is the pose at that end, exactly.

 Not "within an epsilon": a crossfade starts every time a clip changes, and a
 fade at zero that was a hair off its own start would put a visible step at the
 moment the character begins moving — the one frame a player is looking at.
*>
fn void a_blend_at_the_ends_is_exact() @test
{
	rig::Pose a, b;
	two_poses(mem, &a, &b);
	defer { a.free(mem); b.free(mem); }

	rig::Pose? start = rig::blend_poses(mem, a, b, 0.0f);
	if (catch start) { test::@check(false, "blending at 0 works"); return; }
	defer start.free(mem);

	rig::Pose? end = rig::blend_poses(mem, a, b, 1.0f);
	if (catch end) { test::@check(false, "blending at 1 works"); return; }
	defer end.free(mem);

	foreach (usz i, rotation : a.rotations)
	{
		test::@check(start.rotations[i].v == rotation.v, "joint %d holds a's rotation at t=0", i);
		test::@check(start.offsets[i] == a.offsets[i], "and a's offset");
		test::@check(end.rotations[i].v == b.rotations[i].v, "joint %d holds b's rotation at t=1", i);
		test::@check(end.offsets[i] == b.offsets[i], "and b's offset");
	}

	// Past the ends is the ends, so a fade timer that overshoots by a frame does
	// not extrapolate the character into a pose neither clip contains.
	rig::Pose? over = rig::blend_poses(mem, a, b, 1.4f);
	if (catch over) { test::@check(false, "blending past 1 works"); return; }
	defer over.free(mem);
	test::@check(over.offsets[0] == b.offsets[0], "t past 1 clamps to b rather than extrapolating");
}

<*
 And halfway is halfway: the offset is the midpoint and the rotation is half the
 turn.
*>
fn void a_blend_halfway_is_halfway() @test
{
	rig::Pose a, b;
	two_poses(mem, &a, &b);
	defer { a.free(mem); b.free(mem); }

	rig::Pose? middle = rig::blend_poses(mem, a, b, 0.5f);
	if (catch middle) { test::@check(false, "blending works"); return; }
	defer middle.free(mem);

	test::@check(near_vec(middle.offsets[0], { 0.0, 1.0, 0.0 }),
		"the root offset is the midpoint (%.3f, %.3f, %.3f)",
		(double)middle.offsets[0][0], (double)middle.offsets[0][1], (double)middle.offsets[0][2]);

	// Half of a quarter turn is an eighth: +Z should land 45° round.
	Vec3 turned = middle.rotations[1].rotate_vec3({ 0.0, 0.0, 1.0 });
	float root_half = (float)math::sqrt(0.5);
	test::@check(near_vec(turned, { root_half, 0.0, root_half }),
		"and the rotation is half the turn (%.3f, %.3f, %.3f)",
		(double)turned[0], (double)turned[1], (double)turned[2]);

	test::@check(middle.rotations[0].v == a.rotations[0].v,
		"a joint both poses leave at rest stays at rest");
}

<*
 A blend takes the short way round even when the two rotations are written on
 opposite hemispheres.

 `q` and `-q` are the same rotation, and nothing stops a clip from storing one
 and the next clip the other — the bake writes whichever way the axis-angle came
 out. Without the sign fix the character reaches the same pose by spinning most
 of the way round the other side, which is invisible in every static check and
 unmistakable on screen.
*>
fn void a_blend_takes_the_short_way_round() @test
{
	rig::Pose a = rig::rest_pose(mem, 1);
	rig::Pose b = rig::rest_pose(mem, 1);
	defer { a.free(mem); b.free(mem); }

	a.turn(0, { 0.0, 1.0, 0.0 }, 0.4f);
	b.turn(0, { 0.0, 1.0, 0.0 }, 0.8f);
	// Same rotation, opposite hemisphere — which is what the fix has to survive.
	b.rotations[0] = -b.rotations[0];

	rig::Pose? middle = rig::blend_poses(mem, a, b, 0.5f);
	if (catch middle) { test::@check(false, "blending works"); return; }
	defer middle.free(mem);

	// Halfway between 0.4 and 0.8 radians about +Y, reached the short way.
	Vec3 turned = middle.rotations[0].rotate_vec3({ 0.0, 0.0, 1.0 });
	Vec3 wanted = { math::sin(0.6f), 0.0f, math::cos(0.6f) };
	test::@check(near_vec(turned, wanted),
		"halfway is 0.6 rad, not most of a turn the other way (%.3f, %.3f, %.3f)",
		(double)turned[0], (double)turned[1], (double)turned[2]);
}

<*
 Two poses of different lengths are refused rather than half-blended.

 The case is a clip bound before the rig grew a dot, which is an ordinary thing
 to do — and reading off the end of the shorter one would be a crash in the
 frame loop.
*>
fn void poses_of_different_lengths_are_refused() @test
{
	rig::Pose small = rig::rest_pose(mem, 2);
	rig::Pose large = rig::rest_pose(mem, 5);
	defer { small.free(mem); large.free(mem); }

	rig::Pose? refused = rig::blend_poses(mem, small, large, 0.5f);
	test::@check(@catch(refused) == rig::POSE_SIZE_MISMATCH, "a length mismatch is refused");
	if (try refused) refused.free(mem);

	rig::Pose? other_way = rig::blend_poses(mem, large, small, 0.5f);
	test::@check(@catch(other_way) == rig::POSE_SIZE_MISMATCH, "either way round");
	if (try other_way) other_way.free(mem);
}

<*
 A copy is its own memory, so freeing one does not touch the other.
*>
fn void a_pose_copy_stands_alone() @test
{
	rig::Pose original = rig::rest_pose(mem, 3);
	defer original.free(mem);
	original.move(2, { 1.0, 0.0, 0.0 });

	rig::Pose copy = original.copy(mem);
	defer copy.free(mem);

	test::@check(copy.offsets[2] == original.offsets[2], "the copy carries the same values");
	test::@check(copy.offsets.ptr != original.offsets.ptr, "in memory of its own");

	copy.move(2, { 9.0, 9.0, 9.0 });
	test::@check(original.offsets[2][0] == 1.0f, "and writing to it leaves the original alone");
}

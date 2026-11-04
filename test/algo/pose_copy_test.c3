module crig_tests::pose_copy;

import rig;
import std::core::test;

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

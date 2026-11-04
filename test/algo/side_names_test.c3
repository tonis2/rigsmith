<*
 Left and right in a joint's name, read one way. See rules/rigging.md.
*>
module crig_tests::side_names;

import crig;
import std::core::test;

struct SideCase @local
{
	String name;
	String twin;
	float side;
}

const SideCase[*] CASES @local = {
	{ "thigh_L", "thigh_R", 1.0f },
	{ "thigh_R", "thigh_L", -1.0f },
	{ "thigh.l", "thigh.r", 1.0f },
	{ "L_Upperarm", "R_Upperarm", 1.0f },
	{ "LeftFoot", "RightFoot", 1.0f },
	{ "armature:LeftFoot", "armature:RightFoot", 1.0f },
	{ "armature:RightHandThumb1", "armature:LeftHandThumb1", -1.0f },
	{ "upperarm_left", "upperarm_right", 1.0f },
	{ "hips", "", 0.0f },
	{ "arm", "", 0.0f },
};

fn void every_reader_of_a_side_agrees() @test
{
	foreach (one : CASES)
	{
		String twin = crig::mirror_name(mem, one.name);
		defer if (twin.len > 0) twin.free(mem);
		test::@check(twin == one.twin, "mirror_name(%s) is %s", one.name, twin);
		String gait = crig::gait_twin_name(mem, one.name);
		defer if (gait.len > 0) gait.free(mem);
		test::@check(gait == one.twin, "gait_twin_name(%s) is %s", one.name, gait);
		test::@check(crig::side_sign(one.name) == one.side, "side_sign(%s)", one.name);
	}
}

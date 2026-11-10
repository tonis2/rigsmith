<*
 A clip made on this very rig reaches every joint under its own name.

 A capture's clip comes back on the rig it was sent: the same joints under the
 same names, in another order. Eight legs of one shape are the hard case for
 the shape match that lands it, so it is held here.

     `c3c test --trust=full --test-noleak --test-filter crig_tests::reach_by_name`
*>
module crig_tests::reach_by_name;

import crig;
import rig;
import std::core::test;
import std::math;
import std::collections::list;

// A body, and eight four-jointed legs of one shape, four a side.
fn void eight_legs(List{Vec3}* at, List{int}* parents, List{String}* names, bool right_first) @local
{
	at.push({ 0, 0.3f, 0 });
	parents.push(-1);
	names.push("body");
	for (usz n = 0; n < 8; n++)
	{
		// The rig lists a row's left leg then its right; the pack every right leg first, from the back.
		bool left = right_first ? n >= 4 : n % 2 == 0;
		usz row = right_first ? 3 - n % 4 : n / 2;
		float side = left ? 1.0f : -1.0f;
		float z = 0.3f - 0.2f * (float)row;
		Vec3[4] leg = { { side * 0.1f, 0.3f, z }, { side * 0.3f, 0.5f, z }, { side * 0.5f, 0.3f, z }, { side * 0.6f, 0, z } };
		foreach (usz k, p : leg)
		{
			parents.push(k == 0 ? 0 : (int)at.len() - 1);
			at.push(p);
			names.push(string::format(tmem, "leg_%d_%d_%s", row + 1, k + 1, left ? "l" : "r"));
		}
	}
}

fn void a_clip_on_this_rig_reaches_every_joint_by_its_name() @test => @pool()
{
	List{Vec3} rig_at;
	List{int} rig_parents;
	List{String} rig_names;
	List{Vec3} pack_at;
	List{int} pack_parents;
	List{String} pack_names;
	rig_at.init(tmem);
	rig_parents.init(tmem);
	rig_names.init(tmem);
	pack_at.init(tmem);
	pack_parents.init(tmem);
	pack_names.init(tmem);
	eight_legs(&rig_at, &rig_parents, &rig_names, false);
	eight_legs(&pack_at, &pack_parents, &pack_names, true);

	rig::Skeleton skeleton = { .joints = rig_at.array_view(), .parents = rig_parents.array_view() };
	crig::AnimPack pack = { .rest = { .joints = pack_at.array_view(), .parents = pack_parents.array_view() }, .joint_names = pack_names.array_view() };

	crig::PackReach reach = crig::measure_reach(mem, &pack, &skeleton, rig_names.array_view());
	defer reach.free(mem);
	test::@check(reach.usable, "the rig's own clip is usable on it");
	test::eq(reach.answered, (usz)33);
	usz wrong;
	foreach (usz j, name : rig_names)
	{
		if (reach.names[j] == name) continue;
		if (wrong++ < 4) test::@check(false, "%s answers to its own name, not %s", name, reach.names[j]);
	}
	test::eq(wrong, (usz)0);
}

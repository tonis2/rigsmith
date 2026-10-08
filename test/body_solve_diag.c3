module crig_tests::body_solve;

import crig;
import rig;
import std::core::test;
import std::io;
import std::math;
import std::math::quaternion;
import std::time;

fn float pose_gap(Body* b, rig::Pose* a, rig::Pose* c)
{
	float worst = 0.0f;
	foreach (j, q : a.rotations) worst = math::max(worst, angle_of(q.mul(c.rotations[j].invert())));
	return worst;
}

fn void a_diag_trouble() @test
{
	foreach (round : (int[]){ 48, 96 })
	{
		Body b;
		if (!b.open()) return;
		defer b.close();
		Path path = b.circle_path("wrist_L", { -0.15f, -0.1f, 0.1f }, 0.08f, round);
		b.begin();
		rig::Pose start = b.pose.copy(mem);
		defer start.free(mem);
		crig::PointGoal[3] goals;
		goals[1] = b.pin("ankle_L", true);
		goals[2] = b.pin("ankle_R", true);
		String line = "";
		int hops = 0;
		int hops_quiet = 0;
		int troubled = 0;
		for (int k = 1; k <= 2 * round; k++)
		{
			crig::diag_ramp = 24;
			b.solve_path(&start, goals[..], &path, (float)k);
			rig::Pose fine = b.pose.copy(mem);
			defer fine.free(mem);
			crig::diag_ramp = 0;
			crig::diag_rejects = 0;
			crig::diag_iters = 0;
			b.solve_path(&start, goals[..], &path, (float)k);
			float gap = pose_gap(&b, &fine, &b.pose);
			bool hop = gap > 5.0f;
			bool trouble = crig::diag_rejects > 0;
			if (hop) hops++;
			if (hop && !trouble) hops_quiet++;
			if (trouble) troubled++;
			if (hop) line = string::tformat("%s\n   step %d gap %.1f deg, %d rejects of %d iterations", line, k, gap, crig::diag_rejects, crig::diag_iters);
		}
		note("round %d: %d hops (vs ramp 24), %d of them with no rejected step; %d of %d steps had a rejected step%s", round, hops, hops_quiet, troubled, 2 * round, line);
	}
	// And the sit.
	Body b;
	if (!b.open()) return;
	defer b.close();
	Sit sit = b.sit("spine", 0.18f);
	crig::diag_rejects = 0;
	crig::diag_iters = 0;
	b.solve(sit.goals[..]);
	note("sit: %d rejected of %d iterations", crig::diag_rejects, crig::diag_iters);
}

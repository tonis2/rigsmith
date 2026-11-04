<* The pure half of src/app/pose_library.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

fn sz saved_pose_named(RigDocument* doc, String name)
{
	foreach (usz i, pose : doc.poses) if (pose.name == name) return (sz)i;
	return -1;
}

// "Pose N", the first N from the library's size up that no pose uses.
fn String next_pose_name(RigDocument* doc, Allocator allocator)
{
	for (usz n = doc.poses.len + 1; ; n++)
	{
		String name = string::tformat("Pose %d", n);
		if (saved_pose_named(doc, name) < 0) return name.copy(allocator);
	}
}

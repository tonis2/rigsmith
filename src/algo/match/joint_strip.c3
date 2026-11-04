<* The pure half of src/app/joint_strip.c3: no state, undo or notices. *>
module crig;

import rig;

fn void free_names(Allocator allocator, String[] names)
{
	foreach (name : names) if (name.len > 0) alloc::free(allocator, name.ptr);
	if (names.len > 0) alloc::free(allocator, names);
}

<*
 "tail_1", "tail_1 and the 11 joints below it", "tail_1, ear_L and the 4 joints
 below them": the covered joints said the short way, for a notice or a question.
 Temp-allocated.
*>
fn String covered_joints_phrase(String[] roots, usz count)
{
	if (roots.len == 0) return "";
	DString text = dstring::temp();
	text.append(roots[0]);
	if (roots.len > 1) text.appendf(roots.len == 2 ? " and %s" : ", %s", roots[1]);
	if (roots.len > 2) text.appendf(" and %d more", roots.len - 2);
	usz below = count > roots.len ? count - roots.len : 0;
	if (below > 0)
	{
		text.appendf(" and the %d joint%s below %s", below, below == 1 ? "" : "s", roots.len == 1 ? "it" : "them");
	}
	return text.str_view();
}

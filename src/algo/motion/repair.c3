<* The pure half of src/app/repair.c3: no state, undo or notices. *>
module crig;

import std::math;

// Seconds the pane's Smooth averages over: takes out jitter, keeps a step's shape.
const float SMOOTH_DEFAULT_WINDOW = 0.1f;

<*
 The period range a take's cycle is looked for in when nobody says: from a fifth
 of the take to half of it, starting after its first tenth and ending before its
 last — where a generated motion starts and stops.
*>
fn void cycle_defaults(float duration, float* period_min, float* period_max, float* from_min, float* from_max)
{
	*period_min = duration * 0.2f;
	*period_max = duration * 0.5f;
	*from_min = duration * 0.1f;
	*from_max = duration * 0.9f;
}

// The name of the rig's root joint in `names`; "" when it has none.
fn String root_name(RigView* view, String[] names)
{
	foreach (usz j, parent : view.skeleton.parents)
	{
		if (parent < 0 && j < names.len) return names[j];
	}
	return "";
}

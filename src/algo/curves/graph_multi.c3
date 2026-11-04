<* The pure half of src/app/graph_multi.c3: no state, undo or notices. *>
module crig;

import std::math;

<*
 How many selected keys of one channel the graph holds, and `axis` of them: the first one's
 value in `value`, `mixed` when they differ by more than `epsilon`.
*>
fn usz Graph.selected_values(&self, bool rotation, int axis, float* value, bool* mixed, float epsilon = 1.0e-3f)
{
	usz count;
	*mixed = false;
	foreach (key : self.keys)
	{
		GraphCurve curve = self.curves[key.curve];
		if (!key.selected || curve.rotation != rotation || curve.axis != axis) continue;
		if (count == 0)
		{
			*value = key.value;
		}
		else if (math::abs(key.value - *value) > epsilon)
		{
			*mixed = true;
		}
		count++;
	}
	return count;
}

<*
 The channel the value field speaks for: rotation when any selected key is a
 turn, else position. Both are drawn at once, and X means a different thing in each.
*>
fn bool Graph.selected_rotation(&self)
{
	foreach (key : self.keys) if (key.selected && self.curves[key.curve].rotation) return true;
	foreach (key : self.keys) if (key.selected) return false;
	return true;
}

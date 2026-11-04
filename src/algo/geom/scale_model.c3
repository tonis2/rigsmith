<* The pure half of src/app/scale_model.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;

enum ScaleModelResult : int
{
	SCALED,
	UNCHANGED,
	LOCKED,
	REFUSED,
}

// Below this a factor is a typo or a collapse, above it the same the other way.
// A thousandfold covers millimetres to metres, which is the widest honest change.
const float SCALE_MODEL_MIN = 0.001f;

const float SCALE_MODEL_MAX = 1000.0f;

<*
 How tall the model stands, in model units: the mesh's extent along Y, or the
 rig's when there is no mesh. Zero for an empty scene.
*>
fn float model_height(RigDocument* doc, rig::TriMesh* geometry)
{
	if (geometry.positions.len > 0)
	{
		rig::Bounds box = geometry.bounds();
		return box.max.y - box.min.y;
	}
	if (doc.dots.len() == 0) return 0.0f;
	float low = math::FLOAT_MAX;
	float high = -math::FLOAT_MAX;
	foreach (dot : doc.dots.array_view())
	{
		low = math::min(low, dot.position.y);
		high = math::max(high, dot.position.y);
	}
	return high - low;
}

<* The pure half of src/app/gait_author.c3: no state, undo or notices. *>
module crig;

import rig;
import std::math;
import std::math::quaternion;

// Keys per cycle when the caller does not say: 40 is dense enough that a linear
// blend between two keys is the path itself.
const usz GAIT_SAMPLES_DEFAULT = 40;

const usz GAIT_SAMPLES_MOST    = 240;

<*
 What landed. `joints`/`offsets` are the feet as driven (`count` of them) and
 `names` their joint names, copied so they outlive the rig view; `free` releases
 them.
*>
struct GaitAuthored
{
	AnimRef landed;
	bool replaced;
	GaitKind kind;
	GaitReport report;
	usz count;
	usz[GAIT_FEET_MAX] joints;
	float[GAIT_FEET_MAX] offsets;
	String[GAIT_FEET_MAX] names;
	float rig_height;
	// Whether the feet were pinned to their stance paths after the cycle was
	// written, and how far they slid before.
	bool pinned;
	float slide_before;
	// Layers carried over from the clip of this name the cycle replaced.
	usz kept_layers;
	// The paths the feet follow, a foot's own kept where it was edited by hand.
	usz paths;
}

// The layer a gait puts its body's motion in: the pelvis turning, the spine, the
// arms swinging — everything but the legs and the hips' drop.
const String GAIT_BODY_LAYER = "Body motion";

fn void GaitAuthored.free(&self, Allocator allocator)
{
	for (usz i = 0; i < self.count; i++) self.names[i].free(allocator);
	self.count = 0;
}

<*
 The average height of the feet's legs — hip to foot along Y — which is what a
 fraction of "the leg" means for lift and stride.
*>
fn float gait_leg_height(rig::Skeleton* skeleton, usz[] feet)
{
	if (feet.len == 0) return 0.0f;
	float height;
	foreach (foot : feet)
	{
		GaitLeg leg;
		if (gait_leg_of(skeleton, foot, &leg)) height += skeleton.joints[leg.joints[0]].y - skeleton.joints[foot].y;
	}
	return height / (float)feet.len;
}

<*
 Every rotation key of a clip written on this rig, held inside the rig's limits.

 A generator solves for where a foot should be, not for what the joints allow,
 and the few degrees it overshoots by — a knee a hair past straight, an ankle
 rolled further than it goes — are clamped away again when the clip plays. Kept
 in the keys, they are a clip whose keys say one thing and whose playback another,
 and measure_clip reports every one as saturating. Keys on this rig are its own
 local turns, so the clamp is the same one playback runs.
*>
fn void hold_keys_inside_limits(RigDocument* doc, RigView* view, AnimTemplate* clip)
{
	foreach (&frame : clip.keyframes)
	{
		foreach (&dot : frame.dots)
		{
			if (dot.channels == TRANSLATION) continue;
			sz joint = -1;
			foreach (usz j, name : view.names)
			{
				if (name == dot.joint_name)
				{
					joint = (sz)j;
					break;
				}
			}
			if (joint < 0 || (usz)joint >= view.dot_ids.len) continue;
			JointRotationLimits limits = doc.rotation_limits_of(view.dot_ids[(usz)joint]);
			if (!limits.constrained) continue;
			JointLimitFrame limit_frame = joint_limit_frame(&view.skeleton, view.dot_ids, limits);
			if (!limit_frame.usable()) continue;
			Quaternionf turn = quaternion::from_axis_angle{float}(dot.axis, dot.angle);
			Quaternionf held = constrain_joint_rotation(limit_frame, limits, turn);
			axis_angle_of(held, &dot.axis, &dot.angle);
		}
	}
}

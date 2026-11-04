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

<*
 The joints the body layer takes: every keyed joint but the legs and the root.

 @param [&inout] out : `Receives the names.`
 @param feet : `The foot joints.`
*>
fn void gait_body_joints(StringList* out, rig::Skeleton* skeleton, String[] names, usz root, usz[] feet, AnimTemplate clip)
{
	bool[] leg = alloc::new_array(mem, bool, (sz)skeleton.len());
	defer alloc::free(mem, leg);
	leg[root] = true;
	foreach (foot : feet)
	{
		GaitLeg each;
		if (gait_leg_of(skeleton, foot, &each)) for (usz j = 0; j <= each.bones; j++) leg[each.joints[j]] = true;
	}
	foreach (usz j, joint_name : names)
	{
		if (leg[j] || joint_name.len == 0 || clip.channel_count(joint_name, true) + clip.channel_count(joint_name, false) == 0) continue;
		out.push(joint_name);
	}
}

<*
 What was laid over the cycle being rewritten, carried onto the new one: its layers
 and look-ats. The body layer is the cycle's own, and is written again.

 @param body_layered : `Whether the new cycle has its own body layer.`
 @return `How many layers were kept.`
*>
fn usz gait_keep_laid_over(Allocator allocator, AnimTemplate* clip, AnimTemplate* before, bool body_layered)
{
	usz kept;
	foreach (&layer : before.layers) if (!body_layered || layer.name != GAIT_BODY_LAYER) kept++;
	AnimLayer[] next = alloc::new_array(allocator, AnimLayer, (sz)(clip.layers.len + kept));
	foreach (usz i, layer : clip.layers) next[i] = layer;
	usz write = clip.layers.len;
	foreach (&layer : before.layers) if (!body_layered || layer.name != GAIT_BODY_LAYER) next[write++] = layer.copy(allocator);
	if (clip.layers.len > 0) alloc::free(allocator, clip.layers);
	clip.layers = next;
	clip.aims = aims_copy(allocator, before.aims);
	clip.aim_targets = aim_targets_copy(allocator, before.aim_targets);
	return kept;
}

<*
 The feet's new paths over the old cycle's: a path edited by hand stays, and a
 generated one keeps its switches through a re-run.

 @param before : `The cycle being rewritten, or null.`
 @param stepped : `The new paths; taken over.`
 @return `Owned by the caller.`
*>
fn AnimPath[] gait_paths_over(Allocator allocator, AnimTemplate* before, AnimPath[] stepped)
{
	usz hand;
	if (before) foreach (&path : before.paths) if (!path.generated) hand++;
	AnimPath[] next = alloc::new_array(allocator, AnimPath, (sz)(hand + stepped.len));
	usz write;
	if (before) foreach (&path : before.paths) if (!path.generated) next[write++] = path.copy(allocator);
	foreach (&path : stepped)
	{
		bool edited;
		for (usz k = 0; k < write; k++) if (next[k].joint == path.joint) edited = true;
		if (edited) { path.free(allocator); continue; }
		if (before)
		{
			foreach (&old : before.paths)
			{
				if (!old.generated || old.joint != path.joint) continue;
				path.follow = old.follow;
				path.mute = old.mute;
			}
		}
		next[write++] = *path;
	}
	if (stepped.len > 0) alloc::free(allocator, stepped);
	return next[:write];
}

<*
 What a cycle was written from, for the viewport to write it again.

 @param height : `The rig's height, above zero.`
 @param feet : `The foot joints.`
 @param driven : `Each foot's gait entry.`
*>
fn void gait_record(Allocator allocator, AnimTemplate* clip, GaitSpec spec, GaitReport report, float height, String[] names,
	usz[] feet, GaitFoot[] driven)
{
	clip.gait = {
		.set = true,
		.kind = spec.kind,
		.duty = report.duty,
		.stride = report.stride / height,
		.lift = report.lift / height,
		.drop_set = spec.drop_set,
		.drop = spec.drop / height,
		.legs_only = spec.legs_only,
		.arms_set = spec.arms_set,
		.arm_swing = spec.arm_swing,
		.arm_elbow = spec.arm_elbow,
		.arm_elbow_swing = spec.arm_elbow_swing,
		.arm_spread = spec.arm_spread,
		.samples = spec.samples,
		.feet = alloc::new_array(allocator, String, (sz)feet.len),
		.offsets = alloc::new_array(allocator, float, (sz)feet.len),
	};
	foreach (usz i, foot : feet)
	{
		clip.gait.feet[i] = names[foot].copy(allocator);
		clip.gait.offsets[i] = driven[i].offset;
	}
}

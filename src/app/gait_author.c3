<*
 Authoring a gait cycle onto the character: the one path the MCP `author_gait`
 tool and the Animations pane's Gait panel both take.

 The caller says which gait, how long, and optionally which feet (by joint name)
 and where each lands; this finds the rest, draws the clip with `anim/gait.c3`,
 and lands it in the authored pack as one undo step, bound and opened, exactly as
 `author_clip` does for every other writer. Why a request was refused is written
 into `detail`, in words a caller can show as they are.
*>
module crig;

import rig;
import std::math;

faultdef GAIT_REFUSED, GAIT_BAD_FOOT;

// Keys per cycle when the caller does not say: 40 is dense enough that a linear
// blend between two keys is the path itself.
const usz GAIT_SAMPLES_DEFAULT = 40;
const usz GAIT_SAMPLES_MOST = 240;

// One foot as the caller names it. `offset` is honoured only when `has_offset`;
// otherwise the gait's own pattern places the foot.
struct GaitFootRequest
{
	String joint;
	bool has_offset;
	float offset;
}

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
}

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
 Write the clip.

 @param name : `The clip's name; a clip of that name in the authored pack is replaced, so a caller that must not do that makes it unique first (unused_clip_name).`
 @param spec : `Kind, duration, loop and samples are taken as given; zero duty, stride and lift take the gait's defaults.`
 @param lift_fraction : `When above zero, lift as a fraction of the leg's height, overriding spec.lift.`
 @param feet : `Named feet, or empty to have them found.`
 @return? GAIT_REFUSED : `The reason is in detail.`
*>
fn GaitAuthored? AppState.author_gait(&self, String name, GaitSpec spec, double lift_fraction, GaitFootRequest[] feet, DString* detail)
{
	RigView? opened = self.open_rig(mem);
	if (catch opened)
	{
		detail.append_string(`this document has no dots, so there are no legs to walk on. apply_plan fits a rig; get_scene reports what is loaded.`);
		return GAIT_REFUSED~;
	}
	RigView view = opened;
	defer view.free(mem);

	usz[GAIT_FEET_MAX] joints;
	bool[GAIT_FEET_MAX] offsets_given;
	float[GAIT_FEET_MAX] given_offset;
	usz count;
	if (feet.len > 0)
	{
		if (feet.len > GAIT_FEET_MAX)
		{
			detail.appendf(`"feet" has %d entries and %d is the most one gait drives.`, feet.len, GAIT_FEET_MAX);
			return GAIT_REFUSED~;
		}
		foreach (i, entry : feet)
		{
			if (!self.has_dot_named(entry.joint))
			{
				detail.appendf(`feet[%d].joint is "%s", which is not a dot on this rig. get_skeleton lists every joint by name.`, i, entry.joint);
				return GAIT_REFUSED~;
			}
			sz at = view.joint_of(self.dot_named(entry.joint).id);
			if (at < 0)
			{
				detail.appendf(`feet[%d].joint is "%s", which is not part of the rig's skeleton.`, i, entry.joint);
				return GAIT_REFUSED~;
			}
			joints[count] = (usz)at;
			if (entry.has_offset)
			{
				if (entry.offset < 0.0f || entry.offset > 1.0f)
				{
					detail.appendf(`feet[%d].offset is %.9g. It is a phase of the cycle, 0 to 1.`, i, entry.offset);
					return GAIT_REFUSED~;
				}
				offsets_given[count] = true;
				given_offset[count] = entry.offset;
			}
			else if (spec.kind == CUSTOM)
			{
				detail.appendf(`feet[%d] needs "offset" for gait custom: the phase of the cycle the foot lands at, 0 to 1.`, i);
				return GAIT_REFUSED~;
			}
			count++;
		}
	}
	else
	{
		if (spec.kind == CUSTOM)
		{
			detail.append_string(`gait custom needs "feet": every foot's joint and offset, since there is no pattern to read them from.`);
			return GAIT_REFUSED~;
		}
		count = gait_find_feet(&view.skeleton, view.names, joints[:GAIT_FEET_MAX]);
		if (count == 0)
		{
			detail.append_string(`no feet found: a foot is the lowest joint of a left/right pair of limbs that end in a toe, two or more bones below a fork. Name them in "feet".`);
			return GAIT_REFUSED~;
		}
	}

	float[GAIT_FEET_MAX] offsets;
	gait_offsets(&view.skeleton, spec.kind, joints[:count], offsets[:count]);
	GaitFoot[GAIT_FEET_MAX] driven;
	for (usz i = 0; i < count; i++)
	{
		driven[i] = { .joint = joints[i], .offset = offsets_given[i] ? given_offset[i] : offsets[i] };
	}

	if (lift_fraction > 0.0) spec.lift = (float)lift_fraction * gait_leg_height(&view.skeleton, joints[:count]);

	GaitAuthored out = { .kind = spec.kind, .rig_height = view.skeleton.height() };
	AnimTemplate? made = gait_clip(mem, &view.skeleton, view.names, name, spec, driven[:count], &out.report);
	if (catch problem = made)
	{
		if (problem == GAIT_BAD_LEG)
		{
			detail.append_string(`a foot has no leg this can bend: it needs two or more named bones between it and the first fork above. get_skeleton shows the rig's joints and parents.`);
		}
		else
		{
			detail.append_string(`there are no feet to walk on.`);
		}
		return GAIT_REFUSED~;
	}
	AnimTemplate clip = made;

	out.landed = self.author_clip(clip, &out.replaced);
	self.refresh_ui();

	out.count = count;
	for (usz i = 0; i < count; i++)
	{
		out.joints[i] = joints[i];
		out.offsets[i] = driven[i].offset;
		out.names[i] = view.names[joints[i]].copy(mem);
	}
	return out;
}

<*
 The worst a foot slides off the floor while it should be planted, as a fraction
 of the rig's height — `measure_clip`'s foot_slide for a landed clip, or zero when
 there is no rig or no ground spec to measure against.
*>
fn float AppState.clip_foot_slide(&self, AnimRef ref)
{
	AnimTemplate* clip = self.clip(ref);
	if (!clip) return 0.0f;
	RigView? opened = self.open_rig(mem);
	if (catch opened) return 0.0f;
	RigView view = opened;
	defer view.free(mem);
	ClipMetrics numbers = clip_metrics(mem, &view.skeleton, view.names, *clip, 32, &self.doc, view.dot_ids);
	defer numbers.free(mem);
	return numbers.foot_slide;
}
